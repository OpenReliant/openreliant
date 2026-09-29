//! The loadout's bars: where a ship's or a missile's figures stand among the others', in segments,
//! and the figures its panels show beside them. `loadout_load` works them out as it loads
//! (`0x00441B0D`, `0x00441B96`), from the stats the missions fly with (`create.Stats`,
//! `missiles.Table`).
//!
//! The game works them out on the x87. OpenReliant takes its precision to be the 24 bits Direct3D
//! leaves it at, and works in `f32`. **Unverified:** the precision as the loadout loads. The
//! briefing sets 53 bits (`fpu_precision_restore`, `0x00437109`) and draws a frame before it loads
//! the loadout. The shipped stats give the same bars at either precision, but not the same locking
//! times (`lockSeconds`).
//!
//! **Unverified:** the files. `loadout_ship_bars_init` and the two functions after it
//! (`0x00426600` to `0x00426894`) lie after `wgate.cpp`'s known code and before `interf.cpp`'s,
//! among the data of which lie the ITAC's fighter tables they fill (`0x004E5470`, `0x004E57A0`).
//! `range_widen` and `range_scale` (`0x004504C0`, `0x004504F0`) lie after `loadout.cpp`'s known
//! code and before `videoreports.cpp`'s, which has none. They do the loadout's work.

const std = @import("std");
const assert = std.debug.assert;

const formats = @import("../../../formats/stats.zig");
const create = @import("../../game/create.zig");
const gameobj = @import("../../game/gameobj.zig");
const missiles = @import("../../game/missiles.zig");
const tables = @import("tables.zig");

/// The least and the most of a figure among those a bar measures against (`{min, max}`, two
/// floats).
pub const Range = struct {
    min: f32,
    max: f32,

    /// A range of `value` alone, which each range starts from.
    pub fn of(value: f32) Range {
        return .{ .min = value, .max = value };
    }

    /// `range_widen` (`0x004504C0`): takes `value` in. A value below the least becomes the least
    /// without being compared with the most.
    pub fn widen(range: *Range, value: f32) void {
        if (value < range.min) {
            range.min = value;
            return;
        }
        if (value > range.max) range.max = value;
    }

    /// `range_scale` (`0x004504F0`): where `value` stands from `low` to `high`, its share of the
    /// way from the least to the most raised to `exponent`, times `high - low`, plus `low`,
    /// truncated. In a range of one value, every value stands at `high`.
    pub fn scale(range: Range, low: i32, high: i32, exponent: f32, value: f32) i32 {
        if (range.min == range.max) return high;
        const share = (value - range.min) / (range.max - range.min);
        const shaped = std.math.pow(f32, share, exponent);
        return std.math.lossyCast(i32, shaped * @as(f32, @floatFromInt(high - low)) + @as(f32, @floatFromInt(low)));
    }
};

/// The fewest and the most segments a ship's bar fills, and a missile's speed and range
/// (`0x004267B7`, `0x004267B5`, `0x0044B793`, `0x0044B791`).
const least_segments = 3;
const most_segments = 10;

/// The fewest and the most a missile's damage fills (`0x0044B7DA`, `0x0044B7F9`).
const least_damage_segments = 1;
const most_damage_segments = 8;

/// What every bar's share is raised to: 1, a straight line (`0x004267B0`).
const bar_exponent: f32 = 1;

/// The ship types of the fighters the ITAC lists (`0x44` bytes a fighter, its type at `+0x40`):
/// the alliance's (`loadout_alliance_ships`, `0x004E5470`), which are the loadout's ships, and
/// the Coalition's (`loadout_coalition_ships`, `0x004E57A0`).
pub const alliance_fighters = [_]u8{ 4, 3, 2, 5, 1, 7, 11, 0, 9, 10, 6, 8 };
pub const coalition_fighters = [_]u8{ 42, 49, 39, 40, 50, 44, 43, 41, 46 };

