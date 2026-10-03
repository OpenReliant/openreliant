//! `C:\lancer\game\guns.cpp`: guns. `stats_load_guns` (`0x004788F0`) fills `gun_stats` from
//! `gunstats.bin`, [`formats/stats.zig`](../../formats/stats.zig).

const std = @import("std");
const assert = std.debug.assert;

/// What a gun draws for each shot (`Gun.kind`).
pub const Kind = enum(i32) {
    /// The guns' charge, by `Gun.shot_energy`.
    energy = 0,
    /// One of the object's rounds (`GameObject.rounds`).
    rounds = 1,
    _,
};

/// One record of `gun_stats`, a gun type. The executable holds the first five words itself, the
/// rest come from `gunstats.bin` (`Stats.load`).
pub const Gun = extern struct {
    /// What a shot costs the ship.
    kind: Kind,
    /// How large a shot is drawn: half its width, half its height, and its length along its
    /// flight (`boltMesh`).
    bolt: [3]f32,
    /// The sound a shot makes (`bullet_fire`).
    sound: i32,
    /// `Gun.range`, truncated: the ticks a shot lives, which is what gives the gun its range.
    lifetime: i32,
    /// `Gun.speed`: how fast a shot flies.
    speed: f32,
    /// `Gun.damage`: what a shot does to a shield, and to a hull or a component.
    damage: formats.Damage,
    /// `100 / Gun.fire_rate`, truncated: the interval between shots.
    refire_interval: i32,
    /// `Gun.shot_energy`, truncated: what a shot draws from the guns' charge, for a gun of kind
    /// `energy`.
    shot_energy: i32,

    comptime {
        assert(@offsetOf(Gun, "lifetime") == 0x14);
        assert(@offsetOf(Gun, "refire_interval") == 0x24);
        assert(@sizeOf(Gun) == 0x2C);
    }
};

/// The records of `gun_stats`. Type 0 is no gun, so `gunstats.bin`'s 15 records are the types 1
/// to 15 a muzzle can name.
pub const max_types = 16;

/// A gun type. The tag is the type's number less one, which is how a shot keeps its type
/// (`Bullet.kind`) and what `bullet_build` and `bullets_frame` switch on; a muzzle names it by its
/// number, which `gun_stats` holds it under.
pub const GunType = enum(u4) {
    laser_cannon,
    pulse_cannon,
    messon_blaster,
    proton_cannon,
    gattling_lasers,
    tachyon_cannon,
    neutron_particle_gun,
    collapser_guns,
    gattling_plasma_cannon,
    vulcan_battery,
    nova_cannon,
    turret_flak,
    turret_lasers,
    allied_huge_gun,
    coalition_huge_gun,

    /// The type a muzzle's number names. One that names none, 0 or past the last, fires the
    /// Laser Cannon, as `object_collect_guns` does after warning about it.
    pub fn fromNumber(named: u32) GunType {
        if (named == 0 or named >= max_types) return .laser_cannon;
        return @enumFromInt(named - 1);
    }

    /// Whether it is one of the Huge Guns, which the turrets aim by rules of their own.
    pub fn huge(gun_type: GunType) bool {
        return switch (gun_type) {
            .allied_huge_gun, .coalition_huge_gun => true,
            else => false,
        };
    }

    /// Whether this is a turret gun (the Turret Flak, the Turret Lasers or a Huge Gun) rather than
    /// a fighter gun (the Laser Cannon to the Nova Cannon).
    pub fn onTurrets(gun_type: GunType) bool {
        return switch (gun_type) {
            .turret_flak, .turret_lasers, .allied_huge_gun, .coalition_huge_gun => true,
            else => false,
        };
    }

    /// The number a muzzle names it by, and its record in `gun_stats`.
    pub fn number(gun_type: GunType) u8 {
        return @as(u8, @intFromEnum(gun_type)) + 1;
    }

    /// Its figures.
    pub fn stats(gun_type: GunType, table: *const Stats) Gun {
        return table.types[gun_type.number()];
    }
};

/// `gun_stats` (`0x00500CA4`): every gun type's figures at run time.
pub const Stats = struct {
    types: [max_types]Gun,

    /// The table as the executable holds it before `stats_load_guns` runs: each type's own words,
    /// and no figures from the file.
    pub const initial: Stats = built: {
        var table: Stats = .{ .types = @splat(std.mem.zeroes(Gun)) };
        for (&table.types, gun_stats.gun_types) |*gun, static| {
            gun.kind = static.kind;
            gun.bolt = static.bolt;
            gun.sound = static.sound;
        }
        break :built table;
    };

    /// `stats_load_guns` (`0x004788F0`): each record of `gunstats.bin` in turn, the first into
    /// type 1, keeping in whole numbers what the runtime's `__ftol` cuts down.
    pub fn load(stats: *Stats, file: []align(1) const formats.Gun) void {
        const count = @min(file.len, max_types - 1);
        for (stats.types[1..][0..count], file[0..count]) |*gun, record| {
            gun.lifetime = std.math.lossyCast(i32, record.range);
            gun.speed = record.speed;
            gun.damage = record.damage;
            gun.refire_interval = std.math.lossyCast(i32, formats.Gun.refire_scale / record.fire_rate);
            gun.shot_energy = std.math.lossyCast(i32, record.shot_energy);
        }
    }
};

/// One of an object's guns, as the game keeps it in the 0x60 bytes at `GameObject.guns`: the
/// turret it stands on, where it stands on one, and its trigger.
pub const Fitted = struct {
    /// What it stands on, by its part's turret kind, with what a turret keeps (`+0x00`, and by
    /// kind the record's rest).
    turret: Turret,
    /// The tick the trigger is held until (`+0x0C`): the gun fires while the frame begins before
    /// it (`fire`).
    firing_until: i32 = 0,
    /// Which side of its group it is (`+0x14`), as `create_object` marks it from the type's
    /// groups.
    side: GroupSide = .first,
    /// The tick it may next fire (`+0x18`), for a gun that fires by the trigger.
    next_shot: i32 = 0,
    /// The steps it has been firing, over the sound's period (`gun_stats.sound_periods`), which
    /// the game keeps in its own array at `GameObject+0x138`.
    sounded: i32 = 0,

    /// Where its shots leave from and what they are; none for a missile turret, which fires no
    /// shots, or for a turret destroyed with its base.
    pub fn barrel(gun: *const Fitted) ?*const Barrel {
        return switch (gun.turret) {
            .fixed => |*fixed| fixed,
            .aimed => |*aimed| &aimed.barrel,
            .spin => |*spin| &spin.barrel,
            .missile, .gone => null,
        };
    }
};

/// What a gun stands on: no turret, or one of the turrets a turret part makes of its assembly by
/// its turret kind (`shp.Part.TurretKind`), with what it keeps
/// ([`guns/turrets.zig`](guns/turrets.zig)).
pub const Turret = union(enum) {
    /// A gun that does not move, which fires by its object's trigger (kind 0).
    fixed: Barrel,
    /// A turret that turns to aim at a target of its own, and fires by its parts' tracks (kind 1).
    /// It is in no gun group, and FULL GUNS leaves it out.
    aimed: turrets.Aimed,
    /// A gun whose barrels spin up while its trigger is held (kind 2).
    spin: turrets.Spin,
    /// A missile turret (kind 3). It is in no gun group.
    missile: turrets.Launcher,
    /// A turret destroyed with its base (kind -1, `node_forget`, `objects.destroyPart`): nothing
    /// steps or fires it again.
    gone,

    /// The part whose destruction stops it for good (`node_forget`): an aimed turret's or a
    /// launcher's base, a spinning gun's barrels; none for a fixed gun.
    pub fn base(turret: Turret) ?objects.PartRef {
        return switch (turret) {
            .aimed => |aimed| .{ .model = aimed.model, .index = aimed.base },
            .missile => |launcher| .{ .model = launcher.model, .index = launcher.base },
            .spin => |spin| .{ .model = spin.model, .index = spin.barrels },
            .fixed, .gone => null,
        };
    }
};

/// Where a gun's shots leave from, and their type (`+0x04`, and `+0x08`, which holds the type's
/// record).
pub const Barrel = struct {
    muzzle: Muzzle,
    type: GunType,

    /// Fires a shot from it for the object in slot `owner`, heard or not (`shoot`).
    pub fn fire(barrel: Barrel, world: gameobj.World, owner: u16, is_heard: bool) void {
        shoot(world, owner, barrel.muzzle, barrel.type, is_heard);
    }
};

/// A muzzle a gun fires from: an attachment of kind `gun_muzzle` on a part of its object's model,
/// or of a model mounted on it (the gun's node, `+0x04`). The model it belongs to outlives the
/// object.
pub const Muzzle = struct {
    model: *const objects.Model,
    part: usize,
    attachment: *const shp.Attachment,

    /// Where it stands as its part is drawn (its node's frame).
    pub fn drawn(muzzle: Muzzle) math.Place {
        return muzzle.onPart().within(muzzle.model.parts[muzzle.part].drawn());
    }

    /// Where it stands at `when`, with `top`, its object's model, standing at `root`
    /// (`node_world_place`, `node_next_place`); null where `top` doesn't carry it.
    pub fn at(muzzle: Muzzle, top: *const objects.Model, root: math.Place, when: objects.Model.Step) ?math.Place {
        return muzzle.onPart().within(top.partAt(root, muzzle.model, muzzle.part, when) orelse return null);
    }

    fn onPart(muzzle: Muzzle) math.Place {
        return objects.attachmentPlace(muzzle.attachment);
    }

    /// Its flash, where its model carries one (`node_mount_muzzle`).
    pub fn flashOf(muzzle: Muzzle) ?*flash.Flash {
        for (muzzle.model.flashes) |*lit| {
            if (lit.attachment == muzzle.attachment) return lit;
        }
        return null;
    }
};

pub const turrets = @import("guns/turrets.zig");
pub const flash = @import("guns/flash.zig");
pub const nova = @import("guns/nova.zig");
pub const effects = @import("guns/effects.zig");

/// Which of its group's two guns a gun is, as `create_object` marks them (`+0x14`), and which
/// fires next while a ship fires one group out of step (`GameObject.gun_turn`).
pub const GroupSide = enum(u32) {
    /// The group's first gun, the further to the left, or a gun alone in its group.
    first = 0,
    second = 1,
    _,

    /// The other gun of the pair.
    pub fn other(side: GroupSide) GroupSide {
        return if (side == .first) .second else .first;
    }
};

/// `object_fit_guns` (`0x00479800`) with `object_collect_guns` (`0x00479640`): the guns `model`
/// gives an object, walking its parts in order. A part of a turret's class fits the turret its
/// kind makes of its assembly (`turrets.fit`); a part of a turret's assembly is passed over,
/// with what it carries, since its muzzles are the turret's. Any other part gives a fixed gun for
/// each of its `gun_muzzle` attachments, of the type the muzzle holds, and the guns of each model
/// its attachments mount, in the order of its attachments. A muzzle that names type 0 is taken as
/// type 1, as the game does after warning about it. `ship` is what the turrets' fits need.
///
/// **Unverified:** that a part's node holds what hangs from it in the order of its attachments.
pub fn fit(gpa: Allocator, model: *objects.Model, ship: turrets.Ship) Allocator.Error![]Fitted {
    var made: std.ArrayList(Fitted) = .empty;
    errdefer made.deinit(gpa);
    try collect(gpa, &made, model, ship);
    return made.toOwnedSlice(gpa);
}

fn collect(gpa: Allocator, made: *std.ArrayList(Fitted), model: *objects.Model, ship: turrets.Ship) Allocator.Error!void {
    // The mounts are made in the order of the parts and their attachments.
    var mount: usize = 0;
    for (model.parts, 0..) |*part, index| {
        if (part.class.isTurret() and turrets.fits(part.turret_kind)) {
            if (turrets.fit(model, index, ship)) |turret| try made.append(gpa, .{ .turret = turret });
            continue;
        }
        if (turrets.inAssembly(model, part.link_id)) continue;
        for (part.attachments, 0..) |*attachment, at| {
            if (attachment.kind == .gun_muzzle) try made.append(gpa, .{ .turret = .{ .fixed = .{
                .muzzle = .{ .model = model, .part = index, .attachment = attachment },
                .type = .fromNumber(attachment.gun_type),
            } } });
            while (mount < model.mounts.len and precedes(model.mounts[mount], index, at)) mount += 1;
            if (mount == model.mounts.len) continue;
            const mounted = &model.mounts[mount];
            if (mounted.part != index or mounted.attachment != at) continue;
            try collect(gpa, made, &mounted.model, ship);
            mount += 1;
        }
    }
}

/// Whether `mount` stands on an attachment before attachment `at` of part `index`.
fn precedes(mount: objects.Model.Mount, index: usize, at: usize) bool {
    return mount.part < index or (mount.part == index and mount.attachment < at);
}

test Stats {
    var stats: Stats = .initial;
    var file: [2]formats.Gun = @splat(std.mem.zeroes(formats.Gun));
    file[0].range = 1500.7;
    file[0].fire_rate = 8;
    file[0].damage = .{ .shield = 30, .hull = 40 };
    file[0].speed = 1200;
    file[0].shot_energy = 3.5;
    stats.load(&file);
    // The file's first record is gun type 1; type 0 stays the no gun it starts as.
    try std.testing.expectEqual(1500, stats.types[1].lifetime);
    try std.testing.expectEqual(12, stats.types[1].refire_interval);
    try std.testing.expectEqual(30, stats.types[1].damage.shield);
    try std.testing.expectEqual(1200, stats.types[1].speed);
    try std.testing.expectEqual(3, stats.types[1].shot_energy);
    try std.testing.expectEqual(0, stats.types[0].lifetime);
    // The types the executable's own words name stay as they are.
    try std.testing.expectEqual(Kind.energy, stats.types[1].kind);
    try std.testing.expectEqual(Kind.rounds, stats.types[8].kind);
}

/// Gun groups a ship type holds (`0x00545900`, `0x78` bytes a type).
pub const max_groups = 20;

/// A ship type with no guns in groups, which an object that has none points at.
pub const no_groups: [max_groups]Group = @splat(.{});

/// A ship type's gun group: a gun and the gun closest to its mirror image across the ship, or a
/// single gun. Each field is the gun's index among the ship's guns, or -1 for none, as in the
/// game's table.
pub const Group = struct {
    first: i16 = -1,
    second: i16 = -1,

    /// The index of its first gun, if it has one.
    pub fn lead(group: Group) ?usize {
        return place(group.first);
    }

    /// Whether it is a pair of guns.
    pub fn paired(group: Group) bool {
        return place(group.second) != null;
    }

    /// Its guns' places: the first and the second, where it has them.
    pub fn members(group: Group) [2]?usize {
        return .{ place(group.first), place(group.second) };
    }

    fn place(at: i16) ?usize {
        return if (at < 0) null else @intCast(at);
    }
};

/// The gun at `place` among `fitted`, where there is one.
pub fn gunAt(fitted: []Fitted, place: ?usize) ?*Fitted {
    const at = place orelse return null;
    return if (at < fitted.len) &fitted[at] else null;
}

/// The gun type of the first gun of group `group` of `table`, which blind fire, the charge arc,
/// the gunnery display and the Nova Cannon's charge look at; null for a group of none, or led by
/// a gun that fires no shots.
pub fn groupLead(fitted: []Fitted, table: *const [max_groups]Group, group: usize) ?GunType {
    if (group >= max_groups) return null;
    const first = gunAt(fitted, table[group].lead()) orelse return null;
    const barrel = first.barrel() orelse return null;
    return barrel.type;
}

/// The barrel of a gun `gun_groups_build` groups: a fixed gun's or a spinning gun's, not an
/// aimed turret's nor a missile turret's.
fn grouped(gun: *const Fitted) ?*const Barrel {
    return switch (gun.turret) {
        .fixed, .spin => gun.barrel(),
        .aimed, .missile, .gone => null,
    };
}

/// `gun_groups_build` (`0x004667F0`): pairs a ship type's guns into groups, each gun with the gun
/// of its own type nearest its mirror image across the ship, the closest pair first. A gun left
/// over makes a group of its own, and the gun further to the left comes first in its group.
///
/// The groups belong to the ship type, not the object: the game works them out from whichever
/// object of the type is created and keeps them in the type's table.
pub fn buildGroups(fitted: []const Fitted, groups: *[max_groups]Group) u16 {
    const Entry = struct {
        gun: u16,
        at: math.Vector,
        type: GunType,
        partner: ?usize = null,
        apart: f32 = 0,
        left: bool = true,
    };
    var list: [max_groups * 2]Entry = undefined;
    var count: usize = 0;
    for (fitted, 0..) |*gun, index| {
        const barrel = grouped(gun) orelse continue;
        if (count == list.len) continue;
        list[count] = .{ .gun = @intCast(index), .at = barrel.muzzle.drawn().position, .type = barrel.type };
        count += 1;
    }

    groups.* = @splat(.{});
    var made: u16 = 0;
    while (made < max_groups) {
        // Each gun's nearest mirror of its own type.
        for (list[0..count]) |*entry| {
            if (!entry.left) continue;
            entry.apart = std.math.floatMax(f32);
            entry.partner = null;
            for (list[0..count], 0..) |other, index| {
                if (!other.left or other.gun == entry.gun or other.type != entry.type) continue;
                var mirrored = entry.at;
                mirrored[0] = -mirrored[0];
                const apart = math.lengthSquared(mirrored - other.at);
                if (apart >= entry.apart) continue;
                entry.apart = apart;
                entry.partner = index;
            }
        }
        // The closest pair goes first.
        var nearest: ?usize = null;
        for (list[0..count], 0..) |entry, index| {
            if (!entry.left) continue;
            if (nearest == null or entry.apart < list[nearest.?].apart) nearest = index;
        }
        const first = nearest orelse return made;
        const partner = list[first].partner orelse {
            groups[made] = .{ .first = @intCast(list[first].gun) };
            list[first].left = false;
            made += 1;
            continue;
        };
        const leftmost = if (list[partner].at[0] <= list[first].at[0]) partner else first;
        const other = if (leftmost == first) partner else first;
        groups[made] = .{ .first = @intCast(list[leftmost].gun), .second = @intCast(list[other].gun) };
        list[first].left = false;
        list[partner].left = false;
        made += 1;
    }
    return made;
}

