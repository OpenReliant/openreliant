//! PNG files: a minimal writer, enough to save the game's images, and a reader for the pictures in
//! mods, with any colour type, bit depth and interlacing.
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

/// The extension a PNG file's name ends with.
pub const extension = ".png";

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

/// The colour types PNG defines, as `IHDR` gives them.
const ColourType = enum(u8) {
    grey = 0,
    rgb = 2,
    indexed = 3,
    grey_alpha = 4,
    rgba = 6,

    /// The samples a pixel has.
    fn channels(colour: ColourType) u8 {
        return switch (colour) {
            .grey, .indexed => 1,
            .grey_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }

    /// Whether PNG gives the colour type samples of `depth` bits.
    fn takes(colour: ColourType, depth: u8) bool {
        const depths: []const u8 = switch (colour) {
            .grey => &.{ 1, 2, 4, 8, 16 },
            .indexed => &.{ 1, 2, 4, 8 },
            .rgb, .grey_alpha, .rgba => &.{ 8, 16 },
        };
        return std.mem.indexOfScalar(u8, depths, depth) != null;
    }
};

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

/// How a scanline is filtered before it is deflated: PNG's filter types, each byte less what it
/// predicts from the bytes before it (`predict`).
const Filter = enum(u8) {
    none = 0,
    /// The same byte of the pixel to its left.
    sub = 1,
    /// The same byte of the row above.
    up = 2,
    /// The mean of the two.
    average = 3,
    /// Paeth's predictor (`paeth`).
    paeth = 4,

    /// What the filter predicts a byte to be, from the same byte of the pixel to its left, of the
    /// row above, and of the pixel above to the left, each 0 past the picture's edge.
    fn predict(filter: Filter, left: u8, above: u8, corner: u8) u8 {
        return switch (filter) {
            .none => 0,
            .sub => left,
            .up => above,
            .average => @intCast((@as(u16, left) + above) / 2),
            .paeth => paeth(left, above, corner),
        };
    }
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
        const above: []const u8 = if (row > 0) pixels[(row - 1) * stride ..][0..stride] else &.{};
        const filtered = raw[row * (stride + 1) ..][0 .. stride + 1];
        filtered[0] = @intFromEnum(filter);
        for (filtered[1..], line, 0..) |*byte, value, at| {
            byte.* = value -% filter.predict(
                if (at >= bytes_per_pixel) line[at - bytes_per_pixel] else 0,
                if (above.len > 0) above[at] else 0,
                if (above.len > 0 and at >= bytes_per_pixel) above[at - bytes_per_pixel] else 0,
            );
        }
    }

    try writeScanlines(gpa, out, raw);
}

/// The `IDAT` and `IEND` chunks of `raw`, scanlines each behind its filter type, deflated as a zlib
/// stream.
fn writeScanlines(gpa: Allocator, out: *Writer, raw: []const u8) (Allocator.Error || Writer.Error)!void {
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

/// A picture read from a PNG file: 8-bit red, green, blue and alpha, row by row from the top.
pub const Picture = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(picture: Picture, gpa: Allocator) void {
        gpa.free(picture.rgba);
    }
};

/// The longest side `read` takes: a picture larger is refused rather than made.
pub const max_side = 16384;

pub const ReadError = Allocator.Error || error{
    /// The file lacks the signature.
    NotAPng,
    /// A chunk runs past the end of the file, fails its checksum or holds what PNG forbids, or the
    /// pixels are not as many as the header says.
    Corrupt,
    /// A colour type, bit depth or method PNG does not define, or a chunk the picture cannot do
    /// without that this reader does not know.
    Unsupported,
    /// A side of 0, or longer than `max_side`.
    BadSize,
};

