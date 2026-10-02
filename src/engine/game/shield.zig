//! `C:\lancer\game\shield.cpp`: a ship's shields as they are seen, a bubble round the ship that
//! ripples out from where a shot or a knock struck them. **Unverified:** the bubble's meshes and
//! colours (`0x0049E370` to `0x0049EF60`) lie before this file's path, after the 3D sounds' code.
//!
//! A ship that lists components has no bubble: the part struck glows round the hit instead, and
//! its force fields glow whole (`Capital`, `0x0049F4A0` to `0x0049FCD0`).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const libcmt = @import("../libcmt.zig");
const Objects = @import("create.zig").Objects;
const Detail = @import("explode.zig").Detail;
const cloak = @import("cloak.zig");
const ease = @import("../genilib/interf/ease.zig");
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const objects = @import("objects.zig");
const sparks = @import("sparks.zig");
const xtrabits = @import("xtrabits.zig");

/// A sphere's grid: its slices round the axis through its poles, and its bands from pole to pole.
pub const Grid = struct {
    around: u16,
    down: u16,

    pub fn vertices(grid: Grid) usize {
        return (@as(usize, grid.down) - 1) * grid.around + 2;
    }

    /// How many triangles the grid's first `bands` bands hold: `around` in a fan round a pole, and
    /// twice that in a band between.
    pub fn triangles(grid: Grid, bands: usize) usize {
        const fans = @as(usize, @intFromBool(bands > 0)) + @intFromBool(bands == grid.down);
        return (bands * 2 - fans) * grid.around;
    }

    /// Vertex `index` of a sphere of a unit radius on the grid: the pole on +Z first, then each
    /// band's ring in turn, then the pole on -Z (`0x0049E3D0`).
    fn vertex(grid: Grid, index: usize) Vector {
        if (index == 0) return .{ 0, 0, 1 };
        if (index == grid.vertices() - 1) return .{ 0, 0, -1 };
        const band: f32 = @floatFromInt(1 + (index - 1) / grid.around);
        const slice: f32 = @floatFromInt((index - 1) % grid.around);
        const down = band * std.math.pi / @as(f32, @floatFromInt(grid.down));
        const round = slice * 2 * std.math.pi / @as(f32, @floatFromInt(grid.around));
        return .{ @sin(round) * @sin(down), @cos(round) * @sin(down), @cos(down) };
    }

    /// Vertex `slice` of the ring round band `band`, from 1.
    pub fn ring(grid: Grid, band: usize, slice: usize) u16 {
        return @intCast(1 + (band - 1) * grid.around + slice % grid.around);
    }

    /// `values`, one for each vertex of `coarse`, a grid over the same sphere, at vertex `index` of
    /// this grid: the four of `coarse`'s round it, each by how near it stands, as it lies between
    /// their bands and slices, a pole's the same for every slice. On `coarse` itself, a vertex
    /// takes its own.
    pub fn sample(grid: Grid, coarse: Grid, values: []const [4]f32, index: usize) [4]f32 {
        const band, const slice = grid.placeOn(coarse, index);
        const top: usize = @intFromFloat(@floor(band));
        const left: usize = @intFromFloat(@floor(slice));
        const down = band - @floor(band);
        const across = slice - @floor(slice);
        const upper = math.lerp(coarse.valueAt(values, top, left), coarse.valueAt(values, top, left + 1), across);
        const lower = math.lerp(coarse.valueAt(values, top + 1, left), coarse.valueAt(values, top + 1, left + 1), across);
        return math.lerp(upper, lower, down);
    }

    /// Where vertex `index` stands on `coarse`: its band from the pole on +Z and its slice, in
    /// `coarse`'s, the poles at slice 0.
    fn placeOn(grid: Grid, coarse: Grid, index: usize) [2]f32 {
        if (index == 0) return .{ 0, 0 };
        if (index == grid.vertices() - 1) return .{ @floatFromInt(coarse.down), 0 };
        const band = 1 + (index - 1) / grid.around;
        const slice = (index - 1) % grid.around;
        return .{
            @as(f32, @floatFromInt(band * coarse.down)) / @as(f32, @floatFromInt(grid.down)),
            @as(f32, @floatFromInt(slice * coarse.around)) / @as(f32, @floatFromInt(grid.around)),
        };
    }

    /// `values`' value at band `band` from the pole on +Z and slice `slice`, the poles holding one
    /// for every slice.
    fn valueAt(grid: Grid, values: []const [4]f32, band: usize, slice: usize) @Vector(4, f32) {
        if (band == 0) return values[0];
        if (band >= grid.down) return values[grid.vertices() - 1];
        return values[grid.ring(band, slice)];
    }

    /// The triangles of the grid's first `bands` bands, three corners each, band by band as
    /// `0x0049E3D0` lays them: a fan round each pole, and two triangles to each slice of each band
    /// between.
    pub fn corners(grid: Grid, bands: usize, out: []u16) void {
        const last: u16 = @intCast(grid.vertices() - 1);
        var at: usize = 0;
        for (0..bands) |band| {
            for (0..grid.around) |slice| {
                const triangle: [3]u16 = if (band == 0)
                    .{ 0, grid.ring(1, slice + 1), grid.ring(1, slice) }
                else if (band == grid.down - 1)
                    .{ grid.ring(band, grid.around - 1 - slice), grid.ring(band, 2 * grid.around - 2 - slice), last }
                else
                    .{ grid.ring(band, slice), grid.ring(band, slice + 1), grid.ring(band + 1, slice) };
                @memcpy(out[at..][0..3], &triangle);
                at += 3;
            }
            if (band == 0 or band == grid.down - 1) continue;
            for (0..grid.around) |slice| {
                const triangle: [3]u16 = .{ grid.ring(band, slice + 1), grid.ring(band + 1, slice + 1), grid.ring(band + 1, slice) };
                @memcpy(out[at..][0..3], &triangle);
                at += 3;
            }
        }
        assert(at == out.len);
    }
};

/// The bubble's levels of detail, finest first (`0x00593730`), and each one's grid (`0x0050884C`).
pub const level_count = 6;
const grids = [level_count]Grid{
    .{ .around = 16, .down = 14 },
    .{ .around = 12, .down = 10 },
    .{ .around = 10, .down = 8 },
    .{ .around = 8, .down = 6 },
    .{ .around = 6, .down = 4 },
    .{ .around = 4, .down = 4 },
};

/// The vertices of the game's finest level, which a bubble keeps its strengths, colours and texture
/// coordinates for in the original style.
const max_vertices = grids[0].vertices();

comptime {
    for (grids[1..]) |grid| assert(grid.vertices() <= max_vertices);
}

/// How a bubble is drawn: as the game draws it, or smooth.
///
/// **Improvement:** in the smooth style a bubble keeps each hit as where it struck and when, and
/// works each drawn vertex's strength out from them, fading by the share of a tick the frame is at
/// rather than a tick at a time, on whichever level it is drawn at; the game keeps a strength for
/// each vertex of the level it was struck at, which a bubble drawn at another level reads for
/// other vertices. Each level's texture coordinates are its own vertices'; the game's lower levels
/// read the finest level's for other vertices. The texture swirls about its centre, where the
/// game leaves the centre off the coordinates it turns, so the texture wanders further each time
/// it is drawn, the more often the higher the frame rate. And within `fine_reach` of the finest
/// level's reach it is drawn on a finer sphere (`fine_grid`), so the ripple is a smooth ring rather
/// than a band of the finest level's broad triangles.
pub const Style = enum { original, smooth };

/// The smooth style's finer sphere, the level `fine_level`, and the share of the finest level's
/// reach it is drawn out to.
const fine_grid: Grid = .{ .around = 48, .down = 40 };
const fine_level = level_count;
const fine_reach: f32 = 0.5;

/// Every level a bubble may be drawn at: the game's, then the finer one.
const all_grids = grids ++ [1]Grid{fine_grid};

/// The grid of the game's finest sphere, which a bubble's colours are laid out on.
pub const game_grid = grids[0];

/// A sphere a bubble is drawn on, and its grid.
pub const Sphere = struct {
    mesh: *const srapiext.Mesh,
    grid: Grid,
};

/// How many hits a bubble keeps in the smooth style: more than a ripple lasts at any rate of fire,
/// so none ends early.
const recent_hits = 16;

/// How far from the camera each level of detail is drawn out to, by the options' detail
/// (`0x0050887C`, into `0x00593734`). A struck bubble further off than the last isn't drawn.
const reaches: std.EnumArray(Detail, [level_count]f32) = .init(.{
    .low = .{ 1250, 2500, 5000, 10000, 20000, 40000 },
    .medium = .{ 2500, 5000, 10000, 20000, 40000, 80000 },
    .high = .{ 10000, 20000, 40000, 80000, 160000, 320000 },
});

/// The bubble's look: coloured by its vertices, over the shield's texture with its own texture
/// coordinates, adding to what is behind it.
const bubble_material: srapiext.Material = .onePass(.{ .coordinates = .generated, .lit = true, .blend = .add });

