//! A script's instructions as text, a line each: the instruction's offset in the script, its bytes,
//! its opcode's name, and its operands, named from the mission where it names them. `sltool dte
//! script` lists a mission's routines this way, and `openreliant debug` shows the script with it.

const std = @import("std");
const Writer = std.Io.Writer;

const dte = @import("../dte.zig");
const layout = @import("../layout.zig");
const commands = @import("../../engine/game/executor/commands.zig");
const orders = @import("../../engine/game/ai/orders.zig");

/// How a listing names the Executor's commands.
pub const Commands = union(enum) {
    /// By StarLancer's names.
    starlancer,
    /// By their numbers alone, for a game whose commands differ and aren't known, such as Star
    /// Trek: Invasion.
    numbered,
    /// By another game's names, by their numbers, such as Battlestar Galactica's from its
    /// executable.
    listed: []const []const u8,
};

/// How a listing names a ship's component, which takes the model of the ship's type.
pub const Components = struct {
    context: *anyopaque,
    /// Writes the name of component `index` of `ship`, after its number.
    write: *const fn (context: *anyopaque, writer: *Writer, ship: dte.Ship, index: u8) Writer.Error!void,
};

pub const Options = struct {
    commands: Commands = .starlancer,
    /// What names the components; null to give their numbers alone.
    components: ?Components = null,
};

/// The most of an instruction's bytes a line shows: the opcode and three operands. Long inline
/// runs show as their text.
const bytes_shown = 2 + 3 * 3;

/// Writes the instructions of `listing`, a line each indented by two spaces, with the bytes
/// nothing reaches between them, and a note where a reached byte isn't an opcode. `constants` are
/// the routine's (`dte.Routine.constants`).
pub fn write(writer: *Writer, mission: dte.Mission, listing: dte.Disassembly, constants: []align(1) const u32, options: Options) Writer.Error!void {
    var previous: ?usize = null;
    for (listing.instructions, 0..) |instruction, index| {
        // A hole means the bytes between two reached instructions are not reached themselves.
        if (previous) |end| {
            if (instruction.address > end) {
                try writer.print("  {d:>6}  ... {d} bytes not reached\n", .{ end, instruction.address - end });
            }
        }
        previous = instruction.address + instruction.size();
        try writer.writeAll("  ");
        try writeInstructionAt(writer, mission, listing.instructions, index, constants, options);
        try writer.writeByte('\n');
    }
    if (listing.incomplete) try writer.writeAll("  a reached byte is not an opcode\n");
}

/// Writes `instruction`'s line, without its newline: its offset, its bytes, its opcode's name and
/// its operands.
pub fn writeInstruction(writer: *Writer, mission: dte.Mission, instruction: dte.Instruction, constants: []align(1) const u32, options: Options) Writer.Error!void {
    var bytes: [bytes_shown]u8 = undefined;
    var shown: Writer = .fixed(&bytes);
    shown.print("{x:0>2}", .{@backingInt(instruction.opcode)}) catch {};
    for (instruction.operands) |byte| shown.print(" {x:0>2}", .{byte}) catch break;
    try writer.print(std.fmt.comptimePrint("{{d:>6}}  {{s:<{d}}} ", .{bytes_shown}), .{ instruction.address, shown.buffered() });
    try layout.formatTag(dte.Opcode, instruction.opcode, writer);

    switch (instruction.flow) {
        .call => try writeIndex(writer, mission, instruction, options),
        .next => switch (instruction.opcode) {
            .push_constant, .push_constant_wide => {
                const index = instruction.constant().?;
                if (index < constants.len) {
                    try writer.print("   = {d}", .{constants[index]});
                } else {
                    try writer.writeAll("   (past the constants)");
                }
            },
            .command => try writeCommand(writer, instruction.operands[0], options.commands),
            else => try writeIndex(writer, mission, instruction, options),
        },
        .branch => |branch| try writer.print("   -> {d}{s}", .{
            branch.target, if (branch.conditional) " if zero" else "",
        }),
        .inline_data => |data| try writeInline(writer, data),
        .random => |arms| {
            var iterator = arms;
            var separator: []const u8 = "   -> ";
            while (iterator.next()) |target| {
                try writer.print("{s}{d}", .{ separator, target });
                separator = " | ";
            }
        },
        .@"return" => {},
    }
}

