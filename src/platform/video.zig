//! The movies' packets, decoded by FFmpeg's Bink decoders (`deps/ffmpeg`) for the engine's
//! stand-in for Bink ([`engine/bink.zig`](../engine/bink.zig)'s `Codec`), and the frames of MP3
//! files by its MP3 decoder. Each Bink decoder is set up as FFmpeg's reader of the container, its
//! Bink demuxer, sets it up: the video's with the file's signature as its tag and the header's
//! flags as its extra data, an audio track's with its rate, its channels and the file's signature.
//! The MP3 decoder reads all it needs from the frames' headers.
//!
//! FFmpeg is built without threads, so it is used from the thread the game runs on alone.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("av");
const openreliant = @import("openreliant");
const bink = openreliant.engine.bink;

/// The decoders, which hold nothing between the streams they open.
pub const Decoders = struct {
    /// Quiets FFmpeg's messages: a packet it cannot decode fails the call, which says so.
    pub fn init() Decoders {
        c.av_log_set_level(c.AV_LOG_QUIET);
        return .{};
    }

    pub fn codec(decoders: *Decoders) bink.Codec {
        return .{ .context = decoders, .vtable = &.{
            .openVideo = openVideo,
            .openAudio = openAudio,
            .openMp3 = openMp3,
            .picture = picture,
            .samples = samples,
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

fn openMp3(_: *anyopaque) bink.Error!bink.Stream {
    return open(.mp3);
}

/// What a stream's decoder is set up for.
const Setup = union(enum) {
    video: bink.Video,
    audio: bink.Audio,
    mp3,
};

/// A decoder set up for `setup`. A Bink decoder's 4 bytes of extra data hold the video's flags, or
/// an audio track's movie's signature.
fn open(setup: Setup) bink.Error!bink.Stream {
    const id: c.enum_AVCodecID = switch (setup) {
        .video => c.AV_CODEC_ID_BINKVIDEO,
        .audio => |audio| if (audio.dct) c.AV_CODEC_ID_BINKAUDIO_DCT else c.AV_CODEC_ID_BINKAUDIO_RDFT,
        .mp3 => c.AV_CODEC_ID_MP3,
    };
    const decoder = c.avcodec_find_decoder(id) orelse return error.Decoding;
    var context: ?*c.AVCodecContext = c.avcodec_alloc_context3(decoder) orelse return error.OutOfMemory;
    errdefer c.avcodec_free_context(&context);
    const set_up = context.?;
    switch (setup) {
        .video => |video| {
            const extradata = try extraData(set_up);
            set_up.width = @intCast(video.width);
            set_up.height = @intCast(video.height);
            set_up.codec_tag = signature(video.revision);
            std.mem.writeInt(u32, extradata[0..4], @bitCast(video.flags), .little);
        },
        .audio => |audio| {
            const extradata = try extraData(set_up);
            set_up.sample_rate = @intCast(audio.rate);
            c.av_channel_layout_default(&set_up.ch_layout, audio.channels);
            std.mem.writeInt(u32, extradata[0..4], signature(audio.revision), .little);
        },
        .mp3 => {},
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

/// Four bytes of extra data for a Bink decoder, padded as FFmpeg reads past them, which the context
/// frees as it closes.
fn extraData(context: *c.AVCodecContext) bink.Error![*]u8 {
    const extradata: [*]u8 = @ptrCast(c.av_mallocz(4 + c.AV_INPUT_BUFFER_PADDING_SIZE) orelse return error.OutOfMemory);
    context.extradata = extradata;
    context.extradata_size = 4;
    return extradata;
}

/// The Bink signature a movie of `revision` starts with, as a tag.
fn signature(revision: u8) c_uint {
    return std.mem.readInt(u32, &[4]u8{ 'B', 'I', 'K', revision }, .little);
}

/// Hands `packet` to the stream's decoder, in a buffer padded as FFmpeg reads past a packet's end.
fn send(stream: *Stream, packet: []const u8) bink.Error!void {
    if (c.av_new_packet(stream.packet, @intCast(packet.len)) < 0) return error.OutOfMemory;
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
    const half = (height + 1) / 2;
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

fn samples(_: *anyopaque, handle: bink.Stream, packet: []const u8, gpa: Allocator, pcm: *std.ArrayList(i16)) bink.Error!void {
    const stream: *Stream = .of(handle);
    try send(stream, packet);
    const frame = stream.frame;
    while (true) {
        const received = c.avcodec_receive_frame(stream.context, frame);
        if (received == -c.EAGAIN or received == c.AVERROR_EOF) return;
        if (received < 0) return error.Decoding;
        defer c.av_frame_unref(frame);
        const count: usize = @intCast(frame.nb_samples);
        const channels: usize = @intCast(frame.ch_layout.nb_channels);
        const out = try pcm.addManyAsSlice(gpa, count * channels);
        if (frame.format == c.AV_SAMPLE_FMT_FLTP) {
            for (0..channels) |channel| {
                const plane: [*]const f32 = @ptrCast(@alignCast(frame.extended_data[channel]));
                for (0..count) |at| out[at * channels + channel] = sample16(plane[at]);
            }
        } else {
            const interleaved: [*]const f32 = @ptrCast(@alignCast(frame.data[0]));
            for (out, interleaved[0..out.len]) |*to, from| to.* = sample16(from);
        }
    }
}

/// A float sample from -1 to 1 as a 16-bit one, rounded to the nearest and a half to the even one,
/// as FFmpeg's conversion rounds (`lrintf`).
fn sample16(level: f32) i16 {
    const scaled = level * 32768;
    var rounded = @round(scaled);
    if (@abs(scaled - @trunc(scaled)) == 0.5 and @mod(rounded, 2) != 0) rounded -= std.math.sign(scaled);
    return @intFromFloat(std.math.clamp(rounded, -32768, 32767));
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
    // A half goes to the even one.
    try std.testing.expectEqual(2, sample16(2.5 / 32768.0));
    try std.testing.expectEqual(-2, sample16(-2.5 / 32768.0));
    try std.testing.expectEqual(4, sample16(3.5 / 32768.0));
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
    const stream = try codec.openMp3();
    defer codec.close(stream);
    // Two frames of MPEG-2 Layer III at 22,050 Hz in joint stereo, nothing but their headers set:
    // silence, 576 samples a channel each.
    const frame = [_]u8{ 0xFF, 0xF3, 0x80, 0x7C } ++ [_]u8{0} ** 204;
    var pcm: std.ArrayList(i16) = .empty;
    defer pcm.deinit(std.testing.allocator);
    for (0..2) |_| try codec.samples(stream, &frame, std.testing.allocator, &pcm);
    try std.testing.expectEqual(2 * 576 * 2, pcm.items.len);
    for (pcm.items) |sample| try std.testing.expectEqual(0, sample);
}
