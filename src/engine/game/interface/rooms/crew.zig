//! `vr_crew_pick` (`0x00437DF0`): the crew the rooms show on the way to the briefing room's door,
//! picked as the rooms open by how the mission before went. Each crew member is a sprite set of
//! pictures, a shape for each frame of the way's movie they show over, and a line, an MP3 file,
//! which plays as the player takes the way (`0x0043B4EF` on). On the Yamato a second crew member
//! shows after the first, without a line, the three of them in turn. The rooms' drawing shows them
//! over the movie (`vr_draw`, `0x0043C539` on).
//!
//! **Fix:** the mission before is the one the campaign came from. The game takes the number before
//! the rooms' mission, so that after missions 11, 16 and 21, each of which awards a medal, it reads
//! the records of missions 13, 17 and 22, which the campaign skips.
//!
//! **Fix:** how the mission before was rated is what the campaign's records keep of it. The game
//! reads the script's rating among the game's variables, which a saved game doesn't keep, so that
//! after a game loads the crew react to a failure.
//!
//! **Improvement:** the crew member is drawn from `std.Random`, where the game uses `rand()`.

const std = @import("std");

const mp3 = @import("../../../../formats/mp3.zig");
const wave = @import("../../../../formats/wave.zig");
const bink = @import("../../../bink.zig");
const gameflow = @import("../../gameflow.zig");
const hog_snd = @import("../../hog_snd.zig");
const canvas = @import("../canvas.zig");
const rooms = @import("../rooms.zig");

const log = std.log.scoped(.crew);

/// A crew member as the tables hold one (`0x30` bytes each): their sprite set, `%s.spr` of the
/// name at `+0x00`; the frame of the way's movie they show from (`+0x14`), and for how many
/// frames (`+0x18`); and their line, `%s.mp3` of the name at `+0x1C`, none for the Yamato's
/// second.
pub const Member = struct {
    set: []const u8,
    first: u32,
    frames: u32,
    line: ?[]const u8,
};

fn member(comptime name: []const u8, first: u32, frames: u32, comptime line: []const u8) Member {
    return .{ .set = name ++ ".spr", .first = first, .frames = frames, .line = line ++ ".mp3" };
}

/// How the mission before went, which picks the crew (`0x00437E33` on).
pub const Kind = enum {
    /// It awards a medal, or the pilot was promoted at its end.
    honoured,
    /// Its script rated it a failure, or a nanny ship picked the pilot up.
    failed,
    /// Any other rating.
    won,
};

/// Each carrier's crew by the kind (`0x00437E01` on): the Reliant's from `0x004E7DD8`,
/// `0x004E7E98` and `0x004E7FB8`, and the Yamato's from `0x004E7B58`, `0x004E7C48` and
/// `0x004E7D38`, as many as `0x004E7DC8` and `0x004E7B4C` count.
pub const crews = std.EnumArray(rooms.Carrier, std.EnumArray(Kind, []const Member)).init(.{
    .reliant = .init(.{
        .honoured = &.{
            member("rovh", 93, 89, "rm06p"),
            member("rovi", 93, 93, "rm07p"),
            member("rovk", 93, 96, "rm10p"),
            member("rovl", 93, 106, "rm11p"),
        },
        .failed = &.{
            member("rovm", 93, 98, "rm02n"),
            member("rovn", 93, 89, "rm04n"),
            member("rovo", 93, 106, "rm06n"),
            member("rovp", 93, 90, "rm09n"),
            member("rovq", 93, 98, "rm14n"),
            member("rovr", 93, 96, "rm15n"),
        },
        .won = &.{
            member("rovc", 93, 100, "rm01g"),
            member("rovd", 93, 92, "rm02g"),
            member("rove", 93, 93, "rm03g"),
            member("rovf", 93, 97, "rm04g"),
            member("rovg", 93, 105, "rm06g"),
        },
    }),
    .yamato = .init(.{
        .honoured = &.{
            member("yovg", 2, 64, "ym19p"),
            member("yovh", 2, 75, "ym20p"),
            member("yovj", 2, 82, "ym22p"),
            member("yovk", 2, 66, "ym23p"),
            member("yovl", 2, 82, "ym24p"),
        },
        .failed = &.{
            member("yovm", 2, 71, "ym19n"),
            member("yovn", 2, 80, "ym20n"),
            member("yovp", 2, 78, "ym22n"),
            member("yovq", 2, 101, "ym23n"),
            member("yovr", 2, 86, "ym24n"),
        },
        .won = &.{
            member("yovb", 2, 97, "ym20g"),
            member("yovc", 2, 116, "ym21g"),
            member("yovf", 2, 84, "ym24g"),
        },
    }),
});

