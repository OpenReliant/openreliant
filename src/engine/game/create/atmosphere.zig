//! The planets' atmospheres (`Create.cpp`, `planet_atmospheres`, `0x00545868`): a ring in a planet's
//! own colour round the rim of each of the planets that have one, fading out toward its edge, which
//! `create_object` makes as it makes the planet (`Atmospheres.made`) and `backdrop_frame` turns to
//! the camera each frame, as bright as the lens flares, the planet turning slowly as it goes
//! (`Atmospheres.frame`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const loadout = @import("../../interface/loadout/loadout.zig");
const math = @import("../../surrender/math.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const matmanager = @import("../matmanager.zig");
const xtrabits = @import("../xtrabits.zig");
const Vector = math.Vector;

const log = std.log.scoped(.create);

/// How many atmospheres the table holds (`0x00545868` to `0x005458F8`).
pub const capacity = 4;

/// The texture an atmosphere is drawn over (`planet_atmosphere_texture`, `0x005458FC`).
pub const texture_name = "atmos";

/// The quads of the band an atmosphere is made of (`0x0046796B`), and as many as OpenReliant makes
/// a haze's of, round at any size (`Style.haze`).
pub const segments = 20;
pub const round_segments = 96;

/// How the atmospheres are drawn.
pub const Style = enum {
    /// **Improvement:** as a haze. Each ring is made of `round_segments` quads, where the game's
    /// show their sides at high resolutions. It is there at all times, faint on the planet's night
    /// side and brighter toward its sunlit side (`hazeAt`), and as solid as the game's where the
    /// lens flares are brighter. The planet's terminator is softened, the sun reaching a little way
    /// round into its night side (`srapiext.MeshObject.soft_terminator`).
    haze,
    /// As the game draws them: of `segments` quads, there only as the lens flares are.
    original,

    fn quads(style: Style) u16 {
        return switch (style) {
            .haze => round_segments,
            .original => segments,
        };
    }
};

/// How solid a haze is on its planet's night side, and on its sunlit side (`Style.haze`).
pub const haze_night: f32 = 0.15;
pub const haze_day: f32 = 0.6;

/// How solid a haze is at a point of its ring that lies `out` from the planet's middle, the sun
/// `toward` it: `haze_day` on the side that faces the sun, `haze_night` on the side away from it,
/// and between them as the cosine goes.
pub fn hazeAt(out: Vector, toward: Vector) f32 {
    const lit = 0.5 + 0.5 * math.dot(math.normalize(out), toward);
    return math.lerp(haze_night, haze_day, lit);
}

/// Where an atmosphere's inner edge stands, as a share of the planet's radius (`0x00467A05`).
pub const inner_edge: f32 = 0.85;

/// How far a planet with an atmosphere turns about its own Y each tick, in radians
/// (`0x00467B75`).
pub const spin: f32 = 0.0007;

/// How an atmosphere looks, by its planet's type: the colour of its inner edge, which fades to
/// nothing at the outer, and where the outer edge stands, as a share of the planet's radius
/// (`0x00467A47` to `0x00467B18`). Only the planets it names have one.
pub const Look = struct {
    colour: [3]f32,
    outer_edge: f32,

    pub fn of(planet: gameobj.Type) ?Look {
        return switch (planet) {
            .neptune_hi, .neptune_lo => .{ .colour = .{ 0.1, 0.15, 0.2 }, .outer_edge = 0.95 },
            .uranus_hi, .uranus_lo => .{ .colour = .{ 0.15, 0.2, 0.2 }, .outer_edge = 0.95 },
            .jupiter_hi, .jupiter_lo, .venus_hi, .venus_lo => .{ .colour = .{ 0.2, 0.2, 0.15 }, .outer_edge = 1.005 },
            else => null,
        };
    }
};

/// A planet's atmosphere: its band, the scene object that draws it, "Planet atmos mesh", and the
/// band's colours, one a vertex, which the object is coloured by.
pub const Ring = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [2 * round_segments][4]f32,

    /// The ring of a planet of `radius` that looks as `look` says (`create_object`,
    /// `0x0046795D`): a band of `quads` (`loadout.bandMesh`), flat, its first circle drawn
    /// in to `inner_edge` of the radius and its second to the look's outer edge, over `image`,
    /// added by the alpha of its colours; the first circle in the look's colour, the second black,
    /// all solid until the frame sets their alpha. It is never culled, and is coloured by its own.
    pub fn create(gpa: Allocator, image: *srtexture.Image, radius: f32, look: Look, quads: u16) Allocator.Error!*Ring {
        std.debug.assert(quads <= round_segments);
        const ring = try gpa.create(Ring);
        errdefer gpa.destroy(ring);
        ring.mesh = try loadout.bandMesh(gpa, quads, radius, 0);
        errdefer ring.mesh.deinit(gpa);
        const mesh = &ring.mesh;
        mesh.surfaces[0] = .{
            .polygons = @intCast(mesh.polygons.len),
            .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add_alpha }),
            .textures = .{ .{ .image = image }, .none },
        };
        const colours = ring.colours[0 .. 2 * @as(usize, quads)];
        for (mesh.positions[0..quads], mesh.positions[quads..], colours[0..quads], colours[quads..]) |*inner, *outer, *inner_colour, *outer_colour| {
            inner.* *= @splat(inner_edge);
            outer.* *= @splat(look.outer_edge);
            inner_colour.* = .{ look.colour[0], look.colour[1], look.colour[2], 1 };
            outer_colour.* = .{ 0, 0, 0, 1 };
        }
        srapi.calcPolyNormals(mesh);
        srapi.calcVertexNormals(mesh);
        srapi.findBoundingBox(mesh);
        ring.level = .{.{ .mesh = mesh, .until = std.math.inf(f32) }};
        ring.object = .{
            .flags = .{ .not_culled = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = mesh.radius,
            .levels = &ring.level,
            .baked = colours,
        };
        return ring;
    }

    /// Sets how solid it is, its object turned as it is drawn: as the lens flares are bright,
    /// `brightness`, and for a haze at least as `hazeAt` has it at each vertex, the sun `toward` it.
    fn fade(ring: *Ring, style: Style, brightness: f32, toward: Vector) void {
        const quads = ring.mesh.positions.len / 2;
        const colours = ring.colours[0 .. 2 * quads];
        for (ring.mesh.positions[0..quads], colours[0..quads], colours[quads..]) |at, *inner, *outer| {
            const alpha = switch (style) {
                .haze => @max(brightness, hazeAt(math.transform(ring.object.orientation, at), toward)),
                .original => brightness,
            };
            inner[3] = alpha;
            outer[3] = alpha;
        }
    }

    pub fn destroy(ring: *Ring, gpa: Allocator) void {
        ring.mesh.deinit(gpa);
        gpa.destroy(ring);
    }
};

