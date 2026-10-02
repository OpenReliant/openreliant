//! `openreliant`: the engine, on SDL3 in place of Win32 and DirectX. It has no data of its own: it
//! runs in the directory of an installed copy of StarLancer, or in the one given, and reads
//! `resource.hog` and the texture cache from it as the game does. `openreliant install` installs
//! the game's files from its discs; see `install.zig`.
//!
//! It plays a mission, which pauses into the game's menu as each attempt ends, to be flown again:
//! by default mission 0, OpenReliant's own sandbox (`mission0.zig`), which it carries, or the
//! game's mission `--mission` names. It draws through Surrender's pipeline and its Direct3D driver
//! with the GPU, or onto the software device, from the camera's views, which the game's camera keys
//! pick and steer. Added for OpenReliant: the test keys (`test_keys.zig`), and Alt and Enter, which
//! switch to the full screen and back. Escape opens the game's pause menu, whose LEAVE MISSION
//! quits.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const stats = openreliant.stats;
const tcache = openreliant.tcache;
const tga = openreliant.tga;
const spr = openreliant.spr;
const engine = openreliant.engine;
const math = engine.surrender.math;
const srapi = engine.surrender.surrenderlib.srapi;
const srcore = engine.surrender.surrenderlib.srcore;
const srtexture = engine.surrender.surrenderlib.srtexture;
const srd3d = engine.surrender.srd3d;
const game = engine.game;
const save = game.gameflow.save;
const camera = game.camera;
const help = @import("help.zig");
const install = @import("install.zig");
const joysticks = @import("joysticks.zig");
const mission0 = @import("mission0.zig");
const missions = @import("missions.zig");
const Movies = @import("movies.zig").Movies;
const presenting = @import("presenter.zig");
const Presenter = presenting.Presenter;
const Screen = presenting.Screen;
const drawn = presenting.drawn;
const Rooms = @import("rooms.zig").Driver;
const RoomsEnd = @import("rooms.zig").End;
const test_keys = @import("test_keys.zig");
const version = @import("version.zig");
const options_page = @import("options.zig");
const Options = options_page.Options;
const settings_module = @import("settings.zig");

/// Writes `text` to standard output, for a command that only says something: 0, its exit status.
fn say(io: Io, text: []const u8) !u8 {
    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.flush();
    return 0;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "install")) return install.main(init.io, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "joysticks")) return joysticks.main(init.io, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "missions")) return missions.main(init.io, arena, args[2..]);
    const io = init.io;
    const asked = switch (Options.parse(args[1..], .{})) {
        .play => |options| options,
        .help => return say(io, options_page.help_page),
        .version => return say(io, "openreliant " ++ version.string ++ "\n"),
        .wrong => |problem| {
            std.debug.print("openreliant: {f}\nRun 'openreliant --help' to see the options.\n", .{problem});
            return 2;
        },
    };
    const directory = switch (try install.openGame(io, .cwd(), asked.directory)) {
        .game => |opened| opened,
        .no_folder => return missingGameFiles(asked.directory, null),
        .missing => |name| return missingGameFiles(asked.directory, name),
    };
    defer directory.close(io);
    // The game's settings file, which `load_key_config` reads the input settings from and the pause
    // menu's screens write to. If it's missing, every setting keeps its default.
    var settings_file: engine.profile.File = .{ .arena = arena, .profile = .read(io, arena, directory) };
    // OpenReliant's own options: those the settings file keeps, then the command line's. A
    // screenshot leaves the file's out, so that it comes out the same for everyone.
    var kept: Options = .{};
    if (asked.screenshot == null) settings_module.read(settings_file.profile, &kept);
    const options = switch (Options.parse(args[1..], kept)) {
        .play => |options| options,
        // Read the same way again, the command line asks for nothing else.
        .help, .version, .wrong => asked,
    };
    run(io, init.gpa, arena, options, directory, &settings_file) catch |err| switch (err) {
        error.MissingMission => return 1,
        else => return err,
    };
    return 0;
}

/// Opens the controller the game should use, unless it is already open, and loads the input
/// settings and bindings, which depend on the controller. The original does this once at startup in
/// `input_init` and `load_key_config`; OpenReliant also does it whenever a controller is connected
/// or disconnected. `platform.joystick.choose` selects the controller, and the rest of
/// `JoyConfig`'s setup (`platform.joystick.Setup`) configures a joystick's throttle and twist axes.
fn connectController(arena: Allocator, devices: *engine.input.Devices, controller: *?platform.joystick.Controller, settings_file: engine.profile.Profile) void {
    const joystick = platform.joystick;
    const setup: joystick.Setup = .read(settings_file);
    const found = joystick.attached(arena) catch &.{};
    const chosen = joystick.choose(found, setup.preference);
    if (controller.*) |*open| {
        if (chosen != null and chosen.?.id == open.id() and devices.joystick.device != null) return;
        devices.joystick.close();
        open.close();
        controller.* = null;
    }
    if (chosen) |which| {
        controller.* = joystick.Controller.open(which, setup) catch null;
        if (controller.*) |*open| devices.joystick.open(open.device(), game.interface.deadZone(settings_file));
    }
    game.interface.loadKeyConfig(devices, settings_file);
}

/// Says that `directory` holds no installed copy of the game, and what the engine needs; exit
/// status 1.
fn missingGameFiles(directory: []const u8, file: ?[]const u8) u8 {
    if (file) |name| {
        std.debug.print("openreliant: {s} is missing from {s}.\n", .{ name, directory });
    } else {
        std.debug.print("openreliant: there is no directory {s}.\n", .{directory});
    }
    std.debug.print(
        \\OpenReliant is an engine only: it plays the files of a legally obtained copy of
        \\StarLancer. Run it in the directory the game is installed in, or name that directory:
        \\
        \\    openreliant <game-directory>
        \\
        \\To install the game's files from your StarLancer discs:
        \\
        \\    openreliant install <game-directory>
        \\
    , .{});
    return 1;
}

/// The window's size in points as it opens, which the software device draws at until the first
/// frame takes the window's own. OpenReliant's: the original took the display mode `[Device]` names.
const initial_size = [2]u32{ 1280, 720 };

/// The voices `WinMain` asks `sound_init` for (`0x004A9421`).
const sound_voices = 10;

comptime {
    // The platform counts the game's ticks.
    std.debug.assert(platform.window.tick_nanoseconds * game.main.ticks_per_second == std.time.ns_per_s);
}

/// One of the game's files in its folder `directory`, whole, into `arena`: a mod's file of its name
/// first (`game.bigfile.Mods.readLoose`).
fn readGameFile(io: Io, arena: Allocator, directory: Io.Dir, mods: *const game.bigfile.Mods, name: []const u8) ![]u8 {
    return try mods.readLoose(io, arena, directory, name, .limited(engine.files.max_file_size)) orelse error.FileNotFound;
}

/// The strings of the module `name` in the game's folder `directory`, as `language_init` reads them
/// (`game.language.Language.load`).
fn readStrings(io: Io, arena: Allocator, directory: Io.Dir, mods: *const game.bigfile.Mods, name: []const u8) !game.language.Language {
    return .load(arena, try .parse(try readGameFile(io, arena, directory, mods, name)));
}

/// The records of the stats table `table`, from its file in the game's folder `directory`, as its
/// loader reads them (`stats_load_ships` and the others).
fn readStats(io: Io, arena: Allocator, directory: Io.Dir, mods: *const game.bigfile.Mods, comptime table: stats.Table) ![]align(1) const stats.Table.Record(table) {
    const file = try stats.File.parse(table, try readGameFile(io, arena, directory, mods, table.fileName()));
    return @field(file, @tagName(table));
}

