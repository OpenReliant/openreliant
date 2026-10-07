//! `C:\lancer\surrender\surrenderlib\srTexture.cpp`: the texture table. `texture_find`
//! (`0x004C9E20`) looks a name up in the texture cache and reads the pixels on first use; the
//! driver makes its device texture when it first draws with it (`texture_upload`, `0x004C9C90`).
//! OpenReliant keeps each image as 8-bit RGBA mip levels, and uses a mod's picture with a
//! texture's name instead of the cache's image (`Files`), along with the material maps next to it
//! (`Image.Maps`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const png = @import("../../../formats/png.zig");
const texels = @import("../../../formats/texels.zig");
const colour = @import("../colour.zig");
const math = @import("../math.zig");
const tcache = @import("../../../formats/tcache.zig");
const tga = @import("../../../formats/tga.zig");
const srimage = @import("srimage.zig");
pub const mod_pictures = @import("srtexture/mod_pictures.zig");
pub const copies = @import("srtexture/copies.zig");
pub const Copy = copies.Copy;

const log = std.log.scoped(.textures);

pub const Level = struct {
    width: u32,
    height: u32,
    /// How `texels` hold its pixels.
    format: Format = .rgba8,
    /// Its pixels, row by row from the top: 8-bit red, green, blue and alpha each, or, compressed,
    /// blocks of 4 by 4 pixels, a row of blocks at a time. The image owns them, or for a borrowed
    /// image, such as the display's power ball or a film, its owner keeps them.
    texels: []u8,

    /// How a level holds its pixels (`formats.texels`).
    ///
    /// **Improvement:** OpenReliant keeps mods' pictures compressed on the GPU, as today's games
    /// do: a quarter of the memory of 8-bit RGBA, or less.
    pub const Format = texels.Format;
    pub const blocks = texels.blocks;
    pub const block_side = texels.block_side;
};

/// A level of 8-bit or 16-bit RGBA, as pictures are read and mipmapped: the only formats that
/// the mipmapping, sampling and storing helpers take.
pub const RgbaLevel = struct {
    width: u32,
    height: u32,
    rgba: texels.Rgba,
    texels: []u8,

    /// `any` as RGBA; null when it is in another format.
    pub fn of(any: Level) ?RgbaLevel {
        return .{ .width = any.width, .height = any.height, .rgba = any.format.rgba() orelse return null, .texels = any.texels };
    }

    /// The level it is.
    pub fn asLevel(made: RgbaLevel) Level {
        return .{ .width = made.width, .height = made.height, .format = made.rgba.asFormat(), .texels = made.texels };
    }
};

/// Added by OpenReliant: a mod's surface function that a draw is shaded with, and the parameters it
/// reads (`scripting.shaders`). A device that can't run it draws as if there were none.
pub const ModSurface = struct {
    /// The function, as the device knows it.
    function: u16,
    parameters: [4]f32 = @splat(0),
    /// Whether the surfaces it draws blend by the alpha it sets, sorted with the game's other
    /// blended draws, though the game draws them solid; and whether they still write depth, as a
    /// solid model does, so that of two that cut into each other the nearer hides the other.
    see_through: bool = false,
    writes_depth: bool = true,
};

