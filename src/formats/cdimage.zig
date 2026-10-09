//! Raw CD-ROM image access.
//!
//! Redump-style `.bin` images store complete 2352-byte sectors (sync pattern, header, user data,
//! EDC/ECC), while plain `.iso` images store only the 2048-byte user data of each sector. `Image`
//! hides that difference and presents either kind as a flat array of 2048-byte logical blocks,
//! which is what the ISO 9660 layer wants.
//!
//! PlayStation discs also hold Mode 2 Form 2 sectors, which carry streamed audio and video in
//! place of a logical block. `Image` copies the files that hold them as whole Mode 2 sectors.
//!
//! A DiscJuggler `.cdi` image holds several tracks, and `Image` reads its last data track
//! (`cdimage/cdi.zig`). That track may store 2336-byte Mode 2 sectors without their sync pattern
//! and header, and start at a disc address other than 0. Otherwise an image holds one data track.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

pub const cdi = @import("cdimage/cdi.zig");

/// Size of a complete sector as stored in a raw image.
pub const raw_sector_size = 2352;
/// Size of the user data area of a Mode 1 / Mode 2 Form 1 sector: one logical block.
pub const block_size = 2048;
/// Size of a Mode 2 sector without its sync pattern and header: the subheader, twice, then 2328
/// bytes of data and error checks, in either form. Files with streamed audio or video are copied
/// off a disc in sectors of this size, which PlayStation tools read.
pub const mode2_size = raw_sector_size - @sizeOf(Header);

/// Every raw data sector starts with this pattern.
pub const sync_pattern = [_]u8{0x00} ++ @as([10]u8, @splat(0xFF)) ++ [_]u8{0x00};

/// One binary-coded-decimal byte.
pub const Bcd = packed struct(u8) {
    ones: u4,
    tens: u4,

    pub fn value(bcd: Bcd) u8 {
        return @as(u8, bcd.tens) * 10 + bcd.ones;
    }

    pub fn from(n: u8) Bcd {
        assert(n < 100);
        return .{ .ones = @intCast(n % 10), .tens = @intCast(n / 10) };
    }
};

/// Absolute sector address: minutes / seconds / frames, 75 frames to the second.
pub const Msf = extern struct {
    minute: Bcd,
    second: Bcd,
    frame: Bcd,

    /// Sectors a second of a disc holds.
    pub const frames_per_second = 75;
    const seconds_per_minute = std.time.s_per_min;

    /// The data area starts after a two second pregap, so LBA 0 is at 00:02:00.
    pub const pregap_frames = 2 * frames_per_second;

    pub fn toLba(msf: Msf) ?u32 {
        const seconds = @as(u32, msf.minute.value()) * seconds_per_minute + msf.second.value();
        const frames = seconds * frames_per_second + msf.frame.value();
        return if (frames < pregap_frames) null else frames - pregap_frames;
    }

    pub fn fromLba(lba: u32) Msf {
        const frames = lba + pregap_frames;
        return .{
            .minute = .from(@intCast(frames / (frames_per_second * seconds_per_minute))),
            .second = .from(@intCast(frames / frames_per_second % seconds_per_minute)),
            .frame = .from(@intCast(frames % frames_per_second)),
        };
    }

    comptime {
        assert(@sizeOf(Msf) == 3);
    }
};

pub const Mode = enum(u8) {
    /// Zero-filled sector.
    mode0 = 0,
    /// 2048 data bytes protected by EDC and ECC.
    mode1 = 1,
    /// CD-ROM XA. The subheader selects Form 1 (2048 data bytes) or Form 2 (2324).
    mode2 = 2,
    _,
};

/// The first 16 bytes of every raw sector.
pub const Header = extern struct {
    sync: [12]u8,
    address: Msf,
    mode: Mode,

    comptime {
        assert(@sizeOf(Header) == 16);
    }
};

/// Mode 2 sectors follow the header with this subheader, stored twice for redundancy.
pub const XaSubheader = extern struct {
    file_number: u8,
    channel_number: u8,
    submode: Submode,
    coding_info: u8,

    pub const Submode = packed struct(u8) {
        end_of_record: bool = false,
        video: bool = false,
        audio: bool = false,
        data: bool = false,
        trigger: bool = false,
        form2: bool = false,
        real_time: bool = false,
        end_of_file: bool = false,
    };

    comptime {
        assert(@sizeOf(XaSubheader) == 4);
    }
};

