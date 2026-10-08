//! `C:\lancer\game\aiioncan.cpp`: the ion cannons of the Dark Reign, the Boridin and the rogue base,
//! which fire at a ship as Dark reign shoot (110) runs, once Dark Reign shoot (33,
//! `aifuncs.darkReignShoot`) has picked the nearest ship of its target. The cannon turns to the
//! ship and paints it with a red targeting laser as it charges, crackles with blue rays as the
//! lights on its barrel come on one by one, glows along its barrel as rings run up it, then fires a
//! beam that bursts into fireballs about the ship and destroys it. A ship that flies out of the
//! cannon's reach or line, or too close to it, breaks the lock, and the cannon starts again.
//! [The ion cannon](../../../docs/engine/ion-cannon.md) describes it.
//!
//! **Unverified:** that the textures' load (`0x0040CFB0`), the order's init and exit (`0x0040D020`,
//! `0x0040D1E0`), and the routines that make a cannon's record, free it and aim its laser
//! (`0x0040E7A0`, `0x0040E8A0`, `0x0040E970`), which lie either side of the file's known code, are
//! the file's: they do its work.
//!
//! Not ported: what a network game adds, the wait for every player at each step
//! (`ai_sequence_sync`), the towers that give up a long search, and the cannon's turn and kill sent
//! to the other players ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const shp = @import("../../formats/shp.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const ease = @import("../genilib/interf/ease.zig");
const loadout = @import("../interface/loadout/loadout.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const create = @import("create.zig");
const erayfx = @import("erayfx.zig");
const explode = @import("explode.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const matmanager = @import("matmanager.zig");
const objects = @import("objects.zig");
const radio = @import("radio.zig");
const sound3d = @import("sound3d.zig");
const xtrabits = @import("xtrabits.zig");

const log = std.log.scoped(.aiioncan);

/// The textures, which `mission_load` requires as a mission loads (`0x0040CFB0`): the targeting
/// laser's (`0x00518628`), the barrel's glow's (`0x005185B8`), the beam's first strand's
/// (`0x00518630`) and the rings' (`0x00518634`).
const laser_image = "laser2";
const glow_image = "ionc";
const beam_image = "laser3";
const ring_image = "warpin3";

/// The textures the cannons are drawn with.
pub const images = [_][]const u8{ laser_image, glow_image, beam_image, ring_image };

/// How fast the cannon turns to its ship about its Y axis, in radians each hundred ticks
/// (`0x004DC518`): slowly for a ship in one of the first `slow_turn_slots` slots, the player's
/// among them, and twice as fast for another (`0x004DC3F8`, `0x004DC4DC`). It turns while the ship
/// stands further off its Z axis, either way along it, than the angle whose cosine is `in_line`
/// (`0x004DC434`), on the plane it turns in.
const turn_per_tick: f32 = 0.01;
const slow_turn: f32 = 0.2;
const fast_turn: f32 = 0.4;
const slow_turn_slots = 5;
const in_line: f32 = 0.98;

/// How close to the cannon's axis the ship must stand for the targeting laser to go up
/// (`0x004DC524`), and how far off it may stand before the lock breaks (`0x004DC528`, a double):
/// the cosines of those angles.
const aimed: f32 = 0.9063;
const lock_cone: f64 = 0.90631;

/// How close a player's ship may come to where the beam leaves, across the world's X and Z axes,
/// before the lock breaks: closer in mission `close_mission` (`0x0040D74B`, `0x0040D758`).
const nearest_player: f32 = 8000;
const close_mission = 28;
const close_mission_nearest: f32 = 110000;

/// How long the cannon searches for its lock, in ticks, before it gives up (`0x0040D866`).
const longest_search = 2500;

/// The targeting laser (`Ioncannon Mesh1`): a star of `laser_blades` over `laser2`, lit by colours
/// of its own, `laser_width` wide either side, or `victorious_laser_width` at the Victorious
/// (`0x0040D965`, `0x0040D972`), and built `laser_length` long either way (`0x0040D992`). It
/// reaches out to the ship over the first `full_reach` of the charge (`0x004DC4C0`).
const laser_blades = 3;
const laser_width: f32 = 600;
const victorious_laser_width: f32 = 200;
const laser_length: f32 = 100000;
const full_reach: f32 = 0.3;

/// Moose's warning to the player that a cannon charges at the player's ship, and the ticks before
/// he may give it again (`0x0040DA28`).
const warning_line = "MOO_ICW001.ut";
const warning_gap = 1500;

/// The rays that crackle along the cannon as it powers up, blue (`0x0040DB1D`).
const power_ray: erayfx.Spec = .{ .life = 3000, .jitter = 0.1, .width = 2000, .flags = .{ .fades = true } };
const power_ray_colour = [3]f32{ 0, 0, 1 };

/// The lights on the cannon's barrel (`Ioncannon Light`, `0x0040E7A0`): white point lights as
/// bright as `light_intensity`, reaching `light_range` at that (`0x0040E805`, `0x0040E821`). Each
/// comes on `light_step` of the power step after the one before (`0x004DC3F8`).
const light_intensity: f32 = 9;
const light_range: f32 = 2000;
const light_step: f32 = 0.2;

/// The barrel's glow (`Ioncannon Mesh2`): a star of `glow_blades` over `ionc`, unlit, `glow_width`
/// wide either side (`0x0040DD71`). Over the glow step's first `glow_widening` (`0x004DC420`) it
/// widens from `glow_narrow`, and over the fire step's last `1 - glow_collapse` (`0x004DC470`) it
/// flares to `glow_flare` (`0x0040E471`) and narrows again, each at `ease_pace` times the step's
/// pace (`0x004DC520`).
const glow_blades = 4;
const glow_width: f32 = 2000;
const glow_narrow: f32 = 0.5;
const glow_widening: f32 = 0.1;
const glow_flare: f32 = 5000;
const glow_collapse: f32 = 0.9;
const ease_pace: f32 = 10;

/// How fast each blade of the glow runs along its texture, for each blade from the first, a tick
/// (`0x004DC518`): the first stands still.
const scroll_per_blade: f32 = 0.01;

/// The rings that run along the barrel as it glows (`Ioncannon Mesh3`): `ring_count` squares
/// `ring_side` across (`0x0040DDC6`), each `ring_step` of the barrel behind the one before
/// (`0x004DC3F8`), running its length `ring_laps` times over the glow step.
const ring_count = 5;
const ring_side: f32 = 6000;
const ring_step: f32 = 0.2;
const ring_laps: f32 = 2;

/// How the glow and the rings stand across the barrel in the cannon's frame: a quarter turn about
/// its X axis (`mat3_from_angles`).
const across_barrel = math.fromAngles(std.math.pi / 2.0, 0, 0);

/// The beam (`0x0040DF46`): three strands, coloured as the cannon's kind has them, the first over
/// `laser3`, its light reaching `beam_light_range` (`0x0040DF63`). The game also makes its light
/// five times as bright, which the ray's frame sets back to one.
const beam_ray: erayfx.Spec = .{ .strands = 3, .life = 3000, .jitter = 0.2, .width = 2000, .flags = .{ .fades = true } };
const beam_light_range: f32 = 100000;

/// Where the beam's end follows the ship as it fires: this far above it, along the world's Z axis
/// (`0x0040E5C1`).
const beam_lift: Vector = .{ 0, 0, 300 };

/// The fireballs the beam sets off about the ship (`0x0040E0B2`): `fireball_count`, lit, each up to
/// `fireball_spread` of the ship's radius off its centre either way on each axis and across, the
/// next `fireball_gap` ticks after the one before.
const fireball_count = 5;
const fireball_spread: f32 = 0.7;
const fireball_gap = 20;

/// The most rays and lights a cannon has.
const max_rays = 4;
const max_lights = 5;

/// The beam's strands' colours (`0x0040DF89`).
const white = [3]f32{ 1, 1, 1 };
const violet = [3]f32{ 0.3, 0, 1 };

/// What a type's cannon fires with (`order_dark_reign_shoot_110`, `0x0040E7A0`), by the type of
/// its object: the Dark Reign's `Dark Low Body` (`0x004E1C88`) turns, and the `Dark Focus`
/// (`0x004E1C7C`) on it fires; the Boridin's `Bor Ion Cannon` (`0x004E1C98`) and the rogue base's
/// `cannon` (`0x004E1CA8`) do both. Any other type is taken for the Dark Reign with no focus, as
/// the update has it; the game's init leaves the part unset for one.
const Kind = struct {
    /// The part that turns to the ship, which holds the barrel, the rays and the lights.
    cannon: []const u8,
    /// The part the laser and the beam leave from, where it isn't the cannon.
    focus: ?[]const u8 = null,
    /// How far the beam reaches from where it leaves (`0x0040D666`, `0x0040D679`).
    reach: f32 = 190000,
    /// How many rays crackle on it, and how many lights it has.
    rays: usize = max_rays,
    lights: usize = max_lights,
    /// Whether it crackles, lights up and glows as it charges, and keeps its laser up as it fires:
    /// all but the rogue base's.
    effects: bool = true,
    /// Its beam's strands' colours.
    beam: [3][3]f32 = .{ white, violet, violet },

    fn of(object_type: gameobj.Type) Kind {
        return switch (object_type.base()) {
            .boridin => .{ .cannon = "Bor Ion Cannon", .reach = 400000, .rays = 3, .lights = 3 },
            .rogue_base => .{ .cannon = "cannon", .effects = false, .beam = .{ .{ 0.5, 0, 1 }, violet, .{ 0.7, 0, 1 } } },
            .darkreign => .{ .cannon = dark_low_body, .focus = "Dark Focus" },
            else => .{ .cannon = dark_low_body },
        };
    }
};

const dark_low_body = "Dark Low Body";

/// What Dark reign shoot (110) keeps in `order_state`.
pub const State = extern struct {
    /// Its record's index (`0x0040E7A0`): always 0, the one record the game has room for.
    /// OpenReliant keeps a record for each cannon (`Cannons`).
    record: i32,
    step: Step,
    /// The tick its step began.
    step_began: i32,
    /// Its ship's slot as it began, which nothing reads.
    target: i32,
    /// The tick of its last update.
    updated: i32,
    _unknown_14: [0x90 - 0x14]u8,

    comptime {
        assert(@offsetOf(State, "step") == 0x04);
        assert(@offsetOf(State, "updated") == 0x10);
        assert(@sizeOf(State) == 0x90);
    }
};

/// Dark reign shoot's steps, each lasting its `ticks`.
pub const Step = enum(i32) {
    /// It goes on at once.
    start = 0,
    /// It waits for its ship to come into line, then puts its targeting laser up.
    aim = 1,
    /// The laser reaches out to the ship and reddens as the cannon charges.
    charge = 2,
    /// The cannon crackles, and the lights on its barrel come on one by one.
    power = 3,
    /// Its lights shine.
    ready = 4,
    /// Its barrel glows, rings running up it.
    glow = 5,
    /// Its beam strikes the ship.
    fire = 6,
    /// The ship is destroyed.
    destroy = 7,
    _,

    /// How many ticks it lasts (`0x004E1C04`); none for a step that ends on something else.
    fn ticks(step: Step) i32 {
        return switch (step) {
            .charge, .power => 300,
            .ready => 150,
            .glow => 200,
            .fire => 100,
            .start, .aim, .destroy, _ => 0,
        };
    }

    /// Whether it comes before `other`, as the game compares the steps' numbers.
    fn before(step: Step, other: Step) bool {
        return @backingInt(step) < @backingInt(other);
    }

    /// How far through it the order is at tick `now`, it having begun at `began`, as a share; none
    /// for a step with no ticks.
    fn through(step: Step, began: i32, now: i32) f32 {
        const length = step.ticks();
        if (length == 0) return 0;
        return @as(f32, @floatFromInt(now -% began)) / @as(f32, @floatFromInt(length));
    }
};

/// What `aiioncan.cpp` keeps from one order to the next: its textures, when Moose may warn the
/// player again, and a record for each cannon firing.
///
/// **Improvement:** the game has room for one record, which every cannon takes, so two firing at
/// once spoil each other's effects; OpenReliant keeps one for each.
pub const Cannons = struct {
    gpa: Allocator,
    laser: *srtexture.Image,
    glow: *srtexture.Image,
    beam: *srtexture.Image,
    ring: *srtexture.Image,
    /// `0x005185C4`: the tick before which Moose doesn't warn the player again.
    warned_until: i32 = 0,
    records: std.ArrayList(*Record) = .empty,

    /// `0x0040CFB0`, which `mission_load` runs: its textures.
    pub fn init(gpa: Allocator, textures: *srtexture.Table) matmanager.Error!Cannons {
        return .{
            .gpa = gpa,
            .laser = try matmanager.textureRequire(textures, laser_image),
            .glow = try matmanager.textureRequire(textures, glow_image),
            .beam = try matmanager.textureRequire(textures, beam_image),
            .ring = try matmanager.textureRequire(textures, ring_image),
        };
    }

    pub fn deinit(cannons: *Cannons) void {
        cannons.reset();
        cannons.records.deinit(cannons.gpa);
    }

    /// As a mission loads (`0x0040CFB0`): no cannon firing, and Moose free to warn. Their rays have
    /// gone with the mission's (`erayfx.Rays.reset`).
    pub fn reset(cannons: *Cannons) void {
        for (cannons.records.items) |record| record.destroy(cannons.gpa);
        cannons.records.clearRetainingCapacity();
        cannons.warned_until = 0;
    }

    /// The record of the cannon of the object in slot `index`, where it fires.
    pub fn of(cannons: *const Cannons, index: u16) ?*Record {
        for (cannons.records.items) |record| {
            if (record.slot == index) return record;
        }
        return null;
    }

    /// `0x0040E7A0`, and the init's set-up of the record: a record for the cannon of the object in
    /// slot `index`, of `kind`, which turns `cannon` and fires from `focus`, with where the beam
    /// leaves (the first of `focus`'s `ion_beam` points) and its lights. None where the focus lists
    /// no such point.
    ///
    /// **Fix:** the game means to stand each light in the middle of a pair of the cannon's
    /// `ion_lights` points, hanging from it, but its test is the wrong way round, so the lights stay
    /// where they were made, at the world's origin, and their sounds are heard from there.
    /// OpenReliant stands them on the cannon, as many as it lists pairs for.
    fn make(cannons: *Cannons, index: u16, kind: Kind, cannon: objects.PartOf, focus: objects.PartOf) Allocator.Error!void {
        const beam_from = first(focus.part, .ion_beam) orelse return;
        const record = try cannons.gpa.create(Record);
        errdefer cannons.gpa.destroy(record);
        record.* = .{ .slot = index, .cannon = cannon, .focus = focus, .beam_from = beam_from };
        const points = pointsOf(cannon.part, .ion_lights);
        for (record.lights[0..kind.lights], 0..) |*light, n| {
            const ends = pair(points, n) orelse break;
            light.* = (ends[0] + ends[1]) * @as(Vector, @splat(0.5));
            record.light_count = n + 1;
        }
        try cannons.records.append(cannons.gpa, record);
    }

    /// `0x0040E8A0`: lets go of the record of the cannon of the object in slot `index`, where it
    /// has one, and of its effects, its rays among `rays`.
    pub fn free(cannons: *Cannons, rays: ?*erayfx.Rays, index: u16) void {
        for (cannons.records.items, 0..) |record, at| {
            if (record.slot != index) continue;
            if (rays) |table| {
                for (record.rays) |held| {
                    if (held) |kept| if (table.kept(kept)) |ray| table.remove(ray);
                }
                if (record.beam) |kept| if (table.kept(kept)) |ray| table.remove(ray);
            }
            record.destroy(cannons.gpa);
            _ = cannons.records.swapRemove(at);
            return;
        }
    }

    /// The effects the cannons' updates showed this frame, into the scene (`scene_add` in
    /// `order_dark_reign_shoot_110`), where the parts they hang from stand as drawn: the laser from
    /// the focus, the glow, the rings and the lights from the cannon. Then none shows until the
    /// next update. A cannon whose object no longer fires shows nothing.
    pub fn draw(cannons: *Cannons, gpa: Allocator, scene: *srcore.Scene, all: *create.Objects) Allocator.Error!void {
        for (cannons.records.items) |record| {
            defer record.shown = .{};
            const slot = &all.slots[record.slot];
            if (slot.running(.dark_reign_shoot_110) == null) continue;
            const cannon = slot.partPlace(record.cannon.live(all) orelse continue) orelse continue;
            const focus = slot.partPlace(record.focus.live(all) orelse continue) orelse continue;
            const shown = record.shown;
            if (shown.laser) if (record.laser) |*laser| try laser.draw(gpa, scene, focus);
            if (shown.glow) if (record.glow) |*glow| try glow.draw(gpa, scene, cannon);
            if (shown.rings) if (record.rings) |*rings| try rings.draw(gpa, scene, cannon);
            var lit = shown.lights.iterator(.{});
            while (lit.next()) |n| {
                const light: srlight.Light = .{
                    .mask = 0,
                    .intensity = light_intensity,
                    .colour = white,
                    .kind = .{ .point = .{ .position = cannon.point(record.lights[n]), .range = light_range } },
                };
                try xtrabits.sceneAdd(gpa, scene, .{ .light = &light }, .world);
            }
        }
    }
};

/// A cannon's record (`0x005185C8`, 0x60 bytes in the game): its effects, and what its update
/// shows of them this frame.
pub const Record = struct {
    /// The cannon's object, and the parts it turns and fires from (`Kind`).
    slot: u16,
    cannon: objects.PartOf,
    focus: objects.PartOf,
    /// Where the beam leaves, in the focus's frame (`+0x4C`).
    beam_from: Vector,
    /// `+0x00`: the beam, from the fire step.
    beam: ?erayfx.Rays.Kept = null,
    /// `+0x04`: the barrel's glow, from the glow step.
    glow: ?Star = null,
    /// `+0x08`: the targeting laser, from the charge step.
    laser: ?Star = null,
    /// `+0x0C` to `+0x1C`: the rings that run up the barrel, from the glow step.
    rings: ?Rings = null,
    /// `+0x20`, counted at `+0x30`: the rays that crackle on the cannon, from the ready step.
    rays: [max_rays]?erayfx.Rays.Kept = @splat(null),
    /// `+0x34`, counted at `+0x48`: where each light stands, in the cannon's frame.
    lights: [max_lights]Vector = @splat(@splat(0)),
    light_count: usize = 0,
    /// `0x005185BC`: the last light that has come on, -1 for none.
    last_light: i32 = -1,
    /// `0x004E1C24`: the ticks the cannon has searched for its lock.
    searching: i32 = -1,
    /// What this frame shows.
    shown: Shown = .{},

    /// What the update shows this frame (`scene_add`), which `Cannons.draw` draws.
    const Shown = struct {
        laser: bool = false,
        glow: bool = false,
        rings: bool = false,
        lights: std.bit_set.Static(max_lights) = .empty,
    };

    fn destroy(record: *Record, gpa: Allocator) void {
        if (record.laser) |*laser| laser.deinit(gpa);
        if (record.glow) |*glow| glow.deinit(gpa);
        if (record.rings) |*rings| rings.deinit(gpa);
        gpa.destroy(record);
    }

    /// Every light shows this frame.
    fn showLights(record: *Record) void {
        record.shown.lights.setRangeValue(.{ .start = 0, .end = record.light_count }, true);
    }

    /// The targeting laser, from the first of `focus`'s `ion_laser` points, as wide as it is for
    /// `target`'s type (`victorious_laser_width`). None where the focus lists no such point.
    fn raiseLaser(record: *Record, cannons: *const Cannons, focus: objects.PartRef, target: *const create.Slot) Allocator.Error!void {
        const from = first(focus, .ion_laser) orelse return;
        const width = if (target.object.type.base() == .victorious) victorious_laser_width else laser_width;
        const flags: srapiext.ObjectFlags = .{ .not_culled = true, .owns_mesh = true, .baked_object = true };
        record.laser = try Star.create(cannons.gpa, laser_blades, width, .{ -laser_length, laser_length }, true, cannons.laser, flags, .{ .position = from });
    }

    /// `0x0040E970`: the targeting laser at `charge`, the focus standing at `focus` and the ship at
    /// `target`: turned from where it stands toward where the ship is drawn, it reaches out to where
    /// the ship stands, all the way once the charge is `full_reach`, and is red as bright as the
    /// charge; then it shows.
    ///
    /// **Improvement:** the game scales the reach by the charge times 3.3333333; OpenReliant
    /// divides by `full_reach`.
    fn aimLaser(record: *Record, focus: math.Place, target: *const create.Slot, charge: f32) void {
        const laser = if (record.laser) |*held| held else return;
        laser.place.orientation = math.lookAt(focus.inverse(target.drawn.position) - laser.place.position);
        @memset(laser.colours[0..laser.mesh.positions.len], .{ charge, 0, 0, 1 });
        var reach = math.distance(target.object.placeAt(.now).position, laser.place.within(focus).position);
        if (charge < full_reach) reach *= charge / full_reach;
        for (laser.mesh.positions, 0..) |*corner, n| corner.*[2] = if (guns.farCorner(n)) reach else 0;
        srapi.findBoundingBox(&laser.mesh);
        laser.object.radius = laser.mesh.radius;
        record.shown.laser = true;
    }

    /// The rays that crackle along the cannon of the object in slot `index`, `cannon`, between each
    /// pair of its `ion_rays` points, as many as `kind` has.
    fn crackle(record: *Record, world: gameobj.World, index: u16, cannon: objects.PartRef, kind: Kind) void {
        const rays = world.rays orelse return;
        const points = pointsOf(cannon, .ion_rays);
        for (record.rays[0..kind.rays], 0..) |*held, n| {
            const ends = pair(points, n) orelse return;
            const ray = rays.add(power_ray, world.random) catch return;
            ray.colour(0, power_ray_colour);
            ray.from = ends[0];
            ray.to = ends[1];
            ray.hang(.{ .part = .{ .object = index, .part = cannon } });
            ray.owner = index;
            held.* = rays.keep(ray);
        }
    }

    /// The lights coming on, `t` of the way through the power step, the cannon standing at
    /// `cannon`: the next light whose share of the step it is in comes on for this frame, heard
    /// (`BIGON`), and the lights before it that the step has passed stay dark.
    fn lightUp(record: *Record, world: gameobj.World, cannon: math.Place, t: f32) void {
        for (record.lights[0..record.light_count], 0..) |light, n| {
            const from = @as(f32, @floatFromInt(n)) * light_step;
            if (t < from or t > from + light_step or record.last_light >= @as(i32, @intCast(n))) continue;
            record.last_light = @intCast(n);
            sound3d.playFrom(world, .{ .position = cannon.point(light), .orientation = cannon.orientation }, .bigon, .guaranteed);
            record.shown.lights.set(n);
        }
    }

    /// The barrel's glow, standing in the middle of the cannon's two `ion_barrel` points and as
    /// long, and the rings that run between them. None where the cannon lists no such points.
    fn raiseGlow(record: *Record, cannons: *const Cannons, cannon: objects.PartRef) Allocator.Error!void {
        const ends = pair(pointsOf(cannon, .ion_barrel), 0) orelse return;
        const half = math.distance(ends[0], ends[1]) * 0.5;
        const middle = (ends[0] + ends[1]) * @as(Vector, @splat(0.5));
        const flags: srapiext.ObjectFlags = .{ .not_culled = true, .owns_mesh = true };
        record.glow = try Star.create(cannons.gpa, glow_blades, glow_width, .{ -half, half }, false, cannons.glow, flags, .{ .position = middle, .orientation = across_barrel });
        record.rings = try Rings.create(cannons.gpa, cannons.ring);
    }

    /// The beam, from where it leaves the focus of the cannon of the object in slot `index`,
    /// `focus`, standing at `focus_at`, to `target`'s ship, coloured as `kind` has it; and the
    /// fireballs it sets off about the ship.
    fn fire(record: *Record, world: gameobj.World, cannons: *const Cannons, index: u16, kind: Kind, focus: objects.PartRef, focus_at: math.Place, target: *const create.Slot) void {
        if (world.rays) |rays| beam: {
            const ray = rays.add(beam_ray, world.random) catch break :beam;
            ray.light.kind.point.range = beam_light_range;
            for (kind.beam, 0..) |rgb, strand| ray.colour(strand, rgb);
            ray.quadsOver(0, cannons.beam);
            ray.hang(.{ .part = .{ .object = index, .part = focus } });
            ray.from = record.beam_from;
            ray.to = focus_at.inverse(target.drawn.position);
            ray.owner = index;
            record.beam = rays.keep(ray);
        }
        const spread = target.object.radius * fireball_spread;
        for (0..fireball_count) |n| {
            const at = target.drawn.position + world.random.centredVector(@splat(spread));
            explode.fireballAt(world, at, .{ .size = world.random.fraction() * spread, .light = true, .delay = @intCast(n * fireball_gap) });
        }
    }
};

/// A star of blades with a mesh of its own (`guns.starMesh`, `mesh_object_create`), hanging from a
/// part of the cannon: the targeting laser and the barrel's glow.
const Star = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level = undefined,
    object: srapiext.MeshObject,
    /// Where it stands in its part's frame.
    place: math.Place,
    /// How far its blades run along its axis either way, as built.
    along: [2]f32,
    /// Its own colours, a vertex each, where its object takes them.
    colours: [glow_blades * guns.blade_corners][4]f32 = @splat(@splat(0)),

    /// Built over the whole of `image`, drawn added and coloured by its lighting where `lit`, its
    /// object of `flags`.
    fn create(gpa: Allocator, blades: u8, width: f32, along: [2]f32, lit: bool, image: *srtexture.Image, flags: srapiext.ObjectFlags, place: math.Place) Allocator.Error!Star {
        const mesh = try guns.starMesh(gpa, blades, width, along, .{ .{ 0, 0 }, .{ 1, 1 } }, guns.meshMaterial(lit), image);
        return .{ .mesh = mesh, .object = .{ .flags = flags, .position = @splat(0), .radius = mesh.radius, .levels = &.{} }, .place = place, .along = along };
    }

    fn deinit(star: *Star, gpa: Allocator) void {
        star.mesh.deinit(gpa);
    }

    /// Its blades `width` wide either side of its axis, as long as they were built.
    ///
    /// **Improvement:** the game turns each blade by a rounded 0.7853982 and takes the engine's
    /// sine and cosine; OpenReliant computes them (`guns.blade`).
    fn widen(star: *Star, width: f32) void {
        const blades = star.mesh.positions.len / guns.blade_corners;
        for (0..blades) |blade| {
            star.mesh.positions[blade * guns.blade_corners ..][0..guns.blade_corners].* = guns.blade(blade, blades, width, star.along);
        }
        srapi.findBoundingBox(&star.mesh);
        star.object.radius = star.mesh.radius;
    }

    /// Its blades' texture run along them by tick `now`, each by `scroll_per_blade` a tick more
    /// than the blade before.
    fn scroll(star: *Star, now: i32) void {
        const uv = star.mesh.uv[0] orelse return;
        const blades = uv.len / guns.blade_corners;
        for (0..blades) |blade| {
            const along = @as(f32, @floatFromInt(now)) * @as(f32, @floatFromInt(blade)) * scroll_per_blade;
            uv[blade * guns.blade_corners ..][0..guns.blade_corners].* = guns.bladeCorners(.{ .{ 0, along + 1 }, .{ 1, along } });
        }
    }

    /// Into the world's layer, its part standing at `part`.
    fn draw(star: *Star, gpa: Allocator, scene: *srcore.Scene, part: math.Place) Allocator.Error!void {
        const stands = star.place.within(part);
        star.object.position = stands.position;
        star.object.orientation = stands.orientation;
        // What the object points into lives in the star itself.
        star.level = .{.{ .mesh = &star.mesh, .until = std.math.inf(f32) }};
        star.object.levels = &star.level;
        if (star.object.flags.baked_object) star.object.baked = star.colours[0..star.mesh.positions.len];
        try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &star.object }, .world);
    }
};

