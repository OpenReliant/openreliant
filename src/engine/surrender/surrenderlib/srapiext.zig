//! `C:\lancer\surrender\surrenderlib\srAPIext.cpp`: Surrender's frames, the transforms of its scene
//! graph, its meshes' materials, and the scene objects: meshes, sprite sets. The extern structs lay
//! out the game's memory; the rest are OpenReliant's.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../../engine.zig");
const Pointer = engine.Pointer;
const shp = @import("../../../formats/shp.zig");
const tcache = @import("../../../formats/tcache.zig");
const math = @import("../math.zig");
const srlight = @import("srlight.zig");
const srtexture = @import("srtexture.zig");
const Vector = math.Vector;

/// Surrender's transform (`surrenderlib`), `0xB4` bytes, which `frame_create` (`0x004C51C0`)
/// allocates: a node's place relative to its parent frame.
pub const Frame = extern struct {
    _unknown_00: u32,
    /// Such as `GOroot object` for an object's root.
    name: Pointer(u8),
    _unknown_08: [8]u8,
    parent: Pointer(Frame),
    /// **Unknown**, mostly.
    flags: u32,
    /// Row-major 3x3.
    orientation: [9]f32,
    position: shp.Vec3,
    /// **Unknown.** 1.0 when created.
    _unknown_48: f32,
    _unknown_4c: [0x68]u8,

    comptime {
        assert(@offsetOf(Frame, "orientation") == 0x18);
        assert(@offsetOf(Frame, "position") == 0x3C);
        assert(@sizeOf(Frame) == 0xB4);
    }
};

/// How a group of a mesh's polygons is drawn: a first pass and, with `two_pass`, a second over it.
/// Each field but `two_pass` holds one value per pass. A mesh (`mesh_create`, `0x004C4440`) holds a
/// `Group` for each run of polygons, from `+0x64`; the Direct3D driver reads the material as is.
pub const Material = extern struct {
    two_pass: bool,
    _unknown_01: u8,
    /// Where the texture coordinates come from; `none` draws untextured.
    coordinates: [2]Coordinates,
    /// Colour by the vertex lighting, else by white.
    lit: [2]bool,
    blend: [2]Blend,
    /// The texture. Below 8, one of the Direct3D driver's highlight textures.
    image: [2]Pointer(tcache.Image),

    pub const Coordinates = enum(u8) {
        none = 0,
        /// The mesh's own.
        mesh = 1,
        /// Made each frame: from the vertex normals, turned into the camera's frame, where the
        /// object asks (`normals_first`, `normals_second`), `u` being `0.5 + 0.5 * x` and `v`
        /// `0.5 + 0.5 * y`; or the object's own (`own_uv`).
        generated = 2,
        _,
    };

    /// How a pass combines with what is already drawn. Blended polygons are drawn after the rest
    /// of their layer, back to front.
    pub const Blend = enum(u8) {
        /// Replaces it.
        off = 0,
        /// Adds to it.
        add = 1,
        /// Adds to it, scaled by one minus the source alpha.
        premultiplied = 2,
        /// Mixes by the source alpha.
        alpha = 3,
        /// Adds, scaled by the source alpha.
        add_alpha = 4,
        _,
    };

    /// A single pass: where its texture coordinates come from, whether the lighting colours it,
    /// and how it combines with what is drawn.
    pub const Pass = struct {
        coordinates: Coordinates,
        lit: bool,
        blend: Blend,
    };

    /// A material of one pass, whose image its surface's textures hold.
    pub fn onePass(pass: Pass) Material {
        return .{
            .two_pass = false,
            ._unknown_01 = 0,
            .coordinates = .{ pass.coordinates, .none },
            .lit = .{ pass.lit, false },
            .blend = .{ pass.blend, .off },
            .image = .{ .null, .null },
        };
    }

    comptime {
        assert(@offsetOf(Material, "blend") == 6);
        assert(@sizeOf(Material) == 0x10);
    }
};

