//! The pause menu's items and how they are drawn: `menu_draw` (`0x0048DB00`) and the pieces the
//! screens are made of. A screen is a list of `Item`s and what choosing each does; the widgets here
//! (`buttons`, `Slider`, `Selector`) make the items the screens share and read what the pointer
//! does to them. [`pause-menu.md`](../../../../docs/engine/pause-menu.md#menu-items) describes
//! them.
//!
//! **Improvement.** The game lays a menu out in pixels about fractions of the screen, at the size
//! of its art whatever the screen's. OpenReliant multiplies the pixels by `hud.scaleFor`, as it
//! does the display's, so the menu keeps its proportions on a larger screen; at a scale of 1 it is
//! the game's own layout.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const hud = @import("../hud.zig");
const input = @import("../../input.zig");
const language = @import("../language.zig");
const device = @import("../../surrender/srd3d/device.zig");
const spr = @import("../../../formats/spr.zig");

pub const round = hud.round;

/// What drawing a menu can fail with: a shape the set can't give, or memory.
pub const Error = spr.Error || Allocator.Error;

/// The display's shapes (`HUDHARD.SPR`) the menus draw, by their index in the set; 0 for none.
pub const Shape = enum(u32) {
    none = 0,
    button = 0x176,
    button_lit = 0x177,
    /// The box a setting's value is stepped through by, and its two halves, lit.
    arrows = 0x178,
    arrow_back = 0x179,
    arrow_forward = 0x17A,
    /// The widget a list is scrolled by, and its two halves, lit.
    scroll = 0x17B,
    scroll_up = 0x17C,
    scroll_down = 0x17D,
    pointer = 0x17E,
    joystick = 0x17F,
    speaker = 0x180,
    monitor = 0x181,
    joystick_lit = 0x182,
    speaker_lit = 0x183,
    monitor_lit = 0x184,
    check_off = 0x185,
    check_on = 0x186,
    track = 0x187,
    knob = 0x188,
    _,

    /// The shape, or null for none.
    pub fn get(shape: Shape) ?Shape {
        return if (shape == .none) null else shape;
    }
};

/// The game's strings the menus write, by their ids in `LANGUAGE.DLL`; -1 for none.
pub const String = enum(i32) {
    none = -1,
    select_an_option = 0x108,
    audio = 0x109,
    control_devices = 0x10A,
    video = 0x10B,
    graphics_configuration = 0x10D,
    brightness = 0x113,
    continue_game = 0x180,
    restart = 0x181,
    reset_defaults = 0x183,
    default_view = 0x28A,
    cockpit_view = 0x28B,
    chase_view = 0x28C,
    sound_configuration = 0x2ED,
    sound_effects_volume = 0x2EE,
    music_volume = 0x2EF,
    ok = 0x316,
    leave_mission = 0x32B,
    speech_volume = 0x576,
    master_volume = 0x577,
    no_cockpit_view = 0x57F,
    cancel_changes = 0x5A9,
    _,
};

/// The font an item's text is written in, by its index into `menu_fonts` (`0x0057DA64`): the
/// display's own, `smlfnt2.fnt` or `optfnt.fnt`; -1 for none.
pub const Font = enum(i32) {
    none = -1,
    display = 0,
    small = 1,
    large = 2,
};

/// The fonts, open, that `Font` picks from.
pub const Fonts = struct {
    display: *hud.Opened,
    small: *hud.Opened,
    large: *hud.Opened,

    pub fn get(fonts: Fonts, font: Font) ?*hud.Opened {
        return switch (font) {
            .none => null,
            .display => fonts.display,
            .small => fonts.small,
            .large => fonts.large,
        };
    }
};

/// Where a line of an item's text stands from where it is written, as `hud_text` takes it.
pub const Alignment = hud.Align;