/// Plays from the game's folder `directory`, with its settings file `settings_file`, which the
/// pause menu's screens write to.
fn run(io: Io, gpa: Allocator, arena: Allocator, options: Options, directory: Io.Dir, settings_file: *engine.profile.File) !void {
    // OpenReliant's mods, whose files come before the game's own wherever it keeps them; none with
    // `--no-mods`.
    var mods: game.bigfile.Mods = if (options.mods) try .open(arena, io, directory) else .none;
    defer mods.close(arena);
    // What `WinMain` opens at start-up, and the texture cache `renderer_start` opens.
    var resources: game.bigfile.Hog = try .open(arena, io, directory, game.bigfile.resource_name);
    defer resources.close(arena);
    resources.mods = &mods;
    const cache_bytes = try readGameFile(io, arena, directory, &mods, tcache.hardware_name);
    const cache: tcache.Cache = try .parse(arena, cache_bytes);
    const palette = try tga.palette(try resources.readFile(arena, "palette.tga"));
    // What `WinMain` reads from `[Device]`: the options' cockpit setting, the brightness, which
    // the renderer starts with, whether the transitions play, and the renderer's details, which a
    // screenshot takes at their highest, so that it comes out the same for everyone.
    var device_settings: game.winmain.Device = .read(settings_file.profile);
    if (options.screenshot != null) device_settings.details = .{};
    const details = device_settings.details;
    // The textures, the mods' pictures in place of the cache's images, made in `gpa`, since a large
    // picture's reading leaves much behind, each fitted to the texture detail.
    var textures: srtexture.Table = .init(gpa, cache, palette);
    defer textures.deinit();
    textures.files = mods.pictures();
    textures.largest = details.texture.largest();
    // The flight and combat stats `stats_load_ships` reads; every gun type's figures, which
    // `stats_load_guns` reads; every missile type's, which `stats_load_missiles` reads; and the
    // pilots'.
    const ship_stats = try readStats(io, arena, directory, &mods, .ships);
    const gun_stats = try readStats(io, arena, directory, &mods, .guns);
    const missile_stats = try readStats(io, arena, directory, &mods, .missiles);
    const pilot_stats = try readStats(io, arena, directory, &mods, .pilots);
    // The strings `language_init` reads out of `language.dll` at start-up, and those the ITAC reads
    // out of `itaclang.dll` as it opens, which without it writes nothing.
    const strings = try readStrings(io, arena, directory, &mods, game.language.file_name);
    const itac_strings = readStrings(io, arena, directory, &mods, game.itac.strings_name) catch |err| blank: {
        std.log.warn("{s} is left out: {s}", .{ game.itac.strings_name, @errorName(err) });
        break :blank game.language.Language{ .strings = &.{} };
    };

    var window: platform.window.Window = try .open("OpenReliant", initial_size[0], initial_size[1], options.fullscreen);
    defer window.close();
    // The device the driver draws with, and the driver.
    const screen = try arena.create(Screen);
    screen.* = if (options.software)
        .{ .software = try .init(arena, initial_size[0], initial_size[1]) }
    else
        .{ .gpu = try .init(gpa, window.gpu, window.handle, options.settings) };
    defer switch (screen.*) {
        .gpu => |*device| device.deinit(),
        .software => |*device| device.deinit(arena),
    };
    var driver: srd3d.srd3d.Driver = try .init(arena, screen.interface());
    defer driver.deinit();
    var pacer: platform.window.Pacer = .{};
    // How the frames are paced, which the settings screen changes as the game plays.
    var pacing = options.pacing();

    var context: srapi.Context = .{
        .projection = (camera.Camera{}).projection(initial_size[0], initial_size[1]),
        .detail = game.main.detailDivisor(details.graphic),
        .finer = options.detail_reach.finer(),
        .budget = options.draw_budget.limit(),
    };
    var devices: engine.input.Devices = .{};
    // As `WinMain` starts, the keys named as the keyboard's layout names them (`key_names_rename`,
    // `0x004A8F82`).
    platform.keyboard.nameKeys(&devices.key_names);
    // `default.txt`, the bindings `key_config_defaults` starts from, a mod's in its place; without
    // it, the executable's own.
    devices.defaults_file = if (readGameFile(io, arena, directory, &mods, game.interface.defaults_name)) |text| .{ .text = text } else |err| none: {
        std.log.warn("{s} is left out: {s}", .{ game.interface.defaults_name, @errorName(err) });
        break :none null;
    };
    // The characters typed into the window, which its procedure queues (`WM_CHAR`).
    var typed: game.winmain.Typed = .{};
    // Sound: Miles's calls, played by OpenAL Soft or OpenReliant's own mixer through SDL3's audio,
    // with the voices `WinMain` asks `sound_init` for, the volumes of `[Sound]`, and the 3D
    // provider it opens; silent where there is no device, or with `--no-sound`.
    const output: ?*platform.audio.Output = if (options.sound) |chosen| platform.audio.Output.create(gpa, chosen) catch |err| none: {
        std.log.warn("playing without sound: {s}", .{@errorName(err)});
        break :none null;
    } else null;
    defer if (output) |open| open.destroy();
    const sound = try arena.create(game.hog_snd.Sound);
    sound.init(if (output) |open| open.driver() else null, sound_voices, .{ .gpa = gpa, .io = io, .dir = directory, .mods = &mods });
    defer sound.shutdown();
    sound.volumes = .read(settings_file.profile);
    context.brightness = device_settings.brightness;
    // What draws the frames outside the game's loop: the movies', and the loading screens'.
    var presenter: Presenter = .{ .window = &window, .screen = screen, .driver = &driver, .context = &context, .wanted = options.settings.size, .arena = arena };
    defer presenter.close(gpa);
    // Whether what moves is drawn between the game's ticks, which the settings screen changes as
    // the game plays.
    var smooth_motion = options.smooth_motion;
    // OpenReliant's own options as the settings screen shows and changes them.
    var own: settings_module.Own = .{
        .settings_file = settings_file,
        .output = output,
        .sound = options.sound,
        .pacing = &pacing,
        .display = .{ .window = &window, .presenter = &presenter },
        .graphics = settings_module.graphicsOf(options, details),
        .smooth_motion = &smooth_motion,
    };
    // The screenshots the 0 key saves in flight and O in the briefing, in the game's folder.
    var screenshots: game.xtrabits.screenshot.Screenshots = .{ .io = io, .directory = directory };
    defer screenshots.finish();
    // The movies: FFmpeg's decoders behind the stand-in for Bink, and what plays them in a loop of
    // their own. As the renderer first starts, before its loading screens, `renderer_load` plays the
    // intro; a mission `--mission` names, or a screenshot, starts without it.
    var decoders: platform.video.Decoders = .init();
    // The discs' archives, which a full install keeps in the game's folder (`cd_hog_open`), and
    // the hangar's movie played last (`hangar_movie_last`, `0x005D6C8C`).
    var disc: game.interface.disc.Disc = .{ .gpa = gpa, .io = io, .directory = directory, .mods = &mods };
    defer disc.close();
    var hangar: game.xtrabits.movie.Hangar = .{};
    var movies: Movies = .{
        .gpa = gpa,
        .codec = decoders.codec(),
        .sound = if (output) |open| open.driver() else null,
        .presenter = &presenter,
        .devices = &devices,
        .pacer = &pacer,
        .pacing = &pacing,
        .size = options.movie_size,
        .look = options.movie_look,
        .transitions = device_settings.transitions,
        .hardware = !options.software,
        .disc = &disc,
        .typed = &typed,
    };
    if (options.intro and options.mission == null and options.screenshot == null) {
        for (game.xtrabits.movie.intro) |name| _ = try movies.play(name, .cleared) orelse return;
    }
    // The outline fonts that draw the interface's text at the window's resolution, through
    // FreeType: Newtown, built in, and the mods' fonts in their places. The bitmap fonts alone with
    // `--bitmap-fonts`, or where FreeType doesn't start.
    var free_type: ?platform.fonts.FreeType = if (options.outline_fonts) platform.fonts.FreeType.init() catch null else null;
    defer if (free_type) |*library| library.deinit();
    var outlines: game.hud.outline.Outlines = .init(gpa, if (free_type) |*library| library.rasterizer() else null, &mods);
    defer outlines.deinit();
    // The loading screen the renderer's start shows as the game loads, and each mission's start
    // after it: the picture alone, then with LOADING before each part of the game it loads.
    var loading: Loading = .{
        .resources = try .open(gpa, resources, &outlines),
        .archive = &resources,
        .presenter = &presenter,
        .strings = &strings,
        .splash = options.loading_splash,
    };
    defer loading.close();
    try loading.show(game.xtrabits.loading.startup_first);
    try loading.show(game.xtrabits.loading.startup_step);
    var rand: engine.libcmt.Rand = .{};
    const space = try game.backdrop.Backdrop.create(arena, &textures, try game.matmanager.readPixels(arena, resources, game.backdrop.star_map_name), &rand, context.projection.near, options.sun);
    const sky = try game.nebula.Sky.create(arena, &textures, try game.matmanager.readPixels(arena, resources, game.nebula.dome_image_name));
    try sky.select(&textures, game.nebula.default_nebula, &space.lights);
    // What the mission's script asks of its space: the nebula it shows, and the effects it turns
    // on.
    var environment: game.environfx.Environment = .{ .sky = sky, .textures = &textures, .space = space };

    try loading.show(game.xtrabits.loading.startup_step);
    // The engine glows every ship's thrusters burn, built once and shared by them all.
    const glows: game.environfx.Glows = try .create(arena, &textures);
    // The muzzle flashes' flares, built with the shots' looks (`guns_init`).
    const flashes: game.guns.flash.Looks = try .create(arena, &textures, options.flashes);
    // The radar's backing, which the cockpit's view draws under the radar.
    const backing = try game.main.RadarBacking.create(arena, &textures);
    // The display's shapes, whose global palette the ships' schematics are drawn with too.
    const shapes = try spr.Sprite.parse(try resources.readFile(arena, game.hud.hardware_shapes));
    const global_palette = game.hud.globalPalette(shapes);
    // The ship types' stats as `stats_load_ships` leaves them, their models, loaded as the objects
    // need them, and the cockpit a mission's start loads for the player's ship.
    const tables = try arena.create(game.create.Stats);
    tables.* = .initial;
    tables.load(ship_stats);
    var cockpit: game.main.cockpit.Cockpit = .{};
    defer cockpit.deinit();
    var types: game.create.library.TypeCache = .{
        .gpa = gpa,
        .resources = &resources,
        .textures = &textures,
        .light_maps = details.light_maps,
        .looks = .{ .light_sprites = try .load(&textures), .glows = &glows, .flashes = &flashes },
        .global_palette = global_palette,
    };
    defer types.deinit();
    // The objects, every slot standing in until a mission's start makes them, with every gun's,
    // missile's and pilot's figures; the loadout's ship, where one is chosen.
    const objects = try game.create.Objects.create(gpa, &rand);
    defer objects.destroy();
    objects.gun_stats.load(gun_stats);
    objects.missile_stats.load(missile_stats);
    objects.pilots.load(pilot_stats);
    if (options.ship) |ship| objects.loadout_ships[objects.player] = @enumFromInt(ship);
    // What the shots are drawn with, built once (`guns_init`); the Turret Flak's shell is loaded as
    // each mission starts.
    objects.bullets.looks = try game.guns.Looks.create(arena, &textures);
    objects.bullets.shot_lights = options.shot_lights;
    own.shot_lights = &objects.bullets.shot_lights;
    var player: engine.input.Player = .{};
    // The joystick or gamepad the game uses, opened as `input_init` opens a joystick, and again
    // whenever a controller is connected or disconnected.
    try platform.joystick.init(.game);
    defer platform.joystick.deinit();
    _ = platform.joystick.addMappings(try std.fs.path.joinZ(arena, &.{ options.directory, platform.joystick.mappings_name }));
    var controller: ?platform.joystick.Controller = null;
    defer if (controller) |*open| open.close();
    // A screenshot reads no controls, so that it comes out the same whatever is plugged in.
    if (options.screenshot == null) connectController(arena, &devices, &controller, settings_file.profile);

    try loading.show(game.xtrabits.loading.startup_step);
    // The radio's lines, from the game's speech archive, said through the sound's speech sample,
    // and the films of the speakers' faces.
    var radio: game.videoreports.Radio = .open(gpa, io, directory, &mods);
    defer radio.deinit(sound);
    radio.style = options.speech;
    sound.objects = objects;
    sound.missile_sound = options.missile_sound;
    // `bank_stdsmp`, which the positional sounds of a frame play from, and `smp3d.fat`, which the
    // 3D sounds do.
    const stdsmp = try openreliant.fat.Bank.parse(try resources.readFile(arena, "stdsmp.fat"));
    sound.betty = try openreliant.fat.Bank.parse(try resources.readFile(arena, "betty.fat"));
    sound.stdsmp = stdsmp;
    sound.open3D(try openreliant.fat.Bank.parse(try resources.readFile(arena, "smp3d.fat")));

    // The camera, which keeps the options' cockpit setting and starts in the cockpit mode it picks,
    // as a mission's start does.
    const cockpit_setting = options.cockpit orelse device_settings.view;
    var view: camera.Camera = .{ .setting = cockpit_setting, .cockpit_mode = cockpit_setting.mode(), .missiles = &objects.missiles };
    // The game's video settings, which the settings screen's video changes.
    const video_settings: game.interface.settings.Video = .{ .camera = &view, .surrender = &context, .gamma = screen.interface().setsGamma(), .transitions = &movies.transitions };
    var last_view = view.view;
    // The mission's clocks, which `mission_run` zeroes before it loops.
    var clock: game.main.Clock = .{};
    clock.start(platform.window.ticks());
    const hearing: game.hog_snd.Hearing = .{ .sound = sound, .camera = &view.place, .clock = &clock };
    try loading.show(game.xtrabits.loading.startup_step);
    // What the explosions leave for the frames after them, and the particles they send out.
    var explosions: game.explode.Explosions = try .init(gpa, try .load(&textures));
    defer explosions.deinit();
    explosions.settings.detail = details.graphic;
    explosions.settings.debris_lights = options.debris_lights;
    explosions.settings.bit_pool = options.bit_pool;
    explosions.settings.fireballs = options.fireballs;
    explosions.settings.uber = options.uber;
    var particles: game.particles.Pool = try .load(gpa, &textures, .standard, .{ .distant = options.distant });
    defer particles.deinit();
    // The damaged ships' smoke, from pools of its own.
    var smoke: game.main.smoke.Pools = try .load(gpa, &textures, .{ .distant = options.distant, .variety = options.smoke });
    defer smoke.deinit();
    var gun_particles: game.guns.effects.Pools = try .load(gpa, &textures, .{ .distant = options.distant });
    defer gun_particles.deinit();
    var shockwaves: game.shockwave.Shockwaves = try .create(gpa, &textures, options.rings);
    defer shockwaves.deinit(gpa);
    var trails: game.missiles.trail.Trails = .init(gpa, try .load(&textures));
    defer trails.deinit();
    var rays: game.erayfx.Rays = try .init(gpa, &textures);
    defer rays.deinit();
    var tractors: game.tractor.Tractors = try .init(gpa, &textures);
    defer tractors.deinit();
    tractors.glow = options.beam_glow;
    var rippers: game.airipper.Rippers = try .init(gpa, &textures);
    defer rippers.deinit();
    var jump_effects: game.jump.effect.Effects = undefined;
    try jump_effects.init(gpa, &textures, context.hardware);
    defer jump_effects.deinit();
    jump_effects.lighting = options.jump_light;
    rippers.glow = options.beam_glow;
    var atmospheres: game.create.atmosphere.Atmospheres = try .init(gpa, &textures);
    defer atmospheres.deinit();
    atmospheres.style = options.atmospheres;
    var flash: game.main.flash.Flash = .{};
    // The countermeasures' model, read once for the whole run, as `decoys_init` reads it.
    var effects_models: game.create.library.MountCache = .{ .gpa = arena, .resources = &resources, .textures = &textures, .light_maps = details.light_maps };
    var countermeasures: game.cloak.Countermeasures = .init(gpa, effects_models.mounts());
    defer countermeasures.reset();
    const lock_rings: *game.main.lock.Rings = try .create(gpa, &textures);
    defer lock_rings.destroy(gpa);
    const escort_marker: *game.create.escort.Marker = try .create(gpa);
    defer escort_marker.destroy(gpa);
    const chase_objects: *game.hud.chase.Chase = try .create(gpa, &textures);
    defer chase_objects.destroy(gpa);
    var sparks: game.sparks.Sparks = try .create(gpa, &textures);
    defer sparks.deinit();
    var shields: game.shield.Shields = try .create(gpa, &textures, explosions.settings.detail, context.hardware, options.shields);
    defer shields.deinit(gpa);
    environment.ice_field = try .create(arena, &textures, explosions.settings.detail, options.ice_field, &rand);
    var gates: game.wgate.Gates = try .init(gpa, &textures, explosions.settings.detail, context.hardware, options.gates);
    defer gates.deinit();
    // The force feedback's effects, and what plays them on the player's controller.
    const found_forces = engine.input.force.load(io, arena, directory, &mods);
    var lacking = found_forces.lacking.iterator();
    while (lacking.next()) |effect| std.log.warn("forces\\{s} is missing or isn't an effect file: it plays nothing", .{effect.fileName()});
    var force_feedback: engine.input.force.Forces = .{ .library = &found_forces.library, .settings = options.forces };
    // What the objects run in, the camera's view brought up to date each frame.
    var world: game.gameobj.World = .{ .forces = &force_feedback, .objects = objects, .player = &player, .clock = &clock, .view = view.view, .shake = &view.hit_shake, .random = &rand, .difficulty = options.difficulty orelse .medium, .hangar_beacons = options.hangar_beacons, .touchdown = options.touchdown, .hearing = hearing, .camera = &view, .explosions = &explosions, .particles = &particles, .smoke = &smoke, .gun_particles = &gun_particles, .shockwaves = &shockwaves, .trails = &trails, .countermeasures = &countermeasures, .sparks = &sparks, .shields = &shields, .rays = &rays, .tractors = &tractors, .rippers = &rippers, .jump_effects = &jump_effects, .atmospheres = &atmospheres, .escort_marker = escort_marker, .flash = &flash, .spawn = .{ .tables = tables, .types = types.types() }, .environment = &environment, .radio = &radio, .gates = &gates };

    // The pause menu, which stands in the display's place while the game is paused.
    var pause_menu: game.hudoptions.PauseMenu = .{};
    defer pause_menu.close();
    // The head-up display: what it draws with, and what draws it over the finished scene.
    var display: Display = .{
        .resources = try .load(arena, resources, shapes),
        .edge_line = options.edge_line,
        .gpa = arena,
        .device = undefined,
        .screen = .{ 0, 0 },
        .objects = objects,
        .play = undefined,
        .clock = &clock,
        .player = &player,
        .view = &view,
        .radio = &radio,
        .random = &rand,
        .strings = &strings,
        .pause_menu = &pause_menu,
        .devices = &devices,
        .settings = .{
            .file = settings_file,
            .sound = sound,
            .video = video_settings,
            .own = own.interface(),
        },
    };
    world.display = &display.state;

    // The mission `--mission` names, read once from the game's files, or for mission 0, where the
    // game has none, from the copy `openreliant` carries, and started; it starts again as each
    // attempt ends. Without it, the front end picks the mission.
    var play: Play = .{
        .gpa = gpa,
        .number = options.mission orelse mission0.number,
        .file = if (options.mission) |number| try missionFile(io, arena, directory, &resources, number, false) else "",
        .clock = &clock,
        .tables = tables,
        .types = &types,
        .cockpit = &cockpit,
        .display = &display.state,
        .view = &view,
        .loading = &loading,
    };
    defer play.end();
    display.play = &play;
    if (options.mission != null) try play.start(.{ .world = world, .clock = &clock, .devices = &devices });
    // The front end, where the game opens unless `--mission` names a mission, and what it draws
    // with; and where the game is between it and the missions.
    var front: engine.genilib.interf.Interface = .{ .pilot = .{ .difficulty = options.difficulty orelse .easy } };
    var front_resources: ?engine.genilib.interf.Resources = null;
    defer if (front_resources) |*open| open.close();
    var flow: Flow = .{ .in_front_end = options.mission == null };
    // The campaign's saved loadout, which `campaign_new` starts in the Predator, and which the
    // saved games keep.
    var saved_loadout: engine.interface.loadout.Saved = .{};
    const saving: Saving = .{
        .gpa = gpa,
        .folder = .{ .io = io, .dir = directory },
        .player = &player,
        .tier = &objects.campaign_tier,
        .pilot = &front.pilot,
        .saved = &saved_loadout,
        .strings = &strings,
    };
    // The pilot as the game starts: the call sign the profile gives, as `campaign_new` reads it,
    // and the list of call signs, which `WinMain` reads and writes straight back (`0x004A919B`).
    if (flow.in_front_end) {
        if (directory.readFileAlloc(io, game.gameflow.profile_name, arena, .limited(engine.files.max_file_size))) |bytes| {
            front.pilot.call_sign.set(game.gameflow.profileCallSign(bytes));
        } else |_| {}
        const player_name = strings.string(@intFromEnum(game.interface.pilot_roster.String.player)) orelse "";
        front.pilot_roster.list = game.winmain.loadCallSigns(settings_file.profile, player_name);
        try game.winmain.saveCallSigns(&front.pilot_roster.list, settings_file);
    }
    var front_ticks = platform.window.ticks();
    // What the front end's screens run and are entered with, its window and the time since its
    // last pass given each pass.
    var front_context: engine.genilib.interf.Context = .{
        .devices = &devices,
        .typed = &typed,
        .window = .{ 0, 0 },
        .elapsed = 0,
        .sound = sound,
        .bank = stdsmp,
        .settings = settings_file,
        .own = own.interface(),
        .video = video_settings,
        .saves = .{ .gpa = gpa, .folder = saving.folder, .game = saving.gameOf(&flow.loading), .strings = &strings, .local_time = localDate },
    };
    // The Reliant's rooms and the briefing, which run in loops of their own, with what they read,
    // play and draw with: made as the front end's resources open.
    var rooms: ?Rooms = null;
    // A piece of music asked for, as a mission's script plays one (`cmd_PlayMusic`): from `music\`,
    // for ever, at 80.
    if (options.music) |name| {
        const path = try std.fmt.allocPrint(arena, "music\\{s}", .{name});
        sound.playMusic(path, 0, 80, .now);
    }
    // A screenshot waits for the chase view to settle, then runs its ticks, one a frame, at least
    // until the second frame, which draws the sun by how much of it the first found showing.
    var frames_left: ?usize = null;
    if (options.screenshot != null) {
        const subject = camera.Subject.of(&objects.slots[objects.player]);
        for (0..settling_frames) |_| _ = view.frame(.{ .object = subject, .player = subject, .ticks = 1 });
        frames_left = options.screenshot_ticks;
    }

    var scene: srcore.Scene = .{};
    defer scene.deinit(arena);
    // What a frame needs until it is drawn, kept from frame to frame.
    var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer frame_arena.deinit();

    // The window's activation, which a screenshot doesn't wait on.
    var app: game.winmain.App = .{};
    // What `game_pause` pauses the game with, and resumes it.
    const pausing: game.main.Pausing = .{
        .gpa = gpa,
        .clock = &clock,
        .sound = sound,
        .menu = &pause_menu,
        .archive = resources,
        .outlines = &outlines,
        .camera = &view,
        .player = &objects.player,
    };
    // Whether the system's pointer shows over the window, and whether the window holds the mouse.
    var mouse_held = false;
    // As `WinMain` opens the front end, the splash leads into the main menu (`0x004AB6A0`).
    if (flow.in_front_end and options.screenshot == null) {
        _ = try movies.play(game.xtrabits.movie.splash_to_menu, .over_screen) orelse return;
    }
    while (true) {
        if (movies.controllers_changed) {
            movies.controllers_changed = false;
            if (options.screenshot == null) connectController(arena, &devices, &controller, settings_file.profile);
        }
        // The wheel's notches no screen took last pass are let go.
        _ = devices.mouse.notches();
        while (window.poll()) |event| switch (event) {
            .quit => return,
            .key => |key| if (options.screenshot == null) {
                devices.keyboard.down[@intFromEnum(key.scan)] = key.down;
            },
            .typed => |character| if (options.screenshot == null) typed.push(game.language.fromUnicode(character)),
            .controllers => if (options.screenshot == null) connectController(arena, &devices, &controller, settings_file.profile),
            // **Improvement:** the keys named again as the layout changes, where the game names
            // them once, as it starts.
            .keymap => platform.keyboard.nameKeys(&devices.key_names),
            .active => |active| app.active = active or frames_left != null,
            .pointer => |pointer| if (options.screenshot == null) {
                devices.mouse.at = pointer.at;
                // The movement counts only while the window holds the mouse, as DirectInput's
                // exclusive mouse moves only for the game.
                if (mouse_held) devices.mouse.motion = @as(@Vector(2, f32), devices.mouse.motion) + @as(@Vector(2, f32), pointer.moved);
            },
            .button => |button| if (options.screenshot == null) switch (button.which) {
                .left => devices.mouse.buttons.left = button.down,
                .right => devices.mouse.buttons.right = button.down,
            },
            .wheel => |turned| if (options.screenshot == null) {
                devices.mouse.wheel += turned;
            },
        };
        // While the window is inactive, the sound is paused, as the message pump pauses it, and a
        // mission loaded too.
        try game.winmain.followActivation(&app, pausing, play.loaded != null);
        if (output) |open| open.update();
        const size = try presenter.size();

        world.view = view.view;
        world.cockpit = if (cockpit.shown) |*shown| &shown.model else null;
        world.mission = if (play.loaded) |loaded| &loaded.bound else null;
        world.events = if (play.loaded) |loaded| &loaded.events else null;
        world.variables = if (play.loaded) |loaded| &loaded.script.variables else null;
        // The front end's frame while it is shown, as `interface_run` runs its screens, which the
        // keyboard is read for each pass; the mission it picks starts at once, with its clocks
        // zeroed as `mission_run` zeroes them.
        if (flow.in_front_end) {
            if (front_resources == null) {
                front_resources = try .open(gpa, resources, &outlines);
                rooms = .{
                    .movies = &movies,
                    .sound = sound,
                    .clock = &clock,
                    .resources = &resources,
                    .front = &front_resources.?,
                    .outlines = &outlines,
                    .strings = &strings,
                    .speech = options.speech,
                    .lines = if (radio.archive) |*archive| archive else null,
                    .screenshots = &screenshots,
                    .cache = cache,
                    .details = details,
                    .saved = &saved_loadout,
                    .stats = tables,
                    .missile_stats = &objects.missile_stats,
                    .tier = &objects.campaign_tier,
                    .pilot = &front.pilot,
                    .player = &player,
                    .campaign_flown = &flow.campaign,
                    .itac_strings = &itac_strings,
                    .saves = saving.folder,
                    .local_time = localDate,
                    .settings_file = settings_file,
                    .own = own.interface(),
                    .video = video_settings,
                };
            }
            front_context.resources = &front_resources.?;
            const ticks = platform.window.ticks();
            const elapsed = std.math.cast(i32, ticks -| front_ticks) orelse std.math.maxInt(i32);
            front_ticks = ticks;
            devices.keyboard.read();
            sound.updateMusic();
            front_context.window = size;
            front_context.elapsed = elapsed;
            if (front.frame(front_context)) |outcome| {
                const through = &rooms.?;
                flow.next = switch (outcome) {
                    .quit => return,
                    .fly => |flight| fly: {
                        flow.campaign = null;
                        break :fly .{ .flight = flight };
                    },
                    // START GAME: `WinMain` takes a new campaign into the Reliant's rooms, whose
                    // briefing room's door leads to the briefing, and the mission.
                    .campaign => |mission| fly: {
                        flow.campaign = .begin();
                        saving.gameOf(&flow.campaign.?).clearPilot();
                        objects.mission25_second_part = false;
                        const flight = briefedFlight(try through.campaign(mission) orelse return, objects, options.ship) orelse {
                            flow.toFrontEnd(&front);
                            continue;
                        };
                        break :fly .{ .flight = flight };
                    },
                    // LOAD GAME: `WinMain` takes a game loaded as START GAME's, into the rooms before
                    // its mission (`0x004AA1AB` on).
                    .loaded => fly: {
                        flow.campaign = flow.loading;
                        flow.loading = .begin();
                        objects.mission25_second_part = false;
                        const flight = briefedFlight(try through.campaign(flow.campaign.?.mission) orelse return, objects, options.ship) orelse {
                            flow.toFrontEnd(&front);
                            continue;
                        };
                        break :fly .{ .flight = flight };
                    },
                    // The developers' briefing from its loadout on, after which the front end
                    // starts again at its main menu.
                    .briefing => |mission| {
                        if (!try through.loadoutBriefing(mission)) return;
                        front.back();
                        continue;
                    },
                };
            }
        }
        // The flight the front end chose, or the campaign goes on to.
        if (flow.next) |launch| {
            flow.next = null;
            const flight = launch.flight;
            flow.flown = flight;
            play.number = flight.mission;
            play.file = missionFile(io, arena, directory, &resources, flight.mission, objects.mission25_second_part) catch |err| switch (err) {
                error.MissingMission => {
                    flow.toFrontEnd(&front);
                    continue;
                },
                else => |other| return other,
            };
            // The flight's ship, else the one `--ship` names, else the mission's ship; and the
            // simulator it runs in; and the campaign whose variables each attempt starts from.
            objects.loadout_ships[objects.player] = if (flight.ship orelse options.ship) |ship| @enumFromInt(ship) else null;
            objects.loadout_racks[objects.player] = flight.racks;
            objects.simulator = flight.simulator;
            // The simulator pod's missions run on the campaign's variables too, as the game's are
            // the campaign's, but `WinMain` keeps no restart point for them.
            play.campaign = if (flow.campaign) |*going| going else null;
            if (flight.byWinMain()) if (flow.campaign) |*going| {
                flow.restart_point = saving.restartPoint(going);
            };
            // The pilot the front end has set flies it: the radio says the pilot's own lines in
            // the pilot's voice, and hits land by the game's difficulty.
            player.female = front.pilot.female;
            world.difficulty = front.pilot.difficulty;
            // `WinMain` fades the music out over a second, then plays the hangar's movie before
            // the mission's loading, and the landing after it.
            play.winmain_flight = flight.byWinMain();
            if (play.winmain_flight and launch.hangar) {
                waitBeforeLaunch(&clock, sound);
                if (!try movies.launch(&hangar, flight.mission)) return;
            }
            sound.closeMusic();
            clock.start(platform.window.ticks());
            try play.start(.{ .world = world, .clock = &clock, .devices = &devices });
            flow.in_front_end = false;
            flow.from_front_end = true;
        }
        // The movie a screen of the front end plays as it leads to another.
        if (front.movie) |name| {
            front.movie = null;
            _ = try movies.play(name, .over_screen) orelse return;
        }
        // The window takes text while the front end has a line to type into.
        window.takeText(flow.in_front_end and front.takesText());
        const orders: game.aigeneric.Context = .{ .world = world, .clock = &clock, .devices = &devices };
        const slot = &objects.slots[objects.player];
        if (!flow.in_front_end) {
            // The timer's ticks since the last pass, then a game tick for each, as `mission_run` paces
            // them: the simulation steps on every fourth, reading the keyboard as it goes, and runs the
            // objects' updates. A screenshot takes one tick a frame so that the camera settles the same
            // way on every run.
            const now = platform.window.nanoseconds();
            if (frames_left != null) clock.advanceBy(now / platform.window.tick_nanoseconds, 1) else clock.advanceToFine(now, platform.window.tick_nanoseconds);
            // While the communications window is open the keys 1 to 8 are its menu's.
            devices.keyboard.numbers_taken = display.state.windows.status.get(.comms).phase == .open;
            while (clock.nextTick(&devices, world)) |_| {}
            clock.frameBegin();
            // `mission_frame` looks for Escape and F1 before its work, and pausing into the menu
            // leaves the work out.
            _ = try game.main.pauseKeys(pausing, &devices);
            if (clock.paused) {
                game.main.pausedFrame(&devices, hearing, world);
            } else {
                // The force feedback plays while the controller rumbles and its setting lets it.
                force_feedback.feedback = devices.joystick.rumbles;
                force_feedback.setting = devices.settings.force_feedback;
                // Each frame `mission_frame` runs every object's orders, which fly the ships and read
                // the player's controls, and then, before anything is drawn, has every object's frames
                // drawn between its last two places, as far into the step as the clock is; the camera
                // follows the player's.
                const over = game.main.missionFrame(orders, .of(&clock, smooth_motion, options.riders), play.loaded);
                // The mission over, once the camera has watched the player's end or the pilot's pickup,
                // once the player's ship has landed, or once its script ends it, the game settles how
                // it ended and goes on from it (`missionEnded`): the campaign to its next mission or
                // the restart screen, INSTANT ACTION back to the main menu, and the simulator pod's
                // missions back to the pod.
                // One `--mission` named pauses into the menu over the last frame, where RESTART, and
                // CONTINUE with nothing left to continue, fly it again; a screenshot, or a game told
                // not to (`--no-pause-menu`), starts it again straight away.
                if (over) {
                    game.main.missionRunEnd(world.player, objects.mission_number);
                    if (flow.from_front_end) {
                        if (!try missionEnded(&flow, &front, &play, &rooms.?, objects, world.player, saving, options.ship, sound, &movies, &resources)) return;
                        continue;
                    } else if (endsInPauseMenu(options, frames_left)) {
                        play.over = true;
                        try game.main.pause(pausing, true);
                    } else try play.again(orders);
                }
                if (test_keys.active(play.number)) {
                    for (test_keys.ship_keys) |step| {
                        if (devices.keyboard.pressed(@intFromEnum(step[0]), .none, true)) try play.changeShip(orders, step[1]);
                    }
                    if (devices.keyboard.pressed(@intFromEnum(test_keys.wing_key), .none, true)) test_keys.bringWing(orders);
                }

                game.main.controlsFrame(.{
                    .orders = orders,
                    .devices = &devices,
                    .camera = &view,
                    .display = &display.state,
                    .sight = display.sight,
                    .screen = display.screen,
                    .last_view = last_view,
                    .cockpit = if (cockpit.shown) |*shown| shown else null,
                    .forces = &force_feedback,
                    .random = &rand,
                    .smooth_motion = smooth_motion,
                });
            }
        }

        _ = frame_arena.reset(.retain_capacity);
        if (flow.in_front_end) {
            // The screen a transition's movie or a mission's end has just led to entered before
            // its first frame is drawn, as each of the game's screens enters before its loop.
            front.enterShown(front_context);
            var shown: FrontEndDisplay = .{ .front = &front, .resources = &front_resources.?, .target = screen.interface(), .window = size, .strings = &strings, .settings = .{ .devices = &devices, .sound = sound, .video = video_settings } };
            scene.clear();
            try srcore.render(frame_arena.allocator(), &context, &scene, driver.interface(), shown.overlay());
        } else {
            context.camera = .{ .position = view.place.position, .orientation = view.place.orientation };
            context.projection = view.projection(size[0], size[1]);
            // The cockpit's model hangs from the camera, and the radar's backing stands on the radar.
            if (cockpit.shown) |*shown| if (view.cockpit_place) |placed| game.main.cockpit.place(&shown.model, view.place, placed);
            backing.place(context.projection, view.place, game.hud.scaleFor(size));
            display.device = screen.interface();
            display.screen = size;
            display.sight = .{ .place = view.place, .projection = context.projection };
            display.last_view = last_view;
            display.cockpit_mode = view.cockpit_mode;
            try game.main.drawFrame(arena, frame_arena.allocator(), &scene, &context, .{
                .objects = objects,
                .seat = if (slot.object.flags.hidden) objects.player else null,
                .shown = .of(&player),
                .space = space,
                .sky = sky,
                .environment = &environment,
                .gates = &gates,
                .view = view.view,
                .cockpit_mode = view.cockpit_mode,
                .jumping_in = player.jumping_in,
                .last_view = last_view,
                .cut = view.cut,
                .overlay = display.overlay(),
                .cockpit = if (cockpit.shown) |*shown| &shown.model else null,
                // The paused frame hides the radar's backing, whose radar the menu stands in place of.
                .backing = if (clock.paused) null else backing,
                .kills_shown = devices.active(.display_kills, false),
                .particles = &particles,
                .smoke = &smoke,
                .gun_particles = &gun_particles,
                .sparks = &sparks,
                .ahead = game.objects.pastTick(&clock, smooth_motion),
                .explosions = &explosions,
                .shockwaves = &shockwaves,
                .trails = &trails,
                .countermeasures = &countermeasures,
                .lock = &display.state.lock,
                .lock_rings = lock_rings,
                .chase = chase_objects,
                .display = &display.state,
                .shields = &shields,
                .rays = &rays,
                .tractors = &tractors,
                .rippers = &rippers,
                .jump_effects = &jump_effects,
                .atmospheres = &atmospheres,
                .escort_marker = escort_marker,
                .flash = &flash,
                .interference = &display.state.interference,
                .ticks = @intCast(clock.frameTicks()),
                .paused = clock.paused,
                .attachments = .{
                    .camera = view.place.position,
                    .frame_start = clock.frame_start,
                    .random = &rand,
                },
            }, driver.interface());
            // `mission_frame` ends with the 0 key, which saves the frame just drawn.
            if (!clock.paused and game.main.screenshotAsked(&devices.keyboard)) screen.saveScreenshot(gpa, &screenshots);
            last_view = view.view;
            view.cut = false;
            // What the menu's choice ends the pause in, as `mission_paused_frame` acts on it: the
            // mission starts again for RESTART, and for CONTINUE once it is over, and LEAVE MISSION
            // leaves it, for the front end where the mission came from it.
            if (pause_menu.outcome()) |outcome| {
                try game.main.pause(pausing, false);
                switch (outcome) {
                    .continue_mission => if (play.over) try play.again(orders),
                    // `WinMain` loads the campaign's restart point (`0x004AA480`), and restarts
                    // mission 25 from its first part, which it reads again (`0x004AA47A`).
                    .restart => {
                        if (flow.flown.byWinMain()) if (flow.campaign) |*campaign| {
                            saving.restart(campaign, if (flow.restart_point) |*point| point else null);
                        };
                        if (objects.mission25_second_part) {
                            objects.mission25_second_part = false;
                            flow.next = .{ .flight = flow.flown, .hangar = false };
                            continue;
                        }
                        try play.again(orders);
                    },
                    .leave_mission => {
                        if (!flow.from_front_end) return;
                        player.ending = .left;
                        if (!try missionEnded(&flow, &front, &play, &rooms.?, objects, world.player, saving, options.ship, sound, &movies, &resources)) return;
                        continue;
                    },
                }
            }
        }
        // The menus draw their own pointer over the window, in place of the system's, which also
        // hides in full screen and once it rests over the window.
        const menu_pointer = flow.in_front_end or pause_menu.isOpen();
        window.showPointer(menu_pointer);
        // Steering by the mouse, the window holds it in flight, as the game holds DirectInput's
        // mouse while it is in the foreground.
        const hold = devices.controlMode() == .mouse and !menu_pointer and app.active and options.screenshot == null;
        if (hold != mouse_held) {
            mouse_held = hold;
            // Where the system won't hold it, the mouse steers by the pointer's movement over the
            // window, and the failure is logged.
            window.holdMouse(hold) catch {};
        }
        // What the menu's screens saved goes to the file.
        if (settings_file.changed) {
            settings_file.changed = false;
            directory.writeFile(io, .{ .sub_path = engine.profile.settings_name, .data = settings_file.profile.text }) catch |err|
                std.log.warn("the settings can't be saved to {s}: {s}", .{ engine.profile.settings_name, @errorName(err) });
        }
        if (screen.* == .software) try window.present(try screen.software.rgba(frame_arena.allocator()), size[0], size[1]);
        if (frames_left) |*left| {
            left.* -= 1;
            if (left.* == 0) {
                const frame = try screen.capture(frame_arena.allocator());
                return writeScreenshot(io, frame_arena.allocator(), options.screenshot.?, frame.rgba, frame.size);
            }
        }
        if (pacing.rate(window)) |rate| pacer.wait(rate);
    }
}