/// A run of a mesh's polygons with one material.
pub const Group = extern struct {
    polygons: u32,
    material: Material,

    comptime {
        assert(@sizeOf(Group) == 0x14);
    }
};

// --- OpenReliant's scene objects
// --------------------------------------------------------------------

/// A scene object's kind (`+0x00`), which picks its pipeline in `sr_draw_layers`.
pub const Kind = enum(u32) {
    mesh = 1,
    light = 2,
    sprites = 4,
    stars = 7,
    portal = 8,
    _,
};

/// A scene object's flags (`+0x14`).
pub const ObjectFlags = packed struct(u32) {
    /// Left out of the scene by `scene_add`, and of the lights by `mesh_light`.
    hidden: bool = false,
    /// Its polygons are clipped by its portal (`MeshObject.portal`) as well as by the view:
    /// `0x004C5FB0` gives every one of them the portal's clip code (`srapi.Outcode.portal`).
    portal_clipped: bool = false,
    /// The driver sorts all its polygons, farthest first, and draws them at once, as it does
    /// every mesh on the overlay layer (`0x10002D10`).
    sorted: bool = false,
    /// Always its finest level of detail.
    finest: bool = false,
    _unknown_4: bool = false,
    /// A star field takes this frame as its last, so it draws no streaks
    /// (`backdrop_reset_streaks`); `stars_project` clears it.
    fresh: bool = false,
    _unknown_6: u2 = 0,
    /// Lit: its colour, the ambient lights and the rest (`mesh_light`).
    lit: bool = false,
    /// Texture coordinates from the normals for the first pass, and for the second
    /// (`mesh_generated_coordinates`).
    normals_first: bool = false,
    normals_second: bool = false,
    /// Never culled (`mesh_cull`).
    not_culled: bool = false,
    /// Neither tested against the view nor given a level of detail by distance, and always
    /// clipped (`SR_meshpipe_init`): the nebula's patches, the engine glows and the cockpit's
    /// parts.
    always_drawn: bool = false,
    /// Not tested against the view, and always clipped (`0x004C5E20`).
    unbounded: bool = false,
    /// Its mesh is its own, freed with it (`0x004C4D50`): a piece of the break-up's
    /// (`model_slice`).
    owns_mesh: bool = false,
    /// Its triangles hide the sun, lessening its visibility (`0x10001FD0`).
    sun_occluder: bool = false,
    geomorph_positions: bool = false,
    geomorph_normals: bool = false,
    /// Coloured by the mesh's baked colours, or by the object's own.
    baked_mesh: bool = false,
    baked_object: bool = false,
    _unknown_20: bool = false,
    /// Made with texture coordinates of its own for the first pass, and for the second
    /// (`mesh_object_create`), which stand in for the generated ones (`own_uv`).
    own_first: bool = false,
    own_second: bool = false,
    _unknown_23: u9 = 0,

    comptime {
        assert(@bitOffsetOf(ObjectFlags, "lit") == 8);
        assert(@bitOffsetOf(ObjectFlags, "not_culled") == 11);
        assert(@bitOffsetOf(ObjectFlags, "sun_occluder") == 15);
        assert(@bitOffsetOf(ObjectFlags, "baked_object") == 19);
        assert(@bitOffsetOf(ObjectFlags, "own_first") == 21);
        assert(@bitOffsetOf(ObjectFlags, "always_drawn") == 12);
    }
};

/// A texture a material names: one of the driver's highlight textures, or an image of the table.
pub const Texture = union(enum) {
    none,
    highlight: u3,
    image: *srtexture.Image,

    /// The image, or none where there is none.
    pub fn of(found: ?*srtexture.Image) Texture {
        return if (found) |image| .{ .image = image } else .none;
    }
};

