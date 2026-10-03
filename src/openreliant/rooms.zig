//! The Reliant's rooms as `openreliant` runs them (`game.interface.rooms`), with a new pilot's
//! induction before them (`game.interface.induction`), the in-game options over them
//! (`game.interface.in_game_options`) and the briefing after them (`game.interface.briefing`):
//! each in a loop of its own, as the game runs them, each frame drawn over an empty scene and put
//! on the window, with the window's messages read as the message pump reads them, and the movies
//! between them played by `Movies`. `campaign` is what `WinMain` does as START GAME starts a
//! campaign, or LOAD GAME loads one, `goOn` as the campaign goes on after a mission, and `restart`
//! and `replayBriefing` as it turns back to a mission the pilot did not come through. The in-game
//! options' SAVE and LOAD open the saved games (`game.interface.saved_games`); a game loaded takes
//! the rooms to its mission. Their CONTROL DEVICES opens the settings screen
//! (`game.interface.settings`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const srcore = engine.surrender.surrenderlib.srcore;
const tcache = openreliant.tcache;
const game = engine.game;
const loadout = engine.interface.loadout;
const interface = game.interface;
const briefing = interface.briefing;
const canvas = interface.canvas;
const cd_player = interface.cd_player;
const induction = interface.induction;
const locker = interface.locker;
const in_game_options = interface.in_game_options;
const restart_screen = interface.restart;
const rooms = interface.rooms;
const saved_games = interface.saved_games;
const settings = interface.settings;
const save = game.gameflow.save;
const itac_module = game.itac;
const simulator_pod = loadout.simulator_pod;
const Movies = @import("movies.zig").Movies;
const drawn = @import("presenter.zig").drawn;
const version = @import("version");

const log = std.log.scoped(.rooms);

/// How the rooms end, where the game goes on: through the briefing room's door and the briefing,
/// the mission flown, as its loadout left it where it ran; to the main menu; or a mission of the
/// simulator pod's, after which the rooms go back into the pod (`Driver.backFromSimulator`).
pub const End = union(enum) {
    fly: Flown,
    main_menu,
    simulator: interface.main_menu.Flight,

    /// The mission the briefing leads to, which a game loaded on the way may have changed, and
    /// what its loadout chose, where it ran.
    pub const Flown = struct { mission: u16, result: ?loadout.Result };
};

/// How a briefing ends: as the rooms do, or with a game loaded from its in-game options, which
/// takes the rooms to its mission.
const Briefed = union(enum) {
    fly: End.Flown,
    main_menu,
    loaded,
};

/// How the ITAC ends, where the game goes on: closed, or with REPLAY MISSION.
pub const ItacEnd = enum { closed, replay };

