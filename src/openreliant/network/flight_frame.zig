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
round_start: u32 = 0,
tick: ?u32 = null,
scenery_tick: u32 = 0,
bomb_was_active: ?bool = null,
shadow_was_active: ?bool = null,
vampires_started: bool = false,
host_ship_reuse: [wire.slots]u32 = @splat(0),
/// The pilot's held flight command and where its local prediction has integrated to, in game
/// ticks. The original simulated the player's ship on the player's own machine outright
/// (`FUN_004b5590`); under the host's authority the same feel comes from integrating the held
/// command between snapshots and letting each snapshot correct the result.
command: engine.input.flight.Command = .{},
predicted_tick: u32 = 0,
predicting: bool = false,
/// The presentation timeline, which follows the host's ticks one step behind the newest
/// snapshot, so a frame samples between two known places whatever the network did.
play: Play = .{},
/// Each pilot's last two snapshot places, between which it is drawn: the original's
/// `node_frame_update` (`0x0049A460`) moved a remote player's ship between its last two
/// messages' places by `simulation_counter`'s share of the step, and this stands in for it.
motion: [wire.slots]Motion = @splat(.{}),
scene_replica: wire.ScenePage.Replica = .{},
lead_announced: bool = false,
script_aim: u32 = 0,
landing_camera: ?game.camera.Place = null,
camera: game.camera.Camera = .{},
landing_tick: u32 = 0,
radio_tick: u32 = 0,
director: ?wire.MissionView.Director = null,
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
eject_view: ?struct { started: i32, offset: engine.surrender.math.Vector } = null,
ending_scene: ?EndingScene = null,
effect_tick: ?i32 = null,
blast_started: ?i32 = null,
audio: ?Audio = null,
engine_ship: ?game.gameobj.ObjectRef = null,
lock_tone: game.main.lock.Tone = .{},
projectiles: ?Projectiles = null,

pub const DeathView = struct {
    started: i32,
    watching_from: ?engine.surrender.math.Vector,
};

/// The host's clock as the presentation follows it: the timeline holds the game ticks the
/// newest snapshot has reached, less one step, and passes real time between frames toward it.
/// The original had one clock for simulation and drawing (`simulation_counter`,
/// `0x00588718`, the game ticks since the step began); the snapshots stand where its network
/// messages did, and this timeline keeps their two places the right distance apart however
/// they arrived.
const Play = struct {
    /// Where the timeline stands in game ticks: a whole tick and the part of the next.
    ticks: f64 = 0,
    /// The tick the newest snapshot reached, one step back.
    target: f64 = 0,
    /// The monotonic reading of the last frame that advanced the timeline.
    frame: i64 = 0,
    held: bool = false,

    /// A snapshot arrived: follow its tick, one step behind.
    fn arrive(play: *Play, snapshot_tick: u32, round_start: u32) void {
        const reached = @as(f64, @floatFromInt((snapshot_tick -| round_start) *| game.gameobj.ticks_per_step));
        play.target = reached - game.gameobj.ticks_per_step;
        if (!play.held) {
            play.ticks = play.target;
            play.frame = 0;
            play.held = true;
        }
    }

    fn advance(play: *Play, now: i64) void {
        if (!play.held) return;
        const passed = @as(f64, @floatFromInt(@min(@max(now - play.frame, 0), 250 * std.time.us_per_ms))) /
            std.time.us_per_s * game.main.ticks_per_second;
        play.frame = now;
        const gap = play.target - play.ticks;
        // A stall or a new round moves the timeline at once; otherwise it passes time and
        // closes a quarter of what gap remains, so early and late snapshots alike are absorbed.
        const step: f64 = game.gameobj.ticks_per_step;
        if (@abs(gap) > 3 * step) play.ticks = play.target else play.ticks += passed + gap * 0.25 * @min(passed, 1);
    }
};

/// A ship's last two snapshot places and its velocity over them, from which every frame's
/// drawing is taken.
const Motion = struct {
    from: engine.surrender.math.Place = .{},
    to: engine.surrender.math.Place = .{},
    /// The timeline's tick at which `to` becomes the place to cross to.
    arrival: f64 = 0,
    velocity: engine.surrender.math.Vector = @splat(0),
    continuous: bool = false,

    /// A new snapshot's place. A different ship is a cut, not motion through the space between.
    fn update(motion: *Motion, place: engine.surrender.math.Place, velocity: engine.surrender.math.Vector, at: f64, same: bool) void {
        motion.from = if (same) motion.to else place;
        motion.to = place;
        motion.arrival = at;
        motion.velocity = velocity;
        motion.continuous = same;
    }

    /// The ship's place on the timeline: between the two places up to the arrival, and past it
    /// carried by its velocity until the next snapshot lands, as the original carried a ship
    /// by the flight state its message held.
    fn sample(motion: Motion, at: f64) engine.surrender.math.Place {
        const factor: f32 = @floatCast((at - motion.arrival) / game.gameobj.ticks_per_step + 1);
        if (!motion.continuous) return motion.to;
        if (factor <= 0) return motion.from;
        const from = motion.from;
        const to = motion.to;
        if (factor >= 1) {
            const carried = (factor - 1) * (game.gameobj.ticks_per_step * @as(f32, 1) / game.main.ticks_per_second);
            return .{
                .position = to.position + motion.velocity * @as(engine.surrender.math.Vector, @splat(carried)),
                .orientation = to.orientation,
            };
        }
        const math = engine.surrender.math;
        const turn = math.angles(math.product(math.transpose(from.orientation), to.orientation)) * @as(math.Vector, @splat(factor));
        return .{
            .position = math.lerp(from.position, to.position, factor),
            .orientation = math.product(from.orientation, math.fromAngleVector(turn)),
        };
    }
};