/// The atmospheres of the mission's planets, and the texture they are drawn over.
pub const Atmospheres = struct {
    gpa: Allocator,
    image: *srtexture.Image,
    /// How they are drawn.
    style: Style = .haze,
    entries: [capacity]Entry = undefined,
    count: usize = 0,
    /// The frame the planets last turned at (`0x00595BC0`).
    turned_at: i32 = 0,

    /// An atmosphere: its ring, how fast its planet turns, and the planet's slot (`+0x00`, `+0x04`
    /// and `+0x20` of the table's entries). The table also keeps where the planet stood as it was
    /// made (`+0x14`), which nothing reads.
    pub const Entry = struct {
        ring: *Ring,
        spin: f32,
        planet: u16,
    };

    /// As `objects_reset` (`0x00466630`) loads `atmos`, with no atmospheres.
    pub fn init(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!Atmospheres {
        return .{ .gpa = gpa, .image = try matmanager.textureRequire(textures, texture_name) };
    }

    /// As a mission ends (`0x004666B0`), and as the next starts (`objects_reset`): every
    /// atmosphere let go.
    pub fn reset(atmospheres: *Atmospheres) void {
        for (atmospheres.entries[0..atmospheres.count]) |entry| entry.ring.destroy(atmospheres.gpa);
        atmospheres.count = 0;
    }

    pub fn deinit(atmospheres: *Atmospheres) void {
        atmospheres.reset();
    }

    /// The part of `create_object` for a planet, once the object in slot `index` is made: a
    /// planet of a type that has an atmosphere (`Look.of`) gets one, as wide as its model's first
    /// part, turning at `spin`. A haze softens the planet's terminator.
    ///
    /// **Fix:** the game counts on at most `capacity` of them, and a fifth would write past its
    /// table; OpenReliant makes no more, and says so.
    pub fn made(atmospheres: *Atmospheres, all: *create.Objects, index: u16) void {
        const slot = &all.slots[index];
        const look = Look.of(slot.object.type) orelse return;
        const model = if (slot.model) |*held| held else return;
        if (model.parts.len == 0) return;
        if (atmospheres.count == capacity) {
            log.warn("the atmosphere of object {d} is left out: there are {d} already", .{ index, capacity });
            return;
        }
        const part = &model.parts[0].object;
        const ring = Ring.create(atmospheres.gpa, atmospheres.image, part.radius, look, atmospheres.style.quads()) catch |err| {
            log.warn("the atmosphere of object {d} is left out: {s}", .{ index, @errorName(err) });
            return;
        };
        atmospheres.entries[atmospheres.count] = .{ .ring = ring, .spin = spin, .planet = index };
        atmospheres.count += 1;
        if (atmospheres.style == .haze) {
            for (model.parts) |*each| each.object.soft_terminator = true;
        }
    }

    /// `backdrop_frame`'s (`0x004A5CD0`) last work, at frame `now`: each planet with an atmosphere
    /// turns about its own Y by its spin for each tick since the last frame, drawn so at once.
    /// Where the renderer is the hardware's, `hardware`, and the planet is not disabled, its
    /// atmosphere stands where the planet does, turned to face the camera at `camera`, as solid as
    /// the lens flares' `brightness` (`backdrop.flareBrightness`), or a haze as `Ring.fade` has it
    /// with the sun along `sun`, and goes on the background layer.
    /// The planet's parts stand at its origin (`create.planetMade`), so it turns in place, and the
    /// ring stands round it.
    pub fn frame(atmospheres: *Atmospheres, gpa: Allocator, scene: *srcore.Scene, all: *create.Objects, camera: Vector, sun: Vector, hardware: bool, brightness: f32, now: i32) Allocator.Error!void {
        const ticks: f32 = @floatFromInt(now - atmospheres.turned_at);
        defer atmospheres.turned_at = now;
        const toward = math.normalize(sun);
        for (atmospheres.entries[0..atmospheres.count]) |entry| {
            const planet = &all.slots[entry.planet];
            planet.drawn.orientation = math.turned(planet.drawn.orientation, .y, ticks * entry.spin);
            if (planet.model) |*model| model.place(planet.drawn.position, planet.drawn.orientation);
            if (!hardware or planet.object.flags.disabled) continue;
            const object = &entry.ring.object;
            object.position = planet.drawn.position;
            object.orientation = math.lookAt(camera - object.position);
            entry.ring.fade(atmospheres.style, brightness, toward);
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = object }, .background);
        }
    }

    /// Lets go of the atmosphere of the planet in slot `index`, as `DestroyFlightGroup` retires it
    /// (`cmd_DestroyFlightGroup`, `0x00457FD0`).
    ///
    /// **Fix:** the game counts one atmosphere fewer for any planet of the types from `0x60` to
    /// `0x69` and from `0xCA` to `0xD3` whether it has one or not, leaving out both Neptunes, looks
    /// for it among the atmospheres before the last alone, and frees the one it finds while keeping
    /// it in the table, which goes on drawing it; OpenReliant lets go of the planet's own and takes
    /// it out.
    pub fn release(atmospheres: *Atmospheres, index: u16) void {
        for (atmospheres.entries[0..atmospheres.count], 0..) |entry, at| {
            if (entry.planet != index) continue;
            entry.ring.destroy(atmospheres.gpa);
            std.mem.copyForwards(Entry, atmospheres.entries[at .. atmospheres.count - 1], atmospheres.entries[at + 1 .. atmospheres.count]);
            atmospheres.count -= 1;
            return;
        }
    }
};

