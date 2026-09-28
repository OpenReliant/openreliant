//! The display's windows: the panels `hud.cpp` brings over the view when a key or the game asks for
//! one, and takes away again once its time is up. Each has a record at `0x00501D30`, 40 bytes
//! apart: its phase, where it stands, the pieces of its frame, how long it stays, how far it has
//! opened and whether it is held open. `hud_window_open` (`0x0048B510`) and `hud_window_close`
//! (`0x0048B590`) start one opening or closing, for a key, the game or a mission's script
//! (`OpenInstrument` and `CloseInstrument`, which call a window an instrument); `hud_draw` moves
//! each on once a frame and draws it with `hud_window_draw` (`0x00486830`): sliding and shrinking
//! into place as it opens, the reverse as it closes, and in place while it is open.
//!
//! Ported so far: the windows' phases and times, their frames, how they open and close with the
//! display's sounds (`hud_beep` 1 and 2), and what windows 0, 1, 2, 3, 4, 7, 8, 10 and 13 show
//! ([`radio.zig`](radio.zig), [`gunnery.zig`](gunnery.zig),
//! [`missile_display.zig`](missile_display.zig), [`target_display.zig`](target_display.zig),
//! [`damage.zig`](damage.zig), [`power.zig`](power.zig),
//! [`objectives_window.zig`](objectives_window.zig), [`wing_status.zig`](wing_status.zig)).
//! Not yet: what the other
//! windows show, which [`hud.md`](../../../../docs/engine/hud.md) lists with the state each reads.

const std = @import("std");
const Allocator = std.mem.Allocator;

