//! `STARTREK.RES`, Star Trek: Invasion's archive: the game's models, missions, pictures, sounds and
//! films in one file on its disc. The archive starts with an index of 8-byte slots: the sector a
//! file starts at, counted from the start of the archive, and its size in bytes. A slot of size 0
//! is empty. The first slot's file starts right after the index, so its sector is the index's
//! length in sectors.
//!
//! The archive doesn't name its files. The executable lists their names in slot order, as a table
//! of pointers to strings such as `TRK\KJ_FA.TRK` (`names`).
//!
//! Most files are logical blocks. A film or a piece of music also holds Form 2 sectors of streamed
//! audio, and its size counts whole Mode 2 sectors (`cdimage.mode2_size` bytes each) rather than
//! logical blocks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;

const cdimage = @import("../../cdimage.zig");
const iso9660 = @import("../../iso9660.zig");
const layout = @import("../../layout.zig");
const exe = @import("../../playstation/exe.zig");

/// The archive's name on the disc.
pub const file_name = "STARTREK.RES";

/// The longest index this reads, in sectors: a sanity check on the first slot.
const most_index_sectors = 64;

/// The longest name of a file.
const longest_name = 63;

/// One slot of the index.
pub const Slot = extern struct {
    /// The sector the file starts at, from the start of the archive.
    sector: u32,
    /// The file's size in bytes, or in whole Mode 2 sectors' bytes for a streamed file.
    size: u32,

    pub fn isUsed(slot: Slot) bool {
        return slot.size != 0;
    }

    comptime {
        assert(@sizeOf(Slot) == 8);
    }
};

pub const Error = error{ NoSystemCnf, NoExecutable, NoArchive, BadIndex };

/// The archive on Star Trek: Invasion's disc, with its files' names.
pub const Archive = struct {
    image: cdimage.Image,
    /// The archive's first sector on the disc.
    start: u32,
    slots: []align(1) const Slot,
    /// The files' names, in slot order, as the executable lists them.
    names: []const []const u8,

    /// The archive on the disc `volume` reads, and the names that the executable the disc starts
    /// gives its files.
    pub fn open(arena: Allocator, volume: *const iso9660.Volume) !Archive {
        const cnf = try volume.findFile(arena, exe.system_cnf) orelse return error.NoSystemCnf;
        const boot = try exe.bootPath(arena, try volume.readFile(arena, cnf.extent)) orelse return error.NoExecutable;
        const program = try volume.findFile(arena, boot) orelse return error.NoExecutable;
        const executable: exe.Executable = try .parse(try volume.readFile(arena, program.extent));
        const archive = try volume.findFile(arena, file_name) orelse return error.NoArchive;

        // The first slot's sector is the index's length in sectors.
        var first: [cdimage.block_size]u8 = undefined;
        try volume.image.readBlocks(archive.extent.lba, &first);
        const index_sectors = (try layout.view(Slot, &first)).sector;
        if (index_sectors == 0 or index_sectors > most_index_sectors) return error.BadIndex;
        const index = try arena.alloc(u8, index_sectors * cdimage.block_size);
        try volume.image.readBlocks(archive.extent.lba, index);

        return .{
            .image = volume.image,
            .start = archive.extent.lba,
            .slots = try layout.array(Slot, index, index.len / @sizeOf(Slot)),
            .names = try names(arena, executable),
        };
    }

    /// The file in `slot`; null for an empty slot.
    pub fn file(archive: Archive, slot: usize) !?File {
        const held = archive.slots[slot];
        if (!held.isUsed()) return null;
        const lba = archive.start + held.sector;
        // Whichever way the size counts, the file holds at least this many sectors.
        const streamed = try archive.image.hasForm2(lba, @divCeil(held.size, cdimage.mode2_size));
        return .{
            .slot = slot,
            .name = if (slot < archive.names.len) archive.names[slot] else null,
            .lba = lba,
            .size = held.size,
            .streamed = streamed,
        };
    }

    /// Streams `item`'s bytes into `writer`: its size in bytes, or for a streamed file, whole Mode
    /// 2 sectors, enough to hold its size.
    pub fn copy(archive: Archive, item: File, writer: *Io.Writer) !void {
        if (item.streamed) {
            try archive.image.streamMode2Sectors(item.lba, item.sectors(), writer);
        } else {
            try archive.image.streamExtent(item.lba, item.size, writer);
        }
    }
};

