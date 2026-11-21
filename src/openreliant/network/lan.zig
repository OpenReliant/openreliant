//! Finding games on the local network.
//!
//! The original lists LAN games through DirectPlay: `directplay_enum_sessions` (`0x004BC470`)
//! asks for the sessions of the game's application GUID, and `directplay_join_session`
//! (`0x004BC720`) joins one of them ([Front end](../../../docs/engine/front-end.md#lan-games)).
//! OpenReliant has no DirectPlay, so it does the same with its own datagrams. The browser sends
//! a query to the local network's broadcast address, and every host that would take a new pilot
//! answers it. **Improvement:** OpenReliant's own protocol in place of DirectPlay's.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const net = Io.net;
const engine = @import("openreliant").engine;
const web = engine.web;
const Connection = engine.game.interface.Connection;
const identity = @import("identity.zig");

/// The UDP port hosts listen on for queries, next to the game's own (`session.default_port`).
pub const port: u16 = 27021;
/// How long the browser waits for answers to one query.
const answer_wait_us = 600 * std.time.us_per_ms;
/// The most games one search lists. The original keeps ten (`directplay_enum_session_callback`).
/// **Improvement:** a larger list, so a busy network's games don't vanish.
const max_games = 64;
/// The most queries a host answers in one pass of its loop.
const answers_per_poll = 8;

const query_magic = "ORLQ".*;
const answer_magic = "ORLA".*;
/// The longest name or mode an answer carries.
const max_text = 32;
const answer_header = query_magic.len + @sizeOf(u32) + 2 * @sizeOf(u16) + 2 + identity.PublicKey.encoded_length;
/// The largest answer.
pub const max_answer = answer_header + 2 * (1 + max_text);
/// A query's size. A query is padded to at least an answer's size, so that a host never sends
/// more than it receives and can't be used to flood another address.
pub const query_size = 128;

comptime {
    assert(max_answer <= query_size);
}

/// A query: the magic and a nonce the answers repeat, then padding.
pub fn query(nonce: u32) [query_size]u8 {
    var packet: [query_size]u8 = @splat(0);
    packet[0..4].* = query_magic;
    std.mem.writeInt(u32, packet[4..8], nonce, .little);
    return packet;
}

/// The nonce of a query, or null for anything else.
fn queryNonce(packet: []const u8) ?u32 {
    if (packet.len != query_size or !std.mem.eql(u8, packet[0..4], &query_magic)) return null;
    return std.mem.readInt(u32, packet[4..8], .little);
}

/// Short text in an answer.
pub const Text = struct {
    bytes: [max_text]u8 = undefined,
    len: u8 = 0,

    /// The first `max_text` bytes of `text`.
    pub fn of(text: []const u8) Text {
        var result: Text = .{};
        result.len = @intCast(@min(text.len, max_text));
        @memcpy(result.bytes[0..result.len], text[0..result.len]);
        return result;
    }

    pub fn slice(text: *const Text) []const u8 {
        return text.bytes[0..text.len];
    }
};

/// What a host tells the browser about its game.
pub const Answer = struct {
    nonce: u32,
    protocol: u16,
    /// The port the game listens on.
    game_port: u16,
    players: u8,
    capacity: u8,
    key: [identity.PublicKey.encoded_length]u8,
    name: Text,
    mode: Text,

    pub fn encode(answer: *const Answer, buffer: *[max_answer]u8) []const u8 {
        var writer: Io.Writer = .fixed(buffer);
        writer.writeAll(&answer_magic) catch unreachable;
        writer.writeInt(u32, answer.nonce, .little) catch unreachable;
        writer.writeInt(u16, answer.protocol, .little) catch unreachable;
        writer.writeInt(u16, answer.game_port, .little) catch unreachable;
        writer.writeByte(answer.players) catch unreachable;
        writer.writeByte(answer.capacity) catch unreachable;
        writer.writeAll(&answer.key) catch unreachable;
        for ([_]*const Text{ &answer.name, &answer.mode }) |text| {
            writer.writeByte(text.len) catch unreachable;
            writer.writeAll(text.slice()) catch unreachable;
        }
        return writer.buffered();
    }

    /// The answer in `packet`, or null where it isn't a whole, valid one.
    pub fn decode(packet: []const u8) ?Answer {
        if (packet.len < answer_header or packet.len > max_answer) return null;
        if (!std.mem.eql(u8, packet[0..4], &answer_magic)) return null;
        var answer: Answer = .{
            .nonce = std.mem.readInt(u32, packet[4..8], .little),
            .protocol = std.mem.readInt(u16, packet[8..10], .little),
            .game_port = std.mem.readInt(u16, packet[10..12], .little),
            .players = packet[12],
            .capacity = packet[13],
            .key = packet[14..answer_header].*,
            .name = .{},
            .mode = .{},
        };
        var rest = packet[answer_header..];
        for ([_]*Text{ &answer.name, &answer.mode }) |text| {
            if (rest.len == 0 or rest[0] > max_text or rest.len - 1 < rest[0]) return null;
            text.* = .of(rest[1..][0..rest[0]]);
            rest = rest[1 + rest[0] ..];
        }
        if (rest.len != 0 or answer.game_port == 0 or answer.capacity == 0 or answer.players > answer.capacity) return null;
        if (answer.name.len == 0) return null;
        return answer;
    }
};

