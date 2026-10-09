//! The KILLBOARD, the ITAC's eighth section: the pilots of the Reliant's squadrons and the player,
//! best first, five at a time, each with their portrait of `kills.spr`, their name and squadron,
//! their ship and their kills (`tables.pilots`). Each pilot's kills grow mission by mission from a
//! seed the campaign keeps (`Campaign.killboard_seed`), and the board follows the campaign: some
//! pilots leave it, one joins it, and from mission 14 the 45th Volunteers fly as the 45th Flying
//! Tigers.
//!
//! **Unverified:** the file. Its code (`0x00441100` to `0x00441A9D`) lies after the ITAC's shared
//! code and before `loadout.cpp`'s, where no string places it; it goes with the ITAC, whose section
//! it is.

const std = @import("std");

const canvas_module = @import("../interface/canvas.zig");
const gameflow = @import("../gameflow.zig");
const hud = @import("../hud.zig");
const itac_module = @import("../itac.zig");
const language = @import("../language.zig");
const tables = @import("tables.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Itac = itac_module.Itac;

/// The portraits (`0x004EA2B8`), which it reads as it opens and lets go of as it is left.
pub const pictures_name = "inter\\itac\\kills.spr";

/// The pane the board is written into (`0x00441540`).
const board_pane: Rect = .{ .x = 30, .y = 72, .width = 593, .height = 295 };
const board = 0;

/// Where each column starts, and the columns' headings, in the headers' colour (`0x00441594` on).
const name_column = 105;
const ship_column = 258;
const kills_column = 411;
const columns = [_]struct { x: i32, heading: u16 }{
    .{ .x = name_column, .heading = 0x6B4 },
    .{ .x = ship_column, .heading = 0x6B5 },
    .{ .x = kills_column, .heading = 0x6B6 },
};

/// The rows, `shown` from the first, each `row_height` below the last: the place in the large font
/// at `place_at`, the portrait at `portrait_at`, the name at `name_y`, the squadron below it in
/// `squadron_lines` from `squadron_y`, the player's call sign and squadron from `name_y`, and the
/// ship and the kills at `figures_y` (`0x0044166C` on).
const shown = 5;
const row_height = 55;
const place_at: [2]i32 = .{ 20, 37 };
const portrait_at: [2]i32 = .{ 42, 25 };
const name_y = 24;
const squadron_y = 39;
const figures_y = 40;
const squadron_lines: Canvas.Lines = .{ .width = 138, .height = 15, .most = 2 };

/// The palette a portrait is drawn with: block 0 for the player and the 45th's own pilots, block 6
/// for the rest, unfaded (`0x00441987`).
const own_palette = 0;
const other_palette = 6;
const unfaded = 1;

/// The arrows that step the board on and back (`0x004EA2A8`).
const arrows = [2]Rect{ .{ .x = 293, .y = 377, .width = 26, .height = 26 }, .{ .x = 319, .y = 377, .width = 26, .height = 26 } };

/// The player's squadron, the 45th Volunteers, which flies as the 45th Flying Tigers where the
/// mission's rules say so (`gameflow.CampaignMission.Rules.flying_tigers`, from mission 14 in the
/// original), as do the 45th's other pilots (`Pilot.in_45th`; `0x004416BF`, `0x00441735`).
const volunteers = 0x1C8;
const flying_tigers = 0x1C9;

/// The room a row's lines are written into (`0x00441540`).
const line_room = 200;

/// The player's portraits (`0x00441148`).
const female_portrait = 1;
const male_portrait = 2;

/// A pilot of the board.
pub const Pilot = struct {
    name: language.Words,
    /// The line below the name: the pilot's squadron, in brackets.
    squadron: language.Words,
    /// The pilot's ship; none leaves the column empty.
    ship: ?language.Words = null,
    /// The kills the pilot starts a campaign with, and the mean and the spread of those each
    /// mission adds (`killboard_kills`).
    kills: i16 = 0,
    mean: f32 = 0,
    spread: f32 = 0,
    /// The shape of the pilot's portrait in `kills.spr`.
    portrait: u16,
    /// Whether the pilot flies in the 45th: the portrait takes the 45th's palette, and the squadron
    /// shows as the 45th Flying Tigers where the 45th fly as them.
    in_45th: bool = false,
    /// The first mission the pilot is on the board in; null for every mission.
    joins_at: ?u16 = null,
    /// The last mission the pilot is on the board in; null for every mission.
    leaves_after: ?u16 = null,
    /// The missions in which the pilot adds no kills.
    sits_out: []const u16 = &.{},

    /// Whether the pilot is on the board before mission `mission`.
    fn onBoard(pilot: Pilot, mission: u16) bool {
        if (pilot.leaves_after) |after| if (mission > after) return false;
        if (pilot.joins_at) |first| if (mission < first) return false;
        return true;
    }

    /// The original's pilots (`tables.pilots`), with the 45th's (`0x00441987`), the pilots who
    /// leave the board and the one who joins it (`0x00441320`), and the pilot who sits out missions
    /// 19 to 23 (`killboard_kills`, `0x0044148C` on). The game tests Manzo Takamatsu after mission
    /// 23 and again after mission 22, so he leaves after 22.
    pub const original: [tables.pilots.len]Pilot = pilots: {
        var pilots: [tables.pilots.len]Pilot = undefined;
        for (&pilots, tables.pilots) |*pilot, table| {
            var leaves: ?u16 = null;
            for (leaving) |entry| {
                if (entry.name == table.name) leaves = @min(leaves orelse entry.after, entry.after);
            }
            pilot.* = .{
                .name = .{ .string = table.name },
                .squadron = .{ .string = table.call_sign },
                .ship = if (table.ship > 0) .{ .string = table.ship } else null,
                .kills = table.base_kills,
                .mean = table.mean,
                .spread = table.spread,
                .portrait = @intCast(table.shape),
                .in_45th = std.mem.findScalar(u16, &the_45th, table.name) != null,
                .joins_at = if (table.name == joining) joining_mission else null,
                .leaves_after = leaves,
                .sits_out = if (table.name == away) &away_missions else &.{},
            };
        }
        break :pilots pilots;
    };

    const the_45th = [_]u16{ 0x515, 0x6E1, 0x6E7 };
    const Leaves = struct { name: u16, after: u16 };
    const leaving = [_]Leaves{
        .{ .name = 0x6D8, .after = 23 },
        .{ .name = 0x6D5, .after = 25 },
        .{ .name = 0x6CF, .after = 21 },
        .{ .name = 0x6BD, .after = 12 },
        .{ .name = 0x6B7, .after = 21 },
        .{ .name = 0x518, .after = 5 },
        .{ .name = 0x6E7, .after = 5 },
        .{ .name = 0x6D8, .after = 22 },
    };
    const joining = 0x6E1;
    const joining_mission = 6;
    const away = 0x6DB;
    const away_missions = [_]u16{ 19, 20, 21, 22, 23 };
};

/// The board's pilots: the original's until OpenReliant installs the records' (`install`).
var installed: []const Pilot = &Pilot.original;

/// Uses `pilots` as the board's pilots. OpenReliant installs the records' once the load scripts
/// have run.
pub fn install(pilots: []const Pilot) void {
    installed = pilots;
}

/// What `rand` gives at most, which the kills of a mission are drawn against (`0x004DC4C8`), and the
/// middle of that draw (`0x004DC408`).
const rand_max = 32767;
const middle: f32 = 0.5;

/// An entry of the board: a pilot of the table, or the player.
const Entry = union(enum) {
    pilot: u8,
    player,
};

/// The most pilots the board holds: the original's, since the records can't add pilots.
const most_pilots = Pilot.original.len;

pub const Killboard = struct {
    /// The board, best first (`0x00523710`), and how many it holds (`0x005231D0`).
    entries: [most_pilots + 1]Entry = undefined,
    count: u8 = 0,
    /// Each pilot's kills (`+0x66` of their record), and the player's (`skull_count`).
    kills: [most_pilots]i16 = undefined,
    player_kills: i16 = 0,
    /// The place of the first shown (`0x00523714`).
    first: u8 = 0,
    /// Its portraits (`0x0052370C`), and whether it is open (`0x00523718`).
    pictures: itac_module.Pictures = .{},

    /// `0x00441100`: the player's entry, every pilot's kills added up (`killboard_kills`), the board
    /// listed best first (`0x00441320`) from its top, and the portraits read.
    pub fn enter(kill_board: *Killboard, itac: *Itac) void {
        const pilot = itac.pilot;
        kill_board.player_kills = @truncate(pilot.kills);
        kill_board.first = 0;
        kill_board.addUp(pilot.campaign.killboard_seed, pilot.mission);
        kill_board.list(pilot.mission);
        kill_board.pictures.read(itac.context, pictures_name);
    }

    /// `killboard_kills` (`0x00441460`): each pilot's kills. They start from the pilot's own, and
    /// each mission of the campaign's order before `mission` adds a draw from the seed `seed`,
    /// spread round the pilot's mean, except the missions the pilot sits out (`Pilot.sits_out`).
    ///
    /// **Improvement:** the game names missions 12, 13, 17 and 22 as the ones that add no kills
    /// (`0x0044148C` on). OpenReliant passes over the missions the campaign's order doesn't have
    /// (`gameflow.Order`), which are those four in the game's order, so that missions a mod puts
    /// back add their kills.
    ///
    /// **Fix:** the game adds up the kills of a twentieth record past the nineteen, which runs into
    /// the loadout's colours for its panels' text (`loadout_text_remap`, `0x004EA308`). OpenReliant
    /// adds up the nineteen's.
    ///
    /// **Improvement:** the draws come from `std.Random`, seeded with the campaign's seed, where the
    /// game uses `rand`.
    fn addUp(kill_board: *Killboard, seed: i32, mission: u16) void {
        var prng: std.Random.DefaultPrng = .init(@as(u32, @bitCast(seed)));
        const random = prng.random();
        for (boardPilots(), kill_board.kills[0..boardPilots().len]) |pilot, *kills| {
            kills.* = pilot.kills;
            for (1..@max(mission, 1)) |flown| {
                if (!gameflow.campaignOrder().has(@intCast(flown))) continue;
                if (std.mem.findScalar(u16, pilot.sits_out, @intCast(flown)) != null) continue;
                const drawn = @as(f32, @floatFromInt(random.uintAtMost(u16, rand_max))) / rand_max;
                kills.* +%= @intFromFloat((drawn - middle) * pilot.spread + pilot.mean);
            }
        }
    }

    /// `0x00441320`: the pilots on the board before `mission`, then the player, best first, those
    /// with as many kills in that order.
    fn list(kill_board: *Killboard, mission: u16) void {
        kill_board.count = 0;
        for (boardPilots(), 0..) |pilot, place| {
            if (!pilot.onBoard(mission)) continue;
            kill_board.entries[kill_board.count] = .{ .pilot = @intCast(place) };
            kill_board.count += 1;
        }
        kill_board.entries[kill_board.count] = .player;
        kill_board.count += 1;
        std.sort.insertion(Entry, kill_board.entries[0..kill_board.count], @as(*const Killboard, kill_board), moreKills);
    }

    fn killsOf(kill_board: *const Killboard, entry: Entry) i16 {
        return switch (entry) {
            .pilot => |place| kill_board.kills[place],
            .player => kill_board.player_kills,
        };
    }

    fn moreKills(kill_board: *const Killboard, a: Entry, b: Entry) bool {
        return kill_board.killsOf(a) > kill_board.killsOf(b);
    }

    /// `0x00441190`: the board emptied, where it is open.
    ///
    /// **Fix:** the game never lets go of the portraits it reads each time the board opens.
    /// OpenReliant does.
    pub fn leave(kill_board: *Killboard, gpa: std.mem.Allocator) void {
        if (kill_board.pictures.close(gpa)) kill_board.count = 0;
    }

    /// `0x004411C0`: its sound, a build asked for, the panes hidden, and the board built, wiping in.
    /// The game first draws a frame and keeps it as the picture its panes are copied from, which
    /// OpenReliant has no need of.
    pub fn loaded(kill_board: *Killboard, itac: *Itac) void {
        _ = kill_board;
        itac.play(.text, itac_module.full_volume, 1);
        itac.rebuildSection();
        itac.panes[board].wipeIn(board_pane);
    }

    /// `0x00441280`, each pass: the arrows step the board on, as far as its last five, and back.
    pub fn update(kill_board: *Killboard, itac: *Itac) void {
        const arrow = itac.arrowPressed(&arrows) orelse return;
        if (arrow == 0) {
            if (kill_board.first + shown < kill_board.count) kill_board.first += 1;
        } else {
            kill_board.first -|= 1;
        }
    }

    /// `0x00441300` and `0x00441540`, while it is open and no fade runs: the board as its pane has
    /// wiped in.
    pub fn draw(kill_board: *Killboard, itac: *Itac, canvas: Canvas) canvas_module.Error!void {
        if (!kill_board.pictures.open or !itac.panesShow()) return;
        const in_pane = canvas.within(itac.panes[board].showing() orelse return);
        const font = &(itac.small orelse return).font;
        for (columns) |column| try in_pane.text(font, at(column.x, 0), itac.string(column.heading), itac_module.header_colour, .left);
        const last = @min(kill_board.first + shown, kill_board.count);
        for (kill_board.entries[kill_board.first..last], 0..) |entry, row| {
            const top = row_height * @as(i32, @intCast(row));
            try kill_board.drawRow(itac, in_pane, font, entry, top);
            var place: [4]u8 = undefined;
            if (itac.large) |*large| try in_pane.text(&large.font, at(place_at[0], top + place_at[1]), std.mem.print(&place, "{d}", .{kill_board.first + row + 1}) catch "", itac_module.text_colour, .left);
            try kill_board.pictures.draw(in_pane, paletteOf(entry), portraitOf(entry, itac.pilot.female), at(portrait_at[0], top + portrait_at[1]), unfaded);
        }
    }

    /// A row's name and squadron, ship and kills.
    fn drawRow(kill_board: *const Killboard, itac: *Itac, in_pane: Canvas, font: *hud.Opened, entry: Entry, top: i32) canvas_module.Error!void {
        const tigers = gameflow.campaignField(itac.pilot.mission, .rules).flying_tigers;
        var text: [line_room]u8 = undefined;
        switch (entry) {
            .player => {
                const squadron = itac.string(if (tigers) flying_tigers else volunteers);
                const named = std.mem.print(&text, "{s}\n({s})", .{ itac.pilot.call_sign, squadron }) catch "";
                try in_pane.wrapped(font, at(name_column, top + name_y), named, itac_module.text_colour, .left, squadron_lines);
            },
            .pilot => |place| {
                const pilot = boardPilots()[place];
                try in_pane.text(font, at(name_column, top + name_y), itac.words(pilot.name), itac_module.text_colour, .left);
                const squadron = if (tigers and pilot.in_45th) std.mem.print(&text, "({s})", .{itac.string(flying_tigers)}) catch "" else itac.words(pilot.squadron);
                try in_pane.wrapped(font, at(name_column, top + squadron_y), squadron, itac_module.text_colour, .left, squadron_lines);
                if (pilot.ship) |ship| try in_pane.text(font, at(ship_column, top + figures_y), itac.words(ship), itac_module.text_colour, .left);
            },
        }
        var kills: [8]u8 = undefined;
        try in_pane.text(font, at(kills_column, top + figures_y), std.mem.print(&kills, "{d}", .{kill_board.killsOf(entry)}) catch "", itac_module.text_colour, .left);
    }
};

/// Where a point `x` across and `y` down the board's pane stands on the screen.
fn at(x: i32, y: i32) [2]i32 {
    return .{ board_pane.x + x, board_pane.y + y };
}

/// The installed pilots the board holds, at most `most_pilots`.
fn boardPilots() []const Pilot {
    return installed[0..@min(installed.len, most_pilots)];
}

/// The palette `entry`'s portrait is drawn with.
fn paletteOf(entry: Entry) usize {
    return switch (entry) {
        .player => own_palette,
        .pilot => |place| if (boardPilots()[place].in_45th) own_palette else other_palette,
    };
}

/// The shape of `entry`'s portrait, the player's by whether they are `female`.
fn portraitOf(entry: Entry, female: bool) usize {
    return switch (entry) {
        .player => if (female) female_portrait else male_portrait,
        .pilot => |place| boardPilots()[place].portrait,
    };
}

/// The original's pilot whose name is the ITAC's string `name`, for the tests.
fn originalNamed(name: u16) Pilot {
    for (Pilot.original) |pilot| if (pilot.name.string == name) return pilot;
    unreachable;
}

test "Pilot.onBoard" {
    // John McGann leaves after mission 5, Linc Stevenson joins at mission 6, and Manzo Takamatsu
    // leaves after mission 22.
    const mcgann = originalNamed(0x518);
    try std.testing.expect(mcgann.onBoard(5) and !mcgann.onBoard(6));
    const stevenson = originalNamed(Pilot.joining);
    try std.testing.expect(!stevenson.onBoard(5) and stevenson.onBoard(6));
    const takamatsu = originalNamed(0x6D8);
    try std.testing.expect(takamatsu.onBoard(22) and !takamatsu.onBoard(23));
}

test "Pilot.original" {
    // Klaus Steiner sits out missions 19 to 23, and three pilots fly in the 45th.
    try std.testing.expectEqualSlices(u16, &.{ 19, 20, 21, 22, 23 }, originalNamed(Pilot.away).sits_out);
    var in_45th: usize = 0;
    for (Pilot.original) |pilot| in_45th += @intFromBool(pilot.in_45th);
    try std.testing.expectEqual(3, in_45th);
    // A pilot with no ship leaves the column empty.
    for (Pilot.original, tables.pilots) |pilot, table| try std.testing.expectEqual(table.ship > 0, pilot.ship != null);
}

test "a mod's pilots" {
    var mod_pilots = Pilot.original;
    // Every pilot stays on the board, and Stevenson is there from the start.
    for (&mod_pilots) |*pilot| {
        pilot.leaves_after = null;
        pilot.joins_at = null;
    }
    install(&mod_pilots);
    defer install(&Pilot.original);
    var kill_board: Killboard = .{};
    kill_board.addUp(0, 10);
    kill_board.list(10);
    try std.testing.expectEqual(Pilot.original.len + 1, kill_board.count);
}

test "Killboard.list" {
    var kill_board: Killboard = .{ .player_kills = 1000 };
    kill_board.addUp(0, 1);
    // Before mission 1, the pilots' kills are those they start with, and the player with the most
    // leads the board; those after them are in order of their kills.
    try std.testing.expectEqual(tables.pilots[0].base_kills, kill_board.kills[0]);
    kill_board.list(1);
    try std.testing.expectEqual(Entry.player, kill_board.entries[0]);
    for (kill_board.entries[1 .. kill_board.count - 1], kill_board.entries[2..kill_board.count]) |better, worse| {
        try std.testing.expect(kill_board.killsOf(better) >= kill_board.killsOf(worse));
    }
    // Linc Stevenson isn't on it yet.
    for (kill_board.entries[0..kill_board.count]) |entry| switch (entry) {
        .pilot => |place| try std.testing.expect(Pilot.original[place].name.string != Pilot.joining),
        .player => {},
    };
}

test "Killboard.addUp" {
    var kill_board: Killboard = .{};
    // Each mission flown adds about the mean, more or less half the spread, the quiet ones none.
    kill_board.addUp(1, 12);
    const pilot = tables.pilots[0];
    const missions_counted = 11;
    const least: f32 = @as(f32, @floatFromInt(pilot.base_kills)) + missions_counted * (pilot.mean - pilot.spread / 2 - 1);
    const most_kills: f32 = @as(f32, @floatFromInt(pilot.base_kills)) + missions_counted * (pilot.mean + pilot.spread / 2 + 1);
    try std.testing.expect(@as(f32, @floatFromInt(kill_board.kills[0])) >= least);
    try std.testing.expect(@as(f32, @floatFromInt(kill_board.kills[0])) <= most_kills);
    // The same seed adds up the same.
    var again: Killboard = .{};
    again.addUp(1, 12);
    try std.testing.expectEqualSlices(i16, &kill_board.kills, &again.kills);
}
