//! `.HOG` archives: the containers holding the game's assets.
//!
//! The format is Electronic Arts' `BIGF`. A 16-byte header is followed by a directory of
//! variable-length entries, then the members themselves, packed back to back with no padding and
//! no alignment. Every field is big-endian, which is unusual for a game built for x86 and is a
//! leftover of the format's console origins.
//!
//! Most members of `resource.hog` are RefPack-compressed; see `refpack.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const layout = @import("layout.zig");
const Big = layout.Big;
const refpack = @import("refpack.zig");

pub const magic = "BIGF";

/// The fixed header.
pub const Header = extern struct {
    magic: [4]u8,
    archive_size: Big(u32),
    entry_count: Big(u32),
    /// Where the directory ends and the first member begins.
    data_offset: Big(u32),

    comptime {
        std.debug.assert(@sizeOf(Header) == 16);
    }
};

/// A directory record's fixed part, which its name follows, up to a NUL.
pub const Record = extern struct {
    offset: Big(u32),
    size: Big(u32),

    comptime {
        std.debug.assert(@sizeOf(Record) == 8);
    }
};

pub const Entry = struct {
    /// Stored name. Members are a flat namespace: no directories, no path separators.
    name: []const u8,
    offset: u32,
    /// Stored size, which is the compressed size for a RefPack member.
    size: u32,
};

pub const OpenError = error{
    NotAHog,
    /// The header's size field disagrees with the file.
    SizeMismatch,
    /// The directory ran out of room before the first member.
    CorruptDirectory,
};

pub const Archive = struct {
    io: Io,
    file: Io.File,
    header: Header,
    entries: []Entry,
    /// Entries the header counts but that hold no valid record. Two of the shipped archives end
    /// their directory with one uninitialized entry (`0xCD` filler, the MSVC debug pattern); the
    /// members themselves form a complete chain without it.
    phantom_entries: usize,

    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Archive {
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);

        var header: Header = undefined;
        if (try file.readPositionalAll(io, std.mem.asBytes(&header), 0) != @sizeOf(Header))
            return error.NotAHog;
        if (!std.mem.eql(u8, &header.magic, magic)) return error.NotAHog;

        const file_size = try file.length(io);
        if (header.archive_size.get() != file_size) return error.SizeMismatch;

        const directory = try gpa.alloc(u8, header.data_offset.get() -| @sizeOf(Header));
        defer gpa.free(directory);
        _ = try file.readPositionalAll(io, directory, @sizeOf(Header));

        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(gpa);

        var pos: usize = 0;
        for (0..header.entry_count.get()) |_| {
            const entry = parseEntry(directory[pos..], @intCast(file_size)) orelse break;
            try entries.append(gpa, .{
                .name = try gpa.dupe(u8, entry.name),
                .offset = entry.offset,
                .size = entry.size,
            });
            pos += entry.encoded_len;
        }
        if (entries.items.len == 0) return error.CorruptDirectory;
        // Read the count before handing the list over: taking the slice empties it.
        const phantom_entries = header.entry_count.get() - entries.items.len;

        return .{
            .io = io,
            .file = file,
            .header = header,
            .entries = try entries.toOwnedSlice(gpa),
            .phantom_entries = phantom_entries,
        };
    }

    pub fn close(archive: *Archive, gpa: Allocator) void {
        for (archive.entries) |entry| gpa.free(entry.name);
        gpa.free(archive.entries);
        archive.file.close(archive.io);
    }

    /// Reads a member exactly as stored, without decompressing it.
    pub fn readRaw(archive: Archive, gpa: Allocator, entry: Entry) ![]u8 {
        const bytes = try gpa.alloc(u8, entry.size);
        errdefer gpa.free(bytes);
        if (try archive.file.readPositionalAll(archive.io, bytes, entry.offset) != bytes.len)
            return error.UnexpectedEnd;
        return bytes;
    }

    /// Reads a member, decompressing it when it is RefPack-compressed.
    pub fn read(archive: Archive, gpa: Allocator, entry: Entry) !Contents {
        const raw = try archive.readRaw(gpa, entry);
        if (!refpack.looksCompressed(raw)) return .{ .bytes = raw, .compressed = false };
        defer gpa.free(raw);
        return .{ .bytes = try refpack.decompressAlloc(gpa, raw), .compressed = true };
    }

    pub const Contents = struct {
        bytes: []u8,
        /// Whether the stored member was RefPack-compressed.
        compressed: bool,

        pub fn deinit(contents: Contents, gpa: Allocator) void {
            gpa.free(contents.bytes);
        }
    };

    /// The size a RefPack member expands to, from its header alone; null for a member stored as it
    /// is, or one too short for the header its flags describe.
    pub fn expandedSize(archive: Archive, entry: Entry) !?u32 {
        var head: [refpack.max_header_len]u8 = undefined;
        const n = try archive.file.readPositionalAll(archive.io, head[0..@min(entry.size, head.len)], entry.offset);
        const header = refpack.readHeader(head[0..n]) catch return null;
        return header.decompressed_size;
    }

    pub fn find(archive: Archive, name: []const u8) ?Entry {
        for (archive.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        }
        return null;
    }

    /// True when the members tile the file exactly, from `data_offset` to the last byte.
    pub fn isContiguous(archive: Archive) bool {
        var expected = archive.header.data_offset.get();
        for (archive.entries) |entry| {
            if (entry.offset != expected) return false;
            expected = entry.offset + entry.size;
        }
        return expected == archive.header.archive_size.get();
    }
};

