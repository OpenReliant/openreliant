//! `simulator_pod` (`0x0044F3D0`) and its drawing (`0x0044F840`): the simulator pod, which Enter
//! Simulator Pod opens in the Reliant's rooms and the Yamato's (`rooms.Place.simulator`). It runs
//! in a loop of its own, on a screen 640 by 480, over a picture of the pod. Its first screen, FLIGHT
//! SIMULATOR, leads to the training missions, to Instant Action, or out of the pod; the training
//! missions' screen offers the three missions, Instant Action and the way out. The choice under
//! the pointer lights, its name written at the screen's foot, and the left button takes it. A
//! mission is flown in the simulator, in a Grendel, and the pod comes back as it ends (`Pod.back`).
//!
//! **Fix:** RESTART in the pause menu starts the pod's mission again, as it does Instant Action's
//! from the main menu. The game flies the pod's mission once and comes back to the pod however the
//! mission ends, RESTART among them.
//!
//! **Unverified:** the pod's code lies within `loadout.cpp`'s, which the source map places it in.

const std = @import("std");

const create = @import("../../game/create.zig");
const gameobj = @import("../../game/gameobj.zig");
const hud = @import("../../game/hud.zig");
const input = @import("../../input.zig");
const itac = @import("../../game/itac.zig");
const matmanager = @import("../../game/matmanager.zig");
const movie = @import("../../game/xtrabits/movie.zig");
const canvas_module = @import("../../game/interface/canvas.zig");
const main_menu = @import("../../game/interface/main_menu.zig");
const rooms = @import("../../game/interface/rooms.zig");
const Canvas = canvas_module.Canvas;
const Rect = canvas_module.Rect;

/// What the pod reads from `resource.hog` as it opens: the shapes that light its choices
/// (`0x0044F411`), the ITAC's large font, which its title is written in (`0x0044F41D`), and the
/// front end's shapes, which its pointer is drawn from (`vr_frontend_shapes`, `0x0051D4E0`).
pub const shapes_name = "inter\\simpod\\simgfx.spr";
const title_font_name = itac.large_font_name;
const pointer_shapes_name = main_menu.shapes_name;

/// The pictures behind its screens: the first and the last frame of `training_movie`
/// (`0x004EBC64`, `0x004EBC28`, which `background_set_tga` names with `.tga`).
const simulator_picture = "inter\\simpod\\training_00000.tga";
const training_picture = "inter\\simpod\\training_00035.tga";

/// The movie the training missions' screen comes on with (`0x004EBC0C`), and those the Yamato's
/// pod opens and closes with, for a mission after 18 (`0x004EBC80`, `0x004EBBE8`).
const training_movie = "inter\\simpod\\training.bik";
const opening_movie = "inter\\simpod\\hud_controls_up_.bik";
const closing_movie = "inter\\simpod\\hud_controls_down.bik";

/// The screen's title, in the ITAC's large font, from its left (`0x0044FA3A`): FLIGHT SIMULATOR
/// in orange, and on the training missions' screen Training Missions in green.
const title_at: [2]i32 = .{ 0x2A, 0x55 };
const simulator_title = 0x3C6;
const simulator_title_colour = hud.rgb(0xC18415);
const training_title = 0x101;
const training_title_colour = hud.rgb(0x00E200);

/// The pointer's shapes in the front end's set, from the first, one for every `pointer_ticks` game
/// ticks, round `pointer_wrap` (`0x0044FA65`, `0x0044F7D4`).
const first_pointer_shape = 1;
const pointer_ticks = 4;
const pointer_wrap = 0x40;

/// The block of `simgfx.spr` and of the front end's set whose palette the choices and the pointer
/// are drawn with (`0x0044F876`, `0x0044FA4C`).
const palette_block = 0;

/// The pod's two screens (`0x00524FDC`): 0, FLIGHT SIMULATOR, and 1, the training missions'.
pub const Screen = enum { simulator, training };

/// A mission of the simulator: its number, which names its file, `mission%d.dte`, and the
/// simulator it runs in.
pub const Mission = struct {
    number: u16,
    simulator: create.Simulator,

    /// The flight of it: in a Grendel, ship type 2, whatever the loadout chose (`player_loadouts`,
    /// `0x0044F6DF`), flown by the pod, which comes back after it.
    pub fn flight(mission: Mission) main_menu.Flight {
        return .{
            .mission = mission.number,
            .ship = @intFromEnum(gameobj.Type.grendel),
            .simulator = mission.simulator,
            .flier = .simulator_pod,
        };
    }
};

/// The training missions, in the simulator's training (`simulator_mode` 1, `0x0044F66E`), by the
/// names `mission31`, `mission30` and `mission32` (`0x004EBCD4` on) and the numbers 31, 30 and 32
/// (`0x0044F3F4` on).
pub fn training(number: u16) Mission {
    return .{ .number = number, .simulator = .{ .mode = .training } };
}