const EndingScene = struct {
    const most_ticks = 60 * game.main.ticks_per_second;

    camera: game.camera.Camera = .{},
    controls: engine.input.Devices = .{},
    expires: u64,
    landing: bool,
    jump_only: bool = false,
    landed: bool = false,
    finished: bool = false,
};

/// The host chooses the outcome. The stock orders, camera and effects play on this pilot's
/// presentation copy after the ship has left the shared action.
pub fn startEnding(frame: *FlightFrame, result: wire.MissionView, types: game.create.Types, textures: *engine.surrender.surrenderlib.srtexture.Table, now: u64) !void {
    const kind = result.ending_scene;
    if (kind == .none or frame.ending_scene != null) return;
    var scene = frame.world();
    const all = scene.objects;
    const index = all.player;
    if (!all.slots[index].object.created) return error.MissingEndingShip;
    scene.spawn = .{ .tables = &frame.tables, .types = types };
    const orders: game.aigeneric.Context = .of(scene);
    const actor = &all.slots[index].object;
    for (all.slots[0..all.count], 0..) |*slot, at| slot.object.flags.disabled = at != index;
    frame.drawn.display.target = null;
    frame.drawn.player.ending = result.ending;
    all.player_states[index].membership = .local_rules;
    frame.director = null;
    actor.flags.sent_off = false;
    actor.flags.hidden = false;
    actor.flags.jumping = false;
    actor.flags.no_collisions = kind != .pod_shot;
    actor.invulnerable = .none;
    game.aigeneric.popAll(orders, index);
    const carrier: ?game.gameobj.Type = switch (kind) {
        .reliant_landing, .jump_to_reliant => .of(.reliant),
        .yamato_landing, .jump_to_yamato => .of(.yamato),
        else => null,
    };
    const jumping = switch (kind) {
        .jump_out, .jump_to_reliant, .jump_to_yamato => true,
        else => false,
    };
    if (carrier) |kind_of_carrier| {
        const home = (try game.create.make(scene, null, kind_of_carrier)) orelse return error.MissingLandingCarrier;
        frame.drawn.player.carrier = .of(all, home);
        if (!game.aigeneric.giveShip(orders, index, .land, home, null)) return error.MissingLandingOrder;
    } else if (!jumping) {
        frame.drawn.effects.tractors = try .init(frame.drawn.gpa, textures);
        scene.tractors = &frame.drawn.effects.tractors.?;
        game.aieject.beginPickup(.of(scene), index, switch (kind) {
            .rescue => .rescued,
            .capture => .captured,
            .pod_shot => .killed,
            else => unreachable,
        }, .queued);
    }
    if (jumping) {
        frame.drawn.effects.jump_effects = @as(game.jump.effect.Effects, undefined);
        frame.drawn.effects.jump_effects.?.init(frame.drawn.gpa, textures) catch |err| {
            frame.drawn.effects.jump_effects = null;
            return err;
        };
        scene.jump_effects = &frame.drawn.effects.jump_effects.?;
        if (!game.aigeneric.giveShip(.of(scene), index, .jump_out, index, null)) return error.MissingJumpOrder;
        actor.flags.sent_off = true;
    }
    const clock = &frame.drawn.clock;
    clock.timer_at = now;
    clock.ran_to = clock.game_ticks;
    frame.ending_scene = .{ .landing = carrier != null, .jump_only = kind == .jump_out, .expires = now + EndingScene.most_ticks };
    frame.stepEnding(types, now, false);
}

pub fn skipEnding(frame: *FlightFrame) void {
    frame.ending_scene = .{ .landing = false, .expires = 0, .finished = true };
}

pub fn stepEnding(frame: *FlightFrame, types: game.create.Types, now: u64, paused: bool) void {
    const ending = &frame.ending_scene.?;
    if (ending.finished) return;
    const clock = &frame.drawn.clock;
    if (paused) {
        ending.expires += now -| clock.timer_at;
        clock.skipTo(now);
        return;
    }
    if (now >= ending.expires) {
        std.log.warn("the local co-op ending did not finish in time", .{});
        ending.finished = true;
        return;
    }
    const drawn = &frame.drawn;
    var scene = frame.world();
    scene.spawn = .{ .tables = &frame.tables, .types = types };
    scene.tractors = if (drawn.effects.tractors) |*effects| effects else null;
    scene.jump_effects = if (drawn.effects.jump_effects) |*effects| effects else null;
    scene.variables = &drawn.variables.?;
    clock.advanceTo(now);
    _ = game.main.gameFrames(clock, &ending.controls, null, scene, .in_turn, null);
    ending.landed = ending.landing and scene.variables.?.mission_over != 0;
    const all = scene.objects;
    ending.finished = if (ending.jump_only)
        all.slots[all.player].running(.jump_out) == null
    else if (ending.landing)
        ending.landed
    else
        game.main.missionOver(scene);
    const viewing = &drawn.player.viewing;
    const seen = viewing.objectIn(all) orelse all.player;
    ending.camera.frame(.{
        .object = .of(&all.slots[seen]),
        .player = .of(&all.slots[all.player]),
        .ticks = clock.frameTicks(),
        .now = clock.viewTime(),
        .random = &frame.random,
        .landing = game.ailand.seen(all, seen),
        .game = scene,
        .viewing = viewing,
    });
}

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
    audio: ?Audio = null,
    explosions: game.explode.Settings,
    particles: game.particles.Pool.Settings,
};

pub const Audio = struct {
    commands: *game.hog_snd.commands.Commands,
    sound: *game.hog_snd.Sound,
};

pub fn beginAudio(frame: *FlightFrame, audio: ?Audio) void {
    frame.audio = audio;
    if (audio) |ready| ready.sound.stopMusic();
}

pub fn endAudio(frame: *FlightFrame) void {
    if (frame.audio) |ready| ready.commands.endFlight(ready.sound);
    frame.audio = null;
}

