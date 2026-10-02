//! `C:\lancer\game\sparks.cpp`: the sparks a hit throws, small bolts that fly off, slow and fade.
//!
//! Ported: the sparks, and those a shot striking a hull throws (`guns.hullHit`), a component
//! (`guns.componentHit`) or a shield (`shield.zig`). **Not ported:** those of the wall of a
//! multiplayer mission's arena (`arena_wall_hit`, `0x004B02A0`), which is multiplayer's
//! ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const particles = @import("particles.zig");
const table = @import("table.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;

/// What threw a spark, which sets how it looks and moves.
pub const Kind = enum(u3) {
    /// An allied Huge Gun's shot striking a component: a long white beam fading to blue.
    allied_huge_gun = 0,
    /// A shot striking a component.
    component = 1,
    /// A shot striking a hull (`bullet_hull_hit`).
    hull = 2,
    /// A shot striking a shield (`0x0049F1E0`), and a shot or a ship meeting a multiplayer
    /// arena's wall (`arena_wall_hit`): blue.
    shield = 3,
    /// A coalition Huge Gun's shot striking a component: a long beam fading from warm white to red.
    coalition_huge_gun = 4,

    fn look(kind: Kind) Look {
        return looks.get(kind);
    }

    /// Whether it is thrown only within `near_only` of the camera.
    fn nearOnly(kind: Kind) bool {
        return kind == .hull or kind == .shield;
    }
};

/// How a kind of spark looks and moves (0x68 bytes, `0x00508A18`). The game also has it turn, grow
/// and fade late by three flags (`+0x64`), which no kind sets.
const Look = struct {
    /// Half its width and height, and its length (`+0x00`).
    size: Vector,
    /// Out to where its crossed bolt and then its single quad are drawn (`+0x0C`, `+0x10`).
    near: f32 = 100000,
    far: f32 = 500000,
    /// The span of the texture it shows: left, top, right and bottom (`+0x34`).
    uv: [4]f32 = .{ 0.125, 0.5, 0.25, 1 },
    /// Its colour as it is thrown and as it ends (`+0x44`, `+0x50`).
    colours: [2][3]f32,
    /// How long it lasts, in ticks (`+0x5C`), and what is left of its speed after a tick (`+0x60`).
    life: i32,
    drag: f32,
};

const looks: std.EnumArray(Kind, Look) = .init(.{
    .allied_huge_gun = .{ .size = .{ 90, 90, 500 }, .colours = .{ .{ 1, 1, 1 }, .{ 0, 0, 0.1 } }, .life = 300, .drag = 0.9999 },
    .component = .{ .size = .{ 30, 30, 140 }, .colours = .{ .{ 1, 1, 1 }, .{ 0, 0, 0 } }, .life = 100, .drag = 0.995 },
    .hull = .{ .size = .{ 30, 30, 90 }, .colours = .{ .{ 1, 1, 1 }, .{ 0, 0, 0 } }, .life = 100, .drag = 0.995 },
    .shield = .{ .size = .{ 20, 20, 90 }, .uv = .{ 0.125, 0, 0.25, 0.5 }, .colours = .{ .{ 0.4, 0.5, 1 }, .{ 0, 0, 0 } }, .life = 100, .drag = 0.995 },
    .coalition_huge_gun = .{ .size = .{ 90, 90, 500 }, .colours = .{ .{ 1, 0.9, 0.7 }, .{ 0.1, 0, 0 } }, .life = 300, .drag = 0.9999 },
});

/// The texture every spark shows, save an allied Huge Gun's beam, which shows `beam_texture`.
const texture = "lasers";
const beam_texture = "alhuge";
/// How far off an allied Huge Gun's beam is drawn (`0x00594194`).
const beam_until: f32 = 1500000;
/// How far from the camera a spark of a kind thrown only near it may be (`0x004DC444`).
const near_only: f32 = 20000;

/// A spark's levels of detail (`0x00594190`, 0x54 bytes each): an allied Huge Gun's is a beam of
/// three crossed quads reaching its length either way from its middle; the others' are a bolt of
/// two quads crossed along its length, then a single quad, whose material asks for generated
/// coordinates though nothing makes any for it.
const Shape = struct {
    meshes: [2]srapiext.Mesh,
    levels: [2]srapiext.Level,
    count: usize,

    fn deinit(shape: *Shape, gpa: Allocator) void {
        for (shape.meshes[0..shape.count]) |mesh| mesh.deinit(gpa);
    }

    fn shown(shape: *const Shape) []const srapiext.Level {
        return shape.levels[0..shape.count];
    }
};

/// A quad's corners, as the spark meshes list them.
const Quad = [4]Vector;

/// `0x004A2040`: a kind's shape, with its levels pointing at its own meshes, which must stay put.
fn buildShape(gpa: Allocator, textures: *srtexture.Table, kind: Kind, shape: *Shape) (Allocator.Error || matmanager.Error)!void {
    const look = kind.look();
    const x, const y, const z = look.size;
    const along: Quad = .{ .{ 0, y, 0 }, .{ 0, -y, 0 }, .{ 0, -y, z }, .{ 0, y, z } };
    const across: Quad = .{ .{ x, 0, 0 }, .{ -x, 0, 0 }, .{ -x, 0, z }, .{ x, 0, z } };
    if (kind == .allied_huge_gun) {
        const image = try matmanager.textureRequire(textures, beam_texture);
        const quads = [_]Quad{
            .{ .{ 0, y, -z }, .{ 0, -y, -z }, .{ 0, -y, z }, .{ 0, y, z } },
            .{ .{ x, 0, -z }, .{ -x, 0, -z }, .{ -x, 0, z }, .{ x, 0, z } },
            .{ .{ -x, -y, 0 }, .{ x, -y, 0 }, .{ x, y, 0 }, .{ -x, y, 0 } },
        };
        shape.meshes[0] = try quadMesh(gpa, &quads, look.uv, image, .mesh);
        shape.count = 1;
        shape.levels[0] = .{ .mesh = &shape.meshes[0], .until = beam_until };
        return;
    }
    const image = try matmanager.textureRequire(textures, texture);
    shape.meshes[0] = try quadMesh(gpa, &.{ along, across }, look.uv, image, .mesh);
    errdefer shape.meshes[0].deinit(gpa);
    shape.meshes[1] = try quadMesh(gpa, &.{along}, look.uv, image, .generated);
    shape.count = 2;
    shape.levels = .{ .{ .mesh = &shape.meshes[0], .until = look.near }, .{ .mesh = &shape.meshes[1], .until = look.far } };
}

/// A mesh of `quads`, each corner textured from the span `uv` gives, coloured by the spark's own
/// colours and added to what is behind it.
fn quadMesh(gpa: Allocator, quads: []const Quad, uv: [4]f32, image: *srtexture.Image, coordinates: srapiext.Material.Coordinates) Allocator.Error!srapiext.Mesh {
    const corners = quads.len * 4;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = quads.len, .vertices = corners, .indices = corners });
    errdefer mesh.deinit(gpa);
    const coords = try mesh.addCoordinates(gpa);
    mesh.surfaces[0] = .{
        .polygons = @intCast(quads.len),
        .material = .onePass(.{ .coordinates = coordinates, .lit = true, .blend = .add }),
        .textures = .{ .{ .image = image }, .none },
    };
    mesh.numberPolygons(4);
    const left, const top, const right, const bottom = uv;
    for (quads, 0..) |quad, n| {
        mesh.positions[n * 4 ..][0..4].* = quad;
        coords[n * 4 ..][0..4].* = .{ .{ left, top }, .{ right, top }, .{ right, bottom }, .{ left, bottom } };
    }
    for (mesh.indices, 0..) |*index, at| index.* = @intCast(at);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// A spark flying (0x24 bytes).
