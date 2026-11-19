//! Deathmatch Respawn Effect, order 121 in deathmatch.cpp.
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const std = @import("std");
const math = @import("../../surrender/math.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const sound3d = @import("../sound3d.zig");
const xtrabits = @import("../xtrabits.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const loadout = @import("../../interface/loadout/loadout.zig");

/// The ship takes 300 ticks to appear (0x004B0DC4).
pub const duration = 300;

/// `order_deathmatch_respawn_effect_init` (0x004B0DB0) protects the ship as it appears.
pub fn init(ctx: aigeneric.Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    slot.state.respawn_until = ctx.world.clock.frame_start + duration;
    slot.object.invulnerable = ._unknown_4;
    slot.object.flags.no_collisions = true;
    // The original enables targeting with the default flag at 0x0050C2F0.
    slot.object.flags.targetable = true;
    sound(ctx.world, index);
}

pub fn sound(world: @import("../gameobj.zig").World, index: u16) void {
    sound3d.playIn(world, null, null, index, .dmspawn1, 1, sound3d.fxClass(world.objects, index));
}

/// `order_deathmatch_respawn_effect` (0x004B0ED0) returns control at the end of the effect.
pub fn update(ctx: aigeneric.Context, index: u16) void {
    if (remaining(&ctx.world.objects.slots[index], ctx.world.clock.frame_start) == 0)
        aigeneric.end(ctx, index);
}

/// `order_deathmatch_respawn_effect_exit` (0x004B0E80) restores damage and collisions.
pub fn exit(ctx: aigeneric.Context, index: u16) void {
    const object = &ctx.world.objects.slots[index].object;
    object.flags.no_collisions = false;
    object.invulnerable = .none;
}

/// Includes a just-admitted ship whose first game frame has yet to run.
pub fn remaining(slot: *const create.Slot, now: i32) u16 {
    if (slot.running(.deathmatch_respawn_effect) == null) return 0;
    if (slot.object.order_starting) return duration;
    return @intCast(@min(duration, @max(0, slot.state.respawn_until -| now)));
}

fn phase(left: u16) f32 {
    return @as(f32, @floatFromInt(left)) / duration;
}

/// View 0x28 in `camera_frame` (0x0045FC90). The camera swings round toward the nose.
pub fn camera(ship: math.Place, left: u16) math.Place {
    const offset: math.Vector = .{ 0, 200, 1150 };
    const quarter_turn = std.math.pi / 2.0;
    const turn = math.rotation(.y, (1 - @sin(phase(left) * quarter_turn)) * std.math.pi);
    const at = ship.point(math.transform(turn, offset));
    return .{ .position = at, .orientation = math.lookAt(ship.position - at) };
}

/// The fitted clipping plane and sweep from `mp_respawn_effect_create` (0x004B1170).
pub const View = struct {
    mesh: ?srapiext.Mesh = null,
    left: [@import("spawn.zig").positions]u16 = @splat(0),
    portal_keys: [@import("spawn.zig").positions]srapiext.Portal = @splat(.{}),

    pub fn load(view: *View, gpa: std.mem.Allocator, textures: *srtexture.Table) !void {
        const image = try textures.find("dmspawn") orelse return;
        view.mesh = try loadout.addedSquare(gpa, 1, 1, true, image);
    }

    pub fn deinit(view: *View, gpa: std.mem.Allocator) void {
        if (view.mesh) |*mesh| mesh.deinit(gpa);
    }

    fn sweep(slot: *const create.Slot, left: u16) math.Place {
        const eased = (1 - @cos(phase(left) * std.math.pi)) * 0.5;
        const depth = math.lerp(slot.object.bounds_min.z, slot.object.bounds_max.z, eased);
        return .{ .position = slot.drawn.point(.{ 0, 0, depth }), .orientation = slot.drawn.orientation };
    }

    pub fn clip(view: *View, slot: *create.Slot, index: u16, portals: *xtrabits.Portals, left: u16) void {
        const last = view.left[index];
        view.left[index] = left;
        const model = if (slot.model) |*model| model else return;
        if (left == 0) {
            if (last != 0) xtrabits.clipTree(model, null);
            return;
        }
        const portal = portals.stand(&view.portal_keys[index], 0, true) orelse return;
        const place = sweep(slot, left);
        portal.position = place.position;
        portal.orientation = place.orientation;
        portal.normal = .{ 0, 0, -1 };
        xtrabits.clipTree(model, portal);
    }

    /// The order update (0x004B0ED0) draws the square and clipping plane. The beam it builds
    /// never goes into the scene.
    pub fn draw(view: *const View, gpa: std.mem.Allocator, arena: std.mem.Allocator, scene: *srcore.Scene, all: *const create.Objects) !void {
        const mesh = if (view.mesh) |*mesh| mesh else return;
        for (view.left[0..@min(view.left.len, all.playerSlotCount())], 0..) |left, index| {
            if (left == 0 or !all.slots[index].object.created) continue;
            const slot = &all.slots[index];
            const place = sweep(slot, left);
            const progress = phase(left);
            const spin = math.rotation(.z, (1 - @cos(progress * std.math.pi)) * (std.math.pi / 4.0));
            const brightness = @sin(progress * std.math.pi);
            const colours = try arena.alloc([4]f32, mesh.positions.len);
            @memset(colours, .{ brightness, brightness, brightness, 1 });
            try xtrabits.sceneAddCopy(gpa, arena, scene, .{ .own_mesh = .{ .mesh = mesh, .object = .{
                .flags = .{ .not_culled = true, .baked_object = true, .own_first = true },
                .position = place.position,
                .orientation = math.product(spin, place.orientation),
                .scale = slot.object.radius,
                .radius = mesh.radius,
                .levels = &.{},
                .baked = colours,
            } } }, .world);
        }
    }
};