const ParsedEntry = struct {
    name: []const u8,
    offset: u32,
    size: u32,
    encoded_len: usize,
};

/// Reads one directory record: a `Record`, then a NUL-terminated name. Returns null when the bytes
/// are not a plausible record, which is how the trailing filler is detected.
fn parseEntry(directory: []const u8, file_size: u32) ?ParsedEntry {
    const record = layout.view(Record, directory) catch return null;
    const offset = record.offset.get();
    const size = record.size.get();
    if (offset > file_size or size > file_size - offset) return null;

    const rest = directory[@sizeOf(Record)..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse return null;
    const name = rest[0..end];
    if (!validName(name)) return null;
    return .{ .name = name, .offset = offset, .size = size, .encoded_len = @sizeOf(Record) + end + 1 };
}

/// Whether a directory record holds `name`: one or more bytes of printable ASCII, as `parseEntry`
/// reads a name, and as every shipped archive's names are.
pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (c < 0x20 or c >= 0x7F) return false;
    }
    return true;
}

test parseEntry {
    var directory: [32]u8 = @splat(0);
    (try layout.viewMut(Record, &directory)).* = .{ .offset = .of(0x1000), .size = .of(0x200) };
    @memcpy(directory[@sizeOf(Record)..][0..8], "ship.shp");

    const entry = parseEntry(&directory, 0x10000).?;
    try std.testing.expectEqualStrings("ship.shp", entry.name);
    try std.testing.expectEqual(@as(u32, 0x1000), entry.offset);
    try std.testing.expectEqual(@as(u32, 0x200), entry.size);
    try std.testing.expectEqual(@as(usize, 17), entry.encoded_len);

    // Past the end of the archive, and the uninitialized filler both shipped archives end with.
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry(&directory, 0x100));
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry(&(@as([32]u8, @splat(0xCD))), 0x100000));
}

