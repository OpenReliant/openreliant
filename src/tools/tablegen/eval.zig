//! Works out what one mission script VM opcode handler does to the instruction pointer.
//!
//! The dispatcher reads an opcode byte at `P`, sets the instruction pointer to `P + 1` and calls
//! the handler with `ECX` pointing at the cell that holds it. Whatever the handler leaves in that
//! cell is where execution resumes, so the size and shape of an instruction is exactly what the
//! handler does to `[ECX]`.
//!
//! Every path through the handler is explored and the results must agree, so a handler whose
//! behaviour this module cannot pin down is reported rather than guessed at.

const std = @import("std");
const x86 = @import("x86.zig");

/// A read of the script stream: `width` bytes at `ip + offset`, zero extended and shifted left
/// `shift` bits. Handlers build a big-endian pair by loading the high half into `DH` and the low
/// half into `DL`, which is what the shift records.
pub const Fetch = struct {
    offset: i64,
    width: u8,
    shift: u5 = 0,
};

/// What a 32-bit quantity holds, as far as this analysis cares.
pub const Value = union(enum) {
    unknown,
    constant: i64,
    /// The instruction pointer on entry, displaced by a constant.
    ip: i64,
    /// `ECX` on entry: the address of the cell holding the instruction pointer.
    ip_cell,
    /// A read of the script stream.
    operand: Fetch,
    /// `ip + <a read of the script stream>`: a relative target.
    target: Fetch,

    fn add(a: Value, b: Value) Value {
        // Commutative, so normalise to halve the cases.
        if (a == .constant and b != .constant) return add(b, a);
        if (a == .operand and b == .ip) return add(b, a);
        return switch (a) {
            .constant => |x| switch (b) {
                .constant => |y| .{ .constant = x + y },
                else => .unknown,
            },
            .ip => |k| switch (b) {
                .constant => |y| .{ .ip = k + y },
                // `ADD EDX,EAX` with the displacement in EDX and the instruction pointer in EAX.
                // The displacement is relative to where it was read, which is where these land.
                .operand => |fetch| if (fetch.shift == 0 and fetch.offset == k)
                    .{ .target = fetch }
                else
                    .unknown,
                else => .unknown,
            },
            else => .unknown,
        };
    }

    fn sub(a: Value, b: Value) Value {
        return switch (b) {
            .constant => |y| add(a, .{ .constant = -y }),
            else => .unknown,
        };
    }
};

/// Where an effective address points.
const Location = union(enum) {
    /// The cell holding the instruction pointer.
    ip_cell,
    /// `ip + offset`: somewhere in the script stream.
    stream: i64,
    unknown,
};

/// The shape of one instruction, as the decoder needs to see it.
pub const Form = enum {
    /// Execution continues at the instruction after the operands.
    sequential,
    /// The operand bytes hold a displacement from their own position to where execution resumes.
    /// The instruction still ends after the displacement, so a listing continues past it.
    branch,
    /// The one operand byte is a total length: `length - 1` bytes of inline data follow it, and
    /// execution resumes after them.
    inline_data,
    /// Control passes somewhere a linear decoder cannot follow.
    transfer,
};

pub const Shape = struct {
    /// Operand bytes between the opcode and the next instruction. For `inline_data` this counts
    /// only the length byte.
    operands: u8,
    form: Form,
    /// Whether any path through the handler leaves the instruction pointer just past the operands.
    /// Where none does, the bytes after the instruction are reached only by a branch, so a linear
    /// sweep would decode whatever happens to sit there.
    falls_through: bool,
};

pub const Error = error{
    /// Paths through the handler disagree about how many operand bytes it consumes.
    InconsistentOperandCount,
    /// A relative displacement of a width this decoder has no rule for.
    UnsupportedDisplacement,
    /// The handler branches more than the explorer is willing to follow.
    TooManyPaths,
};

const max_paths = 512;

