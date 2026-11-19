//! Flight standings for host-owned arena scores.
const std = @import("std");
const hud = @import("../hud.zig");
const players = @import("../players.zig");
const Objects = @import("../create.zig").Objects;
const max_pilots = @import("../deathmatch/spawn.zig").positions;

// Bitmap blocks and pixel positions used by mp_draw_scoreboard (0x004AF650).
pub const palette_block = 0x13;
pub const font_name = "blk2orng.fnt"; // 0x00508EEC
pub const font_transparent_index = 1; // arena_scoreboard_font_remap, 0x005DAD30
const header_shape = 0x14;
const footer_shape = 0x15;
const row_shape = 0x16;
const half_width = 233;
const width = 2 * half_width;
const rise = 110;
const first_row = 21;
const row_height = 17;
const rank_x = 6;
const pilot_x = 20;
const kills_x = 223;
const deaths_x = 321;
const ping_x = 418;
const pilot_width = 150;
const tally_width = 90;
const heading_colour = hud.rgb(0xFFFFFF);
const row_colour = hud.rgb(0xFFFFFF);
const pane_colour: [4]f32 = .{ 0.015, 0.033, 0.048, 0.9 };

const Row = struct {
    slot: usize,
    pilot: *const players.Membership.Joined,

    /// The original scoreboard (0x004AF650) sorts by kills, then fewer deaths.
    fn before(_: void, first: Row, second: Row) bool {
        if (first.pilot.kills.count != second.pilot.kills.count)
            return first.pilot.kills.count > second.pilot.kills.count;
        return first.pilot.deaths < second.pilot.deaths;
    }
};

/// `mp_draw_scoreboard` (0x004AF650) shows the stock free-for-all standings in the flight HUD.
/// Team standings need the team setup and rules ([#1400](https://github.com/OpenReliant/openreliant/issues/1400)).
pub fn draw(pen: hud.Pen, all: *const Objects, art: ?*hud.Art, labels: *hud.Opened) !void {
    var rows: [max_pilots]Row = undefined;
    var count: usize = 0;
    for (all.player_states[0..@min(all.players, rows.len)], 0..) |*state, slot| {
        if (state.membership != .joined) continue;
        rows[count] = .{ .slot = slot, .pilot = &state.membership.joined };
        count += 1;
    }
    if (count == 0) return;
    std.mem.sort(Row, rows[0..count], {}, Row.before);

    const screen_w: f32 = @floatFromInt(pen.screen[0]);
    const screen_h: f32 = @floatFromInt(pen.screen[1]);
    const scale = @min(pen.scale, screen_w / width, screen_h / (2 * rise));
    const placement: Layout = .{ .left = screen_w * 0.5 - half_width * scale, .top = screen_h * 0.5 - rise * scale, .scale = scale };
    const footer: f32 = @floatFromInt(first_row + count * row_height);
    if (art) |icons| {
        var shapes = pen;
        shapes.art = icons;
        shapes.scale = scale;
        shapes.colour = @splat(1);
        try shapes.shape(header_shape, placement.point(0, 0));
        for (0..count) |row| {
            try shapes.shape(row_shape, placement.point(0, @floatFromInt(first_row + row * row_height)));
        }
        try shapes.shape(footer_shape, placement.point(0, footer));
    } else {
        hud.drawFilled(pen.device, .{ .left = placement.left, .top = placement.top, .right = placement.left + width * scale, .bottom = placement.top + footer * scale }, pane_colour);
    }
    var headings = pen;
    headings.font = labels;
    const pilot_label = pen.strings.string(0xBF) orelse "Pilot";
    try placement.text(headings, pilot_x, 0, pilot_label, heading_colour, .left, pilot_width);
    try placement.text(headings, kills_x, 0, pen.strings.string(0x308) orelse "Kills", heading_colour, .centre, tally_width);
    try placement.text(headings, deaths_x, 0, pen.strings.string(0x307) orelse "Deaths", heading_colour, .centre, tally_width);
    try placement.text(headings, ping_x, 0, pen.strings.string(0x559) orelse "Ping", heading_colour, .centre, tally_width);
    for (rows[0..count], 1..) |row, position| {
        const y: f32 = @floatFromInt(first_row - 1 + (position - 1) * row_height);
        var fallback: [64]u8 = undefined;
        const name = row.pilot.name.slice();
        const label = if (name.len > 0) name else std.fmt.bufPrint(&fallback, "{s} {d}", .{ pilot_label, row.slot + 1 }) catch pilot_label;
        try placement.number(headings, rank_x, y, position, heading_colour);
        try placement.text(pen, pilot_x, y, label, row_colour, .left, pilot_width);
        try placement.number(pen, kills_x, y, row.pilot.kills.count, row_colour);
        try placement.number(pen, deaths_x, y, row.pilot.deaths, row_colour);
        if (row.pilot.ping_ms) |ping| {
            try placement.number(pen, ping_x, y, ping, row_colour);
        } else {
            try placement.text(pen, ping_x, y, "-", row_colour, .centre, tally_width);
        }
    }
}

const Layout = struct {
    left: f32,
    top: f32,
    scale: f32,

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
        const fit = @min(1, available / measured);
        _ = try hud.drawTextIn(pen.font, pen.gpa, pen.device, layout.point(x, y), words, hud.atBrightness(colour, 1), alignment, layout.scale * fit, null);
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
