//! `C:\lancer\game\dmscenarios.cpp`: the multiplayer game's scenarios. **Unverified:** that
//! `dm_scenario_mission` is this file's: it lies before the file's known code, and reads the
//! scenarios' table, which lies beside the file's name.
//!
//! Ported so far: whether a mission is one of the scenarios' maps (`isScenario`).

const std = @import("std");

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
