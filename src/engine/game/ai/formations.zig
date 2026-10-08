//! Formation Regroup and Patrol Route, orders 14 and 15, which fly a flight group in the formation
//! its ships' points place them in (`dte.Formation`, `dte.FormationPoint`). Formation Regroup
//! gathers the group at its places about its middle, and Patrol Route flies it round the waypoints
//! of a route, the ships of a formation keeping their places about their leader. In each, the
//! formation's leader moves the whole group on, once every ship is ready. Missions give Formation
//! Regroup with `SetAI` and Patrol Route with `SetPatrolRoute`; no shipped mission gives either.
//! [docs/engine/orders.md](../../../../docs/engine/orders.md#formations) describes them.
//!
//! **Unverified:** the source file. The code lies after `Ai.cpp`'s known code and before
//! `aidefend.cpp`'s, with Ship Follow Curve's ([`follow.zig`](follow.zig)), and does the orders'
//! work, as `Ai.cpp`'s neighbours do.
//!
//! **Fix:** the leader reads and writes the order state of each ship of its group, whatever order
//! the ship follows, so that a ship given another order since has that order's state taken for the
//! formation's and changed. OpenReliant counts and moves only the ships that follow the leader's
//! order, and a ship whose leader follows another takes its pace as nothing.

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../../../formats/dte.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const Context = aigeneric.Context;
const bind = @import("../mission/bind.zig");
const create = @import("../create.zig");
const curves = @import("../executor/curves.zig");
const gameobj = @import("../gameobj.zig");
const GameObject = gameobj.GameObject;
const objects = @import("../objects.zig");
const Order = @import("orders.zig").Order;
const vm = @import("../../vm.zig");

/// What a state holds for no ship, where the game holds a null address.
pub const no_ship: u32 = std.math.maxInt(u32);

// --- Formation Regroup ----------------------------------------------------------------------

/// What Formation Regroup keeps in `order_state`.
///
/// From `+0x64` the curve routines keep how the ship follows its curve (`followCurve`): the curve's
/// address, the ship's, the ticks a timed way along it takes, whether it has come to the curve's
/// start (`+0x6E`), whether it goes a step at a time, the curve's length, the step it flies toward
/// (`+0x74`), the curve's ticks, the place and the ship a path rides with, and its next marker
/// (`+0x94`). These orders always go a step at a time, with nothing to ride, and the steps read
/// none of the rest. **Fix:** the marker lies past the 0x90 bytes the game allocates for the state,
/// so the game writes past them; OpenReliant keeps no marker (`layCurve`).
pub const RegroupState = extern struct {
    /// Where the ship meets its group: its point's place about the group's middle, `meet_back` back
    /// along Z.
    meet: [3]f32,
    /// Its point's place about the group's middle, which it turns to face once the group has met.
    place: [3]f32,
    /// The formation's leader (`leaderOf`), by its index among the mission's ships, or `no_ship`;
    /// the game holds its record's address.
    leader: u32,
    step: RegroupStep,
    /// Whether it is ready for the group's next step.
    ready: bool,
    /// Whether it flies straight to its meeting point, rather than along its curve.
    direct: bool,
    /// How many of the leader's updates in a row have found the group ready, up to `ready_updates`.
    ready_count: u8,
    /// The curve it flies along to its meeting point (`layCurve`).
    curve: dte.Curve,
    _unknown_64: [10]u8,
    /// Whether it has come to its curve's start.
    started: bool,
    _unknown_6f: [5]u8,
    /// The point of its curve it flies toward: this many `curves.steps`ths of the way along.
    along: u16,
    _unknown_76: [0x90 - 0x76]u8,

    comptime {
        assert(@offsetOf(RegroupState, "place") == 0x0C);
        assert(@offsetOf(RegroupState, "leader") == 0x18);
        assert(@offsetOf(RegroupState, "step") == 0x1C);
        assert(@offsetOf(RegroupState, "ready") == 0x1D);
        assert(@offsetOf(RegroupState, "direct") == 0x1E);
        assert(@offsetOf(RegroupState, "ready_count") == 0x1F);
        assert(@offsetOf(RegroupState, "curve") == 0x20);
        assert(@offsetOf(RegroupState, "started") == 0x64 + 0x0A);
        assert(@offsetOf(RegroupState, "along") == 0x64 + 0x10);
        assert(@sizeOf(RegroupState) == 0x90);
    }
};

/// Formation Regroup's steps, which the leader moves the group through together (`regroupSync`).
pub const RegroupStep = enum(u8) {
    /// Each ship turns to face its meeting point.
    aiming = 0,
    /// Each flies there.
    flying = 1,
    /// Each turns to face its place.
    facing = 2,
    /// The order ends.
    done = 3,
    _,
};

/// How far back along Z from its place the ship meets its group (`0x004DC43C`).
const meet_back: f32 = 10000;

/// How many of the leader's updates in a row the group must be ready for before it goes on to the
/// next step (`0x00403E85`).
const ready_updates = 15;

/// The limit the AI's steering turns a regrouping ship by (`0x00403D3E`, `0x00403D61`).
const regroup_limit: f32 = 0.75;

/// How far a ship's meeting point lies for it to fly there along a curve: no nearer than the first
/// and no farther than the second (`0x004DC444`, `0x004DC464`). Nearer or farther, it flies
/// straight there.
const curve_least: f32 = 20000;
const curve_most: f32 = 400000;

/// The pace a ship sets off at (`setPace`): for its meeting point straight, along its curve until
/// it comes to the curve's start, and along a patrol route (`0x00403EE2`, `0x00404C00`,
/// `0x00403906`).
const set_off_pace: f32 = 0.3;

/// The limit the AI's steering turns a ship by as it flies to a point: its curve's start, or alone
/// on a patrol route, its waypoint (`0x00404C3D`, `0x00403983`).
const steer_limit: f32 = 0.5;

/// `order_formation_regroup_init` (`0x00403C40`): the ship in slot `index` gathers with its flight
/// group. Its meeting point is its formation point's place about the middle of where the group's
/// ships stood (`groupMiddle`), `meet_back` back along Z, which it turns to face; the formation's
/// leader moves the group on. Its throttle goes to nothing.
///
/// A ship in no formation, or in no flight group or an empty one, takes none of that: its state
/// stays empty, so that it turns toward the world's origin, its throttle as it was. **Fix:** for a
/// ship in a formation but in no flight group, the game follows a null pointer; OpenReliant leaves
/// its state empty as well.
pub fn regroupInit(ctx: Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = &slot.state.regroup;
    state.leader = no_ship;
    const bound = world.mission orelse return;
    const ship = bound.ship(index) orelse return;
    const point = ship.formationPoint() orelse return;
    const offset = pointOffset(bound, point) orelse return;
    const group = bound.flightGroup(ship.flight_group) orelse return;
    var middle = groupMiddle(bound, group.*) orelse return;
    middle[2] -= meet_back;
    const meet = middle + offset;
    state.meet = meet;
    state.place = meet;
    state.place[2] += meet_back;
    state.step = .aiming;
    state.ready = false;
    state.ready_count = 0;
    state.leader = leaderOf(bound, ship.flight_group, point) orelse no_ship;
    setPace(slot, 0, 0);
}

