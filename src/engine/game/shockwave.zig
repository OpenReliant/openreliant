//! `C:\lancer\game\shockwave.cpp`: the rings that spread out from an explosion, fading as they go,
//! and what they do to what they pass.
//!
//! Ported: the rings, a blast's (`explode.blast`), the Uber Explode's
//! ([`explode/uber.zig`](explode/uber.zig)), a halting torpedo's ([`aiexplode.zig`](aiexplode.zig))
//! and a Havoc's and an Imp's ([`missiles.zig`](missiles.zig)), and what those do.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const camera = @import("camera.zig");
const aigeneric = @import("aigeneric.zig");
const collision = @import("collision.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const orders = @import("ai/orders.zig");
const matmanager = @import("matmanager.zig");
const particles = @import("particles.zig");
const table = @import("table.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;

/// The rings' looks, one texture each, in the order `shockwave_init` (`0x004A0D90`) builds their
/// meshes (`shockwave_textures`, `0x0059379C`; `shockwave_meshes`, `0x005937B4`).
pub const Ring = enum {
    rng_02,
    rng_03,
    rng_04,
    rng_01,
    rng_06,
};

/// What a shockwave is, which picks its ring and what it does to what it passes.
pub const Kind = enum(u4) {
    /// A blast's, in one of three looks: it shakes the player's view as it passes.
    blast_02 = 0,
    blast_03 = 1,
    blast_04 = 2,
    /// The Uber Explode's pair (`explode.uber`), which do nothing but show.
    uber = 3,
    /// **Unknown.** No caller makes one: it does nothing but show.
    _unknown_4 = 4,
    /// A Havoc's end's (`missiles.end`): it pushes the ships of other sides it passes away,
    /// disrupted (`Shockwave.strike`).
    havoc = 5,
    /// An Imp's end's: it empties the shields of the ships of other sides it passes.
    imp = 6,
    /// A capital ship's split's (`explode.split`): unseen, it shakes the player's view and
    /// damages the player as it passes, by its owner's type, far less as it spreads.
    split = 7,
    /// A halting torpedo's: it shakes the player's view and damages the player as it passes.
    torpedo = 8,

    /// The ring it shows (`shockwave_create`).
    pub fn ring(kind: Kind) Ring {
        return switch (kind) {
            .blast_02 => .rng_02,
            .blast_03 => .rng_03,
            .blast_04 => .rng_04,
            .uber, .imp, .split, .torpedo => .rng_01,
            ._unknown_4, .havoc => .rng_06,
        };
    }

    /// The blast's three, which it picks one of at random.
    pub const blasts = [_]Kind{ .blast_02, .blast_03, .blast_04 };
};

/// How a shockwave is set off: how far it spreads, over how long, drifting how far a tick, and
/// whose it is.
pub const Spec = struct {
    kind: Kind,
    size: f32,
    life: i32,
    velocity: Vector = @splat(0),
    owner: u16,
    /// The side a missile's shockwave spares, its launcher's; null for the rest.
    side: ?gameobj.Side(i32) = null,
};

/// A shockwave spreading (0x2C bytes): a ring that grows from nothing to its size over its life,
/// fading as it goes.
pub const Shockwave = struct {
    kind: Kind,
    /// The ring, which its own colours colour, never culled (`+0x04`). Its scale is how far the
    /// ring has spread, and so how far it had the frame before.
    object: srapiext.MeshObject,
    colours: [Roundness.round.corners()][4]f32,
    /// Where it is, how far through its life and how far it has spread at the frame's tick. The
    /// game keeps the last in the ring's scale; OpenReliant draws the ring from these, further
    /// along between the ticks (`Shockwaves.draw`).
    at: Vector,
    done: f32 = 0,
    reach: f32 = 0,
    /// How far it drifts a tick (`+0x08`), how far it spreads (`+0x14`), when it was set off and
    /// for how long (`+0x18`, `+0x1C`), whose it is (`+0x20`), and the side a missile's spares
    /// (`+0x24`).
    velocity: Vector,
    size: f32,
    born: i32,
    life: i32,
    owner: u16,
    side: ?gameobj.Side(i32),

    /// Whether the ring passed what stands at `at` this frame: from how far it had spread to how
    /// far it has now.
    fn passes(wave: *const Shockwave, at: Vector, reach: f32) bool {
        const distance = math.distance(wave.at, at);
        return wave.reach <= distance and distance < reach;
    }

    fn passesPlayer(wave: *const Shockwave, world: gameobj.World, reach: f32) bool {
        return wave.passes(world.objects.slots[world.objects.player].drawn.position, reach);
    }

    /// Whether a shockwave can harm the object now: not one that lists components, a stand-in, one
    /// exploding or disabled, or one another shockwave harmed less than `harm_pause` ticks ago.
    fn harms(object: *const gameobj.GameObject, frame_start: i32) bool {
        if (object.flags.components or object.flags.stand_in or object.flags.exploding or object.flags.disabled) return false;
        return object.shockwave_until <= frame_start;
    }

    /// A Havoc's or an Imp's shockwave passing the ships of other sides than its missile's, but
    /// torpedoes and the Ripper, each as `harms` allows, and shaking the player's view as it
    /// passes the player's ship. A Havoc's pushes each away from where it stands, into Disrupted
    /// (`aifuncs.disruptedInit`), unless its order ranks above that: hardest while the ring is
    /// young, by the ship's mass times the ring's size over its life, and for as long as 500 ticks
    /// for a player's ship and 2000 for another's, both less as the ring grows past a third of its
    /// life. An Imp's flickers each one's shield bubble for a second and damages each quadrant by
    /// 50 more than its shield holds, none of it passing to the armour, as if the ship had hit
    /// itself.
    fn strike(wave: *const Shockwave, world: gameobj.World, done: f32, reach: f32, how: Strike) void {
        const all = world.objects;
        const now = world.clock.frame_start;
        var walk = all.walk();
        while (walk.next()) |index| {
            const slot = &all.slots[index];
            const object = &slot.object;
            if (!harms(object, now) or object.type == .torpedo or object.type == .ripper) continue;
            if (wave.side) |own| if (object.side == own) continue;
            if (!wave.passes(slot.drawn.position, reach)) continue;
            object.shockwave_until = now + harm_pause;
            if (index == all.player) shake(world, done);
            switch (how) {
                .disrupt => wave.disrupt(world, index, done),
                .drain => {
                    if (slot.shield) |bubble| {
                        bubble.flicker_until = now + imp_flicker;
                        bubble.struck = now;
                    }
                    for (std.enums.values(collision.Quadrant)) |quadrant| {
                        collision.damage(world, index, quadrant, object.shields.get(quadrant) + imp_drain, 0, index, .missile);
                    }
                },
            }
        }
    }

    /// What a missile's shockwave does to a ship it passes.
    const Strike = enum { disrupt, drain };

    /// A Havoc's shockwave's push on the ship at `index`, `done` of the way through its life.
    fn disrupt(wave: *const Shockwave, world: gameobj.World, index: u16, done: f32) void {
        const all = world.objects;
        const slot = &all.slots[index];
        if (slot.current()) |entry| {
            const running = orders.info(entry.order);
            if (running) |info| if (info.priority > orders.info(.disrupted).?.priority) return;
        }
        const ctx: aigeneric.Context = .of(world);
        const took = aigeneric.give(ctx, index, .disrupted, .none);
        if (!took) return;
        const strength = @min(disrupt_strength * (1 - done), 1);
        const ticks: f32 = if (index < all.players) disrupt_player_ticks else disrupt_ticks;
        const away = math.normalize(slot.drawn.position - wave.at);
        const push = away * @as(Vector, @splat(slot.object.mass * wave.size * strength / @as(f32, @floatFromInt(wave.life))));
        slot.orders[0].data = .{ .disrupted = .{ .ticks = @intFromFloat(strength * ticks), .push = push } };
    }

    /// What each quadrant takes as the shockwave passes, with `left` of its life to go: a
    /// torpedo's `torpedo_harm` of its size times `left`, a split's by its owner's type times the
    /// cube of `left`.
    fn harm(wave: *const Shockwave, all: *const create.Objects, left: f32) f32 {
        if (wave.kind != .split) return left * wave.size * torpedo_harm;
        const owner = all.slots[wave.owner].object.type;
        const scale = if (std.mem.indexOfScalar(gameobj.Type, &lighter_splits, owner) != null) lighter_split_harm else split_harm;
        return left * wave.size * left * left * scale;
    }

    /// A torpedo's or a split's shockwave passing the player's ship shakes the view and damages
    /// each quadrant (`harm`), unless the ship lists components, is a stand-in, exploding or
    /// disabled, or another shockwave harmed it less than `harm_pause` ticks ago. A shield's
    /// reserve takes it first: while the reserve holds, the shield is spared, and once the reserve
    /// runs out the shield takes what the reserve held.
    ///
    /// **Improvement:** the game damages the player as if the attacker were object 16, whatever a
    /// loop left in a register; OpenReliant names the shockwave's owner.
    fn harmPlayer(wave: *const Shockwave, world: gameobj.World, done: f32, reach: f32) void {
        const all = world.objects;
        const object = &all.slots[all.player].object;
        if (!harms(object, world.clock.frame_start) or !wave.passesPlayer(world, reach)) return;
        shake(world, done);
        object.shockwave_until = world.clock.frame_start + harm_pause;
        const value = wave.harm(world.objects, 1 - done);
        for (std.enums.values(collision.Quadrant)) |quadrant| {
            const through = if (world.player.shield_reserves.of(quadrant)) |reserve| through: {
                if (reserve.* <= 0) break :through value;
                reserve.* -= value;
                if (reserve.* >= 0) continue;
                const held = reserve.* + value;
                reserve.* = 0;
                break :through held;
            } else value;
            collision.damage(world, all.player, quadrant, through, 1, wave.owner, .collision);
        }
    }
};

/// The shockwaves the game keeps room for; one more is not set off, where the game fails an
/// assertion ("shockwave count exceeded") and writes past its table.
pub const max_shockwaves = 30;

/// How round a ring is: how many points about it (`0x004A0B30`).
///
/// **Improvement:** `round` gives it 32, where the game's 8 make an octagon whose corners show on a
/// ring ten times a ship's radius across. `--original` restores the octagon.
pub const Roundness = enum {
    octagon,
    round,

    fn spokes(roundness: Roundness) usize {
        return switch (roundness) {
            .octagon => 8,
            .round => 32,
        };
    }

    /// A point a unit out and one `hole` out for each spoke.
    fn corners(roundness: Roundness) usize {
        return roundness.spokes() * 2;
    }
};

/// A ring's mesh (`0x004A0B30`): points a unit out and as many `hole` out, evenly about the Z
/// axis, the band between them two triangles a spoke. Each corner's texture coordinates are how
/// far it lies across and up, either way, no nearer the middle than `uv_least`, so the texture, a
/// quarter of a ring, shows mirrored in each quarter.
const hole: f32 = 0.1;
const uv_least: f32 = 1.0 / 64.0;

/// A ring's material: its own texture coordinates, coloured by its colours, and added to what is
/// behind it.
const ring_material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add });

