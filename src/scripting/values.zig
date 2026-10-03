//! Converts Zig values to Luau values and back, for the records (`bind.zig`) and the hooks
//! (`hooks.zig`):
//!
//! - Numbers are numbers, and `bool` is a boolean.
//! - An enum value is its tag's name. A value without a name is a number, and so is one whose tag
//!   starts with an underscore, since those hold values whose meaning isn't known yet.
//! - Byte arrays and slices of bytes are strings, and `@Vector(3, f32)` is a Luau vector.
//! - An optional that holds nothing is nil.
//! - An object (`engine.hooks.Object`) is a handle (`objects.zig`), and a list of objects
//!   (`objects.List`) a table of handles.
//! - Plain data passed on (`data.Data`) is the copy made of it.
//! - Any other struct is a read-only table of its fields.
//!
//! Values read back are checked: a value of the wrong type, out of range or not finite raises an
//! error that names it.

const std = @import("std");
const assert = std.debug.assert;

const openreliant = @import("openreliant");
const Object = openreliant.engine.hooks.Object;
const luau = @import("luau.zig");
const State = luau.State;
const objects = @import("objects.zig");
const data = @import("data.zig");

/// A table scripts handed over, such as an interface, held by a reference that its holder lets go
/// (`Runtime.release`).
pub const Table = struct {
    ref: luau.Ref,
};

/// Pushes `value`.
pub fn push(state: *State, comptime T: type, value: T) void {
    if (T == Object) return objects.push(state, value.slot());
    if (T == objects.List) return pushList(state, value);
    if (T == data.Data or T == Table) {
        _ = state.pushRef(value.ref);
        return;
    }
    switch (@typeInfo(T)) {
        .float => state.pushNumber(value),
        .int => state.pushNumber(@floatFromInt(value)),
        .bool => state.pushBoolean(value),
        .@"enum" => if (name(T, value)) |tag_name| state.pushString(tag_name) else state.pushNumber(@floatFromInt(@intFromEnum(value))),
        .optional => |optional| if (value) |held| push(state, optional.child, held) else state.pushNil(),
        .vector => state.pushVector(value),
        .array => |array| {
            comptime assert(array.child == u8);
            state.pushString(std.mem.sliceTo(&value, 0));
        },
        .pointer => |pointer| {
            comptime assert(pointer.size == .slice and pointer.child == u8);
            state.pushString(value);
        },
        .@"struct" => pushTable(state, T, value),
        else => @compileError("scripts can't read a " ++ @typeName(T)),
    }
}

/// Pushes a table of the handles of `list`'s objects, in order.
fn pushList(state: *State, list: objects.List) void {
    state.newTable(@intCast(list.len), 0);
    for (list.slots[0..list.len], 1..) |index, at| {
        objects.push(state, index);
        state.rawSetIndex(-2, @intCast(at));
    }
}

/// Pushes `value`, a struct, as a read-only table of the fields scripts see (`shown`).
pub fn pushTable(state: *State, comptime T: type, value: T) void {
    const fields = comptime shownFields(T);
    state.newTable(0, fields.len);
    inline for (fields) |field| {
        push(state, field.type, @field(value, field.name));
        state.rawSetField(-2, field.name);
    }
    state.setReadonly(-1, true);
}

/// The fields of `T` that scripts see: all except those starting with an underscore (`shown`).
pub fn shownFields(comptime T: type) []const std.builtin.Type.StructField {
    comptime {
        var fields: []const std.builtin.Type.StructField = &.{};
        for (@typeInfo(T).@"struct".fields) |field| {
            if (shown(field.name)) fields = fields ++ .{field};
        }
        return fields;
    }
}

