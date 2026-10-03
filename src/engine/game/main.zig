//! `C:\lancer\game\main.cpp`: a mission's loop. `mission_run` (`0x00494040`) runs a game tick for
//! each tick of the timer and draws a frame with `mission_frame` (`0x004924B0`). **Unverified:**
//! the two lie after `language.cpp`'s code, where `main.cpp`'s begins; by what they do they are
//! this file's.
//!
//! Ported so far: the clocks and the pacing, the mission's start (`startMission`), how
//! `mission_frame` runs the mission's script, frames the objects, reads the controls, moves the
//! camera, plays the frame's sound and puts the scene together and draws it, the damaged ships'
//! smoke (`smoke`), the armour's conditions (`0x00492370`), the pause (`game_pause`) and the paused
//! frame (`pausedFrame`). Not yet: the rest of the effects and of what it adds to the scene.

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../input.zig");
const libcmt = @import("../libcmt.zig");
const mss = @import("../mss.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const backdrop = @import("backdrop.zig");
const environfx = @import("environfx.zig");
const wgate = @import("wgate.zig");
const camera = @import("camera.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const ailand = @import("ailand.zig");
const create = @import("create.zig");
const pilots = @import("pilots.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const launch = @import("launch.zig");
const cloak = @import("cloak.zig");
pub const lock = @import("main/lock.zig");
const missiles = @import("missiles.zig");
const explode = @import("explode.zig");
const friendly_fire = @import("friendly_fire.zig");
const particles = @import("particles.zig");
const shield = @import("shield.zig");
const erayfx = @import("erayfx.zig");
const tractor = @import("tractor.zig");
const airipper = @import("airipper.zig");
const jump = @import("jump.zig");
pub const flash = @import("main/flash.zig");
pub const scanner = @import("main/scanner.zig");
pub const cockpit = @import("main/cockpit.zig");
const shockwave = @import("shockwave.zig");
const sparks = @import("sparks.zig");
const bigfile = @import("bigfile.zig");
const hog_snd = @import("hog_snd.zig");
const hooks = @import("../hooks.zig");
const betty = hog_snd.betty;
const hud = @import("hud.zig");
const hudoptions = @import("hudoptions.zig");
const videoreports = @import("videoreports.zig");
const sound3d = @import("sound3d.zig");
const matmanager = @import("matmanager.zig");
const nebula = @import("nebula.zig");
const objects = @import("objects.zig");
const srofiles = @import("srofiles.zig");
const xtrabits = @import("xtrabits.zig");
const winmain = @import("winmain.zig");
const gameflow = @import("gameflow.zig");
const Loaded = @import("mission.zig").Loaded;

pub const smoke = @import("main/smoke.zig");

// --- The clocks and the loop ---------------------------------------------------------------

/// The play time `tick_timer` keeps (`play_time_ticks` to `play_time_hours`, `0x00565070` to
/// `0x00565076`). A second takes 101 ticks, as the roll below has it, so the play time runs a
/// hundredth slow.
pub const PlayTime = struct {
    ticks: u16 = 0,
    seconds: u16 = 0,
    minutes: u16 = 0,
    hours: u16 = 0,
};

/// How the mission is ending (`0x00588394`), which its end and the debriefing go by. Nothing ends a
/// mission while it is `playing`. An ejection is `ejecting` until the pilot's pod has drifted its
/// time (`order_eject`, `0x00415C50`), when the mission's odds (`SetRescueProbabilities`; by
/// default always picked up) settle it: the pilot killed, which counts as `destroyed`, picked up by
/// a nanny ship, or picked up by the enemy. The others are not known yet.
pub const Ending = enum(u8) {
    playing = 0,
    /// The player's ship destroyed, or the ejected pilot killed.
    destroyed = 1,
    /// The ejected pilot picked up by a nanny ship (type `0x18`).
    rescued = 2,
    /// The ejected pilot picked up by the enemy (type `0x46`).
    captured = 3,
    /// The mission left from the pause menu (LEAVE MISSION, `mission_paused_frame`, `0x00492149`).
    left = 4,
    /// The script rated the mission a total failure, which `mission_end_record` settles as the
    /// mission ends (`0x00475CE5`). **Not ported:** the mission's end
    /// ([#74](https://github.com/OpenReliant/openreliant/issues/74)).
    total_failure = 5,
    /// The player's ship sent home for destroying a friend (`0x00474B40`), which gives it Friendly
    /// Fire, order 117; its landing begins at once (`ailand`).
    friendly_fire = 6,
    /// **Unknown:** as `friendly_fire`, where the ship's `sent_home` is 3, which a multiplayer
    /// game's code sets.
    _unknown_7 = 7,
    ejecting = 8,
    _,

    /// Whether the player's ship is being sent home for its friendly fire (`friendly_fire.zig`),
    /// which lands it at once and plays no landing (`land_reliant_init`, `0x0040F5C0`).
    pub fn sentHome(ending: Ending) bool {
        return switch (ending) {
            .friendly_fire, ._unknown_7 => true,
            .playing, .destroyed, .rescued, .captured, .left, .total_failure, .ejecting, _ => false,
        };
    }
};

test "Ending.sentHome" {
    try std.testing.expect(Ending.friendly_fire.sentHome());
    try std.testing.expect(Ending._unknown_7.sentHome());
    try std.testing.expect(!Ending.playing.sentHome());
    try std.testing.expect(!Ending.ejecting.sentHome());
    try std.testing.expect(!@as(Ending, @enumFromInt(9)).sentHome());
}

/// What the mission's scene shows (`0x00587CD4`), which a mission's start sets to `everything`.
pub const Showing = enum(u8) {
    everything = 0,
    /// A launch's cutaway (`launch.reliant`), which leaves out the ship the player launches from
    /// (`input.Player.carrier`), its bay seen from within.
    launch = 2,
    /// A landing's cutaway, which the landing orders set (`0x0040EF55`, `0x0040F9A7`): the
    /// Reliant's disables every object but the ship and its carrier (`ailand`). `mission_frame`
    /// passes over the mission's events and `0x0045A570` while it is so.
    landing = 3,
    /// The end of the player's ejection (`aieject.pickUp`): only the pilot's pod and the ship in
    /// the cutaway slot, which picks it up or shoots it down. The pod bursts at once when it is
    /// destroyed, with neither the camera's watch nor the pilot counted killed on the way.
    ejection = 4,
    _,

    /// **Improvement:** what surrounds the camera as the scene shows it in `view`, for the reverb:
    /// a hangar while a launch's cutaway shows the bay from within, or the landing's is seen from
    /// within the launch tube the ship lands in (`camera.View.landing_tube`), and space otherwise.
    pub fn surroundings(showing: Showing, view: camera.View) mss.Surroundings {
        return switch (showing) {
            .launch => .hangar,
            .landing => if (view == .landing_tube) .hangar else .space,
            .everything, .ejection, _ => .space,
        };
    }
};

/// What the mission's scene shows, as the player's state has it: `Showing`, and the ship the
/// player launched from, which a launch's cutaway leaves out.
pub const Shown = struct {
    showing: Showing = .everything,
    carrier: ?u16 = null,

    pub fn of(player: *const input.Player) Shown {
        return .{ .showing = player.showing, .carrier = player.carrier };
    }

    /// Whether the scene leaves out the object in slot `index` of `all` (`mission_frame`,
    /// `0x00492CEF`): a launch's cutaway the ship the player launches from, and the end of the
    /// player's ejection all but the player's pod and the cutaway slot's ship.
    pub fn leavesOut(shown: Shown, all: *const create.Objects, index: u16) bool {
        return switch (shown.showing) {
            .launch => index == shown.carrier,
            .ejection => index != all.player and index != create.cutaway_slot,
            else => false,
        };
    }
};

/// The game's ticks a second: `tick_timer` (`0x004827C0`) runs every hundredth of a second.
pub const ticks_per_second = 100;

/// A mission's clocks, and the pacing they drive: the timer ticks 100 times a second, the loop
/// runs one game tick for each tick of the timer, and the simulation steps on every fourth.
///
/// **Improvement:** OpenReliant has no periodic timer. The platform's monotonic counter of
/// hundredths of a second stands in for the multimedia timer `timer_start` (`0x004A70F0`) sets up,
/// so the clocks advance at the same rate without a thread of their own and without the drift a
/// timer whose period the device rounds would bring.
pub const Clock = struct {
    /// `timer_ticks` (`0x005DB8E8`): every tick of the timer, the paused ones included.
    timer_ticks: u32 = 0,
    /// `game_ticks` (`0x00565064`): the timer's ticks, the paused ones aside, since the sound's
    /// start (`sound_init`). Only the timer moves it on, and nothing zeroes it (`start`).
    game_ticks: u32 = 0,
    /// `mission_ticks` (`0x00587CC4`): ticks `game_tick` has run, the paused ones aside.
    mission_ticks: i32 = 0,
    /// `paused_ticks` (`0x00587CB0`): ticks `game_tick` skipped while the game was paused.
    paused_ticks: u32 = 0,
    play: PlayTime = .{},
    /// `paused` (`0x0057E04C`), which stops the ticks and the script clock.
    paused: bool = false,
    /// `frame_start` (`0x005883B0`): `mission_ticks` when the current frame began.
    frame_start: i32 = 0,
    /// `frame_duration` (`0x00588330`): ticks between the previous frame and this one.
    frame_duration: i32 = 0,
    /// `simulation_counter` (`0x00588718`).
    simulation_counter: u32 = 0,
    /// `simulation_turn` (`0x00562FFC`): the object whose orientation `simulation_step`
    /// orthonormalizes this step (`nextTurn`).
    simulation_turn: u32 = 0,
    /// What the loop has already run game ticks for, which `mission_run` keeps to itself.
    ran_to: u32 = 0,
    /// Where the platform's count of hundredths stood at the last tick, in place of the timer.
    timer_at: u64 = 0,
    /// OpenReliant's: how far the platform's time has run past the last tick, as a share of a tick,
    /// which `stepFraction` draws between the ticks by.
    past_tick: f32 = 0,

    /// The mission's ticks as a count, none before it starts, which the camera times its views by
    /// (`camera.Camera.switched`).
    pub fn viewTime(clock: *const Clock) u32 {
        return @intCast(@max(clock.mission_ticks, 0));
    }

    /// Starts the clocks again from `now`, the platform's count of hundredths of a second. The
    /// mission's clocks start from zero, as `mission_run` zeroes `mission_ticks`, `frame_start`,
    /// `frame_duration` and the play time before it loops. The timer's own counts, `timer_ticks`
    /// and `game_ticks`, keep running, as the original's do from the sound's start (`sound_init`),
    /// so a fade the sound timed by them goes on (`hog_snd.Sound.timerTick`). The loop owes no
    /// ticks yet (`nextTick`).
    pub fn start(clock: *Clock, now: u64) void {
        const timer_ticks = clock.timer_ticks;
        const game_ticks = clock.game_ticks;
        clock.* = .{ .timer_ticks = timer_ticks, .game_ticks = game_ticks, .ran_to = game_ticks, .timer_at = now };
    }

    /// Runs the timer on to `now`, the platform's count of hundredths of a second. The ticks come
    /// from the difference between two counts, never from the length of a frame, so a frame that
    /// falls between two ticks loses nothing, a frame that spans several runs all of them, and the
    /// clocks keep to the platform's count however the frames fall.
    pub fn advanceTo(clock: *Clock, now: u64) void {
        const elapsed = now -% clock.timer_at;
        clock.timer_at = now;
        clock.advanceTimer(@truncate(elapsed));
    }

    /// `advanceTo`, from a finer count: the platform's time in units of which `per_tick` make a
    /// tick. What is left past the last tick is kept for drawing between the ticks.
    pub fn advanceToFine(clock: *Clock, now: u64, per_tick: u64) void {
        clock.advanceTo(now / per_tick);
        clock.past_tick = @as(f32, @floatFromInt(now % per_tick)) / @as(f32, @floatFromInt(per_tick));
    }

    /// Runs `ticks` ticks and takes `now` as where the platform's count has reached, for a
    /// screenshot, which takes a tick a frame so that every run settles alike.
    pub fn advanceBy(clock: *Clock, now: u64, ticks: u32) void {
        clock.timer_at = now;
        clock.past_tick = 0;
        clock.advanceTimer(ticks);
    }

    /// Runs the timer on for `ticks` hundredths of a second.
    pub fn advanceTimer(clock: *Clock, ticks: u32) void {
        for (0..ticks) |_| hog_snd.tickTimer(clock);
    }

    /// Runs the next game tick the loop owes, as `mission_run` (`0x00494040`) paces them: one for
    /// each tick of the timer since the last pass. Returns whether the simulation stepped, or null
    /// once the loop has caught up with the timer.
    pub fn nextTick(clock: *Clock, devices: *input.Devices, world: gameobj.World) ?bool {
        if (clock.ran_to == clock.game_ticks) return null;
        clock.ran_to +%= 1;
        return gameobj.gameTick(clock, devices, world);
    }

    /// Every tick the loop owes. Returns how many simulation steps ran.
    pub fn runTicks(clock: *Clock, devices: *input.Devices, world: gameobj.World) u32 {
        var steps: u32 = 0;
        while (clock.nextTick(devices, world)) |stepped| {
            if (stepped) steps += 1;
        }
        return steps;
    }

    /// `frame_begin` (`0x00491E00`): `frame_duration` becomes the ticks since `frame_start`, and
    /// `frame_start` becomes `mission_ticks`. Code that runs once a frame measures time with these.
    pub fn frameBegin(clock: *Clock) void {
        const began = clock.frame_start;
        clock.frame_start = clock.mission_ticks;
        clock.frame_duration = clock.mission_ticks -% began;
    }

    /// `frame_reset` (`0x00491DE0`).
    pub fn frameReset(clock: *Clock) void {
        clock.frame_start = clock.mission_ticks;
        clock.frame_duration = 0;
    }

    /// The ticks the current frame covers (`frame_duration`), none where the clock ran back.
    pub fn frameTicks(clock: *const Clock) u32 {
        return @intCast(@max(clock.frame_duration, 0));
    }
};

/// What `mission_frame` draws a frame of.
pub const Frame = struct {
    /// The live objects, each drawn by its model's nodes.
    objects: *create.Objects,
    /// The object the camera sits in (`camera.Camera.inside`), which is not drawn but still casts
    /// its shadow.
    seat: ?u16 = null,
    /// What the mission's scene shows.
    shown: Shown = .{},
    space: *backdrop.Backdrop,
    sky: *nebula.Sky,
    /// The environment's effects, which go into the background layer with the backdrop.
    environment: ?*const environfx.Environment = null,
    view: camera.View,
    cockpit_mode: camera.CockpitMode,
    /// Whether the player's ship jumps in, which cuts the dust's streaks shorter
    /// (`input.Player.jumping_in`).
    jumping_in: bool = false,
    /// Last frame's view (`camera_view_last`, `0x00539A64`).
    last_view: camera.View,
    /// Whether the camera has switched view since the last frame drawn (`camera.Camera.cut`).
    cut: bool = false,
    /// What the models' own lights and engine glows are drawn by; each object's own offset into
    /// its lights' blinks and its glow come from its record.
    attachments: objects.View = .{},
    /// What is drawn over the scene once its layers are done, which is the head-up display.
    overlay: ?srcore.Overlay = null,
    /// The cockpit's model and the radar's backing, which view 0 draws over the world in cockpit
    /// mode 1 under the hardware renderers.
    cockpit: ?*objects.Model = null,
    backing: ?*RadarBacking = null,
    /// Whether DISPLAY KILLS is held, which leaves the backing out.
    kills_shown: bool = false,
    /// The sparks and the particles, the smoke's among them, which go into the world's layer
    /// after the shots, the explosions' bits, pieces and fireballs, and the shockwaves.
    sparks: ?*sparks.Sparks = null,
    particles: ?*particles.Pool = null,
    smoke: ?*smoke.Pools = null,
    gun_particles: ?*guns.effects.Pools = null,
    /// How far past the frame's tick the effects are drawn, as a share of a tick
    /// (`objects.pastTick`).
    ahead: f32 = 0,
    explosions: ?*explode.Explosions = null,
    shockwaves: ?*shockwave.Shockwaves = null,
    trails: ?*missiles.trail.Trails = null,
    countermeasures: ?*cloak.Countermeasures = null,
    /// The player's missile lock and its rings, which go into the overlay's layer while it builds,
    /// from the cockpit's views and the chase view.
    lock: ?*const lock.Lock = null,
    lock_rings: ?*lock.Rings = null,
    /// The chase view's objects, and the display whose reticle, pointer and lead point they
    /// follow.
    chase: ?*hud.chase.Chase = null,
    display: ?*const hud.State = null,
    /// The shields' bubbles, which go into the world's layer after the objects.
    shields: ?*shield.Shields = null,
    /// The gates' tunnels, which go into the world's layer before the shields' bubbles.
    gates: ?*wgate.Gates = null,
    /// The electric rays, which go into the world's layer after the explosions.
    rays: ?*erayfx.Rays = null,
    /// The tractors, which go into the world's layer after the objects.
    tractors: ?*tractor.Tractors = null,
    /// The Rippers' beams, which go into the world's layer after the objects.
    rippers: ?*airipper.Rippers = null,
    /// What the jumps show, which goes into the world's layer after the Rippers' beams.
    jump_effects: ?*jump.effect.Effects = null,
    /// The planets' atmospheres, which go into the background layer after the backdrop, lit by its
    /// sun and as bright as its lens flares, their planets turning.
    atmospheres: ?*create.atmosphere.Atmospheres = null,
    /// The escort point's marker, which goes into the world's layer after the backdrop and before
    /// the sky, from the cockpit's views, while the player's ship has an escort point.
    escort_marker: ?*create.escort.Marker = null,
    /// The screen's flash, which goes into the overlay's layer, and the ticks the frame spans
    /// (`frame_duration`), which it counts down.
    flash: ?*flash.Flash = null,
    ticks: i32 = 0,
    /// The display's interference, which the flash shows red in the view ahead and then fades.
    interference: ?*hud.Interference = null,
    /// Whether the game is paused, which holds the bubbles' colours still.
    paused: bool = false,
};

/// What `game_pause` pauses and resumes: the clocks, the voices, and the menu that stands in the
/// display's place while paused.
pub const Pausing = struct {
    gpa: Allocator,
    clock: *Clock,
    sound: *hog_snd.Sound,
    menu: *hudoptions.PauseMenu,
    /// The archive the menu's fonts come from, and the outline fonts that stand in for them.
    archive: bigfile.Hog,
    outlines: ?*hud.outline.Outlines = null,
    /// The camera, which resuming switches to view 0, following the player's ship's slot, when its
    /// cockpit setting (`camera.Camera.setting`) changed while paused.
    camera: *camera.Camera,
    player: *const u16,
};

/// `game_pause` (`0x00491E20`): pauses or resumes the mission. Pausing, where it isn't paused yet,
/// sets `paused`, which stops the ticks and the script clock, pauses the 3D voices and the voices,
/// and opens the menu the display gives its place to. Resuming undoes it, and switches to view 0
/// if the cockpit setting changed in the meantime. The music plays on through the pause. Pausing
/// keeps the cockpit setting, even while already paused.
///
/// Not ported, as what they serve isn't: the chat line and the typed keys it empties, the speech
/// sample it stops, the frame timing it holds, the pause it sends the other players, the paused
/// frame's clock (`paused_clock`), the renderer's `sr + 0x78`, the window it restores, and
/// `0x005DD524`. The radar's backing, which it shows again, the sandbox leaves out while paused.
pub fn pause(pausing: Pausing, on: bool) !void {
    const clock = pausing.clock;
    const sound = pausing.sound;
    const menu = pausing.menu;
    if (on) {
        if (!clock.paused) {
            clock.paused = true;
            sound3d.pause(sound, true);
            sound.pauseAll();
            try menu.open(pausing.gpa, pausing.archive, pausing.outlines);
        }
        menu.view_setting = pausing.camera.setting;
        return;
    }
    if (clock.paused) {
        clock.paused = false;
        sound3d.pause(sound, false);
        sound.resumeAll();
        menu.close();
        if (menu.view_setting != pausing.camera.setting) {
            _ = pausing.camera.setView(.cockpit, pausing.player.*, false, true, clock.viewTime());
        }
    }
}

/// `mission_frame`'s pause keys, which it looks for before its work (`0x0049280B`, `0x00492845`):
/// Escape pauses into the menu's main screen, and F1, KEY CONFIG's binding, straight into its
/// controls (`pause_screen` 2). Whether the game paused.
pub fn pauseKeys(pausing: Pausing, devices: *input.Devices) !bool {
    if (pausing.clock.paused) return false;
    if (devices.keyboard.pressed(input.scan.escape, .none, true)) {
        try pause(pausing, true);
        return true;
    }
    if (!devices.active(.key_config, true)) return false;
    try pause(pausing, true);
    pausing.menu.at = .{ .screen = .controls };
    return true;
}

test pauseKeys {
    const gpa = std.testing.allocator;
    var archive = try hudoptions.testing.fontArchive(gpa);
    defer archive.close(gpa);
    var clock: Clock = .{};
    var sound: hog_snd.Sound = .{};
    var menu: hudoptions.PauseMenu = .{};
    defer menu.close();
    var view: camera.Camera = .{};
    const player: u16 = 0;
    const pausing: Pausing = .{ .gpa = gpa, .clock = &clock, .sound = &sound, .menu = &menu, .archive = archive.hog, .camera = &view, .player = &player };
    var devices: input.Devices = .{};
    try std.testing.expect(!try pauseKeys(pausing, &devices));
    // F1 pauses straight into the controls; paused, the keys do nothing more.
    devices.keyboard.down[devices.bindings.get(.key_config).key] = true;
    try std.testing.expect(try pauseKeys(pausing, &devices));
    try std.testing.expect(clock.paused);
    try std.testing.expectEqual(hudoptions.Next{ .screen = .controls }, menu.at);
    devices.keyboard.down[input.scan.escape] = true;
    try std.testing.expect(!try pauseKeys(pausing, &devices));
}

/// `mission_paused_frame` (`0x00491FC0`)'s work before the frame is drawn, each frame while the
/// game is paused: the keyboard and the joystick read, which lets go of the keys that are up, and
/// the frame's sounds played and placed, the music playing on (`hog_snd.Sound.frame`), heard from
/// `hearing` in `world`. OpenReliant's: the controller stops rumbling. The pause menu reads the
/// pointer as it is drawn over the scene as it stood (`menu_mouse_update`), and its choice ends the
/// pause once the frame is drawn.
///
/// Not ported: the paused clock (`paused_clock`), the radar's backing's flag, and a multiplayer
/// game's messages, its chat line and the players it drops.
pub fn pausedFrame(devices: *input.Devices, hearing: hog_snd.Hearing, world: gameobj.World) void {
    devices.read();
    if (hearing.sound.stdsmp) |bank| hearing.sound.frame(bank, hearing.scene(world));
    devices.joystick.rumble(.{});
}

/// What the frame's controls, its camera and its sound run with (`controlsFrame`).
pub const Controls = struct {
    /// The world, its clock, and the devices the controls read.
    orders: aigeneric.Context,
    devices: *input.Devices,
    camera: *camera.Camera,
    display: *hud.State,
    /// The scene as last drawn, which the targeting keys find the object under the reticle by, and
    /// the screen's size in pixels.
    sight: ?hud.Sight,
    screen: [2]u32,
    /// Last frame's view (`camera_view_last`).
    last_view: camera.View,
    /// The cockpit's model, where the player's ship has one, which the camera's frame moves.
    cockpit: ?*cockpit.Cockpit.Shown,
    forces: *input.force.Forces,
    random: *libcmt.Rand,
    /// Whether what moves is drawn between the game's ticks (`objects.pastTick`).
    smooth_motion: bool,
};

/// `mission_frame`'s work for the controls, the camera and the sound, once a frame over the ticks
/// it spans: `frame_controls` (the camera's keys, then the targeting keys, `hud.targetKeys`, then
/// its own, `input.frameKeys`); the camera's frame, of the view's own object, which the ejection's
/// views show, or else the player's ship, the cockpit's model moved by the ship's rates of turn
/// over its full ones and its speed over its cruise speed; the player's ship left undrawn from its
/// cockpit, as `camera_set_view` sees to; and the frame's sound, heard from where the camera now is:
/// the fades `tick_timer` steps, the music waiting its turn, the positional sounds gathered, and
/// the 3D sounds placed again. OpenReliant's: the effects playing turn the controller's motors
/// (`input.force`).
pub fn controlsFrame(controls: Controls) void {
    const world = controls.orders.world;
    const clock = world.clock;
    const all = world.objects;
    const view = controls.camera;
    const devices = controls.devices;
    const ticks = clock.frameTicks();
    const at = clock.viewTime();
    const slot = &all.slots[all.player];
    view.frameControls(devices, all.player, ticks, at);
    hud.targetKeys(controls.display, .{
        .devices = devices,
        .player = world.player,
        .all = all,
        .sight = controls.sight,
        .last_view = controls.last_view,
        .scale = hud.scaleFor(controls.screen),
        .multiplayer = false,
        .world = world,
    });
    input.frameKeys(.{
        .display = controls.display,
        .player = world.player,
        .devices = devices,
        .slot = slot,
        .view = view.view,
        .game_ticks = clock.game_ticks,
        .multiplayer = false,
        .world = world,
        .all = all,
    });
    // `mission_frame` runs the radio's queue after the controls, then its reports and its remarks;
    // the film's timer turns with the game's clock.
    if (videoreports.onAir(world)) |on_air| {
        const radio, const ctx = on_air;
        radio.runFilm(ctx, ticks);
        radio.frame(ctx);
        radio.stepReports(ctx, clock.game_ticks);
    }
    videoreports.remarksFrame(world);
    const cockpit_input = if (controls.cockpit) |shown| shown.inputFor(slot, view.view) else null;
    const subject = camera.Subject.of(slot);
    const seen = if (view.object) |object| camera.Subject.of(&all.slots[object]) else subject;
    const marker = if (world.explosions) |explosions| if (explosions.marker) |left| left.position else null else null;
    if (view.frame(.{
        .object = seen,
        .player = subject,
        .ticks = ticks,
        .now = at,
        .ahead = objects.pastTick(clock, controls.smooth_motion),
        .marker = marker,
        .cockpit = cockpit_input,
        .random = controls.random,
        .forces = controls.forces,
        .dropping = launch.dropping(all, all.player),
        .landing = ailand.seen(all, view.object orelse all.player),
        .showing = &world.player.showing,
        .game = world,
    })) |next| {
        _ = view.setView(next, all.player, false, true, at);
    }
    slot.object.flags.hidden = view.inside(all.player);
    if (world.hearing) |hearing| {
        hearing.sound.timerTick(clock.game_ticks);
        hearing.sound.surround(world.player.showing.surroundings(view.view));
        if (hearing.sound.stdsmp) |bank| hearing.sound.frame(bank, hearing.scene(world));
    }
    devices.joystick.rumble(controls.forces.motors(clock.frame_start));
}

/// `mission_frame` (`0x004924B0`), as far as the objects go: the player's ship pointed to the
/// flyback marker it has strayed from (`input.nextNavPoint`), then the player's ship uncloaked where
/// the display ran the cloak's charge dry last frame (`hud.State.uncloakSpent`), then every
/// object's orders, which fly the ships and read the player's controls, then the player's ship sent
/// home where it destroyed a friend (`friendly_fire.sendHome`), then the scanner's beep
/// (`scanner.Scanner.frame`), then the frames they are drawn at,
/// then the missiles (`missiles.frame`) and the shots in flight (`guns.bulletsFrame`),
/// then the sparks (`sparks.Sparks.frame`) and the particles (`particles.Pool.frame`,
/// `smoke.Pools.frame`, `guns.effects.Pools.frame`), which `particles_frame` runs together, the
/// damaged ships' smoke (`smoke.frame`), the explosions (`explode.Explosions.frame`), the
/// countermeasures (`cloak.Countermeasures.frame`) and the shockwaves
/// (`shockwave.Shockwaves.frame`). Between them the frame's hits on the player's ship push its
/// controller (`input.force.Forces.pushFrame`). A mission and the sandbox alike run this once a
/// frame, before the camera's own frame and anything drawn.
///
/// Before the orders, in a frame that runs ticks while the mission plays on and its scene isn't
/// the landing's, the mission (`loaded`) raises the events waiting (`mission.Loaded.flush`) and its
/// script runs its frame's work (`mission.Loaded.process`), its clock ticking first for the
/// seconds past (`mission.Loaded.tickClock`).
///
/// After the orders, in a frame in which game time passes, mods' scripts run their `on_update`
/// handlers with the seconds of game time the frame covers.
///
/// Whether the mission is over: as the camera has it (`missionOver`), which sets the script's
/// `mission_over`, or as the script has it, which ends the mission before the frame's work; or,
/// once the frame's work is done, where the script has ended it (`TerminateMission`), as
/// `mission_run` finds after the frame (`0x004941AF`).
pub fn missionFrame(orders: aigeneric.Context, timing: objects.Timing, loaded: ?*Loaded) bool {
    input.nextNavPoint(orders.world);
    const over = missionOver(orders.world);
    const player = orders.world.player;
    if (loaded) |playing| {
        const variables = &playing.script.variables;
        if (over) variables.mission_over = 1;
        if (variables.mission_over != 0) return true;
        if (orders.world.clock.frame_duration != 0 and player.ending == .playing and player.showing != .landing) {
            playing.tickClock(orders.world.clock.game_ticks);
            playing.flush(orders);
            playing.process(orders);
        }
    }
    if (orders.world.display) |display| display.uncloakSpent(orders.world);
    if (orders.world.jump_effects) |effects| effects.beginFrame();
    aigeneric.ordersUpdate(orders);
    if (orders.world.objects.scripts) |scripts| if (orders.world.clock.frameTicks() > 0) {
        scripts.update(@as(f32, @floatFromInt(orders.world.clock.frameTicks())) / ticks_per_second);
    };
    friendly_fire.sendHome(orders);
    player.scanner.frame(orders.world, orders.world.clock.frame_start);
    frameObjects(orders.world.objects, timing, orders.world.clock.frame_start);
    if (orders.world.gates) |gates| for (gates.records) |held| {
        const record = held orelse continue;
        if (record.kind == .warp) @import("wgate/warp.zig").frame(&orders.world.objects.slots[record.slot], record);
    };
    missiles.frame(orders.world, timing.fraction);
    guns.bulletsFrame(orders.world, orders.world.clock, timing.fraction);
    if (orders.world.sparks) |thrown| thrown.frame(orders.world.clock);
    if (orders.world.particles) |pool| pool.frame(orders.world.clock);
    if (orders.world.smoke) |pools| pools.frame(orders.world.clock);
    if (orders.world.gun_particles) |pools| pools.frame(orders.world.clock);
    smoke.frame(orders.world);
    objectsPass(orders);
    followCarrier(orders.world);
    if (orders.world.forces) |forces| forces.pushFrame(orders.world.clock.frame_start);
    orders.world.objects.exhaust.burn(orders.world);
    if (orders.world.explosions) |explosions| explosions.frame(orders.world);
    if (orders.world.countermeasures) |dropped| dropped.frame(orders.world);
    if (orders.world.shockwaves) |waves| waves.frame(orders.world);
    if (orders.world.display) |display| {
        if (orders.world.view.showsLock()) display.lock.frame(orders.world, &display.missiles);
    }
    return over or player.terminated != 0;
}

/// The first mission whose script can end it (`TerminateMission`) without its ending as one the
/// player's ship is destroyed in (`0x00494204`).
const terminated_ends_well_from = 28;

/// `mission_run`'s work once its loop is over (`0x004941FC`): a mission numbered below
/// `terminated_ends_well_from` that its script ended (`TerminateMission`) ends as one the player's
/// ship is destroyed in.
pub fn missionRunEnd(player: *input.Player, mission_number: u16) void {
    if (player.terminated != 0 and mission_number < terminated_ends_well_from) player.ending = .destroyed;
}

test missionRunEnd {
    var player: input.Player = .{ .terminated = 1 };
    missionRunEnd(&player, create.instant_action_mission);
    try std.testing.expectEqual(.playing, player.ending);
    missionRunEnd(&player, 5);
    try std.testing.expectEqual(.destroyed, player.ending);
    // A mission its script leaves running ends as it ends.
    player = .{ .ending = .rescued };
    missionRunEnd(&player, 5);
    try std.testing.expectEqual(.rescued, player.ending);
}

/// `mission_frame`'s care of the ship the player launched from (`0x004932D4`): once that ship
/// explodes, the first Yamato among the objects takes its place, where there is one.
pub fn followCarrier(world: gameobj.World) void {
    const all = world.objects;
    const carrier = world.player.carrier orelse return;
    if (carrier >= all.slots.len or !all.slots[carrier].object.flags.exploding) return;
    for (all.slots[0..all.count], 0..) |*slot, index| {
        if (slot.object.type != .yamato) continue;
        world.player.carrier = @intCast(index);
        return;
    }
}

test followCarrier {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, @splat(0));
    const yamato = try mission.add(.yamato, @splat(0));
    mission.player.carrier = reliant;
    // While the Reliant holds, it stays the ship the player launched from.
    followCarrier(mission.world());
    try std.testing.expectEqual(reliant, mission.player.carrier.?);
    // Once it explodes, the Yamato takes its place.
    mission.slot(reliant).object.flags.exploding = true;
    followCarrier(mission.world());
    try std.testing.expectEqual(yamato, mission.player.carrier.?);
}

/// How long the camera watches the player's ship's end, the pilot's pod picked up, and the pod
/// shot down once it bursts, before the mission is over, in ticks (`0x0049267E`, `0x0049268D`,
/// `0x004926AD`).
const end_watched = 600;
const pickup_watched = 1200;
const shot_watched = 500;

/// `mission_frame`'s end of the mission by what the camera watches (`0x00492651`): once the
/// player's ship's end, the pod's pickup or the pod shot down has been watched its time, the
/// mission is over. Watching the pod shot down, the time counts from when it bursts.
///
/// Not ported: a multiplayer game, where the camera goes on to watch another player.
pub fn missionOver(world: gameobj.World) bool {
    const watching = world.camera orelse return false;
    const now = world.clock.viewTime();
    const watched: u32 = switch (watching.view) {
        .pull_back, .watch, .watch_marker => end_watched,
        .pickup => pickup_watched,
        .pod_shot => watched: {
            if (world.objects.slots[world.objects.player].object.flags.exploding) break :watched shot_watched;
            watching.switched = now;
            return false;
        },
        else => return false,
    };
    return now > watching.switched + watched;
}

/// `mission_frame`'s pass that draws the objects, beyond drawing them: over each object drawn
/// this frame, whether one fights the player with its missile ready, which lights the display's
/// enemy lock, what its destroyed components leave (`objects.loseComponents`, which `object_draw`
/// runs), and each one's avoidance lists (`avoidanceScan`). The damaged ships' smoke is
/// `smoke.frame`'s.
fn objectsPass(orders: aigeneric.Context) void {
    const world = orders.world;
    const all = world.objects;
    var enemy_lock = false;
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        if (slot.object.flags.outOfFrame()) continue;
        if (slot.current()) |entry| {
            if (entry.order == .fight and entry.target.slot() == all.player and slot.state.fight.missile_ready) enemy_lock = true;
        }
        objects.loseComponents(orders, index);
        avoidanceScan(world, index);
    }
    if (world.display) |display| display.enemy_lock = enemy_lock;
}

/// How much wider than the two objects' spheres an object that lists components is watched for
/// (`0x004DC43C`), and how far ahead, in steps, and how near, the others are
/// (`ai.collisionCourse`).
const avoid_widening: f32 = 10000;
const avoid_steps: f32 = 50;
const avoid_margin: f32 = 2000;

/// `avoidance_scan` (`0x00492190`): for a ship whose current order avoids
/// (`orders.Flags.avoidance`) and that has no `no_avoidance`, the objects it could hit, for the
/// avoidance code (`ai.avoidNear`, `ai.avoidAhead`), up to ten of each: those that list components
/// whose spheres, 10000 wider, overlap its own where the step takes them both; and, where the ship
/// lists none itself, the rest it is on course to hit within 50 steps by 2000. It passes over
/// stand-ins, disabled and jumping objects, planets, the ship itself, what it fights, and what
/// either passes through the other.
///
/// Not ported: in a multiplayer game, the other players' ships a ship passes by.
fn avoidanceScan(world: gameobj.World, index: u16) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const ship = &slot.object;
    if (ship.flags.no_avoidance) return;
    const entry = slot.current() orelse return;
    const info = ai.orders.info(entry.order) orelse return;
    if (!info.flags.avoidance) return;
    ship.avoid_near.count = 0;
    ship.avoid_ahead.count = 0;
    for (all.slots[0..all.count], 0..) |*other_slot, other_index| {
        const other: u16 = @intCast(other_index);
        const object = &other_slot.object;
        if (object.flags.outOfFrame() or other == index) continue;
        if (other_slot.combat) |combat| if (combat.class == .planet) continue;
        if (ship.passes_through[0].index() == other or ship.fighting.index() == other) continue;
        if (object.passes_through[0].index() == index) continue;
        if (object.flags.components) {
            if (ship.overlaps(object, avoid_widening)) ship.avoid_near.add(other);
        } else if (!ship.flags.components and ai.collisionCourse(world, index, other, avoid_steps, avoid_margin)) {
            ship.avoid_ahead.add(other);
        }
    }
}

