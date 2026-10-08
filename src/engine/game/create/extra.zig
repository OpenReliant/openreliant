//! The extras a few types carry on one of their parts beyond their model, in
//! `C:\lancer\game\Create.cpp`: the Dark Reign's hat, which `create_object` hangs on its `Dark Hat`
//! as it makes the ship (`0x00467E20`), and the glows of the prototype gate's and the Boridin
//! breakaway's cores, which `explode_component_lost` lights as their components go
//! (`explode.extras`). The game keeps an extra in a record of 0x1C bytes that hangs on its part's
//! frame (`+0x16C`): a first object (`+0x00`), a second (`+0x04`), four electric rays (`+0x08`) and
//! a particle emitter (`+0x18`). OpenReliant keeps it with the object's slot
//! (`create.Slot.extra`).
//!
//! `mission_frame`'s pass over the objects draws it (`main.drawObjects`), the explosions put it out
//! (`explode.extras.putOut`), and `object_free` (`0x00475EF0`) lets it go with the object
//! (`create.Slot.release`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const loadout = @import("../../interface/loadout/loadout.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const create = @import("../create.zig");
const erayfx = @import("../erayfx.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const guns = @import("../guns.zig");
const matmanager = @import("../matmanager.zig");
const objects = @import("../objects.zig");
const particles = @import("../particles.zig");

const log = std.log.scoped(.create);

/// A type's extra, as its part's frame holds it (`+0x16C`).
pub const Extra = union(enum) {
    /// The Dark Reign's hat.
    hat: Hat,
    /// The glow of the prototype gate's or the Boridin breakaway's core.
    glow: Glow,

    /// The template of the sparks it streams, by which they are found among the burning wrecks'
    /// smoke (`explode.Explosions.dropStream`).
    pub fn sparks(extra: *const Extra) *const particles.Template {
        return switch (extra.*) {
            .hat => &explode.hat_sparks,
            .glow => |glow| glow.sparks,
        };
    }

    /// Lets go of it and what it draws, as `object_free` does (`scene_object_free`,
    /// `sprite_set_free`). Its rays and its sparks are left to go with their parts.
    pub fn destroy(extra: *Extra, gpa: Allocator) void {
        switch (extra.*) {
            .hat => |*hat| hat.deinit(gpa),
            .glow => {},
        }
        gpa.destroy(extra);
    }
};

/// The textures the extras are drawn over, which the game requires as it makes them: the hat's
/// band's and the cores' glows', `gunflare\partic5` (`0x004F9D40`), and the hat's star's, `laser4`
/// (`0x004F9D20`).
pub const Images = struct {
    glow: *srtexture.Image,
    star: *srtexture.Image,

    pub fn load(textures: *srtexture.Table) matmanager.Error!Images {
        return .{
            .glow = try matmanager.textureRequire(textures, "gunflare\\partic5"),
            .star = try matmanager.textureRequire(textures, "laser4"),
        };
    }
};

/// A core's glow (`Explode Powercore BMO`): a set of one sprite over `gunflare\partic5`, unlit and
/// added, 2500 either way as it is made, which the objects pass sizes each frame. It hangs from the
/// node of a part or of an object's root, or stands in the world.
pub const Glow = struct {
    /// What it hangs from; null for nothing, so that it stands in the world.
    parent: ?objects.NodeOf,
    /// Where it stands in that frame, or in the world.
    at: Vector,
    /// The sparks it streams (`Extra.sparks`).
    sparks: *const particles.Template,
    set: srapiext.SpriteSet,
    sprite: [1]srapiext.Sprite,

    /// Sizes it `half` either way, sorted as if it stood `bias` farther.
    pub fn size(glow: *Glow, half: f32, bias: f32) void {
        glow.sprite[0].half_size = @splat(half);
        glow.sprite[0].bias = bias;
    }

    /// Stands it where its parent puts it: false where its parent is gone.
    pub fn stand(glow: *Glow, all: *const create.Objects) bool {
        const parent = glow.parent orelse {
            glow.set.position = glow.at;
            return true;
        };
        const place = parent.place(all) orelse return false;
        glow.set.position = place.point(glow.at);
        return true;
    }
};

/// How large a glow is as it is made (`0x0046DED5`, `0x0046E140`).
const glow_made_size: f32 = 2500;

/// The record of a core's glow over `images`, made in `gpa`, hanging from `parent` at `at`
/// (`Glow`), and streaming `sparks`.
pub fn makeGlow(gpa: Allocator, images: *const Images, parent: ?objects.NodeOf, at: Vector, sparks: *const particles.Template) Allocator.Error!*Extra {
    const extra = try gpa.create(Extra);
    extra.* = .{ .glow = .{ .parent = parent, .at = at, .sparks = sparks, .set = .{ .sprites = &.{} }, .sprite = .{.{}} } };
    const glow = &extra.glow;
    glow.size(glow_made_size, 0);
    glow.set.sprites = &glow.sprite;
    glow.set.surface.textures = .{ .{ .image = images.glow }, .none };
    return extra;
}

/// A mesh of its own hanging from a part, where it stands in the part's frame, and the object that
/// draws it (`mesh_object_create`).
pub const Hanging = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    place: math.Place,

    /// Makes the object draw `hanging.mesh`, at the finest level at any distance, with `flags`.
    fn show(hanging: *Hanging, flags: srapiext.ObjectFlags) void {
        hanging.level = .{.{ .mesh = &hanging.mesh, .until = std.math.inf(f32) }};
        hanging.object = .{ .flags = flags, .position = @splat(0), .radius = hanging.mesh.radius, .levels = &hanging.level };
    }

    /// Stands its object where its part, at `part`, puts it.
    pub fn stand(hanging: *Hanging, part: math.Place) void {
        const at = hanging.place.within(part);
        hanging.object.position = at.position;
        hanging.object.orientation = at.orientation;
    }
};

