//! Window 0, the radio's (`hud_window_draw`'s case 0, `0x00488035`): as a line is said
//! ([`videoreports.zig`](../videoreports.zig)), a picture that settles out of noise on the emblem
//! of the speaker's side while the line waits for the window, then the film of the speaker's face
//! ([`hudmovie.zig`](../hudmovie.zig)) under their name while the line plays. The window closes once
//! the line is over, on the emblem.

const std = @import("std");
const assert = std.debug.assert;

const device = @import("../../surrender/srd3d/device.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const gameobj = @import("../gameobj.zig");
const hog_snd = @import("../hog_snd.zig");
const hud = @import("../hud.zig");
const libcmt = @import("../../libcmt.zig");
const videoreports = @import("../videoreports.zig");
const windows = @import("windows.zig");

/// The first of the shapes the window shows while the line waits for it, a friendly speaker's,
/// and any other's (`0x00488130`): one each `ticks_per_shape` of the wait, `shapes` of them, the
/// last the emblem of the speaker's side, which the window closes on.
pub const friendly_shapes: u16 = 0x131;
pub const other_shapes: u16 = 0x148;
pub const shapes = 23;
pub const ticks_per_shape = 4;

comptime {
    // The emblem shows as the line starts.
    assert(@divTrunc(videoreports.speech_delay - 1, ticks_per_shape) == shapes - 1);
}

/// Where the shapes and the film stand from the window's place, and the speaker's name.
pub const picture_at: [2]i32 = .{ 13, 19 };
pub const name_at: [2]i32 = .{ 1, 2 };

/// The first of the shapes for a speaker of `side`.
pub fn firstShape(side: gameobj.Side(u16)) u16 {
    return if (side == .friendly) friendly_shapes else other_shapes;
}

/// What window 0 shows from.
pub const Shown = struct {
    radio: *videoreports.Radio,
    /// What the line is heard through; none where nothing is heard.
    sound: ?*hog_snd.Sound,
    /// The camera's shake, which shakes the film a row at a time, and the C runtime's `rand`, which
    /// it draws from.
    hit_shake: f32,
    random: *libcmt.Rand,
};

/// `hud_window_draw`'s case 0, in every view: in the view ahead (`ahead`) while the window closes,
/// the emblem. Otherwise a film that has stopped closes the window, and a line that is over closes
/// it and stops the film. While the line plays, in the view ahead, the speaker's name and the film,
/// each of its rows moved by the camera's shake (`hud.rowShift`); while it waits for the window,
/// the shape its wait has come to. The shapes shake while the display does (`hud_blit`).
pub fn frame(shown: Shown, held: *windows.Windows, canvas: windows.Canvas, ahead: bool) windows.Canvas.Error!void {
    const radio = shown.radio;
    const movie = &radio.movie;
    const first = firstShape(radio.side);
    if (ahead and held.status.get(.radio).phase == .closing) return canvas.shaky(first + shapes - 1, picture_at);
    if (!movie.playing) return held.close(.radio);
    if (!movie.waiting) {
        if (!radio.speaking(shown.sound)) {
            held.close(.radio);
            movie.stop();
            return;
        }
        if (!ahead) return;
        if (radio.name) |name| try canvas.string(name, name_at, .left);
        const shake: ?hud.Shake = if (shown.hit_shake > 0) .{ .hit_shake = shown.hit_shake, .interference = 0, .random = shown.random } else null;
        canvas.imageShaken(&movie.picture, picture_at, shake);
        return;
    }
    if (!ahead) return;
    const step: u16 = @intCast(std.math.clamp(@divTrunc(movie.waited, ticks_per_shape), 0, shapes - 1));
    try canvas.shaky(first + step, picture_at);
}

test firstShape {
    try std.testing.expectEqual(0x131, firstShape(.friendly));
    try std.testing.expectEqual(0x148, firstShape(.hostile));
    try std.testing.expectEqual(0x148, firstShape(.neutral));
}

test "the film keeps its shape at any window's size" {
    const gpa = std.testing.allocator;
    const across = 120;
    const down = 100;
    var rgba: [across * down * 4]u8 = @splat(0);
    var level = [1]srtexture.Level{.{ .width = across, .height = down, .rgba = &rgba }};
    var picture: srtexture.Image = .{ .levels = &level };
    var random: libcmt.Rand = .{};
    // The display is drawn at one scale both ways, the least of the window's to 1024 by 768, so
    // the film stands 6 to 5 whatever the window's shape, and shaken, a row at a time, as well.
    for ([_][2]u32{ .{ 1024, 768 }, .{ 1920, 1080 }, .{ 768, 1024 }, .{ 3440, 1440 }, .{ 640, 480 } }) |screen| {
        var recorder: device.testing.Recorder = .{ .gpa = gpa };
        defer recorder.deinit();
        const scale = hud.scaleFor(screen);
        const pen = hud.testing.pen(undefined, gpa, recorder.interface());
        const canvas: windows.Canvas = .{ .pen = pen.sized(scale), .at = .{ 0, 0 }, .clip = null };
        canvas.imageShaken(&picture, picture_at, null);
        const quad = recorder.last();
        try std.testing.expectApproxEqRel(across * scale, quad[2].x - quad[0].x, 1e-5);
        try std.testing.expectApproxEqRel(down * scale, quad[2].y - quad[0].y, 1e-5);
        recorder.clear();
        canvas.imageShaken(&picture, picture_at, .{ .hit_shake = 1, .interference = 0, .random = &random });
        try std.testing.expectEqual(down, recorder.draws.items.len);
        for (0..down) |row| {
            const strip = recorder.drawn(row);
            try std.testing.expectApproxEqRel(across * scale, strip[2].x - strip[0].x, 1e-5);
            try std.testing.expectApproxEqRel(scale, strip[2].y - strip[0].y, 1e-5);
        }
    }
}
