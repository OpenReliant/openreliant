//! A Battlestar Galactica model written as glTF 2.0, as `sltool bsg gltf` writes it, so that a
//! modelling tool such as Blender can open it, and `sltool shp from-gltf` can build a model of it
//! for a mod. It reads the model's files from an archive (`Files`):
//!
//! - The model's node is named as the model is, such as `shv2vi00`. Its `extras` hold the Maya scene
//!   it was exported from and every attribute of its definition (`level.zig`).
//! - Each part at the chosen level of detail is a node under its parent's, named as the part is,
//!   with its mesh (`mesh.zig`) and its place (`model.zig`), and its pivot in its `extras`.
//! - Each submesh is a primitive, with its texture coordinates, and its vertices' colours as the
//!   attribute `_COLOR`, which a reader keeps without drawing. Its material is named after its
//!   texture, whose picture is the PNG file `<texture>.png` beside the glTF file (`Picture`).
//! - The guns, engines, vapour trails, cockpit and hardpoints are empty nodes under the model's,
//!   named as `from-gltf` reads them where it has them: `gun_muzzle`, `engine_glow:1`, `missile`
//!   and `launch_point`. The others are `vapour_trail`, `cockpit_view`, and the hardpoint's kind,
//!   such as `turret`. A hardpoint's `extras` hold its attributes, and a model mounted on it is
//!   written under it in the same way, up to `max_mounts` deep.
//!
//! The game's frame is Direct3D's, left-handed, with X to the right; glTF's is right-handed, with X
//! to the left. Every X is negated, and every triangle's corners turned the other way round, so
//! that the model keeps its handedness and its triangles face out.
//!
//! Not written: the collision data, the environment maps, and an animated texture's frames past the
//! first ([#1037](https://github.com/OpenReliant/openreliant/issues/1037)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const gltf = @import("../../gltf.zig");
const write_gltf = gltf.write;
const math = @import("../../../engine/surrender/math.zig");
const level_file = @import("level.zig");
const mesh_file = @import("mesh.zig");
const model_file = @import("model.zig");
const text = @import("text.zig");
const texture_file = @import("texture.zig");

/// Reads the archive's member `name`, such as `models/shv2vi00/shv2vi00.mdl`. Returns null for a
/// name the archive doesn't hold.
pub const Files = struct {
    context: *const anyopaque,
    readFn: *const fn (context: *const anyopaque, arena: Allocator, name: []const u8) ReadError!?[]const u8,

    pub fn read(files: Files, arena: Allocator, name: []const u8) ReadError!?[]const u8 {
        return files.readFn(files.context, arena, name);
    }
};

/// What reading a member can fail with, besides its not being there.
pub const ReadError = error{BadMember} || Allocator.Error;

pub const Options = struct {
    /// The level of detail, from 1, the finest, to `model.coarsest_level`. A model without parts at
    /// that level is written at the nearest level it has.
    level: u8 = 1,
};

/// A texture a material names, and the picture to write of it.
pub const Picture = struct {
    /// The PNG file the glTF file names, such as `sh_v2_viper01.png`.
    file: []const u8,
    texture: texture_file.Texture,
};

pub const Written = struct {
    json: []const u8,
    bin: []const u8,
    pictures: []const Picture,
    /// The archive's names of the files the model names but the archive doesn't hold.
    missing: []const []const u8,
};

pub const Error = error{
    /// The archive holds no `.mdl` file of that name.
    MissingModel,
    NotAModel,
    NotALevel,
} || ReadError || text.Error || mesh_file.Error || texture_file.Error;

/// How deep models mount on models' hardpoints: a launch tube on the Galactica, its door on the
/// launch tube, and so on. A model mounted deeper is left out.
pub const max_mounts = 4;

/// The model `name`, such as `shv2vi00`, as glTF, its buffer named `bin_name`.
pub fn write(arena: Allocator, files: Files, name: []const u8, options: Options, bin_name: []const u8) Error!Written {
    var made: Making = .{ .gltf = .init(arena), .files = files, .level = options.level };
    try made.gltf.roots.append(arena, try made.objectNode(name, 0));
    const written = try made.gltf.finish("sltool bsg gltf", bin_name);
    return .{ .json = written.json, .bin = written.bin, .pictures = made.pictures.items, .missing = made.missing.items };
}

