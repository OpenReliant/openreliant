//! The pilots' face films (`.fm8`, in `pilots.hog`), which the radio's window plays as a pilot
//! speaks (`hudmovie.cpp`): a chain of chunks, each scrambled, a key frame with the palette and
//! the frame compressed with RefPack, delta frames of 4 by 4 blocks moved from the frame before,
//! given whole or drawn in four colours, and the end
//! ([docs/formats/fm8.md](../../../docs/formats/fm8.md)). **Unverified:** no string places its
//! code (`0x004A6520` to `0x004A7060`), which lies between `srofiles.cpp`'s and `timer.cpp`'s;
//! OpenReliant calls it `talkie.cpp`, which sorts between the two.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const layout = @import("../../formats/layout.zig");
const refpack = @import("../../formats/refpack.zig");
const scramble = @import("../../formats/scramble.zig");
const spr = @import("../../formats/spr.zig");

/// The key the chunks are scrambled with (`talkie_unscramble`, `0x004A6E30`).
pub const key = [4]u8{ 0xA3, 0x27, 0xB7, 0xDD };

/// How many bytes at a chunk's end are left plain (`talkie_unscramble`), in every shipped film.
pub const plain_tail = 8;

/// How many frames a film plays a second (`hudmovie_init`, `0x0048D046`).
pub const frames_per_second = 15;

/// A palette of 256 colours, red, green and blue a byte each, as the sprites have theirs.
pub const Palette = [spr.palette_size]u8;

/// The side of a block, in pixels: a frame is blocks of 4 by 4.
pub const block = 4;
pub const block_pixels = block * block;

/// The bits of each of a motion vector's two parts, and the bytes a pattern takes: its four
/// colours, and two bits for each of its pixels.
pub const vector_bits = 10;
pub const pattern_size = 4 + block_pixels / 4;

/// The most bits a map's entry takes, which `field` reads.
pub const max_map_bits = 16;

/// What every chunk starts with.
pub const Header = extern struct {
    id: [4]u8,
    /// The chunk's size, this header included.
    size: u32,

    comptime {
        assert(@sizeOf(Header) == 8);
    }
};

/// The kinds of chunk (`talkie_frame`, `0x004A66A0`).
pub const Id = enum {
    /// `fYEK`: a key frame.
    key,
    /// `fLED`: a delta frame.
    delta,
    /// `fDNE`: the end (`talkie_read_chunk`, `0x004A6D80`).
    end,
    /// Anything else, which the game passes over.
    other,

    pub fn of(id: [4]u8) Id {
        const ids = std.StaticStringMap(Id).initComptime(.{ .{ "fYEK", .key }, .{ "fLED", .delta }, .{ "fDNE", .end } });
        return ids.get(&id) orelse .other;
    }
};

/// A key frame's header (`talkie_key`, `0x004A6980`): the frame's size, and the palette's entries
/// and the first of them, which lie after it, then the pixels. **Unknown:** the last word, zero in
/// every shipped film.
pub const KeyHeader = extern struct {
    chunk: Header,
    height: u16,
    width: u16,
    /// How many palette entries the chunk holds, and the first entry they fill: the palette lies
    /// `first * 3` from the header's end, and the pixels `entries * 3`.
    entries: u16,
    first: u16,
    _unknown_10: u32,

    /// The header's fields as the game reads them; or, where the entries are fewer than the
    /// first, as an earlier tool wrote them, the width before the height and the first entry
    /// before the entries, which the ten unused films in `pilots.hog` have and the game misreads
    /// (`Order`).
    pub fn fields(header: KeyHeader) Fields {
        if (header.entries >= header.first) return .{ .width = header.width, .height = header.height, .entries = header.entries, .first = header.first };
        return .{ .width = header.height, .height = header.width, .entries = header.first, .first = header.entries };
    }

    pub const Fields = struct { width: u16, height: u16, entries: u16, first: u16 };

    comptime {
        assert(@offsetOf(KeyHeader, "height") == 0x08);
        assert(@offsetOf(KeyHeader, "width") == 0x0A);
        assert(@offsetOf(KeyHeader, "entries") == 0x0C);
        assert(@offsetOf(KeyHeader, "first") == 0x0E);
        assert(@sizeOf(KeyHeader) == 0x14);
    }
};

