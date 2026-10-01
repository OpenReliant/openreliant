//! `hudoptions.cpp`: the pause menu, which the game draws in place of the display while a mission
//! is paused, and whose screens change the settings.
//! [`pause-menu.md`](../../../docs/engine/pause-menu.md) describes it.
//!
//! **Unverified:** the file's name, which no assertion gives; the doc says where it comes from.
//!
//! Ported so far: the menu's items, how they are drawn and found under the pointer, and the
//! buttons the screens share ([`hudoptions/menu.zig`](hudoptions/menu.zig)); the pointer, the
//! fonts and the screens' order (`pause_menu_draw`); and the main screen
//! ([`hudoptions/screens.zig`](hudoptions/screens.zig)). The audio, controls and video screens, the
//! controls of which F1 opens too, are OpenReliant's settings screen (`SettingsScreen`). Not yet:
//! the multiplayer screen (#211); and the two screens nothing reaches.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fnt = @import("../../formats/fnt.zig");
const device = @import("../surrender/srd3d/device.zig");
const input = @import("../input.zig");
const profile = @import("../profile.zig");
const bigfile = @import("bigfile.zig");
const camera = @import("camera.zig");
const hog_snd = @import("hog_snd.zig");
const hud = @import("hud.zig");
const language = @import("language.zig");
const interface = @import("interface.zig");
const canvas = interface.canvas;
const settings_screen = interface.settings;

pub const menu = @import("hudoptions/menu.zig");
pub const screens = @import("hudoptions/screens.zig");

test {
    _ = menu;
    _ = screens;
}

/// A screen of the menu: `pause_screen` 1 to 4.
pub const Screen = enum { main, controls, audio, video };

/// What a choice ends the pause in, which `mission_paused_frame` acts on: `pause_screen` 5, 6 and
/// 7.
pub const Outcome = enum { restart, continue_mission, leave_mission };

/// Where a screen's choice goes.
pub const Next = union(enum) {
    screen: Screen,
    outcome: Outcome,
};

/// What the screens show and change, as the game keeps it in its globals, and the file they save
/// it to as they are left.
pub const Settings = struct {
    file: *profile.File,
    sound: *hog_snd.Sound,
    /// The game's video settings, which the settings screen's video changes.
    video: settings_screen.Video,
    /// OpenReliant's own options, which the settings screen shows; none shows them as they come.
    own: ?settings_screen.Own = null,
};

/// What a screen draws with and reads for a frame.
pub const Context = struct {
    ui: menu.Ui,
    pointer: menu.Pointer,
    /// Whether Escape went down since the last frame (`key_pressed`, once).
    escaped: bool,
};

/// What `pause_menu_draw` draws with.
pub const Frame = struct {
    target: device.Device,
    screen: [2]u32,
    /// The display's set of shapes, and its font, the menus' font 0 (`hud_font`).
    art: *hud.Art,
    font: *hud.Opened,
    strings: *const language.Language,
    devices: *input.Devices,
    settings: Settings,
    /// **Improvement.** OpenReliant's version, written small in the menu's bottom right corner.
    version: ?[]const u8 = null,
    /// The timer's ticks, which the settings screen's pointer and list run by.
    timer: u64 = 0,
};

/// The controls, the audio and the video, pause screens 2, 3 and 4: OpenReliant's settings screen
/// on its controls, its audio or its video, drawn as the front end draws it, fitted to the window,
/// over the mission, which it darkens; with the front end's shapes and its dialog's, read as it
/// opens, and a pointer of its own, which moves over it.
///
/// **Improvement:** OpenReliant shows the front end's settings screen in place of the pause menu's
/// own controls, audio and video screens (`pause_screen_controls`, `0x0048FEF0`;
/// `pause_screen_audio`, `0x0048EC70`; `pause_screen_video`, `0x0048F260`), as GAME OPTIONS and the
/// in-game options show it, with CONTINUE where those have MAIN MENU.
const SettingsScreen = struct {
    screen: settings_screen.Settings = .{},
    shapes: ?canvas.Shapes,
    dialog: ?canvas.Shapes,
    pointer: canvas.Pointer = .{},
    /// The pointer's button, which the screen takes once the press that opened it has come up.
    press: input.FreshPress = .{},
    /// The timer's ticks as the last frame was drawn.
    timer: u64,

    /// How dark the mission stands behind the screen.
    const shade: [4]f32 = .{ 0, 0, 0, 0.6 };

    fn close(shown: *SettingsScreen, gpa: Allocator) void {
        if (shown.shapes) |*shapes| shapes.deinit(gpa);
        if (shown.dialog) |*shapes| shapes.deinit(gpa);
    }

    /// The tab the pause menu's `screen` shows, of those the screen stands in for; null for the
    /// main screen, the pause menu's own.
    fn tabOf(screen: Screen) ?settings_screen.Tab {
        return switch (screen) {
            .audio => .audio,
            .controls => .controls,
            .video => .video,
            .main => null,
        };
    }
};

