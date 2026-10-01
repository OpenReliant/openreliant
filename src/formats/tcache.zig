//! `tcachehw.dat` and `tcachesw.dat`: Surrender's texture caches (`srTexture.cpp`), which hold every
//! texture the models and effects use, converted and mipmapped ahead of time.
//!
//! A cache is a header, a directory of 1000 entries, used or not, and the pixels. The game reads the
//! header and the whole directory into memory, `texture_cache_header` and `texture_cache`, and each
//! texture's pixels on first use.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Pointer = @import("../engine.zig").Pointer;
const layout = @import("layout.zig");
const tga = @import("tga.zig");

pub const version = 102;

/// The texture cache of the hardware renderers, which `renderer_start` opens (`0x0050A800`).
pub const hardware_name = "tcachehw.dat";

/// Entries the directory has room for.
pub const capacity = 1000;

pub const header_size = 12;
pub const entry_size = 0xF0;

/// Where the pixels start: after the header and the whole directory.
pub const data_start = header_size + capacity * entry_size;

/// Largest side this reader accepts. Not a limit of the engine's.
pub const max_side = std.math.maxInt(u16);

/// Most mipmap levels a texture can have: a side of `max_side` halves this many times, less one,
/// before it reaches 1.
pub const max_levels = std.math.log2_int(u32, max_side) + 1;

pub const Error = error{ Truncated, NotACache, TooManyEntries, BadEntry, UnsupportedFormat };

pub const Header = extern struct {
    /// `102`. The game starts an empty cache over a file with any other.
    version: u32,
    /// Entries in use, from the first.
    count: u32,
    /// End of the pixels: where the next entry's would go.
    end: u32,

    comptime {
        assert(@sizeOf(Header) == header_size);
    }
};

/// One component of a pixel, whose 8-bit value is `((pixel & mask) >> shift) << loss`.
pub const Channel = extern struct {
    mask: u32,
    shift: u32,
    /// Bits of 8 the component lacks.
    loss: u32,

    pub const absent: Channel = .{ .mask = 0, .shift = 0, .loss = 8 };
};

/// A pixel layout: its size, then where each component lies in it. `pixel_format_set`
/// (`0x004C3430`) builds one from masks.
pub const PixelFormat = extern struct {
    /// 1, 2 or 4.
    bytes: u32,
    /// A palette index.
    index: Channel,
    red: Channel,
    green: Channel,
    blue: Channel,
    alpha: Channel,

    comptime {
        assert(@sizeOf(PixelFormat) == 0x40);
    }
};

/// The pixel formats the shipped caches use.
pub const Encoding = enum {
    /// An 8-bit palette index.
    index8,
    /// 16 bits: a palette index in the low byte, alpha in the high byte.
    index8_alpha8,
    /// 16 bits: red, green and blue in 5, 6 and 5 bits, red at the top.
    rgb565,

    pub fn format(encoding: Encoding) PixelFormat {
        const byte: Channel = .{ .mask = 0xFF, .shift = 0, .loss = 0 };
        const none: Channel = .absent;
        return switch (encoding) {
            .index8 => .{ .bytes = 1, .index = byte, .red = none, .green = none, .blue = none, .alpha = none },
            .index8_alpha8 => .{
                .bytes = 2,
                .index = byte,
                .red = none,
                .green = none,
                .blue = none,
                .alpha = .{ .mask = 0xFF00, .shift = 8, .loss = 0 },
            },
            .rgb565 => .{
                .bytes = 2,
                .index = none,
                .red = .{ .mask = 0xF800, .shift = 11, .loss = 3 },
                .green = .{ .mask = 0x07E0, .shift = 5, .loss = 2 },
                .blue = .{ .mask = 0x001F, .shift = 0, .loss = 3 },
                .alpha = none,
            },
        };
    }

    pub fn bytesPerPixel(encoding: Encoding) u2 {
        return switch (encoding) {
            .index8 => 1,
            .index8_alpha8, .rgb565 => 2,
        };
    }

    /// The encoding `format` describes, if it is one of these.
    pub fn of(format_: PixelFormat) ?Encoding {
        inline for (@typeInfo(Encoding).@"enum".fields) |field| {
            const encoding: Encoding = @enumFromInt(field.value);
            if (std.mem.eql(u8, std.mem.asBytes(&format_), std.mem.asBytes(&encoding.format()))) return encoding;
        }
        return null;
    }
};

