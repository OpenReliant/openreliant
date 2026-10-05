//! OpenReliant's: the pictures that mods give in place of the texture cache's images
//! (`Table.files`), with their material maps, made into images ready for the device
//! ([#503](https://github.com/OpenReliant/openreliant/issues/503)).
//!
//! - A picture or a map is read from the first file of its name the mods give: `<name>.ktx2`,
//!   `<name>.dds` or `<name>.png` (`containers`). A map is `<name>_normal`, `<name>_orm`, the
//!   occlusion, roughness and metallic maps alone, packed into one as glTF packs them, or
//!   `<name>_emissive`.
//! - The loadout's green and red copies of a picture keep its normal and material maps, but not
//!   its emissive map, whose own colours would show through the copy's.
//! - Its files are read one after another, then decoded and mipmapped each on a thread of its own.
//! - For a device that takes compressed textures (`Compressor`), the picture is compressed:
//!   colours, material maps and emissive maps in BC7, normal maps in BC5, the length of a normal
//!   map's mean moved into the material map's alpha. What it compressed is kept between runs,
//!   keyed by the files and the texture detail, so that a picture is compressed once.
//! - A picture compressed already, in a DDS or KTX2 file, draws as it is where the device takes its
//!   format, and is left out otherwise, as is a map whose format doesn't go with its picture's.
//!
//! **Improvement:** the original reads the cache's images alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const XxHash3 = std.hash.XxHash3;

const png = @import("../../../../formats/png.zig");
const dds = @import("../../../../formats/dds.zig");
const ktx2 = @import("../../../../formats/ktx2.zig");
const texels = @import("../../../../formats/texels.zig");
const srtexture = @import("../srtexture.zig");
const Level = srtexture.Level;
const Image = srtexture.Image;
const MapFile = srtexture.MapFile;
const Compressor = srtexture.Compressor;
const Content = srtexture.Content;
const Copy = srtexture.Copy;

const log = std.log.scoped(.textures);

/// The kinds of file a picture can come in, in the order they are looked for.
pub const Container = enum {
    ktx2,
    dds,
    png,

    pub fn extension(container: Container) []const u8 {
        return switch (container) {
            .ktx2 => ktx2.extension,
            .dds => dds.extension,
            .png => png.extension,
        };
    }
};

pub const containers = std.enums.values(Container);

/// What changes the key of what the compressor keeps: change it when what `load` makes of the
/// same files changes.
const kept_version: u32 = 2;

/// A file of a picture, read: its kind, its name and its bytes, owned.
const File = struct {
    container: Container,
    name: []u8,
    bytes: []u8,

    fn deinit(file: File, gpa: Allocator) void {
        gpa.free(file.name);
        gpa.free(file.bytes);
    }
};

/// The files of a picture: its own, and each of its maps'.
const Read = struct {
    picture: ?File = null,
    maps: std.EnumArray(MapFile, ?File) = .initFill(null),

    fn deinit(read: *Read, gpa: Allocator) void {
        if (read.picture) |file| file.deinit(gpa);
        for (std.enums.values(MapFile)) |map| if (read.maps.get(map)) |file| file.deinit(gpa);
    }

    /// Reads the files `files` give the picture `name` and its maps.
    fn fill(read: *Read, gpa: Allocator, files: srtexture.Files, name: []const u8) Allocator.Error!void {
        read.picture = try first(gpa, files, name, "") orelse return;
        for (std.enums.values(MapFile)) |map| read.maps.set(map, try first(gpa, files, name, map.suffix()));
    }

    /// The key of what these files make at the longest side `longest`, or of their `copy`.
    fn key(read: *const Read, longest: u32, copy: ?Copy) Compressor.Key {
        var hash: XxHash3 = .init(0);
        hash.update(std.mem.asBytes(&kept_version));
        hash.update(std.mem.asBytes(&longest));
        if (copy) |made| hash.update(&[_]u8{made.letter()});
        const files = [_]?File{read.picture} ++ read.maps.values;
        for (files, 0..) |found, role| {
            const file = found orelse continue;
            hash.update(std.mem.asBytes(&@as(u32, @intCast(role))));
            hash.update(std.mem.asBytes(&@intFromEnum(file.container)));
            hash.update(std.mem.asBytes(&@as(u64, file.bytes.len)));
            hash.update(file.bytes);
        }
        return hash.final();
    }
};

