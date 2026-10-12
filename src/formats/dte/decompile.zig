//! Reading a routine's bytecode as statements (`statements`), the inverse of `statements.lower`
//! ([#1127](https://github.com/OpenReliant/openreliant/issues/1127)). The developers' compiler
//! wrote each statement as pushes, then the instruction that takes them: `command`, a call, a
//! store, `return`, or the branch of an `if` or a random choice. `routine` follows that shape
//! through the disassembly, and fails where the code has another.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dte = @import("../dte.zig");
const layout = @import("../layout.zig");
const statements = @import("statements.zig");
const executor = @import("../../engine/game/executor.zig");
const Statement = statements.Statement;
const Expression = statements.Expression;

pub const Error = Allocator.Error || error{
    /// There is no block where the routine starts.
    NoBlock,
    /// A byte the code reaches isn't an instruction, or a constant lies past the script.
    Undecodable,
    /// The branches don't nest as an `if`'s or a random choice's do.
    Unstructured,
    /// An instruction no statement holds, such as `nop`, or values a statement doesn't take.
    Unrepresentable,
};

/// The statements of `of`, a routine of `mission`, allocated with `arena`.
pub fn routine(arena: Allocator, mission: dte.Mission, of: dte.Routine) (Error || dte.Error)![]const Statement {
    return block(arena, try mission.script(), of.start);
}

/// The statements of the block at `start` in `script`, allocated with `arena`.
pub fn block(arena: Allocator, script: []const u8, start: usize) Error![]const Statement {
    const disassembly = try dte.disassemble(arena, script, start) orelse return error.NoBlock;
    if (disassembly.incomplete or disassembly.instructions.len == 0) return error.Undecodable;
    const reader = dte.BlockReader.at(script, start).?;
    var decompiler: Decompiler = .{
        .arena = arena,
        .script = script,
        .instructions = disassembly.instructions,
        .constants = start + dte.BlockReader.header_len + reader.code.len,
    };
    return decompiler.until(std.math.maxInt(usize));
}

/// What a statement's pushes leave on the stack: values, and the target a `select_` opcode chose
/// for the store after them.
const Entry = union(enum) {
    value: Expression,
    target: statements.Target,
};

