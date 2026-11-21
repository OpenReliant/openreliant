//! The client's view of a host snapshot, in the records the flight renderer and HUD already read.
const std = @import("std");
const log = std.log.scoped(.flight_frame);
const engine = @import("openreliant").engine;
const game = engine.game;
const wire = @import("wire.zig");
const stock = @import("stock_arena.zig");
const Projectiles = @import("projectiles.zig");
const FlightFrame = @This();

/// One predict-and-correct lane per pilot slot, then one per arena rock.
const lanes = wire.slots + wire.Rocks.max;
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
/// The pilot's held flight command, which the local simulation applies to the pilot's own ship
/// each step it runs (`submitPlayerCommand`). The original simulated the player's ship on the
/// player's own machine outright (`FUN_004b5590`); under the host's authority the same feel comes
/// from the client's simulation running the held command and each snapshot correcting the result.
command: engine.input.flight.Command = .{},
/// The simulation's step takes devices but a client's never reads them: the graphical client
/// samples the controls once a frame into `command`.
devices: engine.input.Devices = .{},
/// The tick the last step reached and the command it flew, which the client sends the host so
/// it flies the pilot's ship the same way at the same step.
flown: ?Flown = null,
/// Whether the local simulation has started its clock.
running: bool = false,
/// Where the local simulation carried each ship, step by step, which each snapshot is matched
/// against at the same moment (`correct`); rocks share the lanes (Rocket League GDC 2018
/// predicts every object; Fiedler, "Snapshot Interpolation").
tracks: [lanes]Track = @splat(.{}),
/// What each tracked object still has to take in of its last correction, a share every step (`ease`).
easing: [lanes]Ease = @splat(.{}),
/// The facing and tick each rock was last seen at, and the filtered turn carried between them.
rock_seen: [wire.Rocks.max]?RockPrior = @splat(null),
rock_spin: [wire.Rocks.max]?Vector = @splat(null),
/// The mission clock of the snapshot last applied, whose step the scenery rides.
applied_clock: i32 = 0,
/// How far each ship is drawn from where its simulation flies it, taken away over the next
/// frames so a correction never moves a drawn ship at once (Fiedler, "Networked Physics"):
/// `position` in world space, `turn` applied after the ship's orientation. The pilot's own ship
/// is one of these: its offset is the camera's.
offsets: [wire.slots]struct { position: Vector = @splat(0), turn: engine.surrender.math.Matrix = engine.surrender.math.identity } = @splat(.{}),
/// The host's echo of every pilot's command, step by step, which the simulation flies the
/// other pilots' ships by (Rocket League GDC 2018).
commands: CommandRing = .{},
/// The pilot's held trigger this frame, which the muzzle prediction fires through the single
/// player path while the host alone decides what each shot does (Overwatch GDC 2017).
own_trigger: bool = false,
/// The MATCH SPEED press of this frame, which the local command flies once, as the host flies
/// the press the wire brought it.
own_match: bool = false,
/// The client's own predicted bolts, oldest first, each given up when the host's shot for it
/// arrives: `index` the local bullets pool slot, `fired_at` the client tick it left at.
own_muzzles: struct {
    const depth = 16;
    entries: [depth]struct { index: u8, fired_at: i32 } = undefined,
    count: u8 = 0,
    next: u8 = 0,
} = .{},
/// The host's margin of the pilot's inputs, in ticks, while the clock takes in its last
/// correction (`reconcile`).
margin: ?f32 = null,
/// The host tick the last margin report rode.
margin_tick: i32 = 0,
/// Microseconds the mission clock runs ahead of real time, so the host's snapshots arrive at a
/// steady lead (`keepClock`).
skew_us: i64 = 0,
/// What remains of the skew to take in, a little each frame.
owed_us: f32 = 0,
/// How far the mission clock is ahead of the host's when its snapshots arrive, in ticks, held
/// near its lows so a late snapshot does not pull the clock back.
lead: ?f32 = null,
/// The real time of the last frame, in microseconds.
frame_us: i64 = 0,
scene_replica: wire.ScenePage.Replica = .{},
lead_announced: bool = false,
script_aim: u32 = 0,
scanner_command: u32 = 0,
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
spin_outs: game.aiexplode.SpinOuts = .{},
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
    /// The local cockpit, which the client loads for its own ship once it is known, as a
    /// mission's start does in single player (`start.cockpit`); null where there is none.
    cockpit: ?*game.main.cockpit.Cockpit = null,
    archive: ?*const game.bigfile.Hog = null,
    models: game.srofiles.Settings = .{},
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
    const scanner = &frame.drawn.player.scanner;
    const target = frame.seenObject(guide.scanner_target);
    if (scanner.object != target or frame.scanner_command != guide.scanner_command) {
        frame.scanner_command = guide.scanner_command;
        scanner.set(target);
        frame.drawn.display.restartScanner();
    }
    const scene = frame.world();
    scanner.frame(scene, scene.clock.frame_start);
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
    // The scenery rides the step of the last applied snapshot, whose clock carries the same
    // moment in mission ticks the tracks are recorded in.
    try frame.presentRocks(&scenery.rocks, frame.applied_clock);
    try frame.presentMines(&scenery.mines, types);
    frame.scenery_tick = scenery.tick;
}

/// The shortest signed way from one angle to another.
fn angleDelta(from: f32, to: f32) f32 {
    const tau = 2 * std.math.pi;
    return @mod(to - from + std.math.pi, tau) - std.math.pi;
}

/// A rock the host sends once places it exactly; the next pair of sceneries measures its turn,
/// which the simulation carries it by from then (Rocket League GDC 2018), and every later
/// scenery only eases the drift the wire's quantized angles leave (`correctRock`).
fn presentRocks(frame: *FlightFrame, rocks: *const wire.Rocks, tick: i32) !void {
    const math = engine.surrender.math;
    const all = frame.drawn.objects;
    if (rocks.count != frame.rocks.count) return error.ArenaRockCountMismatch;
    for (rocks.angles[0..rocks.count], 0..) |entry, at| {
        const lane = wire.slots + at;
        const index: u16 = @intCast(frame.rocks.entries[at].resolve(all) orelse continue);
        const slot = &all.slots[index];
        slot.object.flags.disabled = entry == null;
        const facing = entry orelse {
            frame.rock_seen[at] = null;
            frame.rock_spin[at] = null;
            frame.tracks[lane] = .{};
            frame.easing[lane] = .{};
            continue;
        };
        const angles = math.angles(wire.unpackFacing(facing));
        const prior = frame.rock_seen[at];
        frame.rock_seen[at] = .{ .tick = tick, .angles = angles };
        if (prior == null or !slot.object.created) {
            game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = slot.drawn.position, .orientation = wire.unpackFacing(facing) });
            if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
            frame.tracks[lane] = .{};
            frame.easing[lane] = .{};
            continue;
        }
        frame.spinRock(at, index, prior.?, tick, angles);
        frame.correctRock(lane, index, facing, tick);
    }
}

