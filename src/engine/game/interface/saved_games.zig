//! The front end's saved games, its screen 13 (`saved_games`, `0x00431730`), drawn by
//! `saved_games_draw` (`0x00432480`), the render hook it puts in `sr + 0x88`: the pilot's saved
//! games, to load one, or to save the game as one (`saved_games_saving`, `0x0051D5F4`). The pilot
//! roster's LOAD GAME opens it to load; the in-game options' SAVE and LOAD open it over the rooms
//! and the briefing's loadout. It lists the saves `saved_games_scan` (`0x004315C0`) finds, with the
//! selected one's details, and shows the background the screen that opened it set.
//!
//! **Improvement:** the day's and the month's names in the date are English, where the game takes
//! the system's language's (`GetDateFormatA`).
//!
//! Not ported: what the multiplayer games do with it: the co-op host's load, the multiplayer
//! debriefing's save, and a load sent to the other players
//! ([#475](https://github.com/vdmkenny/openreliant/issues/475)).

const std = @import("std");

const input = @import("../../input.zig");
const gameflow = @import("../gameflow.zig");
const save = gameflow.save;
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const winmain = @import("../winmain.zig");
const canvas_module = @import("canvas.zig");
const Canvas = canvas_module.Canvas;
const Pointer = canvas_module.Pointer;
const Rect = canvas_module.Rect;
const dialog = @import("dialog.zig");
const main_menu = @import("main_menu.zig");
const pilot_roster = @import("pilot_roster.zig");

const log = std.log.scoped(.interface);

/// Its shapes (`interface_shapes`), read as it starts (`0x00431980`).
pub const shapes_name = "interface\\frntend2.spr";

/// Whether it saves the game or loads one.
pub const Mode = enum { load, save };

/// What opened it, which the movies it plays as it is left go by (`in_game_options_open`,
/// `0x005202A4`): the pilot roster, or the in-game options.
pub const From = enum { roster, in_game_options };

/// The movie its opener plays before it, and the background that then shows behind it: the pilot
/// roster's (`0x00430A57`) and the in-game options'.
pub fn opening(from: From) struct { movie: []const u8, background: []const u8 } {
    return switch (from) {
        .roster => .{ .movie = "interface\\sinfade.bik", .background = "interface\\sinfade.tga" },
        .in_game_options => .{ .movie = "interface\\igofade.bik", .background = "interface\\igoptfad.tga" },
    };
}

/// How it ends.
pub const End = enum {
    /// BACK, or Escape: the pilot roster or the in-game options again (`interface_screen` 12).
    back,
    /// MAIN MENU: the main menu (`interface_screen` 0).
    main_menu,
    /// QUIT, answered YES (`game_exit`).
    quit,
    /// A saved game loaded, or the game saved.
    done,
};

/// The movie played as it is left by `end` (`0x00432406`, `0x0043235B`), where one plays: back,
/// loading, `sinfade2.bik` to the roster, `igofade2.bik` to the in-game options; saving,
/// `igofade2.bik` to the in-game options. To the main menu, loading only, `sifad2mm.bik` from the
/// roster, `igof2mm.bik` from the in-game options. None after a load or a save.
pub fn leavingMovie(mode: Mode, from: From, end: End) ?[]const u8 {
    return switch (end) {
        .back => switch (from) {
            .in_game_options => "interface\\igofade2.bik",
            .roster => if (mode == .load) "interface\\sinfade2.bik" else null,
        },
        .main_menu => if (mode == .save) null else switch (from) {
            .in_game_options => "interface\\igof2mm.bik",
            .roster => "interface\\sifad2mm.bik",
        },
        .quit, .done => null,
    };
}

/// The rows the list shows at once, 17 apart down from the first (`0x0043175B` on), and where each
/// row's name, pilot and mission stand, and its bar where it is selected.
const rows = 10;
const first_row: Rect = .{ .x = 49, .y = 126, .width = 400, .height = 17 };
const row_spacing = 17;
const pilot_x = 320;
const mission_x = 570;
const bar_from: [2]i32 = .{ 49, 2 };
const bar_to: [2]i32 = .{ 572, 19 };
const bar_colour = hud.rgb(0x0000FF);

fn rowRect(row: usize) Rect {
    var rect = first_row;
    rect.y += @intCast(row * row_spacing);
    return rect;
}

/// The buttons along its foot: BACK, LOAD GAME or NEW SAVE GAME, MAIN MENU and QUIT, each drawn
/// at its corner, and their labels.
pub const Button = enum { back, act, main_menu, quit };

pub const button_rects = std.EnumArray(Button, Rect).init(.{
    .back = .{ .x = 292, .y = 421, .width = 25, .height = 16 },
    .act = .{ .x = 324, .y = 421, .width = 25, .height = 16 },
    .main_menu = .{ .x = 292, .y = 441, .width = 25, .height = 16 },
    .quit = .{ .x = 324, .y = 441, .width = 25, .height = 16 },
});
const button_shapes: canvas_module.Button.Pair = .{ .off = 26, .lit = 27 };

