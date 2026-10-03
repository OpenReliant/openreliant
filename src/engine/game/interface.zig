//! `C:\lancer\game\interface.cpp`: the front end's screens and the settings they manage. Ported so
//! far: loading and saving the input settings and bindings in `starlancer.ini` (`load_key_config`,
//! `save_key_config`), the main menu (`main_menu`) with its dialog (`dialog`), GAME OPTIONS
//! (`game_options`), the controls on OpenReliant's settings screen (`settings`), its mods screen
//! (`mod_manager`), the pilot roster
//! (`pilot_roster`) and the saved games (`saved_games`), on the front end's screen (`canvas`);
//! opening the discs' archives (`disc`); and the Reliant's rooms (`rooms`), with a new pilot's
//! induction (`induction`), the locker (`locker`), the CD player (`cd_player`), the in-game options
//! (`in_game_options`) and the briefing (`briefing`); and the restart screen after a mission lost
//! (`restart`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const briefing = @import("interface/briefing.zig");
pub const canvas = @import("interface/canvas.zig");
pub const cd_player = @import("interface/cd_player.zig");
pub const dialog = @import("interface/dialog.zig");
pub const disc = @import("interface/disc.zig");
pub const game_options = @import("interface/game_options.zig");
pub const in_game_options = @import("interface/in_game_options.zig");
pub const induction = @import("interface/induction.zig");
pub const locker = @import("interface/locker.zig");
pub const main_menu = @import("interface/main_menu.zig");
pub const mod_manager = @import("interface/mod_manager.zig");
pub const mod_options = @import("interface/mod_options.zig");
pub const pilot_roster = @import("interface/pilot_roster.zig");
pub const restart = @import("interface/restart.zig");
pub const rooms = @import("interface/rooms.zig");
pub const saved_games = @import("interface/saved_games.zig");
pub const settings = @import("interface/settings.zig");

const input = @import("../input.zig");
const controls = input.controls;
const Modifier = input.ControlBinding.Modifier;
const profile = @import("../profile.zig");
const Profile = profile.Profile;

/// The `starlancer.ini` sections with the input settings and bindings: the settings and the keys,
/// a joystick's buttons, and a gamepad's (`buttonSection`).
const key_section = "KeyConfig";
pub const joy_section = "JoyConfig";
const gamepad_section = "GamepadConfig";

/// The section a controller of `kind` keeps its buttons in: `JoyConfig` for a joystick, as the game
/// keeps them, and for a gamepad, whose buttons OpenReliant numbers as its own
/// (`input.GamepadButton`), `GamepadConfig`, which the game never reads.
fn buttonSection(kind: input.JoystickDevice.Kind) []const u8 {
    return switch (kind) {
        .joystick => joy_section,
        .gamepad => gamepad_section,
    };
}

/// The input settings `KeyConfig` holds, by the names the game reads and writes them under.
pub const Setting = enum {
    force_feedback,
    joystick_invert,
    hat_enable,
    twist_enable,
    controller,

    /// Its key in `KeyConfig`.
    pub fn key(setting: Setting) []const u8 {
        return switch (setting) {
            .force_feedback => "ForceFeedback",
            .joystick_invert => "JoystickInvert",
            .hat_enable => "HatEnable",
            .twist_enable => "TwistEnable",
            .controller => "Controller",
        };
    }

    /// Its value in `held`, as the file holds it.
    fn of(setting: Setting, held: input.Settings) u32 {
        return switch (setting) {
            .force_feedback => @intFromBool(held.force_feedback),
            .joystick_invert => @intFromBool(held.joystick_invert),
            .hat_enable => @intFromBool(held.hat_enabled),
            .twist_enable => @intFromBool(held.twist_enabled),
            .controller => @intFromEnum(held.control_mode),
        };
    }

    /// Sets it in `held` from `value`, as the file holds it.
    fn set(setting: Setting, held: *input.Settings, value: u32) void {
        switch (setting) {
            .force_feedback => held.force_feedback = value != 0,
            .joystick_invert => held.joystick_invert = value != 0,
            .hat_enable => held.hat_enabled = value != 0,
            .twist_enable => held.twist_enabled = value != 0,
            .controller => held.control_mode = @enumFromInt(value),
        }
    }
};

