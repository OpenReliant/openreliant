//! Writes face films (`.fm8`, [docs/formats/fm8.md](../../../docs/formats/fm8.md)) from frames of
//! RGBA pixels, for mods that give a pilot a face of their own. The game's decoder
//! (`engine/game/talkie.zig`) sets the format; this is the other way.
//!
//! The frames share one palette of 256 colours: their own colours where they have no more, else
//! colours a median cut picks. A pixel less than half opaque takes the colour the game draws
//! see-through. The first frame is a key frame, its pixels compressed with RefPack; each frame
//! after it is a delta frame, every 4 by 4 block of it moved from the frame before where an equal
//! block lies within `search_reach` pixels, else drawn in four colours where it has no more, else
//! given whole. The map's entries take as few bits as their count allows. Past the palette, a film
//! is the frames exactly: the decoder gives back the frames as they were quantized.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const talkie = openreliant.engine.game.talkie;
const refpack = openreliant.refpack;

/// The colour the game draws see-through (`talkie.transparentIn`): red 255, green 0, blue 216.
pub const see_through: [3]u8 = .{ 0xFF, 0x00, 0xD8 };

/// The alpha below which a pixel is see-through.
const opaque_from = 128;

/// How far a block's match is looked for in the frame before, in pixels either way.
const search_reach = 8;

/// The colours a palette holds.
const palette_colours = 256;

pub const Error = error{
    /// No frames, frames of different sizes, or a size that isn't a whole number of blocks.
    BadFrames,
} || refpack.CompressError;

/// A film of `frames`, each `width` by `height` pixels of red, green, blue and alpha a byte each,
/// scrambled and ready to write. The caller owns the bytes.
pub fn encode(gpa: Allocator, width: u16, height: u16, frames: []const []const u8) Error![]u8 {
    if (frames.len == 0 or width == 0 or height == 0 or width % talkie.block != 0 or height % talkie.block != 0) return error.BadFrames;
    const pixels = @as(usize, width) * height;
    for (frames) |frame| if (frame.len != pixels * 4) return error.BadFrames;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const palette = try paletteOf(arena, frames);
    var film: std.ArrayList(u8) = .empty;
    errdefer film.deinit(gpa);
    var previous: []const u8 = &.{};
    for (frames, 0..) |frame, at| {
        const indices = try quantize(arena, palette, frame);
        const chunk = if (at == 0) try keyChunk(arena, width, height, palette, indices) else try deltaChunk(arena, width, height, previous, indices);
        talkie.unscramble(chunk);
        try film.appendSlice(gpa, chunk);
        previous = indices;
    }
    const end: talkie.Header = .{ .id = "fDNE".*, .size = @sizeOf(talkie.Header) };
    try film.appendSlice(gpa, std.mem.asBytes(&end));
    return film.toOwnedSlice(gpa);
}

/// A pixel's colour as the film holds it: its own, or the see-through colour.
fn colourAt(frame: []const u8, pixel: usize) [3]u8 {
    const rgba = frame[pixel * 4 ..][0..4];
    return if (rgba[3] < opaque_from) see_through else rgba[0..3].*;
}

fn packed24(colour: [3]u8) u24 {
    return @as(u24, colour[0]) << 16 | @as(u24, colour[1]) << 8 | colour[2];
}

/// The palette of the frames: their own colours in order where they have no more than 256, else
/// those of a median cut, the see-through colour kept as it is. Unused entries are black.
fn paletteOf(arena: Allocator, frames: []const []const u8) Allocator.Error!talkie.Palette {
    var counts: std.AutoArrayHashMapUnmanaged(u24, u32) = .empty;
    for (frames) |frame| {
        for (0..frame.len / 4) |pixel| {
            const entry = try counts.getOrPut(arena, packed24(colourAt(frame, pixel)));
            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
        }
    }
    var palette: talkie.Palette = @splat(0);
    const keys = counts.keys();
    if (keys.len <= palette_colours) {
        std.mem.sortUnstable(u24, keys, {}, std.sort.asc(u24));
        for (keys, 0..) |key, at| palette[at * 3 ..][0..3].* = unpacked(key);
        return palette;
    }
    // A median cut over the colours but the see-through one, which keeps an entry of its own.
    var colours: std.ArrayList(Weighted) = .empty;
    var reserve: usize = 0;
    var it = counts.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* == packed24(see_through)) {
            reserve = 1;
            continue;
        }
        try colours.append(arena, .{ .colour = unpacked(entry.key_ptr.*), .count = entry.value_ptr.* });
    }
    const chosen = try medianCut(arena, colours.items, palette_colours - reserve);
    for (chosen, 0..) |colour, at| palette[at * 3 ..][0..3].* = colour;
    if (reserve == 1) palette[chosen.len * 3 ..][0..3].* = see_through;
    return palette;
}

