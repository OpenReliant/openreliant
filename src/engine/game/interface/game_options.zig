//! GAME OPTIONS, screen 1 of the front end (`game_options`, `0x0042A620`), which the main menu's
//! GAME OPTIONS opens: AUDIO, CONTROL DEVICES and VIDEO by their icons, and MAIN MENU, QUIT and
//! ABOUT STARLANCER, which OpenReliant makes ABOUT OPENRELIANT (`in_game_options.About`). Its
//! drawing (`game_options_draw`, `0x0042AFB0`) is the render hook it puts in `sr + 0x88`.
//!
//! AUDIO, CONTROL DEVICES and VIDEO open the settings screen on its audio, its controls and its
//! video (`settings`).

const std = @import("std");

const input = @import("../../input.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const dialog = @import("dialog.zig");
const in_game_options = @import("in_game_options.zig");
const About = in_game_options.About;
const settings = @import("settings.zig");

/// The menu's shapes and what it shows behind itself (`0x0042A6D7`, `0x0042A6E1`): the options'
/// picture, with the icons.
pub const shapes_name = "interface\\frntend4.spr";
pub const background_name = "interface\\main2opt.tga";

/// The menu's items, in the order of its table.
pub const Item = enum { audio, control_devices, video, main_menu, quit, about };

/// Where the pointer finds each item (`0x0042A623` on).
pub const rects = std.EnumArray(Item, Rect).init(.{
    .audio = .{ .x = 30, .y = 165, .width = 152, .height = 127 },
    .control_devices = .{ .x = 219, .y = 165, .width = 152, .height = 127 },
    .video = .{ .x = 408, .y = 165, .width = 152, .height = 127 },
    .main_menu = .{ .x = 292, .y = 441, .width = 25, .height = 16 },
    .quit = .{ .x = 324, .y = 441, .width = 25, .height = 16 },
    .about = .{ .x = 292, .y = 421, .width = 25, .height = 16 },
});

/// An icon's label and its shape under the pointer (`0x0042B091` on).
fn icon(item: Item) ?in_game_options.Panel {
    return switch (item) {
        .audio => .{ .label = .of(0x109, .{ 133, 319 }, .centre), .lit_shape = 0x13, .lit_at = .{ 35, 155 } },
        .control_devices => .{ .label = .of(0x10A, .{ 320, 319 }, .centre), .lit_shape = 0x14, .lit_at = .{ 202, 160 } },
        .video => .{ .label = .of(0x10B, .{ 511, 319 }, .centre), .lit_shape = 0x15, .lit_at = .{ 392, 161 } },
        .main_menu, .quit, .about => null,
    };
}

/// A button's label, in the small font beside it (`0x0042B3AF` on).
fn buttonLabel(item: Item) ?Label {
    return switch (item) {
        .main_menu => .of(0xBB, .{ 288, 440 }, .right),
        .quit => .of(0xBC, .{ 353, 440 }, .left),
        .about => .{ .text = .{ .words = About.title }, .at = .{ 288, 420 }, .alignment = .right },
        .audio, .control_devices, .video => null,
    };
}

/// The buttons' shapes, as they stand and lit (`0x0042B00B`, `0x0042B2D5`).
const button_shape = 0x1B;
const lit_button_shape = 0x1C;

/// The title, SELECT AN OPTION (`0x0042B2F3`).
const title: Label = .of(0x108, .{ 320, 95 }, .centre);

/// The question QUIT asks (`0x0042A766`): Do you really want to Quit?
const quit_question = 0x374;

/// The movie MAIN MENU and Escape play before the main menu (`0x0042A832`).
pub const to_main_menu = "interface\\opt2main.bik";

/// Where the menu leads.
pub const Choice = union(enum) {
    /// MAIN MENU, or Escape: `to_main_menu`, then the main menu.
    main_menu,
    /// QUIT, answered YES.
    quit,
    /// AUDIO, CONTROL DEVICES and VIDEO: the settings screen, on its audio (screen 3), its controls
    /// (screen 16) or its video (screen 15).
    settings: settings.Tab,
};

/// The menu's state.
pub const GameOptions = struct {
    /// The item under the pointer (`roster_item`, `0x00520130`).
    under: ?Item = null,
    /// QUIT's question, and ABOUT OPENRELIANT's box, while either is up.
    confirm: ?dialog.Confirm = null,
    about: ?About = null,

    /// A pass of the menu's loop (`0x0042A709` on): Escape and MAIN MENU go to the main menu, AUDIO,
    /// CONTROL DEVICES and VIDEO to the settings screen, QUIT asks first, and ABOUT opens its box.
    /// While QUIT's question or ABOUT OPENRELIANT's box is up, it takes the pass.
    pub fn frame(menu: *GameOptions, pointer: Pointer, keyboard: *input.Keyboard) ?Choice {
        const escaped = keyboard.pressed(input.scan.escape, .none, true);
        if (menu.about) |*about| {
            if (about.frame(pointer, escaped)) menu.about = null;
            return null;
        }
        if (menu.confirm) |*confirm| {
            const answer = confirm.frame(pointer, escaped) orelse return null;
            menu.confirm = null;
            return if (answer) .quit else null;
        }
        if (escaped) return .main_menu;
        menu.under = canvas_module.itemAt(Item, &rects, pointer.at);
        const chosen = menu.under orelse return null;
        if (!pointer.down) return null;
        switch (chosen) {
            .audio => return .{ .settings = .audio },
            .control_devices => return .{ .settings = .controls },
            .video => return .{ .settings = .video },
            .main_menu => return .main_menu,
            .quit => menu.confirm = .{ .message = .{ .string = quit_question } },
            .about => menu.about = .{},
        }
        return null;
    }

    /// `game_options_draw` (`0x0042AFB0`), over the menu's background: the buttons, the item under
    /// the pointer lit, the title and the labels, ABOUT OPENRELIANT's box or QUIT's question where
    /// either is up, OpenReliant's version, then the pointer. The game writes the label under the
    /// pointer white before the labels, which write over it in blue, so it stays blue.
    pub fn draw(menu: GameOptions, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, about_art: *hud.Art, pointer: Pointer) canvas_module.Error!void {
        for ([_]Item{ .about, .main_menu, .quit }) |item| {
            const rect = rects.get(item);
            try canvas.shape(art, button_shape, .{ rect.x, rect.y });
        }
        if (menu.under) |under| {
            if (icon(under)) |lit| {
                try canvas.shape(art, lit.lit_shape, lit.lit_at);
            } else {
                const rect = rects.get(under);
                try canvas.shape(art, lit_button_shape, .{ rect.x, rect.y });
            }
        }
        const blue = canvas_module.blue;
        try title.write(canvas, canvas.fonts.large, blue);
        for (std.enums.values(Item)) |item| {
            if (icon(item)) |shown| try shown.label.write(canvas, canvas.fonts.large, blue);
            if (buttonLabel(item)) |label| try label.write(canvas, canvas.fonts.small, blue);
        }
        if (menu.about) |about| try about.draw(canvas, about_art);
        if (menu.confirm) |confirm| try confirm.draw(canvas, dialog_art);
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
    }
};

test GameOptions {
    var keyboard: input.Keyboard = .{};
    var menu: GameOptions = .{};
    // The icons lead to the settings screen.
    try std.testing.expectEqual(Choice{ .settings = .controls }, menu.frame(.{ .at = .{ 300, 200 }, .down = true }, &keyboard).?);
    try std.testing.expectEqual(Choice{ .settings = .audio }, menu.frame(.{ .at = .{ 100, 200 }, .down = true }, &keyboard).?);
    try std.testing.expectEqual(Choice{ .settings = .video }, menu.frame(.{ .at = .{ 500, 200 }, .down = true }, &keyboard).?);
    // MAIN MENU at once; QUIT asks first.
    try std.testing.expectEqual(.main_menu, menu.frame(.{ .at = .{ 300, 450 }, .down = true }, &keyboard).?);
    try std.testing.expectEqual(null, menu.frame(.{ .at = .{ 330, 450 }, .down = true }, &keyboard));
    try std.testing.expect(menu.confirm != null);
    _ = menu.frame(.{ .at = .{ 295, 275 }, .down = true }, &keyboard);
    try std.testing.expectEqual(.quit, menu.frame(.{ .at = .{ 295, 275 } }, &keyboard).?);
    // ABOUT opens its box, which Escape closes; then Escape leads to the main menu.
    menu = .{};
    _ = menu.frame(.{ .at = .{ 300, 430 }, .down = true }, &keyboard);
    try std.testing.expect(menu.about != null);
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, menu.frame(.{}, &keyboard));
    try std.testing.expectEqual(null, menu.about);
    keyboard.latched[input.scan.escape] = false;
    try std.testing.expectEqual(.main_menu, menu.frame(.{}, &keyboard).?);
}
