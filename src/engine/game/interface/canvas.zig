//! The front end's screen, which `interface.cpp` lays out in pixels of a 640 by 480 screen, the
//! mode the game runs its front end in, and the pointer that moves over it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fnt = @import("../../../formats/fnt.zig");
const spr = @import("../../../formats/spr.zig");
const bigfile = @import("../bigfile.zig");
const device = @import("../../surrender/srd3d/device.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srd3d = @import("../../surrender/srd3d/srd3d.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const input = @import("../../input.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");

const log = std.log.scoped(.interface);

/// The front end's screen in pixels, the mode returning from a mission sets the display to
/// (`0x004AD2E0`).
pub const size: [2]u32 = .{ 640, 480 };

pub const Error = spr.Error || Allocator.Error;

/// The colours the front end ramps its text through (`interface_palette_ramp`, `0x004287C0`),
/// from a `0xRRGGBB` value: the main menu's labels and the dialogs, a panel's labels under the
/// pointer, the developers' text, and a button's label under the pointer, the pilot roster's
/// call signs among them.
pub const blue = hud.rgb(0x40BCFF);
pub const gold = hud.rgb(0xFDB951);
pub const red = hud.rgb(0xFF0000);
pub const white = hud.rgb(0xFFFFFF);

/// The black the pilot roster's list rows are wiped to, and the middle of ABOUT OPENRELIANT's box.
pub const black = hud.rgb(0x000000);

/// The front end's fonts, which its start-up opens (`interface_init`, `0x004288E0`):
/// `hud.large_menu_font` and `hud.small_menu_font`, the pause menu's too.
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
    /// OpenReliant's version, which a screen writes in the window's corner (`drawVersion`); null
    /// for none.
    version: ?[]const u8 = null,
    /// The palette's brightness the screen's shapes and text are drawn at
    /// (`palette_ramp_brightness`): 1, but as a screen fades in or out.
    brightness: f32 = 1,
    /// The rectangle of the front end's screen its shapes and text are cut to, as a VFX pane
    /// clips what is drawn into it; null for the whole screen.
    clip: ?Rect = null,

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
        try hud.drawShapeWith(art, canvas.gpa, canvas.target, index, canvas.point(at), hud.atBrightness(.{ 1, 1, 1 }, canvas.brightness), canvas.scale(), .{ .clip = canvas.cut() });
    }

    /// The canvas cut to `rect` of the front end's screen, within any cut it has already.
    pub fn within(canvas: Canvas, rect: Rect) Canvas {
        var inside = canvas;
        inside.clip = if (canvas.clip) |outer| outer.intersect(rect) else rect;
        return inside;
    }

    /// Where its clip lies in the window; null for none.
    fn cut(canvas: Canvas) ?hud.Clip {
        const rect = canvas.clip orelse return null;
        const s = canvas.scale();
        const from = canvas.corner();
        const left = from[0] + @as(f32, @floatFromInt(rect.x)) * s;
        const top = from[1] + @as(f32, @floatFromInt(rect.y)) * s;
        return .{ .left = left, .top = top, .right = left + @as(f32, @floatFromInt(rect.width)) * s, .bottom = top + @as(f32, @floatFromInt(rect.height)) * s };
    }

    /// Draws `picture` behind the front end's screen as the device draws a background
    /// (`matmanager.Background`, `srd3d.backgroundEdges`): as high as the screen, keeping its
    /// proportions, and centred across it. A 4:3 picture covers the screen, whatever its size, and
    /// a wider one reaches past its sides into a wider window.
    pub fn fill(canvas: Canvas, picture: *srtexture.Image) void {
        const s = canvas.scale();
        const from = canvas.corner();
        const screen: [4]f32 = .{ from[0], from[1], from[0] + @as(f32, @floatFromInt(size[0])) * s, from[1] + @as(f32, @floatFromInt(size[1])) * s };
        const left, const top, const right, const bottom = srd3d.backgroundEdges(picture, screen);
        hud.drawImageOver(canvas.target, picture, .{ .left = left, .top = top, .right = right, .bottom = bottom }, .{ 1, 1, 1, 1 });
    }

    /// Draws a line in `colour` from the pixel at `from` to the pixel at `to`, both included
    /// (`VFX_line_draw`).
    pub fn line(canvas: Canvas, from: [2]i32, to: [2]i32, colour: [3]f32) void {
        hud.drawLine(canvas.target, canvas.pixelAt(from), canvas.pixelAt(to), hud.atBrightness(colour, 1), canvas.scale());
    }

    /// Fills the pixels from `from` to `to`, both included, with `colour` (`VFX_pane_wipe`).
    pub fn wipe(canvas: Canvas, from: [2]i32, to: [2]i32, colour: [3]f32) void {
        const s = canvas.scale();
        const start = canvas.pixelAt(from);
        const end = canvas.pixelAt(to);
        hud.drawFilled(canvas.target, .{ .left = start[0], .top = start[1], .right = end[0] + s, .bottom = end[1] + s }, hud.atBrightness(colour, 1));
    }

    /// `interface_box` (`0x00435C60`): the frame round a box `extent` across and down from `at`, at a
    /// brightness of 1. Its top and left edges are light (`box_light`), its right and bottom dark
    /// (`box_dark`), each a pixel short of the corner the other starts from, and a pixel in runs a
    /// second frame, all in between (`box_inner`).
    pub fn box(canvas: Canvas, at: [2]i32, extent: [2]i32) void {
        const x = at[0];
        const y = at[1];
        const right = x + extent[0];
        const bottom = y + extent[1];
        canvas.line(.{ x, y }, .{ right, y }, box_light);
        canvas.line(.{ x, y }, .{ x, bottom }, box_light);
        canvas.line(.{ right, y + 1 }, .{ right, bottom }, box_dark);
        canvas.line(.{ right, bottom }, .{ x + 1, bottom }, box_dark);
        canvas.line(.{ x + 1, y + 1 }, .{ right - 1, y + 1 }, box_inner);
        canvas.line(.{ x + 1, bottom - 1 }, .{ right - 1, bottom - 1 }, box_inner);
        canvas.line(.{ x + 1, y + 1 }, .{ x + 1, bottom - 1 }, box_inner);
        canvas.line(.{ right - 1, y + 1 }, .{ right - 1, bottom - 1 }, box_inner);
    }

    /// Where the pixel at `at`, a point of the front end's screen, starts in the window.
    fn pixelAt(canvas: Canvas, at: [2]i32) hud.Point {
        const s = canvas.scale();
        const from = canvas.corner();
        return .{ from[0] + @as(f32, @floatFromInt(at[0])) * s, from[1] + @as(f32, @floatFromInt(at[1])) * s };
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
        _ = try hud.drawTextIn(font, canvas.gpa, canvas.target, canvas.point(at), words, hud.atBrightness(colour, canvas.brightness), alignment, canvas.scale(), canvas.cut());
    }

    /// `hud_text_wrapped` (`0x00480FD0`): `words` broken into lines at most `lines.width` of the
    /// front end's pixels wide, at most `lines.most` of them, each `lines.height` below the last.
    pub fn wrapped(canvas: Canvas, font: *hud.Opened, at: [2]i32, words: []const u8, colour: [3]f32, alignment: hud.Align, lines: Lines) Allocator.Error!void {
        var wrapping: hud.WrappedText = .init(&font.widths, words, lines.width, lines.most);
        var y = at[1];
        while (wrapping.next()) |shown| : (y += lines.height) try canvas.text(font, .{ at[0], y }, shown, colour, alignment);
    }

    /// How `wrapped` lays its lines out.
    pub const Lines = struct {
        width: i32,
        height: i32,
        most: usize,

        /// How many lines `words` break into in `font`, at most `most`.
        pub fn count(lines: Lines, font: *hud.Opened, words: []const u8) usize {
            var wrapping: hud.WrappedText = .init(&font.widths, words, lines.width, lines.most);
            var n: usize = 0;
            while (wrapping.next()) |_| n += 1;
            return n;
        }
    };

    /// **Improvement:** OpenReliant's version, where the canvas has one, in the window's bottom
    /// right corner as the pause menu writes it (`hud.drawVersion`). A screen writes it before its
    /// pointer.
    pub fn drawVersion(canvas: Canvas) Allocator.Error!void {
        const shown = canvas.version orelse return;
        try hud.drawVersion(canvas.fonts.small, canvas.gpa, canvas.target, canvas.window, shown);
    }

    /// The canvas at half brightness where `usable` is false, as the front end dims what can't be
    /// used (`palette_ramp_brightness` 0.5).
    pub fn dimmedUnless(canvas: Canvas, usable: bool) Canvas {
        var shown = canvas;
        if (!usable) shown.brightness = dimmed;
        return shown;
    }

    /// Writes the string of `id` (`language_string`); one the game doesn't have writes nothing.
    pub fn string(canvas: Canvas, font: *hud.Opened, at: [2]i32, id: u32, colour: [3]f32, alignment: hud.Align) Allocator.Error!void {
        const words = canvas.strings.string(id) orelse return;
        try canvas.text(font, at, words, colour, alignment);
    }
};

