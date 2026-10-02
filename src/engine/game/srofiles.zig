//! `C:\lancer\game\srofiles.cpp`: Surrender meshes from `.SHP` models. `mesh_build` (`0x004A3040`)
//! makes a part's mesh for one level of detail and gives each run of faces with the same shading
//! and material a surface of its own; `look` is its rule.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Pointer = @import("../../engine.zig").Pointer;
const shp = @import("../../formats/shp.zig");
const tcache = @import("../../formats/tcache.zig");
const math = @import("../surrender/math.zig");
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const bigfile = @import("bigfile.zig");
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const Material = srapiext.Material;
const Vector = math.Vector;

/// What decides a face's look besides its shading.
pub const Conditions = struct {
    /// Whether `Lmaps` in the settings' `Device` section, `light_maps` (`0x005D5618`), is 1, as it
    /// is unless set.
    light_maps: bool = true,
    /// The part's `lightmap` flag.
    part_lightmap: bool = false,
    /// A hardware renderer rather than the software one.
    hardware: bool = true,
};

pub const Texture = union(enum) {
    none,
    /// The face's material, by the mesh's texture coordinates.
    material,
    /// `l` and the material's name, by the mesh's texture coordinates.
    light_map,
    /// One of the Direct3D driver's highlight textures, by coordinates from the normals.
    highlight: u3,
};

pub const Pass = struct {
    texture: Texture,
    /// Coloured by the vertex lighting, else by white.
    lit: bool,
    blend: Material.Blend,
};

pub const Look = struct {
    first: Pass,
    /// Drawn over the first.
    second: ?Pass = null,
    /// Lines along the edges the face's edge mask leaves unset, instead of the triangle.
    lines: bool = false,
};

/// Mode 10, which `mesh_build` takes for `lit_additive` and `shp.Face.Shading.Mode` does not name.
const lit_additive_again: shp.Face.Shading.Mode = @enumFromInt(10);

/// Whether a face of shading `mode` shows its material's texture, so that `mesh_build` looks the
/// texture up: every mode past the untextured ones.
fn showsTexture(mode: shp.Face.Shading.Mode) bool {
    return switch (mode) {
        .untextured, .wire, .untextured_additive => false,
        else => true,
    };
}

/// The look `mesh_build` gives a face. A sub-mode above 7 on `lit_highlight` does not occur; the
/// driver would take it for an address, and this takes its low three bits.
pub fn look(shading: shp.Face.Shading, conditions: Conditions) Look {
    const untextured: Pass = .{ .texture = .none, .lit = true, .blend = .off };
    const textured: Pass = .{ .texture = .material, .lit = true, .blend = .off };
    return switch (shading.mode) {
        .untextured => .{ .first = untextured },
        .wire => .{ .first = untextured, .lines = true },
        .untextured_additive => .{ .first = .{ .texture = .none, .lit = true, .blend = .add } },
        .unlit => .{ .first = .{ .texture = .material, .lit = false, .blend = .off } },
        .unlit_additive => .{ .first = .{ .texture = .material, .lit = false, .blend = .add } },
        .unlit_blended => .{ .first = .{ .texture = .material, .lit = false, .blend = .alpha } },
        .lit => .{
            .first = textured,
            .second = if (conditions.light_maps and conditions.part_lightmap and conditions.hardware)
                .{ .texture = .light_map, .lit = false, .blend = .add }
            else
                null,
        },
        .lit_highlight => .{
            .first = textured,
            .second = if (conditions.light_maps)
                .{ .texture = .{ .highlight = @truncate(shading.sub_mode) }, .lit = true, .blend = .add }
            else
                null,
        },
        .lit_additive, lit_additive_again => .{ .first = .{ .texture = .material, .lit = true, .blend = .add } },
        // The rest leave the material zero.
        _ => .{ .first = .{ .texture = .none, .lit = false, .blend = .off } },
    };
}

/// A level's material's two textures, each a `T` that is `none` where it has none: its own, and
/// its light map.
fn MaterialImages(comptime T: type, comptime none: T) type {
    return struct {
        material: T = none,
        light_map: T = none,

        /// What a pass that shows `texture` draws with: nothing, one of the two, or the highlight
        /// texture `highlight` makes of its index.
        fn pass(images: @This(), texture: Texture, comptime highlight: fn (u3) T) T {
            return switch (texture) {
                .none => none,
                .material => images.material,
                .light_map => images.light_map,
                .highlight => |index| highlight(index),
            };
        }
    };
}

/// The textures `mesh_build` puts in a material.
pub const Images = MaterialImages(Pointer(tcache.Image), .null);

/// A look as the mesh's material record holds it. The first image is the face's material whatever
/// the look.
pub fn material(face_look: Look, images: Images) Material {
    var record: Material = .{
        .two_pass = face_look.second != null,
        ._unknown_01 = 0,
        .coordinates = .{ coordinates(face_look.first.texture), .none },
        .lit = .{ face_look.first.lit, false },
        .blend = .{ face_look.first.blend, .off },
        .image = .{ images.material, .null },
    };
    if (face_look.second) |second| {
        record.coordinates[1] = coordinates(second.texture);
        record.lit[1] = second.lit;
        record.blend[1] = second.blend;
        record.image[1] = images.pass(second.texture, highlightIndex);
    }
    return record;
}

/// A highlight texture as the material record holds it, by its index in place of an image.
fn highlightIndex(index: u3) Pointer(tcache.Image) {
    return @enumFromInt(index);
}

fn coordinates(texture: Texture) Material.Coordinates {
    return switch (texture) {
        .none => .none,
        .material, .light_map => .mesh,
        .highlight => .generated,
    };
}

// --- mesh_build --------------------------------------------------------------------------------

/// The letter `mesh_build` puts before a material's name to find its texture.
pub const Prefix = enum {
    /// In flight.
    none,
    /// `g`, while the loadout screen loads the ships (`loadout_ship_models`, `0x00524976`).
    loadout_ships,
    /// `r`, while it loads the missiles and guns (`loadout_weapon_models`, `0x00524977`).
    loadout_weapons,

    fn letter(prefix: Prefix) ?u8 {
        return switch (prefix) {
            .none => null,
            .loadout_ships => 'g',
            .loadout_weapons => 'r',
        };
    }
};

/// What `mesh_build` takes from the game besides the model.
pub const Settings = struct {
    /// `Lmaps` in the settings' `Device` section (`light_maps`).
    light_maps: bool = true,
    /// A hardware renderer (`sr + 0x1AC`).
    hardware: bool = true,
    prefix: Prefix = .none,
    /// The model's objects get colours of their own to fade and cloak by: the model's header
    /// flag `cloak`, or a ship type's model in a multiplayer mission (`model_load`).
    cloak: bool = false,
    /// A static light stands in this part's class, which `staticLightsMark` works out, so its
    /// meshes take baked colours for `staticLightsBake` to fill.
    static_light: bool = false,
    /// **Improvement:** the steady lights shine on what stands near as real lights, as the
    /// blinking ones do, rather than being baked into the meshes of their parts' class
    /// (`staticLightsBake`). The model keeps it for its objects (`Loaded.real_lights`).
    real_lights: bool = false,
};

/// The most surfaces a mesh holds (`mesh_create`, `0x004C4440`).
pub const max_surfaces = 20;

pub const Error = matmanager.Error || error{
    /// A level with more runs of faces of one look than a mesh holds surfaces: the game stops
    /// with `oops`.
    TooManySurfaces,
    /// A face naming a vertex its level lacks, which the game does not check.
    CornerOutOfRange,
};

