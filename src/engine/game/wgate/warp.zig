//! Warp Out and Warp In from `C:\lancer\game\wgate.cpp`. The orders share a tunnel record,
//! preserving the departure sequence number when Warp Out queues Warp In.

const std = @import("std");
const math = @import("../../surrender/math.zig");
const ease = @import("../../genilib/interf/ease.zig");
const aigeneric = @import("../aigeneric.zig");
const ai = @import("../ai.zig");
const cloak = @import("../cloak.zig");
const events = @import("../mission/events.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const sound3d = @import("../sound3d.zig");
const wgate = @import("../wgate.zig");
const xtrabits = @import("../xtrabits.zig");
const particles = @import("../particles.zig");
const explode = @import("../explode.zig");
const guns = @import("../guns.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const create = @import("../create.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const jump = @import("../jump.zig");

/// Projector beam layout and emitter settings (`0x0041D2B0`, `wgate_create`, `0x0041FE60`).
const beam_count = 4;
const beam_blades = 3;
const beam_width: f32 = 110;
const beam_length: f32 = 400;
const beam_source_ahead: f32 = 300;
const beam_span = [2][2]f32{ .{ 0.04, 0.04 }, .{ 0.99, 0.99 } };
const emitter_life = 10000;
const emitter_spread: f32 = 0.15;
const emitter_speed: f32 = 10;
const emitter_speed_range: f32 = 2;
const emitter_start_radius: f32 = -30;
const beam_fade_at: f32 = 0.9;
const beam_bright: f32 = 1;
/// Endpoint spin ramps (`0x004DC3F8`, `0x004DC484`, `0x004DC56C`, `0x004DC530`).
const spin_rise_end: f32 = 0.2;
const spin_fall_start: f32 = 0.7;
const spin_min: f32 = 1;
const spin_max: f32 = 6;
/// Ring-depth oscillation beyond progress 1 (`0x004DC3F8`, `0x004DC410`).
const depth_wave: f32 = 0.2;
const depth_floor: f32 = 0.8;
/// Departure fade starts at this fraction (`0x004DC4C0`, `0x004DC5DC`).
const departure_fade_start: f32 = 0.3;
/// Fighter stretching window and maximum length (`0x004DC3F8`, `0x004DC4B4`,
/// `0x004DC59C`, `order_warp_out` step 5).
const stretch_end: f32 = 0.6;
const stretch_length: f32 = 5;
/// Tunnel spin is half the endpoint rate (`0x004DC408`, `order_warp_in`).
const arrival_spin_share: f32 = 0.5;
const extension_spin: f32 = -3;
/// Player warp corridor cleared before opening (`order_warp_out`).
const clearing_reach: f32 = 500000;

/// Warp particles from `wgates_init` (`0x0041E280`, `0x0051D194`).
const warp_particles: particles.Template = .{
    .life = 120,
    .life_spread = 10,
    .rate = .through(1200, 1200, 1200),
    .size = .through(50, 33, 25),
    .colour = .{ .through(0.3, 0.03, 0), .through(0.3, 0, 0), .through(0.3, 0.15, 0) },
};

/// Four projector beams and emitters (`warp_beam_build`, `0x0041D2B0`).
pub const Effect = struct {
    meshes: [beam_count]srapiext.Mesh,
    levels: [beam_count][1]srapiext.Level,
    emitters: [beam_count]particles.Emitter,
    objects: [beam_count]srapiext.MeshObject = undefined,
    colours: [beam_count][(beam_blades + 1) * 4][4]f32 = undefined,
    angle: f32 = 0,
    spin: f32 = 0,
    brightness: f32 = beam_bright,

    pub fn init(gpa: std.mem.Allocator, image: *srtexture.Image, now: i32) !Effect {
        var result: Effect = .{
            .meshes = undefined,
            .levels = undefined,
            .emitters = @splat(.{ .born = now, .life = emitter_life, .template = &warp_particles, .direction = .{ 0, 0, -1 }, .spread = @splat(emitter_spread), .speed = emitter_speed, .speed_range = emitter_speed_range }),
        };
        var made: usize = 0;
        errdefer for (result.meshes[0..made]) |*mesh| mesh.deinit(gpa);
        for (&result.meshes) |*mesh| {
            mesh.* = try beamMesh(gpa, image);
            made += 1;
        }
        for (&result.emitters, 0..) |*emitter, n| {
            const phase = (@as(f32, @floatFromInt(n)) - 1) * std.math.pi / 2.0;
            emitter.place.position = math.transform(math.rotation(.z, phase), .{ 0, emitter_start_radius, 0 });
        }
        return result;
    }

    pub fn deinit(effect: *Effect, gpa: std.mem.Allocator) void {
        for (&effect.meshes) |*mesh| mesh.deinit(gpa);
    }

    pub fn draw(effect: *Effect, gpa: std.mem.Allocator, scene: *srcore.Scene, record: *wgate.Record, all: *const create.Objects) !void {
        const slot = &all.slots[record.slot];
        if (slot.running(.warp_out) == null or slot.state.warp.step != @intFromEnum(OutStep.open)) return;
        const sources = projectorSources(slot);
        for (effect.emitters, &effect.objects, &effect.meshes, &effect.levels, &effect.colours, sources) |emitter, *object, *mesh, *level, *colours, source| {
            const target = record.warp_place.point(emitter.place.position);
            const distance = math.distance(source, target);
            for (mesh.positions[4..], 0..) |*position, n| if (n % 4 == 1 or n % 4 == 2) {
                position[2] = distance;
            };
            // The original supplies red colours, but its unlit material draws the texture alone.
            for (colours, 0..) |*colour, n| colour.* = .{ 1, 0, 0, if (n % 4 == 1 or n % 4 == 2) @max(effect.brightness, 0) else 0 };
            srapi.calcPolyNormals(mesh);
            srapi.calcVertexNormals(mesh);
            srapi.findBoundingBox(mesh);
            level.* = .{.{ .mesh = mesh, .until = std.math.inf(f32) }};
            object.* = .{
                .flags = .{ .not_culled = true, .baked_object = true },
                .position = source,
                .orientation = math.lookAt(target - source),
                .radius = distance,
                .levels = level,
                .baked = colours,
            };
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = object }, .world);
        }
    }

    fn stream(effect: *Effect, world: gameobj.World, record: *wgate.Record, progress: f32, delta: f32) void {
        const radius_now = radius(record, progress);
        const slot = &world.objects.slots[record.slot];
        const spacing = if (slot.object.flags.components) capital_spacing else fighter_spacing;
        const depth = ease.out(0, @as(f32, @floatFromInt(record.tunnel.grid.rings)) * spacing, progress);
        const spin = if (progress < spin_rise_end)
            ease.cosine(spin_min, spin_max, progress / spin_rise_end)
        else if (progress < spin_fall_start)
            spin_max
        else
            ease.cosine(spin_max, 0, (progress - spin_fall_start) / (1 - spin_fall_start));
        effect.spin = spin;
        effect.angle += delta * spin;
        effect.brightness = if (progress > beam_fade_at) ease.linear(beam_bright, 0, (progress - beam_fade_at) / (1 - beam_fade_at)) else beam_bright;
        for (&effect.emitters, 0..) |*emitter, n| {
            const phase = @as(f32, @floatFromInt(n)) * std.math.pi / 2.0 + if (n % 2 == 0) effect.angle else -effect.angle;
            if (depth > mouth_depth) {
                emitter.place.position = .{ -@sin(phase) * radius_now, @cos(phase) * radius_now, depth + record.deeper };
            } else {
                const initial = math.transform(math.rotation(.z, (@as(f32, @floatFromInt(n)) - 1) * std.math.pi / 2.0), .{ 0, emitter_start_radius, 0 });
                emitter.place.position = math.transform(math.rotation(.z, if (n % 2 == 0) effect.angle else -effect.angle), initial) + math.Vector{ 0, 0, depth + record.deeper };
            }
            emitter.place.orientation = math.rotation(.z, if (n % 2 == 0) effect.angle else -effect.angle);
            _ = explode.streamWithin(world, emitter, record.warp_place);
        }
    }
};

