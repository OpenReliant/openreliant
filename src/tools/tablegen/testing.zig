//! Helpers for tablegen's tests: synthetic payloads to read tables from, and a check on the Zig the
//! emitters write.

const std = @import("std");

const openreliant = @import("openreliant");
const pe = openreliant.pe;

const image = @import("image.zig");

/// A region of a synthetic payload, written by virtual address; `reader` makes each a section.
pub const Region = struct {
    va: u32,
    bytes: []u8,

    pub fn put(region: Region, va: u32, bytes: []const u8) void {
        @memcpy(region.bytes[va - region.va ..][0..bytes.len], bytes);
    }

    pub fn putWord(region: Region, va: u32, value: u32) void {
        std.mem.writeInt(u32, region.bytes[va - region.va ..][0..4], value, .little);
    }

    pub fn putHalf(region: Region, va: u32, value: u16) void {
        std.mem.writeInt(u16, region.bytes[va - region.va ..][0..2], value, .little);
    }

    /// Writes `record`, an `extern struct`, as the payload lays it out.
    pub fn putRecord(region: Region, va: u32, record: anytype) void {
        region.put(va, std.mem.asBytes(&record));
    }

    /// Writes `text` and its terminating NUL.
    pub fn putString(region: Region, va: u32, text: []const u8) void {
        region.put(va, text);
        region.bytes[va - region.va + text.len] = 0;
    }
};

/// The payload's image base, which the synthetic payloads share.
pub const base: u32 = 0x400000;

/// A reader over a synthetic payload made of `regions`, allocated in `allocator`. The strings a
/// reader returns point into its image, so free it with `freeReader` only after using them.
pub fn reader(allocator: std.mem.Allocator, regions: []const Region) !image.Reader {
    var sections: [8]pe.testing.Section = undefined;
    for (regions, sections[0..regions.len]) |region, *section| {
        section.* = .{ .rva = region.va - base, .data = region.bytes };
    }
    const bytes = try pe.testing.build(allocator, base, sections[0..regions.len]);
    errdefer allocator.free(bytes);
    return .init(try .parse(bytes), bytes);
}

pub fn freeReader(allocator: std.mem.Allocator, payload: image.Reader) void {
    allocator.free(payload.image.bytes);
}

/// Fails unless `source` parses as Zig.
pub fn expectZig(source: []const u8) !void {
    const allocator = std.testing.allocator;
    const terminated = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(terminated);
    var tree = try std.zig.Ast.parse(allocator, terminated, .zig);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(0, tree.errors.len);
}
