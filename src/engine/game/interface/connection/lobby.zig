//! **Improvement:** OpenReliant combines game setup and the waiting roster, as the original
//! deathmatch loadout (`session_loadout_screen`, 0x0044B950) does. The host starts the match here.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const chat = @import("../../chat.zig");
pub const chat_panel = @import("chat_panel.zig");
const Typed = @import("../../winmain.zig").Typed;
const input = @import("../../../input.zig");
const scenarios = @import("../../dmscenarios.zig");
const CallSign = @import("../pilot_roster.zig").CallSign;
const Layout = @import("layout.zig");
const widgets = @import("widgets.zig");
const choices = @import("choice_list.zig");
const ShipPicker = @import("ship_picker.zig");
const pager_widgets = @import("../settings/widgets.zig");
const Label = widgets.Label;
const Lobby = @This();
pub const History = chat_panel.History;

const Control = enum { leave, launch };
const Field = enum { scenario, ship };
pub const Action = union(enum) { leave, launch, choose_ship, send_chat: chat.Line };
const Role = union(enum) { host: struct { can_launch: bool = false, port: u16 }, guest };

role: Role,
roster: []const ?CallSign,
notices: ?*const History = null,
editor: chat_panel.Editor = .{},
local_slot: usize,
scenario: scenarios.Scenario = .nuclear_threat,
mission: ?u16 = null,
ship: scenarios.Fighter = .predator,
hover: ?Control = null,
mode_open: bool = false,
option_under: ?usize = null,
preview: scenarios.Scenario = .nuclear_threat,
first_pilot: usize = 0,
page_under: ?pager_widgets.Step = null,

const panel_top = 153;
const panel_bottom = 291;
const chat_top = 297;
const chat_bottom = 408;
const left_edge = 48;
const divider = 343;
const right_edge = 592;
const gap = 14;
const heading_y = 9;
const heading_height = 34;
const first_row = heading_height + heading_y;
const row_height = 21;
const RosterWindow = ui.Scrolled(usize);
const line_height = 17;
const control_height = 20;
const control_width = 180;

const host_title: Label = .{ .english = "DEATHMATCH HOST", .installed = 0x2C1 };
const guest_title: Label = .{ .english = "DEATHMATCH JOIN", .installed = 0x2D3 };
const coop_title: Label = .{ .english = "CO-OP", .installed = 0x13D };
const players_label: Label = .{ .english = "PLAYERS", .installed = 0x141 };
const fallback_player: Label = .{ .english = "PILOT", .installed = 0xBF };
const host_label: Label = .{ .english = "HOST", .installed = 0x13C };
const launch_label: Label = .{ .english = "START GAME", .installed = 0xB9 };
const scenario_label: Label = .{ .english = "GAME TYPE", .installed = 0x139 };
const mission_label: Label = .{ .english = "MISSION" };
const ship_label: Label = .{ .english = "SHIP", .installed = 0x2C3 };
const waiting_label: Label = .{ .english = "WAITING", .installed = 0x30E };
const for_host_label: Label = .{ .english = "FOR HOST", .installed = 0x30F };
const change_mode: Label = .{ .english = "CHANGE GAME MODE" };
const select_mode: Label = .{ .english = "SELECT MODE" };
const cancel: Label = .{ .english = "CANCEL" };
const team_play: Label = .{ .english = "TEAM PLAY", .installed = 0x2C6 };
const modal_rows: ui.Rect = .{ .x = 72, .y = 168, .width = 168, .height = choices.height * scenario_options.len };
const details_y = 194;
const details_lines: ui.Canvas.Lines = .{ .width = 302, .height = 15, .most = 8 };
const team_heading_y = details_y + details_lines.height * details_lines.most + 4;
const modal_actions_y = team_heading_y + 53;
const modal_select: ui.Rect = .{ .x = 261, .y = modal_actions_y, .width = 160, .height = control_height };
const modal_cancel: ui.Rect = .{ .x = 72, .y = modal_actions_y, .width = 160, .height = control_height };