/// `warp_beam_build` (`0x0041D2B0`): an end quad followed by three longitudinal blades.
/// Shares quad numbering and mesh construction with gun beams, without adding a second shape.
fn beamMesh(gpa: std.mem.Allocator, image: *srtexture.Image) std.mem.Allocator.Error!srapiext.Mesh {
    var corners: [(beam_blades + 1) * 4]math.Vector = undefined;
    var uv: [corners.len][2]f32 = undefined;
    var faces: [beam_blades + 1][4]u16 = undefined;
    corners[0..4].* = .{ .{ -beam_width, -beam_width, 0 }, .{ beam_width, -beam_width, 0 }, .{ beam_width, beam_width, 0 }, .{ -beam_width, beam_width, 0 } };
    uv[0..4].* = guns.bladeCorners(beam_span);
    faces[0] = guns.quadFace(0);
    for (0..beam_blades) |n| {
        corners[(n + 1) * 4 ..][0..4].* = guns.blade(n, beam_blades, beam_width, .{ 0, beam_length });
        uv[(n + 1) * 4 ..][0..4].* = guns.bladeCorners(beam_span);
        faces[n + 1] = guns.quadFace(n + 1);
    }
    return guns.meshOf(4, gpa, &corners, &faces, &uv, guns.meshMaterial(false), image);
}