pub const Spark = struct {
    kind: Kind,
    /// Its bolt, pointing along its flight and coloured by its own colours, never culled (`+0x04`).
    object: srapiext.MeshObject,
    colours: [max_corners][4]f32 = @splat(@splat(1)),
    /// Where it is at the frame's tick; its bolt is drawn from here (`Sparks.draw`).
    at: Vector,
    born: i32,
    /// How far it flies a tick, slowing as it goes (`+0x0C`), and how far it drifts a tick with
    /// what threw it (`+0x18`).
    velocity: Vector,
    carried: Vector,

    const max_corners = 12;
};

/// How a spray of sparks leaves: how fast, a tick, and up to how much faster or slower, half of
/// it either way; how far off its direction, in radians, half of it either way about two axes; and
/// how many.
pub const Spray = struct {
    speed: f32,
    speed_range: f32,
    spread: f32,
    count: u16,
};

/// The sparks flying, and the shapes they show.
pub const Sparks = struct {
    gpa: Allocator,
    shapes: *std.EnumArray(Kind, Shape),
    /// The sparks flying, the next taking the place of whatever was in its slot (`0x00593D88`),
    /// and when they last moved on (`0x00593D8C`).
    sparks: *Flying,
    moved_at: i32 = 0,

    pub const max = 256;
    const Flying = table.Ring(Spark, max);

    /// `0x004A1AF0`, which `particles_init` runs: the shapes, over their textures.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Sparks {
        const shapes = try gpa.create(std.EnumArray(Kind, Shape));
        errdefer gpa.destroy(shapes);
        var built: usize = 0;
        errdefer for (shapes.values[0..built]) |*shape| shape.deinit(gpa);
        for (std.enums.values(Kind), &shapes.values) |kind, *shape| {
            try buildShape(gpa, textures, kind, shape);
            built += 1;
        }
        const sparks = try gpa.create(Flying);
        sparks.* = .{};
        return .{ .gpa = gpa, .shapes = shapes, .sparks = sparks };
    }

    /// `0x004A1B30`: the shapes let go.
    pub fn deinit(all: *Sparks) void {
        for (&all.shapes.values) |*shape| shape.deinit(all.gpa);
        all.gpa.destroy(all.shapes);
        all.gpa.destroy(all.sparks);
    }

    /// `0x004A1B70`: none flying.
    pub fn reset(all: *Sparks) void {
        all.sparks.* = .{};
    }

    /// `0x004A1DB0`: a spark of `kind` thrown from `at` along `direction` at `speed` a tick,
    /// drifting on with `carried`, in the place of the oldest.
    pub fn add(all: *Sparks, kind: Kind, at: Vector, direction: Vector, speed: f32, carried: Vector, clock: *const Clock) void {
        const slot = all.sparks.take(max);
        slot.* = .{
            .kind = kind,
            .object = .{
                .flags = .{ .not_culled = true, .baked_object = true },
                .position = at,
                .orientation = math.lookAt(direction),
                .radius = all.shapes.getPtrConst(kind).meshes[0].radius,
                .levels = all.shapes.getPtrConst(kind).shown(),
            },
            .at = at,
            .born = clock.frame_start,
            .velocity = math.normalize(direction) * @as(Vector, @splat(speed)),
            .carried = carried,
        };
        slot.*.?.object.baked = &slot.*.?.colours;
    }

    /// `0x004A1BB0`, which `particles_frame` runs first: each spark flies on by its velocity and
    /// what it carries times the ticks since they last moved, slows by its drag for each of them,
    /// and fades from its first colour to its last over its life (`vec3_lerp`, `0x004C1070`), after
    /// which it is gone.
    pub fn frame(all: *Sparks, clock: *const Clock) void {
        const ticks: f32 = @floatFromInt(clock.frame_start - all.moved_at);
        for (&all.sparks.slots) |*slot| {
            const spark = &(slot.* orelse continue);
            const look = spark.kind.look();
            const age = clock.frame_start - spark.born;
            if (age > look.life) {
                slot.* = null;
                continue;
            }
            spark.at += (spark.velocity + spark.carried) * @as(Vector, @splat(ticks));
            spark.velocity *= @splat(std.math.pow(f32, look.drag, ticks));
            const done = particles.through(clock.frame_start, spark.born, look.life);
            const colour = math.lerp(@as(Vector, look.colours[0]), @as(Vector, look.colours[1]), done);
            spark.colours = @splat(.{ colour[0], colour[1], colour[2], 1 });
        }
        all.moved_at = clock.frame_start;
    }

    /// Each spark, into the world's layer, `ahead` of a tick along from where it was at the
    /// frame's tick.
    ///
    /// **Improvement:** the game draws it where the tick left it (`particles.Pool.draw`).
    pub fn draw(all: *Sparks, gpa: Allocator, scene: *srcore.Scene, ahead: f32) Allocator.Error!void {
        for (&all.sparks.slots) |*slot| {
            const spark = &(slot.* orelse continue);
            spark.object.position = spark.at + (spark.velocity + spark.carried) * @as(Vector, @splat(ahead));
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &spark.object }, .world);
        }
    }
};

