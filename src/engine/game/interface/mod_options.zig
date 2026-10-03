//! The options a mod's scripts offer ([#597](https://github.com/OpenReliant/openreliant/issues/597)),
//! and the screen that sets them (`ModOptions`), which the mods screen's OPTIONS button opens.
//!
//! A mod declares a page of options (`Page`) as OpenReliant starts: each option is a toggle, a choice
//! among values or a number in a range, with a label and a default (`Option`). The scripting
//! (`src/scripting/settings.zig`) keeps the pages and the values; the screen reaches them through
//! `Pages`. The screen is laid out as the video tab's graphics list is (`settings/graphics.zig`):
//! a title, a framed list of rows with a check box or an arrows box and a value, the list's
//! arrows, and the settings screen's buttons: OK and MAIN MENU, RESET DEFAULTS and CANCEL CHANGES.
//! A change is kept at once. The text of the option under the pointer is written under the list.
//!
//! **Improvement:** the original can't load mods.
//!
//! Not ported: changing the options from the pause menu in a game
//! ([#600](https://github.com/OpenReliant/openreliant/issues/600)), and more kinds of option and
//! groups ([#601](https://github.com/OpenReliant/openreliant/issues/601)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Label = canvas_module.Label;
const settings = @import("settings.zig");
const widgets = settings.widgets;
const Line = widgets.Line;
const Pane = widgets.Pane;
const Step = widgets.Step;

/// The most options a page has, and the most choices an option has.
pub const max_options = 64;
pub const max_choices = 32;

/// The value of an option: a toggle's boolean, a number, or the text of a choice. Scripts give and
/// read it as a boolean, a number or a string.
pub const Value = union(enum) {
    boolean: bool,
    number: f64,
    text: []const u8,

    pub fn eql(first: Value, second: Value) bool {
        return switch (first) {
            .boolean => |a| second == .boolean and second.boolean == a,
            .number => |a| second == .number and second.number == a,
            .text => |a| second == .text and std.mem.eql(u8, second.text, a),
        };
    }
};

/// How an option is set.
pub const Kind = enum {
    pub const script_name = "OptionKind";

    /// On or off: a check box.
    toggle,
    /// One of a list of values, each with a label of its own.
    choice,
    /// A number from `min` to `max`, a `step` at a time.
    number,
};

/// A value of a choice, and the words that stand for it.
pub const Choice = struct {
    value: Value,
    label: []const u8,
};