/// The Dark Reign's hat: a glowing band hanging below its `Dark Coil`, a red star in the band, red
/// sparks streaming from below the star, and four white rays from the coil to the `Dark Hat`.
pub const Hat = struct {
    /// The part the band, the star and the sparks hang from: the `Dark Coil`.
    coil: objects.PartOf,
    /// `darkreign extra mesh1` (`+0x00`) and `darkreign extra mesh2` (`+0x04`).
    band: Hanging,
    star: Hanging,
    /// The star's own colours, a vertex each.
    star_colours: [star_blades * guns.blade_corners][4]f32,
    /// Its rays (`+0x08`), as the rays keep them.
    rays: [ray_count]?erayfx.Rays.Kept = @splat(null),

    /// The band and the star, made over `images` from `coil`, whose drawn level's mesh has its
    /// vertices' middle at `middle`.
    fn make(hat: *Hat, gpa: Allocator, images: *const Images, coil: objects.PartOf, middle: Vector) Allocator.Error!void {
        hat.coil = coil;
        hat.rays = @splat(null);
        hat.band.mesh = try loadout.bandMesh(gpa, band_segments, band_radius, band_depth);
        errdefer hat.band.mesh.deinit(gpa);
        const band = &hat.band.mesh;
        band.surfaces[0] = .{ .polygons = @intCast(band.polygons.len), .material = band_material, .textures = .{ .{ .image = images.glow }, .none } };
        @memset(band.uv[0].?, band_uv);
        hat.band.show(band_flags);
        hat.band.place = .{ .position = Vector{ 0, -band_drop, 0 } + middle, .orientation = math.fromAngles(band_turn, 0, 0) };

        hat.star.mesh = try guns.starMesh(gpa, star_blades, star_radius, .{ -star_half_length, star_half_length }, .{ .{ 0, 0 }, .{ 1, 1 } }, guns.meshMaterial(true), images.star);
        hat.star.show(star_flags);
        hat.star_colours = @splat(srapiext.solid(star_colour));
        hat.star.object.baked = &hat.star_colours;
        hat.star.place = .{ .position = hat.band.place.position - Vector{ 0, star_drop, 0 }, .orientation = hat.band.place.orientation };
    }

    fn deinit(hat: *Hat, gpa: Allocator) void {
        hat.band.mesh.deinit(gpa);
        hat.star.mesh.deinit(gpa);
    }

    /// Where its sparks stream from in the coil's frame: below the star (`0x004681BD`).
    fn sparksAt(hat: *const Hat) Vector {
        return hat.star.place.position - Vector{ 0, sparks_drop, 0 };
    }
};