/// `mission_frame`'s pass over the objects before the camera's frame: each live object, save
/// stand-ins and disabled and jumping ones, has `missile_homing` cleared, stands on the node it
/// rides where it is launching (`launch.hold`), and is framed as far through the simulation's step
/// as `timing` says (`frameObject`), one the orders placed going on by its glide for the time past
/// the tick, which the orders set afresh each frame.
///
/// **Improvement:** with `timing.riders` `together`, each ship riding a node stands on it again
/// once every object is framed, and is framed again, so that it keeps with a node framed after it
/// (`objects.Riders`).
pub fn frameObjects(all: *create.Objects, timing: objects.Timing, now: i32) void {
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.outOfFrame()) continue;
        object.missile_homing = 0;
        // Gliding, or the frame after, it is drawn from where the orders placed it.
        const gliding = @reduce(.Or, slot.glide != @as(math.Vector, @splat(0)));
        const glide: ?math.Vector = if (gliding or slot.glided) slot.glide * @as(math.Vector, @splat(timing.ahead)) else null;
        slot.glided = gliding;
        slot.glide = @splat(0);
        _ = launch.hold(all, index);
        frameObject(slot, timing, glide, now);
    }
    if (timing.riders == .in_turn) return;
    var riders = all.walk();
    while (riders.next()) |index| {
        const slot = &all.slots[index];
        if (slot.object.flags.outOfFrame()) continue;
        if (launch.hold(all, index)) frameObject(slot, timing, null, now);
    }
}

