//! `C:\lancer\interface\loadout\loadout.cpp`'s tables: the ships and missiles the loadout offers,
//! the rows of figures its panels show, what the campaign's tier and the pilot's rank open, the
//! colours of its text, and where its scene's objects stand. A string is an id for
//! `language.Language.string`; a model is a file name.

const std = @import("std");
const assert = std.debug.assert;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const gameflow = @import("../../game/gameflow.zig");
const hud = @import("../../game/hud.zig");
const missiles_mod = @import("../../game/missiles.zig");
const additions = @import("../../game/additions.zig");
const create = @import("../../game/create.zig");
const guns = @import("../../game/guns.zig");
const objects = @import("../../game/objects.zig");
const shp = @import("../../../formats/shp.zig");

/// A ship the loadout offers: its record (`loadout_ships`, `0x004EC080`, `0x22C` bytes a ship) and
/// its scale. A ship's index is its ship type.
pub const Ship = struct {
    /// The string that names it (`+0x00`).
    name: u16,
    /// Its model (`+0x02`, 250 bytes).
    model: []const u8,
    /// The model the guns page shows of it (`+0xFC`, 250 bytes).
    guns_model: []const u8,
    /// `+0x1F6`.
    class: Class,
    /// `+0x1F7`.
    access: Access,
    /// The last of its rows (`+0x214`), after the seven figures `loadout_load` works out
    /// (`+0x1F8`, `ShipFigures`).
    crew: i32,
    /// `+0x218`.
    specials: Specials,
    /// Its guns, at most `gun_slots` (`+0x21C`, the list ending at a gun of -1).
    guns: []const Mount,
    /// The scale the hologram shows its model at, from a table of its own (`0x004EA2D8`).
    scale: f32,
};

/// A ship's class, as its stats panel names it.
pub const Class = enum(u8) {
    light = 1,
    light_medium = 2,
    medium = 3,
    heavy = 4,
    advanced_heavy = 5,
    prototype_medium = 6,
    prototype_light = 7,

    /// The string that names it (`loadout_draw_stats`, `0x0044503F`). The game draws no class
    /// for a value past these, which no ship has.
    pub fn string(class: Class) u16 {
        return switch (class) {
            .light => 0x223,
            .light_medium => 0x224,
            .medium => 0x225,
            .heavy => 0x226,
            .advanced_heavy => 0x227,
            .prototype_medium => 0x228,
            .prototype_light => 0x553,
        };
    }
};

/// The access a ship's stats panel names.
pub const Access = enum(u8) {
    bronze = 1,
    silver = 2,
    gold = 3,
    platinum = 4,

    /// The string that names it (`loadout_draw_stats`, `0x00445107`). The game draws no access
    /// for a value past these, which no ship has.
    pub fn string(access: Access) u16 {
        return switch (access) {
            .bronze => 0x229,
            .silver => 0x22A,
            .gold => 0x22B,
            .platinum => 0x22C,
        };
    }
};

/// What else a ship has, a bit each, in the order `special_names` names them.
pub const Specials = packed struct(u32) {
    reverse_thrust: bool = false,
    constant_ecm: bool = false,
    tractor_beam: bool = false,
    nova_cannon: bool = false,
    spectral_shields: bool = false,
    blind_fire: bool = false,
    cloaking_device: bool = false,
    super_charge: bool = false,
    _unused: u24 = 0,

    /// Whether it has the special of `bit`.
    pub fn has(specials: Specials, bit: u5) bool {
        return @as(u32, @bitCast(specials)) >> bit & 1 != 0;
    }
};

/// The strings that name the specials, bit by bit (`loadout_special_names`, `0x004EDA90`).
pub const special_names = [_]u16{ 0x1EF, 0x1F0, 0x1F1, 0x1F2, 0x1F3, 0x1F4, 0x1F5, 0x1F6 };

comptime {
    for (@typeInfo(Specials).@"struct".fields[0..special_names.len], 0..) |field, bit| {
        assert(@bitOffsetOf(Specials, field.name) == bit);
        assert(field.type == bool);
    }
}

/// Guns of one kind on a ship (`+0x21C`, two `i16` a slot): the string that names the gun, which
/// `gunDescription` goes by too, and how many the ship has.
pub const Mount = struct {
    gun: u16,
    count: u16,
};

/// The slots a ship's record has for its guns.
pub const gun_slots = 4;

pub const ship_count = 12;

/// A ship the loadout offers: its ship type, and its record (`modRecord` for a mod's).
pub const Offer = struct {
    ship_type: create.TypeIndex,
    record: Ship,

    /// Fills in what a mod's ship type without a base takes from its model, once the loadout has
    /// loaded it (`withModel`); every other ship's record stays as it is.
    pub fn fitModel(offer: *Offer, model: *const shp.Model, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        const mod = additions.ships.get(offer.ship_type) orelse return;
        if (mod.based) return;
        offer.record = try withModel(offer.record, mod.extra.gun, model, gpa);
    }
};

/// The ship a saved game keeps for the loadout's chosen `ship_type` (`campaign_saved_ship`): a
/// mod's ship type as its base, so that the save stays one the original reads.
pub fn savedShip(ship_type: create.TypeIndex) u8 {
    const mod = additions.ships.get(ship_type) orelse return @intCast(ship_type);
    return @intCast(@backingInt(mod.base));
}

/// Whether a mod's ship type shows a gun model of its own on the guns page, in its own model's
/// units: the one it gives, or without a base its own model. One with a base and no gun model of
/// its own shows its base's.
pub fn ownGunsModel(mod: *const additions.ships.Added) bool {
    return !mod.based or mod.extra.guns_model != null;
}

/// The ships the loadout offers, into `buffer`: the game's first `game_count`, then the mods' ship
/// types the player can fly, those based on one of the twelve or on none, that the campaign's
/// `tier` offers, from the tier a mod gives, else from its start. Returns them, and how many of
/// the mods' the arc had no room for.
///
/// **Improvement:** the original offers its own twelve alone.
pub fn offers(tier: u2, game_count: usize, buffer: *[arc_slot_count]Offer) struct { []Offer, usize } {
    var count: usize = 0;
    for (ships[0..game_count], 0..) |record, index| {
        buffer[count] = .{ .ship_type = @intCast(index), .record = record };
        count += 1;
    }
    var left_out: usize = 0;
    for (additions.ships.all(), additions.ships.first..) |mod, number| {
        const base: usize = @backingInt(mod.base);
        if (base >= ship_count) continue;
        if (tier < mod.extra.tier orelse 0) continue;
        if (count == arc_slot_count) {
            left_out += 1;
            continue;
        }
        buffer[count] = .{ .ship_type = @intCast(number), .record = modRecord(&mod) };
        count += 1;
    }
    return .{ buffer[0..count], left_out };
}

