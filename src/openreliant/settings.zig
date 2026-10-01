//! The player's settings, which OpenReliant keeps in `starlancer.ini` in each user's folder
//! (`platform.folders.user`): the game's own sections, which the game's code reads as the game
//! does, and OpenReliant's options in `[OpenReliant]` (`Settings.read`), which the command line's
//! change for the run. The first run starts the file from the one in the game's folder, and the
//! file names the game's folder OpenReliant last played from, which it then plays from by default.
//!
//! **Improvement:** the game reads and writes `starlancer.ini` in its own folder, which every user
//! of the computer shares, and which a system may keep them from writing to.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const profile = engine.profile;
const install = @import("install.zig");
const options_page = @import("options.zig");
const Options = options_page.Options;

const log = std.log.scoped(.settings);

/// OpenReliant's section of the file, which the game never reads.
pub const section = "OpenReliant";

/// The key that names the game's folder OpenReliant last played from, by its whole path.
const game_folder_key = "GameDirectory";

/// The game's folder by default: the current directory.
pub const current_folder = ".";

pub const Settings = struct {
    io: Io,
    /// The folder the file is saved to: the user's, or the game's where there is none (`start`);
    /// null until then, where there is none.
    folder: ?Io.Dir,
    file: profile.File,
    /// Whether the user's folder held the file. Where it didn't, the file starts from the game's
    /// (`start`).
    found: bool,

    /// The file in the user's folder, read into `arena`, or an empty one where there is none.
    /// Without the folder, which is logged, the file is the game folder's (`start`).
    pub fn openUser(io: Io, arena: Allocator) Settings {
        const path = platform.folders.user(arena) catch |err| {
            log.warn("the settings are not kept: there is no folder for them: {s}", .{@errorName(err)});
            return .open(io, arena, null);
        };
        const folder = Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
            log.warn("the settings are not kept: {s} can't be opened: {s}", .{ path, @errorName(err) });
            return .open(io, arena, null);
        };
        return .open(io, arena, folder);
    }

    /// The file in the user's folder `folder`, read into `arena`, or an empty one where there is
    /// none.
    pub fn open(io: Io, arena: Allocator, folder: ?Io.Dir) Settings {
        const text: ?[]const u8 = if (folder) |dir|
            dir.readFileAlloc(io, profile.settings_name, arena, .limited(engine.files.max_file_size)) catch null
        else
            null;
        return .{
            .io = io,
            .folder = folder,
            .file = .{ .arena = arena, .profile = .{ .text = text orelse "" } },
            .found = text != null,
        };
    }

    /// The game's folder to play from: the one the command line names, `named`; else the current
    /// directory, where it holds the game; else the one OpenReliant last played from, where the
    /// file names one; else the current directory, which is then said to hold no game.
    pub fn gameFolder(settings: Settings, named: ?[]const u8, current_holds_game: bool) []const u8 {
        if (named) |folder| return folder;
        if (current_holds_game) return current_folder;
        return settings.lastGameFolder() orelse current_folder;
    }

    /// `gameFolder`, where the current directory is looked in for the game.
    pub fn findGameFolder(settings: Settings, named: ?[]const u8) []const u8 {
        return settings.gameFolder(named, holdsGame(settings.io, current_folder));
    }

    /// The game's folder OpenReliant last played from, as the file names it.
    pub fn lastGameFolder(settings: Settings) ?[]const u8 {
        const folder = settings.file.profile.value(section, game_folder_key) orelse return null;
        return if (folder.len == 0) null else folder;
    }

    /// Where the user's folder held no file: the file the game's folder `game` holds starts it,
    /// saved to the user's folder at once, so that it is taken from there once only. Without
    /// either, every setting keeps its default. Without a folder of the user's, the file is the
    /// game folder's, which it is saved to, as the original keeps it.
    pub fn start(settings: *Settings, game: Io.Dir) void {
        const own = settings.folder != null;
        if (!own) settings.folder = game.openDir(settings.io, current_folder, .{}) catch null;
        if (settings.found) return;
        settings.found = true;
        const arena = settings.file.arena;
        const text = game.readFileAlloc(settings.io, profile.settings_name, arena, .limited(engine.files.max_file_size)) catch return;
        settings.file.profile.text = text;
        if (!own) return;
        settings.file.changed = true;
        settings.save();
    }

    /// Notes the game's folder `game`, by its whole path, as the one OpenReliant last played from.
    pub fn remember(settings: *Settings, game: Io.Dir) void {
        const path = game.realPathFileAlloc(settings.io, current_folder, settings.file.arena) catch |err| {
            log.warn("the game's folder is not noted: {s}", .{@errorName(err)});
            return;
        };
        if (settings.lastGameFolder()) |last| if (std.mem.eql(u8, last, path)) return;
        settings.file.write(section, game_folder_key, path) catch |err| log.warn("the game's folder is not noted: {s}", .{@errorName(err)});
    }

    /// Closes the folder the file is saved to.
    pub fn close(settings: *Settings) void {
        if (settings.folder) |folder| folder.close(settings.io);
        settings.folder = null;
    }

    /// Saves the file to the user's folder, where it has changed since it was last saved.
    pub fn save(settings: *Settings) void {
        if (!settings.file.changed) return;
        settings.file.changed = false;
        const folder = settings.folder orelse return;
        folder.writeFile(settings.io, .{ .sub_path = profile.settings_name, .data = settings.file.profile.text }) catch |err|
            log.warn("the settings can't be saved to {s}: {s}", .{ profile.settings_name, @errorName(err) });
    }

    /// Reads OpenReliant's options from `[OpenReliant]` into `options`: `Original` first, as
    /// `--original` does, then the others, each changing what it set, as an option after
    /// `--original` does. A value a key does not take is left out, and logged.
    pub fn read(settings: Settings, options: *Options) void {
        for (keys) |key| {
            const value = settings.file.profile.value(section, key.name) orelse continue;
            key.read(options, value) catch log.warn("[{s}] {s}={s} is left out: it takes {s}", .{ section, key.name, value, key.takes });
        }
    }
};

