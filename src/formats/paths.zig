//! The names of files that discs and archives hold, checked before a tool writes the files under a
//! folder: a name read from a file could otherwise reach outside it.

const std = @import("std");

/// Whether `name` can name one file or folder in a folder: not empty, not `.` or `..`, and without
/// a path separator.
pub fn isName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.findAny(u8, name, "/\\") == null;
}

/// Whether `path`, its parts separated by forward slashes, names a file under a folder: each part
/// is a name (`isName`), so the path is neither empty nor absolute and has no `..` part.
pub fn isRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (!isName(part)) return false;
    }
    return true;
}

test isName {
    try std.testing.expect(isName("default.xbe"));
    try std.testing.expect(isName("asteroid 01.btga"));
    try std.testing.expect(!isName(""));
    try std.testing.expect(!isName("."));
    try std.testing.expect(!isName(".."));
    try std.testing.expect(!isName("Missions/M1a.dte"));
    try std.testing.expect(!isName("Missions\\M1a.dte"));
}

test isRelative {
    try std.testing.expect(isRelative("models/textures/sh_galactica_damage.btga"));
    try std.testing.expect(isRelative("gfx/asteroid 01.btga"));
    try std.testing.expect(!isRelative(""));
    try std.testing.expect(!isRelative("/etc/passwd"));
    try std.testing.expect(!isRelative("models/../../outside"));
    try std.testing.expect(!isRelative("models//a.mdl"));
    try std.testing.expect(!isRelative("models\\a.mdl"));
}
