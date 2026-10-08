//! A capital ship splitting in two as its hull is destroyed, in `C:\lancer\game\explode.cpp`: the
//! splits under way (`0x0055335C`), each made by `split_create` (`0x0046F480`) as
//! `explode_capship_component` (`0x0046F820`) ends the ship, and run once a frame by
//! `split_update` (`0x00470030`), by how its type splits (`sequences.zig`,
//! `explode_sequence_find`, `0x00471D30`).
//!
//! Two portals (`srapiext.Portal`) cut the ship where the split has reached. The intact parts are
//! drawn only ahead of the cut, and the wreck, a part of the ship's damaged model and a part of the
//! other half the split makes, only behind it, so that in a sweep the ship comes apart from the
//! stern forward, the cut stepping through the points of its parts' `cut` point lists.
//!
//! The other half, where it is a wreck, burns as it is made (`create.wreckMade`). The view
//! flashes (`main/flash.zig`) as the split ends near the camera, and at moments of a Latov's and a
//! Stalag's, and a split's burning bits may be bodies.
//!
//! The Ulysses' top coming away (`ulysses.zig`) takes a slot among the splits too. A Krasnaya
//! throws its arms off as it splits (`extras.throwArm`), and the Boridin breakaway's core and the
//! Dark Reign's hat go out (`extras.putOut`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const create = @import("../create.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const shockwave = @import("../shockwave.zig");
const sound3d = @import("../sound3d.zig");
const table = @import("../table.zig");
const xtrabits = @import("../xtrabits.zig");
const extras = @import("extras.zig");
pub const sequences = @import("sequences.zig");
const ulysses = @import("ulysses.zig");

/// How a ship of `ship_type`, its own number, splits (`explode_sequence_find`), or null for a type
/// with no record.
pub fn find(ship_type: gameobj.Type) ?*const sequences.Record {
    for (&sequences.records) |*record| {
        if (record.type == @backingInt(ship_type.base())) return record;
    }
    return null;
}

/// The splits under way (`0x0055335C`).
pub const Splits = struct {
    gpa: Allocator,
    slots: [max]?UnderWay = @splat(null),

    pub const max = 10;

    pub fn init(gpa: Allocator) Splits {
        return .{ .gpa = gpa };
    }

    pub fn deinit(splits: *Splits) void {
        splits.reset();
    }

    /// As a mission starts again: none under way.
    pub fn reset(splits: *Splits) void {
        for (&splits.slots) |*slot| splits.free(slot);
    }

    /// A split's free function: `split_free` (`0x0046F7D0`) lets a capital ship's go, and its
    /// points and portals with it; `ulysses_split_free` (`0x0046BCC0`) the Ulysses', and its
    /// portals.
    fn free(splits: *Splits, slot: *?UnderWay) void {
        if (slot.*) |under_way| switch (under_way) {
            .capital => |split| splits.gpa.free(split.points),
            .ulysses => {},
        };
        slot.* = null;
    }

    /// `explosions_update`'s pass over them, once a frame: each split's frame function
    /// (`split_update`, `ulysses_split_update`).
    pub fn frame(splits: *Splits, world: gameobj.World) void {
        for (&splits.slots) |*slot| {
            const under_way = &(slot.* orelse continue);
            const over = switch (under_way.*) {
                inline else => |*split| split.update(world),
            };
            if (over) splits.free(slot);
        }
    }

    /// The portals of each split cutting this frame, into the scene, which puts them in the
    /// camera's frame (`scene_add` in each split's frame function).
    pub fn draw(splits: *Splits, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        for (&splits.slots) |*slot| {
            const under_way = &(slot.* orelse continue);
            switch (under_way.*) {
                inline else => |*split| if (split.cutting) {
                    for (&split.portals) |*portal| try xtrabits.sceneAdd(gpa, scene, .{ .portal = portal }, .world);
                },
            }
        }
    }

    /// Whether the object in slot `index` is splitting, which darkens its engines' glows as it is
    /// drawn (`object_draw`'s flag 4).
    pub fn splitting(splits: *const Splits, index: u16) bool {
        for (splits.slots) |slot| {
            const under_way = slot orelse continue;
            switch (under_way) {
                inline else => |split| if (split.object == index) return true,
            }
        }
        return false;
    }

    /// Puts `split` under way in a slot (`split_slot_free`, `take`), and returns it there.
    pub fn add(splits: *Splits, world: gameobj.World, split: UnderWay) *UnderWay {
        const slot = splits.take(world);
        slot.* = split;
        return &slot.*.?;
    }

    /// `split_slot_free` (`0x0046BC00`): the first slot free, or the first where all are taken.
    ///
    /// **Fix:** where all are taken, the game forgets the split in the first slot, whose portals
    /// go on cutting its ship's parts. OpenReliant ends that split first, so nothing is cut any
    /// more.
    fn take(splits: *Splits, world: gameobj.World) *?UnderWay {
        if (table.firstFree(UnderWay, &splits.slots)) |slot| return slot;
        const first = &splits.slots[0];
        if (first.*) |*under_way| switch (under_way.*) {
            inline else => |*split| split.release(world),
        };
        splits.free(first);
        return first;
    }
};

/// A split under way: a capital ship's (`Split`), or the Ulysses' top coming away
/// (`ulysses.Top`). The game keeps each kind's frame and free functions in its record (`+0x08`,
/// `+0x0C`).
pub const UnderWay = union(enum) {
    capital: Split,
    ulysses: ulysses.Top,
};

