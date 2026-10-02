//! `C:\lancer\game\aifuncs.cpp`: the orders a ship flies by: Mill, Do Nothing, Fly Aimlessly,
//! Escort, Fly, Run Away, Find New Target, Find Scoop Up, Object Attach, Toggle Cloak, Slow Rotate,
//! the Random Spins, Formation, Match Speed and Disrupted; the two that launch a missile; a capital
//! ship's lurch as a torpedo strikes it (Make capship list left and right); and orders 44 and 45,
//! which stop the ship dead and back it up. [`aigeneric.zig`](aigeneric.zig) runs them,
//! [`ai.zig`](ai.zig) steers for them, and `docs/engine/orders.md` describes what each does.
//!
//! **Unverified:** only `order_make_boridin_section_break_away_init` (`0x0040BF60`) is placed in
//! this file. The order routines from Mill's (`0x0040A6F0`) up to it lie between `aifight.cpp`'s
//! known code and it, and those from Rotate Boridin breakaway warp projector's (`0x0040C100`) to
//! order 45's (`0x0040C4E0`) between it and `aigeneric.cpp`'s; they go with it as order routines
//! like it.
//!
//! Not ported ([#30](https://github.com/OpenReliant/openreliant/issues/30)): of the order routines
//! here, those of Avoid Target (`0x0040B310`, `0x0040B330`), Dark Reign shoot (`0x0040BAD0`), Turns
//! object lights on (`0x0040BBD0`, `0x0040BC20`) and off (`0x0040BE90`), Make Boridin section break
//! away (`0x0040BF60`) and Rotate Boridin breakaway warp projector (`0x0040C100`).

const std = @import("std");
const assert = std.debug.assert;

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const erayfx = @import("erayfx.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const cloak = @import("cloak.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const Order = @import("ai/orders.zig").Order;
const missiles = @import("missiles.zig");
const objects = @import("objects.zig");
const xtrabits = @import("xtrabits.zig");

// --- Mill -----------------------------------------------------------------------------------

/// What Mill keeps in `order_state`: the frame's tick it began, and the circle it flies round its
/// target, as an orientation whose X and forward axes the circle turns through.
pub const MillState = extern struct {
    started: i32,
    circle: math.Matrix,
    _unknown_28: [0x90 - 0x28]u8,

    comptime {
        assert(@offsetOf(MillState, "circle") == 0x04);
        assert(@sizeOf(MillState) == 0x90);
    }
};

/// How long Mill flies round its target, in ticks (`0x0040A791`); how far from the target its
/// circle runs (`0x004DC494`); and how far round it the point it steers for comes for each tick at
/// the ship's cruise speed (`0x004DC4F4`).
const mill_ticks = 500;
const mill_radius: f32 = 50000;
const mill_pace: f32 = 5e-6;

/// `order_mill_init` (`0x0040A6F0`): the init of Mill (120). Where the ship can aim at its target,
/// cloaked or not (`ai.targetValid`), the mill begins, round a circle facing from the target's node
/// (`ai.aimedAt`) to where the ship will be next.
pub fn millInit(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = ai.ValidTarget.of(all, slot.orders[0].target, .{ .cloaked = true }) orelse return;
    const state = &slot.state.mill;
    state.started = ctx.world.clock.frame_start;
    state.circle = math.lookAt(slot.object.nextPosition() - ai.aimedAt(all, target).position);
}

/// `order_mill` (`0x0040A750`): the update of Mill (120). It pops once the ship can no longer aim
/// at its target or `mill_ticks` have passed. Otherwise the ship flies at full throttle, going
/// round what is in its way, for a point on its circle round the target's node, `mill_radius` from
/// it, which comes round from the ship's side by `mill_pace` of the cruise speed a tick.
///
/// **Improvement:** the sine and cosine come from `std.math` rather than the engine's tables
/// (`sr_sin`, `sr_cos`).
pub fn mill(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = ai.targetOrPop(ctx, index, .{ .cloaked = true }) orelse return;
    const state = &slot.state.mill;
    const now = ctx.world.clock.frame_start;
    if (state.started + mill_ticks < now) return aigeneric.end(ctx, index);
    const cruise = ai.slotCruise(slot, ctx.world.view) orelse return;
    const round: f32 = cruise * @as(f32, @floatFromInt(now - state.started)) * mill_pace;
    const across = math.xAxis(state.circle) * @as(Vector, @splat(@sin(round) * mill_radius));
    const along = math.forward(state.circle) * @as(Vector, @splat(@cos(round) * mill_radius));
    _ = ai.steer(ctx.world, index, across + along + ai.aimedAt(all, target).position, ai.full_limit, ai.no_ease, .clear);
    slot.object.throttle = ai.full_throttle;
}

// --- Do Nothing -----------------------------------------------------------------------------

/// `order_do_nothing` (`0x0040A880`): the update of Do Nothing (0), which lets the ship coast.
pub fn doNothing(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].object.letGo();
}

// --- Fly Aimlessly --------------------------------------------------------------------------

/// What Fly Aimlessly keeps in `order_state`: its figure, from 1 to 3 (`flyAimlessly`); the point
/// of the figure it flies for; where it began; and how the figure lies, turned as the ship was as
/// it began, its X axis reversed about half the time.
pub const AimlessState = extern struct {
    figure: i32,
    point: i32,
    start: shp.Vec3,
    orientation: math.Matrix,
    _unknown_38: [0x90 - 0x38]u8,

    comptime {
        assert(@offsetOf(AimlessState, "point") == 0x04);
        assert(@offsetOf(AimlessState, "start") == 0x08);
        assert(@offsetOf(AimlessState, "orientation") == 0x14);
        assert(@sizeOf(AimlessState) == 0x90);
    }
};

/// How many figures Fly Aimlessly flies (`0x0040A8D9`).
const aimless_figures = 3;

/// The throttle Fly Aimlessly flies at, and how much more it may take at random (`0x004DC4DC`,
/// `0x004DC4C0`).
const aimless_throttle: f32 = 0.4;
const aimless_throttle_spread: f32 = 0.3;

/// How far round its figure each point comes (`0x004DC500`): a twentieth of a turn.
const aimless_step: f32 = 0.05;

/// How far to the side the figure reaches, at each end, for each of its number and one more; and
/// how far ahead and behind it swings (`0x004DC4FC`, `0x004DC494`).
const aimless_side: f32 = 25000;
const aimless_ahead: f32 = 50000;

/// How near a point the ship comes before it flies for the next (`0x004DC4F8` holds its square).
const aimless_reach: f32 = 1000;

/// `order_fly_aimlessly_init` (`0x0040A8C0`): the init of Fly Aimlessly (1). The ship takes its
/// figure, 1 to 3, from its own random numbers (`xtrabits.objectRandom15`), and lays it where it
/// will be next, turned as it will be, its X axis reversed where its next number is odd. It flies
/// for the figure's first point, at `aimless_throttle` and up to `aimless_throttle_spread` more at
/// random (`rand`).
pub fn flyAimlesslyInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    const state = &slot.state.aimless;
    state.figure = @as(i32, xtrabits.objectRandom15(object) % aimless_figures) + 1;
    state.start = object.root.next_position;
    state.orientation = object.root.next_orientation;
    state.point = 1;
    if (xtrabits.objectRandom15(object) & 1 != 0) {
        const turn = state.orientation;
        state.orientation = math.fromAxes(-math.xAxis(turn), math.yAxis(turn), math.forward(turn));
    }
    object.throttle = ctx.world.random.fraction() * aimless_throttle_spread + aimless_throttle;
}

/// `order_fly_aimlessly` (`0x0040A980`): the update of Fly Aimlessly (1), which never ends. The
/// ship flies, going round what is in its way, for the point of its figure it has come to, then
/// for the next once within `aimless_reach` of it. Point `n` lies `t = n` twentieths of a turn
/// round: `(cos t - 1)(figure + 1)` times `aimless_side` to the side of where the order began, and
/// `sin(figure t)` times `aimless_ahead` ahead of it, as the figure lies. Figure 1 is a circle, and
/// figures 2 and 3 are wider loops that swing ahead and back two and three times on the way round.
///
/// **Improvement:** the sine and cosine come from `std.math` rather than the engine's tables
/// (`sr_sin`, `sr_cos`).
pub fn flyAimlessly(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.aimless;
    const turn = @as(f32, @floatFromInt(state.point)) * aimless_step * std.math.tau;
    const figure: f32 = @floatFromInt(state.figure);
    const local: Vector = .{ (@cos(turn) - 1) * (figure + 1) * aimless_side, 0, @sin(figure * turn) * aimless_ahead };
    const point = math.transform(state.orientation, local) + gameobj.vector(state.start);
    _ = ai.steer(ctx.world, index, point, ai.full_limit, ai.no_ease, .clear);
    if (math.distanceSquared(slot.object.nextPosition(), point) < aimless_reach * aimless_reach) state.point +%= 1;
}