/// The record of a mod's ship type the player can fly: its own name and model; its class, access
/// and crew where its manifest gives them; its blind fire and spectral shields as it is fitted
/// (`main.playerShip`); and the rest its base's. One without a base takes only its template's
/// scale: it has `additions.ShipExtra`'s defaults for the figures, no specials, and its own model
/// on the guns page, with its guns and the rest of its specials from its model (`Offer.fitModel`).
/// A gun model the type gives (`GunsModel`) shows on the guns page in place of either.
pub fn modRecord(mod: *const additions.ships.Added) Ship {
    var record = ships[@backingInt(mod.base)];
    if (mod.label_string) |name| record.name = name;
    record.model = mod.extra.model;
    if (!mod.based) {
        record.guns_model = mod.extra.model;
        record.class = additions.ShipExtra.default_class;
        record.access = additions.ShipExtra.default_access;
        record.crew = additions.ShipExtra.default_crew;
        record.specials = .{};
        record.guns = &.{};
    }
    if (mod.extra.guns_model) |own| record.guns_model = own;
    if (mod.extra.class) |own| record.class = own;
    if (mod.extra.access) |own| record.access = own;
    if (mod.extra.crew) |own| record.crew = own;
    if (mod.extra.blind_fire) |own| record.specials.blind_fire = own;
    if (mod.extra.spectral_shields) |own| record.specials.spectral_shields = own;
    return record;
}

/// `record` with what `model` gives it, for a mod's ship type without a base: its guns, each kind
/// its muzzles fire with how many, or every muzzle firing `gun` where the type gives one, at most
/// `gun_slots` kinds; and among its specials, the Nova Cannon where a muzzle fires one, the cloak
/// where the model can cloak, and reverse thrust where it has an engine glow that burns forward
/// (`objects.Model.Glow.burnsForward`).
pub fn withModel(record: Ship, gun: ?guns.GunType, model: *const shp.Model, gpa: std.mem.Allocator) std.mem.Allocator.Error!Ship {
    var made = record;
    var mounts: std.ArrayList(Mount) = .empty;
    errdefer mounts.deinit(gpa);
    for (model.parts) |part| for (part.attachments) |*attachment| switch (attachment.kind) {
        .gun_muzzle => {
            const fired = gun orelse guns.GunType.fromNumber(attachment.gun_type);
            if (fired.base() == .nova_cannon) made.specials.nova_cannon = true;
            const name = gunString(fired) orelse continue;
            for (mounts.items) |*mount| {
                if (mount.gun != name) continue;
                mount.count += 1;
                break;
            } else if (mounts.items.len < gun_slots) try mounts.append(gpa, .{ .gun = name, .count = 1 });
        },
        .engine_glow => if (objects.Model.Glow.burnsForward(attachment)) {
            made.specials.reverse_thrust = true;
        },
        else => {},
    };
    made.guns = try mounts.toOwnedSlice(gpa);
    if (model.header.flags.cloak) made.specials.cloaking_device = true;
    return made;
}

/// The string the loadout names `gun` by: a mod's own name, else its base's string, which the
/// guns page also finds its description by (`gunDescription`). Null for the turrets' guns: the
/// game's records name a fighter's rear turret by strings of their own (`first_rear_turret` on).
pub fn gunString(gun: guns.GunType) ?u16 {
    if (gun.added()) |mod| if (mod.label_string) |name| return name;
    // The strings name the fighters' guns in this order, from `first_described_gun`.
    const order: u16 = switch (gun.base()) {
        .laser_cannon => 0,
        .pulse_cannon => 1,
        .messon_blaster => 2,
        .proton_cannon => 3,
        .gattling_lasers => 4,
        .tachyon_cannon => 5,
        .neutron_particle_gun => 6,
        .nova_cannon => 7,
        .collapser_guns => 8,
        .gattling_plasma_cannon => 9,
        .vulcan_battery => 10,
        .turret_flak, .turret_lasers, .allied_huge_gun, .coalition_huge_gun => return null,
    };
    return first_described_gun + order;
}

