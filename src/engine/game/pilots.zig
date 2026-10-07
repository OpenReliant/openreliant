//! `C:\lancer\game\pilots.cpp`: pilots. `stats_load_pilots` (`0x0049CAE0`) fills `pilot_stats` from
//! `pilotstats.bin`, [`formats/stats.zig`](../../formats/stats.zig), and `object_set_pilot`
//! (`0x0049CCE0`) gives an object its pilot, whose face the radio's window shows as it speaks
//! (`Face`). **Unverified:** the two lie between `particles.cpp`'s code and this file's.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const stats = @import("../../formats/stats.zig");
const additions = @import("additions.zig");
const Pointer = @import("../../engine.zig").Pointer;
const gameobj = @import("gameobj.zig");
const GameObject = gameobj.GameObject;

const log = std.log.scoped(.pilots);

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
    /// (`radio.menu`).
    _unknown_1e: u16,
    /// The record's `_unknown_58`. The radio checks it without any effect (`radio.wingmen`).
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
        .timings = @as(*const Timings, @ptrCast(&stats.tier_a_default)).*,
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
        if (record.tier_a.index()) |level| pilot.timings = @as(*const Timings, @ptrCast(&stats.tier_a_presets[level])).*;
        if (record.tier_c.index()) |level| {
            const preset = stats.tier_c_presets[level];
            pilot.turn_limit = preset[0];
            pilot.turn_ease = preset[1];
            pilot.aim_interval = @bitCast(preset[2]);
            if (record.tier_c == .level_2) pilot.timings.countermeasures = @as(*const Range, @ptrCast(&stats.tier_c_level_2_override)).*;
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
    pilots: [max_pilots]Pilot = @splat(.default),

    /// The game's pilots.
    pub const count = 194;

    /// The pilots the table holds: the game's, then the pilots mods add (`additions.pilots`).
    pub const max_pilots = additions.pilots.end;

    /// Each record of `records` in turn, the game's pilots' and then the mods'.
    pub fn load(table: *Table, records: []align(1) const stats.Pilot) void {
        const loaded = @min(records.len, max_pilots);
        for (table.pilots[0..loaded], records[0..loaded]) |*pilot, record| pilot.* = .of(record);
    }

    /// The pilot numbered `pilot`, or the defaults for a number past the table.
    pub fn get(table: *const Table, pilot: i32) *const Pilot {
        if (pilot < 0 or pilot >= max_pilots) return &Pilot.default;
        return &table.pilots[@intCast(pilot)];
    }
};

test {
    std.testing.refAllDecls(@This());
}

test Table {
    var record: stats.Pilot = std.mem.zeroes(stats.Pilot);
    record.tier_a = .level_0;
    record.tier_b = @fromBackingInt(9);
    record.tier_c = .level_2;
    record.skill = @fromBackingInt(10);
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
    try std.testing.expectEqual(@as(Pilot.Skill, @fromBackingInt(10)), pilot.skill);
    // The rest keep the defaults.
    try std.testing.expectEqual(Pilot.default, table.get(1).*);
    try std.testing.expectEqual(Pilot.Skill.medium, table.get(Table.count).skill);
}

