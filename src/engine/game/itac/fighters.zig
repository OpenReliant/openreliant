//! The fighters of either side, the ITAC's fourth section: ALLIANCE FIGHTERS and COALITION FIGHTERS
//! (`tables.fighters`), each with its picture of `fighters.spr`, its figures and its armament,
//! chosen from a list. The emblems at the top right choose the side, the Alliance's first. The
//! figures are the loadout's bars (`bars.ShipBars`), worked out as the section opens.
//!
//! **Unverified:** the file. Its code (`0x00425910` to `0x004265F1`) lies after DEBRIEFINGS' and
//! before `loadout_ship_bars_init`, between `wgate.cpp`'s known code and `interf.cpp`'s, where no
//! string places it; it goes with the ITAC, whose section it is.

const std = @import("std");

const canvas_module = @import("../interface/canvas.zig");
const bars = @import("../../interface/loadout/bars.zig");
const create = @import("../create.zig");
const itac_module = @import("../itac.zig");
const language = @import("../language.zig");
const tables = @import("tables.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Itac = itac_module.Itac;

/// The pictures (`0x004E5A04`), which it reads as it opens and lets go of as it is left.
pub const pictures_name = "inter\\itac\\fighters.spr";

/// Where the chosen fighter's picture stands (`0x00425B08`), and the blocks of `fighters.spr`'s
/// palettes, the last of which before its shape it is drawn with (`0x00425A99`).
const picture_at: [2]i32 = .{ 91, 65 };
const palette_blocks = [_]usize{ 0, 5, 10, 15, 17, 22, 27 };

/// The buttons that choose the side, the Alliance's and the Coalition's (`0x004E5460`).
const side_buttons = [2]Rect{ .{ .x = 551, .y = 59, .width = 64, .height = 41 }, .{ .x = 478, .y = 59, .width = 64, .height = 61 } };

/// The panes it writes into (`0x00425B70`): the name, the figures, the armament and the list.
const name_pane: Rect = .{ .x = 32, .y = 80, .width = 113, .height = 13 };
const figures_pane: Rect = .{ .x = 33, .y = 252, .width = 200, .height = 138 };
const armament_pane: Rect = .{ .x = 253, .y = 252, .width = 207, .height = 138 };
const list_pane: Rect = .{ .x = 474, .y = 146, .width = 146, .height = 218 };
const name = 0;
const figures = 1;
const armament = 2;
const list = 3;

/// The name, in capitals in the headers' colour, where it stands in its pane (`0x004260E2`), and
/// the room its copy and the armament's lines have (`0x00426030`).
const name_at: [2]i32 = .{ 2, 2 };
const line_room = 100;

/// The figures' rows, 15 apart from the top of their pane (`0x00425C87` on), the bars' from
/// `first_bar_row`, their values right-aligned at `value_x`, and the strings of their labels.
const row_height = 15;
const first_row = 2;
const first_bar_row = 2;
const value_x = 199;
const type_label = 0x4B5;
const clearance_label = 0x4C1;
const speed_label = 0x4B7;
const acceleration_label = 0x4B9;
const agility_label = 0x4B8;
const shield_label = 0x4BA;
const recharge_label = 0x711;
const armor_label = 0x4BB;

/// The armament's: the afterburner's fuel in seconds, then ARMAMENT with a gun a row, the crew, and
/// the special abilities in a paragraph `special_lines` from `specials_x` (`0x00426030`).
const fuel_label = 0x4BF;
const seconds = 0x4D1;
const armament_label = 0x4BC;
const crew_label = 0x4BD;
const special_lines: Canvas.Lines = .{ .width = 197, .height = 11, .most = 20 };
const specials_x = 2;
const special_separator = ", ";

/// The list of the side's fighters (`0x00426490`): each name 6 below the last, every one listed.
const title_list: itac_module.TitleList = .{ .pane = list_pane, .top = 2, .width = 126, .gap = 6, .hotspot_extra = 4 };

/// The most fighters a side lists.
const most = @max(tables.fighters[0].len, tables.fighters[1].len);

pub const Fighters = struct {
    /// The fighter chosen, by its place in the side's list (`0x0051D398`).
    selected: u8 = 0,
    /// Its pictures (`0x0051D388`), and whether it is open (`0x0051D448`).
    pictures: itac_module.Pictures = .{},
    /// Each fighter's bars, by side (`loadout_ship_bars_init`, `0x00426600`).
    bars: [2][most]bars.ShipBars = undefined,
    /// The strings of the side's fighters' names, which the list shows.
    titles: [most]language.Words = undefined,
    /// The entries the list shows, each a hotspot (`0x0051D3C0`).
    listed: [most]itac_module.ListEntry = undefined,
    listed_count: u8 = 0,

    /// `0x00425910`: the first fighter chosen, every fighter's bars worked out, the side's listed
    /// (`0x004265B0`), and the pictures read.
    pub fn enter(fighters: *Fighters, itac: *Itac) void {
        fighters.selected = 0;
        fighters.workOutBars(itac.context.stats);
        fighters.listSide(itac.side);
        fighters.pictures.read(itac.context, pictures_name);
    }

    /// `loadout_ship_bars_init` (`0x00426600`), over the fighters of both sides.
    fn workOutBars(fighters: *Fighters, stats: *const create.Stats) void {
        const ranges: bars.ShipRanges = .init(stats);
        for (tables.fighters, &fighters.bars) |side, *side_bars| {
            for (side, side_bars[0..side.len]) |fighter, *fighter_bars| fighter_bars.* = .of(ranges, stats, fighter.ship_type);
        }
    }

    /// The strings of `side`'s fighters' names, in the table's order.
    fn listSide(fighters: *Fighters, side: itac_module.Side) void {
        for (tables.fighters[@backingInt(side)], 0..) |fighter, place| fighters.titles[place] = .{ .string = fighter.name };
    }

    /// `0x00425960`: the pictures let go of, where it is open.
    pub fn leave(fighters: *Fighters, gpa: std.mem.Allocator) void {
        _ = fighters.pictures.close(gpa);
    }

    /// `0x00425980`, each pass: a build asked for, the other side chosen by its emblem, and another
    /// fighter chosen from the list.
    ///
    /// **Fix:** as another fighter is chosen, the game holds the screen still for half a second
    /// (`itac_pause`, `0x00440170`), drawing nothing. OpenReliant shows the fighter at once.
    pub fn update(fighters: *Fighters, itac: *Itac) void {
        if (itac.rebuildDue()) fighters.build(itac, true);
        if (itac.sidePressed(&side_buttons)) {
            fighters.selected = 0;
            fighters.listSide(itac.side);
            fighters.build(itac, true);
        }
        if (itac.entryChosen(fighters.listed[0..fighters.listed_count], fighters.selected)) |place| {
            fighters.selected = place;
            fighters.build(itac, false);
        }
    }

    /// The side's fighters.
    fn sideFighters(itac: *const Itac) []const tables.Fighter {
        return tables.fighters[@backingInt(itac.side)];
    }

    /// `0x00425B70`: its sound, and for the fighter chosen, its name's, figures' and armament's
    /// panes wiping in and the list laid out; with `wipe`, the list's pane wiping in too.
    fn build(fighters: *Fighters, itac: *Itac, wipe: bool) void {
        itac.play(.text, itac_module.full_volume, 1);
        itac.panes[name].wipeIn(name_pane);
        itac.panes[armament].wipeIn(armament_pane);
        itac.panes[figures].wipeIn(figures_pane);
        fighters.listed_count = title_list.layOut(itac, fighters.titles[0..sideFighters(itac).len], 0, &fighters.listed);
        if (wipe) itac.panes[list].wipeIn(list_pane);
    }

    /// `0x00425A70` at `fade`, while it is open: the chosen fighter's picture and the side's
    /// emblem at `fade`, and its panes while no fade runs.
    pub fn draw(fighters: *Fighters, itac: *Itac, canvas: Canvas, fade: f32) canvas_module.Error!void {
        if (!fighters.pictures.open) return;
        const fighter = sideFighters(itac)[fighters.selected];
        try fighters.pictures.drawWithPalettes(canvas, &palette_blocks, fighter.shape, picture_at, fade);
        try itac.drawEmblem(canvas, fade);
        if (!itac.panesShow()) return;
        try fighters.drawPanes(itac, canvas, fighter);
    }

    /// The panes as they have wiped in: the name, the figures, the armament and the list.
    fn drawPanes(fighters: *Fighters, itac: *Itac, canvas: Canvas, fighter: tables.Fighter) canvas_module.Error!void {
        const font = &(itac.small orelse return).font;
        if (itac.panes[name].showing()) |shown| try itac.writeCapitals(canvas.within(shown), font, line_room, .{ name_pane.x + name_at[0], name_pane.y + name_at[1] }, .{ .string = fighter.name });
        const fighter_bars = fighters.bars[@backingInt(itac.side)][fighters.selected];
        if (itac.panes[figures].showing()) |shown| try writeFigures(itac, .{ .canvas = canvas.within(shown), .font = font, .pane = figures_pane, .value_x = value_x }, fighter, fighter_bars);
        if (itac.panes[armament].showing()) |shown| try writeArmament(itac, .{ .canvas = canvas.within(shown), .font = font, .pane = armament_pane, .value_x = value_x }, fighter, fighter_bars);
        if (itac.panes[list].showing()) |shown| try title_list.write(itac, canvas, shown, fighters.titles[0..sideFighters(itac).len], fighters.listed[0..fighters.listed_count], fighters.selected);
    }
};

/// The figures (`0x00425C49` on): the type, the clearance, which only the Alliance's rows have, and
/// the bars.
fn writeFigures(itac: *Itac, rows: itac_module.Rows, fighter: tables.Fighter, fighter_bars: bars.ShipBars) canvas_module.Error!void {
    try rows.label(rowAt(0), itac.string(type_label));
    try rows.value(rowAt(0), itac.string(fighter.type));
    if (itac.side != .coalition) try rows.label(rowAt(1), itac.string(clearance_label));
    if (fighter.clearance != 0) try rows.value(rowAt(1), itac.string(fighter.clearance));
    const figures_shown = [_]struct { u16, i16 }{
        .{ speed_label, fighter_bars.speed },
        .{ acceleration_label, fighter_bars.acceleration },
        .{ agility_label, fighter_bars.agility },
        .{ shield_label, fighter_bars.shield_power },
        .{ recharge_label, fighter_bars.shield_recharge },
        .{ armor_label, fighter_bars.armor },
    };
    for (figures_shown, first_bar_row..) |figure, row| {
        const label, const value = figure;
        var buffer: [8]u8 = undefined;
        try rows.label(rowAt(row), itac.string(label));
        try rows.value(rowAt(row), std.mem.print(&buffer, "{d}", .{value}) catch "");
    }
}

/// The armament (`0x00426030`): the afterburner's fuel, the guns, the crew, and the special
/// abilities in a paragraph below them.
fn writeArmament(itac: *Itac, rows: itac_module.Rows, fighter: tables.Fighter, fighter_bars: bars.ShipBars) canvas_module.Error!void {
    var buffer: [line_room]u8 = undefined;
    try rows.label(rowAt(0), itac.string(fuel_label));
    try rows.value(rowAt(0), std.mem.print(&buffer, "{d} {s}", .{ fighter_bars.afterburner_fuel, itac.string(seconds) }) catch "");
    try rows.label(rowAt(1), itac.string(armament_label));
    for (fighter.guns, 1..) |gun, row| {
        const text = if (gun.count != 0) std.mem.print(&buffer, "{d} {s}", .{ gun.count, itac.string(gun.name) }) catch "" else itac.string(gun.name);
        try rows.value(rowAt(row), text);
    }
    const crew_row = fighter.guns.len + 1;
    try rows.label(rowAt(crew_row), itac.string(crew_label));
    try rows.value(rowAt(crew_row), std.mem.print(&buffer, "{d}", .{fighter.crew}) catch "");
    if (fighter.specials.len == 0) return;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (fighter.specials, 0..) |special, n| {
        if (n > 0) writer.writeAll(special_separator) catch {};
        writer.writeAll(itac.string(special)) catch {};
    }
    try rows.canvas.wrapped(rows.font, .{ rows.pane.x + specials_x, rows.pane.y + rowAt(crew_row + 1) }, writer.buffered(), itac_module.text_colour, .left, special_lines);
}

/// How far down its pane row `row` stands.
fn rowAt(row: usize) i32 {
    return first_row + row_height * @as(i32, @intCast(row));
}

test rowAt {
    // The rows of the figures, 15 apart: the type at 2, the armor at 107.
    try std.testing.expectEqual(2, rowAt(0));
    try std.testing.expectEqual(107, rowAt(7));
}

test "Fighters.workOutBars" {
    var fighters: Fighters = .{};
    fighters.workOutBars(&create.Stats.initial);
    // With every figure the same, each bar stands at the top of its range.
    try std.testing.expectEqual(10, fighters.bars[0][0].speed);
    try std.testing.expectEqual(10, fighters.bars[1][tables.fighters[1].len - 1].armor);
}

test "the palettes the pictures are drawn with" {
    try std.testing.expectEqual(0, itac_module.paletteBefore(&palette_blocks, 1));
    try std.testing.expectEqual(5, itac_module.paletteBefore(&palette_blocks, 9));
    try std.testing.expectEqual(17, itac_module.paletteBefore(&palette_blocks, 18));
    try std.testing.expectEqual(27, itac_module.paletteBefore(&palette_blocks, 28));
}
