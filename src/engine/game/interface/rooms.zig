//! The Reliant's rooms, and the Yamato's, which the game calls VR (`VR_movie`): the hub a
//! single-player campaign comes back to between missions, a carrier's rooms walked through in
//! movies (`vr_rooms`, `0x00439FB0`). Each place the player stands in is a view (`View`): a movie
//! on the way into it, and one it loops once there, with hotspots that lead on to the next views,
//! or to what happens there (`Action`). The views are tables of the executable, which
//! `tablegen rooms` transcribes ([`rooms/views.zig`](rooms/views.zig)).
//!
//! A pass of the rooms' loop (`0x0043A2C1`) reads the keyboard and the pointer: Escape opens the
//! in-game options (`Step.options`); a view the player has arrived in gets its loop or its action;
//! and the pointer takes the exit under it. The drawing (`vr_draw`, `0x0043C1C0`) plays the movie
//! on, then draws the label of the exit under the pointer, the fish's food and the pointer. The
//! television plays the news report within the rooms (`News`).
//!
//! **Improvement:** the pointer is where the system's is over the window, as it is on the front
//! end's screens (`canvas.Pointer`). The game adds up DirectInput's movements.
//!
//! The crew the player passes on the way to the briefing room's door show over its movie, and
//! speak (`crew`).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const engine = @import("../../../engine.zig");
const hog = @import("../../../formats/hog.zig");
const bink = @import("../../bink.zig");
const input = @import("../../input.zig");
const bigfile = @import("../bigfile.zig");
const cbox = @import("../cbox.zig");
const gameflow = @import("../gameflow.zig");
const hog_snd = @import("../hog_snd.zig");
const hud = @import("../hud.zig");
const videoreports = @import("../videoreports.zig");
const movie = @import("../xtrabits/movie.zig");
const canvas = @import("canvas.zig");
const disc_module = @import("disc.zig");

pub const crew = @import("rooms/crew.zig");
pub const views = @import("rooms/views.zig");

const log = std.log.scoped(.rooms);

/// A view of the rooms (`0x30` bytes each): a place the player stands in, and the way into it.
pub const View = struct {
    /// Where it lies in the executable, which the code names the views it enters the rooms by with
    /// (`Entry`).
    address: u32,
    /// Where the pointer takes it on each view it is an exit of (`+0x00`).
    hotspot: canvas.Rect,
    /// The movie on the way into it (`+0x08`), and the one it loops once there (`+0x0C`), from the
    /// disc's archive; null for none. Without a loop, the way in's last frame stays.
    movie: ?[]const u8,
    loop: ?[]const u8,
    /// The string that names the way into it, which shows as the pointer rests on its hotspot
    /// (`+0x10`).
    label: u16,
    /// The views it leads to (`+0x14`, as many as `+0x12` counts), by their place in `views.views`.
    exits: []const u8,
    /// What happens once the player is in it (`+0x28`).
    action: Action,
    /// The sound of `hum_bank` the way into it plays as the player takes it (`+0x2A`); null for
    /// none.
    sound: ?u8,

    /// The most exits a view has.
    pub const max_exits = 4;

    /// A view as the executable holds it.
    pub const Record = extern struct {
        hotspot: canvas.Rect,
        movie: engine.Pointer(u8),
        loop: engine.Pointer(u8),
        label: i16,
        exit_count: i16,
        exits: [max_exits]engine.Pointer(Record),
        _unknown_24: u32,
        action: Action,
        /// -1 for none.
        sound: i16,
        _unknown_2c: u32,

        comptime {
            assert(@offsetOf(Record, "movie") == 0x08);
            assert(@offsetOf(Record, "label") == 0x10);
            assert(@offsetOf(Record, "exits") == 0x14);
            assert(@offsetOf(Record, "action") == 0x28);
            assert(@offsetOf(Record, "sound") == 0x2A);
            assert(@sizeOf(Record) == 0x30);
        }
    };
};

/// What happens once the player is in a view.
pub const Action = enum(i16) {
    /// Nothing: the view loops, and its hotspots lead on.
    none = 0,
    /// Enter Briefing Room: the briefing, the front end's screen 7 (`interface_run`).
    briefing = 1,
    /// Use ITAC (`itac`, `0x0043EFC0`).
    itac = 2,
    /// Walk to Fish Tank: the fish swim, and the pointer can feed them (`Fish`).
    fish_tank = 3,
    /// **Unknown:** a view that plays two animations of a sprite set over its movie. No view has
    /// it. **Not ported.**
    animated = 4,
    /// Enter Simulator Pod (`simulator_pod`, `0x0044F3D0`).
    simulator = 5,
    /// Open Locker (`medal_display`, `0x004362F0`).
    locker = 6,
    /// Watch ACN News: the news report on the television (`News`).
    news = 7,
    /// **Unknown:** a view the pointer lights as it does those with an action. No view has it.
    unused = 8,
    /// Use CD player (`cd_player`, `0x00437FC0`).
    cd_player = 9,
    _,

    /// Whether the pointer lights over the way into a view of it (`0x0043C8A5`).
    pub fn lights(action: Action) bool {
        return switch (action) {
            .briefing, .itac, .fish_tank, .simulator, .locker, .news, .unused, .cd_player => true,
            .none, .animated, _ => false,
        };
    }

    pub fn format(action: Action, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (action) {
            _ => writer.print("action {d}", .{@intFromEnum(action)}),
            inline else => |named| writer.writeAll(@tagName(named)),
        };
    }
};

/// The views the code enters the rooms by, which `tablegen rooms` walks the tables from.
pub const Entry = enum(u32) {
    /// Where the rooms start on the Reliant, up to mission 18, and on the Yamato after it
    /// (`0x0043A361`, `0x0043A352`).
    reliant_start = 0x00506AD0,
    yamato_start = 0x0050B2B8,
    /// Where the news report leaves the player (`0x0043A52E`, `0x0043A522`).
    reliant_after_news = 0x00506E30,
    yamato_after_news = 0x0050B318,
    /// Where the ITAC leaves the player (`0x0043AA30`, `0x0043AA24`), and where `WinMain` opens
    /// the rooms as the campaign goes on after a mission (`0x004AA381`, `0x004AA372`).
    reliant_after_itac = 0x00506C80,
    yamato_after_itac = 0x0050AEC8,
    /// Where the simulator pod leaves the player (`0x0043AB94`, `0x0043AB8D`).
    reliant_after_simulator = 0x00506D10,
    yamato_after_simulator = 0x0050B678,
    /// Where the locker leaves the player (`0x0043ACAE`, `0x0043ACA2`).
    reliant_after_locker = 0x00506F20,
    yamato_after_locker = 0x0050B3A8,
    /// Where the CD player leaves the player (`0x0043ADD0`, `0x0043ADC9`).
    reliant_after_cd_player = 0x00506DD0,
    yamato_after_cd_player = 0x0050B168,
    /// Where `WinMain` puts the player as a new pilot's induction ends: the simulator pod, turned
    /// to from the ITAC or from the CD player (`0x004AA2A4`, `0x004AA26E`).
    reliant_pod_from_itac = 0x00506CB0,
    reliant_pod_from_cd_player = 0x00506BF0,
};

/// The place in `views.views` of the view at `address`.
pub fn viewAt(comptime address: u32) u8 {
    comptime {
        for (views.views, 0..) |view, index| if (view.address == address) return index;
        @compileError(std.fmt.comptimePrint("no view at 0x{X:0>8}", .{address}));
    }
}

