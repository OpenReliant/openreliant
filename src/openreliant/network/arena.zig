//! Headless arenas for direct-IP sessions, driven by the regular host flight step.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const simulation = @import("arena_simulation");
const stock = @import("stock_arena.zig");
const wire = @import("wire.zig");
const Arena = @This();

const Campaign = struct {
    gates: game.wgate.Gates,
    radio: game.radio.Radio,
    lines: [game.radio.queue_size + game.radio.report_count]wire.CampaignLine = undefined,
    line_count: usize = 0,
    display: game.hud.State = .{},
    environment: game.environfx.Environment = .{},
    cues: game.main.cues.Cues,
    nebula: u8 = game.nebula.default_nebula,
    camera: game.camera.Camera = .{},
    travel: wire.MissionView.Travel = .{},
    ready_since: u32 = 0,
    finished: bool = false,
    started_after: u32 = 0,

    fn say(context: *anyopaque, tick: i32, line: game.radio.RoutedLine) void {
        const campaign: *Campaign = @ptrCast(@alignCast(context));
        if (campaign.line_count == campaign.lines.len) return;
        campaign.lines[campaign.line_count] = .{ .tick = tick, .line = line };
        campaign.line_count += 1;
    }
};

const spawn_spacing: f32 = 12000;
pub const Mode = enum {
    training,
    @"six-beacons",
    @"nuclear-threat",
    @"asteroid-field",
    @"dark-reign",
    @"tag-bomb",
    @"hunt-the-shadow",
    vampires,

    pub fn scenario(mode: Mode) ?wire.Scenario {
        return switch (mode) {
            .training, .@"six-beacons" => null,
            .@"nuclear-threat" => .nuclear_threat,
            .@"asteroid-field" => .asteroid_field,
            .@"dark-reign" => .dark_reign,
            .@"tag-bomb" => .tag_bomb,
            .@"hunt-the-shadow" => .hunt_the_shadow,
            .vampires => .vampires,
        };
    }

    pub fn stockMode(chosen: wire.Scenario) Mode {
        for (std.enums.values(Mode)) |mode| {
            if (mode.scenario() == chosen) return mode;
        }
        unreachable;
    }
};
const Pilot = struct {
    participant: game.players.ParticipantRef,
    fighter: wire.Fighter,
    team: game.players.ArenaTeam = .first,
    loadout: ?wire.CampaignLoadout = null,
    // Keep the last pose while an admitted pilot waits for a free spawn marker.
    last_ship: ?wire.Ship = null,
    /// Whether the pilot has yet to get a ship in this round. Their first goes to the marker
    /// with their slot's number (`spawn.reset`).
    first_spawn: bool = true,
};
const Notice = union(enum) {
    beacon: game.deathmatch.six_beacons.Notice,
    uber_kill: game.deathmatch.UberKill,
    tag_bomb: game.deathmatch.tag_bomb.Notice,
    shadow: game.deathmatch.hunt_the_shadow.Notice,
    vampires: game.deathmatch.vampires.Notice,
};
// A gate delivery can announce the strike and a kill for each other pilot in the same step.
const notice_capacity = 2 * wire.slots + 2;

comptime {
    std.debug.assert(wire.slots == simulation.beacon_spawn_x.len);
}

mission: game.gameobj.testing.Mission,
mode: Mode,
explosions: ?game.explode.Explosions = null,
devices: engine.input.Devices = .{},
pilots: [wire.slots]?Pilot = @splat(null),
/// Pilots whose ship a step could not make, for the host to let go.
unspawnable: [wire.slots]bool = @splat(false),
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
campaign: ?*Campaign = null,
music: wire.MissionMusic.Queue = .{},
last_music: ?wire.MissionMusic = null,
options: game.deathmatch.Options = .{},

pub fn create(gpa: std.mem.Allocator, mode: Mode, io: std.Io, directory: std.Io.Dir) !*Arena {
    return createWithOptions(gpa, mode, .{}, io, directory);
}

pub fn createWithOptions(gpa: std.mem.Allocator, mode: Mode, options: game.deathmatch.Options, io: std.Io, directory: std.Io.Dir) !*Arena {
    const arena = try gpa.create(Arena);
    errdefer gpa.destroy(arena);
    try arena.init(gpa, mode, options, io, directory);
    return arena;
}

