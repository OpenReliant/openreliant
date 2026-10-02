//! The smoke a damaged ship trails, in `C:\lancer\game\main.cpp`: `mission_frame`'s pass over the
//! objects has each one's smoke stream and follows its damage (`frame`), and a change of level
//! starts its smoke again from its model's first engine glow (`0x00494400`, `Stream.start`). A
//! badly damaged ship's smoke throws sparks and, now and then, a small fireball. **Unverified:**
//! the set-up and the plumes (`0x004946B0`) lie after `main.cpp`'s known code, before
//! `matmanager.cpp`'s; by what they do they are this file's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const shp = @import("../../../formats/shp.zig");
const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const create = @import("../create.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const matmanager = @import("../matmanager.zig");
const objects = @import("../objects.zig");
const particles = @import("../particles.zig");
const Clock = @import("../main.zig").Clock;

/// How damaged a ship shows itself to be, by its smoke (`GameObject.smoke_level`).
pub const Level = enum(u8) {
    none = 0,
    /// Thin, pale smoke.
    light = 1,
    /// Thicker smoke.
    heavy = 2,
    /// Dark smoke with sparks in it, and now and then a small fireball.
    burning = 3,

    /// `mission_frame`'s rule for `object`'s level, from the weakest quadrant of its armour over
    /// six times its type's `armor_class`: below 0.9 of it `light`, below 0.7 `heavy` and below
    /// half `burning`. While the weakest of its shields' quadrants holds more than 0.9 of six times
    /// its type's `shield_power`, smoke already showing thins to `light` and none starts. The game
    /// reads the shields' aft quadrant twice and their right one not at all.
    pub fn of(object: *const gameobj.GameObject, combat: *const create.ShipCombat) Level {
        const shields = object.shields;
        if (@min(shields.aft, shields.fore, shields.left) / combat.fullShields() > shielded) {
            return if (object.smoke_level != .none) .light else .none;
        }
        const armor = object.armor;
        const share = armor.weakest() / combat.fullArmor();
        for (thresholds) |threshold| {
            if (share < threshold.below) return threshold.level;
        }
        return .none;
    }

    /// What the level sends out; nothing at `none`.
    fn plume(level: Level) ?*const Plume {
        return switch (level) {
            .none => null,
            .light => &light_plume,
            .heavy => &heavy_plume,
            .burning => &burning_plume,
        };
    }

    /// The shares of the full armour below which each level starts, the worst first
    /// (`0x004DC408`, `0x004DC484`, `0x004DC470`), and the share of the full shields above which
    /// smoke thins.
    const thresholds = [_]struct { below: f32, level: Level }{
        .{ .below = 0.5, .level = .burning },
        .{ .below = 0.7, .level = .heavy },
        .{ .below = 0.9, .level = .light },
    };
    const shielded: f32 = 0.9;
};

/// What a level sends out (`0x004946B0`, which the mission's start runs for each): its particles
/// and how the pool they come from draws them, and how far its emitter strays them either way
/// across its Z axis (`0x00494400`).
const Plume = struct {
    template: particles.Template,
    look: particles.Pool.Look,
    spread: Vector,
};

/// Half a particle a tick: `mission_frame` sets each template's rate to this before it streams
/// (`particle_curve_set`), and a stream's life starts again each frame, so the start of the curve
/// is all that is read.
const rate: particles.Curve = .through(50, 0, 0);

/// Pale specks, added, 0.7 to 0.8 seconds long, growing from a half-size of 37.5 to 300.
const light_plume: Plume = .{
    .template = .{ .life = 70, .life_spread = 10, .rate = rate, .size = .through(37.5, 150, 300), .colour = @splat(.through(0.3, 0.15, 0)) },
    .look = .standard,
    .spread = .{ 0.15, 0.15, 0 },
};

/// Brighter and larger, and a second long: up to a half-size of 500.
const heavy_plume: Plume = .{
    .template = .{ .life = 100, .life_spread = 10, .rate = rate, .size = .through(62.5, 250, 500), .colour = @splat(.through(0.5, 0.25, 0)) },
    .look = .standard,
    .spread = .{ 0.25, 0.25, 0 },
};

/// Larger still, up to a half-size of 600, over `gunflare\partic7`, which darkens what is behind
/// it by its alpha; and a spark one time in 200.
const burning_plume: Plume = .{
    .template = .{ .kind = .sometimes_sparks, .life = 100, .life_spread = 10, .rate = rate, .size = .through(75, 300, 600), .colour = @splat(.through(0.5, 0.25, 0)) },
    .look = .{ .image = "gunflare\\partic7", .blend = .premultiplied },
    .spread = .{ 0.25, 0.25, 0 },
};

/// The pools the smoke comes from, one for each level that smokes (`0x00588708`, `0x0058870C`,
/// `0x00588710`), which the mission's start makes and its end (`0x004942B0`) lets go. They are
/// among the particles' pools, whose particles `particles_frame` moves on and draws together.
pub const Pools = struct {
    /// None at `none`.
    by_level: std.EnumArray(Level, ?particles.Pool) = .initFill(null),

    /// Each level's pool, over the texture its plume requires, sending and drawing its particles
    /// as `settings` says.
    pub fn load(gpa: Allocator, textures: *srtexture.Table, settings: particles.Pool.Settings) (Allocator.Error || matmanager.Error)!Pools {
        var pools: Pools = .{};
        errdefer pools.deinit();
        for (std.enums.values(Level)) |level| {
            const made = level.plume() orelse continue;
            pools.by_level.set(level, try .load(gpa, textures, made.look, settings));
        }
        return pools;
    }

    pub fn deinit(pools: *Pools) void {
        for (&pools.by_level.values) |*slot| if (slot.*) |*pool| pool.deinit();
    }

    /// `particles_reset`, as a mission starts or ends: every particle free.
    pub fn reset(pools: *Pools) void {
        for (&pools.by_level.values) |*slot| if (slot.*) |*pool| pool.reset();
    }

    /// `particles_frame`'s work on them (`particles.Pool.frame`).
    pub fn frame(pools: *Pools, clock: *const Clock) void {
        for (&pools.by_level.values) |*slot| if (slot.*) |*pool| pool.frame(clock);
    }

    /// The rest of `particles_frame` (`particles.Pool.draw`).
    pub fn draw(pools: *Pools, gpa: Allocator, scene: *srcore.Scene, ahead: f32) Allocator.Error!void {
        for (&pools.by_level.values) |*slot| if (slot.*) |*pool| try pool.draw(gpa, scene, ahead);
    }

    fn get(pools: *Pools, level: Level) ?*particles.Pool {
        return if (pools.by_level.getPtr(level).*) |*pool| pool else null;
    }
};

/// A ship's smoke as it streams (`GameObject.smoke`): its emitter, and the part of its model the
/// emitter hangs from.
pub const Stream = struct {
    level: Level,
    emitter: particles.Emitter,
    part: usize,

    /// Where a model's smoke comes from: its first part, in the model's order, with an attachment
    /// of kind `engine_glow`, and the first such attachment on it. A part taken out, as an ejection
    /// takes the rest of the ship off a pilot's pod, is no longer in the model's tree to be found.
    const Point = struct {
        part: usize,
        attachment: *const shp.Attachment,

        fn of(model: *const objects.Model) ?Point {
            for (model.parts, 0..) |*part, index| {
                if (part.removed) continue;
                for (part.attachments) |*attachment| {
                    if (attachment.kind == .engine_glow) return .{ .part = index, .attachment = attachment };
                }
            }
            return null;
        }
    };

    /// `0x00494400`: the smoke for `level` from `point`, or none at `none`. Its emitter stands
    /// where the engine glow does, turned as it is, its Z axis turned back where the glow's plume
    /// burns the other way (a negative length, `size[2]`), and streams along that axis at 30 to 36
    /// a tick for longer than any mission lasts, its particles straying by its plume's spread.
    fn start(level: Level, point: Point) ?Stream {
        const made = level.plume() orelse return null;
        var orientation = point.attachment.orientation;
        if (point.attachment.size[2] < 0) {
            for ([_]usize{ 2, 5, 8 }) |along_z| orientation[along_z] = -orientation[along_z];
        }
        return .{
            .level = level,
            .part = point.part,
            .emitter = .{
                .life = endless,
                // Set each frame before it streams.
                .born = 0,
                .template = &made.template,
                .place = .{ .position = gameobj.vector(point.attachment.position), .orientation = orientation },
                .direction = .{ 0, 0, 1 },
                .spread = made.spread,
                .speed = speed,
                .speed_range = speed_range,
            },
        };
    }

    /// `mission_frame`'s work on a ship's smoke each frame: its stream starts its life again now,
    /// carries a quarter of the ship's velocity, which is a step's, on, and sends its particles
    /// out from the part it hangs from. A ship at `burning` sets a small fireball off one frame in
    /// ten where its smoke leaves it, reckoned from its root rather than the part: 0.1 to 0.3 of
    /// the ship's radius across, for 0.9 seconds, drifting with its smoke.
    fn send(stream: *Stream, world: gameobj.World, pools: *Pools, slot: *const create.Slot) void {
        const sending = world.sending() orelse return;
        const pool = pools.get(stream.level) orelse return;
        const carrier = (slot.model orelse return).parts[stream.part].object;
        const carried = gameobj.vector(slot.object.velocity) * @as(Vector, @splat(carried_share));
        stream.emitter.born = sending.clock.frame_start;
        stream.emitter.inherited = carried;
        _ = pool.stream(&stream.emitter, .{ .position = carrier.position, .orientation = carrier.orientation }, sending);
        if (slot.object.smoke_level != .burning or sending.random.rand() % fireball_odds != 0) return;
        const at = slot.drawn.point(stream.emitter.place.position);
        const size = (sending.random.fraction() * fireball_size_range + fireball_size) * slot.object.radius;
        explode.fireballAt(world, at, .{ .size = size, .life = fireball_life, .velocity = carried });
    }

    /// How long a stream lives, in ticks, and how fast its particles leave, a tick, and up to how
    /// much faster (`smoke_start`: `0x00494699`, `0x00494679` and `0x00494689`).
    const endless = 999999;
    const speed: f32 = 30;
    const speed_range: f32 = 6;
    /// The share of the ship's velocity, a step's, that its smoke carries on with, a tick's
    /// (`mission_frame`, `0x00492E97`).
    const carried_share: f32 = 0.25;
    /// A fireball one frame in this many (`0x00492ED0`), this share of the ship's radius and up to
    /// `fireball_size_range` more across (`0x004DC420`, `0x004DC3F8`), for this many ticks
    /// (`0x00492F27`).
    const fireball_odds = 10;
    const fireball_size: f32 = 0.1;
    const fireball_size_range: f32 = 0.2;
    const fireball_life = 90;
};

/// `mission_frame`'s smoke, in its pass over the objects after the particles' frame and the
/// camera's: a ship a pilot has left (`GameObject.Flags.abandoned`) has its smoke let go and its
/// level reset. Then each object the pass does not leave out (`GameObject.Flags.outOfFrame`) has
/// its smoke sent out (`Stream.send`), and one with stats, save the Ripper, has its level followed:
/// when it changes, its smoke starts again for the new level from its model's first engine glow,
/// and a model without one keeps what smoke it has.
///
/// OpenReliant reckons which particles are behind the camera by the camera's last frame, which it
/// frames after this; the game frames the camera first.
pub fn frame(world: gameobj.World) void {
    const all = world.objects;
    var walk = all.walk();
    while (walk.next()) |index| {
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.abandoned) {
            slot.smoke = null;
            object.smoke_level = .none;
        }
        if (object.flags.outOfFrame()) continue;
        if (slot.smoke) |*stream| if (world.smoke) |pools| stream.send(world, pools, slot);
        const combat = slot.combat orelse continue;
        if (object.type == .ripper) continue;
        const level: Level = .of(object, combat);
        if (level == object.smoke_level) continue;
        object.smoke_level = level;
        const model = if (slot.model) |*model| model else continue;
        const point = Stream.Point.of(model) orelse continue;
        slot.smoke = .start(level, point);
    }
}