/// `warp_projector_beams` (`0x0041D510`): point group 10 supplies the projector origin.
/// The Yamato uses four points on Yam_Warp_Proj_3; other ships repeat their first point.
fn projectorSources(slot: *const create.Slot) [beam_count]math.Vector {
    var result: [beam_count]math.Vector = @splat(slot.drawn.ahead(beam_source_ahead));
    const model = if (slot.model) |*held| held else return result;
    var parts = model.rootChildren();
    while (parts.next()) |part| {
        if (slot.object.type == .yamato and !std.ascii.eqlIgnoreCase(model.source.parts[part.index].part.name(), "Yam_Warp_Proj_3")) continue;
        const groups = model.source.parts[part.index].point_lists;
        for (groups) |group| {
            if (group.kind != .warp_projectors or group.points.len == 0) continue;
            const place = model.frameAt(part.index, slot.drawn);
            for (&result, 0..) |*source, n| {
                const point = group.points[if (slot.object.type == .yamato) @min(n, group.points.len - 1) else 0];
                source.* = place.point(gameobj.vector(point.position));
            }
            return result;
        }
    }
    return result;
}

/// The shared order state (`order_warp_out_init`, `0x0041E550`).
pub const State = extern struct {
    record: i32,
    step: i32,
    updated: i32,
    orientation: math.Matrix,
    _unknown_30: [0x3c - 0x30]u8,
    position: [3]f32,
    _unknown_48: [0x90 - 0x48]u8,

    comptime {
        std.debug.assert(@offsetOf(State, "step") == 4);
        std.debug.assert(@offsetOf(State, "orientation") == 0x0c);
        std.debug.assert(@offsetOf(State, "position") == 0x3c);
        std.debug.assert(@sizeOf(State) == 0x90);
    }
};

const OutStep = enum(i32) { aligning = 0, create = 1, begin = 2, open = 3, extend = 4, enter = 5, finish = 6, _ };
const InStep = enum(i32) { place = 0, begin = 1, emerge = 2, settle = 3, finish = 4, _ };
/// Original timing scale and progress rates (`0x004DC418`, `0x004DC3D8`, `0x004DC424`,
/// `0x004DC5D8`, `0x004DC5F0`, `0x004DC56C`).
const opening_rate: f32 = 3;
const extending_rate: f32 = 4;
const entering_rate: f32 = 2.7;
const emerging_rate: f32 = 4.5;
const settling_rate: f32 = 5;
/// Alignment limit/tolerance and arrival spread (`0x0041E710`, `0x004DC474`, `0x004DC508`).
const align_limit: f32 = 0.8;
const align_tolerance: f32 = 0.05;
const arrival_spread: f32 = 3000;
/// Warp ring spacing and minimum depth (`order_warp_out`, `0x004DC5EC`).
const fighter_spacing: f32 = 900;
const capital_spacing: f32 = 4000;
const mouth_depth: f32 = 800;
/// Scripted departure translation (`0x004DC5E0`, `0x004DC5E4`, `0x004DC5E8`).
const departure_speed: f32 = 100000;
const depth_speed: f32 = 47.7;
const capital_depth_speed: f32 = 5.5;
/// Arrival placement and reveal point at the highest detail (`order_warp_in`, `0x004DC4DC`).
const arrival_back: f32 = 20000;
const arrival_back_low: f32 = 15000;
const reveal_at: f32 = 0.4;
/// Yamato arrival offset and translation coefficients (`order_warp_in`, `0x004DC5F4`,
/// `0x004DC5F8`). Its motion stays frozen while the sequence moves its frame explicitly.
const yamato_tunnel_ahead: f32 = 210000;
const yamato_slowing: f32 = 1.6666666;
const yamato_depth_speed: f32 = 20.5;
const warp_throttle: f32 = 2;
/// End-ring flare multiplier (`0x004DC4E0`) and minimum arrival radius (`order_warp_in`).
const end_radius: f32 = 1.5;
const closed_radius: f32 = 0.05;
/// Arrival expansion changes to contraction halfway through (`0x004DC408`, `0x004DC4A4`).
const arrival_peak: f32 = 0.5;

/// `order_warp_out_init` (`0x0041E550`): clears controls, starts alignment and asks player
/// slots to uncloak, including ships launching from them through the shared cloak setter.
pub fn outInit(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.object.letGo();
    slot.state.warp = std.mem.zeroes(State);
    slot.state.warp.record = -1;
    slot.state.warp.updated = ctx.world.clock.frame_start;
    if (index < ctx.world.objects.players) cloak.set(ctx.world, index, false);
}

