//! DEBRIEFINGS, the ITAC's first section: Enriquez's debriefing of each mission the pilot has
//! flown, chosen from a list, with the mission's kills, the pilot's, and the pilot's rank and
//! level; after a mission, the latest, with REPLAY MISSION. It is text alone: its body is the
//! paragraphs the mission's rating calls for (`tables.debriefings`), with a word on the medal, the
//! promotion, the ribbon and the fighters the mission brought.
//!
//! **Unverified:** the file. Its code (`0x004246C0` to `0x004258FF`) lies between the capital
//! ships' and the fighters', before GenILib's `interf.cpp`, where no assertion names a file; it goes
//! with the ITAC, whose section it is.

const std = @import("std");

const hud = @import("../hud.zig");
const gameflow = @import("../gameflow.zig");
const canvas_module = @import("../interface/canvas.zig");
const itac_module = @import("../itac.zig");
const landing = @import("../xtrabits/landing.zig");
const tables = @import("tables.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
const Itac = itac_module.Itac;
const ScrollBox = itac_module.ScrollBox;

/// The campaign's missions in the order they are flown, by their places in it
/// (`campaign_missions`, `0x004E4954`): mission 1 on, as the campaign moves on
/// (`gameflow.nextMission`), to the last.
const campaign_missions = order: {
    var missions: [campaignLength()]u16 = undefined;
    var number: u16 = 1;
    for (&missions) |*flown| {
        flown.* = number;
        number = gameflow.nextMission(number);
    }
    break :order missions;
};

fn campaignLength() usize {
    var count: usize = 1;
    var number: u16 = 1;
    while (number != gameflow.last_mission) : (count += 1) number = gameflow.nextMission(number);
    return count;
}

/// The place mission 0 has, and the mission number `debrief_select_latest` takes as mission 26
/// (`0x004258E0`). **Unknown:** why; the campaign comes to neither.
const place_of_none = 28;
const odd_mission = 0xFC;
const odd_mission_as = 26;

/// The place of mission `mission` in the campaign's order (`campaign_place`, `0x004E49B0`): the
/// missions flown before it, so that those the campaign has none of share the next one's place, and
/// as the campaign comes to it, the debriefings on offer (`itac_debriefings`, `0x00523078`).
fn placeOf(mission: u16) u8 {
    if (mission == 0) return place_of_none;
    var place: u8 = 0;
    for (campaign_missions) |flown| {
        if (flown >= mission) break;
        place += 1;
    }
    return place;
}

/// The text box of the body, with its arrows (`0x004E4918`), where "(more)" hangs from, and the
/// pane it is written into (`debrief_enter`, `0x004246C0`).
const body_box: ScrollBox = .{
    .arrows = .{ .{ .x = 219, .y = 321, .width = 27, .height = 27 }, .{ .x = 246, .y = 321, .width = 27, .height = 27 } },
    .rect = .{ .x = 30, .y = 112, .width = 400, .height = 191 },
};

/// The panes it writes into, as it builds (`debrief_build`, `0x00424BE0`): the header, the body and
/// the list.
const header_pane: Rect = .{ .x = 30, .y = 82, .width = 399, .height = 34 };
const body_pane: Rect = .{ .x = 30, .y = 117, .width = 400, .height = 194 };
const list_pane: Rect = .{ .x = 473, .y = 104, .width = 144, .height = 259 };
const header = 0;
const body = 1;
const list = 2;

/// The header's lines, in the pane's frame (`debrief_text_draw`, `0x00424CF0`): FROM and TO at the
/// left, whom from and to at `header_values`, a line of `header_line` apart, in the headers'
/// colour.
const from_string = 0x8C;
const to_string = 0x8D;
const header_labels_x = 1;
const header_values_x = 46;
const header_line = 15;
pub const header_colour = hud.rgb(0x3AD1FF);

/// Between two paragraphs (`0x004E5440`).
const between = "\n\n";

/// The paragraphs added to the body: a medal's, by the medal (`0x004E4A26`); a promotion's, by the
/// rank (`0x004E4A48`); a ribbon's, by the ribbon (`0x004E4A32`); the new fighters', by the tier
/// (`0x004E4A5A`); and, where a nanny ship picked the pilot up, whether the objectives were met
/// (`0x00424ED4`), and the pickup's, by the pickups so far (`0x004E4A3E`), in place of the rest.
const medal_texts = [_]u16{ 0, 205, 206, 207, 208, 209, 210 };
const promotion_texts = [_]u16{ 230, 230, 231, 232, 233, 234, 235, 236, 237 };
const ribbon_texts = [_]u16{ 210, 211, 212, 213, 214, 215 };
const tier_texts = [_]u16{ 0, 238, 239, 240 };
const objectives_met_text = 0x720;
const objectives_missed_text = 0x721;
const pickup_texts = [_]u16{ 0, 227, 228, 229 };

/// The figures at its foot (`debrief_draw`, `0x00424930`): the labels at the left, in the labels'
/// colour, and the values right-aligned at `values_x`, in the text's, a line of `figure_line`
/// apart from `figures_y`. Rank and Level are the game's strings, and so are the names of the rank
/// and the level (`gameflow.rank_names`, `gameflow.tier_names`).
const mission_kills_string = 0x8A;
const overall_kills_string = 0x8B;
const rank_string = 0xE8;
const level_string = 0xE9;
const labels_x = 36;
const values_x = 214;
const figures_y = 346;
const figure_line = 16;
pub const label_colour = hud.rgb(0xFFBD82);

/// REPLAY MISSION: its button, lit where the pointer is over it (`0x004E4948`), shapes 27 and 28
/// of `itacgfx.spr` with the palette of block 26, and its label, the game's string, right-aligned
/// beside it, white where lit.
const replay_button: Rect = .{ .x = 433, .y = 368, .width = 33, .height = 25 };
const replay_shape = 27;
const replay_lit_shape = 28;
const replay_palette = 26;
const replay_string = 0x296;
const replay_label_at: [2]i32 = .{ 425, 370 };
const replay_lit_colour = hud.rgb(0xFFFFFF);

/// The list of the missions flown (`debrief_list_draw`, `0x00425780`): each "Mission" and its place
/// counted from 1 (`0x004E5444`), broken into lines of at most `entry_width`, `entry_line` apart,
/// from `entry_x` across and `list_top` down in the pane, `entry_gap` below the last, while the next
/// starts within `list_bottom`; the chosen in the headers' colour. Its arrows (`0x004E4928`) step
/// through it, keeping `list_room` in view.
const mission_string = 0x8E;
const entry_x = 10;
const entry_width = 126;
const entry_line = 11;
const entry_most_lines = 20;
const entry_gap = 6;
const entry_padding = 4;
const list_top = 2;
const list_bottom = 0xDC;
const list_room = 14;
const list_arrows = [2]Rect{ .{ .x = 515, .y = 368, .width = 27, .height = 27 }, .{ .x = 542, .y = 368, .width = 27, .height = 27 } };
const most_listed = 13;

/// The room the body's text has (`itac_text`, `0x00520844`).
const text_room = 10000;

/// A mission listed, and where its entry stands on the screen (`debrief_list_hotspots`,
/// `0x0051D318`).
const Listed = struct { place: u8, rect: Rect };

pub const Debriefing = struct {
    /// The debriefing chosen, a place in the campaign's order (`debrief_selected`, `0x0051D380`);
    /// none where the campaign has none yet.
    selected: ?u8 = null,
    /// The first listed (`debrief_list_first`, `0x0051D30C`).
    first: u8 = 0,
    /// Whether it builds its panes on its next update (`itac_rebuild`, `0x0052032C`).
    rebuild: bool = false,
    box: ScrollBox = body_box,
    /// Whether the pointer is over REPLAY MISSION (`debrief_replay_hover`, `0x0051D310`).
    replay_lit: bool = false,
    listed: [most_listed]Listed = undefined,
    listed_count: u8 = 0,
    /// The body, as its build writes it.
    text: [text_room]u8 = undefined,
    text_len: usize = 0,

    /// `debrief_enter` (`0x004246C0`): the latest debriefing chosen (`debrief_select_latest`,
    /// `0x004258E0`), the list from its start, and the body's box at its top.
    pub fn enter(debriefing: *Debriefing, pilot: itac_module.Pilot) void {
        const place = placeOf(if (pilot.mission == odd_mission) odd_mission_as else pilot.mission);
        debriefing.selected = std.math.sub(u8, place, 1) catch null;
        debriefing.first = 0;
        debriefing.rebuild = false;
        debriefing.box = body_box;
    }

    /// `debrief_loaded` (`0x004247A0`): built with its panes wiping in, and again on the next update.
    pub fn loaded(debriefing: *Debriefing, itac: *Itac) void {
        debriefing.rebuild = true;
        itac.panes = @splat(.{});
        debriefing.build(itac, true);
    }

    /// `debrief_update` (`0x004247C0`), each pass: a build asked for, the body scrolled, another
    /// debriefing chosen from the list, the list stepped through, and REPLAY MISSION.
    ///
    /// **Fix:** as another debriefing is chosen, the game holds the screen still for half a second
    /// (`itac_pause`, `0x00440170`), drawing nothing. OpenReliant shows the debriefing at once.
    pub fn update(debriefing: *Debriefing, itac: *Itac) void {
        if (debriefing.rebuild) {
            debriefing.build(itac, true);
            debriefing.rebuild = false;
        }
        debriefing.box.update(itac.ticks, itac.pointer);
        if (itac.left) if (debriefing.listedAt(itac.pointer.at)) |place| if (debriefing.selected != place) {
            debriefing.selected = place;
            debriefing.box.scroll = ScrollBox.top;
            debriefing.build(itac, false);
        };
        if (itac.left) if (canvas_module.hit(&list_arrows, itac.pointer.at)) |arrow| if (itac.repeat.fires(itac.left_held)) {
            const mission = itac.pilot.mission;
            const room = std.math.sub(u8, placeOf(mission + 1), list_room) catch 0;
            if (arrow == 0) {
                if (debriefing.first < room) debriefing.first += 1;
            } else {
                debriefing.first -|= 1;
            }
            debriefing.layOut(itac);
        };
        debriefing.replay_lit = false;
        if (debriefing.replayOffered(itac)) {
            debriefing.replay_lit = replay_button.holds(itac.pointer.at);
            if (debriefing.replay_lit and itac.left) itac.replay = true;
        }
    }

    /// Whether REPLAY MISSION shows: after a mission, for its debriefing, the latest.
    fn replayOffered(debriefing: Debriefing, itac: *const Itac) bool {
        const selected = debriefing.selected orelse return false;
        return itac.run == .after_mission and placeOf(itac.pilot.mission) == selected + 1;
    }

    /// The listed mission whose entry holds `at`, its edges left out.
    fn listedAt(debriefing: Debriefing, at: [2]i32) ?u8 {
        for (debriefing.listed[0..debriefing.listed_count]) |entry| if (entry.rect.holds(at)) return entry.place;
        return null;
    }

    /// The mission chosen, by its number; none where none is.
    fn chosen(debriefing: Debriefing) ?u16 {
        const place = debriefing.selected orelse return null;
        if (place >= campaign_missions.len) return null;
        return campaign_missions[place];
    }

    /// `debrief_build` (`0x00424BE0`): after the campaign's first mission, its sound, the body
    /// written, the list laid out, and the header's pane wiping in; with `wipe`, the body's and the
    /// list's too.
    fn build(debriefing: *Debriefing, itac: *Itac, wipe: bool) void {
        if (itac.pilot.mission <= 1) return;
        itac.play(.text, itac_module.full_volume, 1);
        debriefing.write(itac);
        debriefing.layOut(itac);
        itac.panes[header].wipeIn(header_pane);
        if (wipe) {
            itac.panes[body].wipeIn(body_pane);
            itac.panes[list].wipeIn(list_pane);
        }
    }

    /// The body of the debriefing chosen (`debrief_text_draw`, `0x00424CF0`): where a nanny ship
    /// picked the pilot up, whether the objectives were met, as the campaign's variables have it
    /// now, and the pickup; otherwise the paragraphs its rating calls for, and after them each
    /// that the mission brought of a medal, where its rating is a success with its bonus, a
    /// promotion, a ribbon and new fighters. A mission's ribbon (`ribbon_of_mission`, `0x0050099F`)
    /// is the chapter it ends, whose table holds the same (`landing.chapterOf`).
    fn write(debriefing: *Debriefing, itac: *Itac) void {
        var writer: std.Io.Writer = .fixed(&debriefing.text);
        defer debriefing.text_len = writer.end;
        const number = debriefing.chosen() orelse return;
        const record = itac.pilot.campaign.kept(number);
        if (record.pickups != 0) {
            const met = itac.pilot.campaign.variables.objectives_met != 0;
            writer.writeAll(between) catch {};
            writer.writeAll(itac.string(if (met) objectives_met_text else objectives_missed_text)) catch {};
            writer.writeAll(between) catch {};
            writer.writeAll(itac.string(pickup_texts[@min(record.pickups, pickup_texts.len - 1)])) catch {};
        } else {
            for (textOf(record, number).paragraphs, 0..) |id, n| {
                if (n > 0) writer.writeAll(between) catch {};
                writer.writeAll(itac.string(id)) catch {};
            }
            if (gameflow.Medal.of(number)) |medal| if (record.rating == .success_bonus) addParagraph(&writer, itac, medal_texts[@intFromEnum(medal)]);
            if (record.promotion) |rank| addParagraph(&writer, itac, promotion_texts[rank]);
            if (landing.chapterOf(number)) |ribbon| addParagraph(&writer, itac, ribbon_texts[ribbon]);
            const tier = gameflow.mission_tiers[number - 1];
            if (tier != 0) addParagraph(&writer, itac, tier_texts[tier]);
        }
        debriefing.reach(itac);
    }

    /// How far the body can scroll, as it breaks into lines.
    fn reach(debriefing: *Debriefing, itac: *Itac) void {
        const font = &(itac.small orelse return);
        debriefing.box.reach(debriefing.box.lines().count(font, debriefing.bodyText()));
    }

    fn bodyText(debriefing: *const Debriefing) []const u8 {
        return debriefing.text[0..debriefing.text_len];
    }

    /// The list's entries laid out from the first, as its drawing lays them out, each a hotspot.
    fn layOut(debriefing: *Debriefing, itac: *Itac) void {
        debriefing.listed_count = 0;
        const font = &(itac.small orelse return);
        if (itac.pilot.mission <= 1) return;
        const flown = std.math.sub(u8, placeOf(itac.pilot.mission + 1), 1) catch 0;
        var y: i32 = list_top;
        var place = debriefing.first;
        while (place < flown and y <= list_bottom and debriefing.listed_count < most_listed) : (place += 1) {
            var buffer: [64]u8 = undefined;
            const entry = entryText(&buffer, itac, place);
            const lines: i32 = @intCast(entryLines().count(font, entry));
            debriefing.listed[debriefing.listed_count] = .{ .place = place, .rect = .{
                .x = list_pane.x,
                .y = @intCast(list_pane.y + y),
                .width = list_pane.width,
                .height = @intCast(lines * entry_line + entry_padding),
            } };
            debriefing.listed_count += 1;
            y += lines * entry_line + entry_gap;
        }
    }

    /// `debrief_draw` (`0x00424930`), at `fade`: its panes, while no fade runs; the figures'
    /// labels, and their values faded; and REPLAY MISSION where it is offered.
    pub fn draw(debriefing: *Debriefing, itac: *Itac, canvas: Canvas, fade: f32) canvas_module.Error!void {
        const small = &(itac.small orelse return);
        if (itac.panesShow()) try debriefing.drawPanes(itac, canvas, small);

        const labels = [_][]const u8{
            itac.string(mission_kills_string),
            itac.string(overall_kills_string),
            itac.context.language.string(rank_string) orelse "",
            itac.context.language.string(level_string) orelse "",
        };
        for (labels, 0..) |label, row| try canvas.text(small, .{ labels_x, figureY(row) }, label, label_colour, .left);

        var faded = canvas;
        faded.brightness = @min(fade, 1);
        const number = debriefing.chosen() orelse 0;
        var mission_kills: [16]u8 = undefined;
        var overall_kills: [16]u8 = undefined;
        const values = [_][]const u8{
            std.fmt.bufPrint(&mission_kills, "{d}", .{itac.pilot.campaign.kept(number).kills}) catch "",
            std.fmt.bufPrint(&overall_kills, "{d}", .{itac.pilot.kills}) catch "",
            itac.context.language.string(gameflow.rank_names[itac.pilot.rank]) orelse "",
            itac.context.language.string(gameflow.tier_names[itac.pilot.tier]) orelse "",
        };
        for (values, 0..) |value, row| try faded.text(small, .{ values_x, figureY(row) }, value, itac_module.text_colour, .right);

        if (debriefing.replayOffered(itac)) if (itac.shapes) |*shapes| {
            shapes.usePalette(replay_palette);
            try canvas.shape(&shapes.art, if (debriefing.replay_lit) replay_lit_shape else replay_shape, .{ replay_button.x, replay_button.y });
            const colour = if (debriefing.replay_lit) replay_lit_colour else itac_module.text_colour;
            try faded.text(small, replay_label_at, itac.context.language.string(replay_string) orelse "", colour, .right);
        };
        if (!itac.frozen and itac.panesShow() and debriefing.box.more(itac.panes[header].wiping != 0)) try itac.drawMore(canvas, debriefing.box);
    }

    /// The panes as they have wiped in: the header, the body as far as it is scrolled, and the list.
    fn drawPanes(debriefing: *Debriefing, itac: *Itac, canvas: Canvas, small: *hud.Opened) canvas_module.Error!void {
        if (itac.panes[header].showing()) |shown| if (debriefing.chosen()) |number| {
            const in_pane = canvas.within(shown);
            const top = header_pane.y + 1;
            const heading = textOf(itac.pilot.campaign.kept(number), number).header;
            try in_pane.text(small, .{ header_pane.x + header_labels_x, top }, itac.string(from_string), header_colour, .left);
            try in_pane.text(small, .{ header_pane.x + header_values_x, top }, itac.string(heading), header_colour, .left);
            try in_pane.text(small, .{ header_pane.x + header_labels_x, top + header_line }, itac.string(to_string), header_colour, .left);
            try in_pane.text(small, .{ header_pane.x + header_values_x, top + header_line }, itac.pilot.call_sign, header_colour, .left);
        };
        if (itac.panes[body].showing()) |shown| {
            const scroll: i32 = @intFromFloat(debriefing.box.scroll);
            try canvas.within(shown).wrapped(small, .{ body_pane.x, body_pane.y + scroll - 1 }, debriefing.bodyText(), itac_module.text_colour, .left, debriefing.box.lines());
        }
        if (itac.panes[list].showing()) |shown| {
            const in_pane = canvas.within(shown);
            for (debriefing.listed[0..debriefing.listed_count]) |entry| {
                var buffer: [64]u8 = undefined;
                const colour = if (debriefing.selected == entry.place) header_colour else itac_module.text_colour;
                try in_pane.wrapped(small, .{ list_pane.x + entry_x, entry.rect.y }, entryText(&buffer, itac, entry.place), colour, .left, entryLines());
            }
        }
    }
};

/// The rating a mission's record has, as its debriefing's table is chosen by: success with its
/// bonus where it has none (`0x00424DA4`).
fn ratingOf(record: gameflow.MissionRecord) usize {
    const rating = record.rating orelse return tables.debriefings.len - 1;
    return @intCast(std.math.clamp(@intFromEnum(rating), 0, tables.debriefings.len - 1));
}

/// The debriefing of mission `number` as its record has it.
fn textOf(record: gameflow.MissionRecord, number: u16) tables.Text {
    return tables.debriefings[ratingOf(record)][number - 1];
}

/// A paragraph of the ITAC's string `id` after those written.
fn addParagraph(writer: *std.Io.Writer, itac: *Itac, id: u16) void {
    writer.writeAll(between) catch {};
    writer.writeAll(itac.string(id)) catch {};
}

/// A figure's row down the screen.
fn figureY(row: usize) i32 {
    return figures_y + @as(i32, @intCast(row)) * figure_line;
}

/// How a list's entry breaks into lines.
fn entryLines() Canvas.Lines {
    return .{ .width = entry_width, .height = entry_line, .most = entry_most_lines };
}

/// "Mission" and the place counted from 1.
fn entryText(buffer: []u8, itac: *Itac, place: u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s} {d}", .{ itac.string(mission_string), @as(u32, place) + 1 }) catch "";
}

test placeOf {
    // The missions the campaign has none of share the next one's place.
    try std.testing.expectEqual(10, placeOf(11));
    try std.testing.expectEqual(11, placeOf(12));
    try std.testing.expectEqual(11, placeOf(14));
    try std.testing.expectEqual(24, placeOf(29));
    // Each place's mission comes back to it.
    for (campaign_missions, 0..) |number, place| try std.testing.expectEqual(place, placeOf(number));
}

test ratingOf {
    try std.testing.expectEqual(4, ratingOf(.{}));
    try std.testing.expectEqual(0, ratingOf(.{ .rating = .failure }));
    try std.testing.expectEqual(3, ratingOf(.{ .rating = .success }));
    try std.testing.expectEqual(4, ratingOf(.{ .rating = .success_bonus }));
}

test textOf {
    // Mission 1 rated a success with its bonus, and rated a failure.
    try std.testing.expectEqual(1641, textOf(.{ .rating = .success_bonus }, 1).paragraphs[0]);
    try std.testing.expectEqual(364, textOf(.{ .rating = .failure }, 1).paragraphs[0]);
}
