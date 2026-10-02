//! What a jump shows, in `C:\lancer\game\jump.cpp` ([`jump.zig`](../jump.zig)). Each jump keeps a
//! record of its own (`jump_effects`, `0x0051CFA4`, 64 of them): trails that stream back from its
//! ship's engines, lights along its hull, the burst a ship arrives through, and the flare it leaves
//! and arrives by. Jump Out's and Jump In's updates make them, shade them and add them to the scene
//! each frame (`Shown`), and let the record go as the jump ends.
//!
//! OpenReliant builds the meshes the records share once, where the game builds a trail's and a
//! burst's mesh for each: the trails' two, the burst Jump In arrives through, and the flare's
//! (`jump_init`, `0x00416490`). Jump Out's own burst (`+0x64`), which the game builds and fades but
//! never adds to the scene, is left out.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../../engine.zig");
const Pointer = engine.Pointer;
const shp = @import("../../../formats/shp.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const Matrix = math.Matrix;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srlight = @import("../../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const loadout = @import("../../interface/loadout/loadout.zig");
const airipper = @import("../airipper.zig");
const create = @import("../create.zig");
const flash = @import("../guns/flash.zig");
const gameobj = @import("../gameobj.zig");
const matmanager = @import("../matmanager.zig");
const objects = @import("../objects.zig");
const xtrabits = @import("../xtrabits.zig");

const log = std.log.scoped(.jump);

/// How many records there are, and how many trails and lights a record holds
/// (`JUMP_MAX_TRAIL_MESHES`, `JUMP_MAX_LIGHTS`).
pub const max_records = 64;
pub const max_trails = 5;
pub const max_lights = 20;

/// A record as the game lays it out (`0x94` bytes), for Ghidra.
pub const Record = extern struct {
    trails: [max_trails]Pointer(anyopaque),
    lights: [max_lights]Pointer(anyopaque),
    /// Jump Out's burst, which is never drawn, and Jump In's.
    out_burst: Pointer(anyopaque),
    in_burst: Pointer(anyopaque),
    flare: Pointer(anyopaque),
    /// How Jump In's flare is turned before it stretches.
    flare_turn: [9]f32,

    comptime {
        assert(@offsetOf(Record, "lights") == 0x14);
        assert(@offsetOf(Record, "out_burst") == 0x64);
        assert(@offsetOf(Record, "flare") == 0x6C);
        assert(@sizeOf(Record) == 0x94);
    }
};

/// What the textures are called: the trails' (`jump_trail_texture`, `0x0051D0AC`), the flare's,
/// the lights' as they come on and as they go out, and the burst's under the hardware renderers
/// (`shield_texture`, `0x0058CB68`) and the software one.
const images = struct {
    const trail = "trail3";
    const flare = "jflare";
    const light = "lights\\flare-b";
    const light_going = "lights\\flare-lb";
    const burst = "shield128";
    const burst_software = "ddheat";
};

/// Whether a jump's flare lights what stands round it.
pub const Lighting = enum {
    /// **Improvement:** the flare casts a point light while it shows, in its own colour
    /// (`jflare`'s, as `flash.flareColour` works a muzzle flash's out), as bright as the share of
    /// it that shows, and reaching `flare_reach` times the ship's width, so that a ship lights up
    /// as it flashes in, and so does whatever stands by.
    flare,
    /// As the original: the flare lights nothing, its glow being in its texture alone.
    none,
};

/// How far the flare's light reaches, for each unit of the ship's width: two and a half times the
/// flare's length, which is four times the width, as a muzzle flash's reaches.
const flare_reach: f32 = 10;

/// What a jump's update adds to the scene this frame, which the frame then draws (`draw`): the
/// game adds them from the update itself.
pub const Shown = packed struct(u8) {
    trails: bool = false,
    lights: bool = false,
    burst: bool = false,
    flare: bool = false,
    _: u4 = 0,

    /// What `shown` shows, and `more` too.
    pub fn with(shown: Shown, more: Shown) Shown {
        return @bitCast(@as(u8, @bitCast(shown)) | @as(u8, @bitCast(more)));
    }
};

/// The meshes the records share, the lights' textures, and the records.
pub const Effects = struct {
    gpa: Allocator,
    /// `jump_flare_mesh` (`0x0051D0A8`).
    flare_mesh: srapiext.Mesh,
    flare_level: [1]srapiext.Level,
    /// A trail's mesh, for a ship that lists no components and for one that does.
    trail_meshes: [2]srapiext.Mesh,
    trail_levels: [2][1]srapiext.Level,
    /// Jump In's burst's mesh.
    burst_mesh: srapiext.Mesh,
    burst_level: [1]srapiext.Level,
    light_image: *srtexture.Image,
    light_going_image: *srtexture.Image,
    /// Whether the burst glows as the hardware renderers draw it, rather than the software one.
    hardware: bool,
    /// Whether the flare lights what stands round it, and in what colour.
    lighting: Lighting = .flare,
    flare_colour: [3]f32,
    records: [max_records]?*Effect = @splat(null),

    /// `jump_init` (`0x00416490`): the flare's mesh, a square 4 by 2 over the whole of `jflare`,
    /// white and added; and OpenReliant's shared meshes. It stays where it is made, as the objects
    /// point at its meshes.
    pub fn init(effects: *Effects, gpa: Allocator, textures: *srtexture.Table, hardware: bool) (Allocator.Error || matmanager.Error)!void {
        const trail_image = try matmanager.textureRequire(textures, images.trail);
        const flare_image = try matmanager.textureRequire(textures, images.flare);
        const burst_image = try matmanager.textureRequire(textures, if (hardware) images.burst else images.burst_software);
        const light_image = try matmanager.textureRequire(textures, images.light);
        const light_going_image = try matmanager.textureRequire(textures, images.light_going);
        var flare_mesh = try loadout.squareMesh(gpa, false, flare_size[0], flare_size[1]);
        errdefer flare_mesh.deinit(gpa);
        loadout.spanWhole(&flare_mesh);
        flare_mesh.surfaces[0] = .{
            .polygons = @intCast(flare_mesh.polygons.len),
            .material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .add }),
            .textures = .{ .{ .image = flare_image }, .none },
        };
        var small = try trailMesh(gpa, trail_image, false);
        errdefer small.deinit(gpa);
        var large = try trailMesh(gpa, trail_image, true);
        errdefer large.deinit(gpa);
        const burst_mesh = try burstMesh(gpa, burst_image, true);
        effects.* = .{
            .gpa = gpa,
            .flare_mesh = flare_mesh,
            .flare_level = undefined,
            .trail_meshes = .{ small, large },
            .trail_levels = undefined,
            .burst_mesh = burst_mesh,
            .burst_level = undefined,
            .light_image = light_image,
            .light_going_image = light_going_image,
            .hardware = hardware,
            .flare_colour = flash.flareColour(&.{.{ .image = flare_image }}),
        };
        effects.flare_level = .{.{ .mesh = &effects.flare_mesh, .until = std.math.inf(f32) }};
        for (&effects.trail_levels, &effects.trail_meshes) |*level, *mesh| level.* = .{.{ .mesh = mesh, .until = std.math.inf(f32) }};
        effects.burst_level = .{.{ .mesh = &effects.burst_mesh, .until = std.math.inf(f32) }};
    }

    /// `jump_free` (`0x00416510`).
    pub fn deinit(effects: *Effects) void {
        effects.reset();
        effects.flare_mesh.deinit(effects.gpa);
        for (&effects.trail_meshes) |*mesh| mesh.deinit(effects.gpa);
        effects.burst_mesh.deinit(effects.gpa);
    }

    /// As a mission ends (`jump_free`), every record goes.
    pub fn reset(effects: *Effects) void {
        for (0..max_records) |index| effects.free(@intCast(index));
    }

    /// `jump_effect_alloc` (`0x00418900`): the first free record, for the jump of the ship in slot
    /// `owner`; null where all are taken.
    pub fn alloc(effects: *Effects, owner: u16) Allocator.Error!?u8 {
        for (&effects.records, 0..) |*record, index| {
            if (record.* != null) continue;
            const effect = try effects.gpa.create(Effect);
            effect.* = .{ .owner = owner };
            record.* = effect;
            return @intCast(index);
        }
        return null;
    }

    /// Record `index`, where it is taken.
    pub fn get(effects: *Effects, index: u8) ?*Effect {
        return if (index < max_records) effects.records[index] else null;
    }

    /// `jump_effect_free` (`0x004189A0`).
    pub fn free(effects: *Effects, index: u8) void {
        const effect = effects.get(index) orelse return;
        effects.gpa.destroy(effect);
        effects.records[index] = null;
    }

    /// Before the frame's orders: nothing is shown until an update says so again, so that the
    /// record of a jump whose order went is drawn no more.
    pub fn beginFrame(effects: *Effects) void {
        for (effects.records) |record| if (record) |effect| {
            effect.shown = .{};
        };
    }

    /// Each record's trails, lights, burst and flare that its jump's update added to the scene this
    /// frame, into the world's layer: all but the flare hang from the ship where it is drawn.
    pub fn draw(effects: *Effects, gpa: Allocator, scene: *srcore.Scene, all: *const create.Objects) Allocator.Error!void {
        for (effects.records) |record| {
            const effect = record orelse continue;
            if (effect.owner >= all.slots.len) continue;
            const ship = all.slots[effect.owner].drawn;
            if (effect.shown.trails) for (&effect.trails) |*held| if (held.*) |*trail| {
                const place = trail.place.within(ship);
                trail.object.position = place.position;
                trail.object.orientation = place.orientation;
                try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &trail.object }, .world);
            };
            if (effect.shown.lights) for (&effect.lights) |*held| if (held.*) |*light| {
                light.set.position = ship.point(light.at);
                light.set.sprites = &light.sprite;
                try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &light.set }, .world);
            };
            if (effect.shown.burst) if (effect.burst) |*burst| {
                const place = (math.Place{ .position = burst_at }).within(ship);
                burst.object.position = place.position;
                burst.object.orientation = place.orientation;
                try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &burst.object }, .world);
            };
            if (effect.shown.flare) if (effect.flare) |*flare| {
                try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &flare.object }, .world);
                if (effects.lighting == .flare and flare.share > 0) {
                    flare.light = .{
                        .mask = 0,
                        .intensity = flare.share,
                        .colour = effects.flare_colour,
                        .kind = .{ .point = .{ .position = flare.object.position, .range = flare.width * flare_reach } },
                    };
                    try xtrabits.sceneAdd(gpa, scene, .{ .light = &flare.light }, .world);
                }
            };
        }
    }

    /// The trails of the ship in slot `index` (`jump_effect_start`, and Jump In's placing): one at
    /// each point of the jump's trails on each part that hangs from the model's root, in the
    /// ship's frame, at most `max_trails`; or one at the ship's own place where it has none. A ship
    /// that lists components trails the larger mesh. Each trails back from where it stands, but
    /// for a Ripper whose cargo pod shows, which flies astern, whose trail streams ahead.
    ///
    /// **Fix:** the game stops with "Too many jumpt trail meshes assigned to this ship.  Check the
    /// pointlists!" past `max_trails`; OpenReliant keeps the first.
    pub fn startTrails(effects: *Effects, effect: *Effect, slot: *create.Slot) void {
        var points: [max_trails]Vector = undefined;
        const count = collect(slot, .jump_trails, &points);
        const found = if (count == 0) 1 else count;
        const large = slot.object.flags.components;
        const turn = if (streamsAhead(slot)) math.identity else math.fromAngles(0, std.math.pi, 0);
        for (0..found) |n| {
            const at: Vector = if (count == 0) @splat(0) else points[n];
            effect.trails[n] = .{
                .object = .{
                    .flags = .{ .not_culled = true, .owns_mesh = true, .baked_object = true },
                    .position = @splat(0),
                    .radius = effects.trail_meshes[@intFromBool(large)].radius,
                    .levels = &effects.trail_levels[@intFromBool(large)],
                },
                .place = .{ .position = at, .orientation = turn },
            };
            const trail = &effect.trails[n].?;
            trail.object.baked = &trail.colours;
        }
    }

    /// The rest of `jump_effect_start` (`0x00417670`): the ship's trails (`startTrails`), and a
    /// light at each point of the jump's lights on each part hanging from its root, at most
    /// `max_lights`: a sprite `light_half` across either way, sorted as if that much nearer, on
    /// `lights\flare-b`, coloured by its colour and added. Returns how many lights it has
    /// (`jump.State.lights`).
    ///
    /// **Fix:** the game stops with "Too many jump lights assigned to this ship.  Check the
    /// pointlists!" past `max_lights`; OpenReliant keeps the first.
    pub fn start(effects: *Effects, effect: *Effect, slot: *create.Slot) usize {
        effects.startTrails(effect, slot);
        var points: [max_lights]Vector = undefined;
        const count = collect(slot, .jump_lights, &points);
        for (points[0..count], 0..) |at, n| {
            var set: srapiext.SpriteSet = .{ .sprites = &.{} };
            set.surface.material.lit[0] = true;
            set.surface.textures = .{ .{ .image = effects.light_image }, .none };
            effect.lights[n] = .{ .set = set, .sprite = .{.{ .half_size = .{ light_half, light_half }, .bias = -light_half }}, .at = at };
        }
        effect.light_count = count;
        return count;
    }

    /// The burst Jump In arrives through (its placing): the shared mesh, hanging `burst_at` ahead
    /// of the ship, glowing at full (`glowBurst`).
    pub fn startBurst(effects: *Effects, effect: *Effect) void {
        effect.burst = .{ .object = .{
            .flags = .{ .normals_second = true, .not_culled = true, .unbounded = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = effects.burst_mesh.radius,
            .levels = &effects.burst_level,
        } };
        const burst = &effect.burst.?;
        burst.object.baked = &burst.colours;
        glowBurst(burst, 1, effects.hardware);
    }

    /// `jump_flare_object` (`0x00418120`): the flare, standing at `at` in the world, as wide as
    /// `width`, which the jump's steps change. It keeps how it is turned (`Effect.flare_turn`),
    /// as Jump In's placing does after it in the game; Jump Out never reads it.
    pub fn startFlare(effects: *Effects, effect: *Effect, at: math.Place, width: f32) void {
        effect.flare = .{ .width = width, .object = .{
            .flags = .{ .not_culled = true, .baked_object = true },
            .position = at.position,
            .orientation = at.orientation,
            .scale = width,
            .radius = effects.flare_mesh.radius,
            .levels = &effects.flare_level,
        } };
        const flare = &effect.flare.?;
        flare.object.baked = &flare.colours;
        effect.flare_turn = at.orientation;
    }

    /// Jump Out's lights as it charges, `progress` of the way (`Effect.chargeLights`), turning to
    /// `lights\flare-lb` as they are swept along the hull.
    pub fn chargeLights(effects: *const Effects, effect: *Effect, progress: f32) void {
        effect.chargeLights(progress, effects.light_going_image);
    }

    /// Jump In's burst glowing as it flies in, `share` of the way still to go (`glowBurst`), as
    /// the renderer draws it.
    pub fn glow(effects: *const Effects, effect: *Effect, share: f32) void {
        if (effect.burst) |*burst| glowBurst(burst, share, effects.hardware);
    }
};

