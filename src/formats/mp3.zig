//! MP3 files: MPEG audio's Layer III frames, which the lines of the crew in the rooms are
//! (`%s.mp3`). The game hands a file to Miles whole, whose MP3 decoder (`MP3DEC.ASI`) plays it;
//! OpenReliant reads its frames here and hands each to FFmpeg's MP3 decoder.
//!
//! A frame starts with a header of four bytes: eleven bits set, the version, the layer, whether a
//! checksum follows, the bit rate's and the sample rate's indices, the padding bit and the channel
//! mode. Its length follows from the bit rate, the sample rate and the padding. A file may start
//! with an ID3v2 tag and end with an ID3v1 one, which hold no audio.

const std = @import("std");

/// The versions of MPEG audio, which set the sample rates and the frames' lengths.
pub const Version = enum { mpeg1, mpeg2, mpeg2_5 };

/// A Layer III frame's header.
pub const Header = struct {
    version: Version,
    /// Bits a second.
    bit_rate: u32,
    /// Samples a second.
    rate: u32,
    padding: bool,
    channels: u8,

    /// The bit rates in kilobits a second by their index, MPEG-1's and the others', the first free
    /// and the last none.
    const bit_rates = std.EnumArray(Version, [16]u16).init(.{
        .mpeg1 = .{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 },
        .mpeg2 = .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
        .mpeg2_5 = .{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 },
    });

    /// The sample rates by their index, the last none.
    const rates = std.EnumArray(Version, [4]u32).init(.{
        .mpeg1 = .{ 44100, 48000, 32000, 0 },
        .mpeg2 = .{ 22050, 24000, 16000, 0 },
        .mpeg2_5 = .{ 11025, 12000, 8000, 0 },
    });

    /// The layer's bits for Layer III, and the channel mode's for one channel.
    const layer_three = 0b01;
    const mono = 0b11;

    /// The header `bytes` hold; null where they hold none of a Layer III frame with a set bit rate.
    pub fn parse(bytes: [4]u8) ?Header {
        const word = std.mem.readInt(u32, &bytes, .big);
        if (word >> 21 != 0x7FF) return null;
        const version: Version = switch (@as(u2, @truncate(word >> 19))) {
            0b11 => .mpeg1,
            0b10 => .mpeg2,
            0b00 => .mpeg2_5,
            0b01 => return null,
        };
        if (@as(u2, @truncate(word >> 17)) != layer_three) return null;
        const bit_rate = bit_rates.get(version)[@as(u4, @truncate(word >> 12))];
        const rate = rates.get(version)[@as(u2, @truncate(word >> 10))];
        if (bit_rate == 0 or rate == 0) return null;
        return .{
            .version = version,
            .bit_rate = @as(u32, bit_rate) * 1000,
            .rate = rate,
            .padding = word >> 9 & 1 == 1,
            .channels = if (@as(u2, @truncate(word >> 6)) == mono) 1 else 2,
        };
    }

    /// The frame's length in bytes, its header included: 144 bytes for each bit a sample of
    /// MPEG-1's, whose frames hold 1152 samples, and 72 for the others', whose frames hold 576.
    pub fn length(header: Header) usize {
        const per_bit: u32 = switch (header.version) {
            .mpeg1 => 144,
            .mpeg2, .mpeg2_5 => 72,
        };
        return per_bit * header.bit_rate / header.rate + @intFromBool(header.padding);
    }
};

/// A frame of a file, its header included.
pub const Frame = struct {
    header: Header,
    bytes: []const u8,
};

/// A file's frames, in order. Bytes that start no frame are passed over, as a decoder finds its
/// way back to the frames.
pub const Frames = struct {
    bytes: []const u8,
    at: usize,

    /// The frames of `bytes`, past an ID3v2 tag at its start.
    pub fn init(bytes: []const u8) Frames {
        return .{ .bytes = bytes, .at = id3v2Length(bytes) };
    }

    /// The next frame; null at the end, at an ID3v1 tag, or where a frame runs past the end.
    pub fn next(frames: *Frames) ?Frame {
        while (frames.at + 4 <= frames.bytes.len) : (frames.at += 1) {
            const rest = frames.bytes[frames.at..];
            if (std.mem.startsWith(u8, rest, id3v1_tag) and rest.len == id3v1_length) return null;
            const header = Header.parse(rest[0..4].*) orelse continue;
            const length = header.length();
            if (length > rest.len) return null;
            frames.at += length;
            return .{ .header = header, .bytes = rest[0..length] };
        }
        return null;
    }
};

