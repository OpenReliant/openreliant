//! `C:\lancer\GenILib\interf.cpp`: the loop the front end's screens run in, `interface_run`
//! (`0x004289D0`), which runs the screen of its number until one hands WinMain an outcome.
//!
//! **Unverified:** the file of `interface_run` and of the front end's start-up (`0x004288E0`),
//! which lie after the file's known code and before `interface.cpp`'s; they run the screens rather
//! than being one, so they go with GenILib's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fat = @import("../../formats/fat.zig");
const spr = @import("../../formats/spr.zig");
const input = @import("../input.zig");
const profile = @import("../profile.zig");
const game = @import("../game.zig");
const bigfile = game.bigfile;
const hog_snd = game.hog_snd;
const hud = game.hud;
const language = game.language;
const winmain = game.winmain;
const matmanager = game.matmanager;
const interface = game.interface;
const canvas = interface.canvas;
const main_menu = interface.main_menu;
const game_options = interface.game_options;
const pilot_roster = interface.pilot_roster;
const saved_games = interface.saved_games;
const settings = interface.settings;
const movie = game.xtrabits.movie;
const device = @import("../surrender/srd3d/device.zig");

pub const ease = @import("interf/ease.zig");
pub const i3d = @import("interf/i3d.zig");

const log = std.log.scoped(.interface);

/// The front end's screens, by the number `interface_run` runs them by (`0x0051DAC4`). Numbers 10
/// and 11 are the multiplayer sessions, and 17 and 18 a session's loadout, each pair the same
/// screen with a flag set or clear (`0x0051D54C`); a number without a screen ends the front end.
pub const Screen = enum(u8) {
    main_menu = 0,
    game_options = 1,
    audio = 3,
    briefing = 7,
    landing_movie = 8,
    pilot_roster = 12,
    saved_games = 13,
    connection = 14,
    video = 15,
    controls = 16,
    _,

    pub fn format(screen: Screen, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (screen) {
            _ => writer.print("screen {d}", .{@intFromEnum(screen)}),
            inline else => |named| writer.writeAll(@tagName(named)),
        };
    }
};

/// What the front end ends in, which `interface_run` returns to WinMain.
pub const Outcome = union(enum) {
    /// QUIT, answered YES: 3.
    quit,
    /// START GAME: 1, a single-player campaign, which `WinMain` takes into the Reliant's rooms
    /// before the mission of its number (`winmain.CampaignStart`). The pilot the roster set flies
    /// its missions (`Interface.pilot`).
    campaign: u16,
    /// A mission to fly without its briefing: the developers' keys' (1, with `skip_briefing` set),
    /// or INSTANT ACTION's, which the main menu flies itself.
    fly: main_menu.Flight,
    /// The developers' briefing of the mission of its number, from its loadout on
    /// (`briefing_from_loadout`): screen 7, whose -1 takes `WinMain` back to the front end's main
    /// menu.
    briefing: u16,
    /// LOAD GAME's saved game loaded: 1, which `WinMain` takes as START GAME's, into the Reliant's
    /// rooms before the loaded campaign's mission (`0x004AA1AB` on).
    loaded,
};

/// The mission a new campaign starts with (`campaign_new` sets `mission_number` to 1).
pub const first_mission = 1;

