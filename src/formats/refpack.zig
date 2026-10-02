//! RefPack, the Electronic Arts LZ77 variant that compresses most members of a `.hog` archive.
//!
//! Also called QFS, and named FB10 after the two bytes its header starts with. A stream is a
//! sequence of commands, each of which copies a short run of literal bytes from the input and then
//! optionally repeats a run that already appeared in the output. Four command encodings cover
//! progressively longer matches, and a fifth ends the stream.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The second header byte. The first carries flags, so the pair is the format's signature.
pub const signature: u8 = 0xFB;

/// The first two bytes of the one form of stream the game expands, read big-endian: flags with
/// only `magic` set, then the signature. `hog_read_file` (`0x004C7F60`), `hog_read_file_as_named`
/// (`0x004C8110`) and `hog_file_size` (`0x004C81F0`) compare a member's first two bytes with it,
/// and take any other member as it is stored.
pub const game_magic: u16 = 0x10FB;

/// The flags byte and the signature.
const signature_len = 2;

/// The shortest header: 3-byte sizes, and no compressed size.
pub const min_header_len = signature_len + 3;

/// The longest header: 4-byte sizes, and both of them.
pub const max_header_len = signature_len + 2 * 4;

pub const Header = struct {
    flags: Flags,
    /// Present only when `flags.compressed_size_present`.
    compressed_size: ?u32,
    decompressed_size: u32,
    /// Bytes the header occupies.
    len: usize,

    pub const Flags = packed struct(u8) {
        /// A compressed size comes before the expanded one.
        compressed_size_present: bool,
        _unused: u3,
        /// Set on every stream seen in this game; part of the signature in practice.
        magic: u1,
        _unused2: u2,
        /// Sizes are 4 bytes rather than 3.
        wide_sizes: bool,

        /// The bytes each size takes.
        pub fn sizeWidth(flags: Flags) usize {
            return if (flags.wide_sizes) 4 else 3;
        }
    };

    pub fn sizeWidth(header: Header) usize {
        return header.flags.sizeWidth();
    }
};

pub const Error = error{
    /// The stream does not start with a RefPack header.
    BadSignature,
    /// A command runs past the end of the input.
    UnexpectedEnd,
    /// A back-reference points before the start of the output.
    BadReference,
    /// The commands produced a different amount of data than the header promised.
    SizeMismatch,
};

/// Reads the header at the start of `data`.
pub fn readHeader(data: []const u8) Error!Header {
    if (!looksCompressed(data)) return error.BadSignature;
    const flags: Header.Flags = @bitCast(data[0]);

    const width = flags.sizeWidth();
    var pos: usize = signature_len;

    var compressed_size: ?u32 = null;
    if (flags.compressed_size_present) {
        if (data.len < pos + width) return error.UnexpectedEnd;
        compressed_size = std.mem.readVarInt(u32, data[pos..][0..width], .big);
        pos += width;
    }
    if (data.len < pos + width) return error.UnexpectedEnd;
    const decompressed_size = std.mem.readVarInt(u32, data[pos..][0..width], .big);
    pos += width;

    return .{
        .flags = flags,
        .compressed_size = compressed_size,
        .decompressed_size = decompressed_size,
        .len = pos,
    };
}

/// True when `data` begins with a RefPack header, whatever its flags.
pub fn looksCompressed(data: []const u8) bool {
    return data.len >= signature_len and data[1] == signature;
}

/// True when `data` begins as the one form of stream the game expands (`game_magic`).
pub fn gameExpands(data: []const u8) bool {
    return data.len >= signature_len and std.mem.readInt(u16, data[0..signature_len], .big) == game_magic;
}

/// A command's first byte says what it is: a short match below `medium_code`, a medium one below
/// `long_code`, a long one below `run_code`, a run of literals below `end_code`, and from there the
/// end of the stream.
const medium_code: u8 = 0x80;
const long_code: u8 = 0xC0;
const run_code: u8 = 0xE0;
const end_code: u8 = 0xFC;

/// A run of literals counts in fours, from 4 at `run_code` to `max_run` below `end_code`.
const run_unit: usize = 4;
const max_run: usize = (end_code - run_code) * run_unit;

/// The most literals a match or the end carries in its own low two bits.
const max_carried: usize = 3;

/// The three forms of a command that repeats a match, from the smallest to the largest.
pub const Form = enum {
    short,
    medium,
    long,

    /// The layout of the command's bytes.
    fn Bits(comptime form: Form) type {
        return switch (form) {
            .short => Short,
            .medium => Medium,
            .long => Long,
        };
    }

    /// The bytes the command takes.
    pub fn size(form: Form) usize {
        return switch (form) {
            inline else => |known| @bitSizeOf(known.Bits()) / 8,
        };
    }

    /// The shortest match it holds, which its length field counts from.
    pub fn shortest(form: Form) usize {
        return switch (form) {
            .short => 3,
            .medium => 4,
            .long => 5,
        };
    }

    /// The longest match it holds.
    pub fn longest(form: Form) usize {
        return switch (form) {
            .short => 10,
            .medium => 67,
            .long => 1028,
        };
    }

    /// The furthest back it reaches. The long form's field holds 131072, but the furthest in the
    /// game's own streams is 131071, and the encoder keeps to that.
    pub fn reach(form: Form) usize {
        return switch (form) {
            .short => 1024,
            .medium => 16384,
            .long => 131071,
        };
    }

    /// Whether it holds a match of `len` bytes from `distance` back.
    fn holds(form: Form, distance: usize, len: usize) bool {
        return distance <= form.reach() and len >= form.shortest() and len <= form.longest();
    }

    /// Decodes the command of this form at the start of `input`, returning it and its length.
    fn decode(comptime form: Form, input: []const u8) Error!Command.Decoded {
        if (input.len < form.size()) return error.UnexpectedEnd;
        const bits: form.Bits() = @bitCast(std.mem.readInt(form.Word(), input[0..comptime form.size()], .big));
        return .{ .{
            .literals = bits.carried,
            .match_len = bits.matchLen(),
            .match_distance = bits.matchDistance(),
            .last = false,
        }, form.size() };
    }

    /// The command's bytes for `match`, carrying `carried` literals after it.
    fn encode(comptime form: Form, match: Match, carried: u2) [form.size()]u8 {
        const bits: form.Bits() = .init(match.distance, match.len, carried);
        var bytes: [form.size()]u8 = undefined;
        std.mem.writeInt(form.Word(), &bytes, @bitCast(bits), .big);
        return bytes;
    }

    /// The command's bytes as one integer, which they are read as, big-endian.
    fn Word(comptime form: Form) type {
        return std.meta.Int(.unsigned, @bitSizeOf(form.Bits()));
    }
};