/// `warp_arrival_position` (`0x0041E660`): alternates ships across the target's X axis by
/// their order sequence: 0, -3000, +3000, -6000, +6000.
fn arrival(target: math.Place, sequence: i16) math.Vector {
    const number: i32 = @as(i32, sequence) + 1;
    const side: i32 = (@as(i32, @intCast(@as(u32, @bitCast(number)) & 1)) * 2 - 1) * @divTrunc(number, 2);
    return target.point(.{ @as(f32, @floatFromInt(side)) * arrival_spread, 0, 0 });
}

/// `order_warp_in_init` (`0x0041E5C0`): stops the ship and records its arrival position and
/// orientation. A departure record is reused; an independently assigned Warp In makes one.
pub fn inInit(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const target = slot.orders[0].target.slotIn(all) orelse return;
    ai.stop(&slot.object);
    const state = &slot.state.warp;
    state.* = std.mem.zeroes(State);
    state.orientation = all.slots[target].drawn.orientation;
    state.position = arrival(all.slots[target].drawn, slot.orders[0].sequence);
    state.updated = world.clock.frame_start;
    if (world.gates) |gates| {
        if (gates.of(index) == null) {
            if (gates.make(world, index, .warp, @splat(0)) catch |err| missing: {
                std.log.scoped(.wgate).warn("cannot create arrival tunnel for object {d}: {s}", .{ index, @errorName(err) });
                break :missing null;
            }) |_| {
                slot.object.flags.frozen = true;
                slot.object.flags.unpowered = true;
            }
        }
    }
}

fn recordFor(ctx: aigeneric.Context, index: u16) ?*wgate.Record {
    const gates = ctx.world.gates orelse return null;
    return gates.of(index);
}

/// Warp updates count elapsed ticks unsigned, as the record clock does (`0x0041E710`).
fn elapsed(state: *State, now: i32) f32 {
    const ticks: u32 = @bitCast(now -% state.updated);
    state.updated = now;
    return @as(f32, @floatFromInt(ticks)) * gameobj.progress_per_tick;
}

fn advance(state: *State, step: anytype, record: ?*wgate.Record) void {
    state.step = @intFromEnum(step);
    if (record) |held| held.progress = 0;
}

