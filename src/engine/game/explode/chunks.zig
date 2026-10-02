//! `C:\lancer\game\explode.cpp`'s rock chunks (`rock_chunks`, `0x00558778`): pieces of rock that
//! fly from a rock a shot strikes (`shieldfx.componentHit`) and from a Latov coming apart
//! (`split.Split`), tumbling, for minutes, each leaving a puff of flak where it is thrown.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const libcmt = @import("../../libcmt.zig");
const explode = @import("../explode.zig");
const table = @import("../table.zig");
const xtrabits = @import("../xtrabits.zig");
const Clock = @import("../main.zig").Clock;

/// A chunk flying (0x20 bytes): its object, the tick it goes at (`+0x00`), how far it moves a tick
/// (`+0x04`), and how far it turns a tick, as angles (`+0x10`). The object is drawn from where the
/// chunk stands at the frame's tick, `place`, which the game keeps in the object itself.
pub const Chunk = struct {
    object: srapiext.MeshObject,
    place: math.Place,
    until: i32,
    velocity: Vector,
    spin: Vector,

    /// Where it stands `ticks` past the frame's tick: moved on by its velocity, and turned by its
    /// spin, for each.
    fn moved(chunk: *const Chunk, ticks: f32) math.Place {
        const by: Vector = @splat(ticks);
        return .{
            .position = chunk.place.position + chunk.velocity * by,
            .orientation = math.product(chunk.place.orientation, math.fromAngleVector(chunk.spin * by)),
        };
    }
};

/// How a chunk is thrown: from a point on a part standing at a place, as a rock struck throws
/// one; or from a point in the world, large and fast, as a Latov coming apart does.
pub const Throw = union(enum) {
    from_part: math.Place,
    large,
};

/// The chunks flying, the next thrown taking the place of the oldest (`0x00553384`), and the tick
/// they last moved on at (`0x00562CC8`).
pub const Chunks = struct {
    ring: table.Ring(Chunk, capacity) = .{},
    moved_at: i32 = 0,

    pub const capacity = 300;

    /// `explosions_update`'s part for the chunks: each past its time goes, and the rest move on
    /// by their velocity and turn by their spin for each tick since they last did.
    pub fn frame(chunks: *Chunks, clock: *const Clock) void {
        const ticks: f32 = @floatFromInt(clock.frame_start - chunks.moved_at);
        for (&chunks.ring.slots) |*slot| {
            const chunk = &(slot.* orelse continue);
            if (chunk.until < clock.frame_start) {
                slot.* = null;
                continue;
            }
            chunk.place = chunk.moved(ticks);
        }
        chunks.moved_at = clock.frame_start;
    }

    /// Each chunk flying goes into the world's layer, `ahead` of a tick past the frame's tick.
    ///
    /// **Improvement:** the game draws a chunk where the frame's tick leaves it; OpenReliant draws
    /// it that much further along and turned (`objects.pastTick`).
    pub fn draw(chunks: *Chunks, gpa: Allocator, scene: *srcore.Scene, ahead: f32) Allocator.Error!void {
        for (&chunks.ring.slots) |*slot| {
            const chunk = &(slot.* orelse continue);
            const shown = chunk.moved(ahead);
            chunk.object.position = shown.position;
            chunk.object.orientation = shown.orientation;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &chunk.object }, .world);
        }
    }
};

/// How long a chunk flies: `least_life` ticks and up to as many more (`0x004DC444`).
const least_life = 20000;
/// How fast a chunk tumbles, up to `tumble` either way about each axis, as angles a tick
/// (`0x004DC420`); how fast it leaves, `speed` to twice that a tick (`0x004DC400`); and how far
/// off its direction, up to half of `stray` either way about each axis (`0x004DC3F8`).
const tumble: f32 = 0.1;
const speed: f32 = 6;
const stray: f32 = 0.2;
/// A large chunk: drawn at `large_scale` to `large_scale_range` more (`0x004DC520`,
/// `0x004DC56C`), leaving `large_speed` times as fast.
const large_scale: f32 = 10;
const large_scale_range: f32 = 5;
const large_speed: f32 = 4;
/// The puff of flak a chunk leaves where it is thrown, lighting what is round it.
const puff: explode.Fireball.Spec = .{ .size = 200, .life = 40, .light = true, .special = true };