const State = struct {
    registers: [8]Value,
    stack: [16]Value = @splat(.unknown),
    depth: usize = 0,
    /// What the instruction pointer cell currently holds. A handler that stores an address it
    /// computed and then reads the cell back must see that address, not the value on entry.
    ip_cell_value: Value,
    /// The largest constant advance stored to it anywhere along this path.
    consumed: i64 = 0,

    fn get(self: State, register: x86.Register) Value {
        return self.registers[@backingInt(register)];
    }

    fn set(self: *State, register: x86.Register, value: Value) void {
        self.registers[@backingInt(register)] = value;
    }

    /// Writes one half of a register, which is how a handler zero extends an operand byte and how
    /// it assembles a big-endian pair.
    fn setByte(self: *State, half: x86.Register.Byte, value: Value) void {
        const current = self.get(half.register);
        const shifted: Value = switch (value) {
            .operand => |fetch| if (fetch.shift == 0 and fetch.width == 1)
                .{ .operand = .{ .offset = fetch.offset, .width = 1, .shift = if (half.high) 8 else 0 } }
            else
                .unknown,
            else => .unknown,
        };
        // A byte written into a register cleared to zero is the whole register.
        if (current == .constant and current.constant == 0) {
            self.set(half.register, shifted);
            return;
        }
        // The low half of a register already holding a high half: a big-endian pair.
        if (current == .operand and shifted == .operand) {
            const high = current.operand;
            const low = shifted.operand;
            if (high.shift == 8 and high.width == 1 and low.shift == 0 and low.offset == high.offset + 1) {
                self.set(half.register, .{ .operand = .{ .offset = high.offset, .width = 2 } });
                return;
            }
        }
        self.set(half.register, .unknown);
    }

    fn resolve(self: State, address: x86.Address) Location {
        if (address.index != null) return .unknown;
        const base = address.base orelse return .unknown;
        return switch (self.get(base)) {
            .ip_cell => if (address.displacement == 0) .ip_cell else .unknown,
            .ip => |k| .{ .stream = k + address.displacement },
            else => .unknown,
        };
    }

    fn load(self: State, address: x86.Address) Value {
        return switch (self.resolve(address)) {
            .ip_cell => if (address.width == 4) self.ip_cell_value else .unknown,
            .stream => |offset| if (address.width == 4)
                .unknown // The stream is never read a dword at a time.
            else
                .{ .operand = .{ .offset = offset, .width = address.width } },
            .unknown => .unknown,
        };
    }

    fn read(self: State, operand: x86.Operand) Value {
        return switch (operand) {
            .register => |register| self.get(register),
            .byte_register => .unknown,
            .memory => |address| self.load(address),
            .immediate => |value| .{ .constant = value },
            .other => .unknown,
        };
    }

    /// Applies a write, recording it when it lands on the instruction pointer cell.
    fn write(self: *State, operand: x86.Operand, value: Value) void {
        switch (operand) {
            .register => |register| self.set(register, value),
            .byte_register => |half| self.setByte(half, value),
            .memory => |address| {
                if (address.width != 4) return;
                if (self.resolve(address) != .ip_cell) return;
                self.ip_cell_value = value;
                if (value == .ip) self.consumed = @max(self.consumed, value.ip);
            },
            .immediate, .other => {},
        }
    }

    fn push(self: *State, value: Value) void {
        if (self.depth < self.stack.len) self.stack[self.depth] = value;
        self.depth += 1;
    }

    fn pop(self: *State) Value {
        if (self.depth == 0) return .unknown;
        self.depth -= 1;
        return if (self.depth < self.stack.len) self.stack[self.depth] else .unknown;
    }
};

/// One terminating path through a handler.
const Outcome = struct {
    ip_cell_value: Value,
    consumed: i64,
};

