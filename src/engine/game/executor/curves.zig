//! A mission's curves (`mission_curves`, section `curves` of a [`.DTE`](../../../../docs/formats/dte.md)):
//! the points along each, how long a path of them is, and the curve that carries a path on. The
//! director's camera flies along them ([`director.zig`](director.zig)).
//!
//! **Unverified:** the source file. The code lies between `loadout.cpp`'s and `Executor.cpp`'s, and
//! the Executor's commands are what reach it.

const std = @import("std");

const dte = @import("../../../formats/dte.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;

const Curve = dte.Curve;

/// The point `t` of the way along `curve`, from 0 at its start to 1 at its end, and on past them
/// for a `t` past them (`curve_point`, `0x00457050`, a component at a time in `curve_axis`,
/// `0x00457090`): its ends weighed by the Hermite functions `2t³ - 3t² + 1` and `3t² - 2t³`, its
/// leaving tangent by `t³ - 2t² + t` and its arriving tangent, turned about, by `t² - t³`, the
/// weights `hermite_from`, `hermite_to`, `hermite_leaving` and `hermite_arriving` (`0x00457130` to
/// `0x004571B0`), each tangent `tangent_scale` times as long as the record has it.
pub fn point(curve: Curve, t: f32) Vector {
    const t2 = t * t;
    const t3 = t2 * t;
    const leaving: Vector = @as(Vector, curve.leaving) * @as(Vector, @splat(tangent_scale));
    const arriving: Vector = @as(Vector, curve.arriving) * @as(Vector, @splat(-tangent_scale));
    return @as(Vector, curve.to) * @as(Vector, @splat(3 * t2 - 2 * t3)) +
        @as(Vector, curve.from) * @as(Vector, @splat(2 * t3 - 3 * t2 + 1)) +
        arriving * @as(Vector, @splat(t3 - t2)) +
        leaving * @as(Vector, @splat(t3 - 2 * t2 + t));
}

/// How many times longer a curve's tangents weigh than the record has them (`curve_axis`,
/// `0x00457090`, whose `PUSH 0x41200000` at `0x004570B6` gives it).
pub const tangent_scale: f32 = 10;

/// How long `curve` is (`curve_length`, `0x00457250`): the sum of the chords between its points at
/// each `steps`th of the way (`curve_length_between`, `0x00457260`).
///
/// **Improvement:** the game takes the points from a table of the four weights at each 32nd of the
/// way (`curve_weights`, `0x00529FC0`), which `curve_weights_fill` (`0x00456F00`) fills as
/// `mission_script_start` begins, through `curve_point_stepped` (`0x00456F70`); OpenReliant
/// computes them.
pub fn length(curve: Curve) f32 {
    var sum: f32 = 0;
    var before = point(curve, 0);
    for (1..steps + 1) |n| {
        const at = point(curve, @as(f32, @floatFromInt(n)) / steps);
        sum += math.distance(at, before);
        before = at;
    }
    return sum;
}

/// The steps a curve is measured by (`0x004DC724`, and a 32nd, `0x004DC478`).
pub const steps = 32;

/// `curve_starting_at` (`0x004571D0`): the first of `curves` that starts at ship `ship`, or null
/// for none.
pub fn starting(curves: []align(1) const Curve, ship: u16) ?usize {
    for (curves, 0..) |curve, n| {
        if (curve.startShip() == ship) return n;
    }
    return null;
}

/// `curve_next` (`0x00457200`): the curve that carries a path on from ship `at`, other than
/// `curves[from]`: the first that starts there, or, unless `starting_only`, that ends there. Null
/// for none.
pub fn next(curves: []align(1) const Curve, from: usize, at: u16, starting_only: bool) ?usize {
    for (curves, 0..) |curve, n| {
        if (n == from) continue;
        if (curve.startShip() == at) return n;
        if (!starting_only and curve.endShip() == at) return n;
    }
    return null;
}

/// The curve that carries a path on from `curves[at]`, the path having taken `taken` curves: the
/// one that carries it on from the ship `curves[at]` ends at (`next`); null where it ends at no
/// ship, or none carries it on. Each walk along a path goes so: its length (`curve_path_length`,
/// `0x00457320`), the director's camera from one curve to the next (`director_curve_end`,
/// `0x00450F20`), and Ship Follow Curve Backwards' search for the curve before one
/// (`follow_back_curve`, `0x00403580`).
///
/// **Fix:** the game walks a path that comes round on itself for ever, which two curves that end
/// at the same ship are enough for, as each carries the path on into the other; OpenReliant ends
/// the path once it has taken as many curves as the mission has.
pub fn following(curves: []align(1) const Curve, at: usize, taken: usize) ?usize {
    if (taken >= curves.len or at >= curves.len) return null;
    const end = curves[at].endShip() orelse return null;
    return next(curves, at, end, false);
}

/// `curve_path_length` (`0x00457320`): how long the path from `curves[first]` is: that curve, and
/// each that carries it on (`following`), to one that ends at no ship.
pub fn pathLength(curves: []align(1) const Curve, first: usize) f32 {
    if (first >= curves.len) return 0;
    var sum = length(curves[first]);
    var at = first;
    var taken: usize = 1;
    while (following(curves, at, taken)) |n| : (taken += 1) {
        sum += length(curves[n]);
        at = n;
    }
    return sum;
}

/// `curve_ride` (`0x004574A0`): `on`, a point of a path that rides along with mission ship `ship`,
/// carried with it: by how far `start` lies from where the mission placed the ship (its record in
/// `ships`), and, where `now` is given, by how far the ship has come from `start` to `now`. A path
/// that rides with no ship stays where it is (`0x004574A9`), as one with a ship past the mission's
/// does.
pub fn ride(ships: []align(1) const dte.Ship, ship: ?u16, on: Vector, start: Vector, now: ?Vector) Vector {
    const index = ship orelse return on;
    if (index >= ships.len) return on;
    const placed: Vector = ships[index].position;
    var carried = on;
    if (now) |at| carried += at - start;
    return carried + (start - placed);
}

/// A curve's next marker, as `nextMarker` finds it: the share of the way to it, null where no point
/// marks a place past the share it was asked from, and the point the camera passes at that share,
/// where there is one.
pub const Marker = struct { at: ?f32, passed: ?u16 };

/// `curve_next_marker` (`0x00457510`): the nearest place on curve `curve` past `after` that one of
/// the mission's points marks (`dte.Ship.markedCurve`), and the last of the points that mark
/// `after` itself.
pub fn nextMarker(ships: []align(1) const dte.Ship, curve: u16, after: f32) Marker {
    var found: Marker = .{ .at = null, .passed = null };
    for (ships, 0..) |ship, n| {
        if (ship.markedCurve() != curve) continue;
        if (ship.marker_at > after) {
            found.at = if (found.at) |nearest| @min(nearest, ship.marker_at) else ship.marker_at;
        } else if (ship.marker_at == after) {
            found.passed = @intCast(n);
        }
    }
    return found;
}

/// A path passing along curve `curve`, `t` of the way, the next place a point marks on it at
/// `next`: once `t` is past that place, the marker past it (`nextMarker`), whose `at` is the place
/// to look for next and whose `passed` is the point passed; null until then, and where no place is
/// left. The director's camera and Ship Follow Curve pass the places so, one an update
/// (`director_progress`, `0x00451119`, and `follow_curve_way`, `0x0040326D`).
pub fn passMarker(ships: []align(1) const dte.Ship, curve: u16, next_at: ?f32, t: f32) ?Marker {
    const at = next_at orelse return null;
    if (!(t > at)) return null;
    return nextMarker(ships, curve, at);
}

/// How far along a curve given `ticks` a path is, `elapsed` ticks after the curve began: from 0 at
/// its start to 1 at its end. Ship Follow Curve and the director's camera both time their curves
/// so.
///
/// **Fix:** the game divides by nothing for a curve given no ticks, which gives an endless share;
/// OpenReliant takes such a curve to its end.
pub fn along(elapsed: f32, ticks: u32) f32 {
    if (ticks == 0) return 1;
    return elapsed / @as(f32, @floatFromInt(ticks));
}

/// The share of a path's ticks that curve `curve` of `list` takes: its length over the path's,
/// `path_length`. Ship Follow Curve and the director's camera both share a path's ticks so.
///
/// **Fix:** the game divides by nothing for a path of no length; OpenReliant gives its curve all
/// the path's ticks. A curve the list lacks takes none.
pub fn pathShare(list: []align(1) const Curve, curve: ?u16, path_length: f32) f32 {
    if (path_length == 0) return 1;
    const index = curve orelse return 0;
    if (index >= list.len) return 0;
    return length(list[index]) / path_length;
}

test "a curve runs from its start to its end, bowed by its tangents" {
    var curve = dte.testing.curve(0, 1, .{ 0, 0, 0 }, .{ 0, 0, 1000 });
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, point(curve, 0));
    try std.testing.expectEqual(Vector{ 0, 0, 1000 }, point(curve, 1));
    // Without tangents, a straight line, eased at the ends: half way at the middle.
    try std.testing.expectEqual(Vector{ 0, 0, 500 }, point(curve, 0.5));
    try std.testing.expectApproxEqAbs(1000, length(curve), 1e-2);
    // Heading out to the side as it leaves and back as it arrives, the middle bows that way, by
    // the tangents' weight; heading out the same way at both ends, it swings through the middle.
    curve.leaving = .{ 100, 0, 0 };
    curve.arriving = .{ 100, 0, 0 };
    try std.testing.expectApproxEqAbs(250, point(curve, 0.5)[0], 1e-3);
    curve.arriving = .{ -100, 0, 0 };
    try std.testing.expectApproxEqAbs(0, point(curve, 0.5)[0], 1e-3);
    try std.testing.expect(point(curve, 0.25)[0] > 0 and point(curve, 0.75)[0] < 0);
    // Past its end the cubic runs on, turning back the way it came.
    try std.testing.expect(point(curve, 1.1)[2] < 1000);
}