/// The pause menu's state, which the game keeps in `hudoptions.cpp`'s globals.
pub const PauseMenu = struct {
    /// `pause_screen` (`0x0057DAA4`): the screen shown, or what a choice ended the pause in.
    at: Next = .{ .screen = .main },
    /// `pause_screen_entered` (`0x0057DABC`): the screen whose enter routine last ran.
    entered: ?Screen = null,
    pointer: menu.Pointer = .{},
    /// The menu's fonts, open while it is.
    fonts: ?Fonts = null,
    /// The main screen's own state.
    main: screens.Main = .{},
    /// `pause_view_setting` (`0x00582E88`), `main.cpp`'s: the cockpit setting as the game paused,
    /// which resuming compares.
    view_setting: camera.CockpitSetting = .cockpit,
    /// The archive the fonts came from, which the settings screen's shapes are read from.
    archive: ?bigfile.Hog = null,
    /// The settings screen, while it is shown.
    settings: ?SettingsScreen = null,

    /// `optfnt.fnt` and `smlfnt2.fnt`, as `hog_load` read them and `font_open` opened them
    /// (`menu_font_large`, `menu_font_small`), and what holds them and their glyphs' images.
    const Fonts = struct {
        gpa: Allocator,
        small: hud.Opened,
        large: hud.Opened,
        files: [2][]u8,
    };

    pub const small_font = hud.small_menu_font;
    pub const large_font = hud.large_menu_font;

    pub fn isOpen(pause_menu: PauseMenu) bool {
        return pause_menu.fonts != null;
    }

    /// `pause_menu_open` (`0x00490600`), as the game pauses: opens the fonts from `archive` and
    /// starts on the main screen. The game also ends the missile lock tone; missiles are not
    /// ported yet (#39).
    pub fn open(pause_menu: *PauseMenu, gpa: Allocator, archive: bigfile.Hog) !void {
        const small = try archive.readFile(gpa, small_font);
        errdefer gpa.free(small);
        const large = try archive.readFile(gpa, large_font);
        errdefer gpa.free(large);
        pause_menu.fonts = .{
            .gpa = gpa,
            .small = .ramp(try fnt.Font.parse(small)),
            .large = .ramp(try fnt.Font.parse(large)),
            .files = .{ small, large },
        };
        pause_menu.at = .{ .screen = .main };
        pause_menu.entered = null;
        pause_menu.archive = archive;
    }

    /// `pause_menu_close` (`0x004906D0`), as the game resumes: frees the fonts.
    pub fn close(pause_menu: *PauseMenu) void {
        const fonts = if (pause_menu.fonts) |*open_fonts| open_fonts else return;
        if (pause_menu.settings) |*shown| shown.close(fonts.gpa);
        pause_menu.settings = null;
        fonts.small.deinit(fonts.gpa);
        fonts.large.deinit(fonts.gpa);
        for (fonts.files) |file| fonts.gpa.free(file);
        pause_menu.fonts = null;
        pause_menu.at = .{ .screen = .main };
    }

    /// What a choice has ended the pause in, once one has, while the menu is open: the paused
    /// frame acts on it once, and resuming closes the menu.
    pub fn outcome(pause_menu: PauseMenu) ?Outcome {
        if (!pause_menu.isOpen()) return null;
        return switch (pause_menu.at) {
            .screen => null,
            .outcome => |ended| ended,
        };
    }

    /// `pause_menu_draw` (`0x004906F0`), the overlay while paused, with the pointer brought up to
    /// date first as `mission_paused_frame` does (`menu_mouse_update`). A screen shown for the
    /// first time runs its enter routine; if its choice goes elsewhere, it runs its leave routine.
    /// The pointer is drawn last.
    pub fn draw(pause_menu: *PauseMenu, frame: Frame) menu.Error!void {
        const fonts = if (pause_menu.fonts) |*open_fonts| open_fonts else return;
        pause_menu.pointer.update(frame.devices.mouse, frame.screen);
        const ui: menu.Ui = .{
            .gpa = fonts.gpa,
            .target = frame.target,
            .screen = frame.screen,
            .scale = hud.scaleFor(frame.screen),
            .art = frame.art,
            .fonts = .{ .display = frame.font, .small = &fonts.small, .large = &fonts.large },
            .strings = frame.strings,
        };
        const screen = switch (pause_menu.at) {
            .screen => |shown| shown,
            .outcome => return,
        };
        const tab = SettingsScreen.tabOf(screen);
        if (pause_menu.entered != screen) {
            if (tab) |shown| pause_menu.enterSettings(frame, shown);
            pause_menu.entered = screen;
        }
        const next = if (tab != null) try pause_menu.settingsFrame(frame) else try pause_menu.main.frame(.{
            .ui = ui,
            .pointer = pause_menu.pointer,
            .escaped = frame.devices.keyboard.pressed(input.scan.escape, .none, true),
        });
        if (next) |going| if (!std.meta.eql(going, pause_menu.at)) {
            if (pause_menu.settings) |*shown| shown.close(fonts.gpa);
            pause_menu.settings = null;
            pause_menu.at = going;
        };
        if (tab != null) return;
        if (frame.version) |version| try hud.drawVersion(ui.fonts.small, ui.gpa, ui.target, ui.screen, version);
        try ui.drawPointer(pause_menu.pointer);
    }

    /// Opens the settings screen on `tab`: the front end's shapes and its dialog's read, and the
    /// screen entered.
    fn enterSettings(pause_menu: *PauseMenu, frame: Frame, tab: settings_screen.Tab) void {
        const fonts = &pause_menu.fonts.?;
        if (pause_menu.settings) |*shown| shown.close(fonts.gpa);
        const archive = if (pause_menu.archive) |*from| from else null;
        pause_menu.settings = .{
            .shapes = if (archive) |from| canvas.Shapes.read(fonts.gpa, from, settings_screen.shapes_name) else null,
            .dialog = if (archive) |from| canvas.Shapes.read(fonts.gpa, from, interface.dialog.shapes_name) else null,
            .timer = frame.timer,
        };
        const shown = &pause_menu.settings.?;
        shown.screen.enter(.pause_menu, tab, settingsContext(frame, shown.pointer));
    }

    /// A frame of the settings screen, the mission darkened behind it: where it leads, OK and
    /// Escape back to the main screen, and CONTINUE out of the pause.
    fn settingsFrame(pause_menu: *PauseMenu, frame: Frame) menu.Error!?Next {
        const fonts = &pause_menu.fonts.?;
        const shown = if (pause_menu.settings) |*kept| kept else return .{ .screen = .main };
        const elapsed = frame.timer -| shown.timer;
        shown.timer = frame.timer;
        shown.pointer.update(&frame.devices.mouse, frame.screen, std.math.lossyCast(i32, elapsed));
        var pointer = shown.pointer;
        pointer.down = shown.press.pressed(pointer.down);
        const end = shown.screen.frame(settingsContext(frame, pointer));
        hud.drawFilled(frame.target, .{ .left = 0, .top = 0, .right = @floatFromInt(frame.screen[0]), .bottom = @floatFromInt(frame.screen[1]) }, SettingsScreen.shade);
        const shapes = if (shown.shapes) |*read| &read.art else return .{ .screen = .main };
        const dialog_art = if (shown.dialog) |*read| &read.art else return .{ .screen = .main };
        const drawn: canvas.Canvas = .{
            .gpa = fonts.gpa,
            .target = frame.target,
            .window = frame.screen,
            .fonts = .{ .large = &fonts.large, .small = &fonts.small },
            .strings = frame.strings,
            .version = frame.version,
        };
        try shown.screen.draw(drawn, shapes, dialog_art, .{ .devices = frame.devices, .sound = frame.settings.sound, .video = frame.settings.video }, shown.pointer);
        return switch (end orelse return null) {
            .back, .main_menu => .{ .screen = .main },
            .continue_mission => .{ .outcome = .continue_mission },
        };
    }

    /// What a pass of the settings screen reads, with the pointer at `pointer`.
    fn settingsContext(frame: Frame, pointer: canvas.Pointer) settings_screen.Context {
        return .{
            .pointer = pointer,
            .devices = frame.devices,
            .settings_file = frame.settings.file,
            .ticks = @truncate(frame.timer),
            .sound = frame.settings.sound,
            .own = frame.settings.own,
            .video = frame.settings.video,
        };
    }
};

