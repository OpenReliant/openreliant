//! Battlestar Galactica's `.hxb` archives, Warthog's `WART3.00`: a header, a table of entries, the
//! members back to back, and their names at the end. A member is stored as it is, or compressed
//! with RefPack (`refpack.zig`) in chunks of up to `chunk_size` bytes, each a length and a RefPack
//! stream without the usual header. Each entry keeps a checksum of the member's bytes.
//!
//! [Battlestar Galactica](../../../../docs/games/battlestar-galactica.md#archives) describes the
//! format and what the game's archives hold.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const layout = @import("../../layout.zig");
const refpack = @import("../../refpack.zig");

pub const magic = "WART3.00";

pub const Header = extern struct {
    magic: [8]u8,
    count: u32,
    /// Where the names start, which is also where the members end.
    names_offset: u32,
    names_size: u32,

    comptime {
        assert(@sizeOf(Header) == 20);
    }
};

/// A member's entry. The entries follow the header, and the members follow the entries.
pub const Entry = extern struct {
    /// Where the member starts in the archive.
    offset: u32,
    /// The bytes the compressed member takes, or 0 for a member stored as it is.
    stored_size: u32,
    /// Its size once unpacked.
    size: u32,
    /// The checksum of its unpacked bytes (`checksum`).
    checksum: u32,
    /// Where its name starts in the names. Copies of a member share one name.
    name_offset: u32,

    pub fn compressed(entry: Entry) bool {
        return entry.stored_size != 0;
    }

    /// The bytes the member takes in the archive.
    pub fn storedSize(entry: Entry) u32 {
        return if (entry.compressed()) entry.stored_size else entry.size;
    }

    comptime {
        assert(@sizeOf(Entry) == 20);
    }
};

/// The most a compressed member's chunk unpacks to. Each chunk's stream unpacks on its own.
pub const chunk_size = 128 * 1024;

/// A chunk's length, before its stream.
const ChunkLength = u32;

/// A member's checksum: the CRC-32 of its unpacked bytes, without the final inversion that the
/// usual CRC-32 (zlib's) applies.
pub fn checksum(data: []const u8) u32 {
    return ~std.hash.Crc32.hash(data);
}

pub const Error = error{
    NotAnArchive,
    /// An entry, a name or a chunk runs past its room.
    Truncated,
    /// A name that isn't a relative path, such as one with a `..` part.
    BadName,
    /// A chunk that unpacks to the wrong size, or chunks that don't fill the member.
    BadChunk,
    BadChecksum,
} || refpack.Error;

pub const Archive = struct {
    bytes: []const u8,
    entries: []align(1) const Entry,
    names: []const u8,

    pub fn parse(bytes: []const u8) Error!Archive {
        const header = layout.view(Header, bytes) catch return error.NotAnArchive;
        if (!std.mem.eql(u8, &header.magic, magic)) return error.NotAnArchive;
        const entries = layout.array(Entry, bytes[@sizeOf(Header)..], header.count) catch return error.Truncated;
        const names_end = @as(u64, header.names_offset) + header.names_size;
        if (names_end > bytes.len) return error.Truncated;
        return .{
            .bytes = bytes,
            .entries = entries,
            .names = bytes[header.names_offset..][0..header.names_size],
        };
    }

    /// The name of `entry`: a relative path with forward slashes, such as
    /// `models/shv1vi00/shv1vi00.mdl`.
    pub fn name(archive: Archive, entry: Entry) Error![]const u8 {
        if (entry.name_offset >= archive.names.len) return error.Truncated;
        const rest = archive.names[entry.name_offset..];
        const end = std.mem.findScalar(u8, rest, 0) orelse return error.Truncated;
        const found = rest[0..end];
        if (!isRelativePath(found)) return error.BadName;
        return found;
    }

    /// The member's bytes as the archive stores them.
    pub fn stored(archive: Archive, entry: Entry) Error![]const u8 {
        if (@as(u64, entry.offset) + entry.storedSize() > archive.bytes.len) return error.Truncated;
        return archive.bytes[entry.offset..][0..entry.storedSize()];
    }

    /// Unpacks the member into `out`, which holds `entry.size` bytes, and checks its checksum.
    pub fn unpackInto(archive: Archive, entry: Entry, out: []u8) Error!void {
        assert(out.len == entry.size);
        const bytes = try archive.stored(entry);
        if (entry.compressed()) try unchunk(bytes, out) else @memcpy(out, bytes);
        if (checksum(out) != entry.checksum) return error.BadChecksum;
    }

    /// The member's bytes, unpacked and checked. The caller owns them.
    pub fn unpackAlloc(archive: Archive, gpa: Allocator, entry: Entry) (Error || Allocator.Error)![]u8 {
        const out = try gpa.alloc(u8, entry.size);
        errdefer gpa.free(out);
        try archive.unpackInto(entry, out);
        return out;
    }
};

