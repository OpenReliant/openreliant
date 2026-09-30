//! `play_landing_movie` (`0x004ABDE0`): what `WinMain` plays as the pilot comes back from a mission
//! it flew (`winmain.landsAfter`). Most missions end in the landing (`Touchdown`): the pilot's ship
//! landing on the Reliant or the Yamato, then a movie of the story's thread by how the script rated
//! the mission, while a sound bank of the same rating plays over both. A mission that ends a chapter
//! of the story ends in the chapter's movie instead (`Chapter`), and the news reports the game's
//! variables call for.

const std = @import("std");

const vm = @import("../../vm.zig");
const Rating = vm.Variables.Outcome;
const Ending = @import("../main.zig").Ending;
const disc = @import("../interface/disc.zig");
const winmain = @import("../winmain.zig");
const movie = @import("movie.zig");

/// What `play_landing_movie` plays.
pub const Landing = union(enum) {
    touchdown: Touchdown,
    chapter: Chapter,
};

/// The landing (`0x004AC195` on): its movie from the disc's archive open (`movie.Kind.landing`),
/// then, unless it was skipped, the thread's from the game's folder (`movie.Kind.thread`). The
/// bank, from `resource.hog`, plays its first sound over both (`sound_play`) at 127, once, from
/// the middle, and it stops as they end (`sound_pause_all`).
pub const Touchdown = struct {
    movie: []const u8,
    /// The thread's movie and the bank: null for a rating past the named ones.
    ///
    /// **Fix:** for such a rating, the game takes whatever its stack holds for the two, and frees
    /// it where the mission ends a chapter.
    thread: ?[]const u8,
    bank: ?[]const u8,
};

/// A chapter's end (`0x004ABFEE` on): the disc that holds the chapter opened (`cd_hog_open`), a
/// zoom (`movie.Kind.cleared_from_disc`), then the chapter's movie and the news reports,
/// each after the news' transition (`movie.Kind.over_screen_from_disc`). From the chapter's movie
/// to the last report, the news' loop plays from `resource.hog` over and over, at
/// `news_loop_volume` from the middle (`sound_play`), until the reports end (`sound_voice_end`).
pub const Chapter = struct {
    disc: disc.Number,
    zoom: []const u8,
    movie: []const u8,
    reports: Reports,
};

/// The news reports after a chapter's movie, in turn.
pub const Reports = struct {
    movies: [most][]const u8 = undefined,
    count: usize = 0,

    /// The most a chapter plays, as mission 11's does.
    const most = 3;

    pub fn slice(reports: *const Reports) []const []const u8 {
        return reports.movies[0..reports.count];
    }
};

/// The bank the news' loop is (`0x004ABFFE`), and its volume (`0x004AC05D`).
pub const news_loop = "newsloop.fat";
pub const news_loop_volume = 0x50;

/// The news' transition, which plays before each report (`0x0050A5F0`).
pub const news_transition = "acntran.bik";

/// What the landing plays on each carrier: its movie (`0x004AC203`, `0x004AC28B`), and the
/// thread's movie and the bank by the mission's rating, from a failure to a success with its bonus
/// (`0x004ABDEC` on). A total failure takes a failure's.
const Carrier = struct {
    landing: []const u8,
    threads: [5][]const u8,
    banks: [5][]const u8,

    fn touchdown(carrier: Carrier, rating: Rating) Touchdown {
        const place: ?usize = switch (rating) {
            .total_failure => 0,
            .failure, .partial_failure, .partial_success, .success, .success_bonus => @intCast(@intFromEnum(rating)),
            _ => null,
        };
        return .{
            .movie = carrier.landing,
            .thread = if (place) |at| carrier.threads[at] else null,
            .bank = if (place) |at| carrier.banks[at] else null,
        };
    }
};

const reliant: Carrier = .{
    .landing = "r_h_land.bik",
    .threads = .{ "rthread_d.bik", "rthread_d.bik", "rthread_c.bik", "rthread_b.bik", "rthread_a.bik" },
    .banks = .{ "rlande.fat", "rlandd.fat", "rlandc.fat", "rlandb.fat", "rlanda.fat" },
};

