//! How a picture's levels hold their pixels: 8-bit RGBA, or blocks of 4 by 4 pixels compressed for
//! a GPU, as DDS and KTX2 files hold them and OpenReliant keeps mods' pictures (#503).

const std = @import("std");

/// How a level holds its pixels.
pub const Format = enum {
    /// 8-bit red, green, blue and alpha a pixel, row by row from the top.
    rgba8,
    /// BC1: colour, and alpha on or off, in 8 bytes a block.
    bc1,
    /// BC3: colour and alpha in 16 bytes a block.
    bc3,
    /// BC5: two channels, red and green, in 16 bytes a block, for normal maps.
    bc5,
    /// BC7: colour and alpha in 16 bytes a block, finer than BC3.
    bc7,

    /// Whether it holds blocks of 4 by 4 pixels.
    pub fn compressed(format: Format) bool {
        return format != .rgba8;
    }

    /// The bytes a level `width` by `height` takes: its rows of blocks, the last ones partly
    /// filled, for a compressed format.
    pub fn size(format: Format, width: u32, height: u32) usize {
        return switch (format) {
            .rgba8 => @as(usize, width) * height * 4,
            .bc1, .bc3, .bc5, .bc7 => blocks(width) * blocks(height) * format.blockBytes(),
        };
    }

    /// The bytes of a block of 4 by 4 pixels; for 8-bit RGBA, of a pixel.
    pub fn blockBytes(format: Format) usize {
        return switch (format) {
            .rgba8 => 4,
            .bc1 => 8,
            .bc3, .bc5, .bc7 => 16,
        };
    }
};

/// The side of a compressed format's block, in pixels.
pub const block_side = 4;

/// The blocks across `pixels`, the last partly filled.
pub fn blocks(pixels: u32) usize {
    return (@as(usize, pixels) + block_side - 1) / block_side;
}

/// A picture read from a file, its levels the file's own bytes.
pub const Contained = struct {
    width: u32,
    height: u32,
    format: Format,
    /// The finest level first, each half the last, rounding down, to at least a pixel.
    levels: []const []const u8,

    /// The width and height of level `index`.
    pub fn sizeOf(contained: Contained, index: usize) [2]u32 {
        return .{ @max(contained.width >> @intCast(index), 1), @max(contained.height >> @intCast(index), 1) };
    }
};

/// The most levels a picture holds: down to a pixel from 65536.
pub const max_levels = 17;

/// Cuts `data` into the `count` levels of a picture `width` by `height` of `format`, into
/// `buffer`; null where `data` is too short.
pub fn cut(data: []const u8, width: u32, height: u32, format: Format, count: usize, buffer: *[max_levels][]const u8) ?[]const []const u8 {
    var at: usize = 0;
    for (buffer[0..count], 0..) |*level, index| {
        const length = format.size(@max(width >> @intCast(index), 1), @max(height >> @intCast(index), 1));
        if (data.len - at < length) return null;
        level.* = data[at..][0..length];
        at += length;
    }
    return buffer[0..count];
}

test Format {
    try std.testing.expectEqual(4 * 4 * 4, Format.rgba8.size(4, 4));
    // 5 by 5 pixels take 2 by 2 blocks; 1 by 1, one.
    try std.testing.expectEqual(4 * 16, Format.bc7.size(5, 5));
    try std.testing.expectEqual(8, Format.bc1.size(1, 1));
    try std.testing.expect(!Format.rgba8.compressed() and Format.bc5.compressed());
}

test cut {
    var buffer: [max_levels][]const u8 = undefined;
    const data: [32 + 16 + 16]u8 = @splat(0);
    // 8 by 4 in BC7: 2 blocks, then 1, then 1.
    const levels = cut(&data, 8, 4, .bc7, 3, &buffer) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(32, levels[0].len);
    try std.testing.expectEqual(16, levels[2].len);
    try std.testing.expectEqual(null, cut(data[0..60], 8, 4, .bc7, 3, &buffer));
}