/// `loadout_ships` (`0x004EC080`), with each ship's scale (`0x004EA2D8`).
pub const ships = [ship_count]Ship{
    .{
        .name = 0x1F7,
        .model = "USLF_prd.SHP",
        .guns_model = "predator_gun.SHP",
        .class = .light,
        .access = .bronze,
        .crew = 2,
        .specials = .{ .blind_fire = true },
        .guns = &.{ .{ .gun = 0x23B, .count = 2 }, .{ .gun = 0x54E, .count = 1 } },
        .scale = 0.009,
    },
    .{
        .name = 0x1F8,
        .model = "JLF_Nagi.SHP",
        .guns_model = "naginata_gun.shp",
        .class = .light,
        .access = .bronze,
        .crew = 2,
        .specials = .{ .spectral_shields = true },
        .guns = &.{.{ .gun = 0x239, .count = 2 }},
        .scale = 0.01,
    },
    .{
        .name = 0x1F9,
        .model = "German_grendal.SHP",
        .guns_model = "grendal_gun.shp",
        .class = .medium,
        .access = .bronze,
        .crew = 3,
        .specials = .{},
        .guns = &.{ .{ .gun = 0x241, .count = 2 }, .{ .gun = 0x238, .count = 2 }, .{ .gun = 0x54F, .count = 1 } },
        .scale = 0.008,
    },
    .{
        .name = 0x1FA,
        .model = "British_Crusader.SHP",
        .guns_model = "crusader_gun.SHP",
        .class = .light,
        .access = .bronze,
        .crew = 2,
        .specials = .{ .spectral_shields = true },
        .guns = &.{ .{ .gun = 0x23C, .count = 2 }, .{ .gun = 0x54E, .count = 1 } },
        .scale = 0.009,
    },
    .{
        .name = 0x1FB,
        .model = "USA_Coyote.SHP",
        .guns_model = "coyote_gun.shp",
        .class = .light_medium,
        .access = .silver,
        .crew = 2,
        .specials = .{ .blind_fire = true },
        .guns = &.{ .{ .gun = 0x23B, .count = 2 }, .{ .gun = 0x54E, .count = 1 } },
        .scale = 0.0084,
    },
    .{
        .name = 0x1FC,
        .model = "French_Mirage.SHP",
        .guns_model = "mirage_gun.SHP",
        .class = .medium,
        .access = .silver,
        .crew = 2,
        .specials = .{},
        .guns = &.{ .{ .gun = 0x23E, .count = 2 }, .{ .gun = 0x23A, .count = 2 } },
        .scale = 0.01,
    },
    .{
        .name = 0x1FD,
        .model = "British_Tempest.SHP",
        .guns_model = "tempest_gun.shp",
        .class = .heavy,
        .access = .silver,
        .crew = 2,
        .specials = .{ .spectral_shields = true },
        .guns = &.{ .{ .gun = 0x23D, .count = 2 }, .{ .gun = 0x239, .count = 2 }, .{ .gun = 0x54F, .count = 1 } },
        .scale = 0.007,
    },
    .{
        .name = 0x1FE,
        .model = "USMF_Pat.SHP",
        .guns_model = "patriot_gun.shp",
        .class = .medium,
        .access = .gold,
        .crew = 2,
        .specials = .{ .blind_fire = true },
        .guns = &.{ .{ .gun = 0x23D, .count = 2 }, .{ .gun = 0x23B, .count = 2 } },
        .scale = 0.0067,
    },
    .{
        .name = 0x1FF,
        .model = "German_Wolverine.SHP",
        .guns_model = "wolverine_gun.shp",
        .class = .advanced_heavy,
        .access = .gold,
        .crew = 3,
        .specials = .{ .reverse_thrust = true },
        .guns = &.{ .{ .gun = 0x240, .count = 2 }, .{ .gun = 0x238, .count = 2 }, .{ .gun = 0x23D, .count = 1 }, .{ .gun = 0x54F, .count = 1 } },
        .scale = 0.006,
    },
    .{
        .name = 0x200,
        .model = "USHF_Reaper.SHP",
        .guns_model = "reaper_gun.shp",
        .class = .heavy,
        .access = .gold,
        .crew = 3,
        .specials = .{ .blind_fire = true },
        .guns = &.{ .{ .gun = 0x23C, .count = 2 }, .{ .gun = 0x242, .count = 2 }, .{ .gun = 0x551, .count = 1 } },
        .scale = 0.0071,
    },
    .{
        .name = 0x201,
        .model = "Jap_Shroud.SHP",
        .guns_model = "shroud_gun.shp",
        .class = .prototype_light,
        .access = .platinum,
        .crew = 2,
        .specials = .{ .reverse_thrust = true, .spectral_shields = true, .blind_fire = true, .cloaking_device = true },
        .guns = &.{.{ .gun = 0x23B, .count = 2 }},
        .scale = 0.006,
    },
    .{
        .name = 0x202,
        .model = "USPF_Phx.SHP",
        .guns_model = "phoenix_gun.shp",
        .class = .prototype_medium,
        .access = .platinum,
        .crew = 2,
        .specials = .{ .reverse_thrust = true, .nova_cannon = true, .blind_fire = true },
        .guns = &.{ .{ .gun = 0x23C, .count = 2 }, .{ .gun = 0x239, .count = 2 }, .{ .gun = 0x23F, .count = 1 }, .{ .gun = 0x552, .count = 1 } },
        .scale = 0.008,
    },
};

comptime {
    for (ships) |ship| assert(ship.guns.len <= gun_slots);
}

/// What the guns page says of a gun: five strings, which `guns_draw` (`0x00445490`) runs together
/// into a sentence (`%s%s%s%s%s`, `0x004EAE9C`).
pub const GunDescription = struct {
    power: u16,
    kind: u16,
    range: u16,
    rate: u16,
    /// The energy it drains, or null (-1) for none, which the sentence ends in `,` for
    /// (`0x004EAEA8`).
    drain: ?u16,
};

/// The first gun `gun_descriptions` describes.
pub const first_described_gun = 0x238;

/// The first of the rear turrets, which the guns page describes none of.
pub const first_rear_turret = 0x54E;

/// `loadout_gun_descriptions` (`0x004EE540`, ten bytes a gun): the guns from
/// `first_described_gun` on.
pub const gun_descriptions = [_]GunDescription{
    .{ .power = 0x243, .kind = 0x24F, .range = 0x246, .rate = 0x24B, .drain = 0x24C },
    .{ .power = 0x244, .kind = 0x24F, .range = 0x246, .rate = 0x24A, .drain = 0x24C },
    .{ .power = 0x244, .kind = 0x24F, .range = 0x247, .rate = 0x24A, .drain = 0x24D },
    .{ .power = 0x244, .kind = 0x24F, .range = 0x247, .rate = 0x249, .drain = 0x24D },
    .{ .power = 0x244, .kind = 0x24F, .range = 0x247, .rate = 0x24B, .drain = 0x24E },
    .{ .power = 0x245, .kind = 0x252, .range = 0x248, .rate = 0x249, .drain = 0x24E },
    .{ .power = 0x245, .kind = 0x252, .range = 0x247, .rate = 0x249, .drain = 0x24E },
    .{ .power = 0x245, .kind = 0x250, .range = 0x246, .rate = 0x249, .drain = 0x24E },
    .{ .power = 0x243, .kind = 0x251, .range = 0x247, .rate = 0x24A, .drain = null },
    .{ .power = 0x245, .kind = 0x251, .range = 0x247, .rate = 0x24B, .drain = null },
    .{ .power = 0x245, .kind = 0x251, .range = 0x248, .rate = 0x249, .drain = null },
};

/// The description of `gun`, where it has one: `guns_draw` looks one up for a gun below
/// `first_rear_turret` (`0x004455F6`), `(gun - first_described_gun) * 5` shorts into the table.
/// OpenReliant gives none to a gun the table doesn't reach either, where the game reads beside
/// it; no ship has one.
pub fn gunDescription(gun: u16) ?GunDescription {
    if (gun < first_described_gun or gun >= first_rear_turret) return null;
    const index = gun - first_described_gun;
    if (index >= gun_descriptions.len) return null;
    return gun_descriptions[index];
}

