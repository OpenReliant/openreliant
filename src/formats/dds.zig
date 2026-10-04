//! DirectDraw Surface files (`.dds`), which mods' pictures can come in, compressed for the GPU
//! ahead of time (#503). OpenReliant reads a single 2D picture with its levels: BC1, BC3, BC5 and
//! BC7, by the old four-character codes or the DX10 header's DXGI formats, and 8-bit RGBA.
//!
//! **Improvement:** the original reads no DDS files.

const std = @import("std");
const texels = @import("texels.zig");
const Format = texels.Format;

pub const extension = ".dds";

pub const Error = error{ NotADds, Corrupt, Unsupported };

const magic = "DDS ";

/// Where the fields lie, from the file's start.
const header_size = 124;
const height_at = 12;
const width_at = 16;
const levels_at = 28;
const pixel_flags_at = 80;
const four_cc_at = 84;
const bit_count_at = 88;
const masks_at = 92;
const caps2_at = 112;
const data_at = 4 + header_size;

/// The DX10 header, after the main one, and where its fields lie from its start.
const dx10_size = 20;
const dxgi_format_at = 0;
const dimension_at = 4;
const array_size_at = 12;

/// `dwFlags`'s bit for a valid mipmap count, the pixel format's bits, and `dwCaps2`'s for a cube
/// map or a volume.
const has_mipmap_count = 0x20000;
const four_cc_flag = 0x4;
const rgb_flag = 0x40;
const cube_or_volume = 0x200 | 0x200000;

/// A DX10 header's dimension for a 2D texture.
const texture_2d = 3;

/// `bytes`, a DDS file, read: its levels are `bytes`' own, cut into `buffer`.
pub fn read(bytes: []const u8, buffer: *[texels.max_levels][]const u8) Error!texels.Contained {
    if (bytes.len < data_at or !std.mem.eql(u8, bytes[0..4], magic)) return error.NotADds;
    if (word(bytes, 4) != header_size) return error.Corrupt;
    const width = word(bytes, width_at);
    const height = word(bytes, height_at);
    if (width == 0 or height == 0) return error.Corrupt;
    if (word(bytes, caps2_at) & cube_or_volume != 0) return error.Unsupported;
    const flags = word(bytes, 8);
    const count: usize = if (flags & has_mipmap_count != 0) @max(word(bytes, levels_at), 1) else 1;
    if (count > texels.max_levels) return error.Corrupt;
    var data = bytes[data_at..];
    const format: Format = if (word(bytes, pixel_flags_at) & four_cc_flag != 0) four: {
        const code = bytes[four_cc_at..][0..4];
        if (std.mem.eql(u8, code, "DX10")) {
            if (data.len < dx10_size) return error.Corrupt;
            const dx10 = data[0..dx10_size];
            data = data[dx10_size..];
            if (word(dx10, dimension_at) != texture_2d or word(dx10, array_size_at) > 1) return error.Unsupported;
            break :four dxgiFormat(word(dx10, dxgi_format_at)) orelse return error.Unsupported;
        }
        break :four fourCc(code) orelse return error.Unsupported;
    } else if (rgba(bytes)) .rgba8 else return error.Unsupported;
    const levels = texels.cut(data, width, height, format, count, buffer) orelse return error.Corrupt;
    return .{ .width = width, .height = height, .format = format, .levels = levels };
}