/// What a run of a mesh's polygons, a set of sprites or a star field is drawn with, as OpenReliant
/// holds it: the material as the game lays it out, less its images, which `textures` holds.
pub const Surface = struct {
    /// For a mesh's run, how many polygons.
    polygons: u32 = 0,
    material: Material,
    textures: [2]Texture = .{ .none, .none },

    /// A glowing sprite's: `image` added over what is behind it, lit by the sprite's own colour, as
    /// the sun's sprites, the lights and the glows of the explosions and the missiles' trails are.
    pub fn glow(image: ?*srtexture.Image) Surface {
        return .{
            .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add }),
            .textures = .{ .of(image), .none },
        };
    }
};

test "Surface.glow" {
    const glowing: Surface = .glow(null);
    try std.testing.expectEqual(Texture.none, glowing.textures[0]);
    try std.testing.expectEqual(Material.Blend.add, glowing.material.blend[0]);
}

/// A polygon of a mesh (`mesh+0x38`): a run of the mesh's indices.
pub const Polygon = struct {
    kind: PolygonKind,
    /// Records of the same strip or fan still to come, from the `.SHP` face: the driver draws a
    /// polygon with those after it in one go.
    continues: u16,
    first: u16,
    count: u16,
};

pub const PolygonKind = enum(u16) {
    /// A triangle, or a fan's records merged into one polygon.
    triangle = 0,
    fan = 1,
    strip_even = 2,
    /// Lists its last two corners the other way round.
    strip_odd = 3,
    /// Lines, one for each pair of indices.
    lines = 5,
    _,
};

/// A polygon's plane: its unit normal and the normal's dot product with its first corner.
pub const Plane = struct {
    normal: Vector,
    distance: f32,

    /// Whether `viewpoint`, in the polygon's frame, lies on its front side, which is the side the
    /// normal points to, or on the plane (`mesh_cull`, `0x004C6280`).
    pub fn faces(plane: Plane, viewpoint: Vector) bool {
        return plane.distance <= math.dot(viewpoint, plane.normal);
    }
};