/// The parts the hat hangs from: its band, star and sparks from the `Dark Coil` (`0x004F9D54`), the
/// record from the `Dark Hat` (`0x004F9CFC`); and the part whose mass the Dark Reign takes twice
/// (`0x004E1C88`).
pub const dark_coil = "Dark Coil";
pub const dark_hat = "Dark Hat";
pub const dark_low_body = "Dark Low Body";

/// The band (`mesh_build_band`, `0x00467FD6`): 9 quads round its axis, 1000 out from it and 5000
/// along it, every corner at the middle of `gunflare\partic5` (`0x00468005`), unlit and added,
/// never culled. It hangs from the coil, its axis turned a quarter turn about X to run down the
/// coil's Y (`0x0046803A`), starting 1800 below the middle of the coil's vertices.
const band_segments = 9;
const band_radius: f32 = 1000;
const band_depth: f32 = 5000;
const band_uv: [2]f32 = .{ 0.5, 0.5 };
const band_material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .add });
const band_flags: srapiext.ObjectFlags = .{ .not_culled = true, .owns_mesh = true };
const band_turn = std.math.pi / 2.0;
const band_drop: f32 = 1800;

/// The star (`mesh_build_star`, `0x004680EE`): 5 blades of `laser4` through its axis, each 1500
/// either side of it and 2500 along it either way, coloured red by its own colours, added and
/// never culled. It stands 2500 further down the coil than the band (`0x004DC7D0`), turned as the
/// band is, so that it fills it.
const star_blades = 5;
const star_radius: f32 = 1500;
const star_half_length: f32 = 2500;
const star_colour: [3]f32 = .{ 1, 0, 0 };
const star_flags: srapiext.ObjectFlags = .{ .not_culled = true, .owns_mesh = true, .baked_object = true };
const star_drop: f32 = 2500;

/// The sparks (`explode.hat_sparks`) stream for good from 1150 below the star (`0x004DC7CC`), at 20
/// to 30 a tick every way, a little less along the coil's Y: strayed up to a turn either way across
/// X and Z, and three quarters of one along Y (`0x004681DB`).
const sparks_drop: f32 = 1150;
const sparks_spread: Vector = .{ std.math.tau, 3 * std.math.pi / 2.0, std.math.tau };
const sparks_speed: f32 = 20;
const sparks_speed_range: f32 = 10;

/// The rays (`eray_add`, `0x00467ED6`): four, one strand each, straying by up to a fifth of their
/// length, 260 either way, dimming as they go dark, white. They last 5000 ticks only where they are
/// timed, and these are not.
const ray_count = 4;
const hat_ray: erayfx.Spec = .{ .life = 5000, .jitter = 0.2, .width = 260, .flags = .{ .fades = true } };
const ray_colour: [3]f32 = .{ 1, 1, 1 };

/// The part of `create_object` for the Dark Reign (`0x00467E20`), once it is made where the world
/// can see it: its hat, which hangs on its `Dark Hat` (`0x00468234`).
///
/// 1. A ray runs from each of the four points of the rays list of the root's first part, the
///    `Dark Coil`, to the same point of the second's, the `Dark Hat`, which it hangs from and plays
///    over the ship (`hangRays`).
/// 2. The band and the star hang from the part named `Dark Coil` (`Hat.make`), the band starting
///    1800 below the middle of the vertices of the coil's drawn level.
/// 3. The sparks stream from the coil's frame below the star, among the burning wrecks' smoke
///    (`explode.Explosions.hangStream`).
///
/// **Fix:** the game sums the coil's vertices onto a vector it never clears, starting from whatever
/// its stack held. OpenReliant starts from nothing.
pub fn hatMade(world: gameobj.World, index: u16) void {
    const all = world.objects;
    const slot = &all.slots[index];
    if (slot.object.type.base() != .darkreign) return;
    const images = world.extras orelse return;
    const model = if (slot.model) |*live| live else return;
    const coil = model.partNamed(dark_coil) orelse return;
    if (model.partNamed(dark_hat) == null) return;
    const part = coil.part();
    const middle: Vector = if (part.object.levels.len > 0) part.object.shown().middle() else @splat(0);
    const extra = makeHat(all.gpa, images, .{ .object = index, .part = coil }, middle) catch |err| {
        log.warn("the Dark Reign in slot {d} has no hat: {s}", .{ index, @errorName(err) });
        return;
    };
    slot.extra = extra;
    const hat = &extra.hat;
    hangRays(world, index, hat);
    if (world.explosions) |explosions| explosions.hangStream(.{ .part = hat.coil }, .{
        .life = explode.forever_life,
        .born = world.clock.frame_start,
        .place = .{ .position = hat.sparksAt() },
        .spread = sparks_spread,
        .speed = sparks_speed,
        .speed_range = sparks_speed_range,
        .template = &explode.hat_sparks,
    });
}