/// Something a menu shows (`MenuItem`, 0x30 bytes): a shape placed about a point of the screen,
/// another in its place while the pointer is on it, and a line of text. The screens' tables in
/// the game are arrays of these.
pub const Item = extern struct {
    /// Which part of the shape stands at the point.
    place: Place = .{},
    /// The point, as fractions of the screen across and down.
    anchor: [2]f32,
    /// From the point, in the menu's pixels.
    offset: [2]i32 = .{ 0, 0 },
    /// The shape, and the one drawn in its place while the pointer is on it. An item with only the
    /// second shows only while the pointer is on it.
    shape: Shape = .none,
    lit: Shape = .none,
    /// Where the text stands from the point, leaving the shape's placing out, what it is written
    /// in, and what it says.
    text_offset: [2]i32 = .{ 0, 0 },
    font: Font = .none,
    string: String = .none,
    style: Style = .{},

    pub const Style = packed struct(u32) {
        alignment: Alignment = .left,
        /// Drawn at half brightness, as what can't be chosen is.
        dimmed: bool = false,
        _: u28 = 0,
    };

    /// An item that shows nothing and that the pointer never finds.
    pub const none: Item = .{ .anchor = .{ 0, 0 } };

    /// The shape the item is placed and found by: its own, or else the one it shows under the
    /// pointer; null for an item of text alone.
    fn boxShape(item: Item) ?Shape {
        return item.shape.get() orelse item.lit.get();
    }

    comptime {
        assert(@offsetOf(Item, "anchor") == 0x04);
        assert(@offsetOf(Item, "shape") == 0x14);
        assert(@offsetOf(Item, "text_offset") == 0x1C);
        assert(@offsetOf(Item, "string") == 0x28);
        assert(@sizeOf(Item) == 0x30);
    }
};

/// Which part of a shape stands at its item's point, across and down, a nibble each.
pub const Place = packed struct(u32) {
    across: Edge = .centre,
    down: Edge = .centre,
    _: u24 = 0,

    pub const Edge = enum(u4) {
        /// As `start`: the game places none of its items so.
        none = 0,
        centre = 1,
        /// The left or the top edge.
        start = 2,
        /// The right or the bottom edge.
        end = 3,
        _,

        /// How far before the point a shape `size` long starts.
        fn lead(edge: Edge, size: i32) i32 {
            return switch (edge) {
                .centre => @divTrunc(size, 2),
                .end => size,
                else => 0,
            };
        }
    };
};

/// The colours `hud_palette_ramp` ramps the menus' text through: orange, and white for the item
/// under the pointer. The title's rule is pure red.
pub const orange = hud.rgb(0xFE851A);
pub const white = hud.rgb(0xFFFFFF);
const red = hud.rgb(0xFF0000);

pub const lit = hud.atBrightness;

fn brightnessOf(dimmed: bool) f32 {
    return if (dimmed) 0.5 else 1;
}

/// The menu's pointer (`menu_cursor_x`, `menu_cursor_y`) and its buttons (`menu_mouse_down`,
/// `menu_mouse_pressed`, `menu_mouse_released`).
pub const Pointer = struct {
    /// Where it points, in the screen's pixels: (320, 240) until the system's pointer has first
    /// been over the window.
    at: [2]i32 = .{ 320, 240 },
    /// Whether the left or the right button is down, and whether one went down, or both came up,
    /// since the last frame.
    down: bool = false,
    pressed: bool = false,
    released: bool = false,

    /// `menu_mouse_update` (`0x0048D9F0`), once a paused frame.
    ///
    /// **Improvement.** The pointer is where the system's is, over the window. The game adds up
    /// DirectInput's movements from where its pointer last stood, and puts the system's back
    /// near the window's corner after each.
    pub fn update(pointer: *Pointer, mouse: input.Mouse, screen: [2]u32) void {
        if (mouse.at) |share| for (&pointer.at, share, screen) |*at, fraction, size| {
            const last: i32 = @intCast(size -| 1);
            at.* = std.math.clamp(round(fraction * @as(f32, @floatFromInt(size))), 0, last);
        };
        const down = mouse.buttons.any();
        pointer.pressed = down and !pointer.down;
        pointer.released = !down and pointer.down;
        pointer.down = down;
    }
};

