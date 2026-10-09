//! glTF 2.0 ([the specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)), as
//! modelling tools such as Blender export it: what `sltool shp from-gltf` builds a model for a mod
//! from ([#359](https://github.com/OpenReliant/openreliant/issues/359)). It reads a `.gltf` file,
//! its buffers in files beside it or in `data:` URIs, and a binary `.glb` file (`read`).
//!
//! `triangles` walks the scene's nodes with their transforms and returns their triangles as an
//! `obj.File`, which the OBJ builder takes (`shp.from_obj`). Each node with a mesh becomes an object
//! with the node's name, and each triangle keeps its material's number. A named node without a mesh
//! becomes a marker, which a name such as `gun_muzzle:1` turns into an attachment. `Material` holds
//! each material's colour, metalness, roughness and glow, and the textures they come from.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const obj = @import("obj.zig");
const math = @import("../engine/surrender/math.zig");
pub const maps = @import("gltf/maps.zig");

pub const Error = Allocator.Error || error{
    /// The file is neither a glTF file's JSON nor a `.glb` file, or its JSON isn't glTF's.
    NotGltf,
    /// An index names something the file doesn't have, or data runs past its buffer.
    BadIndex,
    /// Something glTF allows that this reader doesn't take, such as a sparse accessor or an
    /// extension the file requires.
    Unsupported,
    /// A buffer's file can't be read.
    MissingBuffer,
};

/// Reads the file `name` next to the glTF file, for its buffers and images. Returns null if the
/// file can't be read.
pub const Files = struct {
    context: *const anyopaque,
    readFn: *const fn (context: *const anyopaque, arena: Allocator, name: []const u8) Allocator.Error!?[]u8,

    pub fn read(files: Files, arena: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        return files.readFn(files.context, arena, name);
    }
};

/// A glTF file, read: its JSON, and its buffers' bytes.
pub const Document = struct {
    root: json.ObjectMap,
    buffers: []const []const u8,
    files: Files,

    /// The member `name` of the root, as a list; empty where it has none.
    fn list(document: Document, name: []const u8) []const json.Value {
        const value = document.root.get(name) orelse return &.{};
        return if (value == .array) value.array.items else &.{};
    }

    /// The object at `index` of the root's list `name`.
    fn item(document: Document, name: []const u8, at: usize) Error!json.ObjectMap {
        const items = document.list(name);
        if (at >= items.len or items[at] != .object) return error.BadIndex;
        return items[at].object;
    }
};

/// The magic and the chunk types of a binary `.glb` file.
const glb_magic = "glTF";
const glb_json = 0x4E4F534A;
const glb_binary = 0x004E4942;
/// A `.glb` file's header: its magic, its version and its length.
const glb_header_size = 12;
/// A chunk's header: its length and its type.
const chunk_header_size = 8;

/// The extensions a file may require that this reader accepts anyway: they only change how its
/// materials look, and the model can be drawn without them.
const harmless_extensions = [_][]const u8{ "KHR_materials_emissive_strength", "KHR_materials_specular", "KHR_texture_transform" };

