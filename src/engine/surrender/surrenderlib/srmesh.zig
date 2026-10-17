//! `C:\lancer\surrender\surrenderlib\srMesh.cpp`: the pipeline `SR_meshpipe_init` (`0x004C75C0`)
//! runs a mesh object through each frame for the driver: tests it against the view, picks its level
//! of detail, culls, transforms and projects or marks for clipping, lights, and makes texture
//! coordinates. **Unverified:** the stages, `mesh_cull` (`0x004C6280`) to
//! `mesh_generated_coordinates` (`0x004C7590`), lie between `hog_file.cpp`'s code and
//! `SR_meshpipe_init`; by what they do they are this file's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../../../formats/shp.zig");
const math = @import("../math.zig");
const srapi = @import("srapi.zig");
const srapiext = @import("srapiext.zig");
const srclip = @import("srclip.zig");
const srlight = @import("srlight.zig");
const Vector = math.Vector;
const Outcode = srapi.Outcode;
const MeshObject = srapiext.MeshObject;
const Mesh = srapiext.Mesh;

/// The face mask's bit that hides the cap faces (`shp.Face.Flags.cap`), which close a part where it
/// meets another: an object that comes apart there clears it, and they show.
pub const caps_hidden: u8 = @truncate(@as(u32, @bitCast(shp.Face.Flags{ .cap = true })));

/// How `mesh_cull` draws a face: never, always, or while the viewpoint lies on its front side.
pub const Showing = enum { never, always, facing };

/// How a face of `flags` is drawn under an object's `face_mask`, which says which of the flags it
/// heeds: a cap face heeded is hidden, and a two-sided one never culled; `culling` is off for
/// objects flagged `not_culled`.
pub fn showing(flags: shp.Face.Flags, face_mask: u8, culling: bool) Showing {
    const masked: shp.Face.Flags = @bitCast(@as(u32, @bitCast(flags)) & face_mask);
    if (masked.cap) return .never;
    return if (!culling or masked.two_sided) .always else .facing;
}

/// Texture coordinates from a vertex normal turned into the camera's frame (`mesh_sphere_map`,
/// `0x004C7360`).
pub fn sphereMap(normal_in_camera: Vector) [2]f32 {
    return .{ 0.5 + 0.5 * normal_in_camera[0], 0.5 + 0.5 * normal_in_camera[1] };
}

/// A visible polygon, and the planes the driver clips it against.
pub const Visible = struct {
    polygon: u32,
    clip: Outcode = .{},
};

/// What the pipeline makes of a mesh object for a frame, for the driver. The arrays by vertex hold
/// only the vertices of visible polygons.
pub const Drawn = struct {
    object: *const MeshObject,
    mesh: *const Mesh,
    /// In the camera's frame (`+0xF8`).
    view: []Vector,
    /// As the driver takes them (`+0xFC`), where the vertex is inside the view.
    screen: []srapi.Transformed,
    /// The planes each vertex lies outside (`+0xF4`); all clear unless the object is clipped.
    outcodes: []Outcode,
    /// Red, green, blue and alpha (`+0x100`), for a lit or baked object.
    colours: ?[][4]f32,
    /// OpenReliant's: the normals in the camera's frame, for a lit object in a frame whose device
    /// lights each pixel (`srapi.Context.pixel_lighting`).
    normals: ?[]Vector = null,
    /// Coordinates from the normals (`+0x104`, `+0x108`), for the passes the object asks them for.
    generated: [2]?[][2]f32,
    /// The visible polygons (`+0xD8`), surface by surface: `counts[i]` of them for surface `i`
    /// (`+0x11C`).
    visible: []Visible,
    counts: []u32,
};

/// The vertices and polygons of the objects drawn so far this frame (`0x005E82F4`, `0x005E82F8`):
/// an object that would take either past the limit is left out. The layers are drawn from what
/// went into them last, so it is the objects that went in first that are left out.
pub const Budget = struct {
    vertices: usize = 0,
    polygons: usize = 0,
    limit: usize = srapi.original_budget,
};

