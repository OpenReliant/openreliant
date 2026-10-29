//! OpenReliant's own landings in a bay: the ship flies in at the doors of a gate and comes to rest
//! where a ship waits to launch through that gate. In a hangar bay (`ailand.Style.bay`) that is the
//! gate's launch point (`launch.gateOf`); in the Badanov's or the Krasny's bay
//! (`ailand.Style.badanov`), the place their launch sets a ship at (`launch.badanov.gatePlace`).
//!
//! **Improvement:** the game has no landing in a bay.

const std = @import("std");
const log = std.log.scoped(.orders);

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const Context = aigeneric.Context;
const ailand = @import("../ailand.zig");
const State = ailand.State;
const camera = @import("../camera.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const input = @import("../../input.zig");
const launch = @import("../launch.zig");
const badanov_launch = @import("../launch/badanov.zig");
const bay_launch = @import("../launch/bay.zig");
const objects = @import("../objects.zig");
const sound3d = @import("../sound3d.zig");
const yamato = @import("yamato.zig");

/// The steps of a landing in a bay (`update`).
pub const Step = enum(u32) {
    /// The player flies on until the landing is due; then the cutaway begins (`cutaway`), and the
    /// gate's doors open.
    waiting = 0,
    /// The ship flies in at the doors to where it lands, slowing as it nears, and stops within
    /// `ailand.near` of it; the doors close behind it.
    approaching = 1,
    /// It waits `ailand.landed_wait` ticks there, and the mission is over.
    landed = 2,
    _,
};

/// The bay a landing goes into, by its style.
const Bay = enum {
    /// A hangar bay: to its gate's launch point (`launch.gateOf`), through the gate's doors
    /// (`launch.bay.Doors`).
    hangar,
    /// The Badanov's or the Krasny's: to where a ship waits at the gate to launch
    /// (`launch.badanov.gatePlace`), through their two doors (`launch.badanov.landing_doors`).
    badanov,

    fn of(state: *const State) Bay {
        return if (state.landing() == .badanov) .badanov else .hangar;
    }
};

/// How far out from the mouth of the bay the cutaway sets the ship, along the way it launches:
/// this share of the bay's depth, from where the ship lands to the mouth, and at least this many
/// times the ship's radius, so that a shallow bay still gives the ship a way to fly in on. They go
/// by the bay and the ship rather than by a fixed distance, so that the landing fits any carrier.
const approach_share: f32 = 0.6;
const approach_least_radii: f32 = 20;

/// How far out from the mouth of a bay `depth` deep the cutaway sets a ship of radius `radius`
/// (`approach_share`, `approach_least_radii`).
fn approach(depth: f32, radius: f32) f32 {
    return @max(approach_share * depth, approach_least_radii * radius);
}

/// The first step of a landing in a bay. Aimed at the carrier as a whole, as the player's request
/// aims it, the landing is due `ailand.wait` ticks on, as the Reliant's is. Aimed at a gate, as a
/// mission's `SetAI` aims it at one of the carrier's components, it begins at once, so that the
/// mission lands the ship at its own moment. A ship sent home for its friendly fire lands at once
/// too. Where the carrier's model has no place to land at the gate, the landing is none.
pub fn init(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.land;
    const target = slot.orders[0].target;
    const carrier = target.slotIn(all) orelse return;
    const kind: Bay = .of(state);
    if (gatePlace(all, carrier, kind, aimedGate(target)) == null) {
        state.setLanding(null);
        switch (kind) {
            .hangar => log.warn("object {d} cannot land on what its order aims at: it has no launch point {d}", .{ index, aimedGate(target) }),
            .badanov => log.warn("object {d} cannot land on what its order aims at: it has no bay", .{index}),
        }
        return;
    }
    state.step = .of(Step.waiting);
    const at_once = ctx.world.player.ending.sentHome() or !target.isWhole();
    state.due = ctx.world.clock.frame_start + if (at_once) 0 else ailand.wait;
}

/// The gate a landing aims at: the component of its order's target, or gate 0 for the carrier as a
/// whole.
fn aimedGate(target: aigeneric.Target) i16 {
    return if (target.isWhole()) 0 else target.component;
}

/// Where a ship landing in `kind` of bay at gate `gate` of the carrier in slot `carrier` comes to
/// rest, and how it is turned there, in the world; null where the carrier's model has no such
/// place.
fn gatePlace(all: *const create.Objects, carrier: u16, kind: Bay, gate: i16) ?math.Place {
    return switch (kind) {
        .hangar => (launch.gateOf(all, carrier, gate) orelse return null).place,
        .badanov => badanov_launch.gatePlace(&all.slots[carrier], gate),
    };
}

/// The doors of the gate the landing of the ship in `slot` aims at.
fn doorsOf(all: *const create.Objects, slot: *const create.Slot) bay_launch.Doors {
    const target = slot.orders[0].target;
    const carrier = target.slotIn(all) orelse return .{};
    return switch (Bay.of(&slot.state.land)) {
        .hangar => .of(all.slots[carrier].object.type, aimedGate(target)),
        .badanov => badanov_launch.landing_doors,
    };
}

/// A step of a landing in a bay (`Step`). A ship other than the player's lets its landing go at
/// once, as on the Yamato.
///
/// While the landing is not yet due, the player's ship flies by the player's controls. Then the
/// cutaway begins (`cutaway`): the mission's scene becomes the landing's, every object but the
/// ship and the carrier is disabled, the ship flies by its nose (`motion.Motion.plain`), passing
/// through everything, and the gate's doors open as the launch opens them
/// (`launch.bay.playDoors`). The ship steers at where it lands, upright, its throttle
/// `ailand.approach_throttle` for each unit it has to go, at most the one that flies it at
/// `yamato.bay_speed`. It stops within `ailand.near` of the place, sounding its landing, the doors
/// close behind it, and `ailand.landed_wait` ticks later the mission is over.
pub fn update(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    if (index != all.player) return aigeneric.end(ctx, index);
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.land;
    const carrier = slot.orders[0].target.slotIn(all) orelse return aigeneric.end(ctx, index);
    const now = world.clock.frame_start;
    switch (state.step.as(Step)) {
        .waiting => {
            if (now < state.due) return input.playerControlOrder(ctx, index);
            cutaway(ctx, index, carrier);
            ailand.showLanding(world, index, carrier);
            state.step = .of(Step.approaching);
            slot.motion = .plain;
            object.flags.no_collisions = true;
            bay_launch.playDoors(world, &all.slots[carrier], doorsOf(all, slot), .open);
        },
        .approaching => {
            const point: Vector = state.gate_place;
            _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{ .roll_upright = true });
            const distance = math.distance(point, object.nextPosition());
            const most = if (ai.slotCruise(slot, world.view())) |cruise| yamato.bay_speed / cruise else ailand.approach_most;
            object.throttle = @min(distance * ailand.approach_throttle, most);
            if (distance >= ailand.near) return;
            object.letGo();
            ai.stop(object);
            sound3d.playIn(world, null, null, index, .shipland, 1, .not_reserved);
            bay_launch.playDoors(world, &all.slots[carrier], doorsOf(all, slot), .close);
            state.step = .of(Step.landed);
            state.due = now + ailand.landed_wait;
            log.debug("object {d} is down at its gate at tick {d}", .{ index, now });
        },
        .landed => ailand.endAfter(world, state.due),
        _ => {},
    }
}

