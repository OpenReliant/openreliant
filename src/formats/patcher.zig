//! The patcher of the Slovak fan translation
//! ([docs/formats/translations.md](../../docs/formats/translations.md#the-slovak-patcher)): a small
//! Windows program, and after it a run of blocks. One block lists the files it writes, and the
//! last holds their data. A file comes whole, or as a patch against another file of the patcher.
//!
//! **Unverified:** the product that made it. Its block numbers, `0x1234` to `0x1242` and `0x7F7F`
//! for the data, match those of Clickteam's installers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const pe = @import("pe.zig");

pub const Error = error{ NotAPatcher, Corrupt } || Allocator.Error;

/// A block of the patcher's data: a number, whether its data is packed, and how many bytes
/// follow. A packed block's bytes start with its unpacked size.
const Block = extern struct {
    kind: Kind align(1),
    is_packed: u16 align(1),
    size: u32 align(1),

    const Kind = enum(u16) {
        /// The files the patcher writes (`files_block`, `0x00407196`).
        files = 0x1242,
        /// The files' data, which ends the blocks.
        data = 0x7F7F,
        _,
    };

    comptime {
        assert(@sizeOf(Block) == 8);
    }
};

/// A file the patcher writes.
pub const File = struct {
    name: []const u8,
    /// How many bytes it is once written.
    size: u32,
    kind: Kind,
    /// Where its data lies in the data block, and how many bytes it takes there.
    offset: u32,
    stored: u32,

    pub const Kind = enum(u16) {
        /// Changes to make to another file: a list of commands and the bytes they add.
        patch = 0x21,
        /// The file itself, packed.
        whole = 0x22,
        _,
    };

    /// The name of the file a patch changes: its own. The patcher keeps the file it replaces
    /// under that name and `backup_suffix`, and carries a copy of it whole under the same.
    pub const backup_suffix = ".eng";
};

/// The header of a file's record in the files block, up to its three times; its name follows
/// them, and the record ends with `Tail`.
const Record = extern struct {
    size: u32 align(1),
    flags: u32 align(1),
    kind: File.Kind align(1),
    checksum: u32 align(1),
    /// The file's size once written.
    written: u32 align(1),
    _unknown_12: [12]u8 align(1),
    times: [3]u64 align(1),

    comptime {
        assert(@offsetOf(Record, "written") == 0x0E);
        assert(@offsetOf(Record, "times") == 0x1E);
        assert(@sizeOf(Record) == 0x36);
    }
};

/// The end of a file's record: where its data lies.
const Tail = extern struct {
    checksum: u32 align(1),
    /// For a patch, the size of the file it changes.
    source_size: u32 align(1),
    offset: u32 align(1),
    stored: u32 align(1),

    comptime {
        assert(@sizeOf(Tail) == 16);
    }
};

/// A patcher, read: its files, and the data block they lie in.
pub const Patcher = struct {
    files: []const File,
    data: []const u8,

    /// Reads the patcher `bytes`, which must outlive it. `error.NotAPatcher` for bytes that are
    /// no Windows program with these blocks after it.
    pub fn read(arena: Allocator, bytes: []u8) Error!Patcher {
        var at = overlay(bytes) orelse return error.NotAPatcher;
        var listed: ?[]const File = null;
        while (at + @sizeOf(Block) <= bytes.len) {
            const block = std.mem.bytesToValue(Block, bytes[at..][0..@sizeOf(Block)]);
            at += @sizeOf(Block);
            if (block.is_packed > 1 or block.size > bytes.len - at) return error.NotAPatcher;
            const held = bytes[at..][0..block.size];
            at += block.size;
            switch (block.kind) {
                .files => listed = try files(arena, try unpackBlock(arena, block, held)),
                .data => {
                    // The data block's own size comes first, and the data is the rest of the file.
                    if (held.len < 4) return error.Corrupt;
                    const size = std.mem.readInt(u32, held[0..4], .little);
                    const start = at - block.size + 4;
                    if (size > bytes.len - start) return error.Corrupt;
                    return .{ .files = listed orelse return error.NotAPatcher, .data = bytes[start..][0..size] };
                },
                _ => {},
            }
        }
        return error.NotAPatcher;
    }

    /// The file named `name`, without regard to case.
    pub fn find(patcher: Patcher, name: []const u8) ?File {
        for (patcher.files) |file| {
            if (std.ascii.eqlIgnoreCase(file.name, name)) return file;
        }
        return null;
    }

    /// What `file` is once written. A patch is made against the copy the patcher carries of the
    /// file it changes, so nothing needs to be installed.
    pub fn write(patcher: Patcher, arena: Allocator, file: File) Error![]u8 {
        if (file.offset > patcher.data.len or file.stored > patcher.data.len - file.offset) return error.Corrupt;
        const held = patcher.data[file.offset..][0..file.stored];
        switch (file.kind) {
            .whole => {
                const made = try inflate(arena, held, file.size);
                if (made.len != file.size) return error.Corrupt;
                return made;
            },
            .patch => {
                const backup = try std.mem.concat(arena, u8, &.{ file.name, File.backup_suffix });
                const before = patcher.find(backup) orelse return error.Corrupt;
                if (before.kind != .whole) return error.Corrupt;
                const source = try patcher.write(arena, before);
                var rest = held;
                const commands = try chunk(arena, &rest);
                const added = try chunk(arena, &rest);
                const made = try apply(arena, commands, added, source, file.size);
                if (made.len != file.size) return error.Corrupt;
                return made;
            },
            _ => return error.Corrupt,
        }
    }
};