/// Feeds the rock the rates the host was seen turning it by: with each rate already at its
/// settle target, `steer` holds it there, so both simulations turn the rock identically.
fn spinRock(frame: *FlightFrame, at: usize, index: u16, prior: RockPrior, tick: i32, angles: Vector) void {
    const flight = frame.drawn.objects.slots[index].flight orelse return;
    const steps: f32 = @floatFromInt(@max(1, @divTrunc(tick -% prior.tick, game.gameobj.ticks_per_step)));
    const seen: Vector = .{
        angleDelta(prior.angles[0], angles[0]) / steps,
        angleDelta(prior.angles[1], angles[1]) / steps,
        angleDelta(prior.angles[2], angles[2]) / steps,
    };
    // The wire quantizes each axis, so the rate is filtered toward what the sceneries keep saying.
    const held = if (frame.rock_spin[at]) |kept| kept + (seen - kept) * @as(Vector, @splat(0.25)) else seen;
    frame.rock_spin[at] = held;
    const full: Vector = .{ flight.pitch_rate, flight.yaw_rate, flight.roll_rate };
    const object = &frame.drawn.objects.slots[index].object;
    const reach = held * @as(Vector, @splat(motion.turn_slowing_at_rest)) / full;
    if (@abs(reach[0]) > 1 or @abs(reach[1]) > 1 or @abs(reach[2]) > 1) return;
    object.pitch_input = reach[0];
    object.yaw_input = reach[1];
    object.roll_input = reach[2];
    object.pitch_rate = held[0];
    object.yaw_rate = held[1];
    object.roll_rate = held[2];
    object.throttle = 0;
}

/// Measures the simulated rock against the host's facing at the same tick and eases the
/// difference in like a ship's correction; a torn-off rock is placed exactly and starts over.
fn correctRock(frame: *FlightFrame, lane: usize, index: u16, facing: wire.Facing, tick: i32) void {
    const math = engine.surrender.math;
    const all = frame.drawn.objects;
    const track = &frame.tracks[lane];
    const entry = track.byTick(tick) orelse track.byTick(tick - game.gameobj.ticks_per_step) orelse return;
    const turn = math.angles(math.product(math.transpose(entry.orientation), wire.unpackFacing(facing)));
    if (@reduce(.Max, @abs(turn)) > std.math.pi * 0.5) {
        const slot = &all.slots[index];
        game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = slot.drawn.position, .orientation = wire.unpackFacing(facing) });
        if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
        frame.tracks[lane] = .{};
        frame.easing[lane] = .{};
        return;
    }
    frame.easing[lane] = .{ .angles = turn };
}

fn presentWeapons(frame: *FlightFrame, status: ?wire.ordnance.Status) void {
    const all = frame.drawn.objects;
    const slot = &all.slots[all.player];
    const weapons = &all.player_states[all.player].weapons;
    const prior = weapons.ring;
    if (status) |shown| {
        shown.panels.apply(slot);
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
        .presentation_only = true,
        .spin_outs = &frame.spin_outs,
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
        .gun_effects = .{ .context = frame, .send = noteOwnShot },
    };
}

/// Records the client's own predicted muzzle shots as they leave (`guns.shoot` on this world),
/// so the host's authoritative shot for each can end its predicted bolt instead of doubling it.
fn noteOwnShot(context: *anyopaque, effect: game.guns.FlightEffect) void {
    const frame: *FlightFrame = @ptrCast(@alignCast(context));
    const shot = switch (effect) {
        .shot => |shot| shot,
        else => return,
    };
    if (shot.owner != frame.drawn.objects.player) return;
    const queue = &frame.own_muzzles;
    if (queue.count == queue.entries.len) {
        queue.next = @intCast((queue.next + 1) % queue.entries.len);
        queue.count -= 1;
    }
    queue.entries[(queue.next + queue.count) % queue.entries.len] = .{ .index = shot.index, .fired_at = shot.fired_at };
    queue.count += 1;
}

