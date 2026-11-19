//! `C:\lancer\game\dmscenarios.cpp`: the multiplayer game's scenarios. **Unverified:** that
//! `dm_scenario_mission` is this file's: it lies before the file's known code, and reads the
//! scenarios' table, which lies beside the file's name.
//!
//! Stock arena missions and their strings, as used by the mission loader and game mode picker.

const std = @import("std");
const gameobj = @import("gameobj.zig");

/// The stock scenarios and their display strings, in `dm_scenarios` table order.
pub const Scenario = enum(u8) {
    asteroid_field,
    nuclear_threat,
    dark_reign,
    tag_bomb,
    hunt_the_shadow,
    vampires,

    pub fn mission(scenario: Scenario) u16 {
        return missions[@backingInt(scenario)];
    }

    pub fn nameString(scenario: Scenario) u16 {
        return 0x2AF + @as(u16, @backingInt(scenario));
    }

    pub fn descriptionString(scenario: Scenario) u16 {
        return 0x2B5 + @as(u16, @backingInt(scenario));
    }

    pub fn teamPlayString(scenario: Scenario) u16 {
        return 0x2BB + @as(u16, @backingInt(scenario));
    }

    pub fn hasPowerUps(scenario: Scenario) bool {
        return switch (scenario) {
            .asteroid_field, .dark_reign, .tag_bomb, .hunt_the_shadow => true,
            else => false,
        };
    }

    pub fn available(scenario: Scenario) bool {
        return switch (scenario) {
            .asteroid_field, .nuclear_threat, .dark_reign, .tag_bomb, .hunt_the_shadow => true,
            else => false,
        };
    }
};

/// The fighters offered by `session_loadout_screen` (0x0044B950), in ship type order.
pub const Fighter = enum(u8) {
    predator,
    naginata,
    grendel,
    crusader,
    coyote,
    mirage,
    tempest,
    patriot,
    wolverine,
    reaper,
    shroud,
    phoenix,

    pub fn kind(fighter: Fighter) gameobj.Type {
        return @fromBackingInt(@intCast(@backingInt(fighter)));
    }

    pub fn nameString(fighter: Fighter) u16 {
        return 0x2C7 + @as(u16, @backingInt(fighter));
    }
};

comptime {
    for (std.enums.values(Fighter)) |fighter| {
        const original: gameobj.GameType = @fromBackingInt(@intCast(@backingInt(fighter)));
        std.debug.assert(std.mem.eql(u8, @tagName(fighter), @tagName(original)));
    }
    std.debug.assert(std.enums.values(Scenario).len == missions.len);
}

/// The mission each scenario is played in (`dm_scenarios`, `0x0050C790`: six `0x40`-byte records,
/// each with the mission at offset 8, `0x0050C798` for the first).
pub const missions = [_]u16{ 85, 82, 81, 83, 84, 87 };

/// `dm_scenario_mission` (`0x004B2D30`): whether mission `number` is one of the scenarios' maps,
/// which `mission_start` keeps (`multiplayer_mission`, `0x00582E8C`) and the radio's menu offers no
/// base in.
pub fn isScenario(number: u16) bool {
    return std.mem.findScalar(u16, &missions, number) != null;
}

test isScenario {
    try std.testing.expect(isScenario(81));
    try std.testing.expect(isScenario(87));
    try std.testing.expect(!isScenario(86));
    try std.testing.expect(!isScenario(1));
}