/// A jump's record as OpenReliant keeps it: its objects, and what its update shows this frame.
pub const Effect = struct {
    /// The slot of the ship whose jump it is, from which all but the flare hang.
    owner: u16,
    trails: [max_trails]?Trail = @splat(null),
    lights: [max_lights]?Light = @splat(null),
    light_count: usize = 0,
    burst: ?Burst = null,
    flare: ?Flare = null,
    /// How Jump In's flare is turned before it stretches (`+0x70`), which `Effects.startFlare`
    /// keeps.
    flare_turn: Matrix = math.identity,
    shown: Shown = .{},

    /// `jump_trail_shade` (`0x00418390`) for each trail: its blades glow `trail_colour` times
    /// `trail_share` of `share` along their near edges, fading to nothing at their far ones.
    pub fn shadeTrails(effect: *Effect, share: f32) void {
        for (&effect.trails) |*held| if (held.*) |*trail| shadeTrail(trail, share);
    }

    /// Jump Out's lights as it charges, `progress` of the way: all as bright as `progress` over
    /// `lights_full`, until `lights_going`; then a light a step along the hull, by how far past
    /// that it is, turns to `lights\flare-lb`, and the one two behind it goes out.
    pub fn chargeLights(effect: *Effect, progress: f32, going_image: *srtexture.Image) void {
        if (progress < lights_going) {
            const shade = progress * lights_rise;
            for (&effect.lights) |*held| if (held.*) |*light| {
                light.sprite[0].colour = @splat(shade);
            };
            return;
        }
        const along = (progress - lights_going) * lights_sweep * @as(f32, @floatFromInt(@as(i32, @intCast(effect.light_count)) - 1));
        const lit = math.round(along);
        if (lit >= 0 and lit < max_lights) if (effect.lights[@intCast(lit)]) |*light| {
            light.set.surface.textures[0] = .{ .image = going_image };
        };
        if (lit > 1 and lit - 2 < max_lights) if (effect.lights[@intCast(lit - 2)]) |*light| {
            light.sprite[0].colour = @splat(0);
        };
    }

    /// Every light out, as Jump Out goes.
    pub fn lightsOut(effect: *Effect) void {
        for (&effect.lights) |*held| if (held.*) |*light| {
            light.sprite[0].colour = @splat(0);
        };
    }

    /// Jump In's flare as the ship flies in, `progress` of the way: until `flare_squash` of it, at
    /// full width, turned as it arrived (`flare_turn`) and scaled `1 + progress * flare_stretch`
    /// across and from 1 down to `flare_thinnest` up, which stretches and flattens it in the
    /// world's own X and Y, and as much of it shows as it is high. Whether it shows: not past
    /// `flare_squash`, nor where there is no flare.
    pub fn squashFlare(effect: *Effect, progress: f32) bool {
        if (progress >= flare_squash) return false;
        const flare = if (effect.flare) |*held| held else return false;
        const height = 1 - progress / flare_squash + flare_thinnest;
        flare.grow(1);
        flare.share = height;
        flare.object.orientation = math.product(effect.flare_turn, math.scaling(.{ 1 + progress * flare_stretch, height, 1 }));
        return true;
    }
};

