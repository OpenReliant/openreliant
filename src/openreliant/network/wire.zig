//! Messages used by the direct-IP session. Every message fits in one datagram.
const std = @import("std");
const version = @import("version");
const flight_input = @import("flight_input.zig");
const engine = @import("openreliant").engine;
const flight = engine.input.flight;
pub const arena_ship: engine.game.gameobj.Type = .of(.predator);
pub const revision: u16 = 5;
pub const slots = 3;
pub const step_us = engine.game.gameobj.ticks_per_step * std.time.us_per_s / engine.game.main.ticks_per_second;
pub const beacon_count = engine.game.deathmatch.six_beacons.required;
// A tag and tick, three full ship records, and six loose beacons.
pub const capacity = 1 + @sizeOf(u32) + slots * Ship.encoded_size + 1 + beacon_count * (1 + 3 * @sizeOf(f32));
const max_release = 96;

pub const Input = struct {
    sequence: u32,
    command: flight.Command,

    /// Compare serial numbers across a wrap. The half-range is ambiguous.
    pub fn follows(input: Input, previous: ?u32) bool {
        const accepted = previous orelse return true;
        return @as(i32, @bitCast(input.sequence -% accepted)) > 0;
    }
};
pub const Admission = struct { slot: u8, generation: u64 };
pub const CallSign = engine.game.interface.pilot_roster.CallSign;
pub const Lobby = [slots]?CallSign;

fn validCallSignByte(byte: u8) bool {
    return byte >= ' ' and byte != 0x7f;
}

pub fn lobbyName(profile: []const u8) CallSign {
    var name: CallSign = .{};
    for (profile[0..@min(profile.len, name.bytes.len)]) |byte| {
        if (!validCallSignByte(byte)) continue;
        name.bytes[name.len] = byte;
        name.len += 1;
    }
    name.set(std.mem.trim(u8, name.slice(), " "));
    return name;
}

fn writeCallSign(writer: *std.Io.Writer, name: *const CallSign) !void {
    try writer.writeByte(@intCast(name.len));
    try writer.writeAll(name.slice());
}

fn readCallSign(reader: *std.Io.Reader) !CallSign {
    var name: CallSign = .{};
    const length = try reader.takeByte();
    if (length > name.bytes.len) return error.InvalidCallSign;
    const bytes = try reader.take(length);
    for (bytes) |byte| {
        // The front end uses the game's code page. Exclude control characters.
        if (!validCallSignByte(byte)) return error.InvalidCallSign;
    }
    name.set(bytes);
    return name;
}
pub const Version = struct {
    protocol: u16,
    release: []const u8,

    pub const local: Version = .{ .protocol = revision, .release = version.string };

    pub fn compatible(peer: Version) bool {
        return peer.protocol == revision;
    }
};
pub const Ship = struct {
    generation: u64,
    position: [3]f32,
    // Signed half-turns keep the three angles to six bytes per ship.
    angles: [3]i16 = @splat(0),
    speed: f32 = 0,
    throttle: f32 = 0,
    fuel: i32 = 0,

    const encoded_size = @sizeOf(u64) + 5 * @sizeOf(f32) + 3 * @sizeOf(i16) + @sizeOf(i32);

    pub fn face(ship: *Ship, orientation: engine.surrender.math.Matrix) void {
        const radians = engine.surrender.math.angles(orientation);
        inline for (&ship.angles, 0..) |*angle, i| angle.* = @intFromFloat(@round(radians[i] * (32767.0 / std.math.pi)));
    }

    pub fn orientationMatrix(ship: Ship) engine.surrender.math.Matrix {
        var angles: engine.surrender.math.Vector = undefined;
        inline for (ship.angles, 0..) |angle, i| angles[i] = @as(f32, @floatFromInt(angle)) * (std.math.pi / 32767.0);
        return engine.surrender.math.fromAngleVector(angles);
    }
};
pub const Beacon = union(enum(u8)) { loose: [3]f32, carried: u8 };
pub const Objectives = union(enum(u8)) { none, six_beacons: [beacon_count]Beacon };
pub const Snapshot = struct { tick: u32, ships: [slots]?Ship, objectives: Objectives = .none };

fn writePosition(writer: *std.Io.Writer, position: [3]f32) !void {
    for (position) |axis| try writeFloat(writer, axis);
}

fn readPosition(reader: *std.Io.Reader) ![3]f32 {
    var position: [3]f32 = undefined;
    for (&position) |*axis| {
        axis.* = try readFloat(reader);
    }
    return position;
}

fn writeFloat(writer: *std.Io.Writer, value: f32) !void {
    try writer.writeInt(u32, @bitCast(value), .little);
}

