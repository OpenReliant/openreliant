//! `C:\lancer\game\hog_SND.CPP`: sound, through Miles ([`engine/mss.zig`](../mss.zig) in
//! OpenReliant). The voices a bank's sounds play on (`sound_voices`), the positional sounds
//! gathered over a frame, the music, and the 3D voices the effects of [`sound3d.zig`](sound3d.zig)
//! play on.
//!
//! **Unverified:** most of it lies outside this file's known code (`0x00482160` to `0x004822E9`),
//! from `0x00481400` to `0x00482DE0`, between `hog_gen.cpp`'s and `hud.cpp`'s.
//!
//! Not ported: the CD's own music (`AIL_redbook_open`), which the shipped game plays none of. The
//! radio's speech plays on the sample `sound_init` allocates for it (`speech`), which
//! [`cbox.zig`](cbox.zig) feeds a line at a time where the game streams it through the sample's
//! double buffer.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fat = @import("../../formats/fat.zig");
const bigfile = @import("bigfile.zig");
const bink = @import("../bink.zig");
const paths = @import("../files.zig");
const recordings = @import("recordings.zig");
const shp = @import("../../formats/shp.zig");
const wave = @import("../../formats/wave.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const mss = @import("../mss.zig");
const profile = @import("../profile.zig");
const camera = @import("camera.zig");
const main = @import("main.zig");
const Clock = main.Clock;
const gameobj = @import("gameobj.zig");
const sound3d = @import("sound3d.zig");

const log = std.log.scoped(.sound);

pub const betty = @import("hog_snd/betty.zig");

/// The values `sound_play` takes. The volume runs from 0 to `loudest`. The pan runs from 0 (left)
/// to `rightmost` (right), with `centre` in the middle. A play count of `forever` repeats the
/// sound until it is stopped. The pitch is in quarter tones up or down from `own_pitch`, the
/// sound's own pitch.
pub const loudest = mss.max_level;
pub const rightmost = mss.max_level;
pub const centre = mss.centre_pan;
pub const once = 1;
pub const forever = 0;
pub const own_pitch = 0;

/// The most voices `sound_init` sets up for the banks' sounds (`0x00501798`).
pub const max_voices = 16;

/// The most 3D voices the game takes of its provider's.
pub const max_voices_3d = 64;

/// The positional sounds gathered over a frame (`0x00565340`): slots for 100, of which
/// `sound_buffer_at` fills the first 18.
pub const buffer_slots = 100;
pub const buffered_sounds = 18;

/// The ticks between the fades' steps (`tick_timer`).
const fade_ticks = 5;

/// The step `music_play` fades the music playing out by, before the piece it queues
/// (`0x00482C00`).
const queued_fade_step = 5;

/// The priority `sound_play` starts its search for the lowest from, above any a bank gives (an
/// immediate in `sound_play`).
const priority_ceiling = 9999;

/// Added by OpenReliant: the priority of a script sound, the lowest in the banks. A script sound
/// never takes a voice from a game sound, and a game sound with a higher priority takes a script
/// sound's voice when no voice is free.
pub const script_priority = 1;

/// What `sound_start` divides the effects volume times a sound's by, where the rest of the file
/// divides by `loudest` (an immediate in `sound_start`).
const start_divisor = 128;

/// What a positional sound's volume is multiplied by before its levels are worked out
/// (`sound_buffer_at`, `0x004DC72C`).
const buffered_loudness: f32 = 20;

/// The most quarter tones `sound_pitch_factor` moves a sound up or down (an immediate in
/// `sound_pitch_factor`), and the quarter tones to the octave its tables are made for.
const max_quarter_tones = 96;
const quarter_tones_per_octave = 24;

/// The highest and lowest factors `sound_pitch_factor` gives: four octaves up and four octaves
/// down.
pub const highest_pitch: f32 = 1 << (max_quarter_tones / quarter_tones_per_octave);
pub const lowest_pitch: f32 = 1 / highest_pitch;

/// The count past which `tick_timer` rolls the mission's seconds and minutes over, a tick after
/// they reach it, so each counts 0 to 59 (an immediate in `tick_timer`).
const rollover_after = 58;

/// What turns the game's units into Miles's for a 3D sound's place and speed: its distances
/// (`0x004DC9B4`) and the step's movement into a millisecond's.
pub const distance_scale: f32 = 0.0004;
pub const velocity_scale: f32 = 1e-5;

/// Added by OpenReliant: who started the sound on a voice. Either the game, or a script sound with
/// the ID OpenReliant gave it (`openreliant.audio`).
pub const Starter = enum(u32) {
    game = 0,
    _,
};

/// One voice of `sound_voices`: a Miles sample and what is playing on it.
pub const Voice = extern struct {
    sample: mss.Sample,
    /// Nonzero while the display holds the voice (`hud_draw`), which `play` then never takes over.
    held: u32,
    /// The playing sound's priority, from its bank entry. A new sound takes over the voice with
    /// the lowest one, if that is below its own.
    priority: i32,
    _unknown_0c: u32,
    /// Nonzero while it fades out, by `fade_step` of its volume every five ticks (`timerTick`).
    fading: u32,
    fade_step: i32,
    /// The playing sound's own rate.
    rate: u32,
    /// Its volume as asked, from 0 to 127, which the effects volume and the master volume scale.
    volume: i32,

    comptime {
        assert(@offsetOf(Voice, "priority") == 0x08);
        assert(@offsetOf(Voice, "fading") == 0x10);
        assert(@sizeOf(Voice) == 0x20);
    }

    /// Starts it fading out by `step` every five ticks, and lets any sound take it, as
    /// `sound_voice_fade` and `sound_fade_all` do.
    fn startFade(voice: *Voice, step: i32) void {
        voice.priority = 0;
        voice.held = 0;
        voice.fading = 1;
        voice.fade_step = step;
    }
};

/// One of the 3D voices (`0x00563F60`): a Miles 3D sample and the sound on it.
pub const Voice3D = extern struct {
    sample: mss.Sample3D,
    follows: sound3d.Follows,
    /// What it follows: a shot's record, a missile's or an object's slot; `no_owner` while it is
    /// free.
    owner: i32,
    _unknown_0c: u32,
    /// The playing sound's priority, from its entry in `smp3d.fat`.
    priority: i32,
    /// How far off it is still heard, in Miles's units (`sound3d.Definition.max_distance`).
    range: f32,
    /// The point and the direction it was started with, for a sound that keeps them.
    position: shp.Vec3,
    direction: shp.Vec3,
    _unknown_30: u32,
    /// Taken by a sound of another class while free, so that its own class may take it back.
    borrowed: bool,
    _unknown_35: [3]u8,
    /// The sound playing (`sound3d.sounds.Sound`).
    sound: i32,
    /// When it started (`Clock.frame_start`).
    started: i32,
    /// The sound as 16-bit PCM, which the game decompresses into memory of Miles's own;
    /// OpenReliant's Miles plays the bank's sound as it is.
    decompressed: u32,

    comptime {
        assert(@offsetOf(Voice3D, "range") == 0x14);
        assert(@offsetOf(Voice3D, "borrowed") == 0x34);
        assert(@offsetOf(Voice3D, "started") == 0x3C);
        assert(@sizeOf(Voice3D) == 0x44);
    }

    /// `owner` while the voice is free. A sound at a point started with this for its owner
    /// leaves the voice free while it plays, for any other sound to take.
    pub const no_owner: i32 = -1;

    /// Added by OpenReliant: the `owner` of a script sound at a point (`sound3d.playOwn`). Unlike
    /// a game sound at a point, it keeps its voice until it ends.
    pub const script_owner: i32 = -2;

    /// Added by OpenReliant: the `sound` of a script sound, which is not one of the game's sounds.
    pub const script_sound: i32 = -1;

    /// Whether the voice is free: its `owner` is `no_owner`.
    pub fn isFree(voice: Voice3D) bool {
        return voice.owner == no_owner;
    }

    /// The record or the slot of what it follows, where `owner` names one.
    pub fn ownerIndex(voice: Voice3D) ?u32 {
        return std.math.cast(u32, voice.owner);
    }

    const free: Voice3D = .{
        .sample = @fromBackingInt(0),
        .follows = .none,
        .owner = no_owner,
        ._unknown_0c = 0,
        .priority = 0,
        .range = 0,
        .position = .{ .x = 0, .y = 0, .z = 0 },
        .direction = .{ .x = 0, .y = 0, .z = 0 },
        ._unknown_30 = 0,
        .borrowed = false,
        ._unknown_35 = @splat(0),
        .sound = 0,
        .started = 0,
        .decompressed = 0,
    };
};

/// The four volumes of `starlancer.ini`'s `[Sound]`, each from 0 to 127, with the defaults the
/// options screen resets them to (`0x0042DC5E`).
pub const Volumes = struct {
    /// `Mastervolume` (`0x005D5A70`): everything.
    master: i32 = loudest,
    /// `Fxvolume` (`0x005D5A74`): the banks' sounds and the 3D sounds.
    effects: i32 = 80,
    /// `Musicvolume` (`0x005D55EC`).
    music: i32 = 80,
    /// `Speechvolume` (`0x005D5E88`).
    speech: i32 = loudest,

    pub const section = "Sound";
    /// The key of `[Sound]` each volume is kept under.
    pub const keys: std.EnumArray(std.meta.FieldEnum(Volumes), []const u8) = .init(.{
        .master = "Mastervolume",
        .effects = "Fxvolume",
        .music = "Musicvolume",
        .speech = "Speechvolume",
    });

    /// The master volume's share. **Improvement:** an exact division by `loudest`, where the game
    /// multiplies by its rounded reciprocal (`0x004DC6B0`).
    pub fn masterShare(volumes: Volumes) f32 {
        return @as(f32, @floatFromInt(volumes.master)) / loudest;
    }

    /// `volume` as the game hands it to Miles: scaled by a channel's volume, `channel` over
    /// `divisor` in whole numbers, then by the master volume's share, rounded by `sr_round`.
    pub fn mastered(volumes: Volumes, channel: i32, volume: i32, divisor: i32) i32 {
        const scaled = @divTrunc(channel * volume, divisor);
        return math.round(@as(f32, @floatFromInt(scaled)) * volumes.masterShare());
    }

    /// The volumes `settings` keeps, each at most `loudest`, and the defaults for any it lacks.
    pub fn read(settings: profile.Profile) Volumes {
        var volumes: Volumes = .{};
        inline for (@typeInfo(Volumes).@"struct".field_names) |name| {
            const kept = settings.int(section, keys.get(@field(std.meta.FieldEnum(Volumes), name)), @intCast(@field(volumes, name)));
            @field(volumes, name) = @intCast(@min(kept, loudest));
        }
        return volumes;
    }
};

/// A bank file read into memory, as `hog_load` and `hog_read_file` read it. Its sounds play
/// straight from `bytes`.
pub const BankFile = struct {
    bytes: []u8,
    bank: fat.Bank,
    /// Added by OpenReliant: for each sound, whether a mod replaces it (`of`). Empty when no mod
    /// replaces any.
    modded: []const bool = &.{},

    /// Parses `bytes` as the bank `name` and takes ownership of them, then swaps in the sounds
    /// that mods in `source` replace. A mod's sound is named after the bank and the sound's number
    /// (`fat.soundName`). Returns null and frees `bytes`, with a warning, if they are not a bank.
    ///
    /// **Improvement:** the original plays only its banks' own sounds.
    pub fn of(gpa: Allocator, bytes: []u8, name: []const u8, source: recordings.Source) ?BankFile {
        const bank = fat.Bank.parse(bytes) catch |err| {
            log.warn("the bank {s} is left out: {t}", .{ name, err });
            gpa.free(bytes);
            return null;
        };
        return withModSounds(.{ .bytes = bytes, .bank = bank }, gpa, name, source);
    }

    /// Reads the bank `name` from `archive` (`hog_load`) and swaps in the sounds that its mods
    /// replace, decoded with `codec` (`of`). Returns null, with a warning, if the bank can't be
    /// read.
    pub fn read(gpa: Allocator, archive: *const bigfile.Hog, name: []const u8, codec: ?bink.Codec) ?BankFile {
        const bytes = archive.readFile(gpa, name) catch |err| {
            log.warn("the bank {s} is left out: {t}", .{ name, err });
            return null;
        };
        return of(gpa, bytes, name, .{ .mods = archive.mods, .codec = codec });
    }

    pub fn deinit(file: BankFile, gpa: Allocator) void {
        gpa.free(file.modded);
        gpa.free(file.bytes);
    }

    /// Rebuilds `file`, the bank `name`, with the sounds that mods replace (`fat.rebuild`), and
    /// takes ownership of `file`. A mod's sound that a voice can't play is skipped, so the bank's
    /// own sound stays. If the bank can't be rebuilt, the log says so and `file` comes back
    /// unchanged.
    fn withModSounds(file: BankFile, gpa: Allocator, name: []const u8, source: recordings.Source) BankFile {
        if (source.mods.list.len == 0) return file;
        const count = file.bank.entries.len;
        const replacements = gpa.alloc(?[]const u8, count) catch return file;
        defer gpa.free(replacements);
        @memset(replacements, null);
        defer for (replacements) |replacement| if (replacement) |own| gpa.free(own);
        var found = false;
        for (replacements, 0..) |*replacement, index| {
            var buffer: [bigfile.member_name_room]u8 = undefined;
            replacement.* = playable(gpa, source, fat.soundName(&buffer, name, index) catch continue);
            found = found or replacement.* != null;
        }
        if (!found) return file;
        const modded = gpa.alloc(bool, count) catch return file;
        for (modded, replacements) |*by_mod, replacement| by_mod.* = replacement != null;
        const bytes = fat.rebuild(gpa, file.bank, replacements) catch |err| {
            log.warn("the mods' sounds of the bank {s} are left out: {t}", .{ name, err });
            gpa.free(modded);
            return file;
        };
        const bank = fat.Bank.parse(bytes) catch |err| {
            log.warn("the mods' sounds of the bank {s} are left out: {t}", .{ name, err });
            gpa.free(bytes);
            gpa.free(modded);
            return file;
        };
        file.deinit(gpa);
        return .{ .bytes = bytes, .bank = bank, .modded = modded };
    }

    /// Reads a mod's sound `name` from `source` as a WAVE file that a voice can play. Returns null
    /// if no mod has the sound, or, with a warning, if a voice can't play it.
    fn playable(gpa: Allocator, source: recordings.Source, name: []const u8) ?[]u8 {
        const bytes = source.read(gpa, name) orelse return null;
        _ = mss.voice.Voice.init(bytes) catch |err| {
            log.warn("the sound {s} is left out: {t}", .{ name, err });
            gpa.free(bytes);
            return null;
        };
        return bytes;
    }
};

/// Where the music comes from: separate files in the game folder, `music\` plus the name, which
/// Miles streamed from disk (`AIL_open_stream`), with OpenReliant's mods taking priority.
pub const Files = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    /// Added by OpenReliant: the mods' pieces, which take priority over the game folder's.
    recordings: recordings.Source = .none,
};

