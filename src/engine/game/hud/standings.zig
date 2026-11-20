//! Flight standings for host-owned arena scores.
const std = @import("std");
const hud = @import("../hud.zig");
const players = @import("../players.zig");
const Objects = @import("../create.zig").Objects;
const ui = @import("../interface/canvas.zig");
pub const max_pilots = @import("../gameobj.zig").max_objects;
pub const Scroll = ui.Scrolled(usize);

// Bitmap blocks and pixel positions used by mp_draw_scoreboard (0x004AF650).
pub const palette_block = 0x13;
pub const font_name = "blk2orng.fnt"; // 0x00508EEC
pub const font_transparent_index = 1; // arena_scoreboard_font_remap, 0x005DAD30
pub const font_background_index = 15; // The orange fill behind the headings and ranks.
const header_shape = 0x14;
const footer_shape = 0x15;
const row_shape = 0x16;
const half_width = 233;
const width = 2 * half_width;
const rise = 110;
pub const paused_rise = rise - 50;
pub const first_row = 21;
pub const row_height = 17;
const scroll_footer = 24;
const bottom_margin = 12;
const rank_x = 6;
const pilot_x = 20;
const kills_x = 223;
const deaths_x = 321;
const ping_x = 418;
const reject_x = 515;
pub const reject_offset = reject_x - half_width;
const pilot_width = 150;
const tally_width = 90;
const heading_colour = hud.rgb(0xFFFFFF);
const row_colour = hud.rgb(0xFFFFFF);
const pane_colour: [4]f32 = .{ 0.015, 0.033, 0.048, 0.9 };

pub const Row = struct {
    slot: usize,
    pilot: *const players.Membership.Joined,

    /// The original scoreboard (0x004AF650) sorts by kills, then fewer deaths.
    fn before(_: void, first: Row, second: Row) bool {
        if (first.pilot.kills.count != second.pilot.kills.count)
            return first.pilot.kills.count > second.pilot.kills.count;
        return first.pilot.deaths < second.pilot.deaths;
    }
};

/// Collect the scores in the order `mp_draw_scoreboard` (0x004AF650) uses.
pub fn rowsOf(all: *const Objects, rows: *[max_pilots]Row) []const Row {
    var count: usize = 0;
    for (all.player_states[0..@min(all.players, rows.len)], 0..) |*state, slot| {
        if (state.membership != .joined) continue;
        rows[count] = .{ .slot = slot, .pilot = &state.membership.joined };
        count += 1;
    }
    return ordered(rows[0..count]);
}

pub fn ordered(rows: []Row) []const Row {
    std.mem.sort(Row, rows, {}, Row.before);
    return rows;
}

pub fn scrollWindow(first: usize, count: usize, shown: usize) Scroll {
    return .{ .first = @min(first, count -| shown), .count = count, .shown = shown };
}

pub fn scrollWheel(scroll: *Scroll, notches: i32) void {
    scroll.wheel(std.math.clamp(notches, -max_pilots, max_pilots));
}

pub fn scrollPage(scroll: *Scroll, way: ui.Arrow) void {
    switch (way) {
        .up => scroll.first -|= scroll.shown,
        .down => scroll.first = @min(scroll.first + scroll.shown, scroll.count -| scroll.shown),
    }
}

/// **Improvement:** Fit complete rows and keep room at the bottom for the scroll range.
pub fn visibleRows(screen: [2]u32, scale: f32) usize {
    const layout: Layout = .fit(screen, scale, rise);
    if (layout.scale <= 0) return 1;
    const available = (@as(f32, @floatFromInt(screen[1])) - layout.top) / layout.scale;
    return @intFromFloat(@min(max_pilots, @max(1, @floor((available - first_row - scroll_footer - bottom_margin) / row_height))));
}

/// `mp_draw_scoreboard` (0x004AF650) shows the stock free-for-all standings in the flight HUD.
/// Team standings need the team setup and rules ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
pub fn draw(pen: hud.Pen, all: *const Objects, art: ?*hud.Art, labels: *hud.Opened, first: usize) !void {
    var buffer: [max_pilots]Row = undefined;
    const rows = rowsOf(all, &buffer);
    const count = rows.len;
    if (count == 0) return;
    const scroll = scrollWindow(first, count, visibleRows(pen.screen, pen.scale));
    try drawRows(pen, rows, art, labels, scroll, .flight);
}

pub const Mode = enum { flight, paused_arena, paused_campaign };