/// The value at `given` as a `T`. Raises an error if it doesn't fit; `label` names the value in
/// the message.
pub fn read(state: *State, comptime T: type, given: i32, comptime label: []const u8) T {
    if (T == Object) return .of(objects.read(state, given, label));
    if (T == objects.Handle) return (state.toUserdata(objects.Handle, given, objects.Handle.tag) orelse wrongType(state, label, "an object", given)).*;
    if (T == data.Data) {
        data.copy(state, given, label);
        defer state.pop(1);
        return .{ .ref = state.ref(-1) };
    }
    switch (@typeInfo(T)) {
        .float => {
            const number = state.toNumber(given) orelse wrongType(state, label, "a number", given);
            const narrowed = std.math.lossyCast(T, number);
            if (!std.math.isFinite(narrowed)) state.raise("{s}: expected a finite number, got {d}", .{ label, number });
            return narrowed;
        },
        .int => {
            const number = state.toNumber(given) orelse wrongType(state, label, "a number", given);
            if (number != @floor(number) or number < std.math.minInt(T) or number > std.math.maxInt(T)) {
                state.raise("{s}: expected a whole number from {d} to {d}, got {d}", .{ label, std.math.minInt(T), std.math.maxInt(T), number });
            }
            return @intFromFloat(number);
        },
        .bool => {
            if (state.typeOf(given) != .boolean) wrongType(state, label, "a boolean", given);
            return state.toBoolean(given);
        },
        .@"enum" => |info| {
            if (state.toString(given)) |tag_name| {
                return byName(T, tag_name) orelse state.raise("{s}: expected {s}, got '{s}'", .{ label, comptime choices(T), tag_name });
            }
            const number = state.toNumber(given) orelse wrongType(state, label, comptime choices(T), given);
            if (number == @floor(number) and number >= std.math.minInt(info.tag_type) and number <= std.math.maxInt(info.tag_type)) {
                const raw: info.tag_type = @intFromFloat(number);
                if (!info.is_exhaustive) return @enumFromInt(raw);
                inline for (comptime std.enums.values(T)) |named| {
                    if (@intFromEnum(named) == raw) return named;
                }
            }
            state.raise("{s}: expected {s}, got {d}", .{ label, comptime choices(T), number });
        },
        .optional => |optional| {
            if (state.typeOf(given) == .nil) return null;
            return read(state, optional.child, given, label);
        },
        .vector => {
            const vector = state.toVector(given) orelse wrongType(state, label, "a vector", given);
            if (!@reduce(.And, @abs(vector) <= @as(T, @splat(std.math.floatMax(f32))))) state.raise("{s}: expected a finite vector", .{label});
            return vector;
        },
        .array => |array| {
            comptime assert(array.child == u8);
            const text = state.toString(given) orelse wrongType(state, label, "a string", given);
            if (text.len >= array.len) state.raise("{s}: expected at most {d} bytes, got {d}", .{ label, array.len - 1, text.len });
            var bytes: T = @splat(0);
            @memcpy(bytes[0..text.len], text);
            return bytes;
        },
        // A string is read in place, so it lasts only as long as the call that reads it.
        .pointer => |pointer| {
            comptime assert(pointer.size == .slice and pointer.child == u8 and pointer.is_const);
            return state.toString(given) orelse wrongType(state, label, "a string", given);
        },
        else => @compileError("scripts can't write a " ++ @typeName(T)),
    }
}

fn wrongType(state: *State, comptime label: []const u8, comptime expected: []const u8, given: i32) noreturn {
    state.raise("{s}: expected {s}, got {s}", .{ label, expected, state.typeName(given) });
}

/// The name scripts see for `value`: its tag's, but for a tag that starts with an underscore.
pub fn name(comptime T: type, value: T) ?[]const u8 {
    const tag_name = std.enums.tagName(T, value) orelse return null;
    return if (shown(tag_name)) tag_name else null;
}

/// The value named `tag_name`, if scripts see a value by that name.
fn byName(comptime T: type, tag_name: []const u8) ?T {
    if (!shown(tag_name)) return null;
    return std.meta.stringToEnum(T, tag_name);
}

/// Whether scripts see a tag or a field by its name: all but those that start with an underscore,
/// which hold what isn't understood yet.
pub fn shown(tag_name: []const u8) bool {
    return tag_name.len > 0 and tag_name[0] != '_';
}

/// The names of `T`'s values that scripts see.
pub fn names(comptime T: type) []const []const u8 {
    comptime {
        @setEvalBranchQuota(std.enums.values(T).len * 100);
        var found: []const []const u8 = &.{};
        for (std.enums.values(T)) |value| {
            if (shown(@tagName(value))) found = found ++ .{@tagName(value)};
        }
        return found;
    }
}

/// Whether scripts may give a number for a value of `T`: an open enum takes any, and a value
/// without a name is only given as one.
pub fn takesNumbers(comptime T: type) bool {
    return !@typeInfo(T).@"enum".is_exhaustive or names(T).len < std.enums.values(T).len;
}

/// The values an enum field accepts, for error messages.
fn choices(comptime T: type) []const u8 {
    comptime {
        @setEvalBranchQuota(std.enums.values(T).len * 100);
        const listed = names(T);
        const numbers = takesNumbers(T);
        var text: []const u8 = "";
        for (listed, 0..) |tag_name, at| {
            const separator = if (at == 0) "" else if (at == listed.len - 1 and !numbers) " or " else ", ";
            text = text ++ separator ++ "'" ++ tag_name ++ "'";
        }
        return if (numbers) text ++ " or a number" else text;
    }
}

test choices {
    const Level = enum(u8) { low, high, _unknown_2 };
    try std.testing.expectEqualStrings("'low', 'high' or a number", comptime choices(Level));
    const Exact = enum { left, right, fore };
    try std.testing.expectEqualStrings("'left', 'right' or 'fore'", comptime choices(Exact));
    try std.testing.expectEqual(null, name(Level, ._unknown_2));
    try std.testing.expectEqualStrings("high", name(Level, .high).?);
}

test "values go to scripts and back" {
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    const Level = enum(u8) { low, high, _unknown_2, _ };

    push(state, Level, .high);
    try std.testing.expectEqualStrings("high", state.toString(-1).?);
    try std.testing.expectEqual(Level.high, read(state, Level, -1, "level"));
    push(state, Level, ._unknown_2);
    try std.testing.expectEqual(2, state.toNumber(-1).?);
    try std.testing.expectEqual(Level._unknown_2, read(state, Level, -1, "level"));
    push(state, ?f32, null);
    try std.testing.expectEqual(null, read(state, ?f32, -1, "number"));
    push(state, @Vector(3, f32), .{ 1, 2, 3 });
    try std.testing.expectEqual(@Vector(3, f32){ 1, 2, 3 }, read(state, @Vector(3, f32), -1, "vector"));
    push(state, []const u8, "mission40.dte");
    try std.testing.expectEqualStrings("mission40.dte", state.toString(-1).?);
}