/// One option of a page.
pub const Option = struct {
    /// What scripts read it by.
    key: []const u8,
    /// The words beside it on the screen.
    label: []const u8,
    /// A line about it, written under the list while the pointer is on it; empty for none.
    description: []const u8,
    default: Value,
    control: Control,

    pub const Control = union(Kind) {
        toggle,
        choice: []const Choice,
        number: Range,
    };

    pub const Range = struct { min: f64, max: f64, step: f64 };

    /// What is wrong with the option as declared, if anything.
    pub fn problem(option: Option) ?[]const u8 {
        if (option.key.len == 0) return "an option needs a key";
        if (option.label.len == 0) return "an option needs a label";
        switch (option.control) {
            .toggle => if (option.default != .boolean) return "a toggle's default must be a boolean",
            .choice => |choices| {
                if (choices.len == 0) return "a choice needs choices";
                if (choices.len > max_choices) return "a choice has too many choices";
                for (choices, 0..) |choice, at| {
                    if (choice.value == .boolean) return "a choice's values are numbers or strings";
                    if (choice.label.len == 0) return "a choice needs a label";
                    if (std.meta.activeTag(choices[0].value) != std.meta.activeTag(choice.value)) return "a choice's values must all be numbers, or all strings";
                    for (choices[0..at]) |before| if (before.value.eql(choice.value)) return "a choice's values must differ";
                }
                if (option.indexOf(option.default) == null) return "a choice's default must be one of its values";
            },
            .number => |range| {
                if (option.default != .number) return "a number's default must be a number";
                if (!std.math.isFinite(range.min) or !std.math.isFinite(range.max) or !std.math.isFinite(range.step)) return "a number's range must be finite";
                if (range.min >= range.max) return "a number's min must be below its max";
                if (range.step <= 0) return "a number's step must be above 0";
                if (option.default.number < range.min or option.default.number > range.max) return "a number's default must be within its range";
            },
        }
        return null;
    }

    /// Where `value` stands among a choice's values; null for none, and for another kind of option.
    fn indexOf(option: Option, value: Value) ?usize {
        const choices = switch (option.control) {
            .choice => |listed| listed,
            .toggle, .number => return null,
        };
        for (choices, 0..) |choice, at| if (choice.value.eql(value)) return at;
        return null;
    }

    /// `value` if it suits the option, else the default. A choice gives its own copy of the value,
    /// so that it lasts as long as the option; a number is brought into its range.
    pub fn fit(option: Option, value: Value) Value {
        switch (option.control) {
            .toggle => return if (value == .boolean) value else option.default,
            .choice => |choices| return if (option.indexOf(value)) |at| choices[at].value else option.default,
            .number => |range| return if (value == .number and std.math.isFinite(value.number)) .{ .number = std.math.clamp(value.number, range.min, range.max) } else option.default,
        }
    }

    /// The value an arrow takes `current` to: the next or the last choice, round from one end to the
    /// other, or a step more or less in the range, as far as it goes.
    pub fn stepped(option: Option, current: Value, step: Step) Value {
        switch (option.control) {
            .toggle => return .{ .boolean = !(current == .boolean and current.boolean) },
            .choice => |choices| return choices[widgets.steppedIndex(option.indexOf(current), choices.len, step)].value,
            .number => |range| {
                const now = if (current == .number) current.number else range.min;
                const moved = switch (step) {
                    .on => now + range.step,
                    .back => now - range.step,
                };
                return .{ .number = tidy(std.math.clamp(moved, range.min, range.max)) };
            },
        }
    }

    /// The words that show `value`: a choice's label, or a number written out. Empty for a toggle,
    /// whose check box shows it.
    pub fn words(option: Option, value: Value, buffer: *[number_words]u8) []const u8 {
        switch (option.control) {
            .toggle => return "",
            .choice => return if (option.indexOf(value)) |at| option.control.choice[at].label else "",
            .number => return if (value == .number) std.fmt.bufPrint(buffer, "{d}", .{value.number}) catch "" else "",
        }
    }
};

/// How many bytes a number written out for the screen takes at most.
pub const number_words = 32;

/// A number with the rounding of repeated steps taken off, such as 0.30000000000000004.
fn tidy(number: f64) f64 {
    const places = 1e6;
    return @round(number * places) / places;
}

/// A mod's options.
pub const Page = struct {
    title: []const u8,
    options: []const Option,
};

/// The pages and values the scripting keeps, which the screen reaches. A mod is named as its folder
/// or archive is in the `mods` folder.
pub const Pages = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The mod's page; null where it has none.
        page: *const fn (context: *anyopaque, mod: []const u8) ?Page,
        /// The value of the option `key` of the mod: the one kept if it suits the option, else the
        /// default; null for a key the mod's page doesn't have.
        get: *const fn (context: *anyopaque, mod: []const u8, key: []const u8) ?Value,
        /// Keeps `value` as the option's, and tells the mod's scripts.
        set: *const fn (context: *anyopaque, mod: []const u8, key: []const u8, value: Value) void,
    };

    pub fn page(pages: Pages, mod: []const u8) ?Page {
        return pages.vtable.page(pages.context, mod);
    }

    pub fn get(pages: Pages, mod: []const u8, key: []const u8) ?Value {
        return pages.vtable.get(pages.context, mod, key);
    }

    pub fn set(pages: Pages, mod: []const u8, key: []const u8, value: Value) void {
        pages.vtable.set(pages.context, mod, key, value);
    }
};

/// The title, in the place of the settings screen's tabs.
const title_at: [2]i32 = .{ 320, settings.title_y };

/// Where the rows end their labels, 20 right of the game's as the video tab's do.
const edge = Line.original_edge + 20;
const row_spacing = Line.arrows_height + inside;
const inside = 4;
const frame_line = 2;
const top = 136;

/// The rows the list shows at once.
const shown_rows = 8;

