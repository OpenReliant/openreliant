//! The campaign's missions as scripts see them in `openreliant.records.missions`
//! ([#976](https://github.com/OpenReliant/openreliant/issues/976)). Each mission, indexed by its
//! number, is a proxy for its `gameflow.CampaignMission`, and load scripts change its fields in
//! place, as they do a record's. Assigning a table to a mission changes only the fields the table
//! holds. A replacement campaign sets all of its missions, a restoration sets the missions it puts
//! back, and a small mod sets the one field it changes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const game = openreliant.engine.game;
const gameflow = game.gameflow;
const hud = game.hud;
const gameobj = game.gameobj;
const language = game.language;
const rooms = game.interface.rooms;
const debriefing = game.itac.debriefing;
const landing = game.xtrabits.landing;
const pilots = game.pilots;
const vm = openreliant.engine.vm;
const Rating = vm.Variables.Outcome;
const luau = @import("../luau.zig");
const State = luau.State;
const bind = @import("../bind.zig");
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const table = @import("table.zig");
const Records = records.Records;

/// The name scripts know a mission by.
pub const script_name = "CampaignMission";

/// How the reference and the definitions introduce the missions.
pub const each = "Each of the campaign's missions";
pub const entries_about = "The settings of each of the campaign's missions, by its number. Load scripts change their fields.";

/// A mission's fields, as scripts name them.
pub const Field = enum {
    hologram,
    speech,
    last_word,
    carrier,
    objectives,
    date,
    tier,
    chapter,
    medal,
    induction,
    lesson,
    only_ship,
    television_report,
    debriefing,
    news,
    video_reports,
    landing_carrier,
    yamato_visit,
    chapter_reports,
    alpha_5_pilot,
    alpha_6_pilot,
    wing_twins,
    flying_tigers,
    second_part,
    kamov_wing,
    close_ion_cannons,
    hurried_turrets,
    ripper_from_below,
    wide_advanced_gate,
    counts_kills,
    terminate_ends_well,
    fort_bear_ending,
    cobras_inquiry,
    fifty_first_listed,

    /// Whether the field is one of the mission's rules (`gameflow.CampaignMission.Rules`), which
    /// scripts read and set as booleans.
    fn isRule(comptime field: Field) bool {
        return @hasField(gameflow.CampaignMission.Rules, @tagName(field));
    }
};

/// The type of `field`'s value as scripts read it, which the definitions and the reference show.
pub fn TypeOf(comptime field: Field) type {
    return switch (field) {
        .hologram, .speech, .last_word, .date => ?[]const u8,
        .carrier => rooms.Carrier,
        .objectives => values.List([]const u8, hud.Objectives.per_mission),
        .tier, .chapter => ?u8,
        .medal => ?gameflow.Medal,
        .only_ship => ?gameobj.Type,
        .television_report => values.List(ReportPart, most_parts),
        .debriefing => Debriefing,
        .news => values.List(NewsItem, most_items),
        .video_reports => values.List(VideoReport, most_items),
        .landing_carrier => rooms.Carrier,
        .yamato_visit => landing.YamatoVisit,
        .chapter_reports => values.List(ChapterReport, landing.Reports.most),
        .alpha_5_pilot, .alpha_6_pilot => pilots.Number,
        else => if (field.isRule()) bool else @compileError("no type for " ++ @tagName(field)),
    };
}

