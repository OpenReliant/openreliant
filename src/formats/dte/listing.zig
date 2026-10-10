//! A script's instructions as text, a line each: the instruction's offset in the script, its bytes,
//! its opcode's name, and its operands, named from the mission where it names them. `sltool dte
//! script` lists a mission's routines this way, and `openreliant debug` shows the script with it.

const std = @import("std");
const Writer = std.Io.Writer;

const dte = @import("../dte.zig");
const layout = @import("../layout.zig");
const commands = @import("../../engine/game/executor/commands.zig");

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
    for (listing.instructions) |instruction| {
        // A hole means the bytes between two reached instructions are not reached themselves.
        if (previous) |end| {
            if (instruction.address > end) {
                try writer.print("  {d:>6}  ... {d} bytes not reached\n", .{ end, instruction.address - end });
            }
        }
        previous = instruction.address + instruction.size();
        try writer.writeAll("  ");
        try writeInstruction(writer, mission, instruction, constants, options);
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
            .push_constant => {
                const index = instruction.operands[0];
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
    if (instruction.operands.len != 1) return;
    const index = instruction.operands[0];
    try writer.print("   {d}", .{index});
    const name: []const u8 = switch (instruction.opcode) {
        .call_part, .spawn_part => blk: {
            const all = mission.parts() catch break :blk "";
            break :blk if (index < all.len) mission.name(all[index].name) else "";
        },
        .push_ship => blk: {
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
}
