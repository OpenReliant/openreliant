//! The script's statements as Luau text, as mission source writes them
//! ([The script](../../../../docs/formats/mission-source.md#the-script)).

const std = @import("std");
const Writer = std.Io.Writer;

const statements = @import("../statements.zig");
const Statement = statements.Statement;
const Expression = statements.Expression;
const Operator = statements.Operator;
const Update = statements.Update;
const commands = @import("../../../engine/game/executor/commands.zig");
const conditions = @import("../../../engine/vm/conditions.zig");
const names = @import("names.zig");
const Word = names.Word;
const vocabulary = @import("vocabulary.zig");
const vm = @import("../../../engine/vm.zig");

/// What the text names the mission's records by: their names, by their index among their kind.
pub const Names = struct {
    ships: []const []const u8 = &.{},
    flight_groups: []const []const u8 = &.{},
    squads: []const []const u8 = &.{},
    curves: []const []const u8 = &.{},
    globals: []const []const u8 = &.{},
    parts: []const []const u8 = &.{},
    /// The name of each object's record, by its object ID, where it has one.
    objects: []const ?[]const u8 = &.{},

    /// The record of object `id`: a ship, a flight group or a squad.
    pub fn object(record_names: Names, id: u32) Indexed {
        const list = record_names.objects;
        if (id < list.len and list[id] != null) return .{ .name = list[id].? };
        return .{ .fallback = .{ .object_index, id } };
    }
};

/// A record, by its name, or by its index form, such as `ship_index(59031)`, where its index lies
/// past the mission's records ([References past the
/// records](../../../../docs/formats/mission-source.md#references-past-the-records)).
pub const Indexed = union(enum) {
    name: []const u8,
    fallback: struct { Word, u32 },

    pub fn format(record: Indexed, w: *Writer) Writer.Error!void {
        switch (record) {
            .name => |name| try w.writeAll(name),
            .fallback => |fallback| try w.print("{t}({d})", .{ fallback[0], fallback[1] }),
        }
    }
};

/// Record `index` of `list`, whose index form is `fallback`.
pub fn indexed(list: []const []const u8, index: u32, fallback: Word) Indexed {
    return if (index < list.len) .{ .name = list[index] } else .{ .fallback = .{ fallback, index } };
}

/// Where the statements are: in a trigger's function, whose parameters are its event's values, or
/// in a part's.
pub const Scope = struct {
    /// The names of the event's values, a trigger's function's parameters.
    event: []const []const u8 = &.{},
};

/// The names a trigger's function gives its event's values: their labels in the condition
/// catalogue, as names. No record takes them (`names.Namer.reserve`), so that the function's
/// parameters never hide one.
pub fn eventNames(arena: std.mem.Allocator, values: []const conditions.Value) std.mem.Allocator.Error![]const []const u8 {
    const list = try arena.alloc([]const u8, values.len);
    var namer: names.Namer = .init(arena);
    for (list, values, 0..) |*item, value, index| item.* = try namer.name(value.label, "value", index);
    return list;
}

/// The parameters of a part's function: `arg0`, `arg1` and so on, as the script numbers its
/// arguments.
pub fn writeParameters(writer: *Writer, count: usize) Writer.Error!void {
    for (0..count) |index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.print("arg{d}", .{index});
    }
}

/// Writes `body`, a line for each statement, indented by `depth` levels.
pub fn write(writer: *Writer, body: []const Statement, record_names: *const Names, scope: Scope, depth: usize) Writer.Error!void {
    const printer: Printer = .{ .writer = writer, .names = record_names, .scope = scope };
    try printer.block(body, depth);
}

