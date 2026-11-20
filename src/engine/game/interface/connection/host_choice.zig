//! The game type chooser between the multiplayer browser and a host's lobby.
const std = @import("std");
const ui = @import("../canvas.zig");
const dialog = @import("../dialog.zig");
const hud = @import("../../hud.zig");
const input = @import("../../../input.zig");
const widgets = @import("widgets.zig");
const HostChoice = @This();

pub const Kind = enum { deathmatch, cooperative };
const Action = enum { deathmatch, cooperative, cancel };
const deathmatch: ui.Rect = .{ .x = 329, .y = 239, .width = 153, .height = 20 };
const cooperative: ui.Rect = .{ .x = 158, .y = 239, .width = 153, .height = 20 };
const cancel: ui.Rect = .{ .x = 270, .y = 274, .width = 100, .height = 20 };
const heading: widgets.Label = .{ .english = "GAME TYPE", .installed = 0x139 };
const coop_label: widgets.Label = .{ .english = "CO-OP", .installed = 0x13D };
const deathmatch_label: widgets.Label = .{ .english = "DEATHMATCH", .installed = 0x13E };
const cancel_label: widgets.Label = .{ .english = "BACK", .installed = 0xF7 };

hover: ?Action = null,

pub fn frame(choice: *HostChoice, pointer: ui.Pointer, keys: *input.Keyboard) ?Action {
    choice.hover = if (deathmatch.holds(pointer.at)) .deathmatch else if (cooperative.holds(pointer.at)) .cooperative else if (cancel.holds(pointer.at)) .cancel else null;
    if (keys.pressed(input.scan.escape, .none, true)) return .cancel;
    if (keys.pressed(@backingInt(input.Key.enter), .none, true) or keys.pressed(@backingInt(input.Key.keypad_enter), .none, true)) return .deathmatch;
    return if (pointer.down) choice.hover else null;
}

pub fn draw(choice: HostChoice, canvas: ui.Canvas, art: *hud.Art, dialog_art: *hud.Art) ui.Error!void {
    try dialog.drawBox(canvas, dialog_art);
    try canvas.text(canvas.fonts.large, .{ 320, 203 }, heading.text(canvas.strings.*), ui.white, .centre);
    try widgets.button(canvas, art, cooperative, coop_label, true, choice.hover == .cooperative);
    try widgets.button(canvas, art, deathmatch, deathmatch_label, true, choice.hover == .deathmatch);
    try widgets.button(canvas, art, cancel, cancel_label, true, choice.hover == .cancel);
}

test "the host chooser selects either game type" {
    var keys: input.Keyboard = .{};
    var choice: HostChoice = .{};
    try std.testing.expectEqual(.cooperative, choice.frame(.{ .at = cooperative.centre(), .down = true }, &keys).?);
    try std.testing.expectEqual(.deathmatch, choice.frame(.{ .at = deathmatch.centre(), .down = true }, &keys).?);
    try std.testing.expectEqual(.cancel, choice.frame(.{ .at = cancel.centre(), .down = true }, &keys).?);
}