/// Which colours a bubble glows in: the ship type's side, friendly or not (`+0x40`).
pub const Tint = enum { friendly, other };

/// The steps of each tint's ramp (`0x0058CB6C` for a friendly ship's, `0x00590728` for the
/// others'), a colour for each strength from nothing up to one.
const ramp_steps = 1024;
const Colour = @Vector(3, f32);
const Ramp = [ramp_steps]Colour;

/// How bright a step of the ramp is at most (`0x0049EB00`), and what share of that the others'
/// green and blue get (`0x0049EC30`).
const ramp_brightness: f32 = 0.07;
const other_share: f32 = 0.8;

/// The strengths a ramp turns at (`0x0049EB00`): brightest at `ramp_peak` (`0x004DC4B4`), dimmed
/// by `ramp_dim` (`0x004DC4DC`), and out at `ramp_out` (`0x004DC838`). At its peak a friendly
/// ship's is `ramp_green` green and full blue, and dimmed `ramp_dim_blue` blue.
const ramp_peak: f32 = 0.6;
const ramp_dim: f32 = 0.4;
const ramp_out: f32 = 0.35;
const ramp_green: f32 = 0.7;
const ramp_dim_blue: f32 = 0.3;

/// The spans of strength a ramp eases over: from full strength down to the peak, from the peak
/// down to the dimming, and from the peak down to nothing.
///
/// **Improvement:** OpenReliant divides by the spans, where the game multiplies by their
/// reciprocals, rounded (`0x004DC9D8`, `0x004DC9D4`, `0x004DC9D0`).
const ramp_rise: f32 = 0.4;
const ramp_fall: f32 = 0.2;
const ramp_fade: f32 = 0.6;

/// `0x0049EB00` and `0x0049EC30`: a ramp's colour at `strength`, as red, green and blue. A friendly
/// ship's runs from nothing at 1 up to a cyan of 0.7 green and full blue at 0.6, down through a dim
/// blue at 0.4 to nothing below 0.35; without a hardware renderer it is grey. The others' swaps the
/// green and blue, at 0.8 of the strength.
fn rampColour(tint: Tint, strength: f32, hardware: bool) Colour {
    var colour: Colour = @splat(0);
    if (strength > ramp_peak) {
        const share = (1 - strength) / ramp_rise;
        colour = .{ 0, ease.cosine(0, ramp_green, share), ease.cosine(0, 1, share) };
    } else if (strength > ramp_dim) {
        const share = (ramp_peak - strength) / ramp_fall;
        colour = .{ 0, ease.cosine(ramp_green, 0, share), ease.cosine(1, ramp_dim_blue, share) };
    } else if (strength > ramp_out) {
        colour = .{ 0, 0, ease.cosine(ramp_dim_blue, 0, (ramp_peak - strength) / ramp_fade) };
    }
    const tinted: Colour = switch (tint) {
        .friendly => if (hardware) colour else @splat(colour[2]),
        .other => .{ 0, colour[2] * other_share, colour[1] * other_share },
    };
    return tinted * @as(Colour, @splat(ramp_brightness));
}

/// `0x0049EE40`: a tint's ramp, a step for each 1024th of the strength.
fn buildRamp(tint: Tint, hardware: bool) Ramp {
    var ramp: Ramp = undefined;
    for (&ramp, 0..) |*step, index| step.* = rampColour(tint, @as(f32, @floatFromInt(index)) / ramp_steps, hardware);
    return ramp;
}

/// `0x0049ED60` and `0x0049EDD0`: the ramp's colour at a strength strictly between nothing and
/// one; nothing outside.
fn rampAt(ramp: *const Ramp, strength: f32) Colour {
    if (!(strength > 0 and strength < 1)) return @splat(0);
    const step: usize = @intFromFloat(@floor(strength * (ramp_steps - 1)));
    return ramp[step];
}

/// A bubble's size over its ship's radius (`0x004DC7C4`).
const bubble_scale: f32 = 1.1;

/// How many hits a bubble or a capital shield keeps, the next taking the place of the oldest.
const hit_slots = 8;
const HitSlot = std.math.IntFittingRange(0, hit_slots - 1);

/// What a hit leaves at a vertex: half at the point struck, one more for each 1.2 radians off it,
/// out to `hit_reach` (`0x004DC9E0`) and no more than `max_strength` (`0x004DC480`). A vertex
/// shows only while its strength is below one, so the colour ripples out from the point struck as
/// the strengths fade by `fade_per_tick` (`0x004DC53C`).
const struck_strength: f32 = 0.5;
const strength_spread: f32 = 1.2;
const hit_reach: f32 = 1.4;
const max_strength: f32 = 2;
const fade_per_tick: f32 = 0.025;

/// What a hit leaves at a vertex `angle` radians round from the point struck, or null past
/// `hit_reach`.
fn strengthAt(angle: f32) ?f32 {
    if (!(angle <= hit_reach)) return null;
    return @min(struck_strength + angle / strength_spread, max_strength);
}

/// The angle between two directions. The game's is not a number where rounding puts the cosine
/// past one; OpenReliant holds it to one.
fn angleBetween(a: Vector, b: Vector) f32 {
    return std.math.acos(std.math.clamp(math.dot(a, b) / (math.length(a) * math.length(b)), -1, 1));
}

/// A vertex's hits faded by `ticks`, none below nothing, and the sum of what they show in `ramp`.
fn fadeHits(hits: *[hit_slots]f32, ramp: *const Ramp, ticks: f32) Colour {
    var sum: Colour = @splat(0);
    for (hits) |*strength| {
        strength.* = @max(strength.* - ticks * fade_per_tick, 0);
        sum += rampAt(ramp, strength.*);
    }
    return sum;
}

/// A vertex's colour from the sum of what its hits show, each channel held to one.
fn vertexColour(sum: Colour) [4]f32 {
    const held = @min(sum, @as(Colour, @splat(1)));
    return .{ held[0], held[1], held[2], 0 };
}

/// How long after its last hit a bubble is drawn (`0x004DC440`).
const shown_for = 100;

/// Where a bubble's texture starts swirling about, how fast it swirls, over the square of how far
/// a vertex's coordinates are from there (`0x004DC9CC`), and how fast that point turns about the
/// texture's corner (`0x004DC688`), each a tick.
const start_centre: [2]f32 = .{ 0.3, 0.3 };
const swirl_per_tick: f32 = 1e-5;
const centre_turn_per_tick: f32 = 1e-4;

/// How long a bubble flickers as a force field (`shockwaves_update`), and how often a frame of it
/// is lit: one in this many.
const flicker_for = 100;
const flicker_odds = 4;

