//! The keys OpenReliant adds for testing, which the original leaves unbound, and which act outside
//! any mission's file, in the sandbox alone (`active`): F2 and F3 start the mission again with the
//! loadout's ship the previous or next ship type (`nextShipType`), and F4 brings another wing of
//! Sabres in front of the player (`bringWing`).

const std = @import("std");
const log = std.log.scoped(.test_keys);

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const game = engine.game;
const math = engine.surrender.math;
const mission0 = @import("mission0.zig");

/// Whether the test keys work in mission `number`: in the sandbox alone (`mission0.number`), so that
/// they never change one of the game's missions.
pub fn active(number: u16) bool {
    return number == mission0.number;
}

test active {
    try std.testing.expect(active(mission0.number));
    try std.testing.expect(!active(1));
}

/// F2 and F3, with the way each steps through the ship types.
pub const ship_keys = [_]struct { engine.input.Key, isize }{ .{ .f2, -1 }, .{ .f3, 1 } };
pub const wing_key: engine.input.Key = .f4;

/// The ship type `step` from `from` that has a model, going round the table.
pub fn nextShipType(from: usize, step: isize) usize {
    const types = game.create.models.ship_types;
    var at = from;
    for (types) |_| {
        at = @intCast(@mod(@as(isize, @intCast(at)) + step, @as(isize, types.len)));
        if (types[at].model != null) return at;
    }
    return from;
}

/// A wing of Sabres in front of the player, as mission 0's own: `mission0.wing_size` of them,
/// `mission0.wing_ahead` ahead of the player's ship and `mission0.wing_spacing` apart, facing it,
/// flown by `mission0.wing_pilot` and each under a Fight order against the player. They take the
/// next slots, as the objects the game makes past the mission's ships do; those past the last slot
/// are left out.
pub fn bringWing(orders: game.aigeneric.Context) void {
    const world = orders.world;
    const all = world.objects;
    const spawn = world.spawn orelse return;
    const ship = &all.slots[all.player].object;
    const from = ship.nextPosition();
    const facing = math.product(ship.root.next_orientation, math.rotation(.y, std.math.pi));
    for (0..mission0.wing_size) |place| {
        const across = (@as(f32, @floatFromInt(place)) - @as(f32, mission0.wing_size - 1) / 2) * mission0.wing_spacing;
        const at = from + math.transform(ship.root.next_orientation, .{ across, 0, mission0.wing_ahead });
        const index = game.create.createObject(all, spawn.tables, spawn.types, null, .sabre, 0, at, world.random) catch |err| {
            log.warn("the wing is left out: {s}", .{@errorName(err)});
            return;
        };
        const slot = &all.slots[index];
        game.objects.setOrientation(&slot.object, &slot.drawn, facing);
        game.pilots.setPilot(&slot.object, mission0.wing_pilot);
        _ = game.aigeneric.giveShip(orders, index, .fight, all.player, null);
    }
}

test nextShipType {
    // The Predator's neighbours: the Nagi after it, and the last type with a model before it.
    try std.testing.expectEqual(1, nextShipType(0, 1));
    const last = nextShipType(0, -1);
    try std.testing.expect(game.create.models.ship_types[last].model != null);
    try std.testing.expectEqual(0, nextShipType(last, 1));
}

test bringWing {
    var world: game.gameobj.testing.Mission = undefined;
    try world.init(std.testing.allocator);
    defer world.deinit();
    const player = try world.add(.predator, @splat(0));
    var orders = world.orders();
    orders.world.spawn = world.spawn(game.create.testing.no_models);
    bringWing(orders);
    // Four Sabres ahead, facing the player, fighting it.
    const all = world.objects;
    try std.testing.expectEqual(1 + mission0.wing_size, all.count);
    for (all.slots[1..all.count]) |slot| {
        try std.testing.expectEqual(game.gameobj.Type.sabre, slot.object.type);
        try std.testing.expectEqual(mission0.wing_pilot, slot.object.pilot);
        try std.testing.expectEqual(player, slot.orders[0].target.ship());
        try std.testing.expectApproxEqAbs(-1, math.forward(slot.object.root.orientation)[2], 1e-6);
    }
}
