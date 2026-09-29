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
const frameSize = presenting.frameSize;
const drawn = presenting.drawn;
const Rooms = @import("rooms.zig").Driver;
const test_keys = @import("test_keys.zig");
const version = @import("version.zig");

/// Everything `openreliant` takes on its command line, in the order the help page lists them.
const Arg = enum {
    @"--original",
    @"--mission",
    @"--ship",
    @"--view",
    @"--difficulty",
    @"--music",
    @"--no-pause-menu",
    @"--fullscreen",
    @"--size",
    @"--fps",
    @"--no-vsync",
    @"--software",
    @"--16-bit",
    @"--msaa",
    @"--filter",
    @"--no-bloom",
    @"--no-dither",
    @"--no-pixel-lighting",
    @"--gamma-space",
    @"--shadows",
    @"--no-cockpit-shadows",
    @"--no-smooth-motion",
    @"--few-shot-lights",
    @"--hrtf",
    @"--no-hrtf",
    @"--no-reverb",
    @"--no-compressor",
    @"--no-sound",
    @"--no-intro",
    @"--screenshot",
    @"--screenshot-ticks",
    @"--version",
    @"--help",

    /// The value it takes, as the help page shows it, or null for none.
    fn value(arg: Arg) ?[]const u8 {
        return docs.get(arg).value;
    }
};

/// The help page's sections, in order.
const Section = enum {
    original,
    mission,
    display,
    graphics,
    sound,
    other,

    fn title(section: Section) []const u8 {
        return switch (section) {
            .original => "The original",
            .mission => "The mission",
            .display => "Display",
            .graphics => "Graphics",
            .sound => "Sound",
            .other => "Other",
        };
    }
};

/// What the help page says of an option: its section, the value it takes, and what it does.
const Doc = struct {
    section: Section,
    value: ?[]const u8 = null,
    /// Another name for it, shown before it.
    alias: ?[]const u8 = null,
    text: []const u8,
};

/// Every option's help, which the compiler holds to having one for each.
const docs: std.enums.EnumArray(Arg, Doc) = .init(.{
    .@"--original" = .{ .section = .original, .text = "the original's look and sound: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, light worked out on encoded colours, no shadows, motion that moves on with the game's ticks, a launching ship a frame behind the retainer that lowers it, lights from the latest shots only, muzzle flashes that light nothing and none from the turrets, a jump's flare that lights nothing, the force feedback's own effects only, a blow shaking the camera only while the controller rumbles, an explosion's debris lit by every light, its fireballs, rings, particles and burning bits as few, plain and brief as the original's, the Uber Explode as coarse, unlit and tied to the frame rate as the original's, a damaged ship's smoke as even as the original's, the shields' bubbles as coarse as the original's, the tractor beams as thin as the original's, the hangar's beacons falling short of the launching ship, a ship landing on the Reliant tilted as it came, its tube's door left open, the planets' atmospheres as coarse and fleeting as the original's and their terminators as hard, the Ice Field's rocks drawn only near the middle of the view, the loading screen's picture picked by the screen's width, the movies drawn at their size in the middle of the screen with Bink's blocks and its colour in steps of two pixels, the gates' tunnels as coarse as the original's, the ride through the worm rumbling the more often the higher the frame rate, the sun and its lens flares from their small textures and the sun's glow going out at once behind what hides it, the levels of detail changing as near as the original's, as little drawn a frame as the original allows, the marker for a target out of sight placed as the original misplaces it, a missile's sound left where it was launched, the radio's lines cut flat at their loudest and heard dry, Enriquez's last word in the briefing as loud as its recording, and the sound mixed plainly in stereo" },
    .@"--mission" = .{ .section = .mission, .value = "<number>", .text = "play this mission at once rather than open the main menu: the number the game names its file by, mission<number>.dte, from the game's missions folder or resource.hog; 0 is OpenReliant's sandbox, which openreliant carries where the game has no mission 0" },
    .@"--ship" = .{ .section = .mission, .value = "<type>", .text = "the ship type to fly, by its number in shipstats.bin, in place of the loadout screen's choice, with its default missiles; the mission's own by default" },
    .@"--view" = .{ .section = .mission, .value = "<0|1|2>", .text = "the view it starts in, as the game's settings keep it: 0 the cockpit; 1 the chase view; 2 no cockpit. The settings' own by default, which the pause menu's video screen changes" },
    .@"--difficulty" = .{ .section = .mission, .value = "<easy|medium|hard>", .text = "the game's difficulty: how hard hits land on your ship, and shots on the enemy. By default, as in the game, medium with --mission, where a new campaign's starts, and easy in the main menu until SET GAME DIFFICULTY sets it" },
    .@"--music" = .{ .section = .mission, .value = "<file>", .text = "a piece from the game's music folder to play from the start, until the mission's script plays its own; none by default" },
    .@"--no-pause-menu" = .{ .section = .mission, .text = "with --mission, fly the mission again as soon as it ends, where it otherwise ends in the game's pause menu" },
    .@"--fullscreen" = .{ .section = .display, .text = "fill the display; Alt and Enter switch while playing" },
    .@"--size" = .{ .section = .display, .value = "<width>x<height>", .text = "draw frames of this size in pixels whatever the window's, which shows them scaled; for a screenshot larger than the display" },
    .@"--fps" = .{ .section = .display, .value = "<rate>", .text = "frames a second at most; without vsync, the display's rate by default; 0 for no limit" },
    .@"--no-vsync" = .{ .section = .display, .text = "draw without waiting for the display" },
    .@"--software" = .{ .section = .graphics, .text = "draw on the software device, OpenReliant's reference, rather than the GPU" },
    .@"--16-bit" = .{ .section = .graphics, .text = "16-bit colour, dithered" },
    .@"--msaa" = .{ .section = .graphics, .value = "<1|2|4|8>", .text = "samples a pixel, for smooth edges; 4 by default" },
    .@"--filter" = .{ .section = .graphics, .value = "<original|trilinear|crisp>", .text = "how textures are filtered; crisp by default" },
    .@"--no-bloom" = .{ .section = .graphics, .text = "draw without the bloom around bright things" },
    .@"--no-dither" = .{ .section = .graphics, .text = "draw 32-bit colour without dithering" },
    .@"--no-pixel-lighting" = .{ .section = .graphics, .text = "light each vertex rather than each pixel, as the original does" },
    .@"--gamma-space" = .{ .section = .graphics, .text = "light, blend and filter the encoded colours, as the original does, rather than in linear light" },
    .@"--no-cockpit-shadows" = .{ .section = .graphics, .text = "leave the shadows out of the cockpit, keeping them on the ships" },
    .@"--shadows" = .{ .section = .graphics, .value = "<off|low|high>", .text = "shadows from the sun: low is soft and light on older GPUs, high sharp and smooth; high by default, and none without lighting each pixel" },
    .@"--no-smooth-motion" = .{ .section = .graphics, .text = "move what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame" },
    .@"--few-shot-lights" = .{ .section = .graphics, .text = "light only the latest two of the player's shots and the latest two of everyone else's, as the original does" },
    .@"--hrtf" = .{ .section = .sound, .text = "place the sounds for headphones whatever the output; by default they are while the output is headphones" },
    .@"--no-hrtf" = .{ .section = .sound, .text = "place the sounds for speakers whatever the output" },
    .@"--no-reverb" = .{ .section = .sound, .text = "play the sounds around you, the cockpit's voice and the Reliant's rooms without reverb" },
    .@"--no-compressor" = .{ .section = .sound, .text = "leave the mix's loudness as it is, only keeping its peaks in check" },
    .@"--no-sound" = .{ .section = .sound, .text = "play without sound" },
    .@"--no-intro" = .{ .section = .other, .text = "start without the three movies the game plays as it starts, as --mission and --screenshot do" },
    .@"--screenshot" = .{ .section = .other, .value = "<file.png>", .text = "draw one frame, with the camera settled, to a PNG, and quit; the controls are not read, so that it comes out the same each time" },
    .@"--screenshot-ticks" = .{ .section = .other, .value = "<ticks>", .text = "with --screenshot, how many game ticks to run first, one a frame, so that the scene plays out; 2 by default" },
    .@"--version" = .{ .section = .other, .text = "show the version" },
    .@"--help" = .{ .section = .other, .alias = "-h", .text = "show this page" },
});

