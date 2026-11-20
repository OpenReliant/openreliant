//! Pilot weapon input and the host's private weapon display state.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const display = game.hud.missile_display;
const missile = game.missiles;
const lock = game.main.lock;
const Vector = engine.surrender.math.Vector;

pub const Order = struct {
    aim: Aim,
    presses: Presses = .{},
    cockpit: game.players.CockpitCommand = .{},

    pub fn merge(pending: *Order, next: Order) void {
        if (pending.aim.reuse != next.aim.reuse) {
            pending.* = next;
            return;
        }
        // A launch belongs to the target selected when the pilot pressed fire.
        if (!std.meta.eql(pending.aim, next.aim)) pending.presses.launch = false;
        pending.aim = next.aim;
        pending.presses.merge(next.presses);
        pending.cockpit.merge(next.cockpit);
    }
};

test "a target change drops the old launch but preserves the pilot's countermeasure press" {
    var pending: Order = .{
        .aim = .{ .reuse = 2, .target = .{ .slot = 1, .reuse = 3 } },
        .presses = .{ .launch = true, .countermeasures = true },
    };
    pending.merge(.{ .aim = .{ .reuse = 2 } });
    try std.testing.expect(!pending.presses.launch);
    try std.testing.expect(pending.presses.countermeasures);
    pending.merge(.{ .aim = .{ .reuse = 4 } });
    try std.testing.expect(!pending.presses.any());
}

pub const Aim = struct {
    reuse: u32,
    target: ?game.gameobj.ObjectRef = null,
    component: ?u15 = null,
    script_aim: u32 = 0,
};

const Rotation = enum(u2) { none, clockwise, anticlockwise };

pub const Presses = packed struct(u8) {
    launch: bool = false,
    countermeasures: bool = false,
    rotation: u2 = 0,
    match_speed: bool = false,
    reserved: u3 = 0,

    pub fn from(command: game.players.WeaponCommand) Presses {
        return .{
            .launch = command.launch_missile,
            .countermeasures = command.countermeasures,
            .rotation = @backingInt(if (command.rotate_missiles) |way| switch (way) {
                .clockwise => Rotation.clockwise,
                .anticlockwise => Rotation.anticlockwise,
            } else Rotation.none),
        };
    }

    pub fn turn(presses: Presses) ?display.Turn {
        return switch (std.enums.fromInt(Rotation, presses.rotation) orelse .none) {
            .none => null,
            .clockwise => .clockwise,
            .anticlockwise => .anticlockwise,
        };
    }

    pub fn any(presses: Presses) bool {
        return @as(u8, @bitCast(presses)) != 0;
    }

    fn merge(pending: *Presses, next: Presses) void {
        pending.launch = pending.launch or next.launch;
        pending.countermeasures = pending.countermeasures or next.countermeasures;
        pending.match_speed = pending.match_speed or next.match_speed;
        if (next.rotation != 0) pending.rotation = next.rotation;
    }
};

const CockpitBits = packed struct(u8) {
    next_guns: bool,
    full_guns: bool,
    sync_guns: bool,
    preset: u3,
    reserved: u2 = 0,
};

pub fn writeOrder(w: *std.Io.Writer, order: Order) !void {
    try w.writeInt(u32, order.aim.reuse, .little);
    try w.writeInt(u32, order.aim.script_aim, .little);
    try w.writeByte(@bitCast(order.presses));
    const cockpit: CockpitBits = .{
        .next_guns = order.cockpit.next_guns,
        .full_guns = order.cockpit.full_guns,
        .sync_guns = order.cockpit.sync_guns,
        .preset = if (order.cockpit.power) |preset| @as(u3, @backingInt(preset)) + 1 else 0,
    };
    try w.writeByte(@bitCast(cockpit));
    if (order.aim.target) |target| {
        try w.writeInt(u16, target.slot, .little);
        try w.writeInt(u32, target.reuse, .little);
        try w.writeInt(i16, if (order.aim.component) |part| @intCast(part) else -1, .little);
    }
}