/// The ranges the ships' bars measure against (`0x0051D38C` on).
pub const ShipRanges = struct {
    /// `max_speed` (`0x0051D38C`).
    speed: Range,
    /// `yaw_rate`, of the fighters on the player's side (`0x0051D3A4`).
    friendly_agility: Range,
    /// `yaw_rate`, of the fighters on the other sides (`0x0051D42C`).
    other_agility: Range,
    /// `inertia` (`0x0051D3B4`), which the Acceleration row shows.
    acceleration: Range,
    /// `0x0051D440`.
    shield_power: Range,
    /// `0x0051D438`.
    shield_recharge: Range,
    /// `armor_class` (`0x0051D3AC`).
    armor: Range,

    /// `loadout_ship_bars_init` (`0x00426600`)'s ranges: each starts from the figure of the
    /// alliance's first fighter, the other sides' agility from the Coalition's first, and takes in
    /// every fighter of both lists.
    pub fn init(stats: *const create.Stats) ShipRanges {
        const first = alliance_fighters[0];
        const flight = stats.flight[first];
        const combat = stats.combat[first];
        var ranges: ShipRanges = .{
            .speed = .of(flight.max_speed),
            .friendly_agility = .of(flight.yaw_rate),
            .other_agility = .of(stats.flight[coalition_fighters[0]].yaw_rate),
            .acceleration = .of(flight.inertia),
            .shield_power = .of(@floatFromInt(combat.shield_power)),
            .shield_recharge = .of(combat.shield_recharge),
            .armor = .of(@floatFromInt(combat.armor_class)),
        };
        for (alliance_fighters ++ coalition_fighters) |ship_type| ranges.widen(stats, ship_type);
        return ranges;
    }

    /// `loadout_ship_widen_ranges` (`0x00426700`): takes a fighter's figures in.
    fn widen(ranges: *ShipRanges, stats: *const create.Stats, ship_type: u8) void {
        const flight = stats.flight[ship_type];
        const combat = stats.combat[ship_type];
        ranges.speed.widen(flight.max_speed);
        switch (combat.side) {
            .friendly => ranges.friendly_agility.widen(flight.yaw_rate),
            else => ranges.other_agility.widen(flight.yaw_rate),
        }
        ranges.acceleration.widen(flight.inertia);
        ranges.shield_power.widen(@floatFromInt(combat.shield_power));
        ranges.shield_recharge.widen(combat.shield_recharge);
        ranges.armor.widen(@floatFromInt(combat.armor_class));
    }

    /// The agility range a fighter on `side` is measured against.
    fn agility(ranges: ShipRanges, side: gameobj.Side(i16)) Range {
        return switch (side) {
            .friendly => ranges.friendly_agility,
            else => ranges.other_agility,
        };
    }
};

/// What `loadout_ship_bars` (`0x00426790`) writes into a fighter's entry (`+0x0E` to `+0x1B`): its
/// bars, from 3 to 10 segments, and its afterburner fuel, which its row shows as a number.
pub const ShipBars = extern struct {
    speed: i16,
    agility: i16,
    acceleration: i16,
    shield_power: i16,
    shield_recharge: i16,
    /// The low half of `ShipCombat.afterburner_fuel`.
    afterburner_fuel: i16,
    armor: i16,

    /// `loadout_ship_bars`: a fighter of `ship_type`'s.
    pub fn of(ranges: ShipRanges, stats: *const create.Stats, ship_type: u8) ShipBars {
        const flight = stats.flight[ship_type];
        const combat = stats.combat[ship_type];
        return .{
            .speed = bar(ranges.speed, flight.max_speed),
            .agility = bar(ranges.agility(combat.side), flight.yaw_rate),
            .acceleration = bar(ranges.acceleration, flight.inertia),
            .shield_power = bar(ranges.shield_power, @floatFromInt(combat.shield_power)),
            .shield_recharge = bar(ranges.shield_recharge, combat.shield_recharge),
            .afterburner_fuel = @truncate(combat.afterburner_fuel),
            .armor = bar(ranges.armor, @floatFromInt(combat.armor_class)),
        };
    }

    /// A ship's bar of `value`, kept in 16 bits as the entry keeps it.
    fn bar(range: Range, value: f32) i16 {
        return @truncate(range.scale(least_segments, most_segments, bar_exponent, value));
    }

    comptime {
        assert(@offsetOf(ShipBars, "afterburner_fuel") == 0x18 - 0x0E);
        assert(@offsetOf(ShipBars, "armor") == 0x1A - 0x0E);
    }
};

