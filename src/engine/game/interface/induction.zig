//! A new pilot's induction (`reliant_induction`, `0x00438D50`), as a campaign starts from mission
//! 1: Enriquez shows the pilot round the Reliant's rooms, a scene of hers at each place, before the
//! rooms open. `WinMain` plays the new pilot's intro before it, and after it the way from where it
//! ended into the rooms (`after`).
//!
//! The induction opens with the way from the bunk to the television (`opening`), then plays each
//! place's movie over and over as Enriquez speaks its scene (`stops`). As a scene ends, or on
//! Space, the way to the next place plays (`Step.way`); Escape or the pointer's right button ends
//! the induction where it is. Its drawing (`induction_draw`, `0x00439330`) shows the movie alone.

const std = @import("std");

const input = @import("../../input.zig");
const cbox = @import("../cbox.zig");
const canvas = @import("canvas.zig");
const rooms = @import("rooms.zig");

/// The movies the induction opens with (`0x00438DCD` on), from the disc: down the ladder from the
/// bunk, and on to the television.
pub const opening = [_][]const u8{ "rel_ladd_bunk.bik", "rel_t2l.bik", "rel_c_tv.bik" };

/// The places Enriquez shows the pilot, in order, each named by her scene there: the television,
/// the locker, the simulator pod, the CD player, the ITAC, and the television again. The number of
/// each is the count of ways taken to it (the loop's `EBP`), which `reliant_induction` returns.
pub const Place = enum(u8) {
    intro,
    locker,
    simulator,
    cd_player,
    itac,
    outro,

    fn next(place: Place) ?Place {
        return if (place == .outro) null else @enumFromInt(@intFromEnum(place) + 1);
    }
};

/// What plays at a place: its movie, over and over, and Enriquez's scene there, `%s.bik` and
/// `%s.box` of their names; and the movies of the way on to the next place, or from the last to
/// the room's middle.
pub const Stop = struct {
    movie: []const u8,
    scene: []const u8,
    way: []const []const u8,
};

/// Each place's (`0x004E8E0C`, `0x004E8D98`, then the tables at `0x00438D65` on; the ways,
/// `0x00439093` on).
pub const stops = std.EnumArray(Place, Stop).init(.{
    .intro = .{ .movie = "rel_tv_enriq.bik", .scene = "enr_intro.box", .way = &.{ "rel_tv_c.bik", "rel_c2lock.bik" } },
    .locker = .{ .movie = "single_rel_c2lock.bik", .scene = "enr_locker.box", .way = &.{ "rel_lock2c.bik", "rel_t2itac.bik", "rel_itac2pod.bik" } },
    .simulator = .{ .movie = "rel_podmon_loop.bik", .scene = "enr_simpod.box", .way = &.{"rel_pod2cd.bik"} },
    .cd_player = .{ .movie = "rel_cdloop.bik", .scene = "enr_cd.box", .way = &.{ "rel_cd2pod.bik", "rel_pod2itac.bik" } },
    .itac = .{ .movie = "rel_itacloop.bik", .scene = "enr_itac.box", .way = &.{ "rel_itac2t.bik", "rel_t2l.bik", "rel_c_tv.bik" } },
    .outro = .{ .movie = "rel_tv_enriq.bik", .scene = "enr_outro.box", .way = &.{"rel_tv_c.bik"} },
});

/// Where the rooms open after the induction: the movies played from where it ended first, and the
/// view.
pub const After = struct {
    way: []const []const u8,
    view: u8,
};

/// Where `WinMain` opens the rooms after an induction that ended at `place` (`0x004AA262` on): the
/// simulator pod's view, turned to from the CD player where it ended there, else from the ITAC.
pub fn after(place: Place) After {
    const pod_from_itac = rooms.entryView(.reliant_pod_from_itac);
    return switch (place) {
        .intro, .outro => .{ .way = &.{ "rel_l2t.bik", "rel_t2itac.bik" }, .view = pod_from_itac },
        .locker => .{ .way = &.{ "rel_lock2c.bik", "rel_t2itac.bik" }, .view = pod_from_itac },
        .simulator => .{ .way = &.{"rel_pod2itac.bik"}, .view = pod_from_itac },
        .cd_player => .{ .way = &.{}, .view = rooms.entryView(.reliant_pod_from_cd_player) },
        .itac => .{ .way = &.{}, .view = pod_from_itac },
    };
}

/// What a pass reads: the keyboard, the pointer's right button, and now, in nanoseconds.
pub const Input = struct {
    keyboard: *input.Keyboard,
    right: bool,
    now: u64,
};

/// What a pass leads to.
pub const Step = union(enum) {
    /// The way to the next place, which the caller plays (`play_bink_movie_no_clear_resourced`),
    /// then `arrive`.
    way: []const []const u8,
    /// The induction over at the place it ended at.
    over: Place,
};

