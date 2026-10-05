//! A model (`shp.Model`) built from a Wavefront OBJ file (`obj.zig`), as `sltool shp from-obj`
//! writes it, for mods' ships and missiles made in a modelling tool. Nothing of the game's goes
//! into it.
//!
//! An object's name says what it becomes, before a `:` and a number, case aside; a modelling
//! tool's `.001` after it is left out:
//!
//! - `cockpit`: the cockpit part, which leaves the ship as the pilot's pod when the pilot ejects.
//! - `gun_muzzle:<gun type>`, `missile:<missile>`, `engine_glow:<glow>`, `light:<colour>`,
//!   `eject_point`, `launch_point` and `dock_point`: an attachment of that kind, standing at the
//!   middle of the object's corners, as large as their box. The number is its gun type (1 by
//!   default), its missile at every loadout tier, its glow or its colour (0 by default). An engine
//!   glow burns backward, a light is a sprite that lights nothing round it, and an eject point
//!   throws the pod up; the cockpit holds it where there is one.
//! - `jump_trail` and `jump_light`: a point where a jump's trails stream from and one where its
//!   lights stand along the hull (`shp.PointList.Kind`), at the middle of the object's corners. A
//!   model without jump trails gets one at each engine glow, so that each engine streams one.
//! - Anything else: the body, a part of its own.
//!
//! Each part is one level of detail, its faces each taking the texture their `usemtl` names (none
//! for an untextured face), its vertices' normals the file's or the faces' around them. Each part
//! gets a collision tree of boxes, split along their longest side until a box holds few faces, and
//! mass properties as though it filled its box at `Options.density`. The file's Y up frame is
//! turned into the model's, Y down, as `sltool shp obj` turns it the other way (`Vec3.toYUp`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const obj = @import("../obj.zig");
const shp = @import("../shp.zig");
const Vec3 = shp.Vec3;

pub const Options = struct {
    /// The mass of a unit of a part's box (`shp.Part.density`).
    density: f32 = default_density,
    /// Whether every face is drawn from behind too (`shp.Face.Flags.two_sided`), for a model with
    /// open edges.
    two_sided: bool = false,
    /// Whether the loader builds the second set of meshes the cloak is drawn with
    /// (`shp.Header.Flags.cloak`), as for a ship that cloaks.
    cloak: bool = false,

    /// Makes a fighter as large as the Predator about as heavy.
    pub const default_density: f32 = 0.1;
};

pub const Error = Allocator.Error || error{
    /// The file has no faces outside its attachments, so no body.
    NoBody,
    /// An attachment's number doesn't read as one.
    BadAttachment,
};

/// The model the OBJ `file` makes, in `arena`.
pub fn build(arena: Allocator, file: obj.File, options: Options) Error!shp.Model {
    var body: std.ArrayList(obj.Triangle) = .empty;
    var cockpit: std.ArrayList(obj.Triangle) = .empty;
    var body_attachments: std.ArrayList(shp.Attachment) = .empty;
    var cockpit_attachments: std.ArrayList(shp.Attachment) = .empty;
    var trails: std.ArrayList(shp.Point) = .empty;
    var lights: std.ArrayList(shp.Point) = .empty;
    for (file.objects) |object| {
        const role = try Role.of(object.name);
        // A marker becomes an attachment or a point, or nothing.
        if (object.marker and (role == .body or role == .cockpit)) continue;
        switch (role) {
            .body => try body.appendSlice(arena, object.triangles),
            .cockpit => try cockpit.appendSlice(arena, object.triangles),
            .attachment => |made| {
                var attachment = made;
                place(&attachment, file, object.triangles);
                const into = if (attachment.kind == .eject_point) &cockpit_attachments else &body_attachments;
                try into.append(arena, attachment);
            },
            .point => |kind| {
                const into = if (kind == .jump_trails) &trails else &lights;
                try into.append(arena, pointAt(Box.ofCorners(file, object.triangles).centre()));
            },
        }
    }
    if (body.items.len == 0) return error.NoBody;
    // Without trails of its own, each engine streams one.
    if (trails.items.len == 0) for (body_attachments.items) |attachment| {
        if (attachment.kind == .engine_glow) try trails.append(arena, pointAt(attachment.position));
    };
    var point_lists: std.ArrayList(shp.PointList) = .empty;
    for ([_]struct { shp.PointList.Kind, []shp.Point }{ .{ .jump_trails, trails.items }, .{ .jump_lights, lights.items } }) |entry| {
        const kind, const points = entry;
        if (points.len > 0) try point_lists.append(arena, .{ .kind = kind, .points = points });
    }
    // Without a cockpit, the eject point stays on the body.
    if (cockpit.items.len == 0) try body_attachments.appendSlice(arena, cockpit_attachments.items);

    var parts: std.ArrayList(shp.PartData) = .empty;
    if (cockpit.items.len > 0) try parts.append(arena, try makePart(arena, file, "Cockpit", .cockpit, cockpit.items, cockpit_attachments.items, &.{}, options));
    try parts.append(arena, try makePart(arena, file, "Body", .hull, body.items, body_attachments.items, point_lists.items, options));

    var header = std.mem.zeroes(shp.Header);
    header.version = header_version;
    header.eye = eyePoint(parts.items);
    header.flags.cloak = options.cloak;
    return .{ .header = header, .parts = parts.items, .trailing_bytes = 0 };
}

