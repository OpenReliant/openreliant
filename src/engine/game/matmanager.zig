//! `C:\lancer\game\matmanager.cpp`: the game's side of looking up textures, and the picture shown
//! behind a frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const png = @import("../../formats/png.zig");
const tga = @import("../../formats/tga.zig");
const files = @import("../files.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const bigfile = @import("bigfile.zig");

const log = std.log.scoped(.matmanager);

pub const Error = Allocator.Error || error{ImageMissing};

/// The texture of that name, which must exist (`texture_require`, `0x00494A30`): on a miss the game
/// stops with `Could not find image %s`, and this logs that and fails.
pub fn textureRequire(table: *srtexture.Table, name: []const u8) Error!*srtexture.Image {
    return try table.find(name) orelse {
        log.err("Could not find image {s}", .{name});
        return error.ImageMissing;
    };
}

/// The picture the device shows behind a frame: `background_set` (`0x00494B50`) names it, and
/// `background_load` (`0x00494A70`) reads it from the archive as a TGA and hands it to the device
/// (`sr + 0x50`), which draws it behind the frame (`srd3d.backgroundEdges`). The front end's screens
/// show one, and so do the loading screens.
pub const Background = struct {
    /// Its name (`0x00588744`), which a new name must differ from, case aside, to load again.
    name_buffer: [name_room]u8 = undefined,
    name_len: usize = 0,
    image: ?srtexture.Image = null,

    pub const name_room = 0x100;

    pub fn name(background: *const Background) []const u8 {
        return background.name_buffer[0..background.name_len];
    }

    /// `background_set`: shows the picture of `picture_name`, read from `archive` (`readImage`),
    /// unless it is the one shown already, case aside.
    pub fn set(background: *Background, gpa: Allocator, archive: bigfile.Hog, picture_name: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(picture_name, background.name())) return;
        if (picture_name.len > name_room) return error.NameTooLong;
        const image = try readImage(gpa, archive, picture_name);
        background.deinit(gpa);
        background.image = image;
        @memcpy(background.name_buffer[0..picture_name.len], picture_name);
        background.name_len = picture_name.len;
    }

    /// `set`, as a screen shows its picture: one that can't be read is left out, which the log
    /// says, and the picture shown stays.
    pub fn show(background: *Background, gpa: Allocator, archive: bigfile.Hog, picture_name: []const u8) void {
        background.set(gpa, archive, picture_name) catch |err|
            log.warn("{s} is left out: {s}", .{ picture_name, @errorName(err) });
    }

    /// Shows nothing, the device's clear colour behind the frame.
    pub fn deinit(background: *Background, gpa: Allocator) void {
        if (background.image) |shown| shown.deinit(gpa);
        background.image = null;
        background.name_len = 0;
    }
};

/// Reads the game's TGA picture `picture_name` from `archive` as an opaque image (`picture`), or
/// the mod picture that replaces it (`pictureName`), at any size, also opaque, with its mipmaps
/// generated.
///
/// **Improvement:** the original only reads the TGA.
pub fn readImage(gpa: Allocator, archive: bigfile.Hog, picture_name: []const u8) !srtexture.Image {
    if (try modPicture(gpa, archive, picture_name)) |read| {
        var alpha: usize = 3;
        while (alpha < read.rgba.len) : (alpha += 4) read.rgba[alpha] = std.math.maxInt(u8);
        return srtexture.mipmapped(gpa, read);
    }
    const decoded = try readTga(gpa, archive, picture_name);
    defer decoded.deinit(gpa);
    return picture(gpa, decoded);
}

/// Reads and decodes the game's TGA picture `picture_name` from `archive` for its pixels, or the
/// mod picture that replaces it (`pictureName`), without its alpha channel, if it has the same
/// size. A mod picture of a different size is skipped, which the log says.
///
/// **Improvement:** the original only reads the TGA.
pub fn readPixels(gpa: Allocator, archive: bigfile.Hog, picture_name: []const u8) !tga.Image {
    const own = try readTga(gpa, archive, picture_name);
    errdefer own.deinit(gpa);
    const read = try modPicture(gpa, archive, picture_name) orelse return own;
    defer read.deinit(gpa);
    if (read.width != own.width or read.height != own.height) {
        log.warn("skipping the picture that replaces {s}: it's {d}x{d}, and the original is {d}x{d}", .{ picture_name, read.width, read.height, own.width, own.height });
        return own;
    }
    for (0..@as(usize, own.width) * own.height) |at| own.rgb[at * 3 ..][0..3].* = read.rgba[at * 4 ..][0..3].*;
    return own;
}

/// Reads and decodes the game's TGA picture `picture_name` from `archive` (`tga.decode`).
fn readTga(gpa: Allocator, archive: bigfile.Hog, picture_name: []const u8) !tga.Image {
    const bytes = try archive.readFile(gpa, picture_name);
    defer gpa.free(bytes);
    return tga.decode(gpa, bytes);
}

/// The mod picture that replaces the game's picture `picture_name` (`pictureName`), from
/// `archive`'s mods; null if there's none.
fn modPicture(gpa: Allocator, archive: bigfile.Hog, picture_name: []const u8) Allocator.Error!?png.Picture {
    var buffer: [files.max_path]u8 = undefined;
    const name = pictureName(&buffer, picture_name) catch return null;
    return archive.mods.pictures().picture(gpa, name);
}