test fit {
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    // Two muzzles on the part: one that names a type, one that names none.
    var muzzles = [_]shp.Attachment{ std.mem.zeroes(shp.Attachment), std.mem.zeroes(shp.Attachment) };
    muzzles[0].kind = .gun_muzzle;
    muzzles[0].gun_type = 3;
    muzzles[1].kind = .gun_muzzle;
    muzzles[1].gun_type = 0;
    model.data[0].attachments = &muzzles;

    var live = try objects.Model.create(gpa, &model.source, &model.loaded, .{});
    defer live.deinit(gpa);
    const fitted = try fit(gpa, &live, .{});
    defer gpa.free(fitted);
    try std.testing.expectEqual(2, fitted.len);
    try std.testing.expectEqual(GunType.messon_blaster, fitted[0].barrel().?.type);
    // A muzzle that names no type fires type 1.
    try std.testing.expectEqual(GunType.laser_cannon, fitted[1].barrel().?.type);
    try std.testing.expectEqual(0, fitted[0].turret.fixed.muzzle.part);
    try std.testing.expectEqual(&muzzles[1], fitted[1].turret.fixed.muzzle.attachment);
}

test buildGroups {
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    // Four muzzles: a pair of type 1 either side of the nose, a pair of type 2 further out, and
    // one of type 3 on the centreline.
    const places = [_][3]f32{ .{ -100, 0, 50 }, .{ 100, 0, 50 }, .{ -300, 0, 0 }, .{ 300, 0, 0 }, .{ 0, 0, 80 } };
    const types = [_]u32{ 1, 1, 2, 2, 3 };
    var muzzles: [5]shp.Attachment = @splat(std.mem.zeroes(shp.Attachment));
    for (&muzzles, places, types) |*muzzle, at, kind| {
        muzzle.kind = .gun_muzzle;
        muzzle.position = .{ .x = at[0], .y = at[1], .z = at[2] };
        muzzle.gun_type = kind;
    }
    model.data[0].attachments = &muzzles;

    var live = try objects.Model.create(gpa, &model.source, &model.loaded, .{});
    defer live.deinit(gpa);
    live.place(@splat(0), math.identity);
    const fitted = try fit(gpa, &live, .{});
    defer gpa.free(fitted);

    var groups: [max_groups]Group = @splat(.{});
    const made = buildGroups(fitted, &groups);
    try std.testing.expectEqual(3, made);
    // The closest mirrored pair comes first, the left gun of each pair leading.
    try std.testing.expectEqual(0, groups[0].first);
    try std.testing.expectEqual(1, groups[0].second);
    try std.testing.expectEqual(2, groups[1].first);
    try std.testing.expectEqual(3, groups[1].second);
    // The gun with nothing to mirror stands alone.
    try std.testing.expectEqual(4, groups[2].first);
    try std.testing.expectEqual(-1, groups[2].second);
}

// --- Firing ------------------------------------------------------------------------------------

/// Simulation steps a second, which `ShipCombat.gun_recharge` is counted in (`0x004DC7F0`).
const recharge_steps: f32 = 25;

/// The gun condition a ship fires steadily at (`0x004DC470`). Below it a shot goes off only as
/// often as the condition and `condition_margin` allow.
const steady_condition: f32 = 0.9;

/// What a ship fires beyond its gun condition (`0x004DC420`).
const condition_margin: f32 = 0.1;

/// The interval between the shots of a ship aiming blind, over a hundred (`0x00477464`).
const blind_refire: i32 = 135;

/// The gun type that charges up before it fires, the Nova Cannon. The trigger passes it over and
/// charges it instead (`nova.charge`), and it fires as the trigger is let go (`nova.release`).
const charging_type: GunType = .nova_cannon;

const Clock = @import("main.zig").Clock;

/// A ship's guns as the trigger needs them (`fire`).
pub const Trigger = struct {
    /// Its guns (`create.Slot.guns`).
    fitted: []Fitted,
    /// Its type's gun groups (`create.Slot.gun_groups`).
    groups: *const [max_groups]Group,
    /// `frame_start`: the tick this frame began.
    frame_start: i32,
    /// The player's view's shake, which the Nova Cannon's charge shakes (`nova.charge`); null for
    /// any other ship.
    shake: ?*f32 = null,
};

/// GUNNERY WINDOW's turn (`frame_controls`, `0x00414060`): out of firing every group, where the
/// ship fires them all, or else on to its next group of `groups`, round to the first after the
/// last. The group is three bits, which go round by themselves for a ship of no groups.
pub fn nextGroup(object: *gameobj.GameObject, groups: i16) void {
    if (object.gun_mode.all) {
        object.gun_mode.all = false;
        return;
    }
    const next = @as(i16, object.gun_mode.group) + 1;
    object.gun_mode.group = if (next == groups) 0 else object.gun_mode.group +% 1;
}

/// FULL GUNS (`frame_controls`), for a ship of `groups` groups, at least `full_guns_groups`: flips
/// firing every group. Turning it on for a ship of `evened_groups` lines their guns that fire by
/// the trigger up to fire together, each next firing as the later of the groups' first guns does.
/// Whether it flipped.
pub fn fullGuns(object: *gameobj.GameObject, fitted: []Fitted, table: *const [max_groups]Group, groups: i16) bool {
    if (groups < full_guns_groups) return false;
    object.gun_mode.all = !object.gun_mode.all;
    if (!object.gun_mode.all or groups != evened_groups) return true;
    var latest: i32 = 0;
    for (table[0..evened_groups]) |group| {
        const gun = triggered(fitted, group.lead()) orelse continue;
        latest = @max(latest, gun.next_shot);
    }
    for (table[0..evened_groups]) |group| {
        for (group.members()) |at| {
            const gun = triggered(fitted, at) orelse continue;
            gun.next_shot = latest;
        }
    }
    return true;
}

/// The fewest groups FULL GUNS flips between firing one and firing them all.
const full_guns_groups = 2;

/// How many groups a ship has whose guns FULL GUNS lines up to fire together.
const evened_groups = 2;

/// The gun at `place` of `fitted`, where it fires by the trigger: a fixed gun or a spinning one.
fn triggered(fitted: []Fitted, place: ?usize) ?*Fitted {
    const gun = gunAt(fitted, place) orelse return null;
    return switch (gun.turret) {
        .fixed, .spin => gun,
        else => null,
    };
}

test nextGroup {
    var object = std.mem.zeroes(gameobj.GameObject);
    object.gun_mode.all = true;
    object.gun_mode.group = 1;
    // Out of firing them all, on the group it had.
    nextGroup(&object, 3);
    try std.testing.expect(!object.gun_mode.all);
    try std.testing.expectEqual(1, object.gun_mode.group);
    // On to the next, and round.
    nextGroup(&object, 3);
    try std.testing.expectEqual(2, object.gun_mode.group);
    nextGroup(&object, 3);
    try std.testing.expectEqual(0, object.gun_mode.group);
}

test fullGuns {
    var object = std.mem.zeroes(gameobj.GameObject);
    const barrel: Barrel = .{ .muzzle = undefined, .type = .laser_cannon };
    var fitted = [_]Fitted{
        .{ .turret = .{ .fixed = barrel }, .next_shot = 30 },
        .{ .turret = .{ .fixed = barrel }, .next_shot = 10 },
        .{ .turret = .{ .fixed = barrel }, .next_shot = 50 },
        .{ .turret = .gone, .next_shot = 5 },
    };
    var table = no_groups;
    table[0] = .{ .first = 0, .second = 1 };
    table[1] = .{ .first = 2, .second = 3 };
    // A ship of one group has nothing to flip.
    try std.testing.expect(!fullGuns(&object, &fitted, &table, 1));
    try std.testing.expect(!object.gun_mode.all);
    // On, both groups' guns fire next as the later first gun does; a gun that isn't triggered is
    // left as it was.
    try std.testing.expect(fullGuns(&object, &fitted, &table, 2));
    try std.testing.expect(object.gun_mode.all);
    for (fitted[0..3]) |gun| try std.testing.expectEqual(50, gun.next_shot);
    try std.testing.expectEqual(5, fitted[3].next_shot);
    // Off again, nothing moves.
    fitted[0].next_shot = 7;
    try std.testing.expect(fullGuns(&object, &fitted, &table, 2));
    try std.testing.expect(!object.gun_mode.all);
    try std.testing.expectEqual(7, fitted[0].next_shot);
}

/// The ticks FIRE LASERS holds the trigger for (`player_controls`), so the player's guns fire
/// this frame and stop unless the key is held into the next.
pub const held_ticks: i32 = 1;

/// `object_fire_guns` (`0x0047B1F0`): holds the trigger of the guns that fire for `ticks` ticks
/// from the start of the frame. FIRE LASERS holds it for one tick, so the guns fire this frame and
/// stop unless it is held again; the mission script's Fire command holds it for longer.
///
/// With FULL GUNS every gun fires but an aimed turret's; otherwise the two guns of the chosen
/// group do. A muzzle of the charging type is passed over either way, as is a ship whose guns are
/// disabled. On a Phoenix firing the group a Nova Cannon leads, the trigger charges it first
/// (`nova.charges`, `nova.charge`).
///
/// **Fix:** the game reads a missile turret's gun type, of a muzzle it has none of, and a
/// destroyed turret's; OpenReliant passes over a gun with no barrel.
///
/// Not ported: `0x004BA780`, which the player's trigger runs last.
pub fn fire(object: *gameobj.GameObject, trigger: Trigger, ticks: i32) void {
    if (object.flags.guns_disabled or object.gun_count == 0) return;
    if (nova.charges(object, trigger)) nova.charge(object, trigger.shake);
    const until = trigger.frame_start + ticks;
    var chosen: Chosen = .of(object, trigger.fitted, trigger.groups);
    while (chosen.next()) |gun| {
        const barrel = gun.barrel() orelse continue;
        if (barrel.type == charging_type) continue;
        if (object.gun_mode.all and gun.turret == .aimed) continue;
        gun.firing_until = until;
    }
}

/// The guns a ship fires together (`GameObject.gun_mode`): its chosen group's two, or all of them.
pub const Chosen = struct {
    fitted: []Fitted,
    /// The places of the group's two (`Group.members`), or null for all of them.
    pair: ?[2]?usize,
    at: usize = 0,

    pub fn of(object: *const gameobj.GameObject, fitted: []Fitted, groups: *const [max_groups]Group) Chosen {
        if (object.gun_mode.all) return .{ .fitted = fitted, .pair = null };
        return .{ .fitted = fitted, .pair = groups[object.gun_mode.group].members() };
    }

    pub fn next(chosen: *Chosen) ?*Fitted {
        const pair = chosen.pair orelse {
            if (chosen.at >= chosen.fitted.len) return null;
            defer chosen.at += 1;
            return &chosen.fitted[chosen.at];
        };
        while (chosen.at < pair.len) {
            const place = pair[chosen.at];
            chosen.at += 1;
            if (gunAt(chosen.fitted, place)) |gun| return gun;
        }
        return null;
    }
};

/// `guns_step` (`0x004770E0`), which `simulation_step` runs for every object after its shields
/// recharge. The guns' charge grows by `gun_energy` times the guns' share of the power and their
/// condition, over `ShipCombat.gun_recharge` seconds of steps, up to `gun_energy`, while no gun is
/// charging up. Then each gun whose trigger is held fires once its refire interval has passed, as
/// long as the ship has the charge or the rounds for it: the guns firing this step share out the
/// charge the step began with, so a ship fires none of them rather than some.
///
/// A ship whose gun condition is below `steady_condition` misfires, the more the lower it is, and
/// one aiming blind fires more slowly. While it fires one group of guns out of step, the group's
/// two guns fire in turn (`takesTurn`).
///
/// A spinning gun throws the spent cases of each round it fires (`effects.throwCases`).
///
/// An object whose components are listed steps no guns of its own, and one that is jumping fires
/// none.
pub fn step(world: gameobj.World, clock: *const Clock, index: u16) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const combat = slot.combat orelse return;
    const fitted = slot.guns;
    const groups = slot.gun_groups;
    const stats = &all.gun_stats;
    if (object.flags.components) return;
    if (object.nova_charge == 0) {
        object.gun_charge += combat.gun_energy * object.gun_factor * object.gun_condition /
            (combat.gun_recharge * recharge_steps);
    }
    if (object.gun_charge > combat.gun_energy) object.gun_charge = combat.gun_energy;

    // What the guns firing this step will draw between them.
    var needed: f32 = 0;
    for (fitted) |*gun| {
        const fixed = switch (gun.turret) {
            .fixed => |*fixed| fixed,
            else => continue,
        };
        const record = fixed.type.stats(stats);
        if (clock.frame_start <= gun.firing_until and record.kind == .energy and gun.next_shot <= clock.frame_start) {
            needed += @floatFromInt(record.shot_energy);
        }
    }
    // The charge as the step began, which the guns are held against as they fire.
    const charge = object.gun_charge;
    if (object.flags.jumping) return;

    var alternated = false;
    for (fitted) |*gun| {
        if (clock.frame_start >= gun.firing_until) continue;
        const barrel = gun.barrel() orelse continue;
        const record = barrel.type.stats(stats);
        // Whether the shot is heard is worked out before the sound's turn comes round. Only type
        // 0, which no gun has, has a period of zero.
        const is_heard = heard(world, index, gun);
        if (record.kind == .energy or record.kind == .rounds) {
            gun.sounded = @rem(gun.sounded + 1, @max(1, gun_stats.sound_periods[barrel.type.number()]));
        }
        switch (gun.turret) {
            .fixed => {
                if (gun.next_shot > clock.frame_start) continue;
                shot: {
                    switch (record.kind) {
                        .energy => {
                            if (needed >= charge) break :shot;
                            if (takesTurn(object, groups, gun)) |takes| {
                                if (!takes) break :shot;
                                alternated = true;
                            }
                            if (!fires(world, object)) break :shot;
                            barrel.fire(world, index, is_heard);
                            object.gun_charge -= @floatFromInt(record.shot_energy);
                        },
                        .rounds => {
                            if (object.rounds <= 0) break :shot;
                            if (takesTurn(object, groups, gun)) |takes| {
                                if (!takes) break :shot;
                                alternated = true;
                            }
                            if (!fires(world, object)) break :shot;
                            barrel.fire(world, index, is_heard);
                            object.rounds -= 1;
                        },
                        else => {},
                    }
                }
                gun.next_shot = clock.frame_start + refire(record, object.blind_fire_aim != 0);
            },
            .spin => {
                if (gun.next_shot > clock.frame_start or object.rounds <= 0) continue;
                gun.next_shot = clock.frame_start + refire(record, object.blind_fire_aim != 0);
                if (takesTurn(object, groups, gun)) |takes| {
                    if (!takes) continue;
                    alternated = true;
                }
                barrel.fire(world, index, is_heard);
                effects.throwCases(world, index, barrel.muzzle.model, barrel.muzzle.part);
                object.rounds -= 1;
            },
            // An aimed turret fires by its parts' tracks (`clipEventMuzzles`).
            .aimed, .missile, .gone => {},
        }
    }
    if (alternated) object.gun_turn = object.gun_turn.other();
}

/// Whether a gun takes this shot, for a ship firing one group of guns out of step: the group's two
/// guns fire in turn (`GameObject.gun_turn`). Null for a ship firing every group or firing in
/// step, and for a group of one gun, none of which take turns.
fn takesTurn(object: *const gameobj.GameObject, groups: *const [max_groups]Group, gun: *const Fitted) ?bool {
    const mode = object.gun_mode;
    if (mode.all or mode.synchronised) return null;
    if (!groups[mode.group].paired()) return null;
    return gun.side == object.gun_turn;
}

/// Whether a shot goes off: a ship whose guns are in good condition always fires, a damaged one
/// only as often as its condition allows.
fn fires(world: gameobj.World, object: *const gameobj.GameObject) bool {
    if (object.gun_condition >= steady_condition) return true;
    return world.random.fraction() <= object.gun_condition + condition_margin;
}

/// The ticks between a gun's shots: a ship aiming blind fires a third again as slowly.
fn refire(record: Gun, blind: bool) i32 {
    return if (blind) @divTrunc(record.refire_interval * blind_refire, 100) else record.refire_interval;
}

/// Whether a gun's shot is heard: the player's shots all are, and another ship's one in every
/// `gun_stats.sound_periods` steps of firing. The step works this out before it advances the
/// count, so it holds for the shot the gun is about to take.
pub fn heard(world: gameobj.World, owner: u16, gun: *const Fitted) bool {
    return owner == world.objects.player or gun.sounded == 0;
}

test fire {
    var object = gameobj.testing.object();
    // The trigger reads nothing of where the guns stand.
    var fitted = [_]Fitted{ testing.barrel(.laser_cannon), testing.barrel(.laser_cannon), testing.barrel(.pulse_cannon), testing.barrel(charging_type) };
    fitted[1].side = .second;
    var groups: [max_groups]Group = @splat(.{});
    groups[0] = .{ .first = 0, .second = 1 };
    groups[1] = .{ .first = 2 };
    object.gun_count = fitted.len;
    const trigger: Trigger = .{ .fitted = &fitted, .groups = &groups, .frame_start = 700 };

    // Firing every group holds the trigger of every gun but the one that charges up.
    object.gun_mode = .created(2);
    fire(&object, trigger, held_ticks);
    for (fitted[0..3]) |gun| try std.testing.expectEqual(701, gun.firing_until);
    try std.testing.expectEqual(0, fitted[3].firing_until);

    // Firing one group holds only that group's guns.
    for (&fitted) |*gun| gun.firing_until = 0;
    object.gun_mode.all = false;
    object.gun_mode.group = 1;
    fire(&object, trigger, held_ticks);
    try std.testing.expectEqual(0, fitted[0].firing_until);
    try std.testing.expectEqual(701, fitted[2].firing_until);

    // A ship whose guns are disabled fires none of them.
    for (&fitted) |*gun| gun.firing_until = 0;
    object.flags.guns_disabled = true;
    fire(&object, trigger, held_ticks);
    for (fitted) |gun| try std.testing.expectEqual(0, gun.firing_until);
}