/// The version shipped models carry (`shp.Header.version`), which the loader doesn't read.
const header_version = 107;

/// What an object of the file becomes, by its name.
const Role = union(enum) {
    body,
    cockpit,
    attachment: shp.Attachment,
    point: shp.PointList.Kind,

    fn of(full: []const u8) Error!Role {
        const name = full[0 .. std.mem.indexOfScalar(u8, full, '.') orelse full.len];
        const kind_name, const number_text = if (std.mem.indexOfScalar(u8, name, ':')) |at| .{ name[0..at], name[at + 1 ..] } else .{ name, "" };
        if (std.ascii.eqlIgnoreCase(kind_name, "cockpit")) return .cockpit;
        if (std.ascii.eqlIgnoreCase(kind_name, "jump_trail")) return .{ .point = .jump_trails };
        if (std.ascii.eqlIgnoreCase(kind_name, "jump_light")) return .{ .point = .jump_lights };
        const kinds = [_]struct { []const u8, shp.Attachment.Kind }{
            .{ "gun_muzzle", .gun_muzzle }, .{ "missile", .missile },         .{ "engine_glow", .engine_glow },
            .{ "light", .light },           .{ "eject_point", .eject_point }, .{ "launch_point", .launch_point },
            .{ "dock_point", .dock_point },
        };
        for (kinds) |entry| {
            const named, const kind = entry;
            if (!std.ascii.eqlIgnoreCase(kind_name, named)) continue;
            const number: u32 = if (number_text.len == 0)
                (if (kind == .gun_muzzle) default_gun_type else 0)
            else
                std.fmt.parseInt(u32, number_text, 10) catch return error.BadAttachment;
            var attachment = std.mem.zeroes(shp.Attachment);
            attachment.kind = kind;
            attachment.orientation = identity;
            if (kind == .gun_muzzle) attachment.gun_type = number else attachment.id = number;
            // A hardpoint holds its missile at every loadout tier (`shp.Attachment.wordFor`).
            if (kind == .missile) attachment.later_tiers = @splat(number);
            return .{ .attachment = attachment };
        }
        return .body;
    }
};

/// The gun type a gun muzzle fires without a number: the Laser Cannon.
const default_gun_type = 1;

const identity = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

/// A quarter turn about X, which points an eject point's Z axis, the way it throws the pod, up:
/// the model's Y points down.
const facing_up = [9]f32{ 1, 0, 0, 0, 0, -1, 0, 1, 0 };

