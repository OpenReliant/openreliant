//! `C:\lancer\game\bigfile.cpp`: the `.HOG` archives the game reads its files from. `WinMain`
//! opens `resource.hog` at startup, and `msspeech.hog` for the HUD's speech. The CD archives are
//! opened when the game needs what they hold ([`interface/disc.zig`](interface/disc.zig)).
//! OpenReliant's mods ([`bigfile/mods.zig`](bigfile/mods.zig)) take priority over all of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hog = @import("../../formats/hog.zig");
const layout = @import("../../formats/layout.zig");
const refpack = @import("../../formats/refpack.zig");

pub const mods = @import("bigfile/mods.zig");
pub const Mods = mods.Mods;

const log = std.log.scoped(.bigfile);

/// The archive `WinMain` opens at startup, in the game folder.
pub const resource_name = "resource.hog";

pub const ReadError = Allocator.Error || Io.File.ReadPositionalError || Io.Dir.ReadFileAllocError || refpack.Error || error{
    /// A name that isn't in the archive: the game stops with `HOG bigread2: error loading %s`.
    FileMissing,
    UnexpectedEnd,
};

/// An open archive (`hog_open`, `0x004C7E20`): its file and its directory.
pub const Hog = struct {
    archive: hog.Archive,
    /// Added by OpenReliant: the mods, which are searched before the archive (`Mods`) and outlive
    /// it.
    mods: *const Mods = &Mods.none,

    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Hog {
        return .{ .archive = try .open(gpa, io, dir, path) };
    }

    /// `hog_close` (`0x004C7F20`).
    pub fn close(archive: *Hog, gpa: Allocator) void {
        archive.archive.close(gpa);
    }

    /// Whether a mod or the archive has the member for `name`, looked up as `readFile` does.
    pub fn has(archive: Hog, name: []const u8) bool {
        var buffer: [member_name_room]u8 = undefined;
        const member = memberName(&buffer, name);
        return archive.mods.has(member) or archive.archive.find(member) != null;
    }

    /// Reads the member for `name`, decompressing RefPack data (`hog_read_file`, `0x004C7F60`).
    /// The game looks it up by `memberName`, ignoring case (`hog_seek`, `0x004C8370`), and treats
    /// it as compressed when it starts with `10 FB`. A mod file with the same name takes priority
    /// (`Mods.readFile`).
    pub fn readFile(archive: Hog, gpa: Allocator, name: []const u8) ReadError![]u8 {
        var buffer: [member_name_room]u8 = undefined;
        const member = memberName(&buffer, name);
        if (try archive.mods.readFile(gpa, member)) |bytes| return bytes;
        const entry = archive.archive.find(member) orelse {
            log.err("HOG bigread2: error loading {s}", .{member});
            return error.FileMissing;
        };
        return readMember(archive.archive, gpa, entry);
    }

    /// Reads the member for `name` as stored. Bink opens it in place in the archive
    /// (`BINKFILEHANDLE`) after `hog_locate` (`0x004C83F0`) finds it by its full name, ignoring
    /// case. A mod file with the same name takes priority (`Mods.readStored`). Null if neither has
    /// it.
    pub fn readStored(archive: Hog, gpa: Allocator, name: []const u8) ReadError!?[]u8 {
        if (try archive.mods.readStored(gpa, name)) |bytes| return bytes;
        const entry = archive.archive.find(name) orelse return null;
        return try archive.archive.readRaw(gpa, entry);
    }
};

/// Reads the member `entry` of `archive`, decompressing it if it starts with `10 FB`, as
/// `hog_read_file` (`0x004C7F60`) does.
pub fn readMember(archive: hog.Archive, gpa: Allocator, entry: hog.Entry) ReadError![]u8 {
    const raw = try archive.readRaw(gpa, entry);
    if (!refpack.gameExpands(raw)) return raw;
    defer gpa.free(raw);
    return refpack.decompressAlloc(gpa, raw);
}

/// The buffer size `hog_read_file` (`0x004C7F60`) has for the lookup name. Longer names are cut to
/// this length.
pub const member_name_room = 128;

