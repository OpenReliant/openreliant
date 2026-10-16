//! `C:\lancer\game\ailand.cpp`: Land, order 8, by which the player's ship lands on the carrier it
//! launched from, which ends the mission ([Landing](../../../docs/engine/orders.md#landing)). The
//! player asks for it with PERMISSION TO LAND (`radio.permissionToLand`). Its init picks one
//! of two styles by the carrier; each has its own init and update (`land_styles`, `0x004E1FE8`,
//! `0x18` bytes each: init, update, exit, 0, name and 0): the Reliant's, down into its first
//! launch tube (`reliantInit`, `reliantUpdate`), and the Yamato's, down onto a pad of its landing
//! bay (`yamatoInit`, `yamatoUpdate`). OpenReliant adds a third, for every other carrier it
//! launches from as a hangar bay: in at the doors of a gate and down to its launch point
//! (`bayInit`, `bayUpdate`).
//!
//! **Unverified:** that `order_land` and the styles' routines (`0x0040EB40` to `0x0040FC77`) are
//! this file's. They lie after its known code, before `airipper.cpp`'s, and the style table
//! (`land_styles`, `0x004E1FE8`), just before this file's path, ties them to Land.
//!
//! Not ported: in a multiplayer game, the end of the mission as another player's ship lands on the
//! Yamato ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.orders);

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const camera = @import("camera.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const input = @import("../input.zig");
const launch = @import("launch.zig");
const bay_launch = @import("launch/bay.zig");
const objects = @import("objects.zig");
const reliant_launch = @import("launch/reliant.zig");
const sound3d = @import("sound3d.zig");

/// How a ship lands, by the carrier it lands on (`order_land_init`).
pub const Style = enum(u32) {
    /// On the Yamato, down onto a pad of its landing bay (`yamatoInit`, `yamatoUpdate`).
    yamato = 0,
    /// On the Reliant, down into its first launch tube through the tube's upper door
    /// (`reliantInit`, `reliantUpdate`).
    reliant = 1,
    /// **Improvement:** OpenReliant's own, in a hangar bay of any other carrier that ships launch
    /// from as one: in at the doors of a gate and down to its launch point (`bayInit`,
    /// `bayUpdate`).
    bay = 2,
    /// OpenReliant's own: the order aims at nothing that can be landed on, and ends.
    none = std.math.maxInt(u32),
    _,

    /// The style of a landing on a ship of type `carrier`, or null for a ship with a launch style
    /// of its own that nothing lands on, such as the Badanov. Any other ship is landed on as a
    /// hangar bay, as ships launch from it (`launch.Style.ofCarrier`), where its model has a launch
    /// point for the gate (`bayInit`).
    pub fn of(carrier: gameobj.Type) ?Style {
        return switch (carrier.base()) {
            .reliant => .reliant,
            .yamato => .yamato,
            else => if ((launch.Style.ofCarrier(carrier, 0) orelse .bay) == .bay) .bay else null,
        };
    }
};

/// How the Reliant's landing brings the ship down.
pub const Touchdown = enum {
    /// **Improvement:** the ship levels out as it approaches (`flaredAim`) and stops dead, so that
    /// it sinks straight down the tube and comes to rest level in it; and once its top is below the
    /// tube's upper door, the door closes over it, sounding (`reliantUpdate`).
    level,
    /// As the game lands it: pitched as it came, coasting as it stops, the door left open.
    original,
};

/// The order's state (`GameObject.order_state`).
pub const State = extern struct {
    style: Style,
    /// The frame's tick the step waits for; in the Yamato's landing, from the cutaway on, the tick
    /// the view from its bay begins to slide along it (`camera.View.landing_bay`).
    due: i32,
    /// The Yamato's: the frame's tick the steps on its pad wait for.
    pad_due: i32,
    step: Step,
    /// The Reliant's: the middle of the tube the ship lands in, where the cutaway has moved the
    /// carrier (`cutaway`).
    tube: [3]f32,
    /// OpenReliant's own: whether the Reliant's upper door has begun to close over the ship
    /// (`Touchdown.level`).
    door_closing: bool,
    /// OpenReliant's own: where the ship stands on the Yamato's pad, in the pad's frame, which
    /// each frame's pass places it at (`hold`). The game hangs the ship's frame from the pad's.
    on_pad: [3]f32,
    pad_orientation: math.Matrix,
    /// OpenReliant's own, a bay's: where the launch point of the gate the ship lands at stands and
    /// how it is turned, where the cutaway has moved the carrier (`bayCutaway`), and the mouth of
    /// the bay, where the way out from the point leaves the carrier's bounds (`bayMouth`).
    gate_place: [3]f32,
    gate_orientation: math.Matrix,
    mouth: [3]f32,

    comptime {
        assert(@offsetOf(State, "due") == 0x04);
        assert(@offsetOf(State, "pad_due") == 0x08);
        assert(@offsetOf(State, "step") == 0x0C);
        assert(@offsetOf(State, "tube") == 0x10);
        assert(@sizeOf(State) <= @sizeOf(aigeneric.State));
    }
};

/// The step a landing is at (`State.step`), as each style numbers its own (`ReliantStep`,
/// `YamatoStep`).
pub const Step = enum(u32) {
    _,

    /// The step as the style's own steps, `Styled`, number it.
    pub fn as(step: Step, comptime Styled: type) Styled {
        comptime assert(@typeInfo(Styled).@"enum".tag_type == u32);
        return @fromBackingInt(@backingInt(step));
    }

    /// A style's own step as a landing's.
    pub fn of(own: anytype) Step {
        comptime assert(@typeInfo(@TypeOf(own)).@"enum".tag_type == u32);
        return @fromBackingInt(@backingInt(own));
    }

    /// Whether the landing is at its style's step `other` or past it, by their numbers as the game
    /// compares them.
    pub fn reached(step: Step, other: anytype) bool {
        return @backingInt(step) >= @backingInt(of(other));
    }
};

/// The Reliant's steps.
pub const ReliantStep = enum(u32) {
    /// The player flies on until the landing is due; then the cutaway begins, and the tube's upper
    /// door opens.
    waiting = 0,
    /// The ship flies to `over_tube`, slowing as it nears, and stops within `near`.
    approaching = 1,
    /// Stopped, it waits `settle` ticks.
    settling = 2,
    /// It sinks into the tube, slowing as it goes, and is down within `down_at` of its middle.
    sinking = 3,
    /// Down, it waits `landed_wait` ticks, and the mission is over.
    down = 4,
    _,
};

/// How long the player flies on before the landing begins, in ticks: the Reliant's
/// (`0x0040F5EA`) and the Yamato's (`0x0040EB7A`).
const wait: i32 = 700;

/// Where the cutaway moves the Reliant, or the Yamato's landing bay, turned as the world is, far
/// from what the mission holds (`0x0040F600`, `0x0040EBE4`).
const carrier_away: Vector = .{ 0, -1_000_000, 0 };

/// The Reliant's launch tube the ship lands down, its first (`0x0040F600`), halfway between whose
/// doors' middles it lands (`launch.reliant.tubeMiddle`); and that tube's upper door, a part of the
/// Reliant's root's child list (`launch.reliant.Door`), which opens as the landing begins.
const first_tube = 0;
const upper_door = reliant_launch.Door.upper.part(first_tube);

/// Where the cutaway sets the ship, in the carrier's frame from the tube's middle: ahead of it and
/// above it; and where the ship flies to, over the tube, where it first looks (`0x0040F600`).
const start_offset: Vector = .{ 0, -5000, 20000 };
const over_tube: Vector = .{ 0, -3000, 0 };

/// The upper door's track (`0x004E2050`), and how fast it plays to open the door (`0x0040FA55`).
/// It plays back to close the door as fast as the launch's tube doors open
/// (`launch.reliant.door_speed`), OpenReliant's choice (`Touchdown.level`).
const door_track = "opendoor2";
const door_speed: f32 = 1.23;

/// The throttle the ship approaches with for each unit it has to go, in both styles, and the most
/// the Reliant's takes (`0x004DC4B0`, `0x004DC408`); and how near it stops (`0x004DC468`).
const approach_throttle: f32 = 0.0001;
const approach_most: f32 = 0.5;
const near: f32 = 200;

/// How long the ship waits over the tube before it sinks, in ticks (`0x0040FB59`).
const settle: i32 = 50;

/// The throttle the ship sinks with for each unit it has to go (`0x004DC538`), and how far over the
/// tube's middle it is down, along the carrier's Y axis, which points below it (`0x004DC534`).
const sink_throttle: f32 = 1.0 / 15000.0;
const down_at: f32 = -100;

/// How long the mission goes on once the ship is down, in ticks (`0x0040FC4A`).
const landed_wait: i32 = 270;

/// The parts of the Yamato's landing bay its landing goes by: the hangar, whose lights the cutaway
/// masks as the launch's hangar does (`0x0040EC57`), and the pad the ship comes down on, whose
/// track lowers it (`0x0040F0D2`, `0x004E2048`).
const bay_hangar = 6;
const landing_pad = 1;
const bay_light_mask: u32 = 0x3B;
const pad_track = "floor";

/// Where the cutaway stands the ship in the bay, as shares of the bay's bounds: across, down and
/// along, this much of its maximum and the rest of its minimum (`0x0040EC95`, `0x004DC3F8`,
/// `0x004DC4C0`).
const stand_share: Vector = .{ 0.2, 0.2, 0.3 };

/// The throttle the Yamato's cutaway leaves the ship at (`0x0040EE43`).
const cutaway_throttle: f32 = 0.5;

/// How long after the cutaway the view from the bay begins to slide along it, in ticks
/// (`0x0040EF1B`).
const slide_after: i32 = 600;

/// How far above the hangar's middle, along its Y axis, the ship first flies, and how near it gets
/// before it goes on, which the game compares squared (`0x004DC44C`, `0x004DC490`).
const over_bay: f32 = 1000;
const over_bay_near: f32 = 2000;

/// The speed the ship flies through the bay at most, its throttle what that is of its cruise speed
/// (`0x004DC440`).
const bay_speed: f32 = 100;

/// How far beyond the pad's middle along the bay the ship is to stand, and how near it gets before
/// it stops (`0x004DC4A8`); how far ahead along its nose it steers meanwhile (`0x0040F1D1`); and
/// the throttle it approaches with, `approach_throttle` for each unit it has to go less
/// `approach_least` (`0x004DC4AC`).
const pad_ahead: f32 = 500;
const on_pad_near: f32 = 500;
const pad_lead: f32 = 500;
const approach_least: f32 = 0.02;

/// How the ship turns straight along the bay and level before it stands on the pad
/// (`0x0040F26C`): its yaw and pitch inputs are the angles off the bay's axis less
/// `align_damping` times its rates of turn, times `align_gain` over its type's rates, and it is
/// straight once both are within `aligned` (`0x004DC424`, `0x004DC4C0`, `0x004DC474`).
const align_damping: f32 = 4;
const align_gain: f32 = 0.3;
const aligned: f32 = 0.05;

/// How long the ship waits on the pad before the pad lowers, and how long the pad lowers before the
/// mission is over, in ticks (`0x0040F3A1`, `0x0040F56D`).
const pad_settle: i32 = 200;
const lowered_wait: i32 = 400;

/// The Yamato's steps (`land_yamato_update`, `0x0040EE80`).
pub const YamatoStep = enum(u32) {
    /// The player flies on until the landing is due; then the cutaway begins (`yamatoCutaway`).
    waiting = 0,
    /// The ship flies to `over_bay` above the hangar's middle.
    descending = 1,
    /// It flies on to stand `pad_ahead` beyond the pad's middle, slowing as it nears.
    approaching = 2,
    /// Stopped, it turns straight along the bay and level, and stands on the pad.
    aligning = 3,
    /// It waits `pad_settle` ticks on the pad, which it rides from now on (`hold`).
    settling = 4,
    /// The pad lowers, sounding the ship's landing.
    lowering = 5,
    /// `lowered_wait` ticks later, the mission is over.
    down = 6,
    _,
};

/// OpenReliant's own, for a landing in a bay: how far out from the mouth of the bay the cutaway
/// sets the ship, along the way it launches: this share of the bay's depth, from the launch point
/// to the mouth, and at least this many times the ship's radius, so that a shallow bay still gives
/// the ship a way to fly in on. They go by the bay and the ship rather than by a fixed distance,
/// so that the landing fits any carrier.
const bay_approach_share: f32 = 0.6;
const bay_approach_least_radii: f32 = 20;

/// How far out from the mouth of a bay `depth` deep the cutaway sets a ship of radius `radius`
/// (`bay_approach_share`, `bay_approach_least_radii`).
fn bayApproach(depth: f32, radius: f32) f32 {
    return @max(bay_approach_share * depth, bay_approach_least_radii * radius);
}

/// The steps of a landing in a bay (`bayUpdate`), OpenReliant's own.
pub const BayStep = enum(u32) {
    /// The player flies on until the landing is due; then the cutaway begins (`bayCutaway`), and
    /// the gate's doors open.
    waiting = 0,
    /// The ship flies in at the doors to the launch point, slowing as it nears, and stops within
    /// `near` of it; the doors close behind it.
    approaching = 1,
    /// It waits `landed_wait` ticks at the launch point, and the mission is over.
    landed = 2,
    _,
};

/// `order_land_init` (`0x0040EAC0`): the style, by the type of the carrier the order aims at, and
/// the style's init.
///
/// **Fix:** the game stops with "Cannot land on %s" for a ship that nothing lands on; OpenReliant
/// logs it, and the update lets the order go.
pub fn init(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const state = &all.slots[index].state.land;
    const carrier = all.slots[index].orders[0].target.slotIn(all);
    const carrier_type = if (carrier) |at| all.slots[at].object.type else null;
    state.style = if (carrier_type) |of| Style.of(of) orelse .none else .none;
    switch (state.style) {
        .reliant => reliantInit(ctx, index),
        .yamato => yamatoInit(ctx, index),
        .bay => bayInit(ctx, index),
        .none => log.warn("object {d} cannot land on what its order aims at", .{index}),
        _ => {},
    }
}

/// `order_land` (`0x0040EB40`): the style's update. A landing OpenReliant has no style for ends at
/// once.
pub fn update(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    switch (slot.state.land.style) {
        .reliant => reliantUpdate(ctx, index),
        .yamato => yamatoUpdate(ctx, index),
        .bay => bayUpdate(ctx, index),
        .none, _ => aigeneric.end(ctx, index),
    }
}

/// `land_reliant_init` (`0x0040F5C0`): the first step, due `wait` ticks on, or at once where the
/// player's ship is being sent home for its friendly fire.
fn reliantInit(ctx: Context, index: u16) void {
    const state = &ctx.world.objects.slots[index].state.land;
    state.step = .of(ReliantStep.waiting);
    state.due = ctx.world.clock.frame_start + if (ctx.world.player.ending.sentHome()) 0 else wait;
}

/// `land_reliant_update` (`0x0040F940`): a step of the Reliant's landing (`Step`).
///
/// While the landing is not yet due, the player's ship flies by the player's controls
/// (`input.playerControlOrder`). Then the cutaway begins (`cutaway`): the mission's scene becomes
/// the landing's, every object but the ship and the carrier is disabled and the two others
/// enabled, and the ship flies by its nose (`motion.Motion.plain`), passing through everything.
/// The carrier's first tube's upper door opens, sounding where it is (`playDoor`).
///
/// The ship steers at `over_tube`, its throttle `approach_throttle` for each unit it has to go, at
/// most `approach_most`, and stops within `near` of it, its turns nothing. It waits `settle` ticks,
/// then sinks along its own Y axis (`motion.Motion.downward`), its throttle `sink_throttle` for
/// each unit it stands from the tube's middle. Once it is less than `down_at` over it, it stops,
/// sounding its landing, and `landed_wait` ticks later the mission is over (`vm.Variables`).
fn reliantUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.land;
    const carrier = slot.orders[0].target.slotIn(all) orelse return;
    const now = ctx.world.clock.frame_start;
    switch (state.step.as(ReliantStep)) {
        .waiting => {
            if (now < state.due and index == all.player) return input.playerControlOrder(ctx, index);
            cutaway(ctx, index, carrier);
            world.player.showing = .landing;
            for (all.slots[0..all.count], 0..) |*each, at| each.object.flags.disabled = at != index and at != carrier;
            state.step = .of(ReliantStep.approaching);
            slot.motion = .plain;
            object.flags.no_collisions = true;
            playDoor(world, &all.slots[carrier], .dooropen, 0, door_speed);
        },
        .approaching => {
            const frame = tubeFrame(state, &all.slots[carrier]);
            const point = switch (world.touchdown) {
                .level => flaredAim(frame, object),
                .original => frame.point(over_tube),
            };
            _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{});
            const distance = math.distance(point, object.nextPosition());
            object.throttle = @min(distance * approach_throttle, approach_most);
            if (distance >= near) return;
            object.letGo();
            if (world.touchdown == .level) ai.stop(object);
            state.step = .of(ReliantStep.settling);
            state.due = now + settle;
        },
        .settling => {
            if (state.due >= now) return;
            state.step = .of(ReliantStep.sinking);
            slot.motion = .downward;
        },
        .sinking => {
            const reliant = &all.slots[carrier];
            const frame = tubeFrame(state, reliant);
            const off = frame.inverse(object.nextPosition());
            object.throttle = math.length(off) * sink_throttle;
            // **Improvement:** the tube's upper door closes over the ship: its opening played back
            // from where it stands, as fast as the launch's tube doors open, with the game's sound
            // of a door closing (`0x36`, `doorclos`), as the opening had the sound of one opening
            // (`Touchdown.level`).
            if (world.touchdown == .level and !state.door_closing and belowDoor(reliant, frame, off[1] + object.bounds_min.y)) {
                state.door_closing = true;
                playDoor(world, reliant, .doorclos, objects.Model.keep_time, -reliant_launch.door_speed);
            }
            if (off[1] <= down_at) return;
            object.letGo();
            sound3d.playIn(world, null, null, index, .shipland, 1, .not_reserved);
            state.step = .of(ReliantStep.down);
            state.due = now + landed_wait;
        },
        .down => {
            if (state.due >= now) return;
            if (world.variables) |variables| variables.mission_over = 1;
        },
        _ => {},
    }
}

