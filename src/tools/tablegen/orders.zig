//! Reads the order table out of the payload: the orders objects follow, each with its routines,
//! flags, name and priority.
//!
//! `order_groups` holds a pointer to the records of each hundred order numbers, so order `n` is
//! record `n % 100` of group `n / 100`. The groups lie one after another, the last ending where
//! `order_groups` begins, so each group's length follows from where the next one starts.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const Record = openreliant.engine.game.ai.Record;

const image = @import("image.zig");
const testing = @import("testing.zig");

/// `order_groups`, which `object_orders` (`0x0040C5F0`) and the others index.
pub const order_groups: u32 = 0x004E06E0;
pub const group_count = 3;
const record_size = @sizeOf(Record);

/// Order numbers a group spans.
const group_span = 100;

pub const Order = struct {
    number: i16,
    name: []const u8,
    init: u32,
    update: u32,
    exit: u32,
    flags: u32,
    priority: i32,
};

pub const Group = struct {
    first: i16,
    address: u32,
    len: u8,
};

pub const Table = struct {
    groups: []const Group,
    orders: []const Order,
};

pub const Error = image.Error || error{BadGroups};

pub fn read(arena: std.mem.Allocator, reader: image.Reader) (Error || std.mem.Allocator.Error)!Table {
    const starts = try reader.records(u32, order_groups, group_count);

    const groups = try arena.alloc(Group, group_count);
    var orders: std.ArrayList(Order) = .empty;
    for (groups, starts, 0..) |*group, start, index| {
        const end = if (index + 1 < group_count) starts[index + 1] else order_groups;
        if (end <= start or (end - start) % record_size != 0) return error.BadGroups;
        const len = (end - start) / record_size;
        if (len > group_span) return error.BadGroups;
        group.* = .{ .first = @intCast(index * group_span), .address = start, .len = @intCast(len) };

        for (try reader.records(Record, start, len), 0..) |record, i| {
            try orders.append(arena, .{
                .number = @intCast(index * group_span + i),
                .name = try reader.string(@intFromEnum(record.name)),
                .init = @intFromEnum(record.init),
                .update = @intFromEnum(record.update),
                .exit = @intFromEnum(record.exit),
                .flags = @bitCast(record.flags),
                .priority = record.priority,
            });
        }
    }
    return .{ .groups = groups, .orders = try orders.toOwnedSlice(arena) };
}

/// Each order's name as a Zig identifier: `Make ripper drop what it's carrying` is
/// `make_ripper_drop_what_its_carrying`. A nameless order is `unnamed`, and an order whose name an
/// earlier one has already taken gets its number after it.
pub fn identifiers(arena: std.mem.Allocator, orders: []const Order) std.mem.Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, orders.len);
    for (orders, out, 0..) |order, *identifier, index| {
        const base = try identifierOf(arena, order.name);
        const taken = for (out[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, base)) break true;
        } else false;
        identifier.* = if (taken or base.len == 0)
            try std.fmt.allocPrint(arena, "{s}_{d}", .{ if (base.len == 0) "unnamed" else base, order.number })
        else
            base;
    }
    return out;
}

/// Lower case, words joined by underscores, anything else dropped.
fn identifierOf(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9' => try out.append(arena, std.ascii.toLower(c)),
        ' ', '-', '_' => if (out.items.len != 0 and out.items[out.items.len - 1] != '_') try out.append(arena, '_'),
        else => {},
    };
    while (out.items.len != 0 and out.items[out.items.len - 1] == '_') out.items.len -= 1;
    return out.toOwnedSlice(arena);
}

/// Writes a word of `Record.Flags` as a literal of the fields it sets, each by name, `.{}` for
/// none.
fn writeFlags(w: *Io.Writer, word: u32) Io.Writer.Error!void {
    const flags: Record.Flags = @bitCast(word);
    var any = false;
    try w.writeAll(".{");
    inline for (@typeInfo(Record.Flags).@"struct".fields) |field| {
        const value = @field(flags, field.name);
        const set = if (field.type == bool) value else value != 0;
        if (set) {
            try w.writeAll(if (any) ", ." else " .");
            any = true;
            if (field.type == bool) {
                try w.print("{s} = true", .{field.name});
            } else {
                try w.print("{s} = {d}", .{ field.name, value });
            }
        }
    }
    try w.writeAll(if (any) " }" else "}");
}