/// A world with one ship of two guns, one either side of its nose, for the tests here. Its type
/// costs 2 a shot and fires every 20 ticks.
pub const testing = struct {
    const gun_type: GunType = .laser_cannon;
    const ship_type: u32 = 7;

    /// A fixed gun of `kind` whose muzzle nothing reads.
    pub fn barrel(kind: GunType) Fitted {
        return .{ .turret = .{ .fixed = .{ .muzzle = .{ .model = undefined, .part = 0, .attachment = undefined }, .type = kind } } };
    }

    /// Fits the object in `slot` with `fitted` in place of its guns, and counts them, as
    /// `create_object` does.
    pub fn fitTo(slot: *create.Slot, gpa: Allocator, fitted: []const Fitted) Allocator.Error!void {
        slot.dropGuns(gpa);
        slot.guns = try gpa.dupe(Fitted, fitted);
        slot.object.gun_count = @intCast(slot.guns.len);
    }

    const Ship = struct {
        mission: gameobj.testing.Mission,
        model: create.testing.Model,
        muzzles: [2]shp.Attachment,
        index: u16,

        /// Fills in every field, so a field added here has to be filled in too.
        fn init(ship: *Ship, gpa: Allocator) !void {
            ship.* = .{
                .mission = undefined,
                .model = undefined,
                .muzzles = @splat(std.mem.zeroes(shp.Attachment)),
                .index = 0,
            };
            try ship.mission.init(gpa);
            errdefer ship.mission.deinit();
            ship.mission.clock = .{ .frame_start = 700, .mission_ticks = 700 };
            try ship.model.init(gpa);
            for (&ship.muzzles, [_]f32{ -100, 100 }) |*muzzle, x| {
                muzzle.kind = .gun_muzzle;
                muzzle.gun_type = gun_type.number();
                muzzle.position = .{ .x = x, .y = 0, .z = 0 };
                muzzle.orientation = math.identity;
            }
            ship.model.data[0].attachments = &ship.muzzles;
            const stats = &ship.mission.objects.gun_stats.types[gun_type.number()];
            stats.shot_energy = 2;
            stats.refire_interval = 20;
            stats.speed = 500;
            stats.lifetime = 100;
            stats.damage = .{ .shield = 10, .hull = 4 };
            ship.index = try ship.add(@enumFromInt(ship_type), @splat(0));
            // Its guns hold 100 and charge fully in four seconds, so a step gives them one.
            ship.mission.tables.combat[ship_type].gun_recharge = 4;
            ship.object().gun_charge = 50;
        }

        fn deinit(ship: *Ship, gpa: Allocator) void {
            ship.mission.deinit();
            ship.model.deinit(gpa);
        }

        /// An object of type `of` at `at`, of the same model.
        fn add(ship: *Ship, of: gameobj.Type, at: Vector) !u16 {
            return ship.mission.addWith(ship.model.types(), of, at);
        }

        fn world(ship: *Ship) gameobj.World {
            return ship.mission.world();
        }

        fn object(ship: *Ship) *gameobj.GameObject {
            return &ship.mission.objects.slots[ship.index].object;
        }

        fn guns(ship: *Ship) []Fitted {
            return ship.mission.objects.slots[ship.index].guns;
        }

        /// Holds both guns' triggers for the frame.
        fn hold(ship: *Ship) void {
            for (ship.guns()) |*gun| gun.firing_until = ship.mission.clock.frame_start + 1;
        }

        /// Lets both guns fire again at once.
        fn ready(ship: *Ship) void {
            for (ship.guns()) |*gun| gun.next_shot = 0;
        }
    };
};

test step {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const object = ship.object();
    try std.testing.expectEqual(2, ship.guns().len);

    // A step recharges the guns by the ship's energy over the seconds it takes, and no further
    // than full.
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(51, object.gun_charge);
    object.gun_charge = 100;
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(100, object.gun_charge);

    // With the trigger held both guns fire, each drawing its shot's energy, and neither fires
    // again until its interval has passed.
    object.gun_charge = 50;
    ship.hold();
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(47, object.gun_charge);
    for (ship.guns()) |gun| try std.testing.expectEqual(ship.mission.clock.frame_start + 20, gun.next_shot);
    // Each shot left the muzzle.
    try std.testing.expectEqual(2, flying(world));

    // Held again before the interval has passed, nothing is drawn.
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(48, object.gun_charge);
    try std.testing.expectEqual(2, flying(world));

    // A ship that cannot pay for every gun firing this step fires none of them, but their
    // intervals still begin again.
    object.gun_charge = 3;
    ship.hold();
    ship.ready();
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(4, object.gun_charge);
    for (ship.guns()) |gun| try std.testing.expectEqual(ship.mission.clock.frame_start + 20, gun.next_shot);
    try std.testing.expectEqual(2, flying(world));

    // A gun that fires rounds takes one instead of the charge.
    object.gun_charge = 50;
    object.rounds = 2;
    const rounds: GunType = .collapser_guns;
    world.objects.gun_stats.types[rounds.number()] = testing.gun_type.stats(&world.objects.gun_stats);
    world.objects.gun_stats.types[rounds.number()].kind = .rounds;
    for (ship.guns()) |*gun| gun.turret.fixed.type = rounds;
    ship.hold();
    ship.ready();
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(0, object.rounds);
    try std.testing.expectEqual(51, object.gun_charge);

    // A ship that is jumping fires nothing, though its guns still recharge.
    for (ship.guns()) |*gun| gun.turret.fixed.type = testing.gun_type;
    object.gun_charge = 50;
    object.flags.jumping = true;
    ship.hold();
    ship.ready();
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(51, object.gun_charge);
    for (ship.guns()) |gun| try std.testing.expectEqual(0, gun.next_shot);

    // An object whose components are listed steps no guns of its own, and one charging up a gun
    // recharges none. Neither is holding a trigger.
    object.flags.jumping = false;
    for (ship.guns()) |*gun| gun.firing_until = 0;
    object.gun_charge = 50;
    object.flags.components = true;
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(50, object.gun_charge);
    object.flags.components = false;
    object.nova_charge = 0.5;
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(50, object.gun_charge);
}

/// How many shots are in flight.
fn flying(world: gameobj.World) usize {
    var count: usize = 0;
    for (world.objects.bullets.pool) |bullet| {
        if (bullet.live) count += 1;
    }
    return count;
}

test "a group's two guns fire in turn while the ship fires out of step" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const object = ship.object();
    object.gun_mode.synchronised = false;
    ship.hold();

    // The ship's turn is the first gun's side, so only that gun fires, and the turn passes.
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(49, object.gun_charge);
    try std.testing.expectEqual(GroupSide.second, object.gun_turn);

    // The other gun fires next time round.
    object.gun_charge = 50;
    ship.hold();
    ship.ready();
    step(world, &ship.mission.clock, ship.index);
    try std.testing.expectEqual(49, object.gun_charge);
    try std.testing.expectEqual(GroupSide.first, object.gun_turn);
}

test "a ship aiming blind fires more slowly" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    ship.object().blind_fire_aim = 1;
    ship.hold();
    step(ship.world(), &ship.mission.clock, ship.index);
    for (ship.guns()) |gun| try std.testing.expectEqual(ship.mission.clock.frame_start + 27, gun.next_shot);
}

test blindAim {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    var world = ship.world();
    var display: hud.State = .{};
    display.lead_point = .{ 0, 1000, 1000 };
    world.display = &display;
    const barrel = ship.guns()[0].turret.fixed;
    const pool = &world.objects.bullets.pool;
    const speed = barrel.type.stats(&world.objects.gun_stats).speed;

    // Not aiming blind, the shot flies along its muzzle.
    try std.testing.expectEqual(null, blindAim(world, ship.index, barrel.type));
    barrel.fire(world, ship.index, false);
    try std.testing.expectEqual(Vector{ 0, 0, speed }, pool[0].velocity);

    // Aiming blind, the player's shot flies at the lead cursor's point, as fast as ever.
    ship.object().blind_fire_aim = 1;
    barrel.fire(world, ship.index, false);
    const aimed = pool[1];
    const toward = math.normalize(display.lead_point - aimed.at) * @as(Vector, @splat(speed));
    try math.testing.expectVectorWithin(toward, aimed.velocity, 1e-3);

    // The Nova Cannon and the turrets' guns fire along their muzzles, and so does another ship.
    try std.testing.expectEqual(null, blindAim(world, ship.index, .nova_cannon));
    try std.testing.expectEqual(null, blindAim(world, ship.index, .turret_flak));
    const other = try ship.add(@enumFromInt(testing.ship_type), .{ 0, 0, 1000 });
    world.objects.slots[other].object.blind_fire_aim = 1;
    try std.testing.expectEqual(null, blindAim(world, other, barrel.type));
}

test fires {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const object = ship.object();

    // Guns in good condition always fire, and draw no number to decide it.
    const before = ship.mission.random;
    for (0..8) |_| try std.testing.expect(fires(world, object));
    try std.testing.expectEqual(before, ship.mission.random);

    // Half wrecked guns fire some of the time.
    object.gun_condition = 0.5;
    var shots: usize = 0;
    for (0..100) |_| {
        if (fires(world, object)) shots += 1;
    }
    try std.testing.expect(shots > 0 and shots < 100);
}

test heard {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    var gun = ship.guns()[0];
    gun.sounded = 2;
    // Every one of the player's shots is heard; another ship's only as its count comes round.
    try std.testing.expect(heard(ship.world(), ship.mission.objects.player, &gun));
    try std.testing.expect(!heard(ship.world(), ship.index + 1, &gun));
}

// --- Bullets -----------------------------------------------------------------------------------

/// The shots in flight (`0x00563148`): the game keeps 200 records of `0xC4` bytes and links the
/// live ones into a list, newest first; OpenReliant keeps the same 200 and walks them in order,
/// which tells only in which order two shots that land on one object in a frame are dealt with.
pub const max_bullets = 200;

/// The objects one shot is tested against (`bullet_place`).
pub const max_candidates = 20;

/// What a shot's `dies_at` becomes once it has struck something: the frame that follows frees it.
pub const spent: i32 = -1;

/// An object a shot may reach, and which of its parts, as `bullet_place` leaves it.
pub const Candidate = struct {
    /// The object's slot.
    object: u16 = 0,
    /// For an object that lists components, the part's number (`objects.Model.numbered`), which
    /// is found again each frame in the model the object has then, as the game keeps its node's
    /// number (`object_number_parts`); null for any other object, which is taken whole.
    part: ?u16 = null,
};

/// One shot in flight, as the game keeps it in the `0xC4` bytes of a pool record.
pub const Bullet = struct {
    /// Whether the record is in use.
    live: bool = false,
    /// Its gun type (`+0x00`), which the game keeps as the type's number less one.
    kind: GunType = .laser_cannon,
    /// The tick it dies (`+0x04`), which is `spent` once it has struck something.
    dies_at: i32 = 0,
    /// The tick it was fired (`+0x08`).
    fired_at: i32 = 0,
    /// Where it stood at the frame before (`+0x10`), and where it stands now (`+0x1C`). The frame
    /// pass tests what lies between the two.
    last: Vector = @splat(0),
    at: Vector = @splat(0),
    /// How far it flies each simulation step (`+0x28`).
    velocity: Vector = @splat(0),
    /// The slot that fired it (`+0x34`), which the damage is charged to.
    owner: u16 = 0,
    /// That ship's side (`+0x38`).
    side: gameobj.Side(i32) = .neutral,
    /// The objects it may reach (`+0x68`), as many as `candidate_count` (`+0x64`).
    candidates: [max_candidates]Candidate = @splat(.{}),
    candidate_count: u8 = 0,
    /// Where the frame draws it, between its last place and its next (`bulletsFrame`).
    place: Vector = @splat(0),
    /// What it is drawn with (`+0x3C`, eight words), as `bullet_build` gives them by its type; the
    /// first `piece_count` of them.
    pieces: [max_pieces]Piece = @splat(.{}),
    piece_count: u8 = 0,
    /// The texture coordinates its meshes take as their own (`MeshObject.own_uv`).
    uv: [max_corners][2]f32 = @splat(.{ 0, 0 }),
    /// The light it casts (`+0x60`), while it is one of the latest two of its ring
    /// (`Bullets.player_lights`, `Bullets.other_lights`).
    light: ?srlight.Light = null,
    /// A Huge Gun's shot's trail (`+0x5C`), hung from its frame, the first of its pieces.
    trail: ?effects.Streaming = null,

    /// Its type's figures.
    pub fn stats(bullet: Bullet, table: *const Stats) Gun {
        return bullet.kind.stats(table);
    }

    /// Whether its record is free.
    fn dead(bullet: *const Bullet) bool {
        return !bullet.live;
    }
};

/// The pool of shots (`0x00563148`).
pub const Bullets = struct {
    pool: [max_bullets]Bullet = @splat(.{}),
    /// What the shots are drawn with, where the caller has built it; without, they fly unseen and
    /// draw none of the numbers their looks would.
    looks: ?*Looks = null,
    /// The Nova Cannon's beams showing (`0x00563190`).
    beams: nova.Beams = .{},
    /// Which shots cast a light.
    shot_lights: ShotLights = .latest_two,
    /// The shots that cast a light under `latest_two`: the player's latest two (`0x0056317C`), and
    /// the latest two of everyone else's (`0x00563168`).
    player_lights: Ring = .{},
    other_lights: Ring = .{},

    /// The shots of one ring that cast a light, as indices into the pool: each new one takes the
    /// place after the last, round the two.
    pub const Ring = @import("table.zig").Ring(u8, lights_kept);

    /// Gives the shot at `index`, the player's or another's, its ring's next light, putting out
    /// the light of the shot that held it.
    fn light(bullets: *Bullets, player: bool, index: u8) void {
        const ring = if (player) &bullets.player_lights else &bullets.other_lights;
        const held = ring.take(lights_kept);
        if (held.*) |old| bullets.pool[old].light = null;
        held.* = index;
    }

    /// The first free record, as `bullet_fire` takes it, or null while every one is in flight.
    fn free(bullets: *Bullets) ?u8 {
        return @intCast(firstFreeBy(Bullet, &bullets.pool, Bullet.dead) orelse return null);
    }

    /// Lets the shot at `index` go, and its light with it (`bullet_free`, `0x0047A3D0`).
    fn release(bullets: *Bullets, index: u8) void {
        for ([_]*Ring{ &bullets.player_lights, &bullets.other_lights }) |ring| {
            for (&ring.slots) |*held| {
                if (held.* == index) held.* = null;
            }
        }
        bullets.pool[index] = .{};
    }
};

/// Which shots cast a light.
pub const ShotLights = enum {
    /// The latest two of the player's shots and the latest two of everyone else's, as the game
    /// lights them (`bullet_place`), which a hardware renderer of its day could hold.
    latest_two,
    /// **Improvement:** every shot, so that sustained fire lights the hulls it passes. The GPU
    /// device lights each pixel with the 64 point lights nearest the camera and the pipeline adds
    /// the rest to each vertex, so a frame full of shots still lights them all.
    every_shot,
};

/// How many shots of a ring cast a light at once.
const lights_kept = 2;

/// How far a shot's light reaches at full strength (`bullet_place`).
const shot_light_range: f32 = 1000;

/// The colour of a shot's light: blue, or orange for a hostile ship's shot, unless the player fired
/// it.
const shot_light: [3]f32 = .{ 0, 0.5, 1 };
const hostile_shot_light: [3]f32 = .{ 1, 0.5, 0 };

/// The colour of the light of a shot fired from the side `side`, by the player or not.
fn shotColour(player: bool, side: gameobj.Side(i32)) [3]f32 {
    return if (!player and side == .hostile) hostile_shot_light else shot_light;
}

/// `bullet_fire` (`0x0047C5F0`) with `bullet_place` (`0x0047BDB0`): a shot of `gun_type` that the
/// object in slot `owner` fires from `muzzle`, heard or not. It leaves the muzzle where the step is
/// taking it, flying along the muzzle's nose at the type's speed, and lives for the type's
/// `lifetime` ticks. Nothing is fired while every record is in flight.
///
/// The shot is given the objects it may reach on its way: any object whose radius, widened by how
/// far it could travel meanwhile, the shot's path comes within. The frame pass tests only those
/// (`bulletHit`).
///
/// The shot is drawn with its type's bolt where OpenReliant has one (`Bolts`).
///
/// It casts a light while it is one of the latest two of its ring (`Bullets.Ring`), or for its
/// whole flight under `ShotLights.every_shot`.
///
/// It lights the muzzle's flash, where the muzzle has one, for the shot's type's ticks, in the
/// colour of its light (`flash.Flash.fire`). A shot of the player's plays its gun type's effect on
/// the player's controller (`forceEffect`).
///
/// A few gun types have rules of their own: two Turret Flak shots in five are Turret Lasers shots,
/// and a Turret Flak shot lives a random share of its type's life, from a fifth to all of it, and
/// scatters up to `flak_scatter` about each axis; a Huge Gun's shot is given the objects its path
/// comes within `hugeReach` of as well.
///
/// A ship aiming blind turns the shot from its muzzle to fly at where it aims (`blindAim`).
///
/// Not ported: how the other gun types' shots are drawn
/// ([#154](https://github.com/OpenReliant/openreliant/issues/154)); its sound
/// ([#47](https://github.com/OpenReliant/openreliant/issues/47)).
pub fn shoot(world: gameobj.World, owner: u16, muzzle: Muzzle, gun_type: GunType, is_heard: bool) void {
    if (hooks.enter(.bullet_fire, shoot, .{ world, owner, muzzle, gun_type, is_heard })) |done| return done;
    const clock = world.clock;
    const all = world.objects;
    const slot = &all.slots[owner];
    const model = if (slot.model) |*live| live else return;
    const index = all.bullets.free() orelse return;
    const bullet = &all.bullets.pool[index];

    // The shot's own type, which is its gun's but for a Turret Flak's two times in five
    // (`bullet_fire`); its figures follow it.
    var kind = gun_type;
    if (kind == .turret_flak and @rem(world.random.rand(), flak_lasers.in) < flak_lasers.times) kind = .turret_lasers;
    const record = kind.stats(&all.gun_stats);

    // The muzzle stands where the step is taking the ship, on the part that carries it. A shot
    // aimed blind faces where it is aimed, unrolled.
    const leaves = muzzle.at(model, slot.object.placeAt(.next), .next) orelse return;
    const at = leaves.position;
    const turn = if (blindAim(world, owner, kind)) |aim| math.lookAt(aim - at) else leaves.orientation;

    bullet.* = .{
        .live = true,
        .kind = kind,
        .fired_at = clock.mission_ticks,
        .last = at,
        .at = at,
        .owner = owner,
        .side = slot.object.side,
        .place = at,
    };
    // What it is drawn with comes first, and draws its numbers before the rest (`bullet_place`).
    if (all.bullets.looks) |looks| dress(bullet, looks, world.random, turn);
    if (effects.Trail.of(kind)) |trail| bullet.trail = trail.start(clock.frame_start);

    // The light it casts, which the oldest shot of its ring gives up.
    const player = owner == all.player;
    switch (all.bullets.shot_lights) {
        .latest_two => all.bullets.light(player, index),
        .every_shot => {},
    }
    bullet.light = .{
        .mask = 0,
        .intensity = 1,
        .colour = shotColour(player, bullet.side),
        .kind = .{ .point = .{ .position = at, .range = shot_light_range } },
    };

    var lifetime = record.lifetime;
    if (kind == .turret_flak) {
        const share = world.random.fraction() * flak_life_share + flak_life_least;
        lifetime = std.math.lossyCast(i32, share * @as(f32, @floatFromInt(lifetime)));
    }
    bullet.dies_at = clock.mission_ticks + lifetime;

    bullet.velocity = math.transform(turn, .{ 0, 0, record.speed });
    if (kind == .turret_flak) {
        // Drawn roll, yaw and pitch in that order, each a share of `flak_scatter` either way.
        const scatter = math.fromAngleVector(world.random.centredVector(@splat(flak_scatter)));
        bullet.velocity = math.transform(scatter, bullet.velocity);
    }
    if (is_heard) shotSound(world, @intCast(index), kind, record.sound, owner == all.player);
    if (player) if (world.forces) |forces| forces.start(forceEffect(kind), clock.frame_start);
    candidates(world, bullet, record, lifetime);
    if (muzzle.flashOf()) |lit| lit.fire(kind, clock.frame_start, shotColour(player, bullet.side));
}