/// Writes `setting` of `held` to `KeyConfig`, as `save_key_config` writes each, and the controls
/// screen each the moment it changes (`0x0042BBB4` to `0x0042BF8C`).
pub fn saveSetting(held: input.Settings, settings_file: *profile.File, setting: Setting) Allocator.Error!void {
    try settings_file.writeInt(key_section, setting.key(), setting.of(held));
}

/// The file the game reads its default bindings from, in the game folder (`game_directory`, from
/// `%sdefault.txt` at `0x004E8598`). A mod file with the same name replaces it.
pub const defaults_name = "default.txt";

/// `key_config_defaults` (`0x0042CAA0`), as the controls screen's RESET DEFAULTS calls it, and
/// `load_key_config` starts from: the input settings at their defaults, force feedback on, pitch
/// as the stick has it, the hat on, the twist not rolling, and the joystick steering; and the
/// bindings `default.txt` gives (`input.Devices.defaults_file`), each action's by its name
/// (`defaultBinding`). Every button is cleared first, so that an action has a button only where
/// the file gives it one, and an action the file doesn't name keeps the executable's key
/// (`input.defaultBindings`). A gamepad's buttons are its own. The dead zone stays as it is.
///
/// **Fix:** the game chooses the joystick only where one is attached, and the keyboard where not
/// (`0x0042CAF2`), which its controls screen then writes, so that a game started without the
/// joystick steers with the keyboard ever after. OpenReliant chooses the joystick, which steers with
/// the keyboard while none is attached (`input.Devices.controlMode`).
///
/// **Fix:** the game turns off the twist's setting (`twist_setting`), which the check box shows,
/// but leaves the twist rolling (`twist_enabled`) until the bindings load again. OpenReliant turns
/// the twist off.
///
/// **Improvement:** where the game's folder has no `default.txt`, OpenReliant keeps the
/// executable's bindings, buttons and all, where the game leaves every action without a button.
pub fn keyConfigDefaults(devices: *input.Devices) void {
    devices.settings = .{ .dead_zone = devices.settings.dead_zone };
    devices.bindings = input.defaultBindings(devices.joystick.kind);
    const file = devices.defaults_file orelse return;
    for (&devices.bindings.values) |*binding| defaultBinding(binding, file, devices.joystick.kind);
}

/// An action's binding as `key_config_defaults` reads it from `default.txt` (`0x0042CB04` on): its
/// button cleared, then its `KeyConfig` value, a button, or a key by its name in the executable's
/// English (`controls.keys`, as `key_names_english` holds them) after `SHIFT ` or `CONTROL `; then
/// its `JoyConfig` value over it, a button where a digit follows `JOY BUTTON `. An action the file
/// doesn't name keeps its key and its modifier, and a name the keys lack keeps the key. A gamepad
/// keeps the buttons of its own layout, which the file's joystick buttons don't number.
///
/// The game compares four bytes of `ALT`, its terminator among them (`0x0042CBF6`), so that only a
/// value of `ALT` alone is read as Alt, and as no key.
///
/// **Fix:** as `load_key_config` does, the game looks for `JOY BUTTON ` in `JoyConfig`'s value
/// past as many bytes as `KeyConfig`'s modifier took, so that an action with a modifier never takes
/// a button from it. OpenReliant looks from the start.
fn defaultBinding(binding: *controls.Binding, file: Profile, kind: input.JoystickDevice.Kind) void {
    const joystick = kind == .joystick;
    if (joystick) binding.button = null;
    if (file.value(key_section, binding.name)) |value| {
        const buffer = buffered(value);
        if (isButton(&buffer)) {
            if (joystick) binding.button = buttonNumber(read(buffer[button_name.len..]));
        } else nameKey(binding, &buffer);
    }
    if (!joystick) return;
    const buffer = buffered(file.value(joy_section, binding.name) orelse return);
    if (isButton(&buffer) and std.ascii.isDigit(buffer[button_name.len])) binding.button = buttonNumber(read(buffer[button_name.len..]));
}

/// `value` as `GetPrivateProfileStringA` leaves it in the buffer, cut to fit.
fn buffered(value: []const u8) Buffer {
    var buffer: Buffer = @splat(0);
    copy(&buffer, value[0..@min(value.len, buffer.len - 1)]);
    return buffer;
}

