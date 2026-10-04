//! `C:\lancer\game\guns.cpp`'s particles and fireballs: the trail a Huge Gun's shot leaves, the burst
//! of a Turret Flak shell that ends without striking anything, and the spent cases a spinning gun
//! throws. `guns_init` (`0x00478990`) makes their templates and the guns' two pools of particles.

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../../../formats/shp.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const guns = @import("../guns.zig");
const matmanager = @import("../matmanager.zig");
const objects = @import("../objects.zig");
const particles = @import("../particles.zig");
const sound3d = @import("../sound3d.zig");
const Clock = @import("../main.zig").Clock;

/// The guns' own pools of particles: the flak's (`0x005636D0`) and the spent cases'
/// (`0x0056315C`). They are among the particles' pools, whose particles `particles_frame` moves on
/// and draws together.
pub const Pools = struct {
    flak: particles.Pool,
    cases: particles.Pool,

    /// The flak's: 1000 over `gunflare\partic7`, which darkens what is behind it by its alpha.
    const flak_look: particles.Pool.Look = .{ .image = "gunflare\\partic7", .blend = .premultiplied };
    /// The cases': 100 over `gunflare\case1`, showing its own colours.
    const cases_look: particles.Pool.Look = .{ .count = 100, .image = "gunflare\\case1", .coloured = false, .blend = .premultiplied };

    /// Both pools, sending and drawing their particles as `settings` says.
    pub fn load(gpa: Allocator, textures: *srtexture.Table, settings: particles.Pool.Settings) (Allocator.Error || matmanager.Error)!Pools {
        var flak: particles.Pool = try .load(gpa, textures, flak_look, settings);
        errdefer flak.deinit();
        return .{ .flak = flak, .cases = try .load(gpa, textures, cases_look, settings) };
    }

    pub fn deinit(pools: *Pools) void {
        pools.flak.deinit();
        pools.cases.deinit();
    }

    /// `particles_reset`, as a mission starts or ends: every particle free.
    pub fn reset(pools: *Pools) void {
        pools.flak.reset();
        pools.cases.reset();
    }

    /// `particles_frame`'s work on them (`particles.Pool.frame`).
    pub fn frame(pools: *Pools, clock: *const Clock) void {
        pools.flak.frame(clock);
        pools.cases.frame(clock);
    }

    pub fn draw(pools: *Pools, gpa: Allocator, scene: *srcore.Scene, ahead: f32) Allocator.Error!void {
        try pools.flak.draw(gpa, scene, ahead);
        try pools.cases.draw(gpa, scene, ahead);
    }
};

// --- A Huge Gun's trail --------------------------------------------------------------------------

/// A Huge Gun's shot's trail (`bullet_build`): an emitter hung from the shot's frame for
/// `trail_life` ticks, which the explosions' pool streams from once a frame, then stands afresh
/// `behind` the shot and up to half of `stray` off it each way across (`bullets_frame`, which
/// holds `behind` in its code and `stray` at `0x004DC5A8` and `0x004DC87C`). It points
/// back along the shot at a speed below nothing, so its particles leave forward, at `speed` less up
/// to `trail_speed_range`, strayed up to half of `spread` each way across.
pub const Trail = struct {
    template: particles.Template,
    spread: f32,
    speed: f32,
    behind: f32,
    stray: f32,

    /// The trail of a shot of `kind`, where it leaves one: the Huge Guns'.
    pub fn of(kind: guns.GunType) ?*const Trail {
        return switch (kind.base()) {
            .allied_huge_gun => &allied_trail,
            .coalition_huge_gun => &coalition_trail,
            else => null,
        };
    }

    /// The trail starting at `now`, its emitter standing where the shot does.
    pub fn start(trail: *const Trail, now: i32) Streaming {
        return .{ .trail = trail, .emitter = .{
            .life = trail_life,
            .born = now,
            .direction = .{ 0, 0, -1 },
            .spread = @splat(trail.spread),
            .speed = trail.speed,
            .speed_range = trail_speed_range,
            .template = &trail.template,
        } };
    }
};

/// A trail streaming from a shot in flight.
pub const Streaming = struct {
    trail: *const Trail,
    emitter: particles.Emitter,

    /// Its part of `bullets_frame` for a shot whose frame stands at `shot`: the explosions' pool
    /// streams from its emitter, which then stands afresh behind the shot.
    pub fn frame(streaming: *Streaming, world: gameobj.World, shot: math.Place) void {
        if (world.particles) |pool| if (world.sending()) |sending| {
            _ = pool.stream(&streaming.emitter, shot, sending);
        };
        const stray = streaming.trail.stray;
        const y = world.random.centred() * stray;
        const x = world.random.centred() * stray;
        streaming.emitter.place.position = .{ x, y, -streaming.trail.behind };
    }
};