const Label = canvas_module.Label;

/// A button as it is drawn: its shape at its rectangle's corner, and its label.
fn shownButton(button: Button, mode: Mode) canvas_module.Button {
    const rect = button_rects.get(button);
    return .{ .at = .{ rect.x, rect.y }, .label = switch (button) {
        .back => .of(0xF7, .{ 288, 420 }, .right),
        .act => .of(if (mode == .load) 0xBA else 0x177, .{ 353, 420 }, .left),
        .main_menu => .of(0xBB, .{ 288, 440 }, .right),
        .quit => .of(0xBC, .{ 353, 440 }, .left),
    } };
}

/// The list's arrows: one shape for both, lit up or down under the pointer.
pub const Arrow = canvas_module.Arrow;

pub const arrow_rects = std.EnumArray(Arrow, Rect).init(.{
    .up = .{ .x = 579, .y = 250, .width = 26, .height = 16 },
    .down = .{ .x = 579, .y = 268, .width = 26, .height = 16 },
});
const arrows_shape = 28;
const arrows_at: [2]i32 = .{ 579, 250 };
const lit_up_shape = 29;
const lit_down_shape = 25;

/// The name's line while it is typed, saving: its frame, the name, the cursor after it, which turns
/// on and off every `blink_ticks` game ticks, and OK, which saves under it, lit under the pointer,
/// with its label.
const name_box_at: [2]i32 = .{ 45, 380 };
const name_box_size: [2]i32 = .{ 358, 20 };
const name_at: [2]i32 = .{ 49, 378 };
const cursor = "_";
const blink_ticks = 25;
pub const ok: Rect = .{ .x = 562, .y = 384, .width = 32, .height = 20 };
const ok_shape = 22;
const lit_ok_shape = 23;
const ok_at: [2]i32 = .{ 566, 382 };
const ok_label: Label = .of(0x54D, .{ 562, 384 }, .right);

/// The title: LOAD GAME FOR or SAVE GAME FOR, then the call sign in capitals (`0x004E8750`).
const title_at: [2]i32 = .{ 320, 86 };
const load_title = 0x55F;
const save_title = 0x560;

/// The frames of the list and of the details.
const list_box_at: [2]i32 = .{ 45, 126 };
const list_box_size: [2]i32 = .{ 530, 175 };
const details_box_at: [2]i32 = .{ 45, 321 };
const details_box_size: [2]i32 = .{ 550, 38 };

/// The labels always written, in the small font: the columns' heads, GAME INFORMATION and the
/// details'.
const labels = [_]Label{
    .of(0xE3, .{ 45, 107 }, .left),
    .of(0xE4, .{ 320, 107 }, .centre),
    .of(0xE5, .{ 575, 107 }, .right),
    .of(0xE6, .{ 49, 302 }, .left),
    .of(0xE7, .{ 49, 322 }, .left),
    .of(0xE8, .{ 49, 339 }, .left),
    .of(0xE9, .{ 290, 322 }, .left),
    .of(0xEB, .{ 290, 339 }, .left),
};

/// Where the selected save's details stand: its pilot, rank and level, and the date its file was
/// last written.
const pilot_at: [2]i32 = .{ 113, 322 };
const rank_at: [2]i32 = .{ 113, 339 };
const tier_at: [2]i32 = .{ 350, 322 };
const time_at: [2]i32 = .{ 350, 339 };

/// The name NEW SAVE GAME saves the game under, for the player to rename: Empty Save Game.
const new_save_name = 0x179;

/// QUIT's question: Do you really want to Quit?
const quit_question = main_menu.quit_question;

const blue = canvas_module.blue;
const white = canvas_module.white;

/// A saved game as the list shows it (`saved_games_names`, `saved_games_pilots` and
/// `saved_games_missions`): its name, its pilot's call sign, and the mission it is at.
pub const Listed = struct {
    name: save.Name = .{},
    pilot: pilot_roster.CallSign = .{},
    mission: u16 = 0,
};

/// A moment on the local calendar and clock.
pub const Date = struct {
    year: i32,
    /// 1 to 12.
    month: u8,
    /// 1 to 31.
    day: u8,
    hour: u8,
    minute: u8,
    /// 0 to 6, from Sunday.
    day_of_week: u8,
};

