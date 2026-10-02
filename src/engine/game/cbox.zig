//! `C:\lancer\game\cbox.cpp`: the radio's speech, the lines the pilots say, which come from
//! `ms_speech\msspeech.hog` as files of the game's own codec ([`voice.zig`](voice.zig)),
//! scrambled ([docs/formats/speech.md](../../../docs/formats/speech.md)). The game streams a line
//! through one sample of Miles's, decoding 2048 frames at a time as a timer asks for them
//! (`speech_timer`, `0x00462190`); OpenReliant decodes a line whole as it starts and plays it as
//! a sample (`Player`). **Unverified:** most of it lies before this file's known code
//! (`0x00462110` to `0x00462190`), from `0x00461EB0` on, after `camera.cpp`'s.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.radio);

const layout = @import("../../formats/layout.zig");
const scramble = @import("../../formats/scramble.zig");
const wave = @import("../../formats/wave.zig");
const math = @import("../surrender/math.zig");
const mss = @import("../mss.zig");
const loudness = mss.loudness;
const hog_snd = @import("hog_snd.zig");
const voice = @import("voice.zig");

/// The rate the speech plays at (`0x00461FA1`), which the game plays as stereo, each channel the
/// same.
pub const rate = 22050;

/// The key the files are scrambled with (`speech_unscramble`, `0x00462000`), repeating from the
/// stream's start.
pub const key = [4]u8{ 0xAB, 0x2D, 0x9A, 0xAA };

/// A speech file's header.
pub const Header = extern struct {
    /// The file's length past this field.
    length: u32,
    /// Its tag: `line_magic` or `scene_magic`.
    magic: [4]u8,
    /// The speech's size as 16-bit samples, in bytes: twice its samples.
    size: u32,

    /// The tags the game's speech files carry: the radio's lines, and the scenes, the `.box` files
    /// of the discs' archives, which the Reliant's rooms and the briefings play. The game plays a
    /// file whatever its tag.
    pub const line_magic = "CB00";
    pub const scene_magic = "CB97";

    /// Whether it carries one of the tags the game's files carry.
    pub fn tagged(header: Header) bool {
        return std.mem.eql(u8, &header.magic, line_magic) or std.mem.eql(u8, &header.magic, scene_magic);
    }

    comptime {
        assert(@sizeOf(Header) == 12);
    }
};

/// How many bytes at a stream's end the game leaves scrambled (`length - 0x18` unscrambled from
/// the header's end), and how many the files leave plain: they are scrambled to 8 bytes before
/// their end, which hold the stream's last bits.
pub const game_plain_tail = 16;
pub const plain_tail = 8;

/// A speech file: its header, and its stream unscrambled.
pub const Speech = struct {
    header: Header,
    stream: []const u8,

    /// `bytes`, a speech file as the archive holds it, unscrambled in place (`unscramble`). Null
    /// for a file too short for its header or not tagged as the game's are (`Header.tagged`), which
    /// the game does not check, so that what else an archive holds is passed over.
    pub fn parse(bytes: []u8) ?Speech {
        const header = layout.view(Header, bytes) catch return null;
        if (!header.tagged()) return null;
        const kept = header.*;
        unscramble(bytes);
        return .{ .header = kept, .stream = bytes[@sizeOf(Header)..] };
    }

    /// How many samples it plays: half its size (`0x00461F20`).
    pub fn samples(speech: Speech) usize {
        return speech.header.size >> 1;
    }
};

/// `speech_unscramble` (`0x00462000`): the stream of `bytes`, a speech file, XORed with `key`
/// (`scramble.xor`), unless the file's first bytes are `man`, which the game writes over a file's
/// length as it unscrambles it, or `CB`. OpenReliant leaves the length.
///
/// **Fix:** the game unscrambles all but the stream's last `game_plain_tail` bytes, where the
/// files are scrambled to their last `plain_tail`, so it reads a line's last 8 bytes scrambled,
/// which end the last frame in noise. OpenReliant unscrambles them.
pub fn unscramble(bytes: []u8) void {
    if (bytes.len < @sizeOf(Header)) return;
    if (std.mem.startsWith(u8, bytes, "man") or std.mem.startsWith(u8, bytes, "CB")) return;
    const stream = bytes[@sizeOf(Header)..];
    if (stream.len <= plain_tail) return;
    scramble.xor(stream[0 .. stream.len - plain_tail], key);
}