/// How hard a shockwave shakes the player's view as it passes, times how far through its life it
/// is (`0x004DC520`), no more than the camera takes; how long the player is left alone after a
/// shockwave harms it (`GameObject.shockwave_until`); and how much a torpedo's harms each
/// quadrant, times its size and what is left of its life (`0x004DC474`).
const shake_scale: f32 = 10;
const harm_pause = 50;
const torpedo_harm: f32 = 0.05;

/// What a split's shockwave does to each quadrant, times its size and the cube of what is left of
/// its life: the lighter for a split ship of one of `lighter_splits`' types (`0x004DC9FC`), the
/// heavier for any other (`0x004DC958`).
const split_harm: f32 = 0.015;
const lighter_split_harm: f32 = 0.0045;
const lighter_splits = [_]gameobj.Type{ @enumFromInt(0x36), .darkreign, .stalag, @enumFromInt(0x9B), .boridin_breakaway };

/// A Havoc's shockwave's push: its strength is 1.5 times what is left of its life, up to 1, and
/// the ticks it disrupts a player's ship and another for at full strength (`0x004DC4E0`,
/// `0x004DC4A8`, `0x004DC438`).
const disrupt_strength: f32 = 1.5;
const disrupt_player_ticks: f32 = 500;
const disrupt_ticks: f32 = 2000;

