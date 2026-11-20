//! The installed co-op ITAC screen from multiplayer_debriefing (0x004296A0).
const std = @import("std");
const game = @import("../../gameflow.zig");
const Ending = @import("../../main.zig").Ending;
const language = @import("../../language.zig");
const input = @import("../../../input.zig");
const Typed = @import("../../winmain.zig").Typed;
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const itac = @import("../../itac.zig");
const widgets = @import("widgets.zig");
const chat = @import("chat_panel.zig");
const Crew = @import("debrief_crew.zig");
const CallSign = @import("../pilot_roster.zig").CallSign;
const Debrief = @This();

pub const Action = union(enum) { choice: Crew.Choice, leave, message: @import("../../chat.zig").Line };
pub const History = hud.MessageList(30);
const Control = enum { leave, ready, replay, advance, save };

crew: Crew = .{},
local_slot: u8,
number: u16,
ending: Ending,
objectives_met: bool,
record: game.MissionRecord,
overall_kills: i32,
names: *const [Crew.size]?CallSign,
notices: *const History,
editor: chat.Editor = .{ .focused = true },
letter_strings: language.Language = .{ .strings = &.{} },
history_text: [4096]u8 = undefined,
history_len: usize = 0,
scroll: itac.ScrollBox = .{ .arrows = report_arrows, .rect = report },
hover: ?Control = null,
report_hover: ?usize = null,
chat_hover: ?usize = null,
chat_behind: u8 = 0,
caret: bool = false,
caret_due: u32 = 0,

// multiplayer_debrief_panes (0x00424730) and multiplayer_debrief_render (0x0042A064).
const report: ui.Rect = .{ .x = 35, .y = 107, .width = 565, .height = 90 };
const report_arrows = [2]ui.Rect{
    .{ .x = 293, .y = 199, .width = 27, .height = 28 },
    .{ .x = 320, .y = 199, .width = 27, .height = 28 },
};
const report_arrow_at = [2][2]i32{ .{ 295, 201 }, .{ 321, 201 } };

// multiplayer_chat_panel (0x004AE2D0), variant 1.
const chat_arrows = [2]ui.Rect{
    .{ .x = 320, .y = 302, .width = 27, .height = 27 },
    .{ .x = 293, .y = 302, .width = 27, .height = 27 },
};
const chat_arrow_at = [2][2]i32{ .{ 321, 304 }, .{ 295, 304 } };
const chat_lines = 6;
const chat_left = 38;
const chat_latest_y = 282;
const chat_spacing = 12;
const chat_edit_y = 339;
const menu_blue = hud.rgb(0x40BCFF);

const Button = struct { hot: ui.Rect, label: widgets.Label, anchor: [2]i32, text_y: i32 };
const buttons = std.EnumArray(Control, Button).init(.{
    .leave = .{ .hot = .{ .x = 571, .y = 422, .width = 58, .height = 54 }, .label = .{}, .anchor = .{ 0, 0 }, .text_y = 0 },
    .ready = .{ .hot = .{ .x = 528, .y = 362, .width = 37, .height = 27 }, .label = .{ .english = "READY", .installed = 0x145 }, .anchor = .{ 530, 364 }, .text_y = 368 },
    .advance = .{ .hot = .{ .x = 528, .y = 362, .width = 37, .height = 27 }, .label = .{ .english = "NEXT MISSION", .installed = 0x39B }, .anchor = .{ 530, 364 }, .text_y = 368 },
    .replay = .{ .hot = .{ .x = 528, .y = 398, .width = 37, .height = 27 }, .label = .{ .english = "REPLAY MISSION", .installed = 0x296 }, .anchor = .{ 530, 400 }, .text_y = 403 },
    .save = .{ .hot = .{ .x = 528, .y = 438, .width = 37, .height = 27 }, .label = .{ .english = "SAVE GAME", .installed = 0x178 }, .anchor = .{ 530, 438 }, .text_y = 442 },
});

/// multiplayer_debrief_text (0x00425240) shares the singleplayer report and pickup text.
/// The ending notices for a pilot who is out come from LANGUAGE.DLL.
pub fn setNarrative(debrief: *Debrief, game_strings: language.Language, itac_strings: language.Language) void {
    debrief.letter_strings = itac_strings;
    var writer: std.Io.Writer = .fixed(&debrief.history_text);
    const ending = switch (debrief.ending) {
        .destroyed => game_strings.stringOr(0x53F, "You have been killed"),
        .captured => game_strings.stringOr(0x540, "You have been captured"),
        .friendly_fire => game_strings.stringOr(0x541, "You have been executed"),
        ._unknown_7, .total_failure => game_strings.stringOr(0x566, "You have been kicked off the ship."),
        else => null,
    };
    if (ending) |line| {
        writer.writeAll(line) catch {};
    } else if (debrief.ending == .rescued) {
        itac.debriefing.writePickup(&writer, itac_strings, debrief.objectives_met, 1);
    } else {
        itac.writeNarrative(&writer, itac_strings, itac.debriefing.textOf(debrief.record, debrief.number));
    }
    debrief.history_len = writer.end;
}

