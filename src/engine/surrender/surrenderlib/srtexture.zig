//! `C:\lancer\surrender\surrenderlib\srTexture.cpp`: the texture table. `texture_find`
//! (`0x004C9E20`) looks a name up in the texture cache and reads the pixels on first use; the
//! driver makes its device texture when it first draws with it (`texture_upload`, `0x004C9C90`).
//! OpenReliant keeps each image as 8-bit RGBA mip levels, and takes a mod's picture of a texture's
//! name in place of the cache's (`Files`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const png = @import("../../../formats/png.zig");
const tcache = @import("../../../formats/tcache.zig");
const tga = @import("../../../formats/tga.zig");

const log = std.log.scoped(.textures);

pub const Level = struct {
    width: u32,
    height: u32,
    /// Red, green, blue and alpha, row by row from the top.
    rgba: []const u8,
};

/// An image as OpenReliant holds it, the counterpart of `TextureImage`.
pub const Image = struct {
    /// The full-size level first.
    levels: []const Level,
    /// What the driver made of it, `TextureImage.device_texture`: 0 until it first draws with it.
    device: usize = 0,
    /// Set by whoever changes its pixels after the driver has made a texture of them, such as the
    /// display's power ball, which is drawn afresh every frame. The driver sends the pixels up
    /// again and clears it.
    changed: bool = false,
    /// OpenReliant's: how a device that filters its textures magnifies it.
    magnify: Magnify = .sharp,
    /// OpenReliant's: the maps that make its surface a material, for physically based shading,
    /// where a mod gives them (`Table.maps`).
    maps: Maps = .{},

    /// The maps of a material, each as many levels as its image and of its size, in linear values;
    /// either may be missing.
    pub const Maps = struct {
        /// The surface's normal in the texture's own frame, as OpenGL's normal maps hold it: its
        /// x toward the texture's right, its y toward its top and its z out of the surface, each
        /// from -1 to 1 in red, green and blue.
        normal: ?[]const Level = null,
        /// How much of the ambient light reaches the surface, how rough it is, and how metallic, in
        /// red, green and blue, as glTF packs them.
        orm: ?[]const Level = null,

        fn deinit(maps: Maps, gpa: Allocator) void {
            if (maps.normal) |levels| freeLevels(gpa, levels);
            if (maps.orm) |levels| freeLevels(gpa, levels);
        }
    };

    /// How a device that filters its textures magnifies one, where its filter magnifies at all.
    pub const Magnify = enum(u2) {
        /// By the device's own filter.
        sharp,
        /// **Improvement:** with a smooth cubic filter, which neither rings nor sharpens, for a
        /// soft image stretched far, as the nebulae are.
        smooth,
        /// **Improvement:** with FSR 1's edge-adaptive upscale (AMD's FidelityFX Super Resolution
        /// 1.0), which keeps the edges of a picture stretched far sharp without steps, as the
        /// movies are.
        edge_adaptive,
        /// **Improvement:** as a glyph's coverage, the grey its levels are drawn in, as stored
        /// whatever the lighting: each of its pixels a square of its own coverage, the step from
        /// one to the next eased over a pixel of the frame, so that the menus' text keeps the
        /// fonts' shapes and greys, crisp, however far it is stretched. It takes the colour it is
        /// drawn in alone.
        coverage,
    };

    /// An image of one level, `across` by `down` pixels of `rgba`, which it takes: `deinit` frees
    /// them with the level.
    pub fn single(gpa: Allocator, across: u32, down: u32, rgba: []const u8) Allocator.Error!Image {
        const levels = try gpa.alloc(Level, 1);
        levels[0] = .{ .width = across, .height = down, .rgba = rgba };
        return .{ .levels = levels };
    }

    pub fn width(image: Image) u32 {
        return image.levels[0].width;
    }

    pub fn height(image: Image) u32 {
        return image.levels[0].height;
    }

    /// The texel at `u`, `v` of `level`, filtered bilinearly and wrapping, as the hardware
    /// renderers sample: texel centres at half-texel positions.
    pub fn sample(image: Image, level: usize, u: f32, v: f32) [4]f32 {
        const l = image.levels[@min(level, image.levels.len - 1)];
        const x = u * @as(f32, @floatFromInt(l.width)) - 0.5;
        const y = v * @as(f32, @floatFromInt(l.height)) - 0.5;
        const x0 = @floor(x);
        const y0 = @floor(y);
        const fx = x - x0;
        const fy = y - y0;
        const ix = std.math.lossyCast(i64, x0);
        const iy = std.math.lossyCast(i64, y0);
        var out: [4]f32 = @splat(0);
        const weights = [4]f32{ (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy };
        for (weights, 0..) |weight, corner| {
            const cx = wrap(ix + @as(i64, @intCast(corner & 1)), l.width);
            const cy = wrap(iy + @as(i64, @intCast(corner >> 1)), l.height);
            const texel = l.rgba[(cy * l.width + cx) * 4 ..][0..4];
            for (&out, texel) |*c, t| c.* += @as(f32, @floatFromInt(t)) / 255 * weight;
        }
        return out;
    }

    /// The texel of the finest level nearest `u`, `v`, held within the image, as a point filter
    /// takes it.
    pub fn samplePoint(image: Image, u: f32, v: f32) [4]f32 {
        const l = image.levels[0];
        const x = std.math.clamp(std.math.lossyCast(i64, @floor(u * @as(f32, @floatFromInt(l.width)))), 0, @as(i64, l.width) - 1);
        const y = std.math.clamp(std.math.lossyCast(i64, @floor(v * @as(f32, @floatFromInt(l.height)))), 0, @as(i64, l.height) - 1);
        const at: usize = @intCast(y * l.width + x);
        var out: [4]f32 = undefined;
        for (&out, l.rgba[at * 4 ..][0..4]) |*c, t| c.* = @as(f32, @floatFromInt(t)) / 255;
        return out;
    }

    pub fn deinit(image: Image, gpa: Allocator) void {
        freeLevels(gpa, image.levels);
        image.maps.deinit(gpa);
    }
};

fn freeLevels(gpa: Allocator, levels: []const Level) void {
    for (levels) |l| gpa.free(l.rgba);
    gpa.free(levels);
}

fn wrap(i: i64, size: u32) usize {
    return @intCast(@mod(i, @as(i64, size)));
}

/// OpenReliant's: files that stand in for the cache's images, such as the mods'
/// (`game.bigfile.Mods.textures`), by a texture's name and a picture format's extension.
pub const Files = struct {
    context: *const anyopaque,
    readFn: *const fn (context: *const anyopaque, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8,

    /// The file `name`, in `gpa`; null where there is none.
    pub fn read(files: Files, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        return files.readFn(files.context, gpa, name);
    }
};

/// The extension of the pictures that stand in for the cache's images.
pub const picture_extension = ".png";

/// The material maps a picture may come with, by what their names add to its name.
pub const MapFile = enum {
    normal,
    /// Occlusion, roughness and metallic, packed as glTF packs them.
    orm,
    occlusion,
    roughness,
    metallic,

    /// What its name adds to the picture's: `_` and the map's name.
    pub fn suffix(map_file: MapFile) []const u8 {
        return switch (map_file) {
            inline else => |tag| "_" ++ @tagName(tag),
        };
    }

    /// What it is called in the log.
    pub fn label(map_file: MapFile) []const u8 {
        return switch (map_file) {
            .normal => "normal map",
            .orm => "material map",
            .occlusion => "occlusion map",
            .roughness => "roughness map",
            .metallic => "metallic map",
        };
    }
};

/// The images the texture cache holds, by name, each decoded once with the renderer's palette.
pub const Table = struct {
    gpa: Allocator,
    cache: tcache.Cache,
    palette: tga.Palette,
    /// OpenReliant's: the files whose pictures stand in for the cache's images, of any size
    /// (`picture`); none but the cache's without them.
    ///
    /// **Improvement:** the original reads the cache's images alone.
    files: ?Files = null,
    /// By lower-case file name; null for a name the cache lacks.
    images: std.StringHashMapUnmanaged(?*Image) = .empty,

    pub fn init(gpa: Allocator, cache: tcache.Cache, palette: tga.Palette) Table {
        return .{ .gpa = gpa, .cache = cache, .palette = palette };
    }

    pub fn deinit(table: *Table) void {
        var it = table.images.iterator();
        while (it.next()) |entry| {
            table.gpa.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |image| {
                image.deinit(table.gpa);
                table.gpa.destroy(image);
            }
        }
        table.images.deinit(table.gpa);
    }

    /// The image the engine finds for `name` (`texture_find`), or null when the cache has none: a
    /// picture of the name from `files` first (`picture`).
    pub fn find(table: *Table, name: []const u8) Allocator.Error!?*Image {
        const key = try table.gpa.dupe(u8, tcache.fileName(name));
        for (key) |*c| c.* = std.ascii.toLower(c.*);
        const entry = table.images.getOrPut(table.gpa, key) catch |err| {
            table.gpa.free(key);
            return err;
        };
        if (entry.found_existing) {
            table.gpa.free(key);
            return entry.value_ptr.*;
        }
        entry.value_ptr.* = null;
        if (try table.picture(key)) |image| {
            entry.value_ptr.* = image;
            return image;
        }
        const found = table.cache.find(key) orelse return null;
        const image = try table.gpa.create(Image);
        errdefer table.gpa.destroy(image);
        image.* = try decode(table.gpa, found, &table.palette);
        entry.value_ptr.* = image;
        return image;
    }

    /// The picture `files` give the texture `name`, `<name>.png`, of any size, read as an image
    /// with its levels made (`mipmapped`), and its material maps (`maps`); null where they give
    /// none, or it can't be read, which the log says.
    fn picture(table: *Table, name: []const u8) Allocator.Error!?*Image {
        const files = table.files orelse return null;
        const read = try table.readPicture(files, name, "") orelse return null;
        const size = [2]u32{ read.width, read.height };
        var made = try mipmapped(table.gpa, read);
        errdefer made.deinit(table.gpa);
        made.maps = try table.maps(files, name, size);
        const image = try table.gpa.create(Image);
        image.* = made;
        return image;
    }

    /// The material maps `files` give the texture `name` beside its picture of `size`, of the same
    /// size: `<name>_normal.png`, and `<name>_orm.png` or its maps alone (`packedMaps`). A map of
    /// another size is left out, which the log says.
    fn maps(table: *Table, files: Files, name: []const u8, size: [2]u32) Allocator.Error!Image.Maps {
        var found: Image.Maps = .{};
        errdefer found.deinit(table.gpa);
        if (try table.map(files, name, .normal, size)) |normal| found.normal = try mipmaps(table.gpa, normal, .normal);
        const orm = try table.map(files, name, .orm, size) orelse try table.packedMaps(files, name, size);
        if (orm) |packed_orm| found.orm = try mipmaps(table.gpa, packed_orm, .data);
        return found;
    }

    /// Occlusion, roughness and metallic packed into one picture, as glTF packs them, from their
    /// maps alone, each the red of its own (grey) map, or where it has none no occlusion, rough, or
    /// not metallic. Null where `files` give none of the three.
    fn packedMaps(table: *Table, files: Files, name: []const u8, size: [2]u32) Allocator.Error!?png.Picture {
        const parts = [_]MapFile{ .occlusion, .roughness, .metallic };
        const fallbacks = [parts.len]u8{ std.math.maxInt(u8), std.math.maxInt(u8), 0 };
        var pictures: [parts.len]?png.Picture = @splat(null);
        defer for (pictures) |found| if (found) |part| part.deinit(table.gpa);
        for (&pictures, parts) |*found, part| found.* = try table.map(files, name, part, size);
        for (pictures) |found| {
            if (found != null) break;
        } else return null;
        const rgba = try table.gpa.alloc(u8, @as(usize, size[0]) * size[1] * 4);
        for (0..@as(usize, size[0]) * size[1]) |at| {
            for (pictures, fallbacks, 0..) |found, fallback, channel| {
                rgba[at * 4 + channel] = if (found) |part| part.rgba[at * 4] else fallback;
            }
            rgba[at * 4 + 3] = std.math.maxInt(u8);
        }
        return .{ .width = size[0], .height = size[1], .rgba = rgba };
    }

    /// The map `kind` of the texture `name`, of the picture's `size`; null where `files` give none,
    /// or it can't be read or is of another size, which the log says.
    fn map(table: *Table, files: Files, name: []const u8, kind: MapFile, size: [2]u32) Allocator.Error!?png.Picture {
        const picture_read = try table.readPicture(files, name, kind.suffix()) orelse return null;
        if (picture_read.width == size[0] and picture_read.height == size[1]) return picture_read;
        log.warn("{s}{s}{s} is left out: it is {d}x{d} and its picture {d}x{d}", .{ name, kind.suffix(), picture_extension, picture_read.width, picture_read.height, size[0], size[1] });
        picture_read.deinit(table.gpa);
        return null;
    }

    /// The picture `files` give as `name`, `suffix` and the picture extension; null where they
    /// give none, or it can't be read, which the log says.
    fn readPicture(table: *Table, files: Files, name: []const u8, suffix: []const u8) Allocator.Error!?png.Picture {
        const file_name = try std.fmt.allocPrint(table.gpa, "{s}{s}" ++ picture_extension, .{ name, suffix });
        defer table.gpa.free(file_name);
        const bytes = try files.read(table.gpa, file_name) orelse return null;
        defer table.gpa.free(bytes);
        return png.read(table.gpa, bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NotAPng, error.Corrupt, error.Unsupported, error.BadSize => {
                log.warn("{s} is left out: {s}", .{ file_name, @errorName(err) });
                return null;
            },
        };
    }
};

/// The longest side an image keeps: a picture larger loses its finest levels until it fits, so
/// that every GPU takes it.
pub const max_side = 8192;

/// What a picture holds, which its mipmaps are made for.
pub const Content = enum {
    /// Colours, sRGB-encoded, with alpha: their means are taken in linear light, weighted by alpha.
    colour,
    /// A normal map's vectors: their means are taken as vectors, made a unit long again.
    normal,
    /// Linear values, such as occlusion, roughness and metallic: their plain means.
    data,
};

/// An image of `picture`, which it takes, with its mipmap levels made down to a pixel, each half
/// the last, rounding down (`halved`). A picture longer than `max_side` gives its finest levels up.
pub fn mipmapped(gpa: Allocator, picture: png.Picture) Allocator.Error!Image {
    return .{ .levels = try mipmaps(gpa, picture, .colour) };
}

/// The mipmap levels of `picture`, which it takes, made for `content`, as `mipmapped` makes them.
pub fn mipmaps(gpa: Allocator, picture: png.Picture, content: Content) Allocator.Error![]const Level {
    var levels: std.ArrayList(Level) = .empty;
    errdefer {
        for (levels.items) |l| gpa.free(l.rgba);
        levels.deinit(gpa);
    }
    var finest: Level = .{ .width = picture.width, .height = picture.height, .rgba = picture.rgba };
    {
        errdefer gpa.free(finest.rgba);
        while (@max(finest.width, finest.height) > max_side) {
            const smaller = try halved(gpa, finest, content);
            gpa.free(finest.rgba);
            finest = smaller;
        }
        try levels.append(gpa, finest);
    }
    var last = finest;
    while (last.width > 1 or last.height > 1) {
        last = try halved(gpa, last, content);
        levels.append(gpa, last) catch |err| {
            gpa.free(last.rgba);
            return err;
        };
    }
    return levels.toOwnedSlice(gpa);
}

/// The level after `level`: each side half its own, rounding down, at least a pixel, and each pixel
/// the mean of the up to four it covers, as `content` takes it.
fn halved(gpa: Allocator, level: Level, content: Content) Allocator.Error!Level {
    const Rgb = @Vector(3, f32);
    const width = @max(level.width / 2, 1);
    const height = @max(level.height / 2, 1);
    const rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    for (0..height) |y| for (0..width) |x| {
        var sum: Rgb = @splat(0);
        var weighted: Rgb = @splat(0);
        var alpha: f32 = 0;
        const columns = [2]usize{ @min(2 * x, level.width - 1), @min(2 * x + 1, level.width - 1) };
        const rows = [2]usize{ @min(2 * y, level.height - 1), @min(2 * y + 1, level.height - 1) };
        for (rows) |row| for (columns) |column| {
            const texel = level.rgba[(row * level.width + column) * 4 ..][0..4];
            const value: Rgb = switch (content) {
                .colour => .{ srgb.light(texel[0]), srgb.light(texel[1]), srgb.light(texel[2]) },
                .normal => Rgb{ unit(texel[0]), unit(texel[1]), unit(texel[2]) } * @as(Rgb, @splat(2)) - @as(Rgb, @splat(1)),
                .data => .{ unit(texel[0]), unit(texel[1]), unit(texel[2]) },
            };
            const weight = unit(texel[3]);
            sum += value;
            weighted += value * @as(Rgb, @splat(weight));
            alpha += weight;
        };
        const out = rgba[(y * width + x) * 4 ..][0..4];
        const mean_alpha = level8(alpha / 4);
        switch (content) {
            .colour => {
                // Weighted by alpha, so that a clear pixel lends its colour nothing; where the four
                // are all clear, the mean of their colours, which filtering may still reach.
                const mean = if (alpha > 0) weighted / @as(Rgb, @splat(alpha)) else sum / @as(Rgb, @splat(4));
                out.* = .{ srgb.level(mean[0]), srgb.level(mean[1]), srgb.level(mean[2]), mean_alpha };
            },
            .normal => {
                // The vectors' mean, a unit long again; straight out of the surface where they
                // cancel.
                const length = @sqrt(@reduce(.Add, sum * sum));
                const direction: Rgb = if (length > 0) sum / @as(Rgb, @splat(length)) else .{ 0, 0, 1 };
                const encoded = (direction + @as(Rgb, @splat(1))) / @as(Rgb, @splat(2));
                out.* = .{ level8(encoded[0]), level8(encoded[1]), level8(encoded[2]), mean_alpha };
            },
            .data => {
                const mean = sum / @as(Rgb, @splat(4));
                out.* = .{ level8(mean[0]), level8(mean[1]), level8(mean[2]), mean_alpha };
            },
        }
    };
    return .{ .width = width, .height = height, .rgba = rgba };
}

/// An 8-bit level as a value from 0 to 1.
fn unit(level: u8) f32 {
    return @as(f32, @floatFromInt(level)) / std.math.maxInt(u8);
}

/// The 8-bit level nearest a value from 0 to 1, held to the range.
fn level8(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * std.math.maxInt(u8)));
}

