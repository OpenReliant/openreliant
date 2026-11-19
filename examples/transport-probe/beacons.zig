//! Two pilots start Six Beacons. A third joins after the first pickup.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const Arena = @import("beacon_arena.zig");
const socket = @import("socket.zig");
const wire = @import("beacon_snapshot.zig");
const admission = @import("beacon_admission.zig");
const version = @import("version").string;

const Role = enum { host, pilot1, pilot2, pilot3, cancel_join, silent_join, leave_play, silent_play, wrong_protocol };
const pilot_count = Arena.pilot_count;
const starting_pilots = 2;
const step_us = game.gameobj.ticks_per_step * std.time.us_per_s / game.main.ticks_per_second;

extern "c" fn puts(text: [*:0]const u8) c_int;
extern "c" fn getchar() c_int;
extern "c" fn fflush(stream: ?*anyopaque) c_int;

// The transport dispatches callbacks on the polling thread.
const Peer = struct {
    conn: ?socket.Connection = null,
    connected_at: i64 = 0,
};
var peers: [pilot_count]Peer = @splat(.{});
var role: Role = undefined;
var disconnected = false;
var deadline: i64 = undefined;

export fn probe_connected(conn: socket.Connection, identity: [*:0]const u8, incoming: bool) bool {
    if (incoming != (role == .host)) return false;
    const other = std.meta.stringToEnum(Role, std.mem.span(identity)) orelse return false;
    const index: usize = if (incoming) switch (other) {
        .pilot1 => 0,
        .pilot2 => 1,
        .pilot3 => 2,
        .host, .cancel_join, .silent_join, .leave_play, .silent_play, .wrong_protocol => return false,
    } else if (other == .host) 0 else return false;
    if (peers[index].conn != null) return false;
    peers[index] = .{ .conn = conn, .connected_at = socket.probe_now() };
    return true;
}

export fn probe_closed(conn: socket.Connection) void {
    for (&peers) |*peer| {
        if (peer.conn != conn) continue;
        if (role != .host) disconnected = true;
        peer.* = .{};
    }
}

fn poll() !void {
    if (!socket.probe_poll()) return error.TransportFailed;
    if (disconnected) return error.Disconnected;
    if (socket.probe_now() >= deadline) return error.TimedOut;
}

fn waitForPeer(slot: usize) !socket.Connection {
    while (peers[slot].conn == null) try poll();
    return peers[slot].conn.?;
}

fn receive(conn: socket.Connection, buffer: []u8) ![]const u8 {
    while (true) {
        try poll();
        const packet = try socket.receive(conn, buffer) orelse continue;
        if (packet.lane != wire.lane) return error.WrongLane;
        return packet.bytes;
    }
}

fn expect(conn: socket.Connection, message: wire.Message) !void {
    var buffer: [wire.capacity]u8 = undefined;
    if (!std.mem.eql(u8, try receive(conn, &buffer), &.{@backingInt(message)})) return error.UnexpectedMessage;
}

fn signalReady(message: [*:0]const u8) !void {
    if (puts(message) < 0 or fflush(null) != 0) return error.ReadySignalFailed;
}

const Pilot = struct {
    conn: socket.Connection,
    control: game.players.ControlRef,
    delivery: wire.Delivery = .{},

    fn receiveAck(pilot: *Pilot, now: i64) !void {
        if (pilot.delivery.pending) |pending| {
            if (now >= pending.expires) return error.SnapshotTimedOut;
        }
        var buffer: [wire.capacity]u8 = undefined;
        if (try socket.receive(pilot.conn, &buffer)) |packet| try pilot.delivery.accept(packet.lane, packet.bytes);
    }
};

