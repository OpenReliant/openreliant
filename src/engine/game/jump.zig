//! `C:\lancer\game\jump.cpp`: the jumps by which ships come and go. Jump Out (orders 20 and 41)
//! takes a ship away: it turns to where it goes, holds still while its jump charges, and is gone.
//! Where its order names another object, Jump In (orders 19 and 40) then brings it in beside that
//! object, flying in from far behind it. [Jumps](../../../docs/engine/jump.md) describes them.
//!
//! The orders are this file's by the assertion `order_jump_in` makes with its path (`0x004165EC`),
//! which the source map misses, as it lies in a case of a switch
//! ([#310](https://github.com/vdmkenny/openreliant/issues/310)).
//!
//! What a jump shows, the trails, the lights, the burst and the flare of its effect record, is
//! [`jump/effect.zig`](jump/effect.zig)'s.
//!
//! Left out: the countdown Jump Out keeps while the player's ship jumps, which nothing reads
//! (`jump_player_going`, `0x0051D0B0`; `jump_countdown`, `0x0051D0B4`; `jump_countdown_next`,
//! `0x0051CFA0`; `jump_countdown_step`, `0x0051D0A4`).
//!
//! Not ported: a multiplayer game's jumps
//! ([#55](https://github.com/vdmkenny/openreliant/issues/55)).

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("../../engine.zig");
const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Order = @import("ai/orders.zig").Order;
const camera = @import("camera.zig");
const cloak = @import("cloak.zig");
const create = @import("create.zig");
const events = @import("mission/events.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const sound3d = @import("sound3d.zig");

pub const effect = @import("jump/effect.zig");

const log = std.log.scoped(.jump);

/// What a jump keeps in the object's order state.
pub const State = extern struct {
    _unknown_00: u32,
    /// Its step: Jump Out's or Jump In's.
    step: Step,
    /// The frame's tick its step began, from which the jump motions count.
    since: i32,
    /// Where it goes: Jump Out's destination, Jump In's arrival (`placeOut`, `placeIn`).
    destination: shp.Vec3,
    /// How it is turned: Jump Out's as it charges, to which it turns back as it ends; Jump In's its
    /// target's.
    orientation: math.Matrix,
    /// Where it stood as Jump Out began charging, and as Jump In was placed.
    position: shp.Vec3,
    _unknown_48: [8]u8,
    /// The frame's tick of its last update, from which `progress` counts.
    updated: i32,
    /// How far through its step it is, from 0 to past 1.
    progress: f32,
    /// How many lights its effect has (`jump_effect_start`), which the lights' sweep along the hull
    /// reads (`effect.Effect.chargeLights`).
    lights: i32,
    /// Where Jump Out's motion takes it from and to (`motion.Motion.jump_out`).
    from: shp.Vec3,
    to: shp.Vec3,
    /// The motion it puts aside while it flies its own: the routine's address, which OpenReliant
    /// keeps as `create.Slot.motion_aside`.
    motion: engine.Pointer(gameobj.Routine),
    /// Its effect record (`jump_effects`, `0x0051CFA4`): its trails, lights, burst and flare.
    /// OpenReliant keeps the record's place among them, from 1 (`effectPlace`).
    effect: engine.Pointer(effect.Record),
    /// Whether it jumps out with the player's ship, in formation behind it (`placeOut`).
    with_player: bool,
    _unknown_7d: [3]u8,
    _unknown_80: [0x90 - 0x80]u8,

    comptime {
        assert(@offsetOf(State, "step") == 0x04);
        assert(@offsetOf(State, "since") == 0x08);
        assert(@offsetOf(State, "destination") == 0x0C);
        assert(@offsetOf(State, "orientation") == 0x18);
        assert(@offsetOf(State, "position") == 0x3C);
        assert(@offsetOf(State, "updated") == 0x50);
        assert(@offsetOf(State, "progress") == 0x54);
        assert(@offsetOf(State, "lights") == 0x58);
        assert(@offsetOf(State, "from") == 0x5C);
        assert(@offsetOf(State, "to") == 0x68);
        assert(@offsetOf(State, "motion") == 0x74);
        assert(@offsetOf(State, "effect") == 0x78);
        assert(@offsetOf(State, "with_player") == 0x7C);
        assert(@sizeOf(State) == 0x90);
    }

    /// Moves on to `step`, `progress` from nothing.
    fn next(state: *State, step: Step) void {
        state.step = step;
        state.progress = 0;
    }

    /// Moves on to `step` at `now`, `progress` from nothing.
    fn advance(state: *State, step: Step, now: i32) void {
        state.next(step);
        state.since = now;
    }

    /// Its effect record's place among `jump_effects`, where it has one: `effect` counts from 1,
    /// with 0 for none, which wraps past what a place can be.
    fn effectPlace(state: *const State) ?u8 {
        return std.math.cast(u8, @intFromEnum(state.effect) -% 1);
    }

    /// Keeps `place` as its effect record's, or none.
    fn keepEffect(state: *State, place: ?u8) void {
        state.effect = if (place) |kept| @enumFromInt(@as(u32, kept) + 1) else .null;
    }
};

/// A jump's effect record, with the records' shared meshes and textures that its steps start and
/// shade it by.
const Fx = struct {
    effects: *effect.Effects,
    record: *effect.Effect,
};

/// The jump's effect record, where it has one.
fn effectOf(world: gameobj.World, state: *const State) ?Fx {
    const effects = world.jump_effects orelse return null;
    const record = effects.get(state.effectPlace() orelse return null) orelse return null;
    return .{ .effects = effects, .record = record };
}

/// `jump_effect_alloc` (`0x00418900`) for the jump of the ship in slot `index`.
///
/// **Fix:** the game stops with "Jump has overrun array." where all the records are taken;
/// OpenReliant's jump goes on without one.
fn takeEffect(world: gameobj.World, state: *State, index: u16) ?Fx {
    state.keepEffect(null);
    const effects = world.jump_effects orelse return null;
    const place = effects.alloc(index) catch null orelse {
        log.warn("every jump's effect record is taken: this jump shows nothing", .{});
        return null;
    };
    state.keepEffect(place);
    return .{ .effects = effects, .record = effects.get(place) orelse return null };
}

/// `jump_effect_free` (`0x004189A0`), as the jump ends.
fn freeEffect(world: gameobj.World, state: *State) void {
    const effects = world.jump_effects orelse return;
    if (state.effectPlace()) |place| effects.free(place);
    state.keepEffect(null);
}

/// What the jump's update adds to the scene this frame, on top of what it added already.
fn show(fx: ?Fx, what: effect.Shown) void {
    const held = fx orelse return;
    held.record.shown = held.record.shown.with(what);
}

/// A jump's step, in the word the game keeps it in: Jump Out's or Jump In's.
pub const Step = extern union {
    out: OutStep,
    in: InStep,
};

/// Jump Out's steps.
pub const OutStep = enum(u32) {
    /// Turning to face where it goes, or holding its place behind the player's ship.
    aligning = 0,
    /// Held still until the next frame, when its effect begins.
    stilling = 1,
    /// Charging (`charge_rate`).
    charging = 2,
    /// Going: its motion takes it off (`motion.Motion.jump_out`) for `going_ticks`.
    going = 3,
    /// Gone: its flare fades (`flare_rate`).
    gone = 4,
    /// Its end: it jumps in at its target, or leaves the mission.
    ending = 5,
    _,
};

/// Jump In's steps.
pub const InStep = enum(u32) {
    /// Placed far behind where it arrives.
    placing = 0,
    /// Flashing in (`flash_rate`).
    flashing = 1,
    /// Flying in (`motion.Motion.jump_in`), until `fly_rate` has run.
    flying = 2,
    /// In: its order ends, or Jump In's second number first holds it `settle_ticks` in formation.
    settling = 3,
    _,
};

/// How still a ship turning to face where it jumps must be before it goes: its steering inputs
/// (`0x004DC4AC`) and its rates (`0x004DC474`) within these, its throttle not counted.
const aligned: ai.Stillness = .{ .inputs = 0.02, .rates = 0.05 };

/// How hard it steers to face where it jumps (`0x004DC410`).
const aligning_limit: f32 = 0.8;

/// How long a ship of the player's wing turns to face its jump before it goes anyway, and how long
/// a ship jumping with the player's holds its place, in ticks (`0x00416EE8`, `0x00416EBE`).
const wing_patience = 1000;
const formation_wait = 100;

/// How fast Jump Out charges, and how fast its effect fades as it goes (`0x004DC400`,
/// `0x004DC424`).
const charge_rate: f32 = 6;
const going_rate: f32 = 4;

/// How long Jump Out's motion takes the ship off, in ticks (`0x004DC448`), which the motion's
/// pace matches (`motion.jump_out_pace`).
pub const going_ticks = 250;

/// How fast Jump Out's flare fades once the ship has gone (`0x004DC520`).
const flare_rate: f32 = 10;

/// How far along its way a ship goes as Jump Out's motion takes it off (`jump_effect_start`,
/// `0x0041771F`).
const going_reach: f32 = 500000;

/// How far ahead a ship aims when its Jump Out names nothing, alone, and in the player's
/// formation (`0x00418820`, `0x004185BE`).
const nowhere_reach: f32 = 1e7;
const formation_reach: f32 = 100000;

/// The player's formation (`placeOut`): rows `formation_spacing` apart behind the player's ship
/// (`0x0041866D`), each a ship wider than the last, at most `formation_rows` (`0x0041861A`), flying
/// `formation_speed` ahead (`0x004186C8` for its velocity, `0x004DC594` for its throttle); and how
/// far ahead of it a ship in its way is marked as jumping (`0x00418743`).
const formation_spacing: f32 = 3000;
const formation_rows = 10;
const formation_speed: f32 = 150;
const clearing_reach: f32 = 500000;

/// The depth a ship that leaves the mission is put at, far below everything (`0x004175E1`).
const gone_depth: f32 = -9.9e6;

/// How far behind where it arrives a ship is placed to fly in from: one that lists components, and
/// any other (`0x00416668`, `0x0041666F`, where the game pushes their negatives).
const arrival_distance_components: f32 = 100000;
const arrival_distance: f32 = 25000;

/// How fast Jump In flashes, and flies in (`0x004DC48C`, `0x004DC3D8`).
const flash_rate: f32 = 50;
const fly_rate: f32 = 3;

/// How long Jump In's second number holds its formation once in, in ticks (`0x00416C1D`).
const settle_ticks = 200;

/// The share of a steering input a ship of Jump In's second number rolls and pitches by for each
/// place along its formation (`0x004DC408`).
const settle_input: f32 = 0.5;

/// `order_jump_out_init` (`0x00416D50`): the ship in slot `index` jumps out. Its throttle goes, it
/// is placed for its jump (`placeOut`), and it is heard (`jumponline`, among the player's own
/// sounds for the player's ship, whose camera watches it from the jump's view, locked). A player's
/// ship uncloaks.
pub fn outInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.jump;
    slot.object.throttle = 0;
    state.step = .{ .out = .aligning };
    state.since = ctx.world.clock.frame_start;
    state.with_player = false;
    placeOut(ctx, index);
    sound3d.playIn(world, null, null, index, .jumponline, 1, sound3d.fxClass(all, index));
    if (index == all.player) if (world.camera) |view| {
        _ = view.setJump(.jump_out, index, ctx.world.clock.viewTime(), .of(slot), .of(slot));
    };
    if (index < all.players) cloak.set(world, index, false);
}