/// `bullet_place`'s aim for a shot of type `kind` from the ship in slot `owner`, while the ship
/// aims blind (`GameObject.blind_fire_aim`, which the display sets as it draws the reticle): a
/// shot of the player's flies at the point the lead cursor last stood on
/// (`hud.State.lead_point`). Null for a shot that flies along its muzzle: from a ship not aiming
/// blind, or of the Nova Cannon or a turret's gun.
///
/// Not ported: another player's ship in a multiplayer game, which aims blind at the target of its
/// order (`ai.leadAim`), or along its muzzle where it can't be aimed at.
fn blindAim(world: gameobj.World, owner: u16, kind: GunType) ?Vector {
    const all = world.objects;
    if (all.slots[owner].object.blind_fire_aim == 0) return null;
    if (kind == .nova_cannon or kind.onTurrets()) return null;
    if (owner != all.player) return null;
    const display = world.display orelse return null;
    return display.lead_point;
}

/// The game's own effects of the events the tracks of the model of the object in slot `owner`
/// pass (`node_tree_update`): a `muzzles` event fires the part's muzzles (`clipEventMuzzles`), and
/// a `puff` event throws the part's spent cases (`effects.throwCases`).
pub fn clipEvents(world: *gameobj.World, owner: u16) gameobj.Events {
    return .{ .context = world, .owner = owner, .fire = clipEvent };
}

fn clipEvent(context: *anyopaque, owner: u16, model: *objects.Model, part: usize, kind: shp.ClipEvent.Kind) void {
    const world: *const gameobj.World = @ptrCast(@alignCast(context));
    switch (kind) {
        .muzzles => clipEventMuzzles(world.*, owner, model, part),
        .puff => effects.throwCases(world.*, owner, model, part),
        _ => {},
    }
}

/// `clip_event_muzzles` (`0x0047C7B0`): fires a shot from each muzzle of part `index` of
/// `model`, one of the models of the object in slot `owner`, of the type the muzzle holds, and
/// heard (`bullet_fire`). This is how an aimed turret fires, by its parts' `fire` tracks. Nothing
/// holds such a shot back: not the ship's charge or rounds, the gun's refire or condition, a jump,
/// nor its guns being disabled.
pub fn clipEventMuzzles(world: gameobj.World, owner: u16, model: *const objects.Model, index: usize) void {
    for (model.parts[index].attachments) |*attachment| {
        if (attachment.kind != .gun_muzzle) continue;
        const muzzle: Muzzle = .{ .model = model, .part = index, .attachment = attachment };
        shoot(world, owner, muzzle, .fromNumber(attachment.gun_type), true);
    }
}

/// The effect a shot of `kind` plays on the player's controller (`bullet_place`): the file of its
/// gun type, from the Laser Cannon's to the Nova Cannon's, which the effects are read in the order
/// of; the Laser Cannon's for a turret's gun type.
///
/// **Fix:** the game's switch has no case for the Proton Cannon, which then plays the Laser
/// Cannon's effect, and its own, `prc.frc`, which the game reads, never plays.
fn forceEffect(kind: GunType) input.force.Effect {
    comptime {
        assert(@intFromEnum(input.force.Effect.nc) == @intFromEnum(GunType.nova_cannon));
        // The turrets' guns come after the Nova Cannon, and so past the effects.
        for (std.enums.values(GunType)) |gun_type| {
            assert(gun_type.onTurrets() == (@intFromEnum(gun_type) > @intFromEnum(GunType.nova_cannon)));
        }
    }
    if (kind.onTurrets()) return .lc;
    return @enumFromInt(@intFromEnum(kind));
}

test forceEffect {
    try std.testing.expectEqual(.lc, forceEffect(.laser_cannon));
    try std.testing.expectEqual(.prc, forceEffect(.proton_cannon));
    try std.testing.expectEqual(.nc, forceEffect(.nova_cannon));
    try std.testing.expectEqual(.lc, forceEffect(.turret_lasers));
}

/// The sound a shot makes as it is fired (`bullet_fire`), its gun type's, following it: on a voice
/// of the player's guns for the player's shots, and on a guaranteed one for the huge guns'.
fn shotSound(world: gameobj.World, index: u8, kind: GunType, sound: i32, player: bool) void {
    const which = std.enums.fromInt(sound3d.sounds.Sound, sound) orelse return;
    const class: sound3d.Class = switch (kind) {
        .allied_huge_gun, .coalition_huge_gun => .guaranteed,
        else => if (player) .player_guns else .not_reserved,
    };
    sound3d.playIn(world, null, null, index, which, 1, class);
}

/// The objects `bullet_place` gives a new shot: those its path comes near enough to over its life,
/// widened by how far each could move meanwhile, up to `max_candidates`. An object whose
/// components are listed is walked part by part (`objects.hitWalk`), along the path its life gives
/// the shot from where it leaves the muzzle as it moves against the object, and each part whose
/// collision tree's root box that path meets, or that plays a track, is a candidate of its own
/// (`0x0047BC90`).
///
/// **Quirk:** the object's velocity, a step's worth, is taken off the shot's, a tick's.
fn candidates(world: gameobj.World, bullet: *Bullet, record: Gun, lifetime: i32) void {
    const all = world.objects;
    if (record.speed <= 0) return;
    const along = 1 / (record.speed * record.speed);
    const life: f32 = @floatFromInt(lifetime);
    var walk = all.walk();
    while (walk.next()) |index| {
        if (bullet.candidate_count == max_candidates) return;
        const slot = &all.slots[index];
        const object = &slot.object;
        if (!object.type.hasStats() or object.flags.no_collisions) continue;
        if (index == bullet.owner) continue;
        const to = object.nextPosition() - bullet.at;
        const when = std.math.clamp(math.dot(to, bullet.velocity) * along, 0, life);
        const nearest = bullet.velocity * @as(Vector, @splat(when));
        const moving = ai.slotCruise(slot, world.view) orelse 0;
        const reach = moving * when + object.radius + hugeReach(bullet.kind);
        if (math.lengthSquared(nearest - to) >= reach * reach) continue;
        if (componentModel(slot)) |model| {
            const end = bullet.at + (bullet.velocity - gameobj.vector(object.velocity)) * @as(Vector, @splat(life));
            var listing: Listing = .{ .bullet = bullet, .object = index, .model = model, .from = bullet.at, .to = end };
            objects.hitWalk(model, object.placeAt(.next), &listing);
        } else {
            bullet.candidates[bullet.candidate_count] = .{ .object = index };
            bullet.candidate_count += 1;
        }
    }
}

/// The model of the object in `slot` where the object lists components, which shots test part by
/// part.
fn componentModel(slot: *create.Slot) ?*objects.Model {
    if (!slot.object.flags.components) return null;
    return if (slot.model) |*live| live else null;
}

/// `0x0047BC90`, what `bullet_place` tests each part of an object that lists components with:
/// where the part plays a track, or the shot's path meets its collision tree's root box, the part
/// is a candidate, while there is room.
const Listing = struct {
    bullet: *Bullet,
    object: u16,
    model: *objects.Model,
    from: Vector,
    to: Vector,

    pub fn meets(listing: *Listing, box: objects.Box) bool {
        return box.meetsSegment(listing.from, listing.to);
    }

    pub fn part(listing: *Listing, ref: objects.PartRef, place: math.Place, moving: bool) void {
        const shot = listing.bullet;
        if (shot.candidate_count == max_candidates) return;
        const tree = ref.rootBox() orelse return;
        if (!moving and !tree.meetsSegment(place.inverse(listing.from), place.inverse(listing.to))) return;
        const number = std.math.cast(u16, listing.model.numberOf(ref) orelse return) orelse return;
        shot.candidates[shot.candidate_count] = .{ .object = listing.object, .part = number };
        shot.candidate_count += 1;
    }
};

/// What a turret's shot does to a player's ship, over what it does to any other (`0x004DC59C`).
const turret_damage_to_players: f32 = 2.5;

/// Whether the shot is a Turret Flak's or a Turret Lasers', which hurts a player's ship more
/// (`turret_damage_to_players`); a Huge Gun's does not.
fn hurtsPlayersMore(kind: GunType) bool {
    return kind == .turret_flak or kind == .turret_lasers;
}

/// What a shot of `kind` does of `value` to the object in slot `index`: a turret's shot does more
/// to a player's ship (`bullet_hit`, `bullet_hull_hit`).
fn dealt(all: *const Objects, index: u16, kind: GunType, value: f32) f32 {
    return if (index < all.players and hurtsPlayersMore(kind)) value * turret_damage_to_players else value;
}

test dealt {
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();
    all.players = 1;
    try std.testing.expectEqual(25, dealt(all, 0, .turret_flak, 10));
    try std.testing.expectEqual(10, dealt(all, 0, .laser_cannon, 10));
    try std.testing.expectEqual(10, dealt(all, 0, .allied_huge_gun, 10));
    try std.testing.expectEqual(10, dealt(all, 1, .turret_lasers, 10));
}

/// How much farther a Huge Gun's shot reaches than the objects it may hit stand
/// (`0x004DC758`, `0x004DC508`, and written into `bullet_hit`).
fn hugeReach(kind: GunType) f32 {
    return switch (kind) {
        .allied_huge_gun => 1200,
        .coalition_huge_gun => 3000,
        else => 0,
    };
}

/// The least share of its life a Turret Flak shot lives (`0x004DC3F8`), and how much more it may
/// (`0x004DC410`).
const flak_life_least: f32 = 0.2;
const flak_life_share: f32 = 0.8;

/// How far a Turret Flak shot's flight scatters about each axis, in radians, from half of it one
/// way to half the other (`0x004DC880`).
const flak_scatter: f32 = 0.12;

/// How often a Turret Flak shot is a Turret Lasers' instead: `times` in `in`, where the runtime's
/// number over `in` leaves less than `times` (`bullet_fire`, which holds both in its code).
const flak_lasers = struct {
    const in: u15 = 5;
    const times: u15 = 2;
};

/// `0x0047A4E0`, which `simulation_step` runs after the objects move: every shot flies on by its
/// velocity.
pub fn moveBullets(world: gameobj.World) void {
    for (&world.objects.bullets.pool) |*bullet| {
        if (!bullet.live) continue;
        bullet.at += bullet.velocity;
    }
}

/// The work of `0x0047A510` once a frame, after the objects are framed: each shot is tested
/// against the objects it may reach, and one that is spent or out of life is let go. A shot that
/// has struck something is tested no further.
///
/// A Huge Gun's shot streams its trail (`effects.Streaming`), and a Turret Flak shell that ends
/// without striking anything bursts (`effects.flakBurst`).
///
/// Not ported: how the shots are drawn, their colours fading with their life, and the lights they
/// carry ([#154](https://github.com/OpenReliant/openreliant/issues/154)); what multiplayer makes of a
/// hit.
pub fn bulletsFrame(world: gameobj.World, clock: *const Clock, fraction: f32) void {
    const bullets = &world.objects.bullets;
    for (&bullets.pool, 0..) |*bullet, index| {
        if (!bullet.live) continue;
        // It is drawn as far through the step as the frame is, between its last place and its
        // next, after its type's own work on its pieces.
        bullet.place = math.lerp(bullet.last, bullet.at, fraction);
        if (bullet.piece_count > 0) {
            animate(bullet, clock, bullet.stats(&world.objects.gun_stats), world.random);
            placePieces(bullet);
        }
        if (bullet.trail) |*trail| trail.frame(world, .{ .position = bullet.place, .orientation = bullet.pieces[0].turn });
        if (clock.frame_start < bullet.dies_at) {
            if (bullet.candidate_count > 0) bulletHit(world, bullet);
            // A hit marks it spent, which frees it below rather than flying on.
            if (clock.frame_start < bullet.dies_at) {
                bullet.last = bullet.at;
                continue;
            }
        }
        if (bullet.kind == .turret_flak) effects.flakBurst(world, @intCast(index), bullet.place);
        bullets.release(@intCast(index));
    }
    bullets.beams.frame(world.objects, clock.frame_start);
}

/// `0x00479B40`: what a shot strikes between where it stood last frame and where it stands now. It
/// tests only the objects it was given when it was fired, and drops any it has already flown past.
///
/// An object is struck where the segment first crosses the sphere of its radius, widened for a Huge
/// Gun's shot (`hugeReach`). With a shield up in that quadrant the shot spends itself on the shield
/// (`object_damage` with the type's shield damage, and its hull damage over that as the share that
/// passes through); with the shield down the shot reaches the hull (`hullHit`), though a Huge Gun's
/// always goes through the shields. What the player has shifted fore or aft takes the hit
/// before the quadrant does, and a turret's shot hurts a player's ship more. A ship with its
/// spectral shields on takes nothing at all: the gun type they are tuned to is handed to the check
/// and ignored, so every shot is turned. Whatever becomes of a shot spent on a shield, the shield
/// flares where it struck (`shield.flare`), unless the ship is cloaked, when the shot shows its
/// hull there instead (`cloak.reveal`). An object whose components are listed is struck part by
/// part instead (`componentHit`).
fn bulletHit(world: gameobj.World, bullet: *Bullet) void {
    const all = world.objects;
    const segment: objects.Segment = .between(bullet.last, bullet.at);
    if (math.lengthSquared(segment.span) < 1) return;
    const record = bullet.stats(&world.objects.gun_stats);

    var index: usize = 0;
    while (index < bullet.candidate_count) {
        const candidate = bullet.candidates[index];
        const slot = &all.slots[candidate.object];
        const object = &slot.object;
        if (!object.type.hasStats()) {
            index += 1;
            continue;
        }
        const when = segment.nearest(slot.drawn.position);
        const reach = object.radius + hugeReach(bullet.kind);
        if (segment.missSquared(slot.drawn.position, when) > reach * reach) {
            // Once the shot is past an object it is dropped from the list.
            if (when == 0) {
                var from = index;
                while (from + 1 < bullet.candidate_count) : (from += 1) bullet.candidates[from] = bullet.candidates[from + 1];
                bullet.candidate_count -= 1;
                continue;
            }
            index += 1;
            continue;
        }
        // An object whose components are listed is tested part by part, its candidates in a run.
        if (object.flags.components) {
            var end = index;
            while (end < bullet.candidate_count and bullet.candidates[end].object == candidate.object) end += 1;
            if (componentStruck(world, bullet, segment, candidate.object, bullet.candidates[index..end])) |crossing| {
                return componentHit(world, bullet, candidate.object, crossing);
            }
            index = end;
            continue;
        }
        // Where the segment first crosses the object's sphere.
        const point = segment.point(segment.sphereEntry(slot.drawn.position, reach));
        const struck = collision.quadrant(object, slot.drawn.inverse(point));

        if (!bullet.kind.huge() and (object.shields.get(struck) <= 0 or object.invulnerable == ._unknown_4 or object.invulnerable == ._unknown_5)) {
            hullHit(world, bullet, candidate.object, struck);
            return;
        }
        cloak.reveal(world, candidate.object, point);
        defer if (!object.flags.cloaked) shield.flare(world, candidate.object, point);
        if (!object.flags.spectral_shields and record.damage.shield > 0) {
            const value = record.damage.shield;
            // What the player has shifted fore or aft takes the hit before the quadrant does, and
            // a hit it swallows whole leaves the shields alone.
            if (candidate.object == all.player and world.player.shield_reserves.spare(struck, value)) {
                bullet.dies_at = spent;
                return;
            }
            collision.damage(world, candidate.object, struck, dealt(all, candidate.object, bullet.kind, value), record.damage.hullShare(), bullet.owner, .bullet);
        }
        bullet.dies_at = spent;
        return;
    }
}

/// The sparks a shot striking a hull throws: from where it struck, out from the object's
/// centre through it, at 7.5 to 12.5 a tick, within half a radian either way, carrying on with a
/// quarter of the object's velocity, a step's (`bullet_hull_hit`).
const hull_sparks: sparks.Spray = .{ .speed = 10, .speed_range = 5, .spread = 1, .count = 10 };
const hull_sparks_carry: f32 = 0.25;

/// `bullet_hit` for an object that lists components (`bullet_hull_test`, `0x004798B0`, and
/// `missile_hull_test`): where the shot's segment meets the object's bounding box, the last face it
/// crosses of the parts among `run`, the object's run of candidates, each tested where the segment
/// passes within its radius of it as it stands drawn, and crossed at its next place
/// (`objects.crossPart`). Null where it crosses none, and the shot flies on. A candidate's part is
/// found by its number in the model the object has now, which a part number past its last misses.
fn componentStruck(world: gameobj.World, bullet: *const Bullet, segment: objects.Segment, index: u16, run: []const Candidate) ?objects.Crossing {
    const slot = &world.objects.slots[index];
    const model = componentModel(slot) orelse return null;
    const root = slot.object.placeAt(.next);
    if (!objects.Box.ofBounds(model, root).meetsSegment(bullet.last, bullet.at)) return null;
    var struck: ?objects.Crossing = null;
    for (run) |candidate| {
        const ref = model.numbered(candidate.part orelse continue) orelse continue;
        const drawn = &ref.part().object;
        if (!(segment.missSquared(drawn.position, segment.nearest(drawn.position)) < drawn.radius * drawn.radius)) continue;
        const place = model.partAt(root, ref.model, ref.index, .next) orelse continue;
        if (objects.crossPart(ref, place, bullet.last, bullet.at)) |crossed| struck = crossed;
    }
    return struck;
}

