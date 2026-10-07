//! Reads the ITAC's tables out of the payload: the shapes it lights where the pointer is over them
//! (`itac_lit_draw`, `0x00440F90`), the debriefings its DEBRIEFINGS shows, by the rating a
//! mission's script gave it (`debrief_text_draw`, `0x00424CF0`), the items of its NEWS REPORTS
//! (`news_list_build`, `0x0044E490`), the reports of its VIDEO REPORTS (`video_reports_enter`,
//! `0x00450540`), the fighters, capital ships, squadrons and personnel of either side, and the
//! pilots of its KILLBOARD.
//!
//! The lit shapes are rows of twelve bytes, up to one whose x is -1: where the shape stands, its
//! index in `itacgfx.spr`, a halfword never read, and a mask of the sections it lights in.
//!
//! The payload holds a table of debriefings for each rating, from success with its bonus at
//! `first_debriefings` down to failure, each of `missions` rows of nine halfwords: the string that
//! heads the debriefing, then those of its paragraphs, up to `end_mark`, which ends them.
//!
//! The news items are records of 32 bytes (`StoredNews`): the links the section's list threads
//! them on, the string of the item's title, those of up to five paragraphs ended by
//! `no_paragraph`, the picture's shape, a halfword never read, and the mission after which the item
//! is listed.
//!
//! The video reports are records of 76 bytes (`StoredVideo`): the links the section's list threads
//! them on, the string of the report's title, those of two paragraphs, which `end_mark` ends early
//! as in the debriefings, the still's shape, the mission after which the report is listed, its
//! movie's name, and the part of the campaign it comes from.
//!
//! The fighters, the capital ships, the squadrons, the personnel and the KILLBOARD's pilots are
//! records each section threads on a list of its own by their first 12 bytes, then the strings and
//! figures it writes (`StoredFighter`, `StoredShip`, `StoredSquadron`, `StoredPerson`,
//! `StoredPilot`). The fighters are the loadout's ships too, whose bars `loadout_ship_bars_init`
//! fills in.

const std = @import("std");
const Io = std.Io;

const image = @import("image.zig");
const testing = @import("testing.zig");

/// The lit shapes (`itac_lit_shapes`).
pub const lit_table: u32 = 0x004E94D8;

/// The x that ends the lit shapes.
const lit_end = -1;

/// A lit shape as the payload lays it out.
const StoredLit = extern struct {
    x: i16,
    y: i16,
    shape: u16,
    _unread: u16,
    sections: u32,

    comptime {
        std.debug.assert(@sizeOf(StoredLit) == 12);
    }
};

/// A shape the ITAC lights where the pointer is over it, while a section its mask holds shows.
pub const LitShape = struct {
    at: [2]i16,
    shape: u16,
    sections: u32,
};

/// The table of success with its bonus (rating 4), which the others follow a rating lower each.
pub const first_debriefings: u32 = 0x004E4A68;

/// The ratings, failure (0) to success with its bonus (4), and the missions a table holds.
pub const ratings = 5;
pub const missions = 28;

/// The halfwords of a row: the header, then at most eight paragraphs.
const row_halfwords = 9;

/// The string that ends a row's paragraphs, where there are fewer than eight (`0x00424FB2`), and a
/// video report's, where it has one (`0x00450B09`).
pub const end_mark = 9;

/// The bytes of a table of debriefings.
const table_size = missions * row_halfwords * @sizeOf(i16);

/// A debriefing: the string that heads it, and those of its paragraphs.
pub const Text = struct {
    header: u16,
    paragraphs: []const u16,
};

/// NEWS REPORTS' items (`news_items`), and how many there are.
pub const news_table: u32 = 0x004EB0E8;
pub const news_count = 24;

/// The paragraph that ends an item's paragraphs, where there are fewer than five.
const no_paragraph = -1;

/// A news item as the payload lays it out.
const StoredNews = extern struct {
    links: [3]u32,
    title: u16,
    paragraphs: [5]i16,
    shape: u16,
    _unread: u16,
    mission: i32,

    comptime {
        std.debug.assert(@sizeOf(StoredNews) == 0x20);
    }
};

/// A news item: the string of its title, those of its paragraphs, the shape of its picture, and
/// the mission after which it is listed.
pub const News = struct {
    title: u16,
    paragraphs: []const u16,
    shape: u16,
    mission: i32,
};

/// VIDEO REPORTS' reports (`video_reports_items`), and how many there are.
pub const videos_table: u32 = 0x004EE5B0;
pub const videos_count = 6;

/// The room a report's movie's name has.
const movie_room = 50;

