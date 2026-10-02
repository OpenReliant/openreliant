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
const paths = @import("../files.zig");
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

/// What `sound_play` takes: a volume from nothing to `loudest`; a pan from the left, 0, to
/// `rightmost`, `centre` between; a count of plays, `forever` for one that goes on until it is
/// ended; and `own_pitch`, a sound's own pitch, which the quarter tones up or down are counted
/// from.
pub const loudest = 127;
pub const rightmost = 127;
pub const centre = 64;
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

/// The bytes of 16-bit sound at the 3D sounds' rate that a tick plays, as `sound_3d_update` counts
/// a sound's length in ticks. **Improvement:** OpenReliant divides by them, where the game
/// multiplies by their rounded reciprocal (`0x004DC8B8`).
const bytes_per_tick = sound3d.sample_rate * @sizeOf(i16) / main.ticks_per_second;

comptime {
    assert(bytes_per_tick == 441);
}

/// The count past which `tick_timer` rolls the mission's seconds and minutes over, a tick after
/// they reach it, so each counts 0 to 59 (an immediate in `tick_timer`).
const rollover_after = 58;

/// What turns the game's units into Miles's for a 3D sound's place and speed: its distances
/// (`0x004DC9B4`) and the step's movement into a millisecond's.
pub const distance_scale: f32 = 0.0004;
pub const velocity_scale: f32 = 1e-5;

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

    /// Whether the voice is free: its `owner` is `no_owner`.
    pub fn isFree(voice: Voice3D) bool {
        return voice.owner == no_owner;
    }

    /// The record or the slot of what it follows, where `owner` names one.
    pub fn ownerIndex(voice: Voice3D) ?u32 {
        return std.math.cast(u32, voice.owner);
    }

    const free: Voice3D = .{
        .sample = @enumFromInt(0),
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
    master: i32 = 127,
    /// `Fxvolume` (`0x005D5A74`): the banks' sounds and the 3D sounds.
    effects: i32 = 80,
    /// `Musicvolume` (`0x005D55EC`).
    music: i32 = 80,
    /// `Speechvolume` (`0x005D5E88`).
    speech: i32 = 127,

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
        inline for (comptime std.meta.fieldNames(Volumes)) |name| {
            const kept = settings.int(section, keys.get(@field(std.meta.FieldEnum(Volumes), name)), @intCast(@field(volumes, name)));
            @field(volumes, name) = @intCast(@min(kept, loudest));
        }
        return volumes;
    }
};

/// A bank's file read whole, as `hog_load` and `hog_read_file` read one, whose sounds play from its
/// bytes, and the bank it holds.
pub const BankFile = struct {
    bytes: []u8,
    bank: fat.Bank,

    /// `bytes`, the file of the bank `name`, which it keeps; null where it is not a bank, which the
    /// log says, the bytes then freed.
    pub fn of(gpa: Allocator, bytes: []u8, name: []const u8) ?BankFile {
        const bank = fat.Bank.parse(bytes) catch |err| {
            log.warn("the bank {s} is left out: {s}", .{ name, @errorName(err) });
            gpa.free(bytes);
            return null;
        };
        return .{ .bytes = bytes, .bank = bank };
    }

    /// The bank `name` of `archive` (`hog_load`); null where it is left out, which the log says.
    pub fn read(gpa: Allocator, archive: *const bigfile.Hog, name: []const u8) ?BankFile {
        const bytes = archive.readFile(gpa, name) catch |err| {
            log.warn("the bank {s} is left out: {s}", .{ name, @errorName(err) });
            return null;
        };
        return of(gpa, bytes, name);
    }

    pub fn deinit(file: BankFile, gpa: Allocator) void {
        gpa.free(file.bytes);
    }
};

