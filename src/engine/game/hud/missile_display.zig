//! Window 2, the missile display: the player's missiles in a ring, a type an entry, round the one
//! armed at six o'clock (`hud_missile_ring`, `0x00501CC8`, and `hud_missile_armed`, `0x005656B0`).
//! `hud_missile_ring_build` (`0x00484060`) builds it from the player's racks as a mission starts and
//! after each re-arm, each launch counts one off the armed entry (`input.launchMissile`), and
//! ROTATE MISSILES turns it (`Ring.turn`). The window shows the armed missile's name and count, and
//! each missile in its place round the ring (`draw`).

const std = @import("std");
const assert = std.debug.assert;

const gameobj = @import("../gameobj.zig");
const hog_snd = @import("../hog_snd.zig");
const betty = hog_snd.betty;
const hud = @import("../hud.zig");
const missiles = @import("../missiles.zig");
const Type = missiles.Type;

/// How many entries the ring holds.
pub const max_entries = 10;

/// An entry of the ring (five halfwords).
pub const Entry = extern struct {
    /// Missiles left, or `no_entry`.
    count: i16 = no_entry,
    /// Where it stands round the ring, from 0, the armed one at six o'clock.
    place: i16 = 0,
    /// The first of its type's ten shapes in the display's set, one a place: the shape drawn is
    /// this and its place.
    shape: i16 = 0,
    /// Its name's text.
    name: i16 = 0,
    type: Type = .none,

    /// The count of an entry the ring doesn't hold.
    pub const no_entry: i16 = -1;

    /// The missiles it has left, where the ring holds it.
    pub fn left(entry: Entry) ?i16 {
        return if (entry.count == no_entry) null else entry.count;
    }

    comptime {
        assert(@sizeOf(Entry) == 10);
    }
};

test "Entry.left" {
    try std.testing.expectEqual(null, (Entry{}).left());
    try std.testing.expectEqual(0, (Entry{ .count = 0 }).left());
    try std.testing.expectEqual(12, (Entry{ .count = 12 }).left());
}

/// Each type's first shape and name, for the Screamer to the Hawk (`hud_missile_ring_build`'s own
/// tables); the rest have none.
const shapes = [_]i16{ 0x56, 0x4C, 0x24, 0x42, 0x1A, 0x6A, 0x60, 0x38, 0x2E };
const names = [_]i16{ 0x124, 0x123, 0x121, 0x11E, 0x127, 0x126, 0x125, 0x120, 0x122 };

pub const Ring = struct {
    entries: [max_entries]Entry = @splat(.{}),
    /// The armed entry.
    armed: u16 = 0,
    /// `player_missiles_left` (`0x0052A400`): the entries' counts together, which nothing reads.
    left: i32 = 0,
    /// `0x00569978`: until when Betty says no more that the armed missile has run out, as a launch
    /// is refused for want of a lock.
    empty_warned_until: u32 = 0,
    /// The voice Betty last said a missile's name on (`missile_name_voice`, `0x00566660`).
    /// `0x0057BF3C` counts 150 ticks from then, and nothing reads it.
    name_voice: ?u8 = null,

    /// `hud_missile_ring_build`: an entry for each missile type the ship's racks hold, but the fuel
    /// pod, in the order its racks first come, with the missiles of all its racks; the middle entry
    /// armed, those before it round the ring from it one way and those after it the other.
    pub fn build(ring: *Ring, object: *const gameobj.GameObject) void {
        ring.entries = @splat(.{});
        var count: usize = 0;
        for (object.fittedRacks()) |rack| {
            if (rack.type.base() == .fuel_pod) continue;
            const left: i16 = @truncate(rack.count);
            for (ring.entries[0..count]) |*entry| {
                if (entry.type == rack.type) {
                    entry.count += left;
                    break;
                }
            } else {
                if (count == max_entries) continue;
                // A missile a mod adds shows as its base, under its own name where it has one.
                const index = rack.type.baseIndex() orelse 0;
                const own_name = if (rack.type.added()) |added| added.label_string else null;
                ring.entries[count] = .{
                    .count = left,
                    .place = @intCast(count),
                    .shape = if (index < shapes.len) shapes[index] else 0,
                    .name = if (own_name) |name| std.math.cast(i16, name) orelse 0 else if (index < names.len) names[index] else 0,
                    .type = rack.type,
                };
                count += 1;
            }
        }
        ring.armed = @intCast(count / 2);
        for (ring.entries[0..count]) |*entry| entry.place = @intCast(@mod(@as(i16, @intCast(ring.armed)) - entry.place, max_entries));
        ring.left = 0;
        for (ring.entries) |entry| ring.left += entry.left() orelse continue;
    }

    pub fn armedEntry(ring: *Ring) *Entry {
        return &ring.entries[ring.armed];
    }

    /// ROTATE MISSILES's turn of the ring (`hud_target_keys`, `0x0048B6B0`): clockwise, where the
    /// entry after the armed one is live, every live entry moves one place on round the ring, and
    /// the one it brings to six o'clock is armed; anticlockwise, where the armed entry is not the
    /// first, every live entry moves one place back likewise. The ring doesn't wrap: the keys walk
    /// from the first entry to the last. Whether it turned.
    pub fn turn(ring: *Ring, way: Turn) bool {
        switch (way) {
            .clockwise => if (ring.entries[(ring.armed + 1) % max_entries].left() == null) return false,
            .anticlockwise => if (ring.armed == 0) return false,
        }
        var turned = false;
        for (&ring.entries, 0..) |*entry, index| {
            if (entry.left() == null) continue;
            const place = entry.place + @as(i16, if (way == .clockwise) 1 else -1);
            entry.place = @intCast(@mod(place, max_entries));
            if (entry.place == 0 and place == @as(i16, if (way == .clockwise) max_entries else 0)) {
                ring.armed = @intCast(index);
                turned = true;
            }
        }
        return turned;
    }

    /// After a turn, Betty says the armed missile's name, where it is live, ending what she said
    /// last (`missile_name_voice`, `0x00566660`).
    pub fn sayName(ring: *Ring, sound: *hog_snd.Sound) void {
        const armed = ring.armedEntry();
        if (armed.left() == null) return;
        const name = bettyName(armed.type) orelse return;
        if (ring.name_voice) |voice| sound.endVoice(voice);
        ring.name_voice = betty.say(sound, name);
    }
};