/// A video report as the payload lays it out.
const StoredVideo = extern struct {
    links: [3]u32,
    title: u16,
    paragraphs: [2]u16,
    shape: u16,
    mission: i32,
    movie: [movie_room]u8,
    part: u16,

    comptime {
        std.debug.assert(@sizeOf(StoredVideo) == 0x4C);
        std.debug.assert(@offsetOf(StoredVideo, "part") == 0x4A);
    }
};

/// A video report: the string of its title, those of its paragraphs, the shape of its still, the
/// mission after which it is listed, its movie's name, and the part of the campaign it comes from,
/// 1 for the Reliant's and 2 for the Yamato's.
pub const Video = struct {
    title: u16,
    paragraphs: []const u16,
    shape: u16,
    mission: i32,
    movie: []const u8,
    part: u16,
};

/// The fighters, the Alliance's (`loadout_alliance_ships`) and then the Coalition's
/// (`loadout_coalition_ships`), which follow without a gap.
pub const fighters_table: u32 = 0x004E5470;
pub const fighter_counts = [2]usize{ 12, 9 };

/// A fighter as the payload lays it out. Its bars stay zero until `loadout_ship_bars_init` fills
/// them in.
const StoredFighter = extern struct {
    links: [3]u32,
    name: u16,
    bars: [7]i16,
    type: u16,
    clearance: u16,
    crew: i16,
    guns: [4]u16,
    gun_counts: [4]i16,
    specials: [4]u16,
    _unread: u16,
    shape: i32,
    ship_type: i32,

    comptime {
        std.debug.assert(@sizeOf(StoredFighter) == 0x44);
        std.debug.assert(@offsetOf(StoredFighter, "shape") == 0x3C);
    }
};

/// A gun a fighter carries: its string, and how many, 0 where the ITAC writes no count.
pub const Gun = struct { name: u16, count: i16 };

/// A fighter: the strings of its name, its type and its clearance (0 for none), its crew, its guns
/// and the strings of its special abilities, up to the first of each that is 0, the shape of its
/// picture (-1 for none), and its ship type.
pub const Fighter = struct {
    name: u16,
    type: u16,
    clearance: u16,
    crew: i16,
    guns: []const Gun,
    specials: []const u16,
    shape: i32,
    ship_type: i32,
};

/// The capital ships, the Alliance's (`ships_alliance`) and then the Coalition's, which follow them
/// (`ships_coalition`, `0x004E4560`).
pub const ships_table: u32 = 0x004E42C0;
pub const ship_counts = [2]usize{ 21, 27 };

/// A capital ship as the payload lays it out.
const StoredShip = extern struct {
    links: [3]u32,
    name: u16,
    commissioned: u16,
    type: u16,
    displacement: u16,
    propulsion: u16,
    spacecraft: u16,
    armament: u16,
    crew: i16,
    description: u16,
    shape: i16,

    comptime {
        std.debug.assert(@sizeOf(StoredShip) == 0x20);
    }
};

/// A capital ship: the strings of its name, of when it was commissioned and of its type,
/// displacement, propulsion, spacecraft and armament, its crew, the string of its description, and
/// the shape of its picture (-1 for none).
pub const Ship = struct { name: u16, commissioned: u16, type: u16, displacement: u16, propulsion: u16, spacecraft: u16, armament: u16, crew: i16, description: u16, shape: i16 };

/// The squadrons of either side, the Alliance's and the Coalition's.
pub const squadron_tables = [2]u32{ 0x004EBD10, 0x004EBF28 };
pub const squadron_counts = [2]usize{ 19, 8 };

/// A squadron as the payload lays it out.
const StoredSquadron = extern struct {
    links: [3]u32,
    name: u16,
    class: u16,
    leader: u16,
    base: u16,
    nation: u16,
    text: u16,
    shape: i16,
    palette: i16,

    comptime {
        std.debug.assert(@sizeOf(StoredSquadron) == 0x1C);
    }
};

/// A squadron: the strings of its name, class, leader, base, nation and history, the shape of its
/// picture, and the block of the palette it is drawn with.
pub const Squadron = struct { name: u16, class: u16, leader: u16, base: u16, nation: u16, text: u16, shape: i16, palette: i16 };

/// The personnel, the Alliance's and then the Coalition's, which follow without a gap.
pub const personnel_table: u32 = 0x004EB430;
pub const personnel_counts = [2]usize{ 30, 6 };

/// A person as the payload lays it out.
const StoredPerson = extern struct {
    links: [3]u32,
    name: u16,
    nationality: u16,
    age: u16,
    ship: u16,
    call_sign: u16,
    history: u16,
    training: u16,
    background: u16,
    _unread: i16,
    shape: i16,

    comptime {
        std.debug.assert(@sizeOf(StoredPerson) == 0x20);
    }
};

/// A person: the strings of their name, nationality, age, ship and call sign (0 for none), and of
/// their military history, training and background, and the shape of their portrait.
pub const Person = struct { name: u16, nationality: u16, age: u16, ship: u16, call_sign: u16, history: u16, training: u16, background: u16, shape: i16 };