/// sRGB's transfer function (IEC 61966-2-1), between a colour's 8-bit levels and its light from 0
/// to 1, worked out exactly once for every level.
const srgb = struct {
    /// Below this encoded value the curve is a straight line.
    const knee = 0.04045;
    const slope = 12.92;
    const offset = 0.055;
    const exponent = 2.4;

    /// The light of each level.
    const lights: [256]f32 = table: {
        @setEvalBranchQuota(100_000);
        var out: [256]f32 = undefined;
        for (&out, 0..) |*light_of, at| light_of.* = decoded(@as(f64, @floatFromInt(at)) / 255);
        break :table out;
    };

    /// The light halfway, in encoded value, between each level and the next: where the nearest
    /// level changes.
    const bounds: [255]f32 = table: {
        @setEvalBranchQuota(100_000);
        var out: [255]f32 = undefined;
        for (&out, 0..) |*bound, at| bound.* = decoded((@as(f64, @floatFromInt(at)) + 0.5) / 255);
        break :table out;
    };

    fn decoded(value: f64) f32 {
        return @floatCast(if (value <= knee) value / slope else std.math.pow(f64, (value + offset) / (1 + offset), exponent));
    }

    fn light(of: u8) f32 {
        return lights[of];
    }

    /// The level nearest the light `of`, in encoded value.
    fn level(of: f32) u8 {
        var low: usize = 0;
        var high: usize = bounds.len;
        while (low < high) {
            const middle = (low + high) / 2;
            if (of < bounds[middle]) high = middle else low = middle + 1;
        }
        return @intCast(low);
    }
};

