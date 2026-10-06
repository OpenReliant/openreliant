//! Joysticks and gamepads with SDL3, replacing DirectInput's joystick support. Each controller SDL
//! detects is presented to the game as a DirectInput-style joystick device
//! (`engine.input.JoystickDevice`), with axes scaled to the ranges the game sets, its dead zone
//! applied, 32 buttons and up to four hats. SDL supports a wide range of controllers on every
//! system: flight sticks, throttles, wheels and old gameport sticks on USB adapters as plain
//! joysticks, and the gamepads in its mapping database (Xbox, PlayStation, Nintendo and many
//! others) with a standard layout.

const std = @import("std");
const c = @import("sdl");
const openreliant = @import("openreliant");
const input = openreliant.engine.input;
const interface = openreliant.engine.game.interface;
const Profile = openreliant.engine.profile.Profile;
const Axis = input.Axis;
const JoystickState = input.JoystickState;
const GamepadButton = input.GamepadButton;
const sdl = @import("sdl.zig");

pub const Error = sdl.Error;
const fail = sdl.fail;

/// How the program uses SDL's joystick support.
pub const Mode = enum {
    /// The game: it handles SDL's events, including the quit event SDL sends for Ctrl+C, and reads
    /// controllers while its window has focus.
    game,
    /// A tool without a window that handles no events: controllers are read even without focus,
    /// and Ctrl+C ends the program normally instead of being turned into an SDL event.
    tool,
};

/// Initializes SDL's joystick and gamepad support. SDL then sends a connection event for each
/// controller that is already connected.
pub fn init(mode: Mode) Error!void {
    if (mode == .tool) {
        _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
        _ = c.SDL_SetHint(c.SDL_HINT_NO_SIGNAL_HANDLERS, "1");
    }
    if (!c.SDL_InitSubSystem(c.SDL_INIT_GAMEPAD)) return fail("SDL_InitSubSystem");
}

pub fn deinit() void {
    c.SDL_QuitSubSystem(c.SDL_INIT_GAMEPAD);
}

/// Adds the gamepad mappings in the file at `path`, in SDL's format, so that gamepads missing from
/// SDL's database are recognized. Returns the number of mappings added; 0 if the file is missing.
pub fn addMappings(path: [:0]const u8) u32 {
    return @intCast(@max(c.SDL_AddGamepadMappingsFromFile(path), 0));
}

/// Updates the controllers' state now, instead of on the next event poll.
pub fn update() void {
    c.SDL_UpdateJoysticks();
}

/// The number of axes, buttons and hats SDL reports for a joystick.
pub fn axisCount(plain: *c.SDL_Joystick) u32 {
    return @intCast(@max(c.SDL_GetNumJoystickAxes(plain), 0));
}

pub fn buttonCount(plain: *c.SDL_Joystick) u32 {
    return @intCast(@max(c.SDL_GetNumJoystickButtons(plain), 0));
}

/// The reading of a joystick's axis `index`, from -32768 to 32767, as SDL gives it.
pub fn axisValue(plain: *c.SDL_Joystick, index: u32) i16 {
    return c.SDL_GetJoystickAxis(plain, @intCast(index));
}

pub fn hatCount(plain: *c.SDL_Joystick) u32 {
    return @intCast(@max(c.SDL_GetNumJoystickHats(plain), 0));
}

/// A motor's speed as SDL takes it, from a share of full speed.
fn motorSpeed(share: f32) u16 {
    return std.math.lossyCast(u16, @round(std.math.clamp(share, 0, 1) * std.math.maxInt(u16)));
}

test motorSpeed {
    try std.testing.expectEqual(0, motorSpeed(0));
    try std.testing.expectEqual(std.math.maxInt(u16), motorSpeed(1));
    try std.testing.expectEqual(32768, motorSpeed(0.5));
    try std.testing.expectEqual(0, motorSpeed(-1));
}

/// A controller SDL has detected, before it is opened.
pub const Found = struct {
    id: c.SDL_JoystickID,
    name: []const u8,
    kind: input.JoystickDevice.Kind,
    /// The type SDL reports, from the device's description or SDL's list of known devices.
    sdl_type: c.SDL_JoystickType,
    vendor: u16,
    product: u16,
};

/// The connected controllers, in the order SDL lists them.
pub fn attached(arena: std.mem.Allocator) ![]Found {
    var count: c_int = 0;
    const ids = c.SDL_GetJoysticks(&count) orelse return fail("SDL_GetJoysticks");
    defer c.SDL_free(ids);
    const found = try arena.alloc(Found, @intCast(count));
    for (found, ids[0..found.len]) |*each, id| {
        const name = c.SDL_GetJoystickNameForID(id);
        each.* = .{
            .id = id,
            .name = try arena.dupe(u8, if (name != null) std.mem.span(name) else "Unnamed controller"),
            .kind = if (c.SDL_IsGamepad(id)) .gamepad else .joystick,
            .sdl_type = c.SDL_GetJoystickTypeForID(id),
            .vendor = c.SDL_GetJoystickVendorForID(id),
            .product = c.SDL_GetJoystickProductForID(id),
        };
    }
    return found;
}

/// Selects the controller the game uses. If `preference` (`Joystick` in `JoyConfig`) is set, the
/// first controller whose name contains it. Otherwise the first joystick that isn't a gamepad or a
/// standalone throttle, since a player who connects a flight stick wants to fly with it; then the
/// first gamepad; then any controller. The original game picks the first joystick with force
/// feedback, then the first of any kind.
pub fn choose(found: []const Found, preference: ?[]const u8) ?Found {
    if (preferred(found, preference)) |each| return each;
    for (found) |each| {
        if (each.kind == .joystick and each.sdl_type != c.SDL_JOYSTICK_TYPE_THROTTLE) return each;
    }
    for (found) |each| {
        if (each.kind == .gamepad) return each;
    }
    return if (found.len > 0) found[0] else null;
}

