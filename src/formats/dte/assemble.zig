//! Writing a mission's script: `Routine` builds a routine as the shipped scripts are built, a block
//! of instructions and the constant table after it, with labels for branches; `emit` writes a
//! decoded instruction back from what it means, the inverse of `dte.decodeAt`.
//! [`docs/formats/dte.md`](../../../docs/formats/dte.md#writing-the-script) describes it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dte = @import("../dte.zig");
const Opcode = dte.Opcode;
const commands = @import("../../engine/game/executor/commands.zig");
const executor = @import("../../engine/game/executor.zig");

/// A place in a routine that a branch goes to, placed once with `Routine.place`.
pub const Label = enum(u32) { _ };

/// An arm of a `random_branch`: where it goes, the roll below which it is taken, and the byte after
/// it, whose use is not known.
pub const Arm = struct {
    target: Label,
    threshold: u8,
    extra: u8 = 0,
};

pub const Error = Allocator.Error || error{
    /// An opcode given the wrong form of operands, or one the VM does not implement.
    WrongOperands,
    /// A branch to a place before it: the engine adds the displacement to the instruction pointer
    /// unsigned, so a branch only goes forward.
    BackwardBranch,
    /// A branch further than 16 bits count.
    BranchTooFar,
    /// Inline data longer than its length byte counts.
    InlineTooLong,
    /// More constants than a wide index counts.
    TooManyConstants,
    /// A label a branch goes to that was never placed.
    UnplacedLabel,
    /// A block longer than its length word counts.
    BlockTooLong,
};

