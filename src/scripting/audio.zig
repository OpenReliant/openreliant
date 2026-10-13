//! The `openreliant.audio` package ([#498](https://github.com/OpenReliant/openreliant/issues/498),
//! [#1178](https://github.com/OpenReliant/openreliant/issues/1178)), for player and menu scripts:
//! the game's standard sounds and the mods' own sound files, on the banks' voices or in 3D, the
//! music, and Betty's lines (`package`).

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
    pub const music = api.Field(?[]const u8, "The name of the piece of music playing, as `play_music` takes it; nil while none plays.", struct {
        pub fn get(call: Call) ?[]const u8 {
            const sound = Presentation.hostOf(call).sound orelse return null;
            return hog_snd.pieceName(sound.pieceOn() orelse return null);
        }
    });

    pub const play_sound = api.Function("Plays `sound`: the number of one of the game's standard sounds, the menus' and the display's, or the name of a sound file in the script's mod, in any format a mod's sounds can be in. `options` says how, or is just a number for the volume. With `object` or `at`, it plays in 3D, while a mission is shown. Returns a number for the sound, which `stop_sound` and `sound_playing` take, or nil where it doesn't play.", &.{ "sound", "options" }, playSound);
    pub const stop_sound = api.Function("Stops the sound `id` that `play_sound` started, if it plays still. Nil stops nothing.", &.{"id"}, stopSound);
    pub const sound_playing = api.Function("Whether the sound `id` that `play_sound` started plays still, or is paused with the game. False for nil.", &.{"id"}, soundPlaying);
    pub const play_music = api.Function("Plays the piece `name` from the game's music folder, or a mod's piece of that name, in place of the music playing: for ever, or once where `options.loop` is false. With `options.after_fade`, it waits for the music playing to fade out, as a mission's music changes.", &.{ "name", "options" }, playMusic);
    pub const fade_music = api.Function("Fades the music out, as the game does before a launch. A piece that waits with `after_fade` plays once it has faded.", &.{}, fadeMusic);
    pub const stop_music = api.Function("Stops the music at once, and the piece that waits with `after_fade`, if any.", &.{}, stopMusic);
    pub const say = api.Function("Betty says `line`. Returns whether she does.", &.{"line"}, bettySays);
};

/// How `play_sound` plays a sound.
pub const SoundOptions = struct {
    /// From 0 to 1, of the effects volume.
    volume: f32 = 1,
    /// What the sound's own rate is multiplied by, from `hog_snd.lowest_pitch` to
    /// `hog_snd.highest_pitch`.
    pitch: f32 = 1,
    /// Whether it plays over and over until it's stopped.
    loop: bool = false,
    /// From -1, the left, to 1, the right, for a sound not in 3D.
    pan: f32 = 0,
    /// The object it plays at in 3D, moving with it.
    object: ?Object = null,
    /// The point of the world it plays at in 3D.
    at: ?@Vector(3, f32) = null,
    /// In 3D, within `near` it's heard at its full volume, farther off more quietly, and past `far`
    /// not at all.
    near: f32 = sound3d.default_near,
    far: f32 = sound3d.default_far,
};

/// How `play_music` plays a piece.
pub const MusicOptions = struct {
    /// Whether it plays for ever, rather than once.
    loop: bool = true,
    /// Whether it waits for the music playing to fade out.
    after_fade: bool = false,
};

/// A sound `play_sound` plays: one of the game's standard sounds, by its number, or a file of the
/// script's mod, by its name.
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
    if (!(options.near > 0) or !(options.far >= options.near)) call.raise("near must be more than 0, and far no less than near", .{});
    const place: ?@FieldType(sound3d.Own, "at") = if (options.object) |object| place: {
        if (options.at != null) call.raise("a sound plays at an object or at a point, not both", .{});
        break :place .{ .object = object.slot() };
    } else if (options.at) |point| .{ .point = point } else null;
    const sound = host.sound orelse return null;
    const gpa = call.runtime().gpa;
    // The WAVE file it plays, its priority, and the mod's file it comes from, if it's a mod's.
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

/// A pan from -1, the left, to 1, the right, as a voice takes it (`hog_snd.centre`).
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

/// The most bytes the sounds scripts play from their mods' files can take together, decoded.
pub const max_sound_bytes = 64 << 20;

