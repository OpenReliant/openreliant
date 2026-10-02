//! The discs' archives, `CD1.HOG` and `CD2.HOG`, which hold the movies of the campaign's flights,
//! its briefings and the Reliant's rooms. `cd_hog_open` (`0x0042FE00`) opens the one a part of
//! the game needs as it comes to it, in place of the one open (`cd_hog`, `0x005202D4`).
//!
//! The game reads an archive from the disc in the drive (`cd_in_drive`, `0x004AC6C0`), asking for
//! the other disc where the drive holds the wrong one; or, in a full install (`full_install`,
//! `0x005D62C4`), from the installation's folder, where both archives lie (`cd1_folder`,
//! `0x005D6A28`; `cd2_folder`, `0x005D6928`). OpenReliant reads them as a full install does:
//! `openreliant install` copies both into the game's folder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const files = @import("../../files.zig");
const bigfile = @import("../bigfile.zig");

const log = std.log.scoped(.disc);

/// The discs, by the number the game names each archive by.
pub const Number = enum(u8) {
    one = 1,
    two = 2,

    /// The archive's name, `cd%d.hog` (`0x004E866C`).
    pub fn archiveName(number: Number) []const u8 {
        return switch (number) {
            inline else => |disc| std.fmt.comptimePrint("cd{d}.hog", .{@intFromEnum(disc)}),
        };
    }
};

/// The open CD archive (`cd_hog`).
pub const Disc = struct {
    gpa: Allocator,
    io: Io,
    /// The game folder, which has both CD archives in a full install.
    directory: Io.Dir,
    hog: ?bigfile.Hog = null,
    /// Added by OpenReliant: the mods, which take priority over the archive (`bigfile.Mods`).
    mods: *const bigfile.Mods = &bigfile.Mods.none,

    /// `cd_hog_open` (`0x0042FE00`) in a full install: opens the archive of disc `number`, found in
    /// the game folder ignoring case, and closes the one that was open (`hog_close`). If it can't
    /// be opened, the game stops with `Can't open HOG resource file %s`; OpenReliant carries on
    /// without it, and skips the movies in it.
    pub fn open(disc: *Disc, number: Number) void {
        disc.close();
        const name = number.archiveName();
        var buffer: [files.max_path]u8 = undefined;
        const path = files.find(disc.io, disc.directory, name, &buffer) orelse {
            log.warn("the game folder has no {s}; skipping the movies of disc {d}", .{ name, @intFromEnum(number) });
            return;
        };
        var opened = bigfile.Hog.open(disc.gpa, disc.io, disc.directory, path) catch |err| {
            log.warn("can't open {s}: {s}; skipping the movies of disc {d}", .{ path, @errorName(err), @intFromEnum(number) });
            return;
        };
        opened.mods = disc.mods;
        disc.hog = opened;
    }

    pub fn close(disc: *Disc) void {
        if (disc.hog) |*hog| hog.close(disc.gpa);
        disc.hog = null;
    }

    /// Reads the member `name` of the open archive as stored (`bigfile.Hog.readStored`), with a
    /// mod's file taking priority; null if neither has it.
    pub fn readStored(disc: Disc, gpa: Allocator, name: []const u8) bigfile.ReadError!?[]u8 {
        const hog = disc.hog orelse return disc.mods.readStored(gpa, name);
        return hog.readStored(gpa, name);
    }

    /// Reads the file that `name` names in the open archive, decompressing RefPack data
    /// (`hog_read_file` on `cd_hog`), with a mod's file taking priority; null if neither has it.
    pub fn readFile(disc: Disc, gpa: Allocator, name: []const u8) bigfile.ReadError!?[]u8 {
        const hog = disc.hog orelse {
            var buffer: [bigfile.member_name_room]u8 = undefined;
            return disc.mods.readFile(gpa, bigfile.memberName(&buffer, name));
        };
        if (!hog.has(name)) return null;
        return try hog.readFile(gpa, name);
    }
};

test Number {
    try std.testing.expectEqualStrings("cd1.hog", Number.one.archiveName());
    try std.testing.expectEqualStrings("cd2.hog", Number.two.archiveName());
}

test Disc {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // The installer names the second disc's archive as the disc does.
    try bigfile.testing.write(gpa, io, tmp.dir, "CD2.HOG", &.{.{ .name = "r_h_ta.bik", .data = "BIKf" }});

    var disc: Disc = .{ .gpa = gpa, .io = io, .directory = tmp.dir };
    defer disc.close();
    try std.testing.expectEqual(null, try disc.readStored(gpa, "r_h_ta.bik"));
    disc.open(.two);
    try std.testing.expect(disc.hog != null);
    const movie = (try disc.readStored(gpa, "R_H_TA.BIK")).?;
    defer gpa.free(movie);
    try std.testing.expectEqualStrings("BIKf", movie);
    try std.testing.expectEqual(null, try disc.readStored(gpa, "y_h_ta.bik"));
    const read = (try disc.readFile(gpa, "r_h_ta.bik")).?;
    defer gpa.free(read);
    try std.testing.expectEqualStrings("BIKf", read);
    try std.testing.expectEqual(null, try disc.readFile(gpa, "vrsnd.fat"));

    // The first disc's archive is missing: the second is closed all the same, and nothing is open.
    disc.open(.one);
    try std.testing.expectEqual(null, disc.hog);
}

test "a mod's movies replace the CD archives' movies" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try bigfile.testing.write(gpa, io, tmp.dir, "CD2.HOG", &.{
        .{ .name = "r_h_ta.bik", .data = "the disc's" },
        .{ .name = "r_h_tb.bik", .data = "the disc's other" },
    });
    try tmp.dir.createDirPath(io, "mods/hangar");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/hangar/R_H_TA.bik", .data = "a mod's" });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);

    var disc: Disc = .{ .gpa = gpa, .io = io, .directory = tmp.dir, .mods = &mods };
    defer disc.close();
    // The mod's movie, even with no archive open, and the archive's when no mod has one.
    for ([_]?Number{ null, .two }) |number| {
        if (number) |opened| disc.open(opened);
        const movie = (try disc.readStored(gpa, "r_h_ta.bik")).?;
        defer gpa.free(movie);
        try std.testing.expectEqualStrings("a mod's", movie);
        const read = (try disc.readFile(gpa, "R_H_TA.BIK")).?;
        defer gpa.free(read);
        try std.testing.expectEqualStrings("a mod's", read);
    }
    const other = (try disc.readStored(gpa, "r_h_tb.bik")).?;
    defer gpa.free(other);
    try std.testing.expectEqualStrings("the disc's other", other);
}