/// The brightness what can't be used is dimmed to (`dimmedUnless`).
pub const dimmed = 0.5;

/// `interface_box`'s colours at a brightness of 1 (`0x004DC6D0`, `0x004DC6CC`; `0x004DC6C8`,
/// `0x004DC6C4`; `0x004DC6C0`, `0x004DC6BC`), in 255ths: no red, and green and blue.
const box_light = hud.rgb(0x00A7FF);
const box_dark = hud.rgb(0x005785);
const box_inner = hud.rgb(0x0086CD);

/// How many of a window's pixels one of the front end's spans in a window of `window`: as many as
/// fit the front end in it.
pub fn scaleFor(window: [2]u32) f32 {
    return hud.fit(window, size);
}

/// Where the front end's top left corner stands in a window of `window`, which centres it.
pub fn cornerFor(window: [2]u32) [2]f32 {
    return hud.centred(window, size, scaleFor(window));
}

/// How the renderer projects onto the front end's screen (`renderer_start`, `0x004ACC6B`): over
/// the whole of it, by `factors`, carried into the part of a window of `window` the screen fills
/// (`scaleFor`, `cornerFor`), so that what is drawn in 3D stands where the screen's pictures do.
pub fn projection(window: [2]u32, factors: [2]f32) srapi.Projection {
    var fitted: srapi.Projection = .init(size[0], size[1], srapi.full_screen, factors);
    const scale = scaleFor(window);
    const corner = cornerFor(window);
    fitted.screen = window;
    for (0..2) |axis| {
        fitted.scale[axis] *= scale;
        fitted.centre[axis] = corner[axis] + fitted.centre[axis] * scale;
        for ([2]usize{ axis, axis + 2 }) |edge| fitted.viewport[edge] = corner[axis] + fitted.viewport[edge] * scale;
    }
    return fitted;
}

