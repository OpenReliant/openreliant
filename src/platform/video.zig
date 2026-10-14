//! Decodes the movies' packets with FFmpeg's Bink decoders (`deps/ffmpeg`), for the engine's
//! replacement of Bink ([`engine/bink.zig`](../engine/bink.zig)'s `Codec`), and audio files with
//! FFmpeg's MP3, FLAC, Vorbis and Opus decoders. Each Bink decoder is set up the way FFmpeg's Bink
//! demuxer sets it up. The video decoder gets the file's signature as its codec tag and the
//! header's flags as extra data. An audio track's decoder gets the track's rate and channels, and
//! the file's signature as extra data. The MP3 and FLAC decoders read everything they need from
//! the data they are sent, and the Vorbis and Opus decoders get an Ogg stream's headers as extra
//! data.
//!
//! FFmpeg is built without threads, so it is only used from the game's thread.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("av");
const openreliant = @import("openreliant");
const bink = openreliant.engine.bink;
const math = openreliant.engine.surrender.math;
const wave = openreliant.wave;

/// The decoders. They keep no state between the streams they open. FFmpeg's warnings and errors go
/// to the log (`logs.route`).
pub const Decoders = struct {
    pub fn init() Decoders {
        return .{};
    }

    pub fn codec(decoders: *Decoders) bink.Codec {
        return .{ .context = decoders, .vtable = &.{
            .openVideo = openVideo,
            .openAudio = openAudio,
            .openFile = openFile,
            .picture = picture,
            .send = sendPacket,
            .receive = receive,
            .close = close,
        } };
    }
};

/// A stream's decoder, and the packet and frame it decodes through.
const Stream = struct {
    context: *c.AVCodecContext,
    packet: *c.AVPacket,
    frame: *c.AVFrame,

    fn of(stream: bink.Stream) *Stream {
        return @ptrCast(@alignCast(stream));
    }
};

fn openVideo(_: *anyopaque, video: bink.Video) bink.Error!bink.Stream {
    return open(.{ .video = video });
}

fn openAudio(_: *anyopaque, audio: bink.Audio) bink.Error!bink.Stream {
    return open(.{ .audio = audio });
}

fn openFile(_: *anyopaque, encoding: bink.Encoding) bink.Error!bink.Stream {
    return open(.{ .file = encoding });
}

/// What a stream's decoder is set up for.
const Setup = union(enum) {
    video: bink.Video,
    audio: bink.Audio,
    file: bink.Encoding,
};

/// Opens a decoder set up for `setup`. A Bink video decoder gets the video's flags as 4 bytes of
/// extra data, and a Bink audio decoder gets the movie's signature. A Vorbis or Opus decoder gets
/// the stream's headers.
fn open(setup: Setup) bink.Error!bink.Stream {
    const id: c.enum_AVCodecID = switch (setup) {
        .video => c.AV_CODEC_ID_BINKVIDEO,
        .audio => |audio| if (audio.dct) c.AV_CODEC_ID_BINKAUDIO_DCT else c.AV_CODEC_ID_BINKAUDIO_RDFT,
        .file => |encoding| switch (encoding) {
            .mp3 => c.AV_CODEC_ID_MP3,
            .flac => c.AV_CODEC_ID_FLAC,
            .vorbis => c.AV_CODEC_ID_VORBIS,
            .opus => c.AV_CODEC_ID_OPUS,
        },
    };
    const decoder = c.avcodec_find_decoder(id) orelse return error.Decoding;
    var context: ?*c.AVCodecContext = c.avcodec_alloc_context3(decoder) orelse return error.OutOfMemory;
    errdefer c.avcodec_free_context(&context);
    const set_up = context.?;
    switch (setup) {
        .video => |video| {
            const extradata = try extraData(set_up, 4);
            set_up.width = @intCast(video.width);
            set_up.height = @intCast(video.height);
            set_up.codec_tag = signature(video.revision);
            std.mem.writeInt(u32, extradata[0..4], @bitCast(video.flags), .little);
        },
        .audio => |audio| {
            const extradata = try extraData(set_up, 4);
            set_up.sample_rate = @intCast(audio.rate);
            c.av_channel_layout_default(&set_up.ch_layout, audio.channels);
            std.mem.writeInt(u32, extradata[0..4], signature(audio.revision), .little);
        },
        .file => |encoding| switch (encoding) {
            .mp3, .flac => {},
            .vorbis => |headers| @memcpy(try extraData(set_up, headers.len), headers),
            .opus => |headers| {
                @memcpy(try extraData(set_up, headers.len), headers);
                // The packets' timestamps count samples at Opus's rate. The decoder shifts them
                // past the pre-skip it drops, and logs a warning if it has no timebase for them.
                set_up.pkt_timebase = .{ .num = 1, .den = openreliant.ogg.opus_rate };
            },
        },
    }
    if (c.avcodec_open2(context, decoder, null) < 0) return error.Decoding;
    var packet: ?*c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
    errdefer c.av_packet_free(&packet);
    var frame: ?*c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
    errdefer c.av_frame_free(&frame);
    const stream = try std.heap.c_allocator.create(Stream);
    stream.* = .{ .context = set_up, .packet = packet.?, .frame = frame.? };
    return stream;
}

