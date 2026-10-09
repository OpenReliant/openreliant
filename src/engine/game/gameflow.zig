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
const create = @import("create.zig");
const hooks = @import("../hooks.zig");
const movies = @import("xtrabits/movie.zig");
const briefing = @import("interface/briefing.zig");
const rooms = @import("interface/rooms.zig");
const hud = @import("hud.zig");
const gameobj = @import("gameobj.zig");
const debriefing = @import("itac/debriefing.zig");
const news_reports = @import("itac/news_reports.zig");
const video_reports = @import("videoreports.zig");

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

/// `campaign_new` (`0x004751B0`) as a new campaign begins, which `WinMain` also runs as the game
/// starts: clears the first 32 of the game's variables, then sets the campaign's flags
/// (`campaign_flags`). `Campaign.begin` sets up the rest of the campaign: mission 1 as the next,
/// and empty records for each mission. `save.Game.clearPilot` clears the pilot's tallies, and
/// `ProfileFile.open` reads the pilot's profile.
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

/// The original's loadout tier for each mission, one byte per mission from mission 1
/// (`0x005009D8`): missions 11, 19 and 21 raise the campaign's tier to 1, 2 and 3, and 0 means no
/// change. The loadout raises `campaign_tier` to the highest tier of the missions before its own,
/// and reads at most 28 entries (`loadout_load`, `0x00441AA9`). `CampaignMission.original` copies
/// it.
const mission_tiers = [last_mission]u2{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 3, 0, 0, 0, 0, 0, 0, 0 };

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

    /// A new campaign (`campaign_new`), at mission 1. START GAME then moves it to the first
    /// mission of the campaign's order (`Order.first`).
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

/// Where `mission_end_record` moves the campaign.
pub const Record = struct {
    /// The next mission (`mission_number`).
    next: u16,
    /// The campaign's tier (`campaign_tier`).
    tier: u2,
    /// The medal the mission awarded, if any. Its ceremony plays next.
    medal: ?Medal = null,
};

/// `mission_end_record` (`0x00475A90`), run as mission `mission` ends. The mission's script has
/// rated it in `variables`, the campaign is at `tier`, and `campaign` is the campaign being flown,
/// if any.
///
/// - If the ending keeps no kills (`keepsKills`, `mission_ending` 1 or 3), nothing happens.
/// - If the script rated the mission a total failure, the ending becomes one (`0x00475CE5`).
/// - Otherwise the rating becomes the last one (`0x00475AC2`). If the mission ends a chapter, the
///   pilot gets the chapter's ribbon (`CampaignMission.chapter`, `ribbon_award`, `0x00475A50`).
///   The pilot is promoted by the kills over the campaign (`promote`), and the mission's record
///   keeps the promotion. The kills are kept for the next mission's start
///   (`winmain.startMission`), and the mission's record keeps the mission's own kills. If the
///   mission has a tier, the campaign moves to it (`CampaignMission.tier`, `0x00475B28`).
/// - The campaign moves on to the next mission in its order (`nextMission`), or to the story's end
///   after the last one (`0x00475B3A`).
/// - For every mission but the last, the record keeps the rating (`0x00475B43`). If the mission
///   has a medal (`CampaignMission.medal`, `0x00475B57`), the pilot gets it for a success with its
///   bonus, unless a nanny ship picked the pilot up (`medal_award`, `0x00475A40`). Then the wing's
///   pilots are updated for the next mission (`update_pilots`, `0x00475BE8`), before the autosave
///   keeps them (`save.autosave`) and the pilot's profile takes the campaign (`Profile.keep`).
pub fn endMission(player: *input.Player, variables: *vm.Variables, mission: u16, tier: u2, campaign: ?*Campaign, wingmen: *pilots.Wingmen) ?Record {
    if (!keepsKills(player.ending)) return null;
    const rating = variables.mission_success;
    if (rating == .total_failure) {
        player.ending = .total_failure;
        return null;
    }
    variables.last_success = rating;
    if (campaign) |going| if (campaignField(mission, .chapter)) |ribbon| going.ribbons.set(ribbon - 1);
    const promoted = promote(player);
    player.kills.kept = player.kills.count;
    const record = if (campaign) |going| going.record(mission) else null;
    if (record) |kept| {
        if (promoted) |rank| kept.promotion = rank;
        kept.kills = player.kills.mission;
    }
    const reached: u2 = campaignField(mission, .tier) orelse tier;
    const next = nextMission(mission);
    if (campaign) |going| going.mission = next;
    if (next == story_end) return .{ .next = next, .tier = reached };
    if (record) |kept| kept.rating = rating;
    const awards = player.ending != .rescued and rating == .success_bonus;
    const medal = if (awards) campaignField(mission, .medal) else null;
    if (campaign) |going| if (medal) |won| going.medals.insert(won);
    wingmen.update(next);
    return .{ .next = next, .tier = reached, .medal = medal };
}