/// Whether the folder `path` holds an installed copy of the game (`install.missingGameFile`).
fn holdsGame(io: Io, path: []const u8) bool {
    const directory = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer directory.close(io);
    return install.missingGameFile(io, directory) == null;
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
pub const keys = [_]Key{
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
        if (options.sound) |*sound| sound.master = .{};
    } else {
        try options.apply(.@"--no-compressor", "");
    }
}

/// The options a settings file holding `text` plays with, before the command line's.
fn optionsOf(text: []const u8) Options {
    const settings: Settings = .{
        .io = std.testing.io,
        .folder = null,
        .file = .{ .arena = std.testing.allocator, .profile = .{ .text = text } },
        .found = true,
    };
    var options: Options = .{};
    settings.read(&options);
    return options;
}

test "Settings.read" {
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
    // A value of the wrong kind is left out too.
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

test "Settings finds the game's folder, starts from its file, and notes it" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var user = std.testing.tmpDir(.{});
    defer user.cleanup();
    var game = std.testing.tmpDir(.{});
    defer game.cleanup();
    try game.dir.writeFile(io, .{ .sub_path = profile.settings_name, .data = "[Device]\r\nView=1\r\n" });

    // The first run: no file in the user's folder, which the game's then starts.
    var settings: Settings = .open(io, arena, user.dir);
    try std.testing.expect(!settings.found);
    try std.testing.expectEqualStrings("named", settings.gameFolder("named", true));
    try std.testing.expectEqualStrings(current_folder, settings.gameFolder(null, true));
    try std.testing.expectEqualStrings(current_folder, settings.gameFolder(null, false));
    settings.start(game.dir);
    try std.testing.expectEqual(1, settings.file.profile.int("Device", "View", 0));
    settings.remember(game.dir);
    settings.save();

    // The next run finds the file, and the game's folder it names.
    var again: Settings = .open(io, arena, user.dir);
    try std.testing.expect(again.found);
    try std.testing.expectEqual(1, again.file.profile.int("Device", "View", 0));
    const path = try game.dir.realPathFileAlloc(io, current_folder, arena);
    try std.testing.expectEqualStrings(path, again.gameFolder(null, false));
    try std.testing.expectEqualStrings(current_folder, again.gameFolder(null, true));
    // The game's file is taken once only, and the same folder is noted once.
    try game.dir.writeFile(io, .{ .sub_path = profile.settings_name, .data = "[Device]\r\nView=2\r\n" });
    again.start(game.dir);
    again.remember(game.dir);
    try std.testing.expect(!again.file.changed);
    try std.testing.expectEqual(1, again.file.profile.int("Device", "View", 0));
}

test "Settings without a folder of the user's keeps the game folder's file" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var game = std.testing.tmpDir(.{});
    defer game.cleanup();
    try game.dir.writeFile(io, .{ .sub_path = profile.settings_name, .data = "[Device]\r\nView=1\r\n" });
    var settings: Settings = .open(io, arena_state.allocator(), null);
    defer settings.close();
    settings.start(game.dir);
    try std.testing.expectEqual(1, settings.file.profile.int("Device", "View", 0));
    try std.testing.expect(!settings.file.changed);
    // What changes is saved there.
    try settings.file.writeInt("Device", "View", 2);
    settings.save();
    var text_buffer: [64]u8 = undefined;
    const text = try game.dir.readFile(io, profile.settings_name, &text_buffer);
    try std.testing.expectEqualStrings("[Device]\r\nView=2\r\n", text);
}

test keys {
    // Each key once, and each takes what it says.
    for (keys, 0..) |key, index| {
        for (keys[0..index]) |before| try std.testing.expect(!std.ascii.eqlIgnoreCase(before.name, key.name));
    }
    try std.testing.expectEqualStrings("Original", keys[0].name);
}
