//! The player's missile lock, in `C:\lancer\game\main.cpp`: `mission_frame` runs it, and
//! `mission_run` sets it up. A lock builds on the target the player aims at while the armed missile
//! can reach it (`possible`): three rings close in on the target over a second, turning, and once
//! the missile's lock time has passed they turn white as one and a tone plays. Only a locked
//! missile of a type that needs a lock launches at the target ([`input.zig`](../../input.zig)).
//! [`missiles.md`](../../../../docs/engine/missiles.md#the-lock) describes it.
//!
//! **Unverified:** its code lies after `language.cpp`'s and before `main.cpp`'s asserting code; by
//! what it does it is this file's.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const camera = @import("../camera.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const hog_snd = @import("../hog_snd.zig");
const missile_display = @import("../hud/missile_display.zig");
const matmanager = @import("../matmanager.zig");
const missiles = @import("../missiles.zig");
const objects = @import("../objects.zig");
const xtrabits = @import("../xtrabits.zig");

/// Where a lock stands (`missile_lock_state`, `0x0057DFF0`).
pub const Phase = enum(u32) {
    /// None builds.
    idle = 0,
    /// The rings close in, as the count runs down.
    closing = 1,
    /// They have closed; the lock time runs out.
    waiting = 2,
    locked = 3,
    /// **Unknown.** Nothing sets it; it is taken as lost.
    _unknown_4 = 4,
    /// Lost: the rings open out again, and the lock starts again once they have.
    lost = 5,
};

/// The lock's count while none builds, which the rings close in from.
pub const idle_count: i32 = 100;