pub fn readOrder(r: *std.Io.Reader, pilot_slots: usize) !Order {
    var order: Order = .{
        .aim = .{ .reuse = try r.takeInt(u32, .little), .script_aim = try r.takeInt(u32, .little) },
        .presses = @bitCast(try r.takeByte()),
    };
    if (order.presses.reserved != 0 or std.enums.fromInt(Rotation, order.presses.rotation) == null) return error.InvalidWeaponOrder;
    const cockpit: CockpitBits = @bitCast(try r.takeByte());
    if (cockpit.reserved != 0) return error.InvalidWeaponOrder;
    order.cockpit = .{
        .next_guns = cockpit.next_guns,
        .full_guns = cockpit.full_guns,
        .sync_guns = cockpit.sync_guns,
        .power = if (cockpit.preset != 0)
            std.enums.fromInt(engine.input.power.Preset, cockpit.preset - 1) orelse return error.InvalidWeaponOrder
        else
            null,
    };
    if (r.bufferedLen() == 0) return order;
    const slot = try r.takeInt(u16, .little);
    if (slot >= pilot_slots) return error.InvalidWeaponOrder;
    order.aim.target = .{ .slot = slot, .reuse = try r.takeInt(u32, .little) };
    const component = try r.takeInt(i16, .little);
    if (component < -1) return error.InvalidWeaponOrder;
    if (component >= 0) order.aim.component = @intCast(component);
    return order;
}

/// The private, host-owned readings for GUNNERY, DAMAGE and POWER.
pub const Panels = struct {
    power: [2]f32 = @splat(0),
    conditions: [3]f32 = @splat(1),
    guns: game.gameobj.GunMode = .created(1),
    rounds: i32 = 0,

    const size = 5 * @sizeOf(f32) + @sizeOf(u16) + @sizeOf(i32);

    fn capture(object: *const game.gameobj.GameObject) Panels {
        return .{
            .power = engine.input.power.point(object),
            .conditions = .{ object.gun_condition, object.armor_speed_factor, object.shield_condition },
            .guns = object.gun_mode,
            .rounds = object.rounds,
        };
    }

    pub fn apply(panel: Panels, object: *game.gameobj.GameObject) void {
        object.power_setting.x = panel.power[0];
        object.power_setting.y = panel.power[1];
        object.gun_condition = panel.conditions[0];
        object.armor_speed_factor = panel.conditions[1];
        object.shield_condition = panel.conditions[2];
        object.gun_mode = panel.guns;
        object.rounds = panel.rounds;
    }

    fn write(panel: Panels, w: *std.Io.Writer) !void {
        for (panel.power ++ panel.conditions) |value| try w.writeInt(u32, @bitCast(value), .little);
        try w.writeInt(u16, @bitCast(panel.guns), .little);
        try w.writeInt(i32, panel.rounds, .little);
    }

    fn read(r: *std.Io.Reader) !Panels {
        var values: [5]f32 = undefined;
        for (&values) |*value| {
            value.* = @bitCast(try r.takeInt(u32, .little));
            if (!std.math.isFinite(value.*)) return error.InvalidWeaponStatus;
        }
        const maximum_power = engine.input.power.radius + 0.01;
        if (values[0] * values[0] + values[1] * values[1] > maximum_power * maximum_power) return error.InvalidWeaponStatus;
        return .{
            .power = values[0..2].*,
            .conditions = values[2..5].*,
            .guns = @bitCast(try r.takeInt(u16, .little)),
            .rounds = try r.takeInt(i32, .little),
        };
    }
};

