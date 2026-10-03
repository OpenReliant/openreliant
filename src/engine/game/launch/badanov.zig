//! The Badanov and Krasny launches (`launch_badanov_init`, `0x00419F60`, and
//! `launch_badanov_run`, `0x0041A100`): a ship waits at one of ten positions along the bay,
//! facing out with its nose tilted down. The doors open, and the ship flies out with a yaw
//! input based on its gate. Normal flight resumes after 300 ticks.

const std = @import("std");
const log = std.log.scoped(.launch);

const math = @import("../../surrender/math.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srmesh = @import("../../surrender/surrenderlib/srmesh.zig");
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const shp = @import("../../../formats/shp.zig");
const sound3d = @import("../sound3d.zig");
const xtrabits = @import("../xtrabits.zig");
const bay = @import("bay.zig");
const launch = @import("../launch.zig");

/// The Badanov's steps after the common launch wait and delay.
pub const Step = enum(i32) {
    /// The doors open.
    open = 2,
    /// The ship lets go of its carrier and flies out.
    out = 3,
    /// The ship flies itself, and the launch ends.
    end = 4,
    _,
};

/// The part of the carrier's root's child list that the ship waits at (`0x00419F8D`), and the two
/// parts that are the bay's doors (`0x0041A1CB`, `0x0041A2FF`).
const bay_part = 4;
const doors = [_]usize{ 1, 2 };

/// Each side has five positions. Gates below this number use one side; the rest use the other
/// (`0x00419FFB`).
const gates_a_side = 5;

/// Offsets from the bay bounds' midpoint: half its height across, a fifth of its height up,
/// and a fifth of its length per gate relative to `first_gate_near` or `first_gate_far`
/// (`0x00419FD1`, `0x0041A01F`, `0x0041A03D`, `0x0041A05E`, `0x0041A082`).
const side_reach: f32 = 0.5;
const up_share: f32 = 0.2;
const along_share: f32 = 0.2;
const first_gate_near: f32 = 2;
const first_gate_far: f32 = 7;

/// The ship's nose is turned a quarter turn about the part's Y axis, one way for each side, then
/// down about its X axis by `tilt` (`0x0041A00C`, `0x0041A051`, `0x0041A09D`): 21.6 degrees.
/// **Improvement:** use an exact quarter turn instead of the original's rounded angle.
const quarter_turn: f32 = std.math.pi / 2.0;
const tilt: f32 = -0.37699112;

/// How long the doors take to open, in ticks: `open_ticks` and up to `open_spread` more, drawn from
/// the ship's own numbers (`object_random15`, `0x0041A282`, `0x0041A28F`).
const open_ticks = 200;
const open_spread = 100;

/// How long the ship flies out, in ticks (`0x0041A1EF`), and the throttle it flies out at
/// (`0x0041A202`).
const out_ticks = 300;
const out_throttle: f32 = 2;

/// Yaw is `(gate remainder 5 - steer_middle) * steer`, negated for the first side
/// (`0x0041A20C` to `0x0041A252`). The original uses signed remainder.
const steer: f32 = 0.2;
const steer_middle: f32 = 2.5;

/// `launch_badanov_init` (`0x00419F60`): places the ship in slot `index` at its gate's position
/// in `carrier`'s bay (`bay_part`), riding that part. The position uses the bounds of the last
/// drawn level. The ship turns a quarter turn about the part's Y axis, with opposite signs for
/// the two sides, then tilts down about its X axis.
///
/// **Fix:** if the model lacks the bay or its level, the ship stays where it is and rides the
/// carrier's root instead of dereferencing the missing part.
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const all = ctx.world.objects;
    const slot = &all.slots[index];
    const holder = &all.slots[carrier];
    slot.riding = .{ .object = carrier };
    const model = if (holder.model) |*held| held else return;
    const bounds = model.levelBounds(bay_part) orelse {
        log.warn("the carrier in slot {d} has no bay to launch from", .{carrier});
        return;
    };
    slot.riding = .{ .object = carrier, .part = bay_part };
    const gate = slot.orders[0].target.component;
    const number: f32 = @floatFromInt(gate);
    const size = bounds[1] - bounds[0];
    var at = (bounds[1] + bounds[0]) * @as(math.Vector, @splat(0.5));
    const near = gate < gates_a_side;
    at[0] += if (near) size[1] * side_reach else -size[1] * side_reach;
    at[1] += size[1] * up_share;
    at[2] += (number - if (near) first_gate_near else first_gate_far) * size[2] * along_share;
    const part = model.frameAt(bay_part, holder.drawn);
    var turned = math.turned(part.orientation, .y, if (near) quarter_turn else -quarter_turn);
    turned = math.turned(turned, .x, tilt);
    objects.setPlace(&slot.object, &slot.drawn, .{ .position = part.point(at), .orientation = turned });
}

