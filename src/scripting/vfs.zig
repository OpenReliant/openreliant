//! The `openreliant.vfs` package ([#498](https://github.com/OpenReliant/openreliant/issues/498),
//! [#592](https://github.com/OpenReliant/openreliant/issues/592)):
//! Scripts read the game's and the mods' files, and can't change them (`package`). A file comes as a
//! string of its bytes.
//!
//! A name is looked up in three places in turn: a mod's copy, then the game folder's loose file, such
//! as `missions\mission1.dte`, then the member of `resource.hog` (`find`).

const std = @import("std");

const openreliant = @import("openreliant");
const files = openreliant.engine.files;
const bigfile = openreliant.engine.game.bigfile;
const luau = @import("luau.zig");
const State = luau.State;
const api = @import("api.zig");
const Call = api.Call;
const Storage = @import("storage.zig").Storage;

/// What `openreliant.vfs` holds.
pub const package = struct {
    pub const read = api.Native("Reads the file `name` as a string of its bytes, the way the game does: a mod's copy (the latest mod's first), else the game folder's own file of that name, such as `missions\\mission1.dte`, else the member of the game's `resource.hog`. Nil if there is none.", "name: string", "string?", readGame);
    pub const read_mod = api.Native("Reads the calling mod's own file `name` as a string of its bytes. Nil if the mod doesn't have it.", "name: string", "string?", readMod);
    pub const exists = api.Native("Whether `vfs.read` would find the file `name`.", "name: string", "boolean", fileExists);
};

/// `vfs.read(name)`.
fn readGame(state: *State) i32 {
    const call: Call = .of(state, "vfs.read");
    const name = nameOf(state, "vfs.read");
    const gpa = call.runtime().gpa;
    // Refuses a loose file bigger than half the mod's memory, since it is copied into the script's
    // string.
    const most = call.runtime().options.limits.memory / 2;
    const bytes = find(call, name, most) catch |err| switch (err) {
        error.StreamTooLong => state.raise("vfs.read: {s} is bigger than the {d} bytes a script can read", .{ name, most }),
        else => state.raise("vfs.read: {s} can't be read: {s}", .{ name, @errorName(err) }),
    };
    return pushBytes(state, gpa, bytes orelse return pushNone(state));
}

/// Reads the file `name` into memory from the runtime's allocator, or returns null if there is none:
/// a mod's copy, else the game folder's loose file (`Mods.readLoose`), else the archive's member.
/// A loose file can be at most `most` bytes.
fn find(call: Call, name: []const u8, most: usize) !?[]u8 {
    const shared = call.runtime().options.shared;
    const gpa = call.runtime().gpa;
    const held = shared.files;
    const mods = if (held) |archive| archive.mods else &bigfile.Mods.none;
    const loose = if (shared.game) |folder|
        mods.readLoose(folder.io, gpa, folder.dir, name, .limited(most)) catch |err| switch (err) {
            // A folder is not a file.
            error.IsDir => null,
            else => return err,
        }
    else
        try mods.readInPlaceOf(gpa, name);
    if (loose) |bytes| return bytes;
    const archive = held orelse return null;
    return if (archive.has(name)) try archive.readFile(gpa, name) else null;
}

/// The game folder's loose file `name`, spelled as it is on disk in `spelled`. Null if there is none,
/// or if `name` is a folder.
fn looseFile(folder: Storage.Folder, name: []const u8, spelled: *[files.max_path]u8) ?[]const u8 {
    const path = files.find(folder.io, folder.dir, name, spelled) orelse return null;
    const stat = folder.dir.statFile(folder.io, path, .{}) catch return null;
    if (stat.kind != .file) return null;
    return path;
}

