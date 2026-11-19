//! **Improvement:** OpenReliant combines game setup and the waiting roster, as the original
//! deathmatch loadout (`session_loadout_screen`, 0x0044B950) does. The host starts the match here.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const input = @import("../../../input.zig");
const CallSign = @import("../pilot_roster.zig").CallSign;
const Layout = @import("layout.zig");
const widgets = @import("widgets.zig");
const Label = widgets.Label;
const Lobby = @This();

pub const Action = enum { leave, launch };
const Role = union(enum) { host: struct { can_launch: bool = false, port: u16 }, guest };

role: Role,
roster: []const ?CallSign,
local_slot: usize,
scenario: Label,
ship: Label,
hover: ?Action = null,

const panel_top = 153;
const panel_bottom = 361;
const left_edge = 48;
const divider = 343;
const right_edge = 592;
const gap = 14;
const heading_y = 9;
const first_row = 39;
const row_height = 21;
const line_height = 17;
const control_height = 20;
const control_width = 180;

const host_title: Label = .{ .english = "DEATHMATCH HOST", .installed = 0x2C1 };
const guest_title: Label = .{ .english = "DEATHMATCH JOIN", .installed = 0x2D3 };
const players_label: Label = .{ .english = "PLAYERS", .installed = 0x141 };
const fallback_player: Label = .{ .english = "PILOT", .installed = 0xBF };
const host_label: Label = .{ .english = "HOST", .installed = 0x13C };
const launch_label: Label = .{ .english = "START GAME", .installed = 0xB9 };
const scenario_label: Label = .{ .english = "GAME TYPE", .installed = 0x139 };
const ship_label: Label = .{ .english = "SHIP", .installed = 0x2C3 };
const waiting_label: Label = .{ .english = "WAITING", .installed = 0x30E };
const for_host_label: Label = .{ .english = "FOR HOST", .installed = 0x30F };

fn box(layout: Layout, x: i16, right: i16) ui.Rect {
    const left, const top = layout.point(.{ x, panel_top });
    const end, const bottom = layout.point(.{ right, panel_bottom });
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(end - left), .height = @intCast(bottom - top) };
}

fn control(layout: Layout, action: Action) ui.Rect {
    const panel = switch (action) {
        .leave => box(layout, left_edge, divider),
        .launch => box(layout, divider + gap, right_edge),
    };
    return .{ .x = panel.x, .y = @intCast(layout.point(.{ 0, 391 })[1]), .width = control_width, .height = control_height };
}

fn canLaunch(lobby: *const Lobby) bool {
    return lobby.role == .host and lobby.role.host.can_launch;
}

pub fn frame(lobby: *Lobby, pointer: ui.Pointer, keys: *input.Keyboard, window: [2]u32) ?Action {
    const layout = Layout.init(window);
    const at = layout.point(pointer.at);
    lobby.hover = if (control(layout, .leave).holds(at)) .leave else if (lobby.canLaunch() and control(layout, .launch).holds(at)) .launch else null;
    if (keys.pressed(input.scan.escape, .none, true)) return .leave;
    return if (pointer.down) lobby.hover else null;
}

pub fn draw(lobby: *const Lobby, original: ui.Canvas, art: *hud.Art) !void {
    const layout = Layout.init(original.window);
    var canvas = original;
    canvas.share = layout.share;
    const players_box = box(layout, left_edge, divider);
    const game_box = box(layout, divider + gap, right_edge);
    try widgets.title(canvas, layout.title(), if (lobby.role == .host) host_title else guest_title);
    widgets.panel(canvas, players_box);
    widgets.panel(canvas, game_box);
    try lobby.drawPlayers(canvas, players_box);
    try lobby.drawGame(canvas, game_box);
    const leave: Label = .{ .english = if (lobby.role == .host) "STOP HOSTING" else "LEAVE GAME" };
    try widgets.button(canvas, art, control(layout, .leave), leave, true, lobby.hover == .leave);
    if (lobby.role == .host) try widgets.button(canvas, art, control(layout, .launch), launch_label, lobby.canLaunch(), lobby.hover == .launch);
}