const yamato: Carrier = .{
    .landing = "yamland_generic.bik",
    .threads = .{ "thread04.bik", "thread04.bik", "thread03.bik", "thread02.bik", "thread01.bik" },
    .banks = .{ "ylande.fat", "ylandd.fat", "ylandc.fat", "ylandb.fat", "ylanda.fat" },
};

/// Whether mission `mission` ends on the Yamato: from mission 18 on, the last the pilot flies from
/// the Reliant (`0x004ABF2D`).
pub fn onYamato(mission: u16) bool {
    return mission >= movie.last_from_reliant;
}

/// The chapter each of missions 1 to 32 ends, 0 for none (`0x00509C00`; the game indexes it by the
/// mission's number from the byte before): missions 7, 11, 19, 21 and 25 end chapters 1 to 5.
const chapters = [32]u8{ 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 4, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0 };

/// Each chapter's movie (`0x00509BE8`), the first for none.
const chapter_movies = [_][]const u8{ "dummy.bik", "new_chapter1.bik", "new_chapter2.bik", "new_chapter3.bik", "new_chapter4.bik", "new_chapter5.bik" };

/// The chapter mission `mission` ends, where it ends one.
///
/// **Fix:** past the table's end, the game reads the chapter from what follows it in memory, and
/// the movie of that from past its own table's end. OpenReliant ends no chapter there.
pub fn chapterOf(mission: u16) ?u8 {
    if (mission == 0 or mission > chapters.len) return null;
    const chapter = chapters[mission - 1];
    return if (chapter == 0) null else chapter;
}

/// The zooms into a chapter's movie: before mission 18, and from it on (`0x004AC03B`).
const zoom_before_yamato = "thread_zoom.bik";
const zoom_from_yamato = "rthread_zoom.bik";

/// A news report: its movie, which plays where each of the game's variables `unless` names is other
/// than 1, and the variable it then sets to 1, where it sets one.
const Report = struct {
    movie: []const u8,
    unless: []const u8,
    sets: ?u8 = null,
};

/// The reports after a chapter's movie, by the mission that ends it (`0x004AC07F` on). The
/// variables are the game's, by number (`vm.Variables`): all but 34 are the campaign's flags, which
/// a new campaign sets (`gameflow.newCampaign`) and a mission's script may clear, and each attempt
/// at a mission clears 34 (`gameflow.resetVariables`). What each stands for is not known
/// ([#381](https://github.com/vdmkenny/openreliant/issues/381)). Mission 16's are never reached, as
/// it ends no chapter.
const news = [_]struct { mission: u16, reports: []const Report }{
    .{ .mission = 7, .reports = &.{
        .{ .movie = "new_chapter1_thread1.bik", .unless = &.{18} },
    } },
    .{ .mission = 11, .reports = &.{
        .{ .movie = "new_chapter2_thread1.bik", .unless = &.{29} },
        .{ .movie = "new_chapter2_thread2.bik", .unless = &.{17} },
        .{ .movie = "new_chapter2_thread3.bik", .unless = &.{6}, .sets = 34 },
    } },
    .{ .mission = 16, .reports = &.{
        .{ .movie = "new_chapter3_thread1.bik", .unless = &.{5} },
        .{ .movie = "new_chapter3_thread2.bik", .unless = &.{23} },
        .{ .movie = "new_chapter2_thread3.bik", .unless = &.{ 6, 34 } },
    } },
};

comptime {
    for (news) |mission| std.debug.assert(mission.reports.len <= Reports.most);
}

/// The reports after the chapter mission `mission` ends, by the game's `variables`, which a report
/// that plays may set.
fn reportsAfter(mission: u16, variables: *vm.Variables) Reports {
    var chosen: Reports = .{};
    for (news) |entry| {
        if (entry.mission != mission) continue;
        report: for (entry.reports) |report| {
            for (report.unless) |number| if (variables.slot(number).* == 1) continue :report;
            chosen.movies[chosen.count] = report.movie;
            chosen.count += 1;
            if (report.sets) |number| variables.slot(number).* = 1;
        }
    }
    return chosen;
}

/// Mission 27, which ends without the landing as mission 25's second part may.
const mission27 = 27;

