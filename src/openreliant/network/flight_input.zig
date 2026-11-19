//! Encode the engine's flight commands. Held input is replaceable; presses are sent reliably.
const std = @import("std");
const flight = @import("openreliant").engine.input.flight;

const Drive = packed struct(u8) {
    accelerate: bool = false,
    decelerate: bool = false,
    afterburner: bool = false,
    reverse: bool = false,
    reserved: u4 = 0,
};

/// The most recent throttle press and the net effect of the afterburner toggles since delivery.
pub const Presses = packed struct(u8) {
    zero: bool = false,
    full: bool = false,
    toggle: bool = false,
    reserved: u5 = 0,

    pub fn take(pending: *Presses, command: *flight.Command) void {
        pending.merge(.{
            .zero = command.throttle == .keys and command.throttle.keys.zero,
            .full = command.throttle == .keys and command.throttle.keys.full,
            .toggle = command.toggle_afterburner,
        });
        command.consumePresses();
    }

    pub fn merge(pending: *Presses, next: Presses) void {
        if (next.zero or next.full) {
            pending.zero = next.zero;
            pending.full = next.full;
        }
        pending.toggle = pending.toggle != next.toggle;
    }

    pub fn any(pending: Presses) bool {
        return pending.zero or pending.full or pending.toggle;
    }

    pub fn apply(pending: Presses, command: *flight.Command) void {
        if (command.throttle == .keys) {
            command.throttle.keys.zero = pending.zero;
            command.throttle.keys.full = pending.full;
        }
        command.toggle_afterburner = pending.toggle;
    }
};

/// Release inputs that have to be held while keeping an analogue throttle setting.
pub fn release(command: flight.Command) flight.Command {
    return .{ .throttle = if (command.throttle == .axis) command.throttle else .{ .keys = .{} } };
}

pub fn write(writer: *std.Io.Writer, command: flight.Command) !void {
    if (!command.valid()) return error.InvalidFlightInput;
    try writer.writeByte(@backingInt(std.meta.activeTag(command.steering)));
    switch (command.steering) {
        .axes => |axes| for (axes) |axis| try writeAxis(writer, axis),
        .keys => |keys| {
            try writer.writeByte(@backingInt(keys.yaw));
            try writer.writeByte(@backingInt(keys.pitch));
            try writeAxis(writer, keys.roll);
        },
        .power => |stick| for (stick) |axis| try writeAxis(writer, axis),
        .shields => |axis| try writeAxis(writer, axis),
    }
    try writer.writeByte(@backingInt(std.meta.activeTag(command.throttle)));
    if (command.throttle == .axis) try writeAxis(writer, command.throttle.axis);
    try writer.writeByte(@backingInt(command.strafe));
    const drive: Drive = .{
        .accelerate = command.throttle == .keys and command.throttle.keys.accelerate,
        .decelerate = command.throttle == .keys and command.throttle.keys.decelerate,
        .afterburner = command.afterburner,
        .reverse = command.reverse,
    };
    try writer.writeByte(@bitCast(drive));
}

pub fn read(reader: *std.Io.Reader) !flight.Command {
    const steering: flight.Steering = switch (try readTag(reader, std.meta.Tag(flight.Steering))) {
        .axes => .{ .axes = .{ try readAxis(reader), try readAxis(reader), try readAxis(reader) } },
        .keys => .{ .keys = .{
            .yaw = try readTag(reader, flight.Direction),
            .pitch = try readTag(reader, flight.Direction),
            .roll = try readAxis(reader),
        } },
        .power => .{ .power = .{ try readAxis(reader), try readAxis(reader) } },
        .shields => .{ .shields = try readAxis(reader) },
    };
    var throttle: flight.Throttle = switch (try readTag(reader, std.meta.Tag(flight.Throttle))) {
        .held => .held,
        .axis => .{ .axis = try readAxis(reader) },
        .keys => .{ .keys = .{} },
    };
    const strafe = try readTag(reader, flight.Direction);
    const drive: Drive = @bitCast(try reader.takeByte());
    if (drive.reserved != 0) return error.InvalidFlightInput;
    if (throttle == .keys) {
        throttle.keys.accelerate = drive.accelerate;
        throttle.keys.decelerate = drive.decelerate;
    }
    const command: flight.Command = .{
        .steering = steering,
        .throttle = throttle,
        .strafe = strafe,
        .afterburner = drive.afterburner,
        .reverse = drive.reverse,
    };
    if (!command.valid()) return error.InvalidFlightInput;
    return command;
}

fn writeAxis(writer: *std.Io.Writer, value: f32) !void {
    try writer.writeInt(u32, @bitCast(value), .little);
}

fn readAxis(reader: *std.Io.Reader) !f32 {
    return @bitCast(try reader.takeInt(u32, .little));
}

fn readTag(reader: *std.Io.Reader, comptime Tag: type) !Tag {
    return std.enums.fromInt(Tag, try reader.takeByte()) orelse error.InvalidFlightInput;
}

test "held flight forms round trip with bounded axes and tags" {
    const commands = [_]flight.Command{
        .{ .steering = .{ .keys = .{ .yaw = .negative, .pitch = .positive, .roll = 1 } }, .throttle = .{ .keys = .{ .accelerate = true } }, .reverse = true },
        .{ .steering = .{ .power = .{ 10, -5 } }, .throttle = .held },
        .{ .steering = .{ .shields = -1 }, .throttle = .held },
    };
    var buffer: [32]u8 = undefined;
    for (commands) |command| {
        var writer = std.Io.Writer.fixed(&buffer);
        try write(&writer, command);
        var reader = std.Io.Reader.fixed(writer.buffered());
        try std.testing.expectEqualDeep(command, try read(&reader));
        try std.testing.expectEqual(0, reader.bufferedLen());
    }
    var invalid = std.Io.Reader.fixed(&.{255});
    try std.testing.expectError(error.InvalidFlightInput, read(&invalid));
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.InvalidFlightInput, write(&writer, .{ .steering = .{ .axes = .{ 0, 2, 0 } } }));
}

test "a throttle press can be replaced and two toggles cancel before delivery" {
    var pending: Presses = .{};
    var command: flight.Command = .{ .throttle = .{ .keys = .{ .zero = true } }, .toggle_afterburner = true };
    pending.take(&command);
    try std.testing.expect(!command.throttle.keys.zero);
    try std.testing.expect(!command.toggle_afterburner);
    command.throttle.keys.full = true;
    command.toggle_afterburner = true;
    pending.take(&command);
    pending.apply(&command);
    try std.testing.expect(command.throttle.keys.full);
    try std.testing.expect(!command.throttle.keys.zero);
    try std.testing.expect(!command.toggle_afterburner);
}