/// A file in the archive.
pub const File = struct {
    slot: usize,
    /// Its name as the executable gives it, such as `TRK\KJ_FA.TRK`; null for a slot the
    /// executable doesn't name.
    name: ?[]const u8,
    /// Its first sector on the disc.
    lba: u32,
    size: u32,
    /// Whether it holds streamed audio, as Form 2 sectors.
    streamed: bool,

    /// The sectors it holds.
    pub fn sectors(item: File) u32 {
        const sector_size: u32 = if (item.streamed) cdimage.mode2_size else cdimage.block_size;
        return @divCeil(item.size, sector_size);
    }

    /// The bytes `Archive.copy` writes.
    pub fn copiedSize(item: File) u64 {
        return if (item.streamed) @as(u64, item.sectors()) * cdimage.mode2_size else item.size;
    }

    /// Where to write it under a folder, `/`-separated: its name with forward slashes, or
    /// `slot_N` for a file without one.
    pub fn path(item: File, arena: Allocator) Allocator.Error![]const u8 {
        const name = item.name orelse return std.fmt.allocPrint(arena, "slot_{d}", .{item.slot});
        const relative = try arena.dupe(u8, std.mem.trimStart(u8, name, "\\"));
        std.mem.replaceScalar(u8, relative, '\\', '/');
        return relative;
    }
};

/// The files' names in `executable`, in slot order: the longest run of pointers in its text to
/// names of files (`isFileName`).
pub fn names(arena: Allocator, executable: exe.Executable) Allocator.Error![]const []const u8 {
    const text = executable.text;
    var best: struct { at: usize = 0, count: usize = 0 } = .{};
    var at: usize = 0;
    while (at + 4 <= text.len) {
        var count: usize = 0;
        while (at + (count + 1) * 4 <= text.len and fileNameAt(executable, pointer(text, at + count * 4)) != null) count += 1;
        if (count > best.count) best = .{ .at = at, .count = count };
        at += 4 * @max(count, 1);
    }
    const found = try arena.alloc([]const u8, best.count);
    for (found, 0..) |*name, i| name.* = fileNameAt(executable, pointer(text, best.at + i * 4)).?;
    return found;
}

fn pointer(text: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, text[at..][0..4], .little);
}

/// Whether `name` is the name of a file in the archive: a path of capital letters, digits and
/// underscores with backslashes between its parts, such as `TRK\KJ_FA.TRK`, or `\FRONTEND.OVL` for
/// a file at the top. The name has an extension, and no part is only dots.
pub fn isFileName(name: []const u8) bool {
    if (name.len == 0 or name.len > longest_name) return false;
    for (name) |c| switch (c) {
        'A'...'Z', '0'...'9', '_', '.', '\\' => {},
        else => return false,
    };
    var parts = std.mem.splitScalar(u8, std.mem.trimStart(u8, name, "\\"), '\\');
    var last: []const u8 = "";
    while (parts.next()) |part| {
        if (std.mem.trim(u8, part, ".").len == 0) return false;
        last = part;
    }
    const dot = std.mem.findScalarLast(u8, last, '.') orelse return false;
    return dot + 1 < last.len;
}

/// The string at `address` in the executable's text, where it is the name of a file in the
/// archive.
fn fileNameAt(executable: exe.Executable, address: u32) ?[]const u8 {
    const name = executable.string(address, longest_name) orelse return null;
    return if (isFileName(name)) name else null;
}

test isFileName {
    try std.testing.expect(isFileName("TRK\\KJ_FA.TRK"));
    try std.testing.expect(isFileName("\\FRONTEND.OVL"));
    try std.testing.expect(!isFileName("TRK\\..\\KJ_FA.TRK"));
    try std.testing.expect(!isFileName("TRK\\\\KJ_FA.TRK"));
    try std.testing.expect(!isFileName("README"));
    try std.testing.expect(!isFileName("NAME."));
    try std.testing.expect(!isFileName("trk\\kj_fa.trk"));
    try std.testing.expect(!isFileName(""));
}