pub const Flags = packed struct(u32) {
    /// Set on the index-and-alpha entries, and only those.
    alpha: bool = false,
    /// The pixels are a chain of mipmap levels.
    mipmaps: bool = false,
    /// Set on the 8-bit index entries, and only those.
    indexed: bool = false,
    /// Made at run time and kept in memory, never in the file. `texture_find` does not return it
    /// while nothing uses it.
    transient: bool = false,
    /// Makes `image_convert` take another path (`0x004C8850`). **Unknown.**
    _unknown4: bool = false,
    _unknown5: u27 = 0,
};

/// An image as Surrender holds it (`srImage.cpp`): what the texture functions take and what
/// `texture_find` returns.
pub const Image = extern struct {
    /// NUL-terminated, with no directory or extension.
    name: [32]u8,
    /// The entry's own index in the directory.
    index: u32,
    /// Users; the pixels are loaded while it is non-zero. Stale in the file.
    uses: u32,
    flags: Flags,
    /// Mipmap levels, the full-size image first. `image_pixel_count` makes it 1 without
    /// `Flags.mipmaps`.
    levels: u32,
    width: u32,
    height: u32,
    format: PixelFormat,
    /// The pixels in memory. Stale in the file.
    pixels: Pointer(u8),
    _unknown_7c: [0x18]u8,
    /// `200.0` in every entry. **Unknown.**
    _unknown_94: f32,
    /// File offset of the pixels; for a transient image, the address of a copy of them.
    source: u32,
    /// Added to every channel on upload, as a fraction of full scale.
    brightness: f32,
    /// Every channel is scaled by `1 + contrast` on upload.
    contrast: f32,
    /// The driver's record of the uploaded texture. Run-time state, zero in the file.
    device_texture: u32,

    comptime {
        assert(@offsetOf(Image, "flags") == 0x28);
        assert(@offsetOf(Image, "format") == 0x38);
        assert(@offsetOf(Image, "pixels") == 0x78);
        assert(@offsetOf(Image, "source") == 0x98);
        assert(@sizeOf(Image) == 0xA8);
    }
};

/// A directory entry.
pub const Entry = extern struct {
    /// The format and size of the pixels in the file. `texture_find` copies them over the image's
    /// before reading the pixels, since the upload may convert or resize the image in memory.
    stored_format: PixelFormat,
    stored_width: u32,
    stored_height: u32,
    image: Image,

    comptime {
        assert(@offsetOf(Entry, "image") == 0x48);
        assert(@sizeOf(Entry) == entry_size);
    }

    pub fn name(entry: *align(1) const Entry) []const u8 {
        return std.mem.sliceTo(&entry.image.name, 0);
    }
};

/// Pixels in all levels of an image, as `image_pixel_count` (`0x004C85B0`) counts them: each level
/// halves the last, rounding down.
pub fn pixelCount(width: u32, height: u32, levels: u32) u64 {
    var total: u64 = 0;
    var w: u64 = width;
    var h: u64 = height;
    for (0..levels) |_| {
        total += w * h;
        w /= 2;
        h /= 2;
    }
    return total;
}

/// The part of `path` the engine matches entry names against: what follows its last `\`, `/` or
/// `:` (`path_file_name`, `0x004C9DF0`).
pub fn fileName(path: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, path, "\\/:")) |i| i + 1 else 0;
    return path[start..];
}

/// One mipmap level.
pub const Level = struct {
    width: u32,
    height: u32,
    encoding: Encoding,
    /// Row by row from the top.
    pixels: []const u8,

    /// The level as 8-bit RGBA, top row first. Palette indices look up `palette`. A component
    /// narrower than 8 bits is scaled to full range. An encoding without alpha is opaque.
    pub fn rgba(level: Level, gpa: Allocator, palette: *const tga.Palette) Allocator.Error![]u8 {
        const count = @as(usize, level.width) * level.height;
        const out = try gpa.alloc(u8, count * 4);
        for (0..count) |i| {
            const colour: [4]u8 = switch (level.encoding) {
                .index8 => opaqueColour(palette[level.pixels[i]]),
                .index8_alpha8 => blk: {
                    const rgb = palette[level.pixels[i * 2]];
                    break :blk .{ rgb[0], rgb[1], rgb[2], level.pixels[i * 2 + 1] };
                },
                .rgb565 => blk: {
                    const pixel = std.mem.readInt(u16, level.pixels[i * 2 ..][0..2], .little);
                    const layout_565 = comptime Encoding.rgb565.format();
                    break :blk .{ widen(layout_565.red, pixel), widen(layout_565.green, pixel), widen(layout_565.blue, pixel), 0xFF };
                },
            };
            out[i * 4 ..][0..4].* = colour;
        }
        return out;
    }
};