/// Unpacks a compressed member's chunks, `bytes`, into `out`: each chunk fills `chunk_size` bytes
/// of it, the last what is left.
fn unchunk(bytes: []const u8, out: []u8) Error!void {
    var at: usize = 0;
    var written: usize = 0;
    while (written < out.len) {
        if (bytes.len - at < @sizeOf(ChunkLength)) return error.Truncated;
        const length = std.mem.readInt(ChunkLength, bytes[at..][0..@sizeOf(ChunkLength)], .little);
        at += @sizeOf(ChunkLength);
        if (bytes.len - at < length) return error.Truncated;
        const part = out[written..][0..@min(chunk_size, out.len - written)];
        if (try refpack.decompressInto(part, bytes[at..][0..length]) != part.len) return error.BadChunk;
        at += length;
        written += part.len;
    }
    if (at != bytes.len) return error.BadChunk;
}

/// Whether `path` names a file under the folder it is unpacked into: not empty, not absolute, and
/// with no empty, `.` or `..` part.
fn isRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (std.mem.findScalar(u8, part, '\\') != null) return false;
    }
    return true;
}

pub const testing = struct {
    pub const Member = struct {
        name: []const u8,
        data: []const u8,
        /// Whether it is compressed rather than stored as it is.
        compressed: bool = true,
    };

    /// An archive of `members`, in order. Members with the same name share it, as the game's copies
    /// of a member do.
    pub fn build(gpa: Allocator, members: []const Member) (refpack.CompressError || Allocator.Error)![]u8 {
        var compressor: refpack.Compressor = try .init(gpa);
        defer compressor.deinit(gpa);

        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(gpa);

        const data_start = @sizeOf(Header) + members.len * @sizeOf(Entry);
        for (members, 0..) |member, index| {
            const offset: u32 = @intCast(data_start + data.items.len);
            if (member.compressed) try chunks(gpa, &compressor, &data, member.data) else try data.appendSlice(gpa, member.data);
            const name_offset = for (members[0..index], entries.items) |earlier, entry| {
                if (std.mem.eql(u8, earlier.name, member.name)) break entry.name_offset;
            } else offset: {
                const at: u32 = @intCast(names.items.len);
                try names.appendSlice(gpa, member.name);
                try names.append(gpa, 0);
                break :offset at;
            };
            try entries.append(gpa, .{
                .offset = offset,
                .stored_size = if (member.compressed) @intCast(data_start + data.items.len - offset) else 0,
                .size = @intCast(member.data.len),
                .checksum = checksum(member.data),
                .name_offset = name_offset,
            });
        }

        const header: Header = .{
            .magic = magic.*,
            .count = @intCast(members.len),
            .names_offset = @intCast(data_start + data.items.len),
            .names_size = @intCast(names.items.len),
        };
        return std.mem.concat(gpa, u8, &.{ std.mem.asBytes(&header), std.mem.sliceAsBytes(entries.items), data.items, names.items });
    }

    /// Appends `bytes` to `out` as a compressed member's chunks.
    fn chunks(gpa: Allocator, compressor: *refpack.Compressor, out: *std.ArrayList(u8), bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len != 0) {
            const part = rest[0..@min(chunk_size, rest.len)];
            // The compressor writes the shortest header, which the archives leave out.
            const stream = try compressor.compressApart(gpa, part);
            defer gpa.free(stream);
            const commands = stream[refpack.min_header_len..];
            var length: [@sizeOf(ChunkLength)]u8 = undefined;
            std.mem.writeInt(ChunkLength, &length, @intCast(commands.len), .little);
            try out.appendSlice(gpa, &length);
            try out.appendSlice(gpa, commands);
            rest = rest[part.len..];
        }
    }
};