/// The key a `default.txt` value names, after its modifier's name, into `binding`: a name the keys
/// lack keeps the key.
fn nameKey(binding: *controls.Binding, buffer: *const Buffer) void {
    binding.modifier = .none;
    var name: []const u8 = std.mem.sliceTo(buffer, 0);
    for (default_modifiers) |named| {
        if (!std.mem.eql(u8, buffer[0..named.prefix.len], named.prefix)) continue;
        binding.modifier = named.modifier;
        name = std.mem.sliceTo(buffer[named.skip..], 0);
        break;
    }
    for (controls.keys) |key| {
        if (!std.mem.eql(u8, key.name, name)) continue;
        binding.key = key.code;
        break;
    }
}

/// The modifiers as `key_config_defaults` reads them: the bytes it compares (`0x004E8550`,
/// `0x004E8548`, `0x004E8544`), `ALT`'s terminator among them, and how far the key's name starts
/// past them.
const default_modifiers = [_]struct { prefix: []const u8, skip: usize, modifier: Modifier }{
    .{ .prefix = "SHIFT", .skip = "SHIFT ".len, .modifier = .shift },
    .{ .prefix = "CONTROL", .skip = "CONTROL ".len, .modifier = .control },
    .{ .prefix = "ALT\x00", .skip = "ALT ".len, .modifier = .alt },
};

/// `control_binding_find` (`0x0042C5F0`): the first action but `except` bound to `key` with
/// `modifier`, among all 74, KEY CONFIG's included; null for none.
pub fn bindingFind(bindings: *const input.Bindings, except: ?controls.Action, key: u16, modifier: Modifier) ?controls.Action {
    for (std.enums.values(controls.Action)) |action| {
        if (action == except) continue;
        const binding = bindings.get(action);
        if (binding.key == key and binding.modifier == modifier) return action;
    }
    return null;
}

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
/// key (`loadBinding`).
///
/// A `KeyConfig` value is either a key, as a decimal scan code optionally preceded by `SHIFT `,
/// `CONTROL ` or `ALT `, or `JOY BUTTON ` and a button number starting at 0. A `JoyConfig` value is
/// a button, and overrides the one from `KeyConfig`. A missing entry keeps the default binding.
///
/// **Fix:** where `Controller` is 0 and no joystick is attached, the game makes it 1, the keyboard
/// (`0x0042C8A5`); OpenReliant keeps the choice (`input.Devices.controlMode`).
///
/// Two bugs in the original are fixed; files the game writes itself load the same either way. When
/// the `KeyConfig` entry has a modifier, the original checks the `JoyConfig` value for
/// `JOY BUTTON ` at an offset of the modifier's length, so such an action can never get a button;
/// OpenReliant checks from the start of the value. And when `JoyConfig` has no entry, the original
/// falls back to the action's previous button instead of the one `KeyConfig` just set; OpenReliant
/// keeps the one from `KeyConfig`.
///
/// Each call starts from the defaults (`keyConfigDefaults`), as `hud_init` calls the two, so
/// OpenReliant can load the file again when a controller is connected or disconnected. Added by
/// OpenReliant: a gamepad's bindings come from `GamepadConfig` (`loadPadBinding`); and `DeadZone`
/// in `JoyConfig` sets the joystick's dead zone (`deadZone`).
pub fn loadKeyConfig(devices: *input.Devices, settings_file: Profile) void {
    keyConfigDefaults(devices);
    const held = &devices.settings;
    for (std.enums.values(Setting)) |setting| setting.set(held, settings_file.int(key_section, setting.key(), setting.of(held.*)));
    held.dead_zone = deadZone(settings_file);
    for (&devices.bindings.values) |*binding| switch (devices.joystick.kind) {
        .joystick => loadBinding(binding, settings_file),
        .gamepad => loadPadBinding(binding, settings_file),
    };
    loadModBindings(devices, settings_file);
}

/// Mod bindings use qualified names in separate sections, with no original-format changes.
pub const mod_key_section = "OpenReliantActionKeys";
pub const mod_joy_section = "OpenReliantActionJoystick";
pub const mod_pad_section = "OpenReliantActionGamepad";

pub fn loadModBindings(devices: *input.Devices, file: Profile) void {
    const registry = devices.mod_actions orelse return;
    for (registry.entries[0..registry.count]) |*entry| {
        if (entry.owner == null) continue;
        entry.binding.key = 0;
        entry.binding.button = null;
    }
    for (registry.entries[0..registry.count], 0..) |entry, index| {
        if (entry.owner != null) loadModBinding(devices, file, index);
    }
}

