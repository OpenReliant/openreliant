//! The settings screen's video (`Video`): the original's graphics configuration, screen 15 of the
//! front end (`video_screen`, `0x0042E9B0`), with its drawing (`video_screen_draw`, `0x0042F440`),
//! and OpenReliant's graphics options. At the top, GRAPHICS and its presets, with the graphics
//! options in a pane below it (`graphics.Graphics`); below that, rows laid out as the original's
//! are: RESOLUTION, DEFAULT VIEW and BRIGHTNESS, and FRAME RATE LIMIT, with the check boxes FULL
//! SCREEN, VSYNC and VR TRANSITIONS left of them, where the controls have their controllers. DEFAULT
//! VIEW and VR TRANSITIONS change at once, and are written at once; the brightness changes the
//! device's gamma ramp at once, and is written as the screen is left (`save`).
//!
//! **Improvement:** RESOLUTION chooses the size OpenReliant draws its frames at, a share of the
//! window's own, where the game's chooses the display's mode. FULL SCREEN, VSYNC and FRAME RATE
//! LIMIT are OpenReliant's own. They change at once, as the driver applies them (`settings.Own`).
//!
//! Not ported: 3D RENDER MODE, which chooses the game's Direct3D device; and TEXTURE DETAIL, GRAPHIC
//! DETAIL and LIGHT MAPS, at whose highest OpenReliant draws
//! ([#493](https://github.com/vdmkenny/openreliant/issues/493)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../../input.zig");
const profile = @import("../../../profile.zig");
const srapi = @import("../../../surrender/surrenderlib/srapi.zig");
const FrameSize = @import("../../../surrender/srd3d/device.zig").FrameSize;
const camera = @import("../../camera.zig");
const CockpitSetting = camera.CockpitSetting;
const hud = @import("../../hud.zig");
const canvas_module = @import("../canvas.zig");
const Canvas = canvas_module.Canvas;
const Label = canvas_module.Label;
const settings = @import("../settings.zig");
const Context = settings.Context;
const Display = settings.Own.Display;
const graphics = @import("graphics.zig");
const widgets = @import("widgets.zig");
const Slider = widgets.Slider;
const Step = widgets.Step;
const Line = widgets.Line;
const Toggle = widgets.Toggle;
const steppedIndex = widgets.steppedIndex;

/// `[Device]`, where the video settings are kept (`0x004E8628`), and the keys the screen writes:
/// the view (`0x004E8630`), the brightness (`0x004E8614`) and the transitions (`0x004E861C`).
pub const section = "Device";
pub const view_key = "View";
pub const gamma_key = "gamma";
pub const transitions_key = "Transitions";
/// The file keeps the brightness in hundredths (`0x004DC440`).
pub const gamma_scale = 100;

/// The rows below the graphics, from the top, laid out as the game's are (`widgets.Line`), with
/// the graphics' columns and spacing: the game's RESOLUTION, DEFAULT VIEW and BRIGHTNESS, in the
/// game's order, with OpenReliant's FRAME RATE LIMIT after RESOLUTION.
pub const Row = enum {
    resolution,
    frame_rate,
    default_view,
    brightness,

    fn line(row: Row) Line {
        return .{ .y = first_row + @as(i32, @intFromEnum(row)) * graphics.row_spacing, .edge = graphics.edge };
    }

    fn text(row: Row) Label.Text {
        return switch (row) {
            .resolution => .{ .string = 0x10E },
            .frame_rate => .{ .words = "FRAME RATE LIMIT" },
            .default_view => .{ .string = 0x28A },
            .brightness => .{ .string = 0x113 },
        };
    }
};

/// The first row's arrows' box stands a gap below the graphics' pane.
const first_row = graphics.pane_bottom + graphics.gap + 1;

/// The rows an arrow box steps through their choices.
pub const Choice = enum {
    resolution,
    frame_rate,
    default_view,

    fn row(choice: Choice) Row {
        return switch (choice) {
            inline else => |named| @field(Row, @tagName(named)),
        };
    }
};

/// An arrow of a row's box.
pub const Arrow = struct { choice: Choice, step: Step };

