//! The briefing, the front end's screen 7 (`interface_briefing`, `0x00437010`), which the rooms
//! run as the player goes through the briefing room's door (`rooms.Step.briefing`), before the
//! mission is flown:
//!
//! 1. The door, with AWAITING CLEARANCE across its foot, for the frame after which the briefing
//!    loads (`Stage.door`).
//! 2. The way into the briefing room, in movies over the screen, with the door's sound and the
//!    room's chatter (`Way`).
//! 3. Enriquez at the room's screen, which plays the mission's movie (`movies`), going round his
//!    animation (`Segment`). Escape, the pointer's right button, or the movie's end ends it.
//! 4. After the loadout, his last word, a line of `speech_hog` over an animation of its own, which
//!    ends at its last frame, or on Escape or the right button (`Stage.tag`).
//!
//! The briefing room is the Reliant's up to mission 18, and the Yamato's after it (`Room`). A pass
//! of the briefing (`Briefing.pass`) runs a pass of the loop of the stage it stands at, and the
//! drawing (`briefing_draw`, `0x0043E730`) moves Enriquez and the movie on (`Briefing.advance`).
//!
//! After the campaign's last mission, `WinMain` runs the screen for mission 29, the campaign's end
//! (`end_mission`): Enriquez speaks over the room, without a movie, until his speech ends, and no
//! loadout or last word follows.
//!
//! Not ported: the loadout between the briefing and the last word, with the movies to its hologram
//! and back (`rel_br2holo.bik` and `rel_holo2br.bik`, `br2hol.bik` and `hol2br.bik`) and the in-game
//! options it opens, which can lead to the main menu, or back to the rooms where a saved game
//! loads (`0x0051D4B4`; [#44](https://github.com/vdmkenny/openreliant/issues/44)); and the
//! screenshot the O key saves (`screenshot_save`, `0x004ADC20`;
//! [#395](https://github.com/vdmkenny/openreliant/issues/395)).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const hog = @import("../../../formats/hog.zig");
const input = @import("../../input.zig");
const cbox = @import("../cbox.zig");
const hog_snd = @import("../hog_snd.zig");
const matmanager = @import("../matmanager.zig");
const videoreports = @import("../videoreports.zig");
const canvas = @import("canvas.zig");
const rooms = @import("rooms.zig");

const log = std.log.scoped(.briefing);

/// The mission after the campaign's last, 28, for which `WinMain` runs the briefing as the
/// campaign's end (`0x004373FA`): Enriquez's speech `end_debriefing` in place of the mission's
/// movie, and without the loadout or the last word.
pub const end_mission = 29;

/// Enriquez's speech at the campaign's end, of `speech_hog` (`0x004E89A8`).
pub const end_debriefing = "enddebriefing.ut";

/// The mission's movie, by its number from 1, which the room's screen plays, each `%s.bik`
/// (`0x004E89A0`) of the table the briefing builds (`0x00437016` on). Missions 12, 13, 17 and 22,
/// which the campaign has none of, take mission 1's.
pub const movies = [_][]const u8{ "new_m01", "new_m02", "new_m03", "new_m04", "new_m05", "new_m06", "new_m07", "new_m08", "new_m09", "new_m10", "new_m11", "new_m01", "new_m01", "new_m14", "new_m15", "new_m16", "new_m01", "new_m18", "new_m19", "new_m20", "new_m21", "new_m01", "new_m23", "new_m24", "new_m25", "new_m26", "new_m27", "new_m28" };

/// The movie of mission `mission` (`movies`), written into `buffer`; null for a mission the table
/// has none for.
///
/// **Fix:** past the table the game reads what lies beside it on the stack for the movie's name.
/// OpenReliant plays none there, and the briefing ends at once.
pub fn movieName(buffer: *[movie_name_size]u8, mission: u16) ?[]const u8 {
    if (mission == 0 or mission > movies.len) return null;
    return std.fmt.bufPrint(buffer, "{s}.bik", .{movies[mission - 1]}) catch unreachable;
}

pub const movie_name_size = 16;

/// Enriquez's last word before mission `mission`, `ms_speech\enrbr_tag%02d.ut` of `speech_hog`
/// (`0x004E88C8`), written into `buffer`, which holds it for any mission's number.
fn tagLine(buffer: *[tag_line_size]u8, mission: u16) []const u8 {
    return std.fmt.bufPrint(buffer, "ms_speech\\enrbr_tag{d:0>2}.ut", .{mission}) catch unreachable;
}

const tag_line_size = 32;

/// The bank of `resource.hog` whose sound plays as the briefing loads (`0x004E8A18`), at 110,
/// once (`0x00437187`).
pub const wait_bank = "waitloop.fat";
const wait_volume = 0x6E;