const Node = write_gltf.Node(json.Value);

const Making = struct {
    gltf: write_gltf.Builder(json.Value),
    files: Files,
    level: u8,
    /// The glTF materials made so far, by `materialKey`.
    materials: std.StringHashMapUnmanaged(u32) = .empty,
    /// The textures read so far, by their name in the archive: their glTF texture, or null for one
    /// the archive doesn't hold.
    textures: std.StringHashMapUnmanaged(?Texture) = .empty,
    pictures: std.ArrayList(Picture) = .empty,
    missing: std.ArrayList([]const u8) = .empty,

    const Texture = struct { ref: write_gltf.TextureRef, alpha: bool };

    fn arena(made: *Making) Allocator {
        return made.gltf.arena;
    }

    /// The node of the model `name`, its parts, points and hardpoints under it, `depth` mounts
    /// deep.
    fn objectNode(made: *Making, name: []const u8, depth: usize) Error!u32 {
        const allocator = made.arena();
        const lower = try std.ascii.allocLowerString(allocator, name);
        const model_path = try std.fmt.allocPrint(allocator, "models/{s}/{s}.mdl", .{ lower, lower });
        const model: model_file.Model = try .parse(allocator, try made.files.read(allocator, model_path) orelse return error.MissingModel);
        const level_path = try std.fmt.allocPrint(allocator, "levels/{s}.lvl", .{lower});
        const level: ?level_file.Level = if (try made.files.read(allocator, level_path)) |bytes| try .parse(allocator, bytes) else null;

        var children: std.ArrayList(u32) = .empty;
        try made.partNodes(model, lower, &children);
        if (level) |defined| {
            for (try defined.points(allocator)) |point| try children.append(allocator, try made.pointNode(point));
            for (try defined.hardpoints(allocator)) |hardpoint| try children.append(allocator, try made.hardpointNode(hardpoint, depth));
        }

        var extras: json.ObjectMap = .empty;
        if (model.scene) |scene| try extras.put(allocator, "scene", .{ .string = scene });
        if (level) |defined| try extras.put(allocator, "attributes", try attributesValue(allocator, defined.attributes));
        return made.gltf.node(.{ .name = name, .children = children.items, .extras = .{ .object = extras } });
    }

    /// The nodes of `model`'s parts at the chosen level, listed in `top` where a part hangs from no
    /// other, and under their parents' otherwise. `folder` is the model's folder's name.
    fn partNodes(made: *Making, model: model_file.Model, folder: []const u8, top: *std.ArrayList(u32)) Error!void {
        const allocator = made.arena();
        const chosen = try model.partsAt(allocator, made.level);
        const parents = try allocator.alloc(?usize, chosen.len);
        for (parents, chosen) |*parent, part| parent.* = parentOf(chosen, part);
        // The parts' nodes come first, in the parts' order, so that a part finds its parent's.
        const nodes = &made.gltf.nodes;
        const first = nodes.items.len;
        try nodes.appendNTimes(allocator, undefined, chosen.len);
        const children = try allocator.alloc(std.ArrayList(u32), chosen.len);
        @memset(children, .empty);
        for (chosen, 0..) |part, at| {
            // Made before it is stored, since the list of nodes moves as it grows.
            const placed = try made.partNode(part, folder);
            nodes.items[first + at] = placed;
            const index: u32 = @intCast(first + at);
            if (write_gltf.treeParent(parents, at)) |parent| try children[parent].append(allocator, index) else try top.append(allocator, index);
        }
        for (nodes.items[first..][0..chosen.len], children) |*node, listed| {
            if (listed.items.len > 0) node.children = listed.items;
        }
    }

    /// The node of `part`, a part of the model in the folder `folder`, without its children.
    fn partNode(made: *Making, part: model_file.Part, folder: []const u8) Error!Node {
        const allocator = made.arena();
        var extras: json.ObjectMap = .empty;
        if (part.pivot) |pivot| try extras.put(allocator, "pivot", try numbersValue(allocator, &mirror(pivot)));
        return .{
            .name = part.name,
            .matrix = mirrorMatrix(part.matrix),
            .mesh = if (part.mesh.len > 0) try made.partMesh(part.name, try part.meshPath(allocator, folder)) else null,
            .extras = if (extras.count() > 0) .{ .object = extras } else null,
        };
    }

    /// The node of a gun, an engine's glow, a vapour trail or the cockpit.
    fn pointNode(made: *Making, defined: level_file.Point) Error!u32 {
        const allocator = made.arena();
        var extras: json.ObjectMap = .empty;
        try extras.put(allocator, "attribute", .{ .string = defined.name });
        if (defined.size) |size| try extras.put(allocator, "size", .{ .float = size });
        return made.gltf.node(.{
            .name = switch (defined.kind) {
                .gun => "gun_muzzle",
                .jet => "engine_glow:" ++ std.fmt.comptimePrint("{d}", .{engine_glow}),
                .vapour_trail => "vapour_trail",
                .cockpit => "cockpit_view",
            },
            .translation = mirror(defined.position),
            // A glow's box, a cube two across scaled, is as wide and as high as the jet, and twice
            // as long: `from-gltf` takes half its length as how far the plume reaches.
            .scale = if (defined.size) |size| .{ size / 2, size / 2, size } else null,
            .extras = .{ .object = extras },
        });
    }

    /// The node of a hardpoint, with the model mounted on it, if any, under it.
    fn hardpointNode(made: *Making, defined: level_file.Hardpoint, depth: usize) Error!u32 {
        const allocator = made.arena();
        var children: std.ArrayList(u32) = .empty;
        if (defined.object) |mounted| mount: {
            if (depth >= max_mounts) break :mount;
            const node = made.objectNode(mounted, depth + 1) catch |err| switch (err) {
                error.MissingModel => {
                    try made.missing.append(allocator, try std.fmt.allocPrint(allocator, "models/{s}/", .{mounted}));
                    break :mount;
                },
                else => |e| return e,
            };
            try children.append(allocator, node);
        }
        var extras: json.ObjectMap = .empty;
        try extras.put(allocator, "hardpoint", .{ .string = defined.prefix });
        try extras.put(allocator, "attributes", try attributesValue(allocator, defined.attributes));
        return made.gltf.node(.{
            .name = try hardpointName(allocator, defined),
            .matrix = mirrorMatrix(defined.matrix),
            .children = if (children.items.len > 0) children.items else null,
            .extras = .{ .object = extras },
        });
    }

    /// The mesh `path` of the part `name`, a primitive for each submesh with triangles; null where
    /// the archive doesn't hold it or it has none.
    fn partMesh(made: *Making, name: []const u8, path: []const u8) Error!?u32 {
        const allocator = made.arena();
        const bytes = try made.files.read(allocator, path) orelse {
            try made.missing.append(allocator, path);
            return null;
        };
        const read: mesh_file.Mesh = try .parse(allocator, bytes);
        var primitives: std.ArrayList(write_gltf.Primitive) = .empty;
        for (read.submeshes) |submesh| {
            if (submesh.indices.len == 0) continue;
            try primitives.append(allocator, try made.submeshPrimitive(submesh));
        }
        if (primitives.items.len == 0) return null;
        return try made.gltf.mesh(.{ .name = name, .primitives = primitives.items });
    }

    fn submeshPrimitive(made: *Making, submesh: mesh_file.Submesh) Error!write_gltf.Primitive {
        const allocator = made.arena();
        const count = submesh.positions.len;
        const positions = try allocator.alloc([3]f32, count);
        for (positions, submesh.positions) |*to, from| to.* = mirror(from);
        // Each triangle's last two corners swap, to face out in glTF's frame.
        const indices = try allocator.alloc(u16, submesh.indices.len);
        for (0..indices.len / 3) |triangle| {
            const corners = submesh.indices[triangle * 3 ..][0..3];
            indices[triangle * 3 ..][0..3].* = .{ corners[0], corners[2], corners[1] };
        }
        const lo, const hi = write_gltf.bounds(positions);
        var attributes: write_gltf.Attributes = .{
            .POSITION = try made.gltf.accessor(std.mem.sliceAsBytes(positions), .vertices, .{ .count = count, .type = "VEC3", .min = lo, .max = hi }),
        };
        if (submesh.normals.len > 0) {
            const normals = try allocator.alloc([3]f32, count);
            for (normals, submesh.normals) |*to, from| to.* = write_gltf.unit(mirror(from)) orelse straight_up;
            attributes.NORMAL = try made.gltf.accessor(std.mem.sliceAsBytes(normals), .vertices, .{ .count = count, .type = "VEC3" });
        }
        const uv_slots = [_]*?u32{ &attributes.TEXCOORD_0, &attributes.TEXCOORD_1 };
        for (submesh.uvs, uv_slots) |uvs, slot| {
            if (uvs.len == 0) continue;
            slot.* = try made.gltf.accessor(std.mem.sliceAsBytes(uvs), .vertices, .{ .count = count, .type = "VEC2" });
        }
        if (submesh.colours.len > 0) {
            attributes._COLOR = try made.gltf.accessor(std.mem.sliceAsBytes(submesh.colours), .vertices, .{ .count = count, .type = "VEC4" });
        }
        return .{
            .attributes = attributes,
            .indices = try made.gltf.accessor(std.mem.sliceAsBytes(indices), .indices, .{ .componentType = @backingInt(gltf.Component.unsigned_short), .count = indices.len, .type = "SCALAR" }),
            .material = try made.materialOf(submesh.material),
        };
    }

    /// The glTF material of `material`, made the first time a submesh takes it.
    fn materialOf(made: *Making, material: mesh_file.Material) Error!u32 {
        const allocator = made.arena();
        const key = try materialKey(allocator, material);
        if (made.materials.get(key)) |made_already| return made_already;

        const record = material.record;
        const colour = if (material.colour()) |name| try made.textureOf(name) else null;
        var value: write_gltf.Material = .{ .name = try materialName(allocator, material) };
        if (colour) |found| {
            value.pbrMetallicRoughness.baseColorTexture = found.ref;
            switch (record.blend) {
                // A glow: black, but for the light it gives.
                .additive => {
                    value.pbrMetallicRoughness.baseColorFactor = .{ 0, 0, 0, 1 };
                    value.emissiveTexture = found.ref;
                    value.emissiveFactor = .{ 1, 1, 1 };
                },
                .blended => value.alphaMode = "BLEND",
                else => if (found.alpha) {
                    value.alphaMode = "MASK";
                },
            }
        }
        var extras: json.ObjectMap = .empty;
        try extras.put(allocator, "kind", .{ .integer = @backingInt(record.kind) });
        try extras.put(allocator, "blend", .{ .integer = @backingInt(record.blend) });
        var names: json.Array = .init(allocator);
        for (material.textures) |name| try names.append(.{ .string = name });
        try extras.put(allocator, "textures", .{ .array = names });
        value.extras = .{ .object = extras };

        const index = try made.gltf.material(value);
        try made.materials.put(allocator, key, index);
        return index;
    }

    /// The glTF texture of the game's texture `name`, such as `sh_v2_viper01.tga`, read from
    /// `models/textures/` the first time; null where the archive doesn't hold it.
    fn textureOf(made: *Making, name: []const u8) Error!?Texture {
        const allocator = made.arena();
        const stem = try std.ascii.allocLowerString(allocator, std.Io.Dir.path.stem(name));
        const source = try std.fmt.allocPrint(allocator, "models/textures/{s}.btga", .{stem});
        if (made.textures.get(source)) |known| return known;
        const bytes = try made.files.read(allocator, source) orelse {
            try made.missing.append(allocator, source);
            try made.textures.put(allocator, source, null);
            return null;
        };
        const read: texture_file.Texture = try .parse(allocator, bytes);
        const file = try std.fmt.allocPrint(allocator, "{s}.png", .{stem});
        std.mem.replaceScalar(u8, file, ' ', '_');
        try made.pictures.append(allocator, .{ .file = file, .texture = read });
        const found: Texture = .{ .ref = try made.gltf.texture(file), .alpha = read.hasAlpha() };
        try made.textures.put(allocator, source, found);
        return found;
    }
};