/// The orders a delta frame's header holds its four counts in: the game's, and two earlier
/// tools', which the ten unused films in `pilots.hog` have. The whole blocks' count is second in
/// all three; a chunk's order is told from its size (`DeltaHeader.order`).
pub const Order = enum {
    /// The bits, the whole blocks, the vectors, the patterns: what the game reads.
    bits_first,
    /// The vectors, the whole blocks, the patterns, the bits.
    vectors_first,
    /// The patterns, the whole blocks, the bits, the vectors.
    patterns_first,
};

/// A delta frame's header (`talkie_delta`, `0x004A66F0`): how many bits the map takes for each
/// block, how many blocks are given whole, how many motion vectors there are, and how many blocks
/// are drawn in four colours, in the game's order (`Order.bits_first`). After it, the vectors, the
/// whole blocks, the patterns, and the map. **Unknown:** the last word, zero in every shipped
/// film.
pub const DeltaHeader = extern struct {
    chunk: Header,
    bits: u16,
    whole: u16,
    vectors: u16,
    patterns: u16,
    _unknown_10: u32,

    /// The counts as `order` has them.
    pub fn counts(header: DeltaHeader, held: Order) Counts {
        return switch (held) {
            .bits_first => .{ .bits = header.bits, .whole = header.whole, .vectors = header.vectors, .patterns = header.patterns },
            .vectors_first => .{ .vectors = header.bits, .whole = header.whole, .patterns = header.vectors, .bits = header.patterns },
            .patterns_first => .{ .patterns = header.bits, .whole = header.whole, .bits = header.vectors, .vectors = header.patterns },
        };
    }

    /// The first order, the game's first, whose counts lay out a chunk of `size` bytes for a
    /// frame of `blocks` blocks (`Counts.size`), with bits enough for every entry; or null.
    pub fn order(header: DeltaHeader, size: usize, blocks: usize) ?Order {
        for (std.enums.values(Order)) |candidate| {
            const found = header.counts(candidate);
            if (found.bits > max_map_bits) continue;
            const entries = @as(usize, found.whole) + found.vectors + found.patterns;
            if (found.size(blocks) == size and (@as(usize, 1) << @intCast(found.bits)) >= entries) return candidate;
        }
        return null;
    }

    pub const Counts = struct {
        bits: u16,
        whole: u16,
        vectors: u16,
        patterns: u16,

        /// The bytes a chunk with these counts takes for a frame of `blocks` blocks: the header,
        /// the vectors and the map each packed on to whole words, the whole blocks and the
        /// patterns.
        pub fn size(these: Counts, blocks: usize) usize {
            return @sizeOf(DeltaHeader) + wordBytes(@as(usize, these.vectors) * 2 * vector_bits) + @as(usize, these.whole) * block_pixels + @as(usize, these.patterns) * pattern_size + wordBytes(blocks * these.bits);
        }
    };

    comptime {
        assert(@offsetOf(DeltaHeader, "bits") == 0x08);
        assert(@offsetOf(DeltaHeader, "whole") == 0x0A);
        assert(@offsetOf(DeltaHeader, "vectors") == 0x0C);
        assert(@offsetOf(DeltaHeader, "patterns") == 0x0E);
        assert(@sizeOf(DeltaHeader) == 0x14);
    }
};

/// A chunk, its header included, unscrambled.
pub const Chunk = struct {
    id: Id,
    bytes: []u8,
};