// --- Escort ---------------------------------------------------------------------------------

/// What Escort keeps in `order_state`: how many ships of its target's group its start has still to
/// pass before the one it escorts, and that ship's slot, -1 for none.
pub const EscortState = extern struct {
    place: i32,
    escorted: i32,
    _unknown_08: [0x90 - 0x08]u8,

    /// The slot of the ship it escorts, where that is one of `all`'s slots.
    pub fn escortedIn(state: EscortState, all: *const create.Objects) ?u16 {
        const escorted = std.math.cast(u16, state.escorted) orelse return null;
        return if (escorted < all.slots.len) escorted else null;
    }

    comptime {
        assert(@offsetOf(EscortState, "escorted") == 0x04);
        assert(@sizeOf(EscortState) == 0x90);
    }
};

/// How far ahead of the escorted ship the escort steers for (`0x0040AB16`); within how far of it
/// the escort steers gently (`0x004DC504`, as its square), and by how much of its turn
/// (`0x0040AB89`); and how much faster than the escorted ship it flies for each unit it lies ahead
/// of the escort along the escort's heading (`0x004DC4B0`).
const escort_lead: f32 = 10000;
const escort_near: f32 = 5000;
const escort_near_limit: f32 = 0.5;
const escort_catch_up: f32 = 0.0001;

/// `order_escort_init` (`0x0040AA80`): the init of Escort (9). The ship escorts the ship its order
/// names; or for a flight group or a squad, the ship at the order's place among the group's ships
/// (`aigeneric.Entry.sequence`), counting round them again past the last (`ai.eachShip`,
/// `escort_count_place`).
///
/// **Fix:** where the group has no ships, the game walks it again for ever; OpenReliant escorts
/// none, which ends the order at its first update.
pub fn escortInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.escort;
    const entry = slot.orders[0];
    if (entry.target.kind == .ship) {
        state.escorted = entry.target.index;
        return;
    }
    state.escorted = -1;
    state.place = entry.sequence;
    while (state.place >= 0) {
        var counting: EscortCount = .{ .state = state };
        _ = ai.eachShip(ctx.world, entry.target, &counting);
        if (!counting.visited) return;
    }
}

/// `escort_count_place` (`0x0040AA50`), Escort's visitor: each ship takes one off the place to go,
/// and the one that takes it below nothing is the one to escort.
const EscortCount = struct {
    state: *EscortState,
    visited: bool = false,

    pub fn visit(count: *EscortCount, ship: aigeneric.Target) bool {
        count.visited = true;
        count.state.place -= 1;
        if (count.state.place >= 0) return false;
        count.state.escorted = ship.index;
        return true;
    }
};

/// `order_escort` (`0x0040AAD0`): the update of Escort (9). Once the escorted ship has gone, a
/// stand-in in its slot, the order pops. Otherwise the ship steers for a point `escort_lead` ahead
/// of it: within `escort_near` of it by `escort_near_limit` of its turn, rolling upright, and
/// farther off at its full turn, going round what is in its way. It flies at the escorted ship's
/// speed, and the faster the farther the escorted ship lies ahead along its own heading
/// (`escort_catch_up`).
pub fn escort(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const escorted = slot.state.escort.escortedIn(all) orelse return aigeneric.end(ctx, index);
    const other = &all.slots[escorted];
    if (other.object.type == .stand_in) return aigeneric.end(ctx, index);
    const lead = other.drawn.ahead(escort_lead);
    const to = other.drawn.position - slot.drawn.position;
    const near = math.lengthSquared(to) <= escort_near * escort_near;
    const limit = if (near) escort_near_limit else ai.full_limit;
    const flags: ai.Steering = if (near) .{ .roll_upright = true } else .clear;
    _ = ai.steer(ctx.world, index, lead, limit, ai.no_ease, flags);
    const cruise = ai.slotCruise(slot, ctx.world.view) orelse return;
    slot.object.throttle = math.dot(math.forward(slot.drawn.orientation), to) * escort_catch_up + other.object.speed / cruise;
}

// --- Fly and Run Away -----------------------------------------------------------------------

/// What Fly keeps in `order_state`: the heading it started with, which it flies along while it has
/// no target to fly to.
pub const FlyState = extern struct {
    _unknown_00: [2]f32,
    heading: shp.Vec3,
    _unknown_14: [0x7C]u8,

    comptime {
        assert(@offsetOf(FlyState, "heading") == 0x8);
        assert(@sizeOf(FlyState) == 0x90);
    }
};

/// How near its target Fly comes before it pops (`0x004DC490` holds its square).
const fly_reach: f32 = 2000;

/// How far along its heading Fly steers at while it has no target (`0x0040AD7A`).
const fly_ahead: f32 = 20000;

/// What Fly leaves of the throttle while the ship is going round something (`0x004DC408`).
const avoided_throttle: f32 = 0.5;

/// How far a Fly order moves an object that has no flight stats, for each unit of speed and each
/// tick of the frame (`0x004DC3D4`).
const drift_per_tick: f32 = 0.25;

/// How many times as far from the ship as its target the point Run Away steers for lies, on the
/// ship's far side from the target (`0x0040AE2C`).
const run_away_ahead: f32 = 100000;

/// The ease Run Away steers with (`0x0040AE5F`), and the throttle it flies at (`0x0040AE76`).
const run_away_ease: f32 = 0.1;
const run_away_throttle: f32 = 0.5;

/// `order_fly_init` (`0x0040AC00`): the init of Fly (6), which keeps the heading the ship starts
/// on.
pub fn flyInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.state.fly.heading = gameobj.vec3(slot.object.nextHeading());
}

/// `order_fly` (`0x0040AC20`): the update of Fly (6). It flies at the speed in the order's data, or
/// at full throttle for none. With a target it flies to it and pops once it is within `fly_reach`;
/// without one it holds the heading it started on, steering at a point `fly_ahead` along it. It
/// steers going round what is in its way and rolling upright, and keeps `avoided_throttle` of the
/// throttle while it goes round something. An object with no flight stats is moved along that
/// heading instead of flown, so that a body which has no flight of its own still travels.
///
/// **Improvement** (`main.frameObjects`): an object it moves without flight stats glides on between
/// the ticks (`create.Slot.glide`); the game draws it where it is placed.
pub fn fly(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const heading = gameobj.vector(slot.state.fly.heading);
    const speed: f32 = @floatFromInt(slot.orders[0].data.fly);
    if (speed == 0) {
        object.throttle = ai.full_throttle;
    } else if (ai.slotCruise(slot, ctx.world.view)) |cruise| {
        object.throttle = speed / cruise;
    } else {
        const ticks: f32 = @floatFromInt(ctx.world.clock.frame_duration);
        const per_tick = heading * @as(Vector, @splat(speed * drift_per_tick));
        objects.setPosition(object, &slot.drawn, object.nextPosition() + per_tick * @as(Vector, @splat(ticks)));
        slot.glide = per_tick;
        return;
    }

    // The game reads the target's index as a ship's slot, whatever its kind.
    const flags: ai.Steering = .{ .avoid_near = true, .avoid_ahead = true, .roll_upright = true };
    const avoided = if (slot.orders[0].target.slotIn(all)) |target| steer: {
        const to = all.slots[target].object.nextPosition();
        if (math.lengthSquared(to - object.nextPosition()) < fly_reach * fly_reach) {
            object.letGo();
            return aigeneric.end(ctx, index);
        }
        if (slot.flight == null) return;
        break :steer ai.steer(ctx.world, index, to, ai.full_limit, ai.no_ease, flags);
    } else steer: {
        const at = object.nextPosition() + heading * @as(Vector, @splat(fly_ahead));
        break :steer ai.steer(ctx.world, index, at, ai.full_limit, ai.no_ease, flags);
    };
    if (avoided) object.throttle *= avoided_throttle;
}