/// The glTF file `bytes`, its JSON or a `.glb` file, read into `arena`, its buffers' files read
/// through `files`.
pub fn read(arena: Allocator, bytes: []const u8, files: Files) Error!Document {
    var text = bytes;
    var binary: ?[]const u8 = null;
    if (std.mem.startsWith(u8, bytes, glb_magic)) {
        if (bytes.len < glb_header_size + chunk_header_size) return error.NotGltf;
        var at: usize = glb_header_size;
        text = &.{};
        while (at + chunk_header_size <= bytes.len) {
            const length = std.mem.readInt(u32, bytes[at..][0..4], .little);
            const kind = std.mem.readInt(u32, bytes[at + 4 ..][0..4], .little);
            at += chunk_header_size;
            if (length > bytes.len - at) return error.NotGltf;
            const body = bytes[at..][0..length];
            switch (kind) {
                glb_json => text = body,
                glb_binary => binary = body,
                else => {},
            }
            at += std.mem.alignForward(usize, length, 4);
        }
    }
    const parsed = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.NotGltf,
    };
    if (parsed != .object) return error.NotGltf;
    const root = parsed.object;
    const asset = root.get("asset") orelse return error.NotGltf;
    if (asset != .object) return error.NotGltf;
    if (root.get("extensionsRequired")) |required| if (required == .array) for (required.array.items) |name| {
        if (name != .string) continue;
        for (harmless_extensions) |harmless| {
            if (std.mem.eql(u8, name.string, harmless)) break;
        } else return error.Unsupported;
    };

    var document: Document = .{ .root = root, .buffers = &.{}, .files = files };
    const listed = document.list("buffers");
    const buffers = try arena.alloc([]const u8, listed.len);
    for (buffers, listed, 0..) |*buffer, value, at| {
        if (value != .object) return error.BadIndex;
        buffer.* = if (value.object.get("uri")) |uri|
            try resource(arena, files, string(uri) orelse return error.BadIndex) orelse return error.MissingBuffer
        else if (at == 0) binary orelse return error.MissingBuffer else return error.MissingBuffer;
    }
    document.buffers = buffers;
    return document;
}

/// The bytes of `uri`: decoded from a base64 `data:` URI, or read from a file next to the glTF
/// file. Returns null if the file can't be read.
fn resource(arena: Allocator, files: Files, uri: []const u8) Error!?[]const u8 {
    if (std.mem.startsWith(u8, uri, "data:")) {
        const comma = std.mem.findScalar(u8, uri, ',') orelse return error.BadIndex;
        const encoded = uri[comma + 1 ..];
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(encoded) catch return error.BadIndex;
        const decoded = try arena.alloc(u8, size);
        decoder.decode(decoded, encoded) catch return error.BadIndex;
        return decoded;
    }
    return files.read(arena, try fileName(arena, uri));
}

/// The file name in `uri`, with its percent escapes decoded.
fn fileName(arena: Allocator, uri: []const u8) Allocator.Error![]const u8 {
    const name = try arena.alloc(u8, uri.len);
    return std.Uri.percentDecodeBackwards(name, uri);
}

fn string(value: json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn number(value: json.Value) ?f64 {
    return switch (value) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => null,
    };
}