/// `land_reliant_cutaway` (`0x0040F600`): the cutaway of the Reliant's landing. One of its two
/// views, picked at random, watches the ship, locked. The carrier moves to `carrier_away`, turned
/// as the world is, and the middle of its first launch tube is worked out there: halfway between
/// the middles of the tube's doors, each the middle of the bounds of its part's finest level
/// (`launch.reliant.tubeMiddle`). The ship stands at `start_offset` from it in the carrier's frame,
/// looking at `over_tube`, stopped, its power shared evenly. The carrier's orders are all popped,
/// and it stops.
fn cutaway(ctx: Context, index: u16, carrier: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.land;
    if (world.camera) |view| {
        const pick: camera.View = if (world.random.oneIn(2)) .landing_aside else .landing_tube;
        _ = view.setView(pick, index, true, true, ctx.world.clock.viewTime());
    }
    const reliant = &all.slots[carrier];
    objects.setPlace(&reliant.object, &reliant.drawn, .{ .position = carrier_away, .orientation = math.identity });
    if (reliant_launch.tubeMiddle(reliant, first_tube, 0)) |tube| state.tube = tube;
    const frame = tubeFrame(state, reliant);
    const object = &slot.object;
    objects.setPosition(object, &slot.drawn, frame.point(start_offset));
    const look = frame.point(over_tube);
    objects.setOrientation(object, &slot.drawn, math.lookAt(look - object.nextPosition()));
    ai.stop(object);
    object.gun_factor = 1;
    object.speed_factor = 1;
    object.shield_factor = 1;
    aigeneric.popAll(ctx, carrier);
    ai.stop(&reliant.object);
}