/// The music (`0x00565300` on): a stream of one file, which fades out before another starts.
pub const Music = struct {
    stream: ?mss.Stream = null,
    /// The file it plays, which the stream reads from.
    file: []u8 = &.{},
    /// Its level, 0 to 127, which the music volume and the master volume scale (`0x00565068`).
    level: i32 = 0,
    /// While fading, the level falls by `fade_step` every five ticks until the stream closes
    /// (`0x00563F58`, `0x00563A18`).
    fading: bool = false,
    fade_step: i32 = 0,
    /// A piece to play once this one has faded (`0x0056533A` on).
    queued: ?Piece = null,
    /// Added by OpenReliant: a mod's piece in a format other than WAV that is still being decoded,
    /// a few seconds each pass (`Sound.decodeMusic`). It plays once it is fully decoded, and the
    /// music counts as playing until then.
    decoding: ?Decoding = null,
    /// Added by OpenReliant: whether the music is paused because the game's window is inactive
    /// (`Sound.holdMusic`).
    held: bool = false,
    /// Added by OpenReliant: the piece the stream plays (`Sound.pieceOn`).
    piece: ?Piece = null,

    /// A copy of a piece of music's path.
    pub const Path = struct {
        bytes: [paths.max_path]u8 = @splat(0),
        len: usize = 0,

        /// A copy of `path`, cut short if it's longer than `paths.max_path`.
        pub fn of(path: []const u8) Path {
            var copy: Path = .{ .len = @min(path.len, paths.max_path) };
            @memcpy(copy.bytes[0..copy.len], path[0..copy.len]);
            return copy;
        }

        pub fn slice(copy: *const Path) []const u8 {
            return copy.bytes[0..copy.len];
        }
    };

    /// A piece of music to play: its path, loop count and level.
    pub const Piece = struct {
        path: Path,
        loops: u32,
        level: i32,

        /// The piece at `path`, to play `loops` times at `level`.
        pub fn of(path: []const u8, loops: u32, level: i32) Piece {
            return .{ .path = .of(path), .loops = loops, .level = level };
        }

        /// The piece's path.
        pub fn pathOf(piece: *const Piece) []const u8 {
            return piece.path.slice();
        }
    };

    /// A mod's piece in a format other than WAV that is still being decoded, and whether the
    /// music was paused during the decoding.
    pub const Decoding = struct {
        recording: recordings.Decoding,
        piece: Piece,
        paused: bool = false,
    };
};

/// How many seconds of a mod's piece are decoded each pass (`Sound.decodeMusic`). That takes a
/// few milliseconds, so the game doesn't stall.
const seconds_decoded_a_pass = 3;

/// Where a piece of music loops back to once it has played through: a byte offset into its data
/// for each piece the table names (`0x005017A0`). The rest loop from the start.
pub const music_loops = [_]struct { name: []const u8, loop_start: i32 }{
    .{ .name = "new_mission01", .loop_start = 188318 },
    .{ .name = "new_mission02", .loop_start = 237569 },
    .{ .name = "new_mission03", .loop_start = 102043 },
    .{ .name = "new_mission04", .loop_start = 223314 },
    .{ .name = "new_mission05", .loop_start = 178163 },
    .{ .name = "new_mission06", .loop_start = 144433 },
    .{ .name = "new_mission07", .loop_start = 105604 },
    .{ .name = "new_mission08", .loop_start = 75874 },
    .{ .name = "new_mission09", .loop_start = 55392 },
    .{ .name = "new_mission10", .loop_start = 127749 },
    .{ .name = "new_defeat", .loop_start = 166910 },
    .{ .name = "new_launch", .loop_start = 355065 },
    .{ .name = "new_pensive", .loop_start = 132922 },
    .{ .name = "new_victory", .loop_start = 176922 },
    .{ .name = "new_searching mission 01", .loop_start = 297178 },
    .{ .name = "new_searching mission 02", .loop_start = 126079 },
    .{ .name = "new_searching mission 03", .loop_start = 108719 },
    .{ .name = "new_searching mission 04", .loop_start = 143807 },
    .{ .name = "new_searching mission 05", .loop_start = 101402 },
    .{ .name = "new_searching mission 06", .loop_start = 64511 },
    .{ .name = "new_searching mission 07", .loop_start = 116109 },
    .{ .name = "new_searching mission 08", .loop_start = 158719 },
    .{ .name = "new_searching mission 09", .loop_start = 90111 },
    .{ .name = "new_searching mission 10", .loop_start = 146431 },
    .{ .name = "new_sim01", .loop_start = 389937 },
    .{ .name = "new_sim02", .loop_start = 211074 },
    .{ .name = "new_sim03", .loop_start = 95328 },
    .{ .name = "new_sim04", .loop_start = 438286 },
    .{ .name = "new_sim05", .loop_start = 244327 },
    .{ .name = "new_sim06", .loop_start = 157445 },
    .{ .name = "new_sim07", .loop_start = 148140 },
    .{ .name = "new_sim08", .loop_start = 201251 },
    .{ .name = "new_sim09", .loop_start = 264760 },
    .{ .name = "new_sim10", .loop_start = 337966 },
    .{ .name = "new__spare!", .loop_start = 187648 },
};

/// What a 3D sound is placed and heard against: the objects, the shots, and the camera.
pub const Scene = struct {
    objects: *@import("create.zig").Objects,
    camera: camera.Place,
    view: camera.View,
    clock: *const Clock,
    /// The game's random numbers (`Random`), which pitch the explosions.
    random: *@import("../random.zig").Random,
};

/// What the game's code reaches the sound through: the sound, the camera it is heard from,
/// placed each frame (the game reads its camera's frame, `sr + 0x30`), and the mission's clock.
pub const Hearing = struct {
    sound: *Sound,
    camera: *const camera.Place,
    clock: *const Clock,

    /// The scene a 3D sound is placed in, for `world`.
    pub fn scene(hearing: Hearing, world: gameobj.World) Scene {
        return .{ .objects = world.objects, .camera = hearing.camera.*, .view = world.view, .clock = hearing.clock, .random = world.random };
    }
};