const scenario_options = options: {
    var options: [std.enums.values(scenarios.Scenario).len]Label = undefined;
    for (std.enums.values(scenarios.Scenario), &options) |scenario, *option| {
        option.* = .{ .english = scenario.record().name, .installed = scenario.nameString() };
    }
    break :options options;
};

fn box(layout: Layout, x: i16, right: i16) ui.Rect {
    const left, const top = layout.point(.{ x, panel_top });
    const end, const bottom = layout.point(.{ right, panel_bottom });
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(end - left), .height = @intCast(bottom - top) };
}

fn control(layout: Layout, action: Control) ui.Rect {
    const panel = switch (action) {
        .leave => box(layout, left_edge, divider),
        .launch => box(layout, divider + gap, right_edge),
    };
    return .{ .x = panel.x, .y = @intCast(layout.point(.{ 0, 415 })[1]), .width = control_width, .height = control_height };
}

fn fieldBox(layout: Layout, field: Field) ui.Rect {
    const panel = box(layout, divider + gap, right_edge);
    const inset = Layout.footer_inset;
    return .{ .x = panel.x + inset, .y = panel.y + switch (field) {
        .scenario => @as(i16, 28),
        .ship => 95,
    }, .width = panel.width - 2 * inset, .height = choices.height };
}

fn modeFrame(lobby: *Lobby, pointer: ui.Pointer, escape: bool) void {
    lobby.option_under = choices.hit(modal_rows, pointer.at);
    if (escape) {
        lobby.mode_open = false;
    } else if (pointer.down) {
        if (lobby.option_under) |index| {
            lobby.preview = @fromBackingInt(@intCast(index));
        } else if (modal_cancel.holds(pointer.at)) {
            lobby.mode_open = false;
        } else if (modal_select.holds(pointer.at)) {
            lobby.scenario = lobby.preview;
            lobby.mode_open = false;
        }
    }
}

fn canLaunch(lobby: *const Lobby) bool {
    return lobby.role == .host and lobby.role.host.can_launch;
}

fn playerWindow(lobby: *const Lobby, panel: ui.Rect) RosterWindow {
    var count: usize = 0;
    for (lobby.roster) |entry| count += @intFromBool(entry != null);
    const shown: usize = @intCast(@divFloor(@max(panel.height - first_row - Layout.footer_inset, 0), row_height));
    return .{ .first = @min(lobby.first_pilot, count -| shown), .count = count, .shown = shown };
}

fn playerPager(panel: ui.Rect) pager_widgets.Line {
    const top = @divFloor(heading_height - pager_widgets.Line.arrows_height, 2);
    return .withArrowsAt(.{ panel.x + panel.width - 100, panel.y + top });
}

fn scrollPlayers(lobby: *Lobby, panel: ui.Rect, at: Layout.Point, pointer: ui.Pointer) void {
    var list = lobby.playerWindow(panel);
    lobby.page_under = null;
    if (list.count > list.shown and panel.holds(at)) {
        list.wheel(pointer.wheel);
        if (playerPager(panel).arrowAt(at)) |arrow| {
            if (arrow == .back and list.first > 0 or arrow == .on and list.end() < list.count) {
                lobby.page_under = arrow;
                if (pointer.down) list.scroll(if (arrow == .back) .up else .down);
            }
        }
    }
    lobby.first_pilot = list.first;
}