pub fn loadModBinding(devices: *input.Devices, file: Profile, index: usize) void {
    const entry = &devices.mod_actions.?.entries[index];
    entry.binding = entry.default;
    if (devices.joystick.kind == .gamepad) entry.binding.button = entry.gamepad_button;
    const name = entry.nameOf();
    if (file.value(mod_key_section, name)) |value| {
        const buffer = buffered(value);
        readKey(&entry.binding, &buffer);
        if (entry.binding.key > std.math.maxInt(u8)) entry.binding.key = 0;
    } else if (modKeyConflict(devices, index, entry.binding.key, entry.binding.modifier)) entry.binding.key = 0;
    const section = if (devices.joystick.kind == .gamepad) mod_pad_section else mod_joy_section;
    if (file.value(section, name)) |value| {
        const buffer = buffered(value);
        entry.binding.button = if (isButton(&buffer)) buttonNumber(read(buffer[button_name.len..])) else null;
    } else if (entry.binding.button) |button| {
        if (modButtonConflict(devices, index, button)) entry.binding.button = null;
    }
    entry.ready = false;
    entry.held = false;
}

pub fn modKeyConflict(devices: *const input.Devices, except: usize, key: u16, modifier: Modifier) bool {
    if (key == 0) return false;
    return bindingConflict(devices, .{ .custom = except }, .{ .key = .{ .code = key, .modifier = modifier } }) != null;
}

pub fn modButtonConflict(devices: *const input.Devices, except: usize, button: u8) bool {
    return bindingConflict(devices, .{ .custom = except }, .{ .button = button }) != null;
}

pub const BindingAction = union(enum) { original: controls.Action, custom: usize };
pub const BindingControl = union(enum) {
    key: struct { code: u16, modifier: Modifier },
    button: u8,

    fn matches(control: BindingControl, binding: controls.Binding) bool {
        return switch (control) {
            .key => |key| binding.key == key.code and binding.modifier == key.modifier,
            .button => |button| binding.button == button,
        };
    }
};

/// Shared conflict lookup for default assignment and explicit controls-screen rebinding.
pub fn bindingConflict(devices: *const input.Devices, except: BindingAction, control: BindingControl) ?BindingAction {
    for (std.enums.values(controls.Action)) |original| {
        const candidate: BindingAction = .{ .original = original };
        if (!std.meta.eql(candidate, except) and control.matches(devices.bindings.get(original))) return candidate;
    }
    const registry = devices.mod_actions orelse return null;
    for (registry.entries[0..registry.count], 0..) |entry, index| {
        const candidate: BindingAction = .{ .custom = index };
        if (entry.owner != null and !std.meta.eql(candidate, except) and control.matches(entry.binding)) return candidate;
    }
    return null;
}

pub fn saveModBindings(devices: *const input.Devices, file: *profile.File) Allocator.Error!void {
    const registry = devices.mod_actions orelse return;
    const section = if (devices.joystick.kind == .gamepad) mod_pad_section else mod_joy_section;
    for (registry.entries[0..registry.count]) |*entry| {
        if (entry.owner == null) continue;
        var buffer: [32]u8 = undefined;
        var key: std.Io.Writer = .fixed(&buffer);
        keyValue(&key, entry.binding);
        try file.write(mod_key_section, entry.nameOf(), key.buffered());
        var button_buffer: [32]u8 = undefined;
        try file.write(section, entry.nameOf(), buttonValue(&button_buffer, entry.binding.button));
    }
}

/// An action's binding as `load_key_config` reads it: its `KeyConfig` value, a key or a button, then
/// its `JoyConfig` value, a button, over it.
fn loadBinding(binding: *controls.Binding, settings_file: Profile) void {
    var default_buffer: [32]u8 = undefined;
    const default = defaultValue(&default_buffer, binding.*);
    var buffer: Buffer = @splat(0);
    copy(&buffer, settings_file.string(key_section, binding.name, default, buffer.len));
    binding.button = null;
    var joy_default = default;
    if (isButton(&buffer)) {
        binding.button = buttonNumber(read(buffer[button_name.len..]));
        joy_default = std.mem.sliceTo(&buffer, 0);
    } else readKey(binding, &buffer);
    var joy_buffer: Buffer = @splat(0);
    copy(&joy_buffer, settings_file.string(joy_section, binding.name, joy_default, joy_buffer.len));
    if (isButton(&joy_buffer)) binding.button = buttonNumber(read(joy_buffer[button_name.len..]));
}

