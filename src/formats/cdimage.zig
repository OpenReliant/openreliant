//! Raw CD-ROM image access.
//!
//! Redump-style `.bin` images store complete 2352-byte sectors (sync pattern, header, user data,
//! EDC/ECC), while plain `.iso` images store only the 2048-byte user data of each sector. `Image`
//! hides that difference and presents either kind as a flat array of 2048-byte logical blocks,
//! which is what the ISO 9660 layer wants.
//!
//! Only single-track data images are supported, which is all a StarLancer disc is.

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

/// Size of a complete sector as stored in a raw image.
pub const raw_sector_size = 2352;
/// Size of the user data area of a Mode 1 / Mode 2 Form 1 sector: one logical block.
pub const block_size = 2048;

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
        end_of_record: bool,
        video: bool,
        audio: bool,
        data: bool,
        trigger: bool,
        form2: bool,
        real_time: bool,
        end_of_file: bool,
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

/// Returns the logical block stored inside a raw sector.
pub fn userData(sector: *const [raw_sector_size]u8) SectorError!*const [block_size]u8 {
    const header: *const Header = @ptrCast(sector[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &header.sync, &sync_pattern)) return error.BadSync;
    const offset: usize = switch (header.mode) {
        .mode1 => @sizeOf(Header),
        .mode2 => offset: {
            const subheader: *const XaSubheader = @ptrCast(sector[@sizeOf(Header)..][0..@sizeOf(XaSubheader)]);
            if (subheader.submode.form2) return error.NoLogicalBlock;
            break :offset @sizeOf(Header) + 2 * @sizeOf(XaSubheader);
        },
        .mode0, _ => return error.NoLogicalBlock,
    };
    return sector[offset..][0..block_size];
}

/// A single-track data image, addressed in logical blocks.
pub const Image = struct {
    source: Source,
    layout: Layout,
    block_count: u32,

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

        pub fn sectorSize(layout: Layout) u32 {
            return switch (layout) {
                .cooked => block_size,
                .raw => raw_sector_size,
            };
        }
    };

    pub fn open(io: Io, dir: Io.Dir, path: []const u8) !Image {
        const handle = try dir.openFile(io, path, .{});
        errdefer handle.close(io);
        return init(.{ .file = .{ .io = io, .handle = handle } });
    }

    pub fn init(source: Source) !Image {
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
        if (lba > image.block_count or image.block_count - lba < count) return error.EndOfImage;

        switch (image.layout) {
            .cooked => try image.source.readAll(out, @as(u64, lba) * block_size),
            .raw => {
                // Pull raw sectors in batches so large extents do not cost a syscall per sector.
                var batch: [32 * raw_sector_size]u8 = undefined;
                var done: usize = 0;
                while (done < count) {
                    const n: usize = @min(count - done, batch.len / raw_sector_size);
                    const raw = batch[0 .. n * raw_sector_size];
                    try image.source.readAll(raw, (@as(u64, lba) + done) * raw_sector_size);
                    for (0..n) |i| {
                        const data = try userData(raw[i * raw_sector_size ..][0..raw_sector_size]);
                        @memcpy(out[(done + i) * block_size ..][0..block_size], data);
                    }
                    done += n;
                }
            },
        }
    }

    /// Streams `len` bytes, starting at the beginning of block `lba`, into `writer`.
    pub fn streamExtent(image: Image, lba: u32, len: u64, writer: *Io.Writer) !void {
        var blocks: [32 * block_size]u8 = undefined;
        var remaining = len;
        var next = lba;
        while (remaining > 0) {
            const wanted: usize = @intCast(@min(remaining, blocks.len));
            const n_blocks = std.math.divCeil(usize, wanted, block_size) catch unreachable;
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

test "sectors without a logical block are rejected" {
    const data: [block_size]u8 = @splat(0);
    var sector = testing.sector(0, &data);
    sector[15] = @backingInt(Mode.mode0);
    try std.testing.expectError(error.NoLogicalBlock, userData(&sector));
    sector[0] = 0xAA;
    try std.testing.expectError(error.BadSync, userData(&sector));
}
