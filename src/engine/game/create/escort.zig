//! The escort point's marker, which a mission's script gives the player's ship to fly by
//! (`SetEscortPoint`, `GameObject.escort_point`). `escort_marker_init` (`0x00468920`) builds it as
//! a mission runs, `escort_marker_frame` (`0x00468D00`) places it each frame, and
//! `escort_marker_free` (`0x00468CE0`) frees it as the mission ends. It is four rings about the
//! point's Z axis, each a square of lines with its corners cut off, and between them three sets of
//! four chevrons pointing along it, which pulse red in a band that runs along the axis.
//!
//! **Unverified:** the file. Its code lies after `Create.cpp`'s and before `environfx.cpp`'s,
//! beside `objects_update`, which OpenReliant keeps in `create.zig`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const camera = @import("../camera.zig");
const Objects = @import("../create.zig").Objects;
const xtrabits = @import("../xtrabits.zig");

/// The rings: four of them, `ring_step` apart along the Z axis from `-first_ring` (`0x004DC7E4`,
/// `0x004DC7E0`), each of four corners of `corner_points` points, one corner in each quarter.
const rings = 4;
const ring_step: f32 = 640;
const first_ring: f32 = 960;
const corners = 4;
const corner_points = 4;
const ring_points = corners * corner_points;

/// A corner's points in the upper right quarter, which the others mirror: along the top edge, then
/// down the side (`0x004DC7DC`, `0x004DC7D8`, `0x004DC7E4`). Lines join each point to the next.
const corner = [corner_points][2]f32{ .{ 160, 640 }, .{ 320, 640 }, .{ 640, 320 }, .{ 640, 160 } };

/// The chevrons: at each of three places along the axis, `chevron_step` apart from
/// `-chevron_step`, four of them a quarter turn apart about it, each a triangle of `chevron_radius`
/// (`0x004DC440`) standing `chevron_height` out from the axis, its point toward positive Z.
const chevron_places = 3;
const chevron_step: f32 = 640;
const chevron_height: f32 = 640;
const chevron_radius: f32 = 100;
const chevrons = chevron_places * corners;
const chevron_points = 3;

const vertices = rings * ring_points + chevrons * chevron_points;
const lines = rings * corners * (corner_points - 1);
const polygons = lines + chevrons;
const indices = 2 * lines + chevron_points * chevrons;

comptime {
    // As `escort_marker_init` asks `mesh_create` for them.
    assert(vertices == 100 and polygons == 60 and indices == 132);
}

/// The marker's colour as it is built, full red, of which the pulse sets the red.
const red = [4]f32{ 1, 0, 0, 1 };

/// The pulse: a band that comes round every `pulse_ticks` (300) and brightens each ring and each
/// place of chevrons as it passes, from `dimmest` up by `rise` a tick to full over `pulse_ticks / 2`
/// ticks either side of its middle (`0x004DC518`, `0x004DC3D4`). The rings but the first, and the
/// chevrons, take it `phase_step` ticks apart along the axis, from `first_ring_phase` and
/// `first_chevron_phase` (`0x00468D7C`, `0x00468E34`).
const pulse_ticks: i32 = 300;
const rise: f32 = 0.01;
const dimmest: f32 = 0.25;
const first_ring_phase: i32 = 300;
const first_chevron_phase: i32 = 350;
const phase_step: i32 = 100;

/// How far from the camera the marker is drawn at most, drawn along the line to the point beyond
/// it (`0x004DC494`).
const reach: f32 = 50000;

/// How the marker's lines and triangles are drawn: untextured, coloured by its own colours, and
/// added. **Unknown:** what sets bit 2 of `sr + 0x38`, with which the game has them blend by
/// `add_alpha` instead; OpenReliant leaves it clear, as for the backdrop.
const material: srapiext.Material = .onePass(.{ .coordinates = .none, .lit = true, .blend = .add });