/// The KILLBOARD's pilots (`killboard_pilots`), and how many there are.
pub const pilots_table: u32 = 0x004E9A08;
pub const pilots_count = 19;

/// A pilot as the payload lays it out. The player's record, which the KILLBOARD adds, keeps the
/// call sign in `_call_sign_room`, zero in the table.
const StoredPilot = extern struct {
    links: [3]u32,
    name: u16,
    call_sign: u16,
    _call_sign_room: [0x52]u8,
    ship: u16,
    base_kills: i16,
    _kills: i16,
    mean: f32,
    spread: f32,
    shape: i16,
    _unread: u16,

    comptime {
        std.debug.assert(@sizeOf(StoredPilot) == 0x74);
        std.debug.assert(@offsetOf(StoredPilot, "ship") == 0x62);
    }
};

/// A pilot: the strings of their name, the line below it and their ship, the kills they start
/// with, the mean and the spread of the kills each mission adds, and the shape of their portrait.
pub const Pilot = struct { name: u16, call_sign: u16, ship: u16, base_kills: i16, mean: f32, spread: f32, shape: i16 };

/// What the tables hold.
pub const Tables = struct {
    lit_shapes: []const LitShape,
    debriefings: [ratings][missions]Text,
    news: [news_count]News,
    videos: [videos_count]Video,
    /// By side, the Alliance's first.
    fighters: [2][]const Fighter,
    ships: [2][]const Ship,
    squadrons: [2][]const Squadron,
    personnel: [2][]const Person,
    pilots: [pilots_count]Pilot,
};

/// The leading values of `values` up to the first that is 0.
fn untilZero(comptime T: type, values: []const T) []const T {
    return values[0 .. std.mem.findScalar(T, values, 0) orelse values.len];
}

/// The table of rating `rating`.
fn debriefingsOf(rating: usize) u32 {
    return first_debriefings + @as(u32, @intCast((ratings - 1 - rating) * table_size));
}

/// The most lit shapes read before the end is taken to be missing.
const most_lit = 100;

