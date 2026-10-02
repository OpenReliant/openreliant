//! `C:\lancer\game\guns.cpp`'s Nova Cannon: the Phoenix's gun, which the trigger charges rather
//! than fires (`object_fire_guns`, `0x0047B1F0`) and which, let go, strikes everything straight
//! ahead of the ship at once (`nova_release`, `0x0047B3D0`). Its beam shows for `beam_ticks`
//! (`nova_beams_frame`, `0x00480690`, which `bullets_frame` runs), with strands spiralling along it
//! after a full charge.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const ease = @import("../../genilib/interf/ease.zig");
const collision = @import("../collision.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const cloak = @import("../cloak.zig");
const guns = @import("../guns.zig");
const matmanager = @import("../matmanager.zig");
const objects = @import("../objects.zig");
const shield = @import("../shield.zig");
const shieldfx = @import("../shieldfx.zig");
const table = @import("../table.zig");
const xtrabits = @import("../xtrabits.zig");

/// How much each hold of the trigger charges the cannon for each share of the power the guns take
/// (`0x004DC888`).
const charge_per_hold: f32 = 0.0025;

/// The least charge a release fires; a release short of it loses the charge (`0x004DC408`). Past
/// it the charge shakes the player's view at `charging_shake`, and at `full_charge` at
/// `charged_shake`.
const least_charge: f32 = 0.5;
const full_charge: f32 = 1;
const charging_shake: f32 = 0.3;
const charged_shake: f32 = 0.6;

/// Whether the trigger charges the cannon: on the Phoenix, firing one group, which a Nova Cannon
/// leads.
pub fn charges(object: *const gameobj.GameObject, trigger: guns.Trigger) bool {
    if (!object.type.carriesNova()) return false;
    if (object.gun_mode.all) return false;
    return guns.groupLead(trigger.fitted, trigger.groups, object.gun_mode.group) == .nova_cannon;
}

/// `object_fire_guns`'s charge: `charge_per_hold` more for each share of the power the guns take,
/// up to the full charge. The player's view, through `shake`, shakes at `charging_shake` past
/// `least_charge`, and at `charged_shake` once full.
pub fn charge(object: *gameobj.GameObject, shake: ?*f32) void {
    object.nova_charge += object.gun_factor * charge_per_hold;
    if (object.nova_charge > full_charge) {
        object.nova_charge = full_charge;
        if (shake) |view| view.* = charged_shake;
    } else if (object.nova_charge > least_charge) {
        if (shake) |view| view.* = charging_shake;
    }
}

/// How long a beam shows, in ticks, and how far ahead of the ship it strikes.
pub const beam_ticks = 80;
const beam_reach: f32 = 40000;

/// The most beams showing at once (`nova_beams`, `0x00563190`).
pub const max_beams = 8;

/// The blast's sound: the positional sound in slot 13 of `bank_stdsmp`, as loud as the ship's
/// radius times `blast_loudness` (`0x004DC438`).
const blast_sound = 13;
const blast_loudness: f32 = 2000;

/// The beam: blades round its axis, `ion_radius` wide either side before the charge's square
/// narrows it, and reaching `ion_half_length` either way of where it stands, `ion_offset` from the
/// ship: from just ahead of the ship's nose to past its strike's reach.
const ion_image = "ionc";
const ion_blades = 4;
const ion_radius: f32 = 150;
const ion_half_length: f32 = 20000;
const ion_offset: Vector = .{ 0, 50, 20680 };
const ion_corners = ion_blades * guns.blade_corners;

/// How fast each blade's texture runs along the beam, for each blade from the first, a tick
/// (`0x004DC518`): the first stands still.
const scroll_per_blade: f32 = 0.01;

/// The share of the beam's time left over which it fades out (`0x004DC3F8`).
const fade_share: f32 = 0.2;

/// The strands that spiral along the beam after a full charge: `strand_count`, each a star of
/// `strand_blades` on `laser2` `strand_radius` wide, from one point of a helix to the next.
const strand_image = "laser2";
const strand_count = 30;
const strand_blades = 2;
const strand_radius: f32 = 150;
const strand_corners = strand_blades * guns.blade_corners;

/// The helix the strands follow (`nova_helix`, `0x0047B100`): `helix_radius` about the beam,
/// `helix_turns` a unit along it, reaching `helix_length` a unit and starting `helix_start` ahead
/// of the ship, but never nearer than `helix_nearest`. Its points stand `helix_step` apart, from
/// `helix_lead` behind where the beam has got to.
///
/// **Improvement:** six turns a unit exactly, where the game rounds the angle to 37.6991.
const helix_radius: f32 = 100;
const helix_turns: f32 = 6;
const helix_length: f32 = 15000;
const helix_start: f32 = 600;
const helix_nearest: f32 = 450;
const helix_step: f32 = 0.03;
const helix_lead: f32 = 0.3;

/// The textures the beams are drawn with.
pub const images = [_][]const u8{ ion_image, strand_image };

/// The meshes the beams are drawn with, which `guns_init` builds: the beam over `ionc`, with its
/// own texture coordinates, and a strand over `laser2`, a unit long, both lit by their own colours
/// and added.
pub const Looks = struct {
    ion: srapiext.Mesh,
    strand: srapiext.Mesh,

    pub fn create(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!Looks {
        const ion_texture = try matmanager.textureRequire(textures, ion_image);
        const strand_texture = try matmanager.textureRequire(textures, strand_image);
        const ion = try guns.starMesh(gpa, ion_blades, ion_radius, .{ -ion_half_length, ion_half_length }, null, guns.ownMaterial(true), ion_texture);
        errdefer ion.deinit(gpa);
        const strand = try guns.starMesh(gpa, strand_blades, strand_radius, .{ 0, 1 }, .{ .{ 0, 0 }, .{ 1, 1 } }, guns.meshMaterial(true), strand_texture);
        return .{ .ion = ion, .strand = strand };
    }

    pub fn deinit(looks: *const Looks, gpa: Allocator) void {
        looks.ion.deinit(gpa);
        looks.strand.deinit(gpa);
    }
};

/// The object flags of a beam's and a strand's mesh: never culled, and coloured by their own
/// colours; the beam with its own texture coordinates too.
const ion_flags: srapiext.ObjectFlags = .{ .not_culled = true, .baked_object = true, .own_first = true };
const strand_flags: srapiext.ObjectFlags = .{ .not_culled = true, .baked_object = true };

/// A beam showing: whose it is, until when, and the charge it fired with.
pub const Beam = struct {
    owner: u16,
    until: i32,
    charge: f32,
    ion: srapiext.MeshObject,
    ion_level: [1]srapiext.Level,
    ion_uv: [ion_corners][2]f32 = @splat(.{ 0, 0 }),
    ion_colours: [ion_corners][4]f32 = @splat(srapiext.grey(0)),
    /// Its strands, which show after a full charge.
    strands: ?[strand_count]Strand,

    pub const Strand = struct {
        object: srapiext.MeshObject,
        level: [1]srapiext.Level,
        colours: [strand_corners][4]f32 = @splat(srapiext.grey(0)),
    };

    /// Whether it fired with the full charge.
    pub fn full(beam: Beam) bool {
        return beam.strands != null;
    }

    fn init(looks: *const Looks, owner: u16, until: i32, fired: f32) Beam {
        var beam: Beam = .{
            .owner = owner,
            .until = until,
            .charge = fired,
            .ion = .{ .flags = ion_flags, .position = @splat(0), .radius = looks.ion.radius, .levels = &.{} },
            .ion_level = .{.{ .mesh = &looks.ion, .until = std.math.inf(f32) }},
            .strands = null,
        };
        if (fired == full_charge) {
            var strands: [strand_count]Strand = undefined;
            for (&strands) |*strand| strand.* = .{
                .object = .{ .flags = strand_flags, .position = @splat(0), .radius = looks.strand.radius, .levels = &.{} },
                .level = .{.{ .mesh = &looks.strand, .until = std.math.inf(f32) }},
            };
            beam.strands = strands;
        }
        return beam;
    }

    /// `nova_beams_frame` for one beam, `now`, the ship standing at `ship`: the beam stands as the
    /// ship is turned, `ion_offset` from it, narrowed by the square of the charge; each blade's
    /// texture runs along it by `scroll_per_blade` a tick more than the blade before's, and it is
    /// lit at the ship's end and dark at the far one, fading over the last `fade_share` of its
    /// time. After a full charge, the strands follow the helix as far as the beam has got
    /// (`strandsAt`).
    fn place(beam: *Beam, ship: math.Place, now: i32) void {
        const left = @as(f32, @floatFromInt(beam.until - now)) / beam_ticks;
        const narrow = beam.charge * beam.charge;
        beam.ion.position = ship.point(ion_offset);
        beam.ion.orientation = math.product(ship.orientation, math.scaling(.{ narrow, narrow, 1 }));
        const bright = @min(left / fade_share, 1);
        for (0..ion_blades) |blade| {
            // The whole texture across the blade, and one length of it along, run on by the tick.
            const along = -@as(f32, @floatFromInt(now)) * @as(f32, @floatFromInt(blade)) * scroll_per_blade;
            const corners = blade * guns.blade_corners;
            beam.ion_uv[corners..][0..guns.blade_corners].* = guns.bladeCorners(.{ .{ 0, along + 1 }, .{ 1, along } });
            const near = srapiext.grey(bright);
            const far = srapiext.grey(0);
            beam.ion_colours[corners..][0..guns.blade_corners].* = .{ near, far, far, near };
        }
        if (beam.strands) |*strands| strandsAt(strands, ship, 1 - left);
    }

    /// Adds the beam, and its strands where it has them, to the world's layer.
    fn draw(beam: *Beam, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        // What the objects point into lives in the beam's own record.
        beam.ion.levels = &beam.ion_level;
        beam.ion.own_uv[0] = &beam.ion_uv;
        beam.ion.baked = &beam.ion_colours;
        try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &beam.ion }, .world);
        const strands = if (beam.strands) |*shown| shown else return;
        for (strands) |*strand| {
            strand.object.levels = &strand.level;
            strand.object.baked = &strand.colours;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &strand.object }, .world);
        }
    }
};