/// `0x004A1ED0`: throws `how.count` sparks of `kind` from `at`, each along `direction` turned a
/// random way within `how.spread`, at a random speed within `how`'s, drifting on with `carried`,
/// where the world has sparks. A kind thrown only near the camera is not thrown past `near_only`.
pub fn spray(world: gameobj.World, kind: Kind, at: Vector, direction: Vector, carried: Vector, how: Spray) void {
    const all = world.sparks orelse return;
    if (kind.nearOnly()) {
        const watching = world.camera orelse return;
        if (math.distance(at, watching.place.position) > near_only) return;
    }
    const random = world.random;
    const aim = math.lookAt(direction);
    for (0..how.count) |_| {
        const yaw = random.centred() * how.spread;
        const pitch = random.centred() * how.spread;
        const turned = math.product(math.fromAngles(pitch, yaw, 0), aim);
        const speed = random.centred() * how.speed_range + how.speed;
        all.add(kind, at, math.forward(turned), speed, carried, world.clock);
    }
}

pub const testing = struct {
    /// The sparks built over a table holding nothing but their textures.
    pub const Built = struct {
        textures: *@import("../surrender/surrenderlib/srtexture.zig").testing.Textures,
        sparks: Sparks,

        pub fn init(gpa: Allocator) !Built {
            const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &.{ texture, beam_texture });
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .sparks = try .create(gpa, &textures.table) };
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.sparks.deinit();
            built.textures.deinit(gpa);
        }
    };
};

