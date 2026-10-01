//! The settings screen's controls (`Controls`): the original's control configuration, screen 16 of
//! the front end (`controls_screen`, `0x0042B690`), with its drawing (`controls_screen_draw`,
//! `0x0042CD30`), laid out where the original lays it out on the front end's screen. It changes the
//! input settings and the bindings in `input.Devices`: a setting is written to `starlancer.ini` the
//! moment it changes, as the game writes it, and the bindings as the screen is left (`save`).
//!
//! The list holds `controls_list`'s 80 rows (`controls.list`), 12 at a time: an action's name and
//! its binding, or a divider. A click on an action's row clears its binding and waits for a key or a
//! joystick button (`Waiting`); a key or a button another action holds asks first (`Conflict`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../../../input.zig");
const controls = input.controls;
const Action = controls.Action;
const Binding = controls.Binding;
const Modifier = input.ControlBinding.Modifier;
const profile = @import("../../../profile.zig");
const hud = @import("../../hud.zig");
const language = @import("../../language.zig");
const interface = @import("../../interface.zig");
const canvas_module = @import("../canvas.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Label = canvas_module.Label;
const Arrow = canvas_module.Arrow;
const dialog = @import("../dialog.zig");
const settings = @import("../settings.zig");
const Context = settings.Context;
const Box = settings.Box;

/// The rows the list shows at once (`0x0042B665`, `0x0042D177`).
pub const rows = 12;

/// The ticks a held arrow waits before the list scrolls another row (`0x0042BD2C`).
const scroll_ticks = 5;

/// The two panes, the actions' and their bindings', framed (`interface_box`, `0x0042CD72`,
/// `0x0042CD90`).
const panes = [_]struct { at: [2]i32, extent: [2]i32 }{
    .{ .at = .{ 45, 136 }, .extent = .{ 324, 184 } },
    .{ .at = .{ 401, 136 }, .extent = .{ 195, 184 } },
};

/// The panes' headings, FUNCTION and CONTROL, in the large font (`0x0042CFC0`, `0x0042CFEC`), and
/// PRIMARY CONTROLLER, over the controllers (`0x0042CDD6`).
const headings = [_]Label{
    .of(0x17B, .{ 50, 117 }, .left),
    .of(0x17C, .{ 405, 117 }, .left),
};
const primary_controller: Label = .of(0x234, .{ 45, 327 }, .left);

/// Where the list's rows stand: a row's name and its binding, the first row's height, and the
/// height from row to row (`0x0042D19D`, `0x0042D202`, `0x0042D35A`); and where a click finds a row
/// (`0x0042B78B` on).
const name_x = 50;
const binding_x = 406;
const first_row_y = 139;
const row_height = 15;
const row_width = 550;
const row_hit_height = 10;

/// A divider's two lines, one above the other, across each pane (`0x0042D421` on).
const divider_spans = [_][2]i32{ .{ 45, 367 }, .{ 401, 594 } };

/// The colour of "! NOT ASSIGNED !" (`0x0042D381`).
const yellow = hud.rgb(0xFFFF00);

/// The strings the list and the conflict's question are written with: SHIFT and CONTROL before a
/// key, AND before a button, JOY and its number, and the empty binding's ! NOT ASSIGNED !
/// (`0x0042D22A`, `0x0042D255`, `0x0042D2AC`, `0x0042D2E9`, `0x0042D38B`); CONTROL as the question
/// writes it (`0x0042C0BC`), This Key is already assigned to and Redefine Anyway? (`0x0042C143`).
const shift_string = 0x311;
const control_string = 0x312;
const and_string = 0x545;
const joy_string = 0x32C;
const not_assigned = 0x5B1;
const question_control_string = 0x17C;
const assigned_string = 0x5AF;
const anyway_string = 0x5B0;

/// What a row waiting with nothing taken shows: the game's PRESS, which its training's prompts
/// write (`0x5AE`).
const press_string = 0x5AE;

/// The list's arrows, and their shapes, lit under the pointer (`0x0042D8CA` on): one at the top
/// right of the actions' pane, the other below it.
const arrow_rects = std.EnumArray(Arrow, Rect).init(.{
    .up = .{ .x = 370, .y = 136, .width = 28, .height = 16 },
    .down = .{ .x = 370, .y = 156, .width = 28, .height = 16 },
});
const arrow_x = 374;
const arrow_shapes = std.EnumArray(Arrow, struct { off: usize, lit: usize, y: i32 }).init(.{
    .up = .{ .off = 0x1E, .lit = 0x20, .y = 136 },
    .down = .{ .off = 0x1F, .lit = 0x21, .y = 156 },
});

/// The check boxes, top to bottom: their box at x 349, their label at x 367.
pub const Check = enum {
    force_feedback,
    invert_pitch,
    hat_enable,
    joystick_roll,

    const box_x = 349;
    const label_x = 367;
    /// Where the pointer finds a box: from 4 pixels left of it (`0x0042B70D` on).
    const hit_x = 345;

    /// Its row (`0x0042B70D` on).
    fn y(check: Check) i32 {
        return switch (check) {
            .force_feedback => 325,
            .invert_pitch => 349,
            .hat_enable => 373,
            .joystick_roll => 397,
        };
    }

    fn label(check: Check) Label {
        const string: u32 = switch (check) {
            .force_feedback => 0x17D,
            .invert_pitch => 0x17E,
            .hat_enable => 0x17F,
            .joystick_roll => 0x233,
        };
        return .of(string, .{ label_x, check.y() }, .left);
    }

    /// The setting it changes.
    fn setting(check: Check) interface.Setting {
        return switch (check) {
            .force_feedback => .force_feedback,
            .invert_pitch => .joystick_invert,
            .hat_enable => .hat_enable,
            .joystick_roll => .twist_enable,
        };
    }

    /// Whether it can be changed, else it is dimmed: FORCE FEEDBACK from a joystick that has it,
    /// steering; HAT ENABLE and JOYSTICK ROLL while the joystick steers (`0x0042BBB4`,
    /// `0x0042BC4F`, `0x0042BE79`), but JOYSTICK ROLL not for a gamepad, whose right stick always
    /// rolls (`input.Devices.twistRolls`).
    fn usable(check: Check, devices: *const input.Devices) bool {
        const steering = devices.controlMode() == .joystick;
        return switch (check) {
            .force_feedback => devices.joystick.rumbles and steering,
            .invert_pitch => true,
            .hat_enable => steering,
            .joystick_roll => steering and devices.joystick.kind != .gamepad,
        };
    }

    /// Whether it is ticked: where it can be changed, and its setting is on (`0x0042D96C` on).
    /// INVERT PITCH is ticked while pitch is as the stick has it, `JoystickInvert` 1; and JOYSTICK
    /// ROLL while the twist rolls and the joystick steers, a gamepad's dimmed.
    fn ticked(check: Check, devices: *const input.Devices) bool {
        const kept = devices.settings;
        return switch (check) {
            .force_feedback => kept.force_feedback and check.usable(devices),
            .invert_pitch => kept.joystick_invert,
            .hat_enable => kept.hat_enabled and check.usable(devices),
            .joystick_roll => devices.twistRolls() and devices.controlMode() == .joystick,
        };
    }

    fn toggle(check: Check, kept: *input.Settings) void {
        switch (check) {
            .force_feedback => kept.force_feedback = !kept.force_feedback,
            .invert_pitch => kept.joystick_invert = !kept.joystick_invert,
            .hat_enable => kept.hat_enabled = !kept.hat_enabled,
            .joystick_roll => kept.twist_enabled = !kept.twist_enabled,
        }
    }

    fn rect(check: Check) Rect {
        return .{ .x = hit_x, .y = @intCast(check.y()), .width = Box.size, .height = Box.size };
    }
};

/// PRIMARY CONTROLLER's choices, top to bottom: their box at x 45, their label at x 67.
///
/// **Improvement:** MOUSE, which steers by the mouse (`Controller` 2). The game has its case
/// (`0x0042BF15`) and its string, but neither a place nor a label, so only the file sets it.
pub const Controller = enum {
    joystick,
    mouse,
    keyboard,

    const box_x = 45;
    const label_x = 67;

    fn y(controller: Controller) i32 {
        return switch (controller) {
            .joystick => 349,
            .mouse => 373,
            .keyboard => 397,
        };
    }

    fn string(controller: Controller) u32 {
        return switch (controller) {
            .joystick => 0x235,
            .mouse => 0x236,
            .keyboard => 0x237,
        };
    }

    fn label(controller: Controller) Label {
        return .of(controller.string(), .{ label_x, controller.y() }, .left);
    }

    /// How far JOYSTICK's label reaches at most: `margin` short of the check boxes.
    const room = Check.box_x - margin - label_x;
    const margin = 8;

    fn mode(controller: Controller) input.ControlMode {
        return switch (controller) {
            .joystick => .joystick,
            .mouse => .mouse,
            .keyboard => .keyboard,
        };
    }

    /// Whether it can be chosen, else it is dimmed: JOYSTICK with a joystick (`0x0042BECF`).
    fn usable(controller: Controller, devices: *const input.Devices) bool {
        return controller != .joystick or devices.joystick.device != null;
    }

    fn rect(controller: Controller) Rect {
        return .{ .x = box_x, .y = @intCast(controller.y()), .width = Box.size, .height = Box.size };
    }
};

/// What the pointer finds on the tab: a check box, an arrow, a row of the list, from the top, or a
/// controller.
pub const Item = union(enum) {
    check: Check,
    arrow: Arrow,
    row: u8,
    controller: Controller,
};

/// The items, in the order of the table `interface_hit` reads (`0x0042B69A` on), which settles
/// where two overlap: the arrows over the first two rows. The game's table also holds the screen's
/// buttons (`settings.Button`), and three empty places, one of them MOUSE's.
const items = items: {
    var placed: [3 + 2 + rows + 1 + 3]struct { rect: Rect, item: Item } = undefined;
    var at: usize = 0;
    for ([_]Check{ .force_feedback, .invert_pitch, .hat_enable }) |check| {
        placed[at] = .{ .rect = check.rect(), .item = .{ .check = check } };
        at += 1;
    }
    for (std.enums.values(Arrow)) |arrow| {
        placed[at] = .{ .rect = arrow_rects.get(arrow), .item = .{ .arrow = arrow } };
        at += 1;
    }
    for (0..rows) |row| {
        placed[at] = .{ .rect = rowRect(row), .item = .{ .row = row } };
        at += 1;
    }
    placed[at] = .{ .rect = Check.joystick_roll.rect(), .item = .{ .check = .joystick_roll } };
    at += 1;
    for (std.enums.values(Controller)) |controller| {
        placed[at] = .{ .rect = controller.rect(), .item = .{ .controller = controller } };
        at += 1;
    }
    if (at != placed.len) @compileError("every item placed once");
    break :items placed;
};

fn rowRect(row: usize) Rect {
    return .{ .x = name_x, .y = @intCast(first_row_y + @as(i32, @intCast(row)) * row_height), .width = row_width, .height = row_hit_height };
}

/// The modifiers a key is taken with as a row waits, in the order they are tried: none, Shift and
/// Ctrl (`0x0042C072` on). Alt is never taken.
const taken_modifiers = [_]Modifier{ .none, .shift, .control };

/// A row waiting for a key or a button: its action, and its binding as the wait began, which a
/// wait ended with nothing taken puts back.
const Waiting = struct {
    action: Action,
    old: Binding,
};

/// What a waiting row has taken that another action holds: a key of `controls.keys`, by its place
/// there, with its modifier, or a joystick button.
const Taken = union(enum) {
    key: struct { index: u8, modifier: Modifier },
    button: u8,
};

/// The question a key or a button another action holds asks (`interface_confirm(-1)`,
/// `0x0042C1D4`, `0x0042C42B`): its words are put together as it is drawn (`question`).
const Conflict = struct {
    taken: Taken,
    holder: Action,
    question: dialog.Confirm = .{ .message = .{ .words = "" } },
};

/// The tab's state, which the game keeps in globals and on `controls_screen`'s stack.
pub const Controls = struct {
    /// The input settings and the bindings as the screen opened (`0x0042BA7F` on), which CANCEL
    /// CHANGES puts back.
    kept: struct { settings: input.Settings, bindings: input.Bindings } = .{ .settings = .{}, .bindings = input.defaultBindings(.joystick) },
    /// The list: the 80 rows of `controls_list`, 12 shown from the first (`0x00520234`).
    list: canvas_module.Scrolled(u8) = .{ .count = controls.list.len, .shown = rows },
    /// The tick a held arrow next scrolls the list after.
    scroll_at: u32 = 0,
    /// The row waiting for a key or a button (`0x0051D528`).
    waiting: ?Waiting = null,
    /// Whether a binding has changed since the screen opened or its changes were cancelled, which
    /// Escape asks about (`0x0042C211`, `0x0042C378`).
    changed: bool = false,
    /// The question a key or a button another action holds asks, while it is up.
    conflict: ?Conflict = null,
    /// The joystick button taken, which the tab waits to see come up (`0x0042C380`).
    button_down: ?u8 = null,
    /// The arrow under the pointer, lit (`0x0051DA04`).
    arrow: ?Arrow = null,

    /// `controls_screen`'s start (`0x0042BA75` on): the bindings read again from `starlancer.ini`,
    /// kept for CANCEL CHANGES, and the list at its top.
    pub fn enter(tab: *Controls, context: Context) void {
        const devices = context.devices;
        interface.loadKeyConfig(devices, context.settings_file.profile);
        tab.* = .{
            .kept = .{ .settings = devices.settings, .bindings = devices.bindings },
            .scroll_at = context.ticks,
        };
    }

    /// Whether the conflict's question or a button taken holds the frame: the question answered,
    /// YES gives the waiting row what it took, from the action that held it, and NO puts its old
    /// binding back, the row waiting on (`0x0042C1F2`, `0x0042C284`, `0x0042C34D` on); and a button
    /// taken holds the screen until it comes up.
    pub fn busy(tab: *Controls, context: Context, escaped: bool) bool {
        const devices = context.devices;
        if (tab.conflict) |*asking| {
            const answer = asking.question.frame(context.pointer, escaped) orelse return true;
            const conflict = asking.*;
            tab.conflict = null;
            const waiting = tab.waiting orelse return true;
            const binding = devices.bindings.getPtr(waiting.action);
            if (!answer) {
                binding.* = waiting.old;
                return true;
            }
            const holder = devices.bindings.getPtr(conflict.holder);
            switch (conflict.taken) {
                .key => |key| {
                    binding.key = controls.keys[key.index].code;
                    binding.modifier = key.modifier;
                    holder.key = 0;
                    holder.modifier = .none;
                },
                .button => |button| {
                    binding.button = button;
                    holder.button = null;
                },
            }
            tab.changed = true;
            return true;
        }
        const button = tab.button_down orelse return false;
        if (devices.joystick.down(button)) return true;
        tab.button_down = null;
        return false;
    }

    /// The item the pointer is over.
    pub fn itemAt(at: [2]i32) ?Item {
        for (items) |placed| if (placed.rect.holds(at)) return placed.item;
        return null;
    }

    /// The pointer over `item` with its button up: an arrow lights (`0x0042BFB8`).
    pub fn hover(tab: *Controls, item: Item) void {
        switch (item) {
            .arrow => |arrow| tab.arrow = arrow,
            .check, .row, .controller => {},
        }
    }

    /// A click on `item` (`0x0042BBAD`): a check box that can be changed changes, and its setting
    /// is written; an arrow scrolls the list a row, and again each `scroll_ticks` while it is held,
    /// which it returns true for; a row puts the waiting row's old binding back where it took
    /// nothing, and an action's row clears its binding and waits in its place, where a divider
    /// leaves the waiting row waiting; a controller that can be chosen steers, and is written.
    pub fn choose(tab: *Controls, item: Item, context: Context) Allocator.Error!bool {
        const devices = context.devices;
        const settings_file = context.settings_file;
        switch (item) {
            .check => |check| if (check.usable(devices)) {
                check.toggle(&devices.settings);
                try interface.saveSetting(devices.settings, settings_file, check.setting());
            },
            .arrow => |arrow| {
                tab.scrollHeld(arrow, context.ticks);
                return true;
            },
            .row => |row| {
                tab.restore(devices);
                const action = controls.list[tab.list.first + row] orelse return false;
                const binding = devices.bindings.getPtr(action);
                tab.waiting = .{ .action = action, .old = binding.* };
                binding.key = 0;
                binding.button = null;
                binding.modifier = .none;
            },
            .controller => |controller| if (controller.usable(devices)) {
                devices.settings.control_mode = controller.mode();
                try interface.saveSetting(devices.settings, settings_file, .controller);
            },
        }
        return false;
    }

    /// The list a row on or back, as an arrow held scrolls it: at once, then each `scroll_ticks`
    /// while it is held (`0x0042BD09`).
    fn scrollHeld(tab: *Controls, way: Arrow, ticks: u32) void {
        if (ticks <= tab.scroll_at) return;
        tab.list.scroll(way);
        tab.scroll_at = ticks + scroll_ticks;
    }

    /// Up and Down, held while no row waits, which then binds them, scroll the list as its arrows
    /// do, and the mouse's wheel scrolls it as it turns.
    ///
    /// **Improvement:** the game's screen scrolls by its arrows alone.
    pub fn scrollKeys(tab: *Controls, context: Context) void {
        tab.list.wheel(context.pointer.wheel);
        if (tab.waiting != null) return;
        const keyboard = &context.devices.keyboard;
        if (keyboard.pressed(@intFromEnum(input.Key.up), .none, false)) tab.scrollHeld(.up, context.ticks);
        if (keyboard.pressed(@intFromEnum(input.Key.down), .none, false)) tab.scrollHeld(.down, context.ticks);
    }

    /// Ends the wait, as a click on nothing does (`0x0042BFDE`), the waiting row's old binding back
    /// where it has taken nothing.
    pub fn endWait(tab: *Controls, devices: *input.Devices) void {
        tab.restore(devices);
        tab.waiting = null;
    }

    /// The waiting row's old binding back, where it has taken nothing: no key, button or modifier
    /// (`0x0042BD3C`).
    fn restore(tab: *Controls, devices: *input.Devices) void {
        const waiting = tab.waiting orelse return;
        const binding = devices.bindings.getPtr(waiting.action);
        if (binding.key == 0 and binding.button == null and binding.modifier == .none) binding.* = waiting.old;
    }

    /// A frame's wait, while a row waits (`0x0042C072` on): the first of `controls.keys` pressed
    /// alone, with Shift or with Ctrl, then the lowest joystick button down. Either is taken, and
    /// the row waits on, a later key in place of the first; one another action holds asks first
    /// (`Conflict`). A button taken holds the screen until it comes up.
    ///
    /// **Fix:** the game leaves out the action at the key's place in `key_names` as it looks for
    /// the key's holder (`0x0042C119`), so pressing again the key a row has just taken asks whether
    /// to take it from the row itself, and YES leaves the row without it. OpenReliant leaves out the
    /// waiting row's action.
    ///
    /// **Fix:** a key taken without a question counts as a change, which Escape asks about, as a
    /// button and a key taken from another action do.
    pub fn wait(tab: *Controls, context: Context) void {
        const waiting = tab.waiting orelse return;
        const devices = context.devices;
        const binding = devices.bindings.getPtr(waiting.action);
        keys: for (controls.keys, 0..) |key, index| {
            for (taken_modifiers) |modifier| {
                if (!devices.keyboard.pressed(key.code, modifier, true)) continue;
                if (interface.bindingFind(&devices.bindings, waiting.action, key.code, modifier)) |holder| {
                    tab.conflict = .{ .taken = .{ .key = .{ .index = @intCast(index), .modifier = modifier } }, .holder = holder };
                    return;
                }
                binding.key = key.code;
                binding.modifier = modifier;
                tab.changed = true;
                break :keys;
            }
        }
        const joystick = &devices.joystick;
        if (joystick.device == null) return;
        const button: u8 = for (0..joystick.buttons) |number| {
            if (joystick.down(@intCast(number))) break @intCast(number);
        } else return;
        tab.button_down = button;
        for (std.enums.values(Action)) |action| {
            if (action == waiting.action or devices.bindings.get(action).button != button) continue;
            tab.conflict = .{ .taken = .{ .button = button }, .holder = action };
            return;
        }
        binding.button = button;
        tab.changed = true;
    }

    /// CANCEL CHANGES (`0x0042BC9C`): the settings and the bindings as the screen opened.
    pub fn cancel(tab: *Controls, devices: *input.Devices) void {
        devices.settings = tab.kept.settings;
        devices.bindings = tab.kept.bindings;
        tab.changed = false;
    }

    /// RESET DEFAULTS (`0x0042BE6A`): the defaults, written at once.
    pub fn reset(_: *Controls, devices: *input.Devices, settings_file: *profile.File) Allocator.Error!void {
        interface.keyConfigDefaults(devices);
        try interface.saveKeyConfig(devices, settings_file);
    }

    /// Escape's question answered NO: the settings and the bindings read again from the file
    /// (`0x0042C4C8`).
    pub fn reload(_: *Controls, devices: *input.Devices, settings_file: profile.Profile) void {
        interface.loadKeyConfig(devices, settings_file);
    }

    /// As the screen is left: the settings and the bindings written (`save_key_config`,
    /// `0x0042C4CD`, `0x0042C517`, `0x0042C537`), where they are not what the file gives already.
    ///
    /// **Fix:** the game writes them all as its controls screen is left, and OpenReliant's one
    /// screen is left from any tab, so that a visit to another wrote the defaults of the controller
    /// attached, or of none, as though they had been chosen.
    pub fn save(_: *Controls, devices: *const input.Devices, settings_file: *profile.File) Allocator.Error!void {
        var filed: input.Devices = .{ .joystick = devices.joystick };
        interface.loadKeyConfig(&filed, settings_file.profile);
        if (std.meta.eql(filed.settings, devices.settings) and std.meta.eql(filed.bindings, devices.bindings)) return;
        try interface.saveKeyConfig(devices, settings_file);
    }

    /// `controls_screen_draw`'s part (`0x0042CD30`): the panes, the headings, the controllers' and
    /// the check boxes' labels, each dimmed where it can't be used, the list's rows, the boxes,
    /// the arrows, the one under the pointer lit, the ticks, and the conflict's question where it
    /// is up.
    pub fn draw(tab: Controls, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, devices: *const input.Devices) canvas_module.Error!void {
        const small = canvas.fonts.small;
        const blue = canvas_module.blue;
        for (panes) |pane| canvas.box(pane.at, pane.extent);
        for (headings) |heading| try heading.write(canvas, canvas.fonts.large, blue);
        try primary_controller.write(canvas, small, blue);
        for (std.enums.values(Controller)) |controller| {
            var label = controller.label();
            var buffer: [96]u8 = undefined;
            if (controller == .joystick) label.text = .{ .words = joystickLabel(&buffer, &devices.joystick, canvas.strings, small) };
            const shown = canvas.dimmedUnless(controller.usable(devices));
            try label.write(shown, small, blue);
            try Box.draw(shown, art, .{ Controller.box_x, controller.y() }, devices.controlMode() == controller.mode());
        }
        for (std.enums.values(Check)) |check| {
            const shown = canvas.dimmedUnless(check.usable(devices));
            try check.label().write(shown, small, blue);
            try Box.draw(shown, art, .{ Check.box_x, check.y() }, check.ticked(devices));
        }
        try tab.drawList(canvas, devices);
        for (std.enums.values(Arrow)) |arrow| {
            const shapes = arrow_shapes.get(arrow);
            try canvas.shape(art, shapes.off, .{ arrow_x, shapes.y });
            if (tab.arrow == arrow) try canvas.shape(art, shapes.lit, .{ arrow_x, shapes.y });
        }
        if (tab.conflict) |conflict| {
            var buffer: [256]u8 = undefined;
            var asked = conflict.question;
            asked.message = .{ .words = question(&buffer, conflict, canvas.strings, &devices.bindings) };
            try asked.draw(canvas, dialog_art);
        }
    }

    /// The rows shown (`0x0042D171` on): a divider's two lines, or an action's name and its
    /// binding, white while the row waits, and ! NOT ASSIGNED ! in yellow for an action bound to
    /// nothing, but the waiting one's.
    ///
    /// **Improvement:** a row waiting with nothing taken shows PRESS, where the game leaves it
    /// blank.
    fn drawList(tab: Controls, canvas: Canvas, devices: *const input.Devices) Allocator.Error!void {
        const small = canvas.fonts.small;
        for (tab.list.first..tab.list.end(), 0..) |entry, row| {
            const y = first_row_y + @as(i32, @intCast(row)) * row_height;
            const action = controls.list[entry] orelse {
                // Its two lines stand 6 and 7 below where a row's text starts.
                const line_y = y + 7;
                for (divider_spans) |span| {
                    canvas.line(.{ span[0], line_y - 1 }, .{ span[1], line_y - 1 }, canvas_module.blue);
                    canvas.line(.{ span[0], line_y }, .{ span[1], line_y }, canvas_module.blue);
                }
                continue;
            };
            const waiting = if (tab.waiting) |waits| waits.action == action else false;
            const colour = if (waiting) canvas_module.white else canvas_module.blue;
            const binding = devices.bindings.get(action);
            try canvas.string(small, .{ name_x, y }, binding.string, colour, .left);
            var buffer: [96]u8 = undefined;
            const shown = bindingText(&buffer, binding, canvas.strings);
            if (shown.len != 0) {
                try canvas.text(small, .{ binding_x, y }, shown, colour, .left);
            } else if (waiting) {
                try canvas.string(small, .{ binding_x, y }, press_string, colour, .left);
            } else {
                try canvas.string(small, .{ binding_x, y }, not_assigned, yellow, .left);
            }
        }
    }
};

/// JOYSTICK's label, followed by the joystick's name where there is one, in capitals, cut short
/// with "..." where it would reach the check boxes.
///
/// **Improvement:** the game writes JOYSTICK alone.
fn joystickLabel(buffer: []u8, joystick: *const input.Joystick, strings: *const language.Language, font: *hud.Opened) []const u8 {
    const label = strings.string(Controller.joystick.string()) orelse "";
    if (joystick.device == null) return label;
    var name_buffer: [64]u8 = undefined;
    const name = capitals(&name_buffer, joystick.name);
    if (name.len == 0) return label;
    var kept = name.len;
    while (true) : (kept -= 1) {
        const cut = if (kept < name.len) "..." else "";
        const shown = std.fmt.bufPrint(buffer, "{s} ({s}{s})", .{ label, name[0..kept], cut }) catch return label;
        if (kept == 0 or font.textWidth(shown) <= Controller.room) return shown;
    }
}

/// `text`, UTF-8, in capitals, in the game's code page (`language.fromUnicode`), as much of it as
/// `buffer` holds; empty where it isn't UTF-8.
fn capitals(buffer: []u8, text: []const u8) []const u8 {
    const view = std.unicode.Utf8View.init(text) catch return "";
    var points = view.iterator();
    var length: usize = 0;
    while (points.nextCodepoint()) |point| {
        if (length == buffer.len) break;
        buffer[length] = std.ascii.toUpper(language.fromUnicode(point));
        length += 1;
    }
    return buffer[0..length];
}

/// The name of the key of scan code `code`, as `key_names` gives it; null for none, and for a key
/// it doesn't name, which only a file written by hand can bind.
///
/// Not ported: `WinMain` renames the keys by the names the keyboard's layout gives them
/// (`0x004BCF70`), which the game shows
/// ([#489](https://github.com/vdmkenny/openreliant/issues/489)).
fn keyName(code: u16) ?[]const u8 {
    for (controls.keys) |key| if (key.code == code) return key.name;
    return null;
}

/// A binding as the list writes it (`0x0042D214` on): SHIFT + K, CONTROL + K or K, then AND JOY n
/// for a button, n as the file numbers it; empty for none. Alt isn't written. A key `key_names`
/// doesn't name is written by its scan code.
fn bindingText(buffer: []u8, binding: Binding, strings: *const language.Language) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var key: [8]u8 = undefined;
    const name = keyName(binding.key) orelse if (binding.key == 0) "" else std.fmt.bufPrint(&key, "{d}", .{binding.key}) catch "";
    const modifier: ?u32 = switch (binding.modifier) {
        .shift => shift_string,
        .control => control_string,
        else => null,
    };
    if (modifier) |id| {
        writer.print("{s} + {s}", .{ strings.string(id) orelse "", name }) catch {};
    } else {
        writer.writeAll(name) catch {};
    }
    if (binding.button) |button| {
        if (writer.end != 0) writer.writeAll(strings.string(and_string) orelse "") catch {};
        writer.print("{s} {d}", .{ strings.string(joy_string) orelse "", button }) catch {};
    }
    return writer.buffered();
}