/// The textures of a level's material that the texture table found.
const Found = MaterialImages(?*srtexture.Image, null);

/// A third of a face's `sort_bias` is added to the depth its polygon is sorted by
/// (`0x004DC7D4`).
const sort_bias_share: f32 = 1.0 / 3.0;

/// A part's mesh for one level of detail (`mesh_build`), its textures required from `textures`,
/// or null for a level without faces. Adds to `flags` what the part's object needs: always lit and
/// hiding the sun, and by the part's flags and faces, baked colours, geomorphing, and coordinates
/// from the normals for the second pass. At the finest level it renumbers the faces `face_lists`
/// hold, the part's tree nodes' and face groups', to the polygons the merged fans leave.
///
/// A fan's records become one polygon where `fanMerges` says so; a wire face becomes a polygon of
/// two corners for each edge it draws. `mesh_texel_areas` (`0x004C4090`) then finds each textured
/// polygon's area in texels, which only the software driver reads; OpenReliant leaves it out.
///
/// **Improvement:** a vertex without a counterpart in the next level (`-1`, in a few coarser
/// levels of capital ships and a station) makes the game read whatever lies before that level's
/// vertices; OpenReliant morphs it toward itself.
pub fn build(
    gpa: Allocator,
    textures: *srtexture.Table,
    part: *const shp.PartData,
    level: usize,
    settings: Settings,
    flags: *srapiext.ObjectFlags,
    face_lists: []const []u32,
) Error!?srapiext.Mesh {
    const source = part.meshes[level];
    const faces = source.faces;
    if (faces.len == 0) return null;
    for (faces) |face| {
        for (face.vertices) |corner| if (corner >= source.vertices.len) return error.CornerOutOfRange;
    }
    const part_flags = part.part.flags;
    const static_light = part_flags.has_static_light or settings.static_light;
    flags.lit = true;
    flags.sun_occluder = true;
    if (settings.cloak) flags.baked_object = true;
    if (static_light) flags.baked_mesh = true;
    const coarser: ?shp.Mesh = if (level + 1 < part.meshes.len) part.meshes[level + 1] else null;
    if (coarser != null) {
        if (part_flags.geomorph_normals) flags.geomorph_normals = true;
        if (part_flags.geomorph_positions) flags.geomorph_positions = true;
    }

    // Polygons and indices, as the faces will make them. A wire face counts one polygon more than
    // it makes.
    var polygon_count: usize = 0;
    var index_count: usize = 0;
    var any_face_flags = false;
    {
        var walk: Polygons = .{ .faces = faces };
        while (walk.next()) |step| {
            const face = faces[step.face];
            const mode = face.shading.mode;
            if ((mode == .lit_highlight or mode == .lit_additive) and settings.light_maps) flags.normals_second = true;
            if (face.flags.cap or face.flags.two_sided) any_face_flags = true;
            const wire = face.shading.mode == .wire;
            polygon_count += step.count + @intFromBool(wire);
            index_count += if (wire) 2 * step.count else 3 + step.extra;
        }
    }

    const vertex_count = source.vertices.len;
    const positions = try gpa.alloc(Vector, vertex_count);
    errdefer gpa.free(positions);
    const normals = try gpa.alloc(Vector, vertex_count);
    errdefer gpa.free(normals);
    const morph_positions: ?[]Vector = if (coarser != null and part_flags.geomorph_positions) try gpa.alloc(Vector, vertex_count) else null;
    errdefer if (morph_positions) |m| gpa.free(m);
    const morph_normals: ?[]Vector = if (coarser != null and part_flags.geomorph_normals) try gpa.alloc(Vector, vertex_count) else null;
    errdefer if (morph_normals) |m| gpa.free(m);
    const baked: ?[][4]f32 = if (static_light) try gpa.alloc([4]f32, vertex_count) else null;
    errdefer if (baked) |b| gpa.free(b);
    if (baked) |b| @memset(b, @splat(0));
    const polygons = try gpa.alloc(srapiext.Polygon, polygon_count);
    errdefer gpa.free(polygons);
    @memset(polygons, .{ .kind = .triangle, .continues = 0, .first = 0, .count = 0 });
    const indices = try gpa.alloc(u16, index_count);
    errdefer gpa.free(indices);
    const uv = try gpa.alloc([2]f32, index_count);
    errdefer gpa.free(uv);
    const planes = try gpa.alloc(srapiext.Plane, polygon_count);
    errdefer gpa.free(planes);
    @memset(planes, .{ .normal = @splat(0), .distance = 0 });
    const face_flags: ?[]shp.Face.Flags = if (any_face_flags) try gpa.alloc(shp.Face.Flags, polygon_count) else null;
    errdefer if (face_flags) |all| gpa.free(all);
    if (face_flags) |all| @memset(all, .{});
    const biases = try gpa.alloc(f32, polygon_count);
    errdefer gpa.free(biases);
    @memset(biases, 0);
    var surfaces: std.ArrayList(srapiext.Surface) = .empty;
    errdefer surfaces.deinit(gpa);
    // A light-mapped part's second pass takes the first's coordinates.
    const light_mapped = part_flags.lightmap and settings.light_maps;

    // The textures of the materials that textured faces use.
    const found = try gpa.alloc(Found, source.materials.len);
    defer gpa.free(found);
    for (source.materials, found, 0..) |*m, *images, i| {
        images.* = .{};
        const shown = for (faces) |face| {
            if (face.material == i and showsTexture(face.shading.mode)) break true;
        } else false;
        if (!shown) continue;
        var buffer: [1 + @sizeOf(shp.Material)]u8 = undefined;
        images.material = try matmanager.textureRequire(textures, prefixed(&buffer, settings.prefix.letter(), m.name()));
        if (light_mapped) images.light_map = try matmanager.textureRequire(textures, prefixed(&buffer, 'l', m.name()));
    }

    for (source.vertices, 0..) |vertex, i| {
        positions[i] = gameobj.vector(vertex.position);
        normals[i] = gameobj.vector(vertex.normal);
        const next = coarser orelse continue;
        const at = vertex.nextLod() orelse next.vertices.len;
        const counterpart = if (at < next.vertices.len) next.vertices[at] else vertex;
        if (morph_normals) |m| m[i] = gameobj.vector(counterpart.normal);
        if (morph_positions) |m| m[i] = gameobj.vector(counterpart.position);
    }

    const conditions: Conditions = .{ .light_maps = settings.light_maps, .part_lightmap = part_flags.lightmap, .hardware = settings.hardware };
    var polygon: usize = 0;
    var index: usize = 0;
    // The face that began the run of faces the current surface draws.
    var run: ?shp.Face = null;
    var walk: Polygons = .{ .faces = faces };
    while (walk.next()) |step| {
        assert(step.polygon == polygon);
        const f = step.face;
        const face = faces[f];
        if (run == null or !sameRun(run.?, face)) {
            if (surfaces.items.len == max_surfaces) return error.TooManySurfaces;
            const images = if (face.material < found.len) found[face.material] else Found{};
            try surfaces.append(gpa, surface(look(face.shading, conditions), images));
            run = face;
        }
        const current = &surfaces.items[surfaces.items.len - 1];
        const bias = face.sort_bias * sort_bias_share;
        if (face.shading.mode == .wire) {
            const plane = srapi.planeThrough(positions[face.vertices[0]], positions[face.vertices[1]], positions[face.vertices[2]]);
            for (0..face.vertices.len) |edge| {
                if (!edgeDrawn(face, edge)) continue;
                const ends = [2]usize{ edge, (edge + 1) % face.vertices.len };
                polygons[polygon] = .{ .kind = .lines, .continues = 0, .first = @truncate(index), .count = 2 };
                for (ends, 0..) |corner, k| {
                    indices[index + k] = @truncate(face.vertices[corner]);
                    uv[index + k] = .{ face.u[corner], face.v[corner] };
                }
                planes[polygon] = plane;
                if (face_flags) |all| all[polygon] = faceFlags(face);
                biases[polygon] = bias;
                current.polygons += 1;
                polygon += 1;
                index += 2;
            }
            continue;
        }
        const extra = step.extra;
        polygons[polygon] = if (step.merged)
            .{ .kind = .triangle, .continues = 0, .first = @truncate(index), .count = @truncate(extra + 3) }
        else
            .{ .kind = @enumFromInt(@as(u16, @truncate(@intFromEnum(face.polygon)))), .continues = @truncate(face.remaining), .first = @truncate(index), .count = 3 };
        for (0..3) |corner| {
            indices[index + corner] = @truncate(face.vertices[corner]);
            uv[index + corner] = .{ face.u[corner], face.v[corner] };
        }
        // A merged fan's later records each add their last corner.
        for (faces[f + 1 ..][0..extra], index + 3..) |record, at| {
            indices[at] = @truncate(record.vertices[2]);
            uv[at] = .{ record.u[2], record.v[2] };
        }
        if (face_flags) |all| all[polygon] = faceFlags(face);
        biases[polygon] = bias;
        if (step.merged and level == 0) renumber(face_lists, @intCast(polygon), extra);
        current.polygons += 1;
        polygon += 1;
        index += 3 + extra;
    }

    var mesh: srapiext.Mesh = .{
        .positions = positions,
        .normals = normals,
        .morph_positions = morph_positions,
        .morph_normals = morph_normals,
        .baked = baked,
        .polygons = polygons,
        .indices = indices,
        .uv = .{ uv, if (light_mapped) uv else null },
        .planes = planes,
        .face_flags = face_flags,
        .biases = biases,
        .surfaces = try surfaces.toOwnedSlice(gpa),
        .bounds = undefined,
        .radius = undefined,
    };
    srapi.calcPolyNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// A part as `model_load` leaves it for the objects that show it (`part + 0x10C` on): the flags its
/// object takes, and each level's mesh with the depth it is drawn to. A level without faces holds
/// an empty mesh, where the game leaves no mesh at all.
pub const LoadedPart = struct {
    flags: srapiext.ObjectFlags,
    meshes: []srapiext.Mesh,
    levels: []srapiext.Level,
    /// Its meshes for the cloak, where its model can cloak.
    cloaking: ?Cloaking = null,

    fn deinit(part: LoadedPart, gpa: Allocator) void {
        if (part.cloaking) |cloaking| cloaking.deinit(gpa);
        for (part.meshes) |mesh| mesh.deinit(gpa);
        gpa.free(part.meshes);
        gpa.free(part.levels);
    }
};

/// The two mesh sets `model_load` builds for each part of a model that can cloak: the part's own
/// meshes seen through, each surface's first pass blended by alpha (`part + 0x160`), and the
/// cloak's shimmer over each (`cloak_mesh_build`, `0x004A3CB0`; `part + 0x1B4`). Each level of
/// either shares its own level's geometry, owning only its surfaces, and switches at its distance.
pub const Cloaking = struct {
    see_through: []srapiext.Mesh,
    see_through_levels: []srapiext.Level,
    shimmer: []srapiext.Mesh,
    shimmer_levels: []srapiext.Level,

    /// The cloak's texture, which the shimmer shows (`0x004F7400`).
    const image = "cloak64";

    /// The sets for a part whose own levels are `levels`, its shimmer over `shimmer_image`,
    /// coloured by its own colours on a hardware renderer and by white on the software one.
    pub fn build(gpa: Allocator, levels: []const srapiext.Level, shimmer_image: *srtexture.Image, hardware: bool) Allocator.Error!Cloaking {
        const see_through = try gpa.alloc(srapiext.Mesh, levels.len);
        var through_made: usize = 0;
        errdefer {
            for (see_through[0..through_made]) |mesh| gpa.free(mesh.surfaces);
            gpa.free(see_through);
        }
        for (see_through, levels) |*copy, level| {
            copy.* = level.mesh.*;
            copy.surfaces = try gpa.dupe(srapiext.Surface, level.mesh.surfaces);
            for (copy.surfaces) |*run| run.material.blend[0] = .alpha;
            through_made += 1;
        }
        const shimmer = try gpa.alloc(srapiext.Mesh, levels.len);
        var shimmer_made: usize = 0;
        errdefer {
            for (shimmer[0..shimmer_made]) |mesh| gpa.free(mesh.surfaces);
            gpa.free(shimmer);
        }
        for (shimmer, levels) |*over, level| {
            over.* = level.mesh.*;
            over.uv = .{ null, null };
            over.baked = null;
            var polygons: u32 = 0;
            for (level.mesh.surfaces) |run| polygons += run.polygons;
            over.surfaces = try gpa.alloc(srapiext.Surface, 1);
            over.surfaces[0] = .{
                .polygons = polygons,
                .material = .onePass(.{ .coordinates = .generated, .lit = hardware, .blend = .add }),
                .textures = .{ .{ .image = shimmer_image }, .none },
            };
            shimmer_made += 1;
        }
        const through_levels = try gpa.alloc(srapiext.Level, levels.len);
        errdefer gpa.free(through_levels);
        const shimmer_levels = try gpa.alloc(srapiext.Level, levels.len);
        for (levels, through_levels, shimmer_levels, see_through, shimmer) |level, *through, *over, *through_mesh, *over_mesh| {
            through.* = .{ .mesh = through_mesh, .until = level.until };
            over.* = .{ .mesh = over_mesh, .until = level.until };
        }
        return .{ .see_through = see_through, .see_through_levels = through_levels, .shimmer = shimmer, .shimmer_levels = shimmer_levels };
    }

    pub fn deinit(cloaking: Cloaking, gpa: Allocator) void {
        for (cloaking.see_through) |mesh| gpa.free(mesh.surfaces);
        for (cloaking.shimmer) |mesh| gpa.free(mesh.surfaces);
        gpa.free(cloaking.see_through);
        gpa.free(cloaking.shimmer);
        gpa.free(cloaking.see_through_levels);
        gpa.free(cloaking.shimmer_levels);
    }
};

test Cloaking {
    const gpa = std.testing.allocator;
    var mesh = try @import("../surrender/surrenderlib/srmesh.zig").testing.square(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = 1000 }};
    var texture: srtexture.Image = .{ .levels = &.{} };
    const cloaking: Cloaking = try .build(gpa, &levels, &texture, true);
    defer cloaking.deinit(gpa);

    // Seen through: the part's own mesh at the same distance, its surfaces blended by their alpha,
    // and the part's own left as they were.
    const through = cloaking.see_through_levels[0];
    try std.testing.expectEqual(1000, through.until);
    try std.testing.expectEqual(mesh.positions.ptr, through.mesh.positions.ptr);
    try std.testing.expectEqual(.alpha, through.mesh.surfaces[0].material.blend[0]);
    try std.testing.expectEqual(.off, mesh.surfaces[0].material.blend[0]);
    // The shimmer: every polygon in one surface over the texture, lit and added, its coordinates
    // made each frame from the object's own.
    const shimmer = cloaking.shimmer_levels[0].mesh;
    try std.testing.expectEqual(1, shimmer.surfaces.len);
    try std.testing.expectEqual(2, shimmer.surfaces[0].polygons);
    const drawn_with = shimmer.surfaces[0].material;
    try std.testing.expectEqual(.add, drawn_with.blend[0]);
    try std.testing.expectEqual(.generated, drawn_with.coordinates[0]);
    try std.testing.expect(drawn_with.lit[0]);
    try std.testing.expectEqual(&texture, shimmer.surfaces[0].textures[0].image);
    try std.testing.expectEqual(null, shimmer.uv[0]);
    try std.testing.expectEqual(null, shimmer.baked);
}