/// The rings that run up the barrel as it glows: squares `ring_side` across over the whole of
/// `warpin3`, unlit and added (`loadout.addedSquare`), standing across the barrel. The game builds a
/// mesh for each; OpenReliant one for them all.
const Rings = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level = undefined,
    objects: [ring_count]srapiext.MeshObject,
    /// Where each stands along the barrel, in the cannon's frame.
    at: [ring_count]Vector = @splat(@splat(0)),

    fn create(gpa: Allocator, image: *srtexture.Image) Allocator.Error!Rings {
        const mesh = try loadout.addedSquare(gpa, ring_side, ring_side, false, image);
        // `0x4800`: never culled, and its mesh its own, which here the five share.
        const object: srapiext.MeshObject = .{ .flags = .{ .not_culled = true }, .position = @splat(0), .radius = mesh.radius, .levels = &.{} };
        return .{ .mesh = mesh, .objects = @splat(object) };
    }

    fn deinit(rings: *Rings, gpa: Allocator) void {
        rings.mesh.deinit(gpa);
    }

    /// Each ring `t` of the way through the glow step: `ring_step` of the way from `ends[0]` to
    /// `ends[1]` behind the one before, `ring_laps` times along over the step, coming round to the
    /// first end once past the second.
    fn run(rings: *Rings, ends: [2]Vector, t: f32) void {
        for (&rings.at, 0..) |*at, n| {
            const along = @as(f32, @floatFromInt(n)) * ring_step + t * ring_laps;
            at.* = math.lerp(ends[0], ends[1], along - @floor(along));
        }
    }

    /// Into the world's layer, the cannon standing at `cannon`.
    fn draw(rings: *Rings, gpa: Allocator, scene: *srcore.Scene, cannon: math.Place) Allocator.Error!void {
        rings.level = .{.{ .mesh = &rings.mesh, .until = std.math.inf(f32) }};
        for (&rings.objects, rings.at) |*object, at| {
            const stands = (math.Place{ .position = at, .orientation = across_barrel }).within(cannon);
            object.position = stands.position;
            object.orientation = stands.orientation;
            object.levels = &rings.level;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = object }, .world);
        }
    }
};

