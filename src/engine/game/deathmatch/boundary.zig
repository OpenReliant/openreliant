//! The spherical boundary around a stock deathmatch arena, from deathmatch.cpp.
const Boundary = @This();
const std = @import("std");
const math = @import("../../surrender/math.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const deathmatch = @import("../deathmatch.zig");
const gameobj = @import("../gameobj.zig");
const guns = @import("../guns.zig");
const objects = @import("../objects.zig");
const sound3d = @import("../sound3d.zig");
const sparks = @import("../sparks.zig");
const xtrabits = @import("../xtrabits.zig");

bounds: deathmatch.Bounds,
crossed: [deathmatch.spawn.positions]?gameobj.ObjectRef = @splat(null),
flashes: Flashes = .{},

/// Past this multiple of the arena radius, place the ship back near the wall (0x004DC7EC).
const recall_limit: f32 = 1.2;
/// Place a recalled ship slightly outside the wall so the inward spring still acts (0x004DCA48).
const recall_radius: f32 = 1.01;
/// The spring and damping each use this factor (0x004DCA44).
const return_force: f32 = -0.001;

pub fn outside(boundary: *const Boundary, at: math.Vector) bool {
    return boundary.bounds.radius > 0 and math.distanceSquared(boundary.bounds.centre, at) > boundary.bounds.radius * boundary.bounds.radius;
}

/// The boundary part of `arena_frame` (0x004AEB50). The host runs the original local pilot's
/// wall response for every pilot.
pub fn frame(boundary: *Boundary, world: gameobj.World) void {
    const all = world.objects;
    for (boundary.crossed[0..@min(all.playerSlotCount(), boundary.crossed.len)], 0..) |*crossed, at| {
        const index: u16 = @intCast(at);
        const binding = all.playerBinding(index) orelse {
            crossed.* = null;
            continue;
        };
        const slot = &all.slots[at];
        const object = &slot.object;
        if (!boundary.outside(slot.drawn.position)) {
            crossed.* = null;
            continue;
        }
        if (all.player == index) world.shake.* = 1;
        const delta = object.position() - boundary.bounds.centre;
        if (math.distance(slot.drawn.position, boundary.bounds.centre) <= boundary.bounds.radius * recall_limit) {
            const factor = @as(f32, @floatFromInt(world.clock.frame_duration)) * object.mass * return_force;
            const scale: math.Vector = @splat(factor);
            gameobj.knock(object, delta * scale, object.position());
            gameobj.knock(object, object.velocity.vector() * scale, object.position());
        } else {
            const radius: math.Vector = @splat(boundary.bounds.radius * recall_radius);
            const from_centre = math.normalize(slot.drawn.position - boundary.bounds.centre);
            objects.setPosition(object, &slot.drawn, boundary.bounds.centre + from_centre * radius);
        }
        if (crossed.* != null and crossed.*.?.reuse == binding.ship.reuse) continue;
        crossed.* = binding.ship;
        const nose = math.forward(slot.drawn.orientation) * @as(math.Vector, @splat(object.radius));
        boundary.hit(world, slot.drawn.position + nose, slot.drawn.position, null);
    }
}

/// `arena_shot_check` (0x004AF0E0) checks where the bolt last stood. The shot's next position
/// gives the point the sparks come from. Turret flak bursts on its own schedule.
pub fn stopsShot(boundary: *Boundary, world: gameobj.World, index: u8, bullet: *const guns.Bullet) bool {
    if (bullet.kind.base() == .turret_flak or !boundary.outside(bullet.last)) return false;
    boundary.hit(world, bullet.at, bullet.at, .{ .index = index, .fired_at = bullet.fired_at });
    return true;
}

/// `arena_wall_hit` (0x004B02A0) sends blue sparks into the arena and flashes the point of impact.
fn hit(boundary: *Boundary, world: gameobj.World, at: math.Vector, from: math.Vector, shot: ?Impact.Shot) void {
    const now = world.clock.frame_start;
    const flare = shot == null or !boundary.flashes.matches(at, now);
    const impact: Impact = .{
        .at = at,
        .inward = math.normalize(boundary.bounds.centre - from),
        .started = now,
        .flare = flare,
        .shot = shot,
    };
    if (flare) boundary.flashes.add(impact);
    impact.present(world);
    guns.FlightEffect.emit(.{ .wall = impact }, world);
}

pub const Impact = struct {
    at: math.Vector,
    inward: math.Vector,
    started: i32,
    flare: bool,
    shot: ?Shot = null,

    pub const Shot = struct { index: u8, fired_at: i32 };

    /// The original's spark spray parameters at 0x004B04C4.
    const spray: sparks.Spray = .{ .speed = 10, .speed_range = 1, .spread = 5, .count = 10 };

    pub fn present(impact: Impact, world: gameobj.World) void {
        const direction = if (impact.flare) impact.inward else -impact.inward;
        sparks.spray(world, .shield, impact.at, direction, @splat(0), spray);
        if (impact.flare) sound3d.playIn(world, impact.at, direction, null, .shield01, 1, .not_reserved);
    }
};

/// The 32 simultaneous flashes at 0x005D7710.
pub const Flashes = struct {
    records: [32]?Flash = @splat(null),
    next: usize = 0,

    const Flash = struct { at: math.Vector, inward: math.Vector, started: i32 };
    const life = 250; // 0x004B03CF
    const repeat_window = 100; // 0x004B0342
    const span: f32 = 4000; // 0x004B03AD
    const spokes = 12; // 0x004AE979
    const rings = 8; // 0x004AE983

    fn matches(flashes: *const Flashes, at: math.Vector, now: i32) bool {
        for (flashes.records) |record| {
            const flash = record orelse continue;
            if (now - flash.started <= repeat_window and math.distanceSquared(at, flash.at) <= span * span) return true;
        }
        return false;
    }

    pub fn add(flashes: *Flashes, impact: Impact) void {
        flashes.records[flashes.next] = .{ .at = impact.at, .inward = impact.inward, .started = impact.started };
        flashes.next = (flashes.next + 1) % flashes.records.len;
    }

    /// `arena_wall_flash_create` (0x004AFF30) builds a 12-spoke mesh with eight bands.
    pub fn mesh(gpa: std.mem.Allocator, textures: *srtexture.Table) !?srapiext.Mesh {
        const image = try textures.find("dmsphere2") orelse return null;
        const polygons = 2 * spokes * rings;
        var ripple: srapiext.Mesh = try .create(gpa, .{
            .polygons = polygons,
            .vertices = spokes * (rings + 1),
            .indices = polygons * 3,
        });
        errdefer ripple.deinit(gpa);
        const uv = try ripple.addCoordinates(gpa);
        for (ripple.positions, 0..) |*at, i| {
            const sector: f32 = std.math.tau / @as(f32, spokes);
            const angle = @as(f32, @floatFromInt(i % spokes)) * sector;
            const radius = @as(f32, @floatFromInt(i / spokes)) * (span / (2 * rings));
            at.* = .{ @sin(angle) * radius, @cos(angle) * radius, 0 };
        }
        for (0..rings) |ring| for (0..spokes) |spoke| {
            const next = (spoke + 1) % spokes;
            const inner = ring * spokes;
            const outer = inner + spokes;
            const corner = (inner + spoke) * 6;
            ripple.indices[corner..][0..6].* = .{
                @intCast(inner + spoke), @intCast(outer + spoke), @intCast(inner + next),
                @intCast(inner + next),  @intCast(outer + spoke), @intCast(outer + next),
            };
        };
        for (uv, ripple.indices) |*texel, index| {
            const at = ripple.positions[index];
            const uv_scale: f32 = 0.0005; // 0x004DCA4C
            texel.* = .{ at[0] * uv_scale + 0.5, at[1] * uv_scale + 0.5 };
        }
        ripple.numberPolygons(3);
        ripple.surfaces[0] = .{
            .polygons = polygons,
            .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add }),
            .textures = .{ .{ .image = image }, .none },
        };
        srapi.calcPolyNormals(&ripple);
        srapi.calcVertexNormals(&ripple);
        srapi.findBoundingBox(&ripple);
        return ripple;
    }

    /// `arena_wall_flash_frame` (0x004B0550) moves and colours each band by the flash's age.
    pub fn draw(flashes: *const Flashes, template: *const srapiext.Mesh, gpa: std.mem.Allocator, arena: std.mem.Allocator, scene: *srcore.Scene, now: i32) !void {
        for (flashes.records) |record| {
            const flash = record orelse continue;
            const age = now - flash.started;
            if (age < 0 or age > life) continue;
            const ripple = try arena.create(srapiext.Mesh);
            ripple.* = template.*;
            ripple.positions = try arena.dupe(math.Vector, template.positions);
            const colours = try arena.alloc([4]f32, ripple.positions.len);
            const phase_per_tick: f32 = 0.008; // 0x004DC7A0
            const depth_amplitude: f32 = -250; // 0x004DCA50
            const depth_frequency = 2 * std.math.tau; // 0x004DCA54
            for (0..rings + 1) |ring| {
                const at = ring * spokes;
                const phase = 1 + @as(f32, @floatFromInt(ring)) / rings - @as(f32, @floatFromInt(age)) * phase_per_tick;
                const colour = if (ring >= rings - 1) [4]f32{ 0, 0, 0, 1 } else shade(phase);
                @memset(colours[at..][0..spokes], colour);
                const depth = if (ring < rings and phase > 0) @sin(phase * depth_frequency) * depth_amplitude else 0;
                for (ripple.positions[at..][0..spokes]) |*point| point[2] = depth;
            }
            try xtrabits.sceneAddCopy(gpa, arena, scene, .{ .own_mesh = .{ .mesh = ripple, .object = .{
                .flags = .{ .not_culled = true, .baked_object = true, .own_first = true },
                .position = flash.at,
                .orientation = math.lookAt(flash.inward),
                .radius = ripple.radius,
                .levels = &.{},
                .baked = colours,
            } } }, .world);
        }
    }

    /// `arena_wall_flash_colour` (0x004B0C10), using the hardware renderer's colours.
    fn shade(phase: f32) [4]f32 {
        const peak = 0.6; // 0x004DC4B4
        const tail = 0.4; // 0x004DC4DC
        const cutoff = 0.35; // 0x004DC838
        const brightness = 0.42; // 0x004B0D30
        if (phase >= 1 or phase <= cutoff) return .{ 0, 0, 0, 1 };
        if (phase > peak) {
            const level = ease((1 - phase) / (1 - peak)) * brightness;
            return .{ level * 0.5, 0, level, 1 };
        }
        if (phase > tail) {
            const level = ease((peak - phase) / (peak - tail));
            return .{ (1 - level) * 0.5 * brightness, 0, math.lerp(@as(f32, 1), 0.3, level) * brightness, 1 };
        }
        return .{ 0, 0, 0.3 * (1 - ease((peak - phase) / peak)) * brightness, 1 };
    }

    fn ease(share: f32) f32 {
        return (1 - @cos(share * std.math.pi)) * 0.5;
    }
};