/// The chunks of a film, taken in turn from its bytes.
pub const Chunks = struct {
    bytes: []u8,
    at: usize = 0,

    /// The next chunk, unscrambled in place (`unscramble`), or null past the end chunk or the
    /// film's end, or at a chunk too short for its header or reaching past the end.
    pub fn next(chunks: *Chunks) ?Chunk {
        if (chunks.at >= chunks.bytes.len) return null;
        const rest = chunks.bytes[chunks.at..];
        const header = layout.view(Header, rest) catch return null;
        const size = header.size;
        if (size < @sizeOf(Header) or size > rest.len) {
            chunks.at = chunks.bytes.len;
            return null;
        }
        const id: Id = .of(header.id);
        chunks.at = if (id == .end) chunks.bytes.len else chunks.at + size;
        unscramble(rest[0..size]);
        return .{ .id = id, .bytes = rest[0..size] };
    }
};

/// `talkie_unscramble` (`0x004A6E30`): `chunk` XORed with `key` (`scramble.xor`) past its header
/// and up to its last `plain_tail` bytes; one no longer than both is left as it is.
pub fn unscramble(chunk: []u8) void {
    if (chunk.len <= @sizeOf(Header) + plain_tail) return;
    scramble.xor(chunk[@sizeOf(Header) .. chunk.len - plain_tail], key);
}

pub const Error = error{
    /// A chunk too short for what its header says, a frame of a size that is not blocks, a
    /// delta before any key frame, or pixels RefPack cannot expand.
    BadChunk,
    OutOfMemory,
};

/// A film's decoder as the game lays it out (`talkie_state_new`, `0x004A6CC0`), which `Film`
/// keeps its own way: the frame's size, the key frame's palette fields, the delta's counts, the
/// tables' capacities and the tables, then the palette and the palette converted for the display.
pub const State = extern struct {
    width: i32,
    height: i32,
    entries: i32,
    first: i32,
    vectors: i32,
    whole: i32,
    patterns: i32,
    bits: i32,
    vector_capacity: i32,
    block_capacity: i32,
    /// The frames, each 4 bytes of size then the pixels.
    frames: [2]u32,
    map: u32,
    rows: u32,
    blocks: u32,
    packed_vectors: u32,
    offsets: u32,
    palette: Palette,
    /// The palette in the display's colour depth, 16 bits an entry.
    converted: [spr.palette_size / 3]u16,

    comptime {
        assert(@offsetOf(State, "frames") == 0x28);
        assert(@offsetOf(State, "palette") == 0x44);
        assert(@offsetOf(State, "converted") == 0x344);
        assert(@sizeOf(State) == 0x544);
    }
};