/// A capital ship's split (`split_create`, 0x44 bytes).
pub const Split = struct {
    /// The ship splitting (`+0x00`), and the tick the split began on (`+0x04`).
    object: u16,
    started: i32,
    /// Where the ship's root stood as it split (`+0x10`), which a sweep holds it at, shaking.
    at: Vector,
    /// The two portals (`+0x1C`, `+0x20`): the first cuts the intact parts, keeping what lies ahead
    /// of the cut, the second the wreck, keeping what lies behind it.
    portals: [2]srapiext.Portal,
    sequence: *const sequences.Record,
    /// The other half's slot (`+0x2C`), where it has one.
    other: ?u16 = null,
    /// How far a sweep has stepped through the points (`+0x30`).
    step: usize = 0,
    /// The last intact part of the hull hanging from the ship's root (`+0x34`), and the part of
    /// its damaged model that stays (`+0x38`).
    hull: ?usize = null,
    wreck: ?usize = null,
    /// The points of the parts' `cut` lists, in the ship's frame (`+0x3C`), in order along the
    /// ship.
    points: []Vector,
    /// Whether its portals are in the scene this frame.
    cutting: bool = false,

    /// The portals' normals, in the ship's frame.
    const normals = [2]Vector{ .{ 0, 0, -1 }, .{ 0, 0, 1 } };

    /// How far a sweep shakes the ship about where it split, along each axis (`0x004DC520`).
    const shake: f32 = 10;

    /// `split_update` (`0x00470030`), once a frame: whether the split is over.
    fn update(split: *Split, world: gameobj.World) bool {
        return switch (split.sequence.mode) {
            .sweep => split.sweep(world),
            .bursts => split.burstFrame(world),
            _ => false,
        };
    }

    /// The ship's root as it is drawn.
    fn rootPlace(split: *const Split, world: gameobj.World) math.Place {
        return world.objects.slots[split.object].drawn;
    }

    /// Point `n` of the split's, in the world, as the ship's root is drawn.
    fn worldPoint(split: *const Split, world: gameobj.World, n: usize) Vector {
        return split.rootPlace(world).point(split.points[n]);
    }

    /// A sweep's frame. While it has time and points to go, the other half may move, and the
    /// portals stand at the last point the cut reached, turned as the ship is; the ship is held
    /// where it split, shaking; and, but in its last step or for a Latov, the portals are in the
    /// scene. The cut then steps on as far as the time says: at each point a fireball, burning
    /// bits and now and then the sound of an explosion, and one step in 30 a bigger burst halfway
    /// to the bow. Once the time is up, the halves part (`sweepEnd`).
    ///
    /// **Fix:** with no other half the game frees the player's ship to move each frame, and
    /// sends it off at the end, in the other half's place (`+0x2C` is 0).
    fn sweep(split: *Split, world: gameobj.World) bool {
        const all = world.objects;
        const slot = &all.slots[split.object];
        const sequence = split.sequence;
        const random = world.random;
        const elapsed = world.clock.frame_start - split.started;
        const count = split.points.len;
        if (split.other) |other| all.slots[other].object.flags.disabled = false;
        split.cutting = false;
        if (elapsed < sequence.duration and split.step < count) {
            const reached = split.worldPoint(world, split.step -| 1);
            for (&split.portals) |*portal| {
                portal.position = reached;
                portal.orientation = split.rootPlace(world).orientation;
            }
            split.cutting = split.step + 1 < count and slot.object.type.base() != .latov;
            holdShaking(world, slot, split.at, shake);
        }
        const duration: f32 = @floatFromInt(sequence.duration);
        const per_step = duration / @as(f32, @floatFromInt(count));
        while (elapsed < sequence.duration) {
            if (@as(f32, @floatFromInt(elapsed)) / per_step <= @as(f32, @floatFromInt(split.step))) break;
            if (random.oneIn(big_burst_odds)) split.bigBurst(world);
            split.stepBurst(world);
        }
        if (elapsed <= sequence.duration or slot.object.ends.split_ended) return false;
        split.sweepEnd(world);
        return true;
    }

    /// One step's burst, at the point the cut reaches: a lit fireball, burning bits heading out
    /// from the ship or back along it, and one step in fourteen to sixteen an explosion's sound, at
    /// half to all of its volume. A Latov throws large chunks of rock straight out from the ship in
    /// place of its bits (`explode.rocks.throw`), and flashes the view at its 29th, 35th and 80th
    /// steps.
    fn stepBurst(split: *Split, world: gameobj.World) void {
        const random = world.random;
        const sequence = split.sequence;
        const at = split.worldPoint(world, split.step);
        explode.fireballAt(world, at, .{ .size = (random.fraction() * step_fireball_range + step_fireball_least) * sequence.fireball, .light = true });
        const root = split.rootPlace(world);
        const object = &world.objects.slots[split.object].object;
        const direction = if (random.oneIn(2)) math.normalize(at - root.position) else -math.forward(object.root.orientation);
        if (object.type.base() == .latov) {
            if (sequence.bits > 0 and std.mem.findScalar(usize, &latov_flash_steps, split.step) != null) flash(world);
            const out = math.normalize(at - root.position);
            for (0..@intCast(@max(sequence.bits, 0))) |_| explode.throwChunk(world, at, out, .large);
        } else {
            for (0..@intCast(@max(sequence.bits, 0))) |_| explode.throwBit(world, at, direction, .{ .size = sequence.bit_size, .speed = step_bit_speed, .bodies = sequence.bodies });
        }
        split.step += 1;
        const skew: i32 = @intFromFloat(random.centred() * sound_skew);
        if (@mod(@as(i32, @intCast(split.step)), sound_every - skew) != 0) return;
        const which: sound3d.sounds.Sound = if (random.oneIn(2)) .explosion01 else .explosion02;
        const volume = (random.fraction() + 1) * sound_volume;
        sound3d.playIn(world, at, null, null, which, volume, .not_reserved);
    }

    /// A step's bigger burst, one in `big_burst_odds`: halfway from the cut to the bow, a lit
    /// fireball of the sequence's big size, or 0.35 of the ship's radius, and fast burning bits
    /// heading out from the ship, strayed at random.
    ///
    /// **Fix:** the game gives the first such fireball of a frame whatever velocity its stack
    /// held; OpenReliant gives it none.
    fn bigBurst(split: *Split, world: gameobj.World) void {
        const random = world.random;
        const sequence = split.sequence;
        const count = split.points.len;
        const n = (@as(isize, @intCast(count)) - @as(isize, @intCast(split.step)) - 2);
        const at = split.worldPoint(world, @intCast(@divTrunc(n, 2) + @as(isize, @intCast(split.step))));
        const object = &world.objects.slots[split.object].object;
        const size = if (sequence.big_fireball > 0) sequence.big_fireball else object.radius * big_share;
        explode.fireballAt(world, at, .{ .size = size * big_fireball_share, .light = true });
        const stray = math.fromAngles(random.centred() * big_stray, random.centred() * big_stray, random.centred() * big_stray);
        const direction = math.normalize(math.transform(stray, at - split.rootPlace(world).position));
        const bits: usize = @intFromFloat(@as(f32, @floatFromInt(sequence.bits)) * @as(f32, @floatFromInt(count)) * big_bits_share);
        for (0..bits) |_| explode.throwBit(world, at, direction, .{ .size = sequence.bit_size, .speed = big_bit_speed, .bodies = sequence.bodies });
    }

    /// The steps of a Latov's sweep that flash the view.
    const latov_flash_steps = [_]usize{ 29, 35, 80 };

    /// A step's fireball is `step_fireball_least` of the sequence's fireball size and up to
    /// `step_fireball_range` more (`0x004DC550`, `0x004DC408`), and its bits leave at
    /// `step_bit_speed` (`split_update`). Its explosion is heard on the steps that are a multiple
    /// of `sound_every`, skewed by up to half `sound_skew` either way (`0x004DC834`), at
    /// `sound_volume` of its volume and up to as much again (`0x004DC408`).
    const step_fireball_least: f32 = 0.75;
    const step_fireball_range: f32 = 0.5;
    const step_bit_speed: f32 = 1;
    const sound_every = 15;
    const sound_skew: f32 = -3;
    const sound_volume: f32 = 0.5;

    /// One step in this many is a bigger burst (`split_update`); its fireball is this share of
    /// the ship's radius where the sequence names no size (`0x004DC838`), and half its size
    /// across (`0x004DC408`); it throws `big_bits_share` of the sequence's bits for each point
    /// (`0x004DC474`), which leave at `big_bit_speed` (`split_update`) and stray up to half
    /// `big_stray` either way about each axis (`0x004DC5F0`).
    const big_burst_odds = 30;
    const big_share: f32 = 0.35;
    const big_fireball_share: f32 = 0.5;
    const big_bits_share: f32 = 0.05;
    const big_bit_speed: f32 = 2;
    const big_stray: f32 = 4.5;

    /// A sweep's end, once (`GameObject.Ends.split_ended`): the portals go and nothing is cut;
    /// the other half drifts off by its type; the ship's parts all go but its wreck, and it drifts
    /// and turns slowly, or stops dead for a few types; the view flashes where the camera is near
    /// (`flashNear`); its explosion is heard, and it is recentred on what is left; and fireballs
    /// go off at its hull's `fireballs` points.
    fn sweepEnd(split: *Split, world: gameobj.World) void {
        const all = world.objects;
        const slot = &all.slots[split.object];
        const object = &slot.object;
        object.ends.split_ended = true;
        split.release(world);
        if (split.other) |other| otherHalfEnd(&all.slots[other].object, object.root.orientation);
        if (slot.model) |*model| {
            for (model.parts, 0..) |*part, index| {
                if (index == split.wreck) continue;
                if (object.type.base() == .czar_docked and part.link_id == czar_kept_link) continue;
                part.hidden = true;
            }
        }
        object.flags.unpowered = true;
        object.flags.exploding = true;
        object.velocity = .of(math.transform(object.root.orientation, drift));
        switch (object.type.base()) {
            .czar_docked, .stalag, .kafelnikof, .saladin, .victorious, .darkreign, .kronstadt => {
                object.rotation = math.identity;
                object.velocity = .of(@splat(0));
            },
            .latov => {},
            else => object.rotation = math.fromAngleVector(tumble),
        }
        flashNear(world, split.object);
        split.ending(world);
    }

    /// What every split's end does last: the ship's explosion heard from it, the ship recentred on
    /// what is left of it, and fireballs at its hull part's `fireballs` points (`endFireballs`).
    fn ending(split: *Split, world: gameobj.World) void {
        const slot = &world.objects.slots[split.object];
        sound3d.playIn(world, null, null, split.object, .capexp, 1, .player_fx);
        gameobj.recentreObject(slot);
        const model = if (slot.model) |*live| live else return;
        const hull = split.hull orelse return;
        endFireballs(world, &slot.object, .{ .model = model, .index = hull });
    }

    /// How a ship drifts once split, a step, in its own frame, and turns, a step
    /// (`split_update`).
    const drift: Vector = .{ 2, 1.4, -5 };
    const tumble: Vector = .{ -4e-05, 0.002, -0.0013 };

    /// The parts of a docked Czar of this link id stay as it splits.
    const czar_kept_link = 10;

    /// Lets the portals go, and with them what they cut (`unclip`).
    fn release(split: *Split, world: gameobj.World) void {
        split.cutting = false;
        unclip(world, split.object, split.other);
    }

    /// A bursts split's frame: a Stalag flashes the view one frame in `stalag_flash_odds`; after
    /// its first second, one frame in `burst_odds`, or `stalag_burst_odds` for a Stalag, a burst
    /// about the ship, its bits leaving at `burst_bit_speed`, which shakes the player's view for a
    /// Latov or a Stalag; once the time is up, the end (`burstsEnd`).
    fn burstFrame(split: *Split, world: gameobj.World) bool {
        const all = world.objects;
        const object = &all.slots[split.object].object;
        const elapsed = world.clock.frame_start - split.started;
        const random = world.random;
        if (object.type.base() == .stalag and random.oneIn(stalag_flash_odds)) flash(world);
        if (elapsed > bursts_after) {
            const odds: u15 = if (object.type.base() == .stalag) stalag_burst_odds else burst_odds;
            if (random.oneIn(odds)) {
                if (object.type.base() == .latov or object.type.base() == .stalag) world.shake.* = bursts_shake;
                split.burst(world, burst_bit_speed, true);
            }
        }
        if (elapsed < split.sequence.duration) return false;
        split.burstsEnd(world);
        return true;
    }

    /// A Stalag's bursts flash the view one frame in this many.
    const stalag_flash_odds = 40;

    /// Bursts start this many ticks into a bursts split, and shake the view this hard for a Latov
    /// or a Stalag; a frame bursts one time in `burst_odds`, or a Stalag's in `stalag_burst_odds`,
    /// its bits leaving at `burst_bit_speed` (`split_update`).
    const bursts_after = 100;
    const bursts_shake: f32 = 3;
    const burst_odds = 10;
    const stalag_burst_odds = 5;
    const burst_bit_speed: f32 = 0.8;

    /// A burst about the ship, at one of its points at random: two lit fireballs, the first two to
    /// three times the sequence's fireball size across and the second one to two times, up to
    /// `burst_late` ticks late; `burst_bits` times the sequence's burning bits scattered about the
    /// point heading out from the ship at `bit_speed`; and, where `heard`, an explosion's sound.
    ///
    /// **Fix:** the game takes the points, already in the ship's frame, through the frame of the
    /// part destroyed or of the hull; OpenReliant takes them as the ship stands. And it skips a
    /// ship with no points, where the game divides by none.
    fn burst(split: *const Split, world: gameobj.World, bit_speed: f32, heard: bool) void {
        if (split.points.len == 0) return;
        const random = world.random;
        const sequence = split.sequence;
        const at = split.worldPoint(world, @as(usize, random.rand()) % split.points.len);
        explode.fireballAt(world, at, .{ .size = (random.fraction() + burst_big_least) * sequence.fireball, .light = true });
        const late: i32 = random.below(burst_late);
        explode.fireballAt(world, at, .{ .size = (random.fraction() + 1) * sequence.fireball, .light = true, .delay = late });
        const direction = math.normalize(at - split.rootPlace(world).position);
        for (0..@intCast(@max(sequence.bits * burst_bits, 0))) |_| {
            explode.throwBit(world, at + random.fractionVector(@splat(burst_scatter)), direction, .{ .size = sequence.bit_size, .speed = bit_speed, .bodies = sequence.bodies });
        }
        if (heard) explode.sound(world, at, .explosions);
    }

    /// A burst's first fireball is at least this many times the sequence's size (`0x004DC404`,
    /// which the game adds twice), and its second up to `burst_late` ticks late; it throws
    /// `burst_bits` times the sequence's bits (`split_update`), which start within `burst_scatter`
    /// of the point along each axis (`0x004DC48C`).
    const burst_big_least: f32 = 2;
    const burst_late = 150;
    const burst_bits = 4;
    const burst_scatter: f32 = 50;

    /// A bursts split's end: the view flashes where the camera is near (`flashNear`); its
    /// explosion is heard; a fireball at each of its points, up to `end_late` ticks late, with
    /// burning bits; then, once, the portals go, the other half drifts off, the ship's intact parts
    /// go and its wreck shows, and it drifts and turns slowly, or stops dead for a Latov or a
    /// Stalag, which flashes the view, and whose other half stops too.
    fn burstsEnd(split: *Split, world: gameobj.World) void {
        const all = world.objects;
        const slot = &all.slots[split.object];
        const object = &slot.object;
        const random = world.random;
        const sequence = split.sequence;
        flashNear(world, split.object);
        sound3d.playIn(world, null, null, split.object, .capexp, 1, .player_fx);
        for (0..split.points.len) |n| {
            const at = split.worldPoint(world, n);
            const late: i32 = random.below(end_late);
            explode.fireballAt(world, at, .{ .size = (random.fraction() + 1) * end_share * sequence.fireball, .light = true, .delay = late });
            const direction = math.normalize(at - split.rootPlace(world).position);
            for (0..@intCast(@max(sequence.bits, 0))) |_| {
                explode.throwBit(world, at + random.fractionVector(@splat(burst_scatter)), direction, .{ .size = sequence.bit_size, .speed = sequence.bit_size * end_share, .bodies = sequence.bodies });
            }
        }
        if (object.ends.split_ended) return;
        object.ends.split_ended = true;
        split.release(world);
        if (split.other) |other| {
            const half = &all.slots[other].object;
            half.rotation = math.product(half.rotation, math.fromAngleVector(other_tumble));
            half.velocity = .of(half.velocity.vector() + math.transform(object.root.orientation, other_drift));
            half.flags.disabled = false;
        }
        if (slot.model) |*model| {
            var damaged: usize = 0;
            for (model.parts) |*part| {
                if (!part.flags.damaged) {
                    part.hidden = true;
                } else if (part.class == .hull) {
                    if (damaged == variant) part.hidden = false;
                    damaged += 1;
                }
            }
        }
        object.flags.unpowered = true;
        object.flags.exploding = true;
        if (object.type.base() == .latov or object.type.base() == .stalag) {
            object.velocity = .of(@splat(0));
            object.rotation = math.identity;
        } else {
            object.rotation = math.fromAngleVector(tumble);
            object.velocity = .of(math.transform(object.root.orientation, drift));
        }
        explode.sound(world, slot.drawn.position, .explosions);
        split.ending(world);
        if (object.type.base() == .latov or object.type.base() == .stalag) flash(world);
        if (split.other) |other| {
            const half = &all.slots[other].object;
            switch (object.type.base()) {
                .latov => half.velocity = .of(math.transform(object.root.orientation, latov_drift)),
                .stalag => {
                    half.velocity = .of(@splat(0));
                    half.rotation = math.identity;
                },
                else => {},
            }
        }
    }

    /// A bursts split's end sets its fireballs off up to this many ticks late (`split_update`), at
    /// this share of the sequence's size and up to as much again, and its bits leave at this share
    /// of their size (`0x004DC408`).
    const end_late = 75;
    const end_share: f32 = 0.5;

    /// How the other half of a split drifts off, a step, in the ship's frame, and turns, a step: a
    /// bursts split's, and a sweep's where its type has no way of its own (`otherHalfEnd`). A
    /// Latov's other half drifts off as `latov_drift` instead. The Ulysses' back drifts off by
    /// the same steps, in the world's axes (`ulysses.Top`).
    pub const other_drift: Vector = .{ -1.5, -10, -2 };
    pub const other_tumble: Vector = .{ 0.0005, 0.002, 0.002 };
    const latov_drift: Vector = .{ -5, 0, 0 };

    /// Which way a ship splits: always the first, as every sequence has only the one.
    const variant = 0;
};