/// `attachment` placed at the middle of `triangles`' corners, as large as their box: an engine
/// glow's length reaching back, a light's reach its size, and an eject point turned to throw up.
fn place(attachment: *shp.Attachment, file: obj.File, triangles: []const obj.Triangle) void {
    const box = Box.ofCorners(file, triangles);
    attachment.position = box.centre();
    const half = box.half();
    attachment.size = .{ half.x, half.y, half.z };
    switch (attachment.kind) {
        .engine_glow => attachment.size[2] = -half.z,
        .light => attachment.light_brightness = 1,
        .eject_point => attachment.orientation = facing_up,
        else => {},
    }
}

/// A point at `position`; `makePart` sets its vertex once the part's mesh exists.
fn pointAt(position: Vec3) shp.Point {
    return .{ ._unknown_00 = 0, .vertex = 0, .position = position };
}

/// The vertex of `mesh` nearest `position`.
fn nearestVertex(mesh: shp.Mesh, position: Vec3) u32 {
    var best: u32 = 0;
    var least = std.math.inf(f32);
    for (mesh.vertices, 0..) |vertex, at| {
        const away = [3]f32{ vertex.position.x - position.x, vertex.position.y - position.y, vertex.position.z - position.z };
        const distance = away[0] * away[0] + away[1] * away[1] + away[2] * away[2];
        if (distance < least) {
            least = distance;
            best = @intCast(at);
        }
    }
    return best;
}

/// A position of the file, turned into the model's frame.
fn positionOf(file: obj.File, index: u32) Vec3 {
    const p = file.positions[index];
    return (Vec3{ .x = p[0], .y = p[1], .z = p[2] }).toYUp();
}

/// An axis-aligned box.
const Box = struct {
    lo: Vec3,
    hi: Vec3,

    const empty: Box = .{ .lo = .{ .x = std.math.inf(f32), .y = std.math.inf(f32), .z = std.math.inf(f32) }, .hi = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32), .z = -std.math.inf(f32) } };

    fn add(box: *Box, v: Vec3) void {
        box.lo = Vec3.min(box.lo, v);
        box.hi = Vec3.max(box.hi, v);
    }

    fn ofCorners(file: obj.File, triangles: []const obj.Triangle) Box {
        var box: Box = .empty;
        for (triangles) |triangle| for (triangle.corners) |corner| box.add(positionOf(file, corner.position));
        return if (box.lo.x > box.hi.x) .{ .lo = .zero, .hi = .zero } else box;
    }

    fn centre(box: Box) Vec3 {
        return .{ .x = (box.lo.x + box.hi.x) / 2, .y = (box.lo.y + box.hi.y) / 2, .z = (box.lo.z + box.hi.z) / 2 };
    }

    fn half(box: Box) Vec3 {
        return .{ .x = (box.hi.x - box.lo.x) / 2, .y = (box.hi.y - box.lo.y) / 2, .z = (box.hi.z - box.lo.z) / 2 };
    }
};

/// A part of `class` named `name`, made of `triangles`, with `attachments` and `point_lists`.
/// Each point is tied to the vertex nearest it.
fn makePart(arena: Allocator, file: obj.File, name: []const u8, class: shp.Part.Class, triangles: []const obj.Triangle, attachments: []const shp.Attachment, point_lists: []shp.PointList, options: Options) Error!shp.PartData {
    const mesh = try makeMesh(arena, file, triangles, options);
    for (point_lists) |list| for (list.points) |*point| {
        point.vertex = nearestVertex(mesh, point.position);
    };
    const box = Box.ofCorners(file, triangles);
    var part = std.mem.zeroes(shp.Part);
    @memcpy(part.name_bytes[0..name.len], name);
    part.class = class;
    part.bounds_min = box.lo;
    part.bounds_max = box.hi;
    part.parent = shp.no_index;
    part.orientation = identity;
    part.turret_slot = -1;
    fillMass(&part, box, options.density);
    const tree = try makeTree(arena, mesh);
    const meshes = try arena.alloc(shp.Mesh, 1);
    meshes[0] = mesh;
    return .{
        .part = part,
        .meshes = meshes,
        .attachments = try arena.dupe(shp.Attachment, attachments),
        .point_lists = point_lists,
        .tracks = &.{},
        .nodes = tree.nodes,
        .node_faces = tree.faces,
    };
}