/// `launch_badanov_run` (`0x0041A100`): opens the doors unless they are already moving, then
/// waits `open_ticks` plus a random delay below `open_spread`. It releases the ship with the
/// carrier's velocity, `out_throttle` and gate-based yaw. After `out_ticks`, it clears the
/// controls, restores forward motion and ends the launch.
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.launch;
    const now = world.clock.frame_start;
    const carrier = slot.orders[0].target.slotIn(all) orelse return launch.letGo(ctx, index);
    const carrier_slot = &all.slots[carrier];
    switch (state.step.as(Step)) {
        .open => {
            const wait: i32 = @intCast(xtrabits.objectRandom15(&slot.object) % open_spread);
            state.advance(.of(Step.out), now, open_ticks + wait);
            openDoors(world, carrier_slot);
        },
        .out => if (state.due < now) {
            slot.object.velocity = carrier_slot.object.velocity;
            state.advance(.of(Step.end), now, out_ticks);
            slot.object.throttle = out_throttle;
            const number: f32 = @floatFromInt(@rem(slot.orders[0].target.component, gates_a_side));
            slot.object.yaw_input = (number - steer_middle) * steer;
            if (slot.orders[0].target.component < gates_a_side) slot.object.yaw_input *= -1;
            state.attached = false;
            slot.motion = .plain;
        },
        .end => if (state.due < now) {
            slot.object.letGo();
            slot.motion = .forward;
            launch.letGo(ctx, index);
        },
        _ => {},
    }
}

/// Opens both doors from the track's start unless the first is already moving. Plays the sound
/// at the first door after starting both tracks.
fn openDoors(world: gameobj.World, carrier: *create.Slot) void {
    const model = if (carrier.model) |*live| live else return;
    const first = model.rootChild(doors[0]) orelse return;
    if (first.animation.mode != .none and first.animation.speed != 0) return;
    for (doors) |door| {
        if (model.rootChild(door) == null) continue;
        model.playNamed(door, bay.door_track, 0, .once, bay.door_speed);
    }
    sound3d.playFrom(world, first.drawn(), .dooropen, .not_reserved);
}

const testing = struct {
    /// A five-part model: bay 4 has bounds 200 wide and high, 600 long; doors 1 and 2 have
    /// an opening track. Initialize it in place because its records point into it.
    const Badanov = struct {
        mesh: srapiext.Mesh,
        levels: [1]srapiext.Level,
        tracks: [1]shp.Track,
        parts: objects.testing.Parts(5),

        fn init(badanov: *Badanov, gpa: std.mem.Allocator) !void {
            badanov.mesh = try srmesh.testing.square(gpa);
            badanov.mesh.bounds = .{ .{ -100, -100, -300 }, .{ 100, 100, 300 } };
            badanov.levels = .{.{ .mesh = &badanov.mesh, .until = std.math.inf(f32) }};
            badanov.tracks = .{.{ .clip = objects.testing.clip(100, .once, bay.door_track), .keyframes = &.{}, .events = &.{} }};
            badanov.parts.init();
            badanov.parts.loaded_parts[bay_part].levels = &badanov.levels;
            for (doors) |door| badanov.parts.data[door].tracks = &badanov.tracks;
        }

        fn deinit(badanov: *Badanov, gpa: std.mem.Allocator) void {
            badanov.mesh.deinit(gpa);
        }
    };
};