/// The marker's mesh (`escort_marker_mesh`, `0x0054D104`), its scene object (`escort_marker`,
/// `0x0054D108`), "Dockring mesh", with its own colours, and the ticks it pulses by
/// (`escort_marker_clock`, `0x0054D100`).
pub const Marker = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [vertices][4]f32,
    clock: i32,

    /// `escort_marker_init`: the mesh, and the scene object, never culled, coloured by its own
    /// colours, all full red.
    ///
    /// **Improvement:** OpenReliant sets the chevrons' corners a third of a turn apart by
    /// `std.math.tau`, where the game multiplies by 6.2831855 and by 0.33333334 (`0x004DC3EC`,
    /// `0x004DC7D4`).
    pub fn create(gpa: Allocator) Allocator.Error!*Marker {
        const marker = try gpa.create(Marker);
        errdefer gpa.destroy(marker);
        marker.mesh = try .create(gpa, .{ .polygons = polygons, .vertices = vertices, .indices = indices });
        marker.mesh.surfaces[0] = .{ .polygons = polygons, .material = material };
        build(&marker.mesh);
        marker.level = .{.{ .mesh = &marker.mesh, .until = std.math.inf(f32) }};
        marker.colours = @splat(red);
        marker.clock = 0;
        marker.object = .{
            .flags = .{ .not_culled = true, .baked_object = true },
            .position = @splat(0),
            .radius = marker.mesh.radius,
            .levels = &marker.level,
            .baked = &marker.colours,
        };
        return marker;
    }

    /// `escort_marker_free`.
    pub fn destroy(marker: *Marker, gpa: Allocator) void {
        marker.mesh.deinit(gpa);
        gpa.destroy(marker);
    }

    /// As each mission runs, `escort_marker_init` builds the marker afresh, its pulse from the
    /// start; OpenReliant keeps the one it built for the run, and starts its pulse again.
    pub fn reset(marker: *Marker) void {
        marker.clock = 0;
    }

    /// `escort_marker_frame`, where the player's ship has an escort point: the marker stands where
    /// that object is drawn, turned as it is; the pulse moves on by the frame's `ticks`, and each
    /// ring but the first and each place of chevrons takes its red from it; drawn along the line
    /// from the camera, at `camera_at`, no farther than `reach`; and it goes into the world's layer
    /// in the four views from the cockpit.
    pub fn frame(marker: *Marker, gpa: Allocator, scene: *srcore.Scene, all: *const Objects, camera_at: Vector, view: camera.View, ticks: i32) Allocator.Error!void {
        const point = all.slots[all.player].object.escort_point.index() orelse return;
        const drawn = all.slots[point].drawn;
        marker.object.position = drawn.position;
        marker.object.orientation = drawn.orientation;
        marker.clock = @mod(marker.clock + ticks, pulse_ticks);
        for (1..rings) |ring| {
            const phase = first_ring_phase - phase_step * @as(i32, @intCast(ring - 1));
            const shade = brightness(marker.clock + phase);
            for (marker.colours[ring * ring_points ..][0..ring_points]) |*colour| colour[0] = shade;
        }
        const chevrons_from = rings * ring_points;
        const place_points = corners * chevron_points;
        for (0..chevron_places) |place| {
            const phase = first_chevron_phase - phase_step * @as(i32, @intCast(place));
            const shade = brightness(marker.clock + phase);
            for (marker.colours[chevrons_from + place * place_points ..][0..place_points]) |*colour| colour[0] = shade;
        }
        const offset = marker.object.position - camera_at;
        const distance = math.length(offset);
        if (distance > reach) marker.object.position = camera_at + offset * @as(Vector, @splat(reach / distance));
        switch (view) {
            .cockpit, .cockpit_left, .cockpit_right, .cockpit_rear => try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &marker.object }, .world),
            else => {},
        }
    }
};

/// The red the pulse gives a ring or a place of chevrons at `phase` ticks: full at the middle of
/// the band, falling by `rise` a tick either side of it, to no less than `dimmest`.
fn brightness(phase: i32) f32 {
    const from_middle: f32 = @floatFromInt(@mod(phase, pulse_ticks) - @divExact(pulse_ticks, 2));
    return @max(1 - rise * @abs(from_middle), dimmest);
}

/// The marker's shape (`escort_marker_init`): each ring's corners in turn, the upper right, the
/// upper left, the lower right and the lower left, as lines from each point to the next; then the
/// chevrons, as triangles, place by place along the axis, each place's four a quarter turn apart
/// about it (`mat3_from_angles`).
fn build(mesh: *srapiext.Mesh) void {
    for (0..rings) |ring| {
        const z = @as(f32, @floatFromInt(ring)) * ring_step - first_ring;
        for (0..corners) |quarter| {
            const x: f32 = if (quarter & 1 != 0) -1 else 1;
            const y: f32 = if (quarter & 2 != 0) -1 else 1;
            for (corner, 0..) |point, n| {
                mesh.positions[(ring * corners + quarter) * corner_points + n] = .{ x * point[0], y * point[1], z };
            }
        }
    }
    for (0..chevrons) |chevron| {
        const turn = math.fromAngles(0, 0, @as(f32, @floatFromInt(chevron % corners)) * std.math.pi / 2.0);
        const z = @as(f32, @floatFromInt(chevron / corners)) * chevron_step - chevron_step;
        for (0..chevron_points) |n| {
            const angle = @as(f32, @floatFromInt(n)) * std.math.tau / chevron_points;
            const point: Vector = .{ chevron_radius * @sin(angle), chevron_height, z + chevron_radius * @cos(angle) };
            mesh.positions[rings * ring_points + chevron * chevron_points + n] = math.transform(turn, point);
        }
    }
    for (0..rings * corners) |bend| {
        for (0..corner_points - 1) |n| {
            const line = bend * (corner_points - 1) + n;
            mesh.polygons[line] = .{ .kind = .lines, .continues = 0, .first = @intCast(2 * line), .count = 2 };
            const from: u16 = @intCast(bend * corner_points + n);
            mesh.indices[2 * line ..][0..2].* = .{ from, from + 1 };
        }
    }
    for (0..chevrons) |chevron| {
        const first = 2 * lines + chevron * chevron_points;
        mesh.polygons[lines + chevron] = .{ .kind = .triangle, .continues = 0, .first = @intCast(first), .count = chevron_points };
        for (0..chevron_points) |n| mesh.indices[first + n] = @intCast(rings * ring_points + chevron * chevron_points + n);
    }
    srapi.findBoundingBox(mesh);
}