/// The first controller whose name contains `preference` (`Joystick` in `JoyConfig`), in any case;
/// null when no preference is set or no controller matches it.
pub fn preferred(found: []const Found, preference: ?[]const u8) ?Found {
    const text = preference orelse return null;
    if (text.len == 0) return null;
    for (found) |each| {
        if (std.ascii.findIgnoreCase(each.name, text) != null) return each;
    }
    return null;
}

/// Whether `preference` is set but matches none of the controllers in `found`, so that `choose`
/// falls back to its automatic choice.
pub fn unmatched(found: []const Found, preference: ?[]const u8) bool {
    const text = preference orelse return false;
    return text.len > 0 and preferred(found, text) == null;
}

/// Added by OpenReliant: an optional file in the game folder with extra gamepad mappings in SDL's
/// format, for gamepads missing from SDL's database (`addMappings`).
pub const mappings_name = "gamecontrollerdb.txt";

/// What `JoyConfig` in `starlancer.ini` says of the controller the game uses, in settings added by
/// OpenReliant: `Joystick`, part of the name of the controller to choose (`choose`);
/// `ThrottleAxis` and `TwistAxis`, the axes of a joystick's throttle and twist; and
/// `ThrottleInvert`, which reverses its throttle.
pub const Setup = struct {
    preference: ?[]const u8 = null,
    throttle: Choice = .guess,
    twist: Choice = .guess,
    throttle_inverted: bool = false,

    /// The setup `settings_file` gives, each setting it lacks left to the automatic choice.
    pub fn read(settings_file: Profile) Setup {
        const section = interface.joy_section;
        return .{
            .preference = settings_file.value(section, "Joystick"),
            .throttle = .parse(settings_file.value(section, "ThrottleAxis")),
            .twist = .parse(settings_file.value(section, "TwistAxis")),
            .throttle_inverted = settings_file.int(section, "ThrottleInvert", 0) != 0,
        };
    }
};

test Setup {
    try std.testing.expectEqual(Setup{}, Setup.read(.empty));
    const given = Setup.read(.{ .text = "[JoyConfig]\nJoystick=T.16000M\nThrottleAxis=3\nTwistAxis=-1\nThrottleInvert=1\n" });
    try std.testing.expectEqualStrings("T.16000M", given.preference.?);
    try std.testing.expectEqual(Choice{ .axis = 3 }, given.throttle);
    try std.testing.expectEqual(Choice.none, given.twist);
    try std.testing.expect(given.throttle_inverted);
}

/// The value of `ThrottleAxis` or `TwistAxis` in `JoyConfig` (settings added by OpenReliant): an
/// SDL axis number, starting at 0 as `openreliant joysticks` shows it; -1 for none; or no entry,
/// which keeps the automatic choice.
pub const Choice = union(enum) {
    guess,
    none,
    axis: u8,

    pub fn parse(value: ?[]const u8) Choice {
        const text = std.mem.trim(u8, value orelse return .guess, " \t");
        const number = std.fmt.parseInt(i16, text, 10) catch return .guess;
        if (number < 0) return .none;
        return .{ .axis = std.math.cast(u8, number) orelse return .none };
    }
};

/// Which of a joystick's axes, by SDL's numbering, are used for X, Y, the throttle (the game's Z
/// axis) and the twist (the game's Rz axis).
pub const Layout = struct {
    x: ?u8 = null,
    y: ?u8 = null,
    throttle: ?u8 = null,
    twist: ?u8 = null,
    /// Reverses the throttle axis (`ThrottleInvert` in `JoyConfig`, added by OpenReliant). The game
    /// expects a throttle's lowest value to mean full throttle, which is what most levers report
    /// when pushed forward.
    throttle_inverted: bool = false,

    /// Guesses the layout of a joystick with `axes` axes from common devices. SDL orders a
    /// joystick's axes the same way on every system (X, Y, Z, Rx, Ry, Rz, then sliders), but
    /// doesn't say which of these a joystick has. X and Y are always the first two. With three
    /// axes, the third is the throttle. With four, the third is the twist and the fourth the
    /// throttle, as on most flight sticks. With more, the third is the throttle and the twist is
    /// the fourth (five axes) or the sixth (six or more), as on HOTAS sets. A standalone throttle
    /// uses its first axis as the throttle. A gamepad SDL has no mapping for uses its third axis as
    /// the twist and has no throttle.
    pub fn guess(axes: u8, sdl_type: c.SDL_JoystickType) Layout {
        if (sdl_type == c.SDL_JOYSTICK_TYPE_THROTTLE) return .{ .throttle = if (axes > 0) 0 else null };
        // A gamepad without an SDL mapping: the left stick steers, the right stick's horizontal
        // axis is the twist, and without a throttle axis the throttle keys and buttons are used.
        if (sdl_type == c.SDL_JOYSTICK_TYPE_GAMEPAD) {
            return .{ .x = if (axes > 0) 0 else null, .y = if (axes > 1) 1 else null, .twist = if (axes > 2) 2 else null };
        }
        var layout: Layout = .{};
        if (axes > 0) layout.x = 0;
        if (axes > 1) layout.y = 1;
        switch (axes) {
            0, 1, 2 => {},
            3 => layout.throttle = 2,
            4 => layout = .{ .x = 0, .y = 1, .twist = 2, .throttle = 3 },
            5 => layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 3 },
            else => layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 5 },
        }
        return layout;
    }

    /// The layout with the throttle and twist overridden from `starlancer.ini`, for a joystick with
    /// `axes` axes.
    pub fn with(layout: Layout, axes: u8, throttle: Choice, twist: Choice) Layout {
        var chosen = layout;
        chosen.throttle = pick(layout.throttle, axes, throttle);
        chosen.twist = pick(layout.twist, axes, twist);
        return chosen;
    }

    fn pick(guessed: ?u8, axes: u8, choice: Choice) ?u8 {
        return switch (choice) {
            .guess => guessed,
            .none => null,
            .axis => |axis| if (axis < axes) axis else null,
        };
    }

    /// Each of the game's axes and the joystick axis it is read from.
    fn sources(layout: Layout) [4]struct { Axis, ?u8 } {
        return .{ .{ .x, layout.x }, .{ .y, layout.y }, .{ .z, layout.throttle }, .{ .rz, layout.twist } };
    }

    /// What a joystick's axes are used for.
    pub const Role = enum { x, y, throttle, twist };

    /// What the game reads axis `index` as, or null for an axis it doesn't read.
    pub fn role(layout: Layout, index: u8) ?Role {
        if (layout.x == index) return .x;
        if (layout.y == index) return .y;
        if (layout.throttle == index) return .throttle;
        if (layout.twist == index) return .twist;
        return null;
    }

    /// The axis used for `which`, or null for none.
    pub fn axisFor(layout: Layout, which: Role) ?u8 {
        return switch (which) {
            .x => layout.x,
            .y => layout.y,
            .throttle => layout.throttle,
            .twist => layout.twist,
        };
    }
};

