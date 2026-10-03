//! OpenReliant's settings screen (`Settings`), which stands in for the original's settings screens
//! wherever they open: GAME OPTIONS' and the in-game options' AUDIO, CONTROL DEVICES and VIDEO
//! (screens 3, 16 and 15 of the front end), and the pause menu's. It is laid out as the original's
//! are, on the front end's screen with their shapes (`shapes_name`), with a tab for each in place
//! of their titles, and their buttons: OK and MAIN MENU, or CONTINUE in the pause menu, RESET
//! DEFAULTS and CANCEL CHANGES, which act on the tab shown.
//!
//! The tabs: the audio ([`settings/audio.zig`](settings/audio.zig)), the controls
//! ([`settings/controls.zig`](settings/controls.zig)), and the video
//! ([`settings/video.zig`](settings/video.zig)), which holds OpenReliant's graphics options in a list
//! of its own ([`settings/graphics.zig`](settings/graphics.zig)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const profile = @import("../../profile.zig");
const device = @import("../../surrender/srd3d/device.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const camera = @import("../camera.zig");
const explode = @import("../explode.zig");
const guns = @import("../guns.zig");
const xtrabits = @import("../xtrabits.zig");
const hud = @import("../hud.zig");
const hog_snd = @import("../hog_snd.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const dialog = @import("dialog.zig");

pub const audio = @import("settings/audio.zig");
pub const controls = @import("settings/controls.zig");
pub const video = @import("settings/video.zig");
pub const graphics = @import("settings/graphics.zig");
pub const widgets = @import("settings/widgets.zig");

const log = std.log.scoped(.interface);

/// The shapes the screen draws with: the audio and video screens' (`audio_screen`, `0x0042DAC4`),
/// which hold the controls screen's widgets too, but for the buttons, which take a smoother palette
/// than screen 16's own.
pub const shapes_name = "interface\\frntend5.spr";

/// The tabs, in the order the strip shows them.
pub const Tab = enum {
    audio,
    controls,
    video,

    /// Its label, the one the menus' icon for it has, where the game's screens write their titles
    /// (`0x0042CDA9`), each above its icon's column in GAME OPTIONS (`0x0042B320` on).
    fn label(tab: Tab) Label {
        return switch (tab) {
            .audio => .of(0x109, .{ 133, title_y }, .centre),
            .controls => .of(0x10A, .{ 320, title_y }, .centre),
            .video => .of(0x10B, .{ 511, title_y }, .centre),
        };
    }

    /// Where the pointer finds it: round its label, as wide as it is.
    fn rect(tab: Tab) Rect {
        const half_width: i16 = switch (tab) {
            .audio, .video => 50,
            .controls => 80,
        };
        const centre: i16 = @intCast(tab.label().at[0]);
        return .{ .x = centre - half_width, .y = title_y - tab_above, .width = 2 * half_width, .height = tab_height };
    }
};

/// The labels' row, and where the pointer finds a label: from a little above it, as high as the
/// large font's letters.
pub const title_y = 95;
const tab_above = 4;
const tab_height = 20;

/// The menu the screen opened from, which its second button and its movies follow.
pub const From = enum { game_options, in_game_options, pause_menu };

/// How the screen ends: OK, or Escape, back to the menu it opened from; MAIN MENU to the main menu;
/// CONTINUE back to the mission.
pub const End = enum { back, main_menu, continue_mission };

/// The movie that leads into the screen from `from` on `tab`, and the background it shows: the one
/// GAME OPTIONS plays as an icon is chosen, which fades the icons out of its picture (`0x0042A798`,
/// `0x0042A7C9`), and the in-game options' (`0x0043973A`, `0x00439770`, `0x0043978B`). The pause
/// menu has neither: the screen stands over the mission.
pub fn opening(from: From, tab: Tab) ?struct { movie: []const u8, background: []const u8 } {
    return switch (from) {
        .game_options => .{ .movie = "interface\\optfade.bik", .background = "interface\\optfade.tga" },
        .in_game_options => .{ .movie = "interface\\igofade.bik", .background = switch (tab) {
            .audio, .video => "interface\\igoptfad.tga",
            .controls => "interface\\igofade.tga",
        } },
        .pause_menu => null,
    };
}

/// OpenReliant's own options the screen shows, which the driver keeps: how it reads them, and has a
/// change written to `starlancer.ini`'s `[OpenReliant]` and applied at once.
pub const Own = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        audio: *const fn (context: *anyopaque) Audio,
        setAudio: *const fn (context: *anyopaque, audio: Audio) void,
        display: *const fn (context: *anyopaque) Display,
        setDisplay: *const fn (context: *anyopaque, chosen: Display.Chosen) void,
        graphics: *const fn (context: *anyopaque) Graphics,
        setGraphics: *const fn (context: *anyopaque, chosen: Graphics.Chosen) void,
    };

    /// The sound's options: how OpenAL Soft renders the 3D sounds, for headphones (HRTF) by the
    /// output, always or never; its reverb; and the master bus's compressor.
    pub const Audio = struct {
        hrtf: Hrtf = .auto,
        reverb: bool = true,
        compressor: bool = true,
        /// Whether OpenAL Soft plays the sound, whose the HRTF and the reverb are; the software
        /// Miles of `--original` has neither.
        openal: bool = true,
    };

    pub const Hrtf = enum { auto, on, off };

    /// The display's options: what the screen chooses, and what the driver tells, which choosing
    /// leaves as it is.
    pub const Display = struct {
        chosen: Chosen = .{},
        told: Told = .{},

        pub const Chosen = struct {
            /// The size the frames are drawn at.
            size: device.FrameSize = .window,
            /// Whether the window fills the display.
            fullscreen: bool = false,
            /// Frames a second at most: null for the display's rate where vsync is off, 0 for no
            /// limit.
            frame_rate: ?f32 = null,
            /// Whether the display paces the frames.
            vsync: bool = true,
        };

        pub const Told = struct {
            /// The window's own size, which a share of it is of.
            window: [2]u32 = canvas_module.size,
            /// The display's refresh rate, where it is known.
            refresh_rate: ?f32 = null,
        };
    };

    /// The graphics' options: what the screen chooses; what the game runs with of those that take
    /// effect at the next start, which choosing leaves as it is; and the most samples a pixel the
    /// GPU draws with.
    pub const Graphics = struct {
        chosen: Chosen = .{},
        running: Running = .{},
        most_samples: u8 = 8,

        pub const Chosen = struct {
            /// Whether the original's look and sound lie beneath the options, as `--original` gives
            /// them: what the screen has no row for follows it.
            original: bool = false,
            /// The game's own details (`winmain.Details`), which the presets leave at their
            /// highest.
            texture_detail: xtrabits.TextureDetail = .high,
            graphic_detail: explode.Detail = .high,
            light_maps: bool = true,
            pixel_lighting: bool = true,
            linear_light: bool = true,
            /// Whether the material maps of mod textures are used.
            materials: bool = true,
            shadows: Shadows = .high,
            cockpit_shadows: bool = true,
            shot_lights: guns.ShotLights = .every_shot,
            /// Whether the steady lights of ships and stations shine as lights rather than baked
            /// into their hulls (`srofiles.Settings.real_lights`).
            real_lights: bool = true,
            bloom: bool = true,
            dither: bool = true,
            filter: Filter = .crisp,
            /// Samples a pixel, for smooth edges: 1, 2, 4 or 8.
            samples: u8 = 4,
            sixteen_bit: bool = false,
            smooth_motion: bool = true,
            /// Whether the interface's text is drawn from outline fonts.
            outline_fonts: bool = true,

            /// The preset they are, where they are one.
            pub fn preset(chosen: Chosen) ?Preset {
                for (std.enums.values(Preset)) |each| if (std.meta.eql(chosen, each.chosen())) return each;
                return null;
            }
        };

        /// What the game runs with of the options that take effect at the next start: the base,
        /// the game's details, linear light and 16-bit colour, which change the GPU's formats, and
        /// the fonts.
        pub const Running = struct {
            original: bool = false,
            texture_detail: xtrabits.TextureDetail = .high,
            graphic_detail: explode.Detail = .high,
            light_maps: bool = true,
            real_lights: bool = true,
            linear_light: bool = true,
            sixteen_bit: bool = false,
            outline_fonts: bool = true,

            /// What a game started with `chosen` runs with.
            pub fn of(chosen: Chosen) Running {
                var running: Running = undefined;
                inline for (@typeInfo(Running).@"struct".fields) |field| @field(running, field.name) = @field(chosen, field.name);
                return running;
            }
        };

        pub const Shadows = enum { off, low, high };
        pub const Filter = enum { original, trilinear, crisp };

        /// The options at either end: the original's look, and OpenReliant's, every improvement on.
        pub const Preset = enum {
            original,
            modern,

            /// Its options: OpenReliant's defaults, or `--original`'s.
            pub fn chosen(preset: Preset) Chosen {
                return switch (preset) {
                    .modern => .{},
                    .original => .{
                        .original = true,
                        .pixel_lighting = false,
                        .linear_light = false,
                        .materials = false,
                        .shadows = .off,
                        .shot_lights = .latest_two,
                        .real_lights = false,
                        .bloom = false,
                        .dither = false,
                        .filter = .original,
                        .samples = 1,
                        .sixteen_bit = true,
                        .smooth_motion = false,
                        .outline_fonts = false,
                    },
                };
            }
        };

        /// Whether an option that takes effect at the next start differs from what the game runs
        /// with.
        pub fn waits(options: Graphics) bool {
            return !std.meta.eql(Running.of(options.chosen), options.running);
        }
    };

    pub fn audio(own: Own) Audio {
        return own.vtable.audio(own.context);
    }

    pub fn setAudio(own: Own, chosen: Audio) void {
        own.vtable.setAudio(own.context, chosen);
    }

    pub fn display(own: Own) Display {
        return own.vtable.display(own.context);
    }

    pub fn setDisplay(own: Own, chosen: Display.Chosen) void {
        own.vtable.setDisplay(own.context, chosen);
    }

    pub fn graphics(own: Own) Graphics {
        return own.vtable.graphics(own.context);
    }

    pub fn setGraphics(own: Own, chosen: Graphics.Chosen) void {
        own.vtable.setGraphics(own.context, chosen);
    }
};