/// Writes instruction `index` of `instructions` as `writeInstruction` does, and where it pushes a
/// command's argument (`argumentOf`) that the listing can name, the argument's name: the order of
/// `SetAI`'s AI mode, by the developers' name for it, such as `push_byte   13  Object Attach`. Only
/// StarLancer's commands are known.
pub fn writeInstructionAt(writer: *Writer, mission: dte.Mission, instructions: []const dte.Instruction, index: usize, constants: []align(1) const u32, options: Options) Writer.Error!void {
    const instruction = instructions[index];
    try writeInstruction(writer, mission, instruction, constants, options);
    if (options.commands != .starlancer) return;
    const argument = argumentOf(instructions, index) orelse return;
    if (!std.mem.eql(u8, argument.label, ai_mode)) return;
    const number = pushedValue(instruction, constants) orelse return;
    const order: orders.Order = @fromBackingInt(std.math.cast(i16, number) orelse return);
    const info = orders.info(order) orelse return;
    if (info.name.len != 0) {
        try writer.print("  {s}", .{info.name});
    } else {
        try writer.print("  {f}", .{order});
    }
}

/// The label of the parameter that takes an order, `SetAI`'s.
const ai_mode = "AI Mode";

/// A command's parameter that a push fills: its place among the command's parameters, and its
/// label in the command catalogue.
const Argument = struct {
    param: usize,
    label: []const u8,
};

/// The parameter instruction `index` of `instructions` pushes the argument for: where the
/// instructions just before a `command`, one after another with nothing reaching in between, are
/// pushes, one for each of its parameters, the first push fills the first parameter. Null where it
/// isn't such a push, or the command isn't one of StarLancer's.
fn argumentOf(instructions: []const dte.Instruction, index: usize) ?Argument {
    if (!pushesOne(instructions[index].opcode)) return null;
    var end = index + 1;
    while (end < instructions.len and pushesOne(instructions[end].opcode) and follows(instructions, end)) end += 1;
    if (end == instructions.len or instructions[end].opcode != .command or !follows(instructions, end)) return null;
    const command = commands.find(instructions[end].operands[0]) orelse return null;
    if (end - index > command.params.len or end < command.params.len) return null;
    const first = end - command.params.len;
    for (first + 1..index + 1) |at| {
        if (!pushesOne(instructions[at - 1].opcode) or !follows(instructions, at)) return null;
    }
    const param = index - first;
    return .{ .param = param, .label = command.params[param].label };
}

/// Whether instruction `index` starts where the one before it ends, so that nothing reached from
/// elsewhere lies between them.
fn follows(instructions: []const dte.Instruction, index: usize) bool {
    const before = instructions[index - 1];
    return before.address + before.size() == instructions[index].address;
}

/// Whether `opcode` pushes one value and takes none from the stack.
fn pushesOne(opcode: dte.Opcode) bool {
    return switch (opcode) {
        .push_global, .push_constant, .push_constant_wide, .push_string, .push_string_alt, .push_ship, .push_ship_wide => true,
        .push_component, .push_component_alt, .push_flight_group, .push_squad, .push_curve, .push_section_19 => true,
        .push_byte, .push_byte_alt, .push_percent, .push_local, .push_argument, .push_null, .push_result, .push_event_value => true,
        else => false,
    };
}

/// The number `instruction` pushes, where it pushes one the listing knows: a byte, or a constant.
fn pushedValue(instruction: dte.Instruction, constants: []align(1) const u32) ?u32 {
    if (instruction.constant()) |index| return if (index < constants.len) constants[index] else null;
    return switch (instruction.opcode) {
        .push_byte, .push_byte_alt => if (instruction.operands.len == 1) instruction.operands[0] else null,
        else => null,
    };
}

/// Names command `number` as `names` has it.
fn writeCommand(writer: *Writer, number: u8, names: Commands) Writer.Error!void {
    const name: ?[]const u8 = switch (names) {
        .starlancer => if (commands.find(number)) |command| command.name else null,
        .numbered => null,
        .listed => |listed| if (number < listed.len) listed[number] else null,
    };
    if (name) |text| {
        try writer.print("   {s}", .{text});
    } else if (names != .starlancer) {
        try writer.print("   0x{X:0>2}", .{number});
    }
}

/// Shows the operand of an instruction that takes an index, and the name of what it indexes where
/// the mission holds one.
fn writeIndex(writer: *Writer, mission: dte.Mission, instruction: dte.Instruction, options: Options) Writer.Error!void {
    switch (instruction.opcode) {
        .push_component, .push_component_alt => if (instruction.operands.len == 2) {
            const index = instruction.operands[0];
            const all = mission.ships() catch &.{};
            if (index >= all.len) return writer.print("   {d}, component {d}", .{ index, instruction.operands[1] });
            try writer.print("   {d}  {s}, component {d}", .{ index, mission.name(all[index].name), instruction.operands[1] });
            if (options.components) |components| try components.write(components.context, writer, all[index], instruction.operands[1]);
            return;
        },
        else => {},
    }
    const index: u16 = switch (instruction.opcode) {
        .push_ship_wide => instruction.wide(),
        else => if (instruction.operands.len == 1) instruction.operands[0] else return,
    };
    try writer.print("   {d}", .{index});
    const name: []const u8 = switch (instruction.opcode) {
        .call_part, .spawn_part => blk: {
            const all = mission.parts() catch break :blk "";
            break :blk if (index < all.len) mission.name(all[index].name) else "";
        },
        .push_ship, .push_ship_wide => blk: {
            const all = mission.ships() catch break :blk "";
            break :blk if (index < all.len) mission.name(all[index].name) else "";
        },
        .push_global, .select_global => blk: {
            const all = mission.globals() catch break :blk "";
            break :blk if (index < all.len) mission.name(all[index].name) else "";
        },
        else => "",
    };
    if (name.len != 0) try writer.print("  {s}", .{name});
}