/// How long a trail's emitter streams, longer than any shot flies; and how much slower than its
/// speed its particles may leave.
const trail_life = 10000;
const trail_speed_range: f32 = 20;

/// The Allied Huge Gun's (`0x005635D0`): 1.2 to 1.3 seconds of blue fading to nothing, from a
/// half-size of 700 down to 250, 12 a tick.
const allied_trail: Trail = .{
    .template = .{
        .life = 120,
        .life_spread = 10,
        .rate = .through(1200, 1200, 1200),
        .size = .through(700, 500, 250),
        .colour = .{ .through(0.3, 0, 0), .through(0.8, 0, 0), .through(0.8, 0.2, 0) },
    },
    .spread = 0.15,
    .speed = -220,
    .behind = 700,
    .stray = 400,
};

/// The Coalition Huge Gun's (`0x0056318C`): orange fading to nothing, growing from a half-size of
/// 500 to 1100.
const coalition_trail: Trail = .{
    .template = .{
        .life = 120,
        .life_spread = 10,
        .rate = .through(1200, 1200, 1200),
        .size = .through(500, 700, 1100),
        .colour = .{ .through(1, 0.6, 0), .through(0.9, 0.34, 0), .through(0.7, 0.1, 0) },
    },
    .spread = 0.1,
    .speed = -250,
    .behind = 850,
    .stray = 850,
};

// --- A flak shell's burst ------------------------------------------------------------------------

/// Within this far of the camera a flak shell bursts in full (`0x004DC878`, its square).
const flak_near: f32 = 10000;

/// The flak's particles (`0x00563104`): 1.5 to 1.6 seconds of them, dimming from half grey, growing
/// from a half-size of 42 to 119, and a spark one time in 200.
const flak_template: particles.Template = .{
    .kind = .sometimes_sparks,
    .life = 150,
    .life_spread = 10,
    .size = .through(42, 105, 119),
    .colour = @splat(.through(0.5, 0.25, 0)),
};

/// How many flak particles a burst sends, every way, at 1.4 a tick and up to 0.35 more.
const flak_particles = 30;
const flak_speed: f32 = 1.4;
const flak_speed_range: f32 = 0.35;

/// A full burst's two flashes of flak: the first with a light, the second `flash_late` ticks late
/// and up to as many more.
const flak_flash: explode.Fireball.Spec = .{ .size = 280, .life = 130, .light = true, .special = true };
const flak_after: explode.Fireball.Spec = .{ .size = 245, .life = 130, .special = true };
const flash_late = 20;

/// A burst far off: one flash of flak, larger and brief, with a light.
const flak_far: explode.Fireball.Spec = .{ .size = 600, .life = 40, .light = true, .special = true };

/// A full burst's fireballs: `bangs` of each kind drifting out a random way at `bang_drift` a tick,
/// lit, up to `bang_late` ticks late, living `bang_life` ticks and up to `bang_life_range` more,
/// `bang_size` and up to `bang_size_range` more across (`0x004DC72C`, `0x004DC874`, `0x004DC820`,
/// `0x004DC870`): first of the bang or the sheet at random, then of flak.
const bangs = 10;
const bang_drift: f32 = 10.5;
const bang_late: f32 = 20;
const bang_life = 50;
const bang_life_range: f32 = 70;
const bang_size: f32 = 14;
const bang_size_range: f32 = 56;