fn unpacked(key: u24) [3]u8 {
    return .{ @truncate(key >> 16), @truncate(key >> 8), @truncate(key) };
}

/// A colour and how many pixels have it.
const Weighted = struct { colour: [3]u8, count: u32 };

/// Up to `most` colours standing for `colours`: the box of colours with the widest channel split
/// at its median pixel, again and again, each box then its pixels' mean colour.
fn medianCut(arena: Allocator, colours: []Weighted, most: usize) Allocator.Error![]const [3]u8 {
    var boxes: std.ArrayList([]Weighted) = .empty;
    try boxes.append(arena, colours);
    while (boxes.items.len < most) {
        var widest: ?usize = null;
        var widest_range: u8 = 0;
        var widest_channel: usize = 0;
        for (boxes.items, 0..) |box, at| {
            if (box.len < 2) continue;
            for (0..3) |channel| {
                var low: u8 = 255;
                var high: u8 = 0;
                for (box) |each| {
                    low = @min(low, each.colour[channel]);
                    high = @max(high, each.colour[channel]);
                }
                if (widest == null or high - low > widest_range) {
                    widest = at;
                    widest_range = high - low;
                    widest_channel = channel;
                }
            }
        }
        const split = widest orelse break;
        const box = boxes.items[split];
        const Sort = struct {
            fn less(channel: usize, a: Weighted, b: Weighted) bool {
                return a.colour[channel] < b.colour[channel];
            }
        };
        std.mem.sortUnstable(Weighted, box, widest_channel, Sort.less);
        var total: u64 = 0;
        for (box) |each| total += each.count;
        var below: u64 = 0;
        var cut: usize = 1;
        for (box[0 .. box.len - 1], 1..) |each, at| {
            below += each.count;
            cut = at;
            if (below * 2 >= total) break;
        }
        boxes.items[split] = box[0..cut];
        try boxes.append(arena, box[cut..]);
    }
    const chosen = try arena.alloc([3]u8, boxes.items.len);
    for (boxes.items, chosen) |box, *colour| {
        var sums: [3]u64 = @splat(0);
        var total: u64 = 0;
        for (box) |each| {
            for (0..3) |channel| sums[channel] += @as(u64, each.colour[channel]) * each.count;
            total += each.count;
        }
        for (0..3) |channel| colour[channel] = @intCast((sums[channel] + total / 2) / total);
    }
    return chosen;
}

/// The frame's pixels as entries of `palette`: each the nearest colour, the see-through colour
/// only for itself.
fn quantize(arena: Allocator, palette: talkie.Palette, frame: []const u8) Allocator.Error![]u8 {
    var found: std.AutoHashMapUnmanaged(u24, u8) = .empty;
    const indices = try arena.alloc(u8, frame.len / 4);
    for (indices, 0..) |*index, pixel| {
        const colour = colourAt(frame, pixel);
        const entry = try found.getOrPut(arena, packed24(colour));
        if (!entry.found_existing) entry.value_ptr.* = nearest(palette, colour);
        index.* = entry.value_ptr.*;
    }
    return indices;
}

fn nearest(palette: talkie.Palette, colour: [3]u8) u8 {
    var best: u8 = 0;
    var best_distance: u32 = std.math.maxInt(u32);
    for (0..palette_colours) |at| {
        const entry = palette[at * 3 ..][0..3];
        const see = std.mem.eql(u8, entry, &see_through);
        if (see != std.mem.eql(u8, &colour, &see_through)) continue;
        var distance: u32 = 0;
        for (0..3) |channel| {
            const d = @as(i32, entry[channel]) - colour[channel];
            distance += @intCast(d * d);
        }
        if (distance < best_distance) {
            best = @intCast(at);
            best_distance = distance;
        }
    }
    return best;
}

