//! RIFF/WAVE sounds: the `.fat` banks' entries and the music in `music\`. The game hands them to
//! Miles whole, which plays them as they are; `Decoder` reads their frames for OpenReliant's mixer.
//!
//! The game's sounds are IMA ADPCM (format `0x11`) or PCM. An IMA ADPCM block starts with a
//! header for each channel, the block's first sample and the step index, then holds four bits a
//! sample, the channels taking turns every eight samples.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("layout.zig");
const riff = @import("riff.zig");

/// What a sound's WAVE header says.
pub const Wave = struct {
    format: Format,
    channels: u16,
    rate: u32,
    bits: u16,
    block_align: u16,
    /// For IMA ADPCM, the frames each block holds, from the format chunk's extension.
    frames_per_block: u16,
    /// Sample frames, from the `fact` chunk, or for PCM from the data length.
    frames: ?u32,
    data: []const u8,

    pub const Format = enum(u16) {
        pcm = 1,
        ima_adpcm = 0x11,
        _,

        pub fn format(tag: Format, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return switch (tag) {
                _ => writer.print("format {d}", .{@intFromEnum(tag)}),
                inline else => |named| writer.writeAll(@tagName(named)),
            };
        }
    };

    /// The chunks this module reads.
    const Chunk = enum { fmt, fact, data };

    /// The RIFF form of a sound.
    pub const form = "WAVE";

    /// The `fmt ` chunk's fields, as far as every format has them.
    pub const FormatChunk = extern struct {
        format: Format,
        channels: u16,
        rate: u32,
        byte_rate: u32,
        block_align: u16,
        bits: u16,

        comptime {
            assert(@sizeOf(FormatChunk) == 16);
        }
    };

    /// What follows the common fields for IMA ADPCM: the extension's size, then the frames a block
    /// holds.
    pub const AdpcmExtension = extern struct {
        size: u16,
        frames_per_block: u16,

        comptime {
            assert(@sizeOf(AdpcmExtension) == 4);
        }
    };

    /// What an IMA ADPCM block starts with for each channel: the block's first sample, and the
    /// step index the samples after it start from.
    pub const AdpcmHeader = extern struct {
        sample: i16,
        step_index: u8,
        _reserved: u8,

        comptime {
            assert(@sizeOf(AdpcmHeader) == 4);
        }
    };

    fn chunkOf(id: *const [4]u8) ?Chunk {
        const ids = std.StaticStringMap(Chunk).initComptime(.{
            .{ "fmt ", .fmt },
            .{ "fact", .fact },
            .{ "data", .data },
        });
        return ids.get(id);
    }

    pub fn parse(bytes: []const u8) error{NotAWave}!Wave {
        _ = riff.header(bytes, form) orelse return error.NotAWave;
        var wave: Wave = .{
            .format = @enumFromInt(0),
            .channels = 0,
            .rate = 0,
            .bits = 0,
            .block_align = 0,
            .frames_per_block = 0,
            .frames = null,
            .data = &.{},
        };
        var seen_format = false;

        var chunks: riff.Chunks = .{ .rest = bytes[@sizeOf(riff.Header)..] };
        // A tail too short for a chunk's header ends the chunks.
        while (chunks.rest.len >= @sizeOf(riff.ChunkHeader)) {
            const chunk = (chunks.next() catch return error.NotAWave) orelse break;
            const body = chunk.body;
            switch (chunkOf(&chunk.id) orelse continue) {
                .fmt => {
                    const fmt = layout.view(FormatChunk, body) catch return error.NotAWave;
                    wave.format = fmt.format;
                    wave.channels = fmt.channels;
                    wave.rate = fmt.rate;
                    wave.block_align = fmt.block_align;
                    wave.bits = fmt.bits;
                    if (layout.view(AdpcmExtension, body[@sizeOf(FormatChunk)..])) |extension| {
                        wave.frames_per_block = extension.frames_per_block;
                    } else |_| {}
                    seen_format = true;
                },
                .fact => if (layout.view(u32, body)) |frames| {
                    wave.frames = frames.*;
                } else |_| {},
                .data => wave.data = body,
            }
        }
        if (!seen_format) return error.NotAWave;
        if (wave.frames == null and wave.format == .pcm and wave.block_align != 0) {
            wave.frames = @intCast(wave.data.len / wave.block_align);
        }
        return wave;
    }

    /// Length in seconds, when the header says how many frames there are.
    pub fn seconds(wave: Wave) ?f64 {
        const frames = wave.frames orelse return null;
        if (wave.rate == 0) return null;
        return @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(wave.rate));
    }

    /// The frames the data holds: for IMA ADPCM, whole blocks and the part of the last, as far as
    /// the `fact` chunk allows. None where the header gives no block size.
    pub fn frameCount(wave: Wave) u32 {
        if (wave.block_align == 0) return 0;
        const held: u32 = switch (wave.format) {
            .ima_adpcm => blocks: {
                const whole: u32 = @intCast(wave.data.len / wave.block_align);
                const partial: u32 = @intCast(wave.adpcmFrames(wave.data.len % wave.block_align));
                break :blocks whole * wave.frames_per_block + partial;
            },
            else => @intCast(wave.data.len / wave.block_align),
        };
        return if (wave.frames) |stated| @min(stated, held) else held;
    }

    /// The frames the first `len` bytes of an IMA ADPCM block hold: the sample of each channel's
    /// header, then two a byte of the rest, which the channels share. None where they do not reach
    /// past the headers, or the header gives no channels.
    fn adpcmFrames(wave: Wave, len: usize) usize {
        const headers = @sizeOf(AdpcmHeader) * @as(usize, wave.channels);
        if (wave.channels == 0 or len <= headers) return 0;
        return 1 + (len - headers) * 2 / wave.channels;
    }

    /// The byte offset into the data at which frame `frame` starts, or for IMA ADPCM the block
    /// that holds it: what `frameAt` takes back to the frame.
    pub fn offsetOf(wave: Wave, frame: u32) u32 {
        const kept = @min(frame, wave.frameCount());
        return switch (wave.format) {
            .ima_adpcm => if (wave.frames_per_block == 0) 0 else kept / wave.frames_per_block * wave.block_align,
            else => kept * wave.block_align,
        };
    }

    /// The frame at a byte offset into the data, for a stream's loop block and position: a whole
    /// block at a time for IMA ADPCM.
    pub fn frameAt(wave: Wave, offset: u32) u32 {
        if (wave.block_align == 0) return 0;
        const frame = switch (wave.format) {
            .ima_adpcm => offset / wave.block_align * wave.frames_per_block,
            else => offset / wave.block_align,
        };
        return @min(frame, wave.frameCount());
    }
};