/// An image as OpenReliant holds it, the counterpart of `TextureImage`.
pub const Image = struct {
    /// The full-size level first.
    levels: []Level,
    /// What the driver made of it, `TextureImage.device_texture`: 0 until it first draws with it.
    device: usize = 0,
    /// Set by whoever changes its pixels after the driver has made a texture of them, such as the
    /// display's power ball, which is drawn afresh every frame. The driver sends the pixels up
    /// again and clears it.
    changed: bool = false,
    /// OpenReliant's: how a device that filters its textures magnifies it.
    magnify: Magnify = .sharp,
    /// Added by OpenReliant: the material maps for physically based shading, if a mod has them
    /// (`Table.maps`).
    maps: Maps = .{},
    /// Added by OpenReliant: the mod's surface function its draws are shaded with, if any.
    surface: ?ModSurface = null,
    /// Added by OpenReliant: set by a device that keeps its own copy of the pixels, such as the
    /// GPU, once it has taken them. The texture table can then let go of its own
    /// (`Table.releaseHeld`).
    held: bool = false,

    /// The maps of a material, each as many levels as its image and of its size, in linear values;
    /// either may be missing.
    pub const Maps = struct {
        /// The surface's normal in the texture's own frame, as OpenGL's normal maps hold it: its
        /// x toward the texture's right, its y toward its top and its z out of the surface, each
        /// from -1 to 1 in red, green and blue; in alpha, how long the mean of the normals each
        /// texel stands for is (`Content.normal`). Made ready for the device, in BC5 or 16-bit RG,
        /// it holds x and y alone, and the length is in the material map's alpha.
        normal: ?[]Level = null,
        /// How much of the ambient light reaches the surface, how rough it is, and how metallic, in
        /// red, green and blue, as glTF packs them.
        orm: ?[]Level = null,
        /// The light the surface gives off by itself, sRGB-encoded like its image's colours, as
        /// glTF's emissive texture holds it: added after the surface is lit.
        emissive: ?[]Level = null,

        /// How many maps there are, one for each field.
        pub const count = @typeInfo(Maps).@"struct".field_names.len;

        /// Each map, in the order of the fields.
        pub fn list(maps: Maps) [count]?[]Level {
            var listed: [count]?[]Level = undefined;
            inline for (@typeInfo(Maps).@"struct".field_names, &listed) |name, *map| map.* = @field(maps, name);
            return listed;
        }

        /// The maps `listed` gives, in the order of the fields.
        pub fn fromList(listed: [count]?[]Level) Maps {
            var maps: Maps = .{};
            inline for (@typeInfo(Maps).@"struct".field_names, listed) |name, map| @field(maps, name) = map;
            return maps;
        }

        fn deinit(maps: Maps, gpa: Allocator) void {
            for (maps.list()) |map| if (map) |levels| freeLevels(gpa, levels);
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
    pub fn single(gpa: Allocator, across: u32, down: u32, rgba: []u8) Allocator.Error!Image {
        const levels = try gpa.alloc(Level, 1);
        levels[0] = .{ .width = across, .height = down, .texels = rgba };
        return .{ .levels = levels };
    }

    /// Whether its finest level holds pixels the engine can read: 8-bit RGBA, neither compressed
    /// nor let go of once the device held them (`Table.releaseHeld`).
    pub fn readable(image: Image) bool {
        const finest = image.levels[0];
        return finest.format == .rgba8 and finest.texels.len == finest.format.size(finest.width, finest.height);
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
            const texel = l.texels[(cy * l.width + cx) * 4 ..][0..4];
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
        for (&out, l.texels[at * 4 ..][0..4]) |*c, t| c.* = @as(f32, @floatFromInt(t)) / 255;
        return out;
    }

    pub fn deinit(image: Image, gpa: Allocator) void {
        freeLevels(gpa, image.levels);
        image.maps.deinit(gpa);
    }
};

/// Frees `levels` and their pixels.
pub fn freeLevels(gpa: Allocator, levels: []const Level) void {
    for (levels) |l| gpa.free(l.texels);
    gpa.free(levels);
}

/// Lets go of `levels`' pixels, which the table made, keeping their sizes.
fn releasePixels(gpa: Allocator, levels: []Level) void {
    for (levels) |*level| {
        gpa.free(level.texels);
        level.texels = &.{};
    }
}

fn wrap(i: i64, size: u32) usize {
    return @intCast(@mod(i, @as(i64, size)));
}

/// Added by OpenReliant: files whose pictures replace the game's images, such as the mods' files
/// (`game.bigfile.Mods.pictures`): the cache's images, by texture name, and the interface's shapes
/// and pictures (`game.hud.Art`, `game.matmanager`), each with its own naming scheme.
pub const Files = struct {
    context: *const anyopaque,
    readFn: *const fn (context: *const anyopaque, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8,

    /// The file `name`, in `gpa`; null where there is none.
    pub fn read(files: Files, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        return files.readFn(files.context, gpa, name);
    }

    /// The picture `name`, decoded; null where there is none, or it can't be read, which the log
    /// says.
    pub fn picture(files: Files, gpa: Allocator, name: []const u8) Allocator.Error!?png.Picture {
        const bytes = try files.read(gpa, name) orelse return null;
        defer gpa.free(bytes);
        return png.read(gpa, bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NotAPng, error.Corrupt, error.Unsupported, error.BadSize => {
                log.warn("{s} is left out: {s}", .{ name, @errorName(err) });
                return null;
            },
        };
    }
};

/// The extension of the pictures that stand in for the game's images.
pub const picture_extension = png.extension;

/// The material maps a picture may come with, by what their names add to its name.
pub const MapFile = enum {
    normal,
    /// Occlusion, roughness and metallic, packed as glTF packs them.
    orm,
    occlusion,
    roughness,
    metallic,
    /// The light the surface gives off by itself.
    emissive,

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
            .emissive => "emissive map",
        };
    }
};

/// Added by OpenReliant: what compresses the mods' pictures for a device that takes compressed
/// textures, and keeps what it compressed between runs (`mod_pictures.load`).
pub const Compressor = struct {
    context: *anyopaque,
    vtable: *const VTable,
    /// The compressed formats the device takes.
    takes: std.EnumSet(Level.Format),

    /// What a picture's levels hold, which picks their format.
    pub const Kind = enum {
        /// A picture's colours, in BC7.
        colour,
        /// A material map's values, in BC7, each channel weighed alike.
        data,
        /// A normal map's x and y, in BC5.
        normals,

        pub fn format(kind: Kind) Level.Format {
            return switch (kind) {
                .colour, .data => .bc7,
                .normals => .bc5,
            };
        }
    };

    /// What `load` and `store` check a kept picture by: a hash of its files and the texture detail.
    pub const Key = u64;

    pub const VTable = struct {
        /// `level`, 8-bit RGBA, compressed as `kind`, its texels in `gpa`.
        compress: *const fn (context: *anyopaque, gpa: Allocator, level: Level, kind: Kind) Allocator.Error!Level,
        /// The image kept for the texture `name` under `key`, in `gpa`; null where there is none.
        load: *const fn (context: *anyopaque, gpa: Allocator, name: []const u8, key: *const Key) Allocator.Error!?Image,
        /// Keeps `image` for the texture `name` under `key`, in place of what was kept for it. A
        /// failure is logged, and costs time at the next run alone.
        store: *const fn (context: *anyopaque, name: []const u8, key: *const Key, image: Image) void,
    };

    pub fn compress(compressor: Compressor, gpa: Allocator, level: Level, kind: Kind) Allocator.Error!Level {
        return compressor.vtable.compress(compressor.context, gpa, level, kind);
    }

    pub fn load(compressor: Compressor, gpa: Allocator, name: []const u8, key: *const Key) Allocator.Error!?Image {
        return compressor.vtable.load(compressor.context, gpa, name, key);
    }

    pub fn store(compressor: Compressor, name: []const u8, key: *const Key, image: Image) void {
        compressor.vtable.store(compressor.context, name, key, image);
    }

    /// Whether it compresses pictures: the device takes every format it compresses into.
    pub fn compresses(compressor: Compressor) bool {
        for (std.enums.values(Kind)) |kind| if (!compressor.takes.contains(kind.format())) return false;
        return true;
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
    /// The longest side a texture can have, set by the texture detail (`xtrabits.TextureDetail`);
    /// null for no limit. The driver shrinks the cache's images to fit when it makes their device
    /// textures (`fit`), and drops a mod picture's finest mipmap levels until it fits.
    largest: ?u32 = null,
    /// OpenReliant's: what compresses the mods' pictures, where the device takes compressed
    /// textures; null to keep them as they are.
    compressor: ?Compressor = null,
    /// OpenReliant's: whether the table lets go of an image's pixels once the device holds them
    /// (`releaseHeld`): with the GPU, which keeps its own copy, and not in the tools and tests that
    /// read them.
    release_held: bool = false,
    /// The images whose pixels it hasn't let go of yet, while `release_held`.
    unreleased: std.ArrayList(*Image) = .empty,

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
        table.unreleased.deinit(table.gpa);
    }

    /// The image the engine finds for `name` (`texture_find`), or null when the cache has none: a
    /// picture of the name from `files` first (`picture`).
    pub fn find(table: *Table, name: []const u8) Allocator.Error!?*Image {
        return table.lookUp(name, null);
    }

    /// The `copy` of the texture `name` that the loadout draws (`texture_find` of the name after
    /// the copy's letter), or null when there is none and none can be made. In order: the copy
    /// made from a picture of `name` from `files`; the cache's copy; the copy made from the cache's
    /// image of `name`. A picture of the copy's own name from `files` is passed over, so that a
    /// mod's copy always matches its picture and the game's shades.
    ///
    /// **Improvement:** the game finds the cache's copy alone, so a mod's picture showed in the
    /// loadout only with a copy of its own (`copies`).
    pub fn findCopy(table: *Table, name: []const u8, copy: Copy) Allocator.Error!?*Image {
        return table.lookUp(name, copy);
    }

    /// OpenReliant's: finds the textures `names`, or their `copy`, as `find` and `findCopy` do, but
    /// decodes the mods' pictures among them together, as many at once as the computer has cores
    /// (`shareRows`), so that a model's textures load in about the time of the slowest rather than
    /// the sum of them all ([#692](https://github.com/OpenReliant/openreliant/issues/692)). A name
    /// found before is passed over, and one without a mod picture is left to `find`. The files are
    /// read, and the pictures made ready for the device, on the caller's thread.
    pub fn prefetch(table: *Table, names: []const []const u8, copy: ?Copy) Allocator.Error!void {
        const files = table.files orelse return;
        var started: std.ArrayList(Prefetched) = .empty;
        defer {
            for (started.items) |*item| item.deinit(table.gpa);
            started.deinit(table.gpa);
        }
        for (names) |name| {
            const key = try table.keyOf(name, copy);
            const known = table.images.contains(key) or for (started.items) |item| {
                if (std.mem.eql(u8, item.key, key)) break true;
            } else false;
            if (known) {
                table.gpa.free(key);
                continue;
            }
            // As `make` orders them: a picture of the name, or for a copy, the copy made from a
            // picture of the name alone.
            const outcome = if (copy) |made|
                try mod_pictures.start(table.gpa, files, key[1..], table.longest(), table.compressor, made)
            else
                try mod_pictures.start(table.gpa, files, key, table.longest(), table.compressor, null);
            switch (outcome) {
                .none => table.gpa.free(key),
                .kept => |image| try table.keep(key, image),
                .loading => |loading| started.append(table.gpa, .{ .key = key, .loading = loading }) catch |err| {
                    var unwanted = loading;
                    unwanted.deinit();
                    table.gpa.free(key);
                    return err;
                },
            }
        }
        shareRows(started.items.len, 1, started.items, Prefetched.decode);
        for (started.items) |*item| {
            const image = try item.loading.finish() orelse continue;
            const key = item.key;
            item.key = &.{};
            try table.keep(key, image);
        }
    }

    /// A mod's picture `prefetch` decodes, and the key it's kept under.
    const Prefetched = struct {
        key: []u8,
        loading: mod_pictures.Loading,

        fn deinit(item: *Prefetched, gpa: Allocator) void {
            item.loading.deinit();
            gpa.free(item.key);
        }

        /// Decodes `count` of `items` from `first`, on a thread of its own.
        fn decode(items: []Prefetched, first: usize, count: usize) void {
            for (items[first..][0..count]) |*item| item.loading.decode();
        }
    };

    /// Keeps `image`, the image of `key`, which it takes, as `lookUp` keeps what it makes.
    fn keep(table: *Table, key: []u8, image: Image) Allocator.Error!void {
        var made = image;
        errdefer {
            made.deinit(table.gpa);
            table.gpa.free(key);
        }
        const kept = try table.gpa.create(Image);
        errdefer table.gpa.destroy(kept);
        try table.images.putNoClobber(table.gpa, key, kept);
        kept.* = made;
        // An image the table can't track keeps its pixels, which costs memory alone.
        table.track(kept) catch {};
    }

    /// The key the table files the texture `name` under, or its `copy`: the name in lower case,
    /// after the copy's letter. The caller owns it.
    fn keyOf(table: *Table, name: []const u8, copy: ?Copy) Allocator.Error![]u8 {
        const plain = tcache.fileName(name);
        const start: usize = @intFromBool(copy != null);
        const key = try table.gpa.alloc(u8, start + plain.len);
        if (copy) |made| key[0] = made.letter();
        for (key[start..], plain) |*into, c| into.* = std.ascii.toLower(c);
        return key;
    }

    /// `find`, or `findCopy` of `copy`.
    fn lookUp(table: *Table, name: []const u8, copy: ?Copy) Allocator.Error!?*Image {
        const key = try table.keyOf(name, copy);
        const entry = table.images.getOrPut(table.gpa, key) catch |err| {
            table.gpa.free(key);
            return err;
        };
        if (entry.found_existing) {
            table.gpa.free(key);
            return entry.value_ptr.*;
        }
        entry.value_ptr.* = null;
        const image = try table.make(key, copy) orelse return null;
        entry.value_ptr.* = image;
        // An image the table can't track keeps its pixels, which costs memory alone.
        table.track(image) catch {};
        return image;
    }

    /// The image of `key`, the lower-case name after the letter of `copy`, if any; as `findCopy`
    /// and `find` order them.
    fn make(table: *Table, key: []const u8, copy: ?Copy) Allocator.Error!?*Image {
        const plain = key[@intFromBool(copy != null)..];
        if (try table.picture(plain, copy)) |image| return image;
        if (table.cache.find(key)) |found| return try table.decoded(found, null);
        const made = copy orelse return null;
        return try table.decoded(table.cache.find(plain) orelse return null, made);
    }

    /// The cache's image `found`, decoded and fitted to the texture detail, or its `copy`.
    fn decoded(table: *Table, found: tcache.Texture, copy: ?Copy) Allocator.Error!*Image {
        const image = try table.gpa.create(Image);
        errdefer table.gpa.destroy(image);
        image.* = try decode(table.gpa, found, &table.palette);
        errdefer image.deinit(table.gpa);
        if (copy) |made| made.tint(image.levels);
        try fit(table.gpa, image, table.largest);
        return image;
    }

    /// The longest side a mod's picture can have: the texture detail's limit, at most `max_side`.
    fn longest(table: Table) u32 {
        return @min(table.largest orelse max_side, max_side);
    }

    /// The picture `files` give the texture `name`, with its material maps, made ready for the
    /// device (`mod_pictures.load`), or its `copy`; null where they give none, or it can't be used.
    fn picture(table: *Table, name: []const u8, copy: ?Copy) Allocator.Error!?*Image {
        const files = table.files orelse return null;
        var made = try mod_pictures.load(table.gpa, files, name, table.longest(), table.compressor, copy) orelse return null;
        errdefer made.deinit(table.gpa);
        const image = try table.gpa.create(Image);
        image.* = made;
        return image;
    }

    /// Lets go of the pixels of the images the device holds its own copy of (`Image.held`), where
    /// `release_held` says that nothing else reads them. Their sizes stay.
    pub fn releaseHeld(table: *Table) void {
        var kept: usize = 0;
        for (table.unreleased.items) |image| {
            if (!image.held) {
                table.unreleased.items[kept] = image;
                kept += 1;
                continue;
            }
            releasePixels(table.gpa, image.levels);
            for (image.maps.list()) |map| if (map) |levels| releasePixels(table.gpa, levels);
        }
        table.unreleased.shrinkRetainingCapacity(kept);
    }

    /// Keeps `image`, which the table made, to let go of its pixels once the device holds them.
    fn track(table: *Table, image: *Image) Allocator.Error!void {
        if (table.release_held) try table.unreleased.append(table.gpa, image);
    }
};

/// The longest side an image keeps: a picture larger loses its finest levels until it fits, so
/// that every GPU takes it.
pub const max_side = 8192;

/// `texture_upload`'s fitting of an image to the device's longest side (`0x004C9D1D` on), which
/// the texture detail lowers (`Table.largest`): where a side is longer, the image is made smaller by
/// the whole ratio of that side to the longest, each side by its own (`srimage.shrink`).
pub fn fit(gpa: Allocator, image: *Image, largest: ?u32) Allocator.Error!void {
    const side = largest orelse return;
    const ratio = [2]u32{ fitRatio(image.width(), side), fitRatio(image.height(), side) };
    if (ratio[0] > 1 or ratio[1] > 1) try srimage.shrink(gpa, image, ratio);
}

/// The whole ratio of `length` to `largest`, rounded down, where it is longer; 1 where it isn't.
fn fitRatio(length: u32, largest: u32) u32 {
    return if (length > largest) length / largest else 1;
}

/// What a picture holds, which its mipmaps are made for.
pub const Content = enum {
    /// Colours, sRGB-encoded, with alpha: their means are taken in linear light, weighted by alpha.
    colour,
    /// A normal map's vectors: their means are taken as vectors at their lengths and made a unit
    /// long again, the mean's own length kept in alpha, as Toksvig's method keeps it ("Mipmapping
    /// Normal Maps", 2005): 1 at the finest level, whatever alpha the picture holds, and the
    /// shorter the further the normals a texel stands for spread.
    normal,
    /// Linear values, such as occlusion, roughness and metallic: their plain means.
    data,
};

/// An image of `picture`, which it takes, with its mipmap levels made down to a pixel, each half
/// the last, rounding down (`halved`). A picture longer than `max_side` gives its finest levels up.
pub fn mipmapped(gpa: Allocator, picture: png.Picture) Allocator.Error!Image {
    return .{ .levels = try mipmaps(gpa, picture, .colour, max_side) };
}

/// The mipmap levels of `picture`, which it takes, made for `content`, as `mipmapped` makes them,
/// its finest levels given up while it is longer than `longest`. Where it fails, it lets the
/// picture go.
pub fn mipmaps(gpa: Allocator, picture: png.Picture, content: Content, longest: u32) Allocator.Error![]Level {
    return mipmapLevels(gpa, .{ .width = picture.width, .height = picture.height, .rgba = .rgba8, .texels = picture.rgba }, content, longest);
}

/// The mipmap levels of the 16-bit `picture`, which it takes, as `mipmaps` makes them, in 16-bit
/// RGBA (`rgba16`), so that a 16-bit normal map keeps its precision (#688).
pub fn mipmapsWide(gpa: Allocator, picture: png.WidePicture, content: Content, longest: u32) Allocator.Error![]Level {
    // The level's texels are bytes, which the table frees as bytes.
    const bytes = gpa.dupe(u8, std.mem.sliceAsBytes(picture.rgba)) catch |err| {
        picture.deinit(gpa);
        return err;
    };
    picture.deinit(gpa);
    return mipmapLevels(gpa, .{ .width = picture.width, .height = picture.height, .rgba = .rgba16, .texels = bytes }, content, longest);
}

/// The mipmap levels of `picture`, made for `content`. The levels take over `picture`'s texels.
fn mipmapLevels(gpa: Allocator, picture: RgbaLevel, content: Content, longest: u32) Allocator.Error![]Level {
    var levels: std.ArrayList(Level) = .empty;
    errdefer {
        for (levels.items) |l| gpa.free(l.texels);
        levels.deinit(gpa);
    }
    // Each of a normal map's own normals stands for itself alone, at its full length.
    if (content == .normal) switch (picture.rgba) {
        .rgba8 => for (std.mem.bytesAsSlice([4]u8, picture.texels)) |*texel| {
            texel[3] = std.math.maxInt(u8);
        },
        .rgba16 => for (std.mem.bytesAsSlice([8]u8, picture.texels)) |*texel| {
            std.mem.writeInt(u16, texel[6..8], std.math.maxInt(u16), .native);
        },
    };
    var finest = picture;
    {
        errdefer gpa.free(finest.texels);
        while (@max(finest.width, finest.height) > longest) {
            const smaller = try halved(gpa, finest, content);
            gpa.free(finest.texels);
            finest = smaller;
        }
        try levels.append(gpa, finest.asLevel());
    }
    var last = finest;
    while (last.width > 1 or last.height > 1) {
        last = try halved(gpa, last, content);
        levels.append(gpa, last.asLevel()) catch |err| {
            gpa.free(last.texels);
            return err;
        };
    }
    return levels.toOwnedSlice(gpa);
}

/// The level after `level`, in its own format: each side half its own, rounding down, at least a
/// pixel, and each pixel the mean of the up to four it covers, as `content` takes it.
fn halved(gpa: Allocator, level: RgbaLevel, content: Content) Allocator.Error!RgbaLevel {
    const width = @max(level.width / 2, 1);
    const height = @max(level.height / 2, 1);
    const made: RgbaLevel = .{ .width = width, .height = height, .rgba = level.rgba, .texels = try gpa.alloc(u8, level.rgba.asFormat().size(width, height)) };
    const halving: Halving = .{ .level = level, .made = made, .content = content };
    shareRows(height, least_rows, halving, Halving.rows);
    return made;
}

/// The least rows of a level worth a thread of their own as it is halved: fewer would cost more to
/// start than they save.
const least_rows = 64;

/// A level being halved (`halved`), whose rows each thread makes some of.
const Halving = struct {
    level: RgbaLevel,
    made: RgbaLevel,
    content: Content,

    /// Makes `count` rows of `made` from `first`.
    fn rows(halving: Halving, first: usize, count: usize) void {
        const Rgb = @Vector(3, f32);
        const level = halving.level;
        const made = halving.made;
        for (first..first + count) |y| for (0..made.width) |x| {
            var sum: Rgb = @splat(0);
            var weighted: Rgb = @splat(0);
            var alpha: f32 = 0;
            const columns = [2]usize{ @min(2 * x, level.width - 1), @min(2 * x + 1, level.width - 1) };
            const from = [2]usize{ @min(2 * y, level.height - 1), @min(2 * y + 1, level.height - 1) };
            for (from) |row| for (columns) |column| {
                const at = row * level.width + column;
                const texel = unitsAt(level, at);
                const value: Rgb = switch (halving.content) {
                    .colour => lightAt(level, at),
                    .normal => direction(Rgb{ texel[0], texel[1], texel[2] } * @as(Rgb, @splat(2)) - @as(Rgb, @splat(1))),
                    .data => .{ texel[0], texel[1], texel[2] },
                };
                const weight = texel[3];
                sum += value;
                weighted += value * @as(Rgb, @splat(weight));
                alpha += weight;
            };
            const out = y * made.width + x;
            const mean_alpha = alpha / 4;
            switch (halving.content) {
                .colour => {
                    // Weighted by alpha, so that a clear pixel lends its colour nothing; where the
                    // four are all clear, the mean of their colours, which filtering may still
                    // reach.
                    const mean = if (alpha > 0) weighted / @as(Rgb, @splat(alpha)) else sum / @as(Rgb, @splat(4));
                    storeLight(made, out, mean, mean_alpha);
                },
                .normal => {
                    // The mean of the vectors at the lengths their alpha keeps: its direction, and
                    // its own length in alpha.
                    const mean = weighted / @as(Rgb, @splat(4));
                    const encoded = (direction(mean) + @as(Rgb, @splat(1))) / @as(Rgb, @splat(2));
                    store(made, out, .{ encoded[0], encoded[1], encoded[2], math.length(mean) });
                },
                .data => {
                    const mean = sum / @as(Rgb, @splat(4));
                    store(made, out, .{ mean[0], mean[1], mean[2], mean_alpha });
                },
            }
        };
    }
};

/// The most threads `shareRows` shares a picture's rows between.
pub const max_threads = 16;

/// OpenReliant's: runs `work(context, first, count)` over `rows` rows of a picture, shared out in
/// runs between as many threads as the computer has cores, at most `max_threads`, each taking at
/// least `least` rows. The caller's thread takes the first run. A thread that can't start leaves
/// its run to the caller.
///
/// **Improvement:** the original works on one core; a large mod picture's mipmaps and compression
/// are shared between them all.
pub fn shareRows(rows: usize, least: usize, context: anytype, comptime work: fn (@TypeOf(context), usize, usize) void) void {
    const wanted = @max(@min(std.Thread.getCpuCount() catch 1, max_threads, rows / @max(least, 1)), 1);
    const share = @divCeil(rows, wanted);
    var threads: [max_threads]?std.Thread = @splat(null);
    var first: usize = @min(share, rows);
    for (threads[1..wanted]) |*thread| {
        if (first >= rows) break;
        const count = @min(share, rows - first);
        thread.* = std.Thread.spawn(.{}, work, .{ context, first, count }) catch blk: {
            work(context, first, count);
            break :blk null;
        };
        first += count;
    }
    work(context, 0, @min(share, rows));
    for (threads) |thread| if (thread) |started| started.join();
}

/// The samples of texel `at` of `level`, each from 0 to 1.
fn unitsAt(level: RgbaLevel, at: usize) [4]f32 {
    var units: [4]f32 = undefined;
    switch (level.rgba) {
        .rgba8 => for (&units, level.texels[at * 4 ..][0..4]) |*value, sample| {
            value.* = texels.unit(u8, sample);
        },
        .rgba16 => for (&units, 0..) |*value, channel| {
            value.* = texels.unit(u16, std.mem.readInt(u16, level.texels[(at * 4 + channel) * 2 ..][0..2], .native));
        },
    }
    return units;
}

/// The samples of texel `at` of `level` at 16 bits, an 8-bit sample scaled up exactly.
pub fn samplesAt(level: RgbaLevel, at: usize) [4]u16 {
    var samples: [4]u16 = undefined;
    switch (level.rgba) {
        .rgba8 => for (&samples, level.texels[at * 4 ..][0..4]) |*wide, sample| {
            wide.* = @as(u16, sample) * eight_to_sixteen;
        },
        .rgba16 => for (&samples, 0..) |*wide, channel| {
            wide.* = std.mem.readInt(u16, level.texels[(at * 4 + channel) * 2 ..][0..2], .native);
        },
    }
    return samples;
}

/// The 8-bit sample nearest the 16-bit `sample`.
pub fn sample8(sample: u16) u8 {
    return @intCast((@as(u32, sample) + eight_to_sixteen / 2) / eight_to_sixteen);
}

/// What an 8-bit sample is multiplied by to scale it to 16 bits: 65535 / 255.
const eight_to_sixteen = std.math.maxInt(u16) / std.math.maxInt(u8);

/// The light of texel `at` of `level`, whose colours are sRGB-encoded.
fn lightAt(level: RgbaLevel, at: usize) @Vector(3, f32) {
    if (level.rgba == .rgba8) {
        const texel = level.texels[at * 4 ..][0..4];
        return .{ colour.light(texel[0]), colour.light(texel[1]), colour.light(texel[2]) };
    }
    const units = unitsAt(level, at);
    return .{ colour.decoded(units[0]), colour.decoded(units[1]), colour.decoded(units[2]) };
}

/// Sets texel `at` of `level` to `units`, each from 0 to 1.
fn store(level: RgbaLevel, at: usize, units: [4]f32) void {
    switch (level.rgba) {
        .rgba8 => for (level.texels[at * 4 ..][0..4], units) |*sample, value| {
            sample.* = texels.nearest(u8, value);
        },
        .rgba16 => for (units, 0..) |value, channel| {
            std.mem.writeInt(u16, level.texels[(at * 4 + channel) * 2 ..][0..2], texels.nearest(u16, value), .native);
        },
    }
}

/// Sets texel `at` of `level` to the light `light`, sRGB-encoded, and `alpha`.
fn storeLight(level: RgbaLevel, at: usize, light: @Vector(3, f32), alpha: f32) void {
    if (level.rgba == .rgba8) {
        // The 8-bit level nearest each light, exactly as the table finds it.
        level.texels[at * 4 ..][0..4].* = .{ colour.level(light[0]), colour.level(light[1]), colour.level(light[2]), texels.nearest(u8, alpha) };
        return;
    }
    store(level, at, .{ colour.encoded(light[0]), colour.encoded(light[1]), colour.encoded(light[2]), alpha });
}

/// `normal` a unit long; straight out of the surface where it has no length.
fn direction(normal: math.Vector) math.Vector {
    const length = math.length(normal);
    return if (length > 0) normal / @as(math.Vector, @splat(length)) else .{ 0, 0, 1 };
}

fn decode(gpa: Allocator, texture: tcache.Texture, palette: *const tga.Palette) Allocator.Error!Image {
    var levels: std.ArrayList(Level) = .empty;
    errdefer {
        for (levels.items) |l| gpa.free(l.texels);
        levels.deinit(gpa);
    }
    var n: u32 = 0;
    while (texture.level(n)) |source| : (n += 1) {
        const rgba = try source.rgba(gpa, palette);
        errdefer gpa.free(rgba);
        try levels.append(gpa, .{ .width = source.width, .height = source.height, .texels = rgba });
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
    var rgba = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 };
    var levels = [_]Level{.{ .width = 2, .height = 1, .texels = &rgba }};
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

test "the texture detail fits the cache's images" {
    const gpa = std.testing.allocator;
    const bytes = try tcache.testing.build(gpa, &.{
        .{ .name = "square", .encoding = .index8, .width = 8, .height = 8, .levels = 4, .flags = .{ .mipmaps = true } },
        .{ .name = "wide", .encoding = .index8, .width = 8, .height = 4, .levels = 3, .flags = .{ .mipmaps = true } },
        .{ .name = "small", .encoding = .index8, .width = 4, .height = 4, .levels = 3, .flags = .{ .mipmaps = true } },
    });
    defer gpa.free(bytes);
    const cache: tcache.Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);
    var table: Table = .init(gpa, cache, std.mem.zeroes(tga.Palette));
    defer table.deinit();
    table.largest = 4;
    // Halved both ways, the square gives its finest level up; the wide one, halved across alone, is
    // averaged down to 4 by 4; and one that fits is kept as it is.
    const square = (try table.find("square")).?;
    try std.testing.expectEqual([2]usize{ 4, 3 }, [2]usize{ square.width(), square.levels.len });
    const wide = (try table.find("wide")).?;
    try std.testing.expectEqual([2]u32{ 4, 4 }, [2]u32{ wide.width(), wide.height() });
    try std.testing.expectEqual(3, (try table.find("small")).?.levels.len);
    // A side under twice the longest is not shrunk: the ratio is a whole one.
    try std.testing.expectEqual(1, fitRatio(7, 4));
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
    const pictures: testing.Pictures = .{ .held = &.{
        .{ .name = "kiev_1.png", .bytes = written.written() },
        .{ .name = "hull.png", .bytes = "no picture" },
    } };

    var table: Table = .init(gpa, cache, std.mem.zeroes(tga.Palette));
    defer table.deinit();
    table.files = pictures.files();
    // The picture, whatever the case of the name asked for, with its levels down to a pixel.
    const kiev = (try table.find("KIEV_1")).?;
    try std.testing.expectEqual(4, kiev.width());
    try std.testing.expectEqual(3, kiev.levels.len);
    // The cache's where the picture can't be read.
    const hull = (try table.find("hull")).?;
    try std.testing.expectEqual(2, hull.width());
}

test "Table.prefetch" {
    const gpa = std.testing.allocator;
    const bytes = try tcache.testing.build(gpa, &.{
        .{ .name = "wing", .encoding = .index8, .width = 2, .height = 2 },
        .{ .name = "tail", .encoding = .index8, .width = 2, .height = 2 },
    });
    defer gpa.free(bytes);
    const cache: tcache.Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);

    // Mods' pictures of the tail and of the nose's green copy, all red.
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    var red: [4 * 2 * 4]u8 = undefined;
    for (0..8) |at| red[at * 4 ..][0..4].* = .{ 0xFF, 0, 0, 0xFF };
    try png.writeRgba(gpa, &written.writer, 4, 2, &red);
    const pictures: testing.Pictures = .{ .held = &.{
        .{ .name = "tail.png", .bytes = written.written() },
        .{ .name = "gnose.png", .bytes = written.written() },
    } };
    var table: Table = .init(gpa, cache, std.mem.zeroes(tga.Palette));
    defer table.deinit();
    table.files = pictures.files();

    // The mod's picture of the tail is decoded once, whatever the case of its names, and find
    // gives it; the wing, which has none, and a name nothing has are left to find.
    try table.prefetch(&.{ "TAIL", "tail", "wing", "missing" }, null);
    try std.testing.expectEqual(1, table.images.count());
    const tail = (try table.find("tail")).?;
    try std.testing.expectEqual(4, tail.width());
    try std.testing.expectEqual(tail, table.images.get("tail").?.?);
    try std.testing.expectEqual(2, (try table.find("wing")).?.width());

    // Copies, as findCopy orders them: the copy made from the picture of the name. The mod's
    // picture of the nose's copy is passed over, and with no picture of the nose, none is made.
    try table.prefetch(&.{ "nose", "tail" }, .green);
    try std.testing.expectEqual(null, try table.findCopy("nose", .green));
    try std.testing.expectEqual([4]u8{ 23, 255, 13, 0xFF }, (try table.findCopy("tail", .green)).?.levels[0].texels[0..4].*);
}