fn decode(gpa: Allocator, texture: tcache.Texture, palette: *const tga.Palette) Allocator.Error!Image {
    var levels: std.ArrayList(Level) = .empty;
    errdefer {
        for (levels.items) |l| gpa.free(l.rgba);
        levels.deinit(gpa);
    }
    var n: u32 = 0;
    while (texture.level(n)) |source| : (n += 1) {
        const rgba = try source.rgba(gpa, palette);
        errdefer gpa.free(rgba);
        try levels.append(gpa, .{ .width = source.width, .height = source.height, .rgba = rgba });
    }
    return .{ .levels = try levels.toOwnedSlice(gpa) };
}

test "Image.single" {
    const gpa = std.testing.allocator;
    const rgba = try gpa.dupe(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const image: Image = try .single(gpa, 2, 1, rgba);
    defer image.deinit(gpa);
    try std.testing.expectEqual(1, image.levels.len);
    try std.testing.expectEqual(2, image.width());
    try std.testing.expectEqual(1, image.height());
}

test "images sample bilinearly and wrap" {
    const rgba = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 };
    const levels = [_]Level{.{ .width = 2, .height = 1, .rgba = &rgba }};
    const image: Image = .{ .levels = &levels };
    // Texel centres give the texels; between them, the mean; past the edge it wraps.
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, image.sample(0, 0.25, 0.5));
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, image.sample(0, 0.75, 0.5));
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, image.sample(0, 0.5, 0.5));
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, image.sample(0, 1.0, 0.5));
}