/// What `IHDR` says of the picture.
const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    colour: ColourType,
    interlaced: bool,

    fn parse(body: []const u8) ReadError!Header {
        if (body.len != 13) return error.Corrupt;
        const width = std.mem.readInt(u32, body[0..4], .big);
        const height = std.mem.readInt(u32, body[4..8], .big);
        if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadSize;
        const colour = std.enums.fromInt(ColourType, body[9]) orelse return error.Unsupported;
        const depth = body[8];
        if (!colour.takes(depth)) return error.Unsupported;
        // Deflate, and adaptive filtering: the only methods PNG defines.
        if (body[10] != 0 or body[11] != 0) return error.Unsupported;
        const interlaced = switch (body[12]) {
            0 => false,
            1 => true,
            else => return error.Unsupported,
        };
        return .{ .width = width, .height = height, .depth = depth, .colour = colour, .interlaced = interlaced };
    }

    /// The bytes of a scanline `width` pixels long, less its filter type.
    fn stride(header: Header, width: u32) usize {
        return (@as(usize, width) * header.colour.channels() * header.depth + 7) / 8;
    }

    /// The bytes between a byte and the same byte of the pixel to its left, as the filters take
    /// them: at least one.
    fn filterStep(header: Header) usize {
        return @max(1, @as(usize, header.colour.channels()) * header.depth / 8);
    }
};

/// A pass over the picture, which takes every `step`th pixel of every `step`th row from `first`:
/// the one pass of a picture not interlaced, or one of the seven of Adam7.
const Pass = struct {
    first: [2]u32,
    step: [2]u32,

    const whole = [_]Pass{.{ .first = .{ 0, 0 }, .step = .{ 1, 1 } }};
    const adam7 = [_]Pass{
        .{ .first = .{ 0, 0 }, .step = .{ 8, 8 } },
        .{ .first = .{ 4, 0 }, .step = .{ 8, 8 } },
        .{ .first = .{ 0, 4 }, .step = .{ 4, 8 } },
        .{ .first = .{ 2, 0 }, .step = .{ 4, 4 } },
        .{ .first = .{ 0, 2 }, .step = .{ 2, 4 } },
        .{ .first = .{ 1, 0 }, .step = .{ 2, 2 } },
        .{ .first = .{ 0, 1 }, .step = .{ 1, 2 } },
    };

    /// The pixels across and the rows it takes of a picture `size`.
    fn size(pass: Pass, picture: [2]u32) [2]u32 {
        var taken: [2]u32 = undefined;
        for (&taken, picture, pass.first, pass.step) |*side, whole_side, first, step| {
            side.* = if (whole_side > first) (whole_side - first + step - 1) / step else 0;
        }
        return taken;
    }
};

/// The picture the PNG file `bytes` holds, as 8-bit RGBA, which the caller owns: a picture of any
/// colour type, bit depth and interlacing PNG defines, each sample scaled to 8 bits, palette
/// entries looked up, and `tRNS`'s transparency applied. Chunks this reader does not know are
/// passed over where PNG lets a reader do without them.
pub fn read(gpa: Allocator, bytes: []const u8) ReadError!Picture {
    return readLimited(gpa, bytes, std.math.maxInt(usize));
}

