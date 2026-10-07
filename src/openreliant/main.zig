//! `openreliant`: the engine, on SDL3 in place of Win32 and DirectX. It has no data of its own: it
//! runs in the directory of an installed copy of StarLancer, or in the one given, and reads
//! `resource.hog` and the texture cache from it as the game does. `openreliant install` installs
//! the game's files from its discs; see `install.zig`.
//!
//! It plays a mission, which pauses into the game's menu as each attempt ends, to be flown again:
//! by default mission 0, OpenReliant's own sandbox (`mission0.zig`), which it carries, or the
//! game's mission `--mission` names. It draws through Surrender's pipeline and its Direct3D driver
//! with the GPU, from the camera's views, which the game's camera keys pick and steer. Added for OpenReliant: the test keys (`test_keys.zig`), and Alt and Enter, which
//! switch to the full screen and back. Escape opens the game's pause menu, whose LEAVE MISSION
//! quits.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const scripting = @import("scripting");
const stats = openreliant.stats;
const tcache = openreliant.tcache;
const tga = openreliant.tga;
const dte = openreliant.dte;
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
const hooks_command = @import("hooks.zig");
const install = @import("install.zig");
const joysticks = @import("joysticks.zig");
const log_file = @import("log_file.zig");
const mission0 = @import("mission0.zig");
const missions = @import("missions.zig");
const Movies = @import("movies.zig").Movies;
const presenting = @import("presenter.zig");
const Presenter = presenting.Presenter;
const ModShaders = @import("mod_shaders.zig").ModShaders;
const whole_shaders = @import("whole_shaders.zig");
const WholeShaders = whole_shaders.Loaded;
const drawn = presenting.drawn;
const Rooms = @import("rooms.zig").Driver;
const RoomsEnd = @import("rooms.zig").End;
const test_keys = @import("test_keys.zig");
const ScriptConsole = @import("console.zig").Driver;
const ScriptFrames = @import("script_frames.zig").ScriptFrames;
const GameScripts = @import("game_scripts.zig").GameScripts;
const version = @import("version");
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

pub const std_options: std.Options = .{ .logFn = logLine };

/// Writes each message of the log to the terminal and the log file (`log_file.zig`), and the
/// scripts' messages to the scripting console too (`scripting.console.log`).
fn logLine(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const filled = log_file.logLine(level, scope, format, args);
    if (scope == .scripts) scripting.console.log(level, format, args);
    if (filled) {
        std.log.warn(log_file.full_message, .{});
        scripting.console.log(.warn, log_file.full_message, .{});
    }
}

pub const panic = std.debug.FullPanic(panicked);

