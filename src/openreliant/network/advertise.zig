//! Publish a host's signed directory lease on a background worker.
const std = @import("std");
const engine = @import("openreliant").engine;
const web = engine.web;
const identity = @import("identity.zig");
const wire = @import("wire.zig");
const version = @import("version");
const Host = @import("server.zig");
const net = @import("transport.zig");
const Rendezvous = @import("rendezvous.zig");
const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Publisher = @This();

const Snapshot = struct {
    players: usize,
    capacity: u8,
    scenario: ?wire.Scenario,
    accepting: bool,

    fn of(host: *const Host) Snapshot {
        const players = host.playingCount();
        return .{
            .players = players,
            .capacity = host.player_limit,
            .scenario = if (host.start == .lobby) host.start.lobby.scenario else host.arena.mode.scenario(),
            .accepting = host.final_tick == null and players < host.player_limit,
        };
    }
};

pub const Config = struct {
    origins: []const u8,
    name: []const u8,
    description: []const u8,
    address: ?[]const u8,
    port: u16,
    hosting: Hosting = .dedicated,
    /// Whether players reach the host through the first directory's rendezvous, for a host
    /// behind a router with no forwarded port. The host then publishes to that directory alone:
    /// another one would list an address nobody can reach.
    rendezvous: bool = false,
    /// Whether the game stays out of the list, so that only players with its invite find it. It
    /// needs `rendezvous`, and is published nowhere while the directory offers none.
    unlisted: bool = false,

    /// The directory protocol's names for who hosts a game.
    pub const Hosting = enum { dedicated, player_hosted };

    /// The first of `origins`, which is the one rendezvous goes through.
    fn first(config: Config) ?[]const u8 {
        var origins = std.mem.splitScalar(u8, config.origins, ',');
        while (origins.next()) |part| {
            const origin = std.mem.trim(u8, part, " \t/");
            if (origin.len != 0) return origin;
        }
        return null;
    }
};

test "rendezvous goes through the first directory" {
    const config: Config = .{ .origins = " , https://one.example/ ,https://two.example", .name = "", .description = "", .address = null, .port = 1 };
    try std.testing.expectEqualStrings("https://one.example", config.first().?);
    var none = config;
    none.origins = " , ";
    try std.testing.expectEqual(null, none.first());
}

const Job = struct {
    arena: std.heap.ArenaAllocator,
    origins: []const u8,
    body: []const u8,
    key: KeyPair,
    session: [16]u8,
    /// Whether `origins` is the one directory rendezvous goes through, whose answer may carry a
    /// token.
    takes_token: bool = false,
    token: ?[Rendezvous.token_len]u8 = null,

    pub fn deinit(job: *Job) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&job.key));
        job.arena.deinit();
    }

    /// Registers with each directory, and gives the rendezvous token the first one answered
    /// with, where it gave one.
    pub fn run(job: *Job, io: std.Io, _: *web.Progress) !?[Rendezvous.token_len]u8 {
        job.sendAll(io, .register);
        return job.token;
    }

    /// Sends `operation` to each directory in turn. One that fails or is slow is logged and
    /// doesn't hold up the others.
    fn sendAll(job: *Job, io: std.Io, operation: Operation) void {
        var origins = std.mem.splitScalar(u8, job.origins, ',');
        while (origins.next()) |part| {
            const origin = std.mem.trim(u8, part, " \t/");
            if (origin.len == 0) continue;
            job.sendWithDeadline(io, origin, operation) catch |err| std.log.warn("directory {s}: {t}", .{ origin, err });
        }
    }

    fn sendWithDeadline(job: *Job, io: std.Io, origin: []const u8, operation: Operation) !void {
        const Event = union(enum) { result: anyerror!void, deadline: std.Io.Cancelable!void };
        var events: [2]Event = undefined;
        var select: std.Io.Select(Event) = .init(io, &events);
        defer select.cancelDiscard();
        try select.concurrent(.result, request, .{ job, io, origin, operation });
        try select.concurrent(.deadline, std.Io.sleep, .{ io, operation.deadline(), .awake });
        return switch (try select.await()) {
            .result => |result| result,
            .deadline => error.Timeout,
        };
    }

    /// Asks the directory for a challenge, signs it with the operation's body, and sends the
    /// operation.
    fn request(job: *Job, io: std.Io, origin: []const u8, operation: Operation) !void {
        const allocator = job.arena.allocator();
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        const key = std.fmt.bytesToHex(job.key.public_key.toBytes(), .lower);
        const session = std.fmt.bytesToHex(job.session, .lower);
        const body = switch (operation) {
            .register => job.body,
            .withdraw => "",
        };
        const challenge_body = try std.json.Stringify.valueAlloc(allocator, .{ .key = key, .session = session, .operation = operation }, .{});
        const challenge_url = try std.fmt.allocPrint(allocator, "{s}/v1/challenge", .{origin});
        var response_buffer: [4096]u8 = undefined;
        var response: std.Io.Writer = .fixed(&response_buffer);
        const first = try post(&client, challenge_url, challenge_body, &.{}, &response);
        if (first != .ok) return error.ChallengeRefused;
        const parsed = try std.json.parseFromSliceLeaky(struct { challenge: []const u8 }, allocator, response.buffered(), .{ .ignore_unknown_fields = true });
        if (parsed.challenge.len != 64) return error.InvalidChallenge;
        var message_buffer: [signed_capacity]u8 = undefined;
        const message = try signedMessage(&message_buffer, operation, parsed.challenge, &session, body);
        const signature = std.fmt.bytesToHex((try job.key.sign(message, null)).toBytes(), .lower);
        const headers = [_]std.http.Header{
            .{ .name = "X-Directory-Key", .value = &key },
            .{ .name = "X-Directory-Session", .value = &session },
            .{ .name = "X-Directory-Challenge", .value = parsed.challenge },
            .{ .name = "X-Directory-Signature", .value = &signature },
        };
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/{t}", .{ origin, operation });
        response = .fixed(&response_buffer);
        const status = try post(&client, url, body, &headers, &response);
        if (status != operation.answer()) {
            // What the directory said tells an operator which setting it refuses.
            std.log.warn("directory {s} answered {d}: {s}", .{ origin, @backingInt(status), response.buffered() });
            return error.AdvertisementRefused;
        }
        if (operation == .register and job.takes_token) {
            const Lease = struct { rendezvous_token: ?[]const u8 = null };
            const lease = std.json.parseFromSliceLeaky(Lease, allocator, response.buffered(), .{ .ignore_unknown_fields = true }) catch return;
            const text = lease.rendezvous_token orelse return;
            if (text.len == Rendezvous.token_len) job.token = text[0..Rendezvous.token_len].*;
        }
    }
};