test hazeAt {
    const sun: Vector = .{ 1, 0, 0 };
    try std.testing.expectApproxEqAbs(haze_day, hazeAt(.{ 5, 0, 0 }, sun), 1e-6);
    try std.testing.expectApproxEqAbs(haze_night, hazeAt(.{ -5, 0, 0 }, sun), 1e-6);
    // At the terminator, halfway between.
    try std.testing.expectApproxEqAbs((haze_night + haze_day) / 2, hazeAt(.{ 0, 3, 0 }, sun), 1e-6);
}

test Look {
    try std.testing.expectEqual(0.95, Look.of(.neptune_lo).?.outer_edge);
    try std.testing.expectEqual([3]f32{ 0.15, 0.2, 0.2 }, Look.of(.uranus_hi).?.colour);
    try std.testing.expectEqual(1.005, Look.of(.venus_hi).?.outer_edge);
    try std.testing.expectEqual(null, Look.of(.predator));
}

test Ring {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = .{ .levels = &.{} };
    const ring = try Ring.create(gpa, &image, 1000, Look.of(.jupiter_hi).?, segments);
    defer ring.destroy(gpa);
    // Flat, from 0.85 of the radius in the look's colour out to its outer edge, black.
    try std.testing.expectApproxEqAbs(850, math.length(ring.mesh.positions[0]), 1e-2);
    try std.testing.expectApproxEqAbs(1005, math.length(ring.mesh.positions[segments]), 1e-2);
    for (ring.mesh.positions) |position| try std.testing.expectEqual(0, position[2]);
    try std.testing.expectEqual([4]f32{ 0.2, 0.2, 0.15, 1 }, ring.colours[0]);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, ring.colours[segments]);
    for (ring.mesh.normals) |normal| try std.testing.expectApproxEqAbs(1, @abs(normal[2]), 1e-5);
    // Over the texture, added by its colours' alpha, coloured by its own.
    try std.testing.expectEqual(&image, ring.mesh.surfaces[0].textures[0].image);
    try std.testing.expectEqual(srapiext.Material.Blend.add_alpha, ring.mesh.surfaces[0].material.blend[0]);
    try std.testing.expect(ring.object.flags.baked_object and ring.object.flags.not_culled);
    try std.testing.expectEqual(2 * segments, ring.object.baked.?.len);
}