pub fn frame(lobby: *Lobby, pointer: ui.Pointer, keys: *input.Keyboard, typed: *Typed, window: [2]u32) ?Action {
    const layout = Layout.init(window);
    const at = layout.point(pointer.at);
    const escape = keys.pressed(input.scan.escape, .none, true);
    if (lobby.mode_open) {
        typed.clear();
        lobby.modeFrame(pointer, escape);
        return null;
    }
    lobby.scrollPlayers(box(layout, left_edge, divider), at, pointer);
    const was_focused = lobby.editor.focused;
    var chat_pointer = pointer;
    chat_pointer.at = at;
    if (lobby.editor.frame(chatPanel(layout), chat_pointer, keys, typed, escape)) |line| return .{ .send_chat = line };
    if (lobby.editor.focused or (escape and was_focused)) return null;
    lobby.hover = if (control(layout, .leave).holds(at)) .leave else if (lobby.canLaunch() and control(layout, .launch).holds(at)) .launch else null;
    if (escape) return .leave;
    if (!pointer.down) return null;
    if (lobby.hover) |hover| return switch (hover) {
        .leave => .leave,
        .launch => .launch,
    };
    if (lobby.mission == null and fieldBox(layout, .ship).holds(at)) return .choose_ship;
    if (lobby.mission == null and lobby.role == .host and modeButton(layout).holds(at)) {
        lobby.mode_open = true;
        lobby.preview = lobby.scenario;
        lobby.option_under = null;
    }
    return null;
}

pub fn draw(lobby: *const Lobby, original: ui.Canvas, art: *hud.Art, paging_art: ?*hud.Art) !void {
    const layout = Layout.init(original.window);
    var canvas = original;
    canvas.share = layout.share;
    const players_box = box(layout, left_edge, divider);
    const game_box = box(layout, divider + gap, right_edge);
    try widgets.title(canvas, layout.title(), if (lobby.mission != null) coop_title else if (lobby.role == .host) host_title else guest_title);
    widgets.panel(canvas, players_box);
    widgets.panel(canvas, game_box);
    try lobby.drawPlayers(canvas, players_box, paging_art);
    try lobby.drawGame(canvas, game_box, layout, art);
    try chat_panel.draw(canvas, chatPanel(layout), lobby.notices, &lobby.editor);
    const leave: Label = .{ .english = if (lobby.role == .host) "STOP HOSTING" else "LEAVE GAME" };
    try widgets.button(canvas, art, control(layout, .leave), leave, true, lobby.hover == .leave);
    if (lobby.role == .host) try widgets.button(canvas, art, control(layout, .launch), launch_label, lobby.canLaunch(), lobby.hover == .launch);
    if (lobby.mode_open) try lobby.drawModes(original, art);
}

fn modeButton(layout: Layout) ui.Rect {
    var rect = fieldBox(layout, .scenario);
    rect.y += choices.height + 5;
    return rect;
}

fn description(mode: scenarios.Scenario) Label {
    return .{ .english = mode.record().description, .installed = mode.descriptionString() };
}

fn drawModes(lobby: *const Lobby, canvas: ui.Canvas, art: *hud.Art) !void {
    const top = 107;
    const modal: ui.Rect = .{ .x = 44, .y = top, .width = 552, .height = modal_actions_y + 35 - top };
    widgets.modal(canvas, modal);
    try widgets.title(canvas, .{ 72, 122 }, change_mode);
    try choices.drawList(canvas, modal_rows, &scenario_options, @backingInt(lobby.preview), lobby.option_under);
    const strings = canvas.strings.*;
    const heading = scenario_options[@backingInt(lobby.preview)];
    try canvas.text(canvas.fonts.small, .{ 261, modal_rows.y + 3 }, heading.text(strings), ui.white, .left);
    try canvas.wrapped(canvas.fonts.small, .{ 261, details_y }, description(lobby.preview).text(strings), ui.blue, .left, details_lines);
    try canvas.text(canvas.fonts.small, .{ 261, team_heading_y }, team_play.text(strings), ui.white, .left);
    const teams: Label = .{ .installed = lobby.preview.teamPlayString(), .english = switch (lobby.preview.record().teams) {
        .most_frags => "The team with the most frags wins.",
        .controls_tower => "The tower cannot target the team carrying the relay.",
        .none => "No.",
    } };
    try canvas.wrapped(canvas.fonts.small, .{ 261, team_heading_y + 15 }, teams.text(strings), ui.blue, .left, .{ .width = 302, .height = 14, .most = 2 });
    try widgets.button(canvas, art, modal_cancel, cancel, true, false);
    try widgets.button(canvas, art, modal_select, select_mode, true, false);
}