/// `openreliant --help`.
const help_page = page: {
    var out: []const u8 = help.paragraph("OpenReliant " ++ version.string ++ " plays StarLancer from an installed copy of the game.", 0) ++
        \\
        \\usage: openreliant [<game-directory>] [<option>...]
        \\       openreliant install [--from <disc>]... [--force] <directory>
        \\       openreliant joysticks [<game-directory>] [--watch]
        \\       openreliant missions [<game-directory>]
        \\
        \\
    ++ help.table(&.{.{ .typed = "<game-directory>", .text = "where StarLancer is installed, with resource.hog and tcachehw.dat; the current directory by default" }});
    for (std.enums.values(Section)) |section| {
        out = out ++ "\n" ++ section.title() ++ ":\n";
        if (section == .original) out = out ++ help.paragraph("OpenReliant improves on the original's look and sound. --original turns the improvements off, and an option after it turns one back on.", 2);
        var rows: []const help.Row = &.{};
        for (std.enums.values(Arg)) |arg| {
            const doc = docs.get(arg);
            if (doc.section != section) continue;
            const named = (if (doc.alias) |alias| alias ++ ", " else "") ++ @tagName(arg);
            rows = rows ++ .{help.Row{ .typed = if (doc.value) |shown| named ++ " " ++ shown else named, .text = doc.text }};
        }
        out = out ++ help.table(rows);
    }
    break :page out ++ "\nWhile playing:\n" ++
        help.paragraph("The flight keys are the game's own, as starlancer.ini binds them. OpenReliant adds:", 2) ++
        help.table(&.{
            .{ .typed = "F2, F3", .text = "in the sandbox, start it again in the previous or next ship type" },
            .{ .typed = "F4", .text = "in the sandbox, bring in another wing" },
            .{ .typed = "Alt+Enter", .text = "switch between the window and the full screen" },
            .{ .typed = "Escape", .text = "the pause menu, whose LEAVE MISSION quits" },
            .{ .typed = "0", .text = "save a screenshot, a PNG in the screenshots folder of the game's directory; O does the same in the briefing" },
        }) ++ "\nCommands:\n" ++
        help.table(&.{
            .{ .typed = "install", .text = "install the game's files from the StarLancer discs into a directory" },
            .{ .typed = "joysticks", .text = "list the joysticks and gamepads, and which one the game uses" },
            .{ .typed = "missions", .text = "list the game's missions, its own and those added to its missions folder, and check that each loads" },
        }) ++ help.paragraph("Each command's --help shows its options.", 2);
};

/// What the command line asks for.
const Command = union(enum) {
    play: Options,
    help,
    version,
    wrong: Problem,
};

/// What is wrong with the command line.
const Problem = union(enum) {
    /// An option there is no such thing as.
    unknown: []const u8,
    /// An option with no value after it.
    missing: Arg,
    /// An option with a value it doesn't take.
    bad: struct { arg: Arg, value: []const u8 },

    pub fn format(problem: Problem, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (problem) {
            .unknown => |arg| try writer.print("unknown option '{s}'", .{arg}),
            .missing => |arg| try writer.print("{s} takes a value, {s}", .{ @tagName(arg), arg.value().? }),
            .bad => |wrong| try writer.print("{s} takes {s}, not '{s}'", .{ @tagName(wrong.arg), wrong.arg.value().?, wrong.value }),
        }
    }
};

