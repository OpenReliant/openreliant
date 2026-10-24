//! A movie's decoded pictures, and how `BinkCopyToBuffer` turns one into colours
//! (`bink.Bink.copyToBuffer`): each level of Y with the U and V of where it stands, by BT.601 in
//! its limited range, or as a mod's movie says (`Colour`). OpenReliant's improvements on the way
//! (`Look`) are each left out under `--original`.

const std = @import("std");

/// A decoded picture: planes of levels, `y` at the picture's size, `u` and `v` at half its size
/// across and down, and `alpha` at its size where the movie has one, each `strides` bytes to a
/// row. Its levels make colours as `colour` says.
pub const Picture = struct {
    width: u32,
    height: u32,
    y: []const u8,
    u: []const u8,
    v: []const u8,
    alpha: ?[]const u8 = null,
    strides: [4]usize,
    colour: Colour = .{},
};

/// How a picture's levels of Y, U and V make colours: the matrix of BT.601 or BT.709, and the
/// limited range of levels, 16 to 235 for Y and 16 to 240 for U and V, or the full range. A Bink
/// movie's are BT.601's in the limited range; a mod's movie says its own (`bink.Bink`).
pub const Colour = struct {
    matrix: Matrix = .bt601,
    range: Range = .limited,

    pub const Matrix = enum { bt601, bt709 };
    pub const Range = enum { limited, full };
};

/// The factors that turn levels into a colour, in fixed point, 256ths, as the usual converters
/// have them: the level of black, Y's scale, V's share of red, U's and V's of green, and U's of
/// blue.
const Factors = struct {
    black: i32,
    y: i32,
    red_v: i32,
    green_u: i32,
    green_v: i32,
    blue_u: i32,

    /// The factors of `colour`, from its matrix's weights of red and blue in Y and its range's
    /// scales of the levels.
    fn of(colour: Colour) Factors {
        const red: f64, const blue: f64 = switch (colour.matrix) {
            .bt601 => .{ 0.299, 0.114 },
            .bt709 => .{ 0.2126, 0.0722 },
        };
        const green = 1 - red - blue;
        const black: i32, const luma: f64, const chroma: f64 = switch (colour.range) {
            .limited => .{ 16, 255.0 / 219.0, 255.0 / 224.0 },
            .full => .{ 0, 1, 1 },
        };
        return .{
            .black = black,
            .y = fixed(luma),
            .red_v = fixed(2 * (1 - red) * chroma),
            .green_u = fixed(2 * (1 - blue) * blue / green * chroma),
            .green_v = fixed(2 * (1 - red) * red / green * chroma),
            .blue_u = fixed(2 * (1 - blue) * chroma),
        };
    }

    /// `factor` in 256ths, rounded.
    fn fixed(factor: f64) i32 {
        return @intFromFloat(@round(factor * 256));
    }

    /// The colour of levels `y`, `u` and `v`.
    fn rgb(factors: Factors, y: u8, u: u8, v: u8) [3]u8 {
        const c = (@as(i32, y) - factors.black) * factors.y + 128;
        const d = @as(i32, u) - 128;
        const e = @as(i32, v) - 128;
        return .{
            clampLevel((c + factors.red_v * e) >> 8),
            clampLevel((c - factors.green_u * d - factors.green_v * e) >> 8),
            clampLevel((c + factors.blue_u * d) >> 8),
        };
    }
};

comptime {
    // BT.601's in the limited range are the factors the usual converters, and Bink's, use.
    std.debug.assert(std.meta.eql(Factors.of(.{}), Factors{ .black = 16, .y = 298, .red_v = 409, .green_u = 100, .green_v = 208, .blue_u = 516 }));
}

/// The size of each of a picture `width` by `height` pixels' planes, Y, U and V: Y the picture's,
/// U and V half of it across and down, rounded up.
pub fn planeSizes(width: u32, height: u32) [3][2]usize {
    const half: [2]usize = .{ @divCeil(width, 2), @divCeil(height, 2) };
    return .{ .{ width, height }, half, half };
}

/// OpenReliant's improvements on the pictures.
pub const Look = struct {
    /// **Improvement:** the steps at the edges of the 8 by 8 blocks Bink codes a picture in,
    /// smoothed where they are small and the levels either side are even (`deblock`): the blocks
    /// that show in a dark or flat area, as in the front end's transitions.
    deblock: bool = true,
    /// **Improvement:** each pixel's U and V blended from the four nearest of the half-size
    /// planes, where Bink gives a 2 by 2 block of pixels one colour, which shows as steps along a
    /// coloured edge once the picture is drawn large.
    smooth_colour: bool = true,

    pub const original: Look = .{ .deblock = false, .smooth_colour = false };
};