/// The part's mass properties, as though it filled `box` at `density`: the integrals over the box
/// of x², y², z², xy, yz, xz, x, y and z, and its volume.
fn fillMass(part: *shp.Part, box: Box, density: f32) void {
    const lo = [3]f32{ box.lo.x, box.lo.y, box.lo.z };
    const hi = [3]f32{ box.hi.x, box.hi.y, box.hi.z };
    var length: [3]f32 = undefined;
    var first: [3]f32 = undefined;
    var second: [3]f32 = undefined;
    for (0..3) |axis| {
        length[axis] = hi[axis] - lo[axis];
        first[axis] = (hi[axis] * hi[axis] - lo[axis] * lo[axis]) / 2;
        second[axis] = (hi[axis] * hi[axis] * hi[axis] - lo[axis] * lo[axis] * lo[axis]) / 3;
    }
    part.volume = length[0] * length[1] * length[2];
    part.density = density;
    part.second_moments = .{ second[0] * length[1] * length[2], second[1] * length[0] * length[2], second[2] * length[0] * length[1] };
    part.products = .{ first[0] * first[1] * length[2], first[1] * first[2] * length[0], first[0] * first[2] * length[1] };
    part.first_moments = .{ first[0] * length[1] * length[2], first[1] * length[0] * length[2], first[2] * length[0] * length[1] };
}

/// One level of `triangles`: a vertex for each corner's position and normal, a material for
/// each texture, and a face for each triangle.
fn makeMesh(arena: Allocator, file: obj.File, triangles: []const obj.Triangle, options: Options) Allocator.Error!shp.Mesh {
    const smooth = try smoothNormals(arena, file, triangles);
    var vertices: std.ArrayList(shp.Vertex) = .empty;
    var seen: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;
    var materials: std.ArrayList(shp.Material) = .empty;
    const faces = try arena.alloc(shp.Face, triangles.len);
    for (triangles, faces) |triangle, *face| {
        var corners: [3]u32 = undefined;
        var positions: [3]Vec3 = undefined;
        for (triangle.corners, &corners, &positions) |corner, *at, *position| {
            position.* = positionOf(file, corner.position);
            // The file's normal where it gives one, else the faces' round the position.
            const key = [2]u32{ corner.position, if (corner.normal) |n| n else std.math.maxInt(u32) };
            const entry = try seen.getOrPut(arena, key);
            if (!entry.found_existing) {
                const normal = if (corner.normal) |n| (Vec3{ .x = file.normals[n][0], .y = file.normals[n][1], .z = file.normals[n][2] }).toYUp() else smooth.get(corner.position).?;
                entry.value_ptr.* = @intCast(vertices.items.len);
                try vertices.append(arena, .{ .position = position.*, .normal = normal, .unknown_18 = 0, .next_lod_vertex = shp.no_index });
            }
            at.* = entry.value_ptr.*;
        }
        face.* = std.mem.zeroes(shp.Face);
        face.vertices = corners;
        face.normal = faceNormal(positions);
        face.flags.two_sided = options.two_sided;
        face.polygon = .triangle;
        if (triangle.material) |name| {
            face.material = try materialIndex(arena, &materials, name);
            face.shading.mode = .lit;
        } else {
            // An untextured face reads no texture, but its material must be one the level has
            // (`sltool shp check`): `none`, as `sltool shp obj` names a material without a name.
            face.material = try materialIndex(arena, &materials, untextured);
            face.shading.mode = .untextured;
        }
        for (triangle.corners, 0..) |corner, at| {
            // The file's V runs up the picture, the game's down it.
            const uv = if (corner.uv) |n| file.uvs[n] else [2]f32{ 0, 0 };
            face.u[at] = uv[0];
            face.v[at] = 1 - uv[1];
        }
    }
    return .{ .lod = .{ .switch_distance = 0 }, .vertices = vertices.items, .faces = faces, .materials = materials.items };
}

/// The material an untextured face names.
const untextured = "none";