/// The game's video settings, where the driver keeps them, which the video changes.
pub const Video = struct {
    /// The camera, whose cockpit setting is the options' (`cockpit_mode_setting`), which a
    /// mission starts in.
    camera: *camera.Camera,
    /// Surrender's state, whose brightness (`sr + 0x15FA`) the device's gamma ramp follows.
    surrender: *srapi.Context,
    /// Whether the device has a gamma ramp (`sr + 0x38` bit 0), without which the brightness is
    /// hidden.
    gamma: bool,
    /// Whether the movies between the front end's screens play (`transitions`, `0x005D5E80`).
    transitions: *bool,
};

/// The movie played as the screen, opened from `from`, ends by `end`: back, the icons fade in again
/// (`0x0042C4E2`, `0x0042C4EB`); to the main menu, the menu's own movie (`0x0042C541`,
/// `0x0042C54A`).
pub fn leavingMovie(from: From, end: End) ?[]const u8 {
    return switch (from) {
        .game_options => switch (end) {
            .back => "interface\\optfade2.bik",
            .main_menu => "interface\\opfad2mm.bik",
            .continue_mission => null,
        },
        .in_game_options => switch (end) {
            .back => "interface\\igofade2.bik",
            .main_menu => "interface\\igof2mm.bik",
            .continue_mission => null,
        },
        .pause_menu => null,
    };
}

