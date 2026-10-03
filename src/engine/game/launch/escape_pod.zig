//! Escape-pod launches: both use `launch_point_init` (`0x0041A4B0`) to wait at a carrier's
//! launch point. `launch_pod_run` (`0x0041A4D0`) gives the first pod a random throttle and a
//! yaw input based on its gate. `launch_pod_other_run` (`0x0041B690`) sends the other pod
//! straight out. Both play the escape sound and keep passing through their carrier afterward.

const std = @import("std");

const aigeneric = @import("../aigeneric.zig");
const gameobj = @import("../gameobj.zig");
const sound3d = @import("../sound3d.zig");
const launch = @import("../launch.zig");

/// The first pod's steps after the common launch wait and delay.
pub const Step = enum(i32) {
    /// The pod lets go and drifts off.
    leave = 2,
    /// It drifts until `drift_ticks` have passed.
    drift = 3,
    _,
};

/// The other pod's steps after the common launch wait and delay.
pub const OtherStep = enum(i32) {
    /// Its sound plays.
    sound = 2,
    /// It lets go and flies out.
    leave = 3,
    /// It flies out until `out_ticks` have passed.
    out = 4,
    _,
};

/// The sound a pod leaves with (`0x0041A5E3`, `0x0041B6A9`), played at the pod at its full volume.
const leave_sound: sound3d.sounds.Sound = .escape;

/// How long the first pod drifts, in ticks (`0x0041A5FB`).
const drift_ticks = 200;

/// The first pod's throttle starts at `drift_throttle` and adds a random fraction of
/// `drift_spread` (`0x0041A56E`, `0x0041A57A`, `libcmt.Rand.fraction`).
const drift_throttle: f32 = 2;
const drift_spread: f32 = 0.5;

/// Below `turn_split`, yaw is `(gate - low_middle) * low_turn`; otherwise it is
/// `(gate - high_middle) * high_turn` (`0x0041A58A` to `0x0041A5D4`).
const turn_split = 7;
const low_middle: f32 = 3;
const low_turn: f32 = 1.0 / 12.0;
const high_middle: f32 = 7;
const high_turn: f32 = 1.0 / 16.0;

/// How long the other pod flies out, in ticks (`0x0041B6E8`), and the throttle it flies out at
/// (`0x0041B6D7`).
const out_ticks = 200;
const out_throttle: f32 = 2;

/// The yaw input of the first pod launching through `gate` (`0x0041A58A`).
fn turnOf(gate: i16) f32 {
    const number: f32 = @floatFromInt(gate);
    return if (gate < turn_split) (number - low_middle) * low_turn else (number - high_middle) * high_turn;
}

/// `launch_pod_run` (`0x0041A4D0`): releases the first pod in slot `index`, plays its sound and
/// starts plain motion with a random throttle and gate-based yaw (`turnOf`). After `drift_ticks`,
/// it clears the throttle, restores forward motion and ends the order. The yaw input and
/// carrier pass-through entry remain unchanged.
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = &slot.state.launch;
    const now = world.clock.frame_start;
    switch (state.step.as(Step)) {
        .leave => {
            state.attached = false;
            slot.motion = .plain;
            slot.object.throttle = world.random.fraction() * drift_spread + drift_throttle;
            slot.object.yaw_input = turnOf(slot.orders[0].target.component);
            sound3d.playIn(world, null, null, index, leave_sound, 1, .not_reserved);
            state.advance(.of(Step.drift), now, drift_ticks);
        },
        .drift => if (state.due < now) {
            slot.object.throttle = 0;
            slot.motion = .forward;
            launch.finish(ctx, index);
        },
        _ => {},
    }
}