/// The date shown (`saved_games_time`, `0x0051DAD0`): the hour and minute, two spaces, then the day
/// as `ddd',' MMM dd yyyy` has it (`0x004E872C`, `0x004E873C`).
pub const Time = struct {
    bytes: [32]u8 = undefined,
    len: usize = 0,

    pub fn of(date: Date) Time {
        const days = [7][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
        const months = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        var time: Time = .{};
        const written = std.fmt.bufPrint(&time.bytes, "{d:0>2}:{d:0>2}  {s}, {s} {d:0>2} {d}", .{
            date.hour,
            date.minute,
            days[@min(date.day_of_week, days.len - 1)],
            months[std.math.clamp(date.month, 1, months.len) - 1],
            date.day,
            date.year,
        }) catch &time.bytes;
        time.len = written.len;
        return time;
    }

    pub fn slice(time: *const Time) []const u8 {
        return time.bytes[0..time.len];
    }
};

/// The name typed (`saved_games_name`, `0x0051DA5C`, 20 bytes): 18 characters at most, as
/// `text_entry_step` keeps a line with no font (`0x004813BA`).
pub const TypedName = pilot_roster.Text(typed_room);
const typed_room = 18;

/// NEW SAVE GAME, once pressed: the save it made, whose file leaving without saving removes, or
/// none where the save failed.
const NewSave = union(enum) { failed, made: u8 };

/// The saved games the screen lists, the game it saves and loads, the game's strings, which
/// Empty Save Game is, and the local date and time of a moment, in nanoseconds from 1970 in UTC,
/// which the date shown is made of, where one can be told.
pub const Saves = struct {
    gpa: std.mem.Allocator,
    folder: save.Folder,
    game: save.Game,
    strings: *const language.Language,
    local_time: ?*const fn (i96) ?Date = null,

    /// The pilot's call sign, which names the saved games.
    fn callSign(saves: Saves) []const u8 {
        return saves.game.pilot.call_sign.slice();
    }
};

/// What a pass of the screen reads, and what it saves and loads with.
pub const Context = struct {
    pointer: Pointer,
    keyboard: *input.Keyboard,
    typed: *winmain.Typed,
    /// The game's ticks, which the cursor blinks by (`game_ticks`).
    ticks: u32,
    saves: Saves,
};

/// The screen's state, which the game keeps in globals and on `saved_games`' stack.
pub const SavedGames = struct {
    mode: Mode = .load,
    from: From = .roster,
    /// The saves `saved_games_scan` found.
    list: [save.slots]Listed = @splat(.{}),
    /// How many there are (`saved_games_count`, `0x00520248`), and the save the list's first row
    /// shows (`saved_games_first`, `0x0051DA1C`).
    scrolled: canvas_module.Scrolled(u8) = .{ .shown = rows },
    /// The save selected (`saved_games_selected`, `0x0051D9F8`).
    selected: ?u8 = null,
    /// The selected save's rank and level (`saved_games_rank`, `0x0051DA10`; `saved_games_tier`,
    /// `0x00520258`), and the date its file was last written (`saved_games_time_text`), where it
    /// has been read.
    rank: gameflow.Rank = 0,
    tier: u2 = 0,
    time: ?Time = null,
    /// The name typed while saving: whether it is typed (`roster_typing`, `0x0052019C`), whether
    /// its cursor shows (`roster_cursor_shown`, `0x0052016C`) and the tick the cursor next turns at
    /// (`roster_cursor_blink`, `0x00520164`).
    name: TypedName = .{},
    typing: bool = false,
    cursor_shown: bool = true,
    blink_at: u32 = 0,
    /// What is under the pointer: a row or a button (`roster_item`), an arrow
    /// (`saved_games_arrow`, `0x0051DB38`), and OK while the name is typed (`saved_games_ok_under`,
    /// `0x005202C4`).
    under: ?Under = null,
    arrow: ?Arrow = null,
    ok_under: bool = false,
    /// Whether the pointer's button, down, has been seen, so that a press acts once; and the
    /// pointer as the last pass left it, which OK goes by (`0x00431BFC`).
    held: bool = false,
    last: Pointer = .{},
    /// NEW SAVE GAME, once pressed on this visit.
    new_save: ?NewSave = null,
    /// A load, once LOAD GAME has made it, waiting for the pointer's button to come up
    /// (`0x0043232E`).
    loaded: bool = false,
    /// QUIT's question, and the box saying a save failed, while either is up.
    confirm: ?dialog.Confirm = null,
    save_error: ?dialog.SaveError = null,

    /// Under the pointer: a row of the list, by its place from the first shown, or a button.
    pub const Under = union(enum) { row: u8, button: Button };

    /// Entering the screen, as `saved_games` does before its loop (`0x0043195C` to `0x00431B45`):
    /// loading, the autosave selected where there is one, with its details and date; the list from
    /// its first row, the name empty and not typed, and the saves found.
    pub fn enter(screen: *SavedGames, mode: Mode, from: From, context: Context) void {
        screen.* = .{ .mode = mode, .from = from };
        if (mode == .load) {
            screen.selected = save.autosave_slot;
            if (!screen.readDetails(context.saves, save.autosave_slot)) screen.selected = null else screen.readTime(context.saves, save.autosave_slot);
        }
        context.typed.clear();
        screen.scan(context.saves);
    }

    /// `saved_games_scan` (`0x004315C0`): the call sign's saves from slot 0 on, up to the first
    /// file missing, each one's name, pilot and mission.
    ///
    /// **Fix:** a file with no `SAVE` form is listed with no name, pilot or mission, where the
    /// game shows whatever its buffers held.
    fn scan(screen: *SavedGames, saves: Saves) void {
        screen.scrolled.count = 0;
        for (&screen.list, 0..) |*listed, slot| {
            const bytes = saves.folder.file(saves.gpa, saves.callSign(), @intCast(slot)) orelse break;
            defer saves.gpa.free(bytes);
            var found = save.empty();
            _ = save.read(bytes, &found);
            listed.* = .{ .name = found.name, .mission = found.miss.missionNumber() };
            listed.pilot.set(std.mem.sliceTo(&found.miss.call_sign, 0));
            screen.scrolled.count += 1;
        }
    }

    /// The rank and level of save `slot`, read from its `MISS` (`0x0043199C`, `0x00431D9A` on),
    /// the nearest the game names (`save.Miss.pilotRank`); false where its file can't be read.
    fn readDetails(screen: *SavedGames, saves: Saves, slot: u8) bool {
        var found = save.empty();
        if (!saves.folder.load(saves.gpa, saves.callSign(), slot, &found)) return false;
        screen.rank = found.miss.pilotRank();
        screen.tier = found.miss.campaignTier();
        return true;
    }

    /// The date save `slot`'s file was last written, in local time (`0x00431A68` to `0x00431B0E`,
    /// `0x00431E5F` to `0x00431F1A`).
    fn readTime(screen: *SavedGames, saves: Saves, slot: u8) void {
        const local_time = saves.local_time orelse return;
        const written = saves.folder.modified(saves.callSign(), slot) orelse return;
        screen.time = if (local_time(written)) |date| .of(date) else null;
    }

    /// Starts typing the name, from `name`, the cursor shown.
    ///
    /// **Fix:** the game copies a saved game's name in whatever its length (`strcpy`,
    /// `0x00431D46`); OpenReliant keeps what fits.
    fn startTyping(screen: *SavedGames, context: Context, name: []const u8) void {
        screen.name.set(name);
        screen.blink_at = context.ticks + blink_ticks;
        screen.cursor_shown = true;
        screen.typing = true;
        context.typed.clear();
    }

    /// A pass of `saved_games`' loop (`0x00431B4A` on). The box saying a save failed and QUIT's
    /// question take the pass while up. Escape leaves; Down and Up scroll the list while held.
    /// While the name is typed, saving, the cursor blinks, and Enter or a click on OK saves the game
    /// under it in the slot selected. A press acts once, on the pass it is first seen, but for the
    /// arrows', which scroll a row each pass. A click on a row selects it, loading, with its details
    /// and date; saving, with its details, but for the autosave's, which can't be saved over. A
    /// second click on the row selected loads it, or starts typing its name. LOAD GAME loads the
    /// row selected; NEW SAVE GAME saves the game in the next slot for the player to name. The name
    /// takes a character typed each pass (`hud.typeInto`), as `saved_games_draw` has it.
    pub fn frame(screen: *SavedGames, context: Context) ?End {
        const pointer = context.pointer;
        const keyboard = context.keyboard;
        const escaped = keyboard.pressed(input.scan.escape, .none, true);
        if (screen.loaded) return if (pointer.down) null else .done;
        if (screen.save_error) |*box| {
            if (box.frame(pointer, escaped)) screen.save_error = null;
            return null;
        }
        if (screen.confirm) |*confirm| {
            const answer = confirm.frame(pointer, escaped) orelse return null;
            screen.confirm = null;
            return if (answer) screen.leave(context.saves, .quit) else null;
        }
        if (escaped) return screen.leave(context.saves, .back);
        if (keyboard.pressed(@intFromEnum(input.Key.down), .none, false)) screen.scrolled.scroll(.down);
        if (keyboard.pressed(@intFromEnum(input.Key.up), .none, false)) screen.scrolled.scroll(.up);
        // **Improvement:** the mouse's wheel scrolls the list too.
        screen.scrolled.wheel(context.pointer.wheel);
        defer if (screen.typing and screen.mode == .save) hud.typeInto(context.typed, &screen.name.bytes, &screen.name.len, null);
        if (screen.mode == .save and screen.typing) {
            if (context.ticks > screen.blink_at) {
                screen.blink_at = context.ticks + blink_ticks;
                screen.cursor_shown = !screen.cursor_shown;
            }
            screen.ok_under = ok.holds(screen.last.at);
            if (keyboard.pressed(@intFromEnum(input.Key.enter), .none, true) or (screen.ok_under and screen.last.down)) {
                return screen.saveAs(context.saves);
            }
        }

        var down = pointer.down;
        if (!pointer.down) {
            screen.held = false;
        } else if (screen.held) {
            down = false;
        } else screen.held = true;
        screen.last = .{ .at = pointer.at, .down = down };

        screen.arrow = canvas_module.itemAt(Arrow, &arrow_rects, pointer.at);
        if (screen.arrow) |arrow| if (down) {
            screen.held = false;
            // `saved_games_scroll_down` (`0x00431580`) and `saved_games_scroll_up` (`0x004315A0`).
            screen.scrolled.scroll(arrow);
        };
        screen.under = if (canvas_module.hit(&rowRects(), pointer.at)) |row|
            .{ .row = @intCast(row) }
        else if (canvas_module.itemAt(Button, &button_rects, pointer.at)) |button|
            .{ .button = button }
        else
            null;
        const under = screen.under orelse return null;
        if (!down) return null;
        switch (under) {
            .row => |row| {
                if (row >= @min(screen.scrolled.count, rows)) return null;
                return screen.choose(context, screen.scrolled.first + row);
            },
            .button => |button| switch (button) {
                .back => return screen.leave(context.saves, .back),
                .act => switch (screen.mode) {
                    .load => if (screen.selected) |slot| {
                        if (!load(context.saves, slot)) return null;
                        screen.loaded = true;
                        return if (pointer.down) null else .done;
                    },
                    .save => screen.newSave(context),
                },
                .main_menu => return screen.leave(context.saves, .main_menu),
                .quit => screen.confirm = .{ .message = .{ .string = quit_question } },
            },
        }
        return null;
    }

    /// A click on the row of save `slot` (`0x00431D32` on).
    fn choose(screen: *SavedGames, context: Context, slot: u8) ?End {
        if (screen.selected == slot) switch (screen.mode) {
            .load => return if (load(context.saves, slot)) .done else null,
            .save => if (slot != save.autosave_slot) screen.startTyping(context, screen.list[slot].name.slice()),
        };
        switch (screen.mode) {
            .load => {
                screen.selected = slot;
                _ = screen.readDetails(context.saves, slot);
                screen.readTime(context.saves, slot);
            },
            .save => if (slot != save.autosave_slot) {
                screen.selected = slot;
                _ = screen.readDetails(context.saves, slot);
            },
        }
        return null;
    }

    /// `game_load` of save `slot` into the game; false where its file can't be read.
    fn load(saves: Saves, slot: u8) bool {
        var loaded = save.empty();
        if (!saves.folder.load(saves.gpa, saves.callSign(), slot, &loaded)) {
            log.warn("saved game {d} can't be loaded", .{slot});
            return false;
        }
        saves.game.apply(&loaded);
        return true;
    }

    /// `game_save` of the game under the name typed, in the slot selected (`0x00431C34`): saved,
    /// the saves found again and the screen done; not saved, the box saying so.
    fn saveAs(screen: *SavedGames, saves: Saves) ?End {
        const slot = screen.selected orelse return null;
        const saved = saves.game.capture(screen.name.slice());
        saves.folder.store(saves.gpa, saves.callSign(), slot, &saved) catch |err| {
            log.warn("the game can't be saved: {s}", .{@errorName(err)});
            screen.save_error = .{};
            return null;
        };
        screen.scan(saves);
        return .done;
    }

    /// NEW SAVE GAME (`0x00432011`), once a visit: the game saved in the slot after the last found,
    /// named Empty Save Game, then selected with the game's rank and level and the file's date, the
    /// list scrolled to show it, and loaded back, which clears the game's variables as a load does;
    /// then the name typed from Empty Save Game. Not saved, the box saying so, and NEW SAVE GAME
    /// does nothing more on this visit.
    ///
    /// **Fix:** with every slot taken, NEW SAVE GAME does nothing, where the game saves over the
    /// restart point's file.
    fn newSave(screen: *SavedGames, context: Context) void {
        if (screen.new_save != null or screen.scrolled.count >= save.slots) return;
        const saves = context.saves;
        const slot = screen.scrolled.count;
        const name = saves.strings.string(new_save_name) orelse "";
        const saved = saves.game.capture(name);
        saves.folder.store(saves.gpa, saves.callSign(), slot, &saved) catch |err| {
            log.warn("the game can't be saved: {s}", .{@errorName(err)});
            screen.new_save = .failed;
            screen.save_error = .{};
            return;
        };
        screen.new_save = .{ .made = slot };
        screen.selected = slot;
        screen.scan(saves);
        _ = load(saves, slot);
        screen.tier = saves.game.tier.*;
        screen.rank = saves.game.player.rank;
        screen.readTime(saves, slot);
        if (screen.scrolled.count > rows) screen.scrolled.first = screen.scrolled.count - rows;
        screen.startTyping(context, name);
    }

    /// Leaving the screen by `end`, without a save made: NEW SAVE GAME's save removed
    /// (`0x004322EC`, `0x0043238C`, `0x004323B3`, `0x004323F3`).
    ///
    /// **Fix:** where NEW SAVE GAME failed, nothing is removed; the game removes whatever file its
    /// buffer names.
    fn leave(screen: *SavedGames, saves: Saves, end: End) End {
        if (screen.new_save) |made| switch (made) {
            .made => |slot| saves.folder.remove(saves.callSign(), slot),
            .failed => {},
        };
        return end;
    }

    /// Whether the name takes what is typed.
    pub fn takesText(screen: *const SavedGames) bool {
        return screen.mode == .save and screen.typing;
    }

    /// `saved_games_draw` (`0x00432480`), over the background its opener left: the frames and the
    /// title; saving, the name's frame and, while it is typed, the name with its cursor and OK;
    /// the labels and the date; the buttons, the one under the pointer lit with its label in white;
    /// the rows shown, the selected one white over a bar; the selected save's details; the arrows;
    /// QUIT's question or the box saying a save failed; OpenReliant's version; then the pointer.
    pub fn draw(screen: SavedGames, canvas: Canvas, art: *hud.Art, dialog_art: *hud.Art, pointer: Pointer, call_sign: []const u8) canvas_module.Error!void {
        const large = canvas.fonts.large;
        const small = canvas.fonts.small;
        canvas.box(list_box_at, list_box_size);
        canvas.box(details_box_at, details_box_size);
        var title_buffer: [96]u8 = undefined;
        const heading = canvas.strings.string(if (screen.mode == .load) load_title else save_title) orelse "";
        var capitals: [32]u8 = undefined;
        const upper = std.ascii.upperString(capitals[0..@min(call_sign.len, capitals.len)], call_sign[0..@min(call_sign.len, capitals.len)]);
        const title = std.fmt.bufPrint(&title_buffer, "{s} {s}", .{ heading, upper }) catch heading;
        try canvas.text(large, title_at, title, blue, .centre);
        if (screen.mode == .save) {
            canvas.box(name_box_at, name_box_size);
            if (screen.typing) {
                try canvas.text(large, name_at, screen.name.slice(), white, .left);
                if (screen.cursor_shown) {
                    const width: i32 = @intCast(large.textWidth(screen.name.slice()));
                    try canvas.text(large, .{ name_at[0] + width, name_at[1] }, cursor, white, .left);
                }
                try canvas.shape(art, if (screen.ok_under) lit_ok_shape else ok_shape, ok_at);
                try ok_label.write(canvas, small, blue);
            }
        }
        for (labels) |each| try each.write(canvas, small, blue);
        if (screen.time) |time| try canvas.text(small, time_at, time.slice(), blue, .left);
        for (std.enums.values(Button)) |button| {
            const lit = if (screen.under) |under| switch (under) {
                .button => |pointed| pointed == button,
                .row => false,
            } else false;
            try shownButton(button, screen.mode).draw(canvas, art, button_shapes, lit);
        }
        for (screen.scrolled.first..screen.scrolled.end()) |slot| {
            const y = rowRect(slot - screen.scrolled.first).y;
            const selected = if (screen.selected) |chosen| chosen == slot else false;
            const colour = if (selected) white else blue;
            if (selected) canvas.wipe(.{ bar_from[0], y + bar_from[1] }, .{ bar_to[0], y + bar_to[1] }, bar_colour);
            const listed = &screen.list[slot];
            try canvas.text(small, .{ first_row.x, y }, listed.name.slice(), colour, .left);
            try canvas.text(small, .{ pilot_x, y }, listed.pilot.slice(), colour, .centre);
            var number: [8]u8 = undefined;
            try canvas.text(small, .{ mission_x, y }, std.fmt.bufPrint(&number, "{d}", .{gameflow.displayNumber(listed.mission)}) catch "", colour, .right);
        }
        if (screen.selected) |slot| {
            try canvas.string(small, rank_at, gameflow.rank_names[screen.rank], blue, .left);
            if (slot < screen.scrolled.count) try canvas.text(small, pilot_at, screen.list[slot].pilot.slice(), blue, .left);
            try canvas.string(small, tier_at, gameflow.tier_names[screen.tier], blue, .left);
        }
        try canvas.shape(art, arrows_shape, arrows_at);
        if (screen.arrow) |arrow| switch (arrow) {
            .up => try canvas.shape(art, lit_up_shape, arrows_at),
            .down => try canvas.shape(art, lit_down_shape, .{ arrow_rects.get(.down).x, arrow_rects.get(.down).y }),
        };
        if (screen.confirm) |confirm| try confirm.draw(canvas, dialog_art);
        if (screen.save_error) |box| try box.draw(canvas, dialog_art);
        try canvas.drawVersion();
        try canvas.shape(art, pointer.shape(), pointer.at);
    }
};

/// The rows' rectangles.
fn rowRects() [rows]Rect {
    var all: [rows]Rect = undefined;
    for (&all, 0..) |*rect, row| rect.* = rowRect(row);
    return all;
}

test leavingMovie {
    try std.testing.expectEqualStrings("interface\\sinfade2.bik", leavingMovie(.load, .roster, .back).?);
    try std.testing.expectEqualStrings("interface\\igofade2.bik", leavingMovie(.save, .in_game_options, .back).?);
    try std.testing.expectEqual(null, leavingMovie(.save, .in_game_options, .main_menu));
    try std.testing.expectEqualStrings("interface\\igof2mm.bik", leavingMovie(.load, .in_game_options, .main_menu).?);
    try std.testing.expectEqual(null, leavingMovie(.load, .roster, .done));
}

test Time {
    const time: Time = .of(.{ .year = 2026, .month = 9, .day = 3, .hour = 7, .minute = 5, .day_of_week = 4 });
    try std.testing.expectEqualStrings("07:05  Thu, Sep 03 2026", time.slice());
}

/// A game under way, its saves folder, and what the screen's passes read, for the tests.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    keyboard: input.Keyboard = .{},
    typed: winmain.Typed = .{},
    campaign: gameflow.Campaign = .begin(),
    player: input.Player = .{},
    tier: u2 = 0,
    pilot: pilot_roster.Pilot = .{},
    saved: @import("../../interface/loadout/loadout.zig").Saved = .{},
    strings: language.Language = .{ .strings = &.{} },
    screen: SavedGames = .{},
    ticks: u32 = 0,

    fn init(fixture: *Fixture) void {
        fixture.* = .{ .tmp = std.testing.tmpDir(.{ .iterate = true }) };
        fixture.pilot.call_sign.set("Ace");
    }

    fn deinit(fixture: *Fixture) void {
        fixture.tmp.cleanup();
    }

    fn context(fixture: *Fixture, pointer: Pointer) Context {
        return .{
            .pointer = pointer,
            .keyboard = &fixture.keyboard,
            .typed = &fixture.typed,
            .ticks = fixture.ticks,
            .saves = .{
                .gpa = std.testing.allocator,
                .folder = fixture.folder(),
                .game = .{ .campaign = &fixture.campaign, .player = &fixture.player, .tier = &fixture.tier, .pilot = &fixture.pilot, .saved = &fixture.saved },
                .strings = &fixture.strings,
            },
        };
    }

    fn folder(fixture: *Fixture) save.Folder {
        return .{ .io = std.testing.io, .dir = fixture.tmp.dir };
    }

    fn frame(fixture: *Fixture, pointer: Pointer) ?End {
        fixture.ticks += 1;
        return fixture.screen.frame(fixture.context(pointer));
    }

    /// A click at `at`: the button down on one pass and up on the next; what either pass ended in.
    fn click(fixture: *Fixture, at: [2]i32) ?End {
        if (fixture.frame(.{ .at = at, .down = true })) |end| return end;
        return fixture.frame(.{ .at = at });
    }

    /// Saves the game as `slot`, named `name`, at mission `mission`.
    fn store(fixture: *Fixture, slot: u8, name: []const u8, mission: u16) !void {
        fixture.campaign.mission = mission;
        const game = fixture.context(.{}).saves.game;
        const saved = game.capture(name);
        try fixture.folder().store(std.testing.allocator, "Ace", slot, &saved);
    }
};