/// Where the point `at` of the front end's screen stands in a window of `window`, in its pixels.
pub fn inWindow(window: [2]u32, at: [2]i32) [2]i32 {
    const scale = scaleFor(window);
    const corner = cornerFor(window);
    var placed: [2]i32 = undefined;
    for (&placed, at, corner) |*axis, point, start| axis.* = @intFromFloat(@round(start + @as(f32, @floatFromInt(point)) * scale));
    return placed;
}

test projection {
    // At the screen's own size, the renderer's own projection.
    const own = projection(size, .{ 0.6, 0.8 });
    const renderer: srapi.Projection = .init(640, 480, srapi.full_screen, .{ 0.6, 0.8 });
    try std.testing.expectEqual(renderer.scale, own.scale);
    try std.testing.expectEqual(renderer.centre, own.centre);
    // Fitted into a wider window, half as large again and centred across it.
    const wide = projection(.{ 1280, 720 }, .{ 0.6, 0.8 });
    try std.testing.expectEqual([2]f32{ 640, 360 }, wide.centre);
    try std.testing.expectApproxEqAbs(renderer.scale[0] * 1.5, wide.scale[0], 1e-3);
    try std.testing.expectEqual([4]f32{ 160, 0, 1120, 720 }, wide.viewport);
    try std.testing.expectEqual([2]i32{ 640, 360 }, inWindow(.{ 1280, 720 }, .{ 320, 240 }));
}