/// Lights the view for a moment (`0x00587CC8`), where there is a flash.
fn flash(world: gameobj.World) void {
    if (world.flash) |lit| lit.start();
}

/// `explode_flash_near` (`0x00471D70`) for the ship in slot `index`, as the camera stands.
pub fn flashNear(world: gameobj.World, index: u16) void {
    const lit = world.flash orelse return;
    const seen = world.camera orelse return;
    lit.near(&world.objects.slots[index].object, seen.place.position);
}

/// Holds the ship in `slot` at `at`, shaken by `by` along each axis, one way or the other at
/// random, as a split under way does each frame.
pub fn holdShaking(world: gameobj.World, slot: *create.Slot, at: Vector, by: f32) void {
    var shaken = at;
    inline for (0..3) |axis| shaken[axis] += if (world.random.centred() >= 0) by else -by;
    objects.setPosition(&slot.object, &slot.drawn, shaken);
}

/// Lets a split's portals go: nothing of the ship in slot `index`, or of its other half, is cut
/// any more (`node_tree_unclip` on both).
pub fn unclip(world: gameobj.World, index: u16, other: ?u16) void {
    const all = world.objects;
    if (all.slots[index].model) |*model| xtrabits.clipTree(model, null);
    if (other) |half| if (all.slots[half].model) |*model| xtrabits.clipTree(model, null);
}