/// What the rooms run with.
pub const Driver = struct {
    movies: *Movies,
    sound: *game.hog_snd.Sound,
    clock: *game.main.Clock,
    /// `resource.hog`, the front end's fonts and dialog, the outline fonts that stand in for the
    /// fonts, and the strings.
    resources: *const game.bigfile.Hog,
    front: *engine.genilib.interf.Resources,
    outlines: *game.hud.outline.Outlines,
    strings: *const game.language.Language,
    /// How Enriquez's scenes and words sound: the radio's style.
    speech: game.cbox.Style,
    /// `speech_hog`, which holds Enriquez's words in the briefing; null where the game's folder
    /// has none.
    lines: ?*const openreliant.hog.Archive,
    /// The screenshots the briefing's O key saves.
    screenshots: *game.xtrabits.screenshot.Screenshots,
    /// The texture cache, which the loadout decodes its own textures from, and the renderer's
    /// details, which it draws them and its ships with.
    cache: tcache.Cache,
    details: game.winmain.Details,
    /// What the game's models are built with (`game.srofiles.Settings`).
    models: game.srofiles.Settings,
    /// The campaign's saved loadout, which the loadout starts from and keeps the ship chosen and
    /// its racks in.
    saved: *loadout.Saved,
    /// The ship types' and the missile types' stats, which the loadout shows their figures of.
    stats: *const game.create.Stats,
    missile_stats: *const game.missiles.Table,
    /// The campaign's tier and the pilot, which set the ships the loadout offers, as they stand each
    /// time the loadout runs, and which the ITAC shows and the saved games keep: the pilot the
    /// roster set, the pilot's kills and rank, and the campaign flown.
    tier: *u2,
    pilot: *interface.pilot_roster.Pilot,
    player: *engine.input.Player,
    campaign_flown: *?game.gameflow.Campaign,
    /// The pilots of the player's wing and their replacements, which the saved games keep.
    wingmen: *game.pilots.Wingmen,
    /// `ITACLANG.DLL`'s strings, which the ITAC writes with.
    itac_strings: *const game.language.Language,
    /// The game's folder, which holds the saved games, and the local date and time of a moment,
    /// which the saved games show the dates of their files by.
    saves: save.Folder,
    local_time: ?*const fn (i96) ?saved_games.Date = null,
    /// `starlancer.ini`, which the settings screen writes the settings to, and OpenReliant's own
    /// options, which it shows.
    settings_file: *engine.profile.File,
    own: ?settings.Own = null,
    /// The game's video settings, which the settings screen's video changes.
    video: ?settings.Video = null,
    /// The front end's pointer, which the rooms' follows, and the timer's count it last moved on
    /// at.
    pointer: canvas.Pointer = .{},
    ticks: u64 = 0,
    /// Whether the window is the active one.
    active: bool = true,
    /// The rooms while they are open, before `rooms_mission`, and the simulator pod while it is:
    /// both kept through a mission of the pod's, with the pilot's kills as it began, which the pod
    /// puts back after it (`0x0044F6D5`, `0x0044F6FE`).
    inside: ?rooms.Rooms = null,
    rooms_mission: u16 = 0,
    pod: ?simulator_pod.Pod = null,
    pod_kills: i32 = 0,
    /// The CD player's volume, and which of the Yamato's second crew comes next, which last while
    /// the game runs.
    cd_volume: cd_player.Volume = cd_player.full_volume,
    crew_turn: rooms.crew.Turn = .{},

    /// What `WinMain` does as a single-player campaign starts, or is loaded, before mission
    /// `mission` (`winmain.CampaignStart`), then the rooms. Null where the game quits meanwhile.
    pub fn campaign(driver: *Driver, mission: u16) !?End {
        const start: game.winmain.CampaignStart = .of(mission);
        driver.turnTo(start.disc);
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

    /// What `WinMain` does as the campaign goes on after a mission, before mission `mission`: the
    /// rooms from where the ITAC leaves the pilot (`0x004AA372`, `0x004AA381`), whose briefing
    /// room leads to the mission. Null where the game quits meanwhile.
    pub fn goOn(driver: *Driver, mission: u16) !?End {
        const carrier = rooms.Carrier.of(mission);
        driver.turnTo(carrier.disc());
        return driver.visit(mission, carrier.after(.itac));
    }

    /// REPLAY MISSION FROM BRIEFING's way back to mission `mission` (`0x004AA2E0` on): the
    /// mission's briefing. Null where the game quits meanwhile.
    pub fn replayBriefing(driver: *Driver, mission: u16) !?End {
        driver.turnTo(rooms.Carrier.of(mission).disc());
        return switch (try driver.brief(mission, false) orelse return null) {
            .fly => |flown| .{ .fly = flown },
            .main_menu => .main_menu,
            .loaded => {
                const start = driver.loadedStart() orelse return .main_menu;
                return driver.visit(start.mission, start.view);
            },
        };
    }

    /// The restart screen (`restart_screen`) in its loop, with its shapes: what it chose, or null
    /// where the game quits meanwhile.
    pub fn restart(driver: *Driver) !?restart_screen.Choice {
        const gpa = driver.movies.gpa;
        var screen: Restarting = .{ .shapes = .read(gpa, driver.resources, restart_screen.shapes_name) };
        defer if (screen.shapes) |*shapes| shapes.deinit(gpa);
        driver.startTimer();
        var last = driver.clock.game_ticks;
        while (true) {
            if (!try driver.pump()) return null;
            const ticks = driver.clock.game_ticks;
            const elapsed = ticks -% last;
            last = ticks;
            if (screen.state.frame(driver.pointer, &driver.movies.devices.keyboard, elapsed)) |choice| return choice;
            try driver.present(.{ .restart = &screen });
        }
    }

    /// The ITAC (`itac`) in its loop, for `run`, as the campaign comes to mission `mission`: how it
    /// ends, or null where the game quits meanwhile. Its sounds end as it does (`0x0043FB3D`), and
    /// with none flown, it closes at once.
    pub fn itac(driver: *Driver, run: itac_module.Run, mission: u16) !?ItacEnd {
        const flown = if (driver.campaign_flown.*) |*going| going else return .closed;
        const pilot: itac_module.Pilot = .{
            .call_sign = driver.pilot.call_sign.slice(),
            .kills = driver.player.kills.count,
            .rank = driver.player.rank,
            .tier = driver.tier.*,
            .campaign = flown,
            .mission = mission,
        };
        const with: itac_module.Context = .{ .rooms = driver.context(), .strings = driver.itac_strings, .language = driver.strings };
        driver.startTimer();
        var terminal: itac_module.Itac = .open(with, run, pilot, platform.window.nanoseconds(), driver.clock.game_ticks);
        defer terminal.deinit();
        defer driver.sound.endAll();
        while (true) {
            if (!try driver.pump()) return null;
            const step = terminal.pass(.{
                .keyboard = &driver.movies.devices.keyboard,
                .pointer = driver.pointer,
                .now = platform.window.nanoseconds(),
                .ticks = driver.clock.game_ticks,
            }) orelse {
                try driver.present(.{ .itac = &terminal });
                continue;
            };
            switch (step) {
                .play => |shown| _ = try driver.movies.play(shown.name, shown.kind) orelse return null,
                .hold => driver.movies.pacer.wait(game.main.ticks_per_second),
                .closed => return .closed,
                .replay => return .replay,
            }
        }
    }

    /// The developers' briefing of mission `mission`, from its loadout on
    /// (`briefing_from_loadout`), after which the front end starts again. False where the game
    /// quits meanwhile.
    pub fn loadoutBriefing(driver: *Driver, mission: u16) !bool {
        driver.startTimer();
        return try driver.brief(mission, true) != null;
    }

    /// The game the saved games save and load: the campaign flown, and the pilot; none outside a
    /// campaign.
    fn played(driver: *Driver) ?save.Game {
        const going = if (driver.campaign_flown.*) |*flown| flown else return null;
        return .{ .campaign = going, .player = driver.player, .tier = driver.tier, .pilot = driver.pilot, .saved = driver.saved, .wingmen = driver.wingmen };
    }

    /// What `WinMain` does as it turns to the rooms or a briefing (`0x004AA1BA` on): the music
    /// fading out by 15 (`music_fade_out`) and the archive of disc `number` opened
    /// (`cd_hog_open`), the timer counted from now.
    fn turnTo(driver: *Driver, number: interface.disc.Number) void {
        driver.startTimer();
        driver.sound.fadeMusic(game.winmain.music_fade_step, driver.clock.game_ticks);
        driver.movies.disc.open(number);
    }

    /// The timer counted from now, as the loops step by it.
    fn startTimer(driver: *Driver) void {
        driver.clock.start(platform.window.ticks());
        driver.ticks = platform.window.ticks();
    }

    /// What the briefing's loadout before mission `mission` reads, plays and draws with.
    fn loadoutContext(driver: *Driver, mission: u16) loadout.Context {
        return .{
            .rooms = driver.context(),
            .cache = driver.cache,
            .strings = driver.strings,
            .stats = driver.stats,
            .missile_stats = driver.missile_stats,
            .mission = mission,
            .tier = driver.tier.*,
            .rank = driver.player.rank,
            .saved = driver.saved,
            .hardware = driver.movies.presenter.screen.* != .software,
            .detail = driver.details.graphic,
            .largest_texture = driver.details.texture.largest(),
            .models = driver.models,
        };
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
            .campaign = if (driver.campaign_flown.*) |*going| going else null,
            .second_crew = &driver.crew_turn,
            .outlines = driver.outlines,
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
    /// how they end, or null where the game quits meanwhile. A game loaded from the in-game options
    /// takes the rooms to its mission (`loadedStart`).
    fn visit(driver: *Driver, mission: u16, view: u8) !?End {
        driver.openRooms(mission, view);
        return driver.carryOn();
    }

    /// The rooms in their loop from where they stand, and what they lead to, as `visit`: the rooms
    /// and the pod kept through a mission of the pod's.
    fn carryOn(driver: *Driver) !?End {
        errdefer driver.closeRooms();
        while (true) {
            const mission = driver.rooms_mission;
            const walked = try driver.walk() orelse {
                driver.closeRooms();
                return null;
            };
            const briefed: Briefed = switch (walked) {
                // A mission of the simulator pod's: the rooms and the pod kept for after it.
                .simulator => |flight| return .{ .simulator = flight },
                .briefing => briefed: {
                    driver.closeRooms();
                    break :briefed try driver.brief(mission, false) orelse return null;
                },
                .main_menu => {
                    driver.closeRooms();
                    return .main_menu;
                },
                .loaded => loaded: {
                    driver.closeRooms();
                    break :loaded .loaded;
                },
            };
            switch (briefed) {
                .fly => |flown| return .{ .fly = flown },
                .main_menu => return .main_menu,
                .loaded => {
                    const start = driver.loadedStart() orelse return .main_menu;
                    driver.openRooms(start.mission, start.view);
                },
            }
        }
    }

    /// Back into the simulator pod as a mission of its own ends (`simulator_pod`, `0x0044F6FE`
    /// on): the pilot's kills put back as the mission began, the pod's loop again, and on through
    /// the rooms once it closes. How they end, or null where the game quits meanwhile.
    pub fn backFromSimulator(driver: *Driver) !?End {
        driver.player.kills.count = driver.pod_kills;
        driver.startTimer();
        errdefer driver.closeRooms();
        const pod = &(driver.pod orelse return driver.carryOn());
        pod.back();
        switch (try driver.simulate() orelse {
            driver.closeRooms();
            return null;
        }) {
            .fly => |flight| return .{ .simulator = flight },
            .closed => driver.inside.?.leave(.simulator, platform.window.nanoseconds()),
        }
        return driver.carryOn();
    }

    fn openRooms(driver: *Driver, mission: u16, view: u8) void {
        driver.inside = .open(driver.context(), mission, view, platform.window.nanoseconds());
        driver.rooms_mission = mission;
    }

    /// Lets go of the rooms and the pod, where they are open.
    fn closeRooms(driver: *Driver) void {
        driver.closePod();
        if (driver.inside) |*inside| inside.close();
        driver.inside = null;
    }

    fn closePod(driver: *Driver) void {
        if (driver.pod) |*pod| pod.deinit();
        driver.pod = null;
    }

    /// Where the rooms start again as the in-game options load a game (`0x0043A309` on): the disc
    /// of its mission opened, and the first view of its carrier. None outside a campaign.
    fn loadedStart(driver: *Driver) ?struct { mission: u16, view: u8 } {
        const going = driver.campaign_flown.* orelse return null;
        const carrier = rooms.Carrier.of(going.mission);
        driver.turnTo(carrier.disc());
        return .{ .mission = going.mission, .view = carrier.start() };
    }

    /// How the rooms' loop ends: through the briefing room's door, to the main menu, with a game
    /// loaded, or with a mission of the simulator pod's.
    const Walked = union(enum) { briefing, main_menu, loaded, simulator: interface.main_menu.Flight };

    /// The rooms' loop, from where they stand; null where the game quits meanwhile.
    fn walk(driver: *Driver) !?Walked {
        const inside = &driver.inside.?;
        const mission = driver.rooms_mission;
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
                // A screen of its own ends the pass, as the game goes back to its loop's top after
                // one (`0x0043A2FE`, `0x0043AD8C`): the next pass reads the clock again, which the
                // movie the rooms go on with keeps its time from.
                .options => switch (try driver.options() orelse return null) {
                    .back => continue,
                    .main_menu => return .main_menu,
                    .quit => return null,
                    .loaded => return .loaded,
                },
                .place => |place| {
                    // The places' screens; the rooms play the news report themselves
                    // (`Rooms.pass`).
                    switch (place) {
                        .itac => {
                            _ = try driver.itac(.rooms, mission) orelse return null;
                        },
                        .simulator => {
                            driver.pod = .open(.{ .rooms = driver.context(), .steps = inside.stepSounds() }, mission, driver.clock.game_ticks);
                            if (driver.pod.?.opening()) |shown| _ = try driver.movies.play(shown.name, shown.kind) orelse return null;
                            switch (try driver.simulate() orelse return null) {
                                .fly => |flight| return .{ .simulator = flight },
                                .closed => {},
                            }
                        },
                        .locker => if (!try driver.openLocker(mission, inside.stepSounds())) return null,
                        .cd_player => if (!try driver.listen(mission, inside.stepSounds())) return null,
                        .news => {},
                    }
                    inside.leave(place, platform.window.nanoseconds());
                    continue;
                },
                .briefing => return .briefing,
            };
            inside.advance(now);
            try driver.present(.{ .rooms = inside });
        }
    }

    /// How the simulator pod's loop ends.
    const Simulated = union(enum) { closed, fly: interface.main_menu.Flight };

    /// The simulator pod (`simulator_pod`) in its loop, from where it stands: closed, its movie out
    /// played and the pod let go; or with a mission of its own, the pod kept open and the pilot's
    /// kills kept as the mission begins (`0x0044F6D5`). Null where the game quits meanwhile.
    fn simulate(driver: *Driver) !?Simulated {
        const pod = &driver.pod.?;
        while (true) {
            if (!try driver.pump()) return null;
            const step = pod.pass(.{
                .keyboard = &driver.movies.devices.keyboard,
                .pointer = driver.pointer,
                .ticks = driver.clock.game_ticks,
            }) orelse {
                try driver.present(.{ .pod = pod });
                continue;
            };
            switch (step) {
                .play => |shown| _ = try driver.movies.play(shown.name, shown.kind) orelse return null,
                .fly => |flight| {
                    driver.pod_kills = driver.player.kills.count;
                    return .{ .fly = flight };
                },
                .closed => {
                    if (pod.leave()) |shown| _ = try driver.movies.play(shown.name, shown.kind) orelse return null;
                    driver.closePod();
                    return .closed;
                },
            }
        }
    }

    /// The locker (`medal_display`) before mission `mission`, with the rooms' steps, the Yamato's
    /// way to it played first, in its loop until it closes; false where the game quits meanwhile.
    /// Its 0 saves the screen as it stands, before what the pass leads to.
    fn openLocker(driver: *Driver, mission: u16, steps: rooms.Steps) !bool {
        if (locker.Locker.zoom(.of(mission))) |name| _ = try driver.movies.play(name, .over_screen_from_disc) orelse return false;
        const held: locker.Awards = .of(if (driver.campaign_flown.*) |*going| going else null);
        var case: locker.Locker = .open(.{ .rooms = driver.context(), .steps = steps }, mission, held);
        defer case.deinit();
        while (true) {
            if (!try driver.pump()) return false;
            if (!case.pass(.{ .keyboard = &driver.movies.devices.keyboard, .pointer = driver.pointer, .now = platform.window.nanoseconds() })) return true;
            if (case.screenshot) driver.saveScreenshot();
            try driver.present(.{ .locker = &case });
        }
    }

    /// The CD player (`cd_player`) before mission `mission`, with the rooms' steps, in its loop,
    /// until it closes; false where the game quits meanwhile. The music it plays goes on in the
    /// rooms.
    fn listen(driver: *Driver, mission: u16, steps: rooms.Steps) !bool {
        var player: cd_player.CdPlayer = .open(.{ .rooms = driver.context(), .steps = steps, .volume = &driver.cd_volume }, mission, platform.window.nanoseconds());
        defer player.deinit();
        while (true) {
            if (!try driver.pump()) return false;
            if (!player.pass(.{ .keyboard = &driver.movies.devices.keyboard, .pointer = driver.pointer })) return true;
            try driver.present(.{ .cd_player = &player });
        }
    }

    /// The briefing (`interface_briefing`) before mission `mission`, in its loop, from the
    /// loadout where `from_loadout` has it: its door drawn for the frame it loads after, the
    /// movies of its way in played as it comes to them, and its loadout run, with the in-game
    /// options its Escape opens. How it ends: the mission flown, in the ship the loadout chose; the
    /// main menu; or null where the game quits meanwhile.
    fn brief(driver: *Driver, mission: u16, from_loadout: bool) !?Briefed {
        var meeting: briefing.Briefing = .open(driver.context(), mission, from_loadout, driver.loadoutContext(mission));
        defer meeting.close();
        try driver.present(.{ .briefing = &meeting });
        while (true) {
            const active = driver.active;
            if (!try driver.pump()) return null;
            if (driver.active != active) meeting.pause(!driver.active, platform.window.nanoseconds());
            const pointer = driver.pointer;
            const step = meeting.pass(.{
                .keyboard = &driver.movies.devices.keyboard,
                .right = pointer.right_down,
                .ticks = driver.clock.game_ticks,
                .hologram = .{ .now = milliseconds(), .mouse = .{ .at = pointer.at, .left = pointer.down, .right = pointer.right_down } },
            });
            // O saves the screen as it stands, before what the pass leads to.
            if (meeting.screenshot) driver.saveScreenshot();
            if (step) |next| switch (next) {
                .movie => |name| {
                    _ = try driver.movies.play(name, .over_screen_from_disc) orelse return null;
                    continue;
                },
                .over => return .{ .fly = .{ .mission = mission, .result = meeting.result } },
                .options => {
                    const choice = try driver.options() orelse return null;
                    if (choice == .quit) return null;
                    if (meeting.afterOptions(choice, milliseconds())) |after| switch (after) {
                        .main_menu => return .main_menu,
                        .loaded => return .loaded,
                        else => {},
                    };
                    continue;
                },
                .main_menu => return .main_menu,
                .loaded => return .loaded,
            };
            meeting.advance(platform.window.nanoseconds(), driver.clock.game_ticks);
            try driver.present(.{ .briefing = &meeting });
        }
    }

    /// The in-game options in their loop, with what they draw with: where they lead, or null where
    /// the game quits meanwhile. MAIN MENU plays its movie first; SAVE and LOAD open the saved
    /// games over the menu, while a campaign is flown; AUDIO, CONTROL DEVICES and VIDEO the
    /// settings screen.
    ///
    /// **Fix:** the menu takes no press until the button held as the saved games led back to it
    /// comes up, as the front end's screens take none.
    fn options(driver: *Driver) !?in_game_options.End {
        const gpa = driver.movies.gpa;
        var menu: Menu = .{
            .backdrop = .read(driver, in_game_options.background_name, in_game_options.shapes_name),
            .about_shapes = .read(gpa, driver.resources, in_game_options.about_shapes_name),
        };
        defer menu.close(gpa);
        var press: engine.input.FreshPress = .{ .held = false };
        while (true) {
            if (!try driver.pump()) return null;
            var pointer = driver.pointer;
            pointer.down = press.pressed(pointer.down);
            if (menu.state.frame(pointer, &driver.movies.devices.keyboard)) |choice| switch (choice) {
                .back => return .back,
                .main_menu => {
                    _ = try driver.movies.play(in_game_options.to_main_menu, .over_screen) orelse return null;
                    return .main_menu;
                },
                .quit => return .quit,
                .save, .load => {
                    const mode: saved_games.Mode = if (choice == .save) .save else .load;
                    const end = try driver.savedGames(mode) orelse return null;
                    if (saved_games.leavingMovie(mode, .in_game_options, end)) |movie| _ = try driver.movies.play(movie, .over_screen) orelse return null;
                    if (in_game_options.afterSavedGames(mode, end)) |after| return after;
                    menu.state = .{};
                    press = .{};
                },
                .settings => |tab| {
                    const end = try driver.settingsScreen(tab) orelse return null;
                    if (settings.leavingMovie(.in_game_options, end)) |movie| _ = try driver.movies.play(movie, .over_screen) orelse return null;
                    if (end == .main_menu) return .main_menu;
                    menu.state = .{};
                    press = .{};
                },
            };
            try driver.present(.{ .options = &menu });
        }
    }

    /// The saved games (`saved_games`) over the in-game options, `mode` saving or loading, after
    /// the movie that leads to them, in their loop: how they end, or null where the game quits
    /// meanwhile. Outside a campaign there is no game to save or load, and they end at once.
    fn savedGames(driver: *Driver, mode: saved_games.Mode) !?saved_games.End {
        const flown = driver.played() orelse {
            log.info("the saved games need a campaign", .{});
            return .back;
        };
        const gpa = driver.movies.gpa;
        const opening = saved_games.opening(.in_game_options);
        _ = try driver.movies.play(opening.movie, .over_screen) orelse return null;
        const saves: saved_games.Saves = .{ .gpa = gpa, .folder = driver.saves, .game = flown, .strings = driver.strings, .local_time = driver.local_time };
        var screen: SavesScreen = .{ .backdrop = .read(driver, opening.background, saved_games.shapes_name) };
        defer screen.close(gpa);
        var press: engine.input.FreshPress = .{};
        screen.state.enter(mode, .in_game_options, driver.savesContext(saves, driver.pointer));
        const window = driver.movies.presenter.window;
        defer window.takeText(false);
        while (true) {
            if (!try driver.pump()) return null;
            var pointer = driver.pointer;
            pointer.down = press.pressed(pointer.down);
            window.takeText(screen.state.takesText());
            if (screen.state.frame(driver.savesContext(saves, pointer))) |end| return end;
            try driver.present(.{ .saved_games = &screen });
        }
    }

    /// The settings screen (`settings`) over the in-game options, on `tab`, after the movie that
    /// leads to it, in its loop: how it ends, or null where the game quits meanwhile.
    fn settingsScreen(driver: *Driver, tab: settings.Tab) !?settings.End {
        const gpa = driver.movies.gpa;
        const opening = settings.opening(.in_game_options, tab).?;
        _ = try driver.movies.play(opening.movie, .over_screen) orelse return null;
        var screen: SettingsScreen = .{ .backdrop = .read(driver, opening.background, settings.shapes_name) };
        defer screen.close(gpa);
        var press: engine.input.FreshPress = .{};
        screen.state.enter(.in_game_options, tab, driver.settingsContext(driver.pointer));
        while (true) {
            if (!try driver.pump()) return null;
            var pointer = driver.pointer;
            pointer.down = press.pressed(pointer.down);
            if (screen.state.frame(driver.settingsContext(pointer))) |end| return end;
            try driver.present(.{ .settings = &screen });
        }
    }

    /// What a pass of the settings screen reads, with the pointer at `pointer`.
    fn settingsContext(driver: *Driver, pointer: canvas.Pointer) settings.Context {
        return .{ .pointer = pointer, .devices = driver.movies.devices, .settings_file = driver.settings_file, .ticks = driver.clock.game_ticks, .sound = driver.sound, .own = driver.own, .video = driver.video };
    }

    /// What a pass of the saved games reads, with the pointer at `pointer`.
    fn savesContext(driver: *Driver, saves: saved_games.Saves, pointer: canvas.Pointer) saved_games.Context {
        return .{ .pointer = pointer, .keyboard = &driver.movies.devices.keyboard, .typed = driver.movies.typed, .ticks = driver.clock.game_ticks, .saves = saves };
    }

    /// Reads the window's messages since the last pass, as the message pump does, reads the
    /// keyboard, moves the pointer on and runs the timer, which steps the fades. Returns false if
    /// the window was closed, which quits the game (`game_exit`).
    fn pump(driver: *Driver) !bool {
        const movies = driver.movies;
        const devices = movies.devices;
        const pumped = movies.pump() orelse return false;
        if (pumped.active) |active| driver.activate(active);
        devices.keyboard.read();
        const ticks = platform.window.ticks();
        const elapsed = std.math.cast(i32, ticks -| driver.ticks) orelse std.math.maxInt(i32);
        driver.ticks = ticks;
        driver.pointer.update(&devices.mouse, try movies.presenter.size(), elapsed);
        driver.sound.runTimer(driver.clock, ticks);
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

    /// Saves the screen as it stands, the last frame drawn (`screenshot_save`).
    fn saveScreenshot(driver: *Driver) void {
        driver.movies.presenter.screen.saveScreenshot(driver.movies.gpa, driver.screenshots);
    }

    /// Draws a frame of `screen` and puts it on the window, at the frame rate asked for: over the
    /// loadout's hologram where the briefing shows it.
    fn present(driver: *Driver, screen: Shown.Screen) !void {
        const presenter = driver.movies.presenter;
        const pixels = try presenter.size();
        var shown: Shown = .{ .driver = driver, .window = pixels, .screen = screen };
        const hologram = switch (screen) {
            .briefing => |meeting| meeting.shownHologram(),
            else => null,
        };
        if (hologram) |shown_hologram| {
            var view = shown_hologram.viewIn(pixels);
            try presenter.presentScene(pixels, &view, &shown_hologram.scene, shown.overlay());
        } else try presenter.present(pixels, shown.overlay());
        driver.movies.pace();
    }

    fn canvasFor(driver: *Driver, window: [2]u32) canvas.Canvas {
        return .{
            .gpa = driver.movies.gpa,
            .target = driver.movies.presenter.screen.interface(),
            .window = window,
            .fonts = .{ .large = &driver.front.large.font, .small = &driver.front.small.font },
            .strings = driver.strings,
            .version = version.string,
        };
    }
};

/// The clock's milliseconds, which the loadout's animations run by (`timeGetTime`).
fn milliseconds() u32 {
    return @truncate(platform.window.nanoseconds() / std.time.ns_per_ms);
}

/// What a screen over the rooms draws with: the picture behind it, and its shapes, which it reads
/// as it opens.
const Backdrop = struct {
    background: game.matmanager.Background = .{},
    shapes: ?canvas.Shapes = null,

    /// The picture `background` and the shapes `shapes` of the driver's archive; a part that can't
    /// be read is left out, and logged.
    fn read(driver: *Driver, background: []const u8, shapes: []const u8) Backdrop {
        const gpa = driver.movies.gpa;
        var backdrop: Backdrop = .{ .shapes = .read(gpa, driver.resources, shapes) };
        backdrop.background.show(gpa, driver.resources.*, background);
        return backdrop;
    }

    fn close(backdrop: *Backdrop, gpa: Allocator) void {
        backdrop.background.deinit(gpa);
        if (backdrop.shapes) |*shapes| shapes.deinit(gpa);
    }

    /// Draws the picture, and gives the shapes the screen draws with over it; null where they are
    /// left out.
    fn draw(backdrop: *Backdrop, target: canvas.Canvas) ?*game.hud.Art {
        if (backdrop.background.image) |*shown| target.fill(shown);
        return if (backdrop.shapes) |*loaded| &loaded.art else null;
    }
};

/// The in-game options, and what they draw with, ABOUT STARLANCER's shapes among it.
const Menu = struct {
    state: in_game_options.InGameOptions = .{},
    backdrop: Backdrop,
    about_shapes: ?canvas.Shapes,

    fn close(menu: *Menu, gpa: Allocator) void {
        menu.backdrop.close(gpa);
        if (menu.about_shapes) |*shapes| shapes.deinit(gpa);
    }

    fn draw(menu: *Menu, target: canvas.Canvas, dialog: *game.hud.Art, pointer: canvas.Pointer) canvas.Error!void {
        const shapes = menu.backdrop.draw(target) orelse return;
        const about = if (menu.about_shapes) |*loaded| &loaded.art else null;
        try menu.state.draw(target, shapes, dialog, about, pointer);
    }
};

/// The saved games, and what they draw with.
const SavesScreen = struct {
    state: saved_games.SavedGames = .{},
    backdrop: Backdrop,

    fn close(screen: *SavesScreen, gpa: Allocator) void {
        screen.backdrop.close(gpa);
    }

    fn draw(screen: *SavesScreen, target: canvas.Canvas, dialog: *game.hud.Art, pointer: canvas.Pointer, call_sign: []const u8) canvas.Error!void {
        const shapes = screen.backdrop.draw(target) orelse return;
        try screen.state.draw(target, shapes, dialog, pointer, call_sign);
    }
};

/// The settings screen, and what it draws with.
const SettingsScreen = struct {
    state: settings.Settings = .{},
    backdrop: Backdrop,

    fn close(screen: *SettingsScreen, gpa: Allocator) void {
        screen.backdrop.close(gpa);
    }

    fn draw(screen: *SettingsScreen, target: canvas.Canvas, dialog: *game.hud.Art, shown: settings.Shown, pointer: canvas.Pointer) canvas.Error!void {
        const shapes = screen.backdrop.draw(target) orelse return;
        try screen.state.draw(target, shapes, dialog, shown, pointer);
    }
};

/// The restart screen, and its shapes.
const Restarting = struct {
    state: restart_screen.Restart = .{},
    shapes: ?canvas.Shapes = null,

    fn draw(screen: *Restarting, target: canvas.Canvas, pointer: canvas.Pointer) canvas.Error!void {
        const shapes = if (screen.shapes) |*loaded| &loaded.art else return;
        try screen.state.draw(target, shapes, pointer);
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
        saved_games: *SavesScreen,
        settings: *SettingsScreen,
        briefing: *briefing.Briefing,
        restart: *Restarting,
        itac: *itac_module.Itac,
        pod: *simulator_pod.Pod,
        locker: *locker.Locker,
        cd_player: *cd_player.CdPlayer,
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
            .saved_games => |screen| try drawn(screen.draw(target, &driver.front.dialog, driver.pointer, driver.pilot.call_sign.slice())),
            .settings => |screen| try drawn(screen.draw(target, &driver.front.dialog, .{ .devices = driver.movies.devices, .sound = driver.sound, .video = driver.video }, driver.pointer)),
            .briefing => |meeting| try drawn(meeting.draw(target)),
            .restart => |screen| try drawn(screen.draw(target, driver.pointer)),
            .itac => |terminal| try drawn(terminal.draw(target)),
            .pod => |pod| try drawn(pod.draw(target)),
            .locker => |case| try drawn(case.draw(target)),
            .cd_player => |player| try drawn(player.draw(target)),
        }
    }
};
