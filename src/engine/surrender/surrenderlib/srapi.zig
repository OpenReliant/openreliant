//! `C:\lancer\surrender\surrenderlib\srAPI.cpp`: Surrender's interface to the game: its state,
//! `sr` (`0x005E6B50`), the camera's projection, and what a mesh works out from its vertices.

const std = @import("std");

const math = @import("../math.zig");
const srapiext = @import("srapiext.zig");
const srclip = @import("srclip.zig");
const srshadow = @import("srshadow.zig");
const srtexture = @import("srtexture.zig");
const Vector = math.Vector;

/// The projection `sr_set_projection` (`0x004C3A60`) sets from a viewport, its edges as fractions
/// of the screen, left, top, right and bottom, and a factor across and one down. The view's middle
/// is the screen's, whatever the viewport.
pub const Projection = struct {
    /// The screen's width and height in pixels (`sr + 0x1666`, `sr + 0x166A`).
    screen: [2]u32,
    /// Pixels to a view unit, a point's position over its depth, across and down: the screen's
    /// size less `edge_margin`, times the factor.
    scale: [2]f32,
    /// Where the view axis meets the screen, in pixels.
    centre: [2]f32,
    /// The viewport's edges in view units: left, top, right and bottom.
    bounds: [4]f32,
    /// The viewport's edges in pixels.
    viewport: [4]f32,
    /// The sides of the view volume, through the eye, their unit normals pointing out: left,
    /// right, top and bottom.
    sides: [4]Vector,
    /// The near plane's distance (`sr + 0x169E`).
    near: f32 = in_flight_near,
    /// A vertex's depth is `sqrt(1 / z)` times this (`sr + 0x16A6`). The driver's `begin_scene`
    /// sets it each frame (`depthScale`), so that the near plane is just short of 1.
    depth_scale: f32 = depthScale(in_flight_near),

    /// What `sr_set_projection` takes off the screen's size for its scale, in pixels
    /// (`0x004DC420`).
    const edge_margin: f32 = 0.1;

    pub fn init(width: u32, height: u32, viewport: [4]f32, factors: [2]f32) Projection {
        const size = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        var projection: Projection = .{ .screen = .{ width, height }, .scale = undefined, .centre = undefined, .bounds = undefined, .viewport = undefined, .sides = undefined };
        for (0..2) |axis| {
            projection.scale[axis] = (size[axis] - edge_margin) * factors[axis];
            projection.centre[axis] = size[axis] * 0.5;
            for ([2]usize{ axis, axis + 2 }) |edge| {
                projection.bounds[edge] = (viewport[edge] - 0.5) / factors[axis];
                projection.viewport[edge] = size[axis] * viewport[edge];
            }
        }
        projection.sides = .{
            math.normalize(.{ -1, 0, projection.bounds[0] }),
            math.normalize(.{ 1, 0, -projection.bounds[2] }),
            math.normalize(.{ 0, -1, projection.bounds[1] }),
            math.normalize(.{ 0, 1, -projection.bounds[3] }),
        };
        return projection;
    }

    /// Where a point in view units, a position over its depth, falls on the screen, in pixels.
    pub fn toScreen(projection: Projection, view: [2]f32) [2]f32 {
        return .{
            projection.scale[0] * view[0] + projection.centre[0],
            projection.scale[1] * view[1] + projection.centre[1],
        };
    }

    /// Where a point in the camera's frame, in front of it, falls on the screen. It divides the
    /// scaled position by the depth, where `transform` scales the position over the depth, which
    /// rounds differently.
    pub fn project(projection: Projection, point: Vector) [2]f32 {
        return .{
            projection.centre[0] + projection.scale[0] * point[0] / point[2],
            projection.centre[1] + projection.scale[1] * point[1] / point[2],
        };
    }

    /// A vertex in the camera's frame as the driver takes it (`mesh_project`, `0x004C6D40`):
    /// on the screen, kept within the viewport, with its depth and its reciprocal depth scaled by
    /// the near plane.
    pub fn transform(projection: Projection, point: Vector) Transformed {
        const w = 1 / point[2];
        var screen = projection.toScreen(.{ w * point[0], w * point[1] });
        projection.clamp(&screen);
        return .{
            .x = screen[0],
            .y = screen[1],
            .depth = @sqrt(w) * projection.depth_scale,
            .rhw = projection.near * w,
        };
    }

    /// Keeps a point on the screen within the viewport (`0x004C5DC0`).
    pub fn clamp(projection: Projection, screen: *[2]f32) void {
        for (screen, 0..) |*c, axis| {
            if (c.* < projection.viewport[axis]) c.* = projection.viewport[axis];
            if (projection.viewport[axis + 2] < c.*) c.* = projection.viewport[axis + 2];
        }
    }

    /// Which sides of the view volume a point in the camera's frame lies outside
    /// (`mesh_transform_clipped`, `0x004C6710`): in front of the near plane, only the near plane's,
    /// and otherwise the sides, as the clipper tests them (`srclip.flags`).
    pub fn outcode(projection: Projection, point: Vector) Outcode {
        if (point[2] < projection.near) return .{ .near = true };
        return srclip.flags(projection, point);
    }
};