const camera = @import("../camera.zig");
const device = @import("../../surrender/srd3d/device.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const math = @import("../../surrender/math.zig");
const spr = @import("../../../formats/spr.zig");
const videoreports = @import("../videoreports.zig");

/// The windows, numbered as the game numbers their records.
pub const Window = enum(u4) {
    /// The radio's: the face of whoever speaks, under their name, while they speak.
    radio = 0,
    /// The guns: the ship as a wire frame, the gun or group that fires, and how.
    gunnery = 1,
    /// The missiles in their ring, the armed one's name and how many are left.
    missiles = 2,
    /// The target display's small form: the target's schematic with its shields, its name, its
    /// range and its speed (`hud_ship_status` for the target).
    target = 3,
    /// A bar each for the weapons, the engines and the shields.
    damage = 4,
    /// Frames alone, which no key opens and a mission's script may (`OpenInstrument`).
    /// **Unknown:** what they are for.
    _unknown_5 = 5,
    _unknown_6 = 6,
    /// The power distribution: the ball and the shares of the guns, the engines and the shields.
    power = 7,
    /// The target display's large form, for a big target: its own picture and its subtarget.
    big_target = 8,
    /// A frame alone, which never opens in a multiplayer game. **Unknown:** what it is for.
    _unknown_9 = 9,
    /// The mission's objectives.
    objectives = 10,
    /// The radio's menu of who can be called.
    comms = 11,
    _unknown_12 = 12,
    /// The wing's fighters, each with a bar for its damage.
    wing_status = 13,
    /// **Unknown:** what it shows.
    _unknown_14 = 14,

    /// Whether it is one of the windows that stand still and unseen in mission 25's first part,
    /// where the player flies a Kamov (`hud_draw`, `0x00486408`): the gunnery, missile and wing
    /// status windows.
    pub fn kamovLacks(window: Window) bool {
        return switch (window) {
            .gunnery, .missiles, .wing_status => true,
            else => false,
        };
    }
};

/// Where a window stands in its opening and closing (`+0x00`).
pub const Phase = enum(u16) {
    shut = 0,
    opening = 1,
    closing = 2,
    open = 3,
};

/// The ticks a window takes to open, and to close.
pub const opening_ticks: i32 = 60;

/// The pane `hud_init` draws a window into as it opens and closes, which is then drawn scaled
/// onto the display (`0x0057998C`, 225 by 170): what of a window falls outside it is cut off
/// meanwhile.
pub const buffer_size: [2]i32 = .{ 225, 170 };

/// A piece of a window's frame, one of the pieces at `0x00502078`, 20 bytes each: one of the
/// display's shapes, where it stands from the window's own place, and how it is flipped.
pub const Piece = struct {
    shape: u16,
    /// From the window's place, in the display's pixels. The record holds each as a float, and
    /// `hud_window_draw` cuts it down to a whole number.
    offset: [2]i32,
    mirror: hud.Mirror = .{},
};

/// The pieces the windows' frames use, by their number at `0x00502078`.
const pieces = struct {
    const p0: Piece = .{ .shape = 0x78, .offset = .{ 12, 1 } };
    const p1: Piece = .{ .shape = 0x79, .offset = .{ 0, 14 } };
    const p2: Piece = .{ .shape = 0x7A, .offset = .{ 1, -58 } };
    const p3: Piece = .{ .shape = 0x7B, .offset = .{ 1, -147 } };
    const p4: Piece = .{ .shape = 0x7C, .offset = .{ 0, 0 } };
    const p6: Piece = .{ .shape = 0x7E, .offset = .{ 1, 35 } };
    const p14: Piece = .{ .shape = 0x78, .offset = .{ -139, 1 }, .mirror = .of(1) };
    const p15: Piece = .{ .shape = 0x79, .offset = .{ -32, 14 }, .mirror = .of(1) };
    const p16: Piece = .{ .shape = 0x7A, .offset = .{ -32, -58 }, .mirror = .of(1) };
    const p17: Piece = .{ .shape = 0x78, .offset = .{ 13, -23 }, .mirror = .of(2) };
    const p18: Piece = .{ .shape = 0x7B, .offset = .{ -32, -146 }, .mirror = .of(1) };
    const p27: Piece = .{ .shape = 0x7D, .offset = .{ -210, -24 } };
};

/// What a window's record holds from the start.
pub const Layout = struct {
    /// Where the window stands, a fraction of the screen across and down (`+0x04`, `+0x08`).
    at: [2]f32,
    /// Where its place falls in `buffer_size`'s pane as it opens and closes, a fraction of the
    /// pane (`0x00501F88`, 16 bytes a window). The same as `at` for all but the target display.
    in_buffer: [2]f32,
    /// The pieces of its frame, drawn in the view ahead (`+0x0C`, their count, and from `+0x0E`
    /// their numbers).
    frame: []const Piece,
    /// The ticks it stays open, unless held (`+0x1C`).
    stay: i32,
};

/// Every window's layout, as the payload holds it.
pub const layouts: std.EnumArray(Window, Layout) = .init(.{
    .radio = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p1, pieces.p0 }, .stay = 400 },
    .gunnery = .{ .at = .{ 0, 1 }, .in_buffer = .{ 0, 1 }, .frame = &.{ pieces.p3, pieces.p17 }, .stay = 1200 },
    .missiles = .{ .at = .{ 0.5, 0 }, .in_buffer = .{ 0.5, 0 }, .frame = &.{ pieces.p4, pieces.p6 }, .stay = 200 },
    .target = .{ .at = .{ 0.7, 1 }, .in_buffer = .{ 0.2, 1 }, .frame = &.{}, .stay = 2000 },
    .damage = .{ .at = .{ 1, 0 }, .in_buffer = .{ 1, 0 }, .frame = &.{ pieces.p14, pieces.p15 }, .stay = 1000 },
    ._unknown_5 = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p0, pieces.p1 }, .stay = 200 },
    ._unknown_6 = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p0, pieces.p1 }, .stay = 200 },
    .power = .{ .at = .{ 0, 0.5 }, .in_buffer = .{ 0, 0.5 }, .frame = &.{pieces.p2}, .stay = 1000 },
    .big_target = .{ .at = .{ 1, 1 }, .in_buffer = .{ 1, 1 }, .frame = &.{ pieces.p27, pieces.p18 }, .stay = 2000 },
    ._unknown_9 = .{ .at = .{ 1, 0.5 }, .in_buffer = .{ 1, 0.5 }, .frame = &.{pieces.p16}, .stay = 1000 },
    .objectives = .{ .at = .{ 1, 0.5 }, .in_buffer = .{ 1, 0.5 }, .frame = &.{pieces.p16}, .stay = 1000 },
    .comms = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p1, pieces.p0 }, .stay = 1500 },
    ._unknown_12 = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p0, pieces.p1 }, .stay = 1000 },
    .wing_status = .{ .at = .{ 1, 0.5 }, .in_buffer = .{ 1, 0.5 }, .frame = &.{pieces.p16}, .stay = 1000 },
    ._unknown_14 = .{ .at = .{ 0, 0 }, .in_buffer = .{ 0, 0 }, .frame = &.{ pieces.p1, pieces.p0 }, .stay = 2000 },
});