/// Writes a crash to the log file, then to the terminal as the standard library does.
fn panicked(message: []const u8, first: ?usize) noreturn {
    @branchHint(.cold);
    log_file.crash(message, first orelse @returnAddress());
    std.debug.defaultPanic(message, first);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "install")) return install.main(init.io, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "joysticks")) return joysticks.main(init.io, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "missions")) return missions.main(init.io, arena, args[2..]);
    if (args.len > 1 and std.mem.eql(u8, args[1], "hooks")) return hooks_command.main(init.io, args[2..]);
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
    const game_path = try install.gameFolder(io, arena, asked.directory);
    const directory = switch (try install.openGame(io, .cwd(), game_path)) {
        .game => |opened| opened,
        .no_folder => return missingGameFiles(game_path, null, asked.directory == null),
        .missing => |name| return missingGameFiles(game_path, name, asked.directory == null),
    };
    defer directory.close(io);
    log_file.open(io, directory, version.string);
    defer log_file.close(io);
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
    run(io, init.gpa, arena, options, game_path, directory, &settings_file) catch |err| switch (err) {
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
    if (found.len > 0 and joystick.unmatched(found, setup.preference)) {
        std.log.warn("no attached controller's name contains '{s}' (Joystick in {s}), so the game uses {s}", .{ setup.preference.?, engine.profile.settings_name, chosen.?.name });
    }
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
/// status 1. Where no folder was named (`searched`), it says where OpenReliant looked
/// (`install.findGame`).
fn missingGameFiles(directory: []const u8, file: ?[]const u8, searched: bool) u8 {
    if (searched) {
        std.debug.print("openreliant: the game isn't in the current directory, in a directory in it, or beside openreliant.\n", .{});
    } else if (file) |name| {
        std.debug.print("openreliant: {s} is missing from {s}.\n", .{ name, directory });
    } else {
        std.debug.print("openreliant: there is no directory {s}.\n", .{directory});
    }
    std.debug.print(
        \\OpenReliant is an engine only: it plays the files of a legally obtained copy of
        \\StarLancer. Name the directory the game is installed in:
        \\
        \\    openreliant <game-directory>
        \\
        \\or install it in a directory beside openreliant, where it is found without a name.
        \\To install the game's files from your StarLancer discs:
        \\
        \\    openreliant install {s}
        \\
    , .{install.suggested_folder});
    return 1;
}

/// The window's size in points as it opens. OpenReliant's: the original took the display mode
/// `[Device]` names.
const initial_size = [2]u32{ 1280, 720 };

/// How often the mods' storage that changed is written to the game folder, at most, so that a
/// script that changes it every frame doesn't write a file every frame.
const storage_interval = 2 * std.time.ns_per_s;

/// The voices `WinMain` asks `sound_init` for (`0x004A9421`).
const sound_voices = 10;

comptime {
    // The platform counts the game's ticks.
    std.debug.assert(platform.window.tick_nanoseconds * game.main.ticks_per_second == std.time.ns_per_s);
}

/// Reads one of the game's files in the game folder `directory` into `arena`, with a mod's file of
/// the same name taking priority (`game.bigfile.Mods.readLoose`).
fn readGameFile(io: Io, arena: Allocator, directory: Io.Dir, mods: *const game.bigfile.Mods, name: []const u8) ![]u8 {
    return try mods.readLoose(io, arena, directory, name, .limited(engine.files.max_file_size)) orelse error.FileNotFound;
}

/// Reads the strings of the module `name` in the game folder `directory`, as `language_init` does
/// (`game.language.Language.load`).
fn readStrings(io: Io, arena: Allocator, directory: Io.Dir, mods: *const game.bigfile.Mods, name: []const u8) !game.language.Language {
    return .load(arena, try .parse(try readGameFile(io, arena, directory, mods, name)));
}

/// Reads the records of the stats table `table` from its file in the game folder `directory`, as
/// its loader does (`stats_load_ships` and the others).
fn readStats(io: Io, arena: Allocator, directory: Io.Dir, mods: *const game.bigfile.Mods, comptime table: stats.Table) ![]align(1) const stats.Table.Record(table) {
    const file = try stats.File.parse(table, try readGameFile(io, arena, directory, mods, table.fileName()));
    return @field(file, @tagName(table));
}

/// Plays from the game's folder `directory`, at `game_path`, with its settings file
/// `settings_file`, which the pause menu's screens write to.
fn run(io: Io, gpa: Allocator, arena: Allocator, options: Options, game_path: []const u8, directory: Io.Dir, settings_file: *engine.profile.File) !void {
    // OpenReliant's mods, whose files take priority over the game's files wherever they are; none
    // with `--no-mods`. The mods screen sets which are on and the order they load in, for a
    // screenshot too.
    const mods_order: game.bigfile.mods.Order = .{ .profile = settings_file.profile };
    var mods: game.bigfile.Mods = if (options.mods) try .openOrdered(arena, io, directory, version.semantic, mods_order) else .none;
    defer mods.close(arena);
    // The ship types, guns, missiles and pilots the mods add, each numbered from where the game's
    // end.
    try game.additions.read(arena, mods.list);
    const asked_ship: ?game.create.TypeIndex = if (options.ship) |named| shipNamed(named) orelse {
        std.log.err("--ship takes a ship type's number or name, such as 0 or predator, not '{s}'", .{named});
        return error.UnknownShip;
    } else null;
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
    // What the game's models are built with: the light maps, and the lights as `--original` has
    // them or as OpenReliant's.
    const models: game.srofiles.Settings = .{ .light_maps = details.light_maps, .real_lights = options.real_lights };
    // The textures, with the mods' pictures replacing the cache's images. They're allocated in
    // `gpa`, since reading a large picture allocates a lot of temporary memory, and each is fitted
    // to the texture detail.
    var textures: srtexture.Table = .init(gpa, cache, palette);
    defer textures.deinit();
    textures.files = mods.pictures();
    textures.largest = details.texture.largest();
    // The records: the ship stats `stats_load_ships` reads, the gun stats `stats_load_guns` reads,
    // the missile stats `stats_load_missiles` reads, the pilots, the strings `language_init` reads
    // from `language.dll` at startup, and the ITAC's strings from `itaclang.dll` (without it the
    // ITAC shows no text). The mods' load scripts can change them before the game uses them.
    var records: scripting.Records = try .init(arena, .{
        .ships = try game.additions.ships.records(stats.Ship, arena, try readStats(io, arena, directory, &mods, .ships), 0),
        .guns = try game.additions.guns.records(stats.Gun, arena, try readStats(io, arena, directory, &mods, .guns), 1),
        .missiles = try game.additions.missiles.records(stats.Missile, arena, try readStats(io, arena, directory, &mods, .missiles), 0),
        .pilots = try game.additions.pilots.records(stats.Pilot, arena, try readStats(io, arena, directory, &mods, .pilots), 0),
        .text = try game.additions.addNames(arena, (try readStrings(io, arena, directory, &mods, game.language.file_name)).strings),
        .itac_text = if (readStrings(io, arena, directory, &mods, game.itac.strings_name)) |read| read.strings else |err| blank: {
            std.log.warn("can't read {s}: {s}", .{ game.itac.strings_name, @errorName(err) });
            break :blank &.{};
        },
    });
    // The mods' storage: the sections each mod keeps across every game (read at start-up and
    // written back as they change) and with each saved game. Every script can reach it, the game's
    // files and the game's folder.
    var storage: scripting.storage.Storage = .{ .gpa = gpa, .folder = .{ .io = io, .dir = directory } };
    defer storage.deinit();
    defer storage.flush();
    try storage.readGlobal(mods.list);
    // The pages of options that the mods' load and menu scripts declare at start-up. Their values
    // are kept in the storage.
    var option_pages: scripting.settings.Registry = .init(gpa, &storage);
    defer option_pages.deinit();
    // The game modes the mods' load and menu scripts register at start-up, which GAME MODES lists.
    var game_modes: scripting.game_modes.Registry = .init(gpa, &storage);
    defer game_modes.deinit();
    const shared: scripting.runtime.Shared = .{ .storage = &storage, .files = resources, .game = .{ .io = io, .dir = directory }, .settings = &option_pages, .bindings_file = settings_file, .modes = &game_modes };
    try scripting.load.run(gpa, io, mods.list, &records, version.string, shared);
    // The mods' player and menu scripts: menu scripts from here until OpenReliant quits, player
    // scripts while a game runs (`GameScripts`).
    const presentation = try scripting.Presentation.start(gpa, io, mods.list, &records, version.string, shared);
    defer if (presentation) |shown| shown.stop();
    option_pages.close();
    game_modes.close();
    const ship_stats = records.ships;
    const gun_stats = records.guns;
    const missile_stats = records.missiles;
    const pilot_stats = records.pilots;
    const strings = records.language(.text);
    const itac_strings = records.language(.itac_text);

    var window: platform.window.Window = try .open("OpenReliant", initial_size[0], initial_size[1], options.fullscreen);
    defer window.close();
    // The compiled shaders of the mods, kept in the game folder, and their replacements for
    // OpenReliant's shaders, chosen as OpenReliant starts while MOD EFFECTS is on.
    const shader_cache: platform.shader_cache.Cache = .{ .io = io, .root = directory };
    const whole: WholeShaders = if (options.mod_effects) try whole_shaders.load(arena, shader_cache, mods.list) else .{ .template = .builtin() };
    // The GPU the driver draws with, and the driver.
    const gpu = try arena.create(platform.gpu.Gpu);
    gpu.* = try .init(gpa, window.gpu, window.handle, options.settings, &whole.replacements);
    defer gpu.deinit();
    var driver: srd3d.srd3d.Driver = try .init(arena, gpu.interface());
    defer driver.deinit();
    // The GPU keeps its own copy of the textures, and takes the mods' pictures compressed, which
    // the texture cache keeps between runs.
    textures.release_held = true;
    var texture_store: platform.texture_cache.Store = undefined;
    if (options.texture_compression) {
        texture_store = .{ .io = io, .root = directory, .takes = gpu.compressed };
        textures.compressor = texture_store.compressor();
    }
    // The mods' shaders: the player scripts register them, and the GPU draws them while MOD
    // EFFECTS is on. `stop` removes them before the GPU is destroyed.
    var mod_shaders: ModShaders = .{
        .gpa = gpa,
        .gpu = gpu,
        .cache = shader_cache,
        .presentation = presentation,
        .textures = &textures,
        .template = whole.template,
    };
    mod_shaders.start();
    defer mod_shaders.stop();
    gpu.mod_effects = options.mod_effects;
    var pacer: platform.window.Pacer = .{};
    // How the frames are paced, which the settings screen changes as the game plays.
    var pacing = options.pacing();

    var context: srapi.Context = .{
        .projection = (camera.Camera{}).projection(initial_size[0], initial_size[1]),
        .detail = game.main.detailDivisor(details.graphic),
        .finer = options.detail_reach.finer(),
    };
    var devices: engine.input.Devices = .{};
    if (presentation) |shown| devices.mod_actions = &shown.runtime.input_actions;
    // As `WinMain` starts, the keys named as the keyboard's layout names them (`key_names_rename`,
    // `0x004A8F82`).
    platform.keyboard.nameKeys(&devices.key_names);
    // `default.txt`, the bindings `key_config_defaults` starts from, or a mod's replacement for it;
    // without it, the executable's built-in bindings.
    devices.defaults_file = if (readGameFile(io, arena, directory, &mods, game.interface.defaults_name)) |text| .{ .text = text } else |err| none: {
        std.log.warn("can't read {s}: {s}", .{ game.interface.defaults_name, @errorName(err) });
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
    var presenter: Presenter = .{ .window = &window, .gpu = gpu, .driver = &driver, .context = &context };
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
        .mod_effects = &gpu.mod_effects,
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
        .disc = &disc,
        .typed = &typed,
    };
    if (options.intro and options.mission == null and options.screenshot == null) {
        for (game.xtrabits.movie.intro) |name| _ = try movies.play(name, .cleared) orelse return;
    }
    // The outline fonts that draw the interface text at the window's resolution, through FreeType:
    // the built-in Newtown, and fonts from mods that replace the bitmap fonts. Only the bitmap
    // fonts are used with `--bitmap-fonts`, or if FreeType doesn't start.
    var free_type: ?platform.fonts.FreeType = if (options.outline_fonts) platform.fonts.FreeType.init() catch null else null;
    defer if (free_type) |*library| library.deinit();
    var outlines: game.hud.outline.Outlines = .init(gpa, if (free_type) |*library| library.rasterizer() else null, &mods);
    defer outlines.deinit();
    // Script font faces must close before the rasterizer, and images before the device.
    defer if (presentation) |shown| shown.assets.deinit(gpa);
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
    var rand: engine.random.Random = .{};
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
    tables.addTypes();
    tables.load(ship_stats);
    var cockpit: game.main.cockpit.Cockpit = .{};
    defer cockpit.deinit();
    var types: game.create.library.TypeCache = .{
        .gpa = gpa,
        .resources = &resources,
        .textures = &textures,
        .models = models,
        .looks = .{ .light_sprites = try .load(&textures), .glows = &glows, .flashes = &flashes },
        .global_palette = global_palette,
        .display_shapes = shapes,
    };
    defer types.deinit();
    // The objects, every slot standing in until a mission's start makes them, with every gun's,
    // missile's and pilot's figures; the loadout's ship, where one is chosen.
    const objects = try game.create.Objects.create(gpa, &rand);
    defer objects.destroy();
    objects.gun_stats.addTypes();
    objects.gun_stats.load(gun_stats);
    objects.missile_stats.addTypes();
    objects.missile_stats.load(missile_stats);
    objects.pilots.load(pilot_stats);
    if (asked_ship) |chosen| objects.loadout_ships[objects.player] = @fromBackingInt(chosen);
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
    _ = platform.joystick.addMappings(try std.Io.Dir.path.joinZ(arena, &.{ game_path, platform.joystick.mappings_name }));
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
    const video_settings: game.interface.settings.Video = .{ .camera = &view, .surrender = &context, .gamma = gpu.interface().setsGamma(), .transitions = &movies.transitions };
    var last_view = view.view;
    // The mission's clocks, which `mission_run` zeroes before it loops.
    var clock: game.main.Clock = .{};
    // Lines of speech that nobody hears, as with `--no-sound`, are timed by the game's clock.
    sound.clock = &clock;
    clock.start(platform.window.ticks());
    movies.timer = .{ .clock = &clock, .sound = sound };
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
    tractors.look.glow = options.beam_glow;
    var rippers: game.airipper.Rippers = try .init(gpa, &textures);
    defer rippers.deinit();
    var jump_effects: game.jump.effect.Effects = undefined;
    try jump_effects.init(gpa, &textures);
    defer jump_effects.deinit();
    jump_effects.lighting = options.jump_light;
    rippers.look.glow = options.beam_glow;
    var atmospheres: game.create.atmosphere.Atmospheres = try .init(gpa, &textures);
    defer atmospheres.deinit();
    atmospheres.style = options.atmospheres;
    var flash: game.main.flash.Flash = .{};
    // The countermeasures' model, read once for the whole run, as `decoys_init` reads it.
    var effects_models: game.create.library.MountCache = .{ .gpa = arena, .resources = &resources, .textures = &textures, .models = models };
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
    var shields: game.shield.Shields = try .create(gpa, &textures, explosions.settings.detail, options.shields);
    defer shields.deinit(gpa);
    environment.ice_field = try .create(arena, &textures, explosions.settings.detail, options.ice_field, &rand);
    var gates: game.wgate.Gates = try .init(gpa, &textures, explosions.settings.detail, options.gates);
    defer gates.deinit();
    // The force feedback's effects, and what plays them on the player's controller.
    const forces_library = engine.input.force.load(io, arena, directory, &mods);
    var force_feedback: engine.input.force.Forces = .{ .library = &forces_library, .settings = options.forces };
    // What the objects run in, the camera's view brought up to date each frame.
    var world: game.gameobj.World = .{ .forces = &force_feedback, .objects = objects, .player = &player, .clock = &clock, .view = view.view, .shake = &view.hit_shake, .random = &rand, .difficulty = options.difficulty orelse .medium, .hangar_beacons = options.hangar_beacons, .touchdown = options.touchdown, .hearing = hearing, .camera = &view, .explosions = &explosions, .particles = &particles, .smoke = &smoke, .gun_particles = &gun_particles, .shockwaves = &shockwaves, .trails = &trails, .countermeasures = &countermeasures, .sparks = &sparks, .shields = &shields, .rays = &rays, .tractors = &tractors, .rippers = &rippers, .jump_effects = &jump_effects, .atmospheres = &atmospheres, .escort_marker = escort_marker, .flash = &flash, .spawn = .{ .tables = tables, .types = types.types() }, .environment = &environment, .radio = &radio, .gates = &gates };

    world.launch_steam = options.launch_steam;

    // The pause menu, which stands in the display's place while the game is paused.
    var pause_menu: game.hudoptions.PauseMenu = .{};
    defer pause_menu.close();
    // The head-up display: what it draws with, and what draws it over the finished scene.
    var display: Display = .{
        .resources = try .load(arena, resources, shapes, &outlines),
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
    // A switch of view picks the subtarget's parts out in red or puts them back (`camera_set_view`).
    view.subtarget = .{ .shown = &display.state.subtarget, .all = objects };

    // The mods' global scripts, which run while a game runs: from the front end's start of a game,
    // or `--mission`'s, to the main menu or the end. They stop after the mission's end below.
    var game_scripts: GameScripts = .{ .gpa = gpa, .io = io, .mods = mods.list, .records = &records, .objects = objects, .presentation = presentation, .shared = shared };
    display.presentation = presentation;
    // The display's font as the player and menu scripts write in it over the display and the pause
    // menu: in one colour, as the menus' fonts are, so that its text takes the colour a script
    // gives.
    var script_font: ?game.hud.FontFile = if (presentation != null) game.hud.FontFile.read(gpa, resources, game.hud.Resources.font_name, &outlines) else null;
    defer if (script_font) |*font| font.deinit(gpa);
    var script_small: ?game.hud.FontFile = if (presentation != null) game.hud.FontFile.read(gpa, resources, game.hud.small_menu_font, &outlines) else null;
    defer if (script_small) |*font| font.deinit(gpa);
    var script_large: ?game.hud.FontFile = if (presentation != null) game.hud.FontFile.read(gpa, resources, game.hud.large_menu_font, &outlines) else null;
    defer if (script_large) |*font| font.deinit(gpa);
    // The player and menu scripts' frames, in the main loop, the rooms and the movies.
    var script_frames: ?ScriptFrames = if (presentation) |shown| .{ .gpa = gpa, .presentation = shown, .devices = &devices, .sound = sound, .rasterizer = outlines.rasterizer } else null;
    if (script_frames) |*frames| {
        frames.fonts.set(.hud, if (script_font) |*font| &font.font else null);
        frames.fonts.set(.menu_small, if (script_small) |*font| &font.font else null);
        frames.fonts.set(.menu_large, if (script_large) |*font| &font.font else null);
        frames.presented_at = platform.window.nanoseconds();
        movies.scripts = frames;
        loading.scripts = frames;
    }
    defer game_scripts.deinit();
    // The scripting console, in the developer mode where a mod has scripts, which F11 brings up
    // over the front end or the mission.
    var console = if (options.developer_mode) ScriptConsole.init(gpa, mods.list) else null;
    defer if (console) |*shown| shown.deinit();
    display.console = if (console) |*shown| shown else null;
    if (script_frames) |*frames| frames.console = display.console;
    // The front end, where the game opens unless `--mission` names a mission, with the pilot it
    // sets, who flies every mission; and the pilot's profile, whose call sign the pilot takes as
    // the game starts (`campaign_new`).
    var front: engine.genilib.interf.Interface = .{ .pilot = .{ .difficulty = options.difficulty orelse .easy } };
    defer front.deinit();
    var pilot_profile: game.gameflow.ProfileFile = .{
        .io = io,
        .dir = directory,
        .default_name = strings.string(@backingInt(game.interface.pilot_roster.String.player)) orelse "",
    };
    pilot_profile.open(&front.pilot.call_sign);
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
        .objects = objects,
        .player = &player,
        .pilot = &front.pilot,
        .pilot_profile = &pilot_profile,
        .presentation = presentation,
    };
    defer play.end();
    display.play = &play;
    const asked_parts = try partsNamed(arena, play.number, play.file, if (options.mission != null) options.parts() else &.{});
    const watched = if (options.mission == null) null else options.watch;
    var watch: Watch = .{
        .slot = if (watched) |name| try shipToWatch(play.number, play.file, name) else null,
        .from = options.watch_from,
    };
    if (options.mission != null) {
        try game_scripts.start();
        try play.start(.{ .world = world, .devices = &devices });
    }
    // What the front end draws with, and where the game is between it and the missions.
    var front_resources: ?engine.genilib.interf.Resources = null;
    defer if (front_resources) |*open| open.close();
    var flow: Flow = .{ .in_front_end = options.mission == null, .scripts = &game_scripts, .modes = &game_modes };
    // The campaign's saved loadout, which `campaign_new` starts in the Predator, and which the
    // saved games keep.
    var saved_loadout: engine.interface.loadout.Saved = .{};
    const saving: Saving = .{
        .gpa = gpa,
        .folder = .{ .io = io, .dir = directory, .extra = game_scripts.extra() },
        .scripts = &game_scripts,
        .player = &player,
        .tier = &objects.campaign_tier,
        .pilot = &front.pilot,
        .saved = &saved_loadout,
        .wingmen = &objects.wingmen,
        .pilot_profile = &pilot_profile,
        .strings = &strings,
    };
    // The list of call signs, which `WinMain` reads and writes straight back (`0x004A919B`).
    if (flow.in_front_end) {
        front.pilot_roster.list = game.winmain.loadCallSigns(settings_file.profile, pilot_profile.default_name);
        try game.winmain.saveCallSigns(&front.pilot_roster.list, settings_file);
    }
    var front_ticks = platform.window.ticks();
    // When the mods' storage was last written (`storage_interval`).
    var storage_written_at = platform.window.nanoseconds();
    // The file's name of the mission the scripts reload in.
    var reload_file: [game.winmain.mission_path_size]u8 = undefined;
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
        .pilot_profile = &pilot_profile,
        .own = own.interface(),
        .video = video_settings,
        .saves = .{ .gpa = gpa, .folder = saving.folder, .game = saving.gameOf(&flow.loading), .strings = &strings, .local_time = localDate },
        // The mods screen, which with `--no-mods` stays shut.
        .mods = if (options.mods) .{ .loaded = &mods, .gpa = gpa, .io = io, .game = directory, .version = version.semantic, .pages = option_pages.pages() } else null,
        .modes = game_modes.shown.items,
        // The menu scripts' screens that stand in for the front end's own.
        .scripted = if (presentation) |shown| shown.scripted() else null,
    };
    // The Reliant's rooms and the briefing, which run in loops of their own, with what they read,
    // play and draw with: made as the front end's resources open.
    var rooms: ?Rooms = null;
    // A piece of music asked for, as a mission's script plays one (`cmd_PlayMusic`): from `music\`,
    // for ever, at 80.
    if (options.music) |name| {
        const path = try arena.print("music\\{s}", .{name});
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
    var player_launch: PlayerLaunch = .{ .under_way = options.mission != null };
    while (true) {
        if (platform.window.nanoseconds() -| storage_written_at >= storage_interval) {
            storage.flush();
            storage_written_at = platform.window.nanoseconds();
        }
        if (movies.controllers_changed) {
            movies.controllers_changed = false;
            if (options.screenshot == null) connectController(arena, &devices, &controller, settings_file.profile);
        }
        // The wheel's notches no screen took last pass are let go.
        _ = devices.mouse.notches();
        while (window.poll()) |event| switch (event) {
            .quit => return,
            .key => |key| if (options.screenshot == null) {
                devices.keyboard.down[@backingInt(key.scan)] = key.down;
                if (script_frames) |*frames| frames.key(key.scan, key.down);
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
        const size = presenter.size();
        // The scripting console, which takes the keys while it's up. The scripts reload when it
        // asks, and when a folder mod's script or shader is saved.
        if (console) |*shown| {
            devices.keyboard.read();
            const mission = !flow.in_front_end and play.loaded != null;
            var reloading = shown.watch.changed(io, mods.list, platform.window.nanoseconds());
            if (shown.isUp()) {
                if (try shown.frame(&devices, &typed, size, game_scripts.reachable())) |asked| switch (asked) {
                    .close => try shown.takeAway(pausing),
                    .reload => reloading = true,
                };
            } else if (ScriptConsole.asked(&devices.keyboard)) try shown.bringUp(pausing, mission, &typed);
            if (reloading) try game_scripts.reload(if (mission) .{
                .orders = .{ .world = world, .devices = &devices },
                .mission = game.main.scriptMission(&reload_file, objects, play.number),
                .seed = game.main.scriptSeed(world.random, play.number),
            } else null);
        }
        const console_up = if (console) |*shown| shown.isUp() else false;

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
                    .models = models,
                    .loadout_look = options.loadout_look,
                    .saved = &saved_loadout,
                    .stats = tables,
                    .missile_stats = &objects.missile_stats,
                    .tier = &objects.campaign_tier,
                    .pilot = &front.pilot,
                    .pilot_profile = &pilot_profile,
                    .player = &player,
                    .campaign_flown = &flow.campaign,
                    .wingmen = &objects.wingmen,
                    .itac_strings = &itac_strings,
                    .saves = saving.folder,
                    .local_time = localDate,
                    .settings_file = settings_file,
                    .own = own.interface(),
                    .video = video_settings,
                    .console = if (console) |*shown| .{ .shown = shown, .scripts = &game_scripts } else null,
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
            // While the console is up, it takes the pass.
            const front_outcome = if (console_up) null else front.frame(front_context);
            // The movie a menu script asked for (`ui.play_movie`).
            if (presentation) |shown| if (shown.takeMovie()) |name| {
                _ = try movies.play(name, .cleared) orelse return;
            };
            // What the player set on the mods screen goes to the mod's menu scripts.
            while (option_pages.takeChange()) |change| {
                if (presentation) |shown| shown.settingChanged(change.mod, change.key, change.value);
            }
            if (front_outcome) |outcome| {
                const through = &rooms.?;
                switch (outcome) {
                    .fly, .campaign, .loaded => try game_scripts.start(),
                    // The scripts start knowing the mode and its mission (`core.game_mode`).
                    .game_mode => |mode| {
                        game_modes.start(mode);
                        try game_scripts.start();
                    },
                    .quit, .briefing, .mode_mission, .mode_left => {},
                }
                flow.next = switch (outcome) {
                    .quit => return,
                    .fly => |flight| fly: {
                        flow.campaign = null;
                        break :fly .{ .flight = flight };
                    },
                    // A game mode's first mission, which the main menu flies as it flies INSTANT
                    // ACTION's, after the mode's briefing where it has one, the next following as
                    // each ends (`missionEnded`).
                    .game_mode => {
                        flow.campaign = null;
                        front.brief();
                        continue;
                    },
                    .mode_mission => .{ .flight = modeFlight(&game_modes) },
                    // The player left the mode from its briefing, for the screen the front end
                    // shows.
                    .mode_left => {
                        flow.scripts.stop();
                        game_modes.running = null;
                        continue;
                    },
                    // START GAME: `WinMain` takes a new campaign into the Reliant's rooms, whose
                    // briefing room's door leads to the briefing, and the mission.
                    .campaign => |mission| fly: {
                        flow.campaign = .begin();
                        saving.gameOf(&flow.campaign.?).clearPilot();
                        pilot_profile.open(&front.pilot.call_sign);
                        objects.mission25_second_part = false;
                        const flight = briefedFlight(try through.campaign(mission) orelse return, objects, asked_ship) orelse {
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
                        const flight = briefedFlight(try through.campaign(flow.campaign.?.mission) orelse return, objects, asked_ship) orelse {
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
            objects.loadout_ships[objects.player] = if (flight.ship orelse asked_ship) |ship| @fromBackingInt(ship) else null;
            objects.loadout_racks[objects.player] = flight.racks;
            objects.simulator = flight.simulator;
            // The simulator pod's missions run on the campaign's variables too, as the game's are
            // the campaign's, but `WinMain` keeps no restart point for them.
            play.campaign = if (flow.campaign) |*going| going else null;
            if (flight.byWinMain()) if (flow.campaign) |*going| {
                flow.restart_point = try saving.restartPoint(going);
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
            try play.start(.{ .world = world, .devices = &devices });
            flow.in_front_end = false;
            flow.from_front_end = true;
        }
        // The movie a screen of the front end plays as it leads to another.
        if (front.movie) |name| {
            front.movie = null;
            _ = try movies.play(name, .over_screen) orelse return;
        }
        // The window takes text while the front end has a line to type into.
        window.takeText(console_up or (flow.in_front_end and front.takesText()));
        const orders: game.aigeneric.Context = .{ .world = world, .devices = &devices };
        const slot = &objects.slots[objects.player];
        if (!flow.in_front_end) {
            // The timer's ticks since the last pass, then a game tick for each, as `mission_run` paces
            // them: the simulation steps on every fourth, reading the keyboard as it goes, and runs the
            // objects' updates. A screenshot takes one tick a frame so that the camera settles the same
            // way on every run.
            const now = platform.window.nanoseconds();
            if (options.skip_launch and player_launch.under_way) {
                clock.advanceBy(now / platform.window.tick_nanoseconds, PlayerLaunch.skip_ticks);
            } else if (frames_left != null) clock.advanceBy(now / platform.window.tick_nanoseconds, 1) else clock.advanceToFine(now, platform.window.tick_nanoseconds);
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
                        if (!try missionEnded(&flow, &front, &play, &rooms.?, objects, world.player, saving, asked_ship, sound, &movies, &resources)) return;
                        continue;
                    } else if (endsInPauseMenu(options, frames_left)) {
                        play.over = true;
                        try game.main.pause(pausing, true);
                    } else {
                        // Starting the mission again lets go of the one that ended, which the world
                        // and the orders were pointed at as this pass began, so the rest of the pass
                        // is left out. The next pass points them at the new mission.
                        try play.again(orders);
                        continue;
                    }
                }
                if (test_keys.active(play.number)) {
                    // A change of ship starts the mission again, which leaves the rest of the pass
                    // out likewise.
                    const changed = for (test_keys.ship_keys) |step| {
                        if (devices.keyboard.pressed(@backingInt(step[0]), .none, true)) {
                            try play.changeShip(orders, step[1]);
                            break true;
                        }
                    } else false;
                    if (changed) continue;
                    if (devices.keyboard.pressed(@backingInt(test_keys.wing_key), .none, true)) test_keys.bringWing(orders);
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
                switch (player_launch.step(slot, clock.mission_ticks)) {
                    .under_way => if (options.skip_launch) continue,
                    .ended => {
                        if (play.loaded) |loaded| for (asked_parts) |part| loaded.runPart(orders, part);
                        watch.frame(&view, objects, clock.viewTime());
                    },
                    .over => watch.frame(&view, objects, clock.viewTime()),
                }
            }
        }

        // The player and menu scripts' frame, before anything is drawn, with what each of their
        // layers is drawn on.
        if (script_frames) |*frames| {
            const shown = frames.presentation;
            var host = frames.host(size, !flow.in_front_end and !clock.paused);
            if (flow.in_front_end) {
                const fonts = &front_resources.?;
                frames.show(&host, .ui, &fonts.small.font, game.interface.canvas.scaleFor(size), if (fonts.shapes) |*art| art else null);
            } else {
                const layer: scripting.drawing.Which = if (pause_menu.isOpen()) .ui else .hud;
                if (script_font) |*file| frames.show(&host, layer, &file.font, game.hud.scaleFor(size), &display.resources.art);
                host.camera = .{ .camera = &view, .now = clock.viewTime(), .player = objects.player };
            }
            if (shown.runtime.registries.selected_screen != null and host.views.get(.ui) == null) host.views.set(.ui, host.views.get(.hud));
            shown.frame(host);
            if (host.camera != null) {
                objects.slots[objects.player].object.flags.hidden = view.inside(objects.player);
            }
        }

        _ = frame_arena.reset(.retain_capacity);
        if (flow.in_front_end) {
            // The screen a transition's movie or a mission's end has just led to entered before
            // its first frame is drawn, as each of the game's screens enters before its loop.
            front.enterShown(front_context);
            var shown: FrontEndDisplay = .{ .front = &front, .resources = &front_resources.?, .target = gpu.interface(), .window = size, .strings = &strings, .settings = .{ .devices = &devices, .sound = sound, .video = video_settings }, .presentation = presentation, .console = if (console) |*up| up else null };
            scene.clear();
            try srcore.render(frame_arena.allocator(), &context, &scene, driver.interface(), shown.overlay());
        } else {
            context.camera = .{ .position = view.place.position, .orientation = view.place.orientation };
            context.projection = view.projection(size[0], size[1]);
            // The cockpit's model hangs from the camera, and the radar's backing stands on the radar.
            if (cockpit.shown) |*shown| if (view.cockpit_place) |placed| game.main.cockpit.place(&shown.model, view.place, placed);
            backing.place(context.projection, view.place, game.hud.scaleFor(size));
            display.device = gpu.interface();
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
            if (!clock.paused and game.main.screenshotAsked(&devices.keyboard)) presenter.saveScreenshot(gpa, &screenshots);
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
                            // The mission ends before the mods' scripts go back to the restart
                            // point, so that they don't hear it end.
                            play.end();
                            try saving.restart(campaign, if (flow.restart_point) |*point| point else null);
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
                        if (!try missionEnded(&flow, &front, &play, &rooms.?, objects, world.player, saving, asked_ship, sound, &movies, &resources)) return;
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
            engine.files.writeFile(io, directory, engine.profile.settings_name, settings_file.profile.text) catch |err|
                std.log.warn("the settings can't be saved to {s}: {t}", .{ engine.profile.settings_name, err });
        }
        if (frames_left) |*left| {
            left.* -= 1;
            if (left.* == 0) {
                const frame = try presenter.capture(frame_arena.allocator());
                return writeScreenshot(io, frame_arena.allocator(), options.screenshot.?, frame.rgba, frame.size);
            }
        }
        // The pixels of the textures that went up to the GPU this frame are let go of.
        textures.releaseHeld();
        if (pacing.rate(window)) |rate| pacer.wait(rate);
    }
}

/// The ship type `--ship` names: by its number, one the game has a model for or a mod adds; or
/// by its name, one of the game's (`predator`) or a mod's (`teapot:teapot`). Null for none.
fn shipNamed(text: []const u8) ?game.create.TypeIndex {
    const object_type: game.gameobj.Type = if (std.fmt.parseInt(u16, text, 0)) |number|
        @fromBackingInt(number)
    else |_|
        game.gameobj.Type.fromScriptName(text) orelse return null;
    if (object_type.added() == null) {
        const number = object_type.number();
        if (number >= game.create.models.ship_types.len or game.create.models.ship_types[number].model == null) return null;
    }
    return @intCast(object_type.number());
}

test shipNamed {
    // The Predator by its number or its name; a number without a model, and a name no type has.
    try std.testing.expectEqual(0, shipNamed("0"));
    try std.testing.expectEqual(0, shipNamed("predator"));
    try std.testing.expectEqual(null, shipNamed("999"));
    try std.testing.expectEqual(null, shipNamed("viper:viper"));
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
    if (std.Io.Dir.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
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

/// The player's launch at the start of a `--mission`, which `--skip-launch` plays through without
/// drawing it, each frame running `skip_ticks` ticks as at 60 frames a second, and after which the
/// parts `--part` names run (`partsNamed`). It is under way from the mission's start until the
/// player's ship has been under its Launch order and no longer is; or, for a mission whose player
/// doesn't launch, until `give_up_ticks` pass without the launch starting.
const PlayerLaunch = struct {
    under_way: bool,
    launched: bool = false,

    const skip_ticks = 2;
    const give_up_ticks = 600;

    const Step = enum { under_way, ended, over };

    /// Where the launch is at `ticks` into the mission, with the player's ship in `slot`: still
    /// under way, ended on this frame, or over since an earlier one.
    fn step(launch: *PlayerLaunch, slot: *const game.create.Slot, ticks: i32) Step {
        if (!launch.under_way) return .over;
        const launching = if (slot.current()) |entry| entry.order == .launch else false;
        if (launching) launch.launched = true;
        if (launch.launched and !launching or !launch.launched and ticks >= give_up_ticks) {
            launch.under_way = false;
            return .ended;
        }
        return .under_way;
    }
};

test PlayerLaunch {
    var mission: game.gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ship = try mission.add(.of(.predator), @splat(0));
    const slot = mission.slot(ship);
    // Before the launch starts, and while it runs, it is under way.
    var launch: PlayerLaunch = .{ .under_way = true };
    try std.testing.expectEqual(.under_way, launch.step(slot, 10));
    try std.testing.expect(try game.aigeneric.push(mission.orders(), ship, .launch, .none));
    try std.testing.expectEqual(.under_way, launch.step(slot, 20));
    // Once the ship is out of its Launch order, it ends, and stays over.
    try std.testing.expect(try game.aigeneric.push(mission.orders(), ship, .player_control, .none));
    try std.testing.expectEqual(.ended, launch.step(slot, 30));
    try std.testing.expectEqual(.over, launch.step(slot, 40));
    // A mission whose player never launches ends it once the wait runs out.
    var waiting: PlayerLaunch = .{ .under_way = true };
    try std.testing.expectEqual(.ended, waiting.step(mission.slot(try mission.add(.of(.predator), @splat(0))), PlayerLaunch.give_up_ticks));
    // Outside a `--mission`, there is none to watch.
    var none: PlayerLaunch = .{ .under_way = false };
    try std.testing.expectEqual(.over, none.step(slot, 0));
}

/// `--watch`: once the player's launch is over and the ship is there, the camera watches it
/// (`camera.View.watch`) from `from`, in the ship's own axes, in multiples of its radius, and moves
/// with it. The view is locked, so the player's keys leave it. The mission's script can still take
/// the camera, as for a cutscene, and then keeps it.
const Watch = struct {
    /// The ship's slot.
    slot: ?u16,
    from: [3]f32,
    /// Whether the camera has been set on the ship.
    started: bool = false,

    /// Places the camera `view` by the ship, where it is one of `all`'s objects and is there, at
    /// `now` on the view's clock, after the camera's own frame.
    fn frame(watch: *Watch, view: *camera.Camera, all: *const game.create.Objects, now: u32) void {
        const index = watch.slot orelse return;
        if (index >= all.slots.len) return;
        const slot = &all.slots[index];
        if (!slot.object.created or slot.object.flags.stand_in) return;
        if (!watch.started) {
            if (!view.setView(.watch, index, true, true, now)) return;
            watch.started = true;
        } else if (view.view != .watch or view.object != index) {
            watch.slot = null;
            return;
        }
        const seen: camera.Subject = .of(slot);
        const from: math.Vector = .{ watch.from[0], watch.from[1], watch.from[2] };
        view.place = camera.lookingAt(seen.place().point(from * @as(math.Vector, @splat(seen.radius))), seen.position);
    }
};

test Watch {
    var mission: game.gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var view: camera.Camera = .{};
    // A ship not made yet is waited for.
    var watch: Watch = .{ .slot = 3, .from = .{ 0, 0, 2 } };
    watch.frame(&view, mission.objects, 0);
    try std.testing.expect(!watch.started);
    // Once it is there, the camera watches it from twice its radius ahead, and moves with it.
    const ship = try mission.add(.of(.predator), .{ 100, 0, 0 });
    watch.slot = ship;
    const slot = mission.slot(ship);
    slot.drawn = .{ .position = .{ 100, 0, 0 }, .orientation = math.identity };
    slot.object.radius = 10;
    watch.frame(&view, mission.objects, 0);
    try std.testing.expectEqual(camera.View.watch, view.view);
    try std.testing.expectEqual(ship, view.object.?);
    try std.testing.expect(view.locked);
    try std.testing.expectEqual(math.Vector{ 100, 0, 20 }, view.place.position);
    slot.drawn.position = .{ 100, 0, 50 };
    watch.frame(&view, mission.objects, 1);
    try std.testing.expectEqual(math.Vector{ 100, 0, 70 }, view.place.position);
    // Once the script takes the camera, it keeps it.
    try std.testing.expect(view.setView(.director, null, true, true, 2));
    watch.frame(&view, mission.objects, 2);
    try std.testing.expectEqual(null, watch.slot);
    try std.testing.expectEqual(camera.View.director, view.view);
}

/// The slot of the ship that `name` picks in `file`, mission `number`'s file
/// (`dte.Mission.findShip`), whose object the mission's ship at that place in the table takes; or
/// an error, said on the console, for a name that picks none or more than one ship.
fn shipToWatch(number: u16, file: []const u8, name: []const u8) !u16 {
    const mission: dte.Mission = try .parse(file);
    return switch (try mission.findShip(name)) {
        .one => |index| std.math.cast(u16, index) orelse error.UnknownShip,
        .none => {
            std.log.err("--watch: mission {d} has no ship '{s}'; sltool dte ships lists them", .{ number, name });
            return error.UnknownShip;
        },
        .several => {
            std.log.err("--watch: '{s}' is in the names of more than one ship; sltool dte ships lists them", .{name});
            return error.UnknownShip;
        },
    };
}

/// The script parts that `names` pick in `file`, the mission's file, in the same order
/// (`dte.Mission.findPart`); or an error, said on the console, for a name that picks none or more
/// than one part, or a part that takes arguments.
fn partsNamed(arena: Allocator, number: u16, file: []const u8, names: []const []const u8) ![]const dte.Part {
    if (names.len == 0) return &.{};
    const mission: dte.Mission = try .parse(file);
    const all = try mission.parts();
    const picked = try arena.alloc(dte.Part, names.len);
    for (picked, names) |*part, name| {
        part.* = switch (try mission.findPart(name)) {
            .one => |index| all[index],
            .none => {
                std.log.err("--part: mission {d} has no script part '{s}'; sltool dte parts lists them", .{ number, name });
                return error.UnknownPart;
            },
            .several => {
                std.log.err("--part: '{s}' is in the names of more than one script part; sltool dte parts lists them", .{name});
                return error.UnknownPart;
            },
        };
        if (part.arguments != 0) {
            std.log.err("--part: script part '{s}' takes arguments, which it can't be given", .{name});
            return error.UnknownPart;
        }
    }
    return picked;
}

test endsInPauseMenu {
    try std.testing.expect(endsInPauseMenu(try options_page.testing.parsed(&.{ "--mission", "1" }), null));
    try std.testing.expect(!endsInPauseMenu(try options_page.testing.parsed(&.{}), null));
    try std.testing.expect(!endsInPauseMenu(try options_page.testing.parsed(&.{ "--mission", "1", "--no-pause-menu" }), null));
    try std.testing.expect(!endsInPauseMenu(try options_page.testing.parsed(&.{ "--mission", "1" }), 2));
}

/// `WinMain`'s one-second wait before the hangar's movie (`game.winmain.launchFade`), with the
/// timer running from the start of the flight, so the music fades out during it. Like the game's,
/// the window waits without reading its messages, which the movie's loop then reads.
fn waitBeforeLaunch(clock: *game.main.Clock, sound: *game.hog_snd.Sound) void {
    const start = platform.window.nanoseconds();
    clock.start(platform.window.ticks());
    game.winmain.launchFade(sound, clock.game_ticks);
    var pacer: platform.window.Pacer = .{};
    while (platform.window.nanoseconds() - start < game.winmain.launch_wait) {
        pacer.wait(game.main.ticks_per_second);
        sound.runTimer(clock, platform.window.ticks());
    }
}

/// Where the game is between the front end and the missions, as `WinMain` goes from one to the
/// other: whether the front end is shown, and whether the mission flown was started from it; the
/// campaign it is flown in, none outside one; and the flight to start next, and the last started.
const Flow = struct {
    in_front_end: bool,
    /// The mods' global scripts, which stop as the game goes back to the main menu.
    scripts: *GameScripts,
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
    /// The game modes the mods registered, and the one running while it does.
    modes: *scripting.game_modes.Registry,

    /// Back to the front end's main menu, out of the campaign or the game mode, which ends the
    /// game's scripts.
    fn toFrontEnd(flow: *Flow, front: *engine.genilib.interf.Interface) void {
        flow.scripts.stop();
        front.back();
        flow.in_front_end = true;
        flow.from_front_end = false;
        flow.campaign = null;
        flow.modes.running = null;
    }

    /// To the briefing of the game mode that runs, before its next mission (`modeFlight`). The
    /// game's scripts go on running.
    fn toBriefing(flow: *Flow, front: *engine.genilib.interf.Interface) void {
        front.brief();
        flow.in_front_end = true;
        flow.from_front_end = false;
    }
};

/// The flight of the mission the game mode that runs is at, which the main menu flies, in the
/// mode's ship.
fn modeFlight(modes: *const scripting.game_modes.Registry) game.interface.main_menu.Flight {
    const ship = modes.current().?.ship;
    return .{
        .mission = modes.mission().?,
        .ship = if (ship) |chosen| @intCast(@backingInt(chosen)) else null,
        .flier = .main_menu,
    };
}

/// The local date and time of a moment, in nanoseconds from 1970 in UTC, as the system tells it,
/// which the saved games show the dates of their files by.
fn localDate(since_1970: i96) ?game.interface.saved_games.Date {
    const time = platform.window.localTime(std.math.cast(i64, since_1970) orelse return null) orelse return null;
    return .{ .year = time.year, .month = time.month, .day = time.day, .hour = time.hour, .minute = time.minute, .day_of_week = time.day_of_week };
}

/// What the saved games save and load, and where: the game's folder, and where the driver keeps
/// the pilot, the campaign's tier and the loadout's saved choice; the pilot's profile, which each
/// mission's end writes too; and the strings the autosave's name is written with.
const Saving = struct {
    gpa: Allocator,
    folder: save.Folder,
    /// The mods' scripts, whose state goes with the restart point.
    scripts: *GameScripts,
    player: *engine.input.Player,
    tier: *u2,
    pilot: *game.interface.pilot_roster.Pilot,
    saved: *engine.interface.loadout.Saved,
    wingmen: *game.pilots.Wingmen,
    pilot_profile: *game.gameflow.ProfileFile,
    strings: *const game.language.Language,

    /// The game of `campaign`, as a save takes it and puts it back.
    fn gameOf(saving: Saving, campaign: *game.gameflow.Campaign) save.Game {
        return .{ .campaign = campaign, .player = saving.player, .tier = saving.tier, .pilot = saving.pilot, .saved = saving.saved, .wingmen = saving.wingmen };
    }

    /// `restart_save` (`0x00475D20`), as `WinMain` saves the game before each attempt at a mission
    /// of `campaign` (`0x004AA3FC`).
    ///
    /// **Improvement:** OpenReliant keeps the restart point in memory, where the game writes it to
    /// the saves folder as saved game 100, named restart, and reads it back.
    fn restartPoint(saving: Saving, campaign: *game.gameflow.Campaign) Allocator.Error!save.Save {
        try saving.scripts.keepRestartPoint();
        return saving.gameOf(campaign).capture(save.restart_name);
    }

    /// `restart_load` (`0x00475D30`) of `point` into `campaign`, as a replay or the pause menu's
    /// RESTART turns back to the mission. The mods' scripts go back to their state at that point
    /// too.
    fn restart(saving: Saving, campaign: *game.gameflow.Campaign, point: ?*const save.Save) Allocator.Error!void {
        const kept = point orelse return;
        save.restartLoad(saving.gameOf(campaign), kept);
        try saving.scripts.backToRestartPoint();
    }

    /// What `mission_end_record` writes as the campaign moves on: the autosave (`save.autosave`),
    /// then the pilot's profile, with the campaign copied into it (`gameflow.Profile.keep`).
    fn saveRecord(saving: Saving, campaign: *game.gameflow.Campaign) void {
        const prefix = saving.strings.string(save.autosave_string) orelse "";
        save.autosave(saving.gameOf(campaign), saving.folder, saving.gpa, prefix) catch |err|
            std.log.warn("the game can't be saved: {s}", .{@errorName(err)});
        saving.pilot_profile.profile.keep(saving.gameOf(campaign).campaignRecord());
        saving.pilot_profile.save();
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
fn missionEnded(flow: *Flow, front: *engine.genilib.interf.Interface, play: *Play, rooms: *Rooms, all: *game.create.Objects, player: *engine.input.Player, saving: Saving, ship: ?game.create.TypeIndex, sound: *game.hog_snd.Sound, movies: *Movies, resources: *const game.bigfile.Hog) !bool {
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
    // A game mode goes on to the briefing of its next mission, or back to the main menu once it
    // is over (`game_modes.Registry.goesOn`).
    if (flow.modes.running != null) {
        const rating = if (play.loaded) |loaded| loaded.script.variables.mission_success else .failure;
        if (!try letGo(play, all, sound, null, movies, resources)) return false;
        if (flow.modes.goesOn(player.ending, rating) != null) flow.toBriefing(front) else flow.toFrontEnd(front);
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
fn briefedFlight(end: RoomsEnd, all: *game.create.Objects, ship: ?game.create.TypeIndex) ?game.interface.main_menu.Flight {
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
    fn briefed(end: RoomsEnd, all: *game.create.Objects, ship: ?game.create.TypeIndex) CampaignNext {
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
/// the movie of how it ended and the restart screen; the movie that ends the pilot's career; or
/// after the campaign's last mission, the story's end: the end briefing, the movies and the credits
/// (`game.xtrabits.ending`), then the main menu with the campaign back at its first mission. Null
/// where the game quits meanwhile.
///
/// **Fix:** after the pilot's execution in mission 25's second part, REPLAY MISSION FROM BRIEFING
/// replays the first part's briefing. The game flies the second part again at once, and leaves the
/// replay asked for, so that the next mission's briefing follows it without the rooms, from the
/// game's variables as the second part began.
fn campaignGoesOn(play: *Play, campaign: *game.gameflow.Campaign, rooms: *Rooms, all: *game.create.Objects, player: *engine.input.Player, saving: Saving, flown: game.interface.main_menu.Flight, restart_point: ?*const save.Save, ship: ?game.create.TypeIndex, sound: *game.hog_snd.Sound, movies: *Movies, resources: *const game.bigfile.Hog) !?CampaignNext {
    const loaded = play.loaded orelse return .main_menu;
    const variables = &loaded.script.variables;
    const landing = play.landing(player.ending, all.mission25_second_part);
    const after = game.winmain.afterMission(campaign, player, variables, play.number, &all.mission25_second_part, all.campaign_tier, &all.wingmen);
    switch (after) {
        .goes_on, .second_part => campaign.variables = variables.*,
        .restart, .career_over, .story_end => {},
    }
    if (!try letGo(play, all, sound, landing, movies, resources)) return null;
    switch (after) {
        .goes_on => |record| {
            all.campaign_tier = record.tier;
            if (record.medal) |medal| _ = try movies.play(medal.movie(), .cleared_from_disc) orelse return null;
            saving.saveRecord(campaign);
            switch (try rooms.itac(.after_mission, record.next) orelse return null) {
                .closed => return .briefed(try rooms.goOn(record.next) orelse return null, all, ship),
                .replay => {
                    try saving.restart(campaign, restart_point);
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
                    try saving.restart(campaign, restart_point);
                    all.mission25_second_part = false;
                    return .briefed(try rooms.replayBriefing(play.number) orelse return null, all, ship);
                },
                .replay_from_launch => {
                    try saving.restart(campaign, restart_point);
                    return .{ .fly = .{ .flight = flown, .hangar = false } };
                },
                .main_menu => return .main_menu,
            }
        },
        .career_over => |name| {
            _ = try movies.play(name, .cleared_from_disc) orelse return null;
            return .main_menu;
        },
        // The end briefing, the story's end and the credits, then the main menu with the campaign
        // back at its first mission (`0x004AA6F2` on).
        .story_end => {
            if (!try rooms.endBriefing()) return null;
            if (!try movies.storyEnd(game.xtrabits.ending.movies(variables))) return null;
            if (!try rooms.credits()) return null;
            campaign.mission = game.gameflow.first_mission;
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
    /// The player and menu scripts, which draw over the screen.
    presentation: ?*scripting.Presentation,
    /// The scripting console, drawn over the screen while it's up.
    console: ?*ScriptConsole,

    fn overlay(shown: *FrontEndDisplay) srcore.Overlay {
        return .{ .context = shown, .draw = draw };
    }

    fn draw(context: *anyopaque) Allocator.Error!void {
        const shown: *FrontEndDisplay = @ptrCast(@alignCast(context));
        try drawn(shown.front.draw(shown.resources, shown.target, shown.window, shown.strings, shown.settings, version.string));
        if (shown.presentation) |scripts| try scripts.draw(.ui, shown.target, null);
        // The pointer over a mod's screen that stands in for the front end's own.
        try drawn(shown.front.drawPointer(shown.resources, shown.target, shown.window, shown.strings));
        if (shown.console) |console| try console.draw(shown.target, shown.window, shown.strings, .menus);
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
    /// The player and menu scripts, which draw over the loading screen; null without them.
    scripts: ?*ScriptFrames = null,

    fn close(loading: *Loading) void {
        loading.resources.close();
    }

    /// The size the frames are drawn at.
    fn size(loading: *Loading) [2]u32 {
        return loading.presenter.size();
    }

    /// Draws `frame` and puts it on the window, after the scripts' frame.
    fn show(loading: *Loading, frame: game.xtrabits.loading.Frame) !void {
        loading.presenter.window.pump();
        loading.resources.show(loading.archive.*, frame);
        const pixels = loading.size();
        if (loading.scripts) |scripts| scripts.screenFrame(pixels);
        var shown: Shown = .{ .loading = loading, .window = pixels, .line = if (frame.line) |id| loading.strings.string(@backingInt(id)) else null };
        try loading.presenter.present(shown.overlay());
    }

    /// A frame's overlay: the loading screen, on the front end's screen fitted to the window, and
    /// what the scripts drew.
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
            const target = shown.loading.presenter.gpu.interface();
            try resources.draw(.{
                .gpa = resources.gpa,
                .target = target,
                .window = shown.window,
                .fonts = .{ .large = &resources.large.font, .small = &resources.small.font },
                .strings = shown.loading.strings,
                .version = version.string,
            }, shown.line);
            if (shown.loading.scripts) |scripts| try scripts.drawUi(target);
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
    /// The objects and the player, whose ending the mods' scripts hear as a mission ends.
    objects: *game.create.Objects,
    player: *const engine.input.Player,
    /// The pilot the front end set, and the pilot's profile, which each start writes with the
    /// pilot's call sign.
    pilot: *const game.interface.pilot_roster.Pilot,
    pilot_profile: *game.gameflow.ProfileFile,
    /// The player and menu scripts, which hear as each mission starts and ends.
    presentation: ?*scripting.Presentation = null,

    /// Starts the mission, letting go of the one before, the loading screen shown first
    /// (`game.xtrabits.loading.missionFrames`).
    fn start(play: *Play, orders: game.aigeneric.Context) !void {
        play.end();
        play.over = false;
        if (play.loading) |loading| {
            const frames = game.xtrabits.loading.missionFrames(loading.splash, loading.size()[0], orders.world.objects.simulator.mode);
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
            .profile = play.pilot_profile,
            .call_sign = play.pilot.call_sign.slice(),
        }, try play.gpa.dupe(u8, play.file), play.number);
        const all = orders.world.objects;
        if (play.presentation) |shown| {
            var file_buffer: [game.winmain.mission_path_size]u8 = undefined;
            shown.missionStarted(game.main.scriptMission(&file_buffer, all, play.number));
        }
        // A launch holds the camera until the ship is out; a ship that does not launch starts in
        // its view at once.
        if (!play.view.locked) _ = play.view.setView(startingView(&all.slots[all.player], play.view.cockpit_mode), all.player, false, true, play.clock.viewTime());
    }

    /// Starts the mission again as an attempt ends, or as RESTART starts it again: outside the
    /// campaign, the kills kept where the ending keeps them, as when the ejected pilot is picked up
    /// by a nanny ship (`gameflow.endMission`). The campaign records its missions only as they end
    /// (`campaignGoesOn`).
    fn again(play: *Play, orders: game.aigeneric.Context) !void {
        if (play.campaign == null) if (play.loaded) |loaded| {
            _ = game.gameflow.endMission(orders.world.player, &loaded.script.variables, play.number, orders.world.objects.campaign_tier, null, &orders.world.objects.wingmen);
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
            all.loadout_ships[all.player] = @fromBackingInt(@intCast(candidate));
            try play.start(orders);
            if (all.slots[all.player].type != null or candidate == was) return;
            std.log.warn("ship type {d} is left out: the game has no model for it", .{candidate});
        }
    }

    fn end(play: *Play) void {
        if (play.loaded) |loaded| {
            if (play.presentation) |shown| shown.missionEnded(game.main.scriptOutcome(play.player, loaded));
            game.main.endMission(play.objects, play.player, loaded);
        }
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

/// Reads the file of mission `number` as the game does (`game.mission.bind.read`): from a mod, the
/// game's `missions` folder, or `resource.hog`. Mission 0, OpenReliant's sandbox, comes from the
/// copy built into `openreliant` if the game has none.
fn missionFile(io: Io, arena: Allocator, directory: Io.Dir, resources: *const game.bigfile.Hog, number: u16, second_part: bool) ![]const u8 {
    var path_buffer: [game.winmain.mission_path_size]u8 = undefined;
    const path = game.winmain.missionPath(&path_buffer, number, second_part, false);
    if (try game.mission.bind.read(io, arena, directory, resources, path)) |file| {
        // A mod's mission names the ship types the mod adds by the numbers its manifest gives them.
        if (file.source == .mod) if (resources.mods.holder(engine.files.leaf(path))) |mod| game.additions.remapMission(file.image, mod.name);
        return file.image;
    }
    if (number == mission0.number) return @embedFile("mission0.dte");
    std.debug.print("openreliant: the game has no mission {d}: {s} isn't in a mod, the missions folder or {s}\n", .{ number, engine.files.leaf(path), game.bigfile.resource_name });
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
    /// The game's random numbers (`Random`), which the camera and the display both draw from.
    random: *engine.random.Random,
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
    /// The player and menu scripts, which draw over the display and the pause menu.
    presentation: ?*scripting.Presentation = null,
    /// The scripting console, which stands in the pause menu's place while it's up.
    console: ?*ScriptConsole = null,

    fn overlay(display: *Display) srcore.Overlay {
        return .{ .context = display, .draw = draw };
    }

    fn draw(context: *anyopaque) Allocator.Error!void {
        const display: *Display = @ptrCast(@alignCast(context));
        return drawn(display.drawOverlay());
    }

    /// What Surrender's overlay slot (`sr + 0x88`) holds: the pause menu while paused
    /// (`pause_menu_draw`), and the display otherwise (`hud_draw`), each with what the player and
    /// menu scripts draw over it.
    fn drawOverlay(display: *Display) !void {
        if (display.console) |console| if (console.isUp()) return console.draw(display.device, display.screen, display.strings, .mission);
        if (display.pause_menu.isOpen()) {
            try display.drawPauseMenu();
            if (display.presentation) |scripts| try scripts.draw(.ui, display.device, null);
            return;
        }
        try display.drawDisplay();
        if (display.presentation) |scripts| {
            try scripts.draw(.hud, display.device, display.sight);
            if (scripts.runtime.registries.selected_screen != null) try scripts.draw(.ui, display.device, null);
        }
    }

    fn drawPauseMenu(display: *Display) !void {
        return display.pause_menu.draw(.{
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
    }

    fn drawDisplay(display: *Display) !void {
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
    _ = @import("mod_shaders.zig");
    _ = @import("script_frames.zig");
    _ = @import("game_scripts.zig");
    _ = whole_shaders;
    _ = options_page;
    _ = settings_module;
    _ = install;
    _ = joysticks;
    _ = log_file;
    _ = mission0;
    _ = missions;
    _ = hooks_command;
    _ = test_keys;
    _ = version;
}
