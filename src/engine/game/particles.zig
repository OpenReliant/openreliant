//! `C:\lancer\game\particles.cpp`: particles, sprites that fly off an emitter and change size and
//! colour over their life. A template says how its particles live, and an emitter sends them out of
//! it, all at once (`Pool.burst`) or over its own life (`Pool.stream`). A particle comes from its
//! template's pool, drawn as one set of sprites over the pool's texture, coloured by each sprite's
//! colour. A template of kind `sometimes_sparks` or `sparks` sends sparks as well, which are
//! `explode.cpp`'s small bits of debris (`explode.Explosions.throwSpark`).
//!
//! **Not ported:** what `particles_frame` runs first (`0x004A1BB0`).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const math = @import("../surrender/math.zig");
const Matrix = math.Matrix;
const Place = math.Place;
const Vector = math.Vector;
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const Random = @import("../random.zig").Random;
const explode = @import("explode.zig");
const matmanager = @import("matmanager.zig");
const xtrabits = @import("xtrabits.zig");
const Clock = @import("main.zig").Clock;

/// A quadratic over a particle's life, from 0 at its birth to 1 at its end.
pub const Curve = extern struct {
    a: f32,
    b: f32,
    c: f32,

    /// `particle_curve_set` (`0x0049C180`): the curve through `start`, `middle` and `end` at the
    /// beginning, halfway and the end.
    pub fn through(start: f32, middle: f32, end: f32) Curve {
        return .{ .a = start + end + start + end - middle * 4, .b = middle * 4 - (start * 3 + end), .c = start };
    }

    /// Its value `t` of the way through, summed as the game sums it.
    pub fn at(curve: Curve, t: f32) f32 {
        return curve.b * t + curve.a * t * t + curve.c;
    }

    comptime {
        assert(@offsetOf(Curve, "a") == 0x00);
        assert(@offsetOf(Curve, "b") == 0x04);
        assert(@offsetOf(Curve, "c") == 0x08);
        assert(@sizeOf(Curve) == 0x0C);
    }
};

/// How a template's particles live (`particle_template_create`, `0x0049C5D0`).
pub const Template = extern struct {
    kind: Kind = .particles,
    /// How long each particle lives, in ticks, and up to how many more at random.
    life: i32,
    life_spread: i32 = 0,
    /// How many particles a tick an emitter streams, in hundredths, over its own life.
    rate: Curve = .through(0, 0, 0),
    /// A particle's half-size, and its red, green and blue, over its life.
    size: Curve,
    colour: [3]Curve,
    /// The pool it draws from. OpenReliant hands a burst or a stream its pool instead.
    pool: Pointer(anyopaque) = .null,
    /// How much a burst thins with distance; none at zero.
    distance: f32 = 1,

    pub const Kind = enum(u32) {
        particles = 0,
        /// Particles, and a spark one time in `spark_odds`.
        sometimes_sparks = 1,
        sparks = 2,

        /// What a stream sends on one of its turns.
        fn roll(kind: Kind, random: *Random) Sent {
            return switch (kind) {
                .particles => .particle,
                .sparks => .spark,
                .sometimes_sparks => if (random.rand() % spark_odds != 0) .particle else .spark,
            };
        }

        /// A template that sometimes sparks sends a spark one time in this many
        /// (`particle_stream`).
        const spark_odds = 200;
    };

    pub const Sent = enum { particle, spark };

    /// How far a burst or a stream is thinned: its particles' half-size halfway through their
    /// life, times this, over their distance (`0x004DC594`).
    const thin_by: f32 = 150;

    /// A stream's rate, from hundredths (`0x004DC730`).
    const rate_scale: f32 = 0.01;

    comptime {
        assert(@offsetOf(Template, "life") == 0x04);
        assert(@offsetOf(Template, "rate") == 0x0C);
        assert(@offsetOf(Template, "size") == 0x18);
        assert(@offsetOf(Template, "colour") == 0x24);
        assert(@offsetOf(Template, "pool") == 0x48);
        assert(@offsetOf(Template, "distance") == 0x4C);
        assert(@sizeOf(Template) == 0x50);
    }

    /// How many of `count` particles an emitter at `offset` from `view` sends, where they are
    /// thinned over `over`, or not at all where it is null: half of them behind the camera, and a
    /// share by their half-size halfway through their life times `thin_by` over it, at most all.
    fn thinned(template: *const Template, count: i32, offset: Vector, view: Place, over: ?f32) i32 {
        const behind = math.dot(offset, math.forward(view.orientation)) < 0;
        const facing = if (behind) @divTrunc(count, 2) else count;
        const full = template.size.at(0.5) * thin_by;
        const share = @min(if (over) |by| full / by else full, 1);
        return math.round(@as(f32, @floatFromInt(facing)) * share);
    }
};