/// A mesh (`mesh_create`, `0x004C4440`), as `mesh_build` makes it.
pub const Mesh = struct {
    positions: []Vector,
    normals: []Vector,
    /// Each vertex's counterpart in the next level, where the part geomorphs.
    morph_positions: ?[]Vector = null,
    morph_normals: ?[]Vector = null,
    /// Colours baked from static lights, red, green, blue and alpha.
    baked: ?[][4]f32 = null,
    /// `mesh_build` counts a wire face as one polygon more than it makes; those left over stay
    /// empty at the end, in no surface, and count only toward the frame's budget.
    polygons: []Polygon,
    indices: []u16,
    /// Texture coordinates for each index, for the first pass and the second. A light-mapped
    /// part's second are its first: the same slice.
    uv: [2]?[][2]f32,
    planes: []Plane,
    /// The faces' cap and two-sided flags, where the mesh has any.
    face_flags: ?[]shp.Face.Flags = null,
    /// A third of each face's sort bias.
    biases: []f32,
    surfaces: []Surface,
    bounds: [2]Vector,
    /// The farthest vertex from the origin.
    radius: f32,

    /// How much `create` makes room for.
    pub const Sizes = struct {
        polygons: usize,
        vertices: usize,
        indices: usize,
        surfaces: usize = 1,
    };

    /// A mesh of `sizes`, zeroed, for the caller to fill (`mesh_create`, `0x004C4440`): every
    /// polygon an empty triangle, every position, normal, plane and bias zero, every surface empty
    /// and untextured, no texture coordinates and no bounds.
    pub fn create(gpa: Allocator, sizes: Sizes) Allocator.Error!Mesh {
        const positions = try gpa.alloc(Vector, sizes.vertices);
        errdefer gpa.free(positions);
        @memset(positions, @splat(0));
        const normals = try gpa.alloc(Vector, sizes.vertices);
        errdefer gpa.free(normals);
        @memset(normals, @splat(0));
        const polygons = try gpa.alloc(Polygon, sizes.polygons);
        errdefer gpa.free(polygons);
        @memset(polygons, .{ .kind = .triangle, .continues = 0, .first = 0, .count = 0 });
        const indices = try gpa.alloc(u16, sizes.indices);
        errdefer gpa.free(indices);
        @memset(indices, 0);
        const planes = try gpa.alloc(Plane, sizes.polygons);
        errdefer gpa.free(planes);
        @memset(planes, .{ .normal = @splat(0), .distance = 0 });
        const biases = try gpa.alloc(f32, sizes.polygons);
        errdefer gpa.free(biases);
        @memset(biases, 0);
        const surfaces = try gpa.alloc(Surface, sizes.surfaces);
        @memset(surfaces, .{ .material = std.mem.zeroes(Material) });
        return .{
            .positions = positions,
            .normals = normals,
            .polygons = polygons,
            .indices = indices,
            .uv = .{ null, null },
            .planes = planes,
            .biases = biases,
            .surfaces = surfaces,
            .bounds = .{ @splat(0), @splat(0) },
            .radius = 0,
        };
    }

    /// Gives the mesh texture coordinates for the first pass, one pair an index, zeroed
    /// (`mesh_create`'s flag `0x01`), and returns them.
    pub fn addCoordinates(mesh: *Mesh, gpa: Allocator) Allocator.Error![][2]f32 {
        assert(mesh.uv[0] == null);
        const uv = try gpa.alloc([2]f32, mesh.indices.len);
        @memset(uv, .{ 0, 0 });
        mesh.uv[0] = uv;
        return uv;
    }

    /// Makes the polygons triangles, or fans merged into one, of `corners` indices each, one after
    /// another, as the game's own builders number them.
    pub fn numberPolygons(mesh: Mesh, corners: u16) void {
        for (mesh.polygons, 0..) |*polygon, i| {
            polygon.* = .{ .kind = .triangle, .continues = 0, .first = @intCast(i * corners), .count = corners };
        }
    }

    /// `mesh_copy` (`0x004C4710`): a copy with arrays of its own, in `gpa`. With `flagged` the copy
    /// has flags for each polygon, cleared, even where the mesh has none.
    pub fn copy(mesh: Mesh, gpa: Allocator, flagged: bool) Allocator.Error!Mesh {
        var out: Mesh = .{
            .positions = &.{},
            .normals = &.{},
            .polygons = &.{},
            .indices = &.{},
            .uv = .{ null, null },
            .planes = &.{},
            .biases = &.{},
            .surfaces = &.{},
            .bounds = mesh.bounds,
            .radius = mesh.radius,
        };
        errdefer out.deinit(gpa);
        out.positions = try gpa.dupe(Vector, mesh.positions);
        out.normals = try gpa.dupe(Vector, mesh.normals);
        if (mesh.morph_positions) |m| out.morph_positions = try gpa.dupe(Vector, m);
        if (mesh.morph_normals) |m| out.morph_normals = try gpa.dupe(Vector, m);
        if (mesh.baked) |b| out.baked = try gpa.dupe([4]f32, b);
        out.polygons = try gpa.dupe(Polygon, mesh.polygons);
        out.indices = try gpa.dupe(u16, mesh.indices);
        if (mesh.uv[0]) |u| out.uv[0] = try gpa.dupe([2]f32, u);
        // A light-mapped part's second coordinates are its first, and stay so.
        if (mesh.uv[1]) |u| out.uv[1] = if (mesh.uv[0] != null and u.ptr == mesh.uv[0].?.ptr) out.uv[0] else try gpa.dupe([2]f32, u);
        out.planes = try gpa.dupe(Plane, mesh.planes);
        if (mesh.face_flags) |f| {
            out.face_flags = try gpa.dupe(shp.Face.Flags, f);
        } else if (flagged) {
            const cleared = try gpa.alloc(shp.Face.Flags, mesh.polygons.len);
            @memset(cleared, .{});
            out.face_flags = cleared;
        }
        out.biases = try gpa.dupe(f32, mesh.biases);
        out.surfaces = try gpa.dupe(Surface, mesh.surfaces);
        return out;
    }

    /// Frees what `gpa` allocated for it.
    pub fn deinit(mesh: Mesh, gpa: Allocator) void {
        gpa.free(mesh.positions);
        gpa.free(mesh.normals);
        if (mesh.morph_positions) |m| gpa.free(m);
        if (mesh.morph_normals) |m| gpa.free(m);
        if (mesh.baked) |b| gpa.free(b);
        gpa.free(mesh.polygons);
        gpa.free(mesh.indices);
        if (mesh.uv[0]) |u| gpa.free(u);
        if (mesh.uv[1]) |u| if (mesh.uv[0] == null or u.ptr != mesh.uv[0].?.ptr) gpa.free(u);
        gpa.free(mesh.planes);
        if (mesh.face_flags) |f| gpa.free(f);
        gpa.free(mesh.biases);
        gpa.free(mesh.surfaces);
    }
};

