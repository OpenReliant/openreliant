//! Ship Follow Curve and Ship Follow Curve Backwards, orders 17 and 119: a ship flies to where a
//! path of the mission's curves ([`executor/curves.zig`](../executor/curves.zig)) starts, turned
//! along it, then along the path by `motion_follow` ([`motion.zig`](../motion.zig)), over the
//! order's seconds; backwards, from the path's end to its start. The scripts give them with
//! `ShipFollowCurve`, `MovingShipFollowCurve` and `MovingShipBackupCurve`.
//!
//! **Unverified:** the source file. The code lies after `Ai.cpp`'s known code and before
//! `aidefend.cpp`'s, and does the orders' work, as `Ai.cpp`'s neighbours do.
//!
//! Not ported: a multiplayer game's wait for the other players before the path and after it
//! (`ai_sequence_sync`, `0x00401000`, [#55](https://github.com/vdmkenny/openreliant/issues/55)).

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../../../formats/dte.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("../create.zig");
const curves = @import("../executor/curves.zig");
const events = @import("../mission/events.zig");
const gameobj = @import("../gameobj.zig");
const main = @import("../main.zig");
const motion = @import("../motion.zig");
const Order = @import("orders.zig").Order;
const vm = @import("../../vm.zig");

/// The order's data, as the command gives it (`aigeneric.Entry.data`).
pub const Data = extern struct {
    /// The curve the path starts along, by its index among the mission's curves, where the game
    /// holds its record's address.
    curve: u32 align(2),
    /// How long the path takes, in seconds.
    seconds: u32 align(2),
    /// The ship whose place carries the path, by its index among the mission's ships, or `none`:
    /// the path stands off from the curves as far as the ship stands, as the order starts, from
    /// where the mission placed it (`curves.ride`). The game holds its record's address, or null.
    offset: u32 align(2),

    /// What `curve` holds where the command names no curve, and `offset` where it names no ship.
    pub const none: u32 = 0xFFFF_FFFF;

    /// The order's data for a path from `curve` over `seconds`, carried by `offset`; `none` for a
    /// null.
    pub fn of(curve: ?u16, seconds: u32, offset: ?u16) Data {
        return .{ .curve = curve orelse none, .seconds = seconds, .offset = offset orelse none };
    }

    /// The ship whose place carries the path, where there is one.
    pub fn offsetShip(data: Data) ?u16 {
        return if (data.offset == none) null else std.math.cast(u16, data.offset);
    }

    comptime {
        assert(@offsetOf(Data, "seconds") == 0x4);
        assert(@offsetOf(Data, "offset") == 0x8);
    }
};

/// The order's state (`GameObject.order_state`).
pub const State = extern struct {
    /// The path `motion_follow` follows, and its limit, the ship's top speed.
    follower: motion.Follower,
    /// The curve the ship follows now, by its index; the game holds its record's address.
    curve: u32,
    step: Step,
    _unknown_0d: [3]u8,
    /// The mission's tick the curve began (`mission_ticks`).
    since: i32,
    /// The curve's share of the order's seconds, in ticks.
    ticks: u16,
    _unknown_16: [2]u8,
    /// The path's length, from the order's curve (`curves.pathLength`).
    path_length: f32,
    _unknown_1c: [12]u8,
    /// Where the order's offset ship stood as the order began.
    start: [3]f32,
    /// The share of the way along the curve to the next place a point marks, 0 for none
    /// (`nextMarker`).
    next_marker: f32,

    /// The share of the way along the curve to the next place a point marks, where there is one:
    /// none at 0 or less, as `follow_curve_way` takes it (`0x0040326D`).
    pub fn nextMarker(state: State) ?f32 {
        return if (state.next_marker > 0) state.next_marker else null;
    }

    comptime {
        assert(@offsetOf(State, "curve") == 0x08);
        assert(@offsetOf(State, "step") == 0x0C);
        assert(@offsetOf(State, "since") == 0x10);
        assert(@offsetOf(State, "ticks") == 0x14);
        assert(@offsetOf(State, "path_length") == 0x18);
        assert(@offsetOf(State, "start") == 0x28);
        assert(@offsetOf(State, "next_marker") == 0x34);
    }
};

