//! Start warp projection from Boridin (38) from `C:\lancer\game\wgate.cpp`: the Boridin breakaway
//! projects a warp tunnel ahead of it. Six beams run from the points of its projector to points
//! that swing to and fro about its axis, warp particles streaming from their ends, and an advanced
//! gate's red tunnel stretches out ahead of the projector over the first five seconds, its first
//! six rings lit near the beams' ends. The beams and the tunnel each show nine frames in ten.
//! [Gates](../../../../docs/engine/gates.md#the-boridins-projection) describes it.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const ease = @import("../../genilib/interf/ease.zig");
const aifuncs = @import("../aifuncs.zig");
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const particles = @import("../particles.zig");
const wgate = @import("../wgate.zig");
const xtrabits = @import("../xtrabits.zig");
const tunnel = @import("tunnel.zig");
const warp = @import("warp.zig");

const log = std.log.scoped(.wgate);

/// The beams (`0x00423111`): six, `beam_width` either side of their axis.
const beam_count = 6;
const beam_width: f32 = 1400;

/// The particles that stream from the beams' ends (`warp_large_particles`, `0x0051D138`, which
/// `wgates_init` fills): Warp Out's (`warp.beam_particles`), as large as a ship, from 1000 across
/// down to 500.
const large_particles: particles.Template = large: {
    var template = warp.beam_particles;
    template.size = .through(1000, 750, 500);
    break :large template;
};

/// How the particles leave a beam's end (`0x00423159` to `0x004231A6`): back along the world's Z
/// axis, straying up to `emitter_spread` either way, at `emitter_speed` a tick and up to
/// `emitter_speed_range` more, for `emitter_life` ticks.
const emitter_spread: f32 = 0.15;
const emitter_speed: f32 = 100;
const emitter_speed_range: f32 = 20;
const emitter_life = 10000;

/// Where beam `n` ends, in the projector's frame (`0x004232D3`): `(n + 1)` times `end_step` out
/// along its X axis, and `(5 - n)²` times the spread plus `end_ahead` along its Z axis, turned
/// about Z by `n` sixths of a turn and by the sway, the odd beams the other way. The sway runs
/// `sway_reach` either way at `sway_pace` radians a tick (`0x004DC6CC`, `0x004DC6C8`).
///
/// **Improvement:** the game takes the sway's sine from the engine's table, and turns by a rounded
/// 1.0471976 and 2.1991148; OpenReliant computes them.
const end_step: f32 = 8571.429;
const end_ahead: f32 = 75000;
const sway_pace: f32 = 0.005;
const sway_reach: f32 = 0.7 * std.math.pi;
const end_turn: f32 = std.math.pi / 3.0;

/// How far the projection spreads: its ends and its tunnel's rings stand further out by it, which
/// eases in from nothing to `full_spread` over the first `spread_ticks` (`0x0042326B`).
const full_spread: f32 = 2500;
const spread_ticks = 500;

/// The tunnel (`wgate_tunnel_build`, `0x004231DB`): an advanced gate's, red, of size `tunnel_size`
/// where the gates' are 40 or 70, its rings `r²` times the spread plus `tunnel_ahead` ahead of the
/// projector (`0x004234E0`).
const tunnel_size: f32 = 240;
const tunnel_ahead: f32 = 44000;

/// How the beams' ends light the tunnel's first `lit_rings` rings, each by its own beam's end
/// (`0x00423580`): fully up to two thirds of `1 / lit_falloff` from it, then less, and not at all
/// from `1 / lit_falloff` on. The rings after them are dark.
const lit_rings = beam_count;
const lit_falloff: f32 = 2e-5;
const lit_boost: f32 = 3;

/// The share of frames each beam and the tunnel show in, each drawn for itself (`0x004DC470`).
const shown_share: f32 = 0.9;

/// What Start warp projection from Boridin keeps in `order_state`: the tick it began, and the tick
/// of its last update.
pub const State = extern struct {
    _unknown_00: [8]u8,
    began: i32,
    _unknown_0c: [0x48 - 0x0C]u8,
    updated: i32,
    _unknown_4c: [aigeneric.state_size - 0x4C]u8,

    comptime {
        assert(@offsetOf(State, "began") == 0x08);
        assert(@offsetOf(State, "updated") == 0x48);
        assert(@sizeOf(State) == aigeneric.state_size);
    }
};