/// The hat's record, its band and its star made in `gpa` (`Hat.make`).
fn makeHat(gpa: Allocator, images: *const Images, coil: objects.PartOf, middle: Vector) Allocator.Error!*Extra {
    const extra = try gpa.create(Extra);
    errdefer gpa.destroy(extra);
    extra.* = .{ .hat = undefined };
    try extra.hat.make(gpa, images, coil, middle);
    return extra;
}

/// The hat's rays (`0x00467EC0`): one from each point of the rays list of the root's first part to
/// the same point of the second's, as many as both lists have, up to four. Each hangs from the
/// second part, the first part's point taken into that part's frame where the two stand as the
/// ship is made, and plays over the ship.
fn hangRays(world: gameobj.World, index: u16, hat: *Hat) void {
    const rays = world.rays orelse return;
    const model = if (world.objects.slots[index].model) |*live| live else return;
    if (model.rootChild(0) == null or model.rootChild(1) == null) return;
    const from = (model.partData(0) orelse return).pointList(.rays) orelse return;
    const to = (model.partData(1) orelse return).pointList(.rays) orelse return;
    const from_frame = model.frameAt(0, .{});
    const to_frame = model.frameAt(1, .{});
    const count = @min(from.points.len, to.points.len, ray_count);
    for (from.points[0..count], to.points[0..count], hat.rays[0..count]) |start, end, *kept| {
        const made = rays.add(hat_ray, world.random) catch return;
        made.colour(0, ray_colour);
        made.from = to_frame.inverse(from_frame.point(gameobj.vector(start.position)));
        made.to = gameobj.vector(end.position);
        made.hang(.{ .part = .{ .object = index, .part = .{ .model = model, .index = 1 } } });
        made.owner = index;
        kept.* = rays.keep(made);
    }
}

test {
    std.testing.refAllDecls(@This());
}

pub const testing = struct {
    /// Textures that are never looked into, for the extras' records in tests.
    var image: srtexture.Image = undefined;
    pub const images: Images = .{ .glow = &image, .star = &image };

    /// A Dark Reign wearing its hat (`hatMade`), in the mission of an `explode.testing.Stage`: its
    /// `Dark Coil` at its origin, its `Dark Hat` 1000 above it, each with four ray points about its
    /// own origin, and its `Dark Low Body`. It is set up where it stays, since its records point
    /// into it.
    pub const DarkReign = struct {
        named: objects.testing.NamedParts(3),
        kind: create.Type,
        rays: erayfx.testing.Built,
        /// Its slot.
        index: u16,

        pub const coil_points = [ray_count]Vector{ .{ 100, 0, 0 }, .{ 0, 0, 100 }, .{ -100, 0, 0 }, .{ 0, 0, -100 } };
        pub const hat_points = [ray_count]Vector{ .{ 200, 0, 0 }, .{ 0, 0, 200 }, .{ -200, 0, 0 }, .{ 0, 0, -200 } };
        pub const hat_height: Vector = .{ 0, 1000, 0 };

        /// Builds it (`build`), makes it in the stage's mission at `at` and hangs its hat (`make`).
        pub fn init(ship: *DarkReign, gpa: Allocator, stage: *explode.testing.Stage, at: Vector) !gameobj.World {
            ship.build();
            return ship.make(gpa, stage, at);
        }

        /// Its parts, which a test may change before it is made.
        pub fn build(ship: *DarkReign) void {
            ship.named.init(.{ dark_coil, dark_hat, dark_low_body }, .{ .rays, .rays, .rays }, .{ &coil_points, &hat_points, &.{} });
            ship.kind = .{ .model = &ship.named.parts.source, .loaded = &ship.named.parts.loaded };
        }

        /// Makes it in the stage's mission at `at` and hangs its hat, and returns the world, which
        /// reaches the rays and the textures as well as the explosions.
        pub fn make(ship: *DarkReign, gpa: Allocator, stage: *explode.testing.Stage, at: Vector) !gameobj.World {
            ship.rays = try .init(gpa);
            errdefer ship.rays.deinit(gpa);
            var world = stage.world();
            world.rays = &ship.rays.rays;
            world.extras = &images;
            ship.index = try stage.mission.addWith(create.testing.oneType(&ship.kind), .of(.darkreign), at);
            stage.mission.slot(ship.index).model.?.parts[1].origin = hat_height;
            hatMade(world, ship.index);
            return world;
        }

        /// Lets go of its rays; its slot goes with the stage's mission.
        pub fn deinit(ship: *DarkReign, gpa: Allocator) void {
            ship.rays.deinit(gpa);
        }

        /// Its hat, while it wears one.
        pub fn hat(ship: *const DarkReign, stage: *explode.testing.Stage) ?*Hat {
            const extra = stage.mission.slot(ship.index).extra orelse return null;
            return switch (extra.*) {
                .hat => |*worn| worn,
                .glow => null,
            };
        }
    };
};