/// The name of the mod picture that replaces the game's picture `picture_name`: the name the
/// archive looks it up by (`bigfile.memberName`), with the picture extension instead of the
/// original one.
pub fn pictureName(buffer: []u8, picture_name: []const u8) error{NoSpaceLeft}![]u8 {
    var looked_up: [bigfile.member_name_room]u8 = undefined;
    const member = bigfile.memberName(&looked_up, picture_name);
    const stem = member[0 .. member.len - std.fs.path.extension(member).len];
    return std.fmt.bufPrint(buffer, "{s}" ++ srtexture.picture_extension, .{stem});
}

/// A picture of the game's in the tests, two pixels by one: blue, then green.
const tested_tga = [_]u8{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 24, 0 } ++ [_]u8{ 0xFF, 0, 0, 0, 0xFF, 0 };

test Background {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try bigfile.testing.write(gpa, io, tmp.dir, bigfile.resource_name, &.{
        .{ .name = "back.tga", .data = &tested_tga },
        .{ .name = "broken.tga", .data = "x" },
    });
    var archive: bigfile.Hog = try .open(gpa, io, tmp.dir, bigfile.resource_name);
    defer archive.close(gpa);
    var background: Background = .{};
    defer background.deinit(gpa);
    background.show(gpa, archive, "interface\\back.tga");
    try std.testing.expectEqualStrings("interface\\back.tga", background.name());
    // A picture that can't be read is left out, and the one shown stays.
    background.show(gpa, archive, "interface\\broken.tga");
    try std.testing.expectEqualStrings("interface\\back.tga", background.name());
    try std.testing.expectEqual(2, background.image.?.width());
}

test "a mod's picture replaces one of the game's pictures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Two of the game's pictures.
    try bigfile.testing.write(gpa, io, tmp.dir, bigfile.resource_name, &.{
        .{ .name = "back.tga", .data = &tested_tga },
        .{ .name = "dome.tga", .data = &tested_tga },
    });
    var archive: bigfile.Hog = try .open(gpa, io, tmp.dir, bigfile.resource_name);
    defer archive.close(gpa);
    const shown = try readImage(gpa, archive, "interface\\back.tga");
    defer shown.deinit(gpa);
    try std.testing.expectEqual(2, shown.width());
    try std.testing.expectEqual(1, shown.levels.len);

    // Mod pictures to replace them, with names in a different case: one 4x2 and half transparent,
    // the other red and white.
    var back: std.Io.Writer.Allocating = .init(gpa);
    defer back.deinit();
    try png.writeRgba(gpa, &back.writer, 4, 2, &(@as([4 * 2 * 4]u8, @splat(0x80))));
    var dome: std.Io.Writer.Allocating = .init(gpa);
    defer dome.deinit();
    try png.writeRgba(gpa, &dome.writer, 2, 1, &.{ 0xFF, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try tmp.dir.createDirPath(io, "mods/pictures");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/pictures/BACK.png", .data = back.written() });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/pictures/dome.png", .data = dome.written() });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    archive.mods = &mods;

    // As an image, at any size: opaque, like the original pictures, with its mipmaps generated.
    const modded = try readImage(gpa, archive, "interface\\back.tga");
    defer modded.deinit(gpa);
    try std.testing.expectEqual(4, modded.width());
    try std.testing.expectEqual(3, modded.levels.len);
    try std.testing.expectEqual(std.math.maxInt(u8), modded.levels[0].rgba[3]);
    // For its pixels, only at the original size.
    const colours = try readPixels(gpa, archive, "dome.tga");
    defer colours.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0, 0, 0xFF, 0xFF, 0xFF }, colours.rgb);
    const kept = try readPixels(gpa, archive, "back.tga");
    defer kept.deinit(gpa);
    try std.testing.expectEqual([3]u8{ 0, 0, 0xFF }, kept.pixel(0, 0));
}

test pictureName {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("optfade.png", try pictureName(&buffer, "interface\\optfade.tga"));
    try std.testing.expectEqualStrings("bg_splash.png", try pictureName(&buffer, "bg_splash.TGA"));
    try std.testing.expectError(error.NoSpaceLeft, pictureName(buffer[0..4], "bg_splash.TGA"));
}

/// An image of `decoded`'s pixels, opaque.
pub fn picture(gpa: Allocator, decoded: tga.Image) Allocator.Error!srtexture.Image {
    const pixels = @as(usize, decoded.width) * decoded.height;
    const rgba = try gpa.alloc(u8, pixels * 4);
    errdefer gpa.free(rgba);
    for (0..pixels) |at| {
        rgba[at * 4 ..][0..3].* = decoded.rgb[at * 3 ..][0..3].*;
        rgba[at * 4 + 3] = 0xFF;
    }
    return srtexture.Image.single(gpa, decoded.width, decoded.height, rgba);
}

test picture {
    const gpa = std.testing.allocator;
    var rgb = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const image = try picture(gpa, .{ .width = 2, .height = 1, .rgb = &rgb });
    defer image.deinit(gpa);
    try std.testing.expectEqual(2, image.width());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0xFF, 4, 5, 6, 0xFF }, image.levels[0].rgba);
}