/// The variable that, clear, has mission 25's second part and mission 27 end without the landing
/// (`0x004ABEA7`), and the one that, clear, has mission 8 end on the Yamato, as mission 7 always
/// does (`0x004ABF09`, `0x004AC1F0`). Both are the campaign's flags.
pub const last_missions_land = 36;
pub const mission8_on_reliant = 32;

/// Whether mission `number` is mission 25 or 27 with `last_missions_land` clear: no landing plays
/// after it, where it is 25's second part, and a total failure in it ends the pilot's career in the
/// shuttle at Fort Bear (`winmain.afterMission`).
pub fn lastWithoutLanding(number: u16, variables: *vm.Variables) bool {
    return (number == winmain.second_part_mission or number == mission27) and variables.slot(last_missions_land).* == 0;
}

/// `play_landing_movie` (`0x004ABDE0`) after mission `mission` ended as `ending`: what it plays by
/// the mission, its rating (`vm.Variables.mission_success`) and the game's `variables`, which a
/// news report may set; null for nothing. `second_part` is mission 25's second part
/// (`mission25_second_part`).
///
/// Nothing plays after mission 25's second part or mission 27 where `last_missions_land` is clear, nor where
/// the ship was sent home (`Ending.friendly_fire` and 7). A mission that ends a chapter, unless the
/// script rated it a total failure, ends in the chapter; any other in the landing, on the Yamato
/// from mission 18 on and after mission 7, and after mission 8 where `mission8_on_reliant` is
/// clear, and on the Reliant otherwise. Mission 7's and 8's landings on the Yamato take a failure's
/// thread and bank, whatever the rating.
pub fn landing(mission: u16, second_part: bool, ending: Ending, variables: *vm.Variables) ?Landing {
    // Mission 25's second part may come numbered 251, which counts as 25 (`0x004ABE8D`).
    const number = if (mission == winmain.second_part_number) winmain.second_part_mission else mission;
    const first_part = number == winmain.second_part_mission and !second_part;
    if (!first_part and lastWithoutLanding(number, variables)) return null;
    switch (ending) {
        .friendly_fire, ._unknown_7 => return null,
        else => {},
    }
    const rating = variables.mission_success;
    if (rating != .total_failure) if (chapterOf(number)) |chapter| return .{ .chapter = .{
        .disc = if (onYamato(number)) .one else .two,
        .zoom = if (onYamato(number)) zoom_from_yamato else zoom_before_yamato,
        .movie = chapter_movies[chapter],
        .reports = reportsAfter(number, variables),
    } };
    const visiting = number == 7 or (number == 8 and variables.slot(mission8_on_reliant).* == 0);
    if (visiting) return .{ .touchdown = yamato.touchdown(.failure) };
    return .{ .touchdown = (if (onYamato(number)) yamato else reliant).touchdown(rating) };
}

fn campaign() vm.Variables {
    var variables: vm.Variables = .{};
    @import("../gameflow.zig").newCampaign(&variables);
    return variables;
}

test "the landing, by carrier and rating" {
    var variables = campaign();
    variables.mission_success = .success;
    const reliant_success = landing(1, false, .playing, &variables).?.touchdown;
    try std.testing.expectEqualStrings("r_h_land.bik", reliant_success.movie);
    try std.testing.expectEqualStrings("rthread_b.bik", reliant_success.thread.?);
    try std.testing.expectEqualStrings("rlandb.fat", reliant_success.bank.?);
    // From mission 18 on, the Yamato's; a total failure takes a failure's.
    variables.mission_success = .total_failure;
    const yamato_failure = landing(18, false, .rescued, &variables).?.touchdown;
    try std.testing.expectEqualStrings("yamland_generic.bik", yamato_failure.movie);
    try std.testing.expectEqualStrings("thread04.bik", yamato_failure.thread.?);
    try std.testing.expectEqualStrings("ylande.fat", yamato_failure.bank.?);
    variables.mission_success = .success_bonus;
    try std.testing.expectEqualStrings("thread01.bik", landing(24, false, .playing, &variables).?.touchdown.thread.?);
    // A rating past the named ones lands without the thread and the bank.
    variables.mission_success = @enumFromInt(5);
    const unrated = landing(2, false, .playing, &variables).?.touchdown;
    try std.testing.expectEqualStrings("r_h_land.bik", unrated.movie);
    try std.testing.expectEqual(null, unrated.thread);
    try std.testing.expectEqual(null, unrated.bank);
}