/// The projection (`0x0051D140` to `0x0051D190`, which `wgates_free` lets go): its beams, the
/// emitters at their ends, its tunnel, and what its update shows this frame.
pub const Projection = struct {
    beams: [beam_count]Beam,
    emitters: [beam_count]particles.Emitter,
    tunnel: tunnel.Tunnel,
    /// What this frame shows: which beams, and whether the tunnel.
    shown_beams: std.bit_set.Static(beam_count) = .empty,
    shown_tunnel: bool = false,

    /// A beam (`WProject Mesh`, `0x00423126`): its mesh, its object, never culled and coloured by
    /// its own colours, red and opaque at its far end and clear at its near one, and where it
    /// ends (`0x0051D160`).
    const Beam = struct {
        mesh: srapiext.Mesh,
        level: [1]srapiext.Level = undefined,
        object: srapiext.MeshObject,
        colours: [warp.beam_corners][4]f32,
        end: Vector = @splat(0),
    };

    /// `order_start_warp_projection_from_boridin_init`'s set-up (`0x004230A0`), in place: the
    /// beams over the warp beams' texture, the emitters, born at `now`, and the tunnel on the
    /// gates' grid.
    pub fn build(projection: *Projection, gates: *const wgate.Gates, now: i32) Allocator.Error!void {
        const gpa = gates.gpa;
        projection.* = .{
            .beams = undefined,
            .emitters = @splat(.{
                .born = now,
                .life = emitter_life,
                .template = &large_particles,
                .direction = .{ 0, 0, -1 },
                .spread = @splat(emitter_spread),
                .speed = emitter_speed,
                .speed_range = emitter_speed_range,
            }),
            .tunnel = undefined,
        };
        var made: usize = 0;
        errdefer for (projection.beams[0..made]) |*beam| beam.mesh.deinit(gpa);
        for (&projection.beams) |*beam| {
            beam.* = .{ .mesh = try warp.beamMesh(gpa, gates.beam, beam_width), .object = undefined, .colours = undefined };
            made += 1;
            beam.level = .{.{ .mesh = &beam.mesh, .until = std.math.inf(f32) }};
            // `0x83800`: never culled, always drawn and unbounded, and coloured by its own colours.
            beam.object = .{
                .flags = .{ .not_culled = true, .always_drawn = true, .unbounded = true, .baked_object = true },
                .position = @splat(0),
                .radius = beam.mesh.radius,
                .levels = &beam.level,
                .baked = &beam.colours,
            };
            for (&beam.colours, 0..) |*colour, corner| colour.* = if (corner % 4 == 0 or corner % 4 == 3) @splat(0) else .{ 1, 0, 0, 1 };
        }
        try projection.tunnel.build(gpa, gates.grid, gates.settings.tunnels.split(), gates.warp, .advanced, tunnel_size);
    }

    pub fn deinit(projection: *Projection, gpa: Allocator) void {
        for (&projection.beams) |*beam| beam.mesh.deinit(gpa);
        projection.tunnel.deinit(gpa);
    }

    /// The tunnel's first `lit_rings` rings each lit by its beam's end, and the rings after them
    /// dark (`0x00423580`): each of the game's vertices keeps its colour up to two thirds of
    /// `1 / lit_falloff` from the end, less of it further off, and none from `1 / lit_falloff` on.
    fn lightRings(projection: *Projection) void {
        const tube = &projection.tunnel;
        const grid = tube.grid;
        const place = tube.object.place();
        for (0..grid.rings + 1) |ring| {
            for (0..grid.segments) |segment| {
                const shade = &tube.colours[grid.vertex(ring, segment)];
                const share = if (ring < lit_rings) lit: {
                    const off = math.distance(place.point(tube.gamePosition(ring, segment)), projection.beams[ring].end);
                    break :lit std.math.clamp((1 - std.math.clamp(off * lit_falloff, 0, 1)) * lit_boost, 0, 1);
                } else 0;
                shade.* = .{ shade[0] * share, shade[1] * share, shade[2] * share, shade[3] };
            }
        }
        tube.lay();
    }

    /// The beams and the tunnel this frame's update showed, into the world's layer (`scene_add` in
    /// `order_start_warp_projection_from_boridin`); then none shows until the next update.
    pub fn draw(projection: *Projection, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        defer {
            projection.shown_beams = .empty;
            projection.shown_tunnel = false;
        }
        var shown = projection.shown_beams.iterator(.{});
        while (shown.next()) |n| try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &projection.beams[n].object }, .world);
        if (projection.shown_tunnel) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &projection.tunnel.object }, .world);
    }
};

