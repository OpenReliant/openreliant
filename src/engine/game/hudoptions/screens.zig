//! The pause menu's screens: the main one, and the video settings. Each is its items and
//! what choosing them does; a settings screen also keeps what it opened with for CANCEL CHANGES,
//! and saves as it is left. [`pause-menu.md`](../../../../docs/engine/pause-menu.md#screens)
//! describes them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const camera = @import("../camera.zig");
const hog_snd = @import("../hog_snd.zig");
const hudoptions = @import("../hudoptions.zig");
const menu = @import("menu.zig");
const Context = hudoptions.Context;
const Next = hudoptions.Next;
const Settings = hudoptions.Settings;
const Item = menu.Item;
const Slider = menu.Slider;
const Selector = menu.Selector;
const buttons = menu.buttons;
const Volumes = hog_snd.Volumes;
const CockpitSetting = camera.CockpitSetting;

const Error = menu.Error;

/// The buttons that leave a screen, whatever screen: OK back to the main screen, and the others
/// out of the pause.
const Leave = enum {
    ok,
    restart,
    continue_game,
    leave_mission,

    /// The button a screen's `choice` is, where it is one of these.
    fn of(choice: anytype) ?Leave {
        return std.meta.stringToEnum(Leave, @tagName(choice));
    }

    fn next(leave: Leave) Next {
        return switch (leave) {
            .ok => .{ .screen = .main },
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

/// Pause screen 4, `pause_screen_video` (`0x0048F260`): GRAPHICS CONFIGURATION, the brightness
/// where the device sets it, and the view a mission's launch ends in.
pub const Video = struct {
    /// The settings as the screen opened, which CANCEL CHANGES puts back (`video_saved_view`,
    /// `video_saved_brightness`).
    kept_view: CockpitSetting = .cockpit,
    kept_brightness: f32 = 1,
    /// Whether the pointer holds the brightness's knob (`drag_effects`, which the screen shares).
    held: bool = false,

    const brightness: Slider = .{ .down = -30, .label = .brightness, .low = 0.5, .high = 2 };
    const view: Selector = .{ .down = 30, .label = .default_view };

    /// `[Device]`, where the video settings are kept (`0x004E8628`), and their keys (`0x004E8630`,
    /// `0x004E8614`).
    pub const section = "Device";
    pub const view_key = "View";
    pub const gamma_key = "gamma";
    /// The file keeps the brightness in hundredths.
    pub const gamma_scale = 100;

    const Choice = enum {
        ok,
        restart,
        continue_game,
        reset_defaults,
        brightness_track,
        brightness_knob,
        view_box,
        view_back,
        view_forward,
        view_value,
        cancel_changes,
    };

    /// `pause_video_enter` (`0x0048F230`).
    pub fn enter(video: *Video, settings: Settings) void {
        video.* = .{ .kept_view = settings.camera.setting, .kept_brightness = settings.brightness.* };
    }

    /// First the brightness's knob, where held, follows the pointer, or, with no button down, is
    /// let go of; then the items, and what was chosen. OK and Escape go back to the main screen.
    pub fn frame(video: *Video, context: Context) Error!?Next {
        const settings = context.settings;
        if (!context.pointer.down) {
            video.held = false;
        } else if (video.held) {
            settings.brightness.* = brightness.valueAt(context.ui, context.pointer.at[0]);
        }
        const arrows = view.items(viewName(settings.camera.setting));
        const items: std.EnumArray(Choice, Item) = .init(.{
            .ok = buttons.ok,
            .restart = buttons.restart,
            .continue_game = buttons.continue_game,
            .reset_defaults = buttons.reset_defaults,
            .brightness_track = if (settings.gamma) brightness.track() else Item.none,
            .brightness_knob = if (settings.gamma) brightness.knob(settings.brightness.*) else Item.none,
            .view_box = arrows.get(.box),
            .view_back = arrows.get(.back),
            .view_forward = arrows.get(.forward),
            .view_value = arrows.get(.value),
            .cancel_changes = buttons.cancel_changes,
        });

        if (try choose(Choice, &items, .graphics_configuration, context)) |choice| {
            if (Leave.of(choice)) |way| return way.next();
            switch (choice) {
                // **Fix.** The game sets the cockpit mode to 0, no cockpit, with the setting
                // 0, the cockpit's; OpenReliant sets the mode the setting stands for.
                .reset_defaults => set(settings, .cockpit, 1),
                .cancel_changes => set(settings, video.kept_view, video.kept_brightness),
                .brightness_knob => video.held = true,
                .view_back => set(settings, stepped(settings.camera.setting, Selector.step(.back)), settings.brightness.*),
                .view_forward => set(settings, stepped(settings.camera.setting, Selector.step(.forward)), settings.brightness.*),
                else => {},
            }
        }
        return if (context.escaped) .{ .screen = .main } else null;
    }

    /// `video_settings_save` (`0x0048F5A0`), as the screen is left: the brightness and the view to
    /// `[Device]`.
    pub fn leave(_: *Video, settings: Settings) Allocator.Error!void {
        try settings.file.writeInt(section, gamma_key, menu.round(settings.brightness.* * gamma_scale));
        try settings.file.writeInt(section, view_key, @intFromEnum(settings.camera.setting));
    }

    /// The view setting and the brightness, the camera's cockpit mode following the setting.
    fn set(settings: Settings, setting: CockpitSetting, level: f32) void {
        settings.camera.setting = setting;
        settings.camera.cockpit_mode = setting.mode();
        settings.brightness.* = level;
    }

    /// The setting `by` from `setting`, as the arrows step it: forward past the last to the
    /// first, and back before the first to the last. Each looks only at the end it goes toward, so
    /// a setting the game doesn't know goes back by one.
    fn stepped(setting: CockpitSetting, by: i32) CockpitSetting {
        const last: i64 = std.enums.values(CockpitSetting).len - 1;
        const next = @as(i64, @intFromEnum(setting)) + by;
        if (by > 0 and next > last) return @enumFromInt(0);
        if (by < 0 and next < 0) return @enumFromInt(last);
        return @enumFromInt(next);
    }

    fn viewName(setting: CockpitSetting) menu.String {
        return switch (setting) {
            .cockpit => .cockpit_view,
            .chase => .chase_view,
            else => .no_cockpit_view,
        };
    }
};

test "Leave.of" {
    const Choice = enum { ok, reset_defaults, continue_game };
    try std.testing.expectEqual(Leave.ok, Leave.of(Choice.ok).?);
    try std.testing.expectEqual(null, Leave.of(Choice.reset_defaults));
    try std.testing.expectEqual(Next{ .outcome = .continue_mission }, Leave.of(Choice.continue_game).?.next());
}

test "Video.stepped" {
    try std.testing.expectEqual(CockpitSetting.chase, Video.stepped(.cockpit, 1));
    try std.testing.expectEqual(CockpitSetting.none, Video.stepped(.cockpit, -1));
    try std.testing.expectEqual(CockpitSetting.cockpit, Video.stepped(.none, 1));
    // A setting the game doesn't know goes forward to the first, and back by one.
    try std.testing.expectEqual(CockpitSetting.cockpit, Video.stepped(@enumFromInt(4), 1));
    try std.testing.expectEqual(@as(CockpitSetting, @enumFromInt(4)), Video.stepped(@enumFromInt(5), -1));
}

test "the screens' items as the game's tables have them" {
    // The main screen's icons and labels (`pause_screen_main`'s own table).
    const audio_icon = Main.items.get(.audio);
    try std.testing.expectEqual([2]f32{ 0.25, 0.5 }, audio_icon.anchor);
    try std.testing.expectEqual(menu.Shape.speaker_lit, audio_icon.lit);
    try std.testing.expectEqual([2]i32{ 0, 65 }, audio_icon.text_offset);
    // The video screen's arrows (`video_menu_items`, `0x00502BB0`, items 6 to 9).
    const arrows = Video.view.items(.chase_view);
    try std.testing.expectEqual([2]i32{ -33, 30 }, arrows.get(.back).offset);
    try std.testing.expectEqual(menu.Place.Edge.end, arrows.get(.forward).place.across);
    try std.testing.expectEqual(menu.Shape.none, arrows.get(.back).shape);
    try std.testing.expectEqual(menu.String.chase_view, arrows.get(.value).string);
    // Byte for byte, the placing and the style words are the game's: 0x13 and a right-aligned 2.
    try std.testing.expectEqual(0x13, @as(u32, @bitCast(arrows.get(.box).place)));
    try std.testing.expectEqual(2, @as(u32, @bitCast(arrows.get(.box).style)));
}