/// How the flare stretches across and flattens as the ship flies in (`Effect.squashFlare`):
/// `flare_stretch` times its width across for each of the flight's share (`0x004DC3D8`), gone flat
/// at `flare_squash` of it (`0x004DC4C0`), and never quite nothing (`0x004DC568`).
///
/// **Improvement:** OpenReliant flattens it by the share over `flare_squash`, where the game
/// multiplies by 3.3333333 (`0x004DC530`).
const flare_stretch: f32 = 3;
const flare_squash: f32 = 0.3;
const flare_thinnest: f32 = 1e-6;

/// How the ship's own lights are lit: from nothing to full as the charge reaches `1 / lights_rise`
/// (`0x004DC570`), then from `lights_going` of it (`0x004DC410`) swept along the hull at
/// `lights_sweep` (`0x004DC56C`).
const lights_rise: f32 = 1.25;
const lights_going: f32 = 0.8;
const lights_sweep: f32 = 5;

/// A light's sprite, `light_half` across either way (`0x00417A5F`).
const light_half: f32 = 150;

/// The flare's mesh, 4 by 2 (`0x004164A3`), which its object scales by the ship's width.
const flare_size = [2]f32{ 4, 2 };

/// Where Jump In's burst hangs in the ship's frame (`0x0041673D`).
const burst_at: Vector = .{ 0, 0, 800 };