/// Where the blocks start in `bytes`: after the last section of the program. Null for bytes that
/// aren't a Windows program's, or have nothing after it.
fn overlay(bytes: []u8) ?usize {
    const last = programEnd(bytes) orelse return null;
    return if (last < bytes.len) last else null;
}

/// Where the last section of the program `bytes` ends. Null for bytes that aren't a Windows
/// program's.
fn programEnd(bytes: []u8) ?usize {
    const image = pe.Image.parse(bytes) catch return null;
    var last: usize = 0;
    for (image.sections) |section| last = @max(last, @as(usize, section.raw_offset) + section.raw_size);
    return if (last != 0 and last <= bytes.len) last else null;
}

/// A block's data, unpacked where it is packed.
fn unpackBlock(arena: Allocator, block: Block, held: []const u8) Error![]const u8 {
    if (block.is_packed == 0) return held;
    if (held.len < 4) return error.Corrupt;
    const size = std.mem.readInt(u32, held[0..4], .little);
    const made = try inflate(arena, held[4..], size);
    if (made.len != size) return error.Corrupt;
    return made;
}

/// The files a files block lists: a count, then a record for each.
fn files(arena: Allocator, block: []const u8) Error![]const File {
    if (block.len < 4) return error.Corrupt;
    const count = std.mem.readInt(u32, block[0..4], .little);
    if (count > block.len / @sizeOf(Record)) return error.Corrupt;
    const listed = try arena.alloc(File, count);
    var at: usize = 4;
    for (listed) |*file| {
        if (block.len - at < @sizeOf(Record)) return error.Corrupt;
        const record = std.mem.bytesToValue(Record, block[at..][0..@sizeOf(Record)]);
        if (record.size < @sizeOf(Record) + 1 + @sizeOf(Tail) or record.size > block.len - at) return error.Corrupt;
        const whole = block[at..][0..record.size];
        const named = whole[@sizeOf(Record) .. whole.len - @sizeOf(Tail)];
        const tail = std.mem.bytesToValue(Tail, whole[whole.len - @sizeOf(Tail) ..][0..@sizeOf(Tail)]);
        file.* = .{
            .name = named[0 .. std.mem.indexOfScalar(u8, named, 0) orelse return error.Corrupt],
            .size = record.written,
            .kind = record.kind,
            .offset = tail.offset,
            .stored = tail.stored,
        };
        at += record.size;
    }
    return listed;
}