/// Instant Action, mission 29 (`0x004EBC44`), in its simulator (`simulator_mode` 2 and
/// `simulator`, `0x0044F6A2`, `0x0044F6B4`), as the main menu's INSTANT ACTION flies it.
pub const instant_action: Mission = .{
    .number = create.instant_action_mission,
    .simulator = main_menu.instant_action.simulator,
};

/// What a choice leads to.
pub const Choice = union(enum) {
    /// The training missions' screen, its movie first.
    training,
    /// A mission flown.
    mission: Mission,
    /// Out of the pod.
    leave,
};

/// A choice of a screen (`0x004EBB38`, a record of 0x58 bytes a screen): where the pointer finds
/// it, inside `rect`, its edges left out; the shape that lights it, drawn a pixel in from the
/// rectangle's corner; the string that names it; and what it leads to. The record's next screens
/// (`+0x28`) are read only on the first screen, whose first choice leads to the training missions'.
pub const Item = struct {
    rect: Rect,
    lit: u16,
    name: u32,
    choice: Choice,
};

/// The round buttons' and the corner buttons' rectangles.
fn round(x: i16, y: i16) Rect {
    return .{ .x = x, .y = y, .width = 111, .height = 111 };
}

fn corner(x: i16, y: i16) Rect {
    return .{ .x = x, .y = y, .width = 80, .height = 80 };
}

/// Each screen's choices: Training Missions, Instant Action and Leave Simulator; then Mission 1 -
/// Instrument Training, Mission 2 - Flight Training, Mission 3 - Weapons Training, Leave Simulator
/// and Instant Action.
pub const items = std.EnumArray(Screen, []const Item).init(.{
    .simulator = &.{
        .{ .rect = round(265, 164), .lit = 4, .name = 0x101, .choice = .training },
        .{ .rect = round(265, 328), .lit = 5, .name = 0x102, .choice = .{ .mission = instant_action } },
        .{ .rect = corner(546, 18), .lit = 7, .name = 0x104, .choice = .leave },
    },
    .training = &.{
        .{ .rect = round(100, 164), .lit = 2, .name = 0x106, .choice = .{ .mission = training(31) } },
        .{ .rect = round(265, 164), .lit = 1, .name = 0x105, .choice = .{ .mission = training(30) } },
        .{ .rect = round(265, 328), .lit = 3, .name = 0x107, .choice = .{ .mission = training(32) } },
        .{ .rect = corner(546, 18), .lit = 6, .name = 0x104, .choice = .leave },
        .{ .rect = corner(546, 114), .lit = 8, .name = 0x102, .choice = .{ .mission = instant_action } },
    },
});

/// The choice of `screen` the point `at` is inside, by its place; null for none.
pub fn itemAt(screen: Screen, at: [2]i32) ?usize {
    for (items.get(screen), 0..) |item, index| {
        if (item.rect.holds(at)) return index;
    }
    return null;
}

/// What the pod reads and plays with.
pub const Context = struct {
    rooms: rooms.Context,
    /// The rooms' steps and doors, which a choice taken sounds from.
    steps: rooms.Steps = .{},
};

/// A pass's input.
pub const Input = struct {
    keyboard: *input.Keyboard,
    pointer: canvas_module.Pointer,
    /// The game's ticks.
    ticks: u32,
};

/// What a pass asks of the loop.
pub const Step = union(enum) {
    /// A movie to play in a loop of its own before the next pass.
    play: movie.Named,
    /// A mission to fly, after which the pod comes back (`Pod.back`).
    fly: main_menu.Flight,
    /// Out of the pod, as Escape or Leave Simulator leaves it (`Pod.leave`).
    closed,
};

