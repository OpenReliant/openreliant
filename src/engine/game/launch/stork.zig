//! A satellite's launch from the Stork (`launch_point_init`, `0x0041A4B0`, and `launch_stork_run`,
//! `0x0041AD10`). The satellite waits at one of the Stork's launch points. Then it flies out along
//! its nose, slows to a stop, opens out its parts and flies on by itself.

const std = @import("std");

const shp = @import("../../../formats/shp.zig");
const aigeneric = @import("../aigeneric.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const launch = @import("../launch.zig");

/// A launch's steps from the Stork, after `launch.Step`'s two.
pub const Step = enum(i32) {
    /// The ship lets go of the Stork and flies out.
    leave = 2,
    /// It flies out until `out_ticks` have passed, then its throttle drops to 0.
    out = 3,
    /// It opens out its parts, and the launch ends.
    deploy = 4,
    _,
};

/// How long the ship flies out, in ticks (`0x0041ADF4`).
const out_ticks = 400;

/// How long step 4 is set to wait (`0x0041ADD3`). It doesn't wait: it runs at the next update.
const deploy_ticks = 200;

/// The throttle the ship flies out at (`0x0041ADDD`).
const out_throttle: f32 = 2;

/// The track every part of the ship plays as it opens out (`0x004E1690`), from its start, once, at
/// `deploy_speed` (`0x0041AD49`).
const deploy_track = "deploy";
const deploy_speed: f32 = 4;

/// `launch_stork_run` (`0x0041AD10`): the launch of the ship in slot `index` from step 2 on.
///
/// 1. The ship lets go of the Stork and flies out along its nose at `out_throttle`
///    (`motion.Motion.plain`).
/// 2. After `out_ticks`, its throttle drops to 0.
/// 3. At the next update, each of its parts plays the `deploy` track. The ship flies itself
///    (`motion.Motion.forward`) and the launch lets it go (`launch.letGo`).
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const state = &slot.state.launch;
    const now = ctx.world.clock.frame_start;
    switch (state.step.as(Step)) {
        .leave => {
            slot.object.throttle = out_throttle;
            state.advance(.of(Step.out), now, out_ticks);
            state.attached = false;
            slot.motion = .plain;
        },
        .out => if (state.due < now) {
            slot.object.throttle = 0;
            state.advance(.of(Step.deploy), now, deploy_ticks);
        },
        .deploy => {
            if (slot.model) |*model| model.playNamedTree(deploy_track, 0, .once, deploy_speed);
            slot.motion = .forward;
            launch.letGo(ctx, index);
        },
        _ => {},
    }
}

/// A satellite's model for the tests: two parts, each with the `deploy` track.
const Satellite = struct {
    tracks: [1]shp.Track,
    parts: objects.testing.Parts(2),

    fn init(satellite: *Satellite) void {
        satellite.tracks = .{.{ .clip = objects.testing.clip(200, .once, deploy_track), .keyframes = &.{}, .events = &.{} }};
        satellite.parts.init();
        for (&satellite.parts.data) |*part| part.tracks = &satellite.tracks;
    }
};

test run {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var stork_model: launch.testing.Carrier = undefined;
    stork_model.init();
    var satellite_model: Satellite = undefined;
    satellite_model.init();
    _ = try mission.add(.predator, @splat(0));
    const stork = try mission.add(.stork, .{ 0, 0, 10000 });
    try stork_model.parts.fit(gpa, mission.slot(stork));
    const satellite = try mission.add(.satellite, .{ -5000000, 0, -5000000 });
    try satellite_model.parts.fit(gpa, mission.slot(satellite));
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, satellite, .launch, stork, 0);
    aigeneric.objectOrders(ctx, satellite);

    // It waits at the Stork's first launch point, 10 along the second part, riding it.
    const slot = mission.slot(satellite);
    const state = &slot.state.launch;
    try std.testing.expectEqual(launch.Style.stork, state.style);
    try std.testing.expect(state.attached);
    try std.testing.expectEqual(stork, slot.riding.?.object);
    try std.testing.expectApproxEqAbs(100, slot.drawn.position[0], 1e-3);

    // Started, past its delay, it lets go and flies out.
    launch.start(mission.objects, satellite);
    aigeneric.objectOrders(ctx, satellite);
    launch.testing.pastDue(&mission, ctx, satellite);
    try std.testing.expectEqual(Step.out, state.step.as(Step));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(.plain, slot.motion.?);
    try std.testing.expectEqual(out_throttle, slot.object.throttle);

    // Its throttle drops to 0 once it has flown out.
    launch.testing.pastDue(&mission, ctx, satellite);
    try std.testing.expectEqual(Step.deploy, state.step.as(Step));
    try std.testing.expectEqual(0, slot.object.throttle);

    // At the next update, without waiting, it opens out and flies itself, its launch over.
    try std.testing.expect(state.due > mission.clock.frame_start);
    aigeneric.objectOrders(ctx, satellite);
    for (slot.model.?.parts) |part| try std.testing.expectEqual(deploy_speed, part.animation.speed);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expect(slot.current() == null or slot.current().?.order != .launch);
    try std.testing.expectEqual(null, slot.riding);
}