/// What the front end draws with, which it opens as it starts and frees as it ends: the fonts its
/// start-up opens (`interface_init`, `0x004288E0`), the developers' font the display opens
/// (`font_01`), the dialog's shapes and ABOUT STARLANCER's box's, which `about_box` reads as it
/// opens (`0x0042A556`); and the shown screen's shapes (`interface_shapes`, `0x0051D60C`) and
/// background, which a screen reads as it starts and frees as it leaves (`show`).
pub const Resources = struct {
    gpa: Allocator,
    archive: bigfile.Hog,
    files: std.EnumArray(File, []u8),
    large: hud.FontFile,
    small: hud.FontFile,
    developer: hud.FontFile,
    dialog: hud.Art,
    about: hud.Art,
    /// The screen whose shapes and background are read, its shapes, and the file they are read
    /// from.
    screen: ?Screen = null,
    shapes: ?hud.Art = null,
    shapes_file: []u8 = &.{},
    background: matmanager.Background = .{},

    /// The files it reads, which the dialogs' shapes are made of.
    pub const File = enum { dialog, about };

    const names = std.EnumArray(File, []const u8).init(.{
        .dialog = interface.dialog.shapes_name,
        .about = interface.in_game_options.about_shapes_name,
    });

    /// Opens what the front end draws with, its fonts with the outline fonts of `outlines` that
    /// stand in for them, and the main menu's shapes and background.
    pub fn open(gpa: Allocator, archive: bigfile.Hog, outlines: ?*hud.outline.Outlines) !Resources {
        var large: hud.FontFile = try .open(gpa, archive, hud.large_menu_font, outlines);
        errdefer large.deinit(gpa);
        var small: hud.FontFile = try .open(gpa, archive, hud.small_menu_font, outlines);
        errdefer small.deinit(gpa);
        var developer: hud.FontFile = try .open(gpa, archive, main_menu.developer_font_name, outlines);
        errdefer developer.deinit(gpa);
        var files: std.EnumArray(File, []u8) = undefined;
        var read: usize = 0;
        errdefer for (files.values[0..read]) |file| gpa.free(file);
        for (&files.values, names.values) |*file, name| {
            file.* = try archive.readFile(gpa, name);
            read += 1;
        }
        var resources: Resources = .{
            .gpa = gpa,
            .archive = archive,
            .files = files,
            .large = large,
            .small = small,
            .developer = developer,
            .dialog = try .init(gpa, try spr.Sprite.parse(files.get(.dialog)), null, .of(archive.mods, names.get(.dialog))),
            .about = undefined,
        };
        errdefer resources.dialog.deinit(gpa);
        resources.about = try .init(gpa, try spr.Sprite.parse(files.get(.about)), null, .of(archive.mods, names.get(.about)));
        errdefer resources.about.deinit(gpa);
        try resources.show(.main_menu);
        return resources;
    }

    /// Reads the shapes and the background of `screen`, where it has its own, in place of the
    /// last screen's.
    pub fn show(resources: *Resources, screen: Screen) !void {
        if (resources.screen == screen) return;
        const shown = screenFiles(screen) orelse return;
        const gpa = resources.gpa;
        const file = try resources.archive.readFile(gpa, shown.shapes);
        errdefer gpa.free(file);
        var art: hud.Art = try .init(gpa, try spr.Sprite.parse(file), null, .of(resources.archive.mods, shown.shapes));
        errdefer art.deinit(gpa);
        try resources.background.set(gpa, resources.archive, shown.background);
        resources.dropShapes();
        resources.shapes = art;
        resources.shapes_file = file;
        resources.screen = screen;
    }

    fn dropShapes(resources: *Resources) void {
        if (resources.shapes) |*art| art.deinit(resources.gpa);
        resources.gpa.free(resources.shapes_file);
        resources.shapes = null;
        resources.shapes_file = &.{};
        resources.screen = null;
    }

    pub fn close(resources: *Resources) void {
        const gpa = resources.gpa;
        resources.background.deinit(gpa);
        resources.dropShapes();
        resources.dialog.deinit(gpa);
        resources.about.deinit(gpa);
        inline for (.{ &resources.large, &resources.small, &resources.developer }) |font| font.deinit(gpa);
        for (resources.files.values) |file| gpa.free(file);
    }
};

/// The shapes and the background of each screen ported.
fn screenFiles(screen: Screen) ?struct { shapes: []const u8, background: []const u8 } {
    return switch (screen) {
        .main_menu => .{ .shapes = main_menu.shapes_name, .background = main_menu.background_name },
        .game_options => .{ .shapes = game_options.shapes_name, .background = game_options.background_name },
        .audio => .{ .shapes = settings.shapes_name, .background = settings.opening(.game_options, .audio).?.background },
        .controls => .{ .shapes = settings.shapes_name, .background = settings.opening(.game_options, .controls).?.background },
        .video => .{ .shapes = settings.shapes_name, .background = settings.opening(.game_options, .video).?.background },
        .pilot_roster => .{ .shapes = pilot_roster.shapes_name, .background = pilot_roster.background_name },
        .saved_games => .{ .shapes = saved_games.shapes_name, .background = saved_games.opening(.roster).background },
        else => null,
    };
}

