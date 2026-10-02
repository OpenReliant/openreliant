//! The easings the game moves and fades by: from one value to another as a share goes from 0 to
//! 1, in a straight line or in a curve (`0x004268A0` to `0x00426A2F`).
//!
//! **Unverified:** the file. They lie just before `interf.cpp`'s known code, after the loadout
//! screen's bars, and serve the game's effects rather than the front end: the shields' ramps, the
//! cloak's shimmer, the gates, the Rippers, the Nova Cannon's beam. OpenReliant keeps them with
//! `interf.cpp`.

const std = @import("std");

/// `ease_linear` (`0x004268A0`): from `from` to `to` in a straight line, `at` of the way. For
/// vectors, each component alike, as the game eases a position an axis at a time.
pub fn linear(from: anytype, to: anytype, at: f32) Eased(@TypeOf(from, to)) {
    const T = Eased(@TypeOf(from, to));
    const start: T = from;
    const end: T = to;
    return (end - start) * each(T, at) + start;
}

/// `cosine_ease` (`0x004268C0`): from `from` to `to` as `at` goes from 0 to 1, slow at each end.
/// For vectors, each component alike, as the game eases a position or a set of angles an axis at
/// a time.
///
/// **Improvement:** the cosine comes from `std.math` rather than the engine's table (`sr_cos`).
pub fn cosine(from: anytype, to: anytype, at: f32) Eased(@TypeOf(from, to)) {
    const T = Eased(@TypeOf(from, to));
    const start: T = from;
    const end: T = to;
    return start + (end - start) * each(T, 1 - @cos(at * std.math.pi)) / each(T, 2);
}

/// What `linear` and `cosine` give for values of type `T`: a value of `T`, a float for a number
/// literal.
fn Eased(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float => f32,
        else => T,
    };
}

/// `value` for each component of a `T`, or `value` itself for a float.
fn each(comptime T: type, value: f32) T {
    return if (@typeInfo(T) == .vector) @splat(value) else value;
}

/// `ease_in` (`0x00426900`): from `from` to `to` by the square of `at`, slow at the start.
pub fn in(from: f32, to: f32, at: f32) f32 {
    return (to - from) * (at * at) + from;
}

/// `ease_out` (`0x00426920`): from `from` to `to` by the square root of `at`, slow at the end.
pub fn out(from: f32, to: f32, at: f32) f32 {
    return (to - from) * @sqrt(at) + from;
}

/// Which way `riseFall` goes first.
pub const Way = enum { rising, falling };

/// `ease_rise_fall` (`0x00426950`): from `from` to `to` and back as `at` goes from 0 to 1, rising
/// by the square root of twice `at` (`out`) until half way, then falling by one less the square
/// of twice the rest (`in`); `falling`, the other way about. An `at` below 0 is taken as past half
/// way.
pub fn riseFall(way: Way, from: f32, to: f32, at: f32) f32 {
    const first_half = at >= 0 and at <= half;
    const shaped = switch (way) {
        .rising => if (first_half) out(0, 1, at + at) else in(1, 0, (at - half) + (at - half)),
        .falling => if (first_half) out(1, 0, at + at) else in(0, 1, (at - half) + (at - half)),
    };
    return (to - from) * shaped + from;
}

/// Where `riseFall` turns (`0x004DC408`).
const half: f32 = 0.5;

test linear {
    try std.testing.expectEqual(4, linear(2, 6, 0.5));
    try std.testing.expectEqual(6, linear(2, 6, 1));
    // A vector goes the same share of the way in each component, as each would alone.
    const from: @Vector(3, f32) = .{ 2, 0, -1 };
    const to: @Vector(3, f32) = .{ 6, 0.1, 3 };
    const eased = linear(from, to, 0.3);
    inline for (0..3) |axis| try std.testing.expectEqual(linear(from[axis], to[axis], 0.3), eased[axis]);
}

test cosine {
    try std.testing.expectApproxEqAbs(2, cosine(2, 6, 0), 1e-6);
    try std.testing.expectApproxEqAbs(4, cosine(2, 6, 0.5), 1e-6);
    try std.testing.expectApproxEqAbs(6, cosine(2, 6, 1), 1e-6);
    // A vector eases each component as it would alone.
    const from: @Vector(3, f32) = .{ 2, 0, -1 };
    const to: @Vector(3, f32) = .{ 6, 0.1, 3 };
    const eased = cosine(from, to, 0.3);
    inline for (0..3) |axis| try std.testing.expectEqual(cosine(from[axis], to[axis], 0.3), eased[axis]);
}

test in {
    try std.testing.expectEqual(3, in(2, 6, 0.5));
    try std.testing.expectEqual(12500, in(12500, 0.001, 0));
}

test out {
    try std.testing.expectEqual(4, out(2, 6, 0.25));
    try std.testing.expectEqual(2, out(2, 6, 0));
}

test riseFall {
    try std.testing.expectEqual(0, riseFall(.rising, 0, 1, 0));
    try std.testing.expectApproxEqAbs(0.5, riseFall(.rising, 0, 1, 0.125), 1e-6);
    try std.testing.expectEqual(1, riseFall(.rising, 0, 1, 0.5));
    try std.testing.expectApproxEqAbs(0.75, riseFall(.rising, 0, 1, 0.75), 1e-6);
    try std.testing.expectEqual(0, riseFall(.rising, 0, 1, 1));
    // Falling, it starts high, and it scales to its ends.
    try std.testing.expectEqual(10, riseFall(.falling, 0, 10, 0));
    try std.testing.expectEqual(0, riseFall(.falling, 0, 10, 0.5));
}
