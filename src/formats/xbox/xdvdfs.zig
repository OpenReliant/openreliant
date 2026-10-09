//! XDVDFS, the filesystem of Xbox discs: a volume descriptor at the volume's sector 32, and folders
//! as binary trees of entries sorted by name. An image that `extract-xiso` writes holds the volume
//! alone, as 2048-byte blocks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const cdimage = @import("../cdimage.zig");
const iso9660 = @import("../iso9660.zig");
const layout = @import("../layout.zig");

const block_size = cdimage.block_size;

/// The volume descriptor's sector.
pub const descriptor_sector = 32;

pub const Descriptor = extern struct {
    magic: [20]u8,
    /// The root folder's first sector and size in bytes.
    root_sector: u32,
    root_size: u32,

    pub const xbox = "MICROSOFT*XBOX*MEDIA";

    comptime {
        assert(@offsetOf(Descriptor, "root_sector") == 20);
    }
};

/// An entry of a folder: a node of its tree, then the name. Entries are 4-byte aligned.
pub const Record = extern struct {
    /// The subtrees' offsets in the folder, in 4-byte units; 0 or `none` for none.
    left: u16,
    right: u16,
    /// The file's or folder's first sector, and its size in bytes.
    sector: u32 align(2),
    size: u32 align(2),
    attributes: Attributes,
    name_length: u8,

    /// The name's offset in the entry, right after the record.
    pub const name_offset = @sizeOf(Record);
    /// A subtree's offset where there is none, and the filler past a folder's last entry.
    pub const none = 0xFFFF;

    pub const Attributes = packed struct(u8) {
        read_only: bool,
        hidden: bool,
        system: bool,
        _unknown_3: bool,
        directory: bool,
        archive: bool,
        _unknown_6: bool,
        normal: bool,
    };

    comptime {
        assert(@offsetOf(Record, "sector") == 4);
        assert(@offsetOf(Record, "name_length") == 13);
        assert(@sizeOf(Record) == 14);
    }
};

/// A file or folder, as `iso9660.Entry` has one, less its time.
pub const Entry = struct {
    name: []const u8,
    kind: iso9660.Entry.Kind,
    extent: iso9660.Extent,
};

pub const Walker = iso9660.WalkerOf(Volume, Entry);

pub const Volume = struct {
    image: cdimage.Image,
    descriptor: Descriptor,

    /// The volume on `image`; `error.NotXdvdfs` where it holds none.
    pub fn open(image: cdimage.Image) !Volume {
        var block: [block_size]u8 = undefined;
        image.readBlocks(image.first_lba + descriptor_sector, &block) catch |err| switch (err) {
            error.EndOfImage => return error.NotXdvdfs,
            else => |e| return e,
        };
        const descriptor = (try layout.view(Descriptor, &block)).*;
        if (!std.mem.eql(u8, &descriptor.magic, Descriptor.xbox)) return error.NotXdvdfs;
        return .{ .image = image, .descriptor = descriptor };
    }

    pub fn root(volume: *const Volume) iso9660.Extent {
        return .{ .lba = volume.descriptor.root_sector, .len = volume.descriptor.root_size };
    }

    /// The entries of the folder at `dir`, in the order of its tree: sorted by name.
    pub fn readDirectory(volume: *const Volume, arena: Allocator, dir: iso9660.Extent) ![]Entry {
        const bytes = try arena.alloc(u8, std.mem.alignForward(usize, dir.len, block_size));
        try volume.image.readBlocks(dir.lba, bytes);
        return list(arena, bytes[0..dir.len]);
    }

    pub fn walk(volume: *const Volume, arena: Allocator) !Walker {
        return .init(volume, arena);
    }
};

/// The entries of a folder's bytes, in the order of its tree. A node is visited once, so a tree
/// that loops back ends rather than repeats.
pub fn list(arena: Allocator, folder: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    if (folder.len == 0) return entries.items;
    const visited = try arena.alloc(bool, folder.len / 4);
    @memset(visited, false);

    // An in-order walk: down the left subtrees, then each node and its right subtree.
    var stack: std.ArrayList(usize) = .empty;
    var at: ?usize = 0;
    while (true) {
        while (at) |offset| {
            const record = try recordAt(folder, offset);
            if (visited[offset / 4]) return error.CorruptDirectory;
            visited[offset / 4] = true;
            try stack.append(arena, offset);
            at = subtree(record.left);
        }
        const offset = stack.pop() orelse break;
        const record = try recordAt(folder, offset);
        // An empty folder holds one entry of filler.
        if (record.left == Record.none and record.right == Record.none and record.sector == std.math.maxInt(u32)) break;
        const name = folder[offset + Record.name_offset ..][0..record.name_length];
        if (!isName(name)) return error.CorruptDirectory;
        try entries.append(arena, .{
            .name = name,
            .kind = if (record.attributes.directory) .directory else .file,
            .extent = .{ .lba = record.sector, .len = record.size },
        });
        at = subtree(record.right);
    }
    return entries.items;
}

