//! `C:\lancer\game\gameflow.cpp`: the campaign's flow from one mission to the next.
//! **Unverified:** that `campaign_new`, `profile_load`, `mission_reset_variables` and
//! `mission_end_record` are this file's: they lie beside the file's known code, between
//! `explode.cpp`'s and `gameobj.cpp`'s.
//!
//! Ported so far: the campaign as it begins and as each attempt at a mission starts (`Campaign`),
//! the call sign the pilot's profile gives (`profileCallSign`), what a mission's end makes of the
//! campaign (`endMission`): the pilot's rank, the kills kept, the rating kept, the tier, the medal,
//! the ribbon and the next mission; and the saved games (`save`).

const std = @import("std");

const input = @import("../input.zig");
const vm = @import("../vm.zig");
const Ending = @import("main.zig").Ending;

pub const save = @import("gameflow/save.zig");

/// How many of the game's variables `campaign_new` clears, from the first on (`0x004751B4`).
const cleared_variables = 32;

/// The game's variables a new campaign sets to 1 (`campaign_new`), by number: the campaign's flags,
/// such as `ghost_alive`, and `mission_success`, which each attempt clears again. The rest of the
/// campaign's start at 0.
const campaign_flags = [_]u8{ 14, 16, 17, 18, 19, 20, 21, 5, 22, 23, 29, 30, 31, 32, 35, 13, 8, 7, 6, 36 };

/// `campaign_new` (`0x004751B0`) as a new campaign begins, which `WinMain` runs as the game starts:
/// clears the first 32 of the game's variables, then sets the campaign's flags (`campaign_flags`).
/// `Campaign.begin` sets up the rest of the campaign, mission 1 as the next and each mission's
/// records, and `save.Game.clearPilot` the pilot's tallies. **Not ported:** the pilot's profile but
/// for its call sign (`profileCallSign`) ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
pub fn newCampaign(variables: *vm.Variables) void {
    for (0..cleared_variables) |index| variables.slot(@intCast(index)).* = 0;
    for (campaign_flags) |index| variables.slot(index).* = 1;
}

/// The pilot's profile, `profile.bin` in the game's folder (`0x00500ACC`): the 0xD0 bytes at
/// `0x00562CF8`, the pilot's name 32 bytes from the fourth (`0x00562CFC`). `campaign_new` reads it,
/// or makes a new one under the name PLAYER where there is none.
pub const profile_name = "profile.bin";
pub const profile_size = 0xD0;
const pilot_name_at = 4;
const pilot_name_size = 32;

/// The call sign `profile_load` (`0x00475390`) gives the pilot as `campaign_new` reads the profile,
/// `bytes` as far as the file has them: the name the profile keeps, up to its terminator
/// (`0x004753C5`). Where the game's folder has no profile, `campaign_new` makes one and leaves the
/// call sign as it was, empty as the game starts.
///
/// **Fix:** the game copies the name up to its terminator wherever that lies; OpenReliant keeps to
/// its 32 bytes.
pub fn profileCallSign(bytes: []const u8) []const u8 {
    const name = bytes[@min(bytes.len, pilot_name_at)..@min(bytes.len, pilot_name_at + pilot_name_size)];
    return std.mem.sliceTo(name, 0);
}

/// The tier of the loadout each mission's end brings the campaign to, by mission from the first
/// (`0x005009D8`, a byte a mission): the 11th's 1, the 19th's 2 and the 21st's 3, the rest none.
/// The loadout raises `campaign_tier` to the highest of those before its mission, reading at most
/// 28 (`loadout_load`, `0x00441AA9`).
pub const mission_tiers = [28]u2{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0 };

/// `mission_reset_variables` (`0x00475620`) before each attempt at a mission: clears the variables
/// that belong to the attempt.
pub fn resetVariables(variables: *vm.Variables) void {
    variables.ready = .{};
    variables.backup_available = 0;
    variables.mission_over = 0;
    variables.landing_cleared = 0;
    variables.ion_cannons_hold_lock = 0;
    variables.mission_success = .failure;
    variables.objectives_met = 0;
    variables._unknown_34 = 0;
}