/// `order_jump_out` (`0x00416E00`): Jump Out's update, a step at a time (`OutStep`). Every update
/// of the player's ship clears the jump the mission has ready (`jump_ready`).
///
/// It turns to face where it goes, until its rates and inputs are still (`aligned`), a ship of the
/// player's wing no longer than `wing_patience`; one jumping with the player's holds its place for
/// `formation_wait` instead. Then it is heard (`jumpout`), and held still until the next frame,
/// when its course is set (`beginCourse`). It charges, and at full charge goes: its motion takes it
/// off, colliding with nothing, drawn at its finest (`showFinest`), for `going_ticks`. Then it
/// flies ahead again, jumping, while its flare fades, and collides again.
///
/// What it shows (`effect`): held still, trails stream back from its engines and lights stand
/// along its hull. As it charges the trails brighten and the lights come on, then are swept along
/// the hull; as it goes the lights are out and the trails fade; gone, a flare of its width stands
/// where it was, shrinking away.
///
/// At its end it is turned back as it was, powered and free to move, flies its own motion again,
/// and draws as it did. The player's jump ends every object's jumping. A jump that names another
/// object gives way to Jump In at it, of the matching number and the same place among its group;
/// one that names none leaves the mission: the ship stops jumping, is disabled, but for the
/// player's ship sent off (`GameObject.Flags.sent_off`), and is put far below where it went, its
/// order done.
///
/// Not ported: the Boridin's breakaway letting go of its core's sprite as it charges
/// ([#238](https://github.com/vdmkenny/openreliant/issues/238)).
pub fn outUpdate(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.jump;
    const now = ctx.world.clock.frame_start;
    const dt = gameobj.progressSince(&state.updated, now);
    object.nova_charge = 0;
    if (index == all.player) if (world.events) |waiting| {
        waiting.script.variables.ready.jump = .no;
    };
    switch (state.step.out) {
        .aligning => {
            if (!state.with_player) {
                _ = ai.steer(world, index, gameobj.vector(state.destination), aligning_limit, ai.no_ease, .{});
                const waited = now >= state.since + wing_patience and object.wing == .player;
                if (!waited and !aligned.holds(object, false)) return;
            } else if (now < state.since + formation_wait) return;
            state.step = .{ .out = .stilling };
            state.since = now;
            _ = takeEffect(world, state, index);
            sound3d.playIn(world, null, null, index, .jumpout, 1, sound3d.fxClass(all, index));
        },
        .stilling => {
            object.holdStill();
            object.speed = 0;
            object.rotation = math.identity;
            if (now <= state.since) return;
            beginCourse(slot);
            if (effectOf(world, state)) |held| state.lights = @intCast(held.effects.start(held.record, slot));
            state.next(.{ .out = .charging });
        },
        .charging => {
            const fx = effectOf(world, state);
            defer show(fx, .{ .trails = true, .lights = true });
            if (state.progress > 1) {
                slot.motion_aside = slot.motion;
                slot.motion = .jump_out;
                object.flags.no_collisions = true;
                state.advance(.{ .out = .going }, now);
                if (slot.model) |*model| showFinest(model, true);
                if (fx) |held| held.record.lightsOut();
                state.from = object.root.position;
                return;
            }
            if (fx) |held| {
                held.record.shadeTrails(state.progress);
                held.effects.chargeLights(held.record, state.progress);
            }
            state.progress += dt * charge_rate;
        },
        .going => {
            const fx = effectOf(world, state);
            defer show(fx, .{ .trails = true, .lights = true });
            if (state.since + going_ticks < now) {
                if (fx) |held| held.effects.startFlare(held.record, slot.drawn, object.width());
                slot.motion = .forward;
                object.flags.jumping = true;
                state.next(.{ .out = .gone });
                return;
            }
            if (fx) |held| held.record.shadeTrails(1 - state.progress);
            state.progress += dt * going_rate;
        },
        .gone => {
            const fx = effectOf(world, state);
            if (fx) |held| if (held.record.flare) |*flare| flare.grow(1 - state.progress);
            state.progress += dt * flare_rate;
            show(fx, .{ .flare = true, .trails = true, .lights = true });
            if (state.progress >= 1) {
                state.next(.{ .out = .ending });
                object.flags.no_collisions = false;
            }
        },
        .ending => end(ctx, index),
        _ => {},
    }
}

