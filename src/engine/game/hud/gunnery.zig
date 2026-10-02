//! Window 1, the gunnery display (`hud_window_draw`'s case at `0x004871FB`): the player's ship as
//! a wire frame, the shape the mission's start picks for its type (`hud.State.wire_frame`), with
//! the group of guns that fires lit and its gun's name, or every group but a Nova Cannon's lit
//! under FULL GUNS, whether a pair of guns fires together or in turn, and the rounds left on the
//! ships whose guns fire them. Its shapes shake with the display (`hud.Shake`).

const std = @import("std");

const create = @import("../create.zig");
const guns = @import("../guns.zig");
const hud = @import("../hud.zig");

/// Where each piece stands from the window's place.
const frame_at = [2]i32{ 11, -134 };
const name_at = [2]i32{ 1, -157 };
const pairing_at = [2]i32{ 1, -139 };
const rounds_shape_at = [2]i32{ 4, -17 };
const rounds_at = [2]i32{ 21, -19 };

/// The names of the gun types, from the Laser Cannon's to the Nova Cannon's, a string each in
/// turn (`gunName`), and FULL GUNS's.
const first_gun_name = 0x3A9;
const full_guns_name = 0x297;

/// The string naming gun type `kind`, for the types the display names: the fighters' guns, the
/// Laser Cannon to the Nova Cannon.
fn gunName(kind: guns.GunType) ?u16 {
    if (kind.onTurrets()) return null;
    return first_gun_name + @as(u16, @intFromEnum(kind));
}

/// The shapes that show a pair of guns firing together and firing in turn.
const together_shape = 0xF0;
const in_turn_shape = 0xF1;

/// The shape before the rounds left.
const rounds_shape = 0xEE;

/// The most pieces the window shows: the wire frame, FULL GUNS's name, a group lit for each group,
/// and the rounds.
pub const max_items = 2 + guns.max_groups + 2;

/// A piece of the window, where it stands from the window's place.
pub const Item = union(enum) {
    shape: struct { index: usize, at: [2]i32 },
    string: struct { id: u16, at: [2]i32 },
    rounds: struct { count: i32, at: [2]i32 },
};

/// What the window shows a frame: the player's ship, and the wire frame for its type.
pub const Shown = struct {
    slot: *const create.Slot,
    wire_frame: ?u16,
};

/// The pieces of the window for the player's ship in `slot`, whose wire frame is `wire_frame`,
/// into `out`: nothing without a wire frame. The wire frame, then:
///
/// - Firing one group: its first gun's name, the group lit where there are more, and for a group
///   of two guns but the Nova Cannon's, whether they fire together or in turn. The game takes the
///   gun mode's bits from `synchronised` up off `in_turn_shape` for it; those above it nothing
///   sets.
/// - Firing every group: FULL GUNS's name, and each group lit where there are more, but one whose
///   first gun is a Nova Cannon, which FULL GUNS leaves out.
///
/// Last, on the Grendel, the Wolverine and the Reaper, the rounds left.
pub fn items(slot: *const create.Slot, wire_frame: ?u16, out: *[max_items]Item) []Item {
    const frame = wire_frame orelse return out[0..0];
    const object = &slot.object;
    const groups: usize = @intCast(@max(slot.groupCount(), 0));
    var count: usize = 0;
    out[count] = .{ .shape = .{ .index = frame, .at = frame_at } };
    count += 1;
    const mode = object.gun_mode;
    if (!mode.all) {
        const lead = slot.groupLead(mode.group);
        if (lead) |kind| if (gunName(kind)) |name| {
            out[count] = .{ .string = .{ .id = name, .at = name_at } };
            count += 1;
        };
        if (groups > 1) {
            out[count] = .{ .shape = .{ .index = frame + @as(usize, mode.group) + 1, .at = frame_at } };
            count += 1;
        }
        if (slot.gun_groups[mode.group].paired() and lead != .nova_cannon) {
            out[count] = .{ .shape = .{ .index = if (mode.synchronised) together_shape else in_turn_shape, .at = pairing_at } };
            count += 1;
        }
    } else {
        out[count] = .{ .string = .{ .id = full_guns_name, .at = name_at } };
        count += 1;
        if (groups > 1) for (0..@min(groups, guns.max_groups)) |group| {
            if (slot.groupLead(group) == .nova_cannon) continue;
            out[count] = .{ .shape = .{ .index = frame + group + 1, .at = frame_at } };
            count += 1;
        };
    }
    switch (object.type) {
        .grendel, .wolverine, .reaper => {
            out[count] = .{ .shape = .{ .index = rounds_shape, .at = rounds_shape_at } };
            out[count + 1] = .{ .rounds = .{ .count = object.rounds, .at = rounds_at } };
            count += 2;
        },
        else => {},
    }
    return out[0..count];
}

