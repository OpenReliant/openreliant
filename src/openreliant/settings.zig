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
const FrameSize = engine.surrender.srd3d.device.FrameSize;
const screen = engine.game.interface.settings;
const options_page = @import("options.zig");
const Options = options_page.Options;
const Pacing = options_page.Pacing;
const Presenter = @import("presenter.zig").Presenter;

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
    .{ .name = original_key, .takes = on_off, .read = original },
    .{ .name = fullscreen_key, .takes = on_off, .read = onOff("fullscreen") },
    .{ .name = size_key, .takes = "<width>x<height> or <percent>%", .read = byOption(.@"--size") },
    .{ .name = frame_rate_key, .takes = "<rate>", .read = byOption(.@"--fps") },
    .{ .name = vsync_key, .takes = on_off, .read = onOff("settings.vsync") },
    .{ .name = "Software", .takes = on_off, .read = onOff("software") },
    .{ .name = sixteen_bit_key, .takes = on_off, .read = onOff("settings.sixteen_bit") },
    .{ .name = samples_key, .takes = "1, 2, 4 or 8", .read = byOption(.@"--msaa") },
    .{ .name = filter_key, .takes = "original, trilinear or crisp", .read = byOption(.@"--filter") },
    .{ .name = bloom_key, .takes = on_off, .read = onOff("settings.bloom") },
    .{ .name = dither_key, .takes = on_off, .read = onOff("settings.dither") },
    .{ .name = pixel_lighting_key, .takes = on_off, .read = onOff("settings.pixel_lighting") },
    .{ .name = linear_light_key, .takes = on_off, .read = onOff("settings.linear_light") },
    .{ .name = materials_key, .takes = on_off, .read = onOff("settings.materials") },
    .{ .name = shadows_key, .takes = "off, low or high", .read = byOption(.@"--shadows") },
    .{ .name = cockpit_shadows_key, .takes = on_off, .read = onOff("settings.cockpit_shadows") },
    .{ .name = smooth_motion_key, .takes = on_off, .read = onOff("smooth_motion") },
    .{ .name = shot_lights_key, .takes = on_off, .read = shotLights },
    .{ .name = real_lights_key, .takes = on_off, .read = onOff("real_lights") },
    .{ .name = outline_fonts_key, .takes = on_off, .read = onOff("outline_fonts") },
    .{ .name = mod_effects_key, .takes = on_off, .read = onOff("mod_effects") },
    .{ .name = hrtf_key, .takes = "auto, on or off", .read = hrtf },
    .{ .name = reverb_key, .takes = on_off, .read = reverb },
    .{ .name = compressor_key, .takes = on_off, .read = compressor },
    .{ .name = "DeveloperMode", .takes = on_off, .read = onOff("developer_mode") },
};

/// The keys the settings screen writes (`Own`): the display's options, the graphics' and the
/// sound's.
const original_key = "Original";
const fullscreen_key = "Fullscreen";
const size_key = "Size";
const frame_rate_key = "FrameRate";
const vsync_key = "Vsync";
const samples_key = "Samples";
const sixteen_bit_key = "SixteenBit";
const filter_key = "Filter";
const bloom_key = "Bloom";
const dither_key = "Dither";
const pixel_lighting_key = "PixelLighting";
const linear_light_key = "LinearLight";
const materials_key = "Materials";
const shadows_key = "Shadows";
const cockpit_shadows_key = "CockpitShadows";
const smooth_motion_key = "SmoothMotion";
const shot_lights_key = "ShotLights";
const real_lights_key = "RealLights";
const outline_fonts_key = "OutlineFonts";
const mod_effects_key = "ModEffects";
const hrtf_key = "Hrtf";
const reverb_key = "Reverb";
const compressor_key = "Compressor";

/// An option of the settings screen's, by its field, and the key that keeps it.
const FieldKey = struct { field: []const u8, name: []const u8 };