/// What a window's record holds as the game runs.
pub const Status = struct {
    phase: Phase = .shut,
    /// The ticks left before it closes (`+0x18`).
    left: i32 = 0,
    /// How far it has opened, 0 to `opening_ticks` (`+0x20`).
    progress: i32 = 0,
    /// Held open until its key is pressed again (`+0x24`).
    held: bool = false,
};

/// How a window is drawn this frame.
pub const Shown = struct {
    /// How many times its own size it is drawn, and how much farther than its own place from the
    /// middle of the screen it stands: 1 once open; from 2 down to 1 as it opens, and back up to 2
    /// as it closes.
    scale: f32,
    /// Whether it is drawn through `buffer_size`'s pane, and so cut to it, as it opens and closes.
    buffered: bool,
};

pub const Windows = struct {
    status: std.EnumArray(Window, Status) = .initFill(.{}),
    /// The display's sounds for the windows that have started opening and closing, which
    /// `hud.draw` plays this frame.
    beeps: hud.Beeps = .{},

    /// `hud_window_open` (`0x0048B510`): starts `window` opening, with the display's sound, and
    /// gives it its full time to stay whatever its phase, so a window closing carries on closing.
    /// In a multiplayer game the missiles, the objectives and window 9 never open. Returns whether
    /// the window is up.
    pub fn open(windows: *Windows, window: Window, multiplayer: bool) bool {
        if (multiplayer and (window == .missiles or window == ._unknown_9 or window == .objectives)) return false;
        const status = windows.status.getPtr(window);
        windows.renew(window);
        if (status.phase == .shut) {
            windows.beeps.add(.opens);
            status.phase = .opening;
            status.progress = 0;
            status.held = false;
        }
        return true;
    }

    /// Gives `window` its full time to stay again, whatever its phase.
    pub fn renew(windows: *Windows, window: Window) void {
        windows.status.getPtr(window).left = layouts.get(window).stay;
    }

    /// How the radio opens its window as it says a line (`radio_say`, `0x00456432`; `radio_frame`,
    /// `0x00456596`): `window` held, with its full time to stay, and opening from however far it
    /// had closed, without the display's sound.
    pub fn hold(windows: *Windows, window: Window) void {
        windows.renew(window);
        const status = windows.status.getPtr(window);
        status.phase = .opening;
        status.held = true;
    }

    /// `hud_window_close` (`0x0048B590`): starts `window` closing if it is open or opening, from
    /// its full size, however far it had opened, with the display's sound, and lets go of it. For
    /// the target display's two forms the game also keeps a picture of what they show, which they
    /// close with.
    pub fn close(windows: *Windows, window: Window) void {
        const status = windows.status.getPtr(window);
        if (!windows.up(window)) return;
        windows.beeps.add(.closes);
        status.phase = .closing;
        status.held = false;
        status.progress = opening_ticks;
    }

    /// Whether `window` is open or opening, which is what the keys that close a window test.
    pub fn up(windows: *const Windows, window: Window) bool {
        const phase = windows.status.get(window).phase;
        return phase == .open or phase == .opening;
    }

    /// One window's turn of `hud_draw`'s loop (`0x004863F3`): an opening or closing window moves on
    /// by `frame_duration` ticks; an open one counts its time down and, once that has run out and
    /// nothing holds it, starts closing, though it is drawn in place once more. Returns how the
    /// window is drawn, or null for one that is shut.
    pub fn step(windows: *Windows, window: Window, frame_duration: i32) ?Shown {
        const status = windows.status.getPtr(window);
        switch (status.phase) {
            .opening => {
                status.progress += frame_duration;
                if (status.progress >= opening_ticks) {
                    status.phase = .open;
                    status.progress = opening_ticks;
                }
            },
            .closing => {
                status.progress -= frame_duration;
                if (status.progress < 1) {
                    status.phase = .shut;
                    status.progress = 0;
                }
            },
            .shut, .open => {},
        }
        switch (status.phase) {
            .shut => return null,
            .opening, .closing => return .{ .scale = openingScale(status.progress), .buffered = true },
            .open => {
                if (status.left < 0 and !status.held) {
                    status.left = 0;
                    windows.close(window);
                } else {
                    // The time counts down by the frame's ticks as a halfword.
                    status.left -= @as(i16, @truncate(frame_duration));
                }
                return .{ .scale = 1, .buffered = false };
            },
        }
    }

    /// `hud_draw`'s loop over the windows, which it runs in every view: each moves on, and in the
    /// view ahead from the cockpit is drawn over the display, with what it shows where OpenReliant
    /// draws that. The radio's window follows its line in every view (`hud.radio.frame`). In
    /// mission 25's first part (`kamov`), the windows the Kamov lacks stand still, unseen
    /// (`Window.kamovLacks`, `0x00486408`).
    pub fn frame(
        windows: *Windows,
        pen: Pen,
        screen: [2]u32,
        last_view: camera.View,
        frame_duration: i32,
        contents: Contents,
        kamov: bool,
        scale: f32,
    ) Canvas.Error!void {
        const ahead = hud.instrumented(last_view);
        for (std.enums.values(Window)) |window| {
            if (kamov and window.kamovLacks()) continue;
            const shown = windows.step(window, frame_duration) orelse continue;
            try draw(windows, pen, screen, window, shown, ahead, contents, scale);
        }
    }
};

