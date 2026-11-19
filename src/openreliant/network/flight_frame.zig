//! The client's view of a host snapshot, in the records the flight renderer and HUD already read.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const wire = @import("wire.zig");
const stock = @import("stock_arena.zig");
const Projectiles = @import("projectiles.zig");
const FlightFrame = @This();
const powerups = game.deathmatch.powerups;

drawn: game.main.Drawn,
rays_drawing: game.erayfx.Drawing,
tables: game.create.Stats,
random: engine.random.Random = .{},
tick: ?u32 = null,
host_ship_reuse: [wire.slots]u32 = @splat(0),
respawns: game.deathmatch.respawn.View = .{},
wall: game.deathmatch.Boundary.Flashes = .{},
wall_mesh: ?engine.surrender.surrenderlib.srapiext.Mesh = null,
loaded: ?*game.mission.Loaded = null,
environment: game.environfx.Environment = .{},
beacon_slots: [wire.beacon_count]?u16 = @splat(null),
dark_reign: ?struct {
    relay: game.gameobj.ObjectRef,
    tower: game.gameobj.ObjectRef,
    cannon: game.aiioncan.View = .{},
} = null,
rocks: stock.RockSlots = .{},
pickups: powerups.Pickups = .{},
mine_start: ?u16 = null,
host_mines: [powerups.mine_count]?u32 = @splat(null),
shot_ended_at: [game.guns.max_bullets]i32 = @splat(-1),
wreck_seen_at: [wire.slots]i32 = @splat(-1),
death_view: ?DeathView = null,
effect_tick: ?i32 = null,
blast_started: ?i32 = null,
sounds: ?*game.hog_snd.commands.Commands = null,
lock_tone: game.main.lock.Tone = .{},
projectiles: ?Projectiles = null,

pub const DeathView = struct {
    started: i32,
    watching_from: ?engine.surrender.math.Vector,
};

pub fn create(gpa: std.mem.Allocator, local: *const game.create.Objects, tables: *const game.create.Stats) !*FlightFrame {
    const frame = try gpa.create(FlightFrame);
    errdefer gpa.destroy(frame);
    var random: engine.random.Random = .{};
    const objects = try game.create.Objects.create(gpa, &random);
    objects.count = wire.slots;
    objects.players = wire.slots;
    objects.reuses = local.reuses;
    objects.gun_stats = local.gun_stats;
    objects.missile_stats = local.missile_stats;
    objects.bullets.looks = local.bullets.looks;
    objects.bullets.shot_lights = local.bullets.shot_lights;
    frame.* = .{
        .drawn = .{
            .gpa = gpa,
            .objects = objects,
            .arena = .init(gpa),
            .player = .{ .viewing = .{ .cockpit_mode = .chase } },
        },
        .rays_drawing = .{ .gpa = gpa },
        .tables = tables.*,
        .random = random,
    };
    return frame;
}

pub const CombatAssets = struct {
    textures: *engine.surrender.surrenderlib.srtexture.Table,
    images: ?game.explode.Explosions.Images,
    ordnance_models: game.objects.Effects,
    trails: game.missiles.trail.Trails.Images,
    sounds: ?*game.hog_snd.commands.Commands = null,
    explosions: game.explode.Settings,
    particles: game.particles.Pool.Settings,
};

pub fn enableCombat(frame: *FlightFrame, assets: CombatAssets, types: game.create.Types) !void {
    const gpa = frame.drawn.gpa;
    frame.drawn.effects.explosions = try .init(gpa, assets.images);
    frame.drawn.effects.explosions.?.settings = assets.explosions;
    var kept: game.create.TypeSet = .empty;
    frame.drawn.effects.explosions.?.debris = .load(types, &kept);
    frame.drawn.effects.particles = try .load(gpa, assets.textures, .standard, assets.particles);
    frame.drawn.effects.sparks = try .create(gpa, assets.textures);
    frame.drawn.effects.shockwaves = try .create(gpa, assets.textures, .round);
    frame.drawn.effects.flash = .{};
    if (frame.dark_reign != null) {
        frame.drawn.effects.rays = try .init(gpa, assets.textures);
        frame.drawn.effects.ion_cannons = try .init(gpa, assets.textures);
        const images: game.create.extra.Images = try .load(assets.textures);
        var scene = frame.world();
        scene.extras = &images;
        if (frame.dark_reign.?.tower.resolve(scene.objects)) |tower| game.create.extra.hatMade(scene, tower);
    }
    try frame.respawns.load(gpa, assets.textures);
    frame.wall_mesh = try game.deathmatch.Boundary.Flashes.mesh(gpa, assets.textures);
    frame.projectiles = .init(gpa, assets.ordnance_models, assets.trails);
    frame.sounds = assets.sounds;
}

