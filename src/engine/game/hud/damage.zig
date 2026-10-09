//! Window 4 of the display, the damage display (`hud_window_draw`'s case at `0x00487DC5`): how
//! well the player's weapons, engines and shields still work as the armour wears
//! (`main.armorConditions`), a bar each (`hud_damage_bar`). The icons shake with the display
//! (`hud.Shake`).

const std = @import("std");

const math = @import("../../surrender/math.zig");
const gameobj = @import("../gameobj.zig");
const hud = @import("../hud.zig");

/// The window's title, DAMAGE, right-aligned where it stands from the window's place.
const title = 0x28D;
const title_at = [2]i32{ -2, 2 };

/// The systems the window shows, from the top.
pub const System = enum {
    weapons,
    engines,
    shields,

    /// How well it works, from 0 to 1: the object's gun condition, its armour's speed factor and
    /// its shield condition.
    pub fn condition(system: System, object: *const gameobj.GameObject) f32 {
        return switch (system) {
            .weapons => object.gun_condition,
            .engines => object.armor_speed_factor,
            .shields => object.shield_condition,
        };
    }
};

/// A system's row, each piece where it stands from the window's place: its icon, its name, the
/// rule under them, and its bar.
const Row = struct {
    icon: u16,
    icon_at: [2]i32,
    name: u16,
    name_at: [2]i32,
    rule_at: [2]i32,
    bar_at: [2]i32,
};

const rows: std.EnumArray(System, Row) = .init(.{
    .weapons = .{ .icon = 0xC1, .icon_at = .{ -136, 23 }, .name = 0x285, .name_at = .{ -102, 24 }, .rule_at = .{ -132, 42 }, .bar_at = .{ -98, 45 } },
    .engines = .{ .icon = 0xBD, .icon_at = .{ -134, 59 }, .name = 0x286, .name_at = .{ -102, 62 }, .rule_at = .{ -132, 80 }, .bar_at = .{ -98, 83 } },
    .shields = .{ .icon = 0xBE, .icon_at = .{ -135, 97 }, .name = 0x287, .name_at = .{ -102, 101 }, .rule_at = .{ -132, 119 }, .bar_at = .{ -98, 122 } },
});

/// The rule under each row's icon and name.
const rule_shape = 0x160;

/// A bar: the orange `level_shape` whole, and the red `lost_shape` over it from where the level
/// ends, `bar_length` of the display's own pixels along it at a level of 1 (`0x004DC91C`).
const level_shape = 0xE0;
const lost_shape = 0xDF;
const bar_length = 77;

/// How far the right and bottom edges of `lost_shape`'s pane stand from its left and top ones:
/// the bar's length across, and 6 down.
const lost_reach = [2]i32{ bar_length, 6 };

/// `hud_damage_bar` (`0x00488B30`)'s pane for `lost_shape`, for a bar standing at `at` at `level`:
/// its left, top, right and bottom edges, inclusive, from a pixel before and above where the
/// level ends. `lost_shape` stands where the bar does, so the pane shows it past the level.
pub fn lostPane(at: [2]i32, level: f32) [4]i32 {
    const left = at[0] + math.round(level * bar_length) - 1;
    const top = at[1] - 1;
    return .{ left, top, left + lost_reach[0], top + lost_reach[1] };
}

/// What the window shows a frame: the player's ship.
pub const Shown = struct {
    object: *const gameobj.GameObject,
};

/// `hud_window_draw`'s window 4, in the view ahead: the title, each row's icon and name, the
/// rules, then the bars (`hud_damage_bar`).
pub fn draw(shown: Shown, canvas: hud.windows.Canvas) hud.windows.Canvas.Error!void {
    try canvas.string(.damage_title, title, title_at, .right);
    for (rows.values) |row| {
        try canvas.shaky(row.icon, row.icon_at);
        try canvas.string(.damage_names, row.name, row.name_at, .left);
    }
    for (rows.values) |row| try canvas.shape(rule_shape, row.rule_at);
    for (std.enums.values(System)) |system| {
        const at = rows.get(system).bar_at;
        try canvas.shape(level_shape, at);
        try canvas.shapeIn(lost_shape, at, lostPane(at, system.condition(shown.object)));
    }
}

test lostPane {
    const at = rows.get(.weapons).bar_at;
    // Whole, the pane starts a pixel before the bar's end, so none of the red shows.
    try std.testing.expectEqual([4]i32{ at[0] + 76, at[1] - 1, at[0] + 76 + 0x4D, at[1] + 5 }, lostPane(at, 1));
    // Worn to nothing, it covers the whole bar.
    try std.testing.expectEqual(at[0] - 1, lostPane(at, 0)[0]);
    // Half worn, the red starts halfway, rounded as the game rounds.
    try std.testing.expectEqual(at[0] + 38 - 1, lostPane(at, 0.5)[0]);
}

test "each bar shows its own system" {
    var object = std.mem.zeroes(gameobj.GameObject);
    object.gun_condition = 0.25;
    object.armor_speed_factor = 0.5;
    object.shield_condition = 1;
    try std.testing.expectEqual(0.25, System.weapons.condition(&object));
    try std.testing.expectEqual(0.5, System.engines.condition(&object));
    try std.testing.expectEqual(1, System.shields.condition(&object));
}
