//! The Yamato's landing (`land_yamato_init`, `0x0040EB60`, and `land_yamato_update`,
//! `0x0040EE80`): the ship flies into the Yamato's landing bay, a ship type of its own made in the
//! cutaway slot, and comes down onto its pad, which lowers it.

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
const objects = @import("../objects.zig");
const sound3d = @import("../sound3d.zig");

/// The Yamato's steps (`land_yamato_update`, `0x0040EE80`).
pub const Step = enum(u32) {
    /// The player flies on until the landing is due; then the cutaway begins (`cutaway`).
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
/// (`0x004DC440`). A landing in a hangar bay flies at most as fast (`ailand.bay`).
pub const bay_speed: f32 = 100;

/// How far beyond the pad's middle along the bay the ship is to stand, and how near it gets before
/// it stops (`0x004DC4A8`); how far ahead along its nose it steers meanwhile (`0x0040F1D1`); and
/// the throttle it approaches with, `ailand.approach_throttle` for each unit it has to go less
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

/// `land_yamato_init` (`0x0040EB60`): the first step, due `ailand.wait` ticks on; for the player's
/// ship, the landing bay made in the cutaway slot, passing through everything.
pub fn init(ctx: Context, index: u16) void {
    const world = ctx.world;
    const state = &world.objects.slots[index].state.land;
    state.step = .of(Step.waiting);
    state.due = world.clock.frame_start + ailand.wait;
    if (index != world.objects.player) return;
    const bay = create.make(world, create.cutaway_slot, .of(.yamato_landing_bay)) catch |err| {
        log.warn("the Yamato's landing bay is left out: {s}", .{@errorName(err)});
        return;
    } orelse return;
    world.objects.slots[bay].object.flags.no_collisions = true;
}

/// `land_yamato_update` (`0x0040EE80`): a step of the Yamato's landing (`Step`). A ship other than
/// the player's lets its landing go at once (`order_pop`).
///
/// While the landing is not yet due, the player's ship flies by the player's controls. Then the
/// cutaway begins (`cutaway`), and the ship flies by its nose (`motion.Motion.plain`), passing
/// through everything. The mission's scene becomes the landing's, and every other object is
/// disabled. The ship steers at `over_bay` above the hangar's middle, upright, at `bay_speed`,
/// until it is within `over_bay_near` of it. Then it steers `pad_lead` ahead along its nose from
/// the place `pad_ahead` beyond the pad's middle, level with its own underside, its throttle
/// `ailand.approach_throttle` for each unit it has to go less `approach_least`, at most
/// `bay_speed`, and stops within `on_pad_near` of it. There it turns straight along the bay and
/// level (`alignInputs`), and once it is, it stands on the pad, which it rides (`hold`).
/// `pad_settle` ticks on, the pad lowers, sounding the ship's landing, and `lowered_wait` ticks
/// after that the mission is over.
///
/// **Improvement:** the angles come from `std.math.atan2` rather than the engine's table
/// (`sr_atan2`), as they do elsewhere in OpenReliant.
pub fn update(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    if (index != all.player) return aigeneric.end(ctx, index);
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.land;
    const now = world.clock.frame_start;
    const bay = &all.slots[create.cutaway_slot];
    switch (state.step.as(Step)) {
        .waiting => {
            if (now < state.due) return input.playerControlOrder(ctx, index);
            cutaway(ctx, index);
            state.step = .of(Step.descending);
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
            if (math.distance(point, object.nextPosition()) < over_bay_near) state.step = .of(Step.approaching);
        },
        .approaching => {
            const pad = partMiddle(bay, landing_pad) orelse return;
            const point = pad.frame.point(pad.middle) + Vector{ 0, object.bounds_min.y, pad_ahead };
            const distance = math.distance(point, object.nextPosition());
            const lead = point + math.forward(object.root.next_orientation) * @as(Vector, @splat(pad_lead));
            _ = ai.steer(world, index, lead, ai.full_limit, ai.no_ease, .{ .roll_upright = true });
            object.throttle = @min(distance * ailand.approach_throttle - approach_least, bayThrottle(world, slot));
            if (distance < on_pad_near) state.step = .of(Step.aligning);
        },
        .aligning => {
            alignInputs(slot);
            object.roll_input = 0;
            object.throttle = 0;
            if (@abs(object.yaw_input) >= aligned or @abs(object.pitch_input) >= aligned) return;
            state.step = .of(Step.settling);
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
            state.step = .of(Step.lowering);
        },
        .lowering => {
            // And again as the pad starts down (`0x0040F4F5`).
            object.letGo();
            if (bay.model) |*model| if (model.rootChild(landing_pad) != null) model.playNamed(landing_pad, pad_track, 0, null, 1);
            sound3d.playIn(world, null, null, index, .shipland, 1, .not_reserved);
            state.step = .of(Step.down);
            state.pad_due = now + lowered_wait;
        },
        .down => ailand.endAfter(world, state.pad_due),
        _ => {},
    }
}

/// `land_yamato_cutaway` (`0x0040EBC0`): the cutaway of the Yamato's landing. The landing bay
/// moves to `ailand.carrier_away`, turned as the world is, its hangar lit through
/// `bay_light_mask`. One of its two views, picked at random, watches the ship, locked. The ship
/// stands in the bay at `stand_share` of the bay's bounds, looking at the hangar's middle, stopped,
/// its throttle `cutaway_throttle` and its power shared evenly.
///
/// **Fix:** the game reads past the bay's list of parts where its model lacks the hangar; then
/// OpenReliant leaves the ship turned as it was.
///
/// Left out: the view picked, which the game keeps (`0x0051863C`) and nothing reads.
fn cutaway(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const bay = &all.slots[create.cutaway_slot];
    ailand.moveAway(bay);
    if (bay.model) |*model| if (model.rootChild(bay_hangar) != null) {
        model.parts[bay_hangar].object.light_mask = bay_light_mask;
    };
    ailand.watch(world, index, .{ .landing_bay, .landing_ship });
    const max = bay.object.bounds_max.vector();
    const min = bay.object.bounds_min.vector();
    const away: math.Place = .{ .position = ailand.carrier_away };
    objects.setPosition(object, &slot.drawn, away.point(max * stand_share + min * (@as(Vector, @splat(1)) - stand_share)));
    if (partMiddle(bay, bay_hangar)) |hangar| {
        objects.setOrientation(object, &slot.drawn, math.lookAt(hangar.frame.point(hangar.middle) - object.nextPosition()));
    }
    ailand.stopShip(object);
    object.throttle = cutaway_throttle;
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
    const cruise = ai.slotCruise(slot, world.view()) orelse return 0;
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

/// Each frame's placing of a ship on the Yamato's pad (`main.frameObjects`): from `Step.settling`
/// on, the ship stands where it came to rest on the pad, as the pad lowers. Returns whether it
/// placed the ship.
pub fn hold(all: *create.Objects, index: u16) bool {
    const slot = &all.slots[index];
    if (slot.running(.land) == null) return false;
    const state = &slot.state.land;
    if (state.landing() != .yamato or !state.step.reached(Step.settling)) return false;
    const pad = (slot.riding orelse return false).place(all) orelse return false;
    const on_pad: math.Place = .{ .position = state.on_pad, .orientation = state.pad_orientation };
    objects.setPlace(&slot.object, &slot.drawn, on_pad.within(pad));
    return true;
}

/// What the landing's views stand by (`camera.View.landing_bay`): where the landing bay stands,
/// the bounds of its hangar, and the tick the view slides from.
pub fn seen(all: *const create.Objects, state: *const State) ?camera.Landing {
    const bay = &all.slots[create.cutaway_slot];
    const model = if (bay.model) |*held| held else return null;
    const hangar = model.partBounds(bay_hangar) orelse return null;
    return .{ .yamato = .{ .bay = bay.drawn, .hangar = hangar, .due = state.due } };
}

test "the player's ship lands on a pad of the Yamato's landing bay, and the mission is over" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var bay_model: @import("../launch.zig").testing.Bounded(bay_hangar + 1) = undefined;
    const hangar_bounds: [2]Vector = .{ .{ -10000, -20000, -30000 }, .{ 10000, 0, 30000 } };
    try bay_model.init(gpa, hangar_bounds);
    defer bay_model.deinit(gpa);
    var variables: @import("../../vm.zig").Variables = .{};
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
    try std.testing.expectEqual(ailand.Style.yamato, state.landing().?);
    try std.testing.expectEqual(Step.waiting, state.step.as(Step));
    try std.testing.expectEqual(1000 + ailand.wait, state.due);
    const bay = mission.slot(create.cutaway_slot);
    try std.testing.expectEqual(gameobj.Type.of(.yamato_landing_bay), bay.object.type);
    try std.testing.expect(bay.object.flags.no_collisions);
    try bay_model.parts.fit(gpa, bay);
    bay.object.bounds_min = .of(hangar_bounds[0]);
    bay.object.bounds_max = .of(hangar_bounds[1]);

    // Then the cutaway: the bay far away, the ship standing in it, flying by its nose through
    // everything.
    mission.clock.frame_start = 1000 + ailand.wait;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.descending, state.step.as(Step));
    try std.testing.expectEqual(1000 + ailand.wait + slide_after, state.due);
    try std.testing.expectEqual(ailand.carrier_away, bay.object.nextPosition());
    try std.testing.expectEqual(ailand.carrier_away + Vector{ -6000, -16000, -12000 }, slot.object.nextPosition());
    try std.testing.expectEqual(cutaway_throttle, slot.object.throttle);
    try std.testing.expectEqual(@import("../motion.zig").Motion.plain, slot.motion.?);
    try std.testing.expect(slot.object.flags.no_collisions);

    // It flies over the hangar's middle, every other object disabled, and once near it, on.
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(@import("../main.zig").Showing.landing, mission.player.showing);
    try std.testing.expect(mission.slot(other).object.flags.disabled);
    try std.testing.expectEqual(Step.descending, state.step.as(Step));
    const middle = ailand.carrier_away + Vector{ 0, -10000, 0 };
    objects.setPosition(&slot.object, &slot.drawn, middle - Vector{ 0, over_bay, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.approaching, state.step.as(Step));

    // It flies to stand beyond the pad's middle, level with its underside, and stops near it.
    objects.setPosition(&slot.object, &slot.drawn, middle + Vector{ 0, 0, pad_ahead });
    objects.setOrientation(&slot.object, &slot.drawn, math.identity);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.aligning, state.step.as(Step));

    // Straight along the bay and level, it stands on the pad, and rides it from then on.
    mission.clock.frame_start = 3000;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.settling, state.step.as(Step));
    try std.testing.expectEqual(3000 + pad_settle, state.pad_due);
    try std.testing.expectEqual(objects.NodeOf{ .object = create.cutaway_slot, .part = landing_pad }, slot.riding.?);
    objects.setPosition(&slot.object, &slot.drawn, @splat(0));
    try std.testing.expect(hold(mission.objects, player));
    try std.testing.expectEqual(middle + Vector{ 0, 0, pad_ahead }, slot.object.nextPosition());

    // `pad_settle` ticks on, the pad lowers, and `lowered_wait` ticks later the mission is over.
    mission.ordersAfter(ctx, player, pad_settle + 1);
    try std.testing.expectEqual(Step.lowering, state.step.as(Step));
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.down, state.step.as(Step));
    mission.ordersAfter(ctx, player, lowered_wait);
    try std.testing.expectEqual(0, variables.mission_over);
    mission.ordersAfter(ctx, player, 1);
    try std.testing.expectEqual(1, variables.mission_over);
}
