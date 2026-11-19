//! Messages used by the direct-IP session. Every message fits in one datagram.
const std = @import("std");
const version = @import("version");
const flight_input = @import("flight_input.zig");
const engine = @import("openreliant").engine;
pub const ordnance = @import("ordnance.zig");
const flight = engine.input.flight;
pub const Fighter = engine.game.dmscenarios.Fighter;
pub const Scenario = engine.game.dmscenarios.Scenario;
pub const revision: u16 = 14;
pub const slots = 3;
pub const step_us = engine.game.gameobj.ticks_per_step * std.time.us_per_s / engine.game.main.ticks_per_second;
pub const beacon_count = engine.game.deathmatch.six_beacons.required;
const guns = engine.game.guns;
const powerups = engine.game.deathmatch.powerups;
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
// A tag, scenario, tick, three ships, and the largest scenario payload.
const snapshot_header = 2 + @sizeOf(u32) + slots * Ship.encoded_size + 1 + 1;
const beacon_snapshot_capacity = snapshot_header + beacon_count * (1 + 3 * @sizeOf(f32)) + Blast.encoded_size;
const asteroid_capacity = snapshot_header + slots + 1 + Rocks.max * (1 + @sizeOf(Facing)) +
    @sizeOf(powerups.Pickups.Mask) + @sizeOf(u32) + powerups.mine_count * Mine.encoded_size + 1 + @sizeOf(i32);
const snapshot_capacity = @max(beacon_snapshot_capacity, asteroid_capacity);
pub const capacity = @max(snapshot_capacity + ordnance.Status.capacity, Combat.capacity, ordnance.Page.capacity);
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
pub const Admission = struct { slot: u8, generation: u64 };
pub const chat = engine.game.chat;
pub const ChatScope = enum(u8) { lobby, flight, private };
pub const ChatRequest = struct {
    to: union(ChatScope) { lobby, flight, private: Admission },
    text: chat.Line,
};
pub const ChatLine = struct {
    scope: ChatScope,
    sender: u8,
    name: CallSign,
    text: chat.Line,
};

fn readChat(reader: *std.Io.Reader) !chat.Line {
    const len = try reader.takeByte();
    if (len == 0 or len > chat.capacity) return error.InvalidChat;
    const bytes = try reader.take(len);
    for (bytes) |byte| if (!chat.printable(byte)) return error.InvalidChat;
    if (chat.trim(bytes).len == 0) return error.InvalidChat;
    var text: chat.Line = .{};
    text.set(chat.trim(bytes));
    return text;
}

fn writeChat(writer: *std.Io.Writer, text: *const chat.Line) !void {
    try writer.writeByte(@intCast(text.len));
    try writer.writeAll(text.slice());
}

pub const CallSign = engine.game.interface.pilot_roster.CallSign;
pub const Roster = struct {
    lobby: ?Scenario = null,
    paused: bool = false,
    pilots: [slots]?Pilot = @splat(null),

    pub const Pilot = struct { generation: u64, name: CallSign = .{} };
};
pub const BeaconNotice = struct { event: engine.game.deathmatch.six_beacons.Notice, name: CallSign };
pub const Wreck = engine.game.deathmatch.Wreck;
/// A late effect is useful while original debris could still be present.
pub const wreck_window = 500;
pub const PilotNotice = struct {
    pilot: Admission,
    name: CallSign,
    tick: i32,
    kind: Kind,

    pub const Kind = enum(u8) { joined_flight, left_flight, left_lobby };
};

fn validCallSignByte(byte: u8) bool {
    return chat.printable(byte) and byte != ':';
}