/// The orders' steps.
pub const Step = enum(u8) {
    /// It flies to where the path starts, turned along it (`ai.arrive`).
    arriving = 0,
    /// It waits for the other players in a multiplayer game; in a game of one, it goes on at once
    /// (not ported: the wait, [#55](https://github.com/vdmkenny/openreliant/issues/55)).
    ready = 1,
    /// It follows the path, which moves on to `done` at its end.
    following = 2,
    /// The order ends, once the other players are there too in a multiplayer game (not ported:
    /// the wait, [#55](https://github.com/vdmkenny/openreliant/issues/55)).
    done = 3,
    _,
};

/// How far along the path, in ticks, the ship looks from its start for the way to face as it
/// arrives there: a simulation step, which the game holds as a float (`0x004DC424`).
const lead_ticks: f32 = gameobj.ticks_per_step;

/// Game ticks to a second, which the game holds as a float (`0x004DC440`).
const ticks_per_second: f32 = main.ticks_per_second;

/// `order_ship_follow_curve_init` (`0x00403340`): the ship in slot `index` follows the path from
/// its order's curve: its path is Ship Follow Curve's at its full speed, its length measured, where
/// its offset ship stands noted, and the order's curve begun (`beginCurve`).
pub fn init(ctx: Context, index: u16) void {
    start(ctx.world, index, .curve);
    beginCurve(ctx.world, index, entryData(ctx.world.objects, index).curve);
}

/// `order_ship_follow_curve_backwards_init` (`0x004036C0`): `init` for the path backwards, which
/// begins at the path's last curve (`lastCurve`).
pub fn backwardsInit(ctx: Context, index: u16) void {
    start(ctx.world, index, .curve_backwards);
    lastCurve(ctx.world, index, null);
}

/// What the two orders' `init`s share: the path to follow, the step, the path's length, and where
/// the offset ship stands, as the object stands (`ship_object`).
fn start(world: gameobj.World, index: u16, path: motion.Follower.Path) void {
    const all = world.objects;
    const state = &all.slots[index].state.follow;
    const data = entryData(all, index);
    state.follower = .{ .path = path, .limit = full_speed };
    state.step = .arriving;
    state.path_length = curves.pathLength(world.missionCurves(), data.curve);
    if (data.offsetShip()) |ship| if (ship < all.slots.len) {
        state.start = gameobj.vector(all.slots[ship].object.root.position);
    };
}

/// The limit a path gives `motion_follow`: the ship's top speed (`0x004DC404`).
const full_speed: f32 = 1;

/// `follow_curve_begin` (`0x004031A0`): the ship in slot `index` begins curve `curve` of its path
/// (`startCurve`), and looks for the first place a point marks on it.
fn beginCurve(world: gameobj.World, index: u16, curve: u32) void {
    startCurve(world, index, curve);
    const state = &world.objects.slots[index].state.follow;
    const marker = if (std.math.cast(u16, curve)) |at| curves.nextMarker(world.missionShips(), at, 0).at else null;
    state.next_marker = marker orelse 0;
}

/// What `follow_curve_begin` and `follow_back_curve` share: the ship in slot `index` begins curve
/// `curve` of its path, now (`mission_ticks`), for the curve's share of the order's seconds, as its
/// length is to the path's (`curves.pathShare`).
///
/// **Fix:** the game takes a curve's ticks past 65535 round from nothing; OpenReliant holds them at
/// 65535.
fn startCurve(world: gameobj.World, index: u16, curve: u32) void {
    const all = world.objects;
    const state = &all.slots[index].state.follow;
    state.curve = curve;
    state.since = world.clock.mission_ticks;
    state.ticks = curveTicks(world, state.*, entryData(all, index), curve);
}

