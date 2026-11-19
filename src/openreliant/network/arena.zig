//! An original training arena for direct-IP sessions. It uses the regular host flight step.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const simulation = @import("arena_simulation");
const wire = @import("wire.zig");
const Arena = @This();

const spawn_spacing: f32 = 12000;
const steering_scale: f32 = 0.1;
pub const step_us = game.gameobj.ticks_per_step * std.time.us_per_s / game.main.ticks_per_second;

mission: game.gameobj.testing.Mission,
devices: engine.input.Devices = .{},
pilots: [wire.slots]?game.players.ControlRef = @splat(null),

pub fn init(arena: *Arena, gpa: std.mem.Allocator) !void {
    try arena.mission.init(gpa);
    arena.devices = .{};
    arena.pilots = @splat(null);
    const all = arena.mission.objects;
    all.players = wire.slots;
    all.count = all.players;
}

pub fn deinit(arena: *Arena) void {
    arena.mission.deinit();
}

fn world(arena: *Arena) game.gameobj.World {
    return simulation.world(&arena.mission, null);
}

pub fn join(arena: *Arena, slot: u8) !wire.Admission {
    const mission = &arena.mission;
    const all = mission.objects;
    const x = @as(f32, @floatFromInt(slot)) * spawn_spacing;
    _ = try game.create.createObject(all, &mission.tables, game.create.testing.no_models, slot, .of(.predator), 0, .{ x, 0, 0 }, &mission.random);
    errdefer game.create.resetSlot(.of(arena.world()), slot);
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

pub fn input(arena: *Arena, slot: u8, steering: wire.Steering) bool {
    const pilot = arena.pilots[slot] orelse return false;
    const axis = @as(f32, @floatFromInt(@backingInt(steering))) * steering_scale;
    return arena.mission.objects.submitPlayerCommand(pilot, .{ .flight = .{
        .steering = .{ .axes = .{ axis, 0, 0 } },
        .throttle = .{ .axis = 1 },
    } });
}

pub fn step(arena: *Arena, tick: u32) !wire.Snapshot {
    if (simulation.step(&arena.mission, &arena.devices, null) != .played) return error.ArenaEnded;
    const all = arena.mission.objects;
    var view: wire.Snapshot = .{ .tick = tick, .ships = @splat(null) };
    for (arena.pilots, &view.ships) |entry, *ship| {
        const pilot = entry orelse continue;
        const index = pilot.ship.resolve(all) orelse continue;
        ship.* = .{
            .generation = pilot.participant.generation,
            .position = all.slots[index].object.nextPosition(),
        };
    }
    return view;
}
