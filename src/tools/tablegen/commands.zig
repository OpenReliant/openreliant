//! Reads the Executor command catalogue, which `0x21 command` indexes, out of the payload.
//!
//! The catalogue is self-describing: each entry carries its implementation, its name, a label and
//! a type for each parameter, and a one-line description, all written by the developers. The
//! engine counts entries until one has no implementation (`catalogue_count`, `0x00452A80`), and
//! this reader applies the same rule.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const openreliant = @import("openreliant");
const layout = openreliant.layout;

const image = @import("image.zig");
const testing = @import("testing.zig");

/// Virtual address of the catalogue, which `vm_install_commands` (`0x0045CE30`) installs as the
/// command table.
pub const catalogue: u32 = 0x004F0F50;

pub const max_params = 8;

/// `for_each_ship`: runs a callback for each ship of the ship, flight group or squad record in
/// `ECX`, passing it the rest of the arguments.
pub const for_each_ship: u32 = 0x0045D460;

/// How far past an implementation to look for its call to `for_each_ship`, short of the next
/// implementation.
const max_body = 0x400;

/// How far before that call to look for the `PUSH imm32` of the callback.
const max_push_distance = 12;

/// An entry of the catalogue, as the payload lays it out.
const Entry = extern struct {
    implementation: u32,
    param_count: u32,
    name: u32,
    params: [max_params]Parameter,
    description: u32,
    flag: u32,

    /// A parameter: a type, an unidentified word, and a label.
    const Parameter = extern struct {
        kinds: u32,
        extra: u32,
        label: u32,
    };

    comptime {
        assert(@offsetOf(Entry, "params") == 0x0C);
        assert(@offsetOf(Entry, "description") == 0x6C);
        assert(@sizeOf(Entry) == 0x74);
    }
};

/// `CALL rel32`.
const Call = extern struct {
    opcode: u8,
    displacement: i32 align(1),

    const encoding = 0xE8;

    comptime {
        assert(@sizeOf(Call) == 5);
    }
};

/// `PUSH imm32`.
const Push = extern struct {
    opcode: u8,
    value: u32 align(1),

    const encoding = 0x68;

    comptime {
        assert(@sizeOf(Push) == 5);
    }
};

pub const Param = struct {
    kinds: u32,
    extra: u32,
    label: []const u8,
};

pub const Command = struct {
    implementation: u32,
    name: []const u8,
    params: []const Param,
    description: []const u8,
    flag: u32,
    per_ship: ?u32 = null,
};

pub const Error = image.Error || error{ TooManyParams, NoCallback, TwoCallbacks };

pub fn read(arena: std.mem.Allocator, reader: image.Reader) (Error || std.mem.Allocator.Error)![]const Command {
    var commands: std.ArrayList(Command) = .empty;

    var at = catalogue;
    while (true) : (at += @sizeOf(Entry)) {
        const entry = try reader.record(Entry, at);
        if (entry.implementation == 0) break;

        if (entry.param_count > max_params) return error.TooManyParams;
        const params = try arena.alloc(Param, entry.param_count);
        for (params, entry.params[0..params.len]) |*param, raw| {
            param.* = .{ .kinds = raw.kinds, .extra = raw.extra, .label = try reader.string(raw.label) };
        }
        try commands.append(arena, .{
            .implementation = entry.implementation,
            .name = try reader.string(entry.name),
            .params = params,
            .description = try reader.string(entry.description),
            .flag = entry.flag,
        });
    }
    for (commands.items) |*command| command.per_ship = try perShip(reader, commands.items, command.implementation);
    return commands.toOwnedSlice(arena);
}

/// The callback an implementation hands `for_each_ship`, found by its call and the `PUSH` of the
/// callback just before it. The body is taken to end at the next implementation.
fn perShip(reader: image.Reader, all: []const Command, implementation: u32) Error!?u32 {
    var end = implementation + max_body;
    for (all) |other| {
        if (other.implementation > implementation) end = @min(end, other.implementation);
    }
    const body = try reader.slice(implementation, end - implementation);
    var found: ?u32 = null;
    for (0..body.len -| @sizeOf(Call) + 1) |i| {
        const call = layout.view(Call, body[i..]) catch break;
        if (call.opcode != Call.encoding) continue;
        const next = implementation + @as(u32, @intCast(i + @sizeOf(Call)));
        if (next +% @as(u32, @bitCast(call.displacement)) != for_each_ship) continue;

        const callback = for (1..@min(i, max_push_distance) + 1) |back| {
            const at = i - back;
            if (at + @sizeOf(Push) > i) continue;
            const push = layout.view(Push, body[at..]) catch continue;
            if (push.opcode == Push.encoding) break push.value;
        } else return error.NoCallback;
        if (found) |earlier| {
            if (earlier != callback) return error.TwoCallbacks;
        }
        found = callback;
    }
    return found;
}