const Options = struct {
    directory: []const u8 = ".",
    /// The mission to play at once, by its number, or null to open the front end.
    mission: ?u16 = null,
    /// The ship the player flies, in place of the loadout screen's choice; null for the mission's
    /// own.
    ship: ?u8 = null,
    /// The options' cockpit setting, for the run; the ini's `[Device] View` without it.
    cockpit: ?camera.CockpitSetting = null,
    /// The game's difficulty, for the run; null for medium with `--mission`, and for the game's
    /// own, easy until SET GAME DIFFICULTY sets it, in the front end.
    difficulty: ?game.collision.Difficulty = null,
    screenshot: ?[]const u8 = null,
    /// The game ticks a screenshot runs before it is taken, one a frame.
    screenshot_ticks: u32 = minimum_screenshot_ticks,
    /// Whether a mission `--mission` names ends in the pause menu (`endsInPauseMenu`).
    pause_menu: bool = true,
    /// Whether the game plays the movies of its start as it starts (`xtrabits.movie.intro`).
    intro: bool = true,
    fullscreen: bool = false,
    software: bool = false,
    settings: platform.gpu.Settings = .{},
    /// Frames a second at most, 0 for no limit; null for the display's rate without vsync.
    fps: ?f32 = null,
    /// Draw what moves between the game's ticks as well as between its steps
    /// (`Clock.stepFraction`).
    smooth_motion: bool = true,
    /// When a ship riding a node, as a launching ship rides the hangar's retainer, is placed on it.
    riders: game.objects.Riders = .together,
    /// Which shots cast a light: every one, or the latest two of each side as the original does.
    shot_lights: game.guns.ShotLights = .every_shot,
    /// Whether a muzzle's flash lights what stands round it, and whether the turrets' guns flash.
    flashes: game.guns.flash.Settings = .{},
    /// Whether the effects the game never reads play on the controller, and whether hits shake the
    /// camera whatever the controller.
    forces: engine.input.force.Settings = .{},
    /// Which lights reach an explosion's debris: a ship's, or every one as the original lets them.
    debris_lights: game.explode.DebrisLights = .like_ships,
    /// How many burning bits the explosions keep flying, and for how long.
    bit_pool: game.explode.BitPool = .lasting,
    /// How full the explosions look: their fireballs, their shockwaves' rings, and the particles
    /// sent far from the camera.
    fireballs: game.explode.Fireballs = .fuller,
    /// How the Uber Explode is shown.
    uber: game.explode.uber.Style = .fuller,
    rings: game.shockwave.Roundness = .round,
    distant: game.particles.Pool.Distant = .whole,
    /// How alike a damaged ship's smoke's particles are.
    smoke: game.particles.Pool.Variety = .varied,
    /// How the shields' bubbles are drawn.
    shields: game.shield.Style = .smooth,
    /// How far the launch's hangar's beacons reach.
    hangar_beacons: game.objects.HangarBeacons = .to_the_ship,
    /// How the Reliant's landing brings the ship down.
    touchdown: game.ailand.Touchdown = .level,
    /// How the radio's lines sound.
    speech: game.cbox.Style = .{},
    /// How the tractors' and the Rippers' beams are drawn.
    beam_glow: game.tractor.Glow = .halo,
    /// Whether a jump's flare lights what stands round it.
    jump_light: game.jump.effect.Lighting = .flare,
    /// How the sun and the lens flares are drawn.
    sun: game.backdrop.Sun = .smooth,
    /// How the planets' atmospheres are drawn.
    atmospheres: game.create.atmosphere.Style = .haze,
    /// Which of its pictures the loading screen shows before a mission.
    loading_splash: game.xtrabits.loading.Splash = .largest,
    movie_size: game.xtrabits.movie.Size = .fitted,
    movie_look: engine.bink.Look = .{},
    /// Which of the Ice Field's rocks are drawn.
    ice_field: game.environfx.IceField.Reach = .whole_view,
    /// How finely the gates' tunnels are built, and how often the ride through the worm rumbles.
    gates: game.wgate.Settings = .{},
    /// How far the finer levels of detail reach.
    detail_reach: game.main.DetailReach = .far,
    /// How much a frame may draw.
    draw_budget: game.main.DrawBudget = .roomy,
    /// Where the line starts that places the marker for a target out of sight.
    edge_line: game.hud.EdgeLine = .from_tip,
    /// How the sound plays, or null for none.
    sound: ?platform.audio.Options = .{},
    /// Where a missile's sound is heard from.
    missile_sound: game.sound3d.MissileSound = .follows,
    /// A piece of music to play from the start, from `music\`, before the mission's script plays
    /// its own; none by default.
    music: ?[]const u8 = null,

    /// OpenAL Soft's settings, which a setting for it after `--original` plays with again.
    fn openAl(options: *Options) ?*platform.audio.openal.Settings {
        const sound = &(options.sound orelse return null);
        if (sound.player == .software) sound.player = .{ .openal = .{} };
        return &sound.player.openal;
    }

    /// What `args` ask for: to play with these options, the help page, the version, or what is
    /// wrong with them.
    fn parse(args: []const [:0]const u8) Command {
        var options: Options = .{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const text = args[i];
            if (std.mem.eql(u8, text, "-h")) return .help;
            const arg = std.meta.stringToEnum(Arg, text) orelse {
                if (std.mem.startsWith(u8, text, "-")) return .{ .wrong = .{ .unknown = text } };
                options.directory = text;
                continue;
            };
            const value: [:0]const u8 = if (arg.value() == null) "" else value: {
                i += 1;
                if (i == args.len) return .{ .wrong = .{ .missing = arg } };
                break :value args[i];
            };
            options.apply(arg, value) catch return .{ .wrong = .{ .bad = .{ .arg = arg, .value = value } } };
            switch (arg) {
                .@"--help" => return .help,
                .@"--version" => return .version,
                else => {},
            }
        }
        return .{ .play = options };
    }

    /// Takes in `arg`, with its value where it has one.
    fn apply(options: *Options, arg: Arg, value: []const u8) error{BadValue}!void {
        switch (arg) {
            .@"--original" => {
                options.settings = .original;
                options.smooth_motion = false;
                options.riders = .in_turn;
                options.shot_lights = .latest_two;
                options.flashes = .original;
                options.forces = .original;
                options.debris_lights = .every_light;
                options.bit_pool = .original;
                options.fireballs = .original;
                options.uber = .original;
                options.rings = .octagon;
                options.distant = .thinned;
                options.smoke = .alike;
                options.shields = .original;
                options.hangar_beacons = .own;
                options.touchdown = .original;
                options.speech = .original;
                options.beam_glow = .none;
                options.jump_light = .none;
                options.sun = .original;
                options.atmospheres = .original;
                options.loading_splash = .by_width;
                options.movie_size = .screen;
                options.movie_look = .original;
                options.ice_field = .original;
                options.gates = .original;
                options.detail_reach = .original;
                options.draw_budget = .original;
                options.edge_line = .original;
                if (options.sound) |*sound| sound.* = .{ .player = .software, .master = null };
                options.missile_sound = .stays;
            },
            .@"--mission" => options.mission = std.fmt.parseInt(u16, value, 10) catch return error.BadValue,
            .@"--ship" => {
                const ship = std.fmt.parseInt(u8, value, 0) catch return error.BadValue;
                if (game.create.models.ship_types[ship].model == null) return error.BadValue;
                options.ship = ship;
            },
            .@"--view" => {
                const number = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
                options.cockpit = switch (@as(camera.CockpitSetting, @enumFromInt(number))) {
                    .cockpit, .chase, .none => |setting| setting,
                    _ => return error.BadValue,
                };
            },
            .@"--difficulty" => options.difficulty = std.meta.stringToEnum(game.collision.Difficulty, value) orelse return error.BadValue,
            .@"--music" => options.music = if (std.mem.eql(u8, value, "none")) null else value,
            .@"--no-pause-menu" => options.pause_menu = false,
            .@"--no-intro" => options.intro = false,
            .@"--fullscreen" => options.fullscreen = true,
            .@"--size" => options.settings.size = parseSize(value) orelse return error.BadValue,
            .@"--fps" => {
                const fps = std.fmt.parseFloat(f32, value) catch return error.BadValue;
                if (!(fps >= 0 and fps <= 10_000)) return error.BadValue;
                options.fps = fps;
            },
            .@"--no-vsync" => options.settings.vsync = false,
            .@"--software" => options.software = true,
            .@"--16-bit" => options.settings.sixteen_bit = true,
            .@"--msaa" => {
                const samples = std.fmt.parseInt(u8, value, 10) catch return error.BadValue;
                if (std.mem.indexOfScalar(u8, &.{ 1, 2, 4, 8 }, samples) == null) return error.BadValue;
                options.settings.samples = samples;
            },
            .@"--filter" => options.settings.filter = std.meta.stringToEnum(platform.gpu.Settings.Filter, value) orelse return error.BadValue,
            .@"--no-bloom" => options.settings.bloom = false,
            .@"--no-dither" => options.settings.dither = false,
            .@"--no-pixel-lighting" => options.settings.pixel_lighting = false,
            .@"--gamma-space" => options.settings.linear_light = false,
            .@"--shadows" => options.settings.shadows = std.meta.stringToEnum(platform.gpu.Settings.Shadows, value) orelse return error.BadValue,
            .@"--no-cockpit-shadows" => options.settings.cockpit_shadows = false,
            .@"--no-smooth-motion" => options.smooth_motion = false,
            .@"--few-shot-lights" => options.shot_lights = .latest_two,
            .@"--hrtf" => if (options.openAl()) |settings| {
                settings.hrtf = .on;
            },
            .@"--no-hrtf" => if (options.openAl()) |settings| {
                settings.hrtf = .off;
            },
            .@"--no-reverb" => if (options.openAl()) |settings| {
                settings.reverb = false;
            },
            .@"--no-compressor" => if (options.sound) |*sound| {
                // The limiter stays.
                const master = if (sound.master) |*master| master else master: {
                    sound.master = .{};
                    break :master &sound.master.?;
                };
                master.ratio = 1;
                master.makeup = 0;
            },
            .@"--no-sound" => options.sound = null,
            .@"--screenshot" => options.screenshot = value,
            .@"--screenshot-ticks" => options.screenshot_ticks = @max(std.fmt.parseInt(u32, value, 10) catch return error.BadValue, minimum_screenshot_ticks),
            .@"--help", .@"--version" => {},
        }
    }

    /// A size given as `<width>x<height>`, each from 1 to `max_size`.
    fn parseSize(text: []const u8) ?[2]u32 {
        var halves = std.mem.splitScalar(u8, text, 'x');
        var size: [2]u32 = undefined;
        for (&size) |*side| {
            const digits = halves.next() orelse return null;
            side.* = std.fmt.parseInt(u32, digits, 10) catch return null;
            if (side.* == 0 or side.* > max_size) return null;
        }
        return if (halves.next() == null) size else null;
    }

    /// The largest side `--size` takes, which GPUs draw to.
    const max_size = 16384;

    /// The frames a second to hold to, where the display does not already.
    fn frameRate(options: Options, window: platform.window.Window) ?f32 {
        if (options.fps) |fps| return if (fps > 0) fps else null;
        if (options.software or options.settings.vsync) return null;
        return window.refreshRate();
    }
};

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
    const options = switch (Options.parse(args[1..])) {
        .play => |options| options,
        .help => return say(init.io, help_page),
        .version => return say(init.io, "openreliant " ++ version.string ++ "\n"),
        .wrong => |problem| {
            std.debug.print("openreliant: {f}\nRun 'openreliant --help' to see the options.\n", .{problem});
            return 2;
        },
    };
    run(init.io, init.gpa, arena, options) catch |err| switch (err) {
        error.MissingGameFiles, error.MissingMission => return 1,
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

/// Says that `directory` holds no installed copy of the game, and what the engine needs.
fn missingGameFiles(directory: []const u8, file: ?[]const u8) error{MissingGameFiles} {
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
    return error.MissingGameFiles;
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

/// One of the game's files in its folder `directory`, whole, into `arena`.
fn readGameFile(io: Io, arena: Allocator, directory: Io.Dir, name: []const u8) ![]u8 {
    return directory.readFileAlloc(io, name, arena, .limited(engine.files.max_file_size));
}

/// The records of the stats table `table`, from its file in the game's folder `directory`, as its
/// loader reads them (`stats_load_ships` and the others).
fn readStats(io: Io, arena: Allocator, directory: Io.Dir, comptime table: stats.Table) ![]align(1) const stats.Table.Record(table) {
    const file = try stats.File.parse(table, try readGameFile(io, arena, directory, table.fileName()));
    return @field(file, @tagName(table));
}

fn run(io: Io, gpa: Allocator, arena: Allocator, options: Options) !void {
    const directory = Io.Dir.cwd().openDir(io, options.directory, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return missingGameFiles(options.directory, null),
        else => return err,
    };
    defer directory.close(io);
    if (install.missingGameFile(io, directory)) |name| return missingGameFiles(options.directory, name);

    // What `WinMain` opens at start-up, and the texture cache `renderer_start` opens.
    var resources: game.bigfile.Hog = try .open(arena, io, directory, game.bigfile.resource_name);
    defer resources.close(arena);
    const cache_bytes = try readGameFile(io, arena, directory, tcache.hardware_name);
    const cache: tcache.Cache = try .parse(arena, cache_bytes);
    const palette = try tga.palette(try resources.readFile(arena, "palette.tga"));
    var textures: srtexture.Table = .init(arena, cache, palette);
    // The flight and combat stats `stats_load_ships` reads; every gun type's figures, which
    // `stats_load_guns` reads; every missile type's, which `stats_load_missiles` reads; and the
    // pilots'.
    const ship_stats = try readStats(io, arena, directory, .ships);
    const gun_stats = try readStats(io, arena, directory, .guns);
    const missile_stats = try readStats(io, arena, directory, .missiles);
    const pilot_stats = try readStats(io, arena, directory, .pilots);
    // The strings `language_init` reads out of `language.dll` at start-up.
    const strings: game.language.Language = try .load(arena, try .parse(try readGameFile(io, arena, directory, game.language.file_name)));

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

    var context: srapi.Context = .{
        .projection = (camera.Camera{}).projection(initial_size[0], initial_size[1]),
        .detail = game.main.high_detail,
        .finer = options.detail_reach.finer(),
        .budget = options.draw_budget.limit(),
    };
    var devices: engine.input.Devices = .{};
    // The characters typed into the window, which its procedure queues (`WM_CHAR`).
    var typed: game.winmain.Typed = .{};
    // The game's settings file, which `load_key_config` reads the input settings from and the
    // pause menu's screens write to. If it's missing, every setting keeps its default.
    var settings_file: engine.profile.File = .{ .arena = arena, .profile = .read(io, arena, directory) };
    // Sound: Miles's calls, played by OpenAL Soft or OpenReliant's own mixer through SDL3's audio,
    // with the voices `WinMain` asks `sound_init` for, the volumes of `[Sound]`, and the 3D
    // provider it opens; silent where there is no device, or with `--no-sound`.
    const output: ?*platform.audio.Output = if (options.sound) |chosen| platform.audio.Output.create(gpa, chosen) catch |err| none: {
        std.log.warn("playing without sound: {s}", .{@errorName(err)});
        break :none null;
    } else null;
    defer if (output) |open| open.destroy();
    const sound = try arena.create(game.hog_snd.Sound);
    sound.init(if (output) |open| open.driver() else null, sound_voices, .{ .gpa = gpa, .io = io, .dir = directory });
    defer sound.shutdown();
    sound.volumes = .read(settings_file.profile);
    // What `WinMain` reads from `[Device]`: the options' cockpit setting, the brightness, and
    // whether the transitions play.
    const device_settings: game.winmain.Device = .read(settings_file.profile);
    // What draws the frames outside the game's loop: the movies', and the loading screens'.
    var presenter: Presenter = .{ .window = &window, .screen = screen, .driver = &driver, .context = &context, .wanted = options.settings.size, .arena = arena };
    defer presenter.close(gpa);
    // The screenshots the 0 key saves in flight and O in the briefing, in the game's folder.
    var screenshots: game.xtrabits.screenshot.Screenshots = .{ .io = io, .directory = directory };
    defer screenshots.finish();
    // The movies: FFmpeg's decoders behind the stand-in for Bink, and what plays them in a loop of
    // their own. As the renderer first starts, before its loading screens, `renderer_load` plays the
    // intro; a mission `--mission` names, or a screenshot, starts without it.
    var decoders: platform.video.Decoders = .init();
    // The discs' archives, which a full install keeps in the game's folder (`cd_hog_open`), and
    // the hangar's movie played last (`hangar_movie_last`, `0x005D6C8C`).
    var disc: game.interface.disc.Disc = .{ .gpa = gpa, .io = io, .directory = directory };
    defer disc.close();
    var hangar: game.xtrabits.movie.Hangar = .{};
    var movies: Movies = .{
        .gpa = gpa,
        .codec = decoders.codec(),
        .sound = if (output) |open| open.driver() else null,
        .presenter = &presenter,
        .devices = &devices,
        .pacer = &pacer,
        .frame_rate = options.frameRate(window),
        .size = options.movie_size,
        .look = options.movie_look,
        .transitions = device_settings.transitions,
        .hardware = !options.software,
        .disc = &disc,
    };
    if (options.intro and options.mission == null and options.screenshot == null) {
        for (game.xtrabits.movie.intro) |name| _ = try movies.play(name, .cleared) orelse return;
    }
    // The loading screen the renderer's start shows as the game loads, and each mission's start
    // after it: the picture alone, then with LOADING before each part of the game it loads.
    var loading: Loading = .{
        .resources = try .open(gpa, resources),
        .archive = &resources,
        .presenter = &presenter,
        .strings = &strings,
        .splash = options.loading_splash,
    };
    defer loading.close();
    try loading.show(game.xtrabits.loading.startup_first);
    try loading.show(game.xtrabits.loading.startup_step);
    var rand: engine.libcmt.Rand = .{};
    const space = try game.backdrop.Backdrop.create(arena, &textures, try tga.decode(arena, try resources.readFile(arena, game.backdrop.star_map_name)), &rand, context.projection.near, options.sun);
    const sky = try game.nebula.Sky.create(arena, &textures, try tga.decode(arena, try resources.readFile(arena, game.nebula.dome_image_name)));
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
    var radio: game.videoreports.Radio = .open(gpa, io, directory);
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
    var brightness = device_settings.brightness;
    var view: camera.Camera = .{ .setting = cockpit_setting, .cockpit_mode = cockpit_setting.mode(), .missiles = &objects.missiles };
    var last_view = view.view;
    // The mission's clocks, which `mission_run` zeroes before it loops.
    var clock: game.main.Clock = .{};
    clock.start(platform.window.ticks());
    const hearing: game.hog_snd.Hearing = .{ .sound = sound, .camera = &view.place, .clock = &clock };
    try loading.show(game.xtrabits.loading.startup_step);
    // What the explosions leave for the frames after them, and the particles they send out.
    var explosions: game.explode.Explosions = try .init(gpa, try .load(&textures));
    defer explosions.deinit();
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
    var effects_models: game.create.library.MountCache = .{ .gpa = arena, .resources = &resources, .textures = &textures };
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
    const found_forces = engine.input.force.load(io, arena, directory);
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
        .target = undefined,
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
            .file = &settings_file,
            .sound = sound,
            .stdsmp = stdsmp,
            .camera = &view,
            .brightness = &brightness,
        },
    };
    world.display = &display.state;

    // The mission `--mission` names, read once from the game's files, or for mission 0, where the
    // game has none, from the copy `openreliant` carries, and started; it starts again as each
    // attempt ends. Without it, the front end picks the mission.
    var play: Play = .{
        .gpa = gpa,
        .number = options.mission orelse mission0.number,
        .file = if (options.mission) |number| try missionFile(io, arena, directory, &resources, number) else "",
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
    // with; whether it is shown, and whether the mission being flown was started from it.
    var front: engine.genilib.interf.Interface = .{ .pilot = .{ .difficulty = options.difficulty orelse .easy } };
    var front_resources: ?engine.genilib.interf.Resources = null;
    defer if (front_resources) |*open| open.close();
    // The campaign's saved loadout, which `campaign_new` starts in the Predator. OpenReliant keeps
    // it for the session, the campaign's saving not being ported.
    var saved_loadout: engine.interface.loadout.Saved = .{};
    var in_front_end = options.mission == null;
    // The pilot as the game starts: the call sign the profile gives, as `campaign_new` reads it,
    // and the list of call signs, which `WinMain` reads and writes straight back (`0x004A919B`).
    if (in_front_end) {
        if (readGameFile(io, arena, directory, game.gameflow.profile_name)) |bytes| {
            front.pilot.call_sign.set(game.gameflow.profileCallSign(bytes));
        } else |_| {}
        const player_name = strings.string(@intFromEnum(game.interface.pilot_roster.String.player)) orelse "";
        front.pilot_roster.list = game.winmain.loadCallSigns(settings_file.profile, player_name);
        try game.winmain.saveCallSigns(&front.pilot_roster.list, &settings_file);
    }
    var from_front_end = false;
    var front_ticks = platform.window.ticks();
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
        .camera = &view,
        .player = &objects.player,
    };
    // Whether the system's pointer shows over the window, and whether the window holds the mouse.
    var mouse_held = false;
    // As `WinMain` opens the front end, the splash leads into the main menu (`0x004AB6A0`).
    if (in_front_end and options.screenshot == null) {
        _ = try movies.play(game.xtrabits.movie.splash_to_menu, .over_screen) orelse return;
    }
    while (true) {
        if (movies.controllers_changed) {
            movies.controllers_changed = false;
            if (options.screenshot == null) connectController(arena, &devices, &controller, settings_file.profile);
        }
        while (window.poll()) |event| switch (event) {
            .quit => return,
            .key => |key| if (options.screenshot == null) {
                devices.keyboard.down[@intFromEnum(key.scan)] = key.down;
            },
            .typed => |character| if (options.screenshot == null) typed.push(game.language.fromUnicode(character)),
            .controllers => if (options.screenshot == null) connectController(arena, &devices, &controller, settings_file.profile),
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
        };
        // While the window is inactive, the sound is paused, as the message pump pauses it, and
        // the game too.
        try game.winmain.followActivation(&app, pausing);
        if (output) |open| open.update();
        const size = try frameSize(screen, &window, options.settings.size, arena);

        world.view = view.view;
        world.cockpit = if (cockpit.shown) |*shown| &shown.model else null;
        world.mission = if (play.loaded) |loaded| &loaded.bound else null;
        world.events = if (play.loaded) |loaded| &loaded.events else null;
        world.variables = if (play.loaded) |loaded| &loaded.script.variables else null;
        // The front end's frame while it is shown, as `interface_run` runs its screens, which the
        // keyboard is read for each pass; the mission it picks starts at once, with its clocks
        // zeroed as `mission_run` zeroes them.
        if (in_front_end) {
            if (front_resources == null) front_resources = try .open(gpa, resources);
            const ticks = platform.window.ticks();
            const elapsed = std.math.cast(i32, ticks -| front_ticks) orelse std.math.maxInt(i32);
            front_ticks = ticks;
            devices.keyboard.read();
            sound.updateMusic();
            if (front.frame(.{
                .devices = &devices,
                .typed = &typed,
                .window = size,
                .elapsed = elapsed,
                .sound = sound,
                .bank = stdsmp,
                .resources = &front_resources.?,
                .settings = &settings_file,
            })) |outcome| {
                // The Reliant's rooms and the briefing, which run in loops of their own.
                var rooms: Rooms = .{
                    .movies = &movies,
                    .sound = sound,
                    .clock = &clock,
                    .resources = &resources,
                    .front = &front_resources.?,
                    .strings = &strings,
                    .speech = options.speech,
                    .lines = if (radio.archive) |*archive| archive else null,
                    .screenshots = &screenshots,
                    .cache = cache,
                    .saved = &saved_loadout,
                    .stats = tables,
                    .missile_stats = &objects.missile_stats,
                    .tier = objects.campaign_tier,
                    .rank = player.rank,
                };
                const flight: game.interface.main_menu.Flight = switch (outcome) {
                    .quit => return,
                    .fly => |flight| flight,
                    // START GAME: `WinMain` takes the campaign into the Reliant's rooms, whose
                    // briefing room's door leads to the briefing, and the mission.
                    .campaign => |mission| switch (try rooms.campaign(mission) orelse return) {
                        .fly => |chosen| fly: {
                            // The loadout's ship and its racks, but where `--ship` names a ship,
                            // which is then fitted by its tier; and the tier the loadout raised
                            // the campaign's to.
                            const result = chosen orelse break :fly .{ .mission = mission };
                            objects.campaign_tier = result.tier;
                            if (options.ship) |ship| break :fly .{ .mission = mission, .ship = ship };
                            break :fly .{ .mission = mission, .ship = result.ship, .racks = result.racks };
                        },
                        .main_menu => {
                            front.back();
                            continue;
                        },
                    },
                    // The developers' briefing from its loadout on, after which the front end
                    // starts again at its main menu.
                    .briefing => |mission| {
                        if (!try rooms.loadoutBriefing(mission)) return;
                        front.back();
                        continue;
                    },
                };
                play.number = flight.mission;
                play.file = missionFile(io, arena, directory, &resources, flight.mission) catch |err| switch (err) {
                    error.MissingMission => continue,
                    else => |other| return other,
                };
                // The flight's ship, else the one `--ship` names, else the mission's ship; and
                // the simulator it runs in.
                objects.loadout_ships[objects.player] = if (flight.ship orelse options.ship) |ship| @enumFromInt(ship) else null;
                objects.loadout_racks[objects.player] = flight.racks;
                objects.simulator = flight.simulator;
                // The pilot the front end has set flies it: the radio says the pilot's own
                // lines in the pilot's voice, and hits land by the game's difficulty.
                player.female = front.pilot.female;
                world.difficulty = front.pilot.difficulty;
                // `WinMain` fades the music out over a second, then plays the hangar's movie
                // before the mission's loading, and the landing after it.
                play.winmain_flight = flight.byWinMain();
                if (play.winmain_flight) {
                    waitBeforeLaunch(&clock, sound);
                    if (!try movies.launch(&hangar, flight.mission)) return;
                }
                sound.closeMusic();
                clock.start(platform.window.ticks());
                try play.start(.{ .world = world, .clock = &clock, .devices = &devices });
                in_front_end = false;
                from_front_end = true;
            }
        }
        // The movie a screen of the front end plays as it leads to another.
        if (front.movie) |name| {
            front.movie = null;
            _ = try movies.play(name, .over_screen) orelse return;
        }
        // The window takes text while the front end has a line to type into.
        window.takeText(in_front_end and front.takesText());
        const orders: game.aigeneric.Context = .{ .world = world, .clock = &clock, .devices = &devices };
        const slot = &objects.slots[objects.player];
        if (!in_front_end) {
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
            // `mission_frame` looks for Escape before its work, and pausing into the menu leaves the
            // work out.
            if (!clock.paused and devices.keyboard.pressed(engine.input.scan.escape, .none, true)) try game.main.pause(pausing, true);
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
                const over = game.main.missionFrame(orders, .of(&clock, options.smooth_motion, options.riders), play.loaded);
                // The mission over, once the camera has watched the player's end or the pilot's pickup,
                // once the player's ship has landed, or once its script ends it, the game settles how
                // it ended and goes to its debriefing. Until that is ported, a mission the front end
                // started goes back to it.
                // One `--mission` named pauses into the menu over the last frame, where RESTART, and
                // CONTINUE with nothing left to continue, fly it again; a screenshot, or a game told
                // not to (`--no-pause-menu`), starts it again straight away.
                if (over) {
                    game.main.missionRunEnd(world.player, objects.mission_number);
                    if (from_front_end) {
                        // `WinMain` records the mission as it ends (`0x004A9FBA`), which promotes
                        // the pilot (`mission_end_record`).
                        game.gameflow.endMission(world.player, missionRating(&world));
                        if (!try backToFrontEnd(&play, &front, sound, objects, player.ending, &movies, &resources)) return;
                        in_front_end = true;
                        from_front_end = false;
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
                    .smooth_motion = options.smooth_motion,
                });
            }
        }

        _ = frame_arena.reset(.retain_capacity);
        if (in_front_end) {
            var shown: FrontEndDisplay = .{ .front = &front, .resources = &front_resources.?, .target = screen.interface(), .window = size, .strings = &strings };
            scene.clear();
            try srcore.render(frame_arena.allocator(), &context, &scene, driver.interface(), shown.overlay());
        } else {
            context.camera = .{ .position = view.place.position, .orientation = view.place.orientation };
            context.projection = view.projection(size[0], size[1]);
            // The cockpit's model hangs from the camera, and the radar's backing stands on the radar.
            if (cockpit.shown) |*shown| if (view.cockpit_place) |placed| game.main.cockpit.place(&shown.model, view.place, placed);
            backing.place(context.projection, view.place, game.hud.scaleFor(size));
            display.target = screen.interface();
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
                .ahead = game.objects.pastTick(&clock, options.smooth_motion),
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
                    .restart => try play.again(orders),
                    .leave_mission => {
                        if (!from_front_end) return;
                        player.ending = .left;
                        if (!try backToFrontEnd(&play, &front, sound, objects, player.ending, &movies, &resources)) return;
                        in_front_end = true;
                        from_front_end = false;
                    },
                }
            }
        }
        // The menus draw their own pointer over the window, in place of the system's, which also
        // hides in full screen and once it rests over the window.
        const menu_pointer = in_front_end or pause_menu.isOpen();
        window.showPointer(menu_pointer);
        // Steering by the mouse, the window holds it in flight, as the game holds DirectInput's
        // mouse while it is in the foreground.
        const hold = devices.settings.control_mode == .mouse and !menu_pointer and app.active and options.screenshot == null;
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
                return save(io, frame_arena.allocator(), options.screenshot.?, frame.rgba, frame.size);
            }
        }
        if (options.frameRate(window)) |rate| pacer.wait(rate);
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
const minimum_screenshot_ticks = 2;

