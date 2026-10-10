//! The Xbox's swizzled textures: a level's texels in Morton order (`texels.morton`), the column's
//! bits in the even places and the row's in the odd ones. In a level wider than it is tall, or
//! taller than it is wide, the longer side's bits past the shorter side's stay together above
//! them, so the level is a run of square blocks.

const std = @import("std");
const assert = std.debug.assert;

const morton = @import("../texels/morton.zig");

/// The index, in a swizzled level `width` by `height`, of the texel at `x`, `y`. Both sides are
/// powers of two.
pub fn index(x: u32, y: u32, width: u32, height: u32) u32 {
    assert(std.math.isPowerOfTwo(width) and std.math.isPowerOfTwo(height));
    const shorter = @min(width, height);
    const shared: u5 = @intCast(std.math.log2_int(u32, shorter));
    const low = morton.spread(x & (shorter - 1)) | morton.spread(y & (shorter - 1)) << 1;
    const high = if (width > height) x >> shared else y >> shared;
    return low | high << (2 * shared);
}

/// Copies the swizzled level `from`, `width` by `height` texels, into `to` row by row from the top.
pub fn unswizzle(comptime Texel: type, from: []const Texel, to: []Texel, width: u32, height: u32) void {
    assert(from.len >= @as(usize, width) * height and to.len == @as(usize, width) * height);
    for (0..height) |y| for (0..width) |x| {
        to[y * width + x] = from[index(@intCast(x), @intCast(y), width, height)];
    };
}

test index {
    // A square level interleaves the column's bits with the row's, the column's first.
    try std.testing.expectEqual(0, index(0, 0, 4, 4));
    try std.testing.expectEqual(1, index(1, 0, 4, 4));
    try std.testing.expectEqual(2, index(0, 1, 4, 4));
    try std.testing.expectEqual(3, index(1, 1, 4, 4));
    try std.testing.expectEqual(4, index(2, 0, 4, 4));
    try std.testing.expectEqual(15, index(3, 3, 4, 4));
    // A level twice as wide as it is tall is two square blocks side by side.
    try std.testing.expectEqual(4, index(2, 0, 4, 2));
    try std.testing.expectEqual(7, index(3, 1, 4, 2));
    // One twice as tall is two blocks one above the other.
    try std.testing.expectEqual(4, index(0, 2, 2, 4));
    // A level one texel across keeps its texels in order.
    try std.testing.expectEqual(5, index(0, 5, 1, 8));
}

test unswizzle {
    const swizzled = [_]u8{ 0, 1, 4, 5, 2, 3, 6, 7 };
    var rows: [8]u8 = undefined;
    unswizzle(u8, &swizzled, &rows, 4, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, &rows);
}
