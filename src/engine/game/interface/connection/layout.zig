//! The multiplayer browser fits the 4:3 backdrop. On larger windows its panels
//! grow faster than its text and controls, leaving room for more server rows.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");

pub const Layout = @This();
pub const inset = 7;
pub const footer_inset = 12;
// Shapes 0x17 and 0x18 start one sprite pixel to the left of their anchor.
pub const button_left_overhang = 1;
// The button's last painted row is 13 layout units below the hit target's top.
pub const button_last_row = 13;
pub const row_height = 21;
pub const text_scale = 1.28;
pub const label_offset = 25;
pub const Control = enum { internet, lan, refresh, host, selected, connect, back };
pub const Point = [2]i32;

share: f32,
list: ui.Rect,
details: ui.Rect,
field: ui.Rect,

pub fn init(window: [2]u32) Layout {
    const scale = @max(0.01, ui.scaleFor(window));
    const control_scale = std.math.clamp(scale * 480 / 760, 0.83, 1.22);
    const share = std.math.clamp(control_scale * text_scale / scale, 0.5, 1);
    return atShare(share);
}

pub fn atShare(share: f32) Layout {
    const left = axis(48, 320, share);
    const right = axis(592, 320, share);
    const split = axis(432, 320, share);
    const top = axis(161, 240, share);
    const bottom = axis(359, 240, share);
    return .{
        .share = share,
        .list = .{ .x = left, .y = top, .width = split - left, .height = bottom - top },
        .details = .{ .x = split + 2 * inset, .y = top, .width = right - split - 2 * inset, .height = bottom - top },
        .field = .{ .x = left, .y = axis(391, 240, share), .width = split - left, .height = 23 },
    };
}

fn axis(value: i32, centre: i16, share: f32) i16 {
    return centre + @as(i16, @intCast(hud.round(@as(f32, @floatFromInt(value - centre)) / share)));
}

pub fn point(layout: Layout, from: Point) Point {
    return .{ axis(from[0], 320, layout.share), axis(from[1], 240, layout.share) };
}

pub fn title(layout: Layout) Point {
    return layout.point(.{ 48, 101 });
}

pub fn control(layout: Layout, which: Control) ui.Rect {
    const list = layout.list;
    const details = layout.details;
    const source_y: i16 = @intCast(layout.point(.{ 0, 139 })[1]);
    const width: i16 = switch (which) {
        .internet, .selected, .host, .back => 108,
        .refresh, .connect => 96,
        .lan => 146,
    };
    const x: i16, const y: i16 = switch (which) {
        .internet => .{ list.x, source_y },
        .lan => .{ list.x + 108, source_y },
        .refresh => .{ list.x + list.width - width, source_y },
        .host => .{ details.x + details.width - width, @intCast(layout.title()[1]) },
        .selected => .{ details.x + footer_inset + button_left_overhang, details.y + details.height - footer_inset - button_last_row },
        .connect => .{ details.x + inset, layout.field.y + 1 },
        .back => .{ list.x, @intCast(layout.point(.{ 0, 437 })[1]) },
    };
    return .{ .x = x, .y = y, .width = width, .height = 20 };
}

pub fn rows(layout: Layout) usize {
    return @intCast(@divTrunc(layout.list.height - row_height - inset, row_height));
}

pub fn rowTop(layout: Layout, offset: usize) i16 {
    return layout.list.y + row_height + @as(i16, @intCast(offset)) * row_height;
}