/// The place of the view `entry` names.
pub fn entryView(comptime entry: Entry) u8 {
    return comptime viewAt(@intFromEnum(entry));
}

/// The carrier the rooms are on: the Reliant up to mission 18, the Yamato after it
/// (`0x0043A04C`).
pub const Carrier = enum {
    reliant,
    yamato,

    pub fn of(mission: u16) Carrier {
        return if (mission > movie.last_from_reliant) .yamato else .reliant;
    }

    /// The disc whose archive holds its rooms, which `WinMain` opens for them (`0x004AA1FF` on),
    /// as the in-game options do after LOAD (`0x0043970F`).
    pub fn disc(carrier: Carrier) disc_module.Number {
        return switch (carrier) {
            .reliant => .two,
            .yamato => .one,
        };
    }

    /// The view the rooms start in.
    pub fn start(carrier: Carrier) u8 {
        return switch (carrier) {
            .reliant => entryView(.reliant_start),
            .yamato => entryView(.yamato_start),
        };
    }

    /// The view a place's screen leaves the player in.
    pub fn after(carrier: Carrier, place: Place) u8 {
        return switch (carrier) {
            .reliant => switch (place) {
                .news => entryView(.reliant_after_news),
                .itac => entryView(.reliant_after_itac),
                .simulator => entryView(.reliant_after_simulator),
                .locker => entryView(.reliant_after_locker),
                .cd_player => entryView(.reliant_after_cd_player),
            },
            .yamato => switch (place) {
                .news => entryView(.yamato_after_news),
                .itac => entryView(.yamato_after_itac),
                .simulator => entryView(.yamato_after_simulator),
                .locker => entryView(.yamato_after_locker),
                .cd_player => entryView(.yamato_after_cd_player),
            },
        };
    }

    /// The ship's hum, the sound of `hum_bank` the rooms play over and over (`0x0043A05F`).
    fn hum(carrier: Carrier) usize {
        return switch (carrier) {
            .reliant => 4,
            .yamato => 5,
        };
    }
};

/// The places with a screen of their own, which the rooms leave for and come back from: the news
/// report, which plays within the rooms (`News`), and the screens of the ITAC (`game.itac`), the
/// simulator pod (`interface.loadout.simulator_pod`), the locker (`interface.locker`) and the CD
/// player (`interface.cd_player`).
pub const Place = enum {
    news,
    itac,
    simulator,
    locker,
    cd_player,

    fn of(action: Action) ?Place {
        return switch (action) {
            .news => .news,
            .itac => .itac,
            .simulator => .simulator,
            .locker => .locker,
            .cd_player => .cd_player,
            .none, .briefing, .fish_tank, .animated, .unused, _ => null,
        };
    }
};

/// The rooms' sound banks on the disc (`0x004E9024`, `0x004E9018`): the ship's sounds, the hum and
/// the ways into some views; and the player's, the steps and the doors.
pub const hum_bank = "vrsnd.fat";
pub const steps_bank = "wlksmp.fat";

/// The hum's volume (`0x0043A050`).
const hum_volume = 0x50;