/// What a shot that strikes a component throws: sparks along the face's normal, and for a Huge
/// Gun's, more of them, of its own, a fireball this far across and this long, and an explosion's
/// sound.
const component_sparks: sparks.Spray = .{ .speed = 20, .speed_range = 10, .spread = 1, .count = 10 };
const huge_sparks: sparks.Spray = .{ .speed = 30, .speed_range = 10, .spread = 1.6, .count = 40 };
const huge_fireball_size: f32 = 5000;
const huge_fireball_life = 150;

/// `bullet_hit` striking part `crossing.part` of the object in slot `index`, which lists
/// components: the shot is spent where it crosses the part's face, as the part stands drawn. A
/// force field glows whole (`shield.flareCapital`), and the hit leaves what it leaves on the part
/// (`shieldfx.componentHit`). A Huge Gun's shot sets off a lit fireball there, its own sparks
/// along the face's normal and an explosion's sound, and does no damage; any other throws sparks
/// along the normal, and the part takes the type's hull damage (`collision.componentDamage`),
/// which shows the hull of a cloaked object there (`cloak.reveal`).
fn componentHit(world: gameobj.World, bullet: *Bullet, index: u16, crossing: objects.Crossing) void {
    bullet.dies_at = spent;
    if (crossing.part.part().force_field) shield.flareCapital(world, index, crossing.part, null);
    shieldfx.componentHit(world, index, crossing, .onComponentOf(world.objects.slots[index].object.type));
    const at = crossing.inWorld();
    const normal = math.transform(crossing.part.part().drawn().orientation, crossing.normal);
    const huge: ?sparks.Kind = switch (bullet.kind) {
        .allied_huge_gun => .allied_huge_gun,
        .coalition_huge_gun => .coalition_huge_gun,
        else => null,
    };
    if (huge) |kind| {
        explode.fireballAt(world, at, .{ .size = huge_fireball_size, .life = huge_fireball_life, .light = true });
        sparks.spray(world, kind, at, normal, @splat(0), huge_sparks);
        explode.sound(world, at, .explosions);
        return;
    }
    sparks.spray(world, .component, at, normal, @splat(0), component_sparks);
    const record = bullet.stats(&world.objects.gun_stats);
    collision.componentDamage(world, index, crossing.part, record.damage.hull, bullet.owner, .bullet);
    cloak.reveal(world, index, at);
}

/// `0x00479940`: a shot that has passed an object's shields. It finds the last of the object's
/// parts the segment crosses, by the box each part's mesh stands in, and wears the quadrant's
/// armour by the type's hull damage. The hit is heard (`shieldfx.hullHit`), and it throws sparks
/// from where it struck, unless the camera is in the object's cockpit.
///
/// **Improvement:** the game takes where the shot struck in the part's own frame for where it
/// stands in the world, so its sparks fly from near the world's origin, far from the hit; the
/// port throws them from the hit.
fn hullHit(world: gameobj.World, bullet: *Bullet, index: u16, struck: collision.Quadrant) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const model = if (slot.model) |*live| live else return;
    const along = objects.partEntry(model, bullet.last, bullet.at, .last_shown) orelse return;
    const record = bullet.stats(&world.objects.gun_stats);
    collision.armorDamage(world, index, struck, dealt(all, index, bullet.kind, record.damage.hull), bullet.owner, .bullet);
    const at = math.lerp(bullet.last, bullet.at, along);
    shieldfx.hullHit(world, index, at);
    const inside = if (world.camera) |watching| watching.inside(index) else false;
    if (!inside) {
        const carried = gameobj.vector(slot.object.velocity) * @as(Vector, @splat(hull_sparks_carry));
        sparks.spray(world, .hull, at, at - slot.drawn.position, carried, hull_sparks);
    }
    bullet.dies_at = spent;
}

test clipEventMuzzles {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    var world = ship.world();
    const model = &ship.mission.objects.slots[ship.index].model.?;

    // A muzzles event fires a shot from each of the part's muzzles, held back by nothing: not
    // an empty charge, nor guns that are disabled.
    ship.object().gun_charge = 0;
    ship.object().flags.guns_disabled = true;
    const events = clipEvents(&world, ship.index);
    events.fire(events.context, events.owner, model, 0, .muzzles);
    try std.testing.expectEqual(2, flying(world));
    for (world.objects.bullets.pool[0..2]) |bullet| try std.testing.expectEqual(ship.index, bullet.owner);
    // A puff fires nothing.
    events.fire(events.context, events.owner, model, 0, .puff);
    try std.testing.expectEqual(2, flying(world));
}

test shoot {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const barrel = ship.guns()[0].turret.fixed;

    barrel.fire(world, ship.index, false);
    try std.testing.expectEqual(1, flying(world));
    const bullet = &world.objects.bullets.pool[0];
    // It leaves the muzzle, a hundred to the left of the ship's nose, flying along that nose at
    // the type's speed, and lives for the type's ticks.
    try std.testing.expectEqual(@as(Vector, .{ -100, 0, 0 }), bullet.at);
    try std.testing.expectEqual(@as(Vector, .{ 0, 0, 500 }), bullet.velocity);
    try std.testing.expectEqual(ship.mission.clock.mission_ticks + 100, bullet.dies_at);
    try std.testing.expectEqual(ship.mission.clock.mission_ticks, bullet.fired_at);
    try std.testing.expectEqual(ship.index, bullet.owner);
    // The record keeps the type less one, as the game does.
    try std.testing.expectEqual(testing.gun_type, bullet.kind);

    // A shot flies on by its velocity each step.
    moveBullets(world);
    try std.testing.expectEqual(@as(Vector, .{ -100, 0, 500 }), bullet.at);

    // Nothing is fired once every record is in flight.
    for (&world.objects.bullets.pool) |*record| record.live = true;
    barrel.fire(world, ship.index, false);
    try std.testing.expectEqual(max_bullets, flying(world));
}

test "a shot lights its muzzle's flash" {
    const gpa = std.testing.allocator;
    const built: flash.testing.Built = try .init(gpa, .{});
    defer built.deinit(gpa);
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    // A second ship of the model, made with the flashes, which each of its muzzles carries.
    ship.model.type.effects.flashes = &built.looks;
    const flashing = try ship.add(@enumFromInt(testing.ship_type), .{ 0, 0, 5000 });
    const world = ship.world();
    const slot = &world.objects.slots[flashing];
    try std.testing.expectEqual(2, slot.model.?.flashes.len);
    const barrel = slot.guns[0].turret.fixed;
    const lit = barrel.muzzle.flashOf().?;
    try std.testing.expectEqual(null, lit.until);

    // Lit for the Laser Cannon's 50 ticks from the frame's start; the other muzzle's stays out.
    barrel.fire(world, flashing, false);
    try std.testing.expectEqual(ship.mission.clock.frame_start + 50, lit.until);
    for (slot.model.?.flashes) |*other| {
        if (other != lit) try std.testing.expectEqual(null, other.until);
    }
}

test bulletsFrame {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();

    // A ship of the same model, 500 ahead of the one that fires.
    const target = try ship.add(@enumFromInt(9), .{ 0, 0, 500 });
    const slot = &ship.mission.objects.slots[target];
    slot.drawn = .{ .position = .{ 0, 0, 500 }, .orientation = math.identity };
    const struck = &slot.object;

    // A shot whose path crosses the ship: its shields take the type's shield damage, and it is
    // spent.
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    const bullet = &world.objects.bullets.pool[0];
    try std.testing.expectEqual(1, bullet.candidate_count);
    try std.testing.expectEqual(target, bullet.candidates[0].object);
    bullet.last = .{ 0, 0, 0 };
    bullet.at = .{ 0, 0, 600 };
    bulletsFrame(world, &ship.mission.clock, 0);
    try std.testing.expectEqual(10, struck.recent_damage);
    try std.testing.expectEqual(0, flying(world));

    // With its shields down the next shot reaches the hull, which takes the hull damage.
    struck.shields = .all(0);
    struck.recent_damage = 0;
    const armor = struck.armor;
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    const next = &world.objects.bullets.pool[0];
    next.last = .{ 0, 0, 0 };
    next.at = .{ 0, 0, 600 };
    bulletsFrame(world, &ship.mission.clock, 0);
    try std.testing.expectEqual(4, struck.recent_damage);
    try std.testing.expect(armor.total() > struck.armor.total());
    try std.testing.expectEqual(0, flying(world));

    // A shot that reaches the end of its life is let go.
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    try std.testing.expectEqual(1, flying(world));
    ship.mission.clock.frame_start += 1000;
    bulletsFrame(world, &ship.mission.clock, 0);
    try std.testing.expectEqual(0, flying(world));
}

test "Turret.base" {
    var model: objects.Model = .{ .parts = &.{}, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{} };
    const launcher: Turret = .{ .missile = .{ .model = &model, .base = 3, .launcher = 4 } };
    try std.testing.expectEqual(3, launcher.base().?.index);
    try std.testing.expect(launcher.base().?.model == &model);
    try std.testing.expectEqual(null, (Turret{ .gone = {} }).base());
}

test "the Nova Cannon strikes what stands ahead, and its beam shows" {
    const gpa = std.testing.allocator;
    const fixture: test_looks.Fixture = try .init(gpa);
    defer fixture.deinit(gpa);
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const mission = &ship.mission;
    const all = mission.objects;
    all.bullets.looks = fixture.looks;
    all.gun_stats.types[GunType.nova_cannon.number()].damage = .{ .shield = 40, .hull = 20 };
    const shooter = ship.object();
    shooter.gun_condition = 1;
    // A ship straight ahead, and one off to the side.
    const ahead = try ship.add(@enumFromInt(testing.ship_type), .{ 0, 0, 5000 });
    const aside = try ship.add(@enumFromInt(testing.ship_type), .{ 5000, 0, 5000 });
    const untouched = all.slots[ahead].object.shields;

    // Short of half a charge, nothing fires, and the charge is lost.
    shooter.nova_charge = 0.4;
    nova.release(world, ship.index);
    try std.testing.expectEqual(0, shooter.nova_charge);
    try std.testing.expectEqual(null, all.bullets.beams.slots[0]);
    try std.testing.expectEqual(untouched, all.slots[ahead].object.shields);

    // A full charge strikes the ship ahead and not the one aside, and shows its beam, strands and
    // all.
    shooter.nova_charge = 1;
    nova.release(world, ship.index);
    try std.testing.expectEqual(0, shooter.nova_charge);
    try std.testing.expect(all.slots[ahead].object.shields.total() < untouched.total());
    try std.testing.expectEqual(untouched, all.slots[aside].object.shields);
    try std.testing.expect(all.bullets.beams.slots[0].?.full());

    // Its time over, it goes.
    all.bullets.beams.frame(all, mission.clock.frame_start + nova.beam_ticks + 1);
    try std.testing.expectEqual(null, all.bullets.beams.slots[0]);
}

test "the Nova Cannon strikes a ship's components leaf by leaf" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const mission = &ship.mission;
    mission.objects.gun_stats.types[GunType.nova_cannon.number()].damage = .{ .shield = 40, .hull = 20 };
    // A ship that lists its one part as a component: a square facing the shooter, 500 ahead.
    var hull: create.testing.Model = undefined;
    try hull.init(gpa);
    defer hull.deinit(gpa);
    hull.withHull();
    hull.withComponent();
    hull.data[0].part.component_armor = 100;
    const target = try mission.addWith(hull.types(), .reaper, .{ 0, 0, 500 });
    const slot = &mission.objects.slots[target];
    slot.model.?.place(slot.drawn.position, slot.drawn.orientation);
    const part = &slot.model.?.parts[0];
    const armor = part.armor;

    // Its square's one leaf is crossed: the component takes the hull damage times the charge.
    ship.object().nova_charge = 1;
    nova.release(world, ship.index);
    try std.testing.expect(part.armor < armor);
}

test "a shot strikes a component of a ship that lists them" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    // A ship that lists its one part as a component: a square facing the shooter, 500 ahead.
    var hull: create.testing.Model = undefined;
    try hull.init(gpa);
    defer hull.deinit(gpa);
    hull.withHull();
    hull.withComponent();
    hull.data[0].part.component_armor = 100;
    const mission = &ship.mission;
    const target = try mission.addWith(hull.types(), .reaper, .{ -50, 0, 500 });
    const slot = &mission.objects.slots[target];
    try std.testing.expect(slot.object.flags.components);
    slot.model.?.place(slot.drawn.position, slot.drawn.orientation);
    const part = &slot.model.?.parts[0];
    // As far across as its square, which the fixture's loaded part, with no mesh, leaves out.
    part.object.radius = 150;

    // The part is the shot's candidate, and the shot, crossing it, spends itself on it.
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    const bullet = &world.objects.bullets.pool[0];
    try std.testing.expectEqual(1, bullet.candidate_count);
    try std.testing.expectEqual(target, bullet.candidates[0].object);
    try std.testing.expectEqual(0, bullet.candidates[0].part.?);
    bullet.last = .{ -100, 0, 0 };
    bullet.at = .{ -100, 0, 600 };
    bulletsFrame(world, &mission.clock, 0);
    try std.testing.expect(part.armor < 100);
    try std.testing.expectEqual(0, flying(world));

    // A Huge Gun's shot sets a fireball off there, and does no damage.
    const armor = part.armor;
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    const huge = &world.objects.bullets.pool[0];
    huge.kind = .coalition_huge_gun;
    huge.last = .{ -100, 0, 0 };
    huge.at = .{ -100, 0, 600 };
    bulletsFrame(world, &mission.clock, 0);
    try std.testing.expectEqual(armor, part.armor);
    try std.testing.expectEqual(0, flying(world));

    // One that passes beside the part flies on.
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    const beside = &world.objects.bullets.pool[0];
    beside.last = .{ -400, 0, 0 };
    beside.at = .{ -400, 0, 600 };
    bulletsFrame(world, &mission.clock, 0);
    try std.testing.expectEqual(1, flying(world));

    // Where the object's model has changed since the shot was fired, to one without the part, the
    // shot finds no part by the number it keeps, and flies on.
    beside.* = .{};
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    const changed = &world.objects.bullets.pool[0];
    const parts = slot.model.?.parts;
    defer slot.model.?.parts = parts;
    slot.model.?.parts = parts[0..0];
    changed.last = .{ -100, 0, 0 };
    changed.at = .{ -100, 0, 600 };
    bulletsFrame(world, &mission.clock, 0);
    try std.testing.expectEqual(1, flying(world));
}

test "a shot striking a hull throws sparks from where it struck" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    var built: sparks.testing.Built = try .init(gpa);
    defer built.deinit(gpa);
    var watching: @import("camera.zig").Camera = .{};
    var world = ship.world();
    world.sparks = &built.sparks;
    world.camera = &watching;
    const target = try ship.add(@enumFromInt(9), .{ 0, 0, 500 });
    const slot = &ship.mission.objects.slots[target];
    slot.drawn = .{ .position = .{ 0, 0, 500 }, .orientation = math.identity };
    slot.model.?.place(slot.drawn.position, slot.drawn.orientation);
    slot.object.shields = .all(0);

    // They fly from where the shot enters the part's box, its face 500 ahead.
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    const bullet = &world.objects.bullets.pool[0];
    bullet.last = .{ 0, 0, 0 };
    bullet.at = .{ 0, 0, 600 };
    bulletsFrame(world, &ship.mission.clock, 0);
    for (built.sparks.sparks.slots[0..hull_sparks.count]) |thrown| {
        try std.testing.expect(math.distance(thrown.?.at, .{ 0, 0, 500 }) < 1e-2);
    }
    try std.testing.expectEqual(null, built.sparks.sparks.slots[hull_sparks.count]);
}

test "the player's shifted shields take a hit before the quadrant does" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    // The ship that fires is the player's, so the target here is another slot shooting back.
    const shooter = try ship.add(@enumFromInt(9), .{ 0, 0, 500 });
    const player = &ship.mission.objects.slots[ship.mission.objects.player];
    player.drawn = .{ .position = @splat(0), .orientation = math.identity };
    ship.mission.player.shield_reserves = .{ .fore = 25, .aft = 0 };

    // A shot into the player's fore quadrant comes off the reserve, and the shields are untouched.
    ship.mission.objects.slots[shooter].guns[0].turret.fixed.fire(world, shooter, false);
    const bullet = &world.objects.bullets.pool[0];
    bullet.last = .{ 0, 0, 500 };
    bullet.at = .{ 0, 0, -100 };
    bullet.candidates[0] = .{ .object = ship.mission.objects.player };
    bullet.candidate_count = 1;
    const shields = player.object.shields;
    bulletsFrame(world, &ship.mission.clock, 0);
    try std.testing.expectEqual(15, ship.mission.player.shield_reserves.fore);
    try std.testing.expectEqual(shields, player.object.shields);
}

test "a heard shot sounds, following it" {
    const hog_snd = @import("hog_snd.zig");
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(4, null);
    const sound = &speaker.sound;
    const bank = comptime hog_snd.testing.bank(80);
    sound.open3D(try @import("../../formats/fat.zig").Bank.parse(&bank));
    var world = ship.world();
    world.hearing = speaker.hearing(&ship.mission.clock);

    // Unheard, nothing plays; heard, the gun type's sound follows the shot.
    ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    for (sound.voices_3d[0..sound.voice_3d_count]) |voice| try std.testing.expectEqual(-1, voice.owner);
    ship.guns()[1].turret.fixed.fire(world, ship.index, true);
    const record = testing.gun_type.stats(&ship.mission.objects.gun_stats);
    var found = false;
    for (sound.voices_3d[0..sound.voice_3d_count]) |voice| {
        if (voice.owner != 1) continue;
        try std.testing.expectEqual(sound3d.Follows.shot, voice.follows);
        try std.testing.expectEqual(record.sound, voice.sound);
        found = true;
    }
    try std.testing.expect(found);
}

test "only the latest two shots of a ring cast a light" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const bullets = &world.objects.bullets;
    // The player's ship is the first slot, and a hostile ship fires too.
    const other = try ship.add(@enumFromInt(9), .{ 0, 0, 5000 });
    ship.mission.objects.slots[other].object.side = .hostile;

    // The player's third shot puts out the first one's light.
    for (0..3) |_| ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    try std.testing.expectEqual(null, bullets.pool[0].light);
    try std.testing.expect(bullets.pool[1].light != null);
    try std.testing.expect(bullets.pool[2].light != null);
    try std.testing.expectEqual(shot_light, bullets.pool[2].light.?.colour);

    // Another ship's shots keep a ring of their own, and a hostile ship's are orange.
    ship.mission.objects.slots[other].guns[0].turret.fixed.fire(world, other, false);
    try std.testing.expectEqual(hostile_shot_light, bullets.pool[3].light.?.colour);
    try std.testing.expect(bullets.pool[1].light != null);

    // A shot let go leaves its ring's place empty, and the record free for the next shot.
    bullets.release(2);
    try std.testing.expectEqual(null, bullets.player_lights.slots[0]);
    try std.testing.expectEqual(1, bullets.player_lights.slots[1]);
    try std.testing.expect(!bullets.pool[2].live);
}