/// Curve `curve`'s share of `data`'s seconds, in ticks, for a path of `state.path_length`.
fn curveTicks(world: gameobj.World, state: State, data: Data, curve: u32) u16 {
    const seconds: f32 = @floatFromInt(data.seconds);
    const list = world.missionCurves();
    const part = curves.pathShare(list, curveIn(list, curve), state.path_length);
    return std.math.lossyCast(u16, part * seconds * ticks_per_second);
}

/// `follow_back_curve` (`0x00403580`): the ship in slot `index` begins the curve before `before` on
/// its path backwards, or the path's last where `before` is null (`startCurve`): from the order's
/// curve, each that carries the path on from where the last ends (`curves.following`, whose
/// **Fix** ends a path that comes round on itself), up to one that ends at no ship, or the one
/// before `before`. It looks for no place a point marks.
///
/// **Fix:** the game takes a curve's end for a ship unless its whole reference, kind and all, is
/// `0x0000FFFF` (`0x0040359E`), and so walks on from a curve that ends at no ship to one that
/// starts or ends at none; OpenReliant stops at an end whose index is `dte.Reference.unset`, as
/// `curves.pathLength` does.
fn lastCurve(world: gameobj.World, index: u16, before: ?u32) void {
    const list = world.missionCurves();
    var at = entryData(world.objects, index).curve;
    if (curveIn(list, at)) |first| {
        var last: usize = first;
        var taken: usize = 1;
        while (curves.following(list, last, taken)) |following| : (taken += 1) {
            if (before) |stop| if (following == stop) break;
            last = following;
        }
        at = @intCast(last);
    }
    startCurve(world, index, at);
}

/// `order_ship_follow_curve` (`0x004033A0`), a step at a time (`steps`). Arriving, the ship flies
/// to the path's start, turned toward its point a step on. Following, it flies `motion_follow`, or
/// `motion_follow_backwards` where it was flying tail first, and once the path is over the order
/// ends.
pub fn update(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const following: motion.Motion = if (slot.motion == .backward or slot.motion == .follow_backwards) .follow_backwards else .follow;
    steps(ctx, index, 0, lead_ticks, null, following);
}

/// `order_ship_follow_curve_backwards` (`0x00403720`): `update` for the path backwards, a step at a
/// time (`steps`). Arriving, the ship flies its own motion ahead (`motion_forward`) to the curve's
/// end, turned toward its point a step back; following, it flies `motion_follow`.
pub fn backwardsUpdate(ctx: Context, index: u16) void {
    steps(ctx, index, 1, -lead_ticks, .forward, .follow);
}

/// The steps of the two orders' updates (`Step`). Arriving, the ship flies its motion `arriving`,
/// where that is given, to the point `from` of the way along its curve, turned toward the point
/// `lead` ticks on (`arriveAt`), the curve's clock held at its start; ready, it goes on; following,
/// it flies its motion `following`; done, the order ends.
fn steps(ctx: Context, index: u16, from: f32, lead: f32, arriving: ?motion.Motion, following: motion.Motion) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.follow;
    switch (state.step) {
        .arriving => {
            if (arriving) |own| slot.motion = own;
            if (arriveAt(ctx, index, from, lead)) state.step = .ready;
            state.since = ctx.world.clock.mission_ticks;
        },
        .ready => state.step = .following,
        .following => slot.motion = following,
        .done => aigeneric.end(ctx, index),
        _ => {},
    }
}

/// The ship in slot `index` flies to the point `from` of the way along its curve, turned toward the
/// point `lead` ticks on from there, arriving at the pace the path keeps between the two: the way
/// between them over the ship's cruise speed (`ai.arrive`). Whether it has arrived.
///
/// **Fix:** the game divides by nothing for a curve given no ticks, and turns the ship toward a
/// point past the curve's end; OpenReliant turns it toward the curve's other end
/// (`std.math.sign(lead)`).
fn arriveAt(ctx: Context, index: u16, from: f32, lead: f32) bool {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = slot.state.follow;
    const list = world.missionCurves();
    const curve = list[curveIn(list, state.curve) orelse return true];
    const data = entryData(world.objects, index);
    const step = if (state.ticks == 0) std.math.sign(lead) else lead / @as(f32, @floatFromInt(state.ticks));
    const here = ride(world, data, state, curves.point(curve, from));
    const next = ride(world, data, state, curves.point(curve, from + step));
    const cruise = ai.slotCruise(slot, world.view) orelse return true;
    const pace = math.distance(here, next) / cruise;
    return ai.arrive(world, index, here, math.lookAt(next - here), pace);
}

