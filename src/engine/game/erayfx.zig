//! `C:\lancer\game\erayfx.cpp`: electric rays, jagged strands of light between two points that
//! crackle over a wreck (`explode.burnPart`) or a disrupted ship (`aifuncs.disruptedInit`). The
//! code after this file's known end, up to `0x0046AF40`, is the rays' too.
//!
//! Each strand runs through 17 points, its ends and 15 between, which stray at random each frame
//! the ray is drawn (`jitter`). Each of the 16 segments between them is a glowing cap and two quads
//! crossed along it. A ray lights the space round it with a point light at the middle of its first
//! strand.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const libcmt = @import("../libcmt.zig");
const Objects = @import("create.zig").Objects;
const gameobj = @import("gameobj.zig");
const matmanager = @import("matmanager.zig");
const objects = @import("objects.zig");
const table = @import("table.zig");
const xtrabits = @import("xtrabits.zig");

/// How many rays there is room for (`0x005531B0`).
pub const max_rays = 100;

/// The points a strand runs through, and the segments between them: its ends, then the middles
/// `jitter` fills in, halving it `jitter_depth` times.
const points = 17;
const segments = points - 1;
const jitter_depth = 4;

comptime {
    std.debug.assert(segments == 1 << jitter_depth);
}

/// A segment's vertices: its cap, then the two quads along it (`0x0046A850`).
const segment_vertices = 12;

/// How long a flickering ray stays lit at most, and dark (`0x004DC440`, `0x004DC4B8`), in ticks,
/// and how fast one that fades dims while dark, a tick (`0x004DC418` times `0x004DC584`).
const lit_at_most: f32 = 100;
const dark_at_most: f32 = 1500;
const fade_per_tick: f32 = 0.001 * 30;

/// A strand's alpha as it is made, which its brightness scales.
const strand_alpha: f32 = 0.5;

/// How far a ray's light reaches (`0x0046ACE0`), and the segment it stands at the start of: the
/// middle of the first strand.
const light_range: f32 = 10000;
const light_segment = segments / 2;

/// The texture coordinates of each quad's corners (`0x0046A850`).
const corner_uv = [4][2]f32{ .{ 0.99, 0.99 }, .{ 0.99, 0.04 }, .{ 0.04, 0.04 }, .{ 0.04, 0.99 } };

/// A segment's caps, over highlight texture 0, and its quads, over `laser2`: lit, and added to
/// what is behind them by their alpha (`0x0046A850`).
const cap_material: srapiext.Material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .add_alpha });
const quad_material = cap_material;

/// How a ray behaves (`+0x00`).
pub const Flags = packed struct(u32) {
    /// Lights up and goes dark again at random.
    flickers: bool = false,
    /// Dims while dark, where it would go out at once.
    fades: bool = false,
    /// Goes after its `life`.
    timed: bool = false,
    _unused: u29 = 0,
};

/// What a ray hangs from, whose frame its ends are in: nothing, so the world's; the root of an
/// object; or a part of one (`0x0046AE60`).
pub const Parent = union(enum) {
    world,
    object: u16,
    part: objects.PartOf,

    /// Where it stands as drawn, and the portal that cuts it, or null where it is gone.
    fn standing(parent: Parent, all: *const Objects) ?Standing {
        return switch (parent) {
            .world => .{ .place = .{} },
            .object => |index| .{ .place = all.slots[index].drawn },
            .part => |on| part: {
                const part = on.live(all) orelse break :part null;
                const object = &part.object;
                break :part .{ .place = part.drawn(), .portal = if (object.flags.portal_clipped) object.portal else null };
            },
        };
    }

    const Standing = struct {
        place: math.Place,
        portal: ?*const srapiext.Portal = null,
    };
};