/// `order_run_away` (`0x0040ADE0`): the update of Run Away (7), which flies away from its target at
/// half throttle. It steers at a point far beyond itself, which it first moves round what lies near
/// (`ai.avoidNear`); the steering then goes round what lies near and ahead again (flags 0x3), so it
/// keeps its ease unless that second pass moves the point. It pops once the target's slot holds a
/// stand-in.
pub fn runAway(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    // The game reads the target's index as a ship's slot, whatever its kind.
    const other = find: {
        const target = slot.orders[0].target.slotIn(all) orelse break :find null;
        const object = &all.slots[target].object;
        break :find if (object.type == .stand_in) null else object;
    } orelse return aigeneric.end(ctx, index);
    const from = slot.object.nextPosition();
    const away = from - other.nextPosition();
    var at = from + away * @as(Vector, @splat(run_away_ahead));
    _ = ai.avoidNear(ctx.world, index, &at);
    _ = ai.steer(ctx.world, index, at, ai.full_limit, run_away_ease, .clear);
    slot.object.throttle = run_away_throttle;
}

// --- Find New Target ------------------------------------------------------------------------

/// A ship Find New Target or Find Scoop Up keeps as it walks its target's ships
/// (`find_target_weigh`, `find_scoop_up_nearest`): its slot and component, -1 for none and for the
/// whole ship, and how heavily it weighs, the most a float holds for none yet. The lightest offered
/// is kept.
pub const Pick = extern struct {
    ship: i32,
    component: i32,
    weight: f32,

    /// None yet, as each walk starts.
    pub const none: Pick = .{ .ship = -1, .component = -1, .weight = std.math.floatMax(f32) };

    /// Keeps `offered` where it weighs less than the one kept.
    pub fn offer(pick: *Pick, offered: aigeneric.Target, weight: f32) void {
        if (weight < pick.weight) pick.* = .{ .ship = offered.index, .component = offered.component, .weight = weight };
    }

    /// The ship kept, where there is one, as the target the order pushes at it: the halfwords
    /// `order_push` stores.
    pub fn kept(pick: Pick) ?aigeneric.Target {
        if (pick.ship < 0) return null;
        return .{ .kind = .ship, .index = @truncate(pick.ship), .component = @truncate(pick.component) };
    }

    comptime {
        assert(@offsetOf(Pick, "component") == 0x4);
        assert(@offsetOf(Pick, "weight") == 0x8);
        assert(@sizeOf(Pick) == 0xC);
    }
};

/// What Find New Target keeps in `order_state` as it walks its target's ships: the one it would
/// fight, and the one it would mill round.
pub const FindTargetState = extern struct {
    _unknown_00: u32,
    fight: Pick,
    mill: Pick,
    _unknown_1c: [0x90 - 0x1C]u8,

    comptime {
        assert(@offsetOf(FindTargetState, "fight") == 0x04);
        assert(@offsetOf(FindTargetState, "mill") == 0x10);
        assert(@sizeOf(FindTargetState) == 0x90);
    }
};

/// How many other fighters may fight a target before a fighter looks past it, as the count that
/// starts at 1 for itself (`0x0040AFAB`).
const most_fought = 3;

/// `order_find_new_target` (`0x0040B040`): the update of Find New Target (10). It weighs each ship
/// its target names (`ai.eachShip`, `weighTarget`) for the one to fight and the one to mill round.
/// It fights the lightest of the first, pushing Fight (105), or Torpedo (103) for a ship of the
/// torpedo class; with none, it mills round the lightest of the second (Mill, 120); each pushed
/// above it. With neither it pops.
///
/// Not ported: in a multiplayer game, a ship another machine flies, which pushes no Fight
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
pub fn findNewTarget(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.find_target;
    state.fight = .none;
    state.mill = .none;
    var weighing: Weighing = .{ .ctx = ctx, .index = index };
    _ = ai.eachShip(ctx.world, slot.orders[0].target, &weighing);
    const milled = state.mill.kept() orelse {
        if (state.fight.kept() == null) return aigeneric.end(ctx, index);
        slot.object.letGo();
        return;
    };
    const fought = state.fight.kept() orelse {
        _ = aigeneric.give(ctx, index, .mill, milled);
        return;
    };
    const torpedo = if (slot.combat) |combat| combat.class == .torpedo else false;
    _ = aigeneric.give(ctx, index, if (torpedo) .torpedo else .fight, fought);
}

/// The visitor of Find New Target's walk (`weighTarget`).
const Weighing = struct {
    ctx: Context,
    index: u16,

    pub fn visit(weighing: *Weighing, target: aigeneric.Target) bool {
        weighTarget(weighing.ctx, weighing.index, target);
        return false;
    }
};

/// `find_target_weigh` (`0x0040AE90`), Find New Target's visitor: a ship it can aim at, cloaked or
/// not (`ai.targetValid`), weighs the square of its node's distance from where the searcher will be
/// next. As one to fight, times one more than the ships whose current order is Fight at it, this
/// one component and all; as one to mill round, times that and one more than the ships whose
/// current order is Mill round it. The lightest of each is kept (`Pick.offer`), but to fight only
/// one that is not cloaked, not the target the radio's menu has set aside for the searcher
/// (`GameObject.set_aside`), and for a fighter one fewer than two others fight. Once the set-aside
/// time is up, the target is set aside no more, though not until this walk is over.
///
/// **Quirk:** the game weighs the one to fight by 0.7 more (`0x004DC484`) where the count of
/// objects it has just walked equals the player's slot, which never happens; it looks meant to
/// favour the player's ship ([#314](https://github.com/OpenReliant/openreliant/issues/314)).
/// OpenReliant keeps the game's weights.
fn weighTarget(ctx: Context, index: u16, target: aigeneric.Target) void {
    const all = ctx.world.objects;
    const valid = ai.ValidTarget.of(all, target, .{ .cloaked = true }) orelse return;
    const aimed = valid.slot;
    const slot = &all.slots[index];
    const state = &slot.state.find_target;
    const distance = math.lengthSquared(ai.aimedAt(all, valid).position - slot.object.nextPosition());
    var fights: f32 = 1;
    var mills: f32 = 1;
    for (all.slots[0..all.count]) |*other| {
        if (!other.object.type.hasStats()) continue;
        const entry = (other.current() orelse continue).*;
        if (entry.target.index != target.index or entry.target.component != target.component) continue;
        if (entry.order == .fight) fights += 1;
        if (entry.order == .mill) mills += 1;
    }
    if (slot.object.set_aside.index() == aimed) {
        if (slot.object.set_aside_until < ctx.world.clock.game_ticks) {
            slot.object.set_aside = .none;
            slot.object.set_aside_until = 0;
        }
    } else {
        const fighter = if (slot.combat) |combat| combat.class == .fighter else false;
        if (!all.slots[aimed].object.flags.cloaked and !(fighter and fights >= most_fought)) {
            state.fight.offer(target, fights * distance);
        }
    }
    state.mill.offer(target, (fights + mills) * distance);
}

// --- Find Scoop Up --------------------------------------------------------------------------

/// What Find Scoop Up keeps in `order_state`: its step, and as it walks its target's ships, the
/// nearest it would scoop up, weighed by the square of how far it is.
pub const FindScoopState = extern struct {
    step: FindScoopStep,
    scoop: Pick,
    _unknown_10: [0x90 - 0x10]u8,

    comptime {
        assert(@offsetOf(FindScoopState, "scoop") == 0x04);
        assert(@offsetOf(FindScoopState, "step") == @offsetOf(ListState, "step"));
        assert(@sizeOf(FindScoopState) == 0x90);
    }
};

/// Find Scoop Up's steps: the wait for the other players, then the search.
pub const FindScoopStep = enum(i32) {
    wait = 0,
    search = 1,
    _,
};

/// `order_first_step_init` (`0x0040B1C0`): the init of Find Scoop Up (21) and of Make capship list
/// left and right (115, 116), which a capital ship takes as a torpedo strikes it (`collision`):
/// each from its first step (`findScoopUp`, `capshipList`).
pub fn firstStepInit(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].state.list.step = .first;
}

comptime {
    // Find Scoop Up reads the same word as its own step.
    assert(@intFromEnum(ListStep.first) == @intFromEnum(FindScoopStep.wait));
}