/// `land_yamato_init` (`0x0040EB60`): the first step, due `wait` ticks on; for the player's ship,
/// the landing bay made in the cutaway slot, passing through everything.
fn yamatoInit(ctx: Context, index: u16) void {
    const world = ctx.world;
    const state = &world.objects.slots[index].state.land;
    state.step = .of(YamatoStep.waiting);
    state.due = world.clock.frame_start + wait;
    if (index != world.objects.player) return;
    const bay = create.make(world, create.cutaway_slot, .of(.yamato_landing_bay)) catch |err| {
        log.warn("the Yamato's landing bay is left out: {s}", .{@errorName(err)});
        return;
    } orelse return;
    world.objects.slots[bay].object.flags.no_collisions = true;
}

/// `land_yamato_update` (`0x0040EE80`): a step of the Yamato's landing (`YamatoStep`). A ship
/// other than the player's lets its landing go at once (`order_pop`).
///
/// While the landing is not yet due, the player's ship flies by the player's controls. Then the
/// cutaway begins (`yamatoCutaway`), and the ship flies by its nose (`motion.Motion.plain`),
/// passing through everything. The mission's scene becomes the landing's, and every other object
/// is disabled. The ship steers at `over_bay` above the hangar's middle, upright, at `bay_speed`,
/// until it is within `over_bay_near` of it. Then it steers `pad_lead` ahead along its nose from
/// the place `pad_ahead` beyond the pad's middle, level with its own underside, its throttle
/// `approach_throttle` for each unit it has to go less `approach_least`, at most `bay_speed`, and
/// stops within `on_pad_near` of it. There it turns straight along the bay and level
/// (`alignInputs`), and once it is, it stands on the pad, which it rides (`hold`). `pad_settle`
/// ticks on, the pad lowers, sounding the ship's landing, and `lowered_wait` ticks after that the
/// mission is over.
///
/// **Improvement:** the angles come from `std.math.atan2` rather than the engine's table
/// (`sr_atan2`), as they do elsewhere in OpenReliant.
fn yamatoUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    if (index != all.player) return aigeneric.end(ctx, index);
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.land;
    const now = world.clock.frame_start;
    const bay = &all.slots[create.cutaway_slot];
    switch (state.step.as(YamatoStep)) {
        .waiting => {
            if (now < state.due) return input.playerControlOrder(ctx, index);
            yamatoCutaway(ctx, index);
            state.step = .of(YamatoStep.descending);
            state.due = now + slide_after;
            slot.motion = .plain;
            object.flags.no_collisions = true;
        },
        .descending => {
            world.player.showing = .landing;
            for (all.slots[0..all.count], 0..) |*each, at| if (at != index) {
                each.object.flags.disabled = true;
            };
            const hangar = partMiddle(bay, bay_hangar) orelse return;
            const point = hangar.frame.point(hangar.middle - Vector{ 0, over_bay, 0 });
            _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{ .roll_upright = true });
            object.throttle = bayThrottle(world, slot);
            if (math.distance(point, object.nextPosition()) < over_bay_near) state.step = .of(YamatoStep.approaching);
        },
        .approaching => {
            const pad = partMiddle(bay, landing_pad) orelse return;
            const point = pad.frame.point(pad.middle) + Vector{ 0, object.bounds_min.y, pad_ahead };
            const distance = math.distance(point, object.nextPosition());
            const lead = point + math.forward(object.root.next_orientation) * @as(Vector, @splat(pad_lead));
            _ = ai.steer(world, index, lead, ai.full_limit, ai.no_ease, .{ .roll_upright = true });
            object.throttle = @min(distance * approach_throttle - approach_least, bayThrottle(world, slot));
            if (distance < on_pad_near) state.step = .of(YamatoStep.aligning);
        },
        .aligning => {
            alignInputs(slot);
            object.roll_input = 0;
            object.throttle = 0;
            if (@abs(object.yaw_input) >= aligned or @abs(object.pitch_input) >= aligned) return;
            state.step = .of(YamatoStep.settling);
            state.pad_due = now + pad_settle;
            const model = if (bay.model) |*held| held else return;
            if (model.rootChild(landing_pad) == null) return;
            const standing: math.Place = .{ .position = object.nextPosition(), .orientation = object.root.next_orientation };
            const on_pad = standing.relativeTo(model.frameAt(landing_pad, bay.drawn));
            state.on_pad = on_pad.position;
            state.pad_orientation = on_pad.orientation;
            slot.riding = .{ .object = create.cutaway_slot, .part = landing_pad };
        },
        .settling => {
            // No turns and no throttle while it waits on the pad (`0x0040F4A9`).
            object.letGo();
            if (now <= state.pad_due) return;
            state.step = .of(YamatoStep.lowering);
        },
        .lowering => {
            // And again as the pad starts down (`0x0040F4F5`).
            object.letGo();
            if (bay.model) |*model| if (model.rootChild(landing_pad) != null) model.playNamed(landing_pad, pad_track, 0, null, 1);
            sound3d.playIn(world, null, null, index, .shipland, 1, .not_reserved);
            state.step = .of(YamatoStep.down);
            state.pad_due = now + lowered_wait;
        },
        .down => {
            if (now <= state.pad_due) return;
            if (world.variables) |variables| variables.mission_over = 1;
        },
        _ => {},
    }
}