/// The first file the files give as `name` and `suffix`, in the order of `containers`.
fn first(gpa: Allocator, files: srtexture.Files, name: []const u8, suffix: []const u8) Allocator.Error!?File {
    for (containers) |container| {
        const file_name = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ name, suffix, container.extension() });
        const bytes = files.read(gpa, file_name) catch |err| {
            gpa.free(file_name);
            return err;
        } orelse {
            gpa.free(file_name);
            continue;
        };
        return .{ .container = container, .name = file_name, .bytes = bytes };
    }
    return null;
}

/// The picture the files give for the texture `name`, with its maps, ready for the device; null
/// where they give none, or it can't be used, which the log says. `longest` is the longest side
/// it keeps; `compressor` compresses it, where the device takes compressed textures. With `copy`,
/// it is that copy of the picture (`copies`), kept by the compressor under the copy's own name.
pub fn load(gpa: Allocator, files: srtexture.Files, name: []const u8, longest: u32, compressor: ?Compressor, copy: ?Copy) Allocator.Error!?Image {
    var read: Read = .{};
    defer read.deinit(gpa);
    try read.fill(gpa, files, name);
    if (read.picture == null) return null;
    const key = read.key(longest, copy);
    const kept_name = if (copy) |made| try std.fmt.allocPrint(gpa, "{c}{s}", .{ made.letter(), name }) else name;
    defer if (copy != null) gpa.free(kept_name);
    if (compressor) |held| if (try held.load(gpa, kept_name, &key)) |kept| return kept;
    var made = try decodeAll(gpa, &read, longest) orelse return null;
    errdefer made.deinit(gpa);
    if (copy) |wanted| {
        if (made.levels[0].format != .rgba8) {
            log.info("no {t} copy of {s} is made: it is compressed already", .{ wanted, read.picture.?.name });
            made.deinit(gpa);
            return null;
        }
        wanted.tint(made.levels);
        if (made.maps.emissive) |levels| freeLevels(gpa, levels);
        made.maps.emissive = null;
    }
    const compressed = try conform(gpa, &made, &read, compressor) orelse {
        made.deinit(gpa);
        return null;
    };
    if (compressed) if (compressor) |held| held.store(kept_name, &key, made);
    return made;
}

/// The picture's files decoded, each on a thread of its own: the picture and its maps, a map of
/// another size than the picture's left out, which the log says.
fn decodeAll(gpa: Allocator, read: *const Read, longest: u32) Allocator.Error!?Image {
    const size = sizeOf(read.picture.?);
    var tasks = [_]Task{
        .{ .read = read, .role = .picture, .longest = longest, .gpa = gpa },
        .{ .read = read, .role = .normal, .longest = longest, .gpa = gpa },
        .{ .read = read, .role = .orm, .longest = longest, .gpa = gpa, .size = size },
        .{ .read = read, .role = .emissive, .longest = longest, .gpa = gpa },
    };
    var threads: [tasks.len]?std.Thread = @splat(null);
    for (tasks[1..], threads[1..]) |*task, *thread| {
        if (!task.wanted()) continue;
        thread.* = std.Thread.spawn(.{}, Task.run, .{task}) catch blk: {
            task.run();
            break :blk null;
        };
    }
    tasks[0].run();
    for (threads) |thread| if (thread) |started| started.join();
    var failed = false;
    for (tasks) |task| failed = failed or task.failed;
    const picture = tasks[0].made;
    var made: Image = .{ .levels = picture orelse &.{} };
    made.maps = .{ .normal = tasks[1].made, .orm = tasks[2].made, .emissive = tasks[3].made };
    if (failed or picture == null) {
        made.deinit(gpa);
        return if (failed) error.OutOfMemory else null;
    }
    // A map of another size than the picture's is left out.
    inline for (@typeInfo(Image.Maps).@"struct".fields) |field| {
        if (@field(made.maps, field.name)) |levels| if (levels[0].width != made.width() or levels[0].height != made.height()) {
            const map = @field(MapFile, field.name);
            log.warn("the {s} of {s} is left out: it is {d}x{d} and its picture {d}x{d}", .{ map.label(), read.picture.?.name, levels[0].width, levels[0].height, made.width(), made.height() });
            freeLevels(gpa, levels);
            @field(made.maps, field.name) = null;
        };
    }
    return made;
}

