//! Messages used by the direct-IP session. Every message fits in one datagram.
const std = @import("std");
const version = @import("version");
const identity = @import("identity.zig");

pub const revision: u16 = 2;
pub const slots = 3;
pub const beacon_count = @import("openreliant").engine.game.deathmatch.six_beacons.required;
// A tag and tick, three full ship records, and six loose beacons.
const max_snapshot_size = 1 + @sizeOf(u32) + slots * (@sizeOf(u64) + 3 * @sizeOf(f32)) + 1 + beacon_count * (1 + 3 * @sizeOf(f32));
pub const capacity = @max(max_snapshot_size, 1 + identity.Certificate.max_public_size);
const max_release = 96;

pub const Steering = enum(i8) { left = -1, straight = 0, right = 1 };
pub const Input = struct {
    sequence: u32,
    steering: Steering,

    /// Compare serial numbers across a wrap. The half-range is ambiguous.
    pub fn follows(input: Input, previous: ?u32) bool {
        const accepted = previous orelse return true;
        return @as(i32, @bitCast(input.sequence -% accepted)) > 0;
    }
};
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
pub const Beacon = union(enum(u8)) { loose: [3]f32, carried: u8 };
pub const Objectives = union(enum(u8)) { none, six_beacons: [beacon_count]Beacon };
pub const Snapshot = struct { tick: u32, ships: [slots]?Ship, objectives: Objectives = .none };

fn writePosition(writer: *std.Io.Writer, position: [3]f32) !void {
    for (position) |axis| try writer.writeInt(u32, @bitCast(axis), .little);
}

fn readPosition(reader: *std.Io.Reader) ![3]f32 {
    var position: [3]f32 = undefined;
    for (&position) |*axis| {
        axis.* = @bitCast(try reader.takeInt(u32, .little));
        if (!std.math.isFinite(axis.*)) return error.InvalidPosition;
    }
    return position;
}

pub const Message = union(enum(u8)) {
    join: Version,
    wrong_protocol: Version,
    joined: Admission,
    input: Input,
    view: Snapshot,
    finished: Snapshot,
    leave,
    received_final: u32,
    request_identity: [identity.PublicKey.encoded_length]u8,
    issued_identity: []const u8,

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
                    try writePosition(&w, ship.position);
                }
                try w.writeByte(@backingInt(std.meta.activeTag(view.objectives)));
                switch (view.objectives) {
                    .none => {},
                    .six_beacons => |beacons| for (beacons) |beacon| {
                        try w.writeByte(@backingInt(std.meta.activeTag(beacon)));
                        switch (beacon) {
                            .loose => |position| try writePosition(&w, position),
                            .carried => |slot| try w.writeByte(slot),
                        }
                    },
                }
            },
            .leave => {},
            .received_final => |tick| try w.writeInt(u32, tick, .little),
            .request_identity => |key| try w.writeAll(&key),
            .issued_identity => |cert| {
                if (cert.len == 0 or cert.len > identity.Certificate.max_public_size) return error.InvalidIdentityCertificate;
                try w.writeAll(cert);
            },
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
                    entry.* = .{ .generation = generation, .position = try readPosition(&r) };
                }
                view.objectives = switch (try r.takeEnum(std.meta.Tag(Objectives), .little)) {
                    .none => .none,
                    .six_beacons => objectives: {
                        var beacons: [beacon_count]Beacon = undefined;
                        for (&beacons) |*beacon| {
                            beacon.* = switch (try r.takeEnum(std.meta.Tag(Beacon), .little)) {
                                .loose => .{ .loose = try readPosition(&r) },
                                .carried => carrier: {
                                    const slot = try r.takeByte();
                                    if (slot >= slots or view.ships[slot] == null) return error.InvalidBeaconCarrier;
                                    break :carrier .{ .carried = slot };
                                },
                            };
                        }
                        break :objectives .{ .six_beacons = beacons };
                    },
                };
                break :snapshot if (tag == .view) .{ .view = view } else .{ .finished = view };
            },
            .leave => .leave,
            .received_final => .{ .received_final = try r.takeInt(u32, .little) },
            .request_identity => .{ .request_identity = (try r.takeArray(identity.PublicKey.encoded_length)).* },
            .issued_identity => issued: {
                const len = r.bufferedLen();
                if (len == 0 or len > identity.Certificate.max_public_size) return error.InvalidIdentityCertificate;
                break :issued .{ .issued_identity = try r.take(len) };
            },
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

test "input sequence accepts fresh commands across a wrap" {
    const input: Input = .{ .sequence = 0, .steering = .straight };
    try std.testing.expect(input.follows(null));
    try std.testing.expect(input.follows(std.math.maxInt(u32)));
    try std.testing.expect(!input.follows(0));
    try std.testing.expect(!input.follows(1));
}

test "a final receipt names the applied tick" {
    var buffer: [capacity]u8 = undefined;
    const receipt: Message = .{ .received_final = 175 };
    try std.testing.expectEqualDeep(receipt, try Message.decode(try receipt.encode(&buffer)));
}

test "flight updates fit the direct-IP payload budget" {
    const input_bytes = 6;
    const full_snapshot_bytes = 66;
    var buffer: [capacity]u8 = undefined;
    const input: Message = .{ .input = .{ .sequence = 1, .steering = .straight } };
    const view: Message = .{ .view = .{
        .tick = 1,
        .ships = @splat(.{ .generation = 1, .position = .{ 1, 2, 3 } }),
    } };
    try std.testing.expectEqual(input_bytes, (try input.encode(&buffer)).len);
    try std.testing.expectEqual(full_snapshot_bytes, (try view.encode(&buffer)).len);
}

test "the objective view fits one packet and a carrier needs a current ship" {
    var buffer: [capacity]u8 = undefined;
    var view: Message = .{ .view = .{
        .tick = 3,
        .ships = @splat(.{ .generation = 2, .position = @splat(0) }),
        .objectives = .{ .six_beacons = @splat(.{ .loose = .{ 2, 3, 4 } }) },
    } };
    const bytes = try view.encode(&buffer);
    try std.testing.expectEqual(max_snapshot_size, bytes.len);
    try std.testing.expectEqualDeep(view, try Message.decode(bytes));
    view.view.objectives.six_beacons[0] = .{ .carried = 1 };
    try std.testing.expectEqualDeep(view, try Message.decode(try view.encode(&buffer)));
    view.view.ships[1] = null;
    try std.testing.expectError(error.InvalidBeaconCarrier, Message.decode(try view.encode(&buffer)));
}
