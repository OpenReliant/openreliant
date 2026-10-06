//! The textures `sltool shp from-gltf` writes beside a model for a glTF file's materials
//! (`gltf.Material`), as a mod's pictures and material maps ([Modding](../../../docs/guide/modding.md#material-maps)):
//! for a material whose texture is called `name`,
//!
//! - `name.png`, its colour: its colour texture times its colour, or a picture of its colour alone;
//! - `name_orm.png`, its material map: occlusion, roughness and metalness, from its textures and
//!   values;
//! - `name_normal.png`, its normal map, where it has one;
//! - `name_emissive.png`, the light it gives off, where it gives off any.
//!
//! Every map is as large as the colour picture, which the game needs. A texture of another size is
//! sampled to it, and one that isn't a PNG file is left out, and the log says so.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gltf = @import("../gltf.zig");
const png = @import("../png.zig");
const texels = @import("../texels.zig");
const colour = @import("../../engine/surrender/colour.zig");

const log = std.log.scoped(.gltf);

/// A texture to write: its file's name and its PNG bytes.
pub const File = struct {
    name: []const u8,
    bytes: []const u8,
};

/// The side of the plain picture made for a material without a colour texture.
const plain_side = 4;

/// The textures of `material`, whose texture is called `name`, in `arena`.
pub fn of(arena: Allocator, material: gltf.Material, name: []const u8) Allocator.Error![]const File {
    var files: std.ArrayList(File) = .empty;
    // The colour, which every map takes its size from.
    const texture = try picture(arena, material.colour_texture, material.name, "colour");
    const width: u32 = if (texture) |found| found.width else plain_side;
    const height: u32 = if (texture) |found| found.height else plain_side;
    const pixels = @as(usize, width) * height;
    const base = try arena.alloc(u8, pixels * 4);
    for (0..pixels) |at| {
        const sample: [4]u8 = if (texture) |found| sampled(found, width, height, at) else .{ 255, 255, 255, 255 };
        for (0..3) |channel| base[at * 4 + channel] = colour.level(colour.light(sample[channel]) * material.colour[channel]);
        base[at * 4 + 3] = texels.nearest(u8, texels.unit(u8, sample[3]) * material.colour[3]);
    }
    try files.append(arena, .{ .name = try arena.print("{s}.png", .{name}), .bytes = try encode(arena, width, height, base) });

    // The material map: occlusion in red, roughness in green and metalness in blue, as glTF packs
    // them, each times its value.
    const metal_rough = try picture(arena, material.metal_rough_texture, material.name, "metal and roughness");
    const occlusion = try picture(arena, material.occlusion_texture, material.name, "occlusion");
    const orm = try arena.alloc(u8, pixels * 4);
    for (0..pixels) |at| {
        const parts = if (metal_rough) |found| sampled(found, width, height, at) else [4]u8{ 255, 255, 255, 255 };
        orm[at * 4 ..][0..4].* = .{
            if (occlusion) |found| sampled(found, width, height, at)[0] else 255,
            texels.nearest(u8, texels.unit(u8, parts[1]) * material.roughness),
            texels.nearest(u8, texels.unit(u8, parts[2]) * material.metallic),
            255,
        };
    }
    try files.append(arena, .{ .name = try arena.print("{s}_orm.png", .{name}), .bytes = try encode(arena, width, height, orm) });

    if (try picture(arena, material.normal_texture, material.name, "normal")) |normals| {
        const map = try arena.alloc(u8, pixels * 4);
        for (0..pixels) |at| map[at * 4 ..][0..4].* = sampled(normals, width, height, at);
        try files.append(arena, .{ .name = try arena.print("{s}_normal.png", .{name}), .bytes = try encode(arena, width, height, map) });
    }

    // The light it gives off, encoded as the colour is, held to full brightness.
    if (@reduce(.Max, @as(@Vector(3, f32), material.emissive)) > 0) {
        const glow = try picture(arena, material.emissive_texture, material.name, "emissive");
        const map = try arena.alloc(u8, pixels * 4);
        for (0..pixels) |at| {
            const sample: [4]u8 = if (glow) |found| sampled(found, width, height, at) else .{ 255, 255, 255, 255 };
            for (0..3) |channel| map[at * 4 + channel] = colour.level(colour.light(sample[channel]) * material.emissive[channel]);
            map[at * 4 + 3] = 255;
        }
        try files.append(arena, .{ .name = try arena.print("{s}_emissive.png", .{name}), .bytes = try encode(arena, width, height, map) });
    }
    return files.items;
}

