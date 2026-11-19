//! Two pilots start Six Beacons. A third joins after the first pickup.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const simulation = @import("arena_simulation.zig");
const socket = @import("socket.zig");
const wire = @import("beacon_snapshot.zig");
const version = @import("version").string;

const Role = enum { host, pilot1, pilot2, pilot3, cancel_join, wrong_protocol };
const pilot_count = 3;
const starting_pilots = 2;
const join_timeout = 3 * std.time.us_per_s;
const first_marker = 5000;

extern "c" fn puts(text: [*:0]const u8) c_int;
extern "c" fn getchar() c_int;
extern "c" fn fflush(stream: ?*anyopaque) c_int;

const Arena = struct {
    mission: game.gameobj.testing.Mission,
    explosions: game.explode.Explosions,
    devices: engine.input.Devices = .{},

    fn init(arena: *Arena) !void {
        const allocator = std.heap.page_allocator;
        arena.devices = .{};
        try arena.mission.init(allocator);
        errdefer arena.mission.deinit();
        arena.explosions = try .init(allocator, null);
        errdefer arena.explosions.deinit();
        const all = arena.mission.objects;
        all.players = pilot_count;
        for ([_]f32{ first_marker, -8000, -6000 }) |x| {
            const slot = try arena.mission.add(.of(.predator), .{ x, 0, 0 });
            arena.mission.slot(slot).object.radius = 10;
        }
        const gate = try arena.mission.add(.of(.dm_beacon_gate), @splat(0));
        arena.mission.slot(gate).object.radius = 100;
        for (0..game.deathmatch.six_beacons.required) |i| {
            const x: f32 = @floatFromInt(first_marker + i * 1000);
            const marker = try arena.mission.add(.of(.beacon_marker), .{ x, 0, 0 });
            arena.mission.slot(marker).object.radius = 0;
            const beacon = try arena.mission.add(.of(.dm_beacon), .{ 20000, 0, 0 });
            arena.mission.slot(beacon).object.radius = 20;
        }
        try game.deathmatch.six_beacons.Round.start(arena.world(), .free_for_all);
    }

    fn deinit(arena: *Arena) void {
        arena.explosions.deinit();
        arena.mission.deinit();
    }

    fn world(arena: *Arena) game.gameobj.World {
        return simulation.world(&arena.mission, &arena.explosions);
    }

    fn frame(arena: *Arena) !wire.View {
        if (simulation.step(&arena.mission, &arena.devices, &arena.explosions) != .played) return error.ArenaEnded;
        return wire.View.capture(arena.mission.objects, arena.mission.clock.frame_start);
    }
};

// The transport dispatches callbacks on the polling thread.
const Peer = struct {
    conn: ?socket.Connection = null,
    admitted: bool = false,
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
        .host, .cancel_join, .wrong_protocol => return false,
    } else if (other == .host) 0 else return false;
    if (peers[index].conn != null) return false;
    peers[index] = .{ .conn = conn };
    return true;
}