/// The check boxes, left of the rows, where the controls have their controllers: FULL SCREEN beside
/// RESOLUTION, VSYNC beside FRAME RATE LIMIT, and the game's VR TRANSITIONS beside DEFAULT VIEW.
pub const Check = enum {
    fullscreen,
    vsync,
    transitions,

    fn row(check: Check) Row {
        return switch (check) {
            .fullscreen => .resolution,
            .vsync => .frame_rate,
            .transitions => .default_view,
        };
    }

    /// Its box and its label.
    fn box(check: Check) Toggle {
        return .{ .at = .{ toggles_x, check.row().line().y } };
    }

    fn words(check: Check) Label.Text {
        return switch (check) {
            .fullscreen => .{ .words = "FULL SCREEN" },
            .vsync => .{ .words = "VSYNC" },
            .transitions => .{ .string = 0x2D4 },
        };
    }
};

/// Where the check boxes stand across: where the controls have their controllers' (`0x0042D9F8`).
const toggles_x = 45;

/// The brightness's slider, as the game places it beside its row (`0x0042FA39` on): its knob from
/// x 347 at the least brightness to 175 further at the most (`0x004E7778`, where the pointer finds
/// it), its track until 572, moved as far right as the tab's rows are.
const brightness_slider: Slider = .{
    .from = .{ 347 + rows_moved, Row.brightness.line().y },
    .end = 572 + rows_moved,
};

/// How far right of the game's the tab's rows stand (`graphics.edge`).
const rows_moved = graphics.edge - Line.original_edge;
/// The brightness's range (`0x004DC408`, `0x004DC480`).
const least_brightness: f32 = 0.5;
const most_brightness: f32 = 2;

comptime {
    // The rows stand below the graphics' pane, and the knob above the buttons.
    std.debug.assert(Row.resolution.line().arrow(.back).y > graphics.pane_bottom);
    std.debug.assert(brightness_slider.knob(0).y + brightness_slider.knob(0).height < settings.Button.ok.rect().y);
}

/// The brightness of the knob `along` its travel.
///
/// **Improvement:** it is the knob's place over its travel, exactly, where the game multiplies by
/// its rounded reciprocal (`0x004DC6A4`).
fn brightnessAt(along: i32) f32 {
    const share = @as(f32, @floatFromInt(along)) / Slider.travel;
    return least_brightness + share * (most_brightness - least_brightness);
}

/// How far along its travel the knob of `brightness` stands, rounded to a whole pixel, as the game
/// rounds it (`0x0042EABE`), within the travel.
fn knobAlong(brightness: f32) i32 {
    const share = (brightness - least_brightness) / (most_brightness - least_brightness);
    return std.math.clamp(hud.round(share * Slider.travel), 0, Slider.travel);
}

/// What RESET DEFAULTS sets: the game's defaults for the view and the transitions (`0x004E5C08`,
/// `0x004E5C0C`), and the brightness of `[Device] Gamma`'s default, 100 (`0x0042EEFE`).
const default_view: CockpitSetting = .cockpit;
const default_transitions = true;
const default_brightness: f32 = 1;

/// DEFAULT VIEW's value (`0x0042F8A6`): COCKPIT VIEW, CHASE VIEW or NO COCKPIT VIEW. A setting the
/// game doesn't know shows the last.
fn viewName(setting: CockpitSetting) u32 {
    return switch (setting) {
        .cockpit => 0x28B,
        .chase => 0x28C,
        else => 0x57F,
    };
}

/// The setting a step from `setting` (`0x0042EDFC`, `0x0042EE53`): on past the last to the first,
/// and back before the first to the last. Each looks only at the end it goes toward, so a setting
/// the game doesn't know goes back by one.
fn stepped(setting: CockpitSetting, step: Step) CockpitSetting {
    const last: i64 = std.enums.values(CockpitSetting).len - 1;
    const number: i64 = @intFromEnum(setting);
    return switch (step) {
        .on => if (number + 1 > last) @enumFromInt(0) else @enumFromInt(number + 1),
        .back => if (number - 1 < 0) @enumFromInt(last) else @enumFromInt(number - 1),
    };
}

/// The shares of the window's own size RESOLUTION steps through, from the window's own. Those that
/// come to fewer rows than the front end's screen has, 480, are left out.
const shares = [_]u8{ 100, 75, 50, 25 };

