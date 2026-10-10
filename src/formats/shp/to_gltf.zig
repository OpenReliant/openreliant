//! A model (`shp.Model`) written as glTF 2.0 ([the specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)),
//! as `sltool shp gltf` writes it, so that a modelling tool such as Blender can open a model of
//! the game's to start a mod's from ([#697](https://github.com/OpenReliant/openreliant/issues/697)).
//!
//! - Each part is a node, named as the part is, with one level of detail as its mesh, under the node
//!   of the part it hangs from, as the engine hangs it (`objects.Model.place`). A part's mesh isn't
//!   turned by its orientation, which only sets the axes its animation turns it about, so the
//!   nodes are only moved. A part's class and what it takes as a component are in its node's
//!   `extras`.
//! - Each attachment is an empty node under its part's, named as `sltool shp from-gltf` reads it:
//!   `gun_muzzle:<gun type>`, `missile:<missile>`, `engine_glow:<glow>`, `light:<colour>`,
//!   `eject_point`, `launch_point` and `dock_point`; the kinds `from-gltf` doesn't make are named
//!   `gun:<model>`, `pod:<model>` and `case_ejector`. Each point of a part's jump trails and jump
//!   lights is an empty node named `jump_trail` or `jump_light`.
//! - Each of the model's materials is a glTF material of the same name, whose base colour is the
//!   picture `<material>.png` beside the file, as `sltool tcache extract` writes it. A material
//!   whose faces are drawn from both sides is double-sided.
//! - The model's frame, Y down, is turned to glTF's, Y up, as `sltool shp obj` turns it
//!   (`Vec3.toYUp`). Wire faces and caps are left out, as `obj` leaves them out.
//!
//! The geometry goes in a binary file of its own beside the JSON (`Written.bin`), its corners each
//! a vertex of their own, since a corner's texture coordinates are the face's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../shp.zig");
const Vec3 = shp.Vec3;
const gltf = @import("../gltf.zig");
const math = @import("../../engine/surrender/math.zig");

/// What a model is written as: the glTF file's JSON, its buffer's bytes, which the JSON names as
/// the file `bin_name`, and the names of the materials whose pictures it names, `<name>.png`, all
/// but the one for faces without a material.
pub const Written = struct {
    json: []const u8,
    bin: []const u8,
    materials: []const []const u8,
};

/// `model` as glTF, its parts' level of detail `lod` (each part's coarsest where it has fewer),
/// its buffer named `bin_name`.
pub fn write(arena: Allocator, model: shp.Model, lod: usize, bin_name: []const u8) Allocator.Error!Written {
    const parents = try arena.alloc(?usize, model.parts.len);
    for (parents, model.parts) |*parent, data| parent.* = if (data.part.parentIndex()) |index| index else null;
    var made: Making = .{ .model = model, .parents = parents, .gltf = .init(arena) };
    const nodes = &made.gltf.nodes;
    // The parts' nodes come first, in the parts' order, so that a part finds its parent's.
    try nodes.appendNTimes(arena, undefined, model.parts.len);
    const children = try arena.alloc(std.ArrayList(u32), model.parts.len);
    @memset(children, .empty);
    for (0..model.parts.len) |at| {
        // Made first, since making it adds nodes, which can move the list.
        const placed = try made.part(at, lod, &children[at]);
        nodes.items[at] = placed;
        if (gltf.write.treeParent(parents, at)) |parent| try children[parent].append(arena, @intCast(at)) else try made.gltf.roots.append(arena, @intCast(at));
    }
    for (nodes.items[0..model.parts.len], children) |*node, listed| {
        if (listed.items.len > 0) node.children = listed.items;
    }
    const written = try made.gltf.finish("sltool shp gltf", bin_name);
    var names: std.ArrayList([]const u8) = .empty;
    for (made.gltf.materials.items) |material| {
        if (!std.mem.eql(u8, material.name, untextured)) try names.append(arena, material.name);
    }
    return .{ .json = written.json, .bin = written.bin, .materials = names.items };
}

/// What a part's node holds of the part besides its place and its mesh.
const PartExtras = struct {
    class: []const u8,
    component: bool,
    targetable: bool,
    component_armor: i32,
};

const Node = gltf.write.Node(PartExtras);