test "Level.of" {
    var object = gameobj.testing.object();
    const combat = create.testing.tables().combat[0];
    // Its full armour is 30 a quadrant and its full shields 48.
    object.armor = .all(30);
    try std.testing.expectEqual(Level.none, Level.of(&object, &combat));
    object.armor.right = 26;
    try std.testing.expectEqual(Level.light, Level.of(&object, &combat));
    object.armor.fore = 20;
    try std.testing.expectEqual(Level.heavy, Level.of(&object, &combat));
    object.armor.aft = 14;
    try std.testing.expectEqual(Level.burning, Level.of(&object, &combat));

    // With its shields up, whatever its right quadrant holds, smoke showing thins and none starts.
    object.shields = .all(48);
    object.shields.right = 0;
    object.smoke_level = .burning;
    try std.testing.expectEqual(Level.light, Level.of(&object, &combat));
    object.smoke_level = .none;
    try std.testing.expectEqual(Level.none, Level.of(&object, &combat));
    object.shields.left = 40;
    try std.testing.expectEqual(Level.burning, Level.of(&object, &combat));
}

test "Stream.start" {
    var glow = std.mem.zeroes(shp.Attachment);
    glow.kind = .engine_glow;
    glow.position = .{ .x = 1, .y = 2, .z = -50 };
    glow.orientation = math.identity;
    const point: Stream.Point = .{ .part = 3, .attachment = &glow };
    try std.testing.expectEqual(null, Stream.start(.none, point));

    // It stands where the glow does and streams along its Z axis, straying by the level's spread.
    const light = Stream.start(.light, point).?;
    try std.testing.expectEqual(3, light.part);
    try std.testing.expectEqual(Vector{ 1, 2, -50 }, light.emitter.place.position);
    try std.testing.expectEqual(math.identity, light.emitter.place.orientation);
    try std.testing.expectEqual(Vector{ 0.15, 0.15, 0 }, light.emitter.spread);
    try std.testing.expectEqual(&light_plume.template, light.emitter.template);

    // A glow whose plume burns the other way turns the Z axis back.
    glow.size = .{ 1, 1, -2 };
    const burning = Stream.start(.burning, point).?;
    try std.testing.expectEqual(math.Matrix{ 1, 0, 0, 0, 1, 0, 0, 0, -1 }, burning.emitter.place.orientation);
    try std.testing.expectEqual(Vector{ 0.25, 0.25, 0 }, burning.emitter.spread);
}