/// The bubbles' meshes, colours and textures (`0x0049EF10`), which every bubble shares.
pub const Shields = struct {
    /// The game's levels, then the smooth style's finer one (`fine_level`).
    meshes: [all_grids.len]srapiext.Mesh,
    /// Each mesh as a single level of detail, which the bubbles drawn point at.
    levels: [all_grids.len][1]srapiext.Level = undefined,
    style: Style,
    ramps: std.EnumArray(Tint, Ramp),
    /// How far from the camera each level is drawn out to.
    reaches: [level_count]f32,
    /// `shield128`, which a bubble is drawn over (`0x0058CB68`), and `ffield`, which one flickering
    /// as a force field is (`0x0059372C`).
    texture: *srtexture.Image,
    field: *srtexture.Image,
    /// The capital ships' shields, made in `gpa`.
    capital: Capital,

    /// `0x0049EF10`: the textures, each tint's ramp, and the levels' spheres (`0x0049EE90`), at the
    /// options' detail, in `style`. The ramps are grey without a hardware renderer.
    pub fn create(gpa: Allocator, textures: *srtexture.Table, detail: Detail, hardware: bool, style: Style) (Allocator.Error || matmanager.Error)!Shields {
        const texture = try matmanager.textureRequire(textures, "shield128");
        const field = try matmanager.textureRequire(textures, "ffield");
        var meshes: [all_grids.len]srapiext.Mesh = undefined;
        var built: usize = 0;
        errdefer for (meshes[0..built]) |mesh| mesh.deinit(gpa);
        for (&meshes, all_grids) |*mesh, grid| {
            mesh.* = try sphereMesh(gpa, grid, texture);
            built += 1;
        }
        return .{
            .meshes = meshes,
            .style = style,
            .ramps = .init(.{ .friendly = buildRamp(.friendly, hardware), .other = buildRamp(.other, hardware) }),
            .reaches = reaches.get(detail),
            .texture = texture,
            .field = field,
            .capital = .{ .gpa = gpa },
        };
    }

    /// The sphere a bubble is drawn on at its finest in the shields' style: the game's finest
    /// level, or in the smooth style the finer sphere.
    pub fn finest(shields: *const Shields) Sphere {
        const level: usize = switch (shields.style) {
            .original => 0,
            .smooth => fine_level,
        };
        return .{ .mesh = &shields.meshes[level], .grid = all_grids[level] };
    }

    /// `0x0049EF60`: the meshes let go.
    pub fn deinit(shields: *Shields, gpa: Allocator) void {
        for (shields.meshes) |mesh| mesh.deinit(gpa);
        shields.capital.deinit();
    }

    /// The level of detail for a bubble `distance` from the camera, or null past the last: in the
    /// smooth style, the finer sphere close to it.
    fn levelAt(shields: *const Shields, distance: f32) ?usize {
        if (shields.style == .smooth and distance < shields.reaches[0] * fine_reach) return fine_level;
        for (shields.reaches, 0..) |reach, level| {
            if (distance < reach) return level;
        }
        return null;
    }

    /// What the bubbles' pass needs of the frame.
    pub const Look = struct {
        /// Where the camera is.
        camera: Vector,
        /// Whether the camera is in the player's cockpit (`camera.inCockpit`).
        inside: bool,
        frame_start: i32,
        /// How far past `frame_start` the frame is drawn, as a share of a tick
        /// (`objects.pastTick`), which the smooth style fades by.
        ahead: f32 = 0,
        /// While the game is paused (`0x0057E04C`), the bubbles' colours stand still.
        paused: bool = false,
        /// The runtime's numbers (`libcmt.Rand`), which a force field flickers by; without them it
        /// stays dark.
        random: ?*libcmt.Rand,
    };

    /// `0x0049F0A0`, once a frame (`mission_frame`): the bubble of each ship struck in the last
    /// `shown_for` ticks, into the world's layer, at the level of detail its distance from the
    /// camera gives, save the player's while the camera is in its cockpit. Each bubble's colours
    /// and texture move on by the ticks since they last did (`0x0049F450`, `shield_bubble_update`).
    ///
    /// Then the capital shields (`Capital.draw`).
    ///
    /// **Improvement:** a bubble past the last level's reach is left out; the game stops the pass
    /// there, leaving out every bubble in the slots after it and the capital shields.
    ///
    /// The game moves a bubble's colours on as the renderer draws it; OpenReliant as it goes into
    /// the scene, so one out of view still fades. In the smooth style each bubble's colours and
    /// texture coordinates for the frame go in `arena`.
    pub fn draw(shields: *Shields, gpa: Allocator, arena: Allocator, scene: *srcore.Scene, all: *Objects, look: Look) Allocator.Error!void {
        for (&shields.levels, &shields.meshes) |*level, *mesh| level.* = .{.{ .mesh = mesh, .until = std.math.inf(f32) }};
        for (&all.slots, 0..) |*slot, index| {
            if (slot.object.type == .stand_in) continue;
            const bubble = slot.shield orelse continue;
            const struck = bubble.struck orelse continue;
            const since = look.frame_start -% struck;
            if (since < 0 or since > shown_for) continue;
            const level = shields.levelAt(math.distance(gameobj.vector(slot.object.root.position), look.camera)) orelse continue;
            const hits = try bubble.hitsFor(all.gpa, shields.style);
            if (hits.* == .original) hits.original.level = level;
            if (index == all.player and look.inside) continue;
            const mesh = &shields.meshes[level];
            const ramp = shields.ramps.getPtrConst(bubble.tint);
            switch (hits.*) {
                .original => |kept| {
                    const vertices = mesh.positions.len;
                    if (!look.paused) {
                        const ticks: f32 = @floatFromInt(if (kept.updated) |updated| look.frame_start -% updated else 0);
                        if (!bubble.flickers(shields, mesh, look.frame_start, kept.colours[0..vertices], look.random)) kept.fade(ramp, vertices, ticks);
                        kept.swirl(vertices, ticks);
                        kept.updated = look.frame_start;
                    }
                    bubble.object.own_uv = .{ &kept.uv, null };
                    bubble.object.baked = &kept.colours;
                },
                .smooth => |*recent| {
                    const now = @as(f32, @floatFromInt(look.frame_start)) + look.ahead;
                    const colours = try arena.alloc([4]f32, mesh.positions.len);
                    const uv = try arena.alloc([2]f32, mesh.positions.len);
                    if (!bubble.flickers(shields, mesh, look.frame_start, colours, look.random)) recent.colour(ramp, mesh, now, colours);
                    recent.swirl(mesh, now, uv);
                    bubble.object.own_uv = .{ uv, null };
                    bubble.object.baked = colours;
                },
            }
            bubble.object.levels = &shields.levels[level];
            bubble.object.position = slot.drawn.position;
            bubble.object.orientation = slot.drawn.orientation;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &bubble.object }, .world);
        }
        try shields.capital.draw(shields, gpa, scene, all, look);
    }
};

/// `sphere_mesh_create` (`0x0049E3D0`): a sphere of a unit radius on `grid`, over `image`, lit and
/// added.
///
/// Not ported: its vertices' normals, which nothing lights.
pub fn sphereMesh(gpa: Allocator, grid: Grid, image: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    const triangles = grid.triangles(grid.down);
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = triangles, .vertices = grid.vertices(), .indices = triangles * 3 });
    errdefer mesh.deinit(gpa);
    for (mesh.positions, 0..) |*position, index| position.* = grid.vertex(index);
    grid.corners(grid.down, mesh.indices);
    mesh.numberPolygons(3);
    mesh.surfaces[0] = .{ .polygons = @intCast(triangles), .material = bubble_material, .textures = .{ .{ .image = image }, .none } };
    srapi.calcPolyNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// `shield_bubble_object` (`0x0049E370`, "Shield mesh"): a bubble's scene object, never culled,
/// at a unit radius scaled by `scale`, its levels and colours set by its user.
pub fn bubbleObject(scale: f32) srapiext.MeshObject {
    return .{
        .flags = .{ .not_culled = true, .baked_object = true, .own_first = true },
        .position = @splat(0),
        .scale = scale,
        .radius = 1,
        .levels = &.{},
    };
}

/// The texture coordinates `shield_bubble_object` gives the vertex of a bubble's sphere at `at`:
/// its `x` and `y`.
pub fn bubbleUv(at: Vector) [2]f32 {
    return .{ at[0], at[1] };
}

test bubbleObject {
    const object = bubbleObject(150);
    try std.testing.expect(object.flags.not_culled and object.flags.baked_object and object.flags.own_first);
    try std.testing.expectEqual(150, object.scale);
    try std.testing.expectEqual(1, object.radius);
    try std.testing.expectEqual(0, object.levels.len);
    try std.testing.expectEqual([2]f32{ 0.5, -0.25 }, bubbleUv(.{ 0.5, -0.25, 0.75 }));
}

/// A ship's shield bubble (`0x0049EF90`, 0x48 bytes), which `create_object` makes for a ship that
/// lists no components and is not debris, and which hangs from the ship's frame.
pub const Bubble = struct {
    /// Its scene object (`+0x04`, `bubbleObject`), scaled to `bubble_scale` of the ship's radius.
    object: srapiext.MeshObject,
    /// When a shot or a knock last struck it (`+0x0C`), or null for never.
    struck: ?i32 = null,
    tint: Tint,
    /// Until when it flickers as a force field (`+0x44`), or null.
    flicker_until: ?i32 = null,
    /// What its hits leave, kept as its style keeps them, from the first time it is struck or
    /// drawn.
    hits: ?Hits = null,

    pub const Hits = union(Style) {
        original: *Kept,
        smooth: Recent,
    };

    /// `0x0049EF90`: a bubble for a ship of `radius`, of the ship type's side.
    pub fn create(gpa: Allocator, radius: f32, side: gameobj.Side(i16)) Allocator.Error!*Bubble {
        const bubble = try gpa.create(Bubble);
        bubble.* = .{
            .object = bubbleObject(radius * bubble_scale),
            .tint = if (side == .friendly) .friendly else .other,
        };
        return bubble;
    }

    /// `0x0049F070`.
    pub fn destroy(bubble: *Bubble, gpa: Allocator) void {
        if (bubble.hits) |hits| switch (hits) {
            .original => |kept| gpa.destroy(kept),
            .smooth => {},
        };
        gpa.destroy(bubble);
    }

    /// Its hits, made in `style` where it has none yet.
    fn hitsFor(bubble: *Bubble, gpa: Allocator, style: Style) Allocator.Error!*Hits {
        if (bubble.hits == null) bubble.hits = switch (style) {
            .original => .{ .original = try Kept.create(gpa) },
            .smooth => .{ .smooth = .{} },
        };
        return &bubble.hits.?;
    }

    /// The bubble struck at `at`, standing at `place` round a ship at `centre`, at tick `now`
    /// (`0x0049F1E0`).
    fn strike(bubble: *Bubble, gpa: Allocator, shields: *const Shields, place: math.Place, centre: Vector, at: Vector, now: i32) Allocator.Error!void {
        switch ((try bubble.hitsFor(gpa, shields.style)).*) {
            .original => |kept| kept.strike(&shields.meshes[kept.level], place, bubble.object.scale, centre, at),
            .smooth => |*recent| recent.remember(place, at, now),
        }
        bubble.struck = now;
    }

    /// Flickers the bubble as a force field for `flicker_for` ticks, as a shockwave of kind 6 does
    /// to what it passes (`shockwaves_update`).
    pub fn flicker(bubble: *Bubble, now: i32) void {
        bubble.flicker_until = now + flicker_for;
        bubble.struck = now;
    }

    /// Whether the bubble flickers as a force field at `now`, which holds its hits (`0x0049E7D0`):
    /// then `mesh` is drawn over `ffield` until `flicker_until`, and `colours` are a random grey on
    /// one frame in `flicker_odds` and dark on the rest. The texture is set on the level's mesh,
    /// which every bubble at that level shares, as the game sets it.
    fn flickers(bubble: *Bubble, shields: *const Shields, mesh: *srapiext.Mesh, now: i32, colours: [][4]f32, random: ?*libcmt.Rand) bool {
        const until = bubble.flicker_until orelse return false;
        const over = until < now;
        mesh.surfaces[0].textures[0] = .{ .image = if (over) shields.texture else shields.field };
        if (over) bubble.flicker_until = null;
        const numbers = random orelse {
            @memset(colours, @splat(0));
            return true;
        };
        const lit = numbers.rand() % flicker_odds == 0;
        for (colours) |*colour| {
            const grey = numbers.fraction();
            colour.* = if (lit) .{ grey, grey, grey, 0 } else @splat(0);
        }
        return true;
    }
};