/// The buttons, which the original's settings screens share.
pub const Button = enum {
    ok,
    /// MAIN MENU, or CONTINUE in the pause menu, as the pause menu's own screens have it.
    leave,
    reset_defaults,
    cancel_changes,

    /// Where the pointer finds it (`0x0042B69A` on), and where its shape and its label stand
    /// (`0x0042D019` on).
    pub fn rect(button: Button) Rect {
        return switch (button) {
            .ok => .{ .x = 199, .y = 422, .width = 120, .height = 15 },
            .leave => .{ .x = 199, .y = 443, .width = 120, .height = 15 },
            .reset_defaults => .{ .x = 329, .y = 422, .width = 100, .height = 15 },
            .cancel_changes => .{ .x = 329, .y = 443, .width = 100, .height = 15 },
        };
    }

    /// The button with the label the screens give it, MAIN MENU or CONTINUE as `from` says.
    pub fn shown(button: Button, from: From) canvas_module.Button {
        return button.labelled(switch (button) {
            .ok => .{ .string = 0x316 },
            .leave => .{ .string = if (from == .pause_menu) continue_string else main_menu_string },
            .reset_defaults => .{ .string = 0x183 },
            .cancel_changes => .{ .string = 0x5A9 },
        });
    }

    /// The button in its place with `text` as its label: the left column's labels end left of
    /// their shapes, and the right column's start right of them.
    pub fn labelled(button: Button, text: Label.Text) canvas_module.Button {
        return switch (button) {
            .ok => .{ .at = .{ 299, 422 }, .label = .{ .text = text, .at = .{ 292, 421 }, .alignment = .right } },
            .leave => .{ .at = .{ 299, 443 }, .label = .{ .text = text, .at = .{ 292, 442 }, .alignment = .right } },
            .reset_defaults => .{ .at = .{ 329, 422 }, .label = .{ .text = text, .at = .{ 357, 421 } } },
            .cancel_changes => .{ .at = .{ 329, 443 }, .label = .{ .text = text, .at = .{ 357, 442 } } },
        };
    }
};