/// `order_start_warp_projection_from_boridin_init` (`0x004230A0`): the init of Start warp
/// projection from Boridin (38). The order keeps the tick it began, the gates make the projection
/// anew (`wgate.Gates.makeProjection`), and the ship lets go of its controls. It looks up the
/// part `Warp projector 03` too (`0x004E4230`), and uses it for nothing.
///
/// **Fix:** the game stops with an assertion where the ship is no Boridin breakaway ("Error in
/// Boridin Warp Project AI"); OpenReliant logs it, and the ship projects from its projector as one
/// would, where its model has one.
pub fn init(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    if (slot.object.type.base() != .boridin_breakaway) {
        log.warn("Error in Boridin Warp Project AI: the ship in slot {d} is no Boridin breakaway", .{index});
    }
    const now = world.clock.frame_start;
    slot.state.projection.updated = now;
    slot.state.projection.began = now;
    if (world.gates) |gates| gates.makeProjection(now) catch |err| {
        log.warn("the Boridin breakaway in slot {d} projects nothing: {s}", .{ index, @errorName(err) });
    };
    slot.object.letGo();
}

/// `order_start_warp_projection_from_boridin` (`0x00423230`): the update of Start warp projection
/// from Boridin (38), which never ends. The spread eases in, from nothing to `full_spread` over the
/// first `spread_ticks`, and from where the projector stands:
///
/// 1. Each beam runs from its point of the projector's `warp_projectors` list to its end
///    (`end_step`), which swings to and fro as the sway runs; its emitter streams from the end.
/// 2. Each beam shows, `shown_share` of the time, each for itself.
/// 3. The tunnel stands at the projector, its rings stretched out by the spread
///    (`tunnel.Tunnel.stretch`), red as an advanced gate's; `shown_share` of the time its first
///    rings are lit by the beams' ends and the rest dark (`Projection.lightRings`), and its
///    texture scrolls by the time since the last update as the gates scroll a tunnel's
///    (`tunnel.Tunnel.scroll`).
/// 4. The tunnel shows, `shown_share` of the time.
///
/// **Unverified:** it lies just past the file's known code, after its init.
///
/// **Fix:** the game takes the projector and six of its points for granted: it fails where the
/// model has no projector or the projector lists no points, and reads past the list's end where it
/// lists fewer than six. OpenReliant does nothing where the projection, the projector or its points
/// are missing, and the beams past the list's end leave from its last point.
pub fn update(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const state = &slot.state.projection;
    const now = world.clock.frame_start;
    const gates = world.gates orelse return;
    const projection = gates.projection orelse return;
    const model = if (slot.model) |*live| live else return;
    const projector = model.partNamed(aifuncs.breakaway_projector) orelse return;
    const points = ((projector.data() orelse return).pointList(.warp_projectors) orelse return).points;
    if (points.len == 0) return;
    const place = slot.partPlace(projector.part()) orelse return;
    const elapsed = now -% state.began;
    const spread = if (elapsed <= spread_ticks) ease.in(0, full_spread, @as(f32, @floatFromInt(elapsed)) / spread_ticks) else full_spread;

    const sway = @sin(@as(f32, @floatFromInt(now)) * sway_pace) * sway_reach;
    for (&projection.beams, &projection.emitters, 0..) |*beam, *emitter, n| {
        const out: f32 = @floatFromInt(beam_count - 1 - n);
        const at: Vector = .{ @as(f32, @floatFromInt(n + 1)) * end_step, 0, out * out * spread + end_ahead };
        const turn = @as(f32, @floatFromInt(n)) * end_turn + sway;
        beam.end = place.point(math.transform(math.rotation(.z, if (n % 2 == 0) turn else -turn), at));
        emitter.place.position = beam.end;
        beam.object.position = place.point(gameobj.vector(points[@min(n, points.len - 1)].position));
    }
    for (&projection.beams) |*beam| {
        const length = math.distance(beam.end, beam.object.position);
        beam.object.orientation = math.lookAt(beam.end - beam.object.position);
        for (beam.mesh.positions[4..], 4..) |*corner, n| {
            if (n % 4 == 1 or n % 4 == 2) corner.*[2] = length;
        }
    }
    for (&projection.emitters, 0..) |*emitter, n| {
        _ = explode.streamWithin(world, emitter, null);
        if (world.random.fraction() < shown_share) projection.shown_beams.set(n);
    }

    const tube = &projection.tunnel;
    tube.stretch(spread, tunnel_ahead);
    tube.object.position = place.position;
    tube.object.orientation = place.orientation;
    tube.colour(.advanced);
    const since = gameobj.progressSince(&state.updated, now);
    if (world.random.fraction() < shown_share) {
        projection.lightRings();
        tube.scroll(since);
    }
    if (world.random.fraction() < shown_share) projection.shown_tunnel = true;
}