/// A film being decoded: what the game keeps in `0x544` bytes (`talkie_state_new`, `0x004A6CC0`).
pub const Film = struct {
    gpa: Allocator,
    width: usize = 0,
    height: usize = 0,
    palette: Palette = @splat(0),
    /// The palette's entry the window draws see-through, where the film has one: red 255 or 254,
    /// green 0 and blue 216 or 215 (`0x004A6A1B`).
    transparent: ?u8 = null,
    /// The frame decoded and the one before, each `width * height` pixels, which each delta frame
    /// swaps (`+0x28`, `+0x2C`).
    frames: [2][]u8 = .{ &.{}, &.{} },
    shown: u1 = 0,
    /// The blocks' map (`+0x30`), the blocks a delta gives (`+0x38`), and how far its vectors move
    /// each block from (`+0x40`).
    map: []u32 = &.{},
    blocks: []u8 = &.{},
    offsets: []i32 = &.{},

    pub fn init(gpa: Allocator) Film {
        return .{ .gpa = gpa };
    }

    /// `talkie_state_free` (`0x004A6CF0`).
    pub fn deinit(film: *Film) void {
        for (film.frames) |held| film.gpa.free(held);
        film.gpa.free(film.map);
        film.gpa.free(film.blocks);
        film.gpa.free(film.offsets);
        film.* = .{ .gpa = film.gpa };
    }

    /// The frame decoded last: its pixels, row by row, each an entry of `palette`.
    pub fn frame(film: *const Film) []const u8 {
        return film.frames[film.shown];
    }

    /// `talkie_frame` (`0x004A66A0`): `chunk` decoded, a key frame (`keyFrame`) or a delta frame
    /// (`deltaFrame`) giving the film its next frame (`frame`), the end or any other chunk giving
    /// none. Whether there is a new frame.
    pub fn decode(film: *Film, chunk: Chunk) Error!bool {
        switch (chunk.id) {
            .key => try film.keyFrame(chunk.bytes),
            .delta => try film.deltaFrame(chunk.bytes),
            .end, .other => return false,
        }
        return true;
    }

    /// `talkie_key` (`0x004A6980`): the frame's size and the palette from `bytes`, a key frame
    /// chunk, the frames and the map made for that size, and the frame expanded (`refpack`).
    ///
    /// The game converts the palette's entries from `first` to `entries` for the hardware's colour
    /// depth, which OpenReliant leaves to the drawing, and looks for the see-through colour among
    /// them (`transparent`).
    fn keyFrame(film: *Film, bytes: []const u8) Error!void {
        const header = (layout.view(KeyHeader, bytes) catch return error.BadChunk).fields();
        const width: usize = header.width;
        const height: usize = header.height;
        if (width == 0 or height == 0 or width % block != 0 or height % block != 0) return error.BadChunk;
        const palette_at = @sizeOf(KeyHeader) + @as(usize, header.first) * 3;
        const pixels_at = @sizeOf(KeyHeader) + @as(usize, header.entries) * 3;
        if (palette_at + film.palette.len > bytes.len or pixels_at > bytes.len) return error.BadChunk;
        @memcpy(&film.palette, bytes[palette_at..][0..film.palette.len]);
        film.transparent = transparentIn(film.palette, header.first, header.entries);
        try film.resize(width, height);
        const stream = bytes[pixels_at..];
        const compressed = refpack.readHeader(stream) catch return error.BadChunk;
        const pixels = film.frames[film.shown];
        const written = refpack.decompressInto(pixels, stream[compressed.len..]) catch return error.BadChunk;
        if (written != pixels.len) return error.BadChunk;
    }

    /// The frames and the map made for a frame of `width` by `height`, the old let go of.
    fn resize(film: *Film, width: usize, height: usize) Error!void {
        for (&film.frames) |*held| {
            film.gpa.free(held.*);
            held.* = &.{};
        }
        film.gpa.free(film.map);
        film.map = &.{};
        film.width = width;
        film.height = height;
        for (&film.frames) |*held| held.* = try film.gpa.alloc(u8, width * height);
        @memset(film.frames[0], 0);
        @memset(film.frames[1], 0);
        film.map = try film.gpa.alloc(u32, width * height / block_pixels);
    }

    /// `talkie_delta` (`0x004A66F0`): the next frame from `bytes`, a delta chunk, and the frame
    /// before, the two swapped first: the vectors unpacked into how far each moves a block from
    /// (`offsets`), the whole blocks copied and the patterns drawn after them (`blocks`,
    /// `drawPatterns`), the map unpacked, and the frame assembled (`assemble`). The vectors take
    /// a whole number of words, and so does the map. The header's counts are read in whichever
    /// order lays the chunk out (`DeltaHeader.order`), where the game reads its own alone.
    ///
    /// The game keeps a table of the rows' starts to add a vector's rows by, which for more rows
    /// than the frame has reads beside it; OpenReliant works the offset out.
    fn deltaFrame(film: *Film, bytes: []const u8) Error!void {
        const header = layout.view(DeltaHeader, bytes) catch return error.BadChunk;
        if (film.width == 0) return error.BadChunk;
        const order = header.order(bytes.len, film.map.len) orelse return error.BadChunk;
        const counts = header.counts(order);
        const bits: u5 = @intCast(counts.bits);
        const vectors: usize = counts.vectors;
        const whole: usize = counts.whole;
        const patterns: usize = counts.patterns;
        film.shown ^= 1;
        film.offsets = try growTo(i32, film.gpa, film.offsets, vectors);
        film.blocks = try growTo(u8, film.gpa, film.blocks, (whole + patterns) * block_pixels);

        var at: usize = @sizeOf(DeltaHeader);
        const vector_bytes = wordBytes(vectors * 2 * vector_bits);
        if (at + vector_bytes > bytes.len) return error.BadChunk;
        for (film.offsets[0..vectors], 0..) |*offset, i| {
            const dx = signed(field(bytes[at..], 2 * i * vector_bits, vector_bits));
            const dy = signed(field(bytes[at..], (2 * i + 1) * vector_bits, vector_bits));
            offset.* = dy * @as(i32, @intCast(film.width)) + dx;
        }
        at += vector_bytes;
        const whole_bytes = whole * block_pixels;
        if (at + whole_bytes > bytes.len) return error.BadChunk;
        @memcpy(film.blocks[0..whole_bytes], bytes[at..][0..whole_bytes]);
        at += whole_bytes;
        const pattern_bytes = patterns * pattern_size;
        if (at + pattern_bytes > bytes.len) return error.BadChunk;
        drawPatterns(bytes[at..][0..pattern_bytes], film.blocks[whole_bytes..][0 .. patterns * block_pixels]);
        at += pattern_bytes;
        if (at + wordBytes(film.map.len * bits) > bytes.len) return error.BadChunk;
        for (film.map, 0..) |*entry, i| entry.* = field(bytes[at..], i * bits, bits);
        film.assemble(vectors, whole + patterns);
    }

    /// `blocks_assemble` (`0x004BE884`): the frame from its map, block by block: a block whose
    /// entry is below `vectors` is copied from the frame before, moved by its vector's offset; any
    /// other from the blocks given, `given` of them, by the entry less `vectors`.
    ///
    /// A block a vector moves from outside the frame before, or an entry past the blocks given,
    /// which the game reads from the memory beside them, is left as the frame's buffer holds it.
    fn assemble(film: *Film, vectors: usize, given: usize) void {
        const width = film.width;
        const previous = film.frames[film.shown ^ 1];
        const next = film.frames[film.shown];
        const across = width / block;
        for (film.map, 0..) |entry, i| {
            const base = (i / across) * block * width + (i % across) * block;
            const source = if (entry < vectors) moved: {
                const from = @as(i64, @intCast(base)) + film.offsets[entry];
                if (from < 0 or @as(u64, @intCast(from)) + (block - 1) * width + block > previous.len) continue;
                break :moved previous[@intCast(from)..];
            } else if (entry - vectors < given) film.blocks[(entry - vectors) * block_pixels ..] else continue;
            const stride: usize = if (entry < vectors) width else block;
            for (0..block) |row| @memcpy(next[base + row * width ..][0..block], source[row * stride ..][0..block]);
        }
    }
};