/// The view a ship that does not launch is shown in at first: view 0, as a launch ends in, in
/// `mode`. The chase mode sits a fixed distance behind, which the camera keeps per ship type, so a
/// ship whose own radius is larger than that distance would not fit in it, as the ships `--ship`
/// and the test keys give the player that the game never does. Those are shown in the external
/// view, which orbits at a distance worked out from the ship's own size.
fn startingView(slot: *const game.create.Slot, mode: camera.CockpitMode) camera.View {
    if (mode != .chase) return .cockpit;
    const behind = camera.Chase.offset(slot.object.type).distance;
    return if (slot.object.radius > behind) .external else .cockpit;
}

/// Frames the chase view takes to settle, at a tick a frame.
const settling_frames = 200;

fn writeScreenshot(io: Io, gpa: Allocator, path: []const u8, rgba: []const u8, size: [2]u32) !void {
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try openreliant.png.writeRgba(gpa, &writer.interface, size[0], size[1], rgba);
    try writer.interface.flush();
}

/// Whether a mission `--mission` names ends in the pause menu, which stands in for the debriefing:
/// unless the game flies it again at once (`--no-pause-menu`), or takes a screenshot, which reads
/// no controls and counts its frames down (`frames_left`). A mission the front end starts ends back
/// in the front end.
fn endsInPauseMenu(options: Options, frames_left: ?usize) bool {
    return options.mission != null and options.pause_menu and frames_left == null;
}