/// The order `sltool hog pack` gives a folder's files, so that a folder packs the same wherever it
/// is: by their names' bytes.
pub fn nameOrder(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A member to write: its name, and its bytes as they are to be stored.
pub const Member = struct { name: []const u8, data: []const u8 };

pub const BuildError = error{
    /// A name no directory record holds (`validName`).
    BadName,
    /// Past the 4 GiB that the header's and the records' 32-bit sizes and offsets reach.
    TooLarge,
} || Allocator.Error;

/// An archive of `members`, each stored as given and laid out as every shipped archive is: the
/// header, a record and a NUL-terminated name for each member in their order, then their data back
/// to back from `data_offset` to the end of the file (`Archive.isContiguous`), with no trailing
/// filler. Names are not made unique: the shipped archives repeat some, and a lookup takes the
/// first. The caller owns the bytes.
pub fn build(gpa: Allocator, members: []const Member) BuildError![]u8 {
    var data_at: u64 = @sizeOf(Header);
    var data_size: u64 = 0;
    for (members) |member| {
        if (!validName(member.name)) return error.BadName;
        data_at += @sizeOf(Record) + member.name.len + 1;
        data_size += member.data.len;
    }
    if (data_at + data_size > std.math.maxInt(u32)) return error.TooLarge;

    const bytes = try gpa.alloc(u8, @intCast(data_at + data_size));
    errdefer gpa.free(bytes);
    const header: Header = .{
        .magic = magic.*,
        .archive_size = .of(@intCast(bytes.len)),
        .entry_count = .of(@intCast(members.len)),
        .data_offset = .of(@intCast(data_at)),
    };
    @memcpy(bytes[0..@sizeOf(Header)], std.mem.asBytes(&header));
    var entry_at: usize = @sizeOf(Header);
    var datum_at: usize = @intCast(data_at);
    for (members) |member| {
        const record: Record = .{ .offset = .of(@intCast(datum_at)), .size = .of(@intCast(member.data.len)) };
        @memcpy(bytes[entry_at..][0..@sizeOf(Record)], std.mem.asBytes(&record));
        const name_at = entry_at + @sizeOf(Record);
        @memcpy(bytes[name_at..][0..member.name.len], member.name);
        bytes[name_at + member.name.len] = 0;
        entry_at = name_at + member.name.len + 1;
        @memcpy(bytes[datum_at..][0..member.data.len], member.data);
        datum_at += member.data.len;
    }
    return bytes;
}

/// The extensions of the members the game opens where they lie, not through `hog_read_file`
/// (`0x004C7F60`), so that they are stored as they are: Bink's movies, which `hog_locate`
/// (`0x004C83F0`) finds for Bink to open in the archive, and the face films, which
/// `hudmovie_play` (`0x0048D120`) finds with `hog_seek` (`0x004C8370`) and reads from the archive's
/// file where the seek leaves it.
const opened_in_place = [_][]const u8{ ".bik", ".fm8" };

/// Whether the game opens the member `name` where it lies (`opened_in_place`).
pub fn opensInPlace(name: []const u8) bool {
    const extension = std.fs.path.extension(name);
    for (opened_in_place) |candidate| {
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
    }
    return false;
}

/// How `packMember` stores what the game could read as it is.
pub const Packing = enum {
    /// A RefPack stream where one is smaller and the game can expand it in place.
    compress,
    /// As it is (`sltool hog pack --store`), where the game reads it so.
    store,
};

/// How `packMember` stored a member.
pub const Storage = enum {
    /// As bytes the game reads verbatim.
    stored,
    /// As a RefPack stream `packMember` wrote.
    compressed,
    /// As it came, being a stream the game loads.
    already_compressed,
};

pub const Packed = struct {
    /// The bytes to store, which the caller owns.
    bytes: []u8,
    storage: Storage,
};

pub const PackError = error{
    /// The data begins `10 FB`, so the game takes it for a stream, but it is none the game loads in
    /// place, and no stream of what it holds loads either (`refpack.CompressError`).
    Unloadable,
} || Allocator.Error;

/// The bytes to store for the member `name` of `data`, which the game reads back as `data`. With
/// `.compress`, a RefPack stream where one is smaller and the game can expand it in place, and
/// otherwise the data as it is, which the game reads verbatim; with `.store`, the data as it is. A
/// member the game opens in place (`opensInPlace`) is stored as it is, since the game never expands
/// it.
///
/// Data that begins `10 FB` the game takes for a stream whatever the packing, so it goes in only as
/// a stream that expands to its declared size in place (`refpack.loadsInPlace`). Such a stream is
/// kept as it came, as a member extracted as stored is. A stream over the bound, from another tool
/// say, is expanded, and what it expands to packed in its place. Any other data that begins `10 FB`
/// is compressed, having no form the game reads as it is, and where no stream of it loads, the
/// member is `error.Unloadable`.
pub fn packMember(gpa: Allocator, compressor: *refpack.Compressor, packing: Packing, name: []const u8, data: []const u8) PackError!Packed {
    if (opensInPlace(name)) return .{ .bytes = try gpa.dupe(u8, data), .storage = .stored };
    if (!refpack.gameExpands(data)) return packContent(gpa, compressor, packing, data);
    if (refpack.loadsInPlace(data)) return .{ .bytes = try gpa.dupe(u8, data), .storage = .already_compressed };
    const expanded = refpack.decompressAlloc(gpa, data) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.BadSignature, error.UnexpectedEnd, error.BadReference, error.SizeMismatch => {
            return packContent(gpa, compressor, packing, data);
        },
    };
    defer gpa.free(expanded);
    return packContent(gpa, compressor, packing, expanded);
}

