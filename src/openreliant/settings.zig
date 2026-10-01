//! OpenReliant's own options in the game's settings file, `starlancer.ini` in the game's folder:
//! its `[OpenReliant]` section, which the original never reads, a key for each (`read`). The
//! command line's options change them for the run. The settings screen shows them, and changes
//! them as the game plays (`Own`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const Profile = engine.profile.Profile;
const screen = engine.game.interface.settings;
const options_page = @import("options.zig");
const Options = options_page.Options;

const log = std.log.scoped(.settings);

/// OpenReliant's section of the file.
const section = "OpenReliant";

/// Reads OpenReliant's options from the settings file's `[OpenReliant]` into `options`: `Original`
/// first, as `--original` does, then the others, each changing what it set, as an option after
/// `--original` does. A value a key does not take is left out, and logged.
pub fn read(settings_file: Profile, options: *Options) void {
    for (keys) |key| {
        const value = settings_file.value(section, key.name) orelse continue;
        key.read(options, value) catch log.warn("[{s}] {s}={s} is left out: it takes {s}", .{ section, key.name, value, key.takes });
    }
}

/// One of OpenReliant's options in `[OpenReliant]`: its key, which follows the way the game names
/// its own, what it takes, and how its value is read into the options. An option that turns on and
/// off takes 1 and 0, as the game's own do.
const Key = struct {
    name: []const u8,
    takes: []const u8,
    read: Reader,
};

const Reader = *const fn (options: *Options, value: []const u8) error{BadValue}!void;

const on_off = "1 or 0";

/// The keys, in the order they are read: `Original` first.
const keys = [_]Key{
    .{ .name = "Original", .takes = on_off, .read = original },
    .{ .name = "Fullscreen", .takes = on_off, .read = onOff("fullscreen") },
    .{ .name = "Size", .takes = "<width>x<height>", .read = byOption(.@"--size") },
    .{ .name = "FrameRate", .takes = "<rate>", .read = byOption(.@"--fps") },
    .{ .name = "Vsync", .takes = on_off, .read = onOff("settings.vsync") },
    .{ .name = "Software", .takes = on_off, .read = onOff("software") },
    .{ .name = "SixteenBit", .takes = on_off, .read = onOff("settings.sixteen_bit") },
    .{ .name = "Samples", .takes = "1, 2, 4 or 8", .read = byOption(.@"--msaa") },
    .{ .name = "Filter", .takes = "original, trilinear or crisp", .read = byOption(.@"--filter") },
    .{ .name = "Bloom", .takes = on_off, .read = onOff("settings.bloom") },
    .{ .name = "Dither", .takes = on_off, .read = onOff("settings.dither") },
    .{ .name = "PixelLighting", .takes = on_off, .read = onOff("settings.pixel_lighting") },
    .{ .name = "LinearLight", .takes = on_off, .read = onOff("settings.linear_light") },
    .{ .name = "Shadows", .takes = "off, low or high", .read = byOption(.@"--shadows") },
    .{ .name = "CockpitShadows", .takes = on_off, .read = onOff("settings.cockpit_shadows") },
    .{ .name = "SmoothMotion", .takes = on_off, .read = onOff("smooth_motion") },
    .{ .name = "ShotLights", .takes = on_off, .read = shotLights },
    .{ .name = hrtf_key, .takes = "auto, on or off", .read = hrtf },
    .{ .name = reverb_key, .takes = on_off, .read = reverb },
    .{ .name = compressor_key, .takes = on_off, .read = compressor },
};

/// The keys of the sound's options, which the settings screen writes (`Own`).
const hrtf_key = "Hrtf";
const reverb_key = "Reverb";
const compressor_key = "Compressor";

/// A whole number, nonzero for on.
fn onOrOff(value: []const u8) error{BadValue}!bool {
    return (std.fmt.parseInt(i32, value, 10) catch return error.BadValue) != 0;
}

/// The field of `T` that `path` names, through the fields that hold it, such as `settings.bloom`.
fn FieldAt(comptime T: type, comptime path: []const u8) type {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return @FieldType(T, path);
    return FieldAt(@FieldType(T, path[0..dot]), path[dot + 1 ..]);
}

fn fieldAt(comptime path: []const u8, of: anytype) *FieldAt(@typeInfo(@TypeOf(of)).pointer.child, path) {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (dot) |at| return fieldAt(path[at + 1 ..], &@field(of, path[0..at]));
    return &@field(of, path);
}

/// A key that turns the option at `path` on and off.
fn onOff(comptime path: []const u8) Reader {
    return &struct {
        fn read(options: *Options, value: []const u8) error{BadValue}!void {
            fieldAt(path, options).* = try onOrOff(value);
        }
    }.read;
}