/// Where `now` is in a life from `born`, `life` ticks long, as a share of it.
pub fn through(now: i32, born: i32, life: i32) f32 {
    return @as(f32, @floatFromInt(now - born)) / @as(f32, @floatFromInt(life));
}

/// What sends particles out (`particle_emitter_create`, `0x0049C600`, 0xFC bytes).
pub const Emitter = struct {
    /// How long it streams, in ticks from its birth (`+0x00`, `+0x04`).
    life: i32 = 0,
    born: i32,
    /// Where it stands from its parent, or in the world where it has none: its own frame's place
    /// (`+0x08`, the frame's `+0x18` and `+0x3C`).
    place: Place = .{},
    /// Where that puts it in the world, which it works out each time it sends particles out (the
    /// frame's `+0x4C` and `+0x70`).
    world: Place = .{},
    /// Which way its particles leave, in its own frame, and how far they stray from it along each
    /// axis, half of it either way (`+0xBC`, `+0xC8`).
    direction: Vector = @splat(0),
    spread: Vector = @splat(0),
    /// How fast they leave, a tick: `speed` and up to `speed_range` more (`+0xD4`, `+0xD8`).
    speed: f32 = 0,
    speed_range: f32 = 0,
    /// Added to each particle's velocity, a tick: what it carries of what it leaves (`+0xDC`).
    inherited: Vector = @splat(0),
    /// The span of the texture its particles show: left, right, top and bottom (`+0xE8`).
    uv: [4]f32 = .{ 0, 1, 0, 1 },
    template: *const Template,

    /// Works out where it stands in the world, from `parent`'s place where it hangs from one.
    fn stand(emitter: *Emitter, parent: ?Place) void {
        emitter.world = if (parent) |from| emitter.place.within(from) else emitter.place;
    }

    /// How fast something leaves it: along `direction`, strayed by `spread`, at a speed from
    /// `speed`, turned into the world.
    fn leaving(emitter: *const Emitter, random: *Random) Vector {
        var v = random.centredVector(emitter.spread) + emitter.direction;
        const length = math.length(v);
        if (length > 0) v *= @splat((random.fraction() * emitter.speed_range + emitter.speed) / length);
        return math.transform(emitter.world.orientation, v);
    }

    /// A particle's velocity from it: how fast it leaves, plus what it inherits.
    fn velocity(emitter: *const Emitter, random: *Random) Vector {
        return emitter.leaving(random) + emitter.inherited;
    }

    /// `particle_spark` (`0x0049C340`): a spark from where it stands, as fast as a particle leaves
    /// but inheriting nothing, its velocity a second's.
    fn spark(emitter: *const Emitter, explosions: *explode.Explosions, clock: *const Clock, random: *Random) void {
        const velocity_per_second = emitter.leaving(random) * @as(Vector, @splat(@import("main.zig").ticks_per_second));
        explosions.throwSpark(emitter.world.position, velocity_per_second, clock, random);
    }
};

