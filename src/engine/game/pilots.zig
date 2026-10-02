//! `C:\lancer\game\pilots.cpp`: pilots. `stats_load_pilots` (`0x0049CAE0`) fills `pilot_stats` from
//! `pilotstats.bin`, [`formats/stats.zig`](../../formats/stats.zig), and `object_set_pilot`
//! (`0x0049CCE0`) gives an object its pilot, whose face the radio's window shows as it speaks
//! (`Face`). **Unverified:** the two lie between `particles.cpp`'s code and this file's.

const std = @import("std");
const assert = std.debug.assert;

const stats = @import("../../formats/stats.zig");
const Pointer = @import("../../engine.zig").Pointer;
const gameobj = @import("gameobj.zig");
const GameObject = gameobj.GameObject;

/// One pilot of `pilot_stats`. The loader fills every slot with defaults, then applies the
/// records: each tier field sets a group of these, in `formats/stats.zig`'s preset tables. The
/// Fight order ([`aifight.zig`](aifight.zig)) and its maneuvers read them.
pub const Pilot = extern struct {
    /// How hard it turns: the most of each turning input it steers with (`Pilot.tier_c`'s first
    /// float, `ai.steer`'s `limit`), which also scales the turns a maneuver sets.
    turn_limit: f32,
    /// How far it lets a turn swing (`tier_c`'s second float, `ai.steer`'s `ease`).
    turn_ease: f32,
    /// The ticks between its aims at its target (`tier_c`'s 16-bit value), which also sets how far
    /// ahead it reckons the target's turn.
    aim_interval: i16,
    _unknown_0a: u16,
    /// How far off the line along its nose the aim point may be for it to fire, in the target's
    /// radii (`Pilot.tier_b`).
    fire_spread: f32,
    /// How it times its guns, missiles and countermeasures (`Pilot.tier_a`).
    timings: Timings,
    /// The record's `_unknown_54`, copied through.
    _unknown_1c: u16,
    /// The record's `_unknown_50`. The pilot answers What's your status? only if it's above 0
    /// (`videoreports.menu`).
    _unknown_1e: u16,
    /// The record's `_unknown_58`. The radio checks it without any effect (`videoreports.wingmen`).
    _unknown_20: u16,
    /// The pilot's skill, which the maneuvers use: how far away it starts pursuing, how much
    /// distance it keeps from what it might hit, and whether it uses the afterburner when
    /// attacking. **Unknown:** the original name for it.
    skill: Skill,

    /// A pilot's skill, as stored in its record.
    pub const Skill = stats.Pilot.Skill;

    /// What the loader fills every slot with before it reads the records.
    pub const default: Pilot = .{
        .turn_limit = stats.tier_c_default[0],
        .turn_ease = stats.tier_c_default[1],
        .aim_interval = @bitCast(stats.tier_c_default[2]),
        ._unknown_0a = 0,
        .fire_spread = stats.tier_b_default,
        .timings = @bitCast(stats.tier_a_default),
        ._unknown_1c = 1,
        ._unknown_1e = 1,
        ._unknown_20 = 1,
        .skill = .medium,
    };

    /// The six values `Pilot.tier_a` sets, in ticks, which the game reads as signed words.
    pub const Timings = extern struct {
        /// How long it holds the trigger once it has its aim.
        burst: i16,
        /// How long after it last had the chance to fire it looks again.
        pause: i16,
        /// The range the wait for its next missile falls in.
        missiles: Range,
        /// The range the wait for its next countermeasure falls in. Level 2 of `tier_c` sets
        /// these.
        countermeasures: Range,
    };

    pub const Range = extern struct {
        least: i16,
        most: i16,
    };

    /// The pilot a record makes, starting from the defaults: each tier field selects a preset if it
    /// names one, and the four words after them are copied. Level 2 of `tier_c` also overrides
    /// `tier_a`'s countermeasure timings.
    fn of(record: stats.Pilot) Pilot {
        var pilot: Pilot = .default;
        pilot._unknown_1c = record._unknown_54;
        pilot._unknown_1e = record._unknown_50;
        pilot._unknown_20 = record._unknown_58;
        pilot.skill = record.skill;
        if (record.tier_b.index()) |level| pilot.fire_spread = stats.tier_b_presets[level];
        if (record.tier_a.index()) |level| pilot.timings = @bitCast(stats.tier_a_presets[level]);
        if (record.tier_c.index()) |level| {
            const preset = stats.tier_c_presets[level];
            pilot.turn_limit = preset[0];
            pilot.turn_ease = preset[1];
            pilot.aim_interval = @bitCast(preset[2]);
            if (record.tier_c == .level_2) pilot.timings.countermeasures = @bitCast(stats.tier_c_level_2_override);
        }
        return pilot;
    }

    comptime {
        assert(@offsetOf(Pilot, "aim_interval") == 0x08);
        assert(@offsetOf(Pilot, "fire_spread") == 0x0C);
        assert(@offsetOf(Pilot, "timings") == 0x10);
        assert(@sizeOf(Timings) == @sizeOf(@TypeOf(stats.tier_a_default)));
        assert(@offsetOf(Pilot, "_unknown_1c") == 0x1C);
        assert(@offsetOf(Pilot, "skill") == 0x22);
        assert(@sizeOf(Pilot) == 0x24);
    }
};

