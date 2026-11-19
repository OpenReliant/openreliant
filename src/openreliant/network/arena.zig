//! Headless arenas for direct-IP sessions, driven by the regular host flight step.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const simulation = @import("arena_simulation");
const wire = @import("wire.zig");
const Arena = @This();

const spawn_spacing: f32 = 12000;
pub const Mode = enum { training, @"six-beacons" };

comptime {
    std.debug.assert(wire.slots == simulation.beacon_spawn_x.len);
}

mission: game.gameobj.testing.Mission,
mode: Mode,
explosions: ?game.explode.Explosions = null,
devices: engine.input.Devices = .{},
pilots: [wire.slots]?game.players.ControlRef = @splat(null),

pub fn init(arena: *Arena, gpa: std.mem.Allocator, mode: Mode) !void {
    try arena.mission.init(gpa);
    errdefer arena.mission.deinit();
    arena.mode = mode;
    arena.explosions = null;
    arena.devices = .{};
    arena.pilots = @splat(null);
    switch (mode) {
        .training => {
            const all = arena.mission.objects;
            all.players = wire.slots;
            all.count = all.players;
        },
        .@"six-beacons" => {
            arena.explosions = try .init(gpa, null);
            errdefer arena.explosions.?.deinit();
            try simulation.prepareSixBeacons(&arena.mission, &arena.explosions.?);
        },
    }
}

pub fn deinit(arena: *Arena) void {
    if (arena.explosions) |*explosions| explosions.deinit();
    arena.mission.deinit();
}

fn effects(arena: *Arena) ?*game.explode.Explosions {
    return if (arena.explosions) |*explosions| explosions else null;
}

fn world(arena: *Arena) game.gameobj.World {
    return simulation.world(&arena.mission, arena.effects());
}

pub fn join(arena: *Arena, slot: u8) !wire.Admission {
    const mission = &arena.mission;
    const all = mission.objects;
    const x = if (arena.mode == .@"six-beacons") simulation.beacon_spawn_x[slot] else @as(f32, @floatFromInt(slot)) * spawn_spacing;
    _ = try game.create.createObject(all, &mission.tables, game.create.testing.no_models, slot, wire.arena_ship, 0, .{ x, 0, 0 }, &mission.random);
    errdefer game.create.resetSlot(.of(arena.world()), slot);
    if (arena.mode == .@"six-beacons") mission.slot(slot).object.radius = simulation.beacon_ship_radius;
    const pilot = try simulation.admit(arena.world(), slot);
    errdefer _ = game.create.Objects.leaveParticipant(arena.world(), pilot.participant);
    if (!try game.aigeneric.push(.of(arena.world()), slot, .multiplayer_control, .none)) return error.OrderFailed;
    arena.pilots[slot] = pilot;
    return .{ .slot = slot, .generation = pilot.participant.generation };
}

pub fn leave(arena: *Arena, slot: u8) void {
    const pilot = arena.pilots[slot] orelse return;
    _ = simulation.leave(arena.world(), pilot.participant);
    arena.pilots[slot] = null;
}

pub fn input(arena: *Arena, slot: u8, command: engine.input.flight.Command) bool {
    const pilot = arena.pilots[slot] orelse return false;
    return arena.mission.objects.submitPlayerCommand(pilot, .{ .flight = command });
}

pub fn step(arena: *Arena, tick: u32) !wire.Snapshot {
    if (simulation.step(&arena.mission, &arena.devices, arena.effects()) != .played) return error.ArenaEnded;
    const all = arena.mission.objects;
    var view: wire.Snapshot = .{ .tick = tick, .ships = @splat(null) };
    for (arena.pilots, &view.ships) |entry, *ship| {
        const pilot = entry orelse continue;
        const index = pilot.ship.resolve(all) orelse continue;
        const object = &all.slots[index].object;
        ship.* = .{
            .generation = pilot.participant.generation,
            .position = object.nextPosition(),
            .speed = object.speed,
            .throttle = object.last_throttle,
            .fuel = object.afterburner_fuel,
        };
        ship.*.?.face(object.root.next_orientation);
    }
    if (arena.mode == .@"six-beacons") {
        const captured = try simulation.BeaconView.capture(all);
        var beacons: [wire.beacon_count]wire.Beacon = undefined;
        for (captured.state.beacons, captured.positions, &beacons) |beacon, position, *entry| {
            entry.* = if (beacon.carrier) |carrier|
                .{ .carried = @intCast(carrier.participant.slot) }
            else
                .{ .loose = position };
        }
        view.objectives = .{ .six_beacons = beacons };
    }
    return view;
}