fn drawPlayers(lobby: *const Lobby, canvas: ui.Canvas, panel: ui.Rect, paging_art: ?*hud.Art) !void {
    const font = canvas.fonts.small;
    const inset = Layout.footer_inset;
    const left = panel.x + inset;
    const right = panel.x + panel.width - inset;
    const strings = canvas.strings.*;
    try canvas.text(font, .{ left, panel.y + heading_y }, players_label.text(strings), ui.white, .left);
    const list = lobby.playerWindow(panel);
    var count_buf: [64]u8 = undefined;
    const population = std.fmt.bufPrint(&count_buf, "{d} / {d}", .{ list.count, lobby.roster.len }) catch unreachable;
    try canvas.text(font, .{ right, panel.y + heading_y }, population, ui.blue, .right);
    if (list.count > list.shown) {
        const pager = playerPager(panel);
        if (paging_art) |art| {
            try pager.drawArrows(canvas, art);
            if (lobby.page_under) |under| try pager.drawLit(canvas, art, under);
        } else {
            for ([_]pager_widgets.Step{ .back, .on }, [_][]const u8{ "<", ">" }) |arrow, label| {
                try canvas.text(font, .{ pager.arrow(arrow).centre()[0], panel.y + heading_y }, label, ui.blue, .centre);
            }
        }
    }
    canvas.line(.{ left, panel.y + heading_height }, .{ right, panel.y + heading_height }, hud.rgb(0x324A55));
    const host = host_label.text(strings);
    const tags_width: i16 = @intCast(@max(font.textWidth(host), font.textWidth("YOU")));
    const rows = canvas.within(.{ .x = panel.x, .y = panel.y + first_row - 3, .width = panel.width, .height = @intCast(list.shown * row_height) });
    var row: usize = 0;
    for (lobby.roster, 0..) |entry, slot| {
        const name = entry orelse continue;
        defer row += 1;
        if (row < list.first) continue;
        if (row == list.end()) break;
        const y = panel.y + first_row + @as(i16, @intCast(row - list.first)) * row_height;
        var fallback: [64]u8 = undefined;
        const words = if (name.len != 0) name.slice() else std.fmt.bufPrint(&fallback, "{s} {d}", .{ fallback_player.text(strings), slot + 1 }) catch fallback_player.text(strings);
        if (slot == lobby.local_slot) rows.wipe(.{ left - 3, y - 3 }, .{ right + 3, y + row_height - 5 }, hud.rgb(0x193C4C));
        try widgets.fittedLabel(rows, .{ left, y }, right - left - tags_width - inset, words, ui.white, .left);
        if (slot == 0 or slot == lobby.local_slot) try rows.text(font, .{ right, y }, if (slot == 0) host else "YOU", ui.blue, .right);
    }
}

