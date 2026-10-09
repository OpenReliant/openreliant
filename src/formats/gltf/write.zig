//! Writing glTF 2.0 ([the specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)):
//! a document built a node, a mesh and a material at a time, its geometry in one binary buffer that
//! the JSON names as a file beside it. `sltool shp gltf` (`shp/to_gltf.zig`) and `sltool bsg gltf`
//! (`games/bsg/to_gltf.zig`) write their models with it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const gltf = @import("../gltf.zig");
const math = @import("../../engine/surrender/math.zig");

comptime {
    // glTF's buffers are little-endian, as the values are in memory on the machines OpenReliant
    // runs on, so they are written as they are.
    std.debug.assert(builtin.target.cpu.arch.endian() == .little);
}

/// A node of the scene, with `extras` of the type the writer chooses.
pub fn Node(comptime Extras: type) type {
    return struct {
        name: []const u8,
        translation: ?[3]f32 = null,
        rotation: ?[4]f32 = null,
        scale: ?[3]f32 = null,
        /// The node's transform as a whole, column by column, in place of the three above.
        matrix: ?[16]f32 = null,
        mesh: ?u32 = null,
        children: ?[]const u32 = null,
        extras: ?Extras = null,
    };
}

pub const Mesh = struct {
    name: []const u8,
    primitives: []const Primitive,
};

pub const Primitive = struct {
    attributes: Attributes,
    indices: ?u32 = null,
    material: ?u32 = null,
};

/// A primitive's vertex attributes, by accessor. A name starting with an underscore is an
/// application's own attribute, which a reader keeps without drawing it.
pub const Attributes = struct {
    POSITION: u32,
    NORMAL: ?u32 = null,
    TEXCOORD_0: ?u32 = null,
    TEXCOORD_1: ?u32 = null,
    _COLOR: ?u32 = null,
};

pub const TextureRef = struct { index: u32 };

pub const Material = struct {
    name: []const u8,
    pbrMetallicRoughness: struct {
        baseColorTexture: ?TextureRef = null,
        baseColorFactor: ?[4]f32 = null,
        metallicFactor: f32 = 0,
        roughnessFactor: f32 = 1,
    } = .{},
    emissiveTexture: ?TextureRef = null,
    emissiveFactor: ?[3]f32 = null,
    /// `OPAQUE`, `MASK` or `BLEND`; glTF takes `OPAQUE` for none.
    alphaMode: ?[]const u8 = null,
    doubleSided: bool = false,
    extras: ?std.json.Value = null,
};

pub const Accessor = struct {
    bufferView: u32 = 0,
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
    target: ?u32 = null,
};

/// What a view of the buffer holds, as glTF numbers it.
pub const Target = enum(u32) {
    vertices = 34962,
    indices = 34963,
};

/// What a document is written as: its JSON, and its buffer's bytes, which the JSON names as the
/// file it was given.
pub const Written = struct {
    json: []const u8,
    bin: []const u8,
};

