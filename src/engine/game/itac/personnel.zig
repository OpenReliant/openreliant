//! The personnel of either side, the ITAC's seventh section: ALLIANCE PERSONNEL and COALITION
//! PERSONNEL (`tables.personnel`), each with their portrait of `persons.spr`, their age,
//! nationality, ship and call sign, and their military history, training and background, chosen
//! from a list. The emblems at the top right choose the side, the Alliance's first.
//!
//! **Unverified:** the file. Its code (`0x0044E4C0` to `0x0044EFFE`) lies after `loadout.cpp`'s last
//! assertion, and the source map gives it to that file by the data its tables lie among
//! (`sources.zig`); it goes with the ITAC, whose section it is, as NEWS REPORTS does.

const std = @import("std");

const canvas_module = @import("../interface/canvas.zig");
const itac_module = @import("../itac.zig");
const language = @import("../language.zig");
const tables = @import("tables.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Itac = itac_module.Itac;
const ScrollBox = itac_module.ScrollBox;

/// The portraits (`0x004EB8E0`), which it reads as it opens and lets go of as it is left.
pub const pictures_name = "inter\\itac\\persons.spr";

/// Where the chosen person's portrait stands (`0x0044E7C4`), and the blocks of `persons.spr`'s
/// palettes, the last of which before the portrait's shape it is drawn with (`0x0044E742`).
const portrait_at: [2]i32 = .{ 296, 76 };
const palette_blocks = [_]usize{ 0, 9, 18, 24, 33, 35 };

/// The buttons that choose the side, the Alliance's and the Coalition's (`0x004EB8B0`).
const side_buttons = [2]Rect{ .{ .x = 551, .y = 59, .width = 64, .height = 41 }, .{ .x = 478, .y = 59, .width = 64, .height = 61 } };

/// The panes it writes into (`0x0044EA50`): the name and the figures, the profile, the list, and
/// the profile's heading.
const figures_pane: Rect = .{ .x = 34, .y = 77, .width = 225, .height = 144 };
const body_pane: Rect = .{ .x = 35, .y = 266, .width = 405, .height = 60 };
const list_pane: Rect = .{ .x = 474, .y = 138, .width = 146, .height = 218 };
const heading_pane: Rect = .{ .x = 35, .y = 244, .width = 405, .height = 22 };
const figures = 0;
const body = 1;
const list = 2;
const heading = 3;

/// The name, in capitals in the headers' colour, where it stands in its pane, and the room its copy
/// has (`0x0044EB2F`).
const name_at: [2]i32 = .{ 2, 2 };
const name_room = 52;

/// The figures' rows (`0x0044E960`): the first at `first_row`, each `row_height` below the last,
/// their values right-aligned at `value_x`, and the strings of their labels. The ship and the call
/// sign show only where the person has them.
const first_row = 27;
const row_height = 26;
const value_x = 224;
const age_label = 0x3DB;
const nationality_label = 0x3DC;
const ship_label = 0x3DD;
const call_sign_label = 0x3DE;

/// Where PROFILE stands over the profile, and the headings of its parts, each on a line of its own
/// above it (`0x0044ED00`).
const profile_at: [2]i32 = .{ 1, 1 };
const part_headings = [_]u16{ 0x3E0, 0x3E1, 0x3E2 };
const below_heading = "\n";

/// The text box of the profile, with its arrows (`0x004EB8C0`), where "(more)" hangs from
/// (`0x0044E520`).
const body_box: ScrollBox = .{
    .arrows = .{ .{ .x = 44, .y = 342, .width = 27, .height = 27 }, .{ .x = 71, .y = 342, .width = 27, .height = 27 } },
    .rect = .{ .x = 35, .y = 258, .width = 405, .height = 60 },
};

/// The list of the side's personnel (`0x0044E830`): each name 6 below the last, down to the foot of
/// its pane. Only the Alliance's, the longer, has arrows (`0x004EB8D0`), which step
/// it on no further than to leave `shown_at_least` showing.
const title_list: itac_module.TitleList = .{ .pane = list_pane, .top = 2, .width = 126, .gap = 6, .bottom = 218, .hotspot_extra = 4 };
const list_arrows = [2]Rect{ .{ .x = 514, .y = 367, .width = 27, .height = 27 }, .{ .x = 541, .y = 367, .width = 27, .height = 27 } };
const shown_at_least = 13;

/// The most personnel a side lists.
const most = @max(tables.personnel[0].len, tables.personnel[1].len);

pub const Personnel = struct {
    /// The person chosen, by their place in the side's list (`0x00524FC8`).
    selected: u8 = 0,
    /// The place of the first shown (`0x00524FC4`), which only choosing the side brings back to
    /// the top.
    first: u8 = 0,
    /// Its portraits (`0x00524E7C`), and whether it is open (`0x00524FD0`).
    pictures: itac_module.Pictures = .{},
    box: ScrollBox = body_box,
    /// The strings of the side's personnel's names, which the list shows.
    titles: [most]language.Words = undefined,
    /// The entries the list shows, each a hotspot (`0x00524E80`).
    listed: [most]itac_module.ListEntry = undefined,
    listed_count: u8 = 0,
    /// The profile, as its build writes it.
    text: [itac_module.text_room]u8 = undefined,
    text_len: usize = 0,

    /// `0x0044E4C0`: the first person chosen, the side's listed (`0x0044E9F0`), and the portraits
    /// read.
    pub fn enter(people: *Personnel, itac: *Itac) void {
        people.selected = 0;
        people.listSide(itac.side);
        people.pictures.read(itac.context, pictures_name);
    }

    /// The strings of `side`'s personnel's names, in the table's order (`0x0044E9F0`).
    fn listSide(people: *Personnel, side: itac_module.Side) void {
        for (tables.personnel[@backingInt(side)], 0..) |person, place| people.titles[place] = .{ .string = person.name };
    }

    /// `0x0044E500`: the portraits let go of, where it is open.
    pub fn leave(people: *Personnel, gpa: std.mem.Allocator) void {
        _ = people.pictures.close(gpa);
    }

    /// `0x0044E520`: the profile's box at its top, built on the next update, the panes hidden.
    pub fn loaded(people: *Personnel, itac: *Itac) void {
        people.box = body_box;
        itac.rebuildSection();
    }

    /// `0x0044E590`, each pass: a build asked for, the other side chosen by its emblem, another
    /// person chosen from the list, the Alliance's list stepped through, and the profile scrolled.
    ///
    /// **Fix:** as another person is chosen, the game holds the screen still for half a second
    /// (`itac_pause`, `0x00440170`), drawing nothing. OpenReliant shows the person at once.
    pub fn update(people: *Personnel, itac: *Itac) void {
        if (itac.rebuildDue()) people.build(itac, true);
        if (itac.sidePressed(&side_buttons)) {
            people.first = 0;
            people.selected = 0;
            people.listSide(itac.side);
            people.build(itac, true);
        }
        if (itac.entryChosen(people.listed[0..people.listed_count], people.selected)) |place| {
            people.selected = place;
            people.box.scroll = ScrollBox.top;
            people.build(itac, false);
        }
        if (itac.side == .alliance and itac.listStepped(&list_arrows, &people.first, sidePeople(itac).len -| shown_at_least)) people.layOut(itac);
        people.box.update(itac.ticks, itac.pointer);
    }

    /// The side's personnel.
    fn sidePeople(itac: *const Itac) []const tables.Person {
        return tables.personnel[@backingInt(itac.side)];
    }

    /// `0x0044EA50`: its sound, and for the person chosen, the profile written, the list laid out,
    /// and the panes of the name and figures, the profile and its heading wiping in; with `wipe`,
    /// the list's too.
    fn build(people: *Personnel, itac: *Itac, wipe: bool) void {
        itac.play(.text, itac_module.full_volume, 1);
        people.write(itac);
        itac.panes[figures].wipeIn(figures_pane);
        itac.panes[body].wipeIn(body_pane);
        itac.panes[heading].wipeIn(heading_pane);
        people.layOut(itac);
        if (wipe) itac.panes[list].wipeIn(list_pane);
    }

    /// The profile of the person chosen (`0x0044ED00`): each part's heading on a line of its own
    /// above it, a blank line between two parts.
    fn write(people: *Personnel, itac: *Itac) void {
        const person = sidePeople(itac)[people.selected];
        const parts = [part_headings.len]u16{ person.history, person.training, person.background };
        var writer: std.Io.Writer = .fixed(&people.text);
        for (part_headings, parts, 0..) |part_heading, part, n| {
            if (n > 0) writer.writeAll(itac_module.between) catch {};
            writer.writeAll(itac.string(part_heading)) catch {};
            writer.writeAll(below_heading) catch {};
            writer.writeAll(itac.string(part)) catch {};
        }
        people.text_len = writer.end;
        itac.fitText(&people.box, people.bodyText());
    }

    fn bodyText(people: *const Personnel) []const u8 {
        return people.text[0..people.text_len];
    }

    /// The list's entries laid out from the first shown, each a hotspot.
    fn layOut(people: *Personnel, itac: *Itac) void {
        people.listed_count = title_list.layOut(itac, people.titles[0..sidePeople(itac).len], people.first, &people.listed);
    }

    /// `0x0044E720` at `fade`, while it is open: the chosen person's portrait and the side's emblem
    /// at `fade`, its panes while no fade runs, and "(more)" where the profile runs past its box.
    ///
    /// **Fix:** a portrait past shape 41, which `persons.spr` doesn't hold, takes its palette's block
    /// from the bits of the fade. OpenReliant draws it with the last palette's.
    pub fn draw(people: *Personnel, itac: *Itac, canvas: Canvas, fade: f32) canvas_module.Error!void {
        if (!people.pictures.open) return;
        const person = sidePeople(itac)[people.selected];
        const shape: usize = @intCast(person.shape);
        try people.pictures.draw(canvas, itac_module.paletteBefore(&palette_blocks, shape), shape, portrait_at, fade);
        try itac.drawEmblem(canvas, fade);
        if (!itac.panesShow()) return;
        try people.drawPanes(itac, canvas, person);
        try itac.drawMore(canvas, people.box);
    }

    /// The panes as they have wiped in: the name and the figures, the profile and its heading, and
    /// the list.
    fn drawPanes(people: *Personnel, itac: *Itac, canvas: Canvas, person: tables.Person) canvas_module.Error!void {
        const font = &(itac.small orelse return).font;
        if (itac.panes[figures].showing()) |shown| {
            const in_pane = canvas.within(shown);
            try itac.writeCapitals(in_pane, font, name_room, .{ figures_pane.x + name_at[0], figures_pane.y + name_at[1] }, .{ .string = person.name });
            const rows: itac_module.Rows = .{ .canvas = in_pane, .font = font, .pane = figures_pane, .value_x = value_x };
            var y: i32 = first_row;
            for ([_]struct { u16, u16, bool }{
                .{ age_label, person.age, false },
                .{ nationality_label, person.nationality, false },
                .{ ship_label, person.ship, true },
                .{ call_sign_label, person.call_sign, true },
            }) |row| {
                const label, const value, const optional = row;
                if (optional and value == 0) continue;
                try rows.label(y, itac.string(label));
                try rows.value(y, itac.string(value));
                y += row_height;
            }
        }
        if (itac.panes[heading].showing()) |shown| try itac.writeProfile(canvas, font, heading_pane, shown, profile_at);
        if (itac.panes[body].showing()) |shown| try people.box.drawText(canvas, font, body_pane, shown, people.bodyText());
        if (itac.panes[list].showing()) |shown| try title_list.write(itac, canvas, shown, people.titles[0..sidePeople(itac).len], people.listed[0..people.listed_count], people.selected);
    }
};

test "the palettes the portraits are drawn with" {
    try std.testing.expectEqual(0, itac_module.paletteBefore(&palette_blocks, 8));
    try std.testing.expectEqual(9, itac_module.paletteBefore(&palette_blocks, 17));
    try std.testing.expectEqual(33, itac_module.paletteBefore(&palette_blocks, 34));
    try std.testing.expectEqual(35, itac_module.paletteBefore(&palette_blocks, 41));
}

test "Personnel.listSide" {
    var people: Personnel = .{};
    people.listSide(.coalition);
    try std.testing.expectEqual(tables.personnel[1][0].name, people.titles[0].string);
}