/// The picture of `image`, a texture of `material`'s for `role`; null where there is none, or it
/// isn't a PNG file it can read, which the log says.
fn picture(arena: Allocator, image: ?gltf.Image, material: []const u8, comptime role: []const u8) Allocator.Error!?png.Picture {
    const found = image orelse return null;
    return png.read(arena, found.bytes) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.NotAPng, error.Corrupt, error.Unsupported, error.BadSize => {
            log.warn("the {s} texture of the material {s} is left out: it isn't a PNG file that can be read ({s})", .{ role, material, @errorName(err) });
            return null;
        },
    };
}

/// The texel of `picture` at pixel `at` of a picture `width` by `height`, the nearest where its
/// size differs.
fn sampled(source: png.Picture, width: u32, height: u32, at: usize) [4]u8 {
    const x = (at % width) * source.width / width;
    const y = (at / width) * source.height / height;
    return source.rgba[(y * source.width + x) * 4 ..][0..4].*;
}

fn encode(arena: Allocator, width: u32, height: u32, rgba: []const u8) Allocator.Error![]const u8 {
    var written: std.Io.Writer.Allocating = .init(arena);
    png.writeRgba(arena, &written.writer, width, height, rgba) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => unreachable, // The size and the pixels are made to match.
    };
    return written.written();
}

test of {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // A plain red, quarter-metallic, half-rough material, glowing green: its colour, its material
    // map and its emissive map, each four pixels square.
    const files = try of(gpa, .{ .name = "paint", .colour = .{ 1, 0, 0, 1 }, .metallic = 0.25, .roughness = 0.5, .emissive = .{ 0, 2, 0 } }, "ship_0");
    try std.testing.expectEqual(3, files.len);
    try std.testing.expectEqualStrings("ship_0.png", files[0].name);
    const paint = try png.read(gpa, files[0].bytes);
    try std.testing.expectEqual(plain_side, paint.width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, paint.rgba[0..4]);
    try std.testing.expectEqualStrings("ship_0_orm.png", files[1].name);
    const orm = try png.read(gpa, files[1].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 255, 128, 64, 255 }, orm.rgba[0..4]);
    try std.testing.expectEqualStrings("ship_0_emissive.png", files[2].name);
    const glow = try png.read(gpa, files[2].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, glow.rgba[0..4]);

    // A colour texture times its colour, its size the maps'; a texture that isn't a PNG is left
    // out.
    var written: std.Io.Writer.Allocating = .init(gpa);
    try png.writeRgba(gpa, &written.writer, 2, 1, &.{ 255, 255, 255, 255, 0, 0, 0, 255 });
    const textured = try of(gpa, .{
        .name = "hull",
        .colour = .{ 0.5, 1, 1, 1 },
        .colour_texture = .{ .bytes = written.written(), .mime = null },
        .normal_texture = .{ .bytes = "not a picture", .mime = "image/jpeg" },
    }, "ship_1");
    try std.testing.expectEqual(2, textured.len);
    const hull = try png.read(gpa, textured[0].bytes);
    try std.testing.expectEqual(2, hull.width);
    try std.testing.expectEqualSlices(u8, &.{ colour.level(0.5), 255, 255, 255, 0, 0, 0, 255 }, hull.rgba);
}
