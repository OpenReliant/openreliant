//! A mod's recordings, which replace the game's lines of speech, its music and its sounds: a WAVE
//! file used as it is, or a FLAC or MP3 file that FFmpeg's decoders turn into a WAVE file
//! (`bink.Codec`) ([#1173](https://github.com/OpenReliant/openreliant/issues/1173)). The radio's
//! lines, Enriquez's scenes, the music and the sound banks read them from a `Source`.
//!
//! **Improvement:** the original plays only its own files: its lines in its own speech codec, which
//! badly distorts long, clean speech such as a spoken briefing, and its music as WAVE files.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bigfile = @import("bigfile.zig");
const bink = @import("../bink.zig");
const flac = @import("../../formats/flac.zig");
const mp3 = @import("../../formats/mp3.zig");
const wave = @import("../../formats/wave.zig");

const log = std.log.scoped(.mods);

/// The formats of a mod's recording, in the order they're looked for.
pub const Kind = enum {
    wave,
    flac,
    mp3,

    /// The file extension of the format.
    pub fn extension(kind: Kind) []const u8 {
        return switch (kind) {
            .wave => wave.extension,
            .flac => flac.extension,
            .mp3 => mp3.extension,
        };
    }

    /// The length of the longest extension.
    const longest = longest: {
        var most: usize = 0;
        for (std.enums.values(Kind)) |kind| most = @max(most, kind.extension().len);
        break :longest most;
    };
};

/// The extensions of the game's files that a mod's recording replaces, besides the lines of speech,
/// which have none: the music's WAVE files (`hog_snd.Sound.playMusic`) and Enriquez's scenes
/// (`interface.rooms.speak`).
pub const replaced_extensions = [_][]const u8{ wave.extension, ".box" };

/// A mod's recording, as the mod's file holds it.
pub const Recording = struct {
    bytes: []u8,
    kind: Kind,
};

/// A recording in FLAC or MP3 decoded into a WAVE file a few frames at a time, so that a long piece
/// of music can decode over several of the game's frames (`bink.AudioDecoding`).
pub const Decoding = struct {
    audio: bink.AudioDecoding,
    /// The recording's file, which the decoder reads until it's done.
    file: []u8,

    /// Decodes at least `samples` more samples of each channel, or the rest of the recording.
    /// Returns whether the whole recording is decoded.
    pub fn step(decoding: *Decoding, gpa: Allocator, samples: usize) bink.Error!bool {
        return decoding.audio.step(gpa, samples);
    }

    /// The WAVE file of what was decoded, made in `gpa`. It frees the decoder and the recording's
    /// file, whether or not it succeeds.
    pub fn finish(decoding: *Decoding, gpa: Allocator) Allocator.Error![]u8 {
        defer gpa.free(decoding.file);
        return decoding.audio.finish(gpa);
    }

    /// Decodes the rest of the recording and makes its WAVE file (`finish`).
    pub fn complete(decoding: *Decoding, gpa: Allocator) bink.Error![]u8 {
        defer gpa.free(decoding.file);
        return decoding.audio.complete(gpa);
    }

    pub fn deinit(decoding: *Decoding, gpa: Allocator) void {
        decoding.audio.deinit(gpa);
        gpa.free(decoding.file);
    }
};

/// A mod's recording ready to play, or on its way.
pub const Opened = union(enum) {
    /// A WAVE file, as it is.
    wave: []u8,
    decoding: Decoding,
};