/// Frames the object in `slot` as far through the simulation's step as `timing` says
/// (`objects.frameTree`), going on by `glide` where the orders placed it; a cloaked one's frame
/// then wobbles as its cloak changes, by the frame's tick `now` (`cloak.wobble`).
fn frameObject(slot: *create.Slot, timing: objects.Timing, glide: ?math.Vector, now: i32) void {
    objects.frameTree(&slot.object.root, if (slot.model) |*model| model else null, &slot.drawn, timing.fraction, glide);
    cloak.wobble(slot, now);
}

/// Puts the frame's scene together and draws it, in `mission_frame`'s order: the objects
/// (`drawObjects`), the environment's effects and the backdrop, the sky; the star streaks are
/// reset when the view has changed since the last frame, or the camera has switched view
/// (`camera_set_view`); then `sr_render`. `arena` holds what the frame needs until it is drawn.
pub fn drawFrame(gpa: Allocator, arena: Allocator, scene: *srcore.Scene, context: *srapi.Context, frame: Frame, driver: srcore.Driver) Allocator.Error!void {
    scene.clear();
    // How far off an object stops being worth drawing follows the frame's own projection, so the
    // caller does not have to hand it over with the rest.
    var attachments = frame.attachments;
    attachments.scale = context.projection.scale[0];
    attachments.hardware = context.hardware;
    attachments.paused = frame.paused;
    try drawObjects(gpa, scene, frame.objects, attachments, frame.seat, if (frame.explosions) |explosions| &explosions.splits else null, frame.shown);
    if (frame.tractors) |tractors| try tractors.draw(gpa, scene, frame.objects);
    if (frame.rippers) |rippers| try rippers.draw(gpa, scene, frame.objects);
    if (frame.jump_effects) |effects| try effects.draw(gpa, scene, frame.objects);
    try missiles.draw(frame.objects, gpa, scene, attachments);
    if (frame.trails) |trails| try trails.draw(gpa, scene);
    if (frame.countermeasures) |dropped| try dropped.draw(gpa, scene, attachments);
    if (frame.lock_rings) |rings| if (frame.lock) |held| if (frame.view.showsLock()) {
        try rings.draw(gpa, scene, held, .{ .position = context.camera.position, .orientation = context.camera.orientation }, context.projection);
    };
    if (frame.chase) |seen_behind| if (frame.display) |display| if (frame.view == .cockpit and frame.cockpit_mode == .chase) {
        const ship = &frame.objects.slots[frame.objects.player];
        const aim: ?math.Vector = if (ship.object.blind_fire_aim != 0) display.lead_point else null;
        try seen_behind.draw(gpa, scene, ship.drawn, display.reticle_bright, aim, display.chase_pointer, display.chase_nav_roll);
    };
    if (frame.gates) |gates| try gates.draw(gpa, scene, frame.objects, attachments.frame_start);
    if (frame.shields) |bubbles| try bubbles.draw(gpa, arena, scene, frame.objects, .{
        .camera = attachments.camera,
        .inside = camera.inCockpit(frame.view, frame.cockpit_mode),
        .frame_start = attachments.frame_start,
        .ahead = frame.ahead,
        .paused = frame.paused,
        .random = attachments.random,
    });
    try guns.drawBullets(gpa, scene, &frame.objects.bullets, context.hardware);
    if (frame.sparks) |thrown| try thrown.draw(gpa, scene, frame.ahead);
    if (frame.particles) |pool| try pool.draw(gpa, scene, frame.ahead);
    if (frame.smoke) |pools| try pools.draw(gpa, scene, frame.ahead);
    if (frame.gun_particles) |pools| try pools.draw(gpa, scene, frame.ahead);
    if (frame.explosions) |explosions| try explosions.draw(gpa, scene, frame.ahead);
    if (frame.rays) |rays| if (attachments.random) |random| try rays.draw(gpa, scene, frame.objects, attachments.frame_start, random);
    if (frame.flash) |lit| if (!frame.paused) {
        const shaken = frame.interference;
        // In a capital ship's exhaust the flash is white alone (`exhaust_burning`).
        const red = if (shaken != null and frame.view == .cockpit and !frame.objects.exhaust.burning) shaken.?.level else 0;
        try lit.draw(gpa, scene, .{ .position = context.camera.position, .orientation = context.camera.orientation }, context.projection, frame.ticks, red);
        if (shaken) |interference| interference.fade(attachments.frame_start);
    };
    if (frame.shockwaves) |waves| try waves.draw(gpa, scene, frame.ahead);
    frame.space.shortenDust(frame.jumping_in);
    if (frame.environment) |environment| try environment.frame(gpa, scene, context.camera, attachments.frame_start);
    try frame.space.frame(gpa, scene, context, frame.view, frame.cockpit_mode);
    if (frame.atmospheres) |atmospheres| try atmospheres.frame(gpa, scene, frame.objects, context.camera.position, frame.space.sun_direction, context.hardware, frame.space.flare_brightness, frame.attachments.frame_start);
    if (frame.escort_marker) |marker| try marker.frame(gpa, scene, frame.objects, context.camera.position, frame.view, frame.ticks);
    if (context.hardware) try frame.sky.frame(gpa, scene, context);
    if (frame.view == .cockpit and frame.cockpit_mode == .cockpit and context.hardware) {
        // The backing, then the hands, then the cockpit, all over the world, sorted by depth.
        if (frame.backing) |backing| if (!frame.kills_shown) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &backing.object }, .overlay);
        if (frame.cockpit) |model| {
            for ([_]usize{ cockpit.hands, cockpit.frame }) |index| {
                if (index < model.parts.len) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &model.parts[index].object }, .overlay);
            }
        }
    }
    if (frame.view != frame.last_view or frame.cut) frame.space.resetStreaks();
    try srcore.render(arena, context, scene, driver, frame.overlay);
}

