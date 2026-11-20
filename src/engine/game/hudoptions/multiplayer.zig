//! The stock multiplayer pause and session-loss overlay.
const std = @import("std");
const hud = @import("../hud.zig");
const input = @import("../../input.zig");
const Objects = @import("../create.zig").Objects;
const chat = @import("../chat.zig");
const Typed = @import("../winmain.zig").Typed;
const ui = @import("../interface/canvas.zig");
const chat_panel = @import("../interface/connection/chat_panel.zig");
const widgets = @import("../interface/connection/widgets.zig");
const menu = @import("menu.zig");
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
    arena: bool = true,
    teams: hud.standings.TeamBoard = .{},
    players: []const ?Player,
    paused_by: ?[]const u8 = null,
    can_continue: bool = true,
};

// pause_screen_multiplayer (0x0048E510) adds 50 pixels to the in-flight scoreboard.
const scores_y = @as(comptime_int, ui.size[1]) / 2 - hud.standings.paused_rise;
const first_row = scores_y + hud.standings.first_row - 1;
const row_height = hud.standings.row_height;
const reject_x = ui.size[0] / 2 + hud.standings.reject_offset;
const chat_y = 396;
const score_area: ui.Rect = .{ .x = 87, .y = scores_y, .width = 522, .height = chat_y - scores_y };
const loss_box: ui.Rect = .{ .x = 80, .y = 180, .width = 480, .height = 120 };
const buttons = [_]menu.Item{
    .{ .anchor = .{ 0.5, 1 }, .offset = .{ 16, -32 }, .shape = .button, .lit = .button_lit, .font = .small, .string = .leave_mission, .text_offset = .{ 25, -5 } },
    .{ .anchor = .{ 0.5, 1 }, .offset = .{ -16, -32 }, .shape = .button, .lit = .button_lit, .font = .small, .string = .continue_game, .text_offset = .{ -25, -5 }, .style = .{ .alignment = .right } },
};
const session_lost_button: menu.Item = .{
    .anchor = .{ 0.5, 0.5 },
    .offset = .{ 0, 40 },
    .shape = .button,
    .lit = .button_lit,
    .font = .small,
    .string = .ok,
    .text_offset = .{ 25, -5 },
};
const paused: menu.String = @fromBackingInt(@intCast(0xA9));
const pause_notice: Label = .{ .english = "Player has paused the game", .installed = 0x53E };

pub const Art = struct {
    menu: *hud.Art,
    flight_font: *hud.Opened,
    scoreboard: ?*hud.Art,
    scoreboard_font: *hud.Opened,
    paging: ?*hud.Art,
};

pub const ControlFrame = struct {
    devices: *input.Devices,
    typed: *Typed,
    window: [2]u32,
    scale: hud.UiScale,
    standings_scale: f32 = 1,
    menu_art: ?*const hud.Art = null,
};