/// Jump Out's end, as `outUpdate` describes it.
fn end(ctx: aigeneric.Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.jump;
    objects.setOrientation(object, &slot.drawn, state.orientation);
    object.flags.thaw();
    slot.motion = slot.motion_aside;
    const entry = slot.orders[0];
    if (index == all.player) {
        for (all.slots[0..all.count]) |*each| each.object.flags.jumping = false;
    }
    freeEffect(ctx.world, state);
    if (slot.model) |*model| showFinest(model, false);
    if (entry.target.slotIn(all)) |target| if (target != index) {
        const next: Order = if (entry.order == .jump_out_41) .jump_in_40 else .jump_in;
        aigeneric.end(ctx, index);
        const pushed = aigeneric.giveShip(ctx, index, next, target, null);
        if (pushed) slot.orders[0].sequence = entry.sequence;
        return;
    };
    object.flags.jumping = false;
    if (index != all.player or !object.flags.sent_off) object.flags.disabled = true;
    state.destination.y = gone_depth;
    objects.setPosition(object, &slot.drawn, gameobj.vector(state.destination));
    aigeneric.end(ctx, index);
}

/// The first part of `jump_effect_start` (`0x00417670`), Jump Out's effect's start, which sets the
/// ship's course: it keeps how it is turned and where it stands, and aims its motion `going_reach`
/// along the way to its destination (`State.to`).
fn beginCourse(slot: *create.Slot) void {
    const object = &slot.object;
    const state = &slot.state.jump;
    state.orientation = object.root.orientation;
    state.position = object.root.position;
    const here = slot.drawn.position;
    const way = math.normalize(gameobj.vector(state.destination) - here);
    state.to = gameobj.vec3(way * @as(Vector, @splat(going_reach)) + here);
}