/// Reads a picture only when its decoded RGBA pixels fit `max_rgba_bytes`.
pub fn readLimited(gpa: Allocator, bytes: []const u8, max_rgba_bytes: usize) ReadError!Picture {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.NotAPng;
    var header: ?Header = null;
    // Each palette entry's red, green, blue and alpha; entries past the palette's end are black.
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 0xFF });
    // The colour `tRNS` makes transparent in a picture of grey or RGB, at the samples' depth.
    var transparent: ?[3]u16 = null;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var at: usize = signature.len;
    while (true) {
        if (bytes.len - at < chunk_overhead) return error.Corrupt;
        const length = std.mem.readInt(u32, bytes[at..][0..4], .big);
        if (length > bytes.len - at - chunk_overhead) return error.Corrupt;
        const named = bytes[at + 4 ..][0 .. 4 + length];
        const checksum = std.mem.readInt(u32, bytes[at + 8 + length ..][0..4], .big);
        if (std.hash.crc.Crc32.hash(named) != checksum) return error.Corrupt;
        at += chunk_overhead + length;
        const name = named[0..4];
        const body = named[4..];
        if (std.mem.eql(u8, name, "IHDR")) {
            header = try .parse(body);
            if (@as(usize, header.?.width) * header.?.height * 4 > max_rgba_bytes) return error.BadSize;
            continue;
        }
        const head = header orelse return error.Corrupt;
        if (std.mem.eql(u8, name, "PLTE")) {
            if (body.len % 3 != 0 or body.len / 3 > palette.len) return error.Corrupt;
            for (palette[0 .. body.len / 3], 0..) |*entry, index| entry[0..3].* = body[index * 3 ..][0..3].*;
        } else if (std.mem.eql(u8, name, "tRNS")) {
            switch (head.colour) {
                .indexed => {
                    if (body.len > palette.len) return error.Corrupt;
                    for (palette[0..body.len], body) |*entry, alpha| entry[3] = alpha;
                },
                .grey => {
                    if (body.len != 2) return error.Corrupt;
                    const grey = std.mem.readInt(u16, body[0..2], .big);
                    transparent = .{ grey, grey, grey };
                },
                .rgb => {
                    if (body.len != 6) return error.Corrupt;
                    var colour: [3]u16 = undefined;
                    for (&colour, 0..) |*level, channel| level.* = std.mem.readInt(u16, body[channel * 2 ..][0..2], .big);
                    transparent = colour;
                },
                // Alpha of their own makes the chunk meaningless; PNG forbids it.
                .grey_alpha, .rgba => return error.Corrupt,
            }
        } else if (std.mem.eql(u8, name, "IDAT")) {
            try data.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, name, "IEND")) {
            break;
        } else if (std.ascii.isUpper(name[0])) {
            // A critical chunk: the picture cannot be read without it.
            return error.Unsupported;
        }
    }
    const head = header orelse return error.Corrupt;
    const passes: []const Pass = if (head.interlaced) &Pass.adam7 else &Pass.whole;

    // Every pass's scanlines, each behind its filter type, inflated as the one zlib stream.
    var filtered_size: usize = 0;
    for (passes) |pass| {
        const across, const rows = pass.size(.{ head.width, head.height });
        if (across > 0) filtered_size += rows * (1 + head.stride(across));
    }
    const filtered = try gpa.alloc(u8, filtered_size);
    defer gpa.free(filtered);
    var input: std.Io.Reader = .fixed(data.items);
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    var inflating: std.Io.Writer = .fixed(filtered);
    _ = decompress.reader.streamRemaining(&inflating) catch return error.Corrupt;
    if (inflating.end != filtered.len) return error.Corrupt;

    const rgba = try gpa.alloc(u8, @as(usize, head.width) * head.height * 4);
    errdefer gpa.free(rgba);
    var lines = filtered;
    for (passes) |pass| {
        const across, const rows = pass.size(.{ head.width, head.height });
        if (across == 0 or rows == 0) continue;
        const stride = head.stride(across);
        const scanlines = lines[0 .. rows * (1 + stride)];
        lines = lines[scanlines.len..];
        try unfilter(scanlines, stride, head.filterStep());
        for (0..rows) |row| {
            const samples = scanlines[row * (1 + stride) + 1 ..][0..stride];
            const y = pass.first[1] + row * pass.step[1];
            for (0..across) |column| {
                const x = pass.first[0] + column * pass.step[0];
                rgba[(y * head.width + x) * 4 ..][0..4].* = pixel(head, samples, column, &palette, transparent);
            }
        }
    }
    return .{ .width = head.width, .height = head.height, .rgba = rgba };
}

test "bounded PNG decoding rejects large dimensions before pixel allocation" {
    const gpa = std.testing.allocator;
    var bytes: std.Io.Writer.Allocating = .init(gpa);
    defer bytes.deinit();
    try writeRgba(gpa, &bytes.writer, 2, 1, &.{ 255, 0, 0, 255, 0, 255, 0, 255 });
    try std.testing.expectError(error.BadSize, readLimited(gpa, bytes.written(), 4));
    const picture = try readLimited(gpa, bytes.written(), 8);
    defer picture.deinit(gpa);
    try std.testing.expectEqual(8, picture.rgba.len);
}

/// A chunk's bytes besides its data: its length, its name and its checksum.
const chunk_overhead = 12;

