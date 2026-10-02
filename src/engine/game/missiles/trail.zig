//! The trails in `C:\lancer\game\missiles.cpp`: what a missile, or a torpedo, leaves behind it as
//! it flies, by its type's look (`missile_looks`): a ribbon, a helix of thinner ribbons round it,
//! an exhaust plume and a glow. A trail outlives its missile, fading out once the missile has
//! ended. [`missiles.md`](../../../../docs/engine/missiles.md#trails) describes them.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const Objects = @import("../create.zig").Objects;
const Slot = @import("../create.zig").Slot;
const gameobj = @import("../gameobj.zig");
const GameObject = gameobj.GameObject;
const matmanager = @import("../matmanager.zig");
const missiles = @import("../missiles.zig");
const table = @import("../table.zig");
const xtrabits = @import("../xtrabits.zig");

/// A type's look (`missile_looks`, `0x00503958`, `0x58` bytes a type), which picks the pieces of
/// its trail and colours them.
pub const Look = extern struct {
    pieces: Pieces,
    /// The ribbon's rings, and its colour, which the glow's first sprite takes too.
    segments: i32,
    colour: [3]f32,
    _unknown_14: [3]f32,
    /// **Unknown.** 0.015, 0.005 or 0.002; nothing reads it, and the ribbons fade at 0.015.
    _unknown_20: f32,
    /// The side ribbons' rings, and their colour.
    side_segments: i32,
    side_colour: [3]f32,
    _unknown_34: [3]f32,
    _unknown_40: f32,
    /// How many side ribbons wind round the trail, up to four.
    side_count: i16,
    _unknown_46: u16,
    plume_colour: [3]f32,
    _unknown_54: f32,

    /// Which pieces the trail has, and how its ribbon moves.
    pub const Pieces = packed struct(u32) {
        ribbon: bool = false,
        plume: bool = false,
        sides: bool = false,
        glow: bool = false,
        /// The ribbon widens and turns with the missile's turning.
        twist: bool = false,
        /// The ribbon's rings are stretched at random.
        jitter: bool = false,
        _: u26 = 0,
    };

    comptime {
        assert(@offsetOf(Look, "side_segments") == 0x24);
        assert(@offsetOf(Look, "side_count") == 0x44);
        assert(@offsetOf(Look, "plume_colour") == 0x48);
        assert(@sizeOf(Look) == 0x58);
    }
};

/// The executable's looks, one a missile type. The words nothing reads are left out.
pub const looks: [missiles.type_count]Look = .{
    look(.{ .ribbon = true, .glow = true, .jitter = true }, 25, .{ 0.3, 0.3, 0.6 }, .{}, .{ 1, 1, 1 }),
    look(.{ .ribbon = true, .sides = true }, 5, .{ 0.7, 0.9, 1 }, .{ .count = 3, .segments = 5, .colour = .{ 0.3, 0.7, 0.8 } }, .{ 1, 1, 1 }),
    look(.{ .ribbon = true, .plume = true }, 35, .{ 0.8, 0.6, 1 }, .{}, .{ 0.5, 0.5, 0.5 }),
    look(.{ .ribbon = true, .glow = true }, 60, .{ 0.5, 0.5, 0.5 }, .{ .count = 4 }, .{ 1, 1, 1 }),
    look(.{ .ribbon = true, .sides = true, .jitter = true }, 35, .{ 0.2, 0.1, 0.5 }, .{ .count = 3, .segments = 10, .colour = .{ 0.5, 0.5, 0.5 } }, .{ 1, 1, 1 }),
    look(.{ .ribbon = true, .twist = true, .jitter = true }, 40, .{ 1, 1, 1 }, .{}, .{ 1, 1, 1 }),
    look(.{ .ribbon = true, .glow = true, .jitter = true }, 45, .{ 0, 0, 1 }, .{}, .{ 1, 1, 1 }),
    look(.{ .ribbon = true, .plume = true }, 30, .{ 0.2, 0, 0.5 }, .{}, .{ 0, 0, 1 }),
    look(.{ .ribbon = true, .plume = true, .jitter = true }, 40, .{ 0.5, 0.5, 0.5 }, .{}, .{ 0.5, 0.5, 0.5 }),
    look(.{ .ribbon = true, .glow = true, .jitter = true }, 70, .{ 1, 1, 1 }, .{ .count = 3, .segments = 25 }, .{ 1, 1, 1 }),
    std.mem.zeroes(Look),
};

/// A look's side ribbons, where its record holds any.
const Sides = struct {
    count: i16 = 0,
    segments: i32 = 0,
    colour: [3]f32 = .{ 1, 1, 1 },
};

fn look(pieces: Look.Pieces, segments: i32, colour: [3]f32, sides: Sides, plume_colour: [3]f32) Look {
    var made = std.mem.zeroes(Look);
    made.pieces = pieces;
    made.segments = segments;
    made.colour = colour;
    made.side_segments = sides.segments;
    made.side_colour = sides.colour;
    made.side_count = sides.count;
    made.plume_colour = plume_colour;
    return made;
}