/// `order_warp_out` (`0x0041E710`): aligns the ship, opens and extends its tunnel, moves the
/// ship through the portal, then queues Warp In with the same sequence number.
pub fn outUpdate(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.warp;
    const target = slot.orders[0].target.slotIn(all) orelse return aigeneric.end(ctx, index);
    if (index < all.players) if (world.variables) |variables| {
        variables.ready.warp = .no;
    };
    const delta = elapsed(state, world.clock.frame_start);
    const record = recordFor(ctx, index);
    switch (@as(OutStep, @enumFromInt(state.step))) {
        .aligning => {
            if (index == all.player) {
                if (slot.object.flags.cloaked) return;
                objects.setPlace(&slot.object, &slot.drawn, .{ .position = slot.drawn.position, .orientation = math.lookAt(all.slots[target].drawn.position - slot.drawn.position) });
                const end = slot.drawn.ahead(clearing_reach);
                for (all.slots[0..all.count], 0..) |*other, n| {
                    if (other.object.flags.outOfFrame()) continue;
                    if (other.running(.warp_out)) |order| if (order.target.slot() == target) continue;
                    const model = if (other.model) |*held| held else continue;
                    if (objects.Box.ofBounds(model, other.drawn).meetsSegment(slot.drawn.position, end)) jump.markJumping(all, @intCast(n));
                }
            } else {
                _ = ai.steer(world, index, all.slots[target].drawn.position, align_limit, ai.no_ease, .{});
                const controls = [_]f32{ slot.object.pitch_input, slot.object.yaw_input, slot.object.roll_input, slot.object.pitch_rate, slot.object.yaw_rate, slot.object.roll_rate };
                for (controls) |input| if (@abs(input) > align_tolerance) return;
            }
            sound3d.playIn(world, null, null, index, .warpproject, 1, sound3d.fxClass(all, index));
            state.orientation = slot.object.root.next_orientation;
            if (index == all.player) if (world.camera) |view| {
                _ = view.setView(.warp_prepare, index, true, true, world.clock.viewTime());
            };
            advance(state, OutStep.create, null);
        },
        .create => {
            state.position = slot.drawn.position;
            state.orientation = slot.object.root.orientation;
            if (world.gates) |gates| _ = gates.make(world, index, .warp, @splat(0)) catch |err| {
                std.log.scoped(.wgate).warn("cannot create departure tunnel for object {d}: {s}", .{ index, @errorName(err) });
            };
            slot.object.flags.frozen = true;
            slot.object.flags.unpowered = true;
            advance(state, OutStep.begin, recordFor(ctx, index));
        },
        .begin => {
            if (record) |held| held.warp_shown = true;
            advance(state, OutStep.open, record);
        },
        .open => {
            const held = record orelse return abort(ctx, index);
            if (held.progress > 1) return advance(state, OutStep.extend, held);
            openingShape(held, slot.object.flags.components, held.progress);
            if (held.warp_effect) |*effect| effect.stream(world, held, held.progress, delta);
            held.progress += delta * opening_rate;
        },
        .extend => {
            const held = record orelse return abort(ctx, index);
            if (held.progress > 1) {
                slot.object.throttle = warp_throttle;
                held.tunnel.reshapeWarp(world.clock.frame_start, held.deeper);
                held.portalSetUp();
                if (slot.model) |*model| xtrabits.clipTree(model, &held.portal);
                sound3d.playIn(world, null, null, index, .warpout, 1, sound3d.fxClass(all, index));
                if (index == all.player) if (world.camera) |view| {
                    const switched = view.switched;
                    _ = view.setView(.warp_depart, index, true, true, world.clock.viewTime());
                    view.switched = switched;
                };
                return advance(state, OutStep.enter, held);
            }
            extendedShape(held, slot.object.flags.components, held.progress);
            if (held.warp_effect) |*effect| {
                effect.spin = if (held.progress < departure_fade_start)
                    ease.cosine(0, extension_spin, held.progress / departure_fade_start)
                else
                    extension_spin;
                effect.angle += delta * effect.spin;
            }
            held.progress += delta * extending_rate;
        },
        .enter => {
            const held = record orelse return abort(ctx, index);
            if (held.progress >= 1) return advance(state, OutStep.finish, held);
            const distance = if (slot.object.type == .badanov or slot.object.type == .yamato)
                held.deeper * capital_depth_speed + slot.object.bounds_max.z - slot.object.bounds_min.z
            else
                held.deeper * depth_speed + departure_speed;
            objects.setPosition(&slot.object, &slot.drawn, slot.drawn.ahead(distance * delta));
            if (held.progress > departure_fade_start) held.tunnel.fadeOut((held.progress - departure_fade_start) / (1 - departure_fade_start));
            if (held.warp_effect) |*effect| {
                effect.angle += delta * effect.spin;
                if (held.progress > departure_fade_start) effect.spin = ease.cosine(extension_spin, 0, (held.progress - departure_fade_start) / (1 - departure_fade_start));
            }
            held.progress += delta * entering_rate;
        },
        .finish => {
            objects.setPlace(&slot.object, &slot.drawn, .{ .position = slot.drawn.position, .orientation = state.orientation });
            if (slot.model) |*model| xtrabits.clipTree(model, null);
            slot.object.flags.hidden = true;
            const sequence = slot.orders[0].sequence;
            aigeneric.end(ctx, index);
            if (target != index) {
                if (aigeneric.giveShip(ctx, index, .warp_in, target, null)) slot.orders[0].sequence = sequence;
            } else if (world.gates) |gates| {
                if (record) |held| gates.freeRecord(held);
            }
        },
        _ => {},
    }
}

/// `order_warp_out` step 5 stretches a fighter's drawn frame along Z while it enters.
/// Apply it after `frameTree`, which rebuilds OpenReliant's interpolated frame each frame.
pub fn frame(slot: *create.Slot, record: ?*const wgate.Record) void {
    if (slot.running(.warp_out) == null or slot.state.warp.step != @intFromEnum(OutStep.enter) or slot.object.flags.components) return;
    const held = record orelse return;
    if (held.progress <= spin_rise_end or held.progress >= stretch_end) return;
    const length = ease.in(1, stretch_length, (held.progress - spin_rise_end) / (stretch_end - spin_rise_end));
    slot.drawn.orientation = math.product(slot.drawn.orientation, math.scaling(.{ 1, 1, length }));
    if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
}

