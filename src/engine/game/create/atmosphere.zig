//! The planets' atmospheres (`Create.cpp`, `planet_atmospheres`, `0x00545868`): a ring in a planet's
//! own colour round the rim of each of the planets that have one, fading out toward its edge, which
//! `create_object` makes as it makes the planet (`Atmospheres.made`) and `backdrop_frame` turns to
//! the camera each frame, as bright as the lens flares, the planet turning slowly as it goes
//! (`Atmospheres.frame`). The planets' table (`planets`) says which planets have one, and how each
//! planet turns and leans. A mod's surface function can draw a planet's atmosphere instead
//! (`Shell`).

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
const planets = @import("planets.zig");
const xtrabits = @import("../xtrabits.zig");
const Vector = math.Vector;

const log = std.log.scoped(.create);

/// The lights that don't reach a planet, which a mod's atmosphere shares (`Shell`).
const planet_light_mask = create.planet_light_mask;

/// How many atmospheres the game's table holds (`0x00545868` to `0x005458F8`).
pub const original_capacity = 4;

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
    /// lens flares are brighter. Its edges stand as shares of the edge of the planet the camera
    /// sees, at any distance (`scaleFor`). The planet's terminator is softened, the sun reaching a
    /// little way round into its night side (`srapiext.MeshObject.soft_terminator`).
    haze,
    /// As the game draws them: of `segments` quads, there only as the lens flares are, and as
    /// large as built.
    original,

    fn quads(style: Style) u16 {
        return switch (style) {
            .haze => round_segments,
            .original => segments,
        };
    }

    /// How large a ring is drawn against its build, for a planet of `radius` with the camera
    /// `distance` from its middle. A haze's is as much larger as the planet's visible edge stands
    /// out in the ring's plane (`edgeFactor`), so that the ring keeps to the edge as the camera
    /// comes near, where at the game's size it slips inside it, behind the planet. Null where the
    /// camera is inside the planet. The game draws it as built.
    pub fn scaleFor(style: Style, radius: f32, distance: f32) ?f32 {
        return switch (style) {
            .haze => edgeFactor(radius, distance),
            .original => 1,
        };
    }
};

/// How much farther than `radius` from a sphere's middle its edge looks from the camera `distance`
/// away, in the plane through its middle facing the camera: `1 / sqrt(1 - (radius / distance)^2)`.
/// Null where the camera stands within the sphere.
fn edgeFactor(radius: f32, distance: f32) ?f32 {
    if (!(distance > radius)) return null;
    return 1 / @sqrt(1 - (radius / distance) * (radius / distance));
}

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