/// A short match's two bytes, as one big-endian word: the distance less one in 10 bits, split by
/// the length less `shortest` and the literals it carries.
const Short = packed struct(u16) {
    back_low: u8,
    carried: u2,
    extra: u3,
    back_high: u2,
    code: u1 = 0,

    const form: Form = .short;

    fn init(distance: usize, len: usize, carried: u2) Short {
        const back = distance - 1;
        return .{
            .back_low = @truncate(back),
            .back_high = @intCast(back >> 8),
            .extra = @intCast(len - form.shortest()),
            .carried = carried,
        };
    }

    fn matchDistance(bits: Short) usize {
        return (@as(usize, bits.back_high) << 8 | bits.back_low) + 1;
    }

    fn matchLen(bits: Short) usize {
        return @as(usize, bits.extra) + form.shortest();
    }
};

/// A medium match's three bytes, as one big-endian word: the distance less one in 14 bits, the
/// literals it carries, and the length less `shortest`.
const Medium = packed struct(u24) {
    back: u14,
    carried: u2,
    extra: u6,
    code: u2 = medium_code >> 6,

    const form: Form = .medium;

    fn init(distance: usize, len: usize, carried: u2) Medium {
        return .{
            .back = @intCast(distance - 1),
            .extra = @intCast(len - form.shortest()),
            .carried = carried,
        };
    }

    fn matchDistance(bits: Medium) usize {
        return @as(usize, bits.back) + 1;
    }

    fn matchLen(bits: Medium) usize {
        return @as(usize, bits.extra) + form.shortest();
    }
};

/// A long match's four bytes, as one big-endian word: the length less `shortest` in 10 bits and the
/// distance less one in 17, each split by the other, and the literals it carries.
const Long = packed struct(u32) {
    extra_low: u8,
    back_low: u16,
    carried: u2,
    extra_high: u2,
    back_high: u1,
    code: u3 = long_code >> 5,

    const form: Form = .long;

    fn init(distance: usize, len: usize, carried: u2) Long {
        const back = distance - 1;
        const extra = len - form.shortest();
        return .{
            .extra_low = @truncate(extra),
            .extra_high = @intCast(extra >> 8),
            .back_low = @truncate(back),
            .back_high = @intCast(back >> 16),
            .carried = carried,
        };
    }

    fn matchDistance(bits: Long) usize {
        return (@as(usize, bits.back_high) << 16 | bits.back_low) + 1;
    }

    fn matchLen(bits: Long) usize {
        return (@as(usize, bits.extra_high) << 8 | bits.extra_low) + form.shortest();
    }
};

comptime {
    const assert = std.debug.assert;
    // Each form's code sets the bits of the first byte that tell it from the others, and its fields
    // hold its furthest match and its longest.
    for (std.enums.values(Form)) |form| {
        assert(@bitSizeOf(form.Bits()) == 8 * form.size());
        const bits: form.Bits() = .init(form.reach(), form.longest(), max_carried);
        assert(bits.matchDistance() == form.reach() and bits.matchLen() == form.longest());
    }
    assert(@as(u16, @bitCast(Short.init(1, 3, 0))) >> 8 < medium_code);
    assert(@as(u24, @bitCast(Medium.init(1, 4, 0))) >> 16 == medium_code);
    assert(@as(u32, @bitCast(Long.init(1, 5, 0))) >> 24 == long_code);
}

/// One decoded command: copy `literals` bytes straight through, then repeat `match_len` bytes
/// from `match_distance` back in the output.
const Command = struct {
    literals: usize,
    match_len: usize,
    match_distance: usize,
    last: bool,

    /// A command and the bytes it takes.
    const Decoded = struct { Command, usize };

    /// Decodes the command at the start of `input`, returning it and its encoded length.
    fn decode(input: []const u8) Error!Decoded {
        if (input.len < 1) return error.UnexpectedEnd;
        const b0 = input[0];

        if (b0 < medium_code) return Form.decode(.short, input);
        if (b0 < long_code) return Form.decode(.medium, input);
        if (b0 < run_code) return Form.decode(.long, input);

        // A run of literals, which no match follows.
        if (b0 < end_code) {
            return .{ .{
                .literals = (@as(usize, b0 - run_code) + 1) * run_unit,
                .match_len = 0,
                .match_distance = 0,
                .last = false,
            }, 1 };
        }

        // The end of the stream, with up to three trailing literals.
        return .{ .{
            .literals = b0 & max_carried,
            .match_len = 0,
            .match_distance = 0,
            .last = true,
        }, 1 };
    }
};

/// Decompresses a complete RefPack stream, header included.
pub fn decompressAlloc(gpa: Allocator, stream: []const u8) (Error || Allocator.Error)![]u8 {
    const header = try readHeader(stream);
    const out = try gpa.alloc(u8, header.decompressed_size);
    errdefer gpa.free(out);
    const written = try decompressInto(out, stream[header.len..]);
    if (written != out.len) return error.SizeMismatch;
    return out;
}

/// Decompresses the command stream in `input` into `out`, returning the number of bytes written:
/// OpenReliant's counterpart of `refpack_expand` (`0x004CC350`), which checks each command against
/// both buffers where the game's expansion checks nothing. `input` starts after the header.
pub fn decompressInto(out: []u8, input: []const u8) Error!usize {
    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (true) {
        const command, const encoded_len = try Command.decode(input[in_pos..]);
        in_pos += encoded_len;

        if (input.len - in_pos < command.literals) return error.UnexpectedEnd;
        if (out.len - out_pos < command.literals) return error.SizeMismatch;
        @memcpy(out[out_pos..][0..command.literals], input[in_pos..][0..command.literals]);
        in_pos += command.literals;
        out_pos += command.literals;

        if (command.last) return out_pos;

        if (command.match_distance > out_pos) return error.BadReference;
        if (out.len - out_pos < command.match_len) return error.SizeMismatch;
        // Runs may overlap their own output, so copy one byte at a time rather than @memcpy.
        var source = out_pos - command.match_distance;
        for (0..command.match_len) |_| {
            out[out_pos] = out[source];
            out_pos += 1;
            source += 1;
        }
    }
}

