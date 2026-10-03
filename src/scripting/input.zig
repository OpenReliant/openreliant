//! The `openreliant.input` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! for player and menu scripts: whether keys are held, and the controls bound to actions
//! (`package`). `on_key_press`, `on_key_release` and `on_action` tell them as they change
//! (`presentation.zig`).

const openreliant = @import("openreliant");
const engine_input = openreliant.engine.input;
const controls = engine_input.controls;
const api = @import("api.zig");
const Call = api.Call;
const Presentation = @import("presentation.zig").Presentation;
const std = @import("std");
const values = @import("values.zig");
const interface = openreliant.engine.game.interface;
const Modifier = engine_input.ControlBinding.Modifier;

pub const Identifier = union(enum) { name: []const u8, number: u32 };

const Definition = struct {
    label: []const u8,
    key: ?engine_input.Key = null,
    modifier: Modifier = .none,
    button: ?u8 = null,
    gamepad_button: ?engine_input.GamepadButton = null,
};

fn registerAction(call: Call, name: []const u8, definition: Definition) []const u8 {
    if (call.context.family != .menu) call.raise("input.register_action requires a menu script", .{});
    const scripts = call.runtime();
    if (!openreliant.dte.source.validId(name)) call.raise("action name must be an identifier", .{});
    switch (definition.modifier) {
        .none, .shift, .control => {},
        else => call.raise("action modifier must be none, shift or control", .{}),
    }
    if (definition.button) |button| if (button >= engine_input.JoystickState.max_buttons) call.raise("action button is out of range", .{});
    var buffer: [engine_input.actions.name_size]u8 = undefined;
    const qualified = std.fmt.bufPrint(&buffer, "{s}:{s}", .{ call.context.modOf().name, name }) catch call.raise("qualified action name is too long", .{});
    const index = scripts.input_actions.add(call.context, qualified, definition.label, .{ .name = "", .string = 0, .key = if (definition.key) |key| @intFromEnum(key) else 0, .modifier = definition.modifier, .button = definition.button }) catch |err| call.raise("input.register_action: {s}", .{@errorName(err)});
    scripts.input_actions.entries[index].gamepad_button = if (definition.gamepad_button) |button| @intFromEnum(button) else null;
    var devices: engine_input.Devices = .{ .mod_actions = &scripts.input_actions };
    const file: openreliant.engine.profile.Profile = if (scripts.options.shared.bindings_file) |held| held.profile else .empty;
    // Loading just this action preserves existing in-memory user bindings during registration.
    devices.mod_actions = null;
    interface.loadKeyConfig(&devices, file);
    devices.mod_actions = &scripts.input_actions;
    if (scripts.presentation) |shown| if (shown.host) |host| {
        devices.bindings = host.devices.bindings;
        devices.joystick.kind = host.devices.joystick.kind;
    };
    interface.loadModBinding(&devices, file, index);
    return scripts.input_actions.entries[index].nameOf();
}

/// What `openreliant.input` holds.
pub const package = struct {
    pub const register_action = api.Function("Registers a mod-qualified action from a menu script. Its label appears in controls; conflicting defaults stay unassigned. Returns its name for action_down and on_action. Bindings are saved by name.", &.{ "name", "definition" }, registerAction);
    pub const key_down = api.Function("Whether `key` is held down.", &.{"key"}, keyDown);
    pub const action_down = api.Function("Whether the controls bound to `action` are held: its key, or its joystick button.", &.{"action"}, actionDown);
};

/// `input.key_down(key)`.
fn keyDown(call: Call, key: engine_input.Key) bool {
    return Presentation.hostOf(call, "input.key_down").devices.keyboard.down[@intFromEnum(key)];
}

/// `input.action_down(action)`.
fn actionDown(call: Call, identifier: Identifier) bool {
    const host = Presentation.hostOf(call, "input.action_down");
    return switch (identifier) {
        .name => |name| if (values.byName(controls.Action, name)) |action| host.devices.active(action, false) else blk: {
            const index = call.runtime().input_actions.find(name) orelse call.raise("no registered action '{s}'", .{name});
            break :blk host.flying and host.devices.bindingActive(call.runtime().input_actions.entries[index].binding, false);
        },
        .number => |number| if (number < controls.defaults.len) host.devices.active(@enumFromInt(number), false) else call.raise("custom actions must be named", .{}),
    };
}
