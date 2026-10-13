//! Mission source: a mission as text ([Mission source](../../../docs/formats/mission-source.md)).
//! Its children write the text, hold it as Luau's parser reads it, and compile it into a mission
//! file.
const std = @import("std");

/// The names records are declared under.
pub const names = @import("source/names.zig");
/// The names of the game's values.
pub const vocabulary = @import("source/vocabulary.zig");
/// The script as text.
pub const script = @import("source/script.zig");
/// A mission as text.
pub const write = @import("source/write.zig");
/// The text as Luau's parser reads it.
pub const syntax = @import("source/syntax.zig");
/// The text compiled into a mission file.
pub const compile = @import("source/compile.zig");
/// What the source's words take and give, and the fields of its tables.
pub const language = @import("source/language.zig");
/// The definitions file for luau-lsp.
pub const definitions = @import("source/definitions.zig");

/// Whether `id` is made of letters, digits, `_` and `-`, and starts with a letter or `_`:
/// `[A-Za-z_][A-Za-z0-9_-]*`. Mods' scripts name what they register this way.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or !(std.ascii.isAlphabetic(id[0]) or id[0] == '_')) return false;
    for (id[1..]) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '-')) return false;
    }
    return true;
}

test validId {
    for ([_][]const u8{ "player", "_start", "Alpha_2-escort" }) |id| try std.testing.expect(validId(id));
    for ([_][]const u8{ "", "2player", "-player", "A B", "A.B", "A\x00B", "é" }) |id| try std.testing.expect(!validId(id));
    // Every byte, control characters and bytes past ASCII too, first and later in a name.
    for (0..256) |value| {
        const char: u8 = @intCast(value);
        const letter = (char >= 'A' and char <= 'Z') or (char >= 'a' and char <= 'z');
        const digit = char >= '0' and char <= '9';
        try std.testing.expectEqual(letter or char == '_', validId(&.{char}));
        try std.testing.expectEqual(letter or digit or char == '_' or char == '-', validId(&.{ 'a', char }));
    }
}

test {
    std.testing.refAllDecls(@This());
}