/// What a host asks of a directory. The names are the directory protocol's.
const Operation = enum {
    register,
    withdraw,

    /// How long one directory gets. A withdrawal runs as the host stops, so it gets less.
    fn deadline(operation: Operation) std.Io.Duration {
        return switch (operation) {
            .register => .fromSeconds(3),
            .withdraw => .fromSeconds(2),
        };
    }

    /// The status the directory answers with when it has done the operation.
    fn answer(operation: Operation) std.http.Status {
        return switch (operation) {
            .register => .ok,
            .withdraw => .no_content,
        };
    }
};

/// The directory takes bodies of up to 4096 bytes. The rest is the text signed around the body.
const signed_capacity = 4096 + 160;

/// The bytes a host signs for the directory: the protocol's name, the operation, the directory's
/// challenge, the session and the request's body, each on a line of its own.
fn signedMessage(buffer: []u8, operation: Operation, challenge: []const u8, session: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "OpenReliant Directory v1\n{t}\n{s}\n{s}\n{s}", .{ operation, challenge, session, body });
}

test signedMessage {
    var buffer: [signed_capacity]u8 = undefined;
    try std.testing.expectEqualStrings("OpenReliant Directory v1\nregister\nc0\n5e\n{}", try signedMessage(&buffer, .register, "c0", "5e", "{}"));
    // A withdrawal signs an empty body.
    try std.testing.expectEqualStrings("OpenReliant Directory v1\nwithdraw\nc0\n5e\n", try signedMessage(&buffer, .withdraw, "c0", "5e", ""));
    try std.testing.expectError(error.NoSpaceLeft, signedMessage(&buffer, .register, "c0", "5e", &@as([signed_capacity]u8, @splat('x'))));
}

fn post(client: *std.http.Client, url: []const u8, payload: []const u8, headers: []const std.http.Header, response: *std.Io.Writer) !std.http.Status {
    const uri = try web.secured(try std.Uri.parse(url), .of(url));
    const result = try client.fetch(.{ .location = .{ .uri = uri }, .method = .POST, .payload = payload, .redirect_behavior = .unhandled, .extra_headers = headers, .response_writer = response });
    return result.status;
}

config: Config,
key: KeyPair,
session: [16]u8,
download: web.Download(Job) = .{},
/// The rendezvous a host behind a router takes players through, and how far it has got.
signals: ?*Rendezvous = null,
signalling: Signalling = .off,
/// The listener for the connections that come through ICE, beside the host's IP one.
ice_listener: u32 = 0,
/// Whether the directory's last answer registered the host for rendezvous, which is when its
/// invite works. Null until it has answered.
registered: ?bool = null,
next: i64 = 0,
revision: u64 = 0,
last: ?Snapshot = null,
next_change: i64 = 0,