pub fn destroy(frame: *FlightFrame) void {
    const gpa = frame.drawn.gpa;
    if (frame.loaded) |loaded| loaded.destroy();
    if (frame.projectiles) |*shown| shown.deinit();
    if (frame.sounds) |asked| frame.lock_tone.sound(false, asked, frame.drawn.player.viewing.last);
    if (frame.drawn.effects.explosions) |*effects| effects.deinit();
    if (frame.drawn.effects.particles) |*particles| particles.deinit();
    if (frame.drawn.effects.sparks) |*sparks| sparks.deinit();
    if (frame.drawn.effects.shockwaves) |*rings| rings.deinit(gpa);
    if (frame.drawn.effects.ion_cannons) |*cannons| cannons.deinit();
    frame.rays_drawing.deinit();
    if (frame.drawn.effects.rays) |*rays| rays.deinit();
    frame.respawns.deinit(gpa);
    if (frame.wall_mesh) |*mesh| mesh.deinit(gpa);
    frame.drawn.objects.destroy();
    frame.drawn.arena.deinit();
    gpa.destroy(frame);
}

pub fn presentProjectiles(frame: *FlightFrame, pages: *const [wire.ordnance.Page.pages]?wire.ordnance.Page) !void {
    if (frame.projectiles) |*shown| try shown.apply(frame.world(), pages, frame.tick orelse return);
}

pub fn loadArena(frame: *FlightFrame, files: stock.Files, scenario: wire.Scenario, types: game.create.Types) !void {
    if (!scenario.available()) return error.UnsupportedArena;
    const drawn = &frame.drawn;
    frame.loaded = try files.load(drawn.gpa, scenario, .{
        .objects = drawn.objects,
        .player = &drawn.player,
        .clock = &drawn.clock,
        .shake = &drawn.shake,
        .random = &frame.random,
        .spawn = .{ .tables = &frame.tables, .types = types },
        .environment = &frame.environment,
    });
    if (scenario.hasPowerUps()) {
        frame.rocks = try .collect(drawn.objects);
        frame.pickups = try .collect(drawn.objects);
        frame.mine_start = try powerups.reserveMines(drawn.objects);
    }
    if (scenario == .dark_reign) {
        const Round = game.deathmatch.dark_reign.Round;
        frame.dark_reign = .{
            .relay = Round.find(drawn.objects, .comms_relay) orelse return error.MissingCommsRelay,
            .tower = Round.find(drawn.objects, .darkreign) orelse return error.MissingDarkReign,
        };
    }
    if (scenario != .nuclear_threat) return;
    var count: usize = 0;
    for (drawn.objects.slots[0..drawn.objects.count], 0..) |*slot, index| {
        if (!slot.object.created or slot.object.type.base() != .dm_beacon) continue;
        if (count == frame.beacon_slots.len) return error.InvalidArenaBeacons;
        frame.beacon_slots[count] = @intCast(index);
        count += 1;
    }
    if (count != frame.beacon_slots.len) return error.InvalidArenaBeacons;
}

pub fn applyRoster(frame: *FlightFrame, roster: wire.Roster) void {
    for (roster.pilots, 0..) |entry, index| {
        const membership = &frame.drawn.objects.player_states[index].membership;
        if (membership.* != .joined) continue;
        const peer = entry orelse continue;
        if (peer.generation == membership.joined.generation) membership.joined.name.set(peer.name.slice());
    }
}

