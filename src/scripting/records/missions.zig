//! What the campaign makes of each of its missions, as scripts see it in
//! `openreliant.records.missions` ([#976](https://github.com/OpenReliant/openreliant/issues/976)):
//! by the mission's number, a proxy for its `gameflow.CampaignMission` whose fields load scripts
//! change in place, as they change a record's. Assigning a table to a mission changes the fields
//! the table gives. A replacement campaign sets each of its missions, a restoration the missions it
//! puts back, and a small mod the one field it changes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const game = openreliant.engine.game;
const gameflow = game.gameflow;
const hud = game.hud;
const gameobj = game.gameobj;
const language = game.language;
const rooms = game.interface.rooms;
const luau = @import("../luau.zig");
const State = luau.State;
const bind = @import("../bind.zig");
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const Records = records.Records;

/// The name scripts know a mission by.
pub const script_name = "CampaignMission";

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

    /// The type of the value scripts read, which the definitions and the reference show.
    pub fn Type(comptime field: Field) type {
        return switch (field) {
            .hologram, .speech, .last_word, .date => ?[]const u8,
            .carrier => rooms.Carrier,
            .objectives => values.List([]const u8, hud.Objectives.per_mission),
            .tier, .chapter => ?u8,
            .medal => ?gameflow.Medal,
            .induction, .lesson => bool,
            .only_ship => ?gameobj.Type,
        };
    }

    /// What the reference says of the field.
    pub fn about(field: Field) []const u8 {
        return switch (field) {
            .hologram => "The movie on the briefing room's screen, a Bink file of the game's or a mod's, such as `new_m01.bik`; nil for none.",
            .speech => "Enriquez's words spoken over the briefing room, a speech file of the game's or a mod's, which end the briefing as they end; nil for none. With words, the movie plays on the screen without its sound, and starts over if it ends before she does; set `hologram` to nil for an empty screen.",
            .last_word => "Enriquez's last word after the loadout, a speech file such as `ms_speech\\enrbr_tag01.ut`; nil leaves her silent.",
            .carrier => "The carrier the mission is flown from, whose rooms, briefing room, loadout and hangar the player sees.",
            .objectives => "The names of the objectives, which the mission's script numbers from 0 in `SetObjective`, at most ten. Reading gives a new list; assign a list to change them, or nil for the names the game's own table gives the mission's number.",
            .date => "The date the launch shows, which is the game's text for the mission's number; nil for a mission the game has no date for.",
            .tier => "The tier of the loadout the campaign reaches as the mission ends, 1 to 3, which with the pilot's rank sets the ships the loadout offers; nil for none. The loadout before a mission offers the highest tier the missions numbered before it reach.",
            .chapter => "The chapter of the story the mission ends, 1 to 5: the pilot's ribbon for it, the debriefing's word of it, and the chapter's movie as the pilot lands; nil for none.",
            .medal => "The medal the mission awards for a success with its bonus, unless a nanny ship picked the pilot up, whose ceremony then plays; the crew in the rooms honour the pilot after it, whether or not it was awarded. Nil for none.",
            .induction => "Whether a new pilot's intro and induction come before the mission, where a campaign starts at it.",
            .lesson => "Whether the mission's loadout teaches, as the first mission's does: it starts on the Predator with the tier's missiles, says `loadout.ut` and blinks its exit.",
            .only_ship => "The ship the mission's loadout offers alone, which it starts on with the tier's missiles, as mission 23's offers the Shroud; nil for the ships the tier and the rank open.",
        };
    }
};

/// The userdata for the campaign's missions.
const Missions = struct {
    records: *Records,
    writable: bool,

    const tag = @backingInt(runtime.Tag.campaign_missions);

    fn of(state: *State, at: i32) *const Missions {
        return state.checkUserdata(Missions, at, tag, "the campaign's missions");
    }
};

/// The userdata for one campaign mission.
const Mission = struct {
    records: *Records,
    /// Its place in the records' table: its number less the first's.
    place: usize,
    writable: bool,

    const tag = @backingInt(runtime.Tag.campaign_mission);

    fn of(state: *State, at: i32) *const Mission {
        return state.checkUserdata(Mission, at, tag, "a campaign mission");
    }

    fn number(mission: Mission) u16 {
        return @intCast(mission.place + gameflow.first_mission);
    }

    fn settings(mission: Mission) *gameflow.CampaignMission {
        return &mission.records.missions[mission.place];
    }
};

