//! Window 10 of the display, the mission's objectives (`hud_window_draw`'s case at `0x00486C9E`):
//! MISSION OBJECTIVES, then the objective the window shows (`hud.Objectives.shown`), headed as the
//! current objective or as an objective, with its name beneath, broken into lines.

const std = @import("std");

const hud = @import("../hud.zig");
const Objectives = hud.Objectives;

/// The window's title, MISSION OBJECTIVES, right-aligned where it stands from the window's place.
const title = 0x128;
const title_at = [2]i32{ -3, -78 };

/// The heading of the objective shown, right-aligned beneath the title: Current Objective for the
/// current one, Objective for any other, or No current objectives. where paging found none.
const current_heading = 0x12A;
const heading = 0x12B;
const none_heading = 0x54A;
const heading_at = [2]i32{ -3, -66 };

/// The objective's name, from the left, in lines at most `name_width` wide, `name_line_height`
/// apart, at most `name_lines` of them.
const name_at = [2]i32{ -140, -48 };
const name_width = 140;
const name_line_height = 14;
const name_lines = 6;

/// What the window shows in place of a name where the table has none (`0x0050252C`).
const no_name = "ERROR: No mission Objectives defined!";

/// What the window shows a frame: the mission's objectives.
pub const Shown = struct {
    objectives: *const Objectives,
};

/// What the window says of the objective shown, with the string of its name, or null where the
/// window says no objective is shown.
pub const Words = struct {
    heading: u16,
    name: ?Name,

    pub const Name = union(enum) {
        string: u16,
        text: []const u8,
        missing,
    };
};

/// The heading and the name the window shows for `objectives`.
///
/// **Fix:** the game reads the state and the name of mission 0's objectives from before the
/// table; OpenReliant shows a mission the table has no row for as it shows those after the table,
/// an objective with no name.
pub fn words(objectives: *const Objectives) Words {
    if (objectives.none_shown) return .{ .heading = none_heading, .name = null };
    const state = objectives.states[objectives.shown];
    return .{
        .heading = if (state == .current) current_heading else heading,
        .name = if (objectives.name(objectives.shown)) |named| switch (named) {
            .string => |string| .{ .string = string },
            .text => |text| .{ .text = text },
        } else .missing,
    };
}

/// `hud_window_draw`'s window 10, in the view ahead: the title, the heading, and beneath it the
/// objective's name.
pub fn draw(shown: Shown, canvas: hud.windows.Canvas) hud.windows.Canvas.Error!void {
    try canvas.string(.objectives_title, title, title_at, .right);
    const said = words(shown.objectives);
    try canvas.string(.objectives_heading, said.heading, heading_at, .right);
    const name = said.name orelse return;
    const text = switch (name) {
        .string => |string| canvas.pen.strings.string(string) orelse return,
        .text => |text| text,
        .missing => no_name,
    };
    try canvas.wrapped(.objectives_name, text, name_at, .left, name_width, name_line_height, name_lines);
}

test words {
    var objectives: Objectives = .{};
    objectives.reset(1, false, null);
    // The first objective is current, named by the table.
    try std.testing.expectEqual(Words{ .heading = current_heading, .name = .{ .string = 297 } }, words(&objectives));
    // The second, listed, is an objective.
    objectives.page();
    try std.testing.expectEqual(Words{ .heading = heading, .name = .{ .string = 300 } }, words(&objectives));
    // With every objective hidden, paging finds none, and the window says so.
    objectives.states = @splat(.hidden);
    objectives.page();
    try std.testing.expectEqual(Words{ .heading = none_heading, .name = null }, words(&objectives));
    // A mission the table has no row for has objectives with no names.
    objectives.reset(0, false, null);
    try std.testing.expectEqual(Words{ .heading = heading, .name = .missing }, words(&objectives));
}