pub const SectorError = error{
    /// The sector does not begin with `sync_pattern`.
    BadSync,
    /// The sector mode carries no 2048-byte logical block (Mode 0, Mode 2 Form 2, unknown).
    NoLogicalBlock,
};

/// The header of a raw sector, once its sync pattern is checked.
fn headerOf(sector: *const [raw_sector_size]u8) SectorError!*const Header {
    const header: *const Header = @ptrCast(sector[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.sync, &sync_pattern)) return error.BadSync;
    return header;
}

/// Whether a Mode 2 sector without its sync pattern and header is a Form 2 sector.
fn mode2IsForm2(sector: *const [mode2_size]u8) bool {
    const subheader: *const XaSubheader = @ptrCast(sector[0..@sizeOf(XaSubheader)]);
    return subheader.submode.form2;
}

/// The logical block of a Mode 2 sector without its sync pattern and header.
fn mode2Block(sector: *const [mode2_size]u8) SectorError!*const [block_size]u8 {
    if (mode2IsForm2(sector)) return error.NoLogicalBlock;
    return sector[2 * @sizeOf(XaSubheader) ..][0..block_size];
}

/// Returns the logical block stored inside a raw sector.
pub fn userData(sector: *const [raw_sector_size]u8) SectorError!*const [block_size]u8 {
    return switch ((try headerOf(sector)).mode) {
        .mode1 => sector[@sizeOf(Header)..][0..block_size],
        .mode2 => mode2Block(sector[@sizeOf(Header)..]),
        .mode0, _ => error.NoLogicalBlock,
    };
}

/// Whether a raw sector is a Mode 2 Form 2 sector, which holds streamed audio or video rather than
/// a logical block.
pub fn isForm2(sector: *const [raw_sector_size]u8) SectorError!bool {
    return (try headerOf(sector)).mode == .mode2 and mode2IsForm2(sector[@sizeOf(Header)..]);
}