/// What a burst or a stream is sent out with: the camera's place, which thins it, the clock and the
/// numbers, and the explosions its sparks go to, which are left out where there are none.
pub const Sending = struct {
    view: Place,
    clock: *const Clock,
    random: *Random,
    explosions: ?*explode.Explosions = null,
};

/// A particle's record (0x18 bytes); its sprite is the one of the same index.
pub const Particle = struct {
    /// When it was born and how long it lives, in ticks.
    born: i32 = 0,
    life: i32 = 0,
    /// How far it moves a tick.
    velocity: Vector = @splat(0),
    template: ?*const Template = null,
    /// Where it is at the frame's tick. The game keeps it in the particle's sprite; OpenReliant
    /// draws the sprite from it, further along between the ticks (`Pool.draw`).
    at: Vector = @splat(0),
    /// OpenReliant's: its size and its shade, as shares of its template's (`Pool.Variety`).
    scale: f32 = 1,
    shade: f32 = 1,

    /// The tick its life ends at: it is alive before it, and free after it, or from it on for a
    /// stream.
    fn end(particle: Particle) i32 {
        return particle.born + particle.life;
    }
};

/// A pool particles come from: one of the ten `particle_pools` (`0x0058A948`). The explosions'
/// particles come from the game's own (`particle_pool`, `0x0058A94C`), and each level of a damaged
/// ship's smoke has one (`smoke.Pools`).
pub const Pool = struct {
    gpa: Allocator,
    particles: []Particle,
    sprites: []srapiext.Sprite,
    /// Drawn with as many of `sprites` as `used`.
    set: srapiext.SpriteSet,
    settings: Settings = .{},
    /// What gives a particle its own size and shade where the pool varies them. The game's `rand`
    /// is left as it would be.
    varying: std.Random.DefaultPrng = .init(0),
    /// One past the last particle alive at the last frame (`+0x0C`), up to which the frame looks.
    used: u32 = 0,

    /// How a pool sends and draws its particles where OpenReliant does more than the game.
    pub const Settings = struct {
        /// Whether what goes out far from the camera is thinned.
        distant: Distant = .whole,
        variety: Variety = .alike,
    };

    /// How a burst or a stream far from the camera is sent, and the room the pool has for it.
    ///
    /// **Improvement:** `whole` sends all of it, into a pool four times the game's, where the game
    /// thins bursts and streams by their distance to spare the fill rate of its day; the half
    /// behind the camera is left out either way. `--original` restores the game's.
    pub const Distant = enum {
        thinned,
        whole,

        /// The room for a pool the game makes of `count` particles.
        pub fn size(distant: Distant, count: usize) usize {
            return switch (distant) {
                .thinned => count,
                .whole => count * whole_room,
            };
        }

        const whole_room = 4;
    };

    /// How alike the particles of a template are at the same age.
    ///
    /// **Improvement:** `varied` gives each particle a size of its own, from three quarters to one
    /// and a quarter of its template's, and a shade of its own, from 0.85 to 1.15 of its colour, so
    /// that a dense stream of the same soft sprite does not look even. The game draws them alike;
    /// `--original` restores that.
    pub const Variety = enum {
        alike,
        varied,

        const sizes: [2]f32 = .{ 0.75, 1.25 };
        const shades: [2]f32 = .{ 0.85, 1.15 };

        /// A number between `range`'s two, by `numbers`.
        fn within(range: [2]f32, numbers: std.Random) f32 {
            return math.lerp(range[0], range[1], numbers.float(f32));
        }
    };
    /// How a pool's sprites are drawn, as `particle_pool_create` is given it: how many the game's
    /// pool holds, the texture they show, whether they are coloured by their own colours or show
    /// their texture's, and how they combine with what is drawn.
    pub const Look = struct {
        count: usize = 1000,
        image: []const u8,
        coloured: bool = true,
        blend: srapiext.Material.Blend,

        /// The game's own pool's: `gunflare\partic4`, added (`particles_init`, `0x0049BF60`).
        pub const standard: Look = .{ .image = "gunflare\\partic4", .blend = .add };
    };

    /// `particle_pool_create` (`0x0049C050`): the pool of `count` particles over `image`, their
    /// sprites showing the whole texture, coloured by each sprite's colour and combined with what
    /// is drawn by `blend`.
    pub fn init(gpa: Allocator, count: usize, image: *srtexture.Image, blend: srapiext.Material.Blend) Allocator.Error!Pool {
        const particles = try gpa.alloc(Particle, count);
        errdefer gpa.free(particles);
        const sprites = try gpa.alloc(srapiext.Sprite, count);
        @memset(particles, .{});
        @memset(sprites, .{});
        var set: srapiext.SpriteSet = .{ .sprites = sprites[0..0] };
        set.surface.material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = blend });
        set.surface.textures = .{ .{ .image = image }, .none };
        return .{ .gpa = gpa, .particles = particles, .sprites = sprites, .set = set };
    }

    /// A pool that looks as `look` says, over the texture it requires, sized for how it sends what
    /// is far off.
    pub fn load(gpa: Allocator, textures: *srtexture.Table, look: Look, settings: Settings) (Allocator.Error || matmanager.Error)!Pool {
        var pool: Pool = try .init(gpa, settings.distant.size(look.count), try matmanager.textureRequire(textures, look.image), look.blend);
        pool.set.surface.material.lit[0] = look.coloured;
        pool.settings = settings;
        return pool;
    }

    /// `particles_shutdown` (`0x0049C010`) and `particle_pool_free` (`0x0049C140`).
    pub fn deinit(pool: *Pool) void {
        pool.gpa.free(pool.particles);
        pool.gpa.free(pool.sprites);
    }

    /// `particles_reset` (`0x0049BFB0`), as a mission starts or ends: every particle free.
    pub fn reset(pool: *Pool) void {
        @memset(pool.particles, .{});
        pool.show(0);
    }

    /// Draws the set up to `used` of its sprites.
    fn show(pool: *Pool, used: u32) void {
        pool.used = used;
        pool.set.sprites = pool.sprites[0..used];
    }

    /// `particle_emit` (`0x0049C1C0`): particle `index` born from `emitter`, now, where the emitter
    /// stands.
    pub fn emit(pool: *Pool, emitter: *const Emitter, index: usize, clock: *const Clock, random: *Random) void {
        if (pool.used <= index) pool.used = @intCast(index + 1);
        const template = emitter.template;
        const spread = if (template.life_spread > 0) @rem(@as(i32, random.rand()), template.life_spread) else 0;
        var particle: Particle = .{
            .born = clock.frame_start,
            .life = template.life + spread,
            .template = template,
            .velocity = emitter.velocity(random),
            .at = emitter.world.position,
        };
        if (pool.settings.variety == .varied) {
            const numbers = pool.varying.random();
            particle.scale = Variety.within(Variety.sizes, numbers);
            particle.shade = Variety.within(Variety.shades, numbers);
        }
        pool.particles[index] = particle;
        pool.sprites[index].offset = emitter.world.position;
        pool.sprites[index].uv = emitter.uv;
    }

    /// `particle_burst` (`0x0049C450`): `count` particles from `emitter` at once, into the free
    /// ones, where `parent` puts it, thinned by the emitter's distance times its template's.
    pub fn burst(pool: *Pool, emitter: *Emitter, parent: ?Place, count: i32, sending: Sending) void {
        emitter.stand(parent);
        const template = emitter.template;
        const offset = emitter.world.position - sending.view.position;
        const thinned = pool.settings.distant == .thinned and template.distance > 0;
        var left = template.thinned(count, offset, sending.view, if (thinned) math.length(offset) * template.distance else null);
        for (pool.particles, 0..) |particle, index| {
            if (left < 1) return;
            if (particle.end() < sending.clock.frame_start) {
                pool.emit(emitter, index, sending.clock, sending.random);
                left -= 1;
            }
        }
    }

    /// `particle_stream` (`0x0049C680`): what `emitter` sends out over the frame, by its template's
    /// rate at this point in its life, a roll a tick, each particle moved on as if it had left at
    /// the frame's start. Thinned by its distance alone, from where it stood last. The template's
    /// kind rolls for each particle of the pool it passes, free or not, and a spark it rolls is
    /// thrown on top of the particles sent. Whether the emitter still lives.
    pub fn stream(pool: *Pool, emitter: *Emitter, parent: ?Place, sending: Sending) bool {
        const clock = sending.clock;
        const random = sending.random;
        const now = clock.frame_start;
        if (emitter.life + emitter.born <= now) return false;
        const template = emitter.template;
        const chance = template.rate.at(through(now, emitter.born, emitter.life)) * Template.rate_scale;
        if (!(chance > 0) or clock.frame_duration <= 0) return true;
        var rolled: i32 = 0;
        for (0..@intCast(clock.frame_duration)) |_| {
            if (random.fraction() < chance) rolled += 1;
        }
        if (rolled == 0) return true;
        const offset = emitter.world.position - sending.view.position;
        var left = template.thinned(rolled, offset, sending.view, if (pool.settings.distant == .thinned) math.length(offset) else null);
        emitter.stand(parent);
        const ticks: Vector = @splat(@floatFromInt(clock.frame_duration));
        for (pool.particles, 0..) |particle, index| {
            if (left < 1) return true;
            switch (template.kind.roll(random)) {
                .particle => if (particle.end() <= now) {
                    pool.emit(emitter, index, clock, random);
                    // The game draws a number here that it does not use.
                    _ = random.rand();
                    pool.particles[index].at += pool.particles[index].velocity * ticks;
                    left -= 1;
                },
                .spark => if (sending.explosions) |explosions| emitter.spark(explosions, clock, random),
            }
        }
        return true;
    }

    /// `particles_frame` (`0x0049C8E0`), once a frame after the shots': each particle alive moves
    /// on by its velocity and takes its size and colour from its template's curves at this point
    /// in its life; the others are hidden, and the set drawn stops after the last alive.
    /// **Unverified:** it lies just after this file's known code.
    pub fn frame(pool: *Pool, clock: *const Clock) void {
        const now = clock.frame_start;
        const ticks: Vector = @splat(@floatFromInt(clock.frame_duration));
        var last: u32 = 0;
        for (pool.particles[0..pool.used], pool.sprites[0..pool.used], 0..) |*particle, *sprite, index| {
            const alive = if (now < particle.end()) particle.template else null;
            const template = alive orelse {
                sprite.hidden = true;
                continue;
            };
            particle.at += particle.velocity * ticks;
            const t = through(now, particle.born, particle.life);
            const half = template.size.at(t) * particle.scale;
            sprite.half_size = .{ half, half };
            for (&sprite.colour, template.colour) |*channel, curve| channel.* = std.math.clamp(curve.at(t) * particle.shade, 0, 1);
            sprite.hidden = false;
            last = @intCast(index);
        }
        pool.show(last + 1);
    }

    /// The rest of `particles_frame`: the set goes into the world's layer, each particle `ahead`
    /// of a tick along from where it was at the frame's tick.
    ///
    /// **Improvement:** the game draws them where the tick left them, which moves them on in
    /// hundredths of a second that a display's frames fall between unevenly.
    pub fn draw(pool: *Pool, gpa: Allocator, scene: *srcore.Scene, ahead: f32) Allocator.Error!void {
        if (pool.used == 0) return;
        const past: Vector = @splat(ahead);
        for (pool.particles[0..pool.used], pool.sprites[0..pool.used]) |particle, *sprite| {
            if (!sprite.hidden) sprite.offset = particle.at + particle.velocity * past;
        }
        try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &pool.set }, .world);
    }
};

