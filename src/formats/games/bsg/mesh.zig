//! Battlestar Galactica's meshes (`.bmsh`), binary files (`resource.zig`) of a part of a model:
//!
//! - The first section holds the mesh's header, a record for each submesh, and each submesh's
//!   material: a record and the names of up to four textures.
//! - A section of collision data may follow: positions and a tree of boxes. **Unknown:** its
//!   layout ([#1037](https://github.com/OpenReliant/openreliant/issues/1037)).
//! - A section for each submesh holds its triangles and its vertices' attributes, each attribute
//!   an array of its own.
//!
//! The positions and directions are in Direct3D's left-handed frame: X to the right, Y up, and Z
//! forward. A triangle's corners go clockwise seen from its front.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const layout = @import("../../layout.zig");
const resource = @import("resource.zig");

/// The start of every mesh.
pub const version = 4;
pub const kind = 0xABA9717E;

pub const Header = extern struct {
    submeshes: u32,
    _unknown_04: [2]u16,
    _unknown_08: [2]u32,
    _address_10: u32,
    _unknown_14: u32,
    /// The mesh's box: half its size along each axis, and its middle.
    half_size: [3]f32,
    middle: [3]f32,
    /// **Unverified:** the radius of a sphere about the middle.
    radius: f32,
    _unknown_34: u32,

    comptime {
        assert(@sizeOf(Header) == 0x38);
    }
};

/// The size of a submesh's record. **Unknown:** its layout. An environment-mapped submesh's holds
/// the text `spherical`.
pub const submesh_record_size = 184;

/// How a material draws, by its record's first word.
pub const MaterialKind = enum(u32) {
    /// Without a texture.
    untextured = 0,
    /// With its texture.
    textured = 2,
    /// With a texture whose name ends in a frame's number, such as `launchtube main000.tga`.
    animated = 4,
    /// With its texture, and an environment map as its second.
    environment_mapped = 6,
    _,
};

/// How a material's colour joins what is behind it.
pub const Blend = enum(u32) {
    @"opaque" = 0,
    /// Added to it, as lasers, engine glows and particles are.
    additive = 1,
    /// **Unverified:** mixed with it by the texture's alpha, as clouds and skies are.
    blended = 5,
    _,
};

pub const MaterialRecord = extern struct {
    kind: MaterialKind,
    _unknown_04: [10]u32,
    blend: Blend,
    _unknown_30: [13]u32,

    comptime {
        assert(@sizeOf(MaterialRecord) == 100);
        assert(@offsetOf(MaterialRecord, "blend") == 0x2C);
    }
};

/// The items for a material in the first section: its record and its textures' names.
const material_items = 1 + texture_slots;

/// The textures a material can name. The first is its colour; an environment-mapped material's
/// second is its environment map.
pub const texture_slots = 4;

/// The record before a submesh's attributes.
pub const Buffers = extern struct {
    _unknown_00: u32,
    _address_04: u32,
    /// **Unknown:** 3 in every mesh.
    _unknown_08: u32,
    vertex_count: u32,
    _addresses_10: [9]u32,
    index_count: u32,
    _address_38: u32,
    _unknown_3c: [4]u32,

    comptime {
        assert(@sizeOf(Buffers) == 0x4C);
        assert(@offsetOf(Buffers, "index_count") == 0x34);
    }
};

/// The items of a submesh's section, in order. **Unknown:** the last four, empty in every mesh.
pub const Stream = enum(u8) {
    buffers,
    /// The triangles, three 16-bit indices each, padded to a multiple of 4 bytes.
    indices,
    positions,
    normals,
    /// A red, green, blue and alpha float for each vertex.
    colours,
    /// Texture coordinates for the material's first texture.
    uv0,
    /// Texture coordinates for its second.
    uv1,
    _,
};

/// The items of a submesh's section.
const stream_count = 11;

pub const Material = struct {
    record: *align(1) const MaterialRecord,
    /// The textures' names, such as `sh_v2_viper01.tga`, an empty name for none.
    textures: [texture_slots][]const u8,

    /// The name of the texture that gives its colour, or null for none.
    pub fn colour(material: Material) ?[]const u8 {
        return if (material.textures[0].len > 0) material.textures[0] else null;
    }
};