/// `pilot_stats` (`0x0058A968`): every pilot, which `stats_load_pilots` (`0x0049CAE0`) fills:
/// the defaults in every slot, then `pilotstats.bin`'s records in order.
pub const Table = struct {
    pilots: [count]Pilot = @splat(.default),

    pub const count = 194;

    pub fn load(table: *Table, records: []align(1) const stats.Pilot) void {
        const loaded = @min(records.len, count);
        for (table.pilots[0..loaded], records[0..loaded]) |*pilot, record| pilot.* = .of(record);
    }

    /// The pilot numbered `pilot`, or the defaults for a number past the table.
    pub fn get(table: *const Table, pilot: i32) *const Pilot {
        if (pilot < 0 or pilot >= count) return &Pilot.default;
        return &table.pilots[@intCast(pilot)];
    }
};

test {
    std.testing.refAllDecls(@This());
}

test Table {
    var record: stats.Pilot = std.mem.zeroes(stats.Pilot);
    record.tier_a = .level_0;
    record.tier_b = @enumFromInt(9);
    record.tier_c = .level_2;
    record.skill = @enumFromInt(10);
    record._unknown_50 = 11;
    record._unknown_54 = 12;
    record._unknown_58 = 13;
    record._unread_4e = 0xFFFF;
    var table: Table = .{};
    table.load(&.{record});

    // Each named tier selects its preset, tier C's level 2 overrides the last two values of tier A,
    // tier B keeps its default, and the four words are copied.
    const pilot = table.get(0);
    try std.testing.expectEqual(Pilot.Timings{
        .burst = 10,
        .pause = 40,
        .missiles = .{ .least = 800, .most = 1600 },
        .countermeasures = .{ .least = 50, .most = 100 },
    }, pilot.timings);
    try std.testing.expectEqual(stats.tier_b_default, pilot.fire_spread);
    try std.testing.expectEqual(25, pilot.aim_interval);
    try std.testing.expectEqual(1, pilot.turn_limit);
    try std.testing.expectEqual([3]u16{ 12, 11, 13 }, [3]u16{ pilot._unknown_1c, pilot._unknown_1e, pilot._unknown_20 });
    try std.testing.expectEqual(@as(Pilot.Skill, @enumFromInt(10)), pilot.skill);
    // The rest keep the defaults.
    try std.testing.expectEqual(Pilot.default, table.get(1).*);
    try std.testing.expectEqual(Pilot.Skill.medium, table.get(Table.count).skill);
}

/// `object_set_pilot` (`0x0049CCE0`): gives the object pilot `pilot`, a record of `pilot_stats`.
/// The game points the object at the record and at the pilot's face as well
/// (`GameObject.pilot_stats`, `pilot_record`); OpenReliant looks both up by number (`faceOf`).
pub fn setPilot(object: *GameObject, pilot: i32) void {
    object.pilot = pilot;
}

/// How a pilot's face moves as it says a line, which of its face's films plays (`radio_say_pilot`,
/// `radio_say_ship`).
pub const Head = enum(u32) {
    talking = 0,
    laughing = 1,
    /// The 45th's own pilot, the film every pilot has in this place.
    squadron = 2,
    dying = 3,
    _,
};

