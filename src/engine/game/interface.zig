//! `C:\lancer\game\interface.cpp`: the front end's screens and the settings they manage. Ported so
//! far: loading the input settings and bindings from `starlancer.ini` (`load_key_config`), the main
//! menu (`main_menu`) with its dialog (`dialog`), the pilot roster (`pilot_roster`) and the saved
//! games (`saved_games`), on the front end's screen (`canvas`); opening the discs' archives
//! (`disc`); and the Reliant's rooms
//! (`rooms`), with a new pilot's induction (`induction`), the in-game options
//! (`in_game_options`) and the briefing (`briefing`); and the restart screen after a mission lost
//! (`restart`).

const std = @import("std");

pub const briefing = @import("interface/briefing.zig");
pub const canvas = @import("interface/canvas.zig");
pub const dialog = @import("interface/dialog.zig");
pub const disc = @import("interface/disc.zig");
pub const in_game_options = @import("interface/in_game_options.zig");
pub const induction = @import("interface/induction.zig");
pub const main_menu = @import("interface/main_menu.zig");
pub const pilot_roster = @import("interface/pilot_roster.zig");
pub const restart = @import("interface/restart.zig");
pub const rooms = @import("interface/rooms.zig");
pub const saved_games = @import("interface/saved_games.zig");

const input = @import("../input.zig");
const controls = input.controls;
const Modifier = input.ControlBinding.Modifier;
const profile = @import("../profile.zig");
const Profile = profile.Profile;

/// The `starlancer.ini` sections with the input settings and bindings.
const key_section = "KeyConfig";
pub const joy_section = "JoyConfig";

/// The buffer `load_key_config` reads each binding into: 128 bytes, including the terminator.
const Buffer = [0x80]u8;

/// The prefix of a value that names a joystick button, followed by the button number.
const button_name = "JOY BUTTON ";

/// The modifier names used in values. The key's scan code follows the name and a space.
const modifier_names = [_]struct { name: []const u8, modifier: Modifier }{
    .{ .name = "SHIFT", .modifier = .shift },
    .{ .name = "CONTROL", .modifier = .control },
    .{ .name = "ALT", .modifier = .alt },
};

/// `load_key_config` (`0x0042C800`): loads the input settings from the `KeyConfig` section of
/// `starlancer.ini`, then each action's bindings from both sections, using the action's name as the
/// key. If `Controller` is 0 but there is no joystick, the keyboard is used instead.
///
/// A `KeyConfig` value is either a key, as a decimal scan code optionally preceded by `SHIFT `,
/// `CONTROL ` or `ALT `, or `JOY BUTTON ` and a button number starting at 0. A `JoyConfig` value is
/// a button, and overrides the one from `KeyConfig`. A missing entry keeps the default binding.
///
/// Two bugs in the original are fixed; files the game writes itself load the same either way. When
/// the `KeyConfig` entry has a modifier, the original checks the `JoyConfig` value for
/// `JOY BUTTON ` at an offset of the modifier's length, so such an action can never get a button;
/// OpenReliant checks from the start of the value. And when `JoyConfig` has no entry, the original
/// falls back to the action's previous button instead of the one `KeyConfig` just set; OpenReliant
/// keeps the one from `KeyConfig`.
///
/// Each call starts from `input.defaultBindings`, so OpenReliant can load the file again when a
/// controller is connected or disconnected. Added by OpenReliant: gamepads get their own default
/// bindings and `TwistEnable` defaults to 1 for them, so the right stick rolls; and `DeadZone` in
/// `JoyConfig` sets the joystick's dead zone (`deadZone`).
pub fn loadKeyConfig(devices: *input.Devices, settings_file: Profile) void {
    const joystick = devices.joystick;
    const gamepad = joystick.device != null and joystick.kind == .gamepad;
    const settings = &devices.settings;
    settings.force_feedback = settings_file.int(key_section, "ForceFeedback", 1) != 0;
    settings.joystick_invert = settings_file.int(key_section, "JoystickInvert", 1) != 0;
    settings.hat_enabled = settings_file.int(key_section, "HatEnable", 1) != 0;
    settings.twist_enabled = settings_file.int(key_section, "TwistEnable", @intFromBool(gamepad)) != 0;
    settings.control_mode = @enumFromInt(settings_file.int(key_section, "Controller", 0));
    if (settings.control_mode == .joystick and joystick.device == null) settings.control_mode = .keyboard;
    settings.dead_zone = deadZone(settings_file);

    devices.bindings = input.defaultBindings(joystick.kind);
    for (&devices.bindings.values) |*binding| {
        var default_buffer: [32]u8 = undefined;
        const default = defaultValue(&default_buffer, binding.*);
        var buffer: Buffer = @splat(0);
        copy(&buffer, settings_file.string(key_section, binding.name, default, buffer.len));
        binding.button = null;
        var joy_default = default;
        if (std.mem.eql(u8, buffer[0..button_name.len], button_name)) {
            binding.button = buttonNumber(read(buffer[button_name.len..]));
            joy_default = std.mem.sliceTo(&buffer, 0);
        } else {
            binding.modifier = .none;
            var skipped: usize = 0;
            for (modifier_names) |named| {
                if (!std.mem.eql(u8, buffer[0..named.name.len], named.name)) continue;
                binding.modifier = named.modifier;
                skipped = named.name.len + 1;
                break;
            }
            binding.key = @truncate(@as(u32, @bitCast(read(buffer[skipped..]))));
        }
        var joy_buffer: Buffer = @splat(0);
        copy(&joy_buffer, settings_file.string(joy_section, binding.name, joy_default, joy_buffer.len));
        if (std.mem.eql(u8, joy_buffer[0..button_name.len], button_name)) {
            binding.button = buttonNumber(read(joy_buffer[button_name.len..]));
        }
    }
}

