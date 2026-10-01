//! `cd_player` (`0x00437FC0`) and its drawing (`0x00438890`): the CD player, which Use CD player
//! opens in the Reliant's rooms and the Yamato's (`rooms.Place.cd_player`). It runs in a loop of its
//! own over a picture of the player, and plays the game's music from a list of twelve pieces, each
//! carrier its own: a click on a row chooses a piece and a second plays it, and the buttons play,
//! pause, stop and step through the list, repeat a piece or play the list at random, turn the
//! volume up and down, and leave. The music goes on in the rooms after it, without their reverb, as
//! any music plays.
//!
//! **Fix:** every piece comes from the list shown. The game takes the Yamato's list for PLAY
//! SELECTED TRACK alone, and the Reliant's for the rows, the next and previous tracks and the piece
//! that follows one's end, so that on the Yamato these play the Reliant's piece in the row.
//!
//! **Fix:** the CD player's volume is the level its music plays at, which the music volume and the
//! master volume scale as they scale any music. The game plays each piece at full level and sets
//! the stream to the CD player's volume itself, past the two volumes, so that a press of either
//! button made the music louder at the music volume's default.

const std = @import("std");

const hog = @import("../../../formats/hog.zig");
const hog_snd = @import("../hog_snd.zig");
const hud = @import("../hud.zig");
const input = @import("../../input.zig");
const itac = @import("../itac.zig");
const matmanager = @import("../matmanager.zig");
const canvas_module = @import("canvas.zig");
const rooms = @import("rooms.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;

/// The pictures behind it (`0x00438363`): the Reliant's bunk's player up to mission 18
/// (`0x004E8B34`), and the Yamato's after it (`0x004E8B50`).
const reliant_picture = "\\interface\\rel_bunk2cd.tga";
const yamato_picture = "\\interface\\brd2cd.tga";

/// What it reads from `resource.hog` as it opens: its shapes (`0x004E8B28`), and the ITAC's large
/// font, which its title is written in (`0x004E8320`).
pub const shapes_name = "cdplay.spr";
const title_font_name = itac.large_font_name;

/// The CD player's volume (`0x004E5B88`), from 0 to 127, which lasts while the game runs: full as
/// it starts, and turned a step each pass its buttons are held.
pub const Volume = u7;
pub const full_volume: Volume = hog_snd.loudest;

/// A piece of the list: the file it plays (`music\%s.wav`, `0x004E8B18`) and the string that
/// names it.
pub const Track = struct {
    path: []const u8,
    name: u16,
};

fn track(comptime file: []const u8, name: u16) Track {
    return .{ .path = std.fmt.comptimePrint("music\\{s}.wav", .{file}), .name = name };
}

/// The pieces of each list.
pub const track_count = 12;

/// Each carrier's list: the files (`0x00438261` on, `0x004382E1` on), and their names, Spirit of
/// War to The Catalyst on the Reliant (`0x319` on, `0x004389CD` on) and Final Word to The Rise on
/// the Yamato (`0x531` on, `0x00438A51` on). The Yamato's last plays the Reliant's first piece.
pub const tracks = std.EnumArray(rooms.Carrier, [track_count]Track).init(.{
    .reliant = .{
        track("new_mission01", 0x319),
        track("new_mission02", 0x31A),
        track("new_mission03", 0x31B),
        track("new_mission04", 0x31C),
        track("new_mission05", 0x31D),
        track("new_mission06", 0x31E),
        track("new_mission10", 0x31F),
        track("New_Searching Mission 01", 0x320),
        track("New_Searching Mission 03", 0x321),
        track("New_Searching Mission 05", 0x322),
        track("New_Searching Mission 06", 0x323),
        track("New_Searching Mission 10", 0x324),
    },
    .yamato = .{
        track("New_Sim01", 0x531),
        track("New_Sim02", 0x532),
        track("New_Sim04", 0x533),
        track("New_Sim05", 0x534),
        track("New_Sim07", 0x535),
        track("New_Sim08", 0x536),
        track("New_Sim10", 0x537),
        track("new_launch", 0x538),
        track("New_Takeoff - Music", 0x539),
        track("new_victory", 0x53A),
        track("new_defeat", 0x53B),
        track("new_mission01", 0x53C),
    },
});

/// The buttons, in the order of the rectangles `interface_hit` reads.
pub const Button = enum {
    play,
    pause,
    stop,
    next,
    previous,
    repeat,
    shuffle,
    leave,
    volume_up,
    volume_down,

    /// Whether the pointer over it lights it (`0x00438B0C`): every button but REPEAT TRACK MODE
    /// and RANDOM TRACK MODE, which light while they are on.
    fn lightsUnderPointer(button: Button) bool {
        return switch (button) {
            .repeat, .shuffle => false,
            .play, .pause, .stop, .next, .previous, .leave, .volume_up, .volume_down => true,
        };
    }
};

/// A button: where the pointer finds it, inside its rectangle, its edges left out (`0x00437FD1`
/// on); the shape of `cdplay.spr` that lights it and where it is drawn (`0x004388B9` on); and the
/// string that names it, PLAY SELECTED TRACK to CD VOLUME DOWN (`0x00438987` on).
pub const Item = struct {
    rect: Rect,
    lit: u8,
    lit_at: [2]i32,
    name: u16,
};

pub const buttons = std.EnumArray(Button, Item).init(.{
    .play = .{ .rect = .{ .x = 564, .y = 124, .width = 50, .height = 43 }, .lit = 3, .lit_at = .{ 571, 134 }, .name = 0x2F6 },
    .pause = .{ .rect = .{ .x = 562, .y = 170, .width = 56, .height = 27 }, .lit = 4, .lit_at = .{ 571, 174 }, .name = 0x2F7 },
    .stop = .{ .rect = .{ .x = 562, .y = 199, .width = 55, .height = 26 }, .lit = 5, .lit_at = .{ 571, 204 }, .name = 0x2F8 },
    .next = .{ .rect = .{ .x = 562, .y = 227, .width = 55, .height = 27 }, .lit = 6, .lit_at = .{ 571, 231 }, .name = 0x2F9 },
    .previous = .{ .rect = .{ .x = 562, .y = 256, .width = 56, .height = 27 }, .lit = 7, .lit_at = .{ 571, 259 }, .name = 0x2FA },
    .repeat = .{ .rect = .{ .x = 562, .y = 285, .width = 55, .height = 26 }, .lit = 8, .lit_at = .{ 571, 288 }, .name = 0x2FB },
    .shuffle = .{ .rect = .{ .x = 562, .y = 314, .width = 56, .height = 26 }, .lit = 9, .lit_at = .{ 571, 316 }, .name = 0x2FC },
    .leave = .{ .rect = .{ .x = 562, .y = 343, .width = 54, .height = 38 }, .lit = 10, .lit_at = .{ 571, 354 }, .name = 0x2FD },
    .volume_up = .{ .rect = .{ .x = 21, .y = 341, .width = 56, .height = 22 }, .lit = 1, .lit_at = .{ 29, 345 }, .name = 0x2FE },
    .volume_down = .{ .rect = .{ .x = 21, .y = 363, .width = 56, .height = 22 }, .lit = 2, .lit_at = .{ 29, 368 }, .name = 0x2FF },
});

/// The list's rows, where the pointer finds a piece after the buttons (`0x004380E5` on): 400 by 14
/// from (117, 176), each 16 below the last.
const row_corner: [2]i16 = .{ 0x75, 0xB0 };
const row_size: [2]i16 = .{ 0x190, 0xE };
const row_spacing = 0x10;

/// What lies under the pointer (`0x0051D564`): a button, or a row of the list.
pub const Hotspot = union(enum) {
    button: Button,
    row: usize,
};

/// The rectangles `interface_hit` reads, the buttons' and then the rows'.
const hotspots = blk: {
    var all: [buttons.values.len + track_count]Rect = undefined;
    for (all[0..buttons.values.len], buttons.values) |*rect, item| rect.* = item.rect;
    for (all[buttons.values.len..], 0..) |*rect, row| rect.* = .{
        .x = row_corner[0],
        .y = row_corner[1] + @as(i16, row) * row_spacing,
        .width = row_size[0],
        .height = row_size[1],
    };
    break :blk all;
};

/// What lies under the point `at`, the first of `hotspots` that holds it (`interface_hit`).
pub fn hotspotAt(at: [2]i32) ?Hotspot {
    const index = canvas_module.hit(&hotspots, at) orelse return null;
    if (index < buttons.values.len) return .{ .button = std.enums.values(Button)[index] };
    return .{ .row = index - buttons.values.len };
}

/// The title, CD PLAYER, in the ITAC's large font, and the list, in the front end's small font: the
/// rows' numbers and names, in blue, the piece chosen in white (`0x00438B91` on).
const title = 0x3B4;
const title_at: [2]i32 = .{ 0x75, 0x81 };
const list_colour = hud.rgb(0x0079FE);
const number_x = 0x75;
const name_x = 0x89;
const first_line = 0xAB;

/// The rows' numbers, `%02d` of each from 1 (`0x004E8CF0`).
const numbers = blk: {
    var all: [track_count][]const u8 = undefined;
    for (&all, 1..) |*number, n| number.* = std.fmt.comptimePrint("{d:0>2}", .{n});
    break :blk all;
};

/// The pointer, shape 12 of `cdplay.spr` (`0x00438D1D`).
const pointer_shape = 0xC;

/// What the CD player reads and plays with.
pub const Context = struct {
    rooms: rooms.Context,
    /// The rooms' steps and doors, which a press sounds from.
    steps: rooms.Steps = .{},
    /// The CD player's volume, which outlasts it.
    volume: *Volume,
};

/// A pass's input.
pub const Input = struct {
    keyboard: *input.Keyboard,
    pointer: canvas_module.Pointer,
};

pub const CdPlayer = struct {
    context: Context,
    /// The carrier whose list it shows.
    carrier: rooms.Carrier,
    picture: matmanager.Background = .{},
    /// Its shapes, each drawn with the palette before it in the set, as the drawing makes VFX's
    /// palette of block 0 for the buttons and of block 11 for the pointer (`0x00438AFB`,
    /// `0x00438CF8`).
    shapes: ?canvas_module.Shapes = null,
    title_font: ?hud.FontFile = null,
    /// The pointer as the pass read it, and what lies under it.
    pointer: canvas_module.Pointer = .{},
    under: ?Hotspot = null,
    /// Whether the left button was down on the last pass (`0x0051DB40`), so that a press counts
    /// on the pass it goes down.
    held: bool = false,
    /// Set by LEAVE CD PLAYER, which closes it on the next pass (`0x0043864B`).
    leaving: bool = false,
    /// The piece chosen, by its row (`0x0051D9D0`); null for none.
    selected: ?usize = null,
    /// The buttons' modes (`0x0051DA18`, `0x0051DA08`, `0x005202C8`), and whether a piece plays
    /// that the next follows (`0x0051D7AC`).
    paused: bool = false,
    repeat: bool = false,
    shuffle: bool = false,
    playing: bool = false,
    random: std.Random.DefaultPrng,

    /// Opens it before mission `mission` (`0x00438363` on), at `now`, with its picture, shapes and
    /// font from `resource.hog`, nothing chosen; what is missing is left out, which the log says.
    pub fn open(context: Context, mission: u16, now: u64) CdPlayer {
        const gpa = context.rooms.gpa;
        const resources = context.rooms.resources;
        var player: CdPlayer = .{ .context = context, .carrier = .of(mission), .random = .init(now) };
        const picture = switch (player.carrier) {
            .reliant => reliant_picture,
            .yamato => yamato_picture,
        };
        player.picture.show(gpa, resources.*, picture);
        player.shapes = .read(gpa, resources, shapes_name);
        player.title_font = .read(gpa, resources.*, title_font_name, context.rooms.outlines);
        return player;
    }

    /// Lets go of what it read (`0x0043881F` on). The music plays on.
    pub fn deinit(player: *CdPlayer) void {
        const gpa = player.context.rooms.gpa;
        player.picture.deinit(gpa);
        if (player.shapes) |*shapes| shapes.deinit(gpa);
        if (player.title_font) |*file| file.deinit(gpa);
        player.* = undefined;
    }

    /// The list it shows.
    pub fn list(player: CdPlayer) *const [track_count]Track {
        return tracks.getPtrConst(player.carrier);
    }

    /// A pass of its loop (`0x00438407` on): whether it stays open. Escape closes it, and so does
    /// the pass after LEAVE CD PLAYER. The left button going down over a button or a row sounds
    /// and does what it does; the volume's buttons turn it a step each pass they are held. Then a
    /// piece that has ended is followed (`follow`).
    pub fn pass(player: *CdPlayer, in: Input) bool {
        player.pointer = in.pointer;
        if (in.keyboard.pressed(input.scan.escape, .none, true) or player.leaving) return false;
        player.under = hotspotAt(in.pointer.at);
        const pressed = in.pointer.down and !player.held;
        player.held = in.pointer.down;
        if (pressed and player.under != null) player.playPress();
        if (player.under) |under| switch (under) {
            .button => |button| switch (button) {
                .play => if (pressed and player.selected != null) {
                    player.start();
                    player.paused = false;
                    player.playing = true;
                },
                .pause => if (pressed) {
                    player.context.rooms.sound.pauseMusic(!player.paused);
                    player.paused = !player.paused;
                },
                .stop => if (pressed) {
                    player.selected = null;
                    player.playing = false;
                    player.context.rooms.sound.closeMusic();
                },
                .next => if (pressed) {
                    const next = if (player.selected) |row| row + 1 else 0;
                    if (next < track_count) player.skipTo(next);
                },
                .previous => if (pressed) if (player.selected) |row| if (row > 0) player.skipTo(row - 1),
                .repeat => if (pressed) {
                    player.shuffle = false;
                    player.repeat = !player.repeat;
                },
                .shuffle => if (pressed) {
                    player.repeat = false;
                    player.shuffle = !player.shuffle;
                },
                .leave => if (pressed) {
                    player.leaving = true;
                },
                .volume_up => if (in.pointer.down) player.turn(player.context.volume.* +| 1),
                .volume_down => if (in.pointer.down) player.turn(player.context.volume.* -| 1),
            },
            // A row chooses its piece, and the piece chosen plays.
            .row => |row| if (pressed) {
                if (player.selected == row) {
                    player.start();
                    player.playing = true;
                } else player.selected = row;
            },
        };
        player.follow();
        return true;
    }

    /// The next or the previous track, `row`, played (`0x004385B9` on).
    fn skipTo(player: *CdPlayer, row: usize) void {
        player.selected = row;
        player.start();
        player.paused = false;
    }

    /// What follows a piece as it ends (`0x00438735` on): with REPEAT TRACK MODE off, once the
    /// music has stopped while a piece played, not paused, the list's next, or in RANDOM TRACK MODE
    /// another of its pieces. The list's last piece ends it.
    fn follow(player: *CdPlayer) void {
        if (player.repeat or player.paused or !player.playing) return;
        if (player.context.rooms.sound.musicPlaying()) return;
        const row = player.selected orelse return;
        if (player.shuffle) {
            player.selected = other(player.random.random(), row);
        } else {
            if (row + 1 >= track_count) return;
            player.selected = row + 1;
        }
        player.start();
    }

    /// `music_play` of the piece chosen, at once: over and over in REPEAT TRACK MODE, else once.
    fn start(player: *CdPlayer) void {
        const row = player.selected orelse return;
        const loops: u32 = if (player.repeat) hog_snd.forever else hog_snd.once;
        player.context.rooms.sound.playMusic(player.list()[row].path, loops, player.context.volume.*, .now);
    }

    /// The volume turned to `volume`, and the music with it (`0x0043866D` on, `0x004386AA` on).
    fn turn(player: *CdPlayer, volume: Volume) void {
        player.context.volume.* = volume;
        player.context.rooms.sound.setMusicLevel(volume);
    }

    /// The sound of a press over a button or a row.
    fn playPress(player: CdPlayer) void {
        player.context.steps.play(player.context.rooms.sound, .cd_press);
    }

    /// The frame (`0x00438890`): the picture; the button under the pointer lit, and REPEAT TRACK
    /// MODE and RANDOM TRACK MODE while they are on; the title and the list; the name of the button
    /// under the pointer; and the pointer.
    pub fn draw(player: *CdPlayer, canvas: Canvas) canvas_module.Error!void {
        if (player.picture.image) |*image| canvas.fill(image);
        const button = player.buttonUnder();
        if (player.shapes) |*shapes| {
            if (button) |over| if (over.lightsUnderPointer()) try light(canvas, shapes, over);
            if (player.repeat) try light(canvas, shapes, .repeat);
            if (player.shuffle) try light(canvas, shapes, .shuffle);
        }
        if (player.title_font) |*file| try canvas.string(&file.font, title_at, title, list_colour, .left);
        var y: i32 = first_line;
        for (player.list(), numbers, 0..) |piece, number, row| {
            defer y += row_spacing;
            const colour = if (player.selected == row) canvas_module.white else list_colour;
            try canvas.text(canvas.fonts.small, .{ number_x, y }, number, colour, .left);
            try canvas.string(canvas.fonts.small, .{ name_x, y }, piece.name, colour, .left);
        }
        if (button) |over| try canvas.label(buttons.get(over).name);
        if (player.shapes) |*shapes| try canvas.shape(&shapes.art, pointer_shape, player.pointer.at);
    }

    /// The button under the pointer; null over a row, or over nothing.
    fn buttonUnder(player: CdPlayer) ?Button {
        const under = player.under orelse return null;
        return switch (under) {
            .button => |button| button,
            .row => null,
        };
    }
};

/// Draws the shape that lights `button`.
fn light(canvas: Canvas, shapes: *canvas_module.Shapes, button: Button) canvas_module.Error!void {
    const item = buttons.get(button);
    try canvas.shape(&shapes.art, item.lit, item.lit_at);
}

/// A piece of the list other than `row`, at random.
///
/// **Improvement:** it is drawn from `std.Random` among the other eleven. The game draws
/// `rand() % 12` up to 20 times for one other than `row` (`0x004387AE` on), and plays `row` again
/// where none is.
fn other(random: std.Random, row: usize) usize {
    const drawn = random.uintLessThan(usize, track_count - 1);
    return if (drawn >= row) drawn + 1 else drawn;
}

test hotspotAt {
    try std.testing.expectEqual(Hotspot{ .button = .play }, hotspotAt(.{ 590, 140 }).?);
    try std.testing.expectEqual(Hotspot{ .button = .leave }, hotspotAt(.{ 590, 360 }).?);
    try std.testing.expectEqual(Hotspot{ .button = .volume_down }, hotspotAt(.{ 40, 370 }).?);
    // The rows, 16 apart from (117, 176), their edges left out.
    try std.testing.expectEqual(Hotspot{ .row = 0 }, hotspotAt(.{ 200, 180 }).?);
    try std.testing.expectEqual(Hotspot{ .row = 11 }, hotspotAt(.{ 200, 360 }).?);
    try std.testing.expectEqual(null, hotspotAt(.{ 200, 176 }));
    try std.testing.expectEqual(null, hotspotAt(.{ 320, 440 }));
}

test other {
    var prng: std.Random.DefaultPrng = .init(0);
    for (0..200) |n| {
        const row = n % track_count;
        const drawn = other(prng.random(), row);
        try std.testing.expect(drawn != row and drawn < track_count);
    }
}

test tracks {
    try std.testing.expectEqualStrings("music\\new_mission01.wav", tracks.get(.reliant)[0].path);
    try std.testing.expectEqualStrings("music\\New_Takeoff - Music.wav", tracks.get(.yamato)[8].path);
    try std.testing.expectEqualStrings("12", numbers[11]);
}

/// Its files in the tests: there, but unreadable, and left out.
const stand_ins = [_]hog.Member{
    .{ .name = "rel_bunk2cd.tga", .data = "x" },
    .{ .name = "brd2cd.tga", .data = "x" },
    .{ .name = "cdplay.spr", .data = "x" },
    .{ .name = "itacbig.fnt", .data = "x" },
};

/// The rooms in the tests, with the music of `carrier`'s list.
fn testedWith(tested: *rooms.testing.Tested, carrier: rooms.Carrier) !void {
    try tested.init(&.{}, &.{}, &stand_ins);
    errdefer tested.deinit();
    var paths: [track_count][]const u8 = undefined;
    for (&paths, tracks.get(carrier)) |*path, piece| path.* = piece.path;
    try tested.giveMusic(&paths);
}

/// A pass with the pointer at `at`, the left button down where `down` has it.
fn passAt(player: *CdPlayer, keyboard: *input.Keyboard, at: [2]i32, down: bool) bool {
    return player.pass(.{ .keyboard = keyboard, .pointer = .{ .at = at, .down = down } });
}

/// A click at `at`: the left button down for a pass, then up.
fn click(player: *CdPlayer, keyboard: *input.Keyboard, at: [2]i32) !void {
    try std.testing.expect(passAt(player, keyboard, at, true));
    try std.testing.expect(passAt(player, keyboard, at, false));
}

/// Where the pointer finds `button`, and row `row` of the list; and a point over nothing.
fn buttonAt(button: Button) [2]i32 {
    const rect = buttons.get(button).rect;
    return .{ @as(i32, rect.x) + 5, @as(i32, rect.y) + 5 };
}

fn rowAt(row: i32) [2]i32 {
    return .{ 200, row_corner[1] + row * row_spacing + 5 };
}

const nowhere: [2]i32 = .{ 320, 440 };

test CdPlayer {
    var tested: rooms.testing.Tested = undefined;
    try testedWith(&tested, .reliant);
    defer tested.deinit();
    const sound = &tested.sound;
    var keyboard: input.Keyboard = .{};
    var volume: Volume = full_volume;
    var player: CdPlayer = .open(.{ .rooms = tested.context(), .volume = &volume }, 18, 0);
    defer player.deinit();
    try std.testing.expectEqual(rooms.Carrier.reliant, player.carrier);

    // PLAY SELECTED TRACK with none chosen plays nothing. A press counts on the pass the button
    // goes down: a row held chooses its piece, which plays once the row is clicked again.
    try click(&player, &keyboard, buttonAt(.play));
    try std.testing.expect(!sound.musicPlaying());
    try std.testing.expect(passAt(&player, &keyboard, rowAt(1), true));
    try std.testing.expect(passAt(&player, &keyboard, rowAt(1), true));
    try std.testing.expectEqual(1, player.selected.?);
    try std.testing.expect(!sound.musicPlaying());
    try std.testing.expect(passAt(&player, &keyboard, rowAt(1), false));
    try click(&player, &keyboard, rowAt(1));
    try std.testing.expect(sound.musicPlaying() and player.playing);
    try std.testing.expectEqual(hog_snd.loudest, sound.music.level);

    // The volume turns a step each pass its button is held, and the music with it.
    try std.testing.expect(passAt(&player, &keyboard, buttonAt(.volume_down), true));
    try std.testing.expect(passAt(&player, &keyboard, buttonAt(.volume_down), true));
    try std.testing.expectEqual(full_volume - 2, volume);
    try std.testing.expectEqual(full_volume - 2, sound.music.level);
    for (0..3) |_| try std.testing.expect(passAt(&player, &keyboard, buttonAt(.volume_up), true));
    try std.testing.expect(passAt(&player, &keyboard, buttonAt(.volume_up), false));
    try std.testing.expectEqual(full_volume, volume);

    // Paused, a piece's end is not followed; going on, it is, by the list's next.
    try click(&player, &keyboard, buttonAt(.pause));
    try std.testing.expect(player.paused and !sound.musicPlaying());
    try std.testing.expect(passAt(&player, &keyboard, nowhere, false));
    try std.testing.expectEqual(1, player.selected.?);
    try click(&player, &keyboard, buttonAt(.pause));
    try std.testing.expect(sound.musicPlaying());
    sound.closeMusic();
    try std.testing.expect(passAt(&player, &keyboard, nowhere, false));
    try std.testing.expectEqual(2, player.selected.?);
    try std.testing.expect(sound.musicPlaying());

    // The previous track; and in RANDOM TRACK MODE, another piece follows one's end.
    try click(&player, &keyboard, buttonAt(.previous));
    try std.testing.expectEqual(1, player.selected.?);
    try click(&player, &keyboard, buttonAt(.shuffle));
    sound.closeMusic();
    try std.testing.expect(passAt(&player, &keyboard, nowhere, false));
    try std.testing.expect(player.selected.? != 1 and sound.musicPlaying());
    // REPEAT TRACK MODE turns RANDOM TRACK MODE off, and nothing follows a piece's end.
    try click(&player, &keyboard, buttonAt(.repeat));
    try std.testing.expect(player.repeat and !player.shuffle);
    sound.closeMusic();
    try std.testing.expect(passAt(&player, &keyboard, nowhere, false));
    try std.testing.expect(!sound.musicPlaying());

    // STOP THE CURRENT TRACK ends the music and the choice; the next track is then the first.
    try click(&player, &keyboard, buttonAt(.stop));
    try std.testing.expectEqual(null, player.selected);
    try click(&player, &keyboard, buttonAt(.next));
    try std.testing.expectEqual(0, player.selected.?);
    try std.testing.expect(sound.musicPlaying());

    // LEAVE CD PLAYER closes it on the next pass, the music playing on.
    try std.testing.expect(passAt(&player, &keyboard, buttonAt(.leave), true));
    try std.testing.expect(!passAt(&player, &keyboard, buttonAt(.leave), false));
    try std.testing.expect(sound.musicPlaying());
}

test "the Yamato's CD player plays its own list" {
    var tested: rooms.testing.Tested = undefined;
    try testedWith(&tested, .yamato);
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var volume: Volume = 100;
    var player: CdPlayer = .open(.{ .rooms = tested.context(), .volume = &volume }, 19, 0);
    defer player.deinit();
    try std.testing.expectEqual(rooms.Carrier.yamato, player.carrier);
    // The next track from the first is the Yamato's second, played at the CD player's volume.
    try click(&player, &keyboard, rowAt(0));
    try click(&player, &keyboard, buttonAt(.next));
    try std.testing.expect(tested.sound.musicPlaying());
    try std.testing.expectEqual(100, tested.sound.music.level);
    // Escape closes it.
    keyboard.down[input.scan.escape] = true;
    try std.testing.expect(!passAt(&player, &keyboard, nowhere, false));
}