fn save(io: Io, gpa: Allocator, path: []const u8, rgba: []const u8, size: [2]u32) !void {
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
    try std.testing.expect(endsInPauseMenu(try parsed(&.{ "--mission", "1" }), null));
    try std.testing.expect(!endsInPauseMenu(try parsed(&.{}), null));
    try std.testing.expect(!endsInPauseMenu(try parsed(&.{ "--mission", "1", "--no-pause-menu" }), null));
    try std.testing.expect(!endsInPauseMenu(try parsed(&.{ "--mission", "1" }), 2));
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

/// How the mission's script rates the mission (`mission_success`), a failure where no script runs.
fn missionRating(world: *const game.gameobj.World) engine.vm.Variables.Outcome {
    const variables = world.variables orelse return .failure;
    return variables.mission_success;
}

/// Goes back to the front end as a mission it started ends as `ending`, or is left: the mission
/// let go, out of the simulator, its sounds and music ended, what `play_landing_movie` plays where
/// `WinMain` plays it (`Play.landing`), and the front end's main menu entered again
/// (`Interface.back`). False where the window was closed meanwhile.
fn backToFrontEnd(play: *Play, front: *engine.genilib.interf.Interface, sound: *game.hog_snd.Sound, all: *game.create.Objects, ending: game.main.Ending, movies: *Movies, resources: *const game.bigfile.Hog) !bool {
    const landing = play.landing(ending, all.mission25_second_part);
    play.end();
    all.simulator = .{};
    sound.endAll();
    sound.closeMusic();
    if (landing) |what| if (!try movies.land(what, resources, sound)) return false;
    front.back();
    return true;
}

/// What draws the front end over the cleared frame: its render hook (`sr + 0x88`), which
/// `srcore.render` reaches through the overlay it is handed.
const FrontEndDisplay = struct {
    front: *const engine.genilib.interf.Interface,
    resources: *engine.genilib.interf.Resources,
    target: srd3d.device.Device,
    window: [2]u32,
    strings: *const game.language.Language,

    fn overlay(shown: *FrontEndDisplay) srcore.Overlay {
        return .{ .context = shown, .draw = draw };
    }

    fn draw(context: *anyopaque) Allocator.Error!void {
        const shown: *FrontEndDisplay = @ptrCast(@alignCast(context));
        return drawn(shown.front.draw(shown.resources, shown.target, shown.window, shown.strings, version.string));
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
                .fonts = .{ .large = &resources.font, .small = &resources.small },
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
        }, try play.gpa.dupe(u8, play.file), play.number);
        // A launch holds the camera until the ship is out; a ship that does not launch starts in
        // its view at once.
        const all = orders.world.objects;
        if (!play.view.locked) _ = play.view.setView(startingView(&all.slots[all.player], play.view.cockpit_mode), all.player, false, true, play.clock.viewTime());
    }

    /// Starts the mission again as an attempt ends, the kills kept where the ending keeps them, as
    /// when the ejected pilot is picked up by a nanny ship (`gameflow.endMission`).
    fn again(play: *Play, orders: game.aigeneric.Context) !void {
        game.gameflow.endMission(orders.world.player, missionRating(&orders.world));
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

/// The file of mission `number`, as the game reads it (`game.mission.bind.read`): from the game's
/// `missions` folder, or from `resource.hog`. Mission 0, OpenReliant's own, comes from the copy
/// `openreliant` carries where the game has none.
fn missionFile(io: Io, arena: Allocator, directory: Io.Dir, resources: *const game.bigfile.Hog, number: u16) ![]const u8 {
    var path_buffer: [game.winmain.mission_path_size]u8 = undefined;
    const path = game.winmain.missionPath(&path_buffer, number, false, false);
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
    /// Filled in each frame, before the scene is drawn.
    target: srd3d.device.Device,
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
            .target = display.target,
            .screen = display.screen,
            .art = &display.resources.art,
            .font = &display.resources.font,
            .strings = display.strings,
            .devices = display.devices,
            .settings = display.settings,
            .version = version.string,
        });
        try game.hud.draw(&display.state, &display.resources, .{
            .gpa = display.gpa,
            .target = display.target,
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
    _ = install;
    _ = joysticks;
    _ = mission0;
    _ = missions;
    _ = test_keys;
    _ = version;
}

/// The options `args` play with, for the tests.
fn parsed(args: []const [:0]const u8) error{Usage}!Options {
    return switch (Options.parse(args)) {
        .play => |options| options,
        .help, .version, .wrong => error.Usage,
    };
}

test Options {
    try std.testing.expectEqualStrings(".", (try parsed(&.{})).directory);
    const given = try parsed(&.{ "game/install", "--ship", "3" });
    try std.testing.expectEqualStrings("game/install", given.directory);
    try std.testing.expectEqual(3, given.ship);
    try std.testing.expectEqual(null, given.cockpit);
    try std.testing.expectEqual(camera.CockpitSetting.chase, (try parsed(&.{ "--view", "1" })).cockpit.?);
    try std.testing.expectError(error.Usage, parsed(&.{ "--view", "3" }));
    try std.testing.expectError(error.Usage, parsed(&.{"--ship"}));
    // The mission by its number, mission 0 by default.
    try std.testing.expectEqual(null, (try parsed(&.{})).mission);
    try std.testing.expectEqual(25, (try parsed(&.{ "--mission", "25" })).mission);
    try std.testing.expectEqual(null, (try parsed(&.{})).ship);
    try std.testing.expectError(error.Usage, parsed(&.{ "--mission", "x" }));
    try std.testing.expectError(error.Usage, parsed(&.{ "--ship", "0x0E" }));
    try std.testing.expectError(error.Usage, parsed(&.{"--bogus"}));
    try std.testing.expectEqualStrings("shot.png", (try parsed(&.{ "--screenshot", "shot.png" })).screenshot.?);
    try std.testing.expect((try parsed(&.{})).intro);
    try std.testing.expect(!(try parsed(&.{"--no-intro"})).intro);
    // As the game has it unless told otherwise.
    try std.testing.expectEqual(null, (try parsed(&.{})).difficulty);
    try std.testing.expectEqual(.hard, (try parsed(&.{ "--difficulty", "hard" })).difficulty.?);
    try std.testing.expectEqual(.medium, (try parsed(&.{ "--original", "--difficulty", "medium" })).difficulty.?);
    try std.testing.expectError(error.Usage, parsed(&.{ "--difficulty", "ace" }));

    // The improvements on by default; the original's look, and single settings after it.
    const plain = try parsed(&.{});
    try std.testing.expectEqual(platform.gpu.Settings{}, plain.settings);
    try std.testing.expectEqual(null, plain.fps);
    const retro = try parsed(&.{ "--original", "--msaa", "8", "--no-vsync", "--fps", "0" });
    try std.testing.expect(retro.settings.sixteen_bit);
    try std.testing.expectEqual(.off, retro.settings.shadows);
    try std.testing.expectEqual(.low, (try parsed(&.{ "--shadows", "low" })).settings.shadows);
    try std.testing.expect(!(try parsed(&.{"--no-cockpit-shadows"})).settings.cockpit_shadows);
    try std.testing.expect(!(try parsed(&.{"--gamma-space"})).settings.linear_light);
    try std.testing.expect(!retro.settings.linear_light);
    try std.testing.expectEqual(.original, retro.settings.filter);
    try std.testing.expectEqual(8, retro.settings.samples);
    try std.testing.expect(!retro.settings.vsync);
    try std.testing.expectEqual(0, retro.fps.?);
    try std.testing.expect(!retro.smooth_motion);
    try std.testing.expectEqual(.together, plain.riders);
    try std.testing.expectEqual(.in_turn, retro.riders);
    try std.testing.expectEqual(.latest_two, retro.shot_lights);
    try std.testing.expectEqual(game.guns.flash.Settings.original, retro.flashes);
    try std.testing.expectEqual(game.guns.flash.Settings{}, plain.flashes);
    try std.testing.expectEqual(engine.input.force.Settings.original, retro.forces);
    try std.testing.expectEqual(engine.input.force.Settings{}, plain.forces);
    try std.testing.expectEqual(.stays, retro.missile_sound);
    try std.testing.expectEqual(.every_light, retro.debris_lights);
    try std.testing.expectEqual(.like_ships, plain.debris_lights);
    try std.testing.expectEqual(.lasting, plain.bit_pool);
    try std.testing.expectEqual(.original, retro.bit_pool);
    try std.testing.expectEqual(.original, retro.fireballs);
    try std.testing.expectEqual(.original, retro.uber);
    try std.testing.expectEqual(.fuller, plain.uber);
    try std.testing.expectEqual(.octagon, retro.rings);
    try std.testing.expectEqual(.thinned, retro.distant);
    try std.testing.expectEqual(.alike, retro.smoke);
    try std.testing.expectEqual(.varied, plain.smoke);
    try std.testing.expectEqual(.fuller, plain.fireballs);
    try std.testing.expectEqual(.smooth, plain.shields);
    try std.testing.expectEqual(.original, retro.shields);
    try std.testing.expectEqual(.haze, plain.atmospheres);
    try std.testing.expectEqual(.original, retro.atmospheres);
    try std.testing.expectEqual(.largest, plain.loading_splash);
    try std.testing.expectEqual(.by_width, retro.loading_splash);
    try std.testing.expectEqual(.fitted, plain.movie_size);
    try std.testing.expectEqual(.screen, retro.movie_size);
    try std.testing.expect(plain.movie_look.deblock and !retro.movie_look.deblock);
    try std.testing.expectEqual(.whole_view, plain.ice_field);
    try std.testing.expectEqual(.original, retro.ice_field);
    try std.testing.expectEqual(game.wgate.Settings{}, plain.gates);
    try std.testing.expectEqual(game.wgate.Settings.original, retro.gates);
    try std.testing.expectEqual(.level, plain.touchdown);
    try std.testing.expectEqual(.original, retro.touchdown);
    try std.testing.expectEqual(game.cbox.Style.original, retro.speech);
    try std.testing.expectEqual(game.cbox.Style{}, plain.speech);
    try std.testing.expectEqual(.to_the_ship, plain.hangar_beacons);
    try std.testing.expectEqual(.own, retro.hangar_beacons);
    try std.testing.expectEqual(.halo, plain.beam_glow);
    try std.testing.expectEqual(.none, retro.beam_glow);
    try std.testing.expectEqual(.flare, plain.jump_light);
    try std.testing.expectEqual(.none, retro.jump_light);
    try std.testing.expectEqual(.far, plain.detail_reach);
    try std.testing.expectEqual(.original, retro.detail_reach);
    try std.testing.expectEqual(.roomy, plain.draw_budget);
    try std.testing.expectEqual(.original, retro.draw_budget);
    try std.testing.expect(!(try parsed(&.{"--no-smooth-motion"})).smooth_motion);
    try std.testing.expectEqual(.latest_two, (try parsed(&.{"--few-shot-lights"})).shot_lights);
    // Sound is on unless told otherwise, and the mission's script plays its music.
    try std.testing.expect((try parsed(&.{})).sound.?.player == .openal);
    try std.testing.expectEqual(null, (try parsed(&.{"--no-sound"})).sound);
    try std.testing.expectEqual(null, (try parsed(&.{ "--no-sound", "--hrtf" })).sound);
    // The original's sound is the plain mixer with no master bus; OpenAL's settings bring OpenAL
    // back.
    const original_sound = (try parsed(&.{"--original"})).sound.?;
    try std.testing.expect(original_sound.player == .software and original_sound.master == null);
    const headphones = (try parsed(&.{ "--original", "--hrtf", "--no-reverb" })).sound.?;
    try std.testing.expect(headphones.player.openal.hrtf == .on and !headphones.player.openal.reverb);
    try std.testing.expectEqual(.auto, (try parsed(&.{})).sound.?.player.openal.hrtf);
    try std.testing.expectEqual(.off, (try parsed(&.{"--no-hrtf"})).sound.?.player.openal.hrtf);
    const uncompressed = (try parsed(&.{"--no-compressor"})).sound.?.master.?;
    try std.testing.expectEqual(1, uncompressed.ratio);
    try std.testing.expectEqual(null, (try parsed(&.{})).music);
    try std.testing.expectEqualStrings("New_Sim01.wav", (try parsed(&.{ "--music", "New_Sim01.wav" })).music.?);
    try std.testing.expectEqual(null, (try parsed(&.{ "--music", "none" })).music);
    try std.testing.expect((try parsed(&.{})).smooth_motion);
    try std.testing.expectEqual([2]u32{ 3840, 2160 }, (try parsed(&.{ "--size", "3840x2160" })).settings.size.?);
    for ([_][:0]const u8{ "3840", "0x100", "100x", "1x2x3", "99999x100" }) |bad| {
        try std.testing.expectError(error.Usage, parsed(&.{ "--size", bad }));
    }
    const chosen = try parsed(&.{ "--filter", "trilinear", "--16-bit", "--software", "--fullscreen" });
    try std.testing.expectEqual(.trilinear, chosen.settings.filter);
    try std.testing.expect(chosen.settings.sixteen_bit and chosen.software and chosen.fullscreen);
    try std.testing.expectError(error.Usage, parsed(&.{ "--msaa", "3" }));
    try std.testing.expectError(error.Usage, parsed(&.{ "--filter", "sharp" }));
    try std.testing.expectError(error.Usage, parsed(&.{ "--fps", "-1" }));
    try std.testing.expectError(error.Usage, parsed(&.{ "--fps", "nan" }));
}

test "Options asks for help or the version, and says what is wrong" {
    try std.testing.expectEqual(.help, std.meta.activeTag(Options.parse(&.{"--help"})));
    try std.testing.expectEqual(.help, std.meta.activeTag(Options.parse(&.{ "game", "-h" })));
    try std.testing.expectEqual(.version, std.meta.activeTag(Options.parse(&.{ "game", "--version" })));
    var buffer: [128]u8 = undefined;
    const cases = [_]struct { []const [:0]const u8, []const u8 }{
        .{ &.{"--bogus"}, "unknown option '--bogus'" },
        .{ &.{"--msaa"}, "--msaa takes a value, <1|2|4|8>" },
        .{ &.{ "--msaa", "3" }, "--msaa takes <1|2|4|8>, not '3'" },
        .{ &.{ "--no-sound", "--view", "cockpit" }, "--view takes <0|1|2>, not 'cockpit'" },
    };
    for (cases) |case| {
        const problem = Options.parse(case[0]).wrong;
        try std.testing.expectEqualStrings(case[1], try std.fmt.bufPrint(&buffer, "{f}", .{problem}));
    }
}

test help_page {
    // It starts with the version, every option is on it, and it fits in 80 columns.
    try std.testing.expect(std.mem.startsWith(u8, help_page, "OpenReliant " ++ version.string ++ " plays"));
    for (std.enums.values(Arg)) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, help_page, @tagName(arg)) != null);
    }
    var lines = std.mem.splitScalar(u8, help_page, '\n');
    while (lines.next()) |line| try std.testing.expect(line.len <= help.width);
}
