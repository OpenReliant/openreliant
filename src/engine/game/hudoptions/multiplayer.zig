//! Multiplayer pause controls in the OpenReliant menu style.
const std = @import("std");
const hud = @import("../hud.zig");
const input = @import("../../input.zig");
const Objects = @import("../create.zig").Objects;
const chat = @import("../chat.zig");
const Typed = @import("../winmain.zig").Typed;
const ui = @import("../interface/canvas.zig");
const chat_panel = @import("../interface/connection/chat_panel.zig");
const widgets = @import("../interface/connection/widgets.zig");
const settings = @import("../interface/settings/widgets.zig");
const players = @import("../players.zig");
const CallSign = @import("../interface/pilot_roster.zig").CallSign;
const Label = widgets.Label;

pub const History = chat_panel.History;
pub const Action = union(enum) { resume_match, leave_match, send_chat: chat.Line, drop: players.ParticipantRef };

pub const Player = struct {
    generation: u64,
    name: CallSign = .{},
    can_drop: bool = false,
};

pub const View = union(enum) {
    match: Match,
    lost: Label,
};

pub const Match = struct {
    all: *const Objects,
    history: *const History,
    players: []const ?Player,
    paused_by: ?[]const u8 = null,
    can_continue: bool = true,
};

const panel: ui.Rect = .{ .x = 66, .y = 69, .width = 508, .height = 342 };
const chat_box: ui.Rect = .{ .x = 84, .y = 228, .width = 472, .height = 128 };
const leave_button: ui.Rect = .{ .x = 84, .y = 374, .width = 212, .height = 21 };
const continue_button: ui.Rect = .{ .x = 338, .y = 374, .width = 218, .height = 21 };
const lost_box: ui.Rect = .{ .x = 112, .y = 166, .width = 416, .height = 148 };
const ok_button: ui.Rect = .{ .x = 134, .y = 275, .width = 160, .height = 21 };
const scores_y = 142;
const row_height = 21;
const first_row = scores_y + row_height;
const pilot_x = 112;
const kills_x = 300;
const deaths_x = 363;
const ping_x = 425;
const drop_x = 458;
const drop_width = 90;
const label_width = 190;
const cell_width = 58;
const base_rows = @divTrunc(chat_box.y - first_row, row_height);
const min_margin = 30;
const extra_vertical_room = 2 * @as(i16, @min(panel.y - min_margin, ui.size[1] - panel.y - panel.height - min_margin));
const expandable_rows = @divTrunc(extra_vertical_room, row_height);
const score_area: ui.Rect = .{ .x = chat_box.x, .y = scores_y, .width = chat_box.width, .height = chat_box.y - scores_y };
const page_arrows_at = .{ 523, scores_y - 10 };
const range_x = 514;
const range_width = 56;
const ScoreWindow = hud.standings.Scroll;

const Layout = struct {
    dy: i16,
    extra: i16,
    rows: usize,

    fn fit(count: usize) Layout {
        const added: i16 = @intCast(@min(count -| base_rows, expandable_rows));
        const extra = added * row_height;
        return .{ .dy = -@divTrunc(extra, 2), .extra = extra, .rows = base_rows + @as(usize, @intCast(added)) };
    }

    fn raised(layout: Layout, box: ui.Rect) ui.Rect {
        var moved = box;
        moved.y += layout.dy;
        return moved;
    }

    fn lowered(layout: Layout, box: ui.Rect) ui.Rect {
        var moved = layout.raised(box);
        moved.y += layout.extra;
        return moved;
    }

    fn grown(layout: Layout, box: ui.Rect) ui.Rect {
        var enlarged = layout.raised(box);
        enlarged.height += layout.extra;
        return enlarged;
    }

    fn rowY(layout: Layout, index: usize) i16 {
        return first_row + layout.dy + row_height * @as(i16, @intCast(index));
    }

    fn pager(layout: Layout) settings.Line {
        return .withArrowsAt(.{ page_arrows_at[0], page_arrows_at[1] + layout.dy });
    }
};

const paused: Label = .{ .english = "PAUSED", .installed = 0xA9 };
const match_menu: Label = .{ .english = "MATCH MENU" };
const match_running: Label = .{ .english = "Match in progress" };
const pause_notice: Label = .{ .english = "Player has paused the game", .installed = 0x53E };
const continue_label: Label = .{ .english = "CONTINUE", .installed = 0x180 };
const leave_label: Label = .{ .english = "LEAVE MISSION", .installed = 0x32B };
const loss_title: Label = .{ .english = "SESSION ENDED" };
const ok_label: Label = .{ .english = "OK", .installed = 0x316 };
const drop_label: Label = .{ .english = "Drop" };
const pilot_label: Label = .{ .english = "Pilot", .installed = 0xBF };

