//! Text entry shared by the multiplayer lobby and the flight HUD.
const std = @import("std");
const hud = @import("hud.zig");
const input = @import("../input.zig");
const language = @import("language.zig");
const Typed = @import("winmain.zig").Typed;

/// The original flight editor has 64 bytes with its terminator (0x00454805).
pub const capacity = 63;
pub const Line = language.Text(capacity);
/// Maximum measured width of the flight editor (0x00454810).
pub const flight_width = 300;

/// Chat uses the game's Windows-1252 code page. Exclude controls, undefined
/// characters and invisible soft hyphens before displaying or relaying a line.
pub fn printable(byte: u8) bool {
    return switch (byte) {
        0...' ' - 1, 0x7f, 0x81, 0x8d, 0x8f, 0x90, 0x9d, 0xad => false,
        else => true,
    };
}

pub fn trim(words: []const u8) []const u8 {
    return std.mem.trim(u8, words, " \xa0");
}

/// Apply the shared text entry rules to printable chat characters and Backspace.
pub fn edit(line: *Line, typed: *Typed, fit: ?hud.Fit) void {
    while (typed.pop()) |byte| {
        if (byte == hud.backspace or printable(byte)) hud.typeCharacter(byte, &line.bytes, &line.len, fit);
    }
}

pub fn submitted(keys: *input.Keyboard) bool {
    return keys.pressed(@backingInt(input.Key.enter), .none, true) or
        keys.pressed(@backingInt(input.Key.keypad_enter), .none, true);
}

test "chat edits bounded code page text and trims blank submissions" {
    var line: Line = .{};
    var typed: Typed = .{};
    for ("a\x08\n\x81\xad caf\xe9\xa0") |byte| typed.push(byte);
    edit(&line, &typed, null);
    try std.testing.expectEqualStrings("caf\xe9", trim(line.slice()));
    for (0..capacity + 1) |_| typed.push('x');
    edit(&line, &typed, null);
    try std.testing.expectEqual(capacity, line.len);
    try std.testing.expectEqualStrings("", trim(" \xa0 "));
}