/// Ends the oldest predicted own bolt still flying, which the client's lead over the host makes
/// the one the arriving shot speaks for; false when nothing was predicted for it.
fn endPredictedShot(frame: *FlightFrame) bool {
    const queue = &frame.own_muzzles;
    if (queue.count == 0) return false;
    const entry = queue.entries[queue.next];
    queue.next = @intCast((queue.next + 1) % queue.entries.len);
    queue.count -= 1;
    game.guns.endReplica(frame.world(), entry.index, entry.fired_at);
    return true;
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
                // The host's own shot takes the place of the predicted bolt that already spoke
                // for it at the muzzle (Overwatch GDC 2017).
                const spoke = shot.owner == scene.objects.player and frame.endPredictedShot();
                game.guns.showShot(scene, shot, !spoke);
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

/// Keep the host's snapshots authoritative while the client runs the same simulation single
/// player does: each frame's real time owes the ticks the world has not run, the drawing frames
/// what has run by the share of the step and the tick the frame catches it at, whatever the
/// display's refresh rate, and each snapshot corrects what the simulation could not know
/// (`apply`), as the original's mission loop ran on every player's machine (`frame_controls`,
/// `0x00414060`). The simulation decides nothing (`World.presentation_only`).
pub fn present(frame: *FlightFrame, snapshot: *const wire.Snapshot, admission: wire.Admission, local: *game.create.Objects, types: game.create.Types, now: i64) !void {
    if (frame.tick == null or snapshot.tick != frame.tick.?)
        try frame.apply(snapshot, admission, local, types);
    const clock = &frame.drawn.clock;
    if (!frame.running) {
        // The clock starts at the host's, so the snapshots and the host's shots share its ticks.
        clock.start(@as(u64, @intCast(@max(now, 0))) / tick_us);
        clock.mission_ticks = snapshot.clock;
        clock.frameReset();
        frame.skew_us = 0;
        frame.owed_us = 0;
        frame.lead = null;
        frame.margin = null;
        frame.offsets = @splat(.{});
        frame.own_muzzles = .{};
        frame.frame_us = now;
        for (&frame.tracks) |*track| track.* = .{};
        frame.easing = @splat(.{});
        frame.running = true;
        return;
    }
    const most = @as(f32, @floatFromInt(@max(now - frame.frame_us, 0))) * skew_rate;
    frame.frame_us = now;
    const slew = std.math.clamp(frame.owed_us, -most, most);
    frame.owed_us -= slew;
    frame.skew_us += @intFromFloat(slew);
    if (frame.lead) |*lead| lead.* += slew / @as(f32, @floatFromInt(tick_us));
    if (frame.margin) |*margin| margin.* += slew / @as(f32, @floatFromInt(tick_us));
    clock.advanceToFine(@intCast(@max(now + frame.skew_us, 0)), tick_us);
    const scene = frame.world();
    const all = scene.objects;
    if (all.playerBinding(admission.slot)) |binding|
        _ = all.submitPlayerCommand(binding, .{ .flight = frame.command, .match_speed = frame.own_match });
    var stepped = false;
    while (clock.nextTick(&frame.devices, scene)) |stepped_tick| {
        // The client's own guns fire through the single player path each tick (Overwatch GDC
        // 2017): the muzzle speaks at once, and the host's word on the shot replaces the bolt.
        engine.input.predictOwnGuns(scene, admission.slot, frame.own_trigger);
        game.guns.step(scene, clock, admission.slot);
        if (stepped_tick) {
            frame.ease();
            frame.record();
            stepped = true;
        }
    }
    // The MATCH SPEED press rides the command until a step has flown it, as a press lasts
    // until the key is read.
    if (stepped) frame.own_match = false;
    clock.frameBegin();
    clock.drawBegin();
    const cockpit = game.camera.Cockpit;
    frame.drawn.shake = @max(@min(frame.drawn.shake, cockpit.shake_most) - cockpit.shake_fade * @as(f32, @floatFromInt(clock.frame_duration)), 0);
    if (snapshot.ships[admission.slot]) |ship| if (ship.at_wall) {
        frame.drawn.shake = 1;
    };
    if (scene.flash) |flash| flash.countDown(clock.frame_duration);
    if (scene.sparks) |sparks| sparks.frame(clock);
    if (scene.explosions) |effects| effects.frame(scene);
    if (scene.particles) |particles| particles.frame(clock);
    if (scene.shockwaves) |rings| rings.frame(scene);
    for (all.slots[0..wire.slots]) |*slot| {
        if (slot.cloak != null) game.cloak.frame(slot, clock.frame_start);
    }
    game.main.frameDrawn(all, .of(clock, true, .together), clock.frame_start);
    frame.drawOffsets(@as(f32, @floatFromInt(clock.frame_duration)) / game.main.ticks_per_second);
    frame.respawns.frame(all, &frame.drawn.portals, clock.mission_ticks, clock.past_tick);
    game.guns.frameReplicas(scene);
    frame.drawn.display.followTarget(all, true);
    frame.drawn.display.zoomRadar(scene);
    frame.drawn.display.finishGameFrame(scene);
    frame.drawn.display.messages.expire(clock.frame_start);
}

const tick_us: u64 = std.time.us_per_s / game.main.ticks_per_second;
/// How much faster or slower than real time the mission clock may run while it takes in a skew.
const skew_rate = 0.05;
/// The lead over the host's clock the client's snapshots should arrive at, in ticks.
const target_lead = 2 * game.gameobj.ticks_per_step;
/// A lead or lag beyond this many ticks restarts the clock at the host's.
const lost_lead = 50;
/// The share of a ship's outstanding correction each step takes in: a correction spreads over
/// about a quarter second, a slight change of course the drawing blends like any other step.
const ease_share = 0.15;

/// The part of a correction a ship has not taken in yet.
const Ease = struct {
    position: Vector = @splat(0),
    angles: Vector = @splat(0),
    velocity: Vector = @splat(0),
};

/// The place the local simulation reached at each step for one ship, newest last.
const Track = struct {
    const length = 64;
    const Entry = struct {
        /// `mission_ticks` of the step.
        tick: i32,
        /// The input the step flew the pilot's own ship by.
        position: Vector,
        orientation: engine.surrender.math.Matrix,
        velocity: Vector,
    };
    entries: [length]Entry = undefined,
    count: u8 = 0,
    newest: u8 = length - 1,

    fn push(track: *Track, entry: Entry) void {
        track.newest = (track.newest + 1) % length;
        track.entries[track.newest] = entry;
        track.count = @min(track.count + 1, length);
    }

    /// The entries oldest first.
    fn at(track: *Track, age: usize) *Entry {
        return &track.entries[(track.newest + length + 1 - track.count + age) % length];
    }

    fn byTick(track: *Track, tick: i32) ?*Entry {
        for (0..track.count) |age| if (track.at(age).tick == tick) return track.at(age);
        return null;
    }

    /// Moves `from` and every later step, as the correction moved the ship.
    fn shift(track: *Track, from: i32, position: Vector, velocity: Vector, turn: engine.surrender.math.Matrix) void {
        const math = engine.surrender.math;
        for (0..track.count) |age| {
            const entry = track.at(age);
            if (entry.tick -% from < 0) continue;
            entry.position += position;
            entry.velocity += velocity;
            entry.orientation = math.product(entry.orientation, turn);
        }
    }
};

const Vector = engine.surrender.math.Vector;
const motion = game.motion;

/// The host's per-step echo of every pilot's command, newest last (Rocket League GDC 2018).
const CommandRing = struct {
    const depth = 32;

    entries: [depth]wire.Commands = undefined,
    count: u8 = 0,
    newest: u8 = depth - 1,

    fn push(ring: *CommandRing, entry: wire.Commands) void {
        if (ring.count > 0 and ring.entries[ring.newest].tick == entry.tick) {
            ring.entries[ring.newest] = entry;
            return;
        }
        ring.newest = (ring.newest + 1) % depth;
        ring.entries[ring.newest] = entry;
        ring.count = @min(ring.count + 1, depth);
    }

    /// The command the pilot of `slot` held at `tick`: the newest echo at or before it.
    fn held(ring: *const CommandRing, slot: usize, tick: i32) ?engine.input.flight.Command {
        for (0..ring.count) |age| {
            const entry = &ring.entries[(ring.newest + depth - age) % depth];
            if (entry.tick > tick) continue;
            return if (entry.carried >> @intCast(slot) & 1 != 0) entry.held[slot] else null;
        }
        return null;
    }
};

/// Takes the host's per-step echo of the pilots' commands: the simulation flies the other
/// pilots' ships by them through the order the host flies them with (Rocket League GDC 2018).
pub fn noteCommands(frame: *FlightFrame, entry: wire.Commands) void {
    frame.commands.push(entry);
    const all = frame.drawn.objects;
    for (0..wire.slots) |slot| {
        const index: u16 = @intCast(slot);
        if (index == all.player) continue;
        const binding = all.playerBinding(index) orelse continue;
        const command = frame.commands.held(slot, frame.drawn.clock.mission_ticks) orelse continue;
        _ = all.submitPlayerCommand(binding, .{ .flight = command });
    }
}

pub const Flown = struct { tick: i32, command: engine.input.flight.Command };

/// A rock's last two sceneries measure the turn it carried between them.
const RockPrior = struct { tick: i32, angles: Vector };

/// The object slot a lane tracks: a pilot's slot, or the rock at that place in the arena's list.
fn laneSlot(frame: *const FlightFrame, lane: usize) ?u16 {
    if (lane < wire.slots) return @intCast(lane);
    const rock = lane - wire.slots;
    if (rock >= frame.rocks.count) return null;
    return @intCast(frame.rocks.entries[rock].resolve(frame.drawn.objects) orelse return null);
}

fn record(frame: *FlightFrame) void {
    const all = frame.drawn.objects;
    frame.flown = .{ .tick = frame.drawn.clock.mission_ticks, .command = frame.command };
    for (0..lanes) |lane| {
        const index = frame.laneSlot(lane) orelse {
            frame.tracks[lane] = .{};
            continue;
        };
        const slot = &all.slots[index];
        if (!slot.object.created) {
            frame.tracks[lane] = .{};
            continue;
        }
        frame.tracks[lane].push(.{
            .tick = frame.drawn.clock.mission_ticks,
            .position = slot.object.root.next_position.vector(),
            .orientation = slot.object.root.next_orientation,
            .velocity = slot.object.velocity.vector(),
        });
    }
}

/// Measures the lead the snapshot arrived at and owes the clock the difference from the target.
/// A clock lost from the host's starts over at it.
fn keepClock(frame: *FlightFrame, snapshot: *const wire.Snapshot) void {
    if (!frame.running) return;
    const clock = &frame.drawn.clock;
    const lead = @as(f32, @floatFromInt(clock.mission_ticks -% snapshot.clock)) + clock.past_tick;
    if (@abs(lead) > lost_lead) {
        frame.running = false;
        return;
    }
    const kept = if (frame.lead) |held| if (lead < held) lead else held + (lead - held) * 0.02 else lead;
    frame.lead = kept;
    // The host's margin of the inputs steers the clock once it flows; without a fresh report
    // for a while the measured lead takes over again, so a lost stream never strands the clock.
    const stale = frame.margin != null and clock.mission_ticks -% frame.margin_tick > lost_lead;
    if (frame.margin == null or stale) frame.owed_us = (target_lead - kept) * @as(f32, @floatFromInt(tick_us));
}

fn velocityOf(slot: *const game.create.Slot, ship: wire.Ship, orientation: engine.surrender.math.Matrix) Vector {
    const flight_model = slot.flight orelse return engine.surrender.math.forward(orientation) * @as(Vector, @splat(ship.speed));
    return .{
        wire.dequantizeVelocity(ship.velocity[0], flight_model.max_speed),
        wire.dequantizeVelocity(ship.velocity[1], flight_model.max_speed),
        wire.dequantizeVelocity(ship.velocity[2], flight_model.max_speed),
    };
}

/// Measures how far a ship the simulation carries on stood from the host's place at the same
/// moment, the step at the snapshot's tick. The host flies the pilot's own inputs at the ticks
/// the client flew them, so on its own ship the difference is only what neither predicted. The
/// difference is taken in over the next steps (`ease`), so what no one could predict, a
/// collision or a hit, bends the course rather than moving the ship. Another pilot's ship beyond
/// three steps of its flight from the host's place is placed where that place has reached by
/// now.
fn correct(frame: *FlightFrame, index: u16, ship: wire.Ship, own: bool, snapshot: *const wire.Snapshot) void {
    // The pilot's own ship takes the host's state from `reconcile`.
    if (own) return;
    const math = engine.surrender.math;
    const slot = &frame.drawn.objects.slots[index];
    const track = &frame.tracks[index];
    const orientation = ship.orientationMatrix();
    const velocity = velocityOf(slot, ship, orientation);
    const found = track.byTick(snapshot.clock);
    if (found) |entry| {
        const travel = math.length(entry.velocity);
        const reach = travel * 3 + 25;
        const apart = ship.position - entry.position;
        if (math.dot(apart, apart) <= reach * reach) {
            // With the host's echoed commands the ship is flown back from the host's place
            // rather than eased toward it (Rocket League GDC 2018); the drawn ship holds its
            // place while the difference fades (Fiedler, "Networked Physics").
            if (frame.commands.held(index, snapshot.clock) != null) {
                frame.resimulate(index, ship, snapshot);
                return;
            }
            frame.easing[index] = .{
                .position = apart,
                .angles = math.angles(math.product(math.transpose(entry.orientation), orientation)),
                .velocity = velocity - entry.velocity,
            };
            return;
        }
    } else if (track.count < Track.length) return;
    const clock = &frame.drawn.clock;
    const steps: f32 = @floatFromInt(@divTrunc((clock.mission_ticks - @as(i32, @intCast(clock.simulation_counter))) -% snapshot.clock, game.gameobj.ticks_per_step));
    game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = ship.position + velocity * @as(Vector, @splat(steps)), .orientation = orientation });
    slot.object.velocity = .of(velocity);
    track.* = .{};
    frame.easing[index] = .{};
}