test endsInPauseMenu {
    try std.testing.expect(endsInPauseMenu(try options_page.testing.parsed(&.{ "--mission", "1" }), null));
    try std.testing.expect(!endsInPauseMenu(try options_page.testing.parsed(&.{}), null));
    try std.testing.expect(!endsInPauseMenu(try options_page.testing.parsed(&.{ "--mission", "1", "--no-pause-menu" }), null));
    try std.testing.expect(!endsInPauseMenu(try options_page.testing.parsed(&.{ "--mission", "1" }), 2));
}

/// `WinMain`'s second before the hangar's movie (`game.winmain.launchFade`), the timer run on
/// through it from the flight's start, as it fades the music out. The window waits as the game's
/// does, its messages left for the movie's loop.
fn waitBeforeLaunch(clock: *game.main.Clock, sound: *game.hog_snd.Sound) void {
    const start = platform.window.nanoseconds();
    clock.start(platform.window.ticks());
    game.winmain.launchFade(sound, clock.game_ticks);
    var pacer: platform.window.Pacer = .{};
    while (platform.window.nanoseconds() - start < game.winmain.launch_wait) {
        pacer.wait(game.main.ticks_per_second);
        clock.advanceTo(platform.window.ticks());
        sound.timerTick(clock.game_ticks);
    }
}

