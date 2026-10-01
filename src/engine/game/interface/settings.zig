//! OpenReliant's settings screen (`Settings`), which stands in for the original's settings screens
//! wherever they open: GAME OPTIONS' and the in-game options' AUDIO, CONTROL DEVICES and VIDEO
//! (screens 3, 16 and 15 of the front end), and the pause menu's. It is laid out as the original's
//! are, on the front end's screen with their shapes (`shapes_name`), with a tab for each in place
//! of their titles, and their buttons: OK and MAIN MENU, or CONTINUE in the pause menu, RESET
//! DEFAULTS and CANCEL CHANGES, which act on the tab shown.
//!
//! The tabs: the audio ([`settings/audio.zig`](settings/audio.zig)), the controls
//! ([`settings/controls.zig`](settings/controls.zig)), the video
//! ([`settings/video.zig`](settings/video.zig)), and OpenReliant's graphics options
//! ([`settings/graphics.zig`](settings/graphics.zig)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const profile = @import("../../profile.zig");
const device = @import("../../surrender/srd3d/device.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const camera = @import("../camera.zig");
const guns = @import("../guns.zig");
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
    graphics,

    /// Its label, the one the menus' icon for it has, and GRAPHICS, OpenReliant's word, where the
    /// game's screens write their titles (`0x0042CDA9`), spread across the screen.
    fn label(tab: Tab) Label {
        return switch (tab) {
            .audio => .of(0x109, .{ 80, title_y }, .centre),
            .controls => .of(0x10A, .{ 245, title_y }, .centre),
            .video => .of(0x10B, .{ 410, title_y }, .centre),
            .graphics => .{ .text = .{ .words = "GRAPHICS" }, .at = .{ 555, title_y }, .alignment = .centre },
        };
    }

    /// Where the pointer finds it: round its label, as wide as it is.
    fn rect(tab: Tab) Rect {
        const half_width: i16 = switch (tab) {
            .audio, .video => 40,
            .graphics => 55,
            .controls => 80,
        };
        const centre: i16 = @intCast(tab.label().at[0]);
        return .{ .x = centre - half_width, .y = title_y - tab_above, .width = 2 * half_width, .height = tab_height };
    }
};