fn init(arena: *Arena, gpa: std.mem.Allocator, mode: Mode, options: game.deathmatch.Options, io: std.Io, directory: std.Io.Dir) !void {
    try arena.mission.init(gpa);
    arena.mode = mode;
    arena.options = options;
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
    arena.campaign = null;
    arena.music = .{};
    arena.last_music = null;
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
        .@"nuclear-threat", .@"asteroid-field", .@"dark-reign", .@"tag-bomb", .@"hunt-the-shadow", .vampires => {
            // mission_start seeds the game's random stream afresh (0x004936AE).
            var seed: u64 = undefined;
            io.random(std.mem.asBytes(&seed));
            arena.mission.random = .init(seed);
            const assets = try arena.loadAssets(io, directory);
            const scenario = mode.scenario().?;
            if (scenario == .dark_reign) arena.cannons = try .init(gpa, &assets.images);
            arena.loaded = try assets.files.load(gpa, scenario, arena.world());
            if (std.meta.activeTag(arena.mission.objects.arena_scenario) != std.meta.activeTag(scenario.record().rules)) return error.ArenaScriptDidNotStart;
            if (scenario.hasPowerUps()) arena.rocks = try .collect(arena.mission.objects);
        },
    }
}

fn loadAssets(arena: *Arena, io: std.Io, directory: std.Io.Dir) !*stock.Assets {
    const gpa = arena.mission.objects.gpa;
    const assets = try stock.Assets.open(gpa, io, directory, &arena.mission.tables, arena.mission.objects);
    arena.assets = assets;
    arena.explosions = try .init(gpa, null);
    arena.decoys = .init(gpa, assets.mounts.mounts());
    arena.waves = try .create(gpa, &assets.images, .round);
    return assets;
}

/// Prepare a stock arena with the lobby's admissions. Its objects hold pointers to its ship tables.
pub fn prepareStock(arena: *const Arena, scenario: wire.Scenario, teams: bool, options: game.deathmatch.Options, io: std.Io, directory: std.Io.Dir) !*Arena {
    const gpa = arena.mission.objects.gpa;
    const next = try createWithOptions(gpa, .stockMode(scenario), options, io, directory);
    errdefer next.destroy();
    next.carryAdmissions(arena);
    next.setTeams(teams);
    const all = next.mission.objects;
    @memcpy(all.reuses[0..wire.slots], arena.mission.objects.reuses[0..wire.slots]);
    for (next.pilots) |entry| {
        const pilot = entry orelse continue;
        try next.spawnPilot(pilot, true);
    }
    return next;
}

fn carryAdmissions(next: *Arena, staging: *const Arena) void {
    const all = next.mission.objects;
    all.participant_generation = staging.mission.objects.participant_generation;
    next.pilots = staging.pilots;
    for (&next.pilots, all.player_states[0..wire.slots]) |*entry, *state| {
        if (entry.*) |*pilot| {
            pilot.last_ship = null;
            pilot.first_spawn = true;
            state.* = .{ .membership = .{ .joined = .{ .generation = pilot.participant.generation } } };
        }
    }
}

/// Keep the lobby admissions while unloading the finished mission and its objects.
pub fn betweenMissions(arena: *const Arena, io: std.Io, directory: std.Io.Dir) !*Arena {
    const staging = try create(arena.mission.objects.gpa, .training, io, directory);
    staging.carryAdmissions(arena);
    @memcpy(staging.mission.objects.reuses[0..wire.slots], arena.mission.objects.reuses[0..wire.slots]);
    return staging;
}

pub fn setTeams(arena: *Arena, enabled: bool) void {
    const all = arena.mission.objects;
    all.arena_scores = if (enabled) .{ .teams = .initFill(.{}) } else .free_for_all;
    if (enabled) for (arena.pilots) |entry| {
        const pilot = entry orelse continue;
        _ = all.setParticipantTeam(pilot.participant, pilot.team);
    };
}

pub fn pickTeam(arena: *Arena, slot: u8, team: wire.Team) void {
    const pilot = &arena.pilots[slot].?;
    pilot.team = team;
    const all = arena.mission.objects;
    if (all.arena_scores == .teams) _ = all.setParticipantTeam(pilot.participant, team);
}

pub fn leastPopulatedTeam(arena: *const Arena, joining: u8) wire.Team {
    var counts: std.EnumArray(wire.Team, u8) = .initFill(0);
    for (arena.pilots, 0..) |entry, slot| {
        const pilot = entry orelse continue;
        if (slot != joining) counts.getPtr(pilot.team).* += 1;
    }
    var smallest: wire.Team = .first;
    for (std.enums.values(wire.Team)) |team| {
        if (counts.get(team) < counts.get(smallest)) smallest = team;
    }
    return smallest;
}