const main_menu_string = 0xBB;
const continue_string = 0x180;

/// The buttons' shapes, and lit under the pointer (`0x0042D109`, `0x0042D709`).
pub const button_shapes: canvas_module.Button.Pair = .{ .off = 0x28, .lit = 0x29 };

/// What Escape asks where a binding has changed (`0x0042C4BA`): Would you like to save your
/// changes before leaving this screen?
const save_question = 0x5AB;

/// What a frame of the screen reads, and changes.
pub const Context = struct {
    /// The pointer, its button down where the press is the screen's to take.
    pointer: Pointer,
    devices: *input.Devices,
    /// `starlancer.ini`, which the settings are written to.
    settings_file: *profile.File,
    /// The timer's ticks (`game_ticks`), which a held arrow scrolls the list by.
    ticks: u32,
    /// The sound, whose volumes the audio changes; none changes none.
    sound: ?*hog_snd.Sound = null,
    /// OpenReliant's own options; none shows them as they come.
    own: ?Own = null,
    /// The game's video settings; none leaves the video as it is.
    video: ?Video = null,
};

/// What the pointer finds: a tab's label, a button, or an item of the tab shown.
const Item = union(enum) {
    tab: Tab,
    button: Button,
    audio: audio.Item,
    controls: controls.Item,
    video: video.Item,
};

