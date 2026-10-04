//! Mods' pictures compressed for the GPU ([#503](https://github.com/OpenReliant/openreliant/issues/503)),
//! and kept in the game folder's `cache/textures` between runs, so that a picture is decoded and
//! compressed once rather than at each start.
//!
//! `Store` is the texture table's compressor (`srtexture.Compressor`): it compresses with
//! `texture_compressor.zig`, and keeps each texture's picture in a file of its own, named by a hash
//! of the texture's name. The file holds a `Header`, then the picture's levels and its maps'
//! (`encode`). The header's key is the texture table's hash of the picture's files and the texture
//! detail, so a changed picture doesn't match it, compresses again and replaces the file. A file
//! that is damaged or can't be read is ignored, and one that can't be written is logged. The folder
//! can be deleted at any time.
//!
//! **Improvement:** the original's textures are small, and read as they are.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const XxHash3 = std.hash.XxHash3;

const openreliant = @import("openreliant");
const srtexture = openreliant.engine.surrender.surrenderlib.srtexture;
const Level = srtexture.Level;
const Image = srtexture.Image;
const Compressor = srtexture.Compressor;
const texture_compressor = @import("texture_compressor.zig");

const log = std.log.scoped(.textures);

/// Where the cache is, in the game folder.
pub const folder = "cache/textures";

/// A cache file's extension.
const extension = ".bin";

/// What a cache file starts with.
const magic = "ORTX".*;

/// The version of the cache files' layout. Change it when `Header` or `encode` changes.
const format_version: u32 = 1;

/// The largest cache file read.
const max_file_bytes = 1 << 30;

/// The start of a cache file.
const Header = extern struct {
    magic: [4]u8 = magic,
    version: u32 = format_version,
    /// The texture table's key of what was kept (`Compressor.Key`).
    key: Compressor.Key,
    /// The XxHash3 of what follows, and its size in bytes.
    check: u64,
    size: u64,

    comptime {
        std.debug.assert(@sizeOf(Header) == 56);
    }
};

/// A level as `encode` lays it out before its texels.
const LevelHeader = extern struct {
    width: u32,
    height: u32,
    format: u32,
};

/// The sets of levels a kept picture holds: the picture's, then its normal map's and its material
/// map's, each with as many levels as it has, 0 where it has none.
const set_count = 3;

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

    fn load(context: *anyopaque, gpa: Allocator, name: []const u8, key: *const Compressor.Key) Allocator.Error!?Image {
        const store = from(context);
        const root = store.root orelse return null;
        const path = pathOf(name);
        const bytes = root.readFileAlloc(store.io, &path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return null,
        };
        defer gpa.free(bytes);
        return decode(gpa, bytes, key, store.takes);
    }

    fn keep(context: *anyopaque, name: []const u8, key: *const Compressor.Key, image: Image) void {
        const store = from(context);
        store.write(name, key, image) catch |err| log.warn("can't keep the compressed texture {s} in {s}: {s}", .{ name, folder, @errorName(err) });
    }

    fn write(store: *Store, name: []const u8, key: *const Compressor.Key, image: Image) !void {
        const root = store.root orelse return;
        const sets = setsOf(image);
        var check: XxHash3 = .init(0);
        var size: u64 = 0;
        var table: [set_count * (1 + 17 * 2)][]const u8 = undefined;
        var headers: [set_count][17]LevelHeader = undefined;
        var counts: [set_count]u32 = undefined;
        var parts: usize = 0;
        for (sets, &headers, &counts) |levels, *made, *count| {
            count.* = @intCast(levels.len);
            table[parts] = std.mem.asBytes(count);
            parts += 1;
            for (levels, made[0..levels.len]) |level, *header| {
                header.* = .{ .width = level.width, .height = level.height, .format = @intFromEnum(level.format) };
                table[parts] = std.mem.asBytes(header);
                table[parts + 1] = level.texels;
                parts += 2;
            }
        }
        for (table[0..parts]) |part| {
            check.update(part);
            size += part.len;
        }
        const header: Header = .{ .key = key.*, .check = check.final(), .size = size };
        const path = pathOf(name);
        var file = try root.createFileAtomic(store.io, &path, .{ .make_path = true, .replace = true });
        defer file.deinit(store.io);
        try file.file.writeStreamingAll(store.io, std.mem.asBytes(&header));
        for (table[0..parts]) |part| try file.file.writeStreamingAll(store.io, part);
        try file.replace(store.io);
    }
};

/// A kept picture's sets of levels, in order: its own, its normal map's, its material map's.
fn setsOf(image: Image) [set_count][]const Level {
    return .{ image.levels, image.maps.normal orelse &.{}, image.maps.orm orelse &.{} };
}

/// The path of the texture `name`'s cache file in the game folder.
fn pathOf(name: []const u8) [folder.len + 1 + Sha256.digest_length * 2 + extension.len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    var lowered: [256]u8 = undefined;
    Sha256.hash(std.ascii.lowerString(lowered[0..@min(name.len, lowered.len)], name[0..@min(name.len, lowered.len)]), &digest, .{});
    return (folder ++ "/").* ++ std.fmt.bytesToHex(digest, .lower) ++ extension.*;
}