/// `order_find_scoop_up` (`0x0040B1E0`): the update of Find Scoop Up (21), which starts at its
/// first step (`firstStepInit`). From the wait it goes on to the search; a multiplayer game waits
/// there first for every player, unless the order names a ship (`ai_sequence_sync`,
/// `0x00401000`). The search walks the ships the order's target names (`ai.eachShip`) for the
/// nearest to where the ship will be next that it can aim at, ejected or not, and scoops it up,
/// Scoop Up (107) pushed above it; with none it pops. Once Scoop Up is done, the order starts again
/// from the wait, and searches again.
///
/// Not ported: the wait, and in a multiplayer game the Scoop Up sent to the other players where
/// the order names no ship ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
pub fn findScoopUp(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.find_scoop_up;
    switch (state.step) {
        .wait => state.step = .search,
        .search => {
            state.scoop = .none;
            var scooping: Scooping = .{ .ctx = ctx, .index = index };
            _ = ai.eachShip(ctx.world, slot.orders[0].target, &scooping);
            const nearest = state.scoop.kept() orelse return aigeneric.end(ctx, index);
            _ = aigeneric.give(ctx, index, .scoop_up, nearest);
        },
        _ => {},
    }
}

/// `find_scoop_up_nearest` (`0x0040B140`), Find Scoop Up's visitor: a ship the searcher can aim at,
/// ejected or not (`ai.targetValid`), nearer to where the searcher will be next than the nearest so
/// far, by where it will be next, becomes the nearest (`Pick.offer`).
const Scooping = struct {
    ctx: Context,
    index: u16,

    pub fn visit(scooping: *Scooping, target: aigeneric.Target) bool {
        const all = scooping.ctx.world.objects;
        const found = ai.ValidTarget.of(all, target, .{ .ejected = true }) orelse return false;
        const slot = &all.slots[scooping.index];
        const distance = math.distanceSquared(all.slots[found.slot].object.nextPosition(), slot.object.nextPosition());
        slot.state.find_scoop_up.scoop.offer(target, distance);
        return false;
    }
};

// --- Object Attach and Toggle Cloak ---------------------------------------------------------

/// What Object Attach keeps in `order_state`: where the ship stands in its target's frame.
pub const AttachState = extern struct {
    offset: shp.Vec3,
    _unknown_0c: [0x90 - 0x0C]u8,

    comptime {
        assert(@sizeOf(AttachState) == 0x90);
    }
};

/// `order_object_attach_init` (`0x0040B4A0`): the init of Object Attach (13). The ship keeps where
/// it will stand next in the frame its target will stand in next.
pub fn attachInit(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target.slotIn(all) orelse return;
    slot.state.attach.offset = gameobj.vec3(all.slots[target].object.placeAt(.next).inverse(slot.object.nextPosition()));
}

/// `order_object_attach` (`0x0040B4F0`): the update of Object Attach (13). The ship rides its
/// target: it is put where its offset stands in the target's next frame, turned as the target will
/// be, and takes the target's turn, velocity, speed and rates of turn, which move it on with the
/// target until the next update.
pub fn attach(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target.slotIn(all) orelse return;
    const other = &all.slots[target].object;
    const next = other.placeAt(.next);
    objects.setPlace(&slot.object, &slot.drawn, .{ .position = next.point(gameobj.vector(slot.state.attach.offset)), .orientation = next.orientation });
    const object = &slot.object;
    object.rotation = other.rotation;
    object.velocity = other.velocity;
    object.speed = other.speed;
    object.pitch_rate = other.pitch_rate;
    object.yaw_rate = other.yaw_rate;
    object.roll_rate = other.roll_rate;
}

/// `order_toggle_cloak` (`0x0040B640`): Toggle Cloak (16), which runs once. The ship cloaks where
/// it is not cloaked, and uncloaks where it is (`cloak.set`): where its model can cloak, with the
/// ships launching from it.
pub fn toggleCloak(ctx: Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    cloak.set(ctx.world, index, !object.flags.cloaked);
}

// --- Slow Rotate and the Random Spins -------------------------------------------------------

/// The turn Slow Rotate yaws at, and what every Random Spin turns at before its own share
/// (`0x004DC420`).
pub const spin_input: f32 = 0.1;

/// `order_slow_rotate` (`0x0040B660`): the update of Slow Rotate (18), which turns the ship on the
/// spot.
pub fn slowRotate(ctx: Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    object.letGo();
    object.yaw_input = spin_input;
}

/// How fast a Random Spin tumbles: the share of the turn each input takes at random, on top of
/// `spin_input`: slow 0.3 (`0x004DC4C0`), medium 0.5 (`0x004DC408`), fast 0.9 (`0x004DC470`).
pub const Spin = enum(u8) {
    slow = 0,
    medium = 1,
    fast = 2,

    pub fn spread(spin: Spin) f32 {
        return switch (spin) {
            .slow => 0.3,
            .medium => 0.5,
            .fast => 0.9,
        };
    }
};

/// `order_random_spin_slow_init` (`0x0040B6A0`), `order_random_spin_medium_init` (`0x0040B730`)
/// and `order_random_spin_fast_init` (`0x0040B7C0`): the inits of the Random Spins (22 to 24),
/// which set the ship tumbling, each input at random. Their update does nothing, so the ship keeps
/// the tumble.
pub fn randomSpinInit(ctx: Context, index: u16, spin: Spin) void {
    const object = &ctx.world.objects.slots[index].object;
    const spread = spin.spread();
    object.throttle = 0;
    object.pitch_input = xtrabits.objectRandom(object) * spread + spin_input;
    object.roll_input = xtrabits.objectRandom(object) * spread + spin_input;
    object.yaw_input = xtrabits.objectRandom(object) * spread + spin_input;
}

// --- Formation ------------------------------------------------------------------------------

/// What Formation keeps in `order_state`: where the ship flies in its target's frame.
pub const FormationState = extern struct {
    place: shp.Vec3,
    _unknown_0c: [0x90 - 0x0C]u8,

    comptime {
        assert(@sizeOf(FormationState) == 0x90);
    }
};

/// The least throttle Formation comes to its place at (`0x0040B911`).
const formation_least_throttle: f32 = 0;

/// `order_formation_init` (`0x0040B850`): the init of Formation (27). The ships `SetAI` numbers fly
/// abreast of their target, `aigeneric.abreast_spacing` apart: the one numbered `n` flies `n / 2 +
/// 1` places out, to the target's left where `n` is even and to its right where it is odd
/// (`aigeneric.Entry.abreast`, counting from 2).
pub fn formationInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const out: f32 = @floatFromInt(slot.orders[0].abreast(2));
    slot.state.formation.place = .{ .x = out * aigeneric.abreast_spacing, .y = 0, .z = 0 };
}

/// `order_formation` (`0x0040B8A0`): the update of Formation (27), which keeps the ship at its
/// place by its target as the target will stand next, turned as the target will be (`ai.arrive`).
/// It pops once the target can no longer be aimed at.
pub fn formation(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = ai.targetOrPop(ctx, index, .{}) orelse return;
    const next = all.slots[target.slot].object.placeAt(.next);
    _ = ai.arrive(ctx.world, index, next.point(gameobj.vector(slot.state.formation.place)), next.orientation, formation_least_throttle);
}

// --- Match Speed ----------------------------------------------------------------------------

/// `order_match_speed` (`0x0040B9E0`): the update of Match Speed (32), which holds the ship at its
/// target's speed. It pops once the target can no longer be aimed at.
pub fn matchSpeed(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const target = ai.targetOrPop(ctx, index, .{}) orelse return;
    const cruise = ai.slotCruise(slot, ctx.world.view) orelse return;
    slot.object.throttle = all.slots[target.slot].object.speed / cruise;
}

// --- Launch Missile and order 3 -------------------------------------------------------------

/// `order_launch_missile` (`0x0040B940`): the update of Launch Missile (2), which runs once over
/// the ship's order: a missile from the first of its racks with any left, but Jack Hammers, at the
/// order's target.
pub fn launchMissile(ctx: Context, index: u16) void {
    launchFrom(ctx, index, false);
}

/// `0x0040B990`: the update of order 3, which the game names nothing, likewise for a Jack Hammer,
/// which the Fight order never launches.
pub fn launchJackHammer(ctx: Context, index: u16) void {
    launchFrom(ctx, index, true);
}

fn launchFrom(ctx: Context, index: u16, jack_hammer: bool) void {
    const slot = &ctx.world.objects.slots[index];
    const ship = &slot.object;
    for (ship.fittedRacks(), 0..) |rack, at| {
        if (rack.count < 1 or (rack.type == .jack_hammer) != jack_hammer) continue;
        missiles.launch(ctx.world, index, at, slot.orders[0].target);
        return;
    }
}