/// Whether an address belongs to the local network: loopback, the private IPv4 ranges,
/// link-local, or an IPv6 unique local address. `bytes` holds an IPv6 address, an IPv4 one mapped
/// into it.
pub fn isLan(bytes: [16]u8) bool {
    const ipv6: net.Ip6Address = .{ .bytes = bytes, .port = 0 };
    if (net.Ip4Address.fromIp6(ipv6)) |ipv4| {
        const first, const second, _, _ = ipv4.bytes;
        return first == 127 or first == 10 or (first == 172 and second >= 16 and second <= 31) or
            (first == 192 and second == 168) or (first == 169 and second == 254);
    }
    return ipv6.isLoopBack() or ipv6.isLinkLocal() or bytes[0] & 0xfe == 0xfc;
}

fn isLanAddress(address: net.IpAddress) bool {
    return isLan(net.Ip6Address.fromAny(address).bytes);
}

/// What a host answers with, while it takes new pilots.
pub const Game = struct {
    protocol: u16,
    game_port: u16,
    players: u8,
    capacity: u8,
    key: identity.PublicKey,
    name: []const u8,
    mode: []const u8,
};

/// A host's end: a socket on `port` that answers the browsers' queries.
pub const Responder = struct {
    socket: net.Socket,

    pub fn open(io: Io) !Responder {
        const any = try net.IpAddress.parse("0.0.0.0", port);
        return .{ .socket = try any.bind(io, .{ .mode = .dgram }) };
    }

    pub fn close(responder: *Responder, io: Io) void {
        responder.socket.close(io);
    }

    /// Answers the queries waiting, a few at a time, without waiting for more. A host that takes
    /// no new pilots (`game` null) reads them and says nothing, as DirectPlay lists only the
    /// sessions that do (`directplay_enum_sessions`). Only queries from the local network are
    /// answered.
    pub fn poll(responder: *Responder, io: Io, game: ?Game) void {
        var packet: [query_size]u8 = undefined;
        for (0..answers_per_poll) |_| {
            const message = responder.socket.receiveTimeout(io, &packet, .{ .duration = .{ .raw = .zero, .clock = .awake } }) catch return;
            if (message.flags.trunc) continue;
            const nonce = queryNonce(message.data) orelse continue;
            const listed = game orelse continue;
            if (!isLanAddress(message.from)) continue;
            const answer: Answer = .{
                .nonce = nonce,
                .protocol = listed.protocol,
                .game_port = listed.game_port,
                .players = listed.players,
                .capacity = listed.capacity,
                .key = listed.key.toBytes(),
                .name = .of(listed.name),
                .mode = .of(listed.mode),
            };
            var buffer: [max_answer]u8 = undefined;
            responder.socket.send(io, &message.from, answer.encode(&buffer)) catch {};
        }
    }
};

const Result = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Connection.Server,

    fn deinit(result: *Result) void {
        result.arena.deinit();
    }
};