/// How far a vertex has moved toward its counterpart in the next level, and its normal likewise
/// (`+0xE0`, `+0xE4`).
const Morph = struct {
    positions: f32 = 0,
    normals: f32 = 0,

    /// How far through its level an object starts moving toward the next (`0x004DC550`), and how
    /// many times as fast as it goes on through the level it then moves (`0x004DC424`), so that it
    /// has moved all the way by the level's end.
    const start: f32 = 0.75;
    const rate: f32 = 4;

    /// How far an object `along` of the way through its level has moved toward the next.
    fn moved(along: f32) f32 {
        return if (start <= along) (along - start) * rate else 0;
    }

    comptime {
        std.debug.assert((1 - start) * rate == 1);
    }
};

/// Runs `object` through the pipeline (`SR_meshpipe_init`), lit by `lights`, the scene's in order.
/// Null when nothing of it is drawn. What it returns lives in `arena`.
pub fn pipe(
    arena: Allocator,
    context: *const srapi.Context,
    object: *MeshObject,
    lights: []const srlight.Light,
    budget: *Budget,
) Allocator.Error!?Drawn {
    const current = object.levels[object.level].mesh;
    if (current.polygons.len + budget.polygons > budget.limit) return null;
    if (current.positions.len + budget.vertices > budget.limit) return null;

    // The object in the camera's frame (`SR_object_rotate`, `0x004C7D00`).
    const relative = context.view(object.position);
    const matrix = context.objectMatrix(object.orientation, object.scale);

    var clip: Outcode = Outcode.all;
    var morph: Morph = .{};
    if (!object.flags.always_drawn) {
        clip = sphereTest(context.projection, object, relative) orelse return null;
        clip = try chooseLevel(context, object, relative, matrix, clip, &morph) orelse return null;
    }
    const mesh = object.levels[object.level].mesh;

    var drawn: Drawn = .{
        .object = object,
        .mesh = mesh,
        .view = try arena.alloc(Vector, mesh.positions.len),
        .screen = try arena.alloc(srapi.Transformed, mesh.positions.len),
        .outcodes = try arena.alloc(Outcode, mesh.positions.len),
        .colours = null,
        // The object's own texture coordinates stand in for the generated ones.
        .generated = object.own_uv,
        .visible = undefined,
        .counts = try arena.alloc(u32, mesh.surfaces.len),
    };
    @memset(drawn.outcodes, .{});
    const marks = try arena.alloc(u8, mesh.positions.len);
    @memset(marks, 0);
    drawn.visible = try cull(arena, context, object, mesh, &drawn, marks) orelse return null;

    var listed: std.ArrayList(u16) = .empty;
    if (!clip.any()) {
        for (marks, 0..) |mark, v| {
            if (mark != 0) try listed.append(arena, @intCast(v));
        }
        for (listed.items) |v| {
            drawn.view[v] = transform(mesh, matrix, relative, morph, v);
            drawn.screen[v] = context.projection.transform(drawn.view[v]);
        }
    } else {
        for (marks, 0..) |mark, v| {
            if (mark == 0) continue;
            drawn.view[v] = transform(mesh, matrix, relative, morph, v);
            drawn.outcodes[v] = context.projection.outcode(drawn.view[v]);
        }
        drawn.visible = markClipped(mesh, &drawn, marks, object.flags.portal_clipped);
        for (marks, 0..) |mark, v| {
            if (mark == 0) continue;
            try listed.append(arena, @intCast(v));
            if (!drawn.outcodes[v].any()) drawn.screen[v] = context.projection.transform(drawn.view[v]);
        }
    }

    const pixel_lit = context.pixel_lighting and object.flags.lit and object.takesLights();
    drawn.colours = try light(arena, object, mesh, lights, listed.items, morph, pixel_lit);
    if (pixel_lit) {
        // Turned into the camera's frame without the object's scale, as the lights see them.
        const turn = context.objectMatrix(object.orientation, 1);
        const normals = try arena.alloc(Vector, mesh.positions.len);
        for (listed.items) |v| normals[v] = math.transform(turn, blendedNormal(mesh, morph, v));
        drawn.normals = normals;
    }
    for ([2]bool{ object.flags.normals_first, object.flags.normals_second }, 0..) |wanted, pass| {
        if (wanted) drawn.generated[pass] = try sphereMapped(arena, mesh, matrix, listed.items, morph);
    }

    budget.vertices += mesh.positions.len;
    budget.polygons += mesh.polygons.len;
    return drawn;
}

