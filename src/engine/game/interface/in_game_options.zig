//! The in-game options (`in_game_options`, `0x004394D0`), which Escape opens over the Reliant's
//! rooms: SAVE, LOAD, AUDIO, CONTROL DEVICES and VIDEO, each a screen of the front end's, and BACK,
//! MAIN MENU, QUIT and ABOUT STARLANCER, which OpenReliant makes ABOUT OPENRELIANT (`About`). Its
//! drawing (`in_game_options_draw`, `0x004398B0`) is the render hook it puts in `sr + 0x88`.
//!
//! SAVE and LOAD open the saved games (`saved_games`) over the menu, after `igofade.bik`, which
//! the driver runs (`afterSavedGames`); AUDIO, CONTROL DEVICES and VIDEO open the settings screen
//! on its audio, its controls and its video (`settings`), after the same movie.

const std = @import("std");

const input = @import("../../input.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const dialog = @import("dialog.zig");
const saved_games = @import("saved_games.zig");
const settings = @import("settings.zig");

/// What the menu shows behind itself (`background_set`), its shapes (`0x00520278`), the ABOUT
/// STARLANCER box's (`0x0051D540`), and the movie MAIN MENU plays before the main menu
/// (`play_bink_movie_no_clear`).
pub const background_name = "interface\\ingameop.tga";
pub const shapes_name = "interface\\frntend7.spr";
pub const about_shapes_name = "interface\\frntend2.spr";
pub const to_main_menu = "interface\\igo2mm.bik";

/// The menu's items, in the order of its table.
pub const Item = enum { save, load, audio, control_devices, video, back, main_menu, quit, about };

/// Where the pointer finds each item (`0x004394D3` on).
pub const rects = std.EnumArray(Item, Rect).init(.{
    .save = .{ .x = 140, .y = 121, .width = 131, .height = 112 },
    .load = .{ .x = 338, .y = 121, .width = 130, .height = 109 },
    .audio = .{ .x = 65, .y = 276, .width = 130, .height = 109 },
    .control_devices = .{ .x = 250, .y = 272, .width = 130, .height = 111 },
    .video = .{ .x = 436, .y = 272, .width = 131, .height = 110 },
    .back = .{ .x = 199, .y = 422, .width = 120, .height = 15 },
    .main_menu = .{ .x = 199, .y = 443, .width = 120, .height = 15 },
    .quit = .{ .x = 329, .y = 443, .width = 100, .height = 15 },
    .about = .{ .x = 329, .y = 422, .width = 100, .height = 15 },
});

const Label = canvas_module.Label;
const Button = canvas_module.Button;

/// A panel's label, in the large font, centred under it, and its shape under the pointer, as GAME
/// OPTIONS' icons have them too.
pub const Panel = struct { label: Label, lit_shape: u8, lit_at: [2]i32 };

/// The buttons' shapes, as they stand and lit.
const button_shapes: Button.Pair = .{ .off = 0x1C, .lit = 0x1D };

fn panel(item: Item) ?Panel {
    return switch (item) {
        .save => .{ .label = .of(0x3B5, .{ 0xD0, 0xE9 }, .centre), .lit_shape = 0x12, .lit_at = .{ 0x6B, 0x73 } },
        .load => .{ .label = .of(0x149, .{ 0x198, 0xE9 }, .centre), .lit_shape = 0x13, .lit_at = .{ 0x134, 0x72 } },
        .audio => .{ .label = .of(0x109, .{ 0x82, 0x181 }, .centre), .lit_shape = 0x14, .lit_at = .{ 0x23, 0xFA } },
        .control_devices => .{ .label = .of(0x10A, .{ 0x142, 0x181 }, .centre), .lit_shape = 0x15, .lit_at = .{ 0xE6, 0xFF } },
        .video => .{ .label = .of(0x10B, .{ 0x1FA, 0x181 }, .centre), .lit_shape = 0x16, .lit_at = .{ 0x196, 0xFC } },
        .back, .main_menu, .quit, .about => null,
    };
}

fn button(item: Item) ?Button {
    return switch (item) {
        .back => .{ .label = .of(0xF7, .{ 0x124, 0x1A7 }, .right), .at = .{ 0x12B, 0x1A6 } },
        .main_menu => .{ .label = .of(0xBB, .{ 0x124, 0x1BC }, .right), .at = .{ 0x12B, 0x1BB } },
        .quit => .{ .label = .of(0xBC, .{ 0x165, 0x1BC }, .left), .at = .{ 0x149, 0x1BB } },
        .about => .{ .label = .{ .text = .{ .words = About.title }, .at = .{ 0x165, 0x1A7 } }, .at = .{ 0x149, 0x1A6 } },
        .save, .load, .audio, .control_devices, .video => null,
    };
}

/// The question QUIT asks (`0x004397C1`): Do you really want to Quit?
const quit_question = 0x374;

/// ABOUT STARLANCER's box (`about_box`, `0x0042A520`), drawn over the menu while it is up: its
/// box, its OK button, lit under the pointer, the title, and the notice (string `0x315`), centred
/// in lines at most 400 wide and 14 apart, below where the game writes `PID - ` and the product ID
/// its installer kept in the registry.
///
/// **Improvement:** it is OpenReliant's: ABOUT OPENRELIANT (`title`), as is the item that opens
/// it. The box's middle is filled black, where the game leaves it clear over the menu, and a few
/// words on OpenReliant, its version, copyright and license, stand in the product ID's place
/// above the game's notice, the lines drawn closer where they don't fit above OK 14 apart.
pub const About = struct {
    /// Whether OK is under the pointer (`dialog_button`).
    under: bool = false,
    /// Set as OK is clicked, until the pointer's button comes up.
    closing: bool = false,

    /// The box's title and the item's.
    pub const title = "ABOUT OPENRELIANT";

    /// What follows OpenReliant's name and version.
    const openreliant = "Copyright 2026 the OpenReliant contributors. Licensed under the Mozilla Public License 2.0.";

    const ok: Rect = .{ .x = 0x13C, .y = 0x14E, .width = 25, .height = 16 };
    const box_shape = 0x23;
    const box_at: [2]i32 = .{ 0x72, 0xB1 };
    const ok_shape = 0x1A;
    const lit_ok_shape = 0x1B;
    const title_label: Label = .{ .text = .{ .words = title }, .at = .{ 0x140, 0xB4 }, .alignment = .centre };
    const notice = 0x315;
    /// Where the lines start, the product ID's line in the game, and how they are laid out.
    const text_at: [2]i32 = .{ 0x140, 0xC2 };
    const lines: Canvas.Lines = .{ .width = 400, .height = 14, .most = 10 };
    const ok_label: Label = .of(0x316, .{ 0x134, 0x149 }, .right);

    /// A pass of its loop: Escape closes it at once, a click on OK once the button comes up.
    /// Whether it has closed.
    pub fn frame(about: *About, pointer: Pointer, escaped: bool) bool {
        if (about.closing) return !pointer.down;
        if (escaped) return true;
        about.under = ok.holds(pointer.at);
        if (about.under and pointer.down) about.closing = true;
        return false;
    }

    pub fn draw(about: About, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        if (art.shape(box_shape)) |shape| {
            const edge = shape.header;
            canvas.wipe(.{ box_at[0] + edge.x1, box_at[1] + edge.y1 }, .{ box_at[0] + edge.x2, box_at[1] + edge.y2 }, canvas_module.black);
        }
        try canvas.shape(art, box_shape, box_at);
        try canvas.shape(art, ok_shape, .{ ok.x, ok.y });
        if (about.under) try canvas.shape(art, lit_ok_shape, .{ ok.x, ok.y });
        const small = canvas.fonts.small;
        var buffer: [192]u8 = undefined;
        const ours = if (canvas.version) |version|
            std.fmt.bufPrint(&buffer, "OpenReliant {s}. {s}", .{ version, openreliant }) catch openreliant
        else
            "OpenReliant. " ++ openreliant;
        const theirs = canvas.strings.string(notice) orelse "";
        const spaced = spacing(small, ours, theirs);
        try canvas.wrapped(small, text_at, ours, canvas_module.blue, .centre, spaced);
        const below = text_at[1] + @as(i32, @intCast(spaced.count(small, ours))) * spaced.height;
        try canvas.wrapped(small, .{ text_at[0], below }, theirs, canvas_module.blue, .centre, spaced);
        try title_label.write(canvas, small, canvas_module.blue);
        try ok_label.write(canvas, canvas.fonts.large, canvas_module.blue);
    }

    /// How the lines of `ours` and `theirs` are laid out in `font`: 14 apart, or closer where they
    /// would reach OK's label.
    fn spacing(font: *hud.Opened, ours: []const u8, theirs: []const u8) Canvas.Lines {
        var spaced = lines;
        const count = lines.count(font, ours) + lines.count(font, theirs);
        if (count < 2) return spaced;
        const room = ok_label.at[1] - text_at[1] - @as(i32, @intCast(font.font.header.height));
        spaced.height = @min(lines.height, @divTrunc(room, @as(i32, @intCast(count - 1))));
        return spaced;
    }
};

/// Where the menu leads.
pub const Choice = union(enum) {
    /// BACK, or Escape: the rooms again.
    back,
    /// MAIN MENU: `to_main_menu`, then the main menu.
    main_menu,
    /// QUIT, answered YES.
    quit,
    /// SAVE and LOAD: the saved games over the menu, saving or loading (`0x00439695`,
    /// `0x004396E4`).
    save,
    load,
    /// AUDIO, CONTROL DEVICES and VIDEO: the settings screen over the menu, on its audio, its
    /// controls or its video (`0x0043973A`, `0x00439770`, `0x0043978B`).
    settings: settings.Tab,
};

/// How the in-game options end, with the saved games they open.
pub const End = enum {
    back,
    main_menu,
    quit,
    /// A saved game loaded: the rooms again from the loaded mission's first view, on its disc
    /// (`0x0043980C`).
    loaded,
};

/// What the in-game options do as the saved games `mode` opened ends by `end`
/// (`0x004396BE` on, `0x00439715` on): back to the menu, where it returns null; a game saved, the
/// rooms again; a game loaded, the rooms from its mission; the main menu or QUIT as the screen chose
/// them.
pub fn afterSavedGames(mode: saved_games.Mode, end: saved_games.End) ?End {
    return switch (end) {
        .back => null,
        .done => switch (mode) {
            .save => .back,
            .load => .loaded,
        },
        .main_menu => .main_menu,
        .quit => .quit,
    };
}

/// The menu's state.
pub const InGameOptions = struct {
    /// The item under the pointer (`0x0051D4E4`).
    under: ?Item = null,
    /// QUIT's question, and ABOUT OPENRELIANT's box, while either is up.
    confirm: ?dialog.Confirm = null,
    about: ?About = null,
    /// BACK chosen, which waits for the pointer's button to come up.
    leaving: bool = false,

    /// A pass of the menu's loop: Escape, or BACK once the pointer's button comes up, goes back to
    /// the rooms; SAVE and LOAD lead to the saved games. While QUIT's question or ABOUT
    /// OPENRELIANT's box is up, it takes the pass.
    pub fn frame(menu: *InGameOptions, pointer: Pointer, keyboard: *input.Keyboard) ?Choice {
        const escaped = keyboard.pressed(input.scan.escape, .none, true);
        if (menu.leaving) return if (pointer.down) null else .back;
        if (menu.about) |*about| {
            if (about.frame(pointer, escaped)) menu.about = null;
            return null;
        }
        if (menu.confirm) |*confirm| {
            const answer = confirm.frame(pointer, escaped) orelse return null;
            menu.confirm = null;
            return if (answer) .quit else null;
        }
        if (escaped) return .back;
        menu.under = canvas_module.itemAt(Item, &rects, pointer.at);
        const chosen = menu.under orelse return null;
        if (!pointer.down) return null;
        switch (chosen) {
            .save => return .save,
            .load => return .load,
            .audio => return .{ .settings = .audio },
            .control_devices => return .{ .settings = .controls },
            .video => return .{ .settings = .video },
            .back => menu.leaving = true,
            .main_menu => return .main_menu,
            .quit => menu.confirm = .{ .message = .{ .string = quit_question } },
            .about => menu.about = .{},
        }
        return null;
    }

    /// `in_game_options_draw` (`0x004398B0`), over the menu's background: the buttons and their
    /// labels, the item under the pointer lit, the panels' labels, ABOUT OPENRELIANT's box or
    /// QUIT's question where either is up, OpenReliant's version, then the pointer.
    pub fn draw(menu: InGameOptions, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, about_art: ?*hud.Art, pointer: Pointer) canvas_module.Error!void {
        for (std.enums.values(Item)) |item| {
            const shown = button(item) orelse continue;
            try shown.draw(canvas, art, button_shapes, menu.under == item);
        }
        if (menu.under) |under| if (panel(under)) |lit| try canvas.shape(art, lit.lit_shape, lit.lit_at);
        for (std.enums.values(Item)) |item| {
            const shown = panel(item) orelse continue;
            try shown.label.write(canvas, canvas.fonts.large, canvas_module.blue);
        }
        if (menu.about) |about| if (about_art) |shapes| try about.draw(canvas, shapes);
        if (menu.confirm) |confirm| try confirm.draw(canvas, dialog_art);
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
    }
};

test afterSavedGames {
    try std.testing.expectEqual(null, afterSavedGames(.load, .back));
    try std.testing.expectEqual(End.back, afterSavedGames(.save, .done).?);
    try std.testing.expectEqual(End.loaded, afterSavedGames(.load, .done).?);
    try std.testing.expectEqual(End.main_menu, afterSavedGames(.save, .main_menu).?);
}

test "the items under the pointer" {
    try std.testing.expectEqual(.save, canvas_module.itemAt(Item, &rects, .{ 200, 180 }));
    try std.testing.expectEqual(.video, canvas_module.itemAt(Item, &rects, .{ 500, 300 }));
    try std.testing.expectEqual(.back, canvas_module.itemAt(Item, &rects, .{ 250, 430 }));
    try std.testing.expectEqual(.quit, canvas_module.itemAt(Item, &rects, .{ 350, 450 }));
    try std.testing.expectEqual(null, canvas_module.itemAt(Item, &rects, .{ 10, 10 }));
}

test "ABOUT OPENRELIANT's lines draw closer where they would reach OK" {
    const gpa = std.testing.allocator;
    const fnt = @import("../../../formats/fnt.zig");
    var font: hud.Opened = .open(try fnt.Font.parse(comptime fnt.testing.font(true)), null);
    defer font.deinit(gpa);
    // A few lines stand 14 apart.
    try std.testing.expectEqual(14, About.spacing(&font, "a", "\nb\nc").height);
    // Twelve would reach OK: they share the room from the product ID's line down to OK's label,
    // less a line's height, over their eleven gaps.
    const ours = "a\nb";
    const theirs = "\nc\nd\ne\nf\ng\nh\ni\nj\nk";
    try std.testing.expectEqual(12, About.lines.count(&font, ours) + About.lines.count(&font, theirs));
    const height: i32 = @intCast(font.font.header.height);
    try std.testing.expectEqual(@divTrunc(About.ok_label.at[1] - About.text_at[1] - height, 11), About.spacing(&font, ours, theirs).height);
}

test InGameOptions {
    var keyboard: input.Keyboard = .{};
    var menu: InGameOptions = .{};
    // BACK goes back once the pointer's button comes up.
    try std.testing.expectEqual(null, menu.frame(.{ .at = .{ 250, 430 }, .down = true }, &keyboard));
    try std.testing.expectEqual(null, menu.frame(.{ .at = .{ 250, 430 }, .down = true }, &keyboard));
    try std.testing.expectEqual(.back, menu.frame(.{ .at = .{ 250, 430 } }, &keyboard).?);
    // MAIN MENU at once.
    menu = .{};
    try std.testing.expectEqual(.main_menu, menu.frame(.{ .at = .{ 250, 450 }, .down = true }, &keyboard).?);
    // SAVE leads to the saved games, AUDIO, CONTROL DEVICES and VIDEO to the settings screen.
    menu = .{};
    try std.testing.expectEqual(.save, menu.frame(.{ .at = .{ 200, 180 }, .down = true }, &keyboard).?);
    try std.testing.expectEqual(Choice{ .settings = .controls }, menu.frame(.{ .at = .{ 300, 300 }, .down = true }, &keyboard).?);
    try std.testing.expectEqual(Choice{ .settings = .audio }, menu.frame(.{ .at = .{ 100, 300 }, .down = true }, &keyboard).?);
    try std.testing.expectEqual(Choice{ .settings = .video }, menu.frame(.{ .at = .{ 500, 300 }, .down = true }, &keyboard).?);
    // QUIT asks first; YES quits.
    try std.testing.expectEqual(null, menu.frame(.{ .at = .{ 350, 450 }, .down = true }, &keyboard));
    try std.testing.expect(menu.confirm != null);
    _ = menu.frame(.{ .at = .{ 295, 275 }, .down = true }, &keyboard);
    try std.testing.expectEqual(.quit, menu.frame(.{ .at = .{ 295, 275 } }, &keyboard).?);
    // ABOUT STARLANCER's box closes on OK, once the button comes up, and on Escape.
    menu = .{};
    _ = menu.frame(.{ .at = .{ 350, 430 }, .down = true }, &keyboard);
    try std.testing.expect(menu.about != null);
    _ = menu.frame(.{ .at = .{ 330, 340 }, .down = true }, &keyboard);
    try std.testing.expect(menu.about.?.closing);
    _ = menu.frame(.{ .at = .{ 330, 340 } }, &keyboard);
    try std.testing.expectEqual(null, menu.about);
    menu.about = .{};
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, menu.frame(.{}, &keyboard));
    try std.testing.expectEqual(null, menu.about);
    // Escape goes back.
    keyboard.latched[input.scan.escape] = false;
    try std.testing.expectEqual(.back, menu.frame(.{}, &keyboard).?);
}
