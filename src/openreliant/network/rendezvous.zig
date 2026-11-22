//! Carries an ICE connection's signals through a directory's rendezvous, for a host behind a
//! router with no forwarded port ([#363](https://github.com/OpenReliant/openreliant/issues/363)).
//!
//! The transport makes the signals and reads them (`transport.session_ice_listen`,
//! `session_ice_connect`, `session_signal_in`). A thread of this module's own posts and polls
//! them at the directory, so the game never waits on the network. The directory only stores the
//! signals. The transport's own handshake still checks the host's key, so a directory that
//! altered them could stop a connection but not stand in for the host.
const std = @import("std");
const Io = std.Io;
const web = @import("openreliant").engine.web;
const net = @import("transport.zig");
const Rendezvous = @This();
const log = std.log.scoped(.rendezvous);

/// The largest signal the directory takes, in bytes.
pub const max_signal = 2880;
/// How many signals wait in each direction between the game and the thread.
const waiting = 32;
/// How many joining players a host passes signals for at once, the directory's own share for a
/// listing.
const max_exchanges = 8;
/// What an answer from the directory may hold: a poll's signals and their JSON.
const max_answer = 32 * 1024;
/// How long a request to the directory may take.
const request_timeout: Io.Duration = .fromSeconds(4);
/// How often the thread asks the directory for signals: a host with nobody joining, and either
/// side while a player joins.
const idle_poll: Io.Duration = .fromMilliseconds(1500);
const busy_poll: Io.Duration = .fromMilliseconds(200);
/// How long a host goes on polling quickly after the last signal of a joining player.
const busy_us = 10 * std.time.us_per_s;
/// The exchange a joining player's one connection uses.
pub const joining_exchange = 1;

const Signal = struct {
    exchange: u32 = 0,
    len: u16 = 0,
    bytes: [max_signal]u8 = undefined,

    fn slice(signal: *const Signal) []const u8 {
        return signal.bytes[0..signal.len];
    }
};