/// `order_ship_follow_curve_exit` (`0x00403550`): the ship flies its own motion again, ahead, or
/// astern where it followed the path tail first.
pub fn exit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.motion = if (slot.motion == .follow_backwards) .backward else .forward;
}

/// `order_ship_follow_curve_backwards_exit` (`0x004038C0`): the ship flies its own motion ahead
/// again.
pub fn backwardsExit(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].motion = .forward;
}

/// `follow_curve_way` (`0x00403200`), which `motion_follow` calls for Ship Follow Curve: the point
/// of the ship's curve as far along as the curve's ticks have gone, carried with the order's offset
/// ship. Past a place a point marks, the point has the ship's ShipReached, one place an update
/// (`curves.passMarker`). At the curve's end the ship it ends at has the ship's ShipReached, and
/// the curve that carries the path on begins; with none, the path is over.
///
/// **Fix:** the game moves the step on, and posts the end's ShipReached, at every move past the
/// path's end, so that a second move before the order's update, a collision's or that of a second
/// step in the same pass, leaves the order running, to fly the path again once the step comes
/// round; OpenReliant moves it on once.
///
/// Not ported: an end to a path that comes round on itself, which it flies for ever, where the
/// path's length and its walk backwards stop at as many curves as the mission has
/// (`curves.following`, [#535](https://github.com/vdmkenny/openreliant/issues/535)).
pub fn curveWay(world: gameobj.World, index: u16) motion.Way {
    const slot = &world.objects.slots[index];
    const state = &slot.state.follow;
    const list = world.missionCurves();
    const at = followed(state, list) orelse return .{ .point = gameobj.vector(slot.object.root.position) };
    const curve = list[at];
    const t = share(world, state.*);
    const point = ride(world, entryData(world.objects, index), state.*, curves.point(curve, t));
    if (curves.passMarker(world.missionShips(), at, state.nextMarker(), t)) |marker| {
        state.next_marker = marker.at orelse 0;
        if (marker.passed) |ship| events.shipReached(world, ship, index);
    }
    if (t >= 1 and state.step == .following) {
        if (curve.endShip()) |end| {
            events.shipReached(world, end, index);
            if (curves.next(list, at, end, false)) |following| {
                beginCurve(world, index, @intCast(following));
                return .{ .point = point };
            }
        }
        state.step = .done;
    }
    return .{ .point = point };
}

/// `follow_back_way` (`0x00403600`), which `motion_follow` calls for Ship Follow Curve Backwards:
/// the point of the ship's curve as far back from its end as the curve's ticks have gone, carried
/// with the order's offset ship. Past the curve's start, the curve before it begins (`lastCurve`),
/// or at the order's own curve the path is over.
///
/// **Fix:** the game moves the step on at every move past the path's start, so that a second move
/// before the order's update, a collision's or that of a second step in the same pass, leaves the
/// order running, to fly the path again once the step comes round; OpenReliant moves it on once.
/// A curve given no ticks is past its start at once (`share`).
pub fn backwardsWay(world: gameobj.World, index: u16) motion.Way {
    const slot = &world.objects.slots[index];
    const state = &slot.state.follow;
    const list = world.missionCurves();
    const at = followed(state, list) orelse return .{ .point = gameobj.vector(slot.object.root.position) };
    const data = entryData(world.objects, index);
    const t = 1 - share(world, state.*);
    const point = ride(world, data, state.*, curves.point(list[at], t));
    if ((t < 0 or state.ticks == 0) and state.step == .following) {
        if (state.curve == data.curve) {
            state.step = .done;
        } else {
            lastCurve(world, index, state.curve);
        }
    }
    return .{ .point = point };
}

