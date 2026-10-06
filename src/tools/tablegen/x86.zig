//! The slice of x86 that the mission script VM's opcode handlers are built from.
//!
//! Handlers are short, straight-line and compiler-generated, so a full decoder is not needed: this
//! parses Ghidra's exported textual disassembly into just enough structure for
//! [`eval`](../eval.zig) to follow what each one does to the instruction pointer.

const std = @import("std");

/// A 32-bit general register. Only the eight the handlers use are named.
pub const Register = enum {
    eax,
    ecx,
    edx,
    ebx,
    esp,
    ebp,
    esi,
    edi,

    /// The 32-bit register a byte register aliases, and which half it occupies.
    pub const Byte = struct { register: Register, high: bool };

    pub fn parse(text: []const u8) ?Register {
        var lowered: [3]u8 = undefined;
        if (text.len != 3) return null;
        for (text, &lowered) |c, *out| out.* = std.ascii.toLower(c);
        return std.meta.stringToEnum(Register, &lowered);
    }

    /// Parses `AL`, `DH` and friends into the register they alias.
    pub fn parseByte(text: []const u8) ?Byte {
        if (text.len != 2) return null;
        const letter = std.ascii.toLower(text[0]);
        const half = std.ascii.toLower(text[1]);
        const register: Register = switch (letter) {
            'a' => .eax,
            'b' => .ebx,
            'c' => .ecx,
            'd' => .edx,
            else => return null,
        };
        return switch (half) {
            'l' => .{ .register = register, .high = false },
            'h' => .{ .register = register, .high = true },
            else => null,
        };
    }
};

/// An effective address, `base + index * scale + displacement`.
///
/// Any component may be absent: an absolute address is displacement only, and a bare `[EAX]` is
/// base only.
pub const Address = struct {
    base: ?Register = null,
    index: ?Register = null,
    scale: u8 = 1,
    displacement: i64 = 0,
    /// Bytes touched: 1, 2 or 4. Ghidra spells this as the `byte ptr` / `word ptr` prefix.
    width: u8 = 4,
};

/// Where an instruction reads from or writes to.
pub const Operand = union(enum) {
    register: Register,
    /// A byte register, which writes only one half of its 32-bit parent.
    byte_register: Register.Byte,
    memory: Address,
    immediate: i64,
    /// Anything this module does not model, such as an x87 or string operand.
    other,
};

/// The operations that matter to the instruction-pointer analysis. Everything else becomes
/// [`opaque_op`](#opaque_op), which clobbers its destination rather than being ignored.
pub const Mnemonic = enum {
    mov,
    lea,
    add,
    sub,
    inc,
    dec,
    xor,
    @"and",
    neg,
    shl,
    push,
    pop,
    call,
    ret,
    jmp,
    /// Any conditional jump. Which condition does not matter: both edges are explored.
    jcc,
    /// Modelled only as "destination becomes unknown".
    opaque_op,
};

pub const Instruction = struct {
    address: u32,
    mnemonic: Mnemonic,
    destination: ?Operand = null,
    source: ?Operand = null,
    /// Target of `jmp`, `jcc` and `call`.
    target: ?u32 = null,
};

/// One named function from the export, as a flat instruction list.
pub const Function = struct {
    name: []const u8,
    address: u32,
    instructions: []const Instruction,

    /// Index of the instruction at `address`, or null when it is not in this function.
    pub fn indexOf(self: Function, address: u32) ?usize {
        for (self.instructions, 0..) |instruction, i| {
            if (instruction.address == address) return i;
        }
        return null;
    }
};

const conditional_jumps = [_][]const u8{
    "JZ", "JNZ", "JC", "JNC", "JS", "JNS", "JO", "JNO",
    "JA", "JAE", "JB", "JBE", "JG", "JGE", "JL", "JLE",
    "JP", "JNP", "JE", "JNE",
};

