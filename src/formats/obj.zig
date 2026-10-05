//! Wavefront OBJ, as modelling tools such as Blender export it: what `sltool shp from-obj` builds
//! a model from (`shp/from_obj.zig`). It reads positions (`v`), texture coordinates (`vt`),
//! normals (`vn`), faces (`f`, a polygon of any number of corners, made a fan of triangles),
//! objects and groups (`o`, `g`), and the material each face takes (`usemtl`). Other statements,
//! such as `mtllib` and smoothing groups, are passed over.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A corner of a face: its position, and its texture coordinates and normal where it has them,
/// as indices into the file's lists.
pub const Corner = struct {
    position: u32,
    uv: ?u32 = null,
    normal: ?u32 = null,
};

/// A triangle, with the material its object took when it was listed.
pub const Triangle = struct {
    corners: [3]Corner,
    material: ?[]const u8,
};

/// The faces listed under one `o` or `g` statement, or before any.
pub const Object = struct {
    name: []const u8,
    triangles: []Triangle,
    /// No faces of its own: the place of a glTF file's node without a mesh, as three corners round
    /// it (`gltf.triangles`), which the model builder makes an attachment or a point where its name
    /// says, and leaves out otherwise.
    marker: bool = false,
};

pub const File = struct {
    positions: [][3]f32,
    uvs: [][2]f32,
    normals: [][3]f32,
    objects: []Object,
};

pub const Error = Allocator.Error || error{
    /// A number that doesn't read as one, or a statement with too few of them.
    BadNumber,
    /// A face with fewer than three corners, or a corner naming a position, texture coordinate or
    /// normal the file doesn't have.
    BadFace,
};

/// The OBJ file `text`, which the result points into, read into `arena`.
pub fn parse(arena: Allocator, text: []const u8) Error!File {
    var positions: std.ArrayList([3]f32) = .empty;
    var uvs: std.ArrayList([2]f32) = .empty;
    var normals: std.ArrayList([3]f32) = .empty;
    var objects: std.ArrayList(Object) = .empty;
    var triangles: std.ArrayList(Triangle) = .empty;
    var name: []const u8 = "";
    var material: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, std.mem.sliceTo(raw, '#'), " \t\r");
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const keyword = words.next() orelse continue;
        if (std.mem.eql(u8, keyword, "v")) {
            try positions.append(arena, try numbers(3, &words));
        } else if (std.mem.eql(u8, keyword, "vt")) {
            try uvs.append(arena, try numbers(2, &words));
        } else if (std.mem.eql(u8, keyword, "vn")) {
            try normals.append(arena, try numbers(3, &words));
        } else if (std.mem.eql(u8, keyword, "o") or std.mem.eql(u8, keyword, "g")) {
            if (triangles.items.len > 0) try objects.append(arena, .{ .name = name, .triangles = try triangles.toOwnedSlice(arena) });
            name = std.mem.trim(u8, line[keyword.len..], " \t");
        } else if (std.mem.eql(u8, keyword, "usemtl")) {
            material = std.mem.trim(u8, line[keyword.len..], " \t");
        } else if (std.mem.eql(u8, keyword, "f")) {
            var corners: std.ArrayList(Corner) = .empty;
            while (words.next()) |word| try corners.append(arena, try corner(word, positions.items.len, uvs.items.len, normals.items.len));
            if (corners.items.len < 3) return error.BadFace;
            // A polygon as a fan from its first corner.
            for (1..corners.items.len - 1) |at| {
                try triangles.append(arena, .{ .corners = .{ corners.items[0], corners.items[at], corners.items[at + 1] }, .material = material });
            }
        }
    }
    if (triangles.items.len > 0) try objects.append(arena, .{ .name = name, .triangles = try triangles.toOwnedSlice(arena) });
    return .{ .positions = positions.items, .uvs = uvs.items, .normals = normals.items, .objects = objects.items };
}

/// The next `count` numbers of `words`; a texture coordinate's third, where it has one, is passed
/// over.
fn numbers(comptime count: usize, words: *std.mem.TokenIterator(u8, .any)) Error![count]f32 {
    var out: [count]f32 = undefined;
    for (&out) |*value| {
        const word = words.next() orelse return error.BadNumber;
        value.* = std.fmt.parseFloat(f32, word) catch return error.BadNumber;
    }
    return out;
}

/// A corner as `f` gives it: `v`, `v/vt`, `v//vn` or `v/vt/vn`, each counted from 1, or from the
/// end of its list where negative.
fn corner(word: []const u8, positions: usize, uvs: usize, normals: usize) Error!Corner {
    var fields = std.mem.splitScalar(u8, word, '/');
    const position = try index(fields.next().?, positions) orelse return error.BadFace;
    const uv = if (fields.next()) |text| try index(text, uvs) else null;
    const normal = if (fields.next()) |text| try index(text, normals) else null;
    return .{ .position = position, .uv = uv, .normal = normal };
}

/// The index `text` names in a list of `count`, or null for an empty field.
fn index(text: []const u8, count: usize) Error!?u32 {
    if (text.len == 0) return null;
    const number = std.fmt.parseInt(i64, text, 10) catch return error.BadFace;
    const at: i64 = if (number < 0) @as(i64, @intCast(count)) + number else number - 1;
    if (at < 0 or at >= count) return error.BadFace;
    return @intCast(at);
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const file = try parse(arena.allocator(),
        \\# A quad and a triangle, in two objects.
        \\mtllib ship.mtl
        \\v 0 0 0
        \\v 1 0 0
        \\v 1 1 0
        \\v 0 1 0
        \\vt 0 0
        \\vt 1 1 0
        \\vn 0 0 1
        \\o hull
        \\usemtl yank_2
        \\f 1/1/1 2/2/1 3/2/1 4/1/1
        \\o gun_muzzle:3
        \\f -1//1 -2//1 -3//1
    );
    try std.testing.expectEqual(4, file.positions.len);
    try std.testing.expectEqual(2, file.uvs.len);
    try std.testing.expectEqual(2, file.objects.len);
    // The quad as a fan of two triangles, with its material.
    const hull = file.objects[0];
    try std.testing.expectEqualStrings("hull", hull.name);
    try std.testing.expectEqual(2, hull.triangles.len);
    try std.testing.expectEqual([3]u32{ 0, 2, 3 }, [3]u32{ hull.triangles[1].corners[0].position, hull.triangles[1].corners[1].position, hull.triangles[1].corners[2].position });
    try std.testing.expectEqualStrings("yank_2", hull.triangles[0].material.?);
    // Negative indices count from the end; a corner without texture coordinates has none.
    const muzzle = file.objects[1];
    try std.testing.expectEqualStrings("gun_muzzle:3", muzzle.name);
    try std.testing.expectEqual(Corner{ .position = 3, .normal = 0 }, muzzle.triangles[0].corners[0]);
    // A face naming a position the file doesn't have.
    try std.testing.expectError(error.BadFace, parse(arena.allocator(), "v 0 0 0\nf 1 2 3\n"));
}