const Playing = struct {
    arena: *Arena,
    pilots: [pilot_count]?Pilot = @splat(null),
    next_step: i64,

    fn admit(round: *Playing, slot: usize, conn: socket.Connection) !void {
        std.debug.assert(round.pilots[slot] == null);
        round.pilots[slot] = .{ .conn = conn, .control = try round.arena.admit(@intCast(slot)) };
    }

    fn release(round: *Playing, slot: usize) !void {
        const pilot = round.pilots[slot].?;
        try round.arena.leave(pilot.control.participant);
        round.pilots[slot] = null;
        if (peers[slot].conn == pilot.conn) {
            peers[slot] = .{};
            _ = socket.probe_close(pilot.conn);
        }
    }

    fn receipts(round: *Playing, now: i64) !void {
        for (&round.pilots, peers, 0..) |*entry, peer, i| {
            const pilot = if (entry.*) |*pilot| pilot else continue;
            if (peer.conn != pilot.conn) {
                try round.release(i);
                continue;
            }
            pilot.receiveAck(now) catch |err| {
                if (err == error.SnapshotTimedOut and i == starting_pilots) try round.confirmProgress(pilot.delivery.pending.?.tick);
                std.debug.print("pilot {d}: {s}\n", .{ i + 1, @errorName(err) });
                try round.release(i);
            };
        }
    }

    fn broadcast(round: *Playing, view: wire.View, now: i64) !void {
        var buffer: [wire.capacity]u8 = undefined;
        const bytes = try view.encode(&buffer);
        for (&round.pilots, 0..) |*entry, i| {
            const pilot = if (entry.*) |*pilot| pilot else continue;
            if (pilot.delivery.pending != null) continue;
            socket.send(pilot.conn, wire.lane, bytes) catch {
                try round.release(i);
                continue;
            };
            pilot.delivery.pending = .{ .tick = view.tick, .expires = now + admission.timeout };
        }
    }

    fn advance(round: *Playing, now: i64) !void {
        try round.receipts(now);
        if (now < round.next_step) return;
        round.next_step += step_us;
        try round.broadcast(try round.arena.frame(), now);
    }

    fn appliedSince(round: *const Playing, tick: i32) bool {
        for (round.pilots[0..starting_pilots]) |entry| {
            const pilot = entry orelse return false;
            if ((pilot.delivery.applied orelse return false) <= tick) return false;
        }
        return true;
    }

    fn confirmProgress(round: *const Playing, start_tick: i32) !void {
        const half_window_ticks = admission.timeout * game.main.ticks_per_second / (2 * std.time.us_per_s);
        for (round.pilots[0..starting_pilots]) |entry| {
            const pilot = entry orelse return error.MissingLiveSnapshots;
            const previous = pilot.delivery.previous orelse return error.MissingLiveSnapshots;
            const applied = pilot.delivery.applied orelse return error.MissingLiveSnapshots;
            if (previous <= start_tick or applied - start_tick < half_window_ticks) return error.MissingLiveSnapshots;
        }
        std.debug.print("host ticks {d} to {d}, pilots applied {d} and {d}\n", .{
            start_tick, round.arena.mission.clock.frame_start, round.pilots[0].?.delivery.applied.?, round.pilots[1].?.delivery.applied.?,
        });
    }

    // At each end of the scenario every pilot must confirm the same view.
    fn finishDelivery(round: *Playing, count: usize) !void {
        while (true) {
            try poll();
            try round.receipts(socket.probe_now());
            for (round.pilots[0..count]) |entry| {
                const pilot = entry orelse return error.MissingPilot;
                if (pilot.delivery.pending != null) break;
            } else return;
        }
    }
};