/// `vfs.read_mod(name)`.
fn readMod(state: *State) i32 {
    const call: Call = .of(state, "vfs.read_mod");
    const name = nameOf(state, "vfs.read_mod");
    const gpa = call.runtime().gpa;
    const bytes = call.context.modOf().readFile(gpa, name) catch |err| state.raise("vfs.read_mod: {s} can't be read: {s}", .{ name, @errorName(err) });
    return pushBytes(state, gpa, bytes orelse return pushNone(state));
}

/// `vfs.exists(name)`.
fn fileExists(state: *State) i32 {
    const call: Call = .of(state, "vfs.exists");
    const name = nameOf(state, "vfs.exists");
    const shared = call.runtime().options.shared;
    var spelled: [files.max_path]u8 = undefined;
    const archived = if (shared.files) |held| held.has(name) else false;
    state.pushBoolean(archived or if (shared.game) |folder| looseFile(folder, name, &spelled) != null else false);
    return 1;
}

fn nameOf(state: *State, comptime label: []const u8) []const u8 {
    return state.toString(1) orelse state.raise(label ++ ": expected a file's name, got {s}", .{state.typeName(1)});
}

fn pushNone(state: *State) i32 {
    state.pushNil();
    return 1;
}

/// Pushes `bytes` as a string (the state copies it) and frees them. Luau's errors skip Zig's defers,
/// so if the copy runs out of memory, the bytes are not freed until OpenReliant quits.
fn pushBytes(state: *State, gpa: std.mem.Allocator, bytes: []u8) i32 {
    if (!state.checkStack(1)) {
        gpa.free(bytes);
        state.raise("out of memory", .{});
    }
    state.pushString(bytes);
    gpa.free(bytes);
    return 1;
}

test "scripts read a mod's file, else the game folder's loose file, else the archive's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const load = @import("load.zig");
    const hog = openreliant.hog;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // The game folder: two loose missions, a loose file that the archive has a member of, and the
    // archive.
    try tmp.dir.createDirPath(io, "Missions");
    try tmp.dir.writeFile(io, .{ .sub_path = "Missions/Mission1.DTE", .data = "loose 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Missions/Mission2.DTE", .data = "loose 2" });
    try tmp.dir.writeFile(io, .{ .sub_path = "palette.tga", .data = "loose palette" });
    try hog.testing.write(gpa, io, tmp.dir, bigfile.resource_name, &.{
        .{ .name = "palette.tga", .data = "archive palette" },
        .{ .name = "only.shp", .data = "archive shape" },
    });
    // A mod that replaces the second mission, and reads them all.
    try load.testing.makeMods(io, tmp.dir, &.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nLoad=files.luau\n" },
            .{ "mission2.dte", "mod 2" },
            .{
                "files.luau",
                \\local vfs = require("openreliant.vfs")
                \\assert(vfs.read("missions\\mission1.dte") == "loose 1")
                \\assert(vfs.read(".\\MISSIONS\\Mission1.dte") == "loose 1")
                \\assert(vfs.read("missions\\mission2.dte") == "mod 2")
                \\assert(vfs.read("palette.tga") == "loose palette")
                \\assert(vfs.read("only.shp") == "archive shape")
                \\assert(vfs.read("missions\\mission3.dte") == nil and vfs.read("missions") == nil)
                \\assert(vfs.read("..\\outside.txt") == nil)
                \\assert(vfs.exists("missions\\mission1.dte") and vfs.exists("only.shp") and vfs.exists("mission2.dte"))
                \\assert(not vfs.exists("missions\\mission3.dte") and not vfs.exists("missions"))
                \\assert(vfs.read_mod("mission2.dte") == "mod 2" and vfs.read_mod("mission1.dte") == nil)
            },
        },
    }});
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    var archive: bigfile.Hog = try .open(gpa, io, tmp.dir, bigfile.resource_name);
    defer archive.close(gpa);
    archive.mods = &mods;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try load.testing.records3(arena.allocator());
    try load.run(gpa, io, mods.list, &held, "0.7.0", .{ .files = archive, .game = .{ .io = io, .dir = tmp.dir } });
}
