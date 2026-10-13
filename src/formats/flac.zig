//! FLAC files, which a mod's music and recordings can be
//! ([#1173](https://github.com/OpenReliant/openreliant/issues/1173)): the marker `fLaC`, then the
//! metadata blocks, the first of them the stream's STREAMINFO, then the audio's frames (RFC 9639).
//! OpenReliant reads the STREAMINFO here, and hands the whole file to FFmpeg's FLAC decoder, which
//! reads the rest.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The four bytes a FLAC file starts with.
pub const marker = "fLaC";

/// What a stream's STREAMINFO block says of it.
pub const StreamInfo = struct {
    /// Samples a second.
    rate: u32,
    channels: u8,
    /// Bits a sample, from 4 to 32.
    bits: u8,
    /// Samples in each channel; 0 where the encoder didn't know.
    samples: u64,

    pub const Error = error{ NotFlac, NoStreamInfo };

    /// The block's type, STREAMINFO, and its length.
    const block_type = 0;
    const block_length = 34;

    /// The STREAMINFO of the FLAC file `bytes`, the metadata block that comes first.
    pub fn read(bytes: []const u8) Error!StreamInfo {
        if (!std.mem.startsWith(u8, bytes, marker)) return error.NotFlac;
        if (bytes.len < marker.len + 4 + block_length) return error.NoStreamInfo;
        // A block's header: its type in the low seven bits of the first byte, then its length.
        const header = bytes[marker.len..][0..4];
        if (header[0] & 0x7F != block_type or std.mem.readInt(u24, header[1..4], .big) != block_length) return error.NoStreamInfo;
        // After the block sizes and the frame sizes: 20 bits of rate, 3 of channels less one, 5 of
        // bits less one and 36 of samples.
        const fields = std.mem.readInt(u64, bytes[marker.len + 4 + 10 ..][0..8], .big);
        return .{
            .rate = @intCast(fields >> 44),
            .channels = @intCast((fields >> 41 & 0x7) + 1),
            .bits = @intCast((fields >> 36 & 0x1F) + 1),
            .samples = fields & 0xF_FFFF_FFFF,
        };
    }
};

/// FLAC files for the tests, built by hand.
pub const testing = struct {
    /// A 16-bit FLAC file at `rate` of one frame, `count` samples long, in which each channel
    /// holds its value of `levels` throughout: a constant subframe for each.
    pub fn constant(gpa: Allocator, rate: u20, levels: []const i16, count: u8) Allocator.Error![]u8 {
        var file: std.ArrayList(u8) = .empty;
        errdefer file.deinit(gpa);
        try file.appendSlice(gpa, marker);
        // STREAMINFO, the last metadata block: block and frame sizes, then the fields `read` reads,
        // then the MD5 of the audio, left out.
        try file.appendSlice(gpa, &.{ 0x80, 0, 0, StreamInfo.block_length });
        var block: [StreamInfo.block_length]u8 = @splat(0);
        std.mem.writeInt(u16, block[0..2], count, .big);
        std.mem.writeInt(u16, block[2..4], count, .big);
        const channels: u64 = levels.len - 1;
        std.mem.writeInt(u64, block[10..18], @as(u64, rate) << 44 | channels << 41 | 15 << 36 | count, .big);
        try file.appendSlice(gpa, &block);
        // The frame's header: the sync code, fixed blocks; the block size in 8 bits at the end
        // (`0110`), the rate from the STREAMINFO; independent channels, the bits from the
        // STREAMINFO; frame 0; the block size less one; its CRC-8.
        const frame_at = file.items.len;
        try file.appendSlice(gpa, &.{ 0xFF, 0xF8, 0x60, @intCast(channels << 4), 0, count - 1 });
        try file.append(gpa, std.hash.crc.@"CRC-8/SMBUS".hash(file.items[frame_at..]));
        // Each subframe: a constant (type 0, no wasted bits), its value in 16 bits.
        for (levels) |level| {
            try file.append(gpa, 0);
            try file.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(i16, level)));
        }
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
    // A file whose first block isn't a STREAMINFO.
    var wrong = try gpa.dupe(u8, file);
    defer gpa.free(wrong);
    wrong[4] = 0x84;
    try std.testing.expectError(error.NoStreamInfo, StreamInfo.read(wrong));
}