/// `order_formation_regroup` (`0x00403D00`): the ship in slot `index` regroups, its leader first
/// moving the group on (`regroupSync`), a step at a time (`RegroupStep`). Aiming, it turns to face
/// its meeting point, and is ready once that lies ahead (`face`). Flying, it goes there straight
/// (`steerTo`) or along its curve (`followCurve`), and is ready once within two of its radii of it,
/// its throttle then nothing. Facing, it turns to face its place, and is ready once that lies
/// ahead. Done, it lets go of the turns (`object_hold_turns`, `0x00403FB0`) and the order ends.
pub fn regroup(ctx: Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = &slot.state.regroup;
    if (state.leader == index) regroupSync(world, index);
    switch (state.step) {
        .aiming => state.ready = face(world, index, state.meet, .{ .steer = regroup_limit }),
        .flying => if (!state.ready) {
            const there = if (state.direct) steerTo(world, index, state.meet, regroup_limit) else along: {
                if (!followCurve(ctx, index)) return;
                break :along within(&slot.object, state.meet, 0, null);
            };
            if (there) {
                setPace(slot, 0, 0);
                state.ready = true;
            }
        },
        .facing => state.ready = face(world, index, state.place, .{ .steer = regroup_limit }),
        .done => {
            slot.object.holdTurns();
            aigeneric.end(ctx, index);
        },
        _ => {},
    }
}

/// `regroup_sync` (`0x00403DE0`): the formation's leader, the ship in slot `leader`, moves its
/// flight group on. While every ship of the group still in the mission is ready, each counts the
/// leader's updates; at `ready_updates`, each is ready no more and goes on to its next step. One
/// setting off for its meeting point flies there along a curve (`layCurve`) where the point lies
/// from `curve_least` to `curve_most` away, and otherwise straight, at `set_off_pace`. While any is
/// not ready, the counts start again.
fn regroupSync(world: gameobj.World, leader: u16) void {
    const bound = world.mission orelse return;
    const ship = bound.ship(leader) orelse return;
    const group = bound.flightGroup(ship.flight_group) orelse return;
    const members = bound.groupShips(group.*);
    var ready = true;
    for (members) |member| {
        const record = bound.ship(member) orelse continue;
        if (record.flags.destroyed) continue;
        const state = stateOf(world, member, .formation_regroup) orelse continue;
        ready = ready and state.regroup.ready;
    }
    for (members) |member| {
        const state = &(stateOf(world, member, .formation_regroup) orelse continue).regroup;
        if (!ready) {
            state.ready_count = 0;
            continue;
        }
        state.ready_count +%= 1;
        if (state.ready_count < ready_updates) continue;
        state.ready = false;
        state.ready_count = 0;
        if (state.step == .aiming) {
            const slot = &world.objects.slots[member];
            const from = position(&slot.object);
            const way = math.distance(state.meet, from);
            if (way >= curve_least and way <= curve_most) {
                layCurve(state, from);
                state.direct = false;
            } else {
                setPace(slot, set_off_pace, 0);
                state.direct = true;
            }
        }
        state.step = @fromBackingInt(@backingInt(state.step) +% 1);
    }
}

/// `regroup_lay_curve` (`0x00403F20`), with `curve_path_init` (`0x00404A90`) and `curve_path_begin`
/// (`0x00404B50`) as it calls them: the curve a regrouping ship flies along to its meeting point
/// from `from`, where it stands (`curves.between`), its leaving tangent half the way across, turned
/// a right angle about Y, so that it swings out to the side; and the ship to follow it a step at a
/// time from its first, not yet at its start.
///
/// The game measures the curve and gives the way 30 seconds, which only a timed way along it reads,
/// and looks for the points that mark places on it by its address's place among the mission's
/// curves (`curve_next_marker`), which it is not one of. **Fix:** OpenReliant takes it that none
/// does, where the game takes the points of a curve whose index that address happens to give.
fn layCurve(state: *RegroupState, from: Vector) void {
    var curve = curves.between(from, state.meet);
    const across = (@as(Vector, curve.to) - @as(Vector, curve.from)) * @as(Vector, @splat(0.5));
    curve.leaving = math.transform(math.rotation(.y, std.math.pi / 2.0), across);
    state.curve = curve;
    state.started = false;
    state.along = 1;
}

/// `curve_path_follow` (`0x00404BE0`), a step at a time as Formation Regroup takes it: the ship in
/// slot `index` follows its curve. Until it comes to the curve's start, it flies there at
/// `set_off_pace` (`steerTo`). Then it flies toward the point of its step, turned straight at it
/// each update, and toward the next once within two of its radii of it (`within`). Past the curve's
/// end, which names no ship to go on from, it ends the order (`regroup_curve_end`, `0x00404A60`):
/// its throttle and its turns go to nothing. Whether the order goes on.
///
/// **Improvement:** the game takes each step's point from its table of the curves' weights
/// (`curve_point_stepped`); OpenReliant computes it, as `curves.length` does.
///
/// **Fix:** where the order ends, the game goes on to check the meeting point in the state of the
/// order below; OpenReliant stops there.
fn followCurve(ctx: Context, index: u16) bool {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = &slot.state.regroup;
    if (!state.started) {
        setPace(slot, set_off_pace, 0);
        state.started = steerTo(world, index, curves.point(state.curve, 0), steer_limit);
        if (!state.started) return true;
    }
    const t = @as(f32, @floatFromInt(state.along)) / curves.steps;
    const point = curves.point(state.curve, t);
    if (within(&slot.object, point, 0, null)) state.along +%= 1;
    objects.setOrientation(&slot.object, &slot.drawn, math.lookAt(point - position(&slot.object)));
    if (t > 1) {
        setPace(slot, 0, 0);
        slot.object.holdTurns();
        aigeneric.end(ctx, index);
        return false;
    }
    return true;
}

/// `flight_group_middle` (`0x004522F0`): the middle of the box round where the ships of `group`
/// stood at the mission's last sync (`dte.Ship.runtime_position`; `box_include`, `0x004523B0`;
/// `vec3_halfway`, `0x00452430`); null where the group has no ships.
fn groupMiddle(bound: *const bind.Mission, group: dte.FlightGroup) ?Vector {
    const members = bound.groupShips(group);
    if (members.len == 0) return null;
    var least: Vector = (bound.ship(members[0]) orelse return null).runtime_position;
    var most = least;
    for (members) |member| {
        const at: Vector = (bound.ship(member) orelse continue).runtime_position;
        least = @min(least, at);
        most = @max(most, at);
    }
    return math.lerp(least, most, 0.5);
}

// --- Patrol Route ---------------------------------------------------------------------------

/// What Patrol Route keeps in `order_state`.
pub const PatrolState = extern struct {
    /// The leader's mark: the point ahead of it that it turns toward, `ahead_radii` of its radii
    /// out, at its waypoint's height.
    mark: [3]f32,
    /// Where the leader stood at the mission's last sync (`dte.Ship.runtime_position`).
    leader_at: [3]f32,
    /// The point it flies to at its waypoint: the waypoint itself, or alone, its place in the
    /// group's line through it (`setOff`).
    target: [3]f32,
    /// Its place in the formation about where the leader stands.
    place: [3]f32,
    /// Its place `ahead_radii` of the leader's radii on ahead of the leader, which it turns toward.
    ahead: [3]f32,
    /// The way from the leader to its mark, kept from the last time the leader took it.
    reach: [3]f32,
    /// The waypoint it flies to, by its index among the mission's waypoints
    /// (`bind.Mission.waypoints`), or `no_waypoint`; the game holds its entry's address.
    waypoint: u32,
    /// The formation's leader (`leaderOf`), by its index among the mission's ships, or `no_ship`;
    /// the game holds its record's address.
    leader: u32,
    /// The game's address of the leader's state, which OpenReliant reaches through the leader's
    /// slot (`leaderPace`).
    _leader_state: u32,
    /// Its point in the formation, or `dte.Ship.no_formation_point`.
    formation_point: u16,
    mode: PatrolMode,
    /// Whether the group's ships stand alike near their places, their distances from them within
    /// `close_spread` of each other, which nothing reads.
    close: bool,
    /// How far it stood from its place ahead as it set off, less two of its radii, which nothing
    /// reads.
    start_off: f32,
    /// The leader's pace (`setPace`), which the others fly by.
    pace: f32,
    /// The size of its formation (`formationSize`); 0 alone.
    size: f32,
    /// Whether it stands in its place, turned to it. The leader always does.
    in_place: bool,
    /// How many times the leader is to aim at its waypoint again: the leader moving the group on
    /// sets it to 1 for every ship, and only the leader's own update reads it.
    aim: u8,
    /// Whether the leader has come to its waypoint, within half its formation's size of it.
    arrived: bool,
    _unknown_67: [0x90 - 0x67]u8,

    /// What `waypoint` holds for none.
    pub const no_waypoint: u32 = std.math.maxInt(u32);

    /// Its point in the formation, where it has one.
    pub fn formationPoint(state: PatrolState) ?u16 {
        return if (state.formation_point == dte.Ship.no_formation_point) null else state.formation_point;
    }

    comptime {
        assert(@offsetOf(PatrolState, "leader_at") == 0x0C);
        assert(@offsetOf(PatrolState, "target") == 0x18);
        assert(@offsetOf(PatrolState, "place") == 0x24);
        assert(@offsetOf(PatrolState, "ahead") == 0x30);
        assert(@offsetOf(PatrolState, "reach") == 0x3C);
        assert(@offsetOf(PatrolState, "waypoint") == 0x48);
        assert(@offsetOf(PatrolState, "leader") == 0x4C);
        assert(@offsetOf(PatrolState, "formation_point") == 0x54);
        assert(@offsetOf(PatrolState, "mode") == 0x56);
        assert(@offsetOf(PatrolState, "close") == 0x57);
        assert(@offsetOf(PatrolState, "start_off") == 0x58);
        assert(@offsetOf(PatrolState, "pace") == 0x5C);
        assert(@offsetOf(PatrolState, "size") == 0x60);
        assert(@offsetOf(PatrolState, "in_place") == 0x64);
        assert(@offsetOf(PatrolState, "aim") == 0x65);
        assert(@offsetOf(PatrolState, "arrived") == 0x66);
        assert(@sizeOf(PatrolState) == 0x90);
    }
};