// --- Disrupted ------------------------------------------------------------------------------

/// What a Havoc's shockwave leaves in Disrupted's data (`shockwave.Shockwave.strike`): how many
/// ticks the ship is disrupted for, and the push it takes.
pub const DisruptedData = extern struct {
    ticks: i32 align(2),
    push: [3]f32 align(2),

    comptime {
        assert(@offsetOf(DisruptedData, "ticks") == 0x0);
        assert(@offsetOf(DisruptedData, "push") == 0x4);
        assert(@sizeOf(DisruptedData) == @sizeOf(aigeneric.Entry.Data));
    }
};

/// What Disrupted keeps in `order_state`: the tick it ends at, where Explode keeps its own.
pub const DisruptedState = extern struct {
    _unknown_00: u32,
    end: i32,
    _unknown_08: [0x88]u8,

    comptime {
        assert(@offsetOf(DisruptedState, "end") == 0x4);
        assert(@sizeOf(DisruptedState) == 0x90);
    }
};

/// The spread of the knock to each of a disrupted ship's rates, centred on nothing: 0.05 either
/// way, in radians a step (`0x004DC420`, the word `spin_input` reads).
const disrupted_spin: f32 = 0.1;

/// How many electric rays play over a disrupted ship (`0x0040C356`).
const disrupted_rays = 15;

/// One of the rays over a disrupted ship (`0x0040C251` to `0x0040C25D`): 90 either way, straying
/// by up to 0.6 of its length, flickering and dimming as it goes dark, and lasting `ticks`, as long
/// as the order.
fn disruptedRay(ticks: i32) erayfx.Spec {
    return .{ .life = ticks, .jitter = 0.6, .width = 90, .flags = .{ .flickers = true, .fades = true, .timed = true } };
}

/// The colours of the rays over a disrupted ship, white and blue in turn (`0x0040C277` to
/// `0x0040C28F`).
const disrupted_colours = [2][3]f32{ .{ 0.8, 0.8, 1 }, .{ 0.3, 0.5, 1 } };

/// `order_disrupted_init` (`0x0040C140`): the init of Disrupted (114). The ship is left unpowered
/// until the tick its data counts to, takes the push in its data, and has each rate knocked by up
/// to 0.05 either way, at random, which it tumbles by.
///
/// **Quirk:** the push is given in the world's frame and taken in the ship's own
/// (`gameobj.knockLocal`), so the ship is thrown off at a turn from straight away from the blast.
///
/// Fifteen electric rays play over it meanwhile (`disrupted_rays`), each from its centre out to
/// its radius at random (`disruptedRay`, `disrupted_colours`).
pub fn disruptedInit(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const object = &slot.object;
    const data = slot.orders[0].data.disrupted;
    object.flags.unpowered = true;
    slot.state.disrupted.end = data.ticks + ctx.world.clock.frame_start;
    gameobj.knockLocal(object, data.push, @splat(0));
    const random = ctx.world.random;
    object.yaw_rate += random.centred() * disrupted_spin;
    object.pitch_rate += random.centred() * disrupted_spin;
    object.roll_rate += random.centred() * disrupted_spin;
    object.rotation = math.fromAngles(object.pitch_rate, object.yaw_rate, object.roll_rate);
    const rays = ctx.world.rays orelse return;
    const spec = disruptedRay(data.ticks);
    for (0..disrupted_rays) |n| {
        const ray = rays.add(spec, random) catch return;
        ray.colour(0, disrupted_colours[n % 2]);
        const turn = math.fromAngleVector(random.fractionVector(@splat(std.math.tau)));
        ray.to = math.transform(turn, .{ 0, 0, object.radius });
        ray.hang(.{ .object = index });
        ray.owner = index;
    }
}

/// `order_disrupted` (`0x0040C370`): the update of Disrupted, which pops past its end.
pub fn disrupted(ctx: Context, index: u16) void {
    if (ctx.world.objects.slots[index].state.disrupted.end < ctx.world.clock.frame_start) aigeneric.end(ctx, index);
}

/// `order_disrupted_exit` (`0x0040C390`): the exit of Disrupted, which powers the ship again.
pub fn disruptedExit(ctx: Context, index: u16) void {
    ctx.world.objects.slots[index].object.flags.unpowered = false;
}

// --- Make capship list ----------------------------------------------------------------------

/// Which way a capital ship struck by a torpedo lurches: Make capship list left (115) or right
/// (116), whose updates `order_make_capship_list_left` (`0x0040C4B0`) and
/// `order_make_capship_list_right` (`0x0040C4C0`) hand `capship_list` -1 or 1.
pub const Lurch = enum(i8) {
    left = -1,
    right = 1,

    pub fn order(lurch: Lurch) Order {
        return switch (lurch) {
            .left => .make_capship_list_left,
            .right => .make_capship_list_right,
        };
    }
};

/// What Make capship list left and right (115, 116) keep (`capship_list`, `0x0040C3A0`): the step
/// the lurch has come to, and the tick its step ends.
pub const ListState = extern struct {
    step: ListStep,
    until: i32,
    _unknown_08: [0x90 - 0x08]u8,

    comptime {
        assert(@offsetOf(ListState, "until") == 0x04);
        assert(@sizeOf(ListState) == 0x90);
    }
};

/// Make capship list's steps, from the first (`firstStepInit`).
pub const ListStep = enum(i32) {
    /// It turns by the first of `lurch_steps`.
    first = 0,
    /// Once the first is over, it turns back by the second.
    second = 1,
    /// It waits for the second to be over.
    settling = 2,
    /// It stops rolling, and the order ends.
    done = 3,
    _,
};

/// A step of a capital ship's lurch: the roll and the yaw it turns at, a tick, toward the side it
/// lurches, and the ticks the step lasts.
const LurchStep = struct { roll: f32, yaw: f32, ticks: i32 };

/// How a capital ship lurches as a torpedo strikes it: its first step's roll and yaw
/// (`0x004DC518`, `0x004DC514`), then its second's, back the other way (`0x004DC510`,
/// `0x004DC50C`); the ticks are the code's own.
const lurch_steps = [2]LurchStep{
    .{ .roll = 0.01, .yaw = 0.006, .ticks = 200 },
    .{ .roll = -0.006, .yaw = -0.0048, .ticks = 300 },
};

/// `capship_list` (`0x0040C3A0`), the update of Make capship list left and right (115, 116), which
/// a capital ship takes as a torpedo strikes it (`collision`), a step at a time (`ListStep`): it
/// rolls and yaws toward `side` by the first of `lurch_steps`, each over its own rates, for that
/// step's ticks, then back by the second for its ticks, then stops rolling and the order ends.
pub fn capshipList(ctx: Context, index: u16, side: Lurch) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.list;
    const now = ctx.world.clock.frame_start;
    const flight = slot.flight orelse return;
    switch (state.step) {
        .first => lurchBy(slot, flight, side, lurch_steps[0], .second, now),
        .second => if (state.until <= now) lurchBy(slot, flight, side, lurch_steps[1], .settling, now),
        .settling => if (state.until <= now) {
            state.step = .done;
        },
        .done => {
            slot.object.roll_input = 0;
            aigeneric.end(ctx, index);
        },
        _ => {},
    }
}

/// A step of the lurch, from `now`: the ship turns by `turn` toward `side`, each over its own
/// rate, and its order goes on to `next` once the step's ticks are over.
fn lurchBy(slot: *create.Slot, flight: *const create.FlightModel, side: Lurch, turn: LurchStep, next: ListStep, now: i32) void {
    const way: f32 = @floatFromInt(@intFromEnum(side));
    slot.object.roll_input = turn.roll * way / flight.roll_rate;
    slot.object.yaw_input = turn.yaw * way / flight.yaw_rate;
    slot.state.list.step = next;
    slot.state.list.until = now + turn.ticks;
}

// --- Orders 44 and 45 -----------------------------------------------------------------------

/// `order_immediately_set_ship_to_zero_velocity_and_rotation` (`0x0040C4D0`): the update of order
/// 44, which stops the ship dead and pops.
pub fn zeroVelocity(ctx: Context, index: u16) void {
    ai.stop(&ctx.world.objects.slots[index].object);
    aigeneric.end(ctx, index);
}