/// `order_warp_in` (`0x0041F260`): opens the arrival tunnel, reveals the ship during its
/// emergence, then removes the tunnel, restores its flags and posts JumpedIn.
pub fn inUpdate(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.warp;
    const held = recordFor(ctx, index) orelse return abort(ctx, index);
    const delta = elapsed(state, world.clock.frame_start);
    held.tunnel.scrollArrival(delta);
    switch (@as(InStep, @enumFromInt(state.step))) {
        .place => {
            held.warp_shown = false;
            // The continuation restores sequence after pushing the order. Resolve arrival here
            // as well so hooks and the restored sequence affect the actual placement.
            if (slot.orders[0].target.slotIn(all)) |target| {
                state.position = arrival(all.slots[target].drawn, slot.orders[0].sequence);
            }
            if (index == all.player) if (world.camera) |view| {
                _ = view.setView(.warp_arrive, index, true, true, world.clock.viewTime());
            };
            if (index == all.player) {
                for (all.slots[0..all.count]) |*other| other.object.flags.jumping = false;
                if (world.environment) |environment| environment.update();
            }
            sound3d.playIn(world, null, null, index, .warpin, 1, sound3d.fxClass(all, index));
            slot.object.flags.disabled = false;
            objects.setPlace(&slot.object, &slot.drawn, .{ .position = state.position, .orientation = state.orientation });
            held.warp_place = .{ .position = state.position, .orientation = math.turned(state.orientation, .y, std.math.pi) };
            if (slot.object.type == .yamato) held.warp_place.position = @as(math.Vector, state.position) + math.forward(state.orientation) * @as(math.Vector, @splat(yamato_tunnel_ahead));
            const back = if (held.tunnel.grid.segments < wgate.tunnel.Grid.of(.high).segments) arrival_back_low else arrival_back;
            objects.setPosition(&slot.object, &slot.drawn, @as(math.Vector, state.position) - math.forward(state.orientation) * @as(math.Vector, @splat(back)));
            slot.object.flags.hidden = true;
            slot.object.flags.frozen = slot.object.type == .yamato;
            slot.object.flags.unpowered = slot.object.type == .yamato;
            slot.object.throttle = 1;
            advance(state, InStep.begin, held);
            if (world.gates) |gates| held.tunnel.colour(.warp, gates.hardware);
            for (held.tunnel.radii) |*r| r.* = closed_radius;
            held.tunnel.reshapeWarp(world.clock.frame_start, held.deeper);
            held.portalSetUp();
            if (slot.model) |*model| xtrabits.clipTree(model, &held.portal);
        },
        .begin => {
            held.warp_shown = true;
            slot.object.flags.no_collisions = true;
            advance(state, InStep.emerge, held);
        },
        .emerge => {
            arrivalShape(held, slot.object.flags.components, held.progress);
            if (held.progress >= reveal_at) {
                slot.object.flags.hidden = false;
                if (slot.object.type == .yamato) {
                    const speed = (1 - (held.progress - reveal_at) * yamato_slowing) *
                        (held.deeper * yamato_depth_speed + slot.object.bounds_max.z - slot.object.bounds_min.z);
                    objects.setPosition(&slot.object, &slot.drawn, slot.drawn.ahead(speed * delta));
                } else slot.object.throttle = warp_throttle;
            }
            held.progress += delta * emerging_rate;
            if (held.progress > 1) advance(state, InStep.settle, held);
        },
        .settle => {
            held.warp_shown = false;
            held.progress += delta * settling_rate;
            if (held.progress > 1) advance(state, InStep.finish, held);
        },
        .finish => {
            if (index == all.player) if (world.camera) |view| {
                _ = view.setView(.cockpit, index, false, true, world.clock.viewTime());
            };
            slot.object.flags.no_collisions = false;
            slot.object.flags.frozen = false;
            slot.object.flags.unpowered = false;
            if (slot.model) |*model| xtrabits.clipTree(model, null);
            if (world.gates) |gates| gates.freeRecord(held);
            aigeneric.end(ctx, index);
            events.jumpedIn(world, index);
            return;
        },
        _ => {},
    }
    if (held.warp_effect) |effect| held.warp_place.orientation = math.turned(held.warp_place.orientation, .z, delta * effect.spin * arrival_spin_share);
}

/// **Fix:** allocation failure or a removed tunnel must not leave the order frozen forever.
fn abort(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.object.flags.frozen = false;
    slot.object.flags.unpowered = false;
    slot.object.flags.no_collisions = false;
    slot.object.flags.hidden = false;
    if (slot.model) |*model| xtrabits.clipTree(model, null);
    if (index == ctx.world.objects.player) if (ctx.world.camera) |view| {
        _ = view.setView(.cockpit, index, false, true, ctx.world.clock.viewTime());
    };
    aigeneric.end(ctx, index);
}

/// Arrival radii expand and collapse while depth waves run from ring to ring
/// (`order_warp_in`, `0x0041F260`). The final radius is scaled from its preceding ring.
fn arrivalShape(record: *wgate.Record, capital: bool, progress: f32) void {
    const tunnel = &record.tunnel;
    const spacing = if (capital) capital_spacing else fighter_spacing;
    const rings: f32 = @floatFromInt(tunnel.grid.rings);
    const ramp = if (progress < arrival_peak) progress / arrival_peak else (1 - progress) / (1 - arrival_peak);
    for (tunnel.radii, tunnel.depths, 0..) |*r, *z, n| {
        const ring = @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(tunnel.split));
        const phase = ring / rings;
        const from = (ring + 1) * spacing + mouth_depth;
        const to = (2 * rings + 1) * spacing + mouth_depth - (ring + 1) * spacing;
        if (phase < 1) z.* = depthBetween(from, to, (progress + 1 - phase) / (1 - phase));
        r.* = ease.cosine(closed_radius, radius(record, phase), ramp);
    }
    const last = tunnel.radii.len - 1;
    tunnel.radii[last] = tunnel.radii[last - tunnel.split] * end_radius;
    tunnel.depths[last] = tunnel.depths[last - tunnel.split];
}

