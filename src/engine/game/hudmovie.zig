//! `C:\lancer\game\hudmovie.cpp`: the face films the radio's window plays as a line is said
//! (`Movie`), from `pilots\pilots.hog`, decoded by [`talkie.zig`](talkie.zig) as a timer asks for
//! their frames ([face films](../../../docs/formats/fm8.md)).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.radio);

const hog = @import("../../formats/hog.zig");
const bigfile = @import("bigfile.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const talkie = @import("talkie.zig");
const ticks_per_second = @import("main.zig").ticks_per_second;

/// Where the films come from (`hudmovie_init`, `0x0048D030`): `pilots\pilots.hog`, whose members
/// are the films under their file names. The game stops with a fatal error where it cannot open it.
pub const archive_path = "pilots/pilots.hog";

/// The film of a dead channel (`hudmovie_static`, `0x0050276C`), which plays on once a line's film
/// is over while the line goes on, where the film holds for it (`Flags.hold`).
pub const static_film = "pilots\\static.fm8";

/// The last mission the 45th fly as the 45th Volunteers, and the films that change with the
/// squadron's name: the Volunteers', and in the same order the Tigers' (`hudmovie_play`'s tables
/// from `0x005026AC` and from `0x00502754`).
pub const last_volunteers_mission = 13;
pub const volunteers = [_][]const u8{
    "pilots\\45volntrs_plt.fm8",   "pilots\\45volntrs_plt_l.fm8",   "pilots\\45volntrs_plt_d.fm8",
    "pilots\\45Volntrs_Moose.fm8", "pilots\\45Volntrs_Moose_l.fm8", "pilots\\45Volntrs_Moose_d.fm8",
};
pub const tigers = [_][]const u8{
    "pilots\\45tigers_plt.fm8",   "pilots\\45tigers_plt_l.fm8",   "pilots\\45tigers_plt_d.fm8",
    "pilots\\45Tigers_Moose.fm8", "pilots\\45Tigers_Moose_l.fm8", "pilots\\45Tigers_Moose_d.fm8",
};

comptime {
    assert(volunteers.len == tigers.len);
}

/// How a film plays (`hudmovie_play`'s second argument, `hudmovie_flags`, `0x0057C39C`).
pub const Flags = packed struct(u32) {
    /// It plays again from its start at its end.
    loop: bool = false,
    /// At its end, while the line is still heard, the dead channel's film plays in its place
    /// (`static_film`), and once the line is over the window closes.
    hold: bool = false,
    /// It is drawn in its own palette, as every film the game plays is. **Unknown:** the palette the
    /// window would draw one without it in (`0x0057BF5C`).
    own_palette: bool = false,
    /// It starts no line: the dead channel's film, which plays on while the line goes on.
    silent: bool = false,
    _unknown_4: u28 = 0,

    /// What the radio's commands and reports play a film with: looping, while the line plays.
    pub const looping: Flags = .{ .loop = true, .own_palette = true };
    /// What the commands' `Once` forms play a film with: once, then the dead channel's film while
    /// the line goes on.
    pub const once: Flags = .{ .hold = true, .own_palette = true };
    /// The dead channel's film's (`hudmovie_timer`, `0x0048D4A5`).
    pub const static: Flags = .{ .loop = true, .own_palette = true, .silent = true };

    comptime {
        assert(@as(u32, @bitCast(looping)) == 5);
        assert(@as(u32, @bitCast(once)) == 6);
        assert(@as(u32, @bitCast(static)) == 0xD);
    }
};

/// The film `hudmovie_play` (`0x0048D23A`) plays for `name` in mission `mission`: through mission
/// `last_volunteers_mission` a film of the 45th Tigers' as the 45th Volunteers', and after it the
/// reverse, the names compared without regard to case.
pub fn squadronFilm(name: []const u8, mission: u16) []const u8 {
    const from: []const []const u8, const to: []const []const u8 = if (mission > last_volunteers_mission) .{ &volunteers, &tigers } else .{ &tigers, &volunteers };
    for (from, to) |was, becomes| {
        if (std.ascii.eqlIgnoreCase(name, was)) return becomes;
    }
    return name;
}

/// The member of `pilots.hog` a film's path names: the name from its last backslash on
/// (`hudmovie_play`, `0x0048D2CA`).
pub fn memberName(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return path;
    return path[at + 1 ..];
}

/// The film the radio's window plays: `hudmovie.cpp`'s globals.
pub const Movie = struct {
    gpa: Allocator,
    /// `pilots_hog` (`0x0057C3B4`); null where it cannot be opened, which leaves the window
    /// without films but for the mods'.
    archive: ?hog.Archive = null,
    /// OpenReliant's: the mods, whose films come before the archive's (`bigfile.Mods`).
    mods: *const bigfile.Mods = &bigfile.Mods.none,
    /// The film playing, as `pilots.hog` holds it, its chunks unscrambled once as it starts, and
    /// which of them the timer decodes next; the game reads each from the archive as it comes
    /// (`hudmovie_file`, `0x0057C290`, from `hudmovie_start`, `0x0057C27C`).
    bytes: []u8 = &.{},
    chunks: std.ArrayList(talkie.Chunk) = .empty,
    next: usize = 0,
    /// Its decoder (`hudmovie_state`, `0x0057C280`).
    film: talkie.Film,
    flags: Flags = .{},
    /// `hudmovie_playing` (`0x0057C3A8`).
    playing: bool = false,
    /// Set while the line said with the film waits for the window to open (`0x0057C298`), which
    /// holds the film at its first frame, and the ticks it has waited (`0x0057C3AC`), which the
    /// display counts (`videoreports.Radio.waitForWindow`).
    waiting: bool = false,
    waited: i32 = 0,
    /// The timer's time toward its next turn, in the game's ticks times `talkie.frames_per_second`.
    timer: u32 = 0,
    /// Whether a film has failed to decode since it started, which is told once.
    failed: bool = false,
    /// The frame the window draws (`hudmovie_image`, `0x0057C3BC`), in the film's colours, and its
    /// image.
    rgba: []u8 = &.{},
    level: [1]srtexture.Level = undefined,
    picture: srtexture.Image = .{ .levels = &.{} },

    /// `hudmovie_init` (`0x0048D030`): the films from `archive_path` in `dir`, or none where it
    /// cannot be opened.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) Movie {
        return .openAt(gpa, io, dir, archive_path);
    }

    /// The films from the archive at `path` in `dir`.
    ///
    /// **Fix:** the game stops with a fatal error where it cannot open the archive; OpenReliant
    /// plays the radio's lines without their films.
    pub fn openAt(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Movie {
        const archive = hog.Archive.open(gpa, io, dir, path) catch |err| none: {
            log.warn("the radio's films are left out: {s} cannot be opened: {s}", .{ path, @errorName(err) });
            break :none null;
        };
        return .{ .gpa = gpa, .archive = archive, .film = .init(gpa) };
    }

    /// `hudmovie_shutdown` (`0x0048D0C0`).
    pub fn deinit(movie: *Movie) void {
        movie.stop();
        movie.chunks.deinit(movie.gpa);
        if (movie.archive) |*archive| archive.close(movie.gpa);
        movie.gpa.free(movie.rgba);
        movie.* = .{ .gpa = movie.gpa, .film = .init(movie.gpa) };
    }

    /// `hudmovie_play` (`0x0048D120`): plays the film at `path`, `pilots\<film>.fm8`, as `flags`
    /// say, in mission `mission`'s squadron (`squadronFilm`), its first frame decoded. Returns
    /// whether the line said with it starts at once: where a film was playing already, unless
    /// `flags.silent`. Otherwise the line waits for the window to open (`waiting`).
    ///
    /// **Fix:** the game stops with a fatal error where `pilots.hog` lacks the film, as it does six
    /// the pilots' faces name; OpenReliant plays the dead channel's film in its place.
    pub fn play(movie: *Movie, path: []const u8, flags: Flags, mission: u16) bool {
        const now = movie.playing and !flags.silent;
        if (movie.playing) {
            movie.playing = false;
            movie.waiting = false;
        } else {
            movie.waiting = true;
            movie.waited = 0;
        }
        movie.flags = flags;
        const chosen = squadronFilm(path, mission);
        movie.load(chosen) catch |err| {
            log.warn("the radio's film {s} is left out: {s}", .{ chosen, @errorName(err) });
            movie.load(static_film) catch return now;
        };
        movie.failed = false;
        movie.next = 0;
        _ = movie.advance();
        movie.playing = true;
        return now;
    }

    /// The film at `path` read from the archive, its chunks up to the end chunk unscrambled, in
    /// place of the one before.
    fn load(movie: *Movie, path: []const u8) !void {
        const bytes = try movie.read(path);
        errdefer movie.gpa.free(bytes);
        var chunks: std.ArrayList(talkie.Chunk) = .empty;
        errdefer chunks.deinit(movie.gpa);
        var reading: talkie.Chunks = .{ .bytes = bytes };
        while (reading.next()) |chunk| {
            if (chunk.id == .end) break;
            try chunks.append(movie.gpa, chunk);
        }
        if (chunks.items.len == 0) return error.NoFrames;
        movie.release();
        movie.bytes = bytes;
        movie.chunks = chunks;
    }

    /// The film at `path` as it is stored, a mod's of its name first (`bigfile.Mods.readStored`),
    /// then the archive's (`hog_seek`).
    fn read(movie: *Movie, path: []const u8) ![]u8 {
        const name = memberName(path);
        if (try movie.mods.readStored(movie.gpa, name)) |bytes| return bytes;
        const archive = movie.archive orelse return error.NoArchive;
        const entry = archive.find(name) orelse return error.NotInArchive;
        return archive.readRaw(movie.gpa, entry);
    }

    /// The film's bytes and chunks let go of.
    fn release(movie: *Movie) void {
        movie.gpa.free(movie.bytes);
        movie.bytes = &.{};
        movie.chunks.deinit(movie.gpa);
        movie.chunks = .empty;
        movie.next = 0;
    }

    /// `hudmovie_stop` (`0x0048D420`): the film stops, its decoder and its frames let go of.
    pub fn stop(movie: *Movie) void {
        movie.playing = false;
        movie.film.deinit();
        movie.release();
    }

    /// The next chunk decoded, and a frame it gives copied into the window's (`picture`); false at
    /// the film's end.
    fn advance(movie: *Movie) bool {
        if (movie.next >= movie.chunks.items.len) return false;
        const chunk = movie.chunks.items[movie.next];
        movie.next += 1;
        const decoded = movie.film.decode(chunk) catch |err| {
            if (!movie.failed) log.warn("a frame of the radio's film cannot be decoded: {s}", .{@errorName(err)});
            movie.failed = true;
            return true;
        };
        if (decoded) movie.show() catch |err| log.warn("the radio's film cannot be shown: {s}", .{@errorName(err)});
        return true;
    }

    /// The frame decoded last, in the film's palette, into `picture`, which is made again for a
    /// frame of another size. Every pixel is drawn, the see-through colour among them, as the game
    /// draws them.
    fn show(movie: *Movie) Allocator.Error!void {
        const pixels = movie.film.frame();
        const width: u32 = @intCast(movie.film.width);
        const height: u32 = @intCast(movie.film.height);
        if (movie.rgba.len != pixels.len * 4) {
            movie.rgba = try movie.gpa.realloc(movie.rgba, pixels.len * 4);
            movie.level = .{.{ .width = width, .height = height, .rgba = movie.rgba }};
            movie.picture = .{ .levels = &movie.level };
        } else if (movie.level[0].width != width) {
            movie.level = .{.{ .width = width, .height = height, .rgba = movie.rgba }};
            movie.picture = .{ .levels = &movie.level };
        }
        for (pixels, 0..) |index, at| {
            const colour = movie.film.palette[@as(usize, index) * 3 ..][0..3];
            movie.rgba[at * 4 ..][0..4].* = .{ colour[0], colour[1], colour[2], 0xFF };
        }
        movie.picture.changed = true;
    }

    /// What a turn of the timer comes to.
    pub const Turn = enum {
        /// Nothing more than a frame shown, or none.
        shown,
        /// The film held for its line, which is over: it has stopped, and the window closes.
        over,
    };

    /// `hudmovie_timer` (`0x0048D460`), a turn of the film's timer while the game is not paused and
    /// a film plays whose line is not waiting for the window: the next frame decoded. At the
    /// film's end, a film that holds for its line stops where the line is over (`Turn.over`), or
    /// gives way to the dead channel's film where it is not; one that loops, the dead channel's
    /// among them, plays again from its first frame.
    ///
    /// **Fix:** the game frees the film and then reads on from it where one both holds and loops,
    /// which none does; OpenReliant stops it.
    pub fn turn(movie: *Movie, speaking: bool, mission: u16) Turn {
        if (!movie.playing or movie.waiting) return .shown;
        if (movie.advance()) return .shown;
        if (movie.flags.hold) {
            if (!speaking) {
                movie.stop();
                return .over;
            }
            _ = movie.play(static_film, .static, mission);
        }
        if (!movie.flags.loop) return .shown;
        movie.next = 0;
        _ = movie.advance();
        return .shown;
    }

    /// The timer's turns for a frame of `ticks` of the game's clock: `talkie.frames_per_second`
    /// turns a second, which stand still while the game is paused. Whether a film has stopped with
    /// its line over, and the window is to close.
    pub fn run(movie: *Movie, ticks: u32, speaking: bool, mission: u16) bool {
        movie.timer += ticks * talkie.frames_per_second;
        var over = false;
        while (movie.timer >= ticks_per_second) {
            movie.timer -= ticks_per_second;
            if (movie.turn(speaking, mission) == .over) over = true;
        }
        return over;
    }
};

/// A `pilots.hog` of films built by hand, for the tests: `films`, each a key frame of `size` by
/// `size` pixels of one colour, as many as `frames` says.
pub const testing = struct {
    pub const Film = struct { name: []const u8, frames: usize, colour: u8 };

    pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, films: []const Film) !void {
        var members: std.ArrayList(hog.Member) = .empty;
        defer {
            for (members.items) |member| gpa.free(member.data);
            members.deinit(gpa);
        }
        for (films) |film| try members.append(gpa, .{ .name = film.name, .data = try filmBytes(gpa, film.frames, film.colour) });
        try hog.testing.write(gpa, io, dir, path, members.items);
    }

    /// A film of `frames` key frames of 4 by 4 pixels, all entry 1 of a palette whose entry 1 is
    /// grey `colour`, then the end chunk.
    fn filmBytes(gpa: Allocator, frames: usize, colour: u8) ![]u8 {
        var palette: talkie.Palette = @splat(0);
        @memset(palette[3..6], colour);
        const pixels: [16]u8 = @splat(1);
        const payload = try talkie.testing.keyPayload(gpa, 4, 4, &palette, &pixels);
        defer gpa.free(payload);
        const key = try talkie.testing.chunk(gpa, "fYEK", payload);
        defer gpa.free(key);
        const end = try talkie.testing.chunk(gpa, "fDNE", "");
        defer gpa.free(end);
        const bytes = try gpa.alloc(u8, key.len * frames + end.len);
        for (0..frames) |i| @memcpy(bytes[i * key.len ..][0..key.len], key);
        @memcpy(bytes[key.len * frames ..], end);
        return bytes;
    }
};