/// Allocates `size` bytes of extra data for a decoder, with the padding FFmpeg needs because it
/// reads past the end. The context frees them when it closes.
fn extraData(context: *c.AVCodecContext, size: usize) bink.Error![]u8 {
    const length = std.math.cast(c_int, size) orelse return error.Decoding;
    const extradata: [*]u8 = @ptrCast(c.av_mallocz(size + c.AV_INPUT_BUFFER_PADDING_SIZE) orelse return error.OutOfMemory);
    context.extradata = extradata;
    context.extradata_size = length;
    return extradata[0..size];
}

/// The Bink signature a movie of `revision` starts with, as a tag.
fn signature(revision: u8) c_uint {
    return std.mem.readInt(u32, &[4]u8{ 'B', 'I', 'K', revision }, .little);
}

/// Sends `packet` to the stream's decoder, copied into a buffer with the padding FFmpeg needs
/// because it reads past a packet's end. A FLAC file is sent whole, so a packet larger than FFmpeg
/// can take fails.
fn send(stream: *Stream, packet: []const u8) bink.Error!void {
    const size = std.math.cast(c_int, packet.len) orelse return error.Decoding;
    if (c.av_new_packet(stream.packet, size) < 0) return error.OutOfMemory;
    defer c.av_packet_unref(stream.packet);
    @memcpy(stream.packet.data[0..packet.len], packet);
    if (c.avcodec_send_packet(stream.context, stream.packet) < 0) return error.Decoding;
}

fn picture(_: *anyopaque, handle: bink.Stream, packet: []const u8) bink.Error!bink.Picture {
    const stream: *Stream = .of(handle);
    try send(stream, packet);
    if (c.avcodec_receive_frame(stream.context, stream.frame) < 0) return error.Decoding;
    const frame = stream.frame;
    const width: u32 = @intCast(frame.width);
    const height: u32 = @intCast(frame.height);
    const half = @divCeil(height, 2);
    var strides: [4]usize = undefined;
    for (&strides, frame.linesize[0..4]) |*stride, size| stride.* = @intCast(@max(size, 0));
    return .{
        .width = width,
        .height = height,
        .y = frame.data[0][0 .. strides[0] * height],
        .u = frame.data[1][0 .. strides[1] * half],
        .v = frame.data[2][0 .. strides[2] * half],
        .alpha = if (frame.format == c.AV_PIX_FMT_YUVA420P) frame.data[3][0 .. strides[3] * height] else null,
        .strides = strides,
    };
}

fn sendPacket(_: *anyopaque, handle: bink.Stream, packet: []const u8) bink.Error!void {
    try send(.of(handle), packet);
}

