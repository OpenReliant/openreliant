//! `screenshot_save` (`0x004ADC20`): the screen saved as a picture, as the 0 key asks in flight
//! (`mission_frame`, `0x00493480`) and in the locker (`medal_display`, `0x004368B4`), and O in the
//! briefing (`0x004375F1`) and the loadout (`0x0043787E`, `0x00443689`). The game grabs the screen
//! (`sr + 0x7C`), names it `screenshot%04d.tga` (`screenshot_name_format`, `0x0050A940`) by
//! `screenshot_count` (`0x005D6CA8`), which counts from 0 each run, and writes it in its directory
//! (`tga_write`, `0x004CA620`).
//!
//! **Unverified:** that it is `xtrabits.cpp`'s. It lies past the last code the file's assertions
//! place, between `scene_add` and `object_random15`.
//!
//! **Improvement:** each screenshot is a PNG, in the `screenshots` folder of the game's directory.
//! `--original` keeps them so: they change nothing of the game's look or sound.
//!
//! **Fix:** the numbers go on past the screenshots the folder already holds. The game counts from 0
//! each run, and writes over the last run's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const png = @import("../../../formats/png.zig");

const log = std.log.scoped(.screenshot);

/// The folder of the game's directory the screenshots go in.
pub const folder = "screenshots";

/// A screenshot's name: the game's, `screenshot%04d.tga`, as a PNG.
const name_format = "screenshot{d:0>4}.png";

/// The most bytes a screenshot's name takes.
pub const name_size = std.fmt.count(name_format, .{std.math.maxInt(u32)});

/// The name of screenshot `number`, written into `buffer`.
pub fn name(buffer: *[name_size]u8, number: u32) []const u8 {
    return std.fmt.bufPrint(buffer, name_format, .{number}) catch unreachable;
}

/// A frame to save: rows of red, green, blue and alpha from the top, `size` pixels across and down.
pub const Picture = struct {
    rgba: []const u8,
    size: [2]u32,
};

/// The screenshots of a run, as `screenshot_save` saves them.
pub const Screenshots = struct {
    io: Io,
    /// The game's directory, whose `folder` they go in.
    directory: Io.Dir,
    /// The number the next one is tried at (`screenshot_count`).
    next: u32 = 0,
    /// The screenshots being written, each a task of its own, so that the game goes on meanwhile.
    writing: Io.Group = .init,

    /// Saves `picture`, whose pixels `gpa` holds and which it frees, as the next screenshot: under
    /// the next number no file of the folder has, the folder made first where there is none. The
    /// file is written as a task of its own, which says where once it is done.
    pub fn save(screenshots: *Screenshots, gpa: Allocator, picture: Picture) !void {
        errdefer gpa.free(picture.rgba);
        const io = screenshots.io;
        var dir = try screenshots.directory.createDirPathOpen(io, folder, .{});
        defer dir.close(io);
        var buffer: [name_size]u8 = undefined;
        const file, const number = while (true) {
            const number = screenshots.next;
            screenshots.next +%= 1;
            const file = dir.createFile(io, name(&buffer, number), .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => |e| return e,
            };
            break .{ file, number };
        };
        screenshots.writing.async(io, write, .{ io, gpa, file, number, picture });
    }

    /// Waits for the screenshots still being written.
    pub fn finish(screenshots: *Screenshots) void {
        screenshots.writing.await(screenshots.io) catch {};
    }

    /// Writes `picture` into `file`, screenshot `number`, as a PNG, then closes the one and frees
    /// the other.
    fn write(io: Io, gpa: Allocator, file: Io.File, number: u32, picture: Picture) void {
        defer gpa.free(picture.rgba);
        defer file.close(io);
        var buffer: [name_size]u8 = undefined;
        const saved = name(&buffer, number);
        var bytes: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &bytes);
        png.writeRgba(gpa, &writer.interface, picture.size[0], picture.size[1], picture.rgba) catch |err|
            return log.err("{s} can't be written: {s}", .{ saved, @errorName(err) });
        writer.interface.flush() catch |err| return log.err("{s} can't be written: {s}", .{ saved, @errorName(err) });
        log.info("saved {s}/{s}", .{ folder, saved });
    }
};

test name {
    var buffer: [name_size]u8 = undefined;
    try std.testing.expectEqualStrings("screenshot0000.png", name(&buffer, 0));
    try std.testing.expectEqualStrings("screenshot0042.png", name(&buffer, 42));
    try std.testing.expectEqualStrings("screenshot12345.png", name(&buffer, 12345));
    try std.testing.expectEqual(name_size, name(&buffer, std.math.maxInt(u32)).len);
}

test Screenshots {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const red_and_green = [_]u8{ 0xFF, 0, 0, 0xFF, 0, 0xFF, 0, 0xFF };

    // The first goes in a new folder, as screenshot 0.
    var screenshots: Screenshots = .{ .io = io, .directory = tmp.dir };
    try screenshots.save(gpa, .{ .rgba = try gpa.dupe(u8, &red_and_green), .size = .{ 2, 1 } });
    screenshots.finish();
    const saved = try tmp.dir.readFileAlloc(io, folder ++ "/screenshot0000.png", gpa, .unlimited);
    defer gpa.free(saved);
    try std.testing.expectEqualSlices(u8, png.signature, saved[0..png.signature.len]);

    // A run after it passes over the numbers taken, where the game would write over them.
    var again: Screenshots = .{ .io = io, .directory = tmp.dir };
    try tmp.dir.writeFile(io, .{ .sub_path = folder ++ "/screenshot0001.png", .data = "earlier" });
    for (0..2) |_| try again.save(gpa, .{ .rgba = try gpa.dupe(u8, &red_and_green), .size = .{ 2, 1 } });
    again.finish();
    try std.testing.expectEqual(4, again.next);
    const earlier = try tmp.dir.readFileAlloc(io, folder ++ "/screenshot0001.png", gpa, .unlimited);
    defer gpa.free(earlier);
    try std.testing.expectEqualStrings("earlier", earlier);
    for ([_][]const u8{ "screenshot0002.png", "screenshot0003.png" }) |taken| {
        var buffer: [folder.len + 1 + name_size]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ folder, taken });
        const file = try tmp.dir.readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(file);
        try std.testing.expectEqualSlices(u8, png.signature, file[0..png.signature.len]);
    }
}