/// The player's missile lock: `hud_missile_lock`'s globals.
pub const Lock = struct {
    phase: Phase = .idle,
    /// `missile_lock_count` (`0x0057DFBC`): 100 while no lock is building, down to 0 as the rings
    /// close in, and back up as a lost lock opens out. The target's brackets are drawn at its
    /// hundredths of their brightness.
    count: i32 = idle_count,
    /// `0x0057DFEC`: from minus the armed type's lock time up as the lock builds, and on up once
    /// it has; down again as it is lost.
    ticks: i32 = 0,
    /// `0x0057E000`: the turn the rings keep from a lock that was lost, in degrees.
    turn: i32 = 0,
    /// What the lock began on: the target and its component (`0x0057E024`, `0x0057E026`), and the
    /// armed type (`0x0057DFB8`).
    target: aigeneric.Target = .none,
    type: missiles.Type = .none,
    /// Where the rings close in on (`0x0057DFC8`): the target's node, while the lock holds.
    point: Vector = @splat(0),
    /// The locked tone's voice (`missile_lock_tone`, `0x00566644`).
    tone: ?u8 = null,

    /// `lock_rings_init` (`0x004911D0`), as a mission runs: no lock.
    pub fn reset(lock: *Lock) void {
        lock.phase = .idle;
    }

    pub fn locked(lock: *const Lock) bool {
        return lock.phase == .locked;
    }

    /// `hud_missile_lock` (`0x00491520`), once a frame while the view is one of the cockpit's or
    /// the chase view, as far as the lock goes, while the player's ship has its Player Control
    /// order. Idle, a lock starts where one is `possible`, on the target, its component and the
    /// armed type, the count at 100 and the ticks at minus the type's lock time. While it stays
    /// possible and on what it began on (`same`), the count runs down by the frame's ticks and the
    /// ticks up; the rings close by 0, the lock time runs out by 0 ticks, and the lock holds from
    /// there. Otherwise it is lost: ticks it had counted past the lock go to the rings' turn, and
    /// the count runs back up to 100, and the lock starts again from idle.
    ///
    /// **Fix:** the game means to play a sound as the rings close (`stdsmp` 2), keeping its voice
    /// at `0x0057DFC0`, and to end it once they have; but nothing sets that voice to none first, so
    /// the sound never plays and the game ends the first voice every frame instead, cutting what
    /// plays there. OpenReliant leaves the first voice alone, and the sound unplayed.
    ///
    /// Not ported: in a multiplayer game, the power-up a lock needs.
    pub fn frame(lock: *Lock, world: gameobj.World, ring: *missile_display.Ring) void {
        const entry = ai.playerControlEntry(world.objects) orelse return;
        const elapsed = world.clock.frame_duration;
        // The target the lock holds on, which `same` keeps the one it began on.
        const aimed: ai.ValidTarget = switch (lock.phase) {
            .idle => held: {
                lock.count = idle_count;
                const valid = possible(world, ring, entry.target) orelse return;
                lock.phase = .closing;
                lock.target = entry.target;
                lock.turn = 0;
                lock.type = ring.armedEntry().type;
                lock.ticks = -world.objects.missile_stats.of(lock.type).?.lock_time;
                break :held valid;
            },
            .closing => held: {
                const valid = lock.holds(world, ring, entry.target) orelse return lock.lose();
                lock.count -= elapsed;
                lock.ticks += elapsed;
                if (lock.count <= 0) {
                    lock.count = 0;
                    lock.phase = .waiting;
                }
                break :held valid;
            },
            .waiting => held: {
                const valid = lock.holds(world, ring, entry.target) orelse return lock.lose();
                lock.ticks += elapsed;
                if (lock.ticks >= 0) lock.phase = .locked;
                break :held valid;
            },
            .locked => held: {
                const valid = lock.holds(world, ring, entry.target) orelse return lock.lose();
                lock.ticks += elapsed;
                break :held valid;
            },
            ._unknown_4 => return lock.lose(),
            .lost => {
                lock.count += elapsed;
                lock.ticks -= elapsed;
                if (lock.count >= idle_count) lock.phase = .idle;
                return;
            },
        };
        lock.point = ai.aimedAt(world.objects, aimed).position;
    }

    /// The target, checked, where the lock may go on: still `possible`, and `same`.
    fn holds(lock: *const Lock, world: gameobj.World, ring: *missile_display.Ring, target: aigeneric.Target) ?ai.ValidTarget {
        const valid = possible(world, ring, target) orelse return null;
        return if (lock.same(ring, target)) valid else null;
    }

    /// `missile_lock_same` (`0x004914D0`): whether the player's target, its component and the armed
    /// type are still those the lock began on. Turning the ring loses the lock.
    fn same(lock: *const Lock, ring: *missile_display.Ring, target: aigeneric.Target) bool {
        return target.index == lock.target.index and target.component == lock.target.component and ring.armedEntry().type == lock.type;
    }

    fn lose(lock: *Lock) void {
        if (lock.ticks > 0) {
            lock.turn = lock.ticks;
            lock.ticks = 0;
        }
        lock.phase = .lost;
    }

    /// `hud_draw`'s tone (`0x004844E6`): once locked, in the view ahead from the cockpit, the
    /// locked tone plays twice over (`stdsmp` 0x15), its voice held; out of that view, or once the
    /// lock is lost, its voice is ended, whatever plays on it by then.
    pub fn sound(lock: *Lock, player: *hog_snd.Sound, view: camera.View) void {
        const ahead = view == .cockpit;
        if (lock.locked()) {
            if (lock.tone) |voice| {
                if (!ahead) lock.endTone(player, voice);
                return;
            }
            if (!ahead) return;
            lock.tone = player.playStandard(tone_sample, hog_snd.loudest, tone_plays, hog_snd.centre, hog_snd.own_pitch);
            if (lock.tone) |voice| player.voices[voice].held = 1;
        } else if (lock.tone) |voice| lock.endTone(player, voice);
    }

    fn endTone(lock: *Lock, player: *hog_snd.Sound, voice: u8) void {
        player.endVoice(voice);
        player.voices[voice].held = 0;
        lock.tone = null;
    }
};

/// The locked tone's sample of `bank_stdsmp`, and how often it plays (`hud_draw`, `0x00484511` and
/// `0x0048450D`).
const tone_sample = 0x15;
const tone_plays = 2;