/// How many trails there is room for (`missile_trails`, `0x005887EC`).
pub const max_trails = 200;

/// The most side ribbons a trail keeps.
const max_sides = 4;

/// What a trail follows (`+0x04`, with `+0x08` and `+0x0C`).
pub const Follows = union(enum) {
    /// A missile's record (kind 1), until the missile ends.
    missile: u8,
    /// An object's slot (kind 2): a torpedo's.
    object: u16,
    /// Nothing any more: its missile has ended, and it fades out.
    nothing,
};

/// A trail (`missile_trails`, `0x48` bytes each).
pub const Trail = struct {
    /// Its missile type, which picks its look (`+0x00`).
    type: missiles.Type,
    follows: Follows,
    /// The ring the ribbon lays next, and the ring the side ribbons do (`+0x10`, `+0x14`).
    cursor: u16 = 1,
    side_cursor: u16 = 1,
    /// Its pieces (`+0x18`, `+0x1C`, `+0x2C`, `+0x30`), those its look has.
    ribbon: ?*Ribbon = null,
    sides: [max_sides]?*Ribbon = @splat(null),
    plume: ?*Plume = null,
    glow: ?*Glow = null,
    /// When the plume's texture last moved on (`+0x34`).
    scrolled: i32,
    /// The trails' list, newest first (`+0x40`, `+0x44`).
    newer: ?u8 = null,
    older: ?u8 = null,

    fn looked(trail: *const Trail) *const Look {
        return &looks[trail.type.index().?];
    }

    /// `missile_plume_update` (`0x00497DE0`): while its missile lives, the plume stands at the
    /// missile's tail, its axis wobbling up to 0.05 either way, coloured by its look at full
    /// strength, its texture turning round it by the ticks since it last did.
    fn plumeFrame(trail: *Trail, world: gameobj.World) void {
        const plume = trail.plume.?;
        plume.shown = false;
        const at = switch (trail.follows) {
            .missile => |at| at,
            .object, .nothing => return,
        };
        const slot = &(world.objects.missiles.get(at) orelse return).slot;
        plume.object.position = slot.drawn.point(.{ 0, 0, slot.object.bounds_min.z });
        // The game draws the tilt up before the one across.
        const up = world.random.centred() * plume_wobble;
        const across = world.random.centred() * plume_wobble;
        plume.object.orientation = math.product(slot.drawn.orientation, .{ 1, 0, across, 0, 1, up, 0, 0, 1 });
        plume.colour(trail.looked().plume_colour, 1);
        const turned = @as(f32, @floatFromInt(world.clock.frame_start - trail.scrolled)) * plume_scroll;
        for (plume.mesh.uv[0].?) |*corner| corner[1] += turned;
        trail.scrolled = world.clock.frame_start;
        plume.shown = true;
    }

    /// `missile_glow_update` (`0x00497980`): while its missile lives, or a Russian torpedo it
    /// follows, the glow stands 50 behind the tail, its first sprite as wide as the tail and up to
    /// a sixth more at random, its second half that.
    fn glowFrame(trail: *Trail, world: gameobj.World) void {
        const glow = trail.glow.?;
        glow.shown = false;
        const slot = followed(trail, world.objects) orelse return;
        if (trail.follows == .object and slot.object.type != .russian_torpedo) return;
        const width = slot.object.bounds_max.x * 2;
        const flickered = (world.random.fraction() * glow_flicker + 1) * width;
        glow.sprites[0].half_size = .{ flickered, flickered };
        glow.sprites[0].bias = -flickered;
        glow.sprites[1].half_size = @splat(width * 0.5);
        glow.sprites[1].bias = -width * 0.5;
        glow.set.position = slot.drawn.point(.{ 0, 0, slot.object.bounds_min.z - glow_behind });
        glow.shown = true;
    }

    /// The pieces let go of.
    pub fn release(trail: *Trail, gpa: Allocator) void {
        if (trail.ribbon) |ribbon| ribbon.destroy(gpa);
        for (&trail.sides) |*side| if (side.*) |ribbon| {
            ribbon.destroy(gpa);
            side.* = null;
        };
        if (trail.plume) |plume| plume.destroy(gpa);
        if (trail.glow) |glow| gpa.destroy(glow);
    }
};