/// The curve the ship follows now, by its index (`curveIn`); where the mission lacks it, the path
/// is over.
fn followed(state: *State, list: []align(1) const dte.Curve) ?u16 {
    const at = curveIn(list, state.curve);
    if (at == null) state.step = .done;
    return at;
}

/// Curve `curve` of `list`, by its index, where the list has it: not for `Data.none`.
fn curveIn(list: []align(1) const dte.Curve, curve: u32) ?u16 {
    const at = std.math.cast(u16, curve) orelse return null;
    return if (at < list.len) at else null;
}

/// How far along its curve the ship is: the mission's ticks since the curve began over the curve's
/// (`curves.along`, whose **Fix** takes a curve given no ticks to its end, and so past its start
/// going backwards, as the game's endless share does).
fn share(world: gameobj.World, state: State) f32 {
    return curves.along(@floatFromInt(world.clock.mission_ticks -% state.since), state.ticks);
}

/// `on`, a point of the path, carried with the order's offset ship where it has one: by how far the
/// ship stood from where the mission placed it as the order began (`curves.ride`).
fn ride(world: gameobj.World, data: Data, state: State, on: Vector) Vector {
    return curves.ride(world.missionShips(), data.offsetShip(), on, state.start, null);
}

/// The data of the order on top of the stack of the object in slot `index`.
fn entryData(all: *const create.Objects, index: u16) Data {
    return all.slots[index].orders[0].data.follow;
}

/// The module, whose `init` the tests' `TestPath.init` hides.
const follow = @This();