/// What a file of the picture is decoded as, on a thread of its own.
const Task = struct {
    read: *const Read,
    role: enum { picture, normal, orm, emissive },
    longest: u32,
    gpa: Allocator,
    /// The picture's own size, which a map packed from parts must have.
    size: ?[2]u32 = null,
    made: ?[]const Level = null,
    failed: bool = false,

    /// Whether the picture has a file for it.
    fn wanted(task: *const Task) bool {
        return switch (task.role) {
            .picture => task.read.picture != null,
            .normal => task.read.maps.get(.normal) != null,
            .orm => for ([_]MapFile{ .orm, .occlusion, .roughness, .metallic }) |map| {
                if (task.read.maps.get(map) != null) break true;
            } else false,
            .emissive => task.read.maps.get(.emissive) != null,
        };
    }

    fn run(task: *Task) void {
        if (!task.wanted()) return;
        task.made = task.decode() catch {
            task.failed = true;
            return;
        };
    }

    fn decode(task: *Task) Allocator.Error!?[]const Level {
        const read = task.read;
        return switch (task.role) {
            .picture => decodeFile(task.gpa, read.picture.?, .colour, task.longest),
            .normal => decodeFile(task.gpa, read.maps.get(.normal).?, .normal, task.longest),
            .orm => if (read.maps.get(.orm)) |file| decodeFile(task.gpa, file, .data, task.longest) else packedMap(task.gpa, read, task.size, task.longest),
            .emissive => decodeFile(task.gpa, read.maps.get(.emissive).?, .colour, task.longest),
        };
    }
};

/// `file`'s levels: a compressed file's or one with its levels as they are, its finest given up
/// while longer than `longest`; otherwise decoded and mipmapped for `content`. Null where it can't
/// be read, which the log says.
fn decodeFile(gpa: Allocator, file: File, content: Content, longest: u32) Allocator.Error!?[]const Level {
    if (file.container != .png) {
        var buffer: [texels.max_levels][]const u8 = undefined;
        const contained = contain(file, &buffer) orelse return null;
        if (contained.format.compressed() or contained.levels.len > 1) return try copied(gpa, contained, longest);
    }
    const picture = try pictureOf(gpa, file) orelse return null;
    return try srtexture.mipmaps(gpa, picture, content, longest);
}

/// The picture a DDS or KTX2 file holds; null where it can't be read, which the log says.
fn contain(file: File, buffer: *[texels.max_levels][]const u8) ?texels.Contained {
    const read = switch (file.container) {
        .dds => dds.read(file.bytes, buffer),
        .ktx2 => ktx2.read(file.bytes, buffer),
        .png => unreachable,
    };
    return read catch |err| {
        log.warn("{s} is left out: {s}", .{ file.name, @errorName(err) });
        return null;
    };
}

/// `contained`'s levels, copied, its finest given up while longer than `longest`, all but the
/// coarsest at most.
fn copied(gpa: Allocator, contained: texels.Contained, longest: u32) Allocator.Error![]const Level {
    var from: usize = 0;
    while (from + 1 < contained.levels.len and @max(contained.sizeOf(from)[0], contained.sizeOf(from)[1]) > longest) from += 1;
    const levels = try gpa.alloc(Level, contained.levels.len - from);
    var made: usize = 0;
    errdefer {
        for (levels[0..made]) |level| gpa.free(level.texels);
        gpa.free(levels);
    }
    for (levels, contained.levels[from..], from..) |*level, data, index| {
        const size = contained.sizeOf(index);
        level.* = .{ .width = size[0], .height = size[1], .format = contained.format, .texels = try gpa.dupe(u8, data) };
        made += 1;
    }
    return levels;
}

/// The size of the picture `file` holds, from its header; null where it can't be read.
fn sizeOf(file: File) ?[2]u32 {
    if (file.container == .png) return png.size(file.bytes) catch null;
    var buffer: [texels.max_levels][]const u8 = undefined;
    const contained = switch (file.container) {
        .dds => dds.read(file.bytes, &buffer),
        .ktx2 => ktx2.read(file.bytes, &buffer),
        .png => unreachable,
    } catch return null;
    return .{ contained.width, contained.height };
}

