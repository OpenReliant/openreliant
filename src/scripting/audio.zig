//! The `openreliant.audio` package ([#498](https://github.com/OpenReliant/openreliant/issues/498),
//! [#1178](https://github.com/OpenReliant/openreliant/issues/1178)) for player and menu scripts:
//! plays the game's standard sounds and mod sound files in 2D or 3D, controls the music, and plays
//! Betty's lines (`package`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const bink = engine.bink;
const mss = engine.mss;
const hog_snd = engine.game.hog_snd;
const betty = hog_snd.betty;
const sound3d = engine.game.sound3d;
const recordings = engine.game.recordings;
const executor = engine.game.executor;
const winmain = engine.game.winmain;
const Object = engine.hooks.Object;
const api = @import("api.zig");
const Call = api.Call;
const runtime = @import("runtime.zig");
const script = @import("script.zig");
const Presentation = @import("presentation.zig").Presentation;

/// What `openreliant.audio` holds.
pub const package = struct {
    pub const music = api.Field(?[]const u8, "The name of the piece of music playing, as passed to `play_music`; nil if no music plays.", struct {
        pub fn get(call: Call) ?[]const u8 {
            const sound = Presentation.hostOf(call).sound orelse return null;
            return hog_snd.pieceName(sound.pieceOn() orelse return null);
        }
    });

    pub const play_sound = api.Function("Plays `sound`: the number of a standard game sound (the menu and display sounds), or the name of a sound file in the script's mod, in any format mod sounds support. `options` is a table of settings, or a number for the volume. With `object` or `at`, the sound plays in 3D during a mission. Returns an ID for `stop_sound` and `sound_playing`, or nil if the sound doesn't play.", &.{ "sound", "options" }, playSound);
    pub const stop_sound = api.Function("Stops the sound with ID `id` if it is still playing. Does nothing if `id` is nil.", &.{"id"}, stopSound);
    pub const sound_playing = api.Function("Whether the sound with ID `id` is still playing, or paused with the game. False if `id` is nil.", &.{"id"}, soundPlaying);
    pub const play_music = api.Function("Plays the piece `name` from the game's music folder, or a mod's piece with that name, replacing the current music. The piece loops unless `options.loop` is false. With `options.after_fade`, it starts after the current music fades out, as mission music changes do.", &.{ "name", "options" }, playMusic);
    pub const fade_music = api.Function("Fades the music out, as the game does before a launch. A piece queued with `after_fade` starts when the fade ends.", &.{}, fadeMusic);
    pub const stop_music = api.Function("Stops the music at once, and drops any piece queued with `after_fade`.", &.{}, stopMusic);
    pub const say = api.Function("Betty says `line`. Returns whether she does.", &.{"line"}, bettySays);
};

/// The settings of `play_sound`.
pub const SoundOptions = struct {
    /// From 0 to 1, scaled by the effects volume.
    volume: f32 = 1,
    /// Factor for the sound's own rate, from `hog_snd.lowest_pitch` to `hog_snd.highest_pitch`.
    pitch: f32 = 1,
    /// Whether the sound loops until it's stopped.
    loop: bool = false,
    /// From -1 (left) to 1 (right), for a 2D sound.
    pan: f32 = 0,
    /// The object a 3D sound plays at and follows.
    object: ?Object = null,
    /// The world position a 3D sound plays at.
    at: ?@Vector(3, f32) = null,
    /// Minimum and maximum distance of a 3D sound: full volume within `near`, fading out to
    /// silence at `far`.
    near: f32 = sound3d.default_near,
    far: f32 = sound3d.default_far,
};

/// The settings of `play_music`.
pub const MusicOptions = struct {
    /// Whether the piece loops.
    loop: bool = true,
    /// Whether the piece starts after the current music fades out.
    after_fade: bool = false,
};

/// What `play_sound` plays: a standard game sound by number, or a file in the script's mod by name.
const Played = union(enum) {
    standard: u16,
    file: []const u8,
};