/// A mission of the ships `records` and the curves `list`, each ship's object in the slot of its
/// index: the player's far above, the follower, a Predator, 100 short of where the paths start,
/// and the rest where the paths start.
const TestPath = struct {
    game: vm.machine.testing.Game,

    /// The follower's slot.
    const follower = 1;

    /// Curve 0, from point 2 to point 3, 4000 apart along Z.
    const straight = [_]dte.Curve{dte.testing.curve(2, 3, .{ 0, 0, 0 }, .{ 0, 0, 4000 })};

    /// Curve 0, from point 2 to point 3, 1000 along Z, and curve 1, which carries the path on from
    /// point 3 to point 4, 3000 more.
    const two = [_]dte.Curve{
        dte.testing.curve(2, 3, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(3, 4, .{ 0, 0, 1000 }, .{ 0, 0, 4000 }),
    };

    /// The records of the player's ship, the follower, and `count - 2` curve points.
    fn ships(comptime count: usize) [count]dte.Ship {
        var made = dte.testing.ships(count, dte.Ship.curve_point_kind);
        for (made[0..2]) |*ship| ship.kind = @intFromEnum(gameobj.Type.predator);
        return made;
    }

    fn init(path: *TestPath, records: []const dte.Ship, list: []const dte.Curve) !void {
        try path.game.init(std.testing.allocator, &.{}, .{ .ships = records, .curves = list });
        errdefer path.game.deinit();
        for (0..records.len) |n| _ = try path.game.mission.add(.predator, switch (n) {
            0 => .{ 0, 50000, 0 },
            1 => .{ 0, 0, -100 },
            else => @splat(0),
        });
    }

    /// The mission's tick `at`, as a frame begins and through its steps.
    fn tick(path: *TestPath, at: i32) void {
        path.game.mission.clock.mission_ticks = at;
        path.game.mission.clock.frame_start = at;
    }

    /// The follower's orders and its move, at the frame's tick `at`.
    fn frame(path: *TestPath, at: i32) void {
        path.tick(at);
        aigeneric.objectOrders(path.game.orders(), follower);
        motion.moveSlot(path.game.world(), follower);
    }

    /// Gives the follower `order` along the path from curve 0 for four seconds.
    fn give(path: *TestPath, order: Order) !*create.Slot {
        const slot = path.game.mission.slot(follower);
        slot.motion = .forward;
        try std.testing.expect(try aigeneric.push(path.game.orders(), follower, order, .none));
        slot.orders[0].data = .{ .follow = .of(0, 4, null) };
        return slot;
    }

    /// The follower's state, its order `order` begun at tick 100 (`init` or `backwardsInit`), as
    /// the order's first run begins it, and following its path.
    fn following(path: *TestPath, order: Order) !*State {
        const slot = try path.give(order);
        path.tick(100);
        switch (order) {
            .ship_follow_curve => follow.init(path.game.orders(), follower),
            else => backwardsInit(path.game.orders(), follower),
        }
        slot.object.order_starting = false;
        slot.state.follow.step = .following;
        return &slot.state.follow;
    }

    /// The follower's way along its path at tick `at`.
    fn way(path: *TestPath, at: i32) motion.Way {
        path.tick(at);
        const slot = path.game.mission.slot(follower);
        return switch (slot.state.follow.follower.path) {
            .curve_backwards => backwardsWay(path.game.world(), follower),
            else => curveWay(path.game.world(), follower),
        };
    }
};

test "a ship follows the path from where it starts, for the order's seconds" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &TestPath.straight);
    defer path.game.deinit();
    const slot = try path.give(.ship_follow_curve);

    // It stands within reach of the path's start, so it is there at once, and then follows.
    path.frame(100);
    const state = &slot.state.follow;
    try std.testing.expectEqual(400, state.ticks);
    try std.testing.expectEqual(4000, state.path_length);
    try std.testing.expectEqual(Step.ready, state.step);
    path.frame(100);
    try std.testing.expectEqual(Step.following, state.step);
    path.frame(100);
    try std.testing.expectEqual(motion.Motion.follow, slot.motion.?);
    // Half way through the seconds, its way is the curve's middle, 2100 on: further than its top
    // speed takes it in a step, so it goes at its top speed, its throttle full.
    path.frame(300);
    try std.testing.expectApproxEqAbs(gameobj.testing.flight.max_speed, slot.object.velocity.z, 1e-2);
    try std.testing.expectEqual(1, slot.object.throttle);
    // At the curve's end, which carries the path on nowhere, the path is over, and so the order.
    path.frame(500);
    try std.testing.expectEqual(Step.done, state.step);
    path.frame(500);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(motion.Motion.forward, slot.motion.?);
}

test "a ship follows the path backwards, from its end" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &TestPath.straight);
    defer path.game.deinit();
    const slot = try path.give(.ship_follow_curve_backwards);

    // It stands far from the path's end, so it flies there first, its own motion ahead.
    path.frame(100);
    const state = &slot.state.follow;
    try std.testing.expectEqual(Step.arriving, state.step);
    try std.testing.expectEqual(motion.Motion.forward, slot.motion.?);
    try std.testing.expect(slot.object.throttle > 0);
    // Once there, it follows the path from its end back to its start.
    slot.object.root.next_position = .{ .x = 0, .y = 0, .z = 4000 };
    path.frame(100);
    try std.testing.expectEqual(Step.ready, state.step);
    path.frame(100);
    path.frame(100);
    try std.testing.expectEqual(motion.Motion.follow, slot.motion.?);
    try std.testing.expectApproxEqAbs(4000, path.way(100).point[2], 1e-2);
    try std.testing.expectApproxEqAbs(2000, path.way(300).point[2], 1e-2);
    // Past the start of the path's first curve, it is over.
    _ = path.way(501);
    try std.testing.expectEqual(Step.done, state.step);
}

test "the path runs on the mission's ticks through a frame's steps" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &TestPath.straight);
    defer path.game.deinit();
    _ = try path.following(.ship_follow_curve);

    // The frame began at 100, but the steps since have run the mission on to 300: half way.
    path.game.mission.clock.mission_ticks = 300;
    try std.testing.expectApproxEqAbs(2000, curveWay(path.game.world(), TestPath.follower).point[2], 1e-2);
}

