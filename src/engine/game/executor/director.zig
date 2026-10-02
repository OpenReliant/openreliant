//! The director's camera: for each shot the mission's script stacks ([`camera/shots.zig`](../camera/shots.zig)),
//! it flies the camera along a path of the mission's curves ([`curves.zig`](curves.zig)), or stands
//! it at a ship, over the shot's seconds, looking at a ship or turning from the angles of the ship
//! the path starts at to those of the ship it ends at. The camera shows it in its view 13
//! (`camera.View.director`), locked, and back in the cockpit once the path is over.
//!
//! **Unverified:** the source file. The code lies between `loadout.cpp`'s and `Executor.cpp`'s, and
//! the Executor's commands are what reach it.

const std = @import("std");
const log = std.log.scoped(.mission);

const dte = @import("../../../formats/dte.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const camera = @import("../camera.zig");
const shots = @import("../camera/shots.zig");
const curves = @import("curves.zig");
const events = @import("../mission/events.zig");
const gameobj = @import("../gameobj.zig");
const main = @import("../main.zig");
const mission = @import("../mission.zig");

/// What the director keeps of the shot on screen (`director`, `0x005251E8`).
pub const Director = struct {
    /// The curve the camera flies along (`director_curve`, `0x00525220`), null for none.
    curve: ?u16 = null,
    /// The ship the camera stands at in a shot with no curve (`director_still`, `0x00525270`).
    still: ?u16 = null,
    /// The ship the camera looks at (`director_tracked`, `0x00525244`), null to turn by `yaw` and
    /// `pitch`.
    tracked: ?u16 = null,
    /// The ship the path rides along with (`director_pace`, `0x00525268`), and where its object
    /// stood as the shot began (`director_pace_start`, `0x0052525C`).
    pace: ?u16 = null,
    pace_start: Vector = @splat(0),
    /// The yaw and the pitch the camera turns from and to over the curve, in degrees
    /// (`director_yaw`, `0x00525210`, and `director_pitch`, `0x00525218`).
    yaw: [2]f32 = .{ 0, 0 },
    pitch: [2]f32 = .{ 0, 0 },
    /// Ticks since the curve began (`director_elapsed`, `0x0052524C`).
    elapsed: u32 = 0,
    /// The shot's ticks (`director_ticks`, `0x00525250`), the length of its path
    /// (`director_path_length`, `0x00525254`), and the curve's share of the ticks
    /// (`director_curve_ticks`, `0x00525258`).
    total: u32 = 0,
    path_length: f32 = 0,
    ticks: u32 = 0,
    /// The share of the way along the curve to the next place a point marks
    /// (`director_next_marker`, `0x0052526C`), null for none.
    next_marker: ?f32 = null,
    /// The curves of the path begun so far, which end the path once they are as many as the
    /// mission has (`curves.following`). OpenReliant's own, for `curveEnd`'s **Fix**.
    taken: u16 = 0,

    /// How far along the curve the camera is, `ahead` of a tick past `elapsed`: from 0 at its
    /// start to 1 at its end (`curves.along`, whose **Fix** takes a curve its shot gives no ticks
    /// to its end, where the game places the camera nowhere).
    fn share(director: Director, ahead: f32) f32 {
        return curves.along(@as(f32, @floatFromInt(director.elapsed)) + ahead, director.ticks);
    }
};

/// `director_begin_shot` (`0x00450D10`): the camera of `world`, `view`, begins `shot`: its path, the
/// ship it looks at and the ship its path rides along with, and its seconds, taken whole, in ticks;
/// then the path's first curve, or the ship it stands at (`beginCurve`).
pub fn begin(world: gameobj.World, view: *camera.Camera, shot: shots.Shot) void {
    const director = &view.director;
    const list = world.missionCurves();
    var curve: ?u16 = null;
    director.still = null;
    if (shot.path) |path| switch (path) {
        .ship => |ship| director.still = ship,
        .curve => |index| curve = if (index < list.len) index else null,
    };
    director.pace = shot.pace;
    director.tracked = shot.tracked;
    if (shot.pace) |pace| if (drawnAt(world, pace)) |at| {
        director.pace_start = at;
    };
    director.total = std.math.lossyCast(u32, shot.seconds) *| main.ticks_per_second;
    director.path_length = if (curve) |first| curves.pathLength(list, first) else 0;
    director.taken = 0;
    log.debug("the director's camera takes a shot of {d} ticks, along curve {?d}, at ship {?d}", .{ director.total, curve, director.still });
    beginCurve(world, view, curve, true);
}

/// `director_begin_curve` (`0x00450D90`): the camera begins curve `curve` of the path, or stands at
/// the shot's ship where it has none, for its share of the shot's ticks: as its length is to the
/// path's, or all of them for a path of no length (`curves.pathShare`, with its **Fix**). It turns
/// from the yaw and the pitch of the ship the curve starts at to those of the ship it ends at, a
/// whole turn on where either is less, or by those of the ship it stands at; and it looks for the
/// first place a point marks on the curve. The shot's first curve puts the camera in the director's
/// view, locked (`camera_set_view`). A curve counts as one more the path has taken
/// (`Director.taken`).
///
/// **Fix:** the game reads the angles of a ship past the mission's for a curve that ends at none,
/// and of the ship at address zero for a shot with neither curve nor ship; OpenReliant turns the
/// camera by the ship the curve starts at alone, and holds it level where it has neither.
fn beginCurve(world: gameobj.World, view: *camera.Camera, curve: ?u16, first: bool) void {
    const director = &view.director;
    const list = world.missionCurves();
    director.curve = curve;
    if (curve != null) director.taken +|= 1;
    director.elapsed = 0;
    director.ticks = std.math.lossyCast(u32, curves.pathShare(list, curve, director.path_length) * @as(f32, @floatFromInt(director.total)));
    const ships = world.missionShips();
    const from_ship = if (curve) |index| list[index].startShip() else director.still;
    const to_ship = if (curve) |index| list[index].endShip() else director.still;
    const from = angles(ships, from_ship) orelse [2]f32{ 0, 0 };
    var to = angles(ships, to_ship) orelse from;
    for (&to, from) |*end, start| {
        if (end.* < start) end.* += full_turn;
    }
    director.yaw = .{ from[0], to[0] };
    director.pitch = .{ from[1], to[1] };
    director.next_marker = if (curve) |index| curves.nextMarker(ships, index, 0).at else null;
    if (first) _ = view.setView(.director, null, true, true, world.clock.viewTime());
}

/// A full turn, in degrees (`0x004DC3E0`).
const full_turn: f32 = 360;

/// The yaw and the pitch of mission ship `ship` as the mission's ships' records hold them, where
/// there is one.
fn angles(ships: []align(1) const dte.Ship, ship: ?u16) ?[2]f32 {
    const index = ship orelse return null;
    if (index >= ships.len) return null;
    return .{ @floatFromInt(ships[index].runtime_yaw), @floatFromInt(ships[index].runtime_pitch) };
}

/// `director_frame` (`0x00450FA0`), once a frame in the director's view (`camera_frame`): the curve
/// runs on by the frame's ticks. The camera stands at its point for how far along it is
/// (`place`), and passes each place a point marks (`curves.passMarker`), posting the point's
/// CameraReached (`director_progress`, `0x004510C0`, `events.cameraReached`), one a frame. It looks
/// at the ship it tracks, or else turns by the yaw and the pitch that far from the curve's first to
/// its last. At the curve's end, the next begins (`curveEnd`).
///
/// **Improvement:** the camera stands and turns `ahead` of a tick on, and where the ships are drawn
/// (`drawnAt`), so that with smooth motion it moves on every frame, as they do.
pub fn frame(world: gameobj.World, view: *camera.Camera, ahead: f32) void {
    const director = &view.director;
    director.elapsed +%= world.clock.frameTicks();
    const t = director.share(0);
    const shown = director.share(ahead);
    if (place(world, director.*, shown)) |at| view.place.position = at;
    if (director.curve) |curve| if (curves.passMarker(world.missionShips(), curve, director.next_marker, t)) |marker| {
        director.next_marker = marker.at;
        if (marker.passed) |ship| events.cameraReached(world, ship);
    };
    const yaw = math.lerp(director.yaw[0], director.yaw[1], shown);
    const pitch = math.lerp(director.pitch[0], director.pitch[1], shown);
    if (director.tracked) |ship| {
        if (drawnAt(world, ship)) |target| view.place = camera.lookingAt(view.place.position, target);
    } else {
        view.place.orientation = mission.yawPitch(yaw, pitch);
    }
    if (t >= 1) curveEnd(world, view);
}

/// `director_place` (`0x004511A0`): where the camera stands `t` of the way along the curve: its
/// point there (`curves.point`), or where the ship it stands at is; carried along with the ship the
/// path rides with, where it has one (`curves.ride`). Null for neither.
fn place(world: gameobj.World, director: Director, t: f32) ?Vector {
    const list = world.missionCurves();
    var at = if (director.curve) |curve|
        if (curve < list.len) curves.point(list[curve], t) else return null
    else if (director.still) |ship|
        drawnAt(world, ship) orelse return null
    else
        return null;
    if (director.pace) |pace| if (drawnAt(world, pace)) |now| {
        at = curves.ride(world.missionShips(), pace, at, director.pace_start, now);
    };
    return at;
}

/// `director_curve_end` (`0x00450F20`): the curve is over. The ship it ends at has its
/// CameraReached (`events.cameraReached`), and the curve that carries the path on from there begins
/// (`curves.following`); with none, the shot is over and the camera goes back to the player's
/// cockpit.
///
/// **Fix:** at a curve that ends at no ship, the game posts CameraReached on what lies past the
/// mission's ships, and carries the path on to a curve that starts or ends at none; OpenReliant
/// ends the path there, as its length has it (`curves.pathLength`). The path ends too once it has
/// taken as many curves as the mission has (`Director.taken`), where the game flies a path that
/// comes round on itself for ever, so that its shot and those after it never end.
fn curveEnd(world: gameobj.World, view: *camera.Camera) void {
    const list = world.missionCurves();
    if (view.director.curve) |index| if (index < list.len) {
        if (list[index].endShip()) |end| events.cameraReached(world, end);
        if (curves.following(list, index, view.director.taken)) |next| return beginCurve(world, view, @intCast(next), false);
    };
    _ = view.setView(.cockpit, world.objects.player, false, true, world.clock.viewTime());
}

/// Where the object of mission ship `ship` is drawn, where there is one.
fn drawnAt(world: gameobj.World, ship: u16) ?Vector {
    return if (ship < world.objects.slots.len) world.objects.slots[ship].drawn.position else null;
}

/// A mission of the ships `ships` and the curves `list`, each ship's object in the slot of its
/// index, and a camera on it.
const TestShot = struct {
    game: @import("../../vm.zig").machine.testing.Game,
    view: camera.Camera,

    /// Curve 0, from point 1 to point 2, and curve 1, which carries the path on to point 3.
    const path = [_]dte.Curve{
        dte.testing.curve(1, 2, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(2, 3, .{ 0, 0, 1000 }, .{ 0, 0, 3000 }),
    };

    fn init(shot: *TestShot, ships: []const dte.Ship, list: []const dte.Curve) !void {
        const gpa = std.testing.allocator;
        try shot.game.init(gpa, &.{}, .{ .ships = ships, .curves = list });
        errdefer shot.game.deinit();
        for (ships) |_| _ = try shot.game.mission.add(.predator, @splat(0));
        shot.view = .{};
    }

    fn world(shot: *TestShot) gameobj.World {
        var seen = shot.game.world();
        seen.camera = &shot.view;
        return seen;
    }

    /// The camera's frame, `ticks` long.
    fn frame(shot: *TestShot, ticks: i32) void {
        shot.game.mission.clock.frame_duration = ticks;
        const seen: camera.Subject = .{ .position = @splat(0), .orientation = math.identity };
        _ = shot.view.frame(.{ .object = seen, .player = seen, .ticks = @intCast(ticks), .game = shot.world() });
    }
};

test "a shot flies the camera along its path, turning, and back to the cockpit" {
    var ships = dte.testing.ships(4, dte.Ship.curve_point_kind);
    ships[1].yaw = 350;
    ships[2].yaw = 10;
    ships[2].pitch = 20;
    var shot: TestShot = undefined;
    try shot.init(&ships, &TestShot.path);
    defer shot.game.deinit();
    const view = &shot.view;

    shots.stack(shot.world(), view, .{ .path = .{ .curve = 0 }, .seconds = 2.5 });
    try std.testing.expectEqual(camera.View.director, view.view);
    try std.testing.expect(view.locked);
    // Two whole seconds, over a path 3000 long: the first curve's third of them.
    try std.testing.expectEqual(200, view.director.total);
    try std.testing.expectEqual(66, view.director.ticks);
    // Half way along the first curve, and half way round from 350 to 370 and up from 0 to 20.
    shot.frame(33);
    try std.testing.expectApproxEqAbs(500, view.place.position[2], 1e-3);
    const turned = mission.yawPitch(360, 10);
    try math.testing.expectMatrixWithin(turned, view.place.orientation, 1e-5);
    // At its end, the second carries the path on, for the rest of the ticks.
    shot.frame(33);
    try std.testing.expectEqual(1, view.director.curve);
    try std.testing.expectEqual(133, view.director.ticks);
    try std.testing.expectEqual(0, view.director.elapsed);
    shot.frame(100);
    try std.testing.expect(view.place.position[2] > 2000);
    try std.testing.expectEqual(camera.View.director, view.view);
    // Past its end, the shot is over: back to the cockpit, unlocked, and none waits.
    shot.frame(50);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expect(!view.locked);
    try std.testing.expectEqual(0, view.shots.count);
}

test "a still shot stands at its ship, looks at the one it tracks and holds ships still" {
    var ships = dte.testing.ships(4, dte.Ship.curve_point_kind);
    var shot: TestShot = undefined;
    try shot.init(&ships, &TestShot.path);
    defer shot.game.deinit();
    const view = &shot.view;
    const all = shot.game.mission.objects;
    all.slots[1].drawn.position = .{ 100, 0, 0 };
    all.slots[2].drawn.position = .{ 100, 0, 500 };

    const world = shot.world();
    shots.stack(world, view, .{ .path = .{ .ship = 1 }, .tracked = 2, .seconds = 1, .held = .at(3, null) });
    shots.stack(world, view, .{ .path = .{ .ship = 2 }, .seconds = 1 });
    try std.testing.expectEqual(2, view.shots.count);
    try std.testing.expect(all.slots[3].object.flags.jumping);
    shot.frame(50);
    try std.testing.expectEqual(Vector{ 100, 0, 0 }, view.place.position);
    try std.testing.expectApproxEqAbs(1, math.forward(view.place.orientation)[2], 1e-6);
    // Over, the next waiting begins at once, and the ship held goes.
    shot.frame(50);
    try std.testing.expectEqual(camera.View.director, view.view);
    try std.testing.expectEqual(1, view.shots.count);
    try std.testing.expectEqual(2, view.director.still);
    try std.testing.expect(!all.slots[3].object.flags.jumping);
    // With no ship to track, it turns by the ship's own angles: none.
    shot.frame(10);
    try std.testing.expectEqual(Vector{ 100, 0, 500 }, view.place.position);
    try std.testing.expectEqual(math.identity, view.place.orientation);
}

test "a path rides along with its ship, and passes the places points mark" {
    var ships = dte.testing.ships(5, dte.Ship.curve_point_kind);
    ships[0].kind = @intFromEnum(gameobj.Type.predator);
    ships[0].position = .{ 0, 0, 0 };
    ships[4].kind = dte.Ship.point_kind;
    ships[4].marker_curve = 0;
    ships[4].marker_at = 0.25;
    var shot: TestShot = undefined;
    try shot.init(&ships, &TestShot.path);
    defer shot.game.deinit();
    const view = &shot.view;
    const all = shot.game.mission.objects;

    // The ship stands 50 across as the shot begins, and moves on 50 more.
    all.slots[0].drawn.position = .{ 50, 0, 0 };
    shots.stack(shot.world(), view, .{ .path = .{ .curve = 0 }, .pace = 0, .seconds = 3 });
    try std.testing.expectEqual(0.25, view.director.next_marker);
    all.slots[0].drawn.position = .{ 100, 0, 0 };
    shot.frame(50);
    try std.testing.expectEqual(100, view.place.position[0]);
    // Past the marked place, the next is none.
    try std.testing.expectEqual(null, view.director.next_marker);
}

test "a shot given no seconds is at its curve's end at once, turned by the start alone" {
    var ships = dte.testing.ships(4, dte.Ship.curve_point_kind);
    ships[0].yaw = 30;
    var shot: TestShot = undefined;
    // A curve from point 0 to no ship.
    try shot.init(&ships, &.{dte.testing.curve(0, dte.Reference.unset, .{ 0, 0, 0 }, .{ 0, 0, 1000 })});
    defer shot.game.deinit();
    const view = &shot.view;

    shots.stack(shot.world(), view, .{ .path = .{ .curve = 0 }, .seconds = 0 });
    try std.testing.expectEqual(camera.View.director, view.view);
    try std.testing.expectEqual(0, view.director.ticks);
    // At the first frame the camera stands at the curve's end, turned by its start's angles, and
    // the curve, ending at no ship, ends the path: back to the cockpit.
    shot.frame(1);
    try std.testing.expectEqual(Vector{ 0, 0, 1000 }, view.place.position);
    try math.testing.expectMatrixWithin(mission.yawPitch(30, 0), view.place.orientation, 1e-5);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expectEqual(0, view.shots.count);
}

test "a shot with neither curve nor ship holds the camera where it is, level" {
    var ships = dte.testing.ships(4, dte.Ship.curve_point_kind);
    var shot: TestShot = undefined;
    try shot.init(&ships, &TestShot.path);
    defer shot.game.deinit();
    const view = &shot.view;
    view.place.position = .{ 7, 8, 9 };

    shots.stack(shot.world(), view, .{ .path = null, .seconds = 1 });
    try std.testing.expectEqual(camera.View.director, view.view);
    try std.testing.expectEqual(100, view.director.ticks);
    shot.frame(50);
    try std.testing.expectEqual(Vector{ 7, 8, 9 }, view.place.position);
    try std.testing.expectEqual(math.identity, view.place.orientation);
    try std.testing.expectEqual(camera.View.director, view.view);
    // After its 100 ticks, back to the cockpit.
    shot.frame(50);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
}

test "a path that comes round on itself ends with its shot" {
    var ships = dte.testing.ships(4, dte.Ship.curve_point_kind);
    var shot: TestShot = undefined;
    // Each curve carries the path on into the other.
    try shot.init(&ships, &.{
        dte.testing.curve(1, 2, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(2, 1, .{ 0, 0, 1000 }, .{ 0, 0, 0 }),
    });
    defer shot.game.deinit();
    const view = &shot.view;

    shots.stack(shot.world(), view, .{ .path = .{ .curve = 0 }, .seconds = 2 });
    try std.testing.expectEqual(100, view.director.ticks);
    shot.frame(100);
    try std.testing.expectEqual(1, view.director.curve);
    try std.testing.expectEqual(camera.View.director, view.view);
    // Once it has taken both, the shot is over.
    shot.frame(100);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expect(!view.locked);
    try std.testing.expectEqual(0, view.shots.count);
}