/// `audio.play_sound(sound, options)`.
fn playSound(call: Call, played: Played, given: ?union(enum) { volume: f32, options: SoundOptions }) ?u32 {
    const shown = Presentation.of(call);
    const host = Presentation.hostOf(call);
    const options: SoundOptions = if (given) |how| switch (how) {
        .volume => |volume| .{ .volume = volume },
        .options => |options| options,
    } else .{};
    if (!(options.pitch > 0)) call.raise("pitch must be more than 0", .{});
    if (!(options.near > 0) or !(options.far >= options.near)) call.raise("near must be more than 0, and far at least near", .{});
    const place: ?@FieldType(sound3d.Own, "at") = if (options.object) |object| place: {
        if (options.at != null) call.raise("give object or at, not both", .{});
        break :place .{ .object = object.slot() };
    } else if (options.at) |point| .{ .point = point } else null;
    const sound = host.sound orelse return null;
    const gpa = call.runtime().gpa;
    // The WAVE file to play, its priority, and its cache entry if it's a mod file.
    var cached: ?*Sounds.File = null;
    const file: []const u8, const priority: i32 = switch (played) {
        .standard => |index| standard: {
            const bank = sound.stdsmp orelse return null;
            if (index >= bank.entries.len) return null;
            break :standard .{ bank.sound(index) orelse return null, @intCast(bank.entries[index].priority) };
        },
        .file => |name| own: {
            const codec = if (sound.files) |files| files.recordings.codec else null;
            const loaded = shown.sounds.load(gpa, call.context, name, codec) catch |err| call.raise("sound {s}: {s}", .{ name, problem(err) });
            cached = loaded;
            break :own .{ loaded.wave, hog_snd.script_priority };
        },
    };
    shown.sounds.started.ensureUnusedCapacity(gpa, 1) catch call.raise("out of memory", .{});
    const starter = shown.sounds.next();
    const volume = std.math.clamp(options.volume, 0, 1);
    const pitch = std.math.clamp(options.pitch, hog_snd.lowest_pitch, hog_snd.highest_pitch);
    const loops: u32 = if (options.loop) hog_snd.forever else hog_snd.once;
    const voice = if (place) |at| sound3d.playOwn(sound, host.scene orelse return null, file, .{
        .at = at,
        .volume = volume,
        .pitch = pitch,
        .loops = loops,
        .near = options.near,
        .far = options.far,
        .starter = starter,
    }) else sound.playFile(file, .{
        .priority = priority,
        .volume = @intFromFloat(@round(volume * hog_snd.loudest)),
        .rate_factor = if (pitch != 1) pitch else null,
        .loops = loops,
        .pan = panOf(options.pan),
        .starter = starter,
    });
    _ = voice orelse return null;
    shown.sounds.sound = sound;
    shown.sounds.started.appendAssumeCapacity(.{ .starter = starter, .family = call.context.family, .wave = if (cached) |own| own.wave.ptr else null });
    if (cached) |own| own.played = @backingInt(starter);
    return @backingInt(starter);
}

/// Converts a pan from -1 (left) to 1 (right) into a voice's pan, from 0 to `hog_snd.rightmost`.
fn panOf(pan: f32) i32 {
    return @intFromFloat(@round((std.math.clamp(pan, -1, 1) + 1) / 2 * hog_snd.rightmost));
}

/// `audio.stop_sound(id)`.
fn stopSound(call: Call, id: ?u32) void {
    const sound = Presentation.hostOf(call).sound orelse return;
    sound.endStarted(@fromBackingInt(id orelse return));
}

/// `audio.sound_playing(id)`.
fn soundPlaying(call: Call, id: ?u32) bool {
    const sound = Presentation.hostOf(call).sound orelse return false;
    return sound.playingOf(@fromBackingInt(id orelse return false)) != null;
}

/// `audio.play_music(name, options)`.
fn playMusic(call: Call, name: []const u8, given: ?MusicOptions) void {
    const sound = Presentation.hostOf(call).sound orelse return;
    const options = given orelse MusicOptions{};
    const loops: u32 = if (options.loop) hog_snd.forever else hog_snd.once;
    executor.playPiece(sound, name, loops, if (options.after_fade) .{ .after_fade = sound.gameTicks() } else .now);
}

/// `audio.fade_music()`.
fn fadeMusic(call: Call) void {
    const sound = Presentation.hostOf(call).sound orelse return;
    sound.fadeMusic(winmain.music_fade_step, sound.gameTicks());
}

