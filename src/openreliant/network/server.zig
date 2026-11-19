//! A direct-IP host. Only the game thread admits pilots and applies their commands.
const std = @import("std");
const Io = std.Io;
const wire = @import("wire.zig");
const net = @import("transport.zig");
const Arena = @import("arena.zig");
const identity = @import("identity.zig");
const HandshakeBudget = @import("handshake_budget");
const Host = @This();

const timeout = 5 * std.time.us_per_s;
const packets_per_tick = 4;
const max_identity = 32;
pub const pilots_to_start = 2;

const Peer = struct {
    conn: net.Connection,
    state: enum { connecting, enrolling, certified, joining, playing, closing } = .connecting,
    identity: [max_identity]u8 = undefined,
    identity_len: u8 = 0,
    expires: i64,
    sequence: ?u32 = null,
};

io: Io,
arena: Arena,
signer: ?*const identity.Server = null,
player_limit: u8 = wire.slots,
peers: [wire.slots]?Peer = @splat(null),
budget: HandshakeBudget = .{},
final_tick: ?u32 = null,
final_receipts: usize = 0,

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

fn slotFor(host: *const Host, conn: net.Connection) ?u8 {
    for (host.peers, 0..) |entry, slot| {
        if (entry) |peer| if (peer.conn == conn) return @intCast(slot);
    }
    return null;
}

pub fn status(host: *Host, conn: net.Connection, event: net.Status, name: ?[]const u8) void {
    const slot = host.slotFor(conn);
    switch (event) {
        .incoming => {
            if (slot != null) return;
            if (host.final_tick == null) {
                for (host.peers[0..host.player_limit]) |*entry| {
                    if (entry.* != null) continue;
                    const time = host.now();
                    if (host.budget.take(time) and net.session_accept(conn)) {
                        entry.* = .{ .conn = conn, .expires = time + timeout };
                        return;
                    }
                    break;
                }
            }
        },
        .authenticated => if (slot) |index| {
            const peer = &host.peers[index].?;
            if (peer.state != .connecting) return;
            if (name) |pilot_name| {
                if (pilot_name.len > 0 and pilot_name.len <= max_identity and !host.hasName(pilot_name)) {
                    @memcpy(peer.identity[0..pilot_name.len], pilot_name);
                    peer.identity_len = @intCast(pilot_name.len);
                    peer.state = .joining;
                    return;
                }
            }
        },
        .unverified => if (slot) |index| {
            const peer = &host.peers[index].?;
            if (host.signer != null and peer.state == .connecting) {
                // An encrypted guest can request one certificate. Only a new, authenticated
                // connection can join the simulation with it.
                peer.state = .enrolling;
                return;
            }
        },
        .closed => {},
    }
    if (slot) |index| host.release(index) else net.session_close(conn);
}

fn hasName(host: *const Host, name: []const u8) bool {
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.identity_len != 0 and std.mem.eql(u8, peer.identity[0..peer.identity_len], name)) return true;
    }
    return false;
}

fn receive(host: *Host, slot: u8, peer: *Peer, message: wire.Message, time: i64) !bool {
    if (message == .leave) return false;
    switch (peer.state) {
        .enrolling => {
            if (host.final_tick != null or message != .request_identity) return false;
            const signer = host.signer orelse return false;
            const key = identity.PublicKey.fromBytes(message.request_identity) catch return false;
            const certificate = identity.issue(host.io, &signer.issuer, key, &identity.pilotName(key)) catch return false;
            try net.send(peer.conn, .{ .issued_identity = certificate.slice() });
            peer.state = .certified;
            return true;
        },
        .joining => {
            if (host.final_tick != null or message != .join) return false;
            if (!message.join.compatible()) {
                try net.send(peer.conn, .{ .wrong_protocol = .local });
                peer.state = .closing;
                peer.expires = time + timeout;
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
            if (host.final_tick) |tick| {
                if (message == .received_final and message.received_final == tick) host.final_receipts += 1;
                return message == .input;
            }
            if (message != .input) return false;
            const input = message.input;
            if (!input.follows(peer.sequence)) return true;
            if (!host.arena.input(slot, input.steering)) return false;
            peer.sequence = input.sequence;
            peer.expires = time + timeout;
            return true;
        },
        .connecting, .certified, .closing => return false,
    }
}

fn service(host: *Host, slot: u8, time: i64) !void {
    const peer = if (host.peers[slot]) |*peer| peer else return;
    if (time >= peer.expires) {
        host.release(slot);
        return;
    }
    if (peer.state == .connecting or peer.state == .closing) return;
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
        if (peer.state == .closing) return;
    }
}

fn servicePeers(host: *Host, time: i64) !void {
    for (0..host.peers.len) |slot| try host.service(@intCast(slot), time);
}

fn playingCount(host: *const Host) usize {
    var count: usize = 0;
    for (host.peers) |entry| {
        const peer = entry orelse continue;
        if (peer.state == .playing) count += 1;
    }
    return count;
}

fn broadcast(host: *Host, view: wire.Snapshot, final: bool) !void {
    const message: wire.Message = if (final) .{ .finished = view } else .{ .view = view };
    var buffer: [wire.capacity]u8 = undefined;
    const bytes = try message.encode(&buffer);
    for (&host.peers, 0..) |*entry, slot| {
        const peer = if (entry.*) |*peer| peer else continue;
        if (peer.state != .playing) continue;
        net.sendBytes(peer.conn, bytes, final) catch {
            if (final) host.release(@intCast(slot));
            continue;
        };
        if (final) peer.expires = host.now() + timeout;
    }
}

pub fn run(host: *Host, address: [:0]const u8, ticks: ?u32, invite: ?identity.Invite) !void {
    const listener = net.session_open(address, true);
    if (listener == 0) return error.ListenFailed;
    defer net.session_listen_close(listener);
    defer for (0..host.peers.len) |slot| host.release(@intCast(slot));
    std.debug.print("listening {s}\n", .{address});
    if (invite) |value| {
        std.debug.print("invite {f}\n", .{value});
    } else if (host.signer != null) {
        std.debug.print("Set InviteAddress in server.ini to print an invite for this listener.\n", .{});
    }

    var tick: u32 = 0;
    const last_tick = ticks orelse std.math.maxInt(u32);
    var next_step = host.now();
    var renew_at = next_step + identity.renew_after_us;
    while (tick < last_tick) {
        net.session_poll();
        const time = host.now();
        if (time < next_step) {
            try host.io.sleep(.fromMicroseconds(@min(Arena.step_us, next_step - time)), .awake);
            continue;
        }
        next_step = @max(next_step + Arena.step_us, time);
        if (host.signer) |signer| {
            if (time >= renew_at) {
                var certificate = try signer.hostCertificate(host.io);
                defer certificate.wipe();
                if (!net.session_set_certificate(certificate.bytes[0..].ptr, @intCast(certificate.len)))
                    return error.IdentityRenewalFailed;
                renew_at = time + identity.renew_after_us;
            }
        }
        try host.servicePeers(time);
        if (tick == 0 and host.playingCount() < pilots_to_start) continue;
        tick += 1;
        const view = try host.arena.step(tick);
        if (tick == last_tick) host.final_tick = tick;
        try host.broadcast(view, tick == last_tick);
    }

    const expires = host.now() + timeout;
    while (host.playingCount() != 0 and host.now() < expires) {
        net.session_poll();
        try host.servicePeers(host.now());
        if (host.playingCount() != 0) try host.io.sleep(.fromMilliseconds(1), .awake);
    }
    std.debug.print("finished {d} {d}\n", .{ tick, host.final_receipts });
}