/// A document being built, whose nodes carry `extras` of type `Extras`.
pub fn Builder(comptime Extras: type) type {
    return struct {
        const Self = @This();

        arena: Allocator,
        nodes: std.ArrayList(Node(Extras)) = .empty,
        /// The nodes at the top of the scene.
        roots: std.ArrayList(u32) = .empty,
        meshes: std.ArrayList(Mesh) = .empty,
        materials: std.ArrayList(Material) = .empty,
        textures: std.ArrayList(struct { source: u32 }) = .empty,
        images: std.ArrayList(struct { uri: []const u8 }) = .empty,
        accessors: std.ArrayList(Accessor) = .empty,
        views: std.ArrayList(BufferView) = .empty,
        bin: std.ArrayList(u8) = .empty,

        pub fn init(arena: Allocator) Self {
            return .{ .arena = arena };
        }

        /// Adds `value` and returns its index.
        pub fn node(builder: *Self, value: Node(Extras)) Allocator.Error!u32 {
            try builder.nodes.append(builder.arena, value);
            return @intCast(builder.nodes.items.len - 1);
        }

        pub fn mesh(builder: *Self, value: Mesh) Allocator.Error!u32 {
            try builder.meshes.append(builder.arena, value);
            return @intCast(builder.meshes.items.len - 1);
        }

        pub fn material(builder: *Self, value: Material) Allocator.Error!u32 {
            try builder.materials.append(builder.arena, value);
            return @intCast(builder.materials.items.len - 1);
        }

        /// A texture of the picture `uri`, a file beside the glTF file's.
        pub fn texture(builder: *Self, uri: []const u8) Allocator.Error!TextureRef {
            try builder.images.append(builder.arena, .{ .uri = uri });
            try builder.textures.append(builder.arena, .{ .source = @intCast(builder.images.items.len - 1) });
            return .{ .index = @intCast(builder.textures.items.len - 1) };
        }

        /// An accessor of `bytes`, put in the buffer in a view of their own for `target`, as
        /// `described`. Each view starts at a multiple of 4 bytes, as glTF asks of the values in it.
        pub fn accessor(builder: *Self, bytes: []const u8, target: Target, described: Accessor) Allocator.Error!u32 {
            const arena = builder.arena;
            try builder.bin.appendNTimes(arena, 0, std.mem.alignForward(usize, builder.bin.items.len, view_alignment) - builder.bin.items.len);
            try builder.views.append(arena, .{ .byteOffset = builder.bin.items.len, .byteLength = bytes.len, .target = @backingInt(target) });
            try builder.bin.appendSlice(arena, bytes);
            var listed = described;
            listed.bufferView = @intCast(builder.views.items.len - 1);
            try builder.accessors.append(arena, listed);
            return @intCast(builder.accessors.items.len - 1);
        }

        /// The document, from `generator`, its buffer named `bin_name`.
        pub fn finish(builder: *Self, generator: []const u8, bin_name: []const u8) Allocator.Error!Written {
            const document = .{
                .asset = .{ .version = "2.0", .generator = generator },
                .scene = 0,
                .scenes = &[_]struct { nodes: []const u32 }{.{ .nodes = builder.roots.items }},
                .nodes = builder.nodes.items,
                .meshes = builder.meshes.items,
                .materials = builder.materials.items,
                .textures = builder.textures.items,
                .images = builder.images.items,
                .accessors = builder.accessors.items,
                .bufferViews = builder.views.items,
                .buffers = &[_]struct { uri: []const u8, byteLength: usize }{.{ .uri = bin_name, .byteLength = builder.bin.items.len }},
            };
            var json: std.Io.Writer.Allocating = .init(builder.arena);
            json.writer.print("{f}", .{std.json.fmt(document, .{ .emit_null_optional_fields = false, .whitespace = .indent_1 })}) catch return error.OutOfMemory;
            return .{ .json = json.written(), .bin = builder.bin.items };
        }
    };
}

/// Where each view of the buffer starts: a multiple of the largest value glTF holds, a float.
const view_alignment = 4;

/// The least and the most of `points` along each axis, as a `POSITION` accessor gives them.
pub fn bounds(points: []const [3]f32) struct { [3]f32, [3]f32 } {
    var lo: @Vector(3, f32) = @splat(std.math.inf(f32));
    var hi: @Vector(3, f32) = @splat(-std.math.inf(f32));
    for (points) |point| {
        lo = @min(lo, @as(@Vector(3, f32), point));
        hi = @max(hi, @as(@Vector(3, f32), point));
    }
    return .{ lo, hi };
}

/// The parent of item `index` in a glTF file's tree of nodes, where `parents` gives each item's
/// parent by its index: null for none, and where the parents lead out of the list or back to the
/// item, which a tree can't hold.
pub fn treeParent(parents: []const ?usize, index: usize) ?usize {
    const parent = parents[index] orelse return null;
    var up: ?usize = parent;
    for (0..parents.len) |_| {
        const at = up orelse return parent;
        if (at >= parents.len or at == index) return null;
        up = parents[at];
    }
    return null;
}