/// The graphics' options by the keys that keep them; `Original` keeps the base beneath them.
const graphics_keys = [_]FieldKey{
    .{ .field = "pixel_lighting", .name = pixel_lighting_key },
    .{ .field = "linear_light", .name = linear_light_key },
    .{ .field = "materials", .name = materials_key },
    .{ .field = "shadows", .name = shadows_key },
    .{ .field = "cockpit_shadows", .name = cockpit_shadows_key },
    .{ .field = "shot_lights", .name = shot_lights_key },
    .{ .field = "real_lights", .name = real_lights_key },
    .{ .field = "bloom", .name = bloom_key },
    .{ .field = "dither", .name = dither_key },
    .{ .field = "filter", .name = filter_key },
    .{ .field = "samples", .name = samples_key },
    .{ .field = "sixteen_bit", .name = sixteen_bit_key },
    .{ .field = "smooth_motion", .name = smooth_motion_key },
    .{ .field = "outline_fonts", .name = outline_fonts_key },
    .{ .field = "mod_effects", .name = mod_effects_key },
};

/// The game's own details among the graphics' options, which it keeps in `[Device]`
/// (`engine.game.winmain.Details`), by their keys.
const Details = engine.game.winmain.Details;
const device_keys = [_]FieldKey{
    .{ .field = "texture_detail", .name = Details.texture_key },
    .{ .field = "graphic_detail", .name = Details.graphic_key },
    .{ .field = "light_maps", .name = Details.light_maps_key },
};

comptime {
    // A key for each of the graphics' options, and `Original` for the base.
    const fields = @typeInfo(screen.Own.Graphics.Chosen).@"struct".fields.len;
    std.debug.assert(graphics_keys.len + device_keys.len + 1 == fields);
    for (graphics_keys ++ device_keys) |key| std.debug.assert(@hasField(screen.Own.Graphics.Chosen, key.field));
}

/// An option's value as its key takes it, in `arena`: 1 or 0 for on and off, every shot's lights
/// among them, a number as it is, and a choice by its name.
fn keyValue(arena: Allocator, value: anytype) Allocator.Error![]const u8 {
    return switch (@TypeOf(value)) {
        bool => if (value) "1" else "0",
        engine.game.guns.ShotLights => if (value == .every_shot) "1" else "0",
        u8 => std.fmt.allocPrint(arena, "{d}", .{value}),
        else => @tagName(value),
    };
}