/// How long an Imp's shockwave flickers a bubble, and how far past its shield it damages a
/// quadrant (`0x004DC48C`).
const imp_flicker = 100;
const imp_drain: f32 = 50;

/// The shockwaves spreading, and the rings they show.
pub const Shockwaves = struct {
    meshes: std.EnumArray(Ring, srapiext.Mesh),
    /// Each ring as a single level of detail, which the rings drawn point at.
    levels: std.EnumArray(Ring, [1]srapiext.Level) = .initUndefined(),
    waves: [max_shockwaves]?Shockwave = @splat(null),

    /// `shockwave_init` (`0x004A0D90`): the rings' meshes, over their textures. The game also
    /// builds a sphere (`0x004A16F0`, `0x005937B0`), which nothing draws.
    pub fn create(gpa: Allocator, textures: *srtexture.Table, roundness: Roundness) (Allocator.Error || matmanager.Error)!Shockwaves {
        var meshes: std.EnumArray(Ring, srapiext.Mesh) = undefined;
        var built: usize = 0;
        errdefer for (meshes.values[0..built]) |mesh| mesh.deinit(gpa);
        for (std.enums.values(Ring)) |ring| {
            const image = try matmanager.textureRequire(textures, @tagName(ring));
            meshes.set(ring, try ringMesh(gpa, image, roundness));
            built += 1;
        }
        return .{ .meshes = meshes };
    }

    /// `0x004A0E60`: the meshes let go.
    pub fn deinit(waves: *Shockwaves, gpa: Allocator) void {
        for (waves.meshes.values) |mesh| mesh.deinit(gpa);
    }

    /// As a mission starts again: none spreading.
    pub fn reset(waves: *Shockwaves) void {
        waves.waves = @splat(null);
    }

    /// `shockwave_create` (`0x004A15D0`): sets a shockwave off at `at`, facing as it faces, into
    /// the first free slot, and not at all where there is none. It starts at nothing.
    pub fn add(waves: *Shockwaves, at: math.Place, spec: Spec, clock: *const Clock) void {
        const slot = table.firstFree(Shockwave, &waves.waves) orelse return;
        const mesh = waves.meshes.getPtrConst(spec.kind.ring());
        slot.* = .{
            .kind = spec.kind,
            .object = .{
                .flags = .{ .not_culled = true, .baked_object = true },
                .position = at.position,
                .orientation = at.orientation,
                .scale = 0,
                .radius = mesh.radius,
                .levels = &.{},
            },
            .colours = @splat(@splat(1)),
            .at = at.position,
            .velocity = spec.velocity,
            .size = spec.size,
            .born = clock.frame_start,
            .life = spec.life,
            .owner = spec.owner,
            .side = spec.side,
        };
    }

    /// `shockwaves_update` (`0x004A0F00`), once a frame after the explosions: each shockwave drifts
    /// on by its velocity times the frame's ticks, fades from white to nothing, and spreads to
    /// its size times how far through its life it is, doing what it does to what it passes on
    /// the way. It is let go once its life is over.
    pub fn frame(waves: *Shockwaves, world: gameobj.World) void {
        const clock = world.clock;
        for (&waves.waves) |*slot| {
            const wave = &(slot.* orelse continue);
            const done = particles.through(clock.frame_start, wave.born, wave.life);
            if (!(done < 1)) {
                slot.* = null;
                continue;
            }
            wave.at += wave.velocity * @as(Vector, @splat(@floatFromInt(clock.frame_duration)));
            wave.done = done;
            wave.colours = @splat(@splat(1 - done));
            const reach = done * wave.size;
            switch (wave.kind) {
                .blast_02, .blast_03, .blast_04 => if (wave.passesPlayer(world, reach)) shake(world, done),
                .torpedo, .split => wave.harmPlayer(world, done, reach),
                .havoc => wave.strike(world, done, reach, .disrupt),
                .imp => wave.strike(world, done, reach, .drain),
                .uber, ._unknown_4 => {},
            }
            wave.reach = reach;
        }
    }

    /// Each shockwave's ring, into the world's layer, save kind 7's, which is unseen: `ahead` of a
    /// tick along from where it stood and how far it had spread at the frame's tick.
    ///
    /// **Improvement:** the game draws it as the tick left it (`particles.Pool.draw`).
    pub fn draw(waves: *Shockwaves, gpa: Allocator, scene: *srcore.Scene, ahead: f32) Allocator.Error!void {
        for (std.enums.values(Ring)) |ring| waves.levels.set(ring, .{.{ .mesh = waves.meshes.getPtrConst(ring), .until = std.math.inf(f32) }});
        for (&waves.waves) |*slot| {
            const wave = &(slot.* orelse continue);
            if (wave.kind == .split) continue;
            wave.object.levels = waves.levels.getPtrConst(wave.kind.ring());
            wave.object.baked = &wave.colours;
            wave.object.position = wave.at + wave.velocity * @as(Vector, @splat(ahead));
            const done = @min(wave.done + ahead / @as(f32, @floatFromInt(wave.life)), 1);
            wave.object.scale = done * wave.size;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &wave.object }, .world);
        }
    }
};