const Trail = struct {
    object: srapiext.MeshObject,
    colours: [trail_vertices][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    /// Where it stands in the ship's frame, and how it is turned.
    place: math.Place,
};

const Light = struct {
    set: srapiext.SpriteSet,
    sprite: [1]srapiext.Sprite,
    /// Where it stands in the ship's frame.
    at: Vector,
};

const Burst = struct {
    object: srapiext.MeshObject,
    colours: [burst_vertices][4]f32 = @splat(.{ 0, 0, 0, 0 }),
};

pub const Flare = struct {
    object: srapiext.MeshObject,
    colours: [4][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    /// The ship's width, which it is scaled by, and how much of it shows, from nothing to 1, which
    /// its light is as bright as (`Lighting.flare`).
    width: f32,
    share: f32 = 0,
    light: srlight.Light = undefined,

    /// Scaled to `share` of the ship's width across, and as much of it shows.
    pub fn grow(flare: *Flare, share: f32) void {
        flare.object.scale = flare.width * share;
        flare.share = share;
    }
};

/// The points of `kind` on each part that hangs from the ship's model's root, in the ship's frame
/// (`node_point_group`, `0x004ADD50`, then each part's place), into `into`, as many as fit: how
/// many.
fn collect(slot: *create.Slot, kind: shp.PointList.Kind, into: []Vector) usize {
    const model = if (slot.model) |*live| live else return 0;
    var count: usize = 0;
    for (model.parts, 0..) |part, index| {
        if (part.parent != null or index >= model.source.parts.len) continue;
        const list = model.source.parts[index].pointList(kind) orelse continue;
        const stands = model.partPlace(index, .now);
        for (list.points) |point| {
            if (count == into.len) {
                log.warn("a ship has more points for its jump's trails or lights than the {d} it takes; the rest are left out", .{into.len});
                return count;
            }
            into[count] = stands.point(gameobj.vector(point.position));
            count += 1;
        }
    }
    return count;
}

/// Whether the ship's trails stream ahead of it: a Ripper, while its cargo pod shows.
fn streamsAhead(slot: *create.Slot) bool {
    if (slot.object.type != .ripper) return false;
    const model = if (slot.model) |*live| live else return false;
    const pod = model.partNamed(airipper.cargo_part) orelse return false;
    return !pod.part().hidden;
}

// --- The trails ---------------------------------------------------------------------------------

/// A trail (`jump_trail_mesh`, `0x00417AF0`, "JumpTrail Mesh"): a square across its start
/// `trail_sizes[components]` wide, then three blades a third of a turn apart through its axis,
/// running `trail_lengths[components]` along Z, the blades' corners over the texture from 0.04 to
/// 0.99 either way, coloured by their colours and added.
const trail_vertices = 16;
const trail_blades = 3;
const trail_sizes = [2]f32{ 100, 1000 };
const trail_lengths = [2]f32{ 20000, 40000 };
const trail_near: f32 = 0.04;
const trail_far: f32 = 0.99;

/// **Improvement:** the blades stand a third of a turn apart by `std.math.pi`, where the game
/// multiplies by 1.0471976 (`0x004DC458`).
fn trailMesh(gpa: Allocator, image: *srtexture.Image, components: bool) Allocator.Error!srapiext.Mesh {
    const size = trail_sizes[@intFromBool(components)];
    const length = trail_lengths[@intFromBool(components)];
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 1 + trail_blades, .vertices = trail_vertices, .indices = trail_vertices, .surfaces = 2 });
    errdefer mesh.deinit(gpa);
    mesh.positions[0..4].* = .{ .{ -size, -size, 0 }, .{ size, -size, 0 }, .{ size, size, 0 }, .{ -size, size, 0 } };
    for (0..trail_blades) |blade| {
        const angle = @as(f32, @floatFromInt(blade)) * std.math.pi / trail_blades;
        const across: Vector = .{ size * @sin(angle), size * @cos(angle), 0 };
        const far: Vector = .{ 0, 0, length };
        mesh.positions[4 + 4 * blade ..][0..4].* = .{ -across, far - across, far + across, across };
    }
    mesh.numberPolygons(4);
    for (mesh.indices, 0..) |*index, n| index.* = @intCast(n);
    const uv = try mesh.addCoordinates(gpa);
    for (0..mesh.polygons.len) |face| {
        uv[4 * face ..][0..4].* = .{ .{ trail_far, trail_far }, .{ trail_far, trail_near }, .{ trail_near, trail_near }, .{ trail_near, trail_far } };
    }
    const material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add });
    mesh.surfaces[0] = .{ .polygons = 1, .material = material, .textures = .{ .{ .image = image }, .none } };
    mesh.surfaces[1] = .{ .polygons = trail_blades, .material = material, .textures = .{ .{ .image = image }, .none } };
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// How brightly a trail glows, of the share it is shaded by (`0x004DC4C0`), and its colour at the
/// full (`0x004DC408`, `0x004DC484`).
const trail_share: f32 = 0.3;
const trail_colour: Vector = .{ 0.5, 0.7, 1 };