/// The object's bounding sphere against the view (`0x004C5E20`): null when it lies outside, or is
/// smaller than a pixel; every plane when it crosses one, else none.
fn sphereTest(projection: srapi.Projection, object: *const MeshObject, relative: Vector) ?Outcode {
    if (object.flags.unbounded) return Outcode.all;
    const radius = object.radius * object.scale;
    var clip: Outcode = .{};
    if (projection.scale[0] * radius < relative[2]) return null;
    const in_front = projection.near - relative[2];
    if (radius < in_front) return null;
    if (-radius < in_front) clip = Outcode.all;
    for (projection.sides) |side| {
        const out = math.dot(side, relative);
        if (radius < out) return null;
        if (-radius < out) clip = Outcode.all;
    }
    return clip;
}

/// Picks the level of detail by depth, and how far toward the next it has moved; then, for an
/// object that may need clipping, tests the level's bounding box, each corner as the clipper tests
/// a vertex (`srclip.flags`) (`object_level_select`, `0x004C5FB0`). Null when the object is past
/// its last level or wholly outside a plane. The finer levels reach `context.finer` times further
/// than the depth has them, the last one not.
fn chooseLevel(
    context: *const srapi.Context,
    object: *MeshObject,
    relative: Vector,
    matrix: math.Matrix,
    sphere: Outcode,
    morph: *Morph,
) Allocator.Error!?Outcode {
    morph.* = .{};
    if (!object.flags.finest) {
        const depth = relative[2] / context.detail;
        const count = object.levels.len;
        if (count == 0 or !(depth < object.levels[count - 1].until)) return null;
        const reach = depth / context.finer;
        var level: usize = 0;
        while (level + 1 < count and !(reach < object.levels[level].until)) : (level += 1) {}
        object.level = level;
        if (level + 1 < count) {
            const start: f32 = if (level == 0) 0 else object.levels[level - 1].until;
            const along = (reach - start) / (object.levels[level].until - start);
            const moved = Morph.moved(along);
            if (object.flags.geomorph_normals) morph.normals = moved;
            if (object.flags.geomorph_positions) morph.positions = moved;
        }
    } else {
        object.level = 0;
    }

    var clip: Outcode = .{};
    if (sphere.any()) {
        const mesh = object.levels[object.level].mesh;
        var outside: Outcode = .{};
        var every: Outcode = Outcode.all;
        for (0..8) |n| {
            const point = math.transform(matrix, math.Corner.of(n).in(mesh.bounds)) + relative;
            const code = srclip.flags(context.projection, point);
            outside = outside.either(code);
            every = every.both(code);
        }
        if (every.any()) return null;
        clip = outside;
    }
    if (object.flags.portal_clipped) clip.portal = true;
    return clip;
}