fn mnemonicOf(text: []const u8) Mnemonic {
    const simple = std.StaticStringMap(Mnemonic).initComptime(.{
        .{ "MOV", .mov },   .{ "LEA", .lea }, .{ "ADD", .add },   .{ "SUB", .sub },
        .{ "INC", .inc },   .{ "DEC", .dec }, .{ "XOR", .xor },   .{ "AND", .@"and" },
        .{ "NEG", .neg },   .{ "SHL", .shl }, .{ "PUSH", .push }, .{ "POP", .pop },
        .{ "CALL", .call }, .{ "RET", .ret }, .{ "JMP", .jmp },
    });
    if (simple.get(text)) |mnemonic| return mnemonic;
    for (conditional_jumps) |name| {
        if (std.mem.eql(u8, name, text)) return .jcc;
    }
    return .opaque_op;
}

/// Splits `A, B` at the comma that separates operands, ignoring commas inside brackets.
fn splitOperands(text: []const u8) struct { []const u8, ?[]const u8 } {
    var depth: usize = 0;
    for (text, 0..) |c, i| {
        switch (c) {
            '[' => depth += 1,
            ']' => depth -|= 1,
            ',' => if (depth == 0) return .{
                std.mem.trim(u8, text[0..i], " "),
                std.mem.trim(u8, text[i + 1 ..], " "),
            },
            else => {},
        }
    }
    return .{ std.mem.trim(u8, text, " "), null };
}

fn parseNumber(text: []const u8) ?i64 {
    const negative = text.len > 0 and text[0] == '-';
    const body = if (negative) text[1..] else text;
    const digits = if (std.mem.startsWith(u8, body, "0x")) body[2..] else return null;
    const value = std.fmt.parseInt(i64, digits, 16) catch return null;
    return if (negative) -value else value;
}

fn parseAddress(text: []const u8, width: u8) ?Address {
    const open = std.mem.findScalar(u8, text, '[') orelse return null;
    const close = std.mem.findScalarLast(u8, text, ']') orelse return null;
    if (close < open) return null;

    var address: Address = .{ .width = width };
    var terms = std.mem.tokenizeScalar(u8, text[open + 1 .. close], '+');
    while (terms.next()) |raw| {
        const term = std.mem.trim(u8, raw, " ");
        if (term.len == 0) continue;
        if (std.mem.findScalar(u8, term, '*')) |star| {
            // `EAX*0x4`: an index term.
            address.index = Register.parse(std.mem.trim(u8, term[0..star], " ")) orelse return null;
            const scale = parseNumber(std.mem.trim(u8, term[star + 1 ..], " ")) orelse return null;
            address.scale = std.math.cast(u8, scale) orelse return null;
        } else if (Register.parse(term)) |register| {
            if (address.base == null) address.base = register else address.index = register;
        } else if (parseNumber(term)) |value| {
            address.displacement += value;
        } else return null;
    }
    return address;
}

fn parseOperand(text: []const u8) Operand {
    const widths = .{
        .{ "byte ptr", @as(u8, 1) },
        .{ "word ptr", @as(u8, 2) },
        .{ "dword ptr", @as(u8, 4) },
        .{ "qword ptr", @as(u8, 8) },
    };
    inline for (widths) |entry| {
        if (std.mem.startsWith(u8, text, entry[0])) {
            const rest = std.mem.trim(u8, text[entry[0].len..], " ");
            if (entry[1] > 4) return .other;
            return if (parseAddress(rest, entry[1])) |address| .{ .memory = address } else .other;
        }
    }
    if (Register.parse(text)) |register| return .{ .register = register };
    if (Register.parseByte(text)) |byte| return .{ .byte_register = byte };
    if (std.mem.findScalar(u8, text, '[') != null) {
        // A bare `[0x00537570]`: Ghidra omits the size prefix on some absolute moves.
        return if (parseAddress(text, 4)) |address| .{ .memory = address } else .other;
    }
    if (parseNumber(text)) |value| return .{ .immediate = value };
    return .other;
}

