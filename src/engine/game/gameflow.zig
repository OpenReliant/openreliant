//! `C:\lancer\game\gameflow.cpp`: the campaign's flow from one mission to the next.
//! **Unverified:** that `campaign_new`, `profile_load`, `profile_save`, `mission_reset_variables`
//! and `mission_end_record` are this file's: they lie beside the file's known code, between
//! `explode.cpp`'s and `gameobj.cpp`'s.
//!
//! Ported so far: the campaign as it begins and as each attempt at a mission starts (`Campaign`),
//! the pilot's profile (`Profile`, `ProfileFile`), what a mission's end makes of the campaign
//! (`endMission`): the pilot's rank, the kills kept, the rating kept, the tier, the medal, the
//! ribbon and the next mission; and the saved games (`save`).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const log = std.log.scoped(.gameflow);
const pilots = @import("pilots.zig");

const files = @import("../files.zig");
const input = @import("../input.zig");
const vm = @import("../vm.zig");
const pilot_roster = @import("interface/pilot_roster.zig");
const Ending = @import("main.zig").Ending;

pub const save = @import("gameflow/save.zig");

/// How many of the game's variables `campaign_new` clears, from the first on (`0x004751B4`).
const cleared_variables = 32;

/// The game's variables a new campaign sets to 1 (`campaign_new`), in its order: the campaign's
/// flags, such as `ghost_alive`, and `mission_success`, which each attempt clears again. The rest
/// of the campaign's start at 0.
const campaign_flags = vm.Variables.numbers(.{
    "mission_success", "_unused_16",  "krasnaya_alive",    "rameses_alive",    "kozah_alive",
    "_unused_20",      "_unused_21",  "mcgann_alive",      "fixed_gate_alive", "warp_gate_alive",
    "czar_alive",      "ghost_alive", "_unused_31",        "reliant_alive",    "_unknown_35",
    "steiner_alive",   "kulov_alive", "ivan_petrov_alive", "_unknown_6",       "yamato_alive",
});

/// `campaign_new` (`0x004751B0`) as a new campaign begins, which `WinMain` runs as the game starts:
/// clears the first 32 of the game's variables, then sets the campaign's flags (`campaign_flags`).
/// `Campaign.begin` sets up the rest of the campaign, mission 1 as the next and each mission's
/// records, `save.Game.clearPilot` the pilot's tallies, and `ProfileFile.open` reads the pilot's
/// profile.
pub fn newCampaign(variables: *vm.Variables) void {
    for (0..cleared_variables) |index| variables.slot(@intCast(index)).* = 0;
    for (campaign_flags) |index| variables.slot(index).* = 1;
}

/// The pilot's profile's file in the game's folder (`profile_name`, `0x00500ACC`), and its size.
pub const profile_name = "profile.bin";
pub const profile_size = 0xD0;

