//! The chat log and editor shared by the lobby and the multiplayer pause screen.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const chat = @import("../../chat.zig");
const input = @import("../../../input.zig");
const Typed = @import("../../winmain.zig").Typed;
const Layout = @import("layout.zig");
const widgets = @import("widgets.zig");

pub const History = hud.MessageList(6); // Deathmatch variant of multiplayer_chat_panel, 0x004AE365.
const chat_label: widgets.Label = .{ .english = "CHAT", .installed = 0x140 };
const heading_y = 9;
const spacing = 11;
const field_height = 20;

pub const Editor = struct {
    line: chat.Line = .{},
    focused: bool = false,

    pub fn frame(editor: *Editor, panel: ui.Rect, pointer: ui.Pointer, keys: *input.Keyboard, typed: *Typed, escaped: bool) ?chat.Line {
        if (pointer.down) editor.focused = field(panel).holds(pointer.at);
        if (!editor.focused) {
            typed.clear();
            editor.focused = !escaped and chat.submitted(keys);
            return null;
        }
        chat.edit(&editor.line, typed, null);
        if (escaped) editor.focused = false;
        if (escaped or !chat.submitted(keys)) return null;
        const line = editor.line;
        editor.line.len = 0;
        return if (chat.trim(line.slice()).len != 0) line else null;
    }
};

pub fn field(panel: ui.Rect) ui.Rect {
    const inset = Layout.footer_inset;
    return .{ .x = panel.x + inset, .y = panel.y + panel.height - inset - field_height, .width = panel.width - 2 * inset, .height = field_height };
}

/// `multiplayer_chat_panel` (0x004AE2D0) puts a scrolling log above the line the pilot types.
pub fn draw(canvas: ui.Canvas, panel: ui.Rect, history: ?*const History, editor: *const Editor) !void {
    widgets.panel(canvas, panel);
    const entry = field(panel);
    const font = canvas.fonts.small;
    const top = panel.y + heading_y;
    try canvas.text(font, .{ entry.x, top }, chat_label.text(canvas.strings.*), ui.white, .left);
    if (history) |lines| {
        const height = entry.y - top - spacing;
        const log = canvas.within(.{ .x = entry.x, .y = top + spacing, .width = entry.width, .height = height });
        const visible = @min(lines.count, @as(usize, @intCast(@max(0, @divTrunc(height, spacing)))));
        for (0..visible) |row| {
            const y = top + spacing * @as(i16, @intCast(row + 1));
            try log.text(font, .{ entry.x, y }, lines.line(lines.count - visible + row), ui.blue, .left);
        }
    }
    widgets.panel(canvas, entry);
    const padding = 5;
    var buffer: [chat.capacity + 1]u8 = undefined;
    var line = editor.line.slice();
    const caret_width = font.textWidth("_");
    while (line.len != 0 and font.textWidth(line) + caret_width > entry.width - 2 * padding)
        line = line[1..];
    @memcpy(buffer[0..line.len], line);
    buffer[line.len] = '_';
    const colour = if (editor.focused) ui.white else ui.blue;
    try canvas.within(entry).text(font, .{ entry.x + padding, entry.y + 3 }, buffer[0 .. line.len + @intFromBool(editor.focused)], colour, .left);
}

test "Escape leaves the editor and Enter sends the shared draft" {
    var editor: Editor = .{};
    var keys: input.Keyboard = .{};
    var typed: Typed = .{};
    const panel: ui.Rect = .{ .x = 20, .y = 100, .width = 200, .height = 120 };
    try std.testing.expectEqual(null, editor.frame(panel, .{ .at = field(panel).centre(), .down = true }, &keys, &typed, false));
    try std.testing.expect(editor.focused);
    for ("Ready") |byte| typed.push(byte);
    keys.down[@backingInt(input.Key.enter)] = true;
    const line = editor.frame(panel, .{}, &keys, &typed, false).?;
    try std.testing.expectEqualStrings("Ready", line.slice());
    try std.testing.expectEqual(null, editor.frame(panel, .{}, &keys, &typed, true));
    try std.testing.expect(!editor.focused);
}