/// A key that takes what the command line's `option` takes.
fn byOption(comptime option: options_page.Arg) Reader {
    return &struct {
        fn read(options: *Options, value: []const u8) error{BadValue}!void {
            try options.apply(option, value);
        }
    }.read;
}

/// `Original`: with 1, the original's look and sound, as `--original` gives them.
fn original(options: *Options, value: []const u8) error{BadValue}!void {
    if (try onOrOff(value)) try options.apply(.@"--original", "");
}

/// `ShotLights`: with 1, every shot casts a light; with 0, the latest two of each side do, as in
/// the original (`--few-shot-lights`).
fn shotLights(options: *Options, value: []const u8) error{BadValue}!void {
    options.shot_lights = if (try onOrOff(value)) .every_shot else .latest_two;
}

/// `Hrtf`: whether the sounds are placed for headphones, by the output or always or never, with
/// OpenAL Soft playing them (`--hrtf`, `--no-hrtf`).
fn hrtf(options: *Options, value: []const u8) error{BadValue}!void {
    const chosen = std.meta.stringToEnum(platform.audio.openal.Hrtf, value) orelse return error.BadValue;
    if (options.openAl()) |openal| openal.hrtf = chosen;
}

/// `Reverb`: whether the sounds play with reverb, with OpenAL Soft playing them (`--no-reverb`).
fn reverb(options: *Options, value: []const u8) error{BadValue}!void {
    const on = try onOrOff(value);
    if (options.openAl()) |openal| openal.reverb = on;
}

/// `Compressor`: with 1, the master bus's compressor and limiter as they come; with 0, the limiter
/// alone (`--no-compressor`).
fn compressor(options: *Options, value: []const u8) error{BadValue}!void {
    const compressing = try onOrOff(value);
    if (options.sound) |*sound| sound.master = master(compressing);
}

/// OpenReliant's own options as the settings screen shows them (`interface.settings.Own`): the
/// sound's, as the output plays them. A change is written to `[OpenReliant]`, as `read` reads it,
/// and applied to the output at once.
pub const Own = struct {
    settings_file: *engine.profile.File,
    output: ?*platform.audio.Output,
    /// The sound's options as the output plays them; none without sound.
    sound: ?platform.audio.Options,

    pub fn interface(own: *Own) screen.Own {
        return .{ .context = own, .vtable = &.{ .audio = audio, .setAudio = setAudio } };
    }

    fn audio(context: *anyopaque) screen.Own.Audio {
        const own: *const Own = @ptrCast(@alignCast(context));
        return own.shown();
    }

    fn shown(own: Own) screen.Own.Audio {
        const sound = own.sound orelse return .{ .hrtf = .off, .reverb = false, .compressor = false, .openal = false };
        const compressing = if (sound.master) |bus| bus.compresses() else false;
        return switch (sound.player) {
            .openal => |openal| .{ .hrtf = shownHrtf(openal.hrtf), .reverb = openal.reverb, .compressor = compressing },
            .software => .{ .hrtf = .off, .reverb = false, .compressor = compressing, .openal = false },
        };
    }

    /// Writes what has changed, and applies it to the output. The HRTF and the reverb are OpenAL
    /// Soft's, and change only while it plays: written with the software Miles playing, they would
    /// have the next start play OpenAL Soft, as `--hrtf` after `--original` does.
    fn setAudio(context: *anyopaque, chosen: screen.Own.Audio) void {
        const own: *Own = @ptrCast(@alignCast(context));
        own.change(chosen) catch |err| log.warn("the sound's options are not kept: {s}", .{@errorName(err)});
    }

    fn change(own: *Own, chosen: screen.Own.Audio) Allocator.Error!void {
        const sound = &(own.sound orelse return);
        const file = own.settings_file;
        switch (sound.player) {
            .openal => |*openal| {
                const chosen_hrtf = playedHrtf(chosen.hrtf);
                if (chosen_hrtf != openal.hrtf) {
                    try file.write(section, hrtf_key, @tagName(chosen_hrtf));
                    openal.hrtf = chosen_hrtf;
                    if (own.output) |output| output.setHrtf(chosen_hrtf);
                }
                if (chosen.reverb != openal.reverb) {
                    try file.writeInt(section, reverb_key, @intFromBool(chosen.reverb));
                    openal.reverb = chosen.reverb;
                    if (own.output) |output| output.setReverb(chosen.reverb);
                }
            },
            .software => {},
        }
        if (chosen.compressor != own.shown().compressor) {
            try file.writeInt(section, compressor_key, @intFromBool(chosen.compressor));
            sound.master = master(chosen.compressor);
            if (own.output) |output| output.setMaster(sound.master);
        }
    }
};

fn shownHrtf(played: platform.audio.openal.Hrtf) screen.Own.Hrtf {
    return switch (played) {
        .auto => .auto,
        .on => .on,
        .off => .off,
    };
}