/// Sets a shockwave off at `at`, where the world has shockwaves.
pub fn setOff(world: gameobj.World, at: math.Place, spec: Spec) void {
    const waves = world.shockwaves orelse return;
    waves.add(at, spec, world.clock);
}

/// Shakes the player's view by how far through its life the shockwave passing is, where it shakes
/// no harder already.
///
/// **Improvement** (`input.force.Unread.played`): the player's controller plays `Shock`, unless it
/// is playing already.
fn shake(world: gameobj.World, done: f32) void {
    world.shake.* = @max(world.shake.*, @min(done * shake_scale, camera.Cockpit.shake_most));
    if (world.forces) |forces| forces.startUnlessPlaying(.shock, world.clock.frame_start);
}

/// `0x004A0B30`: a ring's mesh, over `image`.
fn ringMesh(gpa: Allocator, image: *srtexture.Image, roundness: Roundness) Allocator.Error!srapiext.Mesh {
    const spokes = roundness.spokes();
    const corners = roundness.corners();
    const triangles = spokes * 2;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = triangles, .vertices = corners, .indices = triangles * 3 });
    errdefer mesh.deinit(gpa);
    const uv = try mesh.addCoordinates(gpa);
    mesh.surfaces[0] = .{ .polygons = @intCast(triangles), .material = ring_material, .textures = .{ .{ .image = image }, .none } };
    for (0..spokes) |spoke| {
        const turn = math.fromAngles(0, 0, @as(f32, @floatFromInt(spoke)) * std.math.tau / @as(f32, @floatFromInt(spokes)));
        mesh.positions[spoke * 2] = math.transform(turn, .{ 0, 1, 0 });
        mesh.positions[spoke * 2 + 1] = math.transform(turn, .{ 0, hole, 0 });
    }
    mesh.numberPolygons(3);
    for (0..spokes) |spoke| {
        const outer = spoke * 2;
        const band = [6]usize{ outer, outer + 1, outer + 2, outer + 2, outer + 3, outer + 1 };
        for (mesh.indices[spoke * 6 ..][0..6], band) |*index, corner| index.* = @intCast(corner % corners);
    }
    for (mesh.indices, uv) |index, *corner| {
        const at = mesh.positions[index];
        corner.* = .{ @max(@abs(at[0]), uv_least), @max(@abs(at[1]), uv_least) };
    }
    srapi.calcPolyNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