pub const ControlFrame = struct {
    devices: *input.Devices,
    typed: *Typed,
    window: [2]u32,
    scale: hud.UiScale,
    elapsed: i32,
    standings_scale: f32 = 1,
};

pub const State = struct {
    pointer: ui.Pointer = .{},
    press: input.FreshPress = .{},
    editor: chat_panel.Editor = .{},
    confirming_loss: bool = false,
    first_score: usize = 0,

    /// `pause_screen_multiplayer` (0x0048E510) handles Continue, Leave Mission and the chat field.
    /// `pause_session_lost` (0x0048E370) waits for acknowledgment before leaving.
    pub fn frame(state: *State, view: View, controls: ControlFrame) ?Action {
        const was_down = state.pointer.down;
        state.pointer.update(&controls.devices.mouse, controls.window, controls.scale.share(), controls.elapsed);
        var pointer = state.pointer;
        pointer.down = state.press.pressed(pointer.down) and !was_down;
        const keys = &controls.devices.keyboard;
        const escape = keys.pressed(input.scan.escape, .none, true);
        switch (view) {
            .lost => {
                if (pointer.down) state.confirming_loss = ok_button.holds(pointer.at);
                return if (escape or (state.confirming_loss and !state.pointer.down)) .leave_match else null;
            },
            .match => |game| {
                const count = activePlayers(game.players);
                const layout: Layout = .fit(count);
                const was_focused = state.editor.focused;
                // mission_paused_frame (0x004920A9) opens an all-pilots chat draft.
                if (!escape and !was_focused and controls.devices.active(.send_comms_message, true)) {
                    controls.typed.clear();
                    state.editor.focused = true;
                }
                if (state.editor.frame(layout.lowered(chat_box), pointer, keys, controls.typed, escape)) |line| return .{ .send_chat = line };
                var scroll = hud.standings.scrollWindow(state.first_score, count, layout.rows);
                if (count > layout.rows) {
                    if (layout.grown(score_area).holds(pointer.at)) hud.standings.scrollWheel(&scroll, pointer.wheel);
                    if (!state.editor.focused) {
                        if (keys.pressed(input.scan.up, .none, true)) scroll.scroll(.up);
                        if (keys.pressed(input.scan.down, .none, true)) scroll.scroll(.down);
                        const clicked = if (pointer.down) layout.pager().arrowAt(pointer.at) else null;
                        if (clicked == .back or keys.pressed(@backingInt(input.Key.page_up), .none, true)) hud.standings.scrollPage(&scroll, .up);
                        if (clicked == .on or keys.pressed(@backingInt(input.Key.page_down), .none, true)) hud.standings.scrollPage(&scroll, .down);
                    }
                }
                state.first_score = scroll.first;
                if (state.editor.focused or (escape and was_focused)) return null;
                if (game.can_continue and (escape or (pointer.down and layout.lowered(continue_button).holds(pointer.at)))) return .resume_match;
                if (!pointer.down) return null;
                if (layout.lowered(leave_button).holds(pointer.at)) return .leave_match;

                var scores: Scores = undefined;
                const rows = scores.collect(game);
                for (rows[scroll.first..scroll.end()], 0..) |row, index| {
                    if (game.players[row.slot].?.can_drop and dropButton(layout.rowY(index)).holds(pointer.at))
                        return .{ .drop = .{ .slot = @intCast(row.slot), .generation = row.pilot.generation } };
                }
                return null;
            },
        }
    }

    pub fn draw(state: *const State, view: View, canvas: ui.Canvas, art: *hud.Art, paging_art: ?*hud.Art) !void {
        hud.drawFilled(canvas.target, .{ .left = 0, .top = 0, .right = @floatFromInt(canvas.window[0]), .bottom = @floatFromInt(canvas.window[1]) }, @import("../hudoptions.zig").shade);
        switch (view) {
            .match => |game| {
                const layout: Layout = .fit(activePlayers(game.players));
                widgets.panel(canvas, layout.grown(panel));
                try widgets.title(canvas, .{ 84, 87 + layout.dy }, if (game.paused_by != null) paused else match_menu);
                var notice: [160]u8 = undefined;
                const status = if (game.paused_by) |name|
                    std.fmt.bufPrint(&notice, "{s}: {s}", .{ name, pause_notice.text(canvas.strings.*) }) catch pause_notice.text(canvas.strings.*)
                else
                    match_running.text(canvas.strings.*);
                try widgets.fittedLabel(canvas, .{ 84, 118 + layout.dy }, chat_box.width, status, ui.blue, .left);
                try state.drawScores(game, canvas, art, paging_art, layout);
                try chat_panel.draw(canvas, layout.lowered(chat_box), game.history, &state.editor);
                try state.button(canvas, art, layout.lowered(leave_button), leave_label, true);
                try state.button(canvas, art, layout.lowered(continue_button), continue_label, game.can_continue);
            },
            .lost => |reason| {
                widgets.modal(canvas, lost_box);
                try widgets.title(canvas, .{ 134, 187 }, loss_title);
                try canvas.wrapped(canvas.fonts.small, .{ 134, 221 }, reason.text(canvas.strings.*), ui.blue, .left, .{ .width = 372, .height = 15, .most = 3 });
                try state.button(canvas, art, ok_button, ok_label, true);
            },
        }
    }

    pub fn drawPointer(state: *const State, canvas: ui.Canvas, art: *hud.Art) !void {
        try canvas.drawPointer(art, state.pointer);
    }

    fn button(state: *const State, canvas: ui.Canvas, art: *hud.Art, box: ui.Rect, label: Label, enabled: bool) !void {
        try widgets.button(canvas, art, box, label, enabled, enabled and box.holds(state.pointer.at));
    }

    fn drawScores(state: *const State, game: Match, canvas: ui.Canvas, art: *hud.Art, paging_art: ?*hud.Art, layout: Layout) !void {
        const Column = struct { x: i16, label: Label, alignment: hud.Align = .centre };
        const columns = [_]Column{
            .{ .x = pilot_x, .label = pilot_label, .alignment = .left },
            .{ .x = kills_x, .label = .{ .english = "Kills", .installed = 0x308 } },
            .{ .x = deaths_x, .label = .{ .english = "Deaths", .installed = 0x307 } },
            .{ .x = ping_x, .label = .{ .english = "Ping", .installed = 0x559 } },
        };
        for (columns) |column| try widgets.fittedLabel(canvas, .{ column.x, scores_y + layout.dy }, cell_width, column.label.text(canvas.strings.*), ui.white, column.alignment);
        const divider_y = layout.rowY(0) - 5;
        canvas.line(.{ chat_box.x, divider_y }, .{ chat_box.x + chat_box.width, divider_y }, ui.blue);

        var scores: Scores = undefined;
        const rows = scores.collect(game);
        const scroll = hud.standings.scrollWindow(state.first_score, rows.len, layout.rows);
        if (rows.len > layout.rows) try state.drawScroll(canvas, scroll, layout, paging_art);
        const score_canvas = canvas.within(layout.grown(score_area));
        for (rows[scroll.first..scroll.end()], 0..) |row, index| {
            const y = layout.rowY(index);
            var fallback: [64]u8 = undefined;
            const pilot = row.pilot.name.slice();
            const label = pilot_label.text(canvas.strings.*);
            const name = if (pilot.len != 0) pilot else std.fmt.bufPrint(&fallback, "{s} {d}", .{ label, row.slot + 1 }) catch label;
            try number(score_canvas, .{ 96, y }, scroll.first + index + 1);
            try widgets.fittedLabel(score_canvas, .{ pilot_x, y }, label_width, name, ui.white, .left);
            try number(score_canvas, .{ kills_x, y }, row.pilot.kills.count);
            try number(score_canvas, .{ deaths_x, y }, row.pilot.deaths);
            if (row.pilot.ping_ms) |ping| {
                try number(score_canvas, .{ ping_x, y }, ping);
            } else {
                try score_canvas.text(canvas.fonts.small, .{ ping_x, y }, "-", ui.blue, .centre);
            }
            if (game.players[row.slot].?.can_drop) try state.button(score_canvas, art, dropButton(y), drop_label, true);
        }
    }

    fn drawScroll(state: *const State, canvas: ui.Canvas, scroll: ScoreWindow, layout: Layout, paging_art: ?*hud.Art) !void {
        const pager = layout.pager();
        if (paging_art) |art| {
            try pager.drawArrows(canvas, art);
            if (pager.arrowAt(state.pointer.at)) |under| {
                const usable = switch (under) {
                    .back => scroll.first != 0,
                    .on => scroll.end() != scroll.count,
                };
                if (usable) try pager.drawLit(canvas, art, under);
            }
        } else {
            for ([_]settings.Step{ .back, .on }, [_][]const u8{ "<", ">" }) |step, glyph| {
                try canvas.text(canvas.fonts.small, .{ pager.arrow(step).centre()[0], scores_y + layout.dy }, glyph, ui.blue, .centre);
            }
        }
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}-{d}/{d}", .{ scroll.first + 1, scroll.end(), scroll.count }) catch unreachable;
        try widgets.fittedLabel(canvas, .{ range_x, scores_y + layout.dy }, range_width, text, ui.blue, .right);
    }
};