/// Reads a wave's frames in order, as 16-bit samples, the one channel of a mono sound in both. IMA
/// ADPCM is decoded as it goes, a block at a time, with no buffer of its own.
/// A WAVE file of 16-bit PCM in `gpa`: `samples`, `channels` to a frame, at `rate`, as the
/// game's sounds hold theirs (`Wave.parse` reads it back).
pub fn pcm16(gpa: std.mem.Allocator, rate: u32, channels: u16, samples: []const i16) std.mem.Allocator.Error![]u8 {
    const fmt_size = @sizeOf(riff.ChunkHeader) + @sizeOf(Wave.FormatChunk);
    const data_size: u32 = @intCast(samples.len * @sizeOf(i16));
    const file = try gpa.alloc(u8, @sizeOf(riff.Header) + fmt_size + @sizeOf(riff.ChunkHeader) + data_size);
    const riff_header: riff.Header = .{ .id = riff.Header.riff_id.*, .size = @intCast(file.len - 8), .form = Wave.form.* };
    const fmt_header: riff.ChunkHeader = .{ .id = "fmt ".*, .size = @sizeOf(Wave.FormatChunk) };
    const fmt: Wave.FormatChunk = .{
        .format = .pcm,
        .channels = channels,
        .rate = rate,
        .byte_rate = rate * channels * @sizeOf(i16),
        .block_align = channels * @sizeOf(i16),
        .bits = 16,
    };
    const data_header: riff.ChunkHeader = .{ .id = "data".*, .size = data_size };
    var at: usize = 0;
    for ([_][]const u8{ std.mem.asBytes(&riff_header), std.mem.asBytes(&fmt_header), std.mem.asBytes(&fmt), std.mem.asBytes(&data_header), std.mem.sliceAsBytes(samples) }) |part| {
        @memcpy(file[at..][0..part.len], part);
        at += part.len;
    }
    return file;
}

