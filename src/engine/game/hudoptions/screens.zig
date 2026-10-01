//! The pause menu's main screen: its items, and what choosing them does.
//! [`pause-menu.md`](../../../../docs/engine/pause-menu.md#screens) describes it, and the screens
//! the original has besides, whose place OpenReliant's settings screen takes.

const std = @import("std");

const hudoptions = @import("../hudoptions.zig");
const menu = @import("menu.zig");
const Context = hudoptions.Context;
const Next = hudoptions.Next;
const Item = menu.Item;
const buttons = menu.buttons;

const Error = menu.Error;

/// The buttons that leave the main screen, out of the pause.
const Leave = enum {
    restart,
    continue_game,
    leave_mission,

    /// The button a screen's `choice` is, where it is one of these.
    fn of(choice: anytype) ?Leave {
        return std.meta.stringToEnum(Leave, @tagName(choice));
    }

    fn next(leave: Leave) Next {
        return switch (leave) {
            .restart => .{ .outcome = .restart },
            .continue_game => .{ .outcome = .continue_mission },
            .leave_mission => .{ .outcome = .leave_mission },
        };
    }
};

/// Draws a screen's `items` under `title`, and returns the one the pointer's button went down on,
/// by its choice.
fn choose(comptime Choice: type, items: *const std.EnumArray(Choice, Item), title: menu.String, context: Context) Error!?Choice {
    const found = try context.ui.draw(&items.values, title, context.pointer) orelse return null;
    if (!context.pointer.pressed) return null;
    return std.EnumArray(Choice, Item).Indexer.keyForIndex(found);
}

/// Pause screen 1, `pause_screen_main` (`0x0048E8D0`): the settings screens by their icons, and the
/// ways out of the pause.
pub const Main = struct {
    const Choice = enum { leave_mission, restart, continue_game, audio, controls, video };

    const items: std.EnumArray(Choice, Item) = .init(.{
        .leave_mission = buttons.leave_mission,
        .restart = buttons.restart,
        .continue_game = buttons.continue_game,
        .audio = icon(0.25, .speaker, .speaker_lit, .audio),
        .controls = icon(0.5, .joystick, .joystick_lit, .control_devices),
        .video = icon(0.75, .monitor, .monitor_lit, .video),
    });

    /// An icon in the middle of the screen, `across` of the way, labelled below it.
    fn icon(across: f32, shape: menu.Shape, shown: menu.Shape, label: menu.String) Item {
        return .{
            .anchor = .{ across, 0.5 },
            .shape = shape,
            .lit = shown,
            .text_offset = .{ 0, 65 },
            .font = .large,
            .string = label,
            .style = .{ .alignment = .centre },
        };
    }

    /// Escape goes on with the mission.
    pub fn frame(_: *Main, context: Context) Error!?Next {
        if (try choose(Choice, &items, .select_an_option, context)) |choice| {
            if (Leave.of(choice)) |way| return way.next();
            return switch (choice) {
                .audio => .{ .screen = .audio },
                .controls => .{ .screen = .controls },
                .video => .{ .screen = .video },
                else => null,
            };
        }
        return if (context.escaped) .{ .outcome = .continue_mission } else null;
    }
};

test "Leave.of" {
    const Choice = enum { audio, restart, continue_game };
    try std.testing.expectEqual(Leave.restart, Leave.of(Choice.restart).?);
    try std.testing.expectEqual(null, Leave.of(Choice.audio));
    try std.testing.expectEqual(Next{ .outcome = .continue_mission }, Leave.of(Choice.continue_game).?.next());
}

test "the main screen's items as the game's table has them" {
    // The icons and their labels (`pause_screen_main`'s own table).
    const audio_icon = Main.items.get(.audio);
    try std.testing.expectEqual([2]f32{ 0.25, 0.5 }, audio_icon.anchor);
    try std.testing.expectEqual(menu.Shape.speaker_lit, audio_icon.lit);
    try std.testing.expectEqual([2]i32{ 0, 65 }, audio_icon.text_offset);
}