/// The campaign as it goes from one mission to the next.
pub const Campaign = struct {
    /// The game's variables as the last mission the pilot came through left them, which each
    /// attempt at the mission starts from, less the attempt's own (`attempt`): `WinMain` saves the
    /// game as a mission's attempts begin and loads it again for each replay (`restart_save`,
    /// `0x00475D20`; `restart_load`, `0x00475D30`).
    variables: vm.Variables,
    /// The mission the campaign is at, the next to fly (`mission_number`, `0x00562DC8`), which
    /// each mission's end moves on (`endMission`).
    mission: u16 = first_mission,
    /// How many times a nanny ship has picked the ejected pilot up (`0x00562ED4`).
    pickups: u8 = 0,
    /// Each mission's record, by its number less one, as the ITAC's debriefings show it
    /// (`MissionRecord`).
    records: [last_mission]MissionRecord = @splat(.{}),
    /// The medals the pilot has been awarded (`pilot_medals`, `0x00562DFC`).
    medals: std.EnumSet(Medal) = .initEmpty(),
    /// The ribbons the pilot has been awarded, ribbon 1 first (`pilot_ribbons`, `0x00562E14`).
    ribbons: Ribbons = .initEmpty(),
    /// The pilots of the player's wing, Alpha 1 to 6 (`alpha_pilots`, `0x0058A958`): -1 for the
    /// player, then the five wingmen's, as `campaign_pilots_reset` (`0x0049CD20`) starts them for
    /// START GAME.
    wing: save.Wing = .{ -1, 0x55, 0x6C, 0x56, 0xAC, 7 },
    /// The first of the pool of pilots that replace the wingmen who die (`pilot_pool`,
    /// `0x005047D0`), the one record of it a save keeps, as the executable starts it.
    first_replacement: save.Replacement = .{ .pilot = 119, .status = .free },
    /// What the saves keep that a single-player campaign leaves as it is: the local player's
    /// deaths in a multiplayer mission (`mp_deaths`, `0x00562DF8`), and the seed of the ITAC's
    /// KILLBOARD (`killboard_seed`, `0x00562F10`).
    mp_deaths: i32 = 0,
    killboard_seed: i32 = 0,

    /// A new campaign (`campaign_new`).
    pub fn begin() Campaign {
        var variables: vm.Variables = .{};
        newCampaign(&variables);
        return .{ .variables = variables };
    }

    /// The game's variables an attempt at the mission starts with.
    pub fn attempt(campaign: Campaign) vm.Variables {
        var variables = campaign.variables;
        resetVariables(&variables);
        return variables;
    }

    /// Mission `mission`'s record; none outside the campaign's missions.
    pub fn record(campaign: *Campaign, mission: u16) ?*MissionRecord {
        if (mission == 0 or mission > campaign.records.len) return null;
        return &campaign.records[mission - 1];
    }

    /// Mission `mission`'s record as it stands; an empty one outside the campaign's missions.
    pub fn kept(campaign: Campaign, mission: u16) MissionRecord {
        if (mission == 0 or mission > campaign.records.len) return .{};
        return campaign.records[mission - 1];
    }

    /// `pickup_count` (`0x00475A60`), as a nanny ship picks the ejected pilot up in mission
    /// `mission`: whether this is past the pickups the pilot is allowed, which transfers the pilot
    /// off the carrier. Otherwise the mission's record keeps the count (`0x00475A80`).
    pub fn pickedUp(campaign: *Campaign, mission: u16) bool {
        campaign.pickups +|= 1;
        if (campaign.pickups > allowed_pickups) return true;
        if (campaign.record(mission)) |kept_record| kept_record.pickups = campaign.pickups;
        return false;
    }

    /// How many pickups the pilot is allowed (`0x00475A68`).
    const allowed_pickups = 2;
};

/// The game's variables as an attempt at a mission of a new campaign starts, as the first mission's
/// do, and every mission's the front end flies outside the campaign.
pub fn restartPoint() vm.Variables {
    return Campaign.begin().attempt();
}