/// The numbers the campaign's missions can have, 1 to 28. The saved game keeps a record for each
/// (`Campaign.records`), and the game's tables of each mission's medal, ribbon, tier and briefing
/// have as many entries. The story's end takes the number after them (`mission_end_record`,
/// `0x00475B3A`).
pub const first_mission = 1;
pub const last_mission = 28;
pub const story_end = 29;

/// The campaign's missions in the order they are flown, by their numbers (`campaign_missions`,
/// `0x004E4954`). The numbers rise, each from `first_mission` to `last_mission`. The campaign moves
/// on by it as each mission ends (`next`), the player sees each mission's place on it as the
/// mission's number (`shown`), and the ITAC lists the debriefings by it (`place`).
///
/// **Improvement:** the game keeps the order in four places: `campaign_missions`, `campaign_place`
/// (`0x004E49B0`), `mission_display_numbers` (`0x004E5C78`), and the step from one mission to the
/// next in `mission_end_record` (`0x00475BB2` on). OpenReliant works them all out from this one
/// list, which the mods' load scripts can change (`records.campaign`,
/// [#975](https://github.com/OpenReliant/openreliant/issues/975)). For the game's list, they give
/// the same as the game's tables.
pub const Order = struct {
    numbers: [last_mission]u16 = @splat(0),
    count: u8 = 0,

    /// The game's: missions 1 to 28 but 12, 13, 17 and 22, which the campaign has none of.
    pub const original: Order = Order.of(&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15, 16, 18, 19, 20, 21, 23, 24, 25, 26, 27, 28 }) catch unreachable;

    pub const Error = error{
        /// The list has no missions.
        Empty,
        /// A number isn't one a mission of the campaign can have.
        OutOfRange,
        /// A number isn't higher than the one before it.
        NotRising,
    };

    /// The order of the missions `list` gives: at least one, rising, each from `first_mission` to
    /// `last_mission`. Rising numbers in that range are never more than `last_mission`, so they
    /// always fit.
    pub fn of(list: []const u16) Error!Order {
        if (list.len == 0) return error.Empty;
        var order: Order = .{};
        for (list, 0..) |mission, at| {
            if (mission < first_mission or mission > last_mission) return error.OutOfRange;
            if (at > 0 and mission <= list[at - 1]) return error.NotRising;
            order.numbers[at] = mission;
            order.count += 1;
        }
        return order;
    }

    /// The missions, in order.
    pub fn missions(order: *const Order) []const u16 {
        return order.numbers[0..order.count];
    }

    /// The first mission, where a new campaign starts. The game's `campaign_new` starts at mission
    /// 1.
    pub fn first(order: *const Order) u16 {
        return order.numbers[0];
    }

    /// Whether mission `mission` is on the list.
    pub fn has(order: *const Order, mission: u16) bool {
        return std.mem.findScalar(u16, order.missions(), mission) != null;
    }

    /// The mission after mission `mission` (`mission_end_record`, `0x00475BB2` on): the first on the
    /// list with a higher number, which for a mission on the list is the one after it. After the
    /// last comes the story's end. In the game's list, 11 and 12 go on to 14, 16 to 18 and 21 to 23.
    pub fn next(order: *const Order, mission: u16) u16 {
        for (order.missions()) |listed| {
            if (listed > mission) return listed;
        }
        return story_end;
    }

    /// The mission before mission `mission`: the last on the list with a lower number, which for a
    /// mission on the list is the one the campaign comes to it from. The first has none.
    pub fn previous(order: *const Order, mission: u16) ?u16 {
        const before = order.place(mission);
        return if (before == 0) null else order.numbers[before - 1];
    }

    /// How many missions on the list have a lower number than mission `mission` (`campaign_place`,
    /// `0x004E49B0`): the mission's place counted from 0 if it is on the list, otherwise the place
    /// of the mission after it.
    pub fn place(order: *const Order, mission: u16) u8 {
        var before: u8 = 0;
        for (order.missions()) |listed| {
            if (listed >= mission) break;
            before += 1;
        }
        return before;
    }

    /// The number the player sees for mission `mission` (`mission_display_numbers`, `0x004E5C78`),
    /// which the autosaves' names and the saved games' list show: its place on the list counted
    /// from 1. A mission of the campaign's numbers that isn't on the list shows its own number, and
    /// any other number shows 0, as in the game's table.
    ///
    /// **Fix:** a number past the game's table shows 0. The game reads on past the table's end.
    pub fn shown(order: *const Order, mission: u16) u16 {
        if (order.has(mission)) return order.place(mission) + 1;
        return if (mission >= first_mission and mission <= last_mission) mission else 0;
    }
};