/// The most a stream can expand to: the game reads the size as 3 bytes (`hog_unpack`,
/// `0x004C8480`), and has no path for the wide sizes.
pub const max_size: usize = std.math.maxInt(u24);

/// The room `hog_unpack` (`0x004C8480`) leaves beyond a member's expanded size: it adds `0x2800`
/// for the block it allocates (`0x004C84E3`) and for where it reads the stream to (`0x004C8508`).
/// It expands from the start of that block, so the output overtakes the input that is left unless
/// the stream keeps within it: see `inPlaceExcess`.
pub const in_place_slack: usize = 0x2800;

/// The bytes a position's hash covers, which a match needs at least: the shortest any form holds.
const hashed_len = Form.short.shortest();

/// How many earlier positions with the same first `hashed_len` bytes the encoder tries for a match.
const chain_depth: usize = 64;

/// The positions' hash table has `1 << hash_bits` entries, and the chains through them a slot for
/// each position of the window, which covers the furthest reach.
const hash_bits = 16;
const window_size: usize = 1 << 17;
const window_mask: usize = window_size - 1;
const no_position = std.math.maxInt(u32);

/// Knuth's multiplicative hashing: a prime close to 2^32 over the golden ratio, which spreads the
/// hashed bytes' value over the table's bits.
const hash_multiplier: u32 = 0x9E3779B1;

comptime {
    std.debug.assert(window_size > Form.long.reach());
}

pub const CompressError = error{
    /// The data is more than `max_size` bytes, which the header cannot hold.
    TooLarge,
    /// The stream would not survive the game's in-place expansion (`inPlaceExcess` is over
    /// `in_place_slack`), and the game does not check: it overwrites the heap. Store the data as it
    /// is.
    NotInPlace,
} || Allocator.Error;

/// Compresses `data` with a `Compressor` of its own. The caller owns the bytes.
pub fn compressAlloc(gpa: Allocator, data: []const u8) CompressError![]u8 {
    var compressor: Compressor = try .init(gpa);
    defer compressor.deinit(gpa);
    return compressor.compress(gpa, data);
}

/// Compresses one payload after another, such as the members of an archive, with the same match
/// finder.
pub const Compressor = struct {
    finder: Finder,

    pub fn init(gpa: Allocator) Allocator.Error!Compressor {
        return .{ .finder = try .init(gpa) };
    }

    pub fn deinit(compressor: *Compressor, gpa: Allocator) void {
        compressor.finder.deinit(gpa);
    }

    /// Compresses `data` into a stream of the one form the game expands (`10 FB`, a 3-byte size),
    /// that the game's own expansion and `decompressAlloc` both give back as `data`. The caller
    /// owns the bytes.
    ///
    /// This is not EA's compressor and does not reproduce its bytes: it is a lazy parse over hash
    /// chains, which takes each match in the smallest form that holds it. Where a stream would not
    /// load, `error.NotInPlace`, or `error.TooLarge`, the data has to be stored as it is; the game
    /// reads a member that does not begin `10 FB` verbatim. Data that itself begins `10 FB` cannot
    /// be stored as it is, since the game would take it for a stream.
    pub fn compress(compressor: *Compressor, gpa: Allocator, data: []const u8) CompressError![]u8 {
        return compressor.compressWithin(gpa, data, in_place_slack);
    }

    fn compressWithin(compressor: *Compressor, gpa: Allocator, data: []const u8, slack: usize) CompressError![]u8 {
        if (data.len > max_size) return error.TooLarge;

        var stream: Stream = .{};
        errdefer stream.deinit(gpa);
        try stream.start(gpa, @intCast(data.len));

        const finder = &compressor.finder;
        finder.reset(data);
        // The literals since the last match wait in `data[pending..pos]`.
        var pending: usize = 0;
        var pos: usize = 0;
        var found = finder.best(0);
        while (pos < data.len) {
            finder.insert(pos);
            if (found) |match| {
                // A match one byte on is taken instead when it saves more, and the byte here waits.
                const next = finder.best(pos + 1);
                if (next == null or next.?.saving() <= match.saving()) {
                    try stream.match(gpa, data, pending, pos, match);
                    for (pos + 1..pos + match.len) |inside| finder.insert(inside);
                    pos += match.len;
                    pending = pos;
                    found = finder.best(pos);
                    continue;
                }
                found = next;
            } else {
                found = finder.best(pos + 1);
            }
            pos += 1;
        }
        try stream.finish(gpa, data, pending);

        if (stream.excess() > @as(i64, @intCast(slack))) return error.NotInPlace;
        return stream.bytes.toOwnedSlice(gpa);
    }
};

/// A match found in what the encoder has already passed.
const Match = struct {
    distance: usize,
    len: usize,
    /// The smallest form that holds it, which the game's own compressor never goes above.
    form: Form,

    /// The match of `len` bytes from `distance` back, in the smallest form that holds it; null
    /// where none does.
    fn of(distance: usize, len: usize) ?Match {
        for (std.enums.values(Form)) |form| {
            if (form.holds(distance, len)) return .{ .distance = distance, .len = len, .form = form };
        }
        return null;
    }

    /// How many bytes it saves over writing what it covers as literals.
    fn saving(match: Match) isize {
        return @as(isize, @intCast(match.len)) - @as(isize, @intCast(match.form.size()));
    }
};

