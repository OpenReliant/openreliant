//! What `openreliant debug` knows of the mission the game plays: its file, which the game sends
//! (`link.Own.mission_file`), its script's routines and their statements, and the places its
//! breakpoints stop, which it turns into the script's flags (tag `0x09`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const dte = openreliant.dte;

/// A breakpoint, as the `break` command gives it.
pub const Breakpoint = union(enum) {
    /// Before statement `statement` of a part, the part by its number or by its name or a piece of
    /// it (`dte.Mission.findPart`); statements count from 1.
    statement: struct { part: []const u8, statement: u16 },
    /// Before the byte `offset` bytes into the script.
    offset: u32,

    /// Reads `<part>[:<statement>]` or `@<offset>`; null for anything else. Text after the last
    /// colon that isn't a number is part of the part's name. A part's text points into `text`.
    pub fn parse(text: []const u8) ?Breakpoint {
        if (text.len == 0) return null;
        if (text[0] == '@') return .{ .offset = std.fmt.parseInt(u32, text[1..], 0) catch return null };
        const whole: Breakpoint = .{ .statement = .{ .part = text, .statement = 1 } };
        const colon = std.mem.findScalarLast(u8, text, ':') orelse return whole;
        const statement = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return whole;
        if (colon == 0 or statement == 0) return null;
        return .{ .statement = .{ .part = text[0..colon], .statement = statement } };
    }

    pub fn format(breakpoint: Breakpoint, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (breakpoint) {
            .statement => |at| try writer.print("{s}:{d}", .{ at.part, at.statement }),
            .offset => |offset| try writer.print("@{d}", .{offset}),
        }
    }
};

/// Why a breakpoint has no place in the mission.
pub const Unplaced = error{ NoSuchPart, SeveralParts, NoSuchStatement, OutsideScript };

/// The mission's script, read from the mission's file.
pub const Script = struct {
    arena: std.heap.ArenaAllocator,
    mission: dte.Mission,
    code: []const u8,
    routines: []const dte.Routine,
    /// Each routine's instructions, and where its statements end, made as they are first asked
    /// for.
    listings: []?dte.Disassembly,
    statement_lists: []?[]const u32,

    /// Reads `file`, which it copies.
    pub fn init(gpa: Allocator, file: []const u8) !Script {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const mission: dte.Mission = try .parse(try allocator.dupe(u8, file));
        const routines = try mission.routines(allocator);
        const listings = try allocator.alloc(?dte.Disassembly, routines.len);
        @memset(listings, null);
        const statement_lists = try allocator.alloc(?[]const u32, routines.len);
        @memset(statement_lists, null);
        return .{
            .arena = arena,
            .mission = mission,
            .code = try mission.script(),
            .routines = routines,
            .listings = listings,
            .statement_lists = statement_lists,
        };
    }

    pub fn deinit(script: *Script) void {
        script.arena.deinit();
    }

    /// The routine that holds the byte `offset` bytes into the script; null outside them all.
    pub fn routineAt(script: *const Script, offset: u32) ?usize {
        for (script.routines, 0..) |routine, index| {
            if (offset >= routine.start and offset < routine.start + routine.extent) return index;
        }
        return null;
    }

    /// The routine of part `part`; null for a part with no block.
    pub fn partRoutine(script: *const Script, part: usize) ?usize {
        for (script.routines, 0..) |routine, index| {
            switch (routine.owner) {
                .part => |owner| if (owner == part) return index,
                .triggers => {},
            }
        }
        return null;
    }

    /// The part `text` names, by its number or by its name or a piece of it.
    pub fn findPart(script: *const Script, text: []const u8) Unplaced!usize {
        return switch (script.mission.findPart(text) catch return error.NoSuchPart) {
            .one => |index| index,
            .none => error.NoSuchPart,
            .several => error.SeveralParts,
        };
    }

    /// Routine `index`'s instructions; null where its block can't be read.
    pub fn listing(script: *Script, index: usize) Allocator.Error!?dte.Disassembly {
        if (script.listings[index]) |made| return made;
        const made = try dte.disassemble(script.arena.allocator(), script.code, script.routines[index].start) orelse return null;
        script.listings[index] = made;
        return made;
    }

    /// Whether `instruction` ends a statement, which a step stops before (`vm_starts_statement`).
    fn isStatement(instruction: dte.Instruction) bool {
        const info = instruction.opcode.info() orelse return false;
        return info.starts_statement;
    }

    /// Where routine `index`'s statements end: the offsets of the instructions that end them, in
    /// order. Null where its block can't be read.
    pub fn statements(script: *Script, index: usize) Allocator.Error!?[]const u32 {
        if (script.statement_lists[index]) |made| return made;
        const made = try script.listing(index) orelse return null;
        var ends: std.ArrayList(u32) = .empty;
        for (made.instructions) |instruction| {
            if (isStatement(instruction)) try ends.append(script.arena.allocator(), @intCast(instruction.address));
        }
        script.statement_lists[index] = ends.items;
        return ends.items;
    }

    /// The statement of routine `index` the byte `offset` lies in, counted from 1: the first whose
    /// statement instruction lies at or after it. Null past the last.
    pub fn statementAt(script: *Script, index: usize, offset: u32) Allocator.Error!?u16 {
        const ends = try script.statements(index) orelse return null;
        for (ends, 1..) |end, number| {
            if (end >= offset) return @intCast(number);
        }
        return null;
    }

    /// Where `breakpoint` stops: the offset of the byte in the script it stops before.
    pub fn place(script: *Script, breakpoint: Breakpoint) (Unplaced || Allocator.Error)!u32 {
        switch (breakpoint) {
            .offset => |offset| return if (offset < script.code.len) offset else error.OutsideScript,
            .statement => |at| {
                const part = try script.findPart(at.part);
                const index = script.partRoutine(part) orelse return error.NoSuchPart;
                const ends = try script.statements(index) orelse return error.NoSuchStatement;
                return if (at.statement <= ends.len) ends[at.statement - 1] else error.NoSuchStatement;
            },
        }
    }

    /// The script's flags as tag `0x09` sends them (`dte.Mission.scriptFlagsSize`), bit 0 set on
    /// each byte a breakpoint stops before. Breakpoints with no place in the mission are passed
    /// over. Made in `gpa`, which the caller frees.
    pub fn flags(script: *Script, gpa: Allocator, breakpoints: []const Breakpoint) Allocator.Error![]u8 {
        const bytes = try gpa.alloc(u8, script.mission.scriptFlagsSize());
        @memset(bytes, 0);
        for (breakpoints) |breakpoint| {
            const offset = script.place(breakpoint) catch |err| switch (err) {
                error.OutOfMemory => |e| {
                    gpa.free(bytes);
                    return e;
                },
                else => continue,
            };
            bytes[offset] |= openreliant.engine.vm.machine.stop_flag;
        }
        return bytes;
    }
};

