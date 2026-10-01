//! `openreliant joysticks`: lists the connected joysticks and gamepads, shows which one the game
//! will use and, for joysticks, which axis is used for what, and whether `starlancer.ini` chose it.
//! With `--watch` it shows live input from the selected controller as the game sees it: the buttons
//! held by the numbers `JOY BUTTON` takes and, for a joystick, every axis by the number
//! `ThrottleAxis` and `TwistAxis` take, to help find them for `starlancer.ini`. On a terminal the
//! view is redrawn in place.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const help = @import("help.zig");
const joystick = platform.joystick;
const input = openreliant.engine.input;
const interface = openreliant.engine.game.interface;
const Profile = openreliant.engine.profile.Profile;

pub const usage =
    \\usage: openreliant joysticks [<game-directory>] [--watch]
    \\  <game-directory>  the folder StarLancer is installed in, for the settings in its
    \\                    starlancer.ini; the current directory by default
    \\  --watch           show live input from the controller the game uses, until Ctrl+C
    \\  -h, --help        show this page
    \\
;

pub const Options = struct {
    directory: []const u8 = ".",
    watch: bool = false,

    pub fn parse(args: []const [:0]const u8) error{Usage}!Options {
        var options: Options = .{};
        var directory: ?[]const u8 = null;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--watch")) {
                options.watch = true;
            } else if (std.mem.startsWith(u8, arg, "-") or directory != null) {
                return error.Usage;
            } else {
                directory = arg;
            }
        }
        if (directory) |given| options.directory = given;
        return options;
    }
};

/// Runs `openreliant joysticks` with the given arguments. Returns the exit code.
pub fn main(io: Io, arena: Allocator, args: []const [:0]const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (help.asked(args)) {
        try out.writeAll(usage);
        return 0;
    }
    const options = Options.parse(args) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const settings_file: Profile = settings: {
        var directory = Io.Dir.cwd().openDir(io, options.directory, .{}) catch break :settings .empty;
        defer directory.close(io);
        break :settings .read(io, arena, directory);
    };
    const setup: joystick.Setup = .read(settings_file);

    try joystick.init(.tool);
    defer joystick.deinit();
    const mappings = joystick.addMappings(try std.fs.path.joinZ(arena, &.{ options.directory, joystick.mappings_name }));
    if (mappings > 0) try out.print("Read {d} gamepad {s} from {s}.\n", .{ mappings, if (mappings == 1) "mapping" else "mappings", joystick.mappings_name });
    joystick.update();
    const found = try joystick.attached(arena);
    if (found.len == 0) {
        try out.writeAll("No joystick or gamepad is attached.\n");
        return 1;
    }
    const chosen = joystick.choose(found, setup.preference).?;
    for (found, 1..) |each, number| {
        var controller = joystick.Controller.open(each, setup) catch {
            try out.print("{d}. {s}: can't be opened.\n", .{ number, each.name });
            continue;
        };
        defer controller.close();
        try describe(out, number, each, &controller, setup, each.id == chosen.id);
    }
    try out.flush();
    if (!options.watch) return 0;

    var controller = try joystick.Controller.open(chosen, setup);
    defer controller.close();
    var devices: input.Devices = .{};
    devices.joystick.open(controller.device(), interface.deadZone(settings_file));
    // On a terminal each view is drawn over the last; otherwise, as into a file, it follows it.
    const in_place = if (Io.File.stdout().enableAnsiEscapeCodes(io)) |_| true else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.NotTerminalDevice, error.Unexpected => false,
    };
    try out.print("\nShowing input from {s} as the game sees it. Press Ctrl+C to stop.\n\n", .{chosen.name});
    try out.flush();
    var last: [watch_size]u8 = undefined;
    var last_len: usize = 0;
    while (true) {
        joystick.update();
        devices.joystick.read();
        if (devices.joystick.device == null) {
            try out.writeAll("The controller was disconnected.\n");
            return 1;
        }
        var readings: [max_axes]i16 = undefined;
        var axes: usize = 0;
        if (controller.handle == .joystick) {
            const plain = controller.sdlJoystick();
            axes = @min(joystick.axisCount(plain), max_axes);
            for (readings[0..axes], 0..) |*reading, index| reading.* = joystick.axisValue(plain, @intCast(index));
        }
        var view_buffer: [watch_size]u8 = undefined;
        var view: Io.Writer = .fixed(&view_buffer);
        // A view too long for the buffer is cut short.
        writeView(&view, devices.joystick, readings[0..axes], controller.layout) catch {};
        const text = view.buffered();
        if (!std.mem.eql(u8, text, last[0..last_len])) {
            if (in_place) {
                try redraw(out, text, std.mem.count(u8, last[0..last_len], "\n"));
            } else {
                try out.print("{s}\n", .{text});
            }
            try out.flush();
            @memcpy(last[0..text.len], text);
            last_len = text.len;
        }
        try io.sleep(.fromMilliseconds(100), .awake);
    }
}