/// The key that saves a screenshot in flight: 0.
pub const screenshot_key: input.Key = .zero;

/// Whether the player asks for a screenshot of the frame just drawn, as `mission_frame` ends
/// (`0x00493480`): 0, once a press, which then saves it (`xtrabits.screenshot`).
pub fn screenshotAsked(keyboard: *input.Keyboard) bool {
    return keyboard.pressed(@intFromEnum(screenshot_key), .none, true);
}

test screenshotAsked {
    var keyboard: input.Keyboard = .{};
    const key = @intFromEnum(screenshot_key);
    try std.testing.expect(!screenshotAsked(&keyboard));
    // Once a press, and again once the key has come up.
    keyboard.down[key] = true;
    try std.testing.expect(screenshotAsked(&keyboard));
    try std.testing.expect(!screenshotAsked(&keyboard));
    keyboard.down[key] = false;
    keyboard.read();
    keyboard.down[key] = true;
    try std.testing.expect(screenshotAsked(&keyboard));
}

/// Where `mission_frame` holds `detail_divisor` (`srapi.Context.detail`) at the graphic detail
/// `detail` on a machine that keeps up: it raises it by 0.05 each frame whose timed sections take
/// under 1/60 s, up to a top the detail sets, and lowers it by 0.5 each frame over 1/40 s, down to
/// a bottom (`0x00492550` on): from 0.75 to 1.5 at LOW, 1 to 2 at MEDIUM and 1.5 to 3 at HIGH.
/// OpenReliant holds it at the top.
pub fn detailDivisor(detail: explode.Detail) f32 {
    return detail_tops.get(detail);
}

const detail_tops: std.EnumArray(explode.Detail, f32) = .init(.{ .low = 1.5, .medium = 2, .high = 3 });

test detailDivisor {
    try std.testing.expectEqual(3, detailDivisor(.high));
    try std.testing.expectEqual(1.5, detailDivisor(.low));
}

/// How far the finer levels of detail reach (`srapi.Context.finer`).
pub const DetailReach = enum {
    /// **Improvement:** eight times as far as the original has them, so that a ship keeps its
    /// finest mesh until it is far off and no level change shows up close; its last level still
    /// ends, and the ship leaves sight, where the original's does.
    far,
    /// As far as the original has them.
    original,

    pub fn finer(reach: DetailReach) f32 {
        return switch (reach) {
            .far => 8,
            .original => 1,
        };
    }
};

/// How much a frame may draw (`srapi.Context.budget`).
pub const DrawBudget = enum {
    /// **Improvement:** ten times the original's, 200000 vertices and as many polygons, which
    /// a current computer draws with ease. OpenReliant keeps up to 4000 burning bits where the
    /// original keeps 500 (`explode.BitPool`), and a view full of them and of a split's bodies
    /// takes the original's budget; since the layers are drawn from what went in last, the bits
    /// then crowd out the ships' parts, which vanish while the view is full.
    roomy,
    /// The original's, 19999 of each (`srapi.original_budget`).
    original,

    pub fn limit(budget: DrawBudget) usize {
        return switch (budget) {
            .roomy => 200_000,
            .original => srapi.original_budget,
        };
    }
};

/// `mission_frame`'s pass that draws the objects: each live object, save stand-ins and disabled
/// and jumping ones, has its cloak's frame run where it has one (`cloak.frame`), and is drawn with
/// `object_draw` (`objects.Model.draw`), with its own offset into its lights' blinks, its lights
/// unless `lights_disabled`, its engine glows burning by the throttle of its last update times the
/// share of its engines left, but none while it is among `splits`, and nothing at all while it is
/// `hidden`, as the ship the camera sits in is. That ship, `seat`, still casts its shadow
/// (`objects.Model.castShadows`), cloaked as its hull stands (`cloak.shadeUnseen`). A cloaked
/// object is drawn with neither lights nor glows, its parts as its cloak draws them
/// (`cloak.Drawing`).
///
/// Not ported yet: what else the pass draws for a few types, the protogate's power core
/// pulsing, the Boridin breakaway's core and the Dark Reign's hat
/// ([#238](https://github.com/OpenReliant/openreliant/issues/238)); the cutaway scenes' own rules, and
/// the gate's tunnel, in which no object is drawn. The pass's smoke is `smoke.frame`.
pub fn drawObjects(gpa: Allocator, scene: *srcore.Scene, all: *create.Objects, attachments: objects.View, seat: ?u16, splits: ?*const explode.split.Splits, shown: Shown) Allocator.Error!void {
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.outOfFrame()) continue;
        cloak.frame(slot, attachments.frame_start);
        const model = if (slot.model) |*model| model else continue;
        if (object.flags.hidden or shown.leavesOut(all, index)) {
            if (index == seat) {
                if (slot.cloak) |cloaking| cloak.shadeUnseen(model, cloaking.hull);
                try model.castShadows(gpa, scene);
            }
            continue;
        }
        var view = attachments;
        view.blink_offset = object.blink_offset;
        view.lights = !object.flags.lights_disabled;
        view.throttle = object.last_throttle * object.engines_intact;
        if (splits) |under_way| view.glows = !under_way.splitting(index);
        // A cloaked object's lights and engine glows are out, and its cloak draws its parts.
        if (slot.cloak) |*cloaking| {
            view.lights = false;
            view.glows = false;
            view.cloak = .{ .cloak = cloaking, .kafelnikof = object.type == .kafelnikof };
        }
        try model.draw(gpa, scene, .world, view);
    }
}

test "the objects are framed and drawn, save those left out" {
    const gpa = std.testing.allocator;
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(gpa, &random);
    defer all.destroy();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var tables = create.testing.tables();
    for (0..4) |place| {
        const at: math.Vector = .{ @floatFromInt(place * 100), 0, 0 };
        _ = try create.createObject(all, &tables, model.types(), null, .predator, 0, at, &random);
    }
    // The first is the ship the camera sits in, the second is disabled and the third jumping.
    all.slots[0].object.flags.hidden = true;
    all.slots[1].object.flags.disabled = true;
    all.slots[2].object.flags.jumping = true;
    all.slots[3].object.missile_homing = 1;
    frameObjects(all, .{}, 0);
    // Each framed one stands where it was made, and the pass clears the missile warning.
    try std.testing.expectEqual(math.Vector{ 300, 0, 0 }, all.slots[3].drawn.position);
    try std.testing.expectEqual(0, all.slots[3].object.missile_homing);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try drawObjects(gpa, &scene, all, .{}, 0, null, .{});
    // Only the fourth is drawn: its one part. The first, which the camera sits in, casts its
    // shadow without being drawn.
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(math.Vector{ 300, 0, 0 }, scene.layers.get(.world).items[0].mesh.position);
    try std.testing.expectEqual(1, scene.casters.items.len);
    try std.testing.expectEqual(math.Vector{ 0, 0, 0 }, scene.casters.items[0].position);

    // The ejection's cutaway shows the player's pod and the cutaway slot's ship alone.
    all.slots[0].object.flags.hidden = false;
    const seen = try create.createObject(all, &tables, model.types(), create.cutaway_slot, .predator, 0, .{ 0, 0, 500 }, &random);
    frameObjects(all, .{}, 0);
    scene.clear();
    try drawObjects(gpa, &scene, all, .{}, null, null, .{ .showing = .ejection });
    const drawn = scene.layers.get(.world).items;
    try std.testing.expectEqual(2, drawn.len);
    for (drawn) |item| try std.testing.expect(std.meta.eql(item.mesh.position, all.slots[0].drawn.position) or std.meta.eql(item.mesh.position, all.slots[seen].drawn.position));

    // A launch's cutaway leaves out the ship the player launches from.
    scene.clear();
    try drawObjects(gpa, &scene, all, .{}, null, null, .{ .showing = .launch, .carrier = 3 });
    for (scene.layers.get(.world).items) |item| try std.testing.expect(!std.meta.eql(item.mesh.position, all.slots[3].drawn.position));
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
}