/// `jump_trail_shade` (`0x00418390`): every vertex opaque; each blade's two near corners
/// `trail_colour` times `trail_share` of `share`, its far ones black. The square across its start
/// keeps its colours.
fn shadeTrail(trail: *Trail, share: f32) void {
    for (&trail.colours) |*colour| colour[3] = 1;
    const near = trail_colour * @as(Vector, @splat(share * trail_share));
    for (0..trail_blades) |blade| {
        const corners = trail.colours[4 + 4 * blade ..][0..4];
        corners[0][0..3].* = near;
        corners[1][0..3].* = @splat(0);
        corners[2][0..3].* = @splat(0);
        corners[3][0..3].* = near;
    }
}

// --- The burst ----------------------------------------------------------------------------------

/// The burst (`jump_burst_mesh`, `0x00417E30`, "JumpBurst Mesh"): a point at its centre, then six
/// rings of twelve, each farther back along Z and wider, the first of Jump In's closing to a point,
/// banded with triangles from each ring to the next, over its texture by where each corner stands,
/// coloured by its colours and added by their alpha. Jump In's is then made twice as wide.
const burst_rings = 6;
const burst_ring_points = 12;
const burst_vertices = 1 + burst_rings * burst_ring_points;

/// How far a ring stands behind the last, and how wide the widest is, Jump In's and Jump Out's
/// (`0x004DC580`); how its width grows from ring to ring along a quarter of a sine wave
/// (`0x004DC588`, `0x004DC4B4`, `0x004DC584`); how the texture spans it (`0x004DC578`,
/// `0x004DC574`); and how much wider Jump In's is made.
const burst_depths = [2]f32{ 0.9, 0.1 };
const burst_widths = [2]f32{ 1800, 500 };
const burst_depth: f32 = 1800;
const burst_growth: f32 = 0.2;
const burst_width_share: f32 = 0.6;
const burst_least: f32 = 30;
const burst_u: f32 = 1.0 / 108000.0;
const burst_v: f32 = 1.0 / 10800.0;
const burst_widening: f32 = 2;