/// A piece of a patch as the data block holds it (`patch_chunk`, `0x0040564B`), taken off the
/// front of `rest`: a byte of flags, its size, and its bytes, packed or as they are.
fn chunk(arena: Allocator, rest: *[]const u8) Error![]const u8 {
    const Flags = packed struct(u8) {
        /// Its bytes are packed, and their packed size follows its size.
        is_packed: bool,
        /// Its size is four bytes, not two.
        long_size: bool,
        /// Its packed size is four bytes, not two.
        long_stored: bool,
        _unknown_3: u5,
    };
    const size = struct {
        fn take(from: *[]const u8, long: bool) Error!usize {
            const width: usize = if (long) 4 else 2;
            if (from.len < width) return error.Corrupt;
            const value: usize = if (long) std.mem.readInt(u32, from.*[0..4], .little) else std.mem.readInt(u16, from.*[0..2], .little);
            from.* = from.*[width..];
            return value;
        }
    }.take;
    if (rest.len < 1) return error.Corrupt;
    const flags: Flags = @bitCast(rest.*[0]);
    rest.* = rest.*[1..];
    const length = try size(rest, flags.long_size);
    if (length == 0) return &.{};
    const stored = if (flags.is_packed) try size(rest, flags.long_stored) else length;
    if (stored > rest.len) return error.Corrupt;
    const held = rest.*[0..stored];
    rest.* = rest.*[stored..];
    if (!flags.is_packed) return held;
    const made = try inflate(arena, held, length);
    if (made.len != length) return error.Corrupt;
    return made;
}

/// How far a copy's place may lie from the last one's end before it takes the next longer form:
/// the short form reaches 32 either way (`0x00404F86`), and the middle one 16416 (`0x00405017`).
const short_reach = 0x20;
const middle_reach = 0x4020;

/// The value of the middle form that says a four-byte place follows (`0x00404FD3`).
const far_place = 0x100000;

/// The fewest bytes a copy takes whose length is two bytes after a zero byte (`0x00404F2C`).
const long_copy = 0x81;

/// Makes a file of `size` bytes from `source` by a patch (`patch_apply`, `0x004049D8`): `commands`
/// say what to copy from `source` and how many of `added`'s bytes to put between.
///
/// A command's first byte with its top bit set adds bytes: with bits 5 and 6 clear, as many as
/// its low five bits and one more, and no copy; else as many as bits 5 and 6 say, then a copy of
/// its low five bits and two more. With its top bit clear it only copies: that many bytes and one
/// more, or for a zero byte the next two bytes and `long_copy` more.
///
/// A copy's place follows, counted from where the last copy ended, as a signed number in one of
/// three forms: six bits in the one byte; fifteen bits in two, `short_reach` further out; or
/// twenty-two bits in three, `middle_reach` further out, where `far_place` says four bytes follow
/// with the number itself.
fn apply(arena: Allocator, commands: []const u8, added: []const u8, source: []const u8, size: usize) Error![]u8 {
    var made: std.ArrayList(u8) = try .initCapacity(arena, size);
    var command: std.Io.Reader = .fixed(commands);
    var adding = added;
    var from: i64 = 0;
    while (command.seek < commands.len) {
        const first = command.takeByte() catch return error.Corrupt;
        var copied: usize = 0;
        if (first & 0x80 != 0) {
            const some: usize = (first >> 5) & 3;
            const count = if (some == 0) @as(usize, first & 0x1F) + 1 else some;
            if (some != 0) copied = @as(usize, first & 0x1F) + 2;
            if (count > adding.len or count > size - made.items.len) return error.Corrupt;
            made.appendSliceAssumeCapacity(adding[0..count]);
            adding = adding[count..];
        } else if (first == 0) {
            copied = @as(usize, command.takeInt(u16, .little) catch return error.Corrupt) + long_copy;
        } else {
            copied = @as(usize, first) + 1;
        }
        if (copied == 0) continue;

        const lead = command.takeByte() catch return error.Corrupt;
        const move: i64 = if (lead & 0x80 == 0) near: {
            const low = command.takeByte() catch return error.Corrupt;
            const value: i64 = @as(i15, @bitCast(@as(u15, lead & 0x7F) << 8 | low));
            break :near if (value < 0) value - short_reach else value + short_reach;
        } else if (lead & 0x40 == 0)
            @as(i6, @bitCast(@as(u6, @truncate(lead))))
        else far: {
            const rest = command.takeArray(2) catch return error.Corrupt;
            const value: u22 = @as(u22, lead & 0x3F) << 16 | @as(u22, rest[0]) << 8 | rest[1];
            if (value == far_place) break :far command.takeInt(i32, .big) catch return error.Corrupt;
            const signed: i64 = @as(i22, @bitCast(value));
            break :far if (signed < 0) signed - middle_reach else signed + middle_reach;
        };
        const place = from + move;
        if (place < 0 or place > source.len or copied > source.len - @as(usize, @intCast(place))) return error.Corrupt;
        if (copied > size - made.items.len) return error.Corrupt;
        made.appendSliceAssumeCapacity(source[@intCast(place)..][0..copied]);
        from = place + @as(i64, @intCast(copied));
    }
    return made.items;
}

