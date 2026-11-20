//! The co-op debrief shows installed mission text and the crew's readiness.
const std = @import("std");
const game = @import("../../gameflow.zig");
const Ending = @import("../../main.zig").Ending;
const language = @import("../../language.zig");
const input = @import("../../../input.zig");
const Typed = @import("../../winmain.zig").Typed;
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const itac = @import("../../itac.zig");
const Layout = @import("layout.zig");
const widgets = @import("widgets.zig");
const chat = @import("chat_panel.zig");
const Crew = @import("debrief_crew.zig");
const CallSign = @import("../pilot_roster.zig").CallSign;
const Debrief = @This();

pub const Action = union(enum) { choice: Crew.Choice, leave, message: @import("../../chat.zig").Line };
const Control = enum { leave, ready, replay, advance };

crew: Crew = .{},
local_slot: u8,
number: u16,
ending: Ending,
objectives_met: bool,
record: game.MissionRecord,
names: *const [Crew.size]?CallSign,
notices: *const chat.History,
editor: chat.Editor = .{ .focused = true },
history_text: [4096]u8 = undefined,
history_len: usize = 0,
scroll: itac.ScrollBox = .{ .arrows = undefined, .rect = undefined },
hover: ?Control = null,
arrow_hover: ?usize = null,

pub fn setNarrative(debrief: *Debrief, strings: language.Language) void {
    var writer: std.Io.Writer = .fixed(&debrief.history_text);
    if (debrief.ending == .rescued) {
        itac.debriefing.writePickup(&writer, strings, debrief.objectives_met, 1);
    } else itac.writeNarrative(&writer, strings, itac.debriefing.textOf(debrief.record, debrief.number));
    debrief.history_len = writer.end;
}

const title: widgets.Label = .{ .english = "DEBRIEFING", .installed = 0x313 };
const controls = std.EnumArray(Control, widgets.Label).init(.{
    .leave = .{ .english = "LEAVE GAME" },
    .ready = .{ .english = "READY", .installed = 0x145 },
    .replay = .{ .english = "REPLAY MISSION", .installed = 0x296 },
    .advance = .{ .english = "NEXT MISSION", .installed = 0x39B },
});
fn widePanel(layout: Layout, top: i16, bottom: i16) ui.Rect {
    const y: i16 = @intCast(layout.point(.{ 0, top })[1]);
    const end: i16 = @intCast(layout.point(.{ 0, bottom })[1]);
    return .{ .x = layout.list.x, .y = y, .width = layout.details.x + layout.details.width - layout.list.x, .height = end - y };
}

fn reportBox(layout: Layout) ui.Rect {
    return widePanel(layout, 53, 195);
}

fn chatBox(layout: Layout) ui.Rect {
    return widePanel(layout, 226, 306);
}

fn textBox(panel: ui.Rect) ui.Rect {
    return .{
        .x = panel.x + Layout.footer_inset,
        .y = panel.y + 29,
        .width = panel.width - 2 * Layout.footer_inset,
        .height = panel.height - 36,
    };
}

fn textArrows(layout: Layout) [2]ui.Rect {
    // The render callback at 0x0042A144 draws the hover sprites over the upper arrow pair.
    const down = layout.point(.{ 295, 201 });
    const up = layout.point(.{ 321, 201 });
    return .{
        .{ .x = @intCast(down[0]), .y = @intCast(down[1]), .width = @intCast(up[0] - down[0]), .height = 25 },
        .{ .x = @intCast(up[0]), .y = @intCast(up[1]), .width = @intCast(up[0] - down[0]), .height = 25 },
    };
}

fn button(layout: Layout, control: Control) ui.Rect {
    const back = layout.control(.back);
    const across: i16 = switch (control) {
        .leave => 0,
        .ready, .advance => 172,
        .replay => 335,
    };
    return .{ .x = back.x + across, .y = back.y, .width = 158, .height = back.height };
}

fn enabled(debrief: *const Debrief, control: Control) bool {
    return switch (control) {
        .leave => true,
        .ready => debrief.crew.permits(debrief.local_slot, .ready),
        .replay => debrief.crew.permits(debrief.local_slot, .replay),
        .advance => debrief.crew.permits(debrief.local_slot, .advance),
    };
}

fn visible(debrief: *const Debrief, control: Control) bool {
    const is_lead = debrief.crew.lead == debrief.local_slot;
    return switch (control) {
        .leave => true,
        .ready => !is_lead,
        .replay => is_lead,
        .advance => is_lead and debrief.crew.eligible.count() != 0,
    };
}

pub fn updateText(debrief: *Debrief, font: *hud.Opened, pointer: ui.Pointer, tick: u32) void {
    const layout = Layout.atShare(ui.fitted);
    debrief.scroll.rect = textBox(reportBox(layout));
    debrief.scroll.arrows = textArrows(layout);
    debrief.scroll.reach(debrief.scroll.lines().count(font, debrief.history_text[0..debrief.history_len]));
    debrief.arrow_hover = ui.hit(&debrief.scroll.arrows, pointer.at);
    if (debrief.scroll.rect.holds(pointer.at) or debrief.arrow_hover != null)
        debrief.scroll.wheel(pointer.wheel);
    debrief.scroll.update(tick, pointer);
}