/// `land_yamato_cutaway` (`0x0040EBC0`): the cutaway of the Yamato's landing. The landing bay
/// moves to `carrier_away`, turned as the world is, its hangar lit through `bay_light_mask`. One
/// of its two views, picked at random, watches the ship, locked. The ship stands in the bay at
/// `stand_share` of the bay's bounds, looking at the hangar's middle, stopped, its throttle
/// `cutaway_throttle` and its power shared evenly.
///
/// **Fix:** the game reads past the bay's list of parts where its model lacks the hangar; then
/// OpenReliant leaves the ship turned as it was.
///
/// Left out: the view picked, which the game keeps (`0x0051863C`) and nothing reads.
fn yamatoCutaway(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const bay = &all.slots[create.cutaway_slot];
    const away: math.Place = .{ .position = carrier_away };
    objects.setPlace(&bay.object, &bay.drawn, away);
    if (bay.model) |*model| if (model.rootChild(bay_hangar) != null) {
        model.parts[bay_hangar].object.light_mask = bay_light_mask;
    };
    if (world.camera) |view| {
        const pick: camera.View = if (world.random.oneIn(2)) .landing_bay else .landing_ship;
        _ = view.setView(pick, index, true, true, world.clock.viewTime());
    }
    const max = bay.object.bounds_max.vector();
    const min = bay.object.bounds_min.vector();
    objects.setPosition(object, &slot.drawn, away.point(max * stand_share + min * (@as(Vector, @splat(1)) - stand_share)));
    if (partMiddle(bay, bay_hangar)) |hangar| {
        objects.setOrientation(object, &slot.drawn, math.lookAt(hangar.frame.point(hangar.middle) - object.nextPosition()));
    }
    ai.stop(object);
    object.throttle = cutaway_throttle;
    object.gun_factor = 1;
    object.speed_factor = 1;
    object.shield_factor = 1;
}

/// OpenReliant's own: the first step of a landing in a bay. Aimed at the carrier as a whole, as
/// the player's request aims it, the landing is due `wait` ticks on, as the Reliant's is; aimed at
/// a gate, as a mission's `SetAI` aims it at one of the carrier's components, it begins at once,
/// so that the mission lands the ship at its own moment. A ship sent home for its friendly fire
/// lands at once too. A carrier whose model has no launch point for the gate is one that nothing
/// lands on.
fn bayInit(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.land;
    const target = slot.orders[0].target;
    const carrier = target.slotIn(all) orelse return;
    if (launch.gateOf(all, carrier, bayGate(target)) == null) {
        state.style = .none;
        log.warn("object {d} cannot land on what its order aims at: it has no launch point {d}", .{ index, bayGate(target) });
        return;
    }
    state.step = .of(BayStep.waiting);
    const at_once = ctx.world.player.ending.sentHome() or !target.isWhole();
    state.due = ctx.world.clock.frame_start + if (at_once) 0 else wait;
}

/// The gate a landing aims at: the component of its order's target, or gate 0 for the carrier as a
/// whole.
fn bayGate(target: aigeneric.Target) i16 {
    return if (target.isWhole()) 0 else target.component;
}

/// The doors of the gate the landing of the ship in `slot` aims at (`bay_launch.Doors`).
fn bayDoors(all: *const create.Objects, slot: *const create.Slot) bay_launch.Doors {
    const target = slot.orders[0].target;
    const carrier = target.slotIn(all) orelse return .{};
    return .of(all.slots[carrier].object.type, bayGate(target));
}

/// OpenReliant's own: a step of a landing in a bay (`BayStep`). A ship other than the player's
/// lets its landing go at once, as the Yamato's does.
///
/// While the landing is not yet due, the player's ship flies by the player's controls. Then the
/// cutaway begins (`bayCutaway`): the mission's scene becomes the landing's, every object but the
/// ship and the carrier is disabled, the ship flies by its nose (`motion.Motion.plain`), passing
/// through everything, and the gate's doors open as the launch opens them
/// (`bay_launch.playDoors`). The ship steers at the gate's launch point, upright, its throttle
/// `approach_throttle` for each unit it has to go, at most the one that flies it at `bay_speed`,
/// and stops within `near` of the point, sounding its landing; the doors close behind it, and
/// `landed_wait` ticks later the mission is over.
fn bayUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    if (index != all.player) return aigeneric.end(ctx, index);
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.land;
    const carrier = slot.orders[0].target.slotIn(all) orelse return aigeneric.end(ctx, index);
    const now = world.clock.frame_start;
    switch (state.step.as(BayStep)) {
        .waiting => {
            if (now < state.due) return input.playerControlOrder(ctx, index);
            bayCutaway(ctx, index, carrier);
            world.player.showing = .landing;
            for (all.slots[0..all.count], 0..) |*each, at| each.object.flags.disabled = at != index and at != carrier;
            state.step = .of(BayStep.approaching);
            slot.motion = .plain;
            object.flags.no_collisions = true;
            bay_launch.playDoors(world, &all.slots[carrier], bayDoors(all, slot), .open);
        },
        .approaching => {
            const point: Vector = state.gate_place;
            _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{ .roll_upright = true });
            const distance = math.distance(point, object.nextPosition());
            const most = if (ai.slotCruise(slot, world.view)) |cruise| bay_speed / cruise else approach_most;
            object.throttle = @min(distance * approach_throttle, most);
            if (distance >= near) return;
            object.letGo();
            ai.stop(object);
            sound3d.playIn(world, null, null, index, .shipland, 1, .not_reserved);
            bay_launch.playDoors(world, &all.slots[carrier], bayDoors(all, slot), .close);
            state.step = .of(BayStep.landed);
            state.due = now + landed_wait;
            log.debug("object {d} is down at its gate's launch point at tick {d}", .{ index, now });
        },
        .landed => {
            if (state.due >= now) return;
            if (world.variables) |variables| variables.mission_over = 1;
        },
        _ => {},
    }
}