/// How deflate numbers the kinds of block here: as usual, with 4 added (`0x004034C6`).
const BlockKind = enum(u3) { fixed = 5, dynamic = 6, stored = 7, _ };

/// The order the lengths of the code-length code come in: the three repeat codes first, from 18
/// down, then the lengths from 0 up (`0x00403391`). Deflate has its own order for them.
const length_order = [3]u8{ 18, 17, 16 } ++ lengths: {
    var plain: [16]u8 = undefined;
    for (&plain, 0..) |*length, at| length.* = at;
    break :lengths plain;
};

/// Deflate's lengths and distances, which the patcher works out as it starts (`0x00403335`): the
/// least each code stands for, and how many more bits follow it.
const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra = [30]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

/// The end of a block among the literal and length codes, and the most of those and of the
/// distance codes.
const end_of_block = 256;
const most_literals = 286;
const most_distances = 30;

/// The longest code, in bits.
const longest_code = 15;

/// A Huffman code as deflate builds one from its codes' lengths.
const Code = struct {
    /// How many codes have each length, and the symbols in the order of their codes.
    counts: [longest_code + 1]u16,
    symbols: [most_literals + 2]u16,

    /// The code for the symbols whose `lengths` are given, 0 for one that isn't used.
    /// `error.Corrupt` for lengths no code can have.
    fn of(lengths: []const u4) error{Corrupt}!Code {
        var code: Code = .{ .counts = @splat(0), .symbols = undefined };
        for (lengths) |length| code.counts[length] += 1;
        code.counts[0] = 0;
        var left: i32 = 1;
        for (code.counts[1..]) |count| {
            left = left * 2 - count;
            if (left < 0) return error.Corrupt;
        }
        var starts: [longest_code + 2]u16 = @splat(0);
        for (1..longest_code + 1) |length| starts[length + 1] = starts[length] + code.counts[length];
        for (lengths, 0..) |length, symbol| {
            if (length == 0) continue;
            code.symbols[starts[length]] = @intCast(symbol);
            starts[length] += 1;
        }
        return code;
    }

    /// The next symbol of `bits`, read a bit at a time, the code's first bit first.
    fn next(code: *const Code, bits: *Bits) error{Corrupt}!u16 {
        var value: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (code.counts[1..]) |count| {
            value |= try bits.take(1);
            if (value - count < first) return code.symbols[@intCast(index + (value - first))];
            index += count;
            first = (first + count) * 2;
            value *= 2;
        }
        return error.Corrupt;
    }
};

/// Bits read from the least significant of each byte up, as deflate packs them.
const Bits = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(bits: *Bits, count: u5) error{Corrupt}!u16 {
        var value: u32 = 0;
        for (0..count) |place| {
            if (bits.at >> 3 >= bits.bytes.len) return error.Corrupt;
            const bit: u32 = (bits.bytes[bits.at >> 3] >> @intCast(bits.at & 7)) & 1;
            value |= bit << @intCast(place);
            bits.at += 1;
        }
        return @intCast(value);
    }

    /// On to the next whole byte.
    fn alignToByte(bits: *Bits) void {
        bits.at = (bits.at + 7) & ~@as(usize, 7);
    }
};

/// The codes of a block with the fixed codes.
const fixed_literals: Code = Code.of(&(@as([144]u4, @splat(8)) ++ @as([112]u4, @splat(9)) ++ @as([24]u4, @splat(7)) ++ @as([8]u4, @splat(8)))) catch unreachable;
const fixed_distances: Code = Code.of(&@as([most_distances]u4, @splat(5))) catch unreachable;