/// The list for a page of `options`, as the video tab's graphics list is laid out
/// (`settings/graphics.zig`), with a frame as tall as the rows it shows, up to `shown_rows`.
fn paneOf(options: usize) Pane {
    const rows: i32 = @intCast(@min(@max(options, 1), shown_rows));
    const rows_height = (rows - 1) * row_spacing + Line.arrows_height;
    return .{
        .frame = .{ .at = .{ 45, top }, .extent = .{ 520, 2 * frame_line + 2 * inside + rows_height - 1 } },
        .arrows = .{ .at = .{ 570, top } },
        .first = top + frame_line + inside + 1,
        .spacing = row_spacing,
        .edge = edge,
    };
}

/// Where the text of the option under the pointer stands, under a list: its middle, a gap below it.
const description_gap = 10;
fn descriptionAt(pane: Pane) [2]i32 {
    return .{ 320, pane.frame.at[1] + pane.frame.extent[1] + description_gap };
}
const description_lines: Canvas.Lines = .{ .width = 520, .height = 15, .most = 2 };

/// What the pointer finds.
pub const Item = union(enum) {
    button: settings.Button,
    pane: Pane.Item,
};

/// What a pass of the screen reads, and changes.
pub const Context = struct {
    pointer: Pointer,
    keyboard: *input.Keyboard,
    /// The timer's ticks (`game_ticks`), which a held arrow scrolls the list by.
    ticks: u32,
    pages: Pages,
};

/// The screen's state.
pub const ModOptions = struct {
    /// The mod whose page it shows, and the page.
    mod: []const u8 = "",
    page: Page = .{ .title = "", .options = &.{} },
    /// The list, as tall as the page needs.
    pane: Pane = paneOf(0),
    /// The values now, and as the screen opened, which CANCEL CHANGES puts back.
    values: [max_options]Value = undefined,
    kept: [max_options]Value = undefined,
    list: widgets.List = .of(0, shown_rows, 0),
    /// The item under the pointer, lit while its button is up.
    lit: ?Item = null,
    /// Whether the press that chose an item is still down.
    held: bool = false,

    /// Opens the page of `mod`; false where it has none.
    pub fn enter(screen: *ModOptions, mod: []const u8, context: Context) bool {
        const page = context.pages.page(mod) orelse return false;
        screen.* = .{ .mod = mod, .page = page, .pane = paneOf(page.options.len), .list = .of(@intCast(page.options.len), shown_rows, context.ticks) };
        for (page.options, 0..) |option, at| {
            screen.values[at] = context.pages.get(mod, option.key) orelse option.default;
        }
        screen.kept = screen.values;
        return true;
    }

    /// A pass of the screen's loop: how it ends, once it does.
    pub fn frame(screen: *ModOptions, context: Context) ?settings.End {
        if (context.keyboard.pressed(input.scan.escape, .none, true)) return .back;
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
                .ok => return .back,
                .leave => return .main_menu,
                .reset_defaults => for (screen.page.options, 0..) |option, at| screen.change(at, option.default, context),
                .cancel_changes => for (screen.kept[0..screen.page.options.len], 0..) |value, at| screen.change(at, value, context),
            },
            .pane => |on_pane| switch (on_pane) {
                .scroll => |way| {
                    screen.list.scrollHeld(way, context.ticks);
                    screen.held = false;
                },
                .check => |row| screen.change(row, screen.page.options[row].stepped(screen.values[row], .on), context),
                .step => |stepped| screen.change(stepped.row, screen.page.options[stepped.row].stepped(screen.values[stepped.row], stepped.step), context),
            },
        }
        return null;
    }

    /// Makes row `at` hold `value`, and tells the pages where that is a change.
    fn change(screen: *ModOptions, at: usize, value: Value, context: Context) void {
        if (screen.values[at].eql(value)) return;
        screen.values[at] = value;
        context.pages.set(screen.mod, screen.page.options[at].key, value);
    }

    /// What the pointer finds at `at`: the buttons, then the list's items.
    pub fn itemAt(screen: ModOptions, at: [2]i32) ?Item {
        for (std.enums.values(settings.Button)) |button| if (button.rect().holds(at)) return .{ .button = button };
        var buffer: [max_options]Line.Shown = undefined;
        var numbers: [max_options][number_words]u8 = undefined;
        const shown = screen.shownRows(&buffer, &numbers);
        return .{ .pane = screen.pane.itemAt(screen.list, shown, at) orelse return null };
    }

    /// What each row shows: its label, and its check box or its value.
    fn shownRows(screen: ModOptions, buffer: *[max_options]Line.Shown, numbers: *[max_options][number_words]u8) []const Line.Shown {
        const count = screen.page.options.len;
        for (screen.page.options, screen.values[0..count], buffer[0..count], numbers[0..count]) |option, value, *shown, *text| {
            shown.* = .{
                .label = .{ .words = option.label },
                .control = switch (option.control) {
                    .toggle => .{ .check = value == .boolean and value.boolean },
                    .choice, .number => .{ .choice = .{ .words = option.words(value, text) } },
                },
            };
        }
        return buffer[0..count];
    }

    /// The screen's drawing, over the background: the title, the list, the buttons, the one under the
    /// pointer lit, the text of the option under it, OpenReliant's version, then the pointer.
    pub fn draw(screen: ModOptions, canvas: Canvas, art: *hud.Art, pointer: Pointer) canvas_module.Error!void {
        try (Label{ .text = .{ .words = screen.page.title }, .at = title_at, .alignment = .centre }).write(canvas, canvas.fonts.large, canvas_module.white);
        var buffer: [max_options]Line.Shown = undefined;
        var numbers: [max_options][number_words]u8 = undefined;
        const shown = screen.shownRows(&buffer, &numbers);
        const lit_pane: ?Pane.Item = if (screen.lit) |item| switch (item) {
            .pane => |on_pane| on_pane,
            .button => null,
        } else null;
        try screen.pane.draw(canvas, art, screen.list, shown, lit_pane);
        for (std.enums.values(settings.Button)) |button| {
            try button.shown(.game_options).draw(canvas, art, settings.button_shapes, std.meta.eql(screen.lit, Item{ .button = button }));
        }
        if (lit_pane) |item| if (rowOf(item)) |row| {
            const description = screen.page.options[row].description;
            try canvas.wrapped(canvas.fonts.small, descriptionAt(screen.pane), description, canvas_module.blue, .centre, description_lines);
        };
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
    }
};