/// `hud_window_draw`'s window 1, in the view ahead: each of the window's `items`, the text
/// left-aligned.
pub fn draw(shown: Shown, canvas: hud.windows.Canvas) hud.windows.Canvas.Error!void {
    var buffer: [max_items]Item = undefined;
    for (items(shown.slot, shown.wire_frame, &buffer)) |item| switch (item) {
        .shape => |shape| try canvas.shaky(shape.index, shape.at),
        .string => |string| try canvas.string(string.id, string.at, .left),
        .rounds => |rounds| try canvas.print("{d}", .{rounds.count}, rounds.at, .left),
    };
}

const gameobj = @import("../gameobj.zig");

/// A ship of three groups of two guns each, as the Phoenix carries them: the Pulse Cannons, the
/// Gattling Lasers and the Nova Cannons.
const testing = struct {
    const wire_frame: u16 = 0x112;
    const barrel = guns.testing.barrel;

    const fitted = [_]guns.Fitted{
        barrel(.pulse_cannon),    barrel(.pulse_cannon),
        barrel(.gattling_lasers), barrel(.gattling_lasers),
        barrel(.nova_cannon),     barrel(.nova_cannon),
    };

    const table: [guns.max_groups]guns.Group = table: {
        var groups = guns.no_groups;
        groups[0] = .{ .first = 0, .second = 1 };
        groups[1] = .{ .first = 2, .second = 3 };
        groups[2] = .{ .first = 4, .second = 5 };
        break :table groups;
    };

    const combat = std.mem.zeroInit(create.ShipCombat, .{ .gun_groups = 3 });
};

test items {
    var fitted = testing.fitted;
    var slot: create.Slot = .{ .object = std.mem.zeroes(gameobj.GameObject), .combat = &testing.combat, .guns = &fitted, .gun_groups = &testing.table };
    var buffer: [max_items]Item = undefined;
    const frame = testing.wire_frame;

    // A ship with no wire frame shows nothing.
    try std.testing.expectEqual(0, items(&slot, null, &buffer).len);

    // The first group: its gun's name, the group lit, and its two guns firing in turn.
    const first = items(&slot, frame, &buffer);
    try std.testing.expectEqualDeep(&[_]Item{
        .{ .shape = .{ .index = frame, .at = frame_at } },
        .{ .string = .{ .id = gunName(.pulse_cannon).?, .at = name_at } },
        .{ .shape = .{ .index = frame + 1, .at = frame_at } },
        .{ .shape = .{ .index = in_turn_shape, .at = pairing_at } },
    }, first);

    // Firing together, the shape before.
    slot.object.gun_mode.synchronised = true;
    try std.testing.expectEqual(together_shape, items(&slot, frame, &buffer)[3].shape.index);

    // The Nova Cannons: their name and their group, but not how they fire.
    slot.object.gun_mode.group = 2;
    const nova = items(&slot, frame, &buffer);
    try std.testing.expectEqual(3, nova.len);
    try std.testing.expectEqual(gunName(.nova_cannon).?, nova[1].string.id);
    try std.testing.expectEqual(frame + 3, nova[2].shape.index);

    // FULL GUNS: its name, and every group lit but the Nova Cannons'.
    slot.object.gun_mode.all = true;
    const all = items(&slot, frame, &buffer);
    try std.testing.expectEqual(4, all.len);
    try std.testing.expectEqual(full_guns_name, all[1].string.id);
    try std.testing.expectEqual(frame + 1, all[2].shape.index);
    try std.testing.expectEqual(frame + 2, all[3].shape.index);

    // A Reaper counts its rounds.
    slot.object.type = .reaper;
    slot.object.rounds = 250;
    const reaper = items(&slot, frame, &buffer);
    try std.testing.expectEqual(null, gunName(.turret_lasers));
    try std.testing.expectEqual(rounds_shape, reaper[4].shape.index);
    try std.testing.expectEqual(250, reaper[5].rounds.count);
}