/// Lists each surface's polygons that face the camera, with the face mask applied, and marks their
/// vertices (`mesh_cull`). Null for a mesh with no polygons at all.
fn cull(
    arena: Allocator,
    context: *const srapi.Context,
    object: *const MeshObject,
    mesh: *const Mesh,
    drawn: *Drawn,
    marks: []u8,
) Allocator.Error!?[]Visible {
    if (mesh.polygons.len == 0) return null;
    const viewpoint = object.place().inverse(context.camera.position) / @as(Vector, @splat(object.scale));
    var visible: std.ArrayList(Visible) = try .initCapacity(arena, mesh.polygons.len);
    var polygon: u32 = 0;
    for (mesh.surfaces, drawn.counts) |surface, *count| {
        count.* = 0;
        for (0..surface.polygons) |_| {
            defer polygon += 1;
            const flags: shp.Face.Flags = if (mesh.face_flags) |all| all[polygon] else .{};
            switch (showing(flags, object.face_mask, !object.flags.not_culled)) {
                .never => continue,
                .facing => if (!mesh.planes[polygon].faces(viewpoint)) continue,
                .always => {},
            }
            visible.appendAssumeCapacity(.{ .polygon = polygon });
            count.* += 1;
        }
    }
    for (visible.items) |v| {
        const p = mesh.polygons[v.polygon];
        for (mesh.indices[p.first..][0..p.count]) |index| marks[index] +|= 1;
    }
    return visible.items;
}

/// Drops the polygons wholly outside a plane, unmarking their vertices, and notes the planes the
/// rest cross (`0x004C6A60`). Returns the visible polygons left.
fn markClipped(mesh: *const Mesh, drawn: *Drawn, marks: []u8, portal: bool) []Visible {
    var kept: usize = 0;
    var read: usize = 0;
    for (drawn.counts) |*count| {
        const surface_count = count.*;
        count.* = 0;
        for (0..surface_count) |_| {
            defer read += 1;
            const v = drawn.visible[read];
            const p = mesh.polygons[v.polygon];
            var every: Outcode = Outcode.all;
            var any: Outcode = .{};
            for (mesh.indices[p.first..][0..p.count]) |index| {
                every = every.both(drawn.outcodes[index]);
                any = any.either(drawn.outcodes[index]);
            }
            if (p.count < 1 or every.any()) {
                for (mesh.indices[p.first..][0..p.count]) |index| marks[index] -|= 1;
                continue;
            }
            if (portal) any.portal = true;
            drawn.visible[kept] = .{ .polygon = v.polygon, .clip = any };
            kept += 1;
            count.* += 1;
        }
    }
    return drawn.visible[0..kept];
}

/// A vertex in the camera's frame, moved toward its next level's counterpart by `morph`.
fn transform(mesh: *const Mesh, matrix: math.Matrix, relative: Vector, morph: Morph, v: usize) Vector {
    var p = mesh.positions[v];
    if (morph.positions != 0) {
        if (mesh.morph_positions) |targets| p += (targets[v] - p) * @as(Vector, @splat(morph.positions));
    }
    return math.transform(matrix, p) + relative;
}

fn blendedNormal(mesh: *const Mesh, morph: Morph, v: usize) Vector {
    const n = mesh.normals[v];
    if (morph.normals > 0) {
        if (mesh.morph_normals) |targets| return n * @as(Vector, @splat(1 - morph.normals)) + targets[v] * @as(Vector, @splat(morph.normals));
    }
    return n;
}