/// What the reference says of `field`.
pub fn about(field: Field) []const u8 {
    return switch (field) {
        .hologram => "The movie on the briefing room's screen, a Bink file from the game or a mod, such as `new_m01.bik`; nil for none.",
        .speech => "Enriquez's briefing spoken over the briefing room, a speech file from the game or a mod; nil for none. The briefing ends when she finishes. While she speaks, the movie plays on the screen without its sound, and starts over if it ends first; set `hologram` to nil for an empty screen.",
        .last_word => "Enriquez's last word after the loadout, a speech file such as `ms_speech\\enrbr_tag01.ut`; nil leaves her silent.",
        .carrier => "The carrier the mission is flown from. The player sees its rooms, briefing room, loadout and hangar.",
        .objectives => "The names of the objectives, at most ten, which the mission's script numbers from 0 in `SetObjective`. Reading gives a new list; assign a list to change them, or nil for the names in the game's own table for the mission's number.",
        .date => "The date the launch shows, which is the game's text for the mission's number; nil for a mission the game has no date for.",
        .tier => "The loadout tier the campaign moves to when the mission ends, from 1 to 3; nil to leave the tier as it is. The tier and the pilot's rank decide which ships the loadout offers. The loadout before a mission uses the highest tier of the missions with lower numbers.",
        .chapter => "The chapter of the story the mission ends, from 1 to 5; nil if it ends none. The pilot gets the chapter's ribbon, the debriefing mentions it, and the chapter's movie plays after the landing.",
        .medal => "The medal the mission awards for a success with its bonus, unless a nanny ship picked the pilot up; nil for none. The medal's ceremony plays when the pilot gets it. After a mission with a medal, the crew in the rooms honour the pilot, even if the pilot didn't get it.",
        .induction => "Whether a new pilot sees the intro and the induction before the mission, when a campaign starts with it.",
        .lesson => "Whether the mission's loadout teaches the player, as mission 1's does: it starts on the Predator with the tier's missiles, plays `loadout.ut` and blinks its exit button.",
        .only_ship => "The only ship the mission's loadout offers, as mission 23's offers the Shroud; nil for the ships the tier and the rank open. The loadout starts on it with the tier's missiles.",
        .television_report => "Enriquez's report on the rooms' television before the mission, as a list of parts that play one after another; an empty list for none. Reading gives a new list; assign a list to change it.",
        .debriefing => "Enriquez's debriefing of the mission in the ITAC: a list of paragraphs for each rating the mission's script can give. Reading gives a new table; assign a table to change it, and a rating left out has no paragraphs.",
        .news => "The news items that NEWS REPORTS in the ITAC adds in the rooms before the mission, and lists from then on. The news of how a mission went goes on the mission after it. Reading gives a new list; assign a list to change them.",
        .video_reports => "The video reports that VIDEO REPORTS in the ITAC adds in the rooms before the mission, and lists from then on. Reading gives a new list; assign a list to change them.",
        .landing_carrier => "The carrier the landing plays on after the mission, which picks the chapter's disc and zoom too where the mission ends a chapter: the Yamato from mission 18 on, the Reliant before.",
        .yamato_visit => "Whether the ship lands on the Yamato after the mission with a failure's thread and bank, whatever the rating: `never`, `always` as after mission 7, or `when_reliant_lost` as after mission 8, where `reliant_alive` is clear.",
        .chapter_reports => "The news reports that play after the chapter's movie, where the mission ends a chapter, at most eight. Each plays unless one of the game's variables in `unless` is 1, and then sets the variable `sets` to 1, if any. Reading gives a new list; assign a list to change them.",
        .alpha_5_pilot => "The pilot who flies as Alpha 5 from the mission on, such as `diceman`; `none` leaves the pilot there as they are.",
        .alpha_6_pilot => "The pilot who flies as Alpha 6 from the mission on, such as `bandit_volunteers_leader`; `none` leaves the pilot there as they are.",
        .wing_twins => "Whether the player's wing flies the `t_` twins of the player's ships, as in missions 14 and later.",
        .flying_tigers => "Whether the 45th fly as the 45th Flying Tigers rather than the 45th Volunteers, in the radio's films and in Moose's remarks, as after mission 13.",
        .second_part => "Whether the mission has a second part, `mission<number>1.dte`, flown once the first part is won, as mission 25 has. The second part has no landing before it.",
        .kamov_wing => "Whether the player's wing flies Kamovs, in the first part where the mission has two, as in mission 25. The Kamov's schematic is then drawn mirrored.",
        .close_ion_cannons => "Whether the ion cannons' lock lets a player's ship come much closer before it breaks, as in mission 28.",
        .hurried_turrets => "Whether the missile turrets wait half as long between launches, as in mission 28.",
        .ripper_from_below => "Whether the Ripper lifts an object from below rather than from above, as in mission 26.",
        .wide_advanced_gate => "Whether the advanced warp gates' tunnels are as wide as the prototype's, as in mission 8.",
        .counts_kills => "Whether the player's kills count toward the mission's tally, as in missions 1 to 27.",
        .terminate_ends_well => "Whether the mission's script can end it with `TerminateMission` without the ending counting as the player's ship destroyed, as in mission 28.",
        .fort_bear_ending => "Whether, once the Yamato is lost (`yamato_alive` clear), no landing plays after the mission, and a total failure ends the pilot's career in the shuttle at Fort Bear, as in missions 25 and 27.",
        .cobras_inquiry => "Whether the ITAC's history of the 705 Cobras tells of the inquiry into their colonel, as from mission 7 on.",
        .fifty_first_listed => "Whether the ITAC's squadrons list the 51st Volunteers, as in missions 1 to 9.",
    };
}