/// The frames' size a step from `display`'s, through the shares the window offers.
fn steppedSize(display: Display, step: Step) FrameSize {
    var offered: [shares.len]u8 = undefined;
    var count: usize = 0;
    for (shares) |share| {
        const rows = (FrameSize{ .share = share }).of(display.told.window)[1];
        if (share == 100 or rows >= canvas_module.size[1]) {
            offered[count] = share;
            count += 1;
        }
    }
    const at: ?usize = switch (display.chosen.size) {
        .share => |share| std.mem.indexOfScalar(u8, offered[0..count], share),
        .pixels => null,
    };
    return .{ .share = offered[steppedIndex(at, count, step)] };
}

/// RESOLUTION's value: the frames' size in pixels, as the game writes the display's mode
/// (`0x004E8638`), and NATIVE before the window's own.
fn sizeText(display: Display, buffer: []u8) []const u8 {
    const pixels = display.chosen.size.of(display.told.window);
    const native = std.meta.eql(display.chosen.size, FrameSize.window);
    const written = if (native)
        std.fmt.bufPrint(buffer, "NATIVE ({d}x{d})", .{ pixels[0], pixels[1] })
    else
        std.fmt.bufPrint(buffer, "{d}x{d}", .{ pixels[0], pixels[1] });
    return written catch "";
}

/// The limits FRAME RATE LIMIT steps through: the display's rate, a few rates displays run at, and
/// none.
const frame_rates = [_]?f32{ null, 30, 60, 120, 144, 240, 0 };

fn steppedRate(rate: ?f32, step: Step) ?f32 {
    const at = for (frame_rates, 0..) |listed, index| {
        if (std.meta.eql(listed, rate)) break index;
    } else null;
    return frame_rates[steppedIndex(at, frame_rates.len, step)];
}

/// FRAME RATE LIMIT's value: DISPLAY, with the display's rate where it is known; NONE; or the rate.
fn rateText(rate: ?f32, refresh_rate: ?f32, buffer: []u8) []const u8 {
    const limit = rate orelse {
        const display_rate = refresh_rate orelse return "DISPLAY";
        return std.fmt.bufPrint(buffer, "DISPLAY ({d})", .{hud.round(display_rate)}) catch "DISPLAY";
    };
    if (limit == 0) return "NONE";
    return std.fmt.bufPrint(buffer, "{d}", .{hud.round(limit)}) catch "";
}

/// What the pointer finds on the tab.
pub const Item = union(enum) {
    arrow: Arrow,
    check: Check,
    /// The brightness's knob.
    knob,
    graphics: graphics.Item,
};

/// Sets the options' cockpit setting, and the camera's cockpit mode the setting stands for, as the
/// pause menu's video screen sets them (`pause_screen_video`, `0x0048F260`); a mission's start sets
/// the mode so anyway. A setting that changes is written to `[Device]` (`0x0042EE3F`).
fn setView(video: settings.Video, setting: CockpitSetting, file: *profile.File) Allocator.Error!void {
    const view = video.camera;
    view.cockpit_mode = setting.mode();
    if (view.setting == setting) return;
    view.setting = setting;
    try file.writeInt(section, view_key, @intFromEnum(setting));
}

/// Turns the transitions on or off; a change is written to `[Device]` (`0x0042EFC9` on).
fn setTransitions(video: settings.Video, on: bool, file: *profile.File) Allocator.Error!void {
    if (video.transitions.* == on) return;
    video.transitions.* = on;
    try file.writeInt(section, transitions_key, @intFromBool(on));
}