/// Where the list's row `row` is clicked, and each button.
fn rowAt(row: usize) [2]i32 {
    return .{ 100, rowRect(row).y + 5 };
}
fn buttonAt(button: Button) [2]i32 {
    const rect = button_rects.get(button);
    return .{ rect.x + 5, rect.y + 5 };
}

test "loading lists the saves up to the first missing, and a second click loads" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    try fixture.store(0, "AUTOSAVE: Mission 3", 3);
    try fixture.store(1, "Before the Ghost", 5);
    try fixture.store(3, "Never listed", 9);
    fixture.campaign.mission = 1;
    fixture.screen.enter(.load, .roster, fixture.context(.{}));
    // The autosave is selected, and the list stops at the missing slot 2.
    try std.testing.expectEqual(2, fixture.screen.scrolled.count);
    try std.testing.expectEqual(0, fixture.screen.selected);
    try std.testing.expectEqualStrings("Before the Ghost", fixture.screen.list[1].name.slice());
    try std.testing.expectEqualStrings("Ace", fixture.screen.list[1].pilot.slice());
    // A click on a row past the list does nothing; on the second row, selects it.
    try std.testing.expectEqual(null, fixture.click(rowAt(4)));
    try std.testing.expectEqual(0, fixture.screen.selected);
    try std.testing.expectEqual(null, fixture.click(rowAt(1)));
    try std.testing.expectEqual(1, fixture.screen.selected);
    try std.testing.expectEqual(1, fixture.campaign.mission);
    // A second click loads it.
    try std.testing.expectEqual(End.done, fixture.click(rowAt(1)).?);
    try std.testing.expectEqual(5, fixture.campaign.mission);
}

