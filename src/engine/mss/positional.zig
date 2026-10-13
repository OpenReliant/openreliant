//! How loud a 3D sample is in each ear and how far its pitch moves, from where it is and how it
//! moves: OpenReliant's own provider, in place of the ones the game chooses from (`Miles Fast 2D
//! Positional Audio`, A3D, EAX and RSX), none of which it can load. It follows DirectSound3D's
//! model, which those follow too: the gain falls off as the minimum distance over the distance,
//! and no further past the maximum; the cone quietens a sample facing away; the Doppler shift uses
//! the velocities along the line between them.
//!
//! Positions are Miles's: the listener at the origin looking along `+z`, `+x` to its right and `+y`
//! up. Velocities are in the same units a millisecond.

const std = @import("std");

const mss = @import("../mss.zig");
const math = @import("../surrender/math.zig");

pub const Vector = math.Vector;

/// The speed of sound, a millisecond, in DirectSound3D's default metres.
pub const speed_of_sound = 0.3433;

/// A cone's angle, in degrees, that takes in every direction: no cone at all.
pub const full_cone = 360;

/// Up, for a 3D sample's orientation.
pub const up: Vector = .{ 0, 1, 0 };

/// A 3D sample's placing, as the `AIL_set_3D_` calls set it.
pub const Placing = struct {
    position: Vector = @splat(0),
    velocity: Vector = @splat(0),
    /// Which way it faces, for its cone.
    face: Vector = .{ 0, 0, 1 },
    min_distance: f32 = 1,
    max_distance: f32 = 1000,
    /// The cone: inside half the inner angle full volume, outside half the outer angle
    /// `outer_volume` over `mss.max_level`, in degrees; `full_cone` each for none.
    inner_angle: f32 = full_cone,
    outer_angle: f32 = full_cone,
    outer_volume: f32 = mss.max_level,
};

pub const Heard = struct {
    gains: [2]f32,
    /// What the playback rate is multiplied by.
    pitch: f32,
};

/// What the listener hears of a sample placed so, at `volume` from 0 to `mss.max_level`.
pub fn hear(placing: Placing, volume: f32) Heard {
    const distance = math.length(placing.position);
    var gain = volume / mss.max_level * attenuation(placing, distance) * cone(placing, distance);
    gain = std.math.clamp(gain, 0, 1);

    // Panned by how far to the side it lies, with the same power across.
    const side: f32 = if (distance > 0) placing.position[0] / distance else 0;
    const angle = (side + 1) * std.math.pi / 4;
    const gains: [2]f32 = .{ gain * @cos(angle), gain * @sin(angle) };
    return .{ .gains = gains, .pitch = doppler(placing, distance) };
}

fn attenuation(placing: Placing, distance: f32) f32 {
    const clamped = std.math.clamp(distance, placing.min_distance, @max(placing.min_distance, placing.max_distance));
    return if (clamped > 0) placing.min_distance / clamped else 1;
}

/// The cone's share: toward the listener within the inner cone, all of it; outside the outer,
/// the outer volume's; between, some of each.
fn cone(placing: Placing, distance: f32) f32 {
    if (placing.inner_angle >= full_cone or distance == 0) return 1;
    const face_length = math.length(placing.face);
    if (face_length == 0) return 1;
    const toward = -placing.position / @as(Vector, @splat(distance));
    const cosine = std.math.clamp(math.dot(toward, placing.face) / face_length, -1, 1);
    const off = std.math.radiansToDegrees(std.math.acos(cosine));
    const inner = placing.inner_angle / 2;
    const outer = @max(inner, placing.outer_angle / 2);
    const outside = placing.outer_volume / mss.max_level;
    if (off <= inner) return 1;
    if (off >= outer) return outside;
    return 1 + (outside - 1) * (off - inner) / (outer - inner);
}

/// The listener stands still; a sample moving away along the line between them sounds lower.
fn doppler(placing: Placing, distance: f32) f32 {
    if (distance == 0) return 1;
    const velocity = dopplerVelocity(placing.position, placing.velocity);
    const away = math.dot(velocity, placing.position) / distance;
    return speed_of_sound / (speed_of_sound + away);
}

/// The velocity a sample's Doppler shift is worked out from: its own, with the part along the line
/// to the listener held within half the speed of sound either way.
pub fn dopplerVelocity(position: Vector, velocity: Vector) Vector {
    const distance = math.length(position);
    if (distance == 0) return velocity;
    const line = position / @as(Vector, @splat(distance));
    const away = math.dot(velocity, line);
    const held = std.math.clamp(away, -speed_of_sound / 2.0, speed_of_sound / 2.0);
    return velocity + line * @as(Vector, @splat(held - away));
}

test hear {
    // Ahead within the minimum distance, both ears hear it at its volume's power.
    const ahead = hear(.{ .position = .{ 0, 0, 1 }, .min_distance = 2 }, mss.max_level);
    try std.testing.expectApproxEqAbs(@sqrt(0.5), ahead.gains[0], 1e-6);
    try std.testing.expectApproxEqAbs(ahead.gains[0], ahead.gains[1], 1e-6);
    try std.testing.expectEqual(@as(f32, 1), ahead.pitch);

    // Four times as far as the minimum, a quarter as loud; past the maximum, no quieter.
    const far = hear(.{ .position = .{ 0, 0, 8 }, .min_distance = 2, .max_distance = 100 }, mss.max_level);
    try std.testing.expectApproxEqAbs(ahead.gains[0] / 4, far.gains[0], 1e-6);
    const past = hear(.{ .position = .{ 0, 0, 800 }, .min_distance = 2, .max_distance = 100 }, mss.max_level);
    try std.testing.expectApproxEqAbs(ahead.gains[0] / 50, past.gains[0], 1e-6);

    // To the right, the right ear only.
    const right = hear(.{ .position = .{ 1, 0, 0 } }, mss.max_level);
    try std.testing.expectApproxEqAbs(@as(f32, 0), right.gains[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), right.gains[1], 1e-6);

    // Facing away with a cone, the outer volume's share.
    const away = hear(.{ .position = .{ 0, 0, 1 }, .face = .{ 0, 0, 1 }, .inner_angle = 90, .outer_angle = 210, .outer_volume = 63.5 }, mss.max_level);
    try std.testing.expectApproxEqAbs(ahead.gains[0] / 2, away.gains[0], 1e-6);

    // Moving away, lower.
    const leaving = hear(.{ .position = .{ 0, 0, 10 }, .velocity = .{ 0, 0, 0.01 } }, mss.max_level);
    try std.testing.expect(leaving.pitch < 1);
}

test dopplerVelocity {
    // Across the line, as it is; along it, held to half the speed of sound.
    try std.testing.expectEqual(Vector{ 5, 0, 0 }, dopplerVelocity(.{ 0, 0, 10 }, .{ 5, 0, 0 }));
    const held = dopplerVelocity(.{ 0, 0, 10 }, .{ 5, 0, 3 });
    try std.testing.expectEqual(5, held[0]);
    try std.testing.expectApproxEqAbs(speed_of_sound / 2.0, held[2], 1e-6);
    try std.testing.expectEqual(Vector{ 0, 0, -0.1 }, dopplerVelocity(.{ 0, 0, 10 }, .{ 0, 0, -0.1 }));
}