/// `data` as the game is to read it, for a member it reads through `hog_read_file`: as it is, or
/// with `.compress` a RefPack stream where one is smaller and loads.
fn packContent(gpa: Allocator, compressor: *refpack.Compressor, packing: Packing, data: []const u8) PackError!Packed {
    const needs_stream = refpack.gameExpands(data);
    if (packing == .compress or needs_stream) {
        if (compressor.compress(gpa, data)) |stream| {
            if (needs_stream or stream.len < data.len) return .{ .bytes = stream, .storage = .compressed };
            gpa.free(stream);
        } else |err| switch (err) {
            error.TooLarge, error.NotInPlace => if (needs_stream) return error.Unloadable,
            error.OutOfMemory => |e| return e,
        }
    }
    return .{ .bytes = try gpa.dupe(u8, data), .storage = .stored };
}

/// Writes archives, for the tests of code that reads them.
pub const testing = struct {
    /// Writes an archive of `members`, as `build` makes it, to `path` in `dir`.
    pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, members: []const Member) !void {
        const bytes = try build(gpa, members);
        defer gpa.free(bytes);
        try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
    }
};

test Archive {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `abcdabcdabcd`, RefPack-compressed as the game stores its members.
    const compressed = [_]u8{ 0x10, 0xFB, 0x00, 0x00, 0x0C, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC };
    try testing.write(gpa, io, tmp.dir, "test.hog", &.{
        .{ .name = "Ship.SHP", .data = "hello" },
        .{ .name = "mission.dte", .data = &compressed },
    });
    var archive: Archive = try .open(gpa, io, tmp.dir, "test.hog");
    defer archive.close(gpa);
    try std.testing.expectEqual(2, archive.entries.len);
    try std.testing.expectEqual(0, archive.phantom_entries);
    try std.testing.expect(archive.isContiguous());

    // Names match whatever their case.
    const ship = archive.find("ship.shp").?;
    try std.testing.expectEqual(null, archive.find("missing.shp"));
    const stored = try archive.read(gpa, ship);
    defer stored.deinit(gpa);
    try std.testing.expectEqualStrings("hello", stored.bytes);
    try std.testing.expect(!stored.compressed);
    try std.testing.expectEqual(null, try archive.expandedSize(ship));

    const mission = archive.find("MISSION.DTE").?;
    const expanded = try archive.read(gpa, mission);
    defer expanded.deinit(gpa);
    try std.testing.expectEqualStrings("abcdabcdabcd", expanded.bytes);
    try std.testing.expect(expanded.compressed);
    try std.testing.expectEqual(12, (try archive.expandedSize(mission)).?);
    const raw = try archive.readRaw(gpa, mission);
    defer gpa.free(raw);
    try std.testing.expectEqualSlices(u8, &compressed, raw);

    // A member out of its place breaks the chain.
    archive.entries[1].offset += 1;
    try std.testing.expect(!archive.isContiguous());
}

test "a header counting entries the directory lacks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bytes = try build(gpa, &.{.{ .name = "a.tga", .data = "x" }});
    defer gpa.free(bytes);
    const header = try layout.viewMut(Header, bytes);
    header.entry_count = .of(header.entry_count.get() + 1);
    try tmp.dir.writeFile(io, .{ .sub_path = "phantom.hog", .data = bytes });
    var archive: Archive = try .open(gpa, io, tmp.dir, "phantom.hog");
    defer archive.close(gpa);
    try std.testing.expectEqual(1, archive.entries.len);
    try std.testing.expectEqual(1, archive.phantom_entries);

    // Not an archive, and one whose header disagrees with the file's size.
    header.magic = "BIGH".*;
    try tmp.dir.writeFile(io, .{ .sub_path = "other.hog", .data = bytes });
    try std.testing.expectError(error.NotAHog, Archive.open(gpa, io, tmp.dir, "other.hog"));
    header.magic = magic.*;
    try tmp.dir.writeFile(io, .{ .sub_path = "short.hog", .data = bytes[0 .. bytes.len - 1] });
    try std.testing.expectError(error.SizeMismatch, Archive.open(gpa, io, tmp.dir, "short.hog"));
}

