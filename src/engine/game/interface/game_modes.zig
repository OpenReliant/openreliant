//! OpenReliant's game modes screen (`GameModes`), which the main menu's GAME MODES button opens: the
//! game modes the mods' scripts register (`scripting.game_modes`,
//! [#560](https://github.com/OpenReliant/openreliant/issues/560)). Each runs its missions in turn,
//! with the mod's rules, and comes back to the main menu.
//!
//! It is laid out as the mods screen is (`mod_manager`): the list of the modes in its frame, with the
//! lists' arrows, the chosen mode in the frame beside it, and two of the settings screen's buttons:
//! PLAY, where OK stands, and MAIN MENU.
//!
//! **Improvement:** the original has no game modes but its campaign, INSTANT ACTION and
//! multiplayer.

const std = @import("std");

const input = @import("../../input.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const Arrow = canvas_module.Arrow;
const settings = @import("settings.zig");
const widgets = settings.widgets;
const mod_manager = @import("mod_manager.zig");

/// The movie that leads into the screen from the main menu and the background it shows: the
/// mods screen's.
pub const opening = mod_manager.opening;

/// The most modes the list holds; a screen counts its rows in a byte, as the game's lists do.
pub const capacity = std.math.maxInt(u8);

/// A game mode, as the screen shows it.
pub const Mode = struct {
    /// What the list calls it, and what the panel says of it.
    label: []const u8,
    description: []const u8 = "",
    /// The name of the mod that registered it, how many missions it flies, and whether it flies
    /// them again and again.
    mod: []const u8,
    missions: usize,
    loop: bool = false,
};

/// The title, in the place of the settings screen's tabs.
const title: Label = .{ .text = .{ .words = "GAME MODES" }, .at = .{ 320, settings.title_y }, .alignment = .centre };

/// What the panel says when no mode is chosen, and what the list says when there are none.
const choose_note: Label = .{ .text = .{ .words = "CHOOSE A GAME MODE" }, .at = mod_manager.details_middle, .alignment = .centre };
const empty_note: Label = .{ .text = .{ .words = "NO GAME MODES" }, .at = mod_manager.list_middle, .alignment = .centre };

/// The buttons, which are the settings screen's, PLAY standing where its OK does.
pub const Button = enum {
    play,
    leave,

    fn settingsButton(button: Button) settings.Button {
        return switch (button) {
            .play => .ok,
            .leave => .leave,
        };
    }

    fn rect(button: Button) Rect {
        return button.settingsButton().rect();
    }

    fn shown(button: Button) canvas_module.Button {
        return switch (button) {
            .play => button.settingsButton().labelled(.{ .words = "PLAY" }),
            .leave => button.settingsButton().shown(.game_options),
        };
    }
};

/// What the pointer finds on the screen.
pub const Item = union(enum) {
    button: Button,
    scroll: Arrow,
    /// A row's name, which chooses it, by the row's place in the list.
    choose: u8,
};

/// What a pass of the screen reads.
pub const Context = struct {
    pointer: Pointer,
    keyboard: *input.Keyboard,
    /// The timer's ticks (`game_ticks`), which a held arrow scrolls the list by.
    ticks: u32,
    modes: []const Mode,
};

/// How the screen ends.
pub const Leave = union(enum) {
    /// MAIN MENU or Escape.
    main_menu,
    /// PLAY: the mode of this place in the list.
    play: u8,
};

/// The screen's state.
pub const GameModes = struct {
    /// The modes, which live as long as OpenReliant runs, and how many of them the list shows.
    modes: []const Mode = &.{},
    count: u8 = 0,
    /// The row chosen, which the panel shows and PLAY plays.
    chosen: ?u8 = null,
    list: widgets.List = .of(0, mod_manager.shown_rows, 0),
    /// The item under the pointer, lit while its button is up.
    lit: ?Item = null,
    /// Whether the press that chose an item is still down, which chooses nothing more until it
    /// comes up.
    held: bool = false,

    /// Opens the screen, the first mode chosen.
    pub fn enter(screen: *GameModes, context: Context) void {
        screen.* = .{ .modes = context.modes, .count = @intCast(@min(context.modes.len, capacity)) };
        screen.list = .of(screen.count, mod_manager.shown_rows, context.ticks);
        if (screen.count > 0) screen.chosen = 0;
    }

    /// A pass of the screen's loop: how it ends, once it does. Escape leaves for the main menu, as
    /// MAIN MENU does. The wheel and the keys scroll the list, then the item under the pointer is
    /// chosen as the pointer's button goes down, and lit while it is up.
    pub fn frame(screen: *GameModes, context: Context) ?Leave {
        if (context.keyboard.pressed(input.scan.escape, .none, true)) return .main_menu;
        var pointer = context.pointer;
        if (pointer.down and screen.held) pointer.down = false else screen.held = false;
        screen.lit = null;
        screen.list.scrollBy(pointer.wheel, context.keyboard, context.ticks);
        const under = screen.itemAt(pointer.at) orelse return null;
        if (!pointer.down) {
            screen.lit = under;
            return null;
        }
        screen.held = true;
        switch (under) {
            .button => |button| switch (button) {
                .play => if (screen.chosen) |row| return .{ .play = row },
                .leave => return .main_menu,
            },
            .scroll => |way| {
                screen.list.scrollHeld(way, context.ticks);
                screen.held = false;
            },
            .choose => |row| screen.chosen = row,
        }
        return null;
    }

    /// What the pointer finds at `at`: the buttons, then the list's arrows, then the rows shown.
    pub fn itemAt(screen: GameModes, at: [2]i32) ?Item {
        for (std.enums.values(Button)) |button| if (button.rect().holds(at)) return .{ .button = button };
        if (mod_manager.arrows.itemAt(at)) |arrow| return .{ .scroll = arrow };
        for (screen.list.rows.first..screen.list.rows.end(), 0..) |row, place| {
            if (nameRect(place).holds(at)) return .{ .choose = @intCast(row) };
        }
        return null;
    }

    /// The screen's drawing, over the background: the title, the list and the panel, the buttons,
    /// the one under the pointer lit, OpenReliant's version, then the pointer.
    pub fn draw(screen: GameModes, canvas: Canvas, art: *hud.Art, pointer: Pointer) canvas_module.Error!void {
        const modes = screen.modes;
        try title.write(canvas, canvas.fonts.large, canvas_module.white);
        mod_manager.list_frame.draw(canvas);
        mod_manager.details_frame.draw(canvas);
        try screen.drawList(canvas, art, modes);
        try screen.drawDetails(canvas, modes);
        for (std.enums.values(Button)) |button| {
            const shown = button.shown();
            const playable = button != .play or screen.chosen != null;
            try shown.draw(canvas.dimmedUnless(playable), art, settings.button_shapes, std.meta.eql(screen.lit, Item{ .button = button }));
        }
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
    }

    /// The rows shown, each a mode's label, the chosen one white, and the arrows, the one under the
    /// pointer lit.
    fn drawList(screen: GameModes, canvas: Canvas, art: *hud.Art, modes: []const Mode) canvas_module.Error!void {
        if (screen.count == 0) try empty_note.write(canvas, canvas.fonts.small, canvas_module.blue);
        for (screen.list.rows.first..screen.list.rows.end(), 0..) |at, place| {
            const is_chosen = if (screen.chosen) |chosen| chosen == at else false;
            const colour = if (is_chosen) canvas_module.white else canvas_module.blue;
            const rect = nameRect(place);
            try canvas.wrapped(canvas.fonts.small, .{ rect.x + name_inside, rect.y }, modes[at].label, colour, .left, .{ .width = name_width, .height = mod_manager.row_spacing, .most = 1 });
        }
        const lit_arrow: ?Arrow = if (screen.lit) |lit| switch (lit) {
            .scroll => |arrow| arrow,
            .button, .choose => null,
        } else null;
        try mod_manager.arrows.draw(canvas, art, lit_arrow);
    }

    /// The chosen mode: its label, the mod it comes from, how many missions it runs, and what it
    /// says of itself.
    fn drawDetails(screen: GameModes, canvas: Canvas, modes: []const Mode) canvas_module.Error!void {
        const mode = modes[screen.chosen orelse return choose_note.write(canvas, canvas.fonts.small, canvas_module.blue)];
        const font = canvas.fonts.small;
        const lines = mod_manager.details_lines;
        const x = mod_manager.details_frame.at[0] + mod_manager.details_inside;
        var y = mod_manager.details_frame.at[1] + mod_manager.details_inside;
        var buffer: [mod_manager.name_buffer]u8 = undefined;
        try canvas.wrapped(font, .{ x, y }, mode.label, canvas_module.white, .left, lines);
        y += lines.height;
        const from = std.fmt.bufPrint(&buffer, "FROM {s}", .{mode.mod}) catch mode.mod;
        try canvas.wrapped(font, .{ x, y }, from, canvas_module.blue, .left, lines);
        y += lines.height;
        const missions = std.fmt.bufPrint(&buffer, "{d} MISSION{s}{s}", .{ mode.missions, if (mode.missions == 1) "" else "S", if (mode.loop) ", AGAIN AND AGAIN" else "" }) catch "";
        try canvas.wrapped(font, .{ x, y }, missions, canvas_module.blue, .left, lines);
        y += lines.height;
        if (mode.description.len > 0) try canvas.wrapped(font, .{ x, y }, mode.description, canvas_module.blue, .left, mod_manager.description_lines);
    }
};

/// How far right of the list's left edge a row's name starts, and how wide it can be before the
/// list's arrows: where the mods screen's names start, past their check boxes.
const name_x = mod_manager.box_x;
const name_inside = 2;
const name_width = mod_manager.list_frame.at[0] + mod_manager.list_frame.extent[0] - name_x - 8;

/// Where the pointer finds the name of the row shown `place`th from the top.
fn nameRect(place: usize) Rect {
    return .{
        .x = name_x - name_inside,
        .y = @intCast(mod_manager.first_row + @as(i32, @intCast(place)) * mod_manager.row_spacing),
        .width = name_width + 2 * name_inside,
        .height = widgets.Box.size,
    };
}

test "a mode is chosen, played, and the screen left" {
    var keyboard: input.Keyboard = .{};
    const modes = [_]Mode{
        .{ .label = "ARENA", .mod = "arena", .missions = 1 },
        .{ .label = "GAUNTLET", .mod = "arena", .missions = 3 },
    };
    var screen: GameModes = .{};
    const context: Context = .{ .pointer = .{}, .keyboard = &keyboard, .ticks = 0, .modes = &modes };
    screen.enter(context);
    try std.testing.expectEqual(0, screen.chosen.?);
    // The second row chosen, then PLAY.
    const second = nameRect(1);
    var pressed = context;
    pressed.pointer = .{ .at = .{ second.x + 4, second.y + 2 }, .down = true };
    try std.testing.expectEqual(null, screen.frame(pressed));
    try std.testing.expectEqual(1, screen.chosen.?);
    pressed.pointer = .{ .at = .{ 250, 428 } };
    _ = screen.frame(pressed);
    pressed.pointer.down = true;
    try std.testing.expectEqual(Leave{ .play = 1 }, screen.frame(pressed).?);
    // Escape leaves for the main menu.
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(Leave.main_menu, screen.frame(context).?);
}

test "with no modes, PLAY plays nothing" {
    var keyboard: input.Keyboard = .{};
    var screen: GameModes = .{};
    const context: Context = .{ .pointer = .{ .at = .{ 250, 428 }, .down = true }, .keyboard = &keyboard, .ticks = 0, .modes = &.{} };
    screen.enter(context);
    try std.testing.expectEqual(null, screen.chosen);
    try std.testing.expectEqual(null, screen.frame(context));
}