/// `talkie_patterns` (`0x004A6590`): the blocks drawn in four colours, `pattern_size` bytes each
/// in `patterns`, into `blocks`, `block_pixels` each: the four colours, then two bits for each
/// pixel from the last to the first, the highest bits the first pixel's.
fn drawPatterns(patterns: []const u8, blocks: []u8) void {
    for (0..patterns.len / pattern_size) |i| {
        const pattern = patterns[i * pattern_size ..][0..pattern_size];
        const colours = pattern[0..4];
        const map = std.mem.readInt(u32, pattern[4..8], .little);
        for (blocks[i * block_pixels ..][0..block_pixels], 0..) |*pixel, k| {
            pixel.* = colours[(map >> @intCast(2 * (block_pixels - 1 - k))) & 3];
        }
    }
}

/// The palette entry drawn see-through, among the `entries` from `first` (`0x004A6A1B`): the
/// first of red 255, green 0 and blue 216, or red 254, green 0 and blue 215 or 216; or null.
fn transparentIn(palette: Palette, first: u16, entries: u16) ?u8 {
    var index: usize = first;
    while (index < entries and index < palette.len / 3) : (index += 1) {
        const colour = palette[index * 3 ..][0..3];
        const magenta = (colour[0] == 0xFF and colour[2] == 0xD8) or (colour[0] == 0xFE and (colour[2] == 0xD7 or colour[2] == 0xD8));
        if (magenta and colour[1] == 0) return @intCast(index);
    }
    return null;
}

