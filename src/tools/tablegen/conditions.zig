//! Reads the trigger condition catalogue out of the payload.
//!
//! `mission_script_start` installs the catalogue with two instructions, one storing its address and
//! one its length, and this reader takes both from those instructions. Each descriptor names its
//! condition, the kinds of object the condition applies to and the values its events carry;
//! `src/engine/vm.zig` gives the layout.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const Repeat = openreliant.dte.Trigger.Repeat;
const KindSet = openreliant.dte.Object.KindSet;
const vm = openreliant.engine.vm;
const Descriptor = vm.ConditionDescriptor;
const EventValue = vm.EventValue;

const image = @import("image.zig");
const testing = @import("testing.zig");
const zig_text = @import("zig_text.zig");

/// Where `mission_script_start` installs the catalogue: `MOV dword ptr [condition_table], imm32`,
/// then `MOV word ptr [condition_count], imm16`.
pub const install: u32 = 0x0045CBC4;
const condition_table: u32 = 0x0052952C;
const condition_count: u32 = 0x00525F8C;

/// The values an event can carry: the five locals of a thread, and a trigger's five operands.
pub const max_values = vm.max_event_values;

/// `MOV dword ptr [address], value`, which installs the catalogue's address.
const StoreDword = extern struct {
    opcode: [2]u8,
    address: u32 align(1),
    value: u32 align(1),

    const encoding: [2]u8 = .{ 0xC7, 0x05 };

    comptime {
        std.debug.assert(@sizeOf(StoreDword) == 10);
    }
};

/// `MOV word ptr [address], value`, which installs its length.
const StoreWord = extern struct {
    opcode: [3]u8,
    address: u32 align(1),
    value: u16 align(1),

    const encoding: [3]u8 = .{ 0x66, 0xC7, 0x05 };

    comptime {
        std.debug.assert(@sizeOf(StoreWord) == 9);
    }
};

/// What a descriptor's `slot` and `veto_exempt` hold for none.
const none = Descriptor.none;

pub const Value = struct {
    label: []const u8,
    kinds: u32,
    extra: u8,
    checked: bool,
};

pub const Handlers = struct {
    begin: u32,
    add_member: u32,
    verdict: u32,
};

pub const Condition = struct {
    name: []const u8,
    unknown_04: u16,
    subjects: KindSet,
    values: []const Value,
    slot: ?u8,
    veto_exempt: ?Repeat,
    handlers: ?Handlers,
};

pub const Catalogue = struct {
    address: u32,
    conditions: []const Condition,
};

pub const Error = image.Error || error{ NotTheInstall, TooManyValues, PartialHandlers, BadFlag };

pub fn read(arena: std.mem.Allocator, reader: image.Reader) (Error || std.mem.Allocator.Error)!Catalogue {
    const table_store = try reader.record(StoreDword, install);
    if (!std.mem.eql(u8, &table_store.opcode, &StoreDword.encoding) or table_store.address != condition_table) {
        return error.NotTheInstall;
    }
    const count_store = try reader.record(StoreWord, install + @sizeOf(StoreDword));
    if (!std.mem.eql(u8, &count_store.opcode, &StoreWord.encoding) or count_store.address != condition_count) {
        return error.NotTheInstall;
    }
    const address = table_store.value;

    const descriptors = try reader.records(Descriptor, address, count_store.value);
    const conditions = try arena.alloc(Condition, descriptors.len);
    for (conditions, descriptors) |*condition, descriptor| {
        var values: std.ArrayList(Value) = .empty;
        var list = @intFromEnum(descriptor.values);
        while (list != 0) : (list += @sizeOf(EventValue)) {
            // The list ends at a null label. `checked` is a `bool`, so its byte is looked at before
            // the record is read.
            if (try reader.word(list + @offsetOf(EventValue, "label")) == 0) break;
            if (values.items.len == max_values) return error.TooManyValues;
            if (try reader.int(u8, list + @offsetOf(EventValue, "checked")) > 1) return error.BadFlag;
            const value = try reader.record(EventValue, list);
            try values.append(arena, .{
                .label = try reader.string(@intFromEnum(value.label)),
                .kinds = @bitCast(value.kinds),
                .extra = value._unknown_08,
                .checked = value.checked,
            });
        }

        const handlers: Handlers = .{
            .begin = @intFromEnum(descriptor.begin),
            .add_member = @intFromEnum(descriptor.add_member),
            .verdict = @intFromEnum(descriptor.verdict),
        };
        const any = handlers.begin != 0 or handlers.add_member != 0 or handlers.verdict != 0;
        const all = handlers.begin != 0 and handlers.add_member != 0 and handlers.verdict != 0;
        if (any and !all) return error.PartialHandlers;

        condition.* = .{
            .name = try reader.string(@intFromEnum(descriptor.name)),
            .unknown_04 = descriptor._unknown_04,
            .subjects = descriptor.subjects,
            .values = try values.toOwnedSlice(arena),
            .slot = if (descriptor.slot == none) null else descriptor.slot,
            .veto_exempt = if (@intFromEnum(descriptor.veto_exempt) == none) null else descriptor.veto_exempt,
            .handlers = if (all) handlers else null,
        };
    }
    return .{ .address = address, .conditions = conditions };
}