test "a second move past the path's end ends the order once" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &TestPath.straight);
    defer path.game.deinit();

    // Forward, two moves past the end before the order's update leave it done, and the update
    // ends the order.
    const state = try path.following(.ship_follow_curve);
    _ = path.way(500);
    _ = path.way(500);
    try std.testing.expectEqual(Step.done, state.step);
    aigeneric.objectOrders(path.game.orders(), TestPath.follower);
    const slot = path.game.mission.slot(TestPath.follower);
    try std.testing.expectEqual(0, slot.object.order_count);

    // Backwards likewise, past the start of the order's own curve.
    const back = try path.following(.ship_follow_curve_backwards);
    _ = path.way(501);
    _ = path.way(501);
    try std.testing.expectEqual(Step.done, back.step);
    aigeneric.objectOrders(path.game.orders(), TestPath.follower);
    try std.testing.expectEqual(0, slot.object.order_count);
}

test "the path runs on through the curve that carries it" {
    var path: TestPath = undefined;
    const records = TestPath.ships(5);
    try path.init(&records, &TestPath.two);
    defer path.game.deinit();

    // The first curve takes a quarter of the path, and so of its 400 ticks.
    const state = try path.following(.ship_follow_curve);
    try std.testing.expectApproxEqAbs(4000, state.path_length, 1e-1);
    try std.testing.expectApproxEqAbs(100, @as(f32, @floatFromInt(state.ticks)), 1);
    // At its end, the second begins, now, with the rest of the ticks.
    const end = 100 + @as(i32, state.ticks);
    _ = path.way(end);
    try std.testing.expectEqual(1, state.curve);
    try std.testing.expectEqual(end, state.since);
    try std.testing.expectApproxEqAbs(300, @as(f32, @floatFromInt(state.ticks)), 1);
    try std.testing.expectEqual(Step.following, state.step);
}

test "backwards, the path begins at its last curve and steps back to the one before" {
    var path: TestPath = undefined;
    const records = TestPath.ships(5);
    try path.init(&records, &TestPath.two);
    defer path.game.deinit();

    const state = try path.following(.ship_follow_curve_backwards);
    try std.testing.expectEqual(1, state.curve);
    try std.testing.expectApproxEqAbs(300, @as(f32, @floatFromInt(state.ticks)), 1);
    // Past its start, the curve before it begins, now.
    _ = path.way(100 + @as(i32, state.ticks) + 1);
    try std.testing.expectEqual(0, state.curve);
    try std.testing.expectApproxEqAbs(100, @as(f32, @floatFromInt(state.ticks)), 1);
    try std.testing.expectEqual(Step.following, state.step);
}

test "passing a place a point marks looks for the next" {
    var path: TestPath = undefined;
    var records = TestPath.ships(5);
    records[4].kind = dte.Ship.point_kind;
    records[4].marker_curve = 0;
    records[4].marker_at = 0.5;
    try path.init(&records, &TestPath.straight);
    defer path.game.deinit();

    const state = try path.following(.ship_follow_curve);
    try std.testing.expectEqual(0.5, state.next_marker);
    // Short of it, it waits; past it, there is none further.
    _ = path.way(250);
    try std.testing.expectEqual(0.5, state.next_marker);
    _ = path.way(400);
    try std.testing.expectEqual(0, state.next_marker);
}

test "the path stands off as far as its ship stood as the order began" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &TestPath.straight);
    defer path.game.deinit();
    const slot = try path.give(.ship_follow_curve);
    // The player's ship carries it, placed at the origin and standing 50000 above.
    slot.orders[0].data.follow = .of(0, 4, 0);
    path.tick(100);
    init(path.game.orders(), TestPath.follower);
    slot.state.follow.step = .following;
    try std.testing.expectEqual([3]f32{ 0, 50000, 0 }, slot.state.follow.start);
    // Where it goes since does not move the path.
    path.game.mission.slot(0).object.root.position = .{ .x = 0, .y = 0, .z = 0 };
    const at = path.way(300).point;
    try std.testing.expectApproxEqAbs(50000, at[1], 1e-2);
    try std.testing.expectApproxEqAbs(2000, at[2], 1e-2);
}