/// A model's parts, their meshes built (`model_load`, `0x004A44D0`, once it has read the file).
pub const Loaded = struct {
    parts: []LoadedPart,
    /// Whether its steady lights were left out of the bake to shine as real lights
    /// (`Settings.real_lights`), which its objects' lights then cast (`objects.Model.Light.cast`).
    real_lights: bool = false,

    pub fn deinit(loaded: Loaded, gpa: Allocator) void {
        for (loaded.parts) |part| part.deinit(gpa);
        gpa.free(loaded.parts);
    }
};

/// A model file as the game reads and loads it: the `.SHP` model and what `modelLoad` builds of it.
pub const ModelFile = struct {
    model: *const shp.Model,
    loaded: *const Loaded,
};

/// Reads the model `file` from `resources` and loads it with `settings` (`modelLoad`), as the
/// loaders of a ship type's model, of a mounted model and of the cockpit each do. Everything is
/// made in `gpa`, an arena, since none of it is let go but all at once.
pub fn readModel(gpa: Allocator, resources: *const bigfile.Hog, textures: *srtexture.Table, file: []const u8, settings: Settings) !ModelFile {
    const model = try gpa.create(shp.Model);
    model.* = try .parse(gpa, try resources.readFile(gpa, file));
    const loaded = try gpa.create(Loaded);
    loaded.* = try modelLoad(gpa, textures, model, settings, false);
    return .{ .model = model, .loaded = loaded };
}