/// The conflict's question (`0x0042C143` on, `0x0042C3E0` on): what was taken, in quotes, then
/// This Key is already assigned to, the action that holds it, and Redefine Anyway?, a line each.
fn question(buffer: []u8, conflict: Conflict, strings: *const language.Language, bindings: *const input.Bindings) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    switch (conflict.taken) {
        .key => |key| {
            const name = controls.keys[key.index].name;
            const modifier: ?u32 = switch (key.modifier) {
                .shift => shift_string,
                .control => question_control_string,
                else => null,
            };
            if (modifier) |id| {
                writer.print("\"{s} + {s}\"", .{ strings.string(id) orelse "", name }) catch {};
            } else {
                writer.print("\"{s}\"", .{name}) catch {};
            }
        },
        .button => |button| writer.print("\"{s} {d}\"", .{ strings.string(joy_string) orelse "", button }) catch {},
    }
    const holder = strings.string(bindings.get(conflict.holder).string) orelse "";
    writer.print("\n{s} {s}\n{s}", .{ strings.string(assigned_string) orelse "", holder, strings.string(anyway_string) orelse "" }) catch {};
    return writer.buffered();
}

/// What the tests run the tab with.
const Fixture = struct {
    devices: input.Devices = .{},
    arena: std.heap.ArenaAllocator,
    file: profile.File,
    tab: Controls = .{},
    ticks: u32 = 100,

    fn init() Fixture {
        return .{ .arena = .init(std.testing.allocator), .file = undefined };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.arena.deinit();
    }

    fn context(fixture: *Fixture, pointer: canvas_module.Pointer) Context {
        return .{ .pointer = pointer, .devices = &fixture.devices, .settings_file = &fixture.file, .ticks = fixture.ticks };
    }

    fn enter(fixture: *Fixture) void {
        fixture.file = .{ .arena = fixture.arena.allocator(), .profile = .empty };
        fixture.tab.enter(fixture.context(.{}));
    }

    /// Presses `code` with `modifier`'s key held, and runs the wait.
    fn press(fixture: *Fixture, code: u8, modifier: Modifier) void {
        const keyboard = &fixture.devices.keyboard;
        keyboard.down = @splat(false);
        keyboard.read();
        keyboard.down[code] = true;
        switch (modifier) {
            .shift => keyboard.down[input.scan.left_shift] = true,
            .control => keyboard.down[input.scan.left_control] = true,
            else => {},
        }
        fixture.tab.wait(fixture.context(.{}));
    }
};

