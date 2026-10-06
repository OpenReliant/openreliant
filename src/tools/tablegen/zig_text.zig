//! What the table writers share: values and names as Zig source text.

const std = @import("std");
const Io = std.Io;

/// A value of a non-exhaustive enum as Zig: its name, or the number where it has none.
pub fn enumValue(w: *Io.Writer, value: anytype) Io.Writer.Error!void {
    if (std.enums.tagName(@TypeOf(value), value)) |name| {
        try w.print(".{s}", .{name});
    } else {
        try w.print("@fromBackingInt({d})", .{@backingInt(value)});
    }
}

/// A developer's name as a Zig identifier, written into `buffer`, which must be as long: lower case,
/// with an underscore for each space and hyphen. `NOSE UP` is `nose_up`.
pub fn identifier(buffer: []u8, name: []const u8) []const u8 {
    for (name, buffer[0..name.len]) |c, *out| out.* = switch (c) {
        ' ', '-' => '_',
        else => std.ascii.toLower(c),
    };
    return buffer[0..name.len];
}

test enumValue {
    const Side = enum(u8) { friendly = 0, hostile = 1, _ };
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try enumValue(&w, Side.hostile);
    try w.writeAll(", ");
    try enumValue(&w, @as(Side, @fromBackingInt(9)));
    try std.testing.expectEqualStrings(".hostile, @fromBackingInt(9)", w.buffered());
}

test identifier {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("roll_ship_anti_clockwise", identifier(&buffer, "ROLL SHIP ANTI-CLOCKWISE"));
    try std.testing.expectEqualStrings("loop_the_loop", identifier(&buffer, "loop the loop"));
}
