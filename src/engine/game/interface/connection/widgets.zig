//! Shared controls for OpenReliant's multiplayer browser and lobby.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const language = @import("../../language.zig");
const Layout = @import("layout.zig");

pub const Label = struct {
    english: []const u8 = "",
    installed: u16 = 0,

    pub fn text(label: Label, strings: language.Language) []const u8 {
        const value = strings.string(label.installed) orelse return label.english;
        return if (std.mem.trim(u8, value, " \t\r\n").len == 0) label.english else value;
    }
};

pub fn panel(canvas: ui.Canvas, rect: ui.Rect) void {
    const start = canvas.point(.{ rect.x, rect.y });
    const end = canvas.point(.{ rect.x + rect.width, rect.y + rect.height });
    hud.drawFilled(canvas.target, .{ .left = @floatFromInt(start[0]), .top = @floatFromInt(start[1]), .right = @floatFromInt(end[0]), .bottom = @floatFromInt(end[1]) }, .{ 0.015, 0.033, 0.048, 0.67 });
    canvas.box(.{ rect.x, rect.y }, .{ rect.width, rect.height });
}

pub fn modal(canvas: ui.Canvas, rect: ui.Rect) void {
    canvas.wipe(.{ rect.x, rect.y }, .{ rect.x + rect.width, rect.y + rect.height }, hud.rgb(0x09171D));
    canvas.box(.{ rect.x, rect.y }, .{ rect.width, rect.height });
}

pub fn fittedLabel(canvas: ui.Canvas, at: [2]i32, width: i16, words: []const u8, colour: [3]f32, alignment: hud.Align) !void {
    const font = canvas.fonts.small;
    const measured: f32 = @floatFromInt(@max(1, font.textWidth(words)));
    const fit = @min(1, @as(f32, @floatFromInt(width)) / measured);
    _ = try hud.drawTextIn(font, canvas.gpa, canvas.target, canvas.point(at), words, hud.atBrightness(colour, canvas.brightness), alignment, canvas.scale() * fit, null);
}

pub fn title(canvas: ui.Canvas, at: [2]i32, label: Label) !void {
    _ = try hud.drawTextIn(canvas.fonts.large, canvas.gpa, canvas.target, canvas.point(at), label.text(canvas.strings.*), hud.atBrightness(ui.white, canvas.brightness), .left, canvas.scale() * 1.37, null);
}

pub fn button(canvas: ui.Canvas, art: *hud.Art, box: ui.Rect, label: Label, enabled: bool, lit: bool) !void {
    const painted = canvas.dimmedUnless(enabled);
    try hud.drawShape(art, painted.gpa, painted.target, if (lit) 0x18 else 0x17, painted.point(.{ box.x, box.y + 2 }), hud.atBrightness(ui.white, painted.brightness), painted.scale() / Layout.text_scale);
    try fittedLabel(painted, .{ box.x + Layout.label_offset, box.y }, box.width - Layout.label_offset, label.text(canvas.strings.*), if (lit) ui.white else ui.blue, .left);
}
