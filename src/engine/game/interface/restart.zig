//! The restart screen (`restart_screen`, `0x0043EB80`), which `WinMain` turns to after a mission of
//! the campaign the pilot did not come through (`winmain.afterMission`): REPLAY MISSION FROM
//! BRIEFING, REPLAY MISSION FROM LAUNCH and MAIN MENU, over `interface\restart.spr`'s picture. It
//! fades in by the palette's brightness, takes the first press on a choice's button, and fades out
//! again. Its drawing (`restart_screen_draw`, `0x0043ED90`) is the render hook it puts in
//! `sr + 0x88`.

const std = @import("std");

const input = @import("../../input.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Label = canvas_module.Label;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;

/// The screen's shapes (`0x0051D4D0`): its picture, a lit button, and the pointer's frames.
pub const shapes_name = "interface\\restart.spr";

/// What the screen offers, in the order of its buttons.
pub const Choice = enum {
    /// REPLAY MISSION FROM BRIEFING: the game as the mission began (`restart_load`), and the
    /// mission's briefing.
    replay_from_briefing,
    /// REPLAY MISSION FROM LAUNCH: the game as the mission began, and the mission flown again at
    /// once.
    replay_from_launch,
    /// MAIN MENU, or Escape: the front end's main menu.
    main_menu,
};

/// Where the pointer finds each choice's button (`0x0043EB8B` on).
pub const rects = std.EnumArray(Choice, Rect).init(.{
    .replay_from_briefing = .{ .x = 162, .y = 371, .width = 30, .height = 21 },
    .replay_from_launch = .{ .x = 162, .y = 398, .width = 30, .height = 21 },
    .main_menu = .{ .x = 162, .y = 425, .width = 30, .height = 21 },
});

/// Where a choice's button is lit under the pointer (`0x0043EE67` to `0x0043EEA3`), and where its
/// label, a string of the game's, is written (`0x0043EEBC` on).
const lit_at = std.EnumArray(Choice, [2]i32).init(.{
    .replay_from_briefing = .{ 164, 373 },
    .replay_from_launch = .{ 164, 400 },
    .main_menu = .{ 164, 427 },
});
const labels = std.EnumArray(Choice, Label).init(.{
    .replay_from_briefing = .of(0x32D, .{ 199, 374 }, .left),
    .replay_from_launch = .of(0x32E, .{ 199, 402 }, .left),
    .main_menu = .of(0x32F, .{ 199, 428 }, .left),
});

/// The picture and the lit button (`0x0043EE37`, `0x0043EE71`), and where the picture stands
/// (`0x0043EE33`).
const picture_shape = 0x12;
const lit_shape = 0x13;
const picture_at: [2]i32 = .{ 1, 1 };

/// The labels' colour (`interface_palette_ramp`, `0x0043EEB2`): orange.
const label_colour = hud.rgb(0xFE851A);

/// How much brighter the screen grows each game tick as it fades in, and darker as it fades out
/// (`0x004DC64C`): from dark to full in 30.
const fade_step: f32 = 1.0 / 30.0;

/// The screen's state.
pub const Restart = struct {
    /// How bright it is drawn (`palette_ramp_brightness`, `0x005202F0`), from dark.
    brightness: f32 = 0,
    /// The button under the pointer (`0x005201A0`), which stays lit as the screen fades out.
    under: ?Choice = null,
    /// What was chosen, as the screen fades out, the pointer put away meanwhile (`0x0051DB50`).
    chosen: ?Choice = null,

    /// A pass of the screen's loop, `elapsed` game ticks after the last. Until a choice is made,
    /// it grows brighter up to full, Escape chooses MAIN MENU, and a press on a button chooses its
    /// choice at once (`0x0043EC9F`). Then it grows darker, and ends with the choice once dark, or
    /// at once as Escape is pressed again (`0x0043ECF7` on).
    pub fn frame(screen: *Restart, pointer: Pointer, keyboard: *input.Keyboard, elapsed: u32) ?Choice {
        const escaped = keyboard.pressed(input.scan.escape, .none, true);
        const step = @as(f32, @floatFromInt(elapsed)) * fade_step;
        if (screen.chosen) |chosen| {
            if (escaped) return chosen;
            screen.brightness -= step;
            if (screen.brightness >= 0) return null;
            screen.brightness = 0;
            return chosen;
        }
        screen.brightness = @min(screen.brightness + step, 1);
        if (escaped) {
            screen.chosen = .main_menu;
            return null;
        }
        screen.under = canvas_module.itemAt(Choice, &rects, pointer.at);
        if (pointer.down) screen.chosen = screen.under;
        return null;
    }

    /// `restart_screen_draw` (`0x0043ED90`), at the screen's brightness over a cleared frame: its
    /// picture, the button under the pointer lit, the three labels in the small font, and the
    /// pointer until a choice is made.
    pub fn draw(screen: Restart, canvas: Canvas, art: *hud.Art, pointer: Pointer) canvas_module.Error!void {
        var faded = canvas;
        faded.brightness = screen.brightness;
        try faded.shape(art, picture_shape, picture_at);
        if (screen.under) |under| try faded.shape(art, lit_shape, lit_at.get(under));
        for (labels.values) |label| try label.write(faded, faded.fonts.small, label_colour);
        if (screen.chosen == null) try faded.shape(art, pointer.shape(), pointer.at);
    }
};

test Restart {
    var keyboard: input.Keyboard = .{};
    var screen: Restart = .{};
    // It fades in over 30 ticks, and stays at full.
    try std.testing.expectEqual(null, screen.frame(.{ .at = .{ 10, 10 } }, &keyboard, 15));
    try std.testing.expectApproxEqAbs(0.5, screen.brightness, 1e-6);
    try std.testing.expectEqual(null, screen.frame(.{ .at = .{ 10, 10 } }, &keyboard, 30));
    try std.testing.expectEqual(1, screen.brightness);
    // A press on REPLAY MISSION FROM LAUNCH's button chooses it, and the screen fades out with it
    // lit, then ends.
    try std.testing.expectEqual(null, screen.frame(.{ .at = .{ 170, 405 }, .down = true }, &keyboard, 1));
    try std.testing.expectEqual(.replay_from_launch, screen.chosen.?);
    try std.testing.expectEqual(null, screen.frame(.{ .at = .{ 10, 10 } }, &keyboard, 15));
    try std.testing.expectEqual(.replay_from_launch, screen.under.?);
    try std.testing.expectEqual(.replay_from_launch, screen.frame(.{ .at = .{ 10, 10 } }, &keyboard, 16).?);
    // Its label is not its button: a press there chooses nothing.
    screen = .{};
    _ = screen.frame(.{ .at = .{ 250, 380 }, .down = true }, &keyboard, 1);
    try std.testing.expectEqual(null, screen.chosen);
}
