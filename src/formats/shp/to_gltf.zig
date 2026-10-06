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
const builtin = @import("builtin");

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
    var made: Making = .{ .arena = arena, .model = model };
    // The parts' nodes come first, in the parts' order, so that a part finds its parent's.
    try made.nodes.appendNTimes(arena, undefined, model.parts.len);
    const children = try arena.alloc(std.ArrayList(u32), model.parts.len);
    @memset(children, .empty);
    for (0..model.parts.len) |at| {
        // Made first, since making it adds nodes, which can move the list.
        const placed = try made.part(at, lod, &children[at]);
        made.nodes.items[at] = placed;
        if (hangsFrom(model, at)) |parent| try children[parent].append(arena, @intCast(at)) else try made.roots.append(arena, @intCast(at));
    }
    for (made.nodes.items[0..model.parts.len], children) |*node, listed| {
        if (listed.items.len > 0) node.children = listed.items;
    }
    const document: Document = .{
        .asset = .{ .version = "2.0", .generator = "sltool shp gltf" },
        .scene = 0,
        .scenes = &.{.{ .nodes = made.roots.items }},
        .nodes = made.nodes.items,
        .meshes = made.meshes.items,
        .materials = made.materials.items,
        .textures = made.textures.items,
        .images = made.images.items,
        .accessors = made.accessors.items,
        .bufferViews = made.views.items,
        .buffers = &.{.{ .uri = bin_name, .byteLength = made.bin.items.len }},
    };
    var json: std.Io.Writer.Allocating = .init(arena);
    json.writer.print("{f}", .{std.json.fmt(document, .{ .emit_null_optional_fields = false, .whitespace = .indent_1 })}) catch return error.OutOfMemory;
    var names: std.ArrayList([]const u8) = .empty;
    for (made.materials.items) |material| {
        if (!std.mem.eql(u8, material.name, untextured)) try names.append(arena, material.name);
    }
    return .{ .json = json.written(), .bin = made.bin.items, .materials = names.items };
}

/// The glTF file's JSON, its members named as the specification names them.
const Document = struct {
    asset: struct { version: []const u8, generator: []const u8 },
    scene: u32,
    scenes: []const struct { nodes: []const u32 },
    nodes: []const Node,
    meshes: []const Mesh,
    materials: []const Material,
    textures: []const struct { source: u32 },
    images: []const struct { uri: []const u8 },
    accessors: []const Accessor,
    bufferViews: []const BufferView,
    buffers: []const struct { uri: []const u8, byteLength: usize },
};

const Node = struct {
    name: []const u8,
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    mesh: ?u32 = null,
    children: ?[]const u32 = null,
    extras: ?PartExtras = null,
};

/// What a part's node holds of the part besides its place and its mesh.
const PartExtras = struct {
    class: []const u8,
    component: bool,
    targetable: bool,
    component_armor: i32,
};

const Mesh = struct {
    name: []const u8,
    primitives: []const Primitive,
};

const Primitive = struct {
    attributes: struct { POSITION: u32, NORMAL: u32, TEXCOORD_0: u32 },
    material: u32,
};

const Material = struct {
    name: []const u8,
    pbrMetallicRoughness: struct {
        baseColorTexture: struct { index: u32 },
        metallicFactor: f32 = 0,
        roughnessFactor: f32 = 1,
    },
    doubleSided: bool = false,
};

const Accessor = struct {
    bufferView: u32,
    componentType: u32 = @backingInt(gltf.Component.float),
    count: usize,
    type: []const u8,
    min: ?[3]f32 = null,
    max: ?[3]f32 = null,
};

const BufferView = struct {
    buffer: u32 = 0,
    byteOffset: usize,
    byteLength: usize,
    target: u32 = array_buffer,
};

comptime {
    std.debug.assert(builtin.cpu.arch.endian() == .little);
}

/// glTF's number for a buffer of vertex attributes.
const array_buffer = 34962;

