//! The front end's pilot roster, its screen 12 (`pilot_roster`, `0x00430490`), which SINGLE
//! PLAYER opens, drawn by `pilot_roster_draw` (`0x00430C60`), the render hook it puts in
//! `sr + 0x88`. The pilot types a call sign or picks one of the last ten, and is male or female;
//! START GAME asks the game's difficulty (`DifficultyDialog`) and starts a new campaign, LOAD GAME
//! leads to the saved games, and MAIN MENU and QUIT to what they name.
//!
//! Not ported: writing the pilot's profile, `profile.bin`, which the roster does as the call sign
//! changes (`profile_save`, [#74](https://github.com/vdmkenny/openreliant/issues/74),
//! [#301](https://github.com/vdmkenny/openreliant/issues/301)).

const std = @import("std");
const assert = std.debug.assert;

const fnt = @import("../../../formats/fnt.zig");
const input = @import("../../input.zig");
const profile = @import("../../profile.zig");
const collision = @import("../collision.zig");
const hud = @import("../hud.zig");
const winmain = @import("../winmain.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const dialog = @import("dialog.zig");
const main_menu = @import("main_menu.zig");

const log = std.log.scoped(.interface);

/// What the roster shows behind itself (`background_set`) and its shapes (`interface_shapes`)
/// (`0x004E86C8`, `0x004E8358`): the pointer's, the two pilots, the buttons, and SET GAME
/// DIFFICULTY's box.
pub const background_name = "interface\\main2sin.tga";
pub const shapes_name = "interface\\frntend2.spr";

/// The roster's items, in the order of its rectangles, which `pilot_roster` lays out on the stack
/// (`0x0043049C` on): the two pilots, the buttons, the call sign's line, and the arrow that opens
/// the list of call signs.
pub const Item = enum(u3) { male, female, load_game, start_game, main_menu, call_sign, quit, list };

/// Where the pointer finds each item (`interface_hit`).
pub const rects = std.EnumArray(Item, Rect).init(.{
    .male = .{ .x = 62, .y = 145, .width = 111, .height = 228 },
    .female = .{ .x = 239, .y = 151, .width = 102, .height = 275 },
    .load_game = .{ .x = 397, .y = 295, .width = 133, .height = 20 },
    .start_game = .{ .x = 397, .y = 249, .width = 145, .height = 20 },
    .main_menu = .{ .x = 292, .y = 441, .width = 25, .height = 16 },
    .call_sign = .{ .x = 397, .y = 177, .width = 138, .height = 45 },
    .quit = .{ .x = 324, .y = 441, .width = 60, .height = 16 },
    .list = .{ .x = 543, .y = 200, .width = 27, .height = 15 },
});

/// How many call signs the list keeps and shows, a row each (`callsign_list`).
pub const list_rows = 10;

/// Where the list's rows stand, `row_spacing` apart down from the first (`0x0043056B` on), and
/// where each is drawn: its frame (`interface_box`), the black it is wiped to, and its call sign,
/// each across from the screen's left edge and down from the row's top.
const first_row: Rect = .{ .x = 400, .y = 223, .width = 136, .height = 20 };
const row_spacing = 25;
const row_box_at: [2]i32 = .{ 398, -2 };
const row_box_size: [2]i32 = .{ 140, 24 };
const row_wipe_to: [2]i32 = .{ 536, 20 };
const row_text_at: [2]i32 = .{ 404, 2 };

/// The rectangle of the list's row `row`.
fn rowRect(row: usize) Rect {
    var rect = first_row;
    rect.y += @intCast(row * row_spacing);
    return rect;
}

/// The game's strings the roster writes.
pub const String = enum(u32) {
    select_pilot = 0xB7,
    call_sign = 0xB8,
    start_game = 0xB9,
    load_game = 0xBA,
    main_menu = 0xBB,
    quit = 0xBC,
    /// The call sign the list's first place takes where `starlancer.ini` has none, and a new
    /// campaign's pilot where there is no profile (`campaign_new`).
    player = 0xBF,
    set_game_difficulty = 0x2A6,
    easy = 0x2A7,
    medium = 0x11C,
    hard = 0x2A8,
    back = 0xF7,
    start = 0x14A,
};

/// A line of the roster's text: its string, where it stands, in which font and how aligned.
const Label = struct { string: String, at: [2]i32, font: Font, alignment: hud.Align };
const Font = enum { large, small };

/// The labels `pilot_roster_draw` writes in blue (`0x00430D07` on), and again in white for the
/// button under the pointer.
const labels = std.EnumArray(String, ?Label).initDefault(@as(?Label, null), .{
    .select_pilot = .{ .string = .select_pilot, .at = .{ 217, 105 }, .font = .large, .alignment = .centre },
    .call_sign = .{ .string = .call_sign, .at = .{ 396, 168 }, .font = .large, .alignment = .left },
    .start_game = .{ .string = .start_game, .at = .{ 433, 247 }, .font = .large, .alignment = .left },
    .load_game = .{ .string = .load_game, .at = .{ 433, 298 }, .font = .large, .alignment = .left },
    .main_menu = .{ .string = .main_menu, .at = .{ 288, 440 }, .font = .small, .alignment = .right },
    .quit = .{ .string = .quit, .at = .{ 353, 440 }, .font = .small, .alignment = .left },
});

/// The shapes of the roster's set it draws, and where: the pilot chosen, lit, and the list's
/// arrow, lit under the pointer.
const male_shape = 19;
const female_shape = 20;
const male_at: [2]i32 = .{ 34, 114 };
const female_at: [2]i32 = .{ 200, 114 };
const arrow_shape = 24;
const lit_arrow_shape = 25;
const arrow_at: [2]i32 = .{ 543, 200 };

/// A button's shape, and the one it is lit with under the pointer, both drawn at its corner.
const ButtonShapes = struct { shape: usize, lit: usize };

/// The roster's large buttons and its small ones, which SET GAME DIFFICULTY's are too.
const large_button: ButtonShapes = .{ .shape = 22, .lit = 23 };
const small_button: ButtonShapes = .{ .shape = 26, .lit = 27 };

/// The items that are buttons: each button, its corner, and its label, which turns white while the
/// button is lit.
const Placed = struct { shapes: ButtonShapes, at: [2]i32, label: String };
const buttons = std.EnumArray(Item, ?Placed).initDefault(@as(?Placed, null), .{
    .start_game = .{ .shapes = large_button, .at = .{ 398, 249 }, .label = .start_game },
    .load_game = .{ .shapes = large_button, .at = .{ 398, 300 }, .label = .load_game },
    .main_menu = .{ .shapes = small_button, .at = .{ 292, 441 }, .label = .main_menu },
    .quit = .{ .shapes = small_button, .at = .{ 324, 441 }, .label = .quit },
});

/// The call sign's line: its frame (`interface_box`), where the call sign is written and how wide
/// it may grow (`text_entry_step`, `0x00430EF4`), and the cursor after it, which turns on and off
/// every `blink_ticks` while the call sign is typed (`0x00520164`).
const call_sign_box_at: [2]i32 = .{ 398, 192 };
const call_sign_box_size: [2]i32 = .{ 140, 28 };
const call_sign_at: [2]i32 = .{ 402, 197 };
const call_sign_width: u32 = 125;
const cursor = "_";
const cursor_at: [2]i32 = .{ 402, 200 };
const blink_ticks = 25;

/// The colour the roster ramps its text through besides blue (`canvas.blue`): white, for the call
/// sign while it is typed, the list's call signs, and the label under the pointer.
const white = canvas_module.white;

/// A line of text of at most `room` bytes, as the game keeps one, with its terminator, in a buffer
/// one longer.
pub fn Text(comptime room: usize) type {
    return struct {
        bytes: [room]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        /// The line, without its terminator.
        pub fn slice(text: *const Self) []const u8 {
            return text.bytes[0..text.len];
        }

        /// Takes `from`, as much of it as fits.
        ///
        /// **Fix:** the game copies a line into its buffer whatever its length; OpenReliant keeps
        /// what fits.
        pub fn set(text: *Self, from: []const u8) void {
            text.len = @min(from.len, room);
            @memcpy(text.bytes[0..text.len], from[0..text.len]);
        }
    };
}

/// The call sign (`call_sign`, `0x00562DCC`, 32 bytes) and each of the list's (50 bytes each).
pub const CallSign = Text(31);
pub const ListedCallSign = Text(49);

/// The call signs of the last ten pilots (`callsign_list`, `0x005D5E8C`), which `starlancer.ini`
/// keeps as `name00` to `name09` under `[CallsignList]` (`winmain.loadCallSigns`,
/// `winmain.saveCallSigns`). Every place counts as a row of the list, an empty one too
/// (`callsign_count`, `0x00595D98`).
pub const CallSigns = struct {
    names: [list_rows]ListedCallSign = @splat(.{}),

    /// `callsign_add` (`0x00430B80`): `call_sign` in the list, unless it is there already: in the
    /// first empty place, or once the list is full in the last, the rest moved up a place and the
    /// first let go. Returns whether the list changed.
    pub fn add(list: *CallSigns, call_sign: []const u8) bool {
        for (&list.names) |*name| {
            if (std.mem.eql(u8, name.slice(), call_sign)) return false;
        }
        const place = for (&list.names, 0..) |*name, place| {
            if (name.len == 0) break place;
        } else full: {
            std.mem.copyForwards(ListedCallSign, list.names[0 .. list_rows - 1], list.names[1..]);
            break :full list_rows - 1;
        };
        list.names[place].set(call_sign);
        return true;
    }
};

/// What the roster sets of the pilot, which the missions flown after it go by: the call sign
/// (`call_sign`), whether the pilot is female, whose own lines the radio then plays in the female
/// voice (`pilot_female`, `0x00562F16`), and the game's difficulty (`difficulty`, `0x00562F14`).
/// As the game starts, the call sign is the profile's (`gameflow.profileCallSign`) or none, the
/// pilot male, and the difficulty 0, easy, until SET GAME DIFFICULTY sets it, so INSTANT ACTION
/// chosen first is flown on easy.
pub const Pilot = struct {
    call_sign: CallSign = .{},
    female: bool = false,
    difficulty: collision.Difficulty = .easy,
};

/// SET GAME DIFFICULTY (`difficulty_dialog`, `0x00430300`), which START GAME puts up over the
/// roster (`difficulty_dialog_open`, `0x0051D534`): the difficulty starts at medium, the two arrows step it down and up,
/// going round, and START or BACK closes it. A press acts once, until the button comes up.
pub const DifficultyDialog = struct {
    /// The button under the pointer (`dialog_button`, `0x00520294`), and whether its press has
    /// acted.
    under: ?Button = null,
    acted: bool = false,

    /// Its buttons: START, BACK, and the two arrows.
    pub const Button = enum { start, back, easier, harder };

    /// Their rectangles, which it lays out on the stack (`0x00430303` on).
    pub const button_rects = std.EnumArray(Button, Rect).init(.{
        .start = .{ .x = 276, .y = 269, .width = 25, .height = 16 },
        .back = .{ .x = 338, .y = 269, .width = 25, .height = 16 },
        .easier = .{ .x = 253, .y = 222, .width = 16, .height = 26 },
        .harder = .{ .x = 270, .y = 222, .width = 16, .height = 26 },
    });

    /// How it closes: to start the campaign, or back to the roster.
    pub const Answer = enum { start, back };

    /// Puts it up, the difficulty set to medium (`0x00430384`).
    pub fn open(difficulty: *collision.Difficulty) DifficultyDialog {
        difficulty.* = .medium;
        return .{};
    }

    /// A pass of its loop, `escaped` whether Escape went down since the last: Escape goes back.
    pub fn frame(box: *DifficultyDialog, pointer: Pointer, escaped: bool, difficulty: *collision.Difficulty) ?Answer {
        if (escaped) return .back;
        box.under = canvas_module.itemAt(Button, &button_rects, pointer.at);
        const under = box.under orelse return null;
        if (!pointer.down) {
            box.acted = false;
            return null;
        }
        if (box.acted) return null;
        box.acted = true;
        switch (under) {
            .start => return .start,
            .back => return .back,
            .easier => difficulty.* = if (difficulty.* == .easy) .hard else @enumFromInt(@intFromEnum(difficulty.*) - 1),
            .harder => difficulty.* = if (difficulty.* == .hard) .easy else @enumFromInt(@intFromEnum(difficulty.*) + 1),
        }
        return null;
    }

    /// Its part of `pilot_roster_draw` (`0x004312E5` on): the box, the arrows and the buttons, lit
    /// under the pointer, then the title, the difficulty, BACK and START in blue.
    fn draw(box: DifficultyDialog, canvas: Canvas, art: *hud.Art, difficulty: collision.Difficulty) canvas_module.Error!void {
        const large = canvas.fonts.large;
        try canvas.shape(art, dialog_shape, dialog_at);
        try canvas.shape(art, arrows_shape, arrows_at);
        try canvas.shape(art, small_button.shape, dialog_start_at);
        try canvas.shape(art, small_button.shape, dialog_back_at);
        if (box.under) |under| switch (under) {
            .start => try canvas.shape(art, small_button.lit, dialog_start_at),
            .back => try canvas.shape(art, small_button.lit, dialog_back_at),
            .easier => try canvas.shape(art, lit_easier_shape, arrows_at),
            .harder => try canvas.shape(art, lit_harder_shape, harder_at),
        };
        try canvas.string(large, dialog_title_at, @intFromEnum(String.set_game_difficulty), canvas_module.blue, .centre);
        try canvas.string(large, difficulty_at, @intFromEnum(difficultyName(difficulty)), canvas_module.blue, .left);
        try canvas.string(large, back_at, @intFromEnum(String.back), canvas_module.blue, .left);
        try canvas.string(large, start_at, @intFromEnum(String.start), canvas_module.blue, .right);
    }

    /// The dialog's shapes and places: its box, the arrows, each lit, its buttons, and its text.
    const dialog_shape = 34;
    const dialog_at: [2]i32 = .{ 114, 177 };
    const arrows_shape = 30;
    const lit_easier_shape = 31;
    const lit_harder_shape = 32;
    const arrows_at: [2]i32 = .{ 253, 222 };
    const harder_at: [2]i32 = .{ 270, 222 };
    const dialog_start_at: [2]i32 = .{ 276, 269 };
    const dialog_back_at: [2]i32 = .{ 338, 269 };
    const dialog_title_at: [2]i32 = .{ 320, 185 };
    const difficulty_at: [2]i32 = .{ 289, 222 };
    const back_at: [2]i32 = .{ 370, 264 };
    const start_at: [2]i32 = .{ 268, 264 };
};

/// The difficulty's name, from the dialog's table (`0x00430C6E`).
fn difficultyName(difficulty: collision.Difficulty) String {
    return switch (difficulty) {
        .easy => .easy,
        .medium, _ => .medium,
        .hard => .hard,
    };
}

/// Where the roster leads.
pub const Choice = enum {
    /// MAIN MENU, or Escape.
    main_menu,
    /// LOAD GAME: the saved games, screen 13.
    saved_games,
    /// START GAME, once SET GAME DIFFICULTY's START has been chosen: a new campaign
    /// (`campaign_new`).
    start_game,
    /// QUIT, answered YES.
    quit,
};

/// What a frame of the roster reads and changes.
pub const Context = struct {
    pointer: Pointer,
    keyboard: *input.Keyboard,
    /// The characters typed, which the call sign takes while it is typed.
    typed: *winmain.Typed,
    /// The timer's ticks since the last frame.
    elapsed: i32,
    /// The small font, by which the call sign's width is measured; none leaves the call sign as
    /// it is.
    small: ?*const hud.Opened,
    /// The pilot the roster sets.
    pilot: *Pilot,
    /// `starlancer.ini`, which keeps the list; none leaves it unsaved.
    settings: ?*profile.File = null,
};

/// The roster's state, which the game keeps in globals.
pub const Roster = struct {
    /// The item under the pointer (`roster_item`, `0x00520130`).
    under: ?Item = null,
    /// Whether the call sign is typed (`roster_typing`, `0x0052019C`), whether its cursor shows
    /// (`roster_cursor_shown`, `0x0052016C`), and the ticks since it last turned on or off.
    typing: bool = true,
    cursor_shown: bool = true,
    blinked: i32 = 0,
    /// Whether the list of call signs is open (`roster_list_open`, `0x005202B8`), and whether the
    /// arrow's press has already turned it.
    list_open: bool = false,
    list_turned: bool = false,
    /// A row picked, the button's release waited for before anything else is chosen.
    picked: bool = false,
    /// The last ten call signs.
    list: CallSigns = .{},
    /// SET GAME DIFFICULTY, while it is up.
    difficulty: ?DifficultyDialog = null,
    /// QUIT's question, while it is up.
    confirm: ?dialog.Confirm = null,

    /// Entering the roster, as `pilot_roster` does before its loop: the call sign typed afresh,
    /// its cursor on, the list closed, the pilot male, and the characters a file's name can't
    /// hold refused as they are typed (`winmain.Typed.file_names`).
    pub fn enter(roster: *Roster, typed: *winmain.Typed, pilot: *Pilot) void {
        roster.* = .{ .list = roster.list };
        pilot.female = false;
        typed.clear();
        typed.file_names = true;
    }

    /// Leaving the roster: the characters typed no longer refused.
    pub fn leave(typed: *winmain.Typed) void {
        typed.file_names = false;
    }

    /// A pass of `pilot_roster`'s loop. Escape leads to the main menu; SET GAME DIFFICULTY and
    /// QUIT's question, while up, take the frame. The cursor turns on or off every `blink_ticks`.
    /// Enter, or a click anywhere but on the call sign's line, ends the call sign's typing and
    /// puts it in the list. While the list is open, a click on a row takes its call sign, and the
    /// list covers START GAME and LOAD GAME. Otherwise the item under the pointer is chosen while
    /// the button is down: a pilot, a screen, the call sign's line to type it afresh, QUIT's
    /// question, or the list's arrow, which opens or closes it once for each press. While the
    /// call sign is typed, it takes a character typed each frame (`hud.typeInto`), as
    /// `pilot_roster_draw` has it.
    pub fn frame(roster: *Roster, context: Context) ?Choice {
        const keyboard = context.keyboard;
        const pointer = context.pointer;
        const pilot = context.pilot;
        const escaped = keyboard.pressed(input.scan.escape, .none, true);
        if (roster.confirm) |*confirm| {
            const answer = confirm.frame(pointer, escaped) orelse return null;
            roster.confirm = null;
            return if (answer) .quit else null;
        }
        if (roster.difficulty) |*box| {
            const answer = box.frame(pointer, escaped, &pilot.difficulty) orelse return null;
            roster.difficulty = null;
            return switch (answer) {
                .start => .start_game,
                .back => null,
            };
        }
        if (escaped) return .main_menu;
        roster.blinked += context.elapsed;
        if (roster.blinked > blink_ticks) {
            roster.blinked = 0;
            roster.cursor_shown = !roster.cursor_shown;
        }
        const enter_key = @intFromEnum(input.Key.enter);
        const keypad_enter = @intFromEnum(input.Key.keypad_enter);
        if (keyboard.pressed(enter_key, .none, true) or keyboard.pressed(keypad_enter, .none, true)) roster.finishTyping(context);

        roster.under = canvas_module.itemAt(Item, &rects, pointer.at);
        if (roster.under != .call_sign and pointer.down) roster.finishTyping(context);
        if (roster.list_open) {
            if (roster.under == .load_game or roster.under == .start_game) roster.under = null;
            if (canvas_module.hit(&rowRects(), pointer.at)) |row| if (pointer.down) {
                pilot.call_sign.set(roster.list.names[row].slice());
                roster.list_open = false;
                roster.list_turned = false;
                roster.picked = true;
            };
        }
        defer if (roster.typing) if (context.small) |small| {
            hud.typeInto(context.typed, &pilot.call_sign.bytes, &pilot.call_sign.len, .{ .font = small, .max_width = call_sign_width });
        };
        if (roster.picked) {
            if (!pointer.down) roster.picked = false;
            return null;
        }
        const chosen = roster.under orelse {
            roster.list_turned = false;
            return null;
        };
        if (!pointer.down) {
            roster.list_turned = false;
            return null;
        }
        switch (chosen) {
            .male => pilot.female = false,
            .female => pilot.female = true,
            .load_game => return .saved_games,
            .start_game => roster.difficulty = .open(&pilot.difficulty),
            .main_menu => return .main_menu,
            .call_sign => {
                roster.typing = true;
                context.typed.clear();
            },
            .quit => roster.confirm = .{ .message = .{ .string = main_menu.quit_question } },
            .list => if (!roster.list_turned) {
                roster.list_open = !roster.list_open;
                roster.list_turned = true;
            },
        }
        return null;
    }

    /// The call sign's typing ended (`0x004307B9`): the call sign put in the list, which
    /// `starlancer.ini` then keeps, where it wasn't there.
    fn finishTyping(roster: *Roster, context: Context) void {
        roster.typing = false;
        if (!roster.list.add(context.pilot.call_sign.slice())) return;
        const settings = context.settings orelse return;
        winmain.saveCallSigns(&roster.list, settings) catch |err| log.warn("the call signs are not kept: {s}", .{@errorName(err)});
    }

    /// `pilot_roster_draw`: the pilot chosen, lit; the labels in blue; the call sign's frame and
    /// the call sign, white while it is typed, with its cursor; the buttons and the list's arrow,
    /// and the button under the pointer lit with its label in white; the list, where it is open;
    /// SET GAME DIFFICULTY or QUIT's question, where either is up; then the pointer. The roster's
    /// background is drawn behind it all (`background_set`).
    pub fn draw(roster: Roster, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, pointer: Pointer, pilot: Pilot) canvas_module.Error!void {
        const small = canvas.fonts.small;
        if (pilot.female) try canvas.shape(art, female_shape, female_at) else try canvas.shape(art, male_shape, male_at);
        for (labels.values) |held| if (held) |label| try writeLabel(canvas, label, canvas_module.blue);
        canvas.box(call_sign_box_at, call_sign_box_size);
        try canvas.text(small, call_sign_at, pilot.call_sign.slice(), if (roster.typing) white else canvas_module.blue, .left);
        if (roster.typing and roster.cursor_shown) {
            const width: i32 = @intCast(small.textWidth(pilot.call_sign.slice()));
            try canvas.text(small, .{ cursor_at[0] + width, cursor_at[1] }, cursor, canvas_module.blue, .left);
        }
        try canvas.shape(art, if (roster.under == .list) lit_arrow_shape else arrow_shape, arrow_at);
        for (buttons.values) |held| if (held) |placed| try canvas.shape(art, placed.shapes.shape, placed.at);
        if (roster.under) |under| if (buttons.get(under)) |placed| {
            try writeLabel(canvas, labels.get(placed.label).?, white);
            try canvas.shape(art, placed.shapes.lit, placed.at);
        };
        if (roster.list_open) {
            for (&roster.list.names, 0..) |*name, row| {
                const rect = rowRect(row);
                canvas.box(.{ row_box_at[0], rect.y + row_box_at[1] }, row_box_size);
                canvas.wipe(.{ rect.x, rect.y }, .{ row_wipe_to[0], rect.y + row_wipe_to[1] }, black);
                try canvas.text(small, .{ row_text_at[0], rect.y + row_text_at[1] }, name.slice(), white, .left);
            }
        }
        if (roster.difficulty) |box| try box.draw(canvas, art, pilot.difficulty);
        if (roster.confirm) |confirm| try confirm.draw(canvas, dialog_art);
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
    }
};

/// The list's rows' rectangles.
fn rowRects() [list_rows]Rect {
    var all: [list_rows]Rect = undefined;
    for (&all, 0..) |*rect, row| rect.* = rowRect(row);
    return all;
}

/// The black the list's rows are wiped to.
const black = canvas_module.black;

/// Writes `label` in `colour`.
fn writeLabel(canvas: Canvas, label: Label, colour: [3]f32) canvas_module.Error!void {
    const font = switch (label.font) {
        .large => canvas.fonts.large,
        .small => canvas.fonts.small,
    };
    try canvas.string(font, label.at, @intFromEnum(label.string), colour, label.alignment);
}

comptime {
    for (std.enums.values(String)) |string| {
        if (labels.get(string)) |label| assert(label.string == string);
    }
    // Every button has its label.
    for (buttons.values) |held| if (held) |placed| assert(labels.get(placed.label) != null);
}

test CallSigns {
    var list: CallSigns = .{};
    list.names[0].set("PLAYER");
    // A call sign goes in the first empty place, once.
    try std.testing.expect(list.add("Maverick"));
    try std.testing.expect(!list.add("Maverick"));
    try std.testing.expectEqualStrings("Maverick", list.names[1].slice());
    // Full, the first is let go and the rest move up.
    for (2..list_rows) |place| {
        var buffer: [8]u8 = undefined;
        try std.testing.expect(list.add(try std.fmt.bufPrint(&buffer, "pilot{d}", .{place})));
    }
    try std.testing.expect(list.add("Ace"));
    try std.testing.expectEqualStrings("Maverick", list.names[0].slice());
    try std.testing.expectEqualStrings("Ace", list.names[list_rows - 1].slice());
}

test "Text keeps what fits" {
    var call_sign: CallSign = .{};
    call_sign.set("x" ** 40);
    try std.testing.expectEqual(31, call_sign.slice().len);
}

/// A roster entered with a pilot, and what its frames read.
const Fixture = struct {
    keyboard: input.Keyboard = .{},
    typed: winmain.Typed = .{},
    pilot: Pilot = .{},
    roster: Roster = .{},
    font: hud.Opened,

    fn init() !Fixture {
        var fixture: Fixture = .{ .font = .open(try fnt.Font.parse(comptime fnt.testing.font(true)), null) };
        fixture.roster.enter(&fixture.typed, &fixture.pilot);
        return fixture;
    }

    fn frame(fixture: *Fixture, pointer: Pointer) ?Choice {
        return fixture.roster.frame(.{
            .pointer = pointer,
            .keyboard = &fixture.keyboard,
            .typed = &fixture.typed,
            .elapsed = 1,
            .small = &fixture.font,
            .pilot = &fixture.pilot,
        });
    }
};

test "the call sign is typed, and a click elsewhere puts it in the list" {
    var fixture: Fixture = try .init();
    try std.testing.expect(fixture.roster.typing and fixture.typed.file_names);
    // A character typed each frame: the fixture's font has a glyph for code 1 alone, and a code
    // with no glyph has no width.
    for ([_]u8{ 'A', 'c', 'e' }) |character| fixture.typed.push(character);
    for (0..3) |_| _ = fixture.frame(.{ .at = .{ 450, 190 } });
    try std.testing.expectEqualStrings("Ace", fixture.pilot.call_sign.slice());
    // A click on the female pilot ends the typing, puts the call sign in the list, and makes the
    // pilot female.
    _ = fixture.frame(.{ .at = .{ 280, 300 }, .down = true });
    try std.testing.expect(!fixture.roster.typing and fixture.pilot.female);
    try std.testing.expectEqualStrings("Ace", fixture.roster.list.names[0].slice());
}

test "the list opens once for each press, and a row picks its call sign" {
    var fixture: Fixture = try .init();
    _ = fixture.roster.list.add("Wolf");
    _ = fixture.roster.list.add("Ace");
    const arrow: Pointer = .{ .at = .{ 550, 205 }, .down = true };
    _ = fixture.frame(arrow);
    _ = fixture.frame(arrow);
    try std.testing.expect(fixture.roster.list_open);
    _ = fixture.frame(.{ .at = .{ 550, 205 } });
    // The list covers START GAME: a click there picks the second row, Ace, and the list closes.
    try std.testing.expectEqual(null, fixture.frame(.{ .at = .{ 450, 255 }, .down = true }));
    try std.testing.expectEqual(null, fixture.roster.difficulty);
    try std.testing.expectEqualStrings("Ace", fixture.pilot.call_sign.slice());
    try std.testing.expect(!fixture.roster.list_open);
    // Until the button comes up, nothing else is chosen.
    try std.testing.expectEqual(null, fixture.frame(.{ .at = .{ 450, 255 }, .down = true }));
    try std.testing.expectEqual(null, fixture.roster.difficulty);
    _ = fixture.frame(.{ .at = .{ 550, 205 } });
    // Opened again, the first row picks Wolf.
    _ = fixture.frame(arrow);
    _ = fixture.frame(.{ .at = .{ 450, 230 } });
    _ = fixture.frame(.{ .at = .{ 450, 230 }, .down = true });
    try std.testing.expectEqualStrings("Wolf", fixture.pilot.call_sign.slice());
}

test "START GAME asks the difficulty, which the arrows step round" {
    var fixture: Fixture = try .init();
    try std.testing.expectEqual(null, fixture.frame(.{ .at = .{ 450, 255 }, .down = true }));
    try std.testing.expect(fixture.roster.difficulty != null);
    try std.testing.expectEqual(.medium, fixture.pilot.difficulty);
    // The press that opened it has come up; the harder arrow twice goes round to easy.
    const harder: Pointer = .{ .at = .{ 275, 230 }, .down = true };
    _ = fixture.frame(.{ .at = .{ 275, 230 } });
    _ = fixture.frame(harder);
    _ = fixture.frame(harder);
    try std.testing.expectEqual(.hard, fixture.pilot.difficulty);
    _ = fixture.frame(.{ .at = .{ 275, 230 } });
    _ = fixture.frame(harder);
    try std.testing.expectEqual(.easy, fixture.pilot.difficulty);
    // The press held onto START does nothing; START pressed afresh starts the campaign.
    try std.testing.expectEqual(null, fixture.frame(.{ .at = .{ 280, 275 }, .down = true }));
    _ = fixture.frame(.{ .at = .{ 280, 275 } });
    try std.testing.expectEqual(Choice.start_game, fixture.frame(.{ .at = .{ 280, 275 }, .down = true }).?);
}

test "Escape and MAIN MENU lead back, and QUIT asks first" {
    var fixture: Fixture = try .init();
    try std.testing.expectEqual(Choice.main_menu, fixture.frame(.{ .at = .{ 300, 445 }, .down = true }).?);
    try std.testing.expectEqual(null, fixture.frame(.{ .at = .{ 330, 445 }, .down = true }));
    try std.testing.expect(fixture.roster.confirm != null);
    fixture.keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, fixture.frame(.{}));
    try std.testing.expectEqual(null, fixture.frame(.{}));
    try std.testing.expectEqual(null, fixture.roster.confirm);
    fixture.keyboard.down[input.scan.escape] = false;
    fixture.keyboard.latched[input.scan.escape] = false;
    fixture.keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(Choice.main_menu, fixture.frame(.{}).?);
}
