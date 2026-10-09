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
const own_pilots = [_]u16{ 0x515, 0x6E1, 0x6E7 };

/// The arrows that step the board on and back (`0x004EA2A8`).
const arrows = [2]Rect{ .{ .x = 293, .y = 377, .width = 26, .height = 26 }, .{ .x = 319, .y = 377, .width = 26, .height = 26 } };

/// The player's squadron, the 45th Volunteers, which flies as the 45th Flying Tigers from
/// `renamed_from`, as do the pilots whose squadron the board names by these strings
/// (`0x004416BF`, `0x00441735`).
const volunteers = 0x1C8;
const flying_tigers = 0x1C9;
const renamed_from = 14;
const squadron_mates = [_]u16{ 0x6E8, 0x519, 0x6E2 };

/// The room a row's lines are written into (`0x00441540`).
const line_room = 200;

/// The player's portraits (`0x00441148`).
const female_portrait = 1;
const male_portrait = 2;

/// The pilots that leave the board after a mission, and the one that joins it at one
/// (`0x00441320`). The game tests Manzo Takamatsu after mission 23 and again after mission 22.
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
const joins_at = 6;

/// The pilot who adds no kills from mission `away_from` to `away_to` (`killboard_kills`,
/// `0x0044148C` on). Not yet in the records, with the pilots who leave and join
/// ([#1008](https://github.com/OpenReliant/openreliant/issues/1008)).
const away = 0x6DB;
const away_from = 19;
const away_to = 23;

/// What `rand` gives at most, which the kills of a mission are drawn against (`0x004DC4C8`), and the
/// middle of that draw (`0x004DC408`).
const rand_max = 32767;
const middle: f32 = 0.5;

/// An entry of the board: a pilot of the table, or the player.
const Entry = union(enum) {
    pilot: u8,
    player,
};

pub const Killboard = struct {
    /// The board, best first (`0x00523710`), and how many it holds (`0x005231D0`).
    entries: [tables.pilots.len + 1]Entry = undefined,
    count: u8 = 0,
    /// Each pilot's kills (`+0x66` of their record), and the player's (`skull_count`).
    kills: [tables.pilots.len]i16 = undefined,
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
    /// spread round the pilot's mean.
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
        for (tables.pilots, &kill_board.kills) |pilot, *kills| {
            kills.* = pilot.base_kills;
            for (1..@max(mission, 1)) |flown| {
                if (!gameflow.campaignOrder().has(@intCast(flown))) continue;
                if (pilot.name == away and flown >= away_from and flown <= away_to) continue;
                const drawn = @as(f32, @floatFromInt(random.uintAtMost(u16, rand_max))) / rand_max;
                kills.* +%= @intFromFloat((drawn - middle) * pilot.spread + pilot.mean);
            }
        }
    }

    /// `0x00441320`: the pilots on the board before `mission`, then the player, best first, those
    /// with as many kills in that order.
    fn list(kill_board: *Killboard, mission: u16) void {
        kill_board.count = 0;
        for (tables.pilots, 0..) |pilot, place| {
            if (!onBoard(pilot.name, mission)) continue;
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
        const mission = itac.pilot.mission;
        var text: [line_room]u8 = undefined;
        switch (entry) {
            .player => {
                const squadron = itac.string(if (mission >= renamed_from) flying_tigers else volunteers);
                const named = std.mem.print(&text, "{s}\n({s})", .{ itac.pilot.call_sign, squadron }) catch "";
                try in_pane.wrapped(font, at(name_column, top + name_y), named, itac_module.text_colour, .left, squadron_lines);
            },
            .pilot => |place| {
                const pilot = tables.pilots[place];
                try in_pane.text(font, at(name_column, top + name_y), itac.string(pilot.name), itac_module.text_colour, .left);
                const renamed = mission >= renamed_from and std.mem.findScalar(u16, &squadron_mates, pilot.call_sign) != null;
                const squadron = if (renamed) std.mem.print(&text, "({s})", .{itac.string(flying_tigers)}) catch "" else itac.string(pilot.call_sign);
                try in_pane.wrapped(font, at(name_column, top + squadron_y), squadron, itac_module.text_colour, .left, squadron_lines);
                if (pilot.ship > 0) try in_pane.text(font, at(ship_column, top + figures_y), itac.string(pilot.ship), itac_module.text_colour, .left);
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

/// Whether the pilot named `name` is on the board before mission `mission`.
fn onBoard(name: u16, mission: u16) bool {
    for (leaving) |leaves| {
        if (name == leaves.name and mission > leaves.after) return false;
    }
    return !(name == joining and mission < joins_at);
}

/// The palette `entry`'s portrait is drawn with.
fn paletteOf(entry: Entry) usize {
    return switch (entry) {
        .player => own_palette,
        .pilot => |place| if (std.mem.findScalar(u16, &own_pilots, tables.pilots[place].name) != null) own_palette else other_palette,
    };
}

/// The shape of `entry`'s portrait, the player's by whether they are `female`.
fn portraitOf(entry: Entry, female: bool) usize {
    return switch (entry) {
        .player => if (female) female_portrait else male_portrait,
        .pilot => |place| @intCast(tables.pilots[place].shape),
    };
}

test onBoard {
    // John McGann leaves after mission 5, Linc Stevenson joins at mission 6, and Manzo Takamatsu
    // leaves after mission 22.
    try std.testing.expect(onBoard(0x518, 5));
    try std.testing.expect(!onBoard(0x518, 6));
    try std.testing.expect(!onBoard(joining, 5));
    try std.testing.expect(onBoard(joining, 6));
    try std.testing.expect(onBoard(0x6D8, 22));
    try std.testing.expect(!onBoard(0x6D8, 23));
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
        .pilot => |place| try std.testing.expect(tables.pilots[place].name != joining),
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