/// Which way ROTATE MISSILES turns the ring.
pub const Turn = enum { clockwise, anticlockwise };

/// Betty's name of a missile type, the Screamer to the Hawk, which is her line of the same name.
fn bettyName(missile: missiles.Type) ?betty.Line {
    return switch (missile.base()) {
        inline .screamer, .raptor, .havoc, .jack_hammer, .bandit, .vagabond, .solomon, .imp, .hawk => |named| @field(betty.Line, @tagName(named)),
        else => null,
    };
}

/// What the window shows a frame: the ring.
pub const Shown = struct {
    ring: *const Ring,
};

/// Where the armed missile's count, its name and the ring stand from the window's place.
const count_at = [2]i32{ -1, 0x43 };
const name_at = [2]i32{ 0, 1 };
const ring_at = [2]i32{ 0, 0x47 };

/// `hud_window_draw`'s window 2 (`0x00486E8F`), in the view ahead: for each live entry, in the
/// ring's order, the armed one's count and name, centred, and each one's shape for its place, the
/// shapes standing round the ring by their own offsets.
pub fn draw(shown: Shown, canvas: hud.windows.Canvas) hud.windows.Canvas.Error!void {
    for (shown.ring.entries) |entry| {
        const count = entry.left() orelse continue;
        if (entry.place == 0) {
            try canvas.print("{d}", .{count}, count_at, .centre);
            try canvas.string(@intCast(entry.name), name_at, .centre);
        }
        try canvas.shaky(@intCast(entry.shape + entry.place), ring_at);
    }
}

test "Ring.build" {
    var object = gameobj.testing.object();
    // Screamers on two racks, a fuel pod, a Havoc and a Raptor pod.
    object.rack_count = 5;
    const loadout = [_]struct { Type, i32 }{ .{ .of(.screamer), 20 }, .{ .of(.fuel_pod), 1 }, .{ .of(.havoc), 1 }, .{ .of(.screamer), 20 }, .{ .of(.raptor), 3 } };
    for (loadout, 0..) |rack, i| object.racks[i] = .{ .type = rack[0], .count = rack[1] };
    var ring: Ring = .{};
    ring.build(&object);
    // One entry a type, their missiles together, the fuel pod left out.
    try std.testing.expectEqual(40, ring.entries[0].count);
    try std.testing.expectEqual(Type.of(.havoc), ring.entries[1].type);
    try std.testing.expectEqual(3, ring.entries[2].count);
    try std.testing.expectEqual(-1, ring.entries[3].count);
    try std.testing.expectEqual(44, ring.left);
    // The middle armed at six o'clock, the one before it next round, the one after it last.
    try std.testing.expectEqual(1, ring.armed);
    try std.testing.expectEqual(0, ring.armedEntry().place);
    try std.testing.expectEqual(1, ring.entries[0].place);
    try std.testing.expectEqual(9, ring.entries[2].place);
    try std.testing.expectEqual(0x24, ring.armedEntry().shape);
    try std.testing.expectEqual(0x121, ring.armedEntry().name);
}

test "Ring.turn" {
    var object = gameobj.testing.object();
    object.rack_count = 3;
    for ([_]Type{ .of(.screamer), .of(.havoc), .of(.raptor) }, 0..) |missile, i| object.racks[i] = .{ .type = missile, .count = 1 };
    var ring: Ring = .{};
    ring.build(&object);
    try std.testing.expectEqual(1, ring.armed);
    // Clockwise, the next entry comes round to six o'clock and is armed.
    try std.testing.expect(ring.turn(.clockwise));
    try std.testing.expectEqual(2, ring.armed);
    try std.testing.expectEqual(0, ring.entries[2].place);
    try std.testing.expectEqual(1, ring.entries[1].place);
    // Past the last entry it turns no further, and back past the first neither.
    try std.testing.expect(!ring.turn(.clockwise));
    try std.testing.expect(ring.turn(.anticlockwise));
    try std.testing.expect(ring.turn(.anticlockwise));
    try std.testing.expectEqual(0, ring.armed);
    try std.testing.expectEqual(8, ring.entries[2].place);
    try std.testing.expect(!ring.turn(.anticlockwise));
}