/// Finds matches by chaining the earlier positions that begin with the same `hashed_len` bytes.
const Finder = struct {
    data: []const u8 = &.{},
    /// The newest position of each hash.
    head: []u32,
    /// The position before each one, in the same chain, by its place in the window. A slot is
    /// written as its position goes in, before any chain reaches it, so it needs no clearing.
    prev: []u32,

    fn init(gpa: Allocator) Allocator.Error!Finder {
        const head = try gpa.alloc(u32, 1 << hash_bits);
        errdefer gpa.free(head);
        const prev = try gpa.alloc(u32, window_size);
        return .{ .head = head, .prev = prev };
    }

    fn deinit(finder: Finder, gpa: Allocator) void {
        gpa.free(finder.head);
        gpa.free(finder.prev);
    }

    /// Starts on `data`, forgetting every position of the payload before.
    fn reset(finder: *Finder, data: []const u8) void {
        finder.data = data;
        @memset(finder.head, no_position);
    }

    fn hash(finder: Finder, pos: usize) usize {
        const Hashed = std.meta.Int(.unsigned, 8 * hashed_len);
        const value: u32 = std.mem.readInt(Hashed, finder.data[pos..][0..hashed_len], .little);
        return (value *% hash_multiplier) >> (32 - hash_bits);
    }

    /// Makes the position available to matches from later ones.
    fn insert(finder: *Finder, pos: usize) void {
        if (pos + hashed_len > finder.data.len) return;
        const slot = finder.hash(pos);
        finder.prev[pos & window_mask] = finder.head[slot];
        finder.head[slot] = @intCast(pos);
    }

    /// The match at `pos` that saves the most, the newest among equals.
    fn best(finder: Finder, pos: usize) ?Match {
        if (pos + hashed_len > finder.data.len) return null;
        const data = finder.data;
        const limit = @min(data.len - pos, Form.long.longest());

        var found: ?Match = null;
        var candidate = finder.head[finder.hash(pos)];
        var tries: usize = 0;
        while (candidate != no_position and tries < chain_depth) : (tries += 1) {
            const distance = pos - candidate;
            if (distance > Form.long.reach()) break;

            var len: usize = 0;
            while (len < limit and data[candidate + len] == data[pos + len]) len += 1;
            if (Match.of(distance, len)) |match| {
                if (found == null or match.saving() > found.?.saving()) found = match;
            }
            if (len == limit) break;

            // A slot the window has come round to holds a newer position, which ends the chain.
            const before = finder.prev[candidate & window_mask];
            if (before >= candidate) break;
            candidate = before;
        }
        return found;
    }
};

/// Writes the header of the one form the game expands, for data of `size` bytes: `game_magic`, then
/// the size in 3 bytes, big-endian as `readHeader` reads them.
fn writeHeader(bytes: *[min_header_len]u8, size: u24) void {
    std.mem.writeInt(u16, bytes[0..signature_len], game_magic, .big);
    std.mem.writeInt(u24, bytes[signature_len..], size, .big);
}

/// A stream being written, keeping `inPlaceExcess` as it goes from what each command stands for,
/// so that nothing reads it back.
const Stream = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// The bytes of data the commands so far stand for.
    written: usize = 0,
    /// The least, at the start and after each command, of the stream so far less the data it
    /// stands for. The excess is the whole stream's lead less this.
    least_lead: i64 = 0,

    fn deinit(stream: *Stream, gpa: Allocator) void {
        stream.bytes.deinit(gpa);
    }

    fn start(stream: *Stream, gpa: Allocator, size: u24) Allocator.Error!void {
        var header: [min_header_len]u8 = undefined;
        writeHeader(&header, size);
        try stream.bytes.appendSlice(gpa, &header);
    }

    /// A command and its literals are in.
    fn command(stream: *Stream) void {
        const lead = @as(i64, @intCast(stream.bytes.items.len)) - @as(i64, @intCast(stream.written));
        stream.least_lead = @min(stream.least_lead, lead);
    }

    /// Writes `data[from..to]` as runs of literals, leaving up to `max_carried` for the command
    /// that follows to carry, and returns where those begin.
    fn runs(stream: *Stream, gpa: Allocator, data: []const u8, from: usize, to: usize) Allocator.Error!usize {
        var at = from;
        while (to - at > max_carried) {
            const run = @min(max_run, (to - at) / run_unit * run_unit);
            try stream.bytes.append(gpa, run_code + @as(u8, @intCast(run / run_unit - 1)));
            try stream.bytes.appendSlice(gpa, data[at..][0..run]);
            at += run;
            stream.written += run;
            stream.command();
        }
        return at;
    }

    /// Writes the literals waiting in `data[from..pos]`, then `match` at `pos`, with the last 0 to 3
    /// of the literals carried by its command.
    fn match(stream: *Stream, gpa: Allocator, data: []const u8, from: usize, pos: usize, found: Match) Allocator.Error!void {
        const carried_at = try stream.runs(gpa, data, from, pos);
        const carried: u2 = @intCast(pos - carried_at);
        switch (found.form) {
            inline else => |form| try stream.bytes.appendSlice(gpa, &form.encode(found, carried)),
        }
        try stream.bytes.appendSlice(gpa, data[carried_at..pos]);
        stream.written += carried + found.len;
        stream.command();
    }

    /// Writes the literals from `from` to the end of `data`, then the command that ends the
    /// stream, carrying the last few.
    fn finish(stream: *Stream, gpa: Allocator, data: []const u8, from: usize) Allocator.Error!void {
        const rest = try stream.runs(gpa, data, from, data.len);
        try stream.bytes.append(gpa, end_code | @as(u8, @intCast(data.len - rest)));
        try stream.bytes.appendSlice(gpa, data[rest..]);
        stream.written = data.len;
        stream.command();
    }

    /// `inPlaceExcess` of the finished stream.
    fn excess(stream: Stream) i64 {
        const lead = @as(i64, @intCast(stream.bytes.items.len)) - @as(i64, @intCast(stream.written));
        return lead - stream.least_lead;
    }
};

