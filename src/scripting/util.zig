//! The `openreliant.util` package ([#557](https://github.com/OpenReliant/openreliant/issues/557)):
//! orientations, turning points between the world and an object's own frame, and angles
//! (`package`). Luau's `vector` library has the rest of the vector maths.
//!
//! The game's frame is right-handed: an object's X axis points to its right, its Y axis down and
//! its Z axis forward, out of its nose. An orientation is where those three axes point in the world
//! (`Orientation`), as the engine keeps them in the columns of a matrix (`math.Matrix`).

const std = @import("std");

const openreliant = @import("openreliant");
const math = openreliant.engine.surrender.math;
const api = @import("api.zig");
const Call = api.Call;

const Vector = @Vector(3, f32);

/// Where an object's axes point in the world: to its right, down and forward.
pub const Orientation = struct {
    right: Vector,
    down: Vector,
    forward: Vector,

    /// The orientation a matrix of the engine's holds in its columns.
    pub fn of(columns: math.Matrix) Orientation {
        return .{ .right = math.xAxis(columns), .down = math.yAxis(columns), .forward = math.forward(columns) };
    }

    /// The matrix whose columns are its axes.
    pub fn matrix(orientation: Orientation) math.Matrix {
        return math.fromAxes(orientation.right, orientation.down, orientation.forward);
    }
};

/// What `openreliant.util` holds.
pub const package = struct {
    pub const to_world = api.Function("The point of the world that `point` is in the frame of something at `position` turned as `orientation`: `point`'s x to its right, y down and z forward of it.", &.{ "position", "orientation", "point" }, toWorld);
    pub const to_local = api.Function("Where the point of the world `point` is in the frame of something at `position` turned as `orientation`: x to its right, y down and z forward of it.", &.{ "position", "orientation", "point" }, toLocal);
    pub const angle_off = api.Function("The angle in radians between the forward axis of something at `position` turned as `orientation` and the direction to `point`: 0 dead ahead, pi straight behind.", &.{ "position", "orientation", "point" }, angleOff);
    pub const look_at = api.Function("The orientation whose forward axis points along `direction`, turned about its Y axis, then its X axis, with no roll, as the game turns a ship to look at something.", &.{"direction"}, lookAt);
    pub const turn = api.Function("`orientation` turned by `angle` radians about its own `axis`: right-handed, so about its Y axis, which points down, a positive angle turns its nose to the right.", &.{ "orientation", "axis", "angle" }, turnAbout);
    pub const angles = api.Function("The angles in radians that `orientation` is turned by from looking along the world's Z axis, as the game reads them: x the pitch, y the yaw and z the roll.", &.{"orientation"}, anglesOf);
    pub const from_angles = api.Function("The orientation turned by `angles` in radians from looking along the world's Z axis, as `angles` gives them: about X, then Y, then Z.", &.{"angles"}, fromAngles);
    pub const normalize_angle = api.Function("`angle` in radians brought within half a turn either way, from -pi to pi.", &.{"angle"}, normalizeAngle);
};

fn toWorld(_: Call, position: Vector, orientation: Orientation, point: Vector) Vector {
    return position + math.transform(orientation.matrix(), point);
}

fn toLocal(_: Call, position: Vector, orientation: Orientation, point: Vector) Vector {
    return math.transformTransposed(orientation.matrix(), point - position);
}

fn angleOff(_: Call, position: Vector, orientation: Orientation, point: Vector) f32 {
    const toward = point - position;
    if (math.length(toward) == 0) return 0;
    return std.math.acos(std.math.clamp(math.cosineOff(toward, math.normalize(orientation.forward)), -1, 1));
}

fn lookAt(_: Call, direction: Vector) Orientation {
    return .of(math.lookAt(direction));
}

fn turnAbout(_: Call, orientation: Orientation, axis: math.Axis, angle: f32) Orientation {
    return .of(math.turned(orientation.matrix(), axis, angle));
}