pub fn weaponAim(frame: *FlightFrame) wire.ordnance.Aim {
    const all = frame.drawn.objects;
    var aim: wire.ordnance.Aim = .{ .reuse = frame.host_ship_reuse[all.player] };
    const entry = game.ai.controlEntry(all, all.player) orelse return aim;
    const target = entry.target.slotIn(all) orelse return aim;
    if (target != all.player and target < wire.slots and all.playerBinding(target) != null)
        aim.target = .{ .slot = target, .reuse = frame.host_ship_reuse[target] };
    return aim;
}

fn presentWeapons(frame: *FlightFrame, status: ?wire.ordnance.Status) void {
    const all = frame.drawn.objects;
    const slot = &all.slots[all.player];
    const weapons = &all.player_states[all.player].weapons;
    const prior = weapons.ring;
    const decoys_before = slot.object.countermeasures;
    weapons.ring = if (status) |shown| shown.ring() else .{};
    weapons.lock = if (status) |shown| shown.held else .{};
    slot.object.countermeasures = if (status) |shown| shown.countermeasures else 0;
    if (slot.object.countermeasures < decoys_before) game.hud.beep(frame.world(), .done);
    slot.object.missile_homing = @intFromBool(if (status) |shown| shown.incoming else false);
    if (status != null and (weapons.ring.left < prior.left or weapons.ring.armed != prior.armed)) {
        if (frame.drawn.display.windows.open(.missiles, true))
            frame.drawn.display.windows.status.getPtr(.missiles).held = true;
    }
    if (frame.sounds) |asked| frame.lock_tone.sound(weapons.lock.locked(), asked, frame.drawn.player.viewing.last);
}

fn presentPower(frame: *FlightFrame, power: ?wire.Power) void {
    const all = frame.drawn.objects;
    const ship = &all.slots[all.player].object;
    if (power) |held| {
        ship.power_up = held.kind;
        ship.power_up_since = held.since;
        ship.power_up_until = if (powerups.rule(held.kind).?.ticks) |duration| held.since +| duration else -1;
    } else ship.power_up = .none;
}

fn presentPickups(frame: *FlightFrame, mask: powerups.Pickups.Mask) !void {
    const scene = frame.world();
    const before = if (frame.tick != null) frame.pickups.visible(scene.objects) else mask;
    try frame.pickups.show(scene.objects, mask);
    var collected = before & ~mask;
    while (collected != 0) {
        const index = @ctz(collected);
        collected &= collected - 1;
        if (frame.pickups.slots[index].resolve(scene.objects)) |slot|
            game.sound3d.playIn(scene, null, null, slot, .dmpickup, 1, .not_reserved);
    }
}

fn presentMines(frame: *FlightFrame, snapshot: *const wire.Snapshot, types: game.create.Types) !void {
    const first = frame.mine_start orelse return;
    const scene = frame.world();
    const all = scene.objects;
    for (snapshot.mines, &frame.host_mines, 0..) |entry, *known, offset| {
        const index = first + @as(u16, @intCast(offset));
        const slot = &all.slots[index];
        if (known.*) |before| if (entry == null or entry.?.reuse != before) {
            if (entry == null) game.explode.fighterFireball(scene, slot.drawn.position, @splat(0), slot.object.radius);
            game.create.resetSlot(.of(scene), index);
            known.* = null;
        };
        const mine = entry orelse continue;
        if (known.* == null) {
            try powerups.makeMine(all, index, &frame.tables, types, &frame.random);
            known.* = mine.reuse;
        }
        game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = mine.position, .orientation = wire.unpackFacing(mine.angles) });
        if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
    }
}