/// Undoes the filters of `rows`, scanlines of `stride` bytes each behind its filter type, in place.
/// `step` is the bytes from one pixel's to the next (`Header.filterStep`).
fn unfilter(rows: []u8, stride: usize, step: usize) error{Corrupt}!void {
    var previous: []const u8 = &.{};
    var at: usize = 0;
    while (at < rows.len) : (at += 1 + stride) {
        const line = rows[at + 1 ..][0..stride];
        const filter = std.enums.fromInt(Filter, rows[at]) orelse return error.Corrupt;
        for (line, 0..) |*byte, i| {
            byte.* +%= filter.predict(
                if (i >= step) line[i - step] else 0,
                if (previous.len > 0) previous[i] else 0,
                if (previous.len > 0 and i >= step) previous[i - step] else 0,
            );
        }
        previous = line;
    }
}

/// Paeth's predictor: whichever of the bytes to the left, above and above to the left lies nearest
/// their sum less the corner.
fn paeth(left: u8, above: u8, corner: u8) u8 {
    const estimate = @as(i16, left) + above - corner;
    const from_left = @abs(estimate - left);
    const from_above = @abs(estimate - above);
    const from_corner = @abs(estimate - corner);
    if (from_left <= from_above and from_left <= from_corner) return left;
    if (from_above <= from_corner) return above;
    return corner;
}

/// The pixel `column` of the unfiltered scanline `samples`, as 8-bit RGBA.
fn pixel(header: Header, samples: []const u8, column: usize, palette: *const [256][4]u8, transparent: ?[3]u16) [4]u8 {
    const channels = header.colour.channels();
    var raw: [4]u16 = undefined;
    for (raw[0..channels], 0..) |*value, channel| value.* = sample(samples, header.depth, column * channels + channel);
    const full = std.math.maxInt(u8);
    return switch (header.colour) {
        .indexed => palette[@min(raw[0], palette.len - 1)],
        .grey => grey: {
            const level = eightBit(raw[0], header.depth);
            const clear = if (transparent) |key| key[0] == raw[0] else false;
            break :grey .{ level, level, level, if (clear) 0 else full };
        },
        .rgb => rgb: {
            const clear = if (transparent) |key| std.mem.eql(u16, &key, raw[0..3]) else false;
            break :rgb .{ eightBit(raw[0], header.depth), eightBit(raw[1], header.depth), eightBit(raw[2], header.depth), if (clear) 0 else full };
        },
        .grey_alpha => grey: {
            const level = eightBit(raw[0], header.depth);
            break :grey .{ level, level, level, eightBit(raw[1], header.depth) };
        },
        .rgba => .{ eightBit(raw[0], header.depth), eightBit(raw[1], header.depth), eightBit(raw[2], header.depth), eightBit(raw[3], header.depth) },
    };
}

/// The `index`th sample of a scanline of samples `depth` bits each, packed from the high bits of
/// each byte, and big-endian at 16 bits.
fn sample(samples: []const u8, depth: u8, index: usize) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, samples[index * 2 ..][0..2], .big),
        8 => samples[index],
        else => packed_sample: {
            const bit = index * depth;
            const shift: u3 = @intCast(8 - depth - bit % 8);
            const mask = (@as(u8, 1) << @intCast(depth)) - 1;
            break :packed_sample (samples[bit / 8] >> shift) & mask;
        },
    };
}

/// A sample of `depth` bits scaled to 8, rounded to the nearest.
fn eightBit(value: u16, depth: u8) u8 {
    const most = (@as(u32, 1) << @intCast(depth)) - 1;
    return @intCast((@as(u32, value) * std.math.maxInt(u8) + most / 2) / most);
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

/// A chunk for `handMade` to write.
const Chunk = struct { name: *const [4]u8, data: []const u8 };

/// A PNG file of scanlines given as they are stored, behind the header `fields`, for the reader's
/// tests: the signature, `IHDR`, the `chunks` given, then `scanlines` deflated.
fn handMade(gpa: Allocator, fields: Header, chunks: []const Chunk, scanlines: []const u8) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(signature);
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], fields.width, .big);
    std.mem.writeInt(u32, header[4..8], fields.height, .big);
    header[8..13].* = .{ fields.depth, @intFromEnum(fields.colour), 0, 0, @intFromBool(fields.interlaced) };
    try writeChunk(&out.writer, "IHDR", &header);
    for (chunks) |chunk| try writeChunk(&out.writer, chunk.name, chunk.data);
    try writeScanlines(gpa, &out.writer, scanlines);
    return out.toOwnedSlice();
}