/// A mesh object's levels of detail (`+0xB4`): each mesh with the distance it is drawn to.
pub const Level = struct {
    mesh: *const Mesh,
    /// Drawn while the object's depth, over the detail divisor, is below this.
    until: f32,
};

/// A scene object showing a mesh (`mesh_object_create`, `0x004C4BD0`).
pub const MeshObject = struct {
    flags: ObjectFlags,
    /// In the world (`+0x70`, `+0x4C`).
    position: Vector,
    orientation: math.Matrix = math.identity,
    /// `+0x48`: 1 when created. An object at 0 is not drawn.
    scale: f32 = 1,
    /// `+0xD0`: the finest level's radius.
    radius: f32,
    /// `+0xD4`: which of the faces' flags it heeds (`srmesh.showing`); `default_face_mask` when
    /// created.
    face_mask: u8 = default_face_mask,
    /// `+0xDC`: the lights that don't reach it (`srlight.Light.reaches`); `srlight.no_lights` for
    /// none at all.
    light_mask: u32 = 0,
    /// Red, green, blue and alpha (`+0xC4`, `+0xC8`, `+0xCC`, `+0xC0`); zero when created.
    colour: [4]f32 = @splat(0),
    levels: []const Level,
    /// The level drawn (`+0xB8`): the pipeline picks it each frame.
    level: usize = 0,
    /// Its own texture coordinates for each pass (`+0x114`, `+0x118`), a pair a vertex, which
    /// `SR_meshpipe_init` takes in place of the generated ones where it has them.
    own_uv: [2]?[][2]f32 = .{ null, null },
    /// The object's own baked colours (`+0x110`), for `baked_object`.
    baked: ?[]const [4]f32 = null,
    /// `+0xAC`: the portal that clips it, where its flags ask (`portal_clipped`); none clips
    /// nothing.
    portal: ?*const Portal = null,
    /// OpenReliant's: its surfaces blended by alpha cast a shadow as strong as its colour's alpha,
    /// as a cloaked part's see-through hull does (`srshadow`). Otherwise only its solid ones cast.
    alpha_shadow: bool = false,
    /// OpenReliant's: the key lights reach a little way past its terminator, as a planet's
    /// atmosphere carries the sun round into its night side, where the device lights each pixel
    /// (`atmosphere.Style.haze`). Its surfaces drawn in order take it; the sorted ones do not.
    soft_terminator: bool = false,

    /// The mesh of the level drawn, or of the coarsest where the level is past them; it has one
    /// at least.
    pub fn shown(object: *const MeshObject) *const Mesh {
        return object.levels[@min(object.level, object.levels.len - 1)].mesh;
    }

    /// Where it stands in the world and which way it faces.
    pub fn place(object: *const MeshObject) math.Place {
        return .{ .position = object.position, .orientation = object.orientation };
    }

    /// Whether any light may reach it: none reaches an object whose light mask is all ones.
    pub fn takesLights(object: *const MeshObject) bool {
        return object.light_mask != srlight.no_lights;
    }
};