/// The pilot's profile, the 0xD0 bytes the game keeps at `profile` (`0x00562CF8`) and writes to
/// `profile.bin`. Each mission's end copies the campaign into it (`keep`), and the game copies the
/// call sign into it each time before it writes it (`setCallSign`). The game reads it back for its
/// call sign as the game starts, as the main menu opens and as START GAME begins a campaign
/// (`ProfileFile.open`). A network game's campaign mission also takes the pilot's rank, tier,
/// kills, medals, ribbons, ratings and each mission's kills back from it (`0x004A99CC`), which
/// OpenReliant doesn't have yet ([#804](https://github.com/OpenReliant/openreliant/issues/804)).
pub const Profile = extern struct {
    /// The mission the campaign had moved on to when a mission's end last copied the campaign in
    /// (`mission_number`); 0 in a new profile.
    mission: i32,
    /// The pilot's call sign, up to its terminator.
    call_sign: [32]u8,
    /// The pilot's rank, the campaign's tier, the pilot's kills, medals and ribbons, and each
    /// mission's rating and kills, as the saved games keep them (`save.Miss`).
    rank: i32,
    tier: i32,
    kills: i32,
    medals: [save.medals]i32,
    ribbons: [save.ribbons]i32,
    ratings: [save.missions]i16,
    mission_kills: [save.missions]i16,

    /// A new profile, which `campaign_new` makes where the game's folder has none (`0x004752CA`
    /// to `0x00475337`): named `name`, no mission rated, and the rest 0.
    pub fn new(name: []const u8) Profile {
        var profile = std.mem.zeroes(Profile);
        profile.setCallSign(name);
        profile.ratings = @splat(save.no_rating);
        return profile;
    }

    /// `profile_load`'s read (`0x00475390`): `bytes` over the profile, as far as the file has
    /// them.
    pub fn read(profile: *Profile, bytes: []const u8) void {
        const length = @min(bytes.len, profile_size);
        @memcpy(std.mem.asBytes(profile)[0..length], bytes[0..length]);
    }

    /// The call sign the profile keeps, which `profile_load` gives the pilot (`0x004753C5`).
    ///
    /// **Fix:** the game copies the name up to its terminator wherever that lies; OpenReliant keeps
    /// to its 32 bytes.
    pub fn callSign(profile: *const Profile) []const u8 {
        return std.mem.sliceTo(&profile.call_sign, 0);
    }

    /// The copy of `call_sign` into the profile that comes before each write: the call sign as
    /// much as fits, and its terminator; the rest of the field keeps what it held.
    pub fn setCallSign(profile: *Profile, call_sign: []const u8) void {
        const length = @min(call_sign.len, profile.call_sign.len - 1);
        @memcpy(profile.call_sign[0..length], call_sign[0..length]);
        profile.call_sign[length] = 0;
    }

    /// `mission_end_record`'s copy of the campaign into the profile (`0x00475C2D` to
    /// `0x00475CC6`), from the campaign as the saved games take it (`save.Game.campaignRecord`).
    pub fn keep(profile: *Profile, miss: save.Miss) void {
        profile.mission = miss.mission;
        profile.setCallSign(std.mem.sliceTo(&miss.call_sign, 0));
        profile.rank = miss.rank;
        profile.tier = miss.tier;
        profile.kills = miss.kills;
        profile.medals = miss.medals;
        profile.ribbons = miss.ribbons;
        profile.ratings = miss.ratings;
        profile.mission_kills = miss.mission_kills;
    }

    comptime {
        assert(@offsetOf(Profile, "call_sign") == 4);
        assert(@offsetOf(Profile, "rank") == 0x24);
        assert(@offsetOf(Profile, "medals") == 0x30);
        assert(@offsetOf(Profile, "ribbons") == 0x48);
        assert(@offsetOf(Profile, "ratings") == 0x60);
        assert(@offsetOf(Profile, "mission_kills") == 0x98);
        assert(@sizeOf(Profile) == profile_size);
    }
};

/// The pilot's profile as the game keeps it, and the game's folder, where `save` writes it.
pub const ProfileFile = struct {
    profile: Profile = std.mem.zeroes(Profile),
    io: Io,
    dir: Io.Dir,
    /// The name a new profile takes: the game's string PLAYER (`0xBF`).
    default_name: []const u8,
    /// The profile as the file was last read or written, if all of it was.
    written: ?Profile = null,

    /// `campaign_new`'s part in the profile (`0x004752B0` on), as the game starts, as the main menu
    /// opens and as START GAME begins a campaign: the profile `profile.bin` holds (`profile_load`,
    /// `0x00475390`), whose call sign the pilot takes (`call_sign`). Where the game's folder has
    /// none, a new profile named `default_name` (`Profile.new`), written at once, the call sign left
    /// as it was.
    pub fn open(file: *ProfileFile, call_sign: *pilot_roster.CallSign) void {
        var name: [files.max_path]u8 = undefined;
        if (files.find(file.io, file.dir, profile_name, &name)) |spelled| {
            var bytes: [profile_size]u8 = undefined;
            if (file.dir.readFile(file.io, spelled, &bytes)) |read| {
                file.profile.read(read);
                file.written = if (read.len == profile_size) file.profile else null;
                call_sign.set(file.profile.callSign());
                return;
            } else |err| log.warn("can't read {s}: {t}", .{ profile_name, err });
        }
        file.profile = .new(file.default_name);
        file.written = null;
        file.save();
    }

    /// `profile_save` (`0x004753F0`): the profile written to `profile.bin`, over the file found
    /// whatever the case of its name.
    ///
    /// **Improvement:** OpenReliant writes the file only where the profile has changed since it was
    /// last read or written. The game writes it again in each pass of the pilot roster while the
    /// pointer's button is held anywhere off the call sign.
    pub fn save(file: *ProfileFile) void {
        if (file.written) |last| if (std.mem.eql(u8, std.mem.asBytes(&last), std.mem.asBytes(&file.profile))) return;
        files.writeFile(file.io, file.dir, profile_name, std.mem.asBytes(&file.profile)) catch |err| {
            log.warn("the pilot's profile can't be saved to {s}: {t}", .{ profile_name, err });
            return;
        };
        file.written = file.profile;
    }

    /// The pilot's call sign copied into the profile, which is then written (`Profile.setCallSign`,
    /// `save`), as the pilot roster does as its call sign changes (`0x004307EB`, `0x00430860`,
    /// `0x00430921`), the Reliant's rooms as they open (`0x0043A002`), and each mission's start
    /// last (`0x00493F8E`).
    pub fn saveWith(file: *ProfileFile, call_sign: []const u8) void {
        file.profile.setCallSign(call_sign);
        file.save();
    }
};

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
    variables.chapter2_thread3_shown = 0;
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
    medals: std.EnumSet(Medal) = .empty,
    /// The ribbons the pilot has been awarded, ribbon 1 first (`pilot_ribbons`, `0x00562E14`).
    ribbons: Ribbons = .empty,
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
    try std.testing.expectEqual(1, variables.yamato_alive);
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

