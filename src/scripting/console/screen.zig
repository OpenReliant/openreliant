//! The console's screen ([`console.zig`](../console.zig)), laid out on the front end's screen as
//! OpenReliant's settings screen is, and drawn with the front end's pieces: its title where the
//! settings screen has its tabs, in the large font; the output in a frame, in the small font, with
//! a list's arrows beside it; the line typed in a frame below, with the cursor the saved games'
//! name blinks; and buttons where the settings screen has its own. It's drawn over the menus,
//! darkened, or over the paused mission, which shows through as it does behind the pause menu's
//! settings screen (`Backdrop`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const input = engine.input;
const hud = engine.game.hud;
const bigfile = engine.game.bigfile;
const language = engine.game.language;
const winmain = engine.game.winmain;
const interface = engine.game.interface;
const saved_games = interface.saved_games;
const hudoptions = engine.game.hudoptions;
const settings = interface.settings;
const widgets = settings.widgets;
const canvas_module = interface.canvas;
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Arrow = canvas_module.Arrow;
const console_module = @import("../console.zig");
const Console = console_module.Console;
const Tone = console_module.Tone;

/// The title, centred on the settings screen's row of tabs, in the large font, white as the tab
/// shown is.
const title = "SCRIPT CONSOLE";
const title_at: [2]i32 = .{ 320, settings.title_y };

/// The output's frame, from x 45 as the settings screen's panes are, its arrows right of its top,
/// and its rows inside it, in the small font.
const output_frame: widgets.Frame = .{ .at = .{ 45, 125 }, .extent = .{ 520, 260 } };
const arrows: widgets.ListArrows = .{ .at = .{ 570, 125 } };
const rows_at: [2]i32 = .{ 51, 128 };
const row_height = 14;
pub const shown_rows = 18;
/// How wide a row is, a margin short of the frame's sides.
const row_width = 508;

/// The line typed: its frame below the output's, and its text inside it, after the prompt.
const typed_frame: widgets.Frame = .{ .at = .{ 45, 392 }, .extent = .{ 520, 20 } };
const typed_at: [2]i32 = .{ 51, 394 };
/// The space between the prompt and the line.
const prompt_gap = 4;

/// What the console stands over.
pub const Backdrop = enum {
    /// The front end's screens, drawn dark enough that their labels don't show through.
    menus,
    /// The paused mission, which shows through as it does behind the pause menu's settings
    /// screen (`hudoptions.shade`).
    mission,

    fn shade(backdrop: Backdrop) [4]f32 {
        return switch (backdrop) {
            .menus => .{ 0, 0, 0, 0.92 },
            .mission => hudoptions.shade,
        };
    }
};

/// The buttons, each in the place of one of the settings screen's.
pub const Button = enum {
    run,
    close,
    clear,
    reload,

    fn place(button: Button) settings.Button {
        return switch (button) {
            .run => .ok,
            .close => .leave,
            .clear => .reset_defaults,
            .reload => .cancel_changes,
        };
    }

    fn label(button: Button) []const u8 {
        return switch (button) {
            .run => "RUN",
            .close => "CLOSE",
            .clear => "CLEAR",
            .reload => "RELOAD",
        };
    }

    fn shown(button: Button) canvas_module.Button {
        return button.place().labelled(.{ .words = button.label() });
    }
};

/// What the pointer finds on the screen.
pub const Item = union(enum) {
    arrow: Arrow,
    button: Button,
};

/// What the screen keeps from one pass to the next.
pub const View = struct {
    /// How many rows the output is scrolled back from its end.
    back: usize = 0,
    /// The rows the output took as it was last drawn, which scrolling stays within.
    rows: usize = 0,
    /// What's under the pointer, which is drawn lit.
    under: ?Item = null,
    /// Whether the cursor shows, and the tick it next turns on or off at.
    cursor_shown: bool = true,
    blink_at: u32 = 0,
    /// The tick a held arrow next scrolls the output at (`widgets.List.scroll_ticks`).
    scroll_at: u32 = 0,
    /// The pointer's button, which counts once the press that brought the console up has come
    /// up, and whether it was down last pass.
    press: input.FreshPress = .{},
    was_down: bool = false,

    /// Scrolls the output `rows` back, or on where `rows` is negative, within what it holds.
    fn scroll(view: *View, rows: isize) void {
        const most = view.rows -| shown_rows;
        view.back = @intCast(std.math.clamp(@as(isize, @intCast(view.back)) + rows, 0, @as(isize, @intCast(most))));
    }
};