/// `launch_pod_other_run` (`0x0041B690`): plays the other pod's sound, then releases it on the
/// next update at `out_throttle` with plain motion. After `out_ticks`, it clears throttle and
/// yaw, restores forward motion and ends the order. The carrier pass-through entry remains.
pub fn runOther(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = &slot.state.launch;
    const now = world.clock.frame_start;
    switch (state.step.as(OtherStep)) {
        .sound => {
            sound3d.playIn(world, null, null, index, leave_sound, 1, .not_reserved);
            state.step = .of(OtherStep.leave);
        },
        .leave => {
            state.attached = false;
            slot.object.throttle = out_throttle;
            state.advance(.of(OtherStep.out), now, out_ticks);
            slot.motion = .plain;
        },
        .out => if (state.due < now) {
            slot.object.throttle = 0;
            slot.object.yaw_input = 0;
            slot.motion = .forward;
            launch.finish(ctx, index);
        },
        _ => {},
    }
}

const testing = struct {
    /// Creates a pod of type `kind` on an Ulysses and runs its launch past the common delay.
    /// Returns the pod's slot.
    fn started(mission: *gameobj.testing.Mission, carrier_model: *launch.testing.Carrier, kind: gameobj.Type) !u16 {
        const gpa = std.testing.allocator;
        _ = try mission.add(.predator, @splat(0));
        const carrier = try mission.add(.ulysses, .{ 1000, 0, 0 });
        try carrier_model.parts.fit(gpa, mission.slot(carrier));
        const pod = try mission.add(kind, @splat(0));
        const ctx = mission.orders();
        _ = try aigeneric.pushShip(ctx, pod, .launch, carrier, 0);
        aigeneric.objectOrders(ctx, pod);
        launch.start(mission.objects, pod);
        aigeneric.objectOrders(ctx, pod);
        launch.testing.pastDue(mission, ctx, pod);
        return pod;
    }
};

test turnOf {
    // The first pod's turn grows with its gate, either side of the split.
    try std.testing.expectEqual(-0.25, turnOf(0));
    try std.testing.expectEqual(0, turnOf(3));
    try std.testing.expectApproxEqAbs(0.25, turnOf(6), 1e-6);
    try std.testing.expectEqual(0, turnOf(7));
    try std.testing.expectEqual(0.125, turnOf(9));
}

test run {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var carrier_model: launch.testing.Carrier = undefined;
    carrier_model.init();
    const pod = try testing.started(&mission, &carrier_model, .escape_pod);
    const ctx = mission.orders();
    const slot = mission.slot(pod);
    const state = &slot.state.launch;
    try std.testing.expectEqual(launch.Style.escape_pod, state.style);

    // It lets go and drifts off, at a throttle from 2 to 2.5, turning by its gate (0).
    try std.testing.expectEqual(Step.drift, state.step.as(Step));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(.plain, slot.motion.?);
    try std.testing.expect(slot.object.throttle >= drift_throttle and slot.object.throttle <= drift_throttle + drift_spread);
    try std.testing.expectEqual(turnOf(0), slot.object.yaw_input);

    // Normal flight resumes, but the pod still passes through its carrier.
    launch.testing.pastDue(&mission, ctx, pod);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expect(slot.current() == null or slot.current().?.order != .launch);
    try std.testing.expectEqual(null, slot.riding);
    try std.testing.expect(slot.object.flags.targetable);
    try std.testing.expect(slot.object.passes_through[0].index() != null);
}

test runOther {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var carrier_model: launch.testing.Carrier = undefined;
    carrier_model.init();
    const pod = try testing.started(&mission, &carrier_model, .other_escape_pod);
    const ctx = mission.orders();
    const slot = mission.slot(pod);
    const state = &slot.state.launch;
    try std.testing.expectEqual(launch.Style.other_escape_pod, state.style);

    // Its sound plays; at the next update, without waiting, it flies out.
    try std.testing.expectEqual(OtherStep.leave, state.step.as(OtherStep));
    try std.testing.expect(state.attached);
    aigeneric.objectOrders(ctx, pod);
    try std.testing.expectEqual(OtherStep.out, state.step.as(OtherStep));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(out_throttle, slot.object.throttle);
    try std.testing.expectEqual(.plain, slot.motion.?);

    // The launch ends with normal flight and no throttle or yaw input.
    slot.object.yaw_input = 0.5;
    launch.testing.pastDue(&mission, ctx, pod);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expect(slot.current() == null or slot.current().?.order != .launch);
    try std.testing.expect(slot.object.passes_through[0].index() != null);
}
