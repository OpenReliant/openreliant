//! A ship's launch from the Zakov (`launch_zakov_init`, `0x0041B8B0`, and `launch_zakov_run`,
//! `0x0041B940`): it waits on one of the Zakov's launch points, then flies straight out along its
//! nose at twice its throttle for a second before it flies itself.

const std = @import("std");

const aigeneric = @import("../aigeneric.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const launch = @import("../launch.zig");

/// A launch from the Zakov's steps, after `launch.Step`'s two.
pub const Step = enum(i32) {
    /// It lets go of the Zakov.
    leave = 2,
    /// It flies straight out, until it has for `out_ticks`.
    out = 3,
    _,
};

/// How long it flies straight out, in ticks (`0x0041B9DB`).
const out_ticks = 100;

/// The throttle it flies out at (`0x0041B9C4`).
const out_throttle: f32 = 2;

/// `launch_zakov_init` (`0x0041B8B0`): places the ship in slot `index` at the launch point of the
/// Zakov, in slot `carrier`, that its gate names (`launch.attach`), riding the part that holds it.
/// Then it moves the ship forward along its own nose by how far its bounding box reaches behind its
/// centre (`bounds_min`).
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    launch.attach(all, index, carrier, slot.orders[0].target.component);
    objects.setPosition(&slot.object, &slot.drawn, slot.drawn.point(.{ 0, 0, -slot.object.bounds_min.z }));
}

/// `launch_zakov_run` (`0x0041B940`): as its launch reaches step 2, the ship in slot `index` lets
/// go of the Zakov and flies straight out along its nose at `out_throttle` (`motion.Motion.plain`).
/// Once it has flown out for longer than `out_ticks`, it flies itself, with its throttle and its
/// yaw input zeroed, and its launch ends (`launch.finish`).
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.launch;
    const now = ctx.world.clock.frame_start;
    switch (state.step.as(Step)) {
        .leave => {
            slot.motion = .plain;
            state.attached = false;
            slot.object.throttle = out_throttle;
            state.advance(.of(Step.out), now, out_ticks);
        },
        .out => if (state.due < now) {
            slot.motion = .forward;
            slot.object.throttle = 0;
            slot.object.yaw_input = 0;
            launch.finish(ctx, index);
        },
        _ => {},
    }
}

test init {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: launch.testing.Carrier = undefined;
    carrier_model.init();
    _ = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.zakov, .{ 1000, 0, 0 });
    try carrier_model.parts.fit(gpa, mission.slot(carrier));
    const fighter = try mission.add(.sabre, .{ 0, 5000, 0 });
    const slot = mission.slot(fighter);
    slot.object.bounds_min.z = -12;
    _ = try aigeneric.pushShip(mission.orders(), fighter, .launch, carrier, 0);
    aigeneric.objectOrders(mission.orders(), fighter);

    // It rides the part that holds the gate's launch point, 12 forward of the point along its
    // nose, which the point turns half a turn about Y.
    try std.testing.expectEqual(launch.Style.zakov, slot.state.launch.style);
    try std.testing.expect(slot.state.launch.attached);
    try std.testing.expectEqual(carrier, slot.riding.?.object);
    const point = gameobj.vector(carrier_model.attachments[1].position);
    const expected = mission.slot(carrier).drawn.point(point + gameobj.vector(.{ .x = 100, .y = 0, .z = 0 }));
    try std.testing.expectApproxEqAbs(expected[0], slot.drawn.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(expected[2] - 12, slot.drawn.position[2], 1e-3);
}

test run {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: launch.testing.Carrier = undefined;
    carrier_model.init();
    _ = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.zakov, .{ 1000, 0, 0 });
    try carrier_model.parts.fit(gpa, mission.slot(carrier));
    const fighter = try mission.add(.sabre, @splat(0));
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, fighter, .launch, carrier, 0);
    aigeneric.objectOrders(ctx, fighter);
    launch.start(mission.objects, fighter);
    aigeneric.objectOrders(ctx, fighter);
    const slot = mission.slot(fighter);
    const state = &slot.state.launch;

    // Past its wait, it lets go and flies straight out at twice its throttle.
    launch.testing.pastDue(&mission, ctx, fighter);
    try std.testing.expectEqual(Step.out, state.step.as(Step));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(.plain, slot.motion.?);
    try std.testing.expectEqual(out_throttle, slot.object.throttle);

    // Not yet at the end of its time out, it keeps going.
    mission.clock.frame_start = state.due;
    aigeneric.objectOrders(ctx, fighter);
    try std.testing.expectEqual(Step.out, state.step.as(Step));

    // Past it, it flies itself, its throttle and yaw zeroed, and can be targeted, its launch over.
    slot.object.yaw_input = 0.5;
    mission.clock.frame_start = state.due + 1;
    aigeneric.objectOrders(ctx, fighter);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    try std.testing.expectEqual(null, slot.riding);
    // It still passes through the Zakov.
    try std.testing.expectEqual(carrier, slot.object.passes_through[0].index());
}