test build {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Names with spaces, a name given twice as the shipped archives give some, and an empty member.
    const members = [_]Member{
        .{ .name = "Boridin gun dest.SHP", .data = "model" },
        .{ .name = "interpal.tga", .data = "first" },
        .{ .name = "interpal.tga", .data = "second, longer" },
        .{ .name = "empty.bin", .data = "" },
    };
    const bytes = try build(gpa, &members);
    defer gpa.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "built.hog", .data = bytes });

    var archive: Archive = try .open(gpa, io, tmp.dir, "built.hog");
    defer archive.close(gpa);
    try std.testing.expectEqual(members.len, archive.entries.len);
    try std.testing.expectEqual(0, archive.phantom_entries);
    try std.testing.expect(archive.isContiguous());
    try std.testing.expectEqual(bytes.len, archive.header.archive_size.get());
    for (members, archive.entries) |member, entry| {
        try std.testing.expectEqualStrings(member.name, entry.name);
        const stored = try archive.readRaw(gpa, entry);
        defer gpa.free(stored);
        try std.testing.expectEqualSlices(u8, member.data, stored);
    }
    // A lookup takes the first of a repeated name.
    const first = try archive.readRaw(gpa, archive.find("INTERPAL.TGA").?);
    defer gpa.free(first);
    try std.testing.expectEqualStrings("first", first);

    // No member at all is a header alone.
    const none = try build(gpa, &.{});
    defer gpa.free(none);
    try std.testing.expectEqual(@sizeOf(Header), none.len);

    for ([_][]const u8{ "", "tab\there", "caf\xC3\xA9.tga", "line\n" }) |name| {
        try std.testing.expectError(error.BadName, build(gpa, &.{.{ .name = name, .data = "x" }}));
    }
}

test opensInPlace {
    try std.testing.expect(opensInPlace("New_intro.bik"));
    try std.testing.expect(opensInPlace("static.FM8"));
    try std.testing.expect(!opensInPlace("mission1.dte"));
    try std.testing.expect(!opensInPlace("bik"));
}

test packMember {
    const gpa = std.testing.allocator;
    var compressor: refpack.Compressor = try .init(gpa);
    defer compressor.deinit(gpa);
    const text = "The quick brown fox jumps over the lazy dog. " ** 20;

    // Worth packing, and read back whole.
    const packed_text = try packMember(gpa, &compressor, .compress, "readme.txt", text);
    defer gpa.free(packed_text.bytes);
    try std.testing.expectEqual(Storage.compressed, packed_text.storage);
    try std.testing.expect(packed_text.bytes.len < text.len);
    const expanded = try refpack.decompressAlloc(gpa, packed_text.bytes);
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings(text, expanded);

    // A movie is stored as it is, however well it would pack.
    const movie = try packMember(gpa, &compressor, .compress, "warty_.bik", text);
    defer gpa.free(movie.bytes);
    try std.testing.expectEqual(Storage.stored, movie.storage);
    try std.testing.expectEqualStrings(text, movie.bytes);

    // A member already packed is kept as it is, not packed twice.
    const again = try packMember(gpa, &compressor, .compress, "readme.txt", packed_text.bytes);
    defer gpa.free(again.bytes);
    try std.testing.expectEqual(Storage.already_compressed, again.storage);
    try std.testing.expectEqualSlices(u8, packed_text.bytes, again.bytes);

    // Noise does not shrink, so it is stored; and nothing is packed with `.store`.
    var prng: std.Random.DefaultPrng = .init(1);
    var noise: [500]u8 = undefined;
    prng.random().bytes(&noise);
    const noisy = try packMember(gpa, &compressor, .compress, "noise.bin", &noise);
    defer gpa.free(noisy.bytes);
    try std.testing.expectEqual(Storage.stored, noisy.storage);
    const kept = try packMember(gpa, &compressor, .store, "readme.txt", text);
    defer gpa.free(kept.bytes);
    try std.testing.expectEqual(Storage.stored, kept.storage);
}

/// Checks that the game reads `content` from a member stored as `stored`: it expands one that begins
/// `10 FB`, which must then load in place, and reads any other verbatim.
fn expectLoads(stored: []const u8, content: []const u8) !void {
    const gpa = std.testing.allocator;
    if (!refpack.gameExpands(stored)) return std.testing.expectEqualSlices(u8, content, stored);
    try std.testing.expect(try refpack.inPlaceExcess(stored) <= @as(i64, refpack.in_place_slack));
    const expanded = try refpack.decompressAlloc(gpa, stored);
    defer gpa.free(expanded);
    try std.testing.expectEqualSlices(u8, content, expanded);
}

