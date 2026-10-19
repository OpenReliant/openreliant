//! `C:\lancer\game\hudmovie.cpp`: the face films the radio's window plays as a line is said
//! (`Movie`), from `pilots\pilots.hog`, decoded by [`talkie.zig`](talkie.zig) as a timer asks for
//! their frames ([face films](../../../docs/formats/fm8.md)). OpenReliant's game keeps the film
//! and its timer, and drawing decodes its frames as far as the timer has come (`Picture`).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.radio);

const hog = @import("../../formats/hog.zig");
const bigfile = @import("bigfile.zig");
const srtexture = @import("../surrender/surrenderlib/srtexture.zig");
const talkie = @import("talkie.zig");
const Event = @import("table.zig").Event;
const ticks_per_second = @import("main.zig").ticks_per_second;

/// Where the films come from (`hudmovie_init`, `0x0048D030`): `pilots\pilots.hog`, whose members
/// are the films under their file names. The game stops with a fatal error where it cannot open it.
pub const archive_path = "pilots/pilots.hog";

/// The film of a dead channel (`hudmovie_static`, `0x0050276C`), which plays on once a line's film
/// is over while the line goes on, where the film holds for it (`Flags.hold`).
pub const static_film = "pilots\\static.fm8";

/// The name the 45th fly under, which picks the version of their films (`squadronFilm`): the 45th
/// Volunteers', or the 45th Flying Tigers' in a mission whose rules say so
/// (`gameflow.CampaignMission.Rules.flying_tigers`, after mission 13 in the original).
pub const Squadron = enum { volunteers, flying_tigers };

/// The films that change with the squadron's name: the Volunteers', and in the same order the
/// Tigers' (`hudmovie_play`'s tables from `0x005026AC` and from `0x00502754`).
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

/// The film `hudmovie_play` (`0x0048D23A`) plays for `name` while the 45th fly as `squadron`: a
/// film of the 45th Tigers' as the 45th Volunteers', or the reverse, the names compared without
/// regard to case.
pub fn squadronFilm(name: []const u8, squadron: Squadron) []const u8 {
    const from: []const []const u8, const to: []const []const u8 = switch (squadron) {
        .volunteers => .{ &tigers, &volunteers },
        .flying_tigers => .{ &volunteers, &tigers },
    };
    for (from, to) |was, becomes| {
        if (std.ascii.eqlIgnoreCase(name, was)) return becomes;
    }
    return name;
}

/// The member of `pilots.hog` a film's path names: what follows its first backslash
/// (`hudmovie_play`, `0x0048D2CA`).
///
/// **Fix:** the game takes the character after the first backslash without checking there is one,
/// so a path without a backslash reads from address 1 and crashes. OpenReliant takes the whole
/// path.
pub fn memberName(path: []const u8) []const u8 {
    const at = std.mem.findScalar(u8, path, '\\') orelse return path;
    return path[at + 1 ..];
}