pub fn playAudio(frame: *FlightFrame, listener: game.camera.Place, music: []const wire.MissionMusic, timer: u32, paused: bool) void {
    const audio = frame.audio orelse return;
    const scene = frame.world();
    for (music) |cue| {
        const command = cue.commands(timer);
        audio.sound.playMusic(command.piece.pathOf(), command.piece.loops, command.piece.level, command.when);
    }
    if (paused) return audio.sound.updateMusic();
    audio.commands.play(audio.sound, listener);
    audio.sound.surround(scene.player.showing.surroundings(scene.view()));
    const heard: game.hog_snd.Hearing = .{ .sound = audio.sound, .camera = &listener, .clock = scene.clock };
    var sound_scene = heard.scene(scene);
    sound_scene.deathmatch = frame.loaded != null;
    if (audio.sound.stdsmp) |bank| {
        audio.sound.frame(bank, sound_scene);
    } else {
        audio.sound.updateMusic();
        audio.sound.update3D(sound_scene);
    }
}

fn setEngineShip(frame: *FlightFrame, scene: game.gameobj.World, ship: ?game.gameobj.ObjectRef) void {
    const audio = frame.audio orelse return;
    if (std.meta.eql(frame.engine_ship, ship)) return;
    if (frame.engine_ship != null) audio.commands.add(.engine_ended);
    if (ship != null) game.sound3d.hearEngine(scene);
    frame.engine_ship = ship;
}

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
}

pub fn destroy(frame: *FlightFrame) void {
    const gpa = frame.drawn.gpa;
    frame.endAudio();
    if (frame.drawn.radio) |*radio| {
        radio.deinit();
    }
    if (frame.loaded) |loaded| loaded.destroy();
    if (frame.projectiles) |*shown| shown.deinit();
    if (frame.drawn.effects.explosions) |*effects| effects.deinit();
    if (frame.drawn.effects.particles) |*particles| particles.deinit();
    if (frame.drawn.effects.sparks) |*sparks| sparks.deinit();
    if (frame.drawn.effects.shockwaves) |*rings| rings.deinit(gpa);
    if (frame.drawn.effects.ion_cannons) |*cannons| cannons.deinit();
    if (frame.drawn.effects.tractors) |*tractors| tractors.deinit();
    if (frame.drawn.effects.jump_effects) |*effects| effects.deinit();
    frame.rays_drawing.deinit();
    if (frame.drawn.effects.rays) |*rays| rays.deinit();
    frame.respawns.deinit(gpa);
    if (frame.wall_mesh) |*mesh| mesh.deinit(gpa);
    frame.drawn.objects.destroy();
    frame.drawn.arena.deinit();
    gpa.destroy(frame);
}

pub fn presentRadio(frame: *FlightFrame, lines: []const wire.CampaignLine) void {
    const scene = frame.world();
    const radio, const context = game.radio.onAir(scene) orelse return;
    const tick = frame.tick orelse return;
    if (frame.radio_tick != tick) {
        radio.step(context, scene.clock.frameTicks(), scene.clock.game_ticks);
        frame.radio_tick = tick;
    }
    for (lines) |entry| {
        var line = entry.line;
        if (line.speaker == .ship) {
            if (frame.seenObject(line.speaker.ship.object)) |slot| {
                line.speaker.ship.object = .of(scene.objects, slot);
            } else {
                line.speaker = .{ .other = game.radio.nobody };
            }
        }
        line.present(scene, entry.tick);
    }
}

pub fn presentProjectiles(frame: *FlightFrame, pages: *const [wire.ordnance.Page.pages]?wire.ordnance.Page) !void {
    if (frame.projectiles) |*shown| try shown.apply(frame.world(), pages, frame.tick orelse return);
}

pub fn loadArena(frame: *FlightFrame, files: stock.Files, scenario: wire.Scenario, types: game.create.Types) !void {
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
    const all = frame.drawn.objects;
    const local_team = if (roster.pilots[all.player]) |local| local.team else null;
    for (roster.pilots, 0..) |entry, index| {
        const membership = &all.player_states[index].membership;
        if (membership.* != .joined) continue;
        const peer = entry orelse continue;
        if (peer.generation != membership.joined.generation) continue;
        membership.joined.name.set(peer.name.slice());
        if (all.arena_scores == .teams) {
            membership.joined.team = peer.team;
            all.slots[index].object.side = if (local_team == peer.team) .friendly else .hostile;
        }
    }
}

pub fn weaponAim(frame: *FlightFrame) wire.ordnance.Aim {
    const all = frame.drawn.objects;
    var aim: wire.ordnance.Aim = .{ .reuse = frame.host_ship_reuse[all.player], .script_aim = frame.script_aim, .blind_fire = frame.drawn.display.aim.blind_fire };
    const entry = game.ai.controlEntry(all, all.player) orelse return aim;
    const target = entry.target.slotIn(all) orelse return aim;
    if (target != all.player and target < wire.slots and all.playerBinding(target) != null)
        aim.target = .{ .slot = target, .reuse = frame.host_ship_reuse[target] };
    if (frame.scene_replica.reuses[target]) |reuse| aim.target = .{ .slot = target, .reuse = reuse };
    const component = entry.target.resolve(all).component;
    if (aim.target != null and component >= 0) aim.component = @intCast(component);
    return aim;
}

fn seenObject(frame: *const FlightFrame, ref: ?game.gameobj.ObjectRef) ?u16 {
    const object = ref orelse return null;
    const all = frame.drawn.objects;
    if (!all.slots[object.slot].object.created) return null;
    const reuse = if (object.slot < all.players) frame.host_ship_reuse[object.slot] else frame.scene_replica.reuses[object.slot];
    return if (reuse == object.reuse) object.slot else null;
}