/// Collects the answers to one query into the browser's rows.
const Found = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayList(Connection.Server) = .empty,
    keys: std.ArrayList([identity.PublicKey.encoded_length]u8) = .empty,

    /// Adds the game `answer` describes, from `from`, once. A host on the same machine answers
    /// both the broadcast and the loopback query, under one key.
    fn add(found: *Found, from: net.IpAddress, answer: Answer, ping_ms: u16) !void {
        if (found.rows.items.len >= max_games or !isLanAddress(from)) return;
        for (found.keys.items) |key| if (std.mem.eql(u8, &key, &answer.key)) return;
        var address = from;
        address.setPort(answer.game_port);
        const key = identity.PublicKey.fromBytes(answer.key) catch return;
        const target = try std.fmt.allocPrint(found.allocator, "{f}", .{identity.Invite{ .address = address, .key = key }});
        try found.rows.append(found.allocator, .{
            .name = try found.allocator.dupe(u8, answer.name.slice()),
            .description = "",
            .mode = try found.allocator.dupe(u8, answer.mode.slice()),
            .players = answer.players,
            .capacity = answer.capacity,
            .ping_ms = ping_ms,
            .target = target,
            .protocol = answer.protocol,
        });
        try found.keys.append(found.allocator, answer.key);
    }
};

const Job = struct {
    pub fn discard(result: Result) void {
        var owned = result;
        owned.deinit();
    }

    pub fn run(job: *Job, io: Io, progress: *web.Progress) !Result {
        _ = job;
        _ = progress;
        var arena = std.heap.ArenaAllocator.init(web.allocator);
        errdefer arena.deinit();
        var found: Found = .{ .allocator = arena.allocator() };
        const any = try net.IpAddress.parse("0.0.0.0", 0);
        const socket = try any.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
        defer socket.close(io);
        var nonce: u32 = 0;
        try io.randomSecure(std.mem.asBytes(&nonce));
        const packet = query(nonce);
        const sent = Io.Clock.awake.now(io).toMicroseconds();
        // The broadcast reaches the other machines, and loopback a host on this one. Either may
        // fail, such as without a network.
        var reached = false;
        for ([_][]const u8{ "255.255.255.255", "127.0.0.1" }) |text| {
            const to = try net.IpAddress.parse(text, port);
            socket.send(io, &to, &packet) catch continue;
            reached = true;
        }
        if (!reached) return error.NetworkUnreachable;
        const end = sent + answer_wait_us;
        var buffer: [max_answer + 1]u8 = undefined;
        while (true) {
            const now = Io.Clock.awake.now(io).toMicroseconds();
            if (now >= end) break;
            const message = socket.receiveTimeout(io, &buffer, .{ .duration = .{ .raw = .fromMicroseconds(end - now), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => break,
                else => return err,
            };
            const answer = Answer.decode(message.data) orelse continue;
            if (answer.nonce != nonce) continue;
            const elapsed = Io.Clock.awake.now(io).toMicroseconds() - sent;
            const ping: u16 = @intCast(@min(std.math.maxInt(u16), @divTrunc(elapsed + 500, std.time.us_per_ms)));
            try found.add(message.from, answer, ping);
        }
        return .{ .arena = arena, .rows = try found.rows.toOwnedSlice(found.allocator) };
    }
};

/// The browser's end: searches the local network for games on a thread of its own, and lists them
/// on the LAN page.
pub const Browser = struct {
    search: web.Download(Job) = .{},
    result: ?Result = null,

    pub fn refresh(browser: *Browser) void {
        if (browser.search.busy()) return;
        browser.search.start(.{}, .{ .whole = .fromSeconds(5) }) catch |err| std.log.warn("could not search the local network: {t}", .{err});
    }

    pub fn poll(browser: *Browser, screen: *Connection) void {
        const answer = browser.search.take() orelse return;
        const found = answer catch |err| {
            std.log.warn("could not search the local network: {t}", .{err});
            return;
        };
        // The screen still shows the previous rows until it has the new ones.
        screen.replaceListings(.lan, found.rows);
        if (browser.result) |*previous| previous.deinit();
        browser.result = found;
    }

    pub fn close(browser: *Browser) void {
        browser.search.abandon();
        if (browser.result) |*result| result.deinit();
    }
};

test "a query and an answer round-trip, and malformed packets are refused" {
    const packet = query(0xA1B2C3D4);
    try std.testing.expectEqual(@as(?u32, 0xA1B2C3D4), queryNonce(&packet));
    try std.testing.expectEqual(@as(?u32, null), queryNonce(packet[0..64]));

    const key: [identity.PublicKey.encoded_length]u8 = @splat(7);
    const answer: Answer = .{ .nonce = 5, .protocol = 37, .game_port = 27020, .players = 2, .capacity = 8, .key = key, .name = .of("Rook"), .mode = .of("Asteroid Field") };
    var buffer: [max_answer]u8 = undefined;
    const bytes = answer.encode(&buffer);
    try std.testing.expect(bytes.len <= query_size);
    const back = Answer.decode(bytes).?;
    try std.testing.expectEqual(37, back.protocol);
    try std.testing.expectEqual(27020, back.game_port);
    try std.testing.expectEqualStrings("Rook", back.name.slice());
    try std.testing.expectEqualStrings("Asteroid Field", back.mode.slice());

    // Cut short, padded, or with more pilots than places, it is not an answer.
    try std.testing.expectEqual(null, Answer.decode(bytes[0 .. bytes.len - 1]));
    var longer: [max_answer + 1]u8 = undefined;
    @memcpy(longer[0..bytes.len], bytes);
    longer[bytes.len] = 0;
    try std.testing.expectEqual(null, Answer.decode(longer[0 .. bytes.len + 1]));
    var crowded = answer;
    crowded.players = 9;
    try std.testing.expectEqual(null, Answer.decode(crowded.encode(&buffer)));
}

test "the local network's addresses" {
    const allowed = [_][]const u8{ "127.0.0.1", "::1", "10.0.1.7", "172.31.0.2", "192.168.1.9", "169.254.1.2", "fe80::1", "fd12::8" };
    for (allowed) |ip| try std.testing.expect(isLanAddress(try net.IpAddress.parse(ip, 0)));
    const denied = [_][]const u8{ "192.0.2.1", "172.32.1.1", "2001:db8::1", "::", "0.0.0.0", "8.8.8.8" };
    for (denied) |ip| try std.testing.expect(!isLanAddress(try net.IpAddress.parse(ip, 0)));
}

test "a game is listed once per host, as an invite to its game port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var found: Found = .{ .allocator = arena.allocator() };
    const pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(3)) catch unreachable;
    const answer: Answer = .{ .nonce = 1, .protocol = 37, .game_port = 27020, .players = 1, .capacity = 4, .key = pair.public_key.toBytes(), .name = .of("Rook"), .mode = .of("Co-op") };
    try found.add(try net.IpAddress.parse("192.168.1.9", 50000), answer, 3);
    try found.add(try net.IpAddress.parse("127.0.0.1", 50000), answer, 1);
    // Nor is a game answering from outside the local network.
    var other = answer;
    other.key = (std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(4)) catch unreachable).public_key.toBytes();
    try found.add(try net.IpAddress.parse("8.8.8.8", 50000), other, 1);
    try std.testing.expectEqual(1, found.rows.items.len);
    const row = found.rows.items[0];
    try std.testing.expectEqual(3, row.ping_ms.?);
    const invite = try identity.Invite.parse(row.target);
    try std.testing.expectEqual(27020, invite.address.getPort());
    try std.testing.expect(invite.address.eql(&try net.IpAddress.parse("192.168.1.9", 27020)));
}