pub fn lobbyName(profile: []const u8) CallSign {
    var name: CallSign = .{};
    for (profile[0..@min(profile.len, name.bytes.len)]) |byte| {
        if (!validCallSignByte(byte)) continue;
        name.bytes[name.len] = byte;
        name.len += 1;
    }
    name.set(chat.trim(name.slice()));
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
    angles: Facing = @splat(0),
    speed: f32 = 0,
    throttle: f32 = 0,
    fuel: i32 = 0,
    shields: engine.game.gameobj.Quadrants = .all(0),
    armor: engine.game.gameobj.Quadrants = .all(0),
    kills: i32 = 0,
    deaths: u32 = 0,
    cloaked: bool = false,
    respawn: u16 = 0,
    at_wall: bool = false,
    dying: bool = false,
    ping_ms: ?u16 = null,

    pub const unknown_ping = std.math.maxInt(u16);

    const encoded_size = @sizeOf(u64) + @sizeOf(u32) + 1 + 13 * @sizeOf(f32) + 3 * @sizeOf(i16) + 3 * @sizeOf(i32) + 2 * @sizeOf(u16) + 1;

    pub fn face(ship: *Ship, orientation: engine.surrender.math.Matrix) void {
        ship.angles = packFacing(orientation);
    }

    pub fn orientationMatrix(ship: Ship) engine.surrender.math.Matrix {
        return unpackFacing(ship.angles);
    }
};
pub const Beacon = union(enum(u8)) { loose: [3]f32, carried: u8 };
pub const Objectives = union(enum(u8)) { none, six_beacons: [beacon_count]Beacon };
pub const Facing = [3]i16;
const math = engine.surrender.math;

pub fn packFacing(orientation: math.Matrix) Facing {
    const radians = math.angles(orientation);
    var packed_angles: Facing = undefined;
    inline for (&packed_angles, 0..) |*angle, i| angle.* = @intFromFloat(@round(radians[i] * (32767.0 / std.math.pi)));
    return packed_angles;
}

pub fn unpackFacing(packed_angles: Facing) math.Matrix {
    var angles: math.Vector = undefined;
    inline for (packed_angles, 0..) |angle, i| angles[i] = @as(f32, @floatFromInt(angle)) * (std.math.pi / 32767.0);
    return math.fromAngleVector(angles);
}

pub const Rocks = struct {
    /// Mission 85 has thirty rocks. The room for extra entries keeps the packet bounded.
    pub const max = 32;
    count: u8 = 0,
    angles: [max]?Facing = @splat(null),
};

pub const Snapshot = struct {
    tick: u32,
    scenario: ?Scenario = null,
    ships: [slots]?Ship,
    objectives: Objectives = .none,
    rocks: Rocks = .{},
    weapons: ?ordnance.Status = null,
    pickups: powerups.Pickups.Mask = 0,
    mines: [powerups.mine_count]?Mine = @splat(null),
    power: ?Power = null,
    blast: ?Blast = null,
};

pub const Blast = struct {
    owner: u8,
    started: i32,
    size: f32,
    position: [3]f32,
    angles: Facing,

    // The pilot slot also acts as the presence flag.
    const encoded_size = 1 + @sizeOf(i32) + 4 * @sizeOf(f32) + @sizeOf(Facing);

    fn write(value: ?Blast, w: *std.Io.Writer) !void {
        const blast = value orelse return w.writeByte(slots);
        try w.writeByte(blast.owner);
        try w.writeInt(i32, blast.started, .little);
        try writeFloat(w, blast.size);
        try writePosition(w, blast.position);
        for (blast.angles) |angle| try w.writeInt(i16, angle, .little);
    }

    fn read(r: *std.Io.Reader, tick: u32) !?Blast {
        const owner = try r.takeByte();
        if (owner == slots) return null;
        if (owner > slots) return error.InvalidSnapshot;
        const started = try r.takeInt(i32, .little);
        const size = try readFloat(r);
        const now: i32 = @intCast(@min(tick *| engine.game.gameobj.ticks_per_step, std.math.maxInt(i32)));
        const duration = engine.game.deathmatch.six_beacons.blast_ticks;
        if (started < 0 or started > now or now - started > duration + engine.game.gameobj.ticks_per_step or
            size <= 0 or !std.math.isFinite(size * size)) return error.InvalidSnapshot;
        return .{
            .owner = owner,
            .started = started,
            .size = size,
            .position = try readPosition(r),
            .angles = .{ try r.takeInt(i16, .little), try r.takeInt(i16, .little), try r.takeInt(i16, .little) },
        };
    }
};