pub const Submesh = struct {
    material: Material,
    positions: []align(1) const [3]f32,
    /// Empty where the submesh has none, as with the attributes below.
    normals: []align(1) const [3]f32,
    colours: []align(1) const [4]f32,
    uvs: [2][]align(1) const [2]f32,
    indices: []align(1) const u16,
};

pub const Error = error{
    NotAMesh,
    /// An attribute holds a different count of vertices from the positions, or an index names a
    /// vertex past them.
    BadSubmesh,
} || resource.Error;

pub const Mesh = struct {
    header: *align(1) const Header,
    submeshes: []const Submesh,
    /// Whether the mesh has collision data.
    collision: bool,

    /// The mesh in `bytes`, its lists in the arena.
    pub fn parse(arena: Allocator, bytes: []const u8) (Error || Allocator.Error)!Mesh {
        const file: resource.Resource = try .parse(arena, bytes);
        if (file.start.version != version or file.start.kind != kind or file.sections.len == 0) return error.NotAMesh;
        const first = file.sections[0];
        const header = layout.view(Header, first.item(0) orelse return error.NotAMesh) catch return error.NotAMesh;
        const count = header.submeshes;
        const records = first.item(1) orelse return error.NotAMesh;
        if (records.len != @as(usize, count) * submesh_record_size) return error.NotAMesh;
        if (first.items.len != 2 + @as(usize, count) * material_items) return error.NotAMesh;
        if (file.sections.len < 1 + @as(usize, count) or file.sections.len > 2 + @as(usize, count)) return error.NotAMesh;

        const submeshes = try arena.alloc(Submesh, count);
        const sections = file.sections[file.sections.len - count ..];
        for (submeshes, sections, 0..) |*submesh, section, index| {
            const items = first.items[2 + index * material_items ..][0..material_items];
            const record = layout.view(MaterialRecord, items[0]) catch return error.NotAMesh;
            var textures: [texture_slots][]const u8 = undefined;
            for (&textures, items[1..]) |*name, item| name.* = std.mem.sliceTo(item, 0);
            submesh.* = try readSubmesh(section, .{ .record = record, .textures = textures });
        }
        return .{ .header = header, .submeshes = submeshes, .collision = file.sections.len == 2 + @as(usize, count) };
    }
};

/// The submesh in `section`, drawn with `material`.
fn readSubmesh(section: resource.Section, material: Material) Error!Submesh {
    if (section.items.len != stream_count) return error.NotAMesh;
    const buffers = layout.view(Buffers, section.items[@backingInt(Stream.buffers)]) catch return error.NotAMesh;
    const vertices = buffers.vertex_count;
    const indices = layout.array(u16, section.items[@backingInt(Stream.indices)], buffers.index_count) catch return error.BadSubmesh;
    if (indices.len % 3 != 0) return error.BadSubmesh;
    for (indices) |at| if (at >= vertices) return error.BadSubmesh;
    return .{
        .material = material,
        .positions = try attribute([3]f32, section, .positions, vertices, true),
        .normals = try attribute([3]f32, section, .normals, vertices, false),
        .colours = try attribute([4]f32, section, .colours, vertices, false),
        .uvs = .{ try attribute([2]f32, section, .uv0, vertices, false), try attribute([2]f32, section, .uv1, vertices, false) },
        .indices = indices,
    };
}

/// The attribute `stream` of a submesh's `vertices`, as `T`s; empty where the submesh has none, and
/// `required` it must have.
fn attribute(comptime T: type, section: resource.Section, stream: Stream, vertices: u32, required: bool) Error![]align(1) const T {
    const bytes = section.items[@backingInt(stream)];
    if (bytes.len == 0 and !required) return &.{};
    if (bytes.len != @as(usize, vertices) * @sizeOf(T)) return error.BadSubmesh;
    return std.mem.bytesAsSlice(T, bytes);
}