/// The trails, and the textures they are drawn with, which `missiles_init` (`0x00494CB0`) and the
/// pieces' makers require.
pub const Trails = struct {
    gpa: Allocator,
    /// The trails, the newest first (`missile_trail_list`, `0x005887F8`).
    list: table.Linked(Trail, max_trails) = .{},
    images: Images,

    pub const Images = struct {
        /// `missiletrail\mtrail2` (`missile_trail_texture`, `0x005887C4`), the ribbons'.
        ribbon: *srtexture.Image,
        /// `shield128`, the plume's.
        plume: *srtexture.Image,
        /// `gunflare\partic6`, the glow's.
        glow: *srtexture.Image,

        pub fn load(textures: *srtexture.Table) matmanager.Error!Images {
            return .{
                .ribbon = try matmanager.textureRequire(textures, "missiletrail\\mtrail2"),
                .plume = try matmanager.textureRequire(textures, "shield128"),
                .glow = try matmanager.textureRequire(textures, "gunflare\\partic6"),
            };
        }
    };

    pub fn init(gpa: Allocator, images: Images) Trails {
        return .{ .gpa = gpa, .images = images };
    }

    pub fn deinit(trails: *Trails) void {
        trails.reset();
    }

    /// `missiles_reset`'s part (`0x00494D80`), as a mission ends: every trail let go.
    pub fn reset(trails: *Trails) void {
        trails.list.reset(trails.gpa);
    }

    pub fn get(trails: *Trails, index: usize) ?*Trail {
        return trails.list.get(index);
    }

    /// `missile_trail_create` (`0x00494E40`): a trail of `missile_type`'s look following `follows`,
    /// laid where it stands, at the head of the list; null where every trail is taken. Its side
    /// ribbons start at full strength, black, and its ribbon at nothing.
    ///
    /// **Fix:** with every trail taken, the game takes the record past the last, and writes past
    /// its pool; OpenReliant leaves the missile without a trail.
    pub fn start(trails: *Trails, world: gameobj.World, follows: Follows, missile_type: missiles.Type) Allocator.Error!?u8 {
        const style = &looks[missile_type.index() orelse return null];
        const at = trails.list.add(.{ .type = missile_type, .follows = follows, .scrolled = world.clock.frame_start }) orelse return null;
        const trail = trails.get(at).?;
        errdefer trails.list.remove(trails.gpa, at);

        const slot = followed(trail, world.objects) orelse return at;
        const tail = tailCorners(&slot.object);
        const start_at = slot.drawn.point(tail[0]);
        if (style.pieces.sides) {
            for (trail.sides[0..sideCount(style)]) |*side| {
                side.* = try .create(trails.gpa, @intCast(style.side_segments), trails.images.ribbon, start_at, 1);
            }
        }
        if (style.pieces.ribbon) trail.ribbon = try .create(trails.gpa, @intCast(style.segments), trails.images.ribbon, start_at, 0);
        if (style.pieces.plume) trail.plume = try .create(trails.gpa, trails.images.plume);
        if (style.pieces.glow) {
            const glow = try trails.gpa.create(Glow);
            glow.init(trails.images.glow, style.colour);
            trail.glow = glow;
        }
        return at;
    }

    /// `missile_trail_free` (`0x00495200`): the trail's pieces let go, and its record freed.
    fn free(trails: *Trails, at: u8) void {
        trails.list.remove(trails.gpa, at);
    }

    /// The end of `missiles_update` (`0x004960F0`), once a frame: each trail's pieces, newest
    /// first, by its look: the side ribbons (`sides`), the ribbon (`ribbonFrame`), the plume
    /// (`plumeFrame`) and the glow (`glowFrame`). A trail that fades out is freed on the way.
    pub fn frame(trails: *Trails, world: gameobj.World) void {
        var walk = trails.list.walk();
        while (walk.next()) |index| {
            const pieces = trails.get(index).?.looked().pieces;
            if (pieces.sides) trails.sidesFrame(world, index);
            if (pieces.ribbon and trails.get(index) != null) trails.ribbonFrame(world, index);
            const trail = trails.get(index) orelse continue;
            if (pieces.plume) trail.plumeFrame(world);
            if (pieces.glow) trail.glowFrame(world);
        }
    }

    /// `missile_trail_update` (`0x00495280`): the ribbon fades, and while the trail follows
    /// something, its newest ring is laid at the tail of what it follows. Once it has faded
    /// out with nothing to follow, the trail is freed.
    fn ribbonFrame(trails: *Trails, world: gameobj.World, at: u8) void {
        const trail = trails.get(at).?;
        const ribbon = trail.ribbon.?;
        const style = trail.looked();
        const colour = ribbonColour(trail, world.objects);
        const faded = ribbon.fade(world.clock.frame_duration, style.segments, colour);
        const slot = followed(trail, world.objects) orelse {
            if (faded) return trails.free(at);
            ribbon.shown = true;
            return;
        };
        const object = &slot.object;
        var corners = tailCorners(object);
        const turning = turningOf(object);
        if (style.pieces.twist) {
            const turn = math.fromAngles(0, 0, @as(f32, @floatFromInt(world.clock.frame_start)) * turning * spin_rate);
            for (&corners) |*corner| {
                corner[0] *= turning * twist_widening + 1;
                corner[1] *= flatten;
                corner.* = math.transform(turn, corner.*);
            }
        }
        if (style.pieces.jitter) for (&corners) |*corner| {
            corner[0] *= world.random.fraction() * jitter_range + jitter_least;
            corner[1] *= world.random.fraction() * jitter_range + jitter_least;
        };
        ribbon.lay(&trail.cursor, slot, corners, colour, true);
        ribbon.shown = true;
    }

    /// `missile_side_trails_update` (`0x004974B0`): each side ribbon fades, and while the trail
    /// follows something, its newest ring is laid round the tail of what it follows, a fifth of the
    /// tail's size and up to as much again, pushed out by 0.5 to 0.8 of the tail's half-width and
    /// turned about the nose by its share of the whole turn, as the missile's turning winds them
    /// round. Only the first moves the rings on, which the rest share, so they lay theirs at the
    /// ring it has just moved to. Once the last has faded out, the side ribbons are let go, or,
    /// without a ribbon, the trail is freed.
    fn sidesFrame(trails: *Trails, world: gameobj.World, at: u8) void {
        const trail = trails.get(at).?;
        const style = trail.looked();
        const count = sideCount(style);
        var faded = true;
        for (trail.sides[0..count], 0..) |side, strand| {
            const ribbon = side orelse continue;
            faded = ribbon.fade(world.clock.frame_duration, style.side_segments, style.side_colour);
            const slot = followed(trail, world.objects) orelse continue;
            const object = &slot.object;
            const turning = turningOf(object);
            const share = @as(f32, @floatFromInt(strand)) * std.math.tau / @as(f32, @floatFromInt(count));
            const turn = math.fromAngles(0, 0, share + turning * @as(f32, @floatFromInt(world.clock.frame_start)) * spin_rate);
            var corners = tailCorners(object);
            for (&corners) |*corner| {
                corner[0] = (world.random.fraction() + 1) * corner[0] * flatten;
                corner[1] = (world.random.fraction() + 1) * corner[1] * flatten;
                corner[0] += (world.random.fraction() * side_push_range + side_push_least) * object.bounds_max.x;
                corner.* = math.transform(turn, corner.*);
            }
            ribbon.lay(&trail.side_cursor, slot, corners, style.side_colour, strand == 0);
        }
        if (!faded) {
            for (trail.sides[0..count]) |side| if (side) |ribbon| {
                ribbon.shown = true;
            };
            return;
        }
        if (!style.pieces.ribbon) return trails.free(at);
        for (&trail.sides) |*side| if (side.*) |ribbon| {
            ribbon.destroy(trails.gpa);
            side.* = null;
        };
    }

    /// Adds each piece its trail's frame left shown to the world's layer.
    pub fn draw(trails: *Trails, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        var walk = trails.list.walk();
        while (walk.next()) |index| {
            const trail = trails.get(index).?;
            for (trail.sides) |side| if (side) |ribbon| if (ribbon.shown) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &ribbon.object }, .world);
            if (trail.ribbon) |ribbon| if (ribbon.shown) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &ribbon.object }, .world);
            if (trail.plume) |plume| if (plume.shown) try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &plume.object }, .world);
            if (trail.glow) |glow| if (glow.shown) try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &glow.set }, .world);
        }
    }
};