/// The 8-bit RGBA picture `file` holds; null where it can't be read, or is compressed, which the
/// log says.
fn pictureOf(gpa: Allocator, file: File) Allocator.Error!?png.Picture {
    if (file.container == .png) return png.read(gpa, file.bytes) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.NotAPng, error.Corrupt, error.Unsupported, error.BadSize => {
            log.warn("{s} is left out: {s}", .{ file.name, @errorName(err) });
            return null;
        },
    };
    var buffer: [texels.max_levels][]const u8 = undefined;
    const contained = contain(file, &buffer) orelse return null;
    if (contained.format.compressed()) {
        log.warn("{s} is left out: a map packed from parts takes them uncompressed", .{file.name});
        return null;
    }
    return .{ .width = contained.width, .height = contained.height, .rgba = try gpa.dupe(u8, contained.levels[0]) };
}

/// Occlusion, roughness and metallic packed into one material map, as glTF packs them, from their
/// maps alone, each the red of its own (grey) map, or where it has none no occlusion, rough, or
/// not metallic. Null where none of the three can be read; a part of another size than the
/// picture's, `picture_size`, or the first part's, is left out, which the log says.
fn packedMap(gpa: Allocator, read: *const Read, picture_size: ?[2]u32, longest: u32) Allocator.Error!?[]const Level {
    const parts = [_]MapFile{ .occlusion, .roughness, .metallic };
    const fallbacks = [parts.len]u8{ std.math.maxInt(u8), std.math.maxInt(u8), 0 };
    var pictures: [parts.len]?png.Picture = @splat(null);
    defer for (pictures) |found| if (found) |part| part.deinit(gpa);
    var size: ?[2]u32 = picture_size;
    var any = false;
    for (&pictures, parts) |*found, part| {
        const file = read.maps.get(part) orelse continue;
        const picture = try pictureOf(gpa, file) orelse continue;
        const own = [2]u32{ picture.width, picture.height };
        if (size) |wanted| if (!std.meta.eql(wanted, own)) {
            log.warn("{s} is left out: it is {d}x{d} and its picture {d}x{d}", .{ file.name, own[0], own[1], wanted[0], wanted[1] });
            picture.deinit(gpa);
            continue;
        };
        size = own;
        found.* = picture;
        any = true;
    }
    if (!any) return null;
    const whole = size.?;
    const count = @as(usize, whole[0]) * whole[1];
    const rgba = try gpa.alloc(u8, count * 4);
    for (0..count) |at| {
        for (pictures, fallbacks, 0..) |found, fallback, channel| {
            rgba[at * 4 + channel] = if (found) |part| part.rgba[at * 4] else fallback;
        }
        rgba[at * 4 + 3] = std.math.maxInt(u8);
    }
    return try srtexture.mipmaps(gpa, .{ .width = whole[0], .height = whole[1], .rgba = rgba }, .data, longest);
}

