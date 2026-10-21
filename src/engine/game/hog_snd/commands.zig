//! OpenReliant's: what the game frames ask of the sound, in the order they ask it, which the main
//! thread plays right after them (`Commands.play`). The game frames never reach the sound itself.
//! They place each 3D sound in their own objects as they ask for it (`sound3d.place`), and name
//! the voices they keep by what keeps them (`Kept`). Only the main thread chooses the voices and
//! plays them. A world where nothing is heard has no commands, and asks for nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const camera = @import("../camera.zig");
const cbox = @import("../cbox.zig");
const hog_snd = @import("../hog_snd.zig");
const Sound = hog_snd.Sound;
const sound3d = @import("../sound3d.zig");

const log = std.log.scoped(.sound);

/// The voices the game frames keep so that they can end them later, one for each thing that keeps
/// one. Ending one ends whatever plays on its voice by then, as ending a voice by its number does
/// in the game.
pub const Kept = enum {
    /// The missile lock's tone (`main.lock.Lock.sound`).
    lock_tone,
    /// The scanner's beeping (`main.scanner.Scanner`).
    scanner,
    /// Betty saying the armed missile's name (`hud.missile_display.Ring.sayName`).
    missile_name,
};

/// The banks the game frames' samples come from.
pub const Bank = enum {
    /// `bank_stdsmp`: the display's sounds and the frame's (`Sound.stdsmp`).
    stdsmp,
    /// `betty.fat`: Betty's lines (`Sound.betty`).
    betty,
};

/// A bank's sound (`Sound.play`).
pub const Sample = struct {
    bank: Bank,
    index: u16,
    volume: i32 = hog_snd.loudest,
    loops: u32 = hog_snd.once,
    pan: i32 = hog_snd.centre,
    pitch: i32 = hog_snd.own_pitch,
    /// With the reverb of the camera's surroundings (`Sound.playInScene`).
    in_scene: bool = false,
    /// What keeps its voice, to end it later.
    kept: ?Kept = null,
    /// Whether the display holds its voice, so that no other sound takes it (`hog_snd.Voice.held`).
    held: bool = false,
    /// Whether it waits for a voice where none is free, as the game asks for it again each frame
    /// until it plays: until a voice is free, or what keeps it ends it.
    waits: bool = false,
};

/// What the game frames ask of the sound.
pub const Command = union(enum) {
    /// A 3D sound, placed as the game frame found it (`sound3d.playIn`).
    effect: sound3d.Effect,
    /// The player's engine, unless it plays already (`sound3d.hearEngine`).
    engine: sound3d.Effect,
    /// The missile in a record ended, and the sound that follows it with it: the record, and how
    /// often it had been reused (`missiles.end`).
    missile_ended: struct { record: u16, reuse: u32 },
    /// Every 3D sound ended (`sound3d.endAll`).
    effects_ended,
    /// A bank's sound.
    sample: Sample,
    /// A kept voice ended (`Sound.endVoice`), whatever plays on it by then.
    ended: Kept,
    /// A positional sound gathered for the drawn frame (`Sound.bufferAt`).
    buffered: struct { index: u8, at: Vector, volume: f32 },
    /// A piece of music (`Sound.playMusic`).
    music: struct { piece: hog_snd.Music.Piece, when: Sound.When },
    /// A line of speech played on the speech sample (`cbox.Player.start`): the line's file, which
    /// the commands own, and how it sounds.
    speech: struct { bytes: []u8, style: cbox.Style },
    /// The line of speech playing ended (`cbox.Player.stop`).
    speech_ended,
};