/// Where the game is between the front end and the missions, as `WinMain` goes from one to the
/// other: whether the front end is shown, and whether the mission flown was started from it; the
/// campaign it is flown in, none outside one; and the flight to start next, and the last started.
const Flow = struct {
    in_front_end: bool,
    from_front_end: bool = false,
    campaign: ?game.gameflow.Campaign = null,
    /// The campaign the front end's LOAD GAME loads into, which then goes into the rooms as the
    /// campaign flown.
    loading: game.gameflow.Campaign = .begin(),
    next: ?Launch = null,
    flown: game.interface.main_menu.Flight = .{ .mission = 0 },
    /// The game as the last flight of the campaign began, which a replay puts back
    /// (`restartPoint`).
    restart_point: ?save.Save = null,

    /// Back to the front end's main menu, out of the campaign.
    fn toFrontEnd(flow: *Flow, front: *engine.genilib.interf.Interface) void {
        front.back();
        flow.in_front_end = true;
        flow.from_front_end = false;
        flow.campaign = null;
    }
};

/// The local date and time of a moment, in nanoseconds from 1970 in UTC, as the system tells it,
/// which the saved games show the dates of their files by.
fn localDate(since_1970: i96) ?game.interface.saved_games.Date {
    const time = platform.window.localTime(std.math.cast(i64, since_1970) orelse return null) orelse return null;
    return .{ .year = time.year, .month = time.month, .day = time.day, .hour = time.hour, .minute = time.minute, .day_of_week = time.day_of_week };
}