/// Room for what `--watch` shows at a time, and the axes it shows at most.
const watch_size = 2048;
const max_axes = 32;

/// The ANSI escape codes `redraw` uses: the cursor up a number of lines, and erasing the rest of
/// the line and the rest of the screen.
const cursor_up = "\x1b[{d}A";
const erase_line = "\x1b[K";
const erase_below = "\x1b[J";

/// The widest a line drawn in place gets, which a terminal of 80 columns holds: a line that wraps
/// would start each redraw a row lower.
const line_width = 79;

/// Draws `view` over the `drawn` lines above the cursor, which it leaves at the start of the line
/// after the view: each line cut to `line_width`, and what the last view leaves beyond a line, or
/// below the new one, erased.
fn redraw(out: *Io.Writer, view: []const u8, drawn: usize) Io.Writer.Error!void {
    if (drawn > 0) try out.print(cursor_up, .{drawn});
    var rest = view;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |end| {
        try out.print("{s}" ++ erase_line ++ "\n", .{rest[0..@min(end, line_width)]});
        rest = rest[end + 1 ..];
    }
    try out.writeAll(erase_below);
}

/// What `--watch` shows at a time, a line each: the state as the game reads it, the buttons held,
/// and each of a joystick's axes from `readings` (none for a gamepad).
fn writeView(out: *Io.Writer, read: input.Joystick, readings: []const i16, layout: joystick.Layout) Io.Writer.Error!void {
    try writeState(out, read);
    try out.writeByte('\n');
    try writeButtons(out, read);
    try out.writeByte('\n');
    for (readings, 0..) |reading, index| {
        try writeAxis(out, @intCast(index), reading, layout);
        try out.writeByte('\n');
    }
}

/// Prints a controller's entry in the list: its name, type, axis layout, and the setting that
/// chooses it.
fn describe(out: *Io.Writer, number: usize, found: joystick.Found, controller: *joystick.Controller, setup: joystick.Setup, chosen: bool) !void {
    const plain = controller.sdlJoystick();
    try out.print("{d}. {s}{s}\n   {s}, USB ID {x:0>4}:{x:0>4}", .{
        number,
        found.name,
        if (chosen) " (used by the game)" else "",
        @tagName(found.kind),
        found.vendor,
        found.product,
    });
    switch (controller.handle) {
        .gamepad => try out.writeAll(
            \\
            \\   Left stick: pitch and turn. Right stick: roll and speed. D-pad: look around.
            \\
        ),
        .joystick => {
            try count(out, joystick.axisCount(plain), "axis", "axes");
            try count(out, joystick.buttonCount(plain), "button", "buttons");
            try count(out, joystick.hatCount(plain), "hat", "hats");
            try out.writeAll("\n   ");
            try writeLayout(out, controller.layout, setup);
            try out.writeAll("\n");
        },
    }
    // `Joystick=` picks the first controller whose name holds what it gives.
    try out.print("   To choose it: Joystick={s}\n", .{found.name});
}

/// A joystick's axis for each of its uses, and for the throttle and the twist, whether it is the
/// automatic choice or the one `starlancer.ini` gives.
fn writeLayout(out: *Io.Writer, layout: joystick.Layout, setup: joystick.Setup) !void {
    for (std.enums.values(joystick.Layout.Role), 0..) |which, index| {
        if (index > 0) try out.writeAll(", ");
        try out.print("{s}: ", .{label(which)});
        if (layout.axisFor(which)) |axis| try out.print("axis {d}", .{axis}) else try out.writeAll("none");
        const choice = switch (which) {
            .x, .y => continue,
            .throttle => setup.throttle,
            .twist => setup.twist,
        };
        try out.writeAll(switch (choice) {
            .guess => " (automatic)",
            else => if (which == .throttle) " (ThrottleAxis)" else " (TwistAxis)",
        });
    }
}

/// What the list calls each use of an axis.
fn label(which: joystick.Layout.Role) []const u8 {
    return switch (which) {
        .x => "X",
        .y => "Y",
        .throttle => "throttle",
        .twist => "twist",
    };
}