/// Decodes the next frame of what was sent and appends its samples to `pcm` as 16-bit. Returns
/// false once the decoder needs another packet.
fn receive(_: *anyopaque, handle: bink.Stream, gpa: Allocator, pcm: *std.ArrayList(i16)) bink.Error!bool {
    const stream: *Stream = .of(handle);
    const frame = stream.frame;
    const received = c.avcodec_receive_frame(stream.context, frame);
    if (received == -c.EAGAIN or received == c.AVERROR_EOF) return false;
    if (received < 0) return error.Decoding;
    defer c.av_frame_unref(frame);
    const count: usize = @intCast(frame.nb_samples);
    const channels: usize = @intCast(frame.ch_layout.nb_channels);
    const out = try pcm.addManyAsSlice(gpa, count * channels);
    switch (frame.format) {
        c.AV_SAMPLE_FMT_FLTP => for (0..channels) |channel| {
            const plane: [*]const f32 = @ptrCast(@alignCast(frame.extended_data[channel]));
            for (0..count) |at| out[at * channels + channel] = sample16(plane[at]);
        },
        c.AV_SAMPLE_FMT_FLT => {
            const interleaved: [*]const f32 = @ptrCast(@alignCast(frame.data[0]));
            for (out, interleaved[0..out.len]) |*to, from| to.* = sample16(from);
        },
        // FLAC's formats: 16-bit samples as they are, and deeper samples in the top bits of 32.
        c.AV_SAMPLE_FMT_S16 => {
            const interleaved: [*]const i16 = @ptrCast(@alignCast(frame.data[0]));
            @memcpy(out, interleaved[0..out.len]);
        },
        c.AV_SAMPLE_FMT_S32 => {
            const interleaved: [*]const i32 = @ptrCast(@alignCast(frame.data[0]));
            for (out, interleaved[0..out.len]) |*to, from| to.* = top16(from);
        },
        else => return error.Decoding,
    }
    return true;
}

/// Converts a 32-bit sample to 16 bits by keeping its top 16 bits, as FFmpeg's conversion does.
fn top16(level: i32) i16 {
    return @intCast(level >> 16);
}