const Printer = struct {
    writer: *Writer,
    names: *const Names,
    scope: Scope,

    fn block(p: Printer, body: []const Statement, depth: usize) Writer.Error!void {
        for (body) |line| try p.statement(line, depth);
    }

    fn indent(p: Printer, depth: usize) Writer.Error!void {
        try p.writer.splatByteAll(' ', 4 * depth);
    }

    fn statement(p: Printer, line: Statement, depth: usize) Writer.Error!void {
        const w = p.writer;
        try p.indent(depth);
        switch (line) {
            .command => |command| {
                const entry = commands.find(command.index);
                if (entry) |known| try w.print("{s}(", .{known.name}) else try w.print("{t}({d}", .{ Word.command, command.index });
                for (command.arguments, 0..) |argument, index| {
                    if (index > 0 or entry == null) try w.writeAll(", ");
                    try p.expression(argument, kindOf(entry, index), .lowest);
                }
                try w.writeAll(")\n");
            },
            .call => |call| {
                try w.print("{f}(", .{indexed(p.names.parts, call.part, .part_index)});
                try p.values(call.arguments, false);
                try w.writeAll(")\n");
            },
            .spawn => |call| {
                try w.print("{t}({f}", .{ Word.spawn, indexed(p.names.parts, call.part, .part_index) });
                try p.values(call.arguments, true);
                try w.writeAll(")\n");
            },
            .assign => |assign| if (assignSymbol(assign.update)) |symbol_text| {
                try p.target(assign.target);
                try w.print(" {s} ", .{symbol_text});
                try p.expression(assign.value, null, .lowest);
                try w.writeByte('\n');
            } else {
                try w.print("{t}(", .{assign.update});
                try p.target(assign.target);
                try w.writeAll(", ");
                try p.expression(assign.value, null, .lowest);
                try w.writeAll(")\n");
            },
            .@"if" => |branch| try p.ifStatement(branch, depth),
            .random => |random| try p.randomStatement(random, depth),
            .@"return" => |value| {
                try w.writeAll("return ");
                try p.expression(value, null, .lowest);
                try w.writeByte('\n');
            },
        }
    }

    /// Writes `list`, its values separated by commas, with one before the first where `leading`.
    fn values(p: Printer, list: []const Expression, leading: bool) Writer.Error!void {
        for (list, 0..) |value, index| {
            if (index > 0 or leading) try p.writer.writeAll(", ");
            try p.expression(value, null, .lowest);
        }
    }

    /// `if`, `elseif` for an `else` that holds one `if` alone, and `else`.
    fn ifStatement(p: Printer, first: statements.If, depth: usize) Writer.Error!void {
        var branch = first;
        try p.writer.writeAll("if ");
        while (true) {
            try p.expression(branch.condition, null, .lowest);
            try p.writer.writeAll(" then\n");
            try p.block(branch.then, depth + 1);
            const otherwise = branch.otherwise orelse break;
            if (otherwise.len == 1 and otherwise[0] == .@"if") {
                branch = otherwise[0].@"if";
                try p.indent(depth);
                try p.writer.writeAll("elseif ");
                continue;
            }
            try p.indent(depth);
            try p.writer.writeAll("else\n");
            try p.block(otherwise, depth + 1);
            break;
        }
        try p.indent(depth);
        try p.writer.writeAll("end\n");
    }

    /// A random choice: one roll, then an `if` over its arms' thresholds, and the default as `else`.
    fn randomStatement(p: Printer, random: statements.Random, depth: usize) Writer.Error!void {
        try p.writer.print("local roll = {t}()\n", .{Word.random});
        for (random.arms, 0..) |arm, index| {
            try p.indent(depth);
            try p.writer.print("{s} roll < {d} then\n", .{ if (index == 0) "if" else "elseif", arm.threshold });
            try p.block(arm.body, depth + 1);
        }
        if (random.default.len > 0) {
            try p.indent(depth);
            try p.writer.writeAll("else\n");
            try p.block(random.default, depth + 1);
        }
        try p.indent(depth);
        try p.writer.writeAll("end\n");
    }

    fn target(p: Printer, to: statements.Target) Writer.Error!void {
        switch (to) {
            .global => |index| try p.writer.print("{f}", .{indexed(p.names.globals, index, .global_index)}),
            .variable => |number| try p.variable(number),
            .argument => |number| try p.writer.print("arg{d}", .{number}),
        }
    }

    /// One of the game's variables, by its name where it has one.
    fn variable(p: Printer, number: u8) Writer.Error!void {
        if (vocabulary.variable(number)) |known| return p.writer.print("{t}.{s}", .{ Word.game, known });
        try p.writer.print("{t}[{d}]", .{ Word.game, number });
    }

    /// Writes `value`, where `kind` names the value a command's parameter takes, inside an
    /// operator that binds as `outer` does.
    fn expression(p: Printer, value: Expression, kind: ?vocabulary.Kind, outer: Precedence) Writer.Error!void {
        const w = p.writer;
        switch (value) {
            .number => |number| {
                if (kind) |named| {
                    if (named == .part) return w.print("{f}", .{indexed(p.names.parts, number, .part_index)});
                    if (vocabulary.name(named, number)) |text| return w.print("\"{s}\"", .{text});
                }
                try w.print("{d}", .{number});
            },
            .text => |text| try writeString(w, text),
            .ship => |index| try w.print("{f}", .{indexed(p.names.ships, index, .ship_index)}),
            .component => |component| try w.print("{t}({f}, {d})", .{ Word.component, indexed(p.names.ships, component.ship, .ship_index), component.component }),
            .flight_group => |index| try w.print("{f}", .{indexed(p.names.flight_groups, index, .flight_group_index)}),
            .squad => |index| try w.print("{f}", .{indexed(p.names.squads, index, .squad_index)}),
            .curve => |index| try w.print("{f}", .{indexed(p.names.curves, index, .curve_index)}),
            .null => try w.writeAll("nil"),
            .global => |index| try w.print("{f}", .{indexed(p.names.globals, index, .global_index)}),
            .variable => |number| try p.variable(number),
            .argument => |number| try w.print("arg{d}", .{number}),
            .local => |number| {
                if (number < p.scope.event.len) return w.writeAll(p.scope.event[number]);
                try w.print("{t}({d})", .{ Word.thread_value, number });
            },
            .event_value => |event| try p.lastEvent(event),
            .result => try w.print("{t}()", .{Word.result}),
            .binary => |binary| {
                const operator = infix(binary.operator) orelse {
                    try w.print("{t}(", .{binary.operator});
                    try p.expression(binary.left, null, .lowest);
                    try w.writeAll(", ");
                    try p.expression(binary.right, null, .lowest);
                    return w.writeByte(')');
                };
                // An operand that binds more loosely than the operator takes brackets, and on the
                // right one that binds as loosely too, since Luau groups its operators to the left.
                const own = operator.precedence;
                const bracket = @backingInt(own) <= @backingInt(outer);
                if (bracket) try w.writeByte('(');
                try p.expression(binary.left, null, @fromBackingInt(@backingInt(own) - 1));
                try w.print(" {s} ", .{operator.symbol});
                try p.expression(binary.right, null, own);
                if (bracket) try w.writeByte(')');
            },
        }
    }

    /// `last_event(object, condition, label)`: a value an object keeps of its last event, by its
    /// condition's name and the value's label where the catalogue has them.
    fn lastEvent(p: Printer, event: statements.EventValue) Writer.Error!void {
        const w = p.writer;
        try w.print("{t}({f}, ", .{ Word.last_event, p.names.object(event.object) });
        if (vocabulary.name(.condition, event.condition)) |name| try w.print("\"{s}\"", .{name}) else try w.print("{d}", .{event.condition});
        try w.writeAll(", ");
        const condition = conditions.find(event.condition);
        if (condition != null and event.value < condition.?.values.len) {
            try writeString(w, condition.?.values[event.value].label);
        } else {
            try w.print("{d}", .{event.value});
        }
        try w.writeByte(')');
    }
};