test Table {
    const gpa = std.testing.allocator;
    const bytes = try tcache.testing.build(gpa, &.{
        .{ .name = "Kiev_1", .encoding = .index8, .width = 2, .height = 2 },
        .{ .name = "lKiev_1", .encoding = .index8, .width = 2, .height = 2 },
    });
    defer gpa.free(bytes);
    const cache: tcache.Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);
    var palette: tga.Palette = undefined;
    for (&palette, 0..) |*c, i| c.* = .{ @truncate(i), 0, 0 };

    var table: Table = .init(gpa, cache, palette);
    defer table.deinit();
    const kiev = (try table.find("KIEV_1")).?;
    try std.testing.expectEqual(2, kiev.width());
    // The same image again, none for a name the cache lacks, and the light map apart.
    try std.testing.expectEqual(kiev, (try table.find("kiev_1")).?);
    try std.testing.expectEqual(null, try table.find("missing"));
    try std.testing.expect((try table.find("lkiev_1")).? != kiev);
}

test "pictures stand in for the cache's images" {
    const gpa = std.testing.allocator;
    const bytes = try tcache.testing.build(gpa, &.{
        .{ .name = "Kiev_1", .encoding = .index8, .width = 2, .height = 2 },
        .{ .name = "hull", .encoding = .index8, .width = 2, .height = 2 },
    });
    defer gpa.free(bytes);
    const cache: tcache.Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);

    // A picture of four pixels by two for `kiev_1`, and one that is no picture for `hull`.
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try png.writeRgba(gpa, &written.writer, 4, 2, &(@as([32]u8, @splat(0xFF))));
    const Pictures = struct {
        kiev: []const u8,

        fn read(context: *const anyopaque, allocator: Allocator, name: []const u8) Allocator.Error!?[]u8 {
            const pictures: *const @This() = @ptrCast(@alignCast(context));
            if (std.ascii.eqlIgnoreCase(name, "kiev_1.png")) return try allocator.dupe(u8, pictures.kiev);
            if (std.ascii.eqlIgnoreCase(name, "hull.png")) return try allocator.dupe(u8, "no picture");
            return null;
        }
    };
    const pictures: Pictures = .{ .kiev = written.written() };

    var table: Table = .init(gpa, cache, std.mem.zeroes(tga.Palette));
    defer table.deinit();
    table.files = .{ .context = &pictures, .readFn = Pictures.read };
    // The picture, whatever the case of the name asked for, with its levels down to a pixel.
    const kiev = (try table.find("KIEV_1")).?;
    try std.testing.expectEqual(4, kiev.width());
    try std.testing.expectEqual(3, kiev.levels.len);
    // The cache's where the picture can't be read.
    const hull = (try table.find("hull")).?;
    try std.testing.expectEqual(2, hull.width());
}