/// The labels' row, and where the pointer finds a label: from a little above it, as high as the
/// large font's letters.
const title_y = 95;
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
            .audio, .video, .graphics => "interface\\igoptfad.tga",
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
            /// Samples a pixel, for smooth edges: 1, 2, 4 or 8.
            samples: u8 = 4,
        };

        pub const Told = struct {
            /// The window's own size, which a share of it is of.
            window: [2]u32 = canvas_module.size,
            /// The display's refresh rate, where it is known.
            refresh_rate: ?f32 = null,
            /// The most samples a pixel the GPU draws with.
            most_samples: u8 = 8,
        };
    };

    /// The graphics' options: what the screen chooses, and what the game runs with of those that
    /// take effect at the next start, which choosing leaves as it is.
    pub const Graphics = struct {
        chosen: Chosen = .{},
        running: Running = .{},

        pub const Chosen = struct {
            pixel_lighting: bool = true,
            linear_light: bool = true,
            /// Whether the material maps of a mod's textures are shaded.
            materials: bool = true,
            shadows: Shadows = .high,
            cockpit_shadows: bool = true,
            shot_lights: guns.ShotLights = .every_shot,
            bloom: bool = true,
            dither: bool = true,
            filter: Filter = .crisp,
            sixteen_bit: bool = false,
            smooth_motion: bool = true,
        };

        pub const Running = struct {
            linear_light: bool = true,
            sixteen_bit: bool = false,
        };

        pub const Shadows = enum { off, low, high };
        pub const Filter = enum { original, trilinear, crisp };
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

/// An arrow, which steps a choice back or on.
pub const Step = enum { back, on };

/// The choice a step from the one at `at` of `count`, round from the last to the first; from one
/// not among them, on to the first or back to the last.
pub fn steppedIndex(at: ?usize, count: usize, step: Step) usize {
    return switch (step) {
        .on => if (at) |index| (index + 1) % count else 0,
        .back => if (at) |index| (index + count - 1) % count else count - 1,
    };
}

/// The choice of `E` a step from `current`, in its order, round from the last to the first.
pub fn steppedChoice(comptime E: type, current: E, step: Step) E {
    const choices = comptime std.enums.values(E);
    return choices[steppedIndex(std.mem.indexOfScalar(E, choices, current), choices.len, step)];
}

/// A row of the video's and the graphics' tabs, as the game's video screen lays one out
/// (`video_screen_draw`, `0x0042F440`): its label to the left of x 280; an arrows' box, shape
/// `0x2E`, a pixel above it at x 301 (`0x0042F903` on), whose halves the pointer finds 12 by 23 from
/// x 301 and 318 (`video_items`, `0x004E76F0`) and which light under the pointer with `0x2F` and
/// `0x30` (`0x0042FD3D` on), or a check box two pixels below it at x 311 (`0x0042FC89` on); and its
/// value from x 352 (`0x0042F744` on).
pub const Line = struct {
    /// Where its label's text stands, from the top.
    y: i32,

    const label_x = 280;
    const value_x = 352;
    const arrows_shape = 0x2E;
    const arrows_x = 301;
    const arrow_on_x = 318;
    const arrows_raise = 1;
    const arrow_size: [2]i16 = .{ 12, 23 };
    const box_x = 311;
    const box_drop = 2;

    pub fn label(line: Line, text: Label.Text) Label {
        return .{ .text = text, .at = .{ label_x, line.y }, .alignment = .right };
    }

    pub fn value(line: Line, text: Label.Text) Label {
        return .{ .text = text, .at = .{ value_x, line.y } };
    }

    /// Where the pointer finds its arrow `step`.
    pub fn arrow(line: Line, step: Step) Rect {
        const x: i16 = switch (step) {
            .back => arrows_x,
            .on => arrow_on_x,
        };
        return .{ .x = x, .y = @intCast(line.y - arrows_raise), .width = arrow_size[0], .height = arrow_size[1] };
    }

    /// Where its check box stands.
    pub fn box(line: Line) [2]i32 {
        return .{ box_x, line.y + box_drop };
    }

    /// Where the pointer finds its check box.
    pub fn boxRect(line: Line) Rect {
        const corner = line.box();
        return .{ .x = @intCast(corner[0]), .y = @intCast(corner[1]), .width = Box.size, .height = Box.size };
    }

    pub fn drawArrows(line: Line, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        try canvas.shape(art, arrows_shape, .{ arrows_x, line.y - arrows_raise });
    }

    /// Its arrow `step` lit, as under the pointer.
    pub fn drawLit(line: Line, canvas: Canvas, art: *hud.Art, step: Step) canvas_module.Error!void {
        const rect = line.arrow(step);
        const shape: usize = switch (step) {
            .back => 0x2F,
            .on => 0x30,
        };
        try canvas.shape(art, shape, .{ rect.x, rect.y });
    }
};

/// A check box or a radio button of the screen's shapes: the box, shape `0x1A`, and the tick in the
/// one set, `0x1B`, three pixels in (`0x0042D75E` on, `0x0042D96C` on).
pub const Box = struct {
    /// Its size, where the pointer finds it.
    pub const size = 16;
    const shape = 0x1A;
    const tick = 0x1B;
    const tick_offset = 3;

    pub fn draw(canvas: Canvas, art: *hud.Art, at: [2]i32, ticked: bool) canvas_module.Error!void {
        try canvas.shape(art, shape, at);
        if (ticked) try canvas.shape(art, tick, .{ at[0] + tick_offset, at[1] + tick_offset });
    }
};

/// A slider of the screen's shapes, as the audio's volumes and the video's brightness have it: a
/// knob, shape `0x2C`, 15 by 27, which slides `travel` to the right of where it starts, and a
/// track, shape `0x2D`, 10 below the knob's top, every 45 from where the knob starts until `end`
/// (`0x0042E5E3` on, `0x0042FA39` on). The pointer holds the knob 4 pixels to the right of its left
/// edge (`0x0042DEB3`, `0x0042EB27`).
pub const Slider = struct {
    /// Where the knob's corner stands at the slider's start.
    from: [2]i32,
    /// Where the track's marks end.
    end: i32,

    pub const travel = 175;
    const knob_shape = 0x2C;
    const track_shape = 0x2D;
    const knob_size: [2]i16 = .{ 15, 27 };
    const track_drop = 10;
    const track_step = 45;
    const grip = 4;

    /// The knob `along` its travel from the start, where the pointer finds it.
    pub fn knob(slider: Slider, along: i32) Rect {
        return .{ .x = @intCast(slider.from[0] + along), .y = @intCast(slider.from[1]), .width = knob_size[0], .height = knob_size[1] };
    }

    /// How far along its travel the knob held stands, for the pointer at `x`.
    pub fn held(slider: Slider, x: i32) i32 {
        return std.math.clamp(x - grip - slider.from[0], 0, travel);
    }

    pub fn drawTrack(slider: Slider, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        var x = slider.from[0];
        while (x < slider.end) : (x += track_step) try canvas.shape(art, track_shape, .{ x, slider.from[1] + track_drop });
    }

    pub fn drawKnob(slider: Slider, canvas: Canvas, art: *hud.Art, along: i32) canvas_module.Error!void {
        const rect = slider.knob(along);
        try canvas.shape(art, knob_shape, .{ rect.x, rect.y });
    }
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
    fn rect(button: Button) Rect {
        return switch (button) {
            .ok => .{ .x = 199, .y = 422, .width = 120, .height = 15 },
            .leave => .{ .x = 199, .y = 443, .width = 120, .height = 15 },
            .reset_defaults => .{ .x = 329, .y = 422, .width = 100, .height = 15 },
            .cancel_changes => .{ .x = 329, .y = 443, .width = 100, .height = 15 },
        };
    }

    fn shown(button: Button, from: From) canvas_module.Button {
        return switch (button) {
            .ok => .{ .at = .{ 299, 422 }, .label = .of(0x316, .{ 292, 421 }, .right) },
            .leave => .{ .at = .{ 299, 443 }, .label = .of(if (from == .pause_menu) continue_string else main_menu_string, .{ 292, 442 }, .right) },
            .reset_defaults => .{ .at = .{ 329, 422 }, .label = .of(0x183, .{ 357, 421 }, .left) },
            .cancel_changes => .{ .at = .{ 329, 443 }, .label = .of(0x5A9, .{ 357, 442 }, .left) },
        };
    }
};

const main_menu_string = 0xBB;
const continue_string = 0x180;

/// The buttons' shapes, and lit under the pointer (`0x0042D109`, `0x0042D709`).
const button_shapes: canvas_module.Button.Pair = .{ .off = 0x28, .lit = 0x29 };

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
    graphics: graphics.Item,
};