test {
    std.testing.refAllDecls(@This());
}

/// A mission for the tests: the player's ship, and a Boridin breakaway at the origin given Start
/// warp projection from Boridin, its projector's list holding four points, 10 apart up its Y axis,
/// for the six beams. It stays where `init` fills it in, as its records point into it.
const TestProjection = struct {
    run: wgate.testing.Run,
    named: objects.testing.NamedParts(1),
    kind: create.Type,
    breakaway: u16,

    fn init(t: *TestProjection, gpa: Allocator) !void {
        try t.run.init(gpa);
        errdefer t.run.deinit(gpa);
        t.named.init(.{aifuncs.breakaway_projector}, .{.warp_projectors}, .{&.{ .{ 0, 0, 0 }, .{ 0, 10, 0 }, .{ 0, 20, 0 }, .{ 0, 30, 0 } }});
        t.kind = .{ .model = &t.named.parts.source, .loaded = &t.named.parts.loaded };
        const mission = &t.run.mission;
        _ = try mission.add(.of(.predator), @splat(0));
        t.breakaway = try mission.addWith(create.testing.oneType(&t.kind), .of(.boridin_breakaway), @splat(0));
        try std.testing.expect(try aigeneric.push(t.run.orders(), t.breakaway, .start_warp_projection_from_boridin, .none));
    }

    fn deinit(t: *TestProjection, gpa: Allocator) void {
        t.run.deinit(gpa);
    }
};

