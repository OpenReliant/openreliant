//! `.SPR` sprites: the game's 2D imagery, drawn by WinVFX.
//!
//! These hold the interface rather than the world: the HUD, menus, cursors, briefing screens, the
//! news reader, and a per-ship schematic set. Model textures are not here; see
//! `docs/formats/spr.md`.
//!
//! A file is a version string, a count, and a directory of offsets. What each offset points at is
//! not tagged, and three kinds occur: a shape, a 768-byte palette, or a 256-byte colour remap
//! table. `Block.classify` tells them apart by structure.
//!
//! Pixels are palette indices, run-length encoded one row at a time, with index 0 transparent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const layout = @import("layout.zig");
const png = @import("png.zig");

/// Every shipped file carries this version, stored as four raw bytes rather than a number.
pub const magic = "1.40";

/// The extension a sprite set's file name ends with.
pub const extension = ".spr";

pub const palette_size = 256 * 3;
pub const remap_size = 256;

/// Palette channels hold 6-bit VGA levels, so they occupy the low six bits of each byte.
pub const palette_depth = 6;

pub const Header = extern struct {
    version: [4]u8,
    shape_count: u32,

    comptime {
        assert(@sizeOf(Header) == 8);
    }
};

pub const DirectoryEntry = extern struct {
    offset: u32,
    /// Zero in every entry of every shipped file, so its purpose is **unknown**.
    reserved: u32,

    comptime {
        assert(@sizeOf(DirectoryEntry) == 8);
    }
};

/// The fixed part of a shape, followed immediately by its rows.
pub const ShapeHeader = extern struct {
    /// What `VFX_shape_bounds` returns, a width and a height, which the pause menu places a shape
    /// by and finds the pointer on it with. For the menu's shapes they are `x2 + 1` and `y2 + 1`;
    /// the ship schematics hold the same pair throughout a file.
    bounds: Size,
    /// What `VFX_shape_origin` returns, which the pause menu adds to where it draws a shape: (1, 1)
    /// for each of its shapes, which with their `x1` and `y1` of -1 starts the pixels at the point.
    origin: Size,
    /// Bounds, inclusive, in a frame whose origin is the shape's own anchor. They can be
    /// negative, which is how a sprite is centred on its hotspot.
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,

    pub fn width(header: ShapeHeader) i64 {
        return @as(i64, header.x2) - header.x1 + 1;
    }

    pub fn height(header: ShapeHeader) i64 {
        return @as(i64, header.y2) - header.y1 + 1;
    }

    /// Two 16-bit values as VFX reads them from a word: the second in the low half.
    pub const Size = packed struct(u32) {
        down: u16,
        across: u16,
    };

    comptime {
        assert(@sizeOf(ShapeHeader) == 24);
    }
};

/// Bound on a shape's size and anchor. Real shapes sit far inside it; the degenerate placeholders
/// some files carry hold coordinates near `maxInt(i32)` and are excluded by it.
pub const coordinate_limit = 8192;

pub const Shape = struct {
    header: ShapeHeader,
    /// The rows, still encoded.
    rows: []const u8,

    pub fn width(shape: Shape) u32 {
        return @intCast(shape.header.width());
    }

    pub fn height(shape: Shape) u32 {
        return @intCast(shape.header.height());
    }

    /// Expands the rows into one palette index per pixel, row-major. Index 0 is transparent.
    pub fn decode(shape: Shape, gpa: Allocator) (Error || Allocator.Error)![]u8 {
        const pixels = try gpa.alloc(u8, @as(usize, shape.width()) * shape.height());
        errdefer gpa.free(pixels);
        try shape.decodeInto(pixels, null);
        return pixels;
    }

    /// `decode` into `pixels`, one for each of the shape's, marking in `drawn`, where it is given,
    /// each pixel a row draws, index 0 among them, as `VFX_shape_draw` writes them: what the rows
    /// skip, or leave past their end, stays unmarked.
    pub fn decodeInto(shape: Shape, pixels: []u8, drawn: ?[]bool) Error!void {
        const w = shape.width();
        @memset(pixels, 0);
        if (drawn) |marks| @memset(marks, false);
        var pos: usize = 0;
        for (0..shape.height()) |row| {
            const marks = if (drawn) |all| all[row * w ..][0..w] else null;
            pos = try decodeRow(shape.rows, pos, pixels[row * w ..][0..w], marks);
        }
    }
};