/// A data track's image, addressed in logical blocks.
pub const Image = struct {
    source: Source,
    layout: Layout,
    /// The sectors the image holds, from `first_lba`.
    block_count: u32,
    /// The disc address of the image's first sector: 0 for a whole disc, or the start of a track
    /// taken from a disc with several sessions, such as a `.cdi` image's.
    first_lba: u32 = 0,
    /// Where the first sector is in the file.
    start: u64 = 0,

    pub const Source = union(enum) {
        file: struct { io: Io, handle: Io.File },
        /// An image held in memory. Used by tests.
        memory: []const u8,

        fn length(source: Source) !u64 {
            return switch (source) {
                .file => |f| try f.handle.length(f.io),
                .memory => |bytes| bytes.len,
            };
        }

        /// Fills `buffer` from `offset`, failing if the source ends first.
        fn readAll(source: Source, buffer: []u8, offset: u64) !void {
            switch (source) {
                .file => |f| {
                    const n = try f.handle.readPositionalAll(f.io, buffer, offset);
                    if (n != buffer.len) return error.EndOfImage;
                },
                .memory => |bytes| {
                    if (offset > bytes.len or bytes.len - offset < buffer.len) return error.EndOfImage;
                    @memcpy(buffer, bytes[@intCast(offset)..][0..buffer.len]);
                },
            }
        }
    };

    pub const Layout = enum {
        /// Bare 2048-byte logical blocks (`.iso`).
        cooked,
        /// Complete 2352-byte sectors (`.bin` of a `MODE1/2352` or `MODE2/2352` track).
        raw,
        /// 2336-byte Mode 2 sectors without their sync pattern and header (a `.cdi` image's
        /// `MODE2/2336` track).
        mode2,

        pub fn sectorSize(layout: Layout) u32 {
            return switch (layout) {
                .cooked => block_size,
                .raw => raw_sector_size,
                .mode2 => mode2_size,
            };
        }

        /// The logical block of `sector`, a sector as this layout stores it.
        fn block(layout: Layout, sector: []const u8) SectorError!*const [block_size]u8 {
            return switch (layout) {
                .cooked => sector[0..block_size],
                .raw => userData(sector[0..raw_sector_size]),
                .mode2 => mode2Block(sector[0..mode2_size]),
            };
        }

        /// Whether `sector` is a Mode 2 Form 2 sector.
        fn holdsForm2(layout: Layout, sector: []const u8) SectorError!bool {
            return switch (layout) {
                .cooked => false,
                .raw => isForm2(sector[0..raw_sector_size]),
                .mode2 => mode2IsForm2(sector[0..mode2_size]),
            };
        }

        /// `sector` as a whole Mode 2 sector without its sync pattern and header.
        fn mode2Sector(layout: Layout, sector: []const u8) ![]const u8 {
            return switch (layout) {
                .cooked => error.CookedImage,
                .raw => if ((try headerOf(sector[0..raw_sector_size])).mode == .mode2) sector[@sizeOf(Header)..] else error.NotMode2,
                .mode2 => sector,
            };
        }
    };

    pub fn open(io: Io, dir: Io.Dir, path: []const u8) !Image {
        const handle = try dir.openFile(io, path, .{});
        errdefer handle.close(io);
        return init(.{ .file = .{ .io = io, .handle = handle } });
    }

    pub fn init(source: Source) !Image {
        if (try fromCdi(source)) |image| return image;
        var probe: [sync_pattern.len]u8 = undefined;
        const layout: Layout = if (source.readAll(&probe, 0)) |_|
            if (std.mem.eql(u8, &probe, &sync_pattern)) .raw else .cooked
        else |err| switch (err) {
            error.EndOfImage => return error.NotADiscImage,
            else => |e| return e,
        };

        const len = try source.length();
        const sector_size = layout.sectorSize();
        if (len % sector_size != 0) return error.NotADiscImage;
        return .{
            .source = source,
            .layout = layout,
            .block_count = std.math.cast(u32, len / sector_size) orelse return error.NotADiscImage,
        };
    }

    /// The last data track of a `.cdi` image; null for a file that isn't one.
    fn fromCdi(source: Source) !?Image {
        const size = try source.length();
        var tail: [8]u8 = undefined;
        if (size < tail.len) return null;
        try source.readAll(&tail, size - tail.len);
        const table_at = cdi.tableStart(&tail, size) orelse return null;
        if (size - table_at.offset > cdi.max_table) return null;
        var buffer: [cdi.max_table]u8 = undefined;
        const table = buffer[0..@intCast(size - table_at.offset)];
        try source.readAll(table, table_at.offset);
        // A file whose last bytes only look like a `.cdi` image's is read as an image of another
        // kind.
        const found = cdi.lastDataTrack(table, table_at.version) catch return null;
        const track = found orelse return error.NoDataTrack;
        const layout: Layout = switch (track.sector_size) {
            block_size => .cooked,
            mode2_size => .mode2,
            else => .raw,
        };
        if (track.offset + @as(u64, track.length) * layout.sectorSize() > table_at.offset) return error.NotADiscImage;
        return .{ .source = source, .layout = layout, .block_count = track.length, .first_lba = track.first_lba, .start = track.offset };
    }

    pub fn close(image: Image) void {
        switch (image.source) {
            .file => |f| f.handle.close(f.io),
            .memory => {},
        }
    }

    /// Reads whole logical blocks, starting at `lba`, until `out` is full.
    pub fn readBlocks(image: Image, lba: u32, out: []u8) !void {
        assert(out.len % block_size == 0);
        const count = out.len / block_size;
        switch (image.layout) {
            .cooked => {
                try image.checkRange(lba, count);
                try image.source.readAll(out, image.offsetOf(lba));
            },
            .raw, .mode2 => {
                var sectors = try image.sectorsAt(lba, count);
                var at: usize = 0;
                while (try sectors.next()) |sector| : (at += block_size) {
                    @memcpy(out[at..][0..block_size], try image.layout.block(sector));
                }
            },
        }
    }

    /// Whether any of the `count` sectors from `lba` is a Mode 2 Form 2 sector. A cooked image
    /// holds logical blocks alone, so never.
    pub fn hasForm2(image: Image, lba: u32, count: usize) !bool {
        if (image.layout == .cooked) return false;
        var sectors = try image.sectorsAt(lba, count);
        while (try sectors.next()) |sector| {
            if (try image.layout.holdsForm2(sector)) return true;
        }
        return false;
    }

    /// Streams the `count` sectors from `lba` into `writer` as whole Mode 2 sectors,
    /// `mode2_size` bytes each, the way PlayStation tools keep a file with streamed audio or
    /// video. Only a raw image holds them.
    pub fn streamMode2Sectors(image: Image, lba: u32, count: usize, writer: *Io.Writer) !void {
        if (image.layout == .cooked) return error.CookedImage;
        var sectors = try image.sectorsAt(lba, count);
        while (try sectors.next()) |sector| try writer.writeAll(try image.layout.mode2Sector(sector));
    }

    /// Fails unless the image holds the `count` sectors from `lba`.
    fn checkRange(image: Image, lba: u32, count: usize) error{EndOfImage}!void {
        if (lba < image.first_lba) return error.EndOfImage;
        const at = lba - image.first_lba;
        if (at > image.block_count or image.block_count - at < count) return error.EndOfImage;
    }

    /// Where the sector at disc address `lba` is in the file.
    fn offsetOf(image: Image, lba: u32) u64 {
        return image.start + @as(u64, lba - image.first_lba) * image.layout.sectorSize();
    }

    /// The `count` whole sectors from `lba`, read in turn.
    fn sectorsAt(image: Image, lba: u32, count: usize) error{EndOfImage}!Sectors {
        assert(image.layout != .cooked);
        try image.checkRange(lba, count);
        return .{ .image = image, .lba = lba, .end = lba + @as(u32, @intCast(count)) };
    }

    /// Reads whole sectors in batches, so that a large extent doesn't cost a read for each sector.
    const Sectors = struct {
        image: Image,
        /// The next sector to read, and the sector after the last.
        lba: u32,
        end: u32,
        batch: [batch_sectors * raw_sector_size]u8 = undefined,
        /// The sectors the batch holds, and how many of them are taken.
        held: u32 = 0,
        taken: u32 = 0,

        const batch_sectors = 32;

        fn next(reading: *Sectors) !?[]const u8 {
            const size = reading.image.layout.sectorSize();
            if (reading.taken == reading.held) {
                if (reading.lba == reading.end) return null;
                const n: u32 = @min(reading.end - reading.lba, batch_sectors);
                try reading.image.source.readAll(reading.batch[0 .. n * size], reading.image.offsetOf(reading.lba));
                reading.lba += n;
                reading.held = n;
                reading.taken = 0;
            }
            defer reading.taken += 1;
            return reading.batch[reading.taken * size ..][0..size];
        }
    };

    /// Streams `len` bytes, starting at the beginning of block `lba`, into `writer`.
    pub fn streamExtent(image: Image, lba: u32, len: u64, writer: *Io.Writer) !void {
        var blocks: [32 * block_size]u8 = undefined;
        var remaining = len;
        var next = lba;
        while (remaining > 0) {
            const wanted: usize = @intCast(@min(remaining, blocks.len));
            const n_blocks = @divCeil(wanted, block_size);
            try image.readBlocks(next, blocks[0 .. n_blocks * block_size]);
            try writer.writeAll(blocks[0..wanted]);
            remaining -= wanted;
            next += @intCast(n_blocks);
        }
    }
};