/// Start a campaign mission from the installed data and bind its created ships to the lobby crew.
pub fn prepareCampaign(staging: *const Arena, leg: wire.NextMission, io: std.Io, directory: std.Io.Dir, checkpoint: *const game.gameflow.Campaign, wingmen: *const game.pilots.Wingmen) !*Arena {
    const gpa = staging.mission.objects.gpa;
    const arena = try create(gpa, .training, io, directory);
    errdefer arena.destroy();
    const assets = try arena.loadAssets(io, directory);
    const campaign = try gpa.create(Campaign);
    const gates = game.wgate.Gates.init(gpa, &assets.images, .low, .{}) catch |err| {
        gpa.destroy(campaign);
        return err;
    };
    campaign.* = .{
        .gates = gates,
        .radio = .openAt(gpa, io, directory, game.radio.speech_archive, game.hudmovie.archive_path),
        .cues = .{ .gpa = gpa },
        .started_after = leg.after,
    };
    campaign.radio.output = .{ .context = campaign, .send = Campaign.say };
    arena.campaign = campaign;
    arena.carryAdmissions(staging);
    const all = arena.mission.objects;
    all.wingmen = wingmen.*;
    all.mission25_second_part = leg.second_part;
    all.players = 0;
    for (arena.pilots, 0..) |entry, slot| {
        if (entry) |pilot| {
            if (slot >= wire.cooperative_slots) return error.InvalidCampaignCrew;
            all.players = @intCast(slot + 1);
            if (pilot.loadout) |fit| {
                all.loadout_ships[slot] = fit.ship.kind();
                all.loadout_racks[slot] = fit.racks;
            }
        }
    }
    const file = (try assets.files.readMission(gpa, leg.number, leg.second_part)) orelse return error.MissingCampaignMission;
    var seed: u64 = undefined;
    io.random(std.mem.asBytes(&seed));
    arena.loaded = try game.main.startMission(gpa, .{
        .orders = .of(arena.world()),
        .clock = &arena.mission.clock,
        .tables = &arena.mission.tables,
        .types = &assets.library,
        .display = &campaign.display,
        .campaign = checkpoint,
        .seed = seed,
    }, file.image, leg.number);
    for (&arena.pilots, 0..) |*entry, slot| {
        if (entry.*) |*pilot| {
            if (all.playerBinding(@intCast(slot)) == null) return error.MissingCampaignPilotShip;
            const kind = all.slots[slot].object.type.base().untwinned();
            if (kind != .kamov) pilot.fighter = std.enums.fromInt(wire.Fighter, kind.number()) orelse return error.UnsupportedCampaignPilotShip;
        }
    }
    return arena;
}

pub fn destroy(arena: *Arena) void {
    const gpa = arena.mission.objects.gpa;
    arena.deinit();
    gpa.destroy(arena);
}

fn deinit(arena: *Arena) void {
    const gpa = arena.mission.objects.gpa;
    if (arena.loaded) |loaded| loaded.destroy();
    if (arena.campaign) |campaign| {
        campaign.cues.deinit();
        campaign.radio.deinit();
        campaign.gates.deinit();
        gpa.destroy(campaign);
    }
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
    scene.arena_options = arena.options;
    if (arena.campaign) |campaign| {
        scene.damage_rules = .cooperative;
        scene.difficulty = .easy;
        scene.touchdown = .original;
        scene.gates = &campaign.gates;
        scene.display = &campaign.display;
        scene.radio = &campaign.radio;
        scene.environment = &campaign.environment;
        scene.cues = &campaign.cues;
    }
    if (arena.assets) |assets| scene.spawn = .{ .tables = &arena.mission.tables, .types = assets.library.types() };
    if (arena.loaded) |loaded| scene = stock.withMission(scene, loaded);
    scene.uber_kills = .{ .context = arena, .send = noteUberKill };
    scene.beacon_notices = .{ .context = arena, .send = noteBeacon };
    scene.tag_bomb_notices = .{ .context = arena, .send = noteBomb };
    scene.shadow_notices = .{ .context = arena, .send = noteShadow };
    scene.vampires_notices = .{ .context = arena, .send = noteVampires };
    if (arena.decoys) |*decoys| scene.countermeasures = decoys;
    if (arena.waves) |*waves| scene.shockwaves = waves;
    if (arena.cannons) |*cannons| scene.ion_cannons = cannons;
    if (arena.assets != null) {
        scene.music_output = .{ .context = arena, .send = noteMusic };
        scene.gun_effects = .{ .context = arena, .send = noteCombat };
        scene.arena_wrecks = .{ .context = arena, .send = noteWreck };
    }
    return scene;
}

