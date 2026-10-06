//! The game's file names, as it hands them to Windows: folders are split by `\` or `/`, and each
//! name matches in any case. `find`, `readFile` and `writeFile` treat them the same way on every
//! system, so a file a player drops into the game's folders is found however its name is spelled.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The longest path the game builds, Windows' `MAX_PATH`.
pub const max_path = 260;

/// The most OpenReliant reads of one of the game's files into memory, far past the largest.
pub const max_file_size = 256 << 20;

/// The characters that split the folders of a game path. Windows takes both.
pub const separators = "\\/";

/// The last name in the game path `path`: what follows its last `\` or `/`, as Windows splits it.
pub fn leaf(path: []const u8) []const u8 {
    const start = if (std.mem.findLastAny(u8, path, separators)) |at| at + 1 else 0;
    return path[start..];
}

/// The extension of `path`'s last name, from its last `.` and with the dot; empty when the name has
/// no dot, or only a leading one.
pub fn extension(path: []const u8) []const u8 {
    const name = leaf(path);
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return name[name.len..];
    return if (dot == 0) name[name.len..] else name[dot..];
}

/// `path`'s last name without its extension.
pub fn stem(path: []const u8) []const u8 {
    const name = leaf(path);
    return name[0 .. name.len - extension(name).len];
}

/// The file or folder `path` names under `dir`, spelled as it is on disk and with `/` between its
/// names, in `buffer`; null where none does. `.` names the folder itself, and `\` and `/` both
/// split the names.
pub fn find(io: Io, dir: Io.Dir, path: []const u8, buffer: *[max_path]u8) ?[]const u8 {
    var found: usize = 0;
    var names = std.mem.tokenizeAny(u8, path, separators);
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, ".")) continue;
        var folder = dir.openDir(io, if (found == 0) "." else buffer[0..found], .{ .iterate = true }) catch return null;
        defer folder.close(io);
        const spelled = entryNamed(io, folder, name) orelse return null;
        const separator: usize = @intFromBool(found > 0);
        if (found + separator + spelled.len > buffer.len) return null;
        if (separator > 0) buffer[found] = '/';
        @memcpy(buffer[found + separator ..][0..spelled.len], spelled);
        found += separator + spelled.len;
    }
    return buffer[0..found];
}

/// The name of the entry of `folder` spelled `name` whatever its case, which lives as long as the
/// iteration's buffer: until `folder` is closed.
fn entryNamed(io: Io, folder: Io.Dir, name: []const u8) ?[]const u8 {
    var entries = folder.iterate();
    while (entries.next(io) catch return null) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.name;
    }
    return null;
}

/// Whether `path` names a file or folder under `dir`, as the game asks with `_access`.
pub fn exists(io: Io, dir: Io.Dir, path: []const u8) bool {
    var buffer: [max_path]u8 = undefined;
    return find(io, dir, path, &buffer) != null;
}

/// The whole of the file `path` names under `dir`, made in `gpa`, found as `find` finds it; null
/// where there is none.
pub fn readFile(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, limit: Io.Limit) Io.Dir.ReadFileAllocError!?[]u8 {
    var buffer: [max_path]u8 = undefined;
    const spelled = find(io, dir, path, &buffer) orelse return null;
    return try dir.readFileAlloc(io, spelled, gpa, limit);
}

/// Writes `data` to the game's file `path` under `dir`, as Windows does: over the file `find` finds,
/// whatever the case of its name, or else as a new file named by `path`'s last name in the folder
/// `find` finds. error.FileNotFound when that folder isn't there.
pub fn writeFile(io: Io, dir: Io.Dir, path: []const u8, data: []const u8) !void {
    var buffer: [max_path]u8 = undefined;
    if (find(io, dir, path, &buffer)) |spelled| return dir.writeFile(io, .{ .sub_path = spelled, .data = data });
    const name = leaf(path);
    const folder = path[0 .. path.len - name.len];
    const found = if (std.mem.trim(u8, folder, separators).len == 0) "" else find(io, dir, folder, &buffer) orelse return error.FileNotFound;
    var joined: [max_path]u8 = undefined;
    const sub_path = if (found.len == 0) name else std.mem.print(&joined, "{s}/{s}", .{ found, name }) catch return error.NameTooLong;
    return dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

test leaf {
    try std.testing.expectEqualStrings("trooper.fm8", leaf("pilots\\trooper.fm8"));
    try std.testing.expectEqualStrings("trooper.fm8", leaf("pilots/trooper.fm8"));
    try std.testing.expectEqualStrings("c.png", leaf("a\\b/c.png"));
    try std.testing.expectEqualStrings("trooper", leaf("trooper"));
}

test stem {
    try std.testing.expectEqualStrings("peel_shot", stem("art\\peel_shot.png"));
    try std.testing.expectEqualStrings("keep", stem("keep."));
    try std.testing.expectEqualStrings(".png", stem(".png"));
}

test extension {
    // A dot in a folder's name is no extension, on any system.
    try std.testing.expectEqualStrings("", extension("v1.0\\readme"));
    try std.testing.expectEqualStrings(".FM8", extension("static.FM8"));
    try std.testing.expectEqualStrings(".c", extension("a.b.c"));
}

test writeFile {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Saves");
    try tmp.dir.writeFile(io, .{ .sub_path = "Saves/OLD.SAV", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "STARLANCER.INI", .data = "old" });

    // A file found in any case is written over, so the folder keeps one of it.
    try writeFile(io, tmp.dir, "saves\\old.sav", "new");
    try writeFile(io, tmp.dir, "starlancer.ini", "new");
    var buffer: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings("Saves/OLD.SAV", find(io, tmp.dir, "saves/old.sav", &buffer).?);
    const saved = (try readFile(io, std.testing.allocator, tmp.dir, "saves\\old.sav", .unlimited)).?;
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("new", saved);
    var count: usize = 0;
    var top = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer top.close(io);
    var entries = top.iterate();
    while (try entries.next(io)) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "starlancer.ini")) count += 1;
    }
    try std.testing.expectEqual(1, count);

    // A new file goes into the folder as it is spelled; a missing folder is an error.
    try writeFile(io, tmp.dir, "saves\\new.sav", "made");
    try std.testing.expectEqualStrings("Saves/new.sav", find(io, tmp.dir, "SAVES\\NEW.SAV", &buffer).?);
    try std.testing.expectError(error.FileNotFound, writeFile(io, tmp.dir, "missing\\x", "x"));
}

test find {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Missions");
    try tmp.dir.writeFile(io, .{ .sub_path = "Missions/Mission1.DTE", .data = "mission" });

    // Found whatever the case, from the game's own spelling.
    var buffer: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings("Missions/Mission1.DTE", find(io, tmp.dir, ".\\missions\\mission1.dte", &buffer).?);
    try std.testing.expect(exists(io, tmp.dir, "missions/MISSION1.dte"));
    try std.testing.expect(exists(io, tmp.dir, "missions"));
    try std.testing.expect(!exists(io, tmp.dir, "missions\\mission2.dte"));
    try std.testing.expect(!exists(io, tmp.dir, "other\\mission1.dte"));

    const bytes = (try readFile(io, std.testing.allocator, tmp.dir, "MISSIONS\\mission1.dte", .unlimited)).?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("mission", bytes);
    try std.testing.expectEqual(null, try readFile(io, std.testing.allocator, tmp.dir, "missions\\mission2.dte", .unlimited));
}