pub const testing = struct {
    /// The shockwaves built over a table holding nothing but the rings' textures.
    pub const Built = struct {
        textures: *@import("../surrender/surrenderlib/srtexture.zig").testing.Textures,
        waves: Shockwaves,

        pub fn init(gpa: Allocator) !Built {
            var names: [std.enums.values(Ring).len][]const u8 = undefined;
            for (&names, std.enums.values(Ring)) |*name, ring| name.* = @tagName(ring);
            const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &names);
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .waves = try .create(gpa, &textures.table, .round) };
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.waves.deinit(gpa);
            built.textures.deinit(gpa);
        }
    };
};

test Ring {
    var built: testing.Built = try .init(std.testing.allocator);
    defer built.deinit(std.testing.allocator);

    // Each ring is a band a unit out, a tenth deep, over its own texture.
    const mesh = built.waves.meshes.getPtrConst(.rng_03);
    try std.testing.expectEqual(Roundness.round.corners(), mesh.positions.len);
    try std.testing.expectApproxEqAbs(1, mesh.radius, 1e-6);
    try std.testing.expectApproxEqAbs(hole, math.length(mesh.positions[1]), 1e-6);
    try std.testing.expectEqual((try built.textures.table.find("rng_03")).?, mesh.surfaces[0].textures[0].image);

    // Its texture shows mirrored in each quarter, and never quite from the middle.
    const uv = mesh.uv[0].?;
    for (mesh.indices, uv) |index, corner| {
        const at = mesh.positions[index];
        try std.testing.expectApproxEqAbs(@max(@abs(at[0]), uv_least), corner[0], 1e-6);
        try std.testing.expect(corner[1] >= uv_least and corner[1] <= 1 + 1e-6);
    }
    try std.testing.expectEqual(Ring.rng_01, Kind.torpedo.ring());

    // The original's is an octagon.
    const octagon = try ringMesh(std.testing.allocator, (try built.textures.table.find("rng_03")).?, .octagon);
    defer octagon.deinit(std.testing.allocator);
    try std.testing.expectEqual(16, octagon.positions.len);
    try std.testing.expectEqual(Ring.rng_06, Kind.havoc.ring());
}

