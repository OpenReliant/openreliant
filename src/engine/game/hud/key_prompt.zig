//! The prompt `WaitForKey` shows while its thread waits for the player to press an action's key or
//! joystick button (`hud_draw`, `0x0048473D` to `0x00484ABC`): PRESS above the middle of the
//! screen, and under it the action's name, then its key drawn on a key cap, after its modifier on a
//! cap of its own, or its joystick button for an action without a key. It shows in every view.

const std = @import("std");

const hud = @import("../hud.zig");
const input = @import("../../input.zig");
const Pen = hud.Pen;

/// The action `WaitForKey` waits for (`hud_key_awaited`, `0x005799BC`), which a mission's start
/// clears (`hud_init`, `0x00483F9C`).
pub const KeyPrompt = struct {
    /// The action; null while nothing waits, which the game keeps as -1.
    action: ?input.controls.Action = null,

    /// Draws the prompt where `hud_draw` does, after the caption, while an action is awaited: its
    /// binding and its key's name as `devices` has them this frame. With no devices, nothing.
    ///
    /// The action's name and `separator` stand left of the middle by half of the prompt's width:
    /// the name's, then for a modifier a wide cap's and `plus`'s, then the key's cap's, whether or
    /// not an action without a key draws a cap.
    ///
    /// **Fix:** the game takes the word of a modifier past Alt from past the four it holds
    /// (`0x004843BC`); OpenReliant writes none on its cap (`input.ControlBinding.Modifier.word`).
    pub fn draw(prompt: KeyPrompt, pen: Pen, devices: ?*const input.Devices) hud.Error!void {
        const action = prompt.action orelse return;
        const known = devices orelse return;
        const binding = known.bindings.get(action);
        var buffer: [line_room]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        writer.print("{s}{s}", .{ pen.strings.string(binding.string) orelse "", separator }) catch {};
        const name = writer.buffered();
        const key = known.key_names.ofBound(binding.key);
        const name_width = width(pen, name);
        const plus_width = width(pen, plus);
        const modified = binding.modifier != .none;
        var whole = name_width + Cap.of(key).width;
        if (modified) whole += Cap.wide.width + plus_width;
        // Everything stands from the left end of the prompt, level with the middle of the screen.
        const middle = pen.middle();
        const origin: [2]i32 = .{ (@as(i32, @intCast(pen.screen[0])) - pen.span(whole)) >> 1, middle[1] };
        _ = try pen.text(pen.moved(origin, .{ 0, -line_up }), name, .left);
        _ = try pen.text(pen.moved(middle, .{ 0, -press_up }), pen.strings.string(input.press_string) orelse "", .centre);
        var along = name_width;
        if (binding.key == 0) {
            const button = binding.button orelse return;
            var joy_buffer: [line_room]u8 = undefined;
            const joy = std.mem.print(&joy_buffer, "{f}", .{input.ButtonName{ .strings = pen.strings, .button = button }}) catch return;
            _ = try pen.text(pen.moved(origin, .{ along + button_gap, -line_up }), joy, .left);
            return;
        }
        if (modified) {
            try Cap.wide.draw(pen, origin, along, binding.modifier.word() orelse "");
            along += Cap.wide.width;
            _ = try pen.text(pen.moved(origin, .{ along, -line_up }), plus, .left);
            along += plus_width;
        }
        try Cap.of(key).draw(pen, origin, along, key);
    }
};

/// What follows the action's name (`0x00502510`), and what stands between a modifier and its key
/// (`0x0050250C`).
const separator = " = ";
const plus = " + ";

/// The most of a line the prompt writes.
const line_room = 0x80;

/// How far up from the middle of the screen the prompt's lines stand, in the display's own pixels:
/// PRESS (`0x00484856`); the action's name, `plus` and a joystick button (`0x0048481D`); the key
/// caps (`0x004848BC`); and the names on them (`0x00484914`).
const press_up = 0x8F;
const line_up = 0x7B;
const cap_up = 0x80;
const cap_text_up = 0x7D;

/// How far right of the action's name a joystick button stands (`0x00484AAD`).
const button_gap = 4;

/// A key cap the prompt draws a key or a modifier on: the display's shape, how much of the
/// prompt's width it takes, and where the name on it is centred, from its left.
const Cap = struct {
    shape: usize,
    width: i32,
    middle: i32,

    /// The wide cap, for a modifier and for a key whose name is longer than `narrow_letters`
    /// (`0x004848C3`, `0x004847DD`, `0x0048490F`).
    const wide: Cap = .{ .shape = 0x175, .width = 0x5C, .middle = 0x2E };
    /// The narrow cap, for a shorter name (`0x00484A10`, `0x004847E2`, `0x00484A51`).
    const narrow: Cap = .{ .shape = 0x174, .width = 0x1C, .middle = 10 };
    /// The longest name the narrow cap takes (`0x004847D8`).
    const narrow_letters = 2;

    /// The cap the key named `name` goes on.
    fn of(name: []const u8) Cap {
        return if (name.len <= narrow_letters) narrow else wide;
    }

    /// Draws the cap `along` the display's own pixels right of the prompt's left end, `name`
    /// centred on it.
    fn draw(cap: Cap, pen: Pen, origin: [2]i32, along: i32, name: []const u8) hud.Error!void {
        try pen.shape(cap.shape, pen.moved(origin, .{ along, -cap_up }));
        _ = try pen.text(pen.moved(origin, .{ along + cap.middle, -cap_text_up }), name, .centre);
    }
};

/// How wide `text` is in the display's font, in its own pixels (`font_text_width`).
fn width(pen: Pen, text: []const u8) i32 {
    return @intCast(pen.font.textWidth(text));
}

test "Cap.of" {
    // A name of one or two letters goes on the narrow cap, a longer one on the wide.
    try std.testing.expectEqual(Cap.narrow, Cap.of("K"));
    try std.testing.expectEqual(Cap.narrow, Cap.of("F1"));
    try std.testing.expectEqual(Cap.wide, Cap.of("TAB"));
    // So does a binding without a key, whose name is none.
    try std.testing.expectEqual(Cap.narrow, Cap.of(""));
}
