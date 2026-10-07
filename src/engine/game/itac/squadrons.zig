//! The squadrons of either side, the ITAC's sixth section: ALLIANCE SQUADRONS and COALITION
//! SQUADRONS (`tables.squadrons`), each with its picture of `squads.spr`, its class, leader, base
//! and nation, and its history, chosen from a list. The emblems at the top right choose the side,
//! the Alliance's first. The Alliance's list follows the campaign: the 45th Volunteers become the
//! 45th Flying Tigers from mission 13, and the 51st Volunteers leave it after mission 9.
//!
//! **Unverified:** the file. Its code (`0x0044FAA0` to `0x004504BC`) lies after `loadout.cpp`'s last
//! assertion, and the source map gives it to that file by the data its tables lie among
//! (`sources.zig`); it goes with the ITAC, whose section it is, as NEWS REPORTS does.

const std = @import("std");

const canvas_module = @import("../interface/canvas.zig");
const itac_module = @import("../itac.zig");
const tables = @import("tables.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Itac = itac_module.Itac;
const ScrollBox = itac_module.ScrollBox;

/// The pictures (`0x004EC008`), which it reads as it opens and lets go of as it is left.
pub const pictures_name = "inter\\itac\\squads.spr";

/// Where the chosen squadron's picture stands, drawn with the palette its record names
/// (`0x0044FD59`).
const picture_at: [2]i32 = .{ 80, 263 };

/// The buttons that choose the side, the Alliance's and the Coalition's (`0x004EBD00`).
const side_buttons = [2]Rect{ .{ .x = 550, .y = 61, .width = 60, .height = 60 }, .{ .x = 480, .y = 61, .width = 60, .height = 60 } };

/// The panes it writes into (`0x0044FDE0`): the name and the figures, the history, its heading,
/// and the list.
const figures_pane: Rect = .{ .x = 32, .y = 79, .width = 185, .height = 140 };
const body_pane: Rect = .{ .x = 235, .y = 101, .width = 229, .height = 103 };
const heading_pane: Rect = .{ .x = 235, .y = 80, .width = 229, .height = 15 };
const list_pane: Rect = .{ .x = 472, .y = 136, .width = 147, .height = 223 };
const figures = 0;
const body = 1;
const heading = 2;
const list = 3;

/// The name, in capitals in the headers' colour, broken into lines `name_lines` from the top of
/// its pane, and the room its copy has (`0x0044FECE`).
const name_at: [2]i32 = .{ 2, 2 };
const name_lines: Canvas.Lines = .{ .width = 181, .height = 11, .most = 20 };
const name_room = 52;

/// The figures' rows below the name: the first a blank line below its last, each `row_height` below
/// the last, their values right-aligned at `value_x`, and the strings of their labels (`0x0044FED3`
/// on).
const below_name = name_lines.height;
const row_height = 28;
const value_x = 177;
const labels = [_]u16{ 0x3C, 0x8F, 0x90, 0x20D };

/// PROFILE, over the history (`0x00450201`).
const heading_string = 0x87;
const heading_at: [2]i32 = .{ 2, 2 };

/// The text box of the history, with its arrows (`0x004EBCF0`), where "(more)" hangs from
/// (`0x0044FAA0`).
const body_box: ScrollBox = .{
    .arrows = .{ .{ .x = 325, .y = 215, .width = 27, .height = 27 }, .{ .x = 352, .y = 215, .width = 27, .height = 27 } },
    .rect = .{ .x = 235, .y = 82, .width = 229, .height = 116 },
};

/// Where a squadron chosen starts its history scrolled, which the box's next tick brings back to its
/// top (`0x0044FBD0`).
const chosen_scroll = 0;

/// The list of the side's squadrons (`0x00450310`): each name 6 below the last, down to the foot of
/// its pane. Only the Alliance's, the longer, has arrows (`0x004EBCE0`), which step it on no further
/// than to leave `shown_at_least` showing.
const title_list: itac_module.TitleList = .{ .pane = list_pane, .top = 2, .width = 126, .gap = 6, .bottom = 220, .hotspot_x = 472, .hotspot_width = 147, .hotspot_extra = 4 };
const list_arrows = [2]Rect{ .{ .x = 515, .y = 367, .width = 27, .height = 27 }, .{ .x = 542, .y = 367, .width = 27, .height = 27 } };
const shown_at_least = 13;

/// The squadrons the Alliance's list shows only before, from or up to a mission (`0x00450450`), and
/// the squadron whose history tells of the inquiry after mission 6, and that part's string
/// (`0x00450235`).
const volunteers = 0x1C8;
const flying_tigers = 0x1C9;
const renamed_from = 13;
const fifty_first = 0x1CB;
const fifty_first_last = 9;
const cobras = 0x1D0;
const inquiry_after = 6;
const inquiry = 0x218;

/// The most squadrons a side lists.
const most = @max(tables.squadrons[0].len, tables.squadrons[1].len);

pub const Squadrons = struct {
    /// The squadrons listed, by their places in the side's table (`0x0052505C`), and the strings of
    /// their names.
    items: [most]u8 = undefined,
    titles: [most]u16 = undefined,
    item_count: u8 = 0,
    /// The squadron chosen, by its place in the list (`0x00525100`).
    selected: u8 = 0,
    /// The place of the first shown (`0x00525028`).
    first: u8 = 0,
    /// Its pictures (`0x0052502C`), and whether it is open (`0x00525104`).
    pictures: itac_module.Pictures = .{},
    box: ScrollBox = body_box,
    /// The entries the list shows, each a hotspot (`0x00525060`).
    listed: [most]itac_module.ListEntry = undefined,
    listed_count: u8 = 0,
    /// The history, as its build writes it.
    text: [itac_module.text_room]u8 = undefined,
    text_len: usize = 0,

    /// `0x0044FAA0`: the first squadron chosen, the list from its start, the history's box at its
    /// top, the Alliance's listed (`0x00450440`), and the pictures read.
    pub fn enter(squadrons: *Squadrons, itac: *Itac) void {
        squadrons.box = body_box;
        squadrons.selected = 0;
        squadrons.first = 0;
        squadrons.listSide(itac.side, itac.pilot.mission);
        squadrons.pictures.read(itac.context, pictures_name);
    }

    /// `0x00450440`: `side`'s squadrons, in the table's order, the Alliance's as the campaign has
    /// them before `mission`.
    fn listSide(squadrons: *Squadrons, side: itac_module.Side, mission: u16) void {
        squadrons.item_count = 0;
        for (tables.squadrons[@backingInt(side)], 0..) |squadron, place| {
            if (side == .alliance and !listedBefore(squadron.name, mission)) continue;
            squadrons.items[squadrons.item_count] = @intCast(place);
            squadrons.titles[squadrons.item_count] = squadron.name;
            squadrons.item_count += 1;
        }
    }

    /// `0x0044FB40`: the pictures let go of, where it is open.
    pub fn leave(squadrons: *Squadrons, gpa: std.mem.Allocator) void {
        _ = squadrons.pictures.close(gpa);
    }

    /// `0x0044FB60`: the Alliance's shown, built on the next update, the panes hidden.
    pub fn loaded(squadrons: *Squadrons, itac: *Itac) void {
        _ = squadrons;
        itac.side = .alliance;
        itac.rebuildSection();
    }

    /// `0x0044FB80`, each pass: a build asked for, another squadron chosen from the list, the
    /// Alliance's list stepped through, the other side chosen by its emblem, and the history
    /// scrolled.
    ///
    /// **Fix:** as another squadron is chosen, the game holds the screen still for half a second
    /// (`itac_pause`, `0x00440170`), drawing nothing. OpenReliant shows the squadron at once.
    pub fn update(squadrons: *Squadrons, itac: *Itac) void {
        if (itac.rebuildDue()) squadrons.build(itac, true);
        if (itac.entryChosen(squadrons.listed[0..squadrons.listed_count], squadrons.selected)) |place| {
            squadrons.selected = place;
            squadrons.box.scroll = chosen_scroll;
            squadrons.build(itac, false);
        }
        if (itac.side == .alliance) if (itac.arrowPressed(&list_arrows)) |arrow| {
            if (arrow == 0) {
                squadrons.first = @min(squadrons.first + 1, squadrons.item_count -| shown_at_least);
            } else {
                squadrons.first -|= 1;
            }
            squadrons.layOut(itac);
        };
        if (itac.sidePressed(&side_buttons)) {
            squadrons.selected = 0;
            squadrons.first = 0;
            squadrons.box.scroll = chosen_scroll;
            squadrons.listSide(itac.side, itac.pilot.mission);
            squadrons.build(itac, true);
        }
        squadrons.box.update(itac.ticks, itac.pointer);
    }

    /// The squadron chosen.
    fn chosen(squadrons: *const Squadrons, itac: *const Itac) tables.Squadron {
        return tables.squadrons[@backingInt(itac.side)][squadrons.items[squadrons.selected]];
    }

    /// `0x0044FDE0`: its sound, and for the squadron chosen, the history written, the list laid
    /// out, and the panes of the name and figures, the history and its heading wiping in; with
    /// `wipe`, the list's too.
    fn build(squadrons: *Squadrons, itac: *Itac, wipe: bool) void {
        itac.play(.text, itac_module.full_volume, 1);
        squadrons.write(itac);
        squadrons.layOut(itac);
        itac.panes[figures].wipeIn(figures_pane);
        itac.panes[body].wipeIn(body_pane);
        itac.panes[heading].wipeIn(heading_pane);
        if (wipe) itac.panes[list].wipeIn(list_pane);
    }

    /// The history of the squadron chosen (`0x00450180`), and after mission 6, for the 705 Cobras,
    /// the inquiry into their colonel.
    fn write(squadrons: *Squadrons, itac: *Itac) void {
        const squadron = squadrons.chosen(itac);
        const told: []const u16 = if (squadron.name == cobras and itac.pilot.mission > inquiry_after) &.{ squadron.text, inquiry } else &.{squadron.text};
        squadrons.text_len = itac.writeParagraphs(&squadrons.text, told, &squadrons.box);
    }

    fn bodyText(squadrons: *const Squadrons) []const u8 {
        return squadrons.text[0..squadrons.text_len];
    }

    /// The list's entries laid out from the first shown, each a hotspot.
    fn layOut(squadrons: *Squadrons, itac: *Itac) void {
        squadrons.listed_count = title_list.layOut(itac, squadrons.titles[0..squadrons.item_count], squadrons.first, &squadrons.listed);
    }

    /// `0x0044FD10` at `fade`, while it is open: the chosen squadron's picture and the side's emblem
    /// at `fade`, its panes while no fade runs, and "(more)" where the history runs past its box.
    ///
    /// **Fix:** the game draws the picture of the record at the chosen squadron's place in the whole
    /// table, so that past a squadron the Alliance's list leaves out, each shows the picture of one
    /// before it. OpenReliant draws the chosen squadron's.
    pub fn draw(squadrons: *Squadrons, itac: *Itac, canvas: Canvas, fade: f32) canvas_module.Error!void {
        if (!squadrons.pictures.open) return;
        const squadron = squadrons.chosen(itac);
        try squadrons.pictures.draw(canvas, @intCast(squadron.palette), @intCast(squadron.shape), picture_at, fade);
        try itac.drawEmblem(canvas, fade);
        if (!itac.panesShow()) return;
        try squadrons.drawPanes(itac, canvas, squadron);
        try itac.drawMore(canvas, squadrons.box);
    }

    /// The panes as they have wiped in: the name and the figures, the history and its heading, and
    /// the list.
    fn drawPanes(squadrons: *Squadrons, itac: *Itac, canvas: Canvas, squadron: tables.Squadron) canvas_module.Error!void {
        const font = &(itac.small orelse return).font;
        if (itac.panes[figures].showing()) |shown| {
            const in_pane = canvas.within(shown);
            var buffer: [name_room]u8 = undefined;
            const capitals = itac_module.capitals(&buffer, itac.string(squadron.name));
            try in_pane.wrapped(font, .{ figures_pane.x + name_at[0], figures_pane.y + name_at[1] }, capitals, itac_module.header_colour, .left, name_lines);
            const top = name_at[1] + below_name + @as(i32, @intCast(name_lines.count(font, capitals))) * name_lines.height;
            const rows: itac_module.Rows = .{ .canvas = in_pane, .font = font, .pane = figures_pane, .value_x = value_x };
            const values = [labels.len]u16{ squadron.class, squadron.leader, squadron.base, squadron.nation };
            for (labels, values, 0..) |label, value, row| {
                const y = top + row_height * @as(i32, @intCast(row));
                try rows.label(y, itac.string(label));
                try rows.value(y, itac.string(value));
            }
        }
        if (itac.panes[heading].showing()) |shown| try canvas.within(shown).text(font, .{ heading_pane.x + heading_at[0], heading_pane.y + heading_at[1] }, itac.string(heading_string), itac_module.label_colour, .left);
        if (itac.panes[body].showing()) |shown| try squadrons.box.drawText(canvas, font, body_pane, shown, squadrons.bodyText());
        if (itac.panes[list].showing()) |shown| try title_list.write(itac, canvas, shown, squadrons.titles[0..squadrons.item_count], squadrons.listed[0..squadrons.listed_count], squadrons.selected);
    }
};

/// Whether the Alliance's list shows the squadron named `name` before mission `mission`.
fn listedBefore(name: u16, mission: u16) bool {
    return switch (name) {
        volunteers => mission < renamed_from,
        flying_tigers => mission >= renamed_from,
        fifty_first => mission <= fifty_first_last,
        else => true,
    };
}

test "the Alliance's squadrons follow the campaign" {
    var squadrons: Squadrons = .{};
    // Before mission 9, the 45th Volunteers and the 51st Volunteers, but not the Flying Tigers.
    squadrons.listSide(.alliance, 9);
    try std.testing.expectEqual(tables.squadrons[0].len - 1, squadrons.item_count);
    // From mission 13, the Flying Tigers in place of the Volunteers, and no 51st.
    squadrons.listSide(.alliance, 13);
    try std.testing.expectEqual(tables.squadrons[0].len - 2, squadrons.item_count);
    for (squadrons.titles[0..squadrons.item_count]) |title| {
        try std.testing.expect(title != volunteers and title != fifty_first);
    }
    // The Coalition's, all of them.
    squadrons.listSide(.coalition, 13);
    try std.testing.expectEqual(tables.squadrons[1].len, squadrons.item_count);
}
