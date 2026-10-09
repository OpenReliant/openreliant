//! The Dreamcast's PowerVR texture layouts, as the Dreamcast version of StarLancer keeps its
//! textures (`textures.zig`): square pictures of 16-bit texels, either plain, row by row, or
//! compressed with vector quantization (VQ), with or without mipmaps.
//!
//! A VQ texture is a codebook of 256 entries, each a 2 by 2 block of texels, then one byte for each
//! block of the picture: the codebook entry it takes. The blocks are in twiddled order
//! (`twiddled`). A texture with mipmaps holds the full chain down to 1 by 1, smallest first, so the
//! largest level comes last.

const std = @import("std");

/// The codebook of a VQ texture: 256 entries of 4 texels.
pub const codebook_size = 256 * 4 * @sizeOf(u16);

/// The bytes before the 1 by 1 level of a plain texture's mipmaps.
const plain_mip_padding = 6;

pub const Layout = struct {
    compressed: bool,
    mipmaps: bool,

    /// The bytes a texture `side` by `side` takes.
    pub fn size(layout: Layout, side: u32) usize {
        if (!layout.mipmaps) return if (layout.compressed) codebook_size + blocks(side) else texels(side) * 2;
        // The levels from 2 by 2 up to `side`, after the 1 by 1 level.
        var levels: usize = 0;
        var level: u32 = 2;
        while (level <= side) : (level *= 2) levels += if (layout.compressed) blocks(level) else texels(level) * 2;
        return if (layout.compressed) codebook_size + 1 + levels else plain_mip_padding + 2 + levels;
    }

    /// The largest level's bytes in `data`: its texels, or its blocks' codebook entries.
    fn topLevel(layout: Layout, side: u32, data: []const u8) []const u8 {
        const top = if (layout.compressed) blocks(side) else texels(side) * 2;
        return data[layout.size(side) - top ..][0..top];
    }
};

fn texels(side: u32) usize {
    return @as(usize, side) * side;
}

/// The 2 by 2 blocks of a VQ level, one byte each.
fn blocks(side: u32) usize {
    return texels(side) / 4;
}

/// The index of the block at `x`, `y` in twiddled order: the bits of the row and the column
/// interleaved, the row's in the even bits.
pub fn twiddled(x: u32, y: u32) u32 {
    return spread(y) | spread(x) << 1;
}

/// `value` with its bits moved apart: bit `i` to bit `2i`.
fn spread(value: u32) u32 {
    var v = value & 0xFFFF;
    v = (v | v << 8) & 0x00FF00FF;
    v = (v | v << 4) & 0x0F0F0F0F;
    v = (v | v << 2) & 0x33333333;
    v = (v | v << 1) & 0x55555555;
    return v;
}

pub const Error = error{ BadSize, Truncated };

/// The largest level of the texture `data`, `side` by `side`, as `side * side` texels, row by
/// row from the top, into `out`.
pub fn decode(layout: Layout, side: u32, data: []const u8, out: []u16) Error!void {
    if (side == 0 or !std.math.isPowerOfTwo(side) or (layout.compressed and side < 2)) return error.BadSize;
    if (out.len != texels(side)) return error.BadSize;
    if (data.len < layout.size(side)) return error.Truncated;
    const top = layout.topLevel(side, data);
    if (!layout.compressed) {
        for (out, 0..) |*texel, at| texel.* = std.mem.readInt(u16, top[at * 2 ..][0..2], .little);
        return;
    }
    const book = data[0..codebook_size];
    const half = side / 2;
    for (0..half) |by| for (0..half) |bx| {
        const entry: usize = top[twiddled(@intCast(bx), @intCast(by))];
        // An entry's texels are twiddled too: down the left column, then the right.
        for (0..4) |texel| {
            const x = bx * 2 + texel / 2;
            const y = by * 2 + texel % 2;
            out[y * side + x] = std.mem.readInt(u16, book[(entry * 4 + texel) * 2 ..][0..2], .little);
        }
    };
}

test twiddled {
    // Down the first column, then across: 0 1 / 2 3 for a 2 by 2, and so on in blocks of 4.
    try std.testing.expectEqual(0, twiddled(0, 0));
    try std.testing.expectEqual(1, twiddled(0, 1));
    try std.testing.expectEqual(2, twiddled(1, 0));
    try std.testing.expectEqual(3, twiddled(1, 1));
    try std.testing.expectEqual(4, twiddled(0, 2));
    try std.testing.expectEqual(8, twiddled(2, 0));
    try std.testing.expectEqual(15, twiddled(3, 3));
}

test "the sizes of the layouts" {
    try std.testing.expectEqual(512 * 512 * 2, (Layout{ .compressed = false, .mipmaps = false }).size(512));
    try std.testing.expectEqual(2048 + 256 * 256, (Layout{ .compressed = true, .mipmaps = false }).size(512));
    // 1, then 1 + 4 + 16 blocks for the 2, 4 and 8 levels.
    try std.testing.expectEqual(2048 + 1 + 1 + 4 + 16, (Layout{ .compressed = true, .mipmaps = true }).size(8));
    // 6 bytes of padding and the 1 by 1 texel, then 4 + 16 + 64 texels.
    try std.testing.expectEqual(6 + 2 + (4 + 16 + 64) * 2, (Layout{ .compressed = false, .mipmaps = true }).size(8));
}

test decode {
    // A plain 2 by 2 with mipmaps: the padding and the 1 by 1 level, then the largest, row by row.
    var out: [4]u16 = undefined;
    try decode(.{ .compressed = false, .mipmaps = true }, 2, std.mem.sliceAsBytes(&[_]u16{ 0, 0, 0, 9, 10, 20, 30, 40 }), &out);
    try std.testing.expectEqualSlices(u16, &.{ 10, 20, 30, 40 }, &out);

    // A VQ 4 by 4 with mipmaps: the 1 by 1 and 2 by 2 levels' blocks, then the four blocks of the
    // largest, each taking entry 1, whose texels run down the left column and then the right.
    var data: [codebook_size + 1 + 1 + 4]u8 = @splat(0);
    const entry: [4]u16 = .{ 1, 2, 3, 4 };
    @memcpy(data[8..16], std.mem.sliceAsBytes(&entry));
    @memset(data[codebook_size + 2 ..], 1);
    var big: [16]u16 = undefined;
    try decode(.{ .compressed = true, .mipmaps = true }, 4, &data, &big);
    try std.testing.expectEqualSlices(u16, &.{ 1, 3, 1, 3, 2, 4, 2, 4, 1, 3, 1, 3, 2, 4, 2, 4 }, &big);

    try std.testing.expectError(error.Truncated, decode(.{ .compressed = true, .mipmaps = true }, 4, data[0..20], &big));
    try std.testing.expectError(error.BadSize, decode(.{ .compressed = false, .mipmaps = false }, 3, &data, out[0..3]));
}