pub fn emit(w: *Io.Writer, commands: []const Command) !void {
    try w.print(
        \\//! The Executor commands that `0x21 command` calls.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable's command catalogue at
        \\//! 0x{X:0>8}, {d} entries. Names, labels and descriptions are the developers' own. Do not
        \\//! edit by hand; run `make vm-commands`.
        \\
        \\const std = @import("std");
        \\const assert = std.debug.assert;
        \\
        \\/// What a parameter accepts: a mask of the kinds of value it takes. The bit names are read off
        \\/// the labels of the parameters that set them.
        \\pub const Kinds = packed struct(u32) {{
        \\    _unknown_0: u7,
        \\    /// `0x80`: a count, an ID, a number of seconds.
        \\    number: bool,
        \\    /// `0x100`: the name of a speech or movie file.
        \\    file_name: bool,
        \\    /// `0x200`: text, or an animation name.
        \\    text: bool,
        \\    /// `0x400`: a ship.
        \\    ship: bool,
        \\    /// `0x800`: a flight group, or a patrol route.
        \\    flight_group: bool,
        \\    _unknown_12: u2,
        \\    /// `0x4000`: a function, meaning a part.
        \\    part: bool,
        \\    _unknown_15: u4,
        \\    /// `0x80000`: a named constant: a pilot, an AI mode, a text ID.
        \\    constant: bool,
        \\    _unknown_20: bool,
        \\    /// `0x200000`: a trigger condition.
        \\    condition: bool,
        \\    /// `0x400000`: a camera or flight curve.
        \\    curve: bool,
        \\    _unknown_23: u9,
        \\}};
        \\
        \\pub const Param = struct {{
        \\    kinds: Kinds,
        \\    /// **Unknown.** Zero for most parameters.
        \\    extra: u32,
        \\    label: []const u8,
        \\}};
        \\
        \\pub const Command = struct {{
        \\    name: []const u8,
        \\    params: []const Param,
        \\    description: []const u8,
        \\    /// **Unknown.** Set on seven commands.
        \\    flag: u32,
        \\    /// Address of the implementation in the payload executable.
        \\    implementation: u32,
        \\    /// The callback the implementation hands `for_each_ship` (`0x0045D460`), which runs it for
        \\    /// each ship of the ship, flight group or squad the first argument names. Null for a
        \\    /// command that does not.
        \\    per_ship: ?u32,
        \\}};
        \\
        \\/// Every command, indexed by the operand of `0x21 command`.
        \\pub const table = [_]Command{{
        \\
    , .{ catalogue, commands.len });

    for (commands, 0..) |command, index| {
        try w.print("    // 0x{X:0>2}\n    .{{\n", .{index});
        try w.print("        .name = \"{f}\",\n", .{std.zig.fmtString(command.name)});
        if (command.params.len == 0) {
            try w.writeAll("        .params = &.{},\n");
        } else {
            try w.writeAll("        .params = &.{\n");
            for (command.params) |param| {
                try w.print(
                    "            .{{ .kinds = @bitCast(@as(u32, 0x{X:0>8})), .extra = 0x{X:0>8}, .label = \"{f}\" }},\n",
                    .{ param.kinds, param.extra, std.zig.fmtString(param.label) },
                );
            }
            try w.writeAll("        },\n");
        }
        try w.print("        .description = \"{f}\",\n", .{std.zig.fmtString(command.description)});
        try w.print("        .flag = {d},\n", .{command.flag});
        try w.print("        .implementation = 0x{X:0>8},\n", .{command.implementation});
        if (command.per_ship) |callback| {
            try w.print("        .per_ship = 0x{X:0>8},\n    }},\n", .{callback});
        } else {
            try w.writeAll("        .per_ship = null,\n    },\n");
        }
    }

    try w.writeAll(
        \\};
        \\
        \\// Every command has a name, and no two share one, as `executor.commandIndex` takes the first
        \\// command of a name.
        \\comptime {
        \\    @setEvalBranchQuota(200_000);
        \\    for (table, 0..) |command, n| {
        \\        assert(command.name.len != 0);
        \\        for (table[0..n]) |earlier| assert(!std.mem.eql(u8, earlier.name, command.name));
        \\    }
        \\}
        \\
        \\/// Looks up the command `0x21 command` calls with `index`.
        \\pub fn find(index: u8) ?Command {
        \\    return if (index < table.len) table[index] else null;
        \\}
        \\
        \\test find {
        \\    try std.testing.expect(find(0) != null);
        \\    try std.testing.expect(find(table.len) == null);
        \\}
        \\
    );
}

/// A synthetic payload: code at `code_va` for the implementations, and the catalogue with its
/// strings in a second region.
const TestPayload = struct {
    code: [0x800]u8 = @splat(0xCC),
    data: [0x400]u8 = @splat(0),

    const code_va = 0x0045D000;
    const data_va = catalogue & ~@as(u32, 0xFF);
    const strings = data_va + 0x200;

    fn text(payload: *TestPayload) testing.Region {
        return .{ .va = code_va, .bytes = &payload.code };
    }

    fn table(payload: *TestPayload) testing.Region {
        return .{ .va = data_va, .bytes = &payload.data };
    }

    /// `PUSH callback` then `CALL for_each_ship`, at `at`; returns where the next instruction goes.
    fn callForEachShip(payload: *TestPayload, at: u32, callback: ?u32) u32 {
        var next = at;
        if (callback) |address| {
            payload.text().putRecord(next, Push{ .opcode = Push.encoding, .value = address });
            next += @sizeOf(Push);
        }
        const displacement = for_each_ship -% (next + @sizeOf(Call));
        payload.text().putRecord(next, Call{ .opcode = Call.encoding, .displacement = @bitCast(displacement) });
        return next + @sizeOf(Call);
    }

    /// Catalogue entry `index`, with one parameter when `label` is given.
    fn entry(payload: *TestPayload, index: u32, implementation: u32, name: []const u8, label: ?[]const u8) void {
        const region = payload.table();
        const name_at = strings + index * 0x40;
        region.putString(name_at, name);
        region.putString(name_at + 0x10, "Does a thing");
        var record = std.mem.zeroes(Entry);
        record.implementation = implementation;
        record.name = name_at;
        record.description = name_at + 0x10;
        if (label) |text_label| {
            region.putString(name_at + 0x20, text_label);
            record.param_count = 1;
            record.params[0] = .{ .kinds = 0x400, .extra = 0, .label = name_at + 0x20 };
        }
        region.putRecord(catalogue + index * @sizeOf(Entry), record);
    }

    /// The catalogue as `read` finds it. The image lives in `arena`, as the strings read do.
    fn commands(payload: *TestPayload, arena: std.mem.Allocator) ![]const Command {
        return read(arena, try testing.reader(arena, &.{ payload.text(), payload.table() }));
    }
};

test read {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    const first = TestPayload.code_va + 0x100;
    const second = TestPayload.code_va + 0x200;
    const callback = TestPayload.code_va + 0x300;
    payload.text().put(payload.callForEachShip(first, callback), &.{0xC3});
    payload.text().put(second, &.{0xC3});
    payload.entry(0, first, "KillShip", "Ship to kill");
    payload.entry(1, second, "Wait", null);

    const read_commands = try payload.commands(arena.allocator());
    try std.testing.expectEqual(2, read_commands.len);
    try std.testing.expectEqualStrings("KillShip", read_commands[0].name);
    try std.testing.expectEqualStrings("Does a thing", read_commands[0].description);
    try std.testing.expectEqual(1, read_commands[0].params.len);
    try std.testing.expectEqualStrings("Ship to kill", read_commands[0].params[0].label);
    try std.testing.expectEqual(0x400, read_commands[0].params[0].kinds);
    try std.testing.expectEqual(callback, read_commands[0].per_ship.?);
    try std.testing.expectEqual(0, read_commands[1].params.len);
    try std.testing.expectEqual(null, read_commands[1].per_ship);
}

test "a call to for_each_ship needs the callback pushed before it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    const first = TestPayload.code_va + 0x100;
    _ = payload.callForEachShip(first, null);
    payload.entry(0, first, "KillShip", null);
    try std.testing.expectError(error.NoCallback, payload.commands(arena.allocator()));
}

test "an implementation hands for_each_ship one callback" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var payload: TestPayload = .{};
    const first = TestPayload.code_va + 0x100;
    const next = payload.callForEachShip(first, TestPayload.code_va + 0x300);
    _ = payload.callForEachShip(next, TestPayload.code_va + 0x340);
    payload.entry(0, first, "KillShip", null);
    try std.testing.expectError(error.TwoCallbacks, payload.commands(arena.allocator()));
}

test "emit writes Zig that parses" {
    const params = [_]Param{.{ .kinds = 0x400, .extra = 0, .label = "Ship to \"kill\"" }};
    const listed = [_]Command{
        .{ .implementation = 0x0045D100, .name = "KillShip", .params = &params, .description = "Kills it", .flag = 0, .per_ship = 0x0045D300 },
        .{ .implementation = 0x0045D200, .name = "Wait", .params = &.{}, .description = "", .flag = 1 },
    };
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try emit(&out.writer, &listed);
    try testing.expectZig(out.written());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".per_ship = 0x0045D300,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".per_ship = null,") != null);
}