/// Where a mod's recordings come from: the mods that hold them, and what decodes those in FLAC or
/// MP3, if anything.
pub const Source = struct {
    mods: *const bigfile.Mods,
    codec: ?bink.Codec,

    /// No mods, and nothing to decode with.
    pub const none: Source = .{ .mods = &bigfile.Mods.none, .codec = null };

    /// Reads a mod's recording `name`, a name without an extension, into `gpa` as it is: the first
    /// of `name.wav`, `name.flac` and `name.mp3` that a mod has. Returns null if no mod has any of
    /// them, and also, with a warning, if that file can't be read.
    pub fn find(source: Source, gpa: Allocator, name: []const u8) ?Recording {
        var buffer: [bigfile.member_name_room + Kind.longest]u8 = undefined;
        for (std.enums.values(Kind)) |kind| {
            // A name too long for a mod's file is in no mod.
            const named = std.mem.print(&buffer, "{s}{s}", .{ name, kind.extension() }) catch return null;
            const found = source.mods.readFile(gpa, named) catch |err| {
                log.warn("can't read the recording {s}: {t}", .{ named, err });
                return null;
            };
            if (found) |bytes| return .{ .bytes = bytes, .kind = kind };
        }
        return null;
    }

    /// Opens `recording`, the recording `name` (`find`), taking its bytes: a WAVE file is ready as
    /// it is, and a FLAC or MP3 file starts decoding. Returns null, with a warning, if the file
    /// doesn't decode or there's nothing to decode it with.
    pub fn open(source: Source, gpa: Allocator, recording: Recording, name: []const u8) ?Opened {
        switch (recording.kind) {
            .wave => return .{ .wave = recording.bytes },
            inline .flac, .mp3 => |kind| {
                const decoder = source.codec orelse {
                    log.warn("the recording {s}{s} is left out: there's no decoder for it", .{ name, kind.extension() });
                    gpa.free(recording.bytes);
                    return null;
                };
                const begun = if (kind == .flac) bink.AudioDecoding.beginFlac(decoder, recording.bytes) else bink.AudioDecoding.beginMp3(decoder, recording.bytes);
                const audio = begun catch |err| {
                    log.warn("the recording {s}{s} is left out: {t}", .{ name, kind.extension(), err });
                    gpa.free(recording.bytes);
                    return null;
                };
                return .{ .decoding = .{ .audio = audio, .file = recording.bytes } };
            },
        }
    }

    /// Reads a mod's recording `name`, a name without an extension, as a WAVE file in `gpa`,
    /// decoded all at once (`find`, `open`). Returns null if no mod has it or it can't be used.
    pub fn read(source: Source, gpa: Allocator, name: []const u8) ?[]u8 {
        const recording = source.find(gpa, name) orelse return null;
        var decoding = switch (source.open(gpa, recording, name) orelse return null) {
            .wave => |bytes| return bytes,
            .decoding => |on_way| on_way,
        };
        return decoding.complete(gpa) catch |err| {
            log.warn("the recording {s}{s} is left out: {t}", .{ name, recording.kind.extension(), err });
            return null;
        };
    }
};

test "Source.open" {
    const gpa = std.testing.allocator;
    var decoders: bink.testing.Decoders = .{};
    const source: Source = .{ .mods = &bigfile.Mods.none, .codec = decoders.codec() };
    // A WAVE file is ready as it is.
    const ready = source.open(gpa, .{ .bytes = try gpa.dupe(u8, "a WAVE file"), .kind = .wave }, "line").?;
    defer gpa.free(ready.wave);
    // An MP3 file of two frames decodes a frame at a time.
    const frames = mp3.testing.silence(2);
    var opened = source.open(gpa, .{ .bytes = try gpa.dupe(u8, &frames), .kind = .mp3 }, "piece").?;
    try std.testing.expect(!try opened.decoding.step(gpa, 1));
    try std.testing.expect(!try opened.decoding.step(gpa, 1));
    try std.testing.expect(try opened.decoding.step(gpa, 1));
    const piece = try opened.decoding.finish(gpa);
    defer gpa.free(piece);
    try std.testing.expectEqual(22050, (try wave.Wave.parse(piece)).rate);
    try std.testing.expectEqual(0, decoders.streams);
    // A file that doesn't start decoding, and one without a decoder, are left out, their bytes
    // freed.
    try std.testing.expectEqual(null, source.open(gpa, .{ .bytes = try gpa.dupe(u8, "not MP3"), .kind = .mp3 }, "broken"));
    try std.testing.expectEqual(null, Source.none.open(gpa, .{ .bytes = try gpa.dupe(u8, &frames), .kind = .mp3 }, "piece"));
}

test "Source.read" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lossless = try flac.testing.constant(gpa, 22050, &.{7}, 16);
    defer gpa.free(lossless);
    try tmp.dir.createDirPath(io, "mods/a");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/both.wav", .data = "a WAVE file" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/both.flac", .data = lossless });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/lossless.flac", .data = lossless });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/lossless.mp3", .data = "an MP3 file" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/broken.flac", .data = "not a FLAC file" });
    const speech_file = mp3.testing.silence(2);
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/speech.mp3", .data = &speech_file });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    var decoders: bink.testing.Decoders = .{};
    const source: Source = .{ .mods = &mods, .codec = decoders.codec() };

    // A WAVE file comes first, as it is.
    const first = source.read(gpa, "both").?;
    defer gpa.free(first);
    try std.testing.expectEqualStrings("a WAVE file", first);
    // Then a FLAC file, decoded into a WAVE file at its rate and channels.
    const decoded = source.read(gpa, "LOSSLESS").?;
    defer gpa.free(decoded);
    const parsed = try wave.Wave.parse(decoded);
    try std.testing.expectEqual(22050, parsed.rate);
    try std.testing.expectEqual(1, parsed.channels);
    // Then an MP3 file, decoded the same way.
    const speech = source.read(gpa, "speech").?;
    defer gpa.free(speech);
    try std.testing.expectEqual(2, (try wave.Wave.parse(speech)).channels);
    try std.testing.expectEqual(0, decoders.streams);
    // A file that doesn't decode, a FLAC file without a decoder, and a name no mod has give null.
    try std.testing.expectEqual(null, source.read(gpa, "broken"));
    const undecoded: Source = .{ .mods = &mods, .codec = null };
    try std.testing.expectEqual(null, undecoded.read(gpa, "lossless"));
    try std.testing.expectEqual(null, source.read(gpa, "missing"));
}