pub const Power = struct {
    kind: engine.game.gameobj.PowerUp,
    since: i32,

    pub fn capture(object: *const engine.game.gameobj.GameObject) ?Power {
        _ = powerups.rule(object.power_up) orelse return null;
        return .{ .kind = object.power_up, .since = object.power_up_since };
    }
};

pub const Mine = struct {
    position: [3]f32,
    angles: Facing,
    reuse: u32,

    const encoded_size = 3 * @sizeOf(f32) + @sizeOf(Facing) + @sizeOf(u32);
};

fn writeArena(w: *std.Io.Writer, view: *const Snapshot) !void {
    try w.writeInt(powerups.Pickups.Mask, view.pickups, .little);
    var mask: u32 = 0;
    for (view.mines, 0..) |entry, at| {
        if (entry != null) mask |= @as(u32, 1) << @as(u5, @intCast(at));
    }
    try w.writeInt(u32, mask, .little);
    for (view.mines) |entry| if (entry) |mine| {
        try writePosition(w, mine.position);
        for (mine.angles) |axis| try w.writeInt(i16, axis, .little);
        try w.writeInt(u32, mine.reuse, .little);
    };
    if (view.power) |held| {
        _ = powerups.rule(held.kind) orelse return error.InvalidPowerUp;
        try w.writeByte(@intCast(@backingInt(held.kind) + 1));
        try w.writeInt(i32, held.since, .little);
    } else try w.writeByte(0);
}

fn readArena(r: *std.Io.Reader, view: *Snapshot) !void {
    view.pickups = try r.takeInt(powerups.Pickups.Mask, .little);
    const mask = try r.takeInt(u32, .little);
    if (mask >> powerups.mine_count != 0) return error.InvalidArenaMines;
    for (&view.mines, 0..) |*entry, at| {
        if (mask & (@as(u32, 1) << @as(u5, @intCast(at))) == 0) continue;
        entry.* = .{
            .position = try readPosition(r),
            .angles = .{ try r.takeInt(i16, .little), try r.takeInt(i16, .little), try r.takeInt(i16, .little) },
            .reuse = try r.takeInt(u32, .little),
        };
    }
    const id = try r.takeByte();
    if (id == 0) return;
    const kind: engine.game.gameobj.PowerUp = @fromBackingInt(id - 1);
    _ = powerups.rule(kind) orelse return error.InvalidPowerUp;
    const since = try r.takeInt(i32, .little);
    if (since < 0 or since > view.tick *| engine.game.gameobj.ticks_per_step) return error.InvalidPowerUp;
    view.power = .{ .kind = kind, .since = since };
}

fn writeScenario(w: *std.Io.Writer, scenario: ?Scenario) !void {
    try w.writeByte(if (scenario) |value| @backingInt(value) + 1 else 0);
}