test Shockwaves {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    world.shockwaves = &built.waves;
    const player = try mission.add(.predator, @splat(0));
    mission.objects.slots[player].drawn.position = .{ 0, 0, 500 };
    mission.clock.frame_duration = 10;

    // A tenth through its life it has spread a tenth of its size, faded a tenth and drifted on;
    // passing the player, it shakes the view by that tenth.
    setOff(world, .{}, .{ .kind = .blast_02, .size = 10000, .life = 100, .velocity = .{ 1, 0, 0 }, .owner = player });
    const wave = &built.waves.waves[0].?;
    mission.clock.frame_start = 10;
    built.waves.frame(world);
    try std.testing.expectEqual(1000, wave.reach);
    try std.testing.expectEqual(0.9, wave.colours[5][3]);
    try std.testing.expectEqual(Vector{ 10, 0, 0 }, wave.at);

    // Drawn half a tick on, it has drifted and spread half a tick more.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try built.waves.draw(gpa, &scene, 0.5);
    try std.testing.expectEqual(Vector{ 10.5, 0, 0 }, wave.object.position);
    try std.testing.expectEqual(1050, wave.object.scale);
    try std.testing.expectEqual(1, mission.shake);

    // Once its life is over it is gone.
    mission.clock.frame_start = 100;
    built.waves.frame(world);
    try std.testing.expectEqual(null, built.waves.waves[0]);

    // With every slot spreading, one more is not set off.
    for (0..max_shockwaves + 1) |_| setOff(world, .{}, .{ .kind = .blast_03, .size = 1, .life = 1000, .owner = player });
    for (built.waves.waves) |slot| try std.testing.expect(slot != null);
}