/// The row an item of the list is on; none for an arrow of the list.
fn rowOf(item: Pane.Item) ?usize {
    return switch (item) {
        .scroll => null,
        .check => |row| row,
        .step => |stepped| stepped.row,
    };
}

/// What the tests keep pages with: one mod's page, and the values set.
pub const Recorder = struct {
    mod: []const u8,
    page: Page,
    values: [max_options]?Value = @splat(null),
    sets: usize = 0,

    pub fn pages(recorder: *Recorder) Pages {
        return .{ .context = recorder, .vtable = &.{ .page = pageOf, .get = getValue, .set = setValue } };
    }

    fn from(context: *anyopaque) *Recorder {
        return @ptrCast(@alignCast(context));
    }

    fn pageOf(context: *anyopaque, mod: []const u8) ?Page {
        return if (std.mem.eql(u8, mod, from(context).mod)) from(context).page else null;
    }

    fn getValue(context: *anyopaque, mod: []const u8, key: []const u8) ?Value {
        _ = mod;
        const recorder = from(context);
        for (recorder.page.options, 0..) |option, at| {
            if (std.mem.eql(u8, option.key, key)) return recorder.values[at];
        }
        return null;
    }

    fn setValue(context: *anyopaque, mod: []const u8, key: []const u8, value: Value) void {
        _ = mod;
        const recorder = from(context);
        recorder.sets += 1;
        for (recorder.page.options, 0..) |option, at| {
            if (std.mem.eql(u8, option.key, key)) recorder.values[at] = value;
        }
    }
};

pub const test_choices = [_]Choice{
    .{ .value = .{ .number = 0.2 }, .label = "20%" },
    .{ .value = .{ .number = 0.35 }, .label = "35%" },
    .{ .value = .{ .number = 0.5 }, .label = "50%" },
};