fn visible(debrief: *const Debrief, control: Control) bool {
    const is_lead = debrief.crew.lead == debrief.local_slot;
    return switch (control) {
        .leave, .save => true,
        .ready => !is_lead,
        .replay => is_lead,
        .advance => is_lead and debrief.crew.eligible.count() != 0,
    };
}

pub fn updateText(debrief: *Debrief, font: *hud.Opened, pointer: ui.Pointer, tick: u32) void {
    debrief.scroll.reach(debrief.scroll.lines().count(font, debrief.history_text[0..debrief.history_len]));
    debrief.report_hover = ui.hit(&report_arrows, pointer.at);
    if (report.holds(pointer.at) or debrief.report_hover != null) debrief.scroll.wheel(pointer.wheel);
    debrief.scroll.update(tick, pointer);
    if (tick > debrief.caret_due) {
        debrief.caret = !debrief.caret;
        debrief.caret_due = tick +| 25;
    }
}

pub fn frame(debrief: *Debrief, pointer: ui.Pointer, keys: *input.Keyboard, typed: *Typed) ?Action {
    // The original checks Escape before calling multiplayer_chat_panel (0x00429A1C).
    if (keys.pressed(input.scan.escape, .none, true)) return .leave;
    debrief.chat_hover = ui.hit(&chat_arrows, pointer.at);
    if (pointer.down) if (debrief.chat_hover) |arrow| {
        const furthest = debrief.notices.count -| chat_lines;
        debrief.chat_behind = if (arrow == 0) @min(furthest, debrief.chat_behind + 1) else debrief.chat_behind -| 1;
    };
    // The retail debrief takes chat input throughout the screen.
    if (debrief.editor.edit(keys, typed)) |line|
        return .{ .message = line };
    debrief.hover = for (std.enums.values(Control)) |control| {
        if (debrief.visible(control) and buttons.get(control).hot.holds(pointer.at)) break control;
    } else null;
    if (!pointer.down) return null;
    const control = debrief.hover orelse return null;
    const choice: Crew.Choice = switch (control) {
        .leave => return .leave,
        // The save screen and the co-op save format are tracked in #475.
        .save => return null,
        .ready => .ready,
        .replay => .replay,
        .advance => .advance,
    };
    return if (debrief.crew.permits(debrief.local_slot, choice)) .{ .choice = choice } else null;
}

/// multiplayer_debrief_render (0x00429DC0). The background already contains the
/// arrows, report frame, and exit control. The renderer adds text and the active shapes.
pub fn draw(debrief: *const Debrief, canvas: ui.Canvas, panel_font: *hud.Opened, original: ?*hud.Art) !void {
    const strings = canvas.strings.*;
    const font = canvas.fonts.small;
    const previous_palette = if (original) |stock| stock.global else null;
    defer if (original) |stock| {
        stock.global = previous_palette;
    };
    try canvas.text(canvas.fonts.large, .{ 167, 22 }, strings.stringOr(0x313, "DEBRIEFING"), menu_blue, .left);
    var recipient_buffer: [64]u8 = undefined;
    const recipient = debrief.name(strings, debrief.local_slot, &recipient_buffer);
    try itac.debriefing.drawLetterHeader(canvas, font, debrief.letter_strings, .{ 35, 65 }, recipient);
    try debrief.scroll.drawText(canvas, font, report, report, debrief.history_text[0..debrief.history_len]);
    if (debrief.scroll.more(false)) {
        var buffer: [64]u8 = undefined;
        const more = std.fmt.bufPrint(&buffer, "({s})", .{debrief.letter_strings.stringOr(0x78C, "more")}) catch "(more)";
        try canvas.text(font, .{ 600, 193 }, more, itac.text_colour, .right);
    }
    if (original) |stock| {
        stock.global = stock.set.paletteAt(0x17);
        if (debrief.report_hover) |arrow| try canvas.shape(stock, 0x18 + arrow, report_arrow_at[arrow]);
        if (debrief.chat_hover) |arrow| try canvas.shape(stock, 0x19 - arrow, chat_arrow_at[arrow]);
    }
    try debrief.drawChat(canvas, font, panel_font);
    try debrief.drawFigures(canvas, font);
    try debrief.drawCrew(canvas, panel_font);
    for (std.enums.values(Control)) |control| {
        if (control == .leave or !debrief.visible(control)) continue;
        const button = buttons.get(control);
        // Next, Replay and Save use the same square sprite pair (0x0042A0EE, 0x0042A129, 0x0042A1CB).
        if (original) |stock| try canvas.shape(stock, if (debrief.hover == control) 0x1A else 0x1B, button.anchor);
        try canvas.text(font, .{ 517, button.text_y }, button.label.text(strings), itac.text_colour, .right);
    }
}