test "LOAD GAME waits for the button to come up" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    try fixture.store(0, "AUTOSAVE: Mission 6", 6);
    fixture.campaign.mission = 1;
    fixture.screen.enter(.load, .roster, fixture.context(.{}));
    try std.testing.expectEqual(null, fixture.frame(.{ .at = buttonAt(.act), .down = true }));
    try std.testing.expectEqual(6, fixture.campaign.mission);
    try std.testing.expectEqual(null, fixture.frame(.{ .at = buttonAt(.act), .down = true }));
    try std.testing.expectEqual(End.done, fixture.frame(.{ .at = buttonAt(.act) }).?);
}

test "NEW SAVE GAME saves in the next slot, and leaving without a name removes it" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    try fixture.store(0, "AUTOSAVE: Mission 2", 2);
    fixture.campaign.mission = 4;
    fixture.screen.enter(.save, .in_game_options, fixture.context(.{}));
    try std.testing.expectEqual(null, fixture.screen.selected);
    // The autosave can't be chosen to save over.
    try std.testing.expectEqual(null, fixture.click(rowAt(0)));
    try std.testing.expectEqual(null, fixture.screen.selected);
    try std.testing.expectEqual(null, fixture.click(buttonAt(.act)));
    try std.testing.expectEqual(2, fixture.screen.scrolled.count);
    try std.testing.expectEqual(1, fixture.screen.selected);
    try std.testing.expect(fixture.screen.takesText());
    // Once a visit.
    try std.testing.expectEqual(null, fixture.click(buttonAt(.act)));
    try std.testing.expectEqual(2, fixture.screen.scrolled.count);
    // BACK removes it.
    try std.testing.expectEqual(End.back, fixture.click(buttonAt(.back)).?);
    try std.testing.expectEqual(null, fixture.folder().file(std.testing.allocator, "Ace", 1));
}

