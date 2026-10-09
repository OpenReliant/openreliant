//! TIM pictures, the PlayStation's own: a header, a colour table for a picture of palette indices,
//! then the picture. Each block gives the place in video memory it loads to. Star Trek: Invasion
//! keeps its menus' pictures in TIM files and its models' textures in TIM pictures inside them
//! ([PlayStation formats](../../../docs/formats/playstation.md#tim-pictures)).
//!
//! | Offset | Size | Field |
//! |---|---|---|
//! | 0 | 4 | `0x10` |
//! | 4 | 4 | Flags: the depth in bits 0 to 2, and whether a colour table follows in bit 3 |
//! | 8 | | The colour table's block, if any, then the picture's block |
//!
//! A block starts with its length, this 12-byte header included, then its place in video memory
//! and its size: x, y, a width in 16-bit units and a height in rows. The colour table holds one or
//! more palettes of 15-bit colours, a row each.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const layout = @import("../layout.zig");

pub const magic: u32 = 0x10;

pub const Header = extern struct {
    id: u32,
    flags: Flags,

    comptime {
        assert(@sizeOf(Header) == 8);
    }
};

pub const Flags = packed struct(u32) {
    depth: Depth,
    /// A colour table follows the header.
    has_palette: bool,
    _unused: u28,
};

/// How the picture holds its pixels.
pub const Depth = enum(u3) {
    /// Palette indices of 4 bits, the leftmost pixel in the low bits.
    indexed4 = 0,
    /// Palette indices of 8 bits.
    indexed8 = 1,
    /// 15-bit colours (`Colour`).
    direct15 = 2,
    /// 24-bit colours, red first.
    direct24 = 3,
    /// Pictures that mix depths, which nothing here reads.
    mixed = 4,
    _,

    /// The colours a palette needs for the picture's indices; null for direct colour.
    pub fn colours(depth: Depth) ?usize {
        return switch (depth) {
            .indexed4 => 16,
            .indexed8 => 256,
            else => null,
        };
    }

    /// The picture's width in pixels, from its width in 16-bit units of video memory.
    fn pixelsAcross(depth: Depth, units: u32) ?u32 {
        return switch (depth) {
            .indexed4 => units * 4,
            .indexed8 => units * 2,
            .direct15 => units,
            .direct24 => units * 2 / 3,
            .mixed, _ => null,
        };
    }

    pub fn format(depth: Depth, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return layout.formatTagAs(Depth, depth, "depth", writer);
    }
};

/// The header of a block: the colour table or the picture.
pub const Block = extern struct {
    /// The block's length in bytes, this header included.
    length: u32,
    /// Where it loads in video memory.
    x: u16,
    y: u16,
    /// Its width in 16-bit units of video memory, and its height in rows.
    width: u16,
    height: u16,

    comptime {
        assert(@sizeOf(Block) == 12);
    }
};

/// A 15-bit colour. The value `0x0000` is drawn transparent; the flag makes any other colour
/// semi-transparent where the drawing asks for it.
pub const Colour = packed struct(u16) {
    red: u5,
    green: u5,
    blue: u5,
    semi_transparent: bool,

    /// The colour as 8-bit RGBA, each component scaled to full range, `0x0000` transparent.
    pub fn rgba(colour: Colour) [4]u8 {
        const transparent = @as(u16, @bitCast(colour)) == 0;
        return .{ widen(colour.red), widen(colour.green), widen(colour.blue), if (transparent) 0 else 0xFF };
    }

    fn widen(component: u5) u8 {
        return @intCast((@as(u32, component) * 255 + 15) / 31);
    }
};

pub const Error = error{ NotATim, Truncated, UnsupportedDepth, ShortPalette };

