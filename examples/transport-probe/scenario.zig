//! A bounded workload for the transport experiment. It has no game dependencies.
const std = @import("std");

const Role = enum { host, pilot1, pilot2, reject };
const wire = @import("wire.zig");
const tick_us = 40 * std.time.us_per_ms;
const last_tick = 100;
const burst_tick = last_tick / 4;
const bulk_count = 64;
const deadline_us = 30 * std.time.us_per_s;

extern fn probe_open(address: [*:0]const u8, host: bool) bool;
extern fn probe_send(conn: u32, lane: u16, data: [*]const u8, size: c_int) bool;
extern fn probe_receive(conn: u32, data: [*]u8, capacity: c_int, lane: *u16) c_int;
extern fn probe_now() i64;
extern fn probe_poll() void;
extern fn probe_delivered(conn: u32) bool;

fn send(frame: wire.Frame, conn: u32) !void {
    var buffer: [wire.capacity]u8 = undefined;
    const bytes = frame.encode(&buffer);
    if (!probe_send(conn, @backingInt(wire.Frame.lane(frame)), bytes.ptr, @intCast(bytes.len))) return error.SendFailed;
}

const Peer = struct {
    conn: ?u32 = null,
    control: ?wire.Control = null,
    done: bool = false,
    confirmed: bool = false,
    applied: u16 = 0,
    samples: u16 = 0,
    max_ack_us: i64 = 0,
};

const Scenario = struct {
    role: Role,
    shared_clock: bool,
    applied_ages: [last_tick]i64 = undefined,
    peers: [2]Peer = .{ .{}, .{} },
    tick: u16 = 0,
    positions: [2]i16 = .{ 0, 0 },
    sent_at: [last_tick + 1]i64 = @splat(0),
    next_tick: i64 = 0,
    recalls: u16 = 0,
    bulk: u16 = 0,
    snapshots_during_bulk: u16 = 0,
    finished: bool = false,
    success: bool = false,
    disconnected: bool = false,

    fn hostFrame(s: *Scenario, peer: *Peer, frame: wire.Frame) !void {
        switch (frame) {
            .input => |input| {
                if (input.applied > s.tick) return error.FutureAcknowledgement;
                peer.control = input.control;
                if (input.applied <= peer.applied) return;
                peer.applied = input.applied;
                peer.samples += 1;
                peer.max_ack_us = @max(peer.max_ack_us, probe_now() - s.sent_at[input.applied]);
            },
            .done => |count| {
                if (s.tick != last_tick or peer.done or peer.samples == 0 or count == 0 or count > last_tick)
                    return error.BadResult;
                peer.done = true;
                try send(.receipt, peer.conn.?);
            },
            .confirmed => {
                if (!peer.done or peer.confirmed) return error.BadResult;
                peer.confirmed = true;
                s.success = s.peers[0].confirmed and s.peers[1].confirmed;
            },
            else => return error.WrongDirection,
        }
    }

    fn pilotFrame(s: *Scenario, peer: *Peer, frame: wire.Frame) !void {
        switch (frame) {
            .snapshot => |snapshot| {
                if (snapshot.tick == 0 or snapshot.tick > last_tick) return error.BadFrame;
                // The two pilots hold opposite controls throughout the run.
                const distance: i16 = @intCast(snapshot.tick);
                if (!std.mem.eql(i16, &snapshot.positions, &.{ distance, -distance })) return error.WrongPositions;
                if (snapshot.tick > peer.applied) {
                    if (s.shared_clock) {
                        const applied_at = probe_now();
                        if (snapshot.sent_us < 0 or snapshot.sent_us > applied_at) return error.BadTimestamp;
                        s.applied_ages[peer.samples] = applied_at - snapshot.sent_us;
                    }
                    peer.applied = snapshot.tick;
                    peer.samples += 1;
                    if (s.bulk > 0 and s.bulk < bulk_count) s.snapshots_during_bulk += 1;
                }
            },
            .recall => |tick| {
                if (s.role != .pilot1 or s.recalls != 0 or tick != burst_tick) return error.WrongRecall;
                s.recalls += 1;
            },
            .bulk => |index| {
                if (s.bulk >= bulk_count or index != s.bulk) return error.BadBurst;
                s.bulk += 1;
            },
            .finish => |tick| {
                if (s.finished or tick != last_tick) return error.BadFrame;
                s.finished = true;
            },
            .receipt => {
                if (!peer.done or peer.confirmed) return error.BadResult;
                try send(.confirmed, peer.conn.?);
                peer.confirmed = true;
            },
            else => return error.WrongDirection,
        }
        if (s.finished and s.bulk == bulk_count and !peer.done) {
            if (s.recalls != @intFromBool(s.role == .pilot1) or s.snapshots_during_bulk == 0) return error.BadResult;
            try send(.{ .done = peer.samples }, peer.conn.?);
            peer.done = true;
        }
    }

    fn step(s: *Scenario, now: i64) !void {
        if (s.disconnected) return error.Disconnected;
        for (&s.peers) |*peer| {
            const conn = peer.conn orelse continue;
            // Bound each peer's work per poll so that a burst cannot starve the other pilot.
            for (0..32) |_| {
                var bytes: [wire.capacity]u8 = undefined;
                var lane: u16 = undefined;
                const count = probe_receive(conn, &bytes, bytes.len, &lane);
                if (count < 0) return error.ReceiveFailed;
                if (count == 0) break;
                const frame = try wire.Frame.decode(bytes[0..@intCast(count)], lane);
                if (s.role == .host) try s.hostFrame(peer, frame) else try s.pilotFrame(peer, frame);
            }
        }
        if (s.role != .host and s.peers[0].confirmed) {
            if (s.peers[0].conn) |conn| s.success = probe_delivered(conn);
            return;
        }
        if (now < s.next_tick) return;
        s.next_tick = now + tick_us;
        if (s.role != .host) {
            const peer = s.peers[0];
            if (peer.conn) |conn| try send(.{ .input = .{
                .applied = peer.applied,
                .control = if (s.role == .pilot1) .forward else .reverse,
            } }, conn);
            return;
        }
        if (s.tick == last_tick or s.peers[0].control == null or s.peers[1].control == null) return;
        s.tick += 1;
        s.sent_at[s.tick] = now;
        for (&s.positions, s.peers) |*position, peer| position.* += @backingInt(peer.control.?);
        for (&s.peers, 0..) |*peer, i| {
            const conn = peer.conn orelse return error.Disconnected;
            try send(.{ .snapshot = .{ .tick = s.tick, .positions = s.positions, .sent_us = now } }, conn);
            if (s.tick == burst_tick) {
                for (0..bulk_count) |n| try send(.{ .bulk = @intCast(n) }, conn);
                if (i == 0) try send(.{ .recall = s.tick }, conn);
            }
            if (s.tick == last_tick) try send(.{ .finish = s.tick }, conn);
        }
    }
};

