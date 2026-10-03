//! The radio's menu (`comms_menu_run`, `0x00455D40`), which the display's window 11 shows while
//! COMMS WINDOW holds it open, and whose number keys choose its items: pages of items, each leading
//! to another page, and pages that do what their item says and close the window. The pages and
//! what they do lie among the radio's code, from `0x00453A70` to `0x00455D40`. **Unverified:**
//! that the code is `videoreports.cpp`'s, as the radio's is.
//!
//! Not ported: a multiplayer game's pages (`Page.multiplayer` to `Page.deny`), which list the other
//! players, send them messages and the wingmen's commands, and answer another player's request,
//! and the chat line they type in (`chat_typing`, `0x00529FB8`)
//! ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const input = @import("../../input.zig");
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const dmscenarios = @import("../dmscenarios.zig");
const gameobj = @import("../gameobj.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const pilots = @import("../pilots.zig");
const videoreports = @import("../videoreports.zig");
const wingmen = videoreports.wingmen;
const numbered = videoreports.numbered;

/// A page of the menu (`0x00529530`), numbered as the game numbers them (`0x00455FD8`). Each page
/// also names itself for a title (`0x00529FB4`), which nothing draws.
pub const Page = enum(i16) {
    /// COMMS: the player's target, the wing's pilots and the base (`0x00453B90`).
    top = -1,
    /// A ship the page before names (`0x00454370`): the taunts for a hostile ship; the wingmen's
    /// commands, the status, the scolding and the praise for a wingman.
    ship = 0,
    /// Alpha Pilots: the wing's pilots, and the whole wing (`0x00453C80`).
    pilots = 1,
    /// Base: PERMISSION TO LAND and REQUEST BACKUP (`0x00453D50`).
    base = 2,
    /// Open channels (`0x00453DA0`), which no item leads to.
    channels = 3,
    /// A ship, as page 0, which no item leads to.
    ship_again = 4,
    /// Alpha Wing: the wingmen's commands to the whole wing (`0x00454570`).
    wing = 5,
    /// The taunts, which a hostile ship answers (`taunt`).
    taunt_1 = 6,
    taunt_2 = 7,
    taunt_3 = 8,
    taunt_4 = 9,
    taunt_5 = 10,
    /// The wingmen's commands (`wingmen.give`).
    attack_my_target = 11,
    back_off = 12,
    help_me = 13,
    /// What's your status? (`status`)
    status = 14,
    /// Come on... get your act together, and Nice work. I owe you one (`remark`).
    scold = 15,
    praise = 16,
    /// Nothing, which no item leads to.
    nothing = 17,
    /// PERMISSION TO LAND (`videoreports.permissionToLand`).
    permission_to_land = 18,
    /// REQUEST BACKUP (`videoreports.requestBackup`).
    request_backup = 19,
    /// Open all channels, and close all channels: kills credited and remarked on, or not
    /// (`videoreports.Remarks.kill_credit`).
    open_channels = 20,
    close_channels = 21,
    /// A multiplayer game's: the players, a player, a message to a player and to them all,
    /// another player's request, and accepting and denying it.
    multiplayer = 22,
    player = 23,
    message = 24,
    message_all = 25,
    request = 26,
    accept = 27,
    deny = 28,
};

/// What an item says.
pub const Label = union(enum) {
    /// A string of the game's (`language_string`).
    string: u16,
    /// A wingman, as "Bandit (Alpha 2)" (`0x004F0D64`): the string that names its pilot, where it
    /// has one, and its call sign.
    pilot: struct { name: ?u16, call_sign: u16 },

    /// The room the game gives a wingman's words (`0x00529884`, `0x64` bytes each).
    pub const room = 0x64;

    /// What the item says, in the game's strings `said`, a wingman's written into `buffer`.
    /// **Fix:** the game reads the name of a wingman with no pilot through a null pointer;
    /// OpenReliant names it by its call sign alone.
    pub fn words(label: Label, said: *const language.Language, buffer: *[room]u8) []const u8 {
        return switch (label) {
            .string => |id| said.string(id) orelse "",
            .pilot => |pilot| {
                const call_sign = said.string(pilot.call_sign) orelse "";
                const name = said.string(pilot.name orelse return call_sign) orelse "";
                return std.fmt.bufPrint(buffer, "{s} ({s})", .{ name, call_sign }) catch call_sign;
            },
        };
    }
};

/// An item of a page (`0x00529540`, 8 bytes each): what it says, the page it leads to, and whom
/// that page is about.
pub const Item = struct {
    label: Label,
    page: Page,
    /// `wingman_addressed` (`0x00529596`) for the page it leads to: a ship's slot, or `picked`.
    addressed: i16,
};

/// Whom a page is about where the game picks the wingman (`wingman_addressed` -1).
pub const picked: i16 = -1;

/// The strings of the menu's title and items.
const strings = struct {
    /// COMMS, the window's title.
    const title = 0x14C;
    /// The top page's: Target, Alpha Wing and Base.
    const target = 0x14D;
    const pilots = 0x14E;
    const base = 0x14F;
    /// The pilots page's Alpha Wing, the whole wing.
    const whole_wing = 0x158;
    /// The base's: Permission to land, and Request backup.
    const permission_to_land = 0x15A;
    const request_backup = 0x15B;
    /// Open all channels, and Close all channels.
    const open_channels = 0x15D;
    const close_channels = 0x15E;
    /// The taunts, from I'm looking at a dead man.
    const taunts = [_]u16{ 0x168, 0x169, 0x16A, 0x16B, 0x16C };
    /// Attack my target, Back off; this one's mine, and Help me out.
    const commands = [_]u16{ 0x161, 0x162, 0x163 };
    /// What's your status?, Come on... get your act together, and Nice work. I owe you one.
    const status = 0x164;
    const scold = 0x165;
    const praise = 0x166;
    /// The call signs of the wing's places (`0x004EF7DC`): Alpha 1 to Alpha 5, and Alpha Leader.
    const call_signs = [_]u16{ 0x152, 0x153, 0x154, 0x155, 0x156, 0x157 };
};

comptime {
    std.debug.assert(strings.call_signs.len == @import("../mission.zig").wing_size);
}

/// The taunts' pages, and the commands', as the items list them.
const taunt_pages = [_]Page{ .taunt_1, .taunt_2, .taunt_3, .taunt_4, .taunt_5 };
const command_pages = [_]Page{ .attack_my_target, .back_off, .help_me };

/// What the radio's menu keeps between frames, which no mission's start clears.
pub const Menu = struct {
    page: Page = .top,
    items: [capacity]Item = undefined,
    /// How many items the page has (`0x00529CBC`).
    count: std.math.IntFittingRange(0, capacity) = 0,
    /// `wingman_addressed` (`0x00529596`): whom the page is about.
    addressed: i16 = picked,

    /// The items a page has room for (`0x00529540` up to `0x00529590`).
    pub const capacity = 10;

    pub fn shown(menu: *const Menu) []const Item {
        return menu.items[0..menu.count];
    }

    /// `0x00453B50`: an item more on the page.
    fn add(menu: *Menu, label: Label, page: Page, addressed: i16) void {
        if (menu.count == capacity) return;
        menu.items[menu.count] = .{ .label = label, .page = page, .addressed = addressed };
        menu.count += 1;
    }

    /// The menu from its top page, run at once (`run`), as COMMS WINDOW opens the radio's window
    /// (`frame_controls`, `0x00414707`) or the script does (`cmd_OpenInstrument`, `0x0045D9F0`).
    pub fn start(menu: *Menu, ctx: aigeneric.Context) void {
        menu.page = .top;
        menu.run(ctx);
    }

    /// `comms_menu_run` (`0x00455D40`), each frame the radio's window is open, first of the
    /// targeting keys (`hud.targetKeys`): the page makes its items, or does what its item says,
    /// and then the window closes, held no more, still showing the items of the page before. A
    /// page left with no items goes back to the top, which a page of none makes at once. Then the
    /// number keys choose an item, 1 the first: the display sounds `done`, and the item's page
    /// comes next, about whom the item names.
    ///
    /// **Fix:** where the top page itself has no items, the game makes it again and again, and
    /// hangs; OpenReliant leaves the menu empty.
    pub fn run(menu: *Menu, ctx: aigeneric.Context) void {
        const world = ctx.world;
        while (true) {
            const before = menu.count;
            const from = menu.page;
            menu.count = 0;
            const acted = menu.make(ctx);
            if (menu.count == 0) menu.page = .top;
            if (acted) {
                menu.count = before;
                if (world.display) |display| {
                    display.windows.status.getPtr(.comms).held = false;
                    display.windows.close(.comms);
                }
                break;
            }
            if (menu.count > 0 or from == .top) break;
        }
        const devices = ctx.devices orelse return;
        for (menu.shown(), 0..) |item, index| {
            const key: u8 = @intCast(@intFromEnum(input.Key.one) + index);
            if (!devices.keyboard.pressed(key, .none, true)) continue;
            hud.beep(world, .done);
            menu.page = item.page;
            menu.addressed = item.addressed;
            return;
        }
    }

    /// The page's work (`0x00455D66`): its items, or what its item says. Whether it did something,
    /// which closes the window.
    fn make(menu: *Menu, ctx: aigeneric.Context) bool {
        const world = ctx.world;
        const all = world.objects;
        switch (menu.page) {
            .top => menu.makeTop(all),
            .ship, .ship_again => menu.makeShip(all),
            .pilots => menu.makePilots(all),
            .base => {
                menu.add(.{ .string = strings.permission_to_land }, .permission_to_land, 0);
                menu.add(.{ .string = strings.request_backup }, .request_backup, 0);
            },
            .channels => {
                menu.add(.{ .string = strings.open_channels }, .open_channels, 0);
                menu.add(.{ .string = strings.close_channels }, .close_channels, 0);
            },
            .wing => for (strings.commands, command_pages) |string, page| menu.add(.{ .string = string }, page, menu.addressed),
            .taunt_1, .taunt_2, .taunt_3, .taunt_4, .taunt_5 => {
                taunt(ctx, @intCast(@intFromEnum(menu.page) - @intFromEnum(Page.taunt_1)), menu.addressed);
                return true;
            },
            .attack_my_target, .back_off, .help_me => {
                const command: wingmen.Command = switch (menu.page) {
                    .attack_my_target => .attack_my_target,
                    .back_off => .back_off,
                    else => .help_me,
                };
                wingmen.give(world, command, if (std.math.cast(u16, menu.addressed)) |slot| .{ .wingman = slot } else .picked);
                return true;
            },
            .status => {
                status(world, menu.addressed);
                return true;
            },
            .scold, .praise => {
                remark(world, if (menu.page == .scold) scolding else praise, menu.addressed);
                return true;
            },
            .nothing => return true,
            .permission_to_land => {
                videoreports.permissionToLand(world, world.clock.game_ticks);
                return true;
            },
            .request_backup => {
                videoreports.requestBackup(world);
                return true;
            },
            .open_channels, .close_channels => {
                world.player.remarks.kill_credit = menu.page == .open_channels;
                return true;
            },
            .multiplayer, .player, .message, .message_all, .request, .accept, .deny => {},
        }
        return false;
    }

    /// COMMS (`0x00453B90`): Target, where the player's target is a hostile ship that can be aimed
    /// at (`wingmen.hostileTarget`) and a fighter, a capital ship or one between by its type's
    /// class; Alpha Wing, where a ship of the player's wing but the player's is not exploding;
    /// and Base, but in a map of the multiplayer game's scenarios (`dmscenarios.isScenario`).
    fn makeTop(menu: *Menu, all: *create.Objects) void {
        if (wingmen.hostileTarget(all)) |target| if (all.slots[target].combat) |combat| switch (combat.class) {
            .fighter, .capital, .support => menu.add(.{ .string = strings.target }, .ship, @intCast(target)),
            else => {},
        };
        for (all.wing) |listed| {
            const slot = listed orelse continue;
            if (slot == all.player or all.slots[slot].object.flags.exploding) continue;
            menu.add(.{ .string = strings.pilots }, .pilots, 0);
            break;
        }
        if (!dmscenarios.isScenario(all.mission_number)) menu.add(.{ .string = strings.base }, .base, 0);
    }

    /// The ship the menu is about (`0x00454370`), unless it is exploding: for a hostile ship the
    /// five taunts. For a ship of the player's wing, the wingmen's commands where the player's
    /// target is a hostile ship that can be aimed at, and What's your status?; then, for it and any
    /// other friend, the scolding and the praise.
    fn makeShip(menu: *Menu, all: *create.Objects) void {
        const index = std.math.cast(u16, menu.addressed) orelse return;
        const object = &all.slots[index].object;
        if (object.flags.exploding) return;
        if (object.side == .hostile) {
            for (strings.taunts, taunt_pages) |string, page| menu.add(.{ .string = string }, page, menu.addressed);
            return;
        }
        if (object.wing == .player) {
            if (wingmen.hostileTarget(all) != null) {
                for (strings.commands, command_pages) |string, page| menu.add(.{ .string = string }, page, menu.addressed);
            }
            menu.add(.{ .string = strings.status }, .status, menu.addressed);
        }
        menu.add(.{ .string = strings.scold }, .scold, menu.addressed);
        menu.add(.{ .string = strings.praise }, .praise, menu.addressed);
    }

    /// Alpha Pilots (`0x00453C80`): each ship of the player's wing but the player's that is not
    /// exploding, by its pilot and the call sign of its place in the wing; then, for more than one,
    /// the whole wing.
    fn makePilots(menu: *Menu, all: *create.Objects) void {
        for (all.wing, strings.call_signs) |listed, call_sign| {
            const slot = listed orelse continue;
            if (slot == all.player) continue;
            const object = &all.slots[slot].object;
            if (object.flags.exploding) continue;
            const name = pilots.nameOf(object.pilot);
            menu.add(.{ .pilot = .{ .name = name, .call_sign = call_sign } }, .ship, @intCast(slot));
        }
        if (menu.count > 1) menu.add(.{ .string = strings.whole_wing }, .wing, picked);
    }
};

/// The pilot's own taunts (`0x004F0E5C`, `0x004F0E50`, `0x004F0E44`, `0x004F0E38`, `0x004F0E2C`).
const taunt_lines = [_][]const u8{ "hud_007.ut", "hud_008.ut", "hud_009.ut", "hud_010.ut", "hud_011.ut" };

/// The ends of a hostile pilot's answers to a taunt, in its voice (`0x004EF5EC`).
const taunt_answers = numbered("_res_", 1, 24);

/// The enemy's aces, by their pilots' numbers, who answer a taunt in lines of their own
/// (`0x00454AFC`).
const Ace = enum(i32) {
    black_sun = 10,
    ivan_petrov = 15,
    nicolai_petrov = 16,
    mcgann = 50,
    saracen_leader = 131,
    golden_warrior_leader = 133,
    _,

    /// Black Sun's lines (`0x004EF678`), Ivan Petrov's (`0x004EF694`), Nicolai Petrov's
    /// (`0x004EF6CC`), Colonel McGann's (`0x004EF70C`), the Saracens' leader's (`0x004EF64C`) and
    /// the Golden Warriors' leader's (`0x004EF6F4`).
    fn answers(ace: Ace) ?[]const []const u8 {
        return switch (ace) {
            .black_sun => &ace_answers.black_sun,
            .ivan_petrov => &ace_answers.ivan_petrov,
            .nicolai_petrov => &ace_answers.nicolai_petrov,
            .mcgann => &ace_answers.mcgann,
            .saracen_leader => &ace_answers.saracen_leader,
            .golden_warrior_leader => &ace_answers.golden_warrior_leader,
            _ => null,
        };
    }
};

const ace_answers = struct {
    const black_sun = numbered("hs_res_", 1, 7);
    const ivan_petrov = numbered("ip_res_", 1, 14);
    const nicolai_petrov = numbered("np_res_", 1, 10);
    const mcgann = numbered("cm_res_", 1, 10);
    const saracen_leader = numbered("al_res_", 1, 11);
    const golden_warrior_leader = numbered("rd_res_", 1, 6);
};

/// `0x00454870`: taunt `which` to the ship `addressed` names. The pilot says it
/// (`videoreports.playerSays`). Unless the ship is not to be disturbed, is not a fighter by its
/// type's class, or its current order has a priority or aims at the player's ship already, it turns
/// on the player's ship (Fight), and answers in `videoreports.report_delay` ticks: one of an ace's
/// own lines (`Ace`), or one of `taunt_answers` in its pilot's voice. Before it turns, the game
/// draws a random number it doesn't use if the pilot's `pilots.Pilot._unknown_20` is 0 or 1.
fn taunt(ctx: aigeneric.Context, which: usize, addressed: i16) void {
    const world = ctx.world;
    videoreports.playerSays(world, taunt_lines[which]);
    const all = world.objects;
    const index = std.math.cast(u16, addressed) orelse return;
    const slot = &all.slots[index];
    const object = &slot.object;
    if (object.flags.do_not_disturb) return;
    const combat = slot.combat orelse return;
    if (combat.class != .fighter) return;
    if (slot.current()) |current| {
        if (aigeneric.prioritised(all, current.order) or current.target.index == @as(i16, @intCast(all.player))) return;
    }
    switch (all.pilots.get(object.pilot)._unknown_20) {
        0, 1 => _ = world.random.rand(),
        else => {},
    }
    _ = aigeneric.giveShip(ctx, index, .fight, all.player, null);
    const own = (@as(Ace, @enumFromInt(object.pilot))).answers();
    const lines: videoreports.Lines = if (own) |named| .{ .named = named } else .{ .voiced = &taunt_answers };
    videoreports.reportShipIn(world, index, lines, videoreports.report_delay);
}

/// The pilot's own What's your status? (`0x004F0E8C`).
const status_line = "hud_004.ut";

/// The ends of a wingman's answers by how whole its armour is (`condition`), from its lowest, from
/// the fuller set of replies (`0x004EF4FC`, `0x004EF518`, `0x004EF538`) and from the set most pilots
/// have (`0x004EF550`, `0x004EF560`, `0x004EF570`).
const status_answers = struct {
    const full = [_][]const []const u8{ &numbered("_status_", 1, 7), &numbered("_status_", 8, 15), &numbered("_status_", 19, 24) };
    const most = [_][]const []const u8{ &numbered("_status_", 1, 4), &numbered("_status_", 5, 8), &numbered("_status_", 9, 11) };
};

/// How long a wingman takes to answer What's your status?, in the game's ticks (`0x004557F2`).
const status_delay = 250;

/// How much armour a quadrant starts with for each point of its type's armour class, less 1
/// (`0x0045577F`).
const armour_per_class = 6;

/// How whole a ship's armour is, for its answer to What's your status? (`0x00455761`): its four
/// quadrants together over `armour_per_class` times its type's armour class, the fraction dropped,
/// less 1, from 0 to 2.
fn condition(armour: gameobj.Quadrants, class: i32) usize {
    const together = armour.aft + armour.fore + armour.right + armour.left;
    const whole: f32 = @floatFromInt(class *% armour_per_class);
    const level = @as(i16, @truncate(math.ftol(together / whole))) - 1;
    return @intCast(std.math.clamp(level, 0, status_answers.full.len - 1));
}

/// `0x00455720`: What's your status?, to the wingman `addressed` names. The pilot asks
/// (`videoreports.playerSays`). A wingman whose pilot's `pilots.Pilot._unknown_1e` is above 0
/// answers after `status_delay` ticks, by how whole its
/// armour is (`condition`), from the fuller set of replies or the other
/// (`pilots.Face.full_replies`), in its voice.
///
/// **Fix:** the game reads the armour class of a ship with no type's stats through a null pointer;
/// OpenReliant makes no report.
fn status(world: gameobj.World, addressed: i16) void {
    videoreports.playerSays(world, status_line);
    const all = world.objects;
    const index = std.math.cast(u16, addressed) orelse return;
    const slot = &all.slots[index];
    const face = pilots.faceOf(slot.object.pilot) orelse return;
    if (@as(i16, @bitCast(all.pilots.get(slot.object.pilot)._unknown_1e)) <= 0) return;
    const combat = slot.combat orelse return;
    const level = condition(slot.object.armor, combat.armor_class);
    const set = if (face.full_replies) &status_answers.full else &status_answers.most;
    videoreports.reportShipIn(world, index, .{ .voiced = set[level] }, status_delay);
}

/// A remark to a wingman: the pilot's own line, and the ends of the wingman's answers from the
/// fuller set of replies and from the other.
const Remark = struct {
    line: []const u8,
    full: []const []const u8,
    most: []const []const u8,
};

/// Come on... get your act together (`0x004F0EA4`; `0x004EF57C`, `0x004EF5AC`), and Nice work. I
/// owe you one (`0x004F0EB0`; `0x004EF5BC`, `0x004EF5DC`).
const scolding: Remark = .{ .line = "hud_005.ut", .full = &numbered("_cmon_", 1, 12), .most = &numbered("_cmon_", 1, 4) };
const praise: Remark = .{ .line = "hud_006.ut", .full = &numbered("_iou_", 1, 8), .most = &numbered("_iou_", 1, 4) };

/// `0x00455B00` and `0x00455C20`: `said` to the ship `addressed` names. The pilot says it
/// (`videoreports.playerSays`), and the ship answers in `videoreports.report_delay` ticks
/// (`videoreports.reportShip`), from the fuller set of replies or the other.
fn remark(world: gameobj.World, said: Remark, addressed: i16) void {
    videoreports.playerSays(world, said.line);
    const index = std.math.cast(u16, addressed) orelse return;
    videoreports.reportShip(world, index, if (wingmen.fullReplies(world.objects, index)) said.full else said.most);
}

/// What the radio's window shows of the menu.
pub const Shown = struct {
    menu: *const Menu,
    /// `newfont.fnt` (`font_new`, `0x0059549C`), which the items are written in.
    font: *hud.Opened,
};

/// Where the menu stands from the window's place (`hud_window_draw`, `0x00486E74`), how far its
/// first item stands below it and each from the one before (`0x00453AA2`, `0x00453AC1`), and how
/// far an item's words stand from its number (`0x00453B30`).
const menu_at = [2]i32{ 2, 2 };
const items_below = 0x18;
const item_height = 0xC;
const words_across = 0xD;

/// Where item `index` of the page stands.
fn itemAt(index: usize) [2]i32 {
    return .{ menu_at[0], menu_at[1] + items_below + @as(i32, @intCast(index)) * item_height };
}

/// `0x00453A70`, the radio's window's contents in the view ahead: COMMS in the display's font,
/// and below it each item of the page in `newfont.fnt`, its number, 1 the first, and what it says
/// (`0x00453AD0`).
pub fn draw(shown: Shown, canvas: hud.windows.Canvas) hud.windows.Canvas.Error!void {
    try canvas.string(strings.title, menu_at, .left);
    for (shown.menu.shown(), 0..) |item, index| {
        const at = itemAt(index);
        try canvas.printIn(shown.font, "{d}.", .{index + 1}, at, .left);
        var buffer: [Label.room]u8 = undefined;
        try canvas.textIn(shown.font, item.label.words(canvas.pen.strings, &buffer), .{ at[0] + words_across, at[1] }, .left);
    }
}

test "Label.words" {
    var table = [_][]const u8{""} ** 0x160;
    table[0x14F - 1] = "Base";
    table[0x153 - 1] = "Alpha 2";
    table[0x4B - 1] = "BLACK SUN";
    const strings_found: language.Language = .{ .strings = &table };
    var buffer: [Label.room]u8 = undefined;
    try std.testing.expectEqualStrings("Base", (Label{ .string = 0x14F }).words(&strings_found, &buffer));
    try std.testing.expectEqualStrings("BLACK SUN (Alpha 2)", (Label{ .pilot = .{ .name = 0x4B, .call_sign = 0x153 } }).words(&strings_found, &buffer));
    // A wingman with no pilot goes by its call sign.
    try std.testing.expectEqualStrings("Alpha 2", (Label{ .pilot = .{ .name = null, .call_sign = 0x153 } }).words(&strings_found, &buffer));
}

test itemAt {
    try std.testing.expectEqual([2]i32{ 2, 26 }, itemAt(0));
    try std.testing.expectEqual([2]i32{ 2, 50 }, itemAt(2));
}

test condition {
    // Whole, holding up and hurt: a quadrant starts at six times the class, less 1.
    const class = 10;
    try std.testing.expectEqual(2, condition(.all(armour_per_class * class - 1), class));
    try std.testing.expectEqual(1, condition(.all(40), class));
    try std.testing.expectEqual(0, condition(.all(20), class));
    try std.testing.expectEqual(0, condition(.all(0), class));
    // A class of none leaves nothing to measure by.
    try std.testing.expectEqual(0, condition(.all(10), 0));
}

/// The menu's world for the tests: the radio's, with the player's wing and its target
/// (`videoreports.testing.Heard.initWing`), and the display.
const TestMenu = struct {
    heard: videoreports.testing.Heard,
    display: hud.State,
    devices: input.Devices,

    fn init(test_menu: *TestMenu) !aigeneric.Context {
        var world = try test_menu.heard.initWing();
        test_menu.display = .{};
        test_menu.devices = .{};
        world.display = &test_menu.display;
        return .{ .world = world, .devices = &test_menu.devices };
    }

    fn deinit(test_menu: *TestMenu) void {
        test_menu.heard.deinit();
    }

    /// Presses number key `number` for the next run.
    fn press(test_menu: *TestMenu, number: u8) void {
        test_menu.devices.keyboard = .{};
        test_menu.devices.keyboard.down[@intFromEnum(input.Key.one) + number - 1] = true;
    }
};

test "the pages lead from one to the next" {
    var test_menu: TestMenu = undefined;
    const ctx = try test_menu.init();
    defer test_menu.deinit();
    const all = ctx.world.objects;
    var menu: Menu = .{};

    // COMMS: the hostile fighter targeted, the wing and the base.
    menu.start(ctx);
    try std.testing.expectEqual(Page.top, menu.page);
    try std.testing.expectEqual(3, menu.count);
    try std.testing.expectEqual(Item{ .label = .{ .string = strings.target }, .page = .ship, .addressed = @intCast(test_menu.heard.enemy) }, menu.items[0]);
    try std.testing.expectEqual(Page.pilots, menu.items[1].page);
    try std.testing.expectEqual(Page.base, menu.items[2].page);

    // 2 leads to the wing's pilots, one of them, so not the whole wing.
    test_menu.press(2);
    menu.run(ctx);
    try std.testing.expectEqual(Page.pilots, menu.page);
    menu.run(ctx);
    try std.testing.expectEqual(1, menu.count);
    const bandit = menu.items[0];
    try std.testing.expectEqual(@as(i16, @intCast(test_menu.heard.wingman)), bandit.addressed);
    try std.testing.expectEqual(strings.call_signs[1], bandit.label.pilot.call_sign);

    // The wingman's page: the commands, the status, the scolding and the praise.
    test_menu.press(1);
    menu.run(ctx);
    menu.run(ctx);
    try std.testing.expectEqual(Page.ship, menu.page);
    try std.testing.expectEqual(6, menu.count);
    try std.testing.expectEqual(Page.attack_my_target, menu.items[0].page);
    try std.testing.expectEqual(Page.praise, menu.items[5].page);

    // An exploding ship's page has no items, and the menu goes back to the top at once.
    all.slots[test_menu.heard.wingman].object.flags.exploding = true;
    menu.run(ctx);
    try std.testing.expectEqual(Page.top, menu.page);
    try std.testing.expectEqual(2, menu.count);
    all.slots[test_menu.heard.wingman].object.flags.exploding = false;

    // The enemy's page holds the taunts.
    menu.page = .ship;
    menu.addressed = @intCast(test_menu.heard.enemy);
    menu.run(ctx);
    try std.testing.expectEqual(taunt_pages.len, menu.count);
    try std.testing.expectEqual(Page.taunt_1, menu.items[0].page);
}

test "a page that acts closes the window" {
    var test_menu: TestMenu = undefined;
    const ctx = try test_menu.init();
    defer test_menu.deinit();
    const windows = &test_menu.display.windows;
    _ = windows.open(.comms, false);
    windows.status.getPtr(.comms).held = true;
    var menu: Menu = .{};
    menu.start(ctx);

    // Close all channels, from the channels' page no item leads to: kills go uncredited.
    menu.page = .close_channels;
    menu.run(ctx);
    try std.testing.expect(!ctx.world.player.remarks.kill_credit);
    // The window closes, held no more, still showing the page before.
    try std.testing.expectEqual(3, menu.count);
    try std.testing.expect(!windows.status.get(.comms).held);
    try std.testing.expect(windows.status.get(.comms).phase == .closing);
    try std.testing.expectEqual(Page.top, menu.page);
    menu.page = .open_channels;
    menu.run(ctx);
    try std.testing.expect(ctx.world.player.remarks.kill_credit);
}

test "a taunt turns the enemy on the player" {
    var test_menu: TestMenu = undefined;
    const ctx = try test_menu.init();
    defer test_menu.deinit();
    const heard = &test_menu.heard;
    const all = ctx.world.objects;
    var menu: Menu = .{ .page = .taunt_3, .addressed = @intCast(heard.enemy) };
    menu.run(ctx);
    const current = all.slots[heard.enemy].current().?;
    try std.testing.expectEqual(.fight, current.order);
    try std.testing.expectEqual(@as(i16, @intCast(all.player)), current.target.index);
    // It answers in its pilot's voice.
    const report = heard.radio.reports[0] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, heard.enemy), report.object);
    try std.testing.expect(std.mem.startsWith(u8, report.speech.slice(), "rus_res_"));

    // Aimed at the player already, it is not taunted again.
    heard.radio.reports[0] = null;
    menu.page = .taunt_1;
    menu.run(ctx);
    try std.testing.expectEqual(null, heard.radio.reports[0]);

    // An ace answers in its own lines.
    try std.testing.expectEqualStrings("hs_res_007.ut", Ace.black_sun.answers().?[6]);
    try std.testing.expectEqual(null, @as(Ace, @enumFromInt(0)).answers());
}