/// The game's sound: its globals, from `0x00563A18` to `0x00565690`.
pub const Sound = struct {
    /// Miles's digital driver (`0x00563A1C`), or null with none at all: every call then does
    /// nothing, as the game's do while `0x00565688` is clear.
    driver: ?mss.Driver = null,
    voices: [max_voices]Voice = @splat(std.mem.zeroes(Voice)),
    voice_count: u8 = 0,
    /// The voices `pauseAll` stopped, for `resumeAll` (`0x00563A20`).
    paused: [max_voices]bool = @splat(false),
    /// Added by OpenReliant: who started the sound on each voice and each 3D voice.
    starters: [max_voices]Starter = @splat(.game),
    starters_3d: [max_voices_3d]Starter = @splat(.game),
    /// Each positional sound's level in the left ear and the right, gathered over a frame.
    buffered: [buffer_slots][2]f32 = @splat(.{ 0, 0 }),
    volumes: Volumes = .{},
    music: Music = .{},
    files: ?Files = null,
    /// When the fades last stepped (`0x0056533C`).
    faded_at: u32 = 0,
    /// The 3D voices, as many as the provider has, up to 64 (`0x00565684`); none while no
    /// provider is open (`0x0056567C`).
    voices_3d: [max_voices_3d]Voice3D = @splat(Voice3D.free),
    voice_3d_count: u8 = 0,
    /// The voices set aside for the player's engine and its afterburner, of classes
    /// `player_engines` and `player_burners` (`0x00565674`, `0x00565060`).
    engine_voice: ?u8 = null,
    burner_voice: ?u8 = null,
    /// The 3D sounds' own state.
    effects: sound3d.Effects = .{},
    /// The live objects (`game_objects`), whose voices `end3D` lets go of.
    objects: ?*@import("create.zig").Objects = null,
    /// `betty.fat` (`bank_betty`, `0x0056654C`): the cockpit's warnings.
    betty: ?fat.Bank = null,
    /// `bank_stdsmp` (`0x005D6CA0`): the display's sounds and the frame's positional ones
    /// (`playStandard`).
    stdsmp: ?fat.Bank = null,
    /// When the player's armour last warned (`0x00588334`, `main.armorWarning`).
    armor_warned_at: i32 = 0,
    /// When a shot last sounded on the player's hull (`0x00593794`, `shieldfx.hullHit`).
    player_hit_at: i32 = 0,
    /// Where a missile's sound is heard from.
    missile_sound: sound3d.MissileSound = .follows,
    /// What surrounds the camera, which the reverb plays (`surround`).
    surroundings: mss.Surroundings = .space,
    /// The speech sample (`0x00563F18`), which the radio's lines play on (`cbox.Player`); null
    /// where the driver has none to give.
    speech: ?mss.Sample = null,
    /// The game's clock, whose `game_ticks` time a line of speech where there's no speech sample
    /// to play it on (`cbox.Player`); null until the game sets it.
    clock: ?*const Clock = null,

    /// `sound_init` (`0x00481440`), as far as OpenReliant goes: up to 16 voices for the banks, each
    /// a sample of `driver`, and the timer that steps the fades. `driver` is null where the
    /// platform has no sound, which leaves the game silent.
    pub fn init(sound: *Sound, driver: ?mss.Driver, voice_count: u8, files: ?Files) void {
        sound.* = .{ .files = files };
        const opened = driver orelse return;
        // The driver may have played an earlier mission, which could leave it in a hangar.
        opened.setSurroundings(sound.surroundings);
        for (sound.voices[0..@min(voice_count, max_voices)]) |*voice| {
            voice.* = std.mem.zeroes(Voice);
            voice.sample = opened.allocateSample() orelse break;
            sound.voice_count += 1;
        }
        if (sound.voice_count > 0) sound.driver = opened;
        if (sound.driver != null) sound.speech = opened.allocateSample();
    }

    /// The speech sample's volume as the game hands it to Miles (`speech_start`,
    /// `sound_volumes_apply`): the speech volume, scaled by the master volume's share; and by
    /// `volume`, 0 to 127, a line's own, which the game keeps but applies nowhere, so that every
    /// line the game plays, at 127, comes out as the game has it.
    pub fn speechVolume(sound: *const Sound, volume: i32) i32 {
        return sound.volumes.mastered(sound.volumes.speech, volume, loudest);
    }

    /// `sound_shutdown` (`0x00481750`): every voice ended and the music closed.
    pub fn shutdown(sound: *Sound) void {
        sound.endAll();
        sound.close3D();
        sound.closeMusic();
        sound.driver = null;
    }

    // --- The banks' sounds -----------------------------------------------------------------------

    /// `sound_play` (`0x00481F80`): plays sound `index` of `bank` on a voice picked by
    /// `takeVoice`, at `volume` from 0 to 127, `loops` times, at `pan` from 0 to 127, and `pitch`
    /// quarter tones up or down. Returns the voice, or null.
    pub fn play(sound: *Sound, bank: fat.Bank, index: usize, volume: i32, loops: u32, pan: i32, pitch: i32) ?u8 {
        const driver = sound.driver orelse return null;
        const entry_priority: i32 = if (index < bank.entries.len) @intCast(bank.entries[index].priority) else return null;
        const chosen = sound.takeVoice(driver, entry_priority) orelse return null;
        sound.start(bank, index, volume, pitch, loops, pan, chosen);
        return chosen;
    }

    /// Added by OpenReliant: plays the WAVE file `file` as a script sound (`openreliant.audio`)
    /// with the settings in `how`, choosing a voice as `play` does. `file` must stay valid while it
    /// plays. Returns the voice, or null if none is free.
    pub fn playFile(sound: *Sound, file: []const u8, how: Starting) ?u8 {
        const driver = sound.driver orelse return null;
        const chosen = sound.takeVoice(driver, how.priority) orelse return null;
        return if (sound.startFile(chosen, file, how)) chosen else null;
    }

    /// Picks a voice for a sound of `priority`, as `sound_play` (`0x00481F80`) does: the first
    /// finished voice after voice 0, else the first stopped voice, else the busy voice with the
    /// lowest priority, whose sound it ends. It skips a voice the display holds, and a busy voice
    /// whose priority isn't lower than `priority`. Returns null if no voice qualifies.
    fn takeVoice(sound: *Sound, driver: mss.Driver, priority: i32) ?u8 {
        const count = sound.voice_count;
        for (1..count) |v| if (driver.sampleStatus(sound.voices[v].sample) == .done) return @intCast(v);
        for (0..count) |v| if (driver.sampleStatus(sound.voices[v].sample) == .stopped) return @intCast(v);
        var lowest: i32 = priority_ceiling;
        var found: ?u8 = null;
        for (sound.voices[0..count], 0..) |voice, v| {
            if (voice.priority < lowest and voice.held == 0) {
                lowest = voice.priority;
                found = @intCast(v);
            }
        }
        const taken = found orelse return null;
        if (lowest >= priority) return null;
        sound.endVoice(taken);
        return taken;
    }

    /// `play` of sound `index` of `bank_stdsmp` (`0x005D6CA0`), as the game hands that global to
    /// `sound_play`: the voice it plays on, or null, as where the bank is not loaded.
    pub fn playStandard(sound: *Sound, index: usize, volume: i32, loops: u32, pan: i32, pitch: i32) ?u8 {
        const bank = sound.stdsmp orelse return null;
        return sound.play(bank, index, volume, loops, pan, pitch);
    }

    /// `sound_play_on_voice` (`0x004820C0`): plays it on voice `v`, ending what it was playing.
    pub fn playOn(sound: *Sound, v: u8, bank: fat.Bank, index: usize, volume: i32, loops: u32, pan: i32, pitch: i32) void {
        const driver = sound.driver orelse return;
        if (v >= sound.voice_count or index >= bank.entries.len) return;
        if (driver.sampleStatus(sound.voices[v].sample) != .done) sound.endVoice(v);
        sound.voices[v].held = 0;
        sound.start(bank, index, volume, pitch, loops, pan, v);
    }

    /// Plays the WAVE file `file`, a line of speech, once on voice `v`, panned to the middle. It
    /// ends the voice's current sound and holds the voice, so that no other sound takes it. The
    /// rooms play the crew's lines this way (`0x0043B598` on). `file` must stay valid while it
    /// plays. Added by OpenReliant: the line gets the reverb of the camera's surroundings, like
    /// the rooms' other sounds (`inScene`).
    ///
    /// **Fix:** it plays at the speech volume, scaled by the master volume. The game sets the
    /// sample to full volume itself, whatever the settings.
    pub fn speakOn(sound: *Sound, v: u8, file: []const u8) void {
        const driver = sound.driver orelse return;
        if (v >= sound.voice_count) return;
        if (driver.sampleStatus(sound.voices[v].sample) != .done) sound.endVoice(v);
        const voice = &sound.voices[v];
        voice.held = 1;
        sound.starters[v] = .game;
        driver.initSample(voice.sample);
        if (!driver.setSampleFile(voice.sample, file)) {
            log.warn("a line of speech cannot be played", .{});
            return;
        }
        driver.setSampleRoom(voice.sample, .scene);
        driver.setSampleVolume(voice.sample, sound.speechVolume(loudest));
        driver.setSampleLoopCount(voice.sample, once);
        driver.setSamplePan(voice.sample, centre);
        voice.fading = 0;
        voice.volume = loudest;
        driver.startSample(voice.sample);
    }

    /// `sound_start` (`0x004826A0`): plays sound `index` of `bank` on voice `v`, with its rate
    /// moved by `pitch` quarter tones and `volume` scaled by the effects and master volumes.
    fn start(sound: *Sound, bank: fat.Bank, index: usize, volume: i32, pitch: i32, loops: u32, pan: i32, v: u8) void {
        const file = bank.sound(index) orelse return;
        const started = sound.startFile(v, file, .{
            .priority = @intCast(bank.entries[index].priority),
            // Added by OpenReliant: the cockpit's warnings get the cockpit's reverb.
            .room = if (sound.fromCockpit(bank)) .cockpit else .none,
            .volume = volume,
            .rate_factor = if (pitch != 0) pitchFactor(pitch) else null,
            .loops = loops,
            .pan = pan,
        });
        if (!started) log.warn("sound {d} of a bank cannot be played", .{index});
    }

    /// The settings a sound starts with (`startFile`).
    pub const Starting = struct {
        /// A sound with a higher priority can take the voice.
        priority: i32,
        room: mss.Room = .none,
        /// From 0 to 127, scaled by the effects and master volumes.
        volume: i32 = loudest,
        /// Factor for the sound's own rate; null keeps the rate.
        rate_factor: ?f32 = null,
        /// How many times it plays; 0 loops forever.
        loops: u32 = once,
        pan: i32 = centre,
        starter: Starter = .game,
    };

    /// The rest of `sound_start` (`0x004826A0`): plays `file` on voice `v` with the settings in
    /// `how`. Returns false if the driver can't play the file.
    fn startFile(sound: *Sound, v: u8, file: []const u8, how: Starting) bool {
        const driver = sound.driver orelse return false;
        const voice = &sound.voices[v];
        driver.initSample(voice.sample);
        if (!driver.setSampleFile(voice.sample, file)) return false;
        driver.setSampleRoom(voice.sample, how.room);
        const rate = if (wave.Wave.parse(file)) |info| info.rate else |_| 0;
        if (how.rate_factor) |factor| {
            const moved = @as(f32, @floatFromInt(rate)) * factor;
            driver.setSamplePlaybackRate(voice.sample, std.math.lossyCast(u32, moved));
        }
        driver.setSampleVolume(voice.sample, sound.volumes.mastered(sound.volumes.effects, how.volume, start_divisor));
        driver.setSampleLoopCount(voice.sample, how.loops);
        driver.setSamplePan(voice.sample, how.pan);
        voice.priority = how.priority;
        voice.fading = 0;
        voice.rate = rate;
        voice.volume = how.volume;
        sound.starters[v] = how.starter;
        driver.startSample(voice.sample);
        return true;
    }

    /// Added by OpenReliant: gives the sample on voice `v` the reverb of the camera's surroundings
    /// (`mss.Room.scene`), as the 3D sounds have. For sounds in the scene that the game plays as
    /// plain samples.
    pub fn inScene(sound: *Sound, v: u8) void {
        const driver = sound.driver orelse return;
        if (v < sound.voice_count) driver.setSampleRoom(sound.voices[v].sample, .scene);
    }

    /// Plays a sound as `play` does, with the reverb of the camera's surroundings (`inScene`).
    /// Returns the voice, or null.
    pub fn playInScene(sound: *Sound, bank: fat.Bank, index: usize, volume: i32, loops: u32, pan: i32, pitch: i32) ?u8 {
        const v = sound.play(bank, index, volume, loops, pan, pitch) orelse return null;
        sound.inScene(v);
        return v;
    }

    /// Added by OpenReliant: sets the camera's surroundings, whose reverb the 3D sounds and the
    /// scene's samples get. The driver is told only when they change.
    pub fn surround(sound: *Sound, surroundings: mss.Surroundings) void {
        if (surroundings == sound.surroundings) return;
        sound.surroundings = surroundings;
        const driver = sound.driver orelse return;
        driver.setSurroundings(surroundings);
    }

    /// Whether `bank` is the cockpit's own, `betty.fat`.
    fn fromCockpit(sound: *const Sound, bank: fat.Bank) bool {
        const own = sound.betty orelse return false;
        return own.bytes.ptr == bank.bytes.ptr;
    }

    /// `sound_voice_end` (`0x004823D0`).
    pub fn endVoice(sound: *Sound, v: u8) void {
        const driver = sound.driver orelse return;
        const voice = &sound.voices[v];
        voice._unknown_0c = 0;
        voice.priority = 0;
        voice.fading = 0;
        voice.held = 0;
        sound.starters[v] = .game;
        driver.endSample(voice.sample);
    }

    /// Whether voice `v` has finished or was stopped, as `hud_draw` asks of the enemy lock's
    /// warning's voice; false with no driver.
    pub fn voiceIdle(sound: *Sound, v: u8) bool {
        const driver = sound.driver orelse return false;
        return switch (driver.sampleStatus(sound.voices[v].sample)) {
            .done, .stopped => true,
            else => false,
        };
    }

    /// `sound_voice_playing` (`0x00482410`).
    pub fn voicePlaying(sound: *Sound, v: u8) bool {
        const driver = sound.driver orelse return false;
        return driver.sampleStatus(sound.voices[v].sample) == .playing;
    }

    /// `sound_voice_set_volume` (`0x00482440`): a playing voice's volume, from 0 to 127.
    pub fn setVoiceVolume(sound: *Sound, v: u8, volume: i32) void {
        const driver = sound.driver orelse return;
        if (!sound.voicePlaying(v)) return;
        sound.voices[v].volume = volume;
        driver.setSampleVolume(sound.voices[v].sample, sound.volumes.mastered(sound.volumes.effects, volume, loudest));
    }

    /// `sound_voice_fade` (`0x004824C0`): fades a playing voice out by `step` every five ticks, and
    /// lets any sound take it.
    pub fn fadeVoice(sound: *Sound, v: u8, step: i32) void {
        if (!sound.voicePlaying(v)) return;
        sound.voices[v].startFade(step);
    }

    /// `sound_fade_all` (`0x00482510`): every voice not finished fades by `step`.
    pub fn fadeAll(sound: *Sound, step: i32) void {
        const driver = sound.driver orelse return;
        for (sound.voices[0..sound.voice_count]) |*voice| {
            if (driver.sampleStatus(voice.sample) != .done) voice.startFade(step);
        }
    }

    /// `sound_end_all` (`0x00482570`): every voice ended, and the positional sounds forgotten.
    pub fn endAll(sound: *Sound) void {
        if (sound.driver == null) return;
        for (0..sound.voice_count) |v| sound.endVoice(@intCast(v));
        sound.buffered = @splat(.{ 0, 0 });
    }

    /// `sound_pause_all` (`0x004825D0`): stops every playing voice where it is.
    pub fn pauseAll(sound: *Sound) void {
        const driver = sound.driver orelse return;
        for (sound.voices[0..sound.voice_count], sound.paused[0..sound.voice_count]) |voice, *paused| {
            paused.* = driver.sampleStatus(voice.sample) == .playing;
            if (paused.*) driver.stopSample(voice.sample);
        }
    }

    /// `sound_resume_all` (`0x00482630`): what `pauseAll` stopped goes on.
    pub fn resumeAll(sound: *Sound) void {
        const driver = sound.driver orelse return;
        for (sound.voices[0..sound.voice_count], sound.paused[0..sound.voice_count]) |voice, *paused| {
            if (!paused.*) continue;
            paused.* = false;
            driver.resumeSample(voice.sample);
        }
    }

    /// `sound_volumes_apply` (`0x00482990`): the volumes again, after a setting changes: the
    /// music's, each voice's still playing, and the speech sample's.
    pub fn applyVolumes(sound: *Sound) void {
        const driver = sound.driver orelse return;
        sound.applyMusicVolume();
        for (0..sound.voice_count) |v| {
            if (driver.sampleStatus(sound.voices[v].sample) != .done) sound.setVoiceVolume(@intCast(v), sound.voices[v].volume);
        }
        if (sound.speech) |sample| driver.setSampleVolume(sample, sound.speechVolume(loudest));
    }

    /// The music's level, from 0 to 127, at once, as the CD player's volume turns it: the stream
    /// heard at it, scaled by the music volume and the master volume as `applyVolumes` scales it.
    pub fn setMusicLevel(sound: *Sound, level: i32) void {
        sound.music.level = level;
        sound.applyMusicVolume();
    }

    /// The music's stream at its level, scaled by the music volume and the master volume.
    fn applyMusicVolume(sound: *Sound) void {
        const driver = sound.driver orelse return;
        if (sound.music.stream) |stream| driver.setStreamVolume(stream, sound.volumes.mastered(sound.volumes.music, sound.music.level, loudest));
    }

    /// Runs the game's timer up to `now`, the platform's count of hundredths of a second: first
    /// the clocks (`tickTimer`), then the sound's fades (`timerTick`). The original runs
    /// `tick_timer` (`0x004827C0`) 100 times a second on its own multimedia timer (`timer_start`,
    /// `0x004A70F0`, started by `sound_init`), so its fades continue while a movie plays.
    /// OpenReliant calls this once a frame from the rooms' loop, the movies' loop and the wait
    /// before the launch. It then decodes more of a mod's piece that is still being decoded
    /// (`decodeMusic`). In the front end and in missions, `updateMusic` does that instead.
    pub fn runTimer(sound: *Sound, clock: *Clock, now: u64) void {
        clock.advanceTo(now);
        sound.timerTick(clock.game_ticks);
        sound.decodeMusic();
    }

    /// The sound half of `tick_timer` (`0x004827C0`): once at least five ticks have passed since
    /// the last step, it steps the music's fade and each fading voice's. OpenReliant calls it once
    /// a frame instead of from a timer of its own, which steps the fades the same as long as frames
    /// come more often than every five ticks.
    pub fn timerTick(sound: *Sound, game_ticks: u32) void {
        const driver = sound.driver orelse return;
        if (@as(i64, sound.faded_at) >= @as(i64, game_ticks) - fade_ticks) return;
        sound.faded_at = game_ticks;
        if (sound.music.stream) |stream| if (sound.music.fading and driver.streamStatus(stream) == .playing) {
            sound.music.level -= sound.music.fade_step;
            if (sound.music.level < 0) {
                sound.closeMusic();
                sound.music.fading = false;
            } else sound.applyVolumes();
        };
        for (sound.voices[0..sound.voice_count]) |*voice| {
            if (voice.fading == 0) continue;
            if (driver.sampleStatus(voice.sample) == .done) {
                voice.fading = 0;
                continue;
            }
            var volume = driver.sampleVolume(voice.sample) - voice.fade_step;
            if (volume < 1) {
                volume = 0;
                driver.endSample(voice.sample);
                voice.fading = 0;
            }
            driver.setSampleVolume(voice.sample, volume);
        }
    }

    // --- Positional sounds of a frame ------------------------------------------------------------

    /// `sound_buffer_at` (`0x00482160`): adds sound `index` at `position`, at `volume`, to the
    /// frame's positional sounds, its level in each ear by how far and which side of the camera it
    /// is. Only the first 18 are gathered.
    pub fn bufferAt(sound: *Sound, index: usize, position: Vector, view: camera.Place, volume: f32) void {
        if (index >= buffered_sounds) return;
        const loud = volume * buffered_loudness;
        const offset = position - view.position;
        const distance = math.length(offset);
        const across = math.transformTransposed(view.orientation, offset);
        const share = 1 / (distance * loudest);
        const side = across[0] * share;
        const left = std.math.clamp((if (side >= 0) 1 - side else 1) * share * loud, 0, 1);
        const right = std.math.clamp((if (side >= 0) 1 else side + 1) * share * loud, 0, 1);
        sound.buffered[index][0] += left;
        sound.buffered[index][1] += right;
    }

    /// `sound_buffers_play` (`0x004822F0`): plays each positional sound gathered this frame, sound
    /// `n` of `bank` for slot `n`, panned by its two levels and as loud as the louder, each rounded
    /// by `sr_round`, then forgets them.
    pub fn playBuffered(sound: *Sound, bank: fat.Bank) void {
        const effects: f32 = @floatFromInt(sound.volumes.effects);
        for (&sound.buffered, 0..) |*levels, index| {
            if (!(levels[0] > 0) and !(levels[1] > 0)) continue;
            const left = @min(levels[0], 1);
            const right = @min(levels[1], 1);
            const pan = math.round(right * rightmost / (right + left));
            const volume = math.round(effects * @max(left, right) * sound.volumes.masterShare());
            _ = sound.play(bank, index, volume, once, pan, own_pitch);
            levels.* = .{ 0, 0 };
        }
    }

    // --- The 3D voices ---------------------------------------------------------------------------

    /// `sound_3d_open` (`0x00481900`) on OpenReliant's one provider. Allocates as many free 3D
    /// voices as the provider has, up to 64, then sets up the effects on them (`sound3d.init`)
    /// with the bank `smp3d`. `modded` tells which of its sounds come from mods
    /// (`BankFile.modded`).
    pub fn open3D(sound: *Sound, smp3d: fat.Bank, modded: []const bool) void {
        const driver = sound.driver orelse return;
        sound.close3D();
        for (&sound.voices_3d) |*voice| {
            voice.* = Voice3D.free;
            voice.sample = driver.allocate3DSample() orelse break;
            sound.voice_3d_count += 1;
        }
        sound3d.init(sound, smp3d, modded);
    }

    /// `sound_3d_close` (`0x004818A0`).
    pub fn close3D(sound: *Sound) void {
        const driver = sound.driver orelse return;
        for (sound.voices_3d[0..sound.voice_3d_count]) |*voice| {
            driver.release3DSample(voice.sample);
            voice.* = Voice3D.free;
        }
        sound.voice_3d_count = 0;
        sound.engine_voice = null;
        sound.burner_voice = null;
    }

    /// `sound_3d_voice_end` (`0x00481AF0`): ends a 3D voice's sound and frees the voice. The object
    /// or missile it followed loses its voice.
    pub fn end3D(sound: *Sound, v: u8) void {
        const driver = sound.driver orelse return;
        const voice = &sound.voices_3d[v];
        if (voice.isFree()) return;
        if (sound.objects) |all| if (voice.ownerIndex()) |at| {
            const followed: ?*gameobj.GameObject = switch (voice.follows) {
                .object => if (at < all.slots.len) &all.slots[at].object else null,
                .missile => if (all.missiles.get(at)) |missile| &missile.slot.object else null,
                else => null,
            };
            // The game lets go of the object's voice whichever it is; only a missile's sound that
            // follows it gives it one (`sound3d.MissileSound`).
            if (followed) |object| if (object.sound_voice.index() == v) {
                object.sound_voice = .none;
            };
        };
        voice.priority = 0;
        voice._unknown_0c = 0;
        voice.owner = Voice3D.no_owner;
        voice.borrowed = false;
        voice.follows = .none;
        sound.starters_3d[v] = .game;
        driver.end3DSample(voice.sample);
    }

    /// Whether voice `v` is the one set aside for the player's engine or its afterburner's.
    pub fn reserved(sound: *const Sound, v: u8) bool {
        return sound.engine_voice == v or sound.burner_voice == v;
    }

    /// `sound_3d_end_all` (`0x00481BA0`): ends every 3D voice's sound, keeping what it held.
    pub fn end3DAll(sound: *Sound) void {
        const driver = sound.driver orelse return;
        for (sound.voices_3d[0..sound.voice_3d_count]) |*voice| {
            voice.priority = 0;
            voice._unknown_0c = 0;
            driver.end3DSample(voice.sample);
        }
    }

    /// `sound_3d_update` (`0x00481BF0`), once a frame: updates the player's engine sound
    /// (`sound3d.engineUpdate`), then each 3D voice. A voice whose sound has played its full length
    /// is freed, except the engine's and the afterburner's. The others are repositioned relative to
    /// the camera according to what they follow, and freed once out of range.
    ///
    /// Added by OpenReliant: a script sound (`sound3d.playOwn`) keeps its voice until it ends, so a
    /// looping one plays until it's stopped. It fades out toward the edge of its range
    /// (`sound3d.fadeToFar`), stays silent beyond it, and becomes audible again when it comes back
    /// in range.
    pub fn update3D(sound: *Sound, scene: Scene) void {
        const driver = sound.driver orelse return;
        if (sound.voice_3d_count == 0) return;
        sound3d.engineUpdate(sound, scene);
        // Added by OpenReliant: the listener moves with the player's ship, for the Doppler
        // shifts. The game opens no listener, and the software mixer's listener stays still.
        const player = &scene.objects.slots[scene.objects.player].object;
        driver.set3DListenerVelocity(miles(math.transformTransposed(scene.camera.orientation, player.velocity.vector()) * @as(Vector, @splat(velocity_scale))));
        const frame_start = scene.clock.frame_start;
        for (sound.voices_3d[0..sound.voice_3d_count], 0..) |*voice, index| {
            if (voice.isFree()) continue;
            const v: u8 = @intCast(index);
            const set_aside = sound.reserved(v);
            const scripted = sound.starters_3d[index] != .game;
            if (scripted) {
                if (driver.sample3DStatus(voice.sample) == .done) {
                    sound.end3D(v);
                    continue;
                }
            } else if (!set_aside) {
                // How long the sound plays, in ticks. The game divides the sound's size in bytes
                // of 16-bit PCM by the 441 bytes a tick plays at 22,050 Hz, by multiplying with a
                // rounded reciprocal (`0x004DC8B8`). **Improvement:** OpenReliant divides the
                // frames by the rate they play at, `sound3d.sample_rate` scaled for a mod's sound
                // (`sound3d.rateScale`), so a mod's sound at another rate or in stereo isn't cut
                // short or kept too long. The game's own sounds get the same length.
                const frames: f32 = @floatFromInt(driver.sample3DFrames(voice.sample));
                const ticks = math.round(frames / (sound3d.sample_rate * sound.effects.rate_scales[index]) * main.ticks_per_second);
                if (ticks < frame_start - voice.started) {
                    sound.end3D(v);
                    continue;
                }
            }
            var position: Vector = @splat(0);
            var direction: Vector = @splat(0);
            var velocity: Vector = @splat(0);
            var place = true;
            var face = true;
            var move = true;
            switch (voice.follows) {
                .shot, .none, _ => {
                    place = false;
                    face = false;
                    move = false;
                },
                // Where missiles' sounds follow them, one moves with its missile while the voice
                // is still that missile's.
                .missile => follow: {
                    if (sound.missile_sound == .follows) if (voice.ownerIndex()) |at| if (scene.objects.missiles.get(at)) |missile| if (missile.slot.object.sound_voice.index() == v) {
                        position = missile.slot.drawn.position;
                        velocity = missile.slot.object.velocity.vector();
                        direction = math.forward(missile.slot.drawn.orientation);
                        break :follow;
                    };
                    place = false;
                    face = false;
                    move = false;
                },
                .point_facing => {
                    position = voice.position.vector();
                    direction = voice.direction.vector();
                    move = false;
                },
                .point => {
                    place = false;
                    face = false;
                    move = false;
                },
                .object => {
                    // `sound3d.play` gives an object's voice its slot.
                    const at = voice.ownerIndex() orelse {
                        sound.end3D(v);
                        continue;
                    };
                    const slot = &scene.objects.slots[at];
                    if (slot.object.type.base() == .stand_in) {
                        sound.end3D(v);
                        continue;
                    }
                    position = if (at == scene.objects.player) slot.drawn.point(-sound3d.player_sound_offset) else slot.drawn.position;
                    velocity = slot.object.velocity.vector();
                    direction = math.forward(slot.drawn.orientation);
                },
            }
            const relative = (position - scene.camera.position) * @as(Vector, @splat(distance_scale));
            const in_range = set_aside or !place or math.dot(relative, relative) <= voice.range * voice.range;
            if (scripted) {
                driver.set3DSampleVolume(voice.sample, sound.effects.heardLevel(v, voice.range, math.length(relative)));
            } else if (!in_range) {
                sound.end3D(v);
                continue;
            }
            const heading = if (voice.follows == .point) Vector{ 0, 0, 1 } else math.normalize(math.transformTransposed(scene.camera.orientation, direction));
            if (place) driver.set3DPosition(voice.sample, miles(math.transformTransposed(scene.camera.orientation, relative)));
            if (face or voice.follows == .point) driver.set3DOrientation(voice.sample, miles(heading), mss.positional.up);
            if (move) driver.set3DVelocity(voice.sample, miles(math.transformTransposed(scene.camera.orientation, velocity) * @as(Vector, @splat(velocity_scale))));
        }
    }

    // --- Music -----------------------------------------------------------------------------------

    /// When a piece `playMusic` plays starts.
    pub const When = union(enum) {
        /// At once, closing what was playing.
        now,
        /// Once the music playing has faded out, which starts to fade at the timer's count given
        /// (`fadeMusic`).
        after_fade: u32,

        /// The `now` that `music_play` plays a piece at once for (`0x00482A9D`); any other waits
        /// for the music playing to fade out.
        const play_now: u32 = 1;

        /// When `music_play` plays a piece by its `now`, `game_ticks` the timer's count a fade
        /// starts at.
        pub fn of(now: u32, game_ticks: u32) When {
            return if (now == play_now) .now else .{ .after_fade = game_ticks };
        }
    };

    /// `music_play` (`0x00482A80`): plays the file at `path` `loops` times (0 loops forever) at
    /// `level`, starting when `when` says. A piece in the loop table loops back to its loop point
    /// instead of the start.
    pub fn playMusic(sound: *Sound, path: []const u8, loops: u32, level: i32, when: When) void {
        const driver = sound.driver orelse return;
        switch (when) {
            .now => {},
            .after_fade => |game_ticks| {
                sound.music.queued = .of(path, loops, level);
                sound.fadeMusic(queued_fade_step, game_ticks);
                return;
            },
        }
        sound.stopMusic();
        const files = sound.files orelse return;
        const read = readMusic(files, path) catch |err| {
            log.warn("the music {s} is left out: {t}", .{ path, err });
            return;
        };
        switch (read) {
            .whole => |whole| sound.startMusic(driver, files, .of(path, loops, level), whole.bytes, whole.from_mod),
            .decoding => |recording| sound.music.decoding = .{ .recording = recording, .piece = .of(path, loops, level) },
        }
    }

    /// The rest of `music_play`: opens `bytes`, the file of `piece`, as the music stream and starts
    /// it. If `from_mod` is set, the loop point moves to the same moment of the mod's piece
    /// (`modLoopStart`).
    fn startMusic(sound: *Sound, driver: mss.Driver, files: Files, piece: Music.Piece, bytes: []u8, from_mod: bool) void {
        const path = piece.pathOf();
        sound.music.file = bytes;
        const stream = driver.openStream(sound.music.file) orelse {
            log.warn("the music {s} cannot be played", .{path});
            files.gpa.free(sound.music.file);
            sound.music.file = &.{};
            return;
        };
        sound.music.stream = stream;
        sound.music.piece = piece;
        driver.setStreamLoopCount(stream, piece.loops);
        driver.setStreamPosition(stream, 0);
        const loop_start = if (from_mod) modLoopStart(files, path, bytes, musicLoopStart(path)) else musicLoopStart(path);
        driver.setStreamLoopBlock(stream, loop_start, -1);
        // The game sets the position to the loop's start, negated, which Miles takes as nothing.
        driver.setStreamPosition(stream, -loop_start);
        sound.music.level = piece.level;
        sound.applyVolumes();
        driver.startStream(stream);
        if (sound.music.held) driver.pauseStream(stream, true);
    }

    /// Decodes `seconds_decoded_a_pass` more seconds of a mod's piece. Once the piece is fully
    /// decoded, starts it, paused if the music was paused during the decoding.
    fn decodeMusic(sound: *Sound) void {
        const decoding = if (sound.music.decoding) |*pending| pending else return;
        const files = sound.files orelse return;
        const driver = sound.driver orelse return;
        const recording = &decoding.recording;
        const done = recording.step(files.gpa, seconds_decoded_a_pass * recording.audio.rate) catch |err| {
            log.warn("the music {s} is left out: {t}", .{ decoding.piece.pathOf(), err });
            sound.cancelDecoding();
            return;
        };
        if (!done) return;
        var decoded = decoding.*;
        sound.music.decoding = null;
        // Finishing frees the decoder and the mod's file, whether or not it makes the WAVE file.
        const bytes = decoded.recording.finish(files.gpa) catch |err| {
            log.warn("the music {s} is left out: {t}", .{ decoded.piece.pathOf(), err });
            return;
        };
        sound.startMusic(driver, files, decoded.piece, bytes, true);
        if (decoded.paused) sound.pauseMusic(true);
    }

    /// Cancels the decoding of a mod's piece, which then never plays.
    fn cancelDecoding(sound: *Sound) void {
        const decoding = if (sound.music.decoding) |*pending| pending else return;
        const gpa = (sound.files orelse return).gpa;
        decoding.recording.deinit(gpa);
        sound.music.decoding = null;
    }

    /// The frame's sounds, as `mission_frame` and `mission_paused_frame` play them: the music
    /// waiting its turn, the positional sounds gathered from `bank`, and the 3D sounds placed
    /// again, heard from `scene`'s camera.
    pub fn frame(sound: *Sound, bank: fat.Bank, scene: Scene) void {
        sound.updateMusic();
        sound.playBuffered(bank);
        sound.update3D(scene);
    }

    /// `music_update` (`0x00482C30`), called once a frame: starts the queued piece once the music
    /// has stopped. OpenReliant first decodes more of a mod's piece that is still being decoded
    /// (`decodeMusic`).
    pub fn updateMusic(sound: *Sound) void {
        sound.decodeMusic();
        const queued = sound.music.queued orelse return;
        if (sound.musicPlaying()) return;
        sound.music.queued = null;
        sound.playMusic(queued.pathOf(), queued.loops, queued.level, .now);
    }

    /// `music_fade_out` (`0x00482960`): starts fading the music out by `step` every five ticks,
    /// counting from `game_ticks`, the timer's count now, until it stops.
    ///
    /// A mod's piece that is still being decoded is cancelled and never plays.
    pub fn fadeMusic(sound: *Sound, step: i32, game_ticks: u32) void {
        if (sound.music.stream == null) return sound.cancelDecoding();
        sound.music.fading = true;
        sound.music.fade_step = step;
        sound.faded_at = game_ticks;
    }

    /// `music_playing` (`0x00482940`). A mod's piece that is still being decoded counts as
    /// playing, and so does a piece paused because the window is inactive (`holdMusic`).
    pub fn musicPlaying(sound: *Sound) bool {
        const driver = sound.driver orelse return false;
        if (sound.music.decoding != null) return true;
        const stream = sound.music.stream orelse return false;
        return switch (driver.streamStatus(stream)) {
            .playing => true,
            .stopped => sound.music.held,
            else => false,
        };
    }

    /// `music_pause` (`0x00482C70`) and `music_resume` (`0x00482C90`).
    pub fn pauseMusic(sound: *Sound, paused: bool) void {
        const driver = sound.driver orelse return;
        if (sound.music.stream) |stream| driver.pauseStream(stream, paused);
        if (sound.music.decoding) |*pending| pending.paused = paused;
    }

    /// `music_pause` and `music_resume` as the message pump calls them when the game's window
    /// becomes inactive and active again (`winmain.followActivation`). The game's pump blocks
    /// until the window is active again, so nothing else runs in between. OpenReliant's loops keep
    /// running, so the paused piece counts as playing (`musicPlaying`), and a piece that starts in
    /// between starts paused. Otherwise the CD player would take the paused piece for one that has
    /// ended and play its next track.
    pub fn holdMusic(sound: *Sound, held: bool) void {
        sound.music.held = held;
        sound.pauseMusic(held);
    }

    /// `music_close` (`0x00482CF0`). It also cancels a mod's piece that is still decoding.
    pub fn closeMusic(sound: *Sound) void {
        sound.cancelDecoding();
        if (sound.music.stream) |stream| if (sound.driver) |driver| driver.closeStream(stream);
        sound.music.stream = null;
        sound.music.piece = null;
        if (sound.music.file.len > 0) if (sound.files) |files| files.gpa.free(sound.music.file);
        sound.music.file = &.{};
    }

    /// Stops the music at once and drops any queued piece, as `music_play` does before it starts a
    /// piece at once.
    pub fn stopMusic(sound: *Sound) void {
        sound.closeMusic();
        sound.music.fading = false;
        sound.music.queued = null;
    }

    /// Added by OpenReliant: the path of the piece playing, or of a mod's piece still being
    /// decoded. Returns null while no music plays (`musicPlaying`).
    pub fn pieceOn(sound: *Sound) ?[]const u8 {
        if (!sound.musicPlaying()) return null;
        if (sound.music.decoding) |*pending| return pending.piece.pathOf();
        return if (sound.music.piece) |*playing| playing.pathOf() else null;
    }

    /// The game timer's current tick count, which fades count from, or 0 before the game sets its
    /// clock.
    pub fn gameTicks(sound: *const Sound) u32 {
        return if (sound.clock) |clock| clock.game_ticks else 0;
    }

    // --- Script sounds ---------------------------------------------------------------------------

    /// The voice a script sound plays on: a voice or a 3D voice.
    pub const Playing = union(enum) {
        voice: u8,
        voice_3d: u8,
    };

    /// Added by OpenReliant: the voice the script sound `starter` plays on. Returns null once the
    /// sound has ended, or once a game sound has taken its voice. A paused sound still counts as
    /// playing.
    pub fn playingOf(sound: *Sound, starter: Starter) ?Playing {
        const driver = sound.driver orelse return null;
        if (starter == .game) return null;
        for (sound.voices[0..sound.voice_count], sound.starters[0..sound.voice_count], 0..) |voice, started, v| {
            if (started == starter and driver.sampleStatus(voice.sample) != .done) return .{ .voice = @intCast(v) };
        }
        for (sound.voices_3d[0..sound.voice_3d_count], sound.starters_3d[0..sound.voice_3d_count], 0..) |voice, started, v| {
            if (started == starter and !voice.isFree() and driver.sample3DStatus(voice.sample) != .done) return .{ .voice_3d = @intCast(v) };
        }
        return null;
    }

    /// Added by OpenReliant: stops the script sound `starter` if it is still playing.
    pub fn endStarted(sound: *Sound, starter: Starter) void {
        switch (sound.playingOf(starter) orelse return) {
            .voice => |v| sound.endVoice(v),
            .voice_3d => |v| sound.end3D(v),
        }
    }
};