/// What the saved games save and load, and where: the game's folder, and where the driver keeps
/// the pilot, the campaign's tier and the loadout's saved choice; and the strings the autosave's
/// name is written with.
const Saving = struct {
    gpa: Allocator,
    folder: save.Folder,
    player: *engine.input.Player,
    tier: *u2,
    pilot: *game.interface.pilot_roster.Pilot,
    saved: *engine.interface.loadout.Saved,
    strings: *const game.language.Language,

    /// The game of `campaign`, as a save takes it and puts it back.
    fn gameOf(saving: Saving, campaign: *game.gameflow.Campaign) save.Game {
        return .{ .campaign = campaign, .player = saving.player, .tier = saving.tier, .pilot = saving.pilot, .saved = saving.saved };
    }

    /// `restart_save` (`0x00475D20`), as `WinMain` saves the game before each attempt at a mission
    /// of `campaign` (`0x004AA3FC`).
    ///
    /// **Improvement:** OpenReliant keeps the restart point in memory, where the game writes it to
    /// the saves folder as saved game 100, named restart, and reads it back.
    fn restartPoint(saving: Saving, campaign: *game.gameflow.Campaign) save.Save {
        return saving.gameOf(campaign).capture(save.restart_name);
    }

    /// `restart_load` (`0x00475D30`) of `point` into `campaign`, as a replay or the pause menu's
    /// RESTART turns back to the mission.
    fn restart(saving: Saving, campaign: *game.gameflow.Campaign, point: ?*const save.Save) void {
        if (point) |kept| save.restartLoad(saving.gameOf(campaign), kept);
    }

    /// `mission_end_record`'s save as the campaign moves on (`save.autosave`).
    fn autosave(saving: Saving, campaign: *game.gameflow.Campaign) void {
        const prefix = saving.strings.string(save.autosave_string) orelse "";
        save.autosave(saving.gameOf(campaign), saving.folder, saving.gpa, prefix) catch |err|
            std.log.warn("the game can't be saved: {s}", .{@errorName(err)});
    }
};

/// A flight to start, with the hangar's movie before it where `WinMain` flies it, but where the
/// mission is flown again from its launch, as the restart screen's REPLAY MISSION FROM LAUNCH and
/// RESTART fly it (`0x004AA3D9`).
const Launch = struct {
    flight: game.interface.main_menu.Flight,
    hangar: bool = true,
};