/// The game's pilots, by their numbers in `pilotstats.bin` and in the faces' table (`faces`). The
/// names are OpenReliant's, for the pilots the game's code singles out: the player's wing and its
/// stretches (`new_wing`, `stretches`), the first replacements of its pool (`pool`), Moose, who makes
/// the squadron's remarks (`radio.moose`), and the Ronin wing, which flies with the StarLancer
/// trial's player.
pub const GamePilot = enum(u8) {
    /// Bandit and Diceman, the 45th Tigers' wing leaders (`45TigersWL_*`).
    bandit_tigers_leader = 0,
    diceman_tigers_leader = 1,
    /// Moose, of the 45th Tigers and of the 45th Volunteers.
    moose_tigers = 2,
    moose_volunteers = 4,
    /// Bandit and Viper, the 45th Volunteers' wing leaders (`45VolntrWL_*`).
    bandit_volunteers_leader = 6,
    viper = 7,
    /// The Ronin wing's leader, Tanaka in the trial, and its pilots (`RoninWL_Plt`, `Ronin_Plt`).
    ronin_leader = 62,
    ronin = 63,
    /// The new wing's pilots, Hawkeye and Diceman of the stretches, and the pool's first
    /// replacements, Ego, Mayday and Trigger.
    frenchy = 85,
    silky = 86,
    mayday = 87,
    trigger = 88,
    hawkeye = 95,
    worm = 108,
    ego = 119,
    diceman = 120,
    bandit = 172,
    _,

    /// Its number, as the wing keeps it (`Wing`).
    pub fn number(pilot: GamePilot) i16 {
        return @backingInt(pilot);
    }
};