/// `sound_pitch_factor` (`0x00481400`): what `n` quarter tones multiply a rate by, from a sixteenth
/// at 96 down to sixteen at 96 up. **Improvement:** the game looks it up in a table of rounded
/// powers of two; OpenReliant works it out.
pub fn pitchFactor(n: i32) f32 {
    const clamped = std.math.clamp(n, -max_quarter_tones, max_quarter_tones);
    return std.math.pow(f32, 2, @as(f32, @floatFromInt(clamped)) / quarter_tones_per_octave);
}

/// The name of a piece of music as passed to `cmd_PlayMusic`: the path without the music folder,
/// that is, everything after the first `\`.
pub fn pieceName(path: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, path, '\\')) |at| path[at + 1 ..] else path;
}

/// The byte offset a piece of music loops back to (`music_play`): the offset of the first loop
/// table entry that the piece's name (`pieceName`) starts with, ignoring case, or 0.
pub fn musicLoopStart(path: []const u8) i32 {
    const name = pieceName(path);
    for (music_loops) |piece| {
        if (name.len >= piece.name.len and std.ascii.eqlIgnoreCase(name[0..piece.name.len], piece.name)) return piece.loop_start;
    }
    return 0;
}

/// A music file that was read: a whole WAVE file and whether it came from a mod, or a mod's file
/// in another format that is being decoded to WAVE.
const MusicRead = union(enum) {
    whole: struct { bytes: []u8, from_mod: bool },
    decoding: recordings.Decoding,
};