const Making = struct {
    model: shp.Model,
    /// Each part's parent, by its index.
    parents: []const ?usize,
    gltf: gltf.write.Builder(PartExtras),

    /// The node of the model's part `index`, at its level `lod`, with its attachments' and its
    /// points' nodes made and listed in `children`.
    fn part(made: *Making, index: usize, lod: usize, children: *std.ArrayList(u32)) Allocator.Error!Node {
        const arena = made.gltf.arena;
        const data = &made.model.parts[index];
        for (data.attachments) |attachment| {
            try children.append(arena, try made.gltf.node(.{
                .name = try attachmentName(arena, attachment),
                .translation = vector(attachment.position.toYUp()),
                .rotation = rotation(attachment.orientation),
            }));
        }
        for (data.point_lists) |list| {
            const name = pointName(list.kind) orelse continue;
            for (list.points) |point| try children.append(arena, try made.gltf.node(.{ .name = name, .translation = vector(point.position.toYUp()) }));
        }
        const flags = data.part.flags;
        const from = if (gltf.write.treeParent(made.parents, index)) |parent| made.model.parts[parent].part.position else Vec3.zero;
        return .{
            .name = data.part.name(),
            .translation = vector(data.part.position.sub(from).toYUp()),
            .mesh = if (data.meshes.len > 0) try made.mesh(data, data.meshes[@min(lod, data.meshes.len - 1)]) else null,
            .extras = .{
                .class = try arena.print("{f}", .{data.part.class}),
                .component = flags.component,
                .targetable = flags.targetable,
                .component_armor = data.part.component_armor,
            },
        };
    }

    /// The mesh of `level`, a level of `data`'s part, a primitive for each material its faces
    /// take; null for a level without faces to draw.
    fn mesh(made: *Making, data: *const shp.PartData, level: shp.Mesh) Allocator.Error!?u32 {
        const arena = made.gltf.arena;
        var primitives: std.ArrayList(gltf.write.Primitive) = .empty;
        var seen: std.ArrayList(u32) = .empty;
        for (level.faces) |face| {
            if (!drawn(face) or std.mem.findScalar(u32, seen.items, face.material) != null) continue;
            try seen.append(arena, face.material);
            const name = if (face.material < level.materials.len) level.materials[face.material].name() else "";
            try primitives.append(arena, try made.primitive(level, face.material, try made.material(name)));
        }
        if (primitives.items.len == 0) return null;
        return try made.gltf.mesh(.{ .name = data.part.name(), .primitives = primitives.items });
    }

    /// The faces of `level` that take its material `taken`, as a primitive drawn with the glTF
    /// material `material_index`.
    fn primitive(made: *Making, level: shp.Mesh, taken: u32, material_index: u32) Allocator.Error!gltf.write.Primitive {
        const arena = made.gltf.arena;
        var positions: std.ArrayList([3]f32) = .empty;
        var normals: std.ArrayList([3]f32) = .empty;
        var uvs: std.ArrayList([2]f32) = .empty;
        for (level.faces) |face| {
            if (!drawn(face) or face.material != taken) continue;
            // Odd strip members list their last two corners the other way round (`sltool shp obj`).
            const corners: [3]usize = if (face.polygon == .strip_odd) .{ 0, 2, 1 } else .{ 0, 1, 2 };
            var places: [3]Vec3 = undefined;
            for (&places, corners) |*place, corner| place.* = level.vertices[face.vertices[corner]].position;
            for (corners, places) |corner, place| {
                const vertex = level.vertices[face.vertices[corner]];
                try positions.append(arena, vector(place.toYUp()));
                try normals.append(arena, vector(unitNormal(vertex.normal, places).toYUp()));
                try uvs.append(arena, .{ face.u[corner], face.v[corner] });
            }
        }
        const count = positions.items.len;
        const lo, const hi = gltf.write.bounds(positions.items);
        return .{
            .attributes = .{
                .POSITION = try made.gltf.accessor(std.mem.sliceAsBytes(positions.items), .vertices, .{ .count = count, .type = "VEC3", .min = lo, .max = hi }),
                .NORMAL = try made.gltf.accessor(std.mem.sliceAsBytes(normals.items), .vertices, .{ .count = count, .type = "VEC3" }),
                .TEXCOORD_0 = try made.gltf.accessor(std.mem.sliceAsBytes(uvs.items), .vertices, .{ .count = count, .type = "VEC2" }),
            },
            .material = material_index,
        };
    }

    /// The material named `name`, with its picture, made where it is the first face of its name.
    /// It is double-sided where any of the model's faces that take a material of that name is.
    fn material(made: *Making, name: []const u8) Allocator.Error!u32 {
        const shown = if (name.len > 0) name else untextured;
        for (made.gltf.materials.items, 0..) |held, at| {
            if (std.mem.eql(u8, held.name, shown)) return @intCast(at);
        }
        const picture = try made.gltf.texture(try made.gltf.arena.print("{s}.png", .{shown}));
        return made.gltf.material(.{
            .name = shown,
            .pbrMetallicRoughness = .{ .baseColorTexture = picture },
            .doubleSided = made.twoSided(name),
        });
    }

    /// Whether any face of the model's that takes a material named `name` is drawn from both
    /// sides.
    fn twoSided(made: *const Making, name: []const u8) bool {
        for (made.model.parts) |data| for (data.meshes) |level| for (level.faces) |face| {
            if (!face.flags.two_sided or face.material >= level.materials.len) continue;
            if (std.mem.eql(u8, level.materials[face.material].name(), name)) return true;
        };
        return false;
    }
};