test "the wall recalls a ship once and suppresses a nearby bolt flash" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ship = try mission.add(.of(.predator), .{ 0, 0, 1300 });
    const all = mission.objects;
    all.players = ship + 1;
    const pilot = all.joinParticipant(ship).?;
    _ = all.bindParticipant(pilot, .of(all, ship)).?;
    const world = mission.world();
    var boundary: Boundary = .{ .bounds = .{ .centre = @splat(0), .radius = 1000 } };
    boundary.frame(world);
    try std.testing.expectEqual(@as(math.Vector, .{ 0, 0, 1010 }), all.slots[ship].drawn.position);
    try std.testing.expectEqual(@as(usize, 1), boundary.flashes.next);
    boundary.frame(world);
    try std.testing.expectEqual(@as(usize, 1), boundary.flashes.next);

    var bolt: guns.Bullet = .{ .last = .{ 0, 0, 1001 }, .at = .{ 0, 0, 1100 } };
    try std.testing.expect(boundary.stopsShot(world, 0, &bolt));
    try std.testing.expectEqual(@as(usize, 1), boundary.flashes.next);
    bolt.kind = .of(.turret_flak);
    try std.testing.expect(!boundary.stopsShot(world, 0, &bolt));
    mission.clock.frame_start = Flashes.repeat_window + 1;
    bolt.kind = .of(.laser_cannon);
    try std.testing.expect(boundary.stopsShot(world, 0, &bolt));
    try std.testing.expectEqual(@as(usize, 2), boundary.flashes.next);
}
