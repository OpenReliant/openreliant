//! `medal_display` (`0x004362F0`, `MedalDisplay` by its assertions) and its drawing
//! (`0x00436B20`): the locker, which Open Locker opens in the Reliant's rooms and the Yamato's
//! (`rooms.Place.locker`). It runs in a loop of its own over the lid's movie, from the disc: the
//! lid goes up, and the pilot's medals and ribbons come into view with it, each a shape of a set of
//! its own for each frame of the movie (`tables`). Once the lid is up, the pointer names the award
//! under it, and a press of either button sends the lid down again; Escape sends it down at once,
//! and ends it as it goes down. 0 saves a screenshot while the lid is up.
//!
//! **Fix:** the lid's movies are each the locker's own. The game opens three of the four into
//! another movie's handle (`bink_movie`, `0x005D6C40`), and goes on drawing and timing its own
//! (`vr_movie`, `0x0051D7E8`), which then holds a movie already closed: the Reliant's lid going
//! down, and the Yamato's going up and down.
//!
//! The timer it runs, 15 times a second (`0x00437DE0`), is left out: nothing it counts shows.

const std = @import("std");

const gameflow = @import("../gameflow.zig");
const input = @import("../../input.zig");
const hog = @import("../../../formats/hog.zig");
const canvas_module = @import("canvas.zig");
const main_menu = @import("main_menu.zig");
const rooms = @import("rooms.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;

pub const tables = @import("locker/tables.zig");

/// The medals, and the ribbons, a pilot can have.
const awards = 6;

comptime {
    std.debug.assert(std.enums.values(gameflow.Medal).len == awards);
    std.debug.assert(gameflow.Ribbons.bit_length == awards);
}

/// Where the lid is going: up as the locker opens, and down as it closes (`0x0051DB54`).
pub const Lid = enum { up, down };

/// The sound of the lid going up and down, from the rooms' steps.
const lid_sounds = std.EnumArray(Lid, rooms.StepSound).init(.{ .up = .lid_up, .down = .lid_down });

/// The key that saves a screenshot while the lid is up (`0x004368B4`).
pub const screenshot_key: input.Key = .zero;

/// What the pointer's place names once the lid is up (`0x00436F8D`), but over an award the pilot
/// has: Close Locker.
const close_locker = 0xD5;

/// The pointer, from the front end's shapes (`vr_frontend_shapes`, `0x0051D4E0`), in the palette
/// of their block 0, and each award's set in its own block 0's (`0x00436D77`).
const pointer_shapes_name = main_menu.shapes_name;
const palette_block = 0;

/// A medal, or a ribbon by its place from 0, ribbon 1 first.
pub const Award = union(enum) {
    medal: gameflow.Medal,
    ribbon: usize,
};

/// The awards the pilot has (`pilot_medals`, `0x00562DFC`; `pilot_ribbons`, `0x00562E14`).
pub const Awards = struct {
    medals: std.EnumSet(gameflow.Medal) = .initEmpty(),
    ribbons: gameflow.Ribbons = .initEmpty(),

    /// The awards of `campaign`; none outside one.
    pub fn of(campaign: ?*const gameflow.Campaign) Awards {
        const going = campaign orelse return .{};
        return .{ .medals = going.medals, .ribbons = going.ribbons };
    }

    pub fn has(held: Awards, award: Award) bool {
        return switch (award) {
            .medal => |medal| held.medals.contains(medal),
            .ribbon => |place| held.ribbons.isSet(place),
        };
    }
};

/// An award the pointer finds inside its rectangle, the edges left out (`interface_hit`), and the
/// string that names it.
pub const Item = struct {
    rect: Rect,
    award: Award,
    name: u16,
};

fn item(x: i16, y: i16, width: i16, height: i16, award: Award, name: u16) Item {
    return .{ .rect = .{ .x = x, .y = y, .width = width, .height = height }, .award = award, .name = name };
}

/// The Reliant's awards under the pointer (`0x0043632B` on, `0x00436B29` on): The Silver Cluster,
/// The Black Eagle and The Medal of Valor, then the first three ribbons, The Alliance Defense
/// Mobilization Medal, The Long Range Forces Commendation Medal and The Special Operations Service
/// Medal.
const reliant_items = [_]Item{
    item(226, 111, 79, 43, .{ .medal = .silver }, 0x56A),
    item(303, 132, 86, 52, .{ .medal = .black_eagle }, 0x56B),
    item(399, 152, 96, 68, .{ .medal = .valour }, 0x56C),
    item(116, 214, 46, 29, .{ .ribbon = 0 }, 0x56D),
    item(161, 232, 49, 31, .{ .ribbon = 1 }, 0x56E),
    item(213, 252, 50, 35, .{ .ribbon = 2 }, 0x56F),
};

/// The Yamato's: the six medals, The Legion of Service, The Navy Cross and The Alliance Medal of
/// Honor after the Reliant's three, then the five ribbons, The Joint Services Commendation Medal
/// and The Battle of Titan Campaign Medal after the Reliant's three.
const yamato_items = [_]Item{
    item(206, 154, 68, 60, .{ .medal = .silver }, 0x56A),
    item(291, 157, 72, 62, .{ .medal = .black_eagle }, 0x56B),
    item(384, 164, 80, 68, .{ .medal = .valour }, 0x56C),
    item(172, 223, 74, 67, .{ .medal = .legion }, 0x570),
    item(263, 229, 82, 84, .{ .medal = .navy_cross }, 0x571),
    item(366, 239, 90, 97, .{ .medal = .medal_of_honour }, 0x572),
    item(145, 299, 29, 24, .{ .ribbon = 0 }, 0x56D),
    item(190, 308, 40, 23, .{ .ribbon = 1 }, 0x56E),
    item(239, 317, 44, 26, .{ .ribbon = 2 }, 0x56F),
    item(290, 326, 42, 26, .{ .ribbon = 3 }, 0x573),
    item(345, 336, 49, 28, .{ .ribbon = 4 }, 0x574),
};

/// A carrier's locker.
pub const Case = struct {
    /// The lid's movies, from the disc's archive: up (`0x004E883C`, `0x004E88A8`), and down
    /// (`0x004E87E0`, `0x004E87F0`).
    lid: std.EnumArray(Lid, []const u8),
    /// The movie of the way to it, which plays over the screen before the lid goes up
    /// (`0x004E88B8`); none on the Reliant.
    zoom: ?[]const u8,
    /// The sets of the awards' shapes, from the disc's archive, by their places: `rmedal%d.spr`
    /// and `rbar%d.spr` on the Reliant (`0x004E880C`, `0x004E8800`), and `medal%d.spr` and
    /// `bar%d.spr` on the Yamato (`0x004E8828`, `0x004E881C`).
    medal_sets: [awards][]const u8,
    ribbon_sets: [awards][]const u8,
    /// Where the awards stand, and their shapes by the lid's frame.
    medals: *const [awards]tables.Display,
    ribbons: *const [awards]tables.Display,
    items: []const Item,
    /// The frame of the tables the awards go back from as the lid goes down (`0x00436A56`).
    down_from: usize,
};

/// The names of a set of shapes for each award, `stem` and its number from 1.
fn setNames(comptime stem: []const u8) [awards][]const u8 {
    var names: [awards][]const u8 = undefined;
    for (&names, 1..) |*name, number| name.* = std.fmt.comptimePrint(stem ++ "{d}.spr", .{number});
    return names;
}

pub const cases = std.EnumArray(rooms.Carrier, Case).init(.{
    .reliant = .{
        .lid = .init(.{ .up = "rel_locklup.bik", .down = "rel_lockldo.bik" }),
        .zoom = null,
        .medal_sets = setNames("rmedal"),
        .ribbon_sets = setNames("rbar"),
        .medals = &tables.reliant_medals,
        .ribbons = &tables.reliant_ribbons,
        .items = &reliant_items,
        .down_from = 0x15,
    },
    .yamato = .{
        .lid = .init(.{ .up = "locklidup.bik", .down = "lokliddo.bik" }),
        .zoom = "lockzomi.bik",
        .medal_sets = setNames("medal"),
        .ribbon_sets = setNames("bar"),
        .medals = &tables.yamato_medals,
        .ribbons = &tables.yamato_ribbons,
        .items = &yamato_items,
        .down_from = 0xE,
    },
});

/// What the locker reads and plays with.
pub const Context = struct {
    rooms: rooms.Context,
    /// The rooms' steps and doors, which the lid sounds from.
    steps: rooms.Steps = .{},
};

/// A pass's input.
pub const Input = struct {
    keyboard: *input.Keyboard,
    pointer: canvas_module.Pointer,
    /// The clock's nanoseconds, which the lid's movie keeps time by.
    now: u64,
};

pub const Locker = struct {
    context: Context,
    case: *const Case,
    held: Awards,
    lid: Lid = .up,
    /// The lid's movie (`vr_movie`), and whether it has reached its last frame (`vr_arrived`,
    /// `0x00520298`).
    film: rooms.Film = .{},
    arrived: bool = false,
    /// The sets of the awards the pilot has, by their places (`0x0051D45C`, `0x0051DA34`); none for
    /// those it lacks, or that are left out.
    medal_sets: [awards]?canvas_module.Shapes = @splat(null),
    ribbon_sets: [awards]?canvas_module.Shapes = @splat(null),
    pointer_shapes: ?canvas_module.Shapes = null,
    /// The pointer as the pass read it, and the award under it (`0x0051D494`).
    pointer: canvas_module.Pointer = .{},
    under: ?Item = null,
    /// Whether the pass asked for a screenshot of the screen, which the caller then saves
    /// (`screenshot_save`).
    screenshot: bool = false,

    /// Opens the locker before mission `mission`, for a pilot with the awards `held`: the sets of
    /// their shapes, and the lid going up, with its sound (`0x0043655F` on). What is missing is
    /// left out, which the log says. The Yamato's way in (`zoom`) plays first.
    pub fn open(context: Context, mission: u16, held: Awards) Locker {
        const gpa = context.rooms.gpa;
        var locker: Locker = .{ .context = context, .case = cases.getPtrConst(.of(mission)), .held = held };
        locker.send(.up);
        for (&locker.medal_sets, locker.case.medal_sets, std.enums.values(gameflow.Medal)) |*set, name, medal| {
            if (held.has(.{ .medal = medal })) set.* = locker.readSet(name);
        }
        for (&locker.ribbon_sets, locker.case.ribbon_sets, 0..) |*set, name, place| {
            if (held.has(.{ .ribbon = place })) set.* = locker.readSet(name);
        }
        locker.pointer_shapes = .readWith(gpa, context.rooms.resources, pointer_shapes_name, palette_block);
        return locker;
    }

    pub fn deinit(locker: *Locker) void {
        const gpa = locker.context.rooms.gpa;
        locker.film.close();
        for (&locker.medal_sets) |*set| if (set.*) |*shapes| shapes.deinit(gpa);
        for (&locker.ribbon_sets) |*set| if (set.*) |*shapes| shapes.deinit(gpa);
        if (locker.pointer_shapes) |*shapes| shapes.deinit(gpa);
        locker.* = undefined;
    }

    /// The movie of the way to `carrier`'s locker, which plays over the screen before it opens
    /// (`play_bink_movie_no_clear_resourced`, `0x0043655A`).
    pub fn zoom(carrier: rooms.Carrier) ?[]const u8 {
        return cases.get(carrier).zoom;
    }

    /// The set `name` from the disc's archive (`hog_read_file`, `0x00436738`), with the pictures the
    /// mods give in its shapes' place; null where it is left out.
    fn readSet(locker: Locker, name: []const u8) ?canvas_module.Shapes {
        const context = locker.context.rooms;
        const bytes = context.read(name) orelse return null;
        var shapes = canvas_module.Shapes.of(context.gpa, bytes, name, .of(context.disc.mods, name)) orelse return null;
        shapes.usePalette(palette_block);
        return shapes;
    }

    /// A pass of its loop (`0x00436852` on, `0x00436A7D` on): whether it stays open. With the lid
    /// up, the award under the pointer is found; Escape, or either button once the lid has
    /// arrived, sends it down, and 0 asks for a screenshot. With it going down, Escape ends it, and
    /// so does its arriving. Then the lid's movie steps on, as the drawing steps it.
    pub fn pass(locker: *Locker, in: Input) bool {
        locker.pointer = in.pointer;
        locker.screenshot = false;
        const escape = in.keyboard.pressed(input.scan.escape, .none, true);
        switch (locker.lid) {
            .up => {
                locker.under = locker.itemAt(in.pointer.at);
                if (escape) {
                    locker.send(.down);
                } else {
                    locker.screenshot = in.keyboard.pressed(@intFromEnum(screenshot_key), .none, true);
                    if (locker.arrived and (in.pointer.down or in.pointer.right_down)) locker.send(.down);
                }
            },
            .down => if (escape or locker.arrived) return false,
        }
        locker.advance(in.now);
        return true;
    }

    /// The award of this carrier's locker that holds `at` (`interface_hit`, `0x00436899`).
    fn itemAt(locker: Locker, at: [2]i32) ?Item {
        for (locker.case.items) |shown| if (shown.rect.holds(at)) return shown;
        return null;
    }

    /// The lid sent up (`0x0043659C` on) or down (`0x004368FF` on): its movie, in place of the one
    /// before, and its sound.
    fn send(locker: *Locker, lid: Lid) void {
        locker.lid = lid;
        locker.arrived = false;
        locker.film.open(locker.context.rooms, locker.case.lid.get(lid), .screen);
        locker.context.steps.play(locker.context.rooms.sound, lid_sounds.get(lid));
    }

    /// The lid's movie stepped as the drawing steps it (`0x00436C03` on): its next frame once it is
    /// due, and the lid arrived at its last. A movie left out has it arrived at once.
    fn advance(locker: *Locker, now: u64) void {
        if (locker.film.player == null or locker.film.still) {
            locker.arrived = true;
            return;
        }
        if (!locker.film.advance(now)) return;
        locker.arrived = true;
        locker.film.still = true;
    }

    /// The frame of the tables the awards are drawn at (`0x005201AC`): it steps with each frame of
    /// the lid's movie but its last (`0x00436C68`), up from -1 as the lid goes up, and down from
    /// `Case.down_from` as it goes down, no lower than 0. None before the lid's first frame, or
    /// without its movie.
    fn tableFrame(locker: Locker) ?usize {
        const next = locker.film.frame() orelse return null;
        return switch (locker.lid) {
            .up => if (next >= 2) next - 2 else null,
            .down => locker.case.down_from -| (next -| 1),
        };
    }

    /// The frame (`0x00436B20`): the lid's movie; the awards the pilot has, each at its shape for
    /// the frame; with the lid up and arrived, the name of the award under the pointer, or Close
    /// Locker; and the pointer, the front end's.
    pub fn draw(locker: *Locker, canvas: Canvas) canvas_module.Error!void {
        locker.film.draw(canvas);
        if (locker.tableFrame()) |frame| {
            for (&locker.medal_sets, &locker.ribbon_sets, locker.case.medals, locker.case.ribbons) |*medal, *ribbon, medal_display, ribbon_display| {
                if (medal.*) |*shapes| try drawAward(canvas, shapes, medal_display, frame);
                if (ribbon.*) |*shapes| try drawAward(canvas, shapes, ribbon_display, frame);
            }
        }
        if (locker.lid == .up and locker.arrived) try canvas.label(locker.label());
        if (locker.pointer_shapes) |*shapes| try canvas.shape(&shapes.art, locker.pointer.shape(), locker.pointer.at);
    }

    /// What the pointer's place names (`0x00436F31` on): the award under it, where the pilot has it;
    /// else Close Locker.
    fn label(locker: Locker) u16 {
        const over = locker.under orelse return close_locker;
        return if (locker.held.has(over.award)) over.name else close_locker;
    }
};

/// Draws an award at its shape for frame `frame` of its table, where it shows one.
fn drawAward(canvas: Canvas, shapes: *canvas_module.Shapes, display: tables.Display, frame: usize) canvas_module.Error!void {
    const shape = shapeAt(display, frame);
    if (shape == 0) return;
    try canvas.shape(&shapes.art, shape, display.at);
}

/// The shape `display` shows on frame `frame` of its table, 0 for none.
///
/// **Fix:** past the end of its table an award keeps the table's last shape, for a lid's movie
/// longer than the game's. The game reads on past the table.
fn shapeAt(display: tables.Display, frame: usize) u8 {
    return display.shapes[@min(frame, display.shapes.len - 1)];
}

comptime {
    for ([_][]const tables.Display{ &tables.reliant_medals, &tables.reliant_ribbons, &tables.yamato_medals, &tables.yamato_ribbons }) |table| {
        std.debug.assert(table.len == awards);
        for (table) |display| std.debug.assert(display.shapes.len > 0);
    }
}

/// Its sets in the tests, and the front end's shapes: there, but unreadable, and left out.
const stand_ins = [_]hog.Member{
    .{ .name = "rmedal1.spr", .data = "x" },
    .{ .name = "rbar2.spr", .data = "x" },
};
const pointer_stand_in = [_]hog.Member{.{ .name = "frontend.spr", .data = "x" }};

test "each carrier's locker" {
    // The Reliant's six awards under the pointer, the Yamato's eleven, and the lid's frame each
    // sends its awards back from.
    try std.testing.expectEqual(6, cases.get(.reliant).items.len);
    try std.testing.expectEqual(11, cases.get(.yamato).items.len);
    try std.testing.expectEqualStrings("rmedal1.spr", cases.get(.reliant).medal_sets[0]);
    try std.testing.expectEqualStrings("bar6.spr", cases.get(.yamato).ribbon_sets[5]);
    try std.testing.expectEqual(null, Locker.zoom(.reliant));
    try std.testing.expectEqualStrings("lockzomi.bik", Locker.zoom(.yamato).?);
    // Each award's place in the tables matches the item that names it.
    for (std.enums.values(rooms.Carrier)) |carrier| {
        const case = cases.get(carrier);
        for (case.items) |shown| switch (shown.award) {
            .medal => |medal| try std.testing.expect(case.medals[@intFromEnum(medal) - 1].at[0] != 0),
            .ribbon => |place| try std.testing.expect(case.ribbons[place].at[0] != 0),
        };
    }
}

test Awards {
    var campaign: gameflow.Campaign = .begin();
    campaign.medals.insert(.black_eagle);
    campaign.ribbons.set(1);
    const held: Awards = .of(&campaign);
    try std.testing.expect(held.has(.{ .medal = .black_eagle }) and !held.has(.{ .medal = .silver }));
    try std.testing.expect(held.has(.{ .ribbon = 1 }) and !held.has(.{ .ribbon = 0 }));
    try std.testing.expect(!Awards.of(null).has(.{ .medal = .black_eagle }));
}

test shapeAt {
    // The Reliant's first medal comes into view on the lid's tenth frame; past its table, it keeps
    // the last shape.
    const display = tables.reliant_medals[0];
    try std.testing.expectEqual(0, shapeAt(display, 8));
    try std.testing.expectEqual(1, shapeAt(display, 9));
    try std.testing.expectEqual(display.shapes[display.shapes.len - 1], shapeAt(display, 1000));
}

test Locker {
    var tested: rooms.testing.Tested = undefined;
    try tested.init(&.{ "rel_locklup.bik", "rel_lockldo.bik" }, &stand_ins, &pointer_stand_in);
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var held: Awards = .{};
    held.medals.insert(.silver);
    held.ribbons.set(1);
    var locker: Locker = .open(.{ .rooms = tested.context() }, 18, held);
    defer locker.deinit();
    try std.testing.expectEqual(Lid.up, locker.lid);

    // The lid goes up a frame a pass, its frames at 15 a second; the awards' frame steps with it.
    var frame: u64 = 0;
    const second: u64 = std.time.ns_per_s;
    while (!locker.arrived) : (frame += 1) {
        try std.testing.expect(locker.pass(.{ .keyboard = &keyboard, .pointer = .{ .at = .{ 250, 120 } }, .now = frame * second / 15 }));
    }
    // Three frames: the awards stop at the frame before the last.
    try std.testing.expectEqual(1, locker.tableFrame().?);
    // Over The Silver Cluster, which the pilot has, the pointer names it; over nothing, Close Locker.
    try std.testing.expectEqual(0x56A, locker.label());
    locker.under = null;
    try std.testing.expectEqual(close_locker, locker.label());

    // A press sends the lid down, the awards' frames going back from 21 as its frames show.
    try std.testing.expect(locker.pass(.{ .keyboard = &keyboard, .pointer = .{ .at = .{ 600, 400 }, .down = true }, .now = frame * second / 15 }));
    try std.testing.expectEqual(Lid.down, locker.lid);
    try std.testing.expectEqual(20, locker.tableFrame().?);
    while (true) : (frame += 1) {
        if (!locker.pass(.{ .keyboard = &keyboard, .pointer = .{}, .now = frame * second / 15 })) break;
    }
    try std.testing.expectEqual(19, locker.tableFrame().?);
}

test "Escape sends the lid down, then ends it" {
    var tested: rooms.testing.Tested = undefined;
    try tested.init(&.{ "locklidup.bik", "lokliddo.bik" }, &.{}, &pointer_stand_in);
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var locker: Locker = .open(.{ .rooms = tested.context() }, 19, .{});
    defer locker.deinit();
    keyboard.down[input.scan.escape] = true;
    try std.testing.expect(locker.pass(.{ .keyboard = &keyboard, .pointer = .{}, .now = 0 }));
    try std.testing.expectEqual(Lid.down, locker.lid);
    keyboard.down[input.scan.escape] = false;
    keyboard.read();
    keyboard.down[input.scan.escape] = true;
    try std.testing.expect(!locker.pass(.{ .keyboard = &keyboard, .pointer = .{}, .now = 0 }));
}