/// Unpacks `held`, about `size` bytes once unpacked (`inflate`, `0x004032C3`). The patcher packs
/// with deflate, changed in three small ways so that no other program reads it: a block starts
/// with three bits for its kind (`BlockKind`) and then the one that says it is the last; the
/// lengths of the code-length code come in `length_order`; and a stored block has its length
/// alone before its bytes, without the length's complement.
pub fn inflate(arena: Allocator, held: []const u8, size: usize) Error![]u8 {
    var made: std.ArrayList(u8) = try .initCapacity(arena, size);
    var bits: Bits = .{ .bytes = held };
    while (true) {
        const kind: BlockKind = @fromBackingInt(@intCast(try bits.take(3)));
        const last = try bits.take(1) == 1;
        switch (kind) {
            .stored => {
                bits.alignToByte();
                const length = try bits.take(16);
                const start = bits.at >> 3;
                if (length > held.len - start) return error.Corrupt;
                try made.appendSlice(arena, held[start..][0..length]);
                bits.at += @as(usize, length) * 8;
            },
            .fixed => try symbols(arena, &made, &bits, &fixed_literals, &fixed_distances),
            .dynamic => {
                const literals = try bits.take(5) + 257;
                const distances = try bits.take(5) + 1;
                const coded = try bits.take(4) + 4;
                if (literals > most_literals or distances > most_distances) return error.Corrupt;
                var code_lengths: [length_order.len]u4 = @splat(0);
                for (length_order[0..coded]) |symbol| code_lengths[symbol] = @intCast(try bits.take(3));
                const lengths_code: Code = try .of(&code_lengths);
                var lengths: [most_literals + most_distances]u4 = undefined;
                var filled: usize = 0;
                const wanted = literals + distances;
                while (filled < wanted) {
                    const symbol = try lengths_code.next(&bits);
                    const value: u4, const run: usize = switch (symbol) {
                        0...15 => .{ @intCast(symbol), 1 },
                        16 => .{ if (filled == 0) return error.Corrupt else lengths[filled - 1], @as(usize, try bits.take(2)) + 3 },
                        17 => .{ 0, @as(usize, try bits.take(3)) + 3 },
                        else => .{ 0, @as(usize, try bits.take(7)) + 11 },
                    };
                    if (run > wanted - filled) return error.Corrupt;
                    @memset(lengths[filled..][0..run], value);
                    filled += run;
                }
                const literal_code: Code = try .of(lengths[0..literals]);
                const distance_code: Code = try .of(lengths[literals..wanted]);
                try symbols(arena, &made, &bits, &literal_code, &distance_code);
            },
            _ => return error.Corrupt,
        }
        if (last) return made.items;
    }
}

/// A block's literals and copies, up to its end.
fn symbols(arena: Allocator, made: *std.ArrayList(u8), bits: *Bits, literals: *const Code, distances: *const Code) Error!void {
    while (true) {
        const symbol = try literals.next(bits);
        if (symbol < end_of_block) {
            try made.append(arena, @intCast(symbol));
            continue;
        }
        if (symbol == end_of_block) return;
        const length_code = symbol - end_of_block - 1;
        if (length_code >= length_base.len) return error.Corrupt;
        const length = length_base[length_code] + try bits.take(length_extra[length_code]);
        const distance_code = try distances.next(bits);
        if (distance_code >= distance_base.len) return error.Corrupt;
        const distance = @as(usize, distance_base[distance_code]) + try bits.take(distance_extra[distance_code]);
        if (distance > made.items.len) return error.Corrupt;
        try made.ensureUnusedCapacity(arena, length);
        for (0..length) |_| made.appendAssumeCapacity(made.items[made.items.len - distance]);
    }
}