/// Builds every level of every part of `model` (`model_load`), and bakes the static lights it
/// carries into their vertex colours. `multiplayer_ship` is a ship type's model in a multiplayer
/// mission, which with the model's header flag `cloak` gives its objects colours of their own and
/// each part its meshes for the cloak (`Cloaking`), made once the lights are baked.
pub fn modelLoad(gpa: Allocator, textures: *srtexture.Table, model: *const shp.Model, settings: Settings, multiplayer_ship: bool) Error!Loaded {
    var level_settings = settings;
    level_settings.cloak = model.header.flags.cloak or multiplayer_ship;
    const parts = try gpa.alloc(LoadedPart, model.parts.len);
    var made: usize = 0;
    errdefer {
        for (parts[0..made]) |part| part.deinit(gpa);
        gpa.free(parts);
    }
    const lit_classes = staticLightsMark(model);
    for (model.parts, parts) |*part, *loaded| {
        var part_settings = level_settings;
        part_settings.static_light = lit_classes[@intFromBool(part.part.flags.damaged)];
        const meshes = try gpa.alloc(srapiext.Mesh, part.meshes.len);
        var built: usize = 0;
        errdefer {
            for (meshes[0..built]) |mesh| mesh.deinit(gpa);
            gpa.free(meshes);
        }
        var flags: srapiext.ObjectFlags = .{};
        for (meshes, 0..) |*mesh, level| {
            mesh.* = try build(gpa, textures, part, level, part_settings, &flags, &.{}) orelse empty;
            built += 1;
        }
        const levels = try gpa.alloc(srapiext.Level, meshes.len);
        // One level is always drawn: its object has no set of levels to choose from.
        for (levels, meshes, part.meshes) |*level, *mesh, source| {
            level.* = .{ .mesh = mesh, .until = if (meshes.len > 1) source.lod.switch_distance else std.math.inf(f32) };
        }
        loaded.* = .{ .flags = flags, .meshes = meshes, .levels = levels };
        made += 1;
    }
    if (!settings.real_lights) staticLightsBake(model, parts);
    if (level_settings.cloak) {
        var buffer: [1 + Cloaking.image.len]u8 = undefined;
        const shimmer = try matmanager.textureRequire(textures, prefixed(&buffer, settings.prefix.letter(), Cloaking.image));
        // A part with no meshes has none for the cloak either.
        for (parts) |*part| {
            if (part.levels.len > 0) part.cloaking = try .build(gpa, part.levels, shimmer, settings.hardware);
        }
    }
    return .{ .parts = parts, .real_lights = settings.real_lights };
}

// --- Static lights ------------------------------------------------------------------------

/// A light an attachment holds, baked into the meshes of the parts of its class when the model is
/// loaded rather than lit each frame.
pub const StaticLight = struct {
    /// In the model's frame: where the attachment sits on the part it hangs from.
    position: Vector,
    colour: [3]f32,
    /// Scales both how far it reaches and the colour it adds.
    brightness: f32,
    /// How far it reaches, past which it adds nothing.
    radius: f32,
};

/// Whether an attachment holds a static light (`static_lights_mark`): a light with a brightness
/// above zero that does not blink.
fn isStaticLight(attachment: shp.Attachment) bool {
    return attachment.kind == .light and attachment.light_brightness > 0 and
        attachment.blink[0] +% attachment.blink[1] == 0;
}

/// The light an attachment of a part holds, in the model's frame.
fn staticLight(part: *const shp.PartData, attachment: shp.Attachment) StaticLight {
    return .{
        .position = gameobj.vector(attachment.position.add(part.part.position)),
        .colour = @import("objects.zig").steadyColour(attachment.light()),
        .brightness = attachment.light_brightness,
        .radius = attachment.light_brightness * attachment.light_range,
    };
}

/// `static_lights_mark` (`0x004A4070`): whether each class of parts holds a static light, the
/// intact parts first and the damaged ones second. Every part of a class whose light exists takes
/// baked colours, since a light shines on its whole class.
pub fn staticLightsMark(model: *const shp.Model) [2]bool {
    var lit: [2]bool = .{ false, false };
    for (model.parts) |part| {
        for (part.attachments) |attachment| {
            if (isStaticLight(attachment)) lit[@intFromBool(part.part.flags.damaged)] = true;
        }
    }
    return lit;
}

/// `static_lights_bake` (`0x004A4310`): bakes every static light into the meshes of every level of
/// the parts of its own class.
pub fn staticLightsBake(model: *const shp.Model, parts: []LoadedPart) void {
    for (model.parts) |*part| {
        for (part.attachments) |attachment| {
            if (!isStaticLight(attachment)) continue;
            const light = staticLight(part, attachment);
            for (model.parts, parts) |*other, *loaded| {
                if (other.part.flags.damaged != part.part.flags.damaged) continue;
                for (loaded.meshes) |*mesh| staticLightBake(light, other.part.position, mesh);
            }
        }
    }
}