comptime {
    // Every rule has a field of the same name.
    for (@typeInfo(gameflow.CampaignMission.Rules).@"struct".field_names) |name| std.debug.assert(@hasField(Field, name));
}

/// Limits on what a script gives: the paragraphs of a debriefing, a news item or a video report,
/// the news items or video reports of a mission, and the parts of a report.
const most_paragraphs = 16;
const most_items = 16;
const most_parts = 8;

const Paragraphs = values.List([]const u8, most_paragraphs);

/// A part of Enriquez's report on the rooms' television, as scripts see it.
pub const ReportPart = struct {
    pub const script_name = "ReportPart";

    /// Enriquez's scene, a `.box` file from the game or a mod, such as `0015.box`.
    scene: []const u8,
    /// The movie the scene plays over; nil for the carrier's television.
    movie: ?[]const u8 = null,
};

/// A debriefing as scripts see it: Enriquez's paragraphs for each rating.
pub const Debriefing = struct {
    pub const script_name = "Debriefing";

    failure: Paragraphs = .{},
    partial_failure: Paragraphs = .{},
    partial_success: Paragraphs = .{},
    success: Paragraphs = .{},
    success_bonus: Paragraphs = .{},
};

comptime {
    // The fields go in the order of the ratings, which index the debriefing's text.
    const fields = @typeInfo(Debriefing).@"struct".field_names;
    std.debug.assert(fields.len == debriefing.ratings);
    for (fields, 0..) |name, rating| std.debug.assert(std.mem.eql(u8, name, @tagName(@as(Rating, @fromBackingInt(@intCast(rating))))));
}

/// A news report after a chapter's movie, as scripts see it.
pub const ChapterReport = struct {
    pub const script_name = "ChapterReport";

    /// Its movie, a Bink file from the game or a mod.
    movie: []const u8,
    /// The game's variables that keep it from playing where one is 1.
    unless: values.List(vm.GameVariable, most_conditions) = .{},
    /// The variable it sets to 1 as it plays; nil for none.
    sets: ?vm.GameVariable = null,
};

/// The most variables a chapter's news report waits on.
const most_conditions = 4;

/// A news item, as scripts see it.
pub const NewsItem = struct {
    pub const script_name = "NewsItem";

    title: []const u8,
    paragraphs: Paragraphs = .{},
    /// The shape of its picture in `inter\itac\newsrep.spr`.
    picture: u16,
};

/// A video report, as scripts see it.
pub const VideoReport = struct {
    pub const script_name = "VideoReport";

    title: []const u8,
    paragraphs: Paragraphs = .{},
    /// The shape of its still in `inter\itac\vidrep.spr`.
    still: u16,
    /// Its movie, a Bink file from the game or a mod.
    movie: []const u8,
    /// The carrier whose disc holds the movie.
    carrier: rooms.Carrier,
};

/// The proxies of the campaign's missions (`table.Table`).
const proxies = table.Table(@This());
pub const register = proxies.register;
pub const push = proxies.push;

/// What the proxies need of the missions (`table.Table`).
pub const list_name = "missions";
pub const described = "the campaign's missions";
pub const item_noun = "a mission";
pub const list_tag = @backingInt(runtime.Tag.campaign_missions);
pub const item_tag = @backingInt(runtime.Tag.campaign_mission);

pub fn count(held: *const Records) usize {
    return held.missions.len;
}

/// A mission, as its proxy holds it.
const Mission = table.Item;

/// The settings of `mission`.
fn settingsOf(mission: Mission) *gameflow.CampaignMission {
    return &mission.records.missions[mission.place];
}