test "the wingman's status" {
    var test_menu: TestMenu = undefined;
    const ctx = try test_menu.init();
    defer test_menu.deinit();
    const heard = &test_menu.heard;
    const all = ctx.world.objects;
    const combat = &heard.mission.tables.combat[@intFromEnum(gameobj.Type.predator)];
    combat.armor_class = 10;
    all.slots[heard.wingman].object.armor = .all(armour_per_class * 10 - 1);
    all.pilots.pilots[videoreports.testing.Heard.bandit]._unknown_1e = 1;
    var menu: Menu = .{ .page = .status, .addressed = @intCast(heard.wingman) };
    menu.run(ctx);
    const report = heard.radio.reports[0] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ctx.world.clock.game_ticks + status_delay, report.due);
    // Bandit has the fuller replies: whole, the last three of them.
    const speech = report.speech.slice();
    var found = false;
    for (status_answers.full[2]) |suffix| found = found or std.mem.endsWith(u8, speech, suffix);
    try std.testing.expect(found);

    // A pilot whose second value is 0 does not answer.
    heard.radio.reports[0] = null;
    all.pilots.pilots[videoreports.testing.Heard.bandit]._unknown_1e = 0;
    menu.page = .status;
    menu.run(ctx);
    try std.testing.expectEqual(null, heard.radio.reports[0]);
}