/// Sets off the fireballs of a split's end at the `fireballs` points of `ref`, a part of `ship`:
/// one at each of the first `end_fireballs`, lit, `end_fireball_share` of the ship's radius
/// across, each `end_fireball_gap` ticks after the last (`split_update`, `ulysses_split_update`).
///
/// **Fix:** the game reads three points whatever the list holds.
pub fn endFireballs(world: gameobj.World, ship: *const gameobj.GameObject, ref: objects.PartRef) void {
    const data = ref.data() orelse return;
    const list = data.pointList(.fireballs) orelse return;
    const place = ref.part().drawn();
    for (list.points[0..@min(list.points.len, end_fireballs)], 0..) |point, n| {
        const at = place.point(point.position.vector());
        explode.fireballAt(world, at, .{ .size = ship.radius * end_fireball_share, .light = true, .delay = @intCast(n * end_fireball_gap) });
    }
}

/// The fireballs as a split ends: how many, how many ticks apart, and this share of the ship's
/// radius (`0x004DC450`).
const end_fireballs = 3;
const end_fireball_gap = 50;
const end_fireball_share: f32 = 0.15;

/// An object of `piece_type` made where the ship in slot `index` is drawn and turned as it is, its
/// centre where the ship's own model has it: a split's other half, or a piece the Ulysses throws
/// off. Null where it can't be made.
pub fn makePiece(world: gameobj.World, index: u16, piece_type: gameobj.Type) ?u16 {
    const all = world.objects;
    const made = create.make(world, null, piece_type) catch null orelse return null;
    const ship = &all.slots[index];
    const piece = &all.slots[made];
    const root = ship.drawn;
    const offset = piece.object.centre.vector() - ship.object.centre.vector();
    objects.setPlace(&piece.object, &piece.drawn, .{ .position = root.point(offset), .orientation = root.orientation });
    return made;
}