/// The figures `loadout_load` gives the loadout's ships (`0x00441B12` to `0x00441B94`), after
/// `loadout_ship_bars_init` has worked out the fighters' bars: each ship takes those of its
/// fighter (`fighterFor`), and keeps its crew.
pub fn shipFigures(stats: *const create.Stats) [tables.ship_count]tables.ShipFigures {
    const ranges: ShipRanges = .init(stats);
    var figures: [tables.ship_count]tables.ShipFigures = undefined;
    for (&figures, tables.ships, 0..) |*figure, ship, index| {
        const bars: ShipBars = .of(ranges, stats, fighterFor(index));
        figure.* = .{
            bars.speed,
            bars.acceleration,
            bars.agility,
            bars.shield_power,
            bars.shield_recharge,
            bars.armor,
            bars.afterburner_fuel,
            ship.crew,
        };
    }
    return figures;
}

/// The ship type of the fighter whose bars `loadout_load` gives the loadout's ship `index`
/// (`0x00441B19`): the first of the alliance's whose type is `index`, or, where there is none, the
/// fighter after the alliance's last, the Coalition's first.
fn fighterFor(index: usize) u8 {
    for (alliance_fighters) |ship_type| {
        if (ship_type == index) return ship_type;
    }
    return coalition_fighters[0];
}

/// The ranges the missiles' bars measure against, over every missile type.
pub const MissileRanges = struct {
    /// `max_speed` (`0x0052375C`).
    speed: Range,
    /// How far it flies (`0x00524728`, `flightRange`).
    range: Range,
    /// `damageOf` (`0x00524738`).
    damage: Range,

    /// `loadout_missile_bars_init` (`0x0044B680`)'s ranges: each starts from the first type's
    /// figure, and takes in every type's (`loadout_missile_widen_ranges`, `0x0044B710`), the
    /// Jackhammer's damage (`0x0044B745`) excepted.
    pub fn init(table: *const missiles.Table) MissileRanges {
        var ranges: MissileRanges = .{
            .speed = .of(table.flight[0].max_speed),
            .range = .of(flightRange(table, 0)),
            .damage = .of(damageOf(table, 0)),
        };
        for (0..missiles.type_count) |index| {
            ranges.speed.widen(table.flight[index].max_speed);
            ranges.range.widen(flightRange(table, index));
            if (index != @intFromEnum(missiles.Type.jack_hammer)) ranges.damage.widen(damageOf(table, index));
        }
        return ranges;
    }
};

/// How far a missile of type `index` flies: its `flight_time` in ticks times its speed.
fn flightRange(table: *const missiles.Table, index: usize) f32 {
    const product = @as(f64, @floatFromInt(table.stats[index].flight_time)) * table.flight[index].max_speed;
    return @floatCast(product);
}

/// What a missile of type `index` does to a shield and to a hull, together.
fn damageOf(table: *const missiles.Table, index: usize) f32 {
    const damage = table.stats[index].damage;
    return damage.shield + damage.hull;
}

/// What `loadout_missile_bars_init` writes into a missile's record (`+0x100` to `+0x10F`), the
/// figures its rows show: its locking time in seconds, and its bars, -1 for a figure it has none
/// of.
pub const MissileBars = extern struct {
    lock_seconds: i32,
    speed: i32,
    range: i32,
    damage: i32,

    /// A figure a missile has none of, which its panel shows as `-`.
    pub const none = -1;

    /// `figure` as the missile's panel takes it: none where it is `none`.
    pub fn shown(figure: i32) ?i32 {
        return if (figure == none) null else figure;
    }

    /// The Jackhammer's damage (`0x0044B81A`): all ten segments, where the range leaves out its
    /// own damage, which lies far past the others'.
    const jack_hammer_damage = 10;

    /// `loadout_missile_bars` (`0x0044B770`), with the locking time worked out before it
    /// (`0x0044B6E0`), for a missile of `missile`'s type. The Screamer and the Solomon, which need
    /// no lock, have no locking time, and the fuel pod none of the bars. A type past the tables
    /// has no figures.
    pub fn of(ranges: MissileRanges, table: *const missiles.Table, missile: missiles.Type) MissileBars {
        const index = missile.index() orelse return .{ .lock_seconds = none, .speed = none, .range = none, .damage = none };
        var bars: MissileBars = .{
            .lock_seconds = lockSeconds(table.stats[index].lock_time),
            .speed = ranges.speed.scale(least_segments, most_segments, bar_exponent, table.flight[index].max_speed),
            .range = ranges.range.scale(least_segments, most_segments, bar_exponent, flightRange(table, index)),
            .damage = ranges.damage.scale(least_damage_segments, most_damage_segments, bar_exponent, damageOf(table, index)),
        };
        switch (missile) {
            .screamer, .solomon => bars.lock_seconds = none,
            .jack_hammer => bars.damage = jack_hammer_damage,
            .fuel_pod => {
                bars.speed = none;
                bars.range = none;
                bars.damage = none;
            },
            else => {},
        }
        return bars;
    }

    /// The figures in the order the rows show them.
    pub fn figures(bars: MissileBars) tables.MissileFigures {
        return @bitCast(bars);
    }
};

