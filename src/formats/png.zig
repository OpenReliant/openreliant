//! A minimal PNG writer, enough to save the game's images.
//!
//! The game's sprites are 8-bit indexed with one colour reserved for transparency, which PNG
//! represents directly as colour type 3 plus a `tRNS` chunk. Keeping the indices means the output
//! is the original data, not a re-quantised copy of it. Textures, whose formats vary, are written
//! as 8-bit RGBA.
//!
//! Pixel data is deflated with the standard library's compressor, at its default level. Each row of
//! an RGBA picture is filtered first as the difference from the pixel to its left, which deflates
//! far smaller; indices are left as they are, which a filter does not help.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const spr = @import("spr.zig");

pub const signature = "\x89PNG\r\n\x1a\n";

/// 256 RGB triples, 8 bits a channel: the size of a sprite set's palette.
pub const Palette = [spr.palette_size]u8;

pub const Options = struct {
    width: u32,
    height: u32,
    palette: *const Palette,
    /// Index rendered fully transparent, if any.
    transparent: ?u8 = null,
};

pub const Error = error{ DimensionsInvalid, PixelCountMismatch };

/// A palette of greys, entry `i` at `i / full` of white and white from `full` on: `greys(255)`
/// shows the indices themselves as levels of grey.
pub fn greys(comptime full: u8) Palette {
    comptime std.debug.assert(full != 0);
    var palette: Palette = undefined;
    for (0..palette.len / 3) |i| {
        const level: u8 = @intCast(@min(255, i * 255 / full));
        @memset(palette[i * 3 ..][0..3], level);
    }
    return palette;
}

/// Writes an 8-bit indexed PNG. `pixels` is `width * height` palette indices, row-major.
pub fn writeIndexed(
    gpa: Allocator,
    out: *Writer,
    options: Options,
    pixels: []const u8,
) (Error || Allocator.Error || Writer.Error)!void {
    if (options.width == 0 or options.height == 0) return error.DimensionsInvalid;
    if (pixels.len != @as(usize, options.width) * options.height) return error.PixelCountMismatch;

    try writeHeader(out, options.width, options.height, .indexed);
    try writeChunk(out, "PLTE", options.palette);

    if (options.transparent) |index| {
        // Entries before the transparent one are opaque; the chunk can stop right after it.
        const alpha = try gpa.alloc(u8, @as(usize, index) + 1);
        defer gpa.free(alpha);
        @memset(alpha, 0xFF);
        alpha[index] = 0;
        try writeChunk(out, "tRNS", alpha);
    }

    try writePixels(gpa, out, options.width, options.height, 1, pixels, .none);
}

/// Writes an 8-bit RGBA PNG. `pixels` is `width * height` red, green, blue, alpha quadruples,
/// row-major.
pub fn writeRgba(
    gpa: Allocator,
    out: *Writer,
    width: u32,
    height: u32,
    pixels: []const u8,
) (Error || Allocator.Error || Writer.Error)!void {
    if (width == 0 or height == 0) return error.DimensionsInvalid;
    if (pixels.len != @as(usize, width) * height * 4) return error.PixelCountMismatch;
    try writeHeader(out, width, height, .rgba);
    try writePixels(gpa, out, width, height, 4, pixels, .sub);
}

const ColourType = enum(u8) { indexed = 3, rgba = 6 };

/// The signature and the `IHDR` chunk, for 8 bits per sample.
fn writeHeader(out: *Writer, width: u32, height: u32, colour_type: ColourType) Writer.Error!void {
    try out.writeAll(signature);
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8; // bits per sample
    header[9] = @intFromEnum(colour_type);
    header[10] = 0; // deflate
    header[11] = 0; // adaptive filtering
    header[12] = 0; // no interlace
    try writeChunk(out, "IHDR", &header);
}

/// How a scanline is filtered before it is deflated: PNG's filter types, those this writer uses.
const Filter = enum(u8) {
    none = 0,
    /// Each byte less the same byte of the pixel to its left.
    sub = 1,
};

/// The `IDAT` and `IEND` chunks: each scanline filtered by `filter`, behind its filter type, then
/// deflated as a zlib stream.
fn writePixels(
    gpa: Allocator,
    out: *Writer,
    width: u32,
    height: u32,
    bytes_per_pixel: u3,
    pixels: []const u8,
    filter: Filter,
) (Allocator.Error || Writer.Error)!void {
    const stride = @as(usize, width) * bytes_per_pixel;
    const raw = try gpa.alloc(u8, pixels.len + height);
    defer gpa.free(raw);
    for (0..height) |row| {
        const line = pixels[row * stride ..][0..stride];
        const filtered = raw[row * (stride + 1) ..][0 .. stride + 1];
        filtered[0] = @intFromEnum(filter);
        switch (filter) {
            .none => @memcpy(filtered[1..], line),
            .sub => for (filtered[1..], line, 0..) |*byte, value, at| {
                byte.* = value -% if (at >= bytes_per_pixel) line[at - bytes_per_pixel] else 0;
            },
        }
    }

    var deflated: Writer.Allocating = try .initCapacity(gpa, raw.len / 2 + minimum_output);
    defer deflated.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var compress: std.compress.flate.Compress = try .init(&deflated.writer, window, .zlib, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();
    try writeChunk(out, "IDAT", deflated.written());
    try writeChunk(out, "IEND", &.{});
}

/// The least room the compressor asks of what it writes into.
const minimum_output = 9;

fn writeChunk(out: *Writer, name: *const [4]u8, data: []const u8) Writer.Error!void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try out.writeAll(&length);
    try out.writeAll(name);
    try out.writeAll(data);

    var crc: std.hash.crc.Crc32 = .init();
    crc.update(name);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try out.writeAll(&checksum);
}