/// A joystick's axis by its number, as `ThrottleAxis` and `TwistAxis` take it: its reading as a
/// whole percentage of its travel either way, which the axis's noise rarely moves, and what the
/// game reads it as.
fn writeAxis(out: *Io.Writer, index: u8, reading: i16, layout: joystick.Layout) Io.Writer.Error!void {
    const share = @divTrunc(@as(i32, reading) * 100, std.math.maxInt(i16));
    try out.print("Axis {d:>2}: {f}%", .{ index, padded(share, share_width) });
    if (layout.role(index)) |which| try out.print(" ({s})", .{label(which)});
}

fn count(out: *Io.Writer, how_many: u32, one: []const u8, many: []const u8) !void {
    try out.print(", {d} {s}", .{ how_many, if (how_many == 1) one else many });
}

/// The joystick's state as the game reads it, each value in a field as wide as its range, so that
/// the line keeps its shape as the values change.
fn writeState(out: *Io.Writer, read: input.Joystick) Io.Writer.Error!void {
    const values = read.state;
    try out.print("X {f}  Y {f}", .{ padded(values.x, value_width), padded(values.y, value_width) });
    if (read.axes.z) try out.print("  throttle {f}", .{padded(values.z, value_width)});
    if (read.axes.slider) try out.print("  slider {f}", .{padded(values.sliders[0], value_width)});
    if (read.axes.rz) try out.print("  twist {f}", .{padded(values.rz, value_width)});
    if (read.hats > 0) {
        if (values.hat(0)) |angle| {
            try out.print("  hat {d:>3}", .{angle / 100});
        } else {
            try out.writeAll("  hat   -");
        }
    }
}

/// The columns a value the game reads takes at most, from -1000 to 1000 (`input.Axis.range`), and
/// an axis's share of its travel, from -100 to 100.
const value_width = 5;
const share_width = 4;

/// A number right-aligned in `width` columns, for `{f}`: `{d:>5}` gives a signed number of zero or
/// more a plus sign.
const Padded = struct {
    value: i32,
    width: u8,

    pub fn format(number: Padded, out: *Io.Writer) Io.Writer.Error!void {
        var buffer: [11]u8 = undefined;
        const digits = buffer[0..std.fmt.printInt(&buffer, number.value, 10, .lower, .{})];
        try out.alignBuffer(digits, number.width, .right, ' ');
    }
};

fn padded(value: i32, width: u8) Padded {
    return .{ .value = value, .width = width };
}

/// The buttons held, by the numbers `JOY BUTTON` takes, with what each is on a gamepad.
fn writeButtons(out: *Io.Writer, read: input.Joystick) Io.Writer.Error!void {
    try out.writeAll("Buttons down:");
    var held: usize = 0;
    for (read.state.buttons[0..read.buttons], 0..) |button, index| {
        if (button == 0) continue;
        try out.print("{s} {d}", .{ if (held > 0) "," else "", index });
        if (read.kind == .gamepad) try out.print(" ({s})", .{buttonName(@enumFromInt(@as(u5, @intCast(index))))});
        held += 1;
    }
    if (held == 0) try out.writeAll(" none");
}

/// What a gamepad's button is, by where it sits, as the controllers guide lists them.
fn buttonName(button: input.GamepadButton) []const u8 {
    return switch (button) {
        .south => "bottom face button",
        .east => "right face button",
        .west => "left face button",
        .north => "top face button",
        .back => "back",
        .guide => "guide",
        .start => "start",
        .left_stick => "left stick click",
        .right_stick => "right stick click",
        .left_shoulder => "left bumper",
        .right_shoulder => "right bumper",
        .dpad_up => "D-pad up",
        .dpad_down => "D-pad down",
        .dpad_left => "D-pad left",
        .dpad_right => "D-pad right",
        .misc1 => "capture or mute",
        .right_paddle1 => "right paddle 1",
        .left_paddle1 => "left paddle 1",
        .right_paddle2 => "right paddle 2",
        .left_paddle2 => "left paddle 2",
        .touchpad => "touchpad click",
        .misc2, .misc3, .misc4, .misc5, .misc6 => "extra button",
        .left_trigger => "left trigger",
        .right_trigger => "right trigger",
        .right_stick_up => "right stick up",
        .right_stick_down => "right stick down",
        .right_stick_left => "right stick left",
        .right_stick_right => "right stick right",
    };
}

test Options {
    try std.testing.expectEqualStrings(".", (try Options.parse(&.{})).directory);
    const given = try Options.parse(&.{ "game", "--watch" });
    try std.testing.expectEqualStrings("game", given.directory);
    try std.testing.expect(given.watch);
    try std.testing.expectError(error.Usage, Options.parse(&.{"--bogus"}));
    try std.testing.expectError(error.Usage, Options.parse(&.{ "a", "b" }));
}