/// `missile_lock_possible` (`0x00491350`): `target`, with its slot, where the armed missile can
/// lock on it, and null otherwise. It can where it has missiles left, or one the player launched
/// still flies at a target; it is not a Solomon; the target can be aimed at; the player's missiles
/// are not disabled; outside a multiplayer game the target is hostile and the missile not a
/// Screamer; and the target's node lies within the type's lock range of where the ship goes next,
/// within 0.7 of its nose.
pub fn possible(world: gameobj.World, ring: *missile_display.Ring, target: aigeneric.Target) ?ai.ValidTarget {
    const all = world.objects;
    const armed = ring.armedEntry();
    if (armed.count < 1 and !guiding(all)) return null;
    if (armed.type == .solomon) return null;
    const aimed = ai.ValidTarget.of(all, target, .{}) orelse return null;
    const ship = &all.slots[all.player].object;
    if (ship.flags.missiles_disabled) return null;
    if (all.slots[aimed.slot].object.side != .hostile) return null;
    if (armed.type == .screamer) return null;
    const stats = all.missile_stats.of(armed.type) orelse return null;
    return if (missiles.inLockReach(stats, ai.aimedAt(all, aimed).position - ship.nextPosition(), ship.nextHeading())) aimed else null;
}

/// `player_missile_guiding` (`0x004AF190`): whether a missile the player launched still flies at
/// a target.
pub fn guiding(all: *create.Objects) bool {
    var walk = all.missiles.walk();
    while (walk.next()) |index| {
        const missile = all.missiles.get(index) orelse continue;
        if (missile.launcher == all.player and missile.target.slot() != null) return true;
    }
    return false;
}

// --- The rings ---------------------------------------------------------------------------------