test "a round ring" {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = .{ .levels = &.{} };
    const ring = try Ring.create(gpa, &image, 1000, Look.of(.neptune_hi).?, round_segments);
    defer ring.destroy(gpa);
    try std.testing.expectEqual(2 * round_segments, ring.mesh.positions.len);
    try std.testing.expectEqual(2 * round_segments, ring.object.baked.?.len);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, ring.colours[round_segments]);
}

test Atmospheres {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var image: srtexture.Image = .{ .levels = &.{} };
    var atmospheres: Atmospheres = .{ .gpa = gpa, .image = &image, .style = .original };
    defer atmospheres.deinit();
    const all = mission.objects;
    var planets: [capacity + 1]u16 = undefined;
    for (&planets, 0..) |*planet, n| {
        planet.* = try mission.addWith(model.types(), .predator, .{ @floatFromInt(n * 100000), 0, 0 });
        all.slots[planet.*].object.type = .neptune_hi;
    }
    const ship = try mission.addWith(model.types(), .predator, @splat(0));

    // A planet that has one gets its atmosphere; another object none, and a fifth planet none.
    atmospheres.made(all, ship);
    for (planets) |planet| atmospheres.made(all, planet);
    try std.testing.expectEqual(capacity, atmospheres.count);
    try std.testing.expectEqual(planets[0], atmospheres.entries[0].planet);

    // A frame 100 ticks on turns each planet by 100 of its spin, and puts its atmosphere where it
    // stands, facing the camera, as solid as the flares.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const before = all.slots[planets[0]].drawn.orientation;
    try atmospheres.frame(gpa, &scene, all, .{ 0, 0, -5000 }, .{ 1, 0, 0 }, true, 0.5, 100);
    const turned = math.turned(before, .y, 100 * spin);
    try math.testing.expectMatrixWithin(turned, all.slots[planets[0]].drawn.orientation, 1e-5);
    try std.testing.expectEqual(capacity, scene.layers.get(.background).items.len);
    const ring = atmospheres.entries[0].ring;
    try std.testing.expectEqual(all.slots[planets[0]].drawn.position, ring.object.position);
    try std.testing.expect(math.dot(math.forward(ring.object.orientation), math.normalize(@as(Vector, .{ 0, 0, -5000 }) - ring.object.position)) > 0.9999);
    for (ring.colours[0 .. 2 * segments]) |colour| try std.testing.expectEqual(0.5, colour[3]);
    // As the game draws them, the planet's terminator stays hard.
    for (all.slots[planets[0]].model.?.parts) |part| try std.testing.expect(!part.object.soft_terminator);

    // The software renderer draws none, nor a disabled planet's; they turn all the same.
    scene.clear();
    all.slots[planets[1]].object.flags.disabled = true;
    try atmospheres.frame(gpa, &scene, all, @splat(0), .{ 1, 0, 0 }, true, 0.5, 110);
    try std.testing.expectEqual(capacity - 1, scene.layers.get(.background).items.len);
    scene.clear();
    try atmospheres.frame(gpa, &scene, all, @splat(0), .{ 1, 0, 0 }, false, 0.5, 120);
    try std.testing.expectEqual(0, scene.layers.get(.background).items.len);

    // Destroyed, a planet's own atmosphere goes; the others stay.
    atmospheres.release(planets[1]);
    try std.testing.expectEqual(capacity - 1, atmospheres.count);
    for (atmospheres.entries[0..atmospheres.count]) |entry| try std.testing.expect(entry.planet != planets[1]);
    atmospheres.release(ship);
    try std.testing.expectEqual(capacity - 1, atmospheres.count);
}