/// The rooms' steps and doors (`vr_steps_bank`, `0x0051D9FC`), which the rooms and the screens of
/// their places sound from; none where the bank is left out.
pub const Steps = struct {
    file: ?*const hog_snd.BankFile = null,

    /// `which` at full volume, once, in the middle, ringing in the room as the rooms' sounds do.
    pub fn play(steps: Steps, sound: *hog_snd.Sound, which: StepSound) void {
        const file = steps.file orelse return;
        _ = sound.playInScene(file.bank, @intFromEnum(which), hog_snd.loudest, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
    }
};

/// The sounds of the steps and doors, by what plays them.
pub const StepSound = enum(u8) {
    /// Into the news report and out of it (`0x0043A4B9` on).
    news_before = 2,
    news_after = 3,
    /// The locker's lid going down and up (`0x0043691B`, `0x00436697`).
    lid_down = 4,
    lid_up = 5,
    /// Out of the locker and into it.
    locker_after = 6,
    locker_before = 7,
    /// A press over a button or a row of the CD player (`0x0043846A`).
    cd_press = 8,
    /// Into the simulator pod and out of it.
    simulator_before = 9,
    simulator_after = 0xB,
    /// A choice taken in the simulator pod (`0x0044F5EC`).
    pod_choice = 0xC,
};

/// The step the music fades by as the player goes into the briefing, the news, the ITAC and the
/// simulator pod (`music_fade_out`, `0x0043A49D`).
const music_fade_step = 15;

/// The pointer's shapes, from `resource.hog` (`0x004E8FA8`).
pub const pointer_shapes = "interface\\vrgfx.spr";

/// The rooms' pointer (`0x0051DB34`, `0x0051DACC`): where it is, the shape it shows
/// (`0x0051D618`) and the one its place calls for (`0x0051D7E4`), and its animation's frame
/// (`0x00520244`).
pub const Pointer = struct {
    at: [2]i32 = .{ 320, 200 },
    shape: u8 = straight,
    toward: u8 = straight,
    frame: u8 = 0,

    /// Its shapes, each one less than the set's: an arrow to the left, the pointer, an arrow to
    /// the right, and those between them it turns through, every other one.
    pub const left = 0;
    pub const straight = 11;
    pub const right = 21;

    /// Where it turns into the arrows: left of 40, and from 541 on (`0x0043B8D7`).
    const left_edge = 40;
    const right_edge = 541;

    /// Its bounds: 4 from the screen's left, 65 short of its right and 41 short of its bottom
    /// (`0x0043B37D` on).
    const least_x = 4;
    const right_margin = 65;
    const bottom_margin = 41;

    /// Its animation's frames, and the step it turns by.
    const frames = 9;
    const turn = 2;

    /// The shapes over it: the skip's, its lights over the way into a view with an action, and
    /// the arrows' animations (`0x0043C85A` on).
    const skip_shape = 50;
    const skip_offset = 22;
    const light_shapes = 23;
    const left_shapes = 32;
    const right_shapes = 41;

    /// `at` held within its bounds.
    fn place(pointer: *Pointer, at: [2]i32) void {
        pointer.at = .{
            std.math.clamp(at[0], least_x, @as(i32, canvas.size[0]) - right_margin),
            std.math.clamp(at[1], 0, @as(i32, canvas.size[1]) - bottom_margin),
        };
    }

    /// A tick of the rooms' timer: the animation on, and the shape a step toward the one its
    /// place calls for (`0x0043B8B1` on).
    fn tick(pointer: *Pointer) void {
        pointer.frame = (pointer.frame + 1) % frames;
        pointer.toward = if (pointer.at[0] < left_edge) left else if (pointer.at[0] < right_edge) straight else right;
        if (pointer.shape < pointer.toward) {
            pointer.shape = @min(pointer.shape + turn, pointer.toward);
        } else if (pointer.shape > pointer.toward) {
            pointer.shape = @max(pointer.shape -| turn, pointer.toward);
        }
    }
};

/// The rooms' timer, which moves the pointer's animation on 15 times a second (`timer_start`,
/// `0x0043A29F`; `vr_timer`, `0x00437DD0`).
const timer_rate = 15;

/// The fish tank (`Action.fish_tank`): its movies, which play one after another, and the food,
/// which the pointer drops as it presses on it.
pub const Fish = struct {
    /// Which of `movies` plays (`0x0051DAC0`).
    movie: u8 = 0,
    /// Whether the pointer rests on the food (`0x0051D4BC`).
    over_food: bool = false,
    /// The ticks the food has fallen for (`0x0051D600`), null while none falls.
    feeding: ?u32 = null,
    /// The food's shapes, from the disc (`0x004E8F90`), and the tick it last moved on at.
    shapes: ?canvas.Shapes = null,
    fed_at: u32 = 0,

    /// The fish's movies, one after another from the first as the view settles (`0x004E8138`,
    /// `0x004E8F9C`, each `%s.bik` of its name).
    pub const movies = [_][]const u8{ "move_a_.bik", "move_d_.bik", "move_a_.bik", "move_a_.bik", "move_b_.bik", "move_a_.bik", "move_a_.bik", "move_c_.bik", "move_a_.bik", "move_d_.bik", "move_d_.bik", "move_a_.bik", "move_a_.bik", "move_c_.bik" };

    /// The food's sprite set.
    pub const food = "fish.spr";

    /// Where the pointer drops the food: Press for Fish Food (`0x0043B20B`; string `0xE1`).
    const food_hotspot: canvas.Rect = .{ .x = 67, .y = 131, .width = 68, .height = 120 };
    const food_label = 0xE1;

    /// The food falling, a shape of the set a tick from the third, and the tank's front, drawn
    /// over it (`0x0043C73C` on); the food falls for 498 ticks.
    const falling_at: [2]i32 = .{ 250, 125 };
    const first_falling = 3;
    const front_shape = 2;
    const front_at: [2]i32 = .{ 23, 110 };
    const falling_ticks = 498;

    fn deinit(fish: *Fish, gpa: Allocator) void {
        if (fish.shapes) |*shapes| shapes.deinit(gpa);
        fish.shapes = null;
    }
};

/// What the rooms play and draw with.
pub const Context = struct {
    gpa: Allocator,
    /// The movies' decoders, and OpenReliant's look for their pictures.
    codec: bink.Codec,
    look: bink.Look,
    /// The disc's archive open, which holds the rooms' movies, their sound banks, the fish's food
    /// and Enriquez's scenes.
    disc: *disc_module.Disc,
    /// `resource.hog`, which holds the pointer's shapes.
    resources: *const bigfile.Hog,
    sound: *hog_snd.Sound,
    /// How Enriquez's scenes and words sound: the radio's style (`cbox.Style`), where she is heard
    /// as she speaks from a screen or in person (`Voice`).
    speech: cbox.Style,
    /// `speech_hog`, which holds Enriquez's words in the briefing (`videoreports.speech_archive`);
    /// null where the game's folder has none.
    lines: ?*const hog.Archive = null,
    /// The campaign flown, whose mission before picks the crew the rooms show (`crew`); none
    /// outside one.
    campaign: ?*const gameflow.Campaign = null,
    /// Which of the Yamato's second crew comes next, which outlasts the rooms; none to start from
    /// the first each time.
    second_crew: ?*crew.Turn = null,
    /// The outline fonts that stand in for the fonts of the screens the rooms open, the ITAC's
    /// among them (`hud.FontFile`); none for the bitmap fonts alone.
    outlines: ?*hud.outline.Outlines = null,

    /// The file `name` of the disc's archive open, expanded; null where it is left out, which the
    /// log says.
    pub fn read(context: Context, name: []const u8) ?[]u8 {
        return context.disc.readFile(context.gpa, name) catch |err| {
            log.warn("{s} is left out: {s}", .{ name, @errorName(err) });
            return null;
        } orelse {
            log.warn("{s} is left out: no disc's archive open holds it", .{name});
            return null;
        };
    }

    /// The bank `name` of the disc's archive open; null where it is left out.
    pub fn readBank(context: Context, name: []const u8) ?hog_snd.BankFile {
        const bytes = context.read(name) orelse return null;
        return .of(context.gpa, bytes, name);
    }

    /// The sprite set `name` of the disc's archive open, with the pictures the mods give in its
    /// shapes' place; null where it is left out.
    pub fn readShapes(context: Context, name: []const u8) ?canvas.Shapes {
        const bytes = context.read(name) orelse return null;
        return .of(context.gpa, bytes, name, .of(context.disc.mods, name));
    }

    /// The speech file `speech` of `speech_hog` (`hog_read_file`), a mod's first
    /// (`videoreports.readLine`); null where it is left out.
    pub fn readLine(context: Context, speech: []const u8) ?[]u8 {
        return videoreports.readLine(context.gpa, context.resources.mods, if (context.lines) |lines| lines.* else null, speech);
    }
};

/// The movie the rooms play in their own loop (`0x0051D7E8`), as the induction, the news report
/// and the briefing do: from the disc's archive, at 15 frames a second (`movie.Kind.screen`) or,
/// the briefing's, at its own rate (`movie.Kind.briefing`), each frame copied to the screen as it
/// is due.
pub const Film = struct {
    player: ?movie.Player = null,
    /// Whether it loops from its second frame as it ends: the game keeps the pictures of its first
    /// to put back (`0x0051D9D8`).
    loops: bool = false,
    /// Whether its last frame has shown with nothing to follow, which then stays.
    still: bool = false,

    /// The movie `name` from the disc, played as `kind` has it, its sound through the context's,
    /// in place of the one playing; none where it is left out, as where `name` is null.
    pub fn open(film: *Film, context: Context, name: ?[]const u8, kind: movie.Kind) void {
        film.close();
        const wanted = name orelse return;
        film.player = .load(context.gpa, context.codec, context.disc, wanted, kind, context.sound.driver, context.look);
    }

    pub fn close(film: *Film) void {
        if (film.player) |*player| player.close();
        film.* = .{};
    }

    /// The frame due shown (`BinkDoFrame`, `BinkCopyToBuffer`).
    pub fn show(film: *Film, now: u64) void {
        const player = &(film.player orelse return);
        player.show(now) catch |err| film.stop(err);
    }

    /// The frame due shown, once it is due, as a drawing shows its movie (`vr_draw`, the
    /// induction's): the next one after it, or at the last, true.
    pub fn advance(film: *Film, now: u64) bool {
        const player = &(film.player orelse return false);
        if (film.still or player.bink.wait(now)) return false;
        film.show(now);
        const shown = &(film.player orelse return false);
        if (shown.atEnd()) return true;
        shown.bink.nextFrame();
        return false;
    }

    /// The frame it shows, from 1; none where there is no movie.
    pub fn frame(film: Film) ?u32 {
        const player = film.player orelse return null;
        return player.bink.frame_number;
    }

    /// Back to its second frame, as a loop goes round (`BinkGoto`). The game first puts back its
    /// first frame's pictures, for the second to build on; the stand-in's `goto` decodes from the
    /// key frame before it.
    pub fn loopBack(film: *Film, now: u64) void {
        const player = &(film.player orelse return);
        player.bink.goto(2, now) catch |err| film.stop(err);
    }

    /// To its last frame, shown, which then stays.
    pub fn jumpToEnd(film: *Film, now: u64) void {
        const player = &(film.player orelse return);
        player.bink.goto(player.bink.frames, now) catch |err| return film.stop(err);
        film.show(now);
        film.still = true;
    }

    fn stop(film: *Film, err: bink.Error) void {
        log.warn("a movie of the rooms stops short: {s}", .{@errorName(err)});
        film.close();
    }

    /// Its frame, at its size in the middle of the front end's screen.
    pub fn draw(film: *Film, target: canvas.Canvas) void {
        if (film.player) |*player| player.draw(target.target, target.window, .screen);
    }

    /// Its frame, at its size with its top left corner at `at` on the front end's screen.
    pub fn drawAt(film: *Film, target: canvas.Canvas, at: [2]i32) void {
        if (film.player) |*player| target.image(&player.picture, at);
    }
};

/// One of Enriquez's scenes, the file `box` from the disc, spoken through `speech` from a screen,
/// the scene before ended (`say`). A scene left out is not spoken.
pub fn speak(context: Context, speech: *cbox.Player, box: []const u8) void {
    speech.stop(context.gpa, context.sound);
    const bytes = context.read(box) orelse return;
    defer context.gpa.free(bytes);
    say(context, speech, bytes, box, .screen, null);
}

/// Where Enriquez speaks from, which decides where she is heard.
pub const Voice = enum {
    /// **Improvement:** a screen, the television's or a monitor's: heard as the radio's voices
    /// are, in the cockpit's cabin (`cbox.Style.Room.cabin`), short and hard, as over a speaker.
    screen,
    /// **Improvement:** in person, in the briefing room: heard in the scene's room, as the rooms'
    /// other sounds are.
    in_person,

    /// Where she is heard with the radio's style `style`: dry where the style's lines are, as the
    /// game plays them.
    fn room(voice: Voice, style: cbox.Style.Room) cbox.Style.Room {
        if (style == .dry) return .dry;
        return switch (voice) {
            .screen => .cabin,
            .in_person => .scene,
        };
    }
};

/// `bytes`, the speech file `name`, unscrambled in place and spoken through `speech` from `from`:
/// once, at full volume (`speech_play`, `0x00461D80`); where it follows a recording `follows`
/// LUFS loud, matched to it as the style's levels have it (`cbox.Style.Levels`). A file that is not
/// speech is not spoken, which the log says.
pub fn say(context: Context, speech: *cbox.Player, bytes: []u8, name: []const u8, from: Voice, follows: ?f32) void {
    const parsed = cbox.Speech.parse(bytes) orelse {
        log.warn("{s} is left out: it is not speech", .{name});
        return;
    };
    var style = context.speech;
    style.room = from.room(style.room);
    _ = speech.start(context.gpa, context.sound, parsed, speech_volume, style, follows);
}

/// The volume Enriquez's scenes and words play at.
const speech_volume = hog_snd.loudest;

/// The news report on the television (`news_report`, `0x0043BA40`): the next mission's report,
/// Enriquez's scene spoken over the television's movie, and mission 1's in three parts. Escape or
/// a button of the pointer ends it, as does the speech's end.
pub const News = struct {
    /// Mission 1's part playing: 1 the first, 2 the second, 0 the last, as for any other mission's
    /// only one (`0x0043BB43`).
    part: u8,

    /// Each mission's report, by its number from 1 (`0x0043BA60` on): Enriquez's scene, `%s.box`
    /// of its name.
    pub const scenes = [_][]const u8{ "0005a.box", "0015.box", "0025.box", "0035.box", "0045.box", "0055.box", "0065.box", "0075.box", "0085.box", "0095.box", "0105.box", "0115.box", "0125.box", "0135.box", "0145.box", "0155.box", "0165.box", "0175.box", "0185.box", "0195.box", "0205.box", "0215.box", "0225.box", "0235.box", "0245.box", "0255.box", "0265.box", "0275.box" };

    /// The television's movies, the Reliant's and the Yamato's (`0x004E9054`, `0x004E90C0`), and
    /// mission 1's second and last parts (`0x0043C00B` on).
    pub const reliant_television = "rel_tv_in_loop.bik";
    pub const yamato_television = "b_tv_news_.bik";
    const second: Part = .{ .movie = "tv_cald.bik", .scene = "0005b.box" };
    const last: Part = .{ .movie = reliant_television, .scene = "0005c.box" };

    const Part = struct { movie: []const u8, scene: []const u8 };

    /// The label it shows: Click to Leave News Report.
    const label = 0x299;
};

/// What a pass reads.
pub const Input = struct {
    keyboard: *input.Keyboard,
    /// Where the pointer is on the front end's screen, and its buttons.
    at: [2]i32,
    left: bool,
    right: bool,
    /// The video settings' `Transitions`: off, a click on a hotspot skips the way in.
    transitions: bool,
    /// Now, in nanoseconds, which the movies play by; and the timer's count, a hundred a second
    /// (`game_ticks`), which the food falls by and the music fades by.
    now: u64,
    ticks: u32,
};

/// What a pass leads to, which the rooms' caller then runs.
pub const Step = union(enum) {
    /// Escape: the in-game options, after which the rooms go on, or start again from their first
    /// view where a saved game was loaded (`restart`).
    options,
    /// A place's screen, after which `leave` puts the player back in the rooms. The news report
    /// plays within the rooms, and never comes to the caller.
    place: Place,
    /// Through the briefing room's door: the briefing, the front end's screen 7
    /// ([`briefing.zig`](briefing.zig)), which `vr_rooms` runs once it has let the rooms go, before
    /// it returns for the mission to be flown.
    briefing,
};

/// Where the view's movies stand (`0x0051D9E4`).
pub const Phase = enum(u8) {
    /// Its loop, or the way in's last frame, with the hotspots live.
    settled = 1,
    /// The way into it.
    way_in = 2,
};

/// The rooms, as `vr_rooms` runs them.
pub const Rooms = struct {
    context: Context,
    /// The mission the rooms come before (`mission_number`), whose news report the television
    /// plays, and the carrier it puts them on.
    mission: u16,
    carrier: Carrier,
    /// The view the player is in, or on the way into (`0x0051D478`).
    view: u8,
    phase: Phase = .way_in,
    /// Set as the way in ends (`0x00520298`): the view's loop or its action next.
    arrived: bool = false,
    film: Film = .{},
    pointer: Pointer = .{},
    /// The exit under the pointer, by its place in the view's exits (`0x00520184`).
    hover: ?u8 = null,
    /// Whether the buttons were down as a pass took them up, which a press then waits to come up
    /// (the loop's `iVar13`, `iVar22`).
    left_held: bool = false,
    right_held: bool = false,
    /// Set while the pointer shows the skip's shape, the pass before the skip jumps to the way in's
    /// last frame (`0x00520264`).
    skipping: bool = false,
    /// Set for the pass that jumps.
    jump: bool = false,
    /// When the rooms opened, from which their timer counts, and its last tick a pass took up
    /// (`0x0051D48C`, `0x005D6C3C`).
    opened_at: u64,
    seen: u64 = 0,
    /// The ship's sounds and the player's (`0x0051D560`, `0x0051D9FC`), and the voice the hum
    /// plays on.
    hum: ?hog_snd.BankFile = null,
    steps: ?hog_snd.BankFile = null,
    hum_voice: ?u8 = null,
    /// The pointer's shapes (`0x0051D548`).
    shapes: ?canvas.Shapes = null,
    fish: Fish = .{},
    /// The news report, while it plays (`0x0051D454`), and the speech it plays through.
    news: ?News = null,
    speech: cbox.Player = .{},
    /// The crew shown on the way to the briefing room's door, picked as the rooms open.
    crew: crew.Crew = .{},

    /// The rooms before mission `mission` from `view`, its way in shown as it starts, at `now`.
    ///
    /// **Improvement:** their sounds ring subtly in a small room of the ship
    /// (`mss.Surroundings.inside`), and Enriquez's scenes as the radio's voices do (`Voice`). The
    /// game plays them dry.
    pub fn open(context: Context, mission: u16, view: u8, now: u64) Rooms {
        context.sound.surround(.inside);
        var rooms: Rooms = .{ .context = context, .mission = mission, .carrier = .of(mission), .view = view, .opened_at = now };
        rooms.readBanks();
        rooms.playHum();
        rooms.shapes = .read(context.gpa, context.resources, pointer_shapes);
        rooms.enter(views.views[view].movie, now, true);
        rooms.pickCrew(now);
        return rooms;
    }

    pub fn close(rooms: *Rooms) void {
        const gpa = rooms.context.gpa;
        rooms.speech.stop(gpa, rooms.context.sound);
        rooms.film.close();
        rooms.fish.deinit(gpa);
        if (rooms.shapes) |*shapes| shapes.deinit(gpa);
        rooms.context.sound.endAll();
        rooms.crew.deinit(gpa);
        if (rooms.hum) |file| file.deinit(gpa);
        if (rooms.steps) |file| file.deinit(gpa);
        rooms.* = undefined;
    }

    /// `vr_crew_pick` as the rooms open (`0x0043A2A8`), or a game loads into them, drawn from a
    /// generator seeded with `now`.
    fn pickCrew(rooms: *Rooms, now: u64) void {
        var fresh: gameflow.Campaign = undefined;
        const campaign = rooms.context.campaign orelse campaign: {
            fresh = .begin();
            break :campaign &fresh;
        };
        var prng: std.Random.DefaultPrng = .init(now);
        var turn: crew.Turn = .{};
        rooms.crew = .pick(rooms.context, rooms.mission, campaign, prng.random(), rooms.context.second_crew orelse &turn);
    }

    fn current(rooms: Rooms) View {
        return views.views[rooms.view];
    }

    /// `vrsnd.fat` and `wlksmp.fat`, from the disc; a bank left out leaves its sounds out.
    fn readBanks(rooms: *Rooms) void {
        rooms.hum = rooms.context.readBank(hum_bank);
        rooms.steps = rooms.context.readBank(steps_bank);
    }

    /// The ship's hum, over and over, the one before ended.
    fn playHum(rooms: *Rooms) void {
        const hum = rooms.hum orelse return;
        if (rooms.hum_voice) |voice| rooms.context.sound.endVoice(voice);
        rooms.hum_voice = rooms.context.sound.playInScene(hum.bank, rooms.carrier.hum(), hum_volume, hog_snd.forever, hog_snd.centre, hog_snd.own_pitch);
    }

    fn playStep(rooms: *Rooms, which: StepSound) void {
        rooms.stepSounds().play(rooms.context.sound, which);
    }

    /// Its steps and doors, which the screens of its places sound from too.
    pub fn stepSounds(rooms: *const Rooms) Steps {
        return .{ .file = if (rooms.steps) |*file| file else null };
    }

    /// Into a view: its movie `name` opened, its first frame shown at `now` where `show` has it.
    fn enter(rooms: *Rooms, name: ?[]const u8, now: u64, show: bool) void {
        rooms.film.open(rooms.context, name, .screen);
        if (show) rooms.film.show(now);
    }

    /// A pass of the rooms' loop, `in` read (`0x0043A2C1`): what it leads to, if anything. While
    /// the news report plays, a pass of its own loop, and at its end, the rooms again.
    pub fn pass(rooms: *Rooms, in: Input) ?Step {
        if (rooms.news != null) {
            if (!rooms.newsPass(in)) rooms.leave(.news, in.now);
            return null;
        }
        if (rooms.jump) rooms.jumpToEnd(in.now);
        if (in.keyboard.pressed(input.scan.escape, .none, true)) return .options;
        if (rooms.arrived) {
            const view = rooms.current();
            if (view.action == .briefing) {
                rooms.film.close();
                rooms.context.sound.fadeMusic(music_fade_step, in.ticks);
                rooms.context.sound.endAll();
                return .briefing;
            }
            if (Place.of(view.action)) |place| {
                rooms.before(place, in.ticks);
                if (place != .news) return .{ .place = place };
                if (!rooms.startNews(in.now)) rooms.leave(.news, in.now);
                return null;
            }
            rooms.settle(in.now);
        }
        if (rooms.phase == .settled) rooms.food(in);

        rooms.pointer.place(in.at);
        rooms.hover = null;
        const view = rooms.current();
        if (rooms.phase == .settled) {
            for (view.exits, 0..) |exit, place| {
                if (views.views[exit].hotspot.holds(rooms.pointer.at)) {
                    rooms.hover = @intCast(place);
                    break;
                }
            }
        }
        const pressed = (in.left and !rooms.left_held) or (in.right and !rooms.right_held) or in.keyboard.pressed(@intFromEnum(input.Key.space), .none, true);
        const taken = if (pressed) rooms.hover else null;
        if (taken) |place| {
            if (!rooms.take(view.exits[place], in)) return null;
        } else if (in.right) rooms.skip();
        if (!in.right) rooms.right_held = false;
        if (!in.left) rooms.left_held = false;

        const tick = timer_rate * (in.now -| rooms.opened_at) / std.time.ns_per_s + 1;
        if (rooms.seen < tick) {
            rooms.seen = tick;
            rooms.pointer.tick();
        }
        return null;
    }

    /// The view arrived in settles (`0x0043AF4C` on): its loop from its first frame, or the fish
    /// tank's first movie, else the way in's last frame stays.
    fn settle(rooms: *Rooms, now: u64) void {
        const view = rooms.current();
        if (view.loop) |loop| {
            rooms.enter(loop, now, true);
            rooms.film.loops = true;
        } else if (view.action == .fish_tank) {
            rooms.fish.movie = 0;
            rooms.enterFish(now);
        }
        rooms.phase = .settled;
        rooms.arrived = false;
    }

    fn enterFish(rooms: *Rooms, now: u64) void {
        rooms.enter(Fish.movies[rooms.fish.movie], now, true);
        rooms.film.loops = true;
    }

    /// The fish tank's food, while the view is the tank's and no food falls (`0x0043B1E5` on):
    /// the pointer on it, and a press drops it.
    fn food(rooms: *Rooms, in: Input) void {
        const view = rooms.current();
        if (view.loop != null or rooms.fish.feeding != null or view.action != .fish_tank) return;
        rooms.fish.over_food = Fish.food_hotspot.holds(rooms.pointer.at);
        if (!rooms.fish.over_food or !in.left) return;
        rooms.fish.over_food = false;
        rooms.fish.feeding = 0;
        rooms.fish.fed_at = in.ticks;
        if (rooms.fish.shapes == null) rooms.fish.shapes = rooms.context.readShapes(Fish.food);
    }

    /// The exit `exit` taken (`0x0043B40C` on): its way in's sound where it has one, then its way
    /// in, or at once its action where it has none, the loop then starting over. The pointer's
    /// right button, or the left with the transitions off, skips the way in. Whether the pass goes
    /// on.
    fn take(rooms: *Rooms, exit: u8, in: Input) bool {
        const next = views.views[exit];
        if (next.sound) |sound| if (!in.right or (in.left and !in.transitions)) {
            if (rooms.hum) |hum| _ = rooms.context.sound.playInScene(hum.bank, sound, hog_snd.loudest, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
        };
        rooms.view = exit;
        const way = next.movie orelse {
            rooms.arrived = true;
            rooms.phase = .way_in;
            return false;
        };
        rooms.crew.take(rooms.context.sound, way);
        rooms.enter(way, in.now, false);
        rooms.arrived = false;
        rooms.hover = null;
        rooms.phase = .way_in;
        if (in.right or (in.left and !rooms.left_held and !in.transitions)) rooms.skip();
        rooms.fish.over_food = false;
        rooms.fish.feeding = null;
        return true;
    }

    /// The way in skipped (`0x0043B7D6` on): to its last frame, the view's action next where it
    /// has one, or its loop.
    fn skip(rooms: *Rooms) void {
        rooms.left_held = true;
        rooms.right_held = true;
        const view = rooms.current();
        if (view.loop != null) {
            rooms.arrived = true;
            return;
        }
        if (view.action != .none) rooms.arrived = true;
        if (view.action != .cd_player) {
            rooms.skipping = true;
            rooms.jump = true;
        }
    }

    /// The skip's jump, the pass after the pointer showed it: the way in's last frame shown.
    fn jumpToEnd(rooms: *Rooms, now: u64) void {
        rooms.jump = false;
        rooms.skipping = false;
        rooms.film.jumpToEnd(now);
    }

    /// What the rooms do as the player goes into a place's screen (`0x0043A48C` on).
    fn before(rooms: *Rooms, place: Place, ticks: u32) void {
        const sound = rooms.context.sound;
        rooms.film.close();
        switch (place) {
            .news => {
                sound.endAll();
                rooms.hum_voice = null;
                sound.fadeMusic(music_fade_step, ticks);
                rooms.playStep(.news_before);
            },
            .itac => sound.fadeMusic(music_fade_step, ticks),
            .simulator => {
                sound.fadeMusic(music_fade_step, ticks);
                rooms.playStep(.simulator_before);
            },
            .locker => rooms.playStep(.locker_before),
            .cd_player => {},
        }
    }

    /// Back from the screen of `place` into the rooms, at `now`: the view it leaves the player in,
    /// its way in next.
    pub fn leave(rooms: *Rooms, place: Place, now: u64) void {
        switch (place) {
            .news => {
                rooms.playHum();
                rooms.playStep(.news_after);
            },
            .itac => rooms.playHum(),
            .simulator => {
                // The pod ended every sound as it closed, the hum among them.
                rooms.hum_voice = null;
                rooms.playStep(.simulator_after);
            },
            .locker => rooms.playStep(.locker_after),
            .cd_player => {},
        }
        rooms.view = rooms.carrier.after(place);
        rooms.enter(rooms.current().movie, now, place == .cd_player);
        rooms.arrived = false;
    }

    /// Back to the rooms' first view, before mission `mission`, as a saved game loads from the
    /// in-game options (`0x0043A34D` on).
    pub fn restart(rooms: *Rooms, mission: u16, now: u64) void {
        rooms.mission = mission;
        rooms.carrier = .of(mission);
        rooms.view = rooms.carrier.start();
        rooms.enter(rooms.current().movie, now, false);
        rooms.arrived = false;
        rooms.phase = .way_in;
        // The crew picked again for the game loaded (`0x0043A309` on).
        rooms.crew.deinit(rooms.context.gpa);
        rooms.pickCrew(now);
    }

    /// `news_report` (`0x0043BA40`), at `now`: the mission's report, its first part over the
    /// television's movie. False where it has none.
    ///
    /// **Fix:** outside the missions of the table of reports, the game reads what lies either side
    /// of it for the report's name. OpenReliant has no report there.
    fn startNews(rooms: *Rooms, now: u64) bool {
        const mission = rooms.mission;
        if (mission == 0 or mission > News.scenes.len) {
            log.warn("mission {d} has no news report", .{mission});
            return false;
        }
        rooms.news = .{ .part = if (mission == 1) 1 else 0 };
        const television = switch (rooms.carrier) {
            .reliant => News.reliant_television,
            .yamato => News.yamato_television,
        };
        rooms.report(.{ .movie = television, .scene = News.scenes[mission - 1] }, now);
        return true;
    }

    /// A part of the news report: its movie, looping, its first frame shown, and its scene spoken.
    fn report(rooms: *Rooms, part: News.Part, now: u64) void {
        rooms.enter(part.movie, now, true);
        rooms.film.loops = true;
        rooms.phase = .settled;
        speak(rooms.context, &rooms.speech, part.scene);
    }

    /// A pass of the news report's loop (`0x0043BD91` on), `in` read: whether it plays on. Escape
    /// or a button ends it; as its speech ends, mission 1's next part, or the end.
    fn newsPass(rooms: *Rooms, in: Input) bool {
        const news = &(rooms.news orelse return false);
        rooms.pointer.at = in.at;
        if (in.keyboard.pressed(input.scan.escape, .none, true) or in.left or in.right) {
            rooms.endNews();
            return false;
        }
        if (rooms.speech.playing(rooms.context.sound)) return true;
        switch (news.part) {
            1 => {
                news.part = 2;
                rooms.report(News.second, in.now);
            },
            2 => {
                news.part = 0;
                rooms.report(News.last, in.now);
            },
            else => {
                rooms.endNews();
                return false;
            },
        }
        return true;
    }

    /// The news report ended (`0x0043C167` on): its speech stopped, its movie closed, and the
    /// rooms back on a way in.
    fn endNews(rooms: *Rooms) void {
        rooms.speech.stop(rooms.context.gpa, rooms.context.sound);
        rooms.film.close();
        rooms.news = null;
        rooms.phase = .way_in;
    }

    /// `vr_draw`'s movie (`0x0043C1E6` on), at `now`: the frame due shown; at the last, the loop
    /// back to its second frame, or the fish tank's next movie, and at the way in's, the view
    /// arrived in, as it is at once where the way in has no movie or the skip took it to its last
    /// frame.
    pub fn advance(rooms: *Rooms, now: u64) void {
        if (rooms.film.player == null or rooms.film.still) {
            if (rooms.phase == .way_in and !rooms.arrived and !rooms.jump) rooms.arrived = true;
            return;
        }
        if (!rooms.film.advance(now)) return;
        if (rooms.phase == .way_in) {
            rooms.arrived = true;
            rooms.film.still = true;
        } else if (rooms.current().action == .fish_tank and rooms.current().loop == null) {
            rooms.fish.movie = if (rooms.fish.movie < Fish.movies.len - 1) rooms.fish.movie + 1 else 0;
            rooms.enterFish(now);
        } else if (rooms.film.loops) {
            rooms.film.loopBack(now);
        } else rooms.film.still = true;
    }

    /// `vr_draw` (`0x0043C1C0`): the movie, the label of the exit under the pointer, the fish's
    /// food, and the pointer, at `ticks`.
    ///
    /// **Fix:** the game moves the food on by the ticks from the pass's start to the drawing, just
    /// after the pass takes them up, so that it falls only as the drawing takes time, and hardly at
    /// all on a fast machine. OpenReliant moves it on by the ticks since it last moved.
    pub fn draw(rooms: *Rooms, target: canvas.Canvas, ticks: u32) canvas.Error!void {
        rooms.film.draw(target);
        if (rooms.news == null) if (rooms.film.frame()) |frame| try rooms.crew.draw(target, frame);
        const label: ?u32 = if (rooms.news != null)
            News.label
        else if (rooms.hover) |place|
            views.views[rooms.current().exits[place]].label
        else if (rooms.fish.over_food) Fish.food_label else null;
        if (label) |id| try target.label(id);
        try rooms.drawFood(target, ticks);
        try rooms.drawPointer(target);
    }

    fn drawFood(rooms: *Rooms, target: canvas.Canvas, ticks: u32) canvas.Error!void {
        const fed = rooms.fish.feeding orelse return;
        if (rooms.fish.shapes) |*shapes| {
            try target.shape(&shapes.art, fed + Fish.first_falling, Fish.falling_at);
            try target.shape(&shapes.art, Fish.front_shape, Fish.front_at);
        }
        const moved = fed + (ticks -% rooms.fish.fed_at);
        rooms.fish.fed_at = ticks;
        rooms.fish.feeding = if (moved > Fish.falling_ticks) null else moved;
    }

    fn drawPointer(rooms: *Rooms, target: canvas.Canvas) canvas.Error!void {
        const shapes = if (rooms.shapes) |*loaded| &loaded.art else return;
        const pointer = rooms.pointer;
        const skip_at: [2]i32 = .{ pointer.at[0] + Pointer.skip_offset, pointer.at[1] };
        if (rooms.phase == .way_in) {
            if (rooms.skipping) try target.shape(shapes, Pointer.skip_shape, skip_at);
            return;
        }
        if (rooms.skipping) {
            try target.shape(shapes, Pointer.skip_shape, skip_at);
        } else try target.shape(shapes, @as(usize, pointer.shape) + 1, pointer.at);
        const place = rooms.hover orelse return;
        const exit = views.views[rooms.current().exits[place]];
        if (exit.action.lights() and pointer.shape == Pointer.straight) {
            try target.shape(shapes, @as(usize, pointer.frame) + Pointer.light_shapes, pointer.at);
        }
        switch (pointer.shape) {
            Pointer.left => try target.shape(shapes, @as(usize, pointer.frame) + Pointer.left_shapes, pointer.at),
            Pointer.right => try target.shape(shapes, @as(usize, pointer.frame) + Pointer.right_shapes, pointer.at),
            else => {},
        }
    }
};

test {
    _ = crew;
    _ = views;
}

test "the views lead to views of the table" {
    for (views.views) |view| {
        for (view.exits) |exit| try std.testing.expect(exit < views.views.len);
        try std.testing.expect(view.exits.len <= View.max_exits);
    }
    try std.testing.expectEqualStrings("rel_ladd_bunk.bik", views.views[entryView(.reliant_start)].movie.?);
    try std.testing.expectEqualStrings("rel_doorloop.bik", views.views[entryView(.reliant_start)].loop.?);
    try std.testing.expectEqual(.reliant, Carrier.of(18));
    try std.testing.expectEqual(.yamato, Carrier.of(19));
}

test Pointer {
    var pointer: Pointer = .{};
    pointer.place(.{ 0, 470 });
    try std.testing.expectEqual([2]i32{ 4, 439 }, pointer.at);
    // At the left edge it turns, two shapes a tick, into the arrow, as its animation goes round.
    for (0..6) |_| pointer.tick();
    try std.testing.expectEqual(Pointer.left, pointer.shape);
    try std.testing.expectEqual(6, pointer.frame);
    pointer.place(.{ 600, 100 });
    for (0..3) |_| pointer.tick();
    try std.testing.expectEqual(0, pointer.frame);
    try std.testing.expectEqual(6, pointer.shape);
    for (0..10) |_| pointer.tick();
    try std.testing.expectEqual(Pointer.right, pointer.shape);
}

test Voice {
    // From a screen as the radio's voices, in person in the room; dry where the style's lines are.
    try std.testing.expectEqual(.cabin, Voice.screen.room(.cabin));
    try std.testing.expectEqual(.scene, Voice.in_person.room(.cabin));
    try std.testing.expectEqual(.dry, Voice.screen.room(.dry));
    try std.testing.expectEqual(.dry, Voice.in_person.room(.dry));
}

test "the rooms' decls" {
    std.testing.refAllDecls(Rooms);
}

pub const testing = struct {
    /// What the rooms play and draw with in the tests: a disc whose archive holds the movies
    /// `names`, three frames each, and `others`, `resource.hog` with `resources`, and a mixer to
    /// play their sounds.
    pub const Tested = struct {
        tmp: std.testing.TmpDir,
        disc: disc_module.Disc,
        resources: bigfile.Hog,
        mixer: mss.Mixer,
        sound: hog_snd.Sound,
        decoders: bink.testing.Decoders = .{},

        const mss = @import("../../mss.zig");
        const container = @import("../../../formats/bink.zig");

        pub fn init(tested: *Tested, names: []const []const u8, others: []const hog.Member, resources: []const hog.Member) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            tested.tmp = std.testing.tmpDir(.{ .iterate = true });
            var buffers: [8][256]u8 = undefined;
            var members: [12]hog.Member = undefined;
            for (members[0..names.len], names, buffers[0..names.len]) |*member, name, *buffer| {
                member.* = .{ .name = name, .data = container.testing.movie(buffer, 3, &.{}) };
            }
            @memcpy(members[names.len..][0..others.len], others);
            try bigfile.testing.write(gpa, io, tested.tmp.dir, "CD2.HOG", members[0 .. names.len + others.len]);
            // The pointer's shapes, which don't parse, and so are left out, and `resources`.
            var resource_members: [12]hog.Member = undefined;
            resource_members[0] = .{ .name = "vrgfx.spr", .data = "x" };
            @memcpy(resource_members[1..][0..resources.len], resources);
            try bigfile.testing.write(gpa, io, tested.tmp.dir, bigfile.resource_name, resource_members[0 .. resources.len + 1]);
            tested.disc = .{ .gpa = gpa, .io = io, .directory = tested.tmp.dir };
            tested.disc.open(.two);
            tested.resources = try .open(gpa, io, tested.tmp.dir, bigfile.resource_name);
            tested.mixer = .init(22050);
            tested.sound.init(tested.mixer.driver(), 4, null);
            tested.decoders = .{};
        }

        pub fn deinit(tested: *Tested) void {
            tested.sound.closeMusic();
            tested.resources.close(std.testing.allocator);
            tested.disc.close();
            tested.tmp.cleanup();
        }

        pub fn context(tested: *Tested) Context {
            return .{ .gpa = std.testing.allocator, .codec = tested.decoders.codec(), .look = .{}, .disc = &tested.disc, .resources = &tested.resources, .sound = &tested.sound, .speech = .{} };
        }

        /// The music at `paths` in the game's folder, paths of the game's, each in `music\`, which
        /// the sound plays from.
        pub fn giveMusic(tested: *Tested, paths: []const []const u8) !void {
            const io = std.testing.io;
            try tested.tmp.dir.createDirPath(io, "music");
            for (paths) |path| {
                var buffer: [64]u8 = undefined;
                const sub_path = buffer[0..path.len];
                @memcpy(sub_path, path);
                std.mem.replaceScalar(u8, sub_path, '\\', '/');
                try tested.tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = hog_snd.testing.sound_file });
            }
            tested.sound.files = .{ .gpa = std.testing.allocator, .io = io, .dir = tested.tmp.dir };
        }
    };
};