/// How a ray is made (`eray_add`).
pub const Spec = struct {
    strands: u16 = 1,
    /// How many ticks it lasts, where it is timed.
    life: i32,
    /// How far each middle point strays, at most, as a share of the distance between the two
    /// points it lies between.
    jitter: f32,
    /// Half the width of each segment's cap and quads.
    width: f32,
    flags: Flags,
};

/// An electric ray (`eray_create`, `0x0046ACE0`, 0x1B0 bytes).
pub const Ray = struct {
    flags: Flags,
    /// `+0x04`.
    jitter: f32,
    /// How bright it is (`+0x08`), from nothing up to one; drawn only above nothing.
    brightness: f32 = 1,
    /// Its ends, in the frame of what it hangs from (`+0x0C`, `+0x18`).
    from: Vector = @splat(0),
    to: Vector = @splat(0),
    /// When it last moved on (`+0x24`), or null before it first does.
    moved: ?i32 = null,
    /// When it last lit or went dark (`+0x28`), how long it stays lit (`+0x2C`) and dark (`+0x30`).
    /// The game leaves the first two unset; OpenReliant starts them at nothing, so a flickering ray
    /// goes dark on its first frame.
    changed: i32 = 0,
    lit_for: i32 = 0,
    dark_for: i32,
    /// How many ticks it has left, where it is timed (`+0x34`).
    life: i32,
    /// The object it plays over (`+0x38`): it goes once the object's slot stands in.
    owner: ?u16 = null,
    /// Whether it is lit (`+0x3C`).
    lit: bool = true,
    parent: Parent = .world,
    /// Its light (`+0x40`, `Eray Light`).
    light: srlight.Light = .{ .mask = 0, .intensity = 1, .colour = .{ 0, 0, 0 }, .kind = .{ .point = .{ .position = .{ 0, 0, 0 }, .range = light_range } } },
    /// Its strands (`+0x44`, 0x48 bytes each; their count at `+0x1AC`).
    strands: []Strand,

    /// A strand: the game's 17 meshes, one a segment and one more it never places or lights; the
    /// port's one mesh of all 16 segments in the frame of what the ray hangs from, with its
    /// colours; and its alpha (`+0x44`).
    pub const Strand = struct {
        mesh: srapiext.Mesh,
        level: [1]srapiext.Level = undefined,
        object: srapiext.MeshObject = undefined,
        colours: [][4]f32,
        alpha: f32 = strand_alpha,
        /// Half the width of each segment's cap and quads.
        width: f32,

        /// Its mesh (`0x0046A850`, one a segment in the game): every segment's cap, a square
        /// `width` either way across the segment's start, then its two quads, `width` either way
        /// of the segment and crossed along it, each over the whole of its texture. Its colours
        /// start black.
        fn create(gpa: Allocator, width: f32, laser: *srtexture.Image) Allocator.Error!Strand {
            const quads = segments * 3;
            var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = quads, .vertices = segments * segment_vertices, .indices = quads * 4, .surfaces = 2 });
            errdefer mesh.deinit(gpa);
            const uv = try mesh.addCoordinates(gpa);
            // The caps come first, then the quads, so each run is a surface of its own.
            for (0..segments) |segment| {
                const first = segment * segment_vertices;
                const order = [3]usize{ segment, segments + 2 * segment, segments + 2 * segment + 1 };
                for (order, 0..) |polygon, quad| {
                    mesh.polygons[polygon] = .{ .kind = .triangle, .continues = 0, .first = @intCast(polygon * 4), .count = 4 };
                    for (0..4) |corner| {
                        mesh.indices[polygon * 4 + corner] = @intCast(first + quad * 4 + corner);
                        uv[polygon * 4 + corner] = corner_uv[corner];
                    }
                }
            }
            mesh.surfaces[0] = .{ .polygons = segments, .material = cap_material, .textures = .{ .{ .highlight = 0 }, .none } };
            mesh.surfaces[1] = .{ .polygons = segments * 2, .material = quad_material, .textures = .{ .{ .image = laser }, .none } };
            for (0..segments) |segment| shapeSegment(mesh.positions[segment * segment_vertices ..][0..segment_vertices], width, .{}, 0);
            const colours = try gpa.alloc([4]f32, mesh.positions.len);
            @memset(colours, @splat(0));
            return .{ .mesh = mesh, .colours = colours, .width = width };
        }

        fn deinit(strand: Strand, gpa: Allocator) void {
            strand.mesh.deinit(gpa);
            gpa.free(strand.colours);
        }

        /// Its object, once it stands where it stays (`mesh_object_create`'s flags `0x84800`):
        /// never culled, its mesh its own, coloured by its own colours.
        fn place(strand: *Strand) void {
            strand.level = .{.{ .mesh = &strand.mesh, .until = std.math.inf(f32) }};
            strand.object = .{
                .flags = .{ .not_culled = true, .owns_mesh = true, .baked_object = true },
                .position = @splat(0),
                .radius = 0,
                .levels = &strand.level,
                .baked = strand.colours,
            };
        }

        /// Each segment from one of `at` to the next, as the game turns and stretches its own
        /// (`mat3_look_at`), at `alpha`.
        fn shape(strand: *Strand, at: *const [points]Vector, alpha: f32) void {
            for (0..segments) |segment| {
                const along = at[segment + 1] - at[segment];
                const frame: math.Place = .{ .position = at[segment], .orientation = math.lookAt(along) };
                shapeSegment(strand.mesh.positions[segment * segment_vertices ..][0..segment_vertices], strand.width, frame, math.length(along));
            }
            for (strand.colours) |*vertex| vertex[3] = alpha;
            srapi.findBoundingBox(&strand.mesh);
            strand.object.radius = strand.mesh.radius;
        }
    };

    /// `eray_create` (`0x0046ACE0`): a ray of `spec` over `laser2`, lit, with the time it first
    /// stays dark drawn at random.
    fn create(gpa: Allocator, spec: Spec, laser: *srtexture.Image, random: *libcmt.Rand) Allocator.Error!*Ray {
        const ray = try gpa.create(Ray);
        errdefer gpa.destroy(ray);
        const strands = try gpa.alloc(Strand, spec.strands);
        errdefer gpa.free(strands);
        var made: usize = 0;
        errdefer for (strands[0..made]) |strand| strand.deinit(gpa);
        for (strands) |*strand| {
            strand.* = try .create(gpa, spec.width, laser);
            made += 1;
        }
        ray.* = .{
            .flags = spec.flags,
            .jitter = spec.jitter,
            .dark_for = drawTicks(random, dark_at_most),
            .life = spec.life,
            .strands = strands,
        };
        for (ray.strands) |*strand| strand.place();
        return ray;
    }

    /// `0x0046ADF0`.
    fn destroy(ray: *Ray, gpa: Allocator) void {
        for (ray.strands) |strand| strand.deinit(gpa);
        gpa.free(ray.strands);
        gpa.destroy(ray);
    }

    /// `0x0046AE60`: hangs it from `parent`.
    pub fn hang(ray: *Ray, parent: Parent) void {
        ray.parent = parent;
    }

    /// `0x0046AEA0`: strand `index` coloured `colour`, and the light too for the first.
    pub fn colour(ray: *Ray, index: usize, rgb: [3]f32) void {
        const strand = &ray.strands[index];
        for (strand.colours) |*vertex| vertex.* = .{ rgb[0], rgb[1], rgb[2], vertex[3] };
        if (index == 0) ray.light.colour = rgb;
    }

    /// The timing part of `0x0046AF40`, at `now`: whether it lives on. A timed ray loses the ticks
    /// since it last moved on, and goes once none are left; any goes once its owner's slot stands
    /// in. A flickering one lit past its time goes dark, or starts to fade, for up to
    /// `dark_at_most` ticks; dark past its time, it lights again, for up to `lit_at_most`. One that
    /// fades dims while dark.
    fn update(ray: *Ray, all: *const Objects, now: i32, random: *libcmt.Rand) bool {
        const ticks: f32 = @floatFromInt(if (ray.moved) |moved| now -% moved else 0);
        const moved = ray.moved orelse now;
        if (ray.flags.timed) {
            ray.life += moved -% now;
            if (ray.life < 1) return false;
        }
        if (ray.owner) |owner| if (all.slots[owner].object.type == .stand_in) return false;
        ray.moved = now;
        if (!ray.flags.flickers) return true;
        if (ray.lit) {
            if (now -% ray.changed > ray.lit_for) {
                ray.lit = false;
                if (!ray.flags.fades) ray.brightness = 0;
                ray.dark_for = drawTicks(random, dark_at_most);
                ray.changed = now;
            }
        } else {
            if (ray.flags.fades) ray.brightness = @max(ray.brightness - ticks * fade_per_tick, 0);
            if (now -% ray.changed > ray.dark_for) {
                ray.lit = true;
                ray.brightness = 1;
                ray.lit_for = drawTicks(random, lit_at_most);
                ray.changed = now;
            }
        }
        return true;
    }

    /// The drawing part of `0x0046AF40`, while it shows: each strand through its ends, its middles
    /// strayed at random, as bright as the ray, where what it hangs from stands; then its light.
    ///
    /// **Fix:** a ray hanging from a part that a split's portal cuts is cut by it too, so it shows
    /// only on what the sweep has laid bare; the game cuts the part alone, and its rays crackle
    /// over the stretch of the ship still whole.
    fn draw(ray: *Ray, gpa: Allocator, scene: *srcore.Scene, standing: Parent.Standing, random: *libcmt.Rand) Allocator.Error!void {
        const place = standing.place;
        for (ray.strands, 0..) |*strand, index| {
            var at: [points]Vector = undefined;
            at[0] = ray.from;
            at[segments] = ray.to;
            jitter(&at, 0, segments, ray.jitter, jitter_depth, random);
            strand.shape(&at, strand.alpha * ray.brightness);
            strand.object.position = place.position;
            strand.object.orientation = place.orientation;
            strand.object.portal = standing.portal;
            strand.object.flags.portal_clipped = standing.portal != null;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &strand.object }, .world);
            if (index == 0) ray.light.kind.point.position = place.point(at[light_segment]);
        }
        ray.light.intensity = 1;
        try xtrabits.sceneAdd(gpa, scene, .{ .light = &ray.light }, .world);
    }
};