/// A directory entry, once its structure has been recognised.
pub const Block = union(enum) {
    shape: Shape,
    /// 256 RGB triples at 6 bits per channel.
    palette: *const [palette_size]u8,
    /// Maps each palette index to another, for effects such as damage tinting.
    remap: *const [remap_size]u8,
    /// A header whose bounds are nonsense and which carries no rows: a placeholder the exporter
    /// left behind. Nine occur across the shipped files.
    placeholder,

    /// Works out what `offset` points at. `limit` is where the block ends, which is the next
    /// entry's offset or the end of the file.
    ///
    /// Nothing in the file records the kind, so it is recognised by structure. Size alone will not
    /// do it: four shipped shapes are exactly 768 or 256 bytes long. A palette is instead
    /// recognised by its contents, since every channel is a 6-bit level and so never exceeds
    /// `0x3F`, which no shape of either size comes close to satisfying. Whatever is left that
    /// parses as a shape is one, and a remaining block of 256 bytes is a remap table.
    pub fn classify(data: []const u8, offset: usize, limit: usize) Block {
        const size = limit -| offset;
        if (size == palette_size and offset + palette_size <= data.len) {
            const candidate = data[offset..][0..palette_size];
            if (std.mem.max(u8, candidate) <= (1 << palette_depth) - 1) {
                return .{ .palette = candidate };
            }
        }
        if (readShape(data, offset, limit)) |shape| return .{ .shape = shape };
        if (size == remap_size and offset + remap_size <= data.len) {
            return .{ .remap = data[offset..][0..remap_size] };
        }
        return .placeholder;
    }
};

pub const Error = error{
    NotASprite,
    /// The directory or a block runs past the end of the file.
    Truncated,
    /// A row's opcodes end before the row does.
    RowTruncated,
};

pub const Sprite = struct {
    data: []const u8,
    entries: []align(1) const DirectoryEntry,

    pub fn parse(data: []const u8) Error!Sprite {
        const header = layout.view(Header, data) catch return error.NotASprite;
        if (!std.mem.eql(u8, &header.version, magic)) return error.NotASprite;
        return .{
            .data = data,
            .entries = layout.array(DirectoryEntry, data[@sizeOf(Header)..], header.shape_count) catch return error.Truncated,
        };
    }

    pub fn count(sprite: Sprite) usize {
        return sprite.entries.len;
    }

    /// Where the block at `index` ends: the next entry's offset, or the end of the file.
    ///
    /// Entries are in ascending offset order in every shipped file, which is what makes this work.
    pub fn blockEnd(sprite: Sprite, index: usize) usize {
        if (index + 1 < sprite.entries.len) {
            const next = sprite.entries[index + 1].offset;
            if (next <= sprite.data.len and next >= sprite.entries[index].offset) return next;
        }
        return sprite.data.len;
    }

    pub fn block(sprite: Sprite, index: usize) Block {
        return .classify(sprite.data, sprite.entries[index].offset, sprite.blockEnd(index));
    }

    /// The palette a shape draws with: the nearest one at or before it, since a file may carry
    /// several and each group of shapes follows its own.
    pub fn paletteFor(sprite: Sprite, index: usize) ?*const [palette_size]u8 {
        var i = index + 1;
        while (i > 0) {
            i -= 1;
            if (sprite.paletteAt(i)) |found| return found;
        }
        return null;
    }

    /// Block `index`'s palette, where the block is one.
    pub fn paletteAt(sprite: Sprite, index: usize) ?*const [palette_size]u8 {
        if (index >= sprite.count()) return null;
        return switch (sprite.block(index)) {
            .palette => |found| found,
            else => null,
        };
    }
};

/// Reads a shape at `offset`, or null if the bytes there are not one.
fn readShape(data: []const u8, offset: usize, limit: usize) ?Shape {
    if (offset > limit or limit > data.len) return null;
    const header = layout.view(ShapeHeader, data[offset..limit]) catch return null;

    for ([_]i32{ header.x1, header.y1, header.x2, header.y2 }) |value| {
        if (value < -coordinate_limit or value > coordinate_limit) return null;
    }
    const w = header.width();
    const h = header.height();
    if (w <= 0 or h <= 0 or w > coordinate_limit or h > coordinate_limit) return null;

    // The rows must fit in the block. A block whose opcodes run past it is not a shape.
    const rows = data[offset + @sizeOf(ShapeHeader) .. limit];
    var pos: usize = 0;
    var scratch: [coordinate_limit]u8 = undefined;
    for (0..@intCast(h)) |_| {
        pos = decodeRow(rows, pos, scratch[0..@intCast(w)], null) catch return null;
    }
    return .{ .header = header.*, .rows = rows };
}