/// **Fix:** the game leaves the first triangle's corners at the texture's corner, as it starts
/// from the second; OpenReliant spans them like the rest.
///
/// **Improvement:** the rings' points stand a twelfth of a turn apart by `std.math.tau`, and their
/// widths by `std.math.pi`, where the game multiplies by 6.2831855 and 0.083333336 (`0x004DC3EC`,
/// `0x004DC57C`) and by 1.5707964 (`0x004DC3F0`).
fn burstMesh(gpa: Allocator, image: *srtexture.Image, arriving: bool) Allocator.Error!srapiext.Mesh {
    const bands = burst_rings - 1;
    const triangles = 2 * bands * burst_ring_points;
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = triangles, .vertices = burst_vertices, .indices = 3 * triangles });
    errdefer mesh.deinit(gpa);
    const style = @intFromBool(arriving);
    mesh.positions[0] = @splat(0);
    for (0..burst_rings) |ring| {
        const k: f32 = @floatFromInt(ring);
        const radius = if (arriving and ring == 0) 0 else @sin(k * burst_growth * std.math.pi / 2.0) * burst_widths[style] * burst_width_share + burst_least;
        const z = -(k * burst_depths[style] * burst_depth);
        for (0..burst_ring_points) |point| {
            const angle = @as(f32, @floatFromInt(point)) * std.math.tau / burst_ring_points;
            mesh.positions[ringPoint(ring, point)] = .{ radius * @sin(angle), radius * @cos(angle), z };
        }
    }
    mesh.numberPolygons(3);
    var at: usize = 0;
    for (1..burst_rings) |ring| {
        for (0..burst_ring_points) |point| {
            const next = (point + 1) % burst_ring_points;
            const a = ringPoint(ring - 1, point);
            const b = ringPoint(ring, point);
            const c = ringPoint(ring - 1, next);
            const d = ringPoint(ring, next);
            mesh.indices[at..][0..6].* = .{ a, b, c, c, b, d };
            at += 6;
        }
    }
    const uv = try mesh.addCoordinates(gpa);
    for (mesh.indices, uv) |index, *corner| {
        const p = mesh.positions[index];
        corner.* = .{ p[2] * burst_u, p[1] * burst_v };
    }
    mesh.surfaces[0] = .{
        .polygons = triangles,
        .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add_alpha }),
        .textures = .{ .{ .image = image }, .none },
    };
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    if (arriving) {
        for (mesh.positions) |*p| {
            p[0] *= burst_widening;
            p[1] *= burst_widening;
        }
    }
    return mesh;
}