test "material maps come beside a picture" {
    const gpa = std.testing.allocator;
    const bytes = try tcache.testing.build(gpa, &.{.{ .name = "hull", .encoding = .index8, .width = 2, .height = 2 }});
    defer gpa.free(bytes);
    const cache: tcache.Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);

    // Pictures of two pixels by two, each of one colour, by name.
    const Pictures = struct {
        files: []const struct { name: []const u8, rgba: [4]u8, side: u32 = 2 },

        fn read(context: *const anyopaque, allocator: Allocator, name: []const u8) Allocator.Error!?[]u8 {
            const pictures: *const @This() = @ptrCast(@alignCast(context));
            for (pictures.files) |file| {
                if (!std.ascii.eqlIgnoreCase(file.name, name)) continue;
                var pixels: [16 * 4]u8 = undefined;
                for (0..file.side * file.side) |at| pixels[at * 4 ..][0..4].* = file.rgba;
                var written: std.Io.Writer.Allocating = .init(allocator);
                defer written.deinit();
                png.writeRgba(allocator, &written.writer, file.side, file.side, pixels[0 .. file.side * file.side * 4]) catch return error.OutOfMemory;
                return try allocator.dupe(u8, written.written());
            }
            return null;
        }
    };

    // A normal map, and roughness and metallic alone, packed as glTF packs them, where no material
    // map of their own comes; an occlusion map of another size is left out.
    const separate: Pictures = .{ .files = &.{
        .{ .name = "hull.png", .rgba = .{ 200, 100, 50, 255 } },
        .{ .name = "hull_normal.png", .rgba = .{ 128, 128, 255, 255 } },
        .{ .name = "hull_roughness.png", .rgba = .{ 64, 64, 64, 255 } },
        .{ .name = "hull_metallic.png", .rgba = .{ 255, 255, 255, 255 } },
        .{ .name = "hull_occlusion.png", .rgba = .{ 0, 0, 0, 255 }, .side = 4 },
    } };
    var table: Table = .init(gpa, cache, std.mem.zeroes(tga.Palette));
    defer table.deinit();
    table.files = .{ .context = &separate, .readFn = Pictures.read };
    const hull = (try table.find("hull")).?;
    try std.testing.expectEqual(2, hull.maps.normal.?.len);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 255, 255 }, hull.maps.normal.?[1].rgba);
    try std.testing.expectEqualSlices(u8, &.{ 255, 64, 255, 255 }, hull.maps.orm.?[0].rgba[0..4]);

    // A material map packed already takes the place of the three; without maps, there are none.
    const packed_maps: Pictures = .{ .files = &.{
        .{ .name = "hull.png", .rgba = .{ 1, 2, 3, 255 } },
        .{ .name = "hull_orm.png", .rgba = .{ 10, 20, 30, 255 } },
        .{ .name = "hull_roughness.png", .rgba = .{ 99, 99, 99, 255 } },
    } };
    var other: Table = .init(gpa, cache, std.mem.zeroes(tga.Palette));
    defer other.deinit();
    other.files = .{ .context = &packed_maps, .readFn = Pictures.read };
    const packed_hull = (try other.find("hull")).?;
    try std.testing.expectEqual(null, packed_hull.maps.normal);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, packed_hull.maps.orm.?[1].rgba);
}