/// How a ship flies a patrol route.
pub const PatrolMode = enum(u8) {
    /// It turns to face its place ahead, and the leader then has it fly in formation. Nothing sets
    /// it.
    forming = 0,
    /// It keeps its place about the formation's leader, who flies to each waypoint in turn.
    formation = 1,
    /// It flies to each waypoint by itself.
    alone = 2,
    _,
};

/// How many of the leader's radii ahead of it its mark and the places ahead lie (`0x004DC45C`).
const ahead_radii: f32 = 8;

/// The pace a ship starts each waypoint at, and the leader's pace where it must turn further than
/// `narrow_turn` toward its waypoint (`0x004041FD`, `0x004DC450`).
const start_pace: f32 = 0.15;

/// The leader's pace where it turns less than `narrow_turn` toward its waypoint, and less than
/// `wide_turn` (`0x004DC408`, `0x004DC3D4`).
const straight_pace: f32 = 0.5;
const turning_pace: f32 = 0.25;

/// The turns, in radians, by which the leader picks its pace (`0x004DC454`, `0x004DC458`).
///
/// **Improvement:** the game holds them rounded to 0.20943951 and 1.0471976.
const narrow_turn: f32 = std.math.pi / 15.0;
const wide_turn: f32 = std.math.pi / 3.0;

/// How much more than the leader's pace the others fly at (`0x004DC420`).
const catch_up: f32 = 0.1;

/// The pace, in the leader's paces, a ship flies at while its place lies ahead of it, and how much
/// less than the leader's while its place lies behind it (`0x004DC3D8`, `0x00403AB9`).
const behind_pace: f32 = 3;
const ahead_less: f32 = -0.95;

/// Within how many of its radii of its place a ship turned to it slides toward it, and by what
/// share of the way each update (`0x004DC460`, `0x00403A49`).
const slide_radii: f32 = 3.2;
const slide_share: f32 = 0.005;

/// How near each other the group's ships' distances from their places must lie for the group to
/// count as close (`0x004DC46C`).
const close_spread: f32 = 5000;

/// `order_patrol_route_init` (`0x004038E0`): the ship in slot `index` flies its route, from the
/// waypoint its order's target names: in its formation where it has a point in one, and otherwise
/// alone, at `set_off_pace` (`setOff`).
pub fn patrolInit(ctx: Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = &slot.state.patrol;
    state.leader = no_ship;
    state.waypoint = PatrolState.no_waypoint;
    setPace(slot, set_off_pace, 0);
    const bound = world.mission orelse return;
    state.formation_point = if (bound.ship(index)) |ship| ship.formation_point else dte.Ship.no_formation_point;
    const waypoint = std.math.cast(u16, slot.orders[0].target.index) orelse return;
    if (waypoint < bound.waypoints.len) setOff(world, index, waypoint);
    state.close = false;
}

/// `order_patrol_route` (`0x00403940`): the ship in slot `index` flies its route, its leader first
/// moving the formation on (`patrolSync`). Alone, it flies to its waypoint's point (`steerTo`) and
/// then sets off for the next. In formation, it keeps its place (`keepPlace`).
///
/// **Fix:** the game reads the waypoint the order's target names wherever it lies, past the
/// mission's waypoints or before them; OpenReliant ends the order.
pub fn patrol(ctx: Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = &slot.state.patrol;
    const bound = world.mission orelse return aigeneric.end(ctx, index);
    const waypoint = std.math.cast(u16, state.waypoint) orelse return aigeneric.end(ctx, index);
    if (state.leader == index) patrolSync(world, index);
    switch (state.mode) {
        .forming => if (face(world, index, state.ahead, .{ .level = null })) {
            state.in_place = true;
        },
        .alone => if (steerTo(world, index, state.target, steer_limit)) {
            setOff(world, index, nextWaypoint(bound.waypoints, waypoint));
        },
        .formation => keepPlace(world, index),
        _ => {},
    }
}

/// Patrol Route in formation (`0x004039B6`): the ship in slot `index` keeps its place about its
/// leader (`places`), turning on the level toward its place ahead. Turned to it and within
/// `slide_radii` of its radii of its place, it slides `slide_share` of the way there. Until it is
/// in place, it flies at `behind_pace` of the leader's pace while its place lies ahead of it, and
/// at `ahead_less` less of it while its place lies behind it; within two of its radii of its place
/// and turned to it, it is in place, and flies at the leader's pace and `catch_up` more.
///
/// The leader flies at its pace, always in place, and has come to its waypoint once within half its
/// formation's size of it. It turns on the level toward its mark. Where it is to aim at its
/// waypoint again (`PatrolState.aim`), it turns toward the waypoint instead, and takes its mark
/// `ahead_radii` of its radii along its nose, turned by its yaw input, at the waypoint's height,
/// and its pace by how far it must turn: `straight_pace` under `narrow_turn`, `turning_pace` under
/// `wide_turn`, and otherwise `start_pace`.
///
/// **Fix:** the game slides the ship by placing it (`object_place`), which drops the move its step
/// has left to make, so that a ship sliding toward its place moves by the slide alone and hangs
/// back where the slide's pull meets the leader's pace: at a frame rate of 60, short of its place
/// at the first waypoint's pace, so that the formation never moves on. OpenReliant slides the ship
/// and the move it has left together (`objects.shift`), so that it flies on into its place.
fn keepPlace(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const object = &slot.object;
    const state = &slot.state.patrol;
    places(world, index, false);
    var angle: f32 = 0;
    if (state.leader != index) {
        const pace = leaderPace(world, state.*);
        setPace(slot, pace * catch_up + pace, 0);
        const turned = face(world, index, state.ahead, .{ .level = &angle });
        var off: f32 = 0;
        const there = within(object, state.place, 0, &off);
        if (turned and !there and off <= object.radius * slide_radii) {
            const by = (@as(Vector, state.place) - position(object)) * @as(Vector, @splat(slide_share));
            objects.shift(object, &slot.drawn, by);
        }
        if (state.in_place) return;
        if (!there) {
            if (inFront(object, state.place)) setPace(slot, pace * behind_pace, 0) else setPace(slot, pace, ahead_less);
        } else if (turned) {
            state.in_place = true;
        }
        return;
    }
    setPace(slot, state.pace, 0);
    state.in_place = true;
    if (within(object, state.target, state.size * 0.5, null)) state.arrived = true;
    _ = face(world, index, state.mark, .{ .level = &angle });
    if (state.aim == 0) return;
    state.aim -= 1;
    _ = face(world, index, state.target, .{ .level = &angle });
    const nose = math.transform(math.rotation(.y, object.yaw_input), math.forward(object.root.orientation));
    state.reach = nose * @as(Vector, @splat(object.radius * ahead_radii));
    state.mark = position(object) + @as(Vector, state.reach);
    state.mark[1] = state.target[1];
    state.pace = if (angle < wide_turn) (if (angle < narrow_turn) straight_pace else turning_pace) else start_pace;
}

