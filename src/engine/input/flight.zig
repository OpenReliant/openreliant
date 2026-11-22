//! Device-independent flight commands. The simulation applies the original steering, throttle,
//! power and shield rules to commands from either local input or a participant's command record.

const std = @import("std");
const gameobj = @import("../game/gameobj.zig");
const create = @import("../game/create.zig");
const power = @import("power.zig");

/// Control state the original keeps in local globals. Each participant keeps their own copy.
pub const State = struct {
    /// `throttle_setting` (`0x0051CF7C`): the setting changed by the throttle keys.
    throttle: f32 = 0,
    /// `matching_speed` (`0x00579984`): whether the throttle follows the selected target.
    matching_speed: bool = false,
    /// `throttle_before_match` (`0x00566794`): the throttle saved at the last match.
    throttle_before_match: f32 = 0,
    /// `afterburner_toggled` (`0x0051CEFE`): whether AFTERBURNER TOGGLE holds the burn on.
    afterburner_toggled: bool = false,
};

/// A key pair's direction, after resolving the original precedence and pitch inversion.
pub const Direction = enum { negative, neutral, positive };

pub const Throttle = union(enum) {
    held,
    axis: f32,
    keys: struct { accelerate: bool = false, decelerate: bool = false, zero: bool = false, full: bool = false },
};

pub const Steering = union(enum) {
    axes: [3]f32,
    keys: struct { yaw: Direction = .neutral, pitch: Direction = .neutral, roll: f32 = 0 },
    power: [2]f32,
    shields: f32,
};

/// Requests to the simulation, never a replacement position, velocity or shield value.
/// Local input resolves bindings, camera keys, mouse movement and axis inversion before this.
pub const Command = struct {
    steering: Steering = .{ .axes = .{ 0, 0, 0 } },
    throttle: Throttle = .{ .keys = .{} },
    strafe: Direction = .neutral,
    afterburner: bool = false,
    reverse: bool = false,
    toggle_afterburner: bool = false,

    /// Rejects non-finite or out-of-range axis values before they reach the ship's physics.
    /// Power and shield movement retain the mouse's range, which exceeds a joystick's unit axis.
    pub fn valid(command: Command) bool {
        switch (command.steering) {
            .axes => |axes| for (axes) |value| {
                if (!unit(value)) return false;
            },
            .keys => |keys| if (!unit(keys.roll)) return false,
            .power => |stick| for (stick) |value| {
                if (!heldAxis(value)) return false;
            },
            .shields => |value| if (!heldAxis(value)) return false,
        }
        const holding = switch (command.steering) {
            .power, .shields => true,
            .axes, .keys => false,
        };
        if (holding != (command.throttle == .held)) return false;
        return switch (command.throttle) {
            .axis => |value| std.math.isFinite(value) and value >= 0 and value <= 1,
            .held, .keys => true,
        };
    }

    /// A held command may run again at the next frame or physical step. Presses run once.
    pub fn consumePresses(command: *Command) void {
        command.toggle_afterburner = false;
        switch (command.throttle) {
            .keys => |*keys| {
                keys.zero = false;
                keys.full = false;
            },
            .axis, .held => {},
        }
    }
};

fn unit(value: f32) bool {
    return std.math.isFinite(value) and @abs(value) <= 1;
}

/// The largest held-stick value local mouse input can produce: its signed count times
/// `mouse_hold_scale / mouse_range` (`0x004DC554`, `0x004E2378`).
const max_held_axis: f32 = @as(f32, @floatFromInt(std.math.maxInt(i32))) * (mouse_hold_scale / @as(f32, @floatFromInt(mouse_range)));

/// The mouse stick's range (`0x004E2378`), shared with the local command sampler.
pub const mouse_range: i16 = 800;
/// The held mouse movement scale (`0x004DC554`), over `mouse_range`.
pub const mouse_hold_scale: f32 = 64;

fn heldAxis(value: f32) bool {
    return std.math.isFinite(value) and @abs(value) <= max_held_axis;
}

/// A key's steering step (`0x004DC4C0`), throttle step (`0x004DC4AC`) and bank share
/// (`0x004DC408`), applied in the order of `player_controls` (`0x00413410`).
const steering_step: f32 = 0.3;
const throttle_step: f32 = 0.02;
const bank_share: f32 = 0.5;

/// Which of its two passes a command is applied in. The game applies a pilot's controls once a
/// frame with the ship's orders and once more in each simulation step, and its keys move the
/// steering and the throttle by a fixed amount each time.
///
/// **Improvement:** the simulation steps twice as often as the original's
/// (`gameobj.ticks_per_step`), so a step's pass moves the keys' ramps by its share of an original
/// step (`gameobj.step_share`). The ramps then take as long as they do in the original.
pub const Pass = enum {
    frame,
    step,

    fn ramp(pass: Pass) f32 {
        return switch (pass) {
            .frame => 1,
            .step => gameobj.step_share,
        };
    }
};

fn stepped(previous: f32, direction: Direction, pass: Pass) f32 {
    return switch (direction) {
        .negative => previous - steering_step * pass.ramp(),
        .neutral => 0,
        .positive => previous + steering_step * pass.ramp(),
    };
}