/// Rewinds another pilot's ship to the host's state at the snapshot's tick and flies the steps
/// since by the host's echoed commands, through the code every ship flies with (Rocket League
/// GDC 2018). The drawn ship keeps its place; the difference goes to its offset, which fades
/// (Fiedler, "Networked Physics").
fn resimulate(frame: *FlightFrame, index: u16, ship: wire.Ship, snapshot: *const wire.Snapshot) void {
    const math = engine.surrender.math;
    const all = frame.drawn.objects;
    const slot = &all.slots[index];
    const clock = &frame.drawn.clock;
    const orientation = ship.orientationMatrix();
    const velocity = velocityOf(slot, ship, orientation);
    const before = motion.Kinematics.of(&slot.object);
    const seen = math.product(before.orientation, frame.offsets[index].turn);
    game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = ship.position, .orientation = orientation });
    slot.object.velocity = .of(velocity);
    slot.object.speed = ship.speed;
    slot.object.pitch_rate = wire.dequantizeRate(ship.rates[0]);
    slot.object.yaw_rate = wire.dequantizeRate(ship.rates[1]);
    slot.object.roll_rate = wire.dequantizeRate(ship.rates[2]);
    const scene = frame.world();
    var tick = snapshot.clock + game.gameobj.ticks_per_step;
    while (clock.mission_ticks -% tick >= 0) : (tick += game.gameobj.ticks_per_step) {
        engine.input.stepShip(scene, index, frame.commands.held(index, tick), game.gameobj.ticks_per_step);
    }
    const after = &slot.object.root;
    frame.offsets[index].position += before.position - after.next_position.vector();
    frame.offsets[index].turn = math.product(math.transpose(after.next_orientation), seen);
    frame.tracks[index] = .{};
    frame.easing[index] = .{};
}

