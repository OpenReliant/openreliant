//! A torpedo's launch from its tube (`launch_torpedo_init`, `0x0041A360`, and `launch_torpedo_run`,
//! `0x0041A390`), whatever launches it: it waits at one of its carrier's launch points, then boosts
//! away at twice its speed, trailing, before it flies itself.

const std = @import("std");
const log = std.log.scoped(.launch);

const aigeneric = @import("../aigeneric.zig");
const gameobj = @import("../gameobj.zig");
const missiles = @import("../missiles.zig");
const sound3d = @import("../sound3d.zig");
const launch = @import("../launch.zig");

/// A torpedo's launch steps, after `launch.Step`'s two.
pub const Step = enum(i32) {
    /// It leaves the tube.
    fire = 2,
    /// It boosts away, until its boost has lasted `boost_ticks`.
    boost = 3,
    _,
};

/// How long the boost lasts, in ticks (`0x0041A400`).
const boost_ticks = 200;

/// The throttle it boosts at (`0x0041A454`).
const boost_throttle: f32 = 2;

/// The sound it leaves the tube with, as loud as it goes (`0x0041A410`).
const fire_sound: sound3d.sounds.Sound = .missile10;

/// The look of its trail, a torpedo's (`0x0041A49C`).
const trail_look: missiles.Type = .torpedo;

/// `launch_torpedo_init` (`0x0041A360`): the torpedo in slot `index` collides with nothing, and
/// stands at the launch point of its carrier, in slot `carrier`, that its gate names
/// (`launch.attachAtGate`), riding the part that holds it.
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    ctx.world.objects.slots[index].object.flags.no_collisions = true;
    launch.attachAtGate(ctx, index, carrier);
}

/// `launch_torpedo_run` (`0x0041A390`): as its launch reaches step 2, the torpedo in slot `index`
/// lets go of its tube, heard, and boosts away along its nose at `boost_throttle`
/// (`motion.Motion.plain`), steering nothing, from its carrier's velocity, trailing smoke as a
/// torpedo does. Once the boost has lasted `boost_ticks`, it flies itself, collides again, and
/// its launch ends (`launch.finish`).
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.launch;
    const now = ctx.world.clock.frame_start;
    switch (state.step.as(Step)) {
        .fire => {
            state.advance(.of(Step.boost), now, boost_ticks);
            state.attached = false;
            sound3d.playIn(world, null, null, index, fire_sound, 1, .not_reserved);
            const object = &slot.object;
            object.holdTurns();
            object.throttle = boost_throttle;
            slot.motion = .plain;
            if (slot.orders[0].target.slotIn(all)) |carrier| object.velocity = all.slots[carrier].object.velocity;
            if (world.trails) |trails| _ = trails.start(world, .{ .object = index }, trail_look) catch |err| {
                log.warn("a torpedo's trail is left out: {s}", .{@errorName(err)});
            };
        },
        .boost => if (state.due <= now) {
            slot.motion = .forward;
            launch.finish(ctx, index);
            slot.object.flags.no_collisions = false;
        },
        _ => {},
    }
}

test run {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: launch.testing.Carrier = undefined;
    carrier_model.init();
    _ = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.kamov, .{ 1000, 0, 0 });
    try carrier_model.parts.fit(gpa, mission.slot(carrier));
    mission.slot(carrier).object.velocity = .{ .x = 0, .y = 0, .z = 5 };
    const torpedo = try mission.add(.torpedo, @splat(0));
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, torpedo, .launch, carrier, 1);
    aigeneric.objectOrders(ctx, torpedo);
    launch.start(mission.objects, torpedo);
    aigeneric.objectOrders(ctx, torpedo);
    const slot = mission.slot(torpedo);
    const state = &slot.state.launch;
    try std.testing.expect(state.attached);

    // Past its wait, it leaves the tube, boosting at the carrier's velocity with nothing to ride.
    launch.testing.pastDue(&mission, ctx, torpedo);
    try std.testing.expectEqual(Step.boost, state.step.as(Step));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(.plain, slot.motion.?);
    try std.testing.expectEqual(boost_throttle, slot.object.throttle);
    try std.testing.expectEqual(5, slot.object.velocity.z);

    // Once the boost is done, it flies itself, collides and can be targeted, its launch over.
    mission.clock.frame_start = state.due;
    aigeneric.objectOrders(ctx, torpedo);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expect(!slot.object.flags.no_collisions);
    try std.testing.expectEqual(null, slot.riding);
    // It still passes through what launched it.
    try std.testing.expectEqual(carrier, slot.object.passes_through[0].index());
}