/// How large a window is drawn `progress` ticks into its opening: twice its size at the start, its
/// own at the end.
fn openingScale(progress: i32) f32 {
    const step: f32 = 1.0 / @as(f32, @floatFromInt(opening_ticks));
    return (1 - @as(f32, @floatFromInt(progress)) * step) + 1;
}

/// Where a window's place stands on the screen when it is drawn as `shown` says: its own place,
/// moved out from the middle of the screen by the scale it is drawn at.
pub fn anchor(screen: [2]u32, window: Window, shown: Shown, scale: f32) [2]i32 {
    const at = layouts.get(window).at;
    return hud.place(screen, .{ 0, 0 }, (at[0] - 0.5) * shown.scale + 0.5, (at[1] - 0.5) * shown.scale + 0.5, scale);
}

/// The part of the screen `buffer_size`'s pane covers with a window's place at `at`, drawn `size`
/// times the pane's own: the window's place stands where `in_buffer` says in it, as
/// `hud_window_draw` draws it there and `VFX_buffer_transform` scales the pane about the place.
pub fn bufferClip(window: Window, at: [2]i32, size: f32) hud.Clip {
    const in_buffer = layouts.get(window).in_buffer;
    var from: [2]f32 = undefined;
    var to: [2]f32 = undefined;
    for (&from, &to, at, buffer_size, in_buffer) |*low, *high, place, extent, fraction| {
        const inside: f32 = @floatFromInt(math.round(@as(f32, @floatFromInt(extent - 2)) * fraction + 1));
        const centre: f32 = @floatFromInt(place);
        low.* = centre - inside * size;
        high.* = centre + (@as(f32, @floatFromInt(extent)) - inside) * size;
    }
    return .{ .left = from[0], .top = from[1], .right = to[0], .bottom = to[1] };
}