/// A key frame: the size, the whole palette, and the pixels compressed with RefPack.
fn keyChunk(arena: Allocator, width: u16, height: u16, palette: talkie.Palette, indices: []const u8) Error![]u8 {
    var compressor: refpack.Compressor = try .init(arena);
    const pixels = try compressor.compressApart(arena, indices);
    const size = @sizeOf(talkie.KeyHeader) + palette.len + pixels.len;
    const chunk = try arena.alloc(u8, size);
    const header: talkie.KeyHeader = .{
        .chunk = .{ .id = "fYEK".*, .size = @intCast(size) },
        .height = height,
        .width = width,
        .entries = palette_colours,
        .first = 0,
        ._unknown_10 = 0,
    };
    @memcpy(chunk[0..@sizeOf(talkie.KeyHeader)], std.mem.asBytes(&header));
    @memcpy(chunk[@sizeOf(talkie.KeyHeader)..][0..palette.len], &palette);
    @memcpy(chunk[@sizeOf(talkie.KeyHeader) + palette.len ..], pixels);
    return chunk;
}

/// How a delta frame gives one block.
const Given = union(enum) {
    vector: u16,
    whole: u16,
    pattern: u16,
};

/// A delta frame making `next` from `previous`, both `width` by `height` entries.
fn deltaChunk(arena: Allocator, width: u16, height: u16, previous: []const u8, next: []const u8) Error![]u8 {
    const across = width / talkie.block;
    const down = height / talkie.block;
    var vectors: std.ArrayList([2]i16) = .empty;
    var whole: std.ArrayList([talkie.block_pixels]u8) = .empty;
    var patterns: std.ArrayList([talkie.pattern_size]u8) = .empty;
    const map = try arena.alloc(Given, @as(usize, across) * down);
    for (map, 0..) |*given, at| {
        const x: i32 = @intCast(at % across * talkie.block);
        const y: i32 = @intCast(at / across * talkie.block);
        const own = blockAt(next, width, x, y);
        if (try matchIn(arena, previous, width, height, x, y, own, &vectors)) |vector| {
            given.* = .{ .vector = vector };
        } else if (patternOf(own)) |pattern| {
            given.* = .{ .pattern = @intCast(patterns.items.len) };
            try patterns.append(arena, pattern);
        } else {
            given.* = .{ .whole = @intCast(whole.items.len) };
            try whole.append(arena, own);
        }
    }
    const vector_count: u32 = @intCast(vectors.items.len);
    const whole_count: u32 = @intCast(whole.items.len);
    const entries = vector_count + whole_count + @as(u32, @intCast(patterns.items.len));
    const bits: u16 = @max(1, std.math.log2_int_ceil(u32, @max(entries, 1)));

    const counts: talkie.DeltaHeader.Counts = .{ .bits = bits, .whole = @intCast(whole_count), .vectors = @intCast(vector_count), .patterns = @intCast(patterns.items.len) };
    const size = counts.size(map.len);
    const chunk = try arena.alloc(u8, size);
    @memset(chunk, 0);
    const header: talkie.DeltaHeader = .{
        .chunk = .{ .id = "fLED".*, .size = @intCast(size) },
        .bits = counts.bits,
        .whole = counts.whole,
        .vectors = counts.vectors,
        .patterns = counts.patterns,
        ._unknown_10 = 0,
    };
    @memcpy(chunk[0..@sizeOf(talkie.DeltaHeader)], std.mem.asBytes(&header));
    var at: usize = @sizeOf(talkie.DeltaHeader);
    const vector_bytes = wordBytes(vectors.items.len * 2 * talkie.vector_bits);
    for (vectors.items, 0..) |vector, i| {
        putField(chunk[at..][0..vector_bytes], 2 * i * talkie.vector_bits, talkie.vector_bits, tenBits(vector[0]));
        putField(chunk[at..][0..vector_bytes], (2 * i + 1) * talkie.vector_bits, talkie.vector_bits, tenBits(vector[1]));
    }
    at += vector_bytes;
    for (whole.items) |pixels| {
        @memcpy(chunk[at..][0..talkie.block_pixels], &pixels);
        at += talkie.block_pixels;
    }
    for (patterns.items) |pattern| {
        @memcpy(chunk[at..][0..talkie.pattern_size], &pattern);
        at += talkie.pattern_size;
    }
    const map_bytes = wordBytes(map.len * bits);
    for (map, 0..) |given, i| {
        const entry: u32 = switch (given) {
            .vector => |n| n,
            .whole => |n| vector_count + n,
            .pattern => |n| vector_count + whole_count + n,
        };
        putField(chunk[at..][0..map_bytes], i * bits, @intCast(bits), entry);
    }
    return chunk;
}