/// The points of `kind` that `ref`'s part lists (`node_point_group`); none where it lists none.
fn pointsOf(ref: objects.PartRef, kind: shp.PointList.Kind) []const shp.Point {
    const data = ref.data() orelse return &.{};
    const list = data.pointList(kind) orelse return &.{};
    return list.points;
}

/// The first of the points of `kind` that `ref`'s part lists, in its frame, where it lists one.
fn first(ref: objects.PartRef, kind: shp.PointList.Kind) ?Vector {
    const points = pointsOf(ref, kind);
    return if (points.len > 0) gameobj.vector(points[0].position) else null;
}

/// Pair `n` of `points`, in their part's frame, where they hold it.
fn pair(points: []const shp.Point, n: usize) ?[2]Vector {
    if (2 * n + 1 >= points.len) return null;
    return .{ gameobj.vector(points[2 * n].position), gameobj.vector(points[2 * n + 1].position) };
}

/// `order_dark_reign_shoot_110_init` (`0x0040D020`): the init of Dark reign shoot (110). Where the
/// object's model has its kind's parts (`Kind`), the order starts at its first step, keeping its
/// ship and the tick, and the cannon takes a record (`Cannons.make`); a record left from an object
/// that stood in its slot before goes first.
pub fn init(ctx: Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    const cannons = world.ion_cannons orelse return;
    cannons.free(world.rays, index);
    const kind: Kind = .of(slot.object.type);
    const model = if (slot.model) |*live| live else return;
    const cannon = model.partNamed(kind.cannon) orelse return;
    const focus = if (kind.focus) |name| (model.partNamed(name) orelse return) else cannon;
    slot.state.ion_cannon = .{
        .record = 0,
        .step = .start,
        .step_began = 0,
        .target = slot.orders[0].target.index,
        .updated = world.clock.frame_start,
        ._unknown_14 = @splat(0),
    };
    cannons.make(index, kind, .{ .object = index, .part = cannon }, .{ .object = index, .part = focus }) catch |err| {
        log.warn("the ion cannon of object {d} has no record: {s}", .{ index, @errorName(err) });
    };
}