/// Reads the music file at `path`, a game path with backslashes. A mod's recording with the same
/// name, in any format a recording can have (`recordings.Kind`), takes priority. Otherwise it
/// reads the game folder's file, ignoring case as Windows does (`files.find`).
///
/// **Improvement:** the original plays only its own WAVE files.
fn readMusic(files: Files, path: []const u8) !MusicRead {
    const name = Io.Dir.path.stem(paths.leaf(path));
    if (files.recordings.find(files.gpa, name)) |found| {
        if (files.recordings.open(files.gpa, found, name)) |opened| return switch (opened) {
            .wave => |bytes| .{ .whole = .{ .bytes = bytes, .from_mod = true } },
            .decoding => |recording| .{ .decoding = recording },
        };
    }
    return .{ .whole = .{ .bytes = try readGameMusic(files, path), .from_mod = false } };
}

/// The game folder's music file at `path`, read whole into `files.gpa`.
fn readGameMusic(files: Files, path: []const u8) ![]u8 {
    return try paths.readFile(files.io, files.gpa, files.dir, path, .limited(paths.max_file_size)) orelse error.FileNotFound;
}

/// Where a mod's piece of music `own`, which replaces the game's piece at `path`, loops back to.
/// The loop table's `loop_start` is a byte offset into the game's file, so it is converted to the
/// same point in time in the mod's piece. If the game's file can't be read or isn't a WAVE file,
/// the log says so and `loop_start` is used unchanged.
///
/// **Improvement:** the original reads no mods. Without the conversion, a mod's piece in another
/// format than the game's, such as 16-bit PCM at 44,100 Hz instead of IMA ADPCM at 22,050 Hz,
/// would loop back to the wrong point.
fn modLoopStart(files: Files, path: []const u8, own: []const u8, loop_start: i32) i32 {
    if (loop_start <= 0) return loop_start;
    return carriedModLoop(files, path, own, @intCast(loop_start)) catch |err| {
        log.warn("the mod's music {s} may loop back to the wrong moment, since the game's piece can't be read: {t}", .{ path, err });
        return loop_start;
    };
}