/// The lock's three rings (`lock_rings`, `0x0057DFF4`), each a quarter of `tarring` on one square
/// (`lock_ring_mesh`, `0x0057DFC4`), 256 across, facing the camera, coloured by their own colours
/// and added over the view.
pub const Rings = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    objects: [ring_count]srapiext.MeshObject,
    colours: [ring_count][4][4]f32,
    uv: [ring_count][4][2]f32,

    const ring_count = 3;
    const half: f32 = 128;
    const material: srapiext.Material = .onePass(.{ .coordinates = .generated, .lit = true, .blend = .add });
    /// Each ring's quarter of the texture, its corner and its size, in texels of 256
    /// (`0x004DC6A0`, `0x004DC818`).
    const corners = [ring_count][2]f32{ .{ 0, 0 }, .{ 128, 0 }, .{ 0, 128 } };
    const quarter: f32 = 127;
    const texels: f32 = 256;

    /// `lock_ring_mesh_create` (`0x00491080`) and `lock_rings_init`'s rings.
    pub fn create(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!*Rings {
        const image = try matmanager.textureRequire(textures, "tarring");
        const rings = try gpa.create(Rings);
        errdefer gpa.destroy(rings);
        rings.mesh = try .create(gpa, .{ .polygons = 1, .vertices = 4, .indices = 4 });
        rings.mesh.surfaces[0] = .{ .polygons = 1, .material = material, .textures = .{ .{ .image = image }, .none } };
        rings.mesh.positions[0..4].* = .{ .{ -half, -half, 0 }, .{ half, -half, 0 }, .{ half, half, 0 }, .{ -half, half, 0 } };
        rings.mesh.numberPolygons(4);
        rings.mesh.indices[0..4].* = .{ 0, 1, 2, 3 };
        srapi.findBoundingBox(&rings.mesh);
        rings.level = .{.{ .mesh = &rings.mesh, .until = std.math.inf(f32) }};
        for (&rings.objects, &rings.colours, &rings.uv, corners) |*object, *colours, *uv, corner| {
            const u = [2]f32{ corner[0] / texels, (corner[0] + quarter) / texels };
            const v = [2]f32{ corner[1] / texels, (corner[1] + quarter) / texels };
            uv.* = .{ .{ u[0], v[0] }, .{ u[1], v[0] }, .{ u[1], v[1] }, .{ u[0], v[1] } };
            colours.* = @splat(.{ 0, 0, 0, 0 });
            object.* = .{
                .flags = .{ .not_culled = true, .baked_object = true, .own_first = true },
                .position = @splat(0),
                .radius = rings.mesh.radius,
                .levels = &rings.level,
                .baked = colours,
                .own_uv = .{ uv, null },
            };
        }
        return rings;
    }

    pub fn destroy(rings: *Rings, gpa: Allocator) void {
        rings.mesh.deinit(gpa);
        gpa.destroy(rings);
    }

    /// The rest of `hud_missile_lock`: while a lock builds, holds or is lost, and outside view 13,
    /// the rings stand on the line from the camera to where they close in on, as far out as the
    /// count has run down, facing the camera and turned about its axis. Before the lock the
    /// three turn apart, the first to and fro by up to a radian at one and a half times the ticks,
    /// the second by up to 0.6 at two and a half times, the third a degree a tick; locked, all
    /// three a degree a tick. They are drawn at 1.33, 1.11 and 1 times 0.7 of their size, drawing
    /// together over the last half second before the lock; and dark red, whitening over that half
    /// second, at 0.65 of the colour.
    ///
    /// **Improvement:** the game turns degrees into radians by 0.0174533 (`0x004DC71C`);
    /// OpenReliant by `std.math.degreesToRadians`.
    pub fn draw(rings: *Rings, gpa: Allocator, scene: *srcore.Scene, lock: *const Lock, place: camera.Place, projection: srapi.Projection) Allocator.Error!void {
        if (lock.phase == .idle) return;
        const ticks: f32 = @floatFromInt(lock.ticks);
        const angle = std.math.degreesToRadians(ticks);
        const angles: [ring_count]f32 = if (lock.locked()) @splat(angle) else .{ @sin(angle * ring_rates[0]), @sin(angle * ring_rates[1]) * second_ring_swing, angle };
        const reach = projection.scale[0] * close_reach / @as(f32, @floatFromInt(projection.screen[0])) * @as(f32, @floatFromInt(idle_count - lock.count)) * count_share;
        const at = place.position + math.normalize(lock.point - place.position) * @as(Vector, @splat(reach));
        const whitening: f32 = if (lock.ticks < -(whitening_ticks - 1)) 0 else @min((ticks + whitening_ticks) / whitening_ticks, 1);
        const shade = dark_red * @as(Colour, @splat(1 - whitening)) + white * @as(Colour, @splat(whitening));
        const turn = std.math.degreesToRadians(@as(f32, @floatFromInt(lock.turn)));
        for (&rings.objects, &rings.colours, angles, ring_scales) |*object, *colours, spin, first_scale| {
            object.position = at;
            object.orientation = math.product(place.orientation, math.rotation(.z, turn + spin));
            var scale = first_scale;
            if (lock.ticks > -whitening_ticks) scale = if (lock.locked()) 0 else ticks * scale / -whitening_ticks;
            object.scale = (scale + 1) * ring_size_share;
            for (colours) |*corner| corner[0..3].* = shade * @as(Colour, @splat(ring_shade));
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = object }, .overlay);
        }
    }
};

/// How far out the rings stand once closed, for the view's scale across over the screen's width
/// (`0x004DC948`); over how many ticks before the lock they draw together and whiten, which
/// OpenReliant divides by where the game multiplies by 0.02 (`0x004DC940`) and -0.02
/// (`0x004DC944`), an **Improvement**; how much
/// more than `ring_size_share` of their size they start at (`0x00491BDA`, `0x00491BCB`); and how
/// bright they are.
const close_reach: f32 = 2560;
const whitening_ticks: f32 = 50;
const ring_scales = [Rings.ring_count]f32{ 0.328125, 0.109375, 0 };
const ring_shade: f32 = 0.65;

/// The share of their size the rings are drawn at (`0x004DC484`), and how far each point the count
/// has run down from `idle_count` takes them, as a share of as far as they go (`0x004DC518`): one
/// over `idle_count`, as the game rounds it.
const ring_size_share: f32 = 0.7;
const count_share: f32 = 0.01;