const Making = struct {
    arena: Allocator,
    model: shp.Model,
    nodes: std.ArrayList(Node) = .empty,
    roots: std.ArrayList(u32) = .empty,
    meshes: std.ArrayList(Mesh) = .empty,
    materials: std.ArrayList(Material) = .empty,
    textures: std.ArrayList(@typeInfo(@FieldType(Document, "textures")).pointer.child) = .empty,
    images: std.ArrayList(@typeInfo(@FieldType(Document, "images")).pointer.child) = .empty,
    accessors: std.ArrayList(Accessor) = .empty,
    views: std.ArrayList(BufferView) = .empty,
    bin: std.ArrayList(u8) = .empty,

    /// The node of the model's part `index`, at its level `lod`, with its attachments' and its
    /// points' nodes made and listed in `children`.
    fn part(made: *Making, index: usize, lod: usize, children: *std.ArrayList(u32)) Allocator.Error!Node {
        const arena = made.arena;
        const data = &made.model.parts[index];
        for (data.attachments) |attachment| {
            try children.append(arena, try made.node(.{
                .name = try attachmentName(arena, attachment),
                .translation = vector(attachment.position.toYUp()),
                .rotation = rotation(attachment.orientation),
            }));
        }
        for (data.point_lists) |list| {
            const name = pointName(list.kind) orelse continue;
            for (list.points) |point| try children.append(arena, try made.node(.{ .name = name, .translation = vector(point.position.toYUp()) }));
        }
        const flags = data.part.flags;
        const from = if (hangsFrom(made.model, index)) |parent| made.model.parts[parent].part.position else Vec3.zero;
        return .{
            .name = data.part.name(),
            .translation = vector(data.part.position.sub(from).toYUp()),
            .mesh = if (data.meshes.len > 0) try made.mesh(data, data.meshes[@min(lod, data.meshes.len - 1)]) else null,
            .extras = .{
                .class = try std.fmt.allocPrint(arena, "{f}", .{data.part.class}),
                .component = flags.component,
                .targetable = flags.targetable,
                .component_armor = data.part.component_armor,
            },
        };
    }

    fn node(made: *Making, value: Node) Allocator.Error!u32 {
        try made.nodes.append(made.arena, value);
        return @intCast(made.nodes.items.len - 1);
    }

    /// The mesh of `level`, a level of `data`'s part, a primitive for each material its faces
    /// take; null for a level without faces to draw.
    fn mesh(made: *Making, data: *const shp.PartData, level: shp.Mesh) Allocator.Error!?u32 {
        const arena = made.arena;
        var primitives: std.ArrayList(Primitive) = .empty;
        var seen: std.ArrayList(u32) = .empty;
        for (level.faces) |face| {
            if (!drawn(face) or std.mem.indexOfScalar(u32, seen.items, face.material) != null) continue;
            try seen.append(arena, face.material);
            const name = if (face.material < level.materials.len) level.materials[face.material].name() else "";
            try primitives.append(arena, try made.primitive(level, face.material, try made.material(name)));
        }
        if (primitives.items.len == 0) return null;
        try made.meshes.append(arena, .{ .name = data.part.name(), .primitives = primitives.items });
        return @intCast(made.meshes.items.len - 1);
    }

    /// The faces of `level` that take its material `taken`, as a primitive drawn with the glTF
    /// material `material_index`.
    fn primitive(made: *Making, level: shp.Mesh, taken: u32, material_index: u32) Allocator.Error!Primitive {
        var positions: std.ArrayList([3]f32) = .empty;
        var normals: std.ArrayList([3]f32) = .empty;
        var uvs: std.ArrayList([2]f32) = .empty;
        var lo: [3]f32 = @splat(std.math.inf(f32));
        var hi: [3]f32 = @splat(-std.math.inf(f32));
        for (level.faces) |face| {
            if (!drawn(face) or face.material != taken) continue;
            // Odd strip members list their last two corners the other way round (`sltool shp obj`).
            const corners: [3]usize = if (face.polygon == .strip_odd) .{ 0, 2, 1 } else .{ 0, 1, 2 };
            var places: [3]Vec3 = undefined;
            for (&places, corners) |*place, corner| place.* = level.vertices[face.vertices[corner]].position;
            for (corners, places) |corner, place| {
                const at = vector(place.toYUp());
                const vertex = level.vertices[face.vertices[corner]];
                for (&lo, &hi, at) |*low, *high, value| {
                    low.* = @min(low.*, value);
                    high.* = @max(high.*, value);
                }
                try positions.append(made.arena, at);
                try normals.append(made.arena, vector(unitNormal(vertex.normal, places).toYUp()));
                try uvs.append(made.arena, .{ face.u[corner], face.v[corner] });
            }
        }
        const count = positions.items.len;
        return .{
            .attributes = .{
                .POSITION = try made.accessor(std.mem.sliceAsBytes(positions.items), .{ .bufferView = 0, .count = count, .type = "VEC3", .min = lo, .max = hi }),
                .NORMAL = try made.accessor(std.mem.sliceAsBytes(normals.items), .{ .bufferView = 0, .count = count, .type = "VEC3" }),
                .TEXCOORD_0 = try made.accessor(std.mem.sliceAsBytes(uvs.items), .{ .bufferView = 0, .count = count, .type = "VEC2" }),
            },
            .material = material_index,
        };
    }

    /// An accessor of `bytes`, put in the buffer in a view of their own, as `described`. glTF's
    /// buffers are little-endian, as the floats are in memory on the machines OpenReliant runs on.
    fn accessor(made: *Making, bytes: []const u8, described: Accessor) Allocator.Error!u32 {
        try made.views.append(made.arena, .{ .byteOffset = made.bin.items.len, .byteLength = bytes.len });
        try made.bin.appendSlice(made.arena, bytes);
        var listed = described;
        listed.bufferView = @intCast(made.views.items.len - 1);
        try made.accessors.append(made.arena, listed);
        return @intCast(made.accessors.items.len - 1);
    }

    /// The material named `name`, with its picture, made where it is the first face of its name.
    /// It is double-sided where any of the model's faces that take a material of that name is.
    fn material(made: *Making, name: []const u8) Allocator.Error!u32 {
        const shown = if (name.len > 0) name else untextured;
        for (made.materials.items, 0..) |held, at| {
            if (std.mem.eql(u8, held.name, shown)) return @intCast(at);
        }
        try made.images.append(made.arena, .{ .uri = try std.fmt.allocPrint(made.arena, "{s}.png", .{shown}) });
        try made.textures.append(made.arena, .{ .source = @intCast(made.images.items.len - 1) });
        try made.materials.append(made.arena, .{
            .name = shown,
            .pbrMetallicRoughness = .{ .baseColorTexture = .{ .index = @intCast(made.textures.items.len - 1) } },
            .doubleSided = made.twoSided(name),
        });
        return @intCast(made.materials.items.len - 1);
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

/// The part that part `index` of `model` hangs from, where it hangs from one: a parent that is one
/// of the model's other parts, and isn't hung from it in turn, which the glTF file's tree can't hold.
fn hangsFrom(model: shp.Model, index: usize) ?usize {
    const parent = model.parts[index].part.parentIndex() orelse return null;
    var up: ?u32 = parent;
    for (0..model.parts.len) |_| {
        const at = up orelse return parent;
        if (at >= model.parts.len or at == index) return null;
        up = model.parts[at].part.parentIndex();
    }
    return null;
}

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
    const given = normal.vector();
    if (math.length(given) > least_length) return .of(math.normalize(given));
    const across = shp.front(corners);
    if (math.length(across) > least_length) return .of(math.normalize(across));
    return straight_up;
}

/// Straight up in the model's frame, whose Y points down.
const straight_up: Vec3 = .{ .x = 0, .y = -1, .z = 0 };

/// The shortest normal, or cross product, taken to have a direction.
const least_length = 1e-6;

/// The node name of `attachment`, as `from-gltf` reads it (`from_obj.Role`).
fn attachmentName(arena: Allocator, attachment: shp.Attachment) Allocator.Error![]const u8 {
    return switch (attachment.kind) {
        .gun_muzzle => std.fmt.allocPrint(arena, "gun_muzzle:{d}", .{attachment.gun_type}),
        inline .missile, .engine_glow, .light, .gun, .pod => |kind| std.fmt.allocPrint(arena, @tagName(kind) ++ ":{d}", .{attachment.id}),
        inline .eject_point, .launch_point, .dock_point, .case_ejector => |kind| @tagName(kind),
        _ => std.fmt.allocPrint(arena, "attachment:{d}", .{@backingInt(attachment.kind)}),
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
    const Files = struct {
        bin: []const u8,
        fn read(context: *const anyopaque, _: Allocator, name: []const u8) Allocator.Error!?[]u8 {
            const files: *const @This() = @ptrCast(@alignCast(context));
            return if (std.mem.eql(u8, name, "ship.bin")) @constCast(files.bin) else null;
        }
    };
    const files: Files = .{ .bin = written.bin };
    const document = try gltf.read(arena, written.json, .{ .context = &files, .readFn = Files.read });
    const back = try gltf.triangles(arena, document, 1, &.{"yank_1"});
    // The cockpit's triangle and its eject point's marker, then the body's two triangles, and a
    // marker for each of its attachments and for the jump trail the builder put at the engine glow.
    const names = [_][]const u8{ "Cockpit", "eject_point", "Body", "gun_muzzle:3", "engine_glow:7", "jump_trail" };
    try std.testing.expectEqual(names.len, back.objects.len);
    for (names, back.objects) |name, object| try std.testing.expectEqualStrings(name, object.name);
    try std.testing.expectEqual(2, back.objects[2].triangles.len);
    // Each corner keeps its normal, the body's too, after the eject point's marker.
    try std.testing.expectEqual(back.positions.len, back.normals.len);
    try std.testing.expect(std.mem.indexOf(u8, written.json, "\"yank_1.png\"") != null);
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