test squadronFilm {
    // Through mission 13 the 45th are the Volunteers, and after it the Tigers, whichever the film
    // names.
    try std.testing.expectEqualStrings("pilots\\45volntrs_plt.fm8", squadronFilm("pilots\\45Tigers_Plt.fm8", 1));
    try std.testing.expectEqualStrings("pilots\\45Tigers_Moose_d.fm8", squadronFilm("pilots\\45Volntrs_Moose_D.fm8", 14));
    try std.testing.expectEqualStrings("pilots\\45Tigers_Plt.fm8", squadronFilm("pilots\\45Tigers_Plt.fm8", 14));
    try std.testing.expectEqualStrings("pilots\\BUCC.fm8", squadronFilm("pilots\\BUCC.fm8", 1));
}

test memberName {
    try std.testing.expectEqualStrings("BUCC.fm8", memberName("pilots\\BUCC.fm8"));
    try std.testing.expectEqualStrings("static.fm8", memberName("static.fm8"));
}

test Movie {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.write(gpa, io, tmp.dir, "pilots.hog", &.{
        .{ .name = "BUCC.fm8", .frames = 3, .colour = 0x40 },
        .{ .name = "static.fm8", .frames = 2, .colour = 0x80 },
    });
    var movie: Movie = .openAt(gpa, io, tmp.dir, "pilots.hog");
    defer movie.deinit();

    // Started with none playing, a film waits with its line for the window, at its first frame.
    try std.testing.expect(!movie.play("pilots\\BUCC.fm8", .once, 1));
    try std.testing.expect(movie.playing and movie.waiting);
    try std.testing.expectEqual(1, movie.next);
    try std.testing.expectEqual([4]u8{ 0x40, 0x40, 0x40, 0xFF }, movie.rgba[0..4].*);
    try std.testing.expect(movie.picture.changed);
    // It stands still while it waits.
    try std.testing.expect(!movie.run(100, true, 1));
    try std.testing.expectEqual(1, movie.next);
    movie.waiting = false;

    // Fifteen turns a second: a frame each 20 ticks of 3.
    try std.testing.expect(!movie.run(6, true, 1));
    try std.testing.expectEqual(1, movie.next);
    try std.testing.expect(!movie.run(1, true, 1));
    try std.testing.expectEqual(2, movie.next);
    // Once over, while its line goes on, the dead channel's film plays in its place, and loops.
    _ = movie.run(14, true, 1);
    try std.testing.expectEqual(Flags.static, movie.flags);
    try std.testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0xFF }, movie.rgba[0..4].*);
    _ = movie.run(40, true, 1);
    try std.testing.expect(movie.playing);
    // Another film said now, with one playing, starts its line at once.
    try std.testing.expect(movie.play("pilots\\BUCC.fm8", .once, 1));
    try std.testing.expect(!movie.waiting);
    // Over with its line over, it stops, and the window closes.
    try std.testing.expect(movie.run(40, false, 1));
    try std.testing.expect(!movie.playing);

    // A film the archive lacks plays as the dead channel's.
    _ = movie.play("pilots\\nobody.fm8", .looping, 1);
    try std.testing.expect(movie.playing);
    try std.testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0xFF }, movie.rgba[0..4].*);
    movie.stop();
    try std.testing.expect(!movie.playing);
}