/// An ID3v1 tag: `TAG` and 125 bytes more, at a file's end.
const id3v1_tag = "TAG";
const id3v1_length = 128;

/// The length of the ID3v2 tag `bytes` start with, its header and a footer included; 0 for none.
/// Its size is four bytes of seven bits each, the highest first, after `ID3`, its version and its
/// flags, whose bit 4 says a footer of ten bytes follows.
fn id3v2Length(bytes: []const u8) usize {
    const header = 10;
    if (bytes.len < header or !std.mem.startsWith(u8, bytes, "ID3")) return 0;
    var size: usize = 0;
    for (bytes[6..10]) |byte| size = size << 7 | (byte & 0x7F);
    const footer: usize = if (bytes[5] & 0x10 != 0) header else 0;
    return @min(bytes.len, header + size + footer);
}

test "Header.parse" {
    // A crew's line: MPEG-2, Layer III without a checksum, 64 kilobits a second at 22,050 Hz,
    // in joint stereo, whose frames run 208 bytes, or 209 with the padding.
    const header = Header.parse(.{ 0xFF, 0xF3, 0x80, 0x7C }).?;
    try std.testing.expectEqual(Version.mpeg2, header.version);
    try std.testing.expectEqual(64000, header.bit_rate);
    try std.testing.expectEqual(22050, header.rate);
    try std.testing.expectEqual(2, header.channels);
    try std.testing.expectEqual(208, header.length());
    try std.testing.expectEqual(209, Header.parse(.{ 0xFF, 0xF3, 0x82, 0x7C }).?.length());
    // MPEG-1 at 128 kilobits a second and 44,100 Hz, in one channel.
    const first = Header.parse(.{ 0xFF, 0xFB, 0x90, 0xC0 }).?;
    try std.testing.expectEqual(Version.mpeg1, first.version);
    try std.testing.expectEqual(1, first.channels);
    try std.testing.expectEqual(417, first.length());
    // No sync, Layer II, a free bit rate and the reserved version are none.
    try std.testing.expectEqual(null, Header.parse(.{ 0x7F, 0xF3, 0x80, 0x7C }));
    try std.testing.expectEqual(null, Header.parse(.{ 0xFF, 0xF5, 0x80, 0x7C }));
    try std.testing.expectEqual(null, Header.parse(.{ 0xFF, 0xF3, 0x00, 0x7C }));
    try std.testing.expectEqual(null, Header.parse(.{ 0xFF, 0xEB, 0x80, 0x7C }));
}

test Frames {
    // An ID3v2 tag of 6 bytes, a frame, two bytes that start none, a second frame, and an ID3v1
    // tag.
    const frame = [_]u8{ 0xFF, 0xF3, 0x80, 0x7C } ++ [_]u8{0} ** 204;
    const tag = "ID3" ++ [_]u8{ 4, 0, 0, 0, 0, 0, 6 } ++ [_]u8{0} ** 6;
    const file = tag ++ frame ++ [_]u8{ 1, 2 } ++ frame ++ "TAG" ++ [_]u8{0} ** 125;
    var frames: Frames = .init(file);
    try std.testing.expectEqual(16, frames.at);
    try std.testing.expectEqual(208, frames.next().?.bytes.len);
    const second = frames.next().?;
    try std.testing.expectEqual(@intFromPtr(&file[16 + 208 + 2]), @intFromPtr(second.bytes.ptr));
    try std.testing.expectEqual(null, frames.next());
    // A frame cut short is none.
    var short: Frames = .init(frame[0..100]);
    try std.testing.expectEqual(null, short.next());
}