/// The byte offset into the mod's piece `own` that plays at the same moment as `loop_start` bytes
/// into the game's piece at `path`.
fn carriedModLoop(files: Files, path: []const u8, own: []const u8, loop_start: u32) !i32 {
    const game = try readGameMusic(files, path);
    defer files.gpa.free(game);
    const original = try wave.Wave.parse(game);
    // The stream has opened the mod's piece already (`Sound.playMusic`), so it parses.
    const replacement = try wave.Wave.parse(own);
    return @intCast(carriedLoop(original, replacement, loop_start));
}

/// The byte offset into `replacement` at the moment of `original` that `offset` bytes into it
/// falls on.
fn carriedLoop(original: wave.Wave, replacement: wave.Wave, offset: u32) u32 {
    if (original.rate == 0) return offset;
    const frame: u64 = original.frameAt(offset);
    return replacement.offsetOf(@intCast(frame * replacement.rate / original.rate));
}

/// A camera-space vector as Miles takes it: the camera's `y` points down, Miles's up.
pub fn miles(v: Vector) mss.Vector {
    return .{ v[0], -v[1], v[2] };
}

/// What `tick_timer` (`0x004827C0`) does to the mission's clocks, 100 times a second. Its other
/// half steps the fades (`Sound.timerTick`). **Unverified:** it lies after this file's known code,
/// before `hud.cpp`'s.
pub fn tickTimer(clock: *Clock) void {
    clock.timer_ticks +%= 1;
    if (clock.paused) return;
    clock.game_ticks +%= 1;
    clock.play.ticks += 1;
    if (clock.play.ticks > main.ticks_per_second) {
        clock.play.ticks = 0;
        // Each unit rolls when it stood past `rollover_after` before this one.
        const second_over = clock.play.seconds > rollover_after;
        clock.play.seconds += 1;
        if (second_over) {
            clock.play.seconds = 0;
            const minute_over = clock.play.minutes > rollover_after;
            clock.play.minutes += 1;
            if (minute_over) {
                clock.play.minutes = 0;
                clock.play.hours +%= 1;
            }
        }
    }
}

pub const testing = struct {
    /// A bank of `count` sounds, each four frames of 16-bit PCM, the `n`th at priority `n * 10`.
    pub fn bank(comptime count: usize) [fat.header_size + count * @sizeOf(fat.Entry) + count * sound_file.len]u8 {
        var bytes: [fat.header_size + count * @sizeOf(fat.Entry) + count * sound_file.len]u8 = undefined;
        @memcpy(bytes[0..fat.header_size], std.mem.asBytes(&fat.Header{ .magic = fat.magic.*, .count = count }));
        for (0..count) |n| {
            const offset = fat.header_size + count * @sizeOf(fat.Entry) + n * sound_file.len;
            const entry: fat.Entry = .{ .offset = offset, .size = sound_file.len, .priority = n * 10 };
            @memcpy(bytes[fat.header_size + n * @sizeOf(fat.Entry) ..][0..@sizeOf(fat.Entry)], std.mem.asBytes(&entry));
            @memcpy(bytes[offset..][0..sound_file.len], sound_file);
        }
        return bytes;
    }

    pub const sound_file = wave.testing.steady(4, 16384);

    /// A sound player on a mixer of its own, heard from the origin. It stays where `init` fills it
    /// in, as the sound holds the mixer.
    pub const Speaker = struct {
        mixer: mss.Mixer,
        sound: Sound,
        listener: camera.Place,

        /// The mixer's frames a second, those of `sound_file`.
        pub const rate = 22050;

        /// `voices` voices, with `stdsmp` as the sounds' bank where given.
        pub fn init(speaker: *Speaker, voices: u8, stdsmp: ?[]const u8) !void {
            speaker.mixer = .init(rate);
            speaker.listener = .{};
            speaker.sound.init(speaker.mixer.driver(), voices, null);
            if (stdsmp) |bytes| speaker.sound.stdsmp = try fat.Bank.parse(bytes);
        }

        /// How the world hears it, from the origin, on `clock`.
        pub fn hearing(speaker: *Speaker, clock: *const Clock) Hearing {
            return .{ .sound = &speaker.sound, .camera = &speaker.listener, .clock = clock };
        }

        /// Whether any of its voices plays.
        pub fn playing(speaker: *Speaker) bool {
            for (0..speaker.sound.voice_count) |v| {
                if (speaker.sound.voicePlaying(@intCast(v))) return true;
            }
            return false;
        }
    };
};

test "Sound.playInScene plays as play does" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(1);
    const bank = try fat.Bank.parse(&bytes);
    try std.testing.expectEqual(1, sound.playInScene(bank, 0, loudest, once, centre, own_pitch));
    try std.testing.expect(sound.voicePlaying(1));
}

test "Sound.playStandard plays from the standard samples" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    // Without the bank, nothing plays.
    try std.testing.expectEqual(null, sound.playStandard(0, loudest, once, centre, own_pitch));
    const bytes = comptime testing.bank(1);
    sound.stdsmp = try fat.Bank.parse(&bytes);
    try std.testing.expectEqual(1, sound.playStandard(0, loudest, once, centre, own_pitch));
    try std.testing.expect(sound.voicePlaying(1));
}

test "a script sound plays under its ID until it ends or a game sound takes its voice" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const driver = speaker.mixer.driver();
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(3);
    const bank = try fat.Bank.parse(&bytes);
    const starter: Starter = @fromBackingInt(7);
    // It plays at its rate times the factor, and is found by its ID, never by `.game`.
    const v = sound.playFile(testing.sound_file, .{ .priority = script_priority, .rate_factor = 2, .loops = forever, .starter = starter }).?;
    try std.testing.expectEqual(Sound.Playing{ .voice = v }, sound.playingOf(starter).?);
    try std.testing.expectEqual(null, sound.playingOf(.game));
    try std.testing.expectEqual(2 * testing.Speaker.rate, speaker.mixer.samples[@backingInt(sound.voices[v].sample)].state.playing.?.rate);
    // Stopped by its ID, it is no longer found.
    sound.endStarted(starter);
    try std.testing.expectEqual(mss.Status.done, driver.sampleStatus(sound.voices[v].sample));
    try std.testing.expectEqual(null, sound.playingOf(starter));
    // With every voice busy, a script sound gets no voice, and a game sound with a higher
    // priority takes the script sound's voice.
    const again = sound.playFile(testing.sound_file, .{ .priority = script_priority, .loops = forever, .starter = starter }).?;
    sound.playOn(1 - again, bank, 2, loudest, forever, centre, own_pitch);
    try std.testing.expectEqual(null, sound.playFile(testing.sound_file, .{ .priority = script_priority, .starter = @fromBackingInt(8) }));
    try std.testing.expectEqual(again, sound.play(bank, 1, loudest, once, centre, own_pitch));
    try std.testing.expectEqual(null, sound.playingOf(starter));
    // A line of speech on the voice of a finished script sound belongs to the game.
    sound.endAll();
    const spoken = sound.playFile(testing.sound_file, .{ .priority = script_priority, .starter = starter }).?;
    var out: [64][2]f32 = undefined;
    speaker.mixer.mix(&out);
    sound.speakOn(spoken, testing.sound_file);
    try std.testing.expectEqual(null, sound.playingOf(starter));
}

test "Sound.speakOn holds its voice" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(3, null);
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(1);
    const bank = try fat.Bank.parse(&bytes);
    // The voice's sound ends, and the line plays on it with the voice held.
    sound.playOn(2, bank, 0, loudest, forever, centre, own_pitch);
    sound.speakOn(2, testing.sound_file);
    try std.testing.expect(sound.voicePlaying(2));
    try std.testing.expectEqual(1, sound.voices[2].held);
    // No other sound takes the voice.
    for (0..3) |_| try std.testing.expect(sound.play(bank, 0, loudest, once, centre, own_pitch) != 2);
    // Ending the voice releases it.
    sound.endVoice(2);
    try std.testing.expectEqual(0, sound.voices[2].held);
}