test pcm16 {
    const gpa = std.testing.allocator;
    const file = try pcm16(gpa, 22050, 1, &.{ 0, 1000, -1000, 32767 });
    defer gpa.free(file);
    // Read back as the sounds are.
    const sound = try Wave.parse(file);
    try std.testing.expectEqual(.pcm, sound.format);
    try std.testing.expectEqual(1, sound.channels);
    try std.testing.expectEqual(22050, sound.rate);
    try std.testing.expectEqual(4, sound.frameCount());
    var decoder: Decoder = try .init(sound);
    try std.testing.expectEqual([2]i16{ 0, 0 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ 1000, 1000 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ -1000, -1000 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ 32767, 32767 }, decoder.next().?);
    try std.testing.expectEqual(null, decoder.next());
}

pub const Decoder = struct {
    wave: Wave,
    frames: u32,
    /// The next frame's index.
    frame: u32 = 0,
    /// IMA ADPCM's running state for each channel, which each block's header resets.
    predictor: [2]i32 = .{ 0, 0 },
    step_index: [2]u8 = .{ 0, 0 },

    pub const Error = error{Unsupported};

    pub fn init(wave: Wave) Error!Decoder {
        if (wave.channels != 1 and wave.channels != 2) return error.Unsupported;
        if (wave.block_align == 0) return error.Unsupported;
        switch (wave.format) {
            .pcm => if (wave.bits != 8 and wave.bits != 16 or wave.block_align != wave.channels * wave.bits / 8) return error.Unsupported,
            .ima_adpcm => {
                // None where a block is no longer than its headers.
                const holds = wave.adpcmFrames(wave.block_align);
                if (wave.bits != 4 or holds == 0 or wave.frames_per_block != holds) return error.Unsupported;
            },
            _ => return error.Unsupported,
        }
        return .{ .wave = wave, .frames = wave.frameCount() };
    }

    /// The next frame, left and right, or null past the last.
    pub fn next(decoder: *Decoder) ?[2]i16 {
        if (decoder.frame >= decoder.frames) return null;
        const wave = decoder.wave;
        const channels = wave.channels;
        var out: [2]i16 = undefined;
        switch (wave.format) {
            .pcm => {
                const at = @as(usize, decoder.frame) * wave.block_align;
                for (0..channels) |c| out[c] = if (wave.bits == 8)
                    (@as(i16, wave.data[at + c]) - 128) << 8
                else
                    std.mem.readInt(i16, wave.data[at + 2 * c ..][0..2], .little);
            },
            .ima_adpcm => {
                const in_block = decoder.frame % wave.frames_per_block;
                const block = wave.data[@as(usize, decoder.frame / wave.frames_per_block) * wave.block_align ..];
                const header_size = @sizeOf(Wave.AdpcmHeader);
                for (0..channels) |c| {
                    if (in_block == 0) {
                        const header = std.mem.bytesToValue(Wave.AdpcmHeader, block[header_size * c ..][0..header_size]);
                        decoder.predictor[c] = header.sample;
                        decoder.step_index[c] = @min(header.step_index, max_step_index);
                    } else {
                        // Eight samples of each channel in turn, four bytes each, low nibble first.
                        const n = in_block - 1;
                        const group = header_size * channels + (n / group_samples) * group_size * channels + group_size * c;
                        const byte = block[group + (n % group_samples) / 2];
                        const nibble: u4 = @truncate(if (n % 2 == 0) byte else byte >> 4);
                        decoder.decodeNibble(c, @bitCast(nibble));
                    }
                    out[c] = @intCast(decoder.predictor[c]);
                }
            },
            _ => unreachable,
        }
        if (channels == 1) out[1] = out[0];
        decoder.frame += 1;
        return out;
    }

    /// Moves to `frame`, decoding from the start of its block for IMA ADPCM.
    pub fn seek(decoder: *Decoder, frame: u32) void {
        const target = @min(frame, decoder.frames);
        switch (decoder.wave.format) {
            .ima_adpcm => {
                decoder.frame = target - target % decoder.wave.frames_per_block;
                while (decoder.frame < target) _ = decoder.next();
            },
            else => decoder.frame = target,
        }
    }

    /// Samples of a channel an IMA ADPCM block keeps together after its headers, four bits each.
    const group_samples = 8;
    const group_size = group_samples / 2;

    /// One IMA ADPCM sample: the parts of the step it adds up, and whether it takes them away.
    const Nibble = packed struct(u4) {
        magnitude: Magnitude,
        negative: bool,

        const Magnitude = packed struct(u3) {
            quarter: bool,
            half: bool,
            whole: bool,
        };
    };

    /// IMA ADPCM's step for one sample: the difference the nibble's magnitude adds up to, of the
    /// step and its halves, signed by its sign.
    fn decodeNibble(decoder: *Decoder, channel: usize, nibble: Nibble) void {
        const step: i32 = steps[decoder.step_index[channel]];
        var difference = step >> 3;
        if (nibble.magnitude.whole) difference += step;
        if (nibble.magnitude.half) difference += step >> 1;
        if (nibble.magnitude.quarter) difference += step >> 2;
        if (nibble.negative) difference = -difference;
        decoder.predictor[channel] = std.math.clamp(decoder.predictor[channel] + difference, std.math.minInt(i16), std.math.maxInt(i16));
        const moved = @as(i32, decoder.step_index[channel]) + index_moves[@as(u3, @bitCast(nibble.magnitude))];
        decoder.step_index[channel] = @intCast(std.math.clamp(moved, 0, max_step_index));
    }

    const max_step_index = steps.len - 1;

    /// IMA ADPCM's step sizes, as the format defines them.
    const steps = [89]u16{
        7,     8,     9,     10,    11,    12,    13,    14,    16,    17,
        19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
        50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
        130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
        337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
        876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
        2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
        5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    };

    /// How far each magnitude moves the step index.
    const index_moves = [8]i8{ -1, -1, -1, -1, 2, 4, 6, 8 };
};