/// `model_show_finest` (`0x00417DC0`): each part of `model`, and of each model mounted on it,
/// drawn at its finest, or by its distance again (`srapiext.ObjectFlags.finest`).
fn showFinest(model: *objects.Model, finest: bool) void {
    for (model.parts, 0..) |*part, at| {
        part.object.flags.finest = finest;
        var mounts = model.carriedBy(at);
        while (mounts.next()) |mount| showFinest(&mount.model, finest);
    }
}

/// `jump_out_place` (`0x004184F0`): where the ship in slot `index` jumps out to. Where the player's
/// ship jumps out at the same target, the ship goes with it: it collides with nothing and takes its
/// place in a formation behind the player's ship, facing the target, or `formation_reach` ahead of
/// the player's ship where the order names nothing or the player's ship itself. Row `n` of the
/// formation stands `n` times `formation_spacing` behind, and holds `n` ships abreast, the order's
/// place among its group's (`aigeneric.Entry.sequence`) picking the row and the place in it. The
/// ship flies `formation_speed` ahead there, and each object in the way `clearing_reach` ahead of
/// it, but those jumping with it, is marked jumping (`markJumping`). Otherwise the ship goes to its
/// target, or `nowhere_reach` ahead of it where it names nothing or itself.
///
/// Not ported: in a multiplayer game, the formation of the player whose game it is
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn placeOut(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.jump;
    const entry = slot.orders[0];
    const player = &all.slots[all.player];
    const leading = jumpsOutAt(player, entry.target.index);
    const named = entry.target.slotIn(all);
    if (!leading) {
        if (named) |target| if (target != index) {
            state.destination = all.slots[target].object.root.next_position;
            return;
        };
        state.destination = gameobj.vec3(slot.object.placeAt(.next).ahead(nowhere_reach));
        return;
    }
    slot.object.flags.no_collisions = true;
    state.with_player = true;
    const from = player.object.nextPosition();
    // The player's ship jumps at the same target.
    const to = if (named) |target| if (target != all.player)
        all.slots[target].object.nextPosition()
    else
        player.object.placeAt(.next).ahead(formation_reach) else player.object.placeAt(.next).ahead(formation_reach);
    const facing = math.lookAt(to - from);
    state.destination = gameobj.vec3(to);
    var row: i32 = 1;
    var place: i32 = entry.sequence;
    while (row < formation_rows) : (row += 1) {
        if (place < row) {
            const across = @as(f32, @floatFromInt(place)) - (@as(f32, @floatFromInt(row)) - 1) * 0.5;
            const offset: Vector = .{ across + across, 0, @floatFromInt(-row) };
            const at = math.transform(facing, offset * @as(Vector, @splat(formation_spacing))) + from;
            objects.setPlace(&slot.object, &slot.drawn, .{ .position = at, .orientation = facing });
            ai.stop(&slot.object);
            slot.object.velocity = gameobj.vec3(math.transform(slot.object.root.next_orientation, .{ 0, 0, formation_speed }));
            if (ai.slotCruise(slot, world.view)) |cruise| slot.object.throttle = formation_speed / cruise;
            break;
        }
        place -= row;
    }
    const next = slot.object.placeAt(.next);
    const start = next.position;
    const end_at = next.ahead(clearing_reach);
    for (all.slots[0..all.count], 0..) |*other, at| {
        if (other.object.flags.outOfFrame()) continue;
        if (jumpsOutAt(other, entry.target.index)) continue;
        const model = if (other.model) |*live| live else continue;
        if (objects.Box.ofBounds(model, other.drawn).meetsSegment(start, end_at)) markJumping(all, @intCast(at));
    }
}