test "Layout.role" {
    const layout: Layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 4 };
    try std.testing.expectEqual(.throttle, layout.role(2));
    try std.testing.expectEqual(.twist, layout.role(4));
    try std.testing.expectEqual(null, layout.role(3));
    try std.testing.expectEqual(4, layout.axisFor(.twist));
}

/// A hat's position as SDL reports it: one bit per direction.
const Hat = packed struct(u8) {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    _unused: u4 = 0,
};

/// The DirectInput point-of-view value for each hat position: hundredths of a degree clockwise
/// from forward, or centered. Opposite directions cancel out.
const hat_angles: [16]u32 = angles: {
    var angles: [16]u32 = undefined;
    for (&angles, 0..) |*angle, bits| {
        const hat: Hat = @bitCast(@as(u8, bits));
        const across = @as(i8, @intFromBool(hat.right)) - @intFromBool(hat.left);
        const along = @as(i8, @intFromBool(hat.down)) - @intFromBool(hat.up);
        angle.* = switch (along) {
            -1 => switch (across) {
                -1 => 31500,
                0 => 0,
                else => 4500,
            },
            0 => switch (across) {
                -1 => 27000,
                0 => JoystickState.centred,
                else => 9000,
            },
            else => switch (across) {
                -1 => 22500,
                0 => 18000,
                else => 13500,
            },
        };
    }
    break :angles angles;
};

fn pov(hat: Hat) u32 {
    return hat_angles[@as(u4, @truncate(@as(u8, @bitCast(hat))))];
}

/// Scales a raw axis value (-32768 to 32767) the way DirectInput does for the given `range` and
/// `dead_zone` (in hundredths of a percent of the travel from the center): inside the dead zone
/// the result is the center of the range, and outside it the remaining travel is scaled to cover
/// the full range.
pub fn scale(raw: i16, range: [2]i32, dead_zone: u16) i32 {
    const position = @max(@as(f32, @floatFromInt(raw)) / 32767, -1);
    const zone = @as(f32, @floatFromInt(@min(dead_zone, 10000))) / 10000;
    const beyond = @abs(position) - zone;
    const live: f32 = if (beyond <= 0) 0 else std.math.copysign(beyond / (1 - zone), position);
    const low: f32 = @floatFromInt(range[0]);
    const high: f32 = @floatFromInt(range[1]);
    return @intFromFloat(@round((low + high) / 2 + live * (high - low) / 2));
}

/// How far a trigger must be pulled, or the right stick pushed, to count as a button press.
const trigger_press: i16 = 8192;
const stick_press: i16 = 16384;

/// Where each gamepad button is read from: an SDL button, a trigger, or a direction of the right
/// stick.
const Source = union(enum) {
    button: c.SDL_GamepadButton,
    trigger: c.SDL_GamepadAxis,
    stick: struct { axis: c.SDL_GamepadAxis, positive: bool },
};

const sources = std.EnumArray(GamepadButton, Source).init(.{
    .south = .{ .button = c.SDL_GAMEPAD_BUTTON_SOUTH },
    .east = .{ .button = c.SDL_GAMEPAD_BUTTON_EAST },
    .west = .{ .button = c.SDL_GAMEPAD_BUTTON_WEST },
    .north = .{ .button = c.SDL_GAMEPAD_BUTTON_NORTH },
    .back = .{ .button = c.SDL_GAMEPAD_BUTTON_BACK },
    .guide = .{ .button = c.SDL_GAMEPAD_BUTTON_GUIDE },
    .start = .{ .button = c.SDL_GAMEPAD_BUTTON_START },
    .left_stick = .{ .button = c.SDL_GAMEPAD_BUTTON_LEFT_STICK },
    .right_stick = .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_STICK },
    .left_shoulder = .{ .button = c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER },
    .right_shoulder = .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER },
    .dpad_up = .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_UP },
    .dpad_down = .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_DOWN },
    .dpad_left = .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_LEFT },
    .dpad_right = .{ .button = c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT },
    .misc1 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC1 },
    .right_paddle1 = .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1 },
    .left_paddle1 = .{ .button = c.SDL_GAMEPAD_BUTTON_LEFT_PADDLE1 },
    .right_paddle2 = .{ .button = c.SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2 },
    .left_paddle2 = .{ .button = c.SDL_GAMEPAD_BUTTON_LEFT_PADDLE2 },
    .touchpad = .{ .button = c.SDL_GAMEPAD_BUTTON_TOUCHPAD },
    .misc2 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC2 },
    .misc3 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC3 },
    .misc4 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC4 },
    .misc5 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC5 },
    .misc6 = .{ .button = c.SDL_GAMEPAD_BUTTON_MISC6 },
    .left_trigger = .{ .trigger = c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER },
    .right_trigger = .{ .trigger = c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER },
    .right_stick_up = .{ .stick = .{ .axis = c.SDL_GAMEPAD_AXIS_RIGHTY, .positive = false } },
    .right_stick_down = .{ .stick = .{ .axis = c.SDL_GAMEPAD_AXIS_RIGHTY, .positive = true } },
    .right_stick_left = .{ .stick = .{ .axis = c.SDL_GAMEPAD_AXIS_RIGHTX, .positive = false } },
    .right_stick_right = .{ .stick = .{ .axis = c.SDL_GAMEPAD_AXIS_RIGHTX, .positive = true } },
});