/// The listed vertices' colours (`mesh_light`, `0x004C7060`): the object's colour and the ambient
/// lights for a lit object, plus baked colours, then each point and directional light, clamped to 1
/// when anything past the colour and the ambient lights was added. Null for an object neither lit
/// nor baked. With `pixel_lit`, the lights the device adds to each pixel are left out
/// (`srlight.Light.per_pixel`).
///
/// **Fix:** the game takes an object's own colours (`baked_object`) in place of the mesh's
/// (`baked_mesh`), so a model that can cloak, whose parts have colours of their own for the cloak,
/// never shows the static lights baked into its meshes. OpenReliant adds the mesh's too, whose
/// alpha is nothing, so the cloak's see-through hull is as clear as the game has it.
fn light(
    arena: Allocator,
    object: *const MeshObject,
    mesh: *const Mesh,
    lights: []const srlight.Light,
    listed: []const u16,
    morph: Morph,
    pixel_lit: bool,
) Allocator.Error!?[][4]f32 {
    const flags = object.flags;
    if (!flags.lit and !flags.baked_mesh and !flags.baked_object) return null;
    const colours = try arena.alloc([4]f32, mesh.positions.len);
    const takes_lights = object.takesLights();

    var base: [4]f32 = @splat(0);
    if (flags.lit) {
        base = object.colour;
        if (takes_lights) {
            for (lights) |l| {
                if (l.kind != .ambient or !l.reaches(object.light_mask)) continue;
                for (0..3) |c| base[c] += l.colour[c] * l.intensity;
                base[3] += l.alpha * l.intensity;
            }
        }
    }

    const own: ?[]const [4]f32 = if (flags.baked_object) object.ownColours() else null;
    const meshes: ?[]const [4]f32 = if (flags.baked_mesh) mesh.baked else null;
    for (listed) |v| {
        colours[v] = base;
        for ([_]?[]const [4]f32{ own, meshes }) |baked| {
            const b = baked orelse continue;
            for (&colours[v], b[v]) |*c, add| c.* += add;
        }
    }
    var clamp = own != null or meshes != null;

    if (flags.lit and takes_lights) {
        for (lights) |l| {
            if (!l.reaches(object.light_mask)) continue;
            if (pixel_lit and l.per_pixel) continue;
            switch (l.kind) {
                .ambient => {},
                .directional => |forward| {
                    const along = math.normalize(math.transformTransposed(object.orientation, forward)) *
                        @as(Vector, @splat(l.intensity));
                    for (listed) |v| {
                        const amount = math.dot(along, blendedNormal(mesh, morph, v));
                        if (amount > 0) {
                            for (0..3) |c| colours[v][c] += amount * l.colour[c];
                        }
                    }
                    clamp = true;
                },
                .point => |point| {
                    const to = object.place().inverse(point.position);
                    const reach = l.reach(point);
                    const within = reach + mesh.radius;
                    if (within * within <= math.dot(to, to)) continue;
                    for (listed) |v| {
                        const d = to - mesh.positions[v] * @as(Vector, @splat(object.scale));
                        const r2 = math.dot(d, d);
                        if (!(r2 < reach * reach)) continue;
                        const along = math.dot(d, blendedNormal(mesh, morph, v));
                        if (!(along > 0)) continue;
                        const amount = srlight.falloff(r2, reach) * along;
                        for (0..3) |c| colours[v][c] += amount * l.intensity * l.colour[c];
                    }
                    clamp = true;
                },
            }
        }
    }
    if (clamp) {
        for (listed) |v| {
            for (&colours[v]) |*c| c.* = @min(c.*, 1);
        }
    }
    return colours;
}

/// Coordinates from the listed vertices' normals turned into the camera's frame
/// (`mesh_sphere_map`).
fn sphereMapped(arena: Allocator, mesh: *const Mesh, matrix: math.Matrix, listed: []const u16, morph: Morph) Allocator.Error![][2]f32 {
    const out = try arena.alloc([2]f32, mesh.positions.len);
    for (listed) |v| {
        const n = math.transform(matrix, blendedNormal(mesh, morph, v));
        out[v] = sphereMap(n);
    }
    return out;
}

test showing {
    const default_face_mask = srapiext.default_face_mask;
    const plain: shp.Face.Flags = .{};
    const cap: shp.Face.Flags = .{ .cap = true };
    const two_sided: shp.Face.Flags = .{ .two_sided = true };
    // A plain face shows while it faces the viewpoint; a cap face never, until the mask clears
    // its bit.
    try std.testing.expectEqual(Showing.facing, showing(plain, default_face_mask, true));
    try std.testing.expectEqual(Showing.never, showing(cap, default_face_mask, true));
    try std.testing.expectEqual(Showing.facing, showing(cap, default_face_mask & ~caps_hidden, true));
    try std.testing.expectEqual(Showing.facing, showing(cap, 0xFE, true));
    // A two-sided face always shows, unless the mask leaves its bit out.
    try std.testing.expectEqual(Showing.always, showing(two_sided, default_face_mask, true));
    try std.testing.expectEqual(Showing.facing, showing(two_sided, 0xFD, true));
    // Without culling, every face that isn't hidden shows.
    try std.testing.expectEqual(Showing.always, showing(plain, default_face_mask, false));
}