/// How a sweep's other half drifts off at its end, by its type, a step in the ship's frame, and
/// turns, a step.
///
/// **Fix:** the Victorious' front half takes its own drift and turn, where the game goes on
/// into the Kronstadt's wreck's and takes that instead.
fn otherHalfEnd(half: *gameobj.GameObject, orientation: math.Matrix) void {
    const drift: Vector, const tumble: Vector = switch (half.type.base()) {
        .kronstadt_wreck => .{ .{ -1.5, 20, -2 }, @splat(0) },
        .rogue_base_wreck_top, .latov_wreck_1 => .{ .{ -1.5, -40, -2 }, @splat(0) },
        .stalag_wreck_1 => .{ .{ 0, -20, 0 }, .{ 0, 0.0005, 0 } },
        .victorious_wreck_front => .{ .{ 30, 20, 4 }, .{ 0, 0, 0.001 } },
        else => .{ Split.other_drift, Split.other_tumble },
    };
    half.rotation = math.fromAngleVector(tumble);
    half.velocity = .of(math.transform(orientation, drift));
}

/// `explode_capship_component`'s split of the ship in slot `index`, as its hull is destroyed
/// (`split_create` first):
///
/// 1. A Krasnaya throws off each arm whose engine block is still on (`extras.throwArm`), and the
///    Boridin breakaway's core goes out (`extras.putOut`). It takes a slot among the splits, with its
///    portals, where its root stands, and its points, each part's `cut` list in the ship's frame,
///    in order along it but for a Latov's; its engines stop, the Dark Reign's hat goes out, and
///    every part stops playing its track.
/// 2. Its other half, where its sequence names one, stands where it does, turned as it is, turning
///    as it turns but unpowered, still and disabled, and shows its first part, cut by the second
///    portal.
/// 3. Its intact parts, and all they carry, are cut by the first portal; the last of them of its
///    hull is kept. Of its damaged model's hull parts, a Latov shows them all, and the first is its
///    wreck, which a sweep shows at once, cut by the second portal.
/// 4. A shockwave of kind `split`, twice its radius across (`wave_size`), spreads for half as long
///    again as the split runs (`waveLife`), and a bursts split sets off five to seven bursts about
///    the ship at once, every third heard (`opening_least`).
///
/// **Fix:** a ship whose type has no sequence doesn't split, where the game reads a sequence from
/// the text before the table, which never ends. The points are sorted along the ship, where the
/// game puts one that belongs right after the first before it; and each part's are taken through
/// its place in the ship, where the game takes them through its place in the part it hangs from.
pub fn start(world: gameobj.World, index: u16) void {
    const explosions = world.explosions orelse return;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const model = if (slot.model) |*live| live else return;
    const sequence = find(object.type) orelse return;
    if (object.type.base() == .krasnaya) for (std.enums.values(extras.Side)) |side| {
        if (model.partNamed(side.block()) != null) extras.throwArm(world, index, side, side.link());
    };
    if (object.type.base() == .boridin_breakaway) extras.putOut(world, index);
    const points = cutPoints(explosions.splits.gpa, model, object.type.base() != .latov) catch return;
    const split = &explosions.splits.add(world, .{ .capital = .{
        .object = index,
        .started = world.clock.frame_start,
        .at = object.position(),
        .portals = .{ .{}, .{} },
        .sequence = sequence,
        .points = points,
    } }).capital;
    object.flags.engines_disabled = true;
    if (object.type.base() == .darkreign) extras.putOut(world, index);
    stopTracks(model);

    if (sequence.other_half) |half_type| split.other = otherHalf(world, index, @fromBackingInt(half_type), &split.portals[1]);

    var damaged: usize = 0;
    for (model.parts, 0..) |*part, at| {
        if (object.type.base() == .czar_docked and part.link_id == Split.czar_kept_link) continue;
        if (!part.flags.damaged) {
            xtrabits.clipPart(model, at, &split.portals[0]);
            if (part.class == .hull) split.hull = at;
            continue;
        }
        if (part.class != .hull) continue;
        if (object.type.base() == .latov) part.hidden = false;
        if (damaged == Split.variant) {
            if (sequence.mode != .bursts) {
                part.hidden = false;
                part.object.portal = &split.portals[1];
                part.object.flags.portal_clipped = true;
            }
            split.wreck = at;
        }
        damaged += 1;
    }

    for (&split.portals, Split.normals) |*portal, normal| {
        portal.normal = normal;
        portal.orientation = object.root.orientation;
    }
    const velocity = object.velocity.vector();
    shockwave.setOff(world, object.placeAt(.next), .{
        .kind = .split,
        .size = object.radius * wave_size,
        .life = waveLife(sequence.duration),
        .velocity = velocity,
        .owner = index,
    });
    if (sequence.mode == .bursts) {
        var n: usize = 0;
        while (n < @as(usize, world.random.below(opening_range) + opening_least)) : (n += 1) {
            split.burst(world, sequence.bit_size * opening_bit_share, n % opening_heard == 0);
        }
    }
}