test restartPoint {
    var variables: vm.Variables = .{};
    variables.landing_cleared = 1;
    variables.last_success = .success;
    variables.countdown = 30;
    variables.beyond[0] = 5;
    newCampaign(&variables);
    // The first 32 cleared, the campaign's flags set, the rest left.
    try std.testing.expectEqual(0, variables.landing_cleared);
    try std.testing.expectEqual(.failure, variables.last_success);
    try std.testing.expectEqual(1, variables.ghost_alive);
    try std.testing.expectEqual(.partial_failure, variables.mission_success);
    try std.testing.expectEqual(1, variables._unknown_35[1]);
    try std.testing.expectEqual(30, variables.countdown);
    try std.testing.expectEqual(5, variables.beyond[0]);

    // Each attempt clears its own, and keeps the campaign's.
    variables.ready.jump = .newly;
    variables.objectives_met = 1;
    variables.ion_cannons_hold_lock = 1;
    resetVariables(&variables);
    try std.testing.expectEqual(@as(vm.Variables, .{}).ready, variables.ready);
    try std.testing.expectEqual(0, variables.objectives_met);
    try std.testing.expectEqual(0, variables.ion_cannons_hold_lock);
    try std.testing.expectEqual(.failure, variables.mission_success);
    try std.testing.expectEqual(1, variables.ghost_alive);

    const start = restartPoint();
    try std.testing.expectEqual(1, start.ghost_alive);
    try std.testing.expectEqual(.failure, start.mission_success);
    try std.testing.expectEqual(0, start.countdown);
}

/// Whether a mission that ends so keeps the pilot's kills: every ending but the player's ship
/// destroyed or its ejected pilot killed or captured.
pub fn keepsKills(ending: Ending) bool {
    return switch (ending) {
        .destroyed, .captured => false,
        else => true,
    };
}

/// What the pilot's record keeps of a mission of the campaign, which the ITAC's debriefings show:
/// what `mission_end_record` keeps for the next mission's start (`0x00475C69` on), which `WinMain`
/// puts back before each attempt (`0x004A9A1C` on), and the pickups `pickup_count` keeps.
pub const MissionRecord = struct {
    /// How its script rated it as it ended (`mission_ratings`, `0x00562E2C`): none before it is
    /// flown, nor for the campaign's last mission, which leads to the story's end first
    /// (`0x00475B43`).
    rating: ?vm.Variables.Outcome = null,
    /// The pilot's kills in it, one a ship (`mission_kills`, `0x00562E64`;
    /// `input.Player.Kills.mission`).
    kills: u16 = 0,
    /// The campaign's pickups so far, where a nanny ship picked the ejected pilot up in it
    /// (`mission_pickups`, `0x00562E9C`): 1 or 2, and 0 where none did.
    pickups: u8 = 0,
    /// The rank the pilot was promoted to as it ended (`mission_promotions`, `0x00562ED6`); none
    /// where there was no promotion.
    promotion: ?Rank = null,
};

/// What `mission_end_record` moves the campaign on to.
pub const Record = struct {
    /// The next mission (`mission_number`).
    next: u16,
    /// The campaign's tier (`campaign_tier`).
    tier: u2,
    /// The medal the mission awards, whose ceremony then plays.
    medal: ?Medal = null,
};

/// `mission_end_record` (`0x00475A90`) as mission `mission` ends, rated by its script in
/// `variables`, the campaign at `tier`, in `campaign` where it is flown in one: nothing where the
/// ending keeps no kills (`keepsKills`, `mission_ending` 1 or 3); where the script rated it a total
/// failure, the ending becomes one (`0x00475CE5`). Otherwise the rating is kept as the last
/// (`0x00475AC2`), the mission's ribbon awarded where it ends a chapter (`ribbonOf`,
/// `ribbon_award`, `0x00475A50`), the pilot promoted by the kills over the campaign (`promote`),
/// which the mission's record keeps, and the kills kept for the next mission's start
/// (`winmain.startMission`), the mission's in its record; the tier is the one the mission brings,
/// where it brings one (`mission_tiers`, `0x00475B28`); and the campaign moves on (`nextMission`),
/// from the last mission to the story's end (`0x00475B3A`), after any other the record keeping the
/// rating (`0x00475B43`). A mission that awards a medal (`medal_of_mission`, `0x00475B57`) awards
/// it for a success with its bonus, unless a nanny ship picked the pilot up (`medal_award`,
/// `0x00475A40`).
///
/// Not ported: the pilot's profile written
/// ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
pub fn endMission(player: *input.Player, variables: *vm.Variables, mission: u16, tier: u2, campaign: ?*Campaign) ?Record {
    if (!keepsKills(player.ending)) return null;
    const rating = variables.mission_success;
    if (rating == .total_failure) {
        player.ending = .total_failure;
        return null;
    }
    variables.last_success = rating;
    if (campaign) |going| if (ribbonOf(mission)) |ribbon| going.ribbons.set(ribbon - 1);
    const promoted = promote(player);
    player.kills.kept = player.kills.count;
    const record = if (campaign) |going| going.record(mission) else null;
    if (record) |kept| {
        if (promoted) |rank| kept.promotion = rank;
        kept.kills = player.kills.mission;
    }
    const reached = if (mission >= 1 and mission <= mission_tiers.len and mission_tiers[mission - 1] != 0) mission_tiers[mission - 1] else tier;
    const next = if (mission == last_mission) story_end else nextMission(mission);
    if (campaign) |going| going.mission = next;
    if (mission == last_mission) return .{ .next = next, .tier = reached };
    if (record) |kept| kept.rating = rating;
    const awards = player.ending != .rescued and rating == .success_bonus;
    const medal = if (awards) Medal.of(mission) else null;
    if (campaign) |going| if (medal) |won| going.medals.insert(won);
    return .{ .next = next, .tier = reached, .medal = medal };
}