/// The film the radio's window plays: `hudmovie.cpp`'s globals, as far as the game keeps them. The
/// game decodes each frame as its timer comes to it; OpenReliant's drawing does (`Picture`).
pub const Movie = struct {
    gpa: Allocator,
    /// `pilots_hog` (`0x0057C3B4`); null if it can't be opened, which leaves the window without
    /// films except those from mods.
    archive: ?hog.Archive = null,
    /// Added by OpenReliant: the mods, whose films take priority over the archive's
    /// (`bigfile.Mods`).
    mods: *const bigfile.Mods = &bigfile.Mods.none,
    /// The film playing, as `pilots.hog` holds it, its chunks unscrambled once as it starts, and
    /// which of them the timer comes to next; the game reads each from the archive as it comes
    /// (`hudmovie_file`, `0x0057C290`, from `hudmovie_start`, `0x0057C27C`).
    bytes: []u8 = &.{},
    chunks: std.ArrayList(talkie.Chunk) = .empty,
    next: usize = 0,
    /// The films played (`play`), and the times a film has looped (`turn`), after each of which
    /// drawing decodes the film from its first chunk again (`Picture.follow`).
    plays: Event = .{},
    loops: Event = .{},
    flags: Flags = .{},
    /// `hudmovie_playing` (`0x0057C3A8`).
    playing: bool = false,
    /// Set while the line said with the film waits for the window to open (`0x0057C298`), which
    /// holds the film at its first frame, and the ticks it has waited (`0x0057C3AC`), which the
    /// display counts (`radio.Radio.waitForWindow`).
    waiting: bool = false,
    waited: i32 = 0,
    /// The timer's time toward its next turn, in the game's ticks times `talkie.frames_per_second`.
    timer: u32 = 0,

    /// `hudmovie_init` (`0x0048D030`): the films from `archive_path` in `dir`, or none where it
    /// cannot be opened.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) Movie {
        return .openAt(gpa, io, dir, archive_path);
    }

    /// The films from the archive at `path` in `dir`, found in any case (`bigfile.openArchive`).
    ///
    /// **Fix:** the game stops with a fatal error where it cannot open the archive; OpenReliant
    /// plays the radio's lines without their films.
    pub fn openAt(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) Movie {
        const archive = bigfile.openArchive(gpa, io, dir, path) catch |err| none: {
            log.warn("the radio's films are left out: {s} cannot be opened: {s}", .{ path, @errorName(err) });
            break :none null;
        };
        return .{ .gpa = gpa, .archive = archive };
    }

    /// `hudmovie_shutdown` (`0x0048D0C0`).
    pub fn deinit(movie: *Movie) void {
        movie.stop();
        movie.chunks.deinit(movie.gpa);
        if (movie.archive) |*archive| archive.close(movie.gpa);
        movie.* = .{ .gpa = movie.gpa };
    }

    /// `hudmovie_play` (`0x0048D120`): plays the film at `path` (`pilots\<film>.fm8`) as `flags`
    /// say, in the version for the squadron's name, `squadron` (`squadronFilm`), and comes to its
    /// first frame. Returns whether the line spoken with it starts at once, which it does when a
    /// film was already playing, unless `flags.silent`. Otherwise the line waits for the window to
    /// open (`waiting`).
    ///
    /// **Fix:** the game stops with a fatal error when `pilots.hog` lacks the film, and it lacks six
    /// films that the pilots' faces name. OpenReliant plays the dead channel's film in its place,
    /// and logs it when that film is missing too.
    pub fn play(movie: *Movie, path: []const u8, flags: Flags, squadron: Squadron) bool {
        const now = movie.playing and !flags.silent;
        if (movie.playing) {
            movie.playing = false;
            movie.waiting = false;
        } else {
            movie.waiting = true;
            movie.waited = 0;
        }
        movie.flags = flags;
        const chosen = squadronFilm(path, squadron);
        movie.load(chosen) catch |err| {
            log.warn("the radio's film {s} is left out: {s}", .{ chosen, @errorName(err) });
            movie.load(static_film) catch |static_err| {
                log.warn("the dead channel's film {s} is left out too: {s}", .{ static_film, @errorName(static_err) });
                return now;
            };
        };
        movie.next = 0;
        movie.plays.happen();
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

    /// Reads the film at `path` as stored, from a mod if one has a file with its name
    /// (`bigfile.Mods.readStored`), otherwise from the archive (`hog_seek`).
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

    /// `hudmovie_stop` (`0x0048D420`): the film stops, and its chunks are let go of. The game lets
    /// go of its decoder and its frames too, which OpenReliant's drawing keeps (`Picture`).
    pub fn stop(movie: *Movie) void {
        movie.playing = false;
        movie.release();
    }

    /// The timer on to the next chunk, which the game decodes as it comes to it (`Picture`); false
    /// at the film's end.
    fn advance(movie: *Movie) bool {
        if (movie.next >= movie.chunks.items.len) return false;
        movie.next += 1;
        return true;
    }

    /// What a turn of the timer comes to.
    pub const Turn = enum {
        /// Nothing more than a frame shown, or none.
        shown,
        /// The film held for its line, which is over: it has stopped, and the window closes.
        over,
    };

    /// `hudmovie_timer` (`0x0048D460`), a turn of the film's timer while the game is not paused and
    /// a film plays whose line is not waiting for the window: on to the next frame. At the film's
    /// end, a film that holds for its line stops where the line is over (`Turn.over`), or gives way
    /// to the dead channel's film where it is not; one that loops, the dead channel's among them,
    /// plays again from its first frame.
    ///
    /// **Fix:** the game frees the film and then reads on from it where one both holds and loops,
    /// which none does; OpenReliant stops it.
    pub fn turn(movie: *Movie, speaking: bool, squadron: Squadron) Turn {
        if (!movie.playing or movie.waiting) return .shown;
        if (movie.advance()) return .shown;
        if (movie.flags.hold) {
            if (!speaking) {
                movie.stop();
                return .over;
            }
            _ = movie.play(static_film, .static, squadron);
        }
        if (!movie.flags.loop) return .shown;
        movie.next = 0;
        movie.loops.happen();
        _ = movie.advance();
        return .shown;
    }

    /// The timer's turns for a frame of `ticks` of the game's clock: `talkie.frames_per_second`
    /// turns a second, which stand still while the game is paused. Whether a film has stopped with
    /// its line over, and the window is to close.
    pub fn run(movie: *Movie, ticks: u32, speaking: bool, squadron: Squadron) bool {
        movie.timer += ticks * talkie.frames_per_second;
        var over = false;
        while (movie.timer >= ticks_per_second) {
            movie.timer -= ticks_per_second;
            if (movie.turn(speaking, squadron) == .over) over = true;
        }
        return over;
    }
};