/// The Yamato's second crew, who come in turn (`0x004E80A8`).
pub const seconds = [_]Member{
    .{ .set = "yovs.spr", .first = 117, .frames = 85, .line = null },
    .{ .set = "yovt.spr", .first = 117, .frames = 74, .line = null },
    .{ .set = "yovu.spr", .first = 117, .frames = 79, .line = null },
};

/// Which of the Yamato's second crew comes next (`yamato_crew_next`, `0x005202F4`): it goes round
/// as the rooms open, and outlasts them.
pub const Turn = struct {
    next: usize = 0,

    fn take(turn: *Turn) usize {
        const taken = turn.next;
        turn.next = (taken + 1) % seconds.len;
        return taken;
    }
};

/// The Yamato's way into the briefing room, which the crew show on, the second too (`0x004E8F78`).
const yamato_door = "bunk2wr.bik";

/// The Reliant's way to the briefing room's door, which the crew member shows on (`0x004E8F58`).
const reliant_door = "rel_bunkroom2briefing_door.bik";

/// The voice the line plays on (`0x0043B5A9`).
const line_voice = 2;

/// Where a crew member's shapes are drawn, in the palette of their set's block 0 (`0x0043C58F`).
const at: [2]i32 = .{ 1, 1 };
const palette_block = 0;

/// How the mission before mission `mission` went in `campaign` (`0x00437E33` on): its medal by the
/// table (`medal_of_mission`), whether or not it was awarded; then the pilot's promotion at its
/// end; then its rating, a failure or any other, and the pickup by a nanny ship. Before the first
/// mission, the game reads the first's own record, which is empty, and the rating the game's
/// variables start a campaign with, a partial failure (`campaign_new`).
pub fn kindOf(mission: u16, campaign: *const gameflow.Campaign) Kind {
    const before = gameflow.previousMission(mission) orelse mission;
    if (gameflow.Medal.of(before) != null) return .honoured;
    const record = campaign.kept(before);
    if (record.promotion != null) return .honoured;
    const rating = record.rating orelse campaign.variables.mission_success;
    if (rating == .failure or record.pickups != 0) return .failed;
    return .won;
}

/// A crew member the rooms show: their pictures (`crew_shapes`, `0x0051DA98`), from the frame of
/// the way's movie they show from (`crew_first`), for as many frames (`crew_frames`), while they
/// show (`crew_showing`); the Yamato's second's from `0x0051D498` on.
pub const Showing = struct {
    shapes: canvas.Shapes,
    first: u32,
    frames: u32,
    on: bool = false,

    /// The shape for the way's frame `frame` (`0x0043C542` on): none before their first frame,
    /// and past their last, where they stop showing.
    fn shapeAt(showing: *Showing, frame: u32) ?usize {
        if (frame < showing.first) return null;
        const into = frame - showing.first;
        if (into >= showing.frames) {
            showing.on = false;
            return null;
        }
        return into + 1;
    }
};