/// The near plane in flight, which `renderer_start` (`0x004ACBE0`) sets.
pub const in_flight_near: f32 = 100;

/// What the driver's `begin_scene` (`0x100077A0`) scales the depth by for a near plane at `near`:
/// its square root, times `near_depth`.
pub fn depthScale(near: f32) f32 {
    return @sqrt(near) * near_depth;
}

/// Where the near plane falls in the depth buffer, just short of 1 (`srd3d.dll`, `0x10020420`).
const near_depth: f32 = 0.99999;

/// A vertex as the driver draws it: on the screen, with its depth and reciprocal depth.
pub const Transformed = struct {
    x: f32,
    y: f32,
    depth: f32,
    rhw: f32,
};

/// The planes a point lies outside, or a polygon crosses.
pub const Outcode = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,
    near: bool = false,
    /// The object's portal, for every polygon of an object flagged `portal_clipped`.
    portal: bool = false,
    _unused: u2 = 0,

    pub const all: Outcode = .{ .left = true, .right = true, .top = true, .bottom = true, .near = true, .portal = true };

    pub fn any(code: Outcode) bool {
        return @as(u8, @bitCast(code)) != 0;
    }

    pub fn both(a: Outcode, b: Outcode) Outcode {
        return @bitCast(@as(u8, @bitCast(a)) & @as(u8, @bitCast(b)));
    }

    pub fn either(a: Outcode, b: Outcode) Outcode {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }
};

/// The whole screen, as a viewport.
pub const full_screen = [4]f32{ 0, 0, 1, 1 };

/// The vertices and the polygons the game lets the objects drawn in a frame take
/// (`0x005E82F4`, `0x005E82F8` against 19999).
pub const original_budget = 19999;

/// Surrender's state, `sr` (`0x005E6B50`), as OpenReliant keeps it: the camera and its projection,
/// the level-of-detail divisor, and the sun's point the driver checks triangles against.
pub const Context = struct {
    /// The camera's frame (`sr + 0x30`): its orientation's columns are its right, down and
    /// forward axes in the world.
    camera: math.Place = .{},
    projection: Projection,
    /// Depths are divided by this before choosing a level of detail (`detail_divisor`,
    /// `0x005E829A`). `mission_frame` moves it with the frame time, within bounds the detail
    /// setting sets (`game.main.high_detail`).
    detail: f32 = 1,
    /// **Improvement:** how many times further than `detail` has them the finer levels of detail
    /// reach, so that an object keeps a finer mesh from further off; its last level still ends
    /// where `detail` has it, and the object leaves sight there. 1 is the original's.
    finer: f32 = 1,
    /// How many vertices, and how many polygons, the objects drawn in a frame may take
    /// (`srmesh.Budget`): the original's `original_budget` unless set.
    budget: usize = original_budget,
    /// A hardware renderer (`sr + 0x1AC`).
    hardware: bool = true,
    /// The sun's point on the screen (`sr + 0x173E`), and how much of it shows (`sr + 0x1746`):
    /// the driver lessens it for each triangle of an object flagged `sun_occluder` near the point.
    sun: [2]f32 = .{ 0, 0 },
    sun_visibility: f32 = 0,
    /// OpenReliant's: set for a frame whose device lights each pixel with the directional and point
    /// lights (`device.Device.lights`). The pipeline then leaves them out of the vertices' colours
    /// and hands the device the vertices' normals instead.
    pixel_lighting: bool = false,
    /// OpenReliant's: how the device draws the frame's shadows, or null for none (`srshadow`). The
    /// driver sets it with the lights.
    shadows: ?srshadow.Settings = null,
    /// The picture the device draws behind each frame as it begins, over the screen (`sr + 0x50`,
    /// the device's background image); none for the clear colour alone.
    background: ?*srtexture.Image = null,

    /// A point of the world in the camera's frame.
    pub fn view(context: Context, point: Vector) Vector {
        return context.camera.inverse(point);
    }

    /// A direction in the world, in the camera's frame.
    pub fn turn(context: Context, direction: Vector) Vector {
        return math.transformTransposed(context.camera.orientation, direction);
    }

    /// What turns the frame of an object at `orientation`, drawn `scale` times its size, into the
    /// camera's (`SR_object_rotate`, `0x004C7D00`): the camera's orientation turned back, times the
    /// object's, `scaled`.
    pub fn objectMatrix(context: Context, orientation: math.Matrix, scale: f32) math.Matrix {
        return scaled(math.product(math.transpose(context.camera.orientation), orientation), scale);
    }
};

