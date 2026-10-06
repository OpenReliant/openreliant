//! KTX 2.0 files (`.ktx2`), which mods' pictures can come in, compressed for the GPU ahead of time
//! (#503). OpenReliant reads a single 2D picture with its levels: BC1, BC3, BC5 and BC7, and 8-bit
//! RGBA, by their Vulkan formats. Levels supercompressed with Zstandard, as `toktx --zcmp` writes
//! them, are inflated first (`inflated`).
//!
//! Not read: Basis Universal data, which would need transcoding
//! ([#637](https://github.com/OpenReliant/openreliant/issues/637)).
//!
//! **Improvement:** the original reads no KTX2 files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zstd = std.compress.zstd;
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
/// The data format descriptor's, the key and value data's and the supercompression global data's
/// offsets and lengths, which a file `inflated` makes doesn't have.
const descriptors_at = 48;
const index_at = 80;
const entry_size = 24;

/// The supercompression schemes (`supercompressionScheme`) OpenReliant reads.
const Supercompression = enum(u32) {
    none = 0,
    zstandard = 2,
    _,
};

/// `bytes`, a KTX2 file, read: its levels are `bytes`' own, in `buffer`.
pub fn read(bytes: []const u8, buffer: *[texels.max_levels][]const u8) Error!texels.Contained {
    if (bytes.len < index_at or !std.mem.eql(u8, bytes[0..identifier.len], &identifier)) return error.NotAKtx2;
    const width = word(bytes, width_at);
    const height = word(bytes, height_at);
    if (width == 0 or height == 0) return error.Corrupt;
    if (word(bytes, depth_at) > 1 or word(bytes, layers_at) > 1 or word(bytes, faces_at) != 1) return error.Unsupported;
    if (word(bytes, supercompression_at) != @backingInt(Supercompression.none)) return error.Unsupported;
    const format = vulkanFormat(word(bytes, format_at)) orelse return error.Unsupported;
    const count: usize = @max(word(bytes, levels_at), 1);
    if (count > texels.max_levels or bytes.len < index_at + count * entry_size) return error.Corrupt;
    const index_bytes = bytes[index_at..][0 .. count * entry_size];
    for (buffer[0..count], 0..) |*level, index| {
        const offset = try entryWord(index_bytes, index, 0);
        const length = try entryWord(index_bytes, index, 1);
        const size = format.size(@max(width >> @intCast(index), 1), @max(height >> @intCast(index), 1));
        if (length != size or offset > bytes.len or bytes.len - offset < length) return error.Corrupt;
        level.* = bytes[offset..][0..length];
    }
    return .{ .width = width, .height = height, .format = format, .levels = buffer[0..count] };
}

/// `bytes`, a KTX2 file whose levels are supercompressed with Zstandard, as a file of the same
/// picture without supercompression, made in `gpa`, which `read` takes; null for a file that isn't
/// supercompressed with Zstandard, which `read` takes as it is.
pub fn inflated(gpa: Allocator, bytes: []const u8) (Error || Allocator.Error)!?[]u8 {
    if (bytes.len < index_at or !std.mem.eql(u8, bytes[0..identifier.len], &identifier)) return error.NotAKtx2;
    const scheme: Supercompression = @fromBackingInt(@intCast(word(bytes, supercompression_at)));
    if (scheme != .zstandard) return null;
    const count: usize = @max(word(bytes, levels_at), 1);
    if (count > texels.max_levels or bytes.len < index_at + count * entry_size) return error.Corrupt;
    const index = bytes[index_at..][0 .. count * entry_size];

    var length: usize = index_at + index.len;
    for (0..count) |level| length = std.math.add(usize, length, try entryWord(index, level, 2)) catch return error.Corrupt;
    const made = try gpa.alloc(u8, length);
    errdefer gpa.free(made);
    @memcpy(made[0..index_at], bytes[0..index_at]);
    std.mem.writeInt(u32, made[supercompression_at..][0..4], @backingInt(Supercompression.none), .little);
    @memset(made[descriptors_at..index_at], 0);
    var at: usize = index_at + index.len;
    for (0..count) |level| {
        const offset = try entryWord(index, level, 0);
        const packed_length = try entryWord(index, level, 1);
        const size = try entryWord(index, level, 2);
        if (offset > bytes.len or bytes.len - offset < packed_length) return error.Corrupt;
        var in: std.Io.Reader = .fixed(bytes[offset..][0..packed_length]);
        var out: std.Io.Writer = .fixed(made[at..][0..size]);
        var stream: zstd.Decompress = .init(&in, &.{}, .{});
        const written = stream.reader.streamRemaining(&out) catch return error.Corrupt;
        if (written != size) return error.Corrupt;
        const entry = made[index_at + level * entry_size ..][0..entry_size];
        std.mem.writeInt(u64, entry[0..8], at, .little);
        std.mem.writeInt(u64, entry[8..16], size, .little);
        std.mem.writeInt(u64, entry[16..24], size, .little);
        at += size;
    }
    return made;
}