test "BankFile.of puts mods' sounds in place of the bank's own" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A mod gives the second sound of a bank of three in WAV at 44,100 Hz, the third in FLAC in
    // stereo, and the first in a file that can't be played.
    const bytes = comptime testing.bank(3);
    const own = comptime wave.testing.pcmAt(44100, "\x01\x00\x02\x00");
    const lossless = try @import("../../formats/flac.zig").testing.constant(gpa, 11025, &.{ 3, 4 }, 8);
    defer gpa.free(lossless);
    try tmp.dir.createDirPath(io, "mods/a");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/three_000.wav", .data = "not a WAVE file" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/THREE_001.wav", .data = own });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/three_002.flac", .data = lossless });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    var decoders: bink.testing.Decoders = .{};
    const source: recordings.Source = .{ .mods = &mods, .codec = decoders.codec() };
    const original = try fat.Bank.parse(&bytes);

    const file = BankFile.of(gpa, try gpa.dupe(u8, &bytes), "sounds\\three.fat", source).?;
    defer file.deinit(gpa);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, file.modded);
    try std.testing.expectEqualSlices(u8, original.sound(0).?, file.bank.sound(0).?);
    try std.testing.expectEqualSlices(u8, own, file.bank.sound(1).?);
    const decoded = try wave.Wave.parse(file.bank.sound(2).?);
    try std.testing.expectEqual(11025, decoded.rate);
    try std.testing.expectEqual(2, decoded.channels);
    // Each sound keeps its entry's priority.
    for (original.entries, file.bank.entries) |before, after| try std.testing.expectEqual(before.priority, after.priority);
    try std.testing.expectEqual(0, decoders.streams);
    // A bank that no mod gives a sound for stays as it is.
    const other = BankFile.of(gpa, try gpa.dupe(u8, &bytes), "other.fat", source).?;
    defer other.deinit(gpa);
    try std.testing.expectEqual(0, other.modded.len);
    try std.testing.expectEqualSlices(u8, &bytes, other.bytes);
}

test BankFile {
    const gpa = std.testing.allocator;
    const bytes = comptime testing.bank(2);
    const file = BankFile.of(gpa, try gpa.dupe(u8, &bytes), "two.fat", .none).?;
    defer file.deinit(gpa);
    try std.testing.expectEqual(2, file.bank.entries.len);
    // Bytes that are not a bank are rejected and freed.
    try std.testing.expectEqual(null, BankFile.of(gpa, try gpa.dupe(u8, "x"), "x.fat", .none));
}

test "Volumes.read" {
    // The file's volumes, within range, and the defaults for any it lacks.
    const settings: profile.Profile = .{ .text = "[Sound]\nMastervolume=100\nFxvolume=300\n" };
    try std.testing.expectEqual(Volumes{ .master = 100, .effects = 127, .music = 80, .speech = 127 }, Volumes.read(settings));
    try std.testing.expectEqual(Volumes{}, Volumes.read(.empty));
}

test "Sound.When.of" {
    // At once only for exactly 1; any other value fades the music playing out first.
    try std.testing.expectEqual(Sound.When.now, Sound.When.of(1, 7));
    for ([_]u32{ 0, 2, 0xFFFF_FFFF }) |now| try std.testing.expectEqual(Sound.When{ .after_fade = 7 }, Sound.When.of(now, 7));
}

test {
    std.testing.refAllDecls(@This());
}

test "Sound.play takes a free voice, else the lowest priority below its own" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(3, null);
    const driver = speaker.mixer.driver();
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(4);
    const bank = try fat.Bank.parse(&bytes);

    // Voice 0 is passed over while another has finished.
    try std.testing.expectEqual(1, sound.play(bank, 1, loudest, once, centre, own_pitch));
    try std.testing.expectEqual(2, sound.play(bank, 2, loudest, once, centre, own_pitch));
    try std.testing.expectEqual(10, sound.voices[1].priority);
    // Voice 0 has never played, so it takes the next; then all are busy.
    try std.testing.expectEqual(0, sound.play(bank, 1, loudest, once, centre, own_pitch));
    // A sound of priority 30 takes over the lowest, 10, on voice 0; one of 0 takes nothing.
    try std.testing.expectEqual(0, sound.play(bank, 3, loudest, once, centre, own_pitch));
    try std.testing.expectEqual(null, sound.play(bank, 0, loudest, once, centre, own_pitch));
    // A held voice is never taken over.
    sound.voices[1].held = 1;
    try std.testing.expectEqual(null, sound.play(bank, 1, loudest, once, centre, own_pitch));

    // The effects volume, 80, and the master's scale the volume asked for.
    try std.testing.expectEqual(@divTrunc(80 * 127, 128), driver.sampleVolume(sound.voices[0].sample));
}

test "Sound.timerTick steps the fades every five ticks" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const driver = speaker.mixer.driver();
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(2);
    const bank = try fat.Bank.parse(&bytes);
    const v = sound.play(bank, 1, loudest, forever, centre, own_pitch).?;
    const start = driver.sampleVolume(sound.voices[v].sample);
    sound.fadeVoice(v, 30);
    sound.timerTick(6);
    try std.testing.expectEqual(start - 30, driver.sampleVolume(sound.voices[v].sample));
    // Not again until five ticks have passed.
    sound.timerTick(8);
    try std.testing.expectEqual(start - 30, driver.sampleVolume(sound.voices[v].sample));
    sound.timerTick(12);
    sound.timerTick(18);
    try std.testing.expectEqual(mss.Status.done, driver.sampleStatus(sound.voices[v].sample));
    try std.testing.expectEqual(0, sound.voices[v].fading);
}

test "Sound.runTimer keeps fading after the clock starts again" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const driver = speaker.mixer.driver();
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(2);
    const bank = try fat.Bank.parse(&bytes);
    var clock: Clock = .{};
    clock.start(0);
    sound.runTimer(&clock, 1_000);
    // A loop starts the clocks again, as the ITAC does as it opens, and later a voice fades.
    clock.start(50_000);
    const v = sound.play(bank, 1, loudest, forever, centre, own_pitch).?;
    const start = driver.sampleVolume(sound.voices[v].sample);
    sound.fadeVoice(v, 30);
    // The fade steps as soon as five ticks have passed.
    sound.runTimer(&clock, 50_006);
    try std.testing.expectEqual(start - 30, driver.sampleVolume(sound.voices[v].sample));
}

test "Sound pauses and resumes its voices" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const driver = speaker.mixer.driver();
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(2);
    const bank = try fat.Bank.parse(&bytes);
    const v = sound.play(bank, 1, loudest, forever, centre, own_pitch).?;
    sound.pauseAll();
    try std.testing.expectEqual(mss.Status.stopped, driver.sampleStatus(sound.voices[v].sample));
    sound.resumeAll();
    try std.testing.expectEqual(mss.Status.playing, driver.sampleStatus(sound.voices[v].sample));
}

test "Sound knows the cockpit's bank" {
    var sound: Sound = undefined;
    sound.init(null, 0, null);
    const bytes = comptime testing.bank(2);
    // A copy of its own, at another address.
    var other = bytes;
    const bank = try fat.Bank.parse(&bytes);
    try std.testing.expect(!sound.fromCockpit(bank));
    sound.betty = bank;
    try std.testing.expect(sound.fromCockpit(bank));
    try std.testing.expect(!sound.fromCockpit(try fat.Bank.parse(&other)));
}

test "Sound gathers positional sounds and plays them panned" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(4, null);
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(4);
    const bank = try fat.Bank.parse(&bytes);
    // Close by to the right: the right ear takes all of it, the left a little less.
    sound.bufferAt(2, .{ 0.05, 0, 0.1 }, speaker.listener, 1);
    try std.testing.expect(sound.buffered[2][1] > 0);
    try std.testing.expect(sound.buffered[2][0] <= sound.buffered[2][1]);
    // Past the eighteenth, nothing is gathered.
    sound.bufferAt(20, .{ 1, 0, 0 }, speaker.listener, 1);
    try std.testing.expectEqual([2]f32{ 0, 0 }, sound.buffered[20]);
    sound.playBuffered(bank);
    try std.testing.expectEqual([2]f32{ 0, 0 }, sound.buffered[2]);
}

test "Sound.playBuffered rounds as sr_round does" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(4, null);
    const sound = &speaker.sound;
    sound.volumes = .{ .master = loudest, .effects = 125 };
    const bytes = comptime testing.bank(4);
    const bank = try fat.Bank.parse(&bytes);
    // Half as loud as 125 is 62.5, which rounds to the even 62.
    sound.buffered[1] = .{ 0.5, 0.5 };
    sound.playBuffered(bank);
    var played: ?i32 = null;
    for (sound.voices) |voice| {
        if (voice.volume != 0) played = voice.volume;
    }
    try std.testing.expectEqual(62, played);
}

test "Sound.fadeAll fades every voice that has not finished" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(3, null);
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(2);
    const bank = try fat.Bank.parse(&bytes);
    const v = sound.play(bank, 1, loudest, forever, centre, own_pitch).?;
    sound.voices[v].held = 1;
    sound.fadeAll(30);
    // The playing voice fades, held or not, and any sound may take it over.
    try std.testing.expectEqual(1, sound.voices[v].fading);
    try std.testing.expectEqual(30, sound.voices[v].fade_step);
    try std.testing.expectEqual(0, sound.voices[v].held);
    try std.testing.expectEqual(0, sound.voices[v].priority);
    // One that never played has nothing to fade.
    try std.testing.expectEqual(0, sound.voices[if (v == 0) 1 else 0].fading);
}

test "Volumes.mastered" {
    const volumes: Volumes = .{ .master = 64 };
    // 80 of 128 of 127 is 79 in whole numbers, which 64 of 127 makes 39.8, rounded to 40.
    try std.testing.expectEqual(40, volumes.mastered(80, loudest, start_divisor));
    try std.testing.expectEqual(0, volumes.mastered(0, loudest, loudest));
}

test "Voice3D" {
    var voice: Voice3D = .free;
    try std.testing.expect(voice.isFree());
    try std.testing.expectEqual(null, voice.ownerIndex());
    voice.owner = 7;
    try std.testing.expect(!voice.isFree());
    try std.testing.expectEqual(7, voice.ownerIndex());
}

test "Sound.reserved" {
    var sound: Sound = .{ .engine_voice = 3, .burner_voice = 5 };
    try std.testing.expect(sound.reserved(3) and sound.reserved(5));
    try std.testing.expect(!sound.reserved(4));
    sound.burner_voice = null;
    try std.testing.expect(!sound.reserved(5));
}

test "the sound follows what surrounds the camera" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    try std.testing.expectEqual(.space, sound.surroundings);
    sound.surround(.hangar);
    try std.testing.expectEqual(.hangar, sound.surroundings);
    sound.surround(.space);
    try std.testing.expectEqual(.space, sound.surroundings);
}

test carriedLoop {
    const game_data: [256 * 1024]u8 = @splat(0);
    const mod_data: [2 * 1024 * 1024]u8 = @splat(0);
    // Mission 1's piece loops back 188318 bytes into the game's IMA ADPCM, in its 183rd block, at
    // 22050 frames a second; a mod's 16-bit PCM at 44100 loops back at the same moment, twice the
    // frames in.
    const game_piece: wave.Wave = .{ .format = .ima_adpcm, .channels = 2, .rate = 22050, .bits = 4, .block_align = 1024, .frames_per_block = 1017, .frames = null, .data = &game_data };
    const mod_piece: wave.Wave = .{ .format = .pcm, .channels = 2, .rate = 44100, .bits = 16, .block_align = 4, .frames_per_block = 0, .frames = null, .data = &mod_data };
    try std.testing.expectEqual(183 * 1017 * 2 * 4, carriedLoop(game_piece, mod_piece, 188318));
    // A mod's piece in the game's format keeps the table's block.
    try std.testing.expectEqual(183 * 1024, carriedLoop(game_piece, game_piece, 188318));
}

