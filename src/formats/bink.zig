//! `.bik` movies: RAD Game Tools' Bink video, revision 1, which the game plays through
//! `BINKW32.DLL` (`engine/bink.zig`). A movie is a header, its audio tracks, a table of where each
//! frame lies, and the frames: each holds a packet of every audio track, then the frame's video.
//! OpenReliant reads the container itself; FFmpeg's decoders decode the packets (the platform's
//! `video.zig`).
//!
//! The game's movies are revisions `f`, `g` and `i`, 15 frames a second, at most 640 by 480.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("layout.zig");

pub const extension = ".bik";

pub const Error = error{ NotABink, Truncated, BadRate, TooManyTracks, BadIndex, BadFrame };

/// The header's fixed part.
pub const Header = extern struct {
    /// `BIK`, then the revision, `b` to `i` in Bink 1.
    signature: [3]u8,
    revision: u8,
    /// The file's size less the 8 bytes of these two fields.
    size: u32,
    frames: u32,
    /// The size of the largest frame, in bytes.
    largest_frame: u32,
    /// **Unknown.**
    _unknown_10: u32,
    width: u32,
    height: u32,
    /// Frames a second, as `rate` over `rate_divisor`.
    rate: u32,
    rate_divisor: u32,
    flags: VideoFlags,
    audio_tracks: u32,

    comptime {
        assert(@sizeOf(Header) == 0x2C);
    }
};

/// The header at the start of `bytes`, which must start as a Bink file does.
pub fn readHeader(bytes: []const u8) Error!*align(1) const Header {
    const header = try layout.view(Header, bytes);
    if (!std.mem.eql(u8, &header.signature, "BIK")) return error.NotABink;
    return header;
}

/// The video's flags, which the video decoder takes as its extra data.
pub const VideoFlags = packed struct(u32) {
    _unknown_0: u17 = 0,
    /// Grey, without colour.
    grey: bool = false,
    _unknown_18: u2 = 0,
    /// With a plane of alpha besides the colour.
    alpha: bool = false,
    _unknown_21: u11 = 0,
};

/// An audio track's rate and flags, after a word for each track that none of it reads (the largest
/// packet it decodes to).
pub const AudioTrack = extern struct {
    rate: u16,
    flags: AudioFlags,
};

pub const AudioFlags = packed struct(u16) {
    _unknown_0: u12 = 0,
    /// Coded by the discrete cosine transform rather than the real Fourier transform.
    dct: bool = false,
    stereo: bool = false,
    /// 16-bit samples, which every revision 1 movie has.
    sixteen_bit: bool = false,
    _unknown_15: bool = false,
};

/// The most audio tracks a movie is read with, as FFmpeg reads them.
pub const max_audio_tracks = 256;

/// A movie read in place from its file's `bytes`.
pub const Movie = struct {
    bytes: []const u8,
    header: *align(1) const Header,
    tracks: []align(1) const AudioTrack,
    /// Each frame's offset from the start of the file, with bit 0 set for a key frame. A frame
    /// runs to the next frame's offset, the last to the file's end.
    index: []align(1) const u32,

    pub fn parse(bytes: []const u8) Error!Movie {
        const header = try readHeader(bytes);
        if (header.rate == 0 or header.rate_divisor == 0) return error.BadRate;
        if (header.audio_tracks > max_audio_tracks) return error.TooManyTracks;
        const tracks_at = @sizeOf(Header) + header.audio_tracks * @sizeOf(u32);
        if (bytes.len < tracks_at) return error.Truncated;
        const tracks = try layout.array(AudioTrack, bytes[tracks_at..], header.audio_tracks);
        // The tracks' ids follow, which nothing reads, then the index.
        const index_at = tracks_at + header.audio_tracks * (@sizeOf(AudioTrack) + @sizeOf(u32));
        if (bytes.len < index_at) return error.Truncated;
        const index = try layout.array(u32, bytes[index_at..], header.frames);
        const movie: Movie = .{ .bytes = bytes, .header = header, .tracks = tracks, .index = index };
        for (0..index.len) |number| {
            const range = movie.extent(number);
            if (range.end <= range.start or range.end > bytes.len) return error.BadIndex;
        }
        return movie;
    }

    /// Frames a second.
    pub fn frameRate(movie: Movie) f64 {
        return @as(f64, @floatFromInt(movie.header.rate)) / @as(f64, @floatFromInt(movie.header.rate_divisor));
    }

    /// Frame `number`, counting from 0.
    pub fn frame(movie: Movie, number: usize) Error!Frame {
        const range = movie.extent(number);
        const bytes = movie.bytes[range.start..range.end];
        var at: usize = 0;
        for (movie.tracks) |_| {
            const size = (layout.view(u32, bytes[at..]) catch return error.BadFrame).*;
            if (size > bytes.len - at - @sizeOf(u32)) return error.BadFrame;
            at += @sizeOf(u32) + size;
        }
        return .{
            .keyframe = movie.index[number] & 1 != 0,
            .audio = .{ .bytes = bytes[0..at], .left = movie.tracks.len },
            .video = bytes[at..],
        };
    }

    fn extent(movie: Movie, number: usize) struct { start: usize, end: usize } {
        const end = if (number + 1 < movie.index.len) movie.index[number + 1] & ~@as(u32, 1) else movie.header.size +| 8;
        return .{ .start = movie.index[number] & ~@as(u32, 1), .end = end };
    }
};

