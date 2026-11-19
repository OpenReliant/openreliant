//! Random power-up rings in arena games. **Unverified:** the original functions fall between
//! the known code from deathmatch.cpp and dmscenarios.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;
const create = @import("../create.zig");
const objects = @import("../objects.zig");
const xtrabits = @import("../xtrabits.zig");
const math = @import("../../surrender/math.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const loadout = @import("../../interface/loadout/loadout.zig");

const texture = "dmpowerup128-2";
const radians_per_tick = 0.052; // mp_pickup_ring_speed (0x004DCA5C)

/// All three rings on every pickup use the same mesh. Each drawn frame supplies their poses.
pub const Rings = struct {
    textures: *srtexture.Table,
    mesh: ?srapiext.Mesh = null,

    pub fn deinit(rings: *Rings) void {
        if (rings.mesh) |*mesh| mesh.deinit(rings.textures.gpa);
    }

    /// mp_random_pickup_create_rings (0x004B1D10) builds a square with one additive pass.
    fn square(rings: *Rings) Allocator.Error!?*const srapiext.Mesh {
        if (rings.mesh == null) {
            const image = try rings.textures.find(texture) orelse return null;
            rings.mesh = try loadout.addedSquare(rings.textures.gpa, 1400, 1400, false, image);
        }
        return &rings.mesh.?;
    }

    /// mp_arena_pickups_frame (0x004B18E0) turns the rings from their starting orientations
    /// using the mission tick. It skips disabled pickups.
    pub fn draw(rings: *Rings, gpa: Allocator, arena: Allocator, scene: *srcore.Scene, all: *const create.Objects, tick: i32) Allocator.Error!void {
        const angle = @as(f32, @floatFromInt(tick)) * radians_per_tick;
        const quarter = std.math.pi / 2.0;
        const around_y = math.rotation(.y, angle);
        const turns = [_]math.Matrix{
            math.rotation(.x, angle),
            math.product(comptime math.rotation(.x, quarter), around_y),
            math.product(comptime math.rotation(.y, quarter), around_y),
        };
        for (all.slots[0..all.count]) |*slot| {
            if (!slot.object.created or slot.object.flags.disabled or slot.object.type.base() != .powerup_random) continue;
            const model = if (slot.model) |*model| model else continue;
            const centre = ringCentre(model) orelse continue;
            const mesh = try rings.square() orelse return;
            const position = slot.drawn.point(centre);
            for (turns) |turn| {
                try xtrabits.sceneAddCopy(gpa, arena, scene, .{ .own_mesh = .{ .mesh = mesh, .object = .{
                    .flags = .{ .not_culled = true },
                    .position = position,
                    .orientation = math.product(slot.drawn.orientation, turn),
                    .radius = mesh.radius,
                    .levels = &.{},
                } } }, .world);
            }
        }
    }
};

/// The original reads the first two points in the first root child's first list, in root space.
fn ringCentre(model: *const objects.Model) ?math.Vector {
    _ = model.rootChild(0) orelse return null;
    const part = model.partData(0) orelse return null;
    if (part.point_lists.len == 0) return null;
    const points = part.point_lists[0].points;
    if (points.len < 2) return null;
    return (points[0].position.vector() + points[1].position.vector()) * @as(math.Vector, @splat(0.5));
}

test "random pickup rings follow the drawn root and disappear with the pickup" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var random: @import("../../random.zig").Random = .{};
    const all = try create.Objects.create(gpa, &random);
    defer all.destroy();
    var parts: objects.testing.NamedParts(1) = undefined;
    parts.init(.{"pickup"}, .{.door}, .{&.{ .{ 2, 4, 6 }, .{ 4, 8, 12 } }});
    const kinds = [_]@import("../gameobj.zig").GameType{ .powerup_random, .dm_beacon, .dm_beacon_gate };
    all.count = kinds.len;
    for (all.slots[0..all.count], kinds) |*slot, kind| {
        slot.object.type = .of(kind);
        slot.object.created = true;
        slot.object.flags = .{};
        try parts.parts.fit(gpa, slot);
    }
    const textures = try srtexture.testing.Textures.init(gpa, &.{texture});
    defer textures.deinit(gpa);
    var rings: Rings = .{ .textures = &textures.table };
    defer rings.deinit();
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const pickup = &all.slots[0];
    pickup.object.flags.disabled = true;
    try rings.draw(gpa, arena.allocator(), &scene, all, 0);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(null, rings.mesh);

    pickup.object.flags.disabled = false;
    pickup.drawn = .{ .position = .{ 30, 10, -5 }, .orientation = math.rotation(.z, 0.6) };
    for ([_]i32{ 0, 25 }) |tick| {
        scene.clear();
        try rings.draw(gpa, arena.allocator(), &scene, all, tick);
        const drawn = scene.layers.get(.world).items;
        try std.testing.expectEqual(3, drawn.len);
        const angle = @as(f32, @floatFromInt(tick)) * 0.052;
        const turns = [_]math.Matrix{
            math.turned(math.identity, .x, angle),
            math.turned(math.fromAngles(std.math.pi / 2.0, 0, 0), .y, angle),
            math.turned(math.fromAngles(0, std.math.pi / 2.0, 0), .y, angle),
        };
        for (drawn, turns) |item, turn| {
            try std.testing.expectEqual(pickup.drawn.point(.{ 3, 6, 9 }), item.mesh.position);
            for (math.product(pickup.drawn.orientation, turn), item.mesh.orientation) |want, got|
                try std.testing.expectApproxEqAbs(want, got, 1e-6);
            try std.testing.expect(item.mesh.flags.not_culled);
            try std.testing.expectEqual(&rings.mesh.?, item.mesh.levels[0].mesh);
        }
        // Collection hides the rings. Respawn uses the new pose on the next draw.
        pickup.object.flags.disabled = true;
        scene.clear();
        try rings.draw(gpa, arena.allocator(), &scene, all, tick);
        try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
        pickup.drawn.position += math.Vector{ 100, -50, 25 };
        pickup.object.flags.disabled = false;
    }

    // A replacement model can omit the second point.
    parts.lists[0][0].points = parts.lists[0][0].points[0..1];
    scene.clear();
    try rings.draw(gpa, arena.allocator(), &scene, all, 26);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}