/// What a menu draws with and where: the display's shapes and fonts, drawn `scale` times larger
/// (`hud.scaleFor`), and the game's strings.
pub const Ui = struct {
    gpa: Allocator,
    target: device.Device,
    screen: [2]u32,
    scale: f32,
    art: *hud.Art,
    fonts: Fonts,
    strings: *const language.Language,

    /// `fraction` of the screen across, in pixels.
    pub fn across(ui: Ui, fraction: f32) i32 {
        return round(@as(f32, @floatFromInt(ui.screen[0])) * fraction);
    }

    /// `fraction` of the screen down, in pixels.
    pub fn down(ui: Ui, fraction: f32) i32 {
        return round(@as(f32, @floatFromInt(ui.screen[1])) * fraction);
    }

    /// `pixels` of the menu's in the screen's (`hud.pixels`).
    pub fn scaled(ui: Ui, pixels: i32) i32 {
        return hud.pixels(pixels, ui.scale);
    }

    /// The screen's pixels in the menu's.
    pub fn unscaled(ui: Ui, pixels: i32) f32 {
        return @as(f32, @floatFromInt(pixels)) / ui.scale;
    }

    /// The point an item stands about, with `offset` added.
    fn point(ui: Ui, anchor: [2]f32, offset: [2]i32) [2]i32 {
        return .{ ui.across(anchor[0]) + ui.scaled(offset[0]), ui.down(anchor[1]) + ui.scaled(offset[1]) };
    }

    /// Writes the string of `id` in `font` at `at` (`hud_text` of `language_string`). No string,
    /// no font, or a string the game doesn't have, writes nothing.
    pub fn write(ui: Ui, font: Font, at: [2]i32, id: String, colour: [4]f32, alignment: Alignment) Allocator.Error!void {
        const number = std.math.cast(u32, @intFromEnum(id)) orelse return;
        const text = ui.strings.string(number) orelse return;
        try ui.writeText(font, at, text, colour, alignment);
    }

    pub fn writeText(ui: Ui, font: Font, at: [2]i32, text: []const u8, colour: [4]f32, alignment: Alignment) Allocator.Error!void {
        const opened = ui.fonts.get(font) orelse return;
        _ = try hud.drawText(opened, ui.gpa, ui.target, at, text, colour, alignment, ui.scale);
    }

    /// Draws `shape` with its anchor at `at`.
    pub fn drawShape(ui: Ui, shape: Shape, at: [2]i32, colour: [4]f32) Error!void {
        try hud.drawShape(ui.art, ui.gpa, ui.target, @intFromEnum(shape), at, colour, ui.scale);
    }

    /// Where an item's shape stands, placed by the shape's bounds and origin
    /// (`VFX_shape_bounds`, `VFX_shape_origin`), and the rectangle the pointer finds it in; null
    /// for a shape the set lacks.
    fn boxOf(ui: Ui, item: Item, shape: Shape) ?Box {
        const header = (ui.art.shape(@intFromEnum(shape)) orelse return null).header;
        const size: [2]i32 = .{ header.bounds.across, header.bounds.down };
        const origin: [2]i32 = .{ header.origin.across, header.origin.down };
        const anchor: [2]i32 = .{ ui.across(item.anchor[0]), ui.down(item.anchor[1]) };
        var box: Box = undefined;
        for (&box.at, &box.size, anchor, origin, item.offset, size, [2]Place.Edge{ item.place.across, item.place.down }) |*at, *extent, from, start, offset, length, edge| {
            at.* = from + ui.scaled(start + offset - edge.lead(length));
            extent.* = ui.scaled(length);
        }
        return box;
    }

    /// `menu_draw` (`0x0048DB00`): the title, centred over a red rule a fifth of the way down,
    /// then the items' shapes and then their text, in order. With a pointer, the item under it is
    /// drawn with its lit shape and its text in white; the last item under the pointer is
    /// returned, lit shape or not.
    pub fn draw(ui: Ui, items: []const Item, title: String, pointer: ?Pointer) Error!?usize {
        const rule_down = ui.down(0.2);
        try ui.write(.large, .{ ui.across(0.5), rule_down - ui.scaled(32) }, title, lit(orange, 1), .centre);
        const ends: [2]hud.Point = .{ .{ @floatFromInt(ui.across(0.1)), @floatFromInt(rule_down) }, .{ @floatFromInt(ui.across(0.9)), @floatFromInt(rule_down) } };
        hud.drawLine(ui.target, ends[0], ends[1], lit(red, 1), ui.scale);

        var found: ?usize = null;
        var highlighted: ?usize = null;
        for (items, 0..) |item, index| {
            const box = ui.boxOf(item, item.boxShape() orelse continue) orelse continue;
            var shape = item.shape.get();
            if (pointer) |under| if (box.holds(under.at)) {
                found = index;
                if (item.lit.get()) |shown| {
                    shape = shown;
                    highlighted = index;
                }
            };
            const brightness = brightnessOf(item.style.dimmed);
            if (shape) |drawn| try ui.drawShape(drawn, box.at, .{ brightness, brightness, brightness, 1 });
        }
        for (items, 0..) |item, index| {
            if (item.string == .none) continue;
            const colour = if (highlighted == index) white else orange;
            const at = ui.point(item.anchor, .{ item.offset[0] + item.text_offset[0], item.offset[1] + item.text_offset[1] });
            try ui.write(item.font, at, item.string, lit(colour, brightnessOf(item.style.dimmed)), item.style.alignment);
        }
        return found;
    }

    /// Draws the pointer, last, over the rest.
    pub fn drawPointer(ui: Ui, pointer: Pointer) Error!void {
        try ui.drawShape(.pointer, pointer.at, .{ 1, 1, 1, 1 });
    }
};

