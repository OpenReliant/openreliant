//! Shared arena pickup rules from deathmatch.cpp. The host owns contact and the effect timers.
const std = @import("std");
const math = @import("../../surrender/math.zig");
const aigeneric = @import("../aigeneric.zig");
const cloak = @import("../cloak.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const main = @import("../main.zig");
const six_beacons = @import("../dmscenarios/six_beacons.zig");
const sound3d = @import("../sound3d.zig");
const objects = @import("../objects.zig");
const shadow = @import("../dmscenarios/hunt_the_shadow.zig");

const Kind = gameobj.PowerUp;
pub const Rule = struct {
    kind: Kind,
    weight: u16,
    ticks: ?i32 = null,
    icon: u8,
    timer_offset: ?i16 = null,
};

/// The random entries of mp_powerup_rules (0x0050C508). The remaining entries describe
/// scenario objectives and have no weight. Durations are in mission ticks.
pub const rules = [_]Rule{
    .{ .kind = .invulnerable, .weight = 100, .ticks = 1500, .icon = 2, .timer_offset = 0 },
    .{ .kind = .cloak, .weight = 100, .ticks = 1500, .icon = 0, .timer_offset = 0 },
    .{ .kind = .mine, .weight = 100, .icon = 4 },
    .{ .kind = .fuel, .weight = 250, .ticks = 200, .icon = 6 },
    .{ .kind = .repair, .weight = 30, .ticks = 200, .icon = 5 },
    .{ .kind = .missile, .weight = 150, .icon = 1 },
    .{ .kind = .countermeasures, .weight = 100, .ticks = 200, .icon = 9 },
    .{ .kind = .half_throttle, .weight = 20, .ticks = 2500, .icon = 8, .timer_offset = 6 },
    .{ .kind = .no_shield_recharge, .weight = 20, .ticks = 1500, .icon = 3, .timer_offset = 2 },
    .{ .kind = .reversed_controls, .weight = 20, .ticks = 1000, .icon = 7, .timer_offset = 6 },
};

pub fn rule(kind: Kind) ?Rule {
    const index = std.math.cast(usize, @backingInt(kind)) orelse return null;
    return if (index < rules.len) rules[index] else null;
}

const total_weight = total: {
    var sum: u16 = 0;
    for (rules) |entry| sum += entry.weight;
    break :total sum;
};

/// mp_arena_prepare_pickups (0x004B1760) builds the cumulative odds used by powerup_give.
fn choose(draw: f32) Rule {
    const odds: [rules.len]f32 = comptime odds: {
        var result: [rules.len]f32 = undefined;
        var sum: u16 = 0;
        for (rules, &result) |entry, *boundary| {
            sum += entry.weight;
            boundary.* = @as(f32, @floatFromInt(sum)) / total_weight;
        }
        break :odds result;
    };
    for (rules, odds) |entry, boundary| {
        if (draw < boundary) return entry;
    }
    return rules[0];
}

/// The same installed mission defines the pickup order and positions on both ends.
pub const Pickups = struct {
    pub const Mask = u32;
    pub const capacity = @bitSizeOf(Mask);
    slots: [capacity]gameobj.ObjectRef = undefined,
    count: usize = 0,

    pub fn collect(all: *const create.Objects) !Pickups {
        var items: Pickups = .{};
        for (all.slots[all.players..all.count], all.players..) |*slot, index| {
            if (!slot.object.created or slot.object.type.base() != .powerup_random) continue;
            if (items.count == items.slots.len) return error.TooManyArenaPickups;
            items.slots[items.count] = .of(all, @intCast(index));
            items.count += 1;
        }
        return items;
    }

    pub fn visible(items: *const Pickups, all: *const create.Objects) Mask {
        var mask: Mask = 0;
        for (items.slots[0..items.count], 0..) |reference, i| {
            const slot = reference.resolve(all) orelse continue;
            if (!all.slots[slot].object.flags.disabled) mask |= bit(i);
        }
        return mask;
    }

    pub fn show(items: *const Pickups, all: *create.Objects, mask: Mask) !void {
        if (items.count < capacity and mask >> @as(u5, @intCast(items.count)) != 0) return error.InvalidArenaPickupMask;
        for (items.slots[0..items.count], 0..) |reference, i| {
            const slot = reference.resolve(all) orelse continue;
            all.slots[slot].object.flags.disabled = mask & bit(i) == 0;
        }
    }

    fn bit(i: usize) Mask {
        return @as(Mask, 1) << @as(u5, @intCast(i));
    }
};

pub const mine_count = 20;
const mine_spacing: f32 = -1.05; // 0x004DCA60

/// The host preserves the original twenty mine slots and reuses them in order.
pub const Round = struct {
    pickups: Pickups,
    mine_start: u16,
    next_mine: usize = 0,
    mine_owners: [mine_count]?gameobj.DamageSource = @splat(null),
    held_from: [@import("spawn.zig").positions]?gameobj.ObjectRef = @splat(null),
    last_wait: i32 = 0,

    pub fn start(all: *create.Objects) !Round {
        const pickups = try Pickups.collect(all);
        const mine_start = try reserveMines(all);
        return .{ .pickups = pickups, .mine_start = mine_start };
    }

    pub fn owner(round: *const Round, mine: u16) ?gameobj.DamageSource {
        if (mine < round.mine_start or mine - round.mine_start >= mine_count) return null;
        return round.mine_owners[mine - round.mine_start];
    }

    /// mp_arena_pickups_frame (0x004B18E0) checks contact before ending expired effects.
    pub fn frame(round: *Round, world: gameobj.World) void {
        const all = world.objects;
        const states = all.player_states[0..all.playerSlotCount()];
        var joined: usize = 0;
        for (states) |*state| {
            if (state.membership == .joined) joined += 1;
        }
        for (states, 0..) |*state, at| {
            const index: u16 = @intCast(at);
            if (!all.hasBoundPlayerShip(index)) continue;
            if (shadow.isShadow(all, index)) continue;
            const slot = &all.slots[index];
            if (slot.object.power_up != .none or world.clock.frame_start < state.membership.joined.pickups_after or
                slot.running(.deathmatch_respawn_effect) != null) continue;
            for (round.pickups.slots[0..round.pickups.count]) |reference| {
                const item = &all.slots[reference.resolve(all) orelse continue];
                if (item.object.flags.disabled or math.distance(slot.drawn.position, item.drawn.position) >= slot.object.radius + item.object.radius) continue;
                if (joined < 2) {
                    if (world.clock.frame_start -| round.last_wait > 30)
                        six_beacons.Notice.post(world, all.playerBinding(index).?.participant, .waiting_for_players);
                    round.last_wait = world.clock.frame_start;
                    break;
                }
                round.take(world, index, reference, choose(world.random.fraction())) catch |err|
                    std.log.warn("could not fit arena power-up: {s}", .{@errorName(err)});
                break;
            }
        }
        for (0..states.len) |at| {
            if (round.held_from[at] == null) continue;
            const index: u16 = @intCast(at);
            const object = &all.slots[index].object;
            if (object.power_up_until == -1 or world.clock.frame_start <= object.power_up_until) continue;
            if (object.power_up == .cloak and !shadow.isShadow(all, index)) cloak.uncloak(world, index);
            round.release(all, index);
        }
    }

    /// pickup_collect and powerup_give (0x004B25C0, 0x004B1C00) hide the source and grant
    /// one effect. Only missiles and mines wait for Launch Missile.
    fn take(round: *Round, world: gameobj.World, index: u16, reference: gameobj.ObjectRef, entry: Rule) !void {
        const all = world.objects;
        const item = &all.slots[reference.slot].object;
        const slot = &all.slots[index];
        const ship = &slot.object;
        if (entry.kind == .missile) try create.fitArenaMissile(all, index);
        item.flags.disabled = true;
        round.held_from[index] = reference;
        ship.power_up = entry.kind;
        ship.power_up_since = world.clock.frame_start;
        ship.power_up_until = if (entry.ticks) |duration| world.clock.frame_start +| duration else -1;
        switch (entry.kind) {
            .invulnerable => ship.invulnerable = ._unknown_4,
            .cloak => cloak.beginPowerUp(world, index),
            .fuel => if (slot.combat) |combat| {
                const full = combat.fullFuel();
                ship.afterburner_fuel = @min(full, ship.afterburner_fuel +| @divTrunc(full, 4));
            },
            .repair => if (slot.combat) |combat| {
                ship.shields = .all(combat.fullShields() - 1);
                ship.armor = .all(combat.fullArmor());
                main.armorConditions(ship, combat);
            },
            .countermeasures => ship.countermeasures +|= 3,
            .no_shield_recharge => ship.shields = .all(0),
            else => {},
        }
        sound3d.playIn(world, null, null, reference.slot, .dmpickup, 1, .not_reserved);
    }

    /// powerup_use (0x004B1B20), called by Launch Missile. Return true when the regular
    /// missile path should run, then let its caller consume the held power-up.
    pub fn launch(round: *Round, world: gameobj.World, index: u16) bool {
        const slot = &world.objects.slots[index];
        switch (slot.object.power_up) {
            .missile => return true,
            .mine => {
                round.dropMine(world, index) catch |err| {
                    std.log.warn("could not place arena mine: {s}", .{@errorName(err)});
                    return false;
                };
                round.release(world.objects, index);
            },
            else => {},
        }
        return false;
    }

    /// powerup_place_mine (0x004B2130) puts the mine just behind the fighter, at 1.05 times
    /// their combined radii. Its owner survives slot reuse as an ordinary damage source.
    fn dropMine(round: *Round, world: gameobj.World, index: u16) !void {
        const spawn = world.spawn orelse return error.MissingShipTables;
        const all = world.objects;
        const mine = round.mine_start + @as(u16, @intCast(round.next_mine));
        const fighter = &all.slots[index];
        create.resetSlot(.of(world), mine);
        round.mine_owners[round.next_mine] = null;
        try makeMine(all, mine, spawn.tables, spawn.types, world.random);
        const built = &all.slots[mine];
        const offset = (built.object.radius + fighter.object.radius) * mine_spacing;
        const place: math.Place = .{
            .orientation = fighter.drawn.orientation,
            .position = fighter.drawn.point(.{ 0, 0, offset }),
        };
        objects.setPlace(&built.object, &built.drawn, place);
        round.mine_owners[round.next_mine] = .of(all, index);
        round.next_mine = (round.next_mine + 1) % mine_count;
    }

    /// Destruction, departure, expiry and use all free the original pickup (0x004AF120,
    /// 0x004B1730, 0x004B195B and 0x004B1B8E).
    pub fn release(round: *Round, all: *create.Objects, index: u16) void {
        if (index >= round.held_from.len) return;
        const reference = round.held_from[index] orelse return;
        round.held_from[index] = null;
        const ship = &all.slots[index].object;
        if (ship.power_up == .invulnerable) ship.invulnerable = .none;
        ship.power_up = .none;
        if (reference.resolve(all)) |at| all.slots[at].object.flags.disabled = false;
    }
};

pub fn reserveMines(all: *create.Objects) !u16 {
    const first = all.count;
    if (@as(usize, first) + mine_count > all.slots.len) return error.TooManyArenaObjects;
    all.count += mine_count;
    return first;
}

pub fn makeMine(all: *create.Objects, slot: u16, tables: *create.Stats, types: create.Types, random: *@import("../../random.zig").Random) !void {
    _ = try create.createObject(all, tables, types, slot, .of(.proximity_mine), 0, @splat(0), random);
    // powerup_place_mine clears the object's flags at 0x004B21C3. A placed mine
    // can collide with ships, but the target selector skips it.
    all.slots[slot].object.flags = .{};
}

test "original power-up weights and types match every ticket" {
    try std.testing.expectEqual(890, total_weight);
    var ticket: u16 = 0;
    for (rules) |entry| {
        for (ticket..ticket + entry.weight) |draw| {
            const fraction = (@as(f32, @floatFromInt(draw)) + 0.5) / total_weight;
            try std.testing.expectEqual(entry.kind, choose(fraction).kind);
        }
        ticket += entry.weight;
    }
}

test "one pickup belongs to the first pilot and returns after its effect expires" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    all.players = 2;
    for (0..2) |_| {
        const index = try mission.add(.of(.predator), @splat(0));
        const pilot = all.joinParticipant(index).?;
        _ = all.bindParticipant(pilot, .of(all, index)).?;
    }
    const pickup = try mission.add(.of(.powerup_random), @splat(0));
    mission.slot(pickup).object.radius = 100;
    var round: Round = try .start(all);
    const wanted = rule(.countermeasures).?;
    var seed: u64 = 1;
    while (true) : (seed += 1) {
        var random = @import("../../random.zig").Random.init(seed);
        if (choose(random.fraction()).kind == wanted.kind) break;
    }
    mission.random = .init(seed);
    const before = mission.slot(0).object.countermeasures;
    const other = mission.slot(1).object.countermeasures;
    const scene = mission.world();
    round.frame(scene);
    try std.testing.expectEqual(.countermeasures, mission.slot(0).object.power_up);
    try std.testing.expectEqual(.none, mission.slot(1).object.power_up);
    try std.testing.expectEqual(before + 3, mission.slot(0).object.countermeasures);
    try std.testing.expectEqual(other, mission.slot(1).object.countermeasures);
    try std.testing.expectEqual(0, round.pickups.visible(all));
    mission.clock.frame_start = wanted.ticks.?;
    round.frame(scene);
    try std.testing.expectEqual(0, round.pickups.visible(all));
    mission.clock.frame_start += 1;
    round.frame(scene);
    try std.testing.expectEqual(.none, mission.slot(0).object.power_up);
    try std.testing.expectEqual(before + 3, mission.slot(0).object.countermeasures);
    try std.testing.expectEqual(1, round.pickups.visible(all));
}