/// The screen's state.
pub const Settings = struct {
    from: From = .game_options,
    tab: Tab = .controls,
    audio: audio.Audio = .{},
    controls: controls.Controls = .{},
    video: video.Video = .{},
    graphics: graphics.Graphics = .{},
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
        screen.graphics.enter(context);
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
    /// changed; the audio's knobs, the keys and the wheel that scroll the controls' list, and the
    /// video's knob; then the item under the pointer, chosen as the pointer's button goes down, and
    /// lit while it is up; then the waiting row's keys and buttons.
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
        screen.video.arrow = null;
        screen.graphics.arrow = null;
        bindings.arrow = null;
        switch (screen.tab) {
            .audio => screen.audio.slide(context),
            .controls => bindings.scrollKeys(context),
            .video => screen.video.slide(context),
            .graphics => {},
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
                .graphics => |item| screen.graphics.hover(item),
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
                        .graphics => screen.graphics.reset(context),
                    },
                    .cancel_changes => switch (screen.tab) {
                        .audio => screen.audio.cancel(context),
                        .controls => bindings.cancel(devices),
                        .video => try screen.video.cancel(context),
                        .graphics => screen.graphics.cancel(context),
                    },
                },
                .audio => |item| screen.audio.choose(item, context),
                .video => |item| try screen.video.choose(item, context),
                .graphics => |item| screen.graphics.choose(item, context),
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
            .video => .{ .video = video.itemAt(context, at) orelse return null },
            .graphics => .{ .graphics = graphics.itemAt(at) orelse return null },
        };
    }

    /// The screen's drawing (`controls_screen_draw`, `0x0042CD30`, `audio_screen_draw`,
    /// `0x0042E2E0`, `video_screen_draw`, `0x0042F440`): the tabs' labels, the shown one white and one under the pointer gold, the
    /// tab, the buttons, the one under the pointer lit, Escape's question where it is up,
    /// OpenReliant's version, then the pointer.
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
            .graphics => try screen.graphics.draw(canvas, art),
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
    // The pointer over OK lights it; a click leaves, the bindings written.
    try std.testing.expectEqual(null, screen.frame(at(&devices, &file, 250, 430, false)));
    try std.testing.expectEqual(Button.ok, screen.lit.?);
    try std.testing.expectEqual(End.back, screen.frame(at(&devices, &file, 250, 430, true)).?);
    try std.testing.expectEqualStrings("2", file.profile.value("KeyConfig", "COCKPIT CAMERA").?);
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
    clicked.pointer = .{ .at = .{ 80, 100 } };
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
}