/// Registers the metatables of the campaign's missions and of each mission.
pub fn register(state: *State) void {
    state.registerUserdata(Missions.tag, "missions", &.{
        .{ "__index", luau.wrap(index) },
        .{ "__newindex", luau.wrap(newIndex) },
        .{ "__iter", luau.wrap(iterate) },
        .{ "__len", luau.wrap(length) },
        .{ "__tostring", luau.wrap(describeMissions) },
    });
    state.registerUserdata(Mission.tag, script_name, &.{
        .{ "__index", luau.wrap(get) },
        .{ "__newindex", luau.wrap(set) },
        .{ "__tostring", luau.wrap(describeMission) },
    });
}

/// Pushes the campaign's missions, which scripts can change only if `writable`. Call `register`
/// first.
pub fn push(state: *State, held: *Records, writable: bool) void {
    const missions = state.newUserdata(Missions, Missions.tag);
    missions.* = .{ .records = held, .writable = writable };
}

/// The place in `held`'s table of the mission the key at `key` numbers; null for any other key.
fn placeOf(state: *State, held: *const Records, key: i32) ?usize {
    const number = bind.wholeIndex(state.toNumber(key) orelse return null) orelse return null;
    if (number < gameflow.first_mission) return null;
    const place = number - gameflow.first_mission;
    return if (place < held.missions.len) place else null;
}

fn pushMission(state: *State, missions: *const Missions, place: usize) void {
    const mission = state.newUserdata(Mission, Mission.tag);
    mission.* = .{ .records = missions.records, .place = place, .writable = missions.writable };
}

/// The missions' `__index`: the mission of a number, nil for a number the campaign has none for.
fn index(state: *State) i32 {
    const missions = Missions.of(state, 1);
    const place = placeOf(state, missions.records, 2) orelse {
        state.pushNil();
        return 1;
    };
    pushMission(state, missions, place);
    return 1;
}

/// The missions' `__newindex`: `records.missions[n] = { ... }` changes the fields the table gives.
fn newIndex(state: *State) i32 {
    const missions = Missions.of(state, 1);
    if (!missions.writable) state.raise("records can only be changed by load scripts", .{});
    const place = placeOf(state, missions.records, 2) orelse {
        _ = state.toDisplay(2);
        state.raise("records.missions[{s}] does not exist: the campaign's missions are {d} to {d}", .{ state.toString(-1).?, gameflow.first_mission, missions.records.missions.len });
    };
    if (state.typeOf(3) == .nil) state.raise("records.missions: a mission can't be removed", .{});
    if (state.typeOf(3) != .table) state.raise("records.missions: expected a table of fields, got {s}", .{state.typeName(3)});
    const mission: Mission = .{ .records = missions.records, .place = place, .writable = true };
    state.pushNil();
    while (state.next(3)) {
        const key = (if (state.typeOf(-2) == .string) state.toString(-2) else null) orelse
            state.raise("records.missions: a table of fields has names for keys, not {s}", .{state.typeName(-2)});
        setField(state, mission, fieldNamed(state, key), -1);
        state.pop(1);
    }
    return 0;
}

/// The missions' `__iter`: each mission in turn, as its number and the mission.
fn iterate(state: *State) i32 {
    state.pushFunction(luau.wrap(step), "next");
    state.pushCopy(1);
    state.pushNil();
    return 3;
}

/// The mission after the given number, or nothing after the last.
fn step(state: *State) i32 {
    const missions = Missions.of(state, 1);
    const place: usize = if (state.typeOf(2) == .nil) 0 else (placeOf(state, missions.records, 2) orelse return 0) + 1;
    if (place >= missions.records.missions.len) return 0;
    state.pushNumber(@floatFromInt(place + gameflow.first_mission));
    pushMission(state, missions, place);
    return 2;
}