/// The cutaway of a landing in a bay, as the Reliant's (`ailand.reliant`). One of the Reliant's two
/// views, picked at random, watches the ship, locked, standing by the bay (`camera.Landing.bay`).
/// The carrier moves to `ailand.carrier_away`, turned as the world is, and where the ship lands is
/// worked out there (`gatePlace`), with the mouth of the bay (`mouth`). The ship stands `approach`
/// out from the mouth along the way a ship launches, looking in at where it lands, stopped, its
/// power shared evenly. The carrier's orders are all popped, and it stops.
fn cutaway(ctx: Context, index: u16, carrier: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.land;
    ailand.watch(world, index, .{ .landing_aside, .landing_tube });
    const holder = &all.slots[carrier];
    ailand.moveAway(holder);
    const gate = gatePlace(all, carrier, .of(state), aimedGate(slot.orders[0].target)) orelse return;
    state.gate_place = gate.position;
    state.gate_orientation = gate.orientation;
    const at_mouth = mouth(&holder.object, gate);
    state.mouth = at_mouth;
    const object = &slot.object;
    const out = approach(math.distance(gate.position, at_mouth), object.radius);
    objects.setPosition(object, &slot.drawn, at_mouth + math.forward(gate.orientation) * @as(Vector, @splat(out)));
    objects.setOrientation(object, &slot.drawn, math.lookAt(gate.position - object.nextPosition()));
    ailand.stopShip(object);
    ailand.stopCarrier(ctx, carrier);
    const set = object.nextPosition();
    log.debug("object {d} of radius {d:.0} lands at gate {d} of object {d}: there at ({d:.0}, {d:.0}, {d:.0}), the bay's mouth at ({d:.0}, {d:.0}, {d:.0}), the ship set at ({d:.0}, {d:.0}, {d:.0})", .{
        index,            object.radius,    aimedGate(slot.orders[0].target), carrier,
        gate.position[0], gate.position[1], gate.position[2],                 at_mouth[0],
        at_mouth[1],      at_mouth[2],      set[0],                           set[1],
        set[2],
    });
}

