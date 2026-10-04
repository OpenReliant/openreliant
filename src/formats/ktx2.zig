//! KTX 2.0 files (`.ktx2`), which mods' pictures can come in, compressed for the GPU ahead of time
//! (#503). OpenReliant reads a single 2D picture with its levels, uncompressed by any
//! supercompression: BC1, BC3, BC5 and BC7, and 8-bit RGBA, by their Vulkan formats.
//!
//! **Improvement:** the original reads no KTX2 files.

const std = @import("std");
const texels = @import("texels.zig");
const Format = texels.Format;

pub const extension = ".ktx2";

pub const Error = error{ NotAKtx2, Corrupt, Unsupported };

const identifier = [12]u8{ 0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, '\r', '\n', 0x1A, '\n' };

/// Where the header's fields lie, from the file's start, and where the levels' index starts, with
/// each entry's size: its offset, its length and its length uncompressed, 8 bytes each.
const format_at = 12;
const width_at = 20;
const height_at = 24;
const depth_at = 28;
const layers_at = 32;
const faces_at = 36;
const levels_at = 40;
const supercompression_at = 44;
const index_at = 80;
const entry_size = 24;

/// `bytes`, a KTX2 file, read: its levels are `bytes`' own, in `buffer`.
pub fn read(bytes: []const u8, buffer: *[texels.max_levels][]const u8) Error!texels.Contained {
    if (bytes.len < index_at or !std.mem.eql(u8, bytes[0..identifier.len], &identifier)) return error.NotAKtx2;
    const width = word(bytes, width_at);
    const height = word(bytes, height_at);
    if (width == 0 or height == 0) return error.Corrupt;
    if (word(bytes, depth_at) > 1 or word(bytes, layers_at) > 1 or word(bytes, faces_at) != 1) return error.Unsupported;
    if (word(bytes, supercompression_at) != 0) return error.Unsupported;
    const format = vulkanFormat(word(bytes, format_at)) orelse return error.Unsupported;
    const count: usize = @max(word(bytes, levels_at), 1);
    if (count > texels.max_levels or bytes.len < index_at + count * entry_size) return error.Corrupt;
    for (buffer[0..count], 0..) |*level, index| {
        const entry = bytes[index_at + index * entry_size ..][0..entry_size];
        const offset = std.math.cast(usize, std.mem.readInt(u64, entry[0..8], .little)) orelse return error.Corrupt;
        const length = std.math.cast(usize, std.mem.readInt(u64, entry[8..16], .little)) orelse return error.Corrupt;
        const size = format.size(@max(width >> @intCast(index), 1), @max(height >> @intCast(index), 1));
        if (length != size or offset > bytes.len or bytes.len - offset < length) return error.Corrupt;
        level.* = bytes[offset..][0..length];
    }
    return .{ .width = width, .height = height, .format = format, .levels = buffer[0..count] };
}

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// The format of a Vulkan format number, if OpenReliant reads it: the plain and sRGB ones alike,
/// as OpenReliant takes a picture's colours as sRGB-encoded either way.
fn vulkanFormat(number: u32) ?Format {
    return switch (number) {
        37, 43 => .rgba8,
        131...134 => .bc1,
        137, 138 => .bc3,
        141 => .bc5,
        145, 146 => .bc7,
        else => null,
    };
}

pub const testing = struct {
    /// A KTX2 file of the Vulkan format `vulkan`, `width` by `height`, of `levels`, the finest
    /// first.
    pub fn file(gpa: std.mem.Allocator, vulkan: u32, width: u32, height: u32, levels: []const []const u8) ![]u8 {
        var length: usize = index_at + levels.len * entry_size;
        for (levels) |level| length += level.len;
        const made = try gpa.alloc(u8, length);
        @memset(made, 0);
        @memcpy(made[0..identifier.len], &identifier);
        std.mem.writeInt(u32, made[format_at..][0..4], vulkan, .little);
        std.mem.writeInt(u32, made[width_at..][0..4], width, .little);
        std.mem.writeInt(u32, made[height_at..][0..4], height, .little);
        std.mem.writeInt(u32, made[faces_at..][0..4], 1, .little);
        std.mem.writeInt(u32, made[levels_at..][0..4], @intCast(levels.len), .little);
        var at: usize = index_at + levels.len * entry_size;
        for (levels, 0..) |level, index| {
            const entry = made[index_at + index * entry_size ..][0..entry_size];
            std.mem.writeInt(u64, entry[0..8], at, .little);
            std.mem.writeInt(u64, entry[8..16], level.len, .little);
            std.mem.writeInt(u64, entry[16..24], level.len, .little);
            @memcpy(made[at..][0..level.len], level);
            at += level.len;
        }
        return made;
    }
};

test read {
    const gpa = std.testing.allocator;
    var buffer: [texels.max_levels][]const u8 = undefined;
    // A 4 by 4 BC5 picture: one block, then the smaller levels of one block each.
    const levels = [_][]const u8{ &(@as([16]u8, @splat(1))), &(@as([16]u8, @splat(2))), &(@as([16]u8, @splat(3))) };
    const made = try testing.file(gpa, 141, 4, 4, &levels);
    defer gpa.free(made);
    const picture = try read(made, &buffer);
    try std.testing.expectEqual(Format.bc5, picture.format);
    try std.testing.expectEqual(3, picture.levels.len);
    try std.testing.expectEqualSlices(u8, levels[2], picture.levels[2]);
    // A format it doesn't read, a level of the wrong size, and not a KTX2 file at all.
    const other = try testing.file(gpa, 100, 4, 4, &levels);
    defer gpa.free(other);
    try std.testing.expectError(error.Unsupported, read(other, &buffer));
    const short = try testing.file(gpa, 141, 8, 8, &levels);
    defer gpa.free(short);
    try std.testing.expectError(error.Corrupt, read(short, &buffer));
    try std.testing.expectError(error.NotAKtx2, read("DDS ", &buffer));
}
