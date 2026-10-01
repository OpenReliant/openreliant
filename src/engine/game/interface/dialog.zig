//! The front end's dialog asking YES or NO (`interface_confirm`, `0x0042AA80`), which QUIT and the
//! screens' other questions put up over a screen.

const std = @import("std");

const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;

/// The dialog's shapes (`dialog_shapes`): its box in the second palette's colours, and its buttons,
/// lit under the pointer, in the first's. The shapes and places below come from
/// `interface_confirm_draw`.
pub const shapes_name = "quit.spr";
const box_shape = 6;
const button_shape = 3;
const lit_button_shape = 4;
const box_at: [2]i32 = .{ 0x72, 0xB1 };

/// YES and NO (`dialog_buttons`, `0x004E5CB8`), and their labels, written in the large font
/// against them.
pub const buttons = [_]Rect{
    .{ .x = 0x11E, .y = 0x10D, .width = 25, .height = 16 },
    .{ .x = 0x146, .y = 0x10D, .width = 25, .height = 16 },
};
const yes_string = 0x28F;
const no_string = 0x290;
const yes_at: [2]i32 = .{ 0x11A, 0x107 };
const no_at: [2]i32 = .{ 0x162, 0x107 };

/// How the question is laid out: centred on `message_at`, in lines 400 wide, 14 apart, at most 10.
const message_at: [2]i32 = .{ 0x140, 0xD0 };
const message_lines: Canvas.Lines = .{ .width = 400, .height = 14, .most = 10 };

/// The question up, and how it has been answered.
pub const Confirm = struct {
    /// The question: a string (`dialog_message`), or words a screen puts together, as the controls
    /// screen's conflict writes them into `dialog_text` and asks with `interface_confirm(-1)`.
    message: canvas_module.Label.Text,
    /// The button under the pointer (`dialog_button`): 0 YES, 1 NO.
    under: ?usize = null,
    /// The answer given, which holds until the pointer's button comes up.
    answer: ?bool = null,

    /// A pass of `interface_confirm`'s loop (`0x0042AA80`), `escaped` whether Escape went down
    /// since the last: Escape answers NO, a click on a button answers it, and the answer holds
    /// until the button comes up, when the dialog closes with it.
    pub fn frame(confirm: *Confirm, pointer: Pointer, escaped: bool) ?bool {
        if (confirm.answer) |answer| return if (pointer.down) null else answer;
        if (escaped) {
            confirm.answer = false;
            return confirm.frame(pointer, false);
        }
        confirm.under = canvas_module.hit(&buttons, pointer.at);
        if (confirm.under) |button| if (pointer.down) {
            confirm.answer = button == 0;
        };
        return null;
    }

    /// `interface_confirm_draw` (`0x0042AB60`), over the screen's drawing while the dialog is up
    /// (`dialog_open`): the box, the buttons with the one under the pointer lit, the question, and
    /// YES and NO.
    pub fn draw(confirm: Confirm, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        try canvas.shape(art, box_shape, box_at);
        for (buttons, 0..) |button, index| {
            const shape: usize = if (confirm.under == index) lit_button_shape else button_shape;
            try canvas.shape(art, shape, .{ button.x, button.y });
        }
        const font = canvas.fonts.large;
        const question = switch (confirm.message) {
            .string => |id| canvas.strings.string(id) orelse "",
            .words => |words| words,
        };
        try canvas.wrapped(font, message_at, question, canvas_module.blue, .centre, message_lines);
        try canvas.string(font, yes_at, yes_string, canvas_module.blue, .right);
        try canvas.string(font, no_at, no_string, canvas_module.blue, .left);
    }
};

/// The box saying the game could not be saved (`save_error_dialog`, `0x0042A870`), which the saved
/// games screen puts up over itself as a save fails (`save_error_open`, `0x0052026C`): the dialog's
/// box, its OK button, lit under the pointer, the message, and OK's label.
pub const SaveError = struct {
    /// Whether OK is under the pointer (`dialog_button`).
    under: bool = false,
    /// Set as OK is clicked or Escape pressed, until the pointer's button comes up.
    closing: bool = false,

    /// Its OK button (`0x0042A870`), which a click closes it by, and where its box's parts stand
    /// (`save_error_draw`, `0x0042A950`).
    pub const ok_button: Rect = .{ .x = 310, .y = 269, .width = 25, .height = 16 };
    const error_text = 0x561;
    const error_at: [2]i32 = .{ 320, 180 };
    const ok_string = 0x316;
    const ok_at: [2]i32 = .{ 360, 263 };

    /// A pass of its loop: Escape, or a click on OK, closes it once the pointer's button comes up
    /// (`0x0042A91C`). A press held as it opens counts. Whether it has closed.
    pub fn frame(box: *SaveError, pointer: Pointer, escaped: bool) bool {
        if (box.closing) return !pointer.down;
        box.under = ok_button.holds(pointer.at);
        if (escaped or (box.under and pointer.down)) {
            box.closing = true;
            return !pointer.down;
        }
        return false;
    }

    pub fn draw(box: SaveError, canvas: Canvas, art: *hud.Art) canvas_module.Error!void {
        try canvas.shape(art, box_shape, box_at);
        try canvas.shape(art, if (box.under) lit_button_shape else button_shape, .{ ok_button.x, ok_button.y });
        if (canvas.strings.string(error_text)) |words| try canvas.wrapped(canvas.fonts.small, error_at, words, canvas_module.blue, .centre, message_lines);
        try canvas.string(canvas.fonts.large, ok_at, ok_string, canvas_module.blue, .right);
    }
};

test SaveError {
    var box: SaveError = .{};
    // A click off OK does nothing; on it, the box closes once the button comes up.
    try std.testing.expect(!box.frame(.{ .at = .{ 10, 10 }, .down = true }, false));
    try std.testing.expect(!box.frame(.{ .at = .{ 315, 275 }, .down = true }, false));
    try std.testing.expect(box.under and box.closing);
    try std.testing.expect(box.frame(.{ .at = .{ 315, 275 } }, false));
    // Escape closes it at once where no button is down.
    box = .{};
    try std.testing.expect(box.frame(.{}, true));
}

test Confirm {
    var confirm: Confirm = .{ .message = .{ .string = 0x374 } };
    // Over nothing, nothing is answered.
    try std.testing.expectEqual(null, confirm.frame(.{ .at = .{ 10, 10 }, .down = true }, false));
    // A click on NO answers it once the button comes up.
    try std.testing.expectEqual(null, confirm.frame(.{ .at = .{ 340, 275 }, .down = true }, false));
    try std.testing.expectEqual(1, confirm.under);
    try std.testing.expectEqual(null, confirm.frame(.{ .at = .{ 290, 275 }, .down = true }, false));
    try std.testing.expectEqual(false, confirm.frame(.{ .at = .{ 290, 275 } }, false));
    // YES, clicked, answers yes.
    confirm = .{ .message = .{ .string = 0x374 } };
    _ = confirm.frame(.{ .at = .{ 295, 275 }, .down = true }, false);
    try std.testing.expectEqual(true, confirm.frame(.{ .at = .{ 295, 275 } }, false));
    // Escape answers no.
    confirm = .{ .message = .{ .string = 0x374 } };
    try std.testing.expectEqual(false, confirm.frame(.{}, true));
}