/// A line of an `ExportProgram.java` disassembly listing.
pub const Line = union(enum) {
    /// `; ==== <name> @ <address> ====`, which starts a function.
    banner: Banner,
    /// `<address> <bytes> <mnemonic> <operands>`: an instruction.
    instruction: Encoded,
    /// Anything else, such as a blank line.
    other,

    pub const Banner = struct { name: []const u8, address: u32 };

    pub const Encoded = struct {
        address: u32,
        /// Its encoding, in hex.
        bytes: []const u8,
        /// Its mnemonic and its operands.
        text: []const u8,
    };

    const banner_start = "; ==== ";
    const banner_address = " @ ";

    /// What `line`, without its line end, is. A banner without a name and an address is an error.
    pub fn parse(line: []const u8) error{BadBanner}!Line {
        if (std.mem.startsWith(u8, line, banner_start)) {
            const body = line[banner_start.len..];
            const at = std.mem.findLast(u8, body, banner_address) orelse return error.BadBanner;
            const start = at + banner_address.len;
            const end = std.mem.findScalarPos(u8, body, start, ' ') orelse body.len;
            const address = std.fmt.parseInt(u32, body[start..end], 16) catch return error.BadBanner;
            return .{ .banner = .{ .name = body[0..at], .address = address } };
        }
        const address_digits = 8;
        if (line.len < address_digits) return .other;
        const address = std.fmt.parseInt(u32, line[0..address_digits], 16) catch return .other;
        var fields = std.mem.tokenizeAny(u8, line[address_digits..], " \t");
        const bytes = fields.next() orelse return .other;
        return .{ .instruction = .{ .address = address, .bytes = bytes, .text = fields.rest() } };
    }
};

/// Walks a listing a line at a time.
pub const Lines = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn init(listing: []const u8) Lines {
        return .{ .lines = std.mem.splitScalar(u8, listing, '\n') };
    }

    pub fn next(lines: *Lines) error{BadBanner}!?Line {
        const raw = lines.lines.next() orelse return null;
        return try Line.parse(std.mem.trimEnd(u8, raw, "\r"));
    }
};

/// Parses one `<address> <bytes> <mnemonic> <operands>` line, or null when the line is not one.
pub fn parseLine(line: []const u8) ?Instruction {
    return switch (Line.parse(line) catch return null) {
        .instruction => |encoded| decode(encoded),
        .banner, .other => null,
    };
}

/// The instruction an instruction line holds.
fn decode(encoded: Line.Encoded) Instruction {
    var fields = std.mem.tokenizeAny(u8, encoded.text, " \t");
    const mnemonic_text = fields.next() orelse return .{ .address = encoded.address, .mnemonic = .ret };
    const rest = std.mem.trim(u8, fields.rest(), " \t\r");

    const mnemonic = mnemonicOf(mnemonic_text);
    var instruction: Instruction = .{ .address = encoded.address, .mnemonic = mnemonic };
    switch (mnemonic) {
        .jmp, .jcc, .call => instruction.target = blk: {
            const value = parseNumber(rest) orelse break :blk null;
            break :blk std.math.cast(u32, value);
        },
        .ret => {},
        else => {
            const destination, const source = splitOperands(rest);
            if (destination.len != 0) instruction.destination = parseOperand(destination);
            if (source) |text| instruction.source = parseOperand(text);
        },
    }
    return instruction;
}

/// Parses an `ExportProgram.java` disassembly listing into its functions.
///
/// The listing marks each function with a `; ==== <name> @ <address> ====` banner.
pub fn parse(arena: std.mem.Allocator, listing: []const u8) ![]const Function {
    var functions: std.ArrayList(Function) = .empty;
    var instructions: std.ArrayList(Instruction) = .empty;
    var current: ?Line.Banner = null;

    var lines: Lines = .init(listing);
    while (try lines.next()) |line| switch (line) {
        .banner => |banner| {
            if (current) |previous| try functions.append(arena, .{
                .name = previous.name,
                .address = previous.address,
                .instructions = try instructions.toOwnedSlice(arena),
            });
            current = banner;
        },
        .instruction => |encoded| if (current != null) try instructions.append(arena, decode(encoded)),
        .other => {},
    };
    if (current) |previous| try functions.append(arena, .{
        .name = previous.name,
        .address = previous.address,
        .instructions = try instructions.toOwnedSlice(arena),
    });
    return functions.toOwnedSlice(arena);
}