/// A split's shockwave is this many times the ship's radius across (`explode_capship_component`,
/// which adds the radius to itself).
const wave_size: f32 = 2;

/// How long a split's shockwave spreads for a split that runs `duration` ticks: half as long again
/// (`explode_capship_component`).
fn waveLife(duration: i32) i32 {
    return @divTrunc(duration * 3, 2);
}

/// A bursts split opens with at least `opening_least` bursts, and goes on while a fresh draw of up
/// to `opening_range` more says so; every `opening_heard`th is heard, and their bits leave at
/// `opening_bit_share` of their size (`explode_capship_component`, `0x004DC410`).
const opening_least = 5;
const opening_range = 3;
const opening_heard = 3;
const opening_bit_share: f32 = 0.8;

/// The points of the parts' `cut` lists, in the ship's frame, each through its part's place in
/// the ship; sorted along the ship, from the stern, where `sorted`, as the parts list them
/// otherwise (`split_point_insert`, `0x0046F6D0`).
fn cutPoints(gpa: Allocator, model: *const objects.Model, sorted: bool) Allocator.Error![]Vector {
    var points: std.ArrayList(Vector) = .empty;
    errdefer points.deinit(gpa);
    for (0..model.parts.len) |index| {
        const ref: objects.PartRef = .{ .model = @constCast(model), .index = index };
        const data = ref.data() orelse continue;
        const list = data.pointList(.cut) orelse continue;
        const place = model.partPlace(index, .now);
        for (list.points) |point| try points.append(gpa, place.point(point.position.vector()));
    }
    if (sorted) std.mem.sort(Vector, points.items, {}, alongShip);
    return points.toOwnedSlice(gpa);
}