test "every shot casts a light where OpenReliant lets them" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    world.objects.bullets.shot_lights = .every_shot;
    for (0..3) |_| ship.guns()[0].turret.fixed.fire(world, ship.index, false);
    for (world.objects.bullets.pool[0..3]) |bullet| try std.testing.expect(bullet.light != null);
    // The rings are left alone.
    try std.testing.expectEqual(null, world.objects.bullets.player_lights.slots[0]);
}

test "a Turret Flak shot bursts at a random range, scatters, and is at times a laser's" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    const types = &world.objects.gun_stats.types;
    for ([_]GunType{ .turret_flak, .turret_lasers }) |kind| {
        types[kind.number()].lifetime = 100;
        types[kind.number()].speed = 500;
    }
    var gun = ship.guns()[0].turret.fixed;
    gun.type = .turret_flak;

    var flak: usize = 0;
    var lasers: usize = 0;
    for (0..40) |_| {
        gun.fire(world, ship.index, false);
        const bullet = &world.objects.bullets.pool[0];
        if (bullet.kind == .turret_lasers) {
            // A laser's shot flies straight, for its type's whole life.
            lasers += 1;
            try std.testing.expectEqual(@as(Vector, .{ 0, 0, 500 }), bullet.velocity);
            try std.testing.expectEqual(ship.mission.clock.mission_ticks + 100, bullet.dies_at);
        } else {
            flak += 1;
            const life = bullet.dies_at - ship.mission.clock.mission_ticks;
            try std.testing.expect(life >= 20 and life <= 100);
            try std.testing.expect(!@reduce(.And, bullet.velocity == @as(Vector, .{ 0, 0, 500 })));
            try std.testing.expectApproxEqAbs(500, math.length(bullet.velocity), 0.01);
        }
        world.objects.bullets.release(0);
    }
    try std.testing.expect(flak > 0 and lasers > 0);
}

test "a Huge Gun's shot reaches farther, and always through the shields" {
    const gpa = std.testing.allocator;
    var ship: testing.Ship = undefined;
    try ship.init(gpa);
    defer ship.deinit(gpa);
    const world = ship.world();
    world.objects.gun_stats.types[GunType.coalition_huge_gun.number()] = testing.gun_type.stats(&world.objects.gun_stats);
    var gun = ship.guns()[0].turret.fixed;
    gun.type = .coalition_huge_gun;

    // A ship off to the side of the shot's path by more than its radius, but within 3000.
    const target = try ship.add(@enumFromInt(9), .{ 1500, 0, 500 });
    const slot = &ship.mission.objects.slots[target];
    slot.drawn = .{ .position = .{ 1500, 0, 500 }, .orientation = math.identity };
    slot.object.shields = .all(0);
    gun.fire(world, ship.index, false);
    const bullet = &world.objects.bullets.pool[0];
    try std.testing.expectEqual(1, bullet.candidate_count);
    bullet.last = .{ 0, 0, 0 };
    bullet.at = .{ 0, 0, 1000 };
    bulletsFrame(world, &ship.mission.clock, 0);
    // It struck the ship with its shields down and still took the shield's way: the shield damage,
    // then the share of it that passes to the armour. A hull hit would have counted the hull
    // damage alone, 4.
    try std.testing.expectEqual(10 + 4, slot.object.recent_damage);
}

// --- How a shot is drawn -------------------------------------------------------------------------

/// The textures the shots are drawn with, which `guns_init` (`0x00478990`) and `bullet_build`
/// (`0x0047D9A0`) require.
pub const Image = enum {
    /// Most shots' (`0x0056314C`). Each gun type's bolt takes a span of it across
    /// (`gun_stats.atlas`), a friendly shot the top half and a hostile one the bottom, and its
    /// right-hand corner holds the Tachyon Cannon's and the Turret Lasers' pieces.
    lasers,
    /// The Pulse Cannon's and the Collapser Guns' flares, a friendly shot's and any other side's.
    pulse,
    pulse_other,
    collapser,
    collapser_other,
    /// The Huge Guns' shells.
    allied_huge,
    coalition_huge,
    /// The Huge Guns' glow.
    sun,

    /// The name the game requires it by.
    pub fn name(image: Image) []const u8 {
        return switch (image) {
            .lasers => "gunflare\\lasers",
            .pulse => "gunflare\\1pulse",
            .pulse_other => "gunflare\\1pulse-e",
            .collapser => "gunflare\\7colgun",
            .collapser_other => "gunflare\\7colgun-e",
            .allied_huge => "alhuge",
            .coalition_huge => "clhuge",
            .sun => "sunlayer3",
        };
    }
};

/// The meshes the shots are drawn with, which `guns_init` builds once.
///
/// The game builds each twice, one set for the player's side and one for the rest, and the two are
/// the same but for the Turret Lasers' rings, so OpenReliant builds the rest once. It also builds
/// four Messon Blaster bolts where the shots use three, and four Vulcan Battery bolts that are the
/// same, which OpenReliant builds once.
pub const Shape = enum {
    laser,
    messon_0,
    messon_1,
    messon_2,
    proton,
    tachyon_star,
    tachyon_square,
    neutron,
    gattling_plasma_0,
    gattling_plasma_1,
    gattling_plasma_2,
    gattling_plasma_3,
    vulcan,
    nova,
    turret_lasers,
    turret_lasers_other,
    allied_huge,
    coalition_huge,
};

/// How `guns_init` builds a shape.
const Recipe = union(enum) {
    /// Two quads crossed along the flight from the muzzle on, one upright and one flat, and far
    /// off the upright one alone. `0x00478460`, `0x0047ECD0`, `0x0047F370`, `0x0047F730`,
    /// `0x0047F9C0`, `0x0047FC90` and `0x0047FF20` differ in nothing else.
    bolt: Bolt,
    /// A bolt with two diamonds across its flight, at `ring` of its length and at `far_ring`,
    /// drawn from the shot texture's corner (`0x0047EF80`).
    ringed: struct { bolt: Bolt, ring: f32 },
    /// Blades through the flight's axis, spread evenly over half a turn, `half_length` long
    /// either way and `radius` wide either side (`0x004ADF90`).
    star: struct { blades: u8, radius: f32, half_length: f32, span: [2][2]f32 },
    /// A square facing along the flight, `side` across, as two triangles (`0x0044F000`), with
    /// the texture coordinates of its corners.
    square: struct { side: f32, corners: [4][2]f32 },
    /// Three squares through the centre, one in each plane, `half` across either way
    /// (`0x004801B0`, `0x00480420`).
    cross: struct { half: f32, image: Image },
};

/// A bolt's size and look.
const Bolt = struct {
    /// Half its width, half its height, and its length.
    size: [3]f32,
    /// Coloured by the shot's own colours rather than white.
    lit: bool = false,
    /// How far off the near mesh gives way to the far one, and the far one to nothing.
    until: [2]f32 = .{ 15000, 100000 },
};

/// The far end of the second diamond on a ringed bolt, of its length (`0x004DC8AC`), and how wide
/// and high the diamonds are, of the bolt's width and height (`bolt_build_turret_lasers`, which
/// holds it in its code).
const far_ring: f32 = 0.85;
const diamond_size: f32 = 0.6;

/// How far off the Tachyon Cannon's pieces are drawn (`0x0047F600`).
const tachyon_until: f32 = 1_000_000;

/// What each shape is built from.
const recipes: std.EnumArray(Shape, Recipe) = .init(.{
    // `0x00478460` sizes the Laser Cannon's by its record, the others write theirs in.
    .laser = .{ .bolt = .{ .size = gun_stats.gun_types[GunType.laser_cannon.number()].bolt } },
    .messon_0 = messon(0),
    .messon_1 = messon(1),
    .messon_2 = messon(2),
    .proton = .{ .bolt = .{ .size = .{ 50, 50, 1400 }, .lit = true } },
    .tachyon_star = .{ .star = .{ .blades = 3, .radius = 60, .half_length = 800, .span = .{ .{ 0.875, 0 }, .{ 1, 0.24 } } } },
    .tachyon_square = .{ .square = .{ .side = 200, .corners = .{ .{ 0.875, 0.252 }, .{ 1, 0.252 }, .{ 1, 0.375 }, .{ 0.875, 0.375 } } } },
    .neutron = .{ .bolt = .{ .size = .{ 80, 80, 1500 }, .until = .{ 15000, 10_000_000 } } },
    .gattling_plasma_0 = gattlingPlasma(0),
    .gattling_plasma_1 = gattlingPlasma(1),
    .gattling_plasma_2 = gattlingPlasma(2),
    .gattling_plasma_3 = gattlingPlasma(3),
    .vulcan = .{ .bolt = .{ .size = .{ 40, 40, 300 } } },
    .nova = .{ .bolt = .{ .size = .{ 180, 180, 10000 }, .until = .{ 15000, 500_000 } } },
    .turret_lasers = turretLasers(0.6),
    .turret_lasers_other = turretLasers(0.15),
    .allied_huge = .{ .cross = .{ .half = 700, .image = .allied_huge } },
    .coalition_huge = .{ .cross = .{ .half = 1700, .image = .coalition_huge } },
});

/// The Messon Blaster's bolts (`0x0047ECD0`): each 400 longer than the last (`0x004DC5A8`), from 40
/// (`0x004DC8A8`).
fn messon(comptime index: f32) Recipe {
    return .{ .bolt = .{ .size = .{ 5, 5, index * 400 + 40 } } };
}

/// The Gattling Plasma Cannon's bolts (`0x0047F9C0`): each 150 longer than the last
/// (`0x004DC594`), from 200 (`0x004DC468`).
fn gattlingPlasma(comptime index: f32) Recipe {
    return .{ .bolt = .{ .size = .{ 40, 40, index * 150 + 200 } } };
}

/// The Turret Lasers' bolt (`0x0047EF80`), its first ring where the set has it: 0.6 of its length
/// for the player's side (`0x004DC4B4`), 0.15 for the rest (`0x004DC450`).
fn turretLasers(comptime ring: f32) Recipe {
    return .{ .ringed = .{ .bolt = .{ .size = turret_lasers_bolt, .until = .{ 60000, 100000 } }, .ring = ring } };
}

/// The Turret Lasers' bolt's half width, half height and length, which the turrets' muzzle flashes
/// are sized by (`flash.Look.turret`).
pub const turret_lasers_bolt: [3]f32 = .{ 200, 200, 2400 };

/// The most corners of any mesh a shot is drawn with: a ringed bolt's.
const max_corners = 16;

/// A shape as built: its meshes, one for each level of detail, and the levels a mesh object over it
/// draws.
pub const Built = struct {
    meshes: [2]srapiext.Mesh,
    levels: [2]srapiext.Level,
    count: u8,

    fn deinit(built: *const Built, gpa: Allocator) void {
        for (built.meshes[0..built.count]) |mesh| mesh.deinit(gpa);
    }

    /// The levels a mesh object over it draws, which do not move once `built` stands in place.
    pub fn levelsOf(built: *const Built) []const srapiext.Level {
        return built.levels[0..built.count];
    }
};

/// What the shots are drawn with, built once (`guns_init`, `0x00478990`) and let go
/// (`guns_shutdown`, `0x00478FE0`).
pub const Looks = struct {
    shapes: std.EnumArray(Shape, Built),
    images: std.EnumArray(Image, *srtexture.Image),
    /// The Nova Cannon's beam and its strands.
    nova: nova.Looks,
    /// The Turret Flak's shell (`loadShell`): the first mesh of the first part of ship type
    /// `shell_type`'s model, drawn at every distance. Null until it is loaded, or where the model
    /// cannot be, and a Turret Flak shot is then not drawn.
    shell: ?srapiext.Level = null,

    pub fn create(gpa: Allocator, textures: *srtexture.Table) (Allocator.Error || matmanager.Error)!*Looks {
        const looks = try gpa.create(Looks);
        errdefer gpa.destroy(looks);
        for (std.enums.values(Image)) |image| {
            looks.images.set(image, try matmanager.textureRequire(textures, image.name()));
        }
        var made: usize = 0;
        errdefer for (std.enums.values(Shape)[0..made]) |shape| looks.shapes.getPtr(shape).deinit(gpa);
        for (std.enums.values(Shape)) |shape| {
            try build(looks.shapes.getPtr(shape), gpa, recipes.get(shape), &looks.images);
            made += 1;
        }
        looks.nova = try .create(gpa, textures);
        looks.shell = null;
        return looks;
    }

    /// `guns_load_shell` (`0x00479140`), as a mission starts, once the objects are reset: the
    /// Turret Flak's shell, the first level of the first part of ship type `shell_type`'s model,
    /// counted as used so that it stays loaded (`xtrabits.firstLevels`).
    pub fn loadShell(looks: *Looks, all: *Objects, types: ShipTypes) void {
        const levels = xtrabits.firstLevels(all, types, shell_type) orelse &.{};
        looks.shell = if (levels.len > 0) .{ .mesh = levels[0].mesh, .until = std.math.inf(f32) } else null;
    }

    pub fn destroy(looks: *Looks, gpa: Allocator) void {
        for (&looks.shapes.values) |*built| built.deinit(gpa);
        looks.nova.deinit(gpa);
        gpa.destroy(looks);
    }
};

/// The ship type whose model is the Turret Flak's shell (`shell.shp`, `0x00479140`).
const shell_type: u8 = 0xB1;

/// Builds `recipe` into `built`, which stands in place from then on.
fn build(built: *Built, gpa: Allocator, recipe: Recipe, images: *const std.EnumArray(Image, *srtexture.Image)) Allocator.Error!void {
    const lasers = images.get(.lasers);
    switch (recipe) {
        .bolt => |bolt| try buildBolt(built, gpa, lasers, bolt, null),
        .ringed => |ringed| try buildBolt(built, gpa, lasers, ringed.bolt, ringed.ring),
        .star => |star| {
            built.meshes[0] = try starMesh(gpa, star.blades, star.radius, .{ -star.half_length, star.half_length }, star.span, meshMaterial(true), lasers);
            built.levels[0] = .{ .mesh = &built.meshes[0], .until = tachyon_until };
            built.count = 1;
        },
        .square => |square| {
            const half = square.side / 2;
            const corners = [4]Vector{ .{ -half, -half, 0 }, .{ half, -half, 0 }, .{ half, half, 0 }, .{ -half, half, 0 } };
            // Two triangles, each corner with its own coordinates, as the game gives them.
            const faces = [2][3]u16{ .{ 3, 2, 0 }, .{ 2, 1, 0 } };
            var uv: [6][2]f32 = undefined;
            for (&uv, @as(*const [6]u16, @ptrCast(&faces))) |*at, corner| at.* = square.corners[corner];
            built.meshes[0] = try meshOf(3, gpa, &corners, &faces, &uv, meshMaterial(true), lasers);
            built.levels[0] = .{ .mesh = &built.meshes[0], .until = tachyon_until };
            built.count = 1;
        },
        .cross => |cross| {
            const h = cross.half;
            const corners = [12]Vector{
                .{ 0, h, -h },  .{ 0, -h, -h }, .{ 0, -h, h }, .{ 0, h, h },
                .{ h, 0, -h },  .{ -h, 0, -h }, .{ -h, 0, h }, .{ h, 0, h },
                .{ -h, -h, 0 }, .{ h, -h, 0 },  .{ h, h, 0 },  .{ -h, h, 0 },
            };
            const faces = [3][4]u16{ quadFace(0), quadFace(1), quadFace(2) };
            built.meshes[0] = try meshOf(4, gpa, &corners, &faces, null, ownMaterial(true), images.get(cross.image));
            // A single mesh, which the game draws at every distance.
            built.levels[0] = .{ .mesh = &built.meshes[0], .until = std.math.inf(f32) };
            built.count = 1;
        },
    }
}

/// The corners of a star's blade, a quad.
pub const blade_corners = 4;

/// The corners of a blade at its far end, as `blade` lays them out.
pub const blade_far = [_]usize{ 1, 2 };

/// Whether corner `corner` of a mesh of blades, counted across them all, is at its blade's far end
/// (`blade_far`).
pub fn farCorner(corner: usize) bool {
    return std.mem.indexOfScalar(usize, &blade_far, corner % blade_corners) != null;
}

/// The most blades a star is built with.
const max_blades = max_corners / blade_corners;

/// `mesh_build_star` (`0x004ADF90`): blades through the Z axis, spread evenly over half a turn,
/// each a quad `radius` wide either side of the axis and running from `along[0]` to `along[1]`
/// on it, drawn with `material` over `image`: the texture's `span` across each blade
/// (`bladeCorners`), or the object's own coordinates where it has none. No more than `max_blades`
/// are built.
pub fn starMesh(gpa: Allocator, wanted: u8, radius: f32, along: [2]f32, span: ?[2][2]f32, material: srapiext.Material, image: *srtexture.Image) Allocator.Error!srapiext.Mesh {
    const blades: usize = @min(wanted, max_blades);
    var corners: [max_corners]Vector = undefined;
    var uv: [max_corners][2]f32 = undefined;
    var faces: [max_blades][blade_corners]u16 = undefined;
    for (0..blades) |at| {
        corners[at * blade_corners ..][0..blade_corners].* = blade(at, blades, radius, along);
        if (span) |given| uv[at * blade_corners ..][0..blade_corners].* = bladeCorners(given);
        faces[at] = quadFace(at);
    }
    const count = blades * blade_corners;
    return meshOf(blade_corners, gpa, corners[0..count], faces[0..blades], if (span != null) uv[0..count] else null, material, image);
}

/// The corners of blade `index` of a star of `blades` (`starMesh`): turned `index` shares of half a
/// turn about the Z axis, `radius` wide either side of it, from `along[0]` to `along[1]`.
pub fn blade(index: usize, blades: usize, radius: f32, along: [2]f32) [blade_corners]Vector {
    const angle = @as(f32, @floatFromInt(index)) * std.math.pi / @as(f32, @floatFromInt(blades));
    const across: Vector = .{ @sin(angle) * radius, @cos(angle) * radius, 0 };
    const near: Vector = .{ 0, 0, along[0] };
    const far: Vector = .{ 0, 0, along[1] };
    return .{ near - across, far - across, far + across, near + across };
}