/// What a pass of the screen reads.
pub const Frame = struct {
    keyboard: *input.Keyboard,
    /// The characters typed, in the game's code page.
    typed: *winmain.Typed,
    pointer: Pointer,
    /// The game's ticks, which the cursor blinks and a held arrow scrolls by.
    ticks: u32,
};

/// What a pass leads to.
pub const Action = enum { close, run, reload };

/// A pass of the screen: the characters typed go into the line; Enter or RUN runs it; Up and Down
/// bring back the lines typed before; Page Up, Page Down, the wheel and the arrows scroll the
/// output; CLEAR empties it; RELOAD reloads the scripts; Escape, F11 or CLOSE takes the console
/// away.
pub fn frame(console: *Console, context: Frame) ?Action {
    const view = &console.view;
    const keyboard = context.keyboard;
    while (context.typed.count > 0) hud.typeInto(context.typed, &console.typed.bytes, &console.typed.len, null);
    if (context.ticks > view.blink_at) {
        view.blink_at = context.ticks + saved_games.blink_ticks;
        view.cursor_shown = !view.cursor_shown;
    }
    if (pressed(keyboard, .escape) or pressed(keyboard, console_module.key)) return .close;
    if (pressed(keyboard, .enter) or pressed(keyboard, .keypad_enter)) return .run;
    if (pressed(keyboard, .up)) console.recall(.back);
    if (pressed(keyboard, .down)) console.recall(.on);
    if (pressed(keyboard, .page_up)) view.scroll(shown_rows - 1);
    if (pressed(keyboard, .page_down)) view.scroll(-(shown_rows - 1));

    const pointer = context.pointer;
    view.scroll(pointer.wheel * canvas_module.notch_rows);
    view.under = itemAt(pointer.at);
    const fresh = view.press.pressed(pointer.down);
    const clicked = fresh and !view.was_down;
    view.was_down = pointer.down;
    const under = view.under orelse return null;
    switch (under) {
        .arrow => |way| if (fresh and context.ticks > view.scroll_at) {
            view.scroll(if (way == .up) 1 else -1);
            view.scroll_at = context.ticks + widgets.List.scroll_ticks;
        },
        .button => |button| if (clicked) return switch (button) {
            .run => .run,
            .close => .close,
            .reload => .reload,
            .clear => clear: {
                console_module.output.clear();
                view.back = 0;
                break :clear null;
            },
        },
    }
    return null;
}

fn pressed(keyboard: *input.Keyboard, key: input.Key) bool {
    return keyboard.pressed(@intFromEnum(key), .none, true);
}

/// What the pointer finds at `at`.
fn itemAt(at: [2]i32) ?Item {
    if (arrows.itemAt(at)) |way| return .{ .arrow = way };
    for (std.enums.values(Button)) |button| {
        if (button.place().rect().holds(at)) return .{ .button = button };
    }
    return null;
}

/// The colour a line of `tone` is written in: the front end's blue, a typed line white, a
/// warning gold and an error red.
fn colourOf(tone: Tone) [3]f32 {
    return switch (tone) {
        .info => canvas_module.blue,
        .typed => canvas_module.white,
        .warning => canvas_module.gold,
        .failure => canvas_module.red,
    };
}

/// Draws the screen over `backdrop`, darkened, and the pointer at `pointer` with `art`, the
/// settings screen's shapes.
pub fn draw(console: *Console, canvas: Canvas, art: *hud.Art, pointer: Pointer, backdrop: Backdrop) canvas_module.Error!void {
    const window: [2]f32 = .{ @floatFromInt(canvas.window[0]), @floatFromInt(canvas.window[1]) };
    hud.drawFilled(canvas.target, .{ .left = 0, .top = 0, .right = window[0], .bottom = window[1] }, backdrop.shade());
    const view = &console.view;
    try canvas.text(canvas.fonts.large, title_at, title, canvas_module.white, .centre);
    output_frame.draw(canvas);
    try arrows.draw(canvas, art, if (view.under) |under| switch (under) {
        .arrow => |way| way,
        .button => null,
    } else null);
    try drawOutput(view, canvas);

    typed_frame.draw(canvas);
    const small = canvas.fonts.small;
    var prompt_buffer: [console_module.prompt_room]u8 = undefined;
    var encoded: [console_module.prompt_room]u8 = undefined;
    const prompt = language.encode(&encoded, console.prompt(&prompt_buffer));
    try canvas.text(small, typed_at, prompt, canvas_module.blue, .left);
    const prompt_width: i32 = @intCast(small.textWidth(prompt));
    // The end of the line shows where it's wider than the frame.
    const room = typed_frame.extent[0] - (typed_at[0] - typed_frame.at[0]) * 2 - prompt_width - prompt_gap;
    const line = console.typed.slice();
    var from: usize = 0;
    while (from < line.len and @as(i32, @intCast(small.textWidth(line[from..]) + small.textWidth(saved_games.cursor))) > room) from += 1;
    const line_at: [2]i32 = .{ typed_at[0] + prompt_width + prompt_gap, typed_at[1] };
    try canvas.text(small, line_at, line[from..], canvas_module.white, .left);
    if (view.cursor_shown) try canvas.text(small, .{ line_at[0] + @as(i32, @intCast(small.textWidth(line[from..]))), line_at[1] }, saved_games.cursor, canvas_module.white, .left);

    for (std.enums.values(Button)) |button| {
        const lit = if (view.under) |under| std.meta.eql(under, Item{ .button = button }) else false;
        try button.shown().draw(canvas, art, settings.button_shapes, lit);
    }
    try canvas.drawVersion();
    try canvas.shape(art, pointer.shape(), pointer.at);
}

