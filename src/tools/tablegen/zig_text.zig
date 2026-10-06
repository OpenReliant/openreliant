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

/// `value`, a packed struct of flags, as Zig: a literal naming the fields it sets, such as
/// `.{ .ship = true, ._unknown_12 = 0x2 }`, or `.{}` where none is set. Every field needs a default
/// of zero, so that the literal can leave the others out.
pub fn flags(value: anytype) Flags(@TypeOf(value)) {
    return .{ .value = value };
}

pub fn Flags(comptime T: type) type {
    const info = @typeInfo(T).@"struct";
    comptime {
        std.debug.assert(info.layout == .@"packed");
        for (info.field_types, info.field_attrs) |Field, attrs| {
            const default = attrs.defaultValue(Field) orelse @compileError(@typeName(T) ++ " has a field with no default");
            std.debug.assert(@as(@Int(.unsigned, @bitSizeOf(Field)), @bitCast(default)) == 0);
        }
    }
    return struct {
        value: T,

        pub fn format(shown: @This(), w: *Io.Writer) Io.Writer.Error!void {
            var any = false;
            try w.writeAll(".{");
            inline for (info.field_names, info.field_types) |name, Field| {
                const field = @field(shown.value, name);
                const set = switch (@typeInfo(Field)) {
                    .bool => field,
                    .int => field != 0,
                    else => @compileError("a flag field is a bool or an integer"),
                };
                if (set) {
                    try w.writeAll(if (any) ", ." else " .");
                    try w.writeAll(name);
                    switch (@typeInfo(Field)) {
                        .bool => try w.writeAll(" = true"),
                        .int => try w.print(" = 0x{X}", .{field}),
                        else => unreachable,
                    }
                    any = true;
                }
            }
            try w.writeAll(if (any) " }" else "}");
        }
    };
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

test flags {
    const Seen = packed struct(u8) { near: bool = false, far: bool = false, _unknown_2: u6 = 0 };
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try w.print("{f}; {f}", .{ flags(Seen{}), flags(Seen{ .far = true, ._unknown_2 = 0x21 }) });
    try std.testing.expectEqualStrings(".{}; .{ .far = true, ._unknown_2 = 0x21 }", w.buffered());
}

test identifier {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("roll_ship_anti_clockwise", identifier(&buffer, "ROLL SHIP ANTI-CLOCKWISE"));
    try std.testing.expectEqualStrings("loop_the_loop", identifier(&buffer, "loop the loop"));
}