test "mipmaps of normals and of values" {
    const gpa = std.testing.allocator;
    // Two normals leaning opposite ways along x mean one straight out of the surface.
    const leaning = try gpa.dupe(u8, &.{ 218, 128, 218, 255, 38, 128, 218, 255 });
    const normals = try mipmaps(gpa, .{ .width = 2, .height = 1, .rgba = leaning }, .normal);
    defer freeLevels(gpa, normals);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 255, 255 }, normals[1].rgba);
    // Values mean plainly, not in linear light as colours do.
    const values = try gpa.dupe(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255 });
    const data = try mipmaps(gpa, .{ .width = 2, .height = 1, .rgba = values }, .data);
    defer freeLevels(gpa, data);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, data[1].rgba);
}

test mipmapped {
    const gpa = std.testing.allocator;
    // Black and white, which mean the grey of half their light, not half their levels.
    const black_white = try gpa.dupe(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255 });
    const grey = try mipmapped(gpa, .{ .width = 2, .height = 1, .rgba = black_white });
    defer grey.deinit(gpa);
    try std.testing.expectEqual(2, grey.levels.len);
    try std.testing.expectEqualSlices(u8, &.{ 188, 188, 188, 255 }, grey.levels[1].rgba);

    // A clear pixel lends its colour nothing, and its alpha half.
    const half_clear = try gpa.dupe(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 0 });
    const red = try mipmapped(gpa, .{ .width = 2, .height = 1, .rgba = half_clear });
    defer red.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, red.levels[1].rgba);

    // Past the longest side, the finest levels go.
    const long = try gpa.alloc(u8, (max_side + 1) * 4);
    @memset(long, 0x80);
    const kept = try mipmapped(gpa, .{ .width = max_side + 1, .height = 1, .rgba = long });
    defer kept.deinit(gpa);
    try std.testing.expectEqual(max_side / 2, kept.width());
    try std.testing.expectEqual(1, kept.levels[kept.levels.len - 1].width);
}