/// A pass with the pointer at `at` and the buttons `left` and `right`, at frame `frame` of the
/// movies' rate.
fn passAt(rooms: *Rooms, keyboard: *input.Keyboard, at: [2]i32, left: bool, right: bool, frame: u64) ?Step {
    const now = frame * std.time.ns_per_s / 15;
    const step = rooms.pass(.{ .keyboard = keyboard, .at = at, .left = left, .right = right, .transitions = true, .now = now, .ticks = @intCast(frame * 100 / 15) });
    rooms.advance(now);
    return step;
}

test Rooms {
    var tested: testing.Tested = undefined;
    try tested.init(&.{ "rel_ladd_bunk.bik", "rel_doorloop.bik", "rel_t2itac.bik", "rel_itacloop.bik", "rel_bunkroom2briefing_door.bik", "single_rel_bunkroom2briefing_door.bik" }, &.{}, &.{});
    defer tested.deinit();
    var rooms: Rooms = .open(tested.context(), 1, Carrier.start(.reliant), 0);
    defer rooms.close();
    var keyboard: input.Keyboard = .{};
    // Their sounds ring in a room of the ship.
    try std.testing.expectEqual(.inside, tested.sound.surroundings);

    // The way in shows its first frame at once, and the view is arrived in at its last.
    try std.testing.expectEqual(1, tested.decoders.pictures);
    try std.testing.expectEqual(Phase.way_in, rooms.phase);
    var frame: u64 = 0;
    while (!rooms.arrived) : (frame += 1) try std.testing.expectEqual(null, passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame));
    // Arrived, it settles into its loop, which plays on from its second frame at its end.
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame);
    try std.testing.expectEqual(Phase.settled, rooms.phase);
    try std.testing.expect(rooms.film.loops);
    for (0..6) |_| {
        frame += 1;
        _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame);
    }
    try std.testing.expect(rooms.film.player != null and !rooms.film.still);

    // The pointer on the left edge rests on the way to the ITAC; a press takes it.
    frame += 1;
    _ = passAt(&rooms, &keyboard, .{ 10, 200 }, false, false, frame);
    try std.testing.expectEqual(0, rooms.hover.?);
    frame += 1;
    _ = passAt(&rooms, &keyboard, .{ 10, 200 }, true, false, frame);
    try std.testing.expectEqual(entryView(.reliant_start) + 2, rooms.view);
    try std.testing.expectEqual(Phase.way_in, rooms.phase);
    // The right button skips the way in, into the view's loop.
    frame += 1;
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, true, frame);
    try std.testing.expect(rooms.arrived);
    frame += 1;
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, true, frame);
    try std.testing.expectEqual(Phase.settled, rooms.phase);
    try std.testing.expectEqualStrings("rel_itacloop.bik", rooms.current().loop.?);

    // Escape opens the in-game options; the rooms start again from their first view.
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(Step.options, passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame).?);
    keyboard.down[input.scan.escape] = false;
    rooms.restart(1, frame * std.time.ns_per_s / 15);
    try std.testing.expectEqual(Carrier.start(.reliant), rooms.view);
    while (rooms.phase != .settled) : (frame += 1) _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame);

    // Through the briefing room's door, once its way in ends, the briefing.
    frame += 1;
    _ = passAt(&rooms, &keyboard, .{ 300, 250 }, true, false, frame);
    try std.testing.expectEqual(Action.briefing, rooms.current().action);
    var step: ?Step = null;
    while (step == null) : (frame += 1) step = passAt(&rooms, &keyboard, .{ 300, 250 }, false, false, frame);
    try std.testing.expectEqual(Step.briefing, step.?);
}