/// What the game frames asked of the sound since the main thread last played it, and what the main
/// thread keeps to play it: the voices kept and the line of speech playing.
pub const Commands = struct {
    gpa: Allocator,
    list: std.ArrayList(Command) = .empty,
    /// The main thread's: the voice each kept sound plays on, and the one that waits for a voice.
    kept: std.EnumArray(Kept, Hold) = .initFill(.{}),
    /// The main thread's: the line of speech playing.
    line: cbox.Player = .{},

    /// What a kept sound holds: its voice, or the sound that waits for one (`Sample.waits`).
    pub const Hold = struct {
        voice: ?u8 = null,
        waiting: ?Sample = null,
    };

    /// Lets go of what the game frames asked for, and ends the line of speech playing.
    pub fn deinit(commands: *Commands, sound: *Sound) void {
        for (commands.list.items) |command| commands.letGo(command);
        commands.list.deinit(commands.gpa);
        commands.line.stop(commands.gpa, sound);
    }

    /// Asks for `command` after the others. Where there's no room for it, it's left out, with a
    /// warning.
    pub fn add(commands: *Commands, command: Command) void {
        commands.list.append(commands.gpa, command) catch {
            log.warn("the sound misses a command of the game's ({s}): out of memory", .{@tagName(command)});
            commands.letGo(command);
        };
    }

    /// Asks for a line of speech, the speech file `bytes`, which the commands copy.
    pub fn speak(commands: *Commands, bytes: []const u8, style: cbox.Style) void {
        const copy = commands.gpa.dupe(u8, bytes) catch {
            log.warn("the sound misses a line of speech: out of memory", .{});
            return;
        };
        commands.add(.{ .speech = .{ .bytes = copy, .style = style } });
    }

    /// Lets go of what `command` owns.
    fn letGo(commands: *Commands, command: Command) void {
        switch (command) {
            .speech => |speech| commands.gpa.free(speech.bytes),
            else => {},
        }
    }

    /// Plays what the game frames asked for through `sound`, in the order they asked, heard from
    /// `listener`, where the camera stands; then none is left. Last, each kept sound that still
    /// waits for a voice tries again.
    pub fn play(commands: *Commands, sound: *Sound, listener: camera.Place) void {
        defer for (std.enums.values(Kept)) |kept| {
            const waiting = commands.kept.get(kept).waiting orelse continue;
            commands.playSample(sound, waiting);
        };
        defer commands.list.clearRetainingCapacity();
        for (commands.list.items) |command| {
            defer commands.letGo(command);
            switch (command) {
                .effect => |effect| _ = sound3d.startEffect(sound, listener, effect),
                .engine => |effect| sound3d.startEngineEffect(sound, listener, effect),
                .missile_ended => |ended| if (sound.missileVoice(ended.record, ended.reuse)) |voice| sound.end3D(voice),
                .effects_ended => sound3d.endAll(sound),
                .sample => |sample| commands.playSample(sound, sample),
                .ended => |kept| {
                    const held = commands.kept.getPtr(kept);
                    if (held.voice) |voice| sound.endVoice(voice);
                    held.* = .{};
                },
                .buffered => |buffered| sound.bufferAt(buffered.index, buffered.at, listener, buffered.volume),
                .music => |music| sound.playMusic(music.piece.pathOf(), music.piece.loops, music.piece.level, music.when),
                .speech => |speech| {
                    const line = cbox.Line.parse(speech.bytes) orelse continue;
                    _ = commands.line.start(commands.gpa, sound, line, hog_snd.loudest, speech.style, null);
                },
                .speech_ended => commands.line.stop(commands.gpa, sound),
            }
        }
    }

    /// Plays `sample` as `Sound.play` plays it, with the reverb of the camera's surroundings where
    /// it asks for it, and keeps its voice, holds it or waits for one as it says.
    fn playSample(commands: *Commands, sound: *Sound, sample: Sample) void {
        const bank = switch (sample.bank) {
            .stdsmp => sound.stdsmp,
            .betty => sound.betty,
        };
        const played = if (bank) |from| if (sample.in_scene)
            sound.playInScene(from, sample.index, sample.volume, sample.loops, sample.pan, sample.pitch)
        else
            sound.play(from, sample.index, sample.volume, sample.loops, sample.pan, sample.pitch) else null;
        if (played) |voice| if (sample.held) {
            sound.voices[voice].held = 1;
        };
        const kept = sample.kept orelse return;
        commands.kept.set(kept, .{ .voice = played, .waiting = if (played == null and sample.waits) sample else null });
    }
};

test Commands {
    var speaker: hog_snd.testing.Speaker = undefined;
    const bytes = comptime hog_snd.testing.bank(4);
    try speaker.init(2, &bytes);
    defer speaker.deinit();
    const commands = &speaker.asked;
    const sound = &speaker.sound;

    // Nothing plays until the main thread plays what was asked for, and then it's gone.
    commands.add(.{ .sample = .{ .bank = .stdsmp, .index = 1 } });
    try std.testing.expect(!speaker.playing());
    commands.play(sound, speaker.listener);
    try std.testing.expect(speaker.playing());
    try std.testing.expectEqual(0, commands.list.items.len);

    // A kept sound's voice is ended by what keeps it, whatever plays on it by then.
    commands.add(.{ .sample = .{ .bank = .stdsmp, .index = 2, .loops = hog_snd.forever, .kept = .scanner } });
    commands.play(sound, speaker.listener);
    const voice = commands.kept.get(.scanner).voice orelse return error.TestUnexpectedResult;
    try std.testing.expect(sound.voicePlaying(voice));
    commands.add(.{ .ended = .scanner });
    commands.play(sound, speaker.listener);
    try std.testing.expect(!sound.voicePlaying(voice));
    try std.testing.expectEqual(null, commands.kept.get(.scanner).voice);

    // One that waits for a voice plays once one is free, unless what keeps it ends it first.
    for (0..2) |v| sound.playOn(@intCast(v), sound.stdsmp.?, 0, hog_snd.loudest, hog_snd.forever, hog_snd.centre, hog_snd.own_pitch);
    for (0..2) |v| sound.voices[v].held = 1;
    commands.add(.{ .sample = .{ .bank = .stdsmp, .index = 3, .kept = .lock_tone, .held = true, .waits = true } });
    commands.play(sound, speaker.listener);
    try std.testing.expect(commands.kept.get(.lock_tone).waiting != null);
    sound.endVoice(1);
    commands.play(sound, speaker.listener);
    try std.testing.expectEqual(1, commands.kept.get(.lock_tone).voice.?);
    try std.testing.expectEqual(1, sound.voices[1].held);
    try std.testing.expectEqual(null, commands.kept.get(.lock_tone).waiting);
    commands.add(.{ .ended = .lock_tone });
    commands.play(sound, speaker.listener);
    try std.testing.expect(!sound.voicePlaying(1));

    // What isn't played when the commands go is let go of.
    commands.speak("not a line", .{});
}