fn world(frame: *FlightFrame) game.gameobj.World {
    return .{
        .objects = frame.drawn.objects,
        .player = &frame.drawn.player,
        .random = &frame.random,
        .clock = &frame.drawn.clock,
        .shake = &frame.drawn.shake,
        .sounds = frame.sounds,
        .explosions = if (frame.drawn.effects.explosions) |*effects| effects else null,
        .particles = if (frame.drawn.effects.particles) |*particles| particles else null,
        .shockwaves = if (frame.drawn.effects.shockwaves) |*rings| rings else null,
        .flash = if (frame.drawn.effects.flash) |*flash| flash else null,
        .sparks = if (frame.drawn.effects.sparks) |*sparks| sparks else null,
        .rays = if (frame.drawn.effects.rays) |*rays| rays else null,
        .ion_cannons = if (frame.drawn.effects.ion_cannons) |*cannons| cannons else null,
        .display = &frame.drawn.display,
    };
}

pub fn presentWreck(frame: *FlightFrame, wreck: wire.Wreck, types: game.create.Types) !void {
    const scene = frame.world();
    const seen = &frame.wreck_seen_at[wreck.pilot.participant.slot];
    if (wreck.tick <= seen.* or scene.clock.frame_start -| wreck.tick > wire.wreck_window) return;
    seen.* = wreck.tick;
    try wreck.present(scene, types);
}

fn presentBlast(frame: *FlightFrame, scene: game.gameobj.World, blast: wire.Blast) void {
    if (frame.blast_started == blast.started) return;
    frame.blast_started = blast.started;
    const effects = scene.explosions orelse return;
    const place: engine.surrender.math.Place = .{ .position = blast.position, .orientation = wire.unpackFacing(blast.angles) };
    effects.uber.replay(scene, .{
        .owner = blast.owner,
        .place = place,
        .size = blast.size,
        .started = blast.started,
        .duration = game.deathmatch.six_beacons.blast_ticks,
    }, effects.settings.uber);
    if (scene.clock.frame_start - blast.started < game.main.flash.flash_ticks) {
        frame.drawn.shake = 1;
        const owner: ?u16 = if (scene.objects.playerBinding(blast.owner) != null) blast.owner else null;
        game.sound3d.playIn(scene, if (owner == null) blast.position else null, null, owner, .dmdrop, 1, game.sound3d.fxClass(scene.objects, blast.owner));
    }
}

fn remoteShip(frame: *const FlightFrame, ref: game.gameobj.ObjectRef) ?u16 {
    if (ref.slot >= wire.slots or frame.host_ship_reuse[ref.slot] != ref.reuse) return null;
    return if (frame.drawn.objects.playerBinding(ref.slot) != null) ref.slot else null;
}

pub fn presentCombat(frame: *FlightFrame, effects: []const game.guns.FlightEffect) void {
    const scene = frame.world();
    if (effects.len == 0 and frame.effect_tick == scene.clock.frame_start) return;
    frame.effect_tick = scene.clock.frame_start;
    for (effects) |effect| switch (effect) {
        .shot => |shot| {
            if (shot.fired_at > frame.shot_ended_at[shot.index]) {
                game.guns.showShot(scene, shot);
                if (shot.owner == scene.objects.player) _ = frame.drawn.display.windows.open(.gunnery, false);
            }
        },
        .impact => |hit| {
            frame.shot_ended_at[hit.shot] = @max(frame.shot_ended_at[hit.shot], hit.fired_at);
            game.guns.showImpact(scene, hit, frame.remoteShip(hit.target));
        },
        .nova => |beam| if (frame.remoteShip(beam.owner)) |owner| game.guns.nova.show(scene, owner, beam),
        .wall => |wall| {
            if (wall.shot) |shot| {
                frame.shot_ended_at[shot.index] = @max(frame.shot_ended_at[shot.index], shot.fired_at);
                game.guns.endReplica(scene, shot.index, shot.fired_at);
            }
            wall.present(scene);
            if (wall.flare) frame.wall.add(wall);
        },
    };
    game.guns.frameReplicas(scene);
}

fn presentPickup(all: *game.create.Objects, index: u16, value: wire.Beacon) void {
    const slot = &all.slots[index];
    slot.object.flags.disabled = value != .loose;
    if (value == .loose) {
        game.objects.setPosition(&slot.object, &slot.drawn, value.loose);
        if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
    }
}