test "a row waits for a key, and a click on nothing ends the wait" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    fixture.enter();
    const devices = &fixture.devices;
    // The first row is COCKPIT CAMERA's: a click clears its binding and waits.
    try std.testing.expectEqual(Item{ .row = 0 }, Controls.itemAt(.{ 100, 143 }).?);
    _ = try fixture.tab.choose(.{ .row = 0 }, fixture.context(.{}));
    try std.testing.expectEqual(.cockpit_camera, fixture.tab.waiting.?.action);
    try std.testing.expectEqual(0, devices.bindings.get(.cockpit_camera).key);
    // A click on nothing with nothing taken puts the old binding back.
    fixture.tab.endWait(devices);
    try std.testing.expectEqual(null, fixture.tab.waiting);
    try std.testing.expectEqual(controls.binding(.cockpit_camera).key, devices.bindings.get(.cockpit_camera).key);
    // A key no other action holds is taken, Shift with it, and the row waits on.
    _ = try fixture.tab.choose(.{ .row = 0 }, fixture.context(.{}));
    const k = @intFromEnum(input.Key.k);
    const cloak = controls.binding(.cloak_ship);
    try std.testing.expectEqual(k, cloak.key);
    fixture.press(k, .shift);
    try std.testing.expectEqual(k, devices.bindings.get(.cockpit_camera).key);
    try std.testing.expectEqual(Modifier.shift, devices.bindings.get(.cockpit_camera).modifier);
    try std.testing.expect(fixture.tab.changed and fixture.tab.conflict == null);
    try std.testing.expectEqual(.cockpit_camera, fixture.tab.waiting.?.action);
    // Pressed again, the row's own key asks nothing (a fix).
    fixture.press(k, .shift);
    try std.testing.expectEqual(null, fixture.tab.conflict);
    // A click on nothing ends the wait, keeping what was taken.
    fixture.tab.endWait(devices);
    try std.testing.expectEqual(k, devices.bindings.get(.cockpit_camera).key);
}

