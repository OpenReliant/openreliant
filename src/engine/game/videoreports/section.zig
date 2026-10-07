//! VIDEO REPORTS, the ITAC's third section (`itac`): the war's video reports from the missions the
//! campaign has come through (`tables.videos`), each with its title, two paragraphs and a still of
//! `vidrep.spr`, chosen from a list. The play button plays the chosen report's movie from its
//! disc's archive. The first report is chosen as it opens.
//!
//! `C:\lancer\game\videoreports.cpp` holds it: `video_reports_draw` names the file's path
//! (`0x004EE7B8`) as it takes memory (`0x0045079D`), and its code runs from `0x00450540` to
//! `0x00450D01`.

const std = @import("std");

const canvas_module = @import("../interface/canvas.zig");
const disc_module = @import("../interface/disc.zig");
const rooms = @import("../interface/rooms.zig");
const itac_module = @import("../itac.zig");
const tables = itac_module.tables;
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Itac = itac_module.Itac;
const ScrollBox = itac_module.ScrollBox;

/// The stills (`0x004EE7A0`), which it reads as it opens and lets go of as it is left.
pub const pictures_name = "inter\\itac\\vidrep.spr";

/// The film strip the chosen report shows in (`video_reports_draw`, `0x00450760`): its frame, a
/// shape of the stills, at `frame_at`; then the report's still, drawn at the top left of a buffer
/// `still_size` big, and three runs of the buffer's rows copied down the strip from `strip_x`
/// across: its foot above, all of it, and its head below, like the frames of a film.
const frame_shape = 0x23;
const frame_at: [2]i32 = .{ 297, 97 };
const still_size: [2]i32 = .{ 116, 91 };
const strip_x = 317;

/// A run of the buffer's rows copied down the strip: `rows` of them from row `from`, to `to` down
/// the screen (`0x0045085B` on).
const Strip = struct {
    from: i32,
    rows: i32,
    to: i32,

    /// Where it lands on the screen.
    fn rect(strip: Strip) Rect {
        return .{ .x = strip_x, .y = @intCast(strip.to), .width = still_size[0], .height = @intCast(strip.rows) };
    }
};

const strips = [_]Strip{
    .{ .from = 64, .rows = 26, .to = 96 },
    .{ .from = 0, .rows = still_size[1], .to = 130 },
    .{ .from = 0, .rows = 26, .to = 228 },
};

/// The palette the frame is drawn with, and the stills past shape `plain_shapes`; the stills up to
/// it are drawn with block 0's (`0x0045081B`).
const strip_palette = 0x1A;
const plain_shapes = 25;
const plain_palette = 0;

/// The panes it writes into, as it builds (`video_reports_build`, `0x004508D0`): the body, the list
/// and the title.
const body_pane: Rect = .{ .x = 34, .y = 101, .width = 258, .height = 165 };
const list_pane: Rect = .{ .x = 470, .y = 104, .width = 150, .height = 246 };
const title_pane: Rect = .{ .x = 34, .y = 77, .width = 258, .height = 20 };
const body = 0;
const list = 1;
const title = 2;

/// The title, in capitals (`itac.capitals`) in the headers' colour, where it stands in its pane
/// (`0x004509A9`), and the room its copy has (`0x004508D0`).
const title_at: [2]i32 = .{ 2, 2 };
const title_room = 500;

/// The text box of the body, with its arrows (`0x004EE778`), where "(more)" hangs from
/// (`video_reports_enter`, `0x00450540`).
const body_box: ScrollBox = .{
    .arrows = .{ .{ .x = 135, .y = 277, .width = 25, .height = 25 }, .{ .x = 160, .y = 277, .width = 25, .height = 25 } },
    .rect = .{ .x = 34, .y = 103, .width = 258, .height = 156 },
};

/// The list of the reports' titles (`video_reports_list_draw`, `0x00450BA0`), at most `most_listed`
/// from the first shown, the first a pixel down its pane, each hotspot level with its text. Its
/// arrows (`0x004EE790`) step through it.
const title_list: itac_module.TitleList = .{ .pane = list_pane, .top = 1, .hotspot_below = 0 };
const most_listed = 11;
const list_arrows = [2]Rect{ .{ .x = 514, .y = 368, .width = 27, .height = 27 }, .{ .x = 541, .y = 368, .width = 27, .height = 27 } };

/// The button that plays the chosen report (`0x004EE788`).
const play_button: Rect = .{ .x = 360, .y = 277, .width = 40, .height = 40 };

