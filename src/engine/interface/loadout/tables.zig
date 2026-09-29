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
/// of the same number (`missiles.Type`), but for the fuel pod, which is type 10.
pub const Missile = enum(u4) {
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

    /// Its record.
    pub fn record(missile: Missile) MissileRecord {
        return missiles[@intFromEnum(missile)];
    }

    /// The missile a hardpoint's id names for the loadout, which takes the id's word as its own
    /// index (`racks_fit_tier`, `0x00449AD0`; `racks_default`, `0x00449CA0`): none past its
    /// missiles, where the game reads beyond its tables. No shipped ship's hardpoints name one.
    pub fn ofId(id: u32) ?Missile {
        return if (id < missile_count) @enumFromInt(id) else null;
    }

    /// The missile type the flight fits for it (`loadout_leave`, `0x00442D8C`): its own number,
    /// but for the fuel pod, which is type 10.
    pub fn missileType(missile: Missile) missiles_mod.Type {
        return switch (missile) {
            .fuel_pod => .fuel_pod,
            else => @enumFromInt(@intFromEnum(missile)),
        };
    }
};

pub const missile_count = @typeInfo(Missile).@"enum".fields.len;

comptime {
    // Each of the loadout's missiles flies as the missile type of its name.
    for (std.enums.values(Missile)) |missile| assert(std.mem.eql(u8, @tagName(missile), @tagName(missile.missileType())));
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

    pub fn has(set: MissileSet, missile: Missile) bool {
        return @as(u32, @bitCast(set)) >> @intFromEnum(missile) & 1 != 0;
    }

    /// The set with `missile` in it too.
    pub fn with(set: MissileSet, missile: Missile) MissileSet {
        return @bitCast(@as(u32, @bitCast(set)) | @as(u32, 1) << @intFromEnum(missile));
    }
};

comptime {
    for (std.enums.values(Missile), @typeInfo(MissileSet).@"struct".fields[0..missile_count]) |missile, field| {
        assert(std.mem.eql(u8, @tagName(missile), field.name));
        assert(@bitOffsetOf(MissileSet, field.name) == @intFromEnum(missile));
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

test missiles_by_tier {
    const words = [tier_count]u32{ 0x21D, 0x2BF, 0x3BF, 0x3FF };
    for (missiles_by_tier, words) |set, word| try std.testing.expectEqual(word, @as(u32, @bitCast(set)));
    try std.testing.expect(missiles_by_tier[0].has(.fuel_pod));
    try std.testing.expect(!missiles_by_tier[2].has(.solomon));
    // A tier's icons take a slot each for the missiles it offers, and none for the others.
    for (missile_slots, missiles_by_tier) |slots, set| {
        for (slots, std.enums.values(Missile)) |slot, missile| try std.testing.expectEqual(set.has(missile), slot != null);
    }
    try std.testing.expectEqual(.fuel_pod, @as(Missile, @enumFromInt(9)));
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