/// The induction, as `reliant_induction` runs it.
pub const Induction = struct {
    context: rooms.Context,
    /// The place Enriquez speaks at.
    place: Place = .intro,
    film: rooms.Film = .{},
    speech: cbox.Player = .{},
    /// The pointer's right button, which ends the induction only once it has come up since the
    /// place was shown.
    ///
    /// **Fix:** the game ends it while the button is down, so that the press that skipped the way
    /// to a place, still held, ends the induction there at once.
    right: input.FreshPress = .{},

    /// The induction at its first place, after `opening`, at `now`.
    pub fn open(context: rooms.Context, now: u64) Induction {
        var induction: Induction = .{ .context = context };
        induction.show(now);
        return induction;
    }

    pub fn close(induction: *Induction) void {
        induction.speech.stop(induction.context.gpa, induction.context.sound);
        induction.film.close();
    }

    /// The place's movie, its first frame shown and looping, and its scene spoken.
    fn show(induction: *Induction, now: u64) void {
        const stop = stops.get(induction.place);
        induction.film.open(induction.context, stop.movie, .screen);
        induction.film.show(now);
        induction.film.loops = true;
        rooms.speak(induction.context, &induction.speech, stop.scene);
        induction.right = .{};
    }

    /// A pass of the induction's loop (`0x00438FDA` on), `in` read: Escape or the pointer's right
    /// button ends it; as the scene ends, or on Space, the way on to the next place.
    pub fn pass(induction: *Induction, in: Input) ?Step {
        const keyboard = in.keyboard;
        if (keyboard.pressed(input.scan.escape, .none, true) or induction.right.pressed(in.right)) {
            induction.close();
            return .{ .over = induction.place };
        }
        const on = !induction.speech.playing(induction.context.sound) or keyboard.pressed(@intFromEnum(input.Key.space), .none, true);
        if (!on) return null;
        induction.speech.stop(induction.context.gpa, induction.context.sound);
        induction.film.close();
        return .{ .way = stops.get(induction.place).way };
    }

    /// Once the way has played, at `now`: the next place, or after the last's, the induction over
    /// there.
    pub fn arrive(induction: *Induction, now: u64) ?Place {
        induction.place = induction.place.next() orelse return induction.place;
        induction.show(now);
        return null;
    }

    /// The drawing's movie, at `now` (`0x00439353` on): the frame due shown, and at the last, back
    /// to the second.
    pub fn advance(induction: *Induction, now: u64) void {
        if (induction.film.advance(now)) induction.film.loopBack(now);
    }

    /// `induction_draw` (`0x00439330`), the induction's drawing: its movie alone.
    pub fn draw(induction: *Induction, target: canvas.Canvas) void {
        induction.film.draw(target);
    }
};

test after {
    // Each place leaves the pilot turned to the simulator pod, from the CD player where the
    // induction ended there, else from the ITAC.
    for (std.enums.values(Place)) |place| {
        const next = after(place);
        try std.testing.expectEqual(if (place == .cd_player) rooms.entryView(.reliant_pod_from_cd_player) else rooms.entryView(.reliant_pod_from_itac), next.view);
    }
    try std.testing.expectEqualStrings("rel_pod2itac.bik", after(.simulator).way[0]);
}

test Induction {
    const gpa = std.testing.allocator;
    const scene = try cbox.testFile(gpa, 100, 64);
    defer gpa.free(scene);
    var tested: rooms.testing.Tested = undefined;
    try tested.init(&.{ "rel_tv_enriq.bik", "single_rel_c2lock.bik" }, &.{.{ .name = "enr_intro.box", .data = scene }}, &.{});
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};

    // Enriquez speaks at the television while its movie plays over and over.
    var induction: Induction = .open(tested.context(), 0);
    defer induction.close();
    try std.testing.expect(induction.speech.playing(&tested.sound));
    for (0..8) |frame| {
        const now = frame * std.time.ns_per_s / 15;
        try std.testing.expectEqual(null, induction.pass(.{ .keyboard = &keyboard, .right = false, .now = now }));
        induction.advance(now);
    }
    try std.testing.expect(induction.film.player != null);
    // As her scene ends, the way to the locker, then the locker, whose scene is left out.
    var out: [512][2]f32 = undefined;
    tested.mixer.mix(&out);
    const way = induction.pass(.{ .keyboard = &keyboard, .right = false, .now = 0 }).?.way;
    try std.testing.expectEqualStrings("rel_c2lock.bik", way[1]);
    try std.testing.expectEqual(null, induction.arrive(0));
    try std.testing.expectEqual(.locker, induction.place);
    try std.testing.expect(induction.film.player != null and !induction.speech.playing(&tested.sound));
    // Escape ends it there.
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(Step{ .over = .locker }, induction.pass(.{ .keyboard = &keyboard, .right = false, .now = 0 }).?);
    // After the last place's way, it is over there.
    induction.place = .outro;
    try std.testing.expectEqual(.outro, induction.arrive(0).?);
}

test "the right button held as a place shows ends the induction once it has come up" {
    const gpa = std.testing.allocator;
    const scene = try cbox.testFile(gpa, 100, 64);
    defer gpa.free(scene);
    var tested: rooms.testing.Tested = undefined;
    try tested.init(&.{"rel_tv_enriq.bik"}, &.{.{ .name = "enr_intro.box", .data = scene }}, &.{});
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var induction: Induction = .open(tested.context(), 0);
    defer induction.close();
    try std.testing.expectEqual(null, induction.pass(.{ .keyboard = &keyboard, .right = true, .now = 0 }));
    try std.testing.expectEqual(null, induction.pass(.{ .keyboard = &keyboard, .right = false, .now = 0 }));
    try std.testing.expectEqual(Step{ .over = .intro }, induction.pass(.{ .keyboard = &keyboard, .right = true, .now = 0 }).?);
}