/// The name of the material of a face without one.
const untextured = "none";

/// Whether a face is drawn as a surface: wire faces are lines, and caps are hidden on an intact
/// object.
fn drawn(face: shp.Face) bool {
    return face.shading.mode != .wire and !face.flags.cap;
}

fn vector(v: Vec3) [3]f32 {
    return .{ v.x, v.y, v.z };
}

/// `normal`, in the model's frame, made a unit long, as glTF holds normals; where it has no
/// length, as some of the game's models leave it, the normal of the triangle with corners
/// `corners`, or straight up for a triangle with no area.
fn unitNormal(normal: Vec3, corners: [3]Vec3) Vec3 {
    if (gltf.write.unit(normal.vector())) |given| return .of(given);
    if (gltf.write.unit(shp.front(corners))) |across| return .of(across);
    return straight_up;
}

/// Straight up in the model's frame, whose Y points down.
const straight_up: Vec3 = .{ .x = 0, .y = -1, .z = 0 };

/// The node name of `attachment`, as `from-gltf` reads it (`from_obj.Role`).
fn attachmentName(arena: Allocator, attachment: shp.Attachment) Allocator.Error![]const u8 {
    return switch (attachment.kind) {
        .gun_muzzle => arena.print("gun_muzzle:{d}", .{attachment.gun_type}),
        inline .missile, .engine_glow, .light, .gun, .pod => |kind| arena.print(@tagName(kind) ++ ":{d}", .{attachment.id}),
        inline .eject_point, .launch_point, .dock_point, .case_ejector => |kind| @tagName(kind),
        _ => arena.print("attachment:{d}", .{@backingInt(attachment.kind)}),
    };
}

/// The node name of a point of a list of `kind`, for the lists `from-gltf` reads; null for the
/// others.
fn pointName(kind: shp.PointList.Kind) ?[]const u8 {
    return switch (kind) {
        .jump_trails => "jump_trail",
        .jump_lights => "jump_light",
        else => null,
    };
}

/// The rotation of `orientation`, a row-major 3x3 in the model's frame, in glTF's frame as a unit
/// quaternion (x, y, z, w); null for none, and for a matrix that isn't a rotation, as a few of the
/// game's attachments hold. Turning the frame by a half turn about Z negates the matrix's entries
/// that mix Z with X or Y.
fn rotation(orientation: [9]f32) ?[4]f32 {
    var m = orientation;
    for ([_]usize{ 2, 5, 6, 7 }) |at| m[at] = -m[at];
    const identity = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    if (std.mem.eql(f32, &m, &identity) or !isRotation(m)) return null;
    const trace = m[0] + m[4] + m[8];
    const q: [4]f32 = if (trace > 0) q: {
        const s = @sqrt(trace + 1) * 2;
        break :q .{ (m[7] - m[5]) / s, (m[2] - m[6]) / s, (m[3] - m[1]) / s, s / 4 };
    } else if (m[0] > m[4] and m[0] > m[8]) q: {
        const s = @sqrt(1 + m[0] - m[4] - m[8]) * 2;
        break :q .{ s / 4, (m[1] + m[3]) / s, (m[2] + m[6]) / s, (m[7] - m[5]) / s };
    } else if (m[4] > m[8]) q: {
        const s = @sqrt(1 + m[4] - m[0] - m[8]) * 2;
        break :q .{ (m[1] + m[3]) / s, s / 4, (m[5] + m[7]) / s, (m[2] - m[6]) / s };
    } else q: {
        const s = @sqrt(1 + m[8] - m[0] - m[4]) * 2;
        break :q .{ (m[2] + m[6]) / s, (m[5] + m[7]) / s, s / 4, (m[3] - m[1]) / s };
    };
    const turn: @Vector(4, f32) = q;
    return turn / @as(@Vector(4, f32), @splat(@sqrt(@reduce(.Add, turn * turn))));
}