/// The engine glow `from-gltf` gives a jet: the one the player's ships use.
const engine_glow = 1;

/// The index in `chosen` of the part `part` hangs from, or null where it hangs from none of them.
fn parentOf(chosen: []const model_file.Part, part: model_file.Part) ?usize {
    const parent = part.parent orelse return null;
    for (chosen, 0..) |other, at| {
        if (std.mem.eql(u8, other.name, parent)) return at;
    }
    return null;
}

/// The node name of a hardpoint: as `from-gltf` reads it for missiles and launch tubes, and its
/// kind for the others, such as `turret`.
fn hardpointName(arena: Allocator, defined: level_file.Hardpoint) Allocator.Error![]const u8 {
    const kind = defined.kind orelse return std.ascii.allocLowerString(arena, defined.type);
    return switch (kind) {
        .secondary => "missile",
        .launch_tube => "launch_point",
        else => @tagName(kind),
    };
}

/// What tells materials apart: the record and the textures' names.
fn materialKey(arena: Allocator, material: mesh_file.Material) Allocator.Error![]const u8 {
    const textures = material.textures;
    return std.fmt.allocPrint(arena, "{x}:{s}:{s}:{s}:{s}", .{ std.mem.asBytes(material.record), textures[0], textures[1], textures[2], textures[3] });
}