/// A pilot by its number, as scripts know it: none, one of the game's pilots by its name
/// (`GamePilot`) or its number, and a pilot a mod adds by its qualified name.
pub const Number = enum(u8) {
    /// The name scripts know these values by, and the names they know.
    pub const script_name = "PilotNumber";
    pub const Named = GamePilot;

    /// No pilot of the table: a mission's ship record's `dte.Ship.no_pilot`.
    none = 0xFF,
    _,

    /// The pilot an object flown by `pilot` (`GameObject.pilot`) has.
    pub fn of(pilot: i32) Number {
        return if (std.math.cast(u8, pilot)) |number| @fromBackingInt(number) else .none;
    }

    /// The game's pilot `pilot`.
    pub fn named(pilot: GamePilot) Number {
        return @fromBackingInt(@backingInt(pilot));
    }

    /// The name scripts know it by: `none`, one of the game's pilots' names, or a pilot a mod adds
    /// by its qualified name.
    pub fn scriptName(pilot: Number) ?[]const u8 {
        if (pilot == .none) return "none";
        if (additions.pilots.get(@backingInt(pilot))) |added| return added.name;
        return std.enums.tagName(GamePilot, @fromBackingInt(@backingInt(pilot)));
    }

    /// The pilot scripts name `text`, if there is one.
    pub fn fromScriptName(text: []const u8) ?Number {
        if (std.mem.eql(u8, text, "none")) return .none;
        if (std.meta.stringToEnum(GamePilot, text)) |pilot| return .named(pilot);
        return @fromBackingInt(@intCast(additions.pilots.find(text) orelse return null));
    }
};

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
    /// The voice the pilot speaks in flying a hostile ship (`+0x06`, `radio.shipLine`).
    voice: Voice = .rus,
    /// The voice the pilot speaks in flying a friendly ship, by the pilot's number (`0x004538E0`);
    /// none for a pilot the game gives none, whose lines are then left out.
    allied_voice: ?AlliedVoice = null,
    /// Whether the pilot answers the wingmen's commands from the fuller set of replies
    /// (`0x004539A0`, whose table at `0x004539D0` marks Bandit, Diceman, Viper, Enriquez and
    /// Hawkeye).
    full_replies: bool = false,
    /// OpenReliant's: the voice a mod's pilot speaks in on any side, the start of its lines' names,
    /// in place of `voice` and `allied_voice` (`radio.shipLine`).
    own_voice: ?[]const u8 = null,

    pub const heads = 4;

    /// Its film for `head`, or null for a head past the four, which the game reads beside them,
    /// and for an empty name, which a record can give (`FaceRecord`).
    pub fn film(face: *const Face, head: Head) ?[]const u8 {
        const index = @backingInt(head);
        if (index >= heads or face.films[index].len == 0) return null;
        return face.films[index];
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

/// The longest name a face's film can have. The radio writes the film's path,
/// `pilots\<film>.fm8`, and a terminating zero into 128 bytes (`radio.film_path_size`).
pub const max_film = 116;

/// A pilot's face as the records hold it (`openreliant.records.faces`), where scripts can change
/// it: the string that names the pilot, and the name of the film its face plays for each way it
/// moves (`Head`). An empty name plays the dead channel's film.
pub const FaceRecord = struct {
    name: u16,
    talking: Film = @splat(0),
    laughing: Film = @splat(0),
    squadron: Film = @splat(0),
    dying: Film = @splat(0),

    /// The name scripts know these records by.
    pub const script_name = "Face";

    /// A film's name and the zero after it.
    pub const Film = [max_film + 1]u8;

    /// The record of `face`.
    pub fn of(face: *const Face) FaceRecord {
        var record: FaceRecord = .{ .name = face.name };
        inline for (comptime std.enums.values(Head)) |head| {
            @field(record, @tagName(head)) = filmOf(face.films[@backingInt(head)]);
        }
        return record;
    }

    /// The film `name` as a record holds it. A name too long for the radio's path is left empty:
    /// the dead channel's film plays, as it does when the radio has no room for the path.
    pub fn filmOf(name: []const u8) Film {
        var film: Film = @splat(0);
        if (name.len <= max_film) @memcpy(film[0..name.len], name);
        return film;
    }

    comptime {
        // A film for each way the face moves.
        for (std.enums.values(Head)) |head| assert(@FieldType(FaceRecord, @tagName(head)) == Film);
    }
};

/// The records of every pilot's face (`FaceRecord`): the game's pilots', then those of the pilots
/// mods add (`additions.pilots`).
pub fn faceRecords(gpa: Allocator) Allocator.Error![]FaceRecord {
    const added = additions.pilots.all();
    const records = try gpa.alloc(FaceRecord, faces.len + added.len);
    for (records[0..faces.len], &faces) |*record, *face| record.* = .of(face);
    for (records[faces.len..], added) |*record, *each| record.* = .of(&each.extra.face);
    return records;
}

/// `pilot_faces` (`0x005048D8`): every pilot's face, by the pilot's number. The game's table is
/// fixed; OpenReliant loads it from the records (`load`), so that scripts can change the faces.
pub const Faces = struct {
    faces: [Table.max_pilots]Face = initial,
    /// How many pilots have a face. A pilot past them has none.
    count: usize = faces.len,

    /// The game's faces, then blank ones for the pilots mods add.
    const initial = faces ++ @as([Table.max_pilots - faces.len]Face, @splat(blank));
    const blank: Face = .{ .name = 0, .side = .friendly, .films = @splat("") };

    /// A face for each record of `records` in turn, the game's pilots' and then the mods'. Each
    /// keeps the side and the voices that the game or the pilot's mod gives it, and takes its name
    /// and films from the record. The films' names are read in place, so the records must
    /// outlive the table.
    pub fn load(table: *Faces, records: []const FaceRecord) void {
        const loaded = @min(records.len, Table.max_pilots);
        for (table.faces[0..loaded], records[0..loaded], 0..) |*face, *record, pilot| {
            face.* = given(pilot);
            face.name = record.name;
            inline for (comptime std.enums.values(Head)) |head| {
                face.films[@backingInt(head)] = std.mem.sliceTo(&@field(record, @tagName(head)), 0);
            }
        }
        table.count = @max(table.count, loaded);
    }

    /// The face that the game or the mod that adds pilot `pilot` gives it.
    fn given(pilot: usize) Face {
        if (pilot < faces.len) return faces[pilot];
        const added = additions.pilots.get(@intCast(pilot)) orelse return blank;
        return added.extra.face;
    }

    /// The face of pilot `pilot`, or null for a number past the table, which the game reads
    /// beside it.
    pub fn of(table: *const Faces, pilot: i32) ?*const Face {
        const index = std.math.cast(usize, pilot) orelse return null;
        return if (index < table.count) &table.faces[index] else null;
    }

    /// The string that names pilot `pilot` (`Face.name`), as the radio's window and the target
    /// display show it; null for a number past the table.
    pub fn nameOf(table: *const Faces, pilot: i32) ?u16 {
        const face = table.of(pilot) orelse return null;
        return face.name;
    }
};

/// A pilot of the pool that replaces the wingmen who die (`pilot_pool`, `0x005047D0`): a pilot, by
/// the pilot stats' number, and whether the pilot is free, in the wing or dead, as `update_pilots`
/// and `explode_ship_init` mark it.
pub const Replacement = extern struct {
    pilot: i16,
    status: Status,
    _unused: u8 = 0,

    pub const Status = enum(u8) {
        dead = 0,
        in_wing = 1,
        free = 2,
        _,
    };

    comptime {
        assert(@sizeOf(Replacement) == 4);
    }
};

/// The pool's records: 65 (`update_pilots` gives up past the last, `0x0049CE10`).
pub const pool_size = 65;
pub const Pool = [pool_size]Replacement;

/// The pool as the game starts, every pilot free ([`pilots/pool.zig`](pilots/pool.zig), generated
/// from the payload).
pub const starting_pool: Pool = @import("pilots/pool.zig").pool;

/// The pilots of the player's wing, Alpha 1 to 6 (`alpha_pilots`, `0x0058A958`), by the pilot
/// stats' number: -1 for the player, and for a wingman whose pilot has died, then the five
/// wingmen's.
pub const Wing = [6]i16;

/// The wing `campaign_pilots_reset` (`0x0049CD20`) starts a campaign with: Frenchy, Worm, Silky,
/// Bandit and Viper behind the player.
pub const new_wing: Wing = .{ -1, GamePilot.frenchy.number(), GamePilot.worm.number(), GamePilot.silky.number(), GamePilot.bandit.number(), GamePilot.viper.number() };

/// The wingmen's places, Alpha 2 to 6.
pub const wingman_places = new_wing.len - 1;

/// The pilots `update_pilots` gives Alpha 5 and Alpha 6 for each stretch of the campaign, by the
/// last mission of the stretch (`0x0049CD7B` on): Bandit and Viper to mission 5, Diceman and the
/// 45th Volunteers' Bandit to mission 13, Diceman and the 45th Tigers' Bandit to mission 22, and
/// Hawkeye and the 45th Tigers' Diceman to mission 28. A mission past them leaves them as they are.
const stretches = [_]struct { last: u16, pilots: [2]GamePilot }{
    .{ .last = 5, .pilots = .{ .bandit, .viper } },
    .{ .last = 13, .pilots = .{ .diceman, .bandit_volunteers_leader } },
    .{ .last = 22, .pilots = .{ .diceman, .bandit_tigers_leader } },
    .{ .last = 28, .pilots = .{ .hawkeye, .diceman_tigers_leader } },
};

/// The places of the wing `update_pilots` fills from `stretches`: Alpha 5 and Alpha 6.
const story_places = 4;

/// The pilots of the player's wing and the pool of their replacements, which the game keeps in
/// `pilots.cpp`'s globals across a session, and a saved game in part (`save.Save`'s `ALPH` and
/// `PILO`).
///
/// The game starts with the wing zeroed, which no mission sees, since the campaign's start and the
/// way into SINGLE PLAYER reset it (`reset`). OpenReliant starts with a new campaign's, which only
/// `--mission` flies outside a campaign.
pub const Wingmen = struct {
    alpha: Wing = new_wing,
    pool: Pool = starting_pool,

    /// `campaign_pilots_reset` (`0x0049CD20`): every pilot of the pool free, and the wing a new
    /// campaign's.
    pub fn reset(wingmen: *Wingmen) void {
        for (&wingmen.pool) |*replacement| replacement.status = .free;
        wingmen.alpha = new_wing;
    }

    /// `update_pilots` (`0x0049CD70`) for mission `number`, as the campaign moves on to it and as it
    /// starts (`gameflow.endMission`, `main.startMission`): Alpha 5 and Alpha 6 take the
    /// stretch's pilots (`stretches`), then each wingman whose pilot has died takes the first free
    /// pilot of the pool, which is then in the wing.
    ///
    /// **Fix:** with no pilot free, the game stops with "Uh Oh, update_pilots has run out of
    /// pilots"; OpenReliant logs it and leaves the place empty.
    pub fn update(wingmen: *Wingmen, number: u16) void {
        if (number > 0) for (stretches) |stretch| {
            if (number > stretch.last) continue;
            wingmen.alpha[story_places..].* = .{ stretch.pilots[0].number(), stretch.pilots[1].number() };
            break;
        };
        for (wingmen.alpha[1..]) |*pilot| {
            if (pilot.* != -1) continue;
            const replacement = for (&wingmen.pool) |*held| {
                if (held.status == .free) break held;
            } else {
                log.warn("Uh Oh, update_pilots has run out of pilots", .{});
                continue;
            };
            replacement.status = .in_wing;
            pilot.* = replacement.pilot;
        }
    }

    /// What `explode_ship_init` (`0x004088D5` on) does as a ship flown by `pilot` is destroyed:
    /// where the pilot flies in the wing, the place is empty for the next mission to fill, and the
    /// pilot dead in the pool.
    pub fn lose(wingmen: *Wingmen, pilot: i32) void {
        const place = for (wingmen.alpha[1..]) |*held| {
            if (held.* == pilot) break held;
        } else return;
        place.* = -1;
        for (&wingmen.pool) |*replacement| {
            if (replacement.pilot != pilot) continue;
            replacement.status = .dead;
            return;
        }
    }

    /// The wingmen's pilots, Alpha 2 to 6.
    pub fn pilots(wingmen: *const Wingmen) *const [wingman_places]i16 {
        return wingmen.alpha[1..];
    }

    /// Seats the pilots `wing` lists in the wingmen's places, from Alpha 2, as a game mode names
    /// its wingmen; `none` leaves a place as it is.
    ///
    /// **Improvement:** the original's wing is the campaign's alone.
    pub fn seat(wingmen: *Wingmen, wing: []const Number) void {
        const seated = @min(wing.len, wingman_places);
        for (wingmen.alpha[1..][0..seated], wing[0..seated]) |*place, pilot| {
            if (pilot != .none) place.* = @backingInt(pilot);
        }
    }
};

test Wingmen {
    var wingmen: Wingmen = .{};
    try std.testing.expectEqual(starting_pool[0].pilot, wingmen.pool[0].pilot);
    // Mission 6 brings Diceman and Bandit in as Alpha 5 and 6, and the wing's first replacement
    // takes the place of the wingman who died.
    wingmen.lose(0x55);
    try std.testing.expectEqual(-1, wingmen.alpha[1]);
    wingmen.update(6);
    try std.testing.expectEqual(Wing{ -1, starting_pool[0].pilot, 0x6C, 0x56, 0x78, 6 }, wingmen.alpha);
    try std.testing.expectEqual(Replacement.Status.in_wing, wingmen.pool[0].status);
    // A replacement who dies is dead in the pool too, and the next takes the place.
    wingmen.lose(starting_pool[0].pilot);
    try std.testing.expectEqual(Replacement.Status.dead, wingmen.pool[0].status);
    wingmen.update(14);
    try std.testing.expectEqual(starting_pool[1].pilot, wingmen.alpha[1]);
    try std.testing.expectEqual(@as(i16, 0), wingmen.alpha[5]);
    // A pilot outside the wing changes nothing; past the campaign's missions, Alpha 5 and 6 stay.
    wingmen.lose(66);
    wingmen.update(29);
    try std.testing.expectEqual(@as(i16, 0x78), wingmen.alpha[4]);
    // A new campaign frees every pilot, and starts the wing again.
    wingmen.reset();
    try std.testing.expectEqual(new_wing, wingmen.alpha);
    try std.testing.expectEqual(Replacement.Status.free, wingmen.pool[0].status);
    // With nobody free, the place stays empty.
    for (&wingmen.pool) |*replacement| replacement.status = .dead;
    wingmen.alpha[2] = -1;
    wingmen.update(1);
    try std.testing.expectEqual(-1, wingmen.alpha[2]);
}

test "Wingmen.seat" {
    var wingmen: Wingmen = .{};
    // Alpha 6 is Tanaka, and Alpha 2 keeps its pilot, Frenchy.
    wingmen.seat(&.{ .none, .named(.worm), .named(.silky), .named(.bandit), .named(.ronin_leader) });
    try std.testing.expectEqual(GamePilot.frenchy.number(), wingmen.alpha[1]);
    try std.testing.expectEqual(GamePilot.ronin_leader.number(), wingmen.alpha[5]);
    // A shorter list seats the places it reaches.
    wingmen.seat(&.{.named(.viper)});
    try std.testing.expectEqual(GamePilot.viper.number(), wingmen.alpha[1]);
}

test Faces {
    var table: Faces = .{};
    // Bandit and Diceman, the 45th Tigers' wing leaders, and SABERS, the hostile ships' default.
    try std.testing.expectEqual(33, table.nameOf(0).?);
    try std.testing.expectEqual(37, table.nameOf(1).?);
    try std.testing.expectEqual(81, table.nameOf(66).?);
    try std.testing.expectEqual(null, table.nameOf(-1));
    // The first pilot of the table is Bandit, with a film for each way the face moves; a pilot
    // past the table has none.
    const bandit = table.of(0).?;
    try std.testing.expectEqual(.friendly, bandit.side);
    try std.testing.expectEqualStrings("45TigersWL_Bandit_L", bandit.film(.laughing).?);
    try std.testing.expectEqual(null, bandit.film(@fromBackingInt(4)));
    try std.testing.expectEqual(null, table.of(Table.count));

    // The records give the faces their names and films, and a mod's pilot its mod's face.
    var face = faces[21];
    face.films[@backingInt(Head.talking)] = "trooper";
    face.own_voice = "trp";
    var list = [_]additions.pilots.Added{.{ .name = "a:trooper", .mod = "a", .base = 21, .extra = .{ .face = face } }};
    additions.pilots.install(&list);
    defer additions.pilots.reset();
    const records = try faceRecords(std.testing.allocator);
    defer std.testing.allocator.free(records);
    try std.testing.expectEqual(Table.count + 1, records.len);
    records[4] = .{ .name = 1104, .talking = FaceRecord.filmOf("Ronin_Plt"), .dying = FaceRecord.filmOf("Ronin_Plt_D") };
    table.load(records);
    const copilot = table.of(4).?;
    try std.testing.expectEqual(1104, copilot.name);
    try std.testing.expectEqualStrings("Ronin_Plt", copilot.film(.talking).?);
    try std.testing.expectEqual(null, copilot.film(.laughing));
    try std.testing.expectEqual(faces[4].voice, copilot.voice);
    const trooper = table.of(additions.pilots.first).?;
    try std.testing.expectEqualStrings("trooper", trooper.film(.talking).?);
    try std.testing.expectEqualStrings("trp", trooper.own_voice.?);
    try std.testing.expectEqual(null, table.of(additions.pilots.first + 1));
}

test FaceRecord {
    // A film too long for the radio's path is left empty.
    var face = faces[0];
    const long: [max_film + 1]u8 = @splat('x');
    face.films[@backingInt(Head.dying)] = &long;
    const record: FaceRecord = .of(&face);
    try std.testing.expectEqualStrings("45TigersWL_Bandit", std.mem.sliceTo(&record.talking, 0));
    try std.testing.expectEqual(0, record.dying[0]);
}