/// How far the game's in-place expansion of `stream` (`hog_unpack`, `0x004C8480`) comes to the
/// slack it has: the most, over the start of the stream and after each of its commands, by which
/// the input still to read exceeds the output still to write. The stream loads while this is at
/// most `in_place_slack`.
///
/// `hog_unpack` allocates the expanded size and `in_place_slack` more, reads the stream to the end of
/// that, and expands from the start of the same block. The output must not reach input not yet
/// read, and the expansion checks nothing (`0x004CC350`), so a stream over the bound expands into
/// its own commands and smashes the heap. That happens at the start, where the stream is longer than
/// the data by more than the slack, or later, after a run of matches has put the output well ahead
/// and literals then take the input past it. The retail streams are all far inside: the largest
/// value is 486 (`smp3d.fat`).
///
/// `stream` must be of the form the game expands (`gameExpands`), and its commands must give its
/// declared size, each match reaching back no further than the start of the output, as
/// `decompressAlloc` requires.
pub fn inPlaceExcess(stream: []const u8) Error!i64 {
    if (!gameExpands(stream)) return error.BadSignature;
    const header = try readHeader(stream);
    const total: i64 = @intCast(stream.len);
    const size: i64 = header.decompressed_size;

    var read: usize = header.len;
    var written: i64 = 0;
    var worst = total - size;
    while (true) {
        const command, const encoded_len = try Command.decode(stream[read..]);
        read += encoded_len;
        if (stream.len - read < command.literals) return error.UnexpectedEnd;
        read += command.literals;
        written += @intCast(command.literals);
        if (!command.last) {
            if (command.match_distance > written) return error.BadReference;
            written += @intCast(command.match_len);
        }
        worst = @max(worst, (total - @as(i64, @intCast(read))) - (size - written));
        if (command.last) return if (written == size) worst else error.SizeMismatch;
    }
}

/// Whether the game's in-place expansion of `stream` keeps within its slack (`inPlaceExcess`):
/// false for one over it, and for bytes that are no stream of the form the game expands. A stream
/// it passes expands to its declared size (`decompressAlloc`).
pub fn loadsInPlace(stream: []const u8) bool {
    const excess = inPlaceExcess(stream) catch return false;
    return excess <= in_place_slack;
}

/// Streams built by hand, for the tests of code that reads or stores them.
pub const testing = struct {
    /// The largest payload that `literals` writes as a stream the game loads in place: its excess
    /// comes to `in_place_slack` exactly, and a byte more takes it one over.
    pub const largest_in_place: usize = 1_146_211;

    /// `data` written as literals alone, as the encoder writes what it finds no match in: a stream
    /// the game expands, past the in-place bound for more than `largest_in_place` bytes. The caller
    /// owns the bytes.
    pub fn literals(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
        var stream: Stream = .{};
        errdefer stream.deinit(gpa);
        try stream.start(gpa, @intCast(data.len));
        try stream.finish(gpa, data, 0);
        return stream.bytes.toOwnedSlice(gpa);
    }
};

test readHeader {
    const header = try readHeader(&.{ 0x10, 0xFB, 0x08, 0xB5, 0xA8 });
    try std.testing.expectEqual(@as(u32, 0x08B5A8), header.decompressed_size);
    try std.testing.expectEqual(@as(?u32, null), header.compressed_size);
    try std.testing.expectEqual(@as(usize, 5), header.len);
    try std.testing.expect(!header.flags.wide_sizes);

    // With a compressed size, and with wide sizes.
    const with_both = try readHeader(&.{ 0x81, 0xFB, 0, 0, 0x10, 0x00, 0, 0, 0x20, 0x00 });
    try std.testing.expectEqual(@as(?u32, 0x1000), with_both.compressed_size);
    try std.testing.expectEqual(@as(u32, 0x2000), with_both.decompressed_size);
    try std.testing.expectEqual(@as(usize, 10), with_both.len);
    try std.testing.expectEqual(max_header_len, with_both.len);
    try std.testing.expectEqual(min_header_len, header.len);

    try std.testing.expectError(error.BadSignature, readHeader(&.{ 0x10, 0x00, 0, 0, 0 }));
    try std.testing.expectError(error.BadSignature, readHeader(&.{0x10}));
    try std.testing.expectError(error.UnexpectedEnd, readHeader(&.{ 0x81, 0xFB, 0, 0, 0x10, 0x00, 0, 0, 0x20 }));
}

test gameExpands {
    try std.testing.expect(gameExpands(&.{ 0x10, 0xFB, 0x00, 0x00, 0x0C }));
    // Other flags make RefPack all the same, but the game takes such a member as it is stored.
    try std.testing.expect(looksCompressed(&.{ 0x11, 0xFB }) and !gameExpands(&.{ 0x11, 0xFB }));
    try std.testing.expect(!gameExpands(&.{0x10}));
    try std.testing.expect(!gameExpands("RIFF"));
}

test "literal run then end" {
    // 0xE0: four literals. 0xFC: end with no trailing literals.
    var out: [4]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0xE0, 'a', 'b', 'c', 'd', 0xFC });
    try std.testing.expectEqual(@as(usize, 4), written);
    try std.testing.expectEqualStrings("abcd", &out);
}

test "short match repeats earlier output" {
    // 0xE0 -> 4 literals "abcd"; then a short match: b0=0x04 gives 0 literals and length
    // ((0x04 & 0x1C) >> 2) + 3 = 4, b1=3 gives distance 4; then 0xFC ends.
    var out: [8]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0xE0, 'a', 'b', 'c', 'd', 0x04, 0x03, 0xFC });
    try std.testing.expectEqual(@as(usize, 8), written);
    try std.testing.expectEqualStrings("abcdabcd", &out);
}

test "overlapping match extends a run" {
    // A distance of one repeats the previous byte, so the copy reads bytes it is still writing.
    // b0 = 0x01: one literal, match length ((0x01 & 0x1C) >> 2) + 3 = 3, b1 = 0 -> distance 1.
    // 0xFE ends the stream with two trailing literals.
    var out: [6]u8 = undefined;
    const written = try decompressInto(&out, &.{ 0x01, 0x00, 'x', 0xFE, 'y', 'z' });
    try std.testing.expectEqual(@as(usize, 6), written);
    try std.testing.expectEqualStrings("xxxxyz", &out);
}

test "truncated input is rejected" {
    var out: [16]u8 = undefined;
    try std.testing.expectError(error.UnexpectedEnd, decompressInto(&out, &.{0xE0}));
    try std.testing.expectError(error.UnexpectedEnd, decompressInto(&out, &.{0x04}));
    // A match reaching before the start of the output.
    try std.testing.expectError(error.BadReference, decompressInto(&out, &.{ 0x00, 0x00, 0xFC }));
}