const Explorer = struct {
    function: x86.Function,
    outcomes: std.ArrayList(Outcome) = .empty,
    arena: std.mem.Allocator,

    fn run(self: *Explorer, start: usize, state: State, visited: []bool) !void {
        if (self.outcomes.items.len > max_paths) return error.TooManyPaths;

        var index = start;
        var current = state;
        while (index < self.function.instructions.len) : (index += 1) {
            if (visited[index]) return; // A loop: this path adds nothing new.
            visited[index] = true;

            const instruction = self.function.instructions[index];
            switch (instruction.mnemonic) {
                .ret => break,
                .jmp => {
                    const target = instruction.target orelse break;
                    index = self.function.indexOf(target) orelse break;
                    index -= 1; // The loop's increment steps onto it.
                    continue;
                },
                .jcc => {
                    // Follow the taken edge on a copy, then fall through on this one.
                    if (instruction.target) |target| {
                        if (self.function.indexOf(target)) |taken| {
                            const branch_visited = try self.arena.dupe(bool, visited);
                            try self.run(taken, current, branch_visited);
                        }
                    }
                    continue;
                },
                .call => {
                    // The callee returns in EAX and may use the other volatile registers.
                    for ([_]x86.Register{ .eax, .ecx, .edx }) |register| current.set(register, .unknown);
                    continue;
                },
                else => {},
            }

            const destination = instruction.destination orelse continue;
            const value: Value = switch (instruction.mnemonic) {
                .mov => current.read(instruction.source orelse .other),
                .lea => blk: {
                    const address = switch (instruction.source orelse .other) {
                        .memory => |memory| memory,
                        else => break :blk .unknown,
                    };
                    if (address.index != null or address.base == null) break :blk .unknown;
                    break :blk Value.add(current.get(address.base.?), .{ .constant = address.displacement });
                },
                .add => Value.add(current.read(destination), current.read(instruction.source orelse .other)),
                .sub => Value.sub(current.read(destination), current.read(instruction.source orelse .other)),
                .inc => Value.add(current.read(destination), .{ .constant = 1 }),
                .dec => Value.add(current.read(destination), .{ .constant = -1 }),
                .xor => blk: {
                    // Only the clear-to-zero idiom matters, and it is the only form used.
                    const source = instruction.source orelse .other;
                    if (destination == .register and source == .register and
                        destination.register == source.register) break :blk .{ .constant = 0 };
                    break :blk .unknown;
                },
                .push => {
                    current.push(current.read(destination));
                    continue;
                },
                .pop => {
                    const popped = current.pop();
                    current.write(destination, popped);
                    continue;
                },
                else => .unknown,
            };
            current.write(destination, value);
        }

        try self.outcomes.append(self.arena, .{
            .ip_cell_value = current.ip_cell_value,
            .consumed = current.consumed,
        });
    }
};

/// Works out the shape of the instruction that `handler` implements.
pub fn analyze(arena: std.mem.Allocator, handler: x86.Function) !Shape {
    var explorer: Explorer = .{ .function = handler, .arena = arena };
    var initial: State = .{
        .registers = @splat(.unknown),
        // The dispatcher's calling convention: ECX holds the address of the instruction pointer,
        // which points at the first operand byte.
        .ip_cell_value = .{ .ip = 0 },
    };
    initial.set(.ecx, .ip_cell);

    const visited = try arena.alloc(bool, handler.instructions.len);
    @memset(visited, false);
    try explorer.run(0, initial, visited);

    var operands: i64 = 0;
    var relative: ?Fetch = null;
    var transfers = false;
    var falls_through = false;
    for (explorer.outcomes.items) |outcome| {
        var advance = outcome.consumed;
        switch (outcome.ip_cell_value) {
            .ip => |k| {
                advance = @max(advance, k);
                falls_through = true;
            },
            .target => |fetch| relative = fetch,
            else => transfers = true,
        }
        if (advance != 0 and operands != 0 and advance != operands) return error.InconsistentOperandCount;
        operands = @max(operands, advance);
    }

    if (relative) |fetch| {
        // Every relative form starts its displacement at the first operand byte.
        const width = fetch.width + @as(u8, @intCast(fetch.offset));
        return switch (fetch.width) {
            // One byte: the handlers that do this push a pointer to the byte after it first, so
            // the byte is a length covering inline data rather than a branch displacement, and
            // execution resumes just past it.
            1 => .{ .operands = width, .form = .inline_data, .falls_through = true },
            2 => .{ .operands = width, .form = .branch, .falls_through = falls_through },
            else => error.UnsupportedDisplacement,
        };
    }
    return .{
        .operands = std.math.cast(u8, operands) orelse return error.InconsistentOperandCount,
        .form = if (transfers) .transfer else .sequential,
        .falls_through = falls_through,
    };
}

fn expectShape(listing: []const u8, expected: Shape) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const functions = try x86.parse(arena.allocator(), listing);
    try std.testing.expectEqual(expected, try analyze(arena.allocator(), functions[0]));
}