/// What the game keeps of a bubble's hits (`0x0049EF90`): a strength for each vertex of the level
/// it was struck at, the texture's swirl, and the scene object's colours (`+0x110`) and texture
/// coordinates (`+0x114`).
pub const Kept = struct {
    /// When its colours last moved on (`+0x08`), or null before the bubble is first drawn, which
    /// moves them by nothing. The game stamps it with the tick the bubble is made.
    updated: ?i32 = null,
    /// Where its texture swirls about (`+0x10`).
    centre: [2]f32 = start_centre,
    /// What each of its last hits leaves at each vertex (`+0x18`), and which the next takes
    /// (`+0x38`).
    strengths: [max_vertices][hit_slots]f32 = @splat(@splat(0)),
    next: HitSlot = 0,
    /// The level of detail it is drawn at (`+0x3C`).
    level: usize = 0,
    /// Each vertex's texture coordinates, from where the finest level's vertex stands across the
    /// sphere, which every level reads by its own vertices' numbers; and colour.
    uv: [max_vertices][2]f32 = finest_uv,
    colours: [max_vertices][4]f32 = @splat(@splat(0)),

    const finest_uv = uv: {
        @setEvalBranchQuota(10_000);
        var uv: [max_vertices][2]f32 = undefined;
        for (&uv, 0..) |*coordinates, index| coordinates.* = bubbleUv(grids[0].vertex(index));
        break :uv uv;
    };

    fn create(gpa: Allocator) Allocator.Error!*Kept {
        const kept = try gpa.create(Kept);
        kept.* = .{};
        return kept;
    }

    /// The vertex part of `0x0049F1E0`: a hit at `at` on a bubble of `scale` standing at `place`
    /// round a ship at `centre`, into the next of its hits, by how far round from the point struck
    /// each vertex of `mesh` lies.
    fn strike(kept: *Kept, mesh: *const srapiext.Mesh, place: math.Place, scale: f32, centre: Vector, at: Vector) void {
        const toward = at - centre;
        for (mesh.positions, kept.strengths[0..mesh.positions.len]) |position, *hits| {
            const out = place.point(position * @as(Vector, @splat(scale))) - centre;
            hits[kept.next] = strengthAt(angleBetween(toward, out)) orelse continue;
        }
        kept.next +%= 1;
    }

    /// The colours part of `0x0049E7D0`: each of the first `vertices` colours the sum of what its
    /// hits' strengths, faded by `ticks`, show in `ramp`.
    fn fade(kept: *Kept, ramp: *const Ramp, vertices: usize, ticks: f32) void {
        for (kept.colours[0..vertices], kept.strengths[0..vertices]) |*colour, *hits| colour.* = vertexColour(fadeHits(hits, ramp, ticks));
    }

    /// The texture part of `0x0049E7D0`: each of the first `vertices` coordinates turned about
    /// `centre` by `ticks`, the faster the nearer they are, and `centre` turned about the
    /// texture's corner. The game leaves `centre` off the coordinates it turns, so the texture
    /// wanders further each time; this does the same.
    fn swirl(kept: *Kept, vertices: usize, ticks: f32) void {
        for (kept.uv[0..vertices]) |*uv| uv.* = swirled(uv.*, kept.centre, ticks * swirl_per_tick);
        kept.centre = turned(kept.centre, ticks * centre_turn_per_tick);
    }
};

/// What the smooth style keeps of a bubble's hits: where each recent one struck and when, and when
/// the bubble was first drawn, from which its texture has swirled.
pub const Recent = struct {
    hits: [recent_hits]?Hit = @splat(null),
    next: std.math.IntFittingRange(0, recent_hits - 1) = 0,
    born: ?f32 = null,

    /// Where a hit struck, as a direction from the bubble's centre in the ship's frame, and when.
    const Hit = struct {
        direction: Vector,
        at: f32,
    };

    /// A hit at `at` on a bubble standing at `place`, at tick `now`.
    fn remember(recent: *Recent, place: math.Place, at: Vector, now: i32) void {
        recent.hits[recent.next] = .{
            .direction = math.normalize(place.inverse(at)),
            .at = @floatFromInt(now),
        };
        recent.next +%= 1;
    }

    /// Each of `mesh`'s vertices' colour at `now`, in ticks and a share of one, from what each
    /// recent hit leaves there by then, in `ramp`.
    fn colour(recent: *const Recent, ramp: *const Ramp, mesh: *const srapiext.Mesh, now: f32, colours: [][4]f32) void {
        for (mesh.positions, colours) |position, *vertex| {
            var sum: Colour = @splat(0);
            for (recent.hits) |maybe| {
                const hit = maybe orelse continue;
                const strength = strengthAt(angleBetween(position, hit.direction)) orelse continue;
                sum += rampAt(ramp, strength - (now - hit.at) * fade_per_tick);
            }
            vertex.* = vertexColour(sum);
        }
    }

    /// Each of `mesh`'s vertices' texture coordinates at `now`: its own, swirled about the centre
    /// as it has turned since the bubble was first drawn.
    fn swirl(recent: *Recent, mesh: *const srapiext.Mesh, now: f32, uv: [][2]f32) void {
        const born = recent.born orelse now;
        recent.born = born;
        const age = now - born;
        const centre = turned(start_centre, age * centre_turn_per_tick);
        for (mesh.positions, uv) |position, *coordinates| coordinates.* = swirledAbout(.{ position[0], position[1] }, centre, age * swirl_per_tick);
    }
};

/// Where `point` stands from `centre`, turned by `amount` over the square of how far that is: the
/// swirl, faster the nearer the centre. A point dead on the centre would turn by an infinite
/// angle; it is left.
fn swirled(point: [2]f32, centre: [2]f32, amount: f32) [2]f32 {
    const off = [2]f32{ point[0] - centre[0], point[1] - centre[1] };
    const reach = off[0] * off[0] + off[1] * off[1];
    return turned(off, if (reach > 0) amount / reach else 0);
}

/// `point` swirled about `centre` (`swirled`), where it stands.
fn swirledAbout(point: [2]f32, centre: [2]f32, amount: f32) [2]f32 {
    const off = swirled(point, centre, amount);
    return .{ off[0] + centre[0], off[1] + centre[1] };
}

/// `point` turned by `angle` about the origin.
fn turned(point: [2]f32, angle: f32) [2]f32 {
    const sin = @sin(angle);
    const cos = @cos(angle);
    return .{ cos * point[0] - sin * point[1], sin * point[0] + cos * point[1] };
}

/// How a shield's sparks fly: out from the ship through the point struck, at 7.5 to 12.5 a tick,
/// within half a radian either way, carrying on with a quarter of the ship's velocity, ten of them
/// (`0x0049F1E0`).
const shield_sparks: sparks.Spray = .{ .speed = 10, .speed_range = 5, .spread = 1, .count = 10 };
const sparks_carry: f32 = 0.25;