/// `audio.stop_music()`.
fn stopMusic(call: Call) void {
    const sound = Presentation.hostOf(call).sound orelse return;
    sound.stopMusic();
}

/// `audio.say(line)`.
fn bettySays(call: Call, line: betty.Line) bool {
    const sound = Presentation.hostOf(call).sound orelse return false;
    return betty.say(sound, line) != null;
}

/// Size of the cache of decoded mod sound files.
pub const max_sound_bytes = 64 << 20;

/// The script sounds: a cache of the mod sound files the scripts play, decoded into WAVE files on
/// first use, and the list of sounds the scripts started. When the cache is full, it evicts the
/// least recently played files that aren't playing.
pub const Sounds = struct {
    files: std.ArrayList(File) = .empty,
    /// Total size of the cached files.
    bytes: usize = 0,
    /// The sounds the scripts started that may still be playing.
    started: std.ArrayList(Started) = .empty,
    /// The ID of the last sound a script started.
    last: u32 = @backingInt(hog_snd.Starter.game),
    /// The sound system the script sounds play on, set when the first one plays.
    sound: ?*hog_snd.Sound = null,

    const File = struct {
        /// Index of the mod in `runtime.Runtime.mods`.
        mod: u16,
        name: []u8,
        wave: []u8,
        /// ID of the last sound that played it. The lowest is the least recently played.
        played: u32 = 0,

        fn deinit(file: File, gpa: Allocator) void {
            gpa.free(file.wave);
            gpa.free(file.name);
        }
    };

    const Started = struct {
        starter: hog_snd.Starter,
        family: script.Family,
        /// The cached WAVE file it plays, which stays cached while it plays; null for a standard
        /// sound.
        wave: ?[*]const u8,
    };

    /// Stops every script sound and frees the cache.
    pub fn deinit(sounds: *Sounds, gpa: Allocator) void {
        sounds.stop(null);
        for (sounds.files.items) |file| file.deinit(gpa);
        sounds.files.deinit(gpa);
        sounds.started.deinit(gpa);
        sounds.* = .{};
    }

    /// Returns the ID for the next script sound, which is never `.game`.
    fn next(sounds: *Sounds) hog_snd.Starter {
        sounds.last +%= 1;
        if (sounds.last == @backingInt(hog_snd.Starter.game)) sounds.last += 1;
        return @fromBackingInt(sounds.last);
    }

    /// Stops the sounds started by scripts of `family`, or every script sound if `family` is null.
    pub fn stop(sounds: *Sounds, family: ?script.Family) void {
        const sound = sounds.sound orelse return;
        for (sounds.started.items) |started| {
            if (family == null or family == started.family) sound.endStarted(started.starter);
        }
        sounds.forgetEnded();
    }

    /// Forgets the sounds that have ended.
    pub fn forgetEnded(sounds: *Sounds) void {
        const sound = sounds.sound orelse return;
        var kept: usize = 0;
        for (sounds.started.items) |started| {
            if (sound.playingOf(started.starter) == null) continue;
            sounds.started.items[kept] = started;
            kept += 1;
        }
        sounds.started.shrinkRetainingCapacity(kept);
    }

    /// Returns the cache entry for the file `name` of `context`'s mod. On first use, it reads the
    /// file, decodes it with `codec` and makes room for it (`makeRoom`).
    fn load(sounds: *Sounds, gpa: Allocator, context: *const runtime.Context, name: []const u8, codec: ?bink.Codec) !*File {
        for (sounds.files.items) |*file| {
            if (file.mod == context.mod and std.ascii.eqlIgnoreCase(file.name, name)) return file;
        }
        const kind = recordings.Kind.of(name) orelse return error.UnknownFormat;
        const bytes = try context.readModFile(gpa, name);
        const wave = try recordings.decode(codec, gpa, .{ .bytes = bytes, .kind = kind }, max_sound_bytes);
        errdefer gpa.free(wave);
        _ = try mss.voice.Voice.init(wave);
        try sounds.makeRoom(gpa, wave.len);
        const copied = try gpa.dupe(u8, name);
        errdefer gpa.free(copied);
        try sounds.files.append(gpa, .{ .mod = context.mod, .name = copied, .wave = wave });
        sounds.bytes += wave.len;
        return &sounds.files.items[sounds.files.items.len - 1];
    }

    /// Evicts the least recently played files until `needed` more bytes fit. Fails if the files
    /// still playing leave no room.
    fn makeRoom(sounds: *Sounds, gpa: Allocator, needed: usize) error{NoRoom}!void {
        while (sounds.bytes + needed > max_sound_bytes) {
            const file = sounds.files.swapRemove(sounds.stalest() orelse return error.NoRoom);
            sounds.bytes -= file.wave.len;
            file.deinit(gpa);
        }
    }

    /// The least recently played file that isn't playing.
    fn stalest(sounds: *const Sounds) ?usize {
        var found: ?usize = null;
        for (sounds.files.items, 0..) |file, index| {
            if (sounds.plays(file.wave)) continue;
            if (found) |oldest| if (sounds.files.items[oldest].played <= file.played) continue;
            found = index;
        }
        return found;
    }

    /// Whether a script sound is still playing `wave`.
    fn plays(sounds: *const Sounds, wave: []const u8) bool {
        const sound = sounds.sound orelse return false;
        for (sounds.started.items) |started| {
            if (started.wave == wave.ptr and sound.playingOf(started.starter) != null) return true;
        }
        return false;
    }
};