/// The campaign's first mission, where a new campaign starts (`campaign_new`), and its last, and
/// the number the story's end takes after it (`mission_end_record`, `0x00475B3A`).
pub const first_mission = 1;
pub const last_mission = 28;
pub const story_end = 29;

/// The pilot's ribbons, ribbon 1 first: one for each chapter of the story the pilot has come
/// through (`pilot_ribbons`).
pub const Ribbons = std.StaticBitSet(save.ribbons);

/// The ribbon mission `mission` awards as it ends, for the chapter it ends (`ribbon_of_mission`,
/// `0x0050099F`): missions 7, 11, 19, 21 and 25 award ribbons 1 to 5.
pub fn ribbonOf(mission: u16) ?u3 {
    return switch (mission) {
        7 => 1,
        11 => 2,
        19 => 3,
        21 => 4,
        25 => 5,
        else => null,
    };
}

/// The mission after mission `mission` (`mission_end_record`, `0x00475BB2` on): the next number,
/// but 11 and 12 go on to 14, 16 to 18 and 21 to 23, the campaign having no missions 12, 13, 17 and
/// 22.
pub fn nextMission(mission: u16) u16 {
    return switch (mission) {
        11, 12 => 14,
        16 => 18,
        21 => 23,
        else => mission + 1,
    };
}

/// The number the player sees for mission `mission` (`mission_display_numbers`, `0x004E5C78`):
/// the campaign's missions counted in the order they are flown, 1 to 24, which the autosaves'
/// names and the saved games' list show.
///
/// **Fix:** a mission past the table shows as 0, where the game reads on past its end.
pub fn displayNumber(mission: u16) u16 {
    return if (mission < display_numbers.len) display_numbers[mission] else 0;
}

const display_numbers = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 12, 13, 14, 17, 15, 16, 17, 18, 22, 19, 20, 21, 22, 23, 24, 0, 0, 0 };

/// A medal, which a mission awards (`medal_of_mission`, `0x005009BB`), and whose ceremony plays as
/// it does (`medal_movies`, `0x00500A08`).
pub const Medal = enum(u3) {
    silver = 1,
    black_eagle = 2,
    valour = 3,
    legion = 4,
    navy_cross = 5,
    medal_of_honour = 6,

    /// The medal mission `mission` awards: missions 6, 11, 16, 21, 23 and 27 award the six in
    /// turn.
    pub fn of(mission: u16) ?Medal {
        return switch (mission) {
            6 => .silver,
            11 => .black_eagle,
            16 => .valour,
            21 => .legion,
            23 => .navy_cross,
            27 => .medal_of_honour,
            else => null,
        };
    }

    /// Its ceremony, from the disc's archive open (`play_bink_movie_resourced`, `0x00475B98`).
    pub fn movie(medal: Medal) []const u8 {
        return switch (medal) {
            .silver => "new_silver.bik",
            .black_eagle => "new_black eagle.bik",
            .valour => "new_valour.bik",
            .legion => "new_legion.bik",
            .navy_cross => "new_navy_cross.bik",
            .medal_of_honour => "new_medal_of_honour.bik",
        };
    }
};