/// A rectangle of the screen: its corner, and its size.
const Box = struct {
    at: [2]i32,
    size: [2]i32,

    fn holds(box: Box, point: [2]i32) bool {
        for (box.at, box.size, point) |start, length, p| {
            if (p < start or p >= start + length) return false;
        }
        return true;
    }
};

/// A button along the bottom of a screen, `offset` from the middle of the bottom edge, labelled on
/// the side away from the middle.
pub fn button(offset: [2]i32, label: String) Item {
    const right = offset[0] > 0;
    return .{
        .anchor = .{ 0.5, 1 },
        .offset = offset,
        .shape = .button,
        .lit = .button_lit,
        .text_offset = .{ if (right) 25 else -25, -5 },
        .font = .small,
        .string = label,
        .style = .{ .alignment = if (right) .left else .right },
    };
}

/// The buttons the screens share.
pub const buttons = struct {
    pub const ok = button(.{ 16, -32 }, .ok);
    /// In OK's place on the main screen.
    pub const leave_mission = button(.{ 16, -32 }, .leave_mission);
    pub const restart = button(.{ -16, -32 }, .restart);
    pub const continue_game = button(.{ -16, -52 }, .continue_game);
    pub const reset_defaults = button(.{ 16, -52 }, .reset_defaults);
    pub const cancel_changes = button(.{ 16, -74 }, .cancel_changes);
};