/// The helix's point `at` along it (`nova_helix`), in the ship's frame.
fn helix(at: f32) Vector {
    const angle = at * helix_turns * std.math.tau;
    return .{ @cos(angle) * helix_radius, @sin(angle) * helix_radius, at * helix_length + helix_start };
}

/// The strands `through` of the way along the beam's time, the ship standing at `ship`: each from
/// one point of the helix to the next, from `helix_lead` behind that far, as bright as the beam's
/// time rises and falls (`ease.riseFall`). The game lights a strand's first blade alone.
fn strandsAt(strands: *[strand_count]Beam.Strand, ship: math.Place, through: f32) void {
    var points: [strand_count + 1]Vector = undefined;
    for (&points, 0..) |*point, index| {
        var local = helix(@as(f32, @floatFromInt(index)) * helix_step + through - helix_lead);
        local[2] = @max(local[2], helix_nearest);
        point.* = ship.point(local);
    }
    const bright = ease.riseFall(.rising, 0, 1, through);
    for (strands, points[0..strand_count], points[1..]) |*strand, from, to| {
        const length = math.distance(from, to);
        strand.object.position = from;
        strand.object.orientation = math.product(math.lookAt(to - from), math.scaling(.{ 1, 1, length }));
        strand.colours[0..guns.blade_corners].* = @splat(srapiext.grey(bright));
    }
}