pub fn presentGuide(frame: *FlightFrame, guide: wire.MissionView.Guide) void {
    const all = frame.drawn.objects;
    const ship = &all.slots[all.player];
    ship.object.escort_point = .from(frame.seenObject(guide.escort));
    ship.object.nav_point = .from(frame.seenObject(guide.nav));
    frame.drawn.player.primary_target = if (frame.seenObject(guide.primary)) |target| .of(all, .at(target, null)) else null;
    if (guide.aim != frame.script_aim) scripted: {
        const target = if (guide.target) |aim| frame.seenObject(aim.object) orelse break :scripted else null;
        const part: ?u16 = if (guide.target) |aim| if (aim.component) |component| component else null else null;
        const aim = game.aigeneric.Target.at(target orelse 0, part);
        const chosen: game.aigeneric.Target = if (target != null) aim else .none;
        if (engine.input.setPilotTarget(&frame.drawn.display, all, all.player, chosen.index, chosen.component, false))
            frame.script_aim = guide.aim;
    }
    const landing = guide.landing orelse return;
    const at = frame.seenObject(landing.carrier) orelse return;
    const carrier = &all.slots[at];
    const view: game.camera.View = if (landing.view == .tube) .landing_tube else .landing_aside;
    if (frame.landing_camera == null) game.ailand.reliant.openTube(frame.world(), carrier);
    const tick = frame.tick orelse return;
    if (tick != frame.landing_tick) {
        game.gameobj.updateTree(&carrier.object.root, if (carrier.model) |*model| model else null, null);
        frame.landing_tick = tick;
    }
    frame.drawn.player.showing = .landing;
    frame.drawn.player.viewing.view = view;
    frame.drawn.player.viewing.last = view;
    for (all.slots[0..all.count], 0..) |*slot, index| {
        slot.object.flags.hidden = index != all.player and index != at;
    }
    frame.landing_camera = game.camera.reliantLanding(landing.tube, carrier.drawn.orientation, ship.drawn.position, view);
}

pub fn presentScene(frame: *FlightFrame, pages: *const [wire.ScenePage.count]?wire.ScenePage, types: game.create.Types) !void {
    const tick = frame.tick orelse return;
    var scene = frame.world();
    scene.spawn = .{ .tables = &frame.tables, .types = types };
    for (pages) |entry| {
        const page = entry orelse continue;
        if (page.tick <= tick) try frame.scene_replica.apply(scene, &page);
    }
}

pub fn presentScenery(frame: *FlightFrame, scenery: *const wire.Scenery, types: game.create.Types) !void {
    const tick = frame.tick orelse return;
    if (scenery.tick > tick or scenery.tick <= frame.scenery_tick) return;
    try frame.rocks.apply(frame.drawn.objects, &scenery.rocks);
    try frame.presentMines(&scenery.mines, types);
    frame.scenery_tick = scenery.tick;
}

