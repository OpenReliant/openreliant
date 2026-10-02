//! The `*STATS.BIN` tables: ship, gun, missile and pilot definitions.
//!
//! Each is a flat array of 352-byte records with no header. The four share one frame, a 64-byte
//! name followed by fields, and differ in what the fields mean. Each table has its own loader in
//! the payload executable, which reads the file with `fread` one record at a time into a buffer on
//! its stack and copies out only the fields it wants. Everything here is taken from those loaders
//! and from the screens that display the result.
//!
//! **The engine never reads a record's name**, nor anything past its last field. In the shipped
//! files those bytes are zero in every record of every table, so a record's fields are its entire
//! content.

const std = @import("std");
const assert = std.debug.assert;

pub const record_size = 0x160;

/// Bytes of name at the start of every record: NUL-padded ASCII.
pub const name_size = 0x40;

pub const Error = error{
    /// The file is not a whole number of records.
    Truncated,
};

/// The four tables, and how the engine loads each.
pub const Table = enum {
    ships,
    guns,
    missiles,
    pilots,

    pub fn fileName(table: Table) []const u8 {
        return switch (table) {
            .ships => "shipstats.bin",
            .guns => "gunstats.bin",
            .missiles => "missilestats.bin",
            .pilots => "pilotstats.bin",
        };
    }

    /// Recognises a table by its file name, ignoring case and any directory.
    pub fn fromPath(path: []const u8) ?Table {
        const base = std.fs.path.basename(path);
        inline for (comptime std.enums.values(Table)) |table| {
            if (std.ascii.eqlIgnoreCase(base, table.fileName())) return table;
        }
        return null;
    }

    /// How the table's loader decides how many records to read.
    pub fn load(table: Table) Load {
        return switch (table) {
            .ships => .{ .at_most = 256 },
            .guns => .{ .until_end = 15 },
            .missiles => .{ .at_most = 11 },
            .pilots => .{ .until_end = 194 },
        };
    }

    /// The record type for this table.
    pub fn Record(comptime table: Table) type {
        return switch (table) {
            .ships => Ship,
            .guns => Gun,
            .missiles => Missile,
            .pilots => Pilot,
        };
    }
};

/// How a loader decides how many records to read. Either way the payload is the size of the table
/// the records land in.
pub const Load = union(enum) {
    /// Reads records until it has this many, or the file runs out, and stops.
    at_most: usize,
    /// Reads until the end of the file, with no bound, into a table this many records long. A
    /// longer file writes past the end of that table.
    until_end: usize,

    /// Records the engine keeps.
    pub fn capacity(load: Load) usize {
        return switch (load) {
            inline else => |records_kept| records_kept,
        };
    }

    /// How many of `available` records the engine reads, which for `until_end` may exceed what it
    /// has room for.
    pub fn reads(load: Load, available: usize) usize {
        return switch (load) {
            .at_most => |limit| @min(limit, available),
            .until_end => available,
        };
    }
};

/// A parsed table, tagged by which one it is.
pub const File = union(Table) {
    ships: []align(1) const Ship,
    guns: []align(1) const Gun,
    missiles: []align(1) const Missile,
    pilots: []align(1) const Pilot,

    pub fn parse(table: Table, bytes: []const u8) Error!File {
        return switch (table) {
            inline else => |tag| @unionInit(File, @tagName(tag), try records(tag.Record(), bytes)),
        };
    }

    pub fn len(file: File) usize {
        return switch (file) {
            inline else => |rows| rows.len,
        };
    }
};

/// A record's name, up to its first NUL.
pub fn nameOf(bytes: *const [name_size]u8) []const u8 {
    return std.mem.sliceTo(bytes, 0);
}

/// A table's records as `T`.
pub fn records(comptime T: type, bytes: []const u8) Error![]align(1) const T {
    comptime assert(@sizeOf(T) == record_size);
    if (bytes.len % record_size != 0) return error.Truncated;
    return std.mem.bytesAsSlice(T, bytes);
}