test "Table.findCopy" {
    const gpa = std.testing.allocator;
    const bytes = try tcache.testing.build(gpa, &.{
        .{ .name = "hull", .encoding = .index8, .width = 2, .height = 2 },
        .{ .name = "wing", .encoding = .index8, .width = 2, .height = 2 },
        .{ .name = "gwing", .encoding = .index8, .width = 2, .height = 2 },
        .{ .name = "tail", .encoding = .index8, .width = 2, .height = 2 },
        .{ .name = "gnose", .encoding = .index8, .width = 2, .height = 2 },
    });
    defer gpa.free(bytes);
    const cache: tcache.Cache = try .parse(gpa, bytes);
    defer cache.deinit(gpa);
    var palette: tga.Palette = undefined;
    for (&palette, 0..) |*c, i| c.* = .{ @truncate(i), 0, 0 };

    // A mod's picture of the tail, all red, and of the nose's copy.
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    var red: [4 * 2 * 4]u8 = undefined;
    for (0..8) |at| red[at * 4 ..][0..4].* = .{ 0xFF, 0, 0, 0xFF };
    try png.writeRgba(gpa, &written.writer, 4, 2, &red);
    const pictures: testing.Pictures = .{ .held = &.{
        .{ .name = "tail.png", .bytes = written.written() },
        .{ .name = "gnose.png", .bytes = written.written() },
    } };

    var table: Table = .init(gpa, cache, palette);
    defer table.deinit();
    table.files = pictures.files();
    // The cache's own copy, which is the image of its name.
    const wing = (try table.findCopy("WING", .green)).?;
    try std.testing.expectEqual(wing, (try table.find("gwing")).?);
    // A copy made from the cache's image where it has none: its red palette turned green.
    const hull = (try table.findCopy("hull", .green)).?;
    try std.testing.expect(hull != (try table.find("hull")).?);
    try std.testing.expectEqual(hull, (try table.findCopy("hull", .green)).?);
    for (0..4) |at| try std.testing.expect(hull.levels[0].texels[at * 4 + 1] >= hull.levels[0].texels[at * 4]);
    // A copy made from the mod's picture rather than the cache's image. The mod's own copy is
    // passed over, for the cache's.
    const tail = (try table.findCopy("tail", .red)).?;
    try std.testing.expectEqual(4, tail.width());
    try std.testing.expectEqual([4]u8{ 0xFF, 0, 0, 0xFF }, tail.levels[0].texels[0..4].*);
    const nose = (try table.findCopy("nose", .green)).?;
    try std.testing.expectEqual(2, nose.width());
    // Nothing to make a copy from.
    try std.testing.expectEqual(null, try table.findCopy("missing", .green));
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
        .{ .name = "hull_emissive.png", .rgba = .{ 255, 0, 0, 255 } },
    } };
    var table: Table = .init(gpa, cache, std.mem.zeroes(tga.Palette));
    defer table.deinit();
    table.files = .{ .context = &separate, .readFn = Pictures.read };
    const hull = (try table.find("hull")).?;
    // Drawn uncompressed, the normal map keeps its x and y at 16 bits.
    try std.testing.expectEqual(2, hull.maps.normal.?.len);
    try std.testing.expectEqual(Level.Format.rg16, hull.maps.normal.?[1].format);
    const xy = hull.maps.normal.?[1].texels;
    try std.testing.expectEqual(128 * 257, std.mem.readInt(u16, xy[0..2], .native));
    try std.testing.expectEqual(128 * 257, std.mem.readInt(u16, xy[2..4], .native));
    try std.testing.expectEqualSlices(u8, &.{ 255, 64, 255, 255 }, hull.maps.orm.?[0].texels[0..4]);
    // An emissive map is a picture's colours, mipmapped as they are.
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, hull.maps.emissive.?[1].texels);

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
    try std.testing.expectEqual(null, packed_hull.maps.emissive);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, packed_hull.maps.orm.?[1].texels);
}