/// Converts a float sample from -1 to 1 to 16 bits, rounding halves to even as FFmpeg's conversion
/// does (`lrintf`).
fn sample16(level: f32) i16 {
    const rounded = math.roundEven(level * wave.full_scale);
    return @intFromFloat(std.math.clamp(rounded, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn close(_: *anyopaque, handle: bink.Stream) void {
    const stream: *Stream = .of(handle);
    var context: ?*c.AVCodecContext = stream.context;
    var packet: ?*c.AVPacket = stream.packet;
    var frame: ?*c.AVFrame = stream.frame;
    c.avcodec_free_context(&context);
    c.av_packet_free(&packet);
    c.av_frame_free(&frame);
    std.heap.c_allocator.destroy(stream);
}

test sample16 {
    try std.testing.expectEqual(0, sample16(0));
    try std.testing.expectEqual(16384, sample16(0.5));
    // One step of the 16-bit scale as a float. Halves round to the even neighbour.
    const step: f32 = 1.0 / @as(f32, wave.full_scale);
    try std.testing.expectEqual(2, sample16(2.5 * step));
    try std.testing.expectEqual(-2, sample16(-2.5 * step));
    try std.testing.expectEqual(4, sample16(3.5 * step));
    try std.testing.expectEqual(32767, sample16(1.5));
    try std.testing.expectEqual(-32768, sample16(-1));
}

test "a damaged packet fails, and the decoder closes" {
    var decoders: Decoders = .init();
    const codec = decoders.codec();
    const video = try codec.openVideo(.{ .revision = 'f', .width = 16, .height = 16, .flags = .{} });
    defer codec.close(video);
    try std.testing.expectError(error.Decoding, codec.picture(video, &.{ 0xFF, 0xFF }));
    const audio = try codec.openAudio(.{ .revision = 'f', .rate = 22050, .channels = 2, .dct = false });
    var pcm: std.ArrayList(i16) = .empty;
    defer pcm.deinit(std.testing.allocator);
    try std.testing.expectError(error.Decoding, codec.samples(audio, &.{ 1, 2 }, std.testing.allocator, &pcm));
    codec.close(audio);
}

test "MP3 frames decode to their samples" {
    var decoders: Decoders = .init();
    const codec = decoders.codec();
    const stream = try codec.openFile(.mp3);
    defer codec.close(stream);
    // Two frames of MPEG-2 Layer III at 22,050 Hz in joint stereo, with only their headers set:
    // silence, 576 samples per channel in each frame.
    const frame = openreliant.mp3.testing.silent_frame;
    var pcm: std.ArrayList(i16) = .empty;
    defer pcm.deinit(std.testing.allocator);
    for (0..2) |_| try codec.samples(stream, &frame, std.testing.allocator, &pcm);
    try std.testing.expectEqual(2 * 576 * 2, pcm.items.len);
    for (pcm.items) |sample| try std.testing.expectEqual(0, sample);
}

test "a FLAC file decodes to a WAVE file of its samples" {
    const gpa = std.testing.allocator;
    var decoders: Decoders = .init();
    const codec = decoders.codec();
    // One frame of 192 samples per channel at 44,100 Hz, each channel at a constant level.
    const file = try openreliant.flac.testing.constant(gpa, 44100, &.{ 1000, -2000 }, 192);
    defer gpa.free(file);
    var whole: bink.AudioDecoding = try .beginFlac(codec, file);
    const decoded = try whole.complete(gpa);
    defer gpa.free(decoded);
    const parsed = try wave.Wave.parse(decoded);
    try std.testing.expectEqual(wave.Wave.Format.pcm, parsed.format);
    try std.testing.expectEqual(44100, parsed.rate);
    try std.testing.expectEqual(2, parsed.channels);
    try std.testing.expectEqual(192 * 2 * 2, parsed.data.len);
    for (0..192) |at| {
        try std.testing.expectEqual(1000, std.mem.readInt(i16, parsed.data[at * 4 ..][0..2], .little));
        try std.testing.expectEqual(-2000, std.mem.readInt(i16, parsed.data[at * 4 + 2 ..][0..2], .little));
    }
    // A frame at a time, as a mod's music is decoded over several of the game's frames: the
    // file's only frame, then the end.
    var decoding: bink.AudioDecoding = try .beginFlac(codec, file);
    try std.testing.expect(!try decoding.step(gpa, 1));
    try std.testing.expect(try decoding.step(gpa, 1));
    const stepped = try decoding.finish(gpa);
    defer gpa.free(stepped);
    try std.testing.expectEqualSlices(u8, decoded, stepped);
}

test "an Ogg file decodes to a WAVE file of its samples, up to where its last page says it ends" {
    const gpa = std.testing.allocator;
    var decoders: Decoders = .init();
    const codec = decoders.codec();
    // Opus: three packets of 20 ms of silence at 48,000 Hz in stereo, 960 samples per channel in
    // each. The decoder drops the pre-skip of 312 samples at the start, and the last page ends the
    // stream 400 samples before the end of the last packet.
    const frame = 960;
    const opus = try openreliant.ogg.testing.opus(gpa, 2, 312, 3, 3 * frame - 400);
    defer gpa.free(opus);
    var opus_decoding: bink.AudioDecoding = try .beginOgg(codec, gpa, opus);
    const from_opus = try opus_decoding.complete(gpa);
    defer gpa.free(from_opus);
    const opus_wave = try wave.Wave.parse(from_opus);
    try std.testing.expectEqual(48000, opus_wave.rate);
    try std.testing.expectEqual(2, opus_wave.channels);
    try std.testing.expectEqual((3 * frame - 400 - 312) * 2 * @sizeOf(i16), opus_wave.data.len);
    try std.testing.expect(std.mem.allEqual(u8, opus_wave.data, 0));
    // Vorbis: five packets of short blocks of silence at 22,050 Hz in one channel. The first
    // decodes to nothing and each of the others to 128 samples. The last page ends the stream
    // after 400 samples, 112 before the end of the last packet.
    const vorbis = try openreliant.ogg.testing.vorbis(gpa, 22050, 1, 5, 400);
    defer gpa.free(vorbis);
    var vorbis_decoding: bink.AudioDecoding = try .beginOgg(codec, gpa, vorbis);
    try std.testing.expect(!try vorbis_decoding.step(gpa, 4 * 128));
    try std.testing.expectEqual(4 * 128, vorbis_decoding.pcm.items.len);
    const from_vorbis = try vorbis_decoding.complete(gpa);
    defer gpa.free(from_vorbis);
    const vorbis_wave = try wave.Wave.parse(from_vorbis);
    try std.testing.expectEqual(22050, vorbis_wave.rate);
    try std.testing.expectEqual(1, vorbis_wave.channels);
    try std.testing.expectEqual(400 * @sizeOf(i16), vorbis_wave.data.len);
    try std.testing.expect(std.mem.allEqual(u8, vorbis_wave.data, 0));
}

test top16 {
    try std.testing.expectEqual(0, top16(0xFFFF));
    try std.testing.expectEqual(1, top16(0x10000));
    try std.testing.expectEqual(-1, top16(-1));
    try std.testing.expectEqual(std.math.maxInt(i16), top16(std.math.maxInt(i32)));
    try std.testing.expectEqual(std.math.minInt(i16), top16(std.math.minInt(i32)));
}
