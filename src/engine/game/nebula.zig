//! `C:\lancer\game\nebula.cpp`: the sky dome and the nebula. `nebula_create` (`0x00498B30`) builds
//! both at start-up, `nebula_select` (`0x00498D00`) applies the script's choice of nebula and
//! `nebula_frame` (`0x00498E10`) centres both on the camera and adds them to the background layer.
//! OpenReliant builds the hardware renderers' dome (`nebula_dome`, `0x00498810`); the software
//! renderer's (`nebula_dome_software`, `0x00498450`) is not ported.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tga = @import("../../formats/tga.zig");
const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const backdrop = @import("backdrop.zig");
const matmanager = @import("matmanager.zig");
const xtrabits = @import("xtrabits.zig");
const Vector = math.Vector;

/// A nebula a script can pick with `SetEnvironmentFXNebula`: a texture, and the colour it gives the
/// fill lights (`nebula_fill_colours`, `0x00504000`).
pub const Nebula = struct {
    texture: []const u8,
    fill: [3]f32,
};

pub const nebulae = [7]Nebula{
    .{ .texture = "neb01", .fill = .{ 0.24, 0.5, 1 } },
    .{ .texture = "neb02", .fill = .{ 0, 1, 0.8 } },
    .{ .texture = "neb03", .fill = .{ 0.33, 0.46, 1 } },
    .{ .texture = "neb04", .fill = .{ 0.74, 1, 0.32 } },
    .{ .texture = "neb05", .fill = .{ 0, 0.75, 1 } },
    .{ .texture = "neb06", .fill = .{ 0.92, 0.66, 0.33 } },
    .{ .texture = "neb07", .fill = .{ 0, 1, 1 } },
};

/// The nebula `nebula_create` shows until a script picks one.
pub const default_nebula = 0;

/// Marks a nebula's texture to be magnified smoothly, stretched as it is over a patch of the sky
/// (`srtexture.Image.Magnify`).
fn softened(image: *srtexture.Image) *srtexture.Image {
    image.magnify = .smooth;
    return image;
}

/// The nebula shown on the smaller patch.
pub const small_patch_nebula = 5;

/// The image the dome's colours come from, in `resource.hog`.
pub const dome_image_name = "starref12.tga";

/// The sky dome: a band of `dome_columns` by `dome_rows` vertices around the camera, untextured and
/// opaque, each vertex coloured by a pixel of `starref12.tga`.
pub const dome_columns = 15;
pub const dome_rows = 8;
pub const dome_vertices = dome_columns * dome_rows;
pub const dome_polygons = (dome_columns - 1) * (dome_rows - 1) * 2;
pub const dome_radius: f32 = 5000;

/// The side of `starref12.tga`, in pixels: `nebula_dome` scales each coordinate to the last pixel
/// (`0x004DC6CC`) and reads the pixel by the low byte of each, so no other size can colour it.
pub const dome_image_size = 256;

/// How far up and down the dome's rows reach against its radius before they are brought to the
/// sphere (`0x004DC56C`), which crowds them toward its top and bottom.
const dome_stretch: f32 = 5;

/// The triangles of one row of the dome's quads, which make one strip.
const row_polygons = (dome_columns - 1) * 2;

/// What each of a pixel's bytes is worth in the dome's colours (`0x004DC818`): a 256th, so that a
/// full byte falls just short of 1.
const pixel_share: f32 = 1.0 / 256.0;

