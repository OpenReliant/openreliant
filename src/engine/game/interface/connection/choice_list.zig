//! The option lists in the multiplayer setup dialogs.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const widgets = @import("widgets.zig");
const Layout = @import("layout.zig");

pub const Option = struct { label: widgets.Label, available: bool = true };
pub const height = 18;

pub fn options(comptime T: type, labels: []const []const u8) [std.enums.values(T).len]Option {
    var out: [std.enums.values(T).len]Option = undefined;
    for (std.enums.values(T), labels, &out) |tag, label, *option| option.* = .{
        .label = .{ .english = label, .installed = tag.nameString() },
        .available = if (@hasDecl(T, "available")) tag.available() else true,
    };
    return out;
}

pub fn hit(box: ui.Rect, at: [2]i32) ?usize {
    if (!box.holds(at)) return null;
    return @intCast(@divTrunc(at[1] - box.y, height));
}

pub fn drawList(canvas: ui.Canvas, box: ui.Rect, items: []const Option, selected: usize, hover: ?usize) !void {
    canvas.wipe(.{ box.x, box.y }, .{ box.x + box.width, box.y + box.height }, hud.rgb(0x09171D));
    canvas.box(.{ box.x, box.y }, .{ box.width, box.height });
    for (items, 0..) |option, i| {
        const at = box.y + height * @as(i16, @intCast(i));
        const lit = i == selected or (option.available and i == hover);
        if (lit) canvas.wipe(.{ box.x + 2, at + 2 }, .{ box.x + box.width - 2, at + height - 1 }, hud.rgb(0x193C4C));
        const colour = if (lit) ui.white else if (option.available) ui.blue else hud.rgb(0x6F8790);
        try widgets.fittedLabel(canvas, .{ box.x + Layout.inset, at + 3 }, box.width - 2 * Layout.inset, option.label.text(canvas.strings.*), colour, .left);
    }
}