/// A gamepad's binding, added by OpenReliant: its key from `KeyConfig`, where that names a key, and
/// its button from `GamepadConfig`, `JOY BUTTON ` and the button as OpenReliant numbers a gamepad's
/// (`input.GamepadButton`), or nothing for none; the default where either has no entry. A
/// joystick's buttons, `JoyConfig`'s and a `JOY BUTTON` in `KeyConfig`, are numbered otherwise, and
/// a gamepad reads none of them.
fn loadPadBinding(binding: *controls.Binding, settings_file: Profile) void {
    var key_buffer: [32]u8 = undefined;
    var key_default: std.Io.Writer = .fixed(&key_buffer);
    keyValue(&key_default, binding.*);
    var buffer: Buffer = @splat(0);
    copy(&buffer, settings_file.string(key_section, binding.name, key_default.buffered(), buffer.len));
    if (!isButton(&buffer)) readKey(binding, &buffer);
    var button_buffer: [32]u8 = undefined;
    var pad_buffer: Buffer = @splat(0);
    copy(&pad_buffer, settings_file.string(gamepad_section, binding.name, buttonValue(&button_buffer, binding.button), pad_buffer.len));
    binding.button = if (isButton(&pad_buffer)) buttonNumber(read(pad_buffer[button_name.len..])) else null;
}

/// Whether a value names a button.
fn isButton(buffer: *const Buffer) bool {
    return std.mem.eql(u8, buffer[0..button_name.len], button_name);
}