const Decompiler = struct {
    arena: Allocator,
    script: []const u8,
    /// The block's instructions that its code reaches, in address order.
    instructions: []const dte.Instruction,
    /// Where the block's constant table starts in the script.
    constants: usize,
    /// The next instruction to read.
    next: usize = 0,

    /// The statements up to the instruction at `end`.
    fn until(d: *Decompiler, end: usize) Error![]const Statement {
        var list: std.ArrayList(Statement) = .empty;
        while (d.next < d.instructions.len and d.instructions[d.next].address < end) {
            try list.append(d.arena, try d.statement());
        }
        return list.toOwnedSlice(d.arena);
    }

    /// The address of the next instruction, or the end of the last one.
    fn at(d: Decompiler) usize {
        if (d.next < d.instructions.len) return d.instructions[d.next].address;
        const last = d.instructions[d.instructions.len - 1];
        return last.address + last.size();
    }

    /// The instruction that ends where `address` starts.
    fn before(d: Decompiler, address: usize) ?dte.Instruction {
        for (d.instructions) |instruction| {
            if (instruction.address + instruction.size() == address) return instruction;
        }
        return null;
    }

    /// The next statement: pushes, then the instruction that takes them.
    fn statement(d: *Decompiler) Error!Statement {
        var stack: std.ArrayList(Entry) = .empty;
        while (d.next < d.instructions.len) {
            const instruction = d.instructions[d.next];
            d.next += 1;
            if (try d.leaf(instruction)) |pushed| {
                try stack.append(d.arena, .{ .value = pushed });
                continue;
            }
            if (statements.Operator.of(instruction.opcode)) |operator| {
                const right = try pop(&stack);
                const left = try pop(&stack);
                const binary = try d.arena.create(statements.Binary);
                binary.* = .{ .operator = operator, .left = left, .right = right };
                try stack.append(d.arena, .{ .value = .{ .binary = binary } });
                continue;
            }
            if (statements.Update.of(instruction.opcode)) |update| {
                if (stack.items.len != 2) return error.Unrepresentable;
                const target = switch (stack.items[0]) {
                    .target => |target| target,
                    .value => return error.Unrepresentable,
                };
                return .{ .assign = .{ .target = target, .update = update, .value = try pop(&stack) } };
            }
            const operand = if (instruction.operands.len > 0) instruction.operands[0] else 0;
            switch (instruction.opcode) {
                .select_global => try stack.append(d.arena, .{ .target = .{ .global = operand } }),
                .select_array => try stack.append(d.arena, .{ .target = .{ .variable = operand } }),
                .select_argument => try stack.append(d.arena, .{ .target = .{ .argument = operand } }),
                .command => return .{ .command = .{ .index = operand, .arguments = try d.values(stack.items) } },
                .call_part => return .{ .call = .{ .part = operand, .arguments = try d.values(stack.items) } },
                .spawn_part => return .{ .spawn = .{ .part = operand, .arguments = try d.values(stack.items) } },
                .@"return", .return_alt => return .{ .@"return" = try only(stack.items) },
                .branch_if_zero, .branch_if_zero_alt => return d.ifStatement(instruction, try only(stack.items)),
                .random_branch => {
                    if (stack.items.len > 0) return error.Unrepresentable;
                    return d.random(instruction);
                },
                .jump => return error.Unstructured,
                else => return error.Unrepresentable,
            }
        }
        return error.Unrepresentable;
    }

    /// The value `instruction` pushes, if it pushes one of its own.
    fn leaf(d: Decompiler, instruction: dte.Instruction) Error!?Expression {
        const operands = instruction.operands;
        return switch (instruction.opcode) {
            .push_constant, .push_constant_wide => .{ .number = try d.constant(instruction.constant().?) },
            .push_byte, .push_byte_alt => .{ .number = operands[0] },
            .push_string, .push_string_alt => .{ .text = try text(instruction.flow.inline_data) },
            .push_ship => .{ .ship = operands[0] },
            .push_ship_wide => .{ .ship = instruction.wide() },
            .push_component, .push_component_alt => .{ .component = .{ .ship = operands[0], .component = operands[1] } },
            .push_flight_group => .{ .flight_group = operands[0] },
            .push_squad => .{ .squad = operands[0] },
            .push_curve => .{ .curve = operands[0] },
            .push_null => .null,
            .push_global => .{ .global = operands[0] },
            .push_array => .{ .variable = operands[0] },
            .push_argument => .{ .argument = operands[0] },
            .push_local => .{ .local = operands[0] },
            .push_event_value => .{ .event_value = .{ .condition = operands[0], .value = operands[1], .object = operands[2] } },
            .push_result => .result,
            else => null,
        };
    }

    /// Constant `index` of the block's table.
    fn constant(d: Decompiler, index: u16) Error!u32 {
        const place = d.constants + @as(usize, index) * @sizeOf(u32);
        if (place + @sizeOf(u32) > d.script.len) return error.Undecodable;
        return std.mem.readInt(u32, d.script[place..][0..4], .little);
    }

    /// The stack's values, as a statement's arguments.
    fn values(d: Decompiler, entries: []const Entry) Error![]const Expression {
        const list = try d.arena.alloc(Expression, entries.len);
        for (list, entries) |*item, entry| item.* = switch (entry) {
            .value => |each| each,
            .target => return error.Unrepresentable,
        };
        return list;
    }

    /// An `if`: a `branch_if_zero` over its `then` branch, or a `branch_if_zero_alt` over its
    /// `then` branch, which ends with a jump past the `else` branch.
    fn ifStatement(d: *Decompiler, branch: dte.Instruction, condition: Expression) Error!Statement {
        const past_then = branch.flow.branch.target;
        if (branch.opcode == .branch_if_zero) {
            const then = try d.until(past_then);
            if (d.at() != past_then) return error.Unstructured;
            return .{ .@"if" = .{ .condition = condition, .then = then, .otherwise = null } };
        }
        const jump = d.before(past_then) orelse return error.Unstructured;
        if (jump.opcode != .jump) return error.Unstructured;
        const end = jump.flow.branch.target;
        const then = try d.until(jump.address);
        if (d.at() != jump.address) return error.Unstructured;
        d.next += 1;
        const otherwise = try d.until(end);
        if (d.at() != end) return error.Unstructured;
        return .{ .@"if" = .{ .condition = condition, .then = then, .otherwise = otherwise } };
    }

    /// A random choice: the arms' code in their order, each ending with a jump to the end where
    /// more code follows it, then the default's, where it has any.
    fn random(d: *Decompiler, instruction: dte.Instruction) Error!Statement {
        const header = layout.view(dte.ArmIterator.Header, instruction.operands) catch return error.Undecodable;
        const fields = layout.array(dte.ArmIterator.Arm, instruction.operands[@sizeOf(dte.ArmIterator.Header)..], header.count) catch return error.Undecodable;
        if (fields.len == 0) return error.Unrepresentable;
        var targets = instruction.flow.random;
        const default = targets.next() orelse return error.Undecodable;
        const starts = try d.arena.alloc(usize, fields.len);
        for (starts) |*start| start.* = targets.next() orelse return error.Undecodable;
        const arms = try d.arena.alloc(statements.Random.Arm, fields.len);
        var end: ?usize = null;
        for (arms, fields, starts, 0..) |*arm, field, start, index| {
            if (d.at() != start) return error.Unstructured;
            const last = index + 1 == starts.len;
            const next = if (last) default else starts[index + 1];
            const closing = d.before(next);
            // Every arm but the last jumps to the end, and the last one does where the default has
            // code. Where the last arm ends with a jump to its own end, that jump belongs to an
            // `if` with an empty `else` inside the arm.
            const jumps = !last or (end orelse jumpPast(closing, default) orelse default) != default;
            var body: []const Statement = undefined;
            if (jumps) {
                const jump = closing orelse return error.Unstructured;
                if (jump.opcode != .jump or jump.flow.branch.target < next) return error.Unstructured;
                const target = jump.flow.branch.target;
                if (end) |known| if (known != target) return error.Unstructured;
                end = target;
                body = try d.until(jump.address);
                if (d.at() != jump.address) return error.Unstructured;
                d.next += 1;
            } else {
                body = try d.until(next);
                if (d.at() != next) return error.Unstructured;
                end = next;
            }
            arm.* = .{ .threshold = field.threshold, .extra = field._unknown_3, .body = body };
        }
        var otherwise: []const Statement = &.{};
        if (end.? != default) {
            if (d.at() != default) return error.Unstructured;
            otherwise = try d.until(end.?);
            if (d.at() != end.?) return error.Unstructured;
        }
        return .{ .random = .{ .arms = arms, .default = otherwise } };
    }
};