/// The 4 by 4 block of `frame` from `x`, `y`, row by row.
fn blockAt(frame: []const u8, width: u16, x: i32, y: i32) [talkie.block_pixels]u8 {
    var pixels: [talkie.block_pixels]u8 = undefined;
    for (0..talkie.block) |row| {
        const from: usize = @intCast((y + @as(i32, @intCast(row))) * width + x);
        @memcpy(pixels[row * talkie.block ..][0..talkie.block], frame[from..][0..talkie.block]);
    }
    return pixels;
}

/// The vector, among `vectors` or added to them, that moves a block of `previous` equal to `own`
/// to `x`, `y`: none first, then the nearest within `search_reach`; null where there is none.
fn matchIn(arena: Allocator, previous: []const u8, width: u16, height: u16, x: i32, y: i32, own: [talkie.block_pixels]u8, vectors: *std.ArrayList([2]i16)) Allocator.Error!?u16 {
    var reach: i32 = 0;
    while (reach <= search_reach) : (reach += 1) {
        var dy: i32 = -reach;
        while (dy <= reach) : (dy += 1) {
            var dx: i32 = -reach;
            while (dx <= reach) : (dx += 1) {
                if (@max(@abs(dx), @abs(dy)) != reach) continue;
                const from_x = x + dx;
                const from_y = y + dy;
                if (from_x < 0 or from_y < 0 or from_x + talkie.block > width or from_y + talkie.block > height) continue;
                if (!std.mem.eql(u8, &blockAt(previous, width, from_x, from_y), &own)) continue;
                const vector: [2]i16 = .{ @intCast(dx), @intCast(dy) };
                for (vectors.items, 0..) |held, at| if (std.mem.eql(i16, &held, &vector)) return @intCast(at);
                try vectors.append(arena, vector);
                return @intCast(vectors.items.len - 1);
            }
        }
    }
    return null;
}

/// The block drawn in four colours, where it has no more: the colours, the last repeated, then
/// two bits for each pixel, the highest the first pixel's (`talkie.drawPatterns`).
fn patternOf(own: [talkie.block_pixels]u8) ?[talkie.pattern_size]u8 {
    var colours: [4]u8 = undefined;
    var count: usize = 0;
    var map: u32 = 0;
    for (own, 0..) |pixel, k| {
        const index = std.mem.indexOfScalar(u8, colours[0..count], pixel) orelse new: {
            if (count == colours.len) return null;
            colours[count] = pixel;
            count += 1;
            break :new count - 1;
        };
        map |= @as(u32, @intCast(index)) << @intCast(2 * (talkie.block_pixels - 1 - k));
    }
    for (colours[count..]) |*unused| unused.* = colours[0];
    var pattern: [talkie.pattern_size]u8 = undefined;
    @memcpy(pattern[0..4], &colours);
    std.mem.writeInt(u32, pattern[4..8], map, .little);
    return pattern;
}

/// A vector's part as `talkie.vector_bits` bits, its top bit the sign.
fn tenBits(value: i16) u32 {
    return @as(u32, @bitCast(@as(i32, value))) & ((1 << talkie.vector_bits) - 1);
}

/// Writes the `bits` low bits of `value` into `bytes` from bit `at`, least significant first, as
/// `talkie.field` reads them.
fn putField(bytes: []u8, at: usize, bits: u5, value: u32) void {
    for (0..bits) |bit| {
        if (value >> @intCast(bit) & 1 == 0) continue;
        const position = at + bit;
        bytes[position / 8] |= @as(u8, 1) << @intCast(position % 8);
    }
}

/// The bytes `bits` bits take, rounded up to whole words, as `talkie` reads the vectors and the map.
fn wordBytes(bits: usize) usize {
    return ((bits + 31) & ~@as(usize, 31)) / 8;
}