fn noteMusic(context: *anyopaque, command: game.hog_snd.commands.Music) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    const cue = wire.MissionMusic.capture(command) orelse return;
    arena.music.add(cue);
    arena.last_music = cue;
}

fn noteWreck(context: *anyopaque, wreck: wire.Wreck) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    arena.wrecks[wreck.pilot.participant.slot] = wreck;
}

fn noteCombat(context: *anyopaque, effect: game.guns.FlightEffect) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    switch (effect) {
        .shot => |shot| {
            // Arena turret fire uses the same visual events as pilot gunfire.
            if (shot.owner >= wire.slots and arena.mode.scenario() == null) return;
        },
        .nova => |beam| if (beam.owner.slot >= wire.slots) return,
        .impact, .wall => {},
    }
    if (arena.combat_count == arena.combat.len) return;
    arena.combat[arena.combat_count] = effect;
    arena.combat_count += 1;
}

fn noteBeacon(context: *anyopaque, notice: game.deathmatch.six_beacons.Notice) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    arena.note(.{ .beacon = notice });
}

fn noteUberKill(context: *anyopaque, notice: game.deathmatch.UberKill) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    arena.note(.{ .uber_kill = notice });
}

fn noteBomb(context: *anyopaque, notice: game.deathmatch.tag_bomb.Notice) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    arena.note(.{ .tag_bomb = notice });
}

fn noteShadow(context: *anyopaque, notice: game.deathmatch.hunt_the_shadow.Notice) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    arena.note(.{ .shadow = notice });
}

fn noteVampires(context: *anyopaque, notice: game.deathmatch.vampires.Notice) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    arena.note(.{ .vampires = notice });
}

fn note(arena: *Arena, notice: Notice) void {
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
    // A failed spawn never entered the match. Running departure rules here could reset Vampires.
    errdefer scene.objects.player_states[slot] = .{ .membership = .vacant };
    var pilot: Pilot = .{ .participant = participant, .fighter = fighter };
    try arena.spawnPilot(pilot, true);
    pilot.first_spawn = false;
    arena.pilots[slot] = pilot;
    return .{ .slot = slot, .generation = participant.generation };
}

fn spawnPilot(arena: *Arena, pilot: Pilot, first: bool) !void {
    const scene = arena.world();
    const slot = pilot.participant.slot;
    if (arena.assets != null) return game.deathmatch.spawn.reset(scene, pilot.participant, pilot.fighter.kind(), if (first) slot else null);
    game.create.resetSlot(.of(scene), slot);
    try arena.createShip(@intCast(slot), pilot.fighter);
    errdefer game.create.resetSlot(.of(scene), slot);
    _ = scene.objects.bindParticipant(pilot.participant, .of(scene.objects, slot)) orelse return error.BindFailed;
}

pub fn leave(arena: *Arena, slot: u8) void {
    const pilot = arena.pilots[slot] orelse return;
    _ = simulation.leave(arena.world(), pilot.participant);
    arena.pilots[slot] = null;
}