/// `static_light_bake` (`0x004A4130`): adds a light to one mesh's baked colours. A vertex within
/// the light's radius that faces it takes the light times `((radius - distance) / radius)` squared
/// and the cosine of the angle between its normal and the light, which is what the falloff below
/// works out to for a normal of unit length. A baked colour stops at white.
pub fn staticLightBake(light: StaticLight, origin: shp.Vec3, mesh: *srapiext.Mesh) void {
    const baked = mesh.baked orelse return;
    // The light in the part's own frame, where its vertices stand.
    const at = light.position - gameobj.vector(origin);
    const radius = light.radius;
    if (!(radius > 0)) return;
    for (mesh.positions, mesh.normals, baked) |position, normal, *colour| {
        const away = at - position;
        const distance_squared = math.dot(away, away);
        if (distance_squared >= radius * radius) continue;
        const facing = math.dot(away, normal);
        if (facing <= 0) continue;
        const distance = @sqrt(distance_squared);
        const fall = (1 / distance + distance / (radius * radius) - 2 / radius) * facing;
        for (colour[0..3], light.colour) |*channel, c| {
            channel.* = @min(channel.* + fall * light.brightness * c, 1);
        }
    }
}

/// A mesh with nothing in it.
pub const empty: srapiext.Mesh = .{
    .positions = &.{},
    .normals = &.{},
    .polygons = &.{},
    .indices = &.{},
    .uv = .{ null, null },
    .planes = &.{},
    .biases = &.{},
    .surfaces = &.{},
    .bounds = .{ @splat(0), @splat(0) },
    .radius = 0,
};

/// The least dot product of a fan's first record's normal with each later record's for
/// `fanMerges` to merge them, about 2.6 degrees apart (`0x004DCA04`).
const fan_tolerance: f32 = 0.999;

/// Whether a fan's records become one polygon (`fan_merges`, `0x004A2FD0`): a fan's first record,
/// whose normal lies within `fan_tolerance` of each later record's. A fan whose records would run
/// past the level's end is not merged.
pub fn fanMerges(faces: []const shp.Face, f: usize) bool {
    const face = faces[f];
    if (face.polygon != .fan) return false;
    if (f > 0 and faces[f - 1].remaining != 0) return false;
    if (face.remaining >= faces.len - f) return false;
    const normal = gameobj.vector(face.normal);
    for (faces[f + 1 ..][0..face.remaining]) |record| {
        if (!(math.dot(normal, gameobj.vector(record.normal)) >= fan_tolerance)) return false;
    }
    return true;
}

/// Whether a wire face draws its edge from corner `edge` to the next: its edge mask leaves the
/// edge's bit unset. `mesh_build` reads the mask's low three bits, one for each corner.
fn edgeDrawn(face: shp.Face, edge: usize) bool {
    return face.edge_mask & (@as(u32, 1) << @intCast(edge)) == 0;
}

/// How many edges a wire face draws (`edgeDrawn`).
fn edgesDrawn(face: shp.Face) usize {
    var count: usize = 0;
    for (0..face.vertices.len) |edge| count += @intFromBool(edgeDrawn(face, edge));
    return count;
}

/// Whether a face falls in the same run of faces as `first`, the run's first, and so on its
/// surface: the same material, and the same shading as the game compares it, its mode and its
/// sub-mode, the shading's low byte.
fn sameRun(first: shp.Face, face: shp.Face) bool {
    return first.shading.mode == face.shading.mode and first.shading.sub_mode == face.shading.sub_mode and
        first.material == face.material;
}

/// The polygons `build` makes of a level's faces, face by face: a wire face makes one for each
/// edge it draws, a fan that merges (`fanMerges`) one for all its records, and any other face one.
pub const Polygons = struct {
    faces: []const shp.Face,
    face: usize = 0,
    polygon: usize = 0,

    pub const Step = struct {
        /// The face, whether it merges with the records after it, and how many it takes in.
        face: usize,
        merged: bool,
        extra: u32,
        /// The first polygon it makes, and how many it makes.
        polygon: usize,
        count: usize,
    };

    pub fn next(walk: *Polygons) ?Step {
        if (walk.face >= walk.faces.len) return null;
        const face = walk.faces[walk.face];
        const wire = face.shading.mode == .wire;
        const merged = !wire and fanMerges(walk.faces, walk.face);
        const count: usize = if (wire) edgesDrawn(face) else 1;
        const step: Step = .{ .face = walk.face, .merged = merged, .extra = if (merged) face.remaining else 0, .polygon = walk.polygon, .count = count };
        walk.face += 1 + step.extra;
        walk.polygon += count;
        return step;
    }
};

/// The polygon that face `face` of a level's `faces` goes into (`Polygons`), or null past the last
/// face or for a wire face that draws no edge. A wire face goes into the first of its polygons.
pub fn polygonOf(faces: []const shp.Face, face: usize) ?usize {
    var walk: Polygons = .{ .faces = faces };
    while (walk.next()) |step| {
        if (face <= step.face + step.extra) return if (step.count > 0) step.polygon else null;
    }
    return null;
}

/// The cap and two-sided flags, all a polygon keeps of its face's.
fn faceFlags(face: shp.Face) shp.Face.Flags {
    return .{ .cap = face.flags.cap, .two_sided = face.flags.two_sided };
}

/// Renumbers faces after a fan's `extra` later records merged into polygon `polygon`: the later
/// records become the polygon, and the faces after them move down.
fn renumber(face_lists: []const []u32, polygon: u32, extra: u32) void {
    for (face_lists) |list| {
        for (list) |*face| {
            if (face.* <= polygon) continue;
            face.* = if (face.* - polygon < extra) polygon else face.* - extra;
        }
    }
}

/// A run's surface: its look, with the textures its material found.
fn surface(face_look: Look, images: Found) srapiext.Surface {
    const found: MaterialImages(srapiext.Texture, .none) = .{ .material = .of(images.material), .light_map = .of(images.light_map) };
    var textures: [2]srapiext.Texture = .{ found.material, .none };
    if (face_look.second) |second| textures[1] = found.pass(second.texture, highlightTexture);
    var record = material(face_look, .{});
    record.image = .{ .null, .null };
    return .{ .material = record, .textures = textures };
}

/// A highlight texture as a surface draws it.
fn highlightTexture(index: u3) srapiext.Texture {
    return .{ .highlight = index };
}

/// A texture's `name` after a letter, if any, in `buffer`.
fn prefixed(buffer: []u8, letter: ?u8, name: []const u8) []const u8 {
    const start: usize = if (letter) |l| blk: {
        buffer[0] = l;
        break :blk 1;
    } else 0;
    @memcpy(buffer[start..][0..name.len], name);
    return buffer[0 .. start + name.len];
}

fn testShading(mode: u4, sub_mode: u4) shp.Face.Shading {
    return .{ .mode = @enumFromInt(mode), .sub_mode = sub_mode, ._unused = 0 };
}

test look {
    const lit = look(testShading(6, 1), .{});
    try std.testing.expectEqual(Texture.material, lit.first.texture);
    try std.testing.expect(lit.first.lit);
    try std.testing.expectEqual(null, lit.second);

    const mapped = look(testShading(6, 1), .{ .part_lightmap = true });
    try std.testing.expectEqual(Texture.light_map, mapped.second.?.texture);
    try std.testing.expectEqual(Material.Blend.add, mapped.second.?.blend);
    try std.testing.expect(!mapped.second.?.lit);
    // The software renderer and the light maps setting each leave the light map out.
    try std.testing.expectEqual(null, look(testShading(6, 1), .{ .part_lightmap = true, .hardware = false }).second);
    try std.testing.expectEqual(null, look(testShading(6, 1), .{ .part_lightmap = true, .light_maps = false }).second);

    const shiny = look(testShading(7, 3), .{});
    try std.testing.expectEqual(Texture{ .highlight = 3 }, shiny.second.?.texture);
    try std.testing.expect(shiny.second.?.lit);
    try std.testing.expectEqual(null, look(testShading(7, 3), .{ .light_maps = false }).second);

    try std.testing.expect(look(testShading(1, 1), .{}).lines);
    try std.testing.expectEqual(Material.Blend.alpha, look(testShading(5, 0), .{}).first.blend);
    try std.testing.expect(!look(testShading(4, 2), .{}).first.lit);
    try std.testing.expectEqual(look(testShading(8, 1), .{}), look(testShading(10, 1), .{}));
}