/// Writes `orders.zig`.
pub fn emit(w: *Io.Writer, table: Table, names: []const []const u8) Io.Writer.Error!void {
    try w.print(
        \\//! The orders objects follow, numbered as the game numbers them: order `n` is record `n % 100`
        \\//! of group `n / 100` of the order table. `docs/engine/orders.md` describes how objects follow
        \\//! them.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable's order table at 0x{X:0>8},
        \\//! {d} orders in {d} groups. Names are the developers' own. Do not edit by hand; run
        \\//! `make order-tables`.
        \\
        \\const std = @import("std");
        \\
        \\pub const Flags = @import("../ai.zig").Record.Flags;
        \\
        \\/// Every order in the table, by number.
        \\pub const Order = enum(i16) {{
        \\
    , .{ order_groups, table.orders.len, table.groups.len });
    for (table.orders, names) |order, name| {
        try w.print("    {f} = {d},\n", .{ std.zig.fmtId(name), order.number });
    }
    try w.writeAll(
        \\    _,
        \\
        \\    /// Its name in OpenReliant, or its number where the table holds no such order.
        \\    pub fn format(order: Order, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        \\        return switch (order) {
        \\            _ => writer.print("order {d}", .{@intFromEnum(order)}),
        \\            inline else => |named| writer.writeAll(@tagName(named)),
        \\        };
        \\    }
        \\};
        \\
        \\pub const Info = struct {
        \\    order: Order,
        \\    /// The developers' name, which may be empty.
        \\    name: []const u8,
        \\    flags: Flags,
        \\    priority: i32,
        \\    /// Addresses in the payload executable of its routines, or null where it has none.
        \\    init: ?u32,
        \\    update: ?u32,
        \\    exit: ?u32,
        \\};
        \\
        \\/// A group of the table: the records of the orders numbered from `first`.
        \\pub const Group = struct {
        \\    first: i16,
        \\    /// Where its records are in the payload executable.
        \\    address: u32,
        \\    len: u8,
        \\};
        \\
        \\pub const groups = [_]Group{
        \\
    );
    for (table.groups) |group| {
        try w.print("    .{{ .first = {d}, .address = 0x{X:0>8}, .len = {d} }},\n", .{ group.first, group.address, group.len });
    }
    try w.writeAll(
        \\};
        \\
        \\/// Every order, by number.
        \\pub const table = [_]Info{
        \\
    );
    for (table.orders, names) |order, name| {
        try w.print("    .{{ .order = .{f}, .name = \"{f}\", .flags = ", .{ std.zig.fmtId(name), std.zig.fmtString(order.name) });
        try writeFlags(w, order.flags);
        try w.print(", .priority = {d}", .{order.priority});
        inline for (.{ "init", "update", "exit" }) |field| {
            const address = @field(order, field);
            if (address == 0) {
                try w.print(", .{s} = null", .{field});
            } else {
                try w.print(", .{s} = 0x{X:0>8}", .{ field, address });
            }
        }
        try w.writeAll(" },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// The order numbered `order`, or null for a number the table does not hold.
        \\pub fn info(order: Order) ?Info {
        \\    for (table) |entry| {
        \\        if (entry.order == order) return entry;
        \\    }
        \\    return null;
        \\}
        \\
        \\comptime {
        \\    // The table holds each named order once, and the groups tile it in order.
        \\    if (table.len != std.enums.values(Order).len) @compileError("one entry per order");
        \\    var next: usize = 0;
        \\    for (groups) |group| {
        \\        for (table[next..][0..group.len], 0..) |entry, i| {
        \\            if (@intFromEnum(entry.order) - group.first != i) @compileError("orders out of place");
        \\        }
        \\        next += group.len;
        \\    }
        \\    if (next != table.len) @compileError("groups do not cover the table");
        \\}
        \\
        \\test info {
        \\    for (table) |entry| try std.testing.expectEqual(entry.order, info(entry.order).?.order);
        \\    try std.testing.expectEqual(null, info(@enumFromInt(-1)));
        \\}
        \\
    );
}

/// A synthetic payload: two groups of orders, with their names, and the pointers to them.
const TestPayload = struct {
    data: [0x400]u8 = @splat(0),

    const data_va = order_groups - 0x200;
    const strings = order_groups + 0x40;

    fn region(payload: *TestPayload) testing.Region {
        return .{ .va = data_va, .bytes = &payload.data };
    }

    /// Lays out `first_group` records, then one record in each later group.
    fn build(payload: *TestPayload, first_group: []const []const u8) void {
        const r = payload.region();
        const first_len: u32 = @intCast(first_group.len);
        const group_starts = [group_count]u32{
            order_groups - (first_len + group_count - 1) * record_size,
            order_groups - (group_count - 1) * record_size,
            order_groups - record_size,
        };
        r.putRecord(order_groups, group_starts);
        for (first_group, 0..) |name, i| {
            const at = group_starts[0] + @as(u32, @intCast(i)) * record_size;
            const name_at = strings + @as(u32, @intCast(i)) * 0x20;
            r.putString(name_at, name);
            var record = std.mem.zeroes(Record);
            record.name = @enumFromInt(name_at);
            record.update = @enumFromInt(0x00401000 + @as(u32, @intCast(i)) * 0x10);
            record.flags.retaliate = true;
            r.putRecord(at, record);
        }
        var later = std.mem.zeroes(Record);
        later.init = @enumFromInt(0x00402000);
        later.priority = 0x62;
        r.putRecord(group_starts[1], later);
    }

    fn table(payload: *TestPayload, arena: std.mem.Allocator) !Table {
        return read(arena, try testing.reader(arena, &.{payload.region()}));
    }
};

test read {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    payload.build(&.{ "Do Nothing", "Fly Aimlessly" });

    const read_table = try payload.table(arena.allocator());
    try std.testing.expectEqual(group_count, read_table.groups.len);
    try std.testing.expectEqual(2, read_table.groups[0].len);
    try std.testing.expectEqual(100, read_table.groups[1].first);
    try std.testing.expectEqual(4, read_table.orders.len);

    const fly = read_table.orders[1];
    try std.testing.expectEqual(1, fly.number);
    try std.testing.expectEqualStrings("Fly Aimlessly", fly.name);
    try std.testing.expectEqual(0x00401010, fly.update);
    try std.testing.expectEqual(0, fly.init);
    try std.testing.expect(@as(Record.Flags, @bitCast(fly.flags)).retaliate);

    const hundred = read_table.orders[2];
    try std.testing.expectEqual(100, hundred.number);
    try std.testing.expectEqual(0x62, hundred.priority);
    try std.testing.expectEqual(0x00402000, hundred.init);
    try std.testing.expectEqual(200, read_table.orders[3].number);
}

test "groups must tile the table" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    payload.build(&.{"Do Nothing"});
    // A group that starts part way into a record.
    payload.region().putWord(order_groups + 4, order_groups - 2 * record_size + 4);
    try std.testing.expectError(error.BadGroups, payload.table(arena.allocator()));
}

test writeFlags {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // None, and the named and the unknown bits of Fly's word.
    try writeFlags(&out.writer, 0);
    try std.testing.expectEqualStrings(".{}", out.written());
    out.clearRetainingCapacity();
    try writeFlags(&out.writer, 0x4C2);
    try std.testing.expectEqualStrings(".{ ._unknown_1 = 1, .retaliate = true, .avoidance = true, .send_flight = true }", out.written());
    const read_back: Record.Flags = .{ ._unknown_1 = 1, .retaliate = true, .avoidance = true, .send_flight = true };
    try std.testing.expectEqual(0x4C2, @as(u32, @bitCast(read_back)));
}

test identifiers {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const orders = [_]Order{
        .{ .number = 0, .name = "Jump In", .init = 0, .update = 0, .exit = 0, .flags = 0, .priority = 0 },
        .{ .number = 3, .name = "", .init = 0, .update = 0, .exit = 0, .flags = 0, .priority = 0 },
        .{ .number = 39, .name = "Make ripper drop what it's carrying", .init = 0, .update = 0, .exit = 0, .flags = 0, .priority = 0 },
        .{ .number = 40, .name = "Jump In", .init = 0, .update = 0, .exit = 0, .flags = 0, .priority = 0 },
        .{ .number = 110, .name = "Jump in", .init = 0, .update = 0, .exit = 0, .flags = 0, .priority = 0 },
    };
    const names = try identifiers(arena.allocator(), &orders);
    try std.testing.expectEqualStrings("jump_in", names[0]);
    try std.testing.expectEqualStrings("unnamed_3", names[1]);
    try std.testing.expectEqualStrings("make_ripper_drop_what_its_carrying", names[2]);
    try std.testing.expectEqualStrings("jump_in_40", names[3]);
    try std.testing.expectEqualStrings("jump_in_110", names[4]);
}

test "emit writes Zig that parses" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const orders = [_]Order{
        .{ .number = 0, .name = "Do Nothing", .init = 0, .update = 0x0040A880, .exit = 0, .flags = 0x40, .priority = 0 },
        .{ .number = 100, .name = "Player Control", .init = 0, .update = 0x00413410, .exit = 0, .flags = 0x400, .priority = 0 },
    };
    const groups = [_]Group{
        .{ .first = 0, .address = 0x004E0050, .len = 1 },
        .{ .first = 100, .address = 0x004E04A0, .len = 1 },
    };
    const table: Table = .{ .groups = &groups, .orders = &orders };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emit(&out.writer, table, try identifiers(arena.allocator(), &orders));
    try testing.expectZig(out.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "    player_control = 100,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".init = null, .update = 0x00413410, .exit = null },") != null);
    // The flags by name: Player Control's are its multiplayer's sending alone.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".name = \"Player Control\", .flags = .{ .send_flight = true },") != null);
    // The enum is open, so it names its values itself.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "    pub fn format(order: Order, writer: *std.Io.Writer) std.Io.Writer.Error!void {\n") != null);
}
