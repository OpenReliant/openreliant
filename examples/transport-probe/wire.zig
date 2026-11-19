//! The experimental wire format is private to the headless probe.
const std = @import("std");

pub const Lane = enum(u16) { flight, event, background };
pub const Control = enum(i8) { reverse = -1, idle = 0, forward = 1 };
pub const capacity = 1024;

pub const Frame = union(enum(u8)) {
    input: struct { applied: u16, control: Control },
    snapshot: struct { tick: u16, positions: [2]i16, sent_us: i64 },
    recall: u16,
    bulk: u16,
    finish: u16,
    done: u16,
    receipt,
    confirmed,

    const Kind = std.meta.Tag(Frame);

    pub fn lane(kind: Kind) Lane {
        return switch (kind) {
            .input, .snapshot => .flight,
            .bulk => .background,
            .recall, .finish, .done, .receipt, .confirmed => .event,
        };
    }

    fn size(kind: Kind) usize {
        return switch (kind) {
            .input => 4,
            .snapshot => 15,
            .bulk => capacity,
            .receipt, .confirmed => 1,
            .recall, .finish, .done => 3,
        };
    }

    pub fn encode(frame: Frame, buffer: *[capacity]u8) []const u8 {
        buffer[0] = @backingInt(frame);
        switch (frame) {
            .input => |input| {
                std.mem.writeInt(u16, buffer[1..3], input.applied, .little);
                buffer[3] = @bitCast(@backingInt(input.control));
            },
            .snapshot => |snapshot| {
                std.mem.writeInt(u16, buffer[1..3], snapshot.tick, .little);
                std.mem.writeInt(i16, buffer[3..5], snapshot.positions[0], .little);
                std.mem.writeInt(i16, buffer[5..7], snapshot.positions[1], .little);
                std.mem.writeInt(i64, buffer[7..15], snapshot.sent_us, .little);
            },
            .receipt, .confirmed => {},
            inline else => |value, kind| {
                std.mem.writeInt(u16, buffer[1..3], value, .little);
                if (kind == .bulk) @memset(buffer[3..], 0);
            },
        }
        return buffer[0..size(frame)];
    }

    pub fn decode(bytes: []const u8, channel: u16) !Frame {
        if (bytes.len == 0) return error.BadFrame;
        const kind = std.enums.fromInt(Kind, bytes[0]) orelse return error.BadFrame;
        if (bytes.len != size(kind) or channel != @backingInt(lane(kind))) return error.BadFrame;
        return switch (kind) {
            .input => .{ .input = .{
                .applied = std.mem.readInt(u16, bytes[1..3], .little),
                .control = std.enums.fromInt(Control, @as(i8, @bitCast(bytes[3]))) orelse return error.BadFrame,
            } },
            .snapshot => .{ .snapshot = .{
                .tick = std.mem.readInt(u16, bytes[1..3], .little),
                .sent_us = std.mem.readInt(i64, bytes[7..15], .little),
                .positions = .{ std.mem.readInt(i16, bytes[3..5], .little), std.mem.readInt(i16, bytes[5..7], .little) },
            } },
            .receipt => .receipt,
            .confirmed => .confirmed,
            inline else => |tag| @unionInit(Frame, @tagName(tag), std.mem.readInt(u16, bytes[1..3], .little)),
        };
    }
};

test "frames round trip on the assigned lane" {
    const frames = [_]Frame{
        .{ .input = .{ .applied = 267, .control = .reverse } },
        .{ .snapshot = .{ .tick = 513, .positions = .{ -123, 456 }, .sent_us = 12345678 } },
        .{ .recall = 8 },
        .{ .bulk = 10 },
        .{ .finish = 5 },
        .{ .done = 27 },
        .receipt,
    };
    var buffer: [capacity]u8 = undefined;
    for (frames) |frame| {
        const bytes = frame.encode(&buffer);
        try std.testing.expectEqualDeep(frame, try Frame.decode(bytes, @backingInt(Frame.lane(frame))));
        try std.testing.expectError(error.BadFrame, Frame.decode(bytes[0 .. bytes.len - 1], @backingInt(Frame.lane(frame))));
    }
}

test "unknown messages, wrong lanes and out of range controls are rejected" {
    try std.testing.expectError(error.BadFrame, Frame.decode(&.{255}, 0));
    try std.testing.expectError(error.BadFrame, Frame.decode(&.{ @backingInt(Frame.Kind.recall), 0, 0 }, 0));
    try std.testing.expectError(error.BadFrame, Frame.decode(&.{ @backingInt(Frame.Kind.input), 0, 0, 2 }, 0));
}