/// `patrol_sync` (`0x00404330`): the formation's leader, the ship in slot `leader`, moves its
/// flight group on. Each ship of the group still in the mission takes where the leader stood at the
/// last sync, and the group is close where their distances from their places ahead, less two of
/// their radii, lie within `close_spread` of each other. Once every one is in place, each is in
/// place no more: where the leader has come to its waypoint, each sets off for the next (`setOff`),
/// and otherwise the leader aims at its waypoint again.
///
/// Each ship reads whether the leader has come to its waypoint in turn, and the leader setting off
/// clears it, so that the ships after the leader in the group's list aim again instead, as in the
/// game.
///
/// **Fix:** the game takes the spread from the group's first ship, and where that ship is no longer
/// in the mission, from whatever its stack holds; OpenReliant takes it from the first it counts.
fn patrolSync(world: gameobj.World, leader: u16) void {
    const bound = world.mission orelse return;
    const ship = bound.ship(leader) orelse return;
    const group = bound.flightGroup(ship.flight_group) orelse return;
    const members = bound.groupShips(group.*);
    var all_in_place = true;
    var nearest: ?f32 = null;
    var farthest: f32 = 0;
    for (members) |member| {
        const record = bound.ship(member) orelse continue;
        if (record.flags.destroyed) continue;
        const state = &(stateOf(world, member, .patrol_route) orelse continue).patrol;
        const object = &world.objects.slots[member].object;
        state.leader_at = ship.runtime_position;
        const off = math.distance(position(object), state.ahead) - 2 * object.radius;
        if (nearest) |least| {
            nearest = @min(least, off);
            farthest = @max(farthest, off);
        } else {
            nearest = off;
            farthest = off;
        }
        all_in_place = all_in_place and state.in_place;
    }
    const close = farthest - (nearest orelse farthest) < close_spread;
    for (members) |member| {
        const state = &(stateOf(world, member, .patrol_route) orelse continue).patrol;
        state.close = close;
        if (!all_in_place) continue;
        switch (state.mode) {
            .forming => {
                state.in_place = false;
                state.mode = .formation;
            },
            .formation => {
                state.in_place = false;
                const arrived = if (stateOf(world, state.leader, .patrol_route)) |leads| leads.patrol.arrived else false;
                if (arrived) {
                    const waypoint = std.math.cast(u16, state.waypoint) orelse continue;
                    setOff(world, member, nextWaypoint(bound.waypoints, waypoint));
                } else {
                    state.aim = 1;
                }
            },
            else => {},
        }
    }
}

/// `patrol_set_off` (`0x00404040`): the ship in slot `index` sets off for waypoint `waypoint` of
/// the mission's (`bind.Mission.waypoints`), at `start_pace`: in its formation where it can join it
/// (`joinFormation`), and otherwise alone, to its place in a line of its flight group's ships
/// through the waypoint, along the way from the next waypoint: each ship three widths of the
/// group's widest apart, the group's first nearest the next waypoint.
fn setOff(world: gameobj.World, index: u16, waypoint: u16) void {
    const bound = world.mission orelse return;
    const state = &world.objects.slots[index].state.patrol;
    const at = waypointAt(world, bound.waypoints[waypoint]);
    state.target = at;
    const group = if (bound.ship(index)) |record| record.flight_group else dte.Ship.no_flight_group;
    if (!joinFormation(world, index, group)) {
        if (bound.flightGroup(group)) |record| {
            const members = bound.groupShips(record.*);
            const count: f32 = @floatFromInt(record.ship_count);
            const width = 2 * widest(world, members);
            const span = (2 * width + width) * count;
            const next = waypointAt(world, bound.waypoints[nextWaypoint(bound.waypoints, waypoint)]);
            const along = math.normalize(at - next) * @as(Vector, @splat(span));
            const front = along / @as(Vector, @splat(-2));
            const back = along / @as(Vector, @splat(2));
            const place: f32 = @floatFromInt(std.mem.indexOfScalar(u16, members, index) orelse std.math.maxInt(u8));
            state.target = at + math.lerp(front, back, place / count);
        }
        state.mode = .alone;
        state.size = 0;
    }
    state.arrived = false;
    state.waypoint = waypoint;
    state.pace = start_pace;
}

/// What `setOff` does for a ship with a point in a formation (`0x00404082`): where a ship of its
/// flight group `group` stands at the formation's lead (`leaderOf`), the ship flies in formation
/// about it, stopped, its places about the leader taken anew (`places`), and its formation's size
/// (`formationSize`). Whether it does.
///
/// **Fix:** where no ship of its group stands at the formation's lead, the game follows a null
/// pointer; OpenReliant has the ship fly the route alone.
fn joinFormation(world: gameobj.World, index: u16, group: u8) bool {
    const bound = world.mission orelse return false;
    const slot = &world.objects.slots[index];
    const state = &slot.state.patrol;
    const point = state.formationPoint() orelse return false;
    state.leader = leaderOf(bound, group, point) orelse return false;
    state.mode = .formation;
    slot.object.throttle = 0;
    places(world, index, true);
    state.in_place = false;
    state.aim = 0;
    state.start_off = math.distance(position(&slot.object), state.ahead) - 2 * slot.object.radius;
    state.size = formationSize(bound, point);
    return true;
}

/// `patrol_places` (`0x00404620`): the places of the ship in slot `index` about its leader, as the
/// leader stands and is turned: where the leader stood at the last sync, and its place, its
/// formation point's place turned as the leader is, and that place `ahead_radii` of the leader's
/// radii on along the leader's nose. The leader's own place is where it stands, and its mark lies
/// the way it keeps on from where it stood, at its waypoint's height; with `keep`, it keeps that
/// way anew, along its nose.
fn places(world: gameobj.World, index: u16, keep: bool) void {
    const state = &world.objects.slots[index].state.patrol;
    const bound = world.mission orelse return;
    const lead = std.math.cast(u16, state.leader) orelse return;
    const leader_ship = bound.ship(lead) orelse return;
    if (lead >= world.objects.slots.len) return;
    state.leader_at = leader_ship.runtime_position;
    const leader = &world.objects.slots[lead].object;
    const reach = math.forward(leader.root.orientation) * @as(Vector, @splat(leader.radius * ahead_radii));
    var offset: Vector = @splat(0);
    if (index == lead) {
        if (keep) state.reach = reach;
        state.mark = @as(Vector, state.leader_at) + @as(Vector, state.reach);
        state.mark[1] = state.target[1];
    } else if (pointOffset(bound, state.formation_point)) |from_origin| {
        offset = math.transform(leader.root.orientation, from_origin);
    }
    const from = position(leader);
    state.place = offset + from;
    offset += reach;
    state.ahead = offset + from;
}