fn opaqueColour(rgb: [3]u8) [4]u8 {
    return .{ rgb[0], rgb[1], rgb[2], 0xFF };
}

/// The component `channel` describes of `pixel`, scaled from its own bits to 8, to the nearest.
fn widen(comptime channel: Channel, pixel: u16) u8 {
    const max = (1 << (8 - channel.loss)) - 1;
    const v: u32 = (pixel & channel.mask) >> channel.shift;
    return @intCast((v * 255 + max / 2) / max);
}

/// An entry whose pixels the file holds.
pub const Texture = struct {
    entry: *align(1) const Entry,
    encoding: Encoding,
    width: u32,
    height: u32,
    levels: u32,
    /// Every level, the full-size image first.
    pixels: []const u8,

    pub fn name(texture: Texture) []const u8 {
        return texture.entry.name();
    }

    /// Level `n`, or null past the last.
    pub fn level(texture: Texture, n: u32) ?Level {
        if (n >= texture.levels) return null;
        const bytes = texture.encoding.bytesPerPixel();
        const offset = pixelCount(texture.width, texture.height, n) * bytes;
        const width = texture.width >> @intCast(n);
        const height = texture.height >> @intCast(n);
        return .{
            .width = width,
            .height = height,
            .encoding = texture.encoding,
            .pixels = texture.pixels[@intCast(offset)..][0 .. @as(usize, width) * height * bytes],
        };
    }
};

pub const Cache = struct {
    header: *align(1) const Header,
    /// The entries in use.
    entries: []align(1) const Entry,
    /// The entries the game can load: all but transient ones, in directory order.
    textures: []const Texture,

    pub fn parse(gpa: Allocator, bytes: []const u8) (Error || Allocator.Error)!Cache {
        const entries = try directory(bytes);
        const header = try layout.view(Header, bytes);

        var textures: std.ArrayList(Texture) = try .initCapacity(gpa, entries.len);
        errdefer textures.deinit(gpa);
        for (entries) |*entry| {
            if (entry.image.flags.transient) continue;
            textures.appendAssumeCapacity(try textureOf(entry, bytes));
        }
        return .{ .header = header, .entries = entries, .textures = try textures.toOwnedSlice(gpa) };
    }

    pub fn deinit(cache: Cache, gpa: Allocator) void {
        gpa.free(cache.textures);
    }

    /// The entries in use, from the cache's header and directory alone: its first `data_start`
    /// bytes.
    pub fn directory(bytes: []const u8) Error![]align(1) const Entry {
        if (bytes.len < data_start) return error.Truncated;
        const header = try layout.view(Header, bytes);
        if (header.version != version) return error.NotACache;
        if (header.count > capacity) return error.TooManyEntries;
        return layout.array(Entry, bytes[header_size..], header.count);
    }

    /// The texture the engine finds for `path` (`texture_find`, `0x004C9E20`): the first entry whose
    /// name is `path`'s file name, ignoring case.
    pub fn find(cache: Cache, path: []const u8) ?Texture {
        const wanted = fileName(path);
        for (cache.entries) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.name(), wanted)) continue;
            if (entry.image.flags.transient) return null;
            for (cache.textures) |candidate| {
                if (candidate.entry == entry) return candidate;
            }
        }
        return null;
    }
};

fn textureOf(entry: *align(1) const Entry, bytes: []const u8) Error!Texture {
    if (std.mem.indexOfScalar(u8, &entry.image.name, 0) == null or entry.name().len == 0) return error.BadEntry;
    const encoding = Encoding.of(entry.stored_format) orelse return error.UnsupportedFormat;
    const width = entry.stored_width;
    const height = entry.stored_height;
    if (width == 0 or height == 0 or width > max_side or height > max_side) return error.BadEntry;
    const levels: u32 = if (entry.image.flags.mipmaps) entry.image.levels else 1;
    if (levels == 0 or levels > max_levels or width >> @intCast(levels - 1) == 0 or height >> @intCast(levels - 1) == 0) {
        return error.BadEntry;
    }
    const size = pixelCount(width, height, levels) * encoding.bytesPerPixel();
    const start = entry.image.source;
    if (start < data_start or start + size > bytes.len) return error.BadEntry;
    return .{
        .entry = entry,
        .encoding = encoding,
        .width = width,
        .height = height,
        .levels = levels,
        .pixels = bytes[start..][0..@intCast(size)],
    };
}