export fn probe_closed(conn: socket.Connection) void {
    for (&peers) |*peer| {
        if (peer.conn != conn) continue;
        if (role != .host or peer.admitted) disconnected = true;
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

// This revision belongs to the probe protocol. App releases can share a revision.
const protocol_revision: u16 = 1;

fn sendVersion(conn: socket.Connection, message: wire.Message, revision: u16, release: []const u8) !void {
    var buffer: [wire.capacity]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try out.writeByte(@backingInt(message));
    try out.writeInt(u16, revision, .little);
    try out.writeAll(release);
    try socket.send(conn, wire.lane, out.buffered());
}

const Version = struct {
    revision: u16,
    release: []const u8,

    fn read(bytes: []const u8, message: wire.Message) !Version {
        var in = std.Io.Reader.fixed(bytes);
        if (try in.takeEnum(wire.Message, .little) != message) return error.UnexpectedMessage;
        const revision = try in.takeInt(u16, .little);
        const release = in.buffered();
        if (release.len == 0) return error.MissingVersion;
        return .{ .revision = revision, .release = release };
    }
};

fn signalReady(message: [*:0]const u8) !void {
    if (puts(message) < 0 or fflush(null) != 0) return error.ReadySignalFailed;
}

fn compatiblePeer(slot: usize) !socket.Connection {
    const peer = &peers[slot];
    var buffer: [wire.capacity]u8 = undefined;
    while (true) {
        const conn = try waitForPeer(slot);
        if (slot == starting_pilots) try signalReady("checking late join");
        const hello_deadline = socket.probe_now() + join_timeout;
        while (socket.probe_now() < hello_deadline) {
            try poll();
            if (peer.conn != conn) break;
            const packet = socket.receive(conn, &buffer) catch break orelse continue;
            if (packet.lane != wire.lane) break;
            const request = Version.read(packet.bytes, .join) catch break;
            if (request.revision != protocol_revision) {
                sendVersion(conn, .wrong_protocol, protocol_revision, version) catch break;
                // Allow time to read the rejection even if the transport already acknowledged it.
                while (peer.conn == conn and socket.probe_now() < hello_deadline) try poll();
                break;
            }
            peer.admitted = true;
            return conn;
        }
        if (peer.conn == conn) {
            peer.* = .{};
            if (!socket.probe_close(conn)) return error.CloseFailed;
        }
        try signalReady("join slot free");
    }
}

fn sendView(conn: socket.Connection, view: wire.View) !void {
    var buffer: [wire.capacity]u8 = undefined;
    try socket.send(conn, wire.lane, try view.encode(&buffer));
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
    if (!std.meta.eql(after.positions[0], [3]f32{ first_marker + 8, 0, 0 })) return error.WrongDropPosition;
}

fn host() !void {
    var arena: Arena = undefined;
    try arena.init();
    defer arena.deinit();
    var clients: [pilot_count]socket.Connection = undefined;
    for (0..starting_pilots) |i| {
        clients[i] = try compatiblePeer(i);
        _ = try simulation.admit(arena.world(), @intCast(i));
    }
    const pickup = try arena.frame();
    const carrier = try checkPickup(pickup);
    for (clients[0..starting_pilots]) |conn| try sendView(conn, pickup);
    for (clients[0..starting_pilots]) |conn| try expect(conn, .applied);

    // The runner only starts the third process after the first two pilots confirm the pickup.
    try signalReady("beacon carried");
    clients[starting_pilots] = try compatiblePeer(starting_pilots);
    const late = try simulation.admit(arena.world(), starting_pilots);
    const joined = try arena.frame();
    if (!std.meta.eql(carrier, try checkPickup(joined)) or joined.state.countFor(late) != 0)
        return error.WrongJoinState;
    try sendView(clients[starting_pilots], joined);
    try expect(clients[starting_pilots], .applied);

    // This is the normal destruction order. Its init releases the ship's cargo.
    const orders: game.aigeneric.Context = .of(arena.world());
    if (!try game.aigeneric.push(orders, carrier.ship.slot, .explode, .none)) return error.OrderFailed;
    const dropped = try arena.frame();
    try checkDrop(joined, dropped, carrier);
    for (clients) |conn| try sendView(conn, dropped);
    for (clients) |conn| try expect(conn, .applied);

    for (clients) |conn| try socket.send(conn, wire.lane, &.{@backingInt(wire.Message.complete)});
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
    if (role == .cancel_join) {
        // The runner cancels after the host starts waiting for this pilot's join message.
        if (getchar() != '\n') return error.MissingCancellation;
        if (!socket.probe_close(conn)) return error.CloseFailed;
        return;
    }
    if (role == .wrong_protocol) {
        try sendVersion(conn, .join, protocol_revision + 1, version);
        const required = try Version.read(try receive(conn, &buffer), .wrong_protocol);
        if (required.revision != protocol_revision or !std.mem.eql(u8, required.release, version))
            return error.WrongProtocolRejection;
        // Stay connected until the runner observes the host releasing the slot.
        if (getchar() != '\n') return error.MissingRelease;
        std.debug.print("incompatible client: host requires protocol {d} (OpenReliant {s})\n", .{ required.revision, required.release });
        return;
    }

    // The late pilot reports a different app release to exercise compatible joins.
    const release = if (role == .pilot3) "1.0.0" else version;
    try sendVersion(conn, .join, protocol_revision, release);
    const pickup = try wire.View.decode(try receive(conn, &buffer));
    const carrier = try checkPickup(pickup);
    if (role == .pilot3) std.debug.print("pilot3: first snapshot shows pilot1 carrying one beacon\n", .{});
    try socket.send(conn, wire.lane, &.{@backingInt(wire.Message.applied)});

    const drop = try wire.View.decode(try receive(conn, &buffer));
    try checkDrop(pickup, drop, carrier);
    try socket.send(conn, wire.lane, &.{@backingInt(wire.Message.applied)});
    try expect(conn, .complete);
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