/// A locking time of `ticks` in whole seconds (`0x0044B6E0`): `ticks` times
/// `formats.Missile.seconds_per_lock_unit`, truncated, which comes out whole for a whole number of
/// seconds at 24 bits. At 53 bits the product falls just short, and every shipped missile's locking
/// time would show a second less.
fn lockSeconds(ticks: i32) i32 {
    const product: f32 = @floatCast(@as(f64, @floatFromInt(ticks)) * formats.Missile.seconds_per_lock_unit);
    return std.math.lossyCast(i32, product);
}

/// `loadout_missile_bars_init` (`0x0044B680`): the figures of each of the loadout's missiles,
/// each from the missile type of its own number. The fuel pod's therefore come from the torpedo,
/// which its panel shows none of (`missile_info_draw`).
///
/// **Fix:** the game goes on to the eleventh type, the fuel pod's, and writes its figures past the
/// ten records, over `0x004EE640` to `0x004EE64F`, in the table at `0x004EE5B0` that the code after
/// this file reads (`0x00450A90`). OpenReliant fills the ten; the eleventh type still counts in the
/// ranges.
pub fn missileFigures(table: *const missiles.Table) [tables.missile_count]tables.MissileFigures {
    const ranges: MissileRanges = .init(table);
    var figures: [tables.missile_count]tables.MissileFigures = undefined;
    for (&figures, 0..) |*figure, index| {
        const missile: missiles.Type = @enumFromInt(@as(i16, @intCast(index)));
        figure.* = MissileBars.of(ranges, table, missile).figures();
    }
    return figures;
}

test Range {
    var range: Range = .of(5);
    range.widen(2);
    range.widen(9);
    try std.testing.expectEqual(Range{ .min = 2, .max = 9 }, range);
    // A value below the least is not compared with the most.
    range.widen(1);
    try std.testing.expectEqual(Range{ .min = 1, .max = 9 }, range);

    const from: Range = .{ .min = 100, .max = 300 };
    try std.testing.expectEqual(3, from.scale(3, 10, 1, 100));
    try std.testing.expectEqual(10, from.scale(3, 10, 1, 300));
    // Half the way along 7 segments is 3.5 of them, truncated.
    try std.testing.expectEqual(6, from.scale(3, 10, 1, 200));
    // Squared, half the way is a quarter: 1.75 of them.
    try std.testing.expectEqual(4, from.scale(3, 10, 2, 200));
    // A range of one value puts everything at the top.
    try std.testing.expectEqual(10, Range.of(4).scale(3, 10, 1, 4));
}

/// Stats with every fighter of the ITAC's lists at a speed of 100, a yaw rate of 0.05, an inertia
/// of 0.9, shield power 10, recharge 10 and armour 20.
fn testShipStats() create.Stats {
    var stats: create.Stats = .initial;
    for (alliance_fighters ++ coalition_fighters) |ship_type| {
        stats.flight[ship_type].max_speed = 100;
        stats.flight[ship_type].yaw_rate = 0.05;
        stats.flight[ship_type].inertia = 0.9;
        stats.combat[ship_type].shield_power = 10;
        stats.combat[ship_type].shield_recharge = 10;
        stats.combat[ship_type].armor_class = 20;
    }
    return stats;
}