fn index(object: json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

/// The numbers of the member `name`, a list of `count`; `default` where it has none.
fn numbers(comptime count: usize, object: json.ObjectMap, name: []const u8, default: [count]f32) [count]f32 {
    const value = object.get(name) orelse return default;
    if (value != .array or value.array.items.len != count) return default;
    var out: [count]f32 = undefined;
    for (&out, value.array.items) |*into, item| into.* = @floatCast(number(item) orelse return default);
    return out;
}

// --- Accessors ---------------------------------------------------------------------------------

/// What an accessor's elements are made of (`componentType`).
pub const Component = enum(u16) {
    byte = 5120,
    unsigned_byte = 5121,
    short = 5122,
    unsigned_short = 5123,
    unsigned_int = 5125,
    float = 5126,

    fn size(component: Component) usize {
        return switch (component) {
            .byte, .unsigned_byte => 1,
            .short, .unsigned_short => 2,
            .unsigned_int, .float => 4,
        };
    }

    /// Whether it is an unsigned integer, as a primitive's indices must be.
    fn unsigned(component: Component) bool {
        return switch (component) {
            .unsigned_byte, .unsigned_short, .unsigned_int => true,
            .byte, .short, .float => false,
        };
    }
};

/// A buffer view's bytes, and its stride where it gives one.
const View = struct {
    bytes: []const u8,
    stride: ?usize,

    /// The file's buffer view `at`, within its buffer.
    fn of(document: Document, at: usize) Error!View {
        const view = try document.item("bufferViews", at);
        const buffer = index(view, "buffer") orelse return error.BadIndex;
        if (buffer >= document.buffers.len) return error.BadIndex;
        const start = index(view, "byteOffset") orelse 0;
        const length = index(view, "byteLength") orelse return error.BadIndex;
        const bytes = document.buffers[buffer];
        if (start > bytes.len or length > bytes.len - start) return error.BadIndex;
        return .{ .bytes = bytes[start..][0..length], .stride = index(view, "byteStride") };
    }
};

/// An accessor: `count` elements of `width` components each, read from its buffer view.
const Accessor = struct {
    bytes: []const u8,
    stride: usize,
    count: usize,
    width: usize,
    component: Component,
    normalized: bool,

    fn of(document: Document, at: usize) Error!Accessor {
        const accessor = try document.item("accessors", at);
        if (accessor.get("sparse") != null) return error.Unsupported;
        const component = std.enums.fromInt(Component, index(accessor, "componentType") orelse return error.BadIndex) orelse return error.Unsupported;
        const kind = string(accessor.get("type") orelse return error.BadIndex) orelse return error.BadIndex;
        const width: usize = for ([_]struct { []const u8, usize }{ .{ "SCALAR", 1 }, .{ "VEC2", 2 }, .{ "VEC3", 3 }, .{ "VEC4", 4 } }) |pair| {
            if (std.mem.eql(u8, kind, pair[0])) break pair[1];
        } else return error.Unsupported;
        const count = index(accessor, "count") orelse return error.BadIndex;
        const view: View = try .of(document, index(accessor, "bufferView") orelse return error.Unsupported);
        const start = index(accessor, "byteOffset") orelse 0;
        const element = width * component.size();
        const stride = view.stride orelse element;
        const bytes = view.bytes;
        if (count > 0 and (start > bytes.len or (count - 1) * stride + element > bytes.len - start)) return error.BadIndex;
        const normalized = if (accessor.get("normalized")) |value| value == .bool and value.bool else false;
        return .{ .bytes = bytes[start..], .stride = stride, .count = count, .width = width, .component = component, .normalized = normalized };
    }

    /// Component `part` of element `at`, as a number: a normalized integer from 0 to 1, or -1 to 1.
    fn get(accessor: Accessor, at: usize, part: usize) f32 {
        const from = accessor.bytes[at * accessor.stride + part * accessor.component.size() ..];
        return switch (accessor.component) {
            .float => @bitCast(std.mem.readInt(u32, from[0..4], .little)),
            .unsigned_int => @floatFromInt(std.mem.readInt(u32, from[0..4], .little)),
            .unsigned_short => scaled(u16, std.mem.readInt(u16, from[0..2], .little), accessor.normalized),
            .short => scaled(i16, std.mem.readInt(i16, from[0..2], .little), accessor.normalized),
            .unsigned_byte => scaled(u8, from[0], accessor.normalized),
            .byte => scaled(i8, @bitCast(from[0]), accessor.normalized),
        };
    }

    /// Element `at` as an index, of an accessor of unsigned integers (`Component.unsigned`).
    fn indexAt(accessor: Accessor, at: usize) usize {
        const from = accessor.bytes[at * accessor.stride ..];
        return switch (accessor.component.size()) {
            1 => from[0],
            2 => std.mem.readInt(u16, from[0..2], .little),
            else => std.mem.readInt(u32, from[0..4], .little),
        };
    }

    fn vector(accessor: Accessor, comptime count: usize, at: usize) [count]f32 {
        var out: [count]f32 = @splat(0);
        for (out[0..@min(count, accessor.width)], 0..) |*into, part| into.* = accessor.get(at, part);
        return out;
    }
};

fn scaled(comptime T: type, value: T, normalized: bool) f32 {
    const float: f32 = @floatFromInt(value);
    if (!normalized) return float;
    return @max(float / std.math.maxInt(T), -1);
}

// --- The scene ---------------------------------------------------------------------------------

/// A 4x4 matrix, by columns, as glTF keeps its nodes' matrices.
const Matrix = [16]f32;

const identity: Matrix = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

fn multiply(a: Matrix, b: Matrix) Matrix {
    var out: Matrix = undefined;
    for (0..4) |column| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += a[k * 4 + row] * b[column * 4 + k];
        out[column * 4 + row] = sum;
    };
    return out;
}

/// The point `p` moved by `m`.
fn transformPoint(m: Matrix, p: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (&out, 0..) |*into, row| into.* = m[row] * p[0] + m[4 + row] * p[1] + m[8 + row] * p[2] + m[12 + row];
    return out;
}

