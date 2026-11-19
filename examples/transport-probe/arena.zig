//! Two Predators in an empty arena. Both use the normal host input and mission tick.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const Host = @This();

const spawn_x: [2]f32 = .{ -30000, 30000 };

mission: game.gameobj.testing.Mission,
devices: engine.input.Devices = .{},
pilots: [2]game.players.ControlRef,

pub fn init(host: *Host) !void {
    host.devices = .{};
    try host.mission.init(std.heap.page_allocator);
    errdefer host.mission.deinit();
    const all = host.mission.objects;
    all.players = host.pilots.len;
    for (&host.pilots, spawn_x, 0..) |*pilot, x, index| {
        const ship = try host.mission.add(.of(.predator), .{ x, 0, 0 });
        if (ship != index) return error.WrongShipSlot;
        const participant = all.joinParticipant(ship) orelse return error.JoinFailed;
        pilot.* = all.bindParticipant(participant, .of(all, ship)) orelse return error.BindFailed;
        if (!try game.aigeneric.push(.of(host.world()), ship, .multiplayer_control, .none)) return error.OrderFailed;
    }
}

pub fn deinit(host: *Host) void {
    host.mission.deinit();
}

fn world(host: *Host) game.gameobj.World {
    var arena = host.mission.world();
    arena.damage_rules = .{ .arena = null };
    return arena;
}

pub fn step(host: *Host, controls: [2]i8) ![2][3]f32 {
    const all = host.mission.objects;
    for (host.pilots, controls) |pilot, control| {
        const yaw: f32 = @floatFromInt(control);
        if (!all.submitPlayerCommand(pilot, .{ .flight = .{
            .steering = .{ .axes = .{ yaw * 0.1, 0, 0 } },
            .throttle = .{ .axis = 1 },
        } })) return error.InputRejected;
    }

    const clock = &host.mission.clock;
    clock.advanceTimer(game.gameobj.ticks_per_step);
    if (game.main.gameFrames(clock, &host.devices, null, host.world(), .in_turn, null) == .over)
        return error.ArenaEnded;

    var positions: [2][3]f32 = undefined;
    for (&positions, host.pilots) |*position, pilot| {
        const i = pilot.ship.resolve(all) orelse return error.ShipGone;
        position.* = all.slots[i].object.root.next_position.vector();
    }
    return positions;
}

pub fn check(tick: u16, positions: [2][3]f32) !void {
    // Both pilots accelerate along Z and steer in opposite directions on X.
    if (tick < 10) return;
    const first = positions[0][0] - spawn_x[0];
    const second = positions[1][0] - spawn_x[1];
    if (!(first > 0 and second < 0 and positions[0][2] > 0 and positions[1][2] > 0))
        return error.WrongFlight;
}