/// A pilot's face (`pilot_faces`, `0x005048D8`): the string that names the pilot, which the radio's
/// window shows over its face, its side, and a film of its face for each way it moves (`Head`),
/// each the member `pilots\<film>.fm8` of `pilots.hog`
/// ([face films](../../../docs/formats/fm8.md)).
pub const Face = struct {
    name: u16,
    side: gameobj.Side(u16),
    films: [heads][]const u8,
    /// The voice the pilot speaks in flying a hostile ship (`+0x06`, `videoreports.shipLine`).
    voice: Voice = .rus,
    /// The voice the pilot speaks in flying a friendly ship, by the pilot's number (`0x004538E0`);
    /// none for a pilot the game gives none, whose lines are then left out.
    allied_voice: ?AlliedVoice = null,
    /// Whether the pilot answers the wingmen's commands from the fuller set of replies
    /// (`0x004539A0`, whose table at `0x004539D0` marks Bandit, Diceman, Viper, Enriquez and
    /// Hawkeye).
    full_replies: bool = false,

    pub const heads = 4;

    /// Its film for `head`, or null for a head past the four, which the game reads beside them.
    pub fn film(face: *const Face, head: Head) ?[]const u8 {
        const index = @intFromEnum(head);
        return if (index < heads) face.films[index] else null;
    }

    /// The record as the payload lays it out, 24 bytes. **Unknown:** the halfword at `+0x02`, 0x53
    /// in every record.
    pub const Record = extern struct {
        name: u16,
        _unknown_02: u16,
        side: gameobj.Side(u16),
        voice: Voice,
        films: [heads]Pointer(u8),

        comptime {
            assert(@offsetOf(Record, "side") == 0x04);
            assert(@offsetOf(Record, "films") == 0x08);
            assert(@sizeOf(Record) == 0x18);
        }
    };
};

/// The voice a pilot speaks in flying a hostile ship (`ship_line`, `0x00453710`): the start of the
/// name of each of its lines. Every pilot of the game's table is `rus` but a few, of 0 or 4, which
/// is none of these; their lines are left out.
pub const Voice = enum(u16) {
    rus = 5,
    chn = 6,
    arb = 7,
    _,

    /// The start of the names of the pilot's lines, where the voice is one of the game's.
    pub fn prefix(voice: Voice) ?[]const u8 {
        return switch (voice) {
            _ => null,
            inline else => |named| @tagName(named),
        };
    }

    pub fn format(voice: Voice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.writeAll(voice.prefix() orelse "none");
    }
};

/// The voice a pilot speaks in flying a friendly ship (`ship_line`'s cases, `0x00453884`): the
/// start of the name of each of its lines, one for each of the pilots of the player's side who
/// speak.
pub const AlliedVoice = enum(u8) {
    ban,
    dic,
    fre,
    vip,
    enq,
    sil,
    tak,
    jor,
    vix,
    cut,
    cla,
    ski,
    jui,
    fac,
    haw,
    arr,
    ner,
    rhi,
    sta,
    fla,
    wor,
    ego,
};

/// Every pilot's face, by the pilot's number, one for each pilot `Table` holds
/// ([`pilots/faces.zig`](pilots/faces.zig), generated from the payload).
pub const faces = @import("pilots/faces.zig").faces;

comptime {
    assert(faces.len == Table.count);
}

/// The face of pilot `pilot`, or null for a number past the table, which the game reads beside it.
pub fn faceOf(pilot: i32) ?*const Face {
    if (pilot < 0 or pilot >= faces.len) return null;
    return &faces[@intCast(pilot)];
}

/// The string that names pilot `pilot` (`Face.name`), as the radio's window and the target display
/// show it; null for a number past the table.
pub fn nameOf(pilot: i32) ?u16 {
    const face = faceOf(pilot) orelse return null;
    return face.name;
}

test nameOf {
    // Bandit and Diceman, the 45th Tigers' wing leaders, and SABERS, the hostile ships' default.
    try std.testing.expectEqual(33, nameOf(0).?);
    try std.testing.expectEqual(37, nameOf(1).?);
    try std.testing.expectEqual(81, nameOf(66).?);
    try std.testing.expectEqual(null, nameOf(-1));
}

test faceOf {
    // The first pilot of the table is the 45th Tigers' wing leader Bandit, with a film for each way
    // the face moves; a pilot past the table has none.
    const bandit = faceOf(0).?;
    try std.testing.expectEqual(.friendly, bandit.side);
    try std.testing.expectEqualStrings("45TigersWL_Bandit_L", bandit.film(.laughing).?);
    try std.testing.expectEqual(null, bandit.film(@enumFromInt(4)));
    try std.testing.expectEqual(null, faceOf(Table.count));
    try std.testing.expectEqual(null, faceOf(-1));
}