/// The missions' `__len`: how many the campaign has settings for.
fn length(state: *State) i32 {
    state.pushNumber(@floatFromInt(Missions.of(state, 1).records.missions.len));
    return 1;
}

fn describeMissions(state: *State) i32 {
    _ = Missions.of(state, 1);
    state.pushString("missions");
    return 1;
}

fn describeMission(state: *State) i32 {
    _ = Mission.of(state, 1);
    state.pushString(script_name);
    return 1;
}

/// The field named `name`; an error for a name a mission doesn't have.
fn fieldNamed(state: *State, name: []const u8) Field {
    return std.meta.stringToEnum(Field, name) orelse
        state.raise("{s} has no field '{s}' ({s})", .{ script_name, name, field_names });
}

/// The fields' names, for error messages.
const field_names = names: {
    var names: []const u8 = "";
    for (std.enums.values(Field), 0..) |field, at| names = names ++ (if (at == 0) "" else ", ") ++ @tagName(field);
    break :names names;
};

/// A mission's `__index`: the value of a field.
fn get(state: *State) i32 {
    const mission = Mission.of(state, 1).*;
    const name = state.toString(2) orelse state.raise("{s}: a field has a name, not {s}", .{ script_name, state.typeName(2) });
    const settings = mission.settings();
    switch (fieldNamed(state, name)) {
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
        inline .medal, .induction, .lesson, .only_ship => |field| values.push(state, Field.Type(field), @field(settings, @tagName(field))),
        .date => {
            const text = dateText(mission) orelse {
                state.pushNil();
                return 1;
            };
            records.pushText(state, mission.records.text[text - 1]);
        },
    }
    return 1;
}

/// A mission's `__newindex`: changes a field, for load scripts.
fn set(state: *State) i32 {
    const mission = Mission.of(state, 1).*;
    if (!mission.writable) state.raise("records can only be changed by load scripts", .{});
    const name = state.toString(2) orelse state.raise("{s}: a field has a name, not {s}", .{ script_name, state.typeName(2) });
    setField(state, mission, fieldNamed(state, name), 3);
    return 0;
}

/// Sets `field` of `mission` from the value at `given`.
fn setField(state: *State, mission: Mission, field: Field, given: i32) void {
    const held = mission.records;
    const settings = mission.settings();
    switch (field) {
        inline .hologram, .speech, .last_word => |name| {
            const label = comptime script_name ++ "." ++ @tagName(name);
            const file = values.read(state, ?[]const u8, given, label);
            @field(settings.briefing, @tagName(name)) = if (file) |text| held.arena.dupe(u8, text) catch state.raise(label ++ ": out of memory", .{}) else null;
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
        .tier => settings.tier = readFrom(state, gameflow.CampaignMission.Tier, given, 3, script_name ++ ".tier"),
        .chapter => settings.chapter = readFrom(state, gameflow.CampaignMission.Chapter, given, gameflow.last_chapter, script_name ++ ".chapter"),
        inline .medal, .induction, .lesson, .only_ship => |name| {
            @field(settings, @tagName(name)) = values.read(state, Field.Type(name), given, script_name ++ "." ++ @tagName(name));
        },
    }
}

/// The number at `given`, from 1 to `last`, or nil. Raises an error naming `label` otherwise.
fn readFrom(state: *State, comptime T: type, given: i32, comptime last: comptime_int, comptime label: []const u8) ?T {
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
    objectives.reset(mission.number(), false, if (mission.settings().objectives) |*names| names else null);
    const text = mission.records.language(.text);
    state.newTable(hud.Objectives.per_mission, 0);
    var count: i32 = 0;
    for (0..hud.Objectives.per_mission) |objective| {
        const name = switch (objectives.name(@intCast(objective)) orelse continue) {
            .string => |string| text.string(string) orelse continue,
            .text => |own| own,
        };
        count += 1;
        records.pushText(state, name);
        state.rawSetIndex(-2, count);
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
        \\-- The original's, by the mission's number.
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
        \\-- A table changes the fields it gives.
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

test "what a campaign mission awards, and its loadout's and induction's cases" {
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
        \\-- A table gives the fields it holds, so nil clears a field only on its own.
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
    try std.testing.expect(held.missions[10].induction);

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