test "a key another action holds asks, and YES takes it from that action" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    fixture.enter();
    const devices = &fixture.devices;
    _ = try fixture.tab.choose(.{ .row = 0 }, fixture.context(.{}));
    const k = @intFromEnum(input.Key.k);
    fixture.press(k, .none);
    const conflict = fixture.tab.conflict.?;
    try std.testing.expectEqual(.cloak_ship, conflict.holder);
    // Its words: the key, whose action holds it, and the question.
    const strings: language.Language = .{ .strings = &.{} };
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\"K\"\n \n", question(&buffer, conflict, &strings, &devices.bindings));
    // The question takes the frames until it is answered: NO puts the old binding back.
    try std.testing.expect(fixture.tab.busy(fixture.context(.{ .at = .{ 340, 275 }, .down = true }), false));
    try std.testing.expect(fixture.tab.busy(fixture.context(.{ .at = .{ 340, 275 } }), false));
    try std.testing.expectEqual(null, fixture.tab.conflict);
    try std.testing.expectEqual(controls.binding(.cockpit_camera).key, devices.bindings.get(.cockpit_camera).key);
    try std.testing.expectEqual(k, devices.bindings.get(.cloak_ship).key);
    try std.testing.expect(!fixture.tab.busy(fixture.context(.{}), false));
    // YES takes the key from CLOAK SHIP, which is left with none.
    fixture.press(k, .none);
    _ = fixture.tab.busy(fixture.context(.{ .at = .{ 295, 275 }, .down = true }), false);
    _ = fixture.tab.busy(fixture.context(.{ .at = .{ 295, 275 } }), false);
    try std.testing.expectEqual(k, devices.bindings.get(.cockpit_camera).key);
    try std.testing.expectEqual(0, devices.bindings.get(.cloak_ship).key);
    try std.testing.expect(fixture.tab.changed);
    // CANCEL CHANGES puts both back.
    fixture.tab.cancel(devices);
    try std.testing.expectEqual(k, devices.bindings.get(.cloak_ship).key);
    try std.testing.expect(!fixture.tab.changed);
}