pub const testing = struct {
    /// Bits written as `Bits` reads them.
    const Packer = struct {
        bytes: std.ArrayList(u8) = .empty,
        used: usize = 0,

        fn put(packer: *Packer, gpa: Allocator, value: u32, count: u5) !void {
            for (0..count) |place| {
                if (packer.used & 7 == 0) try packer.bytes.append(gpa, 0);
                const bit: u8 = @intCast((value >> @intCast(place)) & 1);
                packer.bytes.items[packer.used >> 3] |= bit << @intCast(packer.used & 7);
                packer.used += 1;
            }
        }

        /// A code of the fixed literals, whose first bit comes first.
        fn literal(packer: *Packer, gpa: Allocator, symbol: u16) !void {
            const code: u16, const length: u5 = switch (symbol) {
                0...143 => .{ 0x30 + symbol, 8 },
                144...255 => .{ 0x190 + symbol - 144, 9 },
                256...279 => .{ symbol - 256, 7 },
                else => .{ 0xC0 + symbol - 280, 8 },
            };
            for (0..length) |place| try packer.put(gpa, (code >> @intCast(length - 1 - place)) & 1, 1);
        }
    };

    /// `bytes` packed as the patcher packs: a stored block where `stored`, else a block of the
    /// fixed codes with no copies.
    pub fn deflate(gpa: Allocator, bytes: []const u8, stored: bool) ![]u8 {
        var packer: Packer = .{};
        errdefer packer.bytes.deinit(gpa);
        try packer.put(gpa, @backingInt(if (stored) BlockKind.stored else BlockKind.fixed), 3);
        try packer.put(gpa, 1, 1);
        if (stored) {
            try packer.put(gpa, 0, 4);
            try packer.put(gpa, @intCast(bytes.len), 16);
            try packer.bytes.appendSlice(gpa, bytes);
        } else {
            for (bytes) |byte| try packer.literal(gpa, byte);
            try packer.literal(gpa, end_of_block);
        }
        return packer.bytes.toOwnedSlice(gpa);
    }

    /// A small Windows program, as the front of a patcher: up to the end of its last section.
    pub fn program(gpa: Allocator) ![]u8 {
        const built = try pe.testing.buildWith(gpa, 0x400000, &.{.{ .name = ".text", .rva = 0x1000, .data = "code" }}, &.{});
        defer gpa.free(built);
        return gpa.dupe(u8, built[0..programEnd(built).?]);
    }

    pub const Made = struct { name: []const u8, kind: File.Kind, data: []const u8, size: u32 };

    /// A patcher that writes `listed`, each one's `data` as the data block holds it: a small
    /// program, a files block and the data block.
    pub fn patcher(gpa: Allocator, listed: []const Made) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const front = try program(gpa);
        defer gpa.free(front);
        try out.appendSlice(gpa, front);

        var table: std.ArrayList(u8) = .empty;
        defer table.deinit(gpa);
        try table.appendSlice(gpa, &std.mem.toBytes(@as(u32, @intCast(listed.len))));
        var offset: u32 = 0;
        for (listed) |file| {
            const padded = file.name.len + 2;
            var record = std.mem.zeroes(Record);
            record.size = @intCast(@sizeOf(Record) + padded + @sizeOf(Tail));
            record.kind = file.kind;
            record.written = file.size;
            try table.appendSlice(gpa, std.mem.asBytes(&record));
            try table.appendSlice(gpa, file.name);
            try table.appendSlice(gpa, &.{ 0, 0 });
            const tail: Tail = .{ .checksum = 0, .source_size = 0, .offset = offset, .stored = @intCast(file.data.len) };
            try table.appendSlice(gpa, std.mem.asBytes(&tail));
            offset += @intCast(file.data.len);
        }
        const packed_table = try deflate(gpa, table.items, false);
        defer gpa.free(packed_table);
        const files_block: Block = .{ .kind = .files, .is_packed = 1, .size = @intCast(packed_table.len + 4) };
        try out.appendSlice(gpa, std.mem.asBytes(&files_block));
        try out.appendSlice(gpa, &std.mem.toBytes(@as(u32, @intCast(table.items.len))));
        try out.appendSlice(gpa, packed_table);

        const data_block: Block = .{ .kind = .data, .is_packed = 0, .size = offset };
        try out.appendSlice(gpa, std.mem.asBytes(&data_block));
        try out.appendSlice(gpa, &std.mem.toBytes(offset));
        for (listed) |file| try out.appendSlice(gpa, file.data);
        return out.toOwnedSlice(gpa);
    }

    /// A patch's two pieces as the data block holds them, neither packed.
    pub fn patch(gpa: Allocator, commands: []const u8, added: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for ([_][]const u8{ commands, added }) |piece| {
            try out.append(gpa, 0);
            try out.appendSlice(gpa, &std.mem.toBytes(@as(u16, @intCast(piece.len))));
            try out.appendSlice(gpa, piece);
        }
        return out.toOwnedSlice(gpa);
    }
};

test inflate {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "SOFTWARE\\Microsoft\\Microsoft Games\\Starlancer\\1.0";
    for ([_]bool{ false, true }) |stored| {
        const held = try testing.deflate(arena, text, stored);
        try std.testing.expectEqualStrings(text, try inflate(arena, held, text.len));
    }
    // A block of deflate's own kinds is refused, and so is one cut short.
    try std.testing.expectError(error.Corrupt, inflate(arena, &.{0x03}, 0));
    const held = try testing.deflate(arena, text, false);
    try std.testing.expectError(error.Corrupt, inflate(arena, held[0 .. held.len - 2], text.len));
}