/// Builds images in memory, for the tests of code that reads them.
pub const testing = struct {
    /// A raw Mode 1 sector around `data`. EDC/ECC are left zeroed; nothing here verifies them.
    pub fn sector(lba: u32, data: *const [block_size]u8) [raw_sector_size]u8 {
        var raw: [raw_sector_size]u8 = @splat(0);
        const header: *Header = @ptrCast(raw[0..@sizeOf(Header)]);
        header.* = .{ .sync = sync_pattern, .address = .fromLba(lba), .mode = .mode1 };
        @memcpy(raw[@sizeOf(Header)..][0..block_size], data);
        return raw;
    }

    /// A raw Mode 2 sector with `submode` in its subheader, its data area starting with `data`.
    pub fn mode2Sector(lba: u32, submode: XaSubheader.Submode, data: []const u8) [raw_sector_size]u8 {
        var raw: [raw_sector_size]u8 = @splat(0);
        const header: *Header = @ptrCast(raw[0..@sizeOf(Header)]);
        header.* = .{ .sync = sync_pattern, .address = .fromLba(lba), .mode = .mode2 };
        const subheader: XaSubheader = .{ .file_number = 0, .channel_number = 0, .submode = submode, .coding_info = 0 };
        for (0..2) |copy| raw[@sizeOf(Header) + copy * @sizeOf(XaSubheader) ..][0..@sizeOf(XaSubheader)].* = std.mem.toBytes(subheader);
        @memcpy(raw[@sizeOf(Header) + 2 * @sizeOf(XaSubheader) ..][0..data.len], data);
        return raw;
    }

    /// A `.cdi` image of an audio track, then a data track of 2336-byte sectors, `blocks`, which
    /// starts at disc address `first_lba`, each track after a pregap of one sector.
    pub fn cdiImage(arena: std.mem.Allocator, first_lba: u32, blocks: []const [block_size]u8) std.mem.Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendNTimes(arena, 0, 2 * raw_sector_size);
        try out.appendNTimes(arena, 0, mode2_size);
        for (blocks, 0..) |*data, at| {
            const whole = mode2Sector(first_lba + @as(u32, @intCast(at)), form1, data);
            try out.appendSlice(arena, whole[@sizeOf(Header)..]);
        }
        const table_at = out.items.len;
        try out.appendSlice(arena, try cdi.testing.table(arena, &.{
            .{ .mode = 0, .sector_code = 2, .pregap = 1, .length = 1, .first_lba = 0 },
            .{ .mode = 2, .sector_code = 1, .pregap = 1, .length = @intCast(blocks.len), .first_lba = first_lba },
        }));
        var tail: [8]u8 = undefined;
        std.mem.writeInt(u32, tail[0..4], @backingInt(cdi.Version.v3_5), .little);
        std.mem.writeInt(u32, tail[4..8], @intCast(out.items.len + tail.len - table_at), .little);
        try out.appendSlice(arena, &tail);
        return out.items;
    }

    /// The submode of a Form 1 data sector, and of a Form 2 sector of streamed audio.
    pub const form1: XaSubheader.Submode = .{ .data = true };
    pub const form2: XaSubheader.Submode = .{ .audio = true, .form2 = true, .real_time = true };
};