/// Signals handed from one thread to another. A short spin lock guards it: each side only
/// copies a record.
const Ring = struct {
    locked: std.atomic.Value(bool) = .init(false),
    items: [waiting]Signal = undefined,
    first: usize = 0,
    count: usize = 0,

    fn lock(ring: *Ring) void {
        while (ring.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock(ring: *Ring) void {
        ring.locked.store(false, .release);
    }

    /// Queues a signal, or gives false for one that is too large or when the ring is full.
    fn push(ring: *Ring, exchange: u32, bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > max_signal) return false;
        ring.lock();
        defer ring.unlock();
        if (ring.count == waiting) return false;
        const item = &ring.items[(ring.first + ring.count) % waiting];
        item.exchange = exchange;
        item.len = @intCast(bytes.len);
        @memcpy(item.bytes[0..bytes.len], bytes);
        ring.count += 1;
        return true;
    }

    fn pop(ring: *Ring, out: *Signal) bool {
        ring.lock();
        defer ring.unlock();
        if (ring.count == 0) return false;
        out.* = ring.items[ring.first];
        ring.first = (ring.first + 1) % waiting;
        ring.count -= 1;
        return true;
    }
};

test Ring {
    const ring = try std.testing.allocator.create(Ring);
    defer std.testing.allocator.destroy(ring);
    ring.* = .{};
    var out: Signal = .{};
    try std.testing.expect(!ring.pop(&out));
    // An empty signal and one over the directory's size are refused.
    try std.testing.expect(!ring.push(1, ""));
    try std.testing.expect(!ring.push(1, &@as([max_signal + 1]u8, @splat(0))));
    for (0..waiting) |n| try std.testing.expect(ring.push(@intCast(n), "signal"));
    try std.testing.expect(!ring.push(99, "full"));
    // They come out in order, and the room they leave is used again.
    try std.testing.expect(ring.pop(&out));
    try std.testing.expectEqual(0, out.exchange);
    try std.testing.expectEqualStrings("signal", out.slice());
    try std.testing.expect(ring.push(99, "again"));
    for (1..waiting) |n| {
        try std.testing.expect(ring.pop(&out));
        try std.testing.expectEqual(n, out.exchange);
    }
    try std.testing.expect(ring.pop(&out));
    try std.testing.expectEqualStrings("again", out.slice());
}

pub const exchange_id_len = 32;
pub const token_len = 64;
pub const key_len = 64;
pub const session_len = 32;

/// Which side of a connection this is, and what it names itself to the directory with.
pub const Role = union(enum) {
    /// A host, with the token its registration gave it. It has none until it is registered.
    host,
    /// A player joining the listing with this key and session, in hex.
    join: struct { key: [key_len]u8, session: [session_len]u8 },
};

/// How far the thread has got.
pub const State = enum(u8) {
    /// Asking the directory what it offers.
    starting,
    /// The directory takes rendezvous, and `stun` holds its STUN servers.
    ready,
    /// The directory can't be reached, or offers no rendezvous.
    failed,
};

/// The exchanges a host has open, each with the number the transport knows it by.
const Exchanges = struct {
    entries: [max_exchanges]?Entry = @splat(null),
    next: u32 = joining_exchange + 1,

    const Entry = struct { number: u32, id: [exchange_id_len]u8, touched: i64 };

    /// The number of the exchange `id`, a new one the first time. A full table gives up the
    /// exchange that has been quiet longest, as the directory itself does.
    fn number(exchanges: *Exchanges, id: [exchange_id_len]u8, now: i64) u32 {
        var free: ?*?Entry = null;
        var quietest: *?Entry = &exchanges.entries[0];
        for (&exchanges.entries) |*slot| {
            if (slot.*) |*entry| {
                if (std.mem.eql(u8, &entry.id, &id)) {
                    entry.touched = now;
                    return entry.number;
                }
                if (quietest.* == null or entry.touched < quietest.*.?.touched) quietest = slot;
            } else if (free == null) {
                free = slot;
            }
        }
        const slot = free orelse quietest;
        slot.* = .{ .number = exchanges.next, .id = id, .touched = now };
        exchanges.next +%= 1;
        if (exchanges.next <= joining_exchange) exchanges.next = joining_exchange + 1;
        return slot.*.?.number;
    }

    fn idOf(exchanges: *const Exchanges, wanted: u32) ?[exchange_id_len]u8 {
        for (exchanges.entries) |slot| {
            if (slot) |entry| if (entry.number == wanted) return entry.id;
        }
        return null;
    }
};

test Exchanges {
    var exchanges: Exchanges = .{};
    const first = exchanges.number(@splat('a'), 1);
    try std.testing.expectEqual(first, exchanges.number(@splat('a'), 2));
    try std.testing.expect(first != exchanges.number(@splat('b'), 3));
    try std.testing.expectEqual(@as([exchange_id_len]u8, @splat('a')), exchanges.idOf(first).?);
    try std.testing.expectEqual(null, exchanges.idOf(9999));
    // A full table drops the one that has been quiet longest.
    for (0..max_exchanges) |n| _ = exchanges.number(@splat('0' + @as(u8, @intCast(n))), 10 + @as(i64, @intCast(n)));
    try std.testing.expectEqual(null, exchanges.idOf(first));
}

origin_buffer: [256]u8 = undefined,
origin_len: usize = 0,
role: Role = .host,
/// Whether the directory is on this machine, as it is in a test. Then the machine's own
/// network's addresses are offered too, which a connection between two local processes needs.
local: bool = false,
outbox: Ring = .{},
inbox: Ring = .{},
state: std.atomic.Value(State) = .init(.starting),
stop: std.atomic.Value(bool) = .init(false),
/// Whether a joining player is connected, and so asks the directory only now and then.
settled: std.atomic.Value(bool) = .init(false),
thread: ?std.Thread = null,
/// The directory's STUN servers, as the transport takes them, once `state` is `ready`.
stun_buffer: [256:0]u8 = @splat(0),
/// A host's token, guarded by `token_lock`, which its registration sets and renews.
token: ?[token_len]u8 = null,
token_lock: std.atomic.Value(bool) = .init(false),

/// The one rendezvous the transport's signals go out through.
var active: ?*Rendezvous = null;

comptime {
    if (@import("network_options").enabled) @export(&signalOut, .{ .name = "session_signal_out" });
}

/// What the transport calls with a signal to send, on its own thread.
fn signalOut(exchange: u32, signal: [*]const u8, size: c_int) callconv(.c) bool {
    const rendezvous = active orelse return false;
    if (size <= 0) return false;
    return rendezvous.outbox.push(exchange, signal[0..@intCast(size)]);
}

/// The STUN servers every game also asks, where a directory names none or its own is down.
const fallback_stun = "stun.cloudflare.com:3478,stun.l.google.com:19302";

/// Starts passing signals through the directory at the URL `directory`. The record is the
/// caller's until `destroy`: it is large, and its thread keeps a pointer to it.
pub fn create(directory: []const u8, role: Role) !*Rendezvous {
    const trimmed = std.mem.trim(u8, directory, " \t/");
    const rendezvous = try web.allocator.create(Rendezvous);
    errdefer web.allocator.destroy(rendezvous);
    rendezvous.* = .{ .role = role, .local = web.Loopback.of(trimmed) == .allowed };
    if (trimmed.len == 0 or trimmed.len > rendezvous.origin_buffer.len) return error.InvalidDirectory;
    @memcpy(rendezvous.origin_buffer[0..trimmed.len], trimmed);
    rendezvous.origin_len = trimmed.len;
    active = rendezvous;
    errdefer active = null;
    rendezvous.thread = try std.Thread.spawn(.{}, run, .{rendezvous});
    return rendezvous;
}

/// Stops the thread, waits for it and frees the record. A request on its way gets
/// `request_timeout` at most.
pub fn destroy(rendezvous: *Rendezvous) void {
    rendezvous.stop.store(true, .release);
    if (rendezvous.thread) |thread| thread.join();
    if (active == rendezvous) active = null;
    web.allocator.destroy(rendezvous);
}

/// The STUN servers to turn ICE on with, once the directory has said it takes rendezvous.
pub fn stun(rendezvous: *const Rendezvous) ?[:0]const u8 {
    if (rendezvous.state.load(.acquire) != .ready) return null;
    return std.mem.sliceTo(&rendezvous.stun_buffer, 0);
}

/// Sets or renews a host's token, in hex, as its registration returns it. Null stops the polling
/// until the next one.
pub fn setToken(rendezvous: *Rendezvous, token: ?[token_len]u8) void {
    while (rendezvous.token_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer rendezvous.token_lock.store(false, .release);
    rendezvous.token = token;
}

fn heldToken(rendezvous: *Rendezvous) ?[token_len]u8 {
    while (rendezvous.token_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
    defer rendezvous.token_lock.store(false, .release);
    return rendezvous.token;
}

/// Slows a joining player's polling once it is connected. ICE may still have a late signal to
/// pass, and the directory closes the exchange on its own.
pub fn settle(rendezvous: *Rendezvous) void {
    rendezvous.settled.store(true, .release);
}

/// Hands the transport the signals the directory brought. The game calls this where it polls
/// the transport.
pub fn pump(rendezvous: *Rendezvous) void {
    var signal: Signal = .{};
    while (rendezvous.inbox.pop(&signal)) {
        // A signal the transport can't read is dropped: it is what a stranger sent.
        _ = net.session_signal_in(signal.exchange, &signal.bytes, signal.len);
    }
}

fn origin(rendezvous: *const Rendezvous) []const u8 {
    return rendezvous.origin_buffer[0..rendezvous.origin_len];
}

const Capabilities = struct {
    rendezvous: bool = false,
    stun_endpoint: ?[]const u8 = null,
};

/// The transport's list of STUN servers from a directory's endpoint, `stun:host:port`, followed
/// by the fallbacks. An endpoint that isn't one is left out.
fn stunList(buffer: *[256:0]u8, endpoint: ?[]const u8) void {
    var out: Io.Writer = .fixed(buffer);
    if (endpoint) |text| if (std.mem.cutPrefix(u8, text, "stun:")) |host| {
        const plain = for (host) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != ':' and c != '-' and c != '[' and c != ']') break false;
        } else host.len != 0;
        if (plain and host.len + 1 + fallback_stun.len < buffer.len) out.print("{s},", .{host}) catch {};
    };
    out.writeAll(fallback_stun) catch {};
    buffer[out.end] = 0;
}

test stunList {
    var buffer: [256:0]u8 = @splat(0);
    stunList(&buffer, "stun:directory.example:3478");
    try std.testing.expectEqualStrings("directory.example:3478," ++ fallback_stun, std.mem.sliceTo(&buffer, 0));
    // No endpoint, one of another kind and one with other characters leave the fallbacks.
    for ([_]?[]const u8{ null, "turn:relay.example:3478", "stun:bad host,evil:1", "stun:" }) |endpoint| {
        buffer = @splat(0);
        stunList(&buffer, endpoint);
        try std.testing.expectEqualStrings(fallback_stun, std.mem.sliceTo(&buffer, 0));
    }
}

const Worker = struct {
    rendezvous: *Rendezvous,
    io: Io,
    client: std.http.Client,
    arena: std.heap.ArenaAllocator,
    exchanges: Exchanges = .{},
    /// A joining player's exchange, once its offer is answered.
    id: ?[exchange_id_len]u8 = null,
    busy_until: i64 = 0,
    answer: [max_answer]u8 = undefined,

    fn url(worker: *Worker, comptime path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(worker.arena.allocator(), "{s}" ++ path, .{worker.rendezvous.origin()});
    }

    /// Posts `payload` and gives the answer's body where the directory answered `expected`.
    fn post(worker: *Worker, target: []const u8, payload: []const u8, token: ?[]const u8, expected: std.http.Status) ![]const u8 {
        const uri = try web.secured(try std.Uri.parse(target), .of(target));
        var body: Io.Writer = .fixed(&worker.answer);
        const headers = [_]std.http.Header{.{ .name = "X-Directory-Rendezvous", .value = token orelse "" }};
        const result = try worker.client.fetch(.{
            .location = .{ .uri = uri },
            .method = .POST,
            .payload = payload,
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .extra_headers = if (token != null) &headers else &.{},
            .response_writer = &body,
        });
        if (result.status != expected) return error.Refused;
        return body.buffered();
    }

    fn capabilities(worker: *Worker) !Capabilities {
        const target = try worker.url("/v1/capabilities");
        const uri = try web.secured(try std.Uri.parse(target), .of(target));
        var body: Io.Writer = .fixed(&worker.answer);
        const result = try worker.client.fetch(.{ .location = .{ .uri = uri }, .redirect_behavior = .unhandled, .keep_alive = false, .response_writer = &body });
        if (result.status != .ok) return error.Refused;
        return std.json.parseFromSliceLeaky(Capabilities, worker.arena.allocator(), body.buffered(), .{ .ignore_unknown_fields = true });
    }

    /// Takes the signals of one answer into the inbox. One that isn't base64 or is too large is
    /// passed over.
    fn take(worker: *Worker, exchange: u32, signals: []const []const u8) void {
        const decoder = std.base64.standard.Decoder;
        var bytes: [max_signal]u8 = undefined;
        for (signals) |text| {
            const size = decoder.calcSizeForSlice(text) catch continue;
            if (size == 0 or size > bytes.len) continue;
            decoder.decode(bytes[0..size], text) catch continue;
            if (!worker.rendezvous.inbox.push(exchange, bytes[0..size])) log.warn("a signal was dropped: the game isn't taking them", .{});
        }
    }

    fn sendSignal(worker: *Worker, id: [exchange_id_len]u8, signal: *const Signal, token: ?[]const u8) !void {
        var encoded: [std.base64.standard.Encoder.calcSize(max_signal)]u8 = undefined;
        const text = std.base64.standard.Encoder.encode(&encoded, signal.slice());
        const payload = try std.fmt.allocPrint(worker.arena.allocator(), "{{\"id\":\"{s}\",\"signal\":\"{s}\"}}", .{ id, text });
        _ = try worker.post(try worker.url("/v1/rendezvous/send"), payload, token, .no_content);
    }

    /// One round of a host: the signals of the players joining it, then its answers to them.
    fn hostRound(worker: *Worker, now: i64) !void {
        const token = worker.rendezvous.heldToken() orelse return;
        const Polled = struct { exchanges: []const struct { id: []const u8, signals: []const []const u8 } };
        const body = try worker.post(try worker.url("/v1/rendezvous/poll"), "{}", &token, .ok);
        const polled = try std.json.parseFromSliceLeaky(Polled, worker.arena.allocator(), body, .{ .ignore_unknown_fields = true });
        for (polled.exchanges) |exchange| {
            if (exchange.id.len != exchange_id_len or exchange.signals.len == 0) continue;
            worker.take(worker.exchanges.number(exchange.id[0..exchange_id_len].*, now), exchange.signals);
            worker.busy_until = now + busy_us;
        }
        var signal: Signal = .{};
        while (worker.rendezvous.outbox.pop(&signal)) {
            // An answer for an exchange the table has given up has nowhere to go.
            const id = worker.exchanges.idOf(signal.exchange) orelse continue;
            worker.sendSignal(id, &signal, &token) catch |err| log.debug("a signal wasn't sent: {t}", .{err});
            worker.busy_until = now + busy_us;
        }
    }

    /// One round of a joining player: its offer first, then its signals and the host's.
    fn joinRound(worker: *Worker, join: @FieldType(Role, "join")) !void {
        var signal: Signal = .{};
        const id = worker.id orelse {
            if (!worker.rendezvous.outbox.pop(&signal)) return;
            var encoded: [std.base64.standard.Encoder.calcSize(max_signal)]u8 = undefined;
            const text = std.base64.standard.Encoder.encode(&encoded, signal.slice());
            const payload = try std.fmt.allocPrint(worker.arena.allocator(), "{{\"key\":\"{s}\",\"session\":\"{s}\",\"signal\":\"{s}\"}}", .{ join.key, join.session, text });
            const body = try worker.post(try worker.url("/v1/rendezvous/offer"), payload, null, .ok);
            const opened = try std.json.parseFromSliceLeaky(struct { id: []const u8 }, worker.arena.allocator(), body, .{ .ignore_unknown_fields = true });
            if (opened.id.len != exchange_id_len) return error.Refused;
            worker.id = opened.id[0..exchange_id_len].*;
            return;
        };
        while (worker.rendezvous.outbox.pop(&signal)) try worker.sendSignal(id, &signal, null);
        const payload = try std.fmt.allocPrint(worker.arena.allocator(), "{{\"id\":\"{s}\"}}", .{id});
        const body = try worker.post(try worker.url("/v1/rendezvous/poll"), payload, null, .ok);
        const polled = try std.json.parseFromSliceLeaky(struct { signals: []const []const u8 }, worker.arena.allocator(), body, .{ .ignore_unknown_fields = true });
        worker.take(joining_exchange, polled.signals);
    }
};

/// A round within `request_timeout`, so a directory that stops answering never holds the thread
/// past it.
fn timed(io: Io, worker: *Worker, comptime round: anytype, args: anytype) !void {
    const Event = union(enum) { result: anyerror!void, deadline: Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.result, round, .{worker} ++ args);
    try select.concurrent(.deadline, Io.sleep, .{ io, request_timeout, .awake });
    return switch (try select.await()) {
        .result => |result| result,
        .deadline => error.Timeout,
    };
}

fn run(rendezvous: *Rendezvous) void {
    var threaded: Io.Threaded = .init(web.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const worker = web.allocator.create(Worker) catch return rendezvous.state.store(.failed, .release);
    defer web.allocator.destroy(worker);
    worker.* = .{ .rendezvous = rendezvous, .io = io, .client = .{ .allocator = web.allocator, .io = io }, .arena = .init(web.allocator) };
    defer worker.arena.deinit();
    defer worker.client.deinit();

    const offered = offered: {
        const Ask = struct {
            fn round(asking: *Worker, out: *Capabilities) anyerror!void {
                out.* = try asking.capabilities();
            }
        };
        var found: Capabilities = .{};
        timed(io, worker, Ask.round, .{&found}) catch |err| {
            log.warn("the directory {s} can't be asked for rendezvous: {t}", .{ rendezvous.origin(), err });
            break :offered false;
        };
        if (found.rendezvous) stunList(&rendezvous.stun_buffer, found.stun_endpoint);
        break :offered found.rendezvous;
    };
    _ = worker.arena.reset(.retain_capacity);
    if (!offered) return rendezvous.state.store(.failed, .release);
    rendezvous.state.store(.ready, .release);

    var failures: u32 = 0;
    while (!rendezvous.stop.load(.acquire)) {
        const now = Io.Clock.awake.now(io).toMicroseconds();
        const outcome = switch (rendezvous.role) {
            .host => timed(io, worker, Worker.hostRound, .{now}),
            .join => |join| timed(io, worker, Worker.joinRound, .{join}),
        };
        _ = worker.arena.reset(.retain_capacity);
        if (outcome) |_| {
            failures = 0;
        } else |err| {
            failures += 1;
            if (failures == 1 or failures % 20 == 0) log.debug("rendezvous with {s}: {t}", .{ rendezvous.origin(), err });
            // A player's join has one exchange to lose. A host keeps trying.
            if (rendezvous.role == .join and failures >= 5) return rendezvous.state.store(.failed, .release);
        }
        const busy = if (rendezvous.role == .join) !rendezvous.settled.load(.acquire) else now < worker.busy_until;
        io.sleep(if (busy and failures == 0) busy_poll else idle_poll, .awake) catch return;
    }
}

test {
    std.testing.refAllDecls(@This());
}