/// The dome's mesh (`nebula_dome`), and the colours its object takes from `image`. Each row of
/// quads is one strip of triangles, its records counting down, split along the diagonal from each
/// quad's first corner to the one below its next. The mesh holds no texture coordinates, normals or
/// planes, and no bounds: its object is neither culled nor tested against the view.
pub fn domeMesh(gpa: Allocator, image: tga.Image, colours: *[dome_vertices][4]f32) (Allocator.Error || error{WrongSize})!srapiext.Mesh {
    if (image.width != dome_image_size or image.height != dome_image_size) return error.WrongSize;
    const mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = dome_polygons, .vertices = dome_vertices, .indices = dome_polygons * 3 });
    mesh.surfaces[0] = .{ .polygons = dome_polygons, .material = .onePass(.{ .coordinates = .none, .lit = true, .blend = .off }) };

    // The steps across the columns and down the rows, from -1 to 1 (`0x004DC99C`, `0x004DC998`).
    const across: f32 = 2.0 / @as(comptime_float, dome_columns - 1);
    const down: f32 = 2.0 / @as(comptime_float, dome_rows - 1);
    const last_pixel: f32 = dome_image_size - 1;
    for (mesh.positions, colours, 0..) |*position, *colour, i| {
        // `u` and `v` from 0 to 1 across the columns and down the rows, as the game works them out.
        const u = ((@as(f32, @floatFromInt(i % dome_columns)) * across - 1) + 1) * 0.5;
        const v = ((@as(f32, @floatFromInt(i / dome_columns)) * down - 1) + 1) * 0.5;
        const pixel = image.pixel(@intFromFloat(u * last_pixel), @intFromFloat(v * last_pixel));
        colour.* = .{
            @as(f32, @floatFromInt(pixel[0])) * pixel_share,
            @as(f32, @floatFromInt(pixel[1])) * pixel_share,
            @as(f32, @floatFromInt(pixel[2])) * pixel_share,
            1,
        };
        const angle = u * std.math.tau;
        const direction = math.normalize(.{ @sin(angle), (v - 0.5) * dome_stretch, @cos(angle) });
        position.* = direction * @as(Vector, @splat(dome_radius));
    }
    for (mesh.polygons, 0..) |*polygon, i| {
        polygon.* = .{ .kind = .strip_even, .continues = @intCast(row_polygons - 1 - i % row_polygons), .first = @intCast(i * 3), .count = 3 };
        const row = i / 2 / (dome_columns - 1);
        const column = i / 2 % (dome_columns - 1);
        const at = column + dome_columns * row;
        const corners: [3]usize = if (i % 2 == 0)
            .{ at, at + dome_columns, at + 1 }
        else
            .{ at + dome_columns, at + 1, at + dome_columns + 1 };
        for (corners, mesh.indices[i * 3 ..][0..3]) |corner, *index| index.* = @intCast(corner);
    }
    return mesh;
}

/// The nebula's patches: `patch_divisions` by `patch_divisions` quads on a sphere of `patch_radius`
/// (`sky_patch_create`, `0x00498EA0`), unlit and added, with the texture across each once. Nebula 5
/// shows on the smaller patch.
pub const patch_divisions = 10;
pub const patch_radius: f32 = 5000;
pub const patch_half_angles = [2]f32{ std.math.pi / 4.0, std.math.pi / 5.0 };

/// The patches' orientation until a nebula marker sets it: a yaw of -90 degrees, which faces them
/// toward `-X`.
pub const patch_orientation = math.fromAngles(0, -std.math.pi / 2.0, 0);