/// The 3x3 part of `m`, as the engine's math holds a matrix, row by row.
fn linear(m: Matrix) math.Matrix {
    return .{ m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10] };
}

/// The matrix that turns normals as `turn` turns points: the inverse of its transpose, which keeps
/// normals at right angles to their surfaces under a stretch; `turn` itself where it has none.
fn normalMatrix(turn: math.Matrix) math.Matrix {
    return math.transpose(math.inverse(turn) orelse return turn);
}

/// The normal `n` turned by `m`, a unit long; none where it has no length.
fn turnNormal(m: math.Matrix, n: [3]f32) [3]f32 {
    const turned = math.transform(m, n);
    if (math.length(turned) == 0) return turned;
    return math.normalize(turned);
}

/// A node's own transform: its `matrix`, or its translation, rotation and scale.
fn local(node: json.ObjectMap) Matrix {
    if (node.get("matrix") != null) return numbers(16, node, "matrix", identity);
    const t = numbers(3, node, "translation", .{ 0, 0, 0 });
    const q = numbers(4, node, "rotation", .{ 0, 0, 0, 1 });
    const s = numbers(3, node, "scale", .{ 1, 1, 1 });
    const x, const y, const z, const w = q;
    return .{
        (1 - 2 * (y * y + z * z)) * s[0], (2 * (x * y + z * w)) * s[0],     (2 * (x * z - y * w)) * s[0],     0,
        (2 * (x * y - z * w)) * s[1],     (1 - 2 * (x * x + z * z)) * s[1], (2 * (y * z + x * w)) * s[1],     0,
        (2 * (x * z + y * w)) * s[2],     (2 * (y * z - x * w)) * s[2],     (1 - 2 * (x * x + y * y)) * s[2], 0,
        t[0],                             t[1],                             t[2],                             1,
    };
}

/// The half side of a marker's cube (a node without a mesh) at a scale of 1. The cube's box is the
/// attachment's size.
const marker_half: f32 = 1;

/// The triangles of the file's scene (`scene`, else the first) as an `obj.File`. Each node with a
/// mesh becomes an object with the node's name. Points and normals are moved by the node's
/// transform and its parents', then scaled by `scale`. A triangle's material is the name
/// `material_names` gives its material's number, or none for a primitive without a material. A
/// named node without a mesh or children becomes a marker (`obj.Object.marker`): an object of three
/// corners around its place, which a name such as `gun_muzzle:1` turns into an attachment. Texture
/// coordinates are flipped to the OBJ convention, where v counts up from the picture's bottom.
pub fn triangles(arena: Allocator, document: Document, scale: f32, material_names: []const []const u8) Error!obj.File {
    var made: Making = .{ .arena = arena, .document = document, .scale = scale, .material_names = material_names };
    const scenes = document.list("scenes");
    const shown = index(document.root, "scene") orelse 0;
    if (shown < scenes.len and scenes[shown] == .object) {
        const nodes = scenes[shown].object.get("nodes") orelse return made.file();
        if (nodes == .array) for (nodes.array.items) |node| {
            if (node != .integer or node.integer < 0) return error.BadIndex;
            try made.node(@intCast(node.integer), identity, 0);
        };
    }
    return made.file();
}

/// The deepest node nesting the reader follows; a deeper file is taken to loop.
const max_depth = 64;