fn alongShip(_: void, a: Vector, b: Vector) bool {
    return a[2] < b[2];
}

/// `node_tree_stop` (`0x00473FB0`): every part of the model, and of every model it carries, stops
/// playing its track.
fn stopTracks(model: *objects.Model) void {
    for (model.parts) |*part| part.animation.speed = 0;
    var each = model.carried();
    while (each.next()) |mount| stopTracks(&mount.model);
}

/// The other half of the ship in slot `index`, of `half_type`, made where the ship stands
/// (`makePiece`); it turns as the ship turns, but still, unpowered and disabled; its first part
/// shows, cut by `portal`. A wreck burns as it is made (`create.wreckMade`). Null where it can't
/// be made.
fn otherHalf(world: gameobj.World, index: u16, half_type: gameobj.Type, portal: *const srapiext.Portal) ?u16 {
    const all = world.objects;
    const made = makePiece(world, index, half_type) orelse return null;
    create.wreckMade(world, made);
    const main = &all.slots[index];
    const half = &all.slots[made];
    const object = &half.object;
    object.throttle = 0;
    object.speed = 0;
    object.pitch_input = main.object.pitch_input;
    object.roll_input = main.object.roll_input;
    object.yaw_input = main.object.yaw_input;
    object.pitch_rate = main.object.pitch_rate;
    object.roll_rate = main.object.roll_rate;
    object.yaw_rate = main.object.yaw_rate;
    object.rotation = main.object.rotation;
    object.flags.unpowered = true;
    object.flags.engines_disabled = true;
    object.flags.disabled = true;
    object.flags.exploding = true;
    if (half.model) |*model| if (model.parts.len > Split.variant) {
        const shown = &model.parts[Split.variant];
        shown.hidden = false;
        shown.object.portal = portal;
        shown.object.flags.portal_clipped = true;
    };
    return made;
}

test "a capital ship sweeps apart" {
    const gpa = std.testing.allocator;
    const shp = @import("../../../formats/shp.zig");
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var fixture: create.testing.Model = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);
    // One part, of the hull, with three points to cut at, listed out of order, and one where the
    // fireballs go off at the end.
    fixture.data[0].part.class = .hull;
    var cut = [_]shp.Point{ testingPoint(100), testingPoint(-100), testingPoint(0) };
    var fireballs = [_]shp.Point{testingPoint(0)};
    var lists = [_]shp.PointList{ .{ .kind = .cut, .points = &cut }, .{ .kind = .fireballs, .points = &fireballs } };
    fixture.data[0].point_lists = &lists;
    const mission = &stage.mission;
    _ = try mission.add(.of(.kamov), @splat(0));
    const ship = try mission.addWith(fixture.types(), .of(.badanov), .{ 0, 0, 5000 });
    var world = stage.world();
    world.spawn = mission.spawn(fixture.types());
    var lit: @import("../main/flash.zig").Flash = .{};
    var watching: @import("../camera.zig").Camera = .{};
    watching.place.position = .{ 0, 0, 5000 };
    world.flash = &lit;
    world.camera = &watching;
    const splits = &stage.explosions.splits;

    // Its points go from the stern; its other half is made, still and disabled, and cut by the
    // second portal; its hull is cut by the first.
    start(world, ship);
    const split = &splits.slots[0].?.capital;
    try std.testing.expectEqual(-100, split.points[0][2]);
    try std.testing.expectEqual(100, split.points[2][2]);
    const half = &mission.objects.slots[split.other.?];
    try std.testing.expect(half.object.flags.disabled and half.object.flags.exploding);
    try std.testing.expect(half.model.?.parts[0].object.portal == &split.portals[1]);
    const hull = &mission.objects.slots[ship].model.?.parts[0];
    try std.testing.expect(hull.object.portal == &split.portals[0] and hull.object.flags.portal_clipped);
    try std.testing.expectEqual(0, split.hull.?);
    try std.testing.expect(splits.splitting(ship));

    // Its first frame puts the portals in the scene at the first point, and frees the other half.
    const first = split.worldPoint(world, 0);
    splits.frame(world);
    try std.testing.expect(split.cutting);
    try std.testing.expectEqual(first, split.portals[0].position);
    try std.testing.expect(!half.object.flags.disabled);
    // Past its time, the halves part: nothing is cut, the hull goes, and the split is over. The
    // camera stands by, so the view flashes.
    mission.clock.frame_start = split.sequence.duration + 1;
    try std.testing.expectEqual(0, lit.left);
    splits.frame(world);
    try std.testing.expectEqual(null, splits.slots[0]);
    try std.testing.expect(hull.hidden and hull.object.portal == null);
    const object = &mission.objects.slots[ship].object;
    try std.testing.expect(object.ends.split_ended and object.flags.unpowered);
    try std.testing.expectEqual(@import("../main/flash.zig").flash_ticks, lit.left);
}

