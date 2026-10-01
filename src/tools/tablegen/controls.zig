//! Reads the control bindings out of the payload: each action's name, the string the controls
//! screens show for it, and the key, modifier and joystick button the game starts with; the keys an
//! action can be bound to, with their names; and the order the controls screens list the actions
//! in.
//!
//! The bindings are data in the image, `ControlBinding` records, and run to the first record whose
//! name is not an action's: upper-case words. The keys are `KeyName` records, and run to the first
//! whose name is not a key's.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const ControlBinding = openreliant.engine.input.ControlBinding;
const KeyName = openreliant.engine.input.KeyName;
const Modifier = ControlBinding.Modifier;

const image = @import("image.zig");
const testing = @import("testing.zig");
const zig_text = @import("zig_text.zig");

/// `control_bindings`, which `control_active` (`0x00412630`) indexes by action.
pub const table: u32 = 0x004E2380;
const name_size = @typeInfo(@FieldType(ControlBinding, "name")).array.len;

/// Actions a table this size could hold, as a bound on the scan.
const max_actions = 256;

/// `key_names`, the keys an action can be bound to.
pub const keys_table: u32 = 0x004E5CD0;
const key_name_size = @typeInfo(@FieldType(KeyName, "name")).array.len;

/// Keys a table this size could hold, as a bound on the scan.
const max_keys = 256;

/// `controls_list`, the rows of the controls screens: an action's, numbered in turn as a screen
/// opens, or a divider (`divider`), to its end (`0x0042BA43`).
pub const list_table: u32 = 0x004E75E8;
pub const list_end: u32 = 0x004E7688;
const divider: i16 = -1;

pub const Binding = struct {
    name: []const u8,
    string: u16,
    key: u16,
    modifier: Modifier,
    button: i16,
};

pub const Key = struct {
    code: u8,
    name: []const u8,
};

/// A row of the controls screens: an action's, which the actions take in turn, or a divider.
pub const Row = enum { action, divider };

pub const Error = image.Error || error{ Empty, UnknownModifier, BadKey, BadRow };

pub fn read(arena: std.mem.Allocator, reader: image.Reader) (Error || std.mem.Allocator.Error)![]const Binding {
    var bindings: std.ArrayList(Binding) = .empty;
    for (0..max_actions) |index| {
        const record = try reader.viewAt(ControlBinding, table, index);
        const binding = try parse(record) orelse break;
        try bindings.append(arena, binding);
    }
    if (bindings.items.len == 0) return error.Empty;
    return bindings.toOwnedSlice(arena);
}

/// The keys of `key_names`, to the first whose name is not a key's.
pub fn readKeys(arena: std.mem.Allocator, reader: image.Reader) (Error || std.mem.Allocator.Error)![]const Key {
    var keys: std.ArrayList(Key) = .empty;
    for (0..max_keys) |index| {
        const record = try reader.viewAt(KeyName, keys_table, index);
        const key = try parseKey(record) orelse break;
        try keys.append(arena, key);
    }
    if (keys.items.len == 0) return error.Empty;
    return keys.toOwnedSlice(arena);
}

/// The key one record holds, or null where its name is not a key's, which ends the table.
fn parseKey(record: *align(1) const KeyName) error{BadKey}!?Key {
    const name = std.mem.sliceTo(&record.name, 0);
    if (name.len == 0 or record.code == 0) return null;
    for (name) |c| if (c < ' ' or c > '~') return null;
    return .{ .name = name, .code = std.math.cast(u8, record.code) orelse return error.BadKey };
}

/// The rows of `controls_list`.
pub fn readList(arena: std.mem.Allocator, reader: image.Reader) (Error || std.mem.Allocator.Error)![]const Row {
    const count = (list_end - list_table) / @sizeOf(i16);
    const entries = try reader.records(i16, list_table, count);
    const rows = try arena.alloc(Row, count);
    for (rows, entries) |*row, entry| row.* = if (entry == divider) .divider else if (entry == 0) .action else return error.BadRow;
    return rows;
}