test Line {
    const banner = (try Line.parse("; ==== vm_op_42 @ 0045c2b0 ====")).banner;
    try std.testing.expectEqualStrings("vm_op_42", banner.name);
    try std.testing.expectEqual(0x0045c2b0, banner.address);

    const move = (try Line.parse("0045bea6  8a02   MOV AL,byte ptr [EDX]")).instruction;
    try std.testing.expectEqual(0x0045bea6, move.address);
    try std.testing.expectEqualStrings("8a02", move.bytes);
    try std.testing.expectEqualStrings("MOV AL,byte ptr [EDX]", move.text);

    try std.testing.expectEqual(Line.other, try Line.parse(""));
    try std.testing.expectEqual(Line.other, try Line.parse("; a comment"));
    try std.testing.expectError(error.BadBanner, Line.parse("; ==== nameless ===="));
    try std.testing.expectError(error.BadBanner, Line.parse("; ==== f @ nowhere ===="));
}

test parseLine {
    const move = parseLine("0045bea6  8a02   MOV AL,byte ptr [EDX]").?;
    try std.testing.expectEqual(@as(u32, 0x0045bea6), move.address);
    try std.testing.expectEqual(Mnemonic.mov, move.mnemonic);
    try std.testing.expectEqual(Register.eax, move.destination.?.byte_register.register);
    try std.testing.expectEqual(false, move.destination.?.byte_register.high);
    try std.testing.expectEqual(Register.edx, move.source.?.memory.base.?);
    try std.testing.expectEqual(@as(u8, 1), move.source.?.memory.width);

    const lea = parseLine("0045bec0  8d1490  LEA EDX,[EAX + EDX*0x4]").?;
    try std.testing.expectEqual(Register.eax, lea.source.?.memory.base.?);
    try std.testing.expectEqual(Register.edx, lea.source.?.memory.index.?);
    try std.testing.expectEqual(@as(u8, 4), lea.source.?.memory.scale);

    const negative = parseLine("0045bbf0  8b41fc  MOV EAX,dword ptr [ECX + -0x8]").?;
    try std.testing.expectEqual(@as(i64, -8), negative.source.?.memory.displacement);

    const absolute = parseLine("0045bea5  a194f92500  MOV ESI,dword ptr [0x00525f94]").?;
    try std.testing.expectEqual(@as(?Register, null), absolute.source.?.memory.base);
    try std.testing.expectEqual(@as(i64, 0x00525f94), absolute.source.?.memory.displacement);

    const branch = parseLine("0045c27a  750d  JNZ 0x0045c289").?;
    try std.testing.expectEqual(Mnemonic.jcc, branch.mnemonic);
    try std.testing.expectEqual(@as(u32, 0x0045c289), branch.target.?);

    try std.testing.expectEqual(@as(?Instruction, null), parseLine("; a comment"));
}

test parse {
    const listing =
        \\; ==== vm_op_42 @ 0045c2b0 ====
        \\0045c2b0  8b01   MOV EAX,dword ptr [ECX]
        \\0045c2b2  33d2   XOR EDX,EDX
        \\0045c2c1  c20400 RET 0x4
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const functions = try parse(arena.allocator(), listing);
    try std.testing.expectEqual(@as(usize, 1), functions.len);
    try std.testing.expectEqualStrings("vm_op_42", functions[0].name);
    try std.testing.expectEqual(@as(u32, 0x0045c2b0), functions[0].address);
    try std.testing.expectEqual(@as(usize, 3), functions[0].instructions.len);
}