/// Where the music comes from: files of their own in the game's directory, `music\` and the name,
/// which Miles streamed from the disk (`AIL_open_stream`), and OpenReliant's mods before them.
pub const Files = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    mods: *const bigfile.Mods = &bigfile.Mods.none,
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
    /// A piece to play once this one has faded (`0x0056533A` on): its path, loop count and level.
    queued: ?Queued = null,

    pub const Queued = struct {
        path: [128]u8 = @splat(0),
        path_len: usize = 0,
        loops: u32,
        level: i32,
    };
};

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
    /// The runtime's numbers, which pitch the explosions.
    random: *@import("../libcmt.zig").Rand,
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

    /// `sound_play` (`0x00481F80`): plays sound `index` of `bank` on a voice, at `volume` from 0 to
    /// 127, `loops` times, `pan` from 0 to 127, `pitch` quarter tones up or down. It takes a voice
    /// that has finished, past the first; else one that was stopped; else the busy voice of lowest
    /// priority, unless it is held or the new sound's is no higher. Returns the voice, or null.
    pub fn play(sound: *Sound, bank: fat.Bank, index: usize, volume: i32, loops: u32, pan: i32, pitch: i32) ?u8 {
        const driver = sound.driver orelse return null;
        const entry_priority: i32 = if (index < bank.entries.len) @intCast(bank.entries[index].priority) else return null;
        const count = sound.voice_count;
        const chosen = chosen: {
            for (1..count) |v| if (driver.sampleStatus(sound.voices[v].sample) == .done) break :chosen v;
            for (0..count) |v| if (driver.sampleStatus(sound.voices[v].sample) == .stopped) break :chosen v;
            var lowest: i32 = priority_ceiling;
            var found: ?usize = null;
            for (sound.voices[0..count], 0..) |voice, v| {
                if (voice.priority < lowest and voice.held == 0) {
                    lowest = voice.priority;
                    found = v;
                }
            }
            const taken = found orelse return null;
            if (lowest >= entry_priority) return null;
            sound.endVoice(@intCast(taken));
            break :chosen taken;
        };
        sound.start(bank, index, volume, pitch, loops, pan, @intCast(chosen));
        return @intCast(chosen);
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

    /// A line of speech, the WAVE file `file`, on voice `v`, which it holds so that no other sound
    /// takes it over: what the voice played ended, once, in the middle, as the rooms play their
    /// crew's lines (`0x0043B598` on). `file` outlives it. Not the game's: it rings in what
    /// surrounds the camera, as the rooms' other sounds do (`inScene`).
    ///
    /// **Fix:** it plays at the speech volume, scaled by the master volume. The game sets the
    /// sample to full volume itself, whatever the settings.
    pub fn speakOn(sound: *Sound, v: u8, file: []const u8) void {
        const driver = sound.driver orelse return;
        if (v >= sound.voice_count) return;
        if (driver.sampleStatus(sound.voices[v].sample) != .done) sound.endVoice(v);
        const voice = &sound.voices[v];
        voice.held = 1;
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

    /// `sound_start` (`0x004826A0`): hands Miles the WAVE file at the entry's offset in the bank,
    /// at its rate moved by `pitch`, and at `volume` scaled by the effects volume and the master
    /// volume.
    fn start(sound: *Sound, bank: fat.Bank, index: usize, volume: i32, pitch: i32, loops: u32, pan: i32, v: u8) void {
        const driver = sound.driver orelse return;
        const voice = &sound.voices[v];
        const file = bank.sound(index) orelse return;
        driver.initSample(voice.sample);
        if (!driver.setSampleFile(voice.sample, file)) {
            log.warn("sound {d} of a bank cannot be played", .{index});
            return;
        }
        // Not the game's: the cockpit's warnings play in the cockpit's cabin.
        driver.setSampleRoom(voice.sample, if (sound.fromCockpit(bank)) .cockpit else .none);
        const rate = if (wave.Wave.parse(file)) |info| info.rate else |_| 0;
        if (pitch != 0) {
            const moved = @as(f32, @floatFromInt(rate)) * pitchFactor(pitch);
            driver.setSamplePlaybackRate(voice.sample, @intCast(math.ftol(moved)));
        }
        driver.setSampleVolume(voice.sample, sound.volumes.mastered(sound.volumes.effects, volume, start_divisor));
        driver.setSampleLoopCount(voice.sample, loops);
        driver.setSamplePan(voice.sample, pan);
        voice.priority = @intCast(bank.entries[index].priority);
        voice.fading = 0;
        voice.rate = rate;
        voice.volume = volume;
        driver.startSample(voice.sample);
    }

    /// Not the game's: the sample on voice `v` rings in what surrounds the camera, as the 3D
    /// sounds do (`mss.Room.scene`): for a sound of the scene that the game plays as a sample.
    pub fn inScene(sound: *Sound, v: u8) void {
        const driver = sound.driver orelse return;
        if (v < sound.voice_count) driver.setSampleRoom(sound.voices[v].sample, .scene);
    }

    /// `play`, the sound then ringing in what surrounds the camera (`inScene`): the voice it plays
    /// on, or null.
    pub fn playInScene(sound: *Sound, bank: fat.Bank, index: usize, volume: i32, loops: u32, pan: i32, pitch: i32) ?u8 {
        const v = sound.play(bank, index, volume, loops, pan, pitch) orelse return null;
        sound.inScene(v);
        return v;
    }

    /// Not the game's: what surrounds the camera, whose reverb the 3D sounds and the samples of the
    /// scene ring in, told to the driver as it changes.
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

    /// `tick_timer`'s (`0x004827C0`) sound: every five ticks and more, the music's fade and each
    /// fading voice's step. OpenReliant runs it once a frame rather than on a timer of its own,
    /// which steps it the same while frames come faster than every five ticks.
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

    /// `sound_3d_open` (`0x00481900`) on OpenReliant's one provider: as many 3D voices as it has,
    /// up to 64, each free, then the effects set up on them (`sound3d.init`).
    pub fn open3D(sound: *Sound, smp3d: fat.Bank) void {
        const driver = sound.driver orelse return;
        sound.close3D();
        for (&sound.voices_3d) |*voice| {
            voice.* = Voice3D.free;
            voice.sample = driver.allocate3DSample() orelse break;
            sound.voice_3d_count += 1;
        }
        sound3d.init(sound, smp3d);
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

    /// `sound_3d_voice_end` (`0x00481AF0`): ends what a 3D voice plays and frees it, and the
    /// object or the missile it followed has none.
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

    /// `sound_3d_update` (`0x00481BF0`), once a frame: the player's engine first
    /// (`sound3d.engineUpdate`), then each 3D voice. One that has played its length, past the
    /// engine's and the afterburner's, is freed; the rest are placed again from the camera, by
    /// what they follow, and freed once out of range.
    pub fn update3D(sound: *Sound, scene: Scene) void {
        const driver = sound.driver orelse return;
        if (sound.voice_3d_count == 0) return;
        sound3d.engineUpdate(sound, scene);
        // Not the game's, which opens no listener: the listener moves with the player's ship, for
        // the Doppler shifts. The software mixer's stays still.
        const player = &scene.objects.slots[scene.objects.player].object;
        driver.set3DListenerVelocity(miles(math.transformTransposed(scene.camera.orientation, gameobj.vector(player.velocity)) * @as(Vector, @splat(velocity_scale))));
        const frame_start = scene.clock.frame_start;
        for (sound.voices_3d[0..sound.voice_3d_count], 0..) |*voice, index| {
            if (voice.isFree()) continue;
            const v: u8 = @intCast(index);
            const set_aside = sound.reserved(v);
            if (!set_aside) {
                const ticks = math.round(@as(f32, @floatFromInt(driver.sample3DLength(voice.sample))) / bytes_per_tick);
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
                    if (sound.missile_sound == .follows) if (scene.objects.missiles.get(voice.ownerIndex().?)) |missile| if (missile.slot.object.sound_voice.index() == v) {
                        position = missile.slot.drawn.position;
                        velocity = gameobj.vector(missile.slot.object.velocity);
                        direction = math.forward(missile.slot.drawn.orientation);
                        break :follow;
                    };
                    place = false;
                    face = false;
                    move = false;
                },
                .point_facing => {
                    position = gameobj.vector(voice.position);
                    direction = gameobj.vector(voice.direction);
                    move = false;
                },
                .point => {
                    place = false;
                    face = false;
                    move = false;
                },
                .object => {
                    const at = voice.ownerIndex().?;
                    const slot = &scene.objects.slots[at];
                    if (slot.object.type == .stand_in) {
                        sound.end3D(v);
                        continue;
                    }
                    position = if (at == scene.objects.player) slot.drawn.point(-sound3d.player_sound_offset) else slot.drawn.position;
                    velocity = gameobj.vector(slot.object.velocity);
                    direction = math.forward(slot.drawn.orientation);
                },
            }
            const relative = (position - scene.camera.position) * @as(Vector, @splat(distance_scale));
            const in_range = set_aside or !place or math.dot(relative, relative) <= voice.range * voice.range;
            if (!in_range) {
                sound.end3D(v);
                continue;
            }
            const heading = if (voice.follows == .point) Vector{ 0, 0, 1 } else math.normalize(math.transformTransposed(scene.camera.orientation, direction));
            if (place) driver.set3DPosition(voice.sample, miles(math.transformTransposed(scene.camera.orientation, relative)));
            if (face or voice.follows == .point) driver.set3DOrientation(voice.sample, miles(heading), .{ 0, 1, 0 });
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

    /// `music_play` (`0x00482A80`): plays the file at `path`, `loops` times (0 for ever) at
    /// `level`, when `when` has it. A piece the loop table names loops back to its own point
    /// rather than to the start.
    pub fn playMusic(sound: *Sound, path: []const u8, loops: u32, level: i32, when: When) void {
        const driver = sound.driver orelse return;
        switch (when) {
            .now => {},
            .after_fade => |game_ticks| {
                var queued: Music.Queued = .{ .loops = loops, .level = level };
                queued.path_len = @min(path.len, queued.path.len);
                @memcpy(queued.path[0..queued.path_len], path[0..queued.path_len]);
                sound.music.queued = queued;
                sound.fadeMusic(queued_fade_step, game_ticks);
                return;
            },
        }
        sound.closeMusic();
        sound.music.fading = false;
        sound.music.queued = null;
        const files = sound.files orelse return;
        sound.music.file = readMusic(files, path) catch |err| {
            log.warn("the music {s} is left out: {s}", .{ path, @errorName(err) });
            return;
        };
        const stream = driver.openStream(sound.music.file) orelse {
            log.warn("the music {s} cannot be played", .{path});
            files.gpa.free(sound.music.file);
            sound.music.file = &.{};
            return;
        };
        sound.music.stream = stream;
        driver.setStreamLoopCount(stream, loops);
        driver.setStreamPosition(stream, 0);
        const loop_start = musicLoopStart(path);
        driver.setStreamLoopBlock(stream, loop_start, -1);
        // The game sets the position to the loop's start, negated, which Miles takes as nothing.
        driver.setStreamPosition(stream, -loop_start);
        sound.music.level = level;
        sound.applyVolumes();
        driver.startStream(stream);
    }

    /// The frame's sounds, as `mission_frame` and `mission_paused_frame` play them: the music
    /// waiting its turn, the positional sounds gathered from `bank`, and the 3D sounds placed
    /// again, heard from `scene`'s camera.
    pub fn frame(sound: *Sound, bank: fat.Bank, scene: Scene) void {
        sound.updateMusic();
        sound.playBuffered(bank);
        sound.update3D(scene);
    }

    /// `music_update` (`0x00482C30`), once a frame: the queued piece starts once the music has
    /// stopped.
    pub fn updateMusic(sound: *Sound) void {
        const queued = sound.music.queued orelse return;
        if (sound.musicPlaying()) return;
        sound.music.queued = null;
        sound.playMusic(queued.path[0..queued.path_len], queued.loops, queued.level, .now);
    }

    /// `music_fade_out` (`0x00482960`): the music fades by `step` every five ticks from
    /// `game_ticks`, the timer's count now, until it stops.
    pub fn fadeMusic(sound: *Sound, step: i32, game_ticks: u32) void {
        if (sound.music.stream == null) return;
        sound.music.fading = true;
        sound.music.fade_step = step;
        sound.faded_at = game_ticks;
    }

    /// `music_playing` (`0x00482940`).
    pub fn musicPlaying(sound: *Sound) bool {
        const driver = sound.driver orelse return false;
        const stream = sound.music.stream orelse return false;
        return driver.streamStatus(stream) == .playing;
    }

    /// `music_pause` (`0x00482C70`) and `music_resume` (`0x00482C90`).
    pub fn pauseMusic(sound: *Sound, paused: bool) void {
        const driver = sound.driver orelse return;
        if (sound.music.stream) |stream| driver.pauseStream(stream, paused);
    }

    /// `music_close` (`0x00482CF0`).
    pub fn closeMusic(sound: *Sound) void {
        if (sound.music.stream) |stream| if (sound.driver) |driver| driver.closeStream(stream);
        sound.music.stream = null;
        if (sound.music.file.len > 0) if (sound.files) |files| files.gpa.free(sound.music.file);
        sound.music.file = &.{};
    }
};

/// `sound_pitch_factor` (`0x00481400`): what `n` quarter tones multiply a rate by, from a sixteenth
/// at 96 down to sixteen at 96 up. **Improvement:** the game looks it up in a table of rounded
/// powers of two; OpenReliant works it out.
pub fn pitchFactor(n: i32) f32 {
    const clamped = std.math.clamp(n, -max_quarter_tones, max_quarter_tones);
    return std.math.pow(f32, 2, @as(f32, @floatFromInt(clamped)) / quarter_tones_per_octave);
}

/// The byte a piece of music loops back to (`music_play`): the loop table's, for the piece whose
/// name starts what follows the path's first `\`, ignoring case, or 0.
pub fn musicLoopStart(path: []const u8) i32 {
    const name = if (std.mem.indexOfScalar(u8, path, '\\')) |at| path[at + 1 ..] else path;
    for (music_loops) |piece| {
        if (name.len >= piece.name.len and std.ascii.eqlIgnoreCase(name[0..piece.name.len], piece.name)) return piece.loop_start;
    }
    return 0;
}

/// Reads the music file at `path`, a path of the game's with backslashes, from the game's
/// directory, found whatever the case of its names, as Windows finds it (`files.find`). A mod's
/// file of its name comes first (`bigfile.Mods.readLoose`).
fn readMusic(files: Files, path: []const u8) ![]u8 {
    return try files.mods.readLoose(files.io, files.gpa, files.dir, path, .limited(paths.max_file_size)) orelse error.FileNotFound;
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

    pub const sound_file = wave.testing.pcm(&std.mem.toBytes([4]i16{ 16384, 16384, 16384, 16384 }));

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

test "Sound.speakOn holds its voice" {
    var speaker: testing.Speaker = undefined;
    try speaker.init(3, null);
    const sound = &speaker.sound;
    const bytes = comptime testing.bank(1);
    const bank = try fat.Bank.parse(&bytes);
    // What the voice played ends, and the line plays on it, held.
    sound.playOn(2, bank, 0, loudest, forever, centre, own_pitch);
    sound.speakOn(2, testing.sound_file);
    try std.testing.expect(sound.voicePlaying(2));
    try std.testing.expectEqual(1, sound.voices[2].held);
    // No other sound takes it over.
    for (0..3) |_| try std.testing.expect(sound.play(bank, 0, loudest, once, centre, own_pitch) != 2);
    // Ended, it is let go.
    sound.endVoice(2);
    try std.testing.expectEqual(0, sound.voices[2].held);
}

test BankFile {
    const gpa = std.testing.allocator;
    const bytes = comptime testing.bank(2);
    const file = BankFile.of(gpa, try gpa.dupe(u8, &bytes), "two.fat").?;
    defer file.deinit(gpa);
    try std.testing.expectEqual(2, file.bank.entries.len);
    // Not a bank, it is left out, and its bytes let go.
    try std.testing.expectEqual(null, BankFile.of(gpa, try gpa.dupe(u8, "x"), "x.fat"));
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
    try std.testing.expectEqualStrings("music\\two.wav", queued.path[0..queued.path_len]);
    sound.updateMusic();
    try std.testing.expectEqual(loudest, sound.music.level);
    // Once the music has stopped, the queued piece starts at its own level.
    sound.closeMusic();
    sound.updateMusic();
    try std.testing.expectEqual(null, sound.music.queued);
    try std.testing.expect(sound.musicPlaying() and !sound.music.fading);
    try std.testing.expectEqual(100, sound.music.level);
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

test musicLoopStart {
    try std.testing.expectEqual(188318, musicLoopStart("music\\New_Mission01.wav"));
    try std.testing.expectEqual(297178, musicLoopStart("music\\New_Searching Mission 01.wav"));
    // Only the first folder is taken off, as the game takes it.
    try std.testing.expectEqual(0, musicLoopStart("music\\mine\\New_Mission01.wav"));
    try std.testing.expectEqual(0, musicLoopStart("music\\New_Takeoff - Music.wav"));
}