fn word(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// The format of a four-character code, if OpenReliant reads it.
fn fourCc(code: *const [4]u8) ?Format {
    const named = [_]struct { []const u8, Format }{ .{ "DXT1", .bc1 }, .{ "DXT5", .bc3 }, .{ "ATI2", .bc5 }, .{ "BC5U", .bc5 } };
    for (named) |pair| if (std.mem.eql(u8, code, pair[0])) return pair[1];
    return null;
}

/// The format of a DXGI format number, if OpenReliant reads it: the plain and sRGB ones alike, as
/// OpenReliant takes a picture's colours as sRGB-encoded either way.
fn dxgiFormat(number: u32) ?Format {
    return switch (number) {
        28, 29 => .rgba8,
        71, 72 => .bc1,
        77, 78 => .bc3,
        83 => .bc5,
        98, 99 => .bc7,
        else => null,
    };
}

/// Whether the old header's pixel format is 32-bit RGBA, red in the lowest byte.
fn rgba(bytes: []const u8) bool {
    const masks = [4]u32{ 0xFF, 0xFF00, 0xFF0000, 0xFF000000 };
    if (word(bytes, pixel_flags_at) & rgb_flag == 0 or word(bytes, bit_count_at) != 32) return false;
    for (masks, 0..) |mask, channel| if (word(bytes, masks_at + channel * 4) != mask) return false;
    return true;
}

pub const testing = struct {
    /// A DDS file of the format `code` gives (a four-character code, or `DX10` with `dxgi`), `width`
    /// by `height`, with `count` levels of `data`.
    pub fn file(gpa: std.mem.Allocator, code: *const [4]u8, dxgi: u32, width: u32, height: u32, count: u32, data: []const u8) ![]u8 {
        const dx10 = std.mem.eql(u8, code, "DX10");
        const header: usize = if (dx10) data_at + dx10_size else data_at;
        const made = try gpa.alloc(u8, header + data.len);
        @memset(made, 0);
        @memcpy(made[0..4], magic);
        std.mem.writeInt(u32, made[4..8], header_size, .little);
        std.mem.writeInt(u32, made[8..12], has_mipmap_count, .little);
        std.mem.writeInt(u32, made[height_at..][0..4], height, .little);
        std.mem.writeInt(u32, made[width_at..][0..4], width, .little);
        std.mem.writeInt(u32, made[levels_at..][0..4], count, .little);
        std.mem.writeInt(u32, made[pixel_flags_at..][0..4], four_cc_flag, .little);
        @memcpy(made[four_cc_at..][0..4], code);
        var at: usize = data_at;
        if (dx10) {
            std.mem.writeInt(u32, made[at + dxgi_format_at ..][0..4], dxgi, .little);
            std.mem.writeInt(u32, made[at + dimension_at ..][0..4], texture_2d, .little);
            std.mem.writeInt(u32, made[at + array_size_at ..][0..4], 1, .little);
            at += dx10_size;
        }
        @memcpy(made[at..], data);
        return made;
    }
};

test read {
    const gpa = std.testing.allocator;
    var buffer: [texels.max_levels][]const u8 = undefined;
    // An 8 by 8 BC7 picture with its four levels, in a DX10 header.
    var data: [64 + 16 + 16 + 16]u8 = undefined;
    for (&data, 0..) |*byte, at| byte.* = @intCast(at);
    const file = try testing.file(gpa, "DX10", 98, 8, 8, 4, &data);
    defer gpa.free(file);
    const picture = try read(file, &buffer);
    try std.testing.expectEqual(Format.bc7, picture.format);
    try std.testing.expectEqual(4, picture.levels.len);
    try std.testing.expectEqualSlices(u8, data[64..80], picture.levels[1]);
    // The same as DXT5 by its old code, which is BC3.
    const old = try testing.file(gpa, "DXT5", 0, 8, 8, 4, &data);
    defer gpa.free(old);
    try std.testing.expectEqual(Format.bc3, (try read(old, &buffer)).format);
    // Cut short, a format it doesn't read, and not a DDS file at all.
    try std.testing.expectError(error.Corrupt, read(file[0 .. file.len - 1], &buffer));
    const other = try testing.file(gpa, "DX10", 2, 8, 8, 1, &data);
    defer gpa.free(other);
    try std.testing.expectError(error.Unsupported, read(other, &buffer));
    try std.testing.expectError(error.NotADds, read("PNG", &buffer));
}