/// What the pilot's record keeps of a mission of the campaign, which the ITAC's debriefings show
/// and the saved games keep: what `mission_end_record` keeps as the mission ends, and the pickups
/// `pickup_count` keeps.
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
/// `0x00475A40`). Last, the wing's pilots are brought up to date for the next mission
/// (`update_pilots`, `0x00475BE8`), before the autosave keeps them (`save.autosave`) and the pilot's
/// profile takes the campaign (`Profile.keep`).
pub fn endMission(player: *input.Player, variables: *vm.Variables, mission: u16, tier: u2, campaign: ?*Campaign, wingmen: *pilots.Wingmen) ?Record {
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
    wingmen.update(next);
    return .{ .next = next, .tier = reached, .medal = medal };
}

/// The campaign's first mission, where a new campaign starts (`campaign_new`), and its last, and
/// the number the story's end takes after it (`mission_end_record`, `0x00475B3A`).
pub const first_mission = 1;
pub const last_mission = 28;
pub const story_end = 29;

/// The pilot's ribbons, ribbon 1 first: one for each chapter of the story the pilot has come
/// through (`pilot_ribbons`).
pub const Ribbons = std.bit_set.Static(save.ribbons);

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

/// The mission the campaign comes to mission `mission` from (`nextMission`): 11 before 14, 16
/// before 18 and 21 before 23, else the number before; none before the first.
pub fn previousMission(mission: u16) ?u16 {
    return switch (mission) {
        0, first_mission => null,
        14 => 11,
        18 => 16,
        23 => 21,
        else => mission - 1,
    };
}