test "missions 7 and 8 land on the Yamato" {
    var variables = campaign();
    // Mission 7 ends chapter 1, unless it was a total failure.
    variables.mission_success = .total_failure;
    const seven = landing(7, false, .playing, &variables).?.touchdown;
    try std.testing.expectEqualStrings("yamland_generic.bik", seven.movie);
    try std.testing.expectEqualStrings("thread04.bik", seven.thread.?);
    try std.testing.expectEqualStrings("ylande.fat", seven.bank.?);
    variables.mission_success = .success;
    try std.testing.expectEqualStrings("r_h_land.bik", landing(8, false, .playing, &variables).?.touchdown.movie);
    variables.slot(mission8_on_reliant).* = 0;
    const eight = landing(8, false, .playing, &variables).?.touchdown;
    try std.testing.expectEqualStrings("yamland_generic.bik", eight.movie);
    try std.testing.expectEqualStrings("thread04.bik", eight.thread.?);
}

test "a chapter's end, and its news" {
    var variables = campaign();
    variables.mission_success = .partial_success;
    const first = landing(7, false, .playing, &variables).?.chapter;
    try std.testing.expectEqual(disc.Number.two, first.disc);
    try std.testing.expectEqualStrings("thread_zoom.bik", first.zoom);
    try std.testing.expectEqualStrings("new_chapter1.bik", first.movie);
    try std.testing.expectEqual(0, first.reports.count);
    // A flag the script cleared calls for its report.
    variables.slot(18).* = 0;
    try std.testing.expectEqualStrings("new_chapter1_thread1.bik", landing(7, false, .playing, &variables).?.chapter.reports.slice()[0]);
    // Mission 11's third report marks itself played.
    variables.slot(29).* = 0;
    variables.slot(6).* = 0;
    const second = landing(11, false, .playing, &variables).?.chapter;
    const played = second.reports.slice();
    try std.testing.expectEqual(2, played.len);
    try std.testing.expectEqualStrings("new_chapter2_thread1.bik", played[0]);
    try std.testing.expectEqualStrings("new_chapter2_thread3.bik", played[1]);
    try std.testing.expectEqual(1, variables.slot(34).*);
    // Mission 16's reports hold the third back once it has played.
    try std.testing.expectEqual(0, reportsAfter(16, &variables).count);
    // Chapters 3 to 5 from the first disc, and past the table none.
    const fifth = landing(25, true, .playing, &variables).?.chapter;
    try std.testing.expectEqual(disc.Number.one, fifth.disc);
    try std.testing.expectEqualStrings("rthread_zoom.bik", fifth.zoom);
    try std.testing.expectEqualStrings("new_chapter5.bik", fifth.movie);
    try std.testing.expectEqual(null, chapterOf(33));
    try std.testing.expectEqual(null, chapterOf(0));
}

test "no landing" {
    var variables = campaign();
    variables.mission_success = .success;
    // Sent home for destroying a friend.
    try std.testing.expectEqual(null, landing(3, false, .friendly_fire, &variables));
    // Mission 25's second part and mission 27 once `last_missions_land` is clear; 251 counts as 25.
    try std.testing.expect(landing(27, false, .playing, &variables) != null);
    variables.slot(last_missions_land).* = 0;
    try std.testing.expectEqual(null, landing(27, false, .playing, &variables));
    try std.testing.expectEqual(null, landing(25, true, .playing, &variables));
    try std.testing.expectEqual(null, landing(winmain.second_part_number, true, .playing, &variables));
    try std.testing.expect(landing(25, false, .playing, &variables) != null);
}

test lastWithoutLanding {
    var variables = campaign();
    try std.testing.expect(!lastWithoutLanding(25, &variables));
    variables.slot(last_missions_land).* = 0;
    try std.testing.expect(lastWithoutLanding(25, &variables));
    try std.testing.expect(lastWithoutLanding(27, &variables));
    try std.testing.expect(!lastWithoutLanding(26, &variables));
}