test showsTexture {
    try std.testing.expect(!showsTexture(.untextured_additive));
    try std.testing.expect(showsTexture(.unlit));
    try std.testing.expect(showsTexture(lit_additive_again));
}

test MaterialImages {
    const images: Images = .{ .material = @enumFromInt(0x0060_0000), .light_map = @enumFromInt(0x0060_1000) };
    try std.testing.expectEqual(images.light_map, images.pass(.light_map, highlightIndex));
    try std.testing.expectEqual(images.material, images.pass(.material, highlightIndex));
    try std.testing.expectEqual(.null, images.pass(.none, highlightIndex));
    try std.testing.expectEqual(4, @intFromEnum(images.pass(.{ .highlight = 4 }, highlightIndex)));
    // Found, a level's material's textures give a surface's; one not found, none.
    var texture: srtexture.Image = .{ .levels = &.{} };
    const found: MaterialImages(srapiext.Texture, .none) = .{ .material = .of(&texture), .light_map = .of(null) };
    try std.testing.expectEqual(&texture, found.pass(.material, highlightTexture).image);
    try std.testing.expect(found.pass(.light_map, highlightTexture) == .none);
    try std.testing.expectEqual(srapiext.Texture{ .highlight = 2 }, found.pass(.{ .highlight = 2 }, highlightTexture));
}

test material {
    const texture: Pointer(tcache.Image) = @enumFromInt(0x0060_0000);
    const light_map: Pointer(tcache.Image) = @enumFromInt(0x0060_1000);

    // The bytes `mesh_build` writes for a light-mapped `lit` face: two passes, the mesh's
    // coordinates for both, the first lit, the second added.
    const mapped = material(look(testShading(6, 0), .{ .part_lightmap = true }), .{ .material = texture, .light_map = light_map });
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 1, 1, 0, 0, 1 }, std.mem.asBytes(&mapped)[0..8]);
    try std.testing.expectEqual(light_map, mapped.image[1]);

    // A highlight: coordinates from the normals, the second pass lit, its image the index.
    const shiny = material(look(testShading(7, 5), .{}), .{ .material = texture });
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 1, 2, 1, 1, 0, 1 }, std.mem.asBytes(&shiny)[0..8]);
    try std.testing.expectEqual(5, @intFromEnum(shiny.image[1]));

    const blended = material(look(testShading(5, 0), .{}), .{ .material = texture });
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0, 0, 3, 0 }, std.mem.asBytes(&blended)[0..8]);
    try std.testing.expectEqual(texture, blended.image[0]);
}

fn testFace(material_index: u32, mode: u4, corners: [3]u32) shp.Face {
    var face = std.mem.zeroes(shp.Face);
    face.material = material_index;
    face.shading = testShading(mode, 0);
    face.vertices = corners;
    face.normal = .{ .x = 0, .y = 0, .z = -1 };
    return face;
}

fn testVertex(x: f32, y: f32, next: i32) shp.Vertex {
    return .{ .position = .{ .x = x, .y = y, .z = 0 }, .normal = .{ .x = 0, .y = 0, .z = -1 }, .unknown_18 = 0, .next_lod_vertex = next };
}

fn testMaterial(name: []const u8) shp.Material {
    var m = std.mem.zeroes(shp.Material);
    @memcpy(m.name_bytes[0..name.len], name);
    return m;
}

fn testPart(meshes: []shp.Mesh, flags: shp.Part.Flags) shp.PartData {
    var part = std.mem.zeroes(shp.Part);
    part.flags = flags;
    return .{ .part = part, .meshes = meshes, .attachments = &.{}, .tracks = &.{}, .nodes = &.{}, .node_faces = &.{} };
}

test "build: surfaces, planes and a wire face's edges" {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, &.{ "hull", "lhull" });
    defer textures.deinit(gpa);

    var vertices = [_]shp.Vertex{ testVertex(-100, -100, -1), testVertex(100, -100, -1), testVertex(100, 100, -1), testVertex(-100, 100, -1) };
    var wire = testFace(1, 1, .{ 0, 1, 2 });
    // The edge from the second corner to the third is left out.
    wire.edge_mask = 0b010;
    var faces = [_]shp.Face{ testFace(0, 6, .{ 0, 2, 1 }), testFace(0, 6, .{ 0, 3, 2 }), wire };
    var materials = [_]shp.Material{ testMaterial("hull"), testMaterial("wire") };
    var meshes = [_]shp.Mesh{.{ .lod = .{ .switch_distance = 0 }, .vertices = &vertices, .faces = &faces, .materials = &materials }};
    const part = testPart(&meshes, std.mem.zeroes(shp.Part.Flags));

    var flags: srapiext.ObjectFlags = .{};
    const mesh = (try build(gpa, &textures.table, &part, 0, .{}, &flags, &.{})).?;
    defer mesh.deinit(gpa);

    try std.testing.expectEqual(srapiext.ObjectFlags{ .lit = true, .sun_occluder = true }, flags);
    try std.testing.expectEqual(2, mesh.surfaces.len);
    try std.testing.expectEqual(2, mesh.surfaces[0].polygons);
    try std.testing.expectEqual(Material.Coordinates.mesh, mesh.surfaces[0].material.coordinates[0]);
    try std.testing.expect(mesh.surfaces[0].textures[0] == .image);
    // The wire face's material is not textured, so nothing is looked up for it.
    try std.testing.expectEqual(Material.Coordinates.none, mesh.surfaces[1].material.coordinates[0]);
    try std.testing.expect(mesh.surfaces[1].textures[0] == .none);
    try std.testing.expectEqual(2, mesh.surfaces[1].polygons);

    // Two edges as lines, and the polygon the wire face counts over them left empty.
    try std.testing.expectEqual(5, mesh.polygons.len);
    try std.testing.expectEqual(srapiext.Polygon{ .kind = .lines, .continues = 0, .first = 6, .count = 2 }, mesh.polygons[2]);
    try std.testing.expectEqualSlices(u16, &.{ 0, 2, 1, 0, 3, 2, 0, 1, 2, 0 }, mesh.indices);
    try std.testing.expectEqual(0, mesh.polygons[4].count);
    // The wire face goes into the first of its lines; one that draws no edge, into none.
    try std.testing.expectEqual(2, polygonOf(&faces, 2));
    faces[2].edge_mask = 0b111;
    try std.testing.expectEqual(null, polygonOf(&faces, 2));

    // The triangles face -Z; the lines keep their face's plane, which faces +Z.
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, -1 }), mesh.planes[0].normal);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 1 }), mesh.planes[3].normal);
    try std.testing.expectEqual(@as(Vector, .{ -100, -100, 0 }), mesh.bounds[0]);
    try std.testing.expectApproxEqAbs(141.42136, mesh.radius, 1e-3);
    try std.testing.expectEqual(null, mesh.uv[1]);
    try std.testing.expectEqual(null, mesh.face_flags);
}

