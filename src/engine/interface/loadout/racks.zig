//! The loadout's racks (`loadout.cpp`): the missiles the missile page fits on the chosen ship's
//! missile hardpoints. The game keeps them in the ship's object, as the flight keeps a ship's
//! racks (`GameObject + 0x158`, `gameobj.Rack`), one for each missile hardpoint in the order the
//! flight fits them (`create.hardpoints`), and `loadout_leave` (`0x00442CC0`) writes them to the
//! campaign and the mission.

const std = @import("std");

const create = @import("../../game/create.zig");
const gameobj = @import("../../game/gameobj.zig");
const missiles = @import("../../game/missiles.zig");
const tables = @import("tables.zig");

/// The most missile hardpoints the missile page shows: its Ship Missile objects (`0x00524228`)
/// and its markers' zooms (`0x00524594`), twelve each. No shipped ship has more than eight; the
/// game runs past those arrays for one that has.
pub const max_hardpoints = 12;

/// A rack of the chosen ship's: the missile it takes (`+0x00`, a word) and whether it holds it
/// (`+0x08`, 1 while it does).
pub const Rack = struct {
    missile: tables.Missile = .screamer,
    fitted: bool = false,
};

/// The campaign's saved racks (`campaign_saved_racks`, `0x00562F1A`, a word each): each rack's
/// missile, or null (-1) for none, which `campaign_new` makes every rack.
pub const Saved = [gameobj.max_racks]?tables.Missile;

/// The chosen ship's racks.
pub const Racks = struct {
    racks: [gameobj.max_racks]Rack = @splat(.{}),

    /// The rack `rack_fit` (`0x0044AAC0`) fits `missile` on: the first of the first `limit` that
    /// holds nothing, where one does.
    ///
    /// The game also counts the racks it fits (`rack_count`, `GameObject + 0x150`) and fits none
    /// while it counts `limit` of them. The markers' making clears that count with missiles still
    /// fitted (`markers_make`), so it never counts more than the racks hold, and where it reaches
    /// `limit` every rack is taken: the racks' own flags decide what it would, and OpenReliant
    /// keeps them alone.
    pub fn take(racks: *Racks, missile: tables.Missile, limit: usize) ?usize {
        for (racks.racks[0..@min(limit, racks.racks.len)], 0..) |*rack, index| {
            if (rack.fitted) continue;
            rack.* = .{ .missile = missile, .fitted = true };
            return index;
        }
        return null;
    }

    /// Rack `index` emptied (`rack_empty`, `0x0044AE40`).
    pub fn empty(racks: *Racks, index: usize) void {
        racks.racks[index].fitted = false;
    }

    /// Every one of the first `limit` emptied (`racks_clear`, `0x0044AEE0`).
    pub fn clear(racks: *Racks, limit: usize) void {
        for (racks.racks[0..@min(limit, racks.racks.len)]) |*rack| rack.fitted = false;
    }

    /// The campaign's saved racks as `loadout_leave` writes them: each rack's missile where it
    /// holds it, none otherwise.
    pub fn saved(racks: Racks) Saved {
        var out: Saved = undefined;
        for (&out, racks.racks) |*to, rack| to.* = if (rack.fitted) rack.missile else null;
        return out;
    }

    /// The racks as `loadout_leave` writes them for the mission (`player_loadouts + 4` on): each
    /// rack's missile type, the fuel pod's 10, and none (-1) where it holds nothing.
    pub fn flown(racks: Racks) create.Racks {
        var out: create.Racks = undefined;
        for (&out, racks.racks) |*to, rack| to.* = if (rack.fitted) rack.missile.missileType() else .none;
        return out;
    }
};

/// The missiles `missiles_available` (`0x0044B870`) shows the icons of: those the campaign's
/// `tier` offers, each while fewer than its limit (`tables.missile_limits`) are `carried`, on the
/// ship or flying to it.
pub fn available(tier: u2, carried: [tables.missile_count]u16) tables.MissileSet {
    var set: tables.MissileSet = .{};
    for (std.enums.values(tables.Missile), carried, tables.missile_limits) |missile, count, limit| {
        if (tables.missiles_by_tier[tier].has(missile) and count < limit) set = set.with(missile);
    }
    return set;
}

test "Racks.take" {
    var racks: Racks = .{};
    // The first empty rack takes each missile.
    try std.testing.expectEqual(0, racks.take(.havoc, 3));
    try std.testing.expectEqual(1, racks.take(.bandit, 3));
    racks.empty(0);
    try std.testing.expectEqual(0, racks.take(.imp, 3));
    try std.testing.expectEqual(tables.Missile.imp, racks.racks[0].missile);
    try std.testing.expectEqual(2, racks.take(.hawk, 3));
    // With every rack of the limit fitted, none is.
    try std.testing.expectEqual(null, racks.take(.hawk, 3));
    // A rack taken off takes the next missile, however many were fitted before.
    racks.empty(1);
    try std.testing.expectEqual(1, racks.take(.screamer, 3));
    try std.testing.expectEqual(tables.Missile.screamer, racks.racks[1].missile);
    racks.clear(3);
    try std.testing.expect(!racks.racks[2].fitted);
}

test "Racks.saved and Racks.flown" {
    var racks: Racks = .{};
    _ = racks.take(.fuel_pod, 20);
    _ = racks.take(.raptor, 20);
    racks.empty(0);
    _ = racks.take(.jack_hammer, 20);
    _ = racks.take(.fuel_pod, 20);
    const saved = racks.saved();
    try std.testing.expectEqual(tables.Missile.jack_hammer, saved[0].?);
    try std.testing.expectEqual(tables.Missile.fuel_pod, saved[2].?);
    try std.testing.expectEqual(null, saved[3]);
    // The flight takes the fuel pod as its own type 10, and none where the rack holds nothing.
    const flown = racks.flown();
    try std.testing.expectEqual(missiles.Type.jack_hammer, flown[0]);
    try std.testing.expectEqual(missiles.Type.raptor, flown[1]);
    try std.testing.expectEqual(missiles.Type.fuel_pod, flown[2]);
    try std.testing.expectEqual(missiles.Type.none, flown[19]);
}

test available {
    var carried: [tables.missile_count]u16 = @splat(0);
    // Tier 0 offers the Screamer, the Havoc, the Jack Hammer, the Bandit and the fuel pod.
    try std.testing.expectEqual(@as(u32, 0x21D), @as(u32, @bitCast(available(0, carried))));
    // Three Jack Hammers are the most a ship takes.
    carried[@intFromEnum(tables.Missile.jack_hammer)] = 3;
    try std.testing.expect(!available(0, carried).has(.jack_hammer));
    carried[@intFromEnum(tables.Missile.jack_hammer)] = 2;
    try std.testing.expect(available(0, carried).has(.jack_hammer));
    try std.testing.expect(available(3, carried).has(.solomon));
}
