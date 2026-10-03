//! The `openreliant.nearby` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! for object scripts: the objects around the script's own (`package`).

const std = @import("std");

const openreliant = @import("openreliant");
const math = openreliant.engine.surrender.math;
const gameobj = openreliant.engine.game.gameobj;
const api = @import("api.zig");
const Call = api.Call;
const handles = @import("objects.zig");
const game = @import("game.zig");
const world = @import("world.zig");

/// What `openreliant.nearby` holds.
pub const package = struct {
    pub const objects = api.Function("The objects within `radius` of the script's object, nearest first, without it.", &.{"radius"}, objectsWithin);
};

/// `nearby.objects(radius)`.
fn objectsWithin(call: Call, radius: f32) handles.List {
    const held = game.Game.of(call, "nearby.objects");
    const own = call.context.object.?;
    const all = held.objects;
    if (!own.valid(all)) call.raise("nearby.objects: the script's object is no longer in the mission", .{});
    const centre = gameobj.vector(all.slots[own.slot].object.root.position);
    var found: handles.List = .{};
    var distances: [gameobj.max_objects]f32 = undefined;
    var walk = all.walk();
    while (walk.next()) |index| {
        if (index == own.slot or !world.inMission(all, index)) continue;
        const apart = math.distance(centre, gameobj.vector(all.slots[index].object.root.position));
        if (apart > radius) continue;
        distances[found.len] = apart;
        found.append(index);
    }
    const Order = struct {
        distances: []f32,
        slots: []u16,

        pub fn lessThan(order: @This(), a: usize, b: usize) bool {
            return order.distances[a] < order.distances[b];
        }

        pub fn swap(order: @This(), a: usize, b: usize) void {
            std.mem.swap(f32, &order.distances[a], &order.distances[b]);
            std.mem.swap(u16, &order.slots[a], &order.slots[b]);
        }
    };
    std.sort.insertionContext(0, found.len, Order{ .distances = &distances, .slots = &found.slots });
    return found;
}
