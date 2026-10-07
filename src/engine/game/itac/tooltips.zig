//! The tooltips `itac.cpp` keeps (`tooltips_init`, `0x00440B30`): a few words under the pointer as
//! it rests on a button, shown after a second, or at once where a tooltip showed in the last 30
//! game ticks (`tooltips_update`, `0x00440C40`; `tooltip_draw`, `0x00440D80`). OpenReliant shows the
//! ITAC's, which name its buttons (`itac_tooltips_add`, `0x00440EB0`).
//!
//! Not ported: the tooltips of the other screens that show them, the saved games, the loadout and
//! one more ([#813](https://github.com/OpenReliant/openreliant/issues/813)).
//!
//! **Fix:** the game adds ten of the ITAC's tooltips, the tenth read from the start of the table
//! after the nine. Its rectangle lies far off the screen, so it never shows. OpenReliant adds the
//! nine.
//!
//! **Unverified:** the file of `tooltips_clear` and the code after it. `tooltip_add`'s assertion
//! names `itac.cpp` (`0x00440BDD`), and the rest lies after it, before `loadout.cpp`'s.

const std = @import("std");

const hud = @import("../hud.zig");
const canvas_module = @import("../interface/canvas.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;

/// The font tooltips are written in, which `tooltips_init` reads (`0x004E99B4`).
pub const font_name = "newfont.fnt";

/// A tooltip: the rectangle the pointer rests on, and its string.
pub const Tooltip = struct { rect: Rect, string: u16 };

/// How long the pointer rests on a button before its tooltip shows, in game ticks, unless a
/// tooltip showed within `recent` of them (`0x00440CB2`, `0x00440CAF`).
const delay = 100;
const recent = 30;

/// Where a tooltip stands: `below` lower than the pointer, or where that would put it past
/// `lowest`, `raised` higher than that (`0x00440CE3`).
const below = 38;
const lowest = 450;
const raised = 57;

/// The screen's width, which a tooltip keeps `right_margin` clear of (`0x00440DE8`).
const screen_width = 640;
const right_margin = 6;

/// The box round the text, from `box_left` and `box_top` of it to `box_right` past its end and
/// `box_bottom` below it, filled with palette entry `fill` and edged with `edge`, which the text is
/// written in too, from `text_at` (`0x00440E0E` on).
const box_left = 1;
const box_top = 3;
const box_right = 5;
const box_bottom = 15;
const text_at: [2]i32 = .{ 2, -2 };
const fill = 0;
const edge = 100;

/// The palette of `itacgfx.spr` a tooltip is drawn with (`0x00440D8B`).
const palette = 29;

pub const Tooltips = struct {
    /// The tooltip the pointer rests on (`0x005203EC`); none where it rests on none.
    current: ?usize = null,
    /// The game tick it shows from (`+0x08` of its record).
    due: u32 = 0,
    /// The game tick a tooltip last showed (`0x005202F8`).
    last_shown: u32 = 0,
    /// Where it shows (`0x005207D8`, `0x005207DC`), which follows the pointer until it shows.
    at: [2]i32 = .{ 0, 0 },

    /// `tooltips_update` at game tick `ticks`, the pointer at `pointer`: the first of `list` that
    /// the pointer rests on, if its tooltip shows now.
    pub fn update(tips: *Tooltips, list: []const Tooltip, pointer: [2]i32, ticks: u32) ?usize {
        const found = for (list, 0..) |tip, index| {
            if (tip.rect.holds(pointer)) break index;
        } else null;
        const index = found orelse {
            tips.current = null;
            return null;
        };
        if (tips.current != index) {
            tips.current = index;
            if (ticks > tips.last_shown + recent) {
                tips.due = ticks + delay;
            } else {
                tips.due = ticks;
                tips.follow(pointer);
            }
        }
        if (ticks < tips.due) {
            tips.follow(pointer);
            return null;
        }
        tips.last_shown = ticks;
        return index;
    }

    /// Where a tooltip stands as the pointer is at `pointer`.
    fn follow(tips: *Tooltips, pointer: [2]i32) void {
        const y = pointer[1] + below;
        tips.at = .{ pointer[0], if (y > lowest) y - raised else y };
    }

    /// `tooltip_draw` (`0x00440D80`): `text` in `font` in its box, kept clear of the screen's right
    /// edge, with `shapes`' colours.
    pub fn draw(tips: Tooltips, canvas: Canvas, font: *hud.Opened, shapes: *canvas_module.Shapes, text: []const u8) canvas_module.Error!void {
        shapes.usePalette(palette);
        const width: i32 = @intCast(font.textWidth(text));
        const x = if (tips.at[0] + width + right_margin > screen_width) screen_width - right_margin - width else tips.at[0];
        const y = tips.at[1];
        const left = x - box_left;
        const top = y - box_top;
        const right = x + width + box_right;
        const bottom = y + box_bottom;
        const edge_colour = colourOf(shapes, edge);
        canvas.wipe(.{ left, top }, .{ right, bottom - 1 }, colourOf(shapes, fill));
        canvas.line(.{ left, top }, .{ right, top }, edge_colour);
        canvas.line(.{ right, top }, .{ right, bottom }, edge_colour);
        canvas.line(.{ right, bottom }, .{ left, bottom }, edge_colour);
        canvas.line(.{ left, bottom }, .{ left, top }, edge_colour);
        try canvas.text(font, .{ x + text_at[0], y + text_at[1] }, text, edge_colour, .left);
    }
};

/// Entry `index` of the palette `shapes` draws with.
fn colourOf(shapes: *canvas_module.Shapes, index: u8) [3]f32 {
    const colour = shapes.art.paletteColour(index);
    return colour[0..3].*;
}

test "Tooltips.update" {
    const list = [_]Tooltip{
        .{ .rect = .{ .x = 12, .y = 422, .width = 58, .height = 51 }, .string = 0x712 },
        .{ .rect = .{ .x = 81, .y = 422, .width = 58, .height = 51 }, .string = 0x713 },
    };
    var tips: Tooltips = .{ .last_shown = 0 };
    // Off the buttons, none shows.
    try std.testing.expectEqual(null, tips.update(&list, .{ 300, 300 }, 1000));
    // Resting on the first, it shows a second later, the box following the pointer meanwhile and
    // raised where it would stand too low.
    try std.testing.expectEqual(null, tips.update(&list, .{ 40, 440 }, 1000));
    try std.testing.expectEqual(null, tips.update(&list, .{ 41, 441 }, 1099));
    try std.testing.expectEqual([2]i32{ 41, 441 + below - raised }, tips.at);
    try std.testing.expectEqual(0, tips.update(&list, .{ 42, 442 }, 1100).?);
    try std.testing.expectEqual([2]i32{ 41, 441 + below - raised }, tips.at);
    // The second shows at once, one having shown within 30 ticks.
    try std.testing.expectEqual(1, tips.update(&list, .{ 90, 440 }, 1120).?);
    // Off and back after long enough, it waits again.
    _ = tips.update(&list, .{ 300, 300 }, 1200);
    try std.testing.expectEqual(null, tips.update(&list, .{ 90, 440 }, 1200));
}