/// The bank of the disc's archive the way in's sounds come from (`0x004E89F4`): its first, a
/// sliding door, and its third, the room's chatter (`0x00437356` on). Its second, another door,
/// the briefing leaves unplayed.
pub const sounds_bank = "vrsfx.fat";
const door_sound = 0;
const chatter_sound = 2;

/// The step the music fades by as the briefing loads (`music_fade_out`, `0x004372C7`), and the
/// voices by as the briefing starts (`sound_fade_all`, `0x004373BB`).
const music_fade_step = 15;
const voices_fade_step = 4;

/// The strings of AWAITING CLEARANCE, written `%s %s` (`0x004E8750`) into 80 bytes, centred in
/// white across the door's foot in the large font (`briefing_door_draw`, `0x00437D30`).
const awaiting = 0x292;
const clearance = 0x293;
const awaiting_size = 80;
const awaiting_at: [2]i32 = .{ 320, 440 };

/// The blocks of the briefing's sprite sets: the room, the palette every shape is drawn with,
/// which the briefing makes VFX's global palette (`palette_to_vfx`, `0x00437282`, `0x0043E771`),
/// and Enriquez's first frame (`0x0043E7E3`).
const room_shape = 0;
const palette_block = 1;
const first_frame = 2;

/// The briefing's sprite set `name` of `resource.hog`, drawn with the palette of its
/// `palette_block`; null where it is left out.
fn readShapes(context: rooms.Context, name: []const u8) ?canvas.Shapes {
    var shapes = canvas.Shapes.read(context.gpa, context.resources, name) orelse return null;
    shapes.usePalette(palette_block);
    return shapes;
}

/// The timer's ticks to Enriquez's first frame (`0x004373E8`), and between his frames, a
/// fifteenth of a second (`0x004DC6D4`): the drawing adds them to the timer's count, and the next
/// frame is due once the count passes the sum, truncated (`__ftol`).
const first_wait = 6;
const frame_ticks: f32 = 6.666;
const frame_wait: u32 = @intFromFloat(frame_ticks);

/// The last word: its line is said as the animation reaches frame 17, and the animation ends at
/// frame 60 (`0x00437C46`, `0x00437C4B`), which is never drawn.
const tag_speaks_at = 0x11;
const tag_last = 0x3C;

/// A segment of Enriquez's animation in the briefing: its first shape past `first_frame`, and its
/// last frame, which it plays up to before the next segment's first.
pub const Segment = struct {
    start: u8,
    last: u8,
};

/// The segments his animation goes round, from the first.
pub const segment_count = 12;

/// The segments of `starts` and `lasts`, two of the executable's tables.
fn segments(starts: [segment_count]u8, lasts: [segment_count]u8) [segment_count]Segment {
    var out: [segment_count]Segment = undefined;
    for (&out, starts, lasts) |*segment, start, last| segment.* = .{ .start = start, .last = last };
    return out;
}

/// The way into the briefing room (`0x00437324` on): movies from the disc's archive over the
/// screen, the door's sound and the room's chatter starting before the last.
pub const Way = struct {
    /// The movie before the sounds, where there is one: the Yamato's, the screen by its door going
    /// dark.
    before: ?[]const u8,
    /// The quarter tones the door's sound plays up (`0x00437388`).
    door_pitch: i32,
    movie: []const u8,
};