/// `player_throttle_keys` (`0x004132C0`) after the bindings have been read. ACCELERATE wins over
/// DECELERATE; FULL THROTTLE runs after ZERO THROTTLE. The setting follows neither an axis nor a
/// held power window. With keys, the ship follows the setting unless its afterburner is on.
pub fn applyThrottle(state: *State, object: *gameobj.GameObject, throttle: Throttle, pass: Pass) void {
    const step = throttle_step * pass.ramp();
    switch (throttle) {
        .held => {},
        .axis => |value| object.throttle = value,
        .keys => |keys| {
            if (keys.accelerate) {
                state.throttle = @min(state.throttle + step, 1);
                object.throttle = @min(object.throttle + step, 1);
            } else if (keys.decelerate) {
                state.throttle = @max(state.throttle - step, 0);
                object.throttle = @max(object.throttle - step, 0);
            }
            if (keys.zero) {
                state.throttle = 0;
                object.throttle = 0;
                state.matching_speed = false;
            }
            if (keys.full) {
                state.throttle = 1;
                object.throttle = 1;
                state.matching_speed = false;
            }
            if (!object.afterburner) object.throttle = state.throttle;
        },
    }
}

/// The simulation half of `player_controls` (`0x00413410`). Bindings and devices stay in
/// `input.sampleFlight`. **Improvement:** the same rules apply to each participant's commands.
pub fn apply(state: *State, reserves: *gameobj.ShieldReserves, object: *gameobj.GameObject, combat: *const create.ShipCombat, command: Command, frame_duration: i32, pass: Pass) void {
    // player_controls (0x0041345D) reverses steering and strafe during the arena penalty.
    const handed: f32 = if (object.power_up == .reversed_controls) -1 else 1;
    switch (command.steering) {
        .axes => |axes| {
            object.yaw_input = handed * axes[0];
            object.pitch_input = handed * axes[1];
            object.roll_input = handed * axes[2];
            object.roll_input += object.yaw_input * bank_share;
        },
        .keys => |keys| {
            object.yaw_input = handed * stepped(handed * object.yaw_input, keys.yaw, pass);
            object.pitch_input = handed * stepped(handed * object.pitch_input, keys.pitch, pass);
            object.roll_input = handed * keys.roll;
            object.roll_input += object.yaw_input * bank_share;
        },
        .power => |stick| {
            object.holdTurns();
            power.move(object, stick[0], stick[1], frame_duration);
        },
        .shields => |y| {
            object.holdTurns();
            power.balanceShields(object, reserves, combat, y);
        },
    }
    applyThrottle(state, object, command.throttle, pass);
    object.lateral_input = handed * @as(f32, switch (command.strafe) {
        .negative => -1,
        .neutral => 0,
        .positive => 1,
    });
    object.throttle = std.math.clamp(object.throttle, 0, 1);
    if (command.toggle_afterburner) state.afterburner_toggled = !state.afterburner_toggled;
    object.afterburner = command.afterburner or state.afterburner_toggled;
    object.reverse_thrust = command.reverse;
    if (object.afterburner_fuel == 0) {
        object.afterburner = false;
        object.reverse_thrust = false;
    }
}

/// player_controls applies the power-up cap after speed matching (0x00413ADA).
pub fn limitArenaThrottle(object: *gameobj.GameObject) void {
    if (object.power_up == .half_throttle) object.throttle = @min(object.throttle, 0.5);
}

test "flight commands reject invalid axes and consume only presses" {
    var command: Command = .{ .toggle_afterburner = true, .afterburner = true, .throttle = .{ .keys = .{ .accelerate = true, .full = true } } };
    try std.testing.expect(command.valid());
    command.consumePresses();
    try std.testing.expect(!command.toggle_afterburner);
    try std.testing.expect(command.afterburner);
    try std.testing.expect(command.throttle.keys.accelerate);
    try std.testing.expect(!command.throttle.keys.full);
    command.steering = .{ .axes = .{ std.math.nan(f32), 0, 0 } };
    try std.testing.expect(!command.valid());
    command.steering = .{ .axes = .{ 0, 2, 0 } };
    try std.testing.expect(!command.valid());
    command.steering = .{ .power = .{ 64, -64 } };
    try std.testing.expect(!command.valid());
    command.throttle = .held;
    try std.testing.expect(command.valid());
    command.throttle = .{ .axis = std.math.inf(f32) };
    try std.testing.expect(!command.valid());
}

test "arena penalties apply to normalised flight commands" {
    var object = gameobj.testing.object();
    const combat: *const create.ShipCombat = &create.testing.tables().combat[0];
    var state: State = .{};
    var reserves: gameobj.ShieldReserves = .{};
    const command: Command = .{
        .steering = .{ .axes = .{ 0.4, 0.25, 0.1 } },
        .throttle = .{ .axis = 1 },
        .strafe = .positive,
    };
    object.power_up = .reversed_controls;
    apply(&state, &reserves, &object, combat, command, gameobj.ticks_per_step, .frame);
    try std.testing.expectEqual(-0.4, object.yaw_input);
    try std.testing.expectEqual(-0.25, object.pitch_input);
    try std.testing.expectApproxEqAbs(-0.3, object.roll_input, 0.001);
    try std.testing.expectEqual(-1, object.lateral_input);
    object.power_up = .half_throttle;
    apply(&state, &reserves, &object, combat, command, gameobj.ticks_per_step, .frame);
    limitArenaThrottle(&object);
    try std.testing.expectEqual(0.5, object.throttle);
    object.power_up = .none;
    apply(&state, &reserves, &object, combat, command, gameobj.ticks_per_step, .frame);
    limitArenaThrottle(&object);
    try std.testing.expectEqual(1, object.throttle);
}

test {
    std.testing.refAllDecls(@This());
}