/// Writes `vm/conditions.zig`.
pub fn emit(w: *Io.Writer, catalogue: Catalogue) !void {
    try w.print(
        \\//! The trigger conditions: the kinds of object each applies to and the values its events carry.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable's condition catalogue at
        \\//! 0x{X:0>8}, {d} entries, which `mission_script_start` installs. Names and labels are the
        \\//! developers' own. Do not edit by hand; run `make vm-conditions`.
        \\
        \\const dte = @import("../../formats/dte.zig");
        \\const Kinds = @import("../game/executor/commands.zig").Kinds;
        \\
        \\/// One value an event carries. A thread the event starts has them as its locals, and a
        \\/// trigger's operands follow the same order.
        \\pub const Value = struct {{
        \\    label: []const u8,
        \\    kinds: Kinds,
        \\    /// **Unknown.**
        \\    extra: u8,
        \\    /// Whether a trigger's operand for this value is checked against the event's.
        \\    checked: bool,
        \\}};
        \\
        \\/// Addresses, in the payload executable, of the handlers that can veto an event.
        \\pub const Handlers = struct {{
        \\    begin: u32,
        \\    add_member: u32,
        \\    verdict: u32,
        \\}};
        \\
        \\pub const Condition = struct {{
        \\    name: []const u8,
        \\    /// The kinds of object whose triggers can have the condition.
        \\    subjects: dte.Object.KindSet,
        \\    values: []const Value,
        \\    /// Where the matcher keeps each object's last event of this condition, for
        \\    /// `push_event_value`.
        \\    slot: ?u8,
        \\    /// The repeat mode whose triggers fire even when a handler vetoes the event.
        \\    veto_exempt: ?dte.Trigger.Repeat,
        \\    handlers: ?Handlers,
        \\    /// **Unknown.**
        \\    _unknown_04: u16,
        \\}};
        \\
        \\/// Every condition, indexed by a trigger's condition byte.
        \\pub const table = [_]Condition{{
        \\
    , .{ catalogue.address, catalogue.conditions.len });

    for (catalogue.conditions, 0..) |condition, index| {
        try w.print("    // 0x{X:0>2}\n    .{{\n", .{index});
        try w.print("        .name = \"{f}\",\n", .{std.zig.fmtString(condition.name)});
        const subjects = condition.subjects;
        try w.print("        .subjects = .{{ .ship = {}, .flight_group = {}, .squad = {}, ._unused = {d} }},\n", .{
            subjects.ship, subjects.flight_group, subjects.squad, subjects._unused,
        });
        if (condition.values.len == 0) {
            try w.writeAll("        .values = &.{},\n");
        } else {
            try w.writeAll("        .values = &.{\n");
            for (condition.values) |value| {
                try w.print(
                    "            .{{ .label = \"{f}\", .kinds = @bitCast(@as(u32, 0x{X:0>8})), .extra = 0x{X:0>2}, .checked = {} }},\n",
                    .{ std.zig.fmtString(value.label), value.kinds, value.extra, value.checked },
                );
            }
            try w.writeAll("        },\n");
        }
        if (condition.slot) |slot| {
            try w.print("        .slot = {d},\n", .{slot});
        } else {
            try w.writeAll("        .slot = null,\n");
        }
        if (condition.veto_exempt) |repeat| {
            try w.writeAll("        .veto_exempt = ");
            try zig_text.enumValue(w, repeat);
            try w.writeAll(",\n");
        } else {
            try w.writeAll("        .veto_exempt = null,\n");
        }
        if (condition.handlers) |handlers| {
            try w.print(
                "        .handlers = .{{ .begin = 0x{X:0>8}, .add_member = 0x{X:0>8}, .verdict = 0x{X:0>8} }},\n",
                .{ handlers.begin, handlers.add_member, handlers.verdict },
            );
        } else {
            try w.writeAll("        .handlers = null,\n");
        }
        try w.print("        ._unknown_04 = 0x{X:0>4},\n    }},\n", .{condition.unknown_04});
    }

    try w.writeAll(
        \\};
        \\
        \\/// Looks up the condition a trigger's condition byte names.
        \\pub fn find(condition: u8) ?Condition {
        \\    return if (condition < table.len) table[condition] else null;
        \\}
        \\
        \\test find {
        \\    const std = @import("std");
        \\    try std.testing.expect(find(0) != null);
        \\    try std.testing.expect(find(table.len) == null);
        \\    for (table) |condition| try std.testing.expect(condition.name.len != 0);
        \\}
        \\
    );
}

/// A synthetic payload: the two instructions that install the catalogue, and the catalogue with its
/// value lists and strings.
const TestPayload = struct {
    code: [0x40]u8 = @splat(0x90),
    data: [0x400]u8 = @splat(0),

    const code_va = install & ~@as(u32, 0xF);
    const table_va = 0x004F2000;
    const lists = table_va + 0x100;
    const strings = table_va + 0x200;

    fn text(payload: *TestPayload) testing.Region {
        return .{ .va = code_va, .bytes = &payload.code };
    }

    fn table(payload: *TestPayload) testing.Region {
        return .{ .va = table_va, .bytes = &payload.data };
    }

    fn installCatalogue(payload: *TestPayload, count: u16) void {
        const region = payload.text();
        region.putRecord(install, StoreDword{ .opcode = StoreDword.encoding, .address = condition_table, .value = table_va });
        region.putRecord(install + @sizeOf(StoreDword), StoreWord{ .opcode = StoreWord.encoding, .address = condition_count, .value = count });
    }

    /// Descriptor `index`, named `name`, with no values, slot or handlers, changed by `change`.
    fn descriptor(payload: *TestPayload, index: u32, name: []const u8, change: anytype) void {
        const name_at = strings + index * 0x20;
        payload.table().putString(name_at, name);
        var record = std.mem.zeroes(Descriptor);
        record.name = @enumFromInt(name_at);
        record.slot = none;
        record.veto_exempt = @enumFromInt(none);
        change.apply(&record);
        payload.table().putRecord(table_va + index * @sizeOf(Descriptor), record);
    }

    /// A value list at `list`, ending with an entry whose label is null, each value checked or not
    /// by the byte `checked`.
    fn values(payload: *TestPayload, list: u32, labels: []const []const u8, checked: u8) void {
        const region = payload.table();
        for (labels, 0..) |label, i| {
            const at = list + @as(u32, @intCast(i)) * @sizeOf(EventValue);
            const label_at = strings + 0x100 + @as(u32, @intCast(i)) * 0x10;
            region.putString(label_at, label);
            var value = std.mem.zeroes(EventValue);
            value.label = @enumFromInt(label_at);
            value.kinds = @bitCast(@as(u32, 0x400));
            value._unknown_08 = 0x02;
            region.putRecord(at, value);
            region.put(at + @offsetOf(EventValue, "checked"), &.{checked});
        }
    }

    /// Leaves a descriptor as `descriptor` makes it.
    const unchanged = struct {
        fn apply(_: *Descriptor) void {}
    };

    /// Points a descriptor's values at the value list.
    const listed = struct {
        fn apply(record: *Descriptor) void {
            record.values = @enumFromInt(lists);
        }
    };

    fn catalogue(payload: *TestPayload, arena: std.mem.Allocator) !Catalogue {
        return read(arena, try testing.reader(arena, &.{ payload.text(), payload.table() }));
    }
};

/// The tests' subjects: a ship or a flight group, and none.
const ship_or_group: KindSet = .{ .ship = true, .flight_group = true, .squad = false, ._unused = 0 };
const no_kinds: KindSet = .{ .ship = false, .flight_group = false, .squad = false, ._unused = 0 };

test read {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    payload.installCatalogue(2);
    payload.descriptor(0, "ShipDestroyed", struct {
        fn apply(record: *Descriptor) void {
            record._unknown_04 = 0x1234;
            record.subjects = ship_or_group;
            record.values = @enumFromInt(TestPayload.lists);
            record.slot = 3;
            record.begin = @enumFromInt(0x0045E000);
            record.add_member = @enumFromInt(0x0045E001);
            record.verdict = @enumFromInt(0x0045E002);
        }
    });
    payload.values(TestPayload.lists, &.{ "Ship", "Killer" }, 1);
    payload.descriptor(1, "MissionStart", TestPayload.unchanged);

    const read_catalogue = try payload.catalogue(arena.allocator());
    try std.testing.expectEqual(TestPayload.table_va, read_catalogue.address);
    try std.testing.expectEqual(2, read_catalogue.conditions.len);

    const destroyed = read_catalogue.conditions[0];
    try std.testing.expectEqualStrings("ShipDestroyed", destroyed.name);
    try std.testing.expectEqual(0x1234, destroyed.unknown_04);
    try std.testing.expectEqual(ship_or_group, destroyed.subjects);
    try std.testing.expectEqual(2, destroyed.values.len);
    try std.testing.expectEqualStrings("Killer", destroyed.values[1].label);
    try std.testing.expectEqual(0x400, destroyed.values[1].kinds);
    try std.testing.expectEqual(2, destroyed.values[1].extra);
    try std.testing.expect(destroyed.values[1].checked);
    try std.testing.expectEqual(3, destroyed.slot);
    try std.testing.expectEqual(0x0045E002, destroyed.handlers.?.verdict);

    const start = read_catalogue.conditions[1];
    try std.testing.expectEqualStrings("MissionStart", start.name);
    try std.testing.expectEqual(0, start.values.len);
    try std.testing.expectEqual(null, start.handlers);
    try std.testing.expectEqual(null, start.slot);
    try std.testing.expectEqual(null, start.veto_exempt);
}

test "read wants the install instructions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    try std.testing.expectError(error.NotTheInstall, payload.catalogue(arena.allocator()));
}