/// Hands the host's simulation what the pilot of `slot` flies this step: the command, the
/// trigger (`fire_for` names the ship it is for), a MATCH SPEED press, and the weapon order.
pub fn input(arena: *Arena, slot: u8, command: engine.input.flight.Command, fire_for: ?u32, order: ?wire.ordnance.Order, match_speed: bool) bool {
    const all = arena.mission.objects;
    if (arena.pilots[slot] == null) return false;
    // An admitted pilot stays connected while the old ship finishes exploding.
    if (!all.hasBoundPlayerShip(slot)) return true;
    if (all.slots[slot].running(.deathmatch_respawn_effect) != null) return true;
    const pilot = all.playerBinding(slot).?;
    const stock_mode = arena.mode.scenario() != null or arena.campaign != null;
    var submitted: game.players.Command = .{
        .flight = command,
        .weapons = .{ .fire_guns = fire_for == pilot.ship.reuse and stock_mode },
        .match_speed = match_speed and stock_mode,
    };
    if (stock_mode) if (order) |weapons| {
        if (weapons.aim.reuse == pilot.ship.reuse) {
            submitted.cockpit = weapons.cockpit;
            if (weapons.aim.script_aim == all.player_states[slot].script_aim) {
                const target = arena.weaponTarget(slot, weapons.aim);
                const ship = &all.slots[slot];
                // The pilot's blind-fire claim arrives on the order, as the original's display
                // set the aim itself (`hud.blind_fire_reach`'s box, `0x0046` by `0x0032`, of
                // the middle). The host asks the same of the lead point against the ship's
                // nose, wide enough that no honest shot is refused.
                const fitted = if (game.main.cockpitShip(all, ship.object.type)) |definition| definition.blind_fire else false;
                const display: game.hud.State = .{ .blind_fire_fitted = fitted, .blind_fire = weapons.aim.blind_fire };
                const allowed = if (target) |aim| allowed: {
                    const valid = game.ai.ValidTarget.of(all, aim.resolve(all).?, .{}) orelse break :allowed false;
                    const lead = game.ai.leadAim(all, slot, valid, 1) orelse break :allowed false;
                    const direction = lead - ship.drawn.position;
                    const nose = engine.surrender.math.forward(ship.drawn.orientation);
                    break :allowed engine.surrender.math.cosineOff(direction, nose) >= 0.984807753012208;
                } else false;
                ship.object.blind_fire_aim = @intFromBool(weapons.aim.blind_fire and allowed and game.hud.blindFire(&display, ship) == .on);
                if (game.ai.controlEntry(all, slot)) |entry| {
                    // The pilot's selection follows what the aim names even where the weapons
                    // refuse it, as the original's display target served MATCH SPEED and the
                    // lead cursor alike; only the weapons take the validated target.
                    const named = if (weapons.aim.target) |ref| ref.resolve(all) else null;
                    const chosen: ?game.players.Target = if (named) |at|
                        if (at != slot and all.playerBinding(at) != null) .{ .object = weapons.aim.target.?, .component = weapons.aim.component } else null
                    else
                        null;
                    const follow = target orelse chosen;
                    if (follow) |aim| {
                        const selected = entry.target.resolve(all);
                        if (!selected.eql(aim.resolve(all).?)) submitted.target = .{ .aim = aim };
                    } else if (entry.target != .none) submitted.target = .clear;
                }
                submitted.weapons.launch_missile = weapons.presses.launch and (weapons.aim.target == null or target != null);
            }
            submitted.weapons.countermeasures = weapons.presses.countermeasures;
            submitted.weapons.rotate_missiles = weapons.presses.turn();
        }
    };
    return all.submitPlayerCommand(pilot, submitted);
}

fn weaponTarget(arena: *const Arena, source: u16, order: wire.ordnance.Aim) ?game.players.Target {
    const all = arena.mission.objects;
    const ref = order.target orelse return null;
    const slot = ref.resolve(all) orelse return null;
    if (slot == source or (arena.campaign == null and all.playerBinding(slot) == null) or
        !game.ai.targetValid(all, .at(slot, if (order.component) |part| @as(u16, part) else null), .{})) return null;
    return .{ .object = ref, .component = order.component };
}

pub fn step(arena: *Arena, tick: u32) !wire.Snapshot {
    arena.wrecks = @splat(null);
    arena.combat_count = 0;
    arena.mission.clock.advanceTimer(game.gameobj.ticks_per_step);
    if (game.main.gameFrames(&arena.mission.clock, &arena.devices, null, arena.world(), .in_turn, arena.loaded) != .played) {
        if (arena.campaign) |campaign| campaign.finished = true else return error.ArenaEnded;
    }
    if (arena.assets != null and arena.campaign == null) {
        for (&arena.pilots) |*entry| {
            const pilot = entry.* orelse continue;
            if (arena.mission.objects.playerBinding(pilot.participant.slot) != null) continue;
            arena.spawnPilot(pilot, pilot.first_spawn) catch |err| switch (err) {
                error.NoFreeSpawn => continue,
                // One pilot's ship is no reason to stop the round: the host lets them go.
                else => {
                    std.log.scoped(.network_host).warn("could not make a ship for the pilot in slot {d}: {t}", .{ pilot.participant.slot, err });
                    arena.unspawnable[pilot.participant.slot] = true;
                    continue;
                },
            };
            entry.*.?.first_spawn = false;
        }
    }
    if (arena.campaign) |campaign| {
        arena.campaignPresentation(campaign);
        const ready = arena.loaded.?.script.variables.ready;
        const travel: wire.MissionView.Travel = .{ .jump = ready.jump != .no, .warp = ready.warp != .no };
        if (!std.meta.eql(campaign.travel, travel)) {
            campaign.travel = travel;
            campaign.ready_since = tick;
        }
    }
    const view = try arena.snapshot(tick);
    for (&arena.pilots, view.ships) |*entry, ship| {
        if (entry.*) |*pilot| pilot.last_ship = ship;
    }
    return view;
}

