//! The code of parts and triggers read from mission source into statements (`statements`), the
//! inverse of `script.write` ([The script](../../../../../docs/formats/mission-source.md#the-script)).

const std = @import("std");

const compile = @import("../compile.zig");
const Compiler = compile.Compiler;
const Error = compile.Error;
const statements = @import("../../statements.zig");
const Statement = statements.Statement;
const Expression = statements.Expression;
const commands = @import("../../../../engine/game/executor/commands.zig");
const executor = @import("../../../../engine/game/executor.zig");
const conditions = @import("../../../../engine/vm/conditions.zig");
const names = @import("../names.zig");
const Word = names.Word;
const syntax = @import("../syntax.zig");
const Index = syntax.Index;
const vocabulary = @import("../vocabulary.zig");

/// What a function's parameters stand for, by their place.
pub const Parameters = enum {
    /// The values of a trigger's event, which its thread starts with.
    event,
    /// A part's arguments.
    arguments,
};

/// The statements of the function `node`, whose parameters are `parameters`.
pub fn function(c: *Compiler, node: Index, parameters: Parameters) Error![]const Statement {
    const found = c.tree.get(node).function;
    const reader: Reader = .{ .c = c, .parameters = found.parameters, .kind = parameters };
    return reader.body(found.body);
}