const Making = struct {
    arena: Allocator,
    document: Document,
    scale: f32,
    material_names: []const []const u8,
    positions: std.ArrayList([3]f32) = .empty,
    uvs: std.ArrayList([2]f32) = .empty,
    normals: std.ArrayList([3]f32) = .empty,
    objects: std.ArrayList(obj.Object) = .empty,

    fn file(made: *Making) obj.File {
        return .{ .positions = made.positions.items, .uvs = made.uvs.items, .normals = made.normals.items, .objects = made.objects.items };
    }

    fn node(made: *Making, at: usize, parent: Matrix, depth: usize) Error!void {
        if (depth > max_depth) return error.BadIndex;
        const value = try made.document.item("nodes", at);
        const world = multiply(parent, local(value));
        const name = if (value.get("name")) |named| string(named) orelse "" else "";
        const children = value.get("children");
        if (index(value, "mesh")) |shown| {
            try made.mesh(shown, world, name);
        } else if (name.len > 0 and children == null) {
            try made.marker(world, name);
        }
        if (children) |listed| if (listed == .array) for (listed.array.items) |child| {
            if (child != .integer or child.integer < 0) return error.BadIndex;
            try made.node(@intCast(child.integer), world, depth + 1);
        };
    }

    fn mesh(made: *Making, at: usize, world: Matrix, name: []const u8) Error!void {
        const value = try made.document.item("meshes", at);
        const primitives = value.get("primitives") orelse return;
        if (primitives != .array) return error.BadIndex;
        const turn = linear(world);
        const normal_turn = normalMatrix(turn);
        // A mirroring transform turns the triangles' faces inside out, which their corners'
        // order then puts right.
        const mirrored = math.determinant(turn) < 0;
        var list: std.ArrayList(obj.Triangle) = .empty;
        for (primitives.array.items) |listed| {
            if (listed != .object) return error.BadIndex;
            try made.primitive(listed.object, world, normal_turn, mirrored, &list);
        }
        if (list.items.len > 0) try made.objects.append(made.arena, .{ .name = name, .triangles = list.items });
    }

    fn primitive(made: *Making, value: json.ObjectMap, world: Matrix, normal_turn: math.Matrix, mirrored: bool, list: *std.ArrayList(obj.Triangle)) Error!void {
        const mode: Mode = if (index(value, "mode")) |given| @fromBackingInt(std.math.cast(u32, given) orelse return) else .triangles;
        switch (mode) {
            .triangles, .triangle_strip, .triangle_fan => {},
            _ => return,
        }
        const attributes = (value.get("attributes") orelse return error.BadIndex);
        if (attributes != .object) return error.BadIndex;
        const positions: Accessor = try .of(made.document, index(attributes.object, "POSITION") orelse return error.BadIndex);
        const normals: ?Accessor = if (index(attributes.object, "NORMAL")) |at| try .of(made.document, at) else null;
        const uvs: ?Accessor = if (index(attributes.object, "TEXCOORD_0")) |at| try .of(made.document, at) else null;
        const indices: ?Accessor = if (index(value, "indices")) |at| try .of(made.document, at) else null;
        if (indices) |listed| if (!listed.component.unsigned()) return error.BadIndex;
        const material: ?[]const u8 = if (index(value, "material")) |at| (if (at < made.material_names.len) made.material_names[at] else return error.BadIndex) else null;

        // The primitive's vertices, each at the same index in the file's lists.
        const first: u32 = @intCast(made.positions.items.len);
        for (0..positions.count) |at| {
            const p = transformPoint(world, positions.vector(3, at));
            try made.positions.append(made.arena, .{ p[0] * made.scale, p[1] * made.scale, p[2] * made.scale });
            try made.normals.append(made.arena, if (normals) |n| turnNormal(normal_turn, n.vector(3, at)) else .{ 0, 0, 0 });
            const uv = if (uvs) |u| u.vector(2, at) else [2]f32{ 0, 0 };
            try made.uvs.append(made.arena, .{ uv[0], 1 - uv[1] });
        }
        const count = if (indices) |i| i.count else positions.count;
        const corner = struct {
            fn at(order: ?Accessor, base: u32, n: usize, has_normals: bool, has_uvs: bool) Error!obj.Corner {
                const vertex: u32 = base + @as(u32, @intCast(if (order) |o| o.indexAt(n) else n));
                return .{ .position = vertex, .uv = if (has_uvs) vertex else null, .normal = if (has_normals) vertex else null };
            }
        }.at;
        if (indices) |i| for (0..i.count) |n| if (i.indexAt(n) >= positions.count) return error.BadIndex;
        var at: usize = 0;
        while (true) {
            var three: [3]usize = undefined;
            switch (mode) {
                .triangles => {
                    if (at + 3 > count) break;
                    three = .{ at, at + 1, at + 2 };
                    at += 3;
                },
                .triangle_strip => {
                    if (at + 3 > count) break;
                    // Every other triangle of a strip runs the other way round.
                    three = if (at % 2 == 0) .{ at, at + 1, at + 2 } else .{ at + 1, at, at + 2 };
                    at += 1;
                },
                .triangle_fan, _ => {
                    if (at + 3 > count) break;
                    three = .{ 0, at + 1, at + 2 };
                    at += 1;
                },
            }
            if (mirrored) std.mem.swap(usize, &three[1], &three[2]);
            var corners: [3]obj.Corner = undefined;
            for (&corners, three) |*into, n| into.* = try corner(indices, first, n, normals != null, uvs != null);
            try list.append(made.arena, .{ .corners = corners, .material = material });
        }
    }

    /// A marker for the node at `world` called `name`: three corners spanning the box around a
    /// cube of `marker_half` scaled, turned and moved by the node's transform. A marker scaled
    /// along one axis makes a long box, such as an engine glow's.
    fn marker(made: *Making, world: Matrix, name: []const u8) Error!void {
        // Each axis of the box reaches as far as the cube's turned axes reach along it.
        const turn = linear(world);
        var half: [3]f32 = @splat(0);
        for (&half, 0..) |*reach, row| {
            for (turn[row * 3 ..][0..3]) |along| reach.* += @abs(along) * marker_half;
        }
        const middle = transformPoint(world, .{ 0, 0, 0 });
        const first: u32 = @intCast(made.positions.items.len);
        for ([_][3]f32{ .{ -1, -1, -1 }, .{ 1, 1, -1 }, .{ -1, 1, 1 } }) |direction| {
            var corner: [3]f32 = undefined;
            for (&corner, middle, direction, half) |*into, at, way, reach| into.* = (at + way * reach) * made.scale;
            try made.positions.append(made.arena, corner);
            // The lists keep a vertex at the same index in each, for the meshes after it.
            try made.normals.append(made.arena, .{ 0, 0, 0 });
            try made.uvs.append(made.arena, .{ 0, 0 });
        }
        const triangle = try made.arena.alloc(obj.Triangle, 1);
        triangle[0] = .{ .corners = .{ .{ .position = first }, .{ .position = first + 1 }, .{ .position = first + 2 } }, .material = null };
        try made.objects.append(made.arena, .{ .name = name, .triangles = triangle, .marker = true });
    }
};