fn compatiblePeer(slot: usize, playing: ?*Playing) !socket.Connection {
    const peer = &peers[slot];
    var pending: ?admission.Attempt = null;
    while (true) {
        try poll();
        const now = socket.probe_now();
        if (pending == null) {
            if (peer.conn) |conn| {
                pending = .{
                    .conn = conn,
                    .expires = peer.connected_at + admission.timeout,
                    .start_tick = if (playing) |round| round.arena.mission.clock.frame_start else 0,
                };
                if (playing != null) try signalReady("checking late join");
            }
        }
        if (pending) |*attempt| switch (attempt.advance(peer.conn, now)) {
            .pending => {},
            .compatible => return attempt.conn,
            .release, .silent_timeout => |result| {
                if (peer.conn == attempt.conn) {
                    peer.* = .{};
                    if (!socket.probe_close(attempt.conn)) return error.CloseFailed;
                }
                if (playing) |round| {
                    if (result == .silent_timeout) try round.confirmProgress(attempt.start_tick);
                    try signalReady(if (result == .silent_timeout) "silent join expired" else "join slot free");
                }
                pending = null;
            },
        };
        if (playing) |round| try round.advance(now);
    }
}

fn acknowledge(conn: socket.Connection, tick: i32) !void {
    const bytes = wire.applied(tick);
    try socket.send(conn, wire.lane, &bytes);
}

fn checkPickup(view: wire.View) !game.players.ControlRef {
    const carrier = view.state.beacons[0].carrier orelse return error.NoPickup;
    if (carrier.participant.slot != 0 or carrier.ship.slot != 0 or view.state.countFor(carrier) != 1)
        return error.WrongCarrier;
    for (view.state.beacons[1..]) |beacon| {
        if (beacon.carrier != null) return error.ExtraPickup;
    }
    return carrier;
}

fn checkDrop(before: wire.View, after: wire.View, carrier: game.players.ControlRef) !void {
    if (after.tick <= before.tick or after.state.countFor(carrier) != 0) return error.NoDrop;
    for (before.state.beacons, after.state.beacons) |earlier, later| {
        if (!std.meta.eql(earlier.object, later.object) or later.carrier != null) return error.WrongBeacon;
    }
    // The first drop moves the same beacon along +X from the carrier.
    if (!std.meta.eql(after.positions[0], [3]f32{ Arena.first_marker + 8, 0, 0 })) return error.WrongDropPosition;
}

fn host() !void {
    var arena: Arena = undefined;
    try arena.init(std.heap.page_allocator);
    defer arena.deinit();
    var playing: Playing = .{ .arena = &arena, .next_step = undefined };
    for (0..starting_pilots) |i| try playing.admit(i, try compatiblePeer(i, null));
    const pickup = try arena.frame();
    const carrier = try checkPickup(pickup);
    try playing.broadcast(pickup, socket.probe_now());
    try playing.finishDelivery(starting_pilots);
    playing.next_step = socket.probe_now() + step_us;
    try signalReady("beacon carried");

    const late_slot = starting_pilots;
    var previous: ?game.players.ControlRef = null;
    const joined = while (true) {
        try playing.admit(late_slot, try compatiblePeer(late_slot, &playing));
        const late = playing.pilots[late_slot].?.control;
        if (previous) |departed| {
            if (arena.mission.objects.submitPlayerCommand(departed, .{})) return error.StalePilotCanFly;
        }
        previous = late;

        // The next scheduled frame supplies the new pilot's first full snapshot.
        while (playing.pilots[late_slot]) |pilot| {
            if (pilot.delivery.applied != null) break;
            try poll();
            try playing.advance(socket.probe_now());
        }
        if (playing.pilots[late_slot] != null) {
            const view = try wire.View.capture(arena.mission.objects, arena.mission.clock.frame_start);
            if (!std.meta.eql(carrier, try checkPickup(view)) or view.state.countFor(late) != 0) return error.WrongJoinState;
            break view;
        }
        const released_at = arena.mission.clock.frame_start;
        while (!playing.appliedSince(released_at)) {
            try poll();
            try playing.advance(socket.probe_now());
        }
        try signalReady("playing slot free");
    };
    try playing.finishDelivery(pilot_count);

    // This is the normal destruction order. Its init releases the ship's cargo.
    const orders: game.aigeneric.Context = .of(arena.world());
    if (!try game.aigeneric.push(orders, carrier.ship.slot, .explode, .none)) return error.OrderFailed;
    const dropped = try arena.frame();
    try checkDrop(joined, dropped, carrier);
    try playing.broadcast(dropped, socket.probe_now());
    try playing.finishDelivery(pilot_count);
    for (playing.pilots) |entry| try socket.send(entry.?.conn, wire.lane, &.{@backingInt(wire.Message.complete)});
    // A client may close after receiving the final message. Drain anything still queued.
    while (true) {
        if (!socket.probe_poll() or socket.probe_now() >= deadline) return error.TimedOut;
        for (peers) |peer| {
            if (peer.conn) |conn| if (!socket.probe_delivered(conn)) break;
        } else break;
    }
    std.debug.print("host: all three pilots confirmed the drop\n", .{});
}