/// The radio's face film as drawing decodes it, with a decoder of its own: it follows the game's
/// film (`Movie`) as far as the game's timer has come, and keeps the frame the window draws
/// (`picture`).
pub const Picture = struct {
    gpa: Allocator,
    /// The decoder (`hudmovie_state`, `0x0057C280`).
    film: talkie.Film,
    /// The films played and the loops it has taken up (`Movie.plays`, `Movie.loops`), and how many
    /// of the film's chunks it has decoded since.
    plays: Event.Seen = .{},
    loops: Event.Seen = .{},
    decoded: usize = 0,
    /// Whether a frame has failed to decode since the film was played, which is told once.
    failed: bool = false,
    /// The frame the window draws (`hudmovie_image`, `0x0057C3BC`), in the film's colours, and its
    /// image.
    rgba: []u8 = &.{},
    level: [1]srtexture.Level = .{.{ .width = 0, .height = 0, .texels = &.{} }},
    picture: srtexture.Image = .{ .levels = &.{} },

    pub fn init(gpa: Allocator) Picture {
        return .{ .gpa = gpa, .film = .init(gpa) };
    }

    /// Lets go of the decoder and the frame, and hands its texture back to the device.
    pub fn deinit(picture: *Picture) void {
        picture.picture.releaseTexture();
        picture.film.deinit();
        picture.gpa.free(picture.rgba);
        picture.* = .init(picture.gpa);
    }

    /// Decodes the game's film from where drawing left it up to the chunk the game's timer has come
    /// to (`Movie.next`), and shows the last frame decoded. A film played or looped since is
    /// decoded from its first chunk, which is a key frame in every film, so the frame is the one
    /// the game decodes.
    pub fn follow(picture: *Picture, movie: *const Movie) void {
        const played = picture.plays.takeUp(movie.plays);
        const looped = picture.loops.takeUp(movie.loops);
        if (played) picture.failed = false;
        if (played or looped) picture.decoded = 0;
        if (!movie.playing) return;
        const chunks = movie.chunks.items;
        var shown = false;
        while (picture.decoded < @min(movie.next, chunks.len)) : (picture.decoded += 1) {
            const made = picture.film.decode(chunks[picture.decoded]) catch |err| {
                if (!picture.failed) log.warn("a frame of the radio's film cannot be decoded: {s}", .{@errorName(err)});
                picture.failed = true;
                continue;
            };
            shown = shown or made;
        }
        if (shown) picture.show() catch |err| log.warn("the radio's film cannot be shown: {s}", .{@errorName(err)});
    }

    /// The frame decoded last, in the film's palette, into `picture`, which is made again for a
    /// frame of another size, its old texture handed back to the device. Every pixel is drawn, the
    /// see-through colour among them, as the game draws them.
    fn show(picture: *Picture) Allocator.Error!void {
        const film = &picture.film;
        const pixels = film.frame();
        const width: u32 = @intCast(film.width);
        const height: u32 = @intCast(film.height);
        const resized = picture.rgba.len != pixels.len * 4;
        if (resized or picture.level[0].width != width) {
            picture.picture.releaseTexture();
            if (resized) picture.rgba = try picture.gpa.realloc(picture.rgba, pixels.len * 4);
            picture.level = .{.{ .width = width, .height = height, .texels = picture.rgba }};
            picture.picture = .{ .levels = &picture.level };
        }
        for (pixels, 0..) |index, at| {
            const colour = film.palette[@as(usize, index) * 3 ..][0..3];
            picture.rgba[at * 4 ..][0..4].* = .{ colour[0], colour[1], colour[2], 0xFF };
        }
        picture.picture.changed = true;
    }
};