fn campaignPresentation(arena: *Arena, campaign: *Campaign) void {
    for (campaign.cues.list.items) |cue| switch (cue) {
        .nebula_asked => |index| if (index < game.nebula.nebulae.len) {
            campaign.nebula = @intCast(index);
        },
        else => {},
    };
    campaign.cues.list.clearRetainingCapacity();
    const scene = arena.world();
    const subject = game.camera.Subject.of(&scene.objects.slots[scene.objects.player]);
    campaign.camera.frame(.{
        .object = subject,
        .player = subject,
        .viewing = &scene.player.viewing,
        .game = scene,
        .ticks = scene.clock.frameTicks(),
        .now = scene.clock.viewTime(),
    });
}

/// Capture an arena view at the current tick. A pilot joining during a pause still needs one.
pub fn snapshot(arena: *Arena, tick: u32) !wire.Snapshot {
    const all = arena.mission.objects;
    var view: wire.Snapshot = .{ .tick = tick, .clock = arena.mission.clock.mission_ticks, .scenario = arena.mode.scenario(), .ships = @splat(null) };
    if (all.arena_scores == .teams) view.teams = all.arena_scores.teams;
    if (arena.campaign) |campaign| {
        view.mission = .{
            .number = all.mission_number,
            .second_part = all.mission25_second_part,
            .pilot_slots = @intCast(all.players),
            .lead = if (engine.input.missionLead(all)) |lead| @intCast(lead.participant.slot) else null,
            .travel = campaign.travel,
            .objectives = campaign.display.objectives.states,
            .rating = arena.loaded.?.script.variables.mission_success,
            .objectives_met = arena.loaded.?.script.variables.objectives_met != 0,
            .reliant_alive = arena.loaded.?.script.variables.reliant_alive != 0,
            .nebula = campaign.nebula,
            .director = if (arena.mission.player.viewing.view == .director) .{
                .position = campaign.camera.place.position,
                .angles = wire.packFacing(campaign.camera.place.orientation),
                .bars = campaign.camera.bars,
            } else null,
        };
    }
    if (all.arena_scenario.powerUps()) |round| view.pickups = round.pickups.visible(all);
    for (arena.pilots, &view.ships, 0..) |entry, *ship, at| {
        const pilot = entry orelse continue;
        const index: u16 = @intCast(at);
        if (all.playerBinding(index) == null) {
            if (arena.assets != null) if (pilot.last_ship) |last| {
                const score = all.player_states[index].membership.joined;
                ship.* = last;
                ship.*.?.dying = true;
                ship.*.?.spin = null;
                ship.*.?.kills = score.kills.count;
                ship.*.?.deaths = score.deaths;
            };
            continue;
        }
        const slot = &all.slots[index];
        const object = &slot.object;
        const score = all.player_states[index].membership.joined;
        const pod = arena.campaign != null and object.flags.ejected and all.slots[index].running(.eject) != null;
        ship.* = .{
            .generation = pilot.participant.generation,
            .reuse = all.reuses[index],
            .fighter = pilot.fighter,
            .position = object.nextPosition(),
            .speed = object.speed,
            .throttle = object.last_throttle,
            .velocity = object.velocity.vector(),
            .rates = .{ object.pitch_rate, object.yaw_rate, object.roll_rate },
            .inputs = .{
                wire.quantizeInput(object.pitch_input),
                wire.quantizeInput(object.yaw_input),
                wire.quantizeInput(object.roll_input),
            },
            .lateral = wire.quantizeLateral(object.lateral_input),
            .speed_factor = wire.quantizeShare(object.speed_factor),
            .engines = wire.quantizeShare(object.engines_intact),
            .fuel = object.afterburner_fuel,
            .shields = object.shields,
            .armor = object.armor,
            .kills = score.kills.count,
            .deaths = score.deaths,
            .cloaked = if (all.slots[index].cloak) |cloak| !cloak.going else false,
            .targetable = arena.mode.scenario() == null or object.flags.targetable,
            .respawn = game.deathmatch.respawn.remaining(&all.slots[index], arena.mission.clock.frame_start),
            .at_wall = if (all.arena_boundary) |*boundary| boundary.outside(object.nextPosition()) else false,
            .dying = object.flags.exploding,
            .spin = if (object.flags.exploding) game.aiexplode.spinning(&all.slots[index], arena.mission.clock.frame_start) else null,
            .pod = pod,
            .pod_clear = pod and all.slots[index].state.eject.stage != .clearing,
            .kamov = object.type.base() == .kamov,
            .engine_waiting = arena.campaign != null and !game.launch.engineReady(slot),
            .afterburner = object.afterburner,
            .reverse_thrust = object.reverse_thrust,
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
    if (all.arena_scenario == .tag_bomb) {
        const bomb = all.arena_scenario.tag_bomb.bomb.hudView();
        view.objectives = .{ .tag_bomb = if (bomb.carrier) |pilot|
            .{ .carrier = @intCast(pilot.slot), .remaining = bomb.remaining }
        else
            null };
    }
    if (all.arena_scenario == .hunt_the_shadow) {
        const holder = all.arena_scenario.hunt_the_shadow.shadow.owner;
        view.objectives = .{ .hunt_the_shadow = if (holder) |pilot| @intCast(pilot.slot) else null };
    }
    if (all.arena_scenario == .vampires)
        view.objectives = .{ .vampires = all.arena_scenario.vampires.infection.roles(all) };
    return view;
}

pub fn scenery(arena: *const Arena, tick: u32) ?wire.Scenery {
    const all = arena.mission.objects;
    const scenario = arena.mode.scenario() orelse return null;
    const round = all.arena_scenario.powerUps() orelse return null;
    var view: wire.Scenery = .{ .tick = tick, .scenario = scenario, .rocks = arena.rocks.capture(all) };
    for (&view.mines, 0..) |*entry, offset| {
        const index = round.mine_start + @as(u16, @intCast(offset));
        const object = &all.slots[index].object;
        if (!object.created or object.flags.disabled or object.flags.stand_in) continue;
        entry.* = .{ .position = object.nextPosition(), .angles = wire.packFacing(object.root.next_orientation), .reuse = all.reuses[index] };
    }
    return view;
}

pub fn crewJump(arena: *Arena, slot: u8, tick: u32, request: wire.CrewRequest) void {
    const campaign = arena.campaign orelse return;
    if (request.view_tick <= campaign.started_after or request.view_tick < campaign.ready_since or request.view_tick > tick) return;
    const pilot = arena.pilots[slot] orelse return;
    if (engine.input.crewJump(arena.world(), .{
        .participant = pilot.participant,
        .ship = .{ .slot = slot, .reuse = request.reuse },
    })) {
        // Any new readiness set by the script belongs to a later view.
        campaign.travel = .{};
        campaign.ready_since = tick +| 1;
    }
}

pub fn crewLand(arena: *Arena, slot: u8, tick: u32, request: wire.CrewRequest) void {
    const campaign = arena.campaign orelse return;
    if (request.view_tick <= campaign.started_after or request.view_tick > tick) return;
    const lead = engine.input.missionLead(arena.mission.objects) orelse return;
    if (lead.participant.slot != slot or lead.ship.reuse != request.reuse) return;
    game.radio.crewLanding(arena.world(), slot);
}

pub fn crewEject(arena: *Arena, slot: u8, tick: u32, request: wire.CrewRequest) void {
    const campaign = arena.campaign orelse return;
    if (request.view_tick <= campaign.started_after or request.view_tick > tick) return;
    const all = arena.mission.objects;
    const pilot = all.playerBinding(slot) orelse return;
    if (pilot.ship.reuse != request.reuse) return;
    engine.input.eject(arena.world(), slot);
}

pub fn guide(arena: *const Arena, index: u8) wire.MissionView.Guide {
    const all = arena.mission.objects;
    const slot = &all.slots[index];
    const state = &all.player_states[index];
    var result: wire.MissionView.Guide = .{ .aim = state.script_aim };
    if (all.boundParticipant(index)) |pilot| {
        if (pilot.ending == .playing) {
            result.scanner_command = state.scanner_command;
            if (state.scanner_target) |ref| if (ref.resolve(all)) |at| {
                if (all.slots[at].object.created and !all.slots[at].object.flags.exploding) result.scanner_target = ref;
            };
        }
    }
    if (state.script_aim != 0) if (game.ai.controlEntry(all, index)) |order| {
        const target = order.target.resolve(all);
        if (target.slotIn(all)) |at| result.target = .{
            .object = .of(all, at),
            .component = if (target.component < 0) null else @intCast(target.component),
        };
    };
    if (slot.object.escort_point.index()) |at| result.escort = .of(all, at);
    if (slot.object.nav_point.index()) |at| result.nav = .of(all, at);
    if (arena.mission.player.primary_target) |aim| if (aim.slotIn(all)) |at| {
        result.primary = .of(all, at);
    };
    if (state.landing_view) |view| {
        if (slot.running(.land)) |order| if (order.target.slotIn(all)) |carrier| {
            result.landing = .{
                .carrier = .of(all, carrier),
                .view = if (view == .landing_tube) .tube else .aside,
                .tube = slot.state.land.tube,
            };
        };
    }
    return result;
}

test "the pilot stays admitted through destruction and old trigger input expires on respawn" {
    var arena: Arena = undefined;
    try arena.init(std.testing.allocator, .training, .{}, std.testing.io, .cwd());
    defer arena.deinit();
    _ = try arena.join(0, .predator);
    arena.mode = .@"nuclear-threat";
    const all = arena.mission.objects;
    const first = all.playerBinding(0).?.ship.reuse;
    try std.testing.expect(arena.input(0, .{}, first, null, false));
    try std.testing.expect(all.playerCommand(0).?.weapons.fire_guns);
    all.slots[0].object.flags.exploding = true;
    try std.testing.expect(arena.input(0, .{}, first, null, false));
    try std.testing.expectEqual(null, all.playerCommand(0));
    try arena.spawnPilot(arena.pilots[0].?, false);
    try std.testing.expect(arena.input(0, .{}, first, .{ .aim = .{ .reuse = first }, .presses = .{ .launch = true, .countermeasures = true } }, false));
    try std.testing.expect(!all.playerCommand(0).?.weapons.fire_guns);
    try std.testing.expect(!all.playerCommand(0).?.weapons.launch_missile);
    try std.testing.expect(!all.playerCommand(0).?.weapons.countermeasures);
    try std.testing.expect(arena.input(0, .{}, all.playerBinding(0).?.ship.reuse, null, false));
    try std.testing.expect(all.playerCommand(0).?.weapons.fire_guns);
    try std.testing.expect(arena.input(0, .{}, null, null, false));
    try std.testing.expect(!all.playerCommand(0).?.weapons.fire_guns);
}

test "a failed admission and an occupied respawn leave the rest of the round running" {
    var arena: Arena = undefined;
    try arena.init(std.testing.allocator, .training, .{}, std.testing.io, .cwd());
    defer arena.deinit();
    const all = arena.mission.objects;
    _ = try arena.join(0, .predator);
    const first = try arena.step(1);
    const reuse = first.ships[0].?.reuse;
    game.create.resetSlot(.of(arena.world()), 0);

    // No marker means reset returns before the ship loader needs any models.
    var assets: stock.Assets = undefined;
    arena.assets = &assets;
    defer arena.assets = null;
    try std.testing.expectError(error.NoFreeSpawn, arena.join(1, .shroud));
    try std.testing.expectEqual(null, arena.pilots[1]);
    try std.testing.expect(all.player_states[1].membership == .vacant);
    const next = try arena.step(2);
    try std.testing.expectEqual(reuse, next.ships[0].?.reuse);
    try std.testing.expect(next.ships[0].?.dying);
    try std.testing.expectEqual(null, all.playerBinding(0));
    try std.testing.expectEqualDeep(next, try arena.snapshot(2));
}

test "a Six Beacons blast queues the original kill line for network delivery" {
    var arena: Arena = undefined;
    try arena.init(std.testing.allocator, .@"six-beacons", .{}, std.testing.io, .cwd());
    defer arena.deinit();
    _ = try arena.join(0, .predator);
    _ = try arena.join(1, .shroud);
    const scene = arena.world();
    const owner = scene.objects.playerBinding(0).?;
    const victim = scene.objects.playerBinding(1).?;
    const blast = scene.explosions.?.uber;
    const duration = game.deathmatch.six_beacons.blast_ticks;
    blast.start(scene, 0, .{ .position = scene.objects.slots[1].drawn.position }, 1000, duration, .original);
    arena.mission.clock.frame_start = duration - 1;
    blast.frame(scene);
    arena.mission.clock.frame_start = duration + 1;
    blast.frame(scene);
    try std.testing.expectEqual(1, arena.notice_count);
    try std.testing.expectEqual(game.deathmatch.UberKill{
        .owner = owner.participant,
        .victim = victim.participant,
        .awarded = true,
        .tick = duration + 1,
    }, arena.notices[0].uber_kill);
}