pub const Status = struct {
    countermeasures: u16,
    incoming: bool,
    armed: u8,
    ammo: [display.max_entries]?Ammo = @splat(null),
    held: lock.Lock = .{},
    panels: Panels = .{},

    const Ammo = struct { kind: missile.GameMissile, count: i16 };
    const Flags = packed struct(u8) { incoming: bool, locking: bool, reserved: u6 = 0 };
    pub const capacity = @sizeOf(u16) + 4 + display.max_entries * (2 * @sizeOf(i16)) + 2 + 2 * @sizeOf(i32) + 3 * @sizeOf(f32) + Panels.size;

    pub fn capture(all: *const game.create.Objects, slot: u16) Status {
        const weapons = &all.player_states[slot].weapons;
        const object = &all.slots[slot].object;
        const incoming = object.missile_homing != 0;
        var status: Status = .{
            .countermeasures = object.countermeasures,
            .incoming = incoming,
            .armed = if (weapons.ring.entries[0].left() == null) 0 else @intCast(weapons.ring.armed),
            .panels = .capture(object),
            .held = if (weapons.lock.phase == .idle) .{} else .{
                .phase = weapons.lock.phase,
                .point = weapons.lock.point,
                .count = weapons.lock.count,
                .ticks = weapons.lock.ticks,
                .turn = weapons.lock.turn,
            },
        };
        for (weapons.ring.entries, &status.ammo) |entry, *ammo| {
            const count = entry.left() orelse break;
            ammo.* = .{ .kind = entry.type.base(), .count = @max(count, 0) };
        }
        return status;
    }

    pub fn ring(status: Status) display.Ring {
        var shown: display.Ring = .{ .armed = status.armed };
        for (status.ammo, &shown.entries, 0..) |entry, *slot, index| {
            const ammo = entry orelse break;
            const place = @mod(@as(i16, status.armed) - @as(i16, @intCast(index)), display.max_entries);
            slot.* = .of(.of(ammo.kind), ammo.count, place);
            shown.left += ammo.count;
        }
        return shown;
    }

    pub fn write(status: *const Status, w: *std.Io.Writer) !void {
        try w.writeInt(u16, status.countermeasures, .little);
        const flags: Flags = .{ .incoming = status.incoming, .locking = status.held.phase != .idle };
        try w.writeByte(@bitCast(flags));
        try w.writeByte(status.armed);
        for (status.ammo) |entry| {
            const ammo = entry orelse break;
            try w.writeInt(i16, @backingInt(ammo.kind), .little);
            try w.writeInt(i16, ammo.count, .little);
        }
        try w.writeInt(i16, @backingInt(missile.GameMissile.none), .little);
        if (flags.locking) {
            try w.writeByte(@intCast(@backingInt(status.held.phase)));
            try w.writeByte(@intCast(std.math.clamp(status.held.count, 0, lock.idle_count)));
            try w.writeInt(i32, status.held.ticks, .little);
            try w.writeInt(i32, status.held.turn, .little);
            inline for (0..3) |axis| try w.writeInt(u32, @bitCast(status.held.point[axis]), .little);
        }
        try status.panels.write(w);
    }

    pub fn read(r: *std.Io.Reader) !Status {
        var status: Status = .{ .countermeasures = try r.takeInt(u16, .little), .incoming = false, .armed = 0 };
        const flags: Flags = @bitCast(try r.takeByte());
        if (flags.reserved != 0) return error.InvalidWeaponStatus;
        status.incoming = flags.incoming;
        status.armed = try r.takeByte();
        var count: usize = 0;
        while (true) {
            const kind = try r.takeEnum(missile.GameMissile, .little);
            if (kind == .none) break;
            const left = try r.takeInt(i16, .little);
            if (count == status.ammo.len or left < 0 or kind == .fuel_pod or kind == .torpedo) return error.InvalidWeaponStatus;
            status.ammo[count] = .{ .kind = kind, .count = left };
            count += 1;
        }
        if (status.armed >= @max(count, 1)) return error.InvalidWeaponStatus;
        if (flags.locking) {
            status.held.phase = std.enums.fromInt(lock.Phase, try r.takeByte()) orelse return error.InvalidWeaponStatus;
            status.held.count = try r.takeByte();
            status.held.ticks = try r.takeInt(i32, .little);
            status.held.turn = try r.takeInt(i32, .little);
            if (status.held.phase == .idle or status.held.count > lock.idle_count or status.held.turn < 0) return error.InvalidWeaponStatus;
            inline for (0..3) |axis| {
                status.held.point[axis] = @bitCast(try r.takeInt(u32, .little));
                if (!std.math.isFinite(status.held.point[axis])) return error.InvalidWeaponStatus;
            }
        }
        status.panels = try .read(r);
        return status;
    }
};