pub const Picture = struct {
    depth: Depth,
    /// Its size in pixels.
    width: u32,
    height: u32,
    /// The first palette of the colour table; empty for direct colour.
    palette: []align(1) const Colour,
    /// The pixels, row by row from the top.
    pixels: []const u8,

    pub fn parse(bytes: []const u8) Error!Picture {
        const header = layout.view(Header, bytes) catch return error.NotATim;
        if (header.id != magic) return error.NotATim;
        const depth = header.flags.depth;
        var rest = bytes[@sizeOf(Header)..];

        var palette: []align(1) const Colour = &.{};
        if (header.flags.has_palette) {
            const table = try block(rest);
            palette = layout.array(Colour, table.body, table.header.width) catch return error.Truncated;
            rest = rest[table.header.length..];
        }
        if (depth.colours()) |needed| {
            if (palette.len < needed) return error.ShortPalette;
        }

        const picture = try block(rest);
        const width = depth.pixelsAcross(picture.header.width) orelse return error.UnsupportedDepth;
        const row = @as(usize, picture.header.width) * 2;
        const size = row * picture.header.height;
        if (picture.body.len < size) return error.Truncated;
        return .{ .depth = depth, .width = width, .height = picture.header.height, .palette = palette, .pixels = picture.body[0..size] };
    }

    /// The block at the start of `bytes`, and its body.
    fn block(bytes: []const u8) Error!struct { header: *align(1) const Block, body: []const u8 } {
        const header = layout.view(Block, bytes) catch return error.Truncated;
        if (header.length < @sizeOf(Block) or header.length > bytes.len) return error.Truncated;
        return .{ .header = header, .body = bytes[@sizeOf(Block)..header.length] };
    }

    /// The picture as 8-bit RGBA, row by row from the top.
    pub fn rgba(picture: Picture, gpa: Allocator) Allocator.Error![]u8 {
        const count = @as(usize, picture.width) * picture.height;
        const out = try gpa.alloc(u8, count * 4);
        const row = picture.pixels.len / picture.height;
        for (0..picture.height) |y| {
            const line = picture.pixels[y * row ..][0..row];
            for (0..picture.width) |x| {
                out[(y * picture.width + x) * 4 ..][0..4].* = switch (picture.depth) {
                    .indexed4 => picture.palette[line[x / 2] >> @intCast(x % 2 * 4) & 0x0F].rgba(),
                    .indexed8 => picture.palette[line[x]].rgba(),
                    .direct15 => @as(Colour, @bitCast(std.mem.readInt(u16, line[x * 2 ..][0..2], .little))).rgba(),
                    .direct24 => .{ line[x * 3], line[x * 3 + 1], line[x * 3 + 2], 0xFF },
                    // `parse` gives no picture of another depth.
                    .mixed, _ => unreachable,
                };
            }
        }
        return out;
    }
};

/// Builds pictures, for tests.
pub const testing = struct {
    /// A 4-bit picture of `units` 16-bit units by `rows`, with a palette of 16 colours.
    pub fn indexed4(arena: Allocator, palette: [16]u16, units: u16, rows: u16, pixels: []const u8) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, std.mem.asBytes(&Header{ .id = magic, .flags = .{ .depth = .indexed4, .has_palette = true, ._unused = 0 } }));
        try out.appendSlice(arena, std.mem.asBytes(&Block{ .length = @sizeOf(Block) + 32, .x = 0, .y = 0, .width = 16, .height = 1 }));
        try out.appendSlice(arena, std.mem.sliceAsBytes(&palette));
        try out.appendSlice(arena, std.mem.asBytes(&Block{ .length = @intCast(@sizeOf(Block) + pixels.len), .x = 0, .y = 0, .width = units, .height = rows }));
        try out.appendSlice(arena, pixels);
        return out.items;
    }
};

test Picture {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var palette: [16]u16 = @splat(0);
    palette[1] = 0x001F; // red
    palette[2] = 0x7C00; // blue
    // One unit across is four pixels: indices 1, 0, 2, 1, the leftmost in the low bits.
    const bytes = try testing.indexed4(gpa, palette, 1, 1, &.{ 0x01, 0x12 });
    const picture: Picture = try .parse(bytes);
    try std.testing.expectEqual(4, picture.width);
    try std.testing.expectEqual(1, picture.height);
    const rgba = try picture.rgba(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 255, 255, 255, 0, 0, 255 }, rgba);

    // A picture cut short, and one whose palette is too short for its indices.
    try std.testing.expectError(error.Truncated, Picture.parse(bytes[0 .. bytes.len - 1]));
    const short = try gpa.dupe(u8, bytes);
    std.mem.writeInt(u16, short[8 + 8 ..][0..2], 15, .little);
    try std.testing.expectError(error.ShortPalette, Picture.parse(short));
    try std.testing.expectError(error.NotATim, Picture.parse("TIM?"));
}

test Colour {
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, (@as(Colour, @bitCast(@as(u16, 0)))).rgba());
    // Black with the flag set is drawn, not left out.
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, (@as(Colour, @bitCast(@as(u16, 0x8000)))).rgba());
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, (@as(Colour, @bitCast(@as(u16, 0x7FFF)))).rgba());
}