test Sparks {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const all = &built.sparks;

    // An allied Huge Gun's is a beam of three quads; the rest a crossed bolt, then a single quad.
    const beam = all.shapes.getPtrConst(.allied_huge_gun);
    try std.testing.expectEqual(1, beam.shown().len);
    try std.testing.expectEqual(12, beam.meshes[0].positions.len);
    const bolt = all.shapes.getPtrConst(.hull).shown();
    try std.testing.expectEqual(2, bolt.len);
    try std.testing.expectEqual(8, bolt[0].mesh.positions.len);
    try std.testing.expectEqual(.generated, bolt[1].mesh.surfaces[0].material.coordinates[0]);

    // A spark flies on with what it carries, slows by its drag and fades, until its life is over.
    var clock: Clock = .{};
    all.add(.hull, @splat(0), .{ 0, 0, 2 }, 10, .{ 1, 0, 0 }, &clock);
    const spark = &all.sparks.slots[0].?;
    try std.testing.expectEqual(spark.object.levels.ptr, bolt.ptr);
    clock.frame_start = 50;
    all.frame(&clock);
    try std.testing.expect(math.distance(spark.at, .{ 50, 0, 500 }) < 1e-3);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try all.draw(gpa, &scene, 0.5);
    try std.testing.expect(math.distance(spark.object.position, spark.at + (spark.velocity + spark.carried) * @as(Vector, @splat(0.5))) < 1e-4);
    try std.testing.expectApproxEqAbs(10 * std.math.pow(f32, 0.995, 50), spark.velocity[2], 1e-3);
    try std.testing.expectApproxEqAbs(0.5, spark.colours[3][0], 1e-6);
    clock.frame_start = 101;
    all.frame(&clock);
    try std.testing.expectEqual(null, all.sparks.slots[0]);

    // The next takes the place of the oldest, round the table.
    const before = all.sparks.next;
    for (0..Sparks.max + 1) |_| all.add(.shield, @splat(0), .{ 0, 0, 1 }, 1, @splat(0), &clock);
    try std.testing.expectEqual((before + 1) % Sparks.max, all.sparks.next);
}

test spray {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var watching: @import("camera.zig").Camera = .{};
    var world = mission.world();
    world.sparks = &built.sparks;
    world.camera = &watching;

    // Ten, each within the spread of the aim and the range of the speed.
    spray(world, .hull, .{ 0, 0, 1000 }, .{ 0, 0, 1 }, @splat(0), .{ .speed = 10, .speed_range = 5, .spread = 1, .count = 10 });
    for (built.sparks.sparks.slots[0..10]) |slot| {
        const spark = slot.?;
        const speed = math.length(spark.velocity);
        try std.testing.expect(speed >= 7.5 and speed <= 12.5);
        try std.testing.expect(spark.velocity[2] / speed >= @cos(@as(f32, 0.75)));
    }
    try std.testing.expectEqual(null, built.sparks.sparks.slots[10]);

    // A hull's are not thrown far from the camera; a component's are.
    spray(world, .hull, .{ 0, 0, near_only + 1 }, .{ 0, 0, 1 }, @splat(0), .{ .speed = 10, .speed_range = 0, .spread = 0, .count = 1 });
    try std.testing.expectEqual(null, built.sparks.sparks.slots[10]);
    spray(world, .component, .{ 0, 0, near_only + 1 }, .{ 0, 0, 1 }, @splat(0), .{ .speed = 10, .speed_range = 0, .spread = 0, .count = 1 });
    try std.testing.expect(built.sparks.sparks.slots[10] != null);
}
