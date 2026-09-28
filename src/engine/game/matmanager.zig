//! `C:\lancer\game\matmanager.cpp`: the game's side of looking up textures, and the picture shown
//! behind a frame.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tga = @import("../../formats/tga.zig");
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
/// (`sr + 0x50`). The front end's screens show one, and so do the loading screens.
pub const Background = struct {
    /// Its name (`0x00588744`), which a new name must differ from, case aside, to load again.
    name_buffer: [name_room]u8 = undefined,
    name_len: usize = 0,
    image: ?srtexture.Image = null,

    pub const name_room = 0x100;

    pub fn name(background: *const Background) []const u8 {
        return background.name_buffer[0..background.name_len];
    }

    /// `background_set`: shows the picture of `picture_name`, read from `archive`, unless it is
    /// the one shown already, case aside.
    pub fn set(background: *Background, gpa: Allocator, archive: bigfile.Hog, picture_name: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(picture_name, background.name())) return;
        if (picture_name.len > name_room) return error.NameTooLong;
        const bytes = try archive.readFile(gpa, picture_name);
        defer gpa.free(bytes);
        const decoded = try tga.decode(gpa, bytes);
        defer decoded.deinit(gpa);
        const image = try picture(gpa, decoded);
        background.deinit(gpa);
        background.image = image;
        @memcpy(background.name_buffer[0..picture_name.len], picture_name);
        background.name_len = picture_name.len;
    }

    /// Shows nothing, the device's clear colour behind the frame.
    pub fn deinit(background: *Background, gpa: Allocator) void {
        if (background.image) |shown| shown.deinit(gpa);
        background.image = null;
        background.name_len = 0;
    }
};

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