test "Morph.moved" {
    try std.testing.expectEqual(0, Morph.moved(0.5));
    try std.testing.expectEqual(0, Morph.moved(0.75));
    try std.testing.expectEqual(0.5, Morph.moved(0.875));
    try std.testing.expectEqual(1, Morph.moved(1));
}

test sphereMap {
    try std.testing.expectEqual([2]f32{ 0.5, 0.5 }, sphereMap(.{ 0, 0, -1 }));
    try std.testing.expectEqual([2]f32{ 1, 0 }, sphereMap(.{ 1, -1, 0 }));
}

pub const testing = struct {
    /// A square of two triangles facing -Z, 200 across, at the origin: one surface of an
    /// untextured, lit, opaque material.
    pub fn square(gpa: Allocator) Allocator.Error!Mesh {
        const positions = try gpa.dupe(Vector, &.{ .{ -100, -100, 0 }, .{ 100, -100, 0 }, .{ 100, 100, 0 }, .{ -100, 100, 0 } });
        const normals = try gpa.dupe(Vector, &.{ .{ 0, 0, -1 }, .{ 0, 0, -1 }, .{ 0, 0, -1 }, .{ 0, 0, -1 } });
        const polygons = try gpa.dupe(srapiext.Polygon, &.{
            .{ .kind = .triangle, .continues = 0, .first = 0, .count = 3 },
            .{ .kind = .triangle, .continues = 0, .first = 3, .count = 3 },
        });
        const indices = try gpa.dupe(u16, &.{ 0, 2, 1, 0, 3, 2 });
        const planes = try gpa.dupe(srapiext.Plane, &.{
            .{ .normal = .{ 0, 0, -1 }, .distance = 0 },
            .{ .normal = .{ 0, 0, -1 }, .distance = 0 },
        });
        const biases = try gpa.dupe(f32, &.{ 0, 0 });
        const surfaces = try gpa.dupe(srapiext.Surface, &.{.{
            .polygons = 2,
            .material = .onePass(.{ .coordinates = .none, .lit = true, .blend = .off }),
        }});
        return .{
            .positions = positions,
            .normals = normals,
            .polygons = polygons,
            .indices = indices,
            .uv = .{ null, null },
            .planes = planes,
            .biases = biases,
            .surfaces = surfaces,
            .bounds = .{ .{ -100, -100, 0 }, .{ 100, 100, 0 } },
            .radius = 141.43,
        };
    }
};

