//! Messages used by the direct-IP session. Every message fits in one datagram.
const std = @import("std");
const version = @import("version");

pub const revision: u16 = 1;
pub const capacity = 128;
pub const slots = 3;
const max_release = 96;

pub const Steering = enum(i8) { left = -1, straight = 0, right = 1 };
pub const Input = struct { sequence: u32, steering: Steering };
pub const Admission = struct { slot: u8, generation: u64 };
pub const Version = struct {
    protocol: u16,
    release: []const u8,

    pub const local: Version = .{ .protocol = revision, .release = version.string };

    pub fn compatible(peer: Version) bool {
        return peer.protocol == revision;
    }
};
pub const Ship = struct { generation: u64, position: [3]f32 };
pub const Snapshot = struct { tick: u32, ships: [slots]?Ship };

pub const Message = union(enum(u8)) {
    join: Version,
    wrong_protocol: Version,
    joined: Admission,
    input: Input,
    view: Snapshot,
    finished: Snapshot,
    leave,

    pub fn encode(message: Message, buffer: []u8) ![]const u8 {
        var w = std.Io.Writer.fixed(buffer);
        try w.writeByte(@backingInt(std.meta.activeTag(message)));
        switch (message) {
            .join, .wrong_protocol => |peer| {
                if (peer.release.len == 0 or peer.release.len > max_release) return error.InvalidVersion;
                try w.writeInt(u16, peer.protocol, .little);
                try w.writeByte(@intCast(peer.release.len));
                try w.writeAll(peer.release);
            },
            .joined => |id| {
                try w.writeByte(id.slot);
                try w.writeInt(u64, id.generation, .little);
            },
            .input => |input| {
                try w.writeInt(u32, input.sequence, .little);
                try w.writeByte(@bitCast(@backingInt(input.steering)));
            },
            .view, .finished => |view| {
                try w.writeInt(u32, view.tick, .little);
                for (view.ships) |entry| {
                    const ship = entry orelse {
                        try w.writeInt(u64, 0, .little);
                        continue;
                    };
                    try w.writeInt(u64, ship.generation, .little);
                    for (ship.position) |axis| try w.writeInt(u32, @bitCast(axis), .little);
                }
            },
            .leave => {},
        }
        return w.buffered();
    }

    pub fn decode(bytes: []const u8) !Message {
        if (bytes.len > capacity) return error.MessageTooLarge;
        var r = std.Io.Reader.fixed(bytes);
        const tag = try r.takeEnum(std.meta.Tag(Message), .little);
        const message: Message = switch (tag) {
            .join, .wrong_protocol => pair: {
                const protocol = try r.takeInt(u16, .little);
                const length = try r.takeByte();
                if (length == 0 or length > max_release) return error.InvalidVersion;
                const release = try r.take(length);
                for (release) |byte| if (!std.ascii.isPrint(byte)) return error.InvalidVersion;
                const peer: Version = .{ .protocol = protocol, .release = release };
                break :pair if (tag == .join) .{ .join = peer } else .{ .wrong_protocol = peer };
            },
            .joined => admitted: {
                const slot = try r.takeByte();
                const generation = try r.takeInt(u64, .little);
                if (slot >= slots or generation == 0) return error.InvalidAdmission;
                break :admitted .{ .joined = .{ .slot = slot, .generation = generation } };
            },
            .input => .{ .input = .{
                .sequence = try r.takeInt(u32, .little),
                .steering = try r.takeEnum(Steering, .little),
            } },
            .view, .finished => snapshot: {
                var view: Snapshot = .{ .tick = try r.takeInt(u32, .little), .ships = @splat(null) };
                for (&view.ships) |*entry| {
                    const generation = try r.takeInt(u64, .little);
                    if (generation == 0) continue;
                    var ship: Ship = .{ .generation = generation, .position = undefined };
                    for (&ship.position) |*axis| {
                        axis.* = @bitCast(try r.takeInt(u32, .little));
                        if (!std.math.isFinite(axis.*)) return error.InvalidPosition;
                    }
                    entry.* = ship;
                }
                break :snapshot if (tag == .view) .{ .view = view } else .{ .finished = view };
            },
            .leave => .leave,
        };
        if (r.bufferedLen() != 0) return error.TrailingData;
        return message;
    }
};

test "versions compare by protocol and snapshots retain slot identities" {
    var buffer: [capacity]u8 = undefined;
    const local: Message = .{ .join = .{ .protocol = revision, .release = "1.0.1" } };
    try std.testing.expect((try Message.decode(try local.encode(&buffer))).join.compatible());
    const old: Message = .{ .join = .{ .protocol = revision - 1, .release = "next" } };
    try std.testing.expect(!(try Message.decode(try old.encode(&buffer))).join.compatible());
    const view: Message = .{ .view = .{ .tick = 12, .ships = .{ .{ .generation = 4, .position = .{ 1, 2, 3 } }, null, null } } };
    const bytes = try view.encode(&buffer);
    try std.testing.expectEqualDeep(view, try Message.decode(bytes));
    try std.testing.expectError(error.EndOfStream, Message.decode(bytes[0 .. bytes.len - 1]));
}