/// The sounds scripts play from their mods' files, each decoded into a WAVE file the first time it
/// plays and kept for the next, and the sounds the scripts started, by their numbers. When a file
/// needs room, the files played longest ago make room for it, but never one that plays still.
pub const Sounds = struct {
    files: std.ArrayList(File) = .empty,
    /// What the files take of `max_sound_bytes`.
    bytes: usize = 0,
    /// The sounds the scripts started that may play still.
    started: std.ArrayList(Started) = .empty,
    /// The number of the last sound a script started.
    last: u32 = @backingInt(hog_snd.Starter.game),
    /// The sound the scripts' sounds play on, once one has played.
    sound: ?*hog_snd.Sound = null,

    const File = struct {
        /// The mod, by its place in `runtime.Runtime.mods`.
        mod: u16,
        name: []u8,
        wave: []u8,
        /// The number of the last sound that played it: the lowest was played longest ago.
        played: u32 = 0,

        fn deinit(file: File, gpa: Allocator) void {
            gpa.free(file.wave);
            gpa.free(file.name);
        }
    };

    const Started = struct {
        starter: hog_snd.Starter,
        family: script.Family,
        /// The WAVE file of the cache it plays, which stays while it plays; null for one of the
        /// game's.
        wave: ?[*]const u8,
    };

    /// Stops every sound the scripts started, and frees the files.
    pub fn deinit(sounds: *Sounds, gpa: Allocator) void {
        sounds.stop(null);
        for (sounds.files.items) |file| file.deinit(gpa);
        sounds.files.deinit(gpa);
        sounds.started.deinit(gpa);
        sounds.* = .{};
    }

    /// The number of the next sound a script starts, which is never the game's.
    fn next(sounds: *Sounds) hog_snd.Starter {
        sounds.last +%= 1;
        if (sounds.last == @backingInt(hog_snd.Starter.game)) sounds.last += 1;
        return @fromBackingInt(sounds.last);
    }

    /// Stops the sounds the scripts of `family` started, or every script's for null.
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

    /// The file `name` of `context`'s mod, decoded with `codec` the first time it plays, which
    /// takes the room it needs (`makeRoom`).
    fn load(sounds: *Sounds, gpa: Allocator, context: *const runtime.Context, name: []const u8, codec: ?bink.Codec) !*File {
        for (sounds.files.items) |*file| {
            if (file.mod == context.mod and std.ascii.eqlIgnoreCase(file.name, name)) return file;
        }
        if (!openreliant.hog.validName(name)) return error.InvalidName;
        const kind = recordings.Kind.of(name) orelse return error.UnknownFormat;
        const bytes = try context.modOf().readFile(gpa, name) orelse return error.FileNotFound;
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

    /// Takes files out of the cache, the one played longest ago first, until one more of `needed`
    /// bytes fits. Fails where the files that play still leave no room.
    fn makeRoom(sounds: *Sounds, gpa: Allocator, needed: usize) error{NoRoom}!void {
        while (sounds.bytes + needed > max_sound_bytes) {
            const file = sounds.files.swapRemove(sounds.stalest() orelse return error.NoRoom);
            sounds.bytes -= file.wave.len;
            file.deinit(gpa);
        }
    }

    /// The file played longest ago that plays no more.
    fn stalest(sounds: *const Sounds) ?usize {
        var found: ?usize = null;
        for (sounds.files.items, 0..) |file, index| {
            if (sounds.plays(file.wave)) continue;
            if (found) |oldest| if (sounds.files.items[oldest].played <= file.played) continue;
            found = index;
        }
        return found;
    }

    /// Whether a sound the scripts started plays `wave` still.
    fn plays(sounds: *const Sounds, wave: []const u8) bool {
        const sound = sounds.sound orelse return false;
        for (sounds.started.items) |started| {
            if (started.wave == wave.ptr and sound.playingOf(started.starter) != null) return true;
        }
        return false;
    }
};

/// What's wrong with a mod's sound file, in plain words for the script's error.
fn problem(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidName => "a file's name must be printable ASCII, with no folder",
        error.FileNotFound => "the mod has no file with that name",
        error.UnknownFormat => "a sound must be a " ++ formats ++ " file",
        error.TooLarge => std.fmt.comptimePrint("decoded, it would take more than {d} MiB", .{max_sound_bytes >> 20}),
        error.NoRoom => std.fmt.comptimePrint("the scripts' sounds that play still take the {d} MiB their files can take", .{max_sound_bytes >> 20}),
        else => recordings.problem(err),
    };
}

/// The extensions of the formats a mod's sound can be in, for a message: ".wav, .flac or .opus".
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

test "Sounds makes room from the file played longest ago, but never one that plays" {
    const gpa = std.testing.allocator;
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    var sounds: Sounds = .{ .sound = &speaker.sound };
    defer sounds.deinit(gpa);
    // Three files, played in the order b, c, a, and c still playing.
    for ([_][]const u8{ "a", "b", "c" }, [_]u32{ 3, 1, 2 }) |name, played| {
        const wave = try gpa.dupe(u8, hog_snd.testing.sound_file);
        try sounds.files.append(gpa, .{ .mod = 0, .name = try gpa.dupe(u8, name), .wave = wave, .played = played });
        sounds.bytes += wave.len;
    }
    const playing = sounds.files.items[2].wave;
    const starter = sounds.next();
    _ = speaker.sound.playFile(playing, .{ .priority = hog_snd.script_priority, .loops = hog_snd.forever, .starter = starter }).?;
    try sounds.started.append(gpa, .{ .starter = starter, .family = .player, .wave = playing.ptr });
    // Room for one more file than the room left takes b out, the one played longest ago.
    try sounds.makeRoom(gpa, max_sound_bytes - sounds.bytes + 1);
    try std.testing.expectEqual(2, sounds.files.items.len);
    for (sounds.files.items) |file| try std.testing.expect(!std.mem.eql(u8, file.name, "b"));
    // The whole room can't be made while c plays; once it's stopped, it can.
    try std.testing.expectError(error.NoRoom, sounds.makeRoom(gpa, max_sound_bytes));
    sounds.stop(.player);
    try std.testing.expectEqual(0, sounds.started.items.len);
    try sounds.makeRoom(gpa, max_sound_bytes);
    try std.testing.expectEqual(0, sounds.files.items.len);
}

test "Sounds.next never gives the game's number" {
    var sounds: Sounds = .{ .last = std.math.maxInt(u32) };
    try std.testing.expect(sounds.next() != .game);
}