/// A missile the loadout offers, and its place in the loadout's missile tables: the missile type
/// of the same number (`missiles.Type`), but for the fuel pod, which is type 10. From
/// `missile_count` on, the missiles mods add (`additions.missiles`), in their order.
///
/// **Improvement:** the original offers its own ten alone.
pub const Missile = enum(u8) {
    screamer = 0,
    raptor = 1,
    havoc = 2,
    jack_hammer = 3,
    bandit = 4,
    vagabond = 5,
    solomon = 6,
    imp = 7,
    hawk = 8,
    fuel_pod = 9,
    _,

    /// Its record. A mod's missile takes its name and its description where it gives them, its
    /// model where it gives one of what hangs on a hardpoint (`additions.MissileExtra`), and the
    /// rest from its base's.
    pub fn record(missile: Missile) MissileRecord {
        const mod = missile.added() orelse return missiles[@backingInt(missile)];
        var made = missile.base().record();
        if (mod.label_string) |name| made.name = name;
        if (mod.extra.description_string) |description| made.description = description;
        if (missile.missileType().hungModel()) |model| made.model = model;
        return made;
    }

    /// The mod's record of it, for a missile a mod adds.
    pub fn added(missile: Missile) ?*const additions.missiles.Added {
        if (@backingInt(missile) < missile_count) return null;
        return missile.missileType().added();
    }

    /// The loadout's missile a mod's missile starts from, which the loadout takes its record and
    /// its limit from; the missile itself for the game's.
    pub fn base(missile: Missile) Missile {
        const mod = missile.added() orelse return missile;
        // The loadout holds only the mods' missiles whose base it offers (`all`, `named`).
        return ofType(mod.base).?;
    }

    /// The loadout's missile that flies as the game's missile type `game`, if it offers one: the
    /// torpedo it never does.
    pub fn ofType(game: missiles_mod.GameMissile) ?Missile {
        for (std.enums.values(Missile)) |missile| {
            if (missile.missileType() == missiles_mod.Type.of(game)) return missile;
        }
        return null;
    }

    /// The missile a mod adds under the qualified name `name`, such as `bananas:banana`, where its
    /// mod is on and the loadout offers its base (`offered`).
    pub fn named(name: []const u8) ?Missile {
        const number = additions.missiles.find(name) orelse return null;
        const missile: Missile = @fromBackingInt(@intCast(missile_count + number - additions.missiles.first));
        return if (missile.offered()) missile else null;
    }

    /// Whether the loadout offers it: one of the game's, or a mod's whose base the loadout offers.
    fn offered(missile: Missile) bool {
        const mod = missile.added() orelse return true;
        return ofType(mod.base) != null;
    }

    /// Every missile the loadout knows: the game's, then those of the mods whose base it offers.
    pub fn all(buffer: *[max_missiles]Missile) []const Missile {
        var count: usize = 0;
        for (0..missile_count + additions.missiles.all().len) |index| {
            const missile: Missile = @fromBackingInt(@intCast(index));
            if (!missile.offered()) continue;
            buffer[count] = missile;
            count += 1;
        }
        return buffer[0..count];
    }

    /// The first campaign tier that offers it (`missiles_by_tier`): a mod's where it gives one,
    /// else its base's. Null for none.
    pub fn firstTier(missile: Missile) ?u2 {
        if (missile.added()) |mod| return mod.extra.tier orelse missile.base().firstTier();
        for (missiles_by_tier, 0..) |set, tier| if (set.has(missile)) return @intCast(tier);
        return null;
    }

    /// Whether the campaign's `tier` offers it.
    pub fn offeredAt(missile: Missile, tier: u2) bool {
        const first = missile.firstTier() orelse return false;
        return tier >= first;
    }

    /// The most of it a ship carries and has in flight at once (`missile_limits`): a mod's its
    /// base's.
    pub fn limit(missile: Missile) u16 {
        return missile_limits[@backingInt(missile.base())];
    }

    /// The missile a hardpoint's id names for the loadout, which takes the id's word as its own
    /// index (`racks_fit_tier`, `0x00449AD0`; `racks_default`, `0x00449CA0`): none past its
    /// missiles, where the game reads beyond its tables. No shipped ship's hardpoints name one.
    pub fn ofId(id: u32) ?Missile {
        return if (id < missile_count) @fromBackingInt(@intCast(id)) else null;
    }

    /// The missile type the flight fits for it (`loadout_leave`, `0x00442D8C`): its own number,
    /// but for the fuel pod, which is type 10, and a mod's missiles, which are the types mods add.
    pub fn missileType(missile: Missile) missiles_mod.Type {
        const index = @backingInt(missile);
        if (index >= missile_count) return @fromBackingInt(@intCast(additions.missiles.first + index - missile_count));
        return switch (missile) {
            .fuel_pod => .of(.fuel_pod),
            else => @fromBackingInt(@intCast(index)),
        };
    }

    /// The id a saved game keeps for it (`campaign_saved_racks`): a mod's missile its base's, so
    /// that the save stays one the original reads.
    pub fn savedId(missile: Missile) u16 {
        return @backingInt(missile.base());
    }
};

/// The game's missiles.
pub const missile_count = @typeInfo(Missile).@"enum".fields.len;

/// The most missiles the loadout knows: the game's, and as many as mods can add.
pub const max_missiles = missile_count + additions.missiles.capacity;

comptime {
    // Each of the loadout's missiles flies as the missile type of its name.
    for (std.enums.values(Missile)) |missile| assert(std.mem.eql(u8, @tagName(missile), @tagName(@as(missiles_mod.GameMissile, @fromBackingInt(@intCast(@backingInt(missile.missileType())))))));
}

/// A missile's record (`loadout_missiles`, `0x004EDAA0`, `0x110` bytes a missile). The four
/// figures after it (`+0x100`) are its `MissileFigures`.
pub const MissileRecord = struct {
    /// The string that names it (`+0x00`).
    name: u16,
    /// Its model (`+0x02`, 250 bytes).
    model: []const u8,
    /// The string that describes it (`+0xFC`).
    description: u16,
};

/// `loadout_missiles` (`0x004EDAA0`), by `Missile`.
pub const missiles = [missile_count]MissileRecord{
    .{ .name = 0x203, .model = "21_screamer_pod.shp", .description = 0x1E5 },
    .{ .name = 0x204, .model = "22_raptor_pod.shp", .description = 0x1E6 },
    .{ .name = 0x205, .model = "23_havoc.shp", .description = 0x1E7 },
    .{ .name = 0x206, .model = "24_jackhammer.shp", .description = 0x1E8 },
    .{ .name = 0x207, .model = "25_bandit.shp", .description = 0x1E9 },
    .{ .name = 0x208, .model = "26_vagabond.shp", .description = 0x1EB },
    .{ .name = 0x209, .model = "27_solomon_pod.shp", .description = 0x1EA },
    .{ .name = 0x20A, .model = "28_imp.shp", .description = 0x1ED },
    .{ .name = 0x20B, .model = "29_hawk_pod.shp", .description = 0x1EC },
    .{ .name = 0x20C, .model = "31_fuel_pod.SHP", .description = 0x1EE },
};

/// A set of the loadout's missiles, a bit each in `Missile`'s order.
pub const MissileSet = packed struct(u32) {
    screamer: bool = false,
    raptor: bool = false,
    havoc: bool = false,
    jack_hammer: bool = false,
    bandit: bool = false,
    vagabond: bool = false,
    solomon: bool = false,
    imp: bool = false,
    hawk: bool = false,
    fuel_pod: bool = false,
    _unused: u22 = 0,

    /// Whether it holds `missile`: never a mod's, which it has no bit for.
    pub fn has(set: MissileSet, missile: Missile) bool {
        const bit = std.math.cast(u5, @backingInt(missile)) orelse return false;
        return @as(u32, @bitCast(set)) >> bit & 1 != 0;
    }
};