test "a host answers a query on loopback, and stays quiet while it takes no one" {
    const io = std.testing.io;
    var responder = Responder.open(io) catch return error.SkipZigTest;
    defer responder.close(io);
    const any = try net.IpAddress.parse("127.0.0.1", 0);
    const socket = try any.bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    const to = try net.IpAddress.parse("127.0.0.1", port);
    const pair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(5)) catch unreachable;
    const game: Game = .{ .protocol = 37, .game_port = 27020, .players = 1, .capacity = 8, .key = pair.public_key, .name = "Rook", .mode = "Asteroid Field" };
    var buffer: [max_answer + 1]u8 = undefined;
    const wait: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } };

    const closed = query(1);
    try socket.send(io, &to, &closed);
    try io.sleep(.fromMilliseconds(20), .awake);
    responder.poll(io, null);
    try std.testing.expectError(error.Timeout, socket.receiveTimeout(io, &buffer, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }));

    const asked = query(2);
    try socket.send(io, &to, &asked);
    try io.sleep(.fromMilliseconds(20), .awake);
    responder.poll(io, game);
    const message = try socket.receiveTimeout(io, &buffer, wait);
    const answer = Answer.decode(message.data).?;
    try std.testing.expectEqual(2, answer.nonce);
    try std.testing.expectEqualStrings("Rook", answer.name.slice());
}