/// What the windows show, for those OpenReliant draws the contents of.
pub const Contents = struct {
    /// Window 0's.
    radio: ?hud.radio.Shown = null,
    /// Window 1's.
    gunnery: ?hud.gunnery.Shown = null,
    /// Window 2's.
    missiles: ?hud.missile_display.Shown = null,
    /// Window 4's.
    damage: ?hud.damage.Shown = null,
    /// Window 7's.
    power: ?hud.power.Shown = null,
    /// Window 10's.
    objectives: ?hud.objectives_window.Shown = null,
    /// Window 11's, the radio's menu.
    comms: ?videoreports.menu.Shown = null,
    /// Windows 3 and 8's, the target display's two forms.
    target_display: ?hud.target_display.Scene = null,
    /// Window 13's.
    wing_status: ?hud.wing_status.Shown = null,
};

/// Where a window's contents are drawn: the window's place on the screen, how many times their
/// own size, and what they are cut to while the window opens or closes.
pub const Inside = struct {
    at: [2]i32,
    size: f32,
    clip: ?hud.Clip,

    /// The point `offset` of the display's own pixels from the window's place.
    pub fn place(inside: Inside, offset: [2]i32) [2]i32 {
        return hud.scaled(inside.at, offset, inside.size);
    }

    /// A VFX pane from the window's place, its left, top, right and bottom edges in the display's
    /// own pixels and inclusive, as the part of the screen it covers, cut to the window's own.
    pub fn pane(inside: Inside, edges: [4]i32) hud.Clip {
        const edge = hud.Clip.edge;
        const x: f32 = @floatFromInt(inside.at[0]);
        const y: f32 = @floatFromInt(inside.at[1]);
        const own: hud.Clip = .{
            .left = edge(x, edges[0], inside.size),
            .top = edge(y, edges[1], inside.size),
            .right = edge(x, edges[2] + 1, inside.size),
            .bottom = edge(y, edges[3] + 1, inside.size),
        };
        const outer = inside.clip orelse return own;
        return own.intersect(outer);
    }
};

/// What the windows draw with: the display's shapes, font and strings, onto `target`, in
/// `colour`.
pub const Pen = struct {
    art: *hud.Art,
    font: *hud.Opened,
    strings: *const language.Language,
    gpa: Allocator,
    target: device.Device,
    colour: [4]f32,
    /// How the display shakes this frame; null while it stands still.
    shake: ?hud.Shake = null,
};