/// Whether the current order of the ship in `slot` is Jump Out at the target of index `target`, as
/// `jump_out_place` asks of the player's ship and of those in the way.
fn jumpsOutAt(slot: *const create.Slot, target: i16) bool {
    const going = slot.running(.jump_out) orelse return false;
    return going.target.index == target;
}

/// `jump_mark` (`0x00418470`): the object in slot `index`, in the way of a jump, is marked jumping,
/// which holds it where it is and leaves it out of the frame until the player's jump ends; so is
/// each fuel pod, and each ship launching from the object or docking with it, and those in turn.
fn markJumping(all: *create.Objects, index: u16) void {
    all.slots[index].object.flags.jumping = true;
    for (all.slots[0..all.count], 0..) |*other, at| {
        if (other.object.flags.outOfFrame()) continue;
        const follows = if (other.current()) |running| running.target.slot() == index and switch (running.order) {
            .launch, .dock => true,
            else => false,
        } else false;
        if (other.object.type == .fuel_pod or follows) markJumping(all, @intCast(at));
    }
}

/// `order_jump_in_init` (`0x00416540`): the ship in slot `index` jumps in, colliding with nothing
/// and jumping, at its place beside its target (`placeIn`).
pub fn inInit(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.object.flags.no_collisions = true;
    slot.object.flags.jumping = true;
    placeIn(ctx.world.objects, index);
    slot.state.jump.step = .{ .in = .placing };
}

/// `jump_in_place` (`0x00418850`): where the ship in slot `index` arrives: abreast of its target,
/// turned as the target is, the order's place among its group's putting it
/// `aigeneric.abreast_spacing` apart on either side in turn (`aigeneric.Entry.abreast`, counting
/// from 1): the first at the target, the second to its left, the third to its right, and so on.
fn placeIn(all: *create.Objects, index: u16) void {
    const slot = &all.slots[index];
    const target = slot.orders[0].target.slotIn(all) orelse return;
    const beside = &all.slots[target].drawn;
    const across = @as(f32, @floatFromInt(slot.orders[0].abreast(1))) * aigeneric.abreast_spacing;
    slot.state.jump.destination = gameobj.vec3(beside.point(.{ across, 0, 0 }));
}