test "the camera is in a hangar while a launch shows the bay, or a landing the tube, from within" {
    try std.testing.expectEqual(.hangar, Showing.launch.surroundings(.launch_aside));
    try std.testing.expectEqual(.hangar, Showing.landing.surroundings(.landing_tube));
    try std.testing.expectEqual(.space, Showing.landing.surroundings(.landing_aside));
    for ([_]Showing{ .everything, .ejection }) |showing| try std.testing.expectEqual(.space, showing.surroundings(.cockpit));
}

test "a launching ship keeps with the node it rides, though that is framed after it" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const ship = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.reliant, @splat(0));
    _ = try aigeneric.pushShip(mission.orders(), ship, .launch, carrier, 0);
    const slot = mission.slot(ship);
    slot.riding = .{ .object = carrier };
    slot.state.launch.attached = true;
    slot.state.launch.orientation = math.identity;
    // The carrier moves on through the step, from where the last frame drew it.
    const root = &mission.slot(carrier).object.root;
    root.flags.committed = true;
    root.next_position = .{ .x = 100, .y = 0, .z = 0 };
    for ([_]objects.Riders{ .in_turn, .together }, [_]f32{ 0, 50 }) |riders, x| {
        mission.slot(carrier).drawn.position = @splat(0);
        frameObjects(mission.objects, .{ .fraction = 0.5, .riders = riders }, 0);
        try std.testing.expectEqual(math.Vector{ 50, 0, 0 }, mission.slot(carrier).drawn.position);
        // The original leaves the ship where the carrier was drawn the frame before.
        try std.testing.expectEqual(math.Vector{ x, 0, 0 }, slot.drawn.position);
    }
}

test "an object the orders place is drawn on by its glide, for the time past the tick" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const index = try mission.add(.predator, .{ 0, 0, 100 });
    const slot = mission.slot(index);
    // Placed at 100 and going 8 a tick, half a tick on it is drawn 4 further along.
    slot.glide = .{ 0, 0, 8 };
    frameObjects(mission.objects, .{ .ahead = 0.5 }, 0);
    try std.testing.expectEqual(math.Vector{ 0, 0, 104 }, slot.drawn.position);
    // Its glide goes once used: placed no more, it is drawn back where it was placed.
    try std.testing.expectEqual(math.Vector{ 0, 0, 0 }, slot.glide);
    frameObjects(mission.objects, .{ .ahead = 0.5 }, 0);
    try std.testing.expectEqual(math.Vector{ 0, 0, 100 }, slot.drawn.position);
    try std.testing.expect(!slot.glided);
    slot.glide = .{ 0, 0, 8 };
    frameObjects(mission.objects, .{ .ahead = 0.25 }, 0);
    try std.testing.expectEqual(math.Vector{ 0, 0, 102 }, slot.drawn.position);
}

/// A driver that draws nothing and counts the frames it is handed, for the tests of what goes into
/// a frame.
const IdleDriver = struct {
    frames: usize = 0,

    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    const srbmo = @import("../surrender/surrenderlib/srbmo.zig");
    const srstars = @import("../surrender/surrenderlib/srstars.zig");
    const srlight = @import("../surrender/surrenderlib/srlight.zig");

    fn driver(idle: *IdleDriver) srcore.Driver {
        return .{ .ptr = idle, .vtable = &.{
            .begin = begin,
            .lights = lights,
            .mesh = mesh,
            .sprites = sprites,
            .stars = stars,
            .overlay = mark,
            .flush = flush,
            .end = mark,
        } };
    }

    fn begin(ptr: *anyopaque, _: *srapi.Context) void {
        const idle: *IdleDriver = @ptrCast(@alignCast(ptr));
        idle.frames += 1;
    }

    fn lights(_: *anyopaque, _: []srlight.Light) Allocator.Error!void {}
    fn mesh(_: *anyopaque, _: *const srmesh.Drawn, _: srcore.Layer, _: *srcore.Blended) Allocator.Error!void {}
    fn sprites(_: *anyopaque, _: *const srbmo.Drawn, _: srcore.Layer, _: *srcore.Blended) Allocator.Error!void {}
    fn stars(_: *anyopaque, _: *const srstars.Drawn, _: srcore.Layer, _: *srcore.Blended) Allocator.Error!void {}
    fn mark(_: *anyopaque) void {}
    fn flush(_: *anyopaque, _: []const srcore.Deferred, _: srcore.Layer) void {}
};

test drawFrame {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    const ship = try mission.addWith(model.types(), .predator, .{ 0, 0, 1000 });
    frameObjects(mission.objects, .{}, 0);

    // The backdrop, the sky, and the radar's backing, from textures of their own names.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try names.appendSlice(gpa, backdrop.testing.names);
    try names.append(gpa, RadarBacking.texture_name);
    const textures = try srtexture.testing.Textures.init(gpa, names.items);
    defer textures.deinit(gpa);
    const map = try gpa.alloc(u8, backdrop.star_map_size * backdrop.star_map_size * 3);
    defer gpa.free(map);
    @memset(map, 0);
    const space = try backdrop.Backdrop.create(gpa, &textures.table, .{ .width = backdrop.star_map_size, .height = backdrop.star_map_size, .rgb = map }, &mission.random, 100, .original);
    defer space.destroy(gpa);
    const dome = try gpa.alloc(u8, nebula.dome_image_size * nebula.dome_image_size * 3);
    defer gpa.free(dome);
    @memset(dome, 0);
    const sky = try nebula.Sky.create(gpa, &textures.table, .{ .width = nebula.dome_image_size, .height = nebula.dome_image_size, .rgb = dome });
    defer sky.destroy(gpa);
    const backing = try RadarBacking.create(gpa, &textures.table);
    defer gpa.destroy(backing);
    var cockpit_model = try cockpit.create(arena, &model.source, &model.loaded);

    var context: srapi.Context = .{ .projection = .init(640, 480, srapi.full_screen, camera.factors) };
    backing.place(context.projection, .{}, 1);
    var idle: IdleDriver = .{};
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var frame: Frame = .{
        .objects = mission.objects,
        .space = space,
        .sky = sky,
        .view = .chase,
        .cockpit_mode = .open,
        .last_view = .chase,
        .cockpit = &cockpit_model,
        .backing = backing,
    };

    // Behind the ship: the ship in the world, the backdrop's stars first in the background and the
    // sky's dome and nebula last, and the frame handed to the driver.
    try drawFrame(gpa, arena, &scene, &context, frame, idle.driver());
    try std.testing.expectEqual(1, idle.frames);
    const world = scene.layers.get(.world).items;
    try std.testing.expectEqual(1, world.len);
    try std.testing.expectEqual(&mission.slot(ship).model.?.parts[0].object, world[0].mesh);
    const background = scene.layers.get(.background).items;
    try std.testing.expectEqual(&space.fields[0], background[0].stars);
    try std.testing.expectEqual(&sky.dome, background[background.len - 2].mesh);
    try std.testing.expectEqual(&sky.patches[sky.shown], background[background.len - 1].mesh);

    // From the cockpit with its model, the radar's backing and then the cockpit go over it all:
    // this cockpit has no hands.
    frame.view = .cockpit;
    frame.cockpit_mode = .cockpit;
    try drawFrame(gpa, arena, &scene, &context, frame, idle.driver());
    var overlay = scene.layers.get(.overlay).items;
    try std.testing.expectEqual(2, overlay.len);
    try std.testing.expectEqual(&backing.object, overlay[0].mesh);
    try std.testing.expectEqual(&cockpit_model.parts[cockpit.frame].object, overlay[1].mesh);
    // DISPLAY KILLS held, the backing is left out.
    frame.kills_shown = true;
    try drawFrame(gpa, arena, &scene, &context, frame, idle.driver());
    overlay = scene.layers.get(.overlay).items;
    try std.testing.expectEqual(1, overlay.len);
    try std.testing.expectEqual(&cockpit_model.parts[cockpit.frame].object, overlay[0].mesh);

    // The software renderer draws neither the sky nor the cockpit.
    context.hardware = false;
    frame.kills_shown = false;
    try drawFrame(gpa, arena, &scene, &context, frame, idle.driver());
    try std.testing.expectEqual(4, idle.frames);
    try std.testing.expectEqual(0, scene.layers.get(.overlay).items.len);
    for (scene.layers.get(.background).items) |item| {
        if (item == .mesh) try std.testing.expect(item.mesh != &sky.dome);
    }
}

test "the passes draw a cloaked object through its cloak" {
    const gpa = std.testing.allocator;
    var stage: cloak.testing.Cloaked = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const part = stage.part();
    cloak.set(stage.mission.world(), stage.index, true);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);

    // Halfway on, the frame wobbles, and the part is drawn see-through, half solid, under its
    // shimmer.
    const halfway = cloak.change_ticks / 2;
    frameObjects(stage.mission.objects, .{}, halfway);
    try std.testing.expect(!std.meta.eql(math.identity, stage.slot().drawn.orientation));
    try drawObjects(gpa, &scene, stage.mission.objects, .{ .frame_start = halfway }, null, null, .{});
    const drawn = scene.layers.get(.world).items;
    try std.testing.expectEqual(2, drawn.len);
    try std.testing.expectEqual(&part.cloak.?.shimmer, drawn[0].mesh);
    try std.testing.expectEqual(&part.object, drawn[1].mesh);
    try std.testing.expectApproxEqAbs(0.5, part.object.colour[3], 1e-6);

    // Once it has come on and gone again, the part alone, as it was.
    scene.clear();
    cloak.frame(stage.slot(), cloak.change_ticks);
    cloak.toggle(stage.mission.world(), stage.index);
    try drawObjects(gpa, &scene, stage.mission.objects, .{ .frame_start = 2 * cloak.change_ticks }, null, null, .{});
    try std.testing.expectEqual(null, stage.slot().cloak);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
}

/// The radar's backing (`0x005883BC`), which the mission's start makes and the cockpit's view
/// draws first: a rectangle across the radar, from 65 left of the middle of the screen to 67
/// right, and 32 either side of the radar's height, `radaralpha`'s disc on it, 75% black. The
/// start unprojects its corners to 1000 in front of the camera, and the object stands in the
/// camera's frame, so it keeps its place on the screen.
///
/// **Improvement.** OpenReliant keeps it on the radar as the display is scaled: its corners are
/// measured in the display's pixels from where the radar stands, and worked out again each frame
/// for the window's size.
pub const RadarBacking = struct {
    positions: [4]math.Vector,
    normals: [4]math.Vector = @splat(@splat(0)),
    polygons: [1]srapiext.Polygon = .{.{ .kind = .triangle, .continues = 0, .first = 0, .count = 4 }},
    indices: [4]u16 = .{ 0, 1, 2, 3 },
    planes: [1]srapiext.Plane = .{.{ .normal = @splat(0), .distance = 0 }},
    biases: [1]f32 = .{0},
    surfaces: [1]srapiext.Surface,
    baked: [4][4]f32 = @splat(colour),
    uv: [4][2]f32 = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } },
    mesh: srapiext.Mesh,
    levels: [1]srapiext.Level,
    object: srapiext.MeshObject,

    /// Its corners across from the middle of the screen, and down from the radar's point.
    pub const across: [2]i32 = .{ -65, 67 };
    pub const down: [2]i32 = .{ -32, 32 };
    /// How far in front of the camera the corners stand.
    pub const depth: f32 = 1000;
    pub const colour: [4]f32 = .{ 0, 0, 0, 0.75 };
    pub const texture_name = "radaralpha";

    /// Makes the backing, with its texture from `textures`, as the start does: lit by its own
    /// colours, textured by its own coordinates and blended by alpha, never culled.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!*RadarBacking {
        const texture = try matmanager.textureRequire(textures, texture_name);
        const backing = try gpa.create(RadarBacking);
        backing.* = .{
            .positions = @splat(@splat(0)),
            .surfaces = .{.{ .polygons = 1, .material = .onePass(.{ .coordinates = .generated, .lit = true, .blend = .alpha }), .textures = .{ .{ .image = texture }, .none } }},
            .mesh = undefined,
            .levels = undefined,
            .object = undefined,
        };
        backing.mesh = .{
            .positions = &backing.positions,
            .normals = &backing.normals,
            .polygons = &backing.polygons,
            .indices = &backing.indices,
            .uv = .{ null, null },
            .planes = &backing.planes,
            .biases = &backing.biases,
            .surfaces = &backing.surfaces,
            .baked = &backing.baked,
            .bounds = undefined,
            .radius = undefined,
        };
        backing.levels = .{.{ .mesh = &backing.mesh, .until = std.math.inf(f32) }};
        backing.object = .{
            .flags = .{ .not_culled = true, .baked_mesh = true, .own_first = true },
            .position = @splat(0),
            .radius = 0,
            .levels = &backing.levels,
            .own_uv = .{ &backing.uv, null },
        };
        return backing;
    }

    /// Puts the corners on the radar for this frame's `projection`, and the object at the camera.
    pub fn place(backing: *RadarBacking, projection: srapi.Projection, at: camera.Place, scale: f32) void {
        backing.positions = corners(projection, scale);
        srapi.findBoundingBox(&backing.mesh);
        backing.object.radius = backing.mesh.radius;
        backing.object.position = at.position;
        backing.object.orientation = at.orientation;
    }

    /// The corners in the camera's frame: across from the middle of the screen and down from the
    /// radar's height, in the display's pixels, unprojected to `depth`.
    pub fn corners(projection: srapi.Projection, scale: f32) [4]math.Vector {
        const radar = hud.place(projection.screen, hud.Radar.offset, hud.Radar.across, hud.Radar.down, scale);
        const around = [4][2]i32{ .{ across[0], down[0] }, .{ across[1], down[0] }, .{ across[1], down[1] }, .{ across[0], down[1] } };
        var out: [4]math.Vector = undefined;
        for (&out, around) |*position, corner| {
            const x = @as(f32, @floatFromInt(corner[0])) * scale;
            const y = @as(f32, @floatFromInt(radar[1])) + @as(f32, @floatFromInt(corner[1])) * scale - projection.centre[1];
            position.* = .{ x * depth / projection.scale[0], y * depth / projection.scale[1], depth };
        }
        return out;
    }
};

