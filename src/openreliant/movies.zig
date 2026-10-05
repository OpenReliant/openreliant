//! The movies as `openreliant` plays them (`game.xtrabits.movie`): each in a loop of its own, as
//! the game plays them, each frame drawn over an empty scene and put on the window, with the
//! window's messages read as the message pump reads them. Around each mission `WinMain` flies, the
//! hangar's movie before it (`launch`) and what `play_landing_movie` plays after it (`land`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const srcore = engine.surrender.surrenderlib.srcore;
const game = engine.game;
const hog_snd = game.hog_snd;
const movie = game.xtrabits.movie;
const landing = game.xtrabits.landing;
const Pacing = @import("options.zig").Pacing;
const Presenter = @import("presenter.zig").Presenter;

pub const Movies = struct {
    gpa: Allocator,
    codec: engine.bink.Codec,
    /// The Miles driver the movies' sound plays through, where there is sound.
    sound: ?engine.mss.Driver,
    presenter: *Presenter,
    devices: *engine.input.Devices,
    pacer: *platform.window.Pacer,
    /// How the loop's frames are paced, as the settings have it.
    pacing: *const Pacing,
    size: movie.Size,
    look: engine.bink.Look,
    /// The video settings' `Transitions`, and whether the renderer is a hardware one, which decide
    /// whether a movie plays (`movie.Kind.plays`).
    transitions: bool,
    hardware: bool,
    /// The disc's archive open, which the movies of a mission's flight come from, and whose folder,
    /// the game's, holds the others.
    disc: *game.interface.disc.Disc,
    /// Whether a controller was connected or taken out while a movie played, which the game's loop
    /// then takes up.
    controllers_changed: bool = false,
    /// The characters typed into the window, which a screen with a line to type into takes.
    typed: *game.winmain.Typed,
    /// The game's clock and sound, whose timer keeps running while a movie plays, as the
    /// original's does (`hog_snd.Sound.runTimer`), so a music fade continues over a movie; null
    /// until the game has its clock.
    timer: ?Timer = null,

    pub const Timer = struct { clock: *game.main.Clock, sound: *hog_snd.Sound };

    /// Plays the movie `name` names as `kind` has it, until it ends or is skipped; null where the
    /// window was closed meanwhile, which quits the game, as it quits the game's loop
    /// (`game_exit`). A movie that is missing, or that cannot be decoded, is left out.
    pub fn play(movies: *Movies, name: []const u8, kind: movie.Kind) !?movie.End {
        if (!kind.plays(movies.transitions, movies.hardware)) return .finished;
        var player = movies.open(name, kind) orelse return .finished;
        defer player.close();
        return movies.run(&player, name);
    }

    /// The movie `name` names, read from where `kind` reads it and opened to play as it has it;
    /// null where it is left out.
    fn open(movies: *Movies, name: []const u8, kind: movie.Kind) ?movie.Player {
        return .load(movies.gpa, movies.codec, movies.disc, name, kind, movies.sound, movies.look);
    }

    /// The window's messages since the last pass, as the message pump reads them: the keys, the
    /// pointer, its buttons and its wheel into the devices, the wheel's notches no screen took
    /// last pass let go, and a controller connected or taken out noted. Null where the window was
    /// closed, which quits the game (`game_exit`).
    pub fn pump(movies: *Movies) ?Pumped {
        const devices = movies.devices;
        var pumped: Pumped = .{};
        _ = devices.mouse.notches();
        while (movies.presenter.window.poll()) |event| switch (event) {
            .quit => return null,
            .key => |key| devices.keyboard.down[@intFromEnum(key.scan)] = key.down,
            .pointer => |pointer| devices.mouse.at = pointer.at,
            .button => |button| switch (button.which) {
                .left => devices.mouse.buttons.left = button.down,
                .right => devices.mouse.buttons.right = button.down,
            },
            .wheel => |turned| devices.mouse.wheel += turned,
            .active => |active| pumped.active = active,
            .controllers => movies.controllers_changed = true,
            .keymap => platform.keyboard.nameKeys(&devices.key_names),
            .typed => |character| movies.typed.push(game.language.fromUnicode(character)),
        };
        return pumped;
    }

    /// What the messages told besides the input: whether the window went inactive or active
    /// again, where it did.
    pub const Pumped = struct { active: ?bool = null };

    /// Runs the loop of `player`, which plays the movie `name`, until it ends; null if the window
    /// was closed meanwhile.
    fn run(movies: *Movies, player: *movie.Player, name: []const u8) !?movie.End {
        const devices = movies.devices;
        while (true) {
            const pumped = movies.pump() orelse return null;
            // The message pump pauses the movie while the window is away (`BinkPause`).
            if (pumped.active) |active| player.bink.pause(!active, platform.window.nanoseconds());
            if (movies.timer) |timer| timer.sound.runTimer(timer.clock, platform.window.ticks());
            devices.keyboard.read();
            const end = player.pass(&devices.keyboard, devices.mouse.buttons.right, platform.window.nanoseconds()) catch |err| end: {
                std.log.warn("the movie {s} stops short: {s}", .{ name, @errorName(err) });
                break :end .finished;
            };
            if (end) |how| return how;
            const pixels = try movies.presenter.size();
            var shown: Shown = .{ .movies = movies, .player = player, .window = pixels };
            try movies.presenter.present(pixels, shown.overlay());
            movies.pace();
        }
    }

    /// Holds the loop to the frames a second the settings ask for, where the display does not.
    pub fn pace(movies: *Movies) void {
        if (movies.pacing.rate(movies.presenter.window.*)) |rate| movies.pacer.wait(rate);
    }

    /// A frame's overlay: the movie's frame, over the cleared frame.
    const Shown = struct {
        movies: *Movies,
        player: *movie.Player,
        window: [2]u32,

        fn overlay(shown: *Shown) srcore.Overlay {
            return .{ .context = shown, .draw = draw };
        }

        fn draw(context: *anyopaque) Allocator.Error!void {
            const shown: *Shown = @ptrCast(@alignCast(context));
            shown.player.draw(shown.movies.presenter.screen.interface(), shown.window, shown.movies.size);
        }
    };

    /// Before mission `mission`, which `WinMain` flies: the hangar's movie, the next of `hangar`'s,
    /// from its disc, which the game opens for it (`0x004ABD40`). False where the window was closed
    /// meanwhile.
    pub fn launch(movies: *Movies, hangar: *movie.Hangar, mission: u16) !bool {
        const next = hangar.next(mission);
        movies.disc.open(next.disc);
        return try movies.play(next.name, .cleared_from_disc) != null;
    }

    /// After the mission: what `play_landing_movie` plays (`landing.landing`), the banks read from
    /// `resources` and played through `sound`. False where the window was closed meanwhile.
    pub fn land(movies: *Movies, what: landing.Landing, resources: *const game.bigfile.Hog, sound: *hog_snd.Sound) !bool {
        switch (what) {
            .touchdown => |touchdown| {
                var opened = movies.open(touchdown.movie, .landing);
                defer if (opened) |*player| player.close();
                // The bank's sound starts once the landing's movie is open, and the voices stop as
                // the landing ends (`sound_pause_all`).
                const bank: ?Bank = if (touchdown.bank) |name| .start(movies.gpa, resources, sound, name, hog_snd.loudest, hog_snd.once) else null;
                defer {
                    sound.pauseAll();
                    if (bank) |started| started.stop(movies.gpa, sound);
                }
                const landed: movie.End = if (opened) |*player| try movies.run(player, touchdown.movie) orelse return false else .finished;
                if (landed == .finished) if (touchdown.thread) |thread| {
                    _ = try movies.play(thread, .thread) orelse return false;
                };
            },
            .chapter => |chapter| {
                movies.disc.open(chapter.disc);
                _ = try movies.play(chapter.zoom, .cleared_from_disc) orelse return false;
                const news: ?Bank = .start(movies.gpa, resources, sound, landing.news_loop, landing.news_loop_volume, hog_snd.forever);
                defer if (news) |started| started.stop(movies.gpa, sound);
                _ = try movies.play(chapter.movie, .over_screen_from_disc) orelse return false;
                for (chapter.reports.slice()) |report| {
                    _ = try movies.play(landing.news_transition, .over_screen_from_disc) orelse return false;
                    _ = try movies.play(report, .over_screen_from_disc) orelse return false;
                }
            },
        }
        return true;
    }
};

/// A bank of `resource.hog` whose first sound plays over the landing's movies, or a chapter's.
const Bank = struct {
    file: hog_snd.BankFile,
    voice: ?u8,

    /// The bank `name` names, read from `resources` (`hog_load`), and its first sound played
    /// through `sound` at `volume`, `loops` times, from the middle at its own pitch (`sound_play`);
    /// null where the bank is left out.
    fn start(gpa: Allocator, resources: *const game.bigfile.Hog, sound: *hog_snd.Sound, name: []const u8, volume: i32, loops: u32) ?Bank {
        const file = hog_snd.BankFile.read(gpa, resources, name) orelse return null;
        return .{ .file = file, .voice = sound.play(file.bank, 0, volume, loops, hog_snd.centre, hog_snd.own_pitch) };
    }

    /// Its voice ended (`sound_voice_end`), then the bank freed.
    fn stop(bank: Bank, gpa: Allocator, sound: *hog_snd.Sound) void {
        if (bank.voice) |v| sound.endVoice(v);
        bank.file.deinit(gpa);
    }
};