/// The tab's state, which the game keeps on `video_screen`'s stack and in globals.
pub const Video = struct {
    /// The settings as the screen opened, which CANCEL CHANGES puts back (`0x0042EA41` on).
    kept: Kept = .{},
    /// OpenReliant's display options as the driver has them, read again each pass.
    display: Display = .{},
    /// Whether the pointer holds the brightness's knob (`options_held`, `0x005202B0`).
    held: bool = false,
    /// The arrow under the pointer, lit.
    arrow: ?Arrow = null,
    /// OpenReliant's graphics options.
    graphics: graphics.Graphics = .{},

    const Kept = struct {
        view: CockpitSetting = default_view,
        brightness: f32 = default_brightness,
        transitions: bool = default_transitions,
        display: Display.Chosen = .{},
    };

    /// `video_screen`'s start: what CANCEL CHANGES puts back kept.
    pub fn enter(tab: *Video, context: Context) void {
        const display: Display = if (context.own) |own| own.display() else .{};
        tab.* = .{ .display = display, .kept = .{ .display = display.chosen } };
        tab.graphics.enter(context);
        const video = context.video orelse return;
        tab.kept.view = video.camera.setting;
        tab.kept.brightness = video.surrender.brightness;
        tab.kept.transitions = video.transitions.*;
    }

    /// The item the pointer is over: the graphics', an arrow, a check box, or the brightness's
    /// knob, where the device has a gamma ramp.
    pub fn itemAt(tab: Video, context: Context, at: [2]i32) ?Item {
        if (tab.graphics.itemAt(at)) |item| return .{ .graphics = item };
        for (std.enums.values(Choice)) |choice| {
            if (choice.row().line().arrowAt(at)) |step| return .{ .arrow = .{ .choice = choice, .step = step } };
        }
        for (std.enums.values(Check)) |check| if (check.box().rect().holds(at)) return .{ .check = check };
        const video = context.video orelse return null;
        if (video.gamma and brightness_slider.knob(knobAlong(video.surrender.brightness)).holds(at)) return .knob;
        return null;
    }

    /// Nothing lit, as each pass starts.
    pub fn unlight(tab: *Video) void {
        tab.arrow = null;
        tab.graphics.lit = null;
        tab.graphics.lit_preset = null;
    }

    /// The pointer over `item` with its button up: an arrow lights.
    pub fn hover(tab: *Video, item: Item) void {
        switch (item) {
            .arrow => |arrow| tab.arrow = arrow,
            .graphics => |on_graphics| tab.graphics.hover(on_graphics),
            .check, .knob => {},
        }
    }

    /// A pass's knob, where the device has a gamma ramp (`0x0042EB15` on): the knob held follows
    /// the pointer, and the brightness changes with it at once; while the pointer's button is
    /// down, the knob under it is held. And OpenReliant's display options as they stand, which
    /// Alt and Enter and the window's size change too, and the keys and the wheel that scroll the
    /// graphics.
    pub fn slide(tab: *Video, context: Context) void {
        if (context.own) |own| tab.display = own.display();
        tab.graphics.scroll(context);
        const video = context.video orelse return;
        if (!video.gamma) return;
        if (tab.held) video.surrender.brightness = brightnessAt(brightness_slider.held(context.pointer.at[0]));
        tab.held = context.pointer.down and brightness_slider.knob(knobAlong(video.surrender.brightness)).holds(context.pointer.at);
    }

    /// A click on `item` (`0x0042EC50`): an arrow steps its row's choice back or on, round from the
    /// last to the first; a check box turns its setting on or off. The view and the transitions are
    /// written at once, and OpenReliant's options applied. The graphics' arrows that scroll their
    /// pane scroll again while held, which it returns true for.
    pub fn choose(tab: *Video, item: Item, context: Context) Allocator.Error!bool {
        const chosen = &tab.display.chosen;
        switch (item) {
            .knob => {},
            .graphics => |on_graphics| return tab.graphics.choose(on_graphics, context),
            .arrow => |arrow| switch (arrow.choice) {
                .resolution => {
                    chosen.size = steppedSize(tab.display, arrow.step);
                    tab.applyDisplay(context);
                },
                .frame_rate => {
                    chosen.frame_rate = steppedRate(chosen.frame_rate, arrow.step);
                    tab.applyDisplay(context);
                },
                .default_view => if (context.video) |video| {
                    try setView(video, stepped(video.camera.setting, arrow.step), context.settings_file);
                },
            },
            .check => |check| switch (check) {
                .fullscreen => {
                    chosen.fullscreen = !chosen.fullscreen;
                    tab.applyDisplay(context);
                },
                .vsync => {
                    chosen.vsync = !chosen.vsync;
                    tab.applyDisplay(context);
                },
                .transitions => if (context.video) |video| {
                    try setTransitions(video, !video.transitions.*, context.settings_file);
                },
            },
        }
        return false;
    }

    fn applyDisplay(tab: *Video, context: Context) void {
        if (context.own) |own| own.setDisplay(tab.display.chosen);
    }

    /// RESET DEFAULTS (`0x0042EEAA`): the view from the cockpit, the transitions on, and the
    /// brightness 1 where the device has a gamma ramp; and OpenReliant's display options and
    /// graphics options at theirs.
    ///
    /// **Fix:** the game shows the view and the transitions reset, but takes the view for itself
    /// only as OK or MAIN MENU start its renderer again, which they do only where the mode or the
    /// detail has changed too, and the transitions never, and writes neither. OpenReliant sets
    /// them, and writes them at once.
    ///
    /// **Fix:** the game puts the brightness's knob in the middle of its track, which is 1.25,
    /// where it means 1, the file's 100 it sets beside it.
    pub fn reset(tab: *Video, context: Context) Allocator.Error!void {
        if (context.video) |video| {
            try setView(video, default_view, context.settings_file);
            try setTransitions(video, default_transitions, context.settings_file);
            if (video.gamma) video.surrender.brightness = default_brightness;
        }
        tab.display.chosen = .{};
        tab.applyDisplay(context);
        tab.graphics.reset(context);
    }

    /// CANCEL CHANGES (`0x0042F015`): the settings as the screen opened, the brightness where the
    /// device has a gamma ramp.
    ///
    /// **Fix:** the game shows the view and the transitions it opened with, but keeps for itself,
    /// and in the file, those chosen since, which it set and wrote as they were chosen. OpenReliant
    /// puts them back, and writes them.
    pub fn cancel(tab: *Video, context: Context) Allocator.Error!void {
        if (context.video) |video| {
            try setView(video, tab.kept.view, context.settings_file);
            try setTransitions(video, tab.kept.transitions, context.settings_file);
            if (video.gamma) video.surrender.brightness = tab.kept.brightness;
        }
        tab.display.chosen = tab.kept.display;
        tab.applyDisplay(context);
        tab.graphics.cancel(context);
    }

    /// As the screen is left, by Escape, OK or MAIN MENU (`0x0042F2B3`, `0x0042F0AF`): the
    /// brightness written to `[Device]` in hundredths, whether the device has a gamma ramp or not.
    pub fn save(_: Video, context: Context) Allocator.Error!void {
        const video = context.video orelse return;
        try context.settings_file.writeInt(section, gamma_key, hud.round(video.surrender.brightness * gamma_scale));
    }

    /// The graphics, then `video_screen_draw`'s part (`0x0042F440`): the rows with their arrows
    /// and values, the check boxes, BRIGHTNESS's label, track and knob only where the device has a
    /// gamma ramp, and the arrow under the pointer lit.
    pub fn draw(tab: Video, canvas: Canvas, art: *hud.Art, shown: ?settings.Video) canvas_module.Error!void {
        try tab.graphics.draw(canvas, art);
        const told = tab.display.told;
        const chosen = tab.display.chosen;
        var buffer: [40]u8 = undefined;
        for (std.enums.values(Choice)) |choice| {
            const value: Label.Text = switch (choice) {
                .resolution => .{ .words = sizeText(tab.display, &buffer) },
                .frame_rate => .{ .words = rateText(chosen.frame_rate, told.refresh_rate, &buffer) },
                .default_view => .{ .string = viewName(if (shown) |video| video.camera.setting else default_view) },
            };
            try choice.row().line().draw(canvas, art, .{ .label = choice.row().text(), .control = .{ .choice = value } });
        }
        for (std.enums.values(Check)) |check| {
            const on = switch (check) {
                .fullscreen => chosen.fullscreen,
                .vsync => chosen.vsync,
                .transitions => if (shown) |video| video.transitions.* else default_transitions,
            };
            try check.box().draw(canvas, art, check.words(), on, true);
        }
        if (shown) |video| if (video.gamma) {
            const brightness = Row.brightness.line();
            try brightness.label(Row.brightness.text()).write(canvas, canvas.fonts.small, canvas_module.blue);
            try brightness_slider.drawTrack(canvas, art);
            try brightness_slider.drawKnob(canvas, art, knobAlong(video.surrender.brightness));
        };
        if (tab.arrow) |arrow| try arrow.choice.row().line().drawLit(canvas, art, arrow.step);
    }
};