/// A patch of a sphere around the camera, `half_angle` each way (`sky_patch_create`): row by row
/// of vertices the yaw steps from `-half_angle` to `half_angle`, and along each row the pitch, each
/// vertex `(0, 0, patch_radius)` turned by both. Each quad is two triangles, split along the
/// diagonal from its first corner to the one below its next.
pub fn patchMesh(gpa: Allocator, half_angle: f32, texture: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    const columns = patch_divisions;
    const rows = patch_divisions;
    const vertex_count = (columns + 1) * (rows + 1);
    const polygon_count = columns * rows * 2;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = polygon_count, .vertices = vertex_count, .indices = polygon_count * 3 });
    errdefer mesh.deinit(gpa);
    const uv = try mesh.addCoordinates(gpa);
    mesh.surfaces[0] = .{ .polygons = polygon_count, .material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .add }), .textures = .{ .{ .image = texture }, .none } };

    const pitch_step = (half_angle - -half_angle) / @as(f32, columns);
    const yaw_step = (half_angle - -half_angle) / @as(f32, rows);
    var yaw = -half_angle;
    var at: usize = 0;
    for (0..rows + 1) |_| {
        var pitch = -half_angle;
        for (0..columns + 1) |_| {
            const turn = math.turned(math.turned(math.identity, .y, yaw), .x, pitch);
            mesh.positions[at] = math.transform(turn, .{ 0, 0, patch_radius });
            at += 1;
            pitch += pitch_step;
        }
        yaw += yaw_step;
    }
    mesh.numberPolygons(3);
    const du = 1 / @as(f32, columns);
    const dv = 1 / @as(f32, rows);
    var index: usize = 0;
    for (0..rows) |row| {
        const top = @as(f32, @floatFromInt(row)) * dv;
        const bottom = top + dv;
        for (0..columns) |column| {
            const left = @as(f32, @floatFromInt(column)) * du;
            const right = left + du;
            const first = row * (columns + 1) + column;
            const corners = [6]usize{ first, first + columns + 2, first + 1, first, first + columns + 1, first + columns + 2 };
            const coordinates = [6][2]f32{ .{ left, top }, .{ right, bottom }, .{ right, top }, .{ left, top }, .{ left, bottom }, .{ right, bottom } };
            for (corners, coordinates, mesh.indices[index..][0..6], uv[index..][0..6]) |corner, c, *i, *t| {
                i.* = @intCast(corner);
                t.* = c;
            }
            index += 6;
        }
    }
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// The sky as `nebula_create` builds it: the dome (`sky_dome`, `0x0058A6A4`) and the two patches
/// (`nebula_patch`, `nebula_patch_small`), each a mesh and its object, and which shows.
pub const Sky = struct {
    dome_mesh: srapiext.Mesh,
    /// The dome object's own colours, from `starref12.tga`.
    dome_colours: [dome_vertices][4]f32,
    dome_levels: [1]srapiext.Level,
    dome: srapiext.MeshObject,
    patch_meshes: [2]srapiext.Mesh,
    patch_levels: [2][1]srapiext.Level,
    patches: [2]srapiext.MeshObject,
    /// The patch shown (`nebula_shown_patch`, `0x0058A100`): the small one for nebula 5.
    shown: u1 = 0,
    /// `nebula_shown` (`0x0058A6B4`).
    nebula: usize = default_nebula,

    /// Builds the dome from `starref12.tga` and both patches with nebula 0's texture
    /// (`nebula_create`).
    pub fn create(gpa: Allocator, textures: *srtexture.Table, image: tga.Image) (matmanager.Error || error{WrongSize})!*Sky {
        const sky = try gpa.create(Sky);
        errdefer gpa.destroy(sky);
        sky.* = .{
            .dome_mesh = undefined,
            .dome_colours = undefined,
            .dome_levels = undefined,
            .dome = undefined,
            .patch_meshes = undefined,
            .patch_levels = undefined,
            .patches = undefined,
        };
        sky.dome_mesh = try domeMesh(gpa, image, &sky.dome_colours);
        errdefer sky.dome_mesh.deinit(gpa);
        sky.dome_levels = .{.{ .mesh = &sky.dome_mesh, .until = std.math.inf(f32) }};
        // Coloured by its own colours, never culled, always clipped.
        sky.dome = .{
            .flags = .{ .baked_object = true, .always_drawn = true, .not_culled = true },
            .position = @splat(0),
            .radius = sky.dome_mesh.radius,
            .levels = &sky.dome_levels,
            .baked = &sky.dome_colours,
        };
        const texture = softened(try matmanager.textureRequire(textures, nebulae[default_nebula].texture));
        var made: usize = 0;
        errdefer for (sky.patch_meshes[0..made]) |mesh| mesh.deinit(gpa);
        for (&sky.patch_meshes, &sky.patch_levels, &sky.patches, patch_half_angles) |*mesh, *levels, *patch, half_angle| {
            mesh.* = try patchMesh(gpa, half_angle, texture);
            made += 1;
            levels.* = .{.{ .mesh = mesh, .until = std.math.inf(f32) }};
            patch.* = .{
                .flags = .{ .owns_mesh = true, .not_culled = true },
                .position = @splat(0),
                .orientation = patch_orientation,
                .radius = mesh.radius,
                .levels = levels,
            };
        }
        return sky;
    }

    pub fn destroy(sky: *Sky, gpa: Allocator) void {
        sky.dome_mesh.deinit(gpa);
        for (sky.patch_meshes) |mesh| mesh.deinit(gpa);
        gpa.destroy(sky);
    }

    /// Shows nebula `nebula` (`nebula_select`): its texture on its patch, and its colour on the
    /// fill lights.
    pub fn select(sky: *Sky, textures: *srtexture.Table, nebula: usize, lights: *backdrop.Lights) (matmanager.Error || error{InvalidNebula})!void {
        if (nebula >= nebulae.len) return error.InvalidNebula;
        lights.getPtr(.fill_02).colour = nebulae[nebula].fill;
        lights.getPtr(.fill_10).colour = nebulae[nebula].fill;
        sky.shown = @intFromBool(nebula == small_patch_nebula);
        sky.patch_meshes[sky.shown].surfaces[0].textures[0] = .{ .image = softened(try matmanager.textureRequire(textures, nebulae[nebula].texture)) };
        sky.nebula = nebula;
    }

    /// Centres the dome and the nebula on the camera and adds them to the background layer
    /// (`nebula_frame`); the software renderer shows no nebula.
    pub fn frame(sky: *Sky, gpa: Allocator, scene: *srcore.Scene, context: *const srapi.Context) Allocator.Error!void {
        const patch = &sky.patches[sky.shown];
        sky.dome.position = context.camera.position;
        patch.position = context.camera.position;
        try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &sky.dome }, .background);
        if (context.hardware) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = patch }, .background);
        // OpenReliant's: what a material's reflections show (`srcore.Scene.reflected`).
        try scene.reflected.append(gpa, .{ .mesh = &sky.dome });
        if (context.hardware) try scene.reflected.append(gpa, .{ .mesh = patch });
    }
};