/// Makes `made` fit the device: compresses it where `compressor` takes compressed textures, and
/// leaves out what it can't draw. Returns whether anything was compressed, or null where the
/// picture itself can't be drawn, which the log says.
fn conform(gpa: Allocator, made: *Image, read: *const Read, compressor: ?Compressor) Allocator.Error!?bool {
    const name = read.picture.?.name;
    const format = made.levels[0].format;
    const compressing = if (compressor) |held| held.compresses() else false;
    if (format.compressed() and !(if (compressor) |held| held.takes.contains(format) else false)) {
        log.warn("{s} is left out: it is compressed in {t}, which the device doesn't take", .{ name, format });
        return null;
    }
    // What the maps must be: compressed beside a compressed picture, and as they are otherwise.
    const compressed = format.compressed() or compressing;
    const normal_format: Level.Format = if (compressed) Compressor.Kind.normals.format() else .rgba8;
    const orm_format: Level.Format = if (compressed) Compressor.Kind.data.format() else .rgba8;
    const emissive_format: Level.Format = if (compressed) Compressor.Kind.colour.format() else .rgba8;
    leaveOut(gpa, &made.maps.normal, normal_format, compressing, name, .normal);
    leaveOut(gpa, &made.maps.orm, orm_format, compressing, name, .orm);
    leaveOut(gpa, &made.maps.emissive, emissive_format, compressing, name, .emissive);
    if (!compressing) return false;
    // The length of the normals' mean goes to the material map's alpha, as BC5 keeps two channels.
    if (made.maps.normal) |normals| if (made.maps.orm) |orm| if (normals[0].format == .rgba8 and orm[0].format == .rgba8) {
        for (normals, orm) |normal, values| {
            const into: []u8 = @constCast(values.texels);
            for (0..@as(usize, normal.width) * normal.height) |at| into[at * 4 + 3] = normal.texels[at * 4 + 3];
        }
    };
    const held = compressor.?;
    var any = false;
    any = try compressLevels(gpa, held, &made.levels, .colour) or any;
    if (made.maps.normal) |*levels| any = try compressLevels(gpa, held, levels, .normals) or any;
    if (made.maps.orm) |*levels| any = try compressLevels(gpa, held, levels, .data) or any;
    if (made.maps.emissive) |*levels| any = try compressLevels(gpa, held, levels, .colour) or any;
    return any;
}

/// Leaves out the map `levels` where it isn't of `wanted`, and can't be compressed into it: a map
/// in 8-bit RGBA can be, while `compressing`.
fn leaveOut(gpa: Allocator, levels: *?[]const Level, wanted: Level.Format, compressing: bool, name: []const u8, map: MapFile) void {
    const found = levels.* orelse return;
    const format = found[0].format;
    if (format == wanted or (format == .rgba8 and compressing)) return;
    log.warn("the {s} of {s} is left out: it is in {t}, and goes with a picture in {t}", .{ map.label(), name, format, wanted });
    freeLevels(gpa, found);
    levels.* = null;
}

/// Compresses `levels` as `kind`, where they are 8-bit RGBA. Returns whether it did.
fn compressLevels(gpa: Allocator, compressor: Compressor, levels: *[]const Level, kind: Compressor.Kind) Allocator.Error!bool {
    if (levels.*[0].format != .rgba8) return false;
    const made = try gpa.alloc(Level, levels.len);
    var done: usize = 0;
    errdefer {
        for (made[0..done]) |level| gpa.free(level.texels);
        gpa.free(made);
    }
    for (levels.*, made) |level, *into| {
        into.* = try compressor.compress(gpa, level, kind);
        done += 1;
    }
    freeLevels(gpa, levels.*);
    levels.* = made;
    return true;
}

const freeLevels = srtexture.freeLevels;

/// A PNG file `side` pixels square, every pixel `rgba`, for the tests.
fn testPng(gpa: Allocator, side: u32, rgba: [4]u8) ![]u8 {
    const pixels = try gpa.alloc(u8, @as(usize, side) * side * 4);
    defer gpa.free(pixels);
    for (0..@as(usize, side) * side) |at| pixels[at * 4 ..][0..4].* = rgba;
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();
    try png.writeRgba(gpa, &written.writer, side, side, pixels);
    return gpa.dupe(u8, written.written());
}