fn anglesOf(_: Call, orientation: Orientation) Vector {
    return math.angles(orientation.matrix());
}

fn fromAngles(_: Call, turned: Vector) Orientation {
    return .of(math.fromAngleVector(turned));
}

fn normalizeAngle(_: Call, angle: f32) f32 {
    return angle - std.math.tau * @round(angle / std.math.tau);
}

test Orientation {
    const turned = math.fromAngles(0.3, -0.7, 1.1);
    try std.testing.expectEqual(turned, Orientation.of(turned).matrix());
    try math.testing.expectVector(.{ 0, 0, 1 }, Orientation.of(math.identity).forward);
}

test "util turns points between the world and an object's frame" {
    const call: Call = undefined;
    const ahead = lookAt(call, .{ 1, 0, 0 });
    try math.testing.expectVector(.{ 1, 0, 0 }, ahead.forward);
    // A point 10 ahead of something at (5, 0, 0) looking along X is at (15, 0, 0), and back.
    const point = toWorld(call, .{ 5, 0, 0 }, ahead, .{ 0, 0, 10 });
    try math.testing.expectVector(.{ 15, 0, 0 }, point);
    try math.testing.expectVector(.{ 0, 0, 10 }, toLocal(call, .{ 5, 0, 0 }, ahead, point));
    try std.testing.expectApproxEqAbs(0, angleOff(call, .{ 5, 0, 0 }, ahead, point), 1e-3);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, angleOff(call, .{ 5, 0, 0 }, ahead, .{ 5, 0, 10 }), 1e-3);
    // Turning about the Y axis, which points down, turns the nose to the right.
    const right = turnAbout(call, .of(math.identity), .y, std.math.pi / 2.0);
    try math.testing.expectVector(.{ 1, 0, 0 }, right.forward);
    try math.testing.expectVector(.{ 0.3, -0.2, 0.1 }, anglesOf(call, fromAngles(call, .{ 0.3, -0.2, 0.1 })));
    try std.testing.expectApproxEqAbs(-std.math.pi / 2.0, normalizeAngle(call, 3 * std.math.pi / 2.0), 1e-5);
    try std.testing.expectApproxEqAbs(0.5, normalizeAngle(call, 0.5 - 4 * std.math.pi), 1e-5);
}

test "scripts read objects' orientations, and give util whole ones" {
    const gpa = std.testing.allocator;
    const runtime = @import("runtime.zig");
    const packages = @import("packages.zig");
    const objects = @import("objects.zig");
    const bind = @import("bind.zig");
    var mission: openreliant.engine.game.gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const player = try mission.add(.predator, .{ 0, 0, 0 });
    const scripts = try runtime.Runtime.create(gpa, std.testing.io, &.{}, .{ .side = .game, .limits = .{ .time = .fromSeconds(1), .memory = 1 << 20 }, .seed = 1, .version = "0.7.0" });
    defer scripts.destroy();
    objects.register(scripts);
    packages.push(scripts);
    scripts.objects = mission.objects;
    const thread = scripts.state.newSandboxedThread();
    var context: runtime.Context = .{ .runtime = scripts, .mod = 0, .family = .global, .thread = thread, .thread_ref = undefined };
    thread.setThreadData(&context);
    objects.push(thread, player);
    thread.setGlobal("player");
    try bind.testing.runSource(thread,
        \\local util = require("openreliant.util")
        \\local o = player.orientation
        \\assert(o.forward == vector.create(0, 0, 1) and o.down == vector.create(0, 1, 0))
        \\local ahead = util.to_world(player.position, o, vector.create(0, 0, 50))
        \\assert(ahead == vector.create(0, 0, 50) and util.angle_off(player.position, o, ahead) == 0)
    );
    try bind.testing.expectSourceError(thread, "local util = require('openreliant.util'); util.angles({ right = vector.one, down = vector.one })", "the field 'forward' is missing");
}