/// The game's video settings, for the tests: a camera, Surrender's state, and the transitions.
const GameVideo = struct {
    view: camera.Camera = .{},
    surrender: srapi.Context = .{ .projection = undefined },
    transitions: bool = true,

    fn video(kept: *GameVideo, gamma: bool) settings.Video {
        return .{ .camera = &kept.view, .surrender = &kept.surrender, .gamma = gamma, .transitions = &kept.transitions };
    }
};

test "the rows stand below the graphics" {
    try std.testing.expectEqual(292, Row.resolution.line().y);
    try std.testing.expectEqual(352, Row.default_view.line().y);
    try std.testing.expectEqual(382, Row.brightness.line().y);
    try std.testing.expectEqual([2]i32{ 45, 352 }, Check.transitions.box().at);
}

test "the brightness's knob" {
    // From x 347 at 0.5 to 522 at 2; 1 stands a third of the way.
    try std.testing.expectEqual(0, knobAlong(0.5));
    try std.testing.expectEqual(Slider.travel, knobAlong(2));
    try std.testing.expectEqual(58, knobAlong(1));
    try std.testing.expectEqual(Slider.travel, knobAlong(3));
    try std.testing.expectEqual(2, brightnessAt(Slider.travel));
    try std.testing.expectApproxEqAbs(1.25, brightnessAt(87), 0.01);
}

