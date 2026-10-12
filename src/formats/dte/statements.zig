//! A routine's code as statements, the shape mission source gives the script
//! ([#1127](https://github.com/OpenReliant/openreliant/issues/1127)): commands, calls, assignments,
//! `if`, random choices and `return`, over expressions. `lower` writes statements as bytecode the
//! way the developers' compiler did, and `decompile` reads them back from it.
//! [`docs/formats/dte.md`](../../../docs/formats/dte.md#statements) describes how that compiler
//! wrote them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dte = @import("../dte.zig");
const Opcode = dte.Opcode;
const assemble = @import("assemble.zig");
const commands = @import("../../engine/game/executor/commands.zig");
const conditions = @import("../../engine/vm/conditions.zig");
const executor = @import("../../engine/game/executor.zig");
const orders = @import("../../engine/game/ai/orders.zig");
const Kinds = commands.Kinds;

/// A statement of a routine. Statements and expressions borrow their slices.
pub const Statement = union(enum) {
    /// A command of the Executor's catalogue: its arguments pushed, then `command`.
    command: Command,
    /// A part called (`call_part`), its arguments pushed first.
    call: Call,
    /// A part started on a thread of its own (`spawn_part`), its arguments pushed first.
    spawn: Call,
    /// A value stored into a variable: `select_`, the value, then the store.
    assign: Assign,
    @"if": If,
    random: Random,
    /// The value pushed before `return`, which leaves the part or ends the thread.
    @"return": Expression,
};

/// A command, by its place in the catalogue (`commands.table`), the operand of `command`. It keeps
/// the arguments the script pushes, however many the command takes: 19 commands in the shipped
/// missions get fewer.
pub const Command = struct {
    index: u8,
    arguments: []const Expression,
};

/// A call of a part, by its index in the part table, the operand of `call_part` or `spawn_part`.
pub const Call = struct {
    part: u8,
    arguments: []const Expression,
};

/// An assignment: where the value goes, how it is stored, and the value.
pub const Assign = struct {
    target: Target,
    update: Update,
    value: Expression,
};

/// What an assignment stores into: a global, one of the game's variables (the array `push_array`
/// reads), or an argument of the running part.
pub const Target = union(enum) {
    global: u8,
    variable: u8,
    argument: u8,

    /// The opcode that selects it as the store target.
    pub fn select(target: Target) Opcode {
        return switch (target) {
            .global => .select_global,
            .variable => .select_array,
            .argument => .select_argument,
        };
    }

    /// Its number, the operand of its `select_` opcode.
    pub fn index(target: Target) u8 {
        return switch (target) {
            inline else => |number| number,
        };
    }
};

/// How an assignment stores its value: by its opcode's name, `assign` to set it, or an operation
/// with the old value, on whole numbers or in floating point.
pub const Update = enum {
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    add_assign_f,
    sub_assign_f,
    mul_assign_f,
    div_assign_f,

    pub fn opcode(update: Update) Opcode {
        return opcodeNamed(update);
    }

    /// The update the opcode `op` stores with, if it is a store.
    pub fn of(op: Opcode) ?Update {
        return named(Update, op);
    }
};

/// An `if`: the condition, popped by a branch over the `then` branch, and the `else` branch where
/// it has one, which may be empty.
pub const If = struct {
    condition: Expression,
    then: []const Statement,
    otherwise: ?[]const Statement,
};

/// A random choice: `random_branch` rolls a number below 100 once and runs the first arm whose
/// threshold is above it, or the default where none is.
pub const Random = struct {
    arms: []const Arm,
    default: []const Statement,

    pub const Arm = struct {
        threshold: u8,
        /// The arm's last byte, which the engine never reads.
        extra: u8,
        body: []const Statement,
    };
};

