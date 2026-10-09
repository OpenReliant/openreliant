//! Xbox executables (`.xbe`): a header that loads at the base address, and sections that load at
//! their own addresses. `Executable.at` turns an address in memory into the file's bytes.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("../layout.zig");

/// The start of the header: the parts this reader needs.
pub const Header = extern struct {
    magic: [4]u8,
    /// The signature over the rest of the header.
    signature: [256]u8,
    /// Where the header loads; the header's addresses count from it.
    base_address: u32,
    headers_size: u32,
    image_size: u32,
    image_header_size: u32,
    time_date: u32,
    certificate_address: u32,
    section_count: u32,
    /// The address of the section headers.
    section_headers: u32,

    pub const xbeh = "XBEH";

    comptime {
        assert(@offsetOf(Header, "base_address") == 0x104);
        assert(@offsetOf(Header, "section_count") == 0x11C);
        assert(@offsetOf(Header, "section_headers") == 0x120);
    }
};

pub const SectionHeader = extern struct {
    flags: u32,
    /// Where the section loads, and its size there.
    address: u32,
    size: u32,
    /// Where its bytes are in the file, and how many.
    file_offset: u32,
    file_size: u32,
    /// The address of its name.
    name: u32,
    _unknown_18: [12]u8,
    digest: [20]u8,

    comptime {
        assert(@sizeOf(SectionHeader) == 0x38);
    }
};

pub const Error = error{NotAnExecutable};

pub const Executable = struct {
    bytes: []const u8,
    header: *align(1) const Header,
    sections: []align(1) const SectionHeader,

    pub fn parse(bytes: []const u8) Error!Executable {
        const header = layout.view(Header, bytes) catch return error.NotAnExecutable;
        if (!std.mem.eql(u8, &header.magic, Header.xbeh) or header.section_headers < header.base_address) return error.NotAnExecutable;
        const headers = header.section_headers - header.base_address;
        if (headers > bytes.len) return error.NotAnExecutable;
        const sections = layout.array(SectionHeader, bytes[headers..], header.section_count) catch return error.NotAnExecutable;
        return .{ .bytes = bytes, .header = header, .sections = sections };
    }

    /// The file's bytes from `address` to the end of what loads there: the header's or a
    /// section's. Null for an address the file doesn't fill.
    pub fn at(executable: Executable, address: u32) ?[]const u8 {
        const base = executable.header.base_address;
        if (address >= base and address - base < executable.header.headers_size) {
            return clipped(executable.bytes, address - base, executable.header.headers_size - (address - base));
        }
        for (executable.sections) |section| {
            if (address < section.address or address - section.address >= @min(section.size, section.file_size)) continue;
            const offset = address - section.address;
            return clipped(executable.bytes, @as(usize, section.file_offset) + offset, section.file_size - offset);
        }
        return null;
    }

    /// The zero-terminated string at `address`, of at most `longest` bytes.
    pub fn string(executable: Executable, address: u32, longest: usize) ?[]const u8 {
        return layout.string(executable.at(address) orelse return null, longest);
    }

    /// The address of the first copy of `bytes` in a section, if any holds one.
    pub fn find(executable: Executable, bytes: []const u8) ?u32 {
        for (executable.sections) |section| {
            const data = clipped(executable.bytes, section.file_offset, section.file_size) orelse continue;
            const offset = std.mem.find(u8, data, bytes) orelse continue;
            return section.address + @as(u32, @intCast(offset));
        }
        return null;
    }
};

/// `len` bytes of `bytes` from `offset`, as many as there are.
fn clipped(bytes: []const u8, offset: usize, len: usize) ?[]const u8 {
    if (offset > bytes.len) return null;
    return bytes[offset..][0..@min(len, bytes.len - offset)];
}

/// Builds executables, for tests.
pub const testing = struct {
    /// An executable based at `base` whose one section loads `data` at `address`.
    pub fn build(arena: std.mem.Allocator, base: u32, address: u32, data: []const u8) std.mem.Allocator.Error![]u8 {
        const headers_size = 0x200;
        const bytes = try arena.alloc(u8, headers_size + data.len);
        @memset(bytes, 0);
        const header: *align(1) Header = @ptrCast(bytes[0..@sizeOf(Header)]);
        header.magic = Header.xbeh.*;
        header.base_address = base;
        header.headers_size = headers_size;
        header.section_count = 1;
        header.section_headers = base + 0x180;
        const section: *align(1) SectionHeader = @ptrCast(bytes[0x180..][0..@sizeOf(SectionHeader)]);
        section.address = address;
        section.size = @intCast(data.len);
        section.file_offset = headers_size;
        section.file_size = @intCast(data.len);
        @memcpy(bytes[headers_size..], data);
        return bytes;
    }
};

test Executable {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try testing.build(arena.allocator(), 0x10000, 0x20000, "\x00CreateTimer\x00");
    const executable: Executable = try .parse(bytes);
    try std.testing.expectEqual(0x20001, executable.find("CreateTimer\x00"));
    try std.testing.expectEqualStrings("CreateTimer", executable.string(0x20001, 32).?);
    try std.testing.expectEqualStrings(Header.xbeh, executable.at(0x10000).?[0..4]);
    try std.testing.expectEqual(null, executable.at(0x30000));
    try std.testing.expectEqual(null, executable.find("Fly\x00"));
    try std.testing.expectError(error.NotAnExecutable, Executable.parse("XBEH"));
}
