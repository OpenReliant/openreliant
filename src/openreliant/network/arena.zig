//! Headless arenas for direct-IP sessions, driven by the regular host flight step.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const simulation = @import("arena_simulation");
const stock = @import("stock_arena.zig");
const wire = @import("wire.zig");
const Arena = @This();

const spawn_spacing: f32 = 12000;
pub const Mode = enum { training, @"six-beacons", @"nuclear-threat" };
const Pilot = struct { participant: game.players.ParticipantRef, fighter: wire.Fighter };
const Notice = game.deathmatch.six_beacons.Notice;
const notice_capacity = wire.slots + 2;

comptime {
    std.debug.assert(wire.slots == simulation.beacon_spawn_x.len);
}

mission: game.gameobj.testing.Mission,
mode: Mode,
explosions: ?game.explode.Explosions = null,
devices: engine.input.Devices = .{},
pilots: [wire.slots]?Pilot = @splat(null),
assets: ?*stock.Assets = null,
loaded: ?*game.mission.Loaded = null,
notices: [notice_capacity]Notice = undefined,
notice_count: usize = 0,
combat: [2 * game.guns.max_bullets + wire.slots]game.guns.FlightEffect = undefined,
combat_count: usize = 0,

pub fn init(arena: *Arena, gpa: std.mem.Allocator, mode: Mode, io: std.Io, directory: std.Io.Dir) !void {
    try arena.mission.init(gpa);
    arena.mode = mode;
    arena.explosions = null;
    arena.devices = .{};
    arena.pilots = @splat(null);
    arena.assets = null;
    arena.loaded = null;
    arena.notice_count = 0;
    arena.combat_count = 0;
    errdefer arena.deinit();
    switch (mode) {
        .training => {
            const all = arena.mission.objects;
            all.players = wire.slots;
            all.count = all.players;
        },
        .@"six-beacons" => {
            arena.explosions = try .init(gpa, null);
            try simulation.prepareSixBeacons(&arena.mission, &arena.explosions.?);
        },
        .@"nuclear-threat" => {
            const assets = try stock.Assets.open(gpa, io, directory, &arena.mission.tables, arena.mission.objects);
            arena.assets = assets;
            arena.explosions = try .init(gpa, null);
            arena.loaded = try assets.files.load(gpa, .nuclear_threat, arena.world());
            if (arena.mission.objects.arena_scenario != .six_beacons) return error.ArenaScriptDidNotStart;
        },
    }
}

pub fn deinit(arena: *Arena) void {
    const gpa = arena.mission.objects.gpa;
    if (arena.loaded) |loaded| loaded.destroy();
    if (arena.explosions) |*explosions| explosions.deinit();
    arena.mission.deinit();
    if (arena.assets) |assets| assets.close(gpa);
}

fn effects(arena: *Arena) ?*game.explode.Explosions {
    return if (arena.explosions) |*explosions| explosions else null;
}

fn world(arena: *Arena) game.gameobj.World {
    var scene = simulation.world(&arena.mission, arena.effects());
    if (arena.assets) |assets| scene.spawn = .{ .tables = &arena.mission.tables, .types = assets.library.types() };
    if (arena.loaded) |loaded| scene = stock.withMission(scene, loaded);
    scene.beacon_notices = .{ .context = arena, .send = note };
    if (arena.assets != null) scene.gun_effects = .{ .context = arena, .send = noteCombat };
    return scene;
}

fn noteCombat(context: *anyopaque, effect: game.guns.FlightEffect) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    switch (effect) {
        .shot => |shot| if (shot.owner >= wire.slots) return,
        .nova => |beam| if (beam.owner.slot >= wire.slots) return,
        .impact => {},
    }
    if (arena.combat_count == arena.combat.len) return;
    arena.combat[arena.combat_count] = effect;
    arena.combat_count += 1;
}

fn note(context: *anyopaque, notice: Notice) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    if (arena.notice_count == arena.notices.len) return;
    arena.notices[arena.notice_count] = notice;
    arena.notice_count += 1;
}

fn createShip(arena: *Arena, slot: u8, fighter: wire.Fighter) !void {
    const mission = &arena.mission;
    const all = mission.objects;
    const x = if (arena.mode == .@"six-beacons") simulation.beacon_spawn_x[slot] else @as(f32, @floatFromInt(slot)) * spawn_spacing;
    _ = try game.create.createObject(all, &mission.tables, game.create.testing.no_models, slot, fighter.kind(), 0, .{ x, 0, 0 }, &mission.random);
    errdefer game.create.resetSlot(.of(arena.world()), slot);
    if (arena.mode == .@"six-beacons") mission.slot(slot).object.radius = simulation.beacon_ship_radius;
    if (!try game.aigeneric.push(.of(arena.world()), slot, .multiplayer_control, .none)) return error.OrderFailed;
}