test hatMade {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var ship: testing.DarkReign = undefined;
    const world = try ship.init(gpa, &stage, @splat(0));
    defer ship.deinit(gpa);
    const hat = ship.hat(&stage).?;

    // The band hangs 1800 down the coil, its axis turned to run down the coil's Y, and the star,
    // red, 2500 below it.
    try std.testing.expectEqual(Vector{ 0, -band_drop, 0 }, hat.band.place.position);
    try math.testing.expectVectorWithin(.{ 0, -1, 0 }, math.transform(hat.band.place.orientation, .{ 0, 0, 1 }), 1e-6);
    try std.testing.expectEqual(Vector{ 0, -band_drop - star_drop, 0 }, hat.star.place.position);
    try std.testing.expectEqual(hat.band.place.orientation, hat.star.place.orientation);
    try std.testing.expectEqual(srapiext.solid(star_colour), hat.star.object.baked.?[star_blades * guns.blade_corners - 1]);
    // Every corner of the band shows the middle of its texture.
    for (hat.band.mesh.uv[0].?) |uv| try std.testing.expectEqual(band_uv, uv);

    // Each ray runs from a point of the coil, taken into the hat's frame, to the hat's point, and
    // hangs from the hat over the ship.
    for (hat.rays, testing.DarkReign.coil_points, testing.DarkReign.hat_points) |kept, from, to| {
        const made = ship.rays.rays.kept(kept.?).?;
        try std.testing.expectEqual(from - testing.DarkReign.hat_height, made.from);
        try std.testing.expectEqual(to, made.to);
        try std.testing.expectEqual(1, made.parent.part.part.index);
        try std.testing.expectEqual(ship.index, made.owner.?);
    }

    // The sparks stream for good from the coil's frame, 1150 below the star.
    const stream = stage.explosions.streams[0].?;
    try std.testing.expectEqual(&explode.hat_sparks, stream.emitter.template);
    try std.testing.expectEqual(Vector{ 0, -band_drop - star_drop - sparks_drop, 0 }, stream.emitter.place.position);
    try std.testing.expectEqual(explode.forever_life, stream.emitter.life);
    try std.testing.expectEqual(0, stream.on.part.part.index);

    // Another type wears none.
    const other = try stage.mission.add(.of(.predator), @splat(0));
    hatMade(world, other);
    try std.testing.expectEqual(null, stage.mission.slot(other).extra);
}

test "the Dark Reign takes its Dark Low Body's mass twice" {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var ship: testing.DarkReign = undefined;
    ship.build();
    ship.named.parts.data[2].part.volume = 5;
    ship.named.parts.data[2].part.density = 2;
    _ = try ship.make(gpa, &stage, @splat(0));
    defer ship.deinit(gpa);
    // Its parts sum to the body's 10, and it takes the body's again.
    try std.testing.expectEqual(20, stage.mission.slot(ship.index).object.mass);
}