/// Pushes the value of `wanted` of `mission`.
pub fn getField(state: *State, mission: Mission, wanted: Field) void {
    const settings = settingsOf(mission);
    switch (wanted) {
        inline .hologram, .speech, .last_word => |field| {
            const plan_field = comptime @tagName(field);
            if (@field(settings.briefing, plan_field)) |file| state.pushString(file) else state.pushNil();
        },
        .carrier => values.push(state, rooms.Carrier, settings.carrier),
        .objectives => pushObjectives(state, mission),
        inline .tier, .chapter => |field| {
            const value: ?u8 = if (@field(settings, @tagName(field))) |number| number else null;
            values.push(state, ?u8, value);
        },
        inline .medal, .only_ship, .landing_carrier, .yamato_visit, .alpha_5_pilot, .alpha_6_pilot => |field| values.push(state, TypeOf(field), @field(settings, @tagName(field))),
        inline .television_report, .news, .video_reports, .chapter_reports => |field| table.pushItems(state, mission.records, @field(settings, @tagName(field))),
        .debriefing => {
            state.newTable(0, debriefing.ratings);
            inline for (@typeInfo(Debriefing).@"struct".field_names, settings.debriefing) |rating, paragraphs| {
                table.pushValue(state, mission.records, []const language.Words, paragraphs);
                state.rawSetField(-2, rating);
            }
        },
        .date => {
            const text = dateText(mission) orelse return state.pushNil();
            records.pushText(state, mission.records.text[text - 1]);
        },
        inline else => |rule| {
            comptime std.debug.assert(rule.isRule());
            state.pushBoolean(@field(settings.rules, @tagName(rule)));
        },
    }
}

/// Sets `field` of `mission` from the value at `given`.
pub fn setField(state: *State, mission: Mission, field: Field, given: i32) void {
    const held = mission.records;
    const settings = settingsOf(mission);
    switch (field) {
        inline .hologram, .speech, .last_word => |name| {
            const label = comptime script_name ++ "." ++ @tagName(name);
            const file = values.read(state, ?[]const u8, given, label);
            @field(settings.briefing, @tagName(name)) = table.kept(?[]const u8, state, held, file, label);
        },
        .carrier => settings.carrier = values.read(state, rooms.Carrier, given, script_name ++ ".carrier"),
        .objectives => {
            const label = script_name ++ ".objectives";
            const list = values.read(state, ?values.List([]const u8, hud.Objectives.per_mission), given, label) orelse {
                settings.objectives = null;
                return;
            };
            settings.objectives = objectiveNames(held.arena, list.slice()) catch |err| switch (err) {
                error.OutOfMemory => state.raise(label ++ ": out of memory", .{}),
                error.BadName => state.raise(label ++ ": " ++ bad_objective_name, .{}),
            };
        },
        .date => {
            const text = dateText(mission) orelse state.raise("{s}.date: mission {d} has no date the game shows", .{ script_name, mission.number() });
            held.text[text - 1] = records.textOf(state, held.arena, given, script_name ++ ".date");
        },
        .tier => settings.tier = readNumber(state, gameflow.CampaignMission.Tier, given, gameflow.last_tier, script_name ++ ".tier"),
        .chapter => settings.chapter = readNumber(state, gameflow.CampaignMission.Chapter, given, gameflow.last_chapter, script_name ++ ".chapter"),
        inline .medal, .only_ship, .landing_carrier, .yamato_visit, .alpha_5_pilot, .alpha_6_pilot => |name| {
            @field(settings, @tagName(name)) = values.read(state, TypeOf(name), given, script_name ++ "." ++ @tagName(name));
        },
        inline .television_report, .news, .video_reports, .chapter_reports => |name| {
            const label = comptime script_name ++ "." ++ @tagName(name);
            const list = values.read(state, TypeOf(name), given, label);
            const Kept = std.meta.Elem(@FieldType(gameflow.CampaignMission, @tagName(name)));
            @field(settings, @tagName(name)) = table.keptItems(Kept, state, held, list.slice(), label);
        },
        .debriefing => {
            const label = script_name ++ ".debriefing";
            const read = values.read(state, Debriefing, given, label);
            inline for (&settings.debriefing, @typeInfo(Debriefing).@"struct".field_names) |*paragraphs, rating| {
                paragraphs.* = table.kept([]const language.Words, state, held, @field(read, rating), label);
            }
        },
        inline else => |name| {
            comptime std.debug.assert(name.isRule());
            @field(settings.rules, @tagName(name)) = values.read(state, bool, given, script_name ++ "." ++ @tagName(name));
        },
    }
}