test "a path of no length gives its curve all the order's ticks" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &.{dte.testing.curve(2, 3, .{ 0, 0, 0 }, .{ 0, 0, 0 })});
    defer path.game.deinit();
    const state = try path.following(.ship_follow_curve);
    try std.testing.expectEqual(0, state.path_length);
    try std.testing.expectEqual(400, state.ticks);
}

test "a curve's ticks hold at 65535" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &TestPath.straight);
    defer path.game.deinit();
    const slot = try path.give(.ship_follow_curve);
    slot.orders[0].data.follow.seconds = 1000;
    init(path.game.orders(), TestPath.follower);
    try std.testing.expectEqual(std.math.maxInt(u16), slot.state.follow.ticks);
}

test "a path that comes round on itself is walked no further than its curves" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &.{
        dte.testing.curve(2, 3, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(3, 2, .{ 0, 0, 1000 }, .{ 0, 0, 0 }),
    });
    defer path.game.deinit();
    // Backwards, the walk to the last curve takes each once, and ends at the second.
    const state = try path.following(.ship_follow_curve_backwards);
    try std.testing.expectEqual(1, state.curve);
    // Past its start, the one before it, the order's own, ends the path.
    _ = path.way(100 + @as(i32, state.ticks) + 1);
    try std.testing.expectEqual(0, state.curve);
    _ = path.way(100 + @as(i32, state.ticks) * 2 + 2);
    try std.testing.expectEqual(Step.done, state.step);
}

test "the backward walk stops at a curve that ends at no ship" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    // Curve 0 ends at no ship, its reference's kind and its last byte set, and curve 1 starts at
    // none.
    try path.init(&records, &.{
        dte.testing.curve(2, dte.Reference.unset, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(dte.Reference.unset, 3, .{ 0, 0, 1000 }, .{ 0, 0, 2000 }),
    });
    defer path.game.deinit();
    const state = try path.following(.ship_follow_curve_backwards);
    try std.testing.expectEqual(0, state.curve);
}

test "a curve given no ticks ends the path, forward and backwards" {
    var path: TestPath = undefined;
    const records = TestPath.ships(4);
    try path.init(&records, &TestPath.straight);
    defer path.game.deinit();

    // Forward, it is at its end at once.
    const state = try path.following(.ship_follow_curve);
    state.ticks = 0;
    _ = path.way(100);
    try std.testing.expectEqual(Step.done, state.step);
    aigeneric.objectOrders(path.game.orders(), TestPath.follower);

    // Backwards, it is past its start at once, and the order ends.
    const slot = try path.give(.ship_follow_curve_backwards);
    slot.orders[0].data.follow.seconds = 0;
    path.frame(100);
    slot.object.root.next_position = .{ .x = 0, .y = 0, .z = 4000 };
    path.frame(100);
    try std.testing.expectEqual(Step.ready, slot.state.follow.step);
    try std.testing.expectEqual(0, slot.state.follow.ticks);
    path.frame(100);
    try std.testing.expectEqual(Step.following, slot.state.follow.step);
    path.frame(100);
    try std.testing.expectEqual(Step.done, slot.state.follow.step);
    path.frame(100);
    try std.testing.expectEqual(0, slot.object.order_count);
}

test Data {
    // A null takes the record's none, and comes back as none; an index comes back as itself.
    const unset: Data = .of(null, 4, null);
    try std.testing.expectEqual(Data{ .curve = Data.none, .seconds = 4, .offset = Data.none }, unset);
    try std.testing.expectEqual(null, unset.offsetShip());
    const carried: Data = .of(2, 4, 7);
    try std.testing.expectEqual(Data{ .curve = 2, .seconds = 4, .offset = 7 }, carried);
    try std.testing.expectEqual(7, carried.offsetShip());
}