fn name(debrief: *const Debrief, strings: language.Language, slot: usize, buffer: []u8) []const u8 {
    if (debrief.names[slot]) |*sign| if (sign.len != 0) return sign.slice();
    const label = strings.stringOr(0xBF, "Pilot");
    return std.fmt.bufPrint(buffer, "{s} {d}", .{ label, slot + 1 }) catch label;
}

fn drawChat(debrief: *const Debrief, canvas: ui.Canvas, font: *hud.Opened, panel_font: *hud.Opened) !void {
    const strings = canvas.strings.*;
    const end = debrief.notices.count - debrief.chat_behind;
    const count = @min(chat_lines, end);
    const pane = canvas.within(.{ .x = chat_left, .y = 219, .width = 572, .height = 81 });
    for (0..count) |row| {
        const y = chat_latest_y - chat_spacing * @as(i32, @intCast(row));
        try pane.text(panel_font, .{ chat_left, y }, debrief.notices.line(end - row - 1), itac.text_colour, .left);
    }
    const label = strings.stringOr(0x295, "MESSAGE:");
    try canvas.text(font, .{ chat_left, chat_edit_y }, label, itac.text_colour, .left);
    const entry_x = chat_left + 4 + @as(i32, @intCast(font.textWidth(label)));
    if (entry_x < 612) try chat.drawDraft(canvas, .{ .x = @intCast(entry_x), .y = chat_edit_y, .width = @intCast(612 - entry_x), .height = 19 }, panel_font, &debrief.editor, debrief.caret, itac.text_colour);
}

fn drawFigures(debrief: *const Debrief, canvas: ui.Canvas, font: *hud.Opened) !void {
    const strings = canvas.strings.*;
    const labels = [_]widgets.Label{
        .{ .english = "Mission Kills", .installed = 0x1DA },
        .{ .english = "Overall Kills", .installed = 0x1DB },
        .{ .english = "Rank", .installed = 0x1DC },
        .{ .english = "Level", .installed = 0x1DD },
    };
    var pilot: input.Player = .{ .kills = .{ .count = debrief.overall_kills } };
    _ = game.promote(&pilot);
    var mission_kills: [16]u8 = undefined;
    var overall_kills: [16]u8 = undefined;
    const values = [_][]const u8{
        std.fmt.bufPrint(&mission_kills, "{d}", .{debrief.record.kills}) catch unreachable,
        std.fmt.bufPrint(&overall_kills, "{d}", .{debrief.overall_kills}) catch unreachable,
        strings.stringOr(game.rank_names[pilot.rank], "2nd Lieutenant"),
        strings.stringOr(game.tier_names[game.campaignField(debrief.number, .tier) orelse 0], "Bronze"),
    };
    for (labels, values, 0..) |label, value, row| {
        const y = 376 + @as(i32, @intCast(row)) * 17;
        try canvas.text(font, .{ 36, y }, label.text(strings), itac.label_colour, .left);
        try canvas.text(font, .{ 202, y }, value, itac.text_colour, .right);
    }
}

fn drawCrew(debrief: *const Debrief, canvas: ui.Canvas, font: *hud.Opened) !void {
    const strings = canvas.strings.*;
    // multiplayer_debrief_render selects the ITAC orange ramp before drawing the roster (0x0042A2DA).
    try canvas.text(font, .{ 225, 364 }, strings.stringOr(0x141, "PLAYERS"), itac.text_colour, .left);
    const roster = canvas.within(.{ .x = 225, .y = 381, .width = 155, .height = 57 });
    var seats = debrief.crew.present.iterator(.{});
    var y: i32 = 381;
    while (seats.next()) |slot| : (y += 13) {
        var call_sign: [64]u8 = undefined;
        const words = debrief.name(strings, slot, &call_sign);
        const restart = strings.stringOr(0x181, "RESTART");
        var label: [64]u8 = undefined;
        const state = if (slot == debrief.crew.lead or debrief.crew.ready.isSet(slot)) state: {
            const text = if (debrief.crew.eligible.isSet(slot)) strings.stringOr(0x145, "READY") else restart;
            break :state std.ascii.upperString(&label, text[0..@min(label.len, text.len)]);
        } else "";
        const reserved = @as(i32, @intCast(font.textWidth(restart)));
        var shortened = words;
        while (shortened.len > 0 and @as(i32, @intCast(font.textWidth(shortened))) >= 145 - reserved)
            shortened = shortened[0 .. shortened.len - 1];
        try roster.text(font, .{ 225, y }, shortened, itac.text_colour, .left);
        if (state.len != 0) try roster.text(font, .{ 379, y }, state, itac.text_colour, .right);
    }
}