pub const State = struct {
    pointer: ui.Pointer = .{},
    press: input.FreshPress = .{},
    editor: chat_panel.Editor = .{},

    first_score: usize = 0,

    /// `pause_screen_multiplayer` (0x0048E510) handles Continue, Leave Mission and the chat field.
    /// `pause_session_lost` (0x0048E370) waits for acknowledgment before leaving.
    pub fn frame(state: *State, view: View, controls: ControlFrame) ?Action {
        const placed: ui.Placement = .of(controls.window, controls.scale.share());
        if (placed.scale <= 0) return null;
        const mouse = &controls.devices.mouse;
        const was_down = state.pointer.down;
        state.pointer.down = mouse.buttons.any();
        state.pointer.wheel = mouse.notches();
        if (mouse.pixelsIn(controls.window)) |pixels| {
            const x, const y = placed.onScreen(pixels);
            state.pointer.at = .{ hud.round(x), hud.round(y) };
        }
        var pointer = state.pointer;
        pointer.down = state.press.pressed(pointer.down) and !was_down;
        const keys = &controls.devices.keyboard;
        const escape = keys.pressed(input.scan.escape, .none, true);
        switch (view) {
            .lost => {
                const released = was_down and !state.pointer.down;
                const okay = buttonAt(controls.menu_art, .{ 320, 280 }).holds(pointer.at);
                return if (released and okay) .leave_match else null;
            },
            .match => |game| {
                const count = activePlayers(game.players);
                const foot = screenRow(controls.window, controls.scale.share(), 1);
                const was_focused = state.editor.focused;
                // mission_paused_frame (0x004920A9) opens an all-pilots chat draft.
                if (escape) {
                    state.editor.focused = false;
                } else if (was_focused) {
                    if (state.editor.edit(keys, controls.typed)) |line| return .{ .send_chat = line };
                } else {
                    controls.typed.clear();
                    state.editor.focused = controls.devices.active(.send_comms_message, true);
                }
                const teams = game.teams;
                const shown = scoreRows(teams);
                var scroll = hud.standings.scrollWindow(state.first_score, count, shown);
                if (count > shown) {
                    if (score_area.holds(pointer.at)) hud.standings.scrollWheel(&scroll, pointer.wheel);
                    if (!state.editor.focused) {
                        if (keys.pressed(input.scan.up, .none, true)) scroll.scroll(.up);
                        if (keys.pressed(input.scan.down, .none, true)) scroll.scroll(.down);
                        const clicked = if (pointer.down) scorePager(teams).arrowAt(pointer.at) else null;
                        if (clicked == .back or keys.pressed(@backingInt(input.Key.page_up), .none, true)) hud.standings.scrollPage(&scroll, .up);
                        if (clicked == .on or keys.pressed(@backingInt(input.Key.page_down), .none, true)) hud.standings.scrollPage(&scroll, .down);
                    }
                }
                state.first_score = scroll.first;
                if (game.can_continue and ((escape and !was_focused) or (pointer.down and buttonAt(controls.menu_art, .{ 304, foot - 32 }).holds(pointer.at)))) return .resume_match;
                if (!pointer.down) return null;
                if (buttonAt(controls.menu_art, .{ 336, foot - 32 }).holds(pointer.at)) return .leave_match;

                var scores: Scores = undefined;
                const rows = scores.collect(game);
                for (rows[scroll.first..scroll.end()], 0..) |row, index| {
                    if (game.players[row.slot].?.can_drop and buttonAt(controls.menu_art, .{ reject_x, rowY(index, teams) + 7 }).holds(pointer.at))
                        return .{ .drop = .{ .slot = @intCast(row.slot), .generation = row.pilot.generation } };
                }
                return null;
            },
        }
    }

    pub fn draw(state: *const State, view: View, canvas: ui.Canvas, art: Art) !void {
        const style = menuOf(canvas, art);
        const pointing: menu.Pointer = .{ .at = canvas.point(state.pointer.at) };
        switch (view) {
            .match => |game| {
                var controls = buttons;
                controls[1].style.dimmed = !game.can_continue;
                const title = if (game.paused_by != null) paused else .none;
                _ = try style.draw(&controls, title, pointing);
                const rule = screenRow(canvas.window, canvas.share, 0.2);
                if (title == .none) try canvas.text(canvas.fonts.large, .{ 320, rule - 32 }, "MATCH MENU", menu.orange, .centre);
                var notice: [160]u8 = undefined;
                const context = if (game.paused_by) |name|
                    std.fmt.bufPrint(&notice, "{s}: {s}", .{ name, pause_notice.text(canvas.strings.*) }) catch pause_notice.text(canvas.strings.*)
                else
                    "Match in progress";
                // The team table begins higher than the pilot table. Keep the pause notice
                // in the space between the rule and the team header.
                const notice_y = rule + @as(i32, if (game.teams.count != 0) 3 else 32);
                try canvas.text(canvas.fonts.large, .{ 320, notice_y }, context, menu.orange, .centre);
                try state.drawScores(game, canvas, art);
                try state.drawChat(game.history, canvas, art.flight_font);
            },
            .lost => |reason| {
                drawLossBox(canvas);
                _ = try style.draw(&.{session_lost_button}, paused, pointing);
                try canvas.wrapped(canvas.fonts.small, .{ 320, 200 }, reason.text(canvas.strings.*), hud.rgb(0x40BCFF), .centre, .{ .width = 400, .height = 14, .most = 10 });
            },
        }
        try canvas.drawVersion();
    }

    pub fn drawPointer(state: *const State, canvas: ui.Canvas, art: Art) !void {
        try menuOf(canvas, art).drawPointer(.{ .at = canvas.point(state.pointer.at) });
    }

    fn drawScores(state: *const State, game: Match, canvas: ui.Canvas, art: Art) !void {
        var scores: Scores = undefined;
        const rows = scores.collect(game);
        const teams = game.teams;
        const shown = scoreRows(teams);
        const scroll = hud.standings.scrollWindow(state.first_score, rows.len, shown);
        const pen: hud.Pen = .{
            .art = art.menu,
            .font = art.flight_font,
            .strings = canvas.strings,
            .gpa = canvas.gpa,
            .device = canvas.target,
            .screen = canvas.window,
            .colour = @splat(1),
            .scale = canvas.scale(),
        };
        const mode: hud.standings.Mode = if (game.arena) .paused_arena else .paused_campaign;
        try teams.draw(pen, art.scoreboard, art.scoreboard_font, mode);
        try hud.standings.drawRows(pen, rows, art.scoreboard, art.scoreboard_font, scroll, mode, teams);
        for (rows[scroll.first..scroll.end()], 0..) |row, index| {
            if (!game.players[row.slot].?.can_drop) continue;
            const at = [2]i32{ reject_x, rowY(index, teams) + 7 };
            const lit = buttonAt(art.menu, at).holds(state.pointer.at);
            const box = buttonAt(art.menu, at);
            try canvas.shape(art.menu, if (lit) @backingInt(menu.Shape.button_lit) else @backingInt(menu.Shape.button), .{ box.x, box.y });
        }
        if (rows.len > shown) try state.drawScroll(canvas, scroll, art.paging, teams);
    }

    fn drawChat(state: *const State, history: *const History, canvas: ui.Canvas, font: *hud.Opened) !void {
        const bottom = screenRow(canvas.window, canvas.share, 1);
        const first = history.count -| hud.Messages.capacity;
        for (first..history.count) |index| {
            var line: [History.line_size + 2]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "- {s}", .{history.line(index)}) catch unreachable;
            const y = bottom - 84 + hud.Messages.spacing * @as(i32, @intCast(index - first));
            try canvas.text(font, .{ 210, y }, text, menu.orange, .left);
        }
        if (!state.editor.focused) return;
        const draft = state.editor.line.slice();
        const draft_y = bottom - 40;
        try canvas.text(font, .{ 320, draft_y }, draft, menu.orange, .centre);
        try canvas.text(font, .{ 320 + @as(i32, @intCast(font.textWidth(draft) / 2)), draft_y }, "_", menu.orange, .left);
    }

    fn drawScroll(state: *const State, canvas: ui.Canvas, scroll: hud.standings.Scroll, paging_art: ?*hud.Art, teams: hud.standings.TeamBoard) !void {
        const pager = scorePager(teams);
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
                try canvas.text(canvas.fonts.small, .{ pager.arrow(step).centre()[0], pager.y - 1 }, glyph, menu.orange, .centre);
            }
        }
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}-{d}/{d}", .{ scroll.first + 1, scroll.end(), scroll.count }) catch unreachable;
        try canvas.text(canvas.fonts.small, .{ 500, pager.y + 4 }, text, menu.orange, .right);
    }
};

