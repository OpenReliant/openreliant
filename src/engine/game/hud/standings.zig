//! Flight standings for host-owned arena scores.
const std = @import("std");
const hud = @import("../hud.zig");
const players = @import("../players.zig");
const Objects = @import("../create.zig").Objects;
const max_pilots = @import("../deathmatch/spawn.zig").positions;

const width = 440;
const margin = 15;
const row_height = 24;
const pilot_width = 218;
const kills_x = 290;
const deaths_x = 386;
const tally_width = 90;
const panel_top = 76;
const heading_colour = hud.rgb(0x79CEE7);
const row_colour = hud.rgb(0xE1F4F7);
const own_colour = hud.rgb(0xFFBC55);
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

pub fn draw(pen: hud.Pen, all: *const Objects) !void {
    var rows: [max_pilots]Row = undefined;
    var count: usize = 0;
    for (all.player_states[0..@min(all.players, rows.len)], 0..) |*state, slot| {
        if (state.membership != .joined) continue;
        rows[count] = .{ .slot = slot, .pilot = &state.membership.joined };
        count += 1;
    }
    if (count == 0) return;
    std.mem.sort(Row, rows[0..count], {}, Row.before);

    const scale = @min(pen.scale, @as(f32, @floatFromInt(pen.screen[0])) / (width + 2 * margin));
    const left = @as(f32, @floatFromInt(pen.screen[0])) * 0.5 - width * scale * 0.5;
    const top = panel_top * scale;
    const height: f32 = @floatFromInt((count + 1) * row_height + 2 * margin);
    hud.drawFilled(pen.device, .{ .left = left, .top = top, .right = left + width * scale, .bottom = top + height * scale }, pane_colour);
    const layout: Layout = .{ .left = left, .top = top, .scale = scale };
    const pilot_label = pen.strings.string(0xBF) orelse "Pilot";
    try layout.text(pen, margin, margin, pilot_label, heading_colour, .left, pilot_width);
    try layout.text(pen, kills_x, margin, pen.strings.string(0x308) orelse "Kills", heading_colour, .centre, tally_width);
    try layout.text(pen, deaths_x, margin, pen.strings.string(0x307) orelse "Deaths", heading_colour, .centre, tally_width);
    for (rows[0..count], 1..) |row, position| {
        const y: f32 = @floatFromInt(margin + position * row_height);
        const colour = if (row.slot == all.player) own_colour else row_colour;
        var fallback: [64]u8 = undefined;
        var kill_text: [16]u8 = undefined;
        var death_text: [16]u8 = undefined;
        const name = row.pilot.name.slice();
        const label = if (name.len > 0) name else std.fmt.bufPrint(&fallback, "{s} {d}", .{ pilot_label, row.slot + 1 }) catch pilot_label;
        try layout.text(pen, margin, y, label, colour, .left, pilot_width);
        try layout.text(pen, kills_x, y, std.fmt.bufPrint(&kill_text, "{d}", .{row.pilot.kills.count}) catch unreachable, colour, .centre, tally_width);
        try layout.text(pen, deaths_x, y, std.fmt.bufPrint(&death_text, "{d}", .{row.pilot.deaths}) catch unreachable, colour, .centre, tally_width);
    }
}

const Layout = struct {
    left: f32,
    top: f32,
    scale: f32,

    fn text(layout: Layout, pen: hud.Pen, x: f32, y: f32, words: []const u8, colour: [3]f32, alignment: hud.Align, available: f32) !void {
        const measured: f32 = @floatFromInt(@max(1, pen.font.textWidth(words)));
        const fit = @min(1, available / measured);
        const point: [2]i32 = .{ @intFromFloat(@round(layout.left + x * layout.scale)), @intFromFloat(@round(layout.top + y * layout.scale)) };
        _ = try hud.drawTextIn(pen.font, pen.gpa, pen.device, point, words, hud.atBrightness(colour, 1), alignment, layout.scale * fit, null);
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