test read {
    const gpa = std.testing.allocator;
    // What the writer writes reads back.
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    const pixels = [_]u8{ 1, 2, 3, 4, 250, 6, 7, 128, 9, 10, 11, 12, 13, 14, 15, 255 };
    try writeRgba(gpa, &written.writer, 2, 2, &pixels);
    const picture = try read(gpa, written.written());
    defer picture.deinit(gpa);
    try std.testing.expectEqual(2, picture.width);
    try std.testing.expectEqual(2, picture.height);
    try std.testing.expectEqualSlices(u8, &pixels, picture.rgba);

    // An indexed picture, its transparent index clear.
    written.clearRetainingCapacity();
    var palette: Palette = @splat(0);
    palette[3..6].* = .{ 0xFF, 0x80, 0x00 };
    try writeIndexed(gpa, &written.writer, .{ .width = 3, .height = 1, .palette = &palette, .transparent = 0 }, &.{ 0, 1, 1 });
    const indexed = try read(gpa, written.written());
    defer indexed.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0xFF, 0x80, 0x00, 0xFF, 0xFF, 0x80, 0x00, 0xFF }, indexed.rgba);
}

test "read undoes every filter" {
    const gpa = std.testing.allocator;
    const width = 7;
    const height = 5;
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, at| byte.* = @truncate(at * 37 + at / 5);
    for (std.enums.values(Filter)) |filter| {
        var written: std.Io.Writer.Allocating = .init(gpa);
        defer written.deinit();
        try writeHeader(&written.writer, width, height, .rgba);
        try writePixels(gpa, &written.writer, width, height, 4, &pixels, filter);
        const picture = try read(gpa, written.written());
        defer picture.deinit(gpa);
        try std.testing.expectEqualSlices(u8, &pixels, picture.rgba);
    }
}

test "read takes every colour type and depth" {
    const gpa = std.testing.allocator;
    const Case = struct {
        header: Header,
        chunks: []const Chunk = &.{},
        scanlines: []const u8,
        rgba: []const u8,
    };
    const cases = [_]Case{
        // Grey of one bit: 3 pixels in a byte, from its high bits.
        .{ .header = .{ .width = 3, .height = 1, .depth = 1, .colour = .grey, .interlaced = false }, .scanlines = &.{ 0, 0b1010_0000 }, .rgba = &.{ 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255 } },
        // Grey of four bits, its level 0 made clear by `tRNS`.
        .{ .header = .{ .width = 2, .height = 1, .depth = 4, .colour = .grey, .interlaced = false }, .chunks = &.{.{ .name = "tRNS", .data = &.{ 0, 0 } }}, .scanlines = &.{ 0, 0x0F }, .rgba = &.{ 0, 0, 0, 0, 255, 255, 255, 255 } },
        // RGB of 16 bits, rounded to 8.
        .{ .header = .{ .width = 1, .height = 1, .depth = 16, .colour = .rgb, .interlaced = false }, .scanlines = &.{ 0, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x7F }, .rgba = &.{ 255, 128, 0, 255 } },
        // Grey and alpha of 8 bits.
        .{ .header = .{ .width = 1, .height = 1, .depth = 8, .colour = .grey_alpha, .interlaced = false }, .scanlines = &.{ 0, 0x40, 0x80 }, .rgba = &.{ 0x40, 0x40, 0x40, 0x80 } },
        // Indexed of 2 bits, past the palette's end black.
        .{ .header = .{ .width = 2, .height = 1, .depth = 2, .colour = .indexed, .interlaced = false }, .chunks = &.{.{ .name = "PLTE", .data = &.{ 10, 20, 30 } }}, .scanlines = &.{ 0, 0b0001_0000 }, .rgba = &.{ 10, 20, 30, 255, 0, 0, 0, 255 } },
    };
    for (cases) |case| {
        const bytes = try handMade(gpa, case.header, case.chunks, case.scanlines);
        defer gpa.free(bytes);
        const picture = try read(gpa, bytes);
        defer picture.deinit(gpa);
        try std.testing.expectEqualSlices(u8, case.rgba, picture.rgba);
    }
}