/// How the radio's lines sound, OpenReliant's own choices; `original` is the game's.
pub const Style = struct {
    peaks: Peaks = .rounded,
    room: Room = .cabin,
    levels: Levels = .matched,

    /// What becomes of the loudest peaks, which the recordings push past full scale in a few
    /// samples of every thousand.
    pub const Peaks = enum {
        /// **Improvement:** rounded off (`softClip`), so that they keep their shape.
        rounded,
        /// Cut flat at full scale, as the game cuts them, which crackles.
        cut,
    };

    /// Where the lines are heard.
    pub const Room = enum {
        /// **Improvement:** in the cockpit's cabin, as Betty's warnings are (`mss.Room.cockpit`).
        cabin,
        /// **Improvement:** in what surrounds the listener, as the scene's sounds are
        /// (`mss.Room.scene`): Enriquez's in person, in the briefing room.
        scene,
        /// Dry, as the game plays them.
        dry,
    };

    /// How loud a line plays beside the recording it follows (`Player.start`).
    pub const Levels = enum {
        /// **Improvement:** brought down to that recording's loudness where it is louder
        /// (`bringDown`), as Enriquez's last word is to the briefing's narration, whose
        /// recordings are mastered quieter.
        matched,
        /// As the recordings have them.
        recorded,
    };

    pub const original: Style = .{ .peaks = .cut, .room = .dry, .levels = .recorded };
};

/// **Improvement:** `samples`, at the speech's `rate`, brought down to the loudness `target`, in
/// LUFS, where they are louder, as ITU-R BS.1770 measures both (`mss.loudness`).
pub fn bringDown(gpa: Allocator, samples: []i16, target: f32) Allocator.Error!void {
    const measured = try loudness.integrated(gpa, samples, 1, rate) orelse return;
    if (measured <= target) return;
    const gain = std.math.pow(f32, 10, (target - measured) / 20);
    for (samples) |*value| value.* = @intFromFloat(@round(@as(f32, @floatFromInt(value.*)) * gain));
}

/// Where the rounding of the peaks begins, as a share of full scale (`Style.Peaks.rounded`).
pub const knee: f32 = 0.8;

/// `value`, a sample of the codec's, with its peaks rounded off: unchanged within `knee` of full
/// scale, and past it eased toward full scale by a hyperbolic tangent, which starts at the same
/// slope, so that a peak of any height comes to full scale at most.
pub fn softClip(value: f32) f32 {
    const full: f32 = std.math.maxInt(i16);
    const bend = knee * full;
    const over = @abs(value) - bend;
    if (over <= 0) return value;
    const room = full - bend;
    return std.math.sign(value) * (bend + room * std.math.tanh(over / room));
}

/// A sample as `speech_fetch` (`0x00462290`) and `speech_timer` make it of the codec's float: the
/// nearest whole number, halves to even, which the game gets by adding 12582912 (`0x004DC798`)
/// and reading the float's low bits, held to 16 bits; its peaks first rounded off where `peaks`
/// says (`softClip`).
///
/// **Fix:** the game reads 17 bits, so a peak past 65536 either way comes round wrong; OpenReliant
/// holds it.
pub fn sample(value: f32, peaks: Style.Peaks) i16 {
    const held = switch (peaks) {
        .rounded => softClip(value),
        .cut => value,
    };
    return @intCast(std.math.clamp(math.round(held), std.math.minInt(i16), std.math.maxInt(i16)));
}

/// The line decoded whole, in `gpa`: `Speech.samples` of it, a frame at a time
/// (`voice.Decoder.frame`), as `speech_fetch` decodes it as the sample plays, its peaks as
/// `peaks` has them.
pub fn decode(gpa: Allocator, speech: Speech, peaks: Style.Peaks) Allocator.Error![]i16 {
    const out = try gpa.alloc(i16, speech.samples());
    var decoder: voice.Decoder = .init(speech.stream);
    var at: usize = voice.frame_samples;
    for (out) |*value| {
        if (at == voice.frame_samples) {
            decoder.frame();
            at = 0;
        }
        value.* = sample(decoder.state.samples()[at], peaks);
        at += 1;
    }
    return out;
}