test stepped {
    try std.testing.expectEqual(CockpitSetting.chase, stepped(.cockpit, .on));
    try std.testing.expectEqual(CockpitSetting.none, stepped(.cockpit, .back));
    try std.testing.expectEqual(CockpitSetting.cockpit, stepped(.none, .on));
    // A setting the game doesn't know goes on to the first, and back by one.
    try std.testing.expectEqual(CockpitSetting.cockpit, stepped(@enumFromInt(4), .on));
    try std.testing.expectEqual(@as(CockpitSetting, @enumFromInt(4)), stepped(@enumFromInt(5), .back));
}

test steppedSize {
    // A 2560 by 1440 window offers its own size, 75% and 50%; 25%, 360 rows, is too few.
    var display: Display = .{ .told = .{ .window = .{ 2560, 1440 } } };
    display.chosen.size = steppedSize(display, .on);
    try std.testing.expectEqual(FrameSize{ .share = 75 }, display.chosen.size);
    display.chosen.size = steppedSize(display, .on);
    display.chosen.size = steppedSize(display, .on);
    try std.testing.expectEqual(FrameSize.window, display.chosen.size);
    try std.testing.expectEqual(FrameSize{ .share = 50 }, steppedSize(display, .back));
    // A size of its own goes on to the window's.
    display.chosen.size = .{ .pixels = .{ 800, 600 } };
    try std.testing.expectEqual(FrameSize.window, steppedSize(display, .on));
    // A window too small for any share offers only its own.
    display = .{ .told = .{ .window = .{ 640, 480 } } };
    try std.testing.expectEqual(FrameSize.window, steppedSize(display, .on));
    var buffer: [40]u8 = undefined;
    try std.testing.expectEqualStrings("NATIVE (640x480)", sizeText(display, &buffer));
    display = .{ .chosen = .{ .size = .{ .share = 50 } }, .told = .{ .window = .{ 2560, 1440 } } };
    try std.testing.expectEqualStrings("1280x720", sizeText(display, &buffer));
}

test "the frame rate's steps" {
    // The display's rate, the listed rates, then none, round again; a rate not listed goes on to
    // the display's.
    try std.testing.expectEqual(30, steppedRate(null, .on).?);
    try std.testing.expectEqual(0, steppedRate(null, .back).?);
    try std.testing.expectEqual(null, steppedRate(0, .on));
    try std.testing.expectEqual(null, steppedRate(50, .on));
    var buffer: [40]u8 = undefined;
    try std.testing.expectEqualStrings("DISPLAY (120)", rateText(null, 119.88, &buffer));
    try std.testing.expectEqualStrings("DISPLAY", rateText(null, null, &buffer));
    try std.testing.expectEqualStrings("NONE", rateText(0, 60, &buffer));
    try std.testing.expectEqualStrings("144", rateText(144, 60, &buffer));
}