test "a joystick button is taken once, and held, holds the screen" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    fixture.enter();
    const devices = &fixture.devices;
    var stick = input.testing.stick();
    devices.joystick.open(stick.device(), input.default_dead_zone);
    // COUNTERMEASURES takes button 6, which no action holds.
    const row = for (controls.list, 0..) |entry, at| {
        if (entry == .countermeasures) break at;
    } else unreachable;
    fixture.tab.list.first = @intCast(row);
    _ = try fixture.tab.choose(.{ .row = 0 }, fixture.context(.{}));
    devices.joystick.state.buttons[6] = input.JoystickState.pressed;
    fixture.tab.wait(fixture.context(.{}));
    try std.testing.expectEqual(6, devices.bindings.get(.countermeasures).button.?);
    try std.testing.expect(fixture.tab.busy(fixture.context(.{}), false));
    devices.joystick.state.buttons[6] = 0;
    try std.testing.expect(!fixture.tab.busy(fixture.context(.{}), false));
    // FIRE LASERS' button 0 asks first.
    devices.joystick.state.buttons[0] = input.JoystickState.pressed;
    fixture.tab.wait(fixture.context(.{}));
    try std.testing.expectEqual(.fire_lasers, fixture.tab.conflict.?.holder);
}

test "the check boxes and the controllers" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    fixture.enter();
    const devices = &fixture.devices;
    // Without a joystick the keyboard steers: HAT ENABLE can't change, INVERT PITCH can, and is
    // written at once.
    try std.testing.expectEqual(input.ControlMode.keyboard, devices.controlMode());
    try std.testing.expectEqual(Item{ .check = .hat_enable }, Controls.itemAt(.{ 350, 380 }).?);
    _ = try fixture.tab.choose(.{ .check = .hat_enable }, fixture.context(.{}));
    try std.testing.expect(devices.settings.hat_enabled);
    _ = try fixture.tab.choose(.{ .check = .invert_pitch }, fixture.context(.{}));
    try std.testing.expect(!devices.settings.joystick_invert);
    try std.testing.expectEqualStrings("0", fixture.file.profile.value("KeyConfig", "JoystickInvert").?);
    // JOYSTICK can't be chosen without one, and stays the choice; MOUSE can.
    _ = try fixture.tab.choose(.{ .controller = .joystick }, fixture.context(.{}));
    try std.testing.expectEqual(input.ControlMode.joystick, devices.settings.control_mode);
    try std.testing.expectEqual(input.ControlMode.keyboard, devices.controlMode());
    try std.testing.expectEqual(Item{ .controller = .mouse }, Controls.itemAt(.{ 50, 380 }).?);
    _ = try fixture.tab.choose(.{ .controller = .mouse }, fixture.context(.{}));
    try std.testing.expectEqualStrings("2", fixture.file.profile.value("KeyConfig", "Controller").?);
}