/// `rock_chunk_throw` (`0x00472780`): a chunk of rock, one of the chunk models at random
/// (`explode.Debris.rock_chunks`), in place of the oldest, thrown from `at` along `direction`, for
/// `least_life` ticks and a random share of as many more. It turns at random first and tumbles as
/// it goes; it leaves at `speed` to twice that a tick, turned a little off its direction. Thrown
/// from a part, `at` is on the part, which stands at the place given; thrown large, it is drawn
/// larger and leaves faster. A puff of flak goes off where it starts.
pub fn throw(explosions: *explode.Explosions, at: Vector, direction: Vector, how: Throw, clock: *const Clock, random: *libcmt.Rand) void {
    const models = &explosions.debris.rock_chunks;
    const levels = models[@as(usize, random.rand()) % models.len].slice();
    const life: i32 = @intFromFloat(random.fraction() * least_life);
    if (levels.len == 0) return;
    const spin = random.centredVector(@splat(tumble));
    const orientation = math.fromAngleVector(random.fractionVector(@splat(std.math.tau)));
    var velocity = direction * @as(Vector, @splat((random.fraction() + 1) * speed));
    velocity = math.transform(math.fromAngleVector(random.centredVector(@splat(stray))), velocity);
    var object: srapiext.MeshObject = .{
        .flags = .{ .lit = true },
        .light_mask = explosions.settings.debris_lights.loose(),
        .position = at,
        .orientation = orientation,
        .radius = levels[0].mesh.radius,
        .levels = levels,
    };
    switch (how) {
        .from_part => |place| object.position = place.point(at),
        .large => {
            object.scale = random.fraction() * large_scale_range + large_scale;
            velocity *= @splat(large_speed);
        },
    }
    explosions.chunks.ring.take(Chunks.capacity).* = .{
        .object = object,
        .place = .{ .position = object.position, .orientation = object.orientation },
        .until = clock.frame_start + least_life + life,
        .velocity = velocity,
        .spin = spin,
    };
    explosions.setOff(object.position, puff, clock, random);
}

test throw {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const srmesh = @import("../../surrender/surrenderlib/srmesh.zig");
    const mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    const explosions = &stage.explosions;
    explosions.debris = explode.testing.debris(&mesh);
    const world = stage.world();
    stage.mission.clock.frame_start = 100;

    // From a part: where the part puts the point, leaving at `speed` to twice that a tick, for
    // `least_life` ticks and up to as many more, with a puff of flak where it starts.
    const part: math.Place = .{ .position = .{ 0, 0, 1000 }, .orientation = math.identity };
    throw(explosions, .{ 10, 0, 0 }, .{ 0, 0, 1 }, .{ .from_part = part }, world.clock, world.random);
    const chunk = explosions.chunks.ring.slots[0].?;
    try std.testing.expectEqual(@as(Vector, .{ 10, 0, 1000 }), chunk.object.position);
    const pace = math.length(chunk.velocity);
    try std.testing.expect(pace >= speed and pace <= 2 * speed);
    try std.testing.expect(chunk.until >= 100 + least_life and chunk.until <= 100 + 2 * least_life);
    try std.testing.expectEqual(1, chunk.object.scale);
    try std.testing.expect(explosions.fireballs[0].?.special);

    // Large: drawn `large_scale` to `large_scale_range` more, and `large_speed` times as fast.
    throw(explosions, @splat(0), .{ 0, 0, 1 }, .large, world.clock, world.random);
    const large = explosions.chunks.ring.slots[1].?;
    try std.testing.expect(large.object.scale >= large_scale and large.object.scale <= large_scale + large_scale_range);
    try std.testing.expect(math.length(large.velocity) >= large_speed * speed);

    // It flies on by its velocity for each tick since the chunks last moved on, and is drawn as
    // far past the tick as the frame is.
    stage.mission.clock.frame_start = 110;
    explosions.chunks.moved_at = 100;
    explosions.chunks.frame(world.clock);
    const moved = explosions.chunks.ring.slots[0].?.place.position;
    try math.testing.expectVectorWithin(chunk.place.position + chunk.velocity * @as(Vector, @splat(10)), moved, 1e-3);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try explosions.chunks.draw(gpa, &scene, 0.5);
    const drawn = explosions.chunks.ring.slots[0].?.object.position;
    try math.testing.expectVectorWithin(moved + chunk.velocity * @as(Vector, @splat(0.5)), drawn, 1e-3);

    // It goes once its time is past.
    stage.mission.clock.frame_start = chunk.until + 1;
    explosions.chunks.frame(world.clock);
    try std.testing.expectEqual(null, explosions.chunks.ring.slots[0]);
}