/// `0x0049F1E0`: the shields of the ship in slot `index` struck at `at`, by a shot or a knock,
/// while any of its shields holds anything. A cloaked ship shows its hull there
/// (`cloak.reveal`) and nothing more. Otherwise sparks fly off the point struck, unless the camera
/// is in the ship's cockpit, and its bubble ripples out from there.
///
/// **Improvement:** the game sends the sparks toward the world's origin, from the point struck
/// taken as a direction; OpenReliant sends them out from the ship, as the game works out first and
/// then writes over.
pub fn flare(world: gameobj.World, index: u16, at: Vector) void {
    const slot = &world.objects.slots[index];
    const object = &slot.object;
    const shields = object.shields.values();
    if (std.mem.allEqual(f32, &shields, 0)) return;
    if (object.flags.cloaked) return cloak.reveal(world, index, at);
    const bubble = slot.shield orelse return;
    const inside = if (world.camera) |watching| watching.inside(index) else false;
    if (!inside) {
        const carried = gameobj.vector(object.velocity) * @as(Vector, @splat(sparks_carry));
        sparks.spray(world, .shield, at, at - slot.drawn.position, carried, shield_sparks);
    }
    const shared = world.shields orelse return;
    // The game makes a bubble's hits with the bubble; where OpenReliant can't, it shows nothing.
    bubble.strike(world.objects.gpa, shared, slot.drawn, gameobj.vector(object.root.position), at, world.clock.frame_start) catch {};
}

// --- The capital ships' shields ------------------------------------------------------------------

/// How many capital shields show at once (`capshields`, `0x0058FB70`), and how long one shows after
/// it was last struck.
const capital_slots = 50;
const capital_shown_for = 200;

/// A slot of the capital shields.
pub const CapitalSlot = std.math.IntFittingRange(0, capital_slots - 1);

/// How far a hit on a capital shield reaches round the centre of the polygon struck: 0.3 of the
/// way across the part's bounds (`0x004DC4C0`), and no more than 8000 (`0x004DC9E4`). A vertex
/// there takes twice its share of the reach, the more the further out.
const capital_reach_share: f32 = 0.3;
const capital_max_reach: f32 = 8000;

/// Which ramp a capital shield glows in (`+0x34`). Nothing sets it: the game hands
/// `capshield_create` the object's side and leaves it unread, so every capital shield glows in a
/// friendly ship's colours.
const capital_tint: Tint = .friendly;

/// How much brighter a capital shield glows than its ramp, which a bubble glows in as it is, and
/// where its texture swirls about, how fast, over the square of how far a coordinate is from there,
/// a tick (`0x004DC418`).
const capital_brightness: f32 = 3;
const capital_centre: [2]f32 = .{ 0.5, 0.5 };
const capital_swirl_per_tick: f32 = 1e-3;

/// `part_is_force_field` (`0x0049FC70`): whether a part's name holds `FORCEFIELD`, whatever its
/// case.
pub fn isForceField(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, "FORCEFIELD") != null;
}

/// `force_field_mark` (`0x0049FCD0`): hides each part of `model` that is a force field, and of
/// each model it carries, as the capital ship's hull is lost (`explode.loseComponent`).
pub fn hideForceFields(model: *objects.Model) void {
    for (model.parts) |*part| {
        if (part.force_field) part.hidden = true;
    }
    var each = model.carried();
    while (each.next()) |mount| hideForceFields(&mount.model);
}

/// The capital shields showing (`capshields`, `0x0058FB70`). A ship that lists components has no
/// bubble. Where it is struck, a copy of the part struck glows round the hit instead, and a force
/// field glows whole.
pub const Capital = struct {
    gpa: Allocator,
    slots: [capital_slots]?*CapitalShield = @splat(null),
    /// The slot the next one takes (`capshield_next`, `0x00593728`), round and round, whatever
    /// shows there.
    next: CapitalSlot = 0,

    /// Lets every one go (`shields_deinit`).
    pub fn deinit(capital: *Capital) void {
        for (&capital.slots) |*slot| {
            if (slot.*) |shown| shown.destroy(capital.gpa);
            slot.* = null;
        }
    }

    /// The one showing on part `ref`, where its node names one.
    ///
    /// The game looks through every slot for the node; OpenReliant reads the slot the node names.
    fn find(capital: *const Capital, ref: objects.PartRef) ?CapitalSlot {
        const at = ref.part().capshield orelse return null;
        const shown = capital.slots[at] orelse return null;
        return if (shown.on.part.model == ref.model and shown.on.part.index == ref.index) at else null;
    }

    /// `capshield_free` (`0x0049F900`): lets slot `at` go, and its part, where it still stands in
    /// `all`, shows none.
    fn free(capital: *Capital, all: *Objects, at: CapitalSlot) void {
        const shown = capital.slots[at] orelse return;
        if (shown.stands(all, at)) shown.on.part.part().capshield = null;
        shown.destroy(capital.gpa);
        capital.slots[at] = null;
    }

    /// `capshield_flare` (`0x0049F4A0`) once the owner is checked: part `ref` of the object in
    /// slot `index` struck on `polygon` of the part's finest mesh at tick `now`. The part's
    /// capital shield shows `capital_shown_for` more ticks; where it has none, one is made in the
    /// next slot (`CapitalShield.create`), letting go of what shows there. Then it takes the hit.
    ///
    /// **Fix:** the game takes the slot it finds for the next one, so the next part struck replaces
    /// the shield struck last while slots stand free; OpenReliant leaves the next slot where it
    /// was.
    fn flare(capital: *Capital, shields: *const Shields, all: *Objects, index: u16, ref: objects.PartRef, polygon: ?usize, now: i32) Allocator.Error!void {
        const at = if (capital.find(ref)) |found| found: {
            capital.slots[found].?.until = now + capital_shown_for;
            break :found found;
        } else made: {
            const at = capital.next;
            capital.free(all, at);
            capital.slots[at] = try CapitalShield.create(capital.gpa, shields, index, ref, at, now);
            capital.next = if (at == capital_slots - 1) 0 else at + 1;
            break :made at;
        };
        capital.slots[at].?.strike(polygon);
    }

    /// `capshields_draw` (`0x0049F950`), once a frame after the bubbles: each capital shield
    /// showing into the world's layer, where its part stands, with its colours and texture moved
    /// on by the ticks since they last moved. One whose time is up is let go, as is one whose part
    /// is gone, which the game lets go of with the part's node (`0x00499CF0`).
    fn draw(capital: *Capital, shields: *const Shields, gpa: Allocator, scene: *srcore.Scene, all: *Objects, look: Shields.Look) Allocator.Error!void {
        for (capital.slots, 0..) |maybe, index| {
            const shown = maybe orelse continue;
            const at: CapitalSlot = @intCast(index);
            if (!(look.frame_start < shown.until) or !shown.stands(all, at)) {
                capital.free(all, at);
                continue;
            }
            const part = shown.on.part.part();
            shown.object.position = part.object.position;
            shown.object.orientation = part.object.orientation;
            const ticks: f32 = @floatFromInt(look.frame_start -% shown.moved);
            shown.fade(shields.ramps.getPtrConst(capital_tint), ticks);
            if (shown.force_field) shown.flicker(look.random) else shown.swirl(ticks);
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &shown.object }, .world);
            shown.moved = look.frame_start;
        }
    }
};