/// The in-flight and paused panels share sprites, columns, and ordering in `mp_draw_scoreboard`.
pub fn drawRows(pen: hud.Pen, rows: []const Row, art: ?*hud.Art, labels: *hud.Opened, scroll: Scroll, mode: Mode) !void {
    const placement: Layout = .fit(pen.screen, pen.scale, if (mode == .flight) rise else paused_rise);
    const visible = rows[scroll.first..scroll.end()];
    const footer: f32 = @floatFromInt(first_row + visible.len * row_height);
    if (art) |icons| {
        var shapes = pen;
        shapes.art = icons;
        shapes.scale = placement.scale;
        shapes.colour = @splat(1);
        try shapes.shape(header_shape, placement.point(0, 0));
        for (0..visible.len) |row| {
            try shapes.shape(row_shape, placement.point(0, @floatFromInt(first_row + row * row_height)));
        }
        try shapes.shape(footer_shape, placement.point(0, footer));
    } else {
        hud.drawFilled(pen.device, .{ .left = placement.left, .top = placement.top, .right = placement.left + width * placement.scale, .bottom = placement.top + footer * placement.scale }, pane_colour);
    }
    var headings = pen;
    headings.font = labels;
    const pilot_label = pen.strings.string(0xBF) orelse "Pilot";
    try placement.text(headings, pilot_x, 0, pilot_label, heading_colour, .left, pilot_width);
    try placement.text(headings, kills_x, 0, pen.strings.string(0x308) orelse "Kills", heading_colour, .centre, tally_width);
    if (mode != .paused_campaign) try placement.text(headings, deaths_x, 0, pen.strings.string(0x307) orelse "Deaths", heading_colour, .centre, tally_width);
    try placement.text(headings, ping_x, 0, pen.strings.string(0x559) orelse "Ping", heading_colour, .centre, tally_width);
    if (mode != .flight) try placement.text(pen, reject_x, 0, pen.strings.string(0x5F2) orelse "Reject", heading_colour, .centre, tally_width);
    for (visible, 0..) |row, position| {
        const y: f32 = @floatFromInt(first_row - 1 + position * row_height);
        var fallback: [64]u8 = undefined;
        const name = row.pilot.name.slice();
        const label = if (name.len > 0) name else std.fmt.bufPrint(&fallback, "{s} {d}", .{ pilot_label, row.slot + 1 }) catch pilot_label;
        try placement.number(headings, rank_x, y, scroll.first + position + 1, heading_colour);
        try placement.text(pen, pilot_x, y, label, row_colour, .left, pilot_width);
        try placement.number(pen, kills_x, y, row.pilot.kills.count, row_colour);
        if (mode != .paused_campaign) try placement.number(pen, deaths_x, y, row.pilot.deaths, row_colour);
        if (row.pilot.ping_ms) |ping| {
            try placement.number(pen, ping_x, y, ping, row_colour);
        } else {
            try placement.text(pen, ping_x, y, "-", row_colour, .centre, tally_width);
        }
    }
    if (scroll.count > scroll.shown and mode == .flight) {
        var buffer_range: [32]u8 = undefined;
        const range = std.fmt.bufPrint(&buffer_range, "{d}-{d}/{d}", .{ scroll.first + 1, scroll.end(), scroll.count }) catch unreachable;
        try placement.text(headings, half_width, footer + row_height, range, heading_colour, .centre, tally_width);
    }
}

const Layout = struct {
    left: f32,
    top: f32,
    scale: f32,

    fn fit(screen: [2]u32, requested: f32, rank_rise: f32) Layout {
        const screen_w: f32 = @floatFromInt(screen[0]);
        const screen_h: f32 = @floatFromInt(screen[1]);
        const scale = @min(requested, screen_w / width, screen_h / (2 * rise));
        return .{ .left = screen_w * 0.5 - half_width * scale, .top = screen_h * 0.5 - rank_rise * scale, .scale = scale };
    }

    fn point(layout: Layout, x: f32, y: f32) [2]i32 {
        return .{ @intFromFloat(@round(layout.left + x * layout.scale)), @intFromFloat(@round(layout.top + y * layout.scale)) };
    }

    fn number(layout: Layout, pen: hud.Pen, x: f32, y: f32, value: anytype, colour: [3]f32) !void {
        var buffer: [24]u8 = undefined;
        const words = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
        try layout.text(pen, x, y, words, colour, .centre, tally_width);
    }

    fn text(layout: Layout, pen: hud.Pen, x: f32, y: f32, words: []const u8, colour: [3]f32, alignment: hud.Align, available: f32) !void {
        const measured: f32 = @floatFromInt(@max(1, pen.font.textWidth(words)));
        const fitted = @min(1, available / measured);
        _ = try hud.drawTextIn(pen.font, pen.gpa, pen.device, layout.point(x, y), words, hud.atBrightness(colour, 1), alignment, layout.scale * fitted, null);
    }
};

test "arena standings break a kill tie by deaths and keep exact ties in slot order" {
    const pilots = [_]players.Membership.Joined{
        .{ .generation = 1, .kills = .{ .count = 4 }, .deaths = 9 },
        .{ .generation = 2, .kills = .{ .count = 2 }, .deaths = 0 },
        .{ .generation = 3, .kills = .{ .count = 4 }, .deaths = 3 },
        .{ .generation = 4, .kills = .{ .count = 4 }, .deaths = 3 },
    };
    var rows: [pilots.len]Row = undefined;
    for (&rows, &pilots, 0..) |*row, *pilot, slot| row.* = .{ .slot = slot, .pilot = pilot };
    std.mem.sort(Row, &rows, {}, Row.before);
    for (rows, [_]usize{ 2, 3, 0, 1 }) |row, slot| try std.testing.expectEqual(slot, row.slot);
}

test "flight standings resize and keep the final ranked row in view" {
    const count = 60;
    const small = visibleRows(.{ 640, 360 }, 1);
    const tall = visibleRows(.{ 640, 900 }, 1);
    try std.testing.expect(small < tall and tall < count);
    var scroll = scrollWindow(count, count, small);
    try std.testing.expectEqual(count - small, scroll.first);
    try std.testing.expectEqual(count, scroll.end());
    scrollPage(&scroll, .up);
    try std.testing.expectEqual(count - small * 2, scroll.first);
    scrollPage(&scroll, .down);
    scrollPage(&scroll, .down);
    try std.testing.expectEqual(count - small, scroll.first);
}
