//! Spawn selection and ship reset from `deathmatch.cpp`.
const std = @import("std");
const math = @import("../../surrender/math.zig");
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const players = @import("../players.zig");
const main = @import("../main.zig");

/// The original scans the eight spawn markers in object order (`0x004AF5C0`).
pub const positions = 8;
const occupied_margin: f32 = 1.2; // 0x004DC7EC

/// The radius the pilot's fighter will have at a marker. `multiplayer_reset_ship` makes the ship
/// before it looks for a marker, so it has the new ship's radius. Here the marker is chosen
/// first, so that a pilot with no free marker keeps waiting as they are. Another ship of the
/// type gives the radius, the pilot's last among them, or else the type's model does.
fn fighterRadius(world: gameobj.World, spawn: gameobj.World.Spawn, index: u16, fighter: gameobj.Type) !f32 {
    const all = world.objects;
    const own = &all.slots[index].object;
    if (own.created and own.type == fighter) return own.radius;
    for (all.slots[0..@min(all.players, all.count)]) |*slot| {
        if (slot.object.created and slot.object.type == fighter) return slot.object.radius;
    }
    return try create.typeRadius(all, spawn.types, fighter) orelse 0;
}

/// What a marker is checked for: the ship of pilot `index`, of type `fighter`, or a ship of a
/// radius given outright.
const Newcomer = union(enum) {
    ship: struct { spawn: gameobj.World.Spawn, index: u16, fighter: gameobj.Type },
    radius: f32,
};

/// A free marker for the newcomer: marker `first` if it is free, or else any free one. A marker
/// is free when no pilot's ship is nearer than `occupied_margin` times the two ships' radii
/// (`0x004AF42D`). The newcomer's radius is worked out only once a pilot's ship is there to
/// compare with, so a map with no markers or no other pilots loads no model for it.
fn position(world: gameobj.World, first: ?u16, newcomer: Newcomer) !?math.Place {
    var radius: ?f32 = switch (newcomer) {
        .ship => null,
        .radius => |given| given,
    };
    const all = world.objects;
    var free: [positions]math.Place = undefined;
    var count: u15 = 0;
    var index: u16 = 0;
    for (all.slots[@min(all.players, all.count)..all.count]) |*slot| {
        if (!slot.object.created or slot.object.type.base() != .spawn_player) continue;
        const place = slot.object.placeAt(.now);
        const preferred = first == index;
        index += 1;
        if (count == free.len) continue;
        for (all.slots[0..all.players], 0..) |*pilot, at| {
            if (all.playerBinding(@intCast(at)) == null) continue;
            const other = radius orelse known: {
                const ship = newcomer.ship;
                const worked = try fighterRadius(world, ship.spawn, ship.index, ship.fighter);
                radius = worked;
                break :known worked;
            };
            if (math.distance(pilot.object.position(), place.position) < occupied_margin * (pilot.object.radius + other)) break;
        } else {
            if (preferred) return place;
            free[count] = place;
            count += 1;
        }
    }
    if (count == 0) return null;
    return free[world.random.below(count)];
}

/// `multiplayer_reset_ship` (`0x004AF1D0`) rebuilds the selected fighter and moves it to a
/// free spawn marker. The host publishes the result through the normal ship snapshots.
///
/// `first` is the marker of a pilot's first spawn in a round: `mp_arena_init` (`0x004AE860`)
/// sets a flag (`0x005DAE50`) that sends the local pilot's first ship to the marker with their
/// slot's number (`0x004AF4F5`). **Improvement:** the pilot takes that marker only if it is
/// free, where the original puts them there whoever stands on it.
pub fn reset(world: gameobj.World, pilot: players.ParticipantRef, fighter: gameobj.Type, first: ?u16) !void {
    const spawn = world.spawn orelse return error.MissingShipTables;
    const all = world.objects;
    const index = pilot.slot;
    const place = try position(world, first, .{ .ship = .{ .spawn = spawn, .index = index, .fighter = fighter } }) orelse return error.NoFreeSpawn;
    const slot = &all.slots[index];
    const power = if (slot.object.created) slot.object.power_setting else null;
    create.resetSlot(.of(world), index);
    all.loadout_ships[index] = fighter;
    all.loadout_racks[index] = @splat(.of(.none));
    _ = try create.createObject(all, spawn.tables, spawn.types, index, fighter, 0, place.position, world.random);
    errdefer create.resetSlot(.of(world), index);
    objects.setPlace(&slot.object, &slot.drawn, place);
    if (power) |shares| slot.object.power_setting = shares;
    if (slot.combat) |stats| slot.object.afterburner_fuel = @divTrunc(stats.afterburner_fuel, 2) * main.ticks_per_second;
    slot.object.countermeasures = 0;
    if (!try aigeneric.push(.of(world), index, .multiplayer_control, .none)) return error.OrderFailed;
    if (!try aigeneric.push(.of(world), index, .deathmatch_respawn_effect, .none)) return error.OrderFailed;
    _ = all.bindParticipant(pilot, .of(all, index)) orelse return error.BindFailed;
    slot.object.flags.targetable = @import("respawn.zig").targetable(world, index);
    const shadow = @import("../dmscenarios/hunt_the_shadow.zig");
    if (shadow.isShadow(all, index)) shadow.cloakShip(world, index);
}