test writeState {
    var read: input.Joystick = .{ .buttons = 12, .hats = 1 };
    read.axes.z = true;
    read.state.x = -1000;
    read.state.z = 250;
    read.state.pov = @splat(input.JoystickState.centred);
    read.state.pov[0] = 9000;
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    try writeState(&out, read);
    try std.testing.expectEqualStrings("X -1000  Y     0  throttle   250  hat  90", out.buffered());
    // The line keeps its shape as the values change.
    read.state.x = 5;
    read.state.pov[0] = input.JoystickState.centred;
    out = .fixed(&buffer);
    try writeState(&out, read);
    try std.testing.expectEqualStrings("X     5  Y     0  throttle   250  hat   -", out.buffered());
}

test writeButtons {
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var read: input.Joystick = .{ .buttons = 12 };
    try writeButtons(&out, read);
    try std.testing.expectEqualStrings("Buttons down: none", out.buffered());
    read.state.buttons[0] = input.JoystickState.pressed;
    read.state.buttons[11] = input.JoystickState.pressed;
    out = .fixed(&buffer);
    try writeButtons(&out, read);
    try std.testing.expectEqualStrings("Buttons down: 0, 11", out.buffered());
    // A gamepad's buttons are named, the right stick's directions among them.
    read = .{ .buttons = input.JoystickState.max_buttons, .kind = .gamepad };
    read.state.buttons[@intFromEnum(input.GamepadButton.south)] = input.JoystickState.pressed;
    read.state.buttons[@intFromEnum(input.GamepadButton.right_stick_right)] = input.JoystickState.pressed;
    out = .fixed(&buffer);
    try writeButtons(&out, read);
    try std.testing.expectEqualStrings("Buttons down: 0 (bottom face button), 31 (right stick right)", out.buffered());
}

test writeView {
    var buffer: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    var read: input.Joystick = .{ .buttons = 12 };
    read.axes.z = true;
    read.axes.rz = true;
    read.state.x = 1000;
    read.state.rz = 1000;
    read.state.buttons[3] = input.JoystickState.pressed;
    const layout: joystick.Layout = .{ .x = 0, .y = 1, .twist = 2, .throttle = 3 };
    try writeView(&out, read, &.{ 32767, 0, 32767, -32768, 5000 }, layout);
    try std.testing.expectEqualStrings(
        \\X  1000  Y     0  throttle     0  twist  1000
        \\Buttons down: 3
        \\Axis  0:  100% (X)
        \\Axis  1:    0% (Y)
        \\Axis  2:  100% (twist)
        \\Axis  3: -100% (throttle)
        \\Axis  4:   15%
        \\
    , out.buffered());
}

test redraw {
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    // The first view is drawn where the cursor is.
    try redraw(&out, "X 0\nButtons down: none\n", 0);
    try std.testing.expectEqualStrings("X 0" ++ erase_line ++ "\nButtons down: none" ++ erase_line ++ "\n" ++ erase_below, out.buffered());
    // A later one goes back over the lines of the last, and a long line is cut.
    out = .fixed(&buffer);
    try redraw(&out, "A" ** 100 ++ "\n", 2);
    try std.testing.expectEqualStrings("\x1b[2A" ++ "A" ** line_width ++ erase_line ++ "\n" ++ erase_below, out.buffered());
}

test writeLayout {
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const layout: joystick.Layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 4 };
    try writeLayout(&out, layout, .{ .twist = .{ .axis = 4 } });
    try std.testing.expectEqualStrings("X: axis 0, Y: axis 1, throttle: axis 2 (automatic), twist: axis 4 (TwistAxis)", out.buffered());
    out = .fixed(&buffer);
    try writeLayout(&out, .{ .x = 0, .y = 1 }, .{ .throttle = .none });
    try std.testing.expectEqualStrings("X: axis 0, Y: axis 1, throttle: none (ThrottleAxis), twist: none (automatic)", out.buffered());
}

test writeAxis {
    var buffer: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&buffer);
    const layout: joystick.Layout = .{ .x = 0, .y = 1, .throttle = 2, .twist = 12 };
    try writeAxis(&out, 2, 16384, layout);
    try std.testing.expectEqualStrings("Axis  2:   50% (throttle)", out.buffered());
    out = .fixed(&buffer);
    try writeAxis(&out, 12, -32768, layout);
    try std.testing.expectEqualStrings("Axis 12: -100% (twist)", out.buffered());
}
