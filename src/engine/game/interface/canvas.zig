//! The front end's screen, which `interface.cpp` lays out in pixels of a 640 by 480 screen, the
//! mode the game runs its front end in, and the pointer that moves over it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const spr = @import("../../../formats/spr.zig");
const device = @import("../../surrender/srd3d/device.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const input = @import("../../input.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");

/// The front end's screen in pixels.
pub const size: [2]i32 = .{ 640, 480 };

pub const Error = spr.Error || Allocator.Error;

/// The colours the front end ramps its text through (`0x004287C0`), from a `0xRRGGBB` value.
pub const blue = hud.rgb(0x40BCFF);
pub const gold = hud.rgb(0xFDB951);
pub const red = hud.rgb(0xFF0000);

/// The front end's fonts, which its start-up opens (`0x004288E0`): `interface\optfnt.fnt` and
/// `interface\smlfnt2.fnt`, the pause menu's too.
pub const Fonts = struct {
    large: *hud.Opened,
    small: *hud.Opened,
};

/// Where the front end draws, and with what.
///
/// **Improvement.** The game switches the display to 640 by 480 for its front end, which then
/// fills the screen. OpenReliant keeps the window as it is and draws the front end as large as fits
/// in it, centred, so that it keeps its shape (`scaleFor`).
pub const Canvas = struct {
    gpa: Allocator,
    target: device.Device,
    /// The window's size in pixels.
    window: [2]u32,
    fonts: Fonts,
    strings: *const language.Language,

    /// How many of the window's pixels one of the front end's spans.
    pub fn scale(canvas: Canvas) f32 {
        return scaleFor(canvas.window);
    }

    /// Where the front end's top left corner stands in the window.
    pub fn corner(canvas: Canvas) [2]f32 {
        return cornerFor(canvas.window);
    }

    /// Where `at`, a point of the front end's screen, stands in the window.
    pub fn point(canvas: Canvas, at: [2]i32) [2]i32 {
        const s = canvas.scale();
        const from = canvas.corner();
        var out: [2]i32 = undefined;
        for (&out, from, at) |*pixel, start, offset| pixel.* = hud.round(start + @as(f32, @floatFromInt(offset)) * s);
        return out;
    }

    /// Draws `index` of `art` with its anchor at `at` (`VFX_shape_draw`).
    pub fn shape(canvas: Canvas, art: *hud.Art, index: usize, at: [2]i32) Error!void {
        try hud.drawShape(art, canvas.gpa, canvas.target, index, canvas.point(at), .{ 1, 1, 1, 1 }, canvas.scale());
    }

    /// Draws `picture` with its top left corner at `at`.
    pub fn image(canvas: Canvas, picture: *srtexture.Image, at: [2]i32) void {
        const s = canvas.scale();
        const from = canvas.corner();
        var left: [2]f32 = undefined;
        for (&left, from, at) |*pixel, start, offset| pixel.* = start + @as(f32, @floatFromInt(offset)) * s;
        hud.drawImage(canvas.target, picture, left, .{ 1, 1, 1, 1 }, s, .{});
    }

    /// Writes `words` in `font` at `at`, ramped through `colour` (`hud_text`).
    pub fn text(canvas: Canvas, font: *hud.Opened, at: [2]i32, words: []const u8, colour: [3]f32, alignment: hud.Align) Allocator.Error!void {
        _ = try hud.drawText(font, canvas.gpa, canvas.target, canvas.point(at), words, hud.atBrightness(colour, 1), alignment, canvas.scale());
    }

    /// `hud_text_wrapped` (`0x00480FD0`): `words` broken into lines at most `lines.width` of the
    /// front end's pixels wide, at most `lines.most` of them, each `lines.height` below the last.
    pub fn wrapped(canvas: Canvas, font: *hud.Opened, at: [2]i32, words: []const u8, colour: [3]f32, alignment: hud.Align, lines: Lines) Allocator.Error!void {
        var wrapping: hud.WrappedText = .init(&font.widths, words, lines.width, lines.most);
        var y = at[1];
        while (wrapping.next()) |shown| : (y += lines.height) try canvas.text(font, .{ at[0], y }, shown, colour, alignment);
    }

    /// How `wrapped` lays its lines out.
    pub const Lines = struct { width: i32, height: i32, most: usize };

    /// Writes the string of `id` (`language_string`); one the game doesn't have writes nothing.
    pub fn string(canvas: Canvas, font: *hud.Opened, at: [2]i32, id: u32, colour: [3]f32, alignment: hud.Align) Allocator.Error!void {
        const words = canvas.strings.string(id) orelse return;
        try canvas.text(font, at, words, colour, alignment);
    }
};

/// How many of a window's pixels one of the front end's spans in a window of `window`: as many as
/// fit the front end in it.
pub fn scaleFor(window: [2]u32) f32 {
    var least: f32 = std.math.floatMax(f32);
    for (window, size) |pixels, across| least = @min(least, @as(f32, @floatFromInt(pixels)) / @as(f32, @floatFromInt(across)));
    return least;
}

/// Where the front end's top left corner stands in a window of `window`, which centres it.
pub fn cornerFor(window: [2]u32) [2]f32 {
    const s = scaleFor(window);
    var from: [2]f32 = undefined;
    for (&from, window, size) |*start, pixels, across| start.* = (@as(f32, @floatFromInt(pixels)) - @as(f32, @floatFromInt(across)) * s) / 2;
    return from;
}

/// A rectangle of the front end's screen, as its tables keep one: its corner and its size.
pub const Rect = extern struct {
    x: i16,
    y: i16,
    width: i16,
    height: i16,

    /// Whether `at` lies inside it, its edges left out (`0x0043EB30`).
    pub fn holds(rect: Rect, at: [2]i32) bool {
        return rect.x < at[0] and at[0] < @as(i32, rect.x) + rect.width and rect.y < at[1] and at[1] < @as(i32, rect.y) + rect.height;
    }
};

/// `0x0043EB30`: the first of `rects` that holds `at`, or null for none.
pub fn hit(rects: []const Rect, at: [2]i32) ?usize {
    for (rects, 0..) |rect, index| if (rect.holds(at)) return index;
    return null;
}

/// The front end's pointer (`0x00520274`, `0x00520270`), its buttons and its animation.
pub const Pointer = struct {
    /// Where it points on the front end's screen.
    at: [2]i32 = .{ 320, 200 },
    /// Whether the left button is down (`0x0051DA0C`), and the right (`0x0051D9D4`).
    down: bool = false,
    right_down: bool = false,
    /// The ticks into its animation (`0x0051DABC`), which runs through its shapes a shape every
    /// `ticks_per_shape` ticks.
    ticks: i32 = 0,

    pub const shapes = 16;
    pub const ticks_per_shape = 4;

    /// `0x004360D0`, once a frame, `elapsed` ticks after the last: the buttons as the mouse has
    /// them, and the animation on.
    ///
    /// **Improvement.** The pointer is where the system's is, over the window, as the pause menu's
    /// is. The game adds up DirectInput's movements from where its pointer last stood.
    pub fn update(pointer: *Pointer, mouse: input.Mouse, window: [2]u32, elapsed: i32) void {
        if (mouse.at) |share| {
            const s = scaleFor(window);
            const from = cornerFor(window);
            for (&pointer.at, share, window, from, size) |*at, fraction, pixels, start, across| {
                const on_screen = fraction * @as(f32, @floatFromInt(pixels));
                at.* = std.math.clamp(hud.round((on_screen - start) / s), 0, across - 1);
            }
        }
        pointer.down = mouse.buttons.left;
        pointer.right_down = mouse.buttons.right;
        pointer.ticks += elapsed;
        if (pointer.ticks >= shapes * ticks_per_shape) pointer.ticks = 0;
    }

    /// The shape it shows, from 1 to `shapes`.
    pub fn shape(pointer: Pointer) usize {
        return @intCast(@divTrunc(pointer.ticks, ticks_per_shape) + 1);
    }
};

test scaleFor {
    try std.testing.expectEqual(1, scaleFor(.{ 640, 480 }));
    try std.testing.expectEqual(2, scaleFor(.{ 1280, 960 }));
    // A wide window fits its height, a tall one its width.
    try std.testing.expectEqual(2.25, scaleFor(.{ 1920, 1080 }));
    try std.testing.expectEqual(1.5, scaleFor(.{ 960, 1080 }));
    try std.testing.expectEqual(0.5, scaleFor(.{ 320, 240 }));
    // Centred.
    try std.testing.expectEqual([2]f32{ 240, 0 }, cornerFor(.{ 1920, 1080 }));
    try std.testing.expectEqual([2]f32{ 0, 180 }, cornerFor(.{ 960, 1080 }));
    try std.testing.expectEqual([2]f32{ 0, 0 }, cornerFor(.{ 640, 480 }));
}

test hit {
    const rects = [_]Rect{
        .{ .x = 27, .y = 123, .width = 184, .height = 290 },
        .{ .x = 332, .y = 441, .width = 20, .height = 15 },
    };
    try std.testing.expectEqual(0, hit(&rects, .{ 100, 200 }));
    try std.testing.expectEqual(1, hit(&rects, .{ 340, 450 }));
    // The edges are left out.
    try std.testing.expectEqual(null, hit(&rects, .{ 27, 200 }));
    try std.testing.expectEqual(null, hit(&rects, .{ 211, 200 }));
    try std.testing.expectEqual(null, hit(&rects, .{ 600, 20 }));
}

test Pointer {
    var pointer: Pointer = .{};
    // With the system's pointer not yet over the window, it stays where it starts.
    pointer.update(.{}, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 320, 200 }, pointer.at);
    // The middle of a wide window is the middle of the front end's screen.
    pointer.update(.{ .at = .{ 0.5, 0.5 } }, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 320, 240 }, pointer.at);
    // Beside it, it keeps to its edge.
    pointer.update(.{ .at = .{ 0.9, 0 } }, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 639, 0 }, pointer.at);
    // Out beside the front end's screen, it keeps to its edge.
    pointer.update(.{ .at = .{ 0.01, 0.5 } }, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual(0, pointer.at[0]);
    // The animation runs through the sixteen shapes, then from the first again.
    pointer.ticks = 0;
    pointer.update(.{}, .{ 640, 480 }, 3);
    try std.testing.expectEqual(1, pointer.shape());
    pointer.update(.{}, .{ 640, 480 }, 60);
    try std.testing.expectEqual(16, pointer.shape());
    pointer.update(.{}, .{ 640, 480 }, 1);
    try std.testing.expectEqual(0, pointer.ticks);
}