test pipe {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mesh = try testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = 5000 }};
    var object: MeshObject = .{ .flags = .{ .lit = true }, .position = .{ 0, 0, 1000 }, .radius = mesh.radius, .levels = &levels };
    const context: srapi.Context = .{ .projection = .init(1024, 768, srapi.full_screen, .{ 0.6, 0.8 }) };
    const lights = [_]srlight.Light{
        .{ .mask = 0x04, .intensity = 1, .colour = .{ 0.25, 0.25, 0.25 }, .kind = .ambient },
        .{ .mask = 0x01, .intensity = 1, .colour = .{ 1, 1, 1 }, .kind = .{ .directional = .{ 0, 0, -1 } } },
    };
    var budget: Budget = .{};

    const drawn = (try pipe(arena, &context, &object, &lights, &budget)).?;
    try std.testing.expectEqual(2, drawn.visible.len);
    try std.testing.expectEqual(4, budget.vertices);
    // Facing the camera, in the middle of the view, lit by the ambient and the light, clamped.
    try std.testing.expectApproxEqAbs(512 - 100.0 / 1000.0 * context.projection.scale[0], drawn.screen[0].x, 1e-3);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 0 }, drawn.colours.?[0]);

    // Turned away, it is culled; beyond its last level it is not drawn at all.
    object.orientation = math.rotation(.y, std.math.pi);
    try std.testing.expectEqual(0, (try pipe(arena, &context, &object, &lights, &budget)).?.visible.len);
    object.orientation = math.identity;
    object.position = .{ 0, 0, 6000 };
    try std.testing.expectEqual(null, try pipe(arena, &context, &object, &lights, &budget));

    // Through the near plane, its polygons are kept with the planes to clip against.
    object.position = .{ 0, 0, 100 };
    const near = (try pipe(arena, &context, &object, &lights, &budget)).?;
    try std.testing.expectEqual(2, near.visible.len);
    try std.testing.expect(!near.visible[0].clip.near);
    object.position = .{ 0, 0, 50 };
    try std.testing.expectEqual(null, try pipe(arena, &context, &object, &lights, &budget));

    // An object that would take the frame past its budget is left out.
    object.position = .{ 0, 0, 1000 };
    var full: Budget = .{ .limit = 5 };
    try std.testing.expect(try pipe(arena, &context, &object, &lights, &full) != null);
    try std.testing.expectEqual(null, try pipe(arena, &context, &object, &lights, &full));
    try std.testing.expectEqual(srapi.original_budget, (Budget{}).limit);
}

test "the finer levels of detail reach further, the last one not" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mesh = try testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{ .{ .mesh = &mesh, .until = 1000 }, .{ .mesh = &mesh, .until = 5000 } };
    var object: MeshObject = .{ .flags = .{}, .position = .{ 0, 0, 3000 }, .radius = mesh.radius, .levels = &levels };
    var context: srapi.Context = .{ .projection = .init(1024, 768, srapi.full_screen, .{ 0.6, 0.8 }), .detail = 2 };
    var budget: Budget = .{};

    // Halved by the divisor, the depth is past the first level's end and within the second's.
    _ = (try pipe(arena, &context, &object, &.{}, &budget)).?;
    try std.testing.expectEqual(1, object.level);
    // Reaching twice as far, the first level holds out; the last still ends where it did.
    context.finer = 2;
    _ = (try pipe(arena, &context, &object, &.{}, &budget)).?;
    try std.testing.expectEqual(0, object.level);
    object.position = .{ 0, 0, 11000 };
    try std.testing.expectEqual(null, try pipe(arena, &context, &object, &.{}, &budget));
}

test "an object's own colours and its mesh's baked ones add up" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var mesh = try testing.square(gpa);
    defer mesh.deinit(gpa);
    mesh.baked = try gpa.dupe([4]f32, &@as([4][4]f32, @splat(.{ 0.5, 0, 0, 0 })));
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    const own = [_][4]f32{ .{ 0, 0, 0, 0.75 }, @splat(0), @splat(0), @splat(0) };
    const object: MeshObject = .{
        .flags = .{ .baked_mesh = true, .baked_object = true },
        .position = @splat(0),
        .radius = mesh.radius,
        .levels = &levels,
        .baked = &own,
    };
    // The static light the mesh bakes shows through the object's own colours, and the alpha is
    // the object's alone.
    const colours = (try light(arena_state.allocator(), &object, &mesh, &.{}, &.{ 0, 1, 2, 3 }, .{}, false)).?;
    try std.testing.expectEqual([4]f32{ 0.5, 0, 0, 0.75 }, colours[0]);
    try std.testing.expectEqual([4]f32{ 0.5, 0, 0, 0 }, colours[1]);
}