test "a name typed saves the game in the slot chosen" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    try fixture.store(0, "AUTOSAVE: Mission 2", 2);
    try fixture.store(1, "Old", 2);
    fixture.campaign.mission = 7;
    fixture.screen.enter(.save, .in_game_options, fixture.context(.{}));
    // The second slot selected, then clicked again, starts typing its name.
    _ = fixture.click(rowAt(1));
    _ = fixture.click(rowAt(1));
    try std.testing.expect(fixture.screen.typing);
    try std.testing.expectEqualStrings("Old", fixture.screen.name.slice());
    // A backspace and three letters, a pass each, then Enter.
    for ([_]u8{ hud.backspace, 'd', 'e', 'r' }) |character| {
        fixture.typed.push(character);
        _ = fixture.frame(.{});
    }
    try std.testing.expectEqualStrings("Older", fixture.screen.name.slice());
    fixture.keyboard.down[@intFromEnum(input.Key.enter)] = true;
    try std.testing.expectEqual(End.done, fixture.frame(.{}).?);
    var found = save.empty();
    try std.testing.expect(fixture.folder().load(std.testing.allocator, "Ace", 1, &found));
    try std.testing.expectEqualStrings("Older", found.name.slice());
    try std.testing.expectEqual(7, found.miss.mission);
}