/// Expands one row.
///
/// Each opcode is a control byte: the low bit picks the kind and the rest is a count.
///
///   * `0x00`              end of row, the rest is transparent
///   * even, count > 0     repeat the next byte `count` times
///   * odd, count > 0      copy the next `count` bytes
///   * `0x01`              skip the next byte's worth of pixels, leaving them transparent
fn decodeRow(rows: []const u8, start: usize, dest: []u8, drawn: ?[]bool) Error!usize {
    var pos = start;
    var x: usize = 0;

    while (true) {
        if (pos >= rows.len) return error.RowTruncated;
        const control = rows[pos];
        pos += 1;
        if (control == 0) return pos;

        const count = control >> 1;
        if (control & 1 == 0) {
            if (pos >= rows.len) return error.RowTruncated;
            const color = rows[pos];
            pos += 1;
            const span = @min(count, dest.len -| x);
            @memset(dest[x..][0..span], color);
            if (drawn) |marks| @memset(marks[x..][0..span], true);
            x += count;
        } else if (count == 0) {
            if (pos >= rows.len) return error.RowTruncated;
            x += rows[pos];
            pos += 1;
        } else {
            if (pos + count > rows.len) return error.RowTruncated;
            const span = @min(@as(usize, count), dest.len -| x);
            @memcpy(dest[x..][0..span], rows[pos..][0..span]);
            if (drawn) |marks| @memset(marks[x..][0..span], true);
            pos += count;
            x += count;
        }
        if (x > dest.len + coordinate_limit) return error.RowTruncated;
    }
}

/// Expands a 6-bit palette into the 8-bit RGB triples an image file wants.
pub fn expandPalette(palette: *const [palette_size]u8, out: *[palette_size]u8) void {
    for (palette, out) |level, *channel| channel.* = expandLevel(level);
}

/// A 6-bit palette level as an 8-bit one: the top bits repeat into the bottom so full scale stays
/// full.
pub fn expandLevel(level: u8) u8 {
    const six: u6 = @truncate(level);
    return @as(u8, six) << 2 | six >> 4;
}

/// The picture name for shape `index` of the set `set_name`, used by `sltool spr extract` and by
/// the mod pictures that replace shapes: the set's name without its folder or extension, `_`, the
/// index with at least three digits, and the PNG extension.
pub fn pictureName(buffer: []u8, set_name: []const u8, index: usize) error{NoSpaceLeft}![]u8 {
    const stem = std.fs.path.stem(std.fs.path.basenameWindows(set_name));
    return std.fmt.bufPrint(buffer, "{s}_{d:0>3}" ++ png.extension, .{ stem, index });
}

test pictureName {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("HUDHARD_021.png", try pictureName(&buffer, "HUDHARD.SPR", 21));
    try std.testing.expectEqualStrings("rbrief_1234.png", try pictureName(&buffer, "interface\\rbrief.spr", 1234));
    try std.testing.expectError(error.NoSpaceLeft, pictureName(buffer[0..8], "HUDHARD.SPR", 21));
}

test expandLevel {
    try std.testing.expectEqual(0, expandLevel(0));
    try std.testing.expectEqual(0xFF, expandLevel(0x3F));
    try std.testing.expectEqual(0x82, expandLevel(0x20));
    // The two bits above the six are not the level's.
    try std.testing.expectEqual(0xFF, expandLevel(0xFF));
}

test decodeRow {
    var row: [8]u8 = undefined;

    // Repeat: 0x08 is even with count 4, so four copies of the colour follow.
    @memset(&row, 0);
    _ = try decodeRow(&.{ 0x08, 0xAB, 0x00 }, 0, &row, null);
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xAB, 0xAB, 0xAB, 0, 0, 0, 0 }, &row);

    // Literal: 0x07 is odd with count 3.
    @memset(&row, 0);
    _ = try decodeRow(&.{ 0x07, 1, 2, 3, 0x00 }, 0, &row, null);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 0, 0, 0, 0 }, &row);

    // Skip: 0x01 leaves pixels transparent, then a literal lands after them.
    @memset(&row, 0);
    _ = try decodeRow(&.{ 0x01, 5, 0x03, 9, 0x00 }, 0, &row, null);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 9, 0, 0 }, &row);

    // What the runs draw is marked, index 0 among it; what a skip passes over is not.
    @memset(&row, 0);
    var drawn: [8]bool = @splat(false);
    _ = try decodeRow(&.{ 0x04, 0, 0x01, 2, 0x03, 0, 0x00 }, 0, &row, &drawn);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, false, true, false, false, false }, &drawn);

    // A row that ends without its terminator is rejected rather than read past.
    try std.testing.expectError(error.RowTruncated, decodeRow(&.{0x08}, 0, &row, null));
    try std.testing.expectError(error.RowTruncated, decodeRow(&.{ 0x07, 1 }, 0, &row, null));
}