/// What a frame of the front end reads and plays through.
pub const Context = struct {
    devices: *input.Devices,
    /// The characters typed into the window.
    typed: *winmain.Typed,
    /// The window's size in pixels.
    window: [2]u32,
    /// The timer's ticks since the last frame.
    elapsed: i32,
    sound: ?*hog_snd.Sound = null,
    /// `bank_stdsmp`.
    bank: ?fat.Bank = null,
    /// What the front end draws with, whose shown screen's shapes and background a screen reads
    /// as it is entered; none reads nothing.
    resources: ?*Resources = null,
    /// `starlancer.ini`, which keeps the roster's call signs and the settings; none leaves them
    /// unsaved, and the settings screen shut.
    settings: ?*profile.File = null,
    /// OpenReliant's own options, which the settings screen shows; none shows them as they come.
    own: ?settings.Own = null,
    /// The game's video settings, which the settings screen changes; none leaves them as they are.
    video: ?settings.Video = null,
    /// The saved games LOAD GAME lists, and the game it loads into; none leaves LOAD GAME on the
    /// roster.
    saves: ?saved_games.Saves = null,
};

/// The front end's state, which the game keeps in globals.
pub const Interface = struct {
    screen: Screen = .main_menu,
    /// The screen whose entering has run.
    entered: ?Screen = null,
    pointer: canvas.Pointer = .{},
    main_menu: main_menu.MainMenu = .{},
    game_options: game_options.GameOptions = .{},
    settings: settings.Settings = .{},
    pilot_roster: pilot_roster.Roster = .{},
    saved_games: saved_games.SavedGames = .{},
    /// The pilot the roster sets, which every mission the front end starts is flown by.
    pilot: pilot_roster.Pilot = .{},
    /// The timer's ticks since the front end began, which the saved games' cursor blinks by, and
    /// the settings screen's list scrolls by.
    ticks: u32 = 0,
    /// The pointer's button, which the shown screen takes only once the press held as it was
    /// entered has come up.
    press: input.FreshPress = .{},
    /// The movie a screen plays as it leads to another (`play_bink_movie_no_clear`), which the
    /// driver plays before the next frame (`game.xtrabits.movie`).
    movie: ?[]const u8 = null,

    /// A frame of `interface_run`: the shown screen entered where it has just been chosen, the
    /// pointer brought up to date (`interface_pointer_update`), then the screen's frame. Returns
    /// what the front end ends in, once it does.
    ///
    /// Not ported: MULTI PLAYER's screens (#43 lists them). Until they are, MULTI PLAYER stays on
    /// the main menu, without its movie.
    ///
    /// **Fix:** a screen takes no press until the button held as it was entered comes up. The
    /// movie between two screens gives the press that chose the second time to end; where the
    /// transitions are off, the game lets it go on to what lies under the pointer on the new
    /// screen.
    pub fn frame(front: *Interface, context: Context) ?Outcome {
        front.ticks +%= @intCast(@max(context.elapsed, 0));
        front.enterShown(context);
        front.pointer.update(&context.devices.mouse, context.window, context.elapsed);
        var pointer = front.pointer;
        pointer.down = front.press.pressed(front.pointer.down);
        switch (front.screen) {
            .main_menu => {
                const choice = front.main_menu.frame(.{
                    .pointer = pointer,
                    .keyboard = &context.devices.keyboard,
                    .sound = context.sound,
                    .bank = context.bank,
                }) orelse return null;
                return switch (choice) {
                    .quit => .quit,
                    .fly => |flight| .{ .fly = flight },
                    .briefing => |mission| .{ .briefing = mission },
                    .pilot_roster => {
                        front.screen = .pilot_roster;
                        front.movie = movie.main_to_single;
                        return null;
                    },
                    .instant_action => .{ .fly = main_menu.instant_action },
                    .game_options => {
                        front.screen = .game_options;
                        front.movie = movie.main_to_options;
                        return null;
                    },
                    .connection => {
                        log.info("MULTI PLAYER is not ported yet", .{});
                        return null;
                    },
                };
            },
            .game_options => {
                const choice = front.game_options.frame(pointer, &context.devices.keyboard) orelse return null;
                switch (choice) {
                    .main_menu => {
                        front.screen = .main_menu;
                        front.movie = game_options.to_main_menu;
                    },
                    .quit => return .quit,
                    .settings => |tab| if (context.settings != null) {
                        front.screen = screenOf(tab);
                        front.movie = settings.opening(.game_options, tab).?.movie;
                    },
                }
                return null;
            },
            .audio, .controls, .video => {
                const settings_file = context.settings orelse {
                    front.screen = .game_options;
                    return null;
                };
                const end = front.settings.frame(settingsContext(front, context, settings_file, pointer)) orelse return null;
                front.movie = settings.leavingMovie(.game_options, end);
                front.screen = switch (end) {
                    .back, .continue_mission => .game_options,
                    .main_menu => .main_menu,
                };
                return null;
            },
            .pilot_roster => {
                const choice = front.pilot_roster.frame(.{
                    .pointer = pointer,
                    .keyboard = &context.devices.keyboard,
                    .typed = context.typed,
                    .elapsed = context.elapsed,
                    .small = if (context.resources) |resources| &resources.small.font else null,
                    .pilot = &front.pilot,
                    .settings = context.settings,
                }) orelse return null;
                switch (choice) {
                    .main_menu => {
                        front.screen = .main_menu;
                        front.movie = movie.single_to_main;
                    },
                    .saved_games => if (context.saves != null) {
                        front.screen = .saved_games;
                        front.movie = saved_games.opening(.roster).movie;
                    },
                    .start_game => {
                        front.leave(context);
                        return .{ .campaign = first_mission };
                    },
                    .quit => return .quit,
                }
                return null;
            },
            .saved_games => {
                const saves = context.saves orelse {
                    front.screen = .pilot_roster;
                    return null;
                };
                const end = front.saved_games.frame(savesContext(front, context, saves, pointer)) orelse return null;
                front.movie = saved_games.leavingMovie(.load, .roster, end);
                switch (end) {
                    .back => front.screen = .pilot_roster,
                    .main_menu => front.screen = .main_menu,
                    .quit => return .quit,
                    .done => {
                        front.leave(context);
                        return .loaded;
                    },
                }
                return null;
            },
            else => {
                log.info("{f} is not ported yet", .{front.screen});
                front.screen = .main_menu;
                return null;
            },
        }
    }

    /// The shown screen entered where it has not been yet, as a pass begins, and as the driver does
    /// before it draws a screen a transition's movie or a mission's end has just led to, so that
    /// its first frame is drawn with its own shapes and background.
    pub fn enterShown(front: *Interface, context: Context) void {
        if (front.entered != front.screen) front.enter(context);
    }

    /// Enters the shown screen, as each screen does before its loop, leaving the last: its shapes
    /// and background read where the front end's resources are given, and the press held then
    /// not taken.
    fn enter(front: *Interface, context: Context) void {
        front.leave(context);
        front.press = .{};
        switch (front.screen) {
            .main_menu => front.main_menu.enter(&front.pointer, context.sound),
            .game_options => front.game_options = .{},
            .audio => if (context.settings) |settings_file| front.settings.enter(.game_options, .audio, settingsContext(front, context, settings_file, front.pointer)),
            .controls => if (context.settings) |settings_file| front.settings.enter(.game_options, .controls, settingsContext(front, context, settings_file, front.pointer)),
            .video => if (context.settings) |settings_file| front.settings.enter(.game_options, .video, settingsContext(front, context, settings_file, front.pointer)),
            .pilot_roster => front.pilot_roster.enter(context.typed, &front.pilot),
            .saved_games => if (context.saves) |saves| front.saved_games.enter(.load, .roster, savesContext(front, context, saves, front.pointer)),
            else => {},
        }
        if (context.resources) |resources| resources.show(front.screen) catch |err| {
            log.warn("{f}'s shapes and background are left out: {s}", .{ front.screen, @errorName(err) });
        };
        front.entered = front.screen;
    }

    /// Leaves the screen entered, as it ends its loop.
    fn leave(front: *Interface, context: Context) void {
        if (front.entered == .pilot_roster) pilot_roster.Roster.leave(context.typed);
        front.entered = null;
    }

    /// Whether the front end takes text as it is typed: while the roster's call sign is, or a saved
    /// game's name.
    pub fn takesText(front: *const Interface) bool {
        return switch (front.screen) {
            .pilot_roster => front.pilot_roster.typing,
            .saved_games => front.saved_games.takesText(),
            else => false,
        };
    }

    /// Comes back to the front end, as a mission started from it ends: its main menu again, until
    /// the campaign's way on after a mission is ported (#74).
    pub fn back(front: *Interface) void {
        front.screen = .main_menu;
        front.entered = null;
    }

    /// The front end's frame as its render hook draws it (`sr + 0x88`): the background behind all,
    /// then the shown screen, the settings screen's of `shown`, with OpenReliant's `version` in the
    /// window's corner where there is one (`canvas.Canvas.drawVersion`).
    pub fn draw(front: Interface, resources: *Resources, target: device.Device, window: [2]u32, strings: *const language.Language, shown: settings.Shown, version: ?[]const u8) canvas.Error!void {
        const drawn: canvas.Canvas = .{
            .gpa = resources.gpa,
            .target = target,
            .window = window,
            .fonts = .{ .large = &resources.large.font, .small = &resources.small.font },
            .strings = strings,
            .version = version,
        };
        if (resources.background.image) |*picture| drawn.fill(picture);
        const art = if (resources.shapes) |*shapes| shapes else return;
        switch (front.screen) {
            .main_menu => try front.main_menu.draw(drawn, art, &resources.dialog, front.pointer, &resources.developer.font),
            .game_options => try front.game_options.draw(drawn, art, &resources.dialog, &resources.about, front.pointer),
            .audio, .controls, .video => try front.settings.draw(drawn, art, &resources.dialog, shown, front.pointer),
            .pilot_roster => try front.pilot_roster.draw(drawn, art, &resources.dialog, front.pointer, front.pilot),
            .saved_games => try front.saved_games.draw(drawn, art, &resources.dialog, front.pointer, front.pilot.call_sign.slice()),
            else => {},
        }
    }
};