/// One ship, station or other object. All 256 records are loaded.
///
/// The loadout screen shows seven of these fields, and its layout table pairs each with a label
/// from `LANGUAGE.DLL`: six as ten-segment bars scaled to the spread across the listed ships, one
/// as a number.
/// Those labels are noted below. The flight model names for `0x44` to `0x5C` come from
/// Starlancer-OSS, which compared mods with the original files; the loader agrees with their
/// grouping, copying the three rates together and the four inertias together.
pub const Ship = extern struct {
    name: [name_size]u8,
    /// Shown as **Max Speed**.
    max_speed: f32,
    /// Shown as **Acceleration**. Around 0.9: the flight model keeps it with the three angular
    /// inertias below.
    inertia: f32,
    /// Shown as **Agility**.
    yaw_rate: f32,
    yaw_inertia: f32,
    pitch_rate: f32,
    pitch_inertia: f32,
    roll_rate: f32,
    roll_inertia: f32,
    /// Shown as **Shield Power**. Truncated to an integer on load.
    shield_power: f32,
    /// Shown as **Armor Class**. Truncated to an integer on load.
    armor_class: f32,
    /// Shown as **Afterburner Fuel**, in seconds. Truncated to an integer on load.
    afterburner_fuel: f32,
    /// Shown as **Shield Recharge**. The loader substitutes 10 for zero.
    shield_recharge: f32,
    /// The guns' maximum charge: `create_object` gives a new ship this much, the guns recharge up
    /// to it, and the display's right arc shows the charge against it. Mods: GunEnergy.
    gun_energy: f32,
    /// The seconds the guns take to charge fully (`guns.step`). Mods: GunRecharge.
    gun_recharge: f32,
    /// The rounds a new ship's guns have, truncated on load. Each shot from a gun of kind `rounds`
    /// uses one (`guns.step`).
    rounds: f32,
    _unread: [record_size - 0x7C]u8,

    /// What the loader substitutes for a `shield_recharge` of zero.
    pub const default_shield_recharge: f32 = 10.0;

    comptime {
        assert(@offsetOf(Ship, "max_speed") == 0x40);
        assert(@offsetOf(Ship, "shield_power") == 0x60);
        assert(@offsetOf(Ship, "shield_recharge") == 0x6C);
        assert(@offsetOf(Ship, "_unread") == 0x7C);
        assert(@sizeOf(Ship) == record_size);
    }
};

/// The damage a hit does to a shield and to a hull.
pub const Damage = extern struct {
    shield: f32,
    hull: f32,

    /// The factor that turns damage getting through a shield into hull damage (`object_damage`):
    /// hull damage divided by shield damage.
    pub fn hullShare(damage: Damage) f32 {
        return damage.hull / damage.shield;
    }
};

/// One gun. The loader reads until the end of the file into `gun_stats`, whose first record is
/// no gun: the file's 15 records are the gun types 1 to 15 a muzzle can name.
pub const Gun = extern struct {
    name: [name_size]u8,
    /// How many ticks a shot lasts, truncated on load, which sets the gun's range.
    range: f32,
    /// How fast a shot flies.
    speed: f32,
    /// The damage a hit does to a shield, and to a hull or a component. The engine also weights
    /// nearby guns by the shield damage when it picks the most dangerous gun type around the
    /// player.
    damage: Damage,
    /// Shots per unit time. The loader stores `100 / fire_rate`, truncated, which is the interval
    /// between shots.
    fire_rate: f32,
    /// The energy a shot takes from the guns' charge, truncated on load, for a gun that uses energy
    /// rather than rounds (`guns.Kind`). Guns that fire rounds have none.
    shot_energy: f32,
    _unread: [record_size - 0x58]u8,

    /// What the loader divides by `fire_rate`.
    pub const refire_scale: f32 = 100.0;

    /// The interval between shots, as the engine stores it. Null for a rate of zero, which the
    /// shipped data never uses.
    pub fn refireInterval(gun: Gun) ?i32 {
        if (gun.fire_rate == 0) return null;
        return std.math.lossyCast(i32, refire_scale / gun.fire_rate);
    }

    comptime {
        assert(@offsetOf(Gun, "range") == 0x40);
        assert(@offsetOf(Gun, "damage") == 0x48);
        assert(@offsetOf(Gun, "fire_rate") == 0x50);
        assert(@offsetOf(Gun, "_unread") == 0x58);
        assert(@sizeOf(Gun) == record_size);
    }
};