/// The face mask a mesh object starts with (`mesh_object_create`): every flag heeded.
pub const default_face_mask: u8 = 0xFF;

/// An opaque colour for a mesh object's own colours (`MeshObject.baked`): `rgb`, its alpha 1.
pub fn solid(rgb: [3]f32) [4]f32 {
    return .{ rgb[0], rgb[1], rgb[2], 1 };
}

/// An opaque grey for a mesh object's own colours, as bright as `level` on each of red, green and
/// blue (`solid`).
pub fn grey(level: f32) [4]f32 {
    return solid(@splat(level));
}

test solid {
    try std.testing.expectEqual([4]f32{ 0.25, 0.5, 0.75, 1 }, solid(.{ 0.25, 0.5, 0.75 }));
    try std.testing.expectEqual([4]f32{ 0.5, 0.5, 0.5, 1 }, grey(0.5));
}

test MeshObject {
    var object: MeshObject = .{ .flags = .{}, .position = .{ 1, 2, 3 }, .radius = 1, .levels = &.{} };
    try std.testing.expectEqual(default_face_mask, object.face_mask);
    try std.testing.expect(object.takesLights());
    object.light_mask = srlight.no_lights;
    try std.testing.expect(!object.takesLights());
    try std.testing.expectEqual(Vector{ 1, 2, 3 }, object.place().position);
}

/// `portal_create` (`0x004C50D0`) for a portal of no corners, a single plane (flag `0x100`): a
/// plane through its place, facing along `normal` in its own frame, that clips the mesh objects
/// that name it (`MeshObject.portal`). `portal_transform` (`0x004CE9F0`) puts the plane in the
/// camera's frame each frame the portal is in the scene (`srcore.Scene.portals`), and the plane
/// stays as it was put there until the next. A polygon it clips keeps what lies on the side its
/// normal points away from (`portal_clip`, `0x004CCF30`).
///
/// Not ported: a portal with corners (flag `0x200`), which the game never makes.
pub const Portal = struct {
    position: Vector = @splat(0),
    orientation: math.Matrix = math.identity,
    /// `+0xB8`, in its own frame. A portal is made with none, which clips nothing.
    normal: Vector = @splat(0),
    /// In the camera's frame, as `transform` last left it (`+0xC8`, `+0xA0`).
    view: View = .{},

    /// Its plane in the camera's frame: a normal, and a point it passes through.
    pub const View = struct {
        normal: Vector = @splat(0),
        point: Vector = @splat(0),

        /// How far `v` lies on the side the portal keeps: what it keeps is at 0 or more.
        pub fn inside(plane: View, v: Vector) f32 {
            return math.dot(plane.normal, plane.point) - math.dot(plane.normal, v);
        }
    };

    /// `portal_transform` (`0x004CE9F0`): the plane, in the frame of a camera standing at `camera`.
    pub fn transform(portal: *Portal, camera: math.Place) void {
        const normal = math.transform(portal.orientation, portal.normal);
        portal.view = .{
            .normal = math.transformTransposed(camera.orientation, normal),
            .point = camera.inverse(portal.position),
        };
    }
};

test "Portal.transform" {
    // A portal 100 ahead of a camera facing along Z, its normal turned from X to Z: it keeps what
    // lies nearer than it.
    var portal: Portal = .{ .position = .{ 0, 0, 100 }, .orientation = math.rotation(.y, -std.math.pi / 2.0), .normal = .{ 1, 0, 0 } };
    portal.transform(.{});
    try std.testing.expect(math.length(portal.view.normal - Vector{ 0, 0, 1 }) < 1e-5);
    try std.testing.expect(portal.view.inside(.{ 0, 0, 50 }) > 0);
    try std.testing.expect(portal.view.inside(.{ 0, 0, 150 }) < 0);
    // Made with no normal, it keeps everything.
    const made: Portal = .{};
    try std.testing.expectEqual(0, made.view.inside(.{ 0, 0, 150 }));
}

