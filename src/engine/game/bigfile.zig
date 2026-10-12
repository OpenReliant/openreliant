//! `C:\lancer\game\bigfile.cpp`: the `.HOG` archives the game reads its files from. `WinMain`
//! opens `resource.hog` at startup, and `msspeech.hog` for the HUD's speech. The CD archives are
//! opened when the game needs what they hold ([`interface/disc.zig`](interface/disc.zig)).
//! OpenReliant's mods ([`bigfile/mods.zig`](bigfile/mods.zig)) take priority over all of them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const files = @import("../files.zig");
const hog = @import("../../formats/hog.zig");
const layout = @import("../../formats/layout.zig");
const refpack = @import("../../formats/refpack.zig");

pub const catalogue = @import("bigfile/catalogue.zig");
pub const mods = @import("bigfile/mods.zig");
pub const order = @import("bigfile/order.zig");
pub const Mods = mods.Mods;

const log = std.log.scoped(.bigfile);

/// The archive `WinMain` opens at startup, in the game folder.
pub const resource_name = "resource.hog";

pub const ReadError = Allocator.Error || Io.File.ReadPositionalError || Io.Dir.ReadFileAllocError || refpack.Error || error{
    /// A name that isn't in the archive: the game stops with `HOG_bigread2: error loading %s.`
    /// (`0x00511BA4`).
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
        return .{ .archive = try openArchive(gpa, io, dir, path) };
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

    /// Reads the member for `name` (`hog_read_file`, `0x004C7F60`), looked up by `memberName` and
    /// read by `readNamed`. A mod file with the same name takes priority (`Mods.readFile`).
    pub fn readFile(archive: Hog, gpa: Allocator, name: []const u8) ReadError![]u8 {
        var buffer: [member_name_room]u8 = undefined;
        const member = memberName(&buffer, name);
        if (try archive.mods.readFile(gpa, member)) |bytes| return bytes;
        return try readNamed(archive.archive, gpa, member) orelse {
            log.err("HOG_bigread2: error loading {s}.", .{member});
            return error.FileMissing;
        };
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

/// `hog_open` (`0x004C7E20`): the archive at `path` under `dir`. The game opens it with `fopen` and
/// `CreateFileA`, so the name matches in any case, and `\` and `/` both split folders
/// (`files.find`).
pub fn openArchive(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !hog.Archive {
    var buffer: [files.max_path]u8 = undefined;
    const spelled = files.find(io, dir, path, &buffer) orelse return error.FileNotFound;
    return .open(gpa, io, dir, spelled);
}

/// Reads the member `member` of `archive`, a name `memberName` gave, as `hog_read_file`
/// (`0x004C7F60`) does: found in any case (`hog_seek`, `0x004C8370`) and expanded when it starts
/// with `10 FB` (`readMember`). Null if the archive doesn't have it.
pub fn readNamed(archive: hog.Archive, gpa: Allocator, member: []const u8) ReadError!?[]u8 {
    const entry = archive.find(member) orelse return null;
    return try readMember(archive, gpa, entry);
}

/// Reads the member `entry` of `archive`, decompressing it if it starts with `10 FB`, as
/// `hog_read_file` (`0x004C7F60`) does.
pub fn readMember(archive: hog.Archive, gpa: Allocator, entry: hog.Entry) ReadError![]u8 {
    return (try archive.read(gpa, entry)).bytes;
}

/// The buffer size `hog_read_file` (`0x004C7F60`) has for the lookup name. Longer names are cut to
/// this length.
pub const member_name_room = 128;

/// The start of the extension `hog_read_file` drops, compared with case (`0x00511B84`).
const dropped_extension = "ut";

/// The name `hog_read_file` (`0x004C7F60`) looks a file up by. It copies `name`, cuts it at its
/// first dot when `ut` follows (with case, so `.UT` stays), then keeps what follows the last
/// backslash after the first character. Only backslashes separate.
///
/// **Fix:** the game copies the name into a 128-byte buffer without a limit, so a longer name
/// overruns its stack. OpenReliant cuts it to `member_name_room` bytes.
pub fn memberName(buffer: *[member_name_room]u8, name: []const u8) []const u8 {
    const length = @min(name.len, buffer.len);
    @memcpy(buffer[0..length], name[0..length]);
    var copy: []const u8 = buffer[0..length];
    if (std.mem.findScalar(u8, copy, '.')) |dot| {
        if (std.mem.startsWith(u8, copy[dot + 1 ..], dropped_extension)) copy = copy[0..dot];
    }
    // The game scans back from the end down to the second character (`0x004C7FF0`).
    if (copy.len > 1) if (std.mem.findScalarLast(u8, copy[1..], '\\')) |at| {
        copy = copy[at + 2 ..];
    };
    return copy;
}

test memberName {
    var buffer: [member_name_room]u8 = undefined;
    try std.testing.expectEqualStrings("USLF_Prd.SHP", memberName(&buffer, "USLF_Prd.SHP"));
    try std.testing.expectEqualStrings("space.tga", memberName(&buffer, "nebula\\space.tga"));
    try std.testing.expectEqualStrings("intro", memberName(&buffer, "movies\\intro.utx"));
    try std.testing.expectEqualStrings("ms1_ban_001", memberName(&buffer, "ms_speech\\ms1_ban_001.ut"));
    // Only a lower-case `ut` right after the first dot is cut.
    try std.testing.expectEqualStrings("trnglnd_001.UT", memberName(&buffer, "trnglnd_001.UT"));
    try std.testing.expectEqualStrings("a.b.ut", memberName(&buffer, "a.b.ut"));
    try std.testing.expectEqualStrings("x", memberName(&buffer, "x.ut.wav"));
    // The cut comes before the folders are dropped, and only a backslash splits them.
    try std.testing.expectEqualStrings("name.ut", memberName(&buffer, "dir.x\\name.ut"));
    try std.testing.expectEqualStrings("dir", memberName(&buffer, "dir.ut\\name"));
    try std.testing.expectEqualStrings("a/b", memberName(&buffer, "a/b.ut"));
    // A backslash as the first character is never taken for a folder's.
    try std.testing.expectEqualStrings("\\abrt_001", memberName(&buffer, "\\abrt_001.ut"));
    // A long name is cut to the buffer.
    const long: [200]u8 = @splat('a');
    try std.testing.expectEqual(member_name_room, memberName(&buffer, &long).len);
}

test readNamed {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const plain = "hello hello hello hello hello hello";
    const packed_bytes = try refpack.compressAlloc(gpa, plain);
    defer gpa.free(packed_bytes);
    // `odd` starts as a RefPack stream with other flags, which the game reads as it is stored.
    try tmp.dir.createDirPath(io, "Pilots");
    try testing.write(gpa, io, tmp.dir, "Pilots/PILOTS.HOG", &.{
        .{ .name = "Ship.SHP", .data = "hello" },
        .{ .name = "packed", .data = packed_bytes },
        .{ .name = "odd", .data = "\x11\xFB\x00\x00\x05abc" },
    });
    // The archive is found in any case, with either separator.
    var archive = try openArchive(gpa, io, tmp.dir, "pilots\\pilots.hog");
    defer archive.close(gpa);
    var again = try openArchive(gpa, io, tmp.dir, "pilots/pilots.hog");
    again.close(gpa);

    const ship = (try readNamed(archive, gpa, "ship.shp")).?;
    defer gpa.free(ship);
    try std.testing.expectEqualStrings("hello", ship);
    const expanded = (try readNamed(archive, gpa, "packed")).?;
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(plain, expanded);
    const odd = (try readNamed(archive, gpa, "odd")).?;
    defer gpa.free(odd);
    try std.testing.expectEqualStrings("\x11\xFB\x00\x00\x05abc", odd);
    try std.testing.expectEqual(null, try readNamed(archive, gpa, "missing"));
}

test Hog {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two members: `Ship.SHP`, which holds `hello`, and a movie, in an archive found in any case.
    try testing.write(gpa, io, tmp.dir, "RESOURCE.HOG", &.{
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
    std.testing.refAllDecls(@This());
}

pub const testing = hog.testing;