pub fn join(arena: *Arena, slot: u8, fighter: wire.Fighter) !wire.Admission {
    const scene = arena.world();
    const participant = scene.objects.joinParticipant(slot) orelse return error.JoinFailed;
    errdefer _ = game.create.Objects.leaveParticipant(scene, participant);
    const pilot: Pilot = .{ .participant = participant, .fighter = fighter };
    try arena.spawnPilot(pilot, true);
    arena.pilots[slot] = pilot;
    return .{ .slot = slot, .generation = participant.generation, .scenario = if (arena.assets != null) .nuclear_threat else null };
}

fn spawnPilot(arena: *Arena, pilot: Pilot, first: bool) !void {
    const scene = arena.world();
    const slot = pilot.participant.slot;
    if (arena.assets != null) return game.deathmatch.spawn.reset(scene, pilot.participant, pilot.fighter.kind(), if (first and slot == 0) slot else null);
    game.create.resetSlot(.of(scene), slot);
    try arena.createShip(@intCast(slot), pilot.fighter);
    errdefer game.create.resetSlot(.of(scene), slot);
    _ = scene.objects.bindParticipant(pilot.participant, .of(scene.objects, slot)) orelse return error.BindFailed;
}

pub fn selectShip(arena: *Arena, slot: u8, fighter: wire.Fighter) !void {
    const pilot = if (arena.pilots[slot]) |*joined| joined else return;
    if (pilot.fighter == fighter) return;
    try arena.spawnPilot(.{ .participant = pilot.participant, .fighter = fighter }, true);
    pilot.fighter = fighter;
}

pub fn leave(arena: *Arena, slot: u8) void {
    const pilot = arena.pilots[slot] orelse return;
    _ = simulation.leave(arena.world(), pilot.participant);
    arena.pilots[slot] = null;
}

pub fn input(arena: *Arena, slot: u8, command: engine.input.flight.Command, fire_for: ?u32) bool {
    const all = arena.mission.objects;
    if (arena.pilots[slot] == null) return false;
    // An admitted pilot stays connected while the old ship finishes exploding.
    if (!all.hasBoundPlayerShip(slot)) return true;
    const pilot = all.playerBinding(slot).?;
    return all.submitPlayerCommand(pilot, .{
        .flight = command,
        .weapons = .{ .fire_guns = fire_for == pilot.ship.reuse and arena.mode == .@"nuclear-threat" },
    });
}

pub fn step(arena: *Arena, tick: u32) !wire.Snapshot {
    arena.notice_count = 0;
    arena.combat_count = 0;
    arena.mission.clock.advanceTimer(game.gameobj.ticks_per_step);
    if (game.main.gameFrames(&arena.mission.clock, &arena.devices, null, arena.world(), .in_turn, arena.loaded) != .played) return error.ArenaEnded;
    const all = arena.mission.objects;
    var view: wire.Snapshot = .{ .tick = tick, .ships = @splat(null) };
    for (arena.pilots, &view.ships, 0..) |entry, *ship, at| {
        const pilot = entry orelse continue;
        const index: u16 = @intCast(at);
        if (all.playerBinding(index) == null) {
            if (arena.assets == null) continue;
            try arena.spawnPilot(pilot, false);
        }
        const object = &all.slots[index].object;
        const score = all.player_states[index].membership.joined;
        ship.* = .{
            .generation = pilot.participant.generation,
            .reuse = all.reuses[index],
            .fighter = pilot.fighter,
            .position = object.nextPosition(),
            .speed = object.speed,
            .throttle = object.last_throttle,
            .fuel = object.afterburner_fuel,
            .shields = object.shields,
            .armor = object.armor,
            .kills = score.kills.count,
            .deaths = score.deaths,
        };
        ship.*.?.face(object.root.next_orientation);
    }
    if (all.arena_scenario == .six_beacons) {
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

test "the pilot stays admitted through destruction and old trigger input expires on respawn" {
    var arena: Arena = undefined;
    try arena.init(std.testing.allocator, .training, std.testing.io, .cwd());
    defer arena.deinit();
    _ = try arena.join(0, .predator);
    arena.mode = .@"nuclear-threat";
    const all = arena.mission.objects;
    const first = all.playerBinding(0).?.ship.reuse;
    try std.testing.expect(arena.input(0, .{}, first));
    try std.testing.expect(all.playerCommand(0).?.weapons.fire_guns);
    all.slots[0].object.flags.exploding = true;
    try std.testing.expect(arena.input(0, .{}, first));
    try std.testing.expectEqual(null, all.playerCommand(0));
    try arena.selectShip(0, .shroud);
    try std.testing.expect(arena.input(0, .{}, first));
    try std.testing.expect(!all.playerCommand(0).?.weapons.fire_guns);
    try std.testing.expect(arena.input(0, .{}, all.playerBinding(0).?.ship.reuse));
    try std.testing.expect(all.playerCommand(0).?.weapons.fire_guns);
    try std.testing.expect(arena.input(0, .{}, null));
    try std.testing.expect(!all.playerCommand(0).?.weapons.fire_guns);
}