/// Writes an inline run as text where it is one, and as hex otherwise.
fn writeInline(writer: *Writer, data: []const u8) Writer.Error!void {
    const text = std.mem.sliceTo(data, 0);
    const printable = text.len + 1 == data.len and
        text.len != 0 and
        for (text) |c| {
            if (!std.ascii.isPrint(c)) break false;
        } else true;

    if (printable) return writer.print("   \"{s}\"", .{text});
    try writer.writeAll("  ");
    for (data) |b| try writer.print(" {x:0>2}", .{b});
}

test writeInstruction {
    var out: [128]u8 = undefined;
    var writer: Writer = .fixed(&out);
    const empty: dte.Mission = .{ .image = &.{}, .directory = &.{} };
    const script = [_]u8{ @backingInt(dte.Opcode.push_byte), 7, @backingInt(dte.Opcode.branch_if_zero), 0, 5 };
    try writeInstruction(&writer, empty, dte.decodeAt(&script, 0).?, &.{}, .{});
    try writer.writeByte('|');
    try writeInstruction(&writer, empty, dte.decodeAt(&script, 2).?, &.{}, .{});
    try std.testing.expectEqualStrings("     0  32 07       push_byte   7|     2  23 00 05    branch_if_zero   -> 8 if zero", writer.buffered());
    // A wide index is a halfword, big-endian.
    writer = .fixed(&out);
    const wide = [_]u8{ @backingInt(dte.Opcode.push_ship_wide), 1, 22, @backingInt(dte.Opcode.push_constant_wide), 0, 1 };
    try writeInstruction(&writer, empty, dte.decodeAt(&wide, 0).?, &.{}, .{});
    try writer.writeByte('|');
    try writeInstruction(&writer, empty, dte.decodeAt(&wide, 3).?, &.{ 4, 5 }, .{});
    try std.testing.expectEqualStrings("     0  52 01 16    push_ship_wide   278|     3  29 00 01    push_constant_wide   = 5", writer.buffered());
}

test writeInstructionAt {
    const empty: dte.Mission = .{ .image = &.{}, .directory = &.{} };
    const set_ai = 0x0B;
    // `SetAI` with its four arguments pushed just before it: the second is the order, 13, Object
    // Attach, which its push names.
    const script = [_]u8{
        @backingInt(dte.Opcode.push_flight_group), 20,
        @backingInt(dte.Opcode.push_byte),         13,
        @backingInt(dte.Opcode.push_constant),     0,
        @backingInt(dte.Opcode.push_null),         @backingInt(dte.Opcode.command),
        set_ai,
    };
    var instructions: [5]dte.Instruction = undefined;
    var at: usize = 0;
    for (&instructions) |*instruction| {
        instruction.* = dte.decodeAt(&script, at).?;
        at += instruction.size();
    }
    const constants = [_]u32{1};
    var out: [128]u8 = undefined;
    var writer: Writer = .fixed(&out);
    try writeInstructionAt(&writer, empty, &instructions, 1, &constants, .{});
    try std.testing.expectEqualStrings("     2  32 0d       push_byte   13  Object Attach", writer.buffered());
    // The other arguments name nothing more; nor does the order for another game's commands.
    writer = .fixed(&out);
    try writeInstructionAt(&writer, empty, &instructions, 2, &constants, .{});
    try std.testing.expectEqualStrings("     4  28 00       push_constant   = 1", writer.buffered());
    writer = .fixed(&out);
    try writeInstructionAt(&writer, empty, &instructions, 1, &constants, .{ .commands = .numbered });
    try std.testing.expectEqualStrings("     2  32 0d       push_byte   13", writer.buffered());
    // Where something else comes between the pushes and the command, the pushes fill no parameter.
    var cut = instructions;
    cut[3] = dte.decodeAt(&[_]u8{@backingInt(dte.Opcode.add)}, 0).?;
    cut[3].address = instructions[3].address;
    try std.testing.expectEqual(null, argumentOf(&cut, 1));
}