/// What a pass of the settings screen reads, with the pointer at `pointer`.
fn settingsContext(front: *const Interface, context: Context, settings_file: *profile.File, pointer: canvas.Pointer) settings.Context {
    return .{ .pointer = pointer, .devices = context.devices, .settings_file = settings_file, .ticks = front.ticks, .sound = context.sound, .own = context.own, .video = context.video };
}

/// The screen of the settings screen's `tab`, the game's screen for it; the video's for the
/// graphics, OpenReliant's, which the game has none of.
fn screenOf(tab: settings.Tab) Screen {
    return switch (tab) {
        .audio => .audio,
        .controls => .controls,
        .video, .graphics => .video,
    };
}

/// What a pass of the saved games reads, with the pointer at `pointer`.
fn savesContext(front: *const Interface, context: Context, saves: saved_games.Saves, pointer: canvas.Pointer) saved_games.Context {
    return .{ .pointer = pointer, .keyboard = &context.devices.keyboard, .typed = context.typed, .ticks = front.ticks, .saves = saves };
}

test "the front end's first choices" {
    var devices: input.Devices = .{};
    var typed: winmain.Typed = .{};
    var front: Interface = .{};
    const context: Context = .{ .devices = &devices, .typed = &typed, .window = .{ 640, 480 }, .elapsed = 1 };
    // SINGLE PLAYER opens the pilot roster, whose call sign takes what is typed. The press held
    // from the main menu picks nothing there, so the typing goes on.
    devices.mouse.at = .{ 100.0 / 640.0, 200.0 / 480.0 };
    _ = front.frame(context);
    devices.mouse.buttons.left = true;
    try std.testing.expectEqual(null, front.frame(context));
    try std.testing.expectEqual(Screen.pilot_roster, front.screen);
    // The roster is entered before its first frame is drawn, as its movie ends.
    try std.testing.expectEqual(Screen.main_menu, front.entered);
    front.enterShown(context);
    try std.testing.expectEqual(Screen.pilot_roster, front.entered);
    _ = front.frame(context);
    _ = front.frame(context);
    try std.testing.expect(front.takesText() and typed.file_names);
    devices.mouse.buttons.left = false;
    _ = front.frame(context);
    // MAIN MENU leads back, and the characters typed are no longer refused. Held on, the press
    // does not go on to INSTANT ACTION, which stands where MAIN MENU did.
    devices.mouse.at = .{ 310.0 / 640.0, 445.0 / 480.0 };
    devices.mouse.buttons.left = true;
    _ = front.frame(context);
    try std.testing.expectEqual(null, front.frame(context));
    try std.testing.expectEqual(Screen.main_menu, front.screen);
    try std.testing.expect(!typed.file_names);
    devices.mouse.buttons.left = false;
    _ = front.frame(context);
    // GAME OPTIONS leads to its menu, after its movie.
    devices.mouse.at = .{ 500.0 / 640.0, 300.0 / 480.0 };
    devices.mouse.buttons.left = true;
    try std.testing.expectEqual(null, front.frame(context));
    try std.testing.expectEqual(Screen.game_options, front.screen);
    try std.testing.expectEqualStrings(movie.main_to_options, front.movie.?);
    front.movie = null;
    // Escape leads back.
    devices.mouse.buttons.left = false;
    devices.keyboard.down[input.scan.escape] = true;
    _ = front.frame(context);
    try std.testing.expectEqual(Screen.main_menu, front.screen);
    devices.keyboard.down[input.scan.escape] = false;
    devices.keyboard.read();
    _ = front.frame(context);
    devices.mouse.buttons.left = true;
    // INSTANT ACTION flies mission 29 in the simulator.
    devices.mouse.at = .{ 310.0 / 640.0, 450.0 / 480.0 };
    try std.testing.expectEqual(main_menu.instant_action, front.frame(context).?.fly);
}

