//! RAD's Bink (`BINKW32.DLL`), as far as the game calls it: a movie opened from its file, decoded
//! a frame at a time and copied into the screen, timed by its frame rate, with its sound played
//! through Miles (`BinkSetSoundSystem` with `BinkOpenMiles`). OpenReliant's stand-in: the
//! library is not the game's, and nothing of it is carried over but the calls' meanings. Each
//! function stands for the `Bink` call it names.
//!
//! OpenReliant reads the container itself (`formats/bink.zig`), and a `Codec` decodes the
//! packets: FFmpeg's decoders, in the platform (`platform/video.zig`). The stand-in decodes a
//! movie's sound whole as the movie opens, and plays it as a Miles stream, where Bink fills a Miles
//! sample as it plays.

const std = @import("std");
const Allocator = std.mem.Allocator;

const container = @import("../formats/bink.zig");
const wave = @import("../formats/wave.zig");
const mss = @import("mss.zig");

pub const picture = @import("bink/picture.zig");
pub const Picture = picture.Picture;
pub const Look = picture.Look;

pub const Error = container.Error || Allocator.Error || error{Decoding};

/// A stream a `Codec` decodes: a movie's video, or one of its audio tracks.
pub const Stream = *anyopaque;

/// What decodes a movie's packets.
pub const Codec = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        openVideo: *const fn (*anyopaque, Video) Error!Stream,
        openAudio: *const fn (*anyopaque, Audio) Error!Stream,
        /// The picture of the video's next packet, which holds until the next.
        picture: *const fn (*anyopaque, Stream, []const u8) Error!Picture,
        /// Appends the samples of the audio's next packet to `pcm`, 16-bit and interleaved.
        samples: *const fn (*anyopaque, Stream, []const u8, Allocator, *std.ArrayList(i16)) Error!void,
        close: *const fn (*anyopaque, Stream) void,
    };

    pub fn openVideo(codec: Codec, video: Video) Error!Stream {
        return codec.vtable.openVideo(codec.context, video);
    }
    pub fn openAudio(codec: Codec, audio: Audio) Error!Stream {
        return codec.vtable.openAudio(codec.context, audio);
    }
    pub fn picture(codec: Codec, stream: Stream, packet: []const u8) Error!Picture {
        return codec.vtable.picture(codec.context, stream, packet);
    }
    pub fn samples(codec: Codec, stream: Stream, packet: []const u8, gpa: Allocator, pcm: *std.ArrayList(i16)) Error!void {
        return codec.vtable.samples(codec.context, stream, packet, gpa, pcm);
    }
    pub fn close(codec: Codec, stream: Stream) void {
        codec.vtable.close(codec.context, stream);
    }
};

/// A movie's video, as its decoder is set up: the header's revision, size and flags.
pub const Video = struct {
    revision: u8,
    width: u32,
    height: u32,
    flags: container.VideoFlags,
};

/// One of a movie's audio tracks, as its decoder is set up.
pub const Audio = struct {
    revision: u8,
    rate: u32,
    channels: u8,
    dct: bool,
};

/// A rate a movie plays at: `frames` every `seconds`.
pub const Rate = struct {
    frames: u32,
    seconds: u32,

    /// The time frame `number`, from 0, is due after the first, in nanoseconds.
    fn due(rate: Rate, number: u32) u64 {
        return @as(u64, number) * rate.seconds * std.time.ns_per_s / rate.frames;
    }
};

/// What `BinkOpen` goes by, besides the file: the settings made before it.
pub const Options = struct {
    /// `BinkSetFrameRate`, with `BinkOpen`'s `BINKFRAMERATE`: the rate it plays at in place of its
    /// own.
    rate: ?Rate = null,
    /// `BinkSetSoundSystem(BinkOpenMiles, driver)`: the Miles driver its sound plays through; none
    /// plays it without sound.
    sound: ?mss.Driver = null,
    /// OpenReliant's: its improvements on the pictures `copyToBuffer` copies.
    look: Look = .{},
};

/// The volume Bink plays a movie's sound at unless told otherwise, full (`BinkSetVolume`), which
/// `play_bink_movie` sets (`0x004AB90F`).
pub const full_volume = 0x8000;