/// Draws the rows of the output that show, scrolled `view.back` rows from its end: each line broken
/// into rows as wide as the frame, an empty line a row of its own.
fn drawOutput(view: *View, canvas: Canvas) Allocator.Error!void {
    const small = canvas.fonts.small;
    const output = &console_module.output;
    output.acquire();
    defer output.lock.unlock();
    var rows: usize = 0;
    for (0..output.count) |at| rows += rowsOf(small, output.lineAt(at));
    view.rows = rows;
    view.back = @min(view.back, rows -| shown_rows);
    const last = rows - view.back;
    const first = last -| shown_rows;
    var row: usize = 0;
    for (0..output.count) |at| {
        const line = output.lineAt(at);
        var encoded: [console_module.max_line]u8 = undefined;
        var wrapping: hud.WrappedText = .init(&small.widths, language.encode(&encoded, line.text()), row_width, std.math.maxInt(usize));
        var any = false;
        while (wrapping.next()) |shown| : (row += 1) {
            any = true;
            if (row >= first and row < last) try canvas.text(small, .{ rows_at[0], rows_at[1] + @as(i32, @intCast(row - first)) * row_height }, shown, colourOf(line.tone), .left);
        }
        if (!any) row += 1;
        if (row >= last) break;
    }
}

/// How many rows `line` takes in `font`.
fn rowsOf(font: *const hud.Opened, line: *const console_module.Line) usize {
    var encoded: [console_module.max_line]u8 = undefined;
    var wrapping: hud.Wrapping = .init(&font.widths, language.encode(&encoded, line.text()), row_width);
    var rows: usize = 0;
    while (wrapping.next()) |_| rows += 1;
    return @max(rows, 1);
}

/// The fonts and shapes the screen draws with, which the console opens the first time it comes up:
/// the front end's fonts, as the pause menu opens them, and the settings screen's shapes.
pub const Resources = struct {
    gpa: Allocator,
    small: hud.FontFile,
    large: hud.FontFile,
    shapes: canvas_module.Shapes,

    pub fn open(gpa: Allocator, archive: *const bigfile.Hog, outlines: ?*hud.outline.Outlines) !Resources {
        var small: hud.FontFile = try .open(gpa, archive.*, hud.small_menu_font, outlines);
        errdefer small.deinit(gpa);
        var large: hud.FontFile = try .open(gpa, archive.*, hud.large_menu_font, outlines);
        errdefer large.deinit(gpa);
        const shapes = canvas_module.Shapes.read(gpa, archive, settings.shapes_name) orelse return error.MissingShapes;
        return .{ .gpa = gpa, .small = small, .large = large, .shapes = shapes };
    }

    pub fn close(resources: *Resources) void {
        resources.small.deinit(resources.gpa);
        resources.large.deinit(resources.gpa);
        resources.shapes.deinit(resources.gpa);
    }

    pub fn fonts(resources: *Resources) canvas_module.Fonts {
        return .{ .large = &resources.large.font, .small = &resources.small.font };
    }
};

test itemAt {
    try std.testing.expectEqual(Item{ .arrow = .up }, itemAt(.{ 575, 130 }).?);
    try std.testing.expectEqual(Item{ .button = .close }, itemAt(.{ 250, 446 }).?);
    try std.testing.expectEqual(null, itemAt(.{ 100, 200 }));
}

test "View.scroll" {
    var view: View = .{ .rows = shown_rows + 5 };
    view.scroll(3);
    try std.testing.expectEqual(3, view.back);
    view.scroll(10);
    try std.testing.expectEqual(5, view.back);
    view.scroll(-20);
    try std.testing.expectEqual(0, view.back);
}
