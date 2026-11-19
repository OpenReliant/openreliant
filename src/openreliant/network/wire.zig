//! Messages used by the direct-IP session. Every message fits in one datagram.
const std = @import("std");
const version = @import("version");
const flight_input = @import("flight_input.zig");
const engine = @import("openreliant").engine;
const flight = engine.input.flight;
pub const Fighter = engine.game.dmscenarios.Fighter;
pub const Scenario = engine.game.dmscenarios.Scenario;
pub const revision: u16 = 7;
pub const slots = 3;
pub const step_us = engine.game.gameobj.ticks_per_step * std.time.us_per_s / engine.game.main.ticks_per_second;
pub const beacon_count = engine.game.deathmatch.six_beacons.required;
const guns = engine.game.guns;
pub const Combat = struct {
    pub const max = 8;
    const largest_effect = 1 + 1 + @sizeOf(u16) + 1 + 2 * @sizeOf(i32) + 6 * @sizeOf(f32);
    pub const capacity = 1 + 1 + max * largest_effect;
    entries: [max]guns.FlightEffect = undefined,
    count: usize = 0,

    pub fn items(combat: *const Combat) []const guns.FlightEffect {
        return combat.entries[0..combat.count];
    }
};
// A tag and tick, three full ship records, and six loose beacons.
const snapshot_capacity = 1 + @sizeOf(u32) + slots * Ship.encoded_size + 1 + beacon_count * (1 + 3 * @sizeOf(f32));
pub const capacity = @max(snapshot_capacity, Combat.capacity);
const max_release = 96;

pub const Input = struct {
    sequence: u32,
    command: flight.Command,
    /// A held trigger names the ship the player saw when they pressed it.
    fire_for: ?u32 = null,

    /// Compare serial numbers across a wrap. The half-range is ambiguous.
    pub fn follows(input: Input, previous: ?u32) bool {
        const accepted = previous orelse return true;
        return @as(i32, @bitCast(input.sequence -% accepted)) > 0;
    }
};
pub const Admission = struct { slot: u8, generation: u64, scenario: ?Scenario = null };
pub const CallSign = engine.game.interface.pilot_roster.CallSign;
pub const Lobby = [slots]?CallSign;
pub const BeaconNotice = struct { event: engine.game.deathmatch.six_beacons.Notice, name: CallSign };

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
    reuse: u32 = 0,
    fighter: Fighter = .predator,
    position: [3]f32,
    // Signed half-turns keep the three angles to six bytes per ship.
    angles: [3]i16 = @splat(0),
    speed: f32 = 0,
    throttle: f32 = 0,
    fuel: i32 = 0,
    shields: engine.game.gameobj.Quadrants = .all(0),
    armor: engine.game.gameobj.Quadrants = .all(0),
    kills: i32 = 0,
    deaths: u32 = 0,

    const encoded_size = @sizeOf(u64) + @sizeOf(u32) + 1 + 13 * @sizeOf(f32) + 3 * @sizeOf(i16) + 3 * @sizeOf(i32);

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

fn writeObject(w: *std.Io.Writer, object: engine.game.gameobj.ObjectRef) !void {
    try w.writeInt(u16, object.slot, .little);
    try w.writeInt(u32, object.reuse, .little);
}

fn readObject(r: *std.Io.Reader) !engine.game.gameobj.ObjectRef {
    return .{ .slot = try r.takeInt(u16, .little), .reuse = try r.takeInt(u32, .little) };
}

fn writeCombat(w: *std.Io.Writer, combat: *const Combat) !void {
    try w.writeByte(@intCast(combat.count));
    for (combat.items()) |effect| {
        try w.writeByte(@backingInt(std.meta.activeTag(effect)));
        switch (effect) {
            .shot => |shot| {
                try w.writeByte(shot.index);
                try w.writeInt(u16, shot.owner, .little);
                try w.writeByte(@backingInt(shot.kind));
                try w.writeInt(i32, shot.fired_at, .little);
                try w.writeInt(i32, shot.dies_at, .little);
                try writePosition(w, shot.origin);
                try writePosition(w, shot.velocity);
            },
            .impact => |hit| {
                try w.writeByte(hit.shot);
                try w.writeInt(i32, hit.fired_at, .little);
                try writeObject(w, hit.target);
                try writePosition(w, hit.at);
                try w.writeByte(@backingInt(hit.kind));
            },
            .nova => |beam| {
                try writeObject(w, beam.owner);
                try writeFloat(w, beam.charge);
                try w.writeInt(i32, beam.fired_at, .little);
            },
        }
    }
}