/// A capital shield (`capshields`, 0x3C bytes): a copy of the part struck, over `shield128`, or
/// `ffield` for a force field, which its last hits light.
pub const CapitalShield = struct {
    /// The part it shows on (`+0x00`).
    on: objects.PartOf,
    /// Its copy of the part's finest mesh, and the scene object that shows it (`+0x04`,
    /// `Capshield mesh`), with its colours (object `+0x110`).
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level = undefined,
    object: srapiext.MeshObject = undefined,
    colours: [][4]f32,
    /// Until when it shows (`+0x08`), and when its colours last moved on (`+0x0C`).
    until: i32,
    moved: i32,
    /// What each of its last hits leaves at each vertex (`+0x10`), and which the next takes
    /// (`+0x30`).
    strengths: [][hit_slots]f32,
    next: HitSlot = 0,
    /// Whether its part is a force field (`+0x38`).
    force_field: bool,

    /// `capshield_create` (`0x0049F790`): a capital shield on part `ref` of the object in slot
    /// `owner`, in slot `at`, at tick `now`. The copy draws every polygon, `cap` faces too, lit and
    /// adding to what is behind it, over the shield's texture.
    fn create(gpa: Allocator, shields: *const Shields, owner: u16, ref: objects.PartRef, at: CapitalSlot, now: i32) Allocator.Error!*CapitalShield {
        const part = ref.part();
        var mesh = try part.object.levels[0].mesh.copy(gpa, true);
        errdefer mesh.deinit(gpa);
        for (mesh.face_flags.?) |*flags| flags.cap = false;
        for (mesh.surfaces) |*surface| {
            surface.material.two_pass = false;
            surface.material.lit[0] = true;
            surface.material.blend[0] = .add;
            surface.textures[0] = .{ .image = if (part.force_field) shields.field else shields.texture };
        }
        const colours = try gpa.alloc([4]f32, mesh.positions.len);
        errdefer gpa.free(colours);
        @memset(colours, @splat(0));
        const strengths = try gpa.alloc([hit_slots]f32, mesh.positions.len);
        errdefer gpa.free(strengths);
        @memset(strengths, @splat(0));
        const shown = try gpa.create(CapitalShield);
        shown.* = .{
            .on = .{ .object = owner, .part = ref },
            .mesh = mesh,
            .colours = colours,
            .until = now + capital_shown_for,
            .moved = now,
            .strengths = strengths,
            .force_field = part.force_field,
        };
        shown.level = .{.{ .mesh = &shown.mesh, .until = std.math.inf(f32) }};
        shown.object = .{
            .flags = .{ .not_culled = true, .owns_mesh = true, .baked_object = true },
            .position = part.object.position,
            .orientation = part.object.orientation,
            .scale = part.object.scale,
            .radius = part.object.radius,
            .levels = &shown.level,
            .baked = colours,
        };
        part.capshield = at;
        return shown;
    }

    fn destroy(shown: *CapitalShield, gpa: Allocator) void {
        shown.mesh.deinit(gpa);
        gpa.free(shown.colours);
        gpa.free(shown.strengths);
        gpa.destroy(shown);
    }

    /// Whether its part still stands in `all` and names slot `at`: its object's model holds the
    /// part's, the part is not taken out, and its node names the slot. Only then is the part read.
    fn stands(shown: *const CapitalShield, all: *const Objects, at: CapitalSlot) bool {
        const part = shown.on.live(all) orelse return false;
        return !part.removed and part.capshield == at;
    }

    /// The hit part of `capshield_flare`, into the next of its hits: a force field's every vertex
    /// takes 1, which shows as it starts to fade. Any other part is lit round `polygon`, the one
    /// struck, out to `capital_reach_share` of the way across its bounds: a vertex there takes
    /// twice its share of the reach, so the glow spreads out from the polygon's middle as it fades.
    /// A polygon it can't read leaves the hit dark; the game reads past the polygons.
    fn strike(shown: *CapitalShield, polygon: ?usize) void {
        const which = shown.next;
        shown.next +%= 1;
        const round = if (shown.force_field) null else shown.middle(polygon);
        const reach = @min(math.distance(shown.mesh.bounds[1], shown.mesh.bounds[0]) * capital_reach_share, capital_max_reach);
        for (shown.mesh.positions, shown.strengths) |position, *hits| {
            hits[which] = if (shown.force_field) 1 else lit: {
                const away = math.distance(position, round orelse break :lit 0);
                break :lit if (away <= reach and reach > 0) @min(away / reach * 2, max_strength) else 0;
            };
        }
        shown.cull();
    }

    /// The middle of the copy's `polygon`, where there is such a polygon with corners.
    fn middle(shown: *const CapitalShield, polygon: ?usize) ?Vector {
        const mesh = &shown.mesh;
        const at = polygon orelse return null;
        if (at >= mesh.polygons.len or mesh.polygons[at].count == 0) return null;
        const struck = mesh.polygons[at];
        var sum: Vector = @splat(0);
        for (mesh.indices[struck.first..][0..struck.count]) |corner| sum += mesh.positions[corner];
        return sum / @as(Vector, @splat(@floatFromInt(struck.count)));
    }

    /// The polygons of the copy that none of its hits lights are not drawn: their faces are
    /// marked `cap`.
    ///
    /// **Fix:** the game marks those the latest hit leaves dark and never draws them again, so a
    /// part struck once more elsewhere loses the glow of its earlier hits; OpenReliant marks those
    /// every hit leaves dark, each time it is struck.
    fn cull(shown: *CapitalShield) void {
        const mesh = &shown.mesh;
        for (mesh.polygons, mesh.face_flags.?) |polygon, *flags| {
            flags.cap = for (mesh.indices[polygon.first..][0..polygon.count]) |corner| {
                if (std.mem.max(f32, &shown.strengths[corner]) > 0) break false;
            } else true;
        }
    }

    /// The colours part of `capshields_draw`: each vertex's hits faded by `ticks`, and what they
    /// show in `ramp`, `capital_brightness` times over.
    fn fade(shown: *CapitalShield, ramp: *const Ramp, ticks: f32) void {
        for (shown.colours, shown.strengths) |*colour, *hits| colour.* = vertexColour(fadeHits(hits, ramp, ticks) * @as(Colour, @splat(capital_brightness)));
    }

    /// A part's texture swirls about its middle by `ticks`, the faster the nearer it.
    ///
    /// **Improvement:** the sine and cosine come from `std.math` rather than the engine's tables
    /// (`sr_sin`, `sr_cos`).
    fn swirl(shown: *CapitalShield, ticks: f32) void {
        const uv = shown.mesh.uv[0] orelse return;
        for (uv) |*coordinates| coordinates.* = swirledAbout(coordinates.*, capital_centre, ticks * capital_swirl_per_tick);
    }

    /// A force field's texture coordinates each thrown anywhere at random, where there are the
    /// runtime's numbers to throw them by, and its green turned blue.
    fn flicker(shown: *CapitalShield, random: ?*libcmt.Rand) void {
        if (random) |numbers| if (shown.mesh.uv[0]) |uv| for (uv) |*coordinates| {
            const u = numbers.fraction();
            coordinates.* = .{ u, numbers.fraction() };
        };
        for (shown.colours) |*colour| {
            const blue = std.math.clamp(colour[2] + colour[1], 0, 1);
            colour[1] = 0;
            colour[2] = blue;
        }
    }
};

/// `capshield_flare` (`0x0049F4A0`): part `ref` of the object in slot `index`, which lists
/// components, struck on `polygon` of the part's finest mesh (`objects.PartRef.polygon`), by a
/// shot or a missile on a component (`shieldfx.componentHit`), or a force field struck by a shot
/// or a knock, which lights whole whatever the polygon. Nothing shows on an object whose
/// invulnerability is `_unknown_5`, nor on a force field of an object exploding.
pub fn flareCapital(world: gameobj.World, index: u16, ref: objects.PartRef, polygon: ?usize) void {
    const object = &world.objects.slots[index].object;
    if (object.invulnerable == ._unknown_5) return;
    const part = ref.part();
    if (part.force_field and object.flags.exploding) return;
    if (part.object.levels.len == 0) return;
    const shields = world.shields orelse return;
    // The game makes what a capital shield needs in its slot; where OpenReliant can't, it shows
    // nothing.
    shields.capital.flare(shields, world.objects, index, ref, polygon, world.clock.frame_start) catch {};
}

test {
    std.testing.refAllDecls(@This());
}

pub const testing = struct {
    /// The bubbles' meshes built over a table holding nothing but their textures.
    pub const Built = struct {
        textures: *@import("../surrender/surrenderlib/srtexture.zig").testing.Textures,
        shields: Shields,

        pub fn init(gpa: Allocator) !Built {
            const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &.{ "shield128", "ffield" });
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .shields = try .create(gpa, &textures.table, .high, true, .original) };
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.shields.deinit(gpa);
            built.textures.deinit(gpa);
        }
    };
};

test "Grid.sample" {
    const coarse: Grid = .{ .around = 4, .down = 3 };
    var values: [coarse.vertices()][4]f32 = undefined;
    for (&values, 0..) |*value, n| value.* = @splat(@floatFromInt(n));
    // On the grid itself, each vertex takes its own.
    for (0..values.len) |n| try std.testing.expectEqual(values[n], coarse.sample(coarse, &values, n));
    // On one three times as fine around and twice down, a vertex on one of the coarse grid's takes
    // its; one between takes a share of each.
    const fine: Grid = .{ .around = 12, .down = 6 };
    try std.testing.expectEqual(values[coarse.ring(1, 0)], fine.sample(coarse, &values, fine.ring(2, 0)));
    const first = values[coarse.ring(1, 0)][0];
    const second = values[coarse.ring(1, 1)][0];
    try std.testing.expectApproxEqAbs(first + (second - first) / 3, fine.sample(coarse, &values, fine.ring(2, 1))[0], 1e-5);
    // Halfway between two bands, halfway between them.
    const below = values[coarse.ring(2, 0)][0];
    try std.testing.expectApproxEqAbs((first + below) / 2, fine.sample(coarse, &values, fine.ring(3, 0))[0], 1e-5);
    // Round the last slice to the first, and the poles the coarse grid's.
    const last = values[coarse.ring(1, 3)][0];
    try std.testing.expectApproxEqAbs(last + (first - last) * 2 / 3, fine.sample(coarse, &values, fine.ring(2, 11))[0], 1e-5);
    try std.testing.expectEqual(values[0], fine.sample(coarse, &values, 0));
    try std.testing.expectEqual(values[values.len - 1], fine.sample(coarse, &values, fine.vertices() - 1));
    // A grid that isn't a whole multiple of the coarse one, as the finer bubble's isn't the game's.
    const odd: Grid = .{ .around = 10, .down = 7 };
    const between = odd.sample(coarse, &values, odd.ring(1, 0))[0];
    try std.testing.expectApproxEqAbs(values[0][0] + (first - values[0][0]) * 3.0 / 7.0, between, 1e-5);
}