test "leaving writes the controls where they are not what the file gives" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    fixture.enter();
    const devices = &fixture.devices;
    // Unchanged, nothing is written, the defaults of no joystick among it.
    try fixture.tab.save(devices, &fixture.file);
    try std.testing.expectEqual(null, fixture.file.profile.value("KeyConfig", "Controller"));
    try std.testing.expectEqual(null, fixture.file.profile.value("JoyConfig", "FIRE LASERS"));
    // A binding changed, they are.
    devices.bindings.getPtr(.eject).key = 0x2D;
    try fixture.tab.save(devices, &fixture.file);
    try std.testing.expectEqualStrings("45", fixture.file.profile.value("KeyConfig", "EJECT").?);
}

test "the arrows scroll a row each 5 ticks while held" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    fixture.enter();
    // The arrows lie over the first two rows, and win.
    try std.testing.expectEqual(Item{ .arrow = .up }, Controls.itemAt(.{ 380, 143 }).?);
    fixture.ticks += 1;
    try std.testing.expect(try fixture.tab.choose(.{ .arrow = .down }, fixture.context(.{})));
    try std.testing.expectEqual(1, fixture.tab.list.first);
    fixture.ticks += scroll_ticks;
    _ = try fixture.tab.choose(.{ .arrow = .down }, fixture.context(.{}));
    try std.testing.expectEqual(1, fixture.tab.list.first);
    fixture.ticks += 1;
    _ = try fixture.tab.choose(.{ .arrow = .down }, fixture.context(.{}));
    try std.testing.expectEqual(2, fixture.tab.list.first);
    // No further than the last row.
    fixture.tab.list.first = controls.list.len - rows;
    fixture.ticks += 10;
    _ = try fixture.tab.choose(.{ .arrow = .down }, fixture.context(.{}));
    try std.testing.expectEqual(controls.list.len - rows, fixture.tab.list.first);
    // A divider's row waits for nothing.
    const divider = for (controls.list, 0..) |entry, at| {
        if (entry == null) break at;
    } else unreachable;
    fixture.tab.list.first = @intCast(divider);
    _ = try fixture.tab.choose(.{ .row = 0 }, fixture.context(.{}));
    try std.testing.expectEqual(null, fixture.tab.waiting);
}