/// How the trails' rings turn with the missile's turning, a tick (`0x004DC518`); how far the
/// ribbon widens with it (`0x004DC408`), and how much of its height it and the side ribbons keep
/// (`0x004DC3F8`).
const spin_rate: f32 = 0.01;
const twist_widening: f32 = 0.5;
const flatten: f32 = 0.2;
/// A jittering ribbon's rings are stretched to 0.5 to 2 times across and up (`0x004DC4E0`,
/// `0x004DC408`).
const jitter_range: f32 = 1.5;
const jitter_least: f32 = 0.5;
/// How far out a side ribbon's rings are pushed, times the tail's half-width (`0x004DC4C0`).
const side_push_range: f32 = 0.3;
const side_push_least: f32 = 0.5;
/// How far a ribbon's ring fades a tick, for each of its rings over 0.04 of them (`0x004DC958`,
/// `0x004DC610`): a ring fades out over its ribbon's rings over 0.375 ticks.
const fade_rate: f32 = 0.015;
const fade_rings: f32 = 0.04;
/// A ribbon moves on to its next ring once its newest stands this many tail widths from the one
/// before (`0x004DC3D8`).
const ring_spacing: f32 = 3;
/// The least a ring laid is lit, however low the throttle (`0x004DC408`).
const least_brightness: f32 = 0.5;
/// A hostile torpedo's ribbon's colour.
const hostile_torpedo: [3]f32 = .{ 227.0 / 255.0, 199.0 / 255.0, 139.0 / 255.0 };