test shareRows {
    // Every row is done once, however the rows are shared out.
    const Count = struct {
        done: *[1000]std.atomic.Value(u32),

        fn rows(count: @This(), first: usize, many: usize) void {
            for (first..first + many) |row| _ = count.done[row].fetchAdd(1, .monotonic);
        }
    };
    for ([_]usize{ 0, 1, 7, 1000 }) |rows| for ([_]usize{ 1, 64 }) |least| {
        var done: [1000]std.atomic.Value(u32) = @splat(.init(0));
        shareRows(rows, least, Count{ .done = &done }, Count.rows);
        for (done, 0..) |row, at| try std.testing.expectEqual(@intFromBool(at < rows), row.load(.monotonic));
    };
}

test RgbaLevel {
    // A compressed level isn't RGBA; a 16-bit one is, and comes back as it was.
    var blocks: [16]u8 = @splat(0);
    try std.testing.expectEqual(null, RgbaLevel.of(.{ .width = 4, .height = 4, .format = .bc7, .texels = &blocks }));
    var wide: [8]u8 = @splat(0);
    const level: Level = .{ .width = 1, .height = 1, .format = .rgba16, .texels = &wide };
    const rgba = RgbaLevel.of(level).?;
    try std.testing.expectEqual(.rgba16, rgba.rgba);
    try std.testing.expectEqual(level, rgba.asLevel());
}