pub fn init(io: std.Io, config: Config, server: *const identity.Server) !Publisher {
    var session: [16]u8 = undefined;
    try io.randomSecure(&session);
    return .{ .config = config, .key = server.issuer, .session = session };
}

const Signalling = enum {
    /// The host is reached at its address.
    off,
    /// The directory is being asked whether it takes rendezvous.
    starting,
    /// The host listens for ICE connections and passes their signals.
    listening,
    /// The directory offers no rendezvous, or can't be reached.
    unavailable,
};

/// Brings the rendezvous up and hands the transport the signals it brought.
fn signal(publisher: *Publisher) void {
    switch (publisher.signalling) {
        .off => {
            if (!publisher.config.rendezvous) return;
            const origin = publisher.config.first() orelse {
                publisher.signalling = .unavailable;
                return;
            };
            publisher.signals = Rendezvous.create(origin, .host) catch |err| {
                std.log.warn("rendezvous could not start: {t}", .{err});
                publisher.signalling = .unavailable;
                return;
            };
            publisher.signalling = .starting;
        },
        .starting => switch (publisher.signals.?.state.load(.acquire)) {
            .starting => {},
            .failed => {
                std.log.warn("the directory offers no rendezvous: players need the host's address and a forwarded port", .{});
                publisher.endSignals();
                publisher.signalling = .unavailable;
            },
            .ready => {
                // A host that opens itself again takes its players through the listener it has.
                if (!net.session_ice_enable(publisher.signals.?.stun().?, publisher.signals.?.local)) {
                    publisher.ice_listener = 0;
                } else if (publisher.ice_listener == 0) publisher.ice_listener = net.session_ice_listen();
                if (publisher.ice_listener == 0) {
                    std.log.warn("the transport could not listen for ICE connections", .{});
                    publisher.endSignals();
                    publisher.signalling = .unavailable;
                    return;
                }
                publisher.signalling = .listening;
                // Publish again at once, now with the rendezvous fields.
                publisher.next = 0;
            },
        },
        .listening => publisher.signals.?.pump(),
        .unavailable => {},
    }
}

/// How far the host's invite has got, for a screen to show.
pub const Sharing = enum { preparing, unavailable, ready };

pub fn sharing(publisher: *const Publisher) Sharing {
    return switch (publisher.signalling) {
        .unavailable => .unavailable,
        .off, .starting => .preparing,
        .listening => if (publisher.registered) |registered| (if (registered) .ready else .unavailable) else .preparing,
    };
}

/// Lists the game or takes it off the list, for a host that changes its mind while it runs.
pub fn setUnlisted(publisher: *Publisher, unlisted: bool) void {
    if (publisher.config.unlisted == unlisted) return;
    publisher.config.unlisted = unlisted;
    // Publish again at once.
    publisher.next = 0;
}

/// Takes the ICE listener out of the publisher, so that `close` leaves it open. The transport
/// drops every connection that came through a listener when it closes, and a host that goes
/// back to a LAN game keeps the players it has. The caller closes it, or gives it to the next
/// publisher in `ice_listener`.
pub fn keepListener(publisher: *Publisher) u32 {
    defer publisher.ice_listener = 0;
    return publisher.ice_listener;
}

fn endSignals(publisher: *Publisher) void {
    if (publisher.signals) |signals| signals.destroy();
    publisher.signals = null;
}

/// The invite that brings a player to this host through the directory's rendezvous, once the
/// host is listed there: what the host hands to the players it wants.
pub fn invite(publisher: *const Publisher, buffer: []u8) ?[]const u8 {
    if (publisher.signalling != .listening or publisher.registered != true) return null;
    const shared: identity.RendezvousInvite = .{ .origin = publisher.config.first() orelse return null, .key = publisher.key.public_key, .session = publisher.session };
    return std.fmt.bufPrint(buffer, "{f}", .{shared}) catch null;
}

pub fn tick(publisher: *Publisher, host: *const Host, now: i64) void {
    publisher.signal();
    if (publisher.download.take()) |answer| {
        if (answer) |token| {
            if (publisher.signalling == .listening) {
                publisher.signals.?.setToken(token);
                publisher.registered = token != null;
            }
        } else |err| std.log.warn("directory advertisement failed: {t}", .{err});
    }
    if (publisher.download.busy()) return;
    // A game for invited players only is published once it can be reached through rendezvous,
    // and nowhere before that: published plainly, it would be listed. Nor is a player's own
    // game, which has no forwarded port to be reached at.
    if ((publisher.config.unlisted or publisher.config.hosting == .player_hosted) and publisher.signalling != .listening) return;
    if (publisher.signalling == .starting) return;
    const current = Snapshot.of(host);
    if (!due(publisher.last, current, now, publisher.next, publisher.next_change)) return;
    publisher.next = now + 30 * std.time.us_per_s;
    publisher.next_change = now + std.time.us_per_s;
    publisher.send(current) catch |err| {
        std.log.warn("could not start directory advertisement: {t}", .{err});
        return;
    };
    publisher.last = current;
}