pub const Crew = struct {
    /// The crew member, and on the Yamato the second; none where their set is left out.
    shown: [2]?Showing = .{ null, null },
    /// The first's line, decoded into a WAVE file (`crew_line`, `0x0051DAA8`); empty where it is
    /// left out.
    line: []u8 = &.{},

    /// `vr_crew_pick` before mission `mission` in `campaign`, drawn from `random`: a crew member of
    /// the carrier's for how the mission before went, their set and their line from the disc, and
    /// on the Yamato the second, whose turn goes on. What is missing is left out, which the log
    /// says.
    pub fn pick(context: rooms.Context, mission: u16, campaign: *const gameflow.Campaign, random: std.Random, turn: *Turn) Crew {
        const carrier: rooms.Carrier = .of(mission);
        const kind = kindOf(mission, campaign);
        const members = crews.get(carrier).get(kind);
        const first = members[random.uintLessThan(usize, members.len)];
        var crew: Crew = .{};
        crew.shown[0] = show(context, first);
        if (first.line) |line| crew.line = readLine(context, line) orelse &.{};
        switch (carrier) {
            .reliant => {},
            .yamato => crew.shown[1] = show(context, seconds[turn.take()]),
        }
        return crew;
    }

    pub fn deinit(crew: *Crew, gpa: std.mem.Allocator) void {
        for (&crew.shown) |*held| if (held.*) |*showing| showing.shapes.deinit(gpa);
        gpa.free(crew.line);
        crew.* = .{};
    }

    /// The way taken, into a view whose movie is `movie` (`0x0043B4EF` on): the Yamato's way into
    /// the briefing room starts both crew members showing, and the Reliant's to its door the first;
    /// either plays the line, as does any way taken while the first still shows.
    pub fn take(crew: *Crew, sound: *hog_snd.Sound, movie: []const u8) void {
        if (std.mem.eql(u8, movie, yamato_door)) {
            crew.setOn(0);
            crew.setOn(1);
        } else if (std.mem.eql(u8, movie, reliant_door)) {
            crew.setOn(0);
        } else if (!crew.on(0)) return;
        if (crew.line.len > 0) sound.speakOn(line_voice, crew.line);
    }

    fn setOn(crew: *Crew, index: usize) void {
        if (crew.shown[index]) |*showing| showing.on = true;
    }

    fn on(crew: Crew, index: usize) bool {
        const showing = crew.shown[index] orelse return false;
        return showing.on;
    }

    /// The crew members showing over the way's movie at its frame `frame` (`0x0043C539` on), each
    /// at their shape for it; past their last frame they stop showing.
    pub fn draw(crew: *Crew, target: canvas.Canvas, frame: u32) canvas.Error!void {
        for (&crew.shown) |*held| {
            const showing = &(held.* orelse continue);
            if (!showing.on) continue;
            const shape = showing.shapeAt(frame) orelse continue;
            try target.shape(&showing.shapes.art, shape, at);
        }
    }
};

/// A crew member's set of pictures from the disc, in its block 0's palette; null where it is left
/// out, which the log says.
fn show(context: rooms.Context, chosen: Member) ?Showing {
    var shapes = context.readShapes(chosen.set) orelse return null;
    shapes.usePalette(palette_block);
    // Drawn over the way's frame, which the game copies into the frame drawn first, their pixels
    // of index 0 show black, as `VFX_shape_draw` writes them.
    shapes.art.index_zero = .drawn;
    return .{ .shapes = shapes, .first = chosen.first, .frames = chosen.frames };
}

/// The line `name` from the disc as a WAVE file (`decode`); null where it is left out, which the
/// log says.
fn readLine(context: rooms.Context, name: []const u8) ?[]u8 {
    const bytes = context.read(name) orelse return null;
    defer context.gpa.free(bytes);
    return decode(context.gpa, context.codec, bytes) catch |err| {
        log.warn("{s} is left out: {s}", .{ name, @errorName(err) });
        return null;
    };
}

/// The MP3 file `bytes`, its frames (`formats/mp3.zig`) decoded by `codec`'s MP3 decoder into a
/// WAVE file at the first frame's rate and channels.
fn decode(gpa: std.mem.Allocator, codec: bink.Codec, bytes: []const u8) (bink.Error || error{NoFrames})![]u8 {
    var frames: mp3.Frames = .init(bytes);
    const opening = frames.next() orelse return error.NoFrames;
    const stream = try codec.openMp3();
    defer codec.close(stream);
    var pcm: std.ArrayList(i16) = .empty;
    defer pcm.deinit(gpa);
    var frame: ?mp3.Frame = opening;
    while (frame) |decoded| : (frame = frames.next()) try codec.samples(stream, decoded.bytes, gpa, &pcm);
    return wave.pcm16(gpa, opening.header.rate, opening.header.channels, pcm.items);
}