test through {
    // A quarter of a life of 100 ticks from tick 10, and past its end.
    try std.testing.expectEqual(0.25, through(35, 10, 100));
    try std.testing.expectEqual(1.5, through(160, 10, 100));
}

test Curve {
    const curve: Curve = .through(1, 0.25, 0);
    try std.testing.expectApproxEqAbs(1, curve.at(0), 1e-6);
    try std.testing.expectApproxEqAbs(0.25, curve.at(0.5), 1e-6);
    try std.testing.expectApproxEqAbs(0, curve.at(1), 1e-6);
}

test "Template.Kind.roll" {
    var random: Random = .{};
    var sparks: usize = 0;
    for (0..20000) |_| {
        if (Template.Kind.sometimes_sparks.roll(&random) == .spark) sparks += 1;
    }
    // One time in 200, near enough.
    try std.testing.expect(sparks > 50 and sparks < 150);
    try std.testing.expectEqual(Template.Sent.particle, Template.Kind.particles.roll(&random));
}

pub const testing = struct {
    const template: Template = .{
        .life = 100,
        .size = .through(10, 20, 30),
        .colour = .{ .through(1, 0.5, 0), .through(1, 1, 1), .through(0, 0, 0) },
        .distance = 0,
    };

    fn pool() !Pool {
        var image: srtexture.Image = undefined;
        return .init(std.testing.allocator, 8, &image, .add);
    }

    /// How many of the pool's particles are in use.
    pub fn sent(from: *const Pool) usize {
        var count: usize = 0;
        for (from.particles) |particle| count += @intFromBool(particle.template != null);
        return count;
    }
};

