//! A direct-IP host. Only the game thread admits pilots and applies their commands.
const std = @import("std");
const Io = std.Io;
const wire = @import("wire.zig");
const net = @import("transport.zig");
const Arena = @import("arena.zig");
const Host = @This();

const timeout = 5 * std.time.us_per_s;
const handshake_starts = 4;
const packets_per_tick = 4;
const max_identity = 32;
const pilots_to_start = 2;

const Peer = struct {
    conn: net.Connection,
    state: enum { connecting, joining, playing, rejecting } = .connecting,
    identity: [max_identity]u8 = undefined,
    identity_len: u8 = 0,
    expires: i64,
    sequence: ?u32 = null,
};

io: Io,
arena: Arena,
peers: [wire.slots]?Peer = @splat(null),
starts: [handshake_starts]i64 = @splat(std.math.minInt(i64)),
next_start: usize = 0,
finishing: bool = false,

fn now(host: *const Host) i64 {
    return Io.Clock.awake.now(host.io).toMicroseconds();
}

fn release(host: *Host, slot: u8) void {
    const peer = host.peers[slot] orelse return;
    if (host.arena.pilots[slot]) |pilot| {
        std.debug.print("left {d} {d}\n", .{ slot, pilot.participant.generation });
        host.arena.leave(slot);
    }
    host.peers[slot] = null;
    net.session_close(peer.conn);
}

pub fn status(host: *Host, conn: net.Connection, event: net.Status, name: ?[]const u8) void {
    switch (event) {
        .incoming => {
            for (host.peers) |peer| if (peer != null and peer.?.conn == conn) return;
            const time = host.now();
            if (!host.finishing and time -| host.starts[host.next_start] >= std.time.us_per_s) {
                for (&host.peers) |*peer| {
                    if (peer.* != null) continue;
                    host.starts[host.next_start] = time;
                    host.next_start = (host.next_start + 1) % host.starts.len;
                    if (net.session_accept(conn)) {
                        peer.* = .{ .conn = conn, .expires = time + timeout };
                        return;
                    }
                    break;
                }
            }
        },
        .authenticated => {
            if (name) |identity| {
                if (identity.len <= max_identity and !host.hasName(identity)) {
                    for (&host.peers) |*entry| {
                        const peer = if (entry.*) |*peer| peer else continue;
                        if (peer.conn != conn or peer.state != .connecting) continue;
                        @memcpy(peer.identity[0..identity.len], identity);
                        peer.identity_len = @intCast(identity.len);
                        peer.state = .joining;
                        return;
                    }
                }
            }
        },
        .closed => {},
    }
    for (host.peers, 0..) |entry, slot| {
        if (entry != null and entry.?.conn == conn) {
            host.release(@intCast(slot));
            return;
        }
    }
    net.session_close(conn);
}

fn hasName(host: *const Host, name: []const u8) bool {
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.state != .connecting and std.mem.eql(u8, peer.identity[0..peer.identity_len], name)) return true;
    }
    return false;
}

fn receive(host: *Host, slot: u8, peer: *Peer, message: wire.Message, time: i64) !bool {
    if (message == .leave) return false;
    switch (peer.state) {
        .joining => {
            if (host.finishing or message != .join) return false;
            if (!message.join.compatible()) {
                try net.send(peer.conn, .{ .wrong_protocol = .local });
                peer.state = .rejecting;
                return true;
            }
            const admitted = try host.arena.join(slot);
            peer.state = .playing;
            peer.expires = time + timeout;
            try net.send(peer.conn, .{ .joined = admitted });
            std.debug.print("joined {d} {d}\n", .{ slot, admitted.generation });
            return true;
        },
        .playing => {
            if (message != .input) return false;
            if (host.finishing) return true;
            const input = message.input;
            if (peer.sequence) |accepted| if (@as(i32, @bitCast(input.sequence -% accepted)) <= 0) return true;
            if (!host.arena.input(slot, input.steering)) return false;
            peer.sequence = input.sequence;
            peer.expires = time + timeout;
            return true;
        },
        .connecting, .rejecting => return false,
    }
}

fn service(host: *Host, slot: u8, time: i64) !void {
    const peer = if (host.peers[slot]) |*peer| peer else return;
    if (time >= peer.expires or (peer.state == .rejecting and net.session_delivered(peer.conn))) {
        host.release(slot);
        return;
    }
    if (peer.state == .connecting or peer.state == .rejecting) return;
    var buf: [wire.capacity]u8 = undefined;
    for (0..packets_per_tick) |_| {
        const message = net.receive(peer.conn, &buf) catch {
            host.release(slot);
            return;
        } orelse return;
        const keep = host.receive(slot, peer, message, time) catch |err| switch (err) {
            error.SendFailed => false,
            else => return err,
        };
        if (!keep) {
            host.release(slot);
            return;
        }
        if (peer.state == .rejecting) return;
    }
}

fn broadcast(host: *Host, message: wire.Message) !void {
    for (host.peers, 0..) |entry, slot| {
        const peer = entry orelse continue;
        if (peer.state != .playing) continue;
        net.send(peer.conn, message) catch |err| switch (err) {
            error.SendFailed => if (message == .finished) host.release(@intCast(slot)),
            else => return err,
        };
    }
}

pub fn run(host: *Host, address: [:0]const u8, ticks: u32) !void {
    const listener = net.session_open(address, true);
    if (listener == 0) return error.ListenFailed;
    defer net.session_listen_close(listener);
    defer for (0..host.peers.len) |slot| host.release(@intCast(slot));
    std.debug.print("listening {s}\n", .{address});

    var tick: u32 = 0;
    var next_step = host.now();
    while (tick < ticks) {
        net.session_poll();
        const time = host.now();
        if (time < next_step) {
            try host.io.sleep(.fromMicroseconds(@min(Arena.step_us, next_step - time)), .awake);
            continue;
        }
        next_step = @max(next_step + Arena.step_us, time);
        for (0..host.peers.len) |slot| try host.service(@intCast(slot), time);
        if (tick == 0) {
            var players: usize = 0;
            for (host.arena.pilots) |pilot| {
                if (pilot != null) players += 1;
            }
            if (players < pilots_to_start) continue;
        }
        tick += 1;
        const view = try host.arena.step(tick);
        host.finishing = tick == ticks;
        try host.broadcast(if (host.finishing) .{ .finished = view } else .{ .view = view });
    }

    const expires = host.now() + timeout;
    while (host.now() < expires) {
        net.session_poll();
        const time = host.now();
        for (0..host.peers.len) |slot| try host.service(@intCast(slot), time);
        for (host.peers) |entry| {
            const peer = entry orelse continue;
            if (peer.state == .playing) break;
        } else {
            std.debug.print("finished {d}\n", .{tick});
            return;
        }
        try host.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.FinishTimedOut;
}