/// A frame of a movie.
pub const Frame = struct {
    keyframe: bool,
    audio: AudioPackets,
    video: []const u8,
};

/// A frame's packet of each audio track, in the tracks' order.
pub const AudioPackets = struct {
    bytes: []const u8,
    left: usize,

    /// The next track's packet, or null once every track's is read. A packet holds the size of
    /// the samples it decodes to, in bytes (`u32`), then their coding; one of fewer than 4 bytes
    /// holds nothing.
    pub fn next(packets: *AudioPackets) ?[]const u8 {
        if (packets.left == 0) return null;
        packets.left -= 1;
        const size = std.mem.readInt(u32, packets.bytes[0..4], .little);
        const packet = packets.bytes[4..][0..size];
        packets.bytes = packets.bytes[4 + size ..];
        return packet;
    }
};

/// What the tests of the readers of movies share.
pub const testing = struct {
    /// A movie of `frames` frames for the tests, 8 by 6 at 15 a second, with one mono track whose
    /// packets are `audio`, and each frame's video its number, padded to a whole number of words as
    /// frames are: a frame starts at an even offset, as bit 0 of its entry in the index is taken.
    pub fn movie(buffer: []u8, frames: u8, audio: []const u8) []u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        // The one track's unused word, its rate and flags, and its id.
        const index_at = @sizeOf(Header) + @sizeOf(u32) + @sizeOf(AudioTrack) + @sizeOf(u32);
        const frame_size = std.mem.alignForward(usize, @sizeOf(u32) + audio.len + 1, @sizeOf(u32));
        const size = index_at + frames * @sizeOf(u32) + frames * frame_size;
        writer.writeStruct(Header{
            .signature = "BIK".*,
            .revision = 'f',
            .size = @intCast(size - 8),
            .frames = frames,
            .largest_frame = @intCast(frame_size),
            ._unknown_10 = frames,
            .width = 8,
            .height = 6,
            .rate = 15,
            .rate_divisor = 1,
            .flags = .{},
            .audio_tracks = 1,
        }, .little) catch unreachable;
        writer.writeInt(u32, 0, .little) catch unreachable;
        writer.writeStruct(AudioTrack{ .rate = 22050, .flags = .{ .sixteen_bit = true } }, .little) catch unreachable;
        writer.writeInt(u32, 0, .little) catch unreachable;
        for (0..frames) |number| {
            const at: u32 = @intCast(index_at + frames * @sizeOf(u32) + number * frame_size);
            writer.writeInt(u32, at | @intFromBool(number == 0), .little) catch unreachable;
        }
        for (0..frames) |number| {
            writer.writeInt(u32, @intCast(audio.len), .little) catch unreachable;
            writer.writeAll(audio) catch unreachable;
            writer.writeByte(@intCast(number)) catch unreachable;
            writer.splatByteAll(0, frame_size - (@sizeOf(u32) + audio.len + 1)) catch unreachable;
        }
        return writer.buffered();
    }
};

test Movie {
    var buffer: [256]u8 = undefined;
    const bytes = testing.movie(&buffer, 3, &.{ 8, 0, 0, 0, 0xAA });
    const movie: Movie = try .parse(bytes);
    try std.testing.expectEqual(3, movie.header.frames);
    try std.testing.expectEqual(15, movie.frameRate());
    try std.testing.expectEqual(22050, movie.tracks[0].rate);
    try std.testing.expect(movie.tracks[0].flags.sixteen_bit and !movie.tracks[0].flags.stereo);
    // Each frame's audio packet, then its video.
    for (0..3) |number| {
        var frame = try movie.frame(number);
        try std.testing.expectEqual(number == 0, frame.keyframe);
        try std.testing.expectEqualSlices(u8, &.{ 8, 0, 0, 0, 0xAA }, frame.audio.next().?);
        try std.testing.expectEqual(null, frame.audio.next());
        try std.testing.expectEqual(number, frame.video[0]);
    }
    // A track with nothing in a frame.
    var empty_buffer: [256]u8 = undefined;
    var empty = try (try Movie.parse(testing.movie(&empty_buffer, 1, &.{}))).frame(0);
    try std.testing.expectEqual(0, empty.audio.next().?.len);
    try std.testing.expectEqual(0, empty.video[0]);
}

test "a damaged movie is refused" {
    var buffer: [256]u8 = undefined;
    const bytes = testing.movie(&buffer, 2, &.{ 0, 0, 0, 0 });
    var riff = buffer;
    @memcpy(riff[0..4], "RIFF");
    try std.testing.expectError(error.NotABink, Movie.parse(riff[0..bytes.len]));
    try std.testing.expectError(error.Truncated, Movie.parse(bytes[0..20]));
    // A frame running past the file.
    try std.testing.expectError(error.BadIndex, Movie.parse(bytes[0 .. bytes.len - 1]));
    // An audio packet longer than its frame.
    var damaged = buffer;
    const first = std.mem.readInt(u32, damaged[@sizeOf(Header) + 12 ..][0..4], .little) & ~@as(u32, 1);
    std.mem.writeInt(u32, damaged[first..][0..4], 100, .little);
    const movie: Movie = try .parse(damaged[0..bytes.len]);
    try std.testing.expectError(error.BadFrame, movie.frame(0));
}