/// `order_dark_reign_shoot_110_exit` (`0x0040D1E0`): the exit of Dark reign shoot (110). The
/// object's sequence points start again (`GameObject.sync_points`), and the cannon lets go of its
/// record and its effects (`Cannons.free`).
pub fn exit(ctx: Context, index: u16) void {
    const world = ctx.world;
    world.objects.slots[index].object.sync_points = @splat(0);
    if (world.ion_cannons) |cannons| cannons.free(world.rays, index);
}

/// `order_dark_reign_shoot_110` (`0x0040D210`): the update of Dark reign shoot (110), the ion
/// cannon of the object in slot `index` firing at the ship its order names, a step at a time
/// (`Step`). The Boridin stops dead each update (`ai.stop`, which also clears the lateral input
/// the game leaves). The order pops where the cannon or its focus is gone. Then:
///
/// 1. The cannon turns about its Y axis toward where the ship is drawn, where it stands off its
///    line (`in_line`), at its rate for the ship (`slow_turn`).
/// 2. Where the ship has gone, or explodes, the order pops.
/// 3. From the charge step to the glow step, unless the ship is the Victorious: the lock breaks
///    where the ship is cloaked, out of the beam's reach (`Kind.reach`), a player's ship too near
///    (`nearest_player`), or off the cannon's line (`lock_cone`). Unless the mission's script holds
///    the lock (`ion_cannons_hold_lock`), the order pops and pushes itself again at the ship, whole,
///    so the cannon starts again.
/// 4. Before the glow step, the cannon gives up after `longest_search` ticks, and the order pops;
///    the ready step starts the count again.
/// 5. Then the step: the laser goes up once the ship is in line (`aimed`), and charges, Moose
///    warning the player (`warning_line`); the cannon crackles (`ICHARGE`) and its lights come on;
///    its barrel glows and the rings run up it; it fires (`ILASER`), the beam's end following the
///    ship as the glow flares and the rays fade; and the ship is destroyed, though not while the
///    director's view shows the player's ship being fired at. A ship of a type with a component
///    loss routine loses its hull (`explode.loseComponent`); another, unless it is fully
///    invulnerable, is destroyed with no pilot ejecting (`ai.objectDestroyed`).
///
/// The rogue base's cannon neither crackles nor lights up nor glows, and its laser goes down as it
/// fires. Each effect shows on the frame its step puts it up (`Cannons.draw`).
pub fn update(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.ion_cannon;
    const now = world.clock.frame_start;
    const ticks = now -% state.updated;
    state.updated = now;
    const kind: Kind = .of(object.type);
    if (object.type.base() == .boridin) ai.stop(object);
    const cannons = world.ion_cannons orelse return aigeneric.end(ctx, index);
    const record = cannons.of(index) orelse return aigeneric.end(ctx, index);
    const model = if (slot.model) |*live| live else return aigeneric.end(ctx, index);
    const cannon = model.partNamed(kind.cannon) orelse return aigeneric.end(ctx, index);
    const focus = if (kind.focus) |name| (model.partNamed(name) orelse return aigeneric.end(ctx, index)) else cannon;
    const cannon_at = slot.partPlace(cannon.part()) orelse return aigeneric.end(ctx, index);
    const focus_at = slot.partPlace(focus.part()) orelse return aigeneric.end(ctx, index);
    const target_index = slot.orders[0].target.slotIn(all) orelse return stop(ctx, index, cannons);
    const target = &all.slots[target_index];
    const step = state.step;
    const t = step.through(state.step_began, now);

    // It turns toward the ship, on the plane it turns in.
    var toward = cannon_at.inverse(target.drawn.position);
    toward[1] = 0;
    const off = @abs(math.cosineOff(toward, .{ 0, 0, 1 }));
    if (off < in_line and toward[0] != 0) {
        const rate: f32 = if (target_index < slow_turn_slots) slow_turn else fast_turn;
        const by = rate * (@as(f32, @floatFromInt(ticks)) * turn_per_tick);
        cannon.model.swivel(cannon.index, .{ 0, if (toward[0] > 0) by else -by, 0 });
        cannon.model.pose(cannon.index);
    }

    if (target.object.gone() or target.orders[0].order == .explode) return stop(ctx, index, cannons);

    const locking = !step.before(.charge) and step.before(.fire) and target.object.type.base() != .victorious;
    if (locking and lockBreaks(world, target, target_index, focus_at.point(record.beam_from), kind, off)) {
        const held = if (world.variables) |variables| variables.ion_cannons_hold_lock != 0 else false;
        if (!held) {
            stop(ctx, index, cannons);
            _ = aigeneric.giveShip(ctx, index, .dark_reign_shoot_110, target_index, null);
            return;
        }
    }

    record.searching +%= ticks;
    if (step.before(.glow) and record.searching > longest_search) return stop(ctx, index, cannons);

    switch (step) {
        .start => advance(state, now),
        .aim => if (off > aimed) {
            advance(state, now);
            record.raiseLaser(cannons, focus, target) catch |err| log.warn("the ion cannon of object {d} has no laser: {s}", .{ index, @errorName(err) });
        },
        .charge => {
            record.aimLaser(focus_at, target, @min(t, 1));
            if (target_index == all.player and cannons.warned_until < now) {
                cannons.warned_until = now + warning_gap;
                radio.mooseSays(world, warning_line, .queued, radio.no_expiry);
            }
            if (t >= 1) advance(state, now);
        },
        .power => {
            record.aimLaser(focus_at, target, 1);
            if (t >= 1) {
                advance(state, now);
                sound3d.playIn(world, null, null, index, .icharge, 1, .guaranteed);
                if (kind.effects) record.crackle(world, index, cannon, kind);
            }
            if (kind.effects) record.lightUp(world, cannon_at, t);
        },
        .ready => {
            record.searching = 0;
            record.aimLaser(focus_at, target, 1);
            if (kind.effects) record.showLights();
            if (t >= 1) {
                advance(state, now);
                if (kind.effects) record.raiseGlow(cannons, cannon) catch |err| log.warn("the ion cannon of object {d} has no glow: {s}", .{ index, @errorName(err) });
            }
        },
        .glow => {
            if (kind.effects) record.showLights();
            record.aimLaser(focus_at, target, 1);
            if (t >= 1) {
                advance(state, now);
                sound3d.playIn(world, null, null, index, .ilaser, 1, .guaranteed);
                record.fire(world, cannons, index, kind, focus, focus_at, target);
                return;
            }
            if (!kind.effects) return;
            const glow = if (record.glow) |*held| held else return;
            if (t < glow_widening) glow.widen(ease.in(glow_narrow, glow_width, t * ease_pace));
            glow.scroll(now);
            if (record.rings) |*rings| if (pair(pointsOf(cannon, .ion_barrel), 0)) |ends| {
                rings.run(ends, t);
                record.shown.rings = true;
            };
            record.shown.glow = true;
        },
        .fire => {
            if (kind.effects) {
                record.showLights();
                record.shown.glow = record.glow != null;
            }
            if (t >= 1) return advance(state, now);
            if (kind.effects) if (record.glow) |*glow| {
                if (t > glow_collapse) glow.widen(ease.linear(glow_flare, glow_narrow, (t - glow_collapse) * ease_pace));
                glow.scroll(now);
                if (world.rays) |rays| for (record.rays) |held| {
                    if (held) |kept| if (rays.kept(kept)) |ray| ray.colour(0, .{ 0, 0, 1 - t });
                };
            };
            if (record.beam) |kept| if (world.rays) |rays| if (rays.kept(kept)) |ray| {
                ray.to = focus_at.inverse(target.drawn.position + beam_lift);
            };
            if (kind.effects) record.aimLaser(focus_at, target, 1);
        },
        .destroy => {
            if (world.view == .director and target_index == all.player) return;
            cannons.free(world.rays, index);
            destroyShip(ctx, target_index);
            aigeneric.end(ctx, index);
        },
        _ => {},
    }
}