test previousMission {
    try std.testing.expectEqual(null, previousMission(first_mission));
    // Each mission the campaign flies comes after the one before it.
    for (first_mission + 1..last_mission + 1) |number| {
        const mission: u16 = @intCast(number);
        if (mission == 12 or mission == 13 or mission == 17 or mission == 22) continue;
        try std.testing.expectEqual(mission, nextMission(previousMission(mission).?));
    }
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
    var wingmen: pilots.Wingmen = .{};
    var player: input.Player = .{ .kills = .{ .count = 40, .kept = 2, .mission = 7 } };
    var variables: vm.Variables = .{ .mission_success = .success };
    var campaign: Campaign = .begin();
    campaign.mission = 5;
    // Destroyed, or captured after ejecting, the attempt's kills are not kept, nor the pilot
    // promoted, and the campaign stays where it is.
    player.ending = .destroyed;
    try std.testing.expectEqual(null, endMission(&player, &variables, 5, 0, &campaign, &wingmen));
    try std.testing.expectEqual(2, player.kills.kept);
    player.ending = .captured;
    try std.testing.expectEqual(null, endMission(&player, &variables, 5, 0, &campaign, &wingmen));
    try std.testing.expectEqual(2, player.kills.kept);
    try std.testing.expectEqual(0, player.rank);
    try std.testing.expectEqual(MissionRecord{}, campaign.kept(5));
    try std.testing.expectEqual(5, campaign.mission);
    // A total failure keeps nothing, and becomes the mission's ending.
    player.ending = .rescued;
    variables.mission_success = .total_failure;
    try std.testing.expectEqual(null, endMission(&player, &variables, 5, 0, &campaign, &wingmen));
    try std.testing.expectEqual(2, player.kills.kept);
    try std.testing.expectEqual(.total_failure, player.ending);
    // Picked up, they are kept, 40 kills make the pilot's rank 1, and the campaign goes on; the
    // record keeps the rating, the mission's kills and the promotion.
    player.ending = .rescued;
    variables.mission_success = .failure;
    try std.testing.expectEqual(Record{ .next = 6, .tier = 0 }, endMission(&player, &variables, 5, 0, &campaign, &wingmen).?);
    // Mission 6's stretch brings Diceman in as Alpha 5.
    try std.testing.expectEqual(0x78, wingmen.alpha[4]);
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
    try std.testing.expectEqual(Record{ .next = 14, .tier = 1, .medal = .black_eagle }, endMission(&player, &variables, 11, 0, &campaign, &wingmen).?);
    try std.testing.expectEqual(null, campaign.kept(11).promotion);
    try std.testing.expect(campaign.medals.contains(.black_eagle));
    try std.testing.expect(campaign.ribbons.isSet(1) and campaign.ribbons.count() == 1);
    try std.testing.expectEqual(14, campaign.mission);
    // Picked up, the medal is not awarded; outside a campaign nothing is kept but the pilot's own;
    // and the last mission leads to the story's end, its record keeping no rating.
    player.ending = .rescued;
    campaign.medals = .empty;
    try std.testing.expectEqual(Record{ .next = 14, .tier = 1 }, endMission(&player, &variables, 11, 0, &campaign, &wingmen).?);
    try std.testing.expectEqual(0, campaign.medals.count());
    try std.testing.expectEqual(Record{ .next = 14, .tier = 1 }, endMission(&player, &variables, 11, 0, null, &wingmen).?);
    try std.testing.expectEqual(Record{ .next = story_end, .tier = 3 }, endMission(&player, &variables, last_mission, 3, &campaign, &wingmen).?);
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

test Profile {
    var profile: Profile = .new("PLAYER");
    try std.testing.expectEqualStrings("PLAYER", profile.callSign());
    try std.testing.expectEqual(0, profile.mission);
    try std.testing.expectEqual(save.no_rating, profile.ratings[0]);
    // A shorter call sign leaves the rest of the field as it was, as the game's copy does.
    profile.setCallSign("Ace");
    try std.testing.expectEqualStrings("Ace", profile.callSign());
    try std.testing.expectEqualStrings("Ace\x00ER\x00", profile.call_sign[0..7]);
    // One too long keeps what fits, with its terminator.
    profile.setCallSign(&@as([40]u8, @splat('x')));
    try std.testing.expectEqual(31, profile.callSign().len);

    // The file's bytes, as far as it has them; a name with no terminator ends with its 32 bytes.
    var bytes: [profile_size]u8 = @splat(0);
    @memcpy(bytes[4..][0..6], "Maniac");
    profile.read(&bytes);
    try std.testing.expectEqualStrings("Maniac", profile.callSign());
    @memset(bytes[4..][0..40], 'y');
    profile.read(bytes[0..8]);
    try std.testing.expectEqualStrings("yyyyac", profile.callSign());
    profile.read(&bytes);
    try std.testing.expectEqual(32, profile.callSign().len);

    // A mission's end copies the campaign in.
    var miss = std.mem.zeroes(save.Miss);
    miss.mission = 6;
    @memcpy(miss.call_sign[0..4], "Wolf");
    miss.rank = 2;
    miss.tier = 1;
    miss.kills = 80;
    miss.mp_deaths = 9;
    miss.medals[0] = 1;
    miss.ribbons[4] = 1;
    miss.ratings = @splat(save.no_rating);
    miss.ratings[4] = 1;
    miss.mission_kills[5] = 12;
    profile.keep(miss);
    try std.testing.expectEqual(6, profile.mission);
    try std.testing.expectEqualStrings("Wolf", profile.callSign());
    try std.testing.expectEqual(2, profile.rank);
    try std.testing.expectEqual(1, profile.tier);
    try std.testing.expectEqual(80, profile.kills);
    try std.testing.expectEqual(1, profile.medals[0]);
    try std.testing.expectEqual(1, profile.ribbons[4]);
    try std.testing.expectEqual(1, profile.ratings[4]);
    try std.testing.expectEqual(save.no_rating, profile.ratings[5]);
    try std.testing.expectEqual(12, profile.mission_kills[5]);
}

test ProfileFile {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file: ProfileFile = .{ .io = std.testing.io, .dir = tmp.dir, .default_name = "PLAYER" };
    // Without a profile, a new one is made and written, and the call sign stays as it was.
    var call_sign: pilot_roster.CallSign = .{};
    call_sign.set("Ace");
    file.open(&call_sign);
    try std.testing.expectEqualStrings("Ace", call_sign.slice());
    var bytes: [profile_size + 1]u8 = undefined;
    const written = try tmp.dir.readFile(std.testing.io, profile_name, &bytes);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&Profile.new("PLAYER")), written);
    // Each write takes the call sign, and the file gives it back, whatever the case of its name.
    file.saveWith("Maniac");
    try tmp.dir.rename(profile_name, tmp.dir, "PROFILE.BIN", std.testing.io);
    file.saveWith("Wolf");
    var again: ProfileFile = .{ .io = std.testing.io, .dir = tmp.dir, .default_name = "PLAYER" };
    again.open(&call_sign);
    try std.testing.expectEqualStrings("Wolf", call_sign.slice());
    // A short file gives what it holds over the profile as it was.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "PROFILE.BIN", .data = "\x01\x00\x00\x00Ace\x00" });
    again.open(&call_sign);
    try std.testing.expectEqualStrings("Ace", call_sign.slice());
    try std.testing.expectEqual(1, again.profile.mission);
    try std.testing.expectEqual(save.no_rating, again.profile.ratings[0]);
}

test {
    _ = save;
}