test openDoors {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var badanov_model: testing.Badanov = undefined;
    try badanov_model.init(gpa);
    defer badanov_model.deinit(gpa);
    const badanov = try mission.add(.badanov, .{ 0, 0, 10000 });
    try badanov_model.parts.fit(gpa, mission.slot(badanov));
    const model = &mission.slot(badanov).model.?;
    // Both doors play their track forward, from its start.
    model.parts[doors[0]].animation.time = 50;
    openDoors(mission.orders().world, mission.slot(badanov));
    for (doors) |door| {
        try std.testing.expectEqual(bay.door_speed, model.parts[door].animation.speed);
        try std.testing.expectEqual(0, model.parts[door].animation.time);
    }
    // While the first door is moving, another ship's launch leaves them as they are.
    model.parts[doors[0]].animation.time = 40;
    openDoors(mission.orders().world, mission.slot(badanov));
    try std.testing.expectEqual(40, model.parts[doors[0]].animation.time);
    // Stopped, it plays again.
    model.parts[doors[0]].animation.speed = 0;
    openDoors(mission.orders().world, mission.slot(badanov));
    try std.testing.expectEqual(0, model.parts[doors[0]].animation.time);
}

test "a ship launches from the Badanov's bay" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var badanov_model: testing.Badanov = undefined;
    try badanov_model.init(gpa);
    defer badanov_model.deinit(gpa);
    _ = try mission.add(.predator, @splat(0));
    const badanov = try mission.add(.badanov, .{ 0, 0, 10000 });
    try badanov_model.parts.fit(gpa, mission.slot(badanov));
    mission.slot(badanov).object.velocity = .{ .x = 0, .y = 0, .z = 5 };
    const ship = try mission.add(.sabre, @splat(0));
    const far = try mission.add(.sabre, @splat(0));
    const ctx = mission.orders();
    for ([_]u16{ ship, far }, [_]u16{ 1, 7 }) |each, gate| {
        _ = try aigeneric.pushShip(ctx, each, .launch, badanov, gate);
        aigeneric.objectOrders(ctx, each);
    }
    const slot = mission.slot(ship);
    const state = &slot.state.launch;
    try std.testing.expectEqual(launch.Style.badanov, state.style);

    // Gate 1 is 100 across, 40 up and 120 behind the bay's midpoint.
    try std.testing.expect(state.attached);
    try std.testing.expectEqual(badanov, slot.riding.?.object);
    try std.testing.expectEqual(bay_part, slot.riding.?.part.?);
    try std.testing.expectApproxEqAbs(100, slot.drawn.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(40, slot.drawn.position[1], 1e-3);
    try std.testing.expectApproxEqAbs(10000 - 120, slot.drawn.position[2], 1e-3);
    // It faces out across the bay, its nose 21.6 degrees down (the Y axis points down).
    const nose = math.forward(slot.drawn.orientation);
    try std.testing.expectApproxEqAbs(@cos(tilt), nose[0], 1e-4);
    try std.testing.expectApproxEqAbs(-@sin(tilt), nose[1], 1e-4);
    // Gate 7 is on the other side, at the bay's longitudinal midpoint.
    const away = mission.slot(far);
    try std.testing.expectApproxEqAbs(-100, away.drawn.position[0], 1e-3);
    try std.testing.expectApproxEqAbs(10000, away.drawn.position[2], 1e-3);

    // Started, past its delay, the doors open.
    launch.start(mission.objects, ship);
    aigeneric.objectOrders(ctx, ship);
    launch.testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(Step.out, state.step.as(Step));
    const model = &mission.slot(badanov).model.?;
    try std.testing.expectEqual(bay.door_speed, model.parts[1].animation.speed);
    try std.testing.expect(state.due - mission.clock.frame_start >= 0);

    // Past the wait, it lets go and flies out with the Badanov's velocity, steering by its gate:
    // gate 1 of five, (1 - 2.5) * 0.2 = -0.3, the near side turned about.
    launch.testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(Step.end, state.step.as(Step));
    try std.testing.expect(!state.attached);
    try std.testing.expectEqual(.plain, slot.motion.?);
    try std.testing.expectEqual(out_throttle, slot.object.throttle);
    try std.testing.expectEqual(5, slot.object.velocity.z);
    try std.testing.expectApproxEqAbs(0.3, slot.object.yaw_input, 1e-6);

    // Normal flight resumes, and the ship stops passing through the Badanov.
    launch.testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(0, slot.object.yaw_input);
    try std.testing.expectEqual(null, slot.object.passes_through[0].index());
    try std.testing.expect(slot.current() == null or slot.current().?.order != .launch);
}
