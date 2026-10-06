//! Reads the payload executable's memory by virtual address.

const std = @import("std");

const openreliant = @import("openreliant");
const layout = openreliant.layout;
const pe = openreliant.pe;

const testing = @import("testing.zig");

pub const Error = error{ OutOfImage, BadString };

pub const Reader = struct {
    image: pe.Image,
    bytes: []const u8,
    base: u32,

    pub fn init(image: pe.Image, bytes: []const u8) Reader {
        return .{ .image = image, .bytes = bytes, .base = image.optional_header.image_base };
    }

    pub fn slice(reader: Reader, va: u32, len: usize) Error![]const u8 {
        const bytes = reader.rest(va) orelse return error.OutOfImage;
        if (len > bytes.len) return error.OutOfImage;
        return bytes[0..len];
    }

    /// The bytes from `va` to the end of its section's data in the file.
    fn rest(reader: Reader, va: u32) ?[]const u8 {
        if (va < reader.base) return null;
        const rva = va - reader.base;
        const section = reader.image.sectionContaining(rva) orelse return null;
        const offset = reader.image.fileOffset(rva) orelse return null;
        const end = @min(@as(usize, section.raw_offset) + section.raw_size, reader.bytes.len);
        return if (offset < end) reader.bytes[offset..end] else null;
    }

    pub fn int(reader: Reader, comptime T: type, va: u32) Error!T {
        return std.mem.readInt(T, (try reader.slice(va, @sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    pub fn word(reader: Reader, va: u32) Error!u32 {
        return reader.int(u32, va);
    }

    /// The record of type `T` at `va`: an `extern struct` laid out as the payload lays it.
    pub fn record(reader: Reader, comptime T: type, va: u32) Error!T {
        return (try reader.view(T, va)).*;
    }

    /// `record`, in place, for a record whose fields are kept by reference, such as its name.
    pub fn view(reader: Reader, comptime T: type, va: u32) Error!*align(1) const T {
        return layout.view(T, try reader.slice(va, @sizeOf(T))) catch error.OutOfImage;
    }

    /// Record `index` of a table of `T` records at `base`.
    pub fn recordAt(reader: Reader, comptime T: type, base: u32, index: usize) Error!T {
        return (try reader.viewAt(T, base, index)).*;
    }

    /// `recordAt`, in place.
    pub fn viewAt(reader: Reader, comptime T: type, base: u32, index: usize) Error!*align(1) const T {
        return reader.view(T, base + @as(u32, @intCast(index)) * @sizeOf(T));
    }

    /// `count` records of type `T` from `va`.
    pub fn records(reader: Reader, comptime T: type, va: u32, count: usize) Error![]align(1) const T {
        const size = std.math.mul(usize, count, @sizeOf(T)) catch return error.OutOfImage;
        return layout.array(T, try reader.slice(va, size), count) catch return error.OutOfImage;
    }

    /// A NUL-terminated string of printable ASCII and tabs at `va`, or empty for a null pointer.
    pub fn string(reader: Reader, va: u32) Error![]const u8 {
        if (va == 0) return "";
        const bytes = reader.rest(va) orelse return error.BadString;
        const end = std.mem.findScalar(u8, bytes, 0) orelse return error.BadString;
        for (bytes[0..end]) |c| if ((c < 0x20 and c != '\t') or c > 0x7E) return error.BadString;
        return bytes[0..end];
    }
};

test Reader {
    var data: [0x40]u8 = @splat(0);
    const region: testing.Region = .{ .va = 0x401000, .bytes = &data };
    region.putWord(0x401000, 0xDEADBEEF);
    region.putString(0x401010, "LANCER");
    region.putString(0x401018, "\tGoto");
    region.put(0x401020, "bad\x01\x00");
    region.put(0x40103C, "open");

    const reader = try testing.reader(std.testing.allocator, &.{region});
    defer testing.freeReader(std.testing.allocator, reader);

    try std.testing.expectEqual(0xDEADBEEF, try reader.word(0x401000));
    try std.testing.expectEqual(0xBEEF, try reader.int(u16, 0x401000));
    try std.testing.expectEqualStrings("LANCER", try reader.string(0x401010));
    try std.testing.expectEqualStrings("\tGoto", try reader.string(0x401018));
    try std.testing.expectEqualStrings("", try reader.string(0));
    try std.testing.expectEqualSlices(u8, "LAN", try reader.slice(0x401010, 3));
    const Pair = extern struct { low: u16, high: u16 };
    try std.testing.expectEqual(Pair{ .low = 0xBEEF, .high = 0xDEAD }, try reader.record(Pair, 0x401000));
    try std.testing.expectEqual(0x434E, (try reader.records(u16, 0x401010, 2))[1]);
    try std.testing.expectEqual(0x434E, try reader.recordAt(u16, 0x401010, 1));
    try std.testing.expectEqual(0x434E, (try reader.viewAt(u16, 0x401010, 1)).*);

    // Below the image, past the section, a control character, and a string that never ends.
    try std.testing.expectError(error.OutOfImage, reader.word(0x3FFFFC));
    try std.testing.expectError(error.OutOfImage, reader.word(0x402000));
    try std.testing.expectError(error.BadString, reader.string(0x401020));
    try std.testing.expectError(error.BadString, reader.string(0x40103C));
}