/// The order on to its next step at tick `now` (`ai_sequence_sync`, which waits for every player
/// in a network game).
fn advance(state: *State, now: i32) void {
    state.step = @fromBackingInt(@backingInt(state.step) + 1);
    state.step_began = now;
}

/// `0x0040E8A0` and `order_pop`: the cannon of the object in slot `index` lets go of its effects
/// (`Cannons.free`), and the order pops.
fn stop(ctx: Context, index: u16, cannons: *Cannons) void {
    cannons.free(ctx.world.rays, index);
    aigeneric.end(ctx, index);
}

/// Whether the cannon loses its lock on the ship in slot `target_index`, `target`, its beam leaving
/// from `from` and the ship standing `off` the cannon's line (`order_dark_reign_shoot_110`'s
/// cosine): where the ship is cloaked, out of `kind`'s reach, a player's ship too near across the
/// world's X and Z axes, or off the lock's cone.
fn lockBreaks(world: gameobj.World, target: *const create.Slot, target_index: u16, from: Vector, kind: Kind, off: f32) bool {
    const at = target.drawn.position;
    var breaks = target.object.flags.cloaked;
    if (math.distance(from, at) > kind.reach) breaks = true;
    if (target_index < world.objects.players) {
        const nearest = if (world.objects.mission_number == close_mission) close_mission_nearest else nearest_player;
        if (math.distance(.{ from[0], 0, from[2] }, .{ at[0], 0, at[2] }) < nearest) breaks = true;
    }
    if (off < lock_cone) breaks = true;
    return breaks;
}