test "a split's shockwave" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    world.shockwaves = &built.waves;
    const player = try mission.add(.predator, @splat(0));
    const badanov = try mission.add(.badanov, @splat(0));
    const stalag = try mission.add(.stalag, @splat(0));
    const slot = &mission.objects.slots[player];
    slot.drawn.position = .{ 0, 0, 1000 };
    slot.object.shields = .all(1000);
    mission.player.shield_reserves = .{ .fore = 0, .aft = 0 };

    // A fifth through its life it passes the player: each quadrant takes the cube of what is left
    // of its life times its size, 0.015 of it for a Badanov's, half of that landing at medium
    // difficulty.
    setOff(world, .{}, .{ .kind = .split, .size = 6000, .life = 100, .owner = badanov });
    mission.clock.frame_start = 20;
    built.waves.frame(world);
    const heavy = 0.8 * 0.8 * 0.8 * 6000 * split_harm / 2.0;
    try std.testing.expectApproxEqAbs(1000 - heavy, slot.object.shields.at(.left).*, 1e-2);
    try std.testing.expectApproxEqAbs(1000 - heavy, slot.object.shields.at(.fore).*, 1e-2);
    try std.testing.expectEqual(2, mission.shake);

    // A Stalag's harms less.
    mission.clock.frame_start = 100;
    built.waves.frame(world);
    slot.object.shields = .all(1000);
    setOff(world, .{}, .{ .kind = .split, .size = 6000, .life = 100, .owner = stalag });
    mission.clock.frame_start = 120;
    built.waves.frame(world);
    const light = 0.8 * 0.8 * 0.8 * 6000 * lighter_split_harm / 2.0;
    try std.testing.expectApproxEqAbs(1000 - light, slot.object.shields.at(.right).*, 1e-2);
}

test "a torpedo's shockwave" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    world.shockwaves = &built.waves;
    const player = try mission.add(.predator, @splat(0));
    const torpedo = try mission.add(.sabre, @splat(0));
    const slot = &mission.objects.slots[player];
    slot.drawn.position = .{ 0, 0, 1000 };
    slot.object.shields = .all(1000);
    mission.player.shield_reserves = .{ .fore = 100, .aft = 1000 };

    // A fifth through its life it passes the player: each quadrant takes 240, which lands on the
    // player's ship at half at medium difficulty; the fore's reserve runs out and the shield takes
    // half what it held, and the aft's reserve holds.
    setOff(world, .{}, .{ .kind = .torpedo, .size = 6000, .life = 100, .owner = torpedo });
    mission.clock.frame_start = 20;
    built.waves.frame(world);
    const shields = &slot.object.shields;
    try std.testing.expectApproxEqAbs(880, shields.at(.left).*, 1e-3);
    try std.testing.expectApproxEqAbs(880, shields.at(.right).*, 1e-3);
    try std.testing.expectApproxEqAbs(950, shields.at(.fore).*, 1e-3);
    try std.testing.expectEqual(1000, shields.at(.aft).*);
    try std.testing.expectEqual(0, mission.player.shield_reserves.fore);
    try std.testing.expectApproxEqAbs(760, mission.player.shield_reserves.aft, 1e-3);
    try std.testing.expectEqual(torpedo, slot.object.last_attacker.index());
    try std.testing.expectEqual(2, mission.shake);
    try std.testing.expectEqual(20 + harm_pause, slot.object.shockwave_until);

    // Another passing within the pause leaves it alone.
    setOff(world, .{}, .{ .kind = .torpedo, .size = 6000, .life = 100, .owner = torpedo });
    mission.clock.frame_start = 40;
    built.waves.frame(world);
    try std.testing.expectApproxEqAbs(880, shields.at(.left).*, 1e-3);
}