/// Decodes `film` with the game's decoder: each frame's palette entries into `frames`, and the
/// palette.
fn decodeAll(gpa: Allocator, film: []u8, frames: *std.ArrayList([]u8)) !talkie.Palette {
    var decoder: talkie.Film = .init(gpa);
    defer decoder.deinit();
    var chunks: talkie.Chunks = .{ .bytes = film };
    while (chunks.next()) |chunk| {
        if (!try decoder.decode(chunk)) continue;
        const pixels = try gpa.dupe(u8, decoder.frame());
        errdefer gpa.free(pixels);
        try frames.append(gpa, pixels);
    }
    return decoder.palette;
}

test encode {
    const gpa = std.testing.allocator;
    const width = 16;
    const height = 8;
    // Three frames: a pattern of a few colours with a see-through corner, the same moved two
    // pixels right with a new block of many colours, and noise in a block of its own.
    var frames: [3][width * height * 4]u8 = undefined;
    for (&frames[0], 0..) |*byte, at| {
        const pixel = at / 4;
        byte.* = switch (at % 4) {
            0 => @intCast(pixel % width * 16),
            1 => @intCast(pixel / width * 30),
            2 => 40,
            else => if (pixel % width < 2 and pixel / width < 2) 0 else 255,
        };
    }
    for (0..height) |y| {
        for (0..width) |x| {
            const from = if (x >= 2) (y * width + x - 2) * 4 else (y * width + x) * 4;
            @memcpy(frames[1][(y * width + x) * 4 ..][0..4], frames[0][from..][0..4]);
        }
    }
    frames[2] = frames[1];
    for (0..4) |y| for (8..12) |x| {
        frames[1][(y * width + x) * 4 ..][0..4].* = .{ @intCast(x * 7 + y * 3), @intCast(y * 50), @intCast(x * 9), 255 };
        frames[2][(y * width + x) * 4 ..][0..4].* = .{ @intCast(x * 13), @intCast(y * 61), @intCast(x * y), 255 };
    };
    const film = try encode(gpa, width, height, &.{ &frames[0], &frames[1], &frames[2] });
    defer gpa.free(film);

    // The game's decoder gives the frames back exactly: each pixel its colour, or the see-through
    // colour where it was transparent.
    var decoded: std.ArrayList([]u8) = .empty;
    defer {
        for (decoded.items) |frame| gpa.free(frame);
        decoded.deinit(gpa);
    }
    const palette = try decodeAll(gpa, film, &decoded);
    try std.testing.expectEqual(3, decoded.items.len);
    for (frames, decoded.items) |frame, indices| {
        for (indices, 0..) |index, pixel| {
            const colour = palette[@as(usize, index) * 3 ..][0..3];
            try std.testing.expectEqualSlices(u8, &colourAt(&frame, pixel), colour);
        }
    }
}

test "a film of many colours keeps the see-through colour exact" {
    const gpa = std.testing.allocator;
    const width = 32;
    const height = 32;
    var frame: [width * height * 4]u8 = undefined;
    for (0..width * height) |pixel| {
        frame[pixel * 4 ..][0..4].* = .{ @intCast(pixel % 256), @intCast(pixel / 4 % 256), @intCast(pixel * 7 % 256), if (pixel == 5) 0 else 255 };
    }
    const film = try encode(gpa, width, height, &.{&frame});
    defer gpa.free(film);
    var decoded: std.ArrayList([]u8) = .empty;
    defer {
        for (decoded.items) |held| gpa.free(held);
        decoded.deinit(gpa);
    }
    const palette = try decodeAll(gpa, film, &decoded);
    try std.testing.expectEqualSlices(u8, &see_through, palette[@as(usize, decoded.items[0][5]) * 3 ..][0..3]);
    // Every other pixel is near its colour.
    for (decoded.items[0], 0..) |index, pixel| {
        if (pixel == 5) continue;
        const colour = palette[@as(usize, index) * 3 ..][0..3];
        for (0..3) |channel| try std.testing.expect(@abs(@as(i32, colour[channel]) - frame[pixel * 4 + channel]) < 48);
    }
}

test "frames that aren't whole blocks are refused" {
    const frame: [6 * 4 * 4]u8 = @splat(0);
    try std.testing.expectError(error.BadFrames, encode(std.testing.allocator, 6, 4, &.{&frame}));
    try std.testing.expectError(error.BadFrames, encode(std.testing.allocator, 4, 4, &.{}));
}
