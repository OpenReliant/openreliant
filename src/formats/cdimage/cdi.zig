//! DiscJuggler `.cdi` images: a disc's tracks back to back, each with its pregap, then a table of
//! the sessions and tracks at the end of the file. Burned Dreamcast discs are often kept this way,
//! with an audio track in the first session and the data track in the second. This reads the
//! table the way cdirip does, and finds the last data track.

const std = @import("std");

/// The last 8 bytes of the file: the version, then where the table starts.
pub const Version = enum(u32) {
    v2 = 0x80000004,
    v3 = 0x80000005,
    /// The table's place counts back from the end of the file.
    v3_5 = 0x80000006,
    _,
};

/// The bytes before each track's record: the same 10 bytes twice.
const mark_half = [_]u8{ 0, 0, 1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF };
const track_mark = mark_half ++ mark_half;

/// The longest table this reads.
pub const max_table = 64 * 1024;

pub const Track = struct {
    /// 0 for audio, 1 for Mode 1 data, 2 for Mode 2 data.
    mode: u32,
    /// 2048, 2336 or 2352.
    sector_size: u32,
    /// The disc address of the first sector after the pregap.
    first_lba: u32,
    /// Its sectors, without the pregap.
    length: u32,
    /// Where the first sector after the pregap is in the file.
    offset: u64,
};

pub const Error = error{BadTable};

/// Reads the table from `table`, the bytes from its start to the version at the end of the file,
/// and returns the last data track; null if the disc has none.
pub fn lastDataTrack(table: []const u8, version: Version) Error!?Track {
    var reader: Reader = .{ .bytes = table };
    var position: u64 = 0;
    var found: ?Track = null;
    const sessions = try reader.int(u16);
    for (0..sessions) |_| {
        const tracks = try reader.int(u16);
        for (0..tracks) |_| {
            if (try reader.int(u32) != 0) try reader.skip(8);
            if (!std.mem.eql(u8, try reader.take(track_mark.len), &track_mark)) return error.BadTable;
            try reader.skip(4);
            try reader.skip(try reader.int(u8));
            try reader.skip(11 + 4 + 4);
            if (try reader.int(u32) == 0x80000000) try reader.skip(8);
            try reader.skip(2);
            const pregap = try reader.int(u32);
            const length = try reader.int(u32);
            try reader.skip(6);
            const mode = try reader.int(u32);
            try reader.skip(12);
            const first_lba = try reader.int(u32);
            const total = try reader.int(u32);
            try reader.skip(16);
            const sector_size: u32 = switch (try reader.int(u32)) {
                0 => 2048,
                1 => 2336,
                2 => 2352,
                else => return error.BadTable,
            };
            try reader.skip(29);
            if (version != .v2) {
                try reader.skip(5);
                if (try reader.int(u32) == 0xFFFFFFFF) try reader.skip(78);
            }
            if (mode != 0) found = .{
                .mode = mode,
                .sector_size = sector_size,
                .first_lba = first_lba,
                .length = length,
                .offset = position + @as(u64, pregap) * sector_size,
            };
            position += @as(u64, total) * sector_size;
        }
        try reader.skip(12);
        if (version != .v2) try reader.skip(1);
    }
    return found;
}

/// Where the table starts, from the file's last 8 bytes and its length; null for a file that
/// isn't a `.cdi` image.
pub fn tableStart(tail: *const [8]u8, file_size: u64) ?struct { offset: u64, version: Version } {
    const version: Version = @fromBackingInt(std.mem.readInt(u32, tail[0..4], .little));
    const value = std.mem.readInt(u32, tail[4..8], .little);
    const offset: u64 = switch (version) {
        .v2, .v3 => value,
        .v3_5 => file_size -| value,
        _ => return null,
    };
    if (offset == 0 or offset >= file_size - tail.len) return null;
    return .{ .offset = offset, .version = version };
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(reader: *Reader, n: usize) Error![]const u8 {
        if (reader.bytes.len - reader.at < n) return error.BadTable;
        defer reader.at += n;
        return reader.bytes[reader.at..][0..n];
    }

    fn skip(reader: *Reader, n: usize) Error!void {
        _ = try reader.take(n);
    }

    fn int(reader: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try reader.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

/// Builds tables, for tests.
pub const testing = struct {
    pub const Spec = struct { mode: u32, sector_code: u32, pregap: u32, length: u32, first_lba: u32 };

    /// A version 3.5 table of one session for each of `tracks`.
    pub fn table(arena: std.mem.Allocator, tracks: []const Spec) std.mem.Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try put(arena, &out, u16, @intCast(tracks.len));
        for (tracks) |track| {
            try put(arena, &out, u16, 1);
            try put(arena, &out, u32, 0);
            try out.appendSlice(arena, &track_mark);
            try out.appendNTimes(arena, 0, 4);
            try put(arena, &out, u8, 4);
            try out.appendSlice(arena, "a.cd");
            try out.appendNTimes(arena, 0, 11 + 4 + 4);
            try put(arena, &out, u32, 0);
            try out.appendNTimes(arena, 0, 2);
            try put(arena, &out, u32, track.pregap);
            try put(arena, &out, u32, track.length);
            try out.appendNTimes(arena, 0, 6);
            try put(arena, &out, u32, track.mode);
            try out.appendNTimes(arena, 0, 12);
            try put(arena, &out, u32, track.first_lba);
            try put(arena, &out, u32, track.pregap + track.length);
            try out.appendNTimes(arena, 0, 16);
            try put(arena, &out, u32, track.sector_code);
            try out.appendNTimes(arena, 0, 29 + 5);
            try put(arena, &out, u32, 0);
            try out.appendNTimes(arena, 0, 12 + 1);
        }
        return out.items;
    }

    fn put(arena: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try out.appendSlice(arena, &bytes);
    }
};

test lastDataTrack {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // An audio session, then a data session, as a burned Dreamcast disc has them.
    const table = try testing.table(arena.allocator(), &.{
        .{ .mode = 0, .sector_code = 2, .pregap = 150, .length = 302, .first_lba = 0 },
        .{ .mode = 2, .sector_code = 1, .pregap = 150, .length = 1000, .first_lba = 11702 },
    });
    const track = (try lastDataTrack(table, .v3_5)).?;
    try std.testing.expectEqual(2336, track.sector_size);
    try std.testing.expectEqual(11702, track.first_lba);
    try std.testing.expectEqual(1000, track.length);
    try std.testing.expectEqual(452 * 2352 + 150 * 2336, track.offset);
    try std.testing.expectError(error.BadTable, lastDataTrack(table[0..40], .v3_5));
}

test tableStart {
    var tail: [8]u8 = undefined;
    std.mem.writeInt(u32, tail[0..4], @backingInt(Version.v3_5), .little);
    std.mem.writeInt(u32, tail[4..8], 713, .little);
    try std.testing.expectEqual(10_000 - 713, tableStart(&tail, 10_000).?.offset);
    std.mem.writeInt(u32, tail[0..4], 0x12345678, .little);
    try std.testing.expectEqual(null, tableStart(&tail, 10_000));
}