/// The margin of the pilot's inputs the host should hold, in ticks: one step absorbs the jitter
/// of their arrival and adds the least delay (Overwatch GDC 2017).
const target_margin: f32 = game.gameobj.ticks_per_step;
/// The time the drawn offset of the pilot's own ship takes to fall to about a third.
const offset_fade_s = 0.1;

/// Takes up the host's state of the pilot's own ship at `own.tick` and flies it again through
/// `replay`, the steps the pilot flew since, by the code single player flies it with
/// (`engine.input.stepShip`), so the ship stands where the host will have it once those inputs
/// arrive (Overwatch GDC 2017; Rocket League GDC 2018). The difference from where it stood moves
/// to the drawn offset (`own_offset`), and the host's margin of the inputs steers the clock.
pub fn reconcile(frame: *FlightFrame, own: wire.OwnFlight, replay: []const wire.Flown, index: u16) void {
    if (!frame.running) return;
    const math = engine.surrender.math;
    const all = frame.drawn.objects;
    const slot = &all.slots[index];
    const clock = &frame.drawn.clock;
    if (!slot.object.created or slot.combat == null) return;
    const now = clock.mission_ticks;
    // A state from ahead of the simulation is taken up once the clock reaches it.
    if (now -% own.tick < 0) return;
    const before = motion.Kinematics.of(&slot.object);
    const seen = math.product(before.orientation, frame.offsets[index].turn);
    own.kinematics.put(&slot.object);
    all.player_states[index].controls = own.controls;
    const scene = frame.world();
    var tick = own.tick + game.gameobj.ticks_per_step;
    var flown: usize = 0;
    var command: ?engine.input.flight.Command = null;
    while (now -% tick >= 0) : (tick += game.gameobj.ticks_per_step) {
        while (flown < replay.len and replay[flown].tick -% tick <= 0) : (flown += 1) command = replay[flown].command;
        engine.input.stepShip(scene, index, command, game.gameobj.ticks_per_step);
    }
    const after = &slot.object.root;
    frame.offsets[index].position += before.position - after.next_position.vector();
    frame.offsets[index].turn = math.product(math.transpose(after.next_orientation), seen);
    frame.tracks[index] = .{};
    frame.easing[index] = .{};
    const margin: f32 = @floatFromInt(own.margin);
    const kept = if (frame.margin) |held| if (margin < held) margin else held + (margin - held) * 0.05 else margin;
    frame.margin = kept;
    frame.margin_tick = own.tick;
    frame.owed_us = (target_margin - kept) * @as(f32, @floatFromInt(tick_us));
}

/// Draws each ship by its offset from where its simulation flies it, then lets the offset fade
/// by `seconds`: a correction never moves a drawn ship at once, the pilot's own ship and the
/// camera least of all (Fiedler, "Networked Physics").
fn drawOffsets(frame: *FlightFrame, seconds: f32) void {
    const math = engine.surrender.math;
    for (frame.drawn.objects.slots[0..wire.slots], &frame.offsets) |*slot, *offset| {
        if (!slot.object.created) {
            offset.* = .{};
            continue;
        }
        slot.drawn.position += offset.position;
        slot.drawn.orientation = math.product(slot.drawn.orientation, offset.turn);
        if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
        const keep = @exp(-seconds / offset_fade_s);
        offset.position *= @splat(keep);
        offset.turn = math.fromAngleVector(math.angles(offset.turn) * @as(Vector, @splat(keep)));
    }
}

/// Takes in a share of every ship's outstanding correction after a step, and moves the steps
/// already recorded with it, so the next snapshot measures only what is still left.
fn ease(frame: *FlightFrame) void {
    const math = engine.surrender.math;
    const share: Vector = @splat(ease_share);
    for (&frame.easing, &frame.tracks, 0..) |*left, *track, lane| {
        const index = frame.laneSlot(lane) orelse {
            left.* = .{};
            continue;
        };
        const slot = &frame.drawn.objects.slots[index];
        if (!slot.object.created) {
            left.* = .{};
            continue;
        }
        const position = left.position * share;
        const velocity = left.velocity * share;
        const turn = math.fromAngleVector(left.angles * share);
        left.position -= position;
        left.velocity -= velocity;
        left.angles -= left.angles * share;
        const root = &slot.object.root;
        root.next_position = .of(root.next_position.vector() + position);
        root.next_orientation = math.product(root.next_orientation, turn);
        slot.object.velocity = .of(slot.object.velocity.vector() + velocity);
        if (track.count > 0) track.shift(track.at(0).tick, position, velocity, turn);
    }
}