test checksum {
    // The standard CRC-32 of "123456789" is 0xCBF43926; the archives keep it uninverted.
    try std.testing.expectEqual(~@as(u32, 0xCBF43926), checksum("123456789"));
}

test Archive {
    const gpa = std.testing.allocator;
    // More than a chunk, so that it takes two.
    const long = try gpa.alloc(u8, chunk_size + 1000);
    defer gpa.free(long);
    for (long, 0..) |*byte, i| byte.* = @truncate(i *% 7 / 5);
    const text = "level\r\n{\r\n\tname({A0GAGA00})\r\n}\r\n";

    const bytes = try testing.build(gpa, &.{
        .{ .name = "models/a0gaga00/a0gaga00c1_body19shape.bmsh", .data = long },
        .{ .name = "levels/a0gaga00.lvl", .data = text },
        .{ .name = "sfx/hud/hud029.bwav", .data = "RIFF", .compressed = false },
        .{ .name = "levels/a0gaga00.lvl", .data = text },
    });
    defer gpa.free(bytes);
    const archive: Archive = try .parse(bytes);
    try std.testing.expectEqual(4, archive.entries.len);

    // The long member takes two chunks, and unpacks whole.
    const first = archive.entries[0];
    try std.testing.expect(first.compressed());
    const unpacked = try archive.unpackAlloc(gpa, first);
    defer gpa.free(unpacked);
    try std.testing.expectEqualSlices(u8, long, unpacked);

    // A member stored as it is takes its size, and the next member starts right after it.
    const stored = archive.entries[2];
    try std.testing.expect(!stored.compressed());
    try std.testing.expectEqual(stored.offset + stored.size, archive.entries[3].offset);
    try std.testing.expectEqualStrings("sfx/hud/hud029.bwav", try archive.name(stored));

    // A copy shares its name with the first.
    try std.testing.expectEqual(archive.entries[1].name_offset, archive.entries[3].name_offset);
    try std.testing.expectEqualStrings("levels/a0gaga00.lvl", try archive.name(archive.entries[3]));
    var copy: [text.len]u8 = undefined;
    try archive.unpackInto(archive.entries[3], &copy);
    try std.testing.expectEqualStrings(text, &copy);

    // A member whose bytes no longer match its checksum is refused.
    const changed = try gpa.dupe(u8, bytes);
    defer gpa.free(changed);
    changed[stored.offset] ^= 1;
    var sound: [4]u8 = undefined;
    try std.testing.expectError(error.BadChecksum, (try Archive.parse(changed)).unpackInto(stored, &sound));

    try std.testing.expectError(error.NotAnArchive, Archive.parse("WART2.00"));
}

test isRelativePath {
    try std.testing.expect(isRelativePath("models/textures/sh_galactica_damage.btga"));
    try std.testing.expect(isRelativePath("gfx/asteroid 01.btga"));
    try std.testing.expect(!isRelativePath(""));
    try std.testing.expect(!isRelativePath("/etc/passwd"));
    try std.testing.expect(!isRelativePath("models/../../outside"));
    try std.testing.expect(!isRelativePath("models//a.mdl"));
    try std.testing.expect(!isRelativePath("models\\a.mdl"));
}
