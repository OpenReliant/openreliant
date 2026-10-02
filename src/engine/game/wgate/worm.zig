//! Part of `C:\lancer\game\wgate.cpp`: the worm (`0x00422700`), the tube the player's ship rides
//! from one gate to the next as it jumps out (`wgate.jumpOut`), built as a tunnel is
//! (`tunnel.zig`). [Gates](../../../../docs/engine/gates.md#jump-out) describes it.
//!
//! **Improvement:** the sines and cosines come from `std.math` rather than the engine's tables
//! (`sr_sin`, `sr_cos`).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const tunnel = @import("tunnel.zig");
const Grid = tunnel.Grid;
const Palette = tunnel.Palette;

/// The worm (`0x00422700`), which the player's ship rides from one gate to the next: a tube of
/// `worm_rings` rings, `worm_segments` round, `worm_radius` across and `worm_ring_spacing` apart,
/// drawn solid with the gates' texture by coordinates of its own and colours of its own (`colour`),
/// and a highlight added by its normals. Its last band is drawn in one pass.
pub const Worm = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [][4]f32,

    pub const grid: Grid = .{ .segments = worm_segments, .rings = worm_rings - 1 };

    pub fn create(gpa: Allocator, image: *srtexture.Image) Allocator.Error!*Worm {
        const worm = try gpa.create(Worm);
        errdefer gpa.destroy(worm);
        const polygons = grid.polygons();
        var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = polygons, .vertices = grid.vertices(), .indices = polygons * 3, .surfaces = 2 });
        errdefer mesh.deinit(gpa);
        for (0..worm_rings) |ring| {
            for (0..worm_segments) |segment| {
                const turn = tunnel.segmentTurn(segment, worm_segments);
                mesh.positions[grid.vertex(ring, segment)] = .{ @sin(turn) * worm_radius, @cos(turn) * worm_radius, @as(f32, @floatFromInt(ring)) * worm_ring_spacing };
            }
        }
        tunnel.numberBands(&mesh, grid);
        const uv = try mesh.addCoordinates(gpa);
        for (mesh.indices, uv) |index, *pair| {
            const at = mesh.positions[index];
            pair.* = .{ at[2] * worm_uv_along, at[1] * worm_uv_across };
        }
        tunnel.tubeSurfaces(&mesh, 2 * worm_segments, image, worm_highlight, true, .off);
        const colours = try gpa.alloc([4]f32, grid.vertices());
        @memset(colours, @splat(0));
        worm.* = .{ .mesh = mesh, .level = undefined, .object = undefined, .colours = colours };
        worm.level = .{.{ .mesh = &worm.mesh, .until = std.math.inf(f32) }};
        worm.object = .{
            .flags = .{ .normals_second = true, .not_culled = true, .unbounded = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = mesh.radius,
            .levels = &worm.level,
            .baked = colours,
        };
        worm.colour();
        return worm;
    }

    pub fn destroy(worm: *Worm, gpa: Allocator) void {
        worm.mesh.deinit(gpa);
        gpa.free(worm.colours);
        gpa.destroy(worm);
    }

    /// `0x00422AD0`: a proto gate's colours (`Palette.blue`) along its rings, each
    /// `worm_ring_share` further along them, its first and last black and clear
    /// (`tunnel.ringShade`).
    fn colour(worm: *Worm) void {
        for (0..grid.rings + 1) |ring| {
            const along = @as(f32, @floatFromInt(ring)) * worm_ring_share;
            tunnel.fillRing(worm.colours, grid, ring, tunnel.ringShade(grid, ring, srapiext.solid(Palette.blue.last), srapiext.solid(Palette.blue.at(along))));
        }
    }

    /// `0x004229B0`: each vertex, the centre too, swaying across and down by up to `worm_sway`, at
    /// its own pace by the frame's tick (`tunnel.sway`), about its place round the tube; the centre
    /// takes the place of the last segment.
    pub fn wobble(worm: *Worm, frame_start: i32) void {
        const ticks: f32 = @floatFromInt(frame_start);
        for (worm.mesh.positions, 0..) |*position, vertex| {
            const segment = (vertex + worm_segments - 1) % worm_segments;
            const turn = tunnel.segmentTurn(segment, worm_segments);
            const swayed = tunnel.sway(ticks, vertex, worm_spread, worm_sway);
            position[0] = @sin(turn) * worm_radius + swayed[0];
            position[1] = @cos(turn) * worm_radius + swayed[1];
        }
    }

    /// Scrolls its texture along it and across it by `time`, as the gates count it
    /// (`order_fixed_gate_jump_out`).
    pub fn scroll(worm: *Worm, time: f32) void {
        tunnel.scrollBy(&worm.mesh, .{ time * worm_scroll[0], -(time * worm_scroll[1]) });
    }
};

comptime {
    // Its mesh numbers its vertices in 16 bits.
    assert(Worm.grid.vertices() <= std.math.maxInt(u16));
}

/// The worm's tube (`0x00422700`): its segments and rings, its radius (`0x004DC43C`), how far apart
/// its rings stand (`0x004DC640`), and its coordinates' scale along it (`0x004DC63C` times
/// `0x004DC638`) and across (`0x004DC4B0`).
const worm_segments = 16;
const worm_rings = 31;
const worm_radius: f32 = 10000;
const worm_ring_spacing: f32 = 200000;
const worm_uv_along: f32 = 3.3333333e-6 * 1.6;
const worm_uv_across: f32 = 1e-4;
/// The driver's highlight texture its second pass takes (`0x00422809`).
const worm_highlight = 0;
/// How far along its colours each ring stands (`0x004DC64C`).
const worm_ring_share: f32 = 1.0 / 30.0;
/// How far its vertices sway (`0x004DC438`), and their offsets' spread (`0x004DC648`,
/// `0x004DC644`).
const worm_sway: f32 = 2000;
const worm_spread = [2]f32{ 5.3, 4.4 };
/// How fast its texture scrolls along it and across it as the gates count time, 1.05 and 0.05 of it
/// a second (`0x004DC61C`, `0x004DC408`).
const worm_scroll = [2]f32{ 10.5, 0.5 };

test Worm {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = undefined;
    const worm = try Worm.create(gpa, &image);
    defer worm.destroy(gpa);
    const grid = Worm.grid;
    // A tube 10000 across, its rings 200000 apart, drawn solid, its last band in one pass.
    try std.testing.expectEqual(srapiext.Material.Blend.off, worm.mesh.surfaces[0].material.blend[0]);
    try std.testing.expectEqual(2 * worm_segments, worm.mesh.surfaces[1].polygons);
    try std.testing.expectEqual(4 * worm_ring_spacing, worm.mesh.positions[grid.vertex(4, 0)][2]);
    // Black and clear at its ends, the proto gate's deep colour on the ring before the last.
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, worm.colours[grid.vertex(grid.rings, 5)]);
    try std.testing.expectEqual(srapiext.solid(Palette.blue.last), worm.colours[grid.vertex(grid.rings - 1, 5)]);
    // Swaying, the centre takes the last segment's place round the tube.
    worm.wobble(0);
    const centre = worm.mesh.positions[0];
    const last_turn = tunnel.segmentTurn(worm_segments - 1, worm_segments);
    try std.testing.expectEqual(@sin(last_turn) * worm_radius + tunnel.sway(0, 0, worm_spread, worm_sway)[0], centre[0]);
    // Its texture scrolls along it and back across it.
    const before = worm.mesh.uv[0].?[3];
    worm.scroll(0.1);
    const after = worm.mesh.uv[0].?[3];
    try std.testing.expect(after[0] > before[0] and after[1] < before[1]);
}