pub const Pod = struct {
    context: Context,
    /// The mission the rooms come before, whose carrier the pod is the Yamato's after 18.
    mission: u16,
    screen: Screen = .simulator,
    /// The choice under the pointer, by its place (`vr_exit_under`, `0x00520184`).
    under: ?usize = null,
    /// The mission flown, which `back` comes back from.
    flying: ?Mission = null,
    picture: matmanager.Background = .{},
    shapes: ?canvas_module.Shapes = null,
    pointer_shapes: ?canvas_module.Shapes = null,
    title_font: ?canvas_module.FontFile = null,
    /// The pointer as the pass read it, and its animation's ticks.
    pointer: canvas_module.Pointer = .{},
    pointer_clock: canvas_module.PointerClock = .{},

    /// Opens it before mission `mission`, at the game's `ticks`, with its shapes and font from
    /// `resource.hog`, on FLIGHT SIMULATOR; what is missing is left out, which the log says.
    pub fn open(context: Context, mission: u16, ticks: u32) Pod {
        const gpa = context.rooms.gpa;
        const resources = context.rooms.resources;
        var pod: Pod = .{ .context = context, .mission = mission, .pointer_clock = .{ .last = ticks } };
        pod.shapes = .readWith(gpa, resources, shapes_name, palette_block);
        pod.pointer_shapes = .readWith(gpa, resources, pointer_shapes_name, palette_block);
        pod.title_font = .read(gpa, resources, title_font_name);
        pod.show(simulator_picture);
        return pod;
    }

    /// Lets go of what it read.
    pub fn deinit(pod: *Pod) void {
        const gpa = pod.context.rooms.gpa;
        pod.picture.deinit(gpa);
        if (pod.shapes) |*shapes| shapes.deinit(gpa);
        if (pod.pointer_shapes) |*shapes| shapes.deinit(gpa);
        if (pod.title_font) |*file| file.deinit(gpa);
        pod.* = undefined;
    }

    /// The movie it opens with: the Yamato's pod's, over the screen.
    pub fn opening(pod: Pod) ?movie.Named {
        return switch (rooms.Carrier.of(pod.mission)) {
            .reliant => null,
            .yamato => .{ .name = opening_movie, .kind = .over_screen },
        };
    }

    /// A pass of its loop: Escape leaves it; the left button down over a choice takes it, as long
    /// as it is down.
    pub fn pass(pod: *Pod, in: Input) ?Step {
        pod.pointer = in.pointer;
        if (in.keyboard.pressed(input.scan.escape, .none, true)) return .closed;
        pod.under = itemAt(pod.screen, in.pointer.at);
        defer pod.pointer_clock.advance(in.ticks, pointer_wrap);
        if (!in.pointer.down) return null;
        const index = pod.under orelse return null;
        switch (items.get(pod.screen)[index].choice) {
            .leave => return .closed,
            .training => {
                pod.playChoice();
                pod.show(training_picture);
                pod.screen = .training;
                return .{ .play = .{ .name = training_movie, .kind = .over_screen } };
            },
            .mission => |mission| {
                // The sound again as the mission is taken (`0x0044F622`); then the front end let go
                // (`0x004AD3B0`), which ends every voice, the two among them, and the rooms' hum.
                pod.playChoice();
                pod.playChoice();
                pod.context.rooms.sound.endAll();
                pod.flying = mission;
                return .{ .fly = mission.flight() };
            },
        }
    }

    /// Back from the mission flown (`0x0044F70F` on): the training missions' screen after a
    /// training mission, and FLIGHT SIMULATOR after Instant Action.
    pub fn back(pod: *Pod) void {
        const flown = pod.flying orelse return;
        pod.flying = null;
        if (flown.simulator.mode == .training) {
            pod.show(training_picture);
        } else {
            pod.show(simulator_picture);
            pod.screen = .simulator;
        }
    }

    /// Out of the pod (`0x0044F807` on): every sound ended, then on the Yamato its movie out.
    pub fn leave(pod: *Pod) ?movie.Named {
        pod.context.rooms.sound.endAll();
        return switch (rooms.Carrier.of(pod.mission)) {
            .reliant => null,
            .yamato => .{ .name = closing_movie, .kind = .over_screen },
        };
    }

    /// The frame (`0x0044F840`): the picture, the choice under the pointer lit and its name, the
    /// screen's title, and the pointer.
    pub fn draw(pod: *Pod, canvas: Canvas) canvas_module.Error!void {
        if (pod.picture.image) |*image| canvas.fill(image);
        if (pod.under) |index| {
            const item = items.get(pod.screen)[index];
            if (pod.shapes) |*shapes| try canvas.shape(&shapes.art, item.lit, .{ item.rect.x + 1, item.rect.y + 1 });
            try canvas.label(item.name);
        }
        if (pod.title_font) |*file| switch (pod.screen) {
            .simulator => try canvas.string(&file.font, title_at, simulator_title, simulator_title_colour, .left),
            .training => try canvas.string(&file.font, title_at, training_title, training_title_colour, .left),
        };
        if (pod.pointer_shapes) |*shapes| try canvas.shape(&shapes.art, pod.pointerShape(), pod.pointer.at);
    }

    /// The pointer's shape.
    fn pointerShape(pod: Pod) usize {
        return first_pointer_shape + pod.pointer_clock.ticks / pointer_ticks;
    }

    /// The sound of a choice taken.
    fn playChoice(pod: Pod) void {
        pod.context.steps.play(pod.context.rooms.sound, .pod_choice);
    }

    /// The picture `name` behind the screen (`background_set_tga`).
    fn show(pod: *Pod, name: []const u8) void {
        pod.picture.show(pod.context.rooms.gpa, pod.context.rooms.resources.*, name);
    }
};

