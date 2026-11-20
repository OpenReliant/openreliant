//! Reliable music commands sent by the host's mission script.
const std = @import("std");
const game = @import("openreliant").engine.game;
const executor = game.executor;
const Command = game.hog_snd.commands.Music;
const Cue = @This();

const Track = game.language.Text(executor.music_path_size - executor.music_folder.len);
const Playback = packed struct(u8) {
    now: bool,
    level: u7,
};

track: Track,
loops: u32,
level: u7,
now: bool,

pub fn capture(command: Command) ?Cue {
    const path = command.piece.pathOf();
    if (!std.mem.startsWith(u8, path, executor.music_folder)) return null;
    const name = path[executor.music_folder.len..];
    if (!isTrack(name)) return null;
    var track: Track = .{};
    track.set(name);
    return .{ .track = track, .loops = command.piece.loops, .level = std.math.cast(u7, command.piece.level) orelse return null, .now = command.when == .now };
}

pub fn commands(cue: Cue, clock: u32) Command {
    var buffer: [executor.music_path_size]u8 = undefined;
    const path = executor.musicPath(&buffer, cue.track.slice()).?;
    return .{
        .piece = .of(path, cue.loops, cue.level),
        .when = if (cue.now) .now else .{ .after_fade = clock },
    };
}

/// A remote host can name a file in the game's music directory.
fn isTrack(name: []const u8) bool {
    if (name.len == 0 or name.len > @as(Track, .{}).bytes.len or name[0] == '.' or name[name.len - 1] == '.') return false;
    for (name) |byte| switch (byte) {
        0...31, 127, '/', '\\', ':', '*', '?', '"', '<', '>', '|' => return false,
        else => {},
    };
    return true;
}

pub fn write(cue: Cue, writer: *std.Io.Writer) !void {
    try writer.writeInt(u32, cue.loops, .little);
    const playback: Playback = .{ .now = cue.now, .level = cue.level };
    try writer.writeByte(@bitCast(playback));
    try writer.writeByte(@intCast(cue.track.len));
    try writer.writeAll(cue.track.slice());
}

pub fn read(reader: *std.Io.Reader) !Cue {
    const loops = try reader.takeInt(u32, .little);
    const playback: Playback = @bitCast(try reader.takeByte());
    const name = try reader.take(try reader.takeByte());
    if (!isTrack(name)) return error.InvalidMusicTrack;
    var track: Track = .{};
    track.set(name);
    return .{ .track = track, .loops = loops, .level = playback.level, .now = playback.now };
}

/// Keep a short sequence of requests until the next send or presentation pass.
pub const Queue = struct {
    const capacity = 8;
    entries: [capacity]Cue = undefined,
    count: usize = 0,

    pub fn add(queue: *Queue, cue: Cue) void {
        if (queue.count == capacity) {
            std.mem.copyForwards(Cue, queue.entries[0 .. capacity - 1], queue.entries[1..]);
            queue.count -= 1;
        }
        queue.entries[queue.count] = cue;
        queue.count += 1;
    }

    pub fn take(queue: *Queue) []const Cue {
        defer queue.count = 0;
        return queue.entries[0..queue.count];
    }
};

test "mission music names a local track and anchors a fade to the viewer's clock" {
    const cue = Cue.capture(.{ .piece = .of("music\\new_searching mission 09.wav", 0, 80), .when = .{ .after_fade = 1230 } }).?;
    var bytes: [executor.music_path_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try cue.write(&writer);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    const decoded = try Cue.read(&reader);
    const playback = decoded.commands(25);
    try std.testing.expectEqualStrings("music\\new_searching mission 09.wav", playback.piece.pathOf());
    try std.testing.expectEqual(80, playback.piece.level);
    try std.testing.expectEqual(0, playback.piece.loops);
    try std.testing.expectEqual(25, playback.when.after_fade);
    try std.testing.expect(!isTrack("../new_launch.wav"));
    try std.testing.expect(!isTrack("x:track.wav"));
    try std.testing.expect(!isTrack("dir\\theme.wav"));
    try std.testing.expect(!isTrack("theme.wav\x00"));
}
