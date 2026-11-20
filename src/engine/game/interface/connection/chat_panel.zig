//! The chat log and editor shared by the lobby and the multiplayer pause screen.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const chat = @import("../../chat.zig");
const input = @import("../../../input.zig");
const Typed = @import("../../winmain.zig").Typed;
const widgets = @import("widgets.zig");

pub const History = hud.MessageList(30);
const chat_label: widgets.Label = .{ .english = "CHAT", .installed = 0x140 };

pub const Caret = struct {
    on: bool = false,
    /// Initialised by `multiplayer_chat_reset` (0x004AE1DD).
    due: u32 = 1,
    const interval = 25;

    /// `multiplayer_chat_panel` toggles once and schedules the next blink (0x004AE63E).
    pub fn update(caret: *Caret, ticks: u32) void {
        if (ticks <= caret.due) return;
        caret.due = ticks +| interval;
        caret.on = !caret.on;
    }
};

pub const Editor = struct {
    line: chat.Line = .{},
    focused: bool = false,

    pub fn frameIn(editor: *Editor, entry: ui.Rect, pointer: ui.Pointer, keys: *input.Keyboard, typed: *Typed, escaped: bool) ?chat.Line {
        if (pointer.down) editor.focused = entry.holds(pointer.at);
        if (!editor.focused) {
            typed.clear();
            editor.focused = !escaped and chat.submitted(keys);
            return null;
        }
        if (escaped) editor.focused = false;
        if (escaped) return null;
        return editor.edit(keys, typed);
    }

    /// Reads the draft and submits it on Enter while the containing screen owns text focus.
    pub fn edit(editor: *Editor, keys: *input.Keyboard, typed: *Typed) ?chat.Line {
        chat.edit(&editor.line, typed, null);
        if (!chat.submitted(keys)) return null;
        const line = editor.line;
        editor.line.len = 0;
        return if (chat.trim(line.slice()).len != 0) line else null;
    }
};

/// `multiplayer_chat_panel` (0x004AE2D0), variants 0 and 2. The callers supply the history box
/// and the number of lines to show. Both place the entry five pixels below the history.
pub const Setup = struct {
    history: ui.Rect,
    rows: usize,

    pub const spacing = 12;
    const field_gap = 5;
    const inset = 4;
    const text_height = 16;

    pub fn entry(setup: Setup) ui.Rect {
        return .{ .x = setup.history.x, .y = setup.history.y + setup.history.height + field_gap, .width = setup.history.width, .height = 21 };
    }

    fn arrows(setup: Setup) widgets.ScrollArrows {
        return .{ .x = setup.history.x + setup.history.width + field_gap, .y = setup.history.y };
    }

    pub fn frame(setup: Setup, history: ?*const History, older: *usize, pointer: ui.Pointer, hover: *?ui.Arrow) void {
        const count = if (history) |lines| lines.count else 0;
        var list: ui.Scrolled(usize) = .{ .first = count -| setup.rows -| older.*, .count = count, .shown = setup.rows };
        hover.* = setup.arrows().under(pointer.at);
        if (pointer.down) if (hover.*) |way| list.scroll(way);
        if (setup.history.holds(pointer.at)) list.wheel(pointer.wheel);
        older.* = count -| list.end();
    }

    pub fn draw(setup: Setup, canvas: ui.Canvas, art: *hud.Art, history: ?*const History, older: usize, hover: ?ui.Arrow, editor: *const Editor, caret: Caret) !void {
        const log = setup.history;
        const input_box = setup.entry();
        canvas.box(.{ log.x, log.y }, .{ log.width, log.height });
        canvas.box(.{ input_box.x, input_box.y }, .{ input_box.width, input_box.height });
        const font = canvas.fonts.small;
        try canvas.text(font, .{ log.x + inset, log.y - 17 }, chat_label.text(canvas.strings.*), ui.blue, .left);
        try setup.arrows().draw(canvas, art, hover);
        if (history) |lines| {
            const end = lines.count -| older;
            const visible = @min(end, setup.rows);
            const clipped = canvas.within(log);
            for (end - visible..end, 0..) |index, row| {
                const y = log.y + log.height - text_height - @as(i16, @intCast(visible - 1 - row)) * spacing;
                try clipped.text(font, .{ log.x + inset, y }, lines.line(index), ui.blue, .left);
            }
        }
        const draft: ui.Rect = .{ .x = input_box.x + inset, .y = input_box.y + 2, .width = input_box.width - 2 * inset, .height = input_box.height - 2 };
        try drawDraft(canvas, draft, font, editor, editor.focused and caret.on, if (editor.focused) ui.white else ui.blue);
    }
};

pub fn drawDraft(canvas: ui.Canvas, entry: ui.Rect, font: *hud.Opened, editor: *const Editor, caret: bool, colour: [3]f32) !void {
    var buffer: [chat.capacity + 1]u8 = undefined;
    var line = editor.line.slice();
    const caret_width = font.textWidth("_");
    while (line.len != 0 and font.textWidth(line) + caret_width > entry.width)
        line = line[1..];
    @memcpy(buffer[0..line.len], line);
    buffer[line.len] = '_';
    try canvas.within(entry).text(font, .{ entry.x, entry.y }, buffer[0 .. line.len + @intFromBool(caret)], colour, .left);
}

test "Escape leaves the editor and Enter sends the shared draft" {
    var editor: Editor = .{};
    var keys: input.Keyboard = .{};
    var typed: Typed = .{};
    const panel: ui.Rect = .{ .x = 20, .y = 100, .width = 200, .height = 120 };
    try std.testing.expectEqual(null, editor.frameIn(panel, .{ .at = panel.centre(), .down = true }, &keys, &typed, false));
    try std.testing.expect(editor.focused);
    for ("Ready") |byte| typed.push(byte);
    keys.down[@backingInt(input.Key.enter)] = true;
    const line = editor.frameIn(panel, .{}, &keys, &typed, false).?;
    try std.testing.expectEqualStrings("Ready", line.slice());
    try std.testing.expectEqual(null, editor.frameIn(panel, .{}, &keys, &typed, true));
    try std.testing.expect(!editor.focused);
}

test "the lobby caret switches once even after a slow frame" {
    var caret: Caret = .{};
    caret.update(2);
    try std.testing.expect(caret.on);
    caret.update(27);
    try std.testing.expect(caret.on);
    caret.update(90);
    try std.testing.expect(!caret.on);
    try std.testing.expectEqual(115, caret.due);
}
