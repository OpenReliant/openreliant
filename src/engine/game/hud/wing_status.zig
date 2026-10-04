//! Window 13 of the display, the wing status (`hud_window_draw`'s case at `0x00486F8E`): THE 45TH,
//! and the ships of the player's wing (`create.Objects.wing`) in a grid three across and two down,
//! the player's first, each with a bar of its weakest armour quadrant, its type's icon and its
//! number in the wing. The icons shake with the display (`hud.Shake`).

const std = @import("std");

const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const hud = @import("../hud.zig");
const mission = @import("../mission.zig");

/// The window's title, THE 45TH, right-aligned where it stands from the window's place.
const title = 0xA6;
const title_at = [2]i32{ -3, -78 };

/// An offset in the display's own pixels, across and down.
const Offset = @Vector(2, i32);

/// Where each slot's bar stands from the window's place: three across, two down. The game keeps
/// the grid's places and takes 24 across and 71 up off each.
const bars_at = [mission.wing_size]Offset{
    .{ -135, -54 }, .{ -88, -54 }, .{ -41, -54 },
    .{ -135, -8 },  .{ -88, -8 },  .{ -41, -8 },
};

/// Where a bar's shapes, its ship's icon and its number stand from the bar.
const shapes_offset: Offset = .{ -1, 1 };
const icon_offset: Offset = .{ 6, 1 };
const number_offset: Offset = .{ 6, -2 };

/// A bar: `bar_height` of the display's own pixels at full armour (`0x004DC914`), and a pane
/// `bar_reach` more across than its left edge. The armour left shows in `level_shape`, and what is
/// lost above it in `lost_shape`, each cut to its part.
const level_shape = 0xF3;
const lost_shape = 0xF2;
const bar_height = 38;
const bar_reach = 3;

/// A ship of the wing as the window shows it: its number in the wing, from 1, where its bar
/// stands, the rows lost from the bar's top, and its icon, if it has one.
pub const Entry = struct {
    number: u8,
    bar_at: Offset,
    lost: i32,
    icon: ?u16,
};

/// The wing's ships the window shows, into `out`: each slot's ship that is still there, is in the
/// player's wing and whose pilot has not ejected. A bar counts the armour from what a ship starts
/// with (`create.ShipCombat.startingArmor`).
///
/// **Fix:** the game counts it from `fullArmor`, one more than a ship starts with, so an undamaged
/// Predator's bar shows a row lost.
pub fn entries(all: *const create.Objects, out: *[mission.wing_size]Entry) []Entry {
    var count: usize = 0;
    for (all.wing, bars_at, 1..) |listed, at, number| {
        const slot = &all.slots[listed orelse continue];
        const object = &slot.object;
        if (object.type.base() == .stand_in or object.wing != .player or object.flags.ejected) continue;
        const combat = slot.combat orelse continue;
        out[count] = .{
            .number = @intCast(number),
            .bar_at = at,
            .lost = lostRows(object.armor, combat.startingArmor()),
            .icon = if (object.wing_icon != 0) object.wing_icon else null,
        };
        count += 1;
    }
    return out[0..count];
}

/// The rows a bar loses from its top (`windows.unlitRows`) for the weakest quadrant's share of
/// `full` armour, and none for armour above full.
pub fn lostRows(armor: gameobj.Quadrants, full: f32) i32 {
    return hud.windows.unlitRows(@min(armor.weakest(), full) / full, bar_height);
}

/// What the window shows a frame: the objects.
pub const Shown = struct {
    all: *const create.Objects,
};

/// `hud_window_draw`'s window 13, in the view ahead: the title, then each of the window's
/// `entries`: its bar, the armour left below what is lost, then its icon and its number.
pub fn draw(shown: Shown, canvas: hud.windows.Canvas) hud.windows.Canvas.Error!void {
    try canvas.string(title, title_at, .right);
    var buffer: [mission.wing_size]Entry = undefined;
    for (entries(shown.all, &buffer)) |entry| {
        const at = entry.bar_at;
        const shapes = at + shapes_offset;
        const left = shapes[0];
        try canvas.shapeIn(level_shape, shapes, .{ left, at[1] + entry.lost, left + bar_reach, at[1] + bar_height });
        if (entry.lost != 0) try canvas.shapeIn(lost_shape, shapes, .{ left, at[1], left + bar_reach, at[1] + entry.lost });
        if (entry.icon) |icon| try canvas.shaky(icon, at + icon_offset);
        try canvas.print("{d}", .{entry.number}, at + number_offset, .left);
    }
}

test entries {
    var fixture: gameobj.testing.Mission = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const all = fixture.objects;
    const player = try fixture.add(.of(.predator), @splat(0));
    const hurt = try fixture.add(.of(.grendel), .{ 1000, 0, 0 });
    const ejected = try fixture.add(.of(.wolverine), .{ 2000, 0, 0 });
    const outsider = try fixture.add(.of(.sabre), .{ 0, 0, 5000 });
    mission.listPlayerWing(all, &.{ player, hurt, ejected });
    all.wing[4] = outsider;
    all.slots[player].object.wing_icon = 0xFC;
    all.slots[ejected].object.flags.ejected = true;
    const full = all.slots[hurt].combat.?.startingArmor();
    all.slots[hurt].object.armor.aft = full / 2;
    var buffer: [mission.wing_size]Entry = undefined;
    const shown = entries(all, &buffer);

    // The player's ship and the one hurt, in their slots' places; not the ejected pilot's, nor a
    // ship outside the wing.
    try std.testing.expectEqual(2, shown.len);
    try std.testing.expectEqual(Entry{ .number = 1, .bar_at = bars_at[0], .lost = 0, .icon = 0xFC }, shown[0]);
    try std.testing.expectEqual(2, shown[1].number);
    try std.testing.expectEqual(bars_at[1], shown[1].bar_at);
    // Its weakest quadrant, at half, loses half the bar; it has no icon.
    try std.testing.expectEqual(bar_height / 2, shown[1].lost);
    try std.testing.expectEqual(null, shown[1].icon);
}

test lostRows {
    try std.testing.expectEqual(0, lostRows(.all(59), 59));
    var armor: gameobj.Quadrants = .all(59);
    armor.right = 0;
    try std.testing.expectEqual(bar_height, lostRows(armor, 59));
    // Armour above full counts as full.
    try std.testing.expectEqual(0, lostRows(.all(90), 59));
}