test "read takes interlaced pictures" {
    const gpa = std.testing.allocator;
    // A picture too small for some of Adam7's passes, as its seven passes store it.
    const width = 5;
    const height = 3;
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, at| byte.* = @truncate(at * 11);
    var scanlines: std.ArrayList(u8) = .empty;
    defer scanlines.deinit(gpa);
    for (Pass.adam7) |pass| {
        const across, const rows = pass.size(.{ width, height });
        if (across == 0) continue;
        for (0..rows) |row| {
            try scanlines.append(gpa, @intFromEnum(Filter.none));
            for (0..across) |column| {
                const x = pass.first[0] + column * pass.step[0];
                const y = pass.first[1] + row * pass.step[1];
                try scanlines.appendSlice(gpa, pixels[(y * width + x) * 4 ..][0..4]);
            }
        }
    }
    const bytes = try handMade(gpa, .{ .width = width, .height = height, .depth = 8, .colour = .rgba, .interlaced = true }, &.{}, scanlines.items);
    defer gpa.free(bytes);
    const picture = try read(gpa, bytes);
    defer picture.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &pixels, picture.rgba);
}

test "read refuses what it cannot take" {
    const gpa = std.testing.allocator;
    const plain: Header = .{ .width = 1, .height = 1, .depth = 8, .colour = .grey, .interlaced = false };
    try std.testing.expectError(error.NotAPng, read(gpa, "GIF89a"));
    // A chunk the reader does not know is passed over where it may be, and stops it where not.
    const extra = try handMade(gpa, plain, &.{.{ .name = "tEXt", .data = "Comment\x00mod" }}, &.{ 0, 7 });
    defer gpa.free(extra);
    const picture = try read(gpa, extra);
    picture.deinit(gpa);
    const critical = try handMade(gpa, plain, &.{.{ .name = "CgBI", .data = "" }}, &.{ 0, 7 });
    defer gpa.free(critical);
    try std.testing.expectError(error.Unsupported, read(gpa, critical));
    // A byte changed fails the checksum; pixels short of the header's count are corrupt.
    const damaged = try gpa.dupe(u8, extra);
    defer gpa.free(damaged);
    damaged[signature.len + 8] ^= 1;
    try std.testing.expectError(error.Corrupt, read(gpa, damaged));
    const short = try handMade(gpa, .{ .width = 2, .height = 1, .depth = 8, .colour = .grey, .interlaced = false }, &.{}, &.{ 0, 7 });
    defer gpa.free(short);
    try std.testing.expectError(error.Corrupt, read(gpa, short));
    // No side may be 0, nor a depth be one PNG lacks for the colour type.
    const empty = try handMade(gpa, .{ .width = 0, .height = 1, .depth = 8, .colour = .grey, .interlaced = false }, &.{}, &.{});
    defer gpa.free(empty);
    try std.testing.expectError(error.BadSize, read(gpa, empty));
    const odd = try handMade(gpa, .{ .width = 1, .height = 1, .depth = 4, .colour = .rgb, .interlaced = false }, &.{}, &.{ 0, 0 });
    defer gpa.free(odd);
    try std.testing.expectError(error.Unsupported, read(gpa, odd));
}

test "read lets go of what it made when memory runs out" {
    const gpa = std.testing.allocator;
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try writeRgba(gpa, &written.writer, 3, 2, &(@as([24]u8, @splat(0x7F))));
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn readBack(allocator: Allocator, bytes: []const u8) !void {
            const picture = try read(allocator, bytes);
            picture.deinit(allocator);
        }
    }.readBack, .{written.written()});
}