/// `order_jump_in` (`0x00416570`): Jump In's update, a step at a time (`InStep`).
///
/// It is turned as its target is, and placed far behind where it arrives, stopped:
/// `arrival_distance`, or `arrival_distance_components` for a ship that lists components. It is
/// heard (`jumpin`); for the player's ship, the camera watches from one of the arrival's three
/// views at random, the mission's space takes on what its script asked of it
/// (`environfx.Environment.update`), and the stars streak shorter (`srstars`). From the same update
/// it flashes in (`flash`), and then flies in by its motion, no longer jumping, the player's view
/// shaking less and less, until it flies ahead again at full throttle, colliding again, powered and
/// free to move. Then its order ends: for the player's ship the camera goes back to the cockpit,
/// and its JumpedIn event is posted (`events.jumpedIn`). A ship of Jump In's second number first
/// holds `settle_ticks` in its formation, rolling and pitching by its place in it.
///
/// What it shows (`effect`): a flare where it appears, which grows to its width as it flashes in;
/// a burst hanging ahead of it, and trails from its engines. As it flies in, the trails and the
/// burst fade, and over the first part of the flight the flare stretches across and flattens
/// (`effect.Effect.squashFlare`).
///
/// Not ported: in a multiplayer game, the JumpedIn posted for the first player's ship too as the
/// ship of the first player still flying jumps in
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn inUpdate(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.jump;
    const now = ctx.world.clock.frame_start;
    const dt = gameobj.progressSince(&state.updated, now);
    object.nova_charge = 0;
    switch (state.step.in) {
        .placing => {
            const target = slot.orders[0].target.slotIn(all) orelse return;
            const fx = takeEffect(world, state, index);
            state.orientation = all.slots[target].drawn.orientation;
            state.position = object.root.position;
            const arrival: math.Place = .{ .position = gameobj.vector(state.destination), .orientation = state.orientation };
            objects.setPlace(object, &slot.drawn, arrival);
            ai.stop(object);
            const back = if (object.flags.components) arrival_distance_components else arrival_distance;
            const start = arrival.ahead(-back);
            objects.setPosition(object, &slot.drawn, start);
            if (fx) |held| {
                held.effects.startFlare(held.record, .{ .position = start, .orientation = state.orientation }, object.width());
                held.effects.startBurst(held.record);
            }
            state.advance(.{ .in = .flashing }, now);
            sound3d.playIn(world, null, null, index, .jumpin, 1, sound3d.fxClass(all, index));
            if (index == all.player) {
                if (world.camera) |view| {
                    const pick = arrivalView(world.random.fraction());
                    _ = view.setJump(pick, index, ctx.world.clock.viewTime(), .of(slot), .of(&all.slots[all.player]));
                }
                if (world.environment) |space| space.update();
                world.player.jumping_in = true;
            }
            if (fx) |held| held.effects.startTrails(held.record, slot);
            // It flashes in from the same update, as if no time had passed (`0x0041679B`).
            flash(world, slot, 0);
        },
        .flashing => flash(world, slot, dt),
        .flying => {
            const fx = effectOf(world, state);
            defer show(fx, .{ .trails = true, .burst = true });
            if (fx) |held| {
                held.record.shadeTrails(1 - state.progress);
                held.effects.glow(held.record, 1 - state.progress);
            }
            if (index == all.player) world.shake.* = math.lerp(@as(f32, 1), 0, state.progress);
            state.progress += dt * fly_rate;
            if (fx) |held| if (held.record.squashFlare(state.progress)) show(fx, .{ .flare = true });
            if (!(state.progress > 1)) return;
            slot.motion = slot.motion_aside;
            object.throttle = ai.full_throttle;
            state.next(.{ .in = .settling });
            state.since = now + settle_ticks;
            world.player.jumping_in = false;
            object.flags.no_collisions = false;
            object.flags.thaw();
        },
        .settling => {
            const entry = slot.orders[0];
            if (entry.order != .jump_in_40 or state.since <= now) {
                if (index == all.player) if (world.camera) |view| {
                    _ = view.setView(.cockpit, index, false, true, ctx.world.clock.viewTime());
                };
                freeEffect(world, state);
                aigeneric.end(ctx, index);
                events.jumpedIn(world, index);
                return;
            }
            object.roll_input = @as(f32, @floatFromInt(entry.abreast(1))) * settle_input;
            object.pitch_input = @as(f32, @floatFromInt(entry.placesOut(1))) * settle_input;
            show(effectOf(world, state), .{ .trails = true, .burst = true });
        },
        _ => {},
    }
}

/// Jump In's flashing step, which its placing runs on into in the same update: the flare grows to
/// the ship's width as it flashes in (`flash_rate`); then the ship flies in by its motion, jumping
/// no more. Its trails and its burst show throughout.
fn flash(world: gameobj.World, slot: *create.Slot, dt: f32) void {
    const object = &slot.object;
    const state = &slot.state.jump;
    const fx = effectOf(world, state);
    if (fx) |held| if (held.record.flare) |*flare| flare.grow(state.progress);
    show(fx, .{ .flare = true, .trails = true, .burst = true });
    state.progress += dt * flash_rate;
    if (state.progress > 1) {
        state.next(.{ .in = .flying });
        slot.motion_aside = slot.motion;
        slot.motion = .jump_in;
        object.flags.jumping = false;
    }
}

/// The view the player's arrival is watched from, by `share`, the C runtime's `rand` over the most
/// it gives (`libcmt.Rand.fraction`): twice it, rounded (`sr_round`), picks one of three, the
/// middle one half the time.
fn arrivalView(share: f32) camera.View {
    return switch (math.round(share + share)) {
        0 => .jump_in_close,
        1 => .jump_in_ahead,
        else => .jump_in_aside,
    };
}

/// How long a test's frames are, in ticks.
const test_frame = 10;

/// Moves the test mission's clock on by a frame and runs the orders of the ship in slot `index`.
fn nextFrame(mission: *gameobj.testing.Mission, ctx: aigeneric.Context, index: u16) void {
    mission.clock.frame_start += test_frame;
    mission.clock.mission_ticks = mission.clock.frame_start;
    mission.clock.frame_duration = test_frame;
    aigeneric.objectOrders(ctx, index);
}

/// Whether `actual` is `expected`, each of its axes within a hundredth.
fn expectVector(expected: Vector, actual: Vector) !void {
    return math.testing.expectVectorWithin(expected, actual, 1e-2);
}

test "a jump out that names nothing leaves the mission" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.predator, .{ 0, 0, 10000 });
    const slot = mission.slot(ship);
    slot.motion = .forward;
    slot.object.throttle = 1;
    const ctx = mission.orders();
    _ = try aigeneric.push(ctx, ship, .jump_out, .none);
    nextFrame(&mission, ctx, ship);
    // It lets its throttle go and aims far ahead, which it faces already, so it holds still.
    try std.testing.expectEqual(0, slot.object.throttle);
    try expectVector(.{ 0, 0, 10000 + nowhere_reach }, gameobj.vector(slot.state.jump.destination));
    try std.testing.expectEqual(OutStep.stilling, slot.state.jump.step.out);
    // It charges, then goes by its own motion, colliding with nothing.
    while (slot.motion != .jump_out) nextFrame(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion_aside);
    try std.testing.expect(slot.object.flags.no_collisions);
    try expectVector(.{ 0, 0, 10000 + going_reach }, gameobj.vector(slot.state.jump.to));
    // Gone, it flies ahead, jumping, and then leaves the mission, far below.
    while (slot.state.jump.step.out == .going) nextFrame(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion);
    try std.testing.expect(slot.object.flags.jumping);
    while (slot.object.order_count > 0) nextFrame(&mission, ctx, ship);
    try std.testing.expect(slot.object.flags.disabled);
    try std.testing.expect(!slot.object.flags.jumping);
    try std.testing.expect(!slot.object.flags.no_collisions);
    try std.testing.expectEqual(gone_depth, slot.object.root.position.y);
}