/// The slot a trail follows, the missile's own for a missile, while it still does: not a torpedo
/// that is gone.
fn followed(trail: *const Trail, all: *Objects) ?*const Slot {
    return switch (trail.follows) {
        .missile => |at| if (all.missiles.get(at)) |missile| &missile.slot else null,
        .object => |slot| if (all.slots[slot].object.type == .stand_in) null else &all.slots[slot],
        .nothing => null,
    };
}

/// How fast an object turns, which winds the trails' rings round: its yaw, pitch and roll rates
/// together.
fn turningOf(object: *const GameObject) f32 {
    return object.yaw_rate + object.pitch_rate + object.roll_rate;
}

/// The corners of an object's tail, in its own frame: its bounds' far face behind it.
fn tailCorners(object: *const GameObject) [4]Vector {
    const low = gameobj.vector(object.bounds_min);
    const high = gameobj.vector(object.bounds_max);
    return .{
        .{ high[0], high[1], low[2] },
        .{ low[0], high[1], low[2] },
        .{ low[0], low[1], low[2] },
        .{ high[0], low[1], low[2] },
    };
}

fn sideCount(style: *const Look) usize {
    return @intCast(std.math.clamp(style.side_count, 0, max_sides));
}

/// The ribbon's colour: its look's, but a hostile torpedo's own.
fn ribbonColour(trail: *const Trail, all: *const Objects) [3]f32 {
    return switch (trail.follows) {
        .object => |slot| if (trail.type == .torpedo and all.slots[slot].object.side == .hostile) hostile_torpedo else trail.looked().colour,
        .missile, .nothing => trail.looked().colour,
    };
}

/// A ribbon (`missile_trail_mesh_create`, `0x004970A0`): a ring buffer of rings of four corners,
/// the tail's, each joined to the next by two crossed quads, along the diagonals of the rings, and
/// capped by one across the next ring. The quads along take the texture's top half, from the ring
/// to the next, and the caps its bottom half. Each corner is coloured by the object's own colours,
/// added to what is behind.
const Ribbon = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [][4]f32,
    /// Whether the frame left it drawn.
    shown: bool = false,

    const material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add });
    const along_uv = [4][2]f32{ .{ 0, 0 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 } };
    const cap_uv = [4][2]f32{ .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 1 }, .{ 0, 1 } };

    /// A ribbon of `segments` rings over `image`, every corner at `at`, at `alpha`.
    fn create(gpa: Allocator, segments: usize, image: *srtexture.Image, at: Vector, alpha: f32) Allocator.Error!*Ribbon {
        const ribbon = try gpa.create(Ribbon);
        errdefer gpa.destroy(ribbon);
        const corners = segments * 4;
        ribbon.mesh = try .create(gpa, .{ .polygons = segments * 3, .vertices = corners, .indices = segments * 12 });
        errdefer ribbon.mesh.deinit(gpa);
        const uv = try ribbon.mesh.addCoordinates(gpa);
        const faces = try gpa.alloc(@import("../../../formats/shp.zig").Face.Flags, segments * 3);
        @memset(faces, .{});
        ribbon.mesh.face_flags = faces;
        ribbon.mesh.surfaces[0] = .{ .polygons = @intCast(segments * 3), .material = material, .textures = .{ .{ .image = image }, .none } };
        ribbon.mesh.numberPolygons(4);
        @memset(ribbon.mesh.positions, at);
        for (0..segments) |segment| {
            const ring: u16 = @intCast(segment * 4);
            const next: u16 = @intCast((segment * 4 + 4) % corners);
            const quads = [3][4]u16{
                .{ ring, ring + 2, next + 2, next },
                .{ ring + 1, ring + 3, next + 3, next + 1 },
                .{ next, next + 1, next + 2, next + 3 },
            };
            for (quads, 0..) |quad, i| {
                const polygon = segment * 3 + i;
                ribbon.mesh.indices[polygon * 4 ..][0..4].* = quad;
                uv[polygon * 4 ..][0..4].* = if (i == 2) cap_uv else along_uv;
            }
        }
        ribbon.colours = try gpa.alloc([4]f32, corners);
        @memset(ribbon.colours, .{ 0, 0, 0, alpha });
        ribbon.level = .{.{ .mesh = &ribbon.mesh, .until = std.math.inf(f32) }};
        ribbon.object = .{
            .flags = .{ .not_culled = true, .always_drawn = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = 0,
            .levels = &ribbon.level,
            .baked = ribbon.colours,
        };
        ribbon.shown = false;
        return ribbon;
    }

    fn destroy(ribbon: *Ribbon, gpa: Allocator) void {
        gpa.free(ribbon.colours);
        ribbon.mesh.deinit(gpa);
        gpa.destroy(ribbon);
    }

    fn ringCount(ribbon: *const Ribbon) usize {
        return ribbon.mesh.polygons.len / 3;
    }

    /// Every corner fades by the frame's ticks, over a ribbon of `rings`, and is coloured by what
    /// is left of it; whether every one has faded out. It is left undrawn.
    fn fade(ribbon: *Ribbon, frame_duration: i32, rings: i32, colour: [3]f32) bool {
        ribbon.shown = false;
        const by = @as(f32, @floatFromInt(frame_duration)) * fade_rate / (@as(f32, @floatFromInt(rings)) * fade_rings);
        var faded = true;
        for (ribbon.colours) |*corner| {
            corner[3] -= by;
            const left = if (corner[3] >= 0) left: {
                faded = false;
                break :left corner[3];
            } else 0;
            corner[0..3].* = .{ colour[0] * left, colour[1] * left, colour[2] * left };
        }
        return faded;
    }

    /// Lays the ring at `cursor` at `slot`'s tail, its corners `corners` in its frame, at full
    /// strength and as bright as its throttle, at least `least_brightness`; hides the quads from it
    /// to the next, the oldest, and shows those to it from the one before. Where `moves` it moves
    /// the cursor on once the ring stands `ring_spacing` tail widths from the one before.
    fn lay(ribbon: *Ribbon, cursor: *u16, slot: *const Slot, corners: [4]Vector, colour: [3]f32, moves: bool) void {
        const object = &slot.object;
        const rings = ribbon.ringCount();
        const first = @as(usize, cursor.*) * 4;
        const before = (first + ribbon.mesh.positions.len - 4) % ribbon.mesh.positions.len;
        const bright = @max(object.throttle, least_brightness);
        for (corners, first..) |corner, vertex| {
            ribbon.mesh.positions[vertex] = slot.drawn.point(corner);
            ribbon.colours[vertex] = .{ bright * colour[0], bright * colour[1], bright * colour[2], 1 };
        }
        const faces = ribbon.mesh.face_flags.?;
        const previous = (@as(usize, cursor.*) * 3 + faces.len - 3) % faces.len;
        for (0..3) |i| {
            faces[previous + i].cap = false;
            faces[@as(usize, cursor.*) * 3 + i].cap = true;
        }
        // The game adds the first texture coordinate of the quad before, which is always 0.
        const width = object.width();
        const apart = math.distance(ribbon.mesh.positions[first], ribbon.mesh.positions[before]);
        if (moves and apart / width > ring_spacing) cursor.* = @intCast((cursor.* + 1) % rings);
    }
};