test Breakpoint {
    try std.testing.expectEqual(Breakpoint{ .offset = 0x10 }, Breakpoint.parse("@0x10").?);
    const first = Breakpoint.parse("setup").?.statement;
    try std.testing.expectEqualStrings("setup", first.part);
    try std.testing.expectEqual(1, first.statement);
    const third = Breakpoint.parse("player wing:3").?.statement;
    try std.testing.expectEqualStrings("player wing", third.part);
    try std.testing.expectEqual(3, third.statement);
    // A colon not followed by a number is part of the name.
    try std.testing.expectEqualStrings("mission: setup", Breakpoint.parse("mission: setup").?.statement.part);
    for ([_][]const u8{ "", "@", "@x", "part:0", ":2" }) |wrong| try std.testing.expectEqual(null, Breakpoint.parse(wrong));
}

test Script {
    const gpa = std.testing.allocator;
    const machine = openreliant.engine.vm.machine.testing;
    const code = try machine.twoStatements(gpa);
    defer gpa.free(code);
    const image = try machine.Fixture.image(gpa, &.{ .{ .code = code }, .{ .code = code } }, .{ .globals = &.{ 0, 0 } });
    defer gpa.free(image);
    var script: Script = try .init(gpa, image);
    defer script.deinit();

    // The second part's statements are its two stores, counted from 1.
    const second = script.partRoutine(1).?;
    const start: u32 = @intCast(script.routines[second].start);
    const store = start + machine.first_instruction + machine.instructionSize(.select_global) + machine.instructionSize(.push_byte);
    try std.testing.expectEqual(store, try script.place(.{ .statement = .{ .part = "1", .statement = 1 } }));
    try std.testing.expectEqual(second, script.routineAt(store).?);
    try std.testing.expectEqual(1, (try script.statementAt(second, start)).?);
    try std.testing.expectEqual(2, (try script.statementAt(second, store + 1)).?);
    try std.testing.expectError(error.NoSuchStatement, script.place(.{ .statement = .{ .part = "1", .statement = 3 } }));
    try std.testing.expectError(error.NoSuchPart, script.place(.{ .statement = .{ .part = "7", .statement = 1 } }));
    try std.testing.expectError(error.OutsideScript, script.place(.{ .offset = 1000 }));

    // The flags stop before each placed breakpoint, and pass over the others.
    const set = try script.flags(gpa, &.{ .{ .statement = .{ .part = "1", .statement = 1 } }, .{ .offset = 1000 } });
    defer gpa.free(set);
    try std.testing.expectEqual(std.mem.alignForward(usize, script.code.len, 4), set.len);
    try std.testing.expectEqualSlices(u32, &.{ store, store + machine.instructionSize(.assign) + machine.instructionSize(.select_global) + machine.instructionSize(.push_byte) }, (try script.statements(second)).?);
    try std.testing.expectEqual(1, std.mem.count(u8, set, &.{1}));
    try std.testing.expectEqual(1, set[store]);
}