test "one operand byte" {
    // vm_op_27, trimmed to the instructions that touch the instruction pointer.
    try expectShape(
        \\; ==== handler @ 0045c300 ====
        \\0045c300  8b01     MOV EAX,dword ptr [ECX]
        \\0045c302  33d2     XOR EDX,EDX
        \\0045c304  8a10     MOV DL,byte ptr [EAX]
        \\0045c32c  8b01     MOV EAX,dword ptr [ECX]
        \\0045c32e  40       INC EAX
        \\0045c32f  8901     MOV dword ptr [ECX],EAX
        \\0045c335  c20400   RET 0x4
        \\
    , .{ .operands = 1, .form = .sequential, .falls_through = true });
}

test "three operand bytes" {
    // vm_op_4b advances the instruction pointer once per byte it reads.
    try expectShape(
        \\; ==== handler @ 0045c5e0 ====
        \\0045c5e1  8b01     MOV EAX,dword ptr [ECX]
        \\0045c5fa  40       INC EAX
        \\0045c5fe  8901     MOV dword ptr [ECX],EAX
        \\0045c602  40       INC EAX
        \\0045c609  8901     MOV dword ptr [ECX],EAX
        \\0045c628  40       INC EAX
        \\0045c62c  8901     MOV dword ptr [ECX],EAX
        \\0045c64c  c20400   RET 0x4
        \\
    , .{ .operands = 3, .form = .sequential, .falls_through = true });
}

test "big-endian relative branch" {
    // vm_op_42: the displacement's high half lands in DH and its low half in DL.
    try expectShape(
        \\; ==== handler @ 0045c2b0 ====
        \\0045c2b0  8b01     MOV EAX,dword ptr [ECX]
        \\0045c2b2  33d2     XOR EDX,EDX
        \\0045c2b4  8a30     MOV DH,byte ptr [EAX]
        \\0045c2b6  8a5001   MOV DL,byte ptr [EAX + 0x1]
        \\0045c2b9  03d0     ADD EDX,EAX
        \\0045c2bf  8911     MOV dword ptr [ECX],EDX
        \\0045c2c1  c20400   RET 0x4
        \\
    , .{ .operands = 2, .form = .branch, .falls_through = false });
}

test "conditional branch agrees with its fall-through" {
    // vm_op_23 either takes the branch or steps past the two displacement bytes.
    try expectShape(
        \\; ==== handler @ 0045c270 ====
        \\0045c278  85d2     TEST EDX,EDX
        \\0045c27a  750d     JNZ 0x0045c289
        \\0045c27c  8b01     MOV EAX,dword ptr [ECX]
        \\0045c27e  33d2     XOR EDX,EDX
        \\0045c280  8a30     MOV DH,byte ptr [EAX]
        \\0045c282  8a5001   MOV DL,byte ptr [EAX + 0x1]
        \\0045c285  03d0     ADD EDX,EAX
        \\0045c287  eb05     JMP 0x0045c28e
        \\0045c289  8b11     MOV EDX,dword ptr [ECX]
        \\0045c28b  83c202   ADD EDX,0x2
        \\0045c28e  8911     MOV dword ptr [ECX],EDX
        \\0045c2a1  c20400   RET 0x4
        \\
    , .{ .operands = 2, .form = .branch, .falls_through = true });
}

test "inline data" {
    // vm_op_2a pushes a pointer to the byte after the length, then skips the whole run.
    try expectShape(
        \\; ==== handler @ 0045c3b0 ====
        \\0045c3b0  8b01     MOV EAX,dword ptr [ECX]
        \\0045c3b8  40       INC EAX
        \\0045c3c3  33d2     XOR EDX,EDX
        \\0045c3ca  8b01     MOV EAX,dword ptr [ECX]
        \\0045c3cc  8a10     MOV DL,byte ptr [EAX]
        \\0045c3ce  03d0     ADD EDX,EAX
        \\0045c3d4  8911     MOV dword ptr [ECX],EDX
        \\0045c3d6  c20400   RET 0x4
        \\
    , .{ .operands = 1, .form = .inline_data, .falls_through = true });
}

test "no operands" {
    // vm_op_53 leaves the instruction pointer where the dispatcher put it.
    try expectShape(
        \\; ==== handler @ 0045c510 ====
        \\0045c510  8b442404 MOV EAX,dword ptr [ESP + 0x4]
        \\0045c514  c20400   RET 0x4
        \\
    , .{ .operands = 0, .form = .sequential, .falls_through = true });
}
