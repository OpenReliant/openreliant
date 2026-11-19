//! Full objective snapshots for the private Six Beacons workload.
const std = @import("std");
const game = @import("openreliant").engine.game;
const objectives = game.deathmatch.six_beacons;
const ObjectRef = game.gameobj.ObjectRef;

pub const lane = 1; // Reliable events.
pub const capacity = 256;
pub const Message = enum(u8) { join, wrong_protocol, snapshot, applied, complete };
const Ownership = enum(u8) { loose, carried };

const ack_size = 1 + @sizeOf(i32);

pub fn applied(tick: i32) [ack_size]u8 {
    var bytes: [ack_size]u8 = undefined;
    bytes[0] = @backingInt(Message.applied);
    std.mem.writeInt(i32, bytes[1..], tick, .little);
    return bytes;
}

pub fn appliedTick(bytes: []const u8) !i32 {
    if (bytes.len != ack_size or bytes[0] != @backingInt(Message.applied)) return error.UnexpectedMessage;
    return std.mem.readInt(i32, bytes[1..ack_size], .little);
}

test "an acknowledgement names the exact snapshot tick" {
    const tick: i32 = 0x01020304;
    const bytes = applied(tick);
    try std.testing.expectEqualSlices(u8, &.{ @backingInt(Message.applied), 4, 3, 2, 1 }, &bytes);
    try std.testing.expectEqual(tick, try appliedTick(&bytes));
    try std.testing.expectError(error.UnexpectedMessage, appliedTick(bytes[0 .. bytes.len - 1]));
    try std.testing.expectError(error.UnexpectedMessage, appliedTick(&(bytes ++ .{0})));
    try std.testing.expectError(error.UnexpectedMessage, appliedTick(&.{ @backingInt(Message.join), 4, 3, 2, 1 }));
}

/// One reliable snapshot can await a receipt on each authenticated connection.
pub const Delivery = struct {
    pending: ?struct { tick: i32, expires: i64 } = null,
    applied: ?i32 = null,
    previous: ?i32 = null,

    pub fn accept(delivery: *Delivery, packet_lane: u16, bytes: []const u8) !void {
        const pending = delivery.pending orelse return error.UnexpectedAcknowledgement;
        if (packet_lane != lane or try appliedTick(bytes) != pending.tick) return error.WrongAcknowledgement;
        delivery.previous = delivery.applied;
        delivery.applied = pending.tick;
        delivery.pending = null;
    }
};

test "only a receipt for this pilot's outstanding snapshot advances delivery" {
    var delivery: Delivery = .{ .applied = 40, .pending = .{ .tick = 50, .expires = 1000 } };
    const before = delivery;
    const stale = applied(40);
    const current = applied(50);
    try std.testing.expectError(error.WrongAcknowledgement, delivery.accept(lane, &stale));
    try std.testing.expectError(error.WrongAcknowledgement, delivery.accept(0, &current));
    try std.testing.expectError(error.UnexpectedMessage, delivery.accept(lane, &.{}));
    try std.testing.expectEqualDeep(before, delivery);
    try delivery.accept(lane, &current);
    try std.testing.expectEqual(40, delivery.previous.?);
    try std.testing.expectEqual(50, delivery.applied.?);
    try std.testing.expectError(error.UnexpectedAcknowledgement, delivery.accept(lane, &current));
}

pub const View = struct {
    tick: i32,
    state: objectives.Snapshot,
    positions: [objectives.required][3]f32,

    pub fn capture(all: *const game.create.Objects, tick: i32) !View {
        const state = all.arena_scenario.six_beacons.snapshot();
        var positions: [objectives.required][3]f32 = undefined;
        for (state.beacons, &positions) |beacon, *position| {
            const index = beacon.object.resolve(all) orelse return error.MissingBeacon;
            const object = &all.slots[index].object;
            if (object.flags.disabled != (beacon.carrier != null)) return error.WrongVisibility;
            position.* = object.position();
        }
        return .{ .tick = tick, .state = state, .positions = positions };
    }

    pub fn encode(view: View, buffer: []u8) ![]const u8 {
        var out = std.Io.Writer.fixed(buffer);
        try out.writeByte(@backingInt(Message.snapshot));
        try out.writeInt(i32, view.tick, .little);
        for (view.state.beacons, view.positions) |beacon, position| {
            try writeRef(&out, beacon.object);
            for (position) |axis| try out.writeInt(u32, @bitCast(axis), .little);
            if (beacon.carrier) |carrier| {
                try out.writeByte(@backingInt(Ownership.carried));
                try out.writeInt(u16, carrier.participant.slot, .little);
                try out.writeInt(u64, carrier.participant.generation, .little);
                try writeRef(&out, carrier.ship);
            } else try out.writeByte(@backingInt(Ownership.loose));
        }
        return out.buffered();
    }

    pub fn decode(bytes: []const u8) !View {
        var in = std.Io.Reader.fixed(bytes);
        if (try in.takeEnum(Message, .little) != .snapshot) return error.UnexpectedMessage;
        var view: View = .{ .tick = try in.takeInt(i32, .little), .state = undefined, .positions = undefined };
        for (&view.state.beacons, &view.positions) |*beacon, *position| {
            beacon.object = try readRef(&in);
            for (position) |*axis| {
                axis.* = @bitCast(try in.takeInt(u32, .little));
                if (!std.math.isFinite(axis.*)) return error.InvalidPosition;
            }
            beacon.carrier = switch (try in.takeEnum(Ownership, .little)) {
                .loose => null,
                .carried => .{
                    .participant = .{ .slot = try in.takeInt(u16, .little), .generation = try in.takeInt(u64, .little) },
                    .ship = try readRef(&in),
                },
            };
        }
        if (in.bufferedLen() != 0) return error.TrailingData;
        return view;
    }
};

fn writeRef(out: *std.Io.Writer, ref: ObjectRef) !void {
    try out.writeInt(u16, ref.slot, .little);
    try out.writeInt(u32, ref.reuse, .little);
}

fn readRef(in: *std.Io.Reader) !ObjectRef {
    return .{ .slot = try in.takeInt(u16, .little), .reuse = try in.takeInt(u32, .little) };
}