/// The `bits` bits of `bytes` from bit `at`, least significant first, as the game reads them
/// from the word there (`talkie_unpack_vectors`, `0x004A6520`; `blocks_unpack_map`,
/// `0x004BE937`): zeros past the end.
fn field(bytes: []const u8, at: usize, bits: u5) u32 {
    var word: u32 = 0;
    for (0..4) |i| {
        if (at / 8 + i < bytes.len) word |= @as(u32, bytes[at / 8 + i]) << @intCast(8 * i);
    }
    return (word >> @intCast(at % 8)) & ((@as(u32, 1) << bits) - 1);
}

/// A vector's part as a whole number: `vector_bits` wide, its top bit the sign.
fn signed(value: u32) i32 {
    const sign: u32 = 1 << (vector_bits - 1);
    return if (value & sign != 0) @as(i32, @intCast(value)) - (1 << vector_bits) else @intCast(value);
}

/// The bytes `bits` bits take, rounded up to whole words.
pub fn wordBytes(bits: usize) usize {
    return ((bits + 31) & ~@as(usize, 31)) / 8;
}

/// `held` with room for `len` items, made larger where it is smaller, as the game frees and
/// allocates its tables again.
fn growTo(comptime T: type, gpa: Allocator, held: []T, len: usize) Allocator.Error![]T {
    if (held.len >= len) return held;
    return gpa.realloc(held, len);
}

/// Films built by hand for the tests.
pub const testing = struct {
    /// A chunk of `id` over `payload`, scrambled as the films are, in `gpa`.
    pub fn chunk(gpa: Allocator, id: *const [4]u8, payload: []const u8) Allocator.Error![]u8 {
        const bytes = try gpa.alloc(u8, @sizeOf(Header) + payload.len);
        const header: Header = .{ .id = id.*, .size = @intCast(bytes.len) };
        @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&header));
        @memcpy(bytes[@sizeOf(Header)..], payload);
        unscramble(bytes);
        return bytes;
    }

    /// A key frame's payload: a frame of `width` by `height` from `pixels`, every one stored as
    /// it is, over a palette of `palette`.
    pub fn keyPayload(gpa: Allocator, width: u16, height: u16, palette: *const Palette, pixels: []const u8) Allocator.Error![]u8 {
        assert(pixels.len == @as(usize, width) * height and pixels.len % 4 == 0 and pixels.len <= 32 * 4);
        const fields = [_]u16{ height, width, 256, 0 };
        var payload: std.ArrayList(u8) = .empty;
        errdefer payload.deinit(gpa);
        for (fields) |value| try payload.appendSlice(gpa, &std.mem.toBytes(value));
        try payload.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
        try payload.appendSlice(gpa, palette);
        // RefPack: the magic, three bytes of size, one run of literals, and the stop.
        try payload.appendSlice(gpa, &[_]u8{ 0x10, refpack.signature, 0, 0, @intCast(pixels.len), @intCast(0xE0 + pixels.len / 4 - 1) });
        try payload.appendSlice(gpa, pixels);
        try payload.append(gpa, 0xFC);
        return payload.toOwnedSlice(gpa);
    }
};

test Chunks {
    const gpa = std.testing.allocator;
    const first = try testing.chunk(gpa, "fYEK", "0123456789abcdef");
    defer gpa.free(first);
    const last = try testing.chunk(gpa, "fDNE", "");
    defer gpa.free(last);
    const film = try std.mem.concat(gpa, u8, &.{ first, last, "fLED\x14\x00\x00\x00trailing" });
    defer gpa.free(film);
    // Scrambled past the header up to the last eight bytes, which stay plain.
    try std.testing.expectEqualStrings("89abcdef", first[16..]);
    try std.testing.expect(!std.mem.eql(u8, "01234567", first[8..16]));
    var chunks: Chunks = .{ .bytes = film };
    const key_chunk = chunks.next().?;
    try std.testing.expectEqual(Id.key, key_chunk.id);
    try std.testing.expectEqualStrings("0123456789abcdef", key_chunk.bytes[8..]);
    // The end chunk ends the film, whatever follows.
    try std.testing.expectEqual(Id.end, chunks.next().?.id);
    try std.testing.expectEqual(null, chunks.next());
    // A chunk reaching past the end is not given.
    var short: Chunks = .{ .bytes = film[0..12] };
    try std.testing.expectEqual(null, short.next());
}