/// One missile. **The loader stops after 11**, so of the 16 shipped records the last five, which
/// are zero throughout, are never read; the eleventh, also zero, is loaded and hidden on the
/// loadout screen.
///
/// The loadout screen shows four values, labelled from `LANGUAGE.DLL`: Locking Time, Speed, Range
/// and Damage.
pub const Missile = extern struct {
    name: [name_size]u8,
    /// Shown as **Speed**.
    speed: f32,
    /// Copied into all three rates of the missile's flight model.
    turn_rate: f32,
    /// **Range** on the loadout screen is `speed * flight_time`. The loader stores the field
    /// multiplied by 100, truncated.
    flight_time: f32,
    /// **Damage** on the loadout screen is the sum of the two (`missile_collide`).
    damage: Damage,
    /// Shown as **Locking Time**, in hundredths of a second: the screen multiplies it by 0.01 and
    /// labels the result in seconds. Truncated to an integer on load.
    lock_time: f32,
    /// In percent, the chance that a countermeasure decoys the missile
    /// (`object_spend_countermeasure`). Truncated to an integer on load.
    decoy_chance: f32,
    /// The distance at which the missile can lock on to a target, for the player, the AI and
    /// missile turrets.
    lock_range: f32,
    /// The damage a hit does to a component, on ships that have components.
    component_damage: f32,
    _unread: [record_size - 0x64]u8,

    /// The range the loadout screen compares missiles by: how far the missile flies.
    pub fn loadoutRange(missile: Missile) f32 {
        return missile.speed * missile.flight_time;
    }

    /// Locking time in seconds, as the loadout screen shows it.
    pub fn lockSeconds(missile: Missile) f32 {
        return missile.lock_time * seconds_per_lock_unit;
    }

    /// What the loadout screen multiplies the locking time by for its seconds
    /// (`loadout_missile_bars_init`, `0x0044B680`, reads it at `0x004DC518`).
    pub const seconds_per_lock_unit: f32 = 0.01;

    comptime {
        assert(@offsetOf(Missile, "speed") == 0x40);
        assert(@offsetOf(Missile, "flight_time") == 0x48);
        assert(@offsetOf(Missile, "damage") == 0x4C);
        assert(@offsetOf(Missile, "lock_time") == 0x54);
        assert(@offsetOf(Missile, "_unread") == 0x64);
        assert(@sizeOf(Missile) == record_size);
    }
};

/// One pilot. The record index is the pilot ID missions refer to.
///
/// The loader first fills all 194 slots with defaults, then reads records until the end of the
/// file. Three fields select one of three presets for a group of runtime values. The four 32-bit
/// words after them are copied with a 16-bit move, so only their low halves are used and the high
/// halves are never read. The shipped data uses levels 1 and 2 only.
pub const Pilot = extern struct {
    name: [name_size]u8,
    /// Selects six 16-bit values: `tier_a_presets`.
    tier_a: Tier,
    /// Selects one value: `tier_b_presets`.
    tier_b: Tier,
    /// Selects two floats and a 16-bit value: `tier_c_presets`. Level 2 also overrides the last
    /// two values `tier_a` set, because the loader applies this field after that one.
    tier_c: Tier,
    /// The pilot's skill, used by the Fight order's maneuvers (`pilots.Pilot.skill`).
    skill: Skill,
    _unread_4e: u16,
    /// Copied to the pilot. The pilot answers the radio's What's your status? only if it's above 0
    /// (`videoreports.menu`). **Unknown:** what else it does.
    _unknown_50: u16,
    _unread_52: u16,
    /// Copied to the pilot. **Unknown:** what it does.
    _unknown_54: u16,
    _unread_56: u16,
    /// Copied to the pilot. The radio checks it without any effect (`videoreports.wingmen`).
    /// **Unknown:** what it does.
    _unknown_58: u16,
    _unread_5a: u16,
    _unread: [record_size - 0x5C]u8,

    /// A pilot's skill. More skilled pilots pursue from closer, keep less distance from what they
    /// might hit, and use the afterburner when attacking. Other values match none of the three
    /// (`aifight`, `aidefend`).
    pub const Skill = enum(u16) {
        low = 0,
        medium = 1,
        high = 2,
        _,
    };

    /// A preset level. Any other value leaves that group at its default.
    pub const Tier = enum(u32) {
        level_0 = 0,
        level_1 = 1,
        level_2 = 2,
        _,

        pub fn index(tier: Tier) ?usize {
            return switch (tier) {
                .level_0, .level_1, .level_2 => @intFromEnum(tier),
                _ => null,
            };
        }
    };

    comptime {
        assert(@offsetOf(Pilot, "tier_a") == 0x40);
        assert(@offsetOf(Pilot, "tier_c") == 0x48);
        assert(@offsetOf(Pilot, "skill") == 0x4C);
        assert(@offsetOf(Pilot, "_unknown_58") == 0x58);
        assert(@offsetOf(Pilot, "_unread") == 0x5C);
        assert(@sizeOf(Pilot) == record_size);
    }
};