/// The vertex of point `point` of ring `ring`, past the centre.
fn ringPoint(ring: usize, point: usize) u16 {
    return @intCast(1 + ring * burst_ring_points + point);
}

/// How the burst's colours fall from ring to ring as it fades (`0x004DC420`) and as it glows
/// (`0x004DC590`), and the colour of its first twelve as it glows under the hardware renderers
/// (`0x004DC408`, `0x004DC58C`).
const burst_fade_step: f32 = 0.1;
const burst_glow_step: f32 = 0.04;
const burst_glow_tip: Vector = .{ 0.5, 0.21, 0 };

/// `jump_burst_glow` (`0x004181C0`), `share` of the way. `jump_burst_fade` (`0x00418150`), which
/// greys the rings as `jump_burst_mesh` makes a burst and as Jump Out goes, goes with Jump Out's
/// burst, as Jump In's glow covers it: the first twelve colours
/// `burst_glow_tip` times `share` squared under the hardware renderers, and grey `share` squared
/// under the software one, as opaque as `share`; each twelve after them a step less, from four
/// steps of `burst_glow_step` times `share`, red under the hardware renderers and grey under the
/// software one, opaque. The colours run from the centre on, a place ahead of the rings'.
fn glowBurst(burst: *Burst, share: f32, hardware: bool) void {
    for (burst.colours[0..burst_ring_points]) |*colour| {
        const tip: Vector = if (hardware) burst_glow_tip * @as(Vector, @splat(share)) else @splat(share);
        colour.* = .{ tip[0] * share, tip[1] * share, tip[2] * share, share };
    }
    var at: usize = burst_ring_points;
    var step: usize = burst_rings - 1;
    while (step > 0) {
        step -= 1;
        const shade = @as(f32, @floatFromInt(step)) * share * burst_glow_step;
        for (burst.colours[at..][0..burst_ring_points]) |*colour| {
            colour.* = if (hardware) .{ shade, 0, 0, 1 } else .{ shade, shade, shade, 1 };
        }
        at += burst_ring_points;
    }
}

test "the trail's mesh" {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = .{ .levels = &.{} };
    var mesh = try trailMesh(gpa, &image, false);
    defer mesh.deinit(gpa);
    // A square across its start, then three blades through the axis, 20000 long.
    try std.testing.expectEqual(Vector{ -100, -100, 0 }, mesh.positions[0]);
    try std.testing.expectEqual(Vector{ 0, -100, 0 }, mesh.positions[4]);
    try std.testing.expectEqual(Vector{ 0, 100, 20000 }, mesh.positions[6]);
    try math.testing.expectVectorWithin(.{ -86.60254, 50, 0 }, mesh.positions[12], 1e-3);
    try std.testing.expectEqual(2, mesh.surfaces.len);
    try std.testing.expectEqual(3, mesh.surfaces[1].polygons);
    try std.testing.expectEqual([2]f32{ trail_far, trail_near }, mesh.uv[0].?[5]);
    // A ship that lists components trails a wider and longer one.
    var large = try trailMesh(gpa, &image, true);
    defer large.deinit(gpa);
    try std.testing.expectEqual(Vector{ 0, 1000, 40000 }, large.positions[6]);
}

test "a trail's shade" {
    var trail: Trail = .{ .object = undefined, .place = .{} };
    shadeTrail(&trail, 1);
    // The blades' near corners glow, their far ones are black, and every vertex is opaque.
    for (@as([3]f32, trail_colour * @as(Vector, @splat(trail_share))), trail.colours[4][0..3]) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-6);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, trail.colours[5]);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, trail.colours[0]);
}

test "the burst's mesh" {
    const gpa = std.testing.allocator;
    var image: srtexture.Image = .{ .levels = &.{} };
    var mesh = try burstMesh(gpa, &image, true);
    defer mesh.deinit(gpa);
    try std.testing.expectEqual(burst_vertices, mesh.positions.len);
    try std.testing.expectEqual(120, mesh.polygons.len);
    // Jump In's first ring closes to a point; its last stands 900 back, 330 across, made twice as
    // wide.
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, mesh.positions[ringPoint(0, 3)]);
    try math.testing.expectVectorWithin(.{ 0, 660, -900 }, mesh.positions[ringPoint(5, 0)], 1e-2);
    // A band's two triangles, from each ring to the next.
    try std.testing.expectEqualSlices(u16, &.{ 1, 13, 2, 2, 13, 14 }, mesh.indices[0..6]);
    // Its first triangle is spanned like the rest.
    try std.testing.expectApproxEqAbs(-180 * burst_u, mesh.uv[0].?[1][0], 1e-9);
}