fn readCombat(r: *std.Io.Reader) !Combat {
    var combat: Combat = .{ .count = try r.takeByte() };
    if (combat.count == 0 or combat.count > Combat.max) return error.InvalidCombat;
    for (combat.entries[0..combat.count]) |*entry| {
        entry.* = switch (try r.takeEnum(std.meta.Tag(guns.FlightEffect), .little)) {
            .shot => shot: {
                const index = try r.takeByte();
                const owner = try r.takeInt(u16, .little);
                const kind = std.enums.fromInt(guns.GameGun, try r.takeByte()) orelse return error.InvalidCombat;
                const fired_at = try r.takeInt(i32, .little);
                const dies_at = try r.takeInt(i32, .little);
                const origin = try readPosition(r);
                const velocity = try readPosition(r);
                if (index >= guns.max_bullets or owner >= slots or fired_at < 0 or dies_at <= fired_at or
                    !std.math.isFinite(engine.surrender.math.lengthSquared(velocity)) or engine.surrender.math.lengthSquared(velocity) == 0)
                    return error.InvalidCombat;
                break :shot .{ .shot = .{
                    .index = index,
                    .owner = owner,
                    .kind = kind,
                    .fired_at = fired_at,
                    .dies_at = dies_at,
                    .origin = origin,
                    .velocity = velocity,
                } };
            },
            .impact => impact: {
                const shot = try r.takeByte();
                const fired_at = try r.takeInt(i32, .little);
                const target = try readObject(r);
                const at = try readPosition(r);
                const kind = try r.takeEnum(guns.FlightEffect.Impact.Surface, .little);
                if (shot >= guns.max_bullets or fired_at < 0) return error.InvalidCombat;
                break :impact .{ .impact = .{ .shot = shot, .fired_at = fired_at, .target = target, .at = at, .kind = kind } };
            },
            .nova => nova: {
                const owner = try readObject(r);
                const charge = try readFloat(r);
                const fired_at = try r.takeInt(i32, .little);
                if (owner.slot >= slots or charge <= 0 or charge > guns.nova.full_charge or fired_at < 0) return error.InvalidCombat;
                break :nova .{ .nova = .{ .owner = owner, .charge = charge, .fired_at = fired_at } };
            },
        };
    }
    return combat;
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
    pick_ship: Fighter,
    beacon_notice: BeaconNotice,
    combat: Combat,

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
                try w.writeByte(if (id.scenario) |scenario| @backingInt(scenario) + 1 else 0);
            },
            .input => |input| {
                try w.writeInt(u32, input.sequence, .little);
                try flight_input.write(&w, input.command);
                if (input.fire_for) |reuse| try w.writeInt(u32, reuse, .little);
            },
            .view, .finished => |view| {
                try w.writeInt(u32, view.tick, .little);
                for (view.ships) |entry| {
                    const ship = entry orelse {
                        try w.writeInt(u64, 0, .little);
                        continue;
                    };
                    try w.writeInt(u64, ship.generation, .little);
                    try w.writeInt(u32, ship.reuse, .little);
                    try w.writeByte(@backingInt(ship.fighter));
                    try writePosition(&w, ship.position);
                    for (ship.angles) |angle| try w.writeInt(i16, angle, .little);
                    try writeFloat(&w, ship.speed);
                    try writeFloat(&w, ship.throttle);
                    try w.writeInt(i32, ship.fuel, .little);
                    for (ship.shields.values()) |value| try writeFloat(&w, value);
                    for (ship.armor.values()) |value| try writeFloat(&w, value);
                    try w.writeInt(i32, ship.kills, .little);
                    try w.writeInt(u32, ship.deaths, .little);
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
            .pick_ship => |fighter| try w.writeByte(@backingInt(fighter)),
            .beacon_notice => |notice| {
                try w.writeByte(@intCast(notice.event.pilot.slot));
                try w.writeInt(u64, notice.event.pilot.generation, .little);
                try w.writeInt(i32, notice.event.tick, .little);
                try w.writeInt(u16, @backingInt(notice.event.kind), .little);
                try writeCallSign(&w, &notice.name);
            },
            .combat => |combat| try writeCombat(&w, &combat),
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
                const code = try r.takeByte();
                const scenario = if (code == 0) null else std.enums.fromInt(Scenario, code - 1) orelse return error.InvalidAdmission;
                if (slot >= slots or generation == 0) return error.InvalidAdmission;
                break :admitted .{ .joined = .{ .slot = slot, .generation = generation, .scenario = scenario } };
            },
            .input => .{ .input = .{
                .sequence = try r.takeInt(u32, .little),
                .command = try flight_input.read(&r),
                .fire_for = if (r.bufferedLen() == 0) null else try r.takeInt(u32, .little),
            } },
            .view, .finished => snapshot: {
                var view: Snapshot = .{ .tick = try r.takeInt(u32, .little), .ships = @splat(null) };
                for (&view.ships) |*entry| {
                    const generation = try r.takeInt(u64, .little);
                    if (generation == 0) continue;
                    var ship: Ship = .{ .generation = generation, .reuse = try r.takeInt(u32, .little), .fighter = try r.takeEnum(Fighter, .little), .position = try readPosition(&r) };
                    for (&ship.angles) |*angle| angle.* = try r.takeInt(i16, .little);
                    ship.speed = try readFloat(&r);
                    ship.throttle = try readFloat(&r);
                    ship.fuel = try r.takeInt(i32, .little);
                    for (std.enums.values(engine.game.collision.Quadrant)) |quadrant| ship.shields.at(quadrant).* = try readFloat(&r);
                    for (std.enums.values(engine.game.collision.Quadrant)) |quadrant| ship.armor.at(quadrant).* = try readFloat(&r);
                    ship.kills = try r.takeInt(i32, .little);
                    ship.deaths = try r.takeInt(u32, .little);
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
            .pick_ship => .{ .pick_ship = try r.takeEnum(Fighter, .little) },
            .beacon_notice => notice: {
                const slot = try r.takeByte();
                const generation = try r.takeInt(u64, .little);
                const tick = try r.takeInt(i32, .little);
                const kind = try r.takeEnum(engine.game.deathmatch.six_beacons.Notice.Kind, .little);
                if (slot >= slots or generation == 0 or tick < 0) return error.InvalidBeaconNotice;
                break :notice .{ .beacon_notice = .{ .event = .{ .pilot = .{ .slot = slot, .generation = generation }, .tick = tick, .kind = kind }, .name = try readCallSign(&r) } };
            },
            .combat => .{ .combat = try readCombat(&r) },
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

test "held primary input names one ship and adds no bytes when released" {
    var buffer: [capacity]u8 = undefined;
    var message: Message = .{ .input = .{ .sequence = 17, .command = .{} } };
    const released = (try message.encode(&buffer)).len;
    message.input.fire_for = 48;
    const held = try message.encode(&buffer);
    try std.testing.expectEqual(released + @sizeOf(u32), held.len);
    try std.testing.expectEqualDeep(message, try Message.decode(held));
    try std.testing.expectError(error.EndOfStream, Message.decode(held[0 .. held.len - 1]));
}

test "combat batches carry visual effects with bounded counts and pool indices" {
    var buffer: [capacity]u8 = undefined;
    var effects: Combat = .{ .count = 3 };
    effects.entries[0..3].* = .{
        .{ .shot = .{ .index = 4, .owner = 0, .kind = .pulse_cannon, .fired_at = 84, .dies_at = 124, .origin = .{ 1, 2, 3 }, .velocity = .{ 0, 0, 1 } } },
        .{ .impact = .{ .shot = 4, .fired_at = 84, .target = .{ .slot = 2, .reuse = 7 }, .at = .{ 1, 2, 20 }, .kind = .shield } },
        .{ .nova = .{ .owner = .{ .slot = 2, .reuse = 7 }, .charge = 0.75, .fired_at = 85 } },
    };
    const content = try (Message{ .combat = effects }).encode(&buffer);
    const decoded = (try Message.decode(content)).combat;
    try std.testing.expectEqualDeep(effects.items(), decoded.items());
    effects.entries[0].shot.index = guns.max_bullets;
    try std.testing.expectError(error.InvalidCombat, Message.decode(try (Message{ .combat = effects }).encode(&buffer)));
    try std.testing.expectError(error.InvalidCombat, Message.decode(&.{ @backingInt(std.meta.Tag(Message).combat), Combat.max + 1 }));
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

test "fighter choices and reliable beacon notices have bounded wire fields" {
    var buffer: [capacity]u8 = undefined;
    const select: Message = .{ .pick_ship = .shroud };
    try std.testing.expectEqual(.shroud, (try Message.decode(try select.encode(&buffer))).pick_ship);
    try std.testing.expectError(error.InvalidEnumTag, Message.decode(&.{ @backingInt(std.meta.Tag(Message).pick_ship), 255 }));
    const sent: Message = .{ .beacon_notice = .{
        .event = .{ .pilot = .{ .slot = 1, .generation = 3 }, .tick = 120, .kind = .triggered },
        .name = lobbyName("Viper"),
    } };
    const received = (try Message.decode(try sent.encode(&buffer))).beacon_notice;
    try std.testing.expectEqual(sent.beacon_notice.event, received.event);
    try std.testing.expectEqualStrings("Viper", received.name.slice());
}

test "a final receipt names the applied tick" {
    var buffer: [capacity]u8 = undefined;
    const receipt: Message = .{ .received_final = 175 };
    try std.testing.expectEqualDeep(receipt, try Message.decode(try receipt.encode(&buffer)));
}

test "flight updates fit the direct-IP payload budget" {
    const input_bytes = 25;
    // A fighter byte and a ship reuse count distinguish a respawn from a new admission.
    const full_snapshot_bytes = 255;
    const objective_snapshot_budget = 336;
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
    var with_objectives = view;
    with_objectives.view.objectives = .{ .six_beacons = @splat(.{ .loose = .{ 1, 2, 3 } }) };
    try std.testing.expect((try with_objectives.encode(&buffer)).len <= objective_snapshot_budget);
}

test "the objective view fits one packet and a carrier needs a current ship" {
    var buffer: [capacity]u8 = undefined;
    var view: Message = .{ .view = .{
        .tick = 3,
        .ships = @splat(.{ .generation = 2, .position = @splat(0) }),
        .objectives = .{ .six_beacons = @splat(.{ .loose = .{ 2, 3, 4 } }) },
    } };
    try std.testing.expectEqual(snapshot_capacity, (try view.encode(&buffer)).len);
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