/// A primitive's mode (`mode`): what its vertices make. This reader takes the triangles' alone:
/// lists, strips and fans.
const Mode = enum(u32) {
    triangles = 4,
    triangle_strip = 5,
    triangle_fan = 6,
    _,
};

// --- Materials ---------------------------------------------------------------------------------

/// The picture of a material's texture.
pub const Image = union(enum) {
    /// The file's bytes, and its media type if the glTF file gives one.
    found: struct {
        bytes: []const u8,
        mime: ?[]const u8 = null,
    },
    /// The name of a file that can't be read, such as a picture that `sltool shp gltf` names but
    /// doesn't write without `--textures`.
    missing: []const u8,
};

/// A material in glTF's metallic workflow. Colours and values are in linear light, every texture
/// is optional, and a texture's values are multiplied by the matching factor.
pub const Material = struct {
    name: []const u8,
    /// Its colour and alpha (`baseColorFactor`), and their texture.
    colour: [4]f32 = .{ 1, 1, 1, 1 },
    colour_texture: ?Image = null,
    /// How metallic and how rough it is, and their texture: roughness in its green, metalness in
    /// its blue.
    metallic: f32 = 1,
    roughness: f32 = 1,
    metal_rough_texture: ?Image = null,
    /// The surface's normals, as OpenGL's normal maps hold them.
    normal_texture: ?Image = null,
    /// How much of the ambient light reaches it, in its texture's red.
    occlusion_texture: ?Image = null,
    /// The light it gives off by itself (`emissiveFactor` times `KHR_materials_emissive_strength`),
    /// and its texture.
    emissive: [3]f32 = .{ 0, 0, 0 },
    emissive_texture: ?Image = null,
    /// Whether its faces are seen from behind too.
    double_sided: bool = false,
};