/// Builds meshes, for tests.
pub const testing = struct {
    pub const Part = struct {
        texture: []const u8,
        blend: Blend = .@"opaque",
        positions: []const [3]f32,
        normals: []const [3]f32 = &.{},
        uvs: []const [2]f32 = &.{},
        indices: []const u16,
    };

    /// A mesh of a submesh for each of `parts`, with an empty collision section.
    pub fn build(arena: Allocator, parts: []const Part) Allocator.Error![]u8 {
        var header = std.mem.zeroes(Header);
        header.submeshes = @intCast(parts.len);
        var first: std.ArrayList([]const u8) = .empty;
        try first.append(arena, try arena.dupe(u8, std.mem.asBytes(&header)));
        try first.append(arena, try arena.alloc(u8, parts.len * submesh_record_size));
        // The first section, filled in below, and a collision section of no items.
        var sections: std.ArrayList([]const []const u8) = .empty;
        try sections.appendSlice(arena, &.{ &.{}, &.{} });
        for (parts) |part| {
            var record = std.mem.zeroes(MaterialRecord);
            record.kind = .textured;
            record.blend = part.blend;
            try first.append(arena, try arena.dupe(u8, std.mem.asBytes(&record)));
            try first.append(arena, try std.mem.concat(arena, u8, &.{ part.texture, "\x00" }));
            for (1..texture_slots) |_| try first.append(arena, "");

            var buffers = std.mem.zeroes(Buffers);
            buffers._unknown_08 = 3;
            buffers.vertex_count = @intCast(part.positions.len);
            buffers.index_count = @intCast(part.indices.len);
            const index_bytes = try arena.alloc(u8, (part.indices.len * 2 + 3) / 4 * 4);
            @memset(index_bytes, 0);
            @memcpy(index_bytes[0 .. part.indices.len * 2], std.mem.sliceAsBytes(part.indices));
            const items = try arena.alloc([]const u8, stream_count);
            @memset(items, "");
            items[@backingInt(Stream.buffers)] = try arena.dupe(u8, std.mem.asBytes(&buffers));
            items[@backingInt(Stream.indices)] = index_bytes;
            items[@backingInt(Stream.positions)] = std.mem.sliceAsBytes(part.positions);
            items[@backingInt(Stream.normals)] = std.mem.sliceAsBytes(part.normals);
            items[@backingInt(Stream.uv0)] = std.mem.sliceAsBytes(part.uvs);
            try sections.append(arena, items);
        }
        sections.items[0] = first.items;
        return resource.testing.build(arena, version, kind, sections.items);
    }
};

test Mesh {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try testing.build(arena, &.{
        .{
            .texture = "sh_v2_viper01.tga",
            .positions = &.{ .{ 0, 0, 600 }, .{ -100, 0, 0 }, .{ 100, 0, 0 } },
            .normals = &.{ .{ 0, 1, 0 }, .{ 0, 1, 0 }, .{ 0, 1, 0 } },
            .uvs = &.{ .{ 0.5, 0 }, .{ 0, 1 }, .{ 1, 1 } },
            .indices = &.{ 0, 1, 2 },
        },
        .{
            .texture = "Colonial laser standard.tga",
            .blend = .additive,
            .positions = &.{ .{ 0, 0, 0 }, .{ 0, 1, 0 }, .{ 1, 0, 0 } },
            .indices = &.{ 2, 1, 0 },
        },
    });
    const mesh: Mesh = try .parse(arena, bytes);
    try std.testing.expect(mesh.collision);
    try std.testing.expectEqual(2, mesh.submeshes.len);
    const hull = mesh.submeshes[0];
    try std.testing.expectEqualStrings("sh_v2_viper01.tga", hull.material.colour().?);
    try std.testing.expectEqual(.textured, hull.material.record.kind);
    try std.testing.expectEqual(600, hull.positions[0][2]);
    try std.testing.expectEqual(3, hull.uvs[0].len);
    try std.testing.expectEqual(0, hull.uvs[1].len);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, &@as([3]u16, hull.indices[0..3].*));
    const laser = mesh.submeshes[1];
    try std.testing.expectEqual(.additive, laser.material.record.blend);
    try std.testing.expectEqual(0, laser.normals.len);
}