test nebulae {
    try std.testing.expectEqualStrings("neb06", nebulae[small_patch_nebula].texture);
}

test domeMesh {
    const gpa = std.testing.allocator;
    const rgb = try gpa.alloc(u8, 256 * 256 * 3);
    defer gpa.free(rgb);
    @memset(rgb, 0);
    rgb[0..3].* = .{ 128, 64, 32 };
    rgb[(255 * 256 + 255) * 3 ..][0..3].* = .{ 255, 255, 255 };
    const image: tga.Image = .{ .width = 256, .height = 256, .rgb = rgb };

    var colours: [dome_vertices][4]f32 = undefined;
    const mesh = try domeMesh(gpa, image, &colours);
    defer mesh.deinit(gpa);
    try std.testing.expectEqual([4]f32{ 0.5, 0.25, 0.125, 1 }, colours[0]);
    try std.testing.expectEqual([4]f32{ 255.0 / 256.0, 255.0 / 256.0, 255.0 / 256.0, 1 }, colours[dome_vertices - 1]);
    // The top row lies up the dome, at -Y, and every vertex on the sphere.
    try std.testing.expect(mesh.positions[0][1] < 0);
    try std.testing.expect(mesh.positions[dome_vertices - 1][1] > 0);
    try std.testing.expectApproxEqAbs(dome_radius, math.length(mesh.positions[0]), 0.5);

    // Each row of quads is a strip of 28 records, counting down.
    try std.testing.expectEqual(srapiext.Polygon{ .kind = .strip_even, .continues = 27, .first = 0, .count = 3 }, mesh.polygons[0]);
    try std.testing.expectEqual(0, mesh.polygons[27].continues);
    try std.testing.expectEqual(27, mesh.polygons[28].continues);
    try std.testing.expectEqualSlices(u16, &.{ 0, 15, 1, 15, 1, 16 }, mesh.indices[0..6]);
    try std.testing.expectEqualSlices(u16, &.{ 118, 104, 119 }, mesh.indices[mesh.indices.len - 3 ..]);

    const wrong: tga.Image = .{ .width = 1, .height = 1, .rgb = rgb[0..3] };
    try std.testing.expectError(error.WrongSize, domeMesh(gpa, wrong, &colours));
}