// Valve dispatches status callbacks on the thread that calls RunCallbacks.
var scenario: Scenario = undefined;

export fn probe_connected(conn: u32, name: [*:0]const u8, incoming: bool) bool {
    const s = &scenario;
    if (incoming != (s.role == .host)) return false;
    const identity = std.mem.span(name);
    const index: usize = if (incoming) pilot: {
        if (std.mem.eql(u8, identity, "pilot1")) break :pilot 0;
        if (std.mem.eql(u8, identity, "pilot2")) break :pilot 1;
        return false;
    } else client: {
        const expected = if (s.role == .reject) "different-host" else "host";
        if (!std.mem.eql(u8, identity, expected)) {
            s.success = s.role == .reject and std.mem.eql(u8, identity, "host");
            return false;
        }
        break :client 0;
    };
    if (s.peers[index].conn != null or s.peers[index].done) return false;
    s.peers[index] = .{ .conn = conn };
    return true;
}

export fn probe_closed(conn: u32) void {
    if (scenario.role != .host and !scenario.success) {
        if (scenario.peers[0].confirmed) scenario.success = true else scenario.disconnected = true;
    }
    for (&scenario.peers) |*peer| {
        if (peer.conn != conn) continue;
        peer.conn = null;
        if (scenario.role == .host and !peer.confirmed) {
            if (scenario.tick != 0) scenario.disconnected = true else peer.control = null;
        }
    }
}

fn run(role: Role, address: [*:0]const u8, shared_clock: bool) !void {
    scenario = .{ .role = role, .shared_clock = shared_clock };
    if (!probe_open(address, role == .host)) return error.OpenFailed;
    const deadline = probe_now() + deadline_us;
    while (!scenario.success) {
        probe_poll();
        if (scenario.success) break;
        const now = probe_now();
        if (now >= deadline) {
            std.debug.print("tick {d}, peers {any}, bulk {d}, recalls {d}\n", .{ scenario.tick, scenario.peers, scenario.bulk, scenario.recalls });
            return error.TimedOut;
        }
        try scenario.step(now);
    }
    if (role == .host) {
        // Keep servicing the final reliable acknowledgements after both pilots finish.
        const drain_until = probe_now() + std.time.us_per_s;
        while (probe_now() < drain_until and (scenario.peers[0].conn != null or scenario.peers[1].conn != null))
            probe_poll();
        for (scenario.peers, 1..) |peer, pilot| {
            std.debug.print("pilot {d}: {d} applied snapshots acknowledged, maximum age at acknowledgement {d} ms\n", .{
                pilot, peer.samples, @divTrunc(peer.max_ack_us, std.time.us_per_ms),
            });
        }
    } else std.debug.print("{s}: {d} snapshots applied ({d} during the burst), {d} recalls, {d} bulk messages\n", .{
        @tagName(role), scenario.peers[0].samples, scenario.snapshots_during_bulk, scenario.recalls, scenario.bulk,
    });
    if (shared_clock and (role == .pilot1 or role == .pilot2)) {
        const ages = scenario.applied_ages[0..scenario.peers[0].samples];
        std.mem.sort(i64, ages, {}, std.sort.asc(i64));
        const p95 = std.math.divCeil(usize, ages.len * 95, 100) catch unreachable;
        std.debug.print("{s}: snapshot age at application, p95 {d} ms, maximum {d} ms\n", .{
            @tagName(role), @divTrunc(ages[p95 - 1], std.time.us_per_ms), @divTrunc(ages[ages.len - 1], std.time.us_per_ms),
        });
    }
}

export fn probe_run(name: [*:0]const u8, address: [*:0]const u8, shared_clock: bool) c_int {
    const role = std.meta.stringToEnum(Role, std.mem.span(name)) orelse return 2;
    run(role, address, shared_clock) catch |err| {
        std.debug.print("{s}: {s}\n", .{ @tagName(role), @errorName(err) });
        return 1;
    };
    return 0;
}