/// A value a statement pushes.
pub const Expression = union(enum) {
    /// A whole number, pushed in the form the place it is used in gives it (`Use`).
    number: u32,
    /// Text, without its NUL: a file's name, or text such as an animation's name.
    text: []const u8,
    ship: u16,
    component: Component,
    flight_group: u8,
    squad: u8,
    curve: u8,
    /// None, for a parameter that can be null: `-1` (`push_null`).
    null,
    global: u8,
    /// One of the game's variables, the array `push_array` reads.
    variable: u8,
    /// An argument of the running part.
    argument: u8,
    /// A value of the running thread: in the block a trigger runs, a value its event carries.
    local: u8,
    /// A value of the last event of a condition an object keeps (`push_event_value`).
    event_value: EventValue,
    /// The last command's result.
    result,
    /// Two values combined: compared, joined by `and` or `or`, or tested for membership.
    binary: *const Binary,
};

/// A ship's component (`push_component`): the ship, then the component, by its index among the
/// ship's components.
pub const Component = struct {
    ship: u8,
    component: u8,
};

/// The operands of `push_event_value`, in their order: the condition, the value of its event, and
/// the object, by its index.
pub const EventValue = struct {
    condition: u8,
    value: u8,
    object: u8,
};

/// Two values and the operator that combines them: `left` is pushed first.
pub const Binary = struct {
    operator: Operator,
    left: Expression,
    right: Expression,
};

/// How two values are combined: by its opcode's name.
pub const Operator = enum {
    equal,
    not_equal,
    greater,
    greater_equal,
    less,
    less_equal,
    greater_f,
    greater_equal_f,
    less_f,
    less_equal_f,
    add,
    sub,
    mul,
    div,
    add_f,
    sub_f,
    mul_f,
    div_f,
    logical_and,
    logical_or,
    in_flight_group,
    not_in_flight_group,
    in_squad,
    not_in_squad,

    pub fn opcode(operator: Operator) Opcode {
        return opcodeNamed(operator);
    }

    /// The operator the opcode `op` applies, if it combines two values.
    pub fn of(op: Opcode) ?Operator {
        return named(Operator, op);
    }
};

/// The opcode `tag` is named after, for `Update` and `Operator`.
fn opcodeNamed(tag: anytype) Opcode {
    return switch (tag) {
        inline else => |each| @field(Opcode, @tagName(each)),
    };
}

/// The tag of `Tags` named after the opcode `op`, if it has one.
fn named(comptime Tags: type, op: Opcode) ?Tags {
    return std.meta.stringToEnum(Tags, std.enums.tagName(Opcode, op) orelse return null);
}

/// What a routine's statements are lowered with.
pub const Context = struct {
    /// The values the event carries, for the block a trigger runs: how a number compared with one
    /// of them is pushed depends on its kinds.
    event: []const conditions.Value = &.{},

    /// The context of `routine` of `mission`: a trigger's block takes the values of its first
    /// trigger's condition.
    pub fn of(mission: dte.Mission, routine: dte.Routine) dte.Error!Context {
        const triggers = switch (routine.owner) {
            .triggers => |triggers| triggers,
            .part => return .{},
        };
        if (triggers.len == 0) return .{};
        const trigger = (try mission.triggers())[triggers[0]];
        const condition = trigger.condition.descriptor() orelse return .{};
        return .{ .event = condition.values };
    }

    /// The kinds of the value `expression` gives, where the context knows them.
    fn kindsOf(context: Context, expression: Expression) Kinds {
        return switch (expression) {
            .local => |index| kindsAt(context.event, index),
            .event_value => |value| kindsAt(if (conditions.find(value.condition)) |condition| condition.values else &.{}, value.value),
            else => .{},
        };
    }
};

/// The kinds of value `index` of an event's `values`, or none past them.
fn kindsAt(values: []const conditions.Value, index: u8) Kinds {
    return if (index < values.len) values[index].kinds else .{};
}