/// A `pilots.hog` of films built by hand, for the tests: `films`, each of key frames of one colour.
pub const testing = struct {
    /// A film of `frames` key frames, `side` by `side` pixels each, all grey `colour`.
    pub const Film = struct { name: []const u8, frames: usize, colour: u8, side: u8 = 4 };

    pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, films: []const Film) !void {
        var members: std.ArrayList(hog.Member) = .empty;
        defer {
            for (members.items) |member| gpa.free(member.data);
            members.deinit(gpa);
        }
        for (films) |film| try members.append(gpa, .{ .name = film.name, .data = try filmBytes(gpa, film) });
        try hog.testing.write(gpa, io, dir, path, members.items);
    }

    /// The film's key frames, every pixel entry 1 of a palette whose entry 1 is its grey, then the
    /// end chunk.
    fn filmBytes(gpa: Allocator, film: Film) ![]u8 {
        var palette: talkie.Palette = @splat(0);
        @memset(palette[3..6], film.colour);
        const pixels = try gpa.alloc(u8, @as(usize, film.side) * film.side);
        defer gpa.free(pixels);
        @memset(pixels, 1);
        const payload = try talkie.testing.keyPayload(gpa, film.side, film.side, &palette, pixels);
        defer gpa.free(payload);
        const key = try talkie.testing.chunk(gpa, "fYEK", payload);
        defer gpa.free(key);
        const end = try talkie.testing.chunk(gpa, "fDNE", "");
        defer gpa.free(end);
        const bytes = try gpa.alloc(u8, key.len * film.frames + end.len);
        for (0..film.frames) |i| @memcpy(bytes[i * key.len ..][0..key.len], key);
        @memcpy(bytes[key.len * film.frames ..], end);
        return bytes;
    }
};

test squadronFilm {
    // The squadron's own film plays, whichever the film names.
    try std.testing.expectEqualStrings("pilots\\45volntrs_plt.fm8", squadronFilm("pilots\\45Tigers_Plt.fm8", .volunteers));
    try std.testing.expectEqualStrings("pilots\\45Tigers_Moose_d.fm8", squadronFilm("pilots\\45Volntrs_Moose_D.fm8", .flying_tigers));
    try std.testing.expectEqualStrings("pilots\\45Tigers_Plt.fm8", squadronFilm("pilots\\45Tigers_Plt.fm8", .flying_tigers));
    try std.testing.expectEqualStrings("pilots\\BUCC.fm8", squadronFilm("pilots\\BUCC.fm8", .volunteers));
}

test memberName {
    try std.testing.expectEqualStrings("BUCC.fm8", memberName("pilots\\BUCC.fm8"));
    try std.testing.expectEqualStrings("static.fm8", memberName("static.fm8"));
    // What follows the first backslash, as `hudmovie_play` cuts it.
    try std.testing.expectEqualStrings("sub\\x.fm8", memberName("pilots\\sub\\x.fm8"));
}