test "the Boridin breakaway projects its beams and its tunnel" {
    const gpa = std.testing.allocator;
    var t: TestProjection = undefined;
    try t.init(gpa);
    defer t.deinit(gpa);
    const mission = &t.run.mission;
    const breakaway = t.breakaway;
    const ctx = t.run.orders();
    mission.slot(breakaway).object.throttle = 1;
    mission.ordersAfter(ctx, breakaway, 0);
    const projection = t.run.built.gates.projection.?;
    try std.testing.expectEqual(0, mission.slot(breakaway).object.throttle);

    // At the start the spread is nothing: the first beam ends `end_step` out and `end_ahead`
    // ahead, turned by the sway at tick 0, which is none, and runs from the first point.
    try math.testing.expectVectorWithin(.{ end_step, 0, end_ahead }, projection.beams[0].end, 1e-2);
    // The second ends twice as far out, turned a sixth of a turn, and the third three times, turned
    // a third of a turn the other way.
    try std.testing.expectApproxEqAbs(end_step, projection.beams[1].end[0], 1e-2);
    try std.testing.expectApproxEqAbs(-1.5 * end_step, projection.beams[2].end[0], 1e-2);
    try std.testing.expect(projection.beams[1].end[1] * projection.beams[2].end[1] < 0);
    try math.testing.expectVector(@splat(0), projection.beams[0].object.position);
    // The fifth and sixth beams leave from the last point the list holds.
    try math.testing.expectVector(.{ 0, 30, 0 }, projection.beams[5].object.position);
    // Each beam reaches its end.
    try std.testing.expectApproxEqRel(math.distance(projection.beams[0].end, @splat(0)), projection.beams[0].mesh.positions[5][2], 1e-5);

    // Half the spread's ticks on, the tunnel's rings stand a quarter of the full spread further
    // out for each square of their number.
    mission.ordersAfter(ctx, breakaway, spread_ticks / 2);
    const tube = &projection.tunnel;
    try std.testing.expectApproxEqAbs(tunnel_ahead + 4 * full_spread / 4, tube.gamePosition(2, 0)[2], 1e-2);
    // Lit, each vertex of the first rings keeps a share of its colour by how near its own ring's
    // beam's end it stands, and the rings after them are dark.
    tube.colour(.advanced);
    const unlit = try gpa.dupe([4]f32, tube.colours);
    defer gpa.free(unlit);
    projection.lightRings();
    var lit: usize = 0;
    for (0..tube.grid.rings + 1) |ring| for (0..tube.grid.segments) |segment| {
        const vertex = tube.grid.vertex(ring, segment);
        const off = math.distance(tube.object.place().point(tube.gamePosition(ring, segment)), projection.beams[@min(ring, beam_count - 1)].end);
        const share = if (ring < lit_rings) std.math.clamp((1 - off * lit_falloff) * lit_boost, 0, 1) else 0;
        if (share > 0) lit += 1;
        try std.testing.expectApproxEqAbs(unlit[vertex][0] * share, tube.colours[vertex][0], 1e-6);
    };
    try std.testing.expect(lit > 0);
    // Each frame the beams and the tunnel show or not, and drawing puts them in the scene.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const beams = projection.shown_beams.count();
    const tunnels: usize = @intFromBool(projection.shown_tunnel);
    try projection.draw(gpa, &scene);
    try std.testing.expectEqual(beams + tunnels, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(0, projection.shown_beams.count());
}

test "past its ease-in the spread holds, and the emitters ride the beams' ends" {
    const gpa = std.testing.allocator;
    var t: TestProjection = undefined;
    try t.init(gpa);
    defer t.deinit(gpa);
    const mission = &t.run.mission;
    const ctx = t.run.orders();
    mission.ordersAfter(ctx, t.breakaway, 0);
    const projection = t.run.built.gates.projection.?;
    const tube = &projection.tunnel;

    // Twice the spread's ticks on, its rings stand the full spread further out for each square of
    // their number, and later still they stand there yet.
    mission.ordersAfter(ctx, t.breakaway, 2 * spread_ticks);
    try std.testing.expectApproxEqAbs(tunnel_ahead + 4 * full_spread, tube.gamePosition(2, 0)[2], 1e-2);
    mission.ordersAfter(ctx, t.breakaway, spread_ticks);
    try std.testing.expectApproxEqAbs(tunnel_ahead + 4 * full_spread, tube.gamePosition(2, 0)[2], 1e-2);
    for (projection.beams, projection.emitters) |beam, emitter| try math.testing.expectVector(beam.end, emitter.place.position);
    // The order never ends.
    try std.testing.expectEqual(1, mission.slot(t.breakaway).object.order_count);
}

test "a breakaway with no projector projects nothing" {
    const gpa = std.testing.allocator;
    var run: wgate.testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    const mission = &run.mission;
    _ = try mission.add(.of(.predator), @splat(0));
    const breakaway = try mission.add(.of(.boridin_breakaway), @splat(0));
    const ctx = run.orders();
    try std.testing.expect(try aigeneric.push(ctx, breakaway, .start_warp_projection_from_boridin, .none));
    mission.ordersAfter(ctx, breakaway, 0);
    mission.ordersAfter(ctx, breakaway, 10);

    // The gates make the projection, but with no projector to stand at nothing of it shows.
    const projection = run.built.gates.projection.?;
    try std.testing.expectEqual(0, projection.shown_beams.count());
    try std.testing.expect(!projection.shown_tunnel);
    try std.testing.expectEqual(1, mission.slot(breakaway).object.order_count);
}