test Film {
    const gpa = std.testing.allocator;
    var palette: Palette = @splat(0);
    palette[3..6].* = .{ 255, 0, 0 };
    palette[6..9].* = .{ 0, 255, 0 };
    palette[12..15].* = .{ 255, 0, 216 };
    // Eight by four: a block of 1s and a block of 2s.
    var pixels: [32]u8 = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = if (i % 8 < 4) 1 else 2;
    const key_payload = try testing.keyPayload(gpa, 8, 4, &palette, &pixels);
    defer gpa.free(key_payload);
    const key_chunk = try testing.chunk(gpa, "fYEK", key_payload);
    defer gpa.free(key_chunk);
    // A delta: two bits an entry; one whole block of 3s; one vector four to the left; one
    // pattern of the colours 10 to 13, its rows 13, 12, 11, 10. The first block takes the
    // pattern, the second the vector, which copies the first block of the frame before.
    var delta: std.ArrayList(u8) = .empty;
    defer delta.deinit(gpa);
    for ([_]u16{ 2, 1, 1, 1 }) |value| try delta.appendSlice(gpa, &std.mem.toBytes(value));
    try delta.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
    const vector: u32 = (0x3FC) | (0 << 10);
    try delta.appendSlice(gpa, &std.mem.toBytes(vector));
    try delta.appendSlice(gpa, &@as([16]u8, @splat(3)));
    try delta.appendSlice(gpa, &[_]u8{ 10, 11, 12, 13 });
    try delta.appendSlice(gpa, &std.mem.toBytes(@as(u32, 0xE4E4E4E4)));
    try delta.appendSlice(gpa, &[_]u8{ 0b0000_0010, 0, 0, 0 });
    const delta_chunk = try testing.chunk(gpa, "fLED", delta.items);
    defer gpa.free(delta_chunk);

    var film: Film = .init(gpa);
    defer film.deinit();
    var chunks: Chunks = .{ .bytes = key_chunk };
    try std.testing.expect(try film.decode(chunks.next().?));
    try std.testing.expectEqual(8, film.width);
    try std.testing.expectEqual(4, film.height);
    try std.testing.expectEqualSlices(u8, &pixels, film.frame());
    try std.testing.expectEqual(4, film.transparent.?);
    try std.testing.expectEqual(255, film.palette[3]);

    chunks = .{ .bytes = delta_chunk };
    try std.testing.expect(try film.decode(chunks.next().?));
    const expected: [32]u8 = @bitCast(@as([4][8]u8, @splat(.{ 13, 12, 11, 10, 1, 1, 1, 1 })));
    try std.testing.expectEqualSlices(u8, &expected, film.frame());
    // The end gives no frame; a delta before any key frame is bad.
    const end = try testing.chunk(gpa, "fDNE", "");
    defer gpa.free(end);
    chunks = .{ .bytes = end };
    try std.testing.expect(!try film.decode(chunks.next().?));
    var fresh: Film = .init(gpa);
    defer fresh.deinit();
    unscramble(delta_chunk);
    chunks = .{ .bytes = delta_chunk };
    try std.testing.expectError(error.BadChunk, fresh.decode(chunks.next().?));
}