fn presentDarkReign(frame: *FlightFrame, scene: game.gameobj.World, view: wire.DarkReign) !void {
    const map = if (frame.dark_reign) |*found| found else return error.UnexpectedArena;
    const all = scene.objects;
    const relay = map.relay.resolve(all) orelse return error.MissingCommsRelay;
    const tower = map.tower.resolve(all) orelse return error.MissingDarkReign;
    const before = frame.drawn.relay_carrier;
    presentPickup(all, relay, view.relay);
    const carrier = if (view.relay == .carried) all.playerBinding(view.relay.carried) else null;
    frame.drawn.relay_carrier = carrier;
    if (carrier) |binding| {
        if (frame.tick != null and !std.meta.eql(before, carrier)) {
            game.sound3d.playIn(scene, null, null, binding.participant.slot, .dmpickup, 1, .not_reserved);
            const target = game.ai.controlEntry(all, all.player);
            if (target != null and target.?.target.slotIn(all) == relay)
                _ = engine.input.cycleTargetFor(scene.display, all, all.player, .next, .hostile, true);
        }
    }
    try map.cannon.show(scene, tower, wire.unpackAngle(view.yaw), view.shot);
    if (scene.rays) |rays| rays.frame(all, scene.clock.frame_start, scene.effectsRandom());
}