comptime {
    // A gamepad's buttons fill the joystick's, one for one.
    std.debug.assert(std.enums.values(GamepadButton).len == JoystickState.max_buttons);
}

/// The gamepad axes the game reads: the left stick as X and Y, and the right stick's horizontal
/// axis as the twist.
const gamepad_axes = [_]struct { Axis, c.SDL_GamepadAxis }{
    .{ .x, c.SDL_GAMEPAD_AXIS_LEFTX },
    .{ .y, c.SDL_GAMEPAD_AXIS_LEFTY },
    .{ .rz, c.SDL_GAMEPAD_AXIS_RIGHTX },
};

/// An open controller, used by the game as its joystick.
pub const Controller = struct {
    handle: Handle,
    /// The axis layout of a plain joystick; gamepads use `gamepad_axes`.
    layout: Layout,
    /// The axis ranges and dead zone the game set.
    ranges: std.EnumArray(Axis, ?[2]i32) = .initFill(null),
    dead_zone: u16 = input.default_dead_zone,
    /// The motors' speeds last sent, low then high, and when (`SDL_GetTicks`).
    rumbled: [2]u16 = .{ 0, 0 },
    rumbled_at: u64 = 0,

    /// How long a rumble runs unless another follows, so that the motors stop soon after the game
    /// stops turning them, as when it pauses.
    const rumble_ms = 100;
    /// How often the motors' speeds are sent at most, while they turn, which spares a wireless
    /// controller a report every frame.
    const rumble_every_ms = 40;

    pub const Handle = union(enum) {
        joystick: *c.SDL_Joystick,
        gamepad: Gamepad,
    };

    /// A gamepad, and the joystick SDL reads it through, taken once as it opens.
    pub const Gamepad = struct {
        pad: *c.SDL_Gamepad,
        joystick: *c.SDL_Joystick,
    };

    /// Opens `found`, applying `setup`'s throttle and twist, and its reversed throttle, to a plain
    /// joystick.
    pub fn open(found: Found, setup: Setup) Error!Controller {
        switch (found.kind) {
            .gamepad => {
                const gamepad = c.SDL_OpenGamepad(found.id) orelse return fail("SDL_OpenGamepad");
                const plain = c.SDL_GetGamepadJoystick(gamepad) orelse {
                    c.SDL_CloseGamepad(gamepad);
                    return fail("SDL_GetGamepadJoystick");
                };
                return .{ .handle = .{ .gamepad = .{ .pad = gamepad, .joystick = plain } }, .layout = .{} };
            },
            .joystick => {
                const plain = c.SDL_OpenJoystick(found.id) orelse return fail("SDL_OpenJoystick");
                const axes: u8 = @intCast(@min(axisCount(plain), std.math.maxInt(u8)));
                var layout = Layout.guess(axes, found.sdl_type).with(axes, setup.throttle, setup.twist);
                layout.throttle_inverted = setup.throttle_inverted;
                return .{ .handle = .{ .joystick = plain }, .layout = layout };
            },
        }
    }

    pub fn close(controller: *Controller) void {
        switch (controller.handle) {
            .joystick => |plain| c.SDL_CloseJoystick(plain),
            .gamepad => |gamepad| c.SDL_CloseGamepad(gamepad.pad),
        }
    }

    /// The underlying SDL joystick (gamepads have one too).
    pub fn sdlJoystick(controller: Controller) *c.SDL_Joystick {
        return switch (controller.handle) {
            .joystick => |plain| plain,
            .gamepad => |gamepad| gamepad.joystick,
        };
    }

    pub fn id(controller: Controller) c.SDL_JoystickID {
        return c.SDL_GetJoystickID(controller.sdlJoystick());
    }

    /// The controller as a joystick device for the game.
    pub fn device(controller: *Controller) input.JoystickDevice {
        return .{ .context = controller, .vtable = &.{
            .capabilities = capabilities,
            .setRange = setRange,
            .setDeadZone = setDeadZone,
            .poll = poll,
            .rumble = rumble,
        } };
    }

    fn capabilities(context: *anyopaque) input.JoystickDevice.Capabilities {
        const controller: *Controller = @ptrCast(@alignCast(context));
        const plain = controller.sdlJoystick();
        const name = c.SDL_GetJoystickName(plain);
        var found: input.JoystickDevice.Capabilities = .{
            .name = if (name != null) std.mem.span(name) else "",
            .axes = .empty,
            .buttons = JoystickState.max_buttons,
            .hats = 1,
            .kind = .gamepad,
            .rumbles = c.SDL_GetBooleanProperty(c.SDL_GetJoystickProperties(plain), c.SDL_PROP_JOYSTICK_CAP_RUMBLE_BOOLEAN, false),
        };
        switch (controller.handle) {
            .gamepad => for (gamepad_axes) |pair| found.axes.insert(pair[0]),
            .joystick => {
                for (controller.layout.sources()) |source| {
                    if (source[1] != null) found.axes.insert(source[0]);
                }
                found.buttons = @intCast(@min(buttonCount(plain), JoystickState.max_buttons));
                found.hats = @intCast(@min(hatCount(plain), JoystickState.max_hats));
                found.kind = .joystick;
            },
        }
        return found;
    }

    /// Turns the motors (`SDL_RumbleJoystick`): their speeds every `rumble_every_ms` at most while
    /// they turn, and a stop as soon as they are to stop.
    fn rumble(context: *anyopaque, motors: input.force.Motors) void {
        const controller: *Controller = @ptrCast(@alignCast(context));
        const speeds: [2]u16 = .{ motorSpeed(motors.low), motorSpeed(motors.high) };
        const now = c.SDL_GetTicks();
        const stopped = std.mem.allEqual(u16, &controller.rumbled, 0);
        if (std.mem.allEqual(u16, &speeds, 0)) {
            if (stopped) return;
        } else if (!stopped and now -% controller.rumbled_at < rumble_every_ms) return;
        controller.rumbled = speeds;
        controller.rumbled_at = now;
        _ = c.SDL_RumbleJoystick(controller.sdlJoystick(), speeds[0], speeds[1], rumble_ms);
    }

    fn setRange(context: *anyopaque, axis: Axis, min: i32, max: i32) void {
        const controller: *Controller = @ptrCast(@alignCast(context));
        controller.ranges.set(axis, .{ min, max });
    }

    fn setDeadZone(context: *anyopaque, zone: u16) void {
        const controller: *Controller = @ptrCast(@alignCast(context));
        controller.dead_zone = zone;
    }

    fn poll(context: *anyopaque, state: *JoystickState) error{Unplugged}!void {
        const controller: *Controller = @ptrCast(@alignCast(context));
        state.* = std.mem.zeroes(JoystickState);
        state.pov = @splat(JoystickState.centred);
        switch (controller.handle) {
            .joystick => |plain| {
                if (!c.SDL_JoystickConnected(plain)) return error.Unplugged;
                for (controller.layout.sources()) |source| {
                    const index = source[1] orelse continue;
                    var raw = c.SDL_GetJoystickAxis(plain, index);
                    if (source[0] == .z and controller.layout.throttle_inverted) raw = ~raw;
                    controller.setAxis(state, source[0], raw);
                }
                const buttons = @min(buttonCount(plain), JoystickState.max_buttons);
                for (state.buttons[0..buttons], 0..) |*button, index| {
                    button.* = if (c.SDL_GetJoystickButton(plain, @intCast(index))) JoystickState.pressed else 0;
                }
                const hats = @min(hatCount(plain), JoystickState.max_hats);
                for (state.pov[0..hats], 0..) |*angle, index| {
                    angle.* = pov(@bitCast(c.SDL_GetJoystickHat(plain, @intCast(index))));
                }
            },
            .gamepad => |held| {
                const gamepad = held.pad;
                if (!c.SDL_GamepadConnected(gamepad)) return error.Unplugged;
                for (gamepad_axes) |pair| controller.setAxis(state, pair[0], c.SDL_GetGamepadAxis(gamepad, pair[1]));
                for (&state.buttons, 0..) |*button, index| {
                    const down = switch (sources.get(@fromBackingInt(@intCast(index)))) {
                        .button => |which| c.SDL_GetGamepadButton(gamepad, which),
                        .trigger => |which| c.SDL_GetGamepadAxis(gamepad, which) >= trigger_press,
                        .stick => |stick| pushed: {
                            const value = c.SDL_GetGamepadAxis(gamepad, stick.axis);
                            break :pushed if (stick.positive) value >= stick_press else value <= -stick_press;
                        },
                    };
                    button.* = if (down) JoystickState.pressed else 0;
                }
                state.pov[0] = pov(.{
                    .up = c.SDL_GetGamepadButton(gamepad, c.SDL_GAMEPAD_BUTTON_DPAD_UP),
                    .right = c.SDL_GetGamepadButton(gamepad, c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT),
                    .down = c.SDL_GetGamepadButton(gamepad, c.SDL_GAMEPAD_BUTTON_DPAD_DOWN),
                    .left = c.SDL_GetGamepadButton(gamepad, c.SDL_GAMEPAD_BUTTON_DPAD_LEFT),
                });
            },
        }
    }

    /// Stores an axis's raw value in the state, scaled to the range the game set. Axes without a
    /// range stay at zero; the game doesn't read them.
    fn setAxis(controller: *Controller, state: *JoystickState, which: Axis, raw: i16) void {
        const range = controller.ranges.get(which) orelse return;
        state.axis(which).* = scale(raw, range, controller.dead_zone);
    }
};