/// A compressor for the tests: it "compresses" a level into blocks of its first byte, notes the
/// alpha of each material map's first pixel as it takes it, and keeps one picture, which it gives
/// back for the same name and key alone.
const TestCompressor = struct {
    takes: std.EnumSet(Level.Format) = .initMany(&.{ .bc5, .bc7 }),
    compressed: usize = 0,
    material_alpha: ?u8 = null,
    kept: ?Image = null,
    kept_name: [16]u8 = undefined,
    kept_name_len: usize = 0,
    kept_key: Compressor.Key = 0,
    loads: usize = 0,

    fn compressor(held: *TestCompressor) Compressor {
        return .{ .context = held, .vtable = &.{ .compress = compress, .load = loadKept, .store = store }, .takes = held.takes };
    }

    fn from(context: *anyopaque) *TestCompressor {
        return @ptrCast(@alignCast(context));
    }

    fn compress(context: *anyopaque, gpa: Allocator, level: Level, kind: Compressor.Kind) Allocator.Error!Level {
        const held = from(context);
        held.compressed += 1;
        if (kind == .data and held.material_alpha == null) held.material_alpha = level.texels[3];
        const format = kind.format();
        const out = try gpa.alloc(u8, format.size(level.width, level.height));
        @memset(out, level.texels[0]);
        return .{ .width = level.width, .height = level.height, .format = format, .texels = out };
    }

    fn loadKept(context: *anyopaque, gpa: Allocator, name: []const u8, key: *const Compressor.Key) Allocator.Error!?Image {
        const held = from(context);
        held.loads += 1;
        const kept = held.kept orelse return null;
        if (!std.mem.eql(u8, name, held.kept_name[0..held.kept_name_len]) or key.* != held.kept_key) return null;
        var maps: [Image.Maps.count]?[]const Level = @splat(null);
        for (kept.maps.list(), &maps) |kept_map, *map| map.* = if (kept_map) |levels| try copy(gpa, levels) else null;
        return .{ .levels = try copy(gpa, kept.levels), .maps = .fromList(maps) };
    }

    fn store(context: *anyopaque, name: []const u8, key: *const Compressor.Key, image: Image) void {
        const held = from(context);
        if (held.kept) |kept| kept.deinit(std.testing.allocator);
        @memcpy(held.kept_name[0..name.len], name);
        held.kept_name_len = name.len;
        held.kept_key = key.*;
        var maps: [Image.Maps.count]?[]const Level = @splat(null);
        for (image.maps.list(), &maps) |given, *map| map.* = if (given) |levels| copy(std.testing.allocator, levels) catch null else null;
        held.kept = .{ .levels = copy(std.testing.allocator, image.levels) catch return, .maps = .fromList(maps) };
    }

    fn copy(gpa: Allocator, levels: []const Level) Allocator.Error![]const Level {
        const made = try gpa.alloc(Level, levels.len);
        for (made, levels) |*into, level| into.* = .{ .width = level.width, .height = level.height, .format = level.format, .texels = try gpa.dupe(u8, level.texels) };
        return made;
    }

    fn deinit(held: *TestCompressor) void {
        if (held.kept) |kept| kept.deinit(std.testing.allocator);
    }
};

test "a picture and its maps are compressed for the device, and kept for the next run" {
    const gpa = std.testing.allocator;
    const picture = try testPng(gpa, 4, .{ 200, 100, 50, 255 });
    defer gpa.free(picture);
    const normal = try testPng(gpa, 4, .{ 128, 128, 255, 255 });
    defer gpa.free(normal);
    const roughness = try testPng(gpa, 4, .{ 64, 64, 64, 255 });
    defer gpa.free(roughness);
    const emissive = try testPng(gpa, 4, .{ 255, 160, 0, 255 });
    defer gpa.free(emissive);
    const pictures: srtexture.testing.Pictures = .{ .held = &.{
        .{ .name = "hull.png", .bytes = picture },
        .{ .name = "hull_normal.png", .bytes = normal },
        .{ .name = "hull_roughness.png", .bytes = roughness },
        .{ .name = "hull_emissive.png", .bytes = emissive },
    } };
    var compressor: TestCompressor = .{};
    defer compressor.deinit();
    const made = (try load(gpa, pictures.files(), "hull", srtexture.max_side, compressor.compressor(), null)).?;
    defer made.deinit(gpa);
    try std.testing.expectEqual(Level.Format.bc7, made.levels[0].format);
    try std.testing.expectEqual(Level.Format.bc5, made.maps.normal.?[0].format);
    try std.testing.expectEqual(Level.Format.bc7, made.maps.orm.?[0].format);
    try std.testing.expectEqual(Level.Format.bc7, made.maps.emissive.?[0].format);
    // Three levels of each of the four, the normals' mean length in the material map's alpha:
    // 255 at the finest level, where each normal stands for itself.
    try std.testing.expectEqual(12, compressor.compressed);
    try std.testing.expectEqual(255, compressor.material_alpha.?);
    // The next run reads what was kept, and compresses nothing.
    const again = (try load(gpa, pictures.files(), "hull", srtexture.max_side, compressor.compressor(), null)).?;
    defer again.deinit(gpa);
    try std.testing.expectEqual(12, compressor.compressed);
    try std.testing.expectEqualSlices(u8, made.maps.emissive.?[0].texels, again.maps.emissive.?[0].texels);
    try std.testing.expectEqual(2, compressor.loads);
    try std.testing.expectEqualSlices(u8, made.levels[0].texels, again.levels[0].texels);
}