test "a jump out that names a ship gives way to a jump in beside it" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 80000 });
    const turned = math.rotation(.y, std.math.pi / 2.0);
    objects.setOrientation(&mission.slot(target).object, &mission.slot(target).drawn, turned);
    const ship = try mission.add(.predator, .{ 0, 0, 10000 });
    const slot = mission.slot(ship);
    slot.motion = .forward;
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, ship, .jump_out_41, target, null);
    slot.orders[0].sequence = 1;
    while (slot.orders[0].order == .jump_out_41) nextFrame(&mission, ctx, ship);
    // Jump In of the matching number takes over, at the same place in the group.
    try std.testing.expectEqual(Order.jump_in_40, slot.orders[0].order);
    try std.testing.expectEqual(1, slot.orders[0].sequence);
    try std.testing.expectEqual(target, slot.orders[0].target.slot());
    try std.testing.expect(!slot.object.flags.disabled);

    // It arrives to the target's left, turned as the target is, and is placed far behind that to
    // fly in from.
    nextFrame(&mission, ctx, ship);
    const arrival = mission.slot(target).drawn.point(.{ -aigeneric.abreast_spacing, 0, 0 });
    try expectVector(arrival, gameobj.vector(slot.state.jump.destination));
    try expectVector(arrival - math.forward(turned) * @as(Vector, @splat(arrival_distance)), slot.drawn.position);
    try std.testing.expectEqual(turned, slot.drawn.orientation);
    try std.testing.expect(slot.object.flags.jumping);
    try std.testing.expect(slot.object.flags.no_collisions);
    // It flashes in, then flies in by its own motion, no longer jumping.
    while (slot.motion != .jump_in) nextFrame(&mission, ctx, ship);
    try std.testing.expect(!slot.object.flags.jumping);
    // Once in, it flies ahead again at full throttle, colliding again, and holds its place in the
    // formation a while, rolling and pitching by it, before its order ends.
    while (slot.state.jump.step.in == .flying) nextFrame(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion);
    try std.testing.expectEqual(ai.full_throttle, slot.object.throttle);
    try std.testing.expect(!slot.object.flags.no_collisions);
    nextFrame(&mission, ctx, ship);
    try std.testing.expectEqual(-settle_input, slot.object.roll_input);
    try std.testing.expectEqual(settle_input, slot.object.pitch_input);
    const settled = mission.clock.frame_start;
    while (slot.object.order_count > 0) nextFrame(&mission, ctx, ship);
    try std.testing.expect(mission.clock.frame_start >= settled + settle_ticks - test_frame);
}

test "the player's arrival is watched from a cutaway, and ends in the cockpit" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 80000 });
    const slot = mission.slot(player);
    slot.motion = .forward;
    var view: camera.Camera = .{};
    var ctx = mission.orders();
    ctx.world.camera = &view;
    _ = try aigeneric.pushShip(ctx, player, .jump_in, target, null);
    nextFrame(&mission, ctx, player);
    try std.testing.expect(switch (view.view) {
        .jump_in_close, .jump_in_ahead, .jump_in_aside => true,
        else => false,
    });
    try std.testing.expect(view.locked);
    try std.testing.expect(mission.player.jumping_in);
    // As it flies in, the view shakes less and less.
    while (slot.state.jump.step.in != .flying) nextFrame(&mission, ctx, player);
    nextFrame(&mission, ctx, player);
    try std.testing.expectEqual(1, mission.shake);
    nextFrame(&mission, ctx, player);
    try std.testing.expect(mission.shake < 1);
    while (slot.object.order_count > 0) nextFrame(&mission, ctx, player);
    try std.testing.expect(!mission.player.jumping_in);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expect(!view.locked);
}