/// The throttle Fly Ship Backwards flies at, which is reverse thrust (`0x0040C510`).
const backwards_throttle: f32 = -0.5;

/// `order_fly_ship_backwards` (`0x0040C4E0`): the update of order 45, which backs the ship up
/// without turning.
pub fn flyBackwards(ctx: Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    object.holdTurns();
    object.throttle = backwards_throttle;
}

test disruptedInit {
    const gpa = std.testing.allocator;
    var rays: erayfx.testing.Built = try .init(gpa);
    defer rays.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var ctx = mission.orders();
    ctx.world.rays = &rays.rays;
    const index = try mission.add(.predator, @splat(0));
    const slot = mission.slot(index);
    slot.object.radius = 50;
    slot.orders[0].data = .{ .disrupted = .{ .ticks = 300, .push = @splat(0) } };

    // Unpowered until its data runs out, with fifteen rays out from its centre to its radius,
    // white and blue in turn, lasting as long.
    disruptedInit(ctx, index);
    try std.testing.expect(slot.object.flags.unpowered);
    for (rays.rays.slots[0..disrupted_rays], 0..) |made, n| {
        const ray = made.?;
        try std.testing.expectEqual(index, ray.owner);
        try std.testing.expectEqual(300, ray.life);
        try std.testing.expect(ray.flags.flickers and ray.flags.fades and ray.flags.timed);
        try std.testing.expectApproxEqAbs(50, math.length(ray.to), 1e-3);
        try std.testing.expectEqual(disrupted_colours[n % 2], ray.light.colour);
    }
    try std.testing.expectEqual(null, rays.rays.slots[disrupted_rays]);
}

test disrupted {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const index = try mission.addOther(@splat(0));
    const slot = mission.slot(index);
    try std.testing.expect(try aigeneric.push(ctx, index, .disrupted, .none));
    slot.orders[0].data = .{ .disrupted = .{ .ticks = 300, .push = @splat(0) } };

    // Started at tick 50, it leaves the ship unpowered to tick 350, which it still holds at.
    mission.clock.frame_start = 50;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(350, slot.state.disrupted.end);
    try std.testing.expect(slot.object.flags.unpowered);
    mission.clock.frame_start = 350;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(1, slot.object.order_count);
    try std.testing.expect(slot.object.flags.unpowered);
    // Past it, the order pops, and its exit powers the ship again.
    mission.clock.frame_start = 351;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expect(!slot.object.flags.unpowered);
}

test capshipList {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.mammoth, .{ 0, 0, 10000 });
    const object = &mission.slot(ship).object;
    const flight = mission.slot(ship).flight.?;
    try std.testing.expect(try aigeneric.push(ctx, ship, Lurch.left.order(), .none));
    const first = lurch_steps[0];
    const second = lurch_steps[1];

    // It rolls and yaws to the left for 200 ticks, then back for 300, then stops rolling and the
    // order ends.
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(-first.roll / flight.roll_rate, object.roll_input);
    try std.testing.expectEqual(-first.yaw / flight.yaw_rate, object.yaw_input);
    mission.clock.frame_start = first.ticks - 1;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(-first.roll / flight.roll_rate, object.roll_input);
    mission.clock.frame_start = first.ticks;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(-second.roll / flight.roll_rate, object.roll_input);
    try std.testing.expectEqual(-second.yaw / flight.yaw_rate, object.yaw_input);
    mission.clock.frame_start = first.ticks + second.ticks;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(ListStep.done, mission.slot(ship).state.list.step);
    try std.testing.expectEqual(1, object.order_count);
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(0, object.roll_input);
    try std.testing.expectEqual(0, object.order_count);
}

test doNothing {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const index = try mission.add(.predator, @splat(0));
    const ctx = mission.orders();

    all.slots[index].object.throttle = 1;
    all.slots[index].object.yaw_input = 1;
    doNothing(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.throttle);
    try std.testing.expectEqual(0, all.slots[index].object.yaw_input);
}

test fly {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 30000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .fly, other, null));

    // Starting it keeps the heading, and with no speed of its own it flies at full throttle.
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(1, all.slots[index].state.fly.heading.z);
    try std.testing.expectEqual(1, all.slots[index].object.throttle);
    // It steers at its target, which lies dead ahead, so it holds its course.
    try std.testing.expectApproxEqAbs(0, all.slots[index].object.yaw_input, 1e-6);

    // A speed in its data is a share of the cruise speed, which is 320 for the test's stats.
    all.slots[index].orders[0].data.fly = 160;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(0.5, all.slots[index].object.throttle, 1e-6);

    // Within reach of the target it stops and pops.
    objects.setPosition(&all.slots[other].object, &all.slots[other].drawn, .{ 0, 0, 1500 });
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.throttle);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);

    // A target past the objects is none, so it holds the heading it started on.
    try std.testing.expect(try aigeneric.push(ctx, index, .fly, .at(gameobj.max_objects, null)));
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(1, all.slots[index].object.order_count);
    try std.testing.expectEqual(1, all.slots[index].object.throttle);
    try std.testing.expectApproxEqAbs(0, all.slots[index].object.yaw_input, 1e-6);
}

test "Fly without a target holds the heading it started on" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    objects.setOrientation(&slot.object, &slot.drawn, math.rotation(.y, std.math.pi / 2.0));
    try std.testing.expect(try aigeneric.push(ctx, index, .fly, .none));
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(1, slot.state.fly.heading.x, 1e-6);
    // The heading is where it points, so it steers straight on.
    try std.testing.expectApproxEqAbs(0, slot.object.yaw_input, 1e-6);
    try std.testing.expectEqual(1, slot.object.order_count);
}

test "Fly moves an object with no flight stats, and glides it between the ticks" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const slot = &all.slots[index];
    slot.flight = null;
    try std.testing.expect(try aigeneric.push(ctx, index, .fly, .none));
    slot.orders[0].data.fly = 100;
    // Placed on by its speed for the ticks the frame spans, and gliding that much a tick.
    mission.clock.frame_duration = 2;
    aigeneric.objectOrders(ctx, index);
    const per_tick = 100 * drift_per_tick;
    try std.testing.expectApproxEqAbs(2 * per_tick, slot.object.root.position.z, 1e-4);
    try std.testing.expectApproxEqAbs(per_tick, slot.glide[2], 1e-6);
}

test "a ship under a Fly order closes on its target and stops there" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const target = try mission.addOther(.{ 8000, 0, 30000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .fly, target, null));
    const slot = &all.slots[index];
    const to = all.slots[target].object.nextPosition();
    const start = math.distance(gameobj.vector(slot.object.root.position), to);

    // A frame of orders, then the step that moves what they steer, as the loop paces them.
    for (0..2000) |_| {
        mission.clock.frame_duration = 4;
        aigeneric.ordersUpdate(ctx);
        create.objectsUpdate(ctx.world);
        for (all.slots[0..all.count]) |*live| {
            gameobj.updateTree(&live.object.root, null, null);
            live.drawn = .{ .position = gameobj.vector(live.object.root.position), .orientation = live.object.root.orientation };
        }
        if (slot.object.order_count == 0) break;
    }

    // It flew there, and stopped once it arrived: the order popped and the throttle is off.
    const reached = math.distance(gameobj.vector(slot.object.root.position), to);
    try std.testing.expect(reached < start / 10);
    try std.testing.expect(reached < fly_reach);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(0, slot.object.throttle);
}

test matchSpeed {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 5000 });
    all.slots[other].object.flags.targetable = true;
    all.slots[other].object.speed = 160;
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .match_speed, other, null));

    aigeneric.objectOrders(ctx, index);
    try std.testing.expectApproxEqAbs(0.5, all.slots[index].object.throttle, 1e-6);

    // Once the target can no longer be aimed at, it pops.
    all.slots[other].object.flags.exploding = true;
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);
}

test randomSpinInit {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const object = &all.slots[index].object;
    object.throttle = 1;
    randomSpinInit(ctx, index, .fast);
    try std.testing.expectEqual(0, object.throttle);
    for ([_]f32{ object.pitch_input, object.roll_input, object.yaw_input }) |turn| {
        try std.testing.expect(turn >= spin_input and turn <= spin_input + Spin.fast.spread());
    }
    // A slower spin never turns as fast as the fastest can.
    randomSpinInit(ctx, index, .slow);
    try std.testing.expect(object.yaw_input <= spin_input + Spin.slow.spread());
}