test "round-trips a real stream shape" {
    const gpa = std.testing.allocator;
    // "abcdabcdabcd" as header + two commands.
    const stream = [_]u8{ 0x10, 0xFB, 0x00, 0x00, 0x0C, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC };
    const out = try decompressAlloc(gpa, &stream);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("abcdabcdabcd", out);
}

/// Compresses `data` and checks what comes back: what OpenReliant's decoder gives, and what the
/// game's expansion demands of the stream.
fn expectRoundTrip(data: []const u8) !void {
    const gpa = std.testing.allocator;
    const stream = try compressAlloc(gpa, data);
    defer gpa.free(stream);

    try std.testing.expect(gameExpands(stream));
    const header = try readHeader(stream);
    try std.testing.expectEqual(@as(u32, @intCast(data.len)), header.decompressed_size);
    try std.testing.expectEqual(min_header_len, header.len);
    try std.testing.expect(try inPlaceExcess(stream) <= @as(i64, in_place_slack));

    const expanded = try decompressAlloc(gpa, stream);
    defer gpa.free(expanded);
    try std.testing.expectEqualSlices(u8, data, expanded);
}

test compressAlloc {
    const gpa = std.testing.allocator;

    // No data is a header and the terminator.
    const empty = try compressAlloc(gpa, "");
    defer gpa.free(empty);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0xFB, 0x00, 0x00, 0x00, 0xFC }, empty);

    // Data the terminator carries alone, then data a run and the terminator carry.
    try expectRoundTrip("a");
    try expectRoundTrip("abc");
    try expectRoundTrip("abcd");
    try expectRoundTrip("abcdefghi");

    try expectRoundTrip("abcdabcdabcd");
    try expectRoundTrip("The quick brown fox jumps over the lazy dog. " ** 200);

    // One byte over and over: the matches overlap what they are writing, and the longest ones are
    // cut at 1028.
    try expectRoundTrip(&@as([100_000]u8, @splat(0)));
    try expectRoundTrip(&@as([1029]u8, @splat(7)));

    var counting: [5000]u8 = undefined;
    for (&counting, 0..) |*byte, i| byte.* = @intCast(i % 251);
    try expectRoundTrip(&counting);
}

test "compresses data of every shape" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5741_524C);
    const random = prng.random();

    var noise: [20_000]u8 = undefined;
    random.bytes(&noise);
    try expectRoundTrip(&noise);

    // Runs of noise and copies of what came before, from a byte to a few hundred back, over
    // distances that reach every form and go past the furthest one.
    const size = 400_000;
    const data = try gpa.alloc(u8, size);
    defer gpa.free(data);
    var at: usize = 0;
    while (at < size) {
        if (at > 16 and random.boolean()) {
            const distance = 1 + random.uintLessThan(usize, @min(at, 200_000));
            const len = @min(3 + random.uintLessThan(usize, 300), size - at);
            for (0..len) |i| data[at + i] = data[at + i - distance];
            at += len;
        } else {
            const len = @min(1 + random.uintLessThan(usize, 6), size - at);
            random.bytes(data[at..][0..len]);
            at += len;
        }
    }
    try expectRoundTrip(data);
}

test Compressor {
    const gpa = std.testing.allocator;
    var compressor: Compressor = try .init(gpa);
    defer compressor.deinit(gpa);

    // A long payload, then a short one whose positions land where the first one's did in the
    // tables, then none, then the long one again: each comes back whole.
    const long = "The quick brown fox jumps over the lazy dog. " ** 400;
    for ([_][]const u8{ long, "The quick brown fox", "", long }) |data| {
        const stream = try compressor.compress(gpa, data);
        defer gpa.free(stream);
        const expanded = try decompressAlloc(gpa, stream);
        defer gpa.free(expanded);
        try std.testing.expectEqualSlices(u8, data, expanded);
    }
}

test writeHeader {
    var bytes: [min_header_len]u8 = undefined;
    writeHeader(&bytes, 0x08B5A8);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0xFB, 0x08, 0xB5, 0xA8 }, &bytes);
    try std.testing.expect(gameExpands(&bytes));
    try std.testing.expectEqual(@as(u32, 0x08B5A8), (try readHeader(&bytes)).decompressed_size);
}

test "each form holds the match it was written for" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { distance: usize, len: usize, form: Form }{
        .{ .distance = 1, .len = 3, .form = .short },
        .{ .distance = 1024, .len = 10, .form = .short },
        .{ .distance = 1024, .len = 3, .form = .short },
        .{ .distance = 1025, .len = 4, .form = .medium },
        .{ .distance = 1, .len = 11, .form = .medium },
        .{ .distance = 16384, .len = 67, .form = .medium },
        .{ .distance = 16384, .len = 4, .form = .medium },
        .{ .distance = 1, .len = 68, .form = .long },
        .{ .distance = 16385, .len = 5, .form = .long },
        .{ .distance = 131071, .len = 5, .form = .long },
        .{ .distance = 131071, .len = 1028, .form = .long },
        .{ .distance = 500, .len = 1028, .form = .long },
    };
    const literals = [_]u8{ 0xA1, 0xB2, 0xC3 };
    for (cases) |case| {
        for (0..literals.len + 1) |carried| {
            var stream: Stream = .{};
            defer stream.deinit(gpa);
            const match = Match.of(case.distance, case.len).?;
            try std.testing.expectEqual(case.form, match.form);
            try stream.match(gpa, &literals, 0, carried, match);

            const command, const encoded_len = try Command.decode(stream.bytes.items);
            try std.testing.expectEqual(case.form.size(), encoded_len);
            try std.testing.expectEqual(carried, command.literals);
            try std.testing.expectEqual(case.len, command.match_len);
            try std.testing.expectEqual(case.distance, command.match_distance);
            try std.testing.expect(!command.last);
            // The carried literals follow the command's own bytes.
            try std.testing.expectEqualSlices(u8, literals[0..carried], stream.bytes.items[encoded_len..]);
            try std.testing.expectEqual(carried + case.len, stream.written);
        }
    }

    // What no form holds: a short match too far, a medium one too far, a match under 3, one over
    // 1028.
    try std.testing.expectEqual(null, Match.of(1025, 3));
    try std.testing.expectEqual(null, Match.of(16385, 4));
    try std.testing.expectEqual(null, Match.of(1, 2));
    try std.testing.expectEqual(null, Match.of(1, 1029));
}