/// How the beam ends the ship in slot `index` (`0x0040E655`): a ship of a type with a component loss
/// routine (`explode.ComponentLoss`) loses its hull, the first part of its model of the hull's
/// class; another, unless it is fully invulnerable, is destroyed, spinning and with no pilot
/// ejecting (`object_destroyed_net`).
///
/// **Fix:** the game stops with an assertion where a ship with a routine has no hull part;
/// OpenReliant destroys it as it destroys another.
fn destroyShip(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    if (explode.ComponentLoss.of(slot.object.type)) |routine| if (hullOf(slot)) |hull| {
        _ = explode.loseComponent(ctx, index, routine, hull);
        return;
    };
    if (slot.object.invulnerable != .full) ai.objectDestroyed(ctx, index, true, true);
}

/// The first part of the model of the object in `slot` of the hull's class, in the order the
/// root's child list holds them, leaving out any taken out of the model.
fn hullOf(slot: *create.Slot) ?objects.PartRef {
    const model = if (slot.model) |*live| live else return null;
    for (model.parts, 0..) |part, index| {
        if (!part.removed and part.class == .hull) return .{ .model = model, .index = index };
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
}

pub const testing = struct {
    /// The cannons and the rays over a table holding nothing but their textures.
    pub const Built = struct {
        textures: *srtexture.testing.Textures,
        rays: erayfx.Rays,
        cannons: Cannons,

        pub fn init(built: *Built, gpa: Allocator) !void {
            built.textures = try srtexture.testing.Textures.init(gpa, &images);
            errdefer built.textures.deinit(gpa);
            built.rays = try .init(gpa, &built.textures.table);
            built.cannons = try .init(gpa, &built.textures.table);
        }

        pub fn deinit(built: *Built, gpa: Allocator) void {
            built.cannons.deinit();
            built.rays.deinit();
            built.textures.deinit(gpa);
        }
    };
};

/// A Boridin's cannon for the tests: its one part, `Bor Ion Cannon`, with its barrel along its Y
/// axis, two pairs of points for rays, two for lights, and where its beam and its laser leave.
const TestCannon = struct {
    parts: objects.testing.Parts(1),
    lists: [5]shp.PointList,
    points: [5][4]shp.Point,

    fn init(cannon: *TestCannon) void {
        cannon.parts.init();
        const data = &cannon.parts.data[0];
        const name = "Bor Ion Cannon";
        @memcpy(data.part.name_bytes[0..name.len], name);
        const kinds = [5]shp.PointList.Kind{ .ion_barrel, .ion_rays, .ion_lights, .ion_beam, .ion_laser };
        const at = [5][]const Vector{
            &.{ .{ 0, -500, 0 }, .{ 0, 500, 0 } },
            &.{ .{ 0, 0, 0 }, .{ 0, 100, 0 }, .{ 0, 0, 0 }, .{ 0, -100, 0 } },
            &.{ .{ 10, 0, 0 }, .{ 30, 0, 0 }, .{ -10, 0, 0 }, .{ -30, 0, 0 } },
            &.{.{ 0, 0, 100 }},
            &.{.{ 0, 0, 50 }},
        };
        for (&cannon.lists, &cannon.points, kinds, at) |*list, *held, kind, positions| {
            for (held[0..positions.len], positions) |*point, position| point.* = .{ ._unknown_00 = 0, .vertex = 0, .position = gameobj.vec3(position) };
            list.* = .{ .kind = kind, .points = held[0..positions.len] };
        }
        data.point_lists = &cannon.lists;
    }
};

/// A mission with the player's ship, a Boridin at the origin with the test cannon (`TestCannon`),
/// and a Sabre straight ahead of it, whose world reaches the explosions, the rays and the cannons.
/// It is set up where it stays, since its records point into it.
const Fixture = struct {
    stage: explode.testing.Stage,
    built: testing.Built,
    model: TestCannon,
    kind: create.Type,
    boridin: u16,
    sabre: u16,

    fn init(fixture: *Fixture) !void {
        try fixture.stage.init();
        errdefer fixture.stage.deinit();
        try fixture.built.init(std.testing.allocator);
        errdefer fixture.built.deinit(std.testing.allocator);
        fixture.model.init();
        fixture.kind = .{ .model = &fixture.model.parts.source, .loaded = &fixture.model.parts.loaded };
        const mission = &fixture.stage.mission;
        _ = try mission.add(.of(.predator), .{ 0, 0, -50000 });
        fixture.boridin = try mission.addWith(create.testing.oneType(&fixture.kind), .of(.boridin), @splat(0));
        fixture.sabre = try mission.add(.of(.sabre), .{ 0, 0, 50000 });
    }

    fn deinit(fixture: *Fixture) void {
        fixture.built.deinit(std.testing.allocator);
        fixture.stage.deinit();
    }

    fn world(fixture: *Fixture) gameobj.World {
        var reached = fixture.stage.world();
        reached.rays = &fixture.built.rays;
        reached.ion_cannons = &fixture.built.cannons;
        return reached;
    }
};

test "the Boridin's cannon charges, fires and destroys a ship" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const mission = &fixture.stage.mission;
    const boridin = fixture.boridin;
    const sabre = fixture.sabre;
    mission.slot(sabre).object.flags.targetable = true;
    const ctx: aigeneric.Context = .of(fixture.world());
    const cannons = &fixture.built.cannons;
    const rays = &fixture.built.rays;
    const state = &mission.slot(boridin).state.ion_cannon;

    // The order starts, takes a record, and goes on to aim at the Sabre, straight ahead.
    try std.testing.expect(try aigeneric.push(ctx, boridin, .dark_reign_shoot_110, .at(sabre, null)));
    mission.ordersAfter(ctx, boridin, 0);
    try std.testing.expectEqual(.aim, state.step);
    const record = cannons.of(boridin).?;
    try std.testing.expectEqual(2, record.light_count);
    try std.testing.expectEqual(@as(Vector, .{ 20, 0, 0 }), record.lights[0]);

    // In line, its laser goes up, and reaches a third of the way at a tenth of the charge, dim red.
    mission.ordersAfter(ctx, boridin, 0);
    try std.testing.expectEqual(.charge, state.step);
    mission.ordersAfter(ctx, boridin, 30);
    const laser = &record.laser.?;
    try std.testing.expect(record.shown.laser);
    try std.testing.expectApproxEqAbs(0.1, laser.colours[0][0], 1e-6);
    try std.testing.expectApproxEqRel((50000 - 50) / 3.0, laser.mesh.positions[1][2], 1e-4);

    // Charged, its lights come on in turn, and at the end of the step it crackles with a ray
    // between each pair of its points.
    mission.ordersAfter(ctx, boridin, 270);
    try std.testing.expectEqual(.power, state.step);
    mission.ordersAfter(ctx, boridin, 0);
    try std.testing.expect(record.shown.lights.isSet(0));
    try std.testing.expectEqual(0, record.last_light);
    record.shown = .{};
    mission.ordersAfter(ctx, boridin, 60);
    try std.testing.expect(record.shown.lights.isSet(1) and !record.shown.lights.isSet(0));
    mission.ordersAfter(ctx, boridin, 240);
    try std.testing.expectEqual(.ready, state.step);
    try std.testing.expect(record.rays[0] != null and record.rays[1] != null and record.rays[2] == null);

    // Ready, then its barrel glows, widening, and its rings run up it.
    mission.ordersAfter(ctx, boridin, 150);
    try std.testing.expectEqual(.glow, state.step);
    try std.testing.expectEqual(0, record.searching);
    mission.ordersAfter(ctx, boridin, 10);
    try std.testing.expect(record.shown.glow and record.shown.rings);
    try std.testing.expectApproxEqAbs(ease.in(glow_narrow, glow_width, 0.5), @abs(record.glow.?.mesh.positions[0][1]), 1e-3);
    try std.testing.expectApproxEqAbs(-400, record.rings.?.at[0][1], 1e-3);

    // It fires: the beam runs from where it leaves to the Sabre, and five fireballs go off about
    // it.
    mission.ordersAfter(ctx, boridin, 190);
    try std.testing.expectEqual(.fire, state.step);
    const beam = rays.kept(record.beam.?).?;
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 100 }), beam.from);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 50000 }), beam.to);
    var set_off: usize = 0;
    for (fixture.stage.explosions.fireballs) |fireball| set_off += @intFromBool(fireball != null);
    try std.testing.expectEqual(fireball_count, set_off);

    // Its end follows the Sabre, and the rays fade.
    mission.ordersAfter(ctx, boridin, 50);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 50300 }), beam.to);
    try std.testing.expectEqual(0.5, rays.kept(record.rays[0].?).?.strands[0].colours[0][2]);

    // The Sabre is destroyed, and the cannon lets go of its record and its rays.
    mission.ordersAfter(ctx, boridin, 50);
    try std.testing.expectEqual(.destroy, state.step);
    mission.ordersAfter(ctx, boridin, 0);
    try std.testing.expectEqual(.explode, mission.slot(sabre).orders[0].order);
    try std.testing.expectEqual(null, cannons.of(boridin));
    for (rays.slots) |held| try std.testing.expectEqual(null, held);
    try std.testing.expectEqual(0, mission.slot(boridin).object.order_count);
}