/// The exhaust plume (`missile_plume_create`, `0x00497AA0`, "Missilebursttrail mesh"): six rings of
/// nine corners behind the tail, widening from nothing at its mouth to 210 at 630 behind, joined by
/// triangles, over `shield128` scaled by the alpha, and coloured by the object's own colours.
const Plume = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    colours: [][4]f32,
    shown: bool = false,

    const rings = 6;
    const spokes = 9;
    const material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add_alpha });
    /// How far apart the rings stand, and where the last does; how wide they grow, by the sine of
    /// `widen_step` of a quarter turn a ring (`0x004DC588`, `0x004DC3F0`); and how far a texture
    /// coordinate runs along it and round it (`0x004DC97C`, `0x004DC96C`, `0x004DC584`,
    /// `0x004DC974`, `0x004DC970`).
    const spacing: f32 = 90;
    const last_behind: f32 = 630;
    const widen_step: f32 = 0.2;
    const widening: f32 = 180;
    const least_width: f32 = 30;
    const along_scale: f32 = 1.0 / 1500.0;
    const round_scale: f32 = 1.0 / (4 * std.math.pi);

    /// **Fix:** the mouth's corners all stand at its centre, and the game works their texture
    /// coordinates round it out as a nought over a nought, which is not a number; OpenReliant gives
    /// them 0.
    fn create(gpa: Allocator, image: *srtexture.Image) Allocator.Error!*Plume {
        const plume = try gpa.create(Plume);
        errdefer gpa.destroy(plume);
        const triangles = (rings - 1) * spokes * 2;
        plume.mesh = try .create(gpa, .{ .polygons = triangles, .vertices = rings * spokes + 1, .indices = triangles * 3 });
        errdefer plume.mesh.deinit(gpa);
        const uv = try plume.mesh.addCoordinates(gpa);
        plume.mesh.surfaces[0] = .{ .polygons = triangles, .material = material, .textures = .{ .{ .image = image }, .none } };
        plume.mesh.positions[0] = @splat(0);
        for (0..rings) |ring| {
            const k: f32 = @floatFromInt(ring);
            const width: f32 = if (ring == 0) 0 else @sin(k * widen_step * (std.math.pi / 2.0)) * widening + least_width;
            const behind: f32 = if (ring == rings - 1) -last_behind else -k * spacing;
            for (0..spokes) |spoke| {
                const angle = @as(f32, @floatFromInt(spoke)) * std.math.tau / spokes;
                plume.mesh.positions[1 + ring * spokes + spoke] = .{ @sin(angle) * width, @cos(angle) * width, behind };
            }
        }
        plume.mesh.numberPolygons(3);
        var polygon: usize = 0;
        for (1..rings) |ring| {
            const inner: u16 = @intCast(1 + (ring - 1) * spokes);
            const outer: u16 = @intCast(1 + ring * spokes);
            for (0..spokes) |spoke| {
                const here: u16 = @intCast(spoke);
                const next: u16 = @intCast((spoke + 1) % spokes);
                plume.mesh.indices[polygon * 3 ..][0..6].* = .{ inner + here, outer + here, inner + next, inner + next, outer + here, outer + next };
                polygon += 2;
            }
        }
        // The first triangle keeps no texture coordinates.
        for (plume.mesh.indices[3..], uv[3..]) |index, *corner| {
            const at = plume.mesh.positions[index];
            const round = std.math.atan(at[0] / at[1]);
            corner.* = .{ at[2] * along_scale, if (std.math.isNan(round)) 0 else round * round_scale };
        }
        srapi.calcPolyNormals(&plume.mesh);
        srapi.findBoundingBox(&plume.mesh);
        plume.colours = try gpa.alloc([4]f32, plume.mesh.positions.len);
        @memset(plume.colours, .{ 0, 0, 0, 0 });
        plume.level = .{.{ .mesh = &plume.mesh, .until = std.math.inf(f32) }};
        plume.object = .{
            .flags = .{ .normals_second = true, .not_culled = true, .owns_mesh = true, .baked_object = true },
            .position = @splat(0),
            .radius = plume.mesh.radius,
            .levels = &plume.level,
            .baked = plume.colours,
        };
        plume.shown = false;
        return plume;
    }

    /// How much less of its colour each nine of the plume's corners takes (`0x004DC420`).
    const fade_step: f32 = 0.1;

    fn destroy(plume: *Plume, gpa: Allocator) void {
        gpa.free(plume.colours);
        plume.mesh.deinit(gpa);
        gpa.destroy(plume);
    }

    /// `missile_plume_colour` (`0x00497D60`): its corners coloured, a nine at a time from the
    /// first, at half of `colour` times `brightness` down to nothing, `fade_step` less each nine.
    /// **Quirk:** the corners go by nines from the centre of the mouth, not from its ring, so each
    /// ring's last corner takes the next ring's colour, and the last corner none.
    fn colour(plume: *Plume, tint: [3]f32, brightness: f32) void {
        for (plume.colours[0 .. rings * spokes], 0..) |*corner, vertex| {
            const share = @as(f32, @floatFromInt(rings - 1 - vertex / spokes)) * brightness * fade_step;
            corner.* = .{ share * tint[0], share * tint[1], share * tint[2], 1 };
        }
    }
};