/// As a mission the front end or the campaign started ends, or is left: a mission of the simulator
/// pod's goes back into the pod (`Rooms.backFromSimulator`); the campaign goes on
/// (`campaignGoesOn`), to the flight it leads to or to the main menu; outside it, the mission is
/// let go, with the landing where it plays one, and the front end's main menu entered again. False
/// where the game quits meanwhile.
fn missionEnded(flow: *Flow, front: *engine.genilib.interf.Interface, play: *Play, rooms: *Rooms, all: *game.create.Objects, player: *engine.input.Player, saving: Saving, ship: ?u8, sound: *game.hog_snd.Sound, movies: *Movies, resources: *const game.bigfile.Hog) !bool {
    if (flow.flown.flier == .simulator_pod) {
        // The pod's mission leaves the game's variables, which are the campaign's, as it ended
        // them: the pod runs it on the game's own (`0x0044F6EF`).
        if (flow.campaign) |*campaign| if (play.loaded) |loaded| {
            campaign.variables = loaded.script.variables;
        };
        if (!try letGo(play, all, sound, null, movies, resources)) return false;
        const flight = briefedFlight(try rooms.backFromSimulator() orelse return false, all, ship) orelse {
            flow.toFrontEnd(front);
            return true;
        };
        flow.next = .{ .flight = flight };
        return true;
    }
    if (flow.campaign) |*campaign| {
        const point = if (flow.restart_point) |*kept| kept else null;
        switch (try campaignGoesOn(play, campaign, rooms, all, player, saving, flow.flown, point, ship, sound, movies, resources) orelse return false) {
            .fly => |launch| {
                flow.next = launch;
                return true;
            },
            .main_menu => {},
        }
    } else if (!try letGo(play, all, sound, play.landing(player.ending, all.mission25_second_part), movies, resources)) return false;
    flow.toFrontEnd(front);
    return true;
}

/// The mission let go as it ends: out of the simulator, its sounds and music ended, and what
/// `play_landing_movie` plays, where `WinMain` plays it (`Play.landing`). False where the game
/// quits meanwhile.
fn letGo(play: *Play, all: *game.create.Objects, sound: *game.hog_snd.Sound, landing: ?game.xtrabits.landing.Landing, movies: *Movies, resources: *const game.bigfile.Hog) !bool {
    play.end();
    all.simulator = .{};
    sound.endAll();
    sound.closeMusic();
    if (landing) |what| return movies.land(what, resources, sound);
    return true;
}

/// The flight the rooms lead to as they `end`: a mission of the simulator pod's; or the mission
/// the briefing leads to, which a game loaded on the way may have changed, in the ship its loadout
/// chose and its racks, but where `--ship` names a `ship`, which is then fitted by its tier, and
/// the campaign's tier as the loadout raised it. Null where they led to the main menu.
fn briefedFlight(end: RoomsEnd, all: *game.create.Objects, ship: ?u8) ?game.interface.main_menu.Flight {
    const flown = switch (end) {
        .fly => |flown| flown,
        .simulator => |flight| return flight,
        .main_menu => return null,
    };
    const mission = flown.mission;
    const result = flown.result orelse return .{ .mission = mission };
    all.campaign_tier = result.tier;
    if (ship) |named| return .{ .mission = mission, .ship = named };
    return .{ .mission = mission, .ship = result.ship, .racks = result.racks };
}

/// What follows a mission of the campaign, as `WinMain` goes on after it (`campaignGoesOn`).
const CampaignNext = union(enum) {
    /// The mission its briefing leads to, mission 25's second part, or the mission again from its
    /// launch.
    fly: Launch,
    main_menu,

    /// Where a briefing leads as it `end`s (`briefedFlight`).
    fn briefed(end: RoomsEnd, all: *game.create.Objects, ship: ?u8) CampaignNext {
        const flight = briefedFlight(end, all, ship) orelse return .main_menu;
        return .{ .fly = .{ .flight = flight } };
    }
};

/// What `WinMain` does as a mission of the campaign ends (`game.winmain.afterMission`), the flight
/// that started it `flown` and the campaign as it began at `restart_point`: the mission let go, with
/// the landing where it plays one (`letGo`). The game's variables as the mission left them carry on
/// to the next mission and to mission 25's second part, but not to a replay, which starts from
/// those the mission began with. Then, as the mission ended: the medal's ceremony, the debriefing in
/// the ITAC (`0x004AA696`), and the rooms the campaign goes on through, or with the ITAC's REPLAY
/// MISSION the campaign put back as the mission began and its briefing again (`0x004AA2E0` on);
/// the movie of how it ended and the restart screen; or the movie that ends the pilot's career.
/// Null where the game quits meanwhile.
///
/// **Fix:** after the pilot's execution in mission 25's second part, REPLAY MISSION FROM BRIEFING
/// replays the first part's briefing. The game flies the second part again at once, and leaves the
/// replay asked for, so that the next mission's briefing follows it without the rooms, from the
/// game's variables as the second part began.
///
/// Not ported: the story's end ([#416](https://github.com/vdmkenny/openreliant/issues/416)).
fn campaignGoesOn(play: *Play, campaign: *game.gameflow.Campaign, rooms: *Rooms, all: *game.create.Objects, player: *engine.input.Player, saving: Saving, flown: game.interface.main_menu.Flight, restart_point: ?*const save.Save, ship: ?u8, sound: *game.hog_snd.Sound, movies: *Movies, resources: *const game.bigfile.Hog) !?CampaignNext {
    const loaded = play.loaded orelse return .main_menu;
    const variables = &loaded.script.variables;
    const landing = play.landing(player.ending, all.mission25_second_part);
    const after = game.winmain.afterMission(campaign, player, variables, play.number, &all.mission25_second_part, all.campaign_tier);
    switch (after) {
        .goes_on, .second_part => campaign.variables = variables.*,
        .restart, .career_over, .story_end => {},
    }
    if (!try letGo(play, all, sound, landing, movies, resources)) return null;
    switch (after) {
        .goes_on => |record| {
            all.campaign_tier = record.tier;
            if (record.medal) |medal| _ = try movies.play(medal.movie(), .cleared_from_disc) orelse return null;
            saving.autosave(campaign);
            switch (try rooms.itac(.after_mission, record.next) orelse return null) {
                .closed => return .briefed(try rooms.goOn(record.next) orelse return null, all, ship),
                .replay => {
                    saving.restart(campaign, restart_point);
                    all.mission25_second_part = false;
                    return .briefed(try rooms.replayBriefing(play.number) orelse return null, all, ship);
                },
            }
        },
        .second_part => return .{ .fly = .{ .flight = flown } },
        .restart => |ending| {
            if (ending) |name| _ = try movies.play(name, .cleared_from_disc) orelse return null;
            switch (try rooms.restart() orelse return null) {
                // Each replay loads the restart point (`0x0043ECDB`, `0x0043ECEC`); from the briefing,
                // it starts from mission 25's first part (`0x004AA2EC`).
                .replay_from_briefing => {
                    saving.restart(campaign, restart_point);
                    all.mission25_second_part = false;
                    return .briefed(try rooms.replayBriefing(play.number) orelse return null, all, ship);
                },
                .replay_from_launch => {
                    saving.restart(campaign, restart_point);
                    return .{ .fly = .{ .flight = flown, .hangar = false } };
                },
                .main_menu => return .main_menu,
            }
        },
        .career_over => |name| {
            _ = try movies.play(name, .cleared_from_disc) orelse return null;
            return .main_menu;
        },
        .story_end => {
            std.log.info("the story's end is not ported yet", .{});
            return .main_menu;
        },
    }
}

/// What draws the front end over the cleared frame: its render hook (`sr + 0x88`), which
/// `srcore.render` reaches through the overlay it is handed.
const FrontEndDisplay = struct {
    front: *const engine.genilib.interf.Interface,
    resources: *engine.genilib.interf.Resources,
    target: srd3d.device.Device,
    window: [2]u32,
    strings: *const game.language.Language,
    /// What the settings screen shows the state of: the devices' settings and bindings, the
    /// sound's volumes, and the video.
    settings: game.interface.settings.Shown,

    fn overlay(shown: *FrontEndDisplay) srcore.Overlay {
        return .{ .context = shown, .draw = draw };
    }

    fn draw(context: *anyopaque) Allocator.Error!void {
        const shown: *FrontEndDisplay = @ptrCast(@alignCast(context));
        return drawn(shown.front.draw(shown.resources, shown.target, shown.window, shown.strings, shown.settings, version.string));
    }
};

/// The loading screens as the driver shows them (`game.xtrabits.loading`): each frame drawn over an
/// empty scene at once and put on the window, the system's events gathered for the loop meanwhile
/// (`message_pump`).
const Loading = struct {
    resources: game.xtrabits.loading.Resources,
    archive: *const game.bigfile.Hog,
    presenter: *Presenter,
    strings: *const game.language.Language,
    splash: game.xtrabits.loading.Splash,

    fn close(loading: *Loading) void {
        loading.resources.close();
    }

    /// The size the frames are drawn at.
    fn size(loading: *Loading) ![2]u32 {
        return loading.presenter.size();
    }

    /// Draws `frame` and puts it on the window.
    fn show(loading: *Loading, frame: game.xtrabits.loading.Frame) !void {
        loading.presenter.window.pump();
        loading.resources.show(loading.archive.*, frame);
        const pixels = try loading.size();
        var shown: Shown = .{ .loading = loading, .window = pixels, .line = if (frame.line) |id| loading.strings.string(@intFromEnum(id)) else null };
        try loading.presenter.present(pixels, shown.overlay());
    }

    /// A frame's overlay: the loading screen, on the front end's screen fitted to the window.
    const Shown = struct {
        loading: *Loading,
        window: [2]u32,
        line: ?[]const u8,

        fn overlay(shown: *Shown) srcore.Overlay {
            return .{ .context = shown, .draw = draw };
        }

        fn draw(context: *anyopaque) Allocator.Error!void {
            const shown: *Shown = @ptrCast(@alignCast(context));
            const resources = &shown.loading.resources;
            try resources.draw(.{
                .gpa = resources.gpa,
                .target = shown.loading.presenter.screen.interface(),
                .window = shown.window,
                .fonts = .{ .large = &resources.large.font, .small = &resources.small.font },
                .strings = shown.loading.strings,
                .version = version.string,
            }, shown.line);
        }
    };
};