/// The target of `instruction`, if it is a jump past `address`.
fn jumpPast(instruction: ?dte.Instruction, address: usize) ?usize {
    const jump = instruction orelse return null;
    if (jump.opcode != .jump or jump.flow.branch.target <= address) return null;
    return jump.flow.branch.target;
}

/// The top of the stack, which must be a value.
fn pop(stack: *std.ArrayList(Entry)) Error!Expression {
    return switch (stack.pop() orelse return error.Unrepresentable) {
        .value => |value| value,
        .target => error.Unrepresentable,
    };
}

/// The one value a statement takes.
fn only(entries: []const Entry) Error!Expression {
    if (entries.len != 1) return error.Unrepresentable;
    return switch (entries[0]) {
        .value => |value| value,
        .target => error.Unrepresentable,
    };
}

/// Inline text without its NUL, which a statement's text always ends with.
fn text(data: []const u8) Error![]const u8 {
    if (data.len == 0 or data[data.len - 1] != 0) return error.Unrepresentable;
    return data[0 .. data.len - 1];
}

/// Statements built by hand, lowered, then read back: the same statements, and lowered again, the
/// same bytes.
fn expectRoundTrip(body: []const Statement, context: statements.Context) !void {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try statements.bytes(gpa, body, context);
    defer gpa.free(bytes);
    const read = try block(arena, bytes, 0);
    try std.testing.expectEqualDeep(body, read);
    const again = try statements.bytes(gpa, read, context);
    defer gpa.free(again);
    try std.testing.expectEqualSlices(u8, bytes, again);
}

