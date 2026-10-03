//! A ship's launch from the rogue base's first six gates (`0x0041B770` and `0x0041B7F0`): it waits
//! at one of the base's launch points, set back along its nose, then backs out of the base for a
//! second before it flies itself. From the seventh gate on, the base launches from a bay
//! (`launch.Style.of`).

const std = @import("std");

const aigeneric = @import("../aigeneric.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const launch = @import("../launch.zig");

/// A launch from the rogue base's steps, after `launch.Step`'s two.
pub const Step = enum(i32) {
    /// The ship lets go of the base and backs away.
    leave = 2,
    /// It backs away until `back_ticks` have passed.
    back = 3,
    _,
};

/// How far the ship waits behind its launch point, along its nose (`0x0041B799`).
const set_back: f32 = 500;

/// How long the ship backs away, in ticks (`0x0041B7DF`), and its throttle while it does
/// (`0x0041B7C6`).
const back_ticks = 100;
const back_throttle: f32 = -2;

/// `launch_rogue_init` (`0x0041B770`): places the ship in slot `index` at the launch point of the rogue base, in slot
/// `carrier`, for its gate (`launch.attachAtGate`), riding the part that holds it, then moves it
/// back along its own nose by `set_back`.
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const slot = &ctx.world.objects.slots[index];
    launch.attachAtGate(ctx, index, carrier);
    objects.setPosition(&slot.object, &slot.drawn, slot.drawn.point(.{ 0, 0, -set_back }));
}

/// `launch_rogue_run` (`0x0041B7F0`): the launch of the ship in slot `index` from step 2 on.
///
/// 1. The ship lets go of the base and drops along its Y axis (`motion.Motion.downward`) at a
///    throttle of `back_throttle`.
/// 2. After `back_ticks`, it flies itself (`motion.Motion.forward`) with its throttle and yaw
///    input at 0, and the launch lets it go (`launch.letGo`).
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.launch;
    const now = ctx.world.clock.frame_start;
    switch (state.step.as(Step)) {
        .leave => {
            slot.motion = .downward;
            state.attached = false;
            slot.object.throttle = back_throttle;
            state.advance(.of(Step.back), now, back_ticks);
        },
        .back => if (state.due < now) {
            slot.motion = .forward;
            slot.object.throttle = 0;
            slot.object.yaw_input = 0;
            launch.letGo(ctx, index);
        },
        _ => {},
    }
}

test "a ship backs out of the rogue base" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: launch.testing.Carrier = undefined;
    carrier_model.init();
    _ = try mission.add(.predator, @splat(0));
    const base = try mission.add(.rogue_base, .{ 1000, 0, 0 });
    try carrier_model.parts.fit(gpa, mission.slot(base));
    const ship = try mission.add(.sabre, @splat(0));
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, ship, .launch, base, 0);
    aigeneric.objectOrders(ctx, ship);
    const slot = mission.slot(ship);
    const state = &slot.state.launch;
    try std.testing.expectEqual(launch.Style.rogue_base, state.style);

    // It waits at the first launch point, 10 along the second part and turned half a turn, then set
    // back 500 along its nose: 500 further along the part's Z.
    try std.testing.expect(state.attached);
    try std.testing.expectEqual(base, slot.riding.?.object);
    try std.testing.expectApproxEqAbs(1100, slot.drawn.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(510, slot.drawn.position[2], 1e-3);

    // Started, past its delay, it lets go and backs away.
    launch.start(mission.objects, ship);
    aigeneric.objectOrders(ctx, ship);
    launch.testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(Step.back, state.step.as(Step));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(.downward, slot.motion.?);
    try std.testing.expectEqual(back_throttle, slot.object.throttle);

    // A second later it flies itself, passing through the base no more, its launch over.
    slot.object.yaw_input = 0.5;
    launch.testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    try std.testing.expectEqual(null, slot.object.passes_through[0].index());
    try std.testing.expect(slot.current() == null or slot.current().?.order != .launch);
}