fn screenRow(window: [2]u32, share: f32, fraction: f32) i32 {
    const placed: ui.Placement = .of(window, share);
    if (placed.scale <= 0) return 0;
    const row = @as(f32, @floatFromInt(window[1])) * fraction;
    return hud.round(placed.onScreen(.{ 0, row })[1]);
}

fn menuOf(canvas: ui.Canvas, art: Art) menu.Ui {
    return .{
        .gpa = canvas.gpa,
        .target = canvas.target,
        .screen = canvas.window,
        .scale = canvas.scale(),
        .art = art.menu,
        .fonts = .{ .small = canvas.fonts.small, .large = canvas.fonts.large, .display = art.flight_font },
        .strings = canvas.strings,
    };
}

fn buttonAt(art: ?*const hud.Art, at: [2]i32) ui.Rect {
    const shape = if (art) |loaded| loaded.shape(@backingInt(menu.Shape.button)) else null;
    const width: i16 = if (shape) |found| @intCast(@min(found.header.bounds.across, ui.size[0])) else 22;
    const height: i16 = if (shape) |found| @intCast(@min(found.header.bounds.down, ui.size[1])) else 15;
    const x: i16 = if (shape) |found| @intCast(@min(found.header.origin.across, ui.size[0])) else 0;
    const y: i16 = if (shape) |found| @intCast(@min(found.header.origin.down, ui.size[1])) else 0;
    return .{ .x = @as(i16, @intCast(at[0])) + x - @divTrunc(width, 2), .y = @as(i16, @intCast(at[1])) + y - @divTrunc(height, 2), .width = width, .height = height };
}

fn scoreRows(teams: hud.standings.TeamBoard) usize {
    return @intCast(@max(1, @divTrunc(chat_y - rowY(0, teams) - 10, row_height)));
}

fn scorePager(teams: hud.standings.TeamBoard) settings.Line {
    const y = if (teams.count == 0) 156 else scores_y + teams.offset(.paused_arena) - settings.Line.arrows_height - 3;
    return .withArrowsAt(.{ 524, y });
}