/// The campaign's order: the game's, until OpenReliant installs the one the mods' load scripts
/// leave (`install`).
var installed: Order = .original;

/// Makes `order` the campaign's order. OpenReliant does this as it starts, once the mods' load
/// scripts have run.
pub fn install(order: Order) void {
    installed = order;
}

/// The campaign's order.
pub fn campaignOrder() *const Order {
    return &installed;
}

/// What the campaign uses for one of its missions besides the mission's file: the briefing room's
/// movie and speech, the carrier, the objectives' names, what the mission awards, the special cases
/// the original ties to missions 1 and 23, Enriquez's report and debriefing, and the ITAC's news
/// items and video reports. The original decides each of these by the mission's number.
///
/// **Improvement:** OpenReliant keeps them in a table indexed by the mission's number, and mods
/// can change it (`openreliant.records.missions`,
/// [#976](https://github.com/OpenReliant/openreliant/issues/976)).
pub const CampaignMission = struct {
    briefing: briefing.Plan,
    carrier: rooms.Carrier,
    /// The names of its objectives in the game's code page, in place of its row of the game's
    /// table (`hud.Objectives.reset`); null for the table's.
    objectives: ?hud.Objectives.Names = null,
    /// The loadout tier the campaign moves to when the mission ends; null to leave the tier as it
    /// is. The tier and the pilot's rank decide which ships the loadout offers.
    tier: ?Tier = null,
    /// The chapter of the story the mission ends; null if it ends none. The pilot gets the
    /// chapter's ribbon, and the chapter's movie plays after the landing.
    chapter: ?Chapter = null,
    /// The medal the mission awards for a success with its bonus; null for none. Its ceremony
    /// plays when the pilot gets it. After a mission with a medal, the crew in the rooms honour the
    /// pilot, even if the pilot didn't get it (`crew.kindOf`).
    medal: ?Medal = null,
    /// Whether a new pilot sees the intro and the induction before this mission, when a campaign
    /// starts with it (`winmain.CampaignStart`).
    induction: bool = false,
    /// Whether the loadout before this mission teaches the player, as mission 1's does: it starts
    /// on the Predator with the tier's missiles, plays `loadout.ut` and blinks its exit button.
    lesson: bool = false,
    /// The only ship the loadout before this mission offers, as mission 23's offers the Shroud;
    /// null for the ships the tier and the rank open. The loadout starts on it with the tier's
    /// missiles.
    only_ship: ?gameobj.Type = null,
    /// Enriquez's report on the rooms' television before the mission, in parts; empty for none.
    television_report: []const rooms.News.Part = &.{},
    /// Enriquez's debriefing of the mission in the ITAC, for each rating.
    debriefing: debriefing.Text = @splat(&.{}),
    /// The news items the ITAC's NEWS REPORTS adds in the rooms before the mission, and lists from
    /// then on.
    news: []const news_reports.Item = &.{},
    /// The video reports the ITAC's VIDEO REPORTS adds in the rooms before the mission, and lists
    /// from then on.
    video_reports: []const video_reports.Report = &.{},

    /// A loadout tier a mission can move the campaign to, from 1 to `last_tier`.
    pub const Tier = std.math.IntFittingRange(1, last_tier);
    /// A chapter of the story, from 1 to `last_chapter`.
    pub const Chapter = std.math.IntFittingRange(1, last_chapter);

    /// The original's settings for each mission, from mission 1.
    pub const original: [last_mission]CampaignMission = missions: {
        var missions: [last_mission]CampaignMission = undefined;
        for (&missions, briefing.Plan.campaign, first_mission..) |*mission, plan, number| {
            mission.* = .{
                .briefing = plan,
                .carrier = .original(number),
                .tier = if (mission_tiers[number - 1] == 0) null else mission_tiers[number - 1],
                .chapter = ribbonOf(number),
                .medal = Medal.of(number),
                .induction = number == original_induction,
                .lesson = number == original_lesson,
                .only_ship = if (number == original_shroud) .of(.shroud) else null,
                .television_report = rooms.News.original(number),
                .debriefing = debriefing.original(number),
                .news = news_reports.Item.original(number),
                .video_reports = video_reports.Report.original(number),
            };
        }
        break :missions missions;
    };

    /// The missions the original singles out by number: a new pilot's induction comes before
    /// mission 1 (`0x004AA229`), the loadout teaches in mission 1 (`0x00441B6F`), and it offers
    /// only the Shroud in mission 23 (`0x0044341E`).
    const original_induction = 1;
    const original_lesson = 1;
    const original_shroud = 23;
};

