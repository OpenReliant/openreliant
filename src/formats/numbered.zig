//! The names of the numbered parts of a game file, such as a sprite set's shapes and a sound bank's
//! sounds: the file's name without its folder or extension, `_`, and the part's number with at
//! least three digits, such as `HUDHARD_021` for shape 21 of `HUDHARD.SPR`. `sltool` saves parts
//! under these names, and a mod's file that replaces a part is named after it.

const std = @import("std");

/// The name of part `index` of the file `file_name`, followed by `extension`.
pub fn name(buffer: []u8, file_name: []const u8, index: usize, extension: []const u8) error{NoSpaceLeft}![]u8 {
    const stem = std.Io.Dir.path.stem(std.Io.Dir.path.basenameWindows(file_name));
    return std.mem.print(buffer, "{s}_{d:0>3}{s}", .{ stem, index, extension });
}

/// A part's name split: the file's name without its extension, and the part's number.
pub const Part = struct {
    file: []const u8,
    index: usize,
};

/// Splits `stem`, a part's name without an extension, into the file's name and the part's number.
/// Returns null if `name` would never write `stem`.
pub fn parse(stem: []const u8) ?Part {
    const mark = std.mem.findScalarLast(u8, stem, '_') orelse return null;
    const digits = stem[mark + 1 ..];
    const index = std.fmt.parseUnsigned(usize, digits, 10) catch return null;
    // `name` writes three digits at least, and no more than the number needs.
    var buffer: [std.fmt.count("{d}", .{std.math.maxInt(usize)})]u8 = undefined;
    const written = std.mem.print(&buffer, "{d:0>3}", .{index}) catch return null;
    if (!std.mem.eql(u8, written, digits)) return null;
    return .{ .file = stem[0..mark], .index = index };
}

test name {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("HUDHARD_021.png", try name(&buffer, "HUDHARD.SPR", 21, ".png"));
    try std.testing.expectEqualStrings("itacsnd_1234", try name(&buffer, "inter\\itac\\itacsnd.fat", 1234, ""));
    try std.testing.expectError(error.NoSpaceLeft, name(buffer[0..8], "smp3d.fat", 7, ""));
}

test parse {
    try std.testing.expectEqualDeep(Part{ .file = "HUDHARD", .index = 21 }, parse("HUDHARD_021").?);
    try std.testing.expectEqualDeep(Part{ .file = "set_two", .index = 1234 }, parse("set_two_1234").?);
    // Fewer than three digits, more than the number needs, and none at all.
    try std.testing.expectEqual(null, parse("HUDHARD_21"));
    try std.testing.expectEqual(null, parse("HUDHARD_0021"));
    try std.testing.expectEqual(null, parse("HUDHARD_"));
    try std.testing.expectEqual(null, parse("HUDHARD"));
}