test scale {
    // The center, the dead zone and both ends, for a stick's range and a throttle's.
    try std.testing.expectEqual(0, scale(0, .{ -1000, 1000 }, 1000));
    try std.testing.expectEqual(0, scale(3000, .{ -1000, 1000 }, 1000));
    try std.testing.expectEqual(1000, scale(32767, .{ -1000, 1000 }, 1000));
    try std.testing.expectEqual(-1000, scale(-32768, .{ -1000, 1000 }, 1000));
    try std.testing.expectEqual(500, scale(0, .{ 0, 1000 }, 1000));
    try std.testing.expectEqual(1000, scale(32767, .{ 0, 1000 }, 1000));
    try std.testing.expectEqual(0, scale(-32768, .{ 0, 1000 }, 1000));
    // Outside the dead zone the remaining travel covers the range: halfway there reads as half.
    try std.testing.expectEqual(500, scale(18022, .{ -1000, 1000 }, 1000));
    // Without a dead zone the mapping is linear; with a 100% dead zone the axis never moves.
    try std.testing.expectEqual(100, scale(3277, .{ -1000, 1000 }, 0));
    try std.testing.expectEqual(0, scale(32767, .{ -1000, 1000 }, 10000));
}

test pov {
    try std.testing.expectEqual(JoystickState.centred, pov(.{}));
    try std.testing.expectEqual(0, pov(.{ .up = true }));
    try std.testing.expectEqual(4500, pov(.{ .up = true, .right = true }));
    try std.testing.expectEqual(9000, pov(.{ .right = true }));
    try std.testing.expectEqual(18000, pov(.{ .down = true }));
    try std.testing.expectEqual(22500, pov(.{ .down = true, .left = true }));
    try std.testing.expectEqual(27000, pov(.{ .left = true }));
    try std.testing.expectEqual(31500, pov(.{ .left = true, .up = true }));
    // Opposite directions cancel out.
    try std.testing.expectEqual(JoystickState.centred, pov(.{ .up = true, .down = true }));
    try std.testing.expectEqual(9000, pov(.{ .up = true, .down = true, .right = true }));
    // SDL's hat constants use the same bits.
    try std.testing.expectEqual(27000, pov(@bitCast(@as(u8, c.SDL_HAT_LEFT))));
    try std.testing.expectEqual(4500, pov(@bitCast(@as(u8, c.SDL_HAT_RIGHTUP))));
}