/// The highest loadout tier. The campaign's tier goes from 0 at the start up to it.
pub const last_tier = std.math.maxInt(u2);

/// The number of the story's last chapter. Each chapter has a ribbon and a movie.
pub const last_chapter = 5;

comptime {
    assert(last_chapter <= save.ribbons);
}

/// The campaign's missions from mission 1: the original's until OpenReliant installs the records'
/// table (`installMissions`).
var installed_missions: []const CampaignMission = &CampaignMission.original;

/// Uses `missions` as the campaign's missions, from mission 1. OpenReliant installs the records'
/// table at startup. The records own that table, so a game mode's changes to its missions come and
/// go with the mode.
pub fn installMissions(missions: []const CampaignMission) void {
    installed_missions = missions;
}

/// Mission `mission`'s settings; null for a mission outside the campaign's table, such as Instant
/// Action's or a training mission.
pub fn campaignMission(mission: u16) ?*const CampaignMission {
    if (mission < first_mission or mission - first_mission >= installed_missions.len) return null;
    return &installed_missions[mission - first_mission];
}

/// Field `field` of mission `mission`'s settings. A mission outside the campaign's table gets the
/// field's default: no awards and no special cases.
pub fn campaignField(mission: u16, comptime field: std.meta.FieldEnum(CampaignMission)) @FieldType(CampaignMission, @tagName(field)) {
    if (campaignMission(mission)) |settings| return @field(settings, @tagName(field));
    const info = @typeInfo(CampaignMission).@"struct";
    const at = @backingInt(field);
    return comptime info.field_attrs[at].defaultValue(info.field_types[at]).?;
}

/// The names campaign mission `mission` gives its objectives, in place of its row of the game's
/// table; null where it gives none.
pub fn campaignObjectives(mission: u16) ?*const hud.Objectives.Names {
    const settings = campaignMission(mission) orelse return null;
    if (settings.objectives) |*names| return names;
    return null;
}

/// The mission the campaign goes on to after mission `mission` (`Order.next`).
pub fn nextMission(mission: u16) u16 {
    return installed.next(mission);
}

/// The mission the campaign comes to mission `mission` from (`Order.previous`).
pub fn previousMission(mission: u16) ?u16 {
    return installed.previous(mission);
}

/// The number the player sees for mission `mission` (`Order.shown`).
pub fn displayNumber(mission: u16) u16 {
    return installed.shown(mission);
}