test frame {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    var glow = [1]shp.Attachment{std.mem.zeroes(shp.Attachment)};
    glow[0].kind = .engine_glow;
    glow[0].position = .{ .x = 0, .y = 0, .z = -50 };
    glow[0].orientation = math.identity;
    model.data[0].attachments = &glow;
    const index = try mission.addWith(model.types(), .predator, @splat(0));
    const slot = mission.slot(index);
    @import("../main.zig").frameObjects(mission.objects, .{}, mission.clock.frame_start);

    var image: srtexture.Image = undefined;
    var pools: Pools = .{};
    defer pools.deinit();
    for ([_]Level{ .light, .heavy, .burning }) |level| pools.by_level.set(level, try .init(gpa, 64, &image, .add));
    // The camera looks along Z from behind the ship.
    var seen: @import("../camera.zig").Camera = .{};
    seen.place.position = .{ 0, 0, -1000 };
    var world = mission.world();
    world.smoke = &pools;
    world.camera = &seen;

    // Undamaged, it smokes not at all.
    frame(world);
    try std.testing.expectEqual(Level.none, slot.object.smoke_level);
    try std.testing.expectEqual(null, slot.smoke);

    // Its shields down and its armour down to two thirds, its smoke starts from its engine glow's
    // part.
    slot.object.shields = .all(0);
    slot.object.armor = .all(20);
    frame(world);
    try std.testing.expectEqual(Level.heavy, slot.object.smoke_level);
    try std.testing.expectEqual(0, slot.smoke.?.part);

    // Each frame it sends particles out, carrying a quarter of the ship's velocity.
    slot.object.velocity = .{ .x = 0, .y = 0, .z = 40 };
    mission.clock.frame_start = 10;
    mission.clock.frame_duration = 20;
    frame(world);
    try std.testing.expectEqual(10, slot.smoke.?.emitter.born);
    try std.testing.expectEqual(Vector{ 0, 0, 10 }, slot.smoke.?.emitter.inherited);
    try std.testing.expect(pools.get(.heavy).?.used > 0);
    try std.testing.expectEqual(0, pools.get(.light).?.used);

    // With its shields up, its smoke thins.
    slot.object.shields = .all(48);
    frame(world);
    try std.testing.expectEqual(Level.light, slot.object.smoke_level);
    try std.testing.expectEqual(Level.light, slot.smoke.?.level);

    // The Ripper's level is not followed.
    slot.object.shields = .all(0);
    slot.object.type = .ripper;
    frame(world);
    try std.testing.expectEqual(Level.light, slot.object.smoke_level);

    // A ship a pilot has left lets its smoke go.
    slot.object.type = .predator;
    slot.object.armor = .all(30);
    slot.object.flags.abandoned = true;
    frame(world);
    try std.testing.expectEqual(Level.none, slot.object.smoke_level);
    try std.testing.expectEqual(null, slot.smoke);

    // With its engine glow's part taken out, as a pilot's pod has, it has nowhere to smoke from.
    slot.object.flags.abandoned = false;
    slot.object.armor = .all(0);
    slot.model.?.parts[0].removed = true;
    frame(world);
    try std.testing.expectEqual(Level.burning, slot.object.smoke_level);
    try std.testing.expectEqual(null, slot.smoke);
}
