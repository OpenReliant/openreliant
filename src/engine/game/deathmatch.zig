//! `C:\lancer\game\deathmatch.cpp`: the players' tallies and the rules of a multiplayer game.
//! **Unverified:** that `kills_add` is this file's: it lies after the file's known code, before
//! `dmscenarios.cpp`'s, among the code that keeps each player's tally.
//!
//! Ported so far: the player's own kills (`addKills`).

const std = @import("std");

const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const input = @import("../input.zig");

/// `kills_add` (`0x004B14F0`): adds `count` kills to the player of `slot`: to the pilot's own,
/// `skull_count`, where that is the local player, and one to the mission's, up to the 27th
/// (`0x004B1534`). **Not ported:** each player's tally (`0x005DB684`) and a team's in a
/// multiplayer game, and what it tells a multiplayer game when asked to.
pub fn addKills(player: *input.Player, all: *const create.Objects, slot: u16, count: i32) void {
    if (slot != all.player) return;
    player.kills.count += count;
    if (all.mission_number <= last_counted_mission) player.kills.mission +|= 1;
}

/// The last mission whose kills `kills_add` counts (`0x004B152F`).
const last_counted_mission = 27;

test addKills {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const other = try mission.add(.sabre, .{ 0, 0, 1000 });
    addKills(&mission.player, mission.objects, player, 1);
    addKills(&mission.player, mission.objects, player, 2);
    // Another player's kills are not the local pilot's.
    addKills(&mission.player, mission.objects, other, 5);
    try std.testing.expectEqual(3, mission.player.kills.count);
    // The mission counts them one a ship, up to the 27th mission.
    try std.testing.expectEqual(2, mission.player.kills.mission);
    mission.objects.mission_number = last_counted_mission + 1;
    addKills(&mission.player, mission.objects, player, 1);
    try std.testing.expectEqual(2, mission.player.kills.mission);
}