test "Pool.burst" {
    var pool = try testing.pool();
    defer pool.deinit();
    var clock: Clock = .{};
    clock.frame_start = 10;
    var random: Random = .{};
    var emitter: Emitter = .{
        .born = clock.frame_start,
        .template = &testing.template,
        .place = .{ .position = .{ 0, 0, 1000 } },
        .spread = .{ 1, 1, 1 },
        .speed = 5,
        .inherited = .{ 0, 0, 1 },
    };
    const sending: Sending = .{ .view = .{}, .clock = &clock, .random = &random };

    // Ahead of the camera, the whole burst, each particle leaving where the emitter stands at its
    // speed plus what it inherits.
    pool.burst(&emitter, null, 3, sending);
    try std.testing.expectEqual(3, pool.used);
    try std.testing.expectEqual(3, testing.sent(&pool));
    try std.testing.expectEqual(Vector{ 0, 0, 1000 }, pool.particles[0].at);
    const own = pool.particles[0].velocity - emitter.inherited;
    try std.testing.expectApproxEqAbs(5, math.length(own), 1e-4);

    // Behind it, half; and never past the pool.
    emitter.place.position = .{ 0, 0, -1000 };
    pool.burst(&emitter, null, 20, sending);
    try std.testing.expectEqual(8, pool.used);

    // Hung from a parent, it stands where the parent puts it.
    pool.reset();
    emitter.place.position = .{ 0, 0, 10 };
    pool.burst(&emitter, .{ .position = .{ 100, 0, 0 } }, 1, sending);
    try std.testing.expectEqual(Vector{ 100, 0, 10 }, pool.particles[0].at);
}

