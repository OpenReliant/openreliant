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

/// What `openreliant.input` holds.
pub const package = struct {
    pub const key_down = api.Function("Whether `key` is held down.", &.{"key"}, keyDown);
    pub const action_down = api.Function("Whether the controls bound to `action` are held: its key, or its joystick button.", &.{"action"}, actionDown);
};

/// `input.key_down(key)`.
fn keyDown(call: Call, key: engine_input.Key) bool {
    return Presentation.hostOf(call, "input.key_down").devices.keyboard.down[@intFromEnum(key)];
}

/// `input.action_down(action)`.
fn actionDown(call: Call, action: controls.Action) bool {
    return Presentation.hostOf(call, "input.action_down").devices.active(action, false);
}