/// The speech as it plays through the speech sample (`speech_start`, `0x00461EB0`; `speech_stop`,
/// `0x00462070`; `speech_playing`, `0x004620A0`): the game keeps eight streams, of which its timer
/// plays the first playing; OpenReliant plays one line at a time, decoded whole into a WAVE file
/// the sample plays.
pub const Player = struct {
    /// The line playing, as the sample's file, kept while it plays.
    file: []u8 = &.{},

    /// `speech_start`: `speech` played through `sound`'s speech sample, the line playing ended:
    /// once, in the middle, at `rate`, as loud as the speech volume, the master volume and
    /// `volume`, 0 to 127, make it (`hog_snd.Sound.speechVolume`), sounding as `style` has it; where
    /// it follows a recording `follows` LUFS loud, matched to it as the style's levels have it.
    /// Whether it plays.
    ///
    /// Not ported: a line that loops (bit 0 of the game's flags), which nothing the game ships
    /// asks for.
    pub fn start(player: *Player, gpa: Allocator, sound: *hog_snd.Sound, speech: Speech, volume: i32, style: Style, follows: ?f32) bool {
        const driver = sound.driver orelse return false;
        const handle = sound.speech orelse return false;
        player.stop(gpa, sound);
        const samples = decode(gpa, speech, style.peaks) catch return false;
        defer gpa.free(samples);
        if (style.levels == .matched) if (follows) |target| bringDown(gpa, samples, target) catch return false;
        player.file = wave.pcm16(gpa, rate, 1, samples) catch return false;
        driver.initSample(handle);
        if (!driver.setSampleFile(handle, player.file)) {
            log.warn("a line of speech cannot be played", .{});
            return false;
        }
        driver.setSampleRoom(handle, switch (style.room) {
            .cabin => .cockpit,
            .scene => .scene,
            .dry => .none,
        });
        driver.setSampleLoopCount(handle, hog_snd.once);
        driver.setSamplePan(handle, hog_snd.centre);
        driver.setSamplePlaybackRate(handle, rate);
        driver.setSampleVolume(handle, sound.speechVolume(volume));
        driver.startSample(handle);
        return true;
    }

    /// `speech_stop`: the line playing ended, and its file let go of.
    pub fn stop(player: *Player, gpa: Allocator, sound: *hog_snd.Sound) void {
        if (sound.driver) |driver| if (sound.speech) |handle| {
            if (driver.sampleStatus(handle) != .done) driver.endSample(handle);
        };
        gpa.free(player.file);
        player.file = &.{};
    }

    /// The line playing stopped where it is (`AIL_stop_sample` on the speech sample), or where it
    /// was stopped so, going on (`AIL_resume_sample`), as the in-game options open and close over
    /// the loadout.
    pub fn pause(player: Player, sound: *hog_snd.Sound, paused: bool) void {
        if (player.file.len == 0) return;
        const driver = sound.driver orelse return;
        const handle = sound.speech orelse return;
        if (paused) {
            if (driver.sampleStatus(handle) == .playing) driver.stopSample(handle);
        } else if (driver.sampleStatus(handle) == .stopped) driver.resumeSample(handle);
    }

    /// `speech_playing`: whether a line plays.
    pub fn playing(player: Player, sound: *hog_snd.Sound) bool {
        _ = player;
        const driver = sound.driver orelse return false;
        const handle = sound.speech orelse return false;
        return driver.sampleStatus(handle) == .playing;
    }

    pub fn deinit(player: *Player, gpa: Allocator) void {
        gpa.free(player.file);
        player.file = &.{};
    }
};

/// A speech file for the tests: a header for `samples` samples over a stream of `stream_len`
/// zero bits, scrambled as the files are, in `gpa`.
pub fn testFile(gpa: Allocator, samples: u32, stream_len: usize) Allocator.Error![]u8 {
    const file = try gpa.alloc(u8, @sizeOf(Header) + stream_len);
    const header: Header = .{ .length = @intCast(file.len - 4), .magic = Header.line_magic.*, .size = samples * 2 };
    @memcpy(file[0..@sizeOf(Header)], std.mem.asBytes(&header));
    @memset(file[@sizeOf(Header)..], 0);
    unscramble(file);
    return file;
}

test unscramble {
    const gpa = std.testing.allocator;
    const file = try testFile(gpa, 100, 24);
    defer gpa.free(file);
    // Scrambled to 8 bytes before the end, the stream shows the key over its zeros, and plain
    // zeros after; unscrambled, all zeros.
    try std.testing.expectEqualSlices(u8, &(key ++ key), file[@sizeOf(Header)..][0..8]);
    try std.testing.expectEqualSlices(u8, &(key ++ key), file[@sizeOf(Header)..][8..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 8, file[@sizeOf(Header)..][16..24]);
    unscramble(file);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 24, file[@sizeOf(Header)..]);
    // Marked unscrambled, a file is left alone.
    var marked = "man\x00CB00\x00\x00\x00\x00abcdefghijklmnop".*;
    unscramble(&marked);
    try std.testing.expectEqualStrings("abcdefghijklmnop", marked[12..]);
}