/// How far the plume's axis wobbles, a frame, times a draw from -0.5 to 0.5 (`0x004DC420`), and
/// how far its texture turns round it a tick (`0x004DC980`).
const plume_wobble: f32 = 0.1;
const plume_scroll: f32 = 0.091;

/// The glow (`missile_glow_create`, `0x00497450`, "MissileTrail BMO"): two sprites over
/// `gunflare\partic6`, coloured and added, one of the look's colour and one white.
const Glow = struct {
    set: srapiext.SpriteSet,
    sprites: [2]srapiext.Sprite,
    shown: bool = false,

    fn init(glow: *Glow, image: *srtexture.Image, tint: [3]f32) void {
        glow.sprites = .{ .{ .colour = tint }, .{ .colour = .{ 1, 1, 1 } } };
        glow.set = .{
            .surface = .glow(image),
            .sprites = &glow.sprites,
        };
        glow.shown = false;
    }
};

/// How far behind the tail the glow stands, and how much wider than the tail its first sprite
/// flickers to at most (`0x004DC48C`, `0x004DC968`).
const glow_behind: f32 = 50;
const glow_flicker: f32 = 1.0 / 6.0;

const testing = struct {
    /// Trails over small textures of their own names, in an armed mission.
    const Stage = struct {
        armed: missiles.testing.Armed,
        textures: *@import("../../surrender/surrenderlib/srtexture.zig").testing.Textures,
        trails: Trails,

        fn init(stage: *Stage) !void {
            const gpa = std.testing.allocator;
            try stage.armed.init(gpa);
            errdefer stage.armed.deinit();
            stage.textures = try .init(gpa, &.{ "mtrail2", "shield128", "partic6" });
            stage.trails = .init(gpa, try .load(&stage.textures.table));
            stage.armed.mission.clock.frame_duration = 1;
        }

        fn deinit(stage: *Stage) void {
            stage.trails.deinit();
            stage.textures.deinit(std.testing.allocator);
            stage.armed.deinit();
        }

        fn world(stage: *Stage) gameobj.World {
            var reached = stage.armed.mission.world();
            reached.trails = &stage.trails;
            return reached;
        }
    };
};