/// The joystick dead zone from `DeadZone` in `JoyConfig` (added by OpenReliant), given as a
/// percentage of each axis's travel from the center, 10 by default as in the original. Returned in
/// hundredths of a percent, the unit DirectInput uses.
pub fn deadZone(settings_file: Profile) u16 {
    const percent: u16 = @min(settings_file.int(joy_section, "DeadZone", input.default_dead_zone / 100), 100);
    return percent * 100;
}

/// A binding formatted the way the game writes it, which is also the default when the file has no
/// entry: `JOY BUTTON ` and the button, or the key's scan code after the modifier's name.
fn defaultValue(buffer: *[32]u8, binding: controls.Binding) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    // The longest value, `CONTROL -32768`, fits the buffer with room to spare.
    if (binding.button) |button| {
        writer.print(button_name ++ "{d}", .{button}) catch {};
    } else {
        const code: i16 = @bitCast(binding.key);
        for (modifier_names) |named| {
            if (named.modifier == binding.modifier) writer.print("{s} ", .{named.name}) catch {};
        }
        writer.print("{d}", .{code}) catch {};
    }
    return writer.buffered();
}

/// Copies a value into the buffer with a terminator, as `GetPrivateProfileStringA` does. Bytes
/// after the terminator keep what the previous value left there.
fn copy(buffer: *Buffer, value: []const u8) void {
    @memcpy(buffer[0..value.len], value);
    buffer[value.len] = 0;
}

/// `atol` on the buffer from `text` up to the terminator.
fn read(text: []const u8) i32 {
    return profile.atol(std.mem.sliceTo(text, 0));
}

/// Converts a button number for the binding: -1, or any number that doesn't fit in a byte, means no
/// button.
fn buttonNumber(number: i32) ?u8 {
    return std.math.cast(u8, number);
}