/// `from`'s choice as `To`'s of the same name, which the compiler holds to having each.
fn sameTag(comptime To: type, from: anytype) To {
    return switch (from) {
        inline else => |tag| @field(To, @tagName(tag)),
    };
}

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
/// sound's, as the output plays them; the display's, as the window and the frames have them; and the
/// graphics', as the GPU draws with them. A change is written to `[OpenReliant]`, as `read` reads it,
/// and applied at once where it can be.
pub const Own = struct {
    settings_file: *engine.profile.File,
    output: ?*platform.audio.Output,
    /// The sound's options as the output plays them; none without sound.
    sound: ?platform.audio.Options,
    /// How the frames are paced; and the window, and what draws the frames at their size. None,
    /// for the tests, shows the display's options as they come.
    pacing: ?*Pacing = null,
    display: ?Display = null,
    /// The graphics' options as chosen, and what the game runs with of those that take effect at
    /// the next start (`graphicsOf`).
    graphics: screen.Own.Graphics = .{},
    /// What the graphics' options change as the game plays, besides the GPU: whether what moves is
    /// drawn between the ticks, and which shots light.
    smooth_motion: ?*bool = null,
    shot_lights: ?*engine.game.guns.ShotLights = null,
    /// Whether the mods' post effects are drawn.
    mod_effects: ?*bool = null,

    pub const Display = struct {
        window: *platform.window.Window,
        presenter: *Presenter,

        /// The GPU, where it draws the frames.
        fn gpu(display: Display) ?*platform.gpu.Gpu {
            return switch (display.presenter.screen.*) {
                .gpu => |*device| device,
                .software => null,
            };
        }
    };

    pub fn interface(own: *Own) screen.Own {
        return .{ .context = own, .vtable = &.{
            .audio = audio,
            .setAudio = setAudio,
            .display = shownDisplay,
            .setDisplay = setDisplay,
            .graphics = shownGraphics,
            .setGraphics = setGraphics,
        } };
    }

    /// The graphics' options, and the most samples a pixel the GPU draws with, one on the software
    /// device.
    fn shownGraphics(context: *anyopaque) screen.Own.Graphics {
        const own: *const Own = @ptrCast(@alignCast(context));
        var graphics = own.graphics;
        if (own.display) |display| graphics.most_samples = if (display.gpu()) |gpu| gpu.mostSamples() else 1;
        return graphics;
    }

    /// Writes the graphics' options (`keepGraphics`), and applies them from the next frame on: the
    /// GPU's, but for 16-bit colour and linear light, which wait for the next start as the fonts
    /// and the base do; the motion; and the shots' lights.
    fn setGraphics(context: *anyopaque, chosen: screen.Own.Graphics.Chosen) void {
        const own: *Own = @ptrCast(@alignCast(context));
        own.changeGraphics(chosen) catch |err| log.warn("the graphics' options are not kept: {s}", .{@errorName(err)});
    }

    fn changeGraphics(own: *Own, chosen: screen.Own.Graphics.Chosen) Allocator.Error!void {
        try own.keepGraphics(chosen);
        own.graphics.chosen = chosen;
        if (own.smooth_motion) |smooth| smooth.* = chosen.smooth_motion;
        if (own.shot_lights) |lights| lights.* = chosen.shot_lights;
        if (own.mod_effects) |drawn| drawn.* = chosen.mod_effects;
        const display = own.display orelse return;
        const gpu = display.gpu() orelse return;
        var wanted = gpu.settings;
        wanted.pixel_lighting = chosen.pixel_lighting;
        wanted.materials = chosen.materials;
        wanted.shadows = sameTag(platform.gpu.Settings.Shadows, chosen.shadows);
        wanted.cockpit_shadows = chosen.cockpit_shadows;
        wanted.bloom = chosen.bloom;
        wanted.dither = chosen.dither;
        wanted.filter = sameTag(platform.gpu.Settings.Filter, chosen.filter);
        wanted.samples = chosen.samples;
        gpu.apply(wanted);
    }

    /// Writes the graphics' options to `[OpenReliant]` so that the file reads back as `chosen`: the
    /// base, `Original`, and each option its own key, where it differs from the base's. A preset,
    /// and a change of base, write them whole, a preset as the base alone; otherwise only what has
    /// changed is written, and an option the command line changed for the run stays out of the
    /// file.
    ///
    /// `Original` plays the software Miles: written while OpenAL Soft plays, the sound's own keys
    /// go with it, so that the sound stays as the AUDIO tab has it.
    ///
    /// The game's details go to `[Device]`, each as its number where it changes, as
    /// `renderer_open` writes them as it starts the renderer again (`0x004A8716` on).
    fn keepGraphics(own: *Own, chosen: screen.Own.Graphics.Chosen) Allocator.Error!void {
        const file = own.settings_file;
        const was = own.graphics.chosen;
        inline for (device_keys) |key| {
            const value = @field(chosen, key.field);
            if (value != @field(was, key.field)) try file.writeInt(screen.video.section, key.name, switch (@TypeOf(value)) {
                bool => @intFromBool(value),
                else => @intFromEnum(value),
            });
        }
        const whole = chosen.preset() != null or chosen.original != was.original;
        if (whole) {
            if (chosen.original) {
                try own.keepSound();
                try file.writeInt(section, original_key, 1);
            } else try file.remove(section, original_key);
        }
        const base = (if (chosen.original) screen.Own.Graphics.Preset.original else screen.Own.Graphics.Preset.modern).chosen();
        inline for (graphics_keys) |key| {
            const value = @field(chosen, key.field);
            if (whole or !std.meta.eql(value, @field(was, key.field))) {
                if (std.meta.eql(value, @field(base, key.field))) {
                    try file.remove(section, key.name);
                } else try file.write(section, key.name, try keyValue(file.arena, value));
            }
        }
    }

    /// Writes the sound's options as OpenAL Soft plays them, where it does.
    fn keepSound(own: *Own) Allocator.Error!void {
        const sound = own.sound orelse return;
        const openal = switch (sound.player) {
            .openal => |settings| settings,
            .software => return,
        };
        const file = own.settings_file;
        try file.write(section, hrtf_key, @tagName(openal.hrtf));
        try file.writeInt(section, reverb_key, @intFromBool(openal.reverb));
        try file.writeInt(section, compressor_key, @intFromBool(own.shown().compressor));
    }

    fn shownDisplay(context: *anyopaque) screen.Own.Display {
        const own: *const Own = @ptrCast(@alignCast(context));
        return own.displayed();
    }

    fn displayed(own: Own) screen.Own.Display {
        var current: screen.Own.Display = .{};
        if (own.pacing) |pacing| {
            current.chosen.frame_rate = pacing.fps;
            current.chosen.vsync = pacing.vsync;
        }
        const display = own.display orelse return current;
        current.chosen.size = display.presenter.wanted;
        current.chosen.fullscreen = display.window.fillsDisplay();
        current.told = .{ .window = display.presenter.windowSize(), .refresh_rate = display.window.refreshRate() };
        return current;
    }

    /// Writes what has changed of the display's options, and applies it from the next frame on:
    /// the frames' size, the window filling the display or not, their pacing, and the GPU's vsync.
    fn setDisplay(context: *anyopaque, chosen: screen.Own.Display.Chosen) void {
        const own: *Own = @ptrCast(@alignCast(context));
        own.changeDisplay(chosen) catch |err| log.warn("the display's options are not kept: {s}", .{@errorName(err)});
    }

    fn changeDisplay(own: *Own, chosen: screen.Own.Display.Chosen) Allocator.Error!void {
        const file = own.settings_file;
        const current = own.displayed().chosen;
        if (!std.meta.eql(chosen.size, current.size)) {
            try file.write(section, size_key, try sizeText(file.arena, chosen.size));
            if (own.display) |display| display.presenter.setSize(chosen.size);
        }
        if (chosen.fullscreen != current.fullscreen) {
            try file.writeInt(section, fullscreen_key, @intFromBool(chosen.fullscreen));
            if (own.display) |display| display.window.setFullscreen(chosen.fullscreen);
        }
        if (!std.meta.eql(chosen.frame_rate, current.frame_rate)) {
            // The display's rate is what the file says without the key.
            if (chosen.frame_rate) |rate| {
                try file.write(section, frame_rate_key, try std.fmt.allocPrint(file.arena, "{d}", .{rate}));
            } else try file.remove(section, frame_rate_key);
            if (own.pacing) |pacing| pacing.fps = chosen.frame_rate;
        }
        if (chosen.vsync != current.vsync) {
            try file.writeInt(section, vsync_key, @intFromBool(chosen.vsync));
            if (own.pacing) |pacing| pacing.vsync = chosen.vsync;
        }
        const display = own.display orelse return;
        const gpu = display.gpu() orelse return;
        var wanted = gpu.settings;
        wanted.vsync = chosen.vsync;
        gpu.apply(wanted);
    }

    fn audio(context: *anyopaque) screen.Own.Audio {
        const own: *const Own = @ptrCast(@alignCast(context));
        return own.shown();
    }

    fn shown(own: Own) screen.Own.Audio {
        const sound = own.sound orelse return .{ .hrtf = .off, .reverb = false, .compressor = false, .openal = false };
        const compressing = if (sound.master) |bus| bus.compresses() else false;
        return switch (sound.player) {
            .openal => |openal| .{ .hrtf = sameTag(screen.Own.Hrtf, openal.hrtf), .reverb = openal.reverb, .compressor = compressing },
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
                const chosen_hrtf = sameTag(platform.audio.openal.Hrtf, chosen.hrtf);
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

/// `Size`'s value for `size`, as `--size` takes it, in `arena`.
fn sizeText(arena: Allocator, size: FrameSize) Allocator.Error![]const u8 {
    return switch (size) {
        .share => |share| std.fmt.allocPrint(arena, "{d}%", .{share}),
        .pixels => |pixels| std.fmt.allocPrint(arena, "{d}x{d}", .{ pixels[0], pixels[1] }),
    };
}

comptime {
    // The settings screen's defaults are the options' own, and its presets the options' and
    // `--original`'s, the game's details at their highest.
    const options: Options = .{};
    std.debug.assert(std.meta.eql(graphicsOf(options, .{}).chosen, screen.Own.Graphics.Preset.modern.chosen()));
    var original_options: Options = .{};
    original_options.apply(.@"--original", "") catch unreachable;
    std.debug.assert(std.meta.eql(graphicsOf(original_options, .{}).chosen, screen.Own.Graphics.Preset.original.chosen()));
    const display: screen.Own.Display.Chosen = .{};
    std.debug.assert(std.meta.eql(options.settings.size, display.size));
    std.debug.assert(options.fullscreen == display.fullscreen and options.settings.vsync == display.vsync);
    std.debug.assert(options.fps == display.frame_rate);
}

/// The graphics' options as the game starts with them, the options' (`read`) and the game's
/// `details`, and what it runs with of those that take effect at the next start.
pub fn graphicsOf(options: Options, details: Details) screen.Own.Graphics {
    const gpu = options.settings;
    const chosen: screen.Own.Graphics.Chosen = .{
        .original = options.original,
        .texture_detail = details.texture,
        .graphic_detail = details.graphic,
        .light_maps = details.light_maps,
        .pixel_lighting = gpu.pixel_lighting,
        .linear_light = gpu.linear_light,
        .materials = gpu.materials,
        .shadows = sameTag(screen.Own.Graphics.Shadows, gpu.shadows),
        .cockpit_shadows = gpu.cockpit_shadows,
        .shot_lights = options.shot_lights,
        .real_lights = options.real_lights,
        .bloom = gpu.bloom,
        .dither = gpu.dither,
        .filter = sameTag(screen.Own.Graphics.Filter, gpu.filter),
        .samples = gpu.samples,
        .sixteen_bit = gpu.sixteen_bit,
        .smooth_motion = options.smooth_motion,
        .outline_fonts = options.outline_fonts,
        .mod_effects = options.mod_effects,
    };
    return .{ .chosen = chosen, .running = .of(chosen) };
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
        \\OutlineFonts=1
        \\DeveloperMode=1
    );
    try std.testing.expect(chosen.settings.bloom and chosen.settings.sixteen_bit);
    try std.testing.expectEqual(8, chosen.settings.samples);
    try std.testing.expectEqual(.low, chosen.settings.shadows);
    try std.testing.expectEqual(.original, chosen.settings.filter);
    try std.testing.expectEqual(0, chosen.fps.?);
    try std.testing.expectEqual(FrameSize{ .pixels = .{ 800, 600 } }, chosen.settings.size);
    try std.testing.expectEqual(.every_shot, chosen.shot_lights);
    try std.testing.expect(!chosen.smooth_motion and !chosen.settings.vsync);
    try std.testing.expect(chosen.original and chosen.outline_fonts and chosen.developer_mode);
    try std.testing.expect(!plain.developer_mode);
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

test "Own's display options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: engine.profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var own: Own = .{ .settings_file = &file, .output = null, .sound = .{} };
    const shown = own.interface();
    try std.testing.expectEqual(screen.Own.Display{}, shown.display());
    // What changes is written as the command line takes it, and read back the same.
    shown.setDisplay(.{ .size = .{ .share = 50 }, .fullscreen = true, .frame_rate = 144, .vsync = false });
    try std.testing.expectEqualStrings("50%", file.profile.value(section, size_key).?);
    try std.testing.expectEqualStrings("1", file.profile.value(section, fullscreen_key).?);
    try std.testing.expectEqualStrings("144", file.profile.value(section, frame_rate_key).?);
    const read_back = optionsOf(file.profile.text);
    try std.testing.expectEqual(FrameSize{ .share = 50 }, read_back.settings.size);
    try std.testing.expect(read_back.fullscreen and !read_back.settings.vsync);
    try std.testing.expectEqual(144, read_back.fps.?);
    shown.setDisplay(.{ .size = .{ .pixels = .{ 800, 600 } }, .frame_rate = 30 });
    try std.testing.expectEqualStrings("800x600", file.profile.value(section, size_key).?);
    // The pacing follows; the display's rate, the default, takes the key out of the file.
    var pacing: Pacing = .{};
    own.pacing = &pacing;
    shown.setDisplay(.{ .frame_rate = 60 });
    try std.testing.expectEqual(60, pacing.fps.?);
    try std.testing.expectEqualStrings("60", file.profile.value(section, frame_rate_key).?);
    shown.setDisplay(.{});
    try std.testing.expectEqual(null, pacing.fps);
    try std.testing.expectEqual(null, file.profile.value(section, frame_rate_key));
}

test "Own's graphics options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: engine.profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var smooth_motion = true;
    var shot_lights: engine.game.guns.ShotLights = .every_shot;
    var own: Own = .{ .settings_file = &file, .output = null, .sound = .{}, .graphics = graphicsOf(.{}, .{}), .smooth_motion = &smooth_motion, .shot_lights = &shot_lights };
    const shown = own.interface();
    try std.testing.expectEqual(screen.Own.Graphics{}, shown.graphics());
    // What changes is written as the file takes it, and read back the same; the motion and the
    // shots' lights change at once.
    const chosen: screen.Own.Graphics.Chosen = .{ .shadows = .low, .filter = .original, .samples = 8, .sixteen_bit = true, .smooth_motion = false, .shot_lights = .latest_two, .outline_fonts = false };
    shown.setGraphics(chosen);
    try std.testing.expectEqualStrings("low", file.profile.value(section, shadows_key).?);
    try std.testing.expectEqualStrings("0", file.profile.value(section, shot_lights_key).?);
    try std.testing.expectEqualStrings("8", file.profile.value(section, samples_key).?);
    try std.testing.expectEqualStrings("0", file.profile.value(section, outline_fonts_key).?);
    try std.testing.expectEqual(null, file.profile.value(section, bloom_key));
    try std.testing.expect(!smooth_motion);
    try std.testing.expectEqual(.latest_two, shot_lights);
    try std.testing.expectEqual(chosen, graphicsOf(optionsOf(file.profile.text), .{}).chosen);
    // 16-bit colour and the fonts wait for the next start: the game runs as it started.
    try std.testing.expect(!shown.graphics().running.sixteen_bit and shown.graphics().waits());
    // Changed back to the default, an option's key goes.
    var back = chosen;
    back.shadows = .high;
    shown.setGraphics(back);
    try std.testing.expectEqual(null, file.profile.value(section, shadows_key));
    // The game's details go to `[Device]` as numbers, as its renderer writes them, and are read
    // back the same.
    var lowered = back;
    lowered.texture_detail = .low;
    lowered.light_maps = false;
    shown.setGraphics(lowered);
    try std.testing.expectEqualStrings("0", file.profile.value(screen.video.section, Details.texture_key).?);
    try std.testing.expectEqualStrings("0", file.profile.value(screen.video.section, Details.light_maps_key).?);
    try std.testing.expectEqual(null, file.profile.value(screen.video.section, Details.graphic_key));
    try std.testing.expectEqual(Details{ .texture = .low, .light_maps = false }, Details.read(file.profile));
    try std.testing.expect(shown.graphics().waits());
}

test "Own's presets keep the file to its base" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: engine.profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var own: Own = .{ .settings_file = &file, .output = null, .sound = .{}, .graphics = graphicsOf(.{}, .{}) };
    const shown = own.interface();
    const Preset = screen.Own.Graphics.Preset;
    // ORIGINAL is written as `Original` alone, with the sound's keys, which keep OpenAL Soft
    // playing, its compressor on.
    shown.setGraphics(Preset.original.chosen());
    try std.testing.expectEqualStrings("1", file.profile.value(section, original_key).?);
    try std.testing.expectEqual(null, file.profile.value(section, bloom_key));
    try std.testing.expectEqualStrings("auto", file.profile.value(section, hrtf_key).?);
    const original_read = optionsOf(file.profile.text);
    try std.testing.expectEqual(Preset.original.chosen(), graphicsOf(original_read, .{}).chosen);
    try std.testing.expect(original_read.sound.?.player == .openal and original_read.sound.?.master.?.compresses());
    // An option changed from it is written beside it; changed back, the preset is the base alone.
    var bloomed = Preset.original.chosen();
    bloomed.bloom = true;
    shown.setGraphics(bloomed);
    try std.testing.expectEqualStrings("1", file.profile.value(section, bloom_key).?);
    try std.testing.expectEqual(bloomed, graphicsOf(optionsOf(file.profile.text), .{}).chosen);
    shown.setGraphics(Preset.original.chosen());
    try std.testing.expectEqual(null, file.profile.value(section, bloom_key));
    // MODERN takes `Original` out.
    shown.setGraphics(Preset.modern.chosen());
    try std.testing.expectEqual(null, file.profile.value(section, original_key));
    try std.testing.expectEqual(Preset.modern.chosen(), graphicsOf(optionsOf(file.profile.text), .{}).chosen);
    // A change of base that is no preset, as CANCEL CHANGES puts back, writes every option that
    // differs from the new base.
    shown.setGraphics(bloomed);
    try std.testing.expectEqualStrings("1", file.profile.value(section, original_key).?);
    try std.testing.expectEqual(bloomed, graphicsOf(optionsOf(file.profile.text), .{}).chosen);
}

test keys {
    // Each key once, the first `Original`.
    for (keys, 0..) |key, index| {
        for (keys[0..index]) |before| try std.testing.expect(!std.ascii.eqlIgnoreCase(before.name, key.name));
    }
    try std.testing.expectEqualStrings("Original", keys[0].name);
}