test samplesAt {
    // An 8-bit pixel scaled up exactly, and a 16-bit one as it is.
    var narrow = [_]u8{ 255, 0, 128, 255 };
    try std.testing.expectEqual([4]u16{ 65535, 0, 32896, 65535 }, samplesAt(.{ .width = 1, .height = 1, .rgba = .rgba8, .texels = &narrow }, 0));
    var wide: [8]u8 = undefined;
    for ([_]u16{ 1, 2, 3, 4 }, 0..) |sample, channel| std.mem.writeInt(u16, wide[channel * 2 ..][0..2], sample, .native);
    try std.testing.expectEqual([4]u16{ 1, 2, 3, 4 }, samplesAt(.{ .width = 1, .height = 1, .rgba = .rgba16, .texels = &wide }, 0));
}

test "a level halved between threads is the level halved on one" {
    const gpa = std.testing.allocator;
    const side = 512;
    const rgba = try gpa.alloc(u8, side * side * 4);
    defer gpa.free(rgba);
    for (rgba, 0..) |*sample, at| sample.* = @truncate(at *% 2654435761 >> 13);
    const level: RgbaLevel = .{ .width = side, .height = side, .rgba = .rgba8, .texels = rgba };
    for (std.enums.values(Content)) |content| {
        const shared = try halved(gpa, level, content);
        defer gpa.free(shared.texels);
        const alone: RgbaLevel = .{ .width = side / 2, .height = side / 2, .rgba = .rgba8, .texels = try gpa.alloc(u8, side / 2 * side / 2 * 4) };
        defer gpa.free(alone.texels);
        Halving.rows(.{ .level = level, .made = alone, .content = content }, 0, side / 2);
        try std.testing.expectEqualSlices(u8, alone.texels, shared.texels);
    }
}