/// The key a value names, after its modifier's name, into `binding`.
fn readKey(binding: *controls.Binding, buffer: *const Buffer) void {
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

/// The joystick dead zone from `DeadZone` in `JoyConfig` (added by OpenReliant), given as a
/// percentage of each axis's travel from the center, 10 by default as in the original. Returned in
/// hundredths of a percent, the unit DirectInput uses.
pub fn deadZone(settings_file: Profile) u16 {
    const percent: u16 = @min(settings_file.int(joy_section, "DeadZone", input.default_dead_zone / dead_zone_unit), 100);
    return percent * dead_zone_unit;
}

/// `save_key_config` (`0x0042C630`): writes the input settings to the `KeyConfig` section of
/// `starlancer.ini`, then each action's key there, by the action's name, after the modifier's name
/// (`keyValue`), and its button to `JoyConfig`, `JOY BUTTON ` and the button's number, or nothing for
/// none (`buttonValue`). Added by OpenReliant: the joystick's dead zone, `DeadZone` in `JoyConfig`
/// (`deadZone`); and a gamepad's buttons go to `GamepadConfig` (`buttonSection`).
///
/// **Fix:** for a key held with Alt, the game writes the address of the key's name, which loads as
/// another key; OpenReliant writes the key's scan code, as it does with the other modifiers.
pub fn saveKeyConfig(devices: *const input.Devices, settings_file: *profile.File) Allocator.Error!void {
    try saveModBindings(devices, settings_file);
    const held = devices.settings;
    for (std.enums.values(Setting)) |setting| try saveSetting(held, settings_file, setting);
    try settings_file.writeInt(joy_section, "DeadZone", held.dead_zone / dead_zone_unit);
    const buttons = buttonSection(devices.joystick.kind);
    for (devices.bindings.values) |binding| {
        var key_buffer: [32]u8 = undefined;
        var key: std.Io.Writer = .fixed(&key_buffer);
        keyValue(&key, binding);
        try settings_file.write(key_section, binding.name, key.buffered());
        var button_buffer: [32]u8 = undefined;
        try settings_file.write(buttons, binding.name, buttonValue(&button_buffer, binding.button));
    }
}

/// The hundredths of a percent the dead zone is kept in, to the percent `DeadZone` holds.
const dead_zone_unit = 100;

/// A binding formatted the way the game writes it, which is also the default when the file has no
/// entry: `JOY BUTTON ` and the button, or the key as `keyValue` writes it.
fn defaultValue(buffer: *[32]u8, binding: controls.Binding) []const u8 {
    if (binding.button != null) return buttonValue(buffer, binding.button);
    // The longest value, `CONTROL -32768`, fits the buffer with room to spare.
    var writer: std.Io.Writer = .fixed(buffer);
    keyValue(&writer, binding);
    return writer.buffered();
}

/// A button as the game writes it: `JOY BUTTON ` and its number, or nothing for none.
fn buttonValue(buffer: *[32]u8, button: ?u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    if (button) |number| writer.print(button_name ++ "{d}", .{number}) catch {};
    return writer.buffered();
}

/// A key as the game writes it to `KeyConfig`: its scan code, after the modifier's name.
fn keyValue(writer: *std.Io.Writer, binding: controls.Binding) void {
    const code: i16 = @bitCast(binding.key);
    for (modifier_names) |named| {
        if (named.modifier == binding.modifier) writer.print("{s} ", .{named.name}) catch {};
    }
    writer.print("{d}", .{code}) catch {};
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
    const loaded = devices.settings;
    try std.testing.expect(!loaded.joystick_invert and loaded.twist_enabled and loaded.hat_enabled);
    // Without a joystick, the joystick stays the choice, and the keyboard steers until one comes.
    try std.testing.expectEqual(input.ControlMode.joystick, loaded.control_mode);
    try std.testing.expectEqual(input.ControlMode.keyboard, devices.controlMode());
    try std.testing.expectEqual(400, loaded.dead_zone);

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
    const loaded = devices.settings;
    try std.testing.expect(loaded.joystick_invert and loaded.hat_enabled and loaded.force_feedback);
    try std.testing.expect(!loaded.twist_enabled);
    try std.testing.expectEqual(input.default_dead_zone, loaded.dead_zone);
    for (std.enums.values(controls.Action)) |action| {
        const default = controls.binding(action);
        try std.testing.expectEqual(default.key, devices.bindings.get(action).key);
        try std.testing.expectEqual(default.modifier, devices.bindings.get(action).modifier);
        try std.testing.expectEqual(default.button, devices.bindings.get(action).button);
    }
}

test saveKeyConfig {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var devices: input.Devices = .{};
    loadKeyConfig(&devices, .empty);
    devices.settings.joystick_invert = false;
    devices.settings.dead_zone = 500;
    devices.bindings.getPtr(.eject).* = .{ .name = "EJECT", .string = 0x36F, .key = 88, .modifier = .alt, .button = null };
    devices.bindings.getPtr(.afterburners).button = 9;
    var file: profile.File = .{ .arena = arena_state.allocator(), .profile = .empty };
    try saveKeyConfig(&devices, &file);
    const saved = file.profile;
    // As the game writes them, but for Alt's key, which it writes as its name's address.
    try std.testing.expectEqualStrings("0", saved.value(key_section, "JoystickInvert").?);
    try std.testing.expectEqualStrings("ALT 88", saved.value(key_section, "EJECT").?);
    try std.testing.expectEqualStrings("SHIFT 18", saved.value(key_section, "PREVIOUS ENEMY TARGET").?);
    try std.testing.expectEqualStrings("JOY BUTTON 9", saved.value(joy_section, "AFTERBURNERS").?);
    try std.testing.expectEqualStrings("", saved.value(joy_section, "EJECT").?);
    try std.testing.expectEqualStrings("5", saved.value(joy_section, "DeadZone").?);
    // And they load back as they were.
    var again: input.Devices = .{};
    loadKeyConfig(&again, saved);
    try std.testing.expect(!again.settings.joystick_invert);
    try std.testing.expectEqual(500, again.settings.dead_zone);
    for (std.enums.values(controls.Action)) |action| {
        const kept = devices.bindings.get(action);
        const loaded = again.bindings.get(action);
        try std.testing.expectEqual(kept.key, loaded.key);
        try std.testing.expectEqual(kept.modifier, loaded.modifier);
        try std.testing.expectEqual(kept.button, loaded.button);
    }
}

test "mod defaults do not steal controls and bindings persist by qualified name" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var registry: input.actions.Registry = .{};
    var owner: u8 = 0;
    const binding: controls.Binding = .{ .name = "", .string = 0, .key = @intFromEnum(input.Key.k), .modifier = .none, .button = 0 };
    const a = try registry.add(&owner, "a:pulse", "Pulse", binding);
    var shifted = binding;
    shifted.modifier = .shift;
    shifted.button = null;
    const b = try registry.add(&owner, "b:pulse", "Other pulse", shifted);
    var devices: input.Devices = .{ .mod_actions = &registry };
    loadKeyConfig(&devices, .empty);
    try std.testing.expectEqual(0, registry.entries[a].binding.key);
    try std.testing.expectEqual(null, registry.entries[a].binding.button);
    try std.testing.expectEqual(binding.key, registry.entries[b].binding.key);
    registry.entries[a].binding = shifted;
    registry.entries[a].binding.key = @intFromEnum(input.Key.f12);
    var file: profile.File = .{ .arena = arena.allocator(), .profile = .empty };
    try saveModBindings(&devices, &file);
    loadModBindings(&devices, file.profile);
    try std.testing.expectEqual(@intFromEnum(input.Key.f12), registry.entries[a].binding.key);
    try std.testing.expectEqual(Modifier.shift, registry.entries[a].binding.modifier);
    devices.joystick.kind = .gamepad;
    loadModBindings(&devices, file.profile);
    try std.testing.expectEqual(null, registry.entries[a].binding.button);
}