test Layout {
    const unknown = c.SDL_JOYSTICK_TYPE_UNKNOWN;
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1 }, Layout.guess(2, unknown));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .throttle = 2 }, Layout.guess(3, unknown));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .twist = 2, .throttle = 3 }, Layout.guess(4, unknown));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .throttle = 2, .twist = 3 }, Layout.guess(5, unknown));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .throttle = 2, .twist = 5 }, Layout.guess(7, unknown));
    try std.testing.expectEqual(Layout{ .throttle = 0 }, Layout.guess(3, c.SDL_JOYSTICK_TYPE_THROTTLE));
    // `starlancer.ini` can move or remove the throttle and twist, within the joystick's axes.
    const stick = Layout.guess(4, unknown);
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .twist = 3, .throttle = 2 }, stick.with(4, .{ .axis = 2 }, .{ .axis = 3 }));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .twist = 2 }, stick.with(4, .none, .guess));
    try std.testing.expectEqual(Layout{ .x = 0, .y = 1, .twist = 2 }, stick.with(4, .{ .axis = 9 }, .guess));
}

test "an inverted throttle" {
    // `~` reverses the raw value: -32768 and 32767 swap, and the center stays the same.
    try std.testing.expectEqual(1000, scale(~@as(i16, -32768), .{ 0, 1000 }, 1000));
    try std.testing.expectEqual(0, scale(~@as(i16, 32767), .{ 0, 1000 }, 1000));
    try std.testing.expectEqual(500, scale(~@as(i16, 0), .{ 0, 1000 }, 1000));
}

test Choice {
    try std.testing.expectEqual(Choice.guess, Choice.parse(null));
    try std.testing.expectEqual(Choice.guess, Choice.parse("slider"));
    try std.testing.expectEqual(Choice.none, Choice.parse("-1"));
    try std.testing.expectEqual(Choice{ .axis = 3 }, Choice.parse(" 3 "));
}

test choose {
    const pad: Found = .{ .id = 1, .name = "Xbox Wireless Controller", .kind = .gamepad, .sdl_type = c.SDL_JOYSTICK_TYPE_GAMEPAD, .vendor = 0x045E, .product = 0x0B13 };
    const throttle: Found = .{ .id = 2, .name = "TWCS Throttle", .kind = .joystick, .sdl_type = c.SDL_JOYSTICK_TYPE_THROTTLE, .vendor = 0x044F, .product = 0xB687 };
    const stick: Found = .{ .id = 3, .name = "T.16000M", .kind = .joystick, .sdl_type = c.SDL_JOYSTICK_TYPE_FLIGHT_STICK, .vendor = 0x044F, .product = 0xB10A };
    // A stick is preferred over a gamepad, and a standalone throttle is only used on its own.
    try std.testing.expectEqual(3, choose(&.{ pad, throttle, stick }, null).?.id);
    try std.testing.expectEqual(1, choose(&.{ throttle, pad }, null).?.id);
    try std.testing.expectEqual(2, choose(&.{throttle}, null).?.id);
    try std.testing.expectEqual(null, choose(&.{}, null));
    // `Joystick` in `starlancer.ini` selects by name.
    try std.testing.expectEqual(1, choose(&.{ pad, stick }, "xbox").?.id);
    try std.testing.expectEqual(3, choose(&.{ pad, stick }, "nothing like it").?.id);
    // A preference that matches nothing is reported, and an empty one counts as none.
    try std.testing.expect(unmatched(&.{ pad, stick }, "nothing like it"));
    try std.testing.expect(!unmatched(&.{ pad, stick }, "XBOX"));
    try std.testing.expect(!unmatched(&.{ pad, stick }, ""));
    try std.testing.expect(!unmatched(&.{ pad, stick }, null));
}

/// Initializes SDL's joystick support for the tests; null if the system doesn't support it.
fn testInit() ?void {
    init(.tool) catch return null;
}