test expandPalette {
    var packed_palette: [palette_size]u8 = @splat(0);
    packed_palette[0] = 0x3F; // full scale at six bits
    packed_palette[1] = 0x20;
    var out: [palette_size]u8 = undefined;
    expandPalette(&packed_palette, &out);
    try std.testing.expectEqual(@as(u8, 0xFF), out[0]);
    try std.testing.expectEqual(@as(u8, 0x82), out[1]);
    try std.testing.expectEqual(@as(u8, 0x00), out[2]);
}

/// Fixtures for the tests here and in the modules that draw sprites.
pub const testing = struct {
    /// A set of a palette, whose index 1 is bright red, and a shape of three pixels by two hung one
    /// left of its anchor: a run of three of index 1, then a pixel skipped and one of index 1.
    pub fn paletteAndShape(gpa: Allocator) Allocator.Error![]u8 {
        var file: std.ArrayList(u8) = .empty;
        errdefer file.deinit(gpa);
        try file.appendSlice(gpa, std.mem.asBytes(&Header{ .version = magic.*, .shape_count = 2 }));
        const directory_at = file.items.len;
        try file.appendNTimes(gpa, 0, 2 * @sizeOf(DirectoryEntry));

        const palette_at = file.items.len;
        try file.appendNTimes(gpa, 0, palette_size);
        file.items[palette_at + 3] = 0x3F;

        const shape_at = file.items.len;
        var header: ShapeHeader = std.mem.zeroes(ShapeHeader);
        header.x1 = -1;
        header.y1 = 0;
        header.x2 = 1;
        header.y2 = 1;
        try file.appendSlice(gpa, std.mem.asBytes(&header));
        try file.appendSlice(gpa, &.{ 0x06, 1, 0x00 });
        try file.appendSlice(gpa, &.{ 0x01, 2, 0x03, 1, 0x00 });

        const directory = std.mem.bytesAsSlice(DirectoryEntry, file.items[directory_at..][0 .. 2 * @sizeOf(DirectoryEntry)]);
        directory[0] = .{ .offset = @intCast(palette_at), .reserved = 0 };
        directory[1] = .{ .offset = @intCast(shape_at), .reserved = 0 };
        return file.toOwnedSlice(gpa);
    }
};

test "parses a sprite with a palette and a shape" {
    const gpa = std.testing.allocator;
    const file = try testing.paletteAndShape(gpa);
    defer gpa.free(file);

    const sprite: Sprite = try .parse(file);
    try std.testing.expectEqual(@as(usize, 2), sprite.count());
    try std.testing.expect(sprite.block(0) == .palette);
    try std.testing.expect(sprite.block(1) == .shape);
    try std.testing.expect(sprite.paletteFor(1) != null);
    // The palette is block 0's alone: the shape's block, and one past the set, hold none.
    try std.testing.expect(sprite.paletteAt(0) != null);
    try std.testing.expectEqual(null, sprite.paletteAt(1));
    try std.testing.expectEqual(null, sprite.paletteAt(2));

    const shape = sprite.block(1).shape;
    try std.testing.expectEqual(@as(u32, 3), shape.width());
    try std.testing.expectEqual(@as(u32, 2), shape.height());

    const pixels = try shape.decode(gpa);
    defer gpa.free(pixels);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 0, 0, 1 }, pixels);
}

test "rejects files that are not sprites" {
    try std.testing.expectError(error.NotASprite, Sprite.parse(&.{}));
    try std.testing.expectError(error.NotASprite, Sprite.parse("2.00" ++ [_]u8{0} ** 4));
    // A count the directory cannot hold.
    var bad: [8]u8 = (magic ++ [_]u8{ 0xFF, 0xFF, 0, 0 }).*;
    try std.testing.expectError(error.Truncated, Sprite.parse(&bad));
}
