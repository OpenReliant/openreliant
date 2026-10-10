//! Reads which opcodes start a statement, where a step of the editor link stops
//! (`vm_starts_statement`, docs/engine/editor-link.md).
//!
//! The function is a `switch` the compiler laid out as a bounded index into a byte table: the
//! opcode less a bias picks a byte, and the byte picks one of the cases in a table of addresses.
//! Each case returns a constant, true or false, as does the default past the bound. This reader
//! decodes exactly that shape, and reports any other rather than guess at it.

const std = @import("std");

const image = @import("image.zig");
const testing = @import("testing.zig");

/// `vm_starts_statement`.
pub const function: u32 = 0x004575C0;

/// The bytes the function's dispatch takes, from its start up to its first case.
const dispatch_length = 0x1D;

pub const Error = image.Error || error{UnexpectedCode};

/// Whether each opcode starts a statement, by its value.
pub fn read(reader: image.Reader) Error![256]bool {
    const code = try reader.slice(function, dispatch_length);
    // `and ecx, 0xFF`: the opcode, a byte.
    try expect(code[0..6], &.{ 0x81, 0xE1, 0xFF, 0x00, 0x00, 0x00 });
    // `lea eax, [ecx - bias]`.
    try expect(code[6..8], &.{ 0x8D, 0x41 });
    const bias: u8 = @bitCast(-%@as(i8, @bitCast(code[8])));
    // `cmp eax, bound`, then `ja` to the default.
    try expect(code[9..11], &.{ 0x83, 0xF8 });
    const bound = code[11];
    try expect(code[12..13], &.{0x77});
    const past_bound = try returned(reader, function + 14 + code[13]);
    // `xor ecx, ecx`, `mov cl, [eax + index table]`.
    try expect(code[14..18], &.{ 0x33, 0xC9, 0x8A, 0x88 });
    const index_table = std.mem.readInt(u32, code[18..22], .little);
    // `jmp [ecx * 4 + case table]`.
    try expect(code[22..25], &.{ 0xFF, 0x24, 0x8D });
    const case_table = std.mem.readInt(u32, code[25..29], .little);

    var starts: [256]bool = @splat(past_bound);
    const indices = try reader.slice(index_table, @as(usize, bound) + 1);
    for (indices, 0..) |case, at| {
        const target = try reader.word(case_table + @as(u32, case) * @sizeOf(u32));
        starts[(at + bias) % starts.len] = try returned(reader, target);
    }
    return starts;
}

/// What the code at `at` returns: `mov al, 1; ret` gives true, `xor al, al; ret` false.
fn returned(reader: image.Reader, at: u32) Error!bool {
    const code = try reader.slice(at, 3);
    if (std.mem.eql(u8, code, &.{ 0xB0, 0x01, 0xC3 })) return true;
    if (std.mem.eql(u8, code, &.{ 0x32, 0xC0, 0xC3 })) return false;
    return error.UnexpectedCode;
}

fn expect(code: []const u8, wanted: []const u8) Error!void {
    if (!std.mem.eql(u8, code, wanted)) return error.UnexpectedCode;
}

test read {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text: testing.Region = .{ .va = function, .bytes = try arena.allocator().alloc(u8, 0x40) };
    @memset(text.bytes, 0x90);
    // Opcodes 0x16 to 0x18: the first and the last start a statement, the middle one doesn't.
    text.put(function, &.{
        0x81, 0xE1, 0xFF, 0x00, 0x00, 0x00, // and ecx, 0xFF
        0x8D, 0x41, 0xEA, // lea eax, [ecx - 0x16]
        0x83, 0xF8, 0x02, // cmp eax, 2
        0x77, 0x12, // ja +0x12
        0x33, 0xC9, 0x8A, 0x88, // xor ecx, ecx; mov cl, [eax + ...]
    });
    text.putWord(function + 18, function + 0x2C);
    text.put(function + 22, &.{ 0xFF, 0x24, 0x8D });
    text.putWord(function + 25, function + 0x24);
    text.put(function + 0x1D, &.{ 0xB0, 0x01, 0xC3 }); // case 0: true
    text.put(function + 0x20, &.{ 0x32, 0xC0, 0xC3 }); // case 1 and the default: false
    text.putWord(function + 0x24, function + 0x1D);
    text.putWord(function + 0x28, function + 0x20);
    text.put(function + 0x2C, &.{ 0, 1, 0 });
    const reader = try testing.reader(arena.allocator(), &.{text});
    const starts = try read(reader);
    try std.testing.expect(starts[0x16] and !starts[0x17] and starts[0x18]);
    try std.testing.expect(!starts[0x15] and !starts[0x19]);

    // Code of another shape is reported.
    text.bytes[0] = 0x90;
    try std.testing.expectError(error.UnexpectedCode, read(try testing.reader(arena.allocator(), &.{text})));
}
