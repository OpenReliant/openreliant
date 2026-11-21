//! Measure direct game-port latency without admitting a player.
//!
//! GameNetworkingSockets 1.6.1 answers a padded UDP challenge before allocating a connection.
//! Keep this small adapter with the transport pin. A reply is only a latency hint, not proof of
//! the server's identity; joining still authenticates the advertised key and session.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Connection = @import("openreliant").engine.game.interface.Connection;
const DirectoryInvite = @import("identity.zig").DirectoryInvite;

const max_probes = 256;
const max_per_address = 16;
const deadline_us = 800 * std.time.us_per_ms;
const request_size = 512;
const Probe = struct { address: net.IpAddress, nonce: u32, sent: i64, row: usize, done: bool = false };

fn request(nonce: u32) [request_size]u8 {
    var packet: [request_size]u8 = @splat(0);
    packet[0] = 32; // ChallengeRequest.
    packet[1] = 5; // A fixed32 connection id in the protobuf body.
    packet[3] = 0x0d;
    std.mem.writeInt(u32, packet[4..8], nonce, .little);
    return packet;
}

// Parse bounded protobuf fields instead of trusting the ordering of a remote reply.
fn replyNonce(packet: []const u8) ?u32 {
    if (packet.len < 2 or packet[0] != 33) return null;
    var offset: usize = 1;
    while (offset < packet.len) {
        const key = varint(packet, &offset) orelse return null;
        const field = key >> 3;
        const kind = key & 7;
        if (field == 0) return null;
        switch (kind) {
            0 => _ = varint(packet, &offset) orelse return null,
            1 => {
                if (packet.len - offset < 8) return null;
                offset += 8;
            },
            2 => {
                const n = varint(packet, &offset) orelse return null;
                if (n > packet.len - offset) return null;
                offset += @intCast(n);
            },
            5 => {
                if (packet.len - offset < 4) return null;
                const value = std.mem.readInt(u32, packet[offset..][0..4], .little);
                offset += 4;
                if (field == 1) return value;
            },
            else => return null,
        }
    }
    return null;
}

fn varint(bytes: []const u8, offset: *usize) ?u64 {
    var value: u64 = 0;
    for (0..10) |i| {
        if (offset.* >= bytes.len) return null;
        const byte = bytes[offset.*];
        offset.* += 1;
        if (i == 9 and byte > 1) return null;
        value |= @as(u64, byte & 0x7f) << @as(u6, @intCast(i * 7));
        if (byte & 0x80 == 0) return value;
    }
    return null;
}

// An untrusted directory must not make the browser send packets to private or special networks.
fn publicAddress(address: net.IpAddress) ?net.IpAddress {
    if (net.Ip4Address.fromAny(address)) |ip| {
        const a, const b, const c, _ = ip.bytes;
        if (a == 0 or a == 10 or a == 127 or a >= 224) return null;
        if ((a == 100 and b >= 64 and b < 128) or (a == 169 and b == 254) or
            (a == 172 and b >= 16 and b < 32) or (a == 192 and b == 168) or
            (a == 192 and (b == 0 or (b == 88 and c == 99))) or
            (a == 198 and (b == 18 or b == 19 or (b == 51 and c == 100))) or
            (a == 203 and b == 0 and c == 113)) return null;
        return .{ .ip4 = ip };
    }
    const ip = address.ip6;
    const a, const b, const c, const d = ip.bytes[0..4].*;
    if (a & 0xe0 != 0x20 or (a == 0x20 and b == 2)) return null;
    if ((a == 0x20 and b == 1 and (c < 2 or (c == 0x0d and d == 0xb8))) or
        (a == 0x3f and b == 0xff and c < 16) or ip.interface.index != 0) return null;
    return address;
}

pub fn measure(io: Io, rows: []Connection.Server) void {
    measureFamily(io, rows, .ip4);
    measureFamily(io, rows, .ip6);
}