/// How an atmosphere looks: the colour of its inner edge, which fades to nothing at the outer, and
/// where its edges stand, as shares of the planet's radius.
pub const Look = struct {
    colour: [3]f32,
    inner_edge: f32 = inner_edge,
    outer_edge: f32,

    /// The original's, by its planet's type (`0x00467A47` to `0x00467B18`): only the planets it
    /// names have one, all with the same inner edge.
    pub fn of(planet: gameobj.Type) ?Look {
        return switch (planet.base()) {
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
    /// The radius of the planet it was made for.
    radius: f32,

    /// The ring of a planet of `radius` that looks as `look` says (`create_object`,
    /// `0x0046795D`): a flat band of `quads` from the look's inner edge to its outer edge
    /// (`flatBand`), over `image`, added by the alpha of its colours; the first circle in the look's
    /// colour, the second black, all solid until the frame sets their alpha. It is never culled, and
    /// is coloured by its own.
    pub fn create(gpa: Allocator, image: *srtexture.Image, radius: f32, look: Look, quads: u16) Allocator.Error!*Ring {
        std.debug.assert(quads <= round_segments);
        const ring = try gpa.create(Ring);
        errdefer gpa.destroy(ring);
        ring.radius = radius;
        ring.mesh = try flatBand(gpa, quads, radius, look.inner_edge, look.outer_edge);
        errdefer ring.mesh.deinit(gpa);
        const mesh = &ring.mesh;
        mesh.surfaces[0].textures = .{ .{ .image = image }, .none };
        const colours = ring.colours[0 .. 2 * @as(usize, quads)];
        for (colours[0..quads], colours[quads..]) |*inner_colour, *outer_colour| {
            inner_colour.* = .{ look.colour[0], look.colour[1], look.colour[2], 1 };
            outer_colour.* = .{ 0, 0, 0, 1 };
        }
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

/// A flat band of `quads` facing along Z (`loadout.bandMesh`), `radius` from its middle, its first
/// circle drawn in to `inner` times that and its second out to `outer` times, with its faces'
/// planes, its vertex normals and its bounds worked out again for them. Its one surface is lit,
/// added by its alpha, with no texture.
fn flatBand(gpa: Allocator, quads: u16, radius: f32, inner: f32, outer: f32) Allocator.Error!srapiext.Mesh {
    var mesh = try loadout.bandMesh(gpa, quads, radius, 0);
    errdefer mesh.deinit(gpa);
    mesh.surfaces[0] = .{
        .polygons = @intCast(mesh.polygons.len),
        .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add_alpha }),
    };
    for (mesh.positions[0..quads], mesh.positions[quads..]) |*near, *far| {
        near.* *= @splat(inner);
        far.* *= @splat(outer);
    }
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// A planet's sphere as its model's first part holds it, at its most detail: the middle of its
/// bounds, which may stand off the model's origin, as Earth's does, and half the widest of their
/// spans.
pub const Sphere = struct {
    middle: Vector,
    radius: f32,

    pub fn of(mesh: *const srapiext.Mesh) Sphere {
        const low, const high = mesh.bounds;
        return .{ .middle = (low + high) * @as(Vector, @splat(0.5)), .radius = @reduce(.Max, high - low) / 2 };
    }
};

/// What finds a mod's surface function by its qualified name, for a planet whose atmosphere one
/// draws (`planets.Planet.atmosphere_surface`): the scripts' registry, which the driver hands over.
pub const SurfaceNames = struct {
    context: *anyopaque,
    find: *const fn (context: *anyopaque, name: []const u8) ?srtexture.ModSurface,
};

/// **Improvement:** a planet's atmosphere that a mod's surface function draws
/// (`planets.Planet.atmosphere_surface`), in place of the band. It is a flat ring of
/// `round_segments` quads that faces the camera through the middle of the planet's sphere, from the
/// planet's `atmosphere_inner` to its `atmosphere_outer` times the sphere's radius, each circle as
/// far out as the sphere of its radius looks from the camera (`place`). In its own frame, the
/// sphere's middle is the origin and the sphere's radius is the unit, so that the function can
/// trace the line of sight through each pixel. It has no texture, and what the function leaves is
/// added over what lies behind it. It is lit as the planets are, by the second key light alone
/// (`create.planet_light_mask`), so that the function reads the direction toward the sun. Both
/// styles draw it, since a mod asks for it.
pub const Shell = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    /// The planet's mesh its sphere is taken from (`Sphere.of`), each frame: `create_object` moves
    /// a planet's meshes onto the middle of their vertices after it makes the atmosphere.
    planet: *const srapiext.Mesh,
    /// Its inner and outer edges, in the sphere's radii.
    inner: f32,
    outer: f32,

    pub fn create(gpa: Allocator, planet: *const srapiext.Mesh, inner: f32, outer: f32, surface: srtexture.ModSurface) Allocator.Error!*Shell {
        const shell = try gpa.create(Shell);
        errdefer gpa.destroy(shell);
        // `place` sizes its circles each frame, in the same plane, so its faces keep the normals
        // that light it.
        shell.mesh = try flatBand(gpa, round_segments, 1, inner, outer);
        shell.planet = planet;
        shell.inner = inner;
        shell.outer = outer;
        shell.level = .{.{ .mesh = &shell.mesh, .until = std.math.inf(f32) }};
        shell.object = .{
            .flags = .{ .lit = true, .not_culled = true, .owns_mesh = true },
            .position = @splat(0),
            .radius = outer,
            .levels = &shell.level,
            .light_mask = planet_light_mask,
            .colour = .{ 0, 0, 0, 1 },
            .surface = surface,
        };
        return shell;
    }

    /// Places it for a frame, with the planet's model at `position`, turned by `orientation`, and
    /// the camera at `camera`: round the sphere's middle, facing the camera, scaled by the sphere's
    /// radius, each circle as far out as the edge of the sphere of its radius looks in the plane
    /// through the middle (`edgeFactor`). False where the camera stands within its outer edge,
    /// which it can't be drawn round.
    pub fn place(shell: *Shell, position: Vector, orientation: math.Matrix, camera: Vector) bool {
        const sphere: Sphere = .of(shell.planet);
        const middle = position + math.transform(orientation, sphere.middle);
        const distance = math.length(camera - middle) / sphere.radius;
        const inner = shell.inner * (edgeFactor(shell.inner, distance) orelse return false);
        const outer = shell.outer * (edgeFactor(shell.outer, distance) orelse return false);
        const quads = shell.mesh.positions.len / 2;
        for (shell.mesh.positions[0..quads], shell.mesh.positions[quads..]) |*near, *far| {
            const around = math.normalize(far.*);
            near.* = around * @as(Vector, @splat(inner));
            far.* = around * @as(Vector, @splat(outer));
        }
        shell.object.position = middle;
        shell.object.orientation = math.lookAt(camera - middle);
        shell.object.scale = sphere.radius;
        shell.object.radius = outer;
        return true;
    }

    pub fn destroy(shell: *Shell, gpa: Allocator) void {
        shell.mesh.deinit(gpa);
        gpa.destroy(shell);
    }
};

/// The atmospheres of the mission's planets, how the planets turn and lean, and the texture the
/// atmospheres are drawn over.
pub const Atmospheres = struct {
    gpa: Allocator,
    image: *srtexture.Image,
    /// How they are drawn.
    style: Style = .haze,
    /// What finds the surface functions the planets name for their atmospheres, where mods run.
    surfaces: ?SurfaceNames = null,
    entries: [planets.most]Entry = undefined,
    count: usize = 0,
    /// The frame the planets last turned at (`0x00595BC0`).
    turned_at: i32 = 0,

    /// A planet that turns, leans or has an atmosphere. Like the game's entries, it holds the
    /// atmosphere's ring (`+0x00`), how far the planet turns about its own Y each tick (`+0x04`,
    /// `planets.Planet.turnPerTick`) and the planet's slot (`+0x20`). OpenReliant adds how the
    /// planet's axis leans in its own frame (`planets.Planet.lean`) and how far it has turned. The
    /// game's entries also keep where the planet stood when it was made (`+0x14`), which nothing
    /// reads.
    pub const Entry = struct {
        ring: ?*Ring,
        /// The atmosphere a mod's surface function draws, in place of the ring (`Shell`).
        shell: ?*Shell = null,
        turn: f32,
        lean: math.Matrix = math.identity,
        turned: f32 = 0,
        planet: u16,

        /// Lets go of its atmosphere, ring or shell.
        fn destroy(entry: Entry, gpa: Allocator) void {
            if (entry.ring) |ring| ring.destroy(gpa);
            if (entry.shell) |shell| shell.destroy(gpa);
        }
    };

    /// As `objects_reset` (`0x00466630`) loads `atmos`, with no atmospheres.
    pub fn init(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!Atmospheres {
        return .{ .gpa = gpa, .image = try matmanager.textureRequire(textures, texture_name) };
    }

    /// As a mission ends (`0x004666B0`), and as the next starts (`objects_reset`): every
    /// atmosphere let go.
    pub fn reset(atmospheres: *Atmospheres) void {
        for (atmospheres.entries[0..atmospheres.count]) |entry| entry.destroy(atmospheres.gpa);
        atmospheres.count = 0;
    }

    pub fn deinit(atmospheres: *Atmospheres) void {
        atmospheres.reset();
    }

    /// The part of `create_object` for a planet, run once the object in slot `index` is made. A
    /// planet that turns, leans or has an atmosphere (`planets.of`) gets an entry, and its
    /// atmosphere's ring, as wide as its model's first part, or the shell a mod's surface function
    /// draws it on (`Shell`) where the planet names one that a mod registered. With the haze style,
    /// the planet's terminator is softened where it has a ring.
    ///
    /// **Fix:** the game assumes at most `original_capacity` atmospheres, and a fifth would write
    /// past the end of its table. **Improvement:** OpenReliant's table holds up to `planets.most`
    /// planets, as many as the planets' table can list, so that the planets a mod adds turn and
    /// keep their atmospheres. Past that it logs a warning and makes no more. A planet whose ring
    /// can't be made still turns.
    pub fn made(atmospheres: *Atmospheres, all: *create.Objects, index: u16) void {
        const slot = &all.slots[index];
        const planet = planets.of(slot.object.type) orelse return;
        const look = planet.look();
        const surface = atmospheres.surfaceOf(planet, index);
        if (look == null and surface == null and planet.spin == 0 and planet.tilt == 0) return;
        const model = if (slot.model) |*held| held else return;
        if (model.parts.len == 0) return;
        if (atmospheres.count == atmospheres.entries.len) {
            log.warn("planet {d} doesn't turn and has no atmosphere: the table already holds {d} planets", .{ index, atmospheres.entries.len });
            return;
        }
        const levels = model.parts[0].object.levels;
        const shell: ?*Shell = shell: {
            const function = surface orelse break :shell null;
            if (levels.len == 0) break :shell null;
            break :shell Shell.create(atmospheres.gpa, levels[0].mesh, planet.atmosphere_inner, planet.atmosphere_outer, function) catch |err| {
                log.warn("planet {d} has no atmosphere of its mod's: {s}", .{ index, @errorName(err) });
                break :shell null;
            };
        };
        const ring: ?*Ring = ring: {
            if (shell != null) break :ring null;
            const each = look orelse break :ring null;
            break :ring Ring.create(atmospheres.gpa, atmospheres.image, model.parts[0].object.radius, each, atmospheres.style.quads()) catch |err| {
                log.warn("planet {d} has no atmosphere: {s}", .{ index, @errorName(err) });
                break :ring null;
            };
        };
        atmospheres.entries[atmospheres.count] = .{ .ring = ring, .shell = shell, .turn = planet.turnPerTick(), .lean = planet.lean(), .planet = index };
        atmospheres.count += 1;
        if (ring != null and atmospheres.style == .haze) {
            for (model.parts) |*each| each.object.soft_terminator = true;
        }
    }

    /// The surface function that draws `planet`'s atmosphere, reading the planet's parameters,
    /// where it names one that a mod registered. A name no mod registered is logged.
    fn surfaceOf(atmospheres: *const Atmospheres, planet: *const planets.Planet, index: u16) ?srtexture.ModSurface {
        const name = planet.atmosphere_surface orelse return null;
        const names = atmospheres.surfaces orelse return null;
        var surface = names.find(names.context, name) orelse {
            log.warn("planet {d}'s atmosphere names the surface function {s}, which no mod registers", .{ index, name });
            return null;
        };
        surface.parameters = planet.atmosphere_parameters;
        return surface;
    }

    /// The last step of `backdrop_frame` (`0x004A5CD0`), at frame `now`. Each planet turns about
    /// its own Y by its turn for every tick since the last frame, and its model is placed to match
    /// at once. For each planet that isn't disabled, its atmosphere's ring is moved to the planet,
    /// turned to face the camera at `camera`, sized for the camera's distance (`Style.scaleFor`),
    /// faded (`Ring.fade`) by the lens flares' `brightness` (`backdrop.flareBrightness`) and the sun
    /// along `sun`, and added to the background layer; a mod's shell is placed for the camera
    /// (`Shell.place`) and added there. The original's software renderer draws no atmosphere. A
    /// planet's parts sit at its origin (`create.planetMade`), so it turns in place, and the ring
    /// stays round it.
    ///
    /// **Improvement:** the game turns the drawn planet a little further each frame. OpenReliant
    /// keeps the total angle instead, and each frame turns the planet from its orientation in the
    /// mission, leaned as the planets' table says, by that angle, so that its axis keeps its
    /// lean.
    pub fn frame(atmospheres: *Atmospheres, gpa: Allocator, scene: *srcore.Scene, all: *create.Objects, camera: Vector, sun: Vector, brightness: f32, now: i32) Allocator.Error!void {
        const ticks: f32 = @floatFromInt(now - atmospheres.turned_at);
        defer atmospheres.turned_at = now;
        const toward = math.normalize(sun);
        for (atmospheres.entries[0..atmospheres.count]) |*entry| {
            const planet = &all.slots[entry.planet];
            entry.turned = @mod(entry.turned + ticks * entry.turn, std.math.tau);
            planet.drawn.orientation = math.turned(math.product(planet.object.root.orientation, entry.lean), .y, entry.turned);
            if (planet.model) |*model| model.place(planet.drawn.position, planet.drawn.orientation);
            if (planet.object.flags.disabled) continue;
            if (entry.shell) |shell| {
                if (shell.place(planet.drawn.position, planet.drawn.orientation, camera)) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &shell.object }, .background);
                continue;
            }
            const ring = entry.ring orelse continue;
            const object = &ring.object;
            object.position = planet.drawn.position;
            object.orientation = math.lookAt(camera - object.position);
            object.scale = atmospheres.style.scaleFor(ring.radius, math.length(camera - object.position)) orelse continue;
            ring.fade(atmospheres.style, brightness, toward);
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = object }, .background);
        }
    }

    /// Lets go of the atmosphere of the planet in slot `index`, as `DestroyFlightGroup` retires it
    /// (`cmd_DestroyFlightGroup`, `0x00457FD0`).
    ///
    /// **Fix:** for any planet of the types `0x60` to `0x69` and `0xCA` to `0xD3`, the game counts
    /// one atmosphere fewer whether the planet has one or not, which leaves out both Neptunes. It
    /// looks for the planet's atmosphere only among the atmospheres before the last, and frees the
    /// one it finds but keeps it in the table, which goes on drawing it. OpenReliant frees the
    /// planet's own atmosphere and removes its entry, so the planet also stops turning.
    pub fn release(atmospheres: *Atmospheres, index: u16) void {
        for (atmospheres.entries[0..atmospheres.count], 0..) |entry, at| {
            if (entry.planet != index) continue;
            entry.destroy(atmospheres.gpa);
            @memmove(atmospheres.entries[at .. atmospheres.count - 1], atmospheres.entries[at + 1 .. atmospheres.count]);
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
    try std.testing.expectEqual(0.95, Look.of(.of(.neptune_lo)).?.outer_edge);
    try std.testing.expectEqual([3]f32{ 0.15, 0.2, 0.2 }, Look.of(.of(.uranus_hi)).?.colour);
    try std.testing.expectEqual(1.005, Look.of(.of(.venus_hi)).?.outer_edge);
    try std.testing.expectEqual(null, Look.of(.of(.predator)));
}

test Ring {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = .{ .levels = &.{} };
    const ring = try Ring.create(gpa, &image, 1000, Look.of(.of(.jupiter_hi)).?, segments);
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
    const ring = try Ring.create(gpa, &image, 1000, Look.of(.of(.neptune_hi)).?, round_segments);
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
    // Five Neptunes, one more than the game's table holds, and Saturn, which neither turns nor has
    // an atmosphere.
    var neptunes: [original_capacity + 1]u16 = undefined;
    for (&neptunes, 0..) |*planet, n| {
        planet.* = try mission.addWith(model.types(), .of(.predator), .{ @floatFromInt(n * 100000), 0, 0 });
        all.slots[planet.*].object.type = .of(.neptune_hi);
    }
    const saturn = try mission.addWith(model.types(), .of(.predator), .{ 0, 100000, 0 });
    all.slots[saturn].object.type = .of(.saturn_hi);
    const ship = try mission.addWith(model.types(), .of(.predator), @splat(0));

    // Each Neptune gets its atmosphere, the fifth too, and Saturn and the ship get nothing.
    atmospheres.made(all, ship);
    atmospheres.made(all, saturn);
    for (neptunes) |planet| atmospheres.made(all, planet);
    try std.testing.expectEqual(neptunes.len, atmospheres.count);
    try std.testing.expectEqual(neptunes[0], atmospheres.entries[0].planet);

    // A frame 100 ticks on turns each planet by 100 of its turn, and puts its atmosphere where it
    // stands, facing the camera, as solid as the flares.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const before = all.slots[neptunes[0]].drawn.orientation;
    try atmospheres.frame(gpa, &scene, all, .{ 0, 0, -5000 }, .{ 1, 0, 0 }, 0.5, 100);
    const turned = math.turned(before, .y, 100 * planets.original_turn);
    try math.testing.expectMatrixWithin(turned, all.slots[neptunes[0]].drawn.orientation, 1e-5);
    try std.testing.expectEqual(neptunes.len, scene.layers.get(.background).items.len);
    const ring = atmospheres.entries[0].ring.?;
    try std.testing.expectEqual(all.slots[neptunes[0]].drawn.position, ring.object.position);
    try std.testing.expect(math.dot(math.forward(ring.object.orientation), math.normalize(@as(Vector, .{ 0, 0, -5000 }) - ring.object.position)) > 0.9999);
    for (ring.colours[0 .. 2 * segments]) |colour| try std.testing.expectEqual(0.5, colour[3]);
    // As the game draws them, the planet's terminator stays hard.
    for (all.slots[neptunes[0]].model.?.parts) |part| try std.testing.expect(!part.object.soft_terminator);

    // A disabled planet's isn't drawn; it turns all the same.
    scene.clear();
    all.slots[neptunes[1]].object.flags.disabled = true;
    try atmospheres.frame(gpa, &scene, all, @splat(0), .{ 1, 0, 0 }, 0.5, 110);
    try std.testing.expectEqual(neptunes.len - 1, scene.layers.get(.background).items.len);

    // Destroyed, a planet's own atmosphere goes; the others stay.
    atmospheres.release(neptunes[1]);
    try std.testing.expectEqual(neptunes.len - 1, atmospheres.count);
    for (atmospheres.entries[0..atmospheres.count]) |entry| try std.testing.expect(entry.planet != neptunes[1]);
    atmospheres.release(ship);
    try std.testing.expectEqual(neptunes.len - 1, atmospheres.count);
}

test "a planet from the table turns and leans as it says, with no atmosphere" {
    defer planets.installOriginal();
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
    // Earth, added to the table: a turn eastward every 100 seconds, its pole leaning toward its
    // front.
    const earth_spin = std.math.tau / 100.0;
    const table = planets.original ++ [_]planets.Planet{.{ .type = .of(.earth), .spin = earth_spin, .tilt = 0.4 }};
    planets.install(&table);
    const earth = try mission.addWith(model.types(), .of(.predator), @splat(0));
    all.slots[earth].object.type = .of(.earth);
    atmospheres.made(all, earth);
    try std.testing.expectEqual(1, atmospheres.count);
    try std.testing.expectEqual(null, atmospheres.entries[0].ring);

    // A quarter of its day later, it has turned a quarter turn eastward about its leaning pole, and
    // nothing is added to the background layer.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try atmospheres.frame(gpa, &scene, all, .{ 0, 0, -5000 }, .{ 1, 0, 0 }, 0.5, 25 * @import("../main.zig").ticks_per_second);
    try std.testing.expectEqual(0, scene.layers.get(.background).items.len);
    const orientation = all.slots[earth].drawn.orientation;
    const pole: [3]f32 = math.transform(orientation, .{ 0, -1, 0 });
    const leaned: [3]f32 = math.transform(table[table.len - 1].lean(), .{ 0, -1, 0 });
    for (leaned, pole) |want, got| try std.testing.expectApproxEqAbs(want, got, 1e-5);
    // Seen from above its north pole, its front has moved a quarter turn to the left, since an
    // eastward turn is counter-clockwise from there.
    const front = math.transform(orientation, .{ 0, 0, 1 });
    const lean = table[table.len - 1].lean();
    const unleaned = math.transform(math.transpose(lean), front);
    try std.testing.expectApproxEqAbs(-1, unleaned[0], 1e-4);
    try std.testing.expectApproxEqAbs(0, unleaned[2], 1e-4);
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
    const planet = try mission.addWith(model.types(), .of(.predator), .{ 1000, 0, 0 });
    all.slots[planet].object.type = .of(.uranus_lo);
    atmospheres.made(all, planet);
    try std.testing.expectEqual(2 * round_segments, atmospheres.entries[0].ring.?.mesh.positions.len);

    // Turning, the planet stays where it stands, turned about its own Y, and the ring stands round
    // it.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const before = all.slots[planet].drawn.orientation;
    try atmospheres.frame(gpa, &scene, all, .{ 0, 0, -5000 }, .{ 1, 0, 0 }, 0.5, 1000);
    try std.testing.expectEqual(Vector{ 1000, 0, 0 }, all.slots[planet].drawn.position);
    try std.testing.expect(!std.meta.eql(before, all.slots[planet].drawn.orientation));
    try std.testing.expectEqual(all.slots[planet].drawn.position, atmospheres.entries[0].ring.?.object.position);
}

test Sphere {
    // Earth's model holds its sphere off its origin.
    var mesh: srapiext.Mesh = undefined;
    mesh.bounds = .{ .{ -300, -1000, -2000 }, .{ 1700, 1000, 0 } };
    const sphere: Sphere = .of(&mesh);
    try std.testing.expectEqual(Vector{ 700, 0, -1000 }, sphere.middle);
    try std.testing.expectEqual(1000, sphere.radius);
}

test "a mod's surface function draws a planet's atmosphere" {
    defer planets.installOriginal();
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
    // The scripts know one function, `test:air`.
    const names = struct {
        fn find(_: *anyopaque, name: []const u8) ?srtexture.ModSurface {
            return if (std.mem.eql(u8, name, "test:air")) .{ .function = 7 } else null;
        }
    };
    var context: u8 = 0;
    atmospheres.surfaces = .{ .context = &context, .find = names.find };
    // Earth, its sphere off its model's origin, with a colour as well, and Venus, which names a
    // function no mod registers.
    model.mesh.bounds = .{ .{ -300, -1000, -2000 }, .{ 1700, 1000, 0 } };
    const table = [_]planets.Planet{
        .{ .type = .of(.earth), .atmosphere_colour = .{ 1, 1, 1 }, .atmosphere_inner = 0.9, .atmosphere_outer = 1.1, .atmosphere_surface = "test:air", .atmosphere_parameters = .{ 1, 2, 3, 4 } },
        .{ .type = .of(.venus_hi), .atmosphere_colour = .{ 1, 1, 1 }, .atmosphere_surface = "test:nothing" },
    };
    planets.install(&table);
    const earth = try mission.addWith(model.types(), .of(.predator), @splat(0));
    all.slots[earth].object.type = .of(.earth);
    const venus = try mission.addWith(model.types(), .of(.predator), .{ 0, 0, 1e7 });
    all.slots[venus].object.type = .of(.venus_hi);
    atmospheres.made(all, earth);
    atmospheres.made(all, venus);

    // Earth's is a shell the function draws, reading Earth's numbers, and no band.
    const shell = atmospheres.entries[0].shell.?;
    try std.testing.expectEqual(null, atmospheres.entries[0].ring);
    try std.testing.expectEqual(7, shell.object.surface.?.function);
    try std.testing.expectEqual([4]f32{ 1, 2, 3, 4 }, shell.object.surface.?.parameters);
    // It is lit as the planets are, its faces facing along its Z, so that the function reads the
    // direction toward the sun.
    try std.testing.expect(shell.object.flags.lit);
    try std.testing.expectEqual(create.planet_light_mask, shell.object.light_mask);
    for (shell.mesh.normals) |normal| try std.testing.expectApproxEqAbs(1, @abs(normal[2]), 1e-5);
    // Venus's function isn't there, so it has its band.
    try std.testing.expectEqual(null, atmospheres.entries[1].shell);
    try std.testing.expect(atmospheres.entries[1].ring != null);

    // From five radii off, the shell stands round the sphere's middle, facing the camera, a radius
    // to a unit, each circle as far out as the sphere of its radius looks.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const middle: Vector = .{ 700, 0, -1000 };
    try atmospheres.frame(gpa, &scene, all, middle + Vector{ 0, 0, -5000 }, .{ 1, 0, 0 }, 0, 0);
    try std.testing.expectEqual(2, scene.layers.get(.background).items.len);
    try std.testing.expectEqual(middle, shell.object.position);
    try std.testing.expectEqual(1000, shell.object.scale);
    try std.testing.expect(math.dot(math.forward(shell.object.orientation), Vector{ 0, 0, -1 }) > 0.9999);
    const seen = struct {
        fn edge(radius: f32, distance: f32) f32 {
            return radius / @sqrt(1 - (radius / distance) * (radius / distance));
        }
    }.edge;
    try std.testing.expectApproxEqAbs(seen(0.9, 5), math.length(shell.mesh.positions[0]), 1e-5);
    try std.testing.expectApproxEqAbs(seen(1.1, 5), math.length(shell.mesh.positions[round_segments]), 1e-5);

    // With the camera within its outer edge, it isn't drawn.
    scene.clear();
    try atmospheres.frame(gpa, &scene, all, middle + Vector{ 0, 0, -1050 }, .{ 1, 0, 0 }, 0, 0);
    try std.testing.expectEqual(1, scene.layers.get(.background).items.len);

    // Destroyed, the planet's shell goes.
    atmospheres.release(earth);
    try std.testing.expectEqual(1, atmospheres.count);
}

test "Style.scaleFor" {
    // A haze's ring keeps to the planet's visible edge: from twice the radius away, the edge stands
    // 1 / sqrt(3/4) of the radius out in the ring's plane; far off, at the radius.
    try std.testing.expectApproxEqAbs(1 / @sqrt(@as(f32, 0.75)), Style.haze.scaleFor(1000, 2000).?, 1e-6);
    try std.testing.expectApproxEqAbs(1, Style.haze.scaleFor(1000, 1e7).?, 1e-6);
    try std.testing.expectEqual(null, Style.haze.scaleFor(1000, 900));
    // As the game draws them, as built.
    try std.testing.expectEqual(1, Style.original.scaleFor(1000, 2000).?);
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
    const planet = try mission.addWith(model.types(), .of(.predator), @splat(0));
    all.slots[planet].object.type = .of(.jupiter_hi);
    all.slots[planet].model.?.parts[0].object.radius = 1000;
    atmospheres.made(all, planet);
    // The planet's terminator softened.
    for (all.slots[planet].model.?.parts) |part| try std.testing.expect(part.object.soft_terminator);

    // Seen with the sun square to the view, the ring is as solid as a haze's day on the side
    // toward the sun, and as its night on the side away, its outer circle as its inner.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const sphere = all.slots[planet].drawn.position;
    try atmospheres.frame(gpa, &scene, all, sphere + Vector{ 0, 0, -5000 }, .{ 3, 0, 0 }, 0, 0);
    const colours = &atmospheres.entries[0].ring.?.colours;
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
    try atmospheres.frame(gpa, &scene, all, sphere + Vector{ 0, 0, -5000 }, .{ 3, 0, 0 }, 0.9, 0);
    for (colours[0 .. 2 * round_segments]) |colour| try std.testing.expectEqual(0.9, colour[3]);
}