fn readFloat(reader: *std.Io.Reader) !f32 {
    const value: f32 = @bitCast(try reader.takeInt(u32, .little));
    if (!std.math.isFinite(value)) return error.InvalidSnapshot;
    return value;
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
    flight_press: flight_input.Presses,
    lobby: Lobby,
    call_sign: CallSign,

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
                try flight_input.write(&w, input.command);
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
                    for (ship.angles) |angle| try w.writeInt(i16, angle, .little);
                    try writeFloat(&w, ship.speed);
                    try writeFloat(&w, ship.throttle);
                    try w.writeInt(i32, ship.fuel, .little);
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
            .flight_press => |presses| try w.writeByte(@bitCast(presses)),
            .lobby => |roster| for (roster) |name| {
                try w.writeByte(@intFromBool(name != null));
                if (name) |present| try writeCallSign(&w, &present);
            },
            .call_sign => |name| try writeCallSign(&w, &name),
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
                .command = try flight_input.read(&r),
            } },
            .view, .finished => snapshot: {
                var view: Snapshot = .{ .tick = try r.takeInt(u32, .little), .ships = @splat(null) };
                for (&view.ships) |*entry| {
                    const generation = try r.takeInt(u64, .little);
                    if (generation == 0) continue;
                    var ship: Ship = .{ .generation = generation, .position = try readPosition(&r) };
                    for (&ship.angles) |*angle| angle.* = try r.takeInt(i16, .little);
                    ship.speed = try readFloat(&r);
                    ship.throttle = try readFloat(&r);
                    ship.fuel = try r.takeInt(i32, .little);
                    const motion = engine.game.motion;
                    if (ship.throttle < motion.reverse_throttle or ship.throttle > motion.afterburner_throttle or ship.fuel < 0)
                        return error.InvalidSnapshot;
                    entry.* = ship;
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
            .flight_press => presses: {
                const value: flight_input.Presses = @bitCast(try r.takeByte());
                if (value.reserved != 0 or !value.any()) return error.InvalidFlightInput;
                break :presses .{ .flight_press = value };
            },
            .lobby => roster: {
                var roster: Lobby = undefined;
                for (&roster) |*entry| entry.* = switch (try r.takeByte()) {
                    0 => null,
                    1 => try readCallSign(&r),
                    else => return error.InvalidLobby,
                };
                if (roster[0] == null) return error.InvalidLobby;
                break :roster .{ .lobby = roster };
            },
            .call_sign => .{ .call_sign = try readCallSign(&r) },
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
    const view: Message = .{ .view = .{ .tick = 12, .ships = .{ .{
        .generation = 4,
        .position = .{ 1, 2, 3 },
        .angles = .{ -1234, 5, 678 },
        .speed = 37.5,
        .throttle = engine.game.motion.afterburner_throttle,
        .fuel = 650,
    }, null, null } } };
    const bytes = try view.encode(&buffer);
    try std.testing.expectEqualDeep(view, try Message.decode(bytes));
    try std.testing.expectError(error.EndOfStream, Message.decode(bytes[0 .. bytes.len - 1]));
}

test "input sequence accepts fresh commands across a wrap" {
    const input: Input = .{ .sequence = 0, .command = .{} };
    try std.testing.expect(input.follows(null));
    try std.testing.expect(input.follows(std.math.maxInt(u32)));
    try std.testing.expect(!input.follows(0));
    try std.testing.expect(!input.follows(1));
}

test "a lobby preserves occupied slots and treats callsigns as bounded display text" {
    const host_name = lobbyName("  Falcon\x00  ");
    const guest_name = lobbyName("\xc9toile");
    const message: Message = .{ .lobby = .{ host_name, null, guest_name } };
    var buffer: [capacity]u8 = undefined;
    const decoded = (try Message.decode(try message.encode(&buffer))).lobby;
    try std.testing.expectEqualStrings("Falcon", decoded[0].?.slice());
    try std.testing.expectEqual(null, decoded[1]);
    try std.testing.expectEqualStrings("\xc9toile", decoded[2].?.slice());
    const call_sign = @backingInt(std.meta.Tag(Message).call_sign);
    try std.testing.expectError(error.InvalidCallSign, Message.decode(&.{ call_sign, 32 }));
    try std.testing.expectError(error.InvalidCallSign, Message.decode(&.{ call_sign, 1, '\n' }));
    try std.testing.expectError(error.InvalidLobby, Message.decode(&.{ @backingInt(std.meta.Tag(Message).lobby), 0, 0, 0 }));
}

test "a final receipt names the applied tick" {
    var buffer: [capacity]u8 = undefined;
    const receipt: Message = .{ .received_final = 175 };
    try std.testing.expectEqualDeep(receipt, try Message.decode(try receipt.encode(&buffer)));
}

test "flight updates fit the direct-IP payload budget" {
    const input_bytes = 25;
    const full_snapshot_bytes = 120;
    var buffer: [capacity]u8 = undefined;
    const input: Message = .{ .input = .{ .sequence = 1, .command = .{
        .steering = .{ .axes = .{ 0.2, -0.5, 0.8 } },
        .throttle = .{ .axis = 0.75 },
        .strafe = .positive,
        .afterburner = true,
    } } };
    const view: Message = .{ .view = .{
        .tick = 1,
        .ships = @splat(.{ .generation = 1, .position = .{ 1, 2, 3 } }),
    } };
    const encoded = try input.encode(&buffer);
    try std.testing.expectEqual(input_bytes, encoded.len);
    try std.testing.expectEqualDeep(input, try Message.decode(encoded));
    try std.testing.expectEqual(full_snapshot_bytes, (try view.encode(&buffer)).len);
}

test "the objective view fits one packet and a carrier needs a current ship" {
    var buffer: [capacity]u8 = undefined;
    var view: Message = .{ .view = .{
        .tick = 3,
        .ships = @splat(.{ .generation = 2, .position = @splat(0) }),
        .objectives = .{ .six_beacons = @splat(.{ .loose = .{ 2, 3, 4 } }) },
    } };
    try std.testing.expectEqual(capacity, (try view.encode(&buffer)).len);
    try std.testing.expectEqualDeep(view, try Message.decode(&buffer));
    view.view.objectives.six_beacons[0] = .{ .carried = 1 };
    try std.testing.expectEqualDeep(view, try Message.decode(try view.encode(&buffer)));
    view.view.ships[1] = null;
    try std.testing.expectError(error.InvalidBeaconCarrier, Message.decode(try view.encode(&buffer)));
}

test "ship angles round-trip the host orientation" {
    const math = engine.surrender.math;
    const facing = math.fromAngles(0.42, -0.91, 2.1);
    var ship: Ship = .{ .generation = 1, .position = @splat(0) };
    ship.face(facing);
    for (facing, ship.orientationMatrix()) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0002);
    }
}