/// Reads the number at `given`, from 1 to `last`, or nil. Raises an error naming `label` for
/// anything else.
fn readNumber(state: *State, comptime T: type, given: i32, comptime last: comptime_int, comptime label: []const u8) ?T {
    const number = values.read(state, ?u8, given, label) orelse return null;
    if (number < 1 or number > last) state.raise(label ++ ": expected a number from 1 to {d}, or nil, got {d}", .{ last, number });
    return @intCast(number);
}

/// The game's text the launch shows as mission `mission`'s date (`hud.Caption.date`), where the
/// records hold it; null otherwise.
fn dateText(mission: Mission) ?u16 {
    const text = hud.Caption.date(mission.number()) orelse return null;
    return if (text >= 1 and text <= mission.records.text.len) text else null;
}

/// Pushes the names of `mission`'s objectives as a new list: those a script gave it, or else its
/// row of the game's table, as the records' text holds the strings.
fn pushObjectives(state: *State, mission: Mission) void {
    var objectives: hud.Objectives = .{};
    objectives.reset(mission.number(), false, if (settingsOf(mission).objectives) |*names| names else null);
    const text = mission.records.language(.text);
    state.newTable(hud.Objectives.per_mission, 0);
    var listed: i32 = 0;
    for (0..hud.Objectives.per_mission) |objective| {
        const name = switch (objectives.name(@intCast(objective)) orelse continue) {
            .string => |string| text.string(string) orelse continue,
            .text => |own| own,
        };
        listed += 1;
        records.pushText(state, name);
        state.rawSetIndex(-2, listed);
    }
}

/// What a script hears when it gives an objective a name the game can't show.
pub const bad_objective_name = std.fmt.comptimePrint("an objective's name must be valid UTF-8 of at most {d} characters", .{language.max_length});

/// The names of a mission's objectives a script gives, `given`, kept in `memory` in the game's code
/// page (`language.encode`), as the flight display shows them (`hud.Objectives.Names`). Errors where
/// a name isn't valid UTF-8 or is too long.
pub fn objectiveNames(memory: Allocator, given: []const []const u8) (Allocator.Error || error{BadName})!hud.Objectives.Names {
    var names: hud.Objectives.Names = @splat(null);
    for (names[0..given.len], given) |*name, text| {
        const characters = std.unicode.utf8CountCodepoints(text) catch return error.BadName;
        if (characters > language.max_length) return error.BadName;
        var buffer: [language.max_length]u8 = undefined;
        name.* = try memory.dupe(u8, language.encode(&buffer, text));
    }
    return names;
}

/// Records for the tests: the game's missions, and the text with the dates and mission 12's
/// objective the game holds.
fn testRecords(arena: Allocator, text: [][]const u8) !Records {
    @memset(text, "");
    text[456] = "Destroy the Reliant's attackers"; // 457, mission 12's objective
    text[988] = "aaaa"; // 989, mission 12's date
    return .init(arena, .{ .ships = &.{}, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = text, .itac_text = &.{} });
}

/// A sandboxed thread with the records as the global `records`, changeable where `writable`.
fn testThread(state: *State, held: *Records, writable: bool) *State {
    state.openLibraries();
    records.register(state);
    records.push(state, held, writable);
    state.setGlobal("records");
    state.sandbox();
    return state.newSandboxedThread();
}