/// A material's name: its texture's, such as `sh_v2_viper01`, and how it blends where it doesn't
/// cover what is behind it.
fn materialName(arena: Allocator, material: mesh_file.Material) Allocator.Error![]const u8 {
    const stem = if (material.colour()) |name| std.Io.Dir.path.stem(name) else "untextured";
    return switch (material.record.blend) {
        .@"opaque" => stem,
        .additive => std.fmt.allocPrint(arena, "{s}_additive", .{stem}),
        .blended => std.fmt.allocPrint(arena, "{s}_blended", .{stem}),
        _ => std.fmt.allocPrint(arena, "{s}_blend{d}", .{ stem, @backingInt(material.record.blend) }),
    };
}

/// `v` in glTF's frame: X negated. Subtracting from 0 keeps a 0 a 0, where negating it would make
/// it -0.
fn mirror(v: [3]f32) [3]f32 {
    return .{ 0 - v[0], v[1], v[2] };
}

/// `m`, a Direct3D matrix row by row, in glTF's frame, column by column, or null for the
/// identity, which glTF takes for none. A Direct3D matrix row by row is glTF's column by column,
/// since one multiplies a row by it and the other a column; the mirror negates the entries that mix
/// X with Y, Z or the place.
fn mirrorMatrix(m: model_file.Matrix) ?[16]f32 {
    if (std.mem.eql(f32, &m, &model_file.identity)) return null;
    var turned = m;
    for ([_]usize{ 1, 2, 3, 4, 8, 12 }) |at| turned[at] = 0 - turned[at];
    return turned;
}