/// A window as its frame and what it shows are drawn: with `pen`, from the window's place
/// (`inside`), each offset in the display's own pixels.
pub const Canvas = struct {
    pen: Pen,
    inside: Inside,

    pub const Error = spr.Error || Allocator.Error;

    /// Shape `index` at `at`, drawn as `how` says.
    pub fn shapeWith(canvas: Canvas, index: usize, at: [2]i32, how: hud.Draw) Error!void {
        const pen = canvas.pen;
        try hud.drawShapeWith(pen.art, pen.gpa, pen.target, index, canvas.inside.place(at), pen.colour, canvas.inside.size, how);
    }

    /// Shape `index` at `at`, cut to the window.
    pub fn shape(canvas: Canvas, index: usize, at: [2]i32) Error!void {
        try canvas.shapeWith(index, at, .{ .clip = canvas.inside.clip });
    }

    /// Shape `index` at `at`, cut to the window, shaken while the display shakes (`hud_blit`).
    pub fn shaky(canvas: Canvas, index: usize, at: [2]i32) Error!void {
        try canvas.shapeWith(index, at, .{ .clip = canvas.inside.clip, .shake = canvas.pen.shake });
    }

    /// Shape `index` at `at`, cut to the VFX pane of `edges` (`Inside.pane`).
    pub fn shapeIn(canvas: Canvas, index: usize, at: [2]i32, edges: [4]i32) Error!void {
        try canvas.shapeWith(index, at, .{ .clip = canvas.inside.pane(edges) });
    }

    /// `picture` with its top left corner at `at`, cut to the window.
    pub fn image(canvas: Canvas, picture: *srtexture.Image, at: [2]i32) void {
        canvas.imageShaken(picture, at, null);
    }

    /// `picture` with its top left corner at `at`, cut to the window, each row moved as `shake`
    /// says where it shakes.
    pub fn imageShaken(canvas: Canvas, picture: *srtexture.Image, at: [2]i32, shake: ?hud.Shake) void {
        const corner = canvas.inside.place(at);
        hud.drawImage(canvas.pen.target, picture, .{ @floatFromInt(corner[0]), @floatFromInt(corner[1]) }, canvas.pen.colour, canvas.inside.size, .{ .clip = canvas.inside.clip, .shake = shake });
    }

    /// `words` at `at` in the display's font, aligned as `alignment` says.
    pub fn text(canvas: Canvas, words: []const u8, at: [2]i32, alignment: hud.Align) Allocator.Error!void {
        try canvas.textIn(canvas.pen.font, words, at, alignment);
    }

    /// `words` at `at` in `font`, aligned as `alignment` says.
    pub fn textIn(canvas: Canvas, font: *hud.Opened, words: []const u8, at: [2]i32, alignment: hud.Align) Allocator.Error!void {
        const pen = canvas.pen;
        _ = try hud.drawText(font, pen.gpa, pen.target, canvas.inside.place(at), words, pen.colour, alignment, canvas.inside.size);
    }

    /// The game's string `id`, where it has one.
    pub fn string(canvas: Canvas, id: u32, at: [2]i32, alignment: hud.Align) Allocator.Error!void {
        try canvas.text(canvas.pen.strings.string(id) orelse return, at, alignment);
    }

    /// `args` written out as `format` says.
    pub fn print(canvas: Canvas, comptime format: []const u8, args: anytype, at: [2]i32, alignment: hud.Align) Allocator.Error!void {
        try canvas.printIn(canvas.pen.font, format, args, at, alignment);
    }

    /// `args` written out in `font` as `format` says.
    pub fn printIn(canvas: Canvas, font: *hud.Opened, comptime format: []const u8, args: anytype, at: [2]i32, alignment: hud.Align) Allocator.Error!void {
        var buffer: [32]u8 = undefined;
        try canvas.textIn(font, std.fmt.bufPrint(&buffer, format, args) catch return, at, alignment);
    }

    /// `hud_text_wrapped` (`0x00480FD0`): `words` broken into lines at most `width` of the display's
    /// pixels wide (`hud.Wrapping`), at most `max_lines` of them, each drawn as `text` draws a line,
    /// `line_height` below the last.
    pub fn wrapped(canvas: Canvas, words: []const u8, at: [2]i32, alignment: hud.Align, width: i32, line_height: i32, max_lines: usize) Allocator.Error!void {
        var lines: hud.WrappedText = .init(&canvas.pen.font.widths, words, width, max_lines);
        var y = at[1];
        while (lines.next()) |shown| : (y += line_height) try canvas.text(shown, .{ at[0], y }, alignment);
    }
};

/// How much of a bar of `rows` is dark for `share` of what it measures left: all of it less the
/// share of it, rounded as `sr_round` does. The target display's bars and the wing status's count
/// their rows this way.
pub fn unlitRows(share: f32, rows: i32) i32 {
    return rows - math.round(share * @as(f32, @floatFromInt(rows)));
}

test unlitRows {
    // Whole, a bar is lit all the way; half gone, its top half is dark; gone, all of it.
    try std.testing.expectEqual(0, unlitRows(1, 98));
    try std.testing.expectEqual(49, unlitRows(0.5, 98));
    try std.testing.expectEqual(38, unlitRows(0, 38));
}