test missionOver {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const index = try mission.add(.predator, @splat(0));
    var watching: camera.Camera = .{};
    var world = mission.world();
    // Without a camera, or in a view of the mission, the mission goes on.
    try std.testing.expect(!missionOver(world));
    world.camera = &watching;
    mission.clock.mission_ticks = 100_000;
    try std.testing.expect(!missionOver(world));
    // The player's end is watched for six seconds, the pickup for twelve.
    for ([_]struct { camera.View, u32 }{ .{ .pull_back, end_watched }, .{ .pickup, pickup_watched } }) |case| {
        const view, const watched = case;
        _ = watching.setView(view, index, true, true, 1000);
        mission.clock.mission_ticks = @intCast(1000 + watched);
        try std.testing.expect(!missionOver(world));
        mission.clock.mission_ticks += 1;
        try std.testing.expect(missionOver(world));
    }
    // The pod shot down is watched from when it bursts.
    _ = watching.setView(.pod_shot, index, true, true, 0);
    mission.clock.mission_ticks = 5000;
    try std.testing.expect(!missionOver(world));
    try std.testing.expectEqual(5000, watching.switched);
    mission.slot(index).object.flags.exploding = true;
    mission.clock.mission_ticks = 5001 + shot_watched;
    try std.testing.expect(missionOver(world));
}

test "the radar's backing stands where the radar does" {
    // At 640 by 480 and the game's scale, the corners project back to 65 left of the middle to
    // 67 right, and 32 either side of the radar's height, 68 above the foot.
    const projection = srapi.Projection.init(640, 480, .{ 0, 0, 1, 1 }, camera.factors);
    const corners = RadarBacking.corners(projection, 1);
    for (corners, [4][2]f32{ .{ 320 - 65, 480 - 68 - 32 }, .{ 320 + 67, 480 - 68 - 32 }, .{ 320 + 67, 480 - 68 + 32 }, .{ 320 - 65, 480 - 68 + 32 } }) |corner, expected| {
        const screen = projection.transform(corner);
        try std.testing.expectApproxEqAbs(expected[0], screen.x, 0.01);
        try std.testing.expectApproxEqAbs(expected[1], screen.y, 0.01);
    }
}

// --- The armour ---------------------------------------------------------------------------

/// `0x00492370`: what an object's armour does to it, from how much of each quadrant's armour is
/// left of its full armour, `6 * ShipCombat.armor_class - 1`, the fore quadrant being the third
/// and the aft the fourth: the guns' condition (`gun_condition`), half the fore one's share and a
/// quarter of each side's; the cruise speed (`armor_speed_factor`), a quarter plus three quarters
/// of the aft one's; and the shields' recharge (`shield_condition`), a quarter of each quadrant's.
/// `create_object` runs it once the armour is full, and the damage as it wears. **Unverified:** it
/// lies after `language.cpp`'s code, where `main.cpp`'s begins, next to `mission_frame`. For the
/// player's ship it goes on to the warning (`armorWarning`).
pub fn armorConditions(object: *gameobj.GameObject, combat: *const create.ShipCombat) void {
    const full = combat.startingArmor();
    const fore = object.armor.fore / full;
    const aft = object.armor.aft / full;
    const sides = (object.armor.left / full) * quadrant_share + (object.armor.right / full) * quadrant_share;
    object.gun_condition = fore * fore_gun_share + sides;
    object.armor_speed_factor = aft * aft_speed_share + least_speed_share;
    object.shield_condition = fore * quadrant_share + aft * quadrant_share + sides;
}

/// What `armorConditions` weighs each quadrant's share of its armour by: a quarter of each toward
/// the shields, and of each side toward the guns (`0x004DC3D4`); half the fore's toward the guns
/// (`0x004DC408`); and three quarters of the aft's toward the cruise speed (`0x004DC550`), over the
/// quarter it keeps with no aft armour at all (`0x004DC3D4`).
const quadrant_share: f32 = 0.25;
const fore_gun_share: f32 = 0.5;
const aft_speed_share: f32 = 0.75;
const least_speed_share: f32 = 0.25;

/// The rest of `object_armor_conditions` (`0x00492370`), for the player's ship: once a quadrant has
/// lost its shield and `armor_warning_share` of its armour, the cockpit's warning, sound 1 of
/// `betty.fat`, no more than once in `armor_warning_interval` ticks.
pub fn armorWarning(hearing: hog_snd.Hearing, object: *const gameobj.GameObject, combat: *const create.ShipCombat) void {
    const sound = hearing.sound;
    const frame_start = hearing.clock.frame_start;
    if (frame_start - sound.armor_warned_at <= armor_warning_interval) return;
    const half = combat.startingArmor() * armor_warning_share;
    for (object.shields.values(), object.armor.values()) |held, armor| {
        if (held > 0 or armor >= half) continue;
        _ = betty.say(sound, .armor_failing);
        sound.armor_warned_at = frame_start;
        return;
    }
}

/// How long the armour's warning keeps quiet once given, in ticks (`0x00492432`), and the share of
/// a quadrant's armour below which it is given (`0x004DC408`).
const armor_warning_interval = 500;
const armor_warning_share: f32 = 0.5;

test armorWarning {
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    const bytes = comptime hog_snd.testing.bank(2);
    sound.betty = try @import("../../formats/fat.zig").Bank.parse(&bytes);
    var clock: Clock = .{ .frame_start = 1000 };
    const hearing = speaker.hearing(&clock);
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .armor_class = 5 });
    var object = gameobj.testing.object();
    object.shields = .all(10);
    object.armor = .all(29);

    // Whole, or with its shields up, no warning.
    armorWarning(hearing, &object, &combat);
    object.armor.left = 10;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(0, sound.armor_warned_at);
    // A quadrant with its shield gone and under half its armour warns, and not again for 500
    // ticks.
    object.shields.left = 0;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(1000, sound.armor_warned_at);
    clock.frame_start = 1400;
    armorWarning(hearing, &object, &combat);
    try std.testing.expectEqual(1000, sound.armor_warned_at);
}

test armorConditions {
    var object = gameobj.testing.object();
    const combat = std.mem.zeroInit(create.ShipCombat, .{ .armor_class = 5 });
    // Whole, everything works fully.
    object.armor = .all(29);
    armorConditions(&object, &combat);
    try std.testing.expectEqual(1, object.gun_condition);
    try std.testing.expectEqual(1, object.armor_speed_factor);
    try std.testing.expectEqual(1, object.shield_condition);
    // With the aft armour gone the ship is down to a quarter of its speed, and its shields to
    // three quarters; the guns, at the fore, are untouched.
    object.armor.aft = 0;
    armorConditions(&object, &combat);
    try std.testing.expectEqual(1, object.gun_condition);
    try std.testing.expectEqual(0.25, object.armor_speed_factor);
    try std.testing.expectEqual(0.75, object.shield_condition);
}

// --- The mission's start -------------------------------------------------------------------

/// A ship the player can fly, as the mission's start (`0x004934F0`) knows it.
pub const PlayerShip = struct {
    /// The model of the cockpit's frame, which the start loads into `0x0057E048`.
    cockpit: []const u8,
    /// The gunnery display's wire frame of the ship, a shape of the display's set, which the start
    /// keeps at `0x005883C0` (`hud.gunnery`).
    wire_frame: u16,
    /// The shape the wing status window shows the ship by (`GameObject.wing_icon`), which the
    /// start gives each ship of the player's wing from the table at `0x004F8890`.
    wing_icon: u16,
    spectral_shields: bool = false,
    blind_fire: bool = false,
};

/// The twelve ships the player can fly, by ship type.
///
/// In mission 25's first part (`mission_number`, `mission25_second_part`), the start loads the
/// Kamov's cockpit, `kamg_frm.shp`, whatever the ship, which OpenReliant does not yet
/// ([#301](https://github.com/OpenReliant/openreliant/issues/301)).
pub const player_ships = [_]PlayerShip{
    .{ .cockpit = "preg_frm.shp", .wire_frame = 0x116, .wing_icon = 0xFC, .blind_fire = true },
    .{ .cockpit = "nagg_frm.shp", .wire_frame = 0x10E, .wing_icon = 0xFA, .spectral_shields = true },
    .{ .cockpit = "gre2_frm.shp", .wire_frame = 0x108, .wing_icon = 0x101 },
    .{ .cockpit = "cru3_frm.shp", .wire_frame = 0x107, .wing_icon = 0xFF, .spectral_shields = true },
    .{ .cockpit = "coyg_frm.shp", .wire_frame = 0x106, .wing_icon = 0x102, .blind_fire = true },
    .{ .cockpit = "mirg_frm.shp", .wire_frame = 0x10B, .wing_icon = 0xFB },
    .{ .cockpit = "temg_frm.shp", .wire_frame = 0x11B, .wing_icon = 0x100, .spectral_shields = true },
    .{ .cockpit = "pat2_frm.shp", .wire_frame = 0x10F, .wing_icon = 0x103, .blind_fire = true },
    .{ .cockpit = "wolv_frm.shp", .wire_frame = 0x11E, .wing_icon = 0xFE },
    .{ .cockpit = "rea2_frm.shp", .wire_frame = 0x117, .wing_icon = 0x105, .blind_fire = true },
    .{ .cockpit = "shr2_frm.shp", .wire_frame = 0x11A, .wing_icon = 0xFD, .spectral_shields = true, .blind_fire = true },
    .{ .cockpit = "phe2_frm.shp", .wire_frame = 0x112, .wing_icon = 0x104, .blind_fire = true },
};

/// The player's ship of `ship_type`, a twin as the ship it twins (`gameobj.Type.untwinned`), or null
/// for a type the start has none for.
pub fn playerShip(ship_type: gameobj.Type) ?PlayerShip {
    const index = ship_type.untwinned().number();
    return if (index < player_ships.len) player_ships[index] else null;
}

/// `mission_start`'s part in the player's wing, once the mission has listed it: the player's ship
/// takes the wing's first slot, and each ship in the wing the icon of its type
/// (`PlayerShip.wing_icon`), or none for a type the player can't fly.
pub fn startWing(all: *create.Objects) void {
    all.wing[0] = all.player;
    for (all.wing) |listed| {
        const index = listed orelse continue;
        const object = &all.slots[index].object;
        object.wing_icon = if (playerShip(object.type)) |ship| ship.wing_icon else 0;
    }
}

test startWing {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.reaper, @splat(0));
    const wingman = try mission.add(.predator, .{ 1000, 0, 0 });
    const twin = try mission.add(.t_phoenix, .{ 2000, 0, 0 });
    const capital = try mission.add(.reliant, .{ 0, 0, 9000 });
    all.wing = .{ null, wingman, twin, capital, null, null };
    startWing(all);
    // The player first, and each ship by its type's icon: a twin as the ship it twins, a type the
    // player can't fly none.
    try std.testing.expectEqual(player, all.wing[0].?);
    try std.testing.expectEqual(player_ships[9].wing_icon, all.slots[player].object.wing_icon);
    try std.testing.expectEqual(0xFC, all.slots[wingman].object.wing_icon);
    try std.testing.expectEqual(0x104, all.slots[twin].object.wing_icon);
    try std.testing.expectEqual(0, all.slots[capital].object.wing_icon);
}

