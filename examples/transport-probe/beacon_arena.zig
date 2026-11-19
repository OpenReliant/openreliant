//! The headless Six Beacons map and its host-owned pilot slots.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const simulation = @import("arena_simulation");
const wire = @import("beacon_snapshot.zig");
const Arena = @This();

pub const first_marker = 5000;
const spawn_x = [_]f32{ first_marker, -8000, -6000 };
pub const pilot_count = spawn_x.len;

mission: game.gameobj.testing.Mission,
explosions: game.explode.Explosions,
devices: engine.input.Devices = .{},

pub fn init(arena: *Arena, allocator: std.mem.Allocator) !void {
    arena.devices = .{};
    try arena.mission.init(allocator);
    errdefer arena.mission.deinit();
    arena.explosions = try .init(allocator, null);
    errdefer arena.explosions.deinit();
    const all = arena.mission.objects;
    all.players = spawn_x.len;
    // Reserve the empty player slots before adding scenery. Admission creates the ship.
    all.count = all.players;
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

pub fn deinit(arena: *Arena) void {
    arena.explosions.deinit();
    arena.mission.deinit();
}

pub fn world(arena: *Arena) game.gameobj.World {
    return simulation.world(&arena.mission, &arena.explosions);
}

pub fn frame(arena: *Arena) !wire.View {
    if (simulation.step(&arena.mission, &arena.devices, &arena.explosions) != .played) return error.ArenaEnded;
    return wire.View.capture(arena.mission.objects, arena.mission.clock.frame_start);
}

pub fn admit(arena: *Arena, slot: u16) !game.players.ControlRef {
    const mission = &arena.mission;
    const index = try game.create.createObject(
        mission.objects,
        &mission.tables,
        game.create.testing.no_models,
        slot,
        .of(.predator),
        0,
        .{ spawn_x[slot], 0, 0 },
        &mission.random,
    );
    errdefer game.create.resetSlot(.of(arena.world()), index);
    mission.slot(index).object.radius = 10;
    return simulation.admit(arena.world(), index);
}

/// mp_player_departed (0x004B6890) runs the mode's leave handler before clearing the ship slot.
pub fn leave(arena: *Arena, participant: game.players.ParticipantRef) !void {
    if (!simulation.leave(arena.world(), participant)) return error.StaleAdmission;
}

test "a departing carrier drops its cargo before the slot gets a fresh ship" {
    var arena: Arena = undefined;
    try arena.init(std.testing.allocator);
    defer arena.deinit();
    const first = try arena.admit(0);
    _ = try arena.admit(1);
    const pickup = try arena.frame();
    try std.testing.expectEqual(1, pickup.state.countFor(first));
    const other = try arena.admit(2);
    const all = arena.mission.objects;
    all.playerState(first.participant.slot).?.membership.joined.kills.add(1, true);
    all.playerState(other.participant.slot).?.membership.joined.kills.add(2, true);
    try std.testing.expectEqualDeep(pickup.state, (try arena.frame()).state);
    try arena.leave(first.participant);
    try std.testing.expectEqual(null, first.ship.resolve(arena.mission.objects));
    const dropped = try wire.View.capture(arena.mission.objects, arena.mission.clock.frame_start);
    try std.testing.expectEqualDeep(pickup.state.beacons[0].object, dropped.state.beacons[0].object);
    try std.testing.expectEqual(null, dropped.state.beacons[0].carrier);
    try std.testing.expectEqual([3]f32{ first_marker + 8, 0, 0 }, dropped.positions[0]);
    const replacement = try arena.admit(0);
    try std.testing.expect(first.participant.generation != replacement.participant.generation);
    try std.testing.expect(first.ship.reuse != replacement.ship.reuse);
    try std.testing.expectEqual(0, all.arena_scenario.six_beacons.carried(replacement.participant));
    const state = all.playerState(replacement.participant.slot).?;
    const ship = &arena.mission.slot(replacement.ship.slot).object;
    try std.testing.expectEqual(0, state.membership.joined.kills.count);
    try std.testing.expectEqual(2, all.playerState(other.participant.slot).?.membership.joined.kills.count);
    ship.rack_count = 1;
    ship.racks[0] = .{ .type = .of(.raptor), .count = 3 };
    all.fitPlayerWeapons(replacement.participant.slot);
    const before = state.*;
    const position = ship.position();
    try std.testing.expect(!all.submitPlayerCommand(first, .{
        .flight = .{ .throttle = .{ .axis = 1 } },
        .weapons = .{ .launch_missile = true },
    }));
    try std.testing.expectEqualDeep(before, state.*);
    try std.testing.expectEqual(position, ship.position());
    try std.testing.expectEqual(3, ship.racks[0].count);
    try std.testing.expectEqualDeep(dropped.state, all.arena_scenario.six_beacons.snapshot());
    try std.testing.expectError(error.StaleAdmission, arena.leave(first.participant));
    try std.testing.expectEqualDeep(other, arena.mission.objects.playerBinding(2).?);
    try std.testing.expectEqualDeep(replacement, arena.mission.objects.playerBinding(0).?);
}