/// `warp_ring_radius` (`0x0041DD20`): cosine easing from 5% to the full ship-type radius.
fn radius(record: *const wgate.Record, progress: f32) f32 {
    return ease.cosine(record.warp_size * closed_radius, record.warp_size, progress);
}

fn openingShape(record: *wgate.Record, capital: bool, progress: f32) void {
    const tunnel = &record.tunnel;
    const spacing = if (capital) capital_spacing else fighter_spacing;
    const depth = ease.out(0, @as(f32, @floatFromInt(tunnel.grid.rings)) * spacing, @max(progress, 0));
    if (depth <= mouth_depth) return;
    for (tunnel.radii, tunnel.depths, 0..) |*r, *z, n| {
        const ring = @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(tunnel.split));
        if (ring == 0) {
            r.* = radius(record, 0);
            z.* = mouth_depth;
        } else if (ring >= @trunc((depth - mouth_depth) / spacing)) {
            r.* = radius(record, progress);
            z.* = depth;
        }
    }
    tunnel.radii[tunnel.radii.len - 1] = radius(record, progress) * end_radius;
    tunnel.depths[tunnel.depths.len - 1] = tunnel.depths[tunnel.depths.len - 1 - tunnel.split];
}

/// `warp_ring_depth` (`0x0041DC60`): cosine easing with an 80% to 100% oscillation past 1.
fn depthBetween(from: f32, to: f32, progress: f32) f32 {
    const amount = if (progress < 1) (1 - @cos(progress * std.math.pi)) * 0.5 else (@cos(progress * std.math.pi) * 0.5 + 0.5) * depth_wave + depth_floor;
    return math.lerp(from, to, amount);
}

fn extendedShape(record: *wgate.Record, capital: bool, progress: f32) void {
    const tunnel = &record.tunnel;
    const spacing = if (capital) capital_spacing else fighter_spacing;
    const rings: f32 = @floatFromInt(tunnel.grid.rings);
    for (tunnel.depths, 0..) |*z, n| {
        const ring = @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(tunnel.split));
        const due = ring / (rings - 1);
        if (due > progress or due >= 1) continue;
        const from = (ring + 1) * spacing + mouth_depth;
        const to = (2 * (rings - 1) + 1) * spacing + mouth_depth - (ring + 1) * spacing;
        z.* = depthBetween(from, to, (progress - due) / (1 - due));
    }
    tunnel.depths[tunnel.depths.len - 1] = tunnel.depths[tunnel.depths.len - 1 - tunnel.split];
}

test arrival {
    try std.testing.expectEqual(math.Vector{ 0, 0, 0 }, arrival(.{}, 0));
    try std.testing.expectEqual(math.Vector{ -3000, 0, 0 }, arrival(.{}, 1));
    try std.testing.expectEqual(math.Vector{ 3000, 0, 0 }, arrival(.{}, 2));
}

test "Warp Out queues Warp In, preserves sequence and releases its record" {
    const gpa = std.testing.allocator;
    var run: wgate.testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    _ = try run.mission.add(.predator, .{ 0, 100000, 0 });
    const ship = try run.mission.add(.predator, @splat(0));
    const target = try run.mission.addOther(.{ 0, 0, 100000 });
    const ctx = run.orders();
    _ = try aigeneric.pushShip(ctx, ship, .warp_out, target, null);
    run.mission.slot(ship).orders[0].sequence = 2;
    var completed = false;
    for (0..1000) |_| {
        run.mission.clock.frame_start += 4;
        run.mission.clock.frame_duration = 4;
        aigeneric.objectOrders(ctx, ship);
        if (run.mission.slot(ship).object.order_count == 0) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
    try std.testing.expectEqual(null, run.built.gates.of(ship));
    const slot = run.mission.slot(ship);
    try std.testing.expect(!slot.object.flags.hidden and !slot.object.flags.frozen and !slot.object.flags.no_collisions);
    try std.testing.expectApproxEqAbs(3000, slot.drawn.position[0], 1e-2);
}

test "a missing warp record ends without leaving the ship frozen" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.predator, @splat(0));
    const ship = try mission.add(.predator, @splat(0));
    const target = try mission.addOther(.{ 0, 0, 100000 });
    const ctx = mission.orders();
    _ = try aigeneric.pushShip(ctx, ship, .warp_in, target, null);
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(0, mission.slot(ship).object.order_count);
    try std.testing.expect(!mission.slot(ship).object.flags.frozen);
}