/// `waypoint_next` (`0x00404000`): the waypoint after waypoint `at` on its route, by their indices
/// among `waypoints`: the next of its flight group's, or after its last, its first again.
///
/// **Fix:** for a route that starts the table, the game reads before the table as it walks back to
/// the route's first; OpenReliant stays within it, which ends with a pair of nulls in the game.
fn nextWaypoint(waypoints: []const bind.Mission.Waypoint, at: u16) u16 {
    const group = waypoints[at].group;
    if (at + 1 < waypoints.len and waypoints[at + 1].group == group) return at + 1;
    var first = at;
    while (first > 0 and waypoints[first - 1].group == group) first -= 1;
    return first;
}

/// Where a waypoint's object stands (`ship_object`), or where the mission's objects lack it, where
/// its record places it.
fn waypointAt(world: gameobj.World, waypoint: bind.Mission.Waypoint) Vector {
    if (waypoint.ship < world.objects.slots.len) return position(&world.objects.slots[waypoint.ship].object);
    const bound = world.mission orelse return @splat(0);
    return if (bound.ship(waypoint.ship)) |record| record.runtime_position else @splat(0);
}

/// The leader's pace, which the ship in `state` flies by: none where the leader no longer follows
/// Patrol Route.
fn leaderPace(world: gameobj.World, state: PatrolState) f32 {
    const leads = stateOf(world, state.leader, .patrol_route) orelse return 0;
    return leads.patrol.pace;
}

/// `flight_group_widest` (`0x00404A00`): the largest radius of the objects of the ships `members`.
fn widest(world: gameobj.World, members: []const u16) f32 {
    var largest: f32 = 0;
    for (members) |member| {
        if (member >= world.objects.slots.len) continue;
        largest = @max(largest, world.objects.slots[member].object.radius);
    }
    return largest;
}

// --- The formations -------------------------------------------------------------------------

/// The place of the formation point `point` about its formation's origin, where the mission has the
/// point.
fn pointOffset(bound: *const bind.Mission, point: u16) ?Vector {
    const all = bound.file.formationPoints() catch return null;
    return if (point < all.len) all[point].offset else null;
}

/// The points of the formation of point `point`: those of the mission's from the formation's first
/// that name it, its points following one another from there.
const FormationPoints = struct {
    all: []align(1) const dte.FormationPoint,
    formation: u16,
    at: usize,

    /// Those of point `point`'s formation, where the mission has the point and the formation.
    fn of(bound: *const bind.Mission, point: u16) ?FormationPoints {
        const all = bound.file.formationPoints() catch return null;
        const formations = bound.file.formations() catch return null;
        if (point >= all.len) return null;
        const formation = all[point].formation;
        if (formation >= formations.len) return null;
        return .{ .all = all, .formation = formation, .at = formations[formation].first_point };
    }

    /// The next point, by its index.
    fn next(points: *FormationPoints) ?u16 {
        while (points.at < points.all.len) {
            const at = points.at;
            points.at += 1;
            if (points.all[at].formation == points.formation) return @intCast(at);
        }
        return null;
    }
};

/// `formation_leader` (`0x00404230`): the ship that leads the formation of point `point` for a ship
/// of flight group `group`: the first of the mission's ships of that group, or of none for
/// `dte.Ship.no_flight_group`, that stands at the formation's point nearest its origin
/// (`formation_ship_at`, `0x004042E0`). Null where none does.
///
/// **Fix:** the game looks at the points from the formation's first to the mission's last, so that
/// a later formation's point nearer its origin takes the lead, which no ship of the group stands
/// at; OpenReliant looks at the formation's own points.
fn leaderOf(bound: *const bind.Mission, group: u8, point: u16) ?u16 {
    var points = FormationPoints.of(bound, point) orelse return null;
    var lead: ?u16 = null;
    var nearest: f32 = 0;
    while (points.next()) |at| {
        const from_origin = math.length(points.all[at].offset);
        if (lead == null or from_origin < nearest) {
            lead = at;
            nearest = from_origin;
        }
    }
    const lead_point = lead orelse return null;
    const ships = bound.ships() catch return null;
    for (ships, 0..) |ship, index| {
        if (ship.formation_point == lead_point and ship.flight_group == group) return @intCast(index);
    }
    return null;
}

/// `formation_size` (`0x00404950`): the size of the formation of point `point`: how far apart the
/// corners of the box round its points lie (`box_include`).
///
/// **Fix:** the game takes in the points from the formation's first to the mission's last, as
/// `leaderOf` looks at them; OpenReliant takes in the formation's own.
fn formationSize(bound: *const bind.Mission, point: u16) f32 {
    var points = FormationPoints.of(bound, point) orelse return 0;
    const first = points.next() orelse return 0;
    var least: Vector = points.all[first].offset;
    var most = least;
    while (points.next()) |at| {
        const offset: Vector = points.all[at].offset;
        least = @min(least, offset);
        most = @max(most, offset);
    }
    return math.distance(most, least);
}

// --- Turning and pace -----------------------------------------------------------------------

/// How `face` turns a ship: with the AI's steering, held within a limit, or on the level, where it
/// gives the angle off the ship's nose (`levelTurn`) where that is asked for.
const Turning = union(enum) {
    steer: f32,
    level: ?*f32,
};

/// How much the AI's steering eases its turn in `face` (`0x00404538`).
const face_ease: f32 = 0.1;

/// The cosine of the angle within which `face` counts a point as ahead (`0x004DC470`).
const ahead_cosine: f32 = 0.9;

/// `formation_face` (`0x004044D0`): turns the ship in slot `index` toward `at` as `turning` asks:
/// with the AI's steering, eased by `face_ease` (`ai.steer`), or on the level toward a point a unit
/// past `at` along the way to it (`levelTurn`). Whether `at` then lies ahead of the ship: the
/// cosine of the angle off its nose `ahead_cosine` or more (`object_point_ahead`, `0x00404570`).
/// The limit Patrol Route passes with its level turns goes unused.
fn face(world: gameobj.World, index: u16, at: Vector, turning: Turning) bool {
    const slot = &world.objects.slots[index];
    const from = position(&slot.object);
    switch (turning) {
        .steer => |limit| _ = ai.steer(world, index, at, limit, face_ease, .{}),
        .level => |angle| {
            const off = levelTurn(slot, at + math.normalize(at - from));
            if (angle) |out| out.* = off;
        },
    }
    return math.dot(math.forward(slot.object.root.orientation), math.normalize(at - from)) >= ahead_cosine;
}

/// How far, in radians, `levelTurn` turns a ship at most (`0x0040475A`).
///
/// **Improvement:** the game holds five degrees rounded to 0.08726646.
const level_turn: f32 = std.math.degreesToRadians(5.0);

/// What `levelTurn` multiplies the angle up or down to a point by, over the ship's pitch rate, for
/// its pitch input (`0x004DC474`).
const level_pitch: f32 = 0.05;

/// `object_turn_level` (`0x00404750`): turns the ship in slot `index` toward `at` on the level, as
/// Patrol Route turns its ships: its yaw input `level_turn` toward the side `at` lies on
/// (`onRight`), or the angle to it off its nose on the level where that is less; its pitch input
/// the angle up or down to it, less `ai.rate_damping` times its pitch rate, times `level_pitch`
/// over its flight stats' pitch rate; and no roll. The angle off its nose on the level, which the
/// game takes from the two directions with their heights dropped, after the one to `at` is made a
/// unit long.
///
/// **Improvement:** the angle up or down comes from `std.math.atan2` rather than the engine's table
/// (`sr_atan2`).
///
/// **Fix:** the game follows a null pointer for a ship with no flight stats, a stand-in;
/// OpenReliant leaves its inputs as they are.
fn levelTurn(slot: *create.Slot, at: Vector) f32 {
    const object = &slot.object;
    const way = at - position(object);
    var turn: f32 = if (onRight(object, at)) level_turn else -level_turn;
    var nose = math.forward(object.root.orientation);
    nose[1] = 0;
    var toward = math.normalize(way);
    toward[1] = 0;
    const off = std.math.acos(math.dot(toward, nose));
    if (@abs(turn) > off) turn = if (turn < 0) -off else off;
    const local = math.transformTransposed(object.root.orientation, way);
    const pitch = std.math.atan2(-local[1], @abs(local[2]));
    const flight = slot.flight orelse return off;
    object.yaw_input = turn;
    object.pitch_input = (pitch - ai.rate_damping * object.pitch_rate) * (level_pitch / flight.pitch_rate);
    object.roll_input = 0;
    return off;
}

