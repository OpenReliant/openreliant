//! The Reliant's rooms as `openreliant` runs them (`game.interface.rooms`), with a new pilot's
//! induction before them (`game.interface.induction`), the in-game options over them
//! (`game.interface.in_game_options`) and the briefing after them (`game.interface.briefing`):
//! each in a loop of its own, as the game runs them, each frame drawn over an empty scene and put
//! on the window, with the window's messages read as the message pump reads them, and the movies
//! between them played by `Movies`. `campaign` is what `WinMain` does as START GAME starts a
//! campaign.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const srcore = engine.surrender.surrenderlib.srcore;
const game = engine.game;
const interface = game.interface;
const briefing = interface.briefing;
const canvas = interface.canvas;
const induction = interface.induction;
const in_game_options = interface.in_game_options;
const rooms = interface.rooms;
const Movies = @import("movies.zig").Movies;
const drawn = @import("presenter.zig").drawn;
const version = @import("version.zig");

const log = std.log.scoped(.rooms);

/// How the rooms end, where the game goes on: through the briefing room's door and the briefing,
/// the mission flown, or to the main menu.
pub const End = enum { fly, main_menu };

/// What the rooms run with.
pub const Driver = struct {
    movies: *Movies,
    sound: *game.hog_snd.Sound,
    clock: *game.main.Clock,
    /// `resource.hog`, the front end's fonts and dialog, and the strings.
    resources: *const game.bigfile.Hog,
    front: *engine.genilib.interf.Resources,
    strings: *const game.language.Language,
    /// How Enriquez's scenes and words sound: the radio's style.
    speech: game.cbox.Style,
    /// `speech_hog`, which holds Enriquez's words in the briefing; null where the game's folder
    /// has none.
    lines: ?*const openreliant.hog.Archive,
    /// The screenshots the briefing's O key saves.
    screenshots: *game.xtrabits.screenshot.Screenshots,
    /// The front end's pointer, which the rooms' follows, and the timer's count it last moved on
    /// at.
    pointer: canvas.Pointer = .{},
    ticks: u64 = 0,
    /// Whether the window is the active one.
    active: bool = true,

    /// What `WinMain` does as a single-player campaign starts, before mission `mission`
    /// (`winmain.CampaignStart`), then the rooms. Null where the game quits meanwhile.
    pub fn campaign(driver: *Driver, mission: u16) !?End {
        const start: game.winmain.CampaignStart = .of(mission);
        driver.startTimer();
        driver.sound.fadeMusic(game.winmain.music_fade_step, driver.clock.game_ticks);
        driver.movies.disc.open(start.disc);
        var view = rooms.Carrier.of(mission).start();
        if (start.induction) {
            _ = try driver.movies.play(game.winmain.new_intro, .cleared_from_disc) orelse return null;
            const place = try driver.induct() orelse return null;
            const after = induction.after(place);
            for (after.way) |name| _ = try driver.movies.play(name, .over_screen_from_disc) orelse return null;
            view = after.view;
        }
        return driver.visit(mission, view);
    }

    /// The developers' briefing of mission `mission`, from its loadout on
    /// (`briefing_from_loadout`), after which the front end starts again. False where the game
    /// quits meanwhile.
    pub fn loadoutBriefing(driver: *Driver, mission: u16) !bool {
        driver.startTimer();
        return driver.brief(mission, true);
    }

    /// The timer counted from now, as the loops step by it.
    fn startTimer(driver: *Driver) void {
        driver.clock.start(platform.window.ticks());
        driver.ticks = platform.window.ticks();
    }

    fn context(driver: *Driver) rooms.Context {
        const movies = driver.movies;
        return .{
            .gpa = movies.gpa,
            .codec = movies.codec,
            .look = movies.look,
            .disc = movies.disc,
            .resources = driver.resources,
            .sound = driver.sound,
            .speech = driver.speech,
            .lines = driver.lines,
        };
    }

    /// The induction (`reliant_induction`) in its loop, after its opening movies: the place it
    /// ended at, or null where the game quits meanwhile.
    fn induct(driver: *Driver) !?induction.Place {
        for (induction.opening) |name| _ = try driver.movies.play(name, .over_screen_from_disc) orelse return null;
        var tour: induction.Induction = .open(driver.context(), platform.window.nanoseconds());
        defer tour.close();
        while (true) {
            if (!try driver.pump()) return null;
            const now = platform.window.nanoseconds();
            if (tour.pass(.{ .keyboard = &driver.movies.devices.keyboard, .right = driver.pointer.right_down, .now = now })) |step| switch (step) {
                .way => |way| {
                    for (way) |name| _ = try driver.movies.play(name, .over_screen_from_disc) orelse return null;
                    if (tour.arrive(platform.window.nanoseconds())) |place| return place;
                },
                .over => |place| return place,
            };
            tour.advance(now);
            try driver.present(.{ .induction = &tour });
        }
    }

    /// The rooms (`vr_rooms`) before mission `mission`, from `view`, in their loop, and through
    /// the briefing room's door, the briefing, which `vr_rooms` runs once it has let the rooms go:
    /// how they end, or null where the game quits meanwhile.
    fn visit(driver: *Driver, mission: u16, view: u8) !?End {
        {
            var inside: rooms.Rooms = .open(driver.context(), mission, view, platform.window.nanoseconds());
            defer inside.close();
            while (true) {
                if (!try driver.pump()) return null;
                const now = platform.window.nanoseconds();
                const pointer = driver.pointer;
                if (inside.pass(.{
                    .keyboard = &driver.movies.devices.keyboard,
                    .at = pointer.at,
                    .left = pointer.down,
                    .right = pointer.right_down,
                    .transitions = driver.movies.transitions,
                    .now = now,
                    .ticks = driver.clock.game_ticks,
                })) |step| switch (step) {
                    .options => switch (try driver.options() orelse return null) {
                        .back => {},
                        .main_menu => return .main_menu,
                        .quit => return null,
                    },
                    // The places' screens are not ported yet (`rooms.Place`): the rooms go on as
                    // though each had closed at once.
                    .place => |place| {
                        log.info("the rooms' {s} is not ported yet", .{@tagName(place)});
                        inside.leave(place, platform.window.nanoseconds());
                    },
                    .briefing => break,
                };
                inside.advance(now);
                try driver.present(.{ .rooms = &inside });
            }
        }
        return if (try driver.brief(mission, false)) .fly else null;
    }

    /// The briefing (`interface_briefing`) before mission `mission`, in its loop, from the
    /// loadout where `from_loadout` has it: its door drawn for the frame it loads after, and the
    /// movies of its way in played as it comes to them. False where the game quits meanwhile.
    fn brief(driver: *Driver, mission: u16, from_loadout: bool) !bool {
        var meeting: briefing.Briefing = .open(driver.context(), mission, from_loadout);
        defer meeting.close();
        try driver.present(.{ .briefing = &meeting });
        while (true) {
            const active = driver.active;
            if (!try driver.pump()) return false;
            if (driver.active != active) meeting.pause(!driver.active, platform.window.nanoseconds());
            const step = meeting.pass(.{
                .keyboard = &driver.movies.devices.keyboard,
                .right = driver.pointer.right_down,
                .ticks = driver.clock.game_ticks,
            });
            // O saves the screen as it stands, before what the pass leads to.
            if (meeting.screenshot) driver.movies.presenter.screen.saveScreenshot(driver.movies.gpa, driver.screenshots);
            if (step) |next| switch (next) {
                .movie => |name| {
                    _ = try driver.movies.play(name, .over_screen_from_disc) orelse return false;
                    continue;
                },
                .over => return true,
            };
            meeting.advance(platform.window.nanoseconds(), driver.clock.game_ticks);
            try driver.present(.{ .briefing = &meeting });
        }
    }

    /// The in-game options in their loop, with what they draw with: where they lead, or null where
    /// the game quits meanwhile. MAIN MENU plays its movie first.
    fn options(driver: *Driver) !?in_game_options.Choice {
        const gpa = driver.movies.gpa;
        var menu: Menu = .{};
        defer menu.close(gpa);
        menu.background.set(gpa, driver.resources.*, in_game_options.background_name) catch |err|
            log.warn("{s} is left out: {s}", .{ in_game_options.background_name, @errorName(err) });
        menu.shapes = .read(gpa, driver.resources, in_game_options.shapes_name);
        menu.about_shapes = .read(gpa, driver.resources, in_game_options.about_shapes_name);
        while (true) {
            if (!try driver.pump()) return null;
            if (menu.state.frame(driver.pointer, &driver.movies.devices.keyboard)) |choice| {
                if (choice == .main_menu) _ = try driver.movies.play(in_game_options.to_main_menu, .over_screen) orelse return null;
                return choice;
            }
            try driver.present(.{ .options = &menu });
        }
    }

    /// The window's messages since the last pass, as the message pump reads them, the keyboard
    /// read, the pointer moved on, and the timer's ticks, which the fades step by; false where the
    /// window was closed, which quits the game (`game_exit`).
    fn pump(driver: *Driver) !bool {
        const movies = driver.movies;
        const devices = movies.devices;
        const pumped = movies.pump() orelse return false;
        if (pumped.active) |active| driver.activate(active);
        devices.keyboard.read();
        const ticks = platform.window.ticks();
        const elapsed = std.math.cast(i32, ticks -| driver.ticks) orelse std.math.maxInt(i32);
        driver.ticks = ticks;
        driver.pointer.update(devices.mouse, try movies.presenter.size(), elapsed);
        driver.clock.advanceTo(ticks);
        driver.sound.timerTick(driver.clock.game_ticks);
        return true;
    }

    /// The window going inactive or active again, as the message pump follows it
    /// (`winmain.followActivation`): while it is away, the music and the voices pause. The game's
    /// pump also waits for the window to come back; the rooms go on meanwhile.
    fn activate(driver: *Driver, active: bool) void {
        if (active == driver.active) return;
        driver.active = active;
        driver.sound.pauseMusic(!active);
        if (active) driver.sound.resumeAll() else driver.sound.pauseAll();
    }

    /// Draws a frame of `screen` and puts it on the window, at the frame rate asked for.
    fn present(driver: *Driver, screen: Shown.Screen) !void {
        const presenter = driver.movies.presenter;
        const pixels = try presenter.size();
        var shown: Shown = .{ .driver = driver, .window = pixels, .screen = screen };
        try presenter.present(pixels, shown.overlay());
        if (driver.movies.frame_rate) |rate| driver.movies.pacer.wait(rate);
    }

    fn canvasFor(driver: *Driver, window: [2]u32) canvas.Canvas {
        return .{
            .gpa = driver.movies.gpa,
            .target = driver.movies.presenter.screen.interface(),
            .window = window,
            .fonts = .{ .large = &driver.front.large, .small = &driver.front.small },
            .strings = driver.strings,
            .version = version.string,
        };
    }
};