pub const VideoReports = struct {
    /// The reports listed, by their places in `tables.videos` (`video_reports_list`,
    /// `0x0052510C`), and the strings of their titles.
    items: [tables.videos.len]u8 = undefined,
    titles: [tables.videos.len]u16 = undefined,
    item_count: u8 = 0,
    /// The report chosen, by its place in the list (`video_reports_selected`, `0x005251D4`); none
    /// where none is listed.
    selected: ?u8 = null,
    /// The place of the first shown (`video_reports_list_first`, `0x005251E0`).
    first: u8 = 0,
    /// Whether it is open, its stills read (`video_reports_open`, `0x00525108`), and its stills
    /// (`video_reports_pictures`, `0x005251E4`).
    open: bool = false,
    pictures: ?canvas_module.Shapes = null,
    box: ScrollBox = body_box,
    /// The entries the list shows, each a hotspot (`video_reports_hotspots`, `0x00525110`).
    listed: [most_listed]itac_module.ListEntry = undefined,
    listed_count: u8 = 0,
    /// The body, as its build writes it.
    text: [itac_module.text_room]u8 = undefined,
    text_len: usize = 0,

    /// `video_reports_enter` (`0x00450540`): the first report chosen, the list from its start, the
    /// body's box at its top, the reports listed, and the stills read.
    pub fn enter(video: *VideoReports, itac: *Itac) void {
        video.first = 0;
        video.listed_count = 0;
        video.box = body_box;
        video.item_count = itac_module.listBefore(&tables.videos, itac.pilot.mission, &video.items, &video.titles);
        video.selected = if (video.item_count > 0) 0 else null;
        video.pictures = canvas_module.Shapes.read(itac.context.rooms.gpa, itac.context.rooms.resources, pictures_name);
        video.open = true;
    }

    /// `video_reports_leave` (`0x00450600`): the stills let go of, where it is open.
    pub fn leave(video: *VideoReports, gpa: std.mem.Allocator) void {
        if (!video.open) return;
        if (video.pictures) |*pictures| pictures.deinit(gpa);
        video.pictures = null;
        video.open = false;
    }

    /// `video_reports_update` (`0x00450630`), each pass: a build asked for, another report chosen
    /// from the list, the list stepped through, the play button, and the body scrolled. A press on
    /// the play button asks the ITAC to play the chosen report (`itac_video_request`).
    ///
    /// **Fix:** as another report is chosen, the game holds the screen still for half a second
    /// (`itac_pause`, `0x00440170`), drawing nothing. OpenReliant shows the report at once.
    pub fn update(video: *VideoReports, itac: *Itac) void {
        if (itac.rebuild) {
            video.build(itac, true);
            itac.rebuild = false;
        }
        if (itac.left) if (itac_module.entryAt(video.listed[0..video.listed_count], itac.pointer.at)) |place| if (video.selected != place) {
            video.selected = place;
            video.box.scroll = ScrollBox.top;
            video.build(itac, false);
        };
        if (itac.left) if (canvas_module.hit(&list_arrows, itac.pointer.at)) |arrow| if (itac.repeat.fires(itac.left_held)) {
            if (arrow == 0) {
                video.first = @min(video.first + 1, video.lastFirst());
            } else {
                video.first -|= 1;
            }
            video.layOut(itac);
        };
        if (itac.left and play_button.holds(itac.pointer.at)) itac.report = video.chosen();
        video.box.update(itac.ticks, itac.pointer);
    }

    /// The furthest the list steps on (`0x004506F3`): its reports less those it shows, less one.
    ///
    /// **Fix:** where the list shows every report, the game steps its first on to -1, after which
    /// the list lights the report after the chosen one, and a press on a report chooses the one
    /// before it. OpenReliant keeps the first at 0 or more.
    fn lastFirst(video: VideoReports) u8 {
        return video.item_count -| (video.listed_count + 1);
    }

    /// The report chosen; none where none is listed.
    fn chosen(video: VideoReports) ?tables.VideoItem {
        const place = video.selected orelse return null;
        return tables.videos[video.items[place]];
    }

    /// `video_reports_build` (`0x004508D0`): its sound, and for the report chosen, the body written,
    /// the list laid out, and the title's and the body's panes wiping in; with `wipe`, the list's
    /// too.
    fn build(video: *VideoReports, itac: *Itac, wipe: bool) void {
        itac.play(.text, itac_module.full_volume, 1);
        const item = video.chosen() orelse return;
        video.text_len = itac.writeParagraphs(&video.text, item.paragraphs, &video.box);
        video.layOut(itac);
        itac.panes[title].wipeIn(title_pane);
        itac.panes[body].wipeIn(body_pane);
        if (wipe) itac.panes[list].wipeIn(list_pane);
    }

    fn bodyText(video: *const VideoReports) []const u8 {
        return video.text[0..video.text_len];
    }

    /// The list's entries laid out from the first shown, as its drawing lays them out, each a
    /// hotspot.
    fn layOut(video: *VideoReports, itac: *Itac) void {
        video.listed_count = title_list.layOut(itac, video.titles[0..video.item_count], video.first, &video.listed);
    }

    /// `video_reports_draw` (`0x00450760`) at `fade`, while it is open: the film strip with the
    /// chosen report's still, both at `fade`, its panes while no fade runs, and "(more)" where the
    /// body runs past its box.
    ///
    /// **Fix:** the game draws the still, 116 by 90, into a buffer a column wider and a row taller,
    /// which it never clears, so that the strip's frames show what the memory held down their
    /// right edge and along their foot. OpenReliant shows black there.
    ///
    /// **Fix:** with no report listed, which the campaign never has, the game reads the chosen
    /// report through a null pointer and crashes. OpenReliant shows none.
    pub fn draw(video: *VideoReports, itac: *Itac, canvas: Canvas, fade: f32) canvas_module.Error!void {
        if (!video.open) return;
        const item = video.chosen() orelse return;
        if (video.pictures) |*pictures| {
            var faded = canvas;
            faded.brightness = @min(fade, 1);
            pictures.usePalette(strip_palette);
            try faded.shape(&pictures.art, frame_shape, frame_at);
            pictures.usePalette(if (item.shape > plain_shapes) strip_palette else plain_palette);
            for (strips) |strip| {
                const rect = strip.rect();
                canvas.wipe(.{ rect.x, rect.y }, .{ rect.x + rect.width - 1, rect.y + rect.height - 1 }, .{ 0, 0, 0 });
                try faded.within(rect).shape(&pictures.art, item.shape, .{ strip_x, strip.to - strip.from });
            }
        }
        if (!itac.panesShow()) return;
        try video.drawPanes(itac, canvas);
        try itac.drawMore(canvas, video.box);
    }

    /// The panes as they have wiped in: the title, the body as far as it is scrolled, and the list.
    fn drawPanes(video: *VideoReports, itac: *Itac, canvas: Canvas) canvas_module.Error!void {
        const small = &(itac.small orelse return).font;
        const item = video.chosen() orelse return;
        if (itac.panes[title].showing()) |shown| {
            var buffer: [title_room]u8 = undefined;
            try canvas.within(shown).text(small, .{ title_pane.x + title_at[0], title_pane.y + title_at[1] }, itac_module.capitals(&buffer, itac.string(item.title)), itac_module.header_colour, .left);
        }
        if (itac.panes[body].showing()) |shown| try video.box.drawText(canvas, small, body_pane, shown, video.bodyText());
        if (itac.panes[list].showing()) |shown| try title_list.write(itac, canvas, shown, video.titles[0..video.item_count], video.listed[0..video.listed_count], video.selected);
    }
};