test "Bcd and Msf round-trip" {
    try std.testing.expectEqual(@as(u8, 59), (Bcd{ .tens = 5, .ones = 9 }).value());
    try std.testing.expectEqual(@as(u8, 0x59), @as(u8, @bitCast(Bcd.from(59))));

    // LBA 16 (the ISO 9660 primary volume descriptor) sits at 00:02:16.
    const msf: Msf = .fromLba(16);
    try std.testing.expectEqual(@as(u8, 0x00), @as(u8, @bitCast(msf.minute)));
    try std.testing.expectEqual(@as(u8, 0x02), @as(u8, @bitCast(msf.second)));
    try std.testing.expectEqual(@as(u8, 0x16), @as(u8, @bitCast(msf.frame)));
    try std.testing.expectEqual(@as(?u32, 16), msf.toLba());
    try std.testing.expectEqual(@as(?u32, null), (Msf{ .minute = .from(0), .second = .from(1), .frame = .from(74) }).toLba());
}

test "raw image exposes user data as logical blocks" {
    var raw: [3 * raw_sector_size]u8 = undefined;
    for (0..3) |i| {
        const data: [block_size]u8 = @splat(@intCast('a' + i));
        raw[i * raw_sector_size ..][0..raw_sector_size].* = testing.sector(@intCast(i), &data);
    }

    const image: Image = try .init(.{ .memory = &raw });
    try std.testing.expectEqual(Image.Layout.raw, image.layout);
    try std.testing.expectEqual(@as(u32, 3), image.block_count);

    var out: [2 * block_size]u8 = undefined;
    try image.readBlocks(1, &out);
    try std.testing.expectEqualSlices(u8, &(@as([block_size]u8, @splat('b')) ++ @as([block_size]u8, @splat('c'))), &out);
    try std.testing.expectError(error.EndOfImage, image.readBlocks(2, &out));

    // An extent need not be a whole number of blocks.
    var buffer: [block_size + 3]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try image.streamExtent(0, buffer.len, &writer);
    try std.testing.expectEqualSlices(u8, "abbb", buffer[block_size - 1 ..]);
}

