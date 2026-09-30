//! The reader of IFF files, Electronic Arts' Interchange File Format, which the saved games are
//! ([docs/formats/save.md](../../../docs/formats/save.md)): chunks, each an id, its length
//! big-endian and that many bytes, padded to an even length, where a `FORM` holds a type and then
//! chunks of its own (`0x004908B0` to `0x00490DBF`). **Unknown:** its source file. The code lies
//! between `hudmovie.cpp`'s and `language.cpp`'s, and no string places it; this module is named
//! for what it reads. The game reads through its file class (`0x0045E640` to `0x0045EA8F`),
//! seeking as it goes; OpenReliant reads the whole file first. `game_save` writes the files
//! (`gameflow/save.zig`).
//!
//! **Fix:** a header or a length that runs past the file's end ends the chunks there, where the
//! game reads on from what its buffer held before.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("../../formats/layout.zig");

/// A form's id: the chunk that holds a type, then chunks of its own.
pub const form_id = "FORM";

/// A chunk's id, and a form's type.
pub const Id = [4]u8;

/// What starts each chunk: its id and its length, big-endian, which leaves out the padding to an
/// even length.
pub const ChunkHeader = extern struct {
    id: Id,
    size: layout.Big(u32),

    comptime {
        assert(@sizeOf(ChunkHeader) == 8);
    }
};

/// A chunk's length with its padding to an even length (`0x00490BB0`).
pub fn paddedSize(size: u32) u64 {
    return @as(u64, size) + (size & 1);
}

/// A chunk as the reader finds it: its id, where it is a form its type, and its body, the bytes
/// its length gives as far as the file has them, a form's after its type, which starts `at`.
const Found = struct {
    id: Id,
    form_type: ?Id,
    at: usize,
    body: []const u8,
};

/// A reader of an IFF file's chunks, those of the form it has entered, or the file's own.
pub const Reader = struct {
    bytes: []const u8,
    /// The chunks searched, from the first to the end of the form entered, or the file's.
    first: usize = 0,
    end: usize,

    /// A reader of `bytes`, at the file's own chunks (`0x00490930`).
    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes, .end = bytes.len };
    }

    /// `iff_find_form` (`0x004909D0`), searching from the first chunk: enters the first form of
    /// type `form_type`, whose chunks are then those searched (`0x00490B20`). False where there is
    /// none, the reader left as it was.
    pub fn enter(reader: *Reader, form_type: *const Id) bool {
        var chunks = reader.walk();
        while (chunks.next()) |found| {
            const kind = found.form_type orelse continue;
            if (!std.mem.eql(u8, &kind, form_type)) continue;
            reader.first = found.at;
            reader.end = found.at + found.body.len;
            return true;
        }
        return false;
    }

    /// `iff_find_chunk` (`0x00490C40`), searching from the first chunk: the body of the first chunk
    /// `id`, forms passed over whole; null where there is none. The body runs as far as the
    /// chunk's length, cut at the file's end, as the file class cuts a read (`0x0045E8D0`).
    pub fn chunk(reader: Reader, id: *const Id) ?[]const u8 {
        var chunks = reader.walk();
        while (chunks.next()) |found| {
            if (found.form_type == null and std.mem.eql(u8, &found.id, id)) return found.body;
        }
        return null;
    }

    fn walk(reader: Reader) Chunks {
        return .{ .bytes = reader.bytes[0..reader.end], .at = reader.first };
    }
};

/// The chunks from `at` on, a header at a time (`iff_read_header`, `0x00490BB0`).
const Chunks = struct {
    bytes: []const u8,
    at: usize,

    fn next(chunks: *Chunks) ?Found {
        const start = chunks.at;
        const header = layout.view(ChunkHeader, chunks.bytes[@min(start, chunks.bytes.len)..]) catch return null;
        const size = header.size.get();
        chunks.at +|= std.math.cast(usize, @sizeOf(ChunkHeader) + paddedSize(size)) orelse std.math.maxInt(usize);
        const at = start + @sizeOf(ChunkHeader);
        const body = chunks.bytes[at..][0..@min(chunks.bytes.len - at, size)];
        if (!std.mem.eql(u8, &header.id, form_id)) return .{ .id = header.id, .form_type = null, .at = at, .body = body };
        if (body.len < @sizeOf(Id)) return null;
        return .{ .id = header.id, .form_type = body[0..@sizeOf(Id)].*, .at = at + @sizeOf(Id), .body = body[@sizeOf(Id)..] };
    }
};

/// Builds IFF files, for tests.
pub const testing = struct {
    /// A chunk of `body`, with its header and its padding.
    pub fn chunk(comptime id: *const Id, comptime body: []const u8) []const u8 {
        const padding = if (body.len % 2 == 1) "\x00" else "";
        return std.mem.toBytes(ChunkHeader{ .id = id.*, .size = .of(body.len) }) ++ body ++ padding;
    }

    /// A form of type `form_type` holding `chunks`.
    pub fn form(comptime form_type: *const Id, comptime chunks: []const u8) []const u8 {
        return chunk(form_id, form_type ++ chunks);
    }
};

test Reader {
    // A form holding a name of odd length and its pad byte, a form of its own with a chunk of the
    // same id, and the chunk after it.
    const bytes = comptime testing.form("SAVE", testing.chunk("NAME", "abc") ++
        testing.form("PART", testing.chunk("MISS", "inner")) ++
        testing.chunk("MISS", "outer!"));

    var reader: Reader = .init(bytes);
    // At the file's own chunks there is only the form.
    try std.testing.expectEqual(null, reader.chunk("NAME"));
    try std.testing.expect(!reader.enter("LOAD"));
    try std.testing.expect(reader.enter("SAVE"));
    try std.testing.expectEqualStrings("abc", reader.chunk("NAME").?);
    // The form within is passed over, and searching starts from the first chunk each time.
    try std.testing.expectEqualStrings("outer!", reader.chunk("MISS").?);
    try std.testing.expectEqualStrings("abc", reader.chunk("NAME").?);
    try std.testing.expectEqual(null, reader.chunk("VERS"));

    // Into the form within, then its chunk.
    try std.testing.expect(reader.enter("PART"));
    try std.testing.expectEqualStrings("inner", reader.chunk("MISS").?);
}

test "Reader at the file's end" {
    // A length past the file's end gives what the file has.
    const long = std.mem.toBytes(ChunkHeader{ .id = "NAME".*, .size = .of(9) }) ++ "abc";
    try std.testing.expectEqualStrings("abc", Reader.init(long).chunk("NAME").?);
    // A header cut short ends the chunks, as does a form too short for its type.
    try std.testing.expectEqual(null, Reader.init("NAME\x00\x00").chunk("NAME"));
    var reader: Reader = .init(testing.chunk(form_id, "SA"));
    try std.testing.expect(!reader.enter("SAVE"));
}