/// A number of ticks up to `most`, at random.
fn drawTicks(random: *libcmt.Rand, most: f32) i32 {
    return @intFromFloat(random.fraction() * most);
}

/// A segment's corners, where `frame` puts it, `length` long: its cap at its start, then its two
/// quads along it, the first across its `Y` axis and the second its `X` (`0x0046A850`).
fn shapeSegment(corners: *[segment_vertices]Vector, width: f32, frame: math.Place, length: f32) void {
    const local = [segment_vertices]Vector{
        .{ -width, -width, 0 }, .{ width, -width, 0 },  .{ width, width, 0 },  .{ -width, width, 0 },
        .{ 0, -width, 0 },      .{ 0, -width, length }, .{ 0, width, length }, .{ 0, width, 0 },
        .{ -width, 0, 0 },      .{ -width, 0, length }, .{ width, 0, length }, .{ width, 0, 0 },
    };
    for (corners, local) |*corner, point| corner.* = frame.point(point);
}

/// `0x0046AA70`: the point halfway between points `a` and `b` of `at`, strayed at random by up to
/// `amount` of the distance between them, then, `depth` times over, the points halfway between it
/// and each of them, the nearer first.
fn jitter(at: *[points]Vector, a: usize, b: usize, amount: f32, depth: u8, random: *libcmt.Rand) void {
    const middle = (a + b) / 2;
    const off = math.normalize(random.centredVector(@splat(std.math.tau)));
    const reach = random.fraction() * math.distance(at[a], at[b]) * amount;
    at[middle] = (at[a] + at[b]) * @as(Vector, @splat(0.5)) + off * @as(Vector, @splat(reach));
    if (depth > 1) {
        jitter(at, a, middle, amount, depth - 1, random);
        jitter(at, middle, b, amount, depth - 1, random);
    }
}