/// `matrix` times `scale`, which the pipelines leave as it is at a scale of 1.
pub fn scaled(matrix: math.Matrix, scale: f32) math.Matrix {
    if (scale == 1) return matrix;
    var out = matrix;
    for (&out) |*m| m.* *= scale;
    return out;
}

/// The plane through three corners, facing the side `(b - a) x (c - a)` points to: its unit normal
/// and the normal's dot product with `a`.
pub fn planeThrough(a: Vector, b: Vector, c: Vector) srapiext.Plane {
    const normal = math.normalize(math.cross(b - a, c - a));
    return .{ .normal = normal, .distance = math.dot(normal, a) };
}

/// Each polygon's plane, from its first three corners (`SR_mesh_calc_poly_normals`,
/// `0x004C3CA0`), with the last two swapped for an odd strip member, which lists them the other way
/// round: its front is the side `(v1 - v0) x (v2 - v0)` points to. Lines keep theirs.
pub fn calcPolyNormals(mesh: *srapiext.Mesh) void {
    for (mesh.polygons, mesh.planes) |polygon, *plane| {
        if (polygon.count <= 2) continue;
        const corners = mesh.indices[polygon.first..][0..3];
        const a = mesh.positions[corners[0]];
        const b = mesh.positions[corners[1]];
        const c = mesh.positions[corners[2]];
        plane.* = if (polygon.kind == .strip_odd) planeThrough(a, c, b) else planeThrough(a, b, c);
    }
}

/// Each vertex's normal (`SR_mesh_calc_vertex_normals`, `0x004C3E30`): the normals of the planes
/// of the polygons it corners, added up and made one long (`math.normalize`), so that one no
/// polygon corners points forward, tiny.
pub fn calcVertexNormals(mesh: *srapiext.Mesh) void {
    @memset(mesh.normals, @splat(0));
    for (mesh.polygons, mesh.planes) |polygon, plane| {
        for (mesh.indices[polygon.first..][0..polygon.count]) |index| mesh.normals[index] += plane.normal;
    }
    for (mesh.normals) |*normal| normal.* = math.normalize(normal.*);
}

/// The mesh's bounding box, and its farthest vertex's distance from the origin
/// (`SR_mesh_find_bounding_box`, `0x004C3F10`); all zero without vertices.
pub fn findBoundingBox(mesh: *srapiext.Mesh) void {
    if (mesh.positions.len == 0) {
        mesh.bounds = .{ @splat(0), @splat(0) };
        mesh.radius = 0;
        return;
    }
    var low = mesh.positions[0];
    var high = low;
    var farthest = math.lengthSquared(low);
    for (mesh.positions[1..]) |position| {
        low = @min(low, position);
        high = @max(high, position);
        farthest = @max(farthest, math.lengthSquared(position));
    }
    mesh.bounds = .{ low, high };
    mesh.radius = @sqrt(farthest);
}