test "handlers come in threes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    payload.installCatalogue(1);
    payload.descriptor(0, "ShipDestroyed", struct {
        fn apply(record: *Descriptor) void {
            record.begin = @enumFromInt(0x0045E000);
        }
    });
    try std.testing.expectError(error.PartialHandlers, payload.catalogue(arena.allocator()));
}

test "a value is checked or not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    payload.installCatalogue(1);
    payload.descriptor(0, "ShipDestroyed", TestPayload.listed);
    payload.values(TestPayload.lists, &.{"Ship"}, 2);
    try std.testing.expectError(error.BadFlag, payload.catalogue(arena.allocator()));
}

test "an event carries at most five values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    payload.installCatalogue(1);
    payload.descriptor(0, "ShipDestroyed", TestPayload.listed);
    payload.values(TestPayload.lists, &.{ "A", "B", "C", "D", "E", "F" }, 0);
    try std.testing.expectError(error.TooManyValues, payload.catalogue(arena.allocator()));
}

test "emit writes Zig that parses" {
    const values_listed = [_]Value{.{ .label = "Ship", .kinds = 0x400, .extra = 2, .checked = true }};
    const listed = [_]Condition{
        .{ .name = "ShipDestroyed", .unknown_04 = 0, .subjects = ship_or_group, .values = &values_listed, .slot = 3, .veto_exempt = .once, .handlers = .{ .begin = 1, .add_member = 2, .verdict = 3 } },
        .{ .name = "MissionStart", .unknown_04 = 0x10, .subjects = no_kinds, .values = &.{}, .slot = null, .veto_exempt = null, .handlers = null },
        .{ .name = "Odd", .unknown_04 = 0, .subjects = no_kinds, .values = &.{}, .slot = null, .veto_exempt = @enumFromInt(0x7F), .handlers = null },
    };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emit(&out.writer, .{ .address = 0x004F2000, .conditions = &listed });
    try testing.expectZig(out.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".slot = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".slot = 3,\n        .veto_exempt = .once,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".veto_exempt = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".veto_exempt = @enumFromInt(127),") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".subjects = .{ .ship = true, .flight_group = true, .squad = false, ._unused = 0 },") != null);
}