/// The rays (`0x005531B0`), and the texture their quads are drawn over (`0x005531AC`).
pub const Rays = struct {
    gpa: Allocator,
    slots: [max_rays]?*Ray = @splat(null),
    laser: *srtexture.Image,

    /// `0x0046ABE0`, as a mission starts: `laser2`, and no rays.
    pub fn init(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!Rays {
        return .{ .gpa = gpa, .laser = try matmanager.textureRequire(textures, "laser2") };
    }

    /// `0x0046AC00`, as a mission ends: every ray let go.
    pub fn reset(rays: *Rays) void {
        for (&rays.slots) |*slot| {
            if (slot.*) |ray| ray.destroy(rays.gpa);
            slot.* = null;
        }
    }

    pub fn deinit(rays: *Rays) void {
        rays.reset();
    }

    /// `eray_add` (`0x0046AC50`): a ray of `spec` in the first free slot, or in the first where
    /// all are taken, letting that ray go.
    pub fn add(rays: *Rays, spec: Spec, random: *libcmt.Rand) Allocator.Error!*Ray {
        const slot = table.firstFree(*Ray, &rays.slots) orelse first: {
            rays.remove(rays.slots[0].?);
            break :first &rays.slots[0];
        };
        const ray = try Ray.create(rays.gpa, spec, rays.laser, random);
        slot.* = ray;
        return ray;
    }

    /// `eray_remove` (`0x0046ACB0`): lets `ray` go.
    pub fn remove(rays: *Rays, ray: *Ray) void {
        for (&rays.slots) |*slot| {
            if (slot.* != ray) continue;
            ray.destroy(rays.gpa);
            slot.* = null;
        }
    }

    /// `0x0046AC30`, once a frame (`mission_frame`): each ray moves on at tick `now`
    /// (`Ray.update`) and, while it is bright and what it hangs from stands in `all`, is drawn.
    /// A ray whose part has gone goes with it.
    pub fn draw(rays: *Rays, gpa: Allocator, scene: *srcore.Scene, all: *const Objects, now: i32, random: *libcmt.Rand) Allocator.Error!void {
        for (rays.slots) |maybe| {
            const ray = maybe orelse continue;
            if (!ray.update(all, now, random)) {
                rays.remove(ray);
                continue;
            }
            const standing = ray.parent.standing(all) orelse {
                rays.remove(ray);
                continue;
            };
            if (ray.brightness != 0) try ray.draw(gpa, scene, standing, random);
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

pub const testing = struct {
    /// The rays over a table holding nothing but their texture.
    pub const Built = struct {
        textures: *@import("../surrender/surrenderlib/srtexture.zig").testing.Textures,
        rays: Rays,

        pub fn init(gpa: Allocator) !Built {
            const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &.{"laser2"});
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .rays = try .init(gpa, &textures.table) };
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.rays.deinit();
            built.textures.deinit(gpa);
        }
    };
};

test jitter {
    var random: libcmt.Rand = .{};
    var at: [points]Vector = undefined;
    at[0] = @splat(0);
    at[segments] = .{ 0, 0, 1600 };

    // With nothing to stray by, the points run evenly along the line.
    jitter(&at, 0, segments, 0, jitter_depth, &random);
    for (at, 0..) |point, n| try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(n * 100)), point[2], 1e-3);

    // Straying by up to a fifth, the middle is within a fifth of the length of the line's middle,
    // and the ends stay.
    jitter(&at, 0, segments, 0.2, jitter_depth, &random);
    try std.testing.expect(math.distance(at[segments / 2], .{ 0, 0, 800 }) <= 320);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 1600 }), at[segments]);
    try std.testing.expect(math.distance(at[segments / 2], .{ 0, 0, 800 }) > 0);
}