test "LOAD GAME opens the saved games, where there are saves to list" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var devices: input.Devices = .{};
    var typed: winmain.Typed = .{};
    var front: Interface = .{ .screen = .pilot_roster };
    var campaign: game.gameflow.Campaign = .begin();
    var player: input.Player = .{};
    var tier: u2 = 0;
    var saved: @import("../interface/loadout/loadout.zig").Saved = .{};
    const strings: language.Language = .{ .strings = &.{} };
    var context: Context = .{ .devices = &devices, .typed = &typed, .window = .{ 640, 480 }, .elapsed = 1 };
    const click = struct {
        fn at(on: *Interface, with: Context, x: f32, y: f32) ?Outcome {
            with.devices.mouse.at = .{ x / 640.0, y / 480.0 };
            with.devices.mouse.buttons.left = false;
            _ = on.frame(with);
            with.devices.mouse.buttons.left = true;
            return on.frame(with);
        }
    }.at;
    // Without the saved games to list, LOAD GAME stays on the roster.
    try std.testing.expectEqual(null, click(&front, context, 450, 305));
    try std.testing.expectEqual(Screen.pilot_roster, front.screen);
    // With them, it leads to the saved games after the roster's movie, loading, with none found.
    context.saves = .{
        .gpa = std.testing.allocator,
        .folder = .{ .io = std.testing.io, .dir = tmp.dir },
        .game = .{ .campaign = &campaign, .player = &player, .tier = &tier, .pilot = &front.pilot, .saved = &saved },
        .strings = &strings,
    };
    try std.testing.expectEqual(null, click(&front, context, 450, 305));
    try std.testing.expectEqual(Screen.saved_games, front.screen);
    try std.testing.expectEqualStrings(saved_games.opening(.roster).movie, front.movie.?);
    front.movie = null;
    front.enterShown(context);
    try std.testing.expectEqual(saved_games.Mode.load, front.saved_games.mode);
    try std.testing.expectEqual(0, front.saved_games.scrolled.count);
    // BACK goes back to the roster, after its movie.
    try std.testing.expectEqual(null, click(&front, context, 300, 428));
    try std.testing.expectEqual(Screen.pilot_roster, front.screen);
    try std.testing.expectEqualStrings("interface\\sinfade2.bik", front.movie.?);
}

test {
    std.testing.refAllDecls(@This());
}

test Screen {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("pilot_roster", try std.fmt.bufPrint(&buffer, "{f}", .{Screen.pilot_roster}));
    try std.testing.expectEqualStrings("screen 10", try std.fmt.bufPrint(&buffer, "{f}", .{@as(Screen, @enumFromInt(10))}));
}