/// The `field`th 8-byte word of the level index's entry for `level`: its offset, its length, or its
/// length uncompressed.
fn entryWord(index: []const u8, level: usize, field: usize) Error!usize {
    const at = level * entry_size + field * 8;
    return std.math.cast(usize, std.mem.readInt(u64, index[at..][0..8], .little)) orelse error.Corrupt;
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

    /// `file`, with each level a Zstandard frame of raw blocks, as a supercompressed file holds it.
    pub fn zstandardFile(gpa: std.mem.Allocator, vulkan: u32, width: u32, height: u32, levels: []const []const u8) ![]u8 {
        var frames: [texels.max_levels][]u8 = undefined;
        var made: usize = 0;
        defer for (frames[0..made]) |frame| gpa.free(frame);
        for (levels, frames[0..levels.len]) |level, *frame| {
            frame.* = try zstandardFrame(gpa, level);
            made += 1;
        }
        const file_made = try file(gpa, vulkan, width, height, frames[0..levels.len]);
        std.mem.writeInt(u32, file_made[supercompression_at..][0..4], @backingInt(Supercompression.zstandard), .little);
        for (levels, 0..) |level, index| {
            std.mem.writeInt(u64, file_made[index_at + index * entry_size + 16 ..][0..8], level.len, .little);
        }
        return file_made;
    }

    /// A Zstandard frame of `bytes` in one raw block, its size given in a byte, under 256 bytes.
    fn zstandardFrame(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
        const magic = [4]u8{ 0x28, 0xB5, 0x2F, 0xFD };
        // A single segment, its content's size in one byte.
        const descriptor = 0x20;
        const last_raw_block: u24 = 1 | @as(u24, @intCast(bytes.len)) << 3;
        const frame = try gpa.alloc(u8, magic.len + 2 + 3 + bytes.len);
        @memcpy(frame[0..4], &magic);
        frame[4] = descriptor;
        frame[5] = @intCast(bytes.len);
        std.mem.writeInt(u24, frame[6..9], last_raw_block, .little);
        @memcpy(frame[9..], bytes);
        return frame;
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

test inflated {
    const gpa = std.testing.allocator;
    var buffer: [texels.max_levels][]const u8 = undefined;
    const levels = [_][]const u8{ &(@as([16]u8, @splat(1))), &(@as([16]u8, @splat(2))), &(@as([16]u8, @splat(3))) };
    // Supercompressed with Zstandard, it can't be read as it is, and inflated, it reads as the
    // plain one does.
    const packed_file = try testing.zstandardFile(gpa, 141, 4, 4, &levels);
    defer gpa.free(packed_file);
    try std.testing.expectError(error.Unsupported, read(packed_file, &buffer));
    const made = (try inflated(gpa, packed_file)).?;
    defer gpa.free(made);
    const picture = try read(made, &buffer);
    try std.testing.expectEqual(Format.bc5, picture.format);
    try std.testing.expectEqual(3, picture.levels.len);
    for (levels, picture.levels) |level, inflated_level| try std.testing.expectEqualSlices(u8, level, inflated_level);
    // A plain file is read as it is.
    const plain = try testing.file(gpa, 141, 4, 4, &levels);
    defer gpa.free(plain);
    try std.testing.expectEqual(null, try inflated(gpa, plain));
    // A level that inflates to another length than its entry says.
    std.mem.writeInt(u64, packed_file[index_at + 16 ..][0..8], 15, .little);
    try std.testing.expectError(error.Corrupt, inflated(gpa, packed_file));
}