pub fn frame(debrief: *Debrief, pointer: ui.Pointer, keys: *input.Keyboard, typed: *Typed) ?Action {
    const layout = Layout.atShare(ui.fitted);
    const chat_panel = chatBox(layout);
    // multiplayer_debriefing checks Escape before it updates the chat editor (0x00429A1C).
    if (keys.pressed(input.scan.escape, .none, true)) return .leave;
    if (debrief.editor.frame(chat_panel, pointer, keys, typed, false)) |line| return .{ .message = line };
    debrief.hover = for (std.enums.values(Control)) |control| {
        if (debrief.visible(control) and button(layout, control).holds(pointer.at)) break control;
    } else null;
    if (!pointer.down) return null;
    const control = debrief.hover orelse return null;
    if (!debrief.enabled(control)) return null;
    return switch (control) {
        .leave => .leave,
        .ready => .{ .choice = .ready },
        .replay => .{ .choice = .replay },
        .advance => .{ .choice = .advance },
    };
}

/// The ITAC heading and arrow sprites are drawn by `multiplayer_debrief_render` (0x00429DC0).
pub fn draw(debrief: *const Debrief, canvas: ui.Canvas, art: *hud.Art, original: ?*hud.Art) !void {
    const layout = Layout.atShare(ui.fitted);
    const chat_panel = chatBox(layout);
    const report = reportBox(layout);
    const players = widePanel(layout, 336, 421);
    try canvas.text(canvas.fonts.large, .{ 167, 22 }, title.text(canvas.strings.*), itac.header_colour, .left);
    widgets.panel(canvas, report);
    widgets.panel(canvas, players);
    const font = canvas.fonts.small;
    const strings = canvas.strings.*;
    const inset = Layout.footer_inset;
    var buffer: [96]u8 = undefined;
    const result = switch (debrief.ending) {
        .destroyed => "Ship lost",
        .captured => "Captured",
        .rescued => "Rescued",
        .friendly_fire, ._unknown_7 => "Recalled",
        else => switch (debrief.record.rating orelse .failure) {
            .success, .success_bonus, .partial_success => "Mission complete",
            else => "Mission failed",
        },
    };
    const mission = strings.stringOr(0xE5, "MISSION");
    const heading = std.fmt.bufPrint(&buffer, "{s} {d}   |   {s}", .{ mission, debrief.number, result }) catch result;
    try widgets.fittedLabel(canvas, .{ report.x + inset, report.y + 9 }, report.width - 2 * inset, heading, itac.header_colour, .left);
    const text = textBox(report);
    var box = debrief.scroll;
    box.rect = text;
    try box.drawText(canvas, font, text, text, debrief.history_text[0..debrief.history_len]);
    if (original) |stock| if (debrief.arrow_hover) |arrow| {
        const rect = textArrows(layout)[arrow];
        try canvas.shape(stock, 0x18 + arrow, .{ rect.x, rect.y });
    };
    const left = layout.details.x - 25;
    const right = players.x + players.width - inset;
    const kills = strings.stringOr(0x1DA, "Mission kills");
    const tally = std.fmt.bufPrint(&buffer, "{s} {d}", .{ kills, debrief.record.kills }) catch kills;
    try widgets.fittedLabel(canvas, .{ players.x + inset, players.y + 9 }, left - players.x - 2 * inset, tally, itac.label_colour, .left);
    try canvas.text(font, .{ left, players.y + 9 }, strings.stringOr(0x141, "PLAYERS"), itac.header_colour, .left);
    var y = players.y + 26;
    var seats = debrief.crew.present.iterator(.{});
    while (seats.next()) |slot| {
        const name = debrief.names[slot] orelse continue;
        const call_sign = if (name.len != 0) name.slice() else std.fmt.bufPrint(&buffer, "Pilot {d}", .{slot + 1}) catch unreachable;
        // The original leaves the status blank until a wingmate is ready and highlights the lead.
        const state = if (slot == debrief.crew.lead or debrief.crew.ready.isSet(slot))
            if (debrief.crew.eligible.isSet(slot)) strings.stringOr(0x145, "READY") else strings.stringOr(0x181, "RESTART")
        else
            "";
        const room: i16 = @intCast(font.textWidth(state) + inset);
        try widgets.fittedLabel(canvas, .{ left, y }, right - left - room, call_sign, ui.white, .left);
        if (state.len != 0) try canvas.text(font, .{ right, y }, state, ui.blue, .right);
        y += 13;
    }
    try chat.draw(canvas, chat_panel, debrief.notices, &debrief.editor);
    for (std.enums.values(Control)) |control| {
        if (!debrief.visible(control)) continue;
        const rect = button(layout, control);
        if (original) |stock| {
            const shown = canvas.dimmedUnless(debrief.enabled(control));
            try shown.shape(stock, if (debrief.hover == control) 0x1A else 0x1B, .{ rect.x, rect.y - 3 });
            try widgets.fittedLabel(shown, .{ rect.x + 36, rect.y }, rect.width - 36, controls.get(control).text(strings), itac.text_colour, .left);
        } else try widgets.button(canvas, art, rect, controls.get(control), debrief.enabled(control), debrief.hover == control);
    }
}