test runAway {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const ctx = mission.orders();

    const index = try mission.addOther(@splat(0));
    const other = try mission.addOther(.{ 0, 0, 5000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, index, .run_away, other, null));

    // The target lies ahead, so it turns away from it and flies at half throttle.
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(run_away_throttle, all.slots[index].object.throttle);
    try std.testing.expect(@abs(all.slots[index].object.yaw_input) > 0 or @abs(all.slots[index].object.roll_input) > 0);

    // A slot that has gone back to standing in is nothing to run from.
    all.resetSlot(other, &mission.random);
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);

    // Nor is an index past the objects.
    try std.testing.expect(try aigeneric.push(ctx, index, .run_away, .at(gameobj.max_objects, null)));
    aigeneric.objectOrders(ctx, index);
    try std.testing.expectEqual(0, all.slots[index].object.order_count);
}

test "Run Away moves its point round what lies near before it steers" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const world = ctx.world;
    // A ship at the origin, running from a target behind it toward a hull ahead, and turning.
    const ship = try mission.addOther(@splat(0));
    const target = try mission.addOther(.{ 0, 0, -5000 });
    _ = try ai.testing.hullAhead(&mission, ship, .{ 0, 0, 5000 });
    const slot = mission.slot(ship);
    slot.object.pitch_rate = 0.02;
    slot.object.yaw_rate = 0.005;

    // The point far beyond the ship moves onto the hull's box, where the steering's own pass finds
    // nothing more to go round, so the ship keeps its ease.
    const from = slot.object.nextPosition();
    var point = from + (from - mission.slot(target).object.nextPosition()) * @as(Vector, @splat(run_away_ahead));
    try std.testing.expect(ai.avoidNear(world, ship, &point));
    var again = point;
    try std.testing.expect(!ai.avoidNear(world, ship, &again));
    const saved = slot.*;
    _ = ai.steer(world, ship, point, ai.full_limit, run_away_ease, .clear);
    const steered: Vector = .{ slot.object.pitch_input, slot.object.yaw_input, slot.object.roll_input };
    slot.* = saved;

    // Run Away turns the ship as steering at that point does.
    try std.testing.expect(try aigeneric.pushShip(ctx, ship, .run_away, target, null));
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(steered, Vector{ slot.object.pitch_input, slot.object.yaw_input, slot.object.roll_input });
    try std.testing.expectEqual(run_away_throttle, slot.object.throttle);
}

test launchMissile {
    var armed: missiles.testing.Armed = undefined;
    try armed.init(std.testing.allocator);
    defer armed.deinit();
    const ship = try armed.add(.hostile, @splat(0));
    const target = try armed.add(.friendly, .{ 0, 0, 20000 });
    armed.mission.slot(ship).orders[0] = .{ .order = .launch_missile, .target = .at(target, null), .sequence = 0, .data = .{ .words = @splat(0) } };
    const ctx = armed.mission.orders();
    // The first rack with missiles, the Raptor pod, at the order's target.
    launchMissile(ctx, ship);
    try std.testing.expectEqual(missiles.Type.raptor, armed.missile(0).type);
    try std.testing.expectEqual(@as(i16, @intCast(target)), armed.missile(0).target.index);
    // The fixture carries no Jack Hammer.
    launchJackHammer(ctx, ship);
    try std.testing.expectEqual(1, armed.live());
}

test Pick {
    var pick: Pick = .none;
    try std.testing.expectEqual(null, pick.kept());
    // The lightest offered is kept: a component of a ship, or a ship whole.
    pick.offer(.at(3, 2), 100);
    try std.testing.expectEqual(aigeneric.Target.at(3, 2), pick.kept().?);
    pick.offer(.at(5, null), 50);
    try std.testing.expectEqual(aigeneric.Target.at(5, null), pick.kept().?);
    // One that weighs as much or more is passed over.
    pick.offer(.at(7, null), 50);
    pick.offer(.at(8, 1), 60);
    try std.testing.expectEqual(aigeneric.Target.at(5, null), pick.kept().?);
}

test EscortState {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var state = std.mem.zeroes(EscortState);
    // None, a slot, and an index past the objects.
    state.escorted = -1;
    try std.testing.expectEqual(null, state.escortedIn(mission.objects));
    state.escorted = 7;
    try std.testing.expectEqual(7, state.escortedIn(mission.objects));
    state.escorted = gameobj.max_objects;
    try std.testing.expectEqual(null, state.escortedIn(mission.objects));
}

/// A mission for the tests of the orders that walk a flight group: `count` ships, the last
/// `in_group` of them in flight group 0 and the rest in none, which the world's mission binds.
const GroupMission = struct {
    game: @import("../vm.zig").machine.testing.Game,

    fn init(mission: *GroupMission, comptime count: usize, in_group: usize) !void {
        const dte = @import("../../formats/dte.zig");
        const records = dte.testing;
        var ships = records.ships(count, 0);
        for (ships[count - in_group ..]) |*ship| ship.flight_group = 0;
        var kinds: [count + 1]dte.Object = @splat(records.object(.ship, 0, 0));
        kinds[count].kind = .flight_group;
        try mission.game.init(std.testing.allocator, &.{}, .{ .ships = &ships, .flight_groups = &.{records.flightGroup(count, .player)}, .objects = &kinds });
    }

    const group: aigeneric.Target = .group(.flight_group, 0);
};

test "Find New Target fights what it may, mills round the rest, and pops with none" {
    var mission: GroupMission = undefined;
    try mission.init(6, 3);
    defer mission.game.deinit();
    const game = &mission.game.mission;
    const ctx = mission.game.orders();
    // A fighter at the origin, a Predator that fights, and the flight group of three ahead, the
    // nearest fought by two others already and the next cloaked.
    const searcher = try game.addOther(@splat(0));
    const other = try game.add(.predator, .{ 0, 0, -5000 });
    const near = try game.add(.predator, .{ 0, 0, 10000 });
    const cloaked = try game.add(.predator, .{ 0, 0, 20000 });
    const far = try game.add(.predator, .{ 0, 0, 30000 });
    for ([_]u16{ near, cloaked, far }) |index| game.slot(index).object.flags.targetable = true;
    game.slot(cloaked).object.flags.cloaked = true;
    try std.testing.expectEqual(.fighter, game.slot(searcher).combat.?.class);
    for ([_]u16{ 0, other }) |index| {
        _ = try aigeneric.pushShip(ctx, index, .fight, near, null);
    }

    // It fights the farthest, the one it may.
    _ = try aigeneric.push(ctx, searcher, .find_new_target, GroupMission.group);
    findNewTarget(ctx, searcher);
    const fought = game.slot(searcher).orders[0];
    try std.testing.expectEqual(Order.fight, fought.order);
    try std.testing.expectEqual(far, fought.target.slot());

    // With that one set aside, it mills round the least crowded for its distance: the nearest.
    _ = aigeneric.pop(ctx, searcher);
    game.slot(searcher).object.set_aside = .of(far);
    game.slot(searcher).object.set_aside_until = 1000;
    findNewTarget(ctx, searcher);
    const milled = game.slot(searcher).orders[0];
    try std.testing.expectEqual(Order.mill, milled.order);
    try std.testing.expectEqual(near, milled.target.slot());

    // Once none can be aimed at, it pops.
    _ = aigeneric.pop(ctx, searcher);
    for ([_]u16{ near, cloaked, far }) |index| game.slot(index).object.flags.targetable = false;
    findNewTarget(ctx, searcher);
    try std.testing.expectEqual(0, game.slot(searcher).object.order_count);
}

