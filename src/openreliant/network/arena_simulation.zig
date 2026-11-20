//! Pilot admission and simulation steps shared by the headless arenas.
const engine = @import("openreliant").engine;
const game = engine.game;
const beacons = game.deathmatch.six_beacons;

pub const beacon_spawn_x = [_]f32{ 5000, -8000, -6000, -10000, -12000, -14000, -16000, -18000 };
pub const beacon_ship_radius: f32 = 10;
const beacon_spacing = 1000;
const gate_radius: f32 = 100;
const pickup_radius: f32 = 20;
const inactive_pickup_x: f32 = 20000;

/// Set up the headless Six Beacons test arena and its reserved launch positions.
pub fn prepareSixBeacons(mission: *game.gameobj.testing.Mission, explosions: *game.explode.Explosions) !void {
    const all = mission.objects;
    all.players = beacon_spawn_x.len;
    all.count = all.players;
    const gate = try mission.add(.of(.dm_beacon_gate), @splat(0));
    mission.slot(gate).object.radius = gate_radius;
    for (0..beacons.required) |i| {
        const x = beacon_spawn_x[0] + @as(f32, @floatFromInt(i * beacon_spacing));
        const marker = try mission.add(.of(.beacon_marker), .{ x, 0, 0 });
        mission.slot(marker).object.radius = 0;
        const beacon = try mission.add(.of(.dm_beacon), .{ inactive_pickup_x, 0, 0 });
        mission.slot(beacon).object.radius = pickup_radius;
    }
    try beacons.Round.start(world(mission, explosions), .free_for_all);
}

pub const BeaconView = struct {
    state: beacons.Snapshot,
    positions: [beacons.required][3]f32,

    pub fn capture(all: *const game.create.Objects) !BeaconView {
        const state = all.arena_scenario.six_beacons.snapshot();
        var positions: [beacons.required][3]f32 = undefined;
        for (state.beacons, &positions) |beacon, *position| {
            const index = beacon.object.resolve(all) orelse return error.MissingBeacon;
            const object = &all.slots[index].object;
            if (object.flags.disabled != (beacon.carrier != null)) return error.WrongVisibility;
            position.* = object.position();
        }
        return .{ .state = state, .positions = positions };
    }
};

pub fn world(mission: *game.gameobj.testing.Mission, explosions: ?*game.explode.Explosions) game.gameobj.World {
    var simulation = mission.world();
    simulation.damage_rules = .{ .arena = null };
    simulation.explosions = explosions;
    return simulation;
}

pub fn admit(simulation: game.gameobj.World, slot: u16) !game.players.ControlRef {
    const all = simulation.objects;
    const pilot = all.joinParticipant(slot) orelse return error.JoinFailed;
    errdefer _ = game.create.Objects.leaveParticipant(simulation, pilot);
    return all.bindParticipant(pilot, .of(all, slot)) orelse error.BindFailed;
}

pub fn leave(simulation: game.gameobj.World, participant: game.players.ParticipantRef) bool {
    const binding = simulation.objects.playerBinding(participant.slot);
    if (!game.create.Objects.leaveParticipant(simulation, participant)) return false;
    if (binding) |pilot| game.create.resetSlot(.of(simulation), pilot.ship.slot);
    return true;
}

pub fn step(mission: *game.gameobj.testing.Mission, devices: *engine.input.Devices, explosions: ?*game.explode.Explosions) game.main.FrameEnd {
    mission.clock.advanceTimer(game.gameobj.ticks_per_step);
    return game.main.gameFrames(&mission.clock, devices, null, world(mission, explosions), .in_turn, null);
}