/// A movie open (`HBINK`).
pub const Bink = struct {
    gpa: Allocator,
    codec: Codec,
    /// The movie's file, which it keeps.
    file: []const u8,
    movie: container.Movie,
    video: Stream,
    /// Its size (`Width`, `Height`), its frames (`Frames`), and the frame `doFrame` decodes next,
    /// counting from 1 (`FrameNum`).
    width: u32,
    height: u32,
    frames: u32,
    frame_number: u32 = 1,
    rate: Rate,
    look: Look,
    /// The last frame decoded.
    picture: ?Picture = null,
    /// Where a picture is deblocked (`Look.deblock`): its planes, Y, U and V, one after another,
    /// each a row straight after another.
    deblocking: ?[]u8 = null,
    sound: ?Sound = null,
    /// When the first frame was decoded, from which the others are due, in nanoseconds; and when
    /// it was paused.
    start: ?u64 = null,
    paused_at: ?u64 = null,

    /// Its sound, as a WAVE file a Miles stream plays.
    const Sound = struct {
        driver: mss.Driver,
        stream: mss.Stream,
        file: []u8,
    };

    /// `BinkOpen`: the movie of `file`, which it takes, to be freed as it closes; its first frame
    /// next. Its first audio track's sound is decoded whole, and waits for the first frame.
    pub fn open(gpa: Allocator, codec: Codec, file: []const u8, options: Options) Error!Bink {
        errdefer gpa.free(file);
        const movie: container.Movie = try .parse(file);
        const header = movie.header;
        const video = try codec.openVideo(.{ .revision = header.revision, .width = header.width, .height = header.height, .flags = header.flags });
        errdefer codec.close(video);
        var bink: Bink = .{
            .gpa = gpa,
            .codec = codec,
            .file = file,
            .movie = movie,
            .video = video,
            .width = header.width,
            .height = header.height,
            .frames = header.frames,
            .rate = options.rate orelse .{ .frames = header.rate, .seconds = header.rate_divisor },
            .look = options.look,
        };
        if (options.look.deblock) {
            var levels: usize = 0;
            for (picture.planeSizes(header.width, header.height)) |size| levels += size[0] * size[1];
            bink.deblocking = try gpa.alloc(u8, levels);
        }
        errdefer if (bink.deblocking) |buffer| gpa.free(buffer);
        if (options.sound) |driver| if (movie.tracks.len > 0) {
            bink.sound = try openSound(gpa, codec, movie, driver);
        };
        return bink;
    }

    /// The first audio track's sound, decoded whole, as a stream of `driver`; none where it has
    /// none, or the driver has no stream left.
    fn openSound(gpa: Allocator, codec: Codec, movie: container.Movie, driver: mss.Driver) Error!?Sound {
        const track = movie.tracks[0];
        const channels: u8 = if (track.flags.stereo) 2 else 1;
        const audio = try codec.openAudio(.{ .revision = movie.header.revision, .rate = track.rate, .channels = channels, .dct = track.flags.dct });
        defer codec.close(audio);
        var pcm: std.ArrayList(i16) = .empty;
        defer pcm.deinit(gpa);
        for (0..movie.index.len) |number| {
            var frame = try movie.frame(number);
            const packet = frame.audio.next().?;
            // A packet of fewer than 4 bytes holds no samples.
            if (packet.len >= 4) try codec.samples(audio, packet, gpa, &pcm);
        }
        if (pcm.items.len == 0) return null;
        const file = try wave.pcm16(gpa, track.rate, channels, pcm.items);
        const stream = driver.openStream(file) orelse {
            gpa.free(file);
            return null;
        };
        // At full volume, as Bink plays it unless told otherwise (`full_volume`).
        driver.setStreamVolume(stream, mss.max_level);
        return .{ .driver = driver, .stream = stream, .file = file };
    }

    /// `BinkClose`.
    pub fn close(bink: *Bink) void {
        if (bink.sound) |sound| {
            sound.driver.closeStream(sound.stream);
            bink.gpa.free(sound.file);
        }
        if (bink.deblocking) |buffer| bink.gpa.free(buffer);
        bink.codec.close(bink.video);
        bink.gpa.free(bink.file);
        bink.* = undefined;
    }

    /// `BinkDoFrame`: decodes the frame `frame_number` names, at `now`. The first starts the
    /// movie's clock, and its sound.
    pub fn doFrame(bink: *Bink, now: u64) Error!void {
        if (bink.start == null) {
            bink.start = now;
            if (bink.sound) |sound| sound.driver.startStream(sound.stream);
        }
        const frame = try bink.movie.frame(bink.frame_number - 1);
        bink.picture = try bink.codec.picture(bink.video, frame.video);
    }

    /// `BinkCopyToBuffer`, in 32-bit RGBA: the last frame decoded into `rgba`, `pitch` bytes to a
    /// row, its top left corner at `at`, turned into colours by BT.601 in its limited range
    /// (`picture.convert`), deblocked first as its look has it.
    pub fn copyToBuffer(bink: Bink, rgba: []u8, pitch: usize, at: [2]usize) void {
        var shown = bink.picture orelse return;
        if (bink.deblocking) |buffer| shown = deblocked(shown, buffer);
        picture.convert(shown, rgba, pitch, at, bink.look.smooth_colour);
    }

    /// `decoded` with its planes copied into `buffer` and deblocked there (`picture.deblock`).
    fn deblocked(decoded: Picture, buffer: []u8) Picture {
        var planes: [3][]u8 = undefined;
        var used: usize = 0;
        const sizes = picture.planeSizes(decoded.width, decoded.height);
        for (&planes, [3][]const u8{ decoded.y, decoded.u, decoded.v }, decoded.strides[0..3], sizes) |*plane, from, stride, size| {
            const across, const down = size;
            plane.* = buffer[used..][0 .. across * down];
            used += plane.len;
            for (0..down) |row| @memcpy(plane.*[row * across ..][0..across], from[row * stride ..][0..across]);
            picture.deblock(plane.*, across, down, across);
        }
        var shown = decoded;
        shown.y, shown.u, shown.v = .{ planes[0], planes[1], planes[2] };
        shown.strides = .{ sizes[0][0], sizes[1][0], sizes[2][0], decoded.strides[3] };
        return shown;
    }

    /// `BinkNextFrame`: the next frame next.
    pub fn nextFrame(bink: *Bink) void {
        bink.frame_number = @min(bink.frame_number + 1, bink.frames);
    }

    /// `BinkGoto`, at `now`: frame `number` next, due a frame from now, decoded from the frames
    /// before it, which are decoded again unseen from the last key frame before it. The game goes
    /// back so to a looping movie's second frame (`BINKGOTOQUICK`), first putting back the
    /// pictures it kept of the first, and on to the last frame of a way in the player skips.
    pub fn goto(bink: *Bink, number: u32, now: u64) Error!void {
        const next = std.math.clamp(number, 1, bink.frames);
        if (next > 1) {
            const before = next - 2;
            var from = before;
            while (from > 0 and !(try bink.movie.frame(from)).keyframe) from -= 1;
            for (from..before + 1) |index| {
                const frame = try bink.movie.frame(index);
                bink.picture = try bink.codec.picture(bink.video, frame.video);
            }
        }
        bink.frame_number = next;
        bink.start = (now + bink.rate.due(1)) -| bink.rate.due(next - 1);
    }

    /// `BinkWait`: whether the frame `frame_number` names is not yet due at `now`, which it never
    /// is while paused. The first frame is due at once.
    pub fn wait(bink: Bink, now: u64) bool {
        if (bink.paused_at != null) return true;
        const start = bink.start orelse return false;
        return now < start + bink.rate.due(bink.frame_number - 1);
    }

    /// `BinkPause`: stops the movie at `now`, its sound too, or plays it on from where it stopped.
    pub fn pause(bink: *Bink, paused: bool, now: u64) void {
        if (paused == (bink.paused_at != null)) return;
        if (paused) {
            bink.paused_at = now;
        } else {
            if (bink.start) |*start| start.* += now - bink.paused_at.?;
            bink.paused_at = null;
        }
        if (bink.sound) |sound| sound.driver.pauseStream(sound.stream, paused);
    }

    /// `BinkSetVolume`: its sound's volume, `full_volume` for full and up to twice that, which
    /// Miles plays at its loudest.
    pub fn setVolume(bink: Bink, volume: u32) void {
        const sound = bink.sound orelse return;
        const level = @min(@as(u64, volume) * mss.max_level / full_volume, mss.max_level);
        sound.driver.setStreamVolume(sound.stream, @intCast(level));
    }

    /// Not Bink's: its sound heard in `room`, as a movie's on a screen of the scene is.
    pub fn setRoom(bink: Bink, room: mss.Room) void {
        const sound = bink.sound orelse return;
        sound.driver.setStreamRoom(sound.stream, room);
    }

    /// Not Bink's: its sound's integrated loudness, in LUFS (`mss.loudness`), measured as it is
    /// asked for; null where it has no sound playing, or its sound is silence.
    pub fn loudness(bink: Bink) Allocator.Error!?f32 {
        const sound = bink.sound orelse return null;
        const decoded = wave.Wave.parse(sound.file) catch return null;
        const samples = std.mem.bytesAsSlice(i16, decoded.data);
        return mss.loudness.integrated(bink.gpa, samples, decoded.channels, decoded.rate);
    }
};