/// `normal` made a unit long, as glTF's normals must be, or null for one too short to have a
/// direction.
pub fn unit(normal: math.Vector) ?math.Vector {
    if (math.length(normal) <= least_length) return null;
    return math.normalize(normal);
}

/// The shortest normal, or cross product, taken to have a direction.
const least_length = 1e-6;

/// Reading written documents back, for tests.
pub const testing = struct {
    /// The document of `json`, whose buffer is `bin`, named `bin_name`.
    pub fn read(arena: Allocator, json: []const u8, bin: []const u8, bin_name: []const u8) gltf.Error!gltf.Document {
        const Buffer = struct {
            name: []const u8,
            bytes: []const u8,

            fn read(context: *const anyopaque, _: Allocator, name: []const u8) Allocator.Error!?[]u8 {
                const buffer: *const @This() = @ptrCast(@alignCast(context));
                return if (std.mem.eql(u8, name, buffer.name)) @constCast(buffer.bytes) else null;
            }
        };
        const buffer: Buffer = .{ .name = bin_name, .bytes = bin };
        return gltf.read(arena, json, .{ .context = &buffer, .readFn = Buffer.read });
    }
};

test treeParent {
    // 0 hangs from nothing, 1 from 0 and 2 from 1; 3 and 4 hang from each other, and 5 from an item
    // the list doesn't hold.
    const parents = [_]?usize{ null, 0, 1, 4, 3, 9 };
    try std.testing.expectEqual(null, treeParent(&parents, 0));
    try std.testing.expectEqual(0, treeParent(&parents, 1).?);
    try std.testing.expectEqual(1, treeParent(&parents, 2).?);
    try std.testing.expectEqual(null, treeParent(&parents, 3));
    try std.testing.expectEqual(null, treeParent(&parents, 4));
    try std.testing.expectEqual(null, treeParent(&parents, 5));
}

test unit {
    try std.testing.expectEqual(math.Vector{ 0, 0, 1 }, unit(.{ 0, 0, 3 }).?);
    try std.testing.expectEqual(null, unit(.{ 0, 0, 0 }));
}

test Builder {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var builder: Builder(struct { kind: []const u8 }) = .init(arena);
    const positions = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const indices = [_]u16{ 0, 1, 2 };
    const lo, const hi = bounds(&positions);
    const index_accessor = try builder.accessor(std.mem.sliceAsBytes(&indices), .indices, .{ .componentType = @backingInt(gltf.Component.unsigned_short), .count = 3, .type = "SCALAR" });
    const position_accessor = try builder.accessor(std.mem.sliceAsBytes(&positions), .vertices, .{ .count = 3, .type = "VEC3", .min = lo, .max = hi });
    const picture = try builder.texture("hull.png");
    const material = try builder.material(.{ .name = "hull", .pbrMetallicRoughness = .{ .baseColorTexture = picture } });
    const mesh = try builder.mesh(.{ .name = "body", .primitives = &.{.{ .attributes = .{ .POSITION = position_accessor }, .indices = index_accessor, .material = material }} });
    const marker = try builder.node(.{ .name = "gun_muzzle", .translation = .{ 1, 2, 3 }, .extras = .{ .kind = "gun" } });
    try builder.roots.append(arena, try builder.node(.{ .name = "ship", .mesh = mesh, .children = &.{marker} }));
    const written = try builder.finish("test", "ship.bin");

    // The positions start at a multiple of 4 after the 6 bytes of indices.
    try std.testing.expectEqual(8, builder.views.items[1].byteOffset);
    try std.testing.expectEqual(8 + 36, written.bin.len);

    // The reader finds the triangle, and the marker by its name.
    const document = try testing.read(arena, written.json, written.bin, "ship.bin");
    const back = try gltf.triangles(arena, document, 1, &.{"hull"});
    try std.testing.expectEqual(2, back.objects.len);
    try std.testing.expectEqualStrings("gun_muzzle", back.objects[1].name);
    try std.testing.expect(std.mem.find(u8, written.json, "\"kind\": \"gun\"") != null);
}
