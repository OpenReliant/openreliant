//! Nero's `.nrg` disc images: the tracks' sectors, then a table of chunks that says where each
//! track lies, and last a footer that points at the table
//! ([docs/formats/disc-images.md](../../../docs/formats/disc-images.md#nero-images)).

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("../layout.zig");

/// The footer of an image of Nero 5.5 and later: the last 12 bytes of the file.
const Footer = extern struct {
    tag: [4]u8,
    /// Where the chunks start.
    table: layout.Big(u64) align(1),

    const magic = "NER5";
};

/// The footer of an earlier image: the last 8 bytes of the file.
const OldFooter = extern struct {
    tag: [4]u8,
    table: layout.Big(u32) align(1),

    const magic = "NERO";
};

/// The most of the file's end the reader looks at for the footer.
pub const footer_size = @sizeOf(Footer);

/// The most bytes of chunks the reader takes: a disc of 99 tracks needs far less.
pub const max_table = 64 * 1024;

/// A chunk's header: its name and the size of what follows.
const Chunk = extern struct {
    name: [4]u8,
    size: layout.Big(u32) align(1),
};

/// What a disc-at-once chunk (`DAOI`, `DAOX`) starts with, before its tracks.
const DiscHeader = extern struct {
    /// The chunk's size again, little-endian.
    size: u32 align(1),
    catalogue: [13]u8,
    _unknown_11: u8,
    toc_type: u8,
    _unknown_13: u8,
    first_track: u8,
    last_track: u8,
};

/// A track of a `DAOX` chunk.
const DiscTrack = extern struct {
    isrc: [12]u8,
    sector_size: layout.Big(u16) align(1),
    mode: layout.Big(u16) align(1),
    _unknown_10: layout.Big(u16) align(1),
    /// Where the track's pregap starts in the file, where its data starts, and where it ends.
    pregap: layout.Big(u64) align(1),
    start: layout.Big(u64) align(1),
    end: layout.Big(u64) align(1),
};

/// A track of a `DAOI` chunk, an earlier image's, with 32-bit offsets.
const OldDiscTrack = extern struct {
    isrc: [12]u8,
    sector_size: layout.Big(u16) align(1),
    mode: layout.Big(u16) align(1),
    _unknown_10: layout.Big(u16) align(1),
    pregap: layout.Big(u32) align(1),
    start: layout.Big(u32) align(1),
    end: layout.Big(u32) align(1),
};

/// How a track's sectors are stored, as the chunks number it.
const audio_mode = 7;

comptime {
    assert(@sizeOf(Footer) == 12);
    assert(@sizeOf(OldFooter) == 8);
    assert(@sizeOf(DiscHeader) == 22);
    assert(@sizeOf(DiscTrack) == 42);
    assert(@sizeOf(OldDiscTrack) == 30);
}

/// Where the chunks of an image start, read from `tail`, the last `footer_size` bytes of a file
/// `size` bytes long; null for a file that isn't a Nero image.
pub fn tableStart(tail: *const [footer_size]u8, size: u64) ?u64 {
    const new = layout.view(Footer, tail) catch unreachable;
    const old = layout.view(OldFooter, tail[footer_size - @sizeOf(OldFooter) ..]) catch unreachable;
    const at: u64 = if (std.mem.eql(u8, &new.tag, Footer.magic))
        new.table.get()
    else if (std.mem.eql(u8, &old.tag, OldFooter.magic))
        old.table.get()
    else
        return null;
    return if (at < size) at else null;
}

/// A data track: where its sectors lie in the file, how large each is, and how many there are.
pub const Track = struct {
    offset: u64,
    sector_size: u32,
    length: u32,
};

pub const Error = error{BadTable};