fn client() !void {
    const conn = try waitForPeer(0);
    var buffer: [wire.capacity]u8 = undefined;
    if (role == .silent_join or role == .cancel_join) {
        // The runner releases the silent client only after the host expires its connection.
        if (getchar() != '\n') return error.MissingRelease;
        if (role == .cancel_join and !socket.probe_close(conn)) return error.CloseFailed;
        return;
    }
    if (role == .wrong_protocol) {
        try admission.sendVersion(conn, .join, admission.protocol_revision + 1, version);
        const required = try admission.Version.read(try receive(conn, &buffer), .wrong_protocol);
        if (required.revision != admission.protocol_revision or !std.mem.eql(u8, required.release, version))
            return error.WrongProtocolRejection;
        // Stay connected until the runner observes the host releasing the slot.
        if (getchar() != '\n') return error.MissingRelease;
        std.debug.print("incompatible client: host requires protocol {d} (OpenReliant {s})\n", .{ required.revision, required.release });
        return;
    }

    // The late pilot reports a different app release to exercise compatible joins.
    const release = if (role == .pilot3) "1.0.0" else version;
    try admission.sendVersion(conn, .join, admission.protocol_revision, release);
    const pickup = try wire.View.decode(try receive(conn, &buffer));
    const carrier = try checkPickup(pickup);
    if (role == .pilot3) std.debug.print("pilot3: first snapshot shows pilot1 carrying one beacon\n", .{});
    if (role == .leave_play) {
        if (!socket.probe_close(conn)) return error.CloseFailed;
        if (getchar() != '\n') return error.MissingRelease;
        return;
    }
    if (role == .silent_play) {
        if (getchar() != '\n') return error.MissingRelease;
        return;
    }
    try acknowledge(conn, pickup.tick);

    var previous = pickup;
    while (true) {
        const view = try wire.View.decode(try receive(conn, &buffer));
        if (view.tick <= previous.tick) return error.StaleSnapshot;
        if (view.state.beacons[0].carrier == null) {
            try checkDrop(previous, view, carrier);
            try acknowledge(conn, view.tick);
            break;
        }
        if (!std.meta.eql(view.state, pickup.state)) return error.WrongJoinState;
        try acknowledge(conn, view.tick);
        previous = view;
    }
    try expect(conn, .complete);
    // Keep the transport alive until the host has drained its final reliable messages.
    if (getchar() != '\n') return error.MissingRelease;
    std.debug.print("{s}: the same beacon is loose again\n", .{@tagName(role)});
}

fn run(address: [*:0]const u8) !void {
    if (!socket.probe_open(address, role == .host, wire.capacity)) return error.OpenFailed;
    deadline = socket.probe_now() + 30 * std.time.us_per_s;
    return if (role == .host) host() else client();
}

export fn probe_run(name: [*:0]const u8, address: [*:0]const u8, _: bool) c_int {
    role = std.meta.stringToEnum(Role, std.mem.span(name)) orelse return 2;
    run(address) catch |err| {
        std.debug.print("{s}: {s}\n", .{ @tagName(role), @errorName(err) });
        return 1;
    };
    return 0;
}