test "the lengths of a block's own codes come with the repeat codes first" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A dynamic block that holds two `a`s: the literal code has `a` and the block's end, a bit
    // each, written as a length of 1, a run of zeroes, a 1 and another run. The code-length code
    // gives 1 and the two zero runs codes, in the patcher's order: 18 first, then 17, 16, 0, 1.
    var packer: testing.Packer = .{};
    try packer.put(arena, @backingInt(BlockKind.dynamic), 3);
    try packer.put(arena, 1, 1);
    try packer.put(arena, 0, 5);
    try packer.put(arena, 0, 5);
    try packer.put(arena, 5 - 4, 4);
    // Lengths for 18, 17, 16, 0 and 1: 1 bit for the long zero run, 2 for the short one and for 1.
    for ([_]u32{ 1, 2, 0, 0, 2 }) |length| try packer.put(arena, length, 3);
    // 97 zeroes, a 1 for `a`, 158 zeroes, a 1 for the end, and a 1 for the one distance code:
    // the long run is the code 0, the lengths' 1 the code 10 and the short run 11.
    try packer.put(arena, 0, 1);
    try packer.put(arena, 97 - 11, 7);
    try packer.put(arena, 0b01, 2);
    try packer.put(arena, 0, 1);
    try packer.put(arena, 127, 7);
    try packer.put(arena, 0, 1);
    try packer.put(arena, 158 - 138 - 11, 7);
    try packer.put(arena, 0b01, 2);
    try packer.put(arena, 0b01, 2);
    // `a` is the code 0 and the end the code 1.
    try packer.put(arena, 0, 1);
    try packer.put(arena, 0, 1);
    try packer.put(arena, 1, 1);
    try std.testing.expectEqualStrings("aa", try inflate(arena, packer.bytes.items, 2));
}

test apply {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = "The quick brown fox jumps over the lazy dog";
    // Copy "The quick " from the start; add "red" and copy " fox" from 5 on; add one byte.
    const commands = [_]u8{
        10 - 1,       0x80 | 0,
        0xE0 | 4 - 2, 0x80 | 5,
        0x80 | 0,
    };
    try std.testing.expectEqualStrings("The quick red fox!", try apply(arena, &commands, "red!", source, 18));
    // A copy back from where the last one ended: "fox" again, six bits before.
    const back = [_]u8{ 0x80 | 0, 3 - 1, 0x80 | 16, 3 - 1, 0x80 | @as(u8, @as(u6, @bitCast(@as(i6, -3)))) };
    try std.testing.expectEqualStrings("-foxfox", try apply(arena, &back, "-", source, 7));
    // The two-byte form reaches 32 further than its number.
    const near = [_]u8{ 4 - 1, 0x00, 3 };
    try std.testing.expectEqualStrings("lazy", try apply(arena, &near, "", source, 4));
    // A copy past the source's end, and more than the file's size, are refused.
    try std.testing.expectError(error.Corrupt, apply(arena, &.{ 4 - 1, 0x80 | 31, 4 - 1, 0x80 | 31 }, "", source, 8));
    try std.testing.expectError(error.Corrupt, apply(arena, &.{ 10 - 1, 0x80 | 0 }, "", source, 4));
}

test Patcher {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const english = "Launch all fighters";
    // The patch keeps "Launch all " and adds the rest.
    const patch = try testing.patch(arena, &.{ 11 - 1, 0x80 | 0, 0x80 | 6 - 1 }, "pilots");
    const bytes = try testing.patcher(arena, &.{
        .{ .name = "LANGUAGE.DLL.eng", .kind = .whole, .data = try testing.deflate(arena, english, false), .size = english.len },
        .{ .name = "LANGUAGE.DLL", .kind = .patch, .data = patch, .size = 17 },
    });
    const patcher: Patcher = try .read(arena, bytes);
    try std.testing.expectEqual(2, patcher.files.len);
    try std.testing.expectEqualStrings(english, try patcher.write(arena, patcher.find("language.dll.ENG").?));
    try std.testing.expectEqualStrings("Launch all pilots", try patcher.write(arena, patcher.find("LANGUAGE.DLL").?));
    // A program with no blocks after it, and bytes that are no program, are no patcher.
    try std.testing.expectError(error.NotAPatcher, Patcher.read(arena, try testing.program(arena)));
    var junk = "MZ, and no more of a program".*;
    try std.testing.expectError(error.NotAPatcher, Patcher.read(arena, &junk));
}
