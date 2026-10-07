//! NEWS REPORTS, the ITAC's second section, which Use ITAC opens first: the news of the war after
//! each mission the campaign has come through (`tables.news`), each with its title, a few
//! paragraphs and a picture of `newsrep.spr`, chosen from a list. The latest is chosen as it opens.
//!
//! **Unverified:** the file. Its code (`0x0044DD90` to `0x0044E4BF`) lies after `loadout.cpp`'s
//! last assertion (`0x0044AC83`) and before VIDEO REPORTS', where no assertion names a file; it
//! goes with the ITAC, whose section it is.

const std = @import("std");

const canvas_module = @import("../interface/canvas.zig");
const language = @import("../language.zig");
const itac_module = @import("../itac.zig");
const tables = @import("tables.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Itac = itac_module.Itac;
const ScrollBox = itac_module.ScrollBox;

/// The pictures (`0x004EB418`), which it reads as it opens and lets go of as it is left.
pub const pictures_name = "inter\\itac\\newsrep.spr";

/// Where the chosen item's picture stands (`0x0044E03D`), and the palette it is drawn with, by the
/// item's place in the list (`0x0044DFF2`): block 0 up to `second_palette_from`, block 13 up to
/// `third_palette_from`, and block 26 past it.
const picture_at: [2]i32 = .{ 302, 100 };
const second_palette_from = 11;
const third_palette_from = 20;
const palettes = [3]usize{ 0, 13, 26 };

/// The panes it writes into, as it builds (`news_build`, `0x0044E0A0`): the title, the body and
/// the list.
const title_pane: Rect = .{ .x = 34, .y = 77, .width = 255, .height = 20 };
const body_pane: Rect = .{ .x = 34, .y = 101, .width = 258, .height = 210 };
const list_pane: Rect = .{ .x = 470, .y = 101, .width = 150, .height = 256 };
const title = 0;
const body = 1;
const list = 2;

/// The title, in capitals (`CharUpperBuffA`, `language.upperCase`) in the headers' colour, where it
/// stands in its pane (`0x0044E15A`), and the room its copy has (`0x0044E0A0`).
const title_at: [2]i32 = .{ 2, 2 };
const title_room = 60;

/// The text box of the body, with its arrows (`0x004EB408`), where "(more)" hangs from
/// (`news_enter`, `0x0044DD90`).
const body_box: ScrollBox = .{
    .arrows = .{ .{ .x = 45, .y = 327, .width = 25, .height = 25 }, .{ .x = 70, .y = 327, .width = 25, .height = 25 } },
    .rect = .{ .x = 34, .y = 91, .width = 258, .height = 210 },
};

/// The list of the items (`news_list_draw`, `0x0044E370`): each title broken into lines of at most
/// `entry_width`, `entry_line` apart, from `entry_x` across in the pane, a blank line below the
/// last, at most `most_listed` of them from the first shown; the chosen in the headers' colour.
/// Each is a hotspot `hotspot_width` wide from `hotspot_x` across and `hotspot_below` further down
/// than its text, as tall as its lines. Its arrows (`0x004EB3E8`) step through it.
const entry_x = 10;
const entry_width = 134;
const entry_line = 11;
const entry_most_lines = 20;
const hotspot_x = 474;
const hotspot_below = 3;
const hotspot_width = 140;
const most_listed = 12;
const list_arrows = [2]Rect{ .{ .x = 515, .y = 368, .width = 25, .height = 25 }, .{ .x = 540, .y = 368, .width = 25, .height = 25 } };

pub const NewsReports = struct {
    /// The items listed, by their places in `tables.news` (`news_list`, `0x00524E40`).
    items: [tables.news.len]u8 = undefined,
    item_count: u8 = 0,
    /// The item chosen, by its place in the list (`news_selected`, `0x00524D78`); none where none
    /// is listed.
    selected: ?u8 = null,
    /// The place of the first shown (`news_list_first`, `0x00524E70`).
    first: u8 = 0,
    /// Whether it is open, its pictures read (`news_open`, `0x00524E74`), and its pictures
    /// (`news_pictures`, `0x00524E6C`).
    open: bool = false,
    pictures: ?canvas_module.Shapes = null,
    /// Whether it builds its panes on its next update (`itac_rebuild`, `0x0052032C`).
    rebuild: bool = false,
    box: ScrollBox = body_box,
    /// The entries the list shows, each a hotspot (`news_hotspots`, `0x00524D80`).
    listed: [most_listed]itac_module.ListEntry = undefined,
    listed_count: u8 = 0,
    /// The body, as its build writes it.
    text: [itac_module.text_room]u8 = undefined,
    text_len: usize = 0,

    /// `news_enter` (`0x0044DD90`): the items listed, the pictures read, the latest chosen, the list
    /// stepped on as far as it goes, and the body's box at its top.
    pub fn enter(news: *NewsReports, itac: *Itac) void {
        news.listItems(itac.pilot.mission);
        news.box = body_box;
        news.pictures = canvas_module.Shapes.read(itac.context.rooms.gpa, itac.context.rooms.resources, pictures_name);
        news.selected = std.math.sub(u8, news.item_count, 1) catch null;
        news.first = news.lastFirst();
        news.layOut(itac);
        news.rebuild = true;
        news.open = true;
    }

    /// `news_list_build` (`0x0044E490`): the items whose missions come before `mission`, the one
    /// the campaign has come to, in the table's order.
    fn listItems(news: *NewsReports, mission: u16) void {
        news.item_count = 0;
        for (tables.news, 0..) |item, index| {
            if (item.mission >= mission) continue;
            news.items[news.item_count] = @intCast(index);
            news.item_count += 1;
        }
    }

    /// The furthest the list steps on, with its last item at the foot of those shown
    /// (`news_list_next`, `0x0044DF90`).
    fn lastFirst(news: NewsReports) u8 {
        return news.item_count -| most_listed;
    }

    /// `news_leave` (`0x0044DE50`): the pictures let go of, where it is open.
    pub fn leave(news: *NewsReports, gpa: std.mem.Allocator) void {
        if (!news.open) return;
        if (news.pictures) |*pictures| pictures.deinit(gpa);
        news.pictures = null;
        news.rebuild = true;
        news.open = false;
    }

    /// The handler the most of the sections share as they are loaded (`itac_section_rebuild`,
    /// `0x0044DE90`): built on the next update, the panes hidden.
    pub fn loaded(news: *NewsReports, itac: *Itac) void {
        news.rebuild = true;
        itac.panes = @splat(.{});
    }

    /// `news_update` (`0x0044DEA0`), each pass: a build asked for, another item chosen from the
    /// list, the list stepped through, and the body scrolled.
    ///
    /// **Fix:** as another item is chosen, the game holds the screen still for half a second
    /// (`itac_pause`, `0x00440170`), drawing nothing. OpenReliant shows the item at once.
    pub fn update(news: *NewsReports, itac: *Itac) void {
        if (news.rebuild) {
            news.build(itac, true);
            news.rebuild = false;
        }
        if (itac.left) if (itac_module.entryAt(news.listed[0..news.listed_count], itac.pointer.at)) |place| if (news.selected != place) {
            news.selected = place;
            news.box.scroll = ScrollBox.top;
            news.build(itac, false);
        };
        if (itac.left) if (canvas_module.hit(&list_arrows, itac.pointer.at)) |arrow| if (itac.repeat.fires(itac.left_held)) {
            if (arrow == 0) {
                news.first = @min(news.first + 1, news.lastFirst());
            } else {
                news.first -|= 1;
            }
            news.layOut(itac);
        };
        news.box.update(itac.ticks, itac.pointer);
    }

    /// The item chosen; none where none is listed.
    fn chosen(news: NewsReports) ?tables.NewsItem {
        const place = news.selected orelse return null;
        return tables.news[news.items[place]];
    }

    /// `news_build` (`0x0044E0A0`): its sound, and for the item chosen, the body written, the list
    /// laid out, and the title's and the body's panes wiping in; with `wipe`, the list's too.
    fn build(news: *NewsReports, itac: *Itac, wipe: bool) void {
        itac.play(.text, itac_module.full_volume, 1);
        const item = news.chosen() orelse return;
        news.write(itac, item);
        news.layOut(itac);
        itac.panes[title].wipeIn(title_pane);
        itac.panes[body].wipeIn(body_pane);
        if (wipe) itac.panes[list].wipeIn(list_pane);
    }

    /// The body of `item` (`news_text_draw`, `0x0044E260`): its paragraphs, a blank line between
    /// each two.
    fn write(news: *NewsReports, itac: *Itac, item: tables.NewsItem) void {
        var writer: std.Io.Writer = .fixed(&news.text);
        for (item.paragraphs, 0..) |id, n| {
            if (n > 0) writer.writeAll(itac_module.between) catch {};
            writer.writeAll(itac.string(id)) catch {};
        }
        news.text_len = writer.end;
        const font = &(itac.small orelse return).font;
        news.box.reach(news.box.lines().count(font, news.bodyText()));
    }

    fn bodyText(news: *const NewsReports) []const u8 {
        return news.text[0..news.text_len];
    }

    /// The list's entries laid out from the first shown, as its drawing lays them out, each a
    /// hotspot.
    fn layOut(news: *NewsReports, itac: *Itac) void {
        news.listed_count = 0;
        const font = &(itac.small orelse return).font;
        var y: i32 = 0;
        var place = news.first;
        while (place < news.item_count and news.listed_count < most_listed) : (place += 1) {
            const item = tables.news[news.items[place]];
            const lines: i32 = @intCast(entryLines().count(font, itac.string(item.title)));
            news.listed[news.listed_count] = .{ .place = place, .top = y, .rect = .{
                .x = hotspot_x,
                .y = @intCast(list_pane.y + y + hotspot_below),
                .width = hotspot_width,
                .height = @intCast(lines * entry_line),
            } };
            news.listed_count += 1;
            y += (lines + 1) * entry_line;
        }
    }

    /// `news_draw` (`0x0044DFE0`) at `fade`, while it is open: the chosen item's picture at `fade`,
    /// its panes while no fade runs, and "(more)" where the body runs past its box.
    ///
    /// **Fix:** with no item listed, the game draws the picture of the record before its table's
    /// first; OpenReliant draws none.
    pub fn draw(news: *NewsReports, itac: *Itac, canvas: Canvas, fade: f32) canvas_module.Error!void {
        if (!news.open) return;
        const place = news.selected orelse return;
        if (news.pictures) |*pictures| {
            pictures.usePalette(paletteOf(place));
            var faded = canvas;
            faded.brightness = @min(fade, 1);
            try faded.shape(&pictures.art, news.chosen().?.shape, picture_at);
        }
        if (!itac.panesShow()) return;
        try news.drawPanes(itac, canvas);
        if (!itac.frozen and news.box.more(itac.panes[title].wiping != 0)) try itac.drawMore(canvas, news.box);
    }

    /// The panes as they have wiped in: the title, the body as far as it is scrolled, and the list.
    fn drawPanes(news: *NewsReports, itac: *Itac, canvas: Canvas) canvas_module.Error!void {
        const small = &(itac.small orelse return).font;
        const item = news.chosen() orelse return;
        if (itac.panes[title].showing()) |shown| {
            var buffer: [title_room]u8 = undefined;
            try canvas.within(shown).text(small, .{ title_pane.x + title_at[0], title_pane.y + title_at[1] }, capitals(&buffer, itac.string(item.title)), itac_module.header_colour, .left);
        }
        if (itac.panes[body].showing()) |shown| try news.box.drawText(canvas, small, body_pane, shown, news.bodyText());
        if (itac.panes[list].showing()) |shown| {
            const in_pane = canvas.within(shown);
            for (news.listed[0..news.listed_count]) |entry| {
                const colour = if (news.selected == entry.place) itac_module.header_colour else itac_module.text_colour;
                const listed_title = itac.string(tables.news[news.items[entry.place]].title);
                try in_pane.wrapped(small, .{ list_pane.x + entry_x, list_pane.y + entry.top }, listed_title, colour, .left, entryLines());
            }
        }
    }
};

/// The palette the picture of the item at `place` in the list is drawn with.
fn paletteOf(place: u8) usize {
    if (place < second_palette_from) return palettes[0];
    if (place < third_palette_from) return palettes[1];
    return palettes[2];
}

/// `text` in capitals, in `buffer`.
///
/// **Fix:** the game copies a title into its room whatever its length; OpenReliant keeps what fits.
fn capitals(buffer: *[title_room]u8, text: []const u8) []const u8 {
    const kept = buffer[0..@min(text.len, title_room - 1)];
    @memcpy(kept, text[0..kept.len]);
    language.upperCase(kept);
    return kept;
}

/// How a list's entry breaks into lines.
fn entryLines() Canvas.Lines {
    return .{ .width = entry_width, .height = entry_line, .most = entry_most_lines };
}

test paletteOf {
    try std.testing.expectEqual(0, paletteOf(0));
    try std.testing.expectEqual(0, paletteOf(10));
    try std.testing.expectEqual(13, paletteOf(11));
    try std.testing.expectEqual(26, paletteOf(20));
}

test capitals {
    var buffer: [title_room]u8 = undefined;
    try std.testing.expectEqualStrings("CONVOY HIT", capitals(&buffer, "Convoy hit"));
    // A title too long for the room keeps what fits.
    try std.testing.expectEqual(title_room - 1, capitals(&buffer, &@as([80]u8, @splat('a'))).len);
}

test "NewsReports.listItems" {
    var news: NewsReports = .{};
    // Before mission 1, the first item alone; before mission 14, those of missions 0 to 13, the
    // campaign having none after missions 11 and 12.
    news.listItems(1);
    try std.testing.expectEqual(1, news.item_count);
    news.listItems(14);
    try std.testing.expectEqual(12, news.item_count);
    try std.testing.expectEqual(13, tables.news[news.items[11]].mission);
    // The list steps on so that the latest shows at its foot.
    news.listItems(28);
    try std.testing.expectEqual(news.item_count - most_listed, news.lastFirst());
}