/// Where an expression's value goes, which decides how the developers' compiler pushed a number or
/// text: by the kinds of the command's parameter it is passed to, or of the value it is compared
/// with; and whether it is a routine's value.
const Use = struct {
    kinds: Kinds = .{},
    returned: bool = false,

    /// A number for a named constant, a condition or a part is a byte (`push_byte`), and so is a
    /// routine's value; one compared with a percentage is a byte too, through `push_byte_alt`. The
    /// rest are constants (`push_constant`).
    fn number(use: Use) Opcode {
        if (use.returned or use.kinds.constant or use.kinds.condition or use.kinds.part) return .push_byte;
        if (use.kinds.percentage) return .push_byte_alt;
        return .push_constant;
    }

    /// Text for a parameter of text is `push_string_alt`; a file's name is `push_string`.
    fn text(use: Use) Opcode {
        return if (use.kinds.text) .push_string_alt else .push_string;
    }
};

/// The room the developers' compiler leaves for a random choice's arms: ten, whatever their count.
/// The arms' code starts after it.
pub const arm_room = 10;

/// Why statements can't be lowered: the assembler's errors, such as a branch further than 16 bits
/// count.
pub const Error = assemble.Error;

/// Writes `body` into `routine` as the developers' compiler did.
pub fn lower(routine: *assemble.Routine, body: []const Statement, context: Context) Error!void {
    for (body) |statement| try lowerStatement(routine, statement, context);
}

/// The bytes of a routine of `body`: its block and its constant table (`assemble.Routine.finish`).
pub fn bytes(gpa: Allocator, body: []const Statement, context: Context) Error![]u8 {
    var routine: assemble.Routine = .init(gpa);
    defer routine.deinit();
    try lower(&routine, body, context);
    return routine.finish();
}

fn lowerStatement(routine: *assemble.Routine, statement: Statement, context: Context) Error!void {
    switch (statement) {
        .command => |command| {
            const params = if (commands.find(command.index)) |entry| entry.params else &.{};
            for (command.arguments, 0..) |argument, index| {
                try push(routine, argument, .{ .kinds = if (index < params.len) params[index].kinds else .{} }, context);
            }
            try routine.op(.command, &.{command.index});
        },
        .call, .spawn => |call| {
            for (call.arguments) |argument| try push(routine, argument, .{}, context);
            try routine.op(if (statement == .call) .call_part else .spawn_part, &.{call.part});
        },
        .assign => |assign| {
            try routine.op(assign.target.select(), &.{assign.target.index()});
            try push(routine, assign.value, .{}, context);
            try routine.op(assign.update.opcode(), &.{});
        },
        .@"if" => |branch| {
            try push(routine, branch.condition, .{}, context);
            const past_then = try routine.label();
            if (branch.otherwise) |otherwise| {
                const end = try routine.label();
                try routine.branch(.branch_if_zero_alt, past_then);
                try lower(routine, branch.then, context);
                try routine.branch(.jump, end);
                routine.place(past_then);
                try lower(routine, otherwise, context);
                routine.place(end);
            } else {
                try routine.branch(.branch_if_zero, past_then);
                try lower(routine, branch.then, context);
                routine.place(past_then);
            }
        },
        .random => |random| try lowerRandom(routine, random, context),
        .@"return" => |value| {
            try push(routine, value, .{ .returned = true }, context);
            try routine.op(.@"return", &.{});
        },
    }
}

/// A random choice: `random_branch` with room for `arm_room` arms, then each arm's code, ending
/// with a jump to the end unless nothing follows it, then the default's code.
fn lowerRandom(routine: *assemble.Routine, random: Random, context: Context) Error!void {
    const end = try routine.label();
    const default = if (random.default.len == 0) end else try routine.label();
    const arms = try routine.gpa.alloc(assemble.Arm, random.arms.len);
    defer routine.gpa.free(arms);
    for (arms, random.arms) |*arm, from| arm.* = .{ .target = try routine.label(), .threshold = from.threshold, .extra = from.extra };
    try routine.randomBranch(default, arms, arm_room);
    for (arms, random.arms, 0..) |arm, from, index| {
        routine.place(arm.target);
        try lower(routine, from.body, context);
        if (index + 1 < arms.len or random.default.len > 0) try routine.branch(.jump, end);
    }
    if (random.default.len > 0) {
        routine.place(default);
        try lower(routine, random.default, context);
    }
    routine.place(end);
}