/// The file's materials, in its order.
pub fn materials(arena: Allocator, document: Document) Error![]Material {
    const listed = document.list("materials");
    const out = try arena.alloc(Material, listed.len);
    for (out, listed, 0..) |*material, value, at| {
        if (value != .object) return error.BadIndex;
        const object = value.object;
        material.* = .{ .name = if (object.get("name")) |name| string(name) orelse "" else "" };
        if (material.name.len == 0) material.name = try arena.print("material {d}", .{at});
        if (object.get("pbrMetallicRoughness")) |pbr| if (pbr == .object) {
            material.colour = numbers(4, pbr.object, "baseColorFactor", material.colour);
            material.colour_texture = try image(arena, document, pbr.object, "baseColorTexture");
            if (pbr.object.get("metallicFactor")) |factor| material.metallic = @floatCast(number(factor) orelse 1);
            if (pbr.object.get("roughnessFactor")) |factor| material.roughness = @floatCast(number(factor) orelse 1);
            material.metal_rough_texture = try image(arena, document, pbr.object, "metallicRoughnessTexture");
        };
        material.normal_texture = try image(arena, document, object, "normalTexture");
        material.occlusion_texture = try image(arena, document, object, "occlusionTexture");
        material.emissive = numbers(3, object, "emissiveFactor", material.emissive);
        material.emissive_texture = try image(arena, document, object, "emissiveTexture");
        if (object.get("extensions")) |extensions| if (extensions == .object) {
            if (extensions.object.get("KHR_materials_emissive_strength")) |strength| if (strength == .object) {
                const factor: f32 = @floatCast(if (strength.object.get("emissiveStrength")) |given| number(given) orelse 1 else 1);
                for (&material.emissive) |*channel| channel.* *= factor;
            };
        };
        material.double_sided = if (object.get("doubleSided")) |sided| sided == .bool and sided.bool else false;
    }
    return out;
}

/// The picture of the texture that the member `name` of `object` refers to (a texture info), or
/// null if there is none.
fn image(arena: Allocator, document: Document, object: json.ObjectMap, name: []const u8) Error!?Image {
    const info = object.get(name) orelse return null;
    if (info != .object) return error.BadIndex;
    const texture = try document.item("textures", index(info.object, "index") orelse return error.BadIndex);
    const source = try document.item("images", index(texture, "source") orelse return null);
    const mime = if (source.get("mimeType")) |given| string(given) else null;
    if (source.get("uri")) |value| {
        const uri = string(value) orelse return error.BadIndex;
        const bytes = try resource(arena, document.files, uri) orelse return .{ .missing = try fileName(arena, uri) };
        return .{ .found = .{ .bytes = bytes, .mime = mime } };
    }
    const view: View = try .of(document, index(source, "bufferView") orelse return error.BadIndex);
    return .{ .found = .{ .bytes = view.bytes, .mime = mime } };
}

/// Files for the tests: none.
const no_files: Files = .{ .context = &{}, .readFn = struct {
    fn read(_: *const anyopaque, _: Allocator, _: []const u8) Allocator.Error!?[]u8 {
        return null;
    }
}.read };

