//! `C:\lancer\GenILib\interf.cpp`: the loop the front end's screens run in, `interface_run`
//! (`0x004289D0`), which runs the screen of its number until one hands WinMain an outcome.
//!
//! **Unverified:** the file of `interface_run` and of the front end's start-up (`0x004288E0`),
//! which lie after the file's known code and before `interface.cpp`'s; they run the screens rather
//! than being one, so they go with GenILib's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fat = @import("../../formats/fat.zig");
const fnt = @import("../../formats/fnt.zig");
const spr = @import("../../formats/spr.zig");
const input = @import("../input.zig");
const game = @import("../game.zig");
const bigfile = game.bigfile;
const hog_snd = game.hog_snd;
const hud = game.hud;
const language = game.language;
const matmanager = game.matmanager;
const interface = game.interface;
const canvas = interface.canvas;
const main_menu = interface.main_menu;
const device = @import("../surrender/srd3d/device.zig");

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
    /// A mission to fly: 1, where the briefing is skipped, else 2 once the briefing has been.
    fly: Flight,
};

/// A mission to fly: its number, the ship type the loadout gives the player, or null for the
/// mission's own, and whether it is flown without its briefing and loadout (`skip_briefing`).
pub const Flight = struct {
    mission: u16,
    ship: ?u8 = null,
    skip_briefing: bool = true,
};

/// The mission SINGLE PLAYER starts while the pilot roster, the Reliant's rooms and the briefing
/// are not ported: the campaign's first.
pub const first_mission = 1;

/// What the front end draws with, which it opens as it starts and frees as it ends: the fonts its
/// start-up opens (`0x004288E0`), the developers' font the display opens (`font_01.fnt`,
/// `0x0059506C`), the main menu's shapes and its dialog's, and the background shown behind them.
/// The game frees a screen's shapes as it leaves the screen; the front end has one screen so far.
pub const Resources = struct {
    gpa: Allocator,
    files: [5][]u8,
    large: hud.Opened,
    small: hud.Opened,
    developer: hud.Opened,
    shapes: hud.Art,
    dialog: hud.Art,
    background: matmanager.Background = .{},

    pub const large_font = "interface\\optfnt.fnt";
    pub const small_font = "interface\\smlfnt2.fnt";

    pub fn open(gpa: Allocator, archive: bigfile.Hog) !Resources {
        var files: [5][]u8 = undefined;
        var read: usize = 0;
        errdefer for (files[0..read]) |file| gpa.free(file);
        for (&files, [_][]const u8{ large_font, small_font, main_menu.developer_font_name, main_menu.shapes_name, interface.dialog.shapes_name }) |*file, name| {
            file.* = try archive.readFile(gpa, name);
            read += 1;
        }
        var shapes: hud.Art = try .init(gpa, try spr.Sprite.parse(files[3]), null);
        errdefer shapes.deinit(gpa);
        var resources: Resources = .{
            .gpa = gpa,
            .files = files,
            .large = .ramp(try fnt.Font.parse(files[0])),
            .small = .ramp(try fnt.Font.parse(files[1])),
            .developer = .ramp(try fnt.Font.parse(files[2])),
            .shapes = shapes,
            .dialog = try .init(gpa, try spr.Sprite.parse(files[4]), null),
        };
        errdefer resources.dialog.deinit(gpa);
        try resources.background.set(gpa, archive, main_menu.background_name);
        return resources;
    }

    pub fn close(resources: *Resources) void {
        const gpa = resources.gpa;
        resources.background.deinit(gpa);
        resources.shapes.deinit(gpa);
        resources.dialog.deinit(gpa);
        inline for (.{ &resources.large, &resources.small, &resources.developer }) |font| font.deinit(gpa);
        for (resources.files) |file| gpa.free(file);
    }
};

/// What a frame of the front end reads and plays through.
pub const Context = struct {
    devices: *input.Devices,
    /// The window's size in pixels.
    window: [2]u32,
    /// The timer's ticks since the last frame.
    elapsed: i32,
    sound: ?*hog_snd.Sound = null,
    /// `bank_stdsmp`.
    bank: ?fat.Bank = null,
};

