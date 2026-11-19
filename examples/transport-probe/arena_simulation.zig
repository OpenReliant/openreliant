//! Simulation setup shared by the headless arena workloads.
const engine = @import("openreliant").engine;
const game = engine.game;

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

pub fn step(mission: *game.gameobj.testing.Mission, devices: *engine.input.Devices, explosions: ?*game.explode.Explosions) game.main.FrameEnd {
    mission.clock.advanceTimer(game.gameobj.ticks_per_step);
    return game.main.gameFrames(&mission.clock, devices, null, world(mission, explosions), .in_turn, null);
}