test glowBurst {
    var burst: Burst = .{ .object = undefined };
    glowBurst(&burst, 1, true);
    try std.testing.expectEqual([4]f32{ 0.5, 0.21, 0, 1 }, burst.colours[0]);
    try std.testing.expectApproxEqAbs(4 * burst_glow_step, burst.colours[burst_ring_points][0], 1e-6);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, burst.colours[burst_vertices - 2]);
    glowBurst(&burst, 0.5, false);
    try std.testing.expectEqual([4]f32{ 0.25, 0.25, 0.25, 0.5 }, burst.colours[0]);
}

test "Effect.chargeLights" {
    var effect: Effect = .{ .owner = 0, .light_count = 6 };
    var image: srtexture.Image = .{ .levels = &.{} };
    var going: srtexture.Image = .{ .levels = &.{} };
    for (0..6) |n| effect.lights[n] = .{ .set = .{ .sprites = &.{}, .surface = .{ .material = undefined, .textures = .{ .{ .image = &image }, .none } } }, .sprite = .{.{}}, .at = @splat(0) };
    // Brightening, then swept along the hull: a light turns, and the one two behind goes out.
    effect.chargeLights(0.4, &going);
    try std.testing.expectEqual(@as([3]f32, @splat(0.5)), effect.lights[0].?.sprite[0].colour);
    effect.chargeLights(0.92, &going);
    try std.testing.expectEqual(&going, effect.lights[3].?.set.surface.textures[0].image);
    try std.testing.expectEqual(@as([3]f32, @splat(0)), effect.lights[1].?.sprite[0].colour);
    try std.testing.expectEqual(@as([3]f32, @splat(0.5)), effect.lights[2].?.sprite[0].colour);
}

test "Shown.with" {
    const trails: Shown = .{ .trails = true };
    try std.testing.expectEqual(Shown{ .trails = true, .flare = true }, trails.with(.{ .flare = true }));
    try std.testing.expectEqual(trails, trails.with(.{}));
}

test "Effect.squashFlare" {
    var effect: Effect = .{ .owner = 0, .flare_turn = math.rotation(.y, std.math.pi / 2.0) };
    // With no flare, nothing shows.
    try std.testing.expect(!effect.squashFlare(0));
    effect.flare = .{ .object = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} }, .width = 50 };
    // A sixth of the way, it shows at full width, half as high, stretched half as wide again
    // across, turned as it arrived.
    try std.testing.expect(effect.squashFlare(0.15));
    const flare = &effect.flare.?;
    try std.testing.expectEqual(50, flare.object.scale);
    try std.testing.expectApproxEqAbs(0.5, flare.share, 1e-5);
    try math.testing.expectMatrixWithin(math.product(effect.flare_turn, math.scaling(.{ 1.45, 0.5 + flare_thinnest, 1 })), flare.object.orientation, 1e-5);
    // Past `flare_squash` of the way, it shows no more.
    try std.testing.expect(!effect.squashFlare(flare_squash));
}

test "the flare lights what stands round it as it shows" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const ship = try mission.add(.predator, @splat(0));
    var effects: Effects = .{
        .gpa = gpa,
        .flare_mesh = try loadout.squareMesh(gpa, false, flare_size[0], flare_size[1]),
        .flare_level = undefined,
        .trail_meshes = undefined,
        .trail_levels = undefined,
        .burst_mesh = undefined,
        .burst_level = undefined,
        .light_image = undefined,
        .light_going_image = undefined,
        .hardware = true,
        .flare_colour = .{ 0.5, 0.7, 1 },
    };
    defer effects.flare_mesh.deinit(gpa);
    effects.flare_level = .{.{ .mesh = &effects.flare_mesh, .until = std.math.inf(f32) }};
    const place = (try effects.alloc(ship)).?;
    defer effects.free(place);
    const record = effects.get(place).?;
    const turned = math.rotation(.y, std.math.pi / 2.0);
    effects.startFlare(record, .{ .position = .{ 0, 0, 100 }, .orientation = turned }, 50);
    // It keeps how it is turned, for Jump In's squash.
    try std.testing.expectEqual(turned, record.flare_turn);
    record.flare.?.grow(0.5);
    record.shown = .{ .flare = true };
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    // Half of it shows, 25 across, its light half as bright and reaching ten times the ship's width.
    try effects.draw(gpa, &scene, mission.objects);
    try std.testing.expectEqual(25, record.flare.?.object.scale);
    try std.testing.expectEqual(1, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(1, scene.lights.items.len);
    try std.testing.expectEqual(0.5, scene.lights.items[0].intensity);
    try std.testing.expectEqual(500, scene.lights.items[0].kind.point.range);
    // As the original, it lights nothing.
    scene.clear();
    effects.lighting = .none;
    try effects.draw(gpa, &scene, mission.objects);
    try std.testing.expectEqual(0, scene.lights.items.len);
    // Nothing is shown until an update says so again.
    effects.beginFrame();
    scene.clear();
    try effects.draw(gpa, &scene, mission.objects);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}

test {
    std.testing.refAllDecls(@This());
}
