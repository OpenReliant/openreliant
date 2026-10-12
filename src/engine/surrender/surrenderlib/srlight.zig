//! `C:\lancer\surrender\surrenderlib\srLight.cpp`: lights, and what each adds to a vertex's colour
//! (`SR_mesh_pointlight`, `0x004CDE40`; `SR_mesh_dirlight`, `0x004CE120`), which the pipeline
//! works out for each vertex it lights (`srmesh`, `mesh_light`) and a device that lights each pixel
//! for each pixel.

const std = @import("std");

/// The light mask of an object no light reaches: all ones.
pub const no_lights: u32 = std.math.maxInt(u32);

pub const Light = struct {
    /// Reaches an object whose light mask shares no bit with it, or for an `inclusive` light, one
    /// whose mask shares a bit with it.
    mask: u32,
    intensity: f32,
    colour: [3]f32,
    /// Only an ambient light adds it, to the vertices' alpha (`mesh_light`).
    alpha: f32 = 0,
    kind: Kind,
    /// OpenReliant's: added to each pixel of a lit mesh by a device that lights each pixel, rather
    /// than to each vertex (`srapi.Context.pixel_lighting`). The driver sets it for the frame.
    per_pixel: bool = false,
    /// OpenReliant's: kept off what a caster shades from it, where the device draws shadows
    /// (`srshadow`). Only a directional light added to each pixel is.
    shadowed: bool = false,
    /// OpenReliant's: reaches only the objects that ask for it, by a bit of their light masks, so
    /// that it lights them alone without changing what lights every other object
    /// (`backdrop.LightRole.planets_40`).
    inclusive: bool = false,

    pub const Kind = union(enum) {
        /// Adds its colour everywhere.
        ambient,
        /// Lights a surface in proportion to its normal's dot product with this axis, the light's
        /// forward axis: it points toward the light.
        directional: [3]f32,
        /// Reaches out to its intensity times the point's range (`reach`).
        point: Point,
    };

    pub const Point = struct { position: [3]f32, range: f32 };

    /// Whether the light reaches an object with `object_mask`. An object whose mask is
    /// `no_lights` takes no lights.
    pub fn reaches(light: Light, object_mask: u32) bool {
        return object_mask != no_lights and (light.mask & object_mask != 0) == light.inclusive;
    }

    /// How far a point light reaches: its intensity times its range.
    pub fn reach(light: Light, point: Point) f32 {
        return light.intensity * point.range;
    }
};

/// How much a point light that reaches `reach` lights a vertex `distance_squared` from it, before
/// the light's intensity and `n . d`, the vertex's normal dotted with the way to the light:
/// `(1 / r + r / R² - 2 / R)`. As `n . d` is `r` times the cosine of the angle between them, the
/// two together come to the cosine times `(1 - r / R)²`.
pub fn falloff(distance_squared: f32, reach: f32) f32 {
    const r = @sqrt(distance_squared);
    return 1 / r + r / (reach * reach) - 2 / reach;
}

test "Light.reaches" {
    const light: Light = .{ .mask = 4, .intensity = 1, .colour = .{ 0.04, 0.04, 0.04 }, .kind = .ambient };
    try std.testing.expect(light.reaches(0x03));
    try std.testing.expect(!light.reaches(0x04));
    try std.testing.expect(!light.reaches(no_lights));
    // An inclusive light reaches only the objects whose masks ask for it.
    const asked: Light = .{ .mask = 0x40, .intensity = 1, .colour = .{ 1, 1, 1 }, .kind = .{ .directional = .{ 0, 0, 1 } }, .inclusive = true };
    try std.testing.expect(asked.reaches(0x7F));
    try std.testing.expect(!asked.reaches(0x3F));
    try std.testing.expect(!asked.reaches(0));
    try std.testing.expect(!asked.reaches(no_lights));
}

test "Light.reach" {
    const light: Light = .{ .mask = 1, .intensity = 2, .colour = .{ 1, 1, 1 }, .kind = .{ .point = .{ .position = .{ 0, 0, 10 }, .range = 20 } } };
    try std.testing.expectEqual(40, light.reach(light.kind.point));
}

test falloff {
    // Times the distance, (1 - r / R)^2: a quarter at half its reach.
    try std.testing.expectApproxEqAbs(0.25, falloff(10 * 10, 20) * 10, 1e-6);
    // At its reach, nothing.
    try std.testing.expectApproxEqAbs(0, falloff(20 * 20, 20), 1e-6);
}