test "Find Scoop Up scoops up the nearest it may, one after another, and pops with none" {
    var mission: GroupMission = undefined;
    try mission.init(5, 3);
    defer mission.game.deinit();
    const game = &mission.game.mission;
    const ctx = mission.game.orders();
    // A ship at the origin, and the flight group of three ahead: the farthest, an ejected one
    // nearer, and the nearest cloaked.
    const searcher = try game.addOther(@splat(0));
    const far = try game.add(.predator, .{ 0, 0, 20000 });
    const ejected = try game.add(.predator, .{ 0, 0, 10000 });
    const cloaked = try game.add(.predator, .{ 0, 0, 5000 });
    for ([_]u16{ far, ejected, cloaked }) |index| game.slot(index).object.flags.targetable = true;
    game.slot(ejected).object.flags.ejected = true;
    game.slot(cloaked).object.flags.cloaked = true;

    // Each time the order starts, its first update goes from the wait to the search, and the next
    // scoops up the ejected one, then once that is gone the farthest.
    _ = try aigeneric.push(ctx, searcher, .find_scoop_up, GroupMission.group);
    const slot = game.slot(searcher);
    for ([_]u16{ ejected, far }) |scooped| {
        aigeneric.objectOrders(ctx, searcher);
        try std.testing.expectEqual(Order.find_scoop_up, slot.orders[0].order);
        try std.testing.expectEqual(.search, slot.state.find_scoop_up.step);
        findScoopUp(ctx, searcher);
        try std.testing.expectEqual(Order.scoop_up, slot.orders[0].order);
        try std.testing.expectEqual(scooped, slot.orders[0].target.slot());
        game.slot(scooped).object.flags.targetable = false;
        _ = aigeneric.pop(ctx, searcher);
    }
    // With none left to aim at, it pops.
    aigeneric.objectOrders(ctx, searcher);
    findScoopUp(ctx, searcher);
    try std.testing.expectEqual(0, slot.object.order_count);
}

test "Escort takes its place in the group, follows, and ends with its ship" {
    var mission: GroupMission = undefined;
    try mission.init(4, 2);
    defer mission.game.deinit();
    const game = &mission.game.mission;
    const ctx = mission.game.orders();
    const escort_ship = try game.addOther(@splat(0));
    const first = try game.add(.predator, .{ 0, 0, 20000 });
    _ = try game.add(.predator, .{ 0, 0, 20000 });

    // Third among the group's two, it counts round to the first.
    _ = try aigeneric.push(ctx, escort_ship, .escort, GroupMission.group);
    game.slot(escort_ship).orders[0].sequence = 2;
    aigeneric.objectOrders(ctx, escort_ship);
    try std.testing.expectEqual(first, game.slot(escort_ship).state.escort.escorted);

    // Far behind a ship flying at 320, it flies faster than that to catch up.
    const lead = game.slot(first);
    lead.object.speed = 320;
    aigeneric.objectOrders(ctx, escort_ship);
    const cruise = gameobj.testing.flight.max_speed;
    try std.testing.expectApproxEqAbs(20000 * escort_catch_up + 320 / cruise, game.slot(escort_ship).object.throttle, 1e-4);

    // Once its ship has gone, it ends.
    lead.object.type = .stand_in;
    aigeneric.objectOrders(ctx, escort_ship);
    try std.testing.expectEqual(0, game.slot(escort_ship).object.order_count);
}

test "Escort of a group with no ships escorts none" {
    var mission: GroupMission = undefined;
    try mission.init(2, 0);
    defer mission.game.deinit();
    const ctx = mission.game.orders();
    const escort_ship = try mission.game.mission.addOther(@splat(0));
    _ = try aigeneric.push(ctx, escort_ship, .escort, GroupMission.group);
    aigeneric.objectOrders(ctx, escort_ship);
    try std.testing.expectEqual(0, mission.game.mission.slot(escort_ship).object.order_count);
}

test "Mill circles its target for a while" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const ship = try mission.addOther(@splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 60000 });
    mission.slot(target).object.flags.targetable = true;
    _ = try aigeneric.pushShip(ctx, ship, .mill, target, null);
    aigeneric.objectOrders(ctx, ship);
    // Its circle faces from the target back to the ship, and it flies at full throttle.
    const state = &mission.slot(ship).state.mill;
    try std.testing.expectApproxEqAbs(-1, math.forward(state.circle)[2], 1e-5);
    try std.testing.expectEqual(ai.full_throttle, mission.slot(ship).object.throttle);
    // After its time is up, it ends.
    mission.clock.frame_start = mill_ticks + 1;
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(0, mission.slot(ship).object.order_count);
}

test "Fly Aimlessly flies its figure from where it began, a point at a time" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const ship = try mission.addOther(.{ 0, 0, 5000 });
    _ = try aigeneric.push(ctx, ship, .fly_aimlessly, .none);
    aigeneric.objectOrders(ctx, ship);
    const slot = mission.slot(ship);
    const state = &slot.state.aimless;
    try std.testing.expect(state.figure >= 1 and state.figure <= aimless_figures);
    try std.testing.expectEqual(Vector{ 0, 0, 5000 }, gameobj.vector(state.start));
    try std.testing.expectEqual(1, state.point);
    try std.testing.expect(slot.object.throttle >= aimless_throttle and slot.object.throttle <= aimless_throttle + aimless_throttle_spread);
    // Half way round, each figure is at its widest, to the side its X axis lies; there the ship
    // flies for the next point.
    for (1..aimless_figures + 1) |figure| {
        state.figure = @intCast(figure);
        state.point = 10;
        const widest = -2 * @as(f32, @floatFromInt(figure + 1)) * aimless_side;
        slot.object.root.next_position = gameobj.vec3(math.xAxis(state.orientation) * @as(Vector, @splat(widest)) + gameobj.vector(state.start));
        flyAimlessly(ctx, ship);
        try std.testing.expectEqual(11, state.point);
    }
    // Away from that point, it flies on for it.
    flyAimlessly(ctx, ship);
    try std.testing.expectEqual(11, state.point);
}

test "Formation flies abreast of its target, on alternate sides, and ends with it" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const ship = try mission.addOther(@splat(0));
    const leader = try mission.add(.predator, .{ 0, 0, 10000 });
    mission.slot(leader).object.flags.targetable = true;
    _ = try aigeneric.pushShip(ctx, ship, .formation, leader, null);
    const slot = mission.slot(ship);
    const state = &slot.state.formation;
    // The ships numbered 0 to 3 fly one and two places out, left and right in turn.
    for ([_]i16{ 0, 1, 2, 3 }, [_]f32{ -3000, 3000, -6000, 6000 }) |sequence, x| {
        slot.orders[0].sequence = sequence;
        formationInit(ctx, ship);
        try std.testing.expectEqual(Vector{ x, 0, 0 }, gameobj.vector(state.place));
    }
    // At its place by the leader, it stops there.
    slot.object.root.next_position = .{ .x = 6000, .y = 0, .z = 10000 };
    slot.object.throttle = 1;
    formation(ctx, ship);
    try std.testing.expectEqual(formation_least_throttle, slot.object.throttle);
    // Once the leader can no longer be aimed at, it pops.
    mission.slot(leader).object.flags.targetable = false;
    formation(ctx, ship);
    try std.testing.expectEqual(0, slot.object.order_count);
}

test "Object Attach rides its target, where it stood in the target's frame" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const pod = try mission.addOther(.{ 100, 0, 1000 });
    const ship = try mission.add(.predator, .{ 0, 0, 1000 });
    const carrier = mission.slot(ship);
    const quarter = math.rotation(.y, std.math.pi / 2.0);
    objects.setOrientation(&carrier.object, &carrier.drawn, quarter);
    _ = try aigeneric.pushShip(ctx, pod, .object_attach, ship, null);
    aigeneric.objectOrders(ctx, pod);
    const offset = math.transformTransposed(quarter, .{ 100, 0, 0 });
    // Where it stood, turned as the ship is.
    try std.testing.expectEqual(Vector{ 100, 0, 1000 }, mission.slot(pod).drawn.position);
    try std.testing.expectEqual(quarter, mission.slot(pod).drawn.orientation);
    // The ship moves on and turns back: the pod keeps its place in the ship's frame, and moves
    // with it.
    carrier.object.root.next_position = .{ .x = 0, .y = 0, .z = 5000 };
    carrier.object.root.next_orientation = math.identity;
    carrier.object.velocity = .{ .x = 0, .y = 0, .z = 50 };
    carrier.object.speed = 50;
    aigeneric.objectOrders(ctx, pod);
    const at = mission.slot(pod).drawn.position;
    const expected = offset + Vector{ 0, 0, 5000 };
    try math.testing.expectVectorWithin(expected, at, 1e-3);
    try std.testing.expectEqual(50, mission.slot(pod).object.velocity.z);
    try std.testing.expectEqual(50, mission.slot(pod).object.speed);
}

test toggleCloak {
    const gpa = std.testing.allocator;
    var stage: cloak.testing.Cloaked = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    // A ship that can cloak, uncloaked, cloaks.
    toggleCloak(stage.mission.orders(), stage.index);
    try std.testing.expect(stage.slot().object.flags.cloaked);
}
