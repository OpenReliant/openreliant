//! The front end's main menu, its screen 0 (`main_menu`, `0x00428B60`), drawn by `main_menu_draw`
//! (`0x004291C0`), the render hook it puts in `sr + 0x88`.
//!
//! **Unverified:** the file. The menu lies between GenILib's `interf.cpp` and `interface.cpp`'s
//! known code; it is one of the game's screens rather than what runs them, so it goes with
//! `interface.cpp`.

const std = @import("std");
const assert = std.debug.assert;

const fat = @import("../../../formats/fat.zig");
const input = @import("../../input.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const hog_snd = @import("../hog_snd.zig");
const hud = @import("../hud.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Label = canvas_module.Label;
const Rect = canvas_module.Rect;
const dialog = @import("dialog.zig");

/// What the menu shows behind itself (`background_set`), its shapes (`interface_shapes`), and the
/// music it starts when none is playing, at 127.
pub const background_name = "interface\\sl_splash2.tga";
pub const shapes_name = "interface\\frontend.spr";
pub const music_name = "music\\New_Pensive.wav";
pub const music_level = 0x7F;

/// The menu's items, in the order of its table.
pub const Item = enum(u3) { single_player, multi_player, game_options, quit, instant_action };

/// A hotspot of the menu (`main_menu_hotspots`, `0x004E5B90`): where the pointer finds its item,
/// what choosing it returns, and the shape a panel shows under the pointer. The buttons' shape goes
/// unused: the drawing lights them with `lit_button_shape`.
pub const Hotspot = extern struct {
    rect: Rect,
    result: Result,
    shape: i16,

    /// What choosing an item returns: its screen, or first the question whether to quit.
    pub const Result = enum(i16) {
        go = 0,
        quit = 3,
        _,
    };
};

comptime {
    assert(@sizeOf(Hotspot) == 12);
}

pub const hotspots = std.EnumArray(Item, Hotspot).init(.{
    .single_player = .{ .rect = .{ .x = 27, .y = 123, .width = 184, .height = 290 }, .result = .go, .shape = 18 },
    .multi_player = .{ .rect = .{ .x = 203, .y = 125, .width = 184, .height = 290 }, .result = .go, .shape = 19 },
    .game_options = .{ .rect = .{ .x = 421, .y = 165, .width = 184, .height = 290 }, .result = .go, .shape = 20 },
    .quit = .{ .rect = .{ .x = 332, .y = 441, .width = 20, .height = 15 }, .result = .quit, .shape = 24 },
    .instant_action = .{ .rect = .{ .x = 300, .y = 441, .width = 20, .height = 15 }, .result = .go, .shape = 24 },
});

/// A panel's two lines, in the large font, centred under it; QUIT and INSTANT ACTION have none.
fn panelLabels(item: Item) ?[2]Label {
    return switch (item) {
        .single_player => .{ .of(0xBD, .{ 0x74, 0x154 }, .centre), .of(0xBF, .{ 0x74, 0x164 }, .centre) },
        .multi_player => .{ .of(0x5B4, .{ 0x140, 0x154 }, .centre), .of(0x5B5, .{ 0x140, 0x164 }, .centre) },
        .game_options => .{ .of(0xC0, .{ 0x20C, 0x154 }, .centre), .of(0xC1, .{ 0x20C, 0x164 }, .centre) },
        .quit, .instant_action => null,
    };
}

/// QUIT and INSTANT ACTION (`main_menu_draw`): their buttons' shapes, lit under the pointer, and
/// their labels in the small font, to the button's right and left.
const button_shape = 0x1B;
const lit_button_shape = 0x1C;
const quit_button: [2]i32 = .{ 0x14C, 0x1B9 };
const instant_action_button: [2]i32 = .{ 0x12C, 0x1B9 };
const quit_label: Label = .of(0xBC, .{ 0x168, 0x1B7 }, .left);
const instant_action_label: Label = .of(0x288, .{ 0x128, 0x1B7 }, .right);

/// The question QUIT asks (`0x00428EFF`): Do you really want to Quit?
pub const quit_question = 0x374;

/// The click, a sound of `bank_stdsmp`, as the item chosen plays it: at 127, panned to the middle.
const click_sound = 0xB;
const click_volume = 0x7F;
const click_pan = 0x40;

/// The developers' code (`0x00428B71`): POTATO, each letter typed with Control, which turns on the
/// developers' keys (`developer_mode`, `0x005D5641`) until the game quits.
const code = [_]input.Key{ .p, .o, .t, .a, .t, .o };

/// With the developers' keys on: the mission they start is written at the top left, `M` and its
/// number, in red in `font_01.fnt` (`font_01`, `0x0059506C`).
pub const developer_font_name = "font_01.fnt";
const developer_text_at: [2]i32 = .{ 5, 5 };

/// The developers' keys that start a mission without its briefing, with Shift, and the ship type
/// each gives the player: F1 to F10 the first ten, then F11 and F12.
const ship_keys = [_]input.Key{ .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 };

/// The number keys, which type the digits 1 to 9 and 0 of the developers' mission.
const digit_keys = [_]input.Key{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .zero };

/// Where the menu leads.
pub const Choice = union(enum) {
    /// SINGLE PLAYER's screen, the pilot roster, MULTI PLAYER's, the connection, and GAME
    /// OPTIONS'.
    pilot_roster,
    connection,
    game_options,
    /// INSTANT ACTION (`instant_action`).
    instant_action,
    /// QUIT, answered YES.
    quit,
    /// A mission the developers' keys start, without its briefing (`skip_briefing`).
    fly: Flight,
    /// The developers' Enter with Control: the briefing of the mission their keys name, from its
    /// loadout on (`briefing_from_loadout`, `0x0051DB48`), the front end's screen 7 next.
    briefing: u16,
};

/// A mission to fly: its number, the ship type the loadout gives the player, or null for the ship
/// the mission gives, the simulator it runs in, and what flies it.
pub const Flight = struct {
    mission: u16,
    ship: ?u8 = null,
    /// The racks the loadout fitted the ship with, where it ran (`player_loadouts + 4` on); none
    /// where the mission starts without it, when the player's ship is fitted by its tier
    /// (`skip_briefing`, `0x005883B4`).
    racks: ?create.Racks = null,
    simulator: create.Simulator = .{},
    flier: Flier = .winmain,

    /// What flies a mission, and so what follows it.
    pub const Flier = enum {
        /// `WinMain`, with the hangar's movie before it and the landing after
        /// (`xtrabits.movie.Hangar`, `xtrabits.landing`).
        winmain,
        /// The main menu, INSTANT ACTION's, which comes back to itself.
        main_menu,
        /// The simulator pod, which comes back to itself (`interface.loadout.simulator_pod`).
        simulator_pod,
    };

    /// Whether `WinMain` flies it.
    pub fn byWinMain(flight: Flight) bool {
        return flight.flier == .winmain;
    }
};

/// INSTANT ACTION (`0x0042905B` to `0x004290E4`): mission 29 in a Grendel, ship type 2, in the
/// simulator of its mode, which the main menu flies again for as long as RESTART starts it again,
/// then comes back to itself. It keeps the mission's number and the pilot's kills as they were.
pub const instant_action: Flight = .{
    .mission = create.instant_action_mission,
    .ship = @intFromEnum(gameobj.Type.grendel),
    .simulator = .{ .mode = .instant_action, .instant_action = true },
    .flier = .main_menu,
};

/// What a frame of the menu reads and plays through.
pub const Context = struct {
    pointer: Pointer,
    keyboard: *input.Keyboard,
    sound: ?*hog_snd.Sound = null,
    /// `bank_stdsmp`, which the click plays from.
    bank: ?fat.Bank = null,
};

/// The menu's state.
pub const MainMenu = struct {
    /// The item under the pointer (`0x0051D544`).
    under: ?Item = null,
    /// How much of the developers' code has been typed.
    typed: usize = 0,
    /// Whether the developers' keys are on (`0x005D5641`).
    developer: bool = false,
    /// The mission the developers' keys start (`mission_number`), whose number they type.
    mission: u16 = 1,
    /// QUIT's question while it is up.
    confirm: ?dialog.Confirm = null,

    /// Entering the menu, as `main_menu` does before its loop: the pointer at (320, 200), and the
    /// music started where none is playing. The game also starts a new campaign
    /// (`campaign_new`); OpenReliant, which has no campaign yet, starts every mission from a new
    /// campaign's variables (`gameflow.restartPoint`).
    pub fn enter(menu: *MainMenu, pointer: *Pointer, sound: ?*hog_snd.Sound) void {
        menu.under = null;
        menu.confirm = null;
        pointer.at = .{ 320, 200 };
        if (sound) |playing| if (!playing.musicPlaying()) playing.playMusic(music_name, 0, music_level, .now);
    }

    /// A pass of `main_menu`'s loop: Escape, or QUIT, asks whether to quit, and while the
    /// question is up it takes the frame (`interface_confirm`). Otherwise the developers' code and
    /// keys, then the item under the pointer, chosen while the pointer's button is down, with a
    /// click.
    pub fn frame(menu: *MainMenu, context: Context) ?Choice {
        const keyboard = context.keyboard;
        const escaped = keyboard.pressed(input.scan.escape, .none, true);
        if (menu.confirm) |*confirm| {
            const answer = confirm.frame(context.pointer, escaped) orelse return null;
            menu.confirm = null;
            return if (answer) .quit else null;
        }
        if (escaped) {
            menu.confirm = .{ .message = .{ .string = quit_question } };
            return null;
        }
        if (menu.typed < code.len and keyboard.pressed(@intFromEnum(code[menu.typed]), .control, true)) {
            menu.typed += 1;
            if (menu.typed == code.len) menu.developer = true;
        }
        if (menu.developer) if (menu.developerKeys(keyboard)) |choice| return choice;

        menu.under = for (std.enums.values(Item)) |item| {
            if (hotspots.get(item).rect.holds(context.pointer.at)) break item;
        } else null;
        const chosen = menu.under orelse return null;
        if (!context.pointer.down) return null;
        if (context.sound) |sound| if (context.bank) |bank| {
            _ = sound.play(bank, click_sound, click_volume, 1, click_pan, 0);
        };
        if (hotspots.get(chosen).result == .quit) {
            menu.confirm = .{ .message = .{ .string = quit_question } };
            return null;
        }
        return switch (chosen) {
            .single_player => .pilot_roster,
            .multi_player => .connection,
            .game_options => .game_options,
            .instant_action => .instant_action,
            .quit => unreachable,
        };
    }

    /// The developers' keys (`0x00428C9B` on): Enter with Shift starts the mission without its
    /// briefing in the first ship type, as Shift with F1 does, and with Control leads to its
    /// briefing from the loadout on; Shift and F1 to F12 start it without its briefing, in the
    /// key's ship type. A number key types a digit of the mission's number: after a single digit it
    /// adds one, after two it starts again.
    fn developerKeys(menu: *MainMenu, keyboard: *input.Keyboard) ?Choice {
        const enter_key = @intFromEnum(input.Key.enter);
        if (keyboard.pressed(enter_key, .shift, true)) return .{ .fly = .{ .mission = menu.mission, .ship = 0 } };
        if (keyboard.pressed(enter_key, .control, true)) return .{ .briefing = menu.mission };
        for (ship_keys, 0..) |key, ship| {
            if (keyboard.pressed(@intFromEnum(key), .shift, true)) return .{ .fly = .{ .mission = menu.mission, .ship = @intCast(ship) } };
        }
        for (digit_keys, 1..) |key, value| {
            if (!keyboard.pressed(@intFromEnum(key), .none, true)) continue;
            const digit: u16 = @intCast(value % 10);
            menu.mission = if (menu.mission < 10) menu.mission * 10 + digit else digit;
            break;
        }
        return null;
    }

    /// `main_menu_draw`: the panels' labels in blue, QUIT's and INSTANT ACTION's buttons and labels,
    /// the item under the pointer lit and a panel's labels in gold, QUIT's question where it is
    /// up, then the pointer, and with the developers' keys on the mission's number. The menu's
    /// background is drawn behind it all (`background_set`).
    pub fn draw(menu: MainMenu, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, pointer: Pointer, developer_font: ?*hud.Opened) canvas_module.Error!void {
        const large = canvas.fonts.large;
        const small = canvas.fonts.small;
        for (std.enums.values(Item)) |item| {
            for (panelLabels(item) orelse continue) |label| try label.write(canvas, large, canvas_module.blue);
        }
        try quit_label.write(canvas, small, canvas_module.blue);
        try instant_action_label.write(canvas, small, canvas_module.blue);
        try canvas.shape(art, button_shape, quit_button);
        try canvas.shape(art, button_shape, instant_action_button);
        if (menu.under) |under| {
            switch (under) {
                .single_player, .multi_player, .game_options => {
                    const hotspot = hotspots.get(under);
                    try canvas.shape(art, @intCast(hotspot.shape), .{ hotspot.rect.x, hotspot.rect.y });
                    for (panelLabels(under).?) |label| try label.write(canvas, large, canvas_module.gold);
                },
                .quit => try canvas.shape(art, lit_button_shape, quit_button),
                .instant_action => try canvas.shape(art, lit_button_shape, instant_action_button),
            }
        }
        if (menu.confirm) |confirm| try confirm.draw(canvas, dialog_art);
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
        if (menu.developer) if (developer_font) |font| {
            var buffer: [16]u8 = undefined;
            const number = std.fmt.bufPrint(&buffer, "M{d}", .{menu.mission}) catch return;
            try canvas.text(font, developer_text_at, number, canvas_module.red, .left);
        };
    }
};

test "an item is found under the pointer, and chosen while the button is down" {
    var keyboard: input.Keyboard = .{};
    var menu: MainMenu = .{};
    try std.testing.expectEqual(null, menu.frame(.{ .pointer = .{ .at = .{ 100, 200 } }, .keyboard = &keyboard }));
    try std.testing.expectEqual(.single_player, menu.under);
    try std.testing.expectEqual(Choice.pilot_roster, menu.frame(.{ .pointer = .{ .at = .{ 100, 200 }, .down = true }, .keyboard = &keyboard }).?);
    try std.testing.expectEqual(Choice.game_options, menu.frame(.{ .pointer = .{ .at = .{ 500, 300 }, .down = true }, .keyboard = &keyboard }).?);
    try std.testing.expectEqual(Choice.instant_action, menu.frame(.{ .pointer = .{ .at = .{ 310, 450 }, .down = true }, .keyboard = &keyboard }).?);
    // Nothing under the pointer, nothing chosen.
    try std.testing.expectEqual(null, menu.frame(.{ .pointer = .{ .at = .{ 5, 5 }, .down = true }, .keyboard = &keyboard }));
    try std.testing.expectEqual(null, menu.under);
}

test "QUIT asks first" {
    var keyboard: input.Keyboard = .{};
    var menu: MainMenu = .{};
    try std.testing.expectEqual(null, menu.frame(.{ .pointer = .{ .at = .{ 340, 450 }, .down = true }, .keyboard = &keyboard }));
    try std.testing.expect(menu.confirm != null);
    // YES, once the button comes up, quits.
    try std.testing.expectEqual(null, menu.frame(.{ .pointer = .{ .at = .{ 295, 275 }, .down = true }, .keyboard = &keyboard }));
    try std.testing.expectEqual(Choice.quit, menu.frame(.{ .pointer = .{ .at = .{ 295, 275 } }, .keyboard = &keyboard }).?);
}

test "Escape asks to quit, and NO goes back to the menu" {
    var keyboard: input.Keyboard = .{};
    var menu: MainMenu = .{};
    keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, menu.frame(.{ .pointer = .{}, .keyboard = &keyboard }));
    try std.testing.expect(menu.confirm != null);
    keyboard.down[input.scan.escape] = false;
    _ = menu.frame(.{ .pointer = .{ .at = .{ 340, 275 }, .down = true }, .keyboard = &keyboard });
    try std.testing.expectEqual(null, menu.frame(.{ .pointer = .{ .at = .{ 340, 275 } }, .keyboard = &keyboard }));
    try std.testing.expectEqual(null, menu.confirm);
}

test "the developers' code and keys" {
    var keyboard: input.Keyboard = .{};
    var menu: MainMenu = .{};
    const control = @intFromEnum(input.Key.left_control);
    keyboard.down[control] = true;
    for (code) |letter| {
        const key = @intFromEnum(letter);
        keyboard.down[key] = true;
        _ = menu.frame(.{ .pointer = .{}, .keyboard = &keyboard });
        keyboard.down[key] = false;
        keyboard.latched[key] = false;
    }
    keyboard.down[control] = false;
    try std.testing.expect(menu.developer);
    // Typing 1 then 5 picks mission 15.
    menu.mission = 0;
    for ([_]input.Key{ .one, .five }) |digit| {
        const key = @intFromEnum(digit);
        keyboard.down[key] = true;
        _ = menu.frame(.{ .pointer = .{}, .keyboard = &keyboard });
        keyboard.down[key] = false;
        keyboard.latched[key] = false;
    }
    try std.testing.expectEqual(15, menu.mission);
    // Shift and F3 start it without its briefing in ship type 2.
    keyboard.down[@intFromEnum(input.Key.left_shift)] = true;
    keyboard.down[@intFromEnum(input.Key.f3)] = true;
    const flight = menu.frame(.{ .pointer = .{}, .keyboard = &keyboard }).?.fly;
    try std.testing.expectEqual(Flight{ .mission = 15, .ship = 2 }, flight);
    try std.testing.expect(flight.byWinMain());
    try std.testing.expect(!instant_action.byWinMain());
    keyboard.down[@intFromEnum(input.Key.f3)] = false;
    // Shift and Enter start it without its briefing in ship type 0; Control and Enter lead to its
    // briefing from the loadout on.
    const enter = @intFromEnum(input.Key.enter);
    keyboard.down[enter] = true;
    try std.testing.expectEqual(Flight{ .mission = 15, .ship = 0 }, menu.frame(.{ .pointer = .{}, .keyboard = &keyboard }).?.fly);
    keyboard.down[enter] = false;
    keyboard.latched[enter] = false;
    keyboard.down[@intFromEnum(input.Key.left_shift)] = false;
    keyboard.down[@intFromEnum(input.Key.left_control)] = true;
    keyboard.down[enter] = true;
    try std.testing.expectEqual(15, menu.frame(.{ .pointer = .{}, .keyboard = &keyboard }).?.briefing);
}