/// The beams showing.
pub const Beams = struct {
    slots: [max_beams]?Beam = @splat(null),

    /// `nova_beams_frame` (`0x00480690`), each frame from `bullets_frame`: each beam past its time
    /// goes, as does one whose ship is gone, and the rest stand where their ships are.
    ///
    /// **Fix:** the game keeps drawing a beam from the record of a ship that has gone.
    pub fn frame(beams: *Beams, all: *const create.Objects, now: i32) void {
        for (&beams.slots) |*slot| {
            const beam = &(slot.* orelse continue);
            const ship = &all.slots[beam.owner];
            if (beam.until < now or ship.object.type == .stand_in) {
                slot.* = null;
                continue;
            }
            beam.place(ship.drawn, now);
        }
    }

    pub fn draw(beams: *Beams, gpa: Allocator, scene: *srcore.Scene) Allocator.Error!void {
        for (&beams.slots) |*slot| {
            if (slot.*) |*beam| try beam.draw(gpa, scene);
        }
    }

    fn free(beams: *Beams) ?*?Beam {
        return table.firstFree(Beam, &beams.slots);
    }
};

/// `nova_release` (`0x0047B3D0`), as the player lets the trigger go with the cannon charged, on
/// the frame `world.clock` has begun: where a beam is free, a release short of `least_charge` only
/// loses the charge. Otherwise the blast sounds from the ship, the controller plays the Nova
/// Cannon's effect, the beam strikes (`strike`) and shows for `beam_ticks`, and the charge is
/// spent. With every beam showing, nothing happens, and the charge waits.
///
/// Not ported: what a multiplayer game sends of it (`0x004BB9C0`), and the release it runs for
/// another player's ship.
pub fn release(world: gameobj.World, index: u16) void {
    const now = world.clock.frame_start;
    const all = world.objects;
    const slot = all.bullets.beams.free() orelse return;
    const ship = &all.slots[index];
    const fired = ship.object.nova_charge;
    ship.object.nova_charge = 0;
    if (fired < least_charge) return;
    if (world.hearing) |hearing| {
        hearing.sound.bufferAt(blast_sound, ship.drawn.position, hearing.camera.*, ship.object.radius * blast_loudness);
    }
    if (world.forces) |forces| forces.start(.nc, now);
    strike(world, index, fired);
    const looks = all.bullets.looks orelse return;
    slot.* = .init(&looks.nova, index, now + beam_ticks, fired);
}