pub const test_options = [_]Option{
    .{ .key = "show", .label = "SHOW PANEL", .description = "Shows the panel.", .default = .{ .boolean = true }, .control = .toggle },
    .{ .key = "flee", .label = "FLEE AT", .description = "", .default = .{ .number = 0.35 }, .control = .{ .choice = &test_choices } },
    .{ .key = "regroup", .label = "REGROUP AFTER", .description = "", .default = .{ .number = 20 }, .control = .{ .number = .{ .min = 5, .max = 60, .step = 5 } } },
};

test Option {
    const flee = test_options[1];
    const regroup = test_options[2];
    // Declared well, and badly.
    for (test_options) |option| try std.testing.expectEqual(null, option.problem());
    var bad = flee;
    bad.default = .{ .number = 0.4 };
    try std.testing.expectEqualStrings("a choice's default must be one of its values", bad.problem().?);
    bad = regroup;
    bad.control = .{ .number = .{ .min = 5, .max = 5, .step = 1 } };
    try std.testing.expectEqualStrings("a number's min must be below its max", bad.problem().?);
    bad.control = .{ .number = .{ .min = 5, .max = 60, .step = 0 } };
    try std.testing.expectEqualStrings("a number's step must be above 0", bad.problem().?);
    bad.default = .{ .number = 100 };
    bad.control = regroup.control;
    try std.testing.expectEqualStrings("a number's default must be within its range", bad.problem().?);
    bad = test_options[0];
    bad.default = .{ .number = 1 };
    try std.testing.expectEqualStrings("a toggle's default must be a boolean", bad.problem().?);
    // A saved value that doesn't suit is the default, and a number is brought into its range.
    try std.testing.expectEqual(Value{ .number = 0.35 }, flee.fit(.{ .number = 0.3 }));
    try std.testing.expectEqual(Value{ .number = 0.5 }, flee.fit(.{ .number = 0.5 }));
    try std.testing.expectEqual(Value{ .number = 60 }, regroup.fit(.{ .number = 1000 }));
    try std.testing.expectEqual(Value{ .number = 20 }, regroup.fit(.{ .text = "soon" }));
    try std.testing.expectEqual(Value{ .boolean = true }, test_options[0].fit(.{ .number = 1 }));
    // Arrows: a choice goes round, a number stops at its ends, and a toggle turns over.
    try std.testing.expectEqual(Value{ .number = 0.5 }, flee.stepped(.{ .number = 0.35 }, .on));
    try std.testing.expectEqual(Value{ .number = 0.2 }, flee.stepped(.{ .number = 0.5 }, .on));
    try std.testing.expectEqual(Value{ .number = 55 }, regroup.stepped(.{ .number = 50 }, .on));
    try std.testing.expectEqual(Value{ .number = 60 }, regroup.stepped(.{ .number = 60 }, .on));
    try std.testing.expectEqual(Value{ .number = 5 }, regroup.stepped(.{ .number = 5 }, .back));
    try std.testing.expectEqual(Value{ .boolean = false }, test_options[0].stepped(.{ .boolean = true }, .on));
    // Steps of a tenth stay tidy.
    const tenths: Option = .{ .key = "t", .label = "T", .description = "", .default = .{ .number = 0 }, .control = .{ .number = .{ .min = 0, .max = 1, .step = 0.1 } } };
    var value: Value = .{ .number = 0 };
    for (0..3) |_| value = tenths.stepped(value, .on);
    try std.testing.expectEqual(Value{ .number = 0.3 }, value);
    var buffer: [number_words]u8 = undefined;
    try std.testing.expectEqualStrings("0.3", tenths.words(value, &buffer));
    try std.testing.expectEqualStrings("35%", flee.words(.{ .number = 0.35 }, &buffer));
    try std.testing.expectEqualStrings("", test_options[0].words(.{ .boolean = true }, &buffer));
}