/// The mouth of the bay a ship launches from `gate`, a place in `carrier`: where the way out from
/// it, along the Z axis of the place, leaves the carrier's bounds (`GameObject.bounds_min`,
/// `bounds_max`), in the world. The place itself where the way out is already outside them, or runs
/// along none of their axes.
fn mouth(carrier: *const gameobj.GameObject, gate: math.Place) Vector {
    const frame: math.Place = .{ .position = carrier.nextPosition(), .orientation = carrier.root.next_orientation };
    const from = frame.inverse(gate.position);
    const way = math.transformTransposed(frame.orientation, math.forward(gate.orientation));
    const min = carrier.bounds_min.vector();
    const max = carrier.bounds_max.vector();
    var reach = std.math.inf(f32);
    inline for (0..3) |axis| if (@abs(way[axis]) > std.math.floatEps(f32)) {
        const edge = if (way[axis] > 0) max[axis] else min[axis];
        reach = @min(reach, (edge - from[axis]) / way[axis]);
    };
    if (!std.math.isFinite(reach) or reach < 0) reach = 0;
    return frame.point(from + way * @as(Vector, @splat(reach)));
}

/// What the landing's views stand by (`camera.Landing.bay`): where the ship lands and how it is
/// turned there, and the bay's mouth, as the landing's state keeps them.
pub fn seen(state: *const State) ?camera.Landing {
    return .{ .bay = .{
        .gate = .{ .position = state.gate_place, .orientation = state.gate_orientation },
        .mouth = state.mouth,
    } };
}