test "mipmaps of normals and of values" {
    const gpa = std.testing.allocator;
    // Normals leaning an eighth of a turn either way along x, by turns: the finest level keeps
    // them at their full length, whatever alpha the picture gives them; the next means them one
    // straight out of the surface, as long as the cosine of their lean, and the one after keeps
    // that length.
    const leaning = try gpa.dupe(u8, &.{ 218, 128, 218, 0, 38, 128, 218, 0, 218, 128, 218, 0, 38, 128, 218, 0 });
    const normals = try mipmaps(gpa, .{ .width = 4, .height = 1, .rgba = leaning }, .normal, max_side);
    defer freeLevels(gpa, normals);
    try std.testing.expectEqualSlices(u8, &.{ 218, 128, 218, 255 }, normals[0].texels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 255, 181 }, normals[1].texels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 255, 181 }, normals[2].texels);
    // Values mean plainly, not in linear light as colours do.
    const values = try gpa.dupe(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255 });
    const data = try mipmaps(gpa, .{ .width = 2, .height = 1, .rgba = values }, .data, max_side);
    defer freeLevels(gpa, data);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, data[1].texels);
}

test mipmapsWide {
    const gpa = std.testing.allocator;
    // A normal leaning a hair along x, finer than 8 bits tell apart from straight out: 16-bit
    // levels keep the lean, at the finest level and in the mean of the next.
    const lean: u16 = 0x8040;
    const rgba = try gpa.dupe(u16, &.{ lean, 0x8000, 0xFFFF, 0, lean, 0x8000, 0xFFFF, 0 });
    const normals = try mipmapsWide(gpa, .{ .width = 2, .height = 1, .rgba = rgba }, .normal, max_side);
    defer freeLevels(gpa, normals);
    try std.testing.expectEqual(Level.Format.rgba16, normals[0].format);
    try std.testing.expectEqual([4]f32{ texels.unit(u16, lean), texels.unit(u16, 0x8000), 1, 1 }, unitsAt(RgbaLevel.of(normals[0]).?, 0));
    const mean = unitsAt(RgbaLevel.of(normals[1]).?, 0);
    try std.testing.expect(mean[0] > texels.unit(u16, 0x8020));
    try std.testing.expectApproxEqAbs(1, mean[3], 1e-4);
}