/// A routine: its instructions, from the block's first, and its constants, from which the block
/// and its constant table are made (`finish`).
pub const Routine = struct {
    gpa: Allocator,
    code: std.ArrayList(u8) = .empty,
    constants: std.ArrayList(u32) = .empty,
    places: std.ArrayList(?usize) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,

    /// A displacement to fill in: at `at`, to the label's place, counted from `from`.
    const Fixup = struct { at: usize, label: Label, from: usize };

    pub fn init(gpa: Allocator) Routine {
        return .{ .gpa = gpa };
    }

    pub fn deinit(routine: *Routine) void {
        routine.code.deinit(routine.gpa);
        routine.constants.deinit(routine.gpa);
        routine.places.deinit(routine.gpa);
        routine.fixups.deinit(routine.gpa);
    }

    pub fn label(routine: *Routine) Allocator.Error!Label {
        try routine.places.append(routine.gpa, null);
        return @enumFromInt(routine.places.items.len - 1);
    }

    /// Places `at` at the next instruction.
    pub fn place(routine: *Routine, at: Label) void {
        routine.places.items[@intFromEnum(at)] = routine.code.items.len;
    }

    /// An instruction of fixed operands: `opcode` and as many operand bytes as it takes, a wide
    /// index big-endian as the engine reads it.
    pub fn op(routine: *Routine, opcode: Opcode, operands: []const u8) Error!void {
        const info = opcode.info() orelse return error.WrongOperands;
        switch (info.form) {
            .sequential, .transfer => {},
            .branch, .inline_data => return error.WrongOperands,
        }
        if (opcode == .random_branch or operands.len != info.operands) return error.WrongOperands;
        try routine.code.append(routine.gpa, @intFromEnum(opcode));
        try routine.code.appendSlice(routine.gpa, operands);
    }

    /// `branch_if_zero` or `jump` to `target`, over a big-endian displacement counted from its own
    /// place.
    pub fn branch(routine: *Routine, opcode: Opcode, target: Label) Error!void {
        const info = opcode.info() orelse return error.WrongOperands;
        if (info.form != .branch) return error.WrongOperands;
        try routine.code.append(routine.gpa, @intFromEnum(opcode));
        const at = routine.code.items.len;
        try routine.code.appendSlice(routine.gpa, &.{ 0, 0 });
        try routine.fixups.append(routine.gpa, .{ .at = at, .label = target, .from = at });
    }

    /// An instruction of inline data, such as `push_string`: a length byte that counts itself, then
    /// `data`.
    pub fn inlineData(routine: *Routine, opcode: Opcode, data: []const u8) Error!void {
        const info = opcode.info() orelse return error.WrongOperands;
        if (info.form != .inline_data) return error.WrongOperands;
        const length = std.math.cast(u8, data.len + 1) orelse return error.InlineTooLong;
        try routine.code.appendSlice(routine.gpa, &.{ @intFromEnum(opcode), length });
        try routine.code.appendSlice(routine.gpa, data);
    }

    /// `command`, calling the Executor's command `name` by its place in the catalogue
    /// (`commands.table`), which a name not in it fails to build.
    pub fn command(routine: *Routine, comptime name: []const u8) Error!void {
        try routine.op(.command, &.{executor.commandIndex(name)});
    }

    /// `push_string` of `text`, NUL-terminated.
    pub fn pushString(routine: *Routine, text: []const u8) Error!void {
        const data = try std.mem.concat(routine.gpa, u8, &.{ text, "\x00" });
        defer routine.gpa.free(data);
        try routine.inlineData(.push_string, data);
    }

    /// `random_branch`: a count, the big-endian default target, then an arm each, whose targets
    /// count from the opcode.
    pub fn randomBranch(routine: *Routine, default: Label, arms: []const Arm) Error!void {
        const count = std.math.cast(u8, arms.len) orelse return error.WrongOperands;
        const from = routine.code.items.len;
        try routine.code.appendSlice(routine.gpa, &.{ @intFromEnum(Opcode.random_branch), count });
        try routine.fixups.append(routine.gpa, .{ .at = routine.code.items.len, .label = default, .from = from });
        try routine.code.appendSlice(routine.gpa, &.{ 0, 0 });
        for (arms) |arm| {
            try routine.fixups.append(routine.gpa, .{ .at = routine.code.items.len, .label = arm.target, .from = from });
            try routine.code.appendSlice(routine.gpa, &.{ 0, 0, arm.threshold, arm.extra });
        }
    }

    /// Pushes constant `value`: the index of it in the routine's table, which it joins the first
    /// time, `push_constant` for an index a byte holds and `push_constant_wide` for a larger one.
    pub fn pushConstant(routine: *Routine, value: u32) Error!void {
        const index = std.mem.indexOfScalar(u32, routine.constants.items, value) orelse index: {
            try routine.constants.append(routine.gpa, value);
            break :index routine.constants.items.len - 1;
        };
        if (index <= std.math.maxInt(u8)) return routine.op(.push_constant, &.{@intCast(index)});
        const wide = std.math.cast(u16, index) orelse return error.TooManyConstants;
        var operands: [2]u8 = undefined;
        std.mem.writeInt(u16, &operands, wide, .big);
        try routine.op(.push_constant_wide, &operands);
    }

    /// The routine's bytes: the block's length word, which counts itself, the instructions and
    /// padding to four bytes; then the constants, padded to eight bytes. The padding is zero.
    pub fn finish(routine: *Routine) Error![]u8 {
        for (routine.fixups.items) |fixup| {
            const target = routine.places.items[@intFromEnum(fixup.label)] orelse return error.UnplacedLabel;
            if (target < fixup.from) return error.BackwardBranch;
            const displacement = std.math.cast(u16, target - fixup.from) orelse return error.BranchTooFar;
            std.mem.writeInt(u16, routine.code.items[fixup.at..][0..2], displacement, .big);
        }
        const block = std.mem.alignForward(usize, block_header + routine.code.items.len, dte.BlockReader.alignment);
        const length = std.math.cast(u16, block) orelse return error.BlockTooLong;
        const table = std.mem.alignForward(usize, routine.constants.items.len * 4, constants_alignment);
        const bytes = try routine.gpa.alloc(u8, block + table);
        @memset(bytes, 0);
        std.mem.writeInt(u16, bytes[0..2], length, .little);
        @memcpy(bytes[block_header..][0..routine.code.items.len], routine.code.items);
        for (routine.constants.items, 0..) |constant, index| std.mem.writeInt(u32, bytes[block + index * 4 ..][0..4], constant, .little);
        return bytes;
    }
};

/// The block's length word, and the size a constant table rounds up to.
const block_header = dte.BlockReader.header_len;
const constants_alignment = 8;