test Grid {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);

    // Each level is a closed sphere of a unit radius: every corner a vertex of it, no triangle
    // folded flat, and every edge shared by two triangles.
    for (built.shields.meshes, all_grids) |mesh, grid| {
        try std.testing.expectEqual(grid.vertices(), mesh.positions.len);
        for (mesh.positions) |position| try std.testing.expectApproxEqAbs(1, math.length(position), 1e-5);
        try std.testing.expectApproxEqAbs(1, mesh.radius, 1e-5);
        var edges: std.AutoHashMapUnmanaged([2]u16, u8) = .empty;
        defer edges.deinit(gpa);
        var corners = std.mem.window(u16, mesh.indices, 3, 3);
        while (corners.next()) |triangle| {
            try std.testing.expect(triangle[0] != triangle[1] and triangle[1] != triangle[2] and triangle[0] != triangle[2]);
            for (0..3) |side| {
                const a = triangle[side];
                const b = triangle[(side + 1) % 3];
                try std.testing.expect(a < mesh.positions.len);
                const entry = try edges.getOrPutValue(gpa, .{ @min(a, b), @max(a, b) }, 0);
                entry.value_ptr.* += 1;
            }
        }
        var each = edges.valueIterator();
        while (each.next()) |uses| try std.testing.expectEqual(2, uses.*);
    }
}

test rampColour {
    // At 0.6 a friendly ship's is at its brightest, a cyan; it is dark at full strength and below
    // 0.35.
    const top = rampColour(.friendly, 0.6, true);
    try std.testing.expectApproxEqAbs(0.7 * ramp_brightness, top[1], 1e-6);
    try std.testing.expectApproxEqAbs(ramp_brightness, top[2], 1e-6);
    try std.testing.expectEqual(0, top[0]);
    try std.testing.expectEqual(Colour{ 0, 0, 0 }, rampColour(.friendly, 1, true));
    try std.testing.expectEqual(Colour{ 0, 0, 0 }, rampColour(.friendly, 0.3, true));
    // The others' swaps the green and the blue, dimmer; a friendly ship's is grey without a
    // hardware renderer.
    const other = rampColour(.other, 0.6, true);
    try std.testing.expectApproxEqAbs(ramp_brightness * other_share, other[1], 1e-6);
    try std.testing.expectApproxEqAbs(0.7 * ramp_brightness * other_share, other[2], 1e-6);
    try std.testing.expectEqual(@as(Colour, @splat(top[2])), rampColour(.friendly, 0.6, false));
    // Only a strength strictly between nothing and one shows.
    var ramp = buildRamp(.friendly, true);
    try std.testing.expectEqual(Colour{ 0, 0, 0 }, rampAt(&ramp, 0));
    try std.testing.expectEqual(Colour{ 0, 0, 0 }, rampAt(&ramp, 1));
    try std.testing.expect(rampAt(&ramp, 0.6)[2] > 0);
}

test "a hit ripples out from where it struck" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const shields = &built.shields;
    const bubble = try Bubble.create(gpa, 100, .friendly);
    defer bubble.destroy(gpa);
    const mesh = &shields.meshes[0];
    const vertices = mesh.positions.len;
    const ramp = shields.ramps.getPtrConst(.friendly);
    const grid = grids[0];
    const pole = 0;
    const near = grid.ring(4, 0);
    const equator = grid.ring(7, 0);

    // Struck on its pole: half a strength there, more further round, and nothing past 1.4 radians.
    try bubble.strike(gpa, shields, .{}, @splat(0), .{ 0, 0, 500 }, 10);
    try std.testing.expectEqual(10, bubble.struck);
    const kept = bubble.hits.?.original;
    try std.testing.expectEqual(1, kept.next);
    try std.testing.expectApproxEqAbs(0.5, kept.strengths[pole][0], 1e-5);
    try std.testing.expectApproxEqAbs(0.5 + 4 * std.math.pi / 14.0 / 1.2, kept.strengths[near][0], 1e-5);
    try std.testing.expectEqual(0, kept.strengths[equator][0]);

    // At first the pole glows and the ring four bands round, past one, is dark.
    kept.fade(ramp, vertices, 0);
    try std.testing.expect(kept.colours[pole][2] > 0);
    try std.testing.expectEqual(0, kept.colours[near][2]);
    // Twenty ticks on, the glow has moved out to it, and the pole is dark.
    const before = kept.uv[near];
    kept.fade(ramp, vertices, 20);
    kept.swirl(vertices, 20);
    try std.testing.expectEqual(0, kept.colours[pole][2]);
    try std.testing.expect(kept.colours[near][2] > 0);
    // Meanwhile the texture has swirled.
    try std.testing.expect(!std.meta.eql(before, kept.uv[near]));

    // A flicker as a force field swaps the texture while it lasts, and back after.
    bubble.flicker(30);
    try std.testing.expect(bubble.flickers(shields, mesh, 40, kept.colours[0..vertices], null));
    try std.testing.expectEqual(shields.field, mesh.surfaces[0].textures[0].image);
    try std.testing.expect(bubble.flickers(shields, mesh, 140, kept.colours[0..vertices], null));
    try std.testing.expectEqual(shields.texture, mesh.surfaces[0].textures[0].image);
    try std.testing.expect(!bubble.flickers(shields, mesh, 150, kept.colours[0..vertices], null));
}

test flare {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var thrown: sparks.testing.Built = try .init(gpa);
    defer thrown.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    var watching: @import("camera.zig").Camera = .{};
    world.shields = &built.shields;
    world.sparks = &thrown.sparks;
    world.camera = &watching;
    mission.clock.frame_start = 50;
    _ = try mission.add(.predator, @splat(0));
    const index = try mission.add(.sabre, .{ 0, 0, 1000 });
    const slot = mission.slot(index);
    const bubble = slot.shield.?;
    try std.testing.expectEqual(Tint.other, bubble.tint);

    // Struck with its shields up: it flares, and sparks fly.
    flare(world, index, .{ 0, 0, 900 });
    try std.testing.expectEqual(50, bubble.struck);
    try std.testing.expect(thrown.sparks.sparks.slots[0] != null);
    // Not while every shield is empty, nor while it is cloaked, when the hit shows its hull.
    bubble.struck = null;
    slot.object.shields = .all(0);
    flare(world, index, .{ 0, 0, 900 });
    try std.testing.expectEqual(null, bubble.struck);
    slot.object.shields = .all(10);
    slot.object.flags.cloaked = true;
    slot.cloak = .{ .came_at = 0 };
    mission.clock.frame_start = 70;
    flare(world, index, .{ 0, 0, 900 });
    try std.testing.expectEqual(null, bubble.struck);
    try std.testing.expectEqual(70, slot.cloak.?.struck_at);
}

test "Shields.draw" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    for ([_]u16{ player, other }) |index| mission.slot(index).shield.?.struck = 100;
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();
    const arena = frame.allocator();
    var look: Shields.Look = .{ .camera = @splat(0), .inside = true, .frame_start = 150, .random = null };

    // Both were struck within the last hundred ticks, but the camera is in the player's cockpit.
    try built.shields.draw(gpa, arena, &scene, mission.objects, look);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(&mission.slot(other).shield.?.object, scene.layers.get(.world).items[0].mesh);
    // A thousand away is the finest level's reach.
    try std.testing.expectEqual(0, mission.slot(other).shield.?.hits.?.original.level);

    // From outside, both; past a hundred ticks, neither.
    scene.clear();
    look.inside = false;
    try built.shields.draw(gpa, arena, &scene, mission.objects, look);
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    scene.clear();
    look.frame_start = 201;
    try built.shields.draw(gpa, arena, &scene, mission.objects, look);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}

