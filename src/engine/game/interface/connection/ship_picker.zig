//! The multiplayer fighter selector uses the installed ITAC's pictures and records.
const std = @import("std");
const ui = @import("../canvas.zig");
const hud = @import("../../hud.zig");
const language = @import("../../language.zig");
const itac = @import("../../itac.zig");
const choices = @import("choice_list.zig");
const widgets = @import("widgets.zig");
const Fighter = @import("../../dmscenarios.zig").Fighter;
const Picker = @This();

pub const Action = union(enum) { cancel, select: Fighter };
pub const Art = struct { pictures: ?*ui.Shapes, strings: language.Language };

preview: Fighter,
under: ?usize = null,

const names = [_][]const u8{ "Predator", "Naginata", "Grendel", "Crusader", "Coyote", "Mirage", "Tempest", "Patriot", "Wolverine", "Reaper", "Shroud", "Phoenix" };
const options = choices.options(Fighter, &names);
const panel: ui.Rect = .{ .x = 44, .y = 85, .width = 552, .height = 320 };
const rows: ui.Rect = .{ .x = 72, .y = 145, .width = 168, .height = choices.height * options.len };
const cancel: ui.Rect = .{ .x = 72, .y = 375, .width = 160, .height = 20 };
const confirm: ui.Rect = .{ .x = 261, .y = 375, .width = 160, .height = 20 };
const title: widgets.Label = .{ .english = "CHOOSE SHIP" };
const pick_label: widgets.Label = .{ .english = "SELECT SHIP" };
const cancel_label: widgets.Label = .{ .english = "CANCEL" };
const preview_scale = 0.82;

pub fn label(ship: Fighter) widgets.Label {
    return options[@backingInt(ship)].label;
}

fn entry(ship: Fighter) itac.tables.Fighter {
    for (itac.tables.fighters[0]) |fighter| if (fighter.ship_type == @backingInt(ship)) return fighter;
    unreachable;
}

pub fn frame(picker: *Picker, pointer: ui.Pointer, escaped: bool) ?Action {
    picker.under = choices.hit(rows, pointer.at);
    if (escaped) return .cancel;
    if (!pointer.down) return null;
    if (picker.under) |index| picker.preview = @fromBackingInt(@intCast(index));
    if (cancel.holds(pointer.at)) return .cancel;
    if (confirm.holds(pointer.at)) return .{ .select = picker.preview };
    return null;
}

pub fn draw(picker: Picker, canvas: ui.Canvas, art: *hud.Art, assets: Art) !void {
    widgets.modal(canvas, panel);
    try widgets.title(canvas, .{ 72, 103 }, title);
    try choices.drawList(canvas, rows, &options, @backingInt(picker.preview), picker.under);
    const profile = entry(picker.preview);
    const font = canvas.fonts.small;
    try canvas.text(font, .{ 261, 147 }, label(picker.preview).text(canvas.strings.*), ui.white, .left);
    if (assets.strings.string(profile.type)) |class| try canvas.text(font, .{ 261, 163 }, class, ui.blue, .left);
    if (assets.pictures) |pictures| if (profile.shape >= 0) {
        const shape: usize = @intCast(profile.shape);
        pictures.usePalette(itac.paletteBefore(&itac.fighters.palette_blocks, shape));
        try hud.drawShape(&pictures.art, canvas.gpa, canvas.target, shape, canvas.point(.{ 291, 178 }), hud.atBrightness(ui.white, canvas.brightness), canvas.scale() * preview_scale);
    };
    var buffer: [512]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buffer);
    for (profile.guns) |gun| {
        const name = assets.strings.string(gun.name) orelse continue;
        if (line.end != 0) line.writeAll(" / ") catch break;
        if (gun.count > 0) line.print("{d} ", .{gun.count}) catch break;
        line.writeAll(name) catch break;
    }
    for (profile.specials) |id| {
        const name = assets.strings.string(id) orelse continue;
        if (line.end != 0) line.writeAll(" / ") catch break;
        line.writeAll(name) catch break;
    }
    try canvas.wrapped(font, .{ 261, 331 }, line.buffered(), ui.blue, .left, .{ .width = 305, .height = 13, .most = 3 });
    try widgets.button(canvas, art, cancel, cancel_label, true, false);
    try widgets.button(canvas, art, confirm, pick_label, true, false);
}

test "the ITAC has a picture for every multiplayer fighter" {
    for (std.enums.values(Fighter)) |fighter| try std.testing.expect(entry(fighter).shape >= 0);
    var picker: Picker = .{ .preview = .predator };
    try std.testing.expectEqual(null, picker.frame(.{ .at = .{ rows.x + 10, rows.y + choices.height + 4 }, .down = true }, false));
    try std.testing.expectEqual(.naginata, picker.frame(.{ .at = confirm.centre(), .down = true }, false).?.select);
}