/// Builds WAVE files for tests.
pub const testing = struct {
    /// A chunk of `body`, with its header and its padding.
    pub const chunk = riff.testing.chunk;

    /// A WAVE file of `format`, its format chunk `fmt` (and `extension`), then `extra` chunks
    /// before the data.
    pub fn file(comptime fmt: Wave.FormatChunk, comptime extension: []const u8, comptime extra: []const u8, comptime data: []const u8) []const u8 {
        const body = Wave.form ++ chunk("fmt ", &std.mem.toBytes(fmt) ++ extension) ++ extra ++ chunk("data", data);
        return chunk(riff.Header.riff_id, body);
    }

    /// Mono 16-bit PCM at 22,050 Hz.
    pub fn pcm(comptime data: []const u8) []const u8 {
        return file(.{ .format = .pcm, .channels = 1, .rate = 22050, .byte_rate = 44100, .block_align = 2, .bits = 16 }, "", "", data);
    }
};

test Wave {
    const pcm = try Wave.parse(comptime testing.pcm("\x00\x00\x01\x00\x02\x00\x03\x00"));
    try std.testing.expectEqual(Wave.Format.pcm, pcm.format);
    try std.testing.expectEqual(@as(?u32, 4), pcm.frames);
    try std.testing.expectEqual(4, pcm.frameCount());

    const fact = comptime testing.chunk("fact", &std.mem.toBytes(@as(u32, 22050)));
    const adpcm = try Wave.parse(comptime testing.file(
        .{ .format = .ima_adpcm, .channels = 1, .rate = 22050, .byte_rate = 11100, .block_align = 256, .bits = 4 },
        &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 505 }),
        fact,
        "\x00\x00",
    ));
    try std.testing.expectEqual(Wave.Format.ima_adpcm, adpcm.format);
    try std.testing.expectEqual(505, adpcm.frames_per_block);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), adpcm.seconds().?, 1e-9);
    // An offset falls on the start of its block, and a PCM one on its frame.
    try std.testing.expectEqual(0, adpcm.frameAt(255));
    try std.testing.expectEqual(2, pcm.frameAt(5));
    try std.testing.expectEqual(4, pcm.frameAt(1000));

    try std.testing.expectError(error.NotAWave, Wave.parse("RIFF\x04\x00\x00\x00AVI "));
}

test "offsetOf takes a frame back to its byte" {
    const data: [8192]u8 = @splat(0);
    // IMA ADPCM, stereo, 1024-byte blocks of 1017 frames, as the game's music is: a frame within a
    // block is at the block's start.
    const adpcm: Wave = .{ .format = .ima_adpcm, .channels = 2, .rate = 22050, .bits = 4, .block_align = 1024, .frames_per_block = 1017, .frames = null, .data = &data };
    try std.testing.expectEqual(2048, adpcm.offsetOf(2 * 1017 + 5));
    try std.testing.expectEqual(2 * 1017, adpcm.frameAt(adpcm.offsetOf(2 * 1017 + 5)));
    // 16-bit PCM in stereo: four bytes a frame.
    const pcm: Wave = .{ .format = .pcm, .channels = 2, .rate = 44100, .bits = 16, .block_align = 4, .frames_per_block = 0, .frames = null, .data = &data };
    try std.testing.expectEqual(40, pcm.offsetOf(10));
    try std.testing.expectEqual(10, pcm.frameAt(pcm.offsetOf(10)));
    // Past the end, the last frame's.
    try std.testing.expectEqual(data.len, pcm.offsetOf(1 << 20));
}