pub fn read(arena: std.mem.Allocator, reader: image.Reader) (image.Error || std.mem.Allocator.Error || error{NoEnd})!Tables {
    var lit: std.ArrayList(LitShape) = .empty;
    for (0..most_lit) |index| {
        const stored = try reader.recordAt(StoredLit, lit_table, index);
        if (stored.x == lit_end) break;
        try lit.append(arena, .{ .at = .{ stored.x, stored.y }, .shape = stored.shape, .sections = stored.sections });
    } else return error.NoEnd;

    var debriefings: [ratings][missions]Text = undefined;
    for (&debriefings, 0..) |*table, rating| {
        for (table, 0..) |*text, mission| {
            var row: [row_halfwords]u16 = undefined;
            for (&row, 0..) |*id, n| id.* = try reader.recordAt(u16, debriefingsOf(rating), mission * row_halfwords + n);
            const paragraphs = row[1..];
            const count = std.mem.findScalar(u16, paragraphs, end_mark) orelse paragraphs.len;
            text.* = .{ .header = row[0], .paragraphs = try arena.dupe(u16, paragraphs[0..count]) };
        }
    }

    var news: [news_count]News = undefined;
    for (&news, 0..) |*item, index| {
        const stored = try reader.recordAt(StoredNews, news_table, index);
        const count = std.mem.findScalar(i16, &stored.paragraphs, no_paragraph) orelse stored.paragraphs.len;
        const paragraphs = try arena.alloc(u16, count);
        for (paragraphs, stored.paragraphs[0..count]) |*id, read_id| id.* = @bitCast(read_id);
        item.* = .{ .title = stored.title, .paragraphs = paragraphs, .shape = stored.shape, .mission = stored.mission };
    }

    var videos: [videos_count]Video = undefined;
    for (&videos, 0..) |*report, index| {
        const stored = try reader.recordAt(StoredVideo, videos_table, index);
        const count = std.mem.findScalar(u16, &stored.paragraphs, end_mark) orelse stored.paragraphs.len;
        report.* = .{
            .title = stored.title,
            .paragraphs = try arena.dupe(u16, stored.paragraphs[0..count]),
            .shape = stored.shape,
            .mission = stored.mission,
            .movie = try arena.dupe(u8, std.mem.sliceTo(&stored.movie, 0)),
            .part = stored.part,
        };
    }
    var fighters: [2][]const Fighter = undefined;
    var first_fighter: usize = 0;
    for (&fighters, fighter_counts) |*side, count| {
        const list = try arena.alloc(Fighter, count);
        for (list, first_fighter..) |*fighter, index| {
            const stored = try reader.recordAt(StoredFighter, fighters_table, index);
            const guns = untilZero(u16, &stored.guns);
            const listed = try arena.alloc(Gun, guns.len);
            for (listed, guns, stored.gun_counts[0..guns.len]) |*gun, name, count_of| gun.* = .{ .name = name, .count = count_of };
            fighter.* = .{
                .name = stored.name,
                .type = stored.type,
                .clearance = stored.clearance,
                .crew = stored.crew,
                .guns = listed,
                .specials = try arena.dupe(u16, untilZero(u16, &stored.specials)),
                .shape = stored.shape,
                .ship_type = stored.ship_type,
            };
        }
        side.* = list;
        first_fighter += count;
    }

    var ships: [2][]const Ship = undefined;
    var first_ship: usize = 0;
    for (&ships, ship_counts) |*side, count| {
        const list = try arena.alloc(Ship, count);
        for (list, first_ship..) |*ship, index| {
            const stored = try reader.recordAt(StoredShip, ships_table, index);
            ship.* = .{ .name = stored.name, .commissioned = stored.commissioned, .type = stored.type, .displacement = stored.displacement, .propulsion = stored.propulsion, .spacecraft = stored.spacecraft, .armament = stored.armament, .crew = stored.crew, .description = stored.description, .shape = stored.shape };
        }
        side.* = list;
        first_ship += count;
    }

    var squadrons: [2][]const Squadron = undefined;
    for (&squadrons, squadron_tables, squadron_counts) |*side, table, count| {
        const list = try arena.alloc(Squadron, count);
        for (list, 0..) |*squadron, index| {
            const stored = try reader.recordAt(StoredSquadron, table, index);
            squadron.* = .{ .name = stored.name, .class = stored.class, .leader = stored.leader, .base = stored.base, .nation = stored.nation, .text = stored.text, .shape = stored.shape, .palette = stored.palette };
        }
        side.* = list;
    }

    var personnel: [2][]const Person = undefined;
    var first_person: usize = 0;
    for (&personnel, personnel_counts) |*side, count| {
        const list = try arena.alloc(Person, count);
        for (list, first_person..) |*person, index| {
            const stored = try reader.recordAt(StoredPerson, personnel_table, index);
            person.* = .{ .name = stored.name, .nationality = stored.nationality, .age = stored.age, .ship = stored.ship, .call_sign = stored.call_sign, .history = stored.history, .training = stored.training, .background = stored.background, .shape = stored.shape };
        }
        side.* = list;
        first_person += count;
    }

    var pilots: [pilots_count]Pilot = undefined;
    for (&pilots, 0..) |*pilot, index| {
        const stored = try reader.recordAt(StoredPilot, pilots_table, index);
        pilot.* = .{ .name = stored.name, .call_sign = stored.call_sign, .ship = stored.ship, .base_kills = stored.base_kills, .mean = stored.mean, .spread = stored.spread, .shape = stored.shape };
    }

    return .{
        .lit_shapes = try lit.toOwnedSlice(arena),
        .debriefings = debriefings,
        .news = news,
        .videos = videos,
        .fighters = fighters,
        .ships = ships,
        .squadrons = squadrons,
        .personnel = personnel,
        .pilots = pilots,
    };
}

/// The names the emitted tables of debriefings go by, from failure up.
const rating_names = [ratings][]const u8{ "failure", "partial failure", "partial success", "success", "success with its bonus" };