test patchMesh {
    const gpa = std.testing.allocator;
    var texture: srtexture.Image = .{ .levels = &.{} };
    const mesh = try patchMesh(gpa, std.math.pi / 4.0, &texture);
    defer mesh.deinit(gpa);
    try std.testing.expectEqual(121, mesh.positions.len);
    try std.testing.expectEqual(200, mesh.polygons.len);

    // The middle vertex lies straight ahead; the first row's first vertex down and to the left,
    // with +Y down.
    const centre = mesh.positions[5 * 11 + 5];
    try std.testing.expectApproxEqAbs(0, centre[0], 1e-2);
    try std.testing.expectApproxEqAbs(0, centre[1], 1e-2);
    try std.testing.expectApproxEqAbs(patch_radius, centre[2], 1e-2);
    try std.testing.expect(mesh.positions[0][0] < 0 and mesh.positions[0][1] > 0);

    try std.testing.expectEqualSlices(u16, &.{ 0, 12, 1, 0, 11, 12 }, mesh.indices[0..6]);
    try std.testing.expectEqual([2]f32{ 0.1, 0.1 }, mesh.uv[0].?[1]);
    try std.testing.expectEqual([2]f32{ 0, 0.1 }, mesh.uv[0].?[4]);
    try std.testing.expectApproxEqAbs(patch_radius, mesh.radius, 1);
}

test Sky {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, backdrop.testing.names);
    defer textures.deinit(gpa);
    const rgb = try gpa.alloc(u8, 256 * 256 * 3);
    defer gpa.free(rgb);
    @memset(rgb, 0);

    const sky = try Sky.create(gpa, &textures.table, .{ .width = 256, .height = 256, .rgb = rgb });
    defer sky.destroy(gpa);
    var lights = backdrop.initialLights();

    // Nebula 5 shows on the small patch and colours both fill lights; its texture, as each
    // patch's, is magnified smoothly.
    try std.testing.expectEqual(.smooth, sky.patch_meshes[0].surfaces[0].textures[0].image.magnify);
    try sky.select(&textures.table, small_patch_nebula, &lights);
    try std.testing.expectEqual(1, sky.shown);
    try std.testing.expectEqual(.smooth, sky.patch_meshes[1].surfaces[0].textures[0].image.magnify);
    try std.testing.expectEqual(nebulae[small_patch_nebula].fill, lights.get(.fill_10).colour);
    try std.testing.expectError(error.InvalidNebula, sky.select(&textures.table, nebulae.len, &lights));

    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var context: srapi.Context = .{
        .camera = .{ .position = .{ 1, 2, 3 }, .orientation = math.identity },
        .projection = .init(640, 480, srapi.full_screen, .{ 0.6, 0.8 }),
    };
    try sky.frame(gpa, &scene, &context);
    try std.testing.expectEqual(2, scene.layers.get(.background).items.len);
    try std.testing.expectEqual(context.camera.position, sky.patches[1].position);
    // The software renderer shows the dome alone.
    scene.clear();
    context.hardware = false;
    try sky.frame(gpa, &scene, &context);
    try std.testing.expectEqual(1, scene.layers.get(.background).items.len);
}