test "Decoder reads PCM" {
    var decoder: Decoder = try .init(try Wave.parse(comptime testing.pcm("\x00\x00\x01\x00\xff\xff")));
    try std.testing.expectEqual([2]i16{ 0, 0 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ 1, 1 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ -1, -1 }, decoder.next().?);
    try std.testing.expectEqual(null, decoder.next());
    decoder.seek(1);
    try std.testing.expectEqual([2]i16{ 1, 1 }, decoder.next().?);

    // Eight-bit samples are unsigned, around 128.
    const eight = comptime testing.file(.{ .format = .pcm, .channels = 1, .rate = 11025, .byte_rate = 11025, .block_align = 1, .bits = 8 }, "", "", "\x80\xff\x00");
    var bytes: Decoder = try .init(try Wave.parse(eight));
    try std.testing.expectEqual([2]i16{ 0, 0 }, bytes.next().?);
    try std.testing.expectEqual([2]i16{ 127 << 8, 127 << 8 }, bytes.next().?);
    try std.testing.expectEqual([2]i16{ -128 << 8, -128 << 8 }, bytes.next().?);
}

test "Decoder reads IMA ADPCM" {
    // One mono block of 9 frames: the header's sample, 100, at step index 0, then 0x7, 0x7 and
    // 0xF: 7 adds the step and both its halves, 0xF takes them away, and each 7 raises the index
    // by 8.
    const block = [_]u8{ 100, 0, 0, 0, 0x77, 0x0F, 0x00, 0x00 };
    const fmt: Wave.FormatChunk = .{ .format = .ima_adpcm, .channels = 1, .rate = 22050, .byte_rate = 22050, .block_align = block.len, .bits = 4 };
    const file = comptime testing.file(fmt, &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 9 }), "", &block);
    var decoder: Decoder = try .init(try Wave.parse(file));
    try std.testing.expectEqual(9, decoder.frames);
    try std.testing.expectEqual(100, decoder.next().?[0]);
    try std.testing.expectEqual(111, decoder.next().?[0]);
    try std.testing.expectEqual(141, decoder.next().?[0]);
    try std.testing.expectEqual(78, decoder.next().?[0]);
    // Seeking starts again from the block's header.
    decoder.seek(2);
    try std.testing.expectEqual(141, decoder.next().?[0]);

    // A block too short for its frames is refused.
    const short = comptime testing.file(fmt, &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 505 }), "", &block);
    try std.testing.expectError(error.Unsupported, Decoder.init(try Wave.parse(short)));

    // A last block cut short holds its header's frame and two for each byte after it.
    const longer = comptime testing.file(fmt, &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 9 }), "", &(block ++ block[0..6].*));
    try std.testing.expectEqual(9 + 5, (try Wave.parse(longer)).frameCount());
}

test "a header without a block size or channels holds no frames" {
    var wave = try Wave.parse(comptime testing.pcm("\x00\x00"));
    wave.block_align = 0;
    try std.testing.expectEqual(0, wave.frameCount());
    try std.testing.expectEqual(0, wave.frameAt(2));
    wave.format = .ima_adpcm;
    try std.testing.expectEqual(0, wave.frameCount());
    wave.block_align = 8;
    wave.channels = 0;
    try std.testing.expectEqual(0, wave.frameCount());
}

test "Decoder takes the channels of IMA ADPCM in turn" {
    // A stereo block: both headers, then four bytes of the left, four of the right. The left
    // steps up by 11, the right down.
    const block = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{ 0x07, 0, 0, 0 } ++ [_]u8{ 0x0F, 0, 0, 0 };
    const fmt: Wave.FormatChunk = .{ .format = .ima_adpcm, .channels = 2, .rate = 22050, .byte_rate = 22050, .block_align = block.len, .bits = 4 };
    const file = comptime testing.file(fmt, &std.mem.toBytes(Wave.AdpcmExtension{ .size = 2, .frames_per_block = 9 }), "", &block);
    var decoder: Decoder = try .init(try Wave.parse(file));
    try std.testing.expectEqual([2]i16{ 0, 0 }, decoder.next().?);
    try std.testing.expectEqual([2]i16{ 11, -11 }, decoder.next().?);
}