/// `object_point_on_right` (`0x004048C0`): whether `at` lies to the right of the ship's nose on the
/// level, or dead ahead or astern: the way to it on the level, turned a right angle back about Y,
/// is not behind the nose on the level.
fn onRight(object: *const GameObject, at: Vector) bool {
    var toward = math.normalize(at - position(object));
    toward[1] = 0;
    toward = math.transform(math.rotation(.y, -std.math.pi / 2.0), toward);
    var nose = math.forward(object.root.orientation);
    nose[1] = 0;
    return math.dot(toward, nose) >= 0;
}

/// `object_point_in_front` (`0x00404700`): whether `at` lies in front of the ship, not behind its
/// nose.
fn inFront(object: *const GameObject, at: Vector) bool {
    return math.dot(math.forward(object.root.orientation), at - position(object)) >= 0;
}

/// `formation_steer_to` (`0x00403FD0`): the ship in slot `index` steers at `at`, held within
/// `limit` (`ai.steer`), and whether it is within two of its radii of it (`within`).
fn steerTo(world: gameobj.World, index: u16, at: Vector, limit: f32) bool {
    _ = ai.steer(world, index, at, limit, 0, .{});
    return within(&world.objects.slots[index].object, at, 0, null);
}

/// `object_within` (`0x004045D0`): whether the ship stands nearer `at` than `reach`, or two of its
/// radii for a reach of 0; `off` takes how far it stands from it, where that is asked for.
fn within(object: *const GameObject, at: Vector, reach: f32, off: ?*f32) bool {
    const distance = math.distance(position(object), at);
    if (off) |out| out.* = distance;
    return distance < if (reach == 0) 2 * object.radius else reach;
}

/// The speed a pace of 1 stands for (`0x004DC468`).
const pace_speed: f32 = 200;

/// `formation_set_pace` (`0x00404210`): sets the ship's throttle for the speed of `pace` and `more`
/// times that again, in `pace_speed`s: `(pace * more + pace) * pace_speed` over its top speed.
///
/// **Fix:** the game follows a null pointer for a ship with no flight stats, a stand-in;
/// OpenReliant leaves its throttle as it is.
fn setPace(slot: *create.Slot, pace: f32, more: f32) void {
    const flight = slot.flight orelse return;
    slot.object.throttle = (pace * more + pace) * pace_speed / flight.max_speed;
}

/// Where the object stands (`GameObject.root`'s position), which these orders go by.
fn position(object: *const GameObject) Vector {
    return gameobj.vector(object.root.position);
}

/// The state of the order the object in slot `index` follows, where that is `order`.
fn stateOf(world: gameobj.World, index: anytype, order: Order) ?*aigeneric.State {
    const at = std.math.cast(u16, index) orelse return null;
    if (at >= world.objects.slots.len) return null;
    const slot = &world.objects.slots[at];
    const entry = slot.current() orelse return null;
    return if (entry.order == order) &slot.state else null;
}

/// A mission for the tests: the player's ship far off, a flight group of two Predators from slot 1,
/// each with the point `points` gives it, or none for `dte.Ship.no_formation_point`, and a route of
/// two waypoints, 10000 and 20000 along Z, in flight group 1. Each ship's object stands where its
/// record places it, its radius `radius`.
const TestMission = struct {
    game: vm.machine.testing.Game,

    const leader = 1;
    const wingman = 2;
    const first_waypoint = 3;
    const radius: f32 = 50;

    /// One formation, its leader's point at its origin and its wingman's 1000 to the right.
    const formations = [_]dte.Formation{.{ .name = 0, ._unknown_02 = 0, .first_point = 0, ._unknown_06 = 0 }};
    const points = [_]dte.FormationPoint{ testPoint(0, .{ 0, 0, 0 }), testPoint(0, .{ 1000, 0, 0 }) };

    fn init(mission: *TestMission, at: [2][3]f32, formation_points: [2]u16) !void {
        const predator = @backingInt(gameobj.GameType.predator);
        var records: [5]dte.Ship = undefined;
        records[0] = dte.testing.ship(0, dte.Ship.no_flight_group, predator);
        records[0].position = .{ 0, 50000, 0 };
        for (at, formation_points, 1..) |place, point, n| {
            records[n] = dte.testing.ship(@intCast(n), 0, predator);
            records[n].position = place;
            records[n].formation_point = point;
        }
        for (0..2) |n| {
            records[first_waypoint + n] = dte.testing.ship(@intCast(first_waypoint + n), 1, dte.Ship.waypoint_kind);
            records[first_waypoint + n].position = .{ 0, 0, 10000 * @as(f32, @floatFromInt(n + 1)) };
        }
        const groups = [_]dte.FlightGroup{ dte.testing.flightGroup(5, .none), dte.testing.flightGroup(6, .none) };
        try mission.game.init(std.testing.allocator, &.{}, .{
            .ships = &records,
            .flight_groups = &groups,
            .formations = &formations,
            .formation_points = &points,
        });
        errdefer mission.game.deinit();
        for (records) |record| {
            const index = try mission.game.mission.add(.of(.predator), record.position);
            mission.game.mission.slot(index).object.radius = radius;
        }
    }

    fn slot(mission: *TestMission, index: u16) *create.Slot {
        return mission.game.mission.slot(index);
    }

    /// Gives the ship in slot `index` `order`, aimed at `target`, and runs its orders once, its
    /// `init` with them.
    fn give(mission: *TestMission, index: u16, order: Order, target: aigeneric.Target) !void {
        try std.testing.expect(try aigeneric.push(mission.game.orders(), index, order, target));
        aigeneric.objectOrders(mission.game.orders(), index);
    }

    /// A frame of the two ships' orders, the leader's first.
    fn frame(mission: *TestMission) void {
        aigeneric.objectOrders(mission.game.orders(), leader);
        aigeneric.objectOrders(mission.game.orders(), wingman);
    }

    /// Turns the ship in slot `index` to face `at`.
    fn turnTo(mission: *TestMission, index: u16, at: [3]f32) void {
        const object = &mission.slot(index).object;
        object.root.orientation = math.lookAt(@as(Vector, at) - position(object));
    }

    /// Puts the ship in slot `index` at `at`.
    fn moveTo(mission: *TestMission, index: u16, at: Vector) void {
        const slot_at = mission.slot(index);
        objects.setPosition(&slot_at.object, &slot_at.drawn, at);
    }
};

fn testPoint(formation: u16, offset: [3]f32) dte.FormationPoint {
    return .{ .formation = formation, ._unknown_02 = 0, .offset = offset };
}