/// Writes `instruction` into `routine` from what it means, as a disassembly gives it: its branch
/// targets through `at`, the label placed at each address, and its inline data from its bytes.
pub fn emit(routine: *Routine, instruction: dte.Instruction, at: *const std.AutoHashMapUnmanaged(usize, Label)) Error!void {
    switch (instruction.flow) {
        .branch => |branch| try routine.branch(instruction.opcode, at.get(branch.target) orelse return error.UnplacedLabel),
        .inline_data => |data| try routine.inlineData(instruction.opcode, data),
        .random => |arms| {
            var targets = arms;
            const default = at.get(targets.next() orelse return error.WrongOperands) orelse return error.UnplacedLabel;
            var list: std.ArrayList(Arm) = .empty;
            defer list.deinit(routine.gpa);
            const header_size = @sizeOf(dte.ArmIterator.Header);
            var index: usize = 0;
            while (targets.next()) |target| : (index += 1) {
                const arm = instruction.operands[header_size + index * 4 ..][0..4];
                try list.append(routine.gpa, .{ .target = at.get(target) orelse return error.UnplacedLabel, .threshold = arm[2], .extra = arm[3] });
            }
            try routine.randomBranch(default, list.items);
        },
        .next, .call, .@"return" => try routine.op(instruction.opcode, instruction.operands),
    }
}

test Routine {
    const gpa = std.testing.allocator;
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    const other = try routine.label();
    const done = try routine.label();
    try routine.op(.push_global, &.{0});
    try routine.pushConstant(1);
    try routine.op(.equal, &.{});
    try routine.branch(.branch_if_zero, other);
    try routine.op(.call_part, &.{21});
    try routine.branch(.jump, done);
    routine.place(other);
    try routine.pushString("ms1_gull_005.ut");
    try routine.pushConstant(1);
    try routine.pushConstant(3);
    try routine.command("CommsFromPilotOnce");
    routine.place(done);
    try routine.op(.push_byte, &.{1});
    try routine.op(.@"return", &.{});
    const bytes = try routine.finish();
    defer gpa.free(bytes);

    // The block and its constants, as the game reads them.
    const block = dte.BlockReader.at(bytes, 0).?;
    try std.testing.expectEqual(0, (2 + block.code.len) % 4);
    const code = bytes[0 .. 2 + block.code.len];
    const disassembly = (try dte.disassemble(gpa, code, 0)).?;
    defer gpa.free(disassembly.instructions);
    try std.testing.expect(!disassembly.incomplete);
    try std.testing.expectEqual(0, disassembly.unreached);
    // The branch goes past the call, and the jump past the string.
    const branch = disassembly.instructions[3];
    try std.testing.expectEqual(Opcode.branch_if_zero, branch.opcode);
    try std.testing.expectEqual(Opcode.push_string, (for (disassembly.instructions) |i| {
        if (i.address == branch.flow.branch.target) break i;
    } else unreachable).opcode);
    // The command by its place in the catalogue.
    const call = disassembly.instructions[disassembly.instructions.len - 3];
    try std.testing.expectEqualStrings("CommsFromPilotOnce", commands.find(call.operands[0]).?.name);
    // Each constant once, in the table after the block, padded to eight bytes.
    const table = bytes[2 + block.code.len ..];
    try std.testing.expectEqual(8, table.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 3, 0, 0, 0 }, table);

    // A branch backwards is refused.
    var back: Routine = .init(gpa);
    defer back.deinit();
    const start = try back.label();
    back.place(start);
    try back.op(.nop, &.{});
    try back.branch(.jump, start);
    try std.testing.expectError(error.BackwardBranch, back.finish());
}

test emit {
    const gpa = std.testing.allocator;
    // A routine with every kind of instruction, written again from its disassembly.
    var routine: Routine = .init(gpa);
    defer routine.deinit();
    const second = try routine.label();
    const third = try routine.label();
    try routine.randomBranch(second, &.{.{ .target = third, .threshold = 50, .extra = 0x45 }});
    routine.place(second);
    try routine.pushString("new_sim02.wav");
    try routine.op(.push_ship_wide, &.{ 0x01, 0x02 });
    routine.place(third);
    try routine.op(.@"return", &.{});
    const bytes = try routine.finish();
    defer gpa.free(bytes);

    const block = dte.BlockReader.at(bytes, 0).?;
    const code = bytes[0 .. 2 + block.code.len];
    const disassembly = (try dte.disassemble(gpa, code, 0)).?;
    defer gpa.free(disassembly.instructions);
    var again: Routine = .init(gpa);
    defer again.deinit();
    var at: std.AutoHashMapUnmanaged(usize, Label) = .empty;
    defer at.deinit(gpa);
    for (disassembly.instructions) |instruction| try at.put(gpa, instruction.address, try again.label());
    for (disassembly.instructions) |instruction| {
        again.place(at.get(instruction.address).?);
        try emit(&again, instruction, &at);
    }
    const rewritten = try again.finish();
    defer gpa.free(rewritten);
    try std.testing.expectEqualSlices(u8, bytes, rewritten);
}