test "the earlier tools' orders" {
    const gpa = std.testing.allocator;
    // A key frame written width first and first entry first decodes as the game's would.
    var palette: Palette = @splat(0);
    var pixels: [32]u8 = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = @intCast(i);
    const released = try testing.keyPayload(gpa, 8, 4, &palette, &pixels);
    defer gpa.free(released);
    const early = try gpa.dupe(u8, released);
    defer gpa.free(early);
    std.mem.writeInt(u16, early[0..2], 8, .little);
    std.mem.writeInt(u16, early[2..4], 4, .little);
    std.mem.writeInt(u16, early[4..6], 0, .little);
    std.mem.writeInt(u16, early[6..8], 256, .little);
    const early_chunk = try testing.chunk(gpa, "fYEK", early);
    defer gpa.free(early_chunk);
    var film: Film = .init(gpa);
    defer film.deinit();
    var chunks: Chunks = .{ .bytes = early_chunk };
    try std.testing.expect(try film.decode(chunks.next().?));
    try std.testing.expectEqual(8, film.width);
    try std.testing.expectEqualSlices(u8, &pixels, film.frame());

    // A delta's order is told from its size: one whole block and no vectors or patterns, at two
    // bits an entry, the counts as each order has them.
    const orders = [_]struct { Order, [4]u16 }{
        .{ .bits_first, .{ 2, 1, 0, 0 } },
        .{ .vectors_first, .{ 0, 1, 0, 2 } },
        .{ .patterns_first, .{ 0, 1, 2, 0 } },
    };
    for (orders) |case| {
        const order, const fields = case;
        var delta: std.ArrayList(u8) = .empty;
        defer delta.deinit(gpa);
        for (fields) |value| try delta.appendSlice(gpa, &std.mem.toBytes(value));
        try delta.appendSlice(gpa, &[_]u8{ 0, 0, 0, 0 });
        try delta.appendSlice(gpa, &@as([16]u8, @splat(7)));
        try delta.appendSlice(gpa, &[_]u8{ 0b0000_0000, 0, 0, 0 });
        const header: DeltaHeader = .{ .chunk = .{ .id = "fLED".*, .size = 0 }, .bits = fields[0], .whole = fields[1], .vectors = fields[2], .patterns = fields[3], ._unknown_10 = 0 };
        try std.testing.expectEqual(order, header.order(delta.items.len + @sizeOf(Header), 2).?);
        const chunk = try testing.chunk(gpa, "fLED", delta.items);
        defer gpa.free(chunk);
        chunks = .{ .bytes = chunk };
        try std.testing.expect(try film.decode(chunks.next().?));
        try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(7)), film.frame());
    }
    // Counts that lay out no chunk of the size are bad.
    const wrong: DeltaHeader = .{ .chunk = .{ .id = "fLED".*, .size = 0 }, .bits = 2, .whole = 5, .vectors = 0, .patterns = 0, ._unknown_10 = 0 };
    try std.testing.expectEqual(null, wrong.order(40, 2));
}

test field {
    const bytes = [_]u8{ 0b1010_0101, 0b1111_0000, 0xFF };
    try std.testing.expectEqual(0b101, field(&bytes, 0, 3));
    try std.testing.expectEqual(0b0000_1010, field(&bytes, 4, 8));
    try std.testing.expectEqual(0b1111, field(&bytes, 12, 4));
    // Past the end, zeros.
    try std.testing.expectEqual(0xFF, field(&bytes, 16, 12));
    try std.testing.expectEqual(0, field(&bytes, 40, 8));
}

test signed {
    try std.testing.expectEqual(5, signed(5));
    try std.testing.expectEqual(-1, signed(0x3FF));
    try std.testing.expectEqual(-512, signed(0x200));
    try std.testing.expectEqual(511, signed(0x1FF));
}

test drawPatterns {
    var blocks: [16]u8 = undefined;
    drawPatterns(&(.{ 7, 8, 9, 10 } ++ std.mem.toBytes(@as(u32, 0x0000_00E4))), &blocks);
    // The lowest bits are the last pixel's: the last four pixels 7, 8, 9, 10 from the end.
    try std.testing.expectEqualSlices(u8, &(@as([12]u8, @splat(7)) ++ [_]u8{ 10, 9, 8, 7 }), &blocks);
}
