//! The `openreliant.audio` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! for player and menu scripts: interface sounds, music and Betty's lines (`package`).

const std = @import("std");

const openreliant = @import("openreliant");
const hog_snd = openreliant.engine.game.hog_snd;
const betty = hog_snd.betty;
const executor = openreliant.engine.game.executor;
const api = @import("api.zig");
const Call = api.Call;
const Presentation = @import("presentation.zig").Presentation;

/// What `openreliant.audio` holds.
pub const package = struct {
    pub const play_sound = api.Function("Plays sound `index` of the game's standard sounds, the menus' and the display's, at `volume` from 0 to 1, or at its loudest where it's nil. Returns whether it played.", &.{ "index", "volume" }, playSound);
    pub const play_music = api.Function("Plays the piece `name` from the game's music folder for ever, in place of the music playing.", &.{"name"}, playMusic);
    pub const say = api.Function("Betty says `line`. Returns whether she does.", &.{"line"}, bettySays);
};

/// `audio.play_sound(index, volume)`.
fn playSound(call: Call, index: u16, volume: ?f32) bool {
    const sound = Presentation.hostOf(call, "audio.play_sound").sound orelse return false;
    const level: i32 = @intFromFloat(@round(std.math.clamp(volume orelse 1, 0, 1) * hog_snd.loudest));
    return sound.playStandard(index, level, hog_snd.once, hog_snd.centre, hog_snd.own_pitch) != null;
}

/// `audio.play_music(name)`.
fn playMusic(call: Call, name: []const u8) void {
    const sound = Presentation.hostOf(call, "audio.play_music").sound orelse return;
    executor.playPiece(sound, name, .now);
}

/// `audio.say(line)`.
fn bettySays(call: Call, line: betty.Line) bool {
    const sound = Presentation.hostOf(call, "audio.say").sound orelse return false;
    return betty.say(sound, line) != null;
}