test Movie {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The archive is found in any case.
    try testing.write(gpa, io, tmp.dir, "PILOTS.HOG", &.{
        .{ .name = "BUCC.fm8", .frames = 3, .colour = 0x40 },
        .{ .name = "static.fm8", .frames = 2, .colour = 0x80 },
    });
    var movie: Movie = .openAt(gpa, io, tmp.dir, "pilots.hog");
    defer movie.deinit();

    // Started with none playing, a film waits with its line for the window, at its first frame.
    try std.testing.expect(!movie.play("pilots\\BUCC.fm8", .once, .volunteers));
    try std.testing.expect(movie.playing and movie.waiting);
    try std.testing.expectEqual(1, movie.next);
    try std.testing.expectEqual(1, movie.plays.count);
    // It stands still while it waits.
    try std.testing.expect(!movie.run(100, true, .volunteers));
    try std.testing.expectEqual(1, movie.next);
    movie.waiting = false;

    // Fifteen turns a second: a frame each 20 ticks of 3.
    try std.testing.expect(!movie.run(6, true, .volunteers));
    try std.testing.expectEqual(1, movie.next);
    try std.testing.expect(!movie.run(1, true, .volunteers));
    try std.testing.expectEqual(2, movie.next);
    // Once over, while its line goes on, the dead channel's film plays in its place, and loops.
    _ = movie.run(14, true, .volunteers);
    try std.testing.expectEqual(Flags.static, movie.flags);
    try std.testing.expectEqual(2, movie.plays.count);
    _ = movie.run(40, true, .volunteers);
    try std.testing.expect(movie.playing);
    try std.testing.expectEqual(4, movie.loops.count);
    // Another film said now, with one playing, starts its line at once.
    try std.testing.expect(movie.play("pilots\\BUCC.fm8", .once, .volunteers));
    try std.testing.expect(!movie.waiting);
    // Over with its line over, it stops, and the window closes.
    try std.testing.expect(movie.run(40, false, .volunteers));
    try std.testing.expect(!movie.playing);

    // A film the archive lacks plays as the dead channel's.
    _ = movie.play("pilots\\nobody.fm8", .looping, .volunteers);
    try std.testing.expect(movie.playing);
    try std.testing.expectEqual(2, movie.chunks.items.len);
    movie.stop();
    try std.testing.expect(!movie.playing);
}

test Picture {
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
    var picture: Picture = .init(gpa);
    defer picture.deinit();

    // Drawing decodes the film's first frame once the game plays it.
    _ = movie.play("pilots\\BUCC.fm8", .once, .volunteers);
    picture.follow(&movie);
    try std.testing.expectEqual(1, picture.decoded);
    try std.testing.expectEqual([4]u8{ 0x40, 0x40, 0x40, 0xFF }, picture.rgba[0..4].*);
    try std.testing.expect(picture.picture.changed);
    // It catches up with however many frames the timer has come on since.
    movie.waiting = false;
    _ = movie.run(14, true, .volunteers);
    picture.follow(&movie);
    try std.testing.expectEqual(3, picture.decoded);
    // The dead channel's film, played and looped in its place, is decoded from its first frame.
    _ = movie.run(14, true, .volunteers);
    picture.follow(&movie);
    try std.testing.expectEqual(movie.next, picture.decoded);
    try std.testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0xFF }, picture.rgba[0..4].*);
    // A film that has stopped is left where it was.
    movie.stop();
    picture.follow(&movie);
    try std.testing.expectEqual([4]u8{ 0x80, 0x80, 0x80, 0xFF }, picture.rgba[0..4].*);
}

test "a film of another size hands its texture back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.write(gpa, io, tmp.dir, "pilots.hog", &.{
        .{ .name = "small.fm8", .frames = 1, .colour = 0x40 },
        .{ .name = "large.fm8", .frames = 1, .colour = 0x40, .side = 8 },
    });
    var drawn: srtexture.testing.Device = .{};
    {
        var movie: Movie = .openAt(gpa, io, tmp.dir, "pilots.hog");
        defer movie.deinit();
        var picture: Picture = .init(gpa);
        defer picture.deinit();
        // The window draws the film, which the device makes a texture of.
        _ = movie.play("pilots\\small.fm8", .once, .volunteers);
        picture.follow(&movie);
        drawn.make(&picture.picture);
        // Another film of its size keeps the texture; one of another size hands it back.
        _ = movie.play("pilots\\small.fm8", .once, .volunteers);
        picture.follow(&movie);
        try std.testing.expectEqual(0, drawn.released);
        _ = movie.play("pilots\\large.fm8", .once, .volunteers);
        picture.follow(&movie);
        try std.testing.expectEqual(1, drawn.released);
        try std.testing.expectEqual(8, picture.picture.width());
        drawn.make(&picture.picture);
    }
    // Shut down, it hands back the texture it holds.
    try std.testing.expectEqual(0, drawn.held());
}