/// The beam's strike: every object but the ship itself, the stand-ins and the disabled ones, whose
/// bounding box the beam meets, `beam_reach` straight ahead of the ship. One listing no components
/// takes the cannon's shield damage times the ship's gun condition and the charge, on the quadrant
/// the beam enters, its hull damage over that passing through, and its shields flare there
/// unless it is cloaked. One listing components takes it part by part (`strikeParts`).
///
/// **Fix:** the game takes where the beam enters the box, in the object's own frame, for a point in
/// the world's, for the quadrant struck and the flare alike, which then land wherever that puts
/// them. OpenReliant takes the point where it enters.
///
/// Not ported: in a multiplayer mission, a quarter of the damage.
fn strike(world: gameobj.World, owner: u16, fired: f32) void {
    const all = world.objects;
    const shooter = &all.slots[owner];
    const from = shooter.drawn.position;
    const to = shooter.drawn.point(.{ 0, 0, beam_reach });
    const record = guns.GunType.nova_cannon.stats(&all.gun_stats);
    const strength = shooter.object.gun_condition * fired;
    var walk = all.walk();
    while (walk.next()) |index| {
        if (index == owner) continue;
        const slot = &all.slots[index];
        const object = &slot.object;
        if (object.flags.stand_in or object.flags.disabled) continue;
        const model = if (slot.model) |*live| live else continue;
        const local_from = slot.drawn.inverse(from);
        const local_to = slot.drawn.inverse(to);
        const along = objects.boxEntry(local_from, local_to, .{ gameobj.vector(object.bounds_min), gameobj.vector(object.bounds_max) }) orelse continue;
        if (object.flags.components) {
            strikeParts(world, index, owner, model, from, to, record.damage.hull * fired);
            continue;
        }
        // Where it enters, as `segment_meets_box` works it out: the span times the share, plus the
        // start.
        const entry = math.lerp(local_from, local_to, along);
        const value = strength * record.damage.shield;
        collision.damage(world, index, collision.quadrant(object, entry), value, record.damage.hullShare(), owner, .bullet);
        if (!object.flags.cloaked) shield.flare(world, index, math.lerp(from, to, along));
    }
}

/// The most leaves of a part's tree the beam strikes at once.
const max_leaves = 64;

/// `nova_strike_parts` (`0x0047B840`): the beam through the parts of `model`, of the object in
/// slot `index`, one listing components, and of the models it carries: each part whose mesh's box
/// the beam meets takes `value` against its component for each leaf of its collision tree whose
/// faces the beam crosses (`objects.leafCrossings`), leaving a hit's burst there
/// (`shieldfx.componentHit`) and, on a cloaked object, showing its hull there (`cloak.reveal`).
///
/// Not ported: the object's `visibility`, which the game scales the segment by and nothing moves
/// off 1.
fn strikeParts(world: gameobj.World, index: u16, owner: u16, model: *objects.Model, from: Vector, to: Vector, value: f32) void {
    const kind: shieldfx.Kind = .onComponentOf(world.objects.slots[index].object.type);
    for (model.parts, 0..) |*part, at| {
        if (part.removed or part.object.levels.len == 0) continue;
        const place = part.drawn();
        if (objects.boxEntry(place.inverse(from), place.inverse(to), part.object.levels[0].mesh.bounds) == null) continue;
        const ref: objects.PartRef = .{ .model = model, .index = at };
        var crossed: [max_leaves]objects.Crossing = undefined;
        for (objects.leafCrossings(ref, place, from, to, &crossed)) |crossing| {
            shieldfx.componentHit(world, index, crossing, kind);
            collision.componentDamage(world, index, ref, value, owner, .bullet);
            cloak.reveal(world, index, crossing.inWorld());
        }
    }
    var carried = model.carried();
    while (carried.next()) |mount| strikeParts(world, index, owner, &mount.model, from, to, value);
}

