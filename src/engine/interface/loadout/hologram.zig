//! The loadout's hologram, its pieces and where they stand (`loadout.cpp`): the textured squares
//! its panels and buttons are (`panel_create`), the disc's mesh, its lights, the buttons' table, and
//! the slots of the disc the ships stand on (`slot_place`). The loadout makes them and moves them
//! (`loadout.Loadout`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srlight = @import("../../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const i3d = @import("../../genilib/interf/i3d.zig");
const anims = @import("anims.zig");
const loadout = @import("loadout.zig");
const panels = @import("panels.zig");
const Vector = math.Vector;

/// Half a texel of the panels' textures, 256 across (`panels.size`), which `panel_create` moves each
/// coordinate on by (`0x004DC700`).
pub const half_texel: f32 = 0.5 / @as(f32, panels.size);

/// The objects the loadout places by name (`loadout_placements`), and its panels' and buttons'
/// names (`panel_create`'s, `0x004EADEC` on).
pub const Name = enum {
    disc,
    glow,
    info,
    ship_name,
    page_title,
    missiles_button,
    exit_button,
    ships_button,
    guns_button,
    default_button,
    remove_all_button,
    scroller0,
    scroller1,

    pub fn text(name: Name) []const u8 {
        return switch (name) {
            .disc => "Disc",
            .glow => "Disc Glow",
            .info => "PnlShipInfo",
            .ship_name => "PnlShipName",
            .page_title => "PnlPageTitle",
            .missiles_button => "BtnMissiles",
            .exit_button => "BtnExit",
            .ships_button => "BtnShips",
            .guns_button => "BtnGuns",
            .default_button => "BtnDefault",
            .remove_all_button => "BtnRemoveAll",
            .scroller0 => "Scroller0",
            .scroller1 => "Scroller1",
        };
    }
};

/// The six buttons, in the order the loadout makes them (`0x005245CC` on), each with its tooltip's
/// string (`0x00443EC6` on).
pub const Button = enum {
    missiles,
    exit,
    ships,
    guns,
    default,
    remove_all,

    pub fn name(button: Button) Name {
        return switch (button) {
            .missiles => .missiles_button,
            .exit => .exit_button,
            .ships => .ships_button,
            .guns => .guns_button,
            .default => .default_button,
            .remove_all => .remove_all_button,
        };
    }

    pub fn tooltip(button: Button) u16 {
        return switch (button) {
            .missiles => 0x22D,
            .exit => 0x22E,
            .ships => 0x22F,
            .guns => 0x230,
            .default => 0x231,
            .remove_all => 0x232,
        };
    }

    /// Where on the panels' art it is drawn from.
    pub fn span(button: Button) Span {
        return switch (button) {
            .missiles => .{ .top = 0.37890625, .left = 0.234375, .bottom = 0.578125, .right = 0.47265625 },
            .exit => .{ .top = 0.1796875, .left = 0.47265625, .bottom = 0.37890625, .right = 0.7109375 },
            .ships => .{ .top = 0.1796875, .left = 0, .bottom = 0.37890625, .right = 0.234375 },
            .guns => .{ .top = 0.37890625, .left = 0, .bottom = 0.578125, .right = 0.234375 },
            .default => .{ .top = 0.1796875, .left = 0.7109375, .bottom = 0.37890625, .right = 0.94921875 },
            .remove_all => .{ .top = 0.1796875, .left = 0.234375, .bottom = 0.37890625, .right = 0.47265625 },
        };
    }
};

/// A button's size (`0x40155182` by `0x3FD54FDF`).
pub const button_size: [2]f32 = .{ 2.333, 1.667 };

/// The scale a button is made at, too small to see until it appears (`0x38D1B717`).
pub const button_hidden_scale: f32 = 1e-4;

/// Where on its texture a panel is drawn from: the edges of the part of the image it shows, as
/// `panel_create` takes them, top, left, bottom and right, each from 0 to 1.
pub const Span = struct {
    top: f32,
    left: f32,
    bottom: f32,
    right: f32,

    pub const whole: Span = .{ .top = 0, .left = 0, .bottom = 1, .right = 1 };
};