test Order {
    const game = Order.original;
    // The game's step from one mission to the next (`mission_end_record`).
    for (0..story_end) |number| {
        const mission: u16 = @intCast(number);
        const step: u16 = switch (mission) {
            11, 12 => 14,
            16 => 18,
            21 => 23,
            else => mission + 1,
        };
        try std.testing.expectEqual(step, game.next(mission));
    }
    // The game's table of the numbers the player sees (`mission_display_numbers`): mission 14 is
    // the twelfth flown, and missions 12 and 13 share its place.
    const display_numbers = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 12, 13, 14, 17, 15, 16, 17, 18, 22, 19, 20, 21, 22, 23, 24, 0, 0, 0 };
    for (display_numbers, 0..) |number, mission| try std.testing.expectEqual(number, game.shown(@intCast(mission)));
    try std.testing.expectEqual(0, game.shown(40));
    try std.testing.expectEqual(11, game.place(12));
    try std.testing.expectEqual(11, game.place(14));
    // Each mission comes after the one before it.
    try std.testing.expectEqual(null, game.previous(first_mission));
    try std.testing.expectEqual(11, game.previous(14));
    for (game.missions()[1..]) |mission| try std.testing.expectEqual(mission, game.next(game.previous(mission).?));

    // With the cut missions back in their places, the campaign flies all 28, and each shows its
    // own number.
    var all: [last_mission]u16 = undefined;
    for (&all, first_mission..) |*mission, number| mission.* = @intCast(number);
    const restored: Order = try .of(&all);
    try std.testing.expectEqual(12, restored.next(11));
    try std.testing.expectEqual(13, restored.next(12));
    try std.testing.expectEqual(14, restored.shown(14));
    try std.testing.expectEqual(story_end, restored.next(last_mission));

    // A campaign of a mod's own, of three missions from the fifth.
    const own: Order = try .of(&.{ 5, 9, 20 });
    try std.testing.expectEqual(5, own.first());
    try std.testing.expectEqual(9, own.next(5));
    try std.testing.expectEqual(story_end, own.next(20));
    try std.testing.expectEqual(2, own.shown(9));
    try std.testing.expectEqual(6, own.shown(6));
    try std.testing.expectEqual(5, own.previous(9));

    // Lists the campaign can't fly.
    try std.testing.expectError(error.Empty, Order.of(&.{}));
    try std.testing.expectError(error.OutOfRange, Order.of(&.{ 0, 1 }));
    try std.testing.expectError(error.OutOfRange, Order.of(&.{ 1, story_end }));
    try std.testing.expectError(error.NotRising, Order.of(&.{ 1, 3, 2 }));
    try std.testing.expectError(error.NotRising, Order.of(&.{ 1, 1 }));
}

test "CampaignMission.original" {
    for (CampaignMission.original, briefing.Plan.campaign, first_mission..) |mission, plan, number| {
        try std.testing.expectEqual(plan, mission.briefing);
        try std.testing.expectEqual(rooms.Carrier.original(@intCast(number)), mission.carrier);
        try std.testing.expectEqual(null, mission.objectives);
    }
}

test "the canon campaign's missions keep the rules OpenReliant 0.8 applied by number" {
    // As 0.8 wrote them, by the mission's number: the Reliant up to mission 18, and its hangar's
    // movies on the second disc; no objectives' names of the campaign's own; mission 1's movie for
    // missions 12, 13, 17 and 22; and the last word for any number.
    var hangar: movies.Hangar = .{};
    for (0..1000) |number| {
        const mission: u16 = @intCast(number);
        const on_reliant = mission <= 18;
        try std.testing.expectEqual(@as(rooms.Carrier, if (on_reliant) .reliant else .yamato), rooms.Carrier.of(mission));
        const launch = hangar.next(mission);
        try std.testing.expectEqual(@as(@TypeOf(launch.disc), if (on_reliant) .two else .one), launch.disc);
        try std.testing.expectEqual(@as(u8, if (on_reliant) 'r' else 'y'), launch.name[0]);
        try std.testing.expectEqual(null, campaignObjectives(mission));
    }
    for (CampaignMission.original, 1..) |mission, number| {
        var movie: [16]u8 = undefined;
        var tag: [32]u8 = undefined;
        const shown: usize = switch (number) {
            12, 13, 17, 22 => 1,
            else => number,
        };
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&movie, "new_m{d:0>2}.bik", .{shown}), mission.briefing.hologram.?);
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&tag, "ms_speech\\enrbr_tag{d:0>2}.ut", .{number}), mission.briefing.last_word.?);
        try std.testing.expectEqual(null, mission.briefing.speech);
    }
}

test installMissions {
    var missions = CampaignMission.original;
    missions[11].carrier = .yamato;
    var names: hud.Objectives.Names = @splat(null);
    names[0] = "Protect the Reliant";
    missions[11].objectives = names;
    installMissions(&missions);
    defer installMissions(&CampaignMission.original);
    // The carrier, and what follows it, comes from the installed table.
    try std.testing.expectEqual(.yamato, rooms.Carrier.of(12));
    try std.testing.expectEqual(.reliant, rooms.Carrier.of(11));
    var hangar: movies.Hangar = .{};
    try std.testing.expectEqualStrings("y_h_tb.bik", hangar.next(12).name);
    try std.testing.expectEqualStrings("Protect the Reliant", campaignObjectives(12).?[0].?);
    try std.testing.expectEqual(null, campaignObjectives(11));
    // A number past the table's, such as Instant Action's, keeps the original's rule.
    try std.testing.expectEqual(null, campaignMission(29));
    try std.testing.expectEqual(.yamato, rooms.Carrier.of(29));
    try std.testing.expectEqual(null, campaignMission(0));
}