fn presentWeapons(frame: *FlightFrame, status: ?wire.ordnance.Status) void {
    const all = frame.drawn.objects;
    const slot = &all.slots[all.player];
    const weapons = &all.player_states[all.player].weapons;
    const prior = weapons.ring;
    if (status) |shown| {
        shown.panels.apply(&slot.object);
        // The host owns the devices' charges; the bars read what it last sent.
        const charges = &all.player_states[all.player].charges;
        for (std.enums.values(game.ship_devices.Device), shown.charges) |device, share|
            charges.getPtr(device).ticks = @intFromFloat(@as(f32, @floatFromInt(share)) / 255 * @as(f32, @floatFromInt(device.spec().full)));
    }
    const decoys_before = slot.object.countermeasures;
    weapons.ring = if (status) |shown| shown.ring() else .{};
    weapons.lock = if (status) |shown| shown.held else .{};
    slot.object.countermeasures = if (status) |shown| shown.countermeasures else 0;
    if (slot.object.countermeasures < decoys_before) game.hud.beep(frame.world(), .done);
    slot.object.missile_homing = @intFromBool(if (status) |shown| shown.incoming else false);
    if (status != null and (weapons.ring.left < prior.left or weapons.ring.armed != prior.armed)) {
        if (frame.drawn.display.windows.open(.missiles, false))
            frame.drawn.display.windows.status.getPtr(.missiles).held = true;
    }
    if (frame.audio) |audio| frame.lock_tone.sound(weapons.lock.locked(), audio.commands, frame.drawn.player.viewing.last);
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

fn presentMines(frame: *FlightFrame, mines: *const [powerups.mine_count]?wire.Mine, types: game.create.Types) !void {
    const first = frame.mine_start orelse return;
    const scene = frame.world();
    const all = scene.objects;
    for (mines, &frame.host_mines, 0..) |entry, *known, offset| {
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

pub fn world(frame: *FlightFrame) game.gameobj.World {
    return .{
        .objects = frame.drawn.objects,
        .player = &frame.drawn.player,
        .random = &frame.random,
        .clock = &frame.drawn.clock,
        .shake = &frame.drawn.shake,
        .sounds = if (frame.audio) |audio| audio.commands else null,
        .radio = if (frame.drawn.radio) |*radio| radio else null,
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

/// Keep the simulation snapshots authoritative while the drawing follows the presentation
/// timeline: each frame samples every ship between its last two snapshot places, and the
/// clock-driven behaviour reads a clock that advances with the frames, as the original's
/// mission loop advanced it (`frame_controls`, `0x00414060`).
pub fn present(frame: *FlightFrame, snapshot: *const wire.Snapshot, admission: wire.Admission, local: *game.create.Objects, types: game.create.Types, now: i64) !void {
    const fresh = frame.tick == null or snapshot.tick != frame.tick.?;
    if (fresh) {
        frame.play.arrive(snapshot.tick, frame.round_start);
        // `apply` reads the clock the previous frame left, which stands a frame behind the
        // timeline: its starts and windows measure from where the drawing last was.
        try frame.apply(snapshot, admission, local, types);
        const all = frame.drawn.objects;
        for (snapshot.ships, 0..) |entry, index| {
            const ship = entry orelse {
                frame.motion[index].continuous = false;
                continue;
            };
            const slot = &all.slots[index];
            const same = slot.object.created and frame.host_ship_reuse[index] == ship.reuse and slot.object.type == ship.kind();
            const velocity: engine.surrender.math.Vector = if (slot.flight) |flight|
                .{
                    wire.dequantizeVelocity(ship.velocity[0], flight.max_speed),
                    wire.dequantizeVelocity(ship.velocity[1], flight.max_speed),
                    wire.dequantizeVelocity(ship.velocity[2], flight.max_speed),
                }
            else
                @splat(0);
            frame.motion[index].update(
                .{ .position = ship.position, .orientation = ship.orientationMatrix() },
                velocity,
                frame.play.target,
                same,
            );
        }
    }
    frame.play.advance(now);
    setClock(frame, @intFromFloat(@max(frame.play.ticks, 0)));
    const scene = frame.world();
    const cockpit = game.camera.Cockpit;
    frame.drawn.shake = @max(@min(frame.drawn.shake, cockpit.shake_most) - cockpit.shake_fade * @as(f32, @floatFromInt(scene.clock.frame_duration)), 0);
    if (snapshot.ships[admission.slot]) |ship| if (ship.at_wall) {
        frame.drawn.shake = 1;
    };
    if (scene.flash) |flash| flash.countDown(scene.clock.frame_duration);
    if (scene.sparks) |sparks| sparks.frame(scene.clock);
    // The pilot's own ship draws from what the pilot holds, corrected by each snapshot, and
    // every other ship from its last two snapshot places on the timeline.
    var predicted = false;
    {
        const own = admission.slot;
        const slot = &frame.drawn.objects.slots[own];
        if (frame.predicting and slot.object.created and !slot.object.flags.exploding and !slot.object.flags.ejected) {
            const player = &frame.drawn.objects.player_states[own];
            while (frame.predicted_tick < frame.drawn.clock.game_ticks) : (frame.predicted_tick += 1) {
                if (slot.combat) |combat|
                    engine.input.flight.apply(&player.controls, &player.shield_reserves, &slot.object, combat, frame.command, 1);
                game.motion.moveSlot(scene, own);
            }
            game.objects.setPlace(&slot.object, &slot.drawn, slot.object.placeAt(.next));
            if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
            predicted = true;
        } else frame.predicted_tick = frame.drawn.clock.game_ticks;
    }
    for (&frame.motion, 0..) |*track, index| {
        if (index == admission.slot and predicted) continue;
        const slot = &frame.drawn.objects.slots[index];
        if (!slot.object.created or !track.continuous) continue;
        const place = track.sample(frame.play.ticks);
        slot.drawn.position = place.position;
        slot.drawn.orientation = place.orientation;
        if (slot.model) |*model| model.place(place.position, place.orientation);
    }
}

/// The drawn clock for a frame of the presentation timeline: the whole ticks it has reached,
/// and the ticks this frame covers.
fn setClock(frame: *FlightFrame, whole: u32) void {
    const clock = &frame.drawn.clock;
    const covered: i32 = @as(i32, @intCast(whole)) -| clock.mission_ticks;
    clock.game_ticks = whole;
    clock.mission_ticks = @intCast(whole);
    clock.frame_start = clock.mission_ticks;
    clock.frame_duration = covered;
    clock.drawn_duration = covered;
    clock.play = .fromTicks(whole);
}

pub fn apply(frame: *FlightFrame, snapshot: *const wire.Snapshot, admission: wire.Admission, local: *game.create.Objects, types: game.create.Types) !void {
    if (frame.tick == snapshot.tick) return;
    const all = frame.drawn.objects;
    all.player = admission.slot;
    if (snapshot.mission) |mission| {
        all.players = mission.pilot_slots;
        all.mission_number = mission.number;
        all.mission25_second_part = mission.second_part;
        frame.environment.requested = mission.nebula;
        frame.director = mission.director;
        var objectives = &frame.drawn.display.objectives;
        if (frame.tick == null) objectives.reset(mission.number, mission.second_part, null);
        // Only a newly current objective changes the pilot's selected page.
        for (mission.objectives, 0..) |state, index| {
            if (objectives.states[index] != state) _ = objectives.set(@intCast(index), state);
        }
        if (frame.drawn.variables == null) frame.drawn.variables = .{};
        const ready = &frame.drawn.variables.?.ready;
        const leads = mission.lead == admission.slot;
        if (!leads or !mission.travel.jump) ready.jump = .no else if (ready.jump == .no) {
            ready.jump = .newly;
        }
        if (!leads or !mission.travel.warp) ready.warp = .no else if (ready.warp == .no) {
            ready.warp = .newly;
        }
        frame.drawn.display.readyPrompt(ready);
    }
    const scene = frame.world();
    if (snapshot.scenario != null and snapshot.scenario.?.hasPowerUps()) {
        try frame.presentPickups(snapshot.pickups);
    }
    frame.drawn.portals.begin();
    defer frame.drawn.portals.end();
    for (snapshot.ships, 0..) |entry, offset| {
        const index: u16 = @intCast(offset);
        const prior = all.playerBinding(index);
        const before = frame.respawns.left[index];
        if (prior != null and (entry == null or prior.?.participant.generation != entry.?.generation or frame.host_ship_reuse[index] != entry.?.reuse or all.slots[index].object.type != entry.?.kind())) {
            game.create.resetSlot(.of(scene), index);
            all.player_states[index] = .{ .membership = .vacant };
        }
        const ship = entry orelse {
            frame.respawns.left[index] = 0;
            if (index == admission.slot) frame.death_view = null;
            continue;
        };
        if (!all.slots[index].object.created) {
            all.loadout_racks[index] = @splat(.of(.none));
            _ = try game.create.createObject(all, &frame.tables, types, index, ship.kind(), 0, ship.position, &frame.random);
            if (snapshot.hasOrdnance()) all.slots[index].object.countermeasures = 0;
            all.player_states[index] = .{ .membership = .{ .joined = .{
                .generation = ship.generation,
                .ship = .of(all, index),
            } } };
            frame.host_ship_reuse[index] = ship.reuse;
            if (index == admission.slot) {
                _ = try game.aigeneric.push(.of(scene), index, .player_control, .none);
                game.main.fitDevices(&all.player_states[index].charges, &frame.drawn.display, game.main.cockpitShip(all, ship.kind()), false);
                // A ship made anew starts its prediction from the snapshot, owing no ticks.
                frame.predicted_tick = frame.drawn.clock.game_ticks;
            } else if (snapshot.mission == null) {
                all.slots[index].object.side = .hostile;
            }
        }
        const slot = &all.slots[index];
        const ejected = ship.pod and !slot.object.flags.ejected;
        if (ejected) {
            game.aieject.showPod(slot);
            if (index == admission.slot) frame.eject_view = .{
                .started = scene.clock.frame_start,
                .offset = engine.surrender.math.xAxis(ship.orientationMatrix()) * @as(engine.surrender.math.Vector, @splat(game.camera.eject_reach)),
            };
        }
        slot.object.flags.ejected = ship.pod;
        slot.object.flags.hidden = ship.pod_clear and index != admission.slot;
        if (ship.pod) slot.object.flags.targetable = !ship.pod_clear;
        const orientation = ship.orientationMatrix();
        if (index == admission.slot and frame.predicting and slot.object.created and frame.host_ship_reuse[index] == ship.reuse) {
            // The prediction stands corrected by a quarter, so what the pilot could not
            // predict, a collision or a hit on the host, closes smoothly rather than snapping;
            // a different ship cuts outright below, where the slot is made anew.
            const at = slot.object.root.next_position;
            const next = engine.surrender.math;
            slot.object.root.next_position = .{
                .x = at.x + (ship.position[0] - at.x) * 0.25,
                .y = at.y + (ship.position[1] - at.y) * 0.25,
                .z = at.z + (ship.position[2] - at.z) * 0.25,
            };
            const turn = next.angles(next.product(next.transpose(slot.object.root.next_orientation), orientation)) * @as(next.Vector, @splat(0.25));
            slot.object.root.next_orientation = next.product(slot.object.root.next_orientation, next.fromAngleVector(turn));
        } else {
            game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = ship.position, .orientation = orientation });
        }
        // order_eject breaks off the cockpit and plays EJECT01 (0x00415808).
        if (ejected) game.sound3d.playIn(scene, null, null, index, .eject01, 1, game.sound3d.fxClass(all, index));
        if ((before == 0 or ship.respawn > before) and ship.respawn + game.gameobj.ticks_per_step >= game.deathmatch.respawn.duration)
            game.deathmatch.respawn.sound(scene, index);
        slot.object.speed = ship.speed;
        // The vector, the rates and the shares the flight model settles by, which a speed along
        // the nose alone cannot give: they are what the presentation carries a ship by between
        // snapshots.
        if (slot.flight) |flight_model| {
            slot.object.velocity = .{
                .x = wire.dequantizeVelocity(ship.velocity[0], flight_model.max_speed),
                .y = wire.dequantizeVelocity(ship.velocity[1], flight_model.max_speed),
                .z = wire.dequantizeVelocity(ship.velocity[2], flight_model.max_speed),
            };
        } else slot.object.velocity = .of(engine.surrender.math.forward(orientation) * @as(engine.surrender.math.Vector, @splat(ship.speed)));
        slot.object.pitch_rate = wire.dequantizeRate(ship.rates[0]);
        slot.object.yaw_rate = wire.dequantizeRate(ship.rates[1]);
        slot.object.roll_rate = wire.dequantizeRate(ship.rates[2]);
        slot.object.pitch_input = wire.dequantizeInput(ship.inputs[0]);
        slot.object.yaw_input = wire.dequantizeInput(ship.inputs[1]);
        slot.object.roll_input = wire.dequantizeInput(ship.inputs[2]);
        slot.object.lateral_input = @floatFromInt(ship.lateral);
        slot.object.speed_factor = wire.dequantizeShare(ship.speed_factor);
        slot.object.engines_intact = wire.dequantizeShare(ship.engines);
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
        if (snapshot.scenario != null) slot.object.flags.targetable = ship.targetable;
        if (!ship.dying and index == admission.slot) frame.death_view = null;
        all.player_states[index].membership.joined.kills.count = ship.kills;
        all.player_states[index].membership.joined.deaths = ship.deaths;
        all.player_states[index].membership.joined.ping_ms = ship.ping_ms;
        slot.object.afterburner = ship.afterburner;
        slot.object.reverse_thrust = ship.reverse_thrust;
        const cloaking = if (slot.cloak) |effect| !effect.going else false;
        if (ship.cloaked != cloaking) {
            if (ship.cloaked) game.cloak.beginPowerUp(scene, index) else game.cloak.uncloak(scene, index);
        }
        if (slot.cloak != null) game.cloak.frame(slot, scene.clock.frame_start);
        if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
        frame.respawns.clip(slot, index, &frame.drawn.portals, ship.respawn);
    }
    all.arena_scores = if (snapshot.teams) |teams| .{ .teams = teams } else .free_for_all;
    const local_ship = snapshot.ships[admission.slot];
    const sounding = if (local_ship) |ship| !ship.pod and !ship.dying and !ship.engine_waiting else false;
    frame.setEngineShip(scene, if (sounding) .of(all, admission.slot) else null);
    const viewing = &frame.drawn.player.viewing;
    viewing.last = viewing.view;
    viewing.view = if (frame.director != null)
        .director
    else if (frame.respawns.left[admission.slot] != 0)
        game.camera.deathmatch_respawn_view
    else if (frame.death_view) |death|
        (if (death.watching_from == null) .pull_back else .watch)
    else if (frame.eject_view != null)
        .eject
    else
        .cockpit;
    if (snapshot.blast) |blast| frame.presentBlast(scene, blast);
    if (scene.explosions) |effects| effects.frame(scene);
    if (scene.particles) |particles| particles.frame(scene.clock);
    if (scene.shockwaves) |rings| rings.frame(scene);
    if (snapshot.hasOrdnance()) frame.presentWeapons(snapshot.weapons);
    if (snapshot.scenario != null and snapshot.scenario.?.hasPowerUps()) frame.presentPower(snapshot.power);
    // Reserve the identities used during the session in the local mission's slot counters.
    for (local.reuses[0..wire.slots], all.reuses[0..wire.slots]) |*reuse, received| reuse.* = received +% 1;
    frame.drawn.tag_bomb = switch (snapshot.objectives) {
        .tag_bomb => |active| if (active) |bomb| .{
            .carrier = if (all.playerBinding(bomb.carrier)) |pilot| pilot.participant else null,
            .remaining = bomb.remaining,
        } else .{},
        else => null,
    };
    frame.drawn.shadow = if (snapshot.objectives == .hunt_the_shadow)
        if (snapshot.objectives.hunt_the_shadow) |owner|
            if (all.playerBinding(owner)) |pilot| pilot.participant else null
        else
            null
    else
        null;
    frame.drawn.vampire_roles = if (snapshot.objectives == .vampires) snapshot.objectives.vampires else null;
    frame.drawn.beacon_snapshot = switch (snapshot.objectives) {
        .none, .tag_bomb, .hunt_the_shadow, .vampires => null,
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
    frame.drawn.display.followTarget(all, true);
    frame.drawn.display.zoomRadar(scene);
    frame.drawn.display.finishGameFrame(scene);
    frame.drawn.display.messages.expire(frame.drawn.clock.frame_start);
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
        .ships = @splat(null),
        .objectives = .{ .six_beacons = @splat(.{ .loose = @splat(0) }) },
    };
    snapshot.ships[0] = .{ .generation = 1, .position = .{ 3, 4, 5 } };
    snapshot.ships[1] = .{ .generation = 2, .position = .{ 8, 0, 1 }, .speed = 12, .throttle = 0.75, .fuel = 240 };
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

test "the mixer follows the local fighter across launch, burn, ejection and replacement" {
    const gpa = std.testing.allocator;
    var speaker: game.hog_snd.testing.Speaker = undefined;
    try speaker.init(4, null);
    defer speaker.deinit();
    const bank = comptime game.hog_snd.testing.bank(80);
    speaker.sound.open3D(try @import("openreliant").fat.Bank.parse(&bank), &.{});
    const sound = &speaker.sound;
    const driver = speaker.mixer.driver();
    const engine_voice = &sound.voices_3d[sound.engine_voice.?];
    const burner = &sound.voices_3d[sound.burner_voice.?];

    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    frame.beginAudio(.{ .commands = &speaker.asked, .sound = sound });

    const admission: wire.Admission = .{ .slot = 0, .generation = 1 };
    const no_models = game.create.testing.no_models;
    var snapshot: wire.Snapshot = .{ .tick = 1, .ships = @splat(null), .mission = .{ .number = 1, .pilot_slots = 1, .lead = 0 } };
    snapshot.ships[0] = .{ .generation = 1, .position = @splat(0), .engine_waiting = true };
    try frame.apply(&snapshot, admission, local, no_models);
    frame.playAudio(speaker.listener, &.{}, 4, false);
    try std.testing.expect(engine_voice.isFree());

    snapshot.tick += 1;
    snapshot.ships[0].?.engine_waiting = false;
    snapshot.ships[0].?.throttle = game.motion.afterburner_throttle;
    snapshot.ships[0].?.afterburner = true;
    try frame.apply(&snapshot, admission, local, no_models);
    frame.playAudio(speaker.listener, &.{}, 8, false);
    try std.testing.expectEqual(.playing, driver.sample3DStatus(engine_voice.sample));
    try std.testing.expectEqual(.playing, driver.sample3DStatus(burner.sample));

    game.main.pauseFlightVoices(sound, true);
    frame.playAudio(speaker.listener, &.{}, 12, true);
    try std.testing.expectEqual(.stopped, driver.sample3DStatus(burner.sample));
    game.main.pauseFlightVoices(sound, false);
    try std.testing.expectEqual(.playing, driver.sample3DStatus(burner.sample));

    snapshot.tick += 1;
    snapshot.ships[0].?.pod = true;
    try frame.apply(&snapshot, admission, local, no_models);
    frame.playAudio(speaker.listener, &.{}, 16, false);
    try std.testing.expect(engine_voice.isFree() and burner.isFree());
    try std.testing.expectEqual(.idle, sound.effects.engine);

    snapshot.tick += 1;
    snapshot.ships[0] = .{ .generation = 1, .reuse = 2, .fighter = .naginata, .position = @splat(0) };
    try frame.apply(&snapshot, admission, local, no_models);
    frame.playAudio(speaker.listener, &.{}, 20, false);
    try std.testing.expectEqual(@backingInt(game.sound3d.engineSound(.of(.naginata))), engine_voice.sound);
    try std.testing.expect(burner.isFree());
    frame.endAudio();
    try std.testing.expect(engine_voice.isFree());
}

test "the target panel opens and closes as flight snapshots advance" {
    const gpa = std.testing.allocator;
    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    const all = frame.drawn.objects;
    const display = &frame.drawn.display;
    const no_models = game.create.testing.no_models;
    const admission: wire.Admission = .{ .slot = 0, .generation = 1 };
    var snapshot: wire.Snapshot = .{
        .tick = 1,
        .ships = @splat(null),
    };
    snapshot.ships[0] = .{ .generation = 1, .position = @splat(0) };
    snapshot.ships[1] = .{ .generation = 2, .position = .{ 0, 0, 2000 } };
    try frame.apply(&snapshot, admission, local, no_models);
    frame.play.arrive(snapshot.tick, frame.round_start);
    try std.testing.expect(engine.input.setPilotTarget(display, all, 0, 1, game.aigeneric.Target.whole, true));
    try std.testing.expectEqual(.opening, display.windows.status.get(.target).phase);

    // A duplicate view while paused must leave the window's phase alone.
    try frame.apply(&snapshot, admission, local, no_models);
    try std.testing.expectEqual(0, display.windows.status.get(.target).progress);
    const tick_us = std.time.us_per_s / game.main.ticks_per_second;
    var now: i64 = 0;
    var opened = false;
    for (0..100) |_| {
        now += 5 * tick_us;
        snapshot.tick += 1;
        try frame.present(&snapshot, admission, local, no_models, now);
        if (display.windows.status.get(.target).phase == .open) {
            opened = true;
            break;
        }
    }
    try std.testing.expect(opened);

    try std.testing.expect(engine.input.setPilotTarget(display, all, 0, -1, game.aigeneric.Target.whole, true));
    try std.testing.expectEqual(.closing, display.windows.status.get(.target).phase);
    var shut = false;
    for (0..100) |_| {
        now += 5 * tick_us;
        snapshot.tick += 1;
        try frame.present(&snapshot, admission, local, no_models, now);
        if (display.windows.status.get(.target).phase == .shut) {
            shut = true;
            break;
        }
    }
    try std.testing.expect(shut);
}

test "the presentation timeline follows the host one step behind" {
    const step: f64 = game.gameobj.ticks_per_step;
    var play: Play = .{};
    play.arrive(10, 0);
    try std.testing.expectEqual(9 * step, play.ticks);
    // A step of time passes: the timeline reaches where the next snapshot will land.
    play.advance(4 * std.time.us_per_s / game.main.ticks_per_second);
    try std.testing.expectEqual(10 * step, play.ticks);
    play.arrive(11, 0);
    play.advance(8 * std.time.us_per_s / game.main.ticks_per_second);
    try std.testing.expectEqual(11 * step, play.ticks);
    // A round change or a stall moves the timeline at once rather than slewing through it.
    play.arrive(100, 0);
    play.advance(0);
    try std.testing.expectEqual(99 * step, play.ticks);
}

test "a ship crosses between its last two places and carries past the arrival" {
    const math = engine.surrender.math;
    const start: math.Place = .{ .position = .{ 0, 0, 0 }, .orientation = math.rotation(.y, 0) };
    const crossed: math.Place = .{ .position = .{ 40, 0, 0 }, .orientation = math.rotation(.y, 0) };
    var motion: Motion = .{};
    motion.update(start, @splat(0), 36, false);
    motion.update(crossed, @splat(10), 40, true);
    try std.testing.expectEqual(@as(f32, 0), motion.sample(36).position[0]);
    try std.testing.expectEqual(@as(f32, 20), motion.sample(38).position[0]);
    try std.testing.expectEqual(@as(f32, 40), motion.sample(40).position[0]);
    // Past the arrival the ship is carried by its velocity: one step at ten a second is 0.4.
    try std.testing.expectApproxEqAbs(@as(f32, 40.4), motion.sample(44).position[0], 0.001);
    // A different ship cuts straight to its place.
    motion.update(start, @splat(0), 44, false);
    try std.testing.expectEqual(start.position, motion.sample(44).position);
}

test "the pilot's own ship draws from the held command and corrects by the snapshot" {
    const gpa = std.testing.allocator;
    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    const all = frame.drawn.objects;
    const no_models = game.create.testing.no_models;
    const admission: wire.Admission = .{ .slot = 0, .generation = 1 };
    var snapshot: wire.Snapshot = .{ .tick = 1, .ships = @splat(null) };
    snapshot.ships[0] = .{ .generation = 1, .position = @splat(0) };
    frame.predicting = true;
    frame.command = .{ .steering = .{ .axes = .{ 0, 0, 0 } }, .throttle = .{ .axis = 1.0 } };
    const tick_us = std.time.us_per_s / game.main.ticks_per_second;
    var now: i64 = 0;
    try frame.present(&snapshot, admission, local, no_models, now);
    const slot = &all.slots[0];
    try std.testing.expect(slot.object.created);

    // Frames pass with no new snapshot: the held throttle carries the ship by itself.
    var carried = false;
    for (0..60) |_| {
        now += 5 * tick_us;
        try frame.present(&snapshot, admission, local, no_models, now);
        const place = slot.drawn.position;
        if (@abs(place[0]) + @abs(place[1]) + @abs(place[2]) > 10) {
            carried = true;
            break;
        }
    }
    try std.testing.expect(carried);

    // A snapshot far from the prediction closes a quarter of the gap, not at once.
    snapshot.tick += 1;
    snapshot.ships[0].?.position = slot.drawn.position + @as(engine.surrender.math.Vector, @splat(100));
    try frame.present(&snapshot, admission, local, no_models, now);
    const gap = slot.drawn.position - snapshot.ships[0].?.position;
    const left = @abs(gap[0]) + @abs(gap[1]) + @abs(gap[2]);
    try std.testing.expect(left > 150);
}