test "each form's bytes at its limits" {
    // Every field at zero, then every field at its most: the fewest literals, the shortest match
    // and the nearest, then 3 literals, the longest match and the furthest the field holds.
    const cases = [_]struct { bytes: []const u8, literals: usize, len: usize, distance: usize }{
        .{ .bytes = &.{ 0x00, 0x00 }, .literals = 0, .len = 3, .distance = 1 },
        .{ .bytes = &.{ 0x7F, 0xFF }, .literals = 3, .len = 10, .distance = 1024 },
        .{ .bytes = &.{ 0x80, 0x00, 0x00 }, .literals = 0, .len = 4, .distance = 1 },
        .{ .bytes = &.{ 0xBF, 0xFF, 0xFF }, .literals = 3, .len = 67, .distance = 16384 },
        .{ .bytes = &.{ 0xC0, 0x00, 0x00, 0x00 }, .literals = 0, .len = 5, .distance = 1 },
        .{ .bytes = &.{ 0xDF, 0xFF, 0xFF, 0xFF }, .literals = 3, .len = 1028, .distance = 131072 },
        // Each field on its own: a short match's distance above 256, a long one's above 65536, and
        // a long one's length above 260.
        .{ .bytes = &.{ 0x60, 0x00 }, .literals = 0, .len = 3, .distance = 769 },
        .{ .bytes = &.{ 0xD0, 0x00, 0x00, 0x00 }, .literals = 0, .len = 5, .distance = 65537 },
        .{ .bytes = &.{ 0xCC, 0x00, 0x00, 0x00 }, .literals = 0, .len = 773, .distance = 1 },
    };
    for (cases) |case| {
        const command, const encoded_len = try Command.decode(case.bytes);
        try std.testing.expectEqual(case.bytes.len, encoded_len);
        try std.testing.expectEqual(case.literals, command.literals);
        try std.testing.expectEqual(case.len, command.match_len);
        try std.testing.expectEqual(case.distance, command.match_distance);
        try std.testing.expect(!command.last);
    }
}

test "each form's bytes at its limits, as the encoder writes them" {
    const gpa = std.testing.allocator;
    const literals = [_]u8{ 0xA1, 0xB2, 0xC3 };
    // The bytes the decoding test reads, written from the other side: every field at zero, then at
    // its most (the long form to the furthest the encoder reaches, one short of its field's), then
    // each field on its own.
    const cases = [_]struct { match: Match, carried: usize, bytes: []const u8 }{
        .{ .match = .{ .distance = 1, .len = 3, .form = .short }, .carried = 0, .bytes = &.{ 0x00, 0x00 } },
        .{ .match = .{ .distance = 1024, .len = 10, .form = .short }, .carried = 3, .bytes = &.{ 0x7F, 0xFF } },
        .{ .match = .{ .distance = 1, .len = 4, .form = .medium }, .carried = 0, .bytes = &.{ 0x80, 0x00, 0x00 } },
        .{ .match = .{ .distance = 16384, .len = 67, .form = .medium }, .carried = 3, .bytes = &.{ 0xBF, 0xFF, 0xFF } },
        .{ .match = .{ .distance = 1, .len = 5, .form = .long }, .carried = 0, .bytes = &.{ 0xC0, 0x00, 0x00, 0x00 } },
        .{ .match = .{ .distance = 131071, .len = 1028, .form = .long }, .carried = 3, .bytes = &.{ 0xDF, 0xFF, 0xFE, 0xFF } },
        .{ .match = .{ .distance = 769, .len = 3, .form = .short }, .carried = 0, .bytes = &.{ 0x60, 0x00 } },
        .{ .match = .{ .distance = 65537, .len = 5, .form = .long }, .carried = 0, .bytes = &.{ 0xD0, 0x00, 0x00, 0x00 } },
        .{ .match = .{ .distance = 1, .len = 773, .form = .long }, .carried = 0, .bytes = &.{ 0xCC, 0x00, 0x00, 0x00 } },
    };
    for (cases) |case| {
        var stream: Stream = .{};
        defer stream.deinit(gpa);
        try stream.match(gpa, &literals, 0, case.carried, case.match);
        try std.testing.expectEqualSlices(u8, case.bytes, stream.bytes.items[0..case.bytes.len]);
        try std.testing.expectEqualSlices(u8, literals[0..case.carried], stream.bytes.items[case.bytes.len..]);
    }
}

test "literals go in runs of at most 112 and the last few ride the next command" {
    const gpa = std.testing.allocator;
    var data: [303]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast(i % 256);

    var stream: Stream = .{};
    defer stream.deinit(gpa);
    const rest = try stream.runs(gpa, &data, 0, data.len);
    // 112, 112 and 76 leave 3.
    try std.testing.expectEqual(@as(usize, 300), rest);
    try std.testing.expectEqual(@as(usize, 300), stream.written);
    try std.testing.expectEqual(@as(usize, 303), stream.bytes.items.len);
    try std.testing.expectEqual(@as(u8, 0xFB), stream.bytes.items[0]);
    try std.testing.expectEqualSlices(u8, data[0..112], stream.bytes.items[1..113]);
    try std.testing.expectEqual(@as(u8, 0xFB), stream.bytes.items[113]);
    try std.testing.expectEqual(@as(u8, 0xF2), stream.bytes.items[226]);

    // Three or fewer are not a run.
    var none: Stream = .{};
    defer none.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), try none.runs(gpa, &data, 0, 3));
    try std.testing.expectEqual(@as(usize, 0), none.bytes.items.len);
}