test "an atmosphere round its planet, turning in place" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var image: srtexture.Image = .{ .levels = &.{} };
    var atmospheres: Atmospheres = .{ .gpa = gpa, .image = &image };
    defer atmospheres.deinit();
    const all = mission.objects;
    const planet = try mission.addWith(model.types(), .predator, .{ 1000, 0, 0 });
    all.slots[planet].object.type = .uranus_lo;
    atmospheres.made(all, planet);
    try std.testing.expectEqual(2 * round_segments, atmospheres.entries[0].ring.mesh.positions.len);

    // Turning, the planet stays where it stands, turned about its own Y, and the ring stands round
    // it.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const before = all.slots[planet].drawn.orientation;
    try atmospheres.frame(gpa, &scene, all, .{ 0, 0, -5000 }, .{ 1, 0, 0 }, true, 0.5, 1000);
    try std.testing.expectEqual(Vector{ 1000, 0, 0 }, all.slots[planet].drawn.position);
    try std.testing.expect(!std.meta.eql(before, all.slots[planet].drawn.orientation));
    try std.testing.expectEqual(all.slots[planet].drawn.position, atmospheres.entries[0].ring.object.position);
}

test "a haze, brighter toward the sun" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var image: srtexture.Image = .{ .levels = &.{} };
    var atmospheres: Atmospheres = .{ .gpa = gpa, .image = &image };
    defer atmospheres.deinit();
    const all = mission.objects;
    const planet = try mission.addWith(model.types(), .predator, @splat(0));
    all.slots[planet].object.type = .jupiter_hi;
    all.slots[planet].model.?.parts[0].object.radius = 1000;
    atmospheres.made(all, planet);
    // The planet's terminator softened.
    for (all.slots[planet].model.?.parts) |part| try std.testing.expect(part.object.soft_terminator);

    // Seen with the sun square to the view, the ring is as solid as a haze's day on the side
    // toward the sun, and as its night on the side away, its outer circle as its inner.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const sphere = all.slots[planet].drawn.position;
    try atmospheres.frame(gpa, &scene, all, sphere + Vector{ 0, 0, -5000 }, .{ 3, 0, 0 }, true, 0, 0);
    const colours = &atmospheres.entries[0].ring.colours;
    var least: f32 = 1;
    var most: f32 = 0;
    for (colours[0..round_segments], colours[round_segments..]) |inner, outer| {
        least = @min(least, inner[3]);
        most = @max(most, inner[3]);
        try std.testing.expectEqual(inner[3], outer[3]);
    }
    try std.testing.expectApproxEqAbs(haze_day, most, 1e-3);
    try std.testing.expectApproxEqAbs(haze_night, least, 1e-3);

    // The lens flares brighter than a haze's day make it all as solid as they are bright.
    try atmospheres.frame(gpa, &scene, all, sphere + Vector{ 0, 0, -5000 }, .{ 3, 0, 0 }, true, 0.9, 0);
    for (colours[0 .. 2 * round_segments]) |colour| try std.testing.expectEqual(0.9, colour[3]);
}