test charge {
    var object = std.mem.zeroes(gameobj.GameObject);
    object.gun_factor = 100;
    var shake: f32 = 0;
    // A quarter of the way, the view holds still.
    charge(&object, &shake);
    try std.testing.expectApproxEqAbs(0.25, object.nova_charge, 1e-6);
    try std.testing.expectEqual(0, shake);
    // Past half, it shakes; past full, it shakes harder, and the charge stops at full.
    charge(&object, &shake);
    charge(&object, &shake);
    try std.testing.expectEqual(charging_shake, shake);
    charge(&object, &shake);
    charge(&object, &shake);
    try std.testing.expectEqual(1, object.nova_charge);
    try std.testing.expectEqual(charged_shake, shake);
    // Another ship's shakes nothing.
    charge(&object, null);
    try std.testing.expectEqual(1, object.nova_charge);
}

test charges {
    var fitted = [_]guns.Fitted{ guns.testing.barrel(.pulse_cannon), guns.testing.barrel(.nova_cannon) };
    var groups = guns.no_groups;
    groups[0] = .{ .first = 0 };
    groups[1] = .{ .first = 1 };
    const trigger: guns.Trigger = .{ .fitted = &fitted, .groups = &groups, .frame_start = 0 };
    var object = std.mem.zeroes(gameobj.GameObject);
    object.type = .phoenix;
    // The Phoenix charges while it fires the group its Nova Cannon leads.
    try std.testing.expect(!charges(&object, trigger));
    object.gun_mode.group = 1;
    try std.testing.expect(charges(&object, trigger));
    // Not while it fires every group, nor on another ship.
    object.gun_mode.all = true;
    try std.testing.expect(!charges(&object, trigger));
    object.gun_mode.all = false;
    object.type = .predator;
    try std.testing.expect(!charges(&object, trigger));
}

test helix {
    try std.testing.expectEqual(@as(Vector, .{ helix_radius, 0, helix_start }), helix(0));
    // A quarter turn on, a twenty-fourth of a unit along.
    const quarter = helix(1.0 / 24.0);
    try std.testing.expectApproxEqAbs(helix_radius, quarter[1], 1e-3);
    try std.testing.expectApproxEqAbs(helix_start + helix_length / 24.0, quarter[2], 1e-2);
}

test "a beam stands on its ship and fades" {
    const looks: Looks = .{ .ion = std.mem.zeroes(srapiext.Mesh), .strand = std.mem.zeroes(srapiext.Mesh) };
    var beam: Beam = .init(&looks, 0, beam_ticks, 0.5);
    try std.testing.expect(!beam.full());
    const ship: math.Place = .{ .position = .{ 0, 0, 100 } };
    beam.place(ship, 0);
    try std.testing.expectEqual(@as(Vector, .{ 0, 50, 20780 }), beam.ion.position);
    // Half the charge, a quarter of the width.
    try std.testing.expectEqual(0.25, beam.ion.orientation[0]);
    // Lit at the ship's end, dark at the far one.
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, beam.ion_colours[0]);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, beam.ion_colours[1]);
    // The second blade's texture runs along it; the first stands still.
    beam.place(ship, 10);
    try std.testing.expectEqual(0, beam.ion_uv[0][1]);
    try std.testing.expectApproxEqAbs(-0.1, beam.ion_uv[4][1], 1e-6);
    // Over the last fifth of its time it fades.
    beam.place(ship, beam_ticks - beam_ticks / 10);
    try std.testing.expectApproxEqAbs(0.5, beam.ion_colours[0][0], 1e-6);

    // A full charge's strands spiral along it.
    var full: Beam = .init(&looks, 0, beam_ticks, 1);
    try std.testing.expect(full.full());
    full.place(ship, beam_ticks / 2);
    try std.testing.expectEqual(1, full.strands.?[0].colours[0][0]);
    try std.testing.expectEqual(0, full.strands.?[0].colours[4][0]);
}