/// How fast the first two rings swing to and fro before the lock, against the ticks (`0x004DC4E0`,
/// `0x004DC59C`), and how far the second swings, in radians (`0x004DC94C`).
const ring_rates = [2]f32{ 1.5, 2.5 };
const second_ring_swing: f32 = 0.6;

/// A ring's colour: red, green and blue.
const Colour = @Vector(3, f32);

/// The rings' colour before they whiten, and once they have (`hud_missile_lock`, `0x00491C7D` and
/// `0x00491C90`).
const dark_red: Colour = .{ 0.5, 0, 0 };
const white: Colour = @splat(1);

const testing = struct {
    /// An armed mission whose player aims at a hostile ship `ahead` along its nose, with its
    /// missiles in the display: a Raptor pod and a Havoc, the Havoc armed.
    const Stage = struct {
        armed: missiles.testing.Armed,
        ring: missile_display.Ring = .{},
        player: u16 = undefined,
        enemy: u16 = undefined,

        fn init(stage: *Stage, ahead: f32) !void {
            stage.* = .{ .armed = undefined };
            try stage.armed.init(std.testing.allocator);
            errdefer stage.armed.deinit();
            stage.player = try stage.armed.add(.friendly, @splat(0));
            stage.enemy = try stage.armed.add(.hostile, .{ 0, 0, ahead });
            _ = try aigeneric.push(stage.armed.mission.orders(), stage.player, .player_control, stage.target());
            stage.ring.build(&stage.armed.mission.slot(stage.player).object);
            stage.armed.mission.clock.frame_duration = 10;
        }

        fn deinit(stage: *Stage) void {
            stage.armed.deinit();
        }

        fn target(stage: *const Stage) aigeneric.Target {
            return .at(stage.enemy, null);
        }
    };
};

test possible {
    var stage: testing.Stage = undefined;
    try stage.init(20000);
    defer stage.deinit();
    const world = stage.armed.mission.world();
    try std.testing.expectEqual(missiles.Type.havoc, stage.ring.armedEntry().type);
    try std.testing.expect(possible(world, &stage.ring, stage.target()) != null);
    // Not beyond the type's lock range, nor off to the side, nor on a friend.
    const enemy = stage.armed.mission.slot(stage.enemy);
    objects.setPosition(&enemy.object, &enemy.drawn, .{ 0, 0, 60000 });
    try std.testing.expectEqual(null, possible(world, &stage.ring, stage.target()));
    objects.setPosition(&enemy.object, &enemy.drawn, .{ 20000, 0, 1000 });
    try std.testing.expectEqual(null, possible(world, &stage.ring, stage.target()));
    objects.setPosition(&enemy.object, &enemy.drawn, .{ 0, 0, 20000 });
    enemy.object.side = .friendly;
    try std.testing.expectEqual(null, possible(world, &stage.ring, stage.target()));
    enemy.object.side = .hostile;
    // Nor with a Screamer or a Solomon armed.
    stage.ring.armedEntry().type = .solomon;
    try std.testing.expectEqual(null, possible(world, &stage.ring, stage.target()));
}

test "Lock.frame" {
    var stage: testing.Stage = undefined;
    try stage.init(20000);
    defer stage.deinit();
    const world = stage.armed.mission.world();
    var lock: Lock = .{};

    // It starts on the target and the Havoc, the ticks at minus its lock time.
    lock.frame(world, &stage.ring);
    try std.testing.expectEqual(Phase.closing, lock.phase);
    try std.testing.expectEqual(-200, lock.ticks);
    try std.testing.expectEqual(missiles.Type.havoc, lock.type);
    // The rings close over 100 ticks, and the lock holds once its time has run out.
    for (0..10) |_| lock.frame(world, &stage.ring);
    try std.testing.expectEqual(Phase.waiting, lock.phase);
    try std.testing.expectEqual(0, lock.count);
    for (0..10) |_| lock.frame(world, &stage.ring);
    try std.testing.expect(lock.locked());
    try std.testing.expectEqual(math.Vector{ 0, 0, 20000 }, lock.point);
    // Turning the ring loses it: the ticks past the lock go to the rings' turn, and it opens out.
    lock.frame(world, &stage.ring);
    stage.ring.armed = 0;
    lock.frame(world, &stage.ring);
    try std.testing.expectEqual(Phase.lost, lock.phase);
    try std.testing.expectEqual(10, lock.turn);
    for (0..10) |_| lock.frame(world, &stage.ring);
    try std.testing.expectEqual(Phase.idle, lock.phase);
}