/// Converts `picture` into `rgba`, `pitch` bytes to a row, its top left corner at `at`: a pixel
/// takes its level of Y, and the U and V of the 2 by 2 block it lies in or, with
/// `smooth_colour`, blended from the nearest four (`smoothChroma`). Alpha, where the movie has
/// none, is full.
pub fn convert(picture: Picture, rgba: []u8, pitch: usize, at: [2]usize, smooth_colour: bool) void {
    const factors: Factors = .of(picture.colour);
    const chroma_width, const chroma_height = planeSizes(picture.width, picture.height)[1];
    for (0..picture.height) |row| {
        const out = rgba[(at[1] + row) * pitch + at[0] * 4 ..][0 .. picture.width * 4];
        const y = picture.y[row * picture.strides[0] ..];
        const alpha = if (picture.alpha) |plane| plane[row * picture.strides[3] ..] else null;
        const rows = nearest(row, chroma_height);
        for (0..picture.width) |column| {
            const columns = nearest(column, chroma_width);
            const u, const v = if (smooth_colour) .{
                smoothChroma(picture.u, picture.strides[1], rows, columns),
                smoothChroma(picture.v, picture.strides[2], rows, columns),
            } else .{
                picture.u[row / 2 * picture.strides[1] + column / 2],
                picture.v[row / 2 * picture.strides[2] + column / 2],
            };
            const colour = factors.rgb(y[column], u, v);
            out[column * 4 ..][0..4].* = .{ colour[0], colour[1], colour[2], if (alpha) |levels| levels[column] else 0xFF };
        }
    }
}

/// The two rows, or columns, of a half-size plane a pixel's colour is blended from, the nearer
/// first: a plane's sample stands in the middle of its 2 by 2 block, so a pixel lies a quarter of
/// the way from the nearer to the farther, which is held within the plane.
const Pair = struct { near: usize, far: usize };

/// The pair about pixel `at` of a plane `count` samples long.
fn nearest(at: usize, count: usize) Pair {
    const near = at / 2;
    const far = if (at % 2 == 0) near -| 1 else @min(near + 1, count - 1);
    return .{ .near = near, .far = far };
}

/// The level of `plane`, `stride` bytes to a row, at a pixel between the samples `rows` and
/// `columns` name: three quarters of the nearer and a quarter of the farther, each way, rounded.
fn smoothChroma(plane: []const u8, stride: usize, rows: Pair, columns: Pair) u8 {
    const near = plane[rows.near * stride ..];
    const far = plane[rows.far * stride ..];
    const sum = 9 * @as(u32, near[columns.near]) + 3 * @as(u32, near[columns.far]) +
        3 * @as(u32, far[columns.near]) + @as(u32, far[columns.far]);
    return @intCast((sum + 8) / 16);
}

fn clampLevel(level: i32) u8 {
    return @intCast(std.math.clamp(level, 0, 0xFF));
}

/// The size of the blocks Bink codes a plane in, whatever its kind.
pub const block = 8;

/// The largest step at a block's edge that is smoothed, in levels: past it the edge is taken for
/// an edge in the picture.
pub const largest_step = 12;

/// How far the levels either side of an edge may differ and still be taken as even.
pub const evenness = 3;

/// Smooths the steps at the edges of the 8 by 8 blocks `plane` is coded in, `width` by `height`
/// levels `stride` bytes to a row, where a step is small and the levels on both sides of it are
/// even: across the columns' edges first, then across the rows', as H.264's filter goes. Where
/// three levels either side are even, the step is spread over the four levels nearest it; where
/// only two are, the two at the edge are brought nearer.
pub fn deblock(plane: []u8, width: usize, height: usize, stride: usize) void {
    var column: usize = block;
    while (column + 3 <= width) : (column += block) {
        for (0..height) |row| smooth(plane, row * stride + column, 1);
    }
    var row: usize = block;
    while (row + 3 <= height) : (row += block) {
        for (0..width) |across| smooth(plane, row * stride + across, stride);
    }
}