/// The index of the texture `name` among `materials`, added where it isn't yet.
fn materialIndex(arena: Allocator, materials: *std.ArrayList(shp.Material), name: []const u8) Allocator.Error!u32 {
    for (materials.items, 0..) |material, at| {
        if (std.ascii.eqlIgnoreCase(material.name(), name)) return @intCast(at);
    }
    var made = std.mem.zeroes(shp.Material);
    const kept = @min(name.len, made.name_bytes.len - 1);
    @memcpy(made.name_bytes[0..kept], name[0..kept]);
    try materials.append(arena, made);
    return @intCast(materials.items.len - 1);
}

/// `(v1 - v0) x (v2 - v0)` of a triangle's corners `p`: out of its front, and as long as twice its
/// area.
fn frontOf(p: [3]Vec3) [3]f32 {
    const a = [3]f32{ p[1].x - p[0].x, p[1].y - p[0].y, p[1].z - p[0].z };
    const b = [3]f32{ p[2].x - p[0].x, p[2].y - p[0].y, p[2].z - p[0].z };
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// `n` a unit long, or along Z where it has no length.
fn unit(n: [3]f32) Vec3 {
    const length = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    if (length == 0) return .{ .x = 0, .y = 0, .z = 1 };
    return .{ .x = n[0] / length, .y = n[1] / length, .z = n[2] / length };
}

/// The face's normal, a unit long, out of its front (`frontOf`).
fn faceNormal(p: [3]Vec3) Vec3 {
    return unit(frontOf(p));
}

/// Each position's normal as the faces round it make it, each weighted by its area.
fn smoothNormals(arena: Allocator, file: obj.File, triangles: []const obj.Triangle) Allocator.Error!std.AutoHashMapUnmanaged(u32, Vec3) {
    var sums: std.AutoHashMapUnmanaged(u32, [3]f32) = .empty;
    for (triangles) |triangle| {
        var p: [3]Vec3 = undefined;
        for (triangle.corners, &p) |corner, *at| at.* = positionOf(file, corner.position);
        const n = frontOf(p);
        for (triangle.corners) |corner| {
            const entry = try sums.getOrPut(arena, corner.position);
            if (!entry.found_existing) entry.value_ptr.* = .{ 0, 0, 0 };
            for (entry.value_ptr, n) |*sum, add| sum.* += add;
        }
    }
    var normals: std.AutoHashMapUnmanaged(u32, Vec3) = .empty;
    var it = sums.iterator();
    while (it.next()) |entry| try normals.put(arena, entry.key_ptr.*, unit(entry.value_ptr.*));
    return normals;
}

/// The most faces a box of the collision tree holds before it splits.
const leaf_faces = 8;

/// A part's collision tree: its boxes, the root first, and the faces each box that doesn't split
/// holds.
const Tree = struct {
    nodes: []shp.TreeNode,
    faces: [][]u32,
};

/// `mesh`'s collision tree: a box round all its faces, split in two at the middle face along its
/// longest side, and so on, until a box holds `leaf_faces` or fewer.
fn makeTree(arena: Allocator, mesh: shp.Mesh) Allocator.Error!Tree {
    var nodes: std.ArrayList(shp.TreeNode) = .empty;
    var faces: std.ArrayList([]u32) = .empty;
    const all = try arena.alloc(u32, mesh.faces.len);
    for (all, 0..) |*face, at| face.* = @intCast(at);
    _ = try split(arena, mesh, all, &nodes, &faces);
    return .{ .nodes = nodes.items, .faces = faces.items };
}

/// Adds the box round `held` to the tree, and those it splits into, returning its index.
fn split(arena: Allocator, mesh: shp.Mesh, held: []u32, nodes: *std.ArrayList(shp.TreeNode), faces: *std.ArrayList([]u32)) Allocator.Error!i32 {
    var box: Box = .empty;
    for (held) |face| for (mesh.faces[face].vertices) |vertex| box.add(mesh.vertices[vertex].position);
    if (held.len == 0) box = .{ .lo = .zero, .hi = .zero };
    const at = nodes.items.len;
    try nodes.append(arena, .{
        ._unknown_00 = 0,
        .orientation = identity,
        .half_size = box.half(),
        .centre = box.centre(),
        .children = .{ shp.no_index, shp.no_index },
    });
    try faces.append(arena, &.{});
    if (held.len <= leaf_faces) {
        faces.items[at] = held;
        return @intCast(at);
    }
    const size = box.half();
    const axis: u2 = if (size.x >= size.y and size.x >= size.z) 0 else if (size.y >= size.z) 1 else 2;
    const Order = struct {
        mesh: shp.Mesh,
        axis: u2,

        fn middle(order: @This(), face: u32) f32 {
            var sum: f32 = 0;
            for (order.mesh.faces[face].vertices) |vertex| {
                const p = order.mesh.vertices[vertex].position;
                sum += switch (order.axis) {
                    0 => p.x,
                    1 => p.y,
                    else => p.z,
                };
            }
            return sum;
        }

        fn before(order: @This(), a: u32, b: u32) bool {
            return order.middle(a) < order.middle(b);
        }
    };
    std.mem.sort(u32, held, Order{ .mesh = mesh, .axis = axis }, Order.before);
    const half = held.len / 2;
    const first = try split(arena, mesh, held[0..half], nodes, faces);
    const second = try split(arena, mesh, held[half..], nodes, faces);
    nodes.items[at].children = .{ first, second };
    return @intCast(at);
}

/// The cockpit views' eye: over the middle of the cockpit, near its top, or the body's where there
/// is none.
fn eyePoint(parts: []const shp.PartData) Vec3 {
    const part = parts[0].part;
    const middle = Box{ .lo = part.bounds_min, .hi = part.bounds_max };
    const at = middle.centre();
    return .{ .x = at.x, .y = part.bounds_min.y + (part.bounds_max.y - part.bounds_min.y) / 4, .z = at.z };
}

test build {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A box of a body, textured, a cockpit of one triangle, and a muzzle and an engine glow.
    const file = try obj.parse(arena,
        \\v -100 -50 -200
        \\v 100 -50 -200
        \\v 100 50 -200
        \\v -100 50 -200
        \\v -100 -50 200
        \\v 100 -50 200
        \\v 100 50 200
        \\v -100 50 200
        \\vt 0 0
        \\vt 1 1
        \\o Hull
        \\usemtl hull_1
        \\f 1/1 2/2 3/2 4/1
        \\f 5/1 8/2 7/2 6/1
        \\f 1/1 5/1 6/2 2/2
        \\f 4/1 3/2 7/2 8/1
        \\f 1/1 4/1 8/2 5/2
        \\f 2/1 6/1 7/2 3/2
        \\o cockpit
        \\usemtl canopy
        \\f 7 6 5
        \\o gun_muzzle:3.001
        \\f 1 2 3
        \\o engine_glow:7
        \\f 1 2 6
        \\o eject_point
        \\f 5 6 7
        \\o jump_light
        \\f 3 3 3
    );
    const model = try build(arena, file, .{});
    // The cockpit first, then the body.
    try std.testing.expectEqual(2, model.parts.len);
    try std.testing.expectEqual(shp.Part.Class.cockpit, model.parts[0].part.class);
    const body = model.parts[1];
    try std.testing.expectEqualStrings("Body", body.part.name());
    // Twelve triangles of the box, each textured with the one material, Y turned down.
    const mesh = body.meshes[0];
    try std.testing.expectEqual(12, mesh.faces.len);
    try std.testing.expectEqual(1, mesh.materials.len);
    try std.testing.expectEqualStrings("hull_1", mesh.materials[0].name());
    try std.testing.expectEqual(shp.Face.Shading.Mode.lit, mesh.faces[0].shading.mode);
    try std.testing.expectEqual(Vec3{ .x = -100, .y = -50, .z = -200 }, body.part.bounds_min);
    // V turned to run down the picture.
    try std.testing.expectEqual(0, mesh.faces[0].v[1]);
    // Its attachments: the muzzle firing gun type 3, the glow burning backward; the eject point is
    // the cockpit's, throwing up.
    try std.testing.expectEqual(2, body.attachments.len);
    try std.testing.expectEqual(shp.Attachment.Kind.gun_muzzle, body.attachments[0].kind);
    try std.testing.expectEqual(3, body.attachments[0].gun_type);
    try std.testing.expectEqual(7, body.attachments[1].id);
    try std.testing.expect(body.attachments[1].size[2] < 0);
    try std.testing.expectEqual(shp.Attachment.Kind.eject_point, model.parts[0].attachments[0].kind);
    try std.testing.expectEqual(-1, model.parts[0].attachments[0].orientation[5]);
    // A jump trail at the engine glow, which gave none of its own, and the jump light, each on the
    // vertex nearest it.
    const trails = body.pointList(.jump_trails).?.points;
    try std.testing.expectEqual(1, trails.len);
    try std.testing.expectEqual(body.attachments[1].position, trails[0].position);
    const lights = body.pointList(.jump_lights).?.points;
    try std.testing.expectEqual(Vec3{ .x = -100, .y = -50, .z = -200 }, lights[0].position);
    try std.testing.expectEqual(lights[0].position, mesh.vertices[lights[0].vertex].position);
    // A collision tree whose boxes hold every face once.
    var counted: usize = 0;
    for (body.node_faces) |held| counted += held.len;
    try std.testing.expectEqual(12, counted);
    try std.testing.expectEqual(Vec3{ .x = 0, .y = 0, .z = 0 }, body.nodes[0].centre);
    // Mass as a filled box: its volume, and nothing off its middle.
    try std.testing.expectEqual(200 * 100 * 400, body.part.volume);
    try std.testing.expectEqual(0, body.part.first_moments[0]);

    // Written and read again, it comes back the same.
    var written: std.Io.Writer.Allocating = .init(arena);
    try model.write(&written.writer);
    const again = try shp.Model.parse(arena, written.written());
    try std.testing.expectEqual(2, again.parts.len);
    try std.testing.expectEqual(12, again.parts[1].meshes[0].faces.len);
    try std.testing.expectEqual(2, again.parts[1].point_lists.len);

    // A hardpoint holds its missile at every tier; an untextured face names the material `none`,
    // so that the model checks out; and the cloak's meshes where asked for.
    const plain = try build(arena, try obj.parse(arena, "v 0 0 0\nv 1 0 0\nv 0 1 1\no Hull\nf 1 2 3\no missile:4\nf 1 2 3\n"), .{ .cloak = true });
    const hardpoint = plain.parts[0].attachments[0];
    for (0..5) |tier| try std.testing.expectEqual(4, hardpoint.idFor(@intCast(tier)));
    try std.testing.expectEqualStrings("none", plain.parts[0].meshes[0].materials[plain.parts[0].meshes[0].faces[0].material].name());
    try std.testing.expect(plain.header.flags.cloak and !model.header.flags.cloak);

    // A marker, as a glTF file's node without a mesh makes one, becomes a point or an attachment,
    // and one with another name nothing.
    var marked = try obj.parse(arena, "v 0 0 0\nv 1 0 0\nv 0 1 1\no Hull\nf 1 2 3\n");
    const marker_triangles = marked.objects[0].triangles;
    var objects = [_]obj.Object{
        marked.objects[0],
        .{ .name = "jump_trail", .triangles = marker_triangles, .marker = true },
        .{ .name = "empty", .triangles = marker_triangles, .marker = true },
    };
    marked.objects = &objects;
    const from_markers = try build(arena, marked, .{});
    try std.testing.expectEqual(1, from_markers.parts[0].pointList(.jump_trails).?.points.len);
    try std.testing.expectEqual(1, from_markers.parts[0].meshes[0].faces.len);

    // No body, and an attachment's number that isn't one.
    try std.testing.expectError(error.NoBody, build(arena, try obj.parse(arena, "v 0 0 0\nv 1 0 0\nv 0 1 0\no cockpit\nf 1 2 3\n"), .{}));
    try std.testing.expectError(error.BadAttachment, build(arena, try obj.parse(arena, "v 0 0 0\nv 1 0 0\nv 0 1 0\no missile:x\nf 1 2 3\n"), .{}));
}