pub fn apply(frame: *FlightFrame, snapshot: *const wire.Snapshot, admission: wire.Admission, local: *game.create.Objects, types: game.create.Types) !void {
    if (frame.tick == snapshot.tick) return;
    frame.keepClock(snapshot);
    frame.applied_clock = snapshot.clock;
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
    for (snapshot.ships, 0..) |entry, offset| {
        const index: u16 = @intCast(offset);
        const prior = all.playerBinding(index);
        if (prior != null and (entry == null or prior.?.participant.generation != entry.?.generation or frame.host_ship_reuse[index] != entry.?.reuse or all.slots[index].object.type != entry.?.kind())) {
            game.create.resetSlot(.of(scene), index);
            all.player_states[index] = .{ .membership = .vacant };
        }
        const ship = entry orelse {
            frame.respawns.forget(index);
            frame.spin_outs.forget(index);
            if (index == admission.slot) frame.death_view = null;
            continue;
        };
        var made = false;
        if (!all.slots[index].object.created) {
            made = true;
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
            } else {
                // Another pilot's ship flies by the host's echo of their command, under the
                // order the host flies it with (Rocket League GDC 2018).
                _ = try game.aigeneric.push(.of(scene), index, .multiplayer_control, .none);
                if (snapshot.mission == null) all.slots[index].object.side = .hostile;
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
        const own = index == admission.slot;
        const carried_on = frame.running and !made;
        if (carried_on) frame.correct(index, ship, own, snapshot) else {
            const orientation = ship.orientationMatrix();
            game.objects.setPlace(&slot.object, &slot.drawn, .{ .position = ship.position, .orientation = orientation });
            slot.object.velocity = .of(velocityOf(slot, ship, orientation));
            frame.tracks[index] = .{};
            frame.easing[index] = .{};
        }
        // order_eject breaks off the cockpit and plays EJECT01 from the abandoned fighter (0x00415808).
        if (ejected) game.aieject.playSeparation(scene, index);
        if (frame.respawns.note(index, snapshot.clock, ship.respawn) and ship.respawn + game.gameobj.ticks_per_step >= game.deathmatch.respawn.duration)
            game.deathmatch.respawn.sound(scene, index);
        // The pilot's own ship flies by the local simulation's controls; another ship's are the
        // last its pilot gave the host. Where the host's command echo carries the ship, its
        // steering comes from that instead, at full precision (Rocket League GDC 2018).
        const echoed = carried_on and !own and frame.commands.held(index, snapshot.clock) != null;
        if (!carried_on or !own) {
            slot.object.speed = ship.speed;
            slot.object.speed_factor = wire.dequantizeShare(ship.speed_factor);
            if (!echoed) {
                slot.object.pitch_rate = wire.dequantizeRate(ship.rates[0]);
                slot.object.yaw_rate = wire.dequantizeRate(ship.rates[1]);
                slot.object.roll_rate = wire.dequantizeRate(ship.rates[2]);
                slot.object.pitch_input = wire.dequantizeInput(ship.inputs[0]);
                slot.object.yaw_input = wire.dequantizeInput(ship.inputs[1]);
                slot.object.roll_input = wire.dequantizeInput(ship.inputs[2]);
                slot.object.lateral_input = @floatFromInt(ship.lateral);
                slot.object.throttle = ship.throttle;
                slot.object.last_throttle = ship.throttle;
                slot.object.afterburner = ship.afterburner;
                slot.object.reverse_thrust = ship.reverse_thrust;
            }
        }
        slot.object.engines_intact = wire.dequantizeShare(ship.engines);
        if (!carried_on or !own) slot.object.afterburner_fuel = ship.fuel;
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
        frame.spin_outs.note(index, snapshot.clock, if (ship.dying) ship.spin else null);
        if (snapshot.scenario != null) slot.object.flags.targetable = ship.targetable;
        if (!ship.dying and index == admission.slot) frame.death_view = null;
        all.player_states[index].membership.joined.kills.count = ship.kills;
        all.player_states[index].membership.joined.deaths = ship.deaths;
        all.player_states[index].membership.joined.ping_ms = ship.ping_ms;
        const cloaking = if (slot.cloak) |effect| !effect.going else false;
        if (ship.cloaked != cloaking) {
            if (ship.cloaked) game.cloak.beginPowerUp(scene, index) else game.cloak.uncloak(scene, index);
        }
    }
    all.arena_scores = if (snapshot.teams) |teams| .{ .teams = teams } else .free_for_all;
    const local_ship = snapshot.ships[admission.slot];
    const sounding = if (local_ship) |ship| !ship.pod and !ship.dying and !ship.engine_waiting else false;
    frame.setEngineShip(scene, if (sounding) .of(all, admission.slot) else null);
    const viewing = &frame.drawn.player.viewing;
    viewing.last = viewing.view;
    viewing.view = if (frame.director != null)
        .director
    else if (frame.respawns.running(admission.slot, frame.drawn.clock.mission_ticks))
        game.camera.deathmatch_respawn_view
    else if (frame.death_view) |death|
        (if (death.watching_from == null) .pull_back else .watch)
    else if (frame.eject_view != null)
        .eject
    else
        .cockpit;
    if (snapshot.blast) |blast| frame.presentBlast(scene, blast);
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
    try std.testing.expect(engine.input.setPilotTarget(display, all, 0, 1, game.aigeneric.Target.whole, true));
    try std.testing.expectEqual(.opening, display.windows.status.get(.target).phase);

    // A duplicate view while paused must leave the window's phase alone.
    try frame.apply(&snapshot, admission, local, no_models);
    try std.testing.expectEqual(0, display.windows.status.get(.target).progress);
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

test "the pilot's own ship flies the held command and takes up the host's state without a jump" {
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
    frame.command = .{ .steering = .{ .axes = .{ 0, 0, 0 } }, .throttle = .{ .axis = 1.0 } };
    var now: i64 = 0;
    try frame.present(&snapshot, admission, local, no_models, now);
    const slot = &all.slots[0];
    try std.testing.expect(slot.object.created);

    // Frames pass with no new snapshot: the held throttle carries the ship by itself.
    var carried = false;
    for (0..120) |_| {
        now += 5 * tick_us;
        try frame.present(&snapshot, admission, local, no_models, now);
        const place = slot.drawn.position;
        if (@abs(place[0]) + @abs(place[1]) + @abs(place[2]) > 10) {
            carried = true;
            break;
        }
    }
    try std.testing.expect(carried);

    // The host's state of a step already flown, with the steps since flown again over it,
    // stands where the simulation stands.
    const math = engine.surrender.math;
    const host_tick = frame.drawn.clock.mission_ticks;
    var host = motion.Kinematics.of(&slot.object);
    const controls = all.player_states[0].controls;
    var replay: [16]wire.Flown = undefined;
    var flown: usize = 0;
    for (0..8) |_| {
        now += 5 * tick_us;
        try frame.present(&snapshot, admission, local, no_models, now);
        const step = frame.flown.?;
        if (flown == 0 or replay[flown - 1].tick != step.tick) {
            replay[flown] = .{ .tick = step.tick, .command = step.command };
            flown += 1;
        }
    }
    const travel = math.length(slot.object.velocity.vector());
    try std.testing.expect(travel > 1);
    frame.reconcile(.{ .tick = host_tick, .margin = 4, .kinematics = host, .controls = controls }, replay[0..flown], 0);
    try std.testing.expect(math.length(frame.offsets[0].position) < 0.01);

    // A host state elsewhere moves the simulation at once but never the drawn ship: the
    // offset carries the difference and fades over the frames that follow.
    host.position[0] += travel * 2;
    const held = math.length(frame.offsets[0].position);
    frame.reconcile(.{ .tick = host_tick, .margin = 4, .kinematics = host, .controls = controls }, replay[0..flown], 0);
    const owed = math.length(frame.offsets[0].position);
    try std.testing.expect(owed > travel * 2 - 0.01 - held);
    for (0..40) |_| {
        now += 5 * tick_us;
        try frame.present(&snapshot, admission, local, no_models, now);
    }
    try std.testing.expect(math.length(frame.offsets[0].position) < owed / 10);
}

test "a remote ship sweeps smoothly under the client's own simulation" {
    const gpa = std.testing.allocator;
    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    const no_models = game.create.testing.no_models;
    const admission: wire.Admission = .{ .slot = 0, .generation = 1 };
    var snapshot: wire.Snapshot = .{ .tick = 1, .ships = @splat(null) };
    snapshot.ships[0] = .{ .generation = 1, .position = @splat(0) };
    snapshot.ships[1] = .{ .generation = 2, .position = @splat(0), .velocity = .{ 0, 0, 25 } };
    var now: i64 = 0;
    try frame.present(&snapshot, admission, local, no_models, now);
    const remote = &frame.drawn.objects.slots[1];
    var previous = remote.drawn.position[2];
    var frames: usize = 0;
    var largest_frame: f32 = 0;
    const frame_us = tick_us * 5 / 3;
    // A ship's velocity is the distance it crosses a step (`motion.move`), so the snapshots
    // carry the seeded pace forward, and the wire's quantization of it round-trips.
    const pace = wire.dequantizeVelocity(25, if (remote.flight) |flight| flight.max_speed else 320);
    for (1..25) |round| {
        // A snapshot every step of forty milliseconds, frames every sixteen and two thirds as
        // a display at sixty a second shows them.
        snapshot.tick += 1;
        // The host's ship crosses exactly what its velocity says, drag and all, so the
        // snapshot's place is the track the simulation itself has reached.
        // It reports from the lead behind, where the client's own track has been.
        const behind = if (frame.flown) |flown| frame.tracks[1].byTick(flown.tick - target_lead) else null;
        if (behind) |entry| {
            snapshot.clock = entry.tick;
            snapshot.ships[1].?.position[2] = entry.position[2];
            snapshot.ships[1].?.velocity = .{ 0, 0, wire.quantizeVelocity(entry.velocity[2], if (remote.flight) |flight| flight.max_speed else 320) };
        }
        for (0..6) |_| {
            now += frame_us;
            try frame.present(&snapshot, admission, local, no_models, now);
            const at = remote.drawn.position[2];
            // The first steps only commit the track the simulation runs on, before the
            // frames between the commits carry the drawing; measure once they do.
            if (round > 3) {
                largest_frame = @max(largest_frame, @abs(at - previous));
                frames += 1;
            }
            previous = at;
        }
    }
    // A frame at sixty a second carries the drawing under two fifths of a step; a snapped or
    // frozen track moves in whole steps at once.
    try std.testing.expect(largest_frame < pace * 0.4);
    try std.testing.expect(frames > 100);
}

test "a rock the host carries turns by the rate two sceneries measure" {
    const gpa = std.testing.allocator;
    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    const no_models = game.create.testing.no_models;
    const admission: wire.Admission = .{ .slot = 0, .generation = 1 };
    var snapshot: wire.Snapshot = .{ .tick = 1, .ships = @splat(null) };
    snapshot.ships[0] = .{ .generation = 1, .position = @splat(0) };
    var now: i64 = 0;
    try frame.present(&snapshot, admission, local, no_models, now);
    // A slot past the pilots stands in for the rock, as the arena's rocks sit: never in the
    // snapshot's ships, only in the scenery.
    const all = frame.drawn.objects;
    all.count = @max(all.count, all.players + 1);
    _ = try game.create.createObject(
        all,
        &frame.tables,
        no_models,
        all.players,
        all.slots[0].object.type,
        0,
        @splat(0),
        &frame.random,
    );
    const rock_slot = all.players;
    frame.rocks.entries[0] = .of(all, rock_slot);
    frame.rocks.count = 1;
    const rock = &all.slots[rock_slot];
    const flight = rock.flight.?;
    // A slow spin, as the arena's `random_spin_slow` gives: small enough that the facings'
    // angles change by the turn itself each step, which is what the derivation reads.
    _ = flight;
    const turn: Vector = @splat(0.002);
    var facing = engine.surrender.math.identity;

    // The first scenery places the rock; the second pair measures its turn.
    var scenery: wire.Scenery = .{ .tick = 1, .scenario = .asteroid_field, .rocks = .{ .count = 1 } };
    var seen: usize = 0;
    while (seen < 4) : (seen += 1) {
        snapshot.tick += 1;
        snapshot.clock += game.gameobj.ticks_per_step;
        now += 5 * tick_us;
        try frame.present(&snapshot, admission, local, no_models, now);
        if (seen == 0) facing = engine.surrender.math.identity;
        facing = engine.surrender.math.product(facing, engine.surrender.math.fromAngleVector(turn));
        scenery.tick = snapshot.tick;
        scenery.rocks.angles[0] = wire.packFacing(facing);
        try frame.presentScenery(&scenery, no_models);
    }
    // The measured rate is the turn the host was seen applying each step, within what the
    // wire's ten-bit angles can say.
    try std.testing.expect(@abs(rock.object.pitch_rate - turn[0]) < 0.001);
    try std.testing.expect(@abs(rock.object.yaw_rate - turn[1]) < 0.001);
    try std.testing.expect(@abs(rock.object.roll_rate - turn[2]) < 0.001);

    // Flown on by the measured rate, the rock stands where the next scenery finds it, so the
    // correction eases in nearly nothing.
    const angles = engine.surrender.math.angles(engine.surrender.math.product(
        engine.surrender.math.transpose(rock.object.root.next_orientation),
        facing,
    ));
    try std.testing.expect(@reduce(.Max, @abs(angles)) < 0.2);
}

test "the host's own shot takes the place of the bolt the client spoke for it" {
    const gpa = std.testing.allocator;
    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    const no_models = game.create.testing.no_models;
    const admission: wire.Admission = .{ .slot = 0, .generation = 1 };
    var snapshot: wire.Snapshot = .{ .tick = 1, .ships = @splat(null) };
    snapshot.ships[0] = .{ .generation = 1, .position = @splat(0) };
    try frame.present(&snapshot, admission, local, no_models, 0);

    // A predicted muzzle shot is recorded as it leaves; the host's word on that shot ends it
    // instead of drawing a second bolt beside it (Overwatch GDC 2017).
    const sink = frame.world().gun_effects.?;
    sink.send(@ptrCast(frame), .{ .shot = .{
        .index = 3,
        .owner = 0,
        .kind = .laser_cannon,
        .fired_at = 100,
        .dies_at = 200,
        .origin = @splat(0),
        .velocity = @splat(1),
    } });
    sink.send(@ptrCast(frame), .{ .shot = .{
        .index = 4,
        .owner = 0,
        .kind = .laser_cannon,
        .fired_at = 104,
        .dies_at = 204,
        .origin = @splat(0),
        .velocity = @splat(1),
    } });
    try std.testing.expectEqual(@as(u8, 2), frame.own_muzzles.count);
    frame.presentCombat(&.{.{ .shot = .{
        .index = 30,
        .owner = 0,
        .kind = .laser_cannon,
        .fired_at = 96,
        .dies_at = 300,
        .origin = @splat(0),
        .velocity = @splat(1),
    } }});
    try std.testing.expectEqual(@as(u8, 1), frame.own_muzzles.count);
    // Another pilot's shot takes none of the client's predicted bolts.
    frame.presentCombat(&.{.{ .shot = .{
        .index = 31,
        .owner = 1,
        .kind = .laser_cannon,
        .fired_at = 108,
        .dies_at = 300,
        .origin = @splat(0),
        .velocity = @splat(1),
    } }});
    try std.testing.expectEqual(@as(u8, 1), frame.own_muzzles.count);
}

test "the host's echoed commands carry another pilot's ship and its correction never jumps" {
    const gpa = std.testing.allocator;
    var random: engine.random.Random = .{};
    const local = try game.create.Objects.create(gpa, &random);
    defer local.destroy();
    const tables = game.create.testing.tables();
    const frame = try create(gpa, local, &tables);
    defer frame.destroy();
    const no_models = game.create.testing.no_models;
    const admission: wire.Admission = .{ .slot = 0, .generation = 1 };
    var snapshot: wire.Snapshot = .{ .tick = 1, .ships = @splat(null) };
    snapshot.ships[0] = .{ .generation = 1, .position = @splat(0) };
    snapshot.ships[1] = .{ .generation = 2, .position = @splat(0) };
    var now: i64 = 0;
    try frame.present(&snapshot, admission, local, no_models, now);

    // The host's echo carries the other pilot's held turn at full precision.
    var commands: wire.Commands = .{ .tick = snapshot.clock, .carried = 0b0010 };
    commands.held[1].steering = .{ .axes = .{ 0, 0, 0.5 } };
    frame.noteCommands(commands);
    var turned = false;
    // Snapshots at twenty-five a second, frames at sixty: four rounds keep the clock's lead
    // well inside its bound while the echoed turn is flown.
    for (0..4) |_| {
        snapshot.tick += 1;
        snapshot.clock += game.gameobj.ticks_per_step;
        for (0..6) |_| {
            now += tick_us * 5 / 3;
            try frame.present(&snapshot, admission, local, no_models, now);
            if (@abs(frame.drawn.objects.slots[1].object.roll_rate) > 0.01) turned = true;
        }
    }
    try std.testing.expect(turned);

    // A snapshot far from the track rewinds and resimulates by those commands; the drawn ship
    // holds its place and the offset takes the difference (Rocket League GDC 2018).
    const remote = &frame.drawn.objects.slots[1];
    const drawn_before = remote.drawn.position;
    // The snapshot reports from behind, at a tick the tracks hold, its ship a little aside
    // from where the simulation stands there.
    snapshot.tick += 1;
    const behind = frame.tracks[1].byTick(frame.flown.?.tick - target_lead) orelse frame.tracks[1].at(0);
    snapshot.clock = behind.tick;
    snapshot.ships[1].?.position = behind.position + @as(Vector, @splat(12));
    now += tick_us * 5 / 3;
    try frame.present(&snapshot, admission, local, no_models, now);
    try std.testing.expect(engine.surrender.math.length(frame.offsets[1].position) > 15);
    // The drawn ship holds its place: the whole difference went to the fading offset.
    try std.testing.expect(engine.surrender.math.length(remote.drawn.position - drawn_before) < 1);
}