pub fn apply(frame: *FlightFrame, snapshot: *const wire.Snapshot, admission: wire.Admission, local: *game.create.Objects, types: game.create.Types) !void {
    if (frame.tick == snapshot.tick) return;
    const all = frame.drawn.objects;
    all.player = admission.slot;
    const scene = frame.world();
    const ticks = snapshot.tick *| game.gameobj.ticks_per_step;
    frame.drawn.clock.drawn_duration = if (frame.tick == null) game.gameobj.ticks_per_step else @intCast(@min(ticks -| frame.drawn.clock.game_ticks, std.math.maxInt(i32)));
    frame.drawn.clock.game_ticks = ticks;
    frame.drawn.clock.mission_ticks = @intCast(@min(ticks, std.math.maxInt(i32)));
    frame.drawn.clock.frame_start = frame.drawn.clock.mission_ticks;
    frame.drawn.clock.frame_duration = frame.drawn.clock.drawn_duration;
    const cockpit = game.camera.Cockpit;
    frame.drawn.shake = @max(@min(frame.drawn.shake, cockpit.shake_most) - cockpit.shake_fade * @as(f32, @floatFromInt(frame.drawn.clock.frame_duration)), 0);
    if (snapshot.ships[admission.slot]) |ship| if (ship.at_wall) {
        frame.drawn.shake = 1;
    };
    if (scene.flash) |flash| flash.countDown(scene.clock.frame_duration);
    frame.drawn.display.windows.step(.comms, scene.clock.frame_duration);
    frame.drawn.display.messages.expire(scene.clock.frame_start);
    if (scene.sparks) |sparks| sparks.frame(scene.clock);
    try frame.rocks.apply(all, &snapshot.rocks);
    if (snapshot.scenario != null and snapshot.scenario.?.hasPowerUps()) {
        try frame.presentPickups(snapshot.pickups);
        try frame.presentMines(snapshot, types);
    }
    frame.drawn.portals.begin();
    defer frame.drawn.portals.end();
    for (snapshot.ships, 0..) |entry, offset| {
        const index: u16 = @intCast(offset);
        const prior = all.playerBinding(index);
        const before = frame.respawns.left[index];
        if (prior != null and (entry == null or prior.?.participant.generation != entry.?.generation or frame.host_ship_reuse[index] != entry.?.reuse or all.slots[index].object.type != entry.?.fighter.kind())) {
            game.create.resetSlot(.of(scene), index);
            all.player_states[index] = .{ .membership = .vacant };
        }
        const ship = entry orelse {
            frame.respawns.left[index] = 0;
            continue;
        };
        if (!all.slots[index].object.created) {
            all.loadout_racks[index] = @splat(.of(.none));
            _ = try game.create.createObject(all, &frame.tables, types, index, ship.fighter.kind(), 0, ship.position, &frame.random);
            if (snapshot.scenario != null) all.slots[index].object.countermeasures = 0;
            all.player_states[index] = .{ .membership = .{ .joined = .{
                .generation = ship.generation,
                .ship = .of(all, index),
            } } };
            frame.host_ship_reuse[index] = ship.reuse;
            if (index == admission.slot) {
                _ = try game.aigeneric.push(.of(scene), index, .player_control, .none);
                game.main.fitDevices(&all.player_states[index].charges, &frame.drawn.display, game.main.playerShip(ship.fighter.kind()), false);
            } else {
                all.slots[index].object.side = .hostile;
            }
        }
        const slot = &all.slots[index];
        game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = ship.position, .orientation = ship.orientationMatrix() });
        if ((before == 0 or ship.respawn > before) and ship.respawn + game.gameobj.ticks_per_step >= game.deathmatch.respawn.duration)
            game.deathmatch.respawn.sound(scene, index);
        slot.object.speed = ship.speed;
        slot.object.throttle = ship.throttle;
        slot.object.last_throttle = ship.throttle;
        slot.object.afterburner_fuel = ship.fuel;
        slot.object.shields = ship.shields;
        slot.object.armor = ship.armor;
        if (ship.dying and !slot.object.flags.exploding) {
            if (prior != null and prior.?.participant.generation == ship.generation) {
                game.explode.fireballAt(scene, slot.drawn.position, .{ .size = slot.object.radius });
                if (game.explode.soundClass(scene, slot.drawn.position) == .guaranteed)
                    game.explode.sound(scene, slot.drawn.position, .guaranteed);
            }
            if (index == admission.slot) {
                const viewing = &frame.drawn.player.viewing;
                const slow = game.aiexplode.movingSlowly(slot, viewing.view);
                frame.death_view = .{
                    .started = scene.clock.frame_start,
                    .watching_from = if (!slow and viewing.seen_from != null) viewing.seen_from.?.position else null,
                };
            }
        }
        slot.object.flags.exploding = ship.dying;
        if (!ship.dying and index == admission.slot) frame.death_view = null;
        all.player_states[index].membership.joined.kills.count = ship.kills;
        all.player_states[index].membership.joined.deaths = ship.deaths;
        all.player_states[index].membership.joined.ping_ms = ship.ping_ms;
        slot.object.afterburner = ship.throttle == game.motion.afterburner_throttle;
        slot.object.reverse_thrust = ship.throttle == game.motion.reverse_throttle;
        const cloaking = if (slot.cloak) |effect| !effect.going else false;
        if (ship.cloaked != cloaking) {
            if (ship.cloaked) game.cloak.beginPowerUp(scene, index) else game.cloak.uncloak(scene, index);
        }
        if (slot.cloak != null) game.cloak.frame(slot, scene.clock.frame_start);
        if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
        frame.respawns.clip(slot, index, &frame.drawn.portals, ship.respawn);
    }
    const viewing = &frame.drawn.player.viewing;
    viewing.last = viewing.view;
    viewing.view = if (frame.respawns.left[admission.slot] != 0)
        game.camera.deathmatch_respawn_view
    else if (frame.death_view) |death|
        (if (death.watching_from == null) .pull_back else .watch)
    else
        .cockpit;
    if (snapshot.blast) |blast| frame.presentBlast(scene, blast);
    if (scene.explosions) |effects| effects.frame(scene);
    if (scene.particles) |particles| particles.frame(scene.clock);
    if (scene.shockwaves) |rings| rings.frame(scene);
    if (snapshot.scenario != null) frame.presentWeapons(snapshot.weapons);
    if (snapshot.scenario != null and snapshot.scenario.?.hasPowerUps()) frame.presentPower(snapshot.power);
    // Reserve the identities used during the session in the local mission's slot counters.
    for (local.reuses[0..wire.slots], all.reuses[0..wire.slots]) |*reuse, received| reuse.* = received +% 1;
    frame.drawn.beacon_snapshot = switch (snapshot.objectives) {
        .none => null,
        .dark_reign => |mode| view: {
            try frame.presentDarkReign(scene, mode);
            break :view null;
        },
        .six_beacons => |beacons| view: {
            var captured: game.deathmatch.six_beacons.HudSnapshot = .{};
            for (&captured.carriers, beacons, frame.beacon_slots) |*carrier, value, marker| {
                if (value == .carried) carrier.* = all.playerBinding(value.carried);
                if (marker) |index| presentPickup(all, index, value);
            }
            break :view captured;
        },
    };
    frame.drawn.display.messages.expire(frame.drawn.clock.frame_start);
    const seconds = ticks / game.main.ticks_per_second;
    frame.drawn.clock.play = .{
        .ticks = @intCast(ticks % game.main.ticks_per_second),
        .seconds = @intCast(seconds % std.time.s_per_min),
        .minutes = @intCast(seconds % std.time.s_per_hour / std.time.s_per_min),
        .hours = @intCast(seconds / std.time.s_per_hour),
    };
    frame.tick = snapshot.tick;
}