/// `bullets_frame`'s burst of a Turret Flak shell at `at`, the shot at `index`, that ends without
/// striking anything: it sounds `FLAK01`, and where the camera stands within `flak_near` there are
/// two flashes of flak, a burst of the guns' flak particles, and the fireballs of `bangs`. Farther
/// off, one flash of `flak_far`.
pub fn flakBurst(world: gameobj.World, index: u8, at: Vector) void {
    sound3d.playIn(world, null, null, index, .flak01, 1, .explosions);
    const seen = world.camera orelse return;
    if (math.lengthSquared(seen.place.position - at) >= flak_near * flak_near) return explode.fireballAt(world, at, flak_far);
    const random = world.random;
    explode.fireballAt(world, at, flak_flash);
    var after = flak_after;
    after.delay = flash_late + @as(i32, @intFromFloat(random.fraction() * flash_late));
    explode.fireballAt(world, at, after);
    if (world.gun_particles) |pools| if (world.sending()) |sending| {
        var burst: particles.Emitter = .{
            .born = world.clock.frame_start,
            .place = .{ .position = at },
            .spread = @splat(1),
            .speed = flak_speed,
            .speed_range = flak_speed_range,
            .template = &flak_template,
        };
        pools.flak.burst(&burst, null, flak_particles, sending);
    };
    for ([_]bool{ false, true }) |special| for (0..bangs) |_| {
        const yaw = random.fraction() * std.math.tau;
        const pitch = random.fraction() * std.math.tau;
        const drift = math.transform(math.fromAngles(pitch, yaw, 0), .{ 0, 0, bang_drift });
        const delay: i32 = @intFromFloat(random.fraction() * bang_late);
        const life = bang_life + @as(i32, @intFromFloat(random.fraction() * bang_life_range));
        const size = random.fraction() * bang_size_range + bang_size;
        const kind: explode.Fireball.Kind = if (special or random.rand() & 1 == 0) .bang else .sheet;
        explode.fireballAt(world, at, .{ .kind = kind, .size = size, .life = life, .delay = delay, .lit = true, .velocity = drift, .special = special });
    };
}

// --- A spinning gun's spent cases ----------------------------------------------------------------

/// The spent cases (`0x005636D4`): each for a second and up to a tenth more, a half-size of 15.
/// The pool shows their texture's own colours, so theirs are never read.
const case_template: particles.Template = .{
    .life = 100,
    .life_spread = 10,
    .size = .through(15, 15, 15),
    .colour = .{ .through(1, 1, 1), .through(0, 0.9, 0.9), .through(0, 0.9, 0.9) },
};

/// How a case leaves its point: back along it at `case_speed` a tick, strayed up to half of
/// `case_spread` each way across, with `case_carried` of the ship's velocity; showing one of the
/// eight cells of `gunflare\case1`, four across and two down.
const case_speed: f32 = 10;
const case_spread: Vector = .{ 0.25, 0.25, 0 };
const case_carried: f32 = 0.25;
const case_cells = [2]u15{ 4, 2 };

/// `clip_event_particles` (`0x0047C800`): a spent case from each of part `part`'s attachments of
/// kind 7 (`shp.Attachment.Kind.case_ejector`), where `model`, a model of the object in slot
/// `owner`, stands after the step, into the guns' cases' pool. A spinning gun throws them as each
/// round fires, and a model's `puff` event.
pub fn throwCases(world: gameobj.World, owner: u16, model: *const objects.Model, part: usize) void {
    const pools = world.gun_particles orelse return;
    const sending = world.sending() orelse return;
    const shown = model.partPlace(part, .next).within(world.objects.slots[owner].object.placeAt(.next));
    const carried = gameobj.vector(world.objects.slots[owner].object.velocity) * @as(Vector, @splat(case_carried));
    for (model.parts[part].attachments) |*attachment| {
        if (attachment.kind != .case_ejector) continue;
        const random = world.random;
        const across: f32 = @floatFromInt(random.rand() & (case_cells[0] - 1));
        const down: f32 = @floatFromInt(random.rand() & (case_cells[1] - 1));
        const width = 1 / @as(f32, @floatFromInt(case_cells[0]));
        const height = 1 / @as(f32, @floatFromInt(case_cells[1]));
        var case: particles.Emitter = .{
            .born = world.clock.frame_start,
            .place = objects.attachmentPlace(attachment),
            .direction = .{ 0, 0, -1 },
            .spread = case_spread,
            .speed = case_speed,
            .inherited = carried,
            .uv = .{ across * width, (across + 1) * width, down * height, (down + 1) * height },
            .template = &case_template,
        };
        pools.cases.burst(&case, shown, 1, sending);
    }
}

pub const testing = struct {
    /// The guns' pools over two images that are never looked into.
    pub const Built = struct {
        flak_image: srtexture.Image = .{ .levels = &.{} },
        cases_image: srtexture.Image = .{ .levels = &.{} },
        pools: Pools,

        pub fn init(built: *Built, gpa: Allocator) !void {
            built.* = .{ .pools = undefined };
            var flak: particles.Pool = try .init(gpa, 100, &built.flak_image, .premultiplied);
            errdefer flak.deinit();
            built.pools = .{ .flak = flak, .cases = try .init(gpa, 100, &built.cases_image, .premultiplied) };
        }

        pub fn deinit(built: *Built) void {
            built.pools.deinit();
        }
    };
};

