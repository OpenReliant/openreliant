//! The settings screen's widgets, which its tabs are put together from: what the original's
//! settings screens draw with their shapes (`settings.shapes_name`), each placed on the front end's
//! screen, drawn, and found under the pointer.
//!
//! - `Line`: a row as the video screen lays one out, its label, an arrows' box or a check box, and
//!   its value.
//! - `Box`, a check box or a radio button, and `Toggle`, one with its label beside it.
//! - `ArrowPair`: two arrows, the audio screen's (`StepArrows`) or a list's (`ListArrows`).
//! - `Slider`: the volumes' and the brightness's.
//! - `Frame`, the box round a list; `List`, the rows a list shows, which its `ListArrows` scroll;
//!   and `Pane`, a list of `Line`s in a frame, with its arrows.
//! - `heading`: the large font's words over a frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../../input.zig");
const hud = @import("../../hud.zig");
const canvas_module = @import("../canvas.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const Arrow = canvas_module.Arrow;
const Error = canvas_module.Error;
const blue = canvas_module.blue;

/// An arrow, which steps a choice back or on.
pub const Step = enum { back, on };

/// The choice a step from the one at `at` of `count`, round from the last to the first; from one
/// not among them, on to the first or back to the last.
pub fn steppedIndex(at: ?usize, count: usize, step: Step) usize {
    return switch (step) {
        .on => if (at) |index| (index + 1) % count else 0,
        .back => if (at) |index| (index + count - 1) % count else count - 1,
    };
}

/// The choice of `E` a step from `current`, in its order, round from the last to the first.
pub fn steppedChoice(comptime E: type, current: E, step: Step) E {
    const choices = comptime std.enums.values(E);
    return choices[steppedIndex(std.mem.indexOfScalar(E, choices, current), choices.len, step)];
}

/// A row, as the game's video screen lays one out (`video_screen_draw`, `0x0042F440`): its label to
/// the left of x 280, its `edge`; an arrows' box, shape `0x2E`, a pixel above it at x 301
/// (`0x0042F903` on), whose halves the pointer finds 12 by 23 from x 301 and 318 (`video_items`,
/// `0x004E76F0`) and which light under the pointer with `0x2F` and `0x30` (`0x0042FD3D` on), or a
/// check box two pixels below it at x 311 (`0x0042FC89` on); and its value from x 352
/// (`0x0042F744` on). A row placed elsewhere keeps its columns as far from its edge.
pub const Line = struct {
    /// Where its label's text stands, from the top.
    y: i32,
    /// Where its label ends, across, which its columns stand right of.
    edge: i32 = original_edge,

    pub const original_edge = 280;
    const value_from = 352 - original_edge;
    const arrows_shape = 0x2E;
    const arrows_from = 301 - original_edge;
    const arrow_on_from = 318 - original_edge;
    const arrows_raise = 1;
    const arrow_size: [2]i16 = .{ 12, 23 };
    /// The arrows' box's height, from a pixel above the label.
    pub const arrows_height = 26;
    const box_from = 311 - original_edge;
    const box_drop = 2;
    const lit_shapes = std.EnumArray(Step, usize).init(.{ .back = 0x2F, .on = 0x30 });

    pub fn label(line: Line, text: Label.Text) Label {
        return .{ .text = text, .at = .{ line.edge, line.y }, .alignment = .right };
    }

    pub fn value(line: Line, text: Label.Text) Label {
        return .{ .text = text, .at = .{ line.edge + value_from, line.y } };
    }

    /// Where the pointer finds its arrow `step`.
    pub fn arrow(line: Line, step: Step) Rect {
        const from: i32 = switch (step) {
            .back => arrows_from,
            .on => arrow_on_from,
        };
        return .{ .x = @intCast(line.edge + from), .y = @intCast(line.y - arrows_raise), .width = arrow_size[0], .height = arrow_size[1] };
    }

    /// The arrow at `at`.
    pub fn arrowAt(line: Line, at: [2]i32) ?Step {
        for (std.enums.values(Step)) |step| if (line.arrow(step).holds(at)) return step;
        return null;
    }

    /// Where its check box stands.
    pub fn box(line: Line) [2]i32 {
        return .{ line.edge + box_from, line.y + box_drop };
    }

    /// Where the pointer finds its check box.
    pub fn boxRect(line: Line) Rect {
        const corner = line.box();
        return .{ .x = @intCast(corner[0]), .y = @intCast(corner[1]), .width = Box.size, .height = Box.size };
    }

    pub fn drawArrows(line: Line, canvas: Canvas, art: *hud.Art) Error!void {
        try canvas.shape(art, arrows_shape, .{ line.edge + arrows_from, line.y - arrows_raise });
    }

    /// Its arrow `step` lit, as under the pointer.
    pub fn drawLit(line: Line, canvas: Canvas, art: *hud.Art, step: Step) Error!void {
        const rect = line.arrow(step);
        try canvas.shape(art, lit_shapes.get(step), .{ rect.x, rect.y });
    }

    /// The row whole: its label, and its check box, ticked or not, or its arrows and its value,
    /// all dimmed where it can't be changed.
    pub fn draw(line: Line, canvas: Canvas, art: *hud.Art, shown: Shown) Error!void {
        const drawn = canvas.dimmedUnless(shown.usable);
        const small = canvas.fonts.small;
        try line.label(shown.label).write(drawn, small, blue);
        switch (shown.control) {
            .check => |ticked| try Box.draw(drawn, art, line.box(), ticked),
            .choice => |text| {
                try line.drawArrows(drawn, art);
                try line.value(text).write(drawn, small, blue);
            },
        }
    }

    /// What a row shows: its label, and its check box or its choice; dimmed where it can't be
    /// changed.
    pub const Shown = struct {
        label: Label.Text,
        control: Control,
        usable: bool = true,
    };

    pub const Control = union(enum) {
        /// A check box, ticked or not.
        check: bool,
        /// A choice the arrows step through, by its value.
        choice: Label.Text,
    };
};

/// A check box or a radio button of the screen's shapes: the box, shape `0x1A`, and the tick in the
/// one set, `0x1B`, three pixels in (`0x0042D75E` on, `0x0042D96C` on).
pub const Box = struct {
    /// Its size, where the pointer finds it.
    pub const size = 16;
    const shape = 0x1A;
    const tick = 0x1B;
    const tick_offset = 3;

    pub fn draw(canvas: Canvas, art: *hud.Art, at: [2]i32, ticked: bool) Error!void {
        try canvas.shape(art, shape, at);
        if (ticked) try canvas.shape(art, tick, .{ at[0] + tick_offset, at[1] + tick_offset });
    }
};

/// A check box or a radio button with its label beside it, at the box's height, as the controls
/// screen has them (`0x0042D96C` on, `0x0042D9F8` on): the controllers' labels 22 right of their
/// boxes, the check boxes' 18. Both are dimmed where it can't be changed.
pub const Toggle = struct {
    /// Where its box stands.
    at: [2]i32,
    /// How far right of the box its label starts.
    gap: i32 = controller_gap,
    /// How far left of the box the pointer finds it, as the controls' check boxes are found 4 to
    /// the left (`0x0042B70D` on), the box's width across from there.
    reach: i32 = 0,

    /// How far right of their boxes the controllers' labels start, and the check boxes'.
    pub const controller_gap = 22;
    pub const check_gap = 18;

    /// Where the pointer finds it.
    pub fn rect(toggle: Toggle) Rect {
        return .{ .x = @intCast(toggle.at[0] - toggle.reach), .y = @intCast(toggle.at[1]), .width = Box.size, .height = Box.size };
    }

    /// Its label, `text`.
    pub fn label(toggle: Toggle, text: Label.Text) Label {
        return .{ .text = text, .at = .{ toggle.at[0] + toggle.gap, toggle.at[1] } };
    }

    /// Its label, `text`, and its box, ticked or not, both dimmed where it can't be changed.
    pub fn draw(toggle: Toggle, canvas: Canvas, art: *hud.Art, text: Label.Text, ticked: bool, usable: bool) Error!void {
        const drawn = canvas.dimmedUnless(usable);
        try toggle.label(text).write(drawn, drawn.fonts.small, blue);
        try Box.draw(drawn, art, toggle.at, ticked);
    }
};

/// A pair of arrows of the screen's shapes, keyed by `Key`, each lit under the pointer: the first
/// at `at`, the second `layout.apart` from it, each found `layout.size` from `layout.reach` left of
/// its shape.
pub fn ArrowPair(comptime Key: type, comptime layout: PairLayout(Key)) type {
    return struct {
        /// Where the first arrow's shape stands.
        at: [2]i32,

        const Pair = @This();
        const keys = std.enums.values(Key);

        /// Where `key`'s shape stands.
        fn corner(arrows: Pair, key: Key) [2]i32 {
            if (key == keys[0]) return arrows.at;
            return .{ arrows.at[0] + layout.apart[0], arrows.at[1] + layout.apart[1] };
        }

        /// Where the pointer finds the arrow `key`.
        pub fn rect(arrows: Pair, key: Key) Rect {
            const at = arrows.corner(key);
            return .{ .x = @intCast(at[0] - layout.reach), .y = @intCast(at[1]), .width = layout.size[0], .height = layout.size[1] };
        }

        /// The arrow at `at`.
        pub fn itemAt(arrows: Pair, at: [2]i32) ?Key {
            for (keys) |key| if (arrows.rect(key).holds(at)) return key;
            return null;
        }

        /// Both arrows, and `lit` lit.
        pub fn draw(arrows: Pair, canvas: Canvas, art: *hud.Art, lit: ?Key) Error!void {
            for (keys) |key| {
                const shapes = layout.shapes.get(key);
                try canvas.shape(art, shapes.off, arrows.corner(key));
                if (lit == key) try canvas.shape(art, shapes.lit, arrows.corner(key));
            }
        }

        comptime {
            std.debug.assert(keys.len == 2);
        }
    };
}

/// How an `ArrowPair` is laid out, and the shapes each arrow is drawn with, as it stands and lit.
pub fn PairLayout(comptime Key: type) type {
    return struct {
        apart: [2]i32,
        size: [2]i16,
        reach: i32 = 0,
        shapes: std.EnumArray(Key, struct { off: usize, lit: usize }),
    };
}

/// A pair of arrows, as the audio screen's 3D SOUND has them (`0x0042E4E4` on): back, shape `0x13`,
/// and on, `0x14`, 22 right of it, lit under the pointer with `0x15` and `0x16`, each found 19 by 26.
pub const StepArrows = ArrowPair(Step, .{
    .apart = .{ 22, 0 },
    .size = .{ 19, 26 },
    .shapes = .init(.{
        .back = .{ .off = 0x13, .lit = 0x15 },
        .on = .{ .off = 0x14, .lit = 0x16 },
    }),
});

/// A slider of the screen's shapes, as the audio's volumes and the video's brightness have it: a
/// knob, shape `0x2C`, 15 by 27, which slides `travel` to the right of where it starts, and a
/// track, shape `0x2D`, 10 below the knob's top, every 45 from where the knob starts until `end`
/// (`0x0042E5E3` on, `0x0042FA39` on). The pointer holds the knob 4 pixels to the right of its left
/// edge (`0x0042DEB3`, `0x0042EB27`).
pub const Slider = struct {
    /// Where the knob's corner stands at the slider's start.
    from: [2]i32,
    /// Where the track's marks end.
    end: i32,

    pub const travel = 175;
    const knob_shape = 0x2C;
    const track_shape = 0x2D;
    const knob_size: [2]i16 = .{ 15, 27 };
    const track_drop = 10;
    const track_step = 45;
    const grip = 4;

    /// The knob `along` its travel from the start, where the pointer finds it.
    pub fn knob(slider: Slider, along: i32) Rect {
        return .{ .x = @intCast(slider.from[0] + along), .y = @intCast(slider.from[1]), .width = knob_size[0], .height = knob_size[1] };
    }

    /// How far along its travel the knob held stands, for the pointer at `x`.
    pub fn held(slider: Slider, x: i32) i32 {
        return std.math.clamp(x - grip - slider.from[0], 0, travel);
    }

    pub fn drawTrack(slider: Slider, canvas: Canvas, art: *hud.Art) Error!void {
        var x = slider.from[0];
        while (x < slider.end) : (x += track_step) try canvas.shape(art, track_shape, .{ x, slider.from[1] + track_drop });
    }

    pub fn drawKnob(slider: Slider, canvas: Canvas, art: *hud.Art, along: i32) Error!void {
        const rect = slider.knob(along);
        try canvas.shape(art, knob_shape, .{ rect.x, rect.y });
    }
};

/// The box round a list, `interface_box`'s (`Canvas.box`): its corner at `at`, `extent` across and
/// down.
pub const Frame = struct {
    at: [2]i32,
    extent: [2]i32,

    pub fn draw(frame: Frame, canvas: Canvas) void {
        canvas.box(frame.at, frame.extent);
    }
};

/// Writes `label` as a heading over a frame, in the large font, blue, as the controls' FUNCTION and
/// CONTROL (`0x0042CFC0`, `0x0042CFEC`).
pub fn heading(canvas: Canvas, label: Label) Allocator.Error!void {
    try label.write(canvas, canvas.fonts.large, blue);
}

/// The rows a list of the screen's shows, a few at a time, as the controls' list shows its own:
/// its arrows scroll it a row, and again each `scroll_ticks` while one is held (`0x0042BD09`).
pub const List = struct {
    rows: canvas_module.Scrolled(u8),
    /// The tick a held arrow next scrolls the list after.
    scroll_at: u32 = 0,

    /// The ticks a held arrow waits before the list scrolls another row (`0x0042BD2C`).
    pub const scroll_ticks = 5;

    /// `count` rows, `shown` at a time, from the first, an arrow scrolling them after `ticks`.
    pub fn of(count: u8, shown: u8, ticks: u32) List {
        return .{ .rows = .{ .count = count, .shown = shown }, .scroll_at = ticks };
    }

    /// The list scrolled `way` a row, as an arrow held scrolls it: at once, then each
    /// `scroll_ticks` while it is held.
    pub fn scrollHeld(list: *List, way: Arrow, ticks: u32) void {
        if (ticks <= list.scroll_at) return;
        list.rows.scroll(way);
        list.scroll_at = ticks + scroll_ticks;
    }

    /// The mouse's wheel's `notches` scroll the list, and Up and Down, held on `keyboard`, scroll
    /// it as its arrows do.
    ///
    /// **Improvement:** the game's lists scroll by their arrows alone.
    pub fn scrollBy(list: *List, notches: i32, keyboard: *input.Keyboard, ticks: u32) void {
        list.rows.wheel(notches);
        if (keyboard.pressed(@intFromEnum(input.Key.up), .none, false)) list.scrollHeld(.up, ticks);
        if (keyboard.pressed(@intFromEnum(input.Key.down), .none, false)) list.scrollHeld(.down, ticks);
    }

    /// Where `row` stands among the rows shown, from the top, where it is shown.
    pub fn place(list: List, row: usize) ?usize {
        if (row < list.rows.first or row >= list.rows.end()) return null;
        return row - list.rows.first;
    }
};

/// A list's arrows, as the controls' list has them (`0x0042D8CA` on): the up arrow, shape `0x1E`,
/// above the down arrow, `0x1F`, 20 below it, each lit under the pointer with `0x20` and `0x21`, and
/// found 28 by 16 from 4 pixels left of its shape (`0x0042B69A` on).
pub const ListArrows = ArrowPair(Arrow, .{
    .apart = .{ 0, 20 },
    .size = .{ 28, 16 },
    .reach = 4,
    .shapes = .init(.{
        .up = .{ .off = 0x1E, .lit = 0x20 },
        .down = .{ .off = 0x1F, .lit = 0x21 },
    }),
});

/// A list of `Line`s in a frame, as the controls' list is framed and scrolled by its arrows: the
/// rows shown stand `spacing` apart from `first` down, their labels ending at `edge`.
pub const Pane = struct {
    frame: Frame,
    arrows: ListArrows,
    /// Where the first row shown has its label, from the top.
    first: i32,
    spacing: i32,
    edge: i32 = Line.original_edge,

    /// What the pointer finds on it: one of its arrows, or a row's arrow or check box, the row by
    /// its place in the list.
    pub const Item = union(enum) {
        scroll: Arrow,
        step: Stepped,
        check: u8,
    };

    pub const Stepped = struct { row: u8, step: Step };

    /// The line of the row shown `place`th from the top.
    pub fn line(pane: Pane, place: usize) Line {
        return .{ .y = pane.first + @as(i32, @intCast(place)) * pane.spacing, .edge = pane.edge };
    }

    /// The item at `at`, among the rows of `shown` that `list` shows.
    pub fn itemAt(pane: Pane, list: List, shown: []const Line.Shown, at: [2]i32) ?Item {
        if (pane.arrows.itemAt(at)) |arrow| return .{ .scroll = arrow };
        for (list.rows.first..list.rows.end(), 0..) |row, place| {
            const placed = pane.line(place);
            switch (shown[row].control) {
                .check => if (placed.boxRect().holds(at)) return .{ .check = @intCast(row) },
                .choice => if (placed.arrowAt(at)) |step| return .{ .step = .{ .row = @intCast(row), .step = step } },
            }
        }
        return null;
    }

    /// The frame, the rows of `shown` that `list` shows, the arrow of `lit`'s lit, and the list's
    /// arrows, the one of `lit` lit.
    pub fn draw(pane: Pane, canvas: Canvas, art: *hud.Art, list: List, shown: []const Line.Shown, lit: ?Item) Error!void {
        pane.frame.draw(canvas);
        for (list.rows.first..list.rows.end(), 0..) |row, place| try pane.line(place).draw(canvas, art, shown[row]);
        var lit_arrow: ?Arrow = null;
        if (lit) |item| switch (item) {
            .scroll => |arrow| lit_arrow = arrow,
            .step => |stepped| if (list.place(stepped.row)) |place| try pane.line(place).drawLit(canvas, art, stepped.step),
            .check => {},
        };
        try pane.arrows.draw(canvas, art, lit_arrow);
    }
};

test steppedChoice {
    const Three = enum { a, b, c };
    try std.testing.expectEqual(Three.b, steppedChoice(Three, .a, .on));
    try std.testing.expectEqual(Three.a, steppedChoice(Three, .c, .on));
    try std.testing.expectEqual(Three.c, steppedChoice(Three, .a, .back));
    // One not among them steps on to the first, or back to the last.
    try std.testing.expectEqual(0, steppedIndex(null, 3, .on));
    try std.testing.expectEqual(2, steppedIndex(null, 3, .back));
}

test Line {
    const line: Line = .{ .y = 129 };
    // The arrows' halves, found a pixel above the label, and the box two below it.
    try std.testing.expectEqual(Step.back, line.arrowAt(.{ 305, 135 }).?);
    try std.testing.expectEqual(Step.on, line.arrowAt(.{ 322, 135 }).?);
    try std.testing.expectEqual(null, line.arrowAt(.{ 340, 135 }));
    try std.testing.expectEqual(Rect{ .x = 311, .y = 131, .width = 16, .height = 16 }, line.boxRect());
    // Placed elsewhere, its columns as far from its edge.
    const moved: Line = .{ .y = 129, .edge = 300 };
    try std.testing.expectEqual(Step.back, moved.arrowAt(.{ 325, 135 }).?);
    try std.testing.expectEqual([2]i32{ 372, 129 }, moved.value(.{ .words = "" }).at);
}

test Toggle {
    // The controls' check boxes are found from 4 pixels left of the box, their labels 18 right.
    const check: Toggle = .{ .at = .{ 349, 325 }, .gap = Toggle.check_gap, .reach = 4 };
    try std.testing.expectEqual(Rect{ .x = 345, .y = 325, .width = 16, .height = 16 }, check.rect());
    try std.testing.expectEqual([2]i32{ 367, 325 }, check.label(.{ .words = "" }).at);
}

test StepArrows {
    // The audio screen's, found 19 by 26 from x 300 and 322.
    const arrows: StepArrows = .{ .at = .{ 300, 369 } };
    try std.testing.expectEqual(Rect{ .x = 322, .y = 369, .width = 19, .height = 26 }, arrows.rect(.on));
    try std.testing.expectEqual(Step.back, arrows.itemAt(.{ 305, 375 }).?);
}

test "the lists' arrows and panes" {
    // The controls' arrows, found 28 by 16 from x 370.
    const arrows: ListArrows = .{ .at = .{ 374, 136 } };
    try std.testing.expectEqual(Rect{ .x = 370, .y = 156, .width = 28, .height = 16 }, arrows.rect(.down));
    try std.testing.expectEqual(Arrow.up, arrows.itemAt(.{ 380, 143 }).?);
    // A pane of four rows showing two, scrolled one down: its second row shown is the list's third.
    const pane: Pane = .{ .frame = .{ .at = .{ 45, 136 }, .extent = .{ 300, 60 } }, .arrows = arrows, .first = 140, .spacing = 26 };
    var list: List = .of(4, 2, 0);
    list.scrollHeld(.down, 1);
    const shown = [_]Line.Shown{
        .{ .label = .{ .words = "A" }, .control = .{ .check = true } },
        .{ .label = .{ .words = "B" }, .control = .{ .choice = .{ .words = "ON" } } },
        .{ .label = .{ .words = "C" }, .control = .{ .choice = .{ .words = "OFF" } } },
        .{ .label = .{ .words = "D" }, .control = .{ .check = false } },
    };
    try std.testing.expectEqual(Pane.Item{ .step = .{ .row = 1, .step = .on } }, pane.itemAt(list, &shown, .{ 322, 145 }).?);
    try std.testing.expectEqual(Pane.Item{ .step = .{ .row = 2, .step = .back } }, pane.itemAt(list, &shown, .{ 305, 171 }).?);
    try std.testing.expectEqual(Pane.Item{ .scroll = .down }, pane.itemAt(list, &shown, .{ 380, 160 }).?);
    // A row not shown is nowhere.
    try std.testing.expectEqual(null, list.place(0));
    try std.testing.expectEqual(1, list.place(2).?);
    // Held, the arrow scrolls again only after the wait.
    list.scrollHeld(.down, 2);
    try std.testing.expectEqual(1, list.rows.first);
    list.scrollHeld(.down, 1 + List.scroll_ticks + 1);
    try std.testing.expectEqual(2, list.rows.first);
}