test "the flight view follows host admissions and objective carriers" {
    const gpa = std.testing.allocator;
    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    const no_models = game.create.testing.no_models;
    const admission: wire.Admission = .{ .slot = 1, .generation = 2 };
    var snapshot: wire.Snapshot = .{
        .tick = 1,
        .ships = .{
            .{ .generation = 1, .position = .{ 3, 4, 5 } },
            .{ .generation = 2, .position = .{ 8, 0, 1 }, .speed = 12, .throttle = 0.75, .fuel = 240 },
            null,
        },
        .objectives = .{ .six_beacons = @splat(.{ .loose = @splat(0) }) },
    };
    snapshot.objectives.six_beacons[0] = .{ .carried = 1 };
    snapshot.ships[1].?.shields = .{ .left = 1, .right = 2, .fore = 3, .aft = 4 };
    snapshot.ships[1].?.armor = .all(40);
    snapshot.ships[1].?.kills = 2;
    try frame.apply(&snapshot, admission, local, no_models);
    const all = frame.drawn.objects;
    try std.testing.expectEqual(admission.slot, all.player);
    try std.testing.expectEqual(@as(engine.surrender.math.Vector, .{ 3, 4, 5 }), all.slots[0].drawn.position);
    try std.testing.expectEqual(1, frame.drawn.beacon_snapshot.?.countAt(all, all.player));
    const slot = &all.slots[all.player];
    const gauges = game.hud.Cluster.Gauges.of(slot).?;
    try std.testing.expectEqual(12, gauges.speed);
    try std.testing.expectEqual(0.75, gauges.throttle);
    try std.testing.expectEqual(240, slot.object.afterburner_fuel);
    try std.testing.expectEqual(snapshot.ships[1].?.shields, slot.object.shields);
    try std.testing.expectEqual(snapshot.ships[1].?.armor, slot.object.armor);
    try std.testing.expectEqual(2, game.hud.Readout.skull.value(all, &frame.drawn.player));
    var roster: wire.Roster = .{};
    roster.pilots[0] = .{ .generation = 1, .name = wire.lobbyName("Falcon") };
    frame.applyRoster(roster);
    try std.testing.expectEqualStrings("Falcon", all.player_states[0].membership.joined.name.slice());
    const earlier = all.playerBinding(0).?.ship;
    try std.testing.expect(!earlier.valid(local));

    snapshot.tick += 1;
    snapshot.ships[0].?.generation = 3;
    snapshot.ships[1].?.reuse = 8;
    snapshot.objectives.six_beacons[0] = .{ .loose = .{ 8, 0, 1 } };
    try frame.apply(&snapshot, admission, local, no_models);
    try std.testing.expect(!earlier.valid(all));
    try std.testing.expectEqual(3, all.playerBinding(0).?.participant.generation);
    frame.applyRoster(roster);
    try std.testing.expectEqualStrings("", all.player_states[0].membership.joined.name.slice());
    try std.testing.expectEqual(0, frame.drawn.beacon_snapshot.?.countAt(all, all.player));
    try std.testing.expectEqual(2, game.hud.Readout.skull.value(all, &frame.drawn.player));
}