/// Pushes `expression`'s value, where `use` gives how a number or text is pushed.
fn push(routine: *assemble.Routine, expression: Expression, use: Use, context: Context) Error!void {
    switch (expression) {
        .number => |value| {
            // A number too large for a byte is a constant wherever it goes.
            const opcode = use.number();
            if (opcode != .push_constant) if (std.math.cast(u8, value)) |byte| return routine.op(opcode, &.{byte});
            try routine.pushConstant(value);
        },
        .text => |text| try routine.pushText(use.text(), text),
        .ship => |ship| if (std.math.cast(u8, ship)) |short| try routine.op(.push_ship, &.{short}) else try routine.opWide(.push_ship_wide, ship),
        .component => |component| try routine.op(.push_component, &.{ component.ship, component.component }),
        .flight_group => |group| try routine.op(.push_flight_group, &.{group}),
        .squad => |squad| try routine.op(.push_squad, &.{squad}),
        .curve => |curve| try routine.op(.push_curve, &.{curve}),
        .null => try routine.op(.push_null, &.{}),
        .global => |global| try routine.op(.push_global, &.{global}),
        .variable => |variable| try routine.op(.push_array, &.{variable}),
        .argument => |argument| try routine.op(.push_argument, &.{argument}),
        .local => |local| try routine.op(.push_local, &.{local}),
        .event_value => |value| try routine.op(.push_event_value, &.{ value.condition, value.value, value.object }),
        .result => try routine.op(.push_result, &.{}),
        .binary => |binary| {
            try push(routine, binary.left, .{ .kinds = context.kindsOf(binary.right) }, context);
            try push(routine, binary.right, .{ .kinds = context.kindsOf(binary.left) }, context);
            try routine.op(binary.operator.opcode(), &.{});
        },
    }
}

/// Expressions for the tests, by name: an order, as `SetAI` takes it, and a value of an event, by
/// its label in the condition catalogue.
pub const testing = struct {
    pub fn order(which: orders.Order) Expression {
        return .{ .number = @intCast(@backingInt(which)) };
    }

    pub fn local(comptime condition: dte.Condition, comptime label: []const u8) Expression {
        const values = comptime condition.descriptor().?.values;
        inline for (values, 0..) |value, index| {
            if (comptime std.mem.eql(u8, value.label, label)) return .{ .local = index };
        }
        @compileError(label ++ " is not a value of " ++ @tagName(condition));
    }
};

comptime {
    // Each update and each operator is named after its opcode.
    @setEvalBranchQuota(10_000);
    for (std.enums.values(Update)) |update| std.debug.assert(update.opcode().isImplemented());
    for (std.enums.values(Operator)) |operator| std.debug.assert(operator.opcode().isImplemented());
}

