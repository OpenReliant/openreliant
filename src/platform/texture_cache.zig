//! Mods' pictures compressed for the GPU ([#503](https://github.com/OpenReliant/openreliant/issues/503)),
//! and kept in the game folder's `cache/textures` between runs, so that a picture is decoded and
//! compressed once rather than at each start.
//!
//! `Store` is the texture table's compressor (`srtexture.Compressor`): it compresses with
//! `texture_compressor.zig`, and keeps each texture's picture in a file of its own
//! (`cache_file.zig`), named after the texture's name in any case. Its payload is the picture's
//! levels and its maps' (`Store.write`). Its key is the texture table's hash of the picture's files
//! and the texture detail, so a changed picture doesn't match it, compresses again and replaces the
//! file. A file that can't be written is logged.
//!
//! **Improvement:** the original's textures are small, and read as they are.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const openreliant = @import("openreliant");
const srtexture = openreliant.engine.surrender.surrenderlib.srtexture;
const Level = srtexture.Level;
const Image = srtexture.Image;
const Compressor = srtexture.Compressor;
const texels = openreliant.texels;
const cache_file = @import("cache_file.zig");
const texture_compressor = @import("texture_compressor.zig");

const log = std.log.scoped(.textures);

/// Where the cache is, in the game folder.
pub const folder = "cache/textures";

/// The cache's files. Change the version when the payload's layout changes.
const Files = cache_file.Files(.{ .folder = folder, .magic = "ORTX".*, .version = 2, .Key = Compressor.Key, .max_bytes = 1 << 30, .any_case = true });

comptime {
    // The layout the files of version 2 were written with, before the caches shared their files.
    std.debug.assert(@sizeOf(Files.Header) == 32);
}

/// A level as `Store.write` lays it out before its texels.
const LevelHeader = extern struct {
    width: u32,
    height: u32,
    format: u32,
};

/// The sets of levels a kept picture holds: the picture's, then each of its maps' in the order of
/// `Image.Maps`' fields, each with as many levels as it has, 0 where it has none.
const set_count = 1 + Image.Maps.count;

pub const Store = struct {
    io: Io,
    /// The game folder, or null to keep nothing.
    root: ?Io.Dir,
    /// The compressed formats the GPU takes.
    takes: std.EnumSet(Level.Format),

    pub fn compressor(store: *Store) Compressor {
        return .{ .context = store, .vtable = &.{ .compress = compress, .load = load, .store = keep }, .takes = store.takes };
    }

    fn from(context: *anyopaque) *Store {
        return @ptrCast(@alignCast(context));
    }

    fn compress(_: *anyopaque, gpa: Allocator, level: Level, kind: Compressor.Kind) Allocator.Error!Level {
        return texture_compressor.compress(gpa, level, kind);
    }

    fn files(store: *const Store) Files {
        return .{ .io = store.io, .root = store.root };
    }

    fn load(context: *anyopaque, gpa: Allocator, name: []const u8, key: *const Compressor.Key) Allocator.Error!?Image {
        const store = from(context);
        const read = try store.files().read(gpa, name, key.*) orelse return null;
        defer read.deinit(gpa);
        return decode(gpa, read.payload, store.takes);
    }

    fn keep(context: *anyopaque, name: []const u8, key: *const Compressor.Key, image: Image) void {
        const store = from(context);
        store.write(name, key, image) catch |err| log.warn("can't keep the compressed texture {s} in {s}: {s}", .{ name, folder, @errorName(err) });
    }

    /// Keeps `image` for the texture `name`: each of its sets of levels (`setsOf`) as the count of
    /// its levels, then each level's `LevelHeader` and texels.
    fn write(store: *Store, name: []const u8, key: *const Compressor.Key, image: Image) !void {
        const sets = setsOf(image);
        var table: [set_count * (1 + texels.max_levels * 2)][]const u8 = undefined;
        var headers: [set_count][texels.max_levels]LevelHeader = undefined;
        var counts: [set_count]u32 = undefined;
        var parts: usize = 0;
        for (sets, &headers, &counts) |levels, *made, *count| {
            count.* = @intCast(levels.len);
            table[parts] = std.mem.asBytes(count);
            parts += 1;
            for (levels, made[0..levels.len]) |level, *header| {
                header.* = .{ .width = level.width, .height = level.height, .format = @backingInt(level.format) };
                table[parts] = std.mem.asBytes(header);
                table[parts + 1] = level.texels;
                parts += 2;
            }
        }
        try store.files().write(name, key.*, table[0..parts]);
    }
};

/// A kept picture's sets of levels, in order: its own, then its maps'.
fn setsOf(image: Image) [set_count][]const Level {
    var sets: [set_count][]const Level = undefined;
    sets[0] = image.levels;
    for (image.maps.list(), sets[1..]) |map, *set| set.* = map orelse &.{};
    return sets;
}

