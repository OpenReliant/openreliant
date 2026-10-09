//! Battlestar Galactica's textures (`.btga`), binary files (`resource.zig`) of one section: a
//! 128-byte header, a palette where the texels are indices, and the texels of every level, largest
//! first, each level swizzled as the Xbox keeps textures (`xbox/swizzle.zig`).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const layout = @import("../../layout.zig");
const swizzle = @import("../../xbox/swizzle.zig");
const resource = @import("resource.zig");

/// How a texture's texels hold their colour: the Xbox's Direct3D formats, by the Xbox's numbers.
pub const Format = enum(u32) {
    /// 8-bit blue, green, red and alpha.
    a8r8g8b8 = 0x06,
    /// 8-bit blue, green and red, and a byte that isn't used.
    x8r8g8b8 = 0x07,
    /// An 8-bit index into the palette.
    p8 = 0x0B,
    _,

    /// The bytes of one texel.
    pub fn texelSize(format: Format) ?usize {
        return switch (format) {
            .a8r8g8b8, .x8r8g8b8 => 4,
            .p8 => 1,
            _ => null,
        };
    }
};

pub const Header = extern struct {
    width: u32,
    height: u32,
    levels: u32,
    format: Format,
    _unknown_10: u32,
    /// **Unknown:** 2, 2 and 2 in every texture.
    _unknown_14: [3]u32,
    _unknown_20: [24]u32,

    comptime {
        assert(@sizeOf(Header) == 128);
    }
};

/// A palette's colour: blue, green, red and alpha.
const Colour = [4]u8;

pub const Error = error{
    NotATexture,
    /// A format other than the three the game's textures use.
    UnsupportedFormat,
    /// The texels or the palette are fewer than the header says.
    Truncated,
} || resource.Error;

pub const Texture = struct {
    header: *align(1) const Header,
    /// The palette of a `.p8` texture, empty for the others.
    palette: []const Colour,
    /// The texels of every level.
    texels: []const u8,

    pub fn parse(arena: Allocator, bytes: []const u8) (Error || Allocator.Error)!Texture {
        const file: resource.Resource = try .parse(arena, bytes);
        if (file.sections.len != 1) return error.NotATexture;
        const items = file.sections[0].items;
        const header_bytes = file.sections[0].item(0) orelse return error.NotATexture;
        const header = layout.view(Header, header_bytes) catch return error.NotATexture;
        const texel_size = header.format.texelSize() orelse return error.UnsupportedFormat;
        const paletted = header.format == .p8;
        if (items.len != @as(usize, if (paletted) 3 else 2)) return error.NotATexture;
        if (header.width == 0 or header.height == 0) return error.NotATexture;
        if (!std.math.isPowerOfTwo(header.width) or !std.math.isPowerOfTwo(header.height)) return error.NotATexture;
        const texels = items[items.len - 1];
        if (texels.len < @as(usize, header.width) * header.height * texel_size) return error.Truncated;
        const palette: []const Colour = if (paletted) std.mem.bytesAsSlice(Colour, items[1][0 .. items[1].len / @sizeOf(Colour) * @sizeOf(Colour)]) else &.{};
        return .{ .header = header, .palette = palette, .texels = texels };
    }

    /// Whether the palette's alpha is used: a palette whose alpha is 0 for every colour, as most
    /// are, is of an opaque texture.
    pub fn hasAlpha(texture: Texture) bool {
        return switch (texture.header.format) {
            .p8 => for (texture.palette) |colour| {
                if (colour[3] != 0) break true;
            } else false,
            .a8r8g8b8 => true,
            else => false,
        };
    }

    /// The largest level as 8-bit red, green, blue and alpha, row by row from the top. An index
    /// past the palette is magenta. The caller owns the bytes.
    pub fn rgba(texture: Texture, gpa: Allocator) Allocator.Error![]u8 {
        const width = texture.header.width;
        const height = texture.header.height;
        const count = @as(usize, width) * height;
        const out = try gpa.alloc(u8, count * 4);
        errdefer gpa.free(out);
        const opaque_alpha = !texture.hasAlpha();
        switch (texture.header.format) {
            .p8 => {
                const indices = try gpa.alloc(u8, count);
                defer gpa.free(indices);
                swizzle.unswizzle(u8, texture.texels[0..count], indices, width, height);
                for (indices, 0..) |at, n| {
                    const colour: Colour = if (at < texture.palette.len) texture.palette[at] else missing;
                    out[n * 4 ..][0..4].* = .{ colour[2], colour[1], colour[0], if (opaque_alpha) 255 else colour[3] };
                }
            },
            .a8r8g8b8, .x8r8g8b8 => {
                const colours = std.mem.bytesAsSlice(Colour, out);
                swizzle.unswizzle(Colour, std.mem.bytesAsSlice(Colour, texture.texels[0 .. count * 4]), colours, width, height);
                for (colours) |*colour| colour.* = .{ colour[2], colour[1], colour[0], if (opaque_alpha) 255 else colour[3] };
            },
            // `parse` takes no other format.
            _ => unreachable,
        }
        return out;
    }
};

/// The colour of an index past the palette.
const missing: Colour = .{ 255, 0, 255, 255 };

/// Builds textures, for tests.
pub const testing = struct {
    /// A `.p8` texture `width` by `height` of one level, its texels given swizzled.
    pub fn build(arena: Allocator, width: u32, height: u32, palette: []const Colour, texels: []const u8) Allocator.Error![]u8 {
        var header = std.mem.zeroes(Header);
        header.width = width;
        header.height = height;
        header.levels = 1;
        header.format = .p8;
        header._unknown_14 = @splat(2);
        return resource.testing.build(arena, 1, 0xD9756DD0, &.{&.{ std.mem.asBytes(&header), std.mem.sliceAsBytes(palette), texels }});
    }
};

test Texture {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Blue, green, red: a palette of three colours, its alpha unused.
    const palette = [_]Colour{ .{ 255, 0, 0, 0 }, .{ 0, 255, 0, 0 }, .{ 0, 0, 255, 0 } };
    // A 4 by 2 level whose rows are 0 1 2 0 and 1 2 0 1, swizzled.
    const bytes = try testing.build(arena, 4, 2, &palette, &.{ 0, 1, 1, 2, 2, 0, 0, 1 });
    const texture: Texture = try .parse(arena, bytes);
    try std.testing.expect(!texture.hasAlpha());
    const pixels = try texture.rgba(arena);
    // Red and green swap places, and the unused alpha is opaque.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, pixels[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, pixels[16..20]);

    // A palette with alpha keeps it.
    const clear = [_]Colour{ .{ 0, 0, 0, 0 }, .{ 255, 255, 255, 128 } };
    const glass: Texture = try .parse(arena, try testing.build(arena, 1, 1, &clear, &.{1}));
    try std.testing.expect(glass.hasAlpha());
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 128 }, try glass.rgba(arena));

    try std.testing.expectError(error.Truncated, Texture.parse(arena, try testing.build(arena, 4, 4, &palette, &.{0})));
}