pub const testing = struct {
    pub const Spec = struct {
        name: []const u8,
        encoding: Encoding,
        width: u32,
        height: u32,
        levels: u32 = 1,
        flags: Flags = .{},
    };

    /// A cache holding an entry for each spec, whose pixel bytes count up from 0 across the file.
    pub fn build(gpa: Allocator, specs: []const Spec) Allocator.Error![]u8 {
        var size: usize = data_start;
        for (specs) |spec| size += @intCast(pixelCount(spec.width, spec.height, spec.levels) * spec.encoding.bytesPerPixel());
        const bytes = try gpa.alloc(u8, size);
        @memset(bytes[0..data_start], 0);
        for (bytes[data_start..], 0..) |*byte, i| byte.* = @truncate(i);

        var at: u32 = data_start;
        for (specs, 0..) |spec, i| {
            var entry = std.mem.zeroes(Entry);
            entry.stored_format = spec.encoding.format();
            entry.stored_width = spec.width;
            entry.stored_height = spec.height;
            @memcpy(entry.image.name[0..spec.name.len], spec.name);
            entry.image.index = @intCast(i);
            entry.image.flags = spec.flags;
            entry.image.levels = spec.levels;
            entry.image.width = spec.width;
            entry.image.height = spec.height;
            entry.image.format = entry.stored_format;
            entry.image._unknown_94 = 200.0;
            entry.image.source = at;
            @memcpy(bytes[header_size + i * entry_size ..][0..entry_size], std.mem.asBytes(&entry));
            at += @intCast(pixelCount(spec.width, spec.height, spec.levels) * spec.encoding.bytesPerPixel());
        }
        const header: Header = .{ .version = version, .count = @intCast(specs.len), .end = at };
        @memcpy(bytes[0..header_size], std.mem.asBytes(&header));
        return bytes;
    }
};

test "the pixel formats match the shipped ones" {
    // As they appear in the files: bytes per pixel, then mask, shift and loss for the index, red,
    // green, blue and alpha.
    const rgb565 = [16]u32{ 2, 0, 0, 8, 0xF800, 11, 3, 0x7E0, 5, 2, 0x1F, 0, 3, 0, 0, 8 };
    const index8_alpha8 = [16]u32{ 2, 0xFF, 0, 0, 0, 0, 8, 0, 0, 8, 0, 0, 8, 0xFF00, 8, 0 };
    const index8 = [16]u32{ 1, 0xFF, 0, 0, 0, 0, 8, 0, 0, 8, 0, 0, 8, 0, 0, 8 };
    try std.testing.expectEqual(Encoding.rgb565, Encoding.of(@bitCast(rgb565)).?);
    try std.testing.expectEqual(Encoding.index8_alpha8, Encoding.of(@bitCast(index8_alpha8)).?);
    try std.testing.expectEqual(Encoding.index8, Encoding.of(@bitCast(index8)).?);
    var other = rgb565;
    other[0] = 4;
    try std.testing.expectEqual(null, Encoding.of(@bitCast(other)));
}

test Flags {
    try std.testing.expectEqual(Flags{ .alpha = true, .mipmaps = true }, @as(Flags, @bitCast(@as(u32, 3))));
    try std.testing.expectEqual(Flags{ .mipmaps = true, .indexed = true }, @as(Flags, @bitCast(@as(u32, 6))));
    try std.testing.expectEqual(Flags{ .transient = true }, @as(Flags, @bitCast(@as(u32, 8))));
}

test pixelCount {
    // 256x256 down to 2x2: eight levels.
    try std.testing.expectEqual(87380, pixelCount(256, 256, 8));
    try std.testing.expectEqual(32 * 32 + 16 * 16 + 8 * 8 + 4 * 4 + 2 * 2, pixelCount(32, 32, 5));
    try std.testing.expectEqual(16 * 32 + 8 * 16 + 4 * 8 + 2 * 4, pixelCount(16, 32, 4));
    try std.testing.expectEqual(4, pixelCount(2, 2, 1));
}

test fileName {
    try std.testing.expectEqualStrings("kiev_1", fileName("kiev_1"));
    try std.testing.expectEqualStrings("kiev_1", fileName("C:\\lancer\\art/kiev_1"));
    try std.testing.expectEqualStrings("kiev_1", fileName("d:kiev_1"));
    try std.testing.expectEqualStrings("", fileName("dir\\"));
}