/// The briefing room: the Reliant's up to mission 18, the Yamato's after it (`0x00437120`, as
/// `rooms.Carrier.of` decides).
pub const Room = struct {
    /// The door, which shows as the briefing loads: `%s.tga` (`0x0043EAF0`) of `0x004E8A28` and
    /// `0x004E8A38`.
    door: []const u8,
    way: Way,
    /// The sprite sets of `resource.hog`, the briefing's (`0x004E8A00`, `0x004E8A0C`) and the last
    /// word's (`0x004E88E4`, `0x004E88F0`): the room (`room_shape`), and Enriquez's frames from
    /// `first_frame`, the briefing's then the frame round the room's screen (`frame_shape`).
    shapes: []const u8,
    tag_shapes: []const u8,
    /// Where Enriquez's frames are drawn (`0x0043E7B9`, `0x0043E7DC`).
    enriquez_at: [2]i32,
    /// The segments of his animation in the briefing.
    segments: [segment_count]Segment,
    /// Where the room's screen shows the movie (`0x0043E9BE`, `0x0043E9D8`), and the frame round
    /// it, drawn over it (`0x0043EA60` on).
    screen_at: [2]i32,
    frame_shape: usize,
    frame_at: [2]i32,

    pub const reliant: Room = .{
        .door = "inter\\rbriefdor.tga",
        .way = .{ .before = null, .door_pitch = 1, .movie = "rel_c2bre.bik" },
        .shapes = "rbrief.spr",
        .tag_shapes = "rbrief2.spr",
        .enriquez_at = .{ 469, 116 },
        // `0x004E5C40`, `0x004E5C58`.
        .segments = segments(.{ 0, 99, 0, 0, 0, 0, 137, 0, 0, 61, 0, 0 }, .{ 60, 37, 60, 60, 60, 60, 42, 60, 60, 37, 60, 60 }),
        .screen_at = .{ 97, 29 },
        .frame_shape = 0xB6,
        .frame_at = .{ 89, 17 },
    };

    pub const yamato: Room = .{
        .door = "inter\\briefdoor.tga",
        .way = .{ .before = "amonoff_.bik", .door_pitch = hog_snd.own_pitch, .movie = "briefing room 350.bik" },
        .shapes = "brief.spr",
        .tag_shapes = "brief2.spr",
        .enriquez_at = .{ 1, 122 },
        // `0x004E5C10`, `0x004E5C28`.
        .segments = segments(.{ 0, 85, 0, 0, 0, 0, 123, 0, 0, 47, 0, 0 }, .{ 46, 37, 46, 46, 46, 46, 42, 46, 46, 37, 46, 46 }),
        .screen_at = .{ 200, 42 },
        .frame_shape = 0xA8,
        .frame_at = .{ 190, 28 },
    };

    pub fn of(carrier: rooms.Carrier) *const Room {
        return switch (carrier) {
            .reliant => &reliant,
            .yamato => &yamato,
        };
    }

    comptime {
        // Enriquez's frames lie between the room and the frame round the screen.
        for ([_]Room{ reliant, yamato }) |room| {
            for (room.segments) |segment| assert(first_frame + segment.start + segment.last < room.frame_shape);
        }
    }
};

/// Where the briefing stands.
pub const Stage = enum {
    /// The door shows: the next pass loads the briefing and sets off the way in.
    door,
    /// The Yamato's way in has begun (`Way.before`): the next pass plays its sounds and its last
    /// movie.
    door_open,
    /// The way in has played: the next pass starts the briefing.
    walked_in,
    /// Enriquez at the room's screen (`briefing_state` 1, `0x00520280`).
    briefing,
    /// His last word (`briefing_state` 2).
    tag,
};

/// What a pass reads.
pub const Input = struct {
    keyboard: *input.Keyboard,
    /// Whether the pointer's right button is down (`interface_pointer_right_down`).
    right: bool,
    /// The timer's count, a hundred a second (`game_ticks`), which Enriquez's frames step by.
    ticks: u32,
};

/// What a pass leads to, which the briefing's caller then runs.
pub const Step = union(enum) {
    /// A movie of the way in, from the disc's archive over the screen
    /// (`play_bink_movie_no_clear_resourced`, `movie.Kind.over_screen_from_disc`), after which the
    /// briefing goes on.
    movie: []const u8,
    /// The briefing over, and the mission to be flown (`interface_briefing` returns -1, with
    /// `0x0051D4B4` clear).
    over,
};