test blade {
    // Its far corners are those `blade_far` names, the next blade's too.
    const corners = blade(1, 3, 10, .{ 5, 400 });
    for (corners, 0..) |corner, at| {
        try std.testing.expectEqual(@as(f32, if (farCorner(at)) 400 else 5), corner[2]);
        try std.testing.expectEqual(farCorner(at), farCorner(at + blade_corners));
    }
    try std.testing.expect(!farCorner(0) and farCorner(1) and farCorner(2) and !farCorner(3));
}

/// The texture coordinates of a star's blade's four corners (`starMesh`), for the texture's `span`
/// from its low corner to its high one: the near end the high `v`, the far the low, and the one
/// side the high `u`, the other the low.
pub fn bladeCorners(span: [2][2]f32) [blade_corners][2]f32 {
    const low, const high = span;
    return .{ .{ high[0], high[1] }, .{ high[0], low[1] }, .{ low[0], low[1] }, .{ low[0], high[1] } };
}

/// Builds a bolt, with its two diamonds at `ring` and `far_ring` of its length where it has them.
fn buildBolt(built: *Built, gpa: Allocator, image: *srtexture.Image, bolt: Bolt, ring: ?f32) Allocator.Error!void {
    const across, const up, const long = bolt.size;
    var corners: [max_corners]Vector = undefined;
    // The upright quad, then the flat one.
    corners[0..8].* = .{
        .{ 0, up, 0 },     .{ 0, -up, 0 },     .{ 0, -up, long },     .{ 0, up, long },
        .{ across, 0, 0 }, .{ -across, 0, 0 }, .{ -across, 0, long }, .{ across, 0, long },
    };
    var count: usize = 8;
    if (ring) |first| {
        const x = across * diamond_size;
        const y = up * diamond_size;
        for ([_]f32{ first * long, far_ring * long }) |z| {
            corners[count..][0..4].* = .{ .{ -x, 0, z }, .{ 0, -y, z }, .{ x, 0, z }, .{ 0, y, z } };
            count += 4;
        }
    }
    const faces = [4][4]u16{ quadFace(0), quadFace(1), quadFace(2), quadFace(3) };
    const material = ownMaterial(bolt.lit);
    built.meshes[0] = try meshOf(4, gpa, corners[0..count], faces[0 .. count / 4], null, material, image);
    errdefer built.meshes[0].deinit(gpa);
    built.meshes[1] = try meshOf(4, gpa, corners[0..4], faces[0..1], null, material, image);
    for (&built.levels, &built.meshes, bolt.until) |*level, *mesh, until| level.* = .{ .mesh = mesh, .until = until };
    built.count = 2;
}

/// The corners of the `index`th quad of a mesh made of quads.
pub fn quadFace(index: usize) [4]u16 {
    const first: u16 = @intCast(index * 4);
    return .{ first, first + 1, first + 2, first + 3 };
}

/// A material drawn with the shot's own texture coordinates (`MeshObject.own_uv`), added to what
/// stands behind it.
pub fn ownMaterial(lit: bool) srapiext.Material {
    return .onePass(.{ .coordinates = .generated, .lit = lit, .blend = .add });
}

/// A material drawn with the mesh's own texture coordinates, added to what stands behind it.
pub fn meshMaterial(lit: bool) srapiext.Material {
    var material = ownMaterial(lit);
    material.coordinates[0] = .mesh;
    return material;
}

/// A mesh of `faces`, each a fan of `n` corners by their index into `corners`, with the texture
/// coordinates of each index in turn, if it has its own. Its normals and planes stay zero, as
/// nothing reads them here: every shot is never culled and lit by nothing but its own colours.
///
/// `mesh_create` gives the mesh's one run of polygons as many as it has vertices, so the game walks
/// empty polygons after the real ones, which draw nothing; OpenReliant's run holds the real ones.
pub fn meshOf(
    comptime n: u16,
    gpa: Allocator,
    corners: []const Vector,
    faces: []const [n]u16,
    uv: ?[]const [2]f32,
    material: srapiext.Material,
    image: *srtexture.Image,
) Allocator.Error!srapiext.Mesh {
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = faces.len, .vertices = corners.len, .indices = faces.len * n });
    errdefer mesh.deinit(gpa);
    @memcpy(mesh.positions, corners);
    mesh.numberPolygons(n);
    for (faces, 0..) |face, i| mesh.indices[i * n ..][0..n].* = face;
    if (uv) |given| @memcpy(try mesh.addCoordinates(gpa), given);
    mesh.surfaces[0] = .{ .polygons = @intCast(faces.len), .material = material, .textures = .{ .{ .image = image }, .none } };
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// The most things a shot is drawn with (`+0x3C`, eight words).
pub const max_pieces = 8;