/// The front end's state, which the game keeps in globals.
pub const Interface = struct {
    screen: Screen = .main_menu,
    /// The screen whose entering has run.
    entered: ?Screen = null,
    pointer: canvas.Pointer = .{},
    main_menu: main_menu.MainMenu = .{},

    /// A frame of `interface_run`: the pointer brought up to date (`0x004360D0`), then the shown
    /// screen's frame, entering it first where it has just been chosen. Returns what the front end
    /// ends in, once it does.
    ///
    /// Not ported: the screens besides the main menu (#43 lists them), and the movies played
    /// between screens (#401). Until they are, SINGLE PLAYER starts the campaign's first mission,
    /// the other screens stay on the main menu, and INSTANT ACTION does nothing (#399).
    pub fn frame(front: *Interface, context: Context) ?Outcome {
        if (front.screen == .main_menu and front.entered != .main_menu) {
            front.main_menu.enter(&front.pointer, context.sound);
            front.entered = .main_menu;
        }
        front.pointer.update(context.devices.mouse, context.window, context.elapsed);
        switch (front.screen) {
            .main_menu => {
                const choice = front.main_menu.frame(.{
                    .pointer = front.pointer,
                    .keyboard = &context.devices.keyboard,
                    .sound = context.sound,
                    .bank = context.bank,
                }) orelse return null;
                return switch (choice) {
                    .quit => .quit,
                    .fly => |flight| .{ .fly = .{ .mission = std.math.cast(u16, flight.mission) orelse return null, .ship = flight.ship, .skip_briefing = !flight.briefing } },
                    .pilot_roster => .{ .fly = .{ .mission = first_mission } },
                    .connection, .game_options, .instant_action => {
                        log.info("MULTI PLAYER, GAME OPTIONS and INSTANT ACTION are not ported yet", .{});
                        return null;
                    },
                };
            },
            else => {
                log.info("{f} is not ported yet", .{front.screen});
                front.screen = .main_menu;
                return null;
            },
        }
    }

    /// Comes back to the front end, as a mission started from it ends: its main menu again, until
    /// the debriefing is ported (#73).
    pub fn back(front: *Interface) void {
        front.screen = .main_menu;
        front.entered = null;
    }

    /// The front end's frame as its render hook draws it (`sr + 0x88`): the background behind all,
    /// then the shown screen.
    pub fn draw(front: Interface, resources: *Resources, target: device.Device, window: [2]u32, strings: *const language.Language) canvas.Error!void {
        const drawn: canvas.Canvas = .{
            .gpa = resources.gpa,
            .target = target,
            .window = window,
            .fonts = .{ .large = &resources.large, .small = &resources.small },
            .strings = strings,
        };
        if (resources.background.image) |*shown| drawn.image(shown, .{ 0, 0 });
        switch (front.screen) {
            .main_menu => try front.main_menu.draw(drawn, &resources.shapes, &resources.dialog, front.pointer, &resources.developer),
            else => {},
        }
    }
};

test "the front end's first choices" {
    var devices: input.Devices = .{};
    var front: Interface = .{};
    // SINGLE PLAYER starts the campaign's first mission, for now.
    devices.mouse.at = .{ 100.0 / 640.0, 200.0 / 480.0 };
    devices.mouse.buttons.left = true;
    const outcome = front.frame(.{ .devices = &devices, .window = .{ 640, 480 }, .elapsed = 1 }).?;
    try std.testing.expectEqual(Flight{ .mission = first_mission }, outcome.fly);
    // GAME OPTIONS, not ported, stays on the main menu.
    devices.mouse.at = .{ 500.0 / 640.0, 300.0 / 480.0 };
    try std.testing.expectEqual(null, front.frame(.{ .devices = &devices, .window = .{ 640, 480 }, .elapsed = 1 }));
    try std.testing.expectEqual(Screen.main_menu, front.screen);
}

test Screen {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("pilot_roster", try std.fmt.bufPrint(&buffer, "{f}", .{Screen.pilot_roster}));
    try std.testing.expectEqualStrings("screen 10", try std.fmt.bufPrint(&buffer, "{f}", .{@as(Screen, @enumFromInt(10))}));
}