test "a member that begins 10 FB is kept only where the game loads it" {
    const gpa = std.testing.allocator;
    var compressor: refpack.Compressor = try .init(gpa);
    defer compressor.deinit(gpa);

    // A stream within the bound, as `sltool hog extract --raw` gives one.
    const within = try compressor.compress(gpa, "The quick brown fox jumps over the lazy dog. " ** 20);
    defer gpa.free(within);
    // A stream past it: literals alone, one byte more than the slack allows.
    const zeros = try gpa.alloc(u8, refpack.testing.largest_in_place + 1);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    const past = try refpack.testing.literals(gpa, zeros);
    defer gpa.free(past);
    try std.testing.expect(try refpack.inPlaceExcess(past) > @as(i64, refpack.in_place_slack));
    // Text that only begins as a stream does, a stream whose commands give a byte fewer than its
    // header declares, and one whose match reaches before the start of the output.
    const not_stream = "\x10\xFBnot a stream, only text that begins as one does";
    const short_by_one = [_]u8{ 0x10, 0xFB, 0x00, 0x00, 0x0D, 0xE0, 'a', 'b', 'c', 'd', 0x14, 0x03, 0xFC };
    const reaches_back = [_]u8{ 0x10, 0xFB, 0x00, 0x00, 0x08, 0x14, 0x03, 0xFC };

    // With and without `--store`.
    for ([_]Packing{ .compress, .store }) |packing| {
        const kept = try packMember(gpa, &compressor, packing, "mission1.dte", within);
        defer gpa.free(kept.bytes);
        try std.testing.expectEqual(Storage.already_compressed, kept.storage);
        try std.testing.expectEqualSlices(u8, within, kept.bytes);

        // Past the bound, what it expands to goes in instead.
        const repacked = try packMember(gpa, &compressor, packing, "big.tga", past);
        defer gpa.free(repacked.bytes);
        try std.testing.expect(repacked.storage != .already_compressed);
        try expectLoads(repacked.bytes, zeros);

        // Not a stream the game loads, and not one to expand: the file itself is compressed, since
        // the game would take it for a stream as it is.
        for ([_][]const u8{ not_stream, &short_by_one, &reaches_back }) |data| {
            const itself = try packMember(gpa, &compressor, packing, "odd.bin", data);
            defer gpa.free(itself.bytes);
            try std.testing.expectEqual(Storage.compressed, itself.storage);
            try expectLoads(itself.bytes, data);
        }
    }
}

test "a movie that begins 10 FB is stored as it is" {
    const gpa = std.testing.allocator;
    var compressor: refpack.Compressor = try .init(gpa);
    defer compressor.deinit(gpa);
    // Bink opens a movie where it lies, and never expands it.
    const movie = "\x10\xFBnot a stream, and never expanded";
    for ([_]Packing{ .compress, .store }) |packing| {
        const stored = try packMember(gpa, &compressor, packing, "odd.bik", movie);
        defer gpa.free(stored.bytes);
        try std.testing.expectEqual(Storage.stored, stored.storage);
        try std.testing.expectEqualSlices(u8, movie, stored.bytes);
    }
}

test "a member that begins 10 FB and loads no way is refused" {
    const gpa = std.testing.allocator;
    var compressor: refpack.Compressor = try .init(gpa);
    defer compressor.deinit(gpa);
    // Not a stream, and more than any stream's header holds.
    const huge = try gpa.alloc(u8, refpack.max_size + 1);
    defer gpa.free(huge);
    @memset(huge, 0);
    huge[0] = 0x10;
    huge[1] = 0xFB;
    for ([_]Packing{ .compress, .store }) |packing| {
        try std.testing.expectError(error.Unloadable, packMember(gpa, &compressor, packing, "huge.bin", huge));
    }
}

test "header reads big-endian fields" {
    const header: Header = .{
        .magic = magic.*,
        .archive_size = .{ .bytes = .{ 0x03, 0x5B, 0x92, 0x50 } },
        .entry_count = .{ .bytes = .{ 0x00, 0x00, 0x11, 0x11 } },
        .data_offset = .{ .bytes = .{ 0x00, 0x01, 0x99, 0x68 } },
    };
    try std.testing.expectEqual(@as(u32, 56332880), header.archive_size.get());
    try std.testing.expectEqual(@as(u32, 4369), header.entry_count.get());
    try std.testing.expectEqual(@as(u32, 104808), header.data_offset.get());
}