/// One of the things a shot is drawn with. The first stands where the shot is drawn, turned as
/// the muzzle was, and the rest hang off it.
pub const Piece = struct {
    /// Where it stands on the first piece, and how it is turned there; the first piece's `turn`
    /// is its own in the world.
    offset: Vector = @splat(0),
    turn: math.Matrix = math.identity,
    drawn: Drawn = .frame,
    /// A mesh's own colours (`MeshObject.baked`), and a sprite set's one sprite.
    colours: [max_corners][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    sprite: [1]srapiext.Sprite = .{.{}},

    pub const Drawn = union(enum) {
        /// A bare frame the rest hang off (`frame_create`), which draws nothing.
        frame,
        mesh: srapiext.MeshObject,
        sprites: srapiext.SpriteSet,
        light: srlight.Light,
    };
};

/// The object flags of a shot's mesh (`bullet_build`): never culled, with the shot's own texture
/// coordinates, and colours of its own where it fades them.
const shot_flags: srapiext.ObjectFlags = .{ .not_culled = true, .own_first = true };
const faded_flags: srapiext.ObjectFlags = .{ .not_culled = true, .own_first = true, .baked_object = true };

/// A mesh object over a shape.
fn meshPiece(looks: *const Looks, shape: Shape, flags: srapiext.ObjectFlags) Piece.Drawn {
    const built = looks.shapes.getPtrConst(shape);
    return .{ .mesh = .{
        .flags = flags,
        .position = @splat(0),
        .radius = built.meshes[0].radius,
        .levels = built.levelsOf(),
    } };
}

/// A set of one sprite on `image`, `half` across either way and sorted as if it stood that much
/// nearer (`sprite_set_create` with one sprite): coloured by its colour, and added.
fn flarePiece(looks: *const Looks, image: Image, half: f32, offset: Vector) Piece {
    var set: srapiext.SpriteSet = .{ .sprites = &.{} };
    set.surface.material.lit[0] = true;
    set.surface.textures = .{ .{ .image = looks.images.get(image) }, .none };
    return .{
        .offset = offset,
        .drawn = .{ .sprites = set },
        .sprite = .{.{ .half_size = .{ half, half }, .bias = -half }},
    };
}

/// How the shots of the gun types that are drawn with more than a bolt look: the sizes and places
/// `bullet_build` gives their pieces, which it holds in its code but where an address is given,
/// and how `bullets_frame` wheels and shades them, a tick.
///
/// The Pulse Cannon's: a flare `half` across either way, and a smaller one, `second_half`,
/// `second_offset` off it at a random turn, which wheels round it about X, Y and Z
/// (`0x004DC880`, `0x004DC4AC`, `0x004DC420`).
const pulse_look = struct {
    const half: f32 = 60;
    const second_half: f32 = 30;
    const second_offset: Vector = .{ 55, 0, 0 };
    const wheel: Vector = .{ 0.12, 0.02, 0.1 };
};

/// The Messon Blaster's: each bolt `off` the axis and up to `along` along it (`0x004DC544`).
const messon_look = struct {
    const off: f32 = 20;
    const along: f32 = 300;
};

/// The Gattling Lasers': each bolt `off` the axis.
const gattling_look = struct {
    const off: f32 = 30;
};

/// The Tachyon Cannon's: its square `square_offset` along its star.
const tachyon_look = struct {
    const square_offset: Vector = .{ 0, 0, 100 };
};

/// The Neutron Particle Gun's: its bolt as bright as `shade` of what its colour has left
/// (`0x004DC4C0`).
const neutron_look = struct {
    const shade: f32 = 0.3;
};

/// The Collapser Guns': two flares `half` across either way, `off` either side of the frame, which
/// spins by `spin` (`0x004DC3F8`).
const collapser_look = struct {
    const half: f32 = 48;
    const off: f32 = 30;
    const spin: f32 = 0.2;
};

/// The Gattling Plasma Cannon's: each bolt up to `along` along the axis (`0x004DC468`), and
/// `off_least` off it and up to `off_range` more (`0x004DC520`, `0x004DC72C`).
const plasma_look = struct {
    const along: f32 = 200;
    const off_least: f32 = 10;
    const off_range: f32 = 20;
};

/// The Vulcan Battery's: its four bolts `across` and `up` off the axis either way, the pairs
/// wheeling about it `wheel` and the other way (`0x004DC420`, `0x004DC4E8`).
const vulcan_look = struct {
    const across: f32 = 50;
    const up: f32 = 12;
    const wheel: f32 = 0.1;
    const wheel_back: f32 = -0.1;
};

/// The Turret Lasers': its rings take the shot texture's corner, the columns of `ring_columns`, the
/// rows of `friendly_ring_rows` for a friendly shot's (`0x004DC8A0`, `0x004DC408`), and of
/// `hostile_ring_rows` for a hostile one's (`0x004DC89C`, `0x004DC404`).
const lasers_look = struct {
    const ring_columns: [2]f32 = .{ 0.875, 1 };
    const friendly_ring_rows: [2]f32 = .{ 0.375, 0.5 };
    const hostile_ring_rows: [2]f32 = .{ 0.875, 1 };
};

/// The Huge Guns': the Allied's and the Coalition's light, as bright as `intensity` and of
/// `colour`; their glow over `sunlayer3`, `glow_half` across either way and of `glow_colour`, as
/// bright as `glow_shade` of what their colour has left (`0x004DC450`); and their shell's turn,
/// `spin` about X, Y and Z for each tick the mission has run (`0x004DC410`, `0x004DC4C0`,
/// `0x004DC420`).
const huge_look = struct {
    const Look = struct {
        intensity: f32,
        colour: [3]f32,
        glow_half: f32,
        glow_colour: [3]f32,
    };
    const allied: Look = .{ .intensity = 1, .colour = .{ 0.8, 0.8, 1 }, .glow_half = 5000, .glow_colour = .{ 0.2, 0.3, 0.3 } };
    const coalition: Look = .{ .intensity = 2, .colour = .{ 1, 0.5, 0.3 }, .glow_half = 7500, .glow_colour = .{ 0.6, 0.4, 0.1 } };
    const glow_shade: f32 = 0.15;
    const spin: Vector = .{ 0.8, 0.3, 0.1 };
};

/// `bullet_build` (`0x0047D9A0`): what a new shot of its type is drawn with. `turn` is the
/// muzzle's, which the first piece takes.
fn dress(bullet: *Bullet, looks: *const Looks, random: *libcmt.Rand, turn: math.Matrix) void {
    // Which set of shapes and textures a shot takes, and which half of the shot texture. The game
    // tests the side for the one and whether it is hostile for the other.
    const other = bullet.side != .friendly;
    const hostile = bullet.side == .hostile;
    const rows: [2]f32 = if (hostile) hostile_rows else friendly_rows;
    const span = gun_stats.atlas[bullet.kind.number()];
    const left = @as(f32, @floatFromInt(span[0])) / atlas_size;
    const right = @as(f32, @floatFromInt(span[0] + span[1])) / atlas_size;
    const quad = [4][2]f32{ .{ left, rows[1] }, .{ right, rows[1] }, .{ right, rows[0] }, .{ left, rows[0] } };
    for (0..max_corners / 4) |at| bullet.uv[at * 4 ..][0..4].* = quad;

    var pieces: [max_pieces]Piece = @splat(.{});
    const count: u8 = switch (bullet.kind) {
        .laser_cannon => one(&pieces, meshPiece(looks, .laser, shot_flags)),
        .pulse_cannon => pulse: {
            const image: Image = if (other) .pulse_other else .pulse;
            pieces[0] = flarePiece(looks, image, pulse_look.half, @splat(0));
            pieces[1] = flarePiece(looks, image, pulse_look.second_half, pulse_look.second_offset);
            // Thrown round the first at random: drawn roll, yaw, then pitch.
            const thrown = math.fromAngleVector(random.fractionVector(@splat(std.math.tau)));
            pieces[1].offset = math.transform(thrown, pieces[1].offset);
            break :pulse 2;
        },
        .messon_blaster => messon: {
            // Three bolts of different lengths, each off the axis and some way along it, at a
            // random turn about it.
            for ([_]Shape{ .messon_0, .messon_1, .messon_2 }, 1..) |shape, at| {
                const along = random.fraction() * messon_look.along;
                const angle = random.fraction() * std.math.tau;
                pieces[at] = .{
                    .drawn = meshPiece(looks, shape, shot_flags),
                    .offset = math.transform(math.fromAngles(0, 0, angle), .{ messon_look.off, 0, along }),
                };
            }
            break :messon 4;
        },
        .proton_cannon => one(&pieces, meshPiece(looks, .proton, faded_flags)),
        .gattling_lasers => gattling: {
            // Three Laser Cannon bolts off the axis, a third of a turn apart. **Improvement:** a
            // third of `std.math.tau`, where the game multiplies by its rounded third of a turn
            // (`0x004DC8A4`).
            for (1..4) |at| {
                const angle = @as(f32, @floatFromInt(at - 1)) * std.math.tau / 3;
                pieces[at] = .{
                    .drawn = meshPiece(looks, .laser, shot_flags),
                    .offset = math.transform(math.fromAngles(0, 0, angle), .{ gattling_look.off, 0, 0 }),
                };
            }
            break :gattling 4;
        },
        .tachyon_cannon => tachyon: {
            const flags: srapiext.ObjectFlags = .{ .not_culled = true, .baked_object = true };
            pieces[0] = .{ .drawn = meshPiece(looks, .tachyon_star, flags) };
            pieces[1] = .{ .drawn = meshPiece(looks, .tachyon_square, flags), .offset = tachyon_look.square_offset };
            break :tachyon 2;
        },
        .neutron_particle_gun => one(&pieces, meshPiece(looks, .neutron, faded_flags)),
        .collapser_guns => collapser: {
            const image: Image = if (other) .collapser_other else .collapser;
            for ([_]f32{ -collapser_look.off, collapser_look.off }, 1..) |x, at| pieces[at] = flarePiece(looks, image, collapser_look.half, .{ x, 0, 0 });
            break :collapser 3;
        },
        .gattling_plasma_cannon => plasma: {
            // Four bolts of different lengths, some way along the axis and off it, at a random turn
            // about it.
            for ([_]Shape{ .gattling_plasma_0, .gattling_plasma_1, .gattling_plasma_2, .gattling_plasma_3 }, 1..) |shape, at| {
                const along = random.fraction() * plasma_look.along;
                const off = random.fraction() * plasma_look.off_range + plasma_look.off_least;
                const angle = random.fraction() * std.math.tau;
                pieces[at] = .{
                    .drawn = meshPiece(looks, shape, shot_flags),
                    .offset = math.transform(math.fromAngles(0, 0, angle), .{ off, 0, along }),
                };
            }
            break :plasma 5;
        },
        .vulcan_battery => vulcan: {
            const x = vulcan_look.across;
            const y = vulcan_look.up;
            for ([_]Vector{ .{ -x, -y, 0 }, .{ x, -y, 0 }, .{ -x, y, 0 }, .{ x, y, 0 } }, 1..) |offset, at| {
                pieces[at] = .{ .drawn = meshPiece(looks, .vulcan, shot_flags), .offset = offset };
            }
            break :vulcan 5;
        },
        // The game turns its bolt an eighth of a turn about the flight here, and `bullet_place`
        // then gives it the muzzle's turn in place of it, so it is drawn unturned.
        .nova_cannon => one(&pieces, meshPiece(looks, .nova, .{ .not_culled = true, .own_first = true, .owns_mesh = true })),
        .turret_flak => flak: {
            if (looks.shell == null) break :flak 0;
            const shell: *const [1]srapiext.Level = &looks.shell.?;
            break :flak one(&pieces, .{ .mesh = .{
                .flags = .{ .lit = true },
                .position = @splat(0),
                .radius = shell[0].mesh.radius,
                .levels = shell,
            } });
        },
        .turret_lasers => lasers: {
            // Its rings take the shot texture's corner, a friendly shot's or a hostile one's.
            const columns = lasers_look.ring_columns;
            const ring_rows = if (hostile) lasers_look.hostile_ring_rows else lasers_look.friendly_ring_rows;
            const ring = [4][2]f32{ .{ columns[0], ring_rows[1] }, .{ columns[1], ring_rows[1] }, .{ columns[1], ring_rows[0] }, .{ columns[0], ring_rows[0] } };
            bullet.uv[8..12].* = ring;
            bullet.uv[12..16].* = ring;
            break :lasers one(&pieces, meshPiece(looks, if (other) .turret_lasers_other else .turret_lasers, faded_flags));
        },
        .allied_huge_gun, .coalition_huge_gun => huge: {
            const allied = bullet.kind == .allied_huge_gun;
            const look = if (allied) huge_look.allied else huge_look.coalition;
            // Each of its squares takes the whole texture.
            for (0..3) |at| bullet.uv[at * 4 ..][0..4].* = .{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
            pieces[1] = .{ .drawn = meshPiece(looks, if (allied) .allied_huge else .coalition_huge, faded_flags) };
            pieces[2] = .{ .drawn = .{ .light = .{
                .mask = 0,
                .intensity = look.intensity,
                .colour = look.colour,
                .kind = .{ .point = .{ .position = @splat(0), .range = huge_light_range } },
            } } };
            pieces[3] = flarePiece(looks, .sun, look.glow_half, @splat(0));
            pieces[3].sprite[0].colour = look.glow_colour;
            break :huge 4;
        },
    };
    // The first piece stands at the muzzle, turned as it is (`bullet_place`).
    pieces[0].turn = turn;
    bullet.pieces = pieces;
    bullet.piece_count = count;
}

/// Makes `drawn` a shot's one piece.
fn one(pieces: *[max_pieces]Piece, drawn: Piece.Drawn) u8 {
    pieces[0] = .{ .drawn = drawn };
    return 1;
}

/// How far a Huge Gun's light reaches (`bullet_build`).
const huge_light_range: f32 = 60000;

/// The work `bullets_frame` does for each type before the shot is tested: its colours by the life
/// it has left, and the turns of the types that spin or wheel.
fn animate(bullet: *Bullet, clock: *const Clock, record: Gun, random: *libcmt.Rand) void {
    const left = fade(bullet, clock, record);
    const friendly = bullet.side == .friendly;
    const ticks: f32 = @floatFromInt(clock.frame_duration);
    const pieces = &bullet.pieces;
    switch (bullet.kind) {
        .pulse_cannon => {
            pieces[0].sprite[0].colour = if (friendly) .{ 0.5, left, 1 } else @splat(left);
            pieces[1].sprite[0].colour = if (friendly) .{ 0, left, 1 } else @splat(left);
            const wheel = pulse_look.wheel;
            pieces[1].offset = math.transform(math.fromAngles(ticks * wheel[0], ticks * wheel[1], ticks * wheel[2]), pieces[1].offset);
        },
        .proton_cannon => paint(&pieces[0], if (friendly) .{ left, left, 1 } else @splat(left)),
        .tachyon_cannon => {
            // Each blade bright down its middle and dark at its ends.
            for (0..3) |at| {
                const corners = pieces[0].colours[at * blade_corners ..][0..blade_corners];
                for (corners, [_]f32{ 0, left, left, 0 }) |*colour, shade| colour.* = .{ shade, shade, shade, colour[3] };
            }
            paint(&pieces[1], @splat(left));
            pieces[0].turn = math.turned(pieces[0].turn, .z, ticks * spin_rate);
        },
        .gattling_lasers => pieces[0].turn = math.turned(pieces[0].turn, .z, ticks * spin_rate),
        .neutron_particle_gun => {
            paint(&pieces[0], @splat(left * neutron_look.shade));
            pieces[0].turn = math.turned(pieces[0].turn, .z, random.fraction());
        },
        .collapser_guns => {
            for (pieces[1..3]) |*piece| piece.sprite[0].colour = @splat(left);
            pieces[0].turn = math.turned(pieces[0].turn, .z, ticks * collapser_look.spin);
        },
        .vulcan_battery => {
            // The two pairs wheel about the flight in opposite ways.
            for (pieces[1..5], [_]f32{ vulcan_look.wheel, vulcan_look.wheel, vulcan_look.wheel_back, vulcan_look.wheel_back }) |*piece, rate| {
                piece.offset = math.transform(math.fromAngles(0, 0, ticks * rate), piece.offset);
            }
        },
        .allied_huge_gun, .coalition_huge_gun => {
            const since: f32 = @floatFromInt(clock.frame_start);
            const spin = huge_look.spin;
            pieces[1].turn = math.fromAngles(since * spin[0], since * spin[1], since * spin[2]);
            paint(&pieces[1], @splat(left));
            switch (pieces[2].drawn) {
                .light => |*light| light.colour = @splat(left),
                else => {},
            }
            pieces[3].sprite[0].colour = @splat(left * huge_look.glow_shade);
        },
        .laser_cannon, .messon_blaster, .gattling_plasma_cannon, .nova_cannon, .turret_flak, .turret_lasers => {},
    }
}

/// How fast the Tachyon Cannon's shot and the Gattling Lasers' spin about their flight, a turn a
/// tick (`0x004DC4DC`).
const spin_rate: f32 = 0.4;

/// Gives every corner of a piece's mesh one colour, keeping each corner's alpha.
fn paint(piece: *Piece, colour: [3]f32) void {
    for (&piece.colours) |*corner| corner.* = .{ colour[0], colour[1], colour[2], corner[3] };
}

/// Places each of a shot's pieces: the first where the shot is drawn, the rest on it.
fn placePieces(bullet: *Bullet) void {
    const first: math.Place = .{ .position = bullet.place, .orientation = bullet.pieces[0].turn };
    for (bullet.pieces[0..bullet.piece_count], 0..) |*piece, at| {
        const position = if (at == 0) first.position else first.point(piece.offset);
        const turn = if (at == 0) first.orientation else math.product(first.orientation, piece.turn);
        switch (piece.drawn) {
            .frame => {},
            .mesh => |*mesh| {
                mesh.position = position;
                mesh.orientation = turn;
            },
            .sprites => |*set| set.position = position,
            .light => |*light| light.kind.point.position = position,
        }
    }
}

/// The texels across the shot texture, which the spans are counted in (`0x004DC818` is one over
/// it).
const atlas_size: f32 = 256;

/// The two halves of the shot texture, top and bottom, as `bullet_build` takes them: each stops a
/// texel short of the half it ends at.
const friendly_rows: [2]f32 = .{ 0, 127.0 / atlas_size };
const hostile_rows: [2]f32 = .{ 0.5, 255.0 / atlas_size };

/// What a shot's colour has left: all of it as it leaves the muzzle, none at the end of its life.
fn fade(bullet: *const Bullet, clock: *const Clock, record: Gun) f32 {
    return @max(1 - particles.through(clock.frame_start, bullet.fired_at, record.lifetime), 0);
}

/// The shots in flight, added to the world's layer as `bullets_frame` adds them once it has placed
/// them, with the lights they cast where the renderer is a hardware one.
///
/// The game gives a shot no light at all on its software renderer (`sr + 0x1AC`); OpenReliant gives
/// it one and leaves it out here, which shows the same.
pub fn drawBullets(gpa: Allocator, scene: *srcore.Scene, bullets: *Bullets, lights: bool) Allocator.Error!void {
    for (&bullets.pool) |*bullet| {
        if (!bullet.live) continue;
        for (bullet.pieces[0..bullet.piece_count]) |*piece| {
            switch (piece.drawn) {
                .frame => {},
                .mesh => |*mesh| {
                    // What the object points into lives in the shot's own record.
                    if (mesh.flags.own_first) mesh.own_uv[0] = &bullet.uv;
                    if (mesh.flags.baked_object) mesh.baked = &piece.colours;
                    try xtrabits.sceneAdd(gpa, scene, .{ .mesh = mesh }, .world);
                },
                .sprites => |*set| {
                    set.sprites = &piece.sprite;
                    try xtrabits.sceneAdd(gpa, scene, .{ .sprites = set }, .world);
                },
                .light => |*light| if (lights) try xtrabits.sceneAdd(gpa, scene, .{ .light = light }, .world),
            }
        }
        if (!lights) continue;
        if (bullet.light) |*light| {
            light.kind.point.position = bullet.place;
            try xtrabits.sceneAdd(gpa, scene, .{ .light = light }, .world);
        }
    }
    try bullets.beams.draw(gpa, scene);
}

/// A texture table holding every image the shots are drawn with, and the looks built over it, for
/// the tests that draw shots.
const test_looks = struct {
    const Fixture = struct {
        textures: *@import("../surrender/surrenderlib/srtexture.zig").testing.Textures,
        looks: *Looks,

        fn init(gpa: Allocator) !Fixture {
            // The texture cache keeps each file's name, without the directory the game names it by.
            const shots = std.enums.values(Image);
            var names: [shots.len + nova.images.len][]const u8 = undefined;
            for (names[0..shots.len], shots) |*name, image| name.* = std.fs.path.basenameWindows(image.name());
            names[shots.len..].* = nova.images;
            const textures = try @import("../surrender/surrenderlib/srtexture.zig").testing.Textures.init(gpa, &names);
            errdefer textures.deinit(gpa);
            return .{ .textures = textures, .looks = try .create(gpa, &textures.table) };
        }

        fn deinit(built: Fixture, gpa: Allocator) void {
            built.looks.destroy(gpa);
            built.textures.deinit(gpa);
        }
    };
};

test Looks {
    const gpa = std.testing.allocator;
    const built: test_looks.Fixture = try .init(gpa);
    defer built.deinit(gpa);
    const shapes = &built.looks.shapes;

    // A bolt: two quads crossed near to, as long as its record says, and one far off.
    const laser = shapes.getPtrConst(.laser);
    try std.testing.expectEqual(2, laser.count);
    try std.testing.expectEqual(8, laser.meshes[0].positions.len);
    try std.testing.expectEqual(4, laser.meshes[1].positions.len);
    try std.testing.expectEqual(@as(Vector, .{ -30, 0, 1200 }), laser.meshes[0].positions[6]);
    try std.testing.expectEqual(15000, laser.levels[0].until);
    // The Messon Blaster's bolts grow by 400.
    try std.testing.expectEqual(@as(Vector, .{ 0, 5, 440 }), shapes.getPtrConst(.messon_1).meshes[0].positions[3]);
    // The Turret Lasers' has its two rings, where the set puts the first.
    const rings = shapes.getPtrConst(.turret_lasers);
    try std.testing.expectEqual(16, rings.meshes[0].positions.len);
    try std.testing.expectEqual(2400 * 0.6, rings.meshes[0].positions[8][2]);
    try std.testing.expectEqual(2400 * 0.15, shapes.getPtrConst(.turret_lasers_other).meshes[0].positions[8][2]);
    // The Tachyon Cannon's star has three blades through the axis, and its square two triangles.
    const star = shapes.getPtrConst(.tachyon_star);
    try std.testing.expectEqual(1, star.count);
    try std.testing.expectEqual(12, star.meshes[0].positions.len);
    try std.testing.expectEqual(@as(Vector, .{ 0, -60, -800 }), star.meshes[0].positions[0]);
    const square = shapes.getPtrConst(.tachyon_square);
    try std.testing.expectEqual(6, square.meshes[0].indices.len);
    try std.testing.expectEqual([2]f32{ 0.875, 0.375 }, square.meshes[0].uv[0].?[0]);
    // A Huge Gun's three squares, drawn at every distance.
    const huge = shapes.getPtrConst(.coalition_huge);
    try std.testing.expectEqual(12, huge.meshes[0].positions.len);
    try std.testing.expectEqual(std.math.inf(f32), huge.levels[0].until);
    // Without the shell's model, a Turret Flak shot is not drawn.
    try std.testing.expectEqual(null, built.looks.shell);
    // Its shell is loaded as a mission starts, its type counted as used so that the types no
    // object uses, let go between missions, keep it.
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(gpa, &random);
    defer all.destroy();
    built.looks.loadShell(all, create.testing.no_models);
    try std.testing.expectEqual(null, built.looks.shell);
    try std.testing.expectEqual(1, all.types[shell_type].objects);
}

test dress {
    const gpa = std.testing.allocator;
    const built: test_looks.Fixture = try .init(gpa);
    defer built.deinit(gpa);
    var random: libcmt.Rand = .{};

    // What each gun type's shot is drawn with: how many pieces, and what the first two are.
    const Expect = struct { kind: GunType, count: u8, first: std.meta.Tag(Piece.Drawn), second: ?std.meta.Tag(Piece.Drawn) = null };
    const expected = [_]Expect{
        .{ .kind = .laser_cannon, .count = 1, .first = .mesh },
        .{ .kind = .pulse_cannon, .count = 2, .first = .sprites, .second = .sprites },
        .{ .kind = .messon_blaster, .count = 4, .first = .frame, .second = .mesh },
        .{ .kind = .proton_cannon, .count = 1, .first = .mesh },
        .{ .kind = .gattling_lasers, .count = 4, .first = .frame, .second = .mesh },
        .{ .kind = .tachyon_cannon, .count = 2, .first = .mesh, .second = .mesh },
        .{ .kind = .neutron_particle_gun, .count = 1, .first = .mesh },
        .{ .kind = .collapser_guns, .count = 3, .first = .frame, .second = .sprites },
        .{ .kind = .gattling_plasma_cannon, .count = 5, .first = .frame, .second = .mesh },
        .{ .kind = .vulcan_battery, .count = 5, .first = .frame, .second = .mesh },
        .{ .kind = .nova_cannon, .count = 1, .first = .mesh },
        .{ .kind = .turret_flak, .count = 0, .first = .frame },
        .{ .kind = .turret_lasers, .count = 1, .first = .mesh },
        .{ .kind = .allied_huge_gun, .count = 4, .first = .frame, .second = .mesh },
        .{ .kind = .coalition_huge_gun, .count = 4, .first = .frame, .second = .mesh },
    };
    comptime std.debug.assert(expected.len == std.enums.values(GunType).len);
    for (expected) |want| {
        var bullet: Bullet = .{ .kind = want.kind, .side = .friendly };
        dress(&bullet, built.looks, &random, math.identity);
        try std.testing.expectEqual(want.count, bullet.piece_count);
        if (want.count == 0) continue;
        try std.testing.expectEqual(want.first, std.meta.activeTag(bullet.pieces[0].drawn));
        if (want.second) |second| try std.testing.expectEqual(second, std.meta.activeTag(bullet.pieces[1].drawn));
    }

    // The Gattling Lasers' three bolts stand 30 off the axis, a third of a turn apart.
    var gattling: Bullet = .{ .kind = .gattling_lasers };
    dress(&gattling, built.looks, &random, math.identity);
    try std.testing.expectApproxEqAbs(30, math.length(gattling.pieces[2].offset), 1e-3);
    try std.testing.expectApproxEqAbs(-15, gattling.pieces[2].offset[0], 1e-3);
    // A Huge Gun's third piece is its light.
    var huge: Bullet = .{ .kind = .allied_huge_gun };
    dress(&huge, built.looks, &random, math.identity);
    try std.testing.expectEqual(huge_light_range, huge.pieces[2].drawn.light.kind.point.range);
    // A friendly shot takes the top half of the shot texture, a hostile one the bottom.
    var hostile: Bullet = .{ .kind = .laser_cannon, .side = .hostile };
    dress(&hostile, built.looks, &random, math.identity);
    try std.testing.expectEqual([2]f32{ 0, 255.0 / 256.0 }, hostile.uv[0]);
    try std.testing.expectEqual([2]f32{ 32.0 / 256.0, 0.5 }, hostile.uv[2]);
}

test "a shot's pieces wheel, spin and fade as it flies" {
    const gpa = std.testing.allocator;
    const built: test_looks.Fixture = try .init(gpa);
    defer built.deinit(gpa);
    var random: libcmt.Rand = .{};
    var clock: Clock = .{ .frame_start = 150, .frame_duration = 5 };
    var record = std.mem.zeroes(Gun);
    record.lifetime = 100;

    // Halfway through its life, a Collapser Guns' flares are at half their brightness, and its
    // frame has spun a tick's worth times the frame's ticks.
    var collapser: Bullet = .{ .kind = .collapser_guns, .fired_at = 100 };
    dress(&collapser, built.looks, &random, math.identity);
    animate(&collapser, &clock, record, &random);
    try std.testing.expectEqual([3]f32{ 0.5, 0.5, 0.5 }, collapser.pieces[1].sprite[0].colour);
    try std.testing.expectEqual(math.turned(math.identity, .z, 5 * 0.2), collapser.pieces[0].turn);

    // A Vulcan Battery's two pairs wheel about the flight in opposite ways.
    var vulcan: Bullet = .{ .kind = .vulcan_battery, .fired_at = 100 };
    dress(&vulcan, built.looks, &random, math.identity);
    const before = vulcan.pieces[1].offset;
    animate(&vulcan, &clock, record, &random);
    const turned_first = std.math.atan2(vulcan.pieces[1].offset[1], vulcan.pieces[1].offset[0]) - std.math.atan2(before[1], before[0]);
    const turned_third = std.math.atan2(vulcan.pieces[3].offset[1], vulcan.pieces[3].offset[0]) - std.math.atan2(@as(f32, 12), @as(f32, -50));
    try std.testing.expect(turned_first * turned_third < 0);

    // A Tachyon Cannon's blades are bright down their middles and dark at their ends.
    var tachyon: Bullet = .{ .kind = .tachyon_cannon, .fired_at = 100 };
    dress(&tachyon, built.looks, &random, math.identity);
    animate(&tachyon, &clock, record, &random);
    try std.testing.expectEqual(0, tachyon.pieces[0].colours[0][0]);
    try std.testing.expectEqual(0.5, tachyon.pieces[0].colours[1][0]);

    // Placed, each piece hangs off the first, turned with it.
    tachyon.place = .{ 0, 0, 1000 };
    tachyon.pieces[0].turn = math.fromAngles(0, std.math.pi / 2.0, 0);
    placePieces(&tachyon);
    const square = tachyon.pieces[1].drawn.mesh.position;
    try std.testing.expectApproxEqAbs(1000, square[2], 1e-3);
    try std.testing.expectApproxEqAbs(100, @abs(square[0]), 1e-3);
}

test drawBullets {
    const gpa = std.testing.allocator;
    const built: test_looks.Fixture = try .init(gpa);
    defer built.deinit(gpa);
    var random: libcmt.Rand = .{};
    var bullets: Bullets = .{ .looks = built.looks };

    // A Huge Gun's shot: its mesh and its glow drawn, its light cast.
    const bullet = &bullets.pool[0];
    bullet.* = .{ .live = true, .kind = .coalition_huge_gun };
    dress(bullet, built.looks, &random, math.identity);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try drawBullets(gpa, &scene, &bullets, true);
    try std.testing.expectEqual(2, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(1, scene.lights.items.len);
    // Its mesh points at the shot's own coordinates and colours.
    const mesh = &bullet.pieces[1].drawn.mesh;
    try std.testing.expectEqual(@as(?[][2]f32, &bullet.uv), mesh.own_uv[0]);
    try std.testing.expect(mesh.baked.?.ptr == &bullet.pieces[1].colours);
    // Without a hardware renderer, it lights nothing.
    scene.clear();
    try drawBullets(gpa, &scene, &bullets, false);
    try std.testing.expectEqual(0, scene.lights.items.len);
}

test {
    std.testing.refAllDecls(@This());
}

const Allocator = std.mem.Allocator;
const ai = @import("ai.zig");
const cloak = @import("cloak.zig");
const collision = @import("collision.zig");
const explode = @import("explode.zig");
const shield = @import("shield.zig");
const shieldfx = @import("shieldfx.zig");
const sparks = @import("sparks.zig");
const create = @import("create.zig");
const ShipTypes = create.Types;
const Objects = create.Objects;
const formats = @import("../../formats/stats.zig");
const gameobj = @import("gameobj.zig");
const gun_stats = @import("guns/stats.zig");
const hooks = @import("../hooks.zig");
const hud = @import("hud.zig");
const libcmt = @import("../libcmt.zig");
const matmanager = @import("matmanager.zig");
const input = @import("../input.zig");
const objects = @import("objects.zig");
const particles = @import("particles.zig");
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const shp = @import("../../formats/shp.zig");
const sound3d = @import("sound3d.zig");
const firstFreeBy = @import("table.zig").firstFreeBy;
const srapi = @import("../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const xtrabits = @import("xtrabits.zig");