test flakBurst {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit();
    var watching: @import("../camera.zig").Camera = .{};
    var world = stage.world();
    world.camera = &watching;
    world.gun_particles = &built.pools;
    stage.mission.clock.frame_start = 100;

    // Far off, one brief flash of flak with a light.
    flakBurst(world, 0, .{ 0, 0, flak_near * 2 });
    const far = stage.explosions.fireballs[0].?;
    try std.testing.expect(far.special and far.light != null);
    try std.testing.expectEqual(flak_far.life, far.life);
    try std.testing.expectEqual(null, stage.explosions.fireballs[1]);

    // Near, two flashes, the flak's particles, and ten fireballs of each kind, drifting out lit.
    stage.explosions.fireballs = @splat(null);
    flakBurst(world, 0, .{ 0, 0, 1000 });
    var fireballs: usize = 0;
    for (stage.explosions.fireballs) |slot| fireballs += @intFromBool(slot != null);
    try std.testing.expectEqual(2 + 2 * bangs, fireballs);
    const after = stage.explosions.fireballs[1].?;
    try std.testing.expect(after.delay >= flash_late and after.delay < 2 * flash_late);
    const bang = stage.explosions.fireballs[2].?;
    try std.testing.expect(bang.lit);
    try std.testing.expectApproxEqAbs(bang_drift, math.length(bang.velocity), 1e-3);
    try std.testing.expect(stage.explosions.fireballs[2 + bangs].?.special);
    try std.testing.expect(built.pools.flak.used > 0);
}

test Trail {
    // Only the Huge Guns' shots leave one, pointing back along the shot at a speed below nothing.
    try std.testing.expectEqual(null, Trail.of(.of(.laser_cannon)));
    const trail = Trail.of(.of(.coalition_huge_gun)).?;
    var streaming = trail.start(100);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, -1 }), streaming.emitter.direction);
    try std.testing.expect(streaming.emitter.speed < 0);

    // Once a frame it stands afresh behind the shot, off it each way by up to half its stray.
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    streaming.frame(stage.world(), .{});
    try std.testing.expectEqual(-trail.behind, streaming.emitter.place.position[2]);
    try std.testing.expect(@abs(streaming.emitter.place.position[0]) <= trail.stray / 2);
}

test throwCases {
    const gpa = std.testing.allocator;
    const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var built: testing.Built = undefined;
    try built.init(gpa);
    defer built.deinit();
    var watching: @import("../camera.zig").Camera = .{};
    watching.place.position = .{ 0, 0, -1000 };
    var world = stage.world();
    world.camera = &watching;
    world.gun_particles = &built.pools;
    stage.mission.clock.frame_start = 100;
    const ship = try stage.mission.add(.of(.grendel), @splat(0));
    stage.mission.objects.slots[ship].object.velocity = .{ .x = 0, .y = 0, .z = 40 };

    // A part with a muzzle and a case ejector a little to its side.
    var points: [2]shp.Attachment = @splat(std.mem.zeroes(shp.Attachment));
    points[0].kind = .gun_muzzle;
    points[1].kind = .case_ejector;
    points[1].orientation = math.identity;
    points[1].position = .{ .x = 10, .y = 0, .z = 0 };
    const shown: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = &.{} };
    var parts = [_]objects.Model.Part{.{ .hidden = false, .parent = null, .origin = @splat(0), .object = shown, .attachments = &points }};
    const model: objects.Model = .{ .parts = &parts, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };

    // One case, from the ejector, back along it at `case_speed` but carried on by a quarter of the
    // ship's velocity, showing one of the eight cells.
    throwCases(world, ship, &model, 0);
    try std.testing.expectEqual(1, built.pools.cases.used);
    const case = built.pools.cases.particles[0];
    try std.testing.expect(case.template == &case_template);
    try std.testing.expectApproxEqAbs(10, case.at[0], 1e-3);
    try std.testing.expect(@abs(case.velocity[2]) < 1);
    const uv = built.pools.cases.sprites[0].uv;
    try std.testing.expectApproxEqAbs(0.25, uv[1] - uv[0], 1e-6);
    try std.testing.expectApproxEqAbs(0.5, uv[3] - uv[2], 1e-6);
}