test inPlaceExcess {
    // `abcd`, then a match of 8 from 4 back: the stream is one byte longer than its data, all in
    // the terminator still to read, and no later point is worse.
    const short = [_]u8{ 0x10, 0xFB, 0x00, 0x00, 0x0C, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC };
    try std.testing.expectEqual(@as(i64, 1), try inPlaceExcess(&short));

    // A stream shorter than its data, and worst in the middle: three matches that each put the
    // output 6 bytes ahead of the input, then two runs of literals that take the input back. It
    // starts at -9 and stands at 3 after the third match.
    const middle = [_]u8{
        0x10, 0xFB, 0x00, 0x00, 36, // 36 bytes out
        0xE0, 'a', 'b', 'c', 'd', // 4
        0x14, 0x03, 0x14, 0x03, 0x14, 0x03, // 24 more
        0xE0, 'e', 'f', 'g', 'h', 0xE0, 'i', 'j', 'k', 'l', // 8 more
        0xFC,
    };
    try std.testing.expectEqual(@as(i64, 3), try inPlaceExcess(&middle));
    const expanded = try decompressAlloc(std.testing.allocator, &middle);
    defer std.testing.allocator.free(expanded);
    try std.testing.expectEqual(@as(usize, 36), expanded.len);

    // Only the form the game expands has a bound.
    try std.testing.expectError(error.BadSignature, inPlaceExcess(&.{ 0x11, 0xFB, 0, 0, 0, 0, 0, 0, 0xFC }));
    try std.testing.expectError(error.UnexpectedEnd, inPlaceExcess(&.{ 0x10, 0xFB, 0, 0, 4, 0xE0, 'a' }));

    // Commands that give a byte fewer, or a byte more, than the header declares, and a match that
    // reaches before the start of the output.
    try std.testing.expectError(error.SizeMismatch, inPlaceExcess(&.{ 0x10, 0xFB, 0x00, 0x00, 0x0D, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC }));
    try std.testing.expectError(error.SizeMismatch, inPlaceExcess(&.{ 0x10, 0xFB, 0x00, 0x00, 0x0B, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC }));
    try std.testing.expectError(error.BadReference, inPlaceExcess(&.{ 0x10, 0xFB, 0x00, 0x00, 0x08, 0x14, 0x03, 0xFC }));
}

/// A stream of `size` zero bytes written as literals alone, finished as the encoder finishes its
/// streams, and the excess the encoder kept as it wrote it.
fn literalStream(gpa: Allocator, size: usize) !struct { []u8, i64 } {
    const data = try gpa.alloc(u8, size);
    defer gpa.free(data);
    @memset(data, 0);

    var stream: Stream = .{};
    errdefer stream.deinit(gpa);
    try stream.start(gpa, @intCast(size));
    try stream.finish(gpa, data, 0);
    const kept = stream.excess();
    return .{ try stream.bytes.toOwnedSlice(gpa), kept };
}

test "the largest literals-only payload the game loads in place" {
    const gpa = std.testing.allocator;
    // Each run of 112 adds a control byte, and the header and the terminator add 6, and a last
    // run when 4 or more are left over: a payload of N bytes takes
    // `5 + N / 112 + (N % 112 >= 4) + 1` more than its own size. That is the slack at
    // `testing.largest_in_place` bytes, and one over it a byte later
    // ([#113](https://github.com/OpenReliant/openreliant/issues/113)).
    const largest = testing.largest_in_place;
    for ([_]usize{ 1000, largest, largest + 1 }) |size| {
        const stream, const kept = try literalStream(gpa, size);
        defer gpa.free(stream);
        const expected: i64 = @intCast(5 + size / 112 + @intFromBool(size % 112 >= 4) + 1);
        try std.testing.expectEqual(expected, try inPlaceExcess(stream));
        try std.testing.expectEqual(expected, kept);
        try std.testing.expectEqual(size <= largest, loadsInPlace(stream));
        if (size == largest) try std.testing.expectEqual(@as(i64, in_place_slack), expected);
        if (size == largest + 1) try std.testing.expectEqual(@as(i64, in_place_slack) + 1, expected);
    }
}

test loadsInPlace {
    try std.testing.expect(loadsInPlace(&.{ 0x10, 0xFB, 0x00, 0x00, 0x0C, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC }));
    // Another form of stream, which the game does not expand, one cut short, one that ends a byte
    // short of its size, and no stream at all.
    try std.testing.expect(!loadsInPlace(&.{ 0x11, 0xFB, 0, 0, 0, 0, 0, 0, 0xFC }));
    try std.testing.expect(!loadsInPlace(&.{ 0x10, 0xFB, 0, 0, 4, 0xE0, 'a' }));
    try std.testing.expect(!loadsInPlace(&.{ 0x10, 0xFB, 0x00, 0x00, 0x0D, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC }));
    try std.testing.expect(!loadsInPlace("RIFF"));
}

test "testing.literals writes the stream the encoder writes for no matches" {
    const gpa = std.testing.allocator;
    const stream = try testing.literals(gpa, "abcdefg");
    defer gpa.free(stream);
    // A run of four, then the terminator carrying the last three.
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0xFB, 0, 0, 7, 0xE0, 'a', 'b', 'c', 'd', 0xFF, 'e', 'f', 'g' }, stream);
}

test "a stream the game could not load in place is refused" {
    const gpa = std.testing.allocator;
    var compressor: Compressor = try .init(gpa);
    defer compressor.deinit(gpa);

    var prng: std.Random.DefaultPrng = .init(3);
    var noise: [3000]u8 = undefined;
    prng.random().bytes(&noise);
    // A run of zeros puts the output far ahead of the input, and a tail of noise then takes the
    // input past it: the worst point is in the middle of the stream.
    const ahead = try gpa.alloc(u8, 200_000);
    defer gpa.free(ahead);
    @memset(ahead[0 .. ahead.len - noise.len], 0);
    @memcpy(ahead[ahead.len - noise.len ..], &noise);

    // Noise alone is longer compressed than it is, and the other is worst in the middle: for each,
    // the encoder's own count of the excess is what `inPlaceExcess` reads from the stream, since it
    // loads at that bound and is refused one under it.
    for ([_][]const u8{ &noise, ahead }) |data| {
        const stream = try compressor.compressWithin(gpa, data, in_place_slack);
        defer gpa.free(stream);
        const excess: usize = @intCast(try inPlaceExcess(stream));
        try std.testing.expect(excess > 0);
        const at_bound = try compressor.compressWithin(gpa, data, excess);
        gpa.free(at_bound);
        try std.testing.expectError(error.NotInPlace, compressor.compressWithin(gpa, data, excess - 1));
    }

    // More than the header holds.
    const huge = try gpa.alloc(u8, max_size + 1);
    defer gpa.free(huge);
    try std.testing.expectError(error.TooLarge, compressAlloc(gpa, huge));
}