test ShipRanges {
    var stats = testShipStats();
    stats.flight[0].max_speed = 300;
    stats.flight[42].max_speed = 50;
    // The Coalition's agility is measured apart from the alliance's.
    stats.flight[49].yaw_rate = 0.5;
    stats.flight[1].yaw_rate = 0.02;
    const ranges: ShipRanges = .init(&stats);
    try std.testing.expectEqual(Range{ .min = 50, .max = 300 }, ranges.speed);
    try std.testing.expectEqual(Range{ .min = 0.02, .max = 0.05 }, ranges.friendly_agility);
    try std.testing.expectEqual(Range{ .min = 0.05, .max = 0.5 }, ranges.other_agility);
    try std.testing.expectEqual(Range.of(20), ranges.armor);
}

test shipFigures {
    var stats = testShipStats();
    stats.flight[0].max_speed = 300;
    stats.flight[5].max_speed = 200;
    stats.combat[3].shield_power = 28;
    stats.combat[2].afterburner_fuel = 0x12345;
    stats.combat[7].armor_class = 30;
    const figures = shipFigures(&stats);
    // Ship 0 is the fastest, ship 5 halfway, the rest the slowest.
    try std.testing.expectEqual(10, figures[0][0]);
    try std.testing.expectEqual(6, figures[5][0]);
    try std.testing.expectEqual(3, figures[1][0]);
    // Where every fighter has the same figure, every bar is full.
    try std.testing.expectEqual(10, figures[4][1]);
    try std.testing.expectEqual(10, figures[4][4]);
    try std.testing.expectEqual(10, figures[3][3]);
    try std.testing.expectEqual(3, figures[4][3]);
    try std.testing.expectEqual(10, figures[7][5]);
    // The afterburner fuel's low half as a number, then the crew.
    try std.testing.expectEqual(0x2345, figures[2][6]);
    try std.testing.expectEqual(3, figures[2][7]);
    try std.testing.expectEqual(2, figures[11][7]);
}

test fighterFor {
    for (0..tables.ship_count) |index| try std.testing.expectEqual(index, fighterFor(index));
    try std.testing.expectEqual(42, fighterFor(tables.ship_count));
}

test missileFigures {
    var table: missiles.Table = .initial;
    for (&table.flight, &table.stats, 0..) |*flight, *stats, index| {
        flight.max_speed = 400;
        stats.flight_time = 6000;
        stats.damage = .{ .shield = 100, .hull = 200 };
        stats.lock_time = @intCast(100 * index);
    }
    table.flight[1].max_speed = 600;
    table.stats[5].damage = .{ .shield = 500, .hull = 350 };
    table.stats[3].damage = .{ .shield = 5000, .hull = 2 };
    table.stats[2].lock_time = 250;
    // The eleventh type, the fuel pod, flies nowhere and hurts nothing: the ranges start from 0.
    table.flight[10].max_speed = 0;
    table.stats[10].flight_time = 0;
    table.stats[10].damage = .{ .shield = 0, .hull = 0 };

    const figures = missileFigures(&table);
    // A whole number of seconds, or its whole part.
    try std.testing.expectEqual(4, figures[4][0]);
    try std.testing.expectEqual(2, figures[2][0]);
    // The Screamer and the Solomon need no lock.
    try std.testing.expectEqual(MissileBars.none, figures[0][0]);
    try std.testing.expectEqual(MissileBars.none, figures[6][0]);
    // Speed and range from 3 to 10, from nothing to the most.
    try std.testing.expectEqual(10, figures[1][1]);
    try std.testing.expectEqual(7, figures[0][1]);
    try std.testing.expectEqual(10, figures[1][2]);
    // Damage from 1 to 8, the Jackhammer's left out of the range and set full.
    try std.testing.expectEqual(8, figures[5][3]);
    try std.testing.expectEqual(3, figures[0][3]);
    try std.testing.expectEqual(10, figures[3][3]);
    // The fuel pod's record takes the torpedo's figures.
    try std.testing.expectEqual(9, figures[9][0]);
    try std.testing.expectEqual(7, figures[9][1]);

    // The eleventh type, which only the game works out, has none of the bars.
    const fuel_pod: MissileBars = .of(.init(&table), &table, .fuel_pod);
    try std.testing.expectEqual(MissileBars{ .lock_seconds = 10, .speed = -1, .range = -1, .damage = -1 }, fuel_pod);
}

test lockSeconds {
    try std.testing.expectEqual(3, lockSeconds(300));
    try std.testing.expectEqual(2, lockSeconds(299));
    try std.testing.expectEqual(0, lockSeconds(0));
}
