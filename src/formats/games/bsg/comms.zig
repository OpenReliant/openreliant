//! Battlestar Galactica's comms films: StarLancer's face films (`engine/game/talkie.zig`) without
//! their scrambling, behind a header of their own. `comms\videodata.dat` holds the films back to
//! back, and `comms\video.idx` gives each film's offset in it.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("../../layout.zig");

/// The start of `video.idx`: the count of films, then a word, then an offset for each film.
pub const IndexHeader = extern struct {
    count: u32,
    /// **Unknown:** 256.
    _unknown_04: u32,
};

/// A film's header, before its chunks.
pub const FilmHeader = extern struct {
    magic: [4]u8,
    /// The frames' size, 128 by 128. **Unknown:** which is the width.
    size: [2]u16,
    /// One more than the film's frames, in every film.
    frames_and_one: u32,

    pub const vq03 = "VQ03";

    /// How many frames the film has.
    pub fn frames(header: FilmHeader) u32 {
        return header.frames_and_one -| 1;
    }

    comptime {
        assert(@sizeOf(FilmHeader) == 12);
    }
};

pub const Error = error{ NotAnIndex, NotAFilm };

pub const Index = struct {
    offsets: []align(1) const u32,

    pub fn parse(bytes: []const u8) Error!Index {
        const header = layout.view(IndexHeader, bytes) catch return error.NotAnIndex;
        const offsets = layout.array(u32, bytes[@sizeOf(IndexHeader)..], header.count) catch return error.NotAnIndex;
        return .{ .offsets = offsets };
    }

    /// Film `number`'s bytes in `data`, the contents of `videodata.dat`: from its offset to the
    /// next film's, or to the end.
    pub fn film(index: Index, data: []u8, number: usize) Error!Film {
        if (number >= index.offsets.len) return error.NotAFilm;
        const start = index.offsets[number];
        const end = if (number + 1 < index.offsets.len) index.offsets[number + 1] else data.len;
        if (start > end or end > data.len) return error.NotAFilm;
        return .parse(data[start..end]);
    }
};

pub const Film = struct {
    header: *align(1) const FilmHeader,
    /// The chunks, as a face film holds them, unscrambled.
    chunks: []u8,

    pub fn parse(bytes: []u8) Error!Film {
        const header = layout.view(FilmHeader, bytes) catch return error.NotAFilm;
        if (!std.mem.eql(u8, &header.magic, FilmHeader.vq03)) return error.NotAFilm;
        return .{ .header = header, .chunks = bytes[@sizeOf(FilmHeader)..] };
    }
};

test Index {
    var index_bytes: [16]u8 = undefined;
    std.mem.writeInt(u32, index_bytes[0..4], 2, .little);
    std.mem.writeInt(u32, index_bytes[4..8], 256, .little);
    std.mem.writeInt(u32, index_bytes[8..12], 0, .little);
    std.mem.writeInt(u32, index_bytes[12..16], 16, .little);
    const index: Index = try .parse(&index_bytes);

    const header: FilmHeader = .{ .magic = FilmHeader.vq03.*, .size = .{ 128, 128 }, .frames_and_one = 3 };
    var data: [32]u8 = @splat(0);
    @memcpy(data[0..12], std.mem.asBytes(&header));
    @memcpy(data[16..28], std.mem.asBytes(&header));
    const first = try index.film(&data, 0);
    try std.testing.expectEqual(2, first.header.frames());
    try std.testing.expectEqual(4, first.chunks.len);
    try std.testing.expectEqual(4, (try index.film(&data, 1)).chunks.len);
    try std.testing.expectError(error.NotAFilm, index.film(&data, 2));

    data[16] = 'X';
    try std.testing.expectError(error.NotAFilm, index.film(&data, 1));
    try std.testing.expectError(error.NotAnIndex, Index.parse(index_bytes[0..12]));
}
