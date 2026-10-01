//! The movies the game plays in a loop of their own. Four functions play one each (`Kind`):
//! `play_bink_movie` (`0x004AB850`) and `play_bink_movie_no_clear` (`0x004AB6E0`) from the game's
//! folder, and `play_bink_movie_resourced` (`0x004ABB80`) and `play_bink_movie_no_clear_resourced`
//! (`0x004AB9D0`) from the disc's archive open; `play_landing_movie` plays its landing in a loop of
//! its own ([`landing.zig`](landing.zig)). As the renderer starts for the first time,
//! `renderer_load` plays the intro (`intro`); `WinMain` plays the splash's way into the main menu
//! (`splash_to_menu`) before it opens the front end, and the hangar's movie before each mission it
//! flies (`Hangar`); and the front end's screens play their transitions as they lead from one to
//! another. The Reliant's rooms play theirs in loops of their own (`Kind.screen`).
//!
//! A pass of the loop (`0x004AB7B2`) runs the message pump and reads the keyboard and the pointer;
//! Escape, the pointer's right button, the movie's end or the game quitting ends it. Otherwise the
//! next frame shows once it is due (`bink_frame`, `play`), copied into the middle of the screen.
//! A movie that cannot be opened stops the game with a message (`play_bink_movie: error loading
//! %s.`); OpenReliant goes on without it.
//!
//! **Improvement:** OpenReliant draws a movie as large as fits in the window, as it draws the front
//! end, so that a 16:9 movie fills a wide window (`Size`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const bink = @import("../../bink.zig");
const files = @import("../../files.zig");
const input = @import("../../input.zig");
const mss = @import("../../mss.zig");
const hud = @import("../hud.zig");
const canvas = @import("../interface/canvas.zig");
const disc = @import("../interface/disc.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const device = @import("../../surrender/srd3d/device.zig");
const container = @import("../../../formats/bink.zig");

const log = std.log.scoped(.movies);

/// The movies `renderer_load` plays as the renderer first starts (`0x004AB4D5` on), before its
/// loading screens.
pub const intro = [_][]const u8{ "new_nms.bik", "new_dalogo_fs_uncmpr.bik", "warty_.bik" };

/// The movie `0x004AB6A0` plays as `WinMain` opens the front end, from the splash into the main
/// menu (`0x0050A31C`).
pub const splash_to_menu = "splash to mm.bik";

/// The transitions between the front end's screens ported (`0x004E8240`, `0x004E8680`): SINGLE
/// PLAYER's from the main menu into the pilot roster, and the pilot roster's MAIN MENU's and
/// Escape's back; and GAME OPTIONS' (`0x004E8210`) into its menu (`interface.game_options`).
pub const main_to_single = "interface\\main2sin.bik";
pub const single_to_main = "interface\\sin2main.bik";
pub const main_to_options = "interface\\main2opt.bik";

/// What plays a movie, which decides where it is read from, the rate it plays at, whether it plays
/// at all, and what ends it.
pub const Kind = enum {
    /// `play_bink_movie`: from the game's folder, at the movie's rate and full volume
    /// (`bink.full_volume`), on a screen it clears to black first. `renderer_load` plays the intro
    /// so.
    cleared,
    /// `play_bink_movie_no_clear`: from the game's folder, at 15 frames a second
    /// (`transition_rate`), over what the screen last showed. The front end's transitions play so.
    over_screen,
    /// `play_bink_movie_resourced`: as `cleared`, from the disc's archive open. The hangar's movies
    /// play so.
    cleared_from_disc,
    /// `play_bink_movie_no_clear_resourced`: as `over_screen`, from the disc's archive open, but at
    /// the movie's rate: it sets the rate without `BINKFRAMERATE`, which alone has Bink keep to it.
    /// A chapter's movie and the news reports after it play so.
    over_screen_from_disc,
    /// `play_landing_movie`'s landing (`0x004AC195` on): from the disc's archive open, at 15 frames
    /// a second and full volume, on a screen it clears to black first, whatever the settings. Its
    /// loop moves no pointer (`interface_pointer_update`), and the pointer's right button leaves
    /// it playing.
    landing,
    /// The thread's movie that follows the landing: from the game's folder, read whole
    /// (`hog_file_read`) and opened in memory (`BINKFROMMEMORY`), at the movie's rate, over the
    /// landing's last frame. It plays and ends as the landing does.
    thread,
    /// The movies of a screen that plays them in its own loop, which decides what ends them and
    /// what loops them: the rooms' (`vr_rooms`), a new pilot's induction's (`reliant_induction`)
    /// and the news report's (`news_report`). From the disc's archive, at 15 frames a second,
    /// whatever the settings.
    screen,
    /// The mission's movie, which the briefing plays on the briefing room's screen in its own loop
    /// (`interface_briefing`): from the disc's archive, at the movie's rate and full volume
    /// (`BinkSetVolume`, `0x00437527`), whatever the settings.
    briefing,
    /// The ITAC's movies, which it plays in its own loop, its sections' titles and text over them
    /// (`itac_movie_play`, `0x00440010`): from the game's folder, at 15 frames a second
    /// (`BinkSetFrameRate` and `BINKFRAMERATE`, `0x0044003F`), whatever the settings. Only Escape
    /// ends one.
    itac,

    /// Where it is read from.
    pub fn source(kind: Kind) Source {
        return switch (kind) {
            .cleared, .over_screen, .thread, .itac => .folder,
            .cleared_from_disc, .over_screen_from_disc, .landing, .screen, .briefing => .disc,
        };
    }

    /// The rate it plays at in place of its own (`BinkSetFrameRate` with `BINKFRAMERATE`).
    pub fn rate(kind: Kind) ?bink.Rate {
        return switch (kind) {
            .over_screen, .landing, .screen, .itac => transition_rate,
            .cleared, .cleared_from_disc, .over_screen_from_disc, .thread, .briefing => null,
        };
    }

    /// Whether it plays: the video settings' `Transitions` (`[Device]`, 1 unless set) leaves out
    /// the movies over the screen, and on a renderer that is not a hardware one, those on a cleared
    /// screen too (`sr + 0x15F8`, `sr + 0x1AC`). The landing's play whatever the settings.
    pub fn plays(kind: Kind, transitions: bool, hardware: bool) bool {
        return switch (kind) {
            .cleared, .cleared_from_disc => transitions or hardware,
            .over_screen, .over_screen_from_disc => transitions,
            .landing, .thread, .screen, .briefing, .itac => true,
        };
    }

    /// Whether the pointer's right button ends it, as Escape does.
    pub fn rightButtonEnds(kind: Kind) bool {
        return switch (kind) {
            .cleared, .over_screen, .cleared_from_disc, .over_screen_from_disc => true,
            .landing, .thread, .screen, .briefing, .itac => false,
        };
    }
};

/// Where a movie is read from.
pub const Source = enum {
    /// The game's folder: the file its name names.
    folder,
    /// The disc's archive open (`disc.Disc`): the member `hog_locate` finds, which Bink opens where
    /// it lies (`BINKFILEHANDLE`).
    disc,
};

/// How a movie's loop ends.
pub const End = enum {
    /// Its last frame shown.
    finished,
    /// Escape, or the pointer's right button where it ends the movie (`Kind.rightButtonEnds`).
    skipped,
};

/// How large a movie is drawn.
pub const Size = enum {
    /// **Improvement:** as large as fits in the window.
    fitted,
    /// At its size in the middle of the front end's screen, as the game draws it on a screen 640
    /// by 480.
    screen,
};

/// The rate `play_bink_movie_no_clear` plays at, whatever the movie's (`BinkSetFrameRate` with
/// `BINKFRAMERATE`, `0x004AB752`). Every player sets it, and `play_landing_movie` opens its landing
/// with `BINKFRAMERATE` at it.
pub const transition_rate: bink.Rate = .{ .frames = 15, .seconds = 1 };

/// The last mission the pilot flies from the Reliant (`0x004ABD50`): the hangar's movie is the
/// Reliant's up to it, from the second disc, and the Yamato's after it, from the first. The landing
/// takes the Yamato's from it on (`landing.onYamato`).
pub const last_from_reliant = 18;

/// A movie on a disc: its name in the disc's archive, which the game opens for it (`cd_hog_open`).
pub const OnDisc = struct {
    disc: disc.Number,
    name: []const u8,
};

/// `hangar_movie_play` (`0x004ABD40`): the movies `WinMain` plays before each mission it flies (not
/// the main menu's INSTANT ACTION, which runs its mission itself), unless a lobby launched the game
/// (`lobby_launch`, `0x00595C64`), as OpenReliant never is: the pilots readying in the Reliant's
/// hangar, or the Yamato's, each of three in turn.
pub const Hangar = struct {
    /// The one played last (`hangar_movie_last`, `0x005D6C8C`), which `WinMain` sets to the first
    /// as it opens the front end (`0x004A9587`), so that the second plays first.
    last: u2 = 0,

    /// The Reliant's and the Yamato's (`0x004ABD48` on).
    const reliant = [3][]const u8{ "r_h_ta.bik", "r_h_tb.bik", "r_h_tc.bik" };
    const yamato = [3][]const u8{ "y_h_ta.bik", "y_h_tb.bik", "y_h_tc.bik" };

    /// The movie before mission `mission`, the next of its three, which plays as
    /// `play_bink_movie_resourced` plays it (`Kind.cleared_from_disc`).
    pub fn next(hangar: *Hangar, mission: u16) OnDisc {
        hangar.last = (hangar.last + 1) % 3;
        return if (mission > last_from_reliant)
            .{ .disc = .one, .name = yamato[hangar.last] }
        else
            .{ .disc = .two, .name = reliant[hangar.last] };
    }
};

/// A movie playing, and the screen its frames are copied into.
pub const Player = struct {
    gpa: Allocator,
    kind: Kind,
    bink: bink.Bink,
    /// The frames, the movie's size, in RGBA (`BinkCopyToBuffer`), and its pixels, which the
    /// picture holds.
    picture: srtexture.Image,
    pixels: []u8,
    /// Whether its last frame has shown (`0x005D6C90`).
    ended: bool = false,
    /// The pointer's right button, which ends the movie only once it has come up since the movie
    /// began (`pass`).
    right: input.FreshPress = .{},

    /// Opens the movie of `file`, which it takes, to play as `kind` has it, its sound through
    /// `sound` where there is one, and its pictures with OpenReliant's `look`.
    pub fn open(gpa: Allocator, codec: bink.Codec, file: []const u8, kind: Kind, sound: ?mss.Driver, look: bink.Look) bink.Error!Player {
        var movie: bink.Bink = try .open(gpa, codec, file, .{ .rate = kind.rate(), .sound = sound, .look = look });
        errdefer movie.close();
        const rgba = try gpa.alloc(u8, @as(usize, movie.width) * movie.height * 4);
        @memset(rgba, 0);
        var picture = srtexture.Image.single(gpa, movie.width, movie.height, rgba) catch |err| {
            gpa.free(rgba);
            return err;
        };
        picture.magnify = .edge_adaptive;
        return .{ .gpa = gpa, .kind = kind, .bink = movie, .picture = picture, .pixels = rgba };
    }

    /// The movie `name`, read from where `kind` reads it, the game's folder or the disc's archive
    /// open (`archive`, whose folder is the game's), a mod's file of its name first
    /// (`bigfile.Mods`), and opened to play as `open` has it; null where it is left out, which the
    /// log says.
    pub fn load(gpa: Allocator, codec: bink.Codec, archive: *const disc.Disc, name: []const u8, kind: Kind, sound: ?mss.Driver, look: bink.Look) ?Player {
        const source = kind.source();
        const found = switch (source) {
            .folder => archive.mods.readLoose(archive.io, gpa, archive.directory, name, .limited(files.max_file_size)),
            .disc => archive.readStored(gpa, name),
        } catch |err| {
            log.warn("the movie {s} is left out: {s}", .{ name, @errorName(err) });
            return null;
        };
        const file = found orelse {
            log.warn("the movie {s} is left out: {s}", .{ name, switch (source) {
                .folder => "the game's folder has none",
                .disc => "no disc's archive open holds it",
            } });
            return null;
        };
        return open(gpa, codec, file, kind, sound, look) catch |err| {
            log.warn("the movie {s} is left out: {s}", .{ name, @errorName(err) });
            return null;
        };
    }

    pub fn close(player: *Player) void {
        player.picture.deinit(player.gpa);
        player.bink.close();
    }

    /// A pass of the loop at `now`, the keyboard read and whether the pointer's right button is
    /// down: how the movie ends, or null while it plays on.
    ///
    /// **Fix:** the right button ends a movie only once it has come up since the movie began. The
    /// game ends it while the button is down, so that a press that skipped what came before, still
    /// held, ends it at once.
    pub fn pass(player: *Player, keyboard: *input.Keyboard, right_down: bool, now: u64) bink.Error!?End {
        if (keyboard.pressed(input.scan.escape, .none, true)) return .skipped;
        if (player.ended) return .finished;
        if (player.right.pressed(right_down) and player.kind.rightButtonEnds()) return .skipped;
        if (player.bink.wait(now)) return null;
        try player.play(now);
        return null;
    }

    /// `bink_frame` (`0x004AC510`): the frame due shown, then the next one next, or the movie
    /// ended at its last.
    fn play(player: *Player, now: u64) bink.Error!void {
        try player.show(now);
        if (player.atEnd()) player.ended = true else player.bink.nextFrame();
    }

    /// The frame due decoded and copied into the picture (`BinkDoFrame`, `BinkCopyToBuffer`).
    pub fn show(player: *Player, now: u64) bink.Error!void {
        try player.bink.doFrame(now);
        player.bink.copyToBuffer(player.pixels, player.bink.width * 4, .{ 0, 0 });
        player.picture.changed = true;
    }

    /// Whether the frame shown last is the movie's last.
    pub fn atEnd(player: Player) bool {
        return player.bink.frame_number == player.bink.frames;
    }

    /// Draws the frame showing on `target`, a window `window` pixels across and down, as large as
    /// `how` has it, in the middle.
    pub fn draw(player: *Player, target: device.Device, window: [2]u32, how: Size) void {
        const size: [2]u32 = .{ player.bink.width, player.bink.height };
        const scale = switch (how) {
            .fitted => hud.fit(window, size),
            .screen => canvas.scaleFor(window),
        };
        hud.drawImage(target, &player.picture, hud.centred(window, size, scale), .{ 1, 1, 1, 1 }, scale, .{});
    }
};

test "a movie plays its frames as each falls due, and ends" {
    const gpa = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    const bytes = container.testing.movie(&buffer, 2, &.{});
    var codec: bink.testing.Decoders = .{};
    var player: Player = try .open(gpa, codec.codec(), try gpa.dupe(u8, bytes), .over_screen, null, .{});
    defer player.close();
    var keyboard: input.Keyboard = .{};
    // The first frame shows at once; the second when it is due, then the movie is over.
    try std.testing.expectEqual(null, try player.pass(&keyboard, false, 0));
    try std.testing.expectEqual(1, codec.pictures);
    try std.testing.expect(player.picture.changed);
    try std.testing.expectEqual(null, try player.pass(&keyboard, false, std.time.ns_per_s / 30));
    try std.testing.expectEqual(1, codec.pictures);
    try std.testing.expectEqual(null, try player.pass(&keyboard, false, std.time.ns_per_s / 15));
    try std.testing.expect(player.ended);
    try std.testing.expectEqual(End.finished, try player.pass(&keyboard, false, std.time.ns_per_s));
}

test "Escape and the right button end a movie" {
    const gpa = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    const bytes = container.testing.movie(&buffer, 5, &.{});
    var codec: bink.testing.Decoders = .{};
    var player: Player = try .open(gpa, codec.codec(), try gpa.dupe(u8, bytes), .cleared, null, .original);
    defer player.close();
    var keyboard: input.Keyboard = .{};
    // The right button held as it begins plays on; pressed once it has come up, it ends it.
    try std.testing.expectEqual(null, try player.pass(&keyboard, true, 0));
    try std.testing.expectEqual(null, try player.pass(&keyboard, false, 0));
    try std.testing.expectEqual(End.skipped, try player.pass(&keyboard, true, 0));
    try std.testing.expectEqual(1, codec.pictures);
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(End.skipped, try player.pass(&keyboard, false, 0));
}

test "the landing plays on with the right button down" {
    const gpa = std.testing.allocator;
    var buffer: [256]u8 = undefined;
    const bytes = container.testing.movie(&buffer, 5, &.{});
    var codec: bink.testing.Decoders = .{};
    var player: Player = try .open(gpa, codec.codec(), try gpa.dupe(u8, bytes), .landing, null, .{});
    defer player.close();
    var keyboard: input.Keyboard = .{};
    try std.testing.expectEqual(null, try player.pass(&keyboard, true, 0));
    try std.testing.expectEqual(1, codec.pictures);
    // At 15 frames a second, whatever the movie's rate.
    try std.testing.expectEqual(transition_rate, player.bink.rate);
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(End.skipped, try player.pass(&keyboard, true, 0));
}

test Kind {
    try std.testing.expect(Kind.over_screen.plays(true, false));
    try std.testing.expect(!Kind.over_screen.plays(false, true));
    try std.testing.expect(!Kind.over_screen_from_disc.plays(false, true));
    try std.testing.expect(Kind.cleared.plays(false, true));
    try std.testing.expect(!Kind.cleared.plays(false, false));
    try std.testing.expect(!Kind.cleared_from_disc.plays(false, false));
    try std.testing.expect(Kind.landing.plays(false, false));
    try std.testing.expect(Kind.thread.plays(false, false));
    // The disc's players read the archive; the thread's movie is a file of the game's folder.
    try std.testing.expectEqual(Source.disc, Kind.over_screen_from_disc.source());
    try std.testing.expectEqual(Source.folder, Kind.thread.source());
    // Only `play_bink_movie_no_clear` and the landing force the rate.
    try std.testing.expectEqual(null, Kind.over_screen_from_disc.rate());
    try std.testing.expectEqual(transition_rate, Kind.over_screen.rate().?);
    // The briefing's movie plays from the disc at its own rate, whatever the settings.
    try std.testing.expectEqual(Source.disc, Kind.briefing.source());
    try std.testing.expectEqual(null, Kind.briefing.rate());
    try std.testing.expect(Kind.briefing.plays(false, false));
}

test Hangar {
    var hangar: Hangar = .{};
    // The second of the Reliant's first, from the second disc, then the rest in turn.
    try std.testing.expectEqualDeep(OnDisc{ .disc = .two, .name = "r_h_tb.bik" }, hangar.next(1));
    try std.testing.expectEqualStrings("r_h_tc.bik", hangar.next(last_from_reliant).name);
    // Past mission 18, the Yamato's, from the first disc.
    try std.testing.expectEqualDeep(OnDisc{ .disc = .one, .name = "y_h_ta.bik" }, hangar.next(19));
    try std.testing.expectEqualStrings("y_h_tb.bik", hangar.next(24).name);
}