test "a gamepad keeps its own buttons" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var devices: input.Devices = .{};
    devices.joystick.kind = .gamepad;
    const settings_file: Profile = .{ .text =
        \\[KeyConfig]
        \\FIRE LASERS=JOY BUTTON 5
        \\AFTERBURNERS=15
        \\[JoyConfig]
        \\ACCELERATE=
        \\AFTERBURNERS=JOY BUTTON 9
        \\[GamepadConfig]
        \\LAUNCH MISSILE=JOY BUTTON 3
        \\COUNTERMEASURES=
        \\
    };
    loadKeyConfig(&devices, settings_file);
    const pad = input.defaultBindings(.gamepad);
    // A joystick's buttons, in `JoyConfig` or in `KeyConfig`, leave the gamepad's as they are; its
    // keys are taken.
    for ([_]controls.Action{ .fire_lasers, .accelerate, .afterburners }) |action| {
        try std.testing.expectEqual(pad.get(action).button, devices.bindings.get(action).button);
    }
    try std.testing.expectEqual(15, devices.bindings.get(.afterburners).key);
    // `GamepadConfig` gives a button, or takes one away.
    try std.testing.expectEqual(3, devices.bindings.get(.launch_missile).button.?);
    try std.testing.expectEqual(null, devices.bindings.get(.countermeasures).button);
    // Its right stick rolls whatever `TwistEnable` says.
    try std.testing.expect(!devices.settings.twist_enabled and devices.twistRolls());

    // Its buttons are written to `GamepadConfig`, and `JoyConfig`'s left alone.
    var file: profile.File = .{ .arena = arena_state.allocator(), .profile = settings_file };
    try saveKeyConfig(&devices, &file);
    try std.testing.expectEqualStrings("JOY BUTTON 3", file.profile.value(gamepad_section, "LAUNCH MISSILE").?);
    try std.testing.expectEqualStrings("JOY BUTTON 9", file.profile.value(joy_section, "AFTERBURNERS").?);
}

test read {
    // Up to the terminator, past which the buffer keeps what an earlier value left.
    try std.testing.expectEqual(57, read("57\x0099"));
    try std.testing.expectEqual(-12, read("-12"));
}

test keyConfigDefaults {
    var devices: input.Devices = .{};
    devices.settings = .{ .joystick_invert = false, .twist_enabled = true, .control_mode = .mouse, .dead_zone = 400 };
    devices.bindings.getPtr(.eject).key = 0;
    keyConfigDefaults(&devices);
    // The joystick chosen, which steers once one is attached; the dead zone, OpenReliant's, stays.
    try std.testing.expectEqual(input.Settings{ .dead_zone = 400 }, devices.settings);
    try std.testing.expectEqual(controls.binding(.eject).key, devices.bindings.get(.eject).key);
    // Without `default.txt`, the executable's buttons stay.
    try std.testing.expectEqual(5, devices.bindings.get(.next_friendly_target).button);
}