test "build: fans merge when flat, and the part's face lists follow" {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, &.{ "hull", "lhull" });
    defer textures.deinit(gpa);

    var vertices = [_]shp.Vertex{ testVertex(0, 0, -1), testVertex(100, 0, -1), testVertex(100, 100, -1), testVertex(0, 100, -1), testVertex(-50, 50, -1) };
    var faces = [_]shp.Face{ testFace(0, 0, .{ 0, 1, 2 }), testFace(0, 0, .{ 0, 2, 3 }), testFace(0, 0, .{ 0, 3, 4 }), testFace(0, 0, .{ 0, 1, 4 }) };
    for (faces[0..3], 0..) |*face, i| {
        face.polygon = .fan;
        face.remaining = @intCast(2 - i);
    }
    var materials = [_]shp.Material{testMaterial("flat")};
    var meshes = [_]shp.Mesh{.{ .lod = .{ .switch_distance = 0 }, .vertices = &vertices, .faces = &faces, .materials = &materials }};
    const part = testPart(&meshes, std.mem.zeroes(shp.Part.Flags));

    var nodes = [_]u32{ 0, 1, 2, 3 };
    var flags: srapiext.ObjectFlags = .{};
    const merged = (try build(gpa, &textures.table, &part, 0, .{}, &flags, &.{&nodes})).?;
    defer merged.deinit(gpa);
    try std.testing.expectEqual(2, merged.polygons.len);
    try std.testing.expectEqual(srapiext.Polygon{ .kind = .triangle, .continues = 0, .first = 0, .count = 5 }, merged.polygons[0]);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, 4, 0, 1, 4 }, merged.indices[0..8]);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1 }, &nodes);
    // Each of the fan's records goes into its one polygon.
    for ([_]usize{ 0, 0, 0, 1 }, 0..) |expected, face| try std.testing.expectEqual(expected, polygonOf(&faces, face));
    try std.testing.expectEqual(null, polygonOf(&faces, 4));

    // A record turned by more than the tolerance, here about 5.7 degrees, keeps the fan's records
    // apart.
    faces[1].normal = .{ .x = 0, .y = 0.0995037, .z = -0.9950372 };
    const apart = (try build(gpa, &textures.table, &part, 0, .{}, &flags, &.{})).?;
    defer apart.deinit(gpa);
    try std.testing.expectEqual(4, apart.polygons.len);
    try std.testing.expectEqual(srapiext.Polygon{ .kind = .fan, .continues = 1, .first = 3, .count = 3 }, apart.polygons[1]);
}

test "build: light maps, baked colours and geomorphing" {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, &.{ "hull", "lhull" });
    defer textures.deinit(gpa);

    // The third vertex has no counterpart in the coarser level.
    var fine = [_]shp.Vertex{ testVertex(0, 0, 0), testVertex(100, 0, 1), testVertex(0, 100, -1) };
    var coarse = [_]shp.Vertex{ testVertex(10, 10, -1), testVertex(90, 10, -1) };
    var fine_faces = [_]shp.Face{testFace(0, 6, .{ 0, 1, 2 })};
    var coarse_faces = [_]shp.Face{testFace(0, 6, .{ 0, 1, 1 })};
    var materials = [_]shp.Material{testMaterial("hull")};
    var meshes = [_]shp.Mesh{
        .{ .lod = .{ .switch_distance = 5000 }, .vertices = &fine, .faces = &fine_faces, .materials = &materials },
        .{ .lod = .{ .switch_distance = 10000 }, .vertices = &coarse, .faces = &coarse_faces, .materials = &materials },
    };
    var part_flags = std.mem.zeroes(shp.Part.Flags);
    part_flags.lightmap = true;
    part_flags.has_static_light = true;
    part_flags.geomorph_positions = true;
    part_flags.geomorph_normals = true;
    const part = testPart(&meshes, part_flags);

    var flags: srapiext.ObjectFlags = .{};
    const mesh = (try build(gpa, &textures.table, &part, 0, .{}, &flags, &.{})).?;
    defer mesh.deinit(gpa);
    try std.testing.expect(flags.baked_mesh and flags.geomorph_positions and flags.geomorph_normals);
    try std.testing.expectEqual(3, mesh.baked.?.len);
    try std.testing.expectEqual(@as(Vector, .{ 10, 10, 0 }), mesh.morph_positions.?[0]);
    try std.testing.expectEqual(@as(Vector, .{ 0, 100, 0 }), mesh.morph_positions.?[2]);
    // The light map over the texture, by the same coordinates.
    const lit = mesh.surfaces[0];
    try std.testing.expect(lit.material.two_pass);
    try std.testing.expect(lit.textures[1] == .image and lit.textures[1].image != lit.textures[0].image);
    try std.testing.expectEqual(mesh.uv[0].?.ptr, mesh.uv[1].?.ptr);

    // The coarsest level has nothing to morph toward.
    const last = (try build(gpa, &textures.table, &part, 1, .{}, &flags, &.{})).?;
    defer last.deinit(gpa);
    try std.testing.expectEqual(null, last.morph_positions);

    // A software renderer draws no light map, though the coordinates are still shared.
    const software = (try build(gpa, &textures.table, &part, 0, .{ .hardware = false }, &flags, &.{})).?;
    defer software.deinit(gpa);
    try std.testing.expect(!software.surfaces[0].material.two_pass);
}

test "build: faults the game stops on or does not check" {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, &.{ "hull", "lhull" });
    defer textures.deinit(gpa);

    var vertices = [_]shp.Vertex{ testVertex(0, 0, -1), testVertex(100, 0, -1), testVertex(0, 100, -1) };
    var faces: [max_surfaces + 1]shp.Face = undefined;
    for (&faces, 0..) |*face, i| face.* = testFace(@intCast(i % 2), 0, .{ 0, 1, 2 });
    var materials = [_]shp.Material{ testMaterial("a"), testMaterial("b") };
    var meshes = [_]shp.Mesh{.{ .lod = .{ .switch_distance = 0 }, .vertices = &vertices, .faces = &faces, .materials = &materials }};
    const part = testPart(&meshes, std.mem.zeroes(shp.Part.Flags));
    var flags: srapiext.ObjectFlags = .{};
    try std.testing.expectError(error.TooManySurfaces, build(gpa, &textures.table, &part, 0, .{}, &flags, &.{}));

    faces[0].vertices[2] = 3;
    try std.testing.expectError(error.CornerOutOfRange, build(gpa, &textures.table, &part, 0, .{}, &flags, &.{}));
}

test sameRun {
    const first = testFace(0, 7, .{ 0, 1, 2 });
    // The shading's bits past the mode and the sub-mode are not compared.
    var face = first;
    face.shading._unused = 1;
    try std.testing.expect(sameRun(first, face));
    face.shading.sub_mode = 3;
    try std.testing.expect(!sameRun(first, face));
    face = first;
    face.material = 1;
    try std.testing.expect(!sameRun(first, face));
}

test edgesDrawn {
    var face = testFace(0, 1, .{ 0, 1, 2 });
    try std.testing.expectEqual(3, edgesDrawn(face));
    face.edge_mask = 0b010;
    try std.testing.expectEqual(2, edgesDrawn(face));
    try std.testing.expect(!edgeDrawn(face, 1));
    // The bits past the third are not read.
    face.edge_mask = 0b1111_1000;
    try std.testing.expectEqual(3, edgesDrawn(face));
}