/// Creates a virtual SDL controller for the tests: a joystick of `sdl_type` with the given numbers
/// of axes, buttons and hats, or, with the masks, a gamepad with those controls.
fn attachVirtual(sdl_type: c.SDL_JoystickType, axes: u16, buttons: u16, hats: u16, masks: ?[2]u32) !c.SDL_JoystickID {
    var desc = std.mem.zeroes(c.SDL_VirtualJoystickDesc);
    desc.version = @sizeOf(c.SDL_VirtualJoystickDesc);
    desc.type = @intCast(sdl_type);
    desc.naxes = axes;
    desc.nbuttons = buttons;
    desc.nhats = hats;
    desc.name = "OpenReliant Test Controller";
    if (masks) |both| {
        desc.button_mask = both[0];
        desc.axis_mask = both[1];
    }
    const id = c.SDL_AttachVirtualJoystick(&desc);
    if (id == 0) return fail("SDL_AttachVirtualJoystick");
    return id;
}

test "reading a flight stick" {
    testInit() orelse return error.SkipZigTest;
    defer deinit();
    const id = try attachVirtual(c.SDL_JOYSTICK_TYPE_FLIGHT_STICK, 4, 12, 1, null);
    defer _ = c.SDL_DetachVirtualJoystick(id);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const found = choose(try attached(arena_state.allocator()), "OpenReliant Test").?;
    try std.testing.expectEqual(input.JoystickDevice.Kind.joystick, found.kind);
    var controller: Controller = try .open(found, .{});
    defer controller.close();
    var joystick: input.Joystick = .{};
    joystick.open(controller.device(), input.default_dead_zone);
    // Four axes: X, Y, the twist, and the throttle last.
    try std.testing.expect(joystick.axes.x and joystick.axes.y and joystick.axes.z and joystick.axes.rz);
    try std.testing.expectEqual(12, joystick.buttons);
    try std.testing.expectEqual(1, joystick.hats);

    const virtual = controller.sdlJoystick();
    _ = c.SDL_SetJoystickVirtualAxis(virtual, 0, 32767);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, 1, -32768);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, 2, 1000);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, 3, -32768);
    _ = c.SDL_SetJoystickVirtualButton(virtual, 0, true);
    _ = c.SDL_SetJoystickVirtualButton(virtual, 11, true);
    _ = c.SDL_SetJoystickVirtualHat(virtual, 0, c.SDL_HAT_LEFT);
    update();
    joystick.read();
    const state = joystick.state;
    try std.testing.expectEqual(1000, state.x);
    try std.testing.expectEqual(-1000, state.y);
    // The twist is inside the dead zone; the throttle is pulled all the way back.
    try std.testing.expectEqual(0, state.rz);
    try std.testing.expectEqual(0, state.z);
    try std.testing.expectEqual(JoystickState.pressed, state.buttons[0]);
    try std.testing.expectEqual(JoystickState.pressed, state.buttons[11]);
    try std.testing.expectEqual(0, state.buttons[1]);
    try std.testing.expectEqual(27000, state.pov[0]);
    try std.testing.expectEqual(JoystickState.centred, state.pov[1]);

    // Once disconnected, it reads as idle.
    _ = c.SDL_DetachVirtualJoystick(id);
    update();
    joystick.read();
    try std.testing.expectEqual(null, joystick.device);
}

test "reading a gamepad" {
    testInit() orelse return error.SkipZigTest;
    defer deinit();
    const all_buttons: u32 = (1 << c.SDL_GAMEPAD_BUTTON_COUNT) - 1;
    const all_axes: u32 = (1 << c.SDL_GAMEPAD_AXIS_COUNT) - 1;
    const id = try attachVirtual(c.SDL_JOYSTICK_TYPE_GAMEPAD, c.SDL_GAMEPAD_AXIS_COUNT, c.SDL_GAMEPAD_BUTTON_COUNT, 0, .{ all_buttons, all_axes });
    defer _ = c.SDL_DetachVirtualJoystick(id);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const found = choose(try attached(arena_state.allocator()), "OpenReliant Test").?;
    try std.testing.expectEqual(input.JoystickDevice.Kind.gamepad, found.kind);
    var controller: Controller = try .open(found, .{});
    defer controller.close();
    var joystick: input.Joystick = .{};
    joystick.open(controller.device(), input.default_dead_zone);
    try std.testing.expectEqual(input.JoystickDevice.Kind.gamepad, joystick.kind);
    try std.testing.expect(joystick.axes.x and joystick.axes.y and joystick.axes.rz and !joystick.axes.z);

    const virtual = controller.sdlJoystick();
    try std.testing.expectEqual(c.SDL_GetGamepadJoystick(controller.handle.gamepad.pad), virtual);
    try std.testing.expectEqual(found.id, controller.id());
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_LEFTX, -32768);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_RIGHTX, 32767);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_RIGHTY, -32768);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, 32767);
    _ = c.SDL_SetJoystickVirtualAxis(virtual, c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER, -32768);
    _ = c.SDL_SetJoystickVirtualButton(virtual, c.SDL_GAMEPAD_BUTTON_SOUTH, true);
    _ = c.SDL_SetJoystickVirtualButton(virtual, c.SDL_GAMEPAD_BUTTON_DPAD_DOWN, true);
    update();
    joystick.read();
    const state = joystick.state;
    try std.testing.expectEqual(-1000, state.x);
    try std.testing.expectEqual(1000, state.rz);
    const button = struct {
        fn down(read: JoystickState, which: GamepadButton) bool {
            return read.buttons[@backingInt(which)] != 0;
        }
    }.down;
    try std.testing.expect(button(state, .south));
    try std.testing.expect(button(state, .right_trigger) and !button(state, .left_trigger));
    try std.testing.expect(button(state, .right_stick_up) and !button(state, .right_stick_down));
    try std.testing.expect(button(state, .right_stick_right));
    try std.testing.expectEqual(18000, state.pov[0]);
}