/// The disc whose archive holds `item`'s movie, which the ITAC opens to play it (`0x0043F8A0`): the
/// Reliant's for the first part of the campaign, and the Yamato's for the second.
pub fn disc(item: tables.VideoItem) disc_module.Number {
    const carrier: rooms.Carrier = if (item.part == 1) .reliant else .yamato;
    return carrier.disc();
}

/// The name `item`'s movie is found by in the archive: what follows the last backslash of its name,
/// or all of it (`0x0043F8C1`).
pub fn movieName(item: tables.VideoItem) []const u8 {
    const last = std.mem.findScalarLast(u8, item.movie, '\\') orelse return item.movie;
    return item.movie[last + 1 ..];
}

test "the reports of the missions flown are listed" {
    var video: VideoReports = .{};
    // Before mission 1, the opening report alone; before mission 19, the Reliant's four; before
    // mission 28, all six.
    for ([_]struct { u16, u8 }{ .{ 1, 1 }, .{ 19, 4 }, .{ 28, 6 } }) |case| {
        const mission, const count = case;
        video.item_count = itac_module.listBefore(&tables.videos, mission, &video.items, &video.titles);
        try std.testing.expectEqual(count, video.item_count);
    }
    try std.testing.expectEqual(tables.videos[5].title, video.titles[5]);
}

test "VideoReports.lastFirst" {
    // Where the list shows all six, it doesn't step on.
    var video: VideoReports = .{ .item_count = 6, .listed_count = 6 };
    try std.testing.expectEqual(0, video.lastFirst());
    // Where it shows four of twelve, it steps on to seven: twelve less four, less one.
    video = .{ .item_count = 12, .listed_count = 4 };
    try std.testing.expectEqual(7, video.lastFirst());
}

test disc {
    // The Reliant's reports are on the second disc, the Yamato's on the first.
    try std.testing.expectEqual(.two, disc(tables.videos[0]));
    try std.testing.expectEqual(.two, disc(tables.videos[3]));
    try std.testing.expectEqual(.one, disc(tables.videos[4]));
}

test movieName {
    try std.testing.expectEqualStrings("new_intro.bik", movieName(tables.videos[0]));
    var item = tables.videos[0];
    item.movie = "movies\\foster.bik";
    try std.testing.expectEqualStrings("foster.bik", movieName(item));
}

test "Strip.rect" {
    // The still's foot above, all of it, and its head below, 116 across from x 317.
    try std.testing.expectEqual(Rect{ .x = 317, .y = 96, .width = 116, .height = 26 }, strips[0].rect());
    try std.testing.expectEqual(Rect{ .x = 317, .y = 130, .width = 116, .height = 91 }, strips[1].rect());
    try std.testing.expectEqual(Rect{ .x = 317, .y = 228, .width = 116, .height = 26 }, strips[2].rect());
}