/// The normal of a vertex whose normal has no length: straight up.
const straight_up: [3]f32 = .{ 0, 1, 0 };

/// `attributes` as a JSON object: each attribute's number, string, or numbers.
fn attributesValue(arena: Allocator, attributes: []const level_file.Attribute) Allocator.Error!json.Value {
    var object: json.ObjectMap = .empty;
    for (attributes) |attribute| {
        const value: json.Value = switch (attribute.type) {
            .number => if (attribute.number()) |n| .{ .float = n } else .{ .string = if (attribute.values.len > 0) attribute.values[0] else "" },
            .string => .{ .string = attribute.string() orelse "" },
            .vector => vector: {
                var numbers: json.Array = .init(arena);
                for (attribute.values) |written| try numbers.append(if (std.fmt.parseFloat(f64, written)) |n| .{ .float = n } else |_| .{ .string = written });
                break :vector .{ .array = numbers };
            },
        };
        try object.put(arena, attribute.name, value);
    }
    return .{ .object = object };
}

/// `values` as a JSON array.
fn numbersValue(arena: Allocator, values: []const f32) Allocator.Error!json.Value {
    var array: json.Array = .init(arena);
    for (values) |value| try array.append(.{ .float = value });
    return .{ .array = array };
}

test mirrorMatrix {
    // A quarter turn about Y, moved 10 along X and 5 along Z.
    const turned: model_file.Matrix = .{ 0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 10, 0, 5, 1 };
    const in_gltf = mirrorMatrix(turned).?;
    // The place's X is negated, and the turn goes the other way.
    try std.testing.expectEqual([16]f32{ 0, 0, 1, 0, 0, 1, 0, 0, -1, 0, 0, 0, -10, 0, 5, 1 }, in_gltf);
    try std.testing.expectEqual(null, mirrorMatrix(model_file.identity));
}

