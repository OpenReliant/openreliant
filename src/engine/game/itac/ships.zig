//! The capital ships of either side, the ITAC's fifth section: ALLIANCE SHIPS and COALITION SHIPS
//! (`tables.ships`), each with its picture of `capships.spr`, its figures and its description,
//! chosen from a list. The emblems at the top right choose the side, the Alliance's first.
//!
//! **Unverified:** the file. Its code (`0x00423870` to `0x00424451`) lies after `wgate.cpp`'s known
//! code and before the 3D cursor's (`cursor_create`) and DEBRIEFINGS', where no assertion names a
//! file; it goes with the ITAC, whose section it is.

const std = @import("std");

const canvas_module = @import("../interface/canvas.zig");
const itac_module = @import("../itac.zig");
const language = @import("../language.zig");
const tables = @import("tables.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Itac = itac_module.Itac;
const ScrollBox = itac_module.ScrollBox;

/// The pictures (`0x004E48F0`), which it reads as it opens and lets go of as it is left.
pub const pictures_name = "inter\\itac\\capships.spr";

/// Where the chosen ship's picture stands (`0x00423BBB`), and the blocks of `capships.spr`'s
/// palettes, every third, the last of which before its shape it is drawn with (`0x00423AF4`).
const picture_at: [2]i32 = .{ 57, 234 };
const palette_blocks = [_]usize{ 0, 3, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48, 51, 54 };

/// The buttons that choose the side, the Alliance's and the Coalition's (`0x004E48E0`).
const side_buttons = [2]Rect{ .{ .x = 551, .y = 59, .width = 64, .height = 41 }, .{ .x = 478, .y = 59, .width = 64, .height = 61 } };

/// The panes it writes into (`0x00423CB0`): the name and the figures, the description's heading,
/// the description, and the list.
const figures_pane: Rect = .{ .x = 33, .y = 80, .width = 200, .height = 138 };
const heading_pane: Rect = .{ .x = 255, .y = 81, .width = 215, .height = 24 };
const body_pane: Rect = .{ .x = 255, .y = 103, .width = 207, .height = 88 };
const list_pane: Rect = .{ .x = 474, .y = 140, .width = 146, .height = 220 };
const figures = 0;
const heading = 1;
const body = 2;
const list = 3;

/// The name, in capitals in the headers' colour, and the room its copy has (`0x00423DA9`).
const name_at: [2]i32 = .{ 2, 2 };
const name_room = 52;

/// The figures' rows below the name, from `first_row` and `row_height` apart, their values
/// right-aligned at `value_x`, and the strings of their labels (`0x00423E08` on): Commissioned,
/// Type, Displacement, Propulsion, Spacecraft, Armament and Crew.
const first_row = 24;
const row_height = 15;
const value_x = 199;
const labels = [_]u16{ 0x50E, 0x50F, 0x510, 0x511, 0x512, 0x513, 0x514 };

/// Where PROFILE stands over the description (`0x00424182`).
const profile_at: [2]i32 = .{ 2, 2 };

/// The text box of the description, with its arrows (`0x004E48D0`), where "(more)" hangs from
/// (`0x00423870`).
///
/// **Fix:** the game's second arrow stands at x 349, overlapping the first, which wins where they
/// overlap. So the right 10 pixels of the second arrow light up but don't scroll the text.
/// OpenReliant moves it to x 359, 27 right of the first like the other sections' arrows, where it
/// covers the arrow that lights up.
const body_box: ScrollBox = .{
    .arrows = .{ .{ .x = 332, .y = 204, .width = 27, .height = 27 }, .{ .x = 359, .y = 204, .width = 27, .height = 27 } },
    .rect = .{ .x = 255, .y = 88, .width = 207, .height = 94 },
    .scroll = chosen_scroll,
};

/// Where the description starts scrolled as the section opens, the side changes or a ship is
/// chosen, which the box's next tick brings back to its top (`0x004238B7`).
const chosen_scroll = 0;

/// The list of the side's ships (`0x004242E0`): each name 6 below the last, down to the foot of its
/// pane. Its arrows (`0x004E48C0`) step it on no further than to leave `shown_at_least` showing.
const title_list: itac_module.TitleList = .{ .pane = list_pane, .top = 2, .width = 126, .gap = 6, .bottom = 210, .hotspot_extra = 4 };
const list_arrows = [2]Rect{ .{ .x = 514, .y = 367, .width = 27, .height = 27 }, .{ .x = 541, .y = 367, .width = 27, .height = 27 } };
const shown_at_least = 13;

/// The descriptions of the Reliant and the Yamato, which continue in a second string written right
/// after them (`0x004241F8`, `0x0042425F`).
const reliant_description = 0x578;
const reliant_continuation = 0x78D;
const yamato_description = 0x5A8;
const yamato_continuation = 0x78A;

/// The most ships a side lists.
const most = @max(tables.ships[0].len, tables.ships[1].len);

pub const Ships = struct {
    /// The ship chosen, by its place in the side's list (`0x0051D23C`).
    selected: u8 = 0,
    /// The place of the first shown (`0x0051D238`).
    first: u8 = 0,
    /// Its pictures (`0x0051D264`), and whether it is open (`0x0051D2D8`).
    pictures: itac_module.Pictures = .{},
    box: ScrollBox = body_box,
    /// The strings of the side's ships' names, which the list shows.
    titles: [most]language.Words = undefined,
    /// The entries the list shows, each a hotspot (`0x0051D268`).
    listed: [most]itac_module.ListEntry = undefined,
    listed_count: u8 = 0,
    /// The description, as its build writes it.
    text: [itac_module.text_room]u8 = undefined,
    text_len: usize = 0,

    /// `0x00423870`: the first ship chosen, the list from its start, the description's box set up,
    /// the Alliance's listed (`0x00424410`), and the pictures read.
    pub fn enter(ships: *Ships, itac: *Itac) void {
        ships.selected = 0;
        ships.first = 0;
        ships.box = body_box;
        ships.listSide(itac.side);
        ships.pictures.read(itac.context, pictures_name);
    }

    /// `0x00424410`: the strings of `side`'s ships' names, in the table's order.
    fn listSide(ships: *Ships, side: itac_module.Side) void {
        for (tables.ships[@backingInt(side)], 0..) |ship, place| ships.titles[place] = .{ .string = ship.name };
    }

    /// `0x00423910`: the pictures let go of, where it is open.
    pub fn leave(ships: *Ships, gpa: std.mem.Allocator) void {
        _ = ships.pictures.close(gpa);
    }

    /// `0x00423930`, each pass: a build asked for, the other side chosen by its emblem, another
    /// ship chosen from the list, the list stepped through on either side, and the description
    /// scrolled.
    ///
    /// **Fix:** as another ship is chosen, the game holds the screen still for half a second
    /// (`itac_pause`, `0x00440170`), drawing nothing. OpenReliant shows the ship at once.
    pub fn update(ships: *Ships, itac: *Itac) void {
        if (itac.rebuildDue()) ships.build(itac, true);
        if (itac.sidePressed(&side_buttons)) {
            ships.selected = 0;
            ships.first = 0;
            ships.box.scroll = chosen_scroll;
            ships.listSide(itac.side);
            ships.build(itac, true);
        }
        if (itac.entryChosen(ships.listed[0..ships.listed_count], ships.selected)) |place| {
            ships.selected = place;
            ships.box.scroll = chosen_scroll;
            ships.build(itac, false);
        }
        if (itac.listStepped(&list_arrows, &ships.first, sideShips(itac).len -| shown_at_least)) ships.layOut(itac);
        ships.box.update(itac.ticks, itac.pointer);
    }

    /// The side's ships.
    fn sideShips(itac: *const Itac) []const tables.Ship {
        return tables.ships[@backingInt(itac.side)];
    }

    /// The ship chosen.
    fn chosen(ships: *const Ships, itac: *const Itac) tables.Ship {
        return sideShips(itac)[ships.selected];
    }

    /// `0x00423CB0`: its sound, and for the ship chosen, the description written, the panes of its
    /// heading, of the description and of the name and figures wiping in, and the list laid out;
    /// with `wipe`, the list's pane wiping in too.
    fn build(ships: *Ships, itac: *Itac, wipe: bool) void {
        itac.play(.text, itac_module.full_volume, 1);
        ships.write(itac);
        itac.panes[heading].wipeIn(heading_pane);
        itac.panes[body].wipeIn(body_pane);
        itac.panes[figures].wipeIn(figures_pane);
        ships.layOut(itac);
        if (wipe) itac.panes[list].wipeIn(list_pane);
    }

    /// The description of the ship chosen (`0x00424130`), the Reliant's and the Yamato's with their
    /// continuations.
    fn write(ships: *Ships, itac: *Itac) void {
        const description = ships.chosen(itac).description;
        var writer: std.Io.Writer = .fixed(&ships.text);
        writer.writeAll(itac.string(description)) catch {};
        if (continuation(description)) |more| writer.writeAll(itac.string(more)) catch {};
        ships.text_len = writer.end;
        itac.fitText(&ships.box, ships.bodyText());
    }

    fn bodyText(ships: *const Ships) []const u8 {
        return ships.text[0..ships.text_len];
    }

    /// The list's entries laid out from the first shown, each a hotspot.
    fn layOut(ships: *Ships, itac: *Itac) void {
        ships.listed_count = title_list.layOut(itac, ships.titles[0..sideShips(itac).len], ships.first, &ships.listed);
    }

    /// `0x00423AC0` at `fade`, while it is open: the chosen ship's picture and the side's emblem at
    /// `fade`, its panes while no fade runs, and "(more)" where the description runs past its box.
    pub fn draw(ships: *Ships, itac: *Itac, canvas: Canvas, fade: f32) canvas_module.Error!void {
        if (!ships.pictures.open) return;
        const ship = ships.chosen(itac);
        try ships.pictures.drawWithPalettes(canvas, &palette_blocks, ship.shape, picture_at, fade);
        try itac.drawEmblem(canvas, fade);
        if (!itac.panesShow()) return;
        try ships.drawPanes(itac, canvas, ship);
        try itac.drawMore(canvas, ships.box);
    }

    /// The panes as they have wiped in: the name and the figures, PROFILE, the description, and the
    /// list.
    fn drawPanes(ships: *Ships, itac: *Itac, canvas: Canvas, ship: tables.Ship) canvas_module.Error!void {
        const font = &(itac.small orelse return).font;
        if (itac.panes[figures].showing()) |shown| {
            const in_pane = canvas.within(shown);
            try itac.writeCapitals(in_pane, font, name_room, .{ figures_pane.x + name_at[0], figures_pane.y + name_at[1] }, .{ .string = ship.name });
            const rows: itac_module.Rows = .{ .canvas = in_pane, .font = font, .pane = figures_pane, .value_x = value_x };
            var crew: [8]u8 = undefined;
            const values = [labels.len][]const u8{
                itac.string(ship.commissioned),
                itac.string(ship.type),
                itac.string(ship.displacement),
                itac.string(ship.propulsion),
                itac.string(ship.spacecraft),
                itac.string(ship.armament),
                std.mem.print(&crew, "{d}", .{ship.crew}) catch "",
            };
            for (labels, values, 0..) |label, value, row| {
                const y = first_row + row_height * @as(i32, @intCast(row));
                try rows.label(y, itac.string(label));
                try rows.value(y, value);
            }
        }
        if (itac.panes[heading].showing()) |shown| try itac.writeProfile(canvas, font, heading_pane, shown, profile_at);
        if (itac.panes[body].showing()) |shown| try ships.box.drawText(canvas, font, body_pane, shown, ships.bodyText());
        if (itac.panes[list].showing()) |shown| try title_list.write(itac, canvas, shown, ships.titles[0..sideShips(itac).len], ships.listed[0..ships.listed_count], ships.selected);
    }
};

/// The string that continues the description `description`, if it is the Reliant's or the
/// Yamato's.
fn continuation(description: u16) ?u16 {
    return switch (description) {
        reliant_description => reliant_continuation,
        yamato_description => yamato_continuation,
        else => null,
    };
}

test continuation {
    try std.testing.expectEqual(reliant_continuation, continuation(reliant_description).?);
    try std.testing.expectEqual(yamato_continuation, continuation(yamato_description).?);
    try std.testing.expectEqual(null, continuation(tables.ships[1][0].description));
}

test "the palettes the pictures are drawn with" {
    try std.testing.expectEqual(0, itac_module.paletteBefore(&palette_blocks, 2));
    try std.testing.expectEqual(3, itac_module.paletteBefore(&palette_blocks, 4));
    try std.testing.expectEqual(27, itac_module.paletteBefore(&palette_blocks, 29));
    try std.testing.expectEqual(54, itac_module.paletteBefore(&palette_blocks, 56));
}

test "the description's arrows lie side by side" {
    // Over the right of the second arrow, the text scrolls back; over the first, on.
    try std.testing.expectEqual(1, canvas_module.hit(&body_box.arrows, .{ 380, 215 }).?);
    try std.testing.expectEqual(0, canvas_module.hit(&body_box.arrows, .{ 355, 215 }).?);
}