/// Writes `tables.zig`.
pub fn emit(w: *Io.Writer, tables: Tables) Io.Writer.Error!void {
    try w.print(
        \\//! The ITAC's tables: the shapes it lights where the pointer is over them, the debriefings its
        \\//! DEBRIEFINGS shows, the items of its NEWS REPORTS, the reports of its VIDEO REPORTS, the
        \\//! fighters, capital ships, squadrons and personnel of either side, and the pilots of its
        \\//! KILLBOARD.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable's lit shapes at 0x{X:0>8}, {d}
        \\//! rows, its debriefings from 0x{X:0>8}, {d} tables of {d} rows, its news items at 0x{X:0>8},
        \\//! {d} rows, its video reports at 0x{X:0>8}, {d} rows, its fighters at 0x{X:0>8}, its capital
        \\//! ships at 0x{X:0>8}, its squadrons at 0x{X:0>8} and 0x{X:0>8}, its personnel at 0x{X:0>8} and
        \\//! its pilots at 0x{X:0>8}, {d} rows. Do not edit by hand; run `make itac-tables`.
        \\
        \\/// A shape the ITAC lights where the pointer is over it, while a section its mask holds shows.
        \\pub const LitShape = struct {{ at: [2]i16, shape: u16, sections: u32 }};
        \\
        \\pub const lit_shapes = [_]LitShape{{
        \\
    , .{ lit_table, tables.lit_shapes.len, first_debriefings, ratings, missions, news_table, news_count, videos_table, videos_count, fighters_table, ships_table, squadron_tables[0], squadron_tables[1], personnel_table, pilots_table, pilots_count });
    for (tables.lit_shapes) |lit| {
        try w.print("    .{{ .at = .{{ {d}, {d} }}, .shape = 0x{X}, .sections = 0x{X} }},\n", .{ lit.at[0], lit.at[1], lit.shape, lit.sections });
    }
    try w.print(
        \\}};
        \\
        \\/// A debriefing: the string that heads it, and those of its paragraphs.
        \\pub const Text = struct {{ header: u16, paragraphs: []const u16 }};
        \\
        \\/// By the rating, failure (0) to success with its bonus (4), then by the mission number less one.
        \\pub const debriefings = [{d}][{d}]Text{{
        \\
    , .{ ratings, missions });
    for (tables.debriefings, rating_names) |table, name| {
        try w.print("    .{{ // {s}\n", .{name});
        for (table, 1..) |text, mission| {
            try w.print("        .{{ .header = {d}, .paragraphs = &.{{", .{text.header});
            for (text.paragraphs, 0..) |id, n| try w.print("{s}{d}", .{ if (n == 0) " " else ", ", id });
            try w.print(" }} }}, // {d}\n", .{mission});
        }
        try w.writeAll("    },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// A news item: the string of its title, those of its paragraphs, the shape of its picture in
        \\/// `newsrep.spr`, and the mission after which it is listed.
        \\pub const NewsItem = struct { title: u16, paragraphs: []const u16, shape: u16, mission: i32 };
        \\
        \\pub const news = [_]NewsItem{
        \\
    );
    for (tables.news) |item| {
        try w.print("    .{{ .title = {d}, .paragraphs = &.{{", .{item.title});
        for (item.paragraphs, 0..) |id, n| try w.print("{s}{d}", .{ if (n == 0) " " else ", ", id });
        try w.print(" }}, .shape = {d}, .mission = {d} }},\n", .{ item.shape, item.mission });
    }
    try w.writeAll(
        \\};
        \\
        \\/// A video report: the string of its title, those of its paragraphs, the shape of its still in
        \\/// `vidrep.spr`, the mission after which it is listed, its movie in the discs' archives, and the
        \\/// part of the campaign it comes from, 1 for the Reliant's and 2 for the Yamato's.
        \\pub const VideoItem = struct { title: u16, paragraphs: []const u16, shape: u16, mission: i32, movie: []const u8, part: u16 };
        \\
        \\pub const videos = [_]VideoItem{
        \\
    );
    for (tables.videos) |report| {
        try w.print("    .{{ .title = {d}, .paragraphs = &.{{", .{report.title});
        for (report.paragraphs, 0..) |id, n| try w.print("{s}{d}", .{ if (n == 0) " " else ", ", id });
        try w.print(" }}, .shape = {d}, .mission = {d}, .movie = \"{f}\", .part = {d} }},\n", .{ report.shape, report.mission, std.zig.fmtString(report.movie), report.part });
    }
    try w.writeAll(
        \\};
        \\
        \\/// A gun a fighter carries: its string, and how many, 0 where the ITAC writes no count.
        \\pub const Gun = struct { name: u16, count: i16 };
        \\
        \\/// A fighter the ITAC lists, which the loadout offers too: the strings of its name, its type and
        \\/// its clearance (0 for none), its crew, its guns, the strings of its special abilities, the shape
        \\/// of its picture in `fighters.spr` (-1 for none), and its ship type.
        \\pub const Fighter = struct { name: u16, type: u16, clearance: u16, crew: i16, guns: []const Gun, specials: []const u16, shape: i32, ship_type: u8 };
        \\
        \\/// By side, the Alliance's first.
        \\pub const fighters = [2][]const Fighter{
        \\
    );
    for (tables.fighters, side_names) |side, side_name| {
        try w.print("    &.{{ // {s}\n", .{side_name});
        for (side) |fighter| {
            try w.print("        .{{ .name = {d}, .type = {d}, .clearance = {d}, .crew = {d}, .guns = &.{{", .{ fighter.name, fighter.type, fighter.clearance, fighter.crew });
            for (fighter.guns, 0..) |gun, n| try w.print("{s}.{{ .name = {d}, .count = {d} }}", .{ if (n == 0) " " else ", ", gun.name, gun.count });
            try w.writeAll(" }, .specials = &.{");
            for (fighter.specials, 0..) |id, n| try w.print("{s}{d}", .{ if (n == 0) " " else ", ", id });
            try w.print(" }}, .shape = {d}, .ship_type = {d} }},\n", .{ fighter.shape, fighter.ship_type });
        }
        try w.writeAll("    },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// A capital ship: the strings of its name, of when it was commissioned and of its type,
        \\/// displacement, propulsion, spacecraft and armament, its crew, the string of its description, and
        \\/// the shape of its picture in `capships.spr` (-1 for none).
        \\pub const Ship = struct { name: u16, commissioned: u16, type: u16, displacement: u16, propulsion: u16, spacecraft: u16, armament: u16, crew: i16, description: u16, shape: i16 };
        \\
        \\/// By side, the Alliance's first.
        \\pub const ships = [2][]const Ship{
        \\
    );
    for (tables.ships, side_names) |side, side_name| {
        try w.print("    &.{{ // {s}\n", .{side_name});
        for (side) |ship| try w.print("        .{{ .name = {d}, .commissioned = {d}, .type = {d}, .displacement = {d}, .propulsion = {d}, .spacecraft = {d}, .armament = {d}, .crew = {d}, .description = {d}, .shape = {d} }},\n", .{ ship.name, ship.commissioned, ship.type, ship.displacement, ship.propulsion, ship.spacecraft, ship.armament, ship.crew, ship.description, ship.shape });
        try w.writeAll("    },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// A squadron: the strings of its name, class, leader, base, nation and history, the shape of its
        \\/// picture in `squads.spr`, and the block of the palette it is drawn with.
        \\pub const Squadron = struct { name: u16, class: u16, leader: u16, base: u16, nation: u16, text: u16, shape: i16, palette: i16 };
        \\
        \\/// By side, the Alliance's first.
        \\pub const squadrons = [2][]const Squadron{
        \\
    );
    for (tables.squadrons, side_names) |side, side_name| {
        try w.print("    &.{{ // {s}\n", .{side_name});
        for (side) |squadron| try w.print("        .{{ .name = {d}, .class = {d}, .leader = {d}, .base = {d}, .nation = {d}, .text = {d}, .shape = {d}, .palette = {d} }},\n", .{ squadron.name, squadron.class, squadron.leader, squadron.base, squadron.nation, squadron.text, squadron.shape, squadron.palette });
        try w.writeAll("    },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// A person: the strings of their name, nationality, age, ship and call sign (0 for none), and of
        \\/// their military history, training and background, and the shape of their portrait in
        \\/// `persons.spr`.
        \\pub const Person = struct { name: u16, nationality: u16, age: u16, ship: u16, call_sign: u16, history: u16, training: u16, background: u16, shape: i16 };
        \\
        \\/// By side, the Alliance's first.
        \\pub const personnel = [2][]const Person{
        \\
    );
    for (tables.personnel, side_names) |side, side_name| {
        try w.print("    &.{{ // {s}\n", .{side_name});
        for (side) |person| try w.print("        .{{ .name = {d}, .nationality = {d}, .age = {d}, .ship = {d}, .call_sign = {d}, .history = {d}, .training = {d}, .background = {d}, .shape = {d} }},\n", .{ person.name, person.nationality, person.age, person.ship, person.call_sign, person.history, person.training, person.background, person.shape });
        try w.writeAll("    },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// A pilot of the KILLBOARD: the strings of their name, the line below it and their ship, the kills
        \\/// they start with, the mean and the spread of the kills each mission adds, and the shape of their
        \\/// portrait in `kills.spr`.
        \\pub const Pilot = struct { name: u16, call_sign: u16, ship: u16, base_kills: i16, mean: f32, spread: f32, shape: i16 };
        \\
        \\pub const pilots = [_]Pilot{
        \\
    );
    for (tables.pilots) |pilot| try w.print("    .{{ .name = {d}, .call_sign = {d}, .ship = {d}, .base_kills = {d}, .mean = {d}, .spread = {d}, .shape = {d} }},\n", .{ pilot.name, pilot.call_sign, pilot.ship, pilot.base_kills, pilot.mean, pilot.spread, pilot.shape });
    try w.writeAll(
        \\};
        \\
    );
}

/// The names the emitted tables of either side go by.
const side_names = [2][]const u8{ "alliance", "coalition" };

test read {
    const allocator = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two lit shapes, then the end.
    const lit_bytes = try allocator.alloc(u8, 3 * @sizeOf(StoredLit));
    defer allocator.free(lit_bytes);
    const lit_region: testing.Region = .{ .va = lit_table, .bytes = lit_bytes };
    lit_region.putRecord(lit_table, StoredLit{ .x = 16, .y = 422, .shape = 0x24, ._unread = 0, .sections = 0xFFFF_FFFF });
    lit_region.putRecord(lit_table + 12, StoredLit{ .x = 221, .y = 322, .shape = 0x1F, ._unread = 0, .sections = 1 });
    lit_region.putRecord(lit_table + 24, StoredLit{ .x = lit_end, .y = 0, .shape = 0, ._unread = 0, .sections = 0 });

    const bytes = try allocator.alloc(u8, ratings * table_size);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    for (0..ratings * missions) |row| std.mem.writeInt(u16, bytes[row * row_halfwords * 2 ..][0..2], 10, .little);
    // Success with its bonus leads the tables, failure ends them: mission 1's full row of each, and
    // mission 2's two paragraphs of success.
    const region: testing.Region = .{ .va = first_debriefings, .bytes = bytes };
    for (0..8) |n| region.putRecord(first_debriefings + @as(u32, @intCast(2 + 2 * n)), @as(u16, @intCast(1641 + n)));
    for (0..8) |n| region.putRecord(debriefingsOf(0) + @as(u32, @intCast(2 + 2 * n)), @as(u16, @intCast(500 + n)));
    const success_row_2 = debriefingsOf(3) + row_halfwords * 2;
    for ([_]u16{ 369, 370, end_mark, 1 }, 0..) |id, n| region.putRecord(success_row_2 + @as(u32, @intCast(2 + 2 * n)), id);

    // The first news item with five paragraphs, the second with two, the rest zeros.
    const news_bytes = try allocator.alloc(u8, news_count * @sizeOf(StoredNews));
    defer allocator.free(news_bytes);
    @memset(news_bytes, 0);
    const news_region: testing.Region = .{ .va = news_table, .bytes = news_bytes };
    news_region.putRecord(news_table, StoredNews{ .links = @splat(0), .title = 537, .paragraphs = .{ 565, 566, 567, 568, 569 }, .shape = 1, ._unread = 0, .mission = 0 });
    news_region.putRecord(news_table + @sizeOf(StoredNews), StoredNews{ .links = @splat(0), .title = 538, .paragraphs = .{ 570, 571, no_paragraph, no_paragraph, no_paragraph }, .shape = 2, ._unread = 0, .mission = 1 });

    // The first video report with both paragraphs, the second with one, the rest zeros.
    const video_bytes = try allocator.alloc(u8, videos_count * @sizeOf(StoredVideo));
    defer allocator.free(video_bytes);
    @memset(video_bytes, 0);
    const video_region: testing.Region = .{ .va = videos_table, .bytes = video_bytes };
    var intro: StoredVideo = .{ .links = @splat(0), .title = 734, .paragraphs = .{ 704, 705 }, .shape = 29, .mission = 0, .movie = @splat(0), .part = 1 };
    @memcpy(intro.movie[0..13], "new_intro.bik");
    video_region.putRecord(videos_table, intro);
    var chapter: StoredVideo = .{ .links = @splat(0), .title = 738, .paragraphs = .{ 680, end_mark }, .shape = 33, .mission = 19, .movie = @splat(0), .part = 2 };
    @memcpy(chapter.movie[0..16], "new_chapter3.bik");
    video_region.putRecord(videos_table + @sizeOf(StoredVideo), chapter);

    // The first fighter with two guns, one counted, and a special; the rest zeros.
    const fighter_bytes = try allocator.alloc(u8, (fighter_counts[0] + fighter_counts[1]) * @sizeOf(StoredFighter));
    defer allocator.free(fighter_bytes);
    @memset(fighter_bytes, 0);
    const fighter_region: testing.Region = .{ .va = fighters_table, .bytes = fighter_bytes };
    fighter_region.putRecord(fighters_table, StoredFighter{ .links = @splat(0), .name = 1035, .bars = @splat(0), .type = 1219, .clearance = 1224, .crew = 2, .guns = .{ 1242, 1235, 0, 0 }, .gun_counts = .{ 2, 0, 0, 0 }, .specials = .{ 1251, 0, 0, 0 }, ._unread = 0, .shape = 1, .ship_type = 4 });

    // The Coalition's first capital ship, after the Alliance's.
    const ship_bytes = try allocator.alloc(u8, (ship_counts[0] + ship_counts[1]) * @sizeOf(StoredShip));
    defer allocator.free(ship_bytes);
    @memset(ship_bytes, 0);
    const ship_region: testing.Region = .{ .va = ships_table, .bytes = ship_bytes };
    ship_region.putRecord(ships_table + ship_counts[0] * @sizeOf(StoredShip), StoredShip{ .links = @splat(0), .name = 1449, .commissioned = 1450, .type = 1451, .displacement = 1452, .propulsion = 1453, .spacecraft = 1454, .armament = 1455, .crew = 6, .description = 1456, .shape = 28 });

    // A squadron of each side.
    var squadron_regions: [2]testing.Region = undefined;
    var squadron_bytes: [2][]u8 = undefined;
    for (&squadron_regions, &squadron_bytes, squadron_tables, squadron_counts) |*squadron_region, *bytes_of, table, count| {
        bytes_of.* = try allocator.alloc(u8, count * @sizeOf(StoredSquadron));
        @memset(bytes_of.*, 0);
        squadron_region.* = .{ .va = table, .bytes = bytes_of.* };
    }
    defer for (squadron_bytes) |bytes_of| allocator.free(bytes_of);
    squadron_regions[0].putRecord(squadron_tables[0], StoredSquadron{ .links = @splat(0), .name = 446, .class = 419, .leader = 421, .base = 501, .nation = 526, .text = 474, .shape = 21, .palette = 20 });
    squadron_regions[1].putRecord(squadron_tables[1], StoredSquadron{ .links = @splat(0), .name = 465, .class = 419, .leader = 439, .base = 517, .nation = 533, .text = 493, .shape = 32, .palette = 30 });

    // The Coalition's first person, after the Alliance's.
    const person_bytes = try allocator.alloc(u8, (personnel_counts[0] + personnel_counts[1]) * @sizeOf(StoredPerson));
    defer allocator.free(person_bytes);
    @memset(person_bytes, 0);
    const person_region: testing.Region = .{ .va = personnel_table, .bytes = person_bytes };
    person_region.putRecord(personnel_table + personnel_counts[0] * @sizeOf(StoredPerson), StoredPerson{ .links = @splat(0), .name = 753, .nationality = 819, .age = 789, .ship = 865, .call_sign = 834, .history = 907, .training = 920, .background = 956, ._unread = 0, .shape = 39 });

    // The first pilot.
    const pilot_bytes = try allocator.alloc(u8, pilots_count * @sizeOf(StoredPilot));
    defer allocator.free(pilot_bytes);
    @memset(pilot_bytes, 0);
    const pilot_region: testing.Region = .{ .va = pilots_table, .bytes = pilot_bytes };
    pilot_region.putRecord(pilots_table, StoredPilot{ .links = @splat(0), .name = 1301, .call_sign = 1305, ._call_sign_room = @splat(0), .ship = 1309, .base_kills = 29, ._kills = 0, .mean = 11, .spread = 3, .shape = 3, ._unread = 0 });

    const payload = try testing.reader(allocator, &.{ lit_region, region, news_region, video_region, fighter_region, ship_region, squadron_regions[0], squadron_regions[1], person_region, pilot_region });
    defer testing.freeReader(allocator, payload);
    const tables = try read(arena, payload);
    try std.testing.expectEqual(2, tables.lit_shapes.len);
    try std.testing.expectEqual(LitShape{ .at = .{ 221, 322 }, .shape = 0x1F, .sections = 1 }, tables.lit_shapes[1]);
    try std.testing.expectEqual(10, tables.debriefings[4][0].header);
    try std.testing.expectEqual(8, tables.debriefings[4][0].paragraphs.len);
    try std.testing.expectEqual(1641, tables.debriefings[4][0].paragraphs[0]);
    try std.testing.expectEqual(500, tables.debriefings[0][0].paragraphs[0]);
    try std.testing.expectEqualSlices(u16, &.{ 369, 370 }, tables.debriefings[3][1].paragraphs);
    try std.testing.expectEqual(5, tables.news[0].paragraphs.len);
    try std.testing.expectEqualSlices(u16, &.{ 570, 571 }, tables.news[1].paragraphs);
    try std.testing.expectEqual(2, tables.news[1].shape);
    try std.testing.expectEqual(1, tables.news[1].mission);
    try std.testing.expectEqualSlices(u16, &.{ 704, 705 }, tables.videos[0].paragraphs);
    try std.testing.expectEqualStrings("new_intro.bik", tables.videos[0].movie);
    try std.testing.expectEqual(1, tables.videos[0].part);
    try std.testing.expectEqualSlices(u16, &.{680}, tables.videos[1].paragraphs);
    try std.testing.expectEqualStrings("new_chapter3.bik", tables.videos[1].movie);
    try std.testing.expectEqual(19, tables.videos[1].mission);
    try std.testing.expectEqual(2, tables.videos[1].part);
    const fighter = tables.fighters[0][0];
    try std.testing.expectEqual(2, fighter.guns.len);
    try std.testing.expectEqual(Gun{ .name = 1235, .count = 0 }, fighter.guns[1]);
    try std.testing.expectEqualSlices(u16, &.{1251}, fighter.specials);
    try std.testing.expectEqual(4, fighter.ship_type);
    try std.testing.expectEqual(fighter_counts[1], tables.fighters[1].len);
    try std.testing.expectEqual(32, tables.squadrons[1][0].shape);
    try std.testing.expectEqual(1449, tables.ships[1][0].name);
    try std.testing.expectEqual(6, tables.ships[1][0].crew);
    try std.testing.expectEqual(753, tables.personnel[1][0].name);
    try std.testing.expectEqual(11, tables.pilots[0].mean);

    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try emit(&out.writer, tables);
    try testing.expectZig(out.written());
}
