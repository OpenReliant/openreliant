//! OpenReliant's settings screen (`Settings`), which stands in for the original's settings screens
//! wherever they open: GAME OPTIONS' and the in-game options' AUDIO, CONTROL DEVICES and VIDEO
//! (screens 3, 16 and 15 of the front end), and the pause menu's. It is laid out as the original's
//! are, on the front end's screen with their shapes (`shapes_name`), with a tab for each in place
//! of their titles, and their buttons: OK and MAIN MENU, or CONTINUE in the pause menu, RESET
//! DEFAULTS and CANCEL CHANGES, which act on the tab shown.
//!
//! Ported so far: the controls ([`settings/controls.zig`](settings/controls.zig)). Not yet: the
//! audio and the video, with OpenReliant's own options
//! ([#206](https://github.com/vdmkenny/openreliant/issues/206),
//! [#209](https://github.com/vdmkenny/openreliant/issues/209)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../input.zig");
const profile = @import("../../profile.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const dialog = @import("dialog.zig");

pub const controls = @import("settings/controls.zig");

const log = std.log.scoped(.interface);

/// The shapes the screen draws with (`controls_screen`, `0x0042BA5C`).
pub const shapes_name = "interface\\frntend6.spr";

/// The tabs, in the order the strip shows them.
pub const Tab = enum {
    controls,

    /// Its label, the one the menus' icon for it has, CONTROL DEVICES, where the game's screen
    /// writes its title (`0x0042CDA9`).
    fn label(tab: Tab) Label {
        return switch (tab) {
            .controls => .of(0x10A, .{ 320, 95 }, .centre),
        };
    }
};

/// The menu the screen opened from, which its second button and its movies follow.
pub const From = enum { game_options, in_game_options, pause_menu };

/// How the screen ends: OK, or Escape, back to the menu it opened from; MAIN MENU to the main menu;
/// CONTINUE back to the mission.
pub const End = enum { back, main_menu, continue_mission };

/// The movie that leads into the screen from `from` on `tab`, and the background it shows: the one
/// GAME OPTIONS plays as an icon is chosen, which fades the icons out of its picture (`0x0042A7C9`),
/// and the in-game options' (`0x00439770`). The pause menu has neither: the screen stands over the
/// mission.
pub fn opening(from: From, tab: Tab) ?struct { movie: []const u8, background: []const u8 } {
    return switch (from) {
        .game_options => .{ .movie = "interface\\optfade.bik", .background = "interface\\optfade.tga" },
        .in_game_options => .{ .movie = "interface\\igofade.bik", .background = switch (tab) {
            .controls => "interface\\igofade.tga",
        } },
        .pause_menu => null,
    };
}

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
};

/// What the pointer finds: a button, or an item of the tab.
const Item = union(enum) {
    button: Button,
    controls: controls.Item,
};