test "a skip into a view without a loop or an action settles on its last frame" {
    var tested: testing.Tested = undefined;
    try tested.init(&.{"lock_i2l.bik"}, &.{}, &.{});
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    const view = comptime viewAt(0x0050B438);
    var rooms: Rooms = .open(tested.context(), 19, view, 0);
    defer rooms.close();
    try std.testing.expectEqual(null, views.views[view].loop);
    // The right button skips the way in: the pointer shows the skip, then its last frame shows,
    // and the drawing after it arrives in the view, which then settles.
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, true, 0);
    try std.testing.expect(rooms.skipping and !rooms.arrived);
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, 1);
    try std.testing.expect(rooms.film.still and rooms.arrived);
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, 2);
    try std.testing.expectEqual(Phase.settled, rooms.phase);
    try std.testing.expect(rooms.film.player != null);
}

test "the news report" {
    const gpa = std.testing.allocator;
    var scenes: [3][]u8 = undefined;
    for (&scenes) |*scene| scene.* = try cbox.testFile(gpa, 100, 64);
    defer for (scenes) |scene| gpa.free(scene);
    var tested: testing.Tested = undefined;
    try tested.init(&.{ "rel_c_tv.bik", "rel_tv_in_loop.bik", "tv_cald.bik", "rel_tv_c.bik" }, &.{
        .{ .name = "0005a.box", .data = scenes[0] },
        .{ .name = "0005b.box", .data = scenes[1] },
        .{ .name = "0005c.box", .data = scenes[2] },
    }, &.{});
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var out: [512][2]f32 = undefined;

    // Into the television's view, the way in ends in mission 1's report, its first part spoken over
    // the television, and its label shown.
    const television = comptime viewAt(0x00506E00);
    var rooms: Rooms = .open(tested.context(), 1, television, 0);
    defer rooms.close();
    var frame: u64 = 0;
    while (rooms.news == null) : (frame += 1) try std.testing.expectEqual(null, passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame));
    try std.testing.expectEqual(1, rooms.news.?.part);
    try std.testing.expectEqual(Phase.settled, rooms.phase);
    try std.testing.expect(rooms.speech.playing(&tested.sound));
    // Each part plays on while its speech does, and the next follows it.
    for ([_]u8{ 2, 0 }) |part| {
        frame += 1;
        _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame);
        try std.testing.expect(rooms.film.player != null);
        tested.mixer.mix(&out);
        frame += 1;
        _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame);
        try std.testing.expectEqual(part, rooms.news.?.part);
        try std.testing.expect(rooms.speech.playing(&tested.sound));
    }
    // At the last's end, the rooms again, turned away from the television.
    tested.mixer.mix(&out);
    frame += 1;
    try std.testing.expectEqual(null, passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame));
    try std.testing.expectEqual(null, rooms.news);
    try std.testing.expectEqual(rooms.carrier.after(.news), rooms.view);
    try std.testing.expectEqual(Phase.way_in, rooms.phase);

    // A button ends it at once, as does Escape.
    rooms.view = television;
    rooms.phase = .way_in;
    rooms.arrived = true;
    frame += 1;
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame);
    try std.testing.expect(rooms.news != null);
    frame += 1;
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, true, false, frame);
    try std.testing.expectEqual(null, rooms.news);
    try std.testing.expect(!rooms.speech.playing(&tested.sound));

    // A mission outside the table has none, and the rooms go on.
    rooms.mission = 29;
    rooms.view = television;
    rooms.arrived = true;
    frame += 1;
    _ = passAt(&rooms, &keyboard, .{ 320, 200 }, false, false, frame);
    try std.testing.expectEqual(null, rooms.news);
    try std.testing.expectEqual(rooms.carrier.after(.news), rooms.view);
}