/// The binding one record holds, or null when its name is not an action's, which ends the table.
fn parse(record: *align(1) const ControlBinding) error{UnknownModifier}!?Binding {
    const name = std.mem.sliceTo(&record.name, 0);
    if (!isActionName(name)) return null;
    return .{
        .name = name,
        .string = record.string,
        .key = record.key,
        .modifier = switch (record.modifier) {
            .none, .shift, .control, .alt => record.modifier,
            _ => return error.UnknownModifier,
        },
        .button = record.button,
    };
}

/// Upper-case words, as every action's name is.
fn isActionName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        'A'...'Z', '0'...'9', ' ', '-' => {},
        else => return false,
    };
    return true;
}

/// Writes `controls.zig`.
pub fn emit(w: *Io.Writer, bindings: []const Binding, keys: []const Key, rows: []const Row) Io.Writer.Error!void {
    try w.print(
        \\//! The player's actions, and the keys and joystick buttons the game binds them to at first; the
        \\//! keys an action can be bound to; and the order the controls screens list the actions in.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable's control bindings at
        \\//! 0x{X:0>8}, {d} actions. The names are the game's own. Do not edit by hand; run
        \\//! `make control-tables`.
        \\
        \\const std = @import("std");
        \\
        \\/// The modifier held with a key; `docs/engine/controls.md` describes how each counts.
        \\pub const Modifier = @import("../input.zig").ControlBinding.Modifier;
        \\
        \\/// Every action, numbered as the game numbers them.
        \\pub const Action = enum(u32) {{
        \\
    , .{ table, bindings.len });
    var buffer: [name_size]u8 = undefined;
    for (bindings, 0..) |binding, index| {
        try w.print("    {s} = {d},\n", .{ zig_text.identifier(&buffer, binding.name), index });
    }
    try w.writeAll(
        \\};
        \\
        \\pub const Binding = struct {
        \\    /// The name `starlancer.ini` keys its bindings by.
        \\    name: []const u8,
        \\    /// The language string of the name the controls screens show.
        \\    string: u16,
        \\    /// A DirectInput scan code (`DIK_*`).
        \\    key: u16,
        \\    modifier: Modifier,
        \\    /// A joystick button, or null for none.
        \\    button: ?u8,
        \\};
        \\
        \\/// The bindings the game starts with, indexed by `Action`.
        \\pub const defaults = [_]Binding{
        \\
    );
    for (bindings) |binding| {
        try w.print("    .{{ .name = \"{f}\", .string = 0x{X:0>3}, .key = 0x{X:0>2}, .modifier = ", .{
            std.zig.fmtString(binding.name), binding.string, binding.key,
        });
        try zig_text.enumValue(w, binding.modifier);
        try w.writeAll(", .button = ");
        if (std.math.cast(u8, binding.button)) |button| {
            try w.print("{d} }},\n", .{button});
        } else {
            try w.writeAll("null },\n");
        }
    }
    try w.print(
        \\}};
        \\
        \\pub fn binding(action: Action) Binding {{
        \\    return defaults[@intFromEnum(action)];
        \\}}
        \\
        \\comptime {{
        \\    if (defaults.len != std.enums.values(Action).len) @compileError("one binding per action");
        \\}}
        \\
        \\/// A key an action can be bound to: its scan code, and the name the game gives it before the
        \\/// keyboard's own (`key_names`, 0x{X:0>8}).
        \\pub const Key = struct {{
        \\    code: u8,
        \\    name: []const u8,
        \\}};
        \\
        \\pub const keys = [_]Key{{
        \\
    , .{keys_table});
    for (keys) |key| try w.print("    .{{ .code = 0x{X:0>2}, .name = \"{f}\" }},\n", .{ key.code, std.zig.fmtString(key.name) });
    try w.print(
        \\}};
        \\
        \\/// The rows of the controls screens, in order (`controls_list`, 0x{X:0>8}): an action, the
        \\/// actions in turn, or null for a divider between groups.
        \\pub const list = [_]?Action{{
        \\
    , .{list_table});
    var buffer2: [name_size]u8 = undefined;
    var next: usize = 0;
    for (rows) |row| switch (row) {
        .divider => try w.writeAll("    null,\n"),
        .action => {
            if (next < bindings.len) try w.print("    .{s},\n", .{zig_text.identifier(&buffer2, bindings[next].name)});
            next += 1;
        },
    };
    try w.writeAll(
        \\};
        \\
        \\test binding {
        \\    for (std.enums.values(Action)) |action| {
        \\        const name = binding(action).name;
        \\        const tag = @tagName(action);
        \\        try std.testing.expectEqual(name.len, tag.len);
        \\        for (name, tag) |c, t| {
        \\            try std.testing.expectEqual(if (c == ' ' or c == '-') '_' else std.ascii.toLower(c), t);
        \\        }
        \\    }
        \\}
        \\
    );
}

fn testRecord(key: u16, modifier: u16, name: []const u8, button: i16) ControlBinding {
    var record: ControlBinding = .{ .key = key, .modifier = @enumFromInt(modifier), .name = @splat(0), .string = 0x35C, .key_name = @splat(0), .button = button };
    @memcpy(record.name[0..name.len], name);
    return record;
}

test parse {
    const record = testRecord(0x0F, 1, "REVERSE THRUST", -1);
    const binding = (try parse(&record)).?;
    try std.testing.expectEqualStrings("REVERSE THRUST", binding.name);
    try std.testing.expectEqual(0x35C, binding.string);
    try std.testing.expectEqual(0x0F, binding.key);
    try std.testing.expectEqual(Modifier.shift, binding.modifier);
    try std.testing.expectEqual(-1, binding.button);

    const alt = testRecord(0x2C, 3, "MATCH SPEED", 4);
    try std.testing.expectEqual(Modifier.alt, (try parse(&alt)).?.modifier);
    try std.testing.expectEqual(4, (try parse(&alt)).?.button);
}

test "parse ends the table at a record that is not an action" {
    const lower = testRecord(0x10, 0, "Not an action", -1);
    try std.testing.expectEqual(null, try parse(&lower));
    const empty = testRecord(0, 0, "", 0);
    try std.testing.expectEqual(null, try parse(&empty));
}

test "parse rejects a modifier the game does not know" {
    const record = testRecord(0x10, 4, "FIRE", -1);
    try std.testing.expectError(error.UnknownModifier, parse(&record));
}

test isActionName {
    try std.testing.expect(isActionName("ROLL SHIP ANTI-CLOCKWISE"));
    try std.testing.expect(isActionName("LOOK 2"));
    try std.testing.expect(!isActionName(""));
    try std.testing.expect(!isActionName("Fire"));
    try std.testing.expect(!isActionName("FIRE\x01"));
}

test parseKey {
    var record: KeyName = .{ .code = 0x1E, .name = @splat(0) };
    @memcpy(record.name[0..1], "A");
    const key = (try parseKey(&record)).?;
    try std.testing.expectEqual(0x1E, key.code);
    try std.testing.expectEqualStrings("A", key.name);
    // The table ends at a record with no code, or a name that is not a key's.
    record.code = 0;
    try std.testing.expectEqual(null, try parseKey(&record));
    record = .{ .code = 0x30, .name = @splat(0) };
    record.name[0] = 0x1E;
    try std.testing.expectEqual(null, try parseKey(&record));
    record = .{ .code = 0x1234, .name = @splat(0) };
    @memcpy(record.name[0..1], "B");
    try std.testing.expectError(error.BadKey, parseKey(&record));
}

test "emit writes Zig that parses" {
    const bindings = [_]Binding{
        .{ .name = "AFTERBURNERS", .string = 0x34A, .key = 0x0F, .modifier = .none, .button = 2 },
        .{ .name = "REVERSE THRUST", .string = 0x35C, .key = 0x0F, .modifier = .shift, .button = -1 },
    };
    const keys = [_]Key{ .{ .code = 0x1E, .name = "A" }, .{ .code = 0x2B, .name = "\\" } };
    const rows = [_]Row{ .action, .divider, .action };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emit(&out.writer, &bindings, &keys, &rows);
    const source = out.written();
    try testing.expectZig(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "    reverse_thrust = 1,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".modifier = .shift, .button = null },\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".modifier = .none, .button = 2 },\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".string = 0x35C,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".{ .code = 0x2B, .name = \"\\\\\" },\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "    .afterburners,\n    null,\n    .reverse_thrust,\n") != null);
}