/// The picture in a cache file's payload `body` if it is whole and the GPU takes its formats
/// (`takes`), or null.
fn decode(gpa: Allocator, body: []const u8, takes: std.EnumSet(Level.Format)) Allocator.Error!?Image {
    var reader: Reader = .{ .bytes = body };
    var sets: [set_count]?[]Level = @splat(null);
    errdefer for (sets) |found| if (found) |levels| freeLevels(gpa, levels);
    for (&sets) |*set| set.* = try reader.levels(gpa, takes) orelse {
        for (sets) |found| if (found) |levels| freeLevels(gpa, levels);
        return null;
    };
    if (reader.at != body.len or sets[0].?.len == 0) {
        for (sets) |found| if (found) |levels| freeLevels(gpa, levels);
        return null;
    }
    // A map with no levels is one the picture doesn't have.
    var maps: [Image.Maps.count]?[]Level = undefined;
    for (sets[1..], &maps) |set, *map| {
        map.* = if (set.?.len > 0) set.? else null;
        if (map.* == null) gpa.free(set.?);
    }
    return .{ .levels = sets[0].?, .maps = .fromList(maps) };
}

/// Reads the sets of levels of a cache file's body, checking each as it goes.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(reader: *Reader, count: usize) ?[]const u8 {
        if (reader.bytes.len - reader.at < count) return null;
        defer reader.at += count;
        return reader.bytes[reader.at..][0..count];
    }

    /// The next set of levels, copied; null where it is cut short, of sizes that don't fit, or of
    /// a format the GPU doesn't take.
    fn levels(reader: *Reader, gpa: Allocator, takes: std.EnumSet(Level.Format)) Allocator.Error!?[]Level {
        const count = std.mem.readInt(u32, (reader.take(4) orelse return null)[0..4], .little);
        if (count > texels.max_levels) return null;
        const made = try gpa.alloc(Level, count);
        var done: usize = 0;
        errdefer {
            for (made[0..done]) |level| gpa.free(level.texels);
            gpa.free(made);
        }
        for (made) |*level| {
            const header = std.mem.bytesToValue(LevelHeader, reader.take(@sizeOf(LevelHeader)) orelse return giveUp(gpa, made[0..done], made));
            const format = std.enums.fromInt(Level.Format, header.format) orelse return giveUp(gpa, made[0..done], made);
            if (format.compressed() and !takes.contains(format)) return giveUp(gpa, made[0..done], made);
            if (header.width == 0 or header.height == 0) return giveUp(gpa, made[0..done], made);
            const data = reader.take(format.size(header.width, header.height)) orelse return giveUp(gpa, made[0..done], made);
            level.* = .{ .width = header.width, .height = header.height, .format = format, .texels = try gpa.dupe(u8, data) };
            done += 1;
        }
        return made;
    }

    fn giveUp(gpa: Allocator, done: []const Level, made: []Level) ?[]Level {
        for (done) |level| gpa.free(level.texels);
        gpa.free(made);
        return null;
    }
};

const freeLevels = srtexture.freeLevels;

test Store {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: Store = .{ .io = io, .root = tmp.dir, .takes = .initMany(&.{ .bc5, .bc7 }) };
    const held = store.compressor();
    const key: Compressor.Key = 7;

    // A 4 by 4 picture in BC7 with a normal map in BC5 and an emissive map in BC7, kept and given
    // back.
    var picture_texels: [16]u8 = @splat(1);
    var normal_texels: [16]u8 = @splat(2);
    var picture = [_]Level{.{ .width = 4, .height = 4, .format = .bc7, .texels = &picture_texels }};
    var normal = [_]Level{.{ .width = 4, .height = 4, .format = .bc5, .texels = &normal_texels }};
    var emissive = [_]Level{.{ .width = 4, .height = 4, .format = .bc7, .texels = &picture_texels }};
    held.store("Hull", &key, .{ .levels = &picture, .maps = .{ .normal = &normal, .emissive = &emissive } });
    const kept = (try held.load(gpa, "hull", &key)).?;
    defer kept.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &picture_texels, kept.levels[0].texels);
    try std.testing.expectEqual(Level.Format.bc5, kept.maps.normal.?[0].format);
    try std.testing.expectEqual(null, kept.maps.orm);
    try std.testing.expectEqualSlices(u8, &picture_texels, kept.maps.emissive.?[0].texels);

    // Another key, a picture the GPU no longer takes, and none kept at all.
    try std.testing.expectEqual(null, try held.load(gpa, "hull", &@as(Compressor.Key, 8)));
    store.takes = .initOne(.bc5);
    try std.testing.expectEqual(null, try store.compressor().load(gpa, "hull", &key));
    try std.testing.expectEqual(null, try held.load(gpa, "other", &key));
}

test decode {
    const gpa = std.testing.allocator;
    const takes: std.EnumSet(Level.Format) = .full;
    // A payload of one 1 by 1 RGBA level and no maps, each map's count 0, then cut short.
    const map_counts = 4 * Image.Maps.count;
    var body: [4 + @sizeOf(LevelHeader) + 4 + map_counts]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], 1, .little);
    @memcpy(body[4..][0..@sizeOf(LevelHeader)], std.mem.asBytes(&LevelHeader{ .width = 1, .height = 1, .format = @backingInt(Level.Format.rgba8) }));
    @memcpy(body[4 + @sizeOf(LevelHeader) ..][0..4], &[_]u8{ 1, 2, 3, 4 });
    @memset(body[body.len - map_counts ..], 0);
    const image = (try decode(gpa, &body, takes)).?;
    defer image.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, image.levels[0].texels);
    try std.testing.expectEqual(null, try decode(gpa, body[0 .. body.len - 1], takes));
    // A level of a format the GPU doesn't take is left out.
    std.mem.writeInt(u32, body[8..12], @backingInt(Level.Format.bc7), .little);
    try std.testing.expectEqual(null, try decode(gpa, &body, .initOne(.bc5)));
}