/// The entry at `offset` in a folder, checked to lie within it, its name included.
fn recordAt(folder: []const u8, offset: usize) !*align(1) const Record {
    if (offset % 4 != 0 or offset >= folder.len) return error.CorruptDirectory;
    const record = layout.view(Record, folder[offset..]) catch return error.CorruptDirectory;
    if (folder.len - offset < Record.name_offset + @as(usize, record.name_length)) return error.CorruptDirectory;
    return record;
}

/// The byte offset of a subtree, or null for none.
fn subtree(link: u16) ?usize {
    return if (link == 0 or link == Record.none) null else @as(usize, link) * 4;
}

/// Whether `name` can name a file under a folder: not empty, no path separators, and not `.` or
/// `..`.
fn isName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.findAny(u8, name, "/\\") == null;
}

/// Builds folders, for tests.
pub const testing = struct {
    /// Writes an entry at `offset` in `folder`.
    pub fn put(folder: []u8, offset: usize, left: u16, right: u16, name: []const u8, extent: iso9660.Extent, kind: iso9660.Entry.Kind) void {
        var attributes: Record.Attributes = @bitCast(@as(u8, 0));
        attributes.directory = kind == .directory;
        const record: Record = .{ .left = left, .right = right, .sector = extent.lba, .size = extent.len, .attributes = attributes, .name_length = @intCast(name.len) };
        @memcpy(folder[offset..][0..Record.name_offset], std.mem.asBytes(&record)[0..Record.name_offset]);
        @memcpy(folder[offset + Record.name_offset ..][0..name.len], name);
    }
};

test list {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // A root of "M" with "A" to its left and "Z" to its right, at 4-byte units 0, 6 and 12.
    var folder: [72]u8 = @splat(0xFF);
    testing.put(&folder, 0, 6, 12, "M", .{ .lba = 30, .len = 5 }, .file);
    testing.put(&folder, 24, 0, 0, "A", .{ .lba = 31, .len = block_size }, .directory);
    testing.put(&folder, 48, 0, 0, "Z", .{ .lba = 32, .len = 7 }, .file);
    const entries = try list(arena.allocator(), &folder);
    try std.testing.expectEqual(3, entries.len);
    for (entries, [_][]const u8{ "A", "M", "Z" }) |entry, name| try std.testing.expectEqualStrings(name, entry.name);
    try std.testing.expectEqual(.directory, entries[0].kind);
    try std.testing.expectEqual(32, entries[2].extent.lba);

    // A tree that loops, "A" to "Z" and back, and a name that climbs out of its folder.
    var looped = folder;
    std.mem.writeInt(u16, looped[24..26], 12, .little);
    std.mem.writeInt(u16, looped[48..50], 6, .little);
    try std.testing.expectError(error.CorruptDirectory, list(arena.allocator(), &looped));
    // An empty folder: one entry of filler.
    const empty: [2048]u8 = @splat(0xFF);
    try std.testing.expectEqual(0, (try list(arena.allocator(), &empty)).len);
    var climbing: [24]u8 = @splat(0xFF);
    testing.put(&climbing, 0, 0, 0, "..", .{ .lba = 30, .len = 5 }, .directory);
    try std.testing.expectError(error.CorruptDirectory, list(arena.allocator(), &climbing));
}

test Volume {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var blocks: [36][block_size]u8 = @splat(@splat(0));
    const descriptor: Descriptor = .{ .magic = Descriptor.xbox.*, .root_sector = 33, .root_size = block_size };
    @memcpy(blocks[descriptor_sector][0..@sizeOf(Descriptor)], std.mem.asBytes(&descriptor));
    @memset(&blocks[33], 0xFF);
    @memset(&blocks[34], 0xFF);
    testing.put(&blocks[33], 0, 0, 0, "MISSIONS", .{ .lba = 34, .len = block_size }, .directory);
    testing.put(&blocks[34], 0, 0, 0, "M1.DTE", .{ .lba = 35, .len = 3 }, .file);

    const image: cdimage.Image = try .init(.{ .memory = std.mem.asBytes(&blocks) });
    const volume: Volume = try .open(image);
    var walker = try volume.walk(arena.allocator());
    try std.testing.expectEqualStrings("MISSIONS", (try walker.next()).?.path);
    const file = (try walker.next()).?;
    try std.testing.expectEqualStrings("MISSIONS/M1.DTE", file.path);
    try std.testing.expectEqual(35, file.entry.extent.lba);
    try std.testing.expectEqual(null, try walker.next());

    const blank: [33 * block_size]u8 = @splat(0);
    try std.testing.expectError(error.NotXdvdfs, Volume.open(try .init(.{ .memory = &blank })));
}
