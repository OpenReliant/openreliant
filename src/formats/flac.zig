//! FLAC files, which mods can use for music and recordings
//! ([#1173](https://github.com/OpenReliant/openreliant/issues/1173)). A file holds the marker
//! `fLaC`, then the metadata blocks, starting with the stream's STREAMINFO, then the audio frames
//! (RFC 9639). OpenReliant reads the STREAMINFO here and hands the whole file to FFmpeg's FLAC
//! decoder, which reads the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const extension = ".flac";

/// The four bytes a FLAC file starts with.
pub const marker = "fLaC";

/// The header of a metadata block, read as a big-endian word.
pub const BlockHeader = packed struct(u32) {
    /// The length of the block after its header, in bytes.
    length: u24,
    type: BlockType,
    /// Set on the last metadata block, which the audio frames follow.
    last: bool,

    pub const size = @sizeOf(u32);

    pub fn read(bytes: *const [size]u8) BlockHeader {
        return @bitCast(std.mem.readInt(u32, bytes, .big));
    }

    pub fn write(header: BlockHeader) [size]u8 {
        var bytes: [size]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @bitCast(header), .big);
        return bytes;
    }
};

/// The type of a metadata block. OpenReliant reads only the STREAMINFO.
pub const BlockType = enum(u7) {
    stream_info = 0,
    _,
};

/// What a stream's STREAMINFO block says about it.
pub const StreamInfo = struct {
    /// Samples per second.
    rate: u32,
    channels: u8,
    /// Bits per sample, from 4 to 32.
    bits: u8,
    /// Samples in each channel; 0 if the encoder didn't know.
    samples: u64,

    pub const Error = error{ NotFlac, NoStreamInfo };

    /// The block's length, after its header.
    pub const length = 34;
    /// Where `Fields` starts in the block: after the smallest and largest block sizes, two bytes
    /// each, and the smallest and largest frame sizes, three bytes each.
    const fields_at = 10;

    /// The block's word after the block and frame sizes, read as a big-endian word. Each count is
    /// stored less one.
    const Fields = packed struct(u64) {
        samples: u36,
        bits_less_one: u5,
        channels_less_one: u3,
        rate: u20,
    };

    /// The STREAMINFO of the FLAC file `bytes`, the metadata block that comes first.
    pub fn read(bytes: []const u8) Error!StreamInfo {
        if (!std.mem.startsWith(u8, bytes, marker)) return error.NotFlac;
        if (bytes.len < marker.len + BlockHeader.size + length) return error.NoStreamInfo;
        const header: BlockHeader = .read(bytes[marker.len..][0..BlockHeader.size]);
        if (header.type != .stream_info or header.length != length) return error.NoStreamInfo;
        const block = bytes[marker.len + BlockHeader.size ..][0..length];
        const fields: Fields = @bitCast(std.mem.readInt(u64, block[fields_at..][0..@sizeOf(u64)], .big));
        return .{
            .rate = fields.rate,
            .channels = @as(u8, fields.channels_less_one) + 1,
            .bits = @as(u8, fields.bits_less_one) + 1,
            .samples = fields.samples,
        };
    }
};

/// FLAC files for the tests, built by hand.
pub const testing = struct {
    /// A FLAC file of 16-bit samples at `rate` with one frame of `count` samples in each channel,
    /// where each channel holds its value of `levels` throughout: a constant subframe for each.
    pub fn constant(gpa: Allocator, rate: u20, levels: []const i16, count: u8) Allocator.Error![]u8 {
        var file: std.ArrayList(u8) = .empty;
        errdefer file.deinit(gpa);
        try file.appendSlice(gpa, marker);
        // The STREAMINFO, the only metadata block: the block and frame sizes, the fields `read`
        // reads, and the audio's MD5 left as zeros.
        try file.appendSlice(gpa, &BlockHeader.write(.{ .length = StreamInfo.length, .type = .stream_info, .last = true }));
        var block: [StreamInfo.length]u8 = @splat(0);
        std.mem.writeInt(u16, block[0..2], count, .big);
        std.mem.writeInt(u16, block[2..4], count, .big);
        const channels_less_one: u3 = @intCast(levels.len - 1);
        const fields: StreamInfo.Fields = .{ .samples = count, .bits_less_one = 16 - 1, .channels_less_one = channels_less_one, .rate = rate };
        std.mem.writeInt(u64, block[StreamInfo.fields_at..][0..@sizeOf(u64)], @bitCast(fields), .big);
        try file.appendSlice(gpa, &block);
        // The frame's header: the sync code, for blocks of a fixed size; the block size given in
        // 8 bits at the end of the header (`0110`), and the rate taken from the STREAMINFO; the
        // channels coded apart, and the bits per sample taken from the STREAMINFO; frame number 0;
        // the block size less one; and the header's CRC-8.
        const frame_at = file.items.len;
        try file.appendSlice(gpa, &.{ 0xFF, 0xF8, 0x60, @as(u8, channels_less_one) << 4, 0, count - 1 });
        try file.append(gpa, std.hash.crc.@"CRC-8/SMBUS".hash(file.items[frame_at..]));
        // Each subframe: a constant (type 0, no wasted bits), then its value in 16 bits.
        for (levels) |level| {
            try file.append(gpa, 0);
            try file.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(i16, level)));
        }
        // The frame's CRC-16.
        const crc = std.hash.crc.@"CRC-16/UMTS".hash(file.items[frame_at..]);
        try file.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u16, crc)));
        return file.toOwnedSlice(gpa);
    }
};

test StreamInfo {
    const gpa = std.testing.allocator;
    const file = try testing.constant(gpa, 44100, &.{ 1000, -2000 }, 192);
    defer gpa.free(file);
    try std.testing.expectEqual(StreamInfo{ .rate = 44100, .channels = 2, .bits = 16, .samples = 192 }, try StreamInfo.read(file));
    try std.testing.expectError(error.NotFlac, StreamInfo.read("RIFF"));
    try std.testing.expectError(error.NoStreamInfo, StreamInfo.read(file[0..20]));
    // A file whose first block is another type, such as a VORBIS_COMMENT (4).
    var wrong = try gpa.dupe(u8, file);
    defer gpa.free(wrong);
    wrong[marker.len..][0..BlockHeader.size].* = BlockHeader.write(.{ .length = StreamInfo.length, .type = @fromBackingInt(4), .last = true });
    try std.testing.expectError(error.NoStreamInfo, StreamInfo.read(wrong));
}

test BlockHeader {
    // The last block, a STREAMINFO of 34 bytes.
    const header: BlockHeader = .read(&.{ 0x80, 0, 0, 34 });
    try std.testing.expectEqual(BlockHeader{ .length = 34, .type = .stream_info, .last = true }, header);
    try std.testing.expectEqual([_]u8{ 0x80, 0, 0, 34 }, header.write());
}