test Speech {
    const gpa = std.testing.allocator;
    const file = try testFile(gpa, 1000, 40);
    defer gpa.free(file);
    const speech = Speech.parse(file).?;
    try std.testing.expectEqual(1000, speech.samples());
    try std.testing.expectEqual(40, speech.stream.len);
    try std.testing.expectEqual(0, speech.stream[0]);
    // A scene is read alike.
    const scene = try testFile(gpa, 10, 16);
    defer gpa.free(scene);
    scene[4..8].* = Header.scene_magic.*;
    try std.testing.expectEqual(10, Speech.parse(scene).?.samples());
    // Not a speech file.
    var other = "RIFF\x00\x00\x00\x00WAVEfmt ".*;
    try std.testing.expectEqual(null, Speech.parse(&other));
    var short = "CB".*;
    try std.testing.expectEqual(null, Speech.parse(&short));
}

test sample {
    try std.testing.expectEqual(0, sample(0.5, .cut));
    try std.testing.expectEqual(2, sample(1.5, .cut));
    try std.testing.expectEqual(-2, sample(-2.4, .cut));
    try std.testing.expectEqual(32767, sample(40000, .cut));
    try std.testing.expectEqual(-32768, sample(-70000, .cut));
    // Rounded off, a peak stays short of full scale.
    try std.testing.expectEqual(2, sample(1.5, .rounded));
    try std.testing.expect(sample(40000, .rounded) < 32767);
}

test softClip {
    // Within the knee, unchanged; past it, eased toward full scale, in order and either way alike.
    try std.testing.expectEqual(1000, softClip(1000));
    try std.testing.expectEqual(-26000, softClip(-26000));
    const bend = knee * 32767;
    try std.testing.expect(softClip(30000) > bend and softClip(30000) < 30000);
    try std.testing.expect(softClip(40000) > softClip(30000));
    try std.testing.expect(softClip(400000) <= 32767 and softClip(400000) > 32700);
    try std.testing.expectEqual(-softClip(40000), softClip(-40000));
}

test decode {
    const gpa = std.testing.allocator;
    // Zero bits: no pulses, so silence, as many samples as the header says.
    const file = try testFile(gpa, 1000, 400);
    defer gpa.free(file);
    const samples = try decode(gpa, Speech.parse(file).?, .rounded);
    defer gpa.free(samples);
    try std.testing.expectEqual(1000, samples.len);
    for (samples) |value| try std.testing.expectEqual(0, value);
}

test bringDown {
    const gpa = std.testing.allocator;
    // A loud tone brought down to the loudness it follows, 12 dB quieter; then left as it is
    // beside a louder one.
    var samples: [rate]i16 = undefined;
    for (&samples, 0..) |*value, n| {
        const t = @as(f32, @floatFromInt(n)) / rate;
        value.* = @intFromFloat(@round(16000 * @sin(2 * std.math.pi * 997 * t)));
    }
    const before = (try loudness.integrated(gpa, &samples, 1, rate)).?;
    try bringDown(gpa, &samples, before - 12);
    try std.testing.expectApproxEqAbs(before - 12, (try loudness.integrated(gpa, &samples, 1, rate)).?, 0.1);
    const quieter = samples;
    try bringDown(gpa, &samples, before);
    try std.testing.expectEqualSlices(i16, &quieter, &samples);
}

test Player {
    const gpa = std.testing.allocator;
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    defer sound.shutdown();
    var player: Player = .{};
    defer player.deinit(gpa);
    const file = try testFile(gpa, 2000, 400);
    defer gpa.free(file);
    const speech = Speech.parse(file).?;
    try std.testing.expect(!player.playing(sound));
    try std.testing.expect(player.start(gpa, sound, speech, hog_snd.loudest, .{}, null));
    try std.testing.expect(player.playing(sound));
    try std.testing.expect(player.file.len > 0);
    player.stop(gpa, sound);
    try std.testing.expect(!player.playing(sound));
    try std.testing.expectEqual(0, player.file.len);
}