test items {
    // The first screen's choices, and the training missions' by their names: mission 1 is
    // mission31.dte, mission 2 mission30.dte and mission 3 mission32.dte.
    try std.testing.expectEqual(Choice.training, items.get(.simulator)[itemAt(.simulator, .{ 300, 200 }).?].choice);
    try std.testing.expectEqual(31, items.get(.training)[itemAt(.training, .{ 150, 200 }).?].choice.mission.number);
    try std.testing.expectEqual(30, items.get(.training)[itemAt(.training, .{ 300, 200 }).?].choice.mission.number);
    try std.testing.expectEqual(32, items.get(.training)[itemAt(.training, .{ 300, 400 }).?].choice.mission.number);
    try std.testing.expectEqual(Choice.leave, items.get(.training)[itemAt(.training, .{ 580, 50 }).?].choice);
    // The rectangles' edges are left out, and the training missions are not on the first screen.
    try std.testing.expectEqual(null, itemAt(.simulator, .{ 265, 200 }));
    try std.testing.expectEqual(null, itemAt(.simulator, .{ 150, 200 }));
    // Instant Action is the main menu's, mission 29 in its simulator, flown in a Grendel by the pod.
    const flight = instant_action.flight();
    try std.testing.expectEqual(29, flight.mission);
    try std.testing.expectEqual(main_menu.instant_action.simulator, flight.simulator);
    try std.testing.expectEqual(@intFromEnum(gameobj.Type.grendel), flight.ship.?);
    try std.testing.expect(!flight.byWinMain());
    try std.testing.expectEqual(create.Simulator.Mode.training, training(30).flight().simulator.mode);
}

test Pod {
    // Its files are there but unreadable, and left out.
    var tested: rooms.testing.Tested = undefined;
    try tested.init(&.{}, &.{}, &.{
        .{ .name = "simgfx.spr", .data = "x" },
        .{ .name = "itacbig.fnt", .data = "x" },
        .{ .name = "frontend.spr", .data = "x" },
        .{ .name = "training_00000.tga", .data = "x" },
        .{ .name = "training_00035.tga", .data = "x" },
    });
    defer tested.deinit();
    var keyboard: input.Keyboard = .{};
    var pod: Pod = .open(.{ .rooms = tested.context() }, 18, 0);
    defer pod.deinit();
    // The Reliant's pod opens and closes without a movie; the Yamato's, after mission 18, with its
    // own.
    try std.testing.expectEqual(null, pod.opening());
    pod.mission = 19;
    try std.testing.expectEqualStrings(opening_movie, pod.opening().?.name);
    pod.mission = 18;

    // The pointer over Training Missions lights it; the left button takes it, through its movie.
    try std.testing.expectEqual(null, pod.pass(.{ .keyboard = &keyboard, .pointer = .{ .at = .{ 300, 200 } }, .ticks = 0 }));
    try std.testing.expectEqual(0, pod.under.?);
    const shown = pod.pass(.{ .keyboard = &keyboard, .pointer = .{ .at = .{ 300, 200 }, .down = true }, .ticks = 4 }).?;
    try std.testing.expectEqualStrings(training_movie, shown.play.name);
    try std.testing.expectEqual(.training, pod.screen);
    // Mission 2 is flown, and the training missions' screen comes back after it.
    const flown = pod.pass(.{ .keyboard = &keyboard, .pointer = .{ .at = .{ 300, 200 }, .down = true }, .ticks = 8 }).?;
    try std.testing.expectEqual(30, flown.fly.mission);
    pod.back();
    try std.testing.expectEqual(.training, pod.screen);
    // Instant Action brings back FLIGHT SIMULATOR after it.
    _ = pod.pass(.{ .keyboard = &keyboard, .pointer = .{ .at = .{ 580, 150 }, .down = true }, .ticks = 12 });
    pod.back();
    try std.testing.expectEqual(.simulator, pod.screen);
    // Leave Simulator closes it, and so does Escape.
    try std.testing.expectEqual(Step.closed, pod.pass(.{ .keyboard = &keyboard, .pointer = .{ .at = .{ 580, 50 }, .down = true }, .ticks = 16 }).?);
    try std.testing.expectEqual(null, pod.leave());
}

test "the pod's pointer turns through the front end's shapes" {
    var pod: Pod = undefined;
    pod.pointer_clock = .{};
    try std.testing.expectEqual(1, pod.pointerShape());
    pod.pointer_clock.advance(pointer_wrap - 1, pointer_wrap);
    try std.testing.expectEqual(16, pod.pointerShape());
    pod.pointer_clock.advance(pointer_wrap, pointer_wrap);
    try std.testing.expectEqual(1, pod.pointerShape());
}
