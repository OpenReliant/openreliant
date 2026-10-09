//! PlayStation executables (`PS-X EXE`): a 2048-byte header, then the program's text, which loads
//! at the address the header gives. A disc's `SYSTEM.CNF` names the executable it starts
//! (`bootPath`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const layout = @import("../layout.zig");

pub const magic = "PS-X EXE";

/// The file on a disc that names the executable the console starts (`bootPath`).
pub const system_cnf = "SYSTEM.CNF";

/// The header's size: the text starts here in the file.
pub const header_size = 0x800;

/// The start of the header. The rest of its 2048 bytes holds a licence line and padding.
pub const Header = extern struct {
    magic: [8]u8,
    _unknown_08: [8]u8,
    /// The address the program starts at.
    entry: u32,
    /// The value of the global pointer register at the start.
    global_pointer: u32,
    /// Where the text loads, and its size.
    text_address: u32,
    text_size: u32,

    comptime {
        assert(@offsetOf(Header, "entry") == 0x10);
        assert(@offsetOf(Header, "text_address") == 0x18);
        assert(@sizeOf(Header) == 0x20);
    }
};

pub const Error = error{NotAnExecutable};

pub const Executable = struct {
    header: *align(1) const Header,
    /// The text as the file holds it, which loads at `header.text_address`.
    text: []const u8,

    pub fn parse(bytes: []const u8) Error!Executable {
        const header = layout.view(Header, bytes) catch return error.NotAnExecutable;
        if (!std.mem.eql(u8, &header.magic, magic) or bytes.len < header_size) return error.NotAnExecutable;
        const text = bytes[header_size..];
        return .{ .header = header, .text = text[0..@min(text.len, header.text_size)] };
    }

    /// The text's bytes from `address` on; null for an address outside it.
    pub fn at(executable: Executable, address: u32) ?[]const u8 {
        const start = executable.header.text_address;
        if (address < start or address - start >= executable.text.len) return null;
        return executable.text[address - start ..];
    }

    /// The NUL-terminated string at `address`, of at most `longest` bytes; null where the text
    /// holds none.
    pub fn string(executable: Executable, address: u32, longest: usize) ?[]const u8 {
        return layout.string(executable.at(address) orelse return null, longest);
    }
};

/// The path of the executable that `config`, the bytes of a disc's `SYSTEM.CNF`, starts,
/// `/`-separated from the root of the disc: `BOOT = cdrom:\SLUS_009.24;1` names `SLUS_009.24`.
/// Null when the file names none.
pub fn bootPath(arena: Allocator, config: []const u8) Allocator.Error!?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, config, "\r\n");
    while (lines.next()) |line| {
        const equals = std.mem.findScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equals], " \t"), "BOOT")) continue;
        var value = std.mem.trim(u8, line[equals + 1 ..], " \t\x00");
        const device = "cdrom:";
        if (value.len >= device.len and std.ascii.eqlIgnoreCase(value[0..device.len], device)) value = value[device.len..];
        value = std.mem.trimStart(u8, value, "\\/");
        // The version, as ISO 9660 names keep it: `;1`.
        if (std.mem.findScalar(u8, value, ';')) |version| value = value[0..version];
        if (value.len == 0) return null;
        const path = try arena.dupe(u8, value);
        std.mem.replaceScalar(u8, path, '\\', '/');
        return path;
    }
    return null;
}

/// Builds executables, for tests.
pub const testing = struct {
    /// An executable whose text, `text`, loads at `address`.
    pub fn build(arena: Allocator, address: u32, text: []const u8) Allocator.Error![]u8 {
        const bytes = try arena.alloc(u8, header_size + text.len);
        @memset(bytes, 0);
        const header: *align(1) Header = @ptrCast(bytes[0..@sizeOf(Header)]);
        header.* = .{ .magic = magic.*, ._unknown_08 = @splat(0), .entry = address, .global_pointer = 0, .text_address = address, .text_size = @intCast(text.len) };
        @memcpy(bytes[header_size..], text);
        return bytes;
    }
};

test Executable {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try testing.build(arena.allocator(), 0x80010000, "hello\x00world");
    const executable: Executable = try .parse(bytes);
    try std.testing.expectEqualStrings("hello", executable.string(0x80010000, 16).?);
    try std.testing.expectEqualStrings("ello", executable.string(0x80010001, 16).?);
    // Too long, with no NUL in the text after it, and outside the text.
    try std.testing.expectEqual(null, executable.string(0x80010000, 4));
    try std.testing.expectEqual(null, executable.string(0x80010006, 16));
    try std.testing.expectEqual(null, executable.string(0x8000FFFF, 16));
    try std.testing.expectError(error.NotAnExecutable, Executable.parse("PS-X EXE"));
}

test bootPath {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqualStrings("SLUS_009.24", (try bootPath(gpa, "BOOT = cdrom:\\SLUS_009.24;1\r\nTCB = 4\r\n")).?);
    try std.testing.expectEqualStrings("GAME/MAIN.EXE", (try bootPath(gpa, "STACK = 801FFFF0\nboot=cdrom:\\GAME\\MAIN.EXE;1\n")).?);
    try std.testing.expectEqual(null, try bootPath(gpa, "TCB = 4\n"));
}