test widen {
    const format = comptime Encoding.rgb565.format();
    try std.testing.expectEqual(0, widen(format.blue, 0));
    try std.testing.expectEqual(255, widen(format.blue, 0x1F));
    try std.testing.expectEqual(255, widen(format.green, 0x3F << 5));
    try std.testing.expectEqual(132, widen(format.blue, 16));
    try std.testing.expectEqual(132, widen(format.red, 16 << 11));
    // Only the channel's own bits count.
    try std.testing.expectEqual(255, widen(format.blue, 0xFFFF));
    try std.testing.expectEqual(0, widen(format.green, 0xF81F));
}

test max_levels {
    // The largest side halves 15 times to reach 1.
    try std.testing.expectEqual(16, max_levels);
    try std.testing.expectEqual(1, max_side >> (max_levels - 1));
}

test Cache {
    const gpa = std.testing.allocator;
    const bytes = try testing.build(gpa, &.{
        .{ .name = "Kiev_1", .encoding = .index8, .width = 8, .height = 4, .levels = 2, .flags = .{ .mipmaps = true, .indexed = true } },
        .{ .name = "loadout", .encoding = .rgb565, .width = 2, .height = 2, .flags = .{ .transient = true } },
        .{ .name = "planet2", .encoding = .index8_alpha8, .width = 2, .height = 2 },
    });
    defer gpa.free(bytes);
    const cache: Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);

    try std.testing.expectEqual(3, cache.entries.len);
    try std.testing.expectEqual(2, cache.textures.len);

    const kiev = cache.find("C:\\art\\KIEV_1").?;
    try std.testing.expectEqualStrings("Kiev_1", kiev.name());
    try std.testing.expectEqual(2, kiev.levels);
    try std.testing.expectEqual(8 * 4 + 4 * 2, kiev.pixels.len);
    const small = kiev.level(1).?;
    try std.testing.expectEqual(4, small.width);
    try std.testing.expectEqual(2, small.height);
    try std.testing.expectEqual(8 * 4, small.pixels[0]);
    try std.testing.expectEqual(null, kiev.level(2));

    // A transient entry is never found, as in the engine at start-up.
    try std.testing.expectEqual(null, cache.find("loadout"));
    try std.testing.expectEqual(null, cache.find("missing"));

    // Without the mipmap flag an entry has one level, whatever it records.
    const planet = cache.find("planet2").?;
    try std.testing.expectEqual(1, planet.levels);
}

test "decodes each encoding" {
    const gpa = std.testing.allocator;
    var palette: tga.Palette = undefined;
    for (&palette, 0..) |*colour, i| colour.* = .{ @truncate(i), 0x10, 0x20 };

    const index8 = try (Level{ .width = 2, .height = 1, .encoding = .index8, .pixels = &.{ 3, 4 } }).rgba(gpa, &palette);
    defer gpa.free(index8);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0x10, 0x20, 0xFF, 4, 0x10, 0x20, 0xFF }, index8);

    const alpha = try (Level{ .width = 1, .height = 1, .encoding = .index8_alpha8, .pixels = &.{ 7, 0x80 } }).rgba(gpa, &palette);
    defer gpa.free(alpha);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0x10, 0x20, 0x80 }, alpha);

    // Pure red, then pure green.
    const direct = try (Level{ .width = 2, .height = 1, .encoding = .rgb565, .pixels = &.{ 0x00, 0xF8, 0xE0, 0x07 } }).rgba(gpa, &palette);
    defer gpa.free(direct);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, direct);
}

test "rejects malformed caches" {
    const gpa = std.testing.allocator;
    const bytes = try testing.build(gpa, &.{.{ .name = "a", .encoding = .index8, .width = 4, .height = 4 }});
    defer gpa.free(bytes);

    try std.testing.expectError(error.Truncated, Cache.parse(gpa, bytes[0..100]));
    // The pixels run past the end.
    try std.testing.expectError(error.BadEntry, Cache.parse(gpa, bytes[0 .. bytes.len - 1]));

    const copy = try gpa.dupe(u8, bytes);
    defer gpa.free(copy);
    copy[0] = 101;
    try std.testing.expectError(error.NotACache, Cache.parse(gpa, copy));
    copy[0] = version;
    const header = try layout.viewMut(Header, copy);
    header.count = capacity + 1;
    try std.testing.expectError(error.TooManyEntries, Cache.parse(gpa, copy));
    header.count = 1;
    copy[header_size] = 4; // four bytes per pixel
    try std.testing.expectError(error.UnsupportedFormat, Cache.parse(gpa, copy));
}