/// A textured square of the hologram's (`panel_create`), with its scene object and the object of
/// the interface that stands for it.
pub const Panel = struct {
    mesh: srapiext.Mesh,
    levels: [1]srapiext.Level,
    scene_object: srapiext.MeshObject,
    object: i3d.Object,

    /// `panel_create` (`0x00444980`): `panel`, a square `size` across and down (`squareMesh`),
    /// turned both ways where `two_sided`, `front` drawn on its front over `span` of the image,
    /// each edge half a texel on, and `back` on its back over the same, turned round; unlit and
    /// added; standing at the origin, named `name` and clickable, and added to the interface.
    pub fn make(panel: *Panel, arena: Allocator, interface: *i3d.Interface, name: Name, front: ?*srtexture.Image, back: ?*srtexture.Image, two_sided: bool, size: [2]f32, span: Span) Allocator.Error!void {
        panel.mesh = try loadout.squareMesh(arena, two_sided, size[0], size[1]);
        const top = span.top + half_texel;
        const left = span.left + half_texel;
        const bottom = span.bottom + half_texel;
        const right = span.right + half_texel;
        const uv = panel.mesh.uv[0].?;
        uv[0..6].* = .{ .{ left, bottom }, .{ right, bottom }, .{ left, top }, .{ right, bottom }, .{ right, top }, .{ left, top } };
        const face: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .add });
        panel.mesh.surfaces[0] = .{ .polygons = 2, .material = face, .textures = .{ .of(front), .none } };
        if (two_sided) {
            uv[6..12].* = .{ .{ left, bottom }, .{ right, top }, .{ left, top }, .{ left, bottom }, .{ right, bottom }, .{ right, top } };
            const surfaces = try arena.alloc(srapiext.Surface, 2);
            surfaces[0] = panel.mesh.surfaces[0];
            surfaces[1] = .{ .polygons = 2, .material = face, .textures = .{ .of(back), .none } };
            panel.mesh.surfaces = surfaces;
        }
        try panel.add(interface, name);
    }

    /// `mesh_object_create` and `i3dobject_create` for a panel's mesh: its scene object, unlit
    /// and at the origin, and its object, clickable, added to the interface by `name`.
    pub fn add(panel: *Panel, interface: *i3d.Interface, name: Name) Allocator.Error!void {
        panel.levels = .{.{ .mesh = &panel.mesh, .until = std.math.inf(f32) }};
        panel.scene_object = .{ .flags = .{}, .position = @splat(0), .radius = panel.mesh.radius, .levels = &panel.levels };
        panel.object = .create(0, null, true);
        panel.object.target = .{ .mesh = &panel.scene_object };
        try interface.addObject(&panel.object, name.text());
    }
};

/// The loadout's lights (`loadout_enter`, `0x00442729` on).
pub const Light = enum { green, red, bright_green, ambient, cursor };
const light_place: Vector = .{ 15, -15, -10 };
const light_range = 100000;
pub const light_intensity = 2;

/// How far a slot's place across and down the disc is scaled (`0x004DC714`).
pub const slot_unit: f32 = 0.078125;

/// The loadout's lights (`loadout_enter`): the green and the red point lights, the bright green one
/// that is never added, the green ambient light, and the cursor's directional light, green on the
/// software renderer.
pub fn lights(hardware: bool) std.EnumArray(Light, srlight.Light) {
    const point: srlight.Light.Kind = .{ .point = .{ .position = light_place, .range = light_range } };
    const cursor_colour: [3]f32 = if (hardware) .{ 0.4, 1, 0.4 } else .{ 0, 1, 0 };
    return .init(.{
        .green = .{ .mask = 2, .intensity = light_intensity, .colour = .{ 1, 1, 1 }, .kind = point },
        .red = .{ .mask = 1, .intensity = light_intensity, .colour = .{ 1, 0.6, 1 }, .kind = point },
        .bright_green = .{ .mask = 4, .intensity = light_intensity, .colour = .{ 0, 1, 0 }, .kind = point },
        .ambient = .{ .mask = 0, .intensity = 0.2, .colour = .{ 0, 1, 0 }, .kind = .ambient },
        .cursor = .{ .mask = 0x10, .intensity = 1, .colour = cursor_colour, .kind = .{ .directional = math.forward(math.fromAngles(0.5, 0.5, 0.5)) } },
    });
}

