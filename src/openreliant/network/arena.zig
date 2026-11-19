//! Headless arenas for direct-IP sessions, driven by the regular host flight step.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const simulation = @import("arena_simulation");
const stock = @import("stock_arena.zig");
const wire = @import("wire.zig");
const Arena = @This();

const spawn_spacing: f32 = 12000;
pub const Mode = enum {
    training,
    @"six-beacons",
    @"nuclear-threat",
    @"asteroid-field",
    @"dark-reign",

    pub fn scenario(mode: Mode) ?wire.Scenario {
        return switch (mode) {
            .training, .@"six-beacons" => null,
            .@"nuclear-threat" => .nuclear_threat,
            .@"asteroid-field" => .asteroid_field,
            .@"dark-reign" => .dark_reign,
        };
    }

    pub fn stockMode(chosen: wire.Scenario) !Mode {
        return switch (chosen) {
            .nuclear_threat => .@"nuclear-threat",
            .asteroid_field => .@"asteroid-field",
            .dark_reign => .@"dark-reign",
            else => error.UnsupportedArena,
        };
    }
};
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
rocks: stock.RockSlots = .{},
notices: [notice_capacity]Notice = undefined,
notice_count: usize = 0,
wrecks: [wire.slots]?wire.Wreck = @splat(null),
combat: [2 * game.guns.max_bullets + wire.slots]game.guns.FlightEffect = undefined,
combat_count: usize = 0,
decoys: ?game.cloak.Countermeasures = null,
waves: ?game.shockwave.Shockwaves = null,
cannons: ?game.aiioncan.Cannons = null,

pub fn create(gpa: std.mem.Allocator, mode: Mode, io: std.Io, directory: std.Io.Dir) !*Arena {
    const arena = try gpa.create(Arena);
    errdefer gpa.destroy(arena);
    try arena.init(gpa, mode, io, directory);
    return arena;
}

fn init(arena: *Arena, gpa: std.mem.Allocator, mode: Mode, io: std.Io, directory: std.Io.Dir) !void {
    try arena.mission.init(gpa);
    arena.mode = mode;
    arena.explosions = null;
    arena.devices = .{};
    arena.pilots = @splat(null);
    arena.assets = null;
    arena.loaded = null;
    arena.rocks = .{};
    arena.notice_count = 0;
    arena.wrecks = @splat(null);
    arena.combat_count = 0;
    arena.decoys = null;
    arena.waves = null;
    arena.cannons = null;
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
        .@"nuclear-threat", .@"asteroid-field", .@"dark-reign" => {
            // mission_start seeds the game's random stream afresh (0x004936AE).
            var seed: u64 = undefined;
            io.random(std.mem.asBytes(&seed));
            arena.mission.random = .init(seed);
            const assets = try stock.Assets.open(gpa, io, directory, &arena.mission.tables, arena.mission.objects);
            arena.assets = assets;
            arena.explosions = try .init(gpa, null);
            arena.decoys = .init(gpa, assets.mounts.mounts());
            arena.waves = try .create(gpa, &assets.images, .round);
            const scenario = mode.scenario().?;
            if (scenario == .dark_reign) arena.cannons = try .init(gpa, &assets.images);
            arena.loaded = try assets.files.load(gpa, scenario, arena.world());
            const started = switch (scenario) {
                .nuclear_threat => arena.mission.objects.arena_scenario == .six_beacons,
                .asteroid_field => arena.mission.objects.arena_scenario == .asteroid_field,
                .dark_reign => arena.mission.objects.arena_scenario == .dark_reign,
                else => unreachable,
            };
            if (!started) return error.ArenaScriptDidNotStart;
            if (scenario.hasPowerUps()) arena.rocks = try .collect(arena.mission.objects);
        },
    }
}