/// Separate pose pages keep a busy arena's projectiles out of the pilot snapshots.
/// Each page covers a fixed range of the host's records, including empty records.
pub const Page = struct {
    pub const width = @bitSizeOf(u16);
    pub const capacity = 1 + @sizeOf(u32) + 2 + @sizeOf(u16) + width * (6 + 3 * @sizeOf(f32) + 3 * @sizeOf(i16) + 1);
    pub const max_age = 6;
    pub const missiles_pages = std.math.divCeil(usize, game.missiles.max_missiles, width) catch unreachable;
    pub const decoy_pages = std.math.divCeil(usize, game.cloak.max_countermeasures, width) catch unreachable;
    pub const pages = missiles_pages + decoy_pages;

    tick: u32,
    family: Family,
    number: u8,
    entries: [width]?Pose = @splat(null),

    pub const Family = enum(u8) {
        missile,
        decoy,

        pub fn records(family: Family) usize {
            return switch (family) {
                .missile => game.missiles.max_missiles,
                .decoy => game.cloak.max_countermeasures,
            };
        }

        pub fn pageCount(family: Family) usize {
            return switch (family) {
                .missile => missiles_pages,
                .decoy => decoy_pages,
            };
        }
    };

    pub const Pose = struct {
        reuse: u32,
        kind: missile.GameMissile = .none,
        position: Vector,
        angles: [3]i16,
        flight: Flight = .{},

        pub const Flight = packed struct(u8) {
            burn: u6 = 0,
            jettisoned: bool = false,
            launched: bool = false,
        };
    };

    pub fn index(page: Page) usize {
        return @as(usize, page.number) + if (page.family == .decoy) missiles_pages else @as(usize, 0);
    }

    pub fn first(page: Page) usize {
        return @as(usize, page.number) * width;
    }

    pub fn mask(page: *const Page) u16 {
        var found: u16 = 0;
        for (page.entries, 0..) |entry, at| if (entry != null) {
            found |= @as(u16, 1) << @as(u4, @intCast(at));
        };
        return found;
    }

    pub fn write(page: *const Page, w: *std.Io.Writer) !void {
        try w.writeInt(u32, page.tick, .little);
        try w.writeByte(@backingInt(page.family));
        try w.writeByte(page.number);
        try w.writeInt(u16, page.mask(), .little);
        for (page.entries) |entry| {
            const pose = entry orelse continue;
            try w.writeInt(u32, pose.reuse, .little);
            if (page.family == .missile) {
                try w.writeInt(i16, @backingInt(pose.kind), .little);
                try w.writeByte(@bitCast(pose.flight));
            }
            inline for (0..3) |axis| try w.writeInt(u32, @bitCast(pose.position[axis]), .little);
            for (pose.angles) |angle| try w.writeInt(i16, angle, .little);
        }
    }

    pub fn read(r: *std.Io.Reader) !Page {
        var page: Page = .{
            .tick = try r.takeInt(u32, .little),
            .family = try r.takeEnum(Family, .little),
            .number = try r.takeByte(),
        };
        if (page.number >= page.family.pageCount() or page.tick == 0) return error.InvalidProjectilePage;
        const alive = try r.takeInt(u16, .little);
        for (&page.entries, 0..) |*entry, at| {
            if (alive & (@as(u16, 1) << @as(u4, @intCast(at))) == 0) continue;
            if (page.first() + at >= page.family.records()) return error.InvalidProjectilePage;
            var pose: Pose = .{
                .reuse = try r.takeInt(u32, .little),
                .position = undefined,
                .angles = undefined,
            };
            if (page.family == .missile) {
                pose.kind = try r.takeEnum(missile.GameMissile, .little);
                if (pose.kind == .none or pose.kind == .torpedo) return error.InvalidProjectilePage;
                pose.flight = @bitCast(try r.takeByte());
            }
            inline for (0..3) |axis| {
                pose.position[axis] = @bitCast(try r.takeInt(u32, .little));
                if (!std.math.isFinite(pose.position[axis])) return error.InvalidProjectilePage;
            }
            for (&pose.angles) |*angle| angle.* = try r.takeInt(i16, .little);
            entry.* = pose;
        }
        return page;
    }
};
