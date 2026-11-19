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

fn position(world: gameobj.World, first: ?u16) ?math.Place {
    const all = world.objects;
    var free: [positions]math.Place = undefined;
    var count: u15 = 0;
    var index: u16 = 0;
    for (all.slots[@min(all.players, all.count)..all.count]) |*slot| {
        if (!slot.object.created or slot.object.type.base() != .spawn_player) continue;
        const place = slot.object.placeAt(.now);
        if (first == index) return place;
        index += 1;
        if (count == free.len) continue;
        for (all.slots[0..all.players], 0..) |*pilot, at| {
            if (all.playerBinding(@intCast(at)) == null) continue;
            if (math.distance(pilot.object.position(), place.position) < occupied_margin * (pilot.object.radius + slot.object.radius)) break;
        } else {
            free[count] = place;
            count += 1;
        }
    }
    if (count == 0) return null;
    return free[world.random.below(count)];
}

/// `multiplayer_reset_ship` (`0x004AF1D0`) rebuilds the selected fighter and moves it to a
/// free spawn marker. The host publishes the result through the normal ship snapshots.
pub fn reset(world: gameobj.World, pilot: players.ParticipantRef, fighter: gameobj.Type, first: ?u16) !void {
    const spawn = world.spawn orelse return error.MissingShipTables;
    const place = position(world, first) orelse return error.NoFreeSpawn;
    const all = world.objects;
    const index = pilot.slot;
    const slot = &all.slots[index];
    const power = if (slot.object.created) slot.object.power_setting else null;
    all.arena_scenario.releaseShip(all, index);
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
    try reset(world, second, .of(.shroud), null);
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
}