/// The briefing, as `interface_briefing` runs it.
pub const Briefing = struct {
    context: rooms.Context,
    /// The mission it comes before (`mission_number`), and its briefing room.
    mission: u16,
    room: *const Room,
    /// Whether it starts from the loadout, the way in and the briefing left out (`0x0051DB48`), as
    /// the developers' Enter with Control has it.
    from_loadout: bool,
    stage: Stage = .door,
    /// The door (`background_set`).
    door: matmanager.Background = .{},
    /// `wait_bank`, and the way in's `sounds_bank`.
    wait: ?hog_snd.BankFile = null,
    sounds: ?hog_snd.BankFile = null,
    /// The sprite set of the briefing, then of the last word (`0x00520254`).
    shapes: ?canvas.Shapes = null,
    /// Enriquez's frame (`0x0051DA94`), the segment of his animation (`0x0051D488`) and its first
    /// shape past `first_frame` (`0x0051D4D4`), the timer's count past which his next frame is due
    /// (`0x0051D4D8`), and the shape the drawing shows (`advance`).
    frame: u16 = 0,
    segment: u8 = 0,
    start: u16 = 0,
    next: u32 = 0,
    shown: usize = first_frame,
    /// The mission's movie on the room's screen, and whether it plays on (`0x0052027C`).
    film: rooms.Film = .{},
    playing: bool = false,
    /// The loudness of the movie's sound, Enriquez's narration, in LUFS, which his last word is
    /// matched to (`cbox.Style.Levels`); null for none.
    narration: ?f32 = null,
    /// The speech file of Enriquez's words (`0x0051D9F0`), whether the last word has been said
    /// (`0x0051DA14`), and the speech they play through.
    line: []u8 = &.{},
    said: bool = false,
    speech: cbox.Player = .{},
    /// The pointer's right button, which ends a stage only once it has come up since the stage
    /// began.
    ///
    /// **Fix:** the game ends a stage while the button is down, so that the press that skipped the
    /// way in, still held, ends the briefing at once, and the last word after it.
    right: input.FreshPress = .{},

    /// The briefing before mission `mission`, its door to be shown for a frame (`0x00437010` to
    /// `0x0043716F`); from the loadout where `from_loadout` has it.
    ///
    /// **Improvement:** its sounds, the movie's and Enriquez's words among them, ring subtly in a
    /// small room of the ship (`mss.Surroundings.inside`). The game plays them dry.
    pub fn open(context: rooms.Context, mission: u16, from_loadout: bool) Briefing {
        context.sound.surround(.inside);
        const room = Room.of(.of(mission));
        var briefing: Briefing = .{ .context = context, .mission = mission, .room = room, .from_loadout = from_loadout };
        briefing.door.set(context.gpa, context.resources.*, room.door) catch |err|
            log.warn("{s} is left out: {s}", .{ room.door, @errorName(err) });
        return briefing;
    }

    pub fn close(briefing: *Briefing) void {
        const gpa = briefing.context.gpa;
        briefing.speech.stop(gpa, briefing.context.sound);
        briefing.film.close();
        briefing.context.sound.endAll();
        briefing.freeLine();
        briefing.freeShapes();
        briefing.freeBanks();
        briefing.door.deinit(gpa);
        briefing.* = undefined;
    }

    fn freeLine(briefing: *Briefing) void {
        briefing.context.gpa.free(briefing.line);
        briefing.line = &.{};
    }

    fn freeShapes(briefing: *Briefing) void {
        if (briefing.shapes) |*shapes| shapes.deinit(briefing.context.gpa);
        briefing.shapes = null;
    }

    fn freeBanks(briefing: *Briefing) void {
        inline for (.{ &briefing.wait, &briefing.sounds }) |bank| {
            if (bank.*) |file| file.deinit(briefing.context.gpa);
            bank.* = null;
        }
    }

    /// A pass of the loop of the stage the briefing stands at, `in` read: what it leads to, if
    /// anything.
    pub fn pass(briefing: *Briefing, in: Input) ?Step {
        return switch (briefing.stage) {
            .door => briefing.load(in.ticks),
            .door_open => briefing.walk(),
            .walked_in => {
                briefing.begin(in.ticks);
                return briefing.briefingPass(in);
            },
            .briefing => briefing.briefingPass(in),
            .tag => briefing.tagPass(in),
        };
    }

    /// What the briefing loads once its door has shown (`0x00437172` on): the wait's sound plays,
    /// the briefing's sprite set is read, the music fades out and the voices pause, and the way
    /// in's sounds are read, before the way in, or from the loadout, the last word. The disc that
    /// holds the briefing opens, as the rooms have it open.
    ///
    /// Not ported: the loadout's models and sounds, which the game loads here but for mission 29
    /// (`loadout_load`, `0x00441AA0`).
    fn load(briefing: *Briefing, ticks: u32) ?Step {
        const context = briefing.context;
        const sound = context.sound;
        briefing.wait = .read(context.gpa, context.resources, wait_bank);
        if (briefing.wait) |wait| _ = sound.playInScene(wait.bank, 0, wait_volume, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
        briefing.shapes = readShapes(context, briefing.room.shapes);
        briefing.speech.stop(context.gpa, sound);
        sound.fadeMusic(music_fade_step, ticks);
        sound.pauseAll();
        briefing.sounds = context.readBank(sounds_bank);
        context.disc.open(rooms.Carrier.of(briefing.mission).disc());
        if (briefing.from_loadout) return briefing.afterBriefing(ticks);
        if (briefing.room.way.before) |before| {
            briefing.stage = .door_open;
            return .{ .movie = before };
        }
        return briefing.walk();
    }

    /// The door's sound and the room's chatter, then the way in's movie (`0x00437356` on).
    fn walk(briefing: *Briefing) Step {
        const way = briefing.room.way;
        if (briefing.sounds) |sounds| {
            const sound = briefing.context.sound;
            _ = sound.playInScene(sounds.bank, door_sound, hog_snd.loudest, hog_snd.once, hog_snd.centre, way.door_pitch);
            _ = sound.playInScene(sounds.bank, chatter_sound, hog_snd.loudest, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
        }
        briefing.stage = .walked_in;
        return .{ .movie = way.movie };
    }

    /// Into the room, at the timer's count `ticks` (`0x004373BB` on): the voices fade out, Enriquez
    /// starts his animation, and the room's screen the mission's movie; or at the campaign's end,
    /// he speaks.
    fn begin(briefing: *Briefing, ticks: u32) void {
        briefing.context.sound.fadeAll(voices_fade_step);
        briefing.stage = .briefing;
        briefing.right = .{};
        briefing.frame = 0;
        briefing.segment = 0;
        briefing.start = 0;
        briefing.next = ticks + first_wait;
        if (briefing.mission == end_mission) {
            briefing.readWords(end_debriefing);
            briefing.sayWords(end_debriefing);
            return;
        }
        var buffer: [movie_name_size]u8 = undefined;
        const name = movieName(&buffer, briefing.mission) orelse {
            log.warn("mission {d} has no briefing's movie", .{briefing.mission});
            return;
        };
        briefing.film.open(briefing.context, name, .briefing);
        const player = &(briefing.film.player orelse return);
        briefing.playing = true;
        player.bink.setRoom(.scene);
        briefing.narration = player.bink.loudness() catch null;
    }

    /// A pass of the briefing's loop (`0x004374F0` on), `in` read: Escape, the right button, or
    /// the movie's end ends it; at the campaign's end, the end of Enriquez's speech, which Escape
    /// and the right button stop.
    fn briefingPass(briefing: *Briefing, in: Input) ?Step {
        const sound = briefing.context.sound;
        const ending = briefing.mission == end_mission;
        const over = in.keyboard.pressed(input.scan.escape, .none, true) or
            (!briefing.playing and !ending) or
            briefing.right.pressed(in.right) or
            (ending and !briefing.speech.playing(sound));
        if (!over) return null;
        if (ending) briefing.speech.stop(briefing.context.gpa, sound);
        briefing.playing = false;
        briefing.film.close();
        briefing.freeLine();
        sound.endAll();
        return briefing.afterBriefing(in.ticks);
    }

    /// The briefing over (`0x004376D2` on): the voices end, and its sprite set and sounds are let
    /// go; then, but at the campaign's end, the loadout and the last word.
    fn afterBriefing(briefing: *Briefing, ticks: u32) ?Step {
        briefing.context.sound.endAll();
        briefing.freeShapes();
        briefing.freeBanks();
        if (briefing.mission == end_mission) return .over;
        briefing.lastWord(ticks);
        return null;
    }

    /// After the loadout, Enriquez's last word, at the timer's count `ticks` (`0x00437B80` on):
    /// its sprite set, his animation from its first frame, and his line read.
    fn lastWord(briefing: *Briefing, ticks: u32) void {
        const context = briefing.context;
        briefing.shapes = readShapes(context, briefing.room.tag_shapes);
        briefing.stage = .tag;
        briefing.right = .{};
        briefing.start = 0;
        briefing.frame = 0;
        briefing.said = false;
        briefing.next = ticks + first_wait;
        var buffer: [tag_line_size]u8 = undefined;
        briefing.readWords(tagLine(&buffer, briefing.mission));
    }

    /// A pass of the last word's loop (`0x00437C50` on), `in` read: the line is said as the
    /// animation reaches `tag_speaks_at`; Escape, the right button, or the animation's end ends it,
    /// and the line with it.
    fn tagPass(briefing: *Briefing, in: Input) ?Step {
        if (briefing.frame == tag_speaks_at and !briefing.said) {
            briefing.said = true;
            var buffer: [tag_line_size]u8 = undefined;
            briefing.sayWords(tagLine(&buffer, briefing.mission));
        }
        const over = in.keyboard.pressed(input.scan.escape, .none, true) or briefing.frame == tag_last or briefing.right.pressed(in.right);
        if (!over) return null;
        briefing.speech.stop(briefing.context.gpa, briefing.context.sound);
        briefing.freeLine();
        briefing.freeShapes();
        return .over;
    }

    /// Enriquez's words, the speech file `name` of `speech_hog` (`hog_read_file`), read; none where
    /// it is left out.
    fn readWords(briefing: *Briefing, name: []const u8) void {
        briefing.freeLine();
        const lines = briefing.context.lines orelse return;
        briefing.line = videoreports.readLine(briefing.context.gpa, lines.*, name) orelse &.{};
    }

    /// The words read, `name`, spoken (`speech_play`): the last word at the loudness of the
    /// narration before it, where the style's levels match them.
    fn sayWords(briefing: *Briefing, name: []const u8) void {
        if (briefing.line.len == 0) return;
        rooms.say(briefing.context, &briefing.speech, briefing.line, videoreports.lineName(name), .in_person, briefing.narration);
    }

    /// `briefing_draw`'s moves (`0x0043E730`), at `now` and the timer's count `ticks`: the shape
    /// Enriquez shows, then, once his next frame is due, his animation on, round its segments in
    /// the briefing and up to its end in the last word; and the movie's frame due shown, the movie
    /// over at its last.
    pub fn advance(briefing: *Briefing, now: u64, ticks: u32) void {
        switch (briefing.stage) {
            .door, .door_open, .walked_in => return,
            .briefing, .tag => {},
        }
        briefing.shown = first_frame + briefing.start + briefing.frame;
        if (ticks > briefing.next) {
            briefing.next = ticks + frame_wait;
            briefing.step();
        }
        if (briefing.playing and briefing.film.advance(now)) briefing.playing = false;
    }

    /// Enriquez's next frame: in the briefing, round the segments of his animation; in the last
    /// word, up to its end.
    fn step(briefing: *Briefing) void {
        switch (briefing.stage) {
            .briefing => {
                const ended = briefing.frame == briefing.room.segments[briefing.segment].last;
                briefing.frame += 1;
                if (!ended) return;
                briefing.frame = 0;
                briefing.segment = (briefing.segment + 1) % segment_count;
                briefing.start = briefing.room.segments[briefing.segment].start;
            },
            .tag => if (briefing.frame < tag_last) {
                briefing.frame += 1;
            },
            .door, .door_open, .walked_in => {},
        }
    }

    /// The movie paused while the window is away, as the message pump pauses it (`bink_playing`,
    /// `BinkPause`), at `now`.
    pub fn pause(briefing: *Briefing, paused: bool, now: u64) void {
        if (briefing.film.player) |*player| player.bink.pause(paused, now);
    }

    /// `briefing_draw` (`0x0043E730`): the room, Enriquez, and in the briefing the movie on the
    /// room's screen with the frame round it. Before the briefing, the door (`drawDoor`).
    pub fn draw(briefing: *Briefing, target: canvas.Canvas) canvas.Error!void {
        switch (briefing.stage) {
            .door, .door_open, .walked_in => return briefing.drawDoor(target),
            .briefing, .tag => {},
        }
        const shapes = if (briefing.shapes) |*loaded| &loaded.art else null;
        if (shapes) |art| {
            try target.shape(art, room_shape, .{ 0, 0 });
            try target.shape(art, briefing.shown, briefing.room.enriquez_at);
        }
        if (briefing.stage != .briefing or briefing.film.player == null) return;
        briefing.film.drawAt(target, briefing.room.screen_at);
        if (shapes) |art| try target.shape(art, briefing.room.frame_shape, briefing.room.frame_at);
    }

    /// `briefing_door_draw` (`0x00437D30`): the door, with AWAITING CLEARANCE across its foot.
    fn drawDoor(briefing: *Briefing, target: canvas.Canvas) Allocator.Error!void {
        if (briefing.door.image) |*shown| target.image(shown, .{ 0, 0 });
        var buffer: [awaiting_size]u8 = undefined;
        const words = std.fmt.bufPrint(&buffer, "{s} {s}", .{
            target.strings.string(awaiting) orelse "",
            target.strings.string(clearance) orelse "",
        }) catch return;
        try target.text(target.fonts.large, awaiting_at, words, canvas.white, .centre);
    }
};

test movieName {
    var buffer: [movie_name_size]u8 = undefined;
    try std.testing.expectEqualStrings("new_m01.bik", movieName(&buffer, 1).?);
    try std.testing.expectEqualStrings("new_m01.bik", movieName(&buffer, 22).?);
    try std.testing.expectEqualStrings("new_m28.bik", movieName(&buffer, 28).?);
    try std.testing.expectEqual(null, movieName(&buffer, 0));
    try std.testing.expectEqual(null, movieName(&buffer, end_mission));
}

test Room {
    try std.testing.expectEqual(&Room.reliant, Room.of(.of(18)));
    try std.testing.expectEqual(&Room.yamato, Room.of(.of(19)));
}

/// The briefing's files for the tests: `tested`'s disc with the movies `movie_names` and the way
/// in's sounds, and `resource.hog` with the wait's sound, and the doors and the sprite sets, which
/// don't parse, and so are left out.
fn testFiles(tested: *rooms.testing.Tested, movie_names: []const []const u8) !void {
    const bank = comptime hog_snd.testing.bank(3);
    const unread = "x";
    try tested.init(movie_names, &.{.{ .name = sounds_bank, .data = &bank }}, &.{
        .{ .name = wait_bank, .data = &bank },
        .{ .name = "rbriefdor.tga", .data = unread },
        .{ .name = "briefdoor.tga", .data = unread },
        .{ .name = Room.reliant.shapes, .data = unread },
        .{ .name = Room.reliant.tag_shapes, .data = unread },
        .{ .name = Room.yamato.shapes, .data = unread },
        .{ .name = Room.yamato.tag_shapes, .data = unread },
    });
}

/// A speech archive of `lines` in `tested`'s folder, `speech_hog`.
fn testLines(tested: *rooms.testing.Tested, lines: []const hog.testing.Member) !hog.Archive {
    const gpa = std.testing.allocator;
    try hog.testing.write(gpa, std.testing.io, tested.tmp.dir, "msspeech.hog", lines);
    return .open(gpa, std.testing.io, tested.tmp.dir, "msspeech.hog");
}

/// A pass at frame `frame` of fifteen a second, and the drawing's moves.
fn passAt(briefing: *Briefing, keyboard: *input.Keyboard, right: bool, frame: u64) ?Step {
    const ticks: u32 = @intCast(frame * 100 / 15);
    const step = briefing.pass(.{ .keyboard = keyboard, .right = right, .ticks = ticks });
    briefing.advance(frame * std.time.ns_per_s / 15, ticks);
    return step;
}

test Briefing {
    const gpa = std.testing.allocator;
    const line = try cbox.testFile(gpa, 100, 64);
    defer gpa.free(line);
    var tested: rooms.testing.Tested = undefined;
    try testFiles(&tested, &.{ "rel_c2bre.bik", "new_m01.bik" });
    defer tested.deinit();
    var lines = try testLines(&tested, &.{.{ .name = "enrbr_tag01", .data = line }});
    defer lines.close(gpa);
    var context = tested.context();
    context.lines = &lines;
    var keyboard: input.Keyboard = .{};

    // The door shows, then the briefing loads, its wait's sound paused as it ends, and the way in
    // plays, the door's sound and the room's chatter starting as its movie does.
    var briefing: Briefing = .open(context, 1, false);
    defer briefing.close();
    try std.testing.expectEqual(Stage.door, briefing.stage);
    try std.testing.expectEqual(.inside, tested.sound.surroundings);
    try std.testing.expectEqualDeep(Step{ .movie = "rel_c2bre.bik" }, passAt(&briefing, &keyboard, false, 0).?);
    try std.testing.expect(tested.sound.paused[1]);
    try std.testing.expect(tested.sound.voicePlaying(2) and tested.sound.voicePlaying(3));

    // Into the room: the mission's movie plays on the room's screen as Enriquez goes round his
    // animation, a frame every seventh tick.
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, false, 1));
    try std.testing.expectEqual(Stage.briefing, briefing.stage);
    try std.testing.expect(briefing.playing);
    try std.testing.expectEqual(first_frame, briefing.shown);
    var frame: u64 = 2;
    while (briefing.playing) : (frame += 1) try std.testing.expectEqual(null, passAt(&briefing, &keyboard, false, frame));
    try std.testing.expect(briefing.frame > 0);

    // The movie over, his last word: its line said at its seventeenth frame, and over at its end.
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, false, frame));
    try std.testing.expectEqual(Stage.tag, briefing.stage);
    try std.testing.expectEqual(0, briefing.frame);
    try std.testing.expect(briefing.line.len > 0);
    var step: ?Step = null;
    while (step == null) : (frame += 1) {
        step = passAt(&briefing, &keyboard, false, frame);
        if (briefing.frame > tag_speaks_at) try std.testing.expect(briefing.said);
    }
    try std.testing.expectEqual(Step.over, step.?);
    try std.testing.expectEqual(tag_last, briefing.frame);
}