/// The name `hog_read_file` looks a file up by: the part of `name` after its last `\`, without an
/// extension starting with `ut`, cut to `member_name_room`.
pub fn memberName(buffer: *[member_name_room]u8, name: []const u8) []const u8 {
    const length = @min(name.len, buffer.len);
    @memcpy(buffer[0..length], name[0..length]);
    var copy: []const u8 = buffer[0..length];
    if (std.mem.indexOfScalar(u8, copy, '.')) |dot| {
        if (std.mem.startsWith(u8, copy[dot + 1 ..], "ut")) copy = copy[0..dot];
    }
    if (std.mem.lastIndexOfScalar(u8, copy, '\\')) |slash| copy = copy[slash + 1 ..];
    return copy;
}

test memberName {
    var buffer: [member_name_room]u8 = undefined;
    try std.testing.expectEqualStrings("USLF_Prd.SHP", memberName(&buffer, "USLF_Prd.SHP"));
    try std.testing.expectEqualStrings("space.tga", memberName(&buffer, "nebula\\space.tga"));
    try std.testing.expectEqualStrings("intro", memberName(&buffer, "movies\\intro.utx"));
}

test Hog {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two members: `Ship.SHP`, which holds `hello`, and a movie.
    try testing.write(gpa, io, tmp.dir, resource_name, &.{
        .{ .name = "Ship.SHP", .data = "hello" },
        .{ .name = "R_H_TA.BIK", .data = "BIKf" },
    });

    var archive: Hog = try .open(gpa, io, tmp.dir, resource_name);
    defer archive.close(gpa);
    const contents = try archive.readFile(gpa, "models\\ship.shp");
    defer gpa.free(contents);
    try std.testing.expectEqualStrings("hello", contents);

    // `hog_locate` matches the full name, ignoring case.
    const movie = (try archive.readStored(gpa, "r_h_ta.bik")).?;
    defer gpa.free(movie);
    try std.testing.expectEqualStrings("BIKf", movie);
    try std.testing.expectEqual(null, try archive.readStored(gpa, "movies\\r_h_ta.bik"));
}

test "mods take priority over the archive" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.write(gpa, io, tmp.dir, resource_name, &.{
        .{ .name = "Ship.SHP", .data = "the game's ship" },
        .{ .name = "palette.tga", .data = "the game's palette" },
        .{ .name = "R_H_TA.BIK", .data = "the game's movie" },
    });
    // A mod with a compressed ship that replaces the game's, a movie, and a new ship.
    const ship = try refpack.compressAlloc(gpa, "a mod's ship, a mod's ship, a mod's ship");
    defer gpa.free(ship);
    try tmp.dir.createDirPath(io, mods.folder_name);
    try testing.write(gpa, io, tmp.dir, "mods/ships.hog", &.{
        .{ .name = "ship.shp", .data = ship },
        .{ .name = "r_h_ta.bik", .data = "a mod's movie" },
        .{ .name = "New.SHP", .data = "a new ship" },
    });
    var found: Mods = try .open(gpa, io, tmp.dir, null);
    defer found.close(gpa);
    var archive: Hog = try .open(gpa, io, tmp.dir, resource_name);
    defer archive.close(gpa);
    archive.mods = &found;

    // The mod's ship, found by the name `hog_read_file` looks up, and decompressed.
    const read = try archive.readFile(gpa, "models\\SHIP.shp");
    defer gpa.free(read);
    try std.testing.expectEqualStrings("a mod's ship, a mod's ship, a mod's ship", read);
    // The archive's file when no mod has one, and a file the mod adds.
    const palette = try archive.readFile(gpa, "palette.tga");
    defer gpa.free(palette);
    try std.testing.expectEqualStrings("the game's palette", palette);
    try std.testing.expect(archive.has("new.shp"));
    // As stored, by the full name.
    const movie = (try archive.readStored(gpa, "R_H_TA.bik")).?;
    defer gpa.free(movie);
    try std.testing.expectEqualStrings("a mod's movie", movie);
    try std.testing.expectEqual(null, try archive.readStored(gpa, "missing.bik"));
}

test {
    _ = mods;
}

pub const testing = hog.testing;