test "Up, Down and the wheel scroll the list while no row waits" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    fixture.enter();
    const keyboard = &fixture.devices.keyboard;
    keyboard.down[@intFromEnum(input.Key.down)] = true;
    fixture.ticks += 1;
    fixture.tab.scrollKeys(fixture.context(.{}));
    try std.testing.expectEqual(1, fixture.tab.list.first);
    // A notch of the wheel down, three rows more.
    fixture.tab.scrollKeys(fixture.context(.{ .wheel = -1 }));
    try std.testing.expectEqual(4, fixture.tab.list.first);
    // While a row waits, Down binds rather than scrolls.
    _ = try fixture.tab.choose(.{ .row = 0 }, fixture.context(.{}));
    fixture.ticks += 10;
    fixture.tab.scrollKeys(fixture.context(.{}));
    try std.testing.expectEqual(4, fixture.tab.list.first);
}

test joystickLabel {
    const gpa = std.testing.allocator;
    const fnt = @import("../../../../formats/fnt.zig");
    var font: hud.Opened = .open(try fnt.Font.parse(comptime fnt.testing.font(true)), null);
    defer font.deinit(gpa);
    font.widths = @splat(6);
    const string_list = [_][]const u8{""} ** (0x235 - 1) ++ [_][]const u8{"JOYSTICK"};
    const strings: language.Language = .{ .strings = &string_list };
    var buffer: [96]u8 = undefined;
    var joystick: input.Joystick = .{};
    // Without a joystick, JOYSTICK alone.
    try std.testing.expectEqualStrings("JOYSTICK", joystickLabel(&buffer, &joystick, &strings, &font));
    var stick = input.testing.stick();
    joystick.open(stick.device(), input.default_dead_zone);
    joystick.name = "Logitech Extreme 3D Pro";
    try std.testing.expectEqualStrings("JOYSTICK (LOGITECH EXTREME 3D PRO)", joystickLabel(&buffer, &joystick, &strings, &font));
    // A name too long for the room is cut short.
    joystick.name = "Thrustmaster T.16000M FCS Hands On Throttle And Stick";
    const shown = joystickLabel(&buffer, &joystick, &strings, &font);
    try std.testing.expect(std.mem.endsWith(u8, shown, "...)"));
    try std.testing.expect(font.textWidth(shown) <= Controller.room);
}

test bindingText {
    const strings: language.Language = .{ .strings = &.{} };
    var buffer: [64]u8 = undefined;
    const fire = controls.binding(.fire_lasers);
    // Without the game's strings, the key's name, then the button.
    try std.testing.expectEqualStrings("SPACE 0", bindingText(&buffer, fire, &strings));
    try std.testing.expectEqualStrings(" + E", bindingText(&buffer, controls.binding(.previous_enemy_target), &strings));
    try std.testing.expectEqualStrings("", bindingText(&buffer, .{ .name = "", .string = 0, .key = 0, .modifier = .none, .button = null }, &strings));
    try std.testing.expectEqualStrings("250", bindingText(&buffer, .{ .name = "", .string = 0, .key = 250, .modifier = .none, .button = null }, &strings));
}