fn drawPlayers(lobby: *const Lobby, canvas: ui.Canvas, panel: ui.Rect) !void {
    const font = canvas.fonts.small;
    const inset = Layout.footer_inset;
    const left = panel.x + inset;
    const right = panel.x + panel.width - inset;
    const strings = canvas.strings.*;
    try canvas.text(font, .{ left, panel.y + heading_y }, players_label.text(strings), ui.white, .left);
    var count: usize = 0;
    for (lobby.roster) |entry| if (entry != null) {
        count += 1;
    };
    var count_buf: [64]u8 = undefined;
    const population = std.fmt.bufPrint(&count_buf, "{d} / {d}", .{ count, lobby.roster.len }) catch unreachable;
    try canvas.text(font, .{ right, panel.y + heading_y }, population, ui.blue, .right);
    canvas.line(.{ left, panel.y + first_row - heading_y }, .{ right, panel.y + first_row - heading_y }, hud.rgb(0x324A55));
    const host = host_label.text(strings);
    const tags_width: i16 = @intCast(@max(font.textWidth(host), font.textWidth("YOU")));
    var y = panel.y + first_row;
    for (lobby.roster, 0..) |entry, slot| {
        const name = entry orelse continue;
        var fallback: [64]u8 = undefined;
        const words = if (name.len != 0) name.slice() else std.fmt.bufPrint(&fallback, "{s} {d}", .{ fallback_player.text(strings), slot + 1 }) catch fallback_player.text(strings);
        if (slot == lobby.local_slot) canvas.wipe(.{ left - 3, y - 3 }, .{ right + 3, y + row_height - 5 }, hud.rgb(0x193C4C));
        try widgets.fittedLabel(canvas, .{ left, y }, right - left - tags_width - inset, words, ui.white, .left);
        if (slot == 0 or slot == lobby.local_slot) try canvas.text(font, .{ right, y }, if (slot == 0) host else "YOU", ui.blue, .right);
        y += row_height;
    }
}

fn drawGame(lobby: *const Lobby, canvas: ui.Canvas, panel: ui.Rect) !void {
    const font = canvas.fonts.small;
    const strings = canvas.strings.*;
    const inset = Layout.footer_inset;
    const x = panel.x + inset;
    const width = panel.width - 2 * inset;
    try widgets.fittedLabel(canvas, .{ x, panel.y + heading_y }, width, scenario_label.text(strings), ui.white, .left);
    try widgets.fittedLabel(canvas, .{ x, panel.y + first_row }, width, lobby.scenario.text(strings), ui.blue, .left);
    try widgets.fittedLabel(canvas, .{ x, panel.y + first_row + 2 * row_height }, width, ship_label.text(strings), ui.white, .left);
    try widgets.fittedLabel(canvas, .{ x, panel.y + first_row + 3 * row_height }, width, lobby.ship.text(strings), ui.blue, .left);
    var buffer: [128]u8 = undefined;
    const status = switch (lobby.role) {
        .host => |host| std.fmt.bufPrint(&buffer, "Join by LAN IP (UDP {d})", .{host.port}) catch unreachable,
        .guest => std.fmt.bufPrint(&buffer, "{s} {s}", .{ waiting_label.text(strings), for_host_label.text(strings) }) catch "Waiting for host",
    };
    try canvas.wrapped(font, .{ x, panel.y + panel.height - inset - 2 * line_height }, status, ui.blue, .left, .{ .width = width, .height = line_height, .most = 2 });
}

test "the launch control belongs to a host that has joined its lobby" {
    const window = [2]u32{ 640, 480 };
    const layout = Layout.init(window);
    const click: ui.Pointer = .{ .at = control(layout, .launch).centre(), .down = true };
    var keys: input.Keyboard = .{};
    var lobby: Lobby = .{ .role = .guest, .roster = &.{}, .local_slot = 1, .scenario = .{}, .ship = .{} };
    try std.testing.expectEqual(null, lobby.frame(click, &keys, window));
    lobby.role = .{ .host = .{ .port = 27020 } };
    try std.testing.expectEqual(null, lobby.frame(click, &keys, window));
    lobby.role.host.can_launch = true;
    try std.testing.expectEqual(.launch, lobby.frame(click, &keys, window).?);
    try std.testing.expectEqual(.leave, lobby.frame(.{ .at = control(layout, .leave).centre(), .down = true }, &keys, window).?);
}