test "a campaign mission's fields, read and changed in place" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var text: [1010][]const u8 = undefined;
    var held = try testRecords(arena.allocator(), &text);
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    const thread = testThread(state, &held, true);

    try bind.testing.runSource(thread,
        \\local missions = records.missions
        \\assert(#missions == 28 and missions[0] == nil and missions[29] == nil and tostring(missions[12]) == "CampaignMission")
        \\-- The original's values.
        \\local cut = missions[12]
        \\assert(cut.hologram == "new_m01.bik" and cut.speech == nil and cut.last_word == "ms_speech\\enrbr_tag12.ut")
        \\assert(cut.carrier == "reliant" and missions[22].carrier == "yamato")
        \\assert(#cut.objectives == 1 and cut.objectives[1] == "Destroy the Reliant's attackers")
        \\assert(cut.date == "aaaa" and #missions[22].objectives == 0)
        \\-- A restoration's changes, field by field.
        \\cut.hologram = nil
        \\cut.speech = "dreamcast_brief12.ut"
        \\cut.objectives = { "Protect the Reliant", "Destroy the Black Guard" }
        \\cut.date = "February 2, 2161"
        \\assert(missions[12].speech == "dreamcast_brief12.ut" and missions[12].objectives[2] == "Destroy the Black Guard")
        \\-- A table changes only the fields it holds.
        \\missions[22] = { carrier = "reliant", hologram = "new_m22.bik" }
        \\assert(missions[22].carrier == "reliant" and missions[22].last_word == "ms_speech\\enrbr_tag22.ut")
        \\local count = 0
        \\for number, mission in missions do count += number end
        \\assert(count == 28 * 29 / 2)
    );
    const twelve = held.missions[11];
    try std.testing.expectEqual(null, twelve.briefing.hologram);
    try std.testing.expectEqualStrings("dreamcast_brief12.ut", twelve.briefing.speech.?);
    try std.testing.expectEqualStrings("Protect the Reliant", twelve.objectives.?[0].?);
    try std.testing.expectEqual(null, twelve.objectives.?[2]);
    try std.testing.expectEqualStrings("February 2, 2161", held.text[988]);
    try std.testing.expectEqual(.reliant, held.missions[21].carrier);
    try std.testing.expectEqualStrings("new_m22.bik", held.missions[21].briefing.hologram.?);

    // Nil for the objectives gives back the game's table's names.
    try bind.testing.runSource(thread, "records.missions[12].objectives = nil; assert(records.missions[12].objectives[1] == \"Destroy the Reliant's attackers\")");
    try std.testing.expectEqual(null, held.missions[11].objectives);

    try bind.testing.expectSourceError(thread, "records.missions[12].nothing = 1", "CampaignMission has no field 'nothing'");
    try bind.testing.expectSourceError(thread, "local _ = records.missions[12].nothing", "CampaignMission has no field 'nothing'");
    try bind.testing.expectSourceError(thread, "records.missions[12].carrier = 'enterprise'", "CampaignMission.carrier");
    try bind.testing.expectSourceError(thread, "records.missions[12].hologram = 5", "CampaignMission.hologram");
    try bind.testing.expectSourceError(thread, "records.missions[12].objectives = { string.rep('x', 999) }", bad_objective_name);
    try bind.testing.expectSourceError(thread, "records.missions[29] = {}", "records.missions[29] does not exist: the campaign's missions are 1 to 28");
    try bind.testing.expectSourceError(thread, "records.missions[12] = nil", "a mission can't be removed");
    try bind.testing.expectSourceError(thread, "records.missions[12] = { [1] = 'x' }", "a table of fields has names for keys");
}

test "a campaign mission's report, debriefing, news and video reports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var text: [1010][]const u8 = undefined;
    var held = try testRecords(arena.allocator(), &text);
    held.itac_text = try arena.allocator().alloc([]const u8, 1700);
    @memset(held.itac_text, "");
    held.itac_text[10] = "Placeholder"; // 11, the first paragraph of mission 12's failure
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    const thread = testThread(state, &held, true);

    try bind.testing.runSource(thread,
        \\local missions = records.missions
        \\-- The original's values.
        \\local cut = missions[12]
        \\assert(#cut.television_report == 1 and cut.television_report[1].scene == "0115.box" and cut.television_report[1].movie == nil)
        \\assert(#missions[1].television_report == 3 and missions[1].television_report[2].movie == "tv_cald.bik")
        \\assert(#cut.debriefing.failure == 5 and cut.debriefing.failure[1] == "Placeholder")
        \\assert(#cut.news == 0 and #missions[14].news == 1 and missions[14].news[1].picture == 15)
        \\local chapter = missions[20].video_reports[1]
        \\assert(chapter.movie == "new_chapter3.bik" and chapter.carrier == "yamato" and #chapter.paragraphs == 2)
        \\-- A restoration's own.
        \\cut.television_report = { { scene = "dreamcast_0115.box" } }
        \\local debriefing = cut.debriefing
        \\debriefing.success = { "Good work, Lieutenant.", "Café" }
        \\cut.debriefing = debriefing
        \\cut.news = { { title = "The Reliant holds", paragraphs = { "She took a beating." }, picture = 14 } }
        \\missions[20].video_reports = {}
        \\assert(cut.debriefing.success[2] == "Café" and cut.news[1].title == "The Reliant holds")
    );
    const twelve = held.missions[11];
    try std.testing.expectEqualStrings("dreamcast_0115.box", twelve.television_report[0].scene);
    try std.testing.expectEqual(null, twelve.television_report[0].movie);
    // Assigning the table read back keeps the other ratings' paragraphs, now as text.
    try std.testing.expectEqualStrings("Placeholder", twelve.debriefing[0][0].text);
    try std.testing.expectEqualStrings("Caf\xe9", twelve.debriefing[3][1].text);
    try std.testing.expectEqualStrings("The Reliant holds", twelve.news[0].title.text);
    try std.testing.expectEqual(14, twelve.news[0].picture);
    try std.testing.expectEqual(0, held.missions[19].video_reports.len);

    try bind.testing.expectSourceError(thread, "records.missions[12].news = { { title = 'x' } }", "the field 'picture' is missing");
    try bind.testing.expectSourceError(thread, "records.missions[12].debriefing = { excellent = {} }", "there's no field 'excellent'");
    try bind.testing.expectSourceError(thread, "records.missions[12].video_reports = { { title = 'x', still = 1, movie = 'x.bik', carrier = 'nanny' } }", "CampaignMission.video_reports.carrier");
}

test "a campaign mission's rules" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var text: [1010][]const u8 = undefined;
    var held = try testRecords(arena.allocator(), &text);
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    const thread = testThread(state, &held, true);

    try bind.testing.runSource(thread,
        \\local missions = records.missions
        \\-- The original's, by the mission's number.
        \\assert(missions[25].second_part and missions[25].kamov_wing and not missions[24].second_part)
        \\assert(missions[14].wing_twins and missions[14].flying_tigers and not missions[13].flying_tigers)
        \\assert(missions[28].hurried_turrets and not missions[28].counts_kills and missions[27].counts_kills)
        \\-- A replacement campaign's mission 25 is a mission like any other.
        \\missions[25].second_part = false
        \\missions[25].kamov_wing = false
        \\missions[12] = { wing_twins = true, terminate_ends_well = true }
    );
    try std.testing.expect(!held.missions[24].rules.second_part and !held.missions[24].rules.kamov_wing);
    try std.testing.expect(held.missions[11].rules.wing_twins and held.missions[11].rules.terminate_ends_well);
    try std.testing.expect(!held.missions[11].rules.flying_tigers);
    try bind.testing.expectSourceError(thread, "records.missions[12].counts_kills = 1", "CampaignMission.counts_kills");
}

test "a campaign mission's landing, chapter news and wing pilots" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var text: [1010][]const u8 = undefined;
    var held = try testRecords(arena.allocator(), &text);
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    const thread = testThread(state, &held, true);

    try bind.testing.runSource(thread,
        \\local missions = records.missions
        \\-- The original's values.
        \\assert(missions[18].landing_carrier == "yamato" and missions[17].landing_carrier == "reliant")
        \\assert(missions[7].yamato_visit == "always" and missions[8].yamato_visit == "when_reliant_lost")
        \\local report = missions[11].chapter_reports[3]
        \\assert(report.movie == "new_chapter2_thread3.bik" and report.unless[1] == 6 and report.sets == "chapter2_thread3_shown")
        \\assert(missions[7].chapter_reports[1].unless[1] == "rameses_alive")
        \\assert(missions[6].alpha_5_pilot == "diceman" and missions[25].fort_bear_ending)
        \\-- A restoration's own.
        \\local cut = missions[12]
        \\cut.landing_carrier = "yamato"
        \\cut.yamato_visit = "never"
        \\cut.chapter_reports = { { movie = "dreamcast_news12.bik", unless = { "krasnaya_alive", 20 } } }
        \\cut.alpha_6_pilot = "none"
    );
    const twelve = held.missions[11];
    try std.testing.expectEqual(.yamato, twelve.landing_carrier);
    try std.testing.expectEqualStrings("dreamcast_news12.bik", twelve.chapter_reports[0].movie);
    try std.testing.expectEqualSlices(vm.GameVariable, &.{ .krasnaya_alive, @fromBackingInt(20) }, twelve.chapter_reports[0].unless);
    try std.testing.expectEqual(null, twelve.chapter_reports[0].sets);
    try std.testing.expectEqual(.none, twelve.alpha_6_pilot);

    try bind.testing.expectSourceError(thread, "records.missions[12].yamato_visit = 'sometimes'", "CampaignMission.yamato_visit");
    try bind.testing.expectSourceError(thread, "records.missions[12].chapter_reports = { { unless = {} } }", "the field 'movie' is missing");
}

test "a campaign mission's awards and special cases" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var text: [1010][]const u8 = undefined;
    var held = try testRecords(arena.allocator(), &text);
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    const thread = testThread(state, &held, true);

    try bind.testing.runSource(thread,
        \\local missions = records.missions
        \\-- The original's values.
        \\assert(missions[11].tier == 1 and missions[11].chapter == 2 and missions[11].medal == "black_eagle")
        \\assert(missions[12].tier == nil and missions[12].chapter == nil and missions[12].medal == nil)
        \\assert(missions[1].induction and missions[1].lesson and not missions[2].induction)
        \\assert(missions[23].only_ship == "shroud" and missions[22].only_ship == nil)
        \\-- A restoration's changes.
        \\local cut = missions[12]
        \\cut.medal = "valour"
        \\cut.tier = 2
        \\cut.chapter = 3
        \\cut.only_ship = "tempest"
        \\-- A table sets only the fields it holds, so clearing a field takes its own assignment.
        \\missions[11] = { induction = true }
        \\missions[11].medal = nil
        \\missions[11].chapter = nil
    );
    const twelve = held.missions[11];
    try std.testing.expectEqual(.valour, twelve.medal);
    try std.testing.expectEqual(2, twelve.tier);
    try std.testing.expectEqual(3, twelve.chapter);
    try std.testing.expectEqual(gameobj.Type.of(.tempest), twelve.only_ship);
    try std.testing.expectEqual(null, held.missions[10].medal);
    try std.testing.expectEqual(null, held.missions[10].chapter);
    try std.testing.expect(held.missions[10].rules.induction);

    try bind.testing.expectSourceError(thread, "records.missions[12].tier = 4", "CampaignMission.tier: expected a number from 1 to 3");
    try bind.testing.expectSourceError(thread, "records.missions[12].chapter = 0", "CampaignMission.chapter: expected a number from 1 to 5");
    try bind.testing.expectSourceError(thread, "records.missions[12].medal = 'gold'", "CampaignMission.medal");
    try bind.testing.expectSourceError(thread, "records.missions[12].lesson = 'yes'", "CampaignMission.lesson");
}

test "the campaign's missions can only be changed by load scripts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var text: [1010][]const u8 = undefined;
    var held = try testRecords(arena.allocator(), &text);
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    const thread = testThread(state, &held, false);
    try bind.testing.runSource(thread, "assert(records.missions[12].carrier == 'reliant')");
    try bind.testing.expectSourceError(thread, "records.missions[12].carrier = 'yamato'", "records can only be changed by load scripts");
    try bind.testing.expectSourceError(thread, "records.missions[12] = { carrier = 'yamato' }", "records can only be changed by load scripts");
}

test objectiveNames {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const names = try objectiveNames(arena.allocator(), &.{ "Caf\u{e9}", "Two" });
    try std.testing.expectEqualStrings("Caf\xe9", names[0].?);
    try std.testing.expectEqualStrings("Two", names[1].?);
    try std.testing.expectEqual(null, names[2]);
    try std.testing.expectError(error.BadName, objectiveNames(arena.allocator(), &.{"\xff"}));
}