/// A sprite of a set (`sprite_set_create`, `0x004C4DB0`): a rectangle facing the camera.
pub const Sprite = struct {
    /// Its own material (`+0x04`), where it has one: `sprite_set_create` points every sprite at
    /// the set's, and the driver draws a blended sprite with the one it points at.
    surface: ?*const Surface = null,
    /// From the set's position, in the world.
    offset: Vector = @splat(0),
    /// How far it reaches either side of its centre, in the camera's units.
    half_size: [2]f32 = .{ 0, 0 },
    /// Added to its depth for sorting (`+0x48`).
    bias: f32 = 0,
    /// Red, green and blue (`+0x54`).
    colour: [3]f32 = .{ 1, 1, 1 },
    /// Its texture's span: left, right, top and bottom (`+0x38`).
    uv: [4]f32 = .{ 0, 1, 0, 1 },
    /// Left out (the set's flags at `+0xC8`).
    hidden: bool = false,
    /// OpenReliant's: how much of it shows, its colour and its alpha both scaled, which a fireball
    /// fades from one frame of its animation into the next by.
    fade: f32 = 1,
};

/// A set of sprites sharing a material (`sprite_set_create`): at first unlit and added, textured
/// by coordinates of its own.
pub const SpriteSet = struct {
    flags: ObjectFlags = .{},
    /// In the world; the sprites are offset from it.
    position: Vector = @splat(0),
    scale: f32 = 1,
    surface: Surface = .{ .material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .add }) },
    sprites: []Sprite,
};

test "Mesh.create" {
    const gpa = std.testing.allocator;
    var mesh: Mesh = try .create(gpa, .{ .polygons = 2, .vertices = 4, .indices = 8, .surfaces = 2 });
    defer mesh.deinit(gpa);
    try std.testing.expectEqual(4, mesh.normals.len);
    try std.testing.expectEqual(2, mesh.planes.len);
    try std.testing.expectEqual(null, mesh.uv[0]);
    try std.testing.expectEqual(Material.Blend.off, mesh.surfaces[1].material.blend[0]);

    // Texture coordinates, one pair an index; the polygons, runs of four one after another.
    const uv = try mesh.addCoordinates(gpa);
    try std.testing.expectEqual(8, uv.len);
    mesh.numberPolygons(4);
    try std.testing.expectEqual(4, mesh.polygons[1].first);
    try std.testing.expectEqual(4, mesh.polygons[1].count);
}

test "Mesh.copy" {
    const gpa = std.testing.allocator;
    var mesh: Mesh = try .create(gpa, .{ .polygons = 2, .vertices = 4, .indices = 6 });
    defer mesh.deinit(gpa);
    const uv = try mesh.addCoordinates(gpa);
    mesh.uv[1] = uv;
    mesh.positions[2] = .{ 1, 2, 3 };

    // Every array its own, but a light map's coordinates still the first pass's.
    var copied = try mesh.copy(gpa, true);
    defer copied.deinit(gpa);
    try std.testing.expectEqual(@as(Vector, .{ 1, 2, 3 }), copied.positions[2]);
    try std.testing.expect(copied.positions.ptr != mesh.positions.ptr);
    try std.testing.expect(copied.uv[0].?.ptr != uv.ptr);
    try std.testing.expectEqual(copied.uv[0].?.ptr, copied.uv[1].?.ptr);
    // Flags for its polygons, where the mesh has none.
    try std.testing.expectEqual(null, mesh.face_flags);
    try std.testing.expectEqual(2, copied.face_flags.?.len);

    // Where it fails part way, it leaves nothing behind.
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 5 });
    try std.testing.expectError(error.OutOfMemory, mesh.copy(failing.allocator(), true));
}

test {
    std.testing.refAllDecls(@This());
}