test "Formation Regroup meets about the group's middle, and moves on once all are ready" {
    var mission: TestMission = undefined;
    try mission.init(.{ .{ 0, 0, 0 }, .{ 2000, 0, 0 } }, .{ 0, 1 });
    defer mission.game.deinit();
    try mission.give(TestMission.leader, .formation_regroup, .none);
    try mission.give(TestMission.wingman, .formation_regroup, .none);

    // The group's middle is 1000 along X; each meets 10000 back from its point's place about it.
    const lead = &mission.slot(TestMission.leader).state.regroup;
    const wing = &mission.slot(TestMission.wingman).state.regroup;
    try std.testing.expectEqual([3]f32{ 1000, 0, -10000 }, lead.meet);
    try std.testing.expectEqual([3]f32{ 2000, 0, -10000 }, wing.meet);
    try std.testing.expectEqual([3]f32{ 2000, 0, 0 }, wing.place);
    try std.testing.expectEqual(TestMission.leader, lead.leader);
    try std.testing.expectEqual(TestMission.leader, wing.leader);
    try std.testing.expectEqual(0, mission.slot(TestMission.wingman).object.throttle);

    // Facing away, neither is ready, and the group stays where it is.
    for (0..20) |_| mission.frame();
    try std.testing.expectEqual(RegroupStep.aiming, wing.step);

    // Turned to their meeting points, both are ready, and after the leader's fifteen updates the
    // group sets off, straight, the points being nearer than `curve_least`.
    mission.turnTo(TestMission.leader, lead.meet);
    mission.turnTo(TestMission.wingman, wing.meet);
    mission.frame();
    for (0..ready_updates - 1) |_| mission.frame();
    try std.testing.expectEqual(RegroupStep.aiming, wing.step);
    mission.frame();
    try std.testing.expectEqual(RegroupStep.flying, lead.step);
    try std.testing.expectEqual(RegroupStep.flying, wing.step);
    try std.testing.expect(wing.direct);
    try std.testing.expectApproxEqAbs(set_off_pace * pace_speed / gameobj.testing.flight.max_speed, mission.slot(TestMission.wingman).object.throttle, 1e-6);

    // Within two radii of its point, a ship stops, ready.
    mission.moveTo(TestMission.wingman, @as(Vector, wing.meet) + Vector{ 0, 0, 50 });
    mission.frame();
    try std.testing.expect(wing.ready);
    try std.testing.expectEqual(0, mission.slot(TestMission.wingman).object.throttle);
    try std.testing.expect(!lead.ready);

    // Both there and facing their places, the group comes to its end and the orders pop.
    mission.moveTo(TestMission.leader, lead.meet);
    for (0..ready_updates + 1) |_| mission.frame();
    try std.testing.expectEqual(RegroupStep.facing, wing.step);
    mission.turnTo(TestMission.leader, lead.place);
    mission.turnTo(TestMission.wingman, wing.place);
    for (0..ready_updates + 1) |_| mission.frame();
    try std.testing.expectEqual(0, mission.slot(TestMission.leader).object.order_count);
    try std.testing.expectEqual(0, mission.slot(TestMission.wingman).object.order_count);
}

test "a regrouping ship far from its meeting point flies a curve that swings out to the side" {
    var mission: TestMission = undefined;
    try mission.init(.{ .{ 0, 0, 0 }, .{ 50000, 0, 0 } }, .{ 0, 1 });
    defer mission.game.deinit();
    try mission.give(TestMission.leader, .formation_regroup, .none);
    try mission.give(TestMission.wingman, .formation_regroup, .none);
    const wing = &mission.slot(TestMission.wingman).state.regroup;
    mission.turnTo(TestMission.leader, mission.slot(TestMission.leader).state.regroup.meet);
    mission.turnTo(TestMission.wingman, wing.meet);
    for (0..ready_updates + 1) |_| mission.frame();
    try std.testing.expectEqual(RegroupStep.flying, wing.step);
    try std.testing.expect(!wing.direct);

    // The curve runs from where it stood to its meeting point, leaving it turned a right angle
    // from the way across.
    try std.testing.expectEqual([3]f32{ 50000, 0, 0 }, wing.curve.from);
    try std.testing.expectEqual(wing.meet, wing.curve.to);
    try math.testing.expectVectorWithin(.{ -5000, 0, 12000 }, wing.curve.leaving, 1e-2);
    try std.testing.expectEqual(null, wing.curve.endShip());

    // At its start, it flies toward the curve's first step, turned at it, and on to the next once
    // there.
    mission.frame();
    try std.testing.expect(wing.started);
    try std.testing.expectEqual(1, wing.along);
    const step: Vector = curves.point(wing.curve, 1.0 / @as(f32, curves.steps));
    const nose = math.forward(mission.slot(TestMission.wingman).object.root.orientation);
    try math.testing.expectVectorWithin(math.normalize(step - Vector{ 50000, 0, 0 }), nose, 1e-5);
    mission.moveTo(TestMission.wingman, step);
    mission.frame();
    try std.testing.expectEqual(2, wing.along);
}

test "a ship in no formation turns toward the world's origin, its state empty" {
    var mission: TestMission = undefined;
    try mission.init(.{ .{ 0, 0, 0 }, .{ 2000, 0, 0 } }, .{ dte.Ship.no_formation_point, 1 });
    defer mission.game.deinit();
    mission.slot(TestMission.leader).object.throttle = 0.5;
    try mission.give(TestMission.leader, .formation_regroup, .none);
    const state = mission.slot(TestMission.leader).state.regroup;
    try std.testing.expectEqual(no_ship, state.leader);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, state.meet);
    try std.testing.expectEqual(0.5, mission.slot(TestMission.leader).object.throttle);
}

test "alone, the group's ships line up through each waypoint, and fly on to the next" {
    var mission: TestMission = undefined;
    const none = dte.Ship.no_formation_point;
    try mission.init(.{ .{ 0, 0, 0 }, .{ 2000, 0, 0 } }, .{ none, none });
    defer mission.game.deinit();
    const first = mission.game.fixture.mission.firstWaypoint(1).?;
    try mission.give(TestMission.leader, .patrol_route, .at(first, null));
    try mission.give(TestMission.wingman, .patrol_route, .at(first, null));

    // The group's widest is 100 across, so its two ships span 600, the first nearest the next
    // waypoint.
    const lead = &mission.slot(TestMission.leader).state.patrol;
    const wing = &mission.slot(TestMission.wingman).state.patrol;
    try std.testing.expectEqual(PatrolMode.alone, lead.mode);
    try math.testing.expectVector(.{ 0, 0, 10300 }, lead.target);
    try math.testing.expectVector(.{ 0, 0, 10000 }, wing.target);
    try std.testing.expectEqual(start_pace, lead.pace);

    // There, the first sets off for the next waypoint, its line now running back the other way.
    mission.moveTo(TestMission.leader, lead.target);
    mission.frame();
    try std.testing.expectEqual(first + 1, lead.waypoint);
    try math.testing.expectVector(.{ 0, 0, 19700 }, lead.target);
    try std.testing.expectEqual(first, wing.waypoint);
}

test "in formation, the leader moves the group on to the next waypoint once all are in place" {
    var mission: TestMission = undefined;
    try mission.init(.{ .{ 0, 0, 0 }, .{ 1000, 0, 0 } }, .{ 0, 1 });
    defer mission.game.deinit();
    const first = mission.game.fixture.mission.firstWaypoint(1).?;
    try mission.give(TestMission.leader, .patrol_route, .at(first, null));
    try mission.give(TestMission.wingman, .patrol_route, .at(first, null));

    // The wingman's place is its point's place about the leader, turned as the leader is, and
    // its place ahead 8 of the leader's radii on.
    const lead = &mission.slot(TestMission.leader).state.patrol;
    const wing = &mission.slot(TestMission.wingman).state.patrol;
    try std.testing.expectEqual(PatrolMode.formation, wing.mode);
    try std.testing.expectEqual(TestMission.leader, wing.leader);
    try math.testing.expectVector(.{ 1000, 0, 0 }, wing.place);
    try math.testing.expectVector(.{ 1000, 0, 400 }, wing.ahead);
    try std.testing.expectEqual(1000, lead.size);

    // In its place and turned to it, the wingman is in place, and the leader always is.
    mission.turnTo(TestMission.wingman, wing.ahead);
    mission.frame();
    try std.testing.expect(wing.in_place);
    try std.testing.expect(lead.in_place);

    // The leader's next update finds both in place but itself short of its waypoint: neither is
    // in place any more, and the leader aims at its waypoint again, its pace taken by how far it
    // must turn, here not at all.
    aigeneric.objectOrders(mission.game.orders(), TestMission.leader);
    try std.testing.expect(!wing.in_place);
    try std.testing.expectEqual(0, lead.aim);
    try std.testing.expectEqual(straight_pace, lead.pace);

    // At its waypoint, the leader has come there, and the wingman takes its place again.
    mission.moveTo(TestMission.leader, lead.target);
    mission.moveTo(TestMission.wingman, .{ 1000, 0, 10000 });
    mission.frame();
    try std.testing.expect(lead.arrived);
    try std.testing.expect(wing.in_place);

    // The next round sends the leader on to the next waypoint. The wingman, after the leader in
    // the group's list, finds that the leader's setting off has cleared its arrival, and has it
    // aim again instead, as in the game; it keeps its place about the leader all the same.
    aigeneric.objectOrders(mission.game.orders(), TestMission.leader);
    try std.testing.expectEqual(first + 1, lead.waypoint);
    try std.testing.expect(!lead.arrived);
    try std.testing.expectEqual(first, wing.waypoint);
    try std.testing.expectEqual(1, wing.aim);
}

