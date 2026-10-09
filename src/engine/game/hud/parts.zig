//! The parts of the game's instruments that the mods' displays can place on their own: each text
//! the flight display writes, the face in the radio's window and the power ball
//! ([#998](https://github.com/OpenReliant/openreliant/issues/998),
//! [#999](https://github.com/OpenReliant/openreliant/issues/999)). A display moves, scales or hides
//! a part without standing in for its instrument, and gives a text part another alignment or
//! other words (`Placement`). Each part draws through a placing of its own inside its instrument's
//! (`hud.Pen.partTextIn`, `hud.Pen.partImage`), so it grows from its own place, and where it draws
//! is kept for the scripts (`hud.State.part_bounds`).
//!
//! **Improvement:** OpenReliant's, for the mods' displays.

const std = @import("std");

const hud = @import("../hud.zig");

/// A part of one of the game's instruments (`hud.Instrument`), named after it.
pub const Part = enum {
    /// The name scripts know these by.
    pub const script_name = "HudPart";

    /// The date the launch types out, and the cursor after it while it types.
    caption_text,
    caption_cursor,
    /// `WaitForKey`'s prompt: PRESS, the action's name, the key's name on its cap or the joystick's
    /// button, and the modifier's name on its cap with the plus after it.
    key_prompt_press,
    key_prompt_action,
    key_prompt_key,
    key_prompt_modifier,
    key_prompt_plus,
    /// The view's name at the top of the screen.
    view_name_text,
    /// The line `DisplaySubTitle` shows.
    subtitle_text,
    /// The message lines.
    messages_text,
    /// The readouts' figures.
    fuel_figure,
    kills_figure,
    countermeasures_figure,
    /// The targeting cluster's figures: the speed the ship makes, and the speed the throttle asks.
    gauges_speed,
    gauges_throttle,
    /// The target's range by its brackets, and by the arrow toward a target off the screen.
    target_markers_range,
    /// The clock's figures.
    clock_text,
    /// The speaker's name over the face in the radio's window.
    radio_speaker,
    /// The face of whoever speaks, in the radio's window.
    radio_face,
    /// The gunnery window's gun name, or FULL GUNS, and its rounds left.
    gunnery_gun,
    gunnery_rounds,
    /// The missile window's count and missile name.
    missiles_count,
    missiles_name,
    /// The target displays' lines: the target's name, its pilot's, its range and speed, and the
    /// subtarget's name.
    target_display_name,
    target_display_pilot,
    target_display_range,
    target_display_speed,
    target_display_subtarget,
    /// The damage window's title, and the systems' names.
    damage_title,
    damage_names,
    /// The power window's title, its percentages and its ball.
    power_title,
    power_figures,
    power_ball,
    /// The objectives window's title, the objective's heading, and its name.
    objectives_title,
    objectives_heading,
    objectives_name,
    /// The radio's menu, in either of the windows that show it: its title, the items' numbers, and
    /// the items.
    comms_title,
    comms_numbers,
    comms_items,
    /// The wing status window's title, and the wingmen's numbers.
    wing_status_title,
    wing_status_numbers,

    /// Whether it's a picture rather than text, which takes no alignment or words.
    pub fn picture(part: Part) bool {
        return switch (part) {
            .radio_face, .power_ball => true,
            else => false,
        };
    }
};

/// The most bytes of words a text part can be given, in the game's code page.
pub const most_words = 64;

/// The words a text part writes in place of its own, in the game's code page.
pub const Words = struct {
    bytes: [most_words]u8 = undefined,
    len: std.math.IntFittingRange(0, most_words) = 0,

    /// `text`, which must fit; null for text longer than `most_words`.
    pub fn of(text: []const u8) ?Words {
        if (text.len > most_words) return null;
        var words: Words = .{ .len = @intCast(text.len) };
        @memcpy(words.bytes[0..text.len], text);
        return words;
    }

    pub fn slice(words: *const Words) []const u8 {
        return words.bytes[0..words.len];
    }
};

/// Where a mod's display puts a part: moved, scaled from its own place or hidden, as an instrument
/// is (`hud.Placement`), and for a text part, the alignment and the words it's written with in place
/// of its own.
pub const Placement = struct {
    place: hud.Placement = .{},
    alignment: ?hud.Align = null,
    words: ?Words = null,
};

/// The parts' placements for a frame, and where each drew.
pub const Parts = struct {
    placements: std.EnumArray(Part, Placement) = .initFill(.{}),
    /// The box each part's draws covered this frame, moved; null for one that didn't draw.
    drawn: std.EnumArray(Part, ?hud.Clip) = .initFill(null),

    /// Takes `box`, where `part` drew, into where it drew this frame.
    pub fn note(parts: *Parts, part: Part, box: ?hud.Clip) void {
        const kept = parts.drawn.getPtr(part);
        kept.* = .joined(kept.*, box orelse return);
    }
};

test Words {
    const words = Words.of("SPEAKER").?;
    try std.testing.expectEqualStrings("SPEAKER", words.slice());
    try std.testing.expectEqual(null, Words.of(&@as([most_words + 1]u8, @splat('x'))));
}

test Parts {
    var parts: Parts = .{};
    parts.note(.radio_speaker, null);
    try std.testing.expectEqual(null, parts.drawn.get(.radio_speaker));
    parts.note(.radio_speaker, .{ .left = 10, .top = 10, .right = 20, .bottom = 20 });
    parts.note(.radio_speaker, .{ .left = 0, .top = 15, .right = 15, .bottom = 30 });
    try std.testing.expectEqual(hud.Clip{ .left = 0, .top = 10, .right = 20, .bottom = 30 }, parts.drawn.get(.radio_speaker).?);
    try std.testing.expect(Part.radio_face.picture());
    try std.testing.expect(!Part.radio_speaker.picture());
}
