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
        return scenario.record().mission;
    }

    pub fn nameString(scenario: Scenario) u16 {
        return scenario.record().strings.name;
    }

    pub fn descriptionString(scenario: Scenario) u16 {
        return scenario.record().strings.description;
    }

    pub fn teamPlayString(scenario: Scenario) u16 {
        return scenario.record().strings.teams;
    }

    pub fn hasPowerUps(scenario: Scenario) bool {
        return switch (scenario.record().rules) {
            .deathmatch, .six_beacons => false,
            .asteroid_field, .dark_reign, .tag_bomb, .hunt_the_shadow, .vampires => true,
        };
    }

    pub fn record(scenario: Scenario) *const Record {
        return original.getPtrConst(scenario);
    }

    pub fn forMission(number: u16) ?Scenario {
        for (std.enums.values(Scenario)) |scenario| {
            if (scenario.mission() == number) return scenario;
        }
        return null;
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
        const ship_type: gameobj.GameType = @fromBackingInt(@intCast(@backingInt(fighter)));
        std.debug.assert(std.mem.eql(u8, @tagName(fighter), @tagName(ship_type)));
    }
}

/// Each rule stores the settings its simulation uses. The host keeps the live round state separately.
pub const Rules = union(enum) {
    deathmatch,
    asteroid_field,
    six_beacons,
    dark_reign: struct { target_delay: i32 },
    tag_bomb: struct { fuse: u16, detonation_frags: i32 },
    hunt_the_shadow: struct { bonus_frags: i32 },
    vampires: struct { last_human_bonus: i32 },
};

/// The mission field comes from dm_scenarios (0x0050C790, offset 8 in each 0x40-byte row).
/// The rules select the host's round state. The lobby uses the English text when a string is missing.
pub const Record = struct {
    mission: u16,
    strings: struct { name: u16, description: u16, teams: u16 },
    teams: enum { most_frags, controls_tower, none },
    rules: Rules,
    name: []const u8,
    description: []const u8,
};

pub const original: std.EnumArray(Scenario, Record) = .init(.{
    .asteroid_field = .{
        .mission = 85,
        .strings = .{ .name = 0x2AF, .description = 0x2B5, .teams = 0x2BB },
        .teams = .most_frags,
        .rules = .asteroid_field,
        .name = "Asteroid Field",
        .description = "Fight for the most kills in an asteroid field.",
    },
    .nuclear_threat = .{
        .mission = 82,
        .strings = .{ .name = 0x2B0, .description = 0x2B6, .teams = 0x2BC },
        .teams = .none,
        .rules = .six_beacons,
        .name = "Nuclear Threat",
        .description = "Collect six beacons and take them to the gate. Losing your ship drops the beacons you carry.",
    },
    .dark_reign = .{
        .mission = 81,
        .strings = .{ .name = 0x2B1, .description = 0x2B7, .teams = 0x2BD },
        .teams = .controls_tower,
        .rules = .{ .dark_reign = .{ .target_delay = 1000 } },
        .name = "Dark Reign",
        .description = "Recover the comms relay to keep the Dark Reign from targeting you and earn credit for its kills.",
    },
    .tag_bomb = .{
        .mission = 83,
        .strings = .{ .name = 0x2B2, .description = 0x2B8, .teams = 0x2BE },
        .teams = .most_frags,
        // `tag_bomb_init` (`0x004B4340`) and `tag_bomb_pilot_destroyed` (`0x004B4460`) set 0x1130
        // ticks. The display adds a second, so it starts at 45.
        .rules = .{ .tag_bomb = .{ .fuse = 4400, .detonation_frags = 3 } },
        .name = "Tag Bomb",
        .description = "The first pilot destroyed respawns with an active bomb. Hit another pilot with your guns to pass it before your timer expires.",
    },
    .hunt_the_shadow = .{
        .mission = 84,
        .strings = .{ .name = 0x2B3, .description = 0x2B9, .teams = 0x2BF },
        .teams = .most_frags,
        .rules = .{ .hunt_the_shadow = .{ .bonus_frags = 5 } },
        .name = "Hunt the Shadow",
        .description = "The first pilot to score a kill becomes the Shadow. The Shadow is cloaked and has no shields. Kill the Shadow to take over.",
    },
    .vampires = .{
        .mission = 87,
        .strings = .{ .name = 0x2B4, .description = 0x2BA, .teams = 0x2C0 },
        .teams = .none,
        .rules = .{ .vampires = .{ .last_human_bonus = 5 } },
        .name = "Vampires",
        .description = "The first pilot to die becomes a vampire. Vampires infect human pilots by killing them. The last human earns five frags and the roles reset.",
    },
});

/// `dm_scenario_mission` (`0x004B2D30`): whether mission `number` is one of the scenarios' maps,
/// which `mission_start` keeps (`multiplayer_mission`, `0x00582E8C`) and the radio's menu offers no
/// base in.
pub fn isScenario(number: u16) bool {
    return Scenario.forMission(number) != null;
}

test isScenario {
    for (std.enums.values(Scenario)) |scenario| try std.testing.expectEqual(scenario, Scenario.forMission(scenario.mission()));
    try std.testing.expect(isScenario(81));
    try std.testing.expect(isScenario(87));
    try std.testing.expect(!isScenario(86));
    try std.testing.expect(!isScenario(1));
}