test "sRGB's levels and light" {
    for (0..256) |at| {
        const level: u8 = @intCast(at);
        try std.testing.expectEqual(level, srgb.level(srgb.light(level)));
    }
    try std.testing.expectEqual(188, srgb.level(0.5));
    try std.testing.expectEqual(0, srgb.level(-1));
    try std.testing.expectEqual(255, srgb.level(2));
}

/// Fixtures for the tests here and in the modules that draw with textures.
pub const testing = struct {
    /// A table of small textures, one under each name it is made with.
    pub const Textures = struct {
        bytes: []u8,
        cache: tcache.Cache,
        table: Table,

        /// A table holding an eight-by-four texture under each of `names`.
        pub fn init(gpa: Allocator, names: []const []const u8) !*Textures {
            const specs = try gpa.alloc(tcache.testing.Spec, names.len);
            defer gpa.free(specs);
            for (specs, names) |*spec, name| spec.* = .{ .name = name, .encoding = .index8, .width = 8, .height = 4 };
            const textures = try gpa.create(Textures);
            errdefer gpa.destroy(textures);
            textures.bytes = try tcache.testing.build(gpa, specs);
            errdefer gpa.free(textures.bytes);
            textures.cache = try .parse(gpa, textures.bytes);
            textures.table = .init(gpa, textures.cache, std.mem.zeroes(tga.Palette));
            return textures;
        }

        pub fn deinit(textures: *Textures, gpa: Allocator) void {
            textures.table.deinit();
            textures.cache.deinit(gpa);
            gpa.free(textures.bytes);
            gpa.destroy(textures);
        }
    };
};

test "testing.Textures" {
    const gpa = std.testing.allocator;
    const textures = try testing.Textures.init(gpa, &.{ "hull", "lhull" });
    defer textures.deinit(gpa);
    try std.testing.expect((try textures.table.find("hull")) != null);
    try std.testing.expect((try textures.table.find("lhull")) != null);
}

test "mipmapped lets go of the picture and its levels when memory runs out" {
    // Every allocation it makes, failing in turn: nothing is left behind, nothing freed twice.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn made(gpa: Allocator) !void {
            const rgba = try gpa.alloc(u8, 4 * 2 * 4);
            @memset(rgba, 0x40);
            const image = try mipmapped(gpa, .{ .width = 4, .height = 2, .rgba = rgba });
            image.deinit(gpa);
        }
    }.made, .{});
}