test write {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A ship of one triangle, a gun, a jet, and a turret's hardpoint whose model is a turret of one
    // triangle.
    const hull_mesh = try mesh_file.testing.build(arena, &.{.{
        .texture = "sh_v2_viper01.tga",
        .positions = &.{ .{ 0, 0, 600 }, .{ -100, 0, 0 }, .{ 100, 0, 0 } },
        .normals = &.{ .{ 0, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 } },
        .uvs = &.{ .{ 0.5, 0 }, .{ 0, 1 }, .{ 1, 1 } },
        // Clockwise seen from above, the side its normals face, as the game's triangles go.
        .indices = &.{ 0, 2, 1 },
    }});
    const picture = try texture_file.testing.build(arena, 1, 1, &.{.{ 0, 0, 255, 0 }}, &.{0});
    const members = [_]struct { []const u8, []const u8 }{
        .{ "models/shv2vi00/shv2vi00.mdl", "model\n{\n// Maya scene Z:/viper.mb\nmodel\n{\nname({c1_viper2})\nparent({})\nmeshname({SHV2VI00c1_viper2Shape.msh})\n}\n}\n" },
        .{ "models/shv2vi00/shv2vi00c1_viper2shape.bmsh", hull_mesh },
        .{ "models/textures/sh_v2_viper01.btga", picture },
        .{ "levels/shv2vi00.lvl", "level\n{\nname({SHV2VI00})\n" ++
            "attribute({Gun1}, const, vector,224.5,-149.1,-95.7,0)\n" ++
            "attribute({Jet1}, const, vector,-152,17.6,-582.7,0)\n" ++
            "attribute({Jet1Size}, const, number,60)\n" ++
            "attribute({Turret00_type}, const, string,{TURRET})\n" ++
            "attribute({Turret00_object}, const, string,{tucbcb10})\n" ++
            "attribute({Turret00_xform3}, const, vector,0,50,0,0)\n}\n" },
        .{ "models/tucbcb10/tucbcb10.mdl", "model\n{\nmodel\n{\nname({c1_pivot})\nparent({})\nmeshname({TUCBCB10c1_pivotShape.msh})\n}\n}\n" },
        .{ "models/tucbcb10/tucbcb10c1_pivotshape.bmsh", hull_mesh },
    };
    const Archive = struct {
        fn read(context: *const anyopaque, _: Allocator, name: []const u8) ReadError!?[]const u8 {
            const held: *const @TypeOf(members) = @ptrCast(@alignCast(context));
            for (held) |member| if (std.mem.eql(u8, member[0], name)) return member[1];
            return null;
        }
    };
    const written = try write(arena, .{ .context = &members, .readFn = Archive.read }, "shv2vi00", .{}, "shv2vi00.bin");
    try std.testing.expectEqual(1, written.pictures.len);
    try std.testing.expectEqualStrings("sh_v2_viper01.png", written.pictures[0].file);
    try std.testing.expectEqual(0, written.missing.len);

    // Read back, the part's triangle, the turret's under its hardpoint, and the markers.
    const document = try write_gltf.testing.read(arena, written.json, written.bin, "shv2vi00.bin");
    const back = try gltf.triangles(arena, document, 1, &.{"sh_v2_viper01"});
    var names: std.ArrayList([]const u8) = .empty;
    for (back.objects) |object| try names.append(arena, object.name);
    for ([_][]const u8{ "c1_viper2", "gun_muzzle", "engine_glow:1", "c1_pivot" }) |name| {
        for (names.items) |held| {
            if (std.mem.eql(u8, held, name)) break;
        } else return error.TestExpectedEqual;
    }
    // The hull's triangle faces up, as it did in the game, and the gun on the right is on glTF's
    // right, its X negated.
    const hull = for (back.objects) |object| {
        if (std.mem.eql(u8, object.name, "c1_viper2")) break object;
    } else unreachable;
    const corner = hull.triangles[0].corners;
    var points: [3]math.Vector = undefined;
    for (&points, corner) |*p, c| p.* = back.positions[c.position];
    try std.testing.expect(math.cross(points[1] - points[0], points[2] - points[0])[1] > 0);
    try std.testing.expect(std.mem.find(u8, written.json, "-224.5") != null);
    // The hardpoint keeps its attributes.
    try std.testing.expect(std.mem.find(u8, written.json, "\"Turret00\"") != null);
}