/// `loadout_disc_create`'s mesh (`0x00444310`): a square 20 across of nine vertices, in four
/// quarters of two triangles, each quarter a surface of its own textured with its plate from edge
/// to edge less half a texel of 256, unlit and added. Its faces' planes, its vertex normals and its
/// bounds are worked out.
pub fn discMesh(gpa: Allocator, plates: [4]?*srtexture.Image) Allocator.Error!srapiext.Mesh {
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 8, .vertices = 9, .indices = 24, .surfaces = 4 });
    errdefer mesh.deinit(gpa);
    for (mesh.positions[0..9], 0..) |*position, i| {
        position.* = .{ @as(f32, @floatFromInt(i % 3)) * 10 - 10, @as(f32, @floatFromInt(i / 3)) * 10 - 10, 0 };
    }
    mesh.numberPolygons(3);
    mesh.indices[0..24].* = .{ 3, 4, 0, 0, 4, 1, 4, 5, 1, 1, 5, 2, 6, 7, 3, 3, 7, 4, 7, 8, 4, 4, 8, 5 };
    const uv = try mesh.addCoordinates(gpa);
    const low = half_texel;
    const high = 1 - half_texel;
    for (0..4) |quarter| {
        uv[quarter * 6 ..][0..6].* = .{ .{ low, high }, .{ high, high }, .{ low, low }, .{ low, low }, .{ high, high }, .{ high, low } };
    }
    for (mesh.surfaces, plates) |*surface, plate| {
        surface.* = .{ .polygons = 2, .material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .add }), .textures = .{ .of(plate), .none } };
    }
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// `slot_place` (`0x00449690`): where `slot` stands on the disc at `disc`, its place across and
/// down scaled by `across`, turned as the disc is and from its centre; and where `face`, how it is
/// turned to face away from the disc's axis at its height, rolled over (`faceAway`). Without it, no
/// angles are given: nought here.
pub fn slotPlace(disc: math.Place, slot: Vector, face: bool, across: f32) anims.Placed {
    var at = slot;
    at[0] *= across;
    at[1] *= across;
    at = disc.position + math.transform(disc.orientation, at);
    var axis = disc.position;
    axis[1] = at[1];
    return .{ .position = at, .angles = if (face) math.angles(faceAway(at, axis, std.math.pi)) else @splat(0) };
}

/// `0x00449750`: an orientation at `from` whose forward axis points away from `to`, turned about Y
/// toward it and then about X half a turn less its rise, and rolled by `roll`.
///
/// **Improvement:** the angles are computed, where the game looks them up in `sr_atan2`'s table.
fn faceAway(from: Vector, to: Vector, roll: f32) math.Matrix {
    var toward = math.normalize(to - from);
    var turned = math.turned(math.identity, .y, std.math.atan2(toward[0], toward[2]));
    toward = math.normalize(math.transformTransposed(turned, toward));
    turned = math.turned(turned, .x, std.math.pi - std.math.atan2(toward[1], toward[2]));
    return math.turned(turned, .z, roll);
}

const expectVector = math.testing.expectVector;

test discMesh {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = .{ .levels = &.{} };
    var mesh = try discMesh(gpa, .{ &image, null, null, null });
    defer mesh.deinit(gpa);
    // Twenty across in four quarters of two triangles, each quarter its plate over the whole
    // image but for half a texel at each edge.
    try std.testing.expectEqual(9, mesh.positions.len);
    try std.testing.expectEqual(Vector{ 10, 10, 0 }, mesh.positions[8]);
    try std.testing.expectEqual(4, mesh.surfaces.len);
    try std.testing.expectEqual(&image, mesh.surfaces[0].textures[0].image);
    try std.testing.expectEqual(srapiext.Texture.none, mesh.surfaces[1].textures[0]);
    try std.testing.expectEqual([2]f32{ half_texel, 1 - half_texel }, mesh.uv[0].?[0]);
    try std.testing.expectEqualSlices(u16, &.{ 3, 4, 0, 0, 4, 1 }, mesh.indices[0..6]);
    try std.testing.expectEqual(srapiext.Material.Blend.add, mesh.surfaces[3].material.blend[0]);
}

test slotPlace {
    // A disc lying flat, turned a quarter about X, its centre at (1, 2, 3).
    const disc: math.Place = .{ .position = .{ 1, 2, 3 }, .orientation = math.fromAngles(-std.math.pi / 2.0, 0, 0) };
    // Across and down scaled, depth as it is, all turned with the disc: its down comes out toward
    // the camera, its depth the world's down.
    const placed = slotPlace(disc, .{ 16, -16, -6 }, false, 0.5);
    try expectVector(.{ 9, -4, 11 }, placed.position);
    try expectVector(@splat(0), placed.angles);
    // Facing away from the disc's axis: a slot beside the axis faces out along X, upright.
    const faced = slotPlace(disc, .{ 16, 0, -1 }, true, 0.5);
    const forward = math.forward(math.fromAngleVector(faced.angles));
    try expectVector(.{ 1, 0, 0 }, forward);
    try expectVector(.{ 0, 1, 0 }, math.yAxis(math.fromAngleVector(faced.angles)));
}