test loadKeyConfig {
    var devices: input.Devices = .{};
    const settings_file: Profile = .{ .text =
        \\[KeyConfig]
        \\JoystickInvert=0
        \\TwistEnable=1
        \\Controller=0
        \\FIRE LASERS=JOY BUTTON 5
        \\LAUNCH MISSILE=JOY BUTTON 7
        \\AFTERBURNERS=15
        \\NEXT ENEMY TARGET=SHIFT 19
        \\SMART TARGET=CONTROL 18
        \\EJECT=ALT 88
        \\[JoyConfig]
        \\FIRE LASERS=JOY BUTTON 5
        \\AFTERBURNERS=JOY BUTTON 9
        \\NEXT ENEMY TARGET=JOY BUTTON 2
        \\DeadZone=4
        \\
    };
    loadKeyConfig(&devices, settings_file);
    const settings = devices.settings;
    try std.testing.expect(!settings.joystick_invert and settings.twist_enabled and settings.hat_enabled);
    // Without a joystick, the keyboard is used.
    try std.testing.expectEqual(input.ControlMode.keyboard, settings.control_mode);
    try std.testing.expectEqual(400, settings.dead_zone);

    const bindings = devices.bindings;
    // A button in both sections, as the game writes them, keeps the action's key.
    try std.testing.expectEqual(5, bindings.get(.fire_lasers).button.?);
    try std.testing.expectEqual(controls.binding(.fire_lasers).key, bindings.get(.fire_lasers).key);
    // A button only in `KeyConfig` is kept too (a fix; the original restores the old button).
    try std.testing.expectEqual(7, bindings.get(.launch_missile).button.?);
    // A key in `KeyConfig` and a button in `JoyConfig`.
    try std.testing.expectEqual(15, bindings.get(.afterburners).key);
    try std.testing.expectEqual(9, bindings.get(.afterburners).button.?);
    // A key with a modifier can also have a button from `JoyConfig` (a fix; the original can't).
    try std.testing.expectEqual(Modifier.shift, bindings.get(.next_enemy_target).modifier);
    try std.testing.expectEqual(19, bindings.get(.next_enemy_target).key);
    try std.testing.expectEqual(2, bindings.get(.next_enemy_target).button.?);
    try std.testing.expectEqual(Modifier.control, bindings.get(.smart_target).modifier);
    try std.testing.expectEqual(Modifier.alt, bindings.get(.eject).modifier);
    try std.testing.expectEqual(88, bindings.get(.eject).key);
    // Missing entries keep the default keys, modifiers and buttons.
    for (std.enums.values(controls.Action)) |action| {
        switch (action) {
            .fire_lasers, .launch_missile, .afterburners, .next_enemy_target, .smart_target, .eject => continue,
            else => {},
        }
        const default = controls.binding(action);
        try std.testing.expectEqual(default.key, bindings.get(action).key);
        try std.testing.expectEqual(default.modifier, bindings.get(action).modifier);
        try std.testing.expectEqual(default.button, bindings.get(action).button);
    }
}

test "an empty settings file keeps the game's defaults" {
    var devices: input.Devices = .{};
    loadKeyConfig(&devices, .empty);
    const settings = devices.settings;
    try std.testing.expect(settings.joystick_invert and settings.hat_enabled and settings.force_feedback);
    try std.testing.expect(!settings.twist_enabled);
    try std.testing.expectEqual(input.default_dead_zone, settings.dead_zone);
    for (std.enums.values(controls.Action)) |action| {
        const default = controls.binding(action);
        try std.testing.expectEqual(default.key, devices.bindings.get(action).key);
        try std.testing.expectEqual(default.modifier, devices.bindings.get(action).modifier);
        try std.testing.expectEqual(default.button, devices.bindings.get(action).button);
    }
}

test read {
    // Up to the terminator, past which the buffer keeps what an earlier value left.
    try std.testing.expectEqual(57, read("57\x0099"));
    try std.testing.expectEqual(-12, read("-12"));
}

test deadZone {
    try std.testing.expectEqual(1000, deadZone(.empty));
    try std.testing.expectEqual(0, deadZone(.{ .text = "[JoyConfig]\nDeadZone=0\n" }));
    try std.testing.expectEqual(10000, deadZone(.{ .text = "[JoyConfig]\nDeadZone=250\n" }));
}

test {
    _ = briefing;
    _ = canvas;
    _ = dialog;
    _ = disc;
    _ = in_game_options;
    _ = induction;
    _ = main_menu;
    _ = pilot_roster;
    _ = restart;
    _ = rooms;
    _ = saved_games;
}