test "the smooth style" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    built.shields.style = .smooth;
    const shields = &built.shields;
    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();
    const arena = frame.allocator();

    // Close to the camera it is drawn on the finer sphere, further off on the game's levels.
    try std.testing.expectEqual(fine_level, shields.levelAt(4000));
    try std.testing.expectEqual(0, shields.levelAt(6000));

    const bubble = try Bubble.create(gpa, 100, .friendly);
    defer bubble.destroy(gpa);
    const mesh = &shields.meshes[fine_level];
    const ramp = shields.ramps.getPtrConst(.friendly);
    const colours = try arena.alloc([4]f32, mesh.positions.len);
    const uv = try arena.alloc([2]f32, mesh.positions.len);
    const pole = 0;
    const near = fine_grid.ring(14, 0);
    const angle = 14 * std.math.pi / @as(f32, fine_grid.down);

    // A hit on its pole, remembered as where it struck and when.
    try bubble.strike(gpa, shields, .{}, @splat(0), .{ 0, 0, 500 }, 10);
    try std.testing.expectEqual(10, bubble.struck);
    const recent = &bubble.hits.?.smooth;
    recent.colour(ramp, mesh, 10, colours);
    try std.testing.expect(colours[pole][2] > 0);
    try std.testing.expectEqual(0, colours[near][2]);
    // Its texture coordinates start as the vertices' own.
    recent.swirl(mesh, 10, uv);
    try std.testing.expectEqual([2]f32{ mesh.positions[near][0], mesh.positions[near][1] }, uv[near]);

    // As it fades the glow moves out, and it fades between the ticks too.
    const ticks = (struck_strength + angle / strength_spread - 0.6) / fade_per_tick;
    recent.colour(ramp, mesh, 10 + ticks, colours);
    try std.testing.expectEqual(0, colours[pole][2]);
    const out = colours[near][2];
    try std.testing.expect(out > 0);
    recent.colour(ramp, mesh, 10 + ticks + 0.5, colours);
    try std.testing.expect(colours[near][2] != out);

    // The texture swirls about its centre, each vertex's coordinates keeping their distance from
    // it.
    const age = ticks + 0.5;
    recent.swirl(mesh, 10 + age, uv);
    const centre = turned(start_centre, age * centre_turn_per_tick);
    const from = [2]f32{ mesh.positions[near][0] - centre[0], mesh.positions[near][1] - centre[1] };
    const now = [2]f32{ uv[near][0] - centre[0], uv[near][1] - centre[1] };
    try std.testing.expectApproxEqAbs(from[0] * from[0] + from[1] * from[1], now[0] * now[0] + now[1] * now[1], 1e-4);
}

test isForceField {
    try std.testing.expect(isForceField("forcefield"));
    try std.testing.expect(isForceField("bow_ForceField2"));
    try std.testing.expect(!isForceField("force_field"));
    try std.testing.expect(!isForceField("hull"));
}

/// A part of two triangles far apart, and a lone vertex 0.3 of the reach from the first one's
/// middle, with a texture's coordinates.
fn testingPartMesh(gpa: Allocator) !srapiext.Mesh {
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 2, .vertices = 7, .indices = 6 });
    errdefer mesh.deinit(gpa);
    @memcpy(mesh.positions, &[_]Vector{ .{ 0, 0, 0 }, .{ 30, 0, 0 }, .{ 0, 30, 0 }, .{ 1000, 0, 0 }, .{ 1000, 30, 0 }, .{ 970, 0, 0 }, @splat(0) });
    @memcpy(mesh.indices, &[_]u16{ 0, 1, 2, 3, 4, 5 });
    mesh.numberPolygons(3);
    mesh.bounds = .{ @splat(0), .{ 1000, 30, 0 } };
    const reach = math.length(mesh.bounds[1]) * capital_reach_share;
    mesh.positions[6] = .{ 10 + 0.3 * reach, 10, 0 };
    mesh.surfaces[0] = .{ .polygons = 2, .material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .off }) };
    const uv = try mesh.addCoordinates(gpa);
    for (uv, 0..) |*coordinates, i| coordinates.* = .{ @as(f32, @floatFromInt(i)) / 6, 0.2 };
    return mesh;
}

test "capital shields" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const shields = &built.shields;
    const capital = &shields.capital;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var world = mission.world();
    world.shields = shields;
    mission.clock.frame_start = 100;
    const index = try mission.add(.kamov, @splat(0));

    const mesh = try testingPartMesh(gpa);
    defer mesh.deinit(gpa);
    const levels = [1]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var parts: [2]objects.Model.Part = @splat(.{ .hidden = false, .parent = null, .origin = @splat(0), .object = .{ .flags = .{}, .position = .{ 0, 0, 500 }, .radius = 1000, .levels = &levels } });
    const slot = mission.slot(index);
    const kept = slot.model;
    slot.model = .{ .parts = &parts, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    defer slot.model = kept;
    const model = &slot.model.?;
    const hull: objects.PartRef = .{ .model = model, .index = 0 };

    // Struck on its first triangle: a copy of the part, over the shield's texture, lit round the
    // triangle's middle and dark at the far one, which isn't drawn.
    flareCapital(world, index, hull, 0);
    const shown = capital.slots[0].?;
    try std.testing.expectEqual(0, parts[0].capshield);
    try std.testing.expectEqual(1, capital.next);
    try std.testing.expectEqual(300, shown.until);
    try std.testing.expectEqual(shields.texture, shown.mesh.surfaces[0].textures[0].image);
    try std.testing.expectEqual(srapiext.Material.Blend.add, shown.mesh.surfaces[0].material.blend[0]);
    try std.testing.expectApproxEqAbs(0.6, shown.strengths[6][0], 1e-4);
    try std.testing.expect(shown.strengths[1][0] > 0);
    try std.testing.expectEqual(0, shown.strengths[3][0]);
    try std.testing.expect(!shown.mesh.face_flags.?[0].cap);
    try std.testing.expect(shown.mesh.face_flags.?[1].cap);

    // Struck again on the far one, later: the same copy shows longer, both triangles are drawn,
    // and the next new one still takes the next slot.
    mission.clock.frame_start = 150;
    flareCapital(world, index, hull, 1);
    try std.testing.expectEqual(shown, capital.slots[0].?);
    try std.testing.expectEqual(350, shown.until);
    try std.testing.expectEqual(1, capital.next);
    try std.testing.expect(shown.strengths[3][1] > 0);
    try std.testing.expect(!shown.mesh.face_flags.?[0].cap and !shown.mesh.face_flags.?[1].cap);

    // Drawn where its part stands: the vertex at 0.6 glows, three times its ramp's brightest,
    // and the texture swirls about its middle, each coordinate keeping its distance from there.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var look: Shields.Look = .{ .camera = @splat(0), .inside = false, .frame_start = 100, .random = null };
    shown.moved = 100;
    const before = shown.mesh.uv[0].?[1];
    try capital.draw(shields, gpa, &scene, mission.objects, look);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 500 }), shown.object.position);
    try std.testing.expectApproxEqAbs(ramp_brightness * capital_brightness, shown.colours[6][2], 1e-4);
    try std.testing.expectEqual(0, shown.colours[3][2]);
    for (before, shown.mesh.uv[0].?[1]) |was, is| try std.testing.expectApproxEqAbs(was, is, 1e-6);
    look.frame_start = 110;
    try capital.draw(shields, gpa, &scene, mission.objects, look);
    const after = shown.mesh.uv[0].?[1];
    try std.testing.expect(!std.meta.eql(before, after));
    const from = [2]f32{ before[0] - 0.5, before[1] - 0.5 };
    const to = [2]f32{ after[0] - 0.5, after[1] - 0.5 };
    try std.testing.expectApproxEqAbs(from[0] * from[0] + from[1] * from[1], to[0] * to[0] + to[1] * to[1], 1e-5);
    // Its strengths have faded ten ticks' worth.
    try std.testing.expectApproxEqAbs(0.35, shown.strengths[6][0], 1e-4);

    // Once its time is up it goes, and its part shows none.
    look.frame_start = 350;
    try capital.draw(shields, gpa, &scene, mission.objects, look);
    try std.testing.expectEqual(null, capital.slots[0]);
    try std.testing.expectEqual(null, parts[0].capshield);

    // A force field glows whole over its own texture, and its colours come out blue; not on an
    // object exploding, nor on one whose invulnerability is the fifth.
    parts[1].force_field = true;
    const field: objects.PartRef = .{ .model = model, .index = 1 };
    capital.next = capital_slots - 1;
    mission.clock.frame_start = 350;
    flareCapital(world, index, field, null);
    const glowing = capital.slots[capital_slots - 1].?;
    try std.testing.expectEqual(0, capital.next);
    try std.testing.expectEqual(shields.field, glowing.mesh.surfaces[0].textures[0].image);
    for (glowing.strengths) |hits| try std.testing.expectEqual(1, hits[0]);
    look.frame_start = 360;
    try capital.draw(shields, gpa, &scene, mission.objects, look);
    try std.testing.expectEqual(0, glowing.colours[0][1]);
    try std.testing.expect(glowing.colours[0][2] > 0);
    capital.deinit();
    slot.object.flags.exploding = true;
    flareCapital(world, index, field, null);
    try std.testing.expectEqual(null, capital.slots[0]);
    slot.object.flags.exploding = false;
    slot.object.invulnerable = ._unknown_5;
    flareCapital(world, index, hull, 0);
    try std.testing.expectEqual(null, capital.slots[0]);
    slot.object.invulnerable = .none;

    // One whose object has gone is let go without its part being read.
    flareCapital(world, index, hull, 0);
    try std.testing.expect(capital.slots[0] != null);
    slot.model = null;
    try capital.draw(shields, gpa, &scene, mission.objects, look);
    try std.testing.expectEqual(null, capital.slots[0]);
    slot.model = .{ .parts = &parts, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };

    // As the ship is lost its force fields go dark.
    hideForceFields(&slot.model.?);
    try std.testing.expect(parts[1].hidden and !parts[0].hidden);
}