/// A setting dragged between `low` and `high` by a knob along a track: the audio screen's volumes
/// and the video screen's brightness. Its row is `down` pixels from the middle of the screen, the
/// track starting 16 to the right of the middle with its label before it.
pub const Slider = struct {
    down: i32,
    label: String,
    low: f32,
    high: f32,

    /// How far the knob's middle travels along the track, from where it starts, in the menu's
    /// pixels.
    const travel = 171;
    const start = 24;

    pub fn track(slider: Slider) Item {
        return .{
            .anchor = .{ 0.5, 0.5 },
            .offset = .{ 16, slider.down },
            .place = .{ .across = .start },
            .shape = .track,
            .text_offset = .{ -32, -6 },
            .font = .small,
            .string = slider.label,
            .style = .{ .alignment = .right },
        };
    }

    /// The knob, where `value` puts it.
    pub fn knob(slider: Slider, value: f32) Item {
        const along = (value - slider.low) / (slider.high - slider.low) * travel + start;
        return .{ .anchor = .{ 0.5, 0.5 }, .offset = .{ round(along), slider.down }, .shape = .knob, .lit = .knob };
    }

    /// The value the pointer at `x` across the screen drags the knob to, within the slider's.
    pub fn valueAt(slider: Slider, ui: Ui, x: i32) f32 {
        const along = ui.unscaled(x - ui.across(0.5)) - start;
        return std.math.clamp(along / travel * (slider.high - slider.low) + slider.low, slider.low, slider.high);
    }
};

/// A setting stepped back and forth through its values by the arrows of a box, its value written
/// to the right of the middle: the video screen's default view. Its row is `down` pixels from the
/// middle of the screen, the box ending 16 to the left of it with its label before it.
pub const Selector = struct {
    down: i32,
    label: String,

    pub const Part = enum { box, back, forward, value };
    pub const Items = std.EnumArray(Part, Item);

    /// The box and its value, and the halves that light as the pointer finds them.
    pub fn items(selector: Selector, value: String) Items {
        const ends: Place = .{ .across = .end };
        return .init(.{
            .box = .{
                .anchor = .{ 0.5, 0.5 },
                .offset = .{ -16, selector.down },
                .place = ends,
                .shape = .arrows,
                .text_offset = .{ -41, -6 },
                .font = .small,
                .string = selector.label,
                .style = .{ .alignment = .right },
            },
            .back = .{ .anchor = .{ 0.5, 0.5 }, .offset = .{ -33, selector.down }, .place = ends, .lit = .arrow_back },
            .forward = .{ .anchor = .{ 0.5, 0.5 }, .offset = .{ -16, selector.down }, .place = ends, .lit = .arrow_forward },
            .value = .{ .anchor = .{ 0.5, 0.5 }, .offset = .{ 16, selector.down }, .place = .{ .across = .start }, .text_offset = .{ 0, -6 }, .font = .small, .string = value },
        });
    }

    /// Which way choosing `part` steps: back, forward, or nowhere.
    pub fn step(part: Part) i32 {
        return switch (part) {
            .back => -1,
            .forward => 1,
            .box, .value => 0,
        };
    }
};

test "Selector.step" {
    try std.testing.expectEqual(-1, Selector.step(.back));
    try std.testing.expectEqual(1, Selector.step(.forward));
    try std.testing.expectEqual(0, Selector.step(.box));
    try std.testing.expectEqual(0, Selector.step(.value));
}

test "the menus' colours" {
    try std.testing.expectEqual([3]f32{ 254.0 / 255.0, 133.0 / 255.0, 26.0 / 255.0 }, orange);
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, lit(white, 0.5));
}

test "Pointer.update" {
    var pointer: Pointer = .{};
    // Before the mouse has been over the window, the pointer stays where it starts.
    pointer.update(.{}, .{ 1024, 768 });
    try std.testing.expectEqual([2]i32{ 320, 240 }, pointer.at);
    // Then it is where the mouse is, on the screen; a button going down is pressed for a frame.
    pointer.update(.{ .at = .{ 0.5, 1.5 }, .buttons = .{ .right = true } }, .{ 1024, 768 });
    try std.testing.expectEqual([2]i32{ 512, 767 }, pointer.at);
    try std.testing.expect(pointer.down and pointer.pressed and !pointer.released);
    pointer.update(.{ .at = .{ 0.5, 0.5 }, .buttons = .{ .right = true } }, .{ 1024, 768 });
    try std.testing.expect(pointer.down and !pointer.pressed);
    pointer.update(.{ .at = .{ 0.5, 0.5 } }, .{ 1024, 768 });
    try std.testing.expect(!pointer.down and pointer.released);
}