test "controllers of many kinds" {
    testInit() orelse return error.SkipZigTest;
    defer deinit();
    const all_buttons: u32 = (1 << c.SDL_GAMEPAD_BUTTON_COUNT) - 1;
    const all_axes: u32 = (1 << c.SDL_GAMEPAD_AXIS_COUNT) - 1;
    const Model = struct {
        name: [:0]const u8,
        sdl_type: c.SDL_JoystickType,
        vendor: u16,
        product: u16,
        axes: u16,
        buttons: u16,
        hats: u16,
        gamepad: bool = false,
        /// What the game should see: the kind of device, its axes, and its buttons and hats.
        kind: input.JoystickDevice.Kind,
        game_axes: []const Axis,
        game_buttons: u8,
        game_hats: u8,
    };
    const models = [_]Model{
        .{ .name = "Xbox 360 Controller", .sdl_type = c.SDL_JOYSTICK_TYPE_GAMEPAD, .vendor = 0x045E, .product = 0x028E, .axes = c.SDL_GAMEPAD_AXIS_COUNT, .buttons = c.SDL_GAMEPAD_BUTTON_COUNT, .hats = 0, .gamepad = true, .kind = .gamepad, .game_axes = &.{ .x, .y, .rz }, .game_buttons = 32, .game_hats = 1 },
        .{ .name = "DualSense Wireless Controller", .sdl_type = c.SDL_JOYSTICK_TYPE_GAMEPAD, .vendor = 0x054C, .product = 0x0CE6, .axes = c.SDL_GAMEPAD_AXIS_COUNT, .buttons = c.SDL_GAMEPAD_BUTTON_COUNT, .hats = 0, .gamepad = true, .kind = .gamepad, .game_axes = &.{ .x, .y, .rz }, .game_buttons = 32, .game_hats = 1 },
        .{ .name = "Logitech Extreme 3D Pro", .sdl_type = c.SDL_JOYSTICK_TYPE_FLIGHT_STICK, .vendor = 0x046D, .product = 0xC215, .axes = 4, .buttons = 12, .hats = 1, .kind = .joystick, .game_axes = &.{ .x, .y, .z, .rz }, .game_buttons = 12, .game_hats = 1 },
        .{ .name = "Saitek X52 Flight Control System", .sdl_type = c.SDL_JOYSTICK_TYPE_FLIGHT_STICK, .vendor = 0x06A3, .product = 0x0255, .axes = 7, .buttons = 39, .hats = 3, .kind = .joystick, .game_axes = &.{ .x, .y, .z, .rz }, .game_buttons = 32, .game_hats = 3 },
        .{ .name = "CH Products Fighterstick", .sdl_type = c.SDL_JOYSTICK_TYPE_UNKNOWN, .vendor = 0x068E, .product = 0x00F3, .axes = 3, .buttons = 8, .hats = 4, .kind = .joystick, .game_axes = &.{ .x, .y, .z }, .game_buttons = 8, .game_hats = 4 },
        .{ .name = "Gameport Adapter Stick", .sdl_type = c.SDL_JOYSTICK_TYPE_UNKNOWN, .vendor = 0x1209, .product = 0x0001, .axes = 2, .buttons = 4, .hats = 0, .kind = .joystick, .game_axes = &.{ .x, .y }, .game_buttons = 4, .game_hats = 0 },
        .{ .name = "TWCS Throttle", .sdl_type = c.SDL_JOYSTICK_TYPE_THROTTLE, .vendor = 0x044F, .product = 0xB687, .axes = 5, .buttons = 14, .hats = 1, .kind = .joystick, .game_axes = &.{.z}, .game_buttons = 14, .game_hats = 1 },
    };
    var ids: [models.len]c.SDL_JoystickID = undefined;
    for (models, &ids) |model, *id| {
        var desc = std.mem.zeroes(c.SDL_VirtualJoystickDesc);
        desc.version = @sizeOf(c.SDL_VirtualJoystickDesc);
        desc.type = @intCast(model.sdl_type);
        desc.vendor_id = model.vendor;
        desc.product_id = model.product;
        desc.naxes = model.axes;
        desc.nbuttons = model.buttons;
        desc.nhats = model.hats;
        desc.name = model.name;
        if (model.gamepad) {
            desc.button_mask = all_buttons;
            desc.axis_mask = all_axes;
        }
        id.* = c.SDL_AttachVirtualJoystick(&desc);
        try std.testing.expect(id.* != 0);
    }
    defer for (ids) |id| {
        _ = c.SDL_DetachVirtualJoystick(id);
    };

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const found = try attached(arena_state.allocator());
    for (models, ids) |model, id| {
        const each = for (found) |candidate| {
            if (candidate.id == id) break candidate;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(model.kind, each.kind);
        var controller: Controller = try .open(each, .{});
        defer controller.close();
        var joystick: input.Joystick = .{};
        joystick.open(controller.device(), input.default_dead_zone);
        var axes: std.EnumSet(Axis) = .empty;
        inline for (@typeInfo(input.JoystickAxes).@"struct".field_names) |name| {
            if (@field(joystick.axes, name)) axes.insert(@field(Axis, name));
        }
        const expected: std.EnumSet(Axis) = .initMany(model.game_axes);
        if (!axes.eql(expected)) {
            std.debug.print("{s}: the game reads the wrong axes\n", .{model.name});
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(model.game_buttons, joystick.buttons);
        try std.testing.expectEqual(model.game_hats, joystick.hats);
    }
    // With all of them connected, the game uses the flight stick.
    var ours: std.ArrayList(Found) = .empty;
    for (found) |each| {
        for (ids) |id| {
            if (each.id == id) try ours.append(arena_state.allocator(), each);
        }
    }
    try std.testing.expectEqualStrings("Logitech Extreme 3D Pro", choose(ours.items, null).?.name);
}