/// What a mission's start readies the mission in, and starts it with.
pub const Start = struct {
    /// What the objects' orders and the mission's script act on: the world, whose pools the start
    /// empties and whose objects it makes afresh, and its clock.
    orders: aigeneric.Context,
    /// The mission's clocks, whose frame the start resets (`frame_reset`).
    clock: *Clock,
    /// The ship types' stats, and their models, which the objects are made from: the start lets go
    /// of the models no object is of any more, and loads each type the mission places
    /// (`ship_type_load`).
    tables: *create.Stats,
    types: *create.library.TypeCache,
    /// The cockpit it loads for the player's ship, and the display it readies for it.
    cockpit: *cockpit.Cockpit,
    display: *hud.State,
    /// The campaign the mission is flown in, whose variables the attempt starts from
    /// (`gameflow.Campaign.attempt`); none for a mission flown outside one, which starts from a new
    /// campaign's (`gameflow.restartPoint`).
    campaign: ?*const gameflow.Campaign = null,
};

/// Where the mission's start makes the camera's marker (`0x00588390`), which the flyby and target
/// views move about (`frame_controls`, `camera_set_view`): an immediate of `mission_start`.
/// OpenReliant's camera keeps its own place for those views, and nothing reads the marker.
const camera_marker_at: math.Vector = .{ 0, 0, -8000 };

/// A mission's start: the loading before it (`mission_load`, `0x004AD0A0`) and `mission_start`
/// (`0x004934F0`), for the mission `image`, made in `gpa`, which the mission then owns, played as
/// mission `number`. Returns the mission loaded for play, which the caller destroys once it ends.
///
/// The loading readies the display's objectives and the launch's caption for the mission, drops the
/// flyback markers, and empties the radio's queue, its reports and its remarks, the script's
/// switches among them (`hud_init`, `radio_reset`), and Moose's warnings of the player's hits on
/// friends (`mission_run`, `0x00474B20`), empties the effects' pools and the missiles in flight,
/// puts a stand-in in every object's slot (`create.Objects.reset`), loads the Turret Flak's
/// shell and the debris (`guns_load_shell`, `explosions_init`), and clears the mark of the player's
/// ship jumping in (`jump_init`). Then the start:
/// 1. ends the 3D sounds, has the mission play with everything shown, no ship the player launched
///    from, no primary target, the camera free in view 0 on the player's ship, in the cockpit mode
///    the options' setting picks, and the ejected pilot always picked up, and puts back the pilot's
///    kills (`winmain.startMission`);
/// 2. binds the mission, whose records the orders then reach (`gameobj.World.mission`), gives its
///    script the game's variables an attempt starts with (`Start.campaign`) and the number
///    of players, which WinMain sets before the mission loads (`script_set_players`,
///    `0x004124D0`, `vm.Variables.players`), and starts the script (`mission.Loaded.start`),
///    whose start part makes the mission's first ships and gives them their orders, a launch
///    among them. The mods' scripts for the mission start just before that
///    (`hooks.Scripts.begin`);
/// 3. lists the player's wing's icons (`startWing`), and makes the camera's marker in the next
///    slot;
/// 4. lets go of the types no object is of any more, and loads the model of each type the mission
///    places;
/// 5. resets the frame's clock (`frame_reset`), loads the cockpit of the player's ship, and readies
///    the display for it as `hud_init` and the start have it: its devices fitted (`fitDevices`),
///    its missiles in the missile display, no missile lock, and the eject marker out.
///
/// Last, mods' scripts run their `on_mission_start` handlers (`hooks.Scripts.started`).
///
/// The start clears the keyboard's state (`0x004BD7E0`), which the next read of the keyboard fills
/// again; OpenReliant's keeps what the device reports.
///
/// The caller shows the loading screen that goes before it (`xtrabits.loading.missionFrames`).
/// Not ported: the renderer's and the textures' setting up, which OpenReliant does once as it
/// starts; the chat line and a multiplayer game; and what the start does for the campaign:
/// mission 25's first part's cockpit, and the pilot's profile
/// ([#301](https://github.com/OpenReliant/openreliant/issues/301)).
pub fn startMission(gpa: Allocator, start: Start, image: []u8, number: u16) !*Loaded {
    const types = start.types.types();
    var orders = start.orders;
    orders.world.spawn = .{ .tables = start.tables, .types = types };
    const world = orders.world;
    const all = world.objects;
    if (world.explosions) |explosions| explosions.reset();
    if (world.shockwaves) |waves| waves.reset();
    if (world.sparks) |thrown| thrown.reset();
    if (world.particles) |pool| pool.reset();
    if (world.smoke) |pools| pools.reset();
    if (world.gun_particles) |pools| pools.reset();
    all.missiles.reset(all.gpa);
    if (world.trails) |trails| trails.reset();
    if (world.rays) |rays| rays.reset();
    if (world.tractors) |tractors| tractors.reset();
    if (world.rippers) |rippers| rippers.reset();
    if (world.jump_effects) |effects| effects.reset();
    if (world.atmospheres) |atmospheres| atmospheres.reset();
    if (world.escort_marker) |marker| marker.reset();
    if (world.radio) |radio| radio.reset(if (world.hearing) |hearing| hearing.sound else null);
    world.player.remarks = .{};
    world.player.friendly_fire = .{};
    if (world.flash) |lit| lit.* = .{};
    start.display.interference = .{};
    start.display.caption = .{};
    start.display.objectives.reset(number, all.mission25_second_part);
    if (world.countermeasures) |dropped| dropped.reset();
    all.reset(world.random);
    // The shell and the debris, counted as used so the sweep below keeps them.
    if (all.bullets.looks) |looks| looks.loadShell(all, types);
    if (world.explosions) |explosions| explosions.debris = .load(all, types);

    if (world.hearing) |hearing| sound3d.endAll(hearing.sound);
    world.player.ending = .playing;
    world.player.terminated = 0;
    if (world.environment) |environment| environment.resetEffects();
    if (world.gates) |gates| gates.reset();
    world.player.showing = .everything;
    world.player.rescue_odds = .{};
    world.player.carrier = null;
    world.player.cutaway = .none;
    world.player.yamato_launch = .{};
    world.player.jumping_in = false;
    world.player.flyback = .{};
    world.player.primary_target = null;
    world.player.scanner = .{};
    if (world.camera) |view| {
        view.view = .cockpit;
        view.object = all.player;
        view.locked = false;
        view.cockpit_mode = view.setting.mode();
    }
    winmain.startMission(world.player, if (start.campaign) |campaign| campaign.kept(number).kills else 0);
    all.mission_number = number;
    var file_buffer: [winmain.mission_path_size]u8 = undefined;
    const mission = scriptMission(&file_buffer, all, number);
    const loaded = try Loaded.create(gpa, image, world.random);
    errdefer loaded.destroy();
    loaded.script.variables = if (start.campaign) |campaign| campaign.attempt() else gameflow.restartPoint();
    loaded.script.variables.players = all.players;
    orders.world.mission = &loaded.bound;
    orders.world.events = &loaded.events;
    if (all.scripts) |scripts| scripts.begin(orders, mission, scriptSeed(world.random, number));
    try loaded.start(orders);

    givePilots(all, number);
    startWing(all);
    _ = create.createObject(all, start.tables, types, null, .marker, 0, camera_marker_at, world.random) catch |err| {
        std.log.warn("the camera's marker is left out: {s}", .{@errorName(err)});
    };
    start.types.sweep(&all.types);
    // The schematics the target display last showed went with the types let go.
    start.display.target_pictures = .{};
    for (try loaded.bound.ships()) |ship| {
        if (std.math.cast(u8, ship.kind)) |kind| _ = types.load(types.context, kind);
    }
    start.clock.frameReset();

    const player = &all.slots[all.player];
    const player_type = all.slotType(all.player, if (try loaded.bound.file.player()) |record| @enumFromInt(record.kind) else player.object.type);
    try start.cockpit.load(start.types.resources, start.types.textures, player_type, start.types.models);
    start.display.ejected = false;
    fitDevices(start.display, player_type, if (player.type) |loaded_type| loaded_type.model.header.flags.cloak else false);
    start.display.missiles.build(&player.object);
    start.display.lock.reset();
    if (all.scripts) |scripts| scripts.started(mission);
    return loaded;
}

/// What the start does for the player's wing's pilots once the mission's script has started
/// (`0x00493DCC` to `0x00493E0A`): the wing's pilots brought up to date for mission `number`
/// (`pilots.Wingmen.update`), then, in a mission of the campaign out of the simulator, each of the
/// player's wingmen given the pilot of its place, Alpha 2 to 6 (`object_set_pilot`), in place of
/// the one the mission's records name, such as 45TH VOLUNTEERS.
///
/// **Fix:** a place of the wing no ship fills, the game gives a pilot to the object before the
/// first, writing through the pointer in front of the objects' table; OpenReliant gives none.
fn givePilots(all: *create.Objects, number: u16) void {
    all.wingmen.update(number);
    // The campaign's missions (`0x00493DE6` to `0x00493DED`).
    if (all.simulator.simulated() or number < gameflow.first_mission or number > gameflow.last_mission) return;
    for (all.wing[1..], all.wingmen.pilots()) |place, pilot| {
        const index = place orelse continue;
        pilots.setPilot(&all.slots[index].object, pilot);
    }
}

/// The seed of the mods' scripts' random numbers for mission `number`: the seed of the game's own
/// random numbers, which the scripts don't draw from, combined with the mission's number.
///
/// Not ported: `mission_start` seeds the game's own numbers with the time (`0x004936AE`)
/// ([#582](https://github.com/OpenReliant/openreliant/issues/582)).
pub fn scriptSeed(random: *const libcmt.Rand, number: u16) u64 {
    return @as(u64, random.seed) << 16 | number;
}

/// OpenReliant's: ends the mission `loaded` and lets it go. First the mods' scripts hear how it
/// ended (`hooks.Scripts.ended`): for the player (`player.ending`), and as the mission's script
/// rated it.
pub fn endMission(all: *create.Objects, player: *const input.Player, loaded: *Loaded) void {
    if (all.scripts) |scripts| scripts.ended(scriptOutcome(player, loaded));
    loaded.destroy();
}

/// OpenReliant's: mission `number` as the mods' scripts hear of it, its file's name written in
/// `buffer`: mission 25's second part where `all` has it flown.
pub fn scriptMission(buffer: *[winmain.mission_path_size]u8, all: *const create.Objects, number: u16) hooks.Mission {
    return .{ .number = number, .file = winmain.missionFileName(buffer, number, all.mission25_second_part) };
}

/// OpenReliant's: how the mission `loaded` ended as the mods' scripts hear of it: for the player
/// (`player.ending`), and as the mission's script rated it.
pub fn scriptOutcome(player: *const input.Player, loaded: *const Loaded) hooks.Outcome {
    return .{ .ending = player.ending, .rating = loaded.script.variables.mission_success };
}

/// Fits the display's devices to the player's ship, as the start does after `hud_init` has set
/// the display up: every ship carries an ECM, the ships of `player_ships` that say so spectral
/// shields and blind fire, and a ship whose model can cloak (`shp.Header.Flags.cloak`) a cloak.
/// Blind fire starts on where it is carried; elsewhere it is left as it was.
pub fn fitDevices(display: *hud.State, ship_type: gameobj.Type, can_cloak: bool) void {
    const ship = playerShip(ship_type);
    display.devices.getPtr(.ecm).setting = .off;
    const spectral = if (ship) |known| known.spectral_shields else false;
    display.devices.getPtr(.spectral_shields).setting = if (spectral) .off else .absent;
    display.devices.getPtr(.cloak).setting = if (can_cloak) .off else .absent;
    display.blind_fire_fitted = if (ship) |known| known.blind_fire else false;
    display.wire_frame = if (ship) |known| known.wire_frame else null;
    if (display.blind_fire_fitted) display.blind_fire = true;
}

test fitDevices {
    // The Shroud carries all three, and a cloak where its model has one.
    const shroud: gameobj.Type = @enumFromInt(10);
    var display: hud.State = .{ .blind_fire = false };
    fitDevices(&display, shroud, true);
    try std.testing.expectEqual(.off, display.devices.get(.spectral_shields).setting);
    try std.testing.expectEqual(.off, display.devices.get(.cloak).setting);
    try std.testing.expect(display.blind_fire_fitted and display.blind_fire);
    // Its twin is the same ship.
    try std.testing.expectEqual(playerShip(shroud), playerShip(@enumFromInt(0xFE)));
    // The Grendel carries only the ECM.
    fitDevices(&display, .grendel, false);
    try std.testing.expectEqual(.off, display.devices.get(.ecm).setting);
    try std.testing.expectEqual(.absent, display.devices.get(.spectral_shields).setting);
    try std.testing.expectEqual(.absent, display.devices.get(.cloak).setting);
    try std.testing.expect(!display.blind_fire_fitted);
    // A capital ship is none of the player's.
    try std.testing.expectEqual(null, playerShip(.yamato));
}