/// What the tests of Bink and of what plays it share.
pub const testing = struct {
    /// A codec for the tests: each picture the movie's size, at most 8 by 6, and grey, its level
    /// of Y 16 more than 16 times the video packet's first byte (in `container.testing.movie`, its
    /// frame's number); each audio packet's bytes past the size as samples. It counts the pictures
    /// it makes, and the streams open.
    pub const Decoders = struct {
        width: u32 = 0,
        height: u32 = 0,
        y: [48]u8 = undefined,
        chroma: [12]u8 = @splat(128),
        pictures: u32 = 0,
        streams: u8 = 0,

        pub fn codec(test_codec: *Decoders) Codec {
            return .{ .context = test_codec, .vtable = &.{
                .openVideo = openVideo,
                .openAudio = openAudio,
                .picture = pictureOf,
                .samples = samples,
                .close = close,
            } };
        }

        fn of(context: *anyopaque) *Decoders {
            return @ptrCast(@alignCast(context));
        }
        fn openVideo(context: *anyopaque, video: Video) Error!Stream {
            const test_codec = of(context);
            test_codec.width, test_codec.height = .{ video.width, video.height };
            test_codec.streams += 1;
            return context;
        }
        fn openAudio(context: *anyopaque, _: Audio) Error!Stream {
            of(context).streams += 1;
            return context;
        }
        fn pictureOf(context: *anyopaque, _: Stream, packet: []const u8) Error!Picture {
            const test_codec = of(context);
            test_codec.pictures += 1;
            test_codec.y = @splat(@intCast(16 + 16 * @as(u32, packet[0])));
            const half = (test_codec.width + 1) / 2;
            return .{ .width = test_codec.width, .height = test_codec.height, .y = &test_codec.y, .u = &test_codec.chroma, .v = &test_codec.chroma, .strides = .{ test_codec.width, half, half, 0 } };
        }
        fn samples(_: *anyopaque, _: Stream, packet: []const u8, gpa: Allocator, pcm: *std.ArrayList(i16)) Error!void {
            for (packet[4..]) |byte| try pcm.append(gpa, byte);
        }
        fn close(context: *anyopaque, _: Stream) void {
            of(context).streams -= 1;
        }
    };
};