test Archive {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The executable: two names, then the table of pointers to them, after a lone pointer.
    const address = 0x80010000;
    var text: [64]u8 = @splat(0);
    @memcpy(text[0..10], "TRK\\A.TRK\x00");
    @memcpy(text[16..27], "\\MUSIC.XAR\x00");
    std.mem.writeInt(u32, text[32..36], address, .little);
    std.mem.writeInt(u32, text[40..44], address, .little);
    std.mem.writeInt(u32, text[44..48], address + 16, .little);
    const program = try exe.testing.build(arena, address, &text);

    // The disc: the volume's descriptors and root, `SYSTEM.CNF`, the executable, and the archive,
    // whose index takes a sector. Slot 0 holds a file of logical blocks and slot 1 a streamed
    // file of two Mode 2 sectors; slot 2 is empty.
    const block_size = cdimage.block_size;
    const root_lba = 18;
    const cnf_lba = 19;
    const exe_lba = 20;
    const res_lba = 22;
    var blocks: [27][block_size]u8 = @splat(@splat(0));
    const cnf = "BOOT = cdrom:\\SLUS_000.01;1\r\n";
    @memcpy(blocks[cnf_lba][0..cnf.len], cnf);
    @memcpy(std.mem.sliceAsBytes(blocks[exe_lba..][0..2])[0..program.len], program);
    const index: [3]Slot = .{ .{ .sector = 1, .size = 5 }, .{ .sector = 2, .size = cdimage.mode2_size + 10 }, .{ .sector = 0, .size = 0 } };
    @memcpy(blocks[res_lba][0..@sizeOf(@TypeOf(index))], std.mem.asBytes(&index));
    @memcpy(blocks[res_lba + 1][0..5], "hello");

    const root: iso9660.Extent = .{ .lba = root_lba, .len = block_size };
    iso9660.testing.writeDescriptors(&blocks, "TREK", root);
    var pos: usize = 0;
    const write = iso9660.testing.writeRecord;
    write(&blocks[root_lba], &pos, iso9660.DirectoryRecord.self_identifier, root, .directory);
    write(&blocks[root_lba], &pos, iso9660.DirectoryRecord.parent_identifier, root, .directory);
    write(&blocks[root_lba], &pos, "SLUS_000.01;1", .{ .lba = exe_lba, .len = @intCast(program.len) }, .file);
    write(&blocks[root_lba], &pos, "STARTREK.RES;1", .{ .lba = res_lba, .len = 5 * block_size }, .file);
    write(&blocks[root_lba], &pos, "SYSTEM.CNF;1", .{ .lba = cnf_lba, .len = cnf.len }, .file);

    // As raw sectors: Form 1 but for the streamed file's two.
    var raw: [blocks.len * cdimage.raw_sector_size]u8 = undefined;
    for (blocks, 0..) |block, lba| {
        const form2 = lba >= res_lba + 2 and lba < res_lba + 4;
        const sector = if (form2)
            cdimage.testing.mode2Sector(@intCast(lba), cdimage.testing.form2, &.{@intCast(lba)})
        else
            cdimage.testing.mode2Sector(@intCast(lba), cdimage.testing.form1, &block);
        raw[lba * cdimage.raw_sector_size ..][0..cdimage.raw_sector_size].* = sector;
    }
    const image: cdimage.Image = try .init(.{ .memory = &raw });
    const volume: iso9660.Volume = try .open(image);
    const archive: Archive = try .open(arena, &volume);

    try std.testing.expectEqual(2, archive.names.len);
    try std.testing.expectEqual(block_size / @sizeOf(Slot), archive.slots.len);

    const first = (try archive.file(0)).?;
    try std.testing.expectEqualStrings("TRK/A.TRK", try first.path(arena));
    try std.testing.expect(!first.streamed);
    var buffer: [2 * cdimage.mode2_size]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try archive.copy(first, &writer);
    try std.testing.expectEqualStrings("hello", writer.buffered());

    const music = (try archive.file(1)).?;
    try std.testing.expectEqualStrings("MUSIC.XAR", try music.path(arena));
    try std.testing.expect(music.streamed);
    try std.testing.expectEqual(2, music.sectors());
    writer = .fixed(&buffer);
    try archive.copy(music, &writer);
    try std.testing.expectEqual(2 * cdimage.mode2_size, writer.buffered().len);
    try std.testing.expectEqual(res_lba + 3, buffer[cdimage.mode2_size + 8]);

    try std.testing.expectEqual(null, try archive.file(2));
    // A slot past the executable's names.
    const unnamed: File = .{ .slot = 7, .name = null, .lba = 0, .size = 1, .streamed = false };
    try std.testing.expectEqualStrings("slot_7", try unnamed.path(arena));
}