test "Pool.frame" {
    var pool = try testing.pool();
    defer pool.deinit();
    var clock: Clock = .{};
    // A particle is free once its life is before the frame, so none is before the first tick.
    clock.frame_start = 1;
    var random: Random = .{};
    var emitter: Emitter = .{ .born = clock.frame_start, .template = &testing.template };
    pool.burst(&emitter, null, 2, .{ .view = .{ .position = .{ 0, 0, -10 } }, .clock = &clock, .random = &random });
    pool.particles[0].velocity = .{ 1, 0, 0 };

    // Halfway through its life, a particle has moved on by its velocity, and takes the curves'
    // middles.
    clock.frame_start = 51;
    clock.frame_duration = 50;
    pool.frame(&clock);
    try std.testing.expectEqual(Vector{ 50, 0, 0 }, pool.particles[0].at);
    try std.testing.expectApproxEqAbs(20, pool.sprites[0].half_size[0], 1e-4);
    try std.testing.expectApproxEqAbs(0.5, pool.sprites[0].colour[0], 1e-6);
    try std.testing.expect(!pool.sprites[0].hidden);

    // Drawn a quarter of a tick past the frame's, its sprite is that much further along.
    var scene: srcore.Scene = .{};
    defer scene.deinit(std.testing.allocator);
    try pool.draw(std.testing.allocator, &scene, 0.25);
    try std.testing.expectEqual(Vector{ 50.25, 0, 0 }, pool.sprites[0].offset);

    // Past it, both are hidden and the set drawn shrinks to one.
    clock.frame_start = 200;
    pool.frame(&clock);
    try std.testing.expect(pool.sprites[0].hidden and pool.sprites[1].hidden);
    try std.testing.expectEqual(1, pool.used);
    try std.testing.expectEqual(1, pool.set.sprites.len);
}