/// A sprite set read whole, as `hog_load` reads one, and the shapes made of it.
pub const Shapes = struct {
    art: hud.Art,
    bytes: []u8,

    /// The shapes of `bytes`, the sprite set `name`, which they keep, with `pictures` in their
    /// place; null where it is not one, the bytes then freed.
    pub fn of(gpa: Allocator, bytes: []u8, name: []const u8, pictures: ?hud.Art.Pictures) ?Shapes {
        const set = spr.Sprite.parse(bytes) catch |err| {
            log.warn("{s} is left out: {s}", .{ name, @errorName(err) });
            gpa.free(bytes);
            return null;
        };
        const art = hud.Art.init(gpa, set, null, pictures) catch {
            gpa.free(bytes);
            return null;
        };
        return .{ .art = art, .bytes = bytes };
    }

    /// The sprite set `name` of `archive`, with the pictures its mods give in its shapes' place;
    /// null where it is left out.
    pub fn read(gpa: Allocator, archive: *const bigfile.Hog, name: []const u8) ?Shapes {
        const bytes = archive.readFile(gpa, name) catch |err| {
            log.warn("{s} is left out: {s}", .{ name, @errorName(err) });
            return null;
        };
        return of(gpa, bytes, name, .of(archive.mods, name));
    }

    /// Drawn with block `palette`'s palette as VFX's global one, as `palette_to_vfx`
    /// (`0x00428410`) makes it of a set's block; each shape with its own where the block is not a
    /// palette.
    pub fn usePalette(shapes: *Shapes, palette: usize) void {
        shapes.art.global = shapes.art.set.paletteAt(palette);
    }

    pub fn deinit(shapes: *Shapes, gpa: Allocator) void {
        shapes.art.deinit(gpa);
        gpa.free(shapes.bytes);
    }
};

/// A font read whole, as `hog_load` reads one, and opened (`font_open`), its levels ramped
/// through the colour it is drawn in (`hud.Opened.ramp`): the ITAC's and the simulator pod's.
pub const FontFile = struct {
    bytes: []u8,
    font: hud.Opened,

    /// The font `name` of `archive`; null where it is left out, which the log says.
    pub fn read(gpa: Allocator, archive: *const bigfile.Hog, name: []const u8) ?FontFile {
        const bytes = archive.readFile(gpa, name) catch |err| {
            log.warn("{s} is left out: {s}", .{ name, @errorName(err) });
            return null;
        };
        const parsed = fnt.Font.parse(bytes) catch |err| {
            log.warn("{s} is left out: {s}", .{ name, @errorName(err) });
            gpa.free(bytes);
            return null;
        };
        return .{ .bytes = bytes, .font = .ramp(parsed) };
    }

    pub fn deinit(file: *FontFile, gpa: Allocator) void {
        file.font.deinit(gpa);
        gpa.free(file.bytes);
    }
};

/// A line of a screen's text: a string of the game's (`language_string`), or OpenReliant's words,
/// where it stands, and how it lines up there.
pub const Label = struct {
    text: Text,
    at: [2]i32,
    alignment: hud.Align = .left,

    pub const Text = union(enum) {
        string: u32,
        words: []const u8,
    };

    /// The game's string `id`, at `at`, lined up by `alignment`.
    pub fn of(id: u32, at: [2]i32, alignment: hud.Align) Label {
        return .{ .text = .{ .string = id }, .at = at, .alignment = alignment };
    }

    /// Writes it in `font`, ramped through `colour`.
    pub fn write(label: Label, canvas: Canvas, font: *hud.Opened, colour: [3]f32) Allocator.Error!void {
        switch (label.text) {
            .string => |id| try canvas.string(font, label.at, id, colour, label.alignment),
            .words => |words| try canvas.text(font, label.at, words, colour, label.alignment),
        }
    }
};

/// A button of the front end's screens: its shape, with its corner at `at`, and its label beside it
/// in the small font, blue, or white over the lit shape while it is under the pointer.
pub const Button = struct {
    at: [2]i32,
    label: Label,

    /// The shapes of a screen's set a button is drawn with: as it stands, and lit.
    pub const Pair = struct { off: usize, lit: usize };

    pub fn draw(button: Button, canvas: Canvas, art: *hud.Art, shapes: Pair, lit: bool) Error!void {
        try canvas.shape(art, if (lit) shapes.lit else shapes.off, button.at);
        try button.label.write(canvas, canvas.fonts.small, if (lit) white else blue);
    }
};

/// A list's arrows, which scroll it a row up or down.
pub const Arrow = enum { up, down };