fn playedHrtf(chosen: screen.Own.Hrtf) platform.audio.openal.Hrtf {
    return switch (chosen) {
        .auto => .auto,
        .on => .on,
        .off => .off,
    };
}

/// The master bus with the compressor, as it comes, or without it: its limiter alone, as
/// `--no-compressor` leaves it.
fn master(compressing: bool) engine.mss.master.Settings {
    const bus: engine.mss.master.Settings = .{};
    return if (compressing) bus else bus.withoutCompressor();
}

/// The options a settings file holding `text` plays with, before the command line's.
fn optionsOf(text: []const u8) Options {
    var options: Options = .{};
    read(.{ .text = text }, &options);
    return options;
}

test read {
    // Without the section, every option as it comes.
    const plain = optionsOf("[Sound]\nFxvolume=80\n");
    try std.testing.expectEqual(platform.gpu.Settings{}, plain.settings);
    // The original's look and sound, with the bloom, eight samples and HRTF again; a value a key
    // does not take is left out.
    const chosen = optionsOf(
        \\[OpenReliant]
        \\Bloom=1
        \\Original=1
        \\Samples=8
        \\Shadows=low
        \\Hrtf=on
        \\Filter=sharp
        \\FrameRate=0
        \\Size=800x600
        \\ShotLights=1
        \\Compressor=0
        \\Vsync=0
    );
    try std.testing.expect(chosen.settings.bloom and chosen.settings.sixteen_bit);
    try std.testing.expectEqual(8, chosen.settings.samples);
    try std.testing.expectEqual(.low, chosen.settings.shadows);
    try std.testing.expectEqual(.original, chosen.settings.filter);
    try std.testing.expectEqual(0, chosen.fps.?);
    try std.testing.expectEqual([2]u32{ 800, 600 }, chosen.settings.size.?);
    try std.testing.expectEqual(.every_shot, chosen.shot_lights);
    try std.testing.expect(!chosen.smooth_motion and !chosen.settings.vsync);
    const sound = chosen.sound.?;
    try std.testing.expectEqual(.on, sound.player.openal.hrtf);
    try std.testing.expectEqual(1, sound.master.?.ratio);
    // A value of the wrong kind is left out too, and the names are read as the game reads its own,
    // without regard to case.
    try std.testing.expect(optionsOf("[OpenReliant]\nBloom=yes\n").settings.bloom);
    try std.testing.expect(!optionsOf("[openreliant]\nbloom=0\n").settings.bloom);
}

test "the command line changes the settings file's options" {
    const base = optionsOf("[OpenReliant]\nVsync=0\nFrameRate=0\nShadows=low\n");
    const faster = switch (Options.parse(&.{ "--fps", "30" }, base)) {
        .play => |options| options,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(30, faster.fps.?);
    try std.testing.expect(!faster.settings.vsync);
    try std.testing.expectEqual(.low, faster.settings.shadows);
    // `--original` takes the original's look and sound whatever the file says.
    const retro = switch (Options.parse(&.{"--original"}, base)) {
        .play => |options| options,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(.off, retro.settings.shadows);
}

test Own {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: engine.profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var own: Own = .{ .settings_file = &file, .output = null, .sound = .{} };
    const shown = own.interface();
    try std.testing.expectEqual(screen.Own.Audio{}, shown.audio());
    // What changes is written, and kept; what doesn't, isn't.
    shown.setAudio(.{ .hrtf = .on, .reverb = true, .compressor = false });
    try std.testing.expectEqualStrings("on", file.profile.value(section, hrtf_key).?);
    try std.testing.expectEqualStrings("0", file.profile.value(section, compressor_key).?);
    try std.testing.expectEqual(null, file.profile.value(section, reverb_key));
    try std.testing.expectEqual(screen.Own.Audio{ .hrtf = .on, .compressor = false }, shown.audio());
    // Read back, they play the same.
    const read_back = optionsOf(file.profile.text);
    try std.testing.expectEqual(platform.audio.openal.Hrtf.on, read_back.sound.?.player.openal.hrtf);
    try std.testing.expect(!read_back.sound.?.master.?.compresses());
    // With the software Miles, the HRTF is not written, which would have OpenAL Soft play.
    own.sound = .{ .player = .software, .master = null };
    shown.setAudio(.{ .hrtf = .auto, .reverb = false, .compressor = true, .openal = false });
    try std.testing.expectEqualStrings("on", file.profile.value(section, hrtf_key).?);
    try std.testing.expectEqualStrings("1", file.profile.value(section, compressor_key).?);
}

test keys {
    // Each key once, the first `Original`.
    for (keys, 0..) |key, index| {
        for (keys[0..index]) |before| try std.testing.expect(!std.ascii.eqlIgnoreCase(before.name, key.name));
    }
    try std.testing.expectEqualStrings("Original", keys[0].name);
}