test "Escape ends the briefing, and the right button the last word" {
    var tested: rooms.testing.Tested = undefined;
    try testFiles(&tested, &.{ "rel_c2bre.bik", "new_m02.bik" });
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var briefing: Briefing = .open(tested.context(), 2, false);
    defer briefing.close();
    _ = passAt(&briefing, &keyboard, false, 0);
    _ = passAt(&briefing, &keyboard, false, 1);
    try std.testing.expect(briefing.playing);
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, false, 2));
    try std.testing.expectEqual(Stage.tag, briefing.stage);
    try std.testing.expectEqual(null, briefing.film.player);
    // Without the speech's archive, his line is left out.
    try std.testing.expectEqual(0, briefing.line.len);
    // The right button, down as the last word begins, ends it once it has come up.
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, true, 3));
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, false, 4));
    try std.testing.expectEqual(Step.over, passAt(&briefing, &keyboard, true, 5).?);
}

test "the press that skipped the way in, still held, ends no stage" {
    var tested: rooms.testing.Tested = undefined;
    try testFiles(&tested, &.{ "rel_c2bre.bik", "new_m02.bik" });
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var briefing: Briefing = .open(tested.context(), 2, false);
    defer briefing.close();
    _ = passAt(&briefing, &keyboard, true, 0);
    for (0..3) |_| try std.testing.expectEqual(null, passAt(&briefing, &keyboard, true, 1));
    try std.testing.expect(briefing.stage == .briefing and briefing.playing);
    // Up, then down again, it ends the briefing; held on, not the last word.
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, false, 1));
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, true, 1));
    try std.testing.expectEqual(Stage.tag, briefing.stage);
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, true, 1));
    try std.testing.expectEqual(Stage.tag, briefing.stage);
}