test kindOf {
    var campaign: gameflow.Campaign = .begin();
    // A new campaign's first rooms: the rating the variables start with, a partial failure.
    try std.testing.expectEqual(Kind.won, kindOf(1, &campaign));
    campaign.variables.mission_success = .success;
    // After a mission that awards a medal, whatever its rating.
    try std.testing.expectEqual(Kind.honoured, kindOf(7, &campaign));
    // After the Black Eagle's mission 11, the campaign goes on to 14: honoured too.
    try std.testing.expectEqual(Kind.honoured, kindOf(14, &campaign));
    // After a promotion; after a pickup by a nanny ship; and after a success.
    campaign.record(3).?.promotion = 1;
    try std.testing.expectEqual(Kind.honoured, kindOf(4, &campaign));
    campaign.record(4).?.pickups = 1;
    try std.testing.expectEqual(Kind.failed, kindOf(5, &campaign));
    try std.testing.expectEqual(Kind.won, kindOf(3, &campaign));
    // A failure, and any other rating, the partial failure's among them.
    campaign.variables.mission_success = .failure;
    try std.testing.expectEqual(Kind.failed, kindOf(3, &campaign));
    campaign.variables.mission_success = .partial_failure;
    try std.testing.expectEqual(Kind.won, kindOf(3, &campaign));
    // A game loaded clears the variables' rating, but the records keep mission 2's success.
    campaign.variables.mission_success = .failure;
    campaign.record(2).?.rating = .success;
    try std.testing.expectEqual(Kind.won, kindOf(3, &campaign));
}

test Turn {
    var turn: Turn = .{};
    for ([_]usize{ 0, 1, 2, 0 }) |expected| try std.testing.expectEqual(expected, turn.take());
}

test "the crew's tables" {
    // The counts the game keeps, and every member's line but the second's.
    try std.testing.expectEqual(4, crews.get(.reliant).get(.honoured).len);
    try std.testing.expectEqual(6, crews.get(.reliant).get(.failed).len);
    try std.testing.expectEqual(5, crews.get(.reliant).get(.won).len);
    try std.testing.expectEqual(5, crews.get(.yamato).get(.honoured).len);
    try std.testing.expectEqual(5, crews.get(.yamato).get(.failed).len);
    try std.testing.expectEqual(3, crews.get(.yamato).get(.won).len);
    try std.testing.expectEqualStrings("rm06p.mp3", crews.get(.reliant).get(.honoured)[0].line.?);
    for (seconds) |second| try std.testing.expectEqual(null, second.line);
}

test Crew {
    const gpa = std.testing.allocator;
    const hog = @import("../../../../formats/hog.zig");
    const spr = @import("../../../../formats/spr.zig");
    const set = try spr.testing.paletteAndShape(gpa);
    defer gpa.free(set);
    // Every set and line of the Reliant's crew after a won mission: a picture, and two frames of
    // MP3.
    const frame = [_]u8{ 0xFF, 0xF3, 0x80, 0x7C } ++ [_]u8{0} ** 204;
    const line = frame ++ frame;
    const won = comptime crews.get(.reliant).get(.won);
    var files: [2 * won.len]hog.Member = undefined;
    for (won, 0..) |chosen, n| {
        files[2 * n] = .{ .name = chosen.set, .data = set };
        files[2 * n + 1] = .{ .name = chosen.line.?, .data = &line };
    }
    var tested: rooms.testing.Tested = undefined;
    try tested.init(&.{}, &files, &.{});
    defer tested.deinit();
    var campaign: gameflow.Campaign = .begin();
    campaign.variables.mission_success = .success;
    var prng: std.Random.DefaultPrng = .init(0);
    var turn: Turn = .{};
    var crew: Crew = .pick(tested.context(), 3, &campaign, prng.random(), &turn);
    defer crew.deinit(gpa);
    // One crew member on the Reliant, the second's turn not taken, and the line's two frames as a
    // WAVE file.
    const showing = &crew.shown[0].?;
    try std.testing.expectEqual(null, crew.shown[1]);
    try std.testing.expectEqual(0, turn.next);
    try std.testing.expectEqual(22050, (try wave.Wave.parse(crew.line)).rate);

    // Another way taken shows nothing; the way to the door shows the crew, and the line plays on
    // voice 2, held.
    crew.take(&tested.sound, "rel_c2lock.bik");
    try std.testing.expect(!showing.on and !tested.sound.voicePlaying(line_voice));
    crew.take(&tested.sound, reliant_door);
    try std.testing.expect(showing.on and tested.sound.voicePlaying(line_voice));
    try std.testing.expectEqual(1, tested.sound.voices[line_voice].held);
    // Shape 1 from the way's frame 93, as many frames as the record says, then none.
    try std.testing.expectEqual(93, showing.first);
    try std.testing.expectEqual(null, showing.shapeAt(92));
    try std.testing.expectEqual(1, showing.shapeAt(93));
    try std.testing.expectEqual(showing.frames, showing.shapeAt(93 + showing.frames - 1));
    try std.testing.expectEqual(null, showing.shapeAt(93 + showing.frames));
    try std.testing.expect(!showing.on);
}
