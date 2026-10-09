//! How a picture's levels hold their pixels: 8-bit or 16-bit samples, or blocks of 4 by 4 pixels
//! compressed for a GPU, as DDS and KTX2 files hold them and OpenReliant keeps mods' pictures
//! (#503).

const std = @import("std");

pub const bc5 = @import("texels/bc5.zig");
pub const morton = @import("texels/morton.zig");

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
    /// 16-bit red, green, blue and alpha a pixel, in the machine's byte order: a 16-bit normal map
    /// as it is read and mipmapped (#688).
    rgba16,
    /// 16-bit red and green a pixel, in the machine's byte order: a normal map's x and y, kept at
    /// 16 bits for a GPU that draws it uncompressed.
    rg16,

    /// Which RGBA format it is, as pictures are read and mipmapped; null for another.
    pub fn rgba(format: Format) ?Rgba {
        return switch (format) {
            inline .rgba8, .rgba16 => |tag| @field(Rgba, @tagName(tag)),
            .bc1, .bc3, .bc5, .bc7, .rg16 => null,
        };
    }

    /// Whether it holds blocks of 4 by 4 pixels.
    pub fn compressed(format: Format) bool {
        return switch (format) {
            .rgba8, .rgba16, .rg16 => false,
            .bc1, .bc3, .bc5, .bc7 => true,
        };
    }

    /// The bytes a level `width` by `height` takes: its rows of blocks, the last ones partly
    /// filled, for a compressed format.
    pub fn size(format: Format, width: u32, height: u32) usize {
        return if (format.compressed()) blocks(width) * blocks(height) * format.blockBytes() else @as(usize, width) * height * format.blockBytes();
    }

    /// The bytes of a block of 4 by 4 pixels; for an uncompressed format, of a pixel.
    pub fn blockBytes(format: Format) usize {
        return switch (format) {
            .rgba8, .rg16 => 4,
            .bc1, .rgba16 => 8,
            .bc3, .bc5, .bc7 => 16,
        };
    }
};

/// The formats pictures are read and mipmapped in: 8-bit or 16-bit RGBA.
pub const Rgba = enum {
    rgba8,
    rgba16,

    /// The level format it is.
    pub fn asFormat(rgba: Rgba) Format {
        return switch (rgba) {
            inline else => |tag| @field(Format, @tagName(tag)),
        };
    }
};

/// The side of a compressed format's block, in pixels.
pub const block_side = 4;

/// The blocks across `pixels`, the last partly filled.
pub fn blocks(pixels: u32) usize {
    return @divCeil(@as(usize, pixels), block_side);
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

/// A sample of `Sample`, `u8` or `u16`, as a value from 0 to 1.
pub fn unit(comptime Sample: type, sample: Sample) f32 {
    return @as(f32, @floatFromInt(sample)) / std.math.maxInt(Sample);
}

/// The sample of `Sample` nearest `value`, a value from 0 to 1 held to that range.
pub fn nearest(comptime Sample: type, value: f32) Sample {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * std.math.maxInt(Sample)));
}

test unit {
    try std.testing.expectEqual(1, unit(u8, 255));
    try std.testing.expectApproxEqAbs(0.5, unit(u16, 0x8000), 1e-4);
    try std.testing.expectEqual(128, nearest(u8, 0.5));
    try std.testing.expectEqual(0xFFFF, nearest(u16, 2));
    try std.testing.expectEqual(0, nearest(u8, -1));
}

test Format {
    try std.testing.expectEqual(4 * 4 * 4, Format.rgba8.size(4, 4));
    // 5 by 5 pixels take 2 by 2 blocks; 1 by 1, one.
    try std.testing.expectEqual(4 * 16, Format.bc7.size(5, 5));
    try std.testing.expectEqual(8, Format.bc1.size(1, 1));
    try std.testing.expect(!Format.rgba8.compressed() and Format.bc5.compressed());
    // 16-bit samples: eight bytes a pixel of RGBA, four of RG.
    try std.testing.expectEqual(3 * 8, Format.rgba16.size(3, 1));
    try std.testing.expectEqual(3 * 4, Format.rg16.size(1, 3));
    try std.testing.expect(!Format.rg16.compressed());
    // The RGBA formats, and back.
    try std.testing.expectEqual(.rgba16, Format.rgba16.rgba().?);
    for ([_]Format{ .bc1, .bc7, .rg16 }) |other| try std.testing.expectEqual(null, other.rgba());
    for (std.enums.values(Rgba)) |rgba| try std.testing.expectEqual(rgba, rgba.asFormat().rgba().?);
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

test {
    std.testing.refAllDecls(@This());
}