fn activePlayers(roster: []const ?Player) usize {
    var count: usize = 0;
    for (roster[0..@min(roster.len, hud.standings.max_pilots)]) |entry| {
        if (entry != null) count += 1;
    }
    return count;
}

fn number(canvas: ui.Canvas, at: [2]i32, value: anytype) !void {
    var buffer: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable;
    try canvas.text(canvas.fonts.small, at, text, ui.blue, .centre);
}

fn dropButton(y: i16) ui.Rect {
    return .{ .x = drop_x, .y = y, .width = drop_width, .height = row_height };
}

const Scores = struct {
    rows: [hud.standings.max_pilots]hud.standings.Row,
    defaults: [hud.standings.max_pilots]players.Membership.Joined,

    /// Membership comes from the roster because it can change while arena snapshots stand still.
    fn collect(scores: *Scores, game: Match) []const hud.standings.Row {
        var count: usize = 0;
        for (game.players[0..@min(game.players.len, scores.rows.len)], 0..) |entry, slot| {
            const pilot = entry orelse continue;
            const previous = &game.all.player_states[slot].membership;
            scores.rows[count] = .{ .slot = slot, .pilot = if (currentScore(previous, pilot.generation)) |score| score else initial: {
                scores.defaults[count] = .{ .generation = pilot.generation };
                scores.defaults[count].name.set(pilot.name.slice());
                break :initial &scores.defaults[count];
            } };
            count += 1;
        }
        return hud.standings.ordered(scores.rows[0..count]);
    }
};

