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
const widgets = @import("widgets.zig");
const Toggle = widgets.Toggle;

/// The rows the list shows at once (`0x0042B665`, `0x0042D177`).
pub const rows = 12;

/// The two panes, the actions' and their bindings', framed (`interface_box`, `0x0042CD72`,
/// `0x0042CD90`).
const panes = [_]widgets.Frame{
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

/// The list's arrows (`0x0042D8CA` on): one at the top right of the actions' pane, the other
/// below it.
const arrows: widgets.ListArrows = .{ .at = .{ 374, 136 } };

/// The check boxes, top to bottom: their box at x 349, their label at x 367.
pub const Check = enum {
    force_feedback,
    invert_pitch,
    hat_enable,
    joystick_roll,

    const box_x = 349;
    /// How far left of a box the pointer finds it (`0x0042B70D` on).
    const reach = 4;

    /// Its box and its label.
    fn box(check: Check) Toggle {
        return .{ .at = .{ box_x, check.y() }, .gap = Toggle.check_gap, .reach = reach };
    }

    /// Its row (`0x0042B70D` on).
    fn y(check: Check) i32 {
        return switch (check) {
            .force_feedback => 325,
            .invert_pitch => 349,
            .hat_enable => 373,
            .joystick_roll => 397,
        };
    }

    fn string(check: Check) u32 {
        return switch (check) {
            .force_feedback => 0x17D,
            .invert_pitch => 0x17E,
            .hat_enable => 0x17F,
            .joystick_roll => 0x233,
        };
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

    fn flip(check: Check, kept: *input.Settings) void {
        switch (check) {
            .force_feedback => kept.force_feedback = !kept.force_feedback,
            .invert_pitch => kept.joystick_invert = !kept.joystick_invert,
            .hat_enable => kept.hat_enabled = !kept.hat_enabled,
            .joystick_roll => kept.twist_enabled = !kept.twist_enabled,
        }
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
    const label_x = box_x + Toggle.controller_gap;

    /// Its box and its label.
    fn box(controller: Controller) Toggle {
        return .{ .at = .{ box_x, controller.y() } };
    }

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
        placed[at] = .{ .rect = check.box().rect(), .item = .{ .check = check } };
        at += 1;
    }
    for (std.enums.values(Arrow)) |arrow| {
        placed[at] = .{ .rect = arrows.rect(arrow), .item = .{ .arrow = arrow } };
        at += 1;
    }
    for (0..rows) |row| {
        placed[at] = .{ .rect = rowRect(row), .item = .{ .row = row } };
        at += 1;
    }
    placed[at] = .{ .rect = Check.joystick_roll.box().rect(), .item = .{ .check = .joystick_roll } };
    at += 1;
    for (std.enums.values(Controller)) |controller| {
        placed[at] = .{ .rect = controller.box().rect(), .item = .{ .controller = controller } };
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
    action: RowAction,
    old: Binding,
    generation: u64 = 0,
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
    holder: RowAction,
    generation: u64 = 0,
    question: dialog.Confirm = .{ .message = .{ .words = "" } },
};

/// The screen uses one binding path for original actions and registry entries.
const RowAction = union(enum) {
    original: Action,
    custom: usize,

    fn binding(action: RowAction, devices: *const input.Devices) *const Binding {
        return switch (action) {
            .original => |original| devices.bindings.getPtrConst(original),
            .custom => |index| &devices.mod_actions.?.entries[index].binding,
        };
    }

    fn mutable(action: RowAction, devices: *input.Devices) *Binding {
        return switch (action) {
            .original => |original| devices.bindings.getPtr(original),
            .custom => |index| &devices.mod_actions.?.entries[index].binding,
        };
    }

    fn label(action: RowAction, devices: *const input.Devices, strings: *const language.Language) []const u8 {
        return switch (action) {
            .original => strings.string(action.binding(devices).string) orelse "",
            .custom => |index| devices.mod_actions.?.entries[index].labelOf(),
        };
    }

    fn generation(action: RowAction, devices: *const input.Devices) u64 {
        return switch (action) {
            .original => 0,
            .custom => |index| if (devices.mod_actions.?.entries[index].owner != null) devices.mod_actions.?.entries[index].generation else 0,
        };
    }
};

fn actionAt(devices: *const input.Devices, row: usize) ?RowAction {
    if (row < controls.list.len) return .{ .original = controls.list[row] orelse return null };
    const registry = devices.mod_actions orelse return null;
    if (row == controls.list.len) return null;
    return .{ .custom = registry.liveIndex(row - controls.list.len - 1) orelse return null };
}

fn conflictAt(devices: *const input.Devices, except: RowAction, control: interface.BindingControl) ?RowAction {
    const excluded: interface.BindingAction = switch (except) {
        .original => |original| .{ .original = original },
        .custom => |index| .{ .custom = index },
    };
    return switch (interface.bindingConflict(devices, excluded, control) orelse return null) {
        .original => |original| .{ .original = original },
        .custom => |index| .{ .custom = index },
    };
}

/// The tab's state, which the game keeps in globals and on `controls_screen`'s stack.
pub const Controls = struct {
    /// The input settings and the bindings as the screen opened (`0x0042BA7F` on), which CANCEL
    /// CHANGES puts back.
    kept: struct { settings: input.Settings, bindings: input.Bindings } = .{ .settings = .{}, .bindings = input.defaultBindings(.joystick) },
    /// The list: the 80 rows of `controls_list`, 12 shown from the first (`0x00520234`).
    list: widgets.List = .of(controls.list.len, rows, 0),
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
    kept_mod: [input.actions.max_actions]?Binding = @splat(null),
    kept_generations: [input.actions.max_actions]u64 = @splat(0),

    /// `controls_screen`'s start (`0x0042BA75` on): the bindings read again from `starlancer.ini`,
    /// kept for CANCEL CHANGES, and the list at its top.
    pub fn enter(tab: *Controls, context: Context) void {
        const devices = context.devices;
        interface.loadKeyConfig(devices, context.settings_file.profile);
        tab.* = .{
            .kept = .{ .settings = devices.settings, .bindings = devices.bindings },
            .list = .of(controls.list.len, rows, context.ticks),
        };
        if (devices.mod_actions) |registry| {
            tab.list.rows.count = registry.rowCount();
            for (registry.entries[0..registry.count], 0..) |entry, index| {
                tab.kept_mod[index] = entry.binding;
                tab.kept_generations[index] = entry.generation;
            }
        }
    }

    /// Whether the conflict's question or a button taken holds the frame: the question answered,
    /// YES gives the waiting row what it took, from the action that held it, and NO puts its old
    /// binding back, the row waiting on (`0x0042C1F2`, `0x0042C284`, `0x0042C34D` on); and a button
    /// taken holds the screen until it comes up.
    pub fn busy(tab: *Controls, context: Context, escaped: bool) bool {
        const devices = context.devices;
        tab.refresh(devices);
        if (tab.conflict) |*asking| {
            const answer = asking.question.frame(context.pointer, escaped) orelse return true;
            const conflict = asking.*;
            tab.conflict = null;
            const waiting = tab.waiting orelse return true;
            const binding = waiting.action.mutable(devices);
            if (!answer) {
                binding.* = waiting.old;
                return true;
            }
            const holder = conflict.holder.mutable(devices);
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
        tab.refresh(devices);
        const settings_file = context.settings_file;
        switch (item) {
            .check => |check| if (check.usable(devices)) {
                check.flip(&devices.settings);
                try interface.saveSetting(devices.settings, settings_file, check.setting());
            },
            .arrow => |arrow| {
                tab.list.scrollHeld(arrow, context.ticks);
                return true;
            },
            .row => |row| {
                tab.restore(devices);
                const action = actionAt(devices, tab.list.rows.first + row) orelse return false;
                const binding = action.mutable(devices);
                tab.waiting = .{ .action = action, .old = binding.*, .generation = action.generation(devices) };
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

    /// The mouse's wheel scrolls the list as it turns, and Up and Down, held, as its arrows do
    /// (`widgets.List.scrollBy`), while no row waits, which then binds them.
    pub fn scrollKeys(tab: *Controls, context: Context) void {
        if (tab.waiting == null) {
            tab.list.scrollBy(context.pointer.wheel, &context.devices.keyboard, context.ticks);
        } else tab.list.rows.wheel(context.pointer.wheel);
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
        tab.refresh(devices);
        const waiting = tab.waiting orelse return;
        const binding = waiting.action.mutable(devices);
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
        tab.refresh(context.devices);
        const waiting = tab.waiting orelse return;
        const devices = context.devices;
        const binding = waiting.action.mutable(devices);
        keys: for (controls.keys, 0..) |key, index| {
            for (taken_modifiers) |modifier| {
                if (!devices.keyboard.pressed(key.code, modifier, true)) continue;
                if (conflictAt(devices, waiting.action, .{ .key = .{ .code = key.code, .modifier = modifier } })) |holder| {
                    tab.conflict = .{ .taken = .{ .key = .{ .index = @intCast(index), .modifier = modifier } }, .holder = holder, .generation = holder.generation(devices) };
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
        if (conflictAt(devices, waiting.action, .{ .button = button })) |holder| {
            tab.conflict = .{ .taken = .{ .button = button }, .holder = holder, .generation = holder.generation(devices) };
            return;
        }
        binding.button = button;
        tab.changed = true;
    }

    /// CANCEL CHANGES (`0x0042BC9C`): the settings and the bindings as the screen opened.
    pub fn cancel(tab: *Controls, devices: *input.Devices) void {
        devices.settings = tab.kept.settings;
        devices.bindings = tab.kept.bindings;
        if (devices.mod_actions) |registry| for (registry.entries[0..registry.count], 0..) |*entry, index| {
            if (entry.owner != null and entry.generation == tab.kept_generations[index]) {
                if (tab.kept_mod[index]) |binding| entry.binding = binding;
            }
        };
        tab.changed = false;
    }

    /// A reload can remove actions while the tab is open. Cancel a stale wait before using it.
    fn refresh(tab: *Controls, devices: *const input.Devices) void {
        if (devices.mod_actions) |registry| {
            tab.list.rows.count = registry.rowCount();
            tab.list.rows.first = @min(tab.list.rows.first, tab.list.rows.count -| tab.list.rows.shown);
            if (tab.conflict) |conflict| {
                if (conflict.holder.generation(devices) != conflict.generation) tab.conflict = null;
            }
            if (tab.waiting) |waiting| {
                if (waiting.action.generation(devices) != waiting.generation) {
                    tab.waiting = null;
                    tab.conflict = null;
                }
            }
        }
    }

    /// RESET DEFAULTS (`0x0042BE6A`): the defaults, written at once.
    pub fn reset(_: *Controls, devices: *input.Devices, settings_file: *profile.File) Allocator.Error!void {
        interface.keyConfigDefaults(devices);
        interface.loadModBindings(devices, .empty);
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
        try interface.saveModBindings(devices, settings_file);
        var filed: input.Devices = .{ .joystick = devices.joystick };
        interface.loadKeyConfig(&filed, settings_file.profile);
        if (std.meta.eql(filed.settings, devices.settings) and std.meta.eql(filed.bindings, devices.bindings)) return;
        try interface.saveKeyConfig(devices, settings_file);
    }

    /// `controls_screen_draw`'s part (`0x0042CD30`): the panes, the headings, the controllers' and
    /// the check boxes' labels, each dimmed where it can't be used, the list's rows, the boxes,
    /// the arrows, the one under the pointer lit, the ticks, and the conflict's question where it
    /// is up.
    pub fn draw(given: Controls, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, devices: *const input.Devices) canvas_module.Error!void {
        var tab = given;
        tab.refresh(devices);
        const small = canvas.fonts.small;
        const blue = canvas_module.blue;
        for (panes) |pane| pane.draw(canvas);
        for (headings) |heading| try widgets.heading(canvas, heading);
        try primary_controller.write(canvas, small, blue);
        for (std.enums.values(Controller)) |controller| {
            var buffer: [96]u8 = undefined;
            const text: Label.Text = if (controller == .joystick)
                .{ .words = joystickLabel(&buffer, &devices.joystick, canvas.strings, small) }
            else
                .{ .string = controller.string() };
            try controller.box().draw(canvas, art, text, devices.controlMode() == controller.mode(), controller.usable(devices));
        }
        for (std.enums.values(Check)) |check| try check.box().draw(canvas, art, .{ .string = check.string() }, check.ticked(devices), check.usable(devices));
        try tab.drawList(canvas, devices);
        try arrows.draw(canvas, art, tab.arrow);
        if (tab.conflict) |conflict| {
            var buffer: [256]u8 = undefined;
            var asked = conflict.question;
            asked.message = .{ .words = question(&buffer, conflict, canvas.strings, devices) };
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
        for (tab.list.rows.first..tab.list.rows.end(), 0..) |entry, row| {
            const y = first_row_y + @as(i32, @intCast(row)) * row_height;
            const action = actionAt(devices, entry) orelse {
                // Its two lines stand 6 and 7 below where a row's text starts.
                const line_y = y + 7;
                for (divider_spans) |span| {
                    canvas.line(.{ span[0], line_y - 1 }, .{ span[1], line_y - 1 }, canvas_module.blue);
                    canvas.line(.{ span[0], line_y }, .{ span[1], line_y }, canvas_module.blue);
                }
                continue;
            };
            const waiting = if (tab.waiting) |waits| std.meta.eql(waits.action, action) else false;
            const colour = if (waiting) canvas_module.white else canvas_module.blue;
            const binding = action.binding(devices).*;
            switch (action) {
                .original => try canvas.string(small, .{ name_x, y }, binding.string, colour, .left),
                .custom => {
                    var label_buffer: [input.actions.label_size]u8 = undefined;
                    const label = language.encode(&label_buffer, action.label(devices, canvas.strings));
                    try canvas.text(small, .{ name_x, y }, label, colour, .left);
                },
            }
            var buffer: [96]u8 = undefined;
            const shown = bindingText(&buffer, binding, canvas.strings, &devices.key_names);
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

/// `text`, UTF-8, in capitals, in the game's code page (`language.encode`), as much of it as
/// `buffer` holds; empty where it isn't UTF-8.
fn capitals(buffer: []u8, text: []const u8) []const u8 {
    const encoded = language.encode(buffer, text);
    for (encoded) |*character| character.* = std.ascii.toUpper(character.*);
    return encoded;
}

/// A binding as the list writes it (`0x0042D214` on): SHIFT + K, CONTROL + K or K, the key by its
/// name in `names`, then AND JOY n for a button, n as the file numbers it; empty for none. Alt
/// isn't written. A binding without a key has no name, as the loaders leave it none
/// (`0x0042CA2B`).
fn bindingText(buffer: []u8, binding: Binding, strings: *const language.Language, names: *const input.KeyNames) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const name = if (binding.key == 0) "" else names.of(binding.key);
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

/// The conflict's question (`0x0042C143` on, `0x0042C3E0` on): what was taken, in quotes, the key
/// by its name in `key_names`, then This Key is already assigned to, the action that holds it, and
/// Redefine Anyway?, a line each.
fn question(buffer: []u8, conflict: Conflict, strings: *const language.Language, devices: *const input.Devices) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    switch (conflict.taken) {
        .key => |key| {
            const name = devices.key_names.of(controls.keys[key.index].code);
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
    const holder = conflict.holder.label(devices, strings);
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
    try std.testing.expectEqual(.cockpit_camera, fixture.tab.waiting.?.action.original);
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
    try std.testing.expectEqual(.cockpit_camera, fixture.tab.waiting.?.action.original);
    // Pressed again, the row's own key asks nothing (a fix).
    fixture.press(k, .shift);
    try std.testing.expectEqual(null, fixture.tab.conflict);
    // A click on nothing ends the wait, keeping what was taken.
    fixture.tab.endWait(devices);
    try std.testing.expectEqual(k, devices.bindings.get(.cockpit_camera).key);
}

test "a mod row rebinds through original conflicts and cancel restores its binding" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    var registry: input.actions.Registry = .{};
    var owner: u8 = 0;
    const index = try registry.add(&owner, "a:pulse", "Pulse", .{ .name = "", .string = 0, .key = 0, .modifier = .none, .button = null });
    fixture.devices.mod_actions = &registry;
    fixture.enter();
    fixture.tab.list.rows.first = fixture.tab.list.rows.count - rows;
    _ = try fixture.tab.choose(.{ .row = rows - 1 }, fixture.context(.{}));
    try std.testing.expectEqual(index, fixture.tab.waiting.?.action.custom);
    fixture.press(@intFromEnum(input.Key.k), .none);
    try std.testing.expectEqual(.cloak_ship, fixture.tab.conflict.?.holder.original);
    _ = fixture.tab.busy(fixture.context(.{ .at = .{ 295, 275 }, .down = true }), false);
    _ = fixture.tab.busy(fixture.context(.{ .at = .{ 295, 275 } }), false);
    try std.testing.expectEqual(@intFromEnum(input.Key.k), registry.entries[index].binding.key);
    try std.testing.expectEqual(0, fixture.devices.bindings.get(.cloak_ship).key);
    fixture.press(@intFromEnum(input.Key.k), .shift);
    try std.testing.expectEqual(Modifier.shift, registry.entries[index].binding.modifier);
    try fixture.tab.save(&fixture.devices, &fixture.file);
    try std.testing.expect(fixture.file.profile.value(interface.mod_key_section, "a:pulse") != null);
    fixture.tab.cancel(&fixture.devices);
    try std.testing.expectEqual(0, registry.entries[index].binding.key);
    try fixture.tab.reset(&fixture.devices, &fixture.file);
    try std.testing.expectEqual(0, registry.entries[index].binding.key);
    registry.removeOwner(&owner);
    fixture.tab.refresh(&fixture.devices);
    try std.testing.expectEqual(controls.list.len, fixture.tab.list.rows.count);
}

test "reused mod action slots cannot receive stale conflicts or cancelled bindings" {
    var fixture: Fixture = .init();
    defer fixture.deinit();
    var registry: input.actions.Registry = .{};
    var owner: u8 = 0;
    const empty: Binding = .{ .name = "", .string = 0, .key = 0, .modifier = .none, .button = null };
    const index = try registry.add(&owner, "a:old", "Old", empty);
    fixture.devices.mod_actions = &registry;
    fixture.enter();
    fixture.tab.waiting = .{ .action = .{ .original = .cockpit_camera }, .old = fixture.devices.bindings.get(.cockpit_camera) };
    fixture.tab.conflict = .{ .holder = .{ .custom = index }, .generation = registry.entries[index].generation, .taken = .{ .button = 3 } };
    registry.removeOwner(&owner);
    var replacement = empty;
    replacement.key = @intFromEnum(input.Key.f12);
    try std.testing.expectEqual(index, try registry.add(&owner, "a:new", "New", replacement));
    fixture.tab.refresh(&fixture.devices);
    try std.testing.expectEqual(null, fixture.tab.conflict);
    fixture.tab.cancel(&fixture.devices);
    try std.testing.expectEqual(replacement.key, registry.entries[index].binding.key);
    fixture.tab.waiting = .{ .action = .{ .custom = index }, .old = replacement, .generation = registry.entries[index].generation };
    registry.removeOwner(&owner);
    _ = try registry.add(&owner, "a:new", "New again", empty);
    fixture.tab.refresh(&fixture.devices);
    try std.testing.expectEqual(null, fixture.tab.waiting);
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
    try std.testing.expectEqual(.cloak_ship, conflict.holder.original);
    // Its words: the key, whose action holds it, and the question.
    const strings: language.Language = .{ .strings = &.{} };
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\"K\"\n \n", question(&buffer, conflict, &strings, devices));
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
    fixture.tab.list.rows.first = @intCast(row);
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
    try std.testing.expectEqual(.fire_lasers, fixture.tab.conflict.?.holder.original);
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
    try std.testing.expectEqual(1, fixture.tab.list.rows.first);
    fixture.ticks += widgets.List.scroll_ticks;
    _ = try fixture.tab.choose(.{ .arrow = .down }, fixture.context(.{}));
    try std.testing.expectEqual(1, fixture.tab.list.rows.first);
    fixture.ticks += 1;
    _ = try fixture.tab.choose(.{ .arrow = .down }, fixture.context(.{}));
    try std.testing.expectEqual(2, fixture.tab.list.rows.first);
    // No further than the last row.
    fixture.tab.list.rows.first = controls.list.len - rows;
    fixture.ticks += 10;
    _ = try fixture.tab.choose(.{ .arrow = .down }, fixture.context(.{}));
    try std.testing.expectEqual(controls.list.len - rows, fixture.tab.list.rows.first);
    // A divider's row waits for nothing.
    const divider = for (controls.list, 0..) |entry, at| {
        if (entry == null) break at;
    } else unreachable;
    fixture.tab.list.rows.first = @intCast(divider);
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
    try std.testing.expectEqual(1, fixture.tab.list.rows.first);
    // A notch of the wheel down, three rows more.
    fixture.tab.scrollKeys(fixture.context(.{ .wheel = -1 }));
    try std.testing.expectEqual(4, fixture.tab.list.rows.first);
    // While a row waits, Down binds rather than scrolls.
    _ = try fixture.tab.choose(.{ .row = 0 }, fixture.context(.{}));
    fixture.ticks += 10;
    fixture.tab.scrollKeys(fixture.context(.{}));
    try std.testing.expectEqual(4, fixture.tab.list.rows.first);
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
    var names: input.KeyNames = .{};
    var buffer: [64]u8 = undefined;
    const fire = controls.binding(.fire_lasers);
    // Without the game's strings, the key's name, then the button.
    try std.testing.expectEqualStrings("SPACE 0", bindingText(&buffer, fire, &strings, &names));
    try std.testing.expectEqualStrings(" + E", bindingText(&buffer, controls.binding(.previous_enemy_target), &strings, &names));
    try std.testing.expectEqualStrings("", bindingText(&buffer, .{ .name = "", .string = 0, .key = 0, .modifier = .none, .button = null }, &strings, &names));
    try std.testing.expectEqualStrings("Unknown", bindingText(&buffer, .{ .name = "", .string = 0, .key = 250, .modifier = .none, .button = null }, &strings, &names));
    // A key by the name the keyboard's layout gives it.
    names.set(0x39, "Leertaste");
    try std.testing.expectEqualStrings("Leertaste 0", bindingText(&buffer, fire, &strings, &names));
}