fn due(previous: ?Snapshot, current: Snapshot, now: i64, next: i64, next_change: i64) bool {
    const changed = if (previous) |last| !std.meta.eql(last, current) else true;
    return now >= next or (changed and now >= next_change);
}

test "player changes publish promptly without allowing rapid churn" {
    const empty: Snapshot = .{ .players = 0, .capacity = 8, .scenario = .tag_bomb, .accepting = true };
    var joined = empty;
    joined.players = 1;
    try std.testing.expect(due(null, empty, 0, 0, 0));
    try std.testing.expect(!due(empty, joined, 500_000, 30_000_000, 1_000_000));
    try std.testing.expect(due(empty, joined, 1_000_000, 30_000_000, 1_000_000));
    try std.testing.expect(due(joined, empty, 2_000_000, 31_000_000, 2_000_000));
    try std.testing.expect(!due(empty, empty, 29_000_000, 30_000_000, 1_000_000));
    try std.testing.expect(due(empty, empty, 30_000_000, 30_000_000, 1_000_000));
}

fn send(publisher: *Publisher, snapshot: Snapshot) !void {
    var arena = std.heap.ArenaAllocator.init(web.allocator);
    var owned = true;
    errdefer if (owned) arena.deinit();
    const allocator = arena.allocator();
    const through_rendezvous = publisher.signalling == .listening;
    // Through rendezvous the host publishes to that one directory.
    const origins = try allocator.dupe(u8, if (through_rendezvous) publisher.config.first().? else publisher.config.origins);
    publisher.revision += 1;
    const mode = if (snapshot.scenario) |chosen| mode: {
        const id = try allocator.dupe(u8, @tagName(chosen));
        for (id) |*character| if (character.* == '_') {
            character.* = '-';
        };
        break :mode .{ .id = id, .name = chosen.record().name };
    } else null;
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .game = .{ .id = "org.openreliant.starlancer", .name = "StarLancer" },
        .revision = publisher.revision,
        .name = publisher.config.name,
        .description = publisher.config.description,
        .hosting = publisher.config.hosting,
        .mode = mode,
        .players = snapshot.players,
        .capacity = snapshot.capacity,
        .accepting = snapshot.accepting,
        .protocol = wire.revision,
        .release = version.string,
        .port = publisher.config.port,
        .address = publisher.config.address,
        // A directory that doesn't know these fields refuses the advertisement, so they go only
        // to one that said it takes rendezvous.
        .rendezvous = if (through_rendezvous) true else null,
        .unlisted = if (through_rendezvous and publisher.config.unlisted) true else null,
    }, .{ .emit_null_optional_fields = false });
    owned = false;
    try publisher.download.start(.{ .arena = arena, .origins = origins, .body = body, .key = publisher.key, .session = publisher.session, .takes_token = through_rendezvous }, .{ .whole = .fromSeconds(15) });
}

/// How long `close` waits for an update on its way to stop: 50 polls of 10 ms.
const update_stop_polls = 50;
const update_stop_poll_ms = 10;

/// Stops publishing. If the host was ever listed, it first asks each directory to withdraw the
/// listing, so a stopped server doesn't stay in players' lists until its lease runs out. Each
/// directory gets a short time (`Operation.deadline`), and a failure is only logged.
pub fn close(publisher: *Publisher, io: std.Io) void {
    // An update still on its way could list the host again after the withdrawal, so it gets a
    // moment to stop first.
    publisher.download.cancel();
    for (0..update_stop_polls) |_| {
        if (!publisher.download.busy() or publisher.download.take() != null) break;
        io.sleep(.fromMilliseconds(update_stop_poll_ms), .awake) catch break;
    }
    publisher.download.abandon();
    if (publisher.last != null) {
        // Through rendezvous the host is known to the first directory alone.
        const origins = if (publisher.signalling == .listening) publisher.config.first().? else publisher.config.origins;
        var job: Job = .{ .arena = .init(web.allocator), .origins = origins, .body = "", .key = publisher.key, .session = publisher.session };
        defer job.deinit();
        job.sendAll(io, .withdraw);
    }
    publisher.endSignals();
    if (publisher.ice_listener != 0) net.session_listen_close(publisher.ice_listener);
    publisher.ice_listener = 0;
    publisher.signalling = .off;
    std.crypto.secureZero(u8, std.mem.asBytes(&publisher.key));
}