test modLoopStart {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files: Files = .{ .gpa = gpa, .io = io, .dir = tmp.dir };
    // A mod's 16-bit stereo piece at 44,100 Hz, eight frames long.
    const own = comptime wave.testing.file(.{ .format = .pcm, .channels = 2, .rate = 44100, .byte_rate = 176400, .block_align = 4, .bits = 16 }, "", "", &@as([32]u8, @splat(0)));
    // Without the game's piece, or with a game's piece that isn't a WAVE file, the table's offset
    // stays as it is.
    try std.testing.expectEqual(4, modLoopStart(files, "music\\one.wav", own, 4));
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/one.wav", .data = "not a wave" });
    try std.testing.expectEqual(4, modLoopStart(files, "music\\one.wav", own, 4));
    // Two frames into the game's mono piece at 22,050 Hz is four frames into the mod's.
    try tmp.dir.writeFile(io, .{ .sub_path = "music/one.wav", .data = testing.sound_file });
    try std.testing.expectEqual(16, modLoopStart(files, "music\\one.wav", own, 4));
}

test "a mod's piece in FLAC or MP3 decodes over the passes, then plays in place of the game's" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/one.wav", .data = testing.sound_file });
    const flac = try @import("../../formats/flac.zig").testing.constant(gpa, 44100, &.{ 1, 2 }, 64);
    defer gpa.free(flac);
    try tmp.dir.createDirPath(io, "mods/a");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/One.flac", .data = flac });
    const frames = @import("../../formats/mp3.zig").testing.silence(2);
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/two.mp3", .data = &frames });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    var decoders: bink.testing.Decoders = .{};
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    sound.files = .{ .gpa = gpa, .io = io, .dir = tmp.dir, .recordings = .{ .mods = &mods, .codec = decoders.codec() } };
    defer sound.closeMusic();
    var clock: Clock = .{};

    // Asked for the game's piece, the mod's FLAC file plays in its place. While it decodes, it
    // counts as playing, and a pause applies to it.
    sound.playMusic("music\\one.wav", forever, loudest, .now);
    try std.testing.expect(sound.music.decoding != null and sound.music.stream == null and sound.musicPlaying());
    sound.pauseMusic(true);
    // Decoded on the next frame of the front end or a mission, it plays paused, at the FLAC file's
    // rate.
    sound.updateMusic();
    try std.testing.expect(sound.music.decoding == null and sound.music.stream != null and !sound.musicPlaying());
    try std.testing.expectEqual(44100, (try wave.Wave.parse(sound.music.file)).rate);
    sound.pauseMusic(false);
    try std.testing.expect(sound.musicPlaying());
    // A piece faded before it starts never plays.
    sound.playMusic("music\\one.wav", forever, loudest, .now);
    sound.fadeMusic(10, 0);
    try std.testing.expect(sound.music.decoding == null and !sound.musicPlaying());
    // The timer that the rooms and the movies run decodes it too.
    sound.playMusic("music\\one.wav", forever, loudest, .now);
    sound.runTimer(&clock, 1);
    try std.testing.expect(sound.music.decoding == null and sound.music.stream != null and sound.musicPlaying());
    // A mod's piece in MP3 decodes the same way, at its own rate.
    sound.playMusic("music\\two.wav", forever, loudest, .now);
    try std.testing.expect(sound.music.decoding != null);
    sound.updateMusic();
    try std.testing.expect(sound.music.decoding == null and sound.musicPlaying());
    try std.testing.expectEqual(22050, (try wave.Wave.parse(sound.music.file)).rate);
    try std.testing.expectEqual(0, decoders.streams);
    // Without a codec, the game's piece plays at once.
    sound.files.?.recordings.codec = null;
    sound.playMusic("music\\one.wav", forever, loudest, .now);
    try std.testing.expect(sound.music.decoding == null and sound.musicPlaying());
    try std.testing.expectEqual(testing.Speaker.rate, (try wave.Wave.parse(sound.music.file)).rate);
}

test "Sound.playMusic queues a piece until the music has stopped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/one.wav", .data = testing.sound_file });
    try tmp.dir.writeFile(io, .{ .sub_path = "music/two.wav", .data = testing.sound_file });
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    sound.files = .{ .gpa = gpa, .io = io, .dir = tmp.dir };
    defer sound.closeMusic();

    sound.playMusic("music\\one.wav", forever, loudest, .now);
    try std.testing.expect(sound.musicPlaying());
    // Queued, the next piece waits while the music playing fades out.
    sound.playMusic("music\\two.wav", once, 100, .{ .after_fade = 40 });
    try std.testing.expect(sound.music.fading);
    try std.testing.expectEqual(40, sound.faded_at);
    const queued = sound.music.queued.?;
    try std.testing.expectEqualStrings("music\\two.wav", queued.pathOf());
    sound.updateMusic();
    try std.testing.expectEqual(loudest, sound.music.level);
    // Once the music has stopped, the queued piece starts at its own level.
    sound.closeMusic();
    sound.updateMusic();
    try std.testing.expectEqual(null, sound.music.queued);
    try std.testing.expect(sound.musicPlaying() and !sound.music.fading);
    try std.testing.expectEqual(100, sound.music.level);
}

test "Sound.holdMusic pauses the music while the window is inactive, and it counts as playing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/one.wav", .data = testing.sound_file });
    try tmp.dir.writeFile(io, .{ .sub_path = "music/two.wav", .data = testing.sound_file });
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const driver = speaker.mixer.driver();
    const sound = &speaker.sound;
    sound.files = .{ .gpa = gpa, .io = io, .dir = tmp.dir };
    defer sound.closeMusic();

    // While paused for the window, the music counts as playing, so a queued piece waits.
    sound.playMusic("music\\one.wav", once, loudest, .now);
    sound.holdMusic(true);
    try std.testing.expectEqual(mss.Status.stopped, driver.streamStatus(sound.music.stream.?));
    try std.testing.expect(sound.musicPlaying());
    sound.music.queued = .of("music\\two.wav", once, 100);
    sound.updateMusic();
    try std.testing.expect(sound.music.queued != null);
    // A piece that starts while the window is inactive starts paused.
    sound.playMusic("music\\two.wav", once, loudest, .now);
    try std.testing.expectEqual(mss.Status.stopped, driver.streamStatus(sound.music.stream.?));
    try std.testing.expect(sound.musicPlaying());
    // When the window is active again, the music resumes.
    sound.holdMusic(false);
    try std.testing.expectEqual(mss.Status.playing, driver.streamStatus(sound.music.stream.?));
    // A pause by the game itself still counts as stopped, as in the original.
    sound.pauseMusic(true);
    try std.testing.expect(!sound.musicPlaying());
}

test "Sound.pieceOn and Sound.stopMusic" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/one.wav", .data = testing.sound_file });
    try tmp.dir.writeFile(io, .{ .sub_path = "music/two.wav", .data = testing.sound_file });
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    sound.files = .{ .gpa = gpa, .io = io, .dir = tmp.dir };
    defer sound.closeMusic();

    try std.testing.expectEqual(null, sound.pieceOn());
    sound.playMusic("music\\one.wav", forever, loudest, .now);
    try std.testing.expectEqualStrings("music\\one.wav", sound.pieceOn().?);
    try std.testing.expectEqualStrings("one.wav", pieceName(sound.pieceOn().?));
    // Stopping the music also drops the queued piece.
    sound.playMusic("music\\two.wav", forever, loudest, .{ .after_fade = 0 });
    sound.stopMusic();
    try std.testing.expectEqual(null, sound.pieceOn());
    sound.updateMusic();
    try std.testing.expectEqual(null, sound.pieceOn());
    // While the game pauses the music, no piece plays.
    sound.playMusic("music\\two.wav", forever, loudest, .now);
    sound.pauseMusic(true);
    try std.testing.expectEqual(null, sound.pieceOn());
}

test "Sound.runTimer runs the clock on and steps the fades" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/one.wav", .data = testing.sound_file });
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    sound.files = .{ .gpa = gpa, .io = io, .dir = tmp.dir };
    defer sound.closeMusic();

    var clock: Clock = .{};
    clock.start(1000);
    sound.playMusic("music\\one.wav", forever, loudest, .now);
    sound.fadeMusic(15, clock.game_ticks);
    // A tenth of a second on, the clock has run ten ticks and the fade has taken a step.
    sound.runTimer(&clock, 1010);
    try std.testing.expectEqual(10, clock.game_ticks);
    try std.testing.expectEqual(loudest - 15, sound.music.level);
    // Run on a frame at a time, the music fades out within half a second.
    var now: u64 = 1010;
    while (sound.music.stream != null and now < 1060) : (now += 2) sound.runTimer(&clock, now);
    try std.testing.expectEqual(null, sound.music.stream);
}

test "Sound.fadeMusic fades the music out from where it starts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "music");
    try tmp.dir.writeFile(io, .{ .sub_path = "music/one.wav", .data = testing.sound_file });
    var speaker: testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    sound.files = .{ .gpa = gpa, .io = io, .dir = tmp.dir };
    defer sound.closeMusic();

    sound.playMusic("music\\one.wav", forever, loudest, .now);
    // The fade counts from its own start, whatever the last fade left.
    sound.faded_at = 50_000;
    sound.fadeMusic(15, 100);
    sound.timerTick(105);
    try std.testing.expectEqual(loudest, sound.music.level);
    sound.timerTick(106);
    try std.testing.expectEqual(loudest - 15, sound.music.level);
    // Past nothing, the stream closes.
    var ticks: u32 = 106;
    while (sound.music.stream != null and ticks < 200) : (ticks += 6) sound.timerTick(ticks);
    try std.testing.expectEqual(null, sound.music.stream);
    try std.testing.expect(!sound.music.fading);
}

test tickTimer {
    var clock: Clock = .{ .play = .{ .ticks = main.ticks_per_second, .seconds = 59, .minutes = 59 } };
    // Past a second's ticks, the seconds roll over into the minutes, and they into the hours.
    tickTimer(&clock);
    try std.testing.expectEqual(main.PlayTime{ .hours = 1 }, clock.play);
    try std.testing.expectEqual(1, clock.game_ticks);
    // Paused, only the timer's own count goes on.
    clock.paused = true;
    tickTimer(&clock);
    try std.testing.expectEqual(2, clock.timer_ticks);
    try std.testing.expectEqual(1, clock.game_ticks);
}

test pitchFactor {
    try std.testing.expectEqual(@as(f32, 1), pitchFactor(0));
    try std.testing.expectApproxEqAbs(@as(f32, 2), pitchFactor(24), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 16), pitchFactor(200), 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 16.0), pitchFactor(-200), 1e-6);
}

test "Music.Path" {
    const short: Music.Path = .of("music\\one.wav");
    try std.testing.expectEqualStrings("music\\one.wav", short.slice());
    // A path longer than the buffer is cut short.
    const long: [paths.max_path + 10]u8 = @splat('a');
    const cut: Music.Path = .of(&long);
    try std.testing.expectEqualSlices(u8, long[0..paths.max_path], cut.slice());
}

test pieceName {
    try std.testing.expectEqualStrings("New_Pensive.wav", pieceName("music\\New_Pensive.wav"));
    try std.testing.expectEqualStrings("mine\\one.wav", pieceName("music\\mine\\one.wav"));
    try std.testing.expectEqualStrings("loose.wav", pieceName("loose.wav"));
}

test "lowest_pitch and highest_pitch match the limits of pitchFactor" {
    try std.testing.expectEqual(pitchFactor(-max_quarter_tones), lowest_pitch);
    try std.testing.expectEqual(pitchFactor(max_quarter_tones), highest_pitch);
}

test musicLoopStart {
    try std.testing.expectEqual(188318, musicLoopStart("music\\New_Mission01.wav"));
    try std.testing.expectEqual(297178, musicLoopStart("music\\New_Searching Mission 01.wav"));
    // Only the first folder is taken off, as the game takes it.
    try std.testing.expectEqual(0, musicLoopStart("music\\mine\\New_Mission01.wav"));
    try std.testing.expectEqual(0, musicLoopStart("music\\New_Takeoff - Music.wav"));
}