test "Pool.Variety" {
    var alike = try testing.pool();
    defer alike.deinit();
    var varied = try testing.pool();
    defer varied.deinit();
    varied.settings.variety = .varied;
    var clock: Clock = .{};
    clock.frame_start = 1;
    var random: Random = .{};
    var same_random: Random = .{};
    var emitter: Emitter = .{ .born = clock.frame_start, .template = &testing.template };
    const view: Place = .{ .position = .{ 0, 0, -10 } };

    // Varied, each particle has a size and a shade of its own, drawn from the pool's own numbers,
    // so the game's go on as they would.
    alike.burst(&emitter, null, 2, .{ .view = view, .clock = &clock, .random = &same_random });
    varied.burst(&emitter, null, 2, .{ .view = view, .clock = &clock, .random = &random });
    try std.testing.expectEqual(same_random.fingerprint(), random.fingerprint());
    try std.testing.expectEqual(1, alike.particles[0].scale);
    for (varied.particles[0..2]) |particle| {
        try std.testing.expect(particle.scale >= 0.75 and particle.scale <= 1.25);
        try std.testing.expect(particle.shade >= 0.85 and particle.shade <= 1.15);
    }
    try std.testing.expect(varied.particles[0].scale != varied.particles[1].scale);

    // Halfway through its life, its half-size and colour are its template's times its own.
    clock.frame_start = 51;
    varied.frame(&clock);
    const own = varied.particles[0];
    try std.testing.expectApproxEqAbs(20 * own.scale, varied.sprites[0].half_size[0], 1e-4);
    try std.testing.expectApproxEqAbs(0.5 * own.shade, varied.sprites[0].colour[0], 1e-5);
}

test "Pool.stream" {
    var pool = try testing.pool();
    defer pool.deinit();
    var clock: Clock = .{};
    var random: Random = .{};
    var streaming = testing.template;
    streaming.rate = .through(100, 100, 100);
    var emitter: Emitter = .{ .born = clock.frame_start, .life = 100, .template = &streaming, .place = .{ .position = .{ 0, 0, 1 } } };
    emitter.world = emitter.place;
    const sending: Sending = .{ .view = .{}, .clock = &clock, .random = &random };

    // At a particle a tick for four ticks, four particles.
    clock.frame_duration = 4;
    try std.testing.expect(pool.stream(&emitter, null, sending));
    try std.testing.expectEqual(4, pool.used);

    // Once its life is over, it sends nothing and says so.
    clock.frame_start = 100;
    try std.testing.expect(!pool.stream(&emitter, null, sending));
}