/// OpenReliant's own: the cutaway of a landing in a bay, as the Reliant's (`cutaway`). One of the
/// Reliant's two views, picked at random, watches the ship, locked, standing by the bay
/// (`camera.Landing.bay`). The carrier moves to `carrier_away`, turned as the world is, and the
/// launch point of the gate is worked out there (`launch.gateOf`), with the mouth of the bay
/// (`bayMouth`). The ship stands `bay_approach` out from the mouth along the way it launches,
/// looking in at the launch point, stopped, its power shared evenly. The carrier's orders are all
/// popped, and it stops.
fn bayCutaway(ctx: Context, index: u16, carrier: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.land;
    if (world.camera) |view| {
        const pick: camera.View = if (world.random.oneIn(2)) .landing_aside else .landing_tube;
        _ = view.setView(pick, index, true, true, world.clock.viewTime());
    }
    const holder = &all.slots[carrier];
    objects.setPlace(&holder.object, &holder.drawn, .{ .position = carrier_away, .orientation = math.identity });
    const gate = (launch.gateOf(all, carrier, bayGate(slot.orders[0].target)) orelse return).place;
    state.gate_place = gate.position;
    state.gate_orientation = gate.orientation;
    const mouth = bayMouth(&holder.object, gate);
    state.mouth = mouth;
    const object = &slot.object;
    const approach = bayApproach(math.distance(gate.position, mouth), object.radius);
    objects.setPosition(object, &slot.drawn, mouth + math.forward(gate.orientation) * @as(Vector, @splat(approach)));
    objects.setOrientation(object, &slot.drawn, math.lookAt(gate.position - object.nextPosition()));
    ai.stop(object);
    object.gun_factor = 1;
    object.speed_factor = 1;
    object.shield_factor = 1;
    aigeneric.popAll(ctx, carrier);
    ai.stop(&holder.object);
    const set = object.nextPosition();
    log.debug("object {d} of radius {d:.0} lands at gate {d} of object {d}: the launch point at ({d:.0}, {d:.0}, {d:.0}), the bay's mouth at ({d:.0}, {d:.0}, {d:.0}), the ship set at ({d:.0}, {d:.0}, {d:.0})", .{
        index,            object.radius,    bayGate(slot.orders[0].target), carrier,
        gate.position[0], gate.position[1], gate.position[2],               mouth[0],
        mouth[1],         mouth[2],         set[0],                         set[1],
        set[2],
    });
}