/// Prepare a stock arena with the lobby's admissions. Its objects hold pointers to its ship tables.
pub fn prepareStock(arena: *const Arena, scenario: wire.Scenario, io: std.Io, directory: std.Io.Dir) !*Arena {
    const gpa = arena.mission.objects.gpa;
    const next = try create(gpa, try .stockMode(scenario), io, directory);
    errdefer next.destroy();
    const all = next.mission.objects;
    all.participant_generation = arena.mission.objects.participant_generation;
    for (arena.pilots, &next.pilots) |entry, *new| {
        const pilot = entry orelse continue;
        const slot = pilot.participant.slot;
        all.player_states[slot] = .{ .membership = .{ .joined = .{ .generation = pilot.participant.generation } } };
        try next.spawnPilot(pilot, true);
        new.* = pilot;
    }
    return next;
}

pub fn destroy(arena: *Arena) void {
    const gpa = arena.mission.objects.gpa;
    arena.deinit();
    gpa.destroy(arena);
}

fn deinit(arena: *Arena) void {
    const gpa = arena.mission.objects.gpa;
    if (arena.loaded) |loaded| loaded.destroy();
    if (arena.decoys) |*decoys| decoys.reset();
    if (arena.waves) |*waves| waves.deinit(gpa);
    if (arena.cannons) |*cannons| cannons.deinit();
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
    if (arena.decoys) |*decoys| scene.countermeasures = decoys;
    if (arena.waves) |*waves| scene.shockwaves = waves;
    if (arena.cannons) |*cannons| scene.ion_cannons = cannons;
    if (arena.assets != null) {
        scene.gun_effects = .{ .context = arena, .send = noteCombat };
        scene.arena_wrecks = .{ .context = arena, .send = noteWreck };
    }
    return scene;
}

fn noteWreck(context: *anyopaque, wreck: wire.Wreck) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    arena.wrecks[wreck.pilot.participant.slot] = wreck;
}