test "a trail's pieces" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const ship = try stage.armed.add(.friendly, @splat(0));

    // A Raptor's: a ribbon of 5 rings and three side ribbons, every corner at the tail's first.
    missiles.launch(world, ship, 0, .none);
    const raptor = stage.trails.get(stage.armed.missile(0).trail.?).?;
    const ribbon = raptor.ribbon.?;
    try std.testing.expectEqual(15, ribbon.mesh.polygons.len);
    try std.testing.expectEqual(20, ribbon.mesh.positions.len);
    try std.testing.expectEqual(ribbon.mesh.positions[0], ribbon.mesh.positions[19]);
    try std.testing.expect(raptor.sides[2] != null and raptor.sides[3] == null);
    try std.testing.expectEqual(1, raptor.sides[0].?.colours[0][3]);
    try std.testing.expectEqual(0, ribbon.colours[0][3]);
    try std.testing.expect(raptor.plume == null and raptor.glow == null);
    // The quads from the last ring join the first.
    try std.testing.expectEqualSlices(u16, &.{ 16, 18, 2, 0 }, ribbon.mesh.indices[4 * 12 ..][0..4]);

    // A Havoc's: a ribbon and a plume, of six rings, the last 630 behind and 210 across.
    missiles.launch(world, ship, 1, .none);
    const havoc = stage.trails.get(stage.armed.missile(1).trail.?).?;
    const plume = havoc.plume.?;
    try std.testing.expectEqual(90, plume.mesh.polygons.len);
    try std.testing.expectApproxEqAbs(-630, plume.mesh.positions[54][2], 1e-3);
    try std.testing.expectApproxEqAbs(210, math.length(plume.mesh.positions[46] * Vector{ 1, 1, 0 }), 1e-3);
    // Its colours step down by nines from the mouth.
    plume.colour(.{ 1, 1, 1 }, 1);
    try std.testing.expectApproxEqAbs(0.5, plume.colours[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(0.4, plume.colours[9][0], 1e-6);
    try std.testing.expectEqual(0, plume.colours[54][3]);
}

test "Trails.frame" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const clock = &stage.armed.mission.clock;
    const ship = try stage.armed.add(.friendly, @splat(0));
    missiles.launch(world, ship, 0, .none);
    const at = stage.armed.missile(0).trail.?;
    const trail = stage.trails.get(at).?;
    const ribbon = trail.ribbon.?;

    // Each frame lays the newest ring at the tail, burning at its throttle, and moves on once the
    // missile has flown three tail widths from the ring before.
    missiles.frame(world, 0);
    try std.testing.expect(ribbon.shown);
    try std.testing.expectEqual(1, ribbon.colours[4][3]);
    try std.testing.expectEqual(2 * looks[1].colour[0], ribbon.colours[4][0]);
    try std.testing.expect(ribbon.mesh.face_flags.?[3].cap and !ribbon.mesh.face_flags.?[0].cap);
    var frames: u16 = 0;
    while (trail.cursor == 1 and frames < 50) : (frames += 1) {
        clock.frame_start += 1;
        missiles.move(world.objects);
        missiles.frame(world, 1);
    }
    try std.testing.expectEqual(2, trail.cursor);
    // Its missile ended, it fades out, a ring over five rings over 0.375 ticks, and is freed.
    missiles.end(world, 0);
    try std.testing.expectEqual(Follows.nothing, trail.follows);
    for (0..20) |_| missiles.frame(world, 0);
    try std.testing.expectEqual(null, stage.trails.list.newest);
}

test "Trails.start" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const ship = try stage.armed.add(.friendly, @splat(0));
    // With every trail taken, a missile flies without one.
    for (&stage.trails.list.records) |*record| record.* = .{ .type = .none, .follows = .nothing, .scrolled = 0 };
    missiles.launch(world, ship, 1, .none);
    try std.testing.expectEqual(null, stage.armed.missile(0).trail);
    for (&stage.trails.list.records) |*record| record.* = null;
}

test Look {
    // The Screamer's ribbon jitters and has a glow; the fuel pod leaves nothing.
    try std.testing.expectEqual(@as(u32, 0x29), @as(u32, @bitCast(looks[0].pieces)));
    try std.testing.expectEqual(@as(u32, 0x31), @as(u32, @bitCast(looks[5].pieces)));
    try std.testing.expectEqual(70, looks[9].segments);
    try std.testing.expectEqual(0, @as(u32, @bitCast(looks[10].pieces)));
}

test turningOf {
    var object = gameobj.testing.object();
    object.yaw_rate = 0.25;
    object.pitch_rate = -0.5;
    object.roll_rate = 1;
    try std.testing.expectEqual(0.75, turningOf(&object));
}