test "choices of different kinds, and repeated ones, are refused" {
    var option = test_options[1];
    const mixed = [_]Choice{ .{ .value = .{ .number = 1 }, .label = "ONE" }, .{ .value = .{ .text = "two" }, .label = "TWO" } };
    option.control = .{ .choice = &mixed };
    option.default = .{ .number = 1 };
    try std.testing.expectEqualStrings("a choice's values must all be numbers, or all strings", option.problem().?);
    const repeated = [_]Choice{ .{ .value = .{ .text = "a" }, .label = "A" }, .{ .value = .{ .text = "a" }, .label = "B" } };
    option.control = .{ .choice = &repeated };
    option.default = .{ .text = "a" };
    try std.testing.expectEqualStrings("a choice's values must differ", option.problem().?);
    option.control = .{ .choice = &.{} };
    try std.testing.expectEqualStrings("a choice needs choices", option.problem().?);
}

/// A click at `at` on `screen`: the pointer there with its button up, then down.
fn click(screen: *ModOptions, keyboard: *input.Keyboard, pages: Pages, at: [2]i32) ?settings.End {
    var context: Context = .{ .pointer = .{ .at = at }, .keyboard = keyboard, .ticks = 0, .pages = pages };
    _ = screen.frame(context);
    context.pointer.down = true;
    return screen.frame(context);
}

test "the screen shows a page, and keeps each change at once" {
    var recorder: Recorder = .{ .mod = "wingmen", .page = .{ .title = "WINGMEN", .options = &test_options } };
    recorder.values[1] = .{ .number = 0.5 };
    const pages = recorder.pages();
    var keyboard: input.Keyboard = .{};
    var screen: ModOptions = .{};
    var context: Context = .{ .pointer = .{}, .keyboard = &keyboard, .ticks = 0, .pages = pages };
    // A mod with no page has none to show.
    try std.testing.expect(!screen.enter("other", context));
    try std.testing.expect(screen.enter("wingmen", context));
    // The values kept, and the defaults for those not kept.
    try std.testing.expectEqual(Value{ .boolean = true }, screen.values[0]);
    try std.testing.expectEqual(Value{ .number = 0.5 }, screen.values[1]);
    try std.testing.expectEqual(Value{ .number = 20 }, screen.values[2]);
    try std.testing.expectEqual(0, recorder.sets);
    // The check box turns the toggle over; the choice's arrows go on and round; the number's step.
    try std.testing.expectEqual(null, click(&screen, &keyboard, pages, screen.pane.line(0).boxRect().centre()));
    try std.testing.expectEqual(Value{ .boolean = false }, recorder.values[0].?);
    try std.testing.expectEqual(null, click(&screen, &keyboard, pages, screen.pane.line(1).arrow(.on).centre()));
    try std.testing.expectEqual(Value{ .number = 0.2 }, recorder.values[1].?);
    try std.testing.expectEqual(null, click(&screen, &keyboard, pages, screen.pane.line(2).arrow(.back).centre()));
    try std.testing.expectEqual(Value{ .number = 15 }, recorder.values[2].?);
    try std.testing.expectEqual(3, recorder.sets);
    // CANCEL CHANGES puts the values back as the screen opened them, RESET DEFAULTS the defaults;
    // a value already there isn't set again.
    try std.testing.expectEqual(null, click(&screen, &keyboard, pages, settings.Button.cancel_changes.rect().centre()));
    try std.testing.expectEqual(Value{ .boolean = true }, recorder.values[0].?);
    try std.testing.expectEqual(Value{ .number = 0.5 }, recorder.values[1].?);
    try std.testing.expectEqual(Value{ .number = 20 }, recorder.values[2].?);
    try std.testing.expectEqual(6, recorder.sets);
    try std.testing.expectEqual(null, click(&screen, &keyboard, pages, settings.Button.reset_defaults.rect().centre()));
    try std.testing.expectEqual(Value{ .number = 0.35 }, recorder.values[1].?);
    try std.testing.expectEqual(7, recorder.sets);
    // OK, MAIN MENU and Escape end the screen.
    try std.testing.expectEqual(settings.End.back, click(&screen, &keyboard, pages, settings.Button.ok.rect().centre()).?);
    try std.testing.expectEqual(settings.End.main_menu, click(&screen, &keyboard, pages, settings.Button.leave.rect().centre()).?);
    keyboard.down[input.scan.escape] = true;
    context.pointer = .{};
    try std.testing.expectEqual(settings.End.back, screen.frame(context).?);
}