/// The screen's state.
pub const Settings = struct {
    from: From = .game_options,
    tab: Tab = .controls,
    controls: controls.Controls = .{},
    /// The button under the pointer, lit (`0x0051DB44`).
    lit: ?Button = null,
    /// Whether the press that chose an item is still down, which chooses nothing more until it
    /// comes up (`0x0042BB37`).
    held: bool = false,
    /// Escape's question, while it is up.
    question: ?dialog.Confirm = null,

    /// Opens the screen from `from` on `tab`.
    pub fn enter(screen: *Settings, from: From, tab: Tab, context: Context) void {
        screen.* = .{ .from = from, .tab = tab };
        screen.controls.enter(context);
    }

    /// A pass of the screen's loop (`controls_screen`, `0x0042BB08` on); how it ends, once it
    /// does. What it can't write to the settings file is logged.
    pub fn frame(screen: *Settings, context: Context) ?End {
        return screen.pass(context) catch |err| {
            log.warn("the settings are not kept: {s}", .{@errorName(err)});
            return null;
        };
    }

    /// The joystick read, as the screen's loop reads it (`0x0042BB17`); the questions up and the
    /// button taken take the pass. Then Escape, which asks first where a binding has changed, then
    /// the item under the pointer, chosen as the pointer's button goes down, and lit while it is
    /// up; then the keys and the wheel that scroll the list, and the waiting row's keys and
    /// buttons.
    ///
    /// **Improvement:** Escape while a row waits only ends the wait, the old binding back where it
    /// took nothing; the game leaves the screen.
    fn pass(screen: *Settings, context: Context) Allocator.Error!?End {
        const devices = context.devices;
        const tab = &screen.controls;
        devices.joystick.read();
        const escaped = devices.keyboard.pressed(input.scan.escape, .none, true);
        if (screen.question) |*question| {
            const answer = question.frame(context.pointer, escaped) orelse return null;
            screen.question = null;
            if (!answer) tab.reload(devices, context.settings_file.profile);
            return try screen.leave(.back, context);
        }
        if (tab.busy(context, escaped)) return null;
        if (escaped) {
            if (tab.waiting != null) {
                tab.endWait(devices);
                return null;
            }
            if (tab.changed) {
                screen.question = .{ .message = .{ .string = save_question } };
                return null;
            }
            return try screen.leave(.back, context);
        }
        var pointer = context.pointer;
        if (pointer.down and screen.held) pointer.down = false else screen.held = false;
        screen.lit = null;
        tab.arrow = null;
        tab.scrollKeys(context);
        const under = itemAt(pointer.at) orelse {
            if (pointer.down) tab.endWait(devices);
            tab.wait(context);
            return null;
        };
        if (!pointer.down) {
            switch (under) {
                .button => |button| screen.lit = button,
                .controls => |item| tab.hover(item),
            }
        } else {
            screen.held = true;
            switch (under) {
                .button => |button| switch (button) {
                    .ok => return try screen.leave(.back, context),
                    .leave => return try screen.leave(if (screen.from == .pause_menu) .continue_mission else .main_menu, context),
                    .reset_defaults => try tab.reset(devices, context.settings_file),
                    .cancel_changes => tab.cancel(devices),
                },
                .controls => |item| if (try tab.choose(item, context)) {
                    screen.held = false;
                },
            }
        }
        tab.wait(context);
        return null;
    }

    /// Leaves by `end`, the settings written (`save_key_config`).
    ///
    /// **Fix:** leaving puts back the binding of a row waiting with nothing taken, where the game
    /// writes the action unbound.
    fn leave(screen: *Settings, end: End, context: Context) Allocator.Error!End {
        screen.controls.endWait(context.devices);
        try screen.controls.save(context.devices, context.settings_file);
        return end;
    }

    fn itemAt(at: [2]i32) ?Item {
        for (std.enums.values(Button)) |button| if (button.rect().holds(at)) return .{ .button = button };
        const item = controls.Controls.itemAt(at) orelse return null;
        return .{ .controls = item };
    }

    /// The screen's drawing (`controls_screen_draw`, `0x0042CD30`): the tabs' labels, the shown
    /// one white, the tab, the buttons, the one under the pointer lit, Escape's question where it
    /// is up, OpenReliant's version, then the pointer.
    pub fn draw(screen: Settings, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, devices: *const input.Devices, pointer: Pointer) canvas_module.Error!void {
        for (std.enums.values(Tab)) |tab| try tab.label().write(canvas, canvas.fonts.large, if (tab == screen.tab) canvas_module.white else canvas_module.blue);
        for (std.enums.values(Button)) |button| try button.shown(screen.from).draw(canvas, art, button_shapes, screen.lit == button);
        try screen.controls.draw(canvas, art, dialog_art, devices);
        if (screen.question) |question| try question.draw(canvas, dialog_art);
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
    }
};

test leavingMovie {
    try std.testing.expectEqualStrings("interface\\optfade2.bik", leavingMovie(.game_options, .back).?);
    try std.testing.expectEqualStrings("interface\\igof2mm.bik", leavingMovie(.in_game_options, .main_menu).?);
    try std.testing.expectEqual(null, leavingMovie(.pause_menu, .back));
    try std.testing.expectEqual(null, opening(.pause_menu, .controls));
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

test {
    _ = controls;
}