/// The screen's state.
pub const Settings = struct {
    from: From = .game_options,
    tab: Tab = .controls,
    audio: audio.Audio = .{},
    controls: controls.Controls = .{},
    video: video.Video = .{},
    /// The tab's label under the pointer, gold.
    lit_tab: ?Tab = null,
    /// The button under the pointer, lit (`0x0051DB44`).
    lit: ?Button = null,
    /// Whether the press that chose an item is still down, which chooses nothing more until it
    /// comes up (`0x0042BB37`).
    held: bool = false,
    /// Escape's question, while it is up.
    question: ?dialog.Confirm = null,

    /// Opens the screen from `from` on `tab`, each tab as its screen opens.
    pub fn enter(screen: *Settings, from: From, tab: Tab, context: Context) void {
        screen.* = .{ .from = from, .tab = tab };
        screen.audio.enter(context);
        screen.controls.enter(context);
        screen.video.enter(context);
    }

    /// A pass of the screen's loop (`controls_screen`, `0x0042BB08` on); how it ends, once it
    /// does. What it can't write to the settings file is logged.
    pub fn frame(screen: *Settings, context: Context) ?End {
        return screen.pass(context) catch |err| {
            log.warn("the settings are not kept: {s}", .{@errorName(err)});
            return null;
        };
    }

    /// The joystick read, as the controls screen's loop reads it (`0x0042BB17`); the questions up
    /// and the button taken take the pass. Then Escape, which asks first where a binding has
    /// changed; the audio's knobs, the keys and the wheel that scroll the lists, and the video's
    /// knob; then the item under the pointer, chosen as the pointer's button goes down, and lit
    /// while it is up; then the waiting row's keys and buttons.
    ///
    /// **Improvement:** Escape while a row waits only ends the wait, the old binding back where it
    /// took nothing; the game leaves the screen.
    fn pass(screen: *Settings, context: Context) Allocator.Error!?End {
        const devices = context.devices;
        const bindings = &screen.controls;
        devices.joystick.read();
        const escaped = devices.keyboard.pressed(input.scan.escape, .none, true);
        if (screen.question) |*question| {
            const answer = question.frame(context.pointer, escaped) orelse return null;
            screen.question = null;
            if (!answer) bindings.reload(devices, context.settings_file.profile);
            return try screen.leave(.back, context);
        }
        if (bindings.busy(context, escaped)) return null;
        if (escaped) {
            if (bindings.waiting != null) {
                bindings.endWait(devices);
                return null;
            }
            if (bindings.changed) {
                screen.question = .{ .message = .{ .string = save_question } };
                return null;
            }
            return try screen.leave(.back, context);
        }
        var pointer = context.pointer;
        if (pointer.down and screen.held) pointer.down = false else screen.held = false;
        screen.lit = null;
        screen.lit_tab = null;
        screen.audio.arrow = null;
        screen.video.unlight();
        bindings.arrow = null;
        switch (screen.tab) {
            .audio => screen.audio.slide(context),
            .controls => bindings.scrollKeys(context),
            .video => screen.video.slide(context),
        }
        const under = screen.itemAt(context, pointer.at) orelse {
            if (pointer.down) bindings.endWait(devices);
            bindings.wait(context);
            return null;
        };
        if (!pointer.down) {
            switch (under) {
                .tab => |tab| screen.lit_tab = tab,
                .button => |button| screen.lit = button,
                .audio => |item| screen.audio.hover(item),
                .controls => |item| bindings.hover(item),
                .video => |item| screen.video.hover(item),
            }
        } else {
            screen.held = true;
            switch (under) {
                .tab => |tab| if (tab != screen.tab) {
                    bindings.endWait(devices);
                    screen.tab = tab;
                },
                .button => |button| switch (button) {
                    .ok => return try screen.leave(.back, context),
                    .leave => return try screen.leave(if (screen.from == .pause_menu) .continue_mission else .main_menu, context),
                    .reset_defaults => switch (screen.tab) {
                        .audio => try screen.audio.reset(context),
                        .controls => try bindings.reset(devices, context.settings_file),
                        .video => try screen.video.reset(context),
                    },
                    .cancel_changes => switch (screen.tab) {
                        .audio => screen.audio.cancel(context),
                        .controls => bindings.cancel(devices),
                        .video => try screen.video.cancel(context),
                    },
                },
                .audio => |item| screen.audio.choose(item, context),
                .video => |item| if (try screen.video.choose(item, context)) {
                    screen.held = false;
                },
                .controls => |item| if (try bindings.choose(item, context)) {
                    screen.held = false;
                },
            }
        }
        bindings.wait(context);
        return null;
    }

    /// Leaves by `end`, each tab's settings written (`save_key_config`, `0x0042E0AE` on, and
    /// `0x0042F0AF` on).
    ///
    /// **Fix:** leaving puts back the binding of a row waiting with nothing taken, where the game
    /// writes the action unbound.
    fn leave(screen: *Settings, end: End, context: Context) Allocator.Error!End {
        screen.controls.endWait(context.devices);
        try screen.controls.save(context.devices, context.settings_file);
        try screen.audio.save(context);
        try screen.video.save(context);
        return end;
    }

    /// What the pointer finds at `at`: the tabs' labels and the buttons first, then the shown
    /// tab's items.
    fn itemAt(screen: Settings, context: Context, at: [2]i32) ?Item {
        for (std.enums.values(Tab)) |tab| if (tab.rect().holds(at)) return .{ .tab = tab };
        for (std.enums.values(Button)) |button| if (button.rect().holds(at)) return .{ .button = button };
        return switch (screen.tab) {
            .audio => .{ .audio = audio.itemAt(context, at) orelse return null },
            .controls => .{ .controls = controls.Controls.itemAt(at) orelse return null },
            .video => .{ .video = screen.video.itemAt(context, at) orelse return null },
        };
    }

    /// The screen's drawing (`controls_screen_draw`, `0x0042CD30`, `audio_screen_draw`,
    /// `0x0042E2E0`, `video_screen_draw`, `0x0042F440`): the tabs' labels, the shown one white and
    /// one under the pointer gold, the tab, the buttons, the one under the pointer lit, Escape's
    /// question where it is up, OpenReliant's version, then the pointer.
    pub fn draw(screen: Settings, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, shown: Shown, pointer: Pointer) canvas_module.Error!void {
        for (std.enums.values(Tab)) |tab| {
            const colour = if (tab == screen.tab) canvas_module.white else if (screen.lit_tab == tab) canvas_module.gold else canvas_module.blue;
            try tab.label().write(canvas, canvas.fonts.large, colour);
        }
        for (std.enums.values(Button)) |button| try button.shown(screen.from).draw(canvas, art, button_shapes, screen.lit == button);
        switch (screen.tab) {
            .audio => try screen.audio.draw(canvas, art, shown.sound),
            .controls => try screen.controls.draw(canvas, art, dialog_art, shown.devices),
            .video => try screen.video.draw(canvas, art, shown.video),
        }
        if (screen.question) |question| try question.draw(canvas, dialog_art);
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
    }
};