test "the cannon starts again as its ship cloaks, unless the script holds the lock" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const mission = &fixture.stage.mission;
    const boridin = fixture.boridin;
    var world = fixture.world();
    const ctx: aigeneric.Context = .of(world);
    const cannons = &fixture.built.cannons;
    const state = &mission.slot(boridin).state.ion_cannon;
    try std.testing.expect(try aigeneric.push(ctx, boridin, .dark_reign_shoot_110, .at(fixture.sabre, null)));
    mission.ordersAfter(ctx, boridin, 0);
    mission.ordersAfter(ctx, boridin, 0);
    try std.testing.expectEqual(.charge, state.step);

    // Cloaked, the Sabre breaks the lock: the order starts again, its laser gone.
    mission.slot(fixture.sabre).object.flags.cloaked = true;
    mission.ordersAfter(ctx, boridin, 10);
    try std.testing.expectEqual(.dark_reign_shoot_110, mission.slot(boridin).orders[0].order);
    try std.testing.expectEqual(null, cannons.of(boridin));
    mission.ordersAfter(ctx, boridin, 0);
    try std.testing.expectEqual(.aim, state.step);
    try std.testing.expectEqual(null, cannons.of(boridin).?.laser);

    // While the script holds the lock, it keeps it.
    var variables: @import("../vm.zig").Variables = .{ .ion_cannons_hold_lock = 1 };
    world.variables = &variables;
    const held: aigeneric.Context = .of(world);
    mission.ordersAfter(held, boridin, 0);
    try std.testing.expectEqual(.charge, state.step);
    mission.ordersAfter(held, boridin, 10);
    try std.testing.expectEqual(.charge, state.step);
    try std.testing.expect(cannons.of(boridin).?.laser != null);
}

test lockBreaks {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.of(.predator), .{ 0, 5000, 7000 });
    const other = try mission.add(.of(.sabre), .{ 0, 0, 189000 });
    const world = mission.world();
    const dark_reign: Kind = .of(.of(.darkreign));
    // A player's ship breaks it as near as 8000 across, whatever its height.
    try std.testing.expect(lockBreaks(world, mission.slot(player), player, @splat(0), dark_reign, 1));
    try std.testing.expect(!lockBreaks(world, mission.slot(other), other, @splat(0), dark_reign, 1));
    // Past the beam's reach, or off its cone, it breaks.
    try std.testing.expect(lockBreaks(world, mission.slot(other), other, .{ 0, 0, -2000 }, dark_reign, 1));
    try std.testing.expect(lockBreaks(world, mission.slot(other), other, @splat(0), dark_reign, 0.9));
    // The Boridin's reach is longer.
    try std.testing.expect(!lockBreaks(world, mission.slot(other), other, .{ 0, 0, -2000 }, .of(.of(.boridin)), 1));
}
