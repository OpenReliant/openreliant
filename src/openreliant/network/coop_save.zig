//! A pilot's local co-op save and profile. The host supplies shared mission state and results.
const std = @import("std");
const engine = @import("openreliant").engine;
const game = engine.game;
const wire = @import("wire.zig");
const save = game.gameflow.save;
const CoopSave = @This();

campaign: game.gameflow.Campaign,
player: engine.input.Player = .{},
tier: u2 = 0,
pilot: game.interface.pilot_roster.Pilot,
saved: engine.interface.loadout.Saved = .{},
wingmen: game.pilots.Wingmen = .{},
restart: ?save.Save = null,

pub fn init(pilot: game.interface.pilot_roster.Pilot) CoopSave {
    return .{ .campaign = .begin(), .pilot = pilot };
}

pub fn saveGame(crew: *CoopSave) save.Game {
    return .{
        .campaign = &crew.campaign,
        .player = &crew.player,
        .tier = &crew.tier,
        .pilot = &crew.pilot,
        .saved = &crew.saved,
        .wingmen = &crew.wingmen,
    };
}

/// WinMain reads each pilot's profile before the first network campaign mission and saves
/// a restart point (0x004A99CC and 0x004A9A9F). A replay restores that attempt's pilot record.
pub fn begin(crew: *CoopSave, number: u16, profile: *const game.gameflow.Profile) void {
    if (crew.restart) |*point| if (point.miss.missionNumber() == number) {
        save.restartLoad(crew.saveGame(), point);
        return;
    };
    crew.campaign.mission = number;
    crew.saveGame().applyProfile(profile);
    crew.restart = crew.saveGame().capture(save.restart_name);
}

pub fn keepLoadout(crew: *CoopSave, fit: engine.interface.loadout.Result) void {
    crew.saved.ship = fit.ship;
    for (&crew.saved.racks, fit.racks) |*rack, kind| rack.* = engine.interface.loadout.tables.Missile.ofType(kind.base());
}

/// mission_end_record (0x00475A90) advances the local save and writes the pilot profile.
/// It skips the autosave in a network game (0x00475BF4).
pub fn record(crew: *CoopSave, result: wire.MissionView, earned: i32, checkpoint: wire.CampaignCheckpoint) ?save.Miss {
    checkpoint.apply(&crew.campaign.variables, &crew.wingmen);
    crew.campaign.variables.mission_success = result.rating;
    crew.player.ending = result.ending;
    crew.player.kills.count = crew.player.kept_kills +| earned;
    crew.player.kills.mission = result.kills;
    const outcome = game.gameflow.endMission(&crew.player, &crew.campaign.variables, result.number, crew.tier, &crew.campaign, &crew.wingmen) orelse {
        crew.player.kills = .{ .count = crew.player.kept_kills };
        return null;
    };
    crew.tier = outcome.tier;
    if (outcome.next == game.gameflow.story_end) return null;
    return crew.saveGame().campaignRecord();
}

test "co-op records follow the local profile and replay starts at the attempt checkpoint" {
    var pilot: game.interface.pilot_roster.Pilot = .{ .difficulty = .hard };
    pilot.call_sign.set("Viper");
    var crew: CoopSave = .init(pilot);
    var profile: game.gameflow.Profile = .new("Viper");
    profile.kills = 17;
    const checkpoint: wire.CampaignCheckpoint = .capture(&crew.campaign.variables, &crew.wingmen);

    crew.begin(1, &profile);
    try std.testing.expectEqual(17, crew.player.kills.count);
    try std.testing.expectEqual(.easy, crew.pilot.difficulty);
    const result: wire.MissionView = .{ .number = 1, .lead = 0, .pilot_slots = 4, .rating = .success, .kills = 3 };
    const first = crew.record(result, 5, checkpoint).?;
    try std.testing.expectEqual(2, first.mission);
    try std.testing.expectEqual(22, first.kills);
    try std.testing.expectEqual(3, first.mission_kills[1]);
    profile.keep(first);
    crew.begin(1, &profile);
    try std.testing.expectEqual(17, crew.player.kills.count);
    var lost = result;
    lost.ending = .destroyed;
    try std.testing.expectEqual(null, crew.record(lost, 4, checkpoint));
    try std.testing.expectEqual(1, crew.campaign.mission);
    try std.testing.expectEqual(17, crew.player.kills.count);
}