/// A list that shows `shown` of its `count` rows, from `first` on, which its arrows scroll; counted
/// in `Int`, as the screen keeps it.
pub fn Scrolled(comptime Int: type) type {
    return struct {
        first: Int = 0,
        count: Int = 0,
        shown: Int,

        const List = @This();

        /// The list a row on, or back, where it holds more than it shows and the last, or the
        /// first, is not shown.
        pub fn scroll(list: *List, way: Arrow) void {
            if (list.count <= list.shown) return;
            switch (way) {
                .down => if (list.first + list.shown < list.count) {
                    list.first += 1;
                },
                .up => list.first -|= 1,
            }
        }

        /// Where the rows shown end: at the list's end, or past the last shown.
        pub fn end(list: List) Int {
            return @min(list.count, list.first + list.shown);
        }

        /// The list scrolled by the wheel's `notches`, `notch_rows` rows each, up for a notch up,
        /// as far as it scrolls.
        pub fn wheel(list: *List, notches: i32) void {
            const way: Arrow = if (notches > 0) .up else .down;
            for (0..@abs(notches) * notch_rows) |_| list.scroll(way);
        }
    };
}

/// The rows a notch of the mouse's wheel scrolls a list (`Scrolled.wheel`), as the system scrolls
/// text by default.
pub const notch_rows = 3;

/// A rectangle of the front end's screen, as its tables keep one: its corner and its size.
pub const Rect = extern struct {
    x: i16,
    y: i16,
    width: i16,
    height: i16,

    /// Whether `at` lies inside it, its edges left out, as `interface_hit` tests.
    pub fn holds(rect: Rect, at: [2]i32) bool {
        return rect.x < at[0] and at[0] < @as(i32, rect.x) + rect.width and rect.y < at[1] and at[1] < @as(i32, rect.y) + rect.height;
    }

    /// What lies inside both.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const left = @max(a.x, b.x);
        const top = @max(a.y, b.y);
        const right = @min(@as(i32, a.x) + a.width, @as(i32, b.x) + b.width);
        const bottom = @min(@as(i32, a.y) + a.height, @as(i32, b.y) + b.height);
        return .{ .x = left, .y = top, .width = @intCast(@max(right - left, 0)), .height = @intCast(@max(bottom - top, 0)) };
    }
};

comptime {
    std.debug.assert(@sizeOf(Rect) == 8);
}

/// `interface_hit` (`0x0043EB30`): the first of `rects` that holds `at`, or null for none.
///
/// **Unverified:** the file. It lies after `interface.cpp`'s known code and before `itac.cpp`'s,
/// and every caller is one of the front end's screens, so it goes with `interface.cpp`.
pub fn hit(rects: []const Rect, at: [2]i32) ?usize {
    for (rects, 0..) |rect, index| if (rect.holds(at)) return index;
    return null;
}

/// `hit` over a screen's items, each with its rectangle: the first item that holds `at`.
pub fn itemAt(comptime Item: type, rects: *const std.EnumArray(Item, Rect), at: [2]i32) ?Item {
    const index = hit(&rects.values, at) orelse return null;
    return std.EnumArray(Item, Rect).Indexer.keyForIndex(index);
}