pub const testing = struct {
    /// An archive with the menu's two fonts, in a directory of its own.
    pub const FontArchive = struct {
        tmp: std.testing.TmpDir,
        hog: bigfile.Hog,

        pub fn close(fonts: *FontArchive, gpa: Allocator) void {
            fonts.hog.close(gpa);
            fonts.tmp.cleanup();
        }
    };

    pub fn fontArchive(gpa: Allocator) !FontArchive {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const font = comptime fnt.testing.font(true);
        try bigfile.testing.write(gpa, std.testing.io, tmp.dir, bigfile.resource_name, &.{
            .{ .name = "smlfnt2.fnt", .data = font },
            .{ .name = "optfnt.fnt", .data = font },
        });
        return .{ .tmp = tmp, .hog = try .open(gpa, std.testing.io, tmp.dir, bigfile.resource_name) };
    }
};

test "PauseMenu.outcome" {
    const gpa = std.testing.allocator;
    var archive = try testing.fontArchive(gpa);
    defer archive.close(gpa);
    var pause_menu: PauseMenu = .{};
    try pause_menu.open(gpa, archive.hog);
    try std.testing.expectEqual(null, pause_menu.outcome());
    pause_menu.at = .{ .outcome = .restart };
    try std.testing.expectEqual(Outcome.restart, pause_menu.outcome().?);
    // Once the game resumes and the menu closes, the choice is spent: it is acted on once.
    pause_menu.close();
    try std.testing.expectEqual(null, pause_menu.outcome());
    try std.testing.expectEqual(Next{ .screen = .main }, pause_menu.at);
}