/// What the screen shows the state of as it is drawn.
pub const Shown = struct {
    devices: *const input.Devices,
    sound: ?*const hog_snd.Sound = null,
    video: ?Video = null,
};

/// What the tabs' tests stand a driver in with.
pub const testing = struct {
    /// OpenReliant's options as a driver keeps them: what it was last given, and how often.
    pub const Recorder = struct {
        audio: Own.Audio = .{},
        display: Own.Display = .{},
        graphics: Own.Graphics = .{},
        given: usize = 0,

        pub fn own(recorder: *Recorder) Own {
            return .{ .context = recorder, .vtable = &.{
                .audio = getAudio,
                .setAudio = setAudio,
                .display = getDisplay,
                .setDisplay = setDisplay,
                .graphics = getGraphics,
                .setGraphics = setGraphics,
            } };
        }

        fn from(context: *anyopaque) *Recorder {
            return @ptrCast(@alignCast(context));
        }

        fn getAudio(context: *anyopaque) Own.Audio {
            return from(context).audio;
        }

        fn setAudio(context: *anyopaque, chosen: Own.Audio) void {
            const recorder = from(context);
            recorder.audio = chosen;
            recorder.given += 1;
        }

        fn getDisplay(context: *anyopaque) Own.Display {
            return from(context).display;
        }

        fn setDisplay(context: *anyopaque, chosen: Own.Display.Chosen) void {
            const recorder = from(context);
            recorder.display.chosen = chosen;
            recorder.given += 1;
        }

        fn getGraphics(context: *anyopaque) Own.Graphics {
            return from(context).graphics;
        }

        fn setGraphics(context: *anyopaque, chosen: Own.Graphics.Chosen) void {
            const recorder = from(context);
            recorder.graphics.chosen = chosen;
            recorder.given += 1;
        }
    };
};

test leavingMovie {
    try std.testing.expectEqualStrings("interface\\optfade2.bik", leavingMovie(.game_options, .back).?);
    try std.testing.expectEqualStrings("interface\\igof2mm.bik", leavingMovie(.in_game_options, .main_menu).?);
    try std.testing.expectEqual(null, leavingMovie(.pause_menu, .back));
    try std.testing.expectEqual(null, opening(.pause_menu, .controls));
    try std.testing.expectEqualStrings("interface\\igoptfad.tga", opening(.in_game_options, .audio).?.background);
}