/// The kind of named value argument `index` of the command `entry` takes, where it takes one.
fn kindOf(entry: ?commands.Command, index: usize) ?vocabulary.Kind {
    const known = entry orelse return null;
    return if (index < known.params.len) vocabulary.of(known.params[index]) else null;
}

/// How tightly an operator binds in Luau, the loosest first.
const Precedence = enum(u8) { lowest, @"or", @"and", comparison, sum, product };

/// How Luau writes an operator between its operands: its symbol, and how tightly it binds.
const Infix = struct { symbol: []const u8, precedence: Precedence };

/// How Luau writes `operator` between its operands, or null for one written as a call.
fn infix(operator: Operator) ?Infix {
    return switch (operator) {
        .logical_or => .{ .symbol = "or", .precedence = .@"or" },
        .logical_and => .{ .symbol = "and", .precedence = .@"and" },
        .equal => .{ .symbol = "==", .precedence = .comparison },
        .not_equal => .{ .symbol = "~=", .precedence = .comparison },
        .greater => .{ .symbol = ">", .precedence = .comparison },
        .greater_equal => .{ .symbol = ">=", .precedence = .comparison },
        .less => .{ .symbol = "<", .precedence = .comparison },
        .less_equal => .{ .symbol = "<=", .precedence = .comparison },
        .add => .{ .symbol = "+", .precedence = .sum },
        .sub => .{ .symbol = "-", .precedence = .sum },
        .mul => .{ .symbol = "*", .precedence = .product },
        .div => .{ .symbol = "/", .precedence = .product },
        .greater_f, .greater_equal_f, .less_f, .less_equal_f, .add_f, .sub_f, .mul_f, .div_f => null,
        .in_flight_group, .not_in_flight_group, .in_squad, .not_in_squad => null,
    };
}