test block {
    const killed: statements.Binary = .{ .operator = .equal, .left = .{ .global = 0 }, .right = .{ .number = 1 } };
    const ready: statements.Binary = .{ .operator = .logical_and, .left = .{ .variable = 3 }, .right = .{ .binary = &killed } };
    const inner = [_]Statement{.{ .@"if" = .{ .condition = .result, .then = &.{.{ .call = .{ .part = 2, .arguments = &.{} } }}, .otherwise = &.{} } }};
    const arms = [_]statements.Random.Arm{
        .{ .threshold = 30, .extra = 0, .body = &.{.{ .call = .{ .part = 1, .arguments = &.{} } }} },
        .{ .threshold = 60, .extra = 0x45, .body = &inner },
        .{ .threshold = 100, .extra = 0, .body = &.{} },
    };
    // One arm, whose `if` ends where the choice does: its jump isn't the arm's.
    const alone = [_]statements.Random.Arm{.{ .threshold = 50, .extra = 0, .body = &inner }};
    const body = [_]Statement{
        .{ .command = .{ .index = executor.commandIndex("SetAI"), .arguments = &.{ .{ .ship = 300 }, .{ .number = 10 }, .{ .number = 1 }, .{ .component = .{ .ship = 4, .component = 2 } } } } },
        .{ .command = .{ .index = executor.commandIndex("CommsFromShip"), .arguments = &.{ .{ .flight_group = 1 }, .{ .number = 1 }, .{ .text = "ms1_gull_005.ut" } } } },
        .{ .assign = .{ .target = .{ .variable = 3 }, .update = .assign, .value = .{ .number = 0x12345678 } } },
        .{ .@"if" = .{ .condition = .{ .binary = &ready }, .then = &.{.{ .spawn = .{ .part = 5, .arguments = &.{.{ .argument = 0 }} } }}, .otherwise = &inner } },
        .{ .random = .{ .arms = &arms, .default = &.{} } },
        .{ .random = .{ .arms = arms[0..1], .default = &.{.{ .call = .{ .part = 3, .arguments = &.{} } }} } },
        .{ .random = .{ .arms = &alone, .default = &.{} } },
        .{ .@"return" = .{ .number = 1 } },
    };
    try expectRoundTrip(&body, .{});
}

test "a command keeps the arguments the script pushes" {
    // `StartDirectorCam` takes five, and some of the shipped missions push four.
    const body = [_]Statement{
        .{ .command = .{ .index = executor.commandIndex("StartDirectorCam"), .arguments = &.{ .{ .curve = 0 }, .{ .ship = 6 }, .{ .number = 8 }, .null } } },
        .{ .@"return" = .{ .number = 1 } },
    };
    try expectRoundTrip(&body, .{});
}

test "code of another shape is refused" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A jump outside an `if`.
    var routine_state: @import("assemble.zig").Routine = .init(gpa);
    defer routine_state.deinit();
    const end = try routine_state.label();
    try routine_state.branch(.jump, end);
    routine_state.place(end);
    try routine_state.op(.push_byte, &.{1});
    try routine_state.op(.@"return", &.{});
    const jumps = try routine_state.finish();
    defer gpa.free(jumps);
    try std.testing.expectError(error.Unstructured, block(arena, jumps, 0));
    // A value left over before `return`, and a `nop`.
    const left = [_]u8{ 8, 0, 0x32, 1, 0x32, 1, 0x43, 0 };
    try std.testing.expectError(error.Unrepresentable, block(arena, &left, 0));
    const nop = [_]u8{ 8, 0, 0x53, 0x32, 1, 0x43, 0, 0 };
    try std.testing.expectError(error.Unrepresentable, block(arena, &nop, 0));
}