/// `hud_window_draw` (`0x00486830`): in the view ahead (`ahead`), each piece of the window's frame,
/// from where its place stands, then what the window shows; the radio's window, which follows its
/// line in every view, whatever the view.
fn draw(windows: *Windows, pen: Pen, screen: [2]u32, window: Window, shown: Shown, ahead: bool, contents: Contents, scale: f32) Canvas.Error!void {
    const at = anchor(screen, window, shown, scale);
    const size = scale * shown.scale;
    const clip: ?hud.Clip = if (shown.buffered) bufferClip(window, at, size) else null;
    const canvas: Canvas = .{ .pen = pen, .inside = .{ .at = at, .size = size, .clip = clip } };
    if (ahead) for (layouts.get(window).frame) |piece| {
        try canvas.shapeWith(piece.shape, piece.offset, .{ .mirror = piece.mirror, .clip = clip, .shake = pen.shake });
    };
    if (window == .radio) {
        if (contents.radio) |radio| try hud.radio.frame(radio, windows, canvas, ahead);
        return;
    }
    if (!ahead) return;
    const phase = windows.status.get(window).phase;
    switch (window) {
        .gunnery => if (contents.gunnery) |gunnery| try hud.gunnery.draw(gunnery, canvas),
        .missiles => if (contents.missiles) |missiles| try hud.missile_display.draw(missiles, canvas),
        .damage => if (contents.damage) |damage| try hud.damage.draw(damage, canvas),
        .power => if (contents.power) |power| try hud.power.draw(power, canvas),
        .objectives => if (contents.objectives) |objectives| try hud.objectives_window.draw(objectives, canvas),
        .comms => if (contents.comms) |comms| try videoreports.menu.draw(comms, canvas),
        .wing_status => if (contents.wing_status) |wing| try hud.wing_status.draw(wing, canvas),
        else => if (hud.target_display.Form.of(window)) |form| if (contents.target_display) |scene| {
            try scene.draw(form, phase == .closing, canvas);
        },
    }
}

test "a window sounds as it starts opening and as it starts closing" {
    var windows: Windows = .{};
    _ = windows.open(.damage, false);
    // Opening already, it opens without a sound; a window shut closes without one.
    _ = windows.open(.damage, false);
    windows.close(.damage);
    windows.close(.damage);
    windows.close(.gunnery);
    try std.testing.expectEqualSlices(hud.Beep, &.{ .opens, .closes }, windows.beeps.slice());
}

test "Window.kamovLacks" {
    try std.testing.expect(Window.gunnery.kamovLacks());
    try std.testing.expect(Window.missiles.kamovLacks());
    try std.testing.expect(Window.wing_status.kamovLacks());
    try std.testing.expect(!Window.objectives.kamovLacks());
    try std.testing.expect(!Window.radio.kamovLacks());
}

test "a window opens, stays its time and closes" {
    var windows: Windows = .{};
    try std.testing.expect(windows.open(.damage, false));
    try std.testing.expectEqual(Phase.opening, windows.status.get(.damage).phase);
    // Half open, it is drawn one and a half times its size; open, its own.
    try std.testing.expectApproxEqAbs(1.5, windows.step(.damage, 30).?.scale, 1e-5);
    try std.testing.expectEqual(Shown{ .scale = 1, .buffered = false }, windows.step(.damage, 30).?);
    try std.testing.expectEqual(Phase.open, windows.status.get(.damage).phase);
    // It stays its 1000 ticks, counted from the frame it opened in.
    _ = windows.step(.damage, 969);
    try std.testing.expectEqual(1, windows.status.get(.damage).left);
    _ = windows.step(.damage, 2);
    try std.testing.expectEqual(Phase.open, windows.status.get(.damage).phase);
    // Past them it starts closing, drawn in place that once more.
    try std.testing.expectEqual(Shown{ .scale = 1, .buffered = false }, windows.step(.damage, 1).?);
    try std.testing.expectEqual(Phase.closing, windows.status.get(.damage).phase);
    try std.testing.expectApproxEqAbs(1.5, windows.step(.damage, 30).?.scale, 1e-5);
    try std.testing.expectEqual(null, windows.step(.damage, 30));
    try std.testing.expectEqual(Phase.shut, windows.status.get(.damage).phase);
}

test "a held window stays open" {
    var windows: Windows = .{};
    _ = windows.open(.gunnery, false);
    windows.status.getPtr(.gunnery).held = true;
    _ = windows.step(.gunnery, 60);
    for (0..10) |_| _ = windows.step(.gunnery, 1000);
    try std.testing.expectEqual(Phase.open, windows.status.get(.gunnery).phase);
    // Closing lets go of it.
    windows.close(.gunnery);
    try std.testing.expectEqual(Phase.closing, windows.status.get(.gunnery).phase);
    try std.testing.expect(!windows.status.get(.gunnery).held);
}