test "the player's ship lands in a hangar bay of its carrier, and the mission is over" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var bremen_model: bay_launch.testing.Bremen = undefined;
    bremen_model.init();
    var variables: @import("../../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    const ctx: Context = .of(world);
    const player = try mission.add(.of(.predator), .{ 100, 0, 0 });
    const bremen = try mission.add(.of(.bremen), .{ 0, 0, 50000 });
    try bremen_model.parts.fit(gpa, mission.slot(bremen));
    // The Bremen offers no landing unless a mod or a script gives it one.
    try std.testing.expectEqual(null, mission.slot(bremen).landing);
    mission.slot(bremen).landing = .bay;
    const other = try mission.add(.of(.predator), .{ 5, 5, 5 });
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, bremen, null));
    const slot = mission.slot(player);
    const state = &slot.state.land;

    // The bay's style. Aimed at the carrier as a whole, as the player's request aims it, the
    // landing is due `wait` ticks on, until which the player flies on.
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(ailand.Style.bay, state.landing().?);
    try std.testing.expectEqual(Step.waiting, state.step.as(Step));
    try std.testing.expectEqual(1000 + ailand.wait, state.due);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.waiting, state.step.as(Step));

    // Then the cutaway: the carrier stopped far away, gate 0's doors opening, the ship out from
    // the bay's mouth looking in at the gate's launch point, flying by its nose and passing
    // through everything, and every other object disabled. The point lies 100 along the carrier's
    // Z axis, and the carrier's bounds reach 400 along it, where the bay's mouth is.
    mission.slot(bremen).object.bounds_min = .of(.{ -300, -300, -300 });
    mission.slot(bremen).object.bounds_max = .of(.{ 300, 300, 400 });
    mission.clock.frame_start = 1000 + ailand.wait;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.approaching, state.step.as(Step));
    try std.testing.expectEqual(@import("../main.zig").Showing.landing, mission.player.showing);
    try std.testing.expect(mission.slot(other).object.flags.disabled);
    try std.testing.expect(!mission.slot(bremen).object.flags.disabled and !slot.object.flags.disabled);
    try std.testing.expectEqual(ailand.carrier_away, mission.slot(bremen).object.nextPosition());
    try std.testing.expectEqual(0, mission.slot(bremen).object.order_count);
    const gate = ailand.carrier_away + Vector{ 0, 0, 100 };
    try std.testing.expectEqual(gate, @as(Vector, state.gate_place));
    try std.testing.expectEqual(ailand.carrier_away + Vector{ 0, 0, 400 }, @as(Vector, state.mouth));
    // The bay is 300 deep, so the ship starts six tenths of that out from the mouth, or twenty of
    // its radii where that is more.
    const out = approach(300, slot.object.radius);
    try std.testing.expectEqual(ailand.carrier_away + Vector{ 0, 0, 400 + out }, slot.object.nextPosition());
    try std.testing.expectEqual(180, approach(300, 0));
    try std.testing.expectEqual(16000, approach(300, 800));
    const facing = math.forward(slot.object.root.next_orientation);
    try std.testing.expectApproxEqAbs(0, facing[0], 1e-5);
    try std.testing.expectApproxEqAbs(0, facing[1], 1e-5);
    try std.testing.expectApproxEqAbs(-1, facing[2], 1e-5);
    try std.testing.expectEqual(@import("../motion.zig").Motion.plain, slot.motion.?);
    try std.testing.expect(slot.object.flags.no_collisions);
    const doors = mission.slot(bremen).model.?.parts;
    try std.testing.expectEqual(bay_launch.door_speed, doors[6].animation.speed);
    try std.testing.expectEqual(bay_launch.door_speed, doors[7].animation.speed);

    // Far from the point, it flies in at the throttle that flies it at `bay_speed` by its cruise
    // speed; nearer, at `approach_throttle` for each unit it has to go; and within `near`, it
    // stops, sounding its landing, and the doors close behind it.
    objects.setPosition(&slot.object, &slot.drawn, gate + Vector{ 0, 0, 50000 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectApproxEqAbs(yamato.bay_speed / gameobj.testing.flight.max_speed, slot.object.throttle, 1e-6);
    objects.setPosition(&slot.object, &slot.drawn, gate + Vector{ 0, 0, 1000 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectApproxEqAbs(1000 * ailand.approach_throttle, slot.object.throttle, 1e-6);
    objects.setPosition(&slot.object, &slot.drawn, gate + Vector{ 0, 0, 150 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.landed, state.step.as(Step));
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(-bay_launch.door_speed, doors[6].animation.speed);

    // `landed_wait` ticks on, the mission is over.
    mission.ordersAfter(ctx, player, ailand.landed_wait);
    try std.testing.expectEqual(0, variables.mission_over);
    mission.ordersAfter(ctx, player, 1);
    try std.testing.expectEqual(1, variables.mission_over);
}

test "a landing a mission aims at a gate begins at once, at that gate" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var bremen_model: bay_launch.testing.Bremen = undefined;
    bremen_model.init();
    const ctx = mission.orders();
    const player = try mission.add(.of(.predator), @splat(0));
    const bremen = try mission.add(.of(.bremen), .{ 0, 0, 50000 });
    try bremen_model.parts.fit(gpa, mission.slot(bremen));
    mission.slot(bremen).landing = .bay;
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, bremen, 1));
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    const state = &mission.slot(player).state.land;
    try std.testing.expectEqual(1000, state.due);
    try std.testing.expectEqual(Step.approaching, state.step.as(Step));
    // Gate 1's launch point lies 200 along the carrier's Z axis.
    try std.testing.expectEqual(ailand.carrier_away + Vector{ 0, 0, 200 }, @as(Vector, state.gate_place));
}

test "the player's ship lands in the Badanov's bay where its launch sets ships, and the mission is over" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var badanov_model: badanov_launch.testing.Badanov = undefined;
    try badanov_model.init(gpa, badanov_launch.testing.bounds);
    defer badanov_model.deinit(gpa);
    var variables: @import("../../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    const ctx: Context = .of(world);
    const player = try mission.add(.of(.predator), .{ 100, 0, 0 });
    const badanov = try mission.add(.of(.badanov), .{ 0, 0, 50000 });
    try badanov_model.parts.fit(gpa, mission.slot(badanov));
    mission.slot(badanov).landing = .badanov;
    mission.slot(badanov).object.bounds_min = .of(.{ -300, -300, -300 });
    mission.slot(badanov).object.bounds_max = .of(.{ 300, 300, 300 });
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, badanov, null));
    const slot = mission.slot(player);
    const state = &slot.state.land;
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(ailand.Style.badanov, state.landing().?);
    try std.testing.expectEqual(1000 + ailand.wait, state.due);

    // At the cutaway, the ship is to come to rest where gate 0's launch sets a ship, as it stands
    // where the cutaway has moved the carrier: 100 across, 40 up and 240 behind the bay's
    // midpoint, facing out of the bay with its nose tilted down. It starts out beyond the mouth,
    // looking in, and the Badanov's two doors open.
    mission.clock.frame_start = 1000 + ailand.wait;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.approaching, state.step.as(Step));
    const there = badanov_launch.gatePlace(mission.slot(badanov), 0).?;
    try std.testing.expectEqual(there.position, @as(Vector, state.gate_place));
    try std.testing.expectApproxEqAbs(100, state.gate_place[0] - ailand.carrier_away[0], 1e-3);
    try std.testing.expectApproxEqAbs(40, state.gate_place[1] - ailand.carrier_away[1], 1e-3);
    try std.testing.expectApproxEqAbs(-240, state.gate_place[2] - ailand.carrier_away[2], 1e-3);
    // The way out leaves the carrier's bounds at its side, 300 across.
    try std.testing.expectApproxEqAbs(300, state.mouth[0] - ailand.carrier_away[0], 1e-3);
    const inward = math.forward(slot.object.root.next_orientation);
    try std.testing.expect(math.dot(inward, math.forward(there.orientation)) < -0.99);
    const doors = mission.slot(badanov).model.?.parts;
    try std.testing.expectEqual(bay_launch.door_speed, doors[1].animation.speed);
    try std.testing.expectEqual(bay_launch.door_speed, doors[2].animation.speed);

    // Within `near` of it, it stops, and the doors close behind it; the mission is over in time.
    objects.setPosition(&slot.object, &slot.drawn, there.position + Vector{ 150, 0, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.landed, state.step.as(Step));
    try std.testing.expectEqual(-bay_launch.door_speed, doors[1].animation.speed);
    mission.ordersAfter(ctx, player, ailand.landed_wait + 1);
    try std.testing.expectEqual(1, variables.mission_over);
}

test "a landing in the Badanov's bay is none where its model has no bay" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const player = try mission.add(.of(.predator), @splat(0));
    const badanov = try mission.add(.of(.badanov), .{ 0, 0, 1000 });
    mission.slot(badanov).landing = .badanov;
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, badanov, null));
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(null, mission.slot(player).running(.land));
}

test seen {
    var state = std.mem.zeroes(State);
    state.gate_place = .{ 4, 5, 6 };
    state.gate_orientation = math.identity;
    state.mouth = .{ 7, 8, 9 };
    const in_bay = seen(&state).?.bay;
    try std.testing.expectEqual(Vector{ 4, 5, 6 }, in_bay.gate.position);
    try std.testing.expectEqual(Vector{ 7, 8, 9 }, in_bay.mouth);
}