/// A glTF file for the tests: a triangle on a node moved 10 along x and half as large, a marker,
/// a group holding a node without a name, an engine glow scaled along x and turned to lie along z,
/// and a red, quarter-metallic material glowing green.
fn testFile(arena: Allocator) ![]const u8 {
    var buffer: [3 * 3 * 4]u8 = undefined;
    for ([_]f32{ 0, 0, 0, 2, 0, 0, 0, 2, 0 }, 0..) |value, at| std.mem.writeInt(u32, buffer[at * 4 ..][0..4], @bitCast(value), .little);
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(buffer.len));
    _ = encoder.encode(encoded, &buffer);
    return arena.print(
        \\{{"asset": {{"version": "2.0"}}, "scene": 0,
        \\ "scenes": [{{"nodes": [0, 1, 2, 4]}}],
        \\ "nodes": [{{"name": "hull", "mesh": 0, "translation": [10, 0, 0], "scale": [0.5, 0.5, 0.5]}},
        \\           {{"name": "gun_muzzle:3", "translation": [0, 0, 5]}},
        \\           {{"name": "group", "children": [3]}}, {{"translation": [1, 1, 1]}},
        \\           {{"name": "engine_glow:2", "rotation": [0, 0.70710678, 0, 0.70710678], "scale": [3, 1, 1]}}],
        \\ "meshes": [{{"primitives": [{{"attributes": {{"POSITION": 0}}, "material": 0}}]}}],
        \\ "materials": [{{"name": "paint", "pbrMetallicRoughness": {{"baseColorFactor": [1, 0, 0, 1], "metallicFactor": 0.25}},
        \\                "emissiveFactor": [0, 1, 0], "extensions": {{"KHR_materials_emissive_strength": {{"emissiveStrength": 2}}}}}}],
        \\ "accessors": [{{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"}}],
        \\ "bufferViews": [{{"buffer": 0, "byteLength": 36}}],
        \\ "buffers": [{{"byteLength": 36, "uri": "data:application/octet-stream;base64,{s}"}}]}}
    , .{encoded});
}

test triangles {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const document = try read(arena.allocator(), try testFile(arena.allocator()), no_files);
    const file = try triangles(arena.allocator(), document, 2, &.{"paint_0"});
    // The hull, moved and halved, then doubled; and the markers, as three corners round their place.
    try std.testing.expectEqual(3, file.objects.len);
    const hull = file.objects[0];
    try std.testing.expectEqualStrings("hull", hull.name);
    try std.testing.expectEqualStrings("paint_0", hull.triangles[0].material.?);
    try std.testing.expectEqual([3]f32{ 20, 0, 0 }, file.positions[hull.triangles[0].corners[0].position]);
    try std.testing.expectEqual([3]f32{ 22, 0, 0 }, file.positions[hull.triangles[0].corners[1].position]);
    const marker = file.objects[1];
    try std.testing.expect(marker.marker);
    try std.testing.expectEqualStrings("gun_muzzle:3", marker.name);
    try std.testing.expectEqual([3]f32{ -2, -2, 8 }, file.positions[marker.triangles[0].corners[0].position]);
    // The engine glow's box is long along z, where its turn points its long x.
    const glow = file.objects[2];
    for ([_][3]f32{ .{ -2, -2, -6 }, .{ 2, 2, -6 }, .{ -2, 2, 6 } }, glow.triangles[0].corners) |expected, corner| {
        for (expected, file.positions[corner.position]) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-5);
    }
    // A file without its asset isn't read as glTF.
    try std.testing.expectError(error.NotGltf, read(arena.allocator(), "{}", no_files));
}

test materials {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const document = try read(arena.allocator(), try testFile(arena.allocator()), no_files);
    const found = try materials(arena.allocator(), document);
    try std.testing.expectEqual(1, found.len);
    try std.testing.expectEqualStrings("paint", found[0].name);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, found[0].colour);
    try std.testing.expectEqual(0.25, found[0].metallic);
    try std.testing.expectEqual(1, found[0].roughness);
    try std.testing.expectEqual([3]f32{ 0, 2, 0 }, found[0].emissive);
    try std.testing.expectEqual(null, found[0].colour_texture);
}

test "a texture whose file is missing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // Without `--textures`, `sltool shp gltf` names the picture but doesn't write it. The
    // material keeps the file's name, and the model is built without the texture.
    const document = try read(gpa,
        \\{"asset": {"version": "2.0"},
        \\ "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
        \\ "textures": [{"source": 0}], "images": [{"uri": "Sabre%20hull.png"}]}
    , no_files);
    const found = try materials(gpa, document);
    try std.testing.expectEqualStrings("Sabre hull.png", found[0].colour_texture.?.missing);
    // A missing buffer still stops the build, because the model can't be built without it.
    try std.testing.expectError(error.MissingBuffer, read(gpa,
        \\{"asset": {"version": "2.0"}, "buffers": [{"byteLength": 4, "uri": "sabre.bin"}]}
    , no_files));
}

test {
    std.testing.refAllDecls(@This());
}