test guiding {
    var stage: testing.Stage = undefined;
    try stage.init(20000);
    defer stage.deinit();
    const all = stage.armed.mission.objects;
    try std.testing.expect(!guiding(all));
    missiles.launch(stage.armed.mission.world(), stage.player, 1, stage.target());
    try std.testing.expect(guiding(all));
}

test "Lock.sound" {
    var speaker: hog_snd.testing.Speaker = undefined;
    const bytes = comptime hog_snd.testing.bank(tone_sample + 1);
    try speaker.init(2, &bytes);
    const player = &speaker.sound;
    var lock: Lock = .{};

    // No tone before the lock, nor once locked in any view but the one ahead.
    lock.sound(player, .cockpit);
    try std.testing.expectEqual(null, lock.tone);
    lock.phase = .locked;
    lock.sound(player, .cockpit_left);
    try std.testing.expectEqual(null, lock.tone);
    // Locked, from the view ahead, it plays on a voice held for it, and only once.
    lock.sound(player, .cockpit);
    const voice = lock.tone.?;
    try std.testing.expectEqual(1, player.voices[voice].held);
    lock.sound(player, .cockpit);
    try std.testing.expectEqual(voice, lock.tone.?);
    // Out of that view, its voice is let go.
    lock.sound(player, .chase);
    try std.testing.expectEqual(null, lock.tone);
    try std.testing.expectEqual(0, player.voices[voice].held);
    // And likewise once the lock is lost.
    lock.sound(player, .cockpit);
    try std.testing.expect(lock.tone != null);
    lock.phase = .lost;
    lock.sound(player, .cockpit);
    try std.testing.expectEqual(null, lock.tone);
}

test "Rings.draw" {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, &.{"tarring"});
    defer textures.deinit(gpa);
    const rings = try Rings.create(gpa, &textures.table);
    defer rings.destroy(gpa);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const projection: srapi.Projection = .init(640, 480, srapi.full_screen, .{ 0.6, 0.8 });
    const place: camera.Place = .{};

    // With no lock building, nothing is drawn.
    var lock: Lock = .{ .point = .{ 0, 0, 1000 } };
    try rings.draw(gpa, &scene, &lock, place, projection);
    try std.testing.expectEqual(0, scene.layers.get(.overlay).items.len);

    // Just begun, far from the lock: at the camera, apart in size, and dark red.
    lock.phase = .closing;
    lock.ticks = -200;
    try rings.draw(gpa, &scene, &lock, place, projection);
    try std.testing.expectEqual(Rings.ring_count, scene.layers.get(.overlay).items.len);
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, rings.objects[0].position);
    for (rings.objects, ring_scales) |object, first_scale| {
        try std.testing.expectApproxEqAbs((first_scale + 1) * ring_size_share, object.scale, 1e-6);
    }
    try std.testing.expectEqual([3]f32{ 0.5 * ring_shade, 0, 0 }, rings.colours[0][0][0..3].*);

    // Locked, closed in: together at their size, white, and as far out as they go.
    scene.clear();
    lock.phase = .locked;
    lock.ticks = 0;
    lock.count = 0;
    try rings.draw(gpa, &scene, &lock, place, projection);
    for (rings.objects) |object| try std.testing.expectApproxEqAbs(ring_size_share, object.scale, 1e-6);
    try std.testing.expectEqual(@as([3]f32, @splat(ring_shade)), rings.colours[2][3][0..3].*);
    const out = projection.scale[0] * close_reach / 640;
    try std.testing.expectApproxEqRel(out, rings.objects[1].position[2], 1e-5);
}
