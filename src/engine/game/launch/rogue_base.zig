//! The rogue base's first six gates use `launch_rogue_init` (`0x0041B770`) and
//! `launch_rogue_run` (`0x0041B7F0`). A ship waits behind its launch point, then uses downward
//! motion at negative throttle for 100 ticks before normal flight resumes. Later gates use
//! the common bay style (`launch.Style.of`).

const std = @import("std");

const aigeneric = @import("../aigeneric.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const launch = @import("../launch.zig");

/// The rogue base's steps after the common launch wait and delay.
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

/// `launch_rogue_init` (`0x0041B770`): places the ship in slot `index` at its gate's launch
/// point on `carrier`, riding the part that holds it, then moves it `set_back` behind the point
/// along the ship's forward axis.
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const slot = &ctx.world.objects.slots[index];
    launch.attachAtGate(ctx, index, carrier);
    objects.setPosition(&slot.object, &slot.drawn, slot.drawn.point(.{ 0, 0, -set_back }));
}

/// `launch_rogue_run` (`0x0041B7F0`): releases the ship in slot `index` with downward motion
/// and `back_throttle`. After `back_ticks`, it clears throttle and yaw, restores forward
/// motion and ends the launch, removing the carrier pass-through entry.
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

    // After 100 ticks, normal flight resumes and the ship stops passing through the base.
    slot.object.yaw_input = 0.5;
    launch.testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    try std.testing.expectEqual(null, slot.object.passes_through[0].index());
    try std.testing.expect(slot.current() == null or slot.current().?.order != .launch);
}
