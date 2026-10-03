//! The `openreliant.nearby` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! for object scripts: the objects around the script's own (`package`).

const std = @import("std");

const openreliant = @import("openreliant");
const math = openreliant.engine.surrender.math;
const gameobj = openreliant.engine.game.gameobj;
const api = @import("api.zig");
const Call = api.Call;
const handles = @import("objects.zig");
const world = @import("world.zig");
const Object = openreliant.engine.hooks.Object;

/// What `openreliant.nearby` holds.
pub const package = struct {
    pub const objects = api.Function("The objects within `radius` of the script's object, or of the player's ship for a player script, nearest first, without it.", &.{"radius"}, objectsWithin);
};

/// `nearby.objects(radius)`.
fn objectsWithin(call: Call, radius: f32) handles.List {
    const all = call.runtime().objects orelse call.raise("nearby.objects can only be used while a game runs", .{});
    const own = call.context.object orelse handles.Handle.of(all, all.player);
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
        found.append(.of(index));
    }
    const Order = struct {
        distances: []f32,
        objects: []Object,

        pub fn lessThan(order: @This(), a: usize, b: usize) bool {
            return order.distances[a] < order.distances[b];
        }

        pub fn swap(order: @This(), a: usize, b: usize) void {
            std.mem.swap(f32, &order.distances[a], &order.distances[b]);
            std.mem.swap(Object, &order.objects[a], &order.objects[b]);
        }
    };
    std.sort.insertionContext(0, found.len, Order{ .distances = &distances, .objects = &found.items });
    return found;
}