fn currentScore(previous: *const players.Membership, generation: u64) ?*const players.Membership.Joined {
    if (previous.* != .joined or previous.joined.generation != generation) return null;
    return &previous.joined;
}

test "standings discard a score belonging to an earlier admission" {
    var membership: players.Membership = .{ .joined = .{ .generation = 9 } };
    try std.testing.expectEqual(null, currentScore(&membership, 10));
    membership.joined.generation = 10;
    try std.testing.expectEqual(10, currentScore(&membership, 10).?.generation);
}

test "large standings grow the panel, scroll before the chat and clamp after departures" {
    const players_in_test = 20;
    const layout: Layout = .fit(players_in_test);
    const last = hud.standings.scrollWindow(players_in_test, players_in_test, layout.rows);
    try std.testing.expect(layout.rows > base_rows);
    try std.testing.expectEqual(players_in_test - layout.rows, last.first);
    try std.testing.expectEqual(players_in_test, last.end());
    try std.testing.expect(layout.rowY(layout.rows - 1) + row_height <= layout.lowered(chat_box).y);
    const grown = layout.grown(panel);
    try std.testing.expect(grown.y >= min_margin);
    try std.testing.expect(grown.y + grown.height <= ui.size[1] - min_margin);
    const after_leave = hud.standings.scrollWindow(last.first, 1, Layout.fit(1).rows);
    try std.testing.expectEqual(0, after_leave.first);
    try std.testing.expectEqual(1, after_leave.end());
}

test "a shared pause guest cannot resume the simulation by pressing Escape" {
    var state: State = .{};
    var devices: input.Devices = .{};
    var typed: Typed = .{};
    const controls: ControlFrame = .{ .devices = &devices, .typed = &typed, .window = ui.size, .scale = .{}, .elapsed = 0 };
    var view: View = .{ .match = .{ .all = undefined, .history = undefined, .players = &.{}, .can_continue = false } };
    devices.keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, state.frame(view, controls));
    devices.keyboard.down[input.scan.escape] = false;
    devices.keyboard.read();
    view.match.can_continue = true;
    devices.keyboard.down[input.scan.escape] = true;
    try std.testing.expect(state.frame(view, controls).? == .resume_match);
}

test "the loss dialog accepts a fresh click when its button is released" {
    var state: State = .{};
    var devices: input.Devices = .{};
    var typed: Typed = .{};
    const controls: ControlFrame = .{ .devices = &devices, .typed = &typed, .window = ui.size, .scale = .{ .percent = 100 }, .elapsed = 0 };
    const view: View = .{ .lost = .{} };
    const at = ok_button.centre();
    devices.mouse.at = .{ @as(f32, @floatFromInt(at[0])) / ui.size[0], @as(f32, @floatFromInt(at[1])) / ui.size[1] };
    try std.testing.expectEqual(null, state.frame(view, controls));
    devices.mouse.buttons.left = true;
    try std.testing.expectEqual(null, state.frame(view, controls));
    devices.mouse.buttons.left = false;
    try std.testing.expect(state.frame(view, controls).? == .leave_match);
}