test fanMerges {
    var faces = [_]shp.Face{ testFace(0, 0, .{ 0, 1, 2 }), testFace(0, 0, .{ 0, 2, 3 }) };
    faces[0].polygon = .fan;
    faces[0].remaining = 1;
    faces[1].polygon = .fan;
    try std.testing.expect(fanMerges(&faces, 0));
    // A later record is not a fan's first.
    try std.testing.expect(!fanMerges(&faces, 1));
    // Records that would run past the end.
    faces[0].remaining = 2;
    try std.testing.expect(!fanMerges(&faces, 0));
}

/// A light attachment sitting `at` along X, reaching `range` times its brightness.
fn testLight(id: u32, at: f32, brightness: f32, range: f32) shp.Attachment {
    var attachment = std.mem.zeroes(shp.Attachment);
    attachment.kind = .light;
    attachment.id = id;
    attachment.position = .{ .x = at, .y = 0, .z = 0 };
    attachment.light_brightness = brightness;
    attachment.light_range = range;
    return attachment;
}

test staticLightsMark {
    var meshes = [_]shp.Mesh{};
    var lights = [_]shp.Attachment{testLight(3, 0, 1, 100)};
    var intact = testPart(&meshes, std.mem.zeroes(shp.Part.Flags));
    intact.attachments = &lights;
    var damaged_flags = std.mem.zeroes(shp.Part.Flags);
    damaged_flags.damaged = true;
    const damaged = testPart(&meshes, damaged_flags);

    // A light on an intact part marks that class alone.
    var parts = [_]shp.PartData{ intact, damaged };
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &parts, .trailing_bytes = 0 };
    try std.testing.expectEqual([2]bool{ true, false }, staticLightsMark(&model));

    // A light that blinks, or one with no brightness, is not baked at all.
    lights[0].blink = .{ 5, 0 };
    try std.testing.expectEqual([2]bool{ false, false }, staticLightsMark(&model));
    lights[0].blink = .{ 0, 0 };
    lights[0].light_brightness = 0;
    try std.testing.expectEqual([2]bool{ false, false }, staticLightsMark(&model));
}

test staticLightsBake {
    // An intact part holding a red light, and a damaged one, each with a vertex halfway out to
    // the light, facing it.
    var meshes = [_]shp.Mesh{};
    var lights = [_]shp.Attachment{testLight(@intFromEnum(shp.Attachment.Light.red), 100, 1, 100)};
    var intact = testPart(&meshes, std.mem.zeroes(shp.Part.Flags));
    intact.attachments = &lights;
    var damaged_flags = std.mem.zeroes(shp.Part.Flags);
    damaged_flags.damaged = true;
    var parts = [_]shp.PartData{ intact, testPart(&meshes, damaged_flags) };
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &parts, .trailing_bytes = 0 };
    var positions = [_]Vector{.{ 50, 0, 0 }};
    var normals = [_]Vector{.{ 1, 0, 0 }};
    var colours: [2][1][4]f32 = @splat(@splat(@splat(0)));
    var built: [2]srapiext.Mesh = @splat(empty);
    var loaded: [2]LoadedPart = undefined;
    for (&built, &colours, &loaded) |*mesh, *baked, *part| {
        mesh.positions = &positions;
        mesh.normals = &normals;
        mesh.baked = baked;
        part.* = .{ .flags = .{}, .meshes = mesh[0..1], .levels = &.{} };
    }

    // The light shines on the parts of its own class alone.
    staticLightsBake(&model, &loaded);
    try std.testing.expectApproxEqAbs(0.25, colours[0][0][0], 1e-5);
    try std.testing.expectEqual(0, colours[1][0][0]);
    // A light past red adds no colour.
    lights[0].id = @intFromEnum(shp.Attachment.Light.cyan);
    staticLightsBake(&model, &loaded);
    try std.testing.expectApproxEqAbs(0.25, colours[0][0][0], 1e-5);
    try std.testing.expectEqual(0, colours[0][0][1]);
    try std.testing.expectEqual(0, colours[0][0][2]);
}

test "a model loaded with real lights keeps them out of the bake for its objects" {
    const gpa = std.testing.allocator;
    var meshes = [_]shp.Mesh{};
    var lights = [_]shp.Attachment{testLight(@intFromEnum(shp.Attachment.Light.red), 100, 1, 100)};
    var parts = [_]shp.PartData{testPart(&meshes, std.mem.zeroes(shp.Part.Flags))};
    parts[0].attachments = &lights;
    const model: shp.Model = .{ .header = std.mem.zeroes(shp.Header), .parts = &parts, .trailing_bytes = 0 };
    const textures = try srtexture.testing.Textures.init(gpa, &.{});
    defer textures.deinit(gpa);
    for ([_]bool{ false, true }) |real| {
        const loaded = try modelLoad(gpa, &textures.table, &model, .{ .real_lights = real }, false);
        defer loaded.deinit(gpa);
        try std.testing.expectEqual(real, loaded.real_lights);
    }
}

test staticLightBake {
    const gpa = std.testing.allocator;
    // Three vertices facing a light 100 along X: at its foot, halfway out, and past its reach.
    var positions = [_]Vector{ .{ 50, 0, 0 }, .{ 0, 0, 0 }, .{ -200, 0, 0 } };
    var normals = [_]Vector{ .{ 1, 0, 0 }, .{ 1, 0, 0 }, .{ 1, 0, 0 } };
    const baked = try gpa.alloc([4]f32, 3);
    defer gpa.free(baked);
    @memset(baked, @splat(0));
    var mesh = empty;
    mesh.positions = &positions;
    mesh.normals = &normals;
    mesh.baked = baked;

    // Red, brightness 1, reaching 100.
    const light: StaticLight = .{ .position = .{ 100, 0, 0 }, .colour = .{ 1, 0, 0 }, .brightness = 1, .radius = 100 };
    staticLightBake(light, shp.Vec3.zero, &mesh);
    // Halfway out it takes a quarter of the light, the falloff being the square of what is left.
    try std.testing.expectApproxEqAbs(0.25, baked[0][0], 1e-5);
    // A vertex exactly at its reach takes none, and one past it nothing at all.
    try std.testing.expectEqual(0, baked[1][0]);
    try std.testing.expectEqual(0, baked[2][0]);
    // Only the light's own colour is added.
    try std.testing.expectEqual(0, baked[0][1]);
    try std.testing.expectEqual(0, baked[0][2]);

    // A vertex facing away takes nothing, and a second light stops the colour at white.
    normals[0] = .{ -1, 0, 0 };
    const was = baked[0][0];
    staticLightBake(light, shp.Vec3.zero, &mesh);
    try std.testing.expectEqual(was, baked[0][0]);
    normals[0] = .{ 1, 0, 0 };
    for (0..8) |_| staticLightBake(light, shp.Vec3.zero, &mesh);
    try std.testing.expectEqual(1, baked[0][0]);
}

test readModel {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    try bigfile.testing.write(gpa, io, tmp.dir, bigfile.resource_name, &.{.{ .name = "Ship.SHP", .data = shp.testing.buildModel(&buffer) }});
    var resources: bigfile.Hog = try .open(gpa, io, tmp.dir, bigfile.resource_name);
    defer resources.close(gpa);
    const textures = try srtexture.testing.Textures.init(gpa, &.{ "yank_1", "lyank_1", "cloak64" });
    defer textures.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const file = try readModel(arena.allocator(), &resources, &textures.table, "ship.shp", .{});
    try std.testing.expectEqual(1, file.model.parts.len);
    try std.testing.expectEqual(1, file.loaded.parts.len);
}