/// The symbol Luau writes `update` with, or null for one written as a call.
fn assignSymbol(update: Update) ?[]const u8 {
    return switch (update) {
        .assign => "=",
        .add_assign => "+=",
        .sub_assign => "-=",
        .mul_assign => "*=",
        .div_assign => "/=",
        .add_assign_f, .sub_assign_f, .mul_assign_f, .div_assign_f => null,
    };
}

/// `text` as a Luau string: printable characters as they are, and the rest escaped.
pub fn writeString(writer: *Writer, text: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (text) |byte| switch (byte) {
        '"', '\\' => try writer.print("\\{c}", .{byte}),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        else => if (std.ascii.isPrint(byte)) try writer.writeByte(byte) else try writer.print("\\x{x:0>2}", .{byte}),
    };
    try writer.writeByte('"');
}

comptime {
    // What the script writes as calls are words of the source's own, which no record takes.
    for (std.enums.values(Operator)) |operator| {
        if (infix(operator) == null) std.debug.assert(@hasField(Word, @tagName(operator)));
    }
    for (std.enums.values(Update)) |update| {
        if (assignSymbol(update) == null) std.debug.assert(@hasField(Word, @tagName(update)));
    }
}

test write {
    const executor = @import("../../../engine/game/executor.zig");
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const record_names: Names = .{
        .ships = &.{ "player_ship", "black_guard" },
        .flight_groups = &.{"alpha"},
        .squads = &.{"sabre_targets"},
        .globals = &.{"convoykilled"},
        .parts = &.{ "launch", "go_home" },
    };
    const killed: statements.Binary = .{ .operator = .equal, .left = .{ .global = 0 }, .right = .{ .number = 1 } };
    const either: statements.Binary = .{ .operator = .logical_or, .left = .{ .binary = &killed }, .right = .{ .local = 2 } };
    const both: statements.Binary = .{ .operator = .logical_and, .left = .{ .binary = &either }, .right = .result };
    const inner = [_]Statement{.{ .@"if" = .{ .condition = .result, .then = &.{}, .otherwise = &.{} } }};
    const arms = [_]statements.Random.Arm{
        .{ .threshold = 50, .extra = 7, .body = &.{.{ .call = .{ .part = 1, .arguments = &.{} } }} },
        .{ .threshold = 100, .extra = 0, .body = &.{} },
    };
    const body = [_]Statement{
        .{ .command = .{ .index = executor.commandIndex("SetAI"), .arguments = &.{ .{ .squad = 0 }, statements.testing.order(.find_new_target), .{ .number = 1 }, .null } } },
        .{ .command = .{ .index = executor.commandIndex("CreateTimer"), .arguments = &.{ .{ .number = 3 }, .{ .number = 1 }, .{ .number = 30 }, .{ .number = 1 } } } },
        .{ .command = .{ .index = 250, .arguments = &.{.{ .text = "a \"line\"\n" }} } },
        .{ .assign = .{ .target = .{ .variable = vm.Variables.number("backup_available") }, .update = .assign, .value = .{ .number = 1 } } },
        .{ .assign = .{ .target = .{ .global = 0 }, .update = .add_assign, .value = .{ .number = 1 } } },
        .{ .@"if" = .{ .condition = .{ .binary = &both }, .then = &.{.{ .spawn = .{ .part = 1, .arguments = &.{.{ .ship = 1 }} } }}, .otherwise = &inner } },
        .{ .random = .{ .arms = &arms, .default = &.{} } },
        .{ .@"return" = .{ .number = 1 } },
    };
    try write(&out.writer, &body, &record_names, .{ .event = &.{ "attacker", "shield_damage", "hull_damage" } }, 0);
    try std.testing.expectEqualStrings(
        \\SetAI(sabre_targets, "find_new_target", 1, nil)
        \\CreateTimer(3, go_home, 30, 1)
        \\command(250, "a \"line\"\n")
        \\game.backup_available = 1
        \\convoykilled += 1
        \\if (convoykilled == 1 or hull_damage) and result() then
        \\    spawn(go_home, black_guard)
        \\elseif result() then
        \\else
        \\end
        \\local roll = random()
        \\if roll < 50 then
        \\    go_home()
        \\elseif roll < 100 then
        \\end
        \\return 1
        \\
    , out.written());
}

test writeString {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeString(&out.writer, "a\\b\"c\x01\xe9");
    try std.testing.expectEqualStrings("\"a\\\\b\\\"c\\x01\\xe9\"", out.written());
}