test "a capital ship bursts apart" {
    const gpa = std.testing.allocator;
    const shp = @import("../../../formats/shp.zig");
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var fixture: create.testing.Model = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);
    fixture.data[0].part.class = .hull;
    var cut = [_]shp.Point{ testingPoint(-100), testingPoint(100) };
    var lists = [_]shp.PointList{.{ .kind = .cut, .points = &cut }};
    fixture.data[0].point_lists = &lists;
    const mission = &stage.mission;
    _ = try mission.add(.of(.kamov), @splat(0));
    const ship = try mission.addWith(fixture.types(), .of(.kurgan), .{ 0, 0, 5000 });
    const world = stage.world();
    const splits = &stage.explosions.splits;

    // A Kurgan bursts at once, with no other half, and its portals never cut.
    start(world, ship);
    const split = &splits.slots[0].?.capital;
    try std.testing.expectEqual(.bursts, split.sequence.mode);
    try std.testing.expectEqual(null, split.other);
    var set_off: usize = 0;
    for (stage.explosions.fireballs) |fireball| set_off += @intFromBool(fireball != null);
    try std.testing.expect(set_off >= 10);
    splits.frame(world);
    try std.testing.expect(!split.cutting);
    // At its end its intact parts go, and the split is over.
    mission.clock.frame_start = split.sequence.duration;
    splits.frame(world);
    try std.testing.expectEqual(null, splits.slots[0]);
    try std.testing.expect(mission.objects.slots[ship].model.?.parts[0].hidden);
}

fn testingPoint(z: f32) @import("../../../formats/shp.zig").Point {
    return .{ ._unknown_00 = 0, .vertex = 0, .position = .{ .x = 0, .y = 0, .z = z } };
}

test waveLife {
    // Half as long again, in whole ticks.
    try std.testing.expectEqual(1350, waveLife(900));
    try std.testing.expectEqual(1, waveLife(1));
}

test find {
    try std.testing.expectEqual(.sweep, find(.of(.badanov)).?.mode);
    try std.testing.expectEqual(0x75, find(.of(.badanov)).?.other_half.?);
    try std.testing.expectEqual(null, find(.of(.sabre)));
}

test Splits {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var splits: Splits = .init(std.testing.allocator);
    defer splits.deinit();
    for (&splits.slots, 0..) |*slot, n| slot.* = .{ .capital = .{ .object = @intCast(n), .started = 0, .at = @splat(0), .portals = .{ .{}, .{} }, .sequence = find(.of(.badanov)).?, .points = try std.testing.allocator.alloc(Vector, 1) } };
    try std.testing.expect(splits.splitting(3));
    try std.testing.expect(!splits.splitting(Splits.max));
    // All taken, a new split takes the first slot, and the one there is let go.
    const added = splits.add(mission.world(), .{ .ulysses = .{ .object = Splits.max, .started = 0, .at = @splat(0), .portals = .{ .{}, .{} } } });
    try std.testing.expect(added == &splits.slots[0].?);
    try std.testing.expect(splits.splitting(Splits.max) and !splits.splitting(0));
}

test "the Dark Reign's hat goes out as it splits" {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    _ = try stage.mission.add(.of(.kamov), @splat(0));
    var ship: create.extra.testing.DarkReign = undefined;
    const world = try ship.init(gpa, &stage, .{ 0, 0, 5000 });
    defer ship.deinit(gpa);
    start(world, ship.index);
    try std.testing.expect(stage.explosions.splits.splitting(ship.index));
    try std.testing.expectEqual(null, ship.hat(&stage));
    try std.testing.expectEqual(null, stage.explosions.streams[0]);
}

test "the Boridin breakaway's core goes out as it splits" {
    const gpa = std.testing.allocator;
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    var fixture: create.testing.Model = undefined;
    try fixture.init(gpa);
    defer fixture.deinit(gpa);
    fixture.data[0].part.class = .hull;
    const mission = &stage.mission;
    _ = try mission.add(.of(.kamov), @splat(0));
    const ship = try mission.addWith(fixture.types(), .of(.boridin_breakaway), .{ 0, 0, 5000 });
    mission.slot(ship).extra = try create.extra.makeGlow(gpa, &create.extra.testing.images, null, @splat(0), &explode.breakaway_core_sparks);
    start(stage.world(), ship);
    try std.testing.expect(stage.explosions.splits.splitting(ship));
    try std.testing.expectEqual(null, mission.slot(ship).extra);
}
