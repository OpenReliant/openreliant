//! OpenReliant's: the green and red copies of a texture that the loadout draws its ships and its
//! weapons with, made where neither the mods nor the texture cache hold one
//! ([#664](https://github.com/OpenReliant/openreliant/issues/664)).
//!
//! The loadout looks each texture up under a letter (`srofiles.Prefix`): `g` for the ships, `r`
//! for the missiles and guns. The texture cache holds both copies of every ship texture: the same
//! picture in shades of green or red, in the colours of `palette3.tga`. A mod that brings a new
//! texture, or a new picture for one of the game's, often brings no copies.
//!
//! **Improvement:** OpenReliant makes the missing copy from the picture. The picture's brightness
//! is stretched over its own range, then sent through a curve onto the copy's colour. The range,
//! the curves and the colours are fitted to the game's own copies of `yank_1`, `yank_2`, `sam_3`
//! and `wolver`. The game's copies scatter round the curve, as they are dithered into 256 colours;
//! the copies OpenReliant makes are smooth.

const std = @import("std");

const srtexture = @import("../srtexture.zig");
const Level = srtexture.Level;

/// Which copy of a texture the loadout draws.
pub const Copy = enum {
    /// The ships' copy, `g`.
    green,
    /// The missiles' and guns' copy, `r`.
    red,

    /// The letter the copy's name starts with, before the texture's.
    pub fn letter(copy: Copy) u8 {
        return switch (copy) {
            .green => 'g',
            .red => 'r',
        };
    }

    /// Turns the 8-bit RGBA `levels` of a picture into this copy of it, in place, leaving alpha as
    /// it is. The finest level gives the range of brightness every level is stretched over.
    pub fn tint(copy: Copy, levels: []const Level) void {
        const finest = levels[0];
        const range: Range = .of(finest.texels);
        var ramp: [256][3]u8 = undefined;
        for (&ramp, 0..) |*colour, at| colour.* = copy.shade(range.stretch(@intCast(at)));
        for (levels) |level| {
            std.debug.assert(level.format == .rgba8);
            const pixels: []u8 = @constCast(level.texels);
            var at: usize = 0;
            while (at + 4 <= pixels.len) : (at += 4) {
                pixels[at..][0..3].* = ramp[brightness(pixels[at..][0..3].*)];
            }
        }
    }

    /// The colour of brightness `stretched`, from 0 to 1 over the picture's range.
    fn shade(copy: Copy, stretched: f32) [3]u8 {
        return switch (copy) {
            .green => {
                const green = std.math.pow(f32, stretched, green_curve);
                return .{ channel(green * green_red), channel(green), channel(green * green_blue) };
            },
            .red => .{ channel(red_floor + (1 - red_floor) * std.math.pow(f32, stretched, red_curve)), 0, 0 },
        };
    }
};

/// The share of a picture's pixels left out at either end of its range of brightness, so that a
/// few stray pixels don't flatten the rest.
const range_share = 0.01;

/// The power the green copy's curve raises the stretched brightness to.
const green_curve = 0.6;
/// The red and the blue of the green copy, each a share of its green.
const green_red = 0.092;
const green_blue = 0.051;

/// The power the red copy's curve raises the stretched brightness to.
const red_curve = 0.5;
/// The red of the darkest pixels of the red copy, which never goes black.
const red_floor = 50.0 / 255.0;

/// The range of brightness a picture's pixels span, less the share `range_share` at either end.
const Range = struct {
    darkest: u8,
    brightest: u8,

    fn of(pixels: []const u8) Range {
        var counts: [256]usize = @splat(0);
        var at: usize = 0;
        while (at + 4 <= pixels.len) : (at += 4) counts[brightness(pixels[at..][0..3].*)] += 1;
        const total = pixels.len / 4;
        const cut: usize = @intFromFloat(@as(f32, @floatFromInt(total)) * range_share);
        return .{ .darkest = beyond(&counts, cut, .up), .brightest = beyond(&counts, cut, .down) };
    }

    /// Where `value` stands in the range, from 0 to 1.
    fn stretch(range: Range, value: u8) f32 {
        if (range.brightest <= range.darkest) return if (value >= range.brightest) 1 else 0;
        const from: f32 = @floatFromInt(range.darkest);
        const span: f32 = @floatFromInt(range.brightest - range.darkest);
        return std.math.clamp((@as(f32, @floatFromInt(value)) - from) / span, 0, 1);
    }

    /// The first brightness, counting from the dark end or the bright one, past `cut` pixels.
    fn beyond(counts: *const [256]usize, cut: usize, way: enum { up, down }) u8 {
        var seen: usize = 0;
        for (0..256) |step| {
            const value: u8 = @intCast(if (way == .up) step else 255 - step);
            seen += counts[value];
            if (seen > cut) return value;
        }
        return if (way == .up) 0 else 255;
    }
};

/// The brightness of a colour, with the weights of ITU-R BT.601.
fn brightness(rgb: [3]u8) u8 {
    const sum = @as(u32, rgb[0]) * 299 + @as(u32, rgb[1]) * 587 + @as(u32, rgb[2]) * 114;
    return @intCast((sum + 500) / 1000);
}

fn channel(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

test "Copy.tint" {
    // A ramp from black to mid grey, with alpha that stays.
    var pixels: [128 * 4]u8 = undefined;
    for (0..128) |at| pixels[at * 4 ..][0..4].* = .{ @intCast(at), @intCast(at), @intCast(at), 0x80 };
    var green = pixels;
    Copy.green.tint(&.{.{ .width = 128, .height = 1, .texels = &green }});
    // Stretched over its own range: the darkest pixel is black, the brightest full green, with a
    // little red and blue, and it rises all the way.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0x80 }, green[0..4].*);
    try std.testing.expectEqual([4]u8{ 23, 255, 13, 0x80 }, green[127 * 4 ..][0..4].*);
    for (1..128) |at| try std.testing.expect(green[at * 4 + 1] >= green[(at - 1) * 4 + 1]);
    // Halfway up its range, the curve is well past half.
    try std.testing.expect(green[64 * 4 + 1] > 160);

    var red = pixels;
    Copy.red.tint(&.{.{ .width = 128, .height = 1, .texels = &red }});
    try std.testing.expectEqual([4]u8{ 50, 0, 0, 0x80 }, red[0..4].*);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 0x80 }, red[127 * 4 ..][0..4].*);
}

test "Range.of" {
    // A few stray pixels at either end don't count.
    var pixels: [200 * 4]u8 = undefined;
    for (0..200) |at| {
        const value: u8 = if (at == 0) 0 else if (at == 199) 255 else 100 + @as(u8, @intCast(at % 50));
        pixels[at * 4 ..][0..4].* = .{ value, value, value, 0xFF };
    }
    const range: Range = .of(&pixels);
    try std.testing.expectEqual(Range{ .darkest = 100, .brightest = 149 }, range);
    try std.testing.expectEqual(0, range.stretch(40));
    try std.testing.expectEqual(1, range.stretch(200));
    // A picture of one colour is all at the top of its range.
    const flat: Range = .{ .darkest = 9, .brightest = 9 };
    try std.testing.expectEqual(1, flat.stretch(9));
}