/// The front end's pointer (`interface_pointer_x`, `interface_pointer_y`), its buttons and its
/// animation.
pub const Pointer = struct {
    /// Where it points on the front end's screen: (320, 200) as the main menu starts.
    at: [2]i32 = .{ 320, 200 },
    /// Whether the left button is down (`interface_pointer_down`), and the right
    /// (`interface_pointer_right_down`).
    down: bool = false,
    right_down: bool = false,
    /// The mouse wheel's whole notches turned since the last pass, positive to scroll up
    /// (`input.Mouse.notches`).
    wheel: i32 = 0,
    /// The ticks into its animation (`interface_pointer_ticks`), which runs through its shapes a
    /// shape every `ticks_per_shape` ticks.
    ticks: i32 = 0,

    /// The animation's shapes, 1 to 16 of the screen's set, and how long each shows: the ticks
    /// wrap at 64 (`0x00436103`), and the drawing takes the shape `ticks / 4 + 1` (`0x0042961C`).
    pub const shapes = 16;
    pub const ticks_per_shape = 4;

    /// `interface_pointer_update` (`0x004360D0`), once a frame, `elapsed` ticks after the last:
    /// the buttons as the mouse has them, and the animation on.
    ///
    /// **Improvement.** The pointer is where the system's is, over the window, as the pause menu's
    /// is. The game adds up DirectInput's movements from where its pointer last stood.
    ///
    /// **Improvement.** It takes the wheel's notches, which scroll the lists; the game reads no
    /// wheel.
    pub fn update(pointer: *Pointer, mouse: *input.Mouse, window: [2]u32, elapsed: i32) void {
        if (mouse.at) |share| {
            const s = scaleFor(window);
            const from = cornerFor(window);
            for (&pointer.at, share, window, from, size) |*at, fraction, pixels, start, across| {
                const on_screen = fraction * @as(f32, @floatFromInt(pixels));
                at.* = std.math.clamp(hud.round((on_screen - start) / s), 0, @as(i32, @intCast(across)) - 1);
            }
        }
        pointer.down = mouse.buttons.left;
        pointer.right_down = mouse.buttons.right;
        pointer.wheel = mouse.notches();
        pointer.ticks += elapsed;
        if (pointer.ticks >= shapes * ticks_per_shape) pointer.ticks = 0;
    }

    /// The shape it shows, from 1 to `shapes`.
    pub fn shape(pointer: Pointer) usize {
        return @intCast(@divTrunc(pointer.ticks, ticks_per_shape) + 1);
    }
};

/// The ticks of the pointer's animation in the ITAC and in the simulator pod (`pointer_clock`,
/// `0x0051D7C8`): on by the game's ticks since the last pass, and back to 0 once they reach a
/// wrap, less their last two bits.
pub const PointerClock = struct {
    ticks: u32 = 0,
    /// The game's ticks at the last pass.
    last: u32 = 0,

    /// On to the game's `ticks`, round `wrap`.
    pub fn advance(clock: *PointerClock, ticks: u32, wrap: u32) void {
        clock.ticks +%= ticks -% clock.last;
        clock.last = ticks;
        if (clock.ticks & ~@as(u32, 3) >= wrap) clock.ticks = 0;
    }
};

test PointerClock {
    var clock: PointerClock = .{ .last = 100 };
    clock.advance(130, 0x40);
    try std.testing.expectEqual(30, clock.ticks);
    // Once they reach the wrap, they start again.
    clock.advance(163, 0x40);
    try std.testing.expectEqual(63, clock.ticks);
    clock.advance(164, 0x40);
    try std.testing.expectEqual(0, clock.ticks);
}

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

test "Canvas.fill" {
    const gpa = std.testing.allocator;
    var recorder: device.testing.Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    const strings: language.Language = .{ .strings = &.{} };
    var font: hud.Opened = undefined;
    const drawn: Canvas = .{ .gpa = gpa, .target = recorder.interface(), .window = .{ 1280, 720 }, .fonts = .{ .large = &font, .small = &font }, .strings = &strings };
    // A picture 1024 by 768 covers the front end's screen, one and a half times its size in a
    // window 720 high, centred across it.
    const rgba = try gpa.alloc(u8, 1024 * 768 * 4);
    var picture = srtexture.Image.single(gpa, 1024, 768, rgba) catch |err| {
        gpa.free(rgba);
        return err;
    };
    defer picture.deinit(gpa);
    drawn.fill(&picture);
    const corners = recorder.drawn(0);
    try std.testing.expectEqual(160, corners[0].x);
    try std.testing.expectEqual(0, corners[0].y);
    try std.testing.expectEqual(1120, corners[2].x);
    try std.testing.expectEqual(720, corners[2].y);
    // A 16:9 picture reaches past the screen's sides, and fills the window.
    const wide_rgba = try gpa.alloc(u8, 16 * 9 * 4);
    var wide = srtexture.Image.single(gpa, 16, 9, wide_rgba) catch |err| {
        gpa.free(wide_rgba);
        return err;
    };
    defer wide.deinit(gpa);
    drawn.fill(&wide);
    const filled = recorder.drawn(1);
    try std.testing.expectEqual(0, filled[0].x);
    try std.testing.expectEqual(0, filled[0].y);
    try std.testing.expectEqual(1280, filled[2].x);
    try std.testing.expectEqual(720, filled[2].y);
}