test "the arrows scroll a row each pass they are held" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    for (0..13) |slot| try fixture.store(@intCast(slot), "x", 2);
    fixture.screen.enter(.load, .roster, fixture.context(.{}));
    try std.testing.expectEqual(13, fixture.screen.scrolled.count);
    const down: Pointer = .{ .at = .{ 585, 272 }, .down = true };
    for (0..5) |_| _ = fixture.frame(down);
    // Three rows are past the ten shown.
    try std.testing.expectEqual(3, fixture.screen.scrolled.first);
    _ = fixture.frame(.{ .at = .{ 585, 255 }, .down = true });
    try std.testing.expectEqual(2, fixture.screen.scrolled.first);
}

test "Escape leaves, and QUIT asks first" {
    var fixture: Fixture = undefined;
    fixture.init();
    defer fixture.deinit();
    fixture.screen.enter(.load, .roster, fixture.context(.{}));
    try std.testing.expectEqual(null, fixture.screen.selected);
    try std.testing.expectEqual(null, fixture.click(buttonAt(.quit)));
    try std.testing.expect(fixture.screen.confirm != null);
    fixture.keyboard.down[input.scan.escape] = true;
    try std.testing.expectEqual(null, fixture.frame(.{}));
    try std.testing.expectEqual(null, fixture.screen.confirm);
    fixture.keyboard.latched[input.scan.escape] = false;
    try std.testing.expectEqual(End.back, fixture.frame(.{}).?);
}