test campaignField {
    try std.testing.expectEqual(.black_eagle, campaignField(11, .medal));
    try std.testing.expectEqual(1, campaignField(11, .tier));
    try std.testing.expect(campaignField(1, .induction));
    // A mission outside the table, such as Instant Action's, gets no awards and no special cases.
    try std.testing.expectEqual(null, campaignField(40, .medal));
    try std.testing.expectEqual(null, campaignField(0, .chapter));
    try std.testing.expect(!campaignField(40, .lesson));
}

test "a mission's end awards what its settings hold" {
    var missions = CampaignMission.original;
    missions[11].medal = .valour;
    missions[11].chapter = 2;
    missions[11].tier = 2;
    missions[10].medal = null;
    missions[10].chapter = null;
    missions[10].tier = null;
    installMissions(&missions);
    defer installMissions(&CampaignMission.original);
    var wingmen: pilots.Wingmen = .{};
    var player: input.Player = .{};
    var variables: vm.Variables = .{ .mission_success = .success_bonus };
    var campaign: Campaign = .begin();
    // Mission 12 now awards the Medal of Valour and ribbon 2, and raises the tier to 2.
    try std.testing.expectEqual(Record{ .next = 14, .tier = 2, .medal = .valour }, endMission(&player, &variables, 12, 0, &campaign, &wingmen).?);
    try std.testing.expect(campaign.medals.contains(.valour) and campaign.ribbons.isSet(1));
    // Mission 11 now awards nothing and leaves the tier as it is.
    campaign = .begin();
    try std.testing.expectEqual(Record{ .next = 14, .tier = 1 }, endMission(&player, &variables, 11, 1, &campaign, &wingmen).?);
    try std.testing.expectEqual(0, campaign.medals.count());
    try std.testing.expectEqual(0, campaign.ribbons.count());
}

test install {
    defer install(.original);
    install(try .of(&.{ 4, 6, 7 }));
    try std.testing.expectEqual(4, campaignOrder().first());
    try std.testing.expectEqual(7, nextMission(6));
    try std.testing.expectEqual(story_end, nextMission(7));
    try std.testing.expectEqual(4, previousMission(6));
    try std.testing.expectEqual(2, displayNumber(6));
}

/// The pilot's ribbons, ribbon 1 first: one for each chapter of the story the pilot has come
/// through (`pilot_ribbons`).
pub const Ribbons = std.bit_set.Static(save.ribbons);

/// The chapter mission `mission` ends in the original, whose ribbon the pilot gets
/// (`ribbon_of_mission`, `0x0050099F`): missions 7, 11, 19, 21 and 25 end chapters 1 to 5.
/// `CampaignMission.original` copies it.
fn ribbonOf(mission: u16) ?CampaignMission.Chapter {
    return switch (mission) {
        7 => 1,
        11 => 2,
        19 => 3,
        21 => 4,
        25 => 5,
        else => null,
    };
}

/// A medal a mission can award. Each has a ceremony movie (`medal_movies`, `0x00500A08`).
pub const Medal = enum(u3) {
    /// The name scripts know these values by.
    pub const script_name = "Medal";

    silver = 1,
    black_eagle = 2,
    valour = 3,
    legion = 4,
    navy_cross = 5,
    medal_of_honour = 6,

    /// The medal mission `mission` awards in the original (`medal_of_mission`, `0x005009BB`):
    /// missions 6, 11, 16, 21, 23 and 27 award the six medals in order. `CampaignMission.original`
    /// copies it.
    fn of(mission: u16) ?Medal {
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

/// The movie of the ceremony as mission `mission` awards the pilot `medal`. `movie` is the medal's
/// own (`Medal.movie`), and scripts can change it (`medal_ceremony`).
///
/// **Improvement:** a step of OpenReliant's own, so that scripts can choose the movie. The game
/// plays the ceremony inside `mission_end_record` (`0x00475B98`).
pub fn ceremonyMovie(all: *create.Objects, medal: Medal, mission: u16, movie: ?movies.Name) ?movies.Name {
    if (hooks.enter(.medal_ceremony, ceremonyMovie, .{ all, medal, mission, movie })) |done| return done;
    return movie;
}

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

test ribbonOf {
    try std.testing.expectEqual(1, ribbonOf(7));
    try std.testing.expectEqual(5, ribbonOf(25));
    try std.testing.expectEqual(null, ribbonOf(28));
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
    std.testing.refAllDecls(@This());
}