test Bink {
    const gpa = std.testing.allocator;
    var decoders: testing.Decoders = .{};
    var buffer: [256]u8 = undefined;
    // Three frames, each a level 16 above the last, from black.
    const bytes = container.testing.movie(&buffer, 3, &.{ 4, 0, 0, 0, 7, 9 });
    var bink: Bink = try .open(gpa, decoders.codec(), try gpa.dupe(u8, bytes), .{});
    defer bink.close();
    try std.testing.expectEqual(3, bink.frames);
    try std.testing.expectEqual(1, bink.frame_number);

    // The first frame is due at once, the next a fifteenth of a second after.
    const start = 1_000_000_000;
    try std.testing.expect(!bink.wait(start));
    try bink.doFrame(start);
    var rgba: [10 * 8 * 4]u8 = @splat(0xAA);
    bink.copyToBuffer(&rgba, 10 * 4, .{ 1, 1 });
    // Black, at the corner given, with the rest left as it was.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0xFF }, rgba[(10 + 1) * 4 ..][0..4]);
    try std.testing.expectEqual(0xAA, rgba[0]);
    bink.nextFrame();
    try std.testing.expect(bink.wait(start + std.time.ns_per_s / 15 - 1));
    try std.testing.expect(!bink.wait(start + std.time.ns_per_s / 15));

    // Paused, nothing is due; resumed, the frame is due as late as the pause was long.
    bink.pause(true, start + 10);
    try std.testing.expect(bink.wait(start + std.time.ns_per_s));
    bink.pause(false, start + 20);
    try std.testing.expect(bink.wait(start + std.time.ns_per_s / 15 + 9));
    try std.testing.expect(!bink.wait(start + std.time.ns_per_s / 15 + 10));

    // The last frame stays the last.
    bink.nextFrame();
    bink.nextFrame();
    try std.testing.expectEqual(3, bink.frame_number);
    try bink.doFrame(start + std.time.ns_per_s);
    try std.testing.expectEqual(48, bink.picture.?.y[0]);

    // Back to the second frame: the first decoded again, unseen, and the second due a frame on.
    const pictures = decoders.pictures;
    const later = start + 2 * std.time.ns_per_s;
    try bink.goto(2, later);
    try std.testing.expectEqual(pictures + 1, decoders.pictures);
    try std.testing.expectEqual(16, bink.picture.?.y[0]);
    try std.testing.expectEqual(2, bink.frame_number);
    try std.testing.expect(bink.wait(later + std.time.ns_per_s / 15 - 1));
    try std.testing.expect(!bink.wait(later + std.time.ns_per_s / 15));
}