test "a ship sliding into its place keeps the move its step has left" {
    var mission: TestMission = undefined;
    try mission.init(.{ .{ 0, 0, 0 }, .{ 1000, 0, 0 } }, .{ 0, 1 });
    defer mission.game.deinit();
    const first = mission.game.fixture.mission.firstWaypoint(1).?;
    try mission.give(TestMission.leader, .patrol_route, .at(first, null));
    try mission.give(TestMission.wingman, .patrol_route, .at(first, null));
    const wing = &mission.slot(TestMission.wingman).state.patrol;

    // 130 behind its place, within 3.2 of its radii but not two, turned to its place ahead, and
    // with a move of 30 left to make.
    const from = @as(Vector, wing.place) - Vector{ 0, 0, 130 };
    mission.moveTo(TestMission.wingman, from);
    mission.turnTo(TestMission.wingman, wing.ahead);
    const object = &mission.slot(TestMission.wingman).object;
    object.root.next_position = gameobj.vec3(from + Vector{ 0, 0, 30 });
    aigeneric.objectOrders(mission.game.orders(), TestMission.wingman);

    // It slides a 200th of the way, and its move is still to come.
    try math.testing.expectVector(from + Vector{ 0, 0, 130 * slide_share }, position(object));
    try math.testing.expectVector(from + Vector{ 0, 0, 30 + 130 * slide_share }, object.nextPosition());
}

test "a Patrol Route aimed past the mission's waypoints ends" {
    var mission: TestMission = undefined;
    try mission.init(.{ .{ 0, 0, 0 }, .{ 1000, 0, 0 } }, .{ 0, 1 });
    defer mission.game.deinit();
    try mission.give(TestMission.leader, .patrol_route, .at(7, null));
    try std.testing.expectEqual(0, mission.slot(TestMission.leader).object.order_count);
}

test "the leader stands at the point nearest its formation's origin, among its own points" {
    // Formation 0 has no point at its origin; formation 1's first lies nearer it than any of
    // formation 0's, which the game would take.
    const formations = [_]dte.Formation{
        .{ .name = 0, ._unknown_02 = 0, .first_point = 0, ._unknown_06 = 0 },
        .{ .name = 0, ._unknown_02 = 0, .first_point = 3, ._unknown_06 = 0 },
    };
    const points = [_]dte.FormationPoint{
        testPoint(0, .{ 1000, 0, 0 }), testPoint(0, .{ 0, 0, 500 }),   testPoint(0, .{ -1000, 0, 0 }),
        testPoint(1, .{ 100, 0, 0 }),  testPoint(1, .{ 0, 0, -2000 }),
    };
    var records: [4]dte.Ship = undefined;
    for (&records, 0..) |*record, n| {
        record.* = dte.testing.ship(@intCast(n), if (n < 3) 0 else 1, 43);
        record.formation_point = @intCast(n);
    }
    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(std.testing.allocator, &.{}, .{ .ships = &records, .formations = &formations, .formation_points = &points });
    defer fixture.deinit();
    const bound = &fixture.mission;
    try std.testing.expectEqual(1, leaderOf(bound, 0, 0));
    try std.testing.expectEqual(3, leaderOf(bound, 1, 3));
    try std.testing.expectEqual(null, leaderOf(bound, 1, 0));
    try std.testing.expectEqual(null, leaderOf(bound, 0, 9));
    // Formation 0's points span 2000 across and 500 deep.
    try std.testing.expectApproxEqAbs(@sqrt(2000.0 * 2000.0 + 500.0 * 500.0), formationSize(bound, 1), 1e-2);
    try std.testing.expectApproxEqAbs(@sqrt(100.0 * 100.0 + 2000.0 * 2000.0), formationSize(bound, 4), 1e-2);
}

test nextWaypoint {
    const waypoints = [_]bind.Mission.Waypoint{
        .{ .group = 1, .ship = 10 }, .{ .group = 1, .ship = 11 }, .{ .group = 1, .ship = 12 }, .{ .group = 2, .ship = 13 },
    };
    try std.testing.expectEqual(1, nextWaypoint(&waypoints, 0));
    try std.testing.expectEqual(2, nextWaypoint(&waypoints, 1));
    // After a route's last, its first again; a route of one comes back to itself.
    try std.testing.expectEqual(0, nextWaypoint(&waypoints, 2));
    try std.testing.expectEqual(3, nextWaypoint(&waypoints, 3));
}

test levelTurn {
    var slot: create.Slot = .{ .object = gameobj.testing.object(), .flight = &gameobj.testing.flight };
    // Off to the right, it yaws right by five degrees at most.
    try std.testing.expectApproxEqAbs(std.math.pi / 4.0, levelTurn(&slot, .{ 1000, 0, 1000 }), 1e-5);
    try std.testing.expectApproxEqAbs(level_turn, slot.object.yaw_input, 1e-6);
    try std.testing.expectEqual(0, slot.object.pitch_input);
    // To the left, the other way; nearer its nose than five degrees, by that angle.
    _ = levelTurn(&slot, .{ -1000, 0, 1000 });
    try std.testing.expectApproxEqAbs(-level_turn, slot.object.yaw_input, 1e-6);
    const off = levelTurn(&slot, .{ 10, 0, 1000 });
    try std.testing.expectApproxEqAbs(std.math.atan(@as(f32, 0.01)), off, 1e-4);
    try std.testing.expectApproxEqAbs(off, slot.object.yaw_input, 1e-6);
    // Above it, Y being down, it pitches by the angle up, damped by its pitch rate.
    slot.object.pitch_rate = 0.1;
    _ = levelTurn(&slot, .{ 0, -1000, 1000 });
    const expected = (std.math.pi / 4.0 - ai.rate_damping * 0.1) * level_pitch / gameobj.testing.flight.pitch_rate;
    try std.testing.expectApproxEqAbs(expected, slot.object.pitch_input, 1e-6);
    try std.testing.expectEqual(0, slot.object.roll_input);
}

test setPace {
    var slot: create.Slot = .{ .object = gameobj.testing.object(), .flight = &gameobj.testing.flight };
    // A pace of 0.3 is a speed of 60, and 0.95 less of it a twentieth of that.
    setPace(&slot, 0.3, 0);
    try std.testing.expectApproxEqAbs(60 / gameobj.testing.flight.max_speed, slot.object.throttle, 1e-6);
    setPace(&slot, 0.3, ahead_less);
    try std.testing.expectApproxEqAbs(3 / gameobj.testing.flight.max_speed, slot.object.throttle, 1e-6);
    // A stand-in, with no flight stats, keeps its throttle.
    var stand_in: create.Slot = .{ .object = gameobj.testing.object() };
    stand_in.object.throttle = 0.5;
    setPace(&stand_in, 0.3, 0);
    try std.testing.expectEqual(0.5, stand_in.object.throttle);
}