/// The first data track `table`, an image's chunks, lists in its disc-at-once chunk; null where
/// it lists none. **Unverified:** an image written track at once, whose tracks are in `ETNF` or
/// `ETN2` chunks, which the reader passes over.
pub fn firstDataTrack(table: []const u8) Error!?Track {
    var at: usize = 0;
    while (at + @sizeOf(Chunk) <= table.len) {
        const chunk = layout.view(Chunk, table[at..]) catch return error.BadTable;
        const size = chunk.size.get();
        const body_at = at + @sizeOf(Chunk);
        if (size > table.len - body_at) return error.BadTable;
        const body = table[body_at..][0..size];
        if (std.mem.eql(u8, &chunk.name, "END!")) break;
        if (std.mem.eql(u8, &chunk.name, "DAOX")) {
            if (try dataTrack(DiscTrack, body)) |track| return track;
        } else if (std.mem.eql(u8, &chunk.name, "DAOI")) {
            if (try dataTrack(OldDiscTrack, body)) |track| return track;
        }
        at = body_at + size;
    }
    return null;
}

/// The first track of `body`, a disc-at-once chunk's of `Record`s, that isn't audio.
fn dataTrack(comptime Record: type, body: []const u8) Error!?Track {
    if (body.len < @sizeOf(DiscHeader)) return error.BadTable;
    const records = body[@sizeOf(DiscHeader)..];
    const tracks = layout.array(Record, records, records.len / @sizeOf(Record)) catch return error.BadTable;
    for (tracks) |track| {
        if (track.mode.get() == audio_mode) continue;
        const sector_size = track.sector_size.get();
        const start: u64 = track.start.get();
        const end: u64 = track.end.get();
        if (sector_size == 0 or end < start) return error.BadTable;
        return .{
            .offset = start,
            .sector_size = sector_size,
            .length = std.math.cast(u32, (end - start) / sector_size) orelse return error.BadTable,
        };
    }
    return null;
}

/// A Nero image for the tests: `sectors`, each `sector_size` bytes, as the one track of a
/// disc-at-once image, after `pregap` bytes of pregap.
pub fn testImage(gpa: std.mem.Allocator, pregap: usize, sector_size: u16, sectors: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.splatByteAll(0, pregap);
    try writer.writeAll(sectors);
    const table_at = pregap + sectors.len;
    try writer.writeAll("DAOX");
    try writer.writeInt(u32, @sizeOf(DiscHeader) + @sizeOf(DiscTrack), .big);
    var header = std.mem.zeroes(DiscHeader);
    header.size = @sizeOf(DiscHeader) + @sizeOf(DiscTrack);
    header.first_track = 1;
    header.last_track = 1;
    try writer.writeAll(std.mem.asBytes(&header));
    // The track, field by field: no ISRC, its sector size, Mode 1, and its three offsets.
    try writer.splatByteAll(0, 12);
    try writer.writeInt(u16, sector_size, .big);
    try writer.writeInt(u16, 0, .big);
    try writer.writeInt(u16, 0, .big);
    try writer.writeInt(u64, 0, .big);
    try writer.writeInt(u64, pregap, .big);
    try writer.writeInt(u64, table_at, .big);
    try writer.writeAll("END!");
    try writer.writeInt(u32, 0, .big);
    try writer.writeAll(Footer.magic);
    try writer.writeInt(u64, table_at, .big);
    return out.toOwnedSlice();
}

test firstDataTrack {
    const gpa = std.testing.allocator;
    const sectors: [3 * 2048]u8 = @splat(0x5A);
    const image = try testImage(gpa, 4096, 2048, &sectors);
    defer gpa.free(image);
    const table_at = tableStart(image[image.len - footer_size ..][0..footer_size], image.len).?;
    try std.testing.expectEqual(4096 + sectors.len, table_at);
    const track = (try firstDataTrack(image[table_at..])).?;
    try std.testing.expectEqual(4096, track.offset);
    try std.testing.expectEqual(2048, track.sector_size);
    try std.testing.expectEqual(3, track.length);
    // Another file's end isn't a footer, and a table cut short isn't read.
    try std.testing.expectEqual(null, tableStart("not an image", 100));
    try std.testing.expectError(error.BadTable, firstDataTrack(image[table_at .. table_at + 20]));
}