test Settings {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var devices: input.Devices = .{};
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var screen: Settings = .{};
    const at = struct {
        fn context(on: *input.Devices, settings_file: *profile.File, x: i32, y: i32, down: bool) Context {
            return .{ .pointer = .{ .at = .{ x, y }, .down = down }, .devices = on, .settings_file = settings_file, .ticks = 0 };
        }
    }.context;
    screen.enter(.pause_menu, .controls, at(&devices, &file, 0, 0, false));
    // The pointer over OK lights it; a click leaves, the bindings, unchanged, left as the file has
    // them.
    try std.testing.expectEqual(null, screen.frame(at(&devices, &file, 250, 430, false)));
    try std.testing.expectEqual(Button.ok, screen.lit.?);
    try std.testing.expectEqual(End.back, screen.frame(at(&devices, &file, 250, 430, true)).?);
    try std.testing.expectEqual(null, file.profile.value("KeyConfig", "COCKPIT CAMERA"));
    // In the pause menu, the second button continues the mission.
    screen.enter(.pause_menu, .controls, at(&devices, &file, 0, 0, false));
    try std.testing.expectEqual(End.continue_mission, screen.frame(at(&devices, &file, 250, 450, true)).?);
    // A row waiting with nothing taken gets its binding back as the screen is left (a fix).
    screen.enter(.game_options, .controls, at(&devices, &file, 0, 0, false));
    try std.testing.expectEqual(null, screen.frame(at(&devices, &file, 100, 143, true)));
    try std.testing.expectEqual(0, devices.bindings.get(.cockpit_camera).key);
    _ = screen.frame(at(&devices, &file, 250, 450, false));
    try std.testing.expectEqual(End.main_menu, screen.frame(at(&devices, &file, 250, 450, true)).?);
    try std.testing.expectEqual(2, devices.bindings.get(.cockpit_camera).key);
    // The press that chose stays spent until it comes up: held over the first row, it doesn't
    // choose it again, nor end the wait.
    screen.enter(.game_options, .controls, at(&devices, &file, 0, 0, false));
    _ = screen.frame(at(&devices, &file, 100, 143, true));
    _ = screen.frame(at(&devices, &file, 10, 10, true));
    try std.testing.expect(screen.controls.waiting != null);
    // A key taken counts as a change, which Escape asks about once the wait is over, the first
    // Escape ending it; NO reads the file again.
    devices.keyboard.down[@intFromEnum(input.Key.f9)] = true;
    _ = screen.frame(at(&devices, &file, 10, 10, false));
    try std.testing.expectEqual(@intFromEnum(input.Key.f9), devices.bindings.get(.cockpit_camera).key);
    devices.keyboard.down[@intFromEnum(input.Key.f9)] = false;
    devices.keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, screen.frame(at(&devices, &file, 10, 10, false)));
    try std.testing.expect(screen.controls.waiting == null and screen.question == null);
    devices.keyboard.latched[input.scan.escape] = false;
    try std.testing.expectEqual(null, screen.frame(at(&devices, &file, 10, 10, false)));
    try std.testing.expect(screen.question != null);
    _ = screen.frame(at(&devices, &file, 340, 275, true));
    try std.testing.expectEqual(End.back, screen.frame(at(&devices, &file, 340, 275, false)).?);
    try std.testing.expectEqual(2, devices.bindings.get(.cockpit_camera).key);
}

test "the tabs' labels switch the tab" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var devices: input.Devices = .{};
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var screen: Settings = .{};
    const context: Context = .{ .pointer = .{}, .devices = &devices, .settings_file = &file, .ticks = 0 };
    screen.enter(.game_options, .controls, context);
    // A row waits; AUDIO's label, clicked, shows the audio, the wait over.
    var clicked = context;
    clicked.pointer = .{ .at = .{ 100, 143 }, .down = true };
    _ = screen.frame(clicked);
    try std.testing.expect(screen.controls.waiting != null);
    clicked.pointer = .{ .at = .{ 133, 100 } };
    _ = screen.frame(clicked);
    try std.testing.expectEqual(Tab.audio, screen.lit_tab.?);
    clicked.pointer.down = true;
    _ = screen.frame(clicked);
    try std.testing.expectEqual(Tab.audio, screen.tab);
    try std.testing.expectEqual(null, screen.controls.waiting);
    try std.testing.expectEqual(input.controls.binding(.cockpit_camera).key, devices.bindings.get(.cockpit_camera).key);
}

test {
    _ = audio;
    _ = controls;
    _ = video;
    _ = graphics;
    _ = widgets;
}