test "the defaults come from default.txt" {
    var devices: input.Devices = .{};
    devices.defaults_file = .{ .text =
        \\[KeyConfig]
        \\FULL THROTTLE=]
        \\JOYSTICK ROLL=/
        \\PREVIOUS ENEMY TARGET=SHIFT E
        \\SYNCHRONISE GUNS=CONTROL G
        \\ACCELERATE==
        \\SEND COMMS MESSAGE='
        \\CLOAK SHIP=NOT A KEY
        \\ECM=ALT
        \\SPECTRAL SHIELDS=ALT X
        \\HELP ME=JOY BUTTON 9
        \\NEXT FRIENDLY TARGET=Q
        \\[JoyConfig]
        \\COUNTERMEASURES=JOY BUTTON 6
        \\FIRE LASERS=JOY BUTTON 0
        \\NEXT FRIENDLY TARGET=
        \\STRAFE LEFT=JOY BUTTON x
        \\
    };
    keyConfigDefaults(&devices);
    const bindings = &devices.bindings;
    // Keys by their names, with Shift and Ctrl: FULL THROTTLE's and JOYSTICK ROLL's differ from
    // the executable's.
    try std.testing.expectEqual(0x1B, bindings.get(.full_throttle).key);
    try std.testing.expectEqual(0x35, bindings.get(.joystick_roll).key);
    try std.testing.expectEqual(controls.Binding{ .name = "PREVIOUS ENEMY TARGET", .string = 0x339, .key = 0x12, .modifier = .shift, .button = null }, bindings.get(.previous_enemy_target));
    try std.testing.expectEqual(Modifier.control, bindings.get(.synchronise_guns).modifier);
    try std.testing.expectEqual(0x0D, bindings.get(.accelerate).key);
    try std.testing.expectEqual(0x28, bindings.get(.send_comms_message).key);
    // A name the keys lack keeps the key; `ALT` alone is Alt and no key, and `ALT X` no modifier.
    try std.testing.expectEqual(controls.binding(.cloak_ship).key, bindings.get(.cloak_ship).key);
    try std.testing.expectEqual(Modifier.alt, bindings.get(.ecm).modifier);
    try std.testing.expectEqual(controls.binding(.ecm).key, bindings.get(.ecm).key);
    try std.testing.expectEqual(Modifier.none, bindings.get(.spectral_shields).modifier);
    // Buttons from either section; none but those the file gives, a digit after `JOY BUTTON`.
    try std.testing.expectEqual(9, bindings.get(.help_me).button);
    try std.testing.expectEqual(controls.binding(.help_me).key, bindings.get(.help_me).key);
    try std.testing.expectEqual(6, bindings.get(.countermeasures).button);
    try std.testing.expectEqual(0, bindings.get(.fire_lasers).button);
    try std.testing.expectEqual(null, bindings.get(.next_friendly_target).button);
    try std.testing.expectEqual(null, bindings.get(.strafe_left).button);
    // An action the file doesn't name keeps the executable's key, without its button.
    try std.testing.expectEqual(controls.binding(.afterburners).key, bindings.get(.afterburners).key);
    try std.testing.expectEqual(null, bindings.get(.afterburners).button);

    // A gamepad takes the keys, and keeps its own buttons.
    devices.joystick.kind = .gamepad;
    keyConfigDefaults(&devices);
    try std.testing.expectEqual(0x1B, bindings.get(.full_throttle).key);
    try std.testing.expectEqual(input.defaultBindings(.gamepad).get(.countermeasures).button, bindings.get(.countermeasures).button);
    try std.testing.expectEqual(null, bindings.get(.help_me).button);
}

test bindingFind {
    const bindings = input.defaultBindings(.joystick);
    const e = controls.binding(.next_enemy_target).key;
    // E alone, with Shift and with Ctrl are three actions.
    try std.testing.expectEqual(.next_enemy_target, bindingFind(&bindings, null, e, .none).?);
    try std.testing.expectEqual(.previous_enemy_target, bindingFind(&bindings, null, e, .shift).?);
    try std.testing.expectEqual(.smart_target, bindingFind(&bindings, null, e, .control).?);
    // The action left out isn't found, nor a key no action holds.
    try std.testing.expectEqual(null, bindingFind(&bindings, .next_enemy_target, e, .none));
    try std.testing.expectEqual(null, bindingFind(&bindings, null, e, .alt));
    // KEY CONFIG's F1 is among them.
    try std.testing.expectEqual(.key_config, bindingFind(&bindings, null, controls.binding(.key_config).key, .none).?);
}

test deadZone {
    try std.testing.expectEqual(1000, deadZone(.empty));
    try std.testing.expectEqual(0, deadZone(.{ .text = "[JoyConfig]\nDeadZone=0\n" }));
    try std.testing.expectEqual(10000, deadZone(.{ .text = "[JoyConfig]\nDeadZone=250\n" }));
}

test {
    _ = briefing;
    _ = canvas;
    _ = cd_player;
    _ = dialog;
    _ = disc;
    _ = game_options;
    _ = in_game_options;
    _ = induction;
    _ = locker;
    _ = main_menu;
    _ = pilot_roster;
    _ = restart;
    _ = rooms;
    _ = saved_games;
    _ = settings;
}
