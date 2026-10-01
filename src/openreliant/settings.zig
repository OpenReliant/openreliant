//! OpenReliant's own options in the game's settings file, `starlancer.ini` in the game's folder:
//! its `[OpenReliant]` section, which the original never reads, a key for each (`read`). The
//! command line's options change them for the run.

const std = @import("std");

const openreliant = @import("openreliant");
const platform = @import("platform");
const Profile = openreliant.engine.profile.Profile;
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
    .{ .name = "Hrtf", .takes = "auto, on or off", .read = hrtf },
    .{ .name = "Reverb", .takes = on_off, .read = reverb },
    .{ .name = "Compressor", .takes = on_off, .read = compressor },
};

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
    if (try onOrOff(value)) {
        if (options.sound) |*sound| sound.master = (platform.audio.Options{}).master;
    } else {
        try options.apply(.@"--no-compressor", "");
    }
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

test keys {
    // Each key once, the first `Original`.
    for (keys, 0..) |key, index| {
        for (keys[0..index]) |before| try std.testing.expect(!std.ascii.eqlIgnoreCase(before.name, key.name));
    }
    try std.testing.expectEqualStrings("Original", keys[0].name);
}
