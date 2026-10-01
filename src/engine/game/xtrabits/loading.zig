//! The loading screens (`0x004AB2B0` to `0x004AB69F`): a picture filling the screen, and a line of
//! the game's strings centred near its foot, which the game shows as it starts and before each
//! attempt at a mission, rendering a frame at each step of the loading. The line is drawn over the
//! frame as it is rendered (`sr + 0x88`), in the front end's large font (`hud.large_menu_font`),
//! through the brightest of the text's grey ramps (`text_ramps`, `0x005955A0`), which maps the
//! font's levels onto the greys of the renderer's palette, up to white.
//!
//! **Unverified:** the file. The loading screens lie between the message pump's code and the first
//! code `xtrabits.cpp`'s assertions place, and the file's `mission_load` and renderer's start run
//! them, so they go with `xtrabits.cpp`.
//!
//! Not ported: in a network session, the players' names and READY beside each one ready, which
//! the mission's loading lists under its line (`loading_players_draw`, `0x004AB300`)
//! ([#404](https://github.com/vdmkenny/openreliant/issues/404)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fnt = @import("../../../formats/fnt.zig");
const bigfile = @import("../bigfile.zig");
const canvas = @import("../interface/canvas.zig");
const create = @import("../create.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const matmanager = @import("../matmanager.zig");

const log = std.log.scoped(.loading);

/// What a loading frame shows: `picture` filling the screen, and the game's string `line` over it,
/// or none.
pub const Frame = struct {
    picture: []const u8,
    line: ?String = null,
};

/// The pictures the mission's loading shows by the screen's width (`0x0050A26C`, `0x0050A234`,
/// `0x0050A250`): one picture at three sizes.
pub const splash = "interface\\sl_splash.tga";
pub const splash_800 = "interface\\sl_splash800.tga";
pub const splash_1024 = "interface\\sl_splash1024.tga";

/// The picture the start-up's loading shows (`0x0050A2D0`).
pub const startup_picture = "interface\\splash.tga";

/// The game's strings the loading screens write (`language_string`): LOADING (`0x004AB3F0`), and
/// the mission's loading's line by the simulator's mode (`0x004AD1C9`, `0x004AD1D3`,
/// `0x004AD1DA`).
pub const String = enum(u32) {
    loading = 0x32A,
    preparing_for_launch = 0xE2,
    calibrating_simulator = 0x14B,
    preparing_for_instant_action = 0x289,
};

/// Which of the mission's loading's pictures is shown.
pub const Splash = enum {
    /// **Improvement:** the largest, `splash_1024`, whatever the screen's width, drawn as large as
    /// fits in the window as the front end's screens are.
    largest,
    /// The one the screen's width picks, as the game has it (`pictureFor`).
    by_width,

    /// The picture for a screen `width` pixels across.
    pub fn picture(choice: Splash, width: u32) []const u8 {
        return switch (choice) {
            .largest => splash_1024,
            .by_width => pictureFor(width),
        };
    }
};

/// `loading_screen`'s pick (`0x004AB40D`): `splash_800` for a screen 800 pixels across,
/// `splash_1024` for one 1024 across, and `splash` for any other.
pub fn pictureFor(width: u32) []const u8 {
    return switch (width) {
        800 => splash_800,
        1024 => splash_1024,
        else => splash,
    };
}

/// The line the mission's loading writes under its picture, by the simulator's mode
/// (`mission_load`, `0x004AD1C0`): Preparing for Instant Action for any mode but none and the
/// Reliant's simulator's training.
pub fn missionLine(mode: create.Simulator.Mode) String {
    return switch (mode) {
        .none => .preparing_for_launch,
        .training => .calibrating_simulator,
        .instant_action, _ => .preparing_for_instant_action,
    };
}

/// The frames the loading before each attempt at a mission shows (`mission_load`,
/// `0x004AD0A0`), with the renderer's and the textures' setting up and the display's between them:
/// its picture alone (`loading_screen`, `0x004AB3F0`), which writes LOADING as the line but sets
/// no overlay to draw it, then the picture with the line by the simulator's `mode`
/// (`missionLine`). `choice` picks the picture for a screen `width` pixels across.
pub fn missionFrames(choice: Splash, width: u32, mode: create.Simulator.Mode) [2]Frame {
    const picture = choice.picture(width);
    return .{ .{ .picture = picture }, .{ .picture = picture, .line = missionLine(mode) } };
}

/// The start-up's frames, as the renderer's start loads the game (`0x004AB4B0`): the picture alone
/// once the ships' stats are read, then with LOADING before each load after them
/// (`loading_step`, `0x004AB470`), which the message pump runs first.
pub const startup_first: Frame = .{ .picture = startup_picture };
pub const startup_step: Frame = .{ .picture = startup_picture, .line = .loading };

/// How far above the screen's foot the line stands, in its pixels: centred across, its top this
/// far up (`loading_line_draw`, `0x004AB2EB`).
const line_rise = 40;

/// What the loading screens draw with: the front end's large font, drawn as levels of one colour
/// (`hud.Opened.ramp`), its small one, which OpenReliant's version is written in, and the picture
/// shown.
pub const Resources = struct {
    gpa: Allocator,
    large: hud.FontFile,
    small: hud.FontFile,
    picture: matmanager.Background = .{},

    /// The fonts of `archive`, with the outline fonts of `outlines` that stand in for them.
    pub fn open(gpa: Allocator, archive: bigfile.Hog, outlines: ?*hud.outline.Outlines) !Resources {
        var large: hud.FontFile = try .open(gpa, archive, hud.large_menu_font, outlines);
        errdefer large.deinit(gpa);
        return .{ .gpa = gpa, .large = large, .small = try .open(gpa, archive, hud.small_menu_font, outlines) };
    }

    pub fn close(resources: *Resources) void {
        resources.picture.deinit(resources.gpa);
        inline for (.{ &resources.large, &resources.small }) |font| font.deinit(resources.gpa);
    }

    /// Readies `frame`'s picture (`background_set`), read from `archive` unless it is shown
    /// already; one that can't be read leaves the screen bare, logged.
    pub fn show(resources: *Resources, archive: bigfile.Hog, frame: Frame) void {
        resources.picture.set(resources.gpa, archive, frame.picture) catch |err| {
            log.warn("the loading screen's {s} is left out: {s}", .{ frame.picture, @errorName(err) });
            resources.picture.deinit(resources.gpa);
        };
    }

    /// Draws a frame of the loading screen on `drawn`, the front end's screen: the picture over the
    /// whole of it (`background_set`), and `line`, where there is one, in white, centred across it
    /// and its top `line_rise` above its foot (`loading_line_draw`, `0x004AB2B0`), then
    /// OpenReliant's version (`canvas.Canvas.drawVersion`). The game lays the line out in the
    /// screen's pixels; OpenReliant lays it out as it does on a screen 640 by 480, as large as
    /// fits in the window, as the front end's screens are.
    pub fn draw(resources: *Resources, drawn: canvas.Canvas, line: ?[]const u8) Allocator.Error!void {
        if (resources.picture.image) |*picture| drawn.fill(picture);
        if (line) |words| {
            const at: [2]i32 = .{ @divTrunc(canvas.size[0], 2), canvas.size[1] - line_rise };
            try drawn.text(&resources.large.font, at, words, white, .centre);
        }
        try drawn.drawVersion();
    }
};

/// The colour the line ramps through: the renderer's palette's greys, up to white.
const white: [3]f32 = .{ 1, 1, 1 };

test pictureFor {
    try std.testing.expectEqualStrings(splash_800, pictureFor(800));
    try std.testing.expectEqualStrings(splash_1024, pictureFor(1024));
    try std.testing.expectEqualStrings(splash, pictureFor(640));
    try std.testing.expectEqualStrings(splash, pictureFor(1920));
    // OpenReliant shows the largest, whatever the width.
    try std.testing.expectEqualStrings(splash_1024, Splash.largest.picture(640));
    try std.testing.expectEqualStrings(splash, Splash.by_width.picture(1280));
}

test missionFrames {
    // The picture alone, then with the line the simulator's mode picks.
    const launch = missionFrames(.by_width, 800, .none);
    try std.testing.expectEqualStrings(splash_800, launch[0].picture);
    try std.testing.expectEqual(null, launch[0].line);
    try std.testing.expectEqualStrings(splash_800, launch[1].picture);
    try std.testing.expectEqual(String.preparing_for_launch, launch[1].line.?);
    try std.testing.expectEqual(String.calibrating_simulator, missionFrames(.largest, 800, .training)[1].line.?);
    try std.testing.expectEqual(String.preparing_for_instant_action, missionFrames(.largest, 800, .instant_action)[1].line.?);
    try std.testing.expectEqual(String.preparing_for_instant_action, missionLine(@enumFromInt(7)));
}

test Resources {
    const gpa = std.testing.allocator;
    const device = @import("../../surrender/srd3d/device.zig");
    const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
    const font = comptime fnt.testing.font(true);
    var resources: Resources = .{
        .gpa = gpa,
        .large = .{ .bytes = &.{}, .font = .ramp(try fnt.Font.parse(font)) },
        .small = .{ .bytes = &.{}, .font = .ramp(try fnt.Font.parse(font)) },
    };
    defer inline for (.{ &resources.large, &resources.small }) |file| file.font.deinit(gpa);
    // A picture 4 by 3, of the front end's shape.
    const rgba = try gpa.alloc(u8, 4 * 3 * 4);
    @memset(rgba, 0xFF);
    resources.picture.image = srtexture.Image.single(gpa, 4, 3, rgba) catch |err| {
        gpa.free(rgba);
        return err;
    };
    defer resources.picture.deinit(gpa);
    var recorder: device.testing.Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const strings: language.Language = .{ .strings = &.{} };
    const drawn: canvas.Canvas = .{
        .gpa = gpa,
        .target = recorder.interface(),
        .window = .{ 1280, 960 },
        .fonts = .{ .large = &resources.large.font, .small = &resources.small.font },
        .strings = &strings,
    };

    // The picture alone covers the whole of the screen, twice the front end's size here.
    try resources.draw(drawn, null);
    try std.testing.expectEqual(1, recorder.draws.items.len);
    const corners = recorder.drawn(0);
    try std.testing.expectEqual(0, corners[0].x);
    try std.testing.expectEqual(0, corners[0].y);
    try std.testing.expectEqual(1280, corners[2].x);
    try std.testing.expectEqual(960, corners[2].y);

    // A line's glyph stands centred across, 40 of the front end's pixels above the foot.
    recorder.clear();
    try resources.draw(drawn, &.{1});
    try std.testing.expectEqual(2, recorder.draws.items.len);
    const glyph = recorder.drawn(1);
    const width: f32 = @floatFromInt(resources.large.font.widths[1]);
    try std.testing.expectEqual(640 - width, glyph[0].x);
    try std.testing.expectEqual((480 - 40) * 2, glyph[0].y);
}