test "a ray flickers, fades and runs out" {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    var random: libcmt.Rand = .{};
    const ray = try built.rays.add(.{ .life = 100, .jitter = 0.2, .width = 10, .flags = .{ .flickers = true, .fades = true, .timed = true } }, &random);

    // It goes dark on its first frame, and dims while dark.
    try std.testing.expect(ray.update(all, 1, &random));
    try std.testing.expect(!ray.lit);
    try std.testing.expectEqual(1, ray.brightness);
    try std.testing.expect(ray.update(all, 11, &random));
    try std.testing.expectApproxEqAbs(0.7, ray.brightness, 1e-5);

    // Past its time dark it lights again, fully; then its life runs out.
    ray.dark_for = 20;
    try std.testing.expect(ray.update(all, 25, &random));
    try std.testing.expect(ray.lit);
    try std.testing.expectEqual(1, ray.brightness);
    try std.testing.expect(!ray.update(all, 101, &random));

    // One that neither fades nor lasts goes out at once, and goes with its owner.
    const other = try built.rays.add(.{ .life = 0, .jitter = 0.2, .width = 10, .flags = .{ .flickers = true } }, &random);
    try std.testing.expect(other.update(all, 1, &random));
    try std.testing.expectEqual(0, other.brightness);
    const owner = try mission.add(.predator, @splat(0));
    other.owner = owner;
    try std.testing.expect(other.update(all, 2, &random));
    mission.objects.resetSlot(owner, &random);
    try std.testing.expect(!other.update(all, 3, &random));
}