/// The mouth of the bay a ship launches from the launch point at `gate` of `carrier`: where the
/// way out from the point, along the Z axis of its place, leaves the carrier's bounds
/// (`GameObject.bounds_min`, `bounds_max`), in the world. The point itself where the way out is
/// already outside them, or runs along none of their axes.
fn bayMouth(carrier: *const gameobj.GameObject, gate: math.Place) Vector {
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

/// Where part `part` of the object in `slot` stands, as its model places it, and the middle of the
/// bounds of its finest level (`objects.Model.partBounds`), in its own frame; null where the model
/// lacks the part.
fn partMiddle(slot: *create.Slot, part: usize) ?struct { frame: math.Place, middle: Vector } {
    const model = if (slot.model) |*held| held else return null;
    const middle = model.boundsMiddle(part) orelse return null;
    return .{ .frame = model.frameAt(part, slot.drawn), .middle = middle };
}

/// The throttle at which the ship in `slot` flies at `bay_speed`, by its cruise speed
/// (`object_cruise_speed`); none for a ship with no flight stats.
fn bayThrottle(world: gameobj.World, slot: *const create.Slot) f32 {
    const cruise = ai.slotCruise(slot, world.view) orelse return 0;
    return bay_speed / cruise;
}

/// The inputs that turn the ship in `slot` straight along the bay and level (`0x0040F26C`): its
/// yaw and its pitch, each the angle off the bay's Z axis less `align_damping` times its rate of
/// turn, times `align_gain` over its type's rate.
///
/// **Fix:** the game follows a null pointer for a ship with no flight stats; OpenReliant leaves
/// its inputs as they are.
fn alignInputs(slot: *create.Slot) void {
    const flight = slot.flight orelse return;
    const object = &slot.object;
    const forward = math.forward(object.root.next_orientation);
    object.yaw_input = (-std.math.atan2(forward[0], forward[2]) - align_damping * object.yaw_rate) * align_gain / flight.yaw_rate;
    object.pitch_input = (std.math.atan2(forward[1], forward[2]) - align_damping * object.pitch_rate) * align_gain / flight.pitch_rate;
}

/// Each frame's placing of a ship on the Yamato's pad (`main.frameObjects`): from
/// `YamatoStep.settling` on, the ship stands where it came to rest on the pad, as the pad lowers.
/// Returns whether it placed the ship.
pub fn hold(all: *create.Objects, index: u16) bool {
    const slot = &all.slots[index];
    if (slot.running(.land) == null) return false;
    const state = &slot.state.land;
    if (state.style != .yamato or !state.step.reached(YamatoStep.settling)) return false;
    const pad = (slot.riding orelse return false).place(all) orelse return false;
    const on_pad: math.Place = .{ .position = state.on_pad, .orientation = state.pad_orientation };
    objects.setPlace(&slot.object, &slot.drawn, on_pad.within(pad));
    return true;
}

/// The frame the landing goes by: the middle of the tube the cutaway worked out (`State.tube`),
/// turned as `carrier` will be next.
fn tubeFrame(state: *const State, carrier: *const create.Slot) math.Place {
    return .{ .position = state.tube, .orientation = carrier.object.root.next_orientation };
}

/// **Improvement:** the point the ship steers at as it approaches, in the tube's frame `frame`
/// (`tubeFrame`), so that it levels out as it comes rather than pitching as it arrives
/// (`Touchdown.level`). It stands over the tube's middle, at first at the game's height,
/// `over_tube`; as the ship nears, eased in and out over the way the cutaway set it to come, it
/// rises to the ship's own height, which it takes once the ship is over the tube.
fn flaredAim(frame: math.Place, object: *const gameobj.GameObject) Vector {
    const off = frame.inverse(object.nextPosition());
    const across = @sqrt(off[0] * off[0] + off[2] * off[2]);
    const share = std.math.clamp(1 - across / start_offset[2], 0, 1);
    const eased = share * share * (3 - 2 * share);
    return frame.point(.{ 0, math.lerp(over_tube[1], off[1], eased), 0 });
}

/// Whether a ship whose top stands `top` along the Y axis of the tube's frame `frame` (`tubeFrame`)
/// is below the underside of the tube's upper door, as the door's finest level bounds it.
/// False where the Reliant's model lacks the door.
fn belowDoor(reliant: *const create.Slot, frame: math.Place, top: f32) bool {
    const model = if (reliant.model) |*held| held else return false;
    const bounds = model.partBounds(upper_door) orelse return false;
    const middle = model.boundsMiddle(upper_door) orelse return false;
    const underside = model.frameAt(upper_door, reliant.drawn).point(.{ middle[0], bounds[1][1], middle[2] });
    return top > frame.inverse(underside)[1];
}

/// Plays the upper door's track (`door_track`) from `from` at `speed`, sounding `which` where the
/// door stands, facing as it does; nothing where the Reliant's model lacks the door.
fn playDoor(world: gameobj.World, reliant: *create.Slot, which: sound3d.sounds.Sound, from: f32, speed: f32) void {
    const model = if (reliant.model) |*held| held else return;
    if (model.rootChild(upper_door) == null) return;
    sound3d.playFrom(world, model.frameAt(upper_door, reliant.drawn), which, .guaranteed);
    model.playNamed(upper_door, door_track, from, null, speed);
}

/// What the landing's views stand by where the object in slot `index` is landing: on the Reliant
/// (`camera.View.landing_tube`, `landing_aside`), the middle of the tube its state keeps and how
/// its carrier is turned as it is drawn; on the Yamato (`camera.View.landing_bay`), where its
/// landing bay stands, the bounds of the bay's hangar, and the tick its view slides from; in a
/// bay (the Reliant's two views again), the launch point's place and the doors' middle its state
/// keeps.
pub fn seen(all: *const create.Objects, index: u16) ?camera.Landing {
    if (index >= all.slots.len) return null;
    const slot = &all.slots[index];
    const entry = slot.running(.land) orelse return null;
    const state = &slot.state.land;
    switch (state.style) {
        .reliant => {
            const carrier = entry.target.slotIn(all) orelse return null;
            return .{ .reliant = .{ .tube = state.tube, .carrier = all.slots[carrier].drawn.orientation } };
        },
        .bay => return .{ .bay = .{
            .gate = .{ .position = state.gate_place, .orientation = state.gate_orientation },
            .mouth = state.mouth,
        } },
        .yamato => {
            const bay = &all.slots[create.cutaway_slot];
            const model = if (bay.model) |*held| held else return null;
            const hangar = model.partBounds(bay_hangar) orelse return null;
            return .{ .yamato = .{ .bay = bay.drawn, .hangar = hangar, .due = state.due } };
        },
        .none, _ => return null,
    }
}

test "Step.reached" {
    const settling: Step = .of(YamatoStep.settling);
    try std.testing.expect(settling.reached(YamatoStep.settling));
    try std.testing.expect(settling.reached(YamatoStep.waiting));
    try std.testing.expect(!Step.of(YamatoStep.waiting).reached(YamatoStep.settling));
}

test Style {
    try std.testing.expectEqual(Style.reliant, Style.of(.of(.reliant)).?);
    try std.testing.expectEqual(Style.yamato, Style.of(.of(.yamato)).?);
    // A ship that ships launch from as a hangar bay is landed on as one, as is any ship without a
    // launch style of its own, whose init then looks for a launch point; one with its own style
    // is not landed on.
    try std.testing.expectEqual(Style.bay, Style.of(.of(.victorious)).?);
    try std.testing.expectEqual(Style.bay, Style.of(.of(.predator)).?);
    try std.testing.expectEqual(null, Style.of(.of(.badanov)));
}

test "the player's ship lands on the Reliant, and the mission is over" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var variables: @import("../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    const ctx: Context = .of(world);
    const player = try mission.add(.of(.predator), .{ 100, 0, 0 });
    const reliant = try mission.add(.of(.reliant), .{ 0, 0, 50000 });
    const other = try mission.add(.of(.predator), .{ 5, 5, 5 });
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
    const slot = mission.slot(player);
    const state = &slot.state.land;

    // The Reliant's style, due `wait` ticks on, until which the player flies on.
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Style.reliant, state.style);
    try std.testing.expectEqual(ReliantStep.waiting, state.step.as(ReliantStep));
    try std.testing.expectEqual(1000 + wait, state.due);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(ReliantStep.waiting, state.step.as(ReliantStep));

    // Then the cutaway: the Reliant stopped far away, the ship ahead of its tube and above it,
    // flying by its nose and passing through everything, and every other object disabled.
    mission.clock.frame_start = 1000 + wait;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(ReliantStep.approaching, state.step.as(ReliantStep));
    try std.testing.expectEqual(@import("main.zig").Showing.landing, mission.player.showing);
    try std.testing.expect(mission.slot(other).object.flags.disabled);
    try std.testing.expect(!mission.slot(reliant).object.flags.disabled and !slot.object.flags.disabled);
    try std.testing.expectEqual(carrier_away, mission.slot(reliant).object.nextPosition());
    try std.testing.expectEqual(0, mission.slot(reliant).object.order_count);
    const tube: Vector = state.tube;
    try std.testing.expectEqual(tube + start_offset, slot.object.nextPosition());
    try std.testing.expectEqual(@import("motion.zig").Motion.plain, slot.motion.?);
    try std.testing.expect(slot.object.flags.no_collisions);

    // Far from the point over the tube, it approaches at its most; within `near`, it stops.
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(approach_most, slot.object.throttle);
    objects.setPosition(&slot.object, &slot.drawn, tube + over_tube + Vector{ 0, 0, 150 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(ReliantStep.settling, state.step.as(ReliantStep));
    try std.testing.expectEqual(0, slot.object.throttle);

    // It waits `settle` ticks, and sinks along its Y axis, slowing as it nears the tube's middle.
    mission.ordersAfter(ctx, player, settle);
    try std.testing.expectEqual(ReliantStep.settling, state.step.as(ReliantStep));
    mission.ordersAfter(ctx, player, 1);
    try std.testing.expectEqual(ReliantStep.sinking, state.step.as(ReliantStep));
    try std.testing.expectEqual(@import("motion.zig").Motion.downward, slot.motion.?);
    objects.setPosition(&slot.object, &slot.drawn, tube + Vector{ 0, -1500, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectApproxEqAbs(1500 * sink_throttle, slot.object.throttle, 1e-6);
    objects.setPosition(&slot.object, &slot.drawn, tube + Vector{ 0, -50, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(ReliantStep.down, state.step.as(ReliantStep));
    try std.testing.expectEqual(0, slot.object.throttle);

    // `landed_wait` ticks after it is down, the mission is over.
    mission.ordersAfter(ctx, player, landed_wait);
    try std.testing.expectEqual(0, variables.mission_over);
    mission.ordersAfter(ctx, player, 1);
    try std.testing.expectEqual(1, variables.mission_over);
}

test flaredAim {
    var object = std.mem.zeroes(gameobj.GameObject);
    const frame: math.Place = .{ .position = .{ 0, 0, 1000 } };
    const tube = frame.position;
    // Where the cutaway sets the ship, the game's point over the tube.
    object.root.next_position = .of(tube + start_offset);
    try std.testing.expectEqual(tube + over_tube, flaredAim(frame, &object));
    // Half way there, the point has risen half way to the ship's height.
    object.root.next_position = .of(tube + Vector{ 0, -4000, start_offset[2] / 2 });
    try std.testing.expectApproxEqAbs(-3500, flaredAim(frame, &object)[1], 1e-2);
    // Over the tube's middle, at the ship's own height, so that it flies level.
    object.root.next_position = .of(tube + Vector{ 0, -3800, 0 });
    try std.testing.expectApproxEqAbs(-3800, flaredAim(frame, &object)[1], 1e-2);
}

test "the ship lands in the Reliant's first tube, and its upper door closes over it" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var reliant_model: reliant_launch.testing.Reliant = undefined;
    try reliant_model.init(gpa);
    defer reliant_model.deinit(gpa);
    var world = mission.world();
    world.touchdown = .level;
    const ctx: Context = .of(world);
    const player = try mission.add(.of(.predator), @splat(0));
    const reliant = try mission.add(.of(.reliant), .{ 0, 0, 50000 });
    try reliant_model.fit(gpa, mission.slot(reliant));
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
    const slot = mission.slot(player);
    const state = &slot.state.land;
    aigeneric.objectOrders(ctx, player);
    mission.clock.frame_start = wait + 1;
    aigeneric.objectOrders(ctx, player);

    // The cutaway works out the tube's middle where it has moved the carrier, turned as the world
    // is: halfway between the lower door, part 0, and the upper door, part 6, 500 above it.
    const tube: Vector = state.tube;
    try std.testing.expectEqual(carrier_away + Vector{ 0, -250, 0 }, tube);
    try std.testing.expectEqual(tube + start_offset, slot.object.nextPosition());

    // Sinking, the door stays open while the ship's top is above the door's underside, 150 over
    // the tube's middle; once its top is below it, the door closes over it, and stays closing.
    state.step = .of(ReliantStep.sinking);
    slot.object.bounds_min.y = -20;
    objects.setPosition(&slot.object, &slot.drawn, tube + Vector{ 0, -1500, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expect(!state.door_closing);
    objects.setPosition(&slot.object, &slot.drawn, tube + Vector{ 0, -120, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(ReliantStep.sinking, state.step.as(ReliantStep));
    try std.testing.expect(state.door_closing);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expect(state.door_closing);
}

test "a ship sent home for its friendly fire lands at once" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const player = try mission.add(.of(.predator), @splat(0));
    const reliant = try mission.add(.of(.reliant), .{ 0, 0, 50000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
    mission.player.ending = .friendly_fire;
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    const state = &mission.slot(player).state.land;
    try std.testing.expectEqual(1000, state.due);
    try std.testing.expectEqual(ReliantStep.approaching, state.step.as(ReliantStep));
}

test "over the tube, a ship stops dead, or coasts as the game lets it" {
    for ([_]Touchdown{ .level, .original }) |touchdown| {
        var mission: gameobj.testing.Mission = undefined;
        try mission.init(std.testing.allocator);
        defer mission.deinit();
        var world = mission.world();
        world.touchdown = touchdown;
        const ctx: Context = .of(world);
        const player = try mission.add(.of(.predator), @splat(0));
        const reliant = try mission.add(.of(.reliant), .{ 0, 0, 50000 });
        try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
        const slot = mission.slot(player);
        const state = &slot.state.land;
        aigeneric.objectOrders(ctx, player);
        mission.clock.frame_start = wait + 1;
        aigeneric.objectOrders(ctx, player);
        objects.setPosition(&slot.object, &slot.drawn, @as(Vector, state.tube) + over_tube + Vector{ 0, 0, 150 });
        slot.object.velocity = .{ .x = 0, .y = 0, .z = -5 };
        aigeneric.objectOrders(ctx, player);
        try std.testing.expectEqual(ReliantStep.settling, state.step.as(ReliantStep));
        try std.testing.expectEqual(@as(f32, if (touchdown == .level) 0 else -5), slot.object.velocity.z);
    }
}

test "a landing on what nothing lands on, or a ship's but the player's on the Yamato, is let go" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    _ = try mission.add(.of(.predator), @splat(0));
    const ship = try mission.add(.of(.predator), @splat(0));
    try std.testing.expect(try aigeneric.push(ctx, ship, .fly_aimlessly, .none));
    // The Yamato lands the player's ship alone, the Badanov has a launch style of its own, and
    // the Predator, landed on as a bay, has no model with a launch point.
    for ([_]gameobj.Type{ .of(.yamato), .of(.badanov), .of(.predator) }) |carrier_type| {
        const carrier = try mission.add(carrier_type, .{ 0, 0, 1000 });
        try std.testing.expect(try aigeneric.pushShip(ctx, ship, .land, carrier, null));
        aigeneric.objectOrders(ctx, ship);
        try std.testing.expectEqual(.fly_aimlessly, mission.slot(ship).current().?.order);
    }
}

test "the player's ship lands in a hangar bay of its carrier, and the mission is over" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var bremen_model: bay_launch.testing.Bremen = undefined;
    bremen_model.init();
    var variables: @import("../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    const ctx: Context = .of(world);
    const player = try mission.add(.of(.predator), .{ 100, 0, 0 });
    const bremen = try mission.add(.of(.bremen), .{ 0, 0, 50000 });
    try bremen_model.parts.fit(gpa, mission.slot(bremen));
    const other = try mission.add(.of(.predator), .{ 5, 5, 5 });
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, bremen, null));
    const slot = mission.slot(player);
    const state = &slot.state.land;

    // The bay's style. Aimed at the carrier as a whole, as the player's request aims it, the
    // landing is due `wait` ticks on, until which the player flies on.
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Style.bay, state.style);
    try std.testing.expectEqual(BayStep.waiting, state.step.as(BayStep));
    try std.testing.expectEqual(1000 + wait, state.due);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(BayStep.waiting, state.step.as(BayStep));

    // Then the cutaway: the carrier stopped far away, gate 0's doors opening, the ship out from
    // the bay's mouth looking in at the gate's launch point, flying by its nose and passing
    // through everything, and every other object disabled. The point lies 100 along the carrier's
    // Z axis, and the carrier's bounds reach 400 along it, where the bay's mouth is.
    mission.slot(bremen).object.bounds_min = .of(.{ -300, -300, -300 });
    mission.slot(bremen).object.bounds_max = .of(.{ 300, 300, 400 });
    mission.clock.frame_start = 1000 + wait;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(BayStep.approaching, state.step.as(BayStep));
    try std.testing.expectEqual(@import("main.zig").Showing.landing, mission.player.showing);
    try std.testing.expect(mission.slot(other).object.flags.disabled);
    try std.testing.expect(!mission.slot(bremen).object.flags.disabled and !slot.object.flags.disabled);
    try std.testing.expectEqual(carrier_away, mission.slot(bremen).object.nextPosition());
    try std.testing.expectEqual(0, mission.slot(bremen).object.order_count);
    const gate = carrier_away + Vector{ 0, 0, 100 };
    try std.testing.expectEqual(gate, @as(Vector, state.gate_place));
    try std.testing.expectEqual(carrier_away + Vector{ 0, 0, 400 }, @as(Vector, state.mouth));
    // The bay is 300 deep, so the ship starts six tenths of that out from the mouth, or twenty of
    // its radii where that is more.
    const approach = bayApproach(300, slot.object.radius);
    try std.testing.expectEqual(carrier_away + Vector{ 0, 0, 400 + approach }, slot.object.nextPosition());
    try std.testing.expectEqual(180, bayApproach(300, 0));
    try std.testing.expectEqual(16000, bayApproach(300, 800));
    const facing = math.forward(slot.object.root.next_orientation);
    try std.testing.expectApproxEqAbs(0, facing[0], 1e-5);
    try std.testing.expectApproxEqAbs(0, facing[1], 1e-5);
    try std.testing.expectApproxEqAbs(-1, facing[2], 1e-5);
    try std.testing.expectEqual(@import("motion.zig").Motion.plain, slot.motion.?);
    try std.testing.expect(slot.object.flags.no_collisions);
    const doors = mission.slot(bremen).model.?.parts;
    try std.testing.expectEqual(bay_launch.door_speed, doors[6].animation.speed);
    try std.testing.expectEqual(bay_launch.door_speed, doors[7].animation.speed);

    // Far from the point, it flies in at the throttle that flies it at `bay_speed` by its cruise
    // speed; nearer, at `approach_throttle` for each unit it has to go; and within `near`, it
    // stops, sounding its landing, and the doors close behind it.
    objects.setPosition(&slot.object, &slot.drawn, gate + Vector{ 0, 0, 50000 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectApproxEqAbs(bay_speed / gameobj.testing.flight.max_speed, slot.object.throttle, 1e-6);
    objects.setPosition(&slot.object, &slot.drawn, gate + Vector{ 0, 0, 1000 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectApproxEqAbs(1000 * approach_throttle, slot.object.throttle, 1e-6);
    objects.setPosition(&slot.object, &slot.drawn, gate + Vector{ 0, 0, 150 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(BayStep.landed, state.step.as(BayStep));
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(-bay_launch.door_speed, doors[6].animation.speed);

    // `landed_wait` ticks on, the mission is over.
    mission.ordersAfter(ctx, player, landed_wait);
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
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, bremen, 1));
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    const state = &mission.slot(player).state.land;
    try std.testing.expectEqual(1000, state.due);
    try std.testing.expectEqual(BayStep.approaching, state.step.as(BayStep));
    // Gate 1's launch point lies 200 along the carrier's Z axis.
    try std.testing.expectEqual(carrier_away + Vector{ 0, 0, 200 }, @as(Vector, state.gate_place));
}

test "the player's ship lands on a pad of the Yamato's landing bay, and the mission is over" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var bay_model: @import("launch.zig").testing.Bounded(bay_hangar + 1) = undefined;
    const hangar_bounds: [2]Vector = .{ .{ -10000, -20000, -30000 }, .{ 10000, 0, 30000 } };
    try bay_model.init(gpa, hangar_bounds);
    defer bay_model.deinit(gpa);
    var variables: @import("../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    world.spawn = mission.spawn(create.testing.no_models);
    const ctx: Context = .of(world);
    const player = try mission.add(.of(.predator), .{ 100, 0, 0 });
    const yamato = try mission.add(.of(.yamato), .{ 0, 0, 50000 });
    const other = try mission.add(.of(.predator), .{ 5, 5, 5 });
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, yamato, null));
    const slot = mission.slot(player);
    const state = &slot.state.land;

    // The Yamato's style, due `wait` ticks on, until which the player flies on; and the landing bay
    // made in the cutaway slot, passing through everything.
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Style.yamato, state.style);
    try std.testing.expectEqual(YamatoStep.waiting, state.step.as(YamatoStep));
    try std.testing.expectEqual(1000 + wait, state.due);
    const bay = mission.slot(create.cutaway_slot);
    try std.testing.expectEqual(gameobj.Type.of(.yamato_landing_bay), bay.object.type);
    try std.testing.expect(bay.object.flags.no_collisions);
    try bay_model.parts.fit(gpa, bay);
    bay.object.bounds_min = .of(hangar_bounds[0]);
    bay.object.bounds_max = .of(hangar_bounds[1]);

    // Then the cutaway: the bay far away, the ship standing in it, flying by its nose through
    // everything.
    mission.clock.frame_start = 1000 + wait;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(YamatoStep.descending, state.step.as(YamatoStep));
    try std.testing.expectEqual(1000 + wait + slide_after, state.due);
    try std.testing.expectEqual(carrier_away, bay.object.nextPosition());
    try std.testing.expectEqual(carrier_away + Vector{ -6000, -16000, -12000 }, slot.object.nextPosition());
    try std.testing.expectEqual(cutaway_throttle, slot.object.throttle);
    try std.testing.expectEqual(@import("motion.zig").Motion.plain, slot.motion.?);
    try std.testing.expect(slot.object.flags.no_collisions);

    // It flies over the hangar's middle, every other object disabled, and once near it, on.
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(@import("main.zig").Showing.landing, mission.player.showing);
    try std.testing.expect(mission.slot(other).object.flags.disabled);
    try std.testing.expectEqual(YamatoStep.descending, state.step.as(YamatoStep));
    const middle = carrier_away + Vector{ 0, -10000, 0 };
    objects.setPosition(&slot.object, &slot.drawn, middle - Vector{ 0, over_bay, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(YamatoStep.approaching, state.step.as(YamatoStep));

    // It flies to stand beyond the pad's middle, level with its underside, and stops near it.
    objects.setPosition(&slot.object, &slot.drawn, middle + Vector{ 0, 0, pad_ahead });
    objects.setOrientation(&slot.object, &slot.drawn, math.identity);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(YamatoStep.aligning, state.step.as(YamatoStep));

    // Straight along the bay and level, it stands on the pad, and rides it from then on.
    mission.clock.frame_start = 3000;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(YamatoStep.settling, state.step.as(YamatoStep));
    try std.testing.expectEqual(3000 + pad_settle, state.pad_due);
    try std.testing.expectEqual(objects.NodeOf{ .object = create.cutaway_slot, .part = landing_pad }, slot.riding.?);
    objects.setPosition(&slot.object, &slot.drawn, @splat(0));
    try std.testing.expect(hold(mission.objects, player));
    try std.testing.expectEqual(middle + Vector{ 0, 0, pad_ahead }, slot.object.nextPosition());

    // `pad_settle` ticks on, the pad lowers, and `lowered_wait` ticks later the mission is over.
    mission.ordersAfter(ctx, player, pad_settle + 1);
    try std.testing.expectEqual(YamatoStep.lowering, state.step.as(YamatoStep));
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(YamatoStep.down, state.step.as(YamatoStep));
    mission.ordersAfter(ctx, player, lowered_wait);
    try std.testing.expectEqual(0, variables.mission_over);
    mission.ordersAfter(ctx, player, 1);
    try std.testing.expectEqual(1, variables.mission_over);
}

test seen {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const player = try mission.add(.of(.predator), @splat(0));
    const reliant = try mission.add(.of(.reliant), .{ 0, 0, 1000 });
    try std.testing.expectEqual(null, seen(mission.objects, player));
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
    mission.slot(player).state.land.style = .reliant;
    mission.slot(player).state.land.tube = .{ 1, 2, 3 };
    const landing = seen(mission.objects, player).?.reliant;
    try std.testing.expectEqual(Vector{ 1, 2, 3 }, landing.tube);
    try std.testing.expectEqual(mission.slot(reliant).drawn.orientation, landing.carrier);
    // In a bay, the launch point's place and the bay's mouth the landing keeps.
    mission.slot(player).state.land.style = .bay;
    mission.slot(player).state.land.gate_place = .{ 4, 5, 6 };
    mission.slot(player).state.land.gate_orientation = math.identity;
    mission.slot(player).state.land.mouth = .{ 7, 8, 9 };
    const in_bay = seen(mission.objects, player).?.bay;
    try std.testing.expectEqual(Vector{ 4, 5, 6 }, in_bay.gate.position);
    try std.testing.expectEqual(Vector{ 7, 8, 9 }, in_bay.mouth);
}