test "opening a closing window only gives it its time" {
    var windows: Windows = .{};
    _ = windows.open(.power, false);
    // Closed while still opening, it closes from its full size.
    _ = windows.step(.power, 20);
    windows.close(.power);
    try std.testing.expectEqual(opening_ticks, windows.status.get(.power).progress);
    try std.testing.expect(!windows.up(.power));
    try std.testing.expect(windows.open(.power, false));
    try std.testing.expectEqual(Phase.closing, windows.status.get(.power).phase);
    try std.testing.expectEqual(layouts.get(.power).stay, windows.status.get(.power).left);
}

test "the radio holds its window open without a sound" {
    var windows: Windows = .{};
    windows.hold(.radio);
    try std.testing.expectEqual(Phase.opening, windows.status.get(.radio).phase);
    try std.testing.expect(windows.status.get(.radio).held);
    try std.testing.expectEqual(0, windows.beeps.slice().len);
    // Held again as it closes, it opens again from however far it had closed.
    _ = windows.step(.radio, opening_ticks);
    windows.close(.radio);
    _ = windows.step(.radio, 20);
    windows.hold(.radio);
    try std.testing.expectEqual(Phase.opening, windows.status.get(.radio).phase);
    try std.testing.expectEqual(opening_ticks - 20, windows.status.get(.radio).progress);
    for (0..10) |_| _ = windows.step(.radio, 1000);
    try std.testing.expectEqual(Phase.open, windows.status.get(.radio).phase);
}

test "a multiplayer game refuses three windows" {
    var windows: Windows = .{};
    try std.testing.expect(!windows.open(.missiles, true));
    try std.testing.expect(!windows.open(.objectives, true));
    try std.testing.expect(!windows.open(._unknown_9, true));
    try std.testing.expect(windows.open(.comms, true));
    try std.testing.expect(!windows.up(.missiles));
}

test Inside {
    const inside: Inside = .{ .at = .{ 100, 200 }, .size = 2, .clip = .{ .left = 0, .top = 0, .right = 150, .bottom = 1000 } };
    try std.testing.expectEqual([2]i32{ 90, 220 }, inside.place(.{ -5, 10 }));
    // A pane's right and bottom edges are its last pixel's, so it reaches one pixel past them, and
    // what the window is cut to cuts it too.
    const pane = inside.pane(.{ -7, -10, -3, 20 });
    try std.testing.expectEqual(hud.Clip{ .left = 86, .top = 180, .right = 96, .bottom = 242 }, pane);
    const cut = inside.pane(.{ 20, 0, 40, 1 });
    try std.testing.expectEqual(150, cut.right);
}

test bufferClip {
    // The gunnery window's place is the pane's lower left, a pixel in: at its own size the pane
    // runs a pixel left of it and 224 right, 169 above it and one below.
    const clip = bufferClip(.gunnery, .{ 100, 500 }, 1);
    try std.testing.expectEqual(hud.Clip{ .left = 99, .top = 331, .right = 324, .bottom = 501 }, clip);
    // Twice the size, twice as far.
    const twice = bufferClip(.power, .{ 0, 0 }, 2);
    try std.testing.expectEqual(hud.Clip{ .left = -2, .top = -170, .right = 448, .bottom = 170 }, twice);
}

test anchor {
    // Open, a window stands in its place; at the start of its opening, twice as far from the
    // middle of the screen.
    const screen: [2]u32 = .{ 1024, 768 };
    const open = anchor(screen, .gunnery, .{ .scale = 1, .buffered = false }, 1);
    try std.testing.expectEqual(hud.place(screen, .{ 0, 0 }, 0, 1, 1), open);
    const starting = anchor(screen, .gunnery, .{ .scale = 2, .buffered = true }, 1);
    try std.testing.expectEqual(hud.place(screen, .{ 0, 0 }, -0.5, 1.5, 1), starting);
}