test startMission {
    const gpa = std.testing.allocator;
    const dte = @import("../../formats/dte.zig");
    const vm = @import("../vm.zig");
    // The start part: the player's flight group, then the other ship's, which fights the player.
    var routine: vm.machine.testing.Routine = .init(gpa);
    defer routine.deinit();
    for (0..2) |group| {
        try routine.op(.push_flight_group, &.{@intCast(group)});
        try routine.command("CreateFlightGroup");
    }
    try routine.op(.push_flight_group, &.{1});
    try routine.op(.push_byte, &.{@intCast(@intFromEnum(ai.orders.Order.fight))});
    try routine.op(.push_byte, &.{1});
    try routine.op(.push_ship, &.{0});
    try routine.command("SetAI");
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);
    // The player flies a torpedo, a type with a model but no schematic nor cockpit, and the other
    // is of a type the game names no model for.
    const torpedo: gameobj.Type = @enumFromInt(74);
    const modelless: gameobj.Type = @enumFromInt(14);
    var ships: [2]dte.Ship = undefined;
    for (&ships, [_]gameobj.Type{ torpedo, modelless }, 0..) |*ship, kind, index| {
        ship.* = dte.testing.ship(@intCast(index), @intCast(index), @intCast(kind.number()));
        ship.position = .{ 0, 0, @floatFromInt(index * 5000) };
    }
    const groups = [_]dte.FlightGroup{ dte.testing.flightGroup(0, .player), dte.testing.flightGroup(0, .none) };
    var part = std.mem.zeroes(dte.Part);
    part.flags.start = true;
    part.length = @intCast(code.len / @sizeOf(u16));
    var sections: dte.write.Sections = @splat(.{});
    dte.write.set(&sections, .ships, ships.len, std.mem.sliceAsBytes(&ships));
    dte.write.set(&sections, .flight_groups, groups.len, std.mem.sliceAsBytes(&groups));
    dte.write.set(&sections, .script, code.len / @sizeOf(u16), code);
    dte.write.set(&sections, .parts, 1, std.mem.asBytes(&part));
    const image = try dte.write.write(gpa, &sections, .{});

    // The game's files: the torpedo's model alone.
    var files: create.library.testing.Files = try .init(gpa, create.models.ship_types[torpedo.number()].model.?);
    defer files.deinit(gpa);
    var types: create.library.TypeCache = .{ .gpa = gpa, .resources = &files.resources, .textures = &files.textures.table, .looks = .{}, .global_palette = null };
    defer types.deinit();
    var shown: cockpit.Cockpit = .{};
    defer shown.deinit();
    var state: hud.State = .{ .ejected = true };
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    mission.player.rescue_odds = .{ .rescued = 1, .captured = 1, .killed = 1 };
    const loaded = try startMission(gpa, .{
        .orders = mission.orders(),
        .clock = &mission.clock,
        .tables = &mission.tables,
        .types = &types,
        .cockpit = &shown,
        .display = &state,
    }, image, 0);
    defer loaded.destroy();

    // The mission's ships in the first slots, the player's with its model, then the camera's marker.
    const all = mission.objects;
    try std.testing.expectEqual(3, all.count);
    // The script knows the mission is flown by one player, and has a new campaign's variables.
    try std.testing.expectEqual(all.players, loaded.script.variables.players);
    try std.testing.expectEqual(1, loaded.script.variables.players);
    try std.testing.expectEqual(1, loaded.script.variables.ghost_alive);
    try std.testing.expect(all.slots[0].type != null);
    try std.testing.expectEqual(gameobj.Type.marker, all.slots[2].object.type);
    try std.testing.expectEqual(camera_marker_at[2], all.slots[2].object.root.position.z);
    // The player's ship on its controls, and the other under the order the script gave it.
    try std.testing.expectEqual(ai.orders.Order.player_control, all.slots[0].orders[0].order);
    try std.testing.expectEqual(ai.orders.Order.fight, all.slots[1].orders[0].order);
    // The player first in the wing, the pilot always picked up, and the display readied.
    try std.testing.expectEqual(0, all.wing[0].?);
    try std.testing.expectEqual(100, mission.player.rescue_odds.rescued);
    try std.testing.expect(!state.ejected);
}

test missionFrame {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // The player's slot, then a ship that turns on the spot under an order of its own.
    for (0..2) |_| _ = try mission.add(.predator, @splat(0));
    const orders = mission.orders();
    try std.testing.expect(try aigeneric.push(orders, 1, .slow_rotate, .none));

    _ = missionFrame(orders, .{}, null);
    // The frame ran the ship's order, and framed every object where it is drawn.
    try std.testing.expect(mission.objects.slots[1].object.yaw_input > 0);
    try std.testing.expect(!mission.objects.slots[1].object.root.flags.unframed);
}

test "the simulation steps on every fourth tick" {
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // The world's clock is the one that ticks.
    const clock = &mission.clock;
    // A second of the timer: 100 ticks, 100 game ticks, 25 steps.
    clock.advanceTimer(100);
    try std.testing.expectEqual(100, clock.game_ticks);
    try std.testing.expectEqual(25, clock.runTicks(&devices, mission.world()));
    try std.testing.expectEqual(100, clock.mission_ticks);
    // The ticks already run are not run again.
    try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
}

test "a paused game stops its clocks but not the timer" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.advanceTimer(8);
    _ = clock.runTicks(&devices, mission.world());
    clock.paused = true;
    clock.advanceTimer(100);
    // The timer counts the paused ticks; the mission's clocks do not move.
    try std.testing.expectEqual(108, clock.timer_ticks);
    try std.testing.expectEqual(8, clock.game_ticks);
    try std.testing.expectEqual(8, clock.mission_ticks);
    try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
    // Paused ticks are counted only for the game ticks the loop asks for.
    clock.paused = false;
    clock.advanceTimer(4);
    try std.testing.expectEqual(1, clock.runTicks(&devices, mission.world()));
    try std.testing.expectEqual(12, clock.mission_ticks);
}

test "the step reads the keyboard, and the latches it clears" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const keyboard = &devices.keyboard;
    keyboard.down[scan_test_key] = true;
    keyboard.latched[scan_test_key] = true;
    // Three ticks do no work, so the latch stands; the fourth reads and keeps it while held.
    clock.advanceTimer(3);
    _ = clock.runTicks(&devices, mission.world());
    try std.testing.expect(keyboard.latched[scan_test_key]);
    clock.advanceTimer(1);
    try std.testing.expectEqual(1, clock.runTicks(&devices, mission.world()));
    try std.testing.expect(keyboard.latched[scan_test_key]);
    // Released, the next read clears it.
    keyboard.down[scan_test_key] = false;
    clock.advanceTimer(4);
    _ = clock.runTicks(&devices, mission.world());
    try std.testing.expect(!keyboard.latched[scan_test_key]);
}

const scan_test_key: u8 = 0x10;

test "play time rolls a second over after 101 ticks" {
    var clock: Clock = .{};
    clock.advanceTimer(101);
    try std.testing.expectEqual(0, clock.play.ticks);
    try std.testing.expectEqual(1, clock.play.seconds);
    // A minute takes 60 of those seconds, and an hour 60 minutes.
    clock.advanceTimer(101 * 59);
    try std.testing.expectEqual(0, clock.play.seconds);
    try std.testing.expectEqual(1, clock.play.minutes);
    clock.advanceTimer(101 * 60 * 59);
    try std.testing.expectEqual(0, clock.play.minutes);
    try std.testing.expectEqual(1, clock.play.hours);
}

test "a frame measures the ticks since the last one" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.advanceTimer(10);
    _ = clock.runTicks(&devices, mission.world());
    clock.frameBegin();
    try std.testing.expectEqual(10, clock.frame_duration);
    try std.testing.expectEqual(10, clock.frameTicks());
    try std.testing.expectEqual(10, clock.frame_start);
    // A frame with no tick between takes no time.
    clock.frameBegin();
    try std.testing.expectEqual(0, clock.frame_duration);
    clock.advanceTimer(3);
    _ = clock.runTicks(&devices, mission.world());
    clock.frameReset();
    try std.testing.expectEqual(13, clock.frame_start);
    try std.testing.expectEqual(0, clock.frame_duration);
}

test "the clocks keep to the platform's count however the frames fall" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const began: u64 = 12_345;
    clock.start(began);
    // Frames of uneven length: several shorter than a tick, one spanning many, one long stall.
    const frames = [_]u64{ 1, 0, 3, 1, 0, 0, 7, 2, 500, 1, 4, 0, 1 };
    var steps: u32 = 0;
    var now = began;
    for (frames) |frame| {
        now += frame;
        clock.advanceTo(now);
        steps += clock.runTicks(&devices, mission.world());
    }
    // Every hundredth between the first count and the last is a tick, and every fourth a step.
    const elapsed: u32 = @intCast(now - began);
    try std.testing.expectEqual(520, elapsed);
    try std.testing.expectEqual(elapsed, clock.timer_ticks);
    try std.testing.expectEqual(elapsed, clock.game_ticks);
    try std.testing.expectEqual(@as(i32, @intCast(elapsed)), clock.mission_ticks);
    try std.testing.expectEqual(elapsed / 4, steps);
    // Frames shorter than a tick neither run one nor lose one: the count rules.
    try std.testing.expectEqual(now, clock.timer_at);
}

test "starting the clocks again keeps the timer's counts running" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.start(0);
    clock.advanceTo(300);
    _ = clock.runTicks(&devices, mission.world());
    // A new loop starts the clocks again: the mission's from zero, the timer's running on, and the
    // loop owing no ticks.
    clock.start(5_000);
    try std.testing.expectEqual(300, clock.timer_ticks);
    try std.testing.expectEqual(300, clock.game_ticks);
    try std.testing.expectEqual(0, clock.mission_ticks);
    try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
    // From there, the ticks count on from both.
    clock.advanceTo(5_004);
    _ = clock.runTicks(&devices, mission.world());
    try std.testing.expectEqual(304, clock.game_ticks);
    try std.testing.expectEqual(4, clock.mission_ticks);
}

test "the frame rate is decoupled from the tick rate" {
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    // The same second of play, drawn at three very different frame rates.
    const rates = [_]u64{ 4, 60, 240 };
    for (rates) |frames| {
        var clock: Clock = .{};
        clock.start(1_000);
        var steps: u32 = 0;
        var drawn: u32 = 0;
        for (1..frames + 1) |frame| {
            // Frame `frame` of `frames` ends this far into the second, in hundredths.
            clock.advanceTo(1_000 + @as(u64, @intCast(frame)) * 100 / frames);
            steps += clock.runTicks(&devices, mission.world());
            clock.frameBegin();
            drawn += 1;
        }
        // However often it drew, a second of play is 100 ticks and 25 simulation steps.
        try std.testing.expectEqual(frames, drawn);
        try std.testing.expectEqual(100, clock.game_ticks);
        try std.testing.expectEqual(100, clock.mission_ticks);
        try std.testing.expectEqual(25, steps);
    }
}

test "a frame faster than the tick runs none, and a slow one runs the lot" {
    var clock: Clock = .{};
    var devices: input.Devices = .{};
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    clock.start(0);
    // Four frames inside one hundredth: no tick falls in them, so the simulation stands still.
    for (0..4) |_| {
        clock.advanceTo(0);
        try std.testing.expectEqual(0, clock.runTicks(&devices, mission.world()));
        clock.frameBegin();
        try std.testing.expectEqual(0, clock.frame_duration);
    }
    // One frame that took a quarter of a second catches up all 25 ticks at once.
    clock.advanceTo(25);
    try std.testing.expectEqual(6, clock.runTicks(&devices, mission.world()));
    clock.frameBegin();
    try std.testing.expectEqual(25, clock.frame_duration);
}

test avoidanceScan {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    const ship = try mission.addOther(@splat(0));
    const hull = try mission.addOther(.{ 0, 0, 10000 });
    const ahead = try mission.addOther(.{ 0, 0, 3000 });
    const far = try mission.addOther(.{ 0, 0, 900000 });
    // The player's ship, which `addOther` puts first, out of the way.
    objects.setPosition(&mission.slot(0).object, &mission.slot(0).drawn, .{ 500000, 0, 0 });
    mission.slot(hull).object.flags.components = true;
    mission.slot(hull).object.radius = 1000;
    mission.slot(ship).object.velocity = .{ .x = 0, .y = 0, .z = 50 };
    // Without an order that avoids, nothing is listed.
    avoidanceScan(world, ship);
    try std.testing.expectEqual(0, mission.slot(ship).object.avoid_near.count);
    // Flying, the hull within its widened reach and the ship ahead it would meet are, but not the
    // far one.
    _ = try aigeneric.pushShip(mission.orders(), ship, .fly, far, null);
    avoidanceScan(world, ship);
    try std.testing.expectEqualSlices(i32, &.{hull}, mission.slot(ship).object.avoid_near.list());
    try std.testing.expectEqualSlices(i32, &.{ahead}, mission.slot(ship).object.avoid_ahead.list());
}

test givePilots {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    _ = try mission.add(.predator, .{ 0, 0, 0 });
    const wingman = try mission.add(.predator, .{ 0, 0, 100 });
    all.wing = @splat(null);
    all.wing[0] = 0;
    all.wing[1] = wingman;
    // In mission 2, Alpha 2 takes the wing's pilot of its place, Frenchy.
    givePilots(all, 2);
    try std.testing.expectEqual(pilots.new_wing[1], all.slots[wingman].object.pilot);
    // In the simulator, the ships keep the pilots their records name.
    all.slots[wingman].object.pilot = 0;
    all.simulator.mode = .training;
    givePilots(all, 2);
    try std.testing.expectEqual(0, all.slots[wingman].object.pilot);
}