test "warp beam geometry has the original cap and three blades" {
    const gpa = std.testing.allocator;
    var built: wgate.testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit(gpa);
    var effect = try Effect.init(gpa, built.gates.beam, 100);
    defer effect.deinit(gpa);
    for (effect.meshes) |mesh| {
        try std.testing.expectEqual(16, mesh.positions.len);
        try std.testing.expectEqual(4, mesh.polygons.len);
        try std.testing.expectEqual(0, mesh.positions[0][2]);
        try std.testing.expectEqual(beam_length, mesh.positions[5][2]);
        try std.testing.expectEqual(.add, mesh.surfaces[0].material.blend[0]);
        try std.testing.expectEqual(.mesh, mesh.surfaces[0].material.coordinates[0]);
    }
}

test "warp allocation failures release every partially built mesh" {
    const Trial = struct {
        fn run(gpa: std.mem.Allocator, world: gameobj.World, gates: wgate.Gates, ship: u16) !void {
            var held = gates;
            held.gpa = gpa;
            defer held.deinit();
            _ = try held.make(world, ship, .warp, @splat(0));
        }
    };
    var run: wgate.testing.Run = undefined;
    try run.init(std.testing.allocator);
    defer run.deinit(std.testing.allocator);
    const ship = try run.mission.add(.predator, @splat(0));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Trial.run, .{ run.orders().world, run.built.gates, ship });
}

test "warp rings wait for the opening depth and keep the final depth at the preceding ring" {
    const gpa = std.testing.allocator;
    var run: wgate.testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    const ship = try run.mission.add(.predator, @splat(0));
    const record = (try run.built.gates.make(run.orders().world, ship, .warp, @splat(0))).?;
    const before = try gpa.dupe(f32, record.tunnel.radii);
    defer gpa.free(before);
    openingShape(record, false, 0);
    try std.testing.expectEqualSlices(f32, before, record.tunnel.radii);
    openingShape(record, false, 0.5);
    // At half progress the square-root depth has passed seven original rings. Earlier rings
    // retain their previous values; the update threshold depends on depth, not progress alone.
    try std.testing.expectEqual(before[6 * record.tunnel.split], record.tunnel.radii[6 * record.tunnel.split]);
    try std.testing.expect(record.tunnel.radii[7 * record.tunnel.split] != before[7 * record.tunnel.split]);
    const last = record.tunnel.depths.len - 1;
    try std.testing.expectEqual(record.tunnel.depths[last - record.tunnel.split], record.tunnel.depths[last]);
    arrivalShape(record, false, 0.5);
    try std.testing.expectEqual(record.tunnel.depths[last - record.tunnel.split], record.tunnel.depths[last]);
    for (record.tunnel.depths) |depth| try std.testing.expect(std.math.isFinite(depth));
}

test "warp stretching affects the drawn fighter frame, not its flight orientation" {
    var run: wgate.testing.Run = undefined;
    try run.init(std.testing.allocator);
    defer run.deinit(std.testing.allocator);
    _ = try run.mission.add(.predator, @splat(0));
    const ship = try run.mission.add(.predator, @splat(0));
    const target = try run.mission.addOther(.{ 0, 0, 100000 });
    const ctx = run.orders();
    _ = try aigeneric.pushShip(ctx, ship, .warp_out, target, null);
    aigeneric.objectOrders(ctx, ship);
    const slot = run.mission.slot(ship);
    const record = (try run.built.gates.make(ctx.world, ship, .warp, @splat(0))).?;
    slot.state.warp.step = @intFromEnum(OutStep.enter);
    record.progress = 0.4;
    frame(slot, record);
    try std.testing.expectApproxEqAbs(2, math.length(math.forward(slot.drawn.orientation)), 1e-5);
    try std.testing.expectEqual(math.identity, slot.object.root.orientation);
}

test "Warp In restores a reused tunnel's colours after the departure fade" {
    const gpa = std.testing.allocator;
    var run: wgate.testing.Run = undefined;
    try run.init(gpa);
    defer run.deinit(gpa);
    _ = try run.mission.add(.predator, @splat(0));
    const ship = try run.mission.add(.predator, @splat(0));
    const target = try run.mission.addOther(.{ 0, 0, 100000 });
    const ctx = run.orders();
    const record = (try run.built.gates.make(ctx.world, ship, .warp, @splat(0))).?;
    const colours = try gpa.dupe([4]f32, record.tunnel.colours);
    defer gpa.free(colours);
    record.tunnel.fadeOut(0.9);
    try std.testing.expect(!std.mem.eql(u8, std.mem.sliceAsBytes(colours), std.mem.sliceAsBytes(record.tunnel.colours)));
    _ = try aigeneric.pushShip(ctx, ship, .warp_in, target, null);
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqualSlices([4]f32, colours, record.tunnel.colours);
}