test brightness {
    // Full at the band's middle, falling a hundredth a tick either side, to no less than a quarter.
    try std.testing.expectEqual(1, brightness(150));
    try std.testing.expectApproxEqAbs(0.5, brightness(100), 1e-6);
    try std.testing.expectApproxEqAbs(0.5, brightness(200), 1e-6);
    try std.testing.expectEqual(dimmest, brightness(0));
    try std.testing.expectEqual(dimmest, brightness(299));
    try std.testing.expectEqual(brightness(150), brightness(450));
}

test "Marker.create builds the rings and the chevrons" {
    const gpa = std.testing.allocator;
    const marker: *Marker = try .create(gpa);
    defer marker.destroy(gpa);
    const mesh = &marker.mesh;
    // The first ring, behind, its upper right corner first.
    try std.testing.expectEqual(Vector{ 160, 640, -960 }, mesh.positions[0]);
    try std.testing.expectEqual(Vector{ 640, 160, -960 }, mesh.positions[3]);
    // Its upper left corner, then the last ring's lower left.
    try std.testing.expectEqual(Vector{ -160, 640, -960 }, mesh.positions[4]);
    try std.testing.expectEqual(Vector{ -640, -160, 960 }, mesh.positions[63]);
    // The first chevron, at the top, its point toward positive Z.
    for ([_]Vector{ .{ 0, 640, -540 }, .{ 86.60254, 640, -690 }, .{ -86.60254, 640, -690 } }, mesh.positions[64..67]) |expected, actual| {
        try math.testing.expectVectorWithin(expected, actual, 1e-3);
    }
    // Each place's chevrons a quarter turn apart: the second stands out along X.
    try std.testing.expectApproxEqAbs(640, @abs(mesh.positions[67][0]), 1e-3);
    try std.testing.expectApproxEqAbs(0, mesh.positions[67][1], 1e-3);
    // Lines along each corner, then the chevrons' triangles.
    try std.testing.expectEqual(srapiext.Polygon{ .kind = .lines, .continues = 0, .first = 0, .count = 2 }, mesh.polygons[0]);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 1, 2, 2, 3, 4, 5 }, mesh.indices[0..8]);
    try std.testing.expectEqual(srapiext.Polygon{ .kind = .triangle, .continues = 0, .first = 96, .count = 3 }, mesh.polygons[48]);
    try std.testing.expectEqualSlices(u16, &.{ 64, 65, 66 }, mesh.indices[96..99]);
    try std.testing.expectEqualSlices(u16, &.{ 97, 98, 99 }, mesh.indices[129..132]);
    try std.testing.expectEqual(polygons, mesh.surfaces[0].polygons);
    for (marker.colours) |colour| try std.testing.expectEqual(red, colour);
}

test "Marker.frame stands it on the escort point, pulses it, and draws it from the cockpit" {
    const gpa = std.testing.allocator;
    const gameobj = @import("../gameobj.zig");
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const player = try mission.add(.predator, .{ 0, 0, 0 });
    const point = try mission.add(.marker, .{ 0, 0, 1000 });
    mission.objects.player = player;
    const marker: *Marker = try .create(gpa);
    defer marker.destroy(gpa);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);

    // Without an escort point, nothing.
    try marker.frame(gpa, &scene, mission.objects, @splat(0), .cockpit, 10);
    try std.testing.expectEqual(0, marker.clock);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);

    mission.slot(player).object.escort_point = .of(point);
    mission.slot(point).drawn = .{ .position = .{ 0, 0, 1000 } };
    try marker.frame(gpa, &scene, mission.objects, @splat(0), .cockpit, 150);
    try std.testing.expectEqual(Vector{ 0, 0, 1000 }, marker.object.position);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    // 150 ticks in, the band is on the second ring; the first stays full red.
    try std.testing.expectEqual(1, marker.colours[ring_points][0]);
    try std.testing.expectEqual(dimmest, marker.colours[2 * ring_points][0]);
    try std.testing.expectEqual(red, marker.colours[0]);

    // Far off, it stands no farther than its reach along the line to the point, and it is left
    // out of the chase view.
    scene.clear();
    mission.slot(point).drawn.position = .{ 0, 0, 200000 };
    try marker.frame(gpa, &scene, mission.objects, @splat(0), .chase, 0);
    try std.testing.expectEqual(Vector{ 0, 0, reach }, marker.object.position);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    // The pulse comes round every 300 ticks.
    try marker.frame(gpa, &scene, mission.objects, @splat(0), .chase, 300);
    try std.testing.expectEqual(150, marker.clock);
}
