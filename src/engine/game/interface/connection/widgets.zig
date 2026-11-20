//! Shared controls for OpenReliant's multiplayer browser and lobby.
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const language = @import("../../language.zig");
const Layout = @import("layout.zig");

pub const Label = struct {
    english: []const u8 = "",
    installed: u16 = 0,

    pub fn text(label: Label, strings: language.Language) []const u8 {
        return strings.stringOr(label.installed, label.english);
    }
};

/// The vertical arrow pair in frntend3.spr, shared by the setup description and chat.
pub const ScrollArrows = struct {
    x: i16,
    y: i16,

    pub fn under(arrows: ScrollArrows, at: [2]i32) ?ui.Arrow {
        const top: ui.Rect = .{ .x = arrows.x, .y = arrows.y, .width = 28, .height = 14 };
        var bottom = top;
        bottom.y += 15;
        if (top.holds(at)) return .up;
        if (bottom.holds(at)) return .down;
        return null;
    }

    pub fn draw(arrows: ScrollArrows, canvas: ui.Canvas, art: *hud.Art, hover: ?ui.Arrow) !void {
        try canvas.shape(art, if (hover == .up) 0x1A else 0x19, .{ arrows.x, arrows.y });
        if (hover == .down) try canvas.shape(art, 0x16, .{ arrows.x, arrows.y + 17 });
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
    try drawFittedLabel(canvas, at, width, null, words, colour, alignment);
}

pub fn fittedRowLabel(canvas: ui.Canvas, cell: ui.Rect, words: []const u8, colour: [3]f32) !void {
    try drawFittedLabel(canvas, .{ cell.x, cell.y }, cell.width, cell.height, words, colour, .left);
}

fn drawFittedLabel(canvas: ui.Canvas, at: [2]i32, width: i16, row_height: ?i16, words: []const u8, colour: [3]f32, alignment: hud.Align) !void {
    const font = canvas.fonts.small;
    const measured: f32 = @floatFromInt(@max(1, font.textWidth(words)));
    const fit = @min(1, @as(f32, @floatFromInt(width)) / measured);
    const scale = canvas.scale();
    var point = canvas.point(at);
    if (row_height) |height| point[1] += hud.round(try ui.centredInkOffset(font, @as(f32, @floatFromInt(height)) * scale, scale * fit));
    _ = try hud.drawTextIn(font, canvas.gpa, canvas.target, point, words, hud.atBrightness(colour, canvas.brightness), alignment, scale * fit, null);
}

pub fn title(canvas: ui.Canvas, at: [2]i32, label: Label) !void {
    _ = try hud.drawTextIn(canvas.fonts.large, canvas.gpa, canvas.target, canvas.point(at), label.text(canvas.strings.*), hud.atBrightness(ui.white, canvas.brightness), .left, canvas.scale() * 1.37, null);
}

pub fn button(canvas: ui.Canvas, art: *hud.Art, box: ui.Rect, label: Label, enabled: bool, lit: bool) !void {
    try alignedButton(canvas, art, box, label, enabled, lit, .left);
}

pub fn alignedButton(canvas: ui.Canvas, art: *hud.Art, box: ui.Rect, label: Label, enabled: bool, lit: bool, edge: enum { left, right }) !void {
    const painted = canvas.dimmedUnless(enabled);
    const words = label.text(canvas.strings.*);
    const width = box.width - Layout.label_offset;
    const label_x, const shape_x = if (edge == .right) right: {
        const right_edge = box.x + box.width;
        const text_width: i16 = @intCast(@min(canvas.fonts.small.textWidth(words), @as(u32, @intCast(width))));
        break :right .{ right_edge, right_edge - text_width - Layout.label_offset };
    } else .{ box.x + Layout.label_offset, box.x };
    try hud.drawShape(art, painted.gpa, painted.target, if (lit) 0x18 else 0x17, painted.point(.{ shape_x, box.y + 2 }), hud.atBrightness(ui.white, painted.brightness), painted.scale() / Layout.text_scale);
    try fittedLabel(painted, .{ label_x, box.y }, width, words, if (lit) ui.white else ui.blue, if (edge == .right) .right else .left);
}