test "cooked image is passed through" {
    const cooked: [2 * block_size]u8 = @as([block_size]u8, @splat(1)) ++ @as([block_size]u8, @splat(2));
    const image: Image = try .init(.{ .memory = &cooked });
    try std.testing.expectEqual(Image.Layout.cooked, image.layout);

    var out: [block_size]u8 = undefined;
    try image.readBlocks(1, &out);
    try std.testing.expectEqual(@as(u8, 2), out[0]);
}

test "Form 2 sectors are found and copied as whole Mode 2 sectors" {
    var raw: [3 * raw_sector_size]u8 = undefined;
    const block: [block_size]u8 = @splat('a');
    raw[0..raw_sector_size].* = testing.mode2Sector(0, testing.form1, &block);
    raw[raw_sector_size..][0..raw_sector_size].* = testing.mode2Sector(1, testing.form2, "sound");
    raw[2 * raw_sector_size ..][0..raw_sector_size].* = testing.mode2Sector(2, testing.form1, &block);
    const image: Image = try .init(.{ .memory = &raw });

    try std.testing.expect(!try image.hasForm2(0, 1));
    try std.testing.expect(try image.hasForm2(0, 3));
    var out: [block_size]u8 = undefined;
    try std.testing.expectError(error.NoLogicalBlock, image.readBlocks(1, &out));
    try std.testing.expectError(error.EndOfImage, image.hasForm2(2, 2));

    // Each sector keeps its subheader and its whole data area.
    var buffer: [2 * mode2_size]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try image.streamMode2Sectors(0, 2, &writer);
    try std.testing.expectEqual(@as(u8, @bitCast(testing.form1)), buffer[@offsetOf(XaSubheader, "submode")]);
    try std.testing.expectEqual('a', buffer[2 * @sizeOf(XaSubheader)]);
    try std.testing.expectEqualStrings("sound", buffer[mode2_size + 2 * @sizeOf(XaSubheader) ..][0..5]);

    // A cooked image holds no Form 2 sectors.
    const cooked: Image = try .init(.{ .memory = &block });
    try std.testing.expect(!try cooked.hasForm2(0, 1));
    try std.testing.expectError(error.CookedImage, cooked.streamMode2Sectors(0, 1, &writer));
}

test "a .cdi image's data track" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = [_][block_size]u8{ @splat('a'), @splat('b'), @splat('c') };
    const image: Image = try .init(.{ .memory = try testing.cdiImage(arena.allocator(), 11702, &blocks) });
    try std.testing.expectEqual(Image.Layout.mode2, image.layout);
    try std.testing.expectEqual(11702, image.first_lba);
    try std.testing.expectEqual(3, image.block_count);

    var out: [2 * block_size]u8 = undefined;
    try image.readBlocks(11703, &out);
    try std.testing.expectEqual('b', out[0]);
    try std.testing.expectEqual('c', out[block_size]);
    // The track holds nothing before its first sector, or past its last.
    try std.testing.expectError(error.EndOfImage, image.readBlocks(0, &out));
    try std.testing.expectError(error.EndOfImage, image.readBlocks(11704, &out));
    try std.testing.expect(!try image.hasForm2(11702, 3));
}

test "sectors without a logical block are rejected" {
    const data: [block_size]u8 = @splat(0);
    var sector = testing.sector(0, &data);
    sector[15] = @backingInt(Mode.mode0);
    try std.testing.expectError(error.NoLogicalBlock, userData(&sector));
    sector[0] = 0xAA;
    try std.testing.expectError(error.BadSync, userData(&sector));
}