test "Place.Edge.lead" {
    try std.testing.expectEqual(12, Place.Edge.centre.lead(24));
    try std.testing.expectEqual(0, Place.Edge.start.lead(24));
    try std.testing.expectEqual(0, Place.Edge.none.lead(24));
    try std.testing.expectEqual(24, Place.Edge.end.lead(24));
}

test Slider {
    // A volume's knob runs from 24 to 195 across the middle of the screen, as the game draws it.
    const volume: Slider = .{ .down = -30, .label = .sound_effects_volume, .low = 0, .high = 127 };
    try std.testing.expectEqual([2]i32{ 24, -30 }, volume.knob(0).offset);
    try std.testing.expectEqual([2]i32{ 195, -30 }, volume.knob(127).offset);
    try std.testing.expectEqual([2]i32{ 78, -30 }, volume.knob(40).offset);
    // The brightness's knob, 114 pixels to a step of 1, as the game works it out.
    const brightness: Slider = .{ .down = -30, .label = .brightness, .low = 0.5, .high = 2 };
    try std.testing.expectEqual(24 + 114, brightness.knob(1.5).offset[0]);

    // The pointer drags the knob to its value, within the range, drawn twice as large or not.
    for ([_]f32{ 1, 2 }) |scale| {
        var ui: Ui = undefined;
        ui.screen = .{ 1024, 768 };
        ui.scale = scale;
        const middle = ui.across(0.5);
        try std.testing.expectEqual(0, volume.valueAt(ui, middle));
        try std.testing.expectApproxEqAbs(40, volume.valueAt(ui, middle + ui.scaled(78)), 0.5);
        try std.testing.expectEqual(127, volume.valueAt(ui, middle + ui.scaled(400)));
        try std.testing.expectApproxEqAbs(1.5, brightness.valueAt(ui, middle + ui.scaled(24 + 114)), 0.001);
    }
}

test Box {
    const box: Box = .{ .at = .{ 10, 20 }, .size = .{ 24, 15 } };
    try std.testing.expect(box.holds(.{ 10, 20 }));
    try std.testing.expect(box.holds(.{ 33, 34 }));
    try std.testing.expect(!box.holds(.{ 34, 20 }));
    try std.testing.expect(!box.holds(.{ 10, 35 }));
}

test button {
    // A button right of the middle is labelled to its right, one left of it to its left.
    try std.testing.expectEqual(Alignment.left, buttons.ok.style.alignment);
    try std.testing.expectEqual([2]i32{ 25, -5 }, buttons.ok.text_offset);
    try std.testing.expectEqual(Alignment.right, buttons.restart.style.alignment);
    try std.testing.expectEqual([2]i32{ -25, -5 }, buttons.restart.text_offset);
}

test Item {
    // The game's own encoding: placed 0x11, centred both ways, and text right-aligned and dimmed
    // as 0xA.
    try std.testing.expectEqual(0x11, @as(u32, @bitCast(Place{})));
    try std.testing.expectEqual(0x12, @as(u32, @bitCast(Place{ .across = .start })));
    try std.testing.expectEqual(0xA, @as(u32, @bitCast(Item.Style{ .alignment = .right, .dimmed = true })));
    try std.testing.expectEqual(null, Item.none.boxShape());
    const arrow: Item = .{ .anchor = .{ 0.5, 0.5 }, .lit = .arrow_back };
    try std.testing.expectEqual(Shape.arrow_back, arrow.boxShape().?);
}