fn noteCombat(context: *anyopaque, effect: game.guns.FlightEffect) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    switch (effect) {
        .shot => |shot| if (shot.owner >= wire.slots) return,
        .nova => |beam| if (beam.owner.slot >= wire.slots) return,
        .impact, .wall => {},
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
    return .{ .slot = slot, .generation = participant.generation };
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

pub fn input(arena: *Arena, slot: u8, command: engine.input.flight.Command, fire_for: ?u32, order: ?wire.ordnance.Order) bool {
    const all = arena.mission.objects;
    if (arena.pilots[slot] == null) return false;
    // An admitted pilot stays connected while the old ship finishes exploding.
    if (!all.hasBoundPlayerShip(slot)) return true;
    if (all.slots[slot].running(.deathmatch_respawn_effect) != null) return true;
    const pilot = all.playerBinding(slot).?;
    const stock_mode = arena.mode.scenario() != null;
    var submitted: game.players.Command = .{
        .flight = command,
        .weapons = .{ .fire_guns = fire_for == pilot.ship.reuse and stock_mode },
    };
    if (stock_mode) if (order) |weapons| {
        if (weapons.aim.reuse == pilot.ship.reuse) {
            const target = if (weapons.aim.target) |ref| weaponTarget(all, slot, ref) else null;
            if (game.ai.controlEntry(all, slot)) |entry| {
                if (target) |ref| {
                    if (entry.target.slotIn(all) != ref.slot) submitted.target = .{ .aim = .{ .object = ref } };
                } else if (entry.target != .none) submitted.target = .clear;
            }
            submitted.weapons.launch_missile = weapons.presses.launch and (weapons.aim.target == null or target != null);
            submitted.weapons.countermeasures = weapons.presses.countermeasures;
            submitted.weapons.rotate_missiles = weapons.presses.turn();
        }
    };
    return all.submitPlayerCommand(pilot, submitted);
}

fn weaponTarget(all: *game.create.Objects, source: u16, ref: game.gameobj.ObjectRef) ?game.gameobj.ObjectRef {
    const slot = ref.resolve(all) orelse return null;
    if (slot == source or all.playerBinding(slot) == null or !game.ai.targetValid(all, .at(slot, null), .{})) return null;
    return ref;
}

pub fn step(arena: *Arena, tick: u32) !wire.Snapshot {
    arena.notice_count = 0;
    arena.wrecks = @splat(null);
    arena.combat_count = 0;
    arena.mission.clock.advanceTimer(game.gameobj.ticks_per_step);
    if (game.main.gameFrames(&arena.mission.clock, &arena.devices, null, arena.world(), .in_turn, arena.loaded) != .played) return error.ArenaEnded;
    return arena.snapshot(tick);
}

/// Capture an arena view at the current tick. A pilot joining during a pause still needs one.
pub fn snapshot(arena: *Arena, tick: u32) !wire.Snapshot {
    const all = arena.mission.objects;
    var view: wire.Snapshot = .{ .tick = tick, .scenario = arena.mode.scenario(), .ships = @splat(null) };
    view.rocks = arena.rocks.capture(all);
    if (all.arena_scenario.powerUps()) |round| {
        view.pickups = round.pickups.visible(all);
        for (&view.mines, 0..) |*entry, i| {
            const index = round.mine_start + @as(u16, @intCast(i));
            const object = &all.slots[index].object;
            if (!object.created or object.flags.disabled or object.flags.stand_in) continue;
            entry.* = .{ .position = object.nextPosition(), .angles = wire.packFacing(object.root.next_orientation), .reuse = all.reuses[index] };
        }
    }
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
            .cloaked = if (all.slots[index].cloak) |cloak| !cloak.going else false,
            .respawn = game.deathmatch.respawn.remaining(&all.slots[index], arena.mission.clock.frame_start),
            .at_wall = if (all.arena_boundary) |*boundary| boundary.outside(object.nextPosition()) else false,
            .dying = object.flags.exploding,
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
        if (arena.explosions) |*flights| if (flights.uber.blast) |*blast| {
            view.blast = .{
                .owner = @intCast(blast.owner.object.slot),
                .started = blast.started,
                .size = blast.size,
                .position = blast.place.position,
                .angles = wire.packFacing(blast.place.orientation),
            };
        };
    }
    if (all.arena_scenario == .dark_reign) {
        const round = &all.arena_scenario.dark_reign.relay;
        const object = &all.slots[round.relay.resolve(all) orelse return error.MissingCommsRelay].object;
        const tower = round.tower.resolve(all) orelse return error.MissingDarkReign;
        view.objectives = .{ .dark_reign = .{
            .relay = if (round.carrier) |carrier| .{ .carried = @intCast(carrier.participant.slot) } else .{ .loose = object.position() },
            .yaw = wire.packAngle(game.aiioncan.yaw(all, tower)),
            .shot = game.aiioncan.capture(arena.world(), tower),
        } };
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
    try std.testing.expect(arena.input(0, .{}, first, null));
    try std.testing.expect(all.playerCommand(0).?.weapons.fire_guns);
    all.slots[0].object.flags.exploding = true;
    try std.testing.expect(arena.input(0, .{}, first, null));
    try std.testing.expectEqual(null, all.playerCommand(0));
    try arena.selectShip(0, .shroud);
    try std.testing.expect(arena.input(0, .{}, first, .{ .aim = .{ .reuse = first }, .presses = .{ .launch = true, .countermeasures = true } }));
    try std.testing.expect(!all.playerCommand(0).?.weapons.fire_guns);
    try std.testing.expect(!all.playerCommand(0).?.weapons.launch_missile);
    try std.testing.expect(!all.playerCommand(0).?.weapons.countermeasures);
    try std.testing.expect(arena.input(0, .{}, all.playerBinding(0).?.ship.reuse, null));
    try std.testing.expect(all.playerCommand(0).?.weapons.fire_guns);
    try std.testing.expect(arena.input(0, .{}, null, null));
    try std.testing.expect(!all.playerCommand(0).?.weapons.fire_guns);
}