comptime {
    for (std.enums.values(Missile), @typeInfo(MissileSet).@"struct".fields[0..missile_count]) |missile, field| {
        assert(std.mem.eql(u8, @tagName(missile), field.name));
        assert(@bitOffsetOf(MissileSet, field.name) == @backingInt(missile));
    }
}

/// A row of a panel's figures (8 bytes a row): its label, how it shows its figure, and what
/// follows a number.
pub const Row = struct {
    /// The string it is labelled with (`+0`).
    label: u16,
    /// `+2`, a byte.
    kind: Kind,
    /// The string after its number, where it has one (`+4`, -1 for none).
    suffix: ?u16,
    /// Whether the missile panel shows a figure of -1 as `-` (`+6`, a byte; `missile_info_draw`,
    /// `0x004459BB`). The ship panel doesn't read it.
    dash_for_none: bool,

    /// How a row shows its figure.
    pub const Kind = enum(u8) {
        /// As a number, and its suffix.
        number = 1,
        /// As ten segments, as many of them filled as the figure.
        bar = 2,
    };
};

/// The string that follows a number of seconds: ` SECS`.
const seconds = 0x21C;

/// A ship's rows (`loadout_stat_layout`, `0x004EC020`), each showing the figure of its place in
/// `ShipFigures`.
pub const ship_rows = [_]Row{
    .{ .label = 0x20E, .kind = .bar, .suffix = null, .dash_for_none = true }, // Max Speed
    .{ .label = 0x210, .kind = .bar, .suffix = null, .dash_for_none = true }, // Acceleration
    .{ .label = 0x20F, .kind = .bar, .suffix = null, .dash_for_none = true }, // Agility
    .{ .label = 0x212, .kind = .bar, .suffix = null, .dash_for_none = true }, // Shield Power
    .{ .label = 0x213, .kind = .bar, .suffix = null, .dash_for_none = true }, // Shield Recharge
    .{ .label = 0x214, .kind = .bar, .suffix = null, .dash_for_none = true }, // Armor Class
    .{ .label = 0x211, .kind = .number, .suffix = seconds, .dash_for_none = true }, // Afterburner Fuel
    .{ .label = 0x217, .kind = .number, .suffix = null, .dash_for_none = true }, // Crew
};

/// A missile's rows (`loadout_missile_layout`, `0x004EC060`), each showing the figure of its place
/// in `MissileFigures`.
pub const missile_rows = [_]Row{
    .{ .label = 0x218, .kind = .number, .suffix = seconds, .dash_for_none = true }, // Locking Time
    .{ .label = 0x219, .kind = .bar, .suffix = null, .dash_for_none = true }, // Speed
    .{ .label = 0x21A, .kind = .bar, .suffix = null, .dash_for_none = true }, // Range
    .{ .label = 0x21B, .kind = .bar, .suffix = null, .dash_for_none = true }, // Damage
};

/// What a ship's rows show, in `ship_rows`' order: the figures of its record from `+0x1F8`, the
/// first seven of which `loadout_load` works out as it loads (`bars.shipFigures`), and its crew.
pub const ShipFigures = [ship_rows.len]i32;

/// What a missile's rows show, in `missile_rows`' order: the figures of its record from `+0x100`,
/// which `loadout_missile_bars_init` works out (`bars.missileFigures`).
pub const MissileFigures = [missile_rows.len]i32;

/// The campaign's tiers (`campaign_tier`, `0x00562DF0`): 0 at the start, 1 after mission 11, 2
/// after 19 and 3 after 21.
pub const tier_count = 4;

/// The pilot's ranks (`gameflow.Rank`, `pilot_rank`, `0x00562DEC`).
pub const rank_count = gameflow.rank_kills.len;

/// How many of `ships` the campaign's tier offers (`0x004EA408`): the loadout offers the first
/// ships, as many as the more of this and `ships_by_rank` (`0x00444760`).
pub const ships_by_tier = [tier_count]u8{ 4, 7, 10, 12 };

/// How many of `ships` the pilot's rank offers (`0x004EA418`).
pub const ships_by_rank = [rank_count]u8{ 4, 5, 6, 7, 8, 9, 10, 11, 12 };

/// The missiles each tier adds to those of the tiers before it (`0x004EA448`).
const missiles_added = [tier_count]u32{ 0x21D, 0xA2, 0x100, 0x40 };

/// The missiles each campaign tier offers (`0x004EA448`): those it adds and those of every tier
/// before it, as `loadout_load` ORs them together in place (`0x00441AF5`).
pub const missiles_by_tier: [tier_count]MissileSet = cumulative: {
    var sets: [tier_count]MissileSet = undefined;
    var so_far: u32 = 0;
    for (&sets, missiles_added) |*set, added| {
        so_far |= added;
        set.* = @bitCast(so_far);
    }
    break :cumulative sets;
};

/// The most of each missile a ship carries and has in flight at once (`0x004EA458`):
/// `missiles_available` (`0x0044B870`) hides a missile's icon while it is at its limit.
pub const missile_limits = [missile_count]u16{ 999, 999, 999, 3, 999, 999, 999, 999, 999, 999 };

/// The slot of `arc_slots` each missile's icon takes on the missiles page, by campaign tier
/// (`0x004EA480`, read at `0x00448837` and `0x004495E2`), or null (-1) where the tier doesn't offer
/// the missile.
pub const missile_slots = [tier_count][missile_count]?u8{
    .{ 3, null, 4, 5, 7, null, null, null, null, 6 },
    .{ 2, 9, 3, 4, 8, 6, null, 7, null, 5 },
    .{ 1, 8, 2, 3, 7, 5, null, 6, 9, 4 },
    .{ 1, 8, 2, 3, 7, 5, 10, 6, 9, 4 },
};

/// The slot of `arc_slots` the icon of each of `known` takes on the missiles page at the
/// campaign's `tier`, in `slots`, or null where the tier doesn't offer it: the game's missiles
/// their slots of `missile_slots`, and the mods' in turn the free slot nearest the arc's middle,
/// so that they carry on the game's row either side. Returns how many of the mods' missiles the
/// tier offers that found no slot.
///
/// **Improvement:** the original has no missiles but its own (`Missile`).
pub fn arcSlots(tier: u2, known: []const Missile, slots: []?u8) usize {
    var taken: [arc_slot_count]bool = @splat(false);
    for (known, slots) |missile, *slot| {
        const index = @backingInt(missile);
        slot.* = if (index < missile_count) missile_slots[tier][index] else null;
        if (slot.*) |at| taken[at] = true;
    }
    var left_out: usize = 0;
    for (known, slots) |missile, *slot| {
        if (missile.added() == null or !missile.offeredAt(tier)) continue;
        const free = nearestMiddle(&taken) orelse {
            left_out += 1;
            continue;
        };
        slot.* = free;
        taken[free] = true;
    }
    return left_out;
}