fn readScenario(r: *std.Io.Reader) !?Scenario {
    const code = try r.takeByte();
    if (code == 0) return null;
    const scenario = std.enums.fromInt(Scenario, code - 1) orelse return error.InvalidScenario;
    if (!scenario.available()) return error.InvalidScenario;
    return scenario;
}

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
            .wall => |wall| {
                try writePosition(w, wall.at);
                try writePosition(w, wall.inward);
                try w.writeInt(i32, wall.started, .little);
                try w.writeByte(@intFromBool(wall.flare));
                if (wall.shot) |shot| {
                    try w.writeByte(shot.index);
                    try w.writeInt(i32, shot.fired_at, .little);
                } else try w.writeByte(guns.max_bullets);
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
            .wall => wall: {
                const at = try readPosition(r);
                const inward = try readPosition(r);
                const length = math.lengthSquared(inward);
                if (length < 0.99 or length > 1.01) return error.InvalidCombat;
                const started = try r.takeInt(i32, .little);
                if (started < 0) return error.InvalidCombat;
                const flare = switch (try r.takeByte()) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidCombat,
                };
                const index = try r.takeByte();
                if (index > guns.max_bullets) return error.InvalidCombat;
                const shot: ?engine.game.deathmatch.Boundary.Impact.Shot = if (index == guns.max_bullets) null else .{
                    .index = index,
                    .fired_at = try r.takeInt(i32, .little),
                };
                if (shot) |value| if (value.fired_at < 0) return error.InvalidCombat;
                break :wall .{ .wall = .{ .at = at, .inward = inward, .started = started, .flare = flare, .shot = shot } };
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
    roster: Roster,
    call_sign: CallSign,
    pick_ship: Fighter,
    beacon_notice: BeaconNotice,
    combat: Combat,
    weapon_order: ordnance.Order,
    projectiles: ordnance.Page,
    pilot_notice: PilotNotice,
    wreck: Wreck,
    chat_request: ChatRequest,
    chat_line: ChatLine,

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
                if (input.fire_for) |reuse| try w.writeInt(u32, reuse, .little);
            },
            .view, .finished => |view| {
                try w.writeInt(u32, view.tick, .little);
                try writeScenario(&w, view.scenario);
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
                    if (view.scenario != null) {
                        try w.writeInt(u16, ship.respawn, .little);
                        const wall: u8 = @intFromBool(ship.at_wall);
                        const dying: u8 = @intFromBool(ship.dying);
                        try w.writeByte(wall | (dying << 1));
                        try w.writeInt(u16, ship.ping_ms orelse Ship.unknown_ping, .little);
                    }
                    if (view.scenario == .asteroid_field) try w.writeByte(@intFromBool(ship.cloaked));
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
                if (view.scenario == .asteroid_field) {
                    if (view.rocks.count > Rocks.max) return error.InvalidSnapshot;
                    try w.writeByte(view.rocks.count);
                    for (view.rocks.angles[0..view.rocks.count]) |entry| {
                        try w.writeByte(@intFromBool(entry != null));
                        if (entry) |facing| for (facing) |axis| try w.writeInt(i16, axis, .little);
                    }
                    try writeArena(&w, &view);
                }
                if (view.scenario == .nuclear_threat) try Blast.write(view.blast, &w);
                try w.writeByte(@intFromBool(view.weapons != null));
                if (view.weapons) |*status| try status.write(&w);
            },
            .leave => {},
            .received_final => |tick| try w.writeInt(u32, tick, .little),
            .flight_press => |presses| try w.writeByte(@bitCast(presses)),
            .roster => |roster| {
                try writeScenario(&w, roster.lobby);
                try w.writeByte(@intFromBool(roster.paused));
                for (roster.pilots) |entry| {
                    try w.writeInt(u64, if (entry) |pilot| pilot.generation else 0, .little);
                    if (entry) |pilot| try writeCallSign(&w, &pilot.name);
                }
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
            .weapon_order => |order| try ordnance.writeOrder(&w, order),
            .projectiles => |page| try page.write(&w),
            .pilot_notice => |notice| {
                try w.writeByte(notice.pilot.slot);
                try w.writeInt(u64, notice.pilot.generation, .little);
                try w.writeInt(i32, notice.tick, .little);
                try w.writeByte(@backingInt(notice.kind));
                try writeCallSign(&w, &notice.name);
            },
            .chat_request => |request| {
                try w.writeByte(@backingInt(std.meta.activeTag(request.to)));
                if (request.to == .private) {
                    try w.writeByte(request.to.private.slot);
                    try w.writeInt(u64, request.to.private.generation, .little);
                }
                try writeChat(&w, &request.text);
            },
            .chat_line => |line| {
                try w.writeByte(@backingInt(line.scope));
                try w.writeByte(line.sender);
                try writeCallSign(&w, &line.name);
                try writeChat(&w, &line.text);
            },
            .wreck => |wreck| {
                try w.writeByte(@intCast(wreck.pilot.participant.slot));
                try w.writeInt(u64, wreck.pilot.participant.generation, .little);
                try w.writeInt(u32, wreck.pilot.ship.reuse, .little);
                try w.writeByte(@backingInt(wreck.fighter));
                try w.writeInt(i32, wreck.tick, .little);
                try writePosition(&w, wreck.motion.place.position);
                for (packFacing(wreck.motion.place.orientation)) |angle| try w.writeInt(i16, angle, .little);
                try writePosition(&w, wreck.motion.velocity);
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
                .command = try flight_input.read(&r),
                .fire_for = if (r.bufferedLen() == 0) null else try r.takeInt(u32, .little),
            } },
            .view, .finished => snapshot: {
                var view: Snapshot = .{ .tick = try r.takeInt(u32, .little), .scenario = try readScenario(&r), .ships = @splat(null) };
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
                    if (view.scenario != null) {
                        ship.respawn = try r.takeInt(u16, .little);
                        if (ship.respawn > engine.game.deathmatch.respawn.duration) return error.InvalidSnapshot;
                        const flags = try r.takeByte();
                        if (flags > 0b11) return error.InvalidSnapshot;
                        ship.at_wall = flags & 1 != 0;
                        ship.dying = flags & 2 != 0;
                        const ping = try r.takeInt(u16, .little);
                        ship.ping_ms = if (ping == Ship.unknown_ping) null else ping;
                    }
                    if (view.scenario == .asteroid_field) ship.cloaked = switch (try r.takeByte()) {
                        0 => false,
                        1 => true,
                        else => return error.InvalidSnapshot,
                    };
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
                if (view.scenario == .asteroid_field) {
                    view.rocks.count = try r.takeByte();
                    if (view.rocks.count > Rocks.max) return error.InvalidSnapshot;
                    for (view.rocks.angles[0..view.rocks.count]) |*entry| {
                        entry.* = switch (try r.takeByte()) {
                            0 => null,
                            1 => .{ try r.takeInt(i16, .little), try r.takeInt(i16, .little), try r.takeInt(i16, .little) },
                            else => return error.InvalidSnapshot,
                        };
                    }
                    try readArena(&r, &view);
                }
                if (view.scenario == .nuclear_threat) view.blast = try Blast.read(&r, view.tick);
                view.weapons = switch (try r.takeByte()) {
                    0 => null,
                    1 => try ordnance.Status.read(&r),
                    else => return error.InvalidSnapshot,
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
            .roster => roster: {
                var view: Roster = .{ .lobby = try readScenario(&r) };
                view.paused = switch (try r.takeByte()) {
                    0 => false,
                    1 => true,
                    else => return error.InvalidRoster,
                };
                if (view.paused and view.lobby != null) return error.InvalidRoster;
                for (&view.pilots) |*entry| {
                    const generation = try r.takeInt(u64, .little);
                    if (generation != 0) entry.* = .{ .generation = generation, .name = try readCallSign(&r) };
                }
                if (view.paused and view.pilots[0] == null) return error.InvalidRoster;
                break :roster .{ .roster = view };
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
            .weapon_order => .{ .weapon_order = try ordnance.readOrder(&r, slots) },
            .projectiles => .{ .projectiles = try ordnance.Page.read(&r) },
            .pilot_notice => notice: {
                const slot = try r.takeByte();
                const generation = try r.takeInt(u64, .little);
                const tick = try r.takeInt(i32, .little);
                if (slot >= slots or generation == 0 or tick < 0) return error.InvalidPilotNotice;
                break :notice .{ .pilot_notice = .{
                    .pilot = .{ .slot = slot, .generation = generation },
                    .tick = tick,
                    .kind = try r.takeEnum(PilotNotice.Kind, .little),
                    .name = try readCallSign(&r),
                } };
            },
            .chat_request => request: {
                const scope = try r.takeEnum(ChatScope, .little);
                const to: @FieldType(ChatRequest, "to") = switch (scope) {
                    .lobby => .lobby,
                    .flight => .flight,
                    .private => private: {
                        const slot = try r.takeByte();
                        const generation = try r.takeInt(u64, .little);
                        if (slot >= slots or generation == 0) return error.InvalidChat;
                        break :private .{ .private = .{ .slot = slot, .generation = generation } };
                    },
                };
                break :request .{ .chat_request = .{ .to = to, .text = try readChat(&r) } };
            },
            .chat_line => line: {
                const scope = try r.takeEnum(ChatScope, .little);
                const sender = try r.takeByte();
                if (sender >= slots) return error.InvalidChat;
                break :line .{ .chat_line = .{
                    .scope = scope,
                    .sender = sender,
                    .name = try readCallSign(&r),
                    .text = try readChat(&r),
                } };
            },
            .wreck => wreck: {
                const slot = try r.takeByte();
                const generation = try r.takeInt(u64, .little);
                const reuse = try r.takeInt(u32, .little);
                const fighter = try r.takeEnum(Fighter, .little);
                const tick = try r.takeInt(i32, .little);
                const position = try readPosition(&r);
                const orientation = unpackFacing(.{ try r.takeInt(i16, .little), try r.takeInt(i16, .little), try r.takeInt(i16, .little) });
                const velocity = try readPosition(&r);
                if (slot >= slots or generation == 0 or tick < 0 or !std.math.isFinite(math.lengthSquared(position)) or
                    !std.math.isFinite(math.lengthSquared(velocity))) return error.InvalidWreck;
                break :wreck .{ .wreck = .{
                    .pilot = .{ .participant = .{ .slot = slot, .generation = generation }, .ship = .{ .slot = slot, .reuse = reuse } },
                    .fighter = fighter,
                    .tick = tick,
                    .motion = .{ .place = .{ .position = position, .orientation = orientation }, .velocity = velocity },
                } };
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

test "a fighter breakup retains the destroyed ship even after a slot is reused" {
    var buffer: [capacity]u8 = undefined;
    const expected: Wreck = .{
        .pilot = .{ .participant = .{ .slot = 1, .generation = 9 }, .ship = .{ .slot = 1, .reuse = 27 } },
        .fighter = .shroud,
        .tick = 320,
        .motion = .{ .place = .{ .position = .{ 10, 20, 30 } }, .velocity = .{ 0, 0, 45 } },
    };
    const message: Message = .{ .wreck = expected };
    const bytes = try message.encode(&buffer);
    const decoded = (try Message.decode(bytes)).wreck;
    try std.testing.expectEqualDeep(expected, decoded);
    buffer[1] = slots;
    try std.testing.expectError(error.InvalidWreck, Message.decode(bytes));
}

test "pilot notices retain the callsign of the admission that left" {
    var buffer: [capacity]u8 = undefined;
    const notice: PilotNotice = .{ .pilot = .{ .slot = 2, .generation = 17 }, .tick = 125, .kind = .left_flight, .name = lobbyName("Raven") };
    const decoded = (try Message.decode(try (Message{ .pilot_notice = notice }).encode(&buffer))).pilot_notice;
    try std.testing.expectEqual(notice.pilot, decoded.pilot);
    try std.testing.expectEqual(notice.kind, decoded.kind);
    try std.testing.expectEqual(notice.tick, decoded.tick);
    try std.testing.expectEqualStrings(notice.name.slice(), decoded.name.slice());
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
    var effects: Combat = .{ .count = 4 };
    effects.entries[0..4].* = .{
        .{ .shot = .{ .index = 4, .owner = 0, .kind = .pulse_cannon, .fired_at = 84, .dies_at = 124, .origin = .{ 1, 2, 3 }, .velocity = .{ 0, 0, 1 } } },
        .{ .impact = .{ .shot = 4, .fired_at = 84, .target = .{ .slot = 2, .reuse = 7 }, .at = .{ 1, 2, 20 }, .kind = .shield } },
        .{ .nova = .{ .owner = .{ .slot = 2, .reuse = 7 }, .charge = 0.75, .fired_at = 85 } },
        .{ .wall = .{ .at = .{ 100, 200, 300 }, .inward = .{ 1, 0, 0 }, .started = 86, .flare = true, .shot = .{ .index = 8, .fired_at = 82 } } },
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
    const message: Message = .{ .roster = .{ .lobby = .asteroid_field, .pilots = .{
        .{ .generation = 1, .name = host_name }, null, .{ .generation = 4, .name = guest_name },
    } } };
    var buffer: [capacity]u8 = undefined;
    const decoded = (try Message.decode(try message.encode(&buffer))).roster;
    try std.testing.expectEqual(.asteroid_field, decoded.lobby);
    try std.testing.expectEqualStrings("Falcon", decoded.pilots[0].?.name.slice());
    try std.testing.expectEqual(null, decoded.pilots[1]);
    try std.testing.expectEqual(4, decoded.pilots[2].?.generation);
    try std.testing.expectEqualStrings("\xc9toile", decoded.pilots[2].?.name.slice());
    const call_sign = @backingInt(std.meta.Tag(Message).call_sign);
    try std.testing.expectError(error.InvalidCallSign, Message.decode(&.{ call_sign, 32 }));
    try std.testing.expectError(error.InvalidCallSign, Message.decode(&.{ call_sign, 1, '\n' }));
    try std.testing.expectError(error.InvalidScenario, Message.decode(&.{ @backingInt(std.meta.Tag(Message).roster), 255 }));
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
    const full_snapshot_bytes = 257;
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
        .scenario = .nuclear_threat,
        .ships = @splat(.{ .generation = 2, .position = @splat(0), .respawn = 289, .ping_ms = 72 }),
        .objectives = .{ .six_beacons = @splat(.{ .loose = .{ 2, 3, 4 } }) },
        .blast = .{ .owner = 1, .started = 10, .size = 2200, .position = .{ 8, 9, 10 }, .angles = .{ 4, -5, 6 } },
    } };
    const full = try view.encode(&buffer);
    try std.testing.expectEqual(beacon_snapshot_capacity, full.len);
    try std.testing.expectEqualDeep(view, try Message.decode(full));
    view.view.objectives.six_beacons[0] = .{ .carried = 1 };
    try std.testing.expectEqualDeep(view, try Message.decode(try view.encode(&buffer)));
    view.view.ships[1] = null;
    try std.testing.expectError(error.InvalidBeaconCarrier, Message.decode(try view.encode(&buffer)));
}

test "ship angles round-trip the host orientation" {
    const facing = math.fromAngles(0.42, -0.91, 2.1);
    var ship: Ship = .{ .generation = 1, .position = @splat(0) };
    ship.face(facing);
    for (facing, ship.orientationMatrix()) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.0002);
    }
}

test "asteroid views include the stock mode and keep absent rock slots" {
    var buffer: [capacity]u8 = undefined;
    var view: Snapshot = .{ .tick = 7, .scenario = .asteroid_field, .ships = @splat(null) };
    view.rocks.count = Rocks.max;
    view.rocks.angles = @splat(.{ 123, 456, -789 });
    view.rocks.angles[1] = null;
    view.pickups = 0b1011;
    view.mines[powerups.mine_count - 1] = .{ .position = .{ 100, 200, -300 }, .angles = .{ 10, -15, 20 }, .reuse = 19 };
    view.power = .{ .kind = .missile, .since = 1 };
    const bytes = try (Message{ .view = view }).encode(&buffer);
    try std.testing.expectEqualDeep(view, (try Message.decode(bytes)).view);
    try std.testing.expectError(error.EndOfStream, Message.decode(bytes[0 .. bytes.len - 1]));
}

test "ordnance orders address both ship lifetimes and keep a valid single press" {
    var buffer: [capacity]u8 = undefined;
    const order: Message = .{ .weapon_order = .{
        .aim = .{ .reuse = 17, .target = .{ .slot = 1, .reuse = 23 } },
        .presses = .from(.{ .launch_missile = true, .rotate_missiles = .anticlockwise }),
    } };
    const bytes = try order.encode(&buffer);
    try std.testing.expectEqualDeep(order, try Message.decode(bytes));
    try std.testing.expectError(error.EndOfStream, Message.decode(bytes[0 .. bytes.len - 1]));
    buffer[1 + @sizeOf(u32)] = 0xff;
    try std.testing.expectError(error.InvalidWeaponOrder, Message.decode(bytes));
}

test "a view can carry private missile and countermeasure status" {
    var buffer: [capacity]u8 = undefined;
    var view: Snapshot = .{ .tick = 1, .scenario = .asteroid_field, .ships = @splat(null) };
    view.weapons = .{ .countermeasures = 3, .incoming = true, .armed = 1 };
    view.weapons.?.ammo[0] = .{ .kind = .screamer, .count = 0 };
    view.weapons.?.ammo[1] = .{ .kind = .raptor, .count = 2 };
    view.weapons.?.held = .{ .phase = .locked, .count = 0, .ticks = 12, .point = .{ 3, 8, 21 } };
    const transmitted = try (Message{ .view = view }).encode(&buffer);
    const status = (try Message.decode(transmitted)).view.weapons.?;
    try std.testing.expectEqualDeep(view.weapons.?, status);
    var ring = status.ring();
    try std.testing.expectEqual(engine.game.missiles.Type.of(.raptor), ring.armedEntry().type);
    try std.testing.expectEqual(0, ring.entries[0].count);
    try std.testing.expectEqual(2, ring.left);
}

test "projectile pages preserve slot reuse and reject entries past the end of the pool" {
    var buffer: [capacity]u8 = undefined;
    const Page = ordnance.Page;
    var page: Page = .{ .tick = 8, .family = .missile, .number = Page.missiles_pages - 1 };
    page.entries[0] = .{ .reuse = 22, .kind = .raptor, .position = .{ 10, 20, 30 }, .angles = .{ 0, 12, 3 }, .flight = .{ .burn = 32, .launched = true } };
    try std.testing.expectEqualDeep(page, (try Message.decode(try (Message{ .projectiles = page }).encode(&buffer))).projectiles);
    page.entries[Page.width - 1] = page.entries[0];
    try std.testing.expectError(error.InvalidProjectilePage, Message.decode(try (Message{ .projectiles = page }).encode(&buffer)));
}

test "chat requests carry a destination and bounded text without a sender field" {
    var buffer: [capacity]u8 = undefined;
    var words: chat.Line = .{};
    words.set("  caf\xe9 ");
    const request: Message = .{ .chat_request = .{ .to = .{ .private = .{ .slot = 2, .generation = 51 } }, .text = words } };
    const encoded = try request.encode(&buffer);
    const decoded = (try Message.decode(encoded)).chat_request;
    try std.testing.expectEqual(request.chat_request.to.private, decoded.to.private);
    try std.testing.expectEqualStrings("caf\xe9", decoded.text.slice());
    try std.testing.expectError(error.TrailingData, Message.decode(buffer[0 .. encoded.len + 1]));
    buffer[2] = slots;
    try std.testing.expectError(error.InvalidChat, Message.decode(encoded));

    const tag = @backingInt(std.meta.Tag(Message).chat_request);
    const lobby = @backingInt(ChatScope.lobby);
    try std.testing.expectError(error.InvalidChat, Message.decode(&.{ tag, lobby, 0 }));
    try std.testing.expectError(error.InvalidChat, Message.decode(&.{ tag, lobby, chat.capacity + 1 }));
    try std.testing.expectError(error.InvalidChat, Message.decode(&.{ tag, lobby, 2, ' ', 0xa0 }));
    for ([_]u8{ 0, '\r', '\n', 0x7f, 0x81, 0xad }) |control|
        try std.testing.expectError(error.InvalidChat, Message.decode(&.{ tag, lobby, 2, 'a', control }));

    const line: Message = .{ .chat_line = .{ .scope = .flight, .sender = 1, .name = lobbyName("Viper"), .text = decoded.text } };
    const delivered = (try Message.decode(try line.encode(&buffer))).chat_line;
    try std.testing.expectEqual(.flight, delivered.scope);
    try std.testing.expectEqual(1, delivered.sender);
    try std.testing.expectEqualStrings("Viper", delivered.name.slice());
    try std.testing.expectEqualStrings("caf\xe9", delivered.text.slice());
}

test "a paused roster names the host and cannot describe a waiting lobby" {
    var buffer: [capacity]u8 = undefined;
    var roster: Message = .{ .roster = .{ .paused = true } };
    roster.roster.pilots[0] = .{ .generation = 19, .name = lobbyName("Falcon") };
    const encoded = try roster.encode(&buffer);
    const decoded = (try Message.decode(encoded)).roster;
    try std.testing.expect(decoded.paused);
    try std.testing.expectEqual(19, decoded.pilots[0].?.generation);
    roster.roster.lobby = .asteroid_field;
    try std.testing.expectError(error.InvalidRoster, Message.decode(try roster.encode(&buffer)));
    roster.roster.lobby = null;
    roster.roster.pilots[0] = null;
    try std.testing.expectError(error.InvalidRoster, Message.decode(try roster.encode(&buffer)));
}