/// The mission being played: the file it starts from, and the mission loaded for play, which
/// starts again as each attempt ends, with what each start readies (`game.main.startMission`).
const Play = struct {
    gpa: Allocator,
    number: u16,
    /// The mission's file as read, of which each start binds a copy, as the game reads the file
    /// again for each.
    file: []const u8,
    loaded: ?*game.mission.Loaded = null,
    clock: *game.main.Clock,
    tables: *game.create.Stats,
    types: *game.create.library.TypeCache,
    cockpit: *game.main.cockpit.Cockpit,
    display: *game.hud.State,
    /// The camera, which shows the player's ship in the view it starts in (`startingView`).
    view: *camera.Camera,
    /// Whether the attempt is over, the pause menu standing in the debriefing's place.
    over: bool = false,
    /// Whether `WinMain` flies the mission (`main_menu.Flight.byWinMain`), which lands after it.
    winmain_flight: bool = false,
    /// The loading screen each start shows.
    loading: ?*Loading = null,
    /// The campaign the mission is flown in, whose variables each attempt starts from; none
    /// outside it.
    campaign: ?*const game.gameflow.Campaign = null,

    /// Starts the mission, letting go of the one before, the loading screen shown first
    /// (`game.xtrabits.loading.missionFrames`).
    fn start(play: *Play, orders: game.aigeneric.Context) !void {
        play.end();
        play.over = false;
        if (play.loading) |loading| {
            const frames = game.xtrabits.loading.missionFrames(loading.splash, (try loading.size())[0], orders.world.objects.simulator.mode);
            for (frames) |frame| try loading.show(frame);
        }
        play.loaded = try game.main.startMission(play.gpa, .{
            .orders = orders,
            .clock = play.clock,
            .tables = play.tables,
            .types = play.types,
            .cockpit = play.cockpit,
            .display = play.display,
            .campaign = play.campaign,
        }, try play.gpa.dupe(u8, play.file), play.number);
        // A launch holds the camera until the ship is out; a ship that does not launch starts in
        // its view at once.
        const all = orders.world.objects;
        if (!play.view.locked) _ = play.view.setView(startingView(&all.slots[all.player], play.view.cockpit_mode), all.player, false, true, play.clock.viewTime());
    }

    /// Starts the mission again as an attempt ends, or as RESTART starts it again: outside the
    /// campaign, the kills kept where the ending keeps them, as when the ejected pilot is picked up
    /// by a nanny ship (`gameflow.endMission`). The campaign records its missions only as they end
    /// (`campaignGoesOn`).
    fn again(play: *Play, orders: game.aigeneric.Context) !void {
        if (play.campaign == null) if (play.loaded) |loaded| {
            _ = game.gameflow.endMission(orders.world.player, &loaded.script.variables, play.number, orders.world.objects.campaign_tier, null);
        };
        try play.start(orders);
    }

    /// Starts the mission again with the loadout's ship the type `step` on from the player's
    /// (`test_keys.nextShipType`), passing over the types whose models the game lacks; with none
    /// to go to, in the ship it was.
    fn changeShip(play: *Play, orders: game.aigeneric.Context, step: isize) !void {
        const all = orders.world.objects;
        const was: usize = all.slots[all.player].object.type.untwinned().number();
        var candidate = was;
        while (true) {
            candidate = test_keys.nextShipType(candidate, step);
            all.loadout_ships[all.player] = @enumFromInt(candidate);
            try play.start(orders);
            if (all.slots[all.player].type != null or candidate == was) return;
            std.log.warn("ship type {d} is left out: the game has no model for it", .{candidate});
        }
    }

    fn end(play: *Play) void {
        if (play.loaded) |loaded| loaded.destroy();
        play.loaded = null;
    }

    /// What `play_landing_movie` plays after the mission ended as `ending`, by its rating and the
    /// game's variables, where `WinMain` flew it and plays it (`game.winmain.landsAfter`).
    /// `second_part` is mission 25's second part.
    fn landing(play: *Play, ending: game.main.Ending, second_part: bool) ?game.xtrabits.landing.Landing {
        if (!play.winmain_flight) return null;
        const loaded = play.loaded orelse return null;
        if (!game.winmain.landsAfter(ending, play.number, second_part)) return null;
        return game.xtrabits.landing.landing(play.number, second_part, ending, &loaded.script.variables);
    }
};

/// The file of mission `number`, as the game reads it (`game.mission.bind.read`): from a mod, the
/// game's `missions` folder, or `resource.hog`. Mission 0, OpenReliant's own, comes from the copy
/// `openreliant` carries where the game has none.
fn missionFile(io: Io, arena: Allocator, directory: Io.Dir, resources: *const game.bigfile.Hog, number: u16, second_part: bool) ![]const u8 {
    var path_buffer: [game.winmain.mission_path_size]u8 = undefined;
    const path = game.winmain.missionPath(&path_buffer, number, second_part, false);
    if (try game.mission.bind.read(io, arena, directory, resources, path)) |file| return file.image;
    if (number == mission0.number) return @embedFile("mission0.dte");
    std.debug.print("openreliant: the game has no mission {d}: neither its missions folder nor {s} holds {s}\n", .{ number, game.bigfile.resource_name, std.fs.path.basenameWindows(path) });
    return error.MissingMission;
}

/// What draws the head-up display over the finished scene: `hud_draw`, given the mission's game.
/// `srcore.render` reaches it where Surrender reaches `hud_draw`, through the overlay it is handed.
const Display = struct {
    resources: game.hud.Resources,
    gpa: Allocator,
    /// What it draws into, filled in each frame before the scene is drawn.
    device: srd3d.device.Device,
    screen: [2]u32,
    /// Last frame's view, which is what `hud_draw` reads to know whether to draw the instruments.
    last_view: camera.View = .cockpit,
    /// What the cockpit view shows, which leaves the reticle out of the chase view.
    cockpit_mode: camera.CockpitMode = .cockpit,
    /// The scene as it is drawn, which the targeting keys find the object under the reticle by
    /// and the target is drawn over; null until the first frame.
    sight: ?game.hud.Sight = null,
    /// Where the line starts that places the marker for a target out of sight.
    edge_line: game.hud.EdgeLine,
    /// The objects, whose player's ship the display shows, and the mission being played, whose
    /// script has what is ready for JUMP DRIVE; filled in once the mission is ready to start.
    objects: *game.create.Objects,
    play: *const Play,
    clock: *const game.main.Clock,
    player: *const engine.input.Player,
    /// The camera, whose shake shakes the power ball too.
    view: *const camera.Camera,
    /// The radio, whose window shows the speaker's face.
    radio: *game.videoreports.Radio,
    /// The C runtime's `rand`, which the camera and the display both draw from.
    random: *engine.libcmt.Rand,
    /// The display's own state, `hud.cpp`'s globals.
    state: game.hud.State = .{},
    /// What the display shows ready for JUMP DRIVE while no mission is loaded: nothing.
    idle: game.hud.Readiness = .{},
    /// The game's strings, which the views without the instruments are named by.
    strings: *const game.language.Language,
    /// The pause menu, which stands in the display's place while the game is paused, the devices
    /// its pointer reads, and the settings its screens change.
    pause_menu: *game.hudoptions.PauseMenu,
    devices: *engine.input.Devices,
    settings: game.hudoptions.Settings,

    fn overlay(display: *Display) srcore.Overlay {
        return .{ .context = display, .draw = draw };
    }

    fn draw(context: *anyopaque) Allocator.Error!void {
        const display: *Display = @ptrCast(@alignCast(context));
        return drawn(display.drawOverlay());
    }

    /// What Surrender's overlay slot (`sr + 0x88`) holds: the pause menu while paused
    /// (`pause_menu_draw`), and the display otherwise (`hud_draw`).
    fn drawOverlay(display: *Display) !void {
        if (display.pause_menu.isOpen()) return display.pause_menu.draw(.{
            .target = display.device,
            .screen = display.screen,
            .art = &display.resources.art,
            .font = &display.resources.font,
            .strings = display.strings,
            .devices = display.devices,
            .settings = display.settings,
            .version = version.string,
            .timer = platform.window.ticks(),
        });
        try game.hud.draw(&display.state, &display.resources, .{
            .gpa = display.gpa,
            .device = display.device,
            .screen = display.screen,
            .sight = display.sight,
            .all = display.objects,
            .player = display.player,
            .clock = display.clock,
            .last_view = display.last_view,
            .mode = display.cockpit_mode,
            .strings = display.strings,
            .hit_shake = display.view.hit_shake,
            .view = display.view.view,
            .sound = display.settings.sound,
            .radio = display.radio,
            .random = display.random,
            .ready = if (display.play.loaded) |loaded| &loaded.script.variables.ready else &display.idle,
            .edge_line = display.edge_line,
            .variables = if (display.play.loaded) |loaded| &loaded.script.variables else null,
        });
    }
};

test {
    _ = options_page;
    _ = settings_module;
    _ = install;
    _ = joysticks;
    _ = mission0;
    _ = missions;
    _ = test_keys;
    _ = version;
}