fn chatPanel(layout: Layout) ui.Rect {
    const left, const top = layout.point(.{ left_edge, chat_top });
    const right, const bottom = layout.point(.{ right_edge, chat_bottom });
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

fn drawGame(lobby: *const Lobby, canvas: ui.Canvas, panel: ui.Rect, layout: Layout, art: *hud.Art) !void {
    const font = canvas.fonts.small;
    const strings = canvas.strings.*;
    const inset = Layout.footer_inset;
    const x = panel.x + inset;
    const width = panel.width - 2 * inset;
    const heading = if (lobby.mission != null) mission_label else scenario_label;
    try widgets.fittedLabel(canvas, .{ x, panel.y + heading_y }, width, heading.text(strings), ui.white, .left);
    const mode = fieldBox(layout, .scenario);
    const ship = fieldBox(layout, .ship);
    if (lobby.mission) |number| {
        var name: [32]u8 = undefined;
        try widgets.fittedLabel(canvas, .{ x, mode.y }, width, std.fmt.bufPrint(&name, "{s} {d}", .{ mission_label.text(strings), number }) catch unreachable, ui.blue, .left);
    } else {
        try widgets.fittedLabel(canvas, .{ x, mode.y }, width, scenario_options[@backingInt(lobby.scenario)].text(strings), ui.blue, .left);
        if (lobby.role == .host) try widgets.button(canvas, art, modeButton(layout), change_mode, true, lobby.mode_open);
        try widgets.fittedLabel(canvas, .{ x, ship.y - 18 }, width, ship_label.text(strings), ui.white, .left);
        try widgets.button(canvas, art, ship, ShipPicker.label(lobby.ship), true, false);
    }
    var buffer: [128]u8 = undefined;
    const status = switch (lobby.role) {
        .host => |host| std.fmt.bufPrint(&buffer, "Join by LAN IP (UDP {d})", .{host.port}) catch unreachable,
        .guest => std.fmt.bufPrint(&buffer, "{s} {s}", .{ waiting_label.text(strings), for_host_label.text(strings) }) catch "Waiting for host",
    };
    try canvas.wrapped(font, .{ x, panel.y + panel.height - inset - line_height }, status, ui.blue, .left, .{ .width = width, .height = line_height, .most = 2 });
}

test "the launch control belongs to a host that has joined its lobby" {
    const window = [2]u32{ 640, 480 };
    const layout = Layout.init(window);
    const click: ui.Pointer = .{ .at = control(layout, .launch).centre(), .down = true };
    var keys: input.Keyboard = .{};
    var typed: Typed = .{};
    var lobby: Lobby = .{ .role = .guest, .roster = &.{}, .local_slot = 1 };
    try std.testing.expectEqual(null, lobby.frame(click, &keys, &typed, window));
    lobby.role = .{ .host = .{ .port = 27020 } };
    try std.testing.expectEqual(null, lobby.frame(click, &keys, &typed, window));
    lobby.role.host.can_launch = true;
    try std.testing.expect(lobby.frame(click, &keys, &typed, window).? == .launch);
    try std.testing.expect(lobby.frame(.{ .at = control(layout, .leave).centre(), .down = true }, &keys, &typed, window).? == .leave);
}

test "guests can choose a ship, while only the host can open the scenario selector" {
    const window = [2]u32{ 640, 480 };
    const layout = Layout.init(window);
    var lobby: Lobby = .{ .role = .guest, .roster = &.{}, .local_slot = 1 };
    var keys: input.Keyboard = .{};
    var typed: Typed = .{};
    const mode = modeButton(layout);
    try std.testing.expectEqual(null, lobby.frame(.{ .at = mode.centre(), .down = true }, &keys, &typed, window));
    try std.testing.expect(!lobby.mode_open);
    const ship = fieldBox(layout, .ship);
    try std.testing.expectEqual(.choose_ship, lobby.frame(.{ .at = ship.centre(), .down = true }, &keys, &typed, window).?);
}

test "the lobby scrolls a full roster within the player panel and clamps after departures" {
    const names: [8]?CallSign = @splat(.{});
    const window: [2]u32 = .{ 800, 600 };
    const panel = box(.init(window), left_edge, divider);
    var lobby: Lobby = .{ .role = .guest, .roster = &names, .local_slot = 7 };
    const beginning = lobby.playerWindow(panel);
    try std.testing.expect(beginning.shown >= 1 and beginning.end() < names.len);
    try std.testing.expect(first_row + beginning.shown * row_height < @as(usize, @intCast(panel.height)));
    lobby.scrollPlayers(panel, panel.centre(), .{ .wheel = -8 });
    try std.testing.expectEqual(names.len, lobby.playerWindow(panel).end());
    const back = playerPager(panel).arrow(.back).centre();
    lobby.scrollPlayers(panel, back, .{ .down = true });
    try std.testing.expectEqual(names.len - 1, lobby.playerWindow(panel).end());
    lobby.roster = names[0..2];
    lobby.scrollPlayers(panel, panel.centre(), .{});
    try std.testing.expectEqual(0, lobby.first_pilot);
}

test {
    std.testing.refAllDecls(@This());
}