test Rays {
    const gpa = std.testing.allocator;
    var built: testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    const rays = &built.rays;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var random: libcmt.Rand = .{};
    const spec: Spec = .{ .life = 0, .jitter = 0.2, .width = 10, .flags = .{} };

    // Room for a hundred; the next takes the first's place.
    for (0..max_rays) |_| _ = try rays.add(spec, &random);
    const first = rays.slots[0].?;
    const next = try rays.add(spec, &random);
    try std.testing.expectEqual(next, rays.slots[0].?);
    try std.testing.expect(next != first or rays.slots[1] != null);
    rays.reset();

    // Hanging from a ship, its strand and its light go into the scene where the ship stands,
    // the light at the strand's middle.
    const ship = try mission.add(.predator, .{ 0, 0, 5000 });
    const ray = try rays.add(.{ .strands = 2, .life = 0, .jitter = 0, .width = 10, .flags = .{} }, &random);
    ray.to = .{ 0, 0, 1600 };
    ray.colour(0, .{ 0.6, 1, 1 });
    ray.hang(.{ .object = ship });
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try rays.draw(gpa, &scene, mission.objects, 0, &random);
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(1, scene.lights.items.len);
    try std.testing.expectEqual([3]f32{ 0.6, 1, 1 }, scene.lights.items[0].colour);
    try std.testing.expectApproxEqAbs(5800, scene.lights.items[0].kind.point.position[2], 1e-3);

    // Each segment runs from one point to the next, its alpha the strand's.
    const strand = &ray.strands[0];
    try std.testing.expectEqual(segments * 3, strand.mesh.polygons.len);
    try std.testing.expectEqual(segments * 2, strand.mesh.surfaces[1].polygons);
    try std.testing.expectApproxEqAbs(100, strand.mesh.positions[5][2], 1e-3);
    try std.testing.expectEqual(strand_alpha, strand.colours[0][3]);
    try std.testing.expectEqual(0.6, strand.colours[0][0]);
}