test mipmapped {
    const gpa = std.testing.allocator;
    // Black and white, which mean the grey of half their light, not half their levels.
    const black_white = try gpa.dupe(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255 });
    const grey = try mipmapped(gpa, .{ .width = 2, .height = 1, .rgba = black_white });
    defer grey.deinit(gpa);
    try std.testing.expectEqual(2, grey.levels.len);
    try std.testing.expectEqualSlices(u8, &.{ 188, 188, 188, 255 }, grey.levels[1].texels);

    // A clear pixel lends its colour nothing, and its alpha half.
    const half_clear = try gpa.dupe(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 0 });
    const red = try mipmapped(gpa, .{ .width = 2, .height = 1, .rgba = half_clear });
    defer red.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, red.levels[1].texels);

    // Past the longest side, the finest levels go.
    const long = try gpa.alloc(u8, (max_side + 1) * 4);
    @memset(long, 0x80);
    const kept = try mipmapped(gpa, .{ .width = max_side + 1, .height = 1, .rgba = long });
    defer kept.deinit(gpa);
    try std.testing.expectEqual(max_side / 2, kept.width());
    try std.testing.expectEqual(1, kept.levels[kept.levels.len - 1].width);
}

/// Fixtures for the tests here and in the modules that draw with textures.
pub const testing = struct {
    /// Files with their names and contents, found ignoring case, like a mod's pictures.
    pub const Pictures = struct {
        held: []const File,

        pub const File = struct { name: []const u8, bytes: []const u8 };

        pub fn files(pictures: *const Pictures) Files {
            return .{ .context = pictures, .readFn = read };
        }

        fn read(context: *const anyopaque, gpa: Allocator, name: []const u8) Allocator.Error!?[]u8 {
            const pictures: *const Pictures = @ptrCast(@alignCast(context));
            for (pictures.held) |file| {
                if (std.ascii.eqlIgnoreCase(file.name, name)) return try gpa.dupe(u8, file.bytes);
            }
            return null;
        }
    };

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

test {
    _ = srimage;
    _ = mod_pictures;
    _ = copies;
}

test "the table lets go of the pixels the device holds" {
    const gpa = std.testing.allocator;
    const textures = try testing.Textures.init(gpa, &.{ "hull", "lhull" });
    defer textures.deinit(gpa);
    textures.table.release_held = true;
    const hull = (try textures.table.find("hull")).?;
    const lhull = (try textures.table.find("lhull")).?;
    // The device took the hull, and not yet the other.
    hull.held = true;
    textures.table.releaseHeld();
    try std.testing.expect(!hull.readable() and lhull.readable());
    try std.testing.expectEqual(8, hull.width());
    for (hull.levels) |level| try std.testing.expectEqual(0, level.texels.len);
    try std.testing.expectEqual(1, textures.table.unreleased.items.len);
}

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