/// The picture in the cache file `bytes` if its key is `key`, it is whole, and the GPU takes its
/// formats (`takes`), or null.
fn decode(gpa: Allocator, bytes: []const u8, key: *const Compressor.Key, takes: std.EnumSet(Level.Format)) Allocator.Error!?Image {
    if (bytes.len < @sizeOf(Header)) return null;
    const header = std.mem.bytesToValue(Header, bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.magic, &magic) or header.version != format_version) return null;
    if (!std.mem.eql(u8, &header.key, key)) return null;
    const body = bytes[@sizeOf(Header)..];
    if (header.size != body.len or XxHash3.hash(0, body) != header.check) return null;
    var reader: Reader = .{ .bytes = body };
    var sets: [set_count]?[]const Level = @splat(null);
    errdefer for (sets) |found| if (found) |levels| freeLevels(gpa, levels);
    for (&sets) |*set| set.* = try reader.levels(gpa, takes) orelse {
        for (sets) |found| if (found) |levels| freeLevels(gpa, levels);
        return null;
    };
    if (reader.at != body.len or sets[0].?.len == 0) {
        for (sets) |found| if (found) |levels| freeLevels(gpa, levels);
        return null;
    }
    const maps: Image.Maps = .{
        .normal = if (sets[1].?.len > 0) sets[1].? else blk: {
            gpa.free(sets[1].?);
            break :blk null;
        },
        .orm = if (sets[2].?.len > 0) sets[2].? else blk: {
            gpa.free(sets[2].?);
            break :blk null;
        },
    };
    return .{ .levels = sets[0].?, .maps = maps };
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
    fn levels(reader: *Reader, gpa: Allocator, takes: std.EnumSet(Level.Format)) Allocator.Error!?[]const Level {
        const count = std.mem.readInt(u32, (reader.take(4) orelse return null)[0..4], .little);
        if (count > 17) return null;
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

    fn giveUp(gpa: Allocator, done: []const Level, made: []Level) ?[]const Level {
        for (done) |level| gpa.free(level.texels);
        gpa.free(made);
        return null;
    }
};

fn freeLevels(gpa: Allocator, levels: []const Level) void {
    for (levels) |level| gpa.free(level.texels);
    gpa.free(levels);
}

test Store {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: Store = .{ .io = io, .root = tmp.dir, .takes = .initMany(&.{ .bc5, .bc7 }) };
    const held = store.compressor();
    const key: Compressor.Key = @splat(7);

    // A 4 by 4 picture in BC7 with a normal map in BC5, kept and given back.
    var picture_texels: [16]u8 = @splat(1);
    var normal_texels: [16]u8 = @splat(2);
    var picture = [_]Level{.{ .width = 4, .height = 4, .format = .bc7, .texels = &picture_texels }};
    var normal = [_]Level{.{ .width = 4, .height = 4, .format = .bc5, .texels = &normal_texels }};
    held.store("Hull", &key, .{ .levels = &picture, .maps = .{ .normal = &normal } });
    const kept = (try held.load(gpa, "hull", &key)).?;
    defer kept.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &picture_texels, kept.levels[0].texels);
    try std.testing.expectEqual(Level.Format.bc5, kept.maps.normal.?[0].format);
    try std.testing.expectEqual(null, kept.maps.orm);

    // Another key, a picture the GPU no longer takes, and none kept at all.
    try std.testing.expectEqual(null, try held.load(gpa, "hull", &@as(Compressor.Key, @splat(8))));
    store.takes = .initOne(.bc5);
    try std.testing.expectEqual(null, try store.compressor().load(gpa, "hull", &key));
    try std.testing.expectEqual(null, try held.load(gpa, "other", &key));
}

test decode {
    const gpa = std.testing.allocator;
    const key: Compressor.Key = @splat(1);
    const takes: std.EnumSet(Level.Format) = .initFull();
    // A file of one 1 by 1 RGBA level and no maps, then cut short and changed.
    var body: [4 + @sizeOf(LevelHeader) + 4 + 4 + 4]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], 1, .little);
    @memcpy(body[4..][0..@sizeOf(LevelHeader)], std.mem.asBytes(&LevelHeader{ .width = 1, .height = 1, .format = @intFromEnum(Level.Format.rgba8) }));
    @memcpy(body[4 + @sizeOf(LevelHeader) ..][0..4], &[_]u8{ 1, 2, 3, 4 });
    @memset(body[body.len - 8 ..], 0);
    const header: Header = .{ .key = key, .check = XxHash3.hash(0, &body), .size = body.len };
    var file: [@sizeOf(Header) + body.len]u8 = undefined;
    @memcpy(file[0..@sizeOf(Header)], std.mem.asBytes(&header));
    @memcpy(file[@sizeOf(Header)..], &body);
    const image = (try decode(gpa, &file, &key, takes)).?;
    defer image.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, image.levels[0].texels);
    try std.testing.expectEqual(null, try decode(gpa, file[0 .. file.len - 1], &key, takes));
    var damaged = file;
    damaged[damaged.len - 9] ^= 1;
    try std.testing.expectEqual(null, try decode(gpa, &damaged, &key, takes));
}