/// The kills each rank needs, from the first (`rank_kills`, `0x005009F4`).
pub const rank_kills = [_]i32{ 0, 35, 72, 115, 150, 200, 255, 275, 300 };

/// The pilot's ranks, from the first.
pub const Rank = std.math.IntFittingRange(0, rank_kills.len - 1);

/// The rank a number stands for, the highest past the last.
pub fn rankOf(value: i32) Rank {
    return @intCast(std.math.clamp(value, 0, rank_kills.len - 1));
}

/// The game's strings that name each rank (`rank_names`, `0x004E5BCC`), and each tier, the level
/// the pilot's loadout reaches (`tier_names`, `0x004E5BEC`).
pub const rank_names = [rank_kills.len]u16{ 0x55C, 0xED, 0xEE, 0x1BD, 0x1BE, 0x1BF, 0x1C0, 0xF0, 0x1C1 };
pub const tier_names = [4]u16{ 0xFA, 0xF9, 0xF8, 0xFB };

/// `mission_end_record`'s promotion (`0x00475AE6` to `0x00475B1A`): the pilot raised to the highest
/// rank whose kills the campaign's reach, where it is above the pilot's own, which it gives. A rank
/// is never lost.
pub fn promote(player: *input.Player) ?Rank {
    var earned: Rank = 0;
    for (rank_kills, 0..) |needed, rank| {
        if (player.kills.count < needed) break;
        earned = @intCast(rank);
    }
    if (earned <= player.rank) return null;
    player.rank = earned;
    return earned;
}

test endMission {
    var player: input.Player = .{ .kills = .{ .count = 40, .kept = 2, .mission = 7 } };
    var variables: vm.Variables = .{ .mission_success = .success };
    var campaign: Campaign = .begin();
    campaign.mission = 5;
    // Destroyed, or captured after ejecting, the attempt's kills are not kept, nor the pilot
    // promoted, and the campaign stays where it is.
    player.ending = .destroyed;
    try std.testing.expectEqual(null, endMission(&player, &variables, 5, 0, &campaign));
    try std.testing.expectEqual(2, player.kills.kept);
    player.ending = .captured;
    try std.testing.expectEqual(null, endMission(&player, &variables, 5, 0, &campaign));
    try std.testing.expectEqual(2, player.kills.kept);
    try std.testing.expectEqual(0, player.rank);
    try std.testing.expectEqual(MissionRecord{}, campaign.kept(5));
    try std.testing.expectEqual(5, campaign.mission);
    // A total failure keeps nothing, and becomes the mission's ending.
    player.ending = .rescued;
    variables.mission_success = .total_failure;
    try std.testing.expectEqual(null, endMission(&player, &variables, 5, 0, &campaign));
    try std.testing.expectEqual(2, player.kills.kept);
    try std.testing.expectEqual(.total_failure, player.ending);
    // Picked up, they are kept, 40 kills make the pilot's rank 1, and the campaign goes on; the
    // record keeps the rating, the mission's kills and the promotion.
    player.ending = .rescued;
    variables.mission_success = .failure;
    try std.testing.expectEqual(Record{ .next = 6, .tier = 0 }, endMission(&player, &variables, 5, 0, &campaign).?);
    try std.testing.expectEqual(40, player.kills.kept);
    try std.testing.expectEqual(1, player.rank);
    try std.testing.expectEqual(.failure, variables.last_success);
    try std.testing.expectEqual(MissionRecord{ .rating = .failure, .kills = 7, .promotion = 1 }, campaign.kept(5));
    try std.testing.expectEqual(6, campaign.mission);
    try std.testing.expectEqual(0, campaign.ribbons.count());
    // Mission 11 ends a chapter, which awards ribbon 2 whatever the rating; it raises the tier,
    // skips to 14, and awards its medal for a success with its bonus. With no promotion, the record
    // keeps none.
    player.ending = .playing;
    variables.mission_success = .success_bonus;
    try std.testing.expectEqual(Record{ .next = 14, .tier = 1, .medal = .black_eagle }, endMission(&player, &variables, 11, 0, &campaign).?);
    try std.testing.expectEqual(null, campaign.kept(11).promotion);
    try std.testing.expect(campaign.medals.contains(.black_eagle));
    try std.testing.expect(campaign.ribbons.isSet(1) and campaign.ribbons.count() == 1);
    try std.testing.expectEqual(14, campaign.mission);
    // Picked up, the medal is not awarded; outside a campaign nothing is kept but the pilot's own;
    // and the last mission leads to the story's end, its record keeping no rating.
    player.ending = .rescued;
    campaign.medals = .initEmpty();
    try std.testing.expectEqual(Record{ .next = 14, .tier = 1 }, endMission(&player, &variables, 11, 0, &campaign).?);
    try std.testing.expectEqual(0, campaign.medals.count());
    try std.testing.expectEqual(Record{ .next = 14, .tier = 1 }, endMission(&player, &variables, 11, 0, null).?);
    try std.testing.expectEqual(Record{ .next = story_end, .tier = 3 }, endMission(&player, &variables, last_mission, 3, &campaign).?);
    try std.testing.expectEqual(null, campaign.kept(last_mission).rating);
    try std.testing.expectEqual(story_end, campaign.mission);
}