test "the arrows and the boxes change the video" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var devices: input.Devices = .{};
    var recorder: settings.testing.Recorder = .{ .display = .{ .told = .{ .window = .{ 1920, 1080 } } } };
    var kept: GameVideo = .{};
    const context: Context = .{ .pointer = .{}, .devices = &devices, .settings_file = &file, .ticks = 0, .own = recorder.own(), .video = kept.video(true) };
    var tab: Video = .{};
    tab.enter(context);
    // DEFAULT VIEW's arrow on, found at its row, changes the view and its mode, written at once.
    const view_on = tab.itemAt(context, .{ 342, 357 }).?;
    try std.testing.expectEqual(Item{ .arrow = .{ .choice = .default_view, .step = .on } }, view_on);
    _ = try tab.choose(view_on, context);
    try std.testing.expectEqual(CockpitSetting.chase, kept.view.setting);
    try std.testing.expectEqual(camera.CockpitMode.chase, kept.view.cockpit_mode);
    try std.testing.expectEqualStrings("1", file.profile.value(section, view_key).?);
    // VR TRANSITIONS' box, left of it, turns them off, written at once.
    const transitions = tab.itemAt(context, .{ 50, 358 }).?;
    try std.testing.expectEqual(Item{ .check = .transitions }, transitions);
    _ = try tab.choose(transitions, context);
    try std.testing.expect(!kept.transitions);
    try std.testing.expectEqualStrings("0", file.profile.value(section, transitions_key).?);
    // OpenReliant's options go to the driver.
    _ = try tab.choose(.{ .arrow = .{ .choice = .resolution, .step = .on } }, context);
    try std.testing.expectEqual(FrameSize{ .share = 75 }, recorder.display.chosen.size);
    _ = try tab.choose(.{ .check = .fullscreen }, context);
    _ = try tab.choose(.{ .check = .vsync }, context);
    _ = try tab.choose(.{ .arrow = .{ .choice = .frame_rate, .step = .on } }, context);
    try std.testing.expectEqual(Display.Chosen{ .size = .{ .share = 75 }, .fullscreen = true, .vsync = false, .frame_rate = 30 }, recorder.display.chosen);
    // GRAPHICS' arrows, above, set the original's look.
    const original = tab.itemAt(context, .{ 342, 127 }).?;
    try std.testing.expectEqual(Item{ .graphics = .{ .preset = .on } }, original);
    _ = try tab.choose(original, context);
    try std.testing.expect(recorder.graphics.chosen.original);
    // CANCEL CHANGES puts all back, and writes the game's again.
    try tab.cancel(context);
    try std.testing.expectEqual(CockpitSetting.cockpit, kept.view.setting);
    try std.testing.expect(kept.transitions);
    try std.testing.expectEqualStrings("1", file.profile.value(section, transitions_key).?);
    try std.testing.expectEqual(Display.Chosen{}, recorder.display.chosen);
    try std.testing.expect(!recorder.graphics.chosen.original);
}

test "the brightness's knob is dragged, and written as the screen is left" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    var devices: input.Devices = .{};
    var kept: GameVideo = .{};
    var context: Context = .{ .pointer = .{}, .devices = &devices, .settings_file = &file, .ticks = 0, .video = kept.video(true) };
    var tab: Video = .{};
    tab.enter(context);
    // At 1, the knob stands from x 425, on BRIGHTNESS's row: held as the button goes down on it, it
    // follows the pointer from the next pass.
    try std.testing.expectEqual(Item.knob, tab.itemAt(context, .{ 430, 393 }).?);
    context.pointer = .{ .at = .{ 430, 393 }, .down = true };
    tab.slide(context);
    try std.testing.expect(tab.held);
    context.pointer.at = .{ 620, 393 };
    tab.slide(context);
    try std.testing.expectEqual(2, kept.surrender.brightness);
    // Let go, held no more; RESET DEFAULTS sets 1 again, and leaving writes it.
    context.pointer.down = false;
    tab.slide(context);
    try std.testing.expect(!tab.held);
    try tab.reset(context);
    try std.testing.expectEqual(1, kept.surrender.brightness);
    try tab.save(context);
    try std.testing.expectEqualStrings("100", file.profile.value(section, gamma_key).?);
    // Without a gamma ramp, there is no knob, and the brightness stays.
    context.video = kept.video(false);
    kept.surrender.brightness = 1.5;
    try std.testing.expectEqual(null, tab.itemAt(context, .{ 430, 393 }));
    try tab.reset(context);
    try std.testing.expectEqual(1.5, kept.surrender.brightness);
}