test "each light's share of a vertex's colour" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mesh = try testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    // The square faces -Z; its first corner stands at (-100, -100, 0).
    const object: MeshObject = .{ .flags = .{ .lit = true }, .position = @splat(0), .radius = mesh.radius, .levels = &levels };
    const listed = [_]u16{ 0, 1, 2, 3 };

    // An ambient light adds its colour times its intensity, and nothing past it is clamped.
    const ambient = [_]srlight.Light{.{ .mask = 4, .intensity = 0.5, .colour = .{ 0.08, 0.08, 0.08 }, .alpha = 0.5, .kind = .ambient }};
    const dim = (try light(arena, &object, &mesh, &ambient, &listed, .{}, false)).?;
    try std.testing.expectEqual([4]f32{ 0.04, 0.04, 0.04, 0.25 }, dim[0]);

    // A directional light along the normal adds its colour times its intensity; one from behind
    // adds nothing.
    var lights = [_]srlight.Light{.{ .mask = 1, .intensity = 0.5, .colour = .{ 1, 1, 0.8 }, .kind = .{ .directional = .{ 0, 0, -1 } } }};
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.4, 0 }, (try light(arena, &object, &mesh, &lights, &listed, .{}, false)).?[0]);
    lights[0].kind = .{ .directional = .{ 0, 0, 1 } };
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, (try light(arena, &object, &mesh, &lights, &listed, .{}, false)).?[0]);

    // A point light straight in front of a corner, at half its reach: the cosine is 1 and
    // (1 - 1/2)^2 a quarter. Out of its reach, nothing.
    lights[0] = .{ .mask = 1, .intensity = 1, .colour = .{ 1, 1, 1 }, .kind = .{ .point = .{ .position = .{ -100, -100, -10 }, .range = 20 } } };
    const near = (try light(arena, &object, &mesh, &lights, &listed, .{}, false)).?;
    try std.testing.expectApproxEqAbs(0.25, near[0][0], 1e-6);
    try std.testing.expectEqual(0, near[2][0]);
}

test "pipe for a device that lights each pixel" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mesh = try testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = 5000 }};
    var object: MeshObject = .{ .flags = .{ .lit = true }, .position = .{ 0, 0, 1000 }, .radius = mesh.radius, .levels = &levels };
    var context: srapi.Context = .{ .projection = .init(1024, 768, srapi.full_screen, .{ 0.6, 0.8 }), .pixel_lighting = true };
    var lights = [_]srlight.Light{
        .{ .mask = 0x04, .intensity = 1, .colour = .{ 0.25, 0.25, 0.25 }, .kind = .ambient },
        .{ .mask = 0x01, .intensity = 1, .colour = .{ 1, 1, 1 }, .kind = .{ .directional = .{ 0, 0, -1 } }, .per_pixel = true },
    };
    var budget: Budget = .{};

    // The vertices keep the ambient light alone, and carry their normals in the camera's frame
    // for the device to add the directional light with.
    object.orientation = math.rotation(.x, 0.5);
    context.camera.orientation = math.rotation(.y, 0.25);
    const drawn = (try pipe(arena, &context, &object, &lights, &budget)).?;
    try std.testing.expectEqual([4]f32{ 0.25, 0.25, 0.25, 0 }, drawn.colours.?[0]);
    const turned = math.transformTransposed(context.camera.orientation, math.transform(object.orientation, .{ 0, 0, -1 }));
    try std.testing.expect(math.length(drawn.normals.?[2] - turned) < 1e-6);

    // A light the device doesn't take is still added to each vertex.
    lights[1].per_pixel = false;
    try std.testing.expect((try pipe(arena, &context, &object, &lights, &budget)).?.colours.?[0][0] > 0.25);
    lights[1].per_pixel = true;

    // An object that takes no lights has none to hand over, and neither does a device that
    // lights each vertex.
    object.light_mask = srlight.no_lights;
    try std.testing.expectEqual(null, (try pipe(arena, &context, &object, &lights, &budget)).?.normals);
    object.light_mask = 0;
    context.pixel_lighting = false;
    const lit = (try pipe(arena, &context, &object, &lights, &budget)).?;
    try std.testing.expectEqual(null, lit.normals);
    try std.testing.expect(lit.colours.?[0][0] > 0.25);
}