test "writes a readable indexed PNG" {
    const gpa = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();

    var palette: Palette = @splat(0);
    palette[3] = 0xFF; // index 1 is red

    const pixels = [_]u8{ 0, 1, 1, 0 };
    try writeIndexed(gpa, &buffer.writer, .{ .width = 2, .height = 2, .palette = &palette, .transparent = 0 }, &pixels);

    const png = buffer.written();
    try std.testing.expectEqualSlices(u8, signature, png[0..8]);
    // IHDR, PLTE, tRNS, IDAT and IEND must all be present, in that order.
    var at: usize = 8;
    for ([_][]const u8{ "IHDR", "PLTE", "tRNS", "IDAT", "IEND" }) |name| {
        const length = std.mem.readInt(u32, png[at..][0..4], .big);
        try std.testing.expectEqualStrings(name, png[at + 4 ..][0..4]);
        at += 12 + length;
    }
    try std.testing.expectEqual(png.len, at);
}

test "writes an RGBA PNG" {
    const gpa = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();

    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try writeRgba(gpa, &buffer.writer, 2, 1, &pixels);

    const png = buffer.written();
    try std.testing.expectEqualStrings("IHDR", png[12..16]);
    try std.testing.expectEqual(6, png[16 + 9]); // colour type
    // IDAT holds the one scanline, deflated: its filter type, Sub, the first pixel as it is, and
    // the second less the first.
    const scanlines = try inflated(gpa, png);
    defer gpa.free(scanlines);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2, 3, 4, 4, 4, 4, 4 }, scanlines);

    try std.testing.expectError(error.PixelCountMismatch, writeRgba(gpa, &buffer.writer, 2, 2, &pixels));
    try std.testing.expectError(error.DimensionsInvalid, writeRgba(gpa, &buffer.writer, 0, 1, &.{}));
}

/// The scanlines a PNG's `IDAT` chunk holds, inflated.
fn inflated(gpa: Allocator, png: []const u8) ![]u8 {
    var at: usize = signature.len;
    while (!std.mem.eql(u8, png[at + 4 ..][0..4], "IDAT")) at += 12 + std.mem.readInt(u32, png[at..][0..4], .big);
    const length = std.mem.readInt(u32, png[at..][0..4], .big);
    var input: std.Io.Reader = .fixed(png[at + 8 ..][0..length]);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    return decompress.reader.allocRemaining(gpa, .unlimited);
}

test "a large picture deflates smaller and comes back whole" {
    const gpa = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    // A gradient, which the filter turns into runs.
    const width = 300;
    const height = 200;
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| for (0..width) |x| {
        const at = (y * width + x) * 4;
        pixels[at..][0..4].* = .{ @truncate(x), @truncate(y), @truncate(x + y), 0xFF };
    };
    try writeRgba(gpa, &buffer.writer, width, height, &pixels);
    try std.testing.expect(buffer.written().len < pixels.len / 4);

    const scanlines = try inflated(gpa, buffer.written());
    defer gpa.free(scanlines);
    const stride = width * 4;
    try std.testing.expectEqual(height * (stride + 1), scanlines.len);
    for (0..height) |y| {
        const line = scanlines[y * (stride + 1) ..][0 .. stride + 1];
        try std.testing.expectEqual(@intFromEnum(Filter.sub), line[0]);
        // Undone, the filter gives the row back.
        var row: [stride]u8 = undefined;
        for (&row, line[1..], 0..) |*byte, filtered, at| byte.* = filtered +% if (at >= 4) row[at - 4] else 0;
        try std.testing.expectEqualSlices(u8, pixels[y * stride ..][0..stride], &row);
    }
}

test "rejects mismatched input" {
    const gpa = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    const palette: Palette = @splat(0);

    try std.testing.expectError(error.PixelCountMismatch, writeIndexed(
        gpa,
        &buffer.writer,
        .{ .width = 4, .height = 4, .palette = &palette },
        &.{ 0, 0 },
    ));
    try std.testing.expectError(error.DimensionsInvalid, writeIndexed(
        gpa,
        &buffer.writer,
        .{ .width = 0, .height = 1, .palette = &palette },
        &.{},
    ));
}

test greys {
    // Each index as its own level.
    const levels = greys(255);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 1, 1 }, levels[0..6]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, levels[levels.len - 3 ..]);
    // Levels of coverage up to 16, and white past it.
    const coverage = greys(16);
    try std.testing.expectEqual(127, coverage[8 * 3]);
    try std.testing.expectEqual(255, coverage[16 * 3]);
    try std.testing.expectEqual(255, coverage[200 * 3]);
}