test "a second admitted fighter spawns clear of the first" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    all.players = 2;
    all.count = all.players;
    const first_place: math.Vector = .{ 4000, 12, 8000 };
    const second_place: math.Vector = .{ -4000, 24, -8000 };
    _ = try mission.add(.of(.spawn_player), first_place);
    _ = try mission.add(.of(.spawn_player), second_place);
    var world = mission.world();
    world.spawn = mission.spawn(create.testing.no_models);
    const first = all.joinParticipant(0).?;
    const second = all.joinParticipant(1).?;
    try reset(world, first, .of(.predator), 0);
    // The test's ships have no model to take a radius from.
    all.slots[0].object.radius = 100;
    // Slot zero's preferred marker is occupied. A returning pilot must use a free one.
    world.arena_options.target_players = false;
    try reset(world, second, .of(.shroud), 0);
    try std.testing.expect(all.slots[0].object.flags.targetable);
    try std.testing.expect(!all.slots[1].object.flags.targetable);
    try std.testing.expectEqual(first_place, all.slots[0].drawn.position);
    try std.testing.expectEqual(second_place, all.slots[1].drawn.position);
    try std.testing.expectEqual(gameobj.Type.of(.shroud), all.slots[1].object.type);
    try std.testing.expectEqual(second, all.playerBinding(1).?.participant);
    const ctx: aigeneric.Context = .of(world);
    aigeneric.objectOrders(ctx, 1);
    try std.testing.expect(all.slots[1].object.flags.no_collisions);
    try std.testing.expectEqual(gameobj.Invulnerability._unknown_4, all.slots[1].object.invulnerable);
    mission.clock.frame_start = @import("respawn.zig").duration - 1;
    aigeneric.objectOrders(ctx, 1);
    try std.testing.expect(all.slots[1].running(.deathmatch_respawn_effect) != null);
    mission.clock.frame_start += 1;
    aigeneric.objectOrders(ctx, 1);
    try std.testing.expect(all.slots[1].running(.multiplayer_control) != null);
    try std.testing.expect(!all.slots[1].object.flags.no_collisions);
    try std.testing.expect(all.slots[1].object.invulnerable == .none);
    try std.testing.expect(!all.slots[1].object.flags.targetable);
}

test "a marker is free past the two ships' radii, and a pilot's first ship takes their slot's marker" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    all.players = 2;
    all.count = all.players;
    // Nearer than a marker's own radius would allow, which the original never counts.
    const first_place: math.Vector = .{ 0, 0, 0 };
    const second_place: math.Vector = .{ 3000, 0, 0 };
    _ = try mission.add(.of(.spawn_player), first_place);
    _ = try mission.add(.of(.spawn_player), second_place);
    var world = mission.world();
    world.spawn = mission.spawn(create.testing.no_models);
    const first = all.joinParticipant(0).?;
    const second = all.joinParticipant(1).?;
    try reset(world, first, .of(.predator), 0);
    all.slots[0].object.radius = 100;
    try reset(world, second, .of(.predator), 1);
    try std.testing.expectEqual(first_place, all.slots[0].drawn.position);
    try std.testing.expectEqual(second_place, all.slots[1].drawn.position);

    // A ship within 1.2 times the two radii keeps the marker taken.
    all.slots[1].object.radius = 100;
    objects.setPosition(&all.slots[1].object, &all.slots[1].drawn, .{ 3200, 0, 0 });
    try std.testing.expectEqual(null, try position(world, 0, .{ .radius = 100 }));
    try std.testing.expectEqual(second_place, (try position(world, 0, .{ .radius = 50 })).?.position);
}