fn measureFamily(io: Io, rows: []Connection.Server, family: std.meta.Tag(net.IpAddress)) void {
    var probes: [max_probes]Probe = undefined;
    var count: usize = 0;
    for (rows, 0..) |row, index| {
        if (count == probes.len) break;
        const entry = DirectoryInvite.parse(row.target) catch continue;
        const address = publicAddress(entry.invite.address) orelse continue;
        if (std.meta.activeTag(address) != family) continue;
        var host = address;
        host.setPort(0);
        var same_host: usize = 0;
        var duplicate = false;
        for (probes[0..count]) |probe| {
            if (probe.address.eql(&address)) {
                duplicate = true;
                break;
            }
            var other = probe.address;
            other.setPort(0);
            if (host.eql(&other)) same_host += 1;
        }
        if (duplicate or same_host >= max_per_address) continue;
        var nonce: u32 = 0;
        io.randomSecure(std.mem.asBytes(&nonce)) catch continue;
        if (nonce == 0) nonce = 1;
        probes[count] = .{ .address = address, .nonce = nonce, .sent = 0, .row = index };
        count += 1;
    }
    if (count == 0) return;
    const bind = net.IpAddress.parse(if (family == .ip4) "0.0.0.0" else "::", 0) catch return;
    const socket = bind.bind(io, .{ .mode = .dgram }) catch return;
    defer socket.close(io);
    for (probes[0..count]) |*probe| {
        const packet = request(probe.nonce);
        probe.sent = Io.Clock.awake.now(io).toMicroseconds();
        socket.send(io, &probe.address, &packet) catch {
            probe.done = true;
        };
    }
    const end = Io.Clock.awake.now(io).toMicroseconds() + deadline_us;
    var bytes: [1024]u8 = undefined;
    while (true) {
        var outstanding = false;
        for (probes[0..count]) |probe| if (!probe.done) {
            outstanding = true;
            break;
        };
        if (!outstanding) break;
        const remaining = end - Io.Clock.awake.now(io).toMicroseconds();
        if (remaining <= 0) break;
        const message = socket.receiveTimeout(io, &bytes, .{ .duration = .{ .raw = .fromMicroseconds(remaining), .clock = .awake } }) catch break;
        if (message.flags.trunc) continue;
        const nonce = replyNonce(message.data) orelse continue;
        for (probes[0..count]) |*probe| {
            if (probe.done or probe.nonce != nonce or !probe.address.eql(&message.from)) continue;
            const elapsed = @max(0, Io.Clock.awake.now(io).toMicroseconds() - probe.sent);
            const ping: u16 = @intCast(@min(std.math.maxInt(u16), @divTrunc(elapsed + 500, 1000)));
            rows[probe.row].ping_ms = ping;
            for (rows[probe.row + 1 ..]) |*row| {
                const listing = DirectoryInvite.parse(row.target) catch continue;
                if (probe.address.eql(&listing.invite.address)) row.ping_ms = ping;
            }
            probe.done = true;
            break;
        }
    }
}

test "transport challenges and replies are bounded" {
    const packet = request(0x12345678);
    try std.testing.expectEqual(512, packet.len);
    try std.testing.expectEqualSlices(u8, &.{ 32, 5, 0, 13, 0x78, 0x56, 0x34, 0x12 }, packet[0..8]);
    try std.testing.expectEqual(@as(?u32, 0x12345678), replyNonce(&.{ 33, 13, 0x78, 0x56, 0x34, 0x12 }));
    try std.testing.expectEqual(@as(?u32, null), replyNonce(&.{ 33, 13, 0x78 }));
    try std.testing.expectEqual(@as(?u32, null), replyNonce(&.{ 33, 0x12, 0xff, 0xff }));
    try std.testing.expect(publicAddress(try net.IpAddress.parse("127.0.0.1", 27020)) == null);
    try std.testing.expect(publicAddress(try net.IpAddress.parse("8.8.8.8", 27020)) != null);
}