/// The in-game options, and what they draw with: their background and shapes, and ABOUT
/// STARLANCER's.
const Menu = struct {
    state: in_game_options.InGameOptions = .{},
    background: game.matmanager.Background = .{},
    shapes: ?canvas.Shapes = null,
    about_shapes: ?canvas.Shapes = null,

    fn close(menu: *Menu, gpa: Allocator) void {
        menu.background.deinit(gpa);
        if (menu.shapes) |*shapes| shapes.deinit(gpa);
        if (menu.about_shapes) |*shapes| shapes.deinit(gpa);
    }

    fn draw(menu: *Menu, target: canvas.Canvas, dialog: *game.hud.Art, pointer: canvas.Pointer) canvas.Error!void {
        if (menu.background.image) |*shown| target.image(shown, .{ 0, 0 });
        const shapes = if (menu.shapes) |*loaded| &loaded.art else return;
        const about = if (menu.about_shapes) |*loaded| &loaded.art else null;
        try menu.state.draw(target, shapes, dialog, about, pointer);
    }
};

/// A frame's overlay: one of the screens, on the front end's screen fitted to the window.
const Shown = struct {
    driver: *Driver,
    window: [2]u32,
    screen: Screen,

    const Screen = union(enum) {
        induction: *induction.Induction,
        rooms: *rooms.Rooms,
        options: *Menu,
        briefing: *briefing.Briefing,
    };

    fn overlay(shown: *Shown) srcore.Overlay {
        return .{ .context = shown, .draw = draw };
    }

    fn draw(context: *anyopaque) Allocator.Error!void {
        const shown: *Shown = @ptrCast(@alignCast(context));
        const driver = shown.driver;
        const target = driver.canvasFor(shown.window);
        switch (shown.screen) {
            .induction => |tour| tour.draw(target),
            .rooms => |inside| try drawn(inside.draw(target, driver.clock.game_ticks)),
            .options => |menu| try drawn(menu.draw(target, &driver.front.dialog, driver.pointer)),
            .briefing => |meeting| try drawn(meeting.draw(target)),
        }
    }
};