/// The message for an error with a mod sound file.
fn problem(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownFormat => "a sound must be a " ++ formats ++ " file",
        error.TooLarge => std.fmt.comptimePrint("it takes more than {d} MiB decoded", .{max_sound_bytes >> 20}),
        error.NoRoom => std.fmt.comptimePrint("the sounds still playing fill the {d} MiB sound cache", .{max_sound_bytes >> 20}),
        else => runtime.fileProblem(err) orelse recordings.problem(err),
    };
}

/// The extensions of the supported sound formats, for messages.
const formats = formats: {
    const kinds = std.enums.values(recordings.Kind);
    var text: []const u8 = "";
    for (kinds, 0..) |kind, at| {
        text = text ++ (if (at == 0) "" else if (at == kinds.len - 1) " or " else ", ") ++ kind.extension();
    }
    break :formats text;
};

test formats {
    try std.testing.expectEqualStrings(".wav, .flac, .mp3, .ogg or .opus", formats);
}

test panOf {
    try std.testing.expectEqual(0, panOf(-1));
    try std.testing.expectEqual(hog_snd.centre, panOf(0));
    try std.testing.expectEqual(hog_snd.rightmost, panOf(2));
}

test "Sounds evicts the least recently played file that isn't playing" {
    const gpa = std.testing.allocator;
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    var sounds: Sounds = .{ .sound = &speaker.sound };
    defer sounds.deinit(gpa);
    // Three files, played in the order b, c, a. c is still playing.
    for ([_][]const u8{ "a", "b", "c" }, [_]u32{ 3, 1, 2 }) |name, played| {
        const wave = try gpa.dupe(u8, hog_snd.testing.sound_file);
        try sounds.files.append(gpa, .{ .mod = 0, .name = try gpa.dupe(u8, name), .wave = wave, .played = played });
        sounds.bytes += wave.len;
    }
    const playing = sounds.files.items[2].wave;
    const starter = sounds.next();
    _ = speaker.sound.playFile(playing, .{ .priority = hog_snd.script_priority, .loops = hog_snd.forever, .starter = starter }).?;
    try sounds.started.append(gpa, .{ .starter = starter, .family = .player, .wave = playing.ptr });
    // Making room for one byte more than is free evicts b, the least recently played.
    try sounds.makeRoom(gpa, max_sound_bytes - sounds.bytes + 1);
    try std.testing.expectEqual(2, sounds.files.items.len);
    for (sounds.files.items) |file| try std.testing.expect(!std.mem.eql(u8, file.name, "b"));
    // The whole cache can't be freed while c plays, but it can once c is stopped.
    try std.testing.expectError(error.NoRoom, sounds.makeRoom(gpa, max_sound_bytes));
    sounds.stop(.player);
    try std.testing.expectEqual(0, sounds.started.items.len);
    try sounds.makeRoom(gpa, max_sound_bytes);
    try std.testing.expectEqual(0, sounds.files.items.len);
}

test "Sounds.next never returns .game" {
    var sounds: Sounds = .{ .last = std.math.maxInt(u32) };
    try std.testing.expect(sounds.next() != .game);
}