test Projection {
    // The game's usual view on a 1024 by 768 screen: square pixels, and a view 5/6 of a unit
    // either side across and 5/8 up and down.
    const projection: Projection = .init(1024, 768, full_screen, .{ 0.6, 0.8 });
    try std.testing.expectApproxEqAbs(614.34, projection.scale[0], 1e-3);
    try std.testing.expectApproxEqAbs(614.32, projection.scale[1], 1e-3);
    try std.testing.expectEqual([2]f32{ 512, 384 }, projection.centre);
    try std.testing.expectApproxEqAbs(-5.0 / 6.0, projection.bounds[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.625, projection.bounds[3], 1e-6);
    try std.testing.expectEqual([2]f32{ 512, 384 }, projection.project(.{ 0, 0, 10 }));

    // Bars over the top and bottom tenth leave the middle where it was.
    const bars: Projection = .init(1024, 768, .{ 0, 0.1, 1, 0.9 }, .{ 0.6, 0.8 });
    try std.testing.expectEqual(projection.centre, bars.centre);
    try std.testing.expectApproxEqAbs(76.8, bars.viewport[1], 1e-3);
    try std.testing.expectApproxEqAbs(-0.5, bars.bounds[1], 1e-6);
}

test "vertices as the driver takes them" {
    const projection: Projection = .init(1024, 768, full_screen, .{ 0.6, 0.8 });
    // On the near plane the depth is just short of 1, and the reciprocal depth is 1.
    const near = projection.transform(.{ 0, 0, 100 });
    try std.testing.expectApproxEqAbs(0.99999, near.depth, 1e-6);
    try std.testing.expectApproxEqAbs(1, near.rhw, 1e-6);
    // Four times as far, half the depth.
    try std.testing.expectApproxEqAbs(0.99999 / 2.0, projection.transform(.{ 0, 0, 400 }).depth, 1e-6);
    // Off the side, it is kept to the viewport's edge.
    try std.testing.expectEqual(1024, projection.transform(.{ 5000, 0, 100 }).x);
}

test "Projection.toScreen" {
    const projection: Projection = .init(1024, 768, full_screen, .{ 0.6, 0.8 });
    try std.testing.expectEqual(projection.centre, projection.toScreen(.{ 0, 0 }));
    const off = projection.toScreen(.{ 0.5, -0.25 });
    try std.testing.expectEqual(projection.scale[0] * 0.5 + projection.centre[0], off[0]);
    try std.testing.expectEqual(projection.scale[1] * -0.25 + projection.centre[1], off[1]);
}

test "Context.objectMatrix" {
    var context: Context = .{ .projection = .init(1024, 768, full_screen, .{ 0.6, 0.8 }) };
    context.camera.orientation = math.rotation(.y, 0.5);
    const object = math.rotation(.x, 0.25);
    // Unscaled, the object's orientation as the camera sees it; scaled, each entry times the scale.
    const turned = context.objectMatrix(object, 1);
    try std.testing.expectEqual(math.product(math.transpose(context.camera.orientation), object), turned);
    for (turned, context.objectMatrix(object, 2)) |one, two| try std.testing.expectEqual(one * 2, two);
    // A point of the world in the camera's frame, and back.
    context.camera.position = .{ 10, 20, 30 };
    const seen = context.view(.{ 10, 20, 130 });
    try std.testing.expect(math.length(context.camera.point(seen) - Vector{ 10, 20, 130 }) < 1e-4);
}

test scaled {
    try std.testing.expectEqual(math.identity, scaled(math.identity, 1));
    try std.testing.expectEqual(math.scaling(@splat(3)), scaled(math.identity, 3));
}

test calcPolyNormals {
    const gpa = std.testing.allocator;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 2, .vertices = 3, .indices = 6 });
    defer mesh.deinit(gpa);
    mesh.positions[0..3].* = .{ .{ 0, 0, 5 }, .{ 1, 0, 5 }, .{ 0, 1, 5 } };
    mesh.numberPolygons(3);
    mesh.indices[0..6].* = .{ 0, 1, 2, 0, 1, 2 };
    mesh.polygons[1].kind = .strip_odd;
    calcPolyNormals(&mesh);
    // A triangle faces the side (v1 - v0) x (v2 - v0) points to; an odd strip member the other.
    try std.testing.expectEqual(Vector{ 0, 0, 1 }, mesh.planes[0].normal);
    try std.testing.expectEqual(5, mesh.planes[0].distance);
    try std.testing.expectEqual(Vector{ 0, 0, -1 }, mesh.planes[1].normal);
    try std.testing.expectEqual(-5, mesh.planes[1].distance);
    // A viewpoint on a plane's front side faces it.
    try std.testing.expect(mesh.planes[0].faces(.{ 0, 0, 10 }));
    try std.testing.expect(!mesh.planes[0].faces(.{ 0, 0, 0 }));
    try std.testing.expect(mesh.planes[1].faces(.{ 0, 0, 0 }));
}

test Outcode {
    const projection: Projection = .init(1024, 768, full_screen, .{ 0.6, 0.8 });
    try std.testing.expectEqual(Outcode{}, projection.outcode(.{ 0, 0, 1000 }));
    try std.testing.expectEqual(Outcode{ .near = true }, projection.outcode(.{ 5000, 0, 50 }));
    try std.testing.expectEqual(Outcode{ .left = true, .bottom = true }, projection.outcode(.{ -1000, 700, 1000 }));
    try std.testing.expect(Outcode.both(.{ .left = true }, .{ .left = true, .top = true }).left);
    try std.testing.expect(!Outcode.both(.{ .left = true }, .{ .right = true }).any());
    // The side planes' normals point out: a point off the left is in front of the left plane.
    try std.testing.expect(math.dot(projection.sides[0], .{ -1000, 0, 1000 }) > 0);
    try std.testing.expect(math.dot(projection.sides[3], .{ 0, 1000, 1000 }) > 0);
}
