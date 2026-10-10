//! Morton order, which consoles keep their textures in so that texels near each other on the
//! picture are near each other in memory: a texel's index interleaves the bits of its column and
//! its row. The Dreamcast twiddles its textures this way (`dreamcast/pvr.zig`), and the Xbox
//! swizzles them (`xbox/swizzle.zig`), each with its own order of the two.

const std = @import("std");

/// `value` with the bits of its low half moved apart: bit `i` to bit `2i`.
pub fn spread(value: u32) u32 {
    var v = value & 0xFFFF;
    v = (v | v << 8) & 0x00FF00FF;
    v = (v | v << 4) & 0x0F0F0F0F;
    v = (v | v << 2) & 0x33333333;
    v = (v | v << 1) & 0x55555555;
    return v;
}

test spread {
    try std.testing.expectEqual(0, spread(0));
    try std.testing.expectEqual(0b1, spread(0b1));
    try std.testing.expectEqual(0b101, spread(0b11));
    try std.testing.expectEqual(0b1000101, spread(0b1011));
    try std.testing.expectEqual(0x55555555, spread(0xFFFF));
    // The upper half is left out.
    try std.testing.expectEqual(0, spread(0x10000));
}
