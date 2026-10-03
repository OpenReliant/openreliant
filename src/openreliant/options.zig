//! What `openreliant` takes on its command line: its options, the help page that lists them, and
//! how they are read.

const std = @import("std");

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const game = engine.game;
const camera = game.camera;
const FrameSize = engine.surrender.srd3d.device.FrameSize;
const help = @import("help.zig");
const version = @import("version");

/// Everything `openreliant` takes on its command line, in the order the help page lists them.
pub const Arg = enum {
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
    @"--no-materials",
    @"--shadows",
    @"--no-cockpit-shadows",
    @"--no-smooth-motion",
    @"--few-shot-lights",
    @"--baked-lights",
    @"--bitmap-fonts",
    @"--hrtf",
    @"--no-hrtf",
    @"--no-reverb",
    @"--no-compressor",
    @"--no-sound",
    @"--no-mods",
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
    .@"--original" = .{ .section = .original, .text = "the original's look and sound: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, light worked out on encoded colours, no material maps, no shadows, motion that moves on with the game's ticks, a launching ship a frame behind the retainer that lowers it, lights from the latest shots only, muzzle flashes that light nothing and none from the turrets, a jump's flare that lights nothing, the force feedback's own effects only, a blow shaking the camera only while the controller rumbles, an explosion's debris lit by every light, its fireballs, rings, particles and burning bits as few, plain and brief as the original's, the Uber Explode as coarse, unlit and tied to the frame rate as the original's, a damaged ship's smoke as even as the original's, the shields' bubbles as coarse as the original's, the tractor beams as thin as the original's, the hangar's beacons falling short of the launching ship, a ship landing on the Reliant tilted as it came, its tube's door left open, the planets' atmospheres as coarse and fleeting as the original's and their terminators as hard, the Ice Field's rocks drawn only near the middle of the view, the loading screen's picture picked by the screen's width, the movies drawn at their size in the middle of the screen with Bink's blocks and its colour in steps of two pixels, the gates' tunnels as coarse as the original's, the ride through the worm rumbling the more often the higher the frame rate, the sun and its lens flares from their small textures and the sun's glow going out at once behind what hides it, the levels of detail changing as near as the original's, as little drawn a frame as the original allows, the marker for a target out of sight placed as the original misplaces it, a missile's sound left where it was launched, the radio's lines cut flat at their loudest and heard dry, Enriquez's last word in the briefing as loud as its recording, the interface's text in the game's bitmap fonts, and the sound mixed plainly in stereo" },
    .@"--mission" = .{ .section = .mission, .value = "<number>", .text = "start this mission right away instead of opening the main menu. The number is the one in the mission's file name, mission<number>.dte, loaded from a mod, the game's missions folder or resource.hog. Mission 0 is OpenReliant's sandbox, which is built into openreliant for games without a mission 0" },
    .@"--ship" = .{ .section = .mission, .value = "<type>", .text = "the ship type to fly, by its number in shipstats.bin, in place of the loadout screen's choice, with its default missiles; the mission's own by default" },
    .@"--view" = .{ .section = .mission, .value = "<0|1|2>", .text = "the view it starts in, as the game's settings keep it: 0 the cockpit; 1 the chase view; 2 no cockpit. The settings' own by default, which the settings screen's VIDEO changes" },
    .@"--difficulty" = .{ .section = .mission, .value = "<easy|medium|hard>", .text = "the game's difficulty: how hard hits land on your ship, and shots on the enemy. By default, as in the game, medium with --mission, where a new campaign's starts, and easy in the main menu until SET GAME DIFFICULTY sets it" },
    .@"--music" = .{ .section = .mission, .value = "<file>", .text = "a piece from the game's music folder to play from the start, until the mission's script plays its own; none by default" },
    .@"--no-pause-menu" = .{ .section = .mission, .text = "with --mission, fly the mission again as soon as it ends, where it otherwise ends in the game's pause menu" },
    .@"--fullscreen" = .{ .section = .display, .text = "fill the display; Alt and Enter switch while playing" },
    .@"--size" = .{ .section = .display, .value = "<width>x<height>|<percent>%", .text = "draw frames of this size in pixels whatever the window's, which shows them scaled, as for a screenshot larger than the display; or a share of the window's own, such as 50%, to draw faster; the window's own by default" },
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
    .@"--no-materials" = .{ .section = .graphics, .text = "ignore the material maps of mod textures: no normal maps or reflections, and the original highlights instead of the maps' highlights" },
    .@"--no-cockpit-shadows" = .{ .section = .graphics, .text = "leave the shadows out of the cockpit, keeping them on the ships" },
    .@"--shadows" = .{ .section = .graphics, .value = "<off|low|high>", .text = "shadows from the sun: low is soft and light on older GPUs, high sharp and smooth; high by default, and none without lighting each pixel" },
    .@"--no-smooth-motion" = .{ .section = .graphics, .text = "move what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame" },
    .@"--few-shot-lights" = .{ .section = .graphics, .text = "light only the latest two of the player's shots and the latest two of everyone else's, as the original does" },
    .@"--baked-lights" = .{ .section = .graphics, .text = "bake the steady lights of ships and stations into their hulls, as the original does, rather than shine them as lights on what stands near" },
    .@"--bitmap-fonts" = .{ .section = .graphics, .text = "draw the interface text with the original bitmap fonts, scaled up to the window, instead of outline fonts drawn at the window's resolution (the built-in Newtown, or a font from a mod)" },
    .@"--hrtf" = .{ .section = .sound, .text = "place the sounds for headphones whatever the output; by default they are while the output is headphones" },
    .@"--no-hrtf" = .{ .section = .sound, .text = "place the sounds for speakers whatever the output" },
    .@"--no-reverb" = .{ .section = .sound, .text = "play the sounds around you, the cockpit's voice and the Reliant's rooms without reverb" },
    .@"--no-compressor" = .{ .section = .sound, .text = "leave the mix's loudness as it is, only keeping its peaks in check" },
    .@"--no-sound" = .{ .section = .sound, .text = "play without sound" },
    .@"--no-mods" = .{ .section = .other, .text = "start without the mods in the game's mods folder" },
    .@"--no-intro" = .{ .section = .other, .text = "start without the three movies the game plays as it starts, as --mission and --screenshot do" },
    .@"--screenshot" = .{ .section = .other, .value = "<file.png>", .text = "draw one frame, with the camera settled, to a PNG, and quit; the controls, the [OpenReliant] settings and the details in [Device] are not read, so that it comes out the same each time" },
    .@"--screenshot-ticks" = .{ .section = .other, .value = "<ticks>", .text = "with --screenshot, how many game ticks to run first, one a frame, so that the scene plays out; 2 by default" },
    .@"--version" = .{ .section = .other, .text = "show the version" },
    .@"--help" = .{ .section = .other, .alias = "-h", .text = "show this page" },
});