fn rowY(index: usize, teams: hud.standings.TeamBoard) i32 {
    return first_row + teams.offset(.paused_arena) + @as(i32, @intCast(index)) * row_height;
}

fn drawLossBox(canvas: ui.Canvas) void {
    // menu_box_draw (0x0048D820) frames the black pane with the original red edges.
    const left = loss_box.x;
    const top = loss_box.y;
    const right = left + loss_box.width;
    const bottom = top + loss_box.height;
    canvas.wipe(.{ left, top }, .{ right, bottom }, ui.black);
    canvas.line(.{ left, top }, .{ right - 1, top }, hud.rgb(0xCD0000));
    canvas.line(.{ left, top + 1 }, .{ left, bottom - 1 }, hud.rgb(0xCD0000));
    canvas.line(.{ left, bottom }, .{ right, bottom }, hud.rgb(0x660000));
    canvas.line(.{ right, top }, .{ right, bottom - 1 }, hud.rgb(0x660000));
    const inner = hud.rgb(0xA40000);
    canvas.line(.{ left + 1, top + 1 }, .{ right - 1, top + 1 }, inner);
    canvas.line(.{ left + 1, top + 2 }, .{ left + 1, bottom - 2 }, inner);
    canvas.line(.{ left + 1, bottom - 1 }, .{ right - 1, bottom - 1 }, inner);
    canvas.line(.{ right - 1, top + 2 }, .{ right - 1, bottom - 2 }, inner);
}

fn activePlayers(roster: []const ?Player) usize {
    var count: usize = 0;
    for (roster[0..@min(roster.len, hud.standings.max_pilots)]) |entry| {
        if (entry != null) count += 1;
    }
    return count;
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

test "paused standings show all stock slots and stop their paging before chat" {
    const count = 20;
    const available_rows = scoreRows(.{});
    const last = hud.standings.scrollWindow(count, count, available_rows);
    try std.testing.expect(available_rows >= 8);
    try std.testing.expectEqual(count - available_rows, last.first);
    try std.testing.expectEqual(count, last.end());
    try std.testing.expect(rowY(available_rows - 1, .{}) + row_height <= chat_y);
}

test "a shared pause guest cannot resume the simulation by pressing Escape" {
    var state: State = .{};
    var devices: input.Devices = .{};
    var typed: Typed = .{};
    const controls: ControlFrame = .{ .devices = &devices, .typed = &typed, .window = ui.size, .scale = .{} };
    var view: View = .{ .match = .{ .all = undefined, .history = undefined, .players = &.{}, .can_continue = false } };
    devices.keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, state.frame(view, controls));
    devices.keyboard.down[input.scan.escape] = false;
    devices.keyboard.read();
    view.match.can_continue = true;
    devices.keyboard.down[input.scan.escape] = true;
    try std.testing.expect(state.frame(view, controls).? == .resume_match);
}

test "the pause menu buttons work while a chat draft is open" {
    var devices: input.Devices = .{};
    var typed: Typed = .{};
    const controls: ControlFrame = .{ .devices = &devices, .typed = &typed, .window = ui.size, .scale = .{ .percent = 100 } };
    const view: View = .{ .match = .{ .all = undefined, .history = undefined, .players = &.{} } };
    for ([_]i16{ 304, 336 }, [_]Action{ .resume_match, .leave_match }) |x, expected| {
        var state: State = .{ .editor = .{ .focused = true } };
        devices.mouse.at = .{ @as(f32, @floatFromInt(x)) / ui.size[0], @as(f32, ui.size[1] - 32) / ui.size[1] };
        devices.mouse.buttons.left = false;
        try std.testing.expectEqual(null, state.frame(view, controls));
        devices.mouse.buttons.left = true;
        try std.testing.expectEqual(expected, state.frame(view, controls).?);
    }
}

test "the loss dialog accepts a fresh click when its button is released" {
    var state: State = .{};
    var devices: input.Devices = .{};
    var typed: Typed = .{};
    const controls: ControlFrame = .{ .devices = &devices, .typed = &typed, .window = ui.size, .scale = .{ .percent = 100 } };
    const view: View = .{ .lost = .{} };
    const at = buttonAt(null, .{ 320, 280 }).centre();
    devices.mouse.at = .{ @as(f32, @floatFromInt(at[0])) / ui.size[0], @as(f32, @floatFromInt(at[1])) / ui.size[1] };
    try std.testing.expectEqual(null, state.frame(view, controls));
    devices.mouse.buttons.left = true;
    try std.testing.expectEqual(null, state.frame(view, controls));
    devices.mouse.buttons.left = false;
    try std.testing.expect(state.frame(view, controls).? == .leave_match);
}