test "the Yamato's way in and the frames of Enriquez's animation" {
    var tested: rooms.testing.Tested = undefined;
    try testFiles(&tested, &.{});
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var briefing: Briefing = .open(tested.context(), 19, false);
    defer briefing.close();
    try std.testing.expectEqual(&Room.yamato, briefing.room);
    try std.testing.expectEqualDeep(Step{ .movie = "amonoff_.bik" }, passAt(&briefing, &keyboard, false, 0).?);
    try std.testing.expectEqualDeep(Step{ .movie = "briefing room 350.bik" }, passAt(&briefing, &keyboard, false, 0).?);
    // Without its movie, the briefing ends at once.
    try std.testing.expectEqual(null, briefing.pass(.{ .keyboard = &keyboard, .right = false, .ticks = 100 }));
    try std.testing.expectEqual(Stage.tag, briefing.stage);

    // His animation goes round its segments, each played up to its last frame, then the next's
    // from its first shape.
    briefing.stage = .briefing;
    briefing.frame = Room.yamato.segments[0].last;
    briefing.step();
    try std.testing.expectEqual(0, briefing.frame);
    try std.testing.expectEqual(1, briefing.segment);
    try std.testing.expectEqual(85, briefing.start);
    briefing.segment = segment_count - 1;
    briefing.frame = Room.yamato.segments[segment_count - 1].last;
    briefing.step();
    try std.testing.expectEqual(0, briefing.segment);
    // In the last word it stops at its end.
    briefing.stage = .tag;
    briefing.frame = tag_last;
    briefing.step();
    try std.testing.expectEqual(tag_last, briefing.frame);
    // A frame is due once the timer's count passes the next frame's.
    briefing.next = 100;
    briefing.frame = 0;
    briefing.advance(0, 100);
    try std.testing.expectEqual(0, briefing.frame);
    briefing.advance(0, 101);
    try std.testing.expectEqual(1, briefing.frame);
    try std.testing.expectEqual(101 + 6, briefing.next);
}