test lower {
    const gpa = std.testing.allocator;
    const condition: Binary = .{ .operator = .equal, .left = .{ .global = 0 }, .right = .{ .number = 1 } };
    const then = [_]Statement{.{ .call = .{ .part = 21, .arguments = &.{} } }};
    const otherwise = [_]Statement{.{ .spawn = .{ .part = 24, .arguments = &.{} } }};
    const arms = [_]Random.Arm{
        .{ .threshold = 50, .extra = 0, .body = &.{.{ .call = .{ .part = 1, .arguments = &.{} } }} },
        .{ .threshold = 100, .extra = 0, .body = &.{.{ .call = .{ .part = 2, .arguments = &.{} } }} },
    };
    const body = [_]Statement{
        // SetAI's mode is a named constant, pushed as a byte, and its priority a number, pushed as a
        // constant. PlayMusic takes a file's name, and PrintDebugMessage text.
        .{ .command = .{ .index = executor.commandIndex("SetAI"), .arguments = &.{ .{ .squad = 9 }, testing.order(.find_new_target), .{ .number = 1 }, .null } } },
        .{ .command = .{ .index = executor.commandIndex("PlayMusic"), .arguments = &.{ .{ .text = "new_sim02.wav" }, .{ .number = 0 } } } },
        .{ .command = .{ .index = executor.commandIndex("PrintDebugMessage"), .arguments = &.{.{ .text = "hello" }} } },
        .{ .assign = .{ .target = .{ .global = 0 }, .update = .add_assign, .value = .{ .number = 1 } } },
        .{ .@"if" = .{ .condition = .{ .binary = &condition }, .then = &then, .otherwise = &otherwise } },
        .{ .@"if" = .{ .condition = .result, .then = &then, .otherwise = null } },
        .{ .random = .{ .arms = &arms, .default = &.{} } },
        .{ .@"return" = .{ .number = 1 } },
    };
    const routine = try bytes(gpa, &body, .{});
    defer gpa.free(routine);
    try expectOpcodes(routine, &.{
        .push_squad,    .push_byte,          .push_constant, .push_null,       .command,
        .push_string,   .push_constant,      .command,       .push_string_alt, .command,
        .select_global, .push_constant,      .add_assign,    .push_global,     .push_constant,
        .equal,         .branch_if_zero_alt, .call_part,     .jump,            .spawn_part,
        .push_result,   .branch_if_zero,     .call_part,     .random_branch,   .call_part,
        .jump,          .call_part,          .push_byte,     .@"return",
    });
    // The random choice keeps room for ten arms, and the first arm's code follows it.
    const disassembly = (try dte.disassemble(gpa, routine, 0)).?;
    defer gpa.free(disassembly.instructions);
    const random = disassembly.instructions[23];
    const first = disassembly.instructions[24];
    try std.testing.expectEqual(random.address + 1 + @sizeOf(dte.ArmIterator.Header) + @sizeOf(dte.ArmIterator.Arm) * arm_room, first.address);
    // Each constant once, in the order first pushed: 1, then 0.
    const table = routine[dte.BlockReader.header_len + dte.BlockReader.at(routine, 0).?.code.len ..];
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 0 }, table);
}

test "a number compared with a percentage is a byte" {
    const gpa = std.testing.allocator;
    const shot_at = conditions.find(@backingInt(dte.Condition.shot_at)).?;
    const hull: Binary = .{ .operator = .greater_equal, .left = testing.local(.shot_at, "Hull Damage"), .right = .{ .number = 50 } };
    const attacker: Binary = .{ .operator = .equal, .left = testing.local(.shot_at, "Attacker"), .right = .{ .number = 50 } };
    const body = [_]Statement{
        .{ .@"if" = .{ .condition = .{ .binary = &hull }, .then = &.{}, .otherwise = null } },
        .{ .@"if" = .{ .condition = .{ .binary = &attacker }, .then = &.{}, .otherwise = null } },
        .{ .@"return" = .{ .number = 1 } },
    };
    const routine = try bytes(gpa, &body, .{ .event = shot_at.values });
    defer gpa.free(routine);
    // The hull's damage is a percentage, the attacker a ship.
    try expectOpcodes(routine, &.{
        .push_local, .push_byte_alt, .greater_equal, .branch_if_zero,
        .push_local, .push_constant, .equal,         .branch_if_zero,
        .push_byte,  .@"return",
    });
}

/// Checks that the block `routine` starts with has the opcodes `expected`, in order.
fn expectOpcodes(routine: []const u8, expected: []const Opcode) !void {
    const gpa = std.testing.allocator;
    const disassembly = (try dte.disassemble(gpa, routine, 0)).?;
    defer gpa.free(disassembly.instructions);
    const opcodes = try gpa.alloc(Opcode, disassembly.instructions.len);
    defer gpa.free(opcodes);
    for (opcodes, disassembly.instructions) |*opcode, instruction| opcode.* = instruction.opcode;
    try std.testing.expectEqualSlices(Opcode, expected, opcodes);
}