test "a path runs on through the curves that carry it" {
    const curves = [_]Curve{
        dte.testing.curve(0, 1, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(1, 2, .{ 0, 0, 1000 }, .{ 0, 0, 3000 }),
        dte.testing.curve(2, dte.Reference.unset, .{ 0, 0, 3000 }, .{ 0, 0, 3000 }),
        dte.testing.curve(dte.Reference.unset, 5, .{ 0, 0, 0 }, .{ 0, 0, 10 }),
    };
    try std.testing.expectEqual(1, starting(&curves, 1));
    try std.testing.expectEqual(null, starting(&curves, 7));
    // A curve that starts at no ship starts at none, as one that ends at none ends at none.
    try std.testing.expectEqual(null, starting(&curves, dte.Reference.unset));
    try std.testing.expectEqual(null, next(&curves, 0, dte.Reference.unset, false));
    try std.testing.expectEqual(1, next(&curves, 0, 1, true));
    // A curve that ends there carries it on too, unless only one that starts there may.
    try std.testing.expectEqual(0, next(&curves, 1, 1, false));
    try std.testing.expectEqual(null, next(&curves, 1, 1, true));
    try std.testing.expectEqual(null, next(&curves, 0, 7, false));
    try std.testing.expectApproxEqAbs(3000, pathLength(&curves, 0), 1e-1);
    try std.testing.expectEqual(0, pathLength(&curves, 4));
    // A path that comes round on itself ends once it has taken every curve.
    const round = [_]Curve{ dte.testing.curve(0, 1, .{ 0, 0, 0 }, .{ 0, 0, 10 }), dte.testing.curve(1, 0, .{ 0, 0, 10 }, .{ 0, 0, 0 }) };
    try std.testing.expectApproxEqAbs(20, pathLength(&round, 0), 1e-3);
}

test following {
    // Two curves that end at the same ship carry the path on into each other, round and round,
    // until the path has taken both.
    const round = [_]Curve{
        dte.testing.curve(1, 2, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(3, 2, .{ 0, 0, 2000 }, .{ 0, 0, 1000 }),
    };
    try std.testing.expectEqual(1, following(&round, 0, 1));
    try std.testing.expectEqual(0, following(&round, 1, 1));
    try std.testing.expectEqual(null, following(&round, 1, 2));
    // A curve that ends at no ship carries it nowhere, nor does one the list lacks.
    const open = [_]Curve{
        dte.testing.curve(1, dte.Reference.unset, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(dte.Reference.unset, 2, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
    };
    try std.testing.expectEqual(null, following(&open, 0, 1));
    try std.testing.expectEqual(null, following(&open, 2, 0));
}

test ride {
    var ships = dte.testing.ships(2, dte.Ship.curve_point_kind);
    ships[1].position = .{ 100, 0, 0 };
    // A ship placed at 100 that stood at 150 as the path began, and stands at 200 now: the point
    // rides along by 100, or by 50 without its move since.
    try std.testing.expectEqual(Vector{ 100, 0, 0 }, ride(&ships, 1, @splat(0), .{ 150, 0, 0 }, .{ 200, 0, 0 }));
    try std.testing.expectEqual(Vector{ 50, 0, 0 }, ride(&ships, 1, @splat(0), .{ 150, 0, 0 }, null));
    // With no ship, or one past the mission's, it stays.
    try std.testing.expectEqual(Vector{ 5, 0, 0 }, ride(&ships, null, .{ 5, 0, 0 }, .{ 150, 0, 0 }, .{ 200, 0, 0 }));
    try std.testing.expectEqual(Vector{ 5, 0, 0 }, ride(&ships, 2, .{ 5, 0, 0 }, .{ 150, 0, 0 }, .{ 200, 0, 0 }));
}

/// Three points that mark curve 4 a quarter, three quarters and half way along, and a ship of
/// another kind that marks nothing.
fn testMarkers() [4]dte.Ship {
    var ships: [4]dte.Ship = @splat(std.mem.zeroes(dte.Ship));
    for (ships[0..3], [_]f32{ 0.25, 0.75, 0.5 }) |*ship, at| {
        ship.kind = dte.Ship.point_kind;
        ship.marker_curve = 4;
        ship.marker_at = at;
    }
    ships[3].marker_curve = 4;
    ships[3].marker_at = 0.3;
    return ships;
}

test nextMarker {
    const ships = testMarkers();
    try std.testing.expectEqual(Marker{ .at = 0.25, .passed = null }, nextMarker(&ships, 4, 0));
    try std.testing.expectEqual(Marker{ .at = 0.75, .passed = 2 }, nextMarker(&ships, 4, 0.5));
    try std.testing.expectEqual(Marker{ .at = null, .passed = 1 }, nextMarker(&ships, 4, 0.75));
    try std.testing.expectEqual(Marker{ .at = null, .passed = null }, nextMarker(&ships, 5, 0));
}

test passMarker {
    const ships = testMarkers();
    // Short of the place and at it, nothing is passed; past it, its point is, and the next is the
    // one on.
    try std.testing.expectEqual(null, passMarker(&ships, 4, 0.25, 0.2));
    try std.testing.expectEqual(null, passMarker(&ships, 4, 0.25, 0.25));
    try std.testing.expectEqual(Marker{ .at = 0.5, .passed = 0 }, passMarker(&ships, 4, 0.25, 0.3));
    try std.testing.expectEqual(Marker{ .at = 0.75, .passed = 2 }, passMarker(&ships, 4, 0.5, 0.6));
    try std.testing.expectEqual(Marker{ .at = null, .passed = 1 }, passMarker(&ships, 4, 0.75, 0.8));
    // With none left, nothing more.
    try std.testing.expectEqual(null, passMarker(&ships, 4, null, 1));
}

test along {
    try std.testing.expectEqual(0.25, along(100, 400));
    // Past its end, past 1.
    try std.testing.expectEqual(1.5, along(600, 400));
    // A curve given no ticks is at its end at once.
    try std.testing.expectEqual(1, along(0, 0));
    try std.testing.expectEqual(1, along(50, 0));
}

test pathShare {
    const list = [_]Curve{
        dte.testing.curve(0, 1, .{ 0, 0, 0 }, .{ 0, 0, 1000 }),
        dte.testing.curve(1, 2, .{ 0, 0, 1000 }, .{ 0, 0, 4000 }),
    };
    try std.testing.expectApproxEqAbs(0.25, pathShare(&list, 0, 4000), 1e-4);
    try std.testing.expectApproxEqAbs(0.75, pathShare(&list, 1, 4000), 1e-4);
    // A curve the list lacks takes none, and a path of no length gives its curve all.
    try std.testing.expectEqual(0, pathShare(&list, 2, 4000));
    try std.testing.expectEqual(0, pathShare(&list, null, 4000));
    try std.testing.expectEqual(1, pathShare(&list, 0, 0));
}