/// Whether the row-major 3x3 `m` turns without stretching or mirroring: its rows each a unit long
/// and square to one another, and its determinant 1, to within `rotation_slack`.
fn isRotation(m: math.Matrix) bool {
    for (math.product(m, math.transpose(m)), math.identity) |got, expected| {
        if (@abs(got - expected) > rotation_slack) return false;
    }
    return @abs(math.determinant(m) - 1) <= rotation_slack;
}

/// How far a matrix's rows may stray from a rotation's, which the game's rounded matrices do.
const rotation_slack = 1e-3;

test rotation {
    // None for the identity.
    try std.testing.expectEqual(null, rotation(.{ 1, 0, 0, 0, 1, 0, 0, 0, 1 }));
    // A quarter turn about X in the model's frame is one the other way about glTF's X, since X
    // turns round with the frame.
    const turned = rotation(.{ 1, 0, 0, 0, 0, -1, 0, 1, 0 }).?;
    const half = @sqrt(0.5);
    for ([4]f32{ -half, 0, 0, half }, turned) |expected, got| try std.testing.expectApproxEqAbs(expected, got, 1e-6);
    // None for a matrix that stretches, or mirrors.
    try std.testing.expectEqual(null, rotation(.{ 2, 0, 0, 0, 1, 0, 0, 0, 1 }));
    try std.testing.expectEqual(null, rotation(.{ -1, 0, 0, 0, 1, 0, 0, 0, 1 }));
}

test unitNormal {
    const flat = [3]Vec3{ .zero, .{ .x = 1, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 1 } };
    // A normal is made a unit long; one without length is the triangle's.
    try std.testing.expectEqual(Vec3{ .x = 0, .y = 0, .z = 1 }, unitNormal(.{ .x = 0, .y = 0, .z = 3 }, flat));
    try std.testing.expectEqual(Vec3{ .x = 0, .y = -1, .z = 0 }, unitNormal(.zero, flat));
    // A triangle without area points up.
    try std.testing.expectEqual(straight_up, unitNormal(.zero, .{ .zero, .{ .x = 1, .y = 0, .z = 0 }, .{ .x = 2, .y = 0, .z = 0 } }));
}

test write {
    const obj = @import("../obj.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A model of a body of two triangles, with a gun muzzle and an engine glow, and a cockpit of
    // one, with an eject point.
    const source =
        \\v -100 -50 -200
        \\v 100 -50 -200
        \\v 0 50 200
        \\v 0 -50 200
        \\vt 0 0
        \\vt 1 0
        \\vt 0 1
        \\o hull
        \\usemtl yank_1
        \\f 1/1 2/2 3/3
        \\f 1/1 3/3 4/1
        \\o gun_muzzle:3
        \\f 1 2 3
        \\o engine_glow:7
        \\f 2 3 4
        \\o cockpit
        \\f 2/2 3/3 4/1
        \\o eject_point
        \\f 1 2 4
        \\
    ;
    const model = try shp.from_obj.build(arena, try obj.parse(arena, source), .{});
    const written = try write(arena, model, 0, "ship.bin");

    // Read back, it holds the same triangles and the attachments by name.
    const document = try gltf.write.testing.read(arena, written.json, written.bin, "ship.bin");
    const back = try gltf.triangles(arena, document, 1, &.{"yank_1"});
    // The cockpit's triangle and its eject point's marker, then the body's two triangles, and a
    // marker for each of its attachments and for the jump trail the builder put at the engine glow.
    const names = [_][]const u8{ "Cockpit", "eject_point", "Body", "gun_muzzle:3", "engine_glow:7", "jump_trail" };
    try std.testing.expectEqual(names.len, back.objects.len);
    for (names, back.objects) |name, object| try std.testing.expectEqualStrings(name, object.name);
    try std.testing.expectEqual(2, back.objects[2].triangles.len);
    // Each corner keeps its normal, the body's too, after the eject point's marker.
    try std.testing.expectEqual(back.positions.len, back.normals.len);
    try std.testing.expect(std.mem.find(u8, written.json, "\"yank_1.png\"") != null);
    try std.testing.expectEqualStrings("yank_1", written.materials[0]);
    // Built again, the model has its body and its attachments back.
    const again = try shp.from_obj.build(arena, back, .{});
    try std.testing.expectEqual(model.parts.len, again.parts.len);
    for (model.parts, again.parts) |part, part_again| {
        try std.testing.expectEqualStrings(part.part.name(), part_again.part.name());
        try std.testing.expectEqual(part.meshes[0].faces.len, part_again.meshes[0].faces.len);
        try std.testing.expectEqual(part.attachments.len, part_again.attachments.len);
    }
}