test displayNumber {
    try std.testing.expectEqual(11, displayNumber(11));
    // The campaign has no missions 12 and 13, so that mission 14 is the twelfth flown.
    try std.testing.expectEqual(12, displayNumber(14));
    try std.testing.expectEqual(24, displayNumber(last_mission));
    try std.testing.expectEqual(0, displayNumber(story_end));
    try std.testing.expectEqual(0, displayNumber(40));
}

test ribbonOf {
    try std.testing.expectEqual(1, ribbonOf(7));
    try std.testing.expectEqual(5, ribbonOf(25));
    try std.testing.expectEqual(null, ribbonOf(28));
}

test nextMission {
    try std.testing.expectEqual(2, nextMission(1));
    try std.testing.expectEqual(14, nextMission(12));
    try std.testing.expectEqual(18, nextMission(16));
    try std.testing.expectEqual(23, nextMission(21));
    try std.testing.expectEqual(25, nextMission(24));
}

test "Campaign.pickedUp" {
    var campaign: Campaign = .begin();
    // Each mission's record keeps the count, and the third pickup transfers the pilot.
    try std.testing.expect(!campaign.pickedUp(3));
    try std.testing.expect(!campaign.pickedUp(5));
    try std.testing.expectEqual(1, campaign.kept(3).pickups);
    try std.testing.expectEqual(2, campaign.kept(5).pickups);
    try std.testing.expect(campaign.pickedUp(6));
    try std.testing.expectEqual(0, campaign.kept(6).pickups);
    // Outside the campaign's missions, there is no record.
    try std.testing.expectEqual(null, campaign.record(0));
    try std.testing.expectEqual(MissionRecord{}, campaign.kept(last_mission + 1));
}

test promote {
    var player: input.Player = .{};
    try std.testing.expectEqual(0, player.rank);
    // Each rank at its kills exactly, and the last from 300 on.
    player.kills.count = 72;
    try std.testing.expectEqual(2, promote(&player));
    try std.testing.expectEqual(2, player.rank);
    player.kills.count = 1000;
    try std.testing.expectEqual(@as(?Rank, rank_kills.len - 1), promote(&player));
    try std.testing.expectEqual(rank_kills.len - 1, player.rank);
    // A rank earned is kept, whatever the kills, and no promotion is given again.
    player.kills.count = 0;
    try std.testing.expectEqual(null, promote(&player));
    try std.testing.expectEqual(rank_kills.len - 1, player.rank);
}

test profileCallSign {
    var bytes: [profile_size]u8 = @splat(0);
    @memcpy(bytes[4..][0..6], "Maniac");
    try std.testing.expectEqualStrings("Maniac", profileCallSign(&bytes));
    // A name with no terminator ends with its 32 bytes, and a short file gives what it holds.
    @memset(bytes[4..][0..40], 'x');
    try std.testing.expectEqual(32, profileCallSign(&bytes).len);
    try std.testing.expectEqualStrings("xx", profileCallSign(bytes[0..6]));
    try std.testing.expectEqualStrings("", profileCallSign(bytes[0..2]));
}

test {
    _ = save;
}