test "the campaign's end: Enriquez's speech, and no last word" {
    const gpa = std.testing.allocator;
    const speech = try cbox.testFile(gpa, 100, 64);
    defer gpa.free(speech);
    var tested: rooms.testing.Tested = undefined;
    try testFiles(&tested, &.{});
    defer tested.deinit();
    var lines = try testLines(&tested, &.{.{ .name = "enddebriefing", .data = speech }});
    defer lines.close(gpa);
    var context = tested.context();
    context.lines = &lines;
    var keyboard: input.Keyboard = .{};
    var briefing: Briefing = .open(context, end_mission, false);
    defer briefing.close();
    _ = passAt(&briefing, &keyboard, false, 0);
    _ = passAt(&briefing, &keyboard, false, 0);
    _ = passAt(&briefing, &keyboard, false, 1);
    // He speaks without a movie.
    try std.testing.expectEqual(Stage.briefing, briefing.stage);
    try std.testing.expect(briefing.speech.playing(&tested.sound));
    try std.testing.expect(!briefing.playing);
    // His speech over, so is the briefing.
    var out: [512][2]f32 = undefined;
    tested.mixer.mix(&out);
    try std.testing.expectEqual(Step.over, passAt(&briefing, &keyboard, false, 2).?);
}

test "from the loadout, the last word alone" {
    var tested: rooms.testing.Tested = undefined;
    try testFiles(&tested, &.{});
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var briefing: Briefing = .open(tested.context(), 3, true);
    defer briefing.close();
    try std.testing.expectEqual(null, passAt(&briefing, &keyboard, false, 0));
    try std.testing.expectEqual(Stage.tag, briefing.stage);
}