test "the ships that jump out with the player's form up behind it" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 100000 });
    const wing = [_]u16{ try mission.add(.predator, .{ 5000, 0, 0 }), try mission.add(.predator, .{ -5000, 0, 0 }) };
    const ctx = mission.orders();
    for ([_]u16{ player, wing[0], wing[1] }, 0..) |index, sequence| {
        _ = try aigeneric.pushShip(ctx, index, .jump_out, target, null);
        mission.slot(index).orders[0].sequence = @intCast(sequence);
    }
    mission.clock.frame_start = test_frame;
    for ([_]u16{ player, wing[0], wing[1] }) |index| aigeneric.objectOrders(ctx, index);
    // The player's ship leads, a row ahead of the next, which holds two abreast.
    try expectVector(.{ 0, 0, -formation_spacing }, mission.slot(player).drawn.position);
    try expectVector(.{ -formation_spacing, 0, -3 * formation_spacing }, mission.slot(wing[0]).drawn.position);
    try expectVector(.{ formation_spacing, 0, -3 * formation_spacing }, mission.slot(wing[1]).drawn.position);
    for (wing) |index| {
        const slot = mission.slot(index);
        try std.testing.expect(slot.state.jump.with_player);
        try std.testing.expect(slot.object.flags.no_collisions);
        try std.testing.expectEqual(formation_speed, slot.object.velocity.z);
        try std.testing.expectEqual(formation_speed / gameobj.testing.flight.max_speed, slot.object.throttle);
        try expectVector(.{ 0, 0, 100000 }, gameobj.vector(slot.state.jump.destination));
    }
    // They hold their places a while before they go.
    for (0..formation_wait / test_frame - 1) |_| nextFrame(&mission, ctx, wing[0]);
    try std.testing.expectEqual(OutStep.aligning, mission.slot(wing[0]).state.jump.step.out);
    nextFrame(&mission, ctx, wing[0]);
    try std.testing.expectEqual(OutStep.stilling, mission.slot(wing[0]).state.jump.step.out);
}

test "a ship that lists components flies in from farther behind" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const target = try mission.add(.predator, .{ 0, 0, 80000 });
    const ship = try mission.add(.predator, .{ 0, 0, 10000 });
    const slot = mission.slot(ship);
    slot.object.flags.components = true;
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, ship, .jump_in, target, null);
    nextFrame(&mission, ctx, ship);
    try expectVector(.{ 0, 0, 80000 - arrival_distance_components }, slot.drawn.position);
}

test markJumping {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const base = try mission.add(.predator, .{ 0, 0, 5000 });
    const launching = try mission.add(.predator, .{ 0, 0, 5000 });
    const pod = try mission.add(.predator, .{ 90000, 0, 0 });
    mission.slot(pod).object.type = .fuel_pod;
    const other = try mission.add(.predator, .{ 0, 0, 9000 });
    _ = try aigeneric.pushShip(mission.orders(), launching, .launch, base, null);
    // What is in the way holds, with what launches from it, and every fuel pod.
    markJumping(mission.objects, base);
    for ([_]u16{ base, launching, pod }) |index| try std.testing.expect(mission.slot(index).object.flags.jumping);
    try std.testing.expect(!mission.slot(other).object.flags.jumping);
}

test arrivalView {
    const libcmt = @import("../libcmt.zig");
    const Draw = struct {
        /// The share `rand` gives with `random`.
        fn share(random: u15) f32 {
            return @as(f32, @floatFromInt(random)) / libcmt.Rand.max;
        }
    };
    // A quarter of the time the close view, half the time the view ahead, and a quarter the view
    // aside.
    try std.testing.expectEqual(camera.View.jump_in_close, arrivalView(Draw.share(0)));
    try std.testing.expectEqual(camera.View.jump_in_close, arrivalView(Draw.share(8191)));
    try std.testing.expectEqual(camera.View.jump_in_ahead, arrivalView(Draw.share(8192)));
    try std.testing.expectEqual(camera.View.jump_in_ahead, arrivalView(Draw.share(24575)));
    try std.testing.expectEqual(camera.View.jump_in_aside, arrivalView(Draw.share(24576)));
    try std.testing.expectEqual(camera.View.jump_in_aside, arrivalView(Draw.share(32767)));
}

test "State.effectPlace" {
    // A zeroed state has no record; a record kept is found again, and let go is gone.
    var state = std.mem.zeroes(State);
    try std.testing.expectEqual(null, state.effectPlace());
    state.keepEffect(0);
    try std.testing.expectEqual(1, @intFromEnum(state.effect));
    try std.testing.expectEqual(0, state.effectPlace());
    state.keepEffect(effect.max_records - 1);
    try std.testing.expectEqual(effect.max_records - 1, state.effectPlace());
    state.keepEffect(null);
    try std.testing.expectEqual(.null, state.effect);
    try std.testing.expectEqual(null, state.effectPlace());
}

test showFinest {
    const gpa = std.testing.allocator;
    var gun: create.testing.Model = undefined;
    try gun.init(gpa);
    defer gun.deinit(gpa);
    var carrier: objects.testing.Carrier = undefined;
    carrier.init(.{ 0, 0, 1000 });
    var model = try carrier.build(gpa, &gun);
    defer model.deinit(gpa);
    gameobj.linkParts(&model, &carrier.parts.source);
    const mounted = &model.mounts[0].model;
    // Each part, the model's own and those of the model mounted on it, is drawn at its finest, and
    // then by its distance again.
    showFinest(&model, true);
    for (model.parts) |part| try std.testing.expect(part.object.flags.finest);
    for (mounted.parts) |part| try std.testing.expect(part.object.flags.finest);
    showFinest(&model, false);
    for (model.parts) |part| try std.testing.expect(!part.object.flags.finest);
    for (mounted.parts) |part| try std.testing.expect(!part.object.flags.finest);
}