/// The slot of the arc not `taken` nearest its middle, the left one of two as near; null for none.
fn nearestMiddle(taken: *const [arc_slot_count]bool) ?u8 {
    var best: ?u8 = null;
    for (taken, 0..) |is_taken, at| {
        if (is_taken) continue;
        if (best == null or fromMiddle(at) < fromMiddle(best.?)) best = @intCast(at);
    }
    return best;
}

/// How far slot `at` is from the arc's middle, in half slots.
fn fromMiddle(at: usize) usize {
    return @abs(@as(isize, @intCast(at * 2)) - (arc_slot_count - 1));
}

/// The levels of coverage a remap table colours: those of the loadout's fonts, 0 for none to 15.
pub const remap_length = 16;

/// The colours the info panels' text is drawn in (`0x004EA308`): for each of the fonts' levels, the
/// entry of VFX's palette (`palette3`) it takes, greens from black to the brightest, and level 0
/// clear. The brightest, the full level's, is the bars' colour too (`bar_colour`).
pub const text_remap = [remap_length]u8{ hud.Remap.clear, 0x00, 0x05, 0x0D, 0x15, 0x14, 0x2E, 0x2F, 0x32, 0x35, 0x43, 0x9C, 0xA6, 0xAF, 0xB8, 0xC9 };

/// The title's colours (`0x00523D64`), which `loadout_load` makes of `text_remap` the other way
/// round (`0x00441C3A`), then sets level 0 clear and level 15 to the palette's first entry,
/// black: the title's letters come out black inside, edged in green, over the panel's art.
pub const title_remap: [remap_length]u8 = reversed: {
    var remap: [remap_length]u8 = undefined;
    for (&remap, 0..) |*entry, level| entry.* = text_remap[remap_length - 1 - level];
    remap[0] = hud.Remap.clear;
    remap[remap_length - 1] = 0;
    break :reversed remap;
};

/// The entry of VFX's palette the bars' segments are drawn in (`0x00445B20`).
pub const bar_colour = 0xC9;

/// Where an object of the loadout's scene stands (`loadout_placement_table`, `0x004EA520`, `0x2C`
/// bytes each): `loadout_placements` (`0x0044B5E0`) puts each object it finds by its name at the
/// position, turned by the angles (pitch, yaw, roll).
pub const Placement = struct {
    /// `+0x00`, 20 bytes with its terminator.
    name: []const u8,
    position: Vector,
    angles: Vector,
};