test "a movie's sound plays as a stream" {
    const gpa = std.testing.allocator;
    var decoders: testing.Decoders = .{};
    var mixer: mss.Mixer = .init(22050);
    const driver = mixer.driver();
    var buffer: [256]u8 = undefined;
    const bytes = container.testing.movie(&buffer, 2, &.{ 6, 0, 0, 0, 7, 9 });
    var bink: Bink = try .open(gpa, decoders.codec(), try gpa.dupe(u8, bytes), .{ .sound = driver });
    // The two frames' samples, 7 and 9 each, in one WAVE file; the audio decoder is closed.
    const sound = bink.sound.?;
    const file = try wave.Wave.parse(sound.file);
    try std.testing.expectEqual(22050, file.rate);
    try std.testing.expectEqual(4, file.frameCount());
    try std.testing.expectEqual(1, decoders.streams);
    try std.testing.expectEqual(mss.Status.done, driver.streamStatus(sound.stream));
    try bink.doFrame(0);
    try std.testing.expectEqual(mss.Status.playing, driver.streamStatus(sound.stream));
    bink.pause(true, 5);
    try std.testing.expectEqual(mss.Status.stopped, driver.streamStatus(sound.stream));
    // All but silence, it has no loudness to be matched to.
    try std.testing.expectEqual(null, try bink.loudness());
    bink.close();
    try std.testing.expectEqual(0, decoders.streams);
}

test "Bink.loudness" {
    const gpa = std.testing.allocator;
    var decoders: testing.Decoders = .{};
    var mixer: mss.Mixer = .init(22050);
    var buffer: [256]u8 = undefined;
    // A sound that swings, and one the same but for its louder swing.
    const quiet_bytes = container.testing.movie(&buffer, 2, &.{ 8, 0, 0, 0, 64, 0, 64, 0 });
    var quiet: Bink = try .open(gpa, decoders.codec(), try gpa.dupe(u8, quiet_bytes), .{ .sound = mixer.driver() });
    defer quiet.close();
    const loud_bytes = container.testing.movie(&buffer, 2, &.{ 8, 0, 0, 0, 255, 0, 255, 0 });
    var loud: Bink = try .open(gpa, decoders.codec(), try gpa.dupe(u8, loud_bytes), .{ .sound = mixer.driver() });
    defer loud.close();
    const soft = (try quiet.loudness()).?;
    try std.testing.expectApproxEqAbs(soft + 20 * std.math.log10(@as(f32, 255.0 / 64.0)), (try loud.loudness()).?, 0.1);
    // Without its sound, none.
    var silent: Bink = try .open(gpa, decoders.codec(), try gpa.dupe(u8, loud_bytes), .{});
    defer silent.close();
    try std.testing.expectEqual(null, try silent.loudness());
}
