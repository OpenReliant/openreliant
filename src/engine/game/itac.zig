//! `C:\lancer\game\itac.cpp`: the ITAC, the terminal Use ITAC opens in the Reliant's rooms and the
//! Yamato's, and which `WinMain` opens after each mission of the campaign for its debriefing
//! (`itac`, `0x0043EFC0`). It runs in a loop of its own, on a screen 640 by 480. Nine buttons along
//! its foot open its sections (`Section`), each with a movie in and a movie out, over which its
//! title and text fade, and a picture its text is written on; the last button closes it.
//!
//! Ported so far: the ITAC's loop, with its movies, its sections' pictures and titles, the fades of
//! their text, the panes their text wipes in by, the lit shapes, the pointer and the sounds; and
//! DEBRIEFINGS (`debriefing`). The other sections show their pictures with nothing written on them:
//! NEWS REPORTS ([#461](https://github.com/vdmkenny/openreliant/issues/461)), VIDEO REPORTS
//! ([#462](https://github.com/vdmkenny/openreliant/issues/462)), the fighters
//! ([#463](https://github.com/vdmkenny/openreliant/issues/463)), the capital ships
//! ([#464](https://github.com/vdmkenny/openreliant/issues/464)), the squadrons
//! ([#465](https://github.com/vdmkenny/openreliant/issues/465)) and the personnel
//! ([#466](https://github.com/vdmkenny/openreliant/issues/466)) of either side, and the KILLBOARD
//! ([#467](https://github.com/vdmkenny/openreliant/issues/467)). Not ported either: the buttons'
//! tooltips ([#468](https://github.com/vdmkenny/openreliant/issues/468)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("../input.zig");
const hud = @import("hud.zig");
const hog_snd = @import("hog_snd.zig");
const gameflow = @import("gameflow.zig");
const language = @import("language.zig");
const matmanager = @import("matmanager.zig");
const movie = @import("xtrabits/movie.zig");
const canvas_module = @import("interface/canvas.zig");
const rooms = @import("interface/rooms.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;
pub const debriefing = @import("itac/debriefing.zig");
pub const tables = @import("itac/tables.zig");

/// The module the ITAC's strings come from (`itac_language_init`, `0x00440770`): the game asks for
/// `itaclang.dll`; the disc's file is named in capitals, and Windows finds either.
pub const strings_name = "ITACLANG.DLL";

/// What the ITAC reads from `resource.hog` as it opens: its sounds (`0x0043F2F5`), its fonts
/// (`0x0043F3D3`, `0x0043F3EE`), and the shapes of its pointer and of what it lights
/// (`tooltips_init`, `0x00440B30`).
pub const sounds_name = "inter\\itac\\itacsnd.fat";
pub const large_font_name = "inter\\itac\\itacbig.fnt";
pub const small_font_name = "inter\\itac\\itacsml.fnt";
pub const shapes_name = "inter\\itac\\itacgfx.spr";

/// The movie the screen comes on with, and the picture it leaves (`0x0043F4D4`).
const coming_on = "inter\\itac\\itacinit.bik";
const coming_on_picture = "inter\\itac\\itactrans_00014.tga";

/// The movies the rooms open it with, the pilot's eye read on the Reliant, from the disc, and its
/// own on the Yamato (`0x0043F48B`, `0x0043F4AF`), and the one it closes with on the Yamato
/// (`0x0043FAA1`).
const eye_read = "itac_eye_recog.bik";
const opening = "inter\\itac\\itac open.bik";
const closing = "inter\\itac\\itaclose.bik";

/// The ITAC's sections, in the order of the buttons along its foot, the last of which closes it.
pub const Section = enum(u4) {
    debriefings,
    news_reports,
    video_reports,
    fighters,
    ships,
    squadrons,
    personnel,
    killboard,
    exit,

    /// The string of its title, which in the sections that show either side names the side
    /// (`itac_titles`, `0x004E9484`; `itac_titles_coalition`, `0x004E9498`).
    pub fn title(section: Section, side: Side) u16 {
        return switch (section) {
            .debriefings => 1,
            .news_reports => 2,
            .video_reports => 3,
            .fighters => if (side == .coalition) 4 else 0x5C,
            .ships => if (side == .coalition) 0x5D else 5,
            .squadrons => if (side == .coalition) 0x5E else 6,
            .personnel => if (side == .coalition) 0x5F else 7,
            .killboard => 8,
            .exit => 9,
        };
    }

    /// Whether it shows the Alliance's or the Coalition's, which it starts on the Alliance's as it
    /// opens (`0x00425910` and the others' first handlers).
    fn sided(section: Section) bool {
        return switch (section) {
            .fighters, .ships, .squadrons, .personnel => true,
            .debriefings, .news_reports, .video_reports, .killboard, .exit => false,
        };
    }

    /// Its bit in a lit shape's mask of sections.
    fn bit(section: Section) u32 {
        return @as(u32, 1) << @intFromEnum(section);
    }
};

/// Each section's button, 58 by 51 along the foot of the screen (`itac_buttons`, `0x004E9340`).
const buttons = std.EnumArray(Section, Rect).init(.{
    .debriefings = .{ .x = 12, .y = 422, .width = 58, .height = 51 },
    .news_reports = .{ .x = 81, .y = 422, .width = 58, .height = 51 },
    .video_reports = .{ .x = 151, .y = 422, .width = 58, .height = 51 },
    .fighters = .{ .x = 220, .y = 422, .width = 58, .height = 51 },
    .ships = .{ .x = 290, .y = 422, .width = 58, .height = 51 },
    .squadrons = .{ .x = 359, .y = 422, .width = 58, .height = 51 },
    .personnel = .{ .x = 429, .y = 422, .width = 58, .height = 51 },
    .killboard = .{ .x = 499, .y = 422, .width = 58, .height = 51 },
    .exit = .{ .x = 570, .y = 422, .width = 58, .height = 51 },
});

/// A section's movies in and out and its picture, in `inter\itac\` (`itac_movies`, `0x004E9418`).
const Files = struct {
    in: []const u8,
    out: ?[]const u8,
    picture: ?[]const u8,
};

const section_files = std.EnumArray(Section, Files).init(.{
    .debriefings = .{ .in = "inter\\itac\\itacdeb.bik", .out = "inter\\itac\\itacdebf.bik", .picture = "inter\\itac\\itactrans_00030.tga" },
    .news_reports = .{ .in = "inter\\itac\\itacnew.bik", .out = "inter\\itac\\itacnewf.bik", .picture = "inter\\itac\\itactrans_00051.tga" },
    .video_reports = .{ .in = "inter\\itac\\itacmov.bik", .out = "inter\\itac\\itacmovf.bik", .picture = "inter\\itac\\itactrans_00072.tga" },
    .fighters = .{ .in = "inter\\itac\\itacss.bik", .out = "inter\\itac\\itacssf.bik", .picture = "inter\\itac\\itactrans_00093.tga" },
    .ships = .{ .in = "inter\\itac\\itaccs.bik", .out = "inter\\itac\\itaccsf.bik", .picture = "inter\\itac\\itactrans_00114.tga" },
    .squadrons = .{ .in = "inter\\itac\\itacsq.bik", .out = "inter\\itac\\itacsqf.bik", .picture = "inter\\itac\\itactrans_00135.tga" },
    .personnel = .{ .in = "inter\\itac\\itacpil.bik", .out = "inter\\itac\\itacpilf.bik", .picture = "inter\\itac\\itactrans_00156.tga" },
    .killboard = .{ .in = "inter\\itac\\itackil.bik", .out = "inter\\itac\\itackilf.bik", .picture = "inter\\itac\\itactrans_00177.tga" },
    .exit = .{ .in = "inter\\itac\\itacexit.bik", .out = null, .picture = null },
});

/// The side the fighters, the ships, the squadrons and the personnel show (`itac_side`,
/// `0x00523058`).
pub const Side = enum(u1) {
    alliance,
    coalition,
};

/// The sounds of `itacsnd.fat`.
pub const Sound = enum(u8) {
    /// Its hum, over and over while it is open.
    hum = 0,
    /// A button pressed.
    button = 1,
    /// Now and then, one or the other.
    now_and_then = 2,
    /// As it comes on.
    power = 3,
    /// The pilot's eye read, as the rooms open it.
    eye = 4,
    /// A section's text coming up.
    text = 5,
    /// As it closes.
    close = 6,
    now_and_then_other = 7,
    /// A side chosen, in the sections that show either.
    side = 8,
};

/// The volumes it plays its sounds at, from 0 to 127: the hum's, its coming on's and the sounds
/// now and then's, and the rest's.
const hum_volume = 0x40;
const low_volume = 0x50;
pub const full_volume = 0x7F;

/// When a sound plays now and then: the first between 500 and 700 game ticks after the hum starts,
/// each other between 500 and 1300 after the last (`0x0043F4F8`, `0x0043F66B`).
const now_and_then_after = 500;
const first_spread = 200;
const spread = 800;

/// How much the hum and the closing sound fade by, every five ticks, as it closes
/// (`sound_voice_fade`, `0x0043FA7C`, `0x0043FAB2`).
const close_fade_step = 10;

/// The ITAC's timer, 30 ticks a second (`itac_timer`, `0x0043FC60`), which the panes wipe in by,
/// and which paces the scrolling and the arrows' auto-repeat.
pub const timer_rate = 30;

/// The title: where it stands, left-aligned in the large font, and its colour (`0x0043FE9B`).
const title_at: [2]i32 = .{ 167, 22 };
const title_colour = hud.rgb(0xEC694D);

/// How far a section's title and text fade each frame of a movie, in over its movie in and out
/// over its movie out (`0x004DC5A0`, `0x004DC3F8`): its sixteen frames and its five.
const fade_in_step: f32 = 1.0 / 16.0;
const fade_out_step: f32 = 0.2;

/// The pointer's shapes in `itacgfx.spr`, from the first, one for every `pointer_ticks` game ticks
/// (`0x004404C1`); its ticks wrap as they reach `pointer_wrap`, or `movie_pointer_wrap` while a
/// movie plays (`0x0043F79E`, `0x004400F8`), and it is drawn with the palette of block
/// `pointer_palette`.
const first_pointer_shape = 2;
const pointer_ticks = 4;
const pointer_wrap = 0x54;
const movie_pointer_wrap = 0x40;
const pointer_palette = 1;

/// The palette the lit shapes are drawn with (`0x00440FAC`).
const lit_palette = 0x1E;

/// The string of "more", which `(%s)` writes where a box's text runs past it, right-aligned, in the
/// small font and the text's colour (`itac_more_draw`, `0x00441090`).
const more_string = 0x78C;
pub const text_colour = hud.rgb(0xFF923A);

/// How far a pane wipes in each tick of the ITAC's timer (`0x0043FFD4`).
const wipe_step = 14;

/// Who opens it.
pub const Run = enum {
    /// Use ITAC, in the rooms: the pilot's eye read or its own movie, then NEWS REPORTS.
    rooms,
    /// `WinMain`, after a mission of the campaign: DEBRIEFINGS at once, with REPLAY MISSION for
    /// the mission just flown (`itac_after_mission`, `0x00523088`; `itac_replay_offered`,
    /// `0x005D6094`).
    after_mission,
};

/// What the ITAC shows of the pilot and the campaign.
pub const Pilot = struct {
    call_sign: []const u8,
    /// `skull_count`: the kills over the campaign.
    kills: i32,
    rank: gameflow.Rank,
    tier: u2,
    campaign: *const gameflow.Campaign,
    /// `mission_number`: the mission the campaign has come to, the next to fly.
    mission: u16,
};

/// What the ITAC reads and plays with: the rooms', its own strings (`ITACLANG.DLL`,
/// `itac_language_init`, `0x00440770`) and the game's.
pub const Context = struct {
    rooms: rooms.Context,
    strings: *const language.Language,
    language: *const language.Language,
};

/// A pass's input.
pub const Input = struct {
    keyboard: *input.Keyboard,
    pointer: canvas_module.Pointer,
    /// The time in nanoseconds, and the game's ticks.
    now: u64,
    ticks: u32,
};

/// What a pass asks of the loop.
pub const Step = union(enum) {
    /// A movie to play in a loop of its own before the next pass.
    play: movie.Named,
    /// Nothing drawn this pass: the screen holds, as the game's does while its closing sound fades
    /// (`0x0043FB21`).
    hold,
    /// It has closed.
    closed,
    /// REPLAY MISSION: the mission just flown again, from its briefing (`replay_briefing`,
    /// `0x00520840`).
    replay,
};

/// A pane a section's text is written into (`itac_pane_records`, `0x00520330`), which shows once
/// the text is in, wiping in from the left.
pub const Pane = struct {
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    shown: bool = false,
    /// The wipes still running: each ends as the width shown reaches the pane's.
    wiping: u8 = 0,
    /// How much of its width shows while it wipes.
    revealed: i16 = 0,

    /// Its text written into it at `rect`, wiping in from nothing.
    pub fn wipeIn(pane: *Pane, rect: Rect) void {
        pane.rect = rect;
        pane.shown = true;
        pane.wiping +|= 1;
        pane.revealed = 0;
    }

    /// Where it shows: the part wiped in so far (`itac_panes_draw`, `0x0043FF50`).
    pub fn showing(pane: Pane) ?Rect {
        if (!pane.shown) return null;
        var shown = pane.rect;
        if (pane.wiping != 0) shown.width = @min(pane.revealed, pane.rect.width);
        return shown;
    }

    /// A tick of the ITAC's timer: a wipe a step on, and ended as it reaches the pane's width.
    fn tick(pane: *Pane) void {
        if (!pane.shown or pane.wiping == 0) return;
        pane.revealed +|= wipe_step;
        if (pane.revealed >= pane.rect.width) pane.wiping -= 1;
    }
};

/// The panes a section writes into.
pub const Panes = [4]Pane;

/// A box of text a section scrolls, with its two arrows, and "(more)" at its foot while its text
/// runs past it (`0x24` bytes; the debriefing's `debrief_box`, `0x0051D2E8`).
pub const ScrollBox = struct {
    /// Its arrows: the first scrolls the text on, the second back.
    arrows: [2]Rect,
    /// Where it stands on the screen, and its size.
    rect: Rect,
    /// How far its text is scrolled, from -1 at its top down to `least` (`+0x14`).
    scroll: f32 = top,
    /// The steps of a scroll under way, counted its way from 1 to 5 (`+0x18`); 0 for none.
    steps: i32 = 0,
    /// The furthest its text scrolls (`itac_scroll_least`, `0x005231C8`).
    least: f32 = top,
    /// The timer's tick it last moved on (`itac_scroll_tick`, `0x00523070`).
    last_tick: u32 = 0,

    /// Its scroll at the top of its text.
    pub const top: f32 = -1;
    /// How far a step moves it (`0x004DC3D8`), five of which make a line.
    const step: f32 = 3;
    const steps_to_a_line = 5;
    /// The lines its text breaks into: width less `margin`, `line_height` apart, at most
    /// `most_lines` (`itac_scroll_text_draw`, `0x00440920`).
    const margin = 5;
    pub const line_height = 15;
    pub const most_lines = 50;

    /// How its text breaks into lines.
    pub fn lines(box: ScrollBox) Canvas.Lines {
        return .{ .width = box.rect.width - margin, .height = line_height, .most = most_lines };
    }

    /// `itac_scroll_text_draw` (`0x00440920`), as its text breaks into `count` lines: how far it
    /// can scroll. Where the lines fit, a little way on all the same.
    pub fn reach(box: *ScrollBox, count: usize) void {
        const height: i32 = box.rect.height;
        const least = height - 1 - line_height * @as(i32, @intCast(count)) - @rem(height, line_height);
        box.least = @floatFromInt(if (least >= 0) -2 else least);
    }

    /// Whether its text runs past it, which "(more)" marks, the pane it wipes into at rest.
    pub fn more(box: ScrollBox, wiping: bool) bool {
        return !wiping and box.least < box.scroll;
    }

    /// `itac_scroll_text_update` (`0x004409F0`), the timer at `tick`: on each tick, a scroll under
    /// way a step on, and the scroll kept to its text. With none under way, the left button down
    /// over an arrow starts one.
    pub fn update(box: *ScrollBox, tick: u32, pointer: canvas_module.Pointer) void {
        if (tick != box.last_tick) {
            if (box.steps == 0 or box.steps > steps_to_a_line or box.steps < -steps_to_a_line) {
                box.steps = 0;
            } else {
                const way: f32 = if (box.steps < 0) -1 else 1;
                box.scroll += way * step;
                box.steps += if (box.steps < 0) -1 else 1;
            }
            box.keep();
            box.last_tick = tick;
        }
        if (box.steps == 0 and pointer.down) if (canvas_module.hit(&box.arrows, pointer.at)) |arrow| {
            box.steps = if (arrow == 0) -1 else 1;
            box.keep();
        };
    }

    /// The scroll kept between the top of its text and `least`.
    fn keep(box: *ScrollBox) void {
        if (box.scroll > top) {
            box.scroll = top;
        } else if (box.scroll < box.least) {
            box.scroll = box.least;
        }
    }
};

/// The auto-repeat of the arrows that step through a list (`itac_repeat`, `0x00441060`): true as
/// the left button goes down, then while it is held, on the timer's fourth tick and every fifth
/// after it.
pub const Repeat = struct {
    /// The timer's ticks since the press (`itac_repeat_ticks`, `0x005207E0`), and their count
    /// round five (`itac_repeat_phase`, `0x00520328`).
    ticks: u32 = 0,
    phase: u32 = 0,

    const every = 5;

    /// A tick of the ITAC's timer.
    fn tick(repeat: *Repeat) void {
        repeat.ticks +%= 1;
        repeat.phase = repeat.ticks % every;
    }

    /// Whether a press held, where `held` it was down on the last pass too, repeats this pass.
    pub fn fires(repeat: *Repeat, held: bool) bool {
        if (!held) {
            repeat.ticks = 1;
            return true;
        }
        const phase = repeat.phase;
        repeat.phase +%= 1;
        return phase == 0;
    }
};

/// What the loop does.
const Stage = union(enum) {
    /// As it opens: from the rooms, its sound and the pilot's eye read or its own movie.
    start,
    /// Its coming-on sound and movie.
    power,
    /// `itacinit.bik`, the screen coming on.
    coming_on,
    /// A section's movie in, the section's title and text fading in over it; the section
    /// loaded before it where `loaded`.
    entering: struct { section: Section, loaded: bool = false },
    /// The section shown.
    shown,
    /// The shown section's movie out, its title and text fading out over it, on the way to
    /// another's movie in.
    leaving: Section,
    /// Closing: the hum fading, its closing sound, and on the Yamato its movie out.
    closing,
    /// Its closing sound set fading, after its movie out.
    closed_movie,
    /// Its closing sound fading, the screen held.
    fading_out,
    closed,
};

/// How a section's text fades over its movies.
const Fade = enum { none, in, out };

pub const Itac = struct {
    context: Context,
    run: Run,
    pilot: Pilot,
    /// Its fonts, shapes and sounds.
    large: ?hud.FontFile = null,
    small: ?hud.FontFile = null,
    shapes: ?canvas_module.Shapes = null,
    sounds: ?hog_snd.BankFile = null,
    /// The shown section's picture, which its text is written on.
    picture: matmanager.Background = .{},
    /// The movie playing in the loop.
    film: rooms.Film = .{},
    stage: Stage = .start,
    section: ?Section = null,
    side: Side = .coalition,
    /// The fade of the section's title and text over its movies (`itac_fade`, `0x0052082C`;
    /// `itac_fade_state`, `0x00520324`).
    fade: f32 = 0,
    fading: Fade = .none,
    /// Whether the pointer is left out and the section left alone, over a movie in
    /// (`itac_frozen`, `0x0052308C`).
    frozen: bool = false,
    panes: Panes = @splat(.{}),
    /// The ITAC's timer: when it started, its ticks, and the tick the panes last wiped at
    /// (`itac_ticks`, `0x005231C0`; `itac_wipe_tick`, `0x0052307C`).
    started: u64 = 0,
    ticks: u32 = 1,
    wipe_tick: u32 = 0,
    repeat: Repeat = .{},
    /// The left button, down this pass and down on the last (`0x00520138`, `0x00520820`).
    left: bool = false,
    left_held: bool = false,
    /// The pointer as the pass read it, and its animation's ticks.
    pointer: canvas_module.Pointer = .{},
    pointer_clock: canvas_module.PointerClock = .{},
    hum: ?u8 = null,
    close_voice: ?u8 = null,
    /// The game tick the next sound now and then is due at.
    now_and_then_due: u32 = 0,
    random: std.Random.DefaultPrng,
    /// DEBRIEFINGS.
    debriefings: debriefing.Debriefing = .{},
    /// REPLAY MISSION chosen (`replay_briefing`, `0x00520840`).
    replay: bool = false,

    /// Opens it for `run`, at `now` and the game's `ticks`, with its fonts, shapes and sounds from
    /// `resource.hog`; what is missing is left out, which the log says.
    pub fn open(context: Context, run: Run, pilot: Pilot, now: u64, ticks: u32) Itac {
        const gpa = context.rooms.gpa;
        const resources = context.rooms.resources;
        var itac: Itac = .{
            .context = context,
            .run = run,
            .pilot = pilot,
            .started = now,
            .pointer_clock = .{ .last = ticks },
            .random = .init(now),
        };
        itac.large = .read(gpa, resources.*, large_font_name, context.rooms.outlines);
        itac.small = .read(gpa, resources.*, small_font_name, context.rooms.outlines);
        itac.shapes = .read(gpa, resources, shapes_name);
        itac.sounds = .read(gpa, resources, sounds_name);
        return itac;
    }

    /// Lets go of what it read.
    pub fn deinit(itac: *Itac) void {
        const gpa = itac.context.rooms.gpa;
        itac.film.close();
        itac.picture.deinit(gpa);
        if (itac.large) |*font| font.deinit(gpa);
        if (itac.small) |*font| font.deinit(gpa);
        if (itac.shapes) |*shapes| shapes.deinit(gpa);
        if (itac.sounds) |file| file.deinit(gpa);
        itac.* = undefined;
    }

    /// The ITAC's string `id` (`itac_string`, `0x00440910`); none past its strings.
    pub fn string(itac: Itac, id: u32) []const u8 {
        return itac.context.strings.string(id) orelse "";
    }

    /// A pass of its loop.
    pub fn pass(itac: *Itac, in: Input) ?Step {
        itac.timer(in.now);
        itac.left_held = itac.left and in.pointer.down;
        itac.left = in.pointer.down;
        itac.pointer = in.pointer;
        const escape = in.keyboard.pressed(input.scan.escape, .none, true);
        switch (itac.stage) {
            .start => {
                itac.stage = .power;
                if (itac.run == .rooms) {
                    itac.play(.eye, full_volume, 1);
                    return switch (rooms.Carrier.of(itac.pilot.mission)) {
                        .reliant => .{ .play = .{ .name = eye_read, .kind = .over_screen_from_disc } },
                        .yamato => .{ .play = .{ .name = opening, .kind = .over_screen } },
                    };
                }
                itac.powerOn(in.now);
            },
            .power => itac.powerOn(in.now),
            .coming_on => if (itac.filmPlayed(in, escape)) itac.cameOn(in),
            .entering => |entering| if (itac.filmPlayed(in, escape)) itac.entered(entering.section, entering.loaded),
            .leaving => |to| if (itac.filmPlayed(in, escape)) itac.openNext(to, in.now),
            .shown => {
                if (itac.replay) {
                    itac.stage = .closed;
                    return .replay;
                }
                if (escape) return itac.close();
                itac.nowAndThen(in.ticks);
                if (itac.left) if (canvas_module.itemAt(Section, &buttons, in.pointer.at)) |section| if (section != itac.section) itac.leave(section, in.now);
                itac.pointer_clock.advance(in.ticks, pointer_wrap);
                if (itac.stage == .shown) {
                    itac.wipePanes();
                    itac.update();
                }
            },
            .closing => return itac.close(),
            .closed_movie => {
                if (itac.close_voice) |voice| itac.context.rooms.sound.fadeVoice(voice, close_fade_step);
                itac.stage = .fading_out;
                return .hold;
            },
            .fading_out => {
                if (itac.close_voice) |voice| if (itac.context.rooms.sound.voicePlaying(voice)) return .hold;
                itac.stage = .closed;
                return .closed;
            },
            .closed => return .closed,
        }
        return null;
    }

    /// Its coming-on sound, and the screen coming on (`0x0043F4C8`).
    fn powerOn(itac: *Itac, now: u64) void {
        itac.play(.power, low_volume, 1);
        itac.startFilm(coming_on, now);
        itac.stage = .coming_on;
    }

    /// The ITAC's timer run on to `now`: each tick wipes the panes on, and moves the auto-repeat
    /// on (`0x0043FC60`).
    fn timer(itac: *Itac, now: u64) void {
        const elapsed = (now -| itac.started) * timer_rate / std.time.ns_per_s;
        const ticks: u32 = @intCast(@min(elapsed + 1, std.math.maxInt(u32)));
        while (itac.ticks < ticks) {
            itac.ticks += 1;
            itac.repeat.tick();
        }
    }

    /// Plays `sound` of its bank at `volume`, `loops` times (0 for ever), from the middle.
    pub fn play(itac: *Itac, sound: Sound, volume: i32, loops: u32) void {
        _ = itac.playVoice(sound, volume, loops);
    }

    fn playVoice(itac: *Itac, sound: Sound, volume: i32, loops: u32) ?u8 {
        const bank = itac.sounds orelse return null;
        return itac.context.rooms.sound.play(bank.bank, @intFromEnum(sound), volume, loops, hog_snd.centre, hog_snd.own_pitch);
    }

    /// `itac_movie_play` (`0x00440010`): the movie `name` from the game's folder, its first frame
    /// shown at once.
    fn startFilm(itac: *Itac, name: []const u8, now: u64) void {
        itac.film.open(itac.context.rooms, name, .itac);
        itac.film.show(now);
    }

    /// The movie on a pass: its frame due shown, and the fade a step on each frame (`itac_movie_draw`,
    /// `0x004401F0`), the pointer's animation on. True once it has played to its end or Escape has
    /// ended it.
    ///
    /// **Fix:** the fade steps each frame of the movie, over which it is meant to run: sixteen in and
    /// five out. The game steps it each frame it draws, so that it runs faster the faster the
    /// machine, and a movie skipped leaves the section's text as dim as the fade had reached,
    /// which OpenReliant ends at full.
    fn filmPlayed(itac: *Itac, in: Input, escape: bool) bool {
        const before = itac.film.frame();
        const ended = itac.film.advance(in.now);
        if (itac.film.frame() != before) switch (itac.fading) {
            .none => {},
            .in => itac.fade = @min(itac.fade + fade_in_step, 1),
            .out => itac.fade = @max(itac.fade - fade_out_step, 0),
        };
        itac.pointer_clock.advance(in.ticks, movie_pointer_wrap);
        const done = ended or escape or itac.film.player == null;
        if (done) itac.film.close();
        return done;
    }

    /// The screen come on: its picture, its hum and the sounds now and then due, and the first
    /// section's movie in (`0x0043F4E0` on). From the rooms, NEWS REPORTS, opened before its movie;
    /// after a mission, DEBRIEFINGS.
    ///
    /// **Fix:** after a mission the game opens DEBRIEFINGS after its movie in, so that the figures
    /// fading in over the movie are those of whichever debriefing was chosen last, if any.
    /// OpenReliant opens it before, as the rooms' run opens NEWS REPORTS.
    fn cameOn(itac: *Itac, in: Input) void {
        itac.setPicture(coming_on_picture);
        itac.left = false;
        itac.left_held = false;
        itac.hum = itac.playVoice(.hum, hum_volume, hog_snd.forever);
        const random = itac.random.random();
        itac.now_and_then_due = in.ticks + now_and_then_after + random.uintLessThan(u32, first_spread);
        const first: Section = switch (itac.run) {
            .rooms => .news_reports,
            .after_mission => .debriefings,
        };
        itac.enter(first);
        const loaded = itac.run == .rooms;
        if (loaded) itac.load(first);
        itac.section = first;
        itac.fading = .in;
        itac.fade = 0;
        itac.frozen = true;
        itac.startFilm(section_files.get(first).in, in.now);
        itac.stage = .{ .entering = .{ .section = first, .loaded = loaded } };
    }

    /// A section's movie in played: the section loaded, where it is not already, or the ITAC
    /// closing where it is the last button's (`0x0043F5BC`, `0x0043F8A9`).
    fn entered(itac: *Itac, section: Section, loaded: bool) void {
        itac.frozen = false;
        itac.fading = .none;
        itac.fade = 1;
        if (section == .exit) {
            itac.stage = .closing;
            return;
        }
        if (!loaded) itac.load(section);
        itac.stage = .shown;
    }

    /// A press on the button of `to`: its sound, the shown section's movie out with its title and
    /// text fading out over it, the pointer still shown (`0x0043F6DE` on).
    fn leave(itac: *Itac, to: Section, now: u64) void {
        itac.play(.button, full_volume, 1);
        const from = itac.section orelse return itac.openNext(to, now);
        itac.fading = .out;
        itac.fade = 1;
        if (section_files.get(from).out) |name| itac.startFilm(name, now);
        itac.stage = .{ .leaving = to };
    }

    /// The shown section's movie out played: it is left, and `to` opened, its movie in playing with
    /// its title and text fading in over it, the pointer left out (`0x0043F751` on). Of the
    /// sections' handlers for leaving them, DEBRIEFINGS' does nothing (`noop`), and the others are
    /// not ported.
    fn openNext(itac: *Itac, to: Section, now: u64) void {
        itac.section = to;
        if (to != .exit) itac.enter(to);
        itac.fading = .in;
        itac.fade = 0;
        itac.frozen = true;
        itac.startFilm(section_files.get(to).in, now);
        itac.stage = .{ .entering = .{ .section = to } };
    }

    /// A section's first handler, as it is opened (slot 0).
    fn enter(itac: *Itac, section: Section) void {
        if (section.sided()) itac.side = .alliance;
        switch (section) {
            .debriefings => itac.debriefings.enter(itac.pilot),
            .news_reports, .video_reports, .fighters, .ships, .squadrons, .personnel, .killboard, .exit => {},
        }
    }

    /// `itac_section_load` (`0x0043FCA0`): the section's picture, which its text is written on, its
    /// panes hidden, and its third handler, which builds them (slot 2).
    fn load(itac: *Itac, section: Section) void {
        if (section_files.get(section).picture) |name| itac.setPicture(name);
        for (&itac.panes) |*pane| pane.shown = false;
        switch (section) {
            .debriefings => itac.debriefings.loaded(itac),
            .news_reports, .video_reports, .fighters, .ships, .squadrons, .personnel, .killboard => itac.panes = @splat(.{}),
            .exit => {},
        }
    }

    /// The shown section's fourth handler, each pass while no fade runs (slot 3).
    fn update(itac: *Itac) void {
        const section = itac.section orelse return;
        switch (section) {
            .debriefings => itac.debriefings.update(itac),
            .news_reports, .video_reports, .fighters, .ships, .squadrons, .personnel, .killboard, .exit => {},
        }
    }

    fn setPicture(itac: *Itac, name: []const u8) void {
        itac.picture.show(itac.context.rooms.gpa, itac.context.rooms.resources.*, name);
    }

    /// A sound now and then, where one is due, and the next one's time (`0x0043F654`).
    ///
    /// **Improvement:** the times and the sound are drawn from `std.Random`, where the game uses
    /// `rand`.
    fn nowAndThen(itac: *Itac, ticks: u32) void {
        if (ticks <= itac.now_and_then_due) return;
        const random = itac.random.random();
        itac.now_and_then_due = ticks + now_and_then_after + random.uintLessThan(u32, spread);
        itac.play(if (random.boolean()) .now_and_then else .now_and_then_other, low_volume, 1);
    }

    /// Escape, or the last button's movie in played: the hum fading, the closing sound and on the
    /// Yamato the ITAC's movie out, then the sound fading, the screen held until it has
    /// (`0x0043FA70`, `0x0043FADB`). Escape leaves the shown section as it is, without its handler
    /// for leaving it.
    fn close(itac: *Itac) ?Step {
        itac.fading = .none;
        if (itac.hum) |voice| itac.context.rooms.sound.fadeVoice(voice, close_fade_step);
        itac.close_voice = itac.playVoice(.close, full_volume, 1);
        itac.stage = .closed_movie;
        return switch (rooms.Carrier.of(itac.pilot.mission)) {
            .reliant => null,
            .yamato => .{ .play = .{ .name = closing, .kind = .over_screen } },
        };
    }

    /// The pointer's frame.
    fn pointerShape(itac: Itac) usize {
        return first_pointer_shape + itac.pointer_clock.ticks / pointer_ticks;
    }

    /// The frame: the movie playing, with the title and text of the section it fades over, or the
    /// section's picture with its title, text and lit shapes; and the pointer, unless a section's
    /// movie in plays (`itac_movie_draw`, `0x004401F0`; `itac_draw`, `0x004403F0`).
    pub fn draw(itac: *Itac, canvas: Canvas) canvas_module.Error!void {
        const playing = itac.film.player != null;
        if (playing) {
            itac.film.draw(canvas);
            if (itac.fading != .none and itac.fade > 0) try itac.drawSection(canvas, itac.fade);
        } else {
            if (itac.picture.image) |*image| canvas.fill(image);
            if (itac.section != null) try itac.drawSection(canvas, itac.fade);
            if (!itac.frozen) try itac.drawLit(canvas);
        }
        if (!itac.frozen) try itac.drawPointer(canvas);
    }

    /// `itac_section_draw` (`0x0043FE90`): the section's title, and what its fifth handler draws, at
    /// `fade`.
    fn drawSection(itac: *Itac, canvas: Canvas, fade: f32) canvas_module.Error!void {
        const section = itac.section orelse return;
        if (itac.large) |*file| try canvas.text(&file.font, title_at, itac.string(section.title(itac.side)), title_colour, .left);
        switch (section) {
            .debriefings => try itac.debriefings.draw(itac, canvas, fade),
            .news_reports, .video_reports, .fighters, .ships, .squadrons, .personnel, .killboard, .exit => {},
        }
    }

    /// Whether the panes show: not while a fade runs (`0x0043FF52`).
    pub fn panesShow(itac: Itac) bool {
        return itac.fading == .none;
    }

    /// A tick of the timer seen by the panes: each wiping one a step on, once a pass
    /// (`0x0043FFC2`).
    fn wipePanes(itac: *Itac) void {
        if (!itac.panesShow() or itac.ticks == itac.wipe_tick) return;
        for (&itac.panes) |*pane| pane.tick();
        itac.wipe_tick = itac.ticks;
    }

    /// `itac_lit_draw` (`0x00440F90`): the shapes the shown section lights where the pointer is
    /// over them.
    fn drawLit(itac: *Itac, canvas: Canvas) canvas_module.Error!void {
        const section = itac.section orelse return;
        const shapes = &(itac.shapes orelse return);
        shapes.usePalette(lit_palette);
        for (tables.lit_shapes) |lit| {
            if (lit.sections & section.bit() == 0) continue;
            const found = shapes.art.shape(lit.shape) orelse continue;
            const at = itac.pointer.at;
            const inside = at[0] >= lit.at[0] and at[1] >= lit.at[1] and
                at[0] < lit.at[0] + found.header.width() and at[1] < lit.at[1] + found.header.height();
            if (inside) try canvas.shape(&shapes.art, lit.shape, .{ lit.at[0], lit.at[1] });
        }
    }

    /// `itac_more_draw` (`0x00441090`): "(more)" at the foot of a box whose text runs past it.
    pub fn drawMore(itac: *Itac, canvas: Canvas, box: ScrollBox) canvas_module.Error!void {
        const font = &(itac.small orelse return).font;
        var text: [32]u8 = undefined;
        const more = std.fmt.bufPrint(&text, "({s})", .{itac.string(more_string)}) catch return;
        try canvas.text(font, .{ box.rect.x + box.rect.width, box.rect.y + box.rect.height + more_below }, more, text_colour, .right);
    }

    /// How far below a box "(more)" stands (`0x004409A7`).
    const more_below = 5;

    fn drawPointer(itac: *Itac, canvas: Canvas) canvas_module.Error!void {
        const shapes = &(itac.shapes orelse return);
        shapes.usePalette(pointer_palette);
        try canvas.shape(&shapes.art, itac.pointerShape(), itac.pointer.at);
    }
};

test "Newtown stands in for the ITAC's fonts" {
    try std.testing.expect(hud.outline.standsIn(large_font_name) and hud.outline.standsIn(small_font_name));
}

test buttons {
    try std.testing.expectEqual(.debriefings, canvas_module.itemAt(Section, &buttons, .{ 40, 440 }).?);
    try std.testing.expectEqual(.exit, canvas_module.itemAt(Section, &buttons, .{ 600, 440 }).?);
    // The edges are left out.
    try std.testing.expectEqual(null, canvas_module.itemAt(Section, &buttons, .{ 12, 440 }));
    try std.testing.expectEqual(null, canvas_module.itemAt(Section, &buttons, .{ 300, 300 }));
}

test "Section.title" {
    try std.testing.expectEqual(1, Section.debriefings.title(.coalition));
    try std.testing.expectEqual(0x5C, Section.fighters.title(.alliance));
    try std.testing.expectEqual(4, Section.fighters.title(.coalition));
    try std.testing.expectEqual(5, Section.ships.title(.alliance));
    try std.testing.expectEqual(0x5D, Section.ships.title(.coalition));
}

test Pane {
    var pane: Pane = .{};
    try std.testing.expectEqual(null, pane.showing());
    pane.wipeIn(.{ .x = 30, .y = 82, .width = 30, .height = 34 });
    try std.testing.expectEqual(0, pane.showing().?.width);
    // Fourteen pixels a tick, until it is all shown.
    pane.tick();
    try std.testing.expectEqual(14, pane.showing().?.width);
    pane.tick();
    pane.tick();
    try std.testing.expectEqual(0, pane.wiping);
    try std.testing.expectEqual(30, pane.showing().?.width);
}

test ScrollBox {
    var box: ScrollBox = .{
        .arrows = .{ .{ .x = 219, .y = 321, .width = 27, .height = 27 }, .{ .x = 246, .y = 321, .width = 27, .height = 27 } },
        .rect = .{ .x = 30, .y = 117, .width = 400, .height = 191 },
    };
    // Ten lines fit; twenty run past the box, which can scroll 121 pixels.
    box.reach(10);
    try std.testing.expectEqual(-2, box.least);
    box.reach(20);
    try std.testing.expectEqual(-121, box.least);
    try std.testing.expect(box.more(false));
    try std.testing.expect(!box.more(true));
    // A press on the first arrow scrolls a line on over five ticks, three pixels a tick.
    box.update(0, .{ .at = .{ 230, 330 }, .down = true });
    try std.testing.expectEqual(-1, box.steps);
    for (1..6) |tick| box.update(@intCast(tick), .{});
    try std.testing.expectEqual(-16, box.scroll);
    box.update(6, .{});
    try std.testing.expectEqual(0, box.steps);
    // The second arrow scrolls back, no further than the top.
    box.update(6, .{ .at = .{ 250, 330 }, .down = true });
    for (7..20) |tick| box.update(@intCast(tick), .{});
    try std.testing.expectEqual(ScrollBox.top, box.scroll);
}

test Repeat {
    var repeat: Repeat = .{};
    // The press fires, then the fourth tick after it, then every fifth.
    try std.testing.expect(repeat.fires(false));
    var fired: [12]bool = undefined;
    for (&fired) |*one| {
        repeat.tick();
        one.* = repeat.fires(true);
    }
    try std.testing.expectEqual([12]bool{ false, false, false, true, false, false, false, false, true, false, false, false }, fired);
}

test Itac {
    // Its files are there but unreadable, and left out.
    var tested: rooms.testing.Tested = undefined;
    try tested.init(&.{}, &.{}, &.{
        .{ .name = "itacsnd.fat", .data = "x" },
        .{ .name = "itacbig.fnt", .data = "x" },
        .{ .name = "itacsml.fnt", .data = "x" },
        .{ .name = "itacgfx.spr", .data = "x" },
        .{ .name = "itactrans_00014.tga", .data = "x" },
        .{ .name = "itactrans_00030.tga", .data = "x" },
    });
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    const strings: language.Language = .{ .strings = &.{} };
    var campaign: gameflow.Campaign = .begin();
    campaign.records[0] = .{ .rating = .success };
    const pilot: Pilot = .{ .call_sign = "MAVERICK", .kills = 3, .rank = 0, .tier = 0, .campaign = &campaign, .mission = 2 };
    var itac: Itac = .open(.{ .rooms = tested.context(), .strings = &strings, .language = &strings }, .after_mission, pilot, 0, 0);
    defer itac.deinit();
    const pass = struct {
        var now: u64 = 0;
        fn with(terminal: *Itac, keys: *input.Keyboard, pointer: canvas_module.Pointer) ?Step {
            now += std.time.ns_per_s / timer_rate;
            return terminal.pass(.{ .keyboard = keys, .pointer = pointer, .now = now, .ticks = @intCast(now / (std.time.ns_per_s / 100)) });
        }
    }.with;
    // After a mission it comes on and opens DEBRIEFINGS, the latest chosen and its panes wiping in,
    // its movies left out here.
    for (0..4) |_| try std.testing.expectEqual(null, pass(&itac, &keyboard, .{}));
    try std.testing.expectEqual(.shown, std.meta.activeTag(itac.stage));
    try std.testing.expectEqual(.debriefings, itac.section.?);
    try std.testing.expectEqual(0, itac.debriefings.selected.?);
    try std.testing.expect(itac.panes[0].shown);
    // The last button closes it, through DEBRIEFINGS' movie out and its own movie in, then its
    // closing sound, which with no sound has faded at once.
    try std.testing.expectEqual(null, pass(&itac, &keyboard, .{ .at = .{ 600, 440 }, .down = true }));
    try std.testing.expectEqual(.leaving, std.meta.activeTag(itac.stage));
    for (0..3) |_| try std.testing.expectEqual(null, pass(&itac, &keyboard, .{}));
    try std.testing.expectEqual(.exit, itac.section.?);
    try std.testing.expectEqual(Step.hold, pass(&itac, &keyboard, .{}));
    try std.testing.expectEqual(Step.closed, pass(&itac, &keyboard, .{}));
}

test {
    _ = debriefing;
    _ = tables;
}
