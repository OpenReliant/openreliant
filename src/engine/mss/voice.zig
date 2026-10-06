//! What a sample, a 3D sample and a stream share: a WAVE sound played from its frames at a rate of
//! its own, looped as often as asked, resampled to the output's rate by linear interpolation.

const std = @import("std");

const wave = @import("../../formats/wave.zig");

/// A handle's state, as `AIL_sample_status` reports it (Miles's `SMP_` values).
pub const Status = enum(u32) {
    /// Not allocated.
    free = 1,
    /// Finished, or never started: a handle ready for a sound.
    done = 2,
    playing = 4,
    /// Stopped part of the way, to be resumed.
    stopped = 8,
    _,

    pub fn format(status: Status, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (status) {
            _ => writer.print("status {d}", .{@backingInt(status)}),
            inline else => |named| writer.writeAll(@tagName(named)),
        };
    }
};

pub const Voice = struct {
    decoder: wave.Decoder,
    status: Status = .done,
    /// Frames a second.
    rate: u32,
    /// Times to play it, 0 for ever.
    loop_count: u32 = 1,
    /// The times it has played to the end.
    played: u32 = 0,
    /// Where a loop starts again, and where it ends: the whole sound unless a stream's loop block
    /// says otherwise.
    loop_start: u32 = 0,
    loop_end: u32,
    /// The two frames the output falls between, and how far between them.
    current: [2]f32 = .{ 0, 0 },
    following: [2]f32 = .{ 0, 0 },
    phase: f32 = 0,
    /// The frames are used up and nothing is left to loop.
    ended: bool = false,

    /// A voice for `file`, a WAVE sound, at its own rate, not yet playing.
    pub fn init(file: []const u8) (error{NotAWave} || wave.Decoder.Error)!Voice {
        const decoder: wave.Decoder = try .init(try wave.Wave.parse(file));
        return .{ .decoder = decoder, .rate = decoder.wave.rate, .loop_end = decoder.frames };
    }

    /// Starts it from the beginning.
    pub fn start(voice: *Voice) void {
        voice.startFrom(0);
    }

    /// Starts it from `frame`.
    pub fn startFrom(voice: *Voice, frame: u32) void {
        voice.decoder.seek(frame);
        voice.played = 0;
        voice.ended = false;
        voice.phase = 0;
        voice.current = voice.fetch();
        voice.following = voice.fetch();
        voice.status = .playing;
    }

    /// Stops it where it is, to be resumed, if it is playing (`AIL_stop_sample`,
    /// `AIL_pause_stream`).
    pub fn stop(voice: *Voice) void {
        if (voice.status == .playing) voice.status = .stopped;
    }

    /// Plays it on from where it stopped, if it did (`AIL_resume_sample`, `AIL_pause_stream`).
    pub fn resumePlaying(voice: *Voice) void {
        if (voice.status == .stopped) voice.status = .playing;
    }

    /// Adds `out.len` frames of it at the output's `rate`, each channel times its gain, stepping
    /// its pitch by `pitch`. It is done once the last frame has been played.
    pub fn mix(voice: *Voice, out: [][2]f32, output_rate: u32, gains: [2]f32, pitch: f32) void {
        if (voice.status != .playing) return;
        const step = @as(f32, @floatFromInt(voice.rate)) * pitch / @as(f32, @floatFromInt(output_rate));
        for (out) |*frame| {
            if (voice.ended and voice.phase >= 1) {
                voice.status = .done;
                return;
            }
            for (frame, voice.current, voice.following, gains) |*sum, a, b, gain| {
                sum.* += (a + (b - a) * voice.phase) * gain;
            }
            voice.phase += step;
            while (voice.phase >= 1 and !voice.ended) {
                voice.phase -= 1;
                voice.current = voice.following;
                voice.following = voice.fetch();
            }
        }
    }

    /// The next frame as `-1` to `1`, looping back to `loop_start` at `loop_end` while loops are
    /// left; silence once it has ended.
    fn fetch(voice: *Voice) [2]f32 {
        if (voice.ended) return .{ 0, 0 };
        if (voice.decoder.frame >= voice.loop_end) {
            voice.played += 1;
            if (voice.loop_count != 0 and voice.played >= voice.loop_count) {
                voice.ended = true;
                return .{ 0, 0 };
            }
            voice.decoder.seek(voice.loop_start);
        }
        const frame = voice.decoder.next() orelse {
            voice.ended = true;
            return .{ 0, 0 };
        };
        return .{ @as(f32, @floatFromInt(frame[0])) / 32768, @as(f32, @floatFromInt(frame[1])) / 32768 };
    }

    /// The frame at a byte offset into the sound's data, for a stream's loop block and position:
    /// a whole block at a time for IMA ADPCM.
    pub fn frameAt(voice: Voice, offset: u32) u32 {
        return voice.decoder.wave.frameAt(offset);
    }
};

test Voice {
    // Four frames at the output's own rate come out as they are.
    const file = comptime wave.testing.pcm(&std.mem.toBytes([4]i16{ 16384, -16384, 8192, 0 }));
    var voice: Voice = try .init(file);
    voice.start();
    var out: [6][2]f32 = @splat(.{ 0, 0 });
    voice.mix(&out, 22050, .{ 1, 0.5 }, 1);
    try std.testing.expectEqual([2]f32{ 0.5, 0.25 }, out[0]);
    try std.testing.expectEqual([2]f32{ -0.5, -0.25 }, out[1]);
    try std.testing.expectEqual([2]f32{ 0, 0 }, out[3]);
    try std.testing.expectEqual(Status.done, voice.status);

    // At half the output's rate each frame lasts two, the second between it and the next.
    voice.start();
    out = @splat(.{ 0, 0 });
    voice.mix(&out, 44100, .{ 1, 1 }, 1);
    try std.testing.expectEqual(@as(f32, 0.5), out[0][0]);
    try std.testing.expectEqual(@as(f32, 0), out[1][0]);
    try std.testing.expectEqual(@as(f32, -0.5), out[2][0]);

    // Looped twice, it plays eight frames and ends.
    voice.loop_count = 2;
    voice.start();
    var twice: [10][2]f32 = @splat(.{ 0, 0 });
    voice.mix(&twice, 22050, .{ 1, 1 }, 1);
    try std.testing.expectEqual(@as(f32, 0.5), twice[4][0]);
    try std.testing.expectEqual(@as(f32, 0), twice[8][0]);
    try std.testing.expectEqual(Status.done, voice.status);

    // Looping for ever, it goes on.
    voice.loop_count = 0;
    voice.start();
    var ever: [64][2]f32 = @splat(.{ 0, 0 });
    voice.mix(&ever, 22050, .{ 1, 1 }, 1);
    try std.testing.expectEqual(Status.playing, voice.status);
    try std.testing.expectEqual(@as(f32, 0.5), ever[60][0]);

    // Stopped, it stays so until it is resumed; one done is neither stopped nor resumed.
    voice.stop();
    try std.testing.expectEqual(Status.stopped, voice.status);
    voice.stop();
    try std.testing.expectEqual(Status.stopped, voice.status);
    voice.resumePlaying();
    try std.testing.expectEqual(Status.playing, voice.status);
    voice.status = .done;
    voice.stop();
    voice.resumePlaying();
    try std.testing.expectEqual(Status.done, voice.status);
}

test "Status.format" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("stopped", try std.fmt.bufPrint(&buffer, "{f}", .{Status.stopped}));
    try std.testing.expectEqualStrings("status 16", try std.fmt.bufPrint(&buffer, "{f}", .{@as(Status, @fromBackingInt(@intCast(16)))}));
}