/// `loadout_placement_table` (`0x004EA520`), up to the empty name that ends it (`0x004EA704`).
pub const placements = [_]Placement{
    .{ .name = "BtnExit", .position = .{ 10, -8.35, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "BtnShips", .position = .{ 10, -5.8, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "BtnMissiles", .position = .{ 10, -3.8, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "BtnGuns", .position = .{ 10, -1.8, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "BtnDefault", .position = .{ 4.2, -8.35, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "BtnRemoveAll", .position = .{ 6.7, -8.35, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "PnlPageTitle", .position = .{ -8, -8.7, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "PnlShipName", .position = .{ -3.9, -7.9, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "PnlShipInfo", .position = .{ -8.6, -2.6, 0 }, .angles = .{ 0, 0, 0 } },
    .{ .name = "Disc", .position = .{ 1.499999, 3.749997, 1.449999 }, .angles = .{ -std.math.pi / 2.0, 0, 0 } },
    .{ .name = "Disc Glow", .position = .{ 1.000001, 5.099997, -3.8 }, .angles = .{ -1.765725, 0, 0 } },
};

comptime {
    for (placements) |placement| assert(placement.name.len < 0x14);
}

/// Where the camera stands (`loadout_placements`, `0x0044B5E7`).
pub const camera_position: Vector = .{ -2.8, -6.5, -16.85 };

/// How the camera is turned: pitch, yaw and roll (`0x0044B604`).
pub const camera_angles: Vector = .{ -0.368, 0.067, 0.03 };

/// Where the chosen ship stands (`slots_set`, `0x004497F0`, into `0x005245F4`), in the units the
/// slots are placed on the disc in (`0x00449690`).
pub const chosen_slot: Vector = .{ 23, -23, -6 };

pub const arc_slot_count = 12;

/// The slots round the disc's arc, from one end round the front to the other (`slots_set`, into
/// `0x005240B4`, `0x1C` bytes apart): the ships the loadout offers stand in the middle ones, a
/// missile's icon in the one `missile_slots` gives it.
pub const arc_slots = [arc_slot_count]Vector{
    .{ -98, -23, -1 },
    .{ -99, 11, -1 },
    .{ -89, 42, -1 },
    .{ -72, 67, -1 },
    .{ -48, 85, -1 },
    .{ -18, 97, -1 },
    .{ 17, 97, -1 },
    .{ 48, 85, -1 },
    .{ 71, 67, -1 },
    .{ 89, 42, -1 },
    .{ 97, 11, -1 },
    .{ 96, -23, -1 },
};

comptime {
    for (missile_slots) |row| for (row) |slot| if (slot) |at| assert(at < arc_slot_count);
}

test ships {
    // Each scale is the executable's own float.
    const scale_bits = [ship_count]u32{
        0x3C1374BC, 0x3C23D70A, 0x3C03126F, 0x3C1374BC, 0x3C09A027, 0x3C23D70A,
        0x3BE56042, 0x3BDB8BAC, 0x3BC49BA6, 0x3BE8A71E, 0x3BC49BA6, 0x3C03126F,
    };
    for (ships, scale_bits) |ship, bits| try std.testing.expectEqual(bits, @as(u32, @bitCast(ship.scale)));
    // The Shroud's specials word is 0x71, the Phoenix's 0x29.
    try std.testing.expectEqual(0x71, @as(u32, @bitCast(ships[10].specials)));
    try std.testing.expectEqual(0x29, @as(u32, @bitCast(ships[11].specials)));
    try std.testing.expect(ships[10].specials.has(6));
    try std.testing.expect(!ships[10].specials.has(7));
    try std.testing.expectEqual(0x553, ships[10].class.string());
    try std.testing.expectEqual(0x22C, ships[11].access.string());
}

test gunDescription {
    try std.testing.expectEqual(0x246, gunDescription(0x238).?.range);
    try std.testing.expectEqual(null, gunDescription(0x242).?.drain);
    // The rear turrets have none, nor what lies outside the table.
    try std.testing.expectEqual(null, gunDescription(first_rear_turret));
    try std.testing.expectEqual(null, gunDescription(0x243));
    try std.testing.expectEqual(null, gunDescription(0x237));
    // Every gun a ship has but the rear turrets is described.
    for (ships) |ship| for (ship.guns) |mount| {
        try std.testing.expectEqual(mount.gun < first_rear_turret, gunDescription(mount.gun) != null);
    };
}

test "the mods' ship types" {
    var list = [_]additions.ships.Added{
        // Offered from the campaign's start, as it gives no tier, under a name of its own.
        .{ .name = "a:pot", .mod = "a", .base = .predator, .label_string = 900, .extra = .{ .model = "pot.shp" } },
        // Offered from the tier it gives, though its base, the Phoenix, comes later.
        .{ .name = "a:early", .mod = "a", .base = .phoenix, .extra = .{ .model = "early.shp", .tier = 1 } },
        // A capital ship's type, which the player can't fly.
        .{ .name = "a:big", .mod = "a", .base = .yamato, .extra = .{ .model = "big.shp" } },
    };
    additions.ships.install(&list);
    defer additions.ships.reset();
    var buffer: [arc_slot_count]Offer = undefined;
    // The first tier's four of the game's, then the pot; the early one waits for its tier.
    const first, const left_out = offers(0, 4, &buffer);
    try std.testing.expectEqual(5, first.len);
    try std.testing.expectEqual(0, left_out);
    const pot = first[4];
    try std.testing.expectEqual(additions.ships.first, pot.ship_type);
    try std.testing.expectEqual(900, pot.record.name);
    try std.testing.expectEqualStrings("pot.shp", pot.record.model);
    try std.testing.expectEqual(ships[0].class, pot.record.class);
    // At the second tier, the game's seven, the pot, and the early one from its own tier.
    const second, _ = offers(1, 7, &buffer);
    try std.testing.expectEqual(9, second.len);
    try std.testing.expectEqual(additions.ships.first + 1, second[8].ship_type);
    // With every place of the arc taken by the game's twelve, the mods' are left out.
    const full, const dropped = offers(3, ship_count, &buffer);
    try std.testing.expectEqual(ship_count, full.len);
    try std.testing.expectEqual(2, dropped);
    // A saved game keeps a mod's ship type as its base.
    try std.testing.expectEqual(0, savedShip(additions.ships.first));
    try std.testing.expectEqual(11, savedShip(11));
}

test modRecord {
    var list = [_]additions.ships.Added{
        // Based on the Phoenix, with its own figures and without its blind fire.
        .{ .name = "a:own", .mod = "a", .base = .phoenix, .extra = .{ .model = "own.shp", .class = .heavy, .crew = 3, .blind_fire = false } },
        // Without a base: the defaults, its model on the guns page, and the shields it gives.
        .{ .name = "a:bare", .mod = "a", .base = .predator, .based = false, .extra = .{ .model = "bare.shp", .access = .gold, .spectral_shields = true } },
        // Based on the Predator, with a gun model of its own.
        .{ .name = "a:armed", .mod = "a", .base = .predator, .extra = .{ .model = "armed.shp", .guns_model = "armed_gun.shp" } },
    };
    // Which show a gun model of their own: the one without a base and the one that gives one.
    try std.testing.expect(!ownGunsModel(&list[0]) and ownGunsModel(&list[1]) and ownGunsModel(&list[2]));
    try std.testing.expectEqualStrings("armed_gun.shp", modRecord(&list[2]).guns_model);
    try std.testing.expectEqualStrings(ships[11].guns_model, modRecord(&list[0]).guns_model);
    const own = modRecord(&list[0]);
    try std.testing.expectEqual(Class.heavy, own.class);
    try std.testing.expectEqual(3, own.crew);
    try std.testing.expectEqual(ships[11].access, own.access);
    try std.testing.expect(!own.specials.blind_fire and ships[11].specials.blind_fire);
    try std.testing.expect(own.specials.nova_cannon);
    try std.testing.expectEqual(ships[11].guns.ptr, own.guns.ptr);
    const bare = modRecord(&list[1]);
    try std.testing.expectEqual(additions.ShipExtra.default_class, bare.class);
    try std.testing.expectEqual(Access.gold, bare.access);
    try std.testing.expectEqual(additions.ShipExtra.default_crew, bare.crew);
    try std.testing.expectEqualStrings("bare.shp", bare.guns_model);
    try std.testing.expectEqual(0, bare.guns.len);
    try std.testing.expectEqual(Specials{ .spectral_shields = true }, bare.specials);
    try std.testing.expectEqual(ships[0].scale, bare.scale);
}

test gunString {
    // As the game's records name them: the Predator's Proton Cannon and the Phoenix's Nova Cannon.
    try std.testing.expectEqual(ships[0].guns[0].gun, gunString(.of(.proton_cannon)).?);
    try std.testing.expectEqual(ships[11].guns[2].gun, gunString(.of(.nova_cannon)).?);
    try std.testing.expectEqual(null, gunString(.of(.turret_flak)));
    // Every fighter's gun has a description.
    for (std.enums.values(guns.GameGun)) |gun| {
        if (gunString(.of(gun))) |name| try std.testing.expect(gunDescription(name) != null);
    }
}

test withModel {
    const gpa = std.testing.allocator;
    var buffer: [1024]u8 = undefined;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var model = try shp.Model.parse(arena.allocator(), shp.testing.buildModel(&buffer));
    // Two Pulse Cannons, a Nova Cannon, a turret's gun the list leaves out, and a glow that burns
    // forward. The test model can cloak.
    var attachments = std.mem.zeroes([5]shp.Attachment);
    for (&attachments, [_]u32{ 2, 2, 11, 12, 0 }) |*attachment, number| {
        attachment.kind = .gun_muzzle;
        attachment.gun_type = number;
    }
    attachments[4].kind = .engine_glow;
    attachments[4].orientation[8] = 1;
    attachments[4].size[2] = 1;
    model.parts[0].attachments = &attachments;
    const bare: Ship = .{ .name = 0, .model = "", .guns_model = "", .class = .light, .access = .bronze, .crew = 1, .specials = .{}, .guns = &.{}, .scale = 1 };
    const made = try withModel(bare, null, &model, gpa);
    defer gpa.free(made.guns);
    try std.testing.expectEqualSlices(Mount, &.{ .{ .gun = 0x239, .count = 2 }, .{ .gun = 0x23F, .count = 1 } }, made.guns);
    try std.testing.expectEqual(Specials{ .reverse_thrust = true, .nova_cannon = true, .cloaking_device = true }, made.specials);
    // A gun the type gives fires from every muzzle, as `guns.refit` fits it.
    const refit = try withModel(bare, .of(.tachyon_cannon), &model, gpa);
    defer gpa.free(refit.guns);
    try std.testing.expectEqualSlices(Mount, &.{.{ .gun = 0x23D, .count = 4 }}, refit.guns);
}

test "the mods' missiles" {
    var list = [_]additions.missiles.Added{
        // On a pod's base, a missile of its own still hangs in its base's pod.
        .{ .name = "a:pod", .mod = "a", .base = .raptor, .extra = .{ .model = "banana.shp" } },
        .{ .name = "a:rail", .mod = "a", .base = .bandit, .label_string = 900, .extra = .{ .model = "banana.shp", .tier = 2, .description_string = 901 } },
        // The torpedo the loadout never offers.
        .{ .name = "a:torpedo", .mod = "a", .base = .torpedo, .extra = .{} },
    };
    additions.missiles.install(&list);
    defer additions.missiles.reset();
    const pod: Missile = @fromBackingInt(@intCast(missile_count));
    const rail: Missile = @fromBackingInt(@intCast(missile_count + 1));
    // The game's ten, then those of the mods whose base the loadout offers.
    var buffer: [max_missiles]Missile = undefined;
    const known = Missile.all(&buffer);
    try std.testing.expectEqual(missile_count + 2, known.len);
    try std.testing.expectEqual(rail, known[known.len - 1]);
    // Its record: its own name, description and model, else its base's.
    try std.testing.expectEqual(Missile.raptor, pod.base());
    try std.testing.expectEqualDeep(Missile.raptor.record(), pod.record());
    const record = rail.record();
    try std.testing.expectEqual(900, record.name);
    try std.testing.expectEqual(901, record.description);
    try std.testing.expectEqualStrings("banana.shp", record.model);
    // It flies as its own type, and a saved game keeps its base.
    try std.testing.expectEqual(@as(missiles_mod.Type, @fromBackingInt(@intCast(additions.missiles.first + 1))), rail.missileType());
    try std.testing.expectEqual(@backingInt(Missile.bandit), rail.savedId());
    // Found again by its qualified name, while its mod is on.
    try std.testing.expectEqual(rail, Missile.named("A:RAIL").?);
    try std.testing.expectEqual(null, Missile.named("b:rail"));
    // A missile on a base the loadout doesn't offer isn't found, as a saved game might still name it.
    try std.testing.expectEqual(null, Missile.named("a:torpedo"));
    // Offered from its own tier, else its base's, with its base's limit.
    try std.testing.expectEqual(2, rail.firstTier());
    try std.testing.expect(!rail.offeredAt(1) and rail.offeredAt(3));
    try std.testing.expectEqual(Missile.raptor.firstTier(), pod.firstTier());
    try std.testing.expectEqual(missile_limits[@backingInt(Missile.bandit)], rail.limit());
    // On the arc, in the slots the game's missiles leave free.
    var slots: [missile_count + 2]?u8 = undefined;
    try std.testing.expectEqual(0, arcSlots(3, known, &slots));
    try std.testing.expectEqual(missile_slots[3][0], slots[0]);
    try std.testing.expectEqual(@as(?u8, 0), slots[missile_count]);
    try std.testing.expectEqual(@as(?u8, 11), slots[missile_count + 1]);
    // At the second tier the game's take slots 2 to 9, and the mods' carry on beside them, the
    // left of two as near the middle first.
    _ = arcSlots(1, known, &slots);
    try std.testing.expectEqual(@as(?u8, 1), slots[missile_count]);
    try std.testing.expectEqual(null, slots[missile_count + 1]);
    // Before its tier, a missile has no slot.
    _ = arcSlots(1, known, &slots);
    try std.testing.expectEqual(null, slots[missile_count + 1]);
}

test arcSlots {
    // More of the mods' missiles than the tier leaves free slots: the rest are left out.
    var list: [arc_slot_count]additions.missiles.Added = undefined;
    for (&list) |*each| each.* = .{ .name = "a:m", .mod = "a", .base = .screamer, .extra = .{} };
    additions.missiles.install(&list);
    defer additions.missiles.reset();
    var buffer: [max_missiles]Missile = undefined;
    const known = Missile.all(&buffer);
    var slots: [missile_count + arc_slot_count]?u8 = undefined;
    // The last tier offers all ten of the game's, which leave two slots.
    try std.testing.expectEqual(arc_slot_count - 2, arcSlots(3, known, &slots));
}

test missiles_by_tier {
    const words = [tier_count]u32{ 0x21D, 0x2BF, 0x3BF, 0x3FF };
    for (missiles_by_tier, words) |set, word| try std.testing.expectEqual(word, @as(u32, @bitCast(set)));
    try std.testing.expect(missiles_by_tier[0].has(.fuel_pod));
    try std.testing.expect(!missiles_by_tier[2].has(.solomon));
    // A tier's icons take a slot each for the missiles it offers, and none for the others.
    for (missile_slots, missiles_by_tier) |slots, set| {
        for (slots, std.enums.values(Missile)) |slot, missile| try std.testing.expectEqual(set.has(missile), slot != null);
    }
    try std.testing.expectEqual(.fuel_pod, @as(Missile, @fromBackingInt(@intCast(9))));
    try std.testing.expectEqual(0x20C, Missile.fuel_pod.record().name);
}

test title_remap {
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xB8, 0xAF, 0xA6, 0x9C, 0x43, 0x35, 0x32, 0x2F, 0x2E, 0x14, 0x15, 0x0D, 0x05, 0x00, 0x00 }, &title_remap);
    try std.testing.expectEqual(bar_colour, text_remap[remap_length - 1]);
}

test placements {
    // The disc's and its glow's floats are the executable's own.
    const disc = placements[9];
    try std.testing.expectEqualStrings("Disc", disc.name);
    const bits = [_]struct { f32, u32 }{
        .{ disc.position[0], 0x3FBFFFF8 },           .{ disc.position[1], 0x406FFFF3 },
        .{ disc.position[2], 0x3FB99991 },           .{ disc.angles[0], 0xBFC90FDB },
        .{ placements[10].position[0], 0x3F800008 }, .{ placements[10].position[1], 0x40A3332D },
        .{ placements[10].position[2], 0xC0733333 }, .{ placements[10].angles[0], 0xBFE20347 },
        .{ camera_position[2], 0xC186CCCD },         .{ camera_angles[0], 0xBEBC6A7F },
        .{ camera_angles[1], 0x3D89374C },           .{ camera_angles[2], 0x3CF5C28F },
    };
    for (bits) |pair| try std.testing.expectEqual(pair[1], @as(u32, @bitCast(pair[0])));
}