test "a copy of a picture is tinted, and kept apart from the picture" {
    const gpa = std.testing.allocator;
    const picture = try testPng(gpa, 4, .{ 200, 100, 50, 255 });
    defer gpa.free(picture);
    const pictures: srtexture.testing.Pictures = .{ .held = &.{
        .{ .name = "hull.png", .bytes = picture },
        .{ .name = "hull_emissive.png", .bytes = picture },
    } };
    var compressor: TestCompressor = .{};
    defer compressor.deinit();
    const plain = (try load(gpa, pictures.files(), "hull", srtexture.max_side, compressor.compressor(), null)).?;
    defer plain.deinit(gpa);
    try std.testing.expect(plain.maps.emissive != null);
    // The test compressor keeps the first byte, the red: a picture of one colour is at the top of
    // its range, so its green copy has the little red of full green.
    const green = (try load(gpa, pictures.files(), "hull", srtexture.max_side, compressor.compressor(), .green)).?;
    defer green.deinit(gpa);
    try std.testing.expectEqual(200, plain.levels[0].texels[0]);
    try std.testing.expectEqual(23, green.levels[0].texels[0]);
    // The copy has no emissive map, whose own colours would show through it.
    try std.testing.expectEqual(null, green.maps.emissive);
    // It is kept under its own name, and read back from there.
    try std.testing.expectEqualStrings("ghull", compressor.kept_name[0..compressor.kept_name_len]);
    const again = (try load(gpa, pictures.files(), "hull", srtexture.max_side, compressor.compressor(), .green)).?;
    defer again.deinit(gpa);
    try std.testing.expectEqual(9, compressor.compressed);
}

test "a DDS picture draws as it is where the device takes its format, and not otherwise" {
    const gpa = std.testing.allocator;
    var data: [16 + 16 + 16]u8 = @splat(9);
    const file = try dds.testing.file(gpa, "DX10", 98, 4, 4, 3, &data);
    defer gpa.free(file);
    const normal = try testPng(gpa, 4, .{ 128, 128, 255, 255 });
    defer gpa.free(normal);
    const pictures: srtexture.testing.Pictures = .{ .held = &.{
        .{ .name = "hull.dds", .bytes = file },
        .{ .name = "hull.png", .bytes = normal },
        .{ .name = "hull_normal.png", .bytes = normal },
    } };
    // The DDS file comes before the PNG; its levels are kept as they are, and the normal map is
    // compressed to go with them.
    var compressor: TestCompressor = .{};
    defer compressor.deinit();
    const made = (try load(gpa, pictures.files(), "hull", srtexture.max_side, compressor.compressor(), null)).?;
    defer made.deinit(gpa);
    try std.testing.expectEqual(Level.Format.bc7, made.levels[0].format);
    try std.testing.expectEqualSlices(u8, data[0..16], made.levels[0].texels);
    try std.testing.expectEqual(Level.Format.bc5, made.maps.normal.?[0].format);
    // Without a device that takes BC7, the picture is left out.
    try std.testing.expectEqual(null, try load(gpa, pictures.files(), "hull", srtexture.max_side, null, null));
}

test "a KTX2 picture of one level is mipmapped, and its finest levels go past the longest side" {
    const gpa = std.testing.allocator;
    var pixels: [8 * 8 * 4]u8 = @splat(200);
    const file = try ktx2.testing.file(gpa, 37, 8, 8, &.{&pixels});
    defer gpa.free(file);
    const pictures: srtexture.testing.Pictures = .{ .held = &.{.{ .name = "hull.ktx2", .bytes = file }} };
    const made = (try load(gpa, pictures.files(), "hull", 4, null, null)).?;
    defer made.deinit(gpa);
    try std.testing.expectEqual(4, made.width());
    try std.testing.expectEqual(3, made.levels.len);
    try std.testing.expectEqual(Level.Format.rgba8, made.levels[0].format);
}