/// The six values each level of `Pilot.tier_a` sets, and the defaults the loader starts from.
pub const tier_a_presets = [3][6]u16{
    .{ 10, 40, 800, 1600, 400, 800 },
    .{ 30, 50, 400, 800, 300, 600 },
    .{ 100, 100, 200, 400, 200, 400 },
};
pub const tier_a_default = [6]u16{ 30, 50, 400, 800, 200, 400 };

/// The value each level of `Pilot.tier_b` sets.
pub const tier_b_presets = [3]f32{ 5.0, 3.0, 1.5 };
pub const tier_b_default: f32 = 3.0;

/// What each level of `Pilot.tier_c` sets.
pub const TierC = struct { f32, f32, u16 };
pub const tier_c_presets = [3]TierC{
    .{ 0.6, 0.4, 100 },
    .{ 0.8, 0.2, 50 },
    .{ 1.0, 0.0, 25 },
};
pub const tier_c_default: TierC = .{ 0.8, 0.2, 50 };
/// What level 2 of `tier_c` writes over the last two of `tier_a`'s values.
pub const tier_c_level_2_override = [2]u16{ 50, 100 };

fn testRecord(comptime T: type, name: []const u8) T {
    var bytes: [record_size]u8 = @splat(0);
    @memcpy(bytes[0..name.len], name);
    return @bitCast(bytes);
}

test Table {
    try std.testing.expectEqual(Table.ships, Table.fromPath("game/install/SHIPSTATS.BIN").?);
    try std.testing.expectEqual(Table.pilots, Table.fromPath("pilotstats.bin").?);
    try std.testing.expectEqual(@as(?Table, null), Table.fromPath("shipstats.bak"));
    try std.testing.expectEqual(Ship, Table.Record(.ships));
}

test Load {
    const missiles = Table.missiles.load();
    try std.testing.expectEqual(@as(usize, 11), missiles.capacity());
    try std.testing.expectEqual(@as(usize, 11), missiles.reads(16));

    const guns = Table.guns.load();
    try std.testing.expectEqual(@as(usize, 15), guns.capacity());
    try std.testing.expectEqual(@as(usize, 20), guns.reads(20));
}

test File {
    var bytes: [record_size]u8 = @splat(0);
    @memcpy(bytes[0..5], "Laser");
    const file = try File.parse(.guns, &bytes);
    try std.testing.expectEqual(Table.guns, std.meta.activeTag(file));
    try std.testing.expectEqual(@as(usize, 1), file.len());
    try std.testing.expectEqualStrings("Laser", nameOf(&file.guns[0].name));
}

test records {
    var file: [2 * record_size]u8 = @splat(0);
    var ship = testRecord(Ship, "Us Predator");
    ship.max_speed = 320;
    ship.shield_power = 10;
    @memcpy(file[0..record_size], std.mem.asBytes(&ship));

    const ships = try records(Ship, &file);
    try std.testing.expectEqual(@as(usize, 2), ships.len);
    try std.testing.expectEqualStrings("Us Predator", nameOf(&ships[0].name));
    try std.testing.expectEqual(@as(f32, 320), ships[0].max_speed);
    try std.testing.expectEqualStrings("", nameOf(&ships[1].name));

    try std.testing.expectError(error.Truncated, records(Ship, file[0 .. record_size + 1]));
}

test Gun {
    var gun = testRecord(Gun, "Proton Cannon");
    gun.fire_rate = 6;
    try std.testing.expectEqual(@as(?i32, 16), gun.refireInterval());
    gun.fire_rate = 0;
    try std.testing.expectEqual(@as(?i32, null), gun.refireInterval());
}

test Missile {
    var missile = testRecord(Missile, "Raptor");
    missile.speed = 500;
    missile.flight_time = 50;
    missile.lock_time = 300;
    try std.testing.expectEqual(@as(f32, 25000), missile.loadoutRange());
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), missile.lockSeconds(), 1e-5);
}

test Pilot {
    var pilot = testRecord(Pilot, "Cat Foster");
    pilot.tier_a = .level_2;
    pilot.tier_b = @enumFromInt(7);
    try std.testing.expectEqual(@as(?usize, 2), pilot.tier_a.index());
    try std.testing.expectEqual(@as(?usize, null), pilot.tier_b.index());

    // The loader's 16-bit move only reads the low half of the word, the skill.
    std.mem.writeInt(u32, std.mem.asBytes(&pilot)[@offsetOf(Pilot, "skill")..][0..4], 0x0003_0002, .little);
    try std.testing.expectEqual(Pilot.Skill.high, pilot.skill);
}