test Shapes {
    const gpa = std.testing.allocator;
    // A set of one palette, the least a set holds.
    const at = @sizeOf(spr.Header) + @sizeOf(spr.DirectoryEntry);
    var set: [at + spr.palette_size]u8 = @splat(0);
    set[0..@sizeOf(spr.Header)].* = @bitCast(spr.Header{ .version = spr.magic.*, .shape_count = 1 });
    set[@sizeOf(spr.Header)..at].* = @bitCast(spr.DirectoryEntry{ .offset = at, .reserved = 0 });
    var shapes = Shapes.of(gpa, try gpa.dupe(u8, &set), "palette.spr", null).?;
    defer shapes.deinit(gpa);
    try std.testing.expectEqual(1, shapes.art.set.count());
    // Its palette made the one every shape is drawn with; a block that is none leaves each its own.
    shapes.usePalette(0);
    try std.testing.expect(shapes.art.global != null);
    shapes.usePalette(1);
    try std.testing.expectEqual(null, shapes.art.global);
    // Not a sprite set, it is left out, and its bytes let go.
    try std.testing.expectEqual(null, Shapes.of(gpa, try gpa.dupe(u8, "x"), "x.spr", null));
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

test itemAt {
    const Item = enum { panel, button };
    const rects = std.EnumArray(Item, Rect).init(.{
        .panel = .{ .x = 27, .y = 123, .width = 184, .height = 290 },
        .button = .{ .x = 100, .y = 200, .width = 20, .height = 15 },
    });
    // The first that holds the point, where two do.
    try std.testing.expectEqual(.panel, itemAt(Item, &rects, .{ 110, 205 }));
    try std.testing.expectEqual(null, itemAt(Item, &rects, .{ 600, 20 }));
}

test Pointer {
    var pointer: Pointer = .{};
    var mouse: input.Mouse = .{};
    // With the system's pointer not yet over the window, it stays where it starts.
    pointer.update(&mouse, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 320, 200 }, pointer.at);
    // The middle of a wide window is the middle of the front end's screen.
    mouse.at = .{ 0.5, 0.5 };
    pointer.update(&mouse, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 320, 240 }, pointer.at);
    // Beside it, it keeps to its edge.
    mouse.at = .{ 0.9, 0 };
    pointer.update(&mouse, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual([2]i32{ 639, 0 }, pointer.at);
    // Out beside the front end's screen, it keeps to its edge.
    mouse.at = .{ 0.01, 0.5 };
    pointer.update(&mouse, .{ 1920, 1080 }, 1);
    try std.testing.expectEqual(0, pointer.at[0]);
    // The animation runs through the sixteen shapes, then from the first again.
    pointer.ticks = 0;
    pointer.update(&mouse, .{ 640, 480 }, 3);
    try std.testing.expectEqual(1, pointer.shape());
    pointer.update(&mouse, .{ 640, 480 }, 60);
    try std.testing.expectEqual(16, pointer.shape());
    pointer.update(&mouse, .{ 640, 480 }, 1);
    try std.testing.expectEqual(0, pointer.ticks);
    // It takes the wheel's whole notches, once.
    mouse.wheel = -1.5;
    pointer.update(&mouse, .{ 640, 480 }, 1);
    try std.testing.expectEqual(-1, pointer.wheel);
    pointer.update(&mouse, .{ 640, 480 }, 1);
    try std.testing.expectEqual(0, pointer.wheel);
}

test Scrolled {
    var list: Scrolled(u8) = .{ .count = 13, .shown = 10 };
    list.scroll(.up);
    try std.testing.expectEqual(0, list.first);
    for (0..5) |_| list.scroll(.down);
    // No further than the last row shown.
    try std.testing.expectEqual(3, list.first);
    try std.testing.expectEqual(13, list.end());
    list.scroll(.up);
    try std.testing.expectEqual(2, list.first);
    // A notch of the wheel down scrolls three rows, as far as the list goes.
    list.first = 0;
    list.wheel(-1);
    try std.testing.expectEqual(3, list.first);
    list.wheel(-1);
    try std.testing.expectEqual(3, list.first);
    list.wheel(1);
    try std.testing.expectEqual(0, list.first);
    // A list that holds no more than it shows does not scroll.
    var short: Scrolled(usize) = .{ .count = 4, .shown = 10 };
    short.scroll(.down);
    try std.testing.expectEqual(0, short.first);
    try std.testing.expectEqual(4, short.end());
}