const Reader = struct {
    c: *Compiler,
    /// The function's parameters, their `name` nodes.
    parameters: []const Index,
    kind: Parameters,

    fn fail(r: Reader, node: Index, comptime message: []const u8, args: anytype) Error {
        return r.c.fail(node, message, args);
    }

    fn get(r: Reader, node: Index) syntax.Syntax {
        return r.c.tree.get(node);
    }

    fn body(r: Reader, block: Index) Error![]const Statement {
        const lines = r.get(block).block;
        var list: std.ArrayList(Statement) = .empty;
        var at: usize = 0;
        while (at < lines.len) : (at += 1) {
            const line = lines[at];
            if (r.get(line) == .local) {
                // A random choice: its roll, then the `if` over its arms.
                const next = if (at + 1 < lines.len) lines[at + 1] else return r.fail(line, "a random choice's roll is followed by the `if` over its arms", .{});
                try list.append(r.c.arena, .{ .random = try r.random(line, next) });
                at += 1;
                continue;
            }
            try list.append(r.c.arena, try r.statement(line));
        }
        return list.items;
    }

    fn statement(r: Reader, line: Index) Error!Statement {
        switch (r.get(line)) {
            .call_statement => |call| return r.callStatement(call),
            .assign => |binding| {
                if (binding.targets.len != 1 or binding.values.len != 1) return r.fail(line, "an assignment sets one target to one value", .{});
                return .{ .assign = .{ .target = try r.target(binding.targets[0]), .update = .assign, .value = try r.expression(binding.values[0]) } };
            },
            .compound_assign => |assign| {
                const update: statements.Update = switch (assign.operator) {
                    .add => .add_assign,
                    .sub => .sub_assign,
                    .mul => .mul_assign,
                    .div => .div_assign,
                    else => return r.fail(line, "the script has no `{s}=`", .{assign.operator.symbol()}),
                };
                return .{ .assign = .{ .target = try r.target(assign.target), .update = update, .value = try r.expression(assign.value) } };
            },
            .@"if" => |branch| return .{ .@"if" = try r.ifStatement(branch) },
            .@"return" => |values| {
                if (values.len != 1) return r.fail(line, "`return` gives one value", .{});
                return .{ .@"return" = try r.expression(values[0]) };
            },
            .unsupported => |what| return r.fail(line, "{s}, which mission source doesn't use", .{what}),
            else => return r.fail(line, "this isn't a statement of the script", .{}),
        }
    }

    fn ifStatement(r: Reader, branch: syntax.Syntax.If) Error!statements.If {
        const otherwise: ?[]const Statement = if (branch.@"else") |node| switch (r.get(node)) {
            // `elseif`: an `else` that holds one `if`.
            .@"if" => try r.c.arena.dupe(Statement, &.{try r.statement(node)}),
            else => try r.body(node),
        } else null;
        return .{ .condition = try r.expression(branch.condition), .then = try r.body(branch.then), .otherwise = otherwise };
    }

    /// `local roll = random()` at `line`, then at `next`, an `if` that compares the roll with each
    /// arm's threshold, `roll < 50`, and runs the default in its `else`.
    fn random(r: Reader, line: Index, next: Index) Error!statements.Random {
        const binding = r.get(line).local;
        const usage = "a local holds a random choice's roll: `local roll = random()`";
        if (binding.targets.len != 1 or binding.values.len != 1) return r.fail(line, usage, .{});
        const value = binding.values[0];
        if (r.c.wordOf(value) != .random or r.get(value).call.arguments.len != 0) return r.fail(line, usage, .{});
        const roll = r.get(binding.targets[0]).name;
        var arms: std.ArrayList(statements.Random.Arm) = .empty;
        var branch_node = next;
        while (true) {
            const branch = switch (r.get(branch_node)) {
                .@"if" => |found| found,
                else => return r.fail(branch_node, "a random choice's roll is followed by the `if` over its arms", .{}),
            };
            try arms.append(r.c.arena, .{ .threshold = try r.threshold(branch.condition, roll), .extra = 0, .body = try r.body(branch.then) });
            const otherwise = branch.@"else" orelse return .{ .arms = arms.items, .default = &.{} };
            if (r.get(otherwise) != .@"if") return .{ .arms = arms.items, .default = try r.body(otherwise) };
            branch_node = otherwise;
        }
    }

    /// The threshold of an arm of a random choice, from its condition: `roll < 50`.
    fn threshold(r: Reader, node: Index, roll: syntax.Syntax.Local) Error!u8 {
        const usage = "an arm of a random choice compares the roll with its threshold, such as `{s} < 50`";
        const comparison = switch (r.get(node)) {
            .binary => |pair| pair,
            else => return r.fail(node, usage, .{roll.name}),
        };
        if (comparison.operator != .less) return r.fail(node, usage, .{roll.name});
        switch (r.get(comparison.left)) {
            .local_name => |local| if (local.number != roll.number) return r.fail(node, usage, .{roll.name}),
            else => return r.fail(node, usage, .{roll.name}),
        }
        return r.c.whole(u8, comparison.right);
    }

    fn callStatement(r: Reader, node: Index) Error!Statement {
        const call = r.get(node).call;
        switch (r.get(call.function)) {
            .global_name => |name| {
                if (executor.commandNamed(name)) |index| return .{ .command = .{ .index = index, .arguments = try r.commandArguments(index, call.arguments) } };
                if (std.meta.stringToEnum(Word, name)) |word| switch (word) {
                    .command => {
                        if (call.arguments.len == 0) return r.fail(node, "`command(...)` takes the command's number, then its arguments", .{});
                        const index = try r.c.whole(u8, call.arguments[0]);
                        return .{ .command = .{ .index = index, .arguments = try r.commandArguments(index, call.arguments[1..]) } };
                    },
                    .spawn => {
                        if (call.arguments.len == 0) return r.fail(node, "`spawn(...)` takes the part, then its arguments", .{});
                        return .{ .spawn = .{ .part = try r.part(call.arguments[0]), .arguments = try r.expressions(call.arguments[1..]) } };
                    },
                    .add_assign_f, .sub_assign_f, .mul_assign_f, .div_assign_f => {
                        if (call.arguments.len != 2) return r.fail(node, "`{t}(...)` takes its target and its value", .{word});
                        return .{ .assign = .{
                            .target = try r.target(call.arguments[0]),
                            .update = std.meta.stringToEnum(statements.Update, @tagName(word)).?,
                            .value = try r.expression(call.arguments[1]),
                        } };
                    },
                    else => return r.fail(node, "`{t}(...)` isn't a statement", .{word}),
                };
                const declared = try r.c.lookup(call.function, name);
                if (declared.kind != .part) return r.fail(call.function, "`{s}` is a {s}, which can't be called", .{ name, declared.kind.noun() });
            },
            .call => {},
            else => return r.fail(call.function, "a command or a part is called here", .{}),
        }
        return .{ .call = .{ .part = try r.part(call.function), .arguments = try r.expressions(call.arguments) } };
    }

    /// The arguments of command `index`: a name in quotes where the parameter takes a named value,
    /// such as an order, and a part by its name.
    fn commandArguments(r: Reader, index: u8, nodes: []const Index) Error![]const Expression {
        const params = if (commands.find(index)) |command| command.params else &.{};
        const list = try r.c.arena.alloc(Expression, nodes.len);
        for (list, nodes, 0..) |*argument, node, place| {
            const kind = if (place < params.len) vocabulary.of(params[place]) else null;
            argument.* = if (kind) |value_kind| switch (value_kind) {
                .part => .{ .number = try r.part(node) },
                else => if (r.get(node) == .string) .{ .number = try r.c.named(node, value_kind) } else try r.expression(node),
            } else try r.expression(node);
        }
        return list;
    }

    fn expressions(r: Reader, nodes: []const Index) Error![]const Expression {
        const list = try r.c.arena.alloc(Expression, nodes.len);
        for (list, nodes) |*item, node| item.* = try r.expression(node);
        return list;
    }

    /// A part, by its name, or by `part_index(N)` for one past the mission's parts.
    fn part(r: Reader, node: Index) Error!u8 {
        return r.c.referenceAs(u8, node, .part);
    }

    /// What an assignment stores into: a global, a part's argument, or one of the game's
    /// variables.
    fn target(r: Reader, node: Index) Error!statements.Target {
        switch (r.get(node)) {
            .global_name => |name| {
                if (names.argument(name)) |number| return .{ .argument = number };
                const declared = try r.c.lookup(node, name);
                if (declared.kind != .global) return r.fail(node, "`{s}` is a {s}, which can't be assigned", .{ name, declared.kind.noun() });
                return .{ .global = try r.c.narrow(u8, node, declared.index, "global") };
            },
            .local_name => |local| {
                const place = try r.parameter(node, local);
                if (r.kind == .event) return r.fail(node, "`{s}` is a value of the event, which can't be assigned", .{local.name});
                return .{ .argument = place };
            },
            .field, .index => return .{ .variable = try r.variable(node) },
            else => return r.fail(node, "a value is assigned to a global, a part's argument or one of the game's variables", .{}),
        }
    }

    /// The place among the function's parameters of the one that `local` names.
    fn parameter(r: Reader, node: Index, local: syntax.Syntax.Local) Error!u8 {
        for (r.parameters, 0..) |parameter_node, place| {
            if (r.get(parameter_node).name.number == local.number) return @intCast(place);
        }
        return r.fail(node, "`{s}` is a random choice's roll, which only the `if` over its arms compares", .{local.name});
    }

    /// One of the game's variables: `game.mission_over`, or `game[37]` for one without a name.
    fn variable(r: Reader, node: Index) Error!u8 {
        const object = switch (r.get(node)) {
            inline .field, .index => |found| found.object,
            else => unreachable,
        };
        if (r.get(object) != .global_name or !std.mem.eql(u8, r.get(object).global_name, @tagName(Word.game)))
            return r.fail(node, "only the game's variables are read this way: `game.mission_over` or `game[37]`", .{});
        switch (r.get(node)) {
            .field => |field| return vocabulary.variableNumber(field.name) orelse return r.fail(node, "the game has no variable `{s}`", .{field.name}),
            .index => |indexed| return r.c.whole(u8, indexed.key),
            else => unreachable,
        }
    }

    fn expression(r: Reader, node: Index) Error!Expression {
        switch (r.get(node)) {
            .number => return .{ .number = try r.c.word(node) },
            .unary => |unary| {
                if (unary.operator != .minus) return r.fail(node, "the script has no `{s}`", .{unary.operator.symbol()});
                return .{ .number = try r.c.word(node) };
            },
            .string => |text| return .{ .text = text },
            .nil => return .null,
            .global_name => |name| return r.named(node, name),
            .local_name => |local| {
                const place = try r.parameter(node, local);
                return switch (r.kind) {
                    .event => .{ .local = place },
                    .arguments => .{ .argument = place },
                };
            },
            .field, .index => return .{ .variable = try r.variable(node) },
            .call => return r.callValue(node),
            .binary => |pair| {
                const operator: statements.Operator = switch (pair.operator) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .equal => .equal,
                    .not_equal => .not_equal,
                    .less => .less,
                    .less_equal => .less_equal,
                    .greater => .greater,
                    .greater_equal => .greater_equal,
                    .@"and" => .logical_and,
                    .@"or" => .logical_or,
                    .floor_div, .mod, .pow, .concat => return r.fail(node, "the script has no `{s}`", .{pair.operator.symbol()}),
                };
                return r.binary(operator, pair.left, pair.right);
            },
            .boolean => return r.fail(node, "the script has no `true` or `false`: it compares numbers, as in `== 1`", .{}),
            .unsupported => |what| return r.fail(node, "{s}, which mission source doesn't use", .{what}),
            else => return r.fail(node, "this isn't a value of the script", .{}),
        }
    }

    fn binary(r: Reader, operator: statements.Operator, left: Index, right: Index) Error!Expression {
        const made = try r.c.arena.create(statements.Binary);
        made.* = .{ .operator = operator, .left = try r.expression(left), .right = try r.expression(right) };
        return .{ .binary = made };
    }

    /// The record a name declares, as the script pushes it, or a part's argument such as `arg0`.
    fn named(r: Reader, node: Index, name: []const u8) Error!Expression {
        if (names.argument(name)) |number| return .{ .argument = number };
        const declared = try r.c.lookup(node, name);
        const index = declared.index;
        const noun = declared.kind.noun();
        return switch (declared.kind) {
            .ship => .{ .ship = try r.c.narrow(u16, node, index, noun) },
            .flight_group => .{ .flight_group = try r.c.narrow(u8, node, index, noun) },
            .squad => .{ .squad = try r.c.narrow(u8, node, index, noun) },
            .curve => .{ .curve = try r.c.narrow(u8, node, index, noun) },
            .global => .{ .global = try r.c.narrow(u8, node, index, noun) },
            .part => r.fail(node, "`{s}` is a part, which runs as `{s}()`", .{ name, name }),
            .formation, .handler => r.fail(node, "`{s}` is a {s}, which the script doesn't name", .{ name, declared.kind.noun() }),
        };
    }

    /// A value the script gets by a call: a ship's component, a value of the thread or of an
    /// object's last event, the last command's result, a record by its index, or an operator
    /// written as a call.
    fn callValue(r: Reader, node: Index) Error!Expression {
        const word = r.c.wordOf(node) orelse return r.fail(node, "this call isn't a value of the script", .{});
        const arguments = r.get(node).call.arguments;
        switch (word) {
            .result => {
                if (arguments.len != 0) return r.fail(node, "`result()` takes nothing", .{});
                return .result;
            },
            .component => {
                if (arguments.len != 2) return r.fail(node, "`component(...)` takes the ship and the component's index", .{});
                return .{ .component = .{ .ship = try r.c.referenceAs(u8, arguments[0], .ship), .component = try r.c.whole(u8, arguments[1]) } };
            },
            .thread_value => return .{ .local = try r.c.whole(u8, try r.only(node, arguments, "the value's place")) },
            .last_event => return .{ .event_value = try r.lastEvent(node, arguments) },
            .ship_index => return .{ .ship = try r.c.whole(u16, try r.only(node, arguments, "the ship's index")) },
            .flight_group_index => return .{ .flight_group = try r.c.whole(u8, try r.only(node, arguments, "the flight group's index")) },
            .squad_index => return .{ .squad = try r.c.whole(u8, try r.only(node, arguments, "the squad's index")) },
            .curve_index => return .{ .curve = try r.c.whole(u8, try r.only(node, arguments, "the curve's index")) },
            .global_index => return .{ .global = try r.c.whole(u8, try r.only(node, arguments, "the global's index")) },
            .greater_f, .greater_equal_f, .less_f, .less_equal_f, .add_f, .sub_f, .mul_f, .div_f, .in_flight_group, .not_in_flight_group, .in_squad, .not_in_squad => {
                if (arguments.len != 2) return r.fail(node, "`{t}(...)` takes two values", .{word});
                return r.binary(std.meta.stringToEnum(statements.Operator, @tagName(word)).?, arguments[0], arguments[1]);
            },
            else => return r.fail(node, "`{t}(...)` isn't a value of the script", .{word}),
        }
    }

    /// The one argument of the call `node`, which is `what`.
    fn only(r: Reader, node: Index, arguments: []const Index, comptime what: []const u8) Error!Index {
        if (arguments.len != 1) return r.fail(node, "this takes " ++ what, .{});
        return arguments[0];
    }

    /// `last_event(object, condition, value)`: the object, the condition by its name, and the
    /// value of its event by its label in the condition catalogue, or each by its number.
    fn lastEvent(r: Reader, node: Index, arguments: []const Index) Error!statements.EventValue {
        if (arguments.len != 3) return r.fail(node, "`last_event(...)` takes the object, the condition and the value", .{});
        const condition = try r.c.narrow(u8, arguments[1], try r.c.named(arguments[1], .condition), "condition");
        const value: u8 = switch (r.get(arguments[2])) {
            .string => |label| value: {
                const values = if (conditions.find(condition)) |found| found.values else &.{};
                for (values, 0..) |entry, place| {
                    if (std.mem.eql(u8, entry.label, label)) break :value @intCast(place);
                }
                return r.fail(arguments[2], "the condition's event has no value \"{s}\"", .{label});
            },
            else => try r.c.whole(u8, arguments[2]),
        };
        const object = try r.c.objectOf(arguments[0]);
        return .{ .condition = condition, .value = value, .object = try r.c.narrow(u8, arguments[0], object, "object") };
    }
};