/// `openreliant --help`.
pub const help_page = page: {
    var out: []const u8 = help.paragraph("OpenReliant " ++ version.string ++ " plays StarLancer from an installed copy of the game.", 0) ++
        \\
        \\usage: openreliant [<game-directory>] [<option>...]
        \\       openreliant install [--from <disc>]... [--force] <directory>
        \\       openreliant joysticks [<game-directory>] [--watch]
        \\       openreliant missions [<game-directory>] [--no-mods]
        \\       openreliant hooks [<hook>] [--definitions]
        \\
        \\
    ++ help.table(&.{.{ .typed = "<game-directory>", .text = "where StarLancer is installed, with resource.hog and tcachehw.dat; the current directory by default" }}) ++
        "\n" ++ help.paragraph("The game keeps its settings in starlancer.ini in its directory, and OpenReliant its own in that file's [OpenReliant] section. The options below change them for the run.", 0);
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
            .{ .typed = "hooks", .text = "list what mods' scripts can hook, or write the definitions file for Luau's language server" },
        }) ++ help.paragraph("Each command's --help shows its options.", 2);
};

/// What the command line asks for.
pub const Command = union(enum) {
    play: Options,
    help,
    version,
    wrong: Problem,
};

/// What is wrong with the command line.
pub const Problem = union(enum) {
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

pub const Options = struct {
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
    /// Whether to load the mods in the game's `mods` folder (`game.bigfile.Mods`).
    mods: bool = true,
    /// Whether the original's look and sound were taken (`--original`), which the options after it
    /// change.
    original: bool = false,
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
    /// Whether the steady lights of ships and stations shine as lights, or are baked into their
    /// hulls as the original bakes them (`game.srofiles.Settings.real_lights`).
    real_lights: bool = true,
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
    /// Whether the interface's text is drawn in outline fonts at the window's resolution
    /// (`game.hud.outline`), or in the game's bitmap fonts alone.
    outline_fonts: bool = true,
    /// How the sound plays, or null for none.
    sound: ?platform.audio.Options = .{},
    /// Where a missile's sound is heard from.
    missile_sound: game.sound3d.MissileSound = .follows,
    /// A piece of music to play from the start, from `music\`, before the mission's script plays
    /// its own; none by default.
    music: ?[]const u8 = null,

    /// OpenAL Soft's settings, which a setting for it after `--original` plays with again.
    pub fn openAl(options: *Options) ?*platform.audio.openal.Settings {
        const sound = &(options.sound orelse return null);
        if (sound.player == .software) sound.player = .{ .openal = .{} };
        return &sound.player.openal;
    }

    /// What `args` ask for: to play with `base`, what the settings file keeps (`settings.read`),
    /// changed for the run by the options they give; the help page; the version; or what is wrong
    /// with them.
    pub fn parse(args: []const [:0]const u8, base: Options) Command {
        var options = base;
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
    pub fn apply(options: *Options, arg: Arg, value: []const u8) error{BadValue}!void {
        switch (arg) {
            .@"--original" => {
                options.original = true;
                options.settings = .original;
                options.smooth_motion = false;
                options.riders = .in_turn;
                options.shot_lights = .latest_two;
                options.real_lights = false;
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
                options.outline_fonts = false;
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
            .@"--no-mods" => options.mods = false,
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
            .@"--no-materials" => options.settings.materials = false,
            .@"--shadows" => options.settings.shadows = std.meta.stringToEnum(platform.gpu.Settings.Shadows, value) orelse return error.BadValue,
            .@"--no-cockpit-shadows" => options.settings.cockpit_shadows = false,
            .@"--no-smooth-motion" => options.smooth_motion = false,
            .@"--few-shot-lights" => options.shot_lights = .latest_two,
            .@"--baked-lights" => options.real_lights = false,
            .@"--bitmap-fonts" => options.outline_fonts = false,
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
                const bus: engine.mss.master.Settings = sound.master orelse .{};
                sound.master = bus.withoutCompressor();
            },
            .@"--no-sound" => options.sound = null,
            .@"--screenshot" => options.screenshot = value,
            .@"--screenshot-ticks" => options.screenshot_ticks = @max(std.fmt.parseInt(u32, value, 10) catch return error.BadValue, minimum_screenshot_ticks),
            .@"--help", .@"--version" => {},
        }
    }

    /// A size given as `<width>x<height>`, each from 1 to `max_size`, or as `<percent>%` of the
    /// window's own, from 1 to the whole.
    fn parseSize(text: []const u8) ?FrameSize {
        if (std.mem.endsWith(u8, text, "%")) {
            const share = std.fmt.parseInt(u8, text[0 .. text.len - 1], 10) catch return null;
            return if (share >= 1 and share <= FrameSize.whole) .{ .share = share } else null;
        }
        var halves = std.mem.splitScalar(u8, text, 'x');
        var size: [2]u32 = undefined;
        for (&size) |*side| {
            const digits = halves.next() orelse return null;
            side.* = std.fmt.parseInt(u32, digits, 10) catch return null;
            if (side.* == 0 or side.* > max_size) return null;
        }
        return if (halves.next() == null) .{ .pixels = size } else null;
    }

    /// The largest side `--size` takes, which GPUs draw to.
    const max_size = 16384;

    /// How the frames are paced as the game starts.
    pub fn pacing(options: Options) Pacing {
        return .{ .fps = options.fps, .vsync = options.settings.vsync, .software = options.software };
    }
};

/// How the frames are paced, which the settings screen changes as the game plays: frames a second at
/// most, and whether the display paces them.
pub const Pacing = struct {
    /// Frames a second at most, 0 for no limit; null for the display's rate without vsync.
    fps: ?f32 = null,
    vsync: bool = true,
    /// Whether the software device draws the frames, which go to the window as the display shows
    /// them.
    software: bool = false,

    /// The frames a second to hold to, where the display does not already.
    pub fn rate(pacing: Pacing, window: platform.window.Window) ?f32 {
        if (pacing.fps) |fps| return if (fps > 0) fps else null;
        if (pacing.software or pacing.vsync) return null;
        return window.refreshRate();
    }
};

/// The game ticks a screenshot runs at least, one a frame.
const minimum_screenshot_ticks = 2;

/// Reading the options, for the tests.
pub const testing = struct {
    /// The options `args` play with.
    pub fn parsed(args: []const [:0]const u8) error{Usage}!Options {
        return switch (Options.parse(args, .{})) {
            .play => |options| options,
            .help, .version, .wrong => error.Usage,
        };
    }
};

const parsed = testing.parsed;

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
    // Mods are loaded unless `--no-mods` is given.
    try std.testing.expect((try parsed(&.{})).mods);
    try std.testing.expect(!(try parsed(&.{"--no-mods"})).mods);
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
    try std.testing.expect(retro.original and !plain.original);
    try std.testing.expect(retro.settings.sixteen_bit);
    try std.testing.expectEqual(.off, retro.settings.shadows);
    try std.testing.expectEqual(.low, (try parsed(&.{ "--shadows", "low" })).settings.shadows);
    try std.testing.expect(!(try parsed(&.{"--no-cockpit-shadows"})).settings.cockpit_shadows);
    try std.testing.expect(!(try parsed(&.{"--gamma-space"})).settings.linear_light);
    try std.testing.expect(plain.settings.materials);
    try std.testing.expect(!(try parsed(&.{"--no-materials"})).settings.materials);
    try std.testing.expect(!retro.settings.materials);
    try std.testing.expect(!retro.settings.linear_light);
    try std.testing.expectEqual(.original, retro.settings.filter);
    try std.testing.expectEqual(8, retro.settings.samples);
    try std.testing.expect(!retro.settings.vsync);
    try std.testing.expectEqual(0, retro.fps.?);
    try std.testing.expect(!retro.smooth_motion);
    try std.testing.expectEqual(.together, plain.riders);
    try std.testing.expectEqual(.in_turn, retro.riders);
    try std.testing.expectEqual(.latest_two, retro.shot_lights);
    try std.testing.expect(plain.real_lights and !retro.real_lights);
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
    try std.testing.expect(plain.outline_fonts and !retro.outline_fonts);
    try std.testing.expect(!(try parsed(&.{"--bitmap-fonts"})).outline_fonts);
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
    try std.testing.expect(!(try parsed(&.{"--baked-lights"})).real_lights);
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
    try std.testing.expectEqual(FrameSize{ .pixels = .{ 3840, 2160 } }, (try parsed(&.{ "--size", "3840x2160" })).settings.size);
    try std.testing.expectEqual(FrameSize{ .share = 50 }, (try parsed(&.{ "--size", "50%" })).settings.size);
    try std.testing.expectEqual(FrameSize.window, (try parsed(&.{})).settings.size);
    for ([_][:0]const u8{ "3840", "0x100", "100x", "1x2x3", "99999x100", "0%", "101%", "%", "x%" }) |bad| {
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
    try std.testing.expectEqual(.help, std.meta.activeTag(Options.parse(&.{"--help"}, .{})));
    try std.testing.expectEqual(.help, std.meta.activeTag(Options.parse(&.{ "game", "-h" }, .{})));
    try std.testing.expectEqual(.version, std.meta.activeTag(Options.parse(&.{ "game", "--version" }, .{})));
    var buffer: [128]u8 = undefined;
    const cases = [_]struct { []const [:0]const u8, []const u8 }{
        .{ &.{"--bogus"}, "unknown option '--bogus'" },
        .{ &.{"--msaa"}, "--msaa takes a value, <1|2|4|8>" },
        .{ &.{ "--msaa", "3" }, "--msaa takes <1|2|4|8>, not '3'" },
        .{ &.{ "--no-sound", "--view", "cockpit" }, "--view takes <0|1|2>, not 'cockpit'" },
    };
    for (cases) |case| {
        const problem = Options.parse(case[0], .{}).wrong;
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