/// Smooths the step before the level at `at`, the levels `apart` bytes from one another across
/// it: p2, p1 and p0 before it, q0, q1 and q2 from it.
fn smooth(plane: []u8, at: usize, apart: usize) void {
    var levels: [6]i32 = undefined;
    for (&levels, 0..) |*level, index| level.* = plane[at + index * apart - 3 * apart];
    const p2, const p1, const p0, const q0, const q1, const q2 = levels;
    const step = @abs(p0 - q0);
    if (step == 0 or step > largest_step) return;
    if (@abs(p1 - p0) > evenness or @abs(q1 - q0) > evenness) return;
    if (@abs(p2 - p0) <= evenness and @abs(q2 - q0) <= evenness) {
        plane[at - 2 * apart] = @intCast((p2 + p1 + p0 + q0 + 2) >> 2);
        plane[at - apart] = @intCast((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3);
        plane[at] = @intCast((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3);
        plane[at + apart] = @intCast((p0 + q0 + q1 + q2 + 2) >> 2);
    } else {
        const delta = ((q0 - p0) * 4 + (p1 - q1) + 4) >> 3;
        plane[at - apart] = @intCast(std.math.clamp(p0 + delta, 0, 0xFF));
        plane[at] = @intCast(std.math.clamp(q0 - delta, 0, 0xFF));
    }
}

test Factors {
    const bt601: Factors = .of(.{});
    // Limited range: 16 is black, 235 white, and the middle of U and V grey.
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, bt601.rgb(16, 128, 128));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, bt601.rgb(235, 128, 128));
    try std.testing.expectEqual([3]u8{ 128, 128, 128 }, bt601.rgb(126, 128, 128));
    // Red, from BT.601's levels, and within a level of it from BT.709's, which BT.601 takes for a
    // darker red.
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, bt601.rgb(81, 90, 240));
    try std.testing.expectEqual([3]u8{ 255, 1, 0 }, Factors.of(.{ .matrix = .bt709 }).rgb(63, 102, 240));
    try std.testing.expectEqual([3]u8{ 234, 0, 2 }, bt601.rgb(63, 102, 240));
    // Full range: 0 is black and 255 white.
    const full: Factors = .of(.{ .range = .full });
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, full.rgb(0, 128, 128));
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, full.rgb(255, 128, 128));
}

test convert {
    // A picture 4 by 2 of one grey, its U plane a step from 128 to 160 between its two samples.
    const y: [8]u8 = @splat(126);
    const u = [2]u8{ 128, 160 };
    const v = [2]u8{ 128, 128 };
    const picture: Picture = .{ .width = 4, .height = 2, .y = &y, .u = &u, .v = &v, .strides = .{ 4, 2, 2, 0 } };
    var rgba: [4 * 2 * 4]u8 = undefined;
    // Whole blocks: the first two pixels grey, the last two the step's other side.
    convert(picture, &rgba, 16, .{ 0, 0 }, false);
    try std.testing.expectEqual(rgba[4 * 1 + 2], rgba[0 + 2]);
    try std.testing.expect(rgba[4 * 2 + 2] > rgba[4 * 1 + 2]);
    try std.testing.expectEqual(0xFF, rgba[3]);
    // Blended: the second pixel a quarter of the way to the step's other side, the third three
    // quarters, and the edges held within the plane.
    convert(picture, &rgba, 16, .{ 0, 0 }, true);
    const blue = [4]u8{ rgba[2], rgba[4 + 2], rgba[8 + 2], rgba[12 + 2] };
    try std.testing.expect(blue[0] < blue[1] and blue[1] < blue[2] and blue[2] < blue[3]);
    const bt601: Factors = .of(.{});
    try std.testing.expectEqual(bt601.rgb(126, 128, 128)[2], blue[0]);
    try std.testing.expectEqual(bt601.rgb(126, 136, 128)[2], blue[1]);
    try std.testing.expectEqual(bt601.rgb(126, 152, 128)[2], blue[2]);
}

test deblock {
    // Two blocks side by side, even on each side of a step of 8: the step spread over four levels.
    var plane: [16]u8 = .{ 40, 40, 40, 40, 40, 40, 40, 40, 48, 48, 48, 48, 48, 48, 48, 48 };
    deblock(&plane, 16, 1, 16);
    try std.testing.expectEqualSlices(u8, &.{ 40, 40, 40, 40, 40, 40, 42, 43, 45, 46, 48, 48, 48, 48, 48, 48 }, &plane);
    // A step past the largest is an edge in the picture, and stays.
    var edge: [16]u8 = .{ 40, 40, 40, 40, 40, 40, 40, 40, 80, 80, 80, 80, 80, 80, 80, 80 };
    deblock(&edge, 16, 1, 16);
    try std.testing.expectEqual(40, edge[7]);
    try std.testing.expectEqual(80, edge[8]);
    // Detail beside the edge keeps it.
    var detail: [16]u8 = .{ 40, 40, 40, 40, 40, 40, 30, 40, 48, 48, 48, 48, 48, 48, 48, 48 };
    deblock(&detail, 16, 1, 16);
    try std.testing.expectEqual(40, detail[7]);
    // Down the rows as across the columns.
    var column: [16]u8 = .{ 40, 40, 40, 40, 40, 40, 40, 40, 48, 48, 48, 48, 48, 48, 48, 48 };
    deblock(&column, 1, 16, 1);
    try std.testing.expectEqual(43, column[7]);
    try std.testing.expectEqual(45, column[8]);
}
