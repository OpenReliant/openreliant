//! `C:\lancer\game\videoreports.cpp`: the radio's reports, the lines the pilots say with their
//! faces in the radio's window (`Radio`). **Unverified:** no string places its code; the link
//! order puts it after `loadout.cpp`, where the code that queues the reports and makes the radio's
//! remarks lies, from `0x00456050` to `0x00456F00`.
//!
//! The reports (`Report`) wait their time and are then said as lines: PERMISSION TO LAND's answer
//! and the wingmen's replies to their commands (`wingmen`) queue them. The remarks (`Remarks`) are
//! the lines the game has the pilots say by itself: the reminders to land and to jump, the warning
//! of a missile, and the words on a kill, a ship lost, a pilot ejecting, a hit on the player and a
//! launch. The radio's menu (`menu`), which the display's window 11 shows, reaches the wingmen,
//! the enemy and the base.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.radio);

const hog = @import("../../formats/hog.zig");
const bigfile = @import("bigfile.zig");
const aigeneric = @import("aigeneric.zig");
const cbox = @import("cbox.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const hog_snd = @import("hog_snd.zig");
const hudmovie = @import("hudmovie.zig");
const pilots = @import("pilots.zig");
const Windows = @import("hud/windows.zig").Windows;
const input = @import("../input.zig");
const vm = @import("../vm.zig");
const events = @import("mission/events.zig");

pub const wingmen = @import("videoreports/wingmen.zig");
pub const menu = @import("videoreports/menu.zig");

test {
    _ = wingmen;
    _ = menu;
}

/// The lines `stem` numbered from `first` to `last`, as `_amt_001.ut`, as the radio's tables list
/// them.
pub fn numbered(comptime stem: []const u8, comptime first: u16, comptime last: u16) [last - first + 1][]const u8 {
    var names: [last - first + 1][]const u8 = undefined;
    for (&names, first..) |*name, number| name.* = std.fmt.comptimePrint("{s}{d:0>3}.ut", .{ stem, number });
    return names;
}

test numbered {
    const names = comptime numbered("_amt_", 9, 13);
    try std.testing.expectEqual(5, names.len);
    try std.testing.expectEqualStrings("_amt_009.ut", names[0]);
    try std.testing.expectEqualStrings("_amt_013.ut", names[4]);
}

/// How long PERMISSION TO LAND goes unheard once heard, in the timer's ticks (`0x00453FC2`).
pub const permission_every: u32 = 500;

/// `permission_to_land` (`0x00453DE0`), as the player presses PERMISSION TO LAND outside a
/// multiplayer mission (`frame_controls`, `0x0041466A`), the timer at `game_ticks`: heard at most
/// once in `permission_every` ticks (`permission_heard_from`).
///
/// In a training mission (`create.Objects.training`), where the script's `landing_cleared` is
/// set, the pilot asks (`playerSays`, `hud_012`), and the flight instructor answers in
/// `report_delay` ticks (`trnglnd_001`) and clears the player's ship to land. In any other, unless
/// the ship is landing already, the pilot asks, and the bridge of the carrier it launched from
/// answers in `report_delay` ticks (`bridgeLine`): where `landing_cleared` is set it clears the
/// ship, by a line the script's `mission_success` picks at random from its lines, and otherwise it
/// refuses, by one of the refusals. A ship cleared lands on that carrier (`ailand`). A report
/// that finds the radio's reports all taken is not said, and a ship refused that way is not
/// cleared either. The radio's menu asks too (`menu.Page.permission_to_land`).
///
/// **Fix:** the game reads through a null pointer where the player's ship launched from no
/// carrier; OpenReliant asks nothing.
///
/// Not ported: the debug line it writes naming the mission's rating, which nothing shows; a
/// multiplayer game's side of it, in which a remote player's ship is cleared whatever the script
/// says ([#55](https://github.com/OpenReliant/openreliant/issues/55)); and the game's mode
/// `0x00524FE4` 1, in which the key works as in a training mission.
pub fn permissionToLand(world: gameobj.World, game_ticks: u32) void {
    const player = world.player;
    if (game_ticks < player.permission_heard_from) return;
    player.permission_heard_from = game_ticks + permission_every;
    const all = world.objects;
    const variables = world.variables orelse return;
    const radio = world.radio;
    if (all.training()) {
        if (variables.landing_cleared == 0) return;
        playerSays(world, request_line);
        if (radio) |heard| {
            const place = heard.freeReport() orelse return;
            var film: [report_text_size]u8 = undefined;
            heard.reports[place] = .{
                .object = instructor,
                .about = all.player,
                .name = instructor_name,
                .due = game_ticks + report_delay,
                .film = .of(std.fmt.bufPrint(&film, "pilots\\{s}.fm8", .{instructor_film}) catch hudmovie.static_film),
                .speech = .of(instructor_line),
            };
        }
        land(world);
        return;
    }
    if (landing(all)) return;
    const carrier = player.carrier orelse return;
    playerSays(world, request_line);
    const cleared = variables.landing_cleared != 0;
    if (radio) |heard| {
        const lines = if (cleared) clearances(variables.mission_success) else &refusals;
        if (!reportBridge(world, heard, carrier, lines, game_ticks)) return;
    }
    if (cleared) land(world);
}

/// A report of the bridge of `carrier` to the player, said `report_delay` ticks after
/// `game_ticks`: one of `lines`, as its officer says it (`bridgeLine`), under the name of the
/// Yamato's officer where the carrier is a Yamato and the Reliant's otherwise. False where the
/// radio's reports are all taken.
fn reportBridge(world: gameobj.World, radio: *Radio, carrier: u16, lines: []const []const u8, game_ticks: u32) bool {
    const place = radio.freeReport() orelse return false;
    const all = world.objects;
    var speech: [report_text_size]u8 = undefined;
    const said = bridgeLine(&speech, all, carrier, pick(world, lines));
    radio.reports[place] = .{
        .object = if (all.slots[carrier].object.type == .yamato) yamato_bridge else reliant_bridge,
        .about = all.player,
        .name = bridge_name,
        .due = game_ticks + report_delay,
        .film = .of(said.film),
        .speech = .of(said.speech),
    };
    return true;
}

/// The pilot's own line asking for backup (`0x004F0E98`).
const backup_request_line = "hud_013.ut";

/// The ends of the bridge's lines sending backup (`0x004EF7A4`) and refusing it (`0x004EF7C0`).
const backup_lines = struct {
    const sent = numbered("_reqbk_", 1, 7);
    const refused = numbered("_reqbk_", 8, 14);
};

/// `comms_request_backup` (`0x004558D0`), the radio menu's REQUEST BACKUP: the pilot asks
/// (`playerSays`, `hud_013`). Where the mission has backup to send (`vm.Variables.backup_available`)
/// and REQUEST BACKUP has not brought it yet this mission (`Remarks.backup_called`), the player's
/// ship has its PlayerWantsBackup, on which the script sends it (`events.wantsBackup`), and the
/// bridge of the carrier the ship launched from answers that it comes; otherwise the bridge
/// refuses. The bridge answers in `report_delay` ticks (`reportBridge`), unless the radio's reports
/// are all taken.
///
/// **Fix:** the game reads through a null pointer where the player's ship launched from no
/// carrier; OpenReliant makes no report.
pub fn requestBackup(world: gameobj.World) void {
    playerSays(world, backup_request_line);
    const remarks = &world.player.remarks;
    const available = if (world.variables) |variables| variables.backup_available != 0 else false;
    const sent = available and !remarks.backup_called;
    if (sent) {
        events.wantsBackup(world);
        remarks.backup_called = true;
    }
    const carrier = world.player.carrier orelse return;
    const radio = world.radio orelse return;
    _ = reportBridge(world, radio, carrier, if (sent) &backup_lines.sent else &backup_lines.refused, world.clock.game_ticks);
}

/// The player's ship lands on the carrier it launched from (`order_push`, Land).
fn land(world: gameobj.World) void {
    const carrier = world.player.carrier orelse return;
    const ctx: aigeneric.Context = .of(world);
    _ = aigeneric.giveShip(ctx, world.objects.player, .land, carrier, null);
}

/// How long a report waits before it is said, in the timer's ticks (`0x00453E40`).
pub const report_delay: u32 = 300;

/// Who speaks for the carriers and the training: the Yamato's bridge officer and the Reliant's,
/// pilots `0x54` and `0x3C` of the pilots' table (`0x00453E22`, `0x00453E68`), and the flight
/// instructor, pilot `0x52` (`0x004542B8`).
const yamato_officer: u16 = 0x54;
const reliant_officer: u16 = 0x3C;
const flight_instructor: u16 = 0x52;

/// Whose PERMISSION TO LAND's answers are, and the strings that name them.
const yamato_bridge: i32 = pilot_base + yamato_officer;
const reliant_bridge: i32 = pilot_base + reliant_officer;
const bridge_name: u16 = 0x44;
const instructor: i32 = pilot_base + flight_instructor;
const instructor_name: u16 = 0x100;

/// The flight instructor's film and line (`0x00505090`, `0x004F0D6C`), and the pilot's own line
/// asking to land (`0x004F0D8C`).
const instructor_film = "VirtFlt_Ins";
const instructor_line = "trnglnd_001.ut";
const request_line = "hud_012.ut";

/// The ends of the bridge's lines clearing a ship to land, for a mission the script rates a
/// success or better (`0x004EF734`), a partial failure or a partial success (`0x004EF758`), and
/// any other (`0x004EF774`); and those refusing it (`0x004EF794`).
const clearance_lines = struct {
    const success = [_][]const u8{ "_lnd_001.ut", "_lnd_002.ut", "_lnd_003.ut", "_lnd_004.ut", "_lnd_005.ut", "_lnd_006.ut", "_lnd_007.ut", "_lnd_008.ut", "_lnd_009.ut" };
    const partial = [_][]const u8{ "_lnd_010.ut", "_lnd_011.ut", "_lnd_012.ut", "_lnd_013.ut", "_lnd_014.ut", "_lnd_015.ut", "_lnd_016.ut" };
    const failure = [_][]const u8{ "_lnd_017.ut", "_lnd_018.ut", "_lnd_019.ut", "_lnd_020.ut", "_lnd_021.ut", "_lnd_022.ut", "_lnd_023.ut", "_lnd_024.ut" };
};
const refusals = [_][]const u8{ "_lnd_den_01.ut", "_lnd_den_02.ut", "_lnd_den_03.ut", "_lnd_den_04.ut" };

/// The bridge's lines clearing a ship to land for a mission rated `outcome` (`0x00453EA5`).
fn clearances(outcome: vm.Variables.Outcome) []const []const u8 {
    return switch (outcome) {
        .partial_failure, .partial_success => &clearance_lines.partial,
        .success, .success_bonus => &clearance_lines.success,
        else => &clearance_lines.failure,
    };
}

/// `0x00453620`: the bridge's line ending in `suffix`, written into `buffer`, and the film of the
/// officer who says it: the Yamato's, `yam` and `Yam_Brdge_Off`, where the carrier is a Yamato or
/// explodes; the Reliant's, `rel` and `Rel_Brdge_Off`, otherwise.
fn bridgeLine(buffer: []u8, all: *const create.Objects, carrier: u16, suffix: []const u8) struct { speech: []const u8, film: []const u8 } {
    const object = &all.slots[carrier].object;
    const yamato = object.type == .yamato or object.flags.exploding;
    const prefix = if (yamato) "yam" else "rel";
    return .{
        .speech = std.fmt.bufPrint(buffer, "{s}{s}", .{ prefix, suffix }) catch suffix,
        .film = if (yamato) "pilots\\Yam_Brdge_Off.fm8" else "pilots\\Rel_Brdge_Off.fm8",
    };
}

/// `0x004566C0` with `0x004536D0`: the pilot's own line ending in `line`, said at once without the
/// window, in the male voice (`mp`) or the female one (`fp`) by the pilot's sex (`input.Player.female`),
/// ending the line playing. Not ported: that a multiplayer mission says nothing
/// ([#55](https://github.com/OpenReliant/openreliant/issues/55)).
pub fn playerSays(world: gameobj.World, line: []const u8) void {
    const radio = world.radio orelse return;
    const hearing = world.hearing orelse return;
    var buffer: [report_text_size]u8 = undefined;
    const speech = std.fmt.bufPrint(&buffer, "{s}{s}", .{ if (world.player.female) "fp" else "mp", line }) catch return;
    radio.playSpeech(hearing.sound, speech);
}

/// Whether the player's ship is landing: its current order is Land.
fn landing(all: *create.Objects) bool {
    const entry = all.slots[all.player].current() orelse return false;
    return entry.order == .land;
}

// --- The remarks ---------------------------------------------------------------------------

/// What the radio's remarks keep between frames, which `radio_reset` (`0x004560F0`) clears as each
/// mission starts (`input.Player.remarks`).
pub const Remarks = struct {
    /// The enemy's taunts left unsaid (`DisableTaunts`, `0x00529CB4`), and the remarks
    /// (`DisableGenericComms`, `0x00529538`), but for the reminders to jump, the flight
    /// instructor's reminder to land and the ejection's words, as the mission's script asks.
    taunts_disabled: bool = false,
    generic_comms_disabled: bool = false,
    /// Whether the landing reminder has begun (`0x00529878`), and the frame's start past which it
    /// next speaks (`0x00529D40`).
    landing_reminded: bool = false,
    landing_next: i32 = 0,
    /// Whether the jump reminder has begun (`0x00529874`), how many of Moose's calls to jump it has
    /// made (`0x00529598`), and the game's tick from which the next comes (`0x00529D44`).
    jump_reminded: bool = false,
    jump_calls: std.math.IntFittingRange(0, jump_call_count) = 0,
    jump_next: u32 = 0,
    /// The frame's start past which the missile warning may speak again (`0x005297E4`).
    missile_next: i32 = 0,
    /// The slot of the pilot's pod that ejected last from the player's wing, until the rescue's
    /// words (`0x00529590`), and the frame's start past which they come (`0x00529880`).
    ejected: ?u16 = null,
    rescue_at: i32 = 0,
    /// The game's tick past which a kill draws a remark again (`0x00529CB8`).
    kill_next: u32 = 0,
    /// The frame's start past which an enemy may taunt again (`0x005297EC`).
    taunt_next: i32 = 0,
    /// Whether REQUEST BACKUP has brought backup this mission (`0x00529CB0`, `requestBackup`).
    backup_called: bool = false,
    /// Whether a kill is credited and remarked on (`kill_credit_on`, `0x00529C6C`,
    /// `aiexplode.killCredit`), which the radio menu's channels turn off and on again
    /// (`menu.Page.close_channels`).
    kill_credit: bool = true,
};

/// Who makes the squadron's remarks: Moose, pilot 2 of the pilots' table, the 45th Tigers', after
/// mission `hudmovie.last_volunteers_mission`, and pilot 4, the 45th Volunteers', through it
/// (`0x0045681C`).
const tigers_moose: u16 = 2;
const volunteers_moose: u16 = 4;

fn moose(all: *const create.Objects) u16 {
    return if (all.mission_number > hudmovie.last_volunteers_mission) tigers_moose else volunteers_moose;
}

/// `pick_line` (`0x00453A50`): one of `lines`, at random.
pub fn pick(world: gameobj.World, lines: []const []const u8) []const u8 {
    return lines[world.random.rand() % lines.len];
}

/// The radio and what it reaches as a line is said, where the world has a radio and is heard.
pub fn onAir(world: gameobj.World) ?struct { *Radio, Context } {
    const radio = world.radio orelse return null;
    const hearing = world.hearing orelse return null;
    return .{ radio, .{
        .sound = hearing.sound,
        .windows = if (world.display) |display| &display.windows else null,
        .all = world.objects,
        .frame_start = world.clock.frame_start,
    } };
}

/// `radio_busy` on the world's radio: whether a line plays or waits; never where nothing is heard.
fn busy(world: gameobj.World) bool {
    const radio, const ctx = onAir(world) orelse return false;
    return radio.busy(ctx.sound);
}

/// `Radio.sayPilot` on the world's radio, where it has one.
pub fn pilotSays(world: gameobj.World, pilot: u16, head: pilots.Head, speech: []const u8, mode: Mode, flags: hudmovie.Flags, expiry: i32) void {
    const radio, const ctx = onAir(world) orelse return;
    radio.sayPilot(ctx, pilot, head, speech, mode, flags, expiry);
}

/// `Radio.sayShip` on the world's radio, where it has one.
fn shipSays(world: gameobj.World, ship: u16, head: pilots.Head, speech: []const u8, mode: Mode, flags: hudmovie.Flags, expiry: i32) void {
    const radio, const ctx = onAir(world) orelse return;
    radio.sayShip(ctx, ship, head, speech, mode, flags, expiry);
}

/// Moose says `speech`, talking, the film looping (`radio_say_pilot`).
pub fn mooseSays(world: gameobj.World, speech: []const u8, mode: Mode, expiry: i32) void {
    pilotSays(world, moose(world.objects), .talking, speech, mode, .looping, expiry);
}

/// Moose says one of `lines`, picked at random (`pick`), in turn on the radio, never expiring.
pub fn mooseSaysOneOf(world: gameobj.World, lines: []const []const u8) void {
    mooseSays(world, pick(world, lines), .queued, no_expiry);
}

/// A report of the wingman in slot `ship` to the player, said `report_delay` ticks after the
/// game's tick: one of `lines` in the pilot's voice (`shipLine`), with the film of its face
/// talking, as the wingmen's commands answer (`0x00454DA9`). None where the radio's reports are all
/// taken; the line is picked as the report is made, even where nothing is heard.
///
/// **Fix:** the game copies the line of a pilot with no voice there from nowhere, and stops;
/// OpenReliant makes no report.
pub fn reportShip(world: gameobj.World, ship: u16, lines: []const []const u8) void {
    reportShipIn(world, ship, .{ .voiced = lines }, report_delay);
}

/// The lines a ship's report picks from: the ends of lines in its pilot's voice (`shipLine`), or
/// whole lines, as a few of the enemy's aces have their own.
pub const Lines = union(enum) {
    voiced: []const []const u8,
    named: []const []const u8,

    fn all(lines: Lines) []const []const u8 {
        return switch (lines) {
            inline else => |each| each,
        };
    }
};

/// `reportShip` of one of `lines`, said `delay` ticks after the game's tick.
pub fn reportShipIn(world: gameobj.World, ship: u16, lines: Lines, delay: u32) void {
    const radio = world.radio orelse {
        _ = pick(world, lines.all());
        return;
    };
    const place = radio.freeReport() orelse return;
    const picked = pick(world, lines.all());
    const all = world.objects;
    var buffer: [ship_line_size]u8 = undefined;
    const speech = switch (lines) {
        .voiced => shipLine(&buffer, all, ship, picked) orelse return,
        .named => picked,
    };
    var film: [film_path_size]u8 = undefined;
    radio.reports[place] = .{
        .object = ship,
        .about = all.player,
        .due = world.clock.game_ticks + delay,
        .film = .of(filmPath(&film, pilots.faceOf(all.slots[ship].object.pilot), .talking)),
        .speech = .of(speech),
    };
}

/// The room the game gives a ship's line's name (`0x00529CC0`, up to `0x00529D40`).
const ship_line_size = 0x80;

/// `ship_line` (`0x00453710`): the name of the line ending in `suffix` that the pilot of the ship
/// in slot `ship` says, written into `buffer`: in the pilot's voice for the friendly side
/// (`pilots.Face.allied_voice`) where the ship is friendly, and in its voice for the other
/// (`pilots.Face.voice`) where the ship is hostile. A pilot the game gives no voice there has none,
/// and its line is left out.
///
/// **Fix:** the game gives a ship on any other side whatever line it made last; OpenReliant gives
/// it none.
pub fn shipLine(buffer: []u8, all: *const create.Objects, ship: u16, suffix: []const u8) ?[]const u8 {
    const object = &all.slots[ship].object;
    const face = pilots.faceOf(object.pilot) orelse return null;
    const prefix = switch (object.side) {
        .friendly => @tagName(face.allied_voice orelse return null),
        .hostile => face.voice.prefix() orelse return null,
        else => return null,
    };
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ prefix, suffix }) catch null;
}

/// `radio_remarks_frame` (`0x00456B90`), each frame after the reports (`Radio.stepReports`): the
/// reminders to land (`landingReminder`) and to jump (`jumpReminder`), the missile warning
/// (`missileWarning`) and the rescue's words (`rescue`).
///
/// Not ported: the game's mode `0x00524FE4` 1, in which the reminders and the launch's words are
/// as in a training mission.
pub fn remarksFrame(world: gameobj.World) void {
    landingReminder(world);
    jumpReminder(world);
    missileWarning(world);
    rescue(world);
}

/// How long the landing reminder waits between its words, from the frame's start (`0x00456760`).
const landing_wait: i32 = 4500;

/// Moose's reminders to land (`0x004EF828`), and the flight instructor's (`0x004F0ED8`).
const landing_reminders = [_][]const u8{ "moolnd_001.ut", "moolnd_002.ut", "moolnd_003.ut" };
const training_landing_reminder = "trnprm_001.ut";

/// `radio_landing_reminder` (`0x00456710`), each frame, unless the player's ship is landing: while
/// the script's `landing_cleared` is set and the mission goes on, the reminder runs, and otherwise
/// it is over. As it begins, in a training mission, the flight instructor reminds the pilot to ask
/// to land, and says no more. In any other, every `landing_wait` ticks from then, Moose reminds the
/// pilot, unless the script has the remarks unsaid.
fn landingReminder(world: gameobj.World) void {
    const all = world.objects;
    if (landing(all)) return;
    const remarks = &world.player.remarks;
    const cleared = if (world.variables) |variables| variables.landing_cleared != 0 else false;
    if (!cleared or world.player.ending != .playing) {
        remarks.landing_reminded = false;
        return;
    }
    const now = world.clock.frame_start;
    if (!remarks.landing_reminded) {
        remarks.landing_reminded = true;
        remarks.landing_next = now + landing_wait;
        if (all.training()) pilotSays(world, flight_instructor, .talking, training_landing_reminder, .queued, .looping, no_expiry);
    }
    if (all.training() or now <= remarks.landing_next) return;
    if (!remarks.generic_comms_disabled) mooseSaysOneOf(world, &landing_reminders);
    remarks.landing_next = now + landing_wait;
}

/// How long the jump reminder waits between Moose's calls to jump, in the game's ticks
/// (`0x004568A1`), how many it makes (`0x00456995`), and how long it waits after the last
/// (`0x00456A4D`).
const jump_wait: u32 = 2000;
const jump_call_count = 4;
const jump_last_wait: u32 = 300;

/// Moose's words that a jump is ready (`0x004EF8AC`), or a warp (`0x004EF8BC`); the flight
/// instructor's (`0x004F0EE8`); and Moose's calls to jump, each one's lines more pressing than the
/// last's (`0x004EF7E8` to `0x004EF818`).
const jump_lines = [_][]const u8{ "jmp_001.ut", "jmp_002.ut", "jmp_003.ut", "jmp_004.ut" };
const warp_lines = [_][]const u8{ "wrp_001.ut", "wrp_002.ut", "wrp_003.ut", "wrp_004.ut" };
const training_jump_line = "trnjmp_001.ut";
const jump_call_lines = [jump_call_count][4][]const u8{
    .{ "moo_w1001.ut", "moo_w1002.ut", "moo_w1003.ut", "moo_w1004.ut" },
    .{ "moo_w2001.ut", "moo_w2002.ut", "moo_w2003.ut", "moo_w2004.ut" },
    .{ "moo_w3001.ut", "moo_w3002.ut", "moo_w3003.ut", "moo_w3004.ut" },
    .{ "moo_w4001.ut", "moo_w4002.ut", "moo_w4003.ut", "moo_w4004.ut" },
};

/// `radio_jump_reminder` (`0x00456860`), each frame: while the mission has a jump or a warp ready
/// (`hud.Readiness`) and goes on, the reminder runs, and otherwise it is over. As it begins, the
/// flight instructor in a training mission, or Moose in any other, says one is ready, a jump rather
/// than a warp where both are. Outside training, Moose then calls the pilot to jump every
/// `jump_wait` ticks, `jump_call_count` times, and `jump_last_wait` ticks after the last, the
/// player's ship jumps (`input.playerJump`). These are said whatever the script has unsaid.
fn jumpReminder(world: gameobj.World) void {
    const remarks = &world.player.remarks;
    const ready = if (world.variables) |variables| variables.ready else null;
    const jump = if (ready) |readiness| readiness.jump != .no else false;
    const warp = if (ready) |readiness| readiness.warp != .no else false;
    if (!(jump or warp) or world.player.ending != .playing) {
        remarks.jump_reminded = false;
        return;
    }
    const all = world.objects;
    const now = world.clock.game_ticks;
    if (!remarks.jump_reminded) {
        remarks.jump_reminded = true;
        remarks.jump_calls = 0;
        remarks.jump_next = now + jump_wait;
        if (all.training()) {
            pilotSays(world, flight_instructor, .talking, training_jump_line, .queued, .looping, no_expiry);
        } else {
            mooseSaysOneOf(world, if (jump) &jump_lines else &warp_lines);
        }
    }
    if (all.training() or now < remarks.jump_next) return;
    if (remarks.jump_calls == jump_call_count) {
        input.playerJump(world);
        remarks.jump_reminded = false;
        return;
    }
    mooseSaysOneOf(world, &jump_call_lines[remarks.jump_calls]);
    remarks.jump_calls += 1;
    remarks.jump_next = now + if (remarks.jump_calls == jump_call_count) jump_last_wait else jump_wait;
}

/// How long the missile warning waits before it may speak again, from the frame's start
/// (`0x00456AFE`), and how long its words may wait to be said (`0x00456ABF`).
const missile_wait: i32 = 1000;
const missile_expiry: i32 = 500;

/// Moose's warnings of a missile coming (`0x004EF834`).
const missile_warnings = [_][]const u8{ "plck_001.ut", "plck_002.ut", "plck_003.ut", "plck_004.ut", "plck_005.ut", "plck_006.ut", "plck_007.ut", "plck_008.ut" };

/// `radio_missile_warning` (`0x00456A80`), each frame: while a missile homes on the player's ship
/// (`gameobj.GameObject.missile_homing`) and the ship is in the action, at most once in
/// `missile_wait` ticks, Moose warns the pilot, unless the radio is busy or the script has the
/// remarks unsaid.
fn missileWarning(world: gameobj.World) void {
    const all = world.objects;
    const object = &all.slots[all.player].object;
    if (object.flags.outOfAction() or object.missile_homing == 0) return;
    const remarks = &world.player.remarks;
    const now = world.clock.frame_start;
    if (now <= remarks.missile_next) return;
    if (!remarks.generic_comms_disabled) mooseSays(world, pick(world, &missile_warnings), .if_idle, missile_expiry);
    remarks.missile_next = now + missile_wait;
}

/// How long after a wingman's pilot ejects the rescue's words come, from the frame's start
/// (`0x00456D9A`).
const rescue_wait: i32 = 1000;

/// The place in the player's wing of the wingman who says the rescue's words (`0x00515D92`).
const rescuer_place = 5;

/// The rescue's words (`0x004EF8CC`).
const rescue_lines = [_][]const u8{ "res_001.ut", "res_002.ut", "res_003.ut" };

/// `radio_rescue` (`0x00456B10`), each frame: `rescue_wait` ticks after a wingman's pilot ejects
/// (`wingmanEjected`), the wingman in the last place of the player's wing (`rescuer_place`) says
/// the rescue's words, unless the radio is busy, the pilot's pod is exploding, or the script has
/// the remarks unsaid.
///
/// **Fix:** the game reads before its objects where the wing has no ship in that place;
/// OpenReliant says nothing.
fn rescue(world: gameobj.World) void {
    const remarks = &world.player.remarks;
    const ejected = remarks.ejected orelse return;
    if (world.clock.frame_start <= remarks.rescue_at) return;
    remarks.ejected = null;
    const all = world.objects;
    if (all.slots[ejected].object.flags.exploding or remarks.generic_comms_disabled) return;
    const suffix = pick(world, &rescue_lines);
    const rescuer = all.wing[rescuer_place] orelse return;
    var buffer: [ship_line_size]u8 = undefined;
    const speech = shipLine(&buffer, all, rescuer, suffix) orelse return;
    const pilot = std.math.cast(u16, all.slots[rescuer].object.pilot) orelse return;
    pilotSays(world, pilot, .talking, speech, .if_idle, .looping, no_expiry);
}

/// How long after a kill's remark another's may come, in the game's ticks (`0x00456C14`); how long
/// a remark may wait to be said (`0x00456C5A`), and a dying pilot's last words (`0x00456C91`).
const kill_wait: u32 = 600;
const kill_expiry: i32 = 500;
const last_words_expiry: i32 = 200;

/// Moose's words on a pilot's pod shot (`0x004EF878`), on a fighter's kill (`0x004EF854`) and on a
/// torpedo's (`0x004EF884`); and a dying pilot's last words (`0x004EF8D8`).
const pod_kill_lines = [_][]const u8{ "enmejt_001.ut", "enmejt_002.ut", "enmejt_003.ut" };
const fighter_kill_lines = [_][]const u8{ "plyrkl_001.ut", "plyrkl_002.ut", "plyrkl_003.ut", "plyrkl_004.ut", "plyrkl_005.ut", "plyrkl_006.ut", "plyrkl_007.ut", "plyrkl_008.ut", "plyrkl_009.ut" };
const torpedo_kill_lines = [_][]const u8{ "trpkl_001.ut", "trpkl_002.ut", "trpkl_003.ut", "trpkl_004.ut", "trpkl_005.ut", "trpkl_006.ut" };
const last_words = [_][]const u8{ "dth_001.ut", "dth_002.ut", "dth_003.ut", "dth_004.ut", "dth_005.ut", "dth_006.ut" };

/// `radio_kill_remark` (`0x00456BB0`), as the player is credited with the kill of the object in
/// slot `index` (`aiexplode.killCredit`, `explode.loseHull`), outside a multiplayer game. A pilot's
/// pod has Moose remark on it, unless the radio is busy or the script has the remarks unsaid.
/// Anything else draws a remark at most once in `kill_wait` ticks, while the script lets the
/// remarks be said, and then only if the radio is free: a fighter's pilot says its last words, its
/// face dying, and Moose congratulates the player; a torpedo has Moose remark on it; any other kill
/// goes unremarked.
pub fn killRemark(world: gameobj.World, index: u16) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const remarks = &world.player.remarks;
    if (slot.object.flags.ejected) {
        if (!remarks.generic_comms_disabled) mooseSays(world, pick(world, &pod_kill_lines), .if_idle, no_expiry);
        return;
    }
    const now = world.clock.game_ticks;
    if (remarks.kill_next >= now or remarks.generic_comms_disabled) return;
    remarks.kill_next = now + kill_wait;
    if (busy(world)) return;
    const combat = slot.combat orelse return;
    switch (combat.class) {
        .fighter => {
            var buffer: [ship_line_size]u8 = undefined;
            if (shipLine(&buffer, all, index, pick(world, &last_words))) |speech| {
                shipSays(world, index, .dying, speech, .queued, .once, last_words_expiry);
            }
            mooseSays(world, pick(world, &fighter_kill_lines), .queued, kill_expiry);
        },
        .torpedo => mooseSays(world, pick(world, &torpedo_kill_lines), .if_idle, kill_expiry),
        else => {},
    }
}

/// The last words of a ship of the player's wing as it is lost (`0x004EFAD8`), and Moose's after
/// them (`0x004EF89C`).
const lost_line = "dth_001.ut";
const lost_lines = [_][]const u8{ "npcdth_001.ut", "npcdth_002.ut", "npcdth_003.ut", "npcdth_004.ut" };

/// `radio_ship_lost` (`0x00456CF0`), as a ship of the player's wing is lost
/// (`aiexplode.killCredit`), but the player's own, while the radio is free and the script lets the
/// remarks be said: its pilot says its last words, its face dying, and Moose mourns it.
pub fn shipLost(world: gameobj.World, index: u16) void {
    const all = world.objects;
    if (busy(world) or world.player.remarks.generic_comms_disabled or index == all.player) return;
    var buffer: [ship_line_size]u8 = undefined;
    if (shipLine(&buffer, all, index, lost_line)) |speech| shipSays(world, index, .dying, speech, .if_idle, .once, no_expiry);
    mooseSaysOneOf(world, &lost_lines);
}

/// A wingman's words as its pilot ejects (`0x004E3B18`).
const eject_line = "ejt_001.ut";

/// `radio_wingman_ejected` (`0x00456D80`), as the pilot of a ship of the player's wing but the
/// player's ejects (`aieject.init`), in the pod in slot `index`: the rescue's words wait
/// `rescue_wait` ticks (`rescue`), and the pilot says it is ejecting, unless the radio is busy or
/// the script has the remarks unsaid.
pub fn wingmanEjected(world: gameobj.World, index: u16) void {
    const all = world.objects;
    if (index == all.player) return;
    const remarks = &world.player.remarks;
    remarks.ejected = index;
    remarks.rescue_at = world.clock.frame_start + rescue_wait;
    if (remarks.generic_comms_disabled) return;
    var buffer: [ship_line_size]u8 = undefined;
    const speech = shipLine(&buffer, all, index, eject_line) orelse return;
    shipSays(world, index, .talking, speech, .if_idle, .looping, no_expiry);
}

/// How long after an enemy's taunt another may come, from the frame's start (`0x00456DFD`).
const taunt_wait: i32 = 2000;

/// The enemy's taunts (`0x004EF8F0`).
const taunts = [_][]const u8{ "tnt_001.ut", "tnt_002.ut", "tnt_003.ut", "tnt_004.ut", "tnt_005.ut", "tnt_006.ut", "tnt_007.ut", "tnt_008.ut", "tnt_009.ut", "tnt_010.ut", "tnt_011.ut", "tnt_012.ut", "tnt_013.ut" };

/// `radio_enemy_taunt` (`0x00456DD0`), as the ship in slot `attacker` hits the player's ship with a
/// shot or a missile (`collision.damage`, `collision.armorDamage`): a hostile ship, but one that
/// lists components, taunts the pilot at most once in `taunt_wait` ticks, unless the radio is busy
/// or the script has the taunts or the remarks unsaid.
pub fn enemyTaunt(world: gameobj.World, attacker: u16) void {
    const all = world.objects;
    if (attacker >= all.slots.len) return;
    const object = &all.slots[attacker].object;
    if (object.side != .hostile or object.flags.components) return;
    const remarks = &world.player.remarks;
    const now = world.clock.frame_start;
    if (now <= remarks.taunt_next) return;
    remarks.taunt_next = now + taunt_wait;
    if (remarks.generic_comms_disabled or remarks.taunts_disabled) return;
    var buffer: [ship_line_size]u8 = undefined;
    const speech = shipLine(&buffer, all, attacker, pick(world, &taunts)) orelse return;
    shipSays(world, attacker, .talking, speech, .if_idle, .looping, no_expiry);
}

/// The bridge officers' words as the player's ship launches, the Reliant's (`0x004EF924`) and the
/// Yamato's (`0x004EF93C`), and the flight instructor's (`0x004F0EF8`).
const reliant_launch_lines = [_][]const u8{ "relbdg_001.ut", "relbdg_002.ut", "relbdg_003.ut", "relbdg_004.ut", "relbdg_005.ut", "relbdg_006.ut" };
const yamato_launch_lines = [_][]const u8{ "yambdg_001.ut", "yambdg_002.ut", "yambdg_003.ut", "yambdg_004.ut", "yambdg_005.ut" };
const training_launch_line = "trnlch_001.ut";

/// `radio_launch_line` (`0x00456E50`), as the player's ship's launch from the ship in slot
/// `carrier` goes (`launch.update`), while the script lets the remarks be said and the radio is
/// free: the flight instructor speaks in a training mission, and in any other the bridge officer
/// of the carrier, a Reliant or a Yamato. A launch from anything else goes unremarked.
pub fn launchLine(world: gameobj.World, carrier: u16) void {
    if (world.player.remarks.generic_comms_disabled) return;
    const all = world.objects;
    if (all.training()) return pilotSays(world, flight_instructor, .talking, training_launch_line, .if_idle, .looping, no_expiry);
    const officer: u16, const lines: []const []const u8 = switch (all.slots[carrier].object.type) {
        .reliant => .{ reliant_officer, &reliant_launch_lines },
        .yamato => .{ yamato_officer, &yamato_launch_lines },
        else => return,
    };
    pilotSays(world, officer, .talking, pick(world, lines), .if_idle, .looping, no_expiry);
}

/// Where the radio's lines come from (`speech_hog`, `0x0057BC48`): `ms_speech\msspeech.hog`,
/// whose members are the lines without their `.ut` extension (`lineName`).
pub const speech_archive = "ms_speech/msspeech.hog";

/// How many lines the radio's queue holds (`0x005295A0`, `0x74` bytes each).
pub const queue_size = 5;

/// The most of a film's path and of a speech file's name a line in the queue keeps (`0x005295A6`
/// and `0x005295D8`, the room between each and what follows).
pub const film_size = 50;
pub const name_size = 52;

/// What marks a pilot of the pilots' table (`pilots.faces`) rather than a ship's slot in whose a
/// line is (`comms_object`, `0x0057BDF4`): the pilot's number from this on (`0x00456290`).
pub const pilot_base: i32 = 0xFFFF;

/// Whose a line is where it is nobody's (`comms_object`), as `PlayCommsMovie`'s are.
pub const nobody: i32 = -1;

/// The ticks the line said waits for the radio's window to open before it starts, with its film
/// (`hud_draw`, `0x00485335`, past `0x5B`).
pub const speech_delay: i32 = 92;

/// The expiry the commands give a line: none (`0x00458AF0`).
pub const no_expiry: i32 = -1;

/// How a line is said (`radio_say`, `0x004562D0`).
/// How many reports wait their time (`0x00529D48`), and the room each gives its film's path and
/// its speech file's name (`+0x18`, `+0x4A`).
pub const report_count = 5;
const report_text_size = 50;

/// A report (`0x00529D48`, `0x7C` bytes each): a line that waits its time, then goes to the queue
/// (`Radio.stepReports`).
pub const Report = struct {
    /// Whose it is, as a line's (`Line.object`).
    object: i32,
    /// **Unknown.** Whom it concerns (`+0x08`): PERMISSION TO LAND and the wingmen's replies put
    /// the player's ship there, and nothing reads it.
    about: i32 = nobody,
    /// **Unknown.** What kind of report it is (`+0x0C`): only one of `said_report` is said.
    kind: u16 = said_report,
    /// The string that names a pilot of the pilots' table who says it (`+0x10`); a ship's report
    /// is named by its pilot's face instead.
    name: ?u16 = null,
    /// The timer's tick past which it is said (`+0x14`).
    due: u32,
    film: Text(report_text_size),
    speech: Text(report_text_size),
};

/// A report as the game lays it out (`0x7C` bytes), for Ghidra.
pub const ReportRecord = extern struct {
    used: u16,
    _unknown_02: u16,
    object: i32,
    about: i32,
    kind: u16,
    /// **Unknown.** `radio_reset` sets it to -1, and nothing else touches it.
    _unknown_0e: u16,
    name: u16,
    _unknown_12: u16,
    due: i32,
    film: [report_text_size]u8,
    speech: [report_text_size]u8,

    comptime {
        std.debug.assert(@offsetOf(ReportRecord, "due") == 0x14);
        std.debug.assert(@offsetOf(ReportRecord, "film") == 0x18);
        std.debug.assert(@offsetOf(ReportRecord, "speech") == 0x4A);
        std.debug.assert(@sizeOf(ReportRecord) == 0x7C);
    }
};

/// The kind of report that is said, and an object whose report is not (`0x0045607D`).
const said_report: u16 = 1;
const unsaid_object: i32 = 0x3E9;

pub const Mode = enum(u32) {
    /// At once, ending the line playing.
    now = 0,
    /// Queued, said once the lines before it are.
    queued = 1,
    /// Queued unless a line plays or waits (`radio_busy`, `0x004561A0`).
    if_idle = 2,
    _,
};

/// A line as `radio_say` takes it.
pub const Line = struct {
    /// The film of the speaker's face, a path as `pilots\<film>.fm8`.
    film: []const u8,
    /// The speech file.
    speech: []const u8,
    /// The string that names the speaker, which the window shows; none for a pilot past the
    /// pilots' table.
    name: ?u16,
    flags: hudmovie.Flags = .looping,
    /// Whose it is (`comms_object`): a ship's slot, a pilot of the pilots' table from `pilot_base`
    /// on, or `nobody`.
    object: i32,
    /// The ticks from the frame's start past which a queued line is dropped unsaid; none below 1.
    expiry: i32 = no_expiry,
};

/// What the radio reaches of the game as a line is said.
pub const Context = struct {
    /// What the lines are heard through.
    sound: *hog_snd.Sound,
    /// The display's windows, where there is a display: window 0 is the radio's.
    windows: ?*Windows,
    all: *const create.Objects,
    /// The frame's start (`frame_start`), from which a queued line's expiry counts.
    frame_start: i32,
};

/// Text of at most `size` bytes, kept in place, as the queue keeps a line's names.
fn Text(comptime size: usize) type {
    return struct {
        bytes: [size]u8 = undefined,
        len: usize = 0,

        fn of(text: []const u8) @This() {
            var kept: @This() = .{ .len = @min(text.len, size) };
            @memcpy(kept.bytes[0..kept.len], text[0..kept.len]);
            return kept;
        }

        pub fn slice(kept: *const @This()) []const u8 {
            return kept.bytes[0..kept.len];
        }
    };
}

/// A line waiting in the queue, with the frame's tick past which it is dropped unsaid, or none.
pub const Queued = struct {
    flags: hudmovie.Flags,
    name: ?u16,
    film: Text(film_size),
    speech: Text(name_size),
    object: i32,
    expiry: ?i32,

    /// Whether it is still to be said at `frame_start`.
    fn due(line: *const Queued, frame_start: i32) bool {
        const expiry = line.expiry orelse return true;
        return frame_start <= expiry;
    }
};

/// The name a speech file is kept under in the archive (`hog_read_file`, `0x004C7F60`): the name
/// from its last backslash on, less an extension beginning `ut`.
pub fn lineName(name: []const u8) []const u8 {
    const after = hudmovie.memberName(name);
    const dot = std.mem.lastIndexOfScalar(u8, after, '.') orelse return after;
    return if (std.ascii.startsWithIgnoreCase(after[dot + 1 ..], "ut")) after[0..dot] else after;
}

/// Reads the speech file that `speech` names into `gpa`, from a mod or from the speech archive
/// `archive` (`speech_hog`), by the name `hog_read_file` looks up (`lineName`). A mod's file takes
/// priority (`bigfile.Mods.readFile`). Returns null if there's no archive and no mod has the file,
/// and also, with a warning, if the archive doesn't have it or it can't be read.
pub fn readLine(gpa: Allocator, mods: *const bigfile.Mods, archive: ?hog.Archive, speech: []const u8) ?[]u8 {
    const name = lineName(speech);
    const modded = mods.readFile(gpa, name) catch |err| {
        log.warn("can't read the line {s}: {s}", .{ name, @errorName(err) });
        return null;
    };
    if (modded) |bytes| return bytes;
    const lines = archive orelse return null;
    const entry = lines.find(name) orelse {
        log.warn("the line {s} is not in {s}", .{ name, speech_archive });
        return null;
    };
    const contents = lines.read(gpa, entry) catch |err| {
        log.warn("can't read the line {s}: {s}", .{ name, @errorName(err) });
        return null;
    };
    return contents.bytes;
}

/// The room the game gives a pilot's film's path (`radio_say_pilot`, `0x00456255`).
const film_path_size = 128;

/// The path of `face`'s film for `head`, `pilots\<film>.fm8` (`0x004F0D7C`), written into
/// `buffer`; or the dead channel's film where there is no face, no film for `head`, or no room.
fn filmPath(buffer: []u8, face: ?*const pilots.Face, head: pilots.Head) []const u8 {
    const film = (face orelse return hudmovie.static_film).film(head) orelse return hudmovie.static_film;
    return std.fmt.bufPrint(buffer, "pilots\\{s}.fm8", .{film}) catch hudmovie.static_film;
}

/// The radio: the archive its lines come from, the line playing and the lines waiting, and the
/// film of the speaker's face.
pub const Radio = struct {
    gpa: Allocator,
    /// `speech_hog`; null if the game folder doesn't have it, which leaves the radio silent except
    /// for lines from mods.
    archive: ?hog.Archive,
    /// Added by OpenReliant: the mods, whose lines take priority over the archive's
    /// (`bigfile.Mods`).
    mods: *const bigfile.Mods = &bigfile.Mods.none,
    player: cbox.Player = .{},
    /// How the lines sound.
    style: cbox.Style = .{},
    /// The films of the speakers' faces (`hudmovie.cpp`).
    movie: hudmovie.Movie,
    /// The speech file of the line said last, read as it is said, until it starts with its film
    /// (`radio_speech`, `0x005883CC`).
    line: []u8 = &.{},
    /// The string that names whoever says the line (`0x0057BC4C`), whose it is (`comms_object`,
    /// `0x0057BDF4`), and their side (`0x0056993C`), which the window shows.
    name: ?u16 = null,
    object: i32 = nobody,
    side: gameobj.Side(u16) = .friendly,
    /// The queue (`0x005295A0`), how many lines wait (`0x00529594`), where the next is put
    /// (`0x00529870`) and where the next is taken from (`0x00529CBE`).
    queue: [queue_size]Queued = undefined,
    count: usize = 0,
    write: usize = 0,
    read: usize = 0,
    /// The reports waiting their time.
    reports: [report_count]?Report = @splat(null),

    /// Opens the radio, with its lines from `speech_archive` and its films from
    /// `hudmovie.archive_path` in `dir` (without either if it can't be opened), and with `mods`
    /// taking priority over both.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir, mods: *const bigfile.Mods) Radio {
        var radio: Radio = .openAt(gpa, io, dir, speech_archive, hudmovie.archive_path);
        radio.mods = mods;
        radio.movie.mods = mods;
        return radio;
    }

    /// The radio with its lines from the archive at `lines` and its films from the one at `films`
    /// in `dir`.
    pub fn openAt(gpa: Allocator, io: Io, dir: Io.Dir, lines: []const u8, films: []const u8) Radio {
        const archive = hog.Archive.open(gpa, io, dir, lines) catch |err| none: {
            log.warn("the radio has no lines: can't open {s}: {s}", .{ lines, @errorName(err) });
            break :none null;
        };
        return .{ .gpa = gpa, .archive = archive, .movie = .openAt(gpa, io, dir, films) };
    }

    pub fn deinit(radio: *Radio, sound: ?*hog_snd.Sound) void {
        radio.reset(sound);
        radio.movie.deinit();
        if (radio.archive) |*archive| archive.close(radio.gpa);
        radio.archive = null;
    }

    /// `radio_reset` (`0x004560F0`), as a mission starts and as it ends: the line playing ended
    /// (`speech_stop_all`, `0x004620D0`), the queue emptied, and the window naming no one.
    ///
    /// **Fix:** the game leaves a film playing into the next mission, whose first line then starts
    /// before its window has opened; OpenReliant stops it.
    pub fn reset(radio: *Radio, sound: ?*hog_snd.Sound) void {
        if (sound) |heard| radio.player.stop(radio.gpa, heard) else radio.player.deinit(radio.gpa);
        radio.dropLine();
        radio.movie.stop();
        radio.movie.waiting = false;
        radio.name = null;
        radio.object = nobody;
        radio.count = 0;
        radio.write = 0;
        radio.read = 0;
        radio.reports = @splat(null);
    }

    /// `speech_playing` (`0x004620A0`): whether a line plays.
    pub fn speaking(radio: *const Radio, sound: ?*hog_snd.Sound) bool {
        const heard = sound orelse return false;
        return radio.player.playing(heard);
    }

    /// `radio_busy` (`0x004561A0`): whether a line plays or waits.
    pub fn busy(radio: *const Radio, sound: *hog_snd.Sound) bool {
        return radio.speaking(sound) or radio.count > 0;
    }

    /// `radio_say` (`0x004562D0`), outside a multiplayer mission: `line` said as `mode` has it.
    /// Said at once (`sayNow`), it ends the line playing. Queued, it waits its turn (`frame`),
    /// dropped past its expiry from the frame's start where it has one, or where the queue is
    /// full.
    pub fn say(radio: *Radio, ctx: Context, line: Line, mode: Mode) void {
        switch (mode) {
            .now => radio.sayNow(ctx, line),
            .queued => radio.enqueue(line, ctx.frame_start),
            .if_idle => if (!radio.busy(ctx.sound)) radio.enqueue(line, ctx.frame_start),
            _ => {},
        }
    }

    /// `radio_say`'s mode 0: the window opens held unless it is open (`Windows.hold`), the line
    /// playing stops, the window names the speaker, their side found (`sideOf`), and the line's
    /// speech is read and its film played, the line starting with it (`start`).
    fn sayNow(radio: *Radio, ctx: Context, line: Line) void {
        if (ctx.windows) |windows| if (windows.status.get(.radio).phase != .open) windows.hold(.radio);
        radio.player.stop(radio.gpa, ctx.sound);
        radio.name = line.name;
        radio.object = line.object;
        radio.side = sideOf(ctx.all, line.object);
        radio.load(line.speech);
        radio.start(ctx, line.film, line.flags);
    }

    /// `radio_say_pilot` (`0x00456250`): `speech` said by pilot `pilot` of the pilots' table, its
    /// face moving as `head` says, outside a multiplayer mission.
    pub fn sayPilot(radio: *Radio, ctx: Context, pilot: u16, head: pilots.Head, speech: []const u8, mode: Mode, flags: hudmovie.Flags, expiry: i32) void {
        const face = pilots.faceOf(pilot);
        var buffer: [film_path_size]u8 = undefined;
        radio.say(ctx, .{
            .film = filmPath(&buffer, face, head),
            .speech = speech,
            .name = if (face) |found| found.name else null,
            .flags = flags,
            .object = pilot_base + @as(i32, pilot),
            .expiry = expiry,
        }, mode);
    }

    /// `radio_say_ship` (`0x004561C0`): `speech` said by the ship in slot `ship`, its pilot's face
    /// moving as `head` says, outside a multiplayer mission: not by a stand-in, nor a ship
    /// exploding.
    ///
    /// **Fix:** the game reads beside the pilots' table for a pilot past it; OpenReliant says the
    /// line with the dead channel's film and no name. Where the game's ship has no pilot record it
    /// says nothing; every ship OpenReliant makes has a pilot.
    pub fn sayShip(radio: *Radio, ctx: Context, ship: u16, head: pilots.Head, speech: []const u8, mode: Mode, flags: hudmovie.Flags, expiry: i32) void {
        const all = ctx.all;
        if (ship >= all.slots.len) return;
        const object = &all.slots[ship].object;
        if (object.flags.stand_in or object.flags.exploding) return;
        const face = pilots.faceOf(object.pilot);
        var buffer: [film_path_size]u8 = undefined;
        radio.say(ctx, .{
            .film = filmPath(&buffer, face, head),
            .speech = speech,
            .name = if (face) |found| found.name else null,
            .flags = flags,
            .object = ship,
            .expiry = expiry,
        }, mode);
    }

    /// `radio_frame` (`0x00456510`), each frame: while lines wait, the window is shut or closing and
    /// no line plays, the next is taken, and said unless its time has passed: the window opens
    /// held, names the speaker, and, where the line is someone's, its speech is read and its film
    /// played, the line starting with it. One that is nobody's leaves the window open with nothing
    /// in it, which then closes.
    pub fn frame(radio: *Radio, ctx: Context) void {
        if (radio.count == 0) return;
        if (ctx.windows) |windows| switch (windows.status.get(.radio).phase) {
            .shut, .closing => {},
            .opening, .open => return,
        };
        if (radio.speaking(ctx.sound)) return;
        const line = &radio.queue[radio.read];
        if (line.due(ctx.frame_start)) {
            if (ctx.windows) |windows| windows.hold(.radio);
            radio.dropLine();
            radio.object = line.object;
            radio.name = line.name;
            if (line.object != nobody) {
                radio.side = sideOf(ctx.all, line.object);
                radio.load(line.speech.slice());
                radio.start(ctx, line.film.slice(), line.flags);
            }
        }
        radio.count -= 1;
        radio.read = (radio.read + 1) % queue_size;
    }

    /// `0x004560D0`: the first report free, or null where all are taken.
    pub fn freeReport(radio: *const Radio) ?usize {
        for (radio.reports, 0..) |report, place| {
            if (report == null) return place;
        }
        return null;
    }

    /// `0x00456050`, each frame after `frame`: each report whose time has passed at `game_ticks`
    /// goes, and one of `said_report` is said, queued, looping and never too late (`say`), unless
    /// it is nobody's or `unsaid_object`'s, or a ship's that is exploding. A ship's report is
    /// named by its pilot's face, a pilot's by the report's name.
    pub fn stepReports(radio: *Radio, ctx: Context, game_ticks: u32) void {
        for (&radio.reports) |*held| {
            const report = held.* orelse continue;
            if (game_ticks <= report.due) continue;
            held.* = null;
            if (report.kind != said_report or report.object == nobody or report.object == unsaid_object) continue;
            var name: ?u16 = report.name;
            if (report.object < pilot_base) {
                if (report.object < 0 or report.object >= ctx.all.slots.len) continue;
                const object = &ctx.all.slots[@intCast(report.object)].object;
                if (object.flags.exploding) continue;
                name = pilots.nameOf(object.pilot);
            }
            radio.say(ctx, .{
                .film = report.film.slice(),
                .speech = report.speech.slice(),
                .name = name,
                .object = report.object,
            }, .queued);
        }
    }

    /// The film's timer for a frame of `ticks` (`hudmovie.Movie.run`): a film that held for its
    /// line, which is over, has stopped, and the window closes.
    pub fn runFilm(radio: *Radio, ctx: Context, ticks: u32) void {
        if (!radio.movie.run(ticks, radio.speaking(ctx.sound), ctx.all.mission_number)) return;
        if (ctx.windows) |windows| windows.close(.radio);
    }

    /// `hud_draw` (`0x0048531D`), each frame: while the line said waits for the window to open
    /// (`hudmovie.Movie.waiting`), the frame's ticks are counted, and at `speech_delay` the line
    /// starts, and its film with it.
    pub fn waitForWindow(radio: *Radio, sound: ?*hog_snd.Sound, ticks: i32) void {
        const movie = &radio.movie;
        if (!movie.waiting) return;
        movie.waited += ticks;
        if (movie.waited < speech_delay) return;
        if (sound) |heard| radio.startLine(heard);
        movie.waiting = false;
    }

    /// `cmd_PlaySpeech`'s line (`0x00458090`): the speech file `speech` played at once, without a
    /// window or a film, ending the line playing. The game reads it into a buffer of its own
    /// (`0x005883D0`), so a line waiting for the window keeps its own.
    pub fn playSpeech(radio: *Radio, sound: *hog_snd.Sound, speech: []const u8) void {
        radio.player.stop(radio.gpa, sound);
        const bytes = radio.readSpeech(speech) orelse return;
        defer radio.gpa.free(bytes);
        radio.play(sound, bytes);
    }

    /// The ship whose line the window names while it is open or opening, unless it is cloaked
    /// (`hud_comms_marker`, `0x0048B0F0`; `hud_radar`, `0x00488BDE`); none for a pilot's line or
    /// nobody's.
    ///
    /// **Fix:** the radar takes a pilot's number for a slot, and marks whatever ship lies there;
    /// OpenReliant marks only a ship whose line it is.
    pub fn speakingShip(radio: *const Radio, windows: *const Windows, all: *const create.Objects) ?u16 {
        if (!windows.up(.radio)) return null;
        if (radio.object < 0 or radio.object >= all.count) return null;
        const ship: u16 = @intCast(radio.object);
        if (all.slots[ship].object.flags.cloaked) return null;
        return ship;
    }

    fn enqueue(radio: *Radio, line: Line, frame_start: i32) void {
        if (radio.count >= queue_size) return;
        radio.queue[radio.write] = .{
            .flags = line.flags,
            .name = line.name,
            .film = .of(line.film),
            .speech = .of(line.speech),
            .object = line.object,
            .expiry = if (line.expiry < 1) null else frame_start + line.expiry,
        };
        radio.count += 1;
        radio.write = (radio.write + 1) % queue_size;
    }

    /// The film at `film` played as `flags` say (`hudmovie.Movie.play`), and the line said with it
    /// started where a film was playing already; otherwise it waits for the window
    /// (`waitForWindow`).
    fn start(radio: *Radio, ctx: Context, film: []const u8, flags: hudmovie.Flags) void {
        if (radio.movie.play(film, flags, ctx.all.mission_number)) radio.startLine(ctx.sound);
    }

    /// The line said last (`line`) read from the archive, in place of the one before.
    fn load(radio: *Radio, speech: []const u8) void {
        radio.dropLine();
        radio.line = radio.readSpeech(speech) orelse &.{};
    }

    fn dropLine(radio: *Radio) void {
        radio.gpa.free(radio.line);
        radio.line = &.{};
    }

    /// `speech_start` for the line said last, which then goes.
    fn startLine(radio: *Radio, sound: *hog_snd.Sound) void {
        if (radio.line.len == 0) return;
        defer radio.dropLine();
        radio.play(sound, radio.line);
    }

    /// Reads the speech file that `speech` names, from a mod or the archive (`readLine`).
    fn readSpeech(radio: *Radio, speech: []const u8) ?[]u8 {
        return readLine(radio.gpa, radio.mods, radio.archive, speech);
    }

    /// `bytes`, a speech file, played (`cbox.Player.start`) at the volume every line the game plays
    /// takes, the line playing ended; one that is not a speech file is left out with a warning.
    fn play(radio: *Radio, sound: *hog_snd.Sound, bytes: []u8) void {
        const parsed = cbox.Speech.parse(bytes) orelse {
            log.warn("a line of the radio's is not a speech file", .{});
            return;
        };
        _ = radio.player.start(radio.gpa, sound, parsed, hog_snd.loudest, radio.style, null);
    }
};

/// The side of whoever says a line whose `object` is (`radio_say`, `0x00456475`): a ship's, a
/// pilot's face's, or the friendly side for nobody's. One past the objects or the pilots' table,
/// which the game reads beside them, is friendly too.
pub fn sideOf(all: *const create.Objects, object: i32) gameobj.Side(u16) {
    if (object >= pilot_base) {
        const face = pilots.faceOf(object - pilot_base) orelse return .friendly;
        return face.side;
    }
    if (object < 0 or object >= all.count) return .friendly;
    const side = @intFromEnum(all.slots[@intCast(object)].object.side);
    return @enumFromInt(@as(u16, @truncate(@as(u32, @bitCast(side)))));
}

test Radio {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // An archive of two lines, and one of films.
    var archives: testing.Archives = undefined;
    try archives.init(gpa, io, &.{ "MS1_BAN_001", "PLCK_001" }, &.{
        .{ .name = "45volntrs_plt.fm8", .frames = 2, .colour = 0x40 },
        .{ .name = "static.fm8", .frames = 2, .colour = 0x80 },
    });
    defer archives.deinit();
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    mission.objects.mission_number = 1;
    const wingman = try mission.add(.predator, @splat(0));
    const enemy = try mission.add(.predator, .{ 0, 0, 1000 });
    mission.slot(enemy).object.side = .hostile;

    var radio = archives.radio(gpa, io);
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    defer sound.shutdown();
    defer radio.deinit(sound);
    try std.testing.expect(radio.archive != null and radio.movie.archive != null);
    var windows: Windows = .{};
    const ctx: Context = .{ .sound = sound, .windows = &windows, .all = mission.objects, .frame_start = 100 };

    // A line said at once opens the window held and names its speaker; the line waits for the
    // window, with its film, the 45th Tigers' pilot's as the Volunteers' in mission 1.
    radio.sayShip(ctx, wingman, .squadron, "ms1_ban_001.ut", .now, .looping, no_expiry);
    try std.testing.expectEqual(.opening, windows.status.get(.radio).phase);
    try std.testing.expect(windows.status.get(.radio).held);
    try std.testing.expectEqual(pilots.faces[0].name, radio.name.?);
    try std.testing.expectEqual(@as(i32, wingman), radio.object);
    try std.testing.expect(radio.movie.playing and radio.movie.waiting);
    try std.testing.expectEqual([4]u8{ 0x40, 0x40, 0x40, 0xFF }, radio.movie.rgba[0..4].*);
    try std.testing.expect(!radio.speaking(sound));
    radio.waitForWindow(sound, speech_delay - 1);
    try std.testing.expect(!radio.speaking(sound));
    radio.waitForWindow(sound, 1);
    try std.testing.expect(radio.speaking(sound));
    try std.testing.expect(!radio.movie.waiting);

    // A line queued waits while the window is up, and until the line playing is over.
    radio.sayShip(ctx, enemy, .talking, "plck_001.ut", .queued, .looping, no_expiry);
    try std.testing.expectEqual(1, radio.count);
    radio.frame(ctx);
    try std.testing.expectEqual(1, radio.count);
    windows.close(.radio);
    radio.player.stop(gpa, sound);
    radio.frame(ctx);
    try std.testing.expectEqual(0, radio.count);
    // Taken, it opens the window again, with a film playing already, so its line starts at once,
    // on the hostile side.
    try std.testing.expectEqual(.opening, windows.status.get(.radio).phase);
    try std.testing.expect(radio.speaking(sound));
    try std.testing.expectEqual(.hostile, radio.side);
    // The ship whose line it is shows while the window is up, unless cloaked.
    try std.testing.expectEqual(enemy, radio.speakingShip(&windows, mission.objects).?);
    mission.slot(enemy).object.flags.cloaked = true;
    try std.testing.expectEqual(null, radio.speakingShip(&windows, mission.objects));

    // A line queued unless the radio is busy waits for it to go quiet; one whose time has passed
    // is dropped unsaid.
    const pilot_line: Line = .{ .film = hudmovie.static_film, .speech = "plck_001.ut", .name = null, .object = pilot_base + 3, .expiry = 50 };
    radio.say(ctx, pilot_line, .if_idle);
    try std.testing.expectEqual(0, radio.count);
    radio.player.stop(gpa, sound);
    radio.say(ctx, pilot_line, .if_idle);
    try std.testing.expectEqual(1, radio.count);
    try std.testing.expectEqual(150, radio.queue[radio.read].expiry.?);
    windows.close(.radio);
    radio.frame(.{ .sound = sound, .windows = &windows, .all = mission.objects, .frame_start = 200 });
    try std.testing.expectEqual(0, radio.count);
    try std.testing.expect(!radio.speaking(sound));
    // The queue holds five; a sixth is dropped.
    for (0..queue_size + 1) |_| radio.say(ctx, pilot_line, .queued);
    try std.testing.expectEqual(queue_size, radio.count);
    radio.reset(sound);
    try std.testing.expectEqual(0, radio.count);
    try std.testing.expect(!radio.movie.playing);

    // A line played by the script has no window nor film; one the archive lacks is left out.
    radio.playSpeech(sound, "ms1_ban_001.ut");
    try std.testing.expect(radio.speaking(sound));
    try std.testing.expect(!radio.movie.playing);
    radio.playSpeech(sound, "nothing.ut");
    try std.testing.expect(!radio.speaking(sound));
}

test sideOf {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const enemy = try mission.add(.predator, @splat(0));
    mission.slot(enemy).object.side = .hostile;
    try std.testing.expectEqual(.hostile, sideOf(mission.objects, enemy));
    try std.testing.expectEqual(.friendly, sideOf(mission.objects, nobody));
    // A pilot's side is its face's, and the pilots past the table friendly.
    try std.testing.expectEqual(pilots.faces[21].side, sideOf(mission.objects, pilot_base + 21));
    try std.testing.expectEqual(.friendly, sideOf(mission.objects, pilot_base + pilots.faces.len));
}

test filmPath {
    var buffer: [film_path_size]u8 = undefined;
    const bandit = pilots.faceOf(0);
    try std.testing.expectEqualStrings("pilots\\45TigersWL_Bandit_d.fm8", filmPath(&buffer, bandit, .dying));
    try std.testing.expectEqualStrings(hudmovie.static_film, filmPath(&buffer, bandit, @enumFromInt(4)));
    try std.testing.expectEqualStrings(hudmovie.static_film, filmPath(&buffer, null, .talking));
}

test readLine {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try hog.testing.write(gpa, io, tmp.dir, "speech.hog", &.{
        .{ .name = "ABRT_001", .data = "the game's line" },
        .{ .name = "ABRT_002", .data = "the game's other line" },
    });
    try tmp.dir.createDirPath(io, "mods/voices");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/voices/abrt_001", .data = "a mod's line" });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    var archive: hog.Archive = try .open(gpa, io, tmp.dir, "speech.hog");
    defer archive.close(gpa);

    // A mod's line, by the name the archive uses, and then a line from the archive.
    const modded = readLine(gpa, &mods, archive, "ms_speech\\ABRT_001.ut").?;
    defer gpa.free(modded);
    try std.testing.expectEqualStrings("a mod's line", modded);
    const own = readLine(gpa, &mods, archive, "ABRT_002.ut").?;
    defer gpa.free(own);
    try std.testing.expectEqualStrings("the game's other line", own);
    // Without the archive, only the mods' lines.
    const alone = readLine(gpa, &mods, null, "ABRT_001.ut").?;
    defer gpa.free(alone);
    try std.testing.expectEqualStrings("a mod's line", alone);
    try std.testing.expectEqual(null, readLine(gpa, &mods, null, "ABRT_002.ut"));
}

test lineName {
    try std.testing.expectEqualStrings("ms1_ban_001", lineName("ms1_ban_001.ut"));
    try std.testing.expectEqualStrings("trnglnd_001", lineName("speech\\trnglnd_001.UT"));
    try std.testing.expectEqualStrings("plck_001.wav", lineName("plck_001.wav"));
    try std.testing.expectEqualStrings("abrt_001", lineName("abrt_001"));
}

test "PERMISSION TO LAND's answers wait their time, then the radio says them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var archives: testing.Archives = undefined;
    try archives.init(gpa, io, &.{ "MPHUD_012", "FPHUD_012" }, &.{.{ .name = "static.fm8", .frames = 1, .colour = 0x80 }});
    defer archives.deinit();
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 1000 });
    var radio = archives.radio(gpa, io);
    var speaker: hog_snd.testing.Speaker = undefined;
    try speaker.init(2, null);
    const sound = &speaker.sound;
    defer sound.shutdown();
    defer radio.deinit(sound);
    var variables: vm.Variables = .{ .landing_cleared = 1, .mission_success = .success };
    var world = mission.world();
    world.variables = &variables;
    world.radio = &radio;
    world.hearing = speaker.hearing(&mission.clock);
    mission.player.carrier = reliant;

    // The pilot asks at once, and the Reliant's bridge answers in its time, clearing the ship by one
    // of the lines for a success.
    permissionToLand(world, 100);
    try std.testing.expect(radio.speaking(sound));
    const report = radio.reports[0].?;
    try std.testing.expectEqual(reliant_bridge, report.object);
    try std.testing.expectEqual(bridge_name, report.name);
    try std.testing.expectEqual(100 + report_delay, report.due);
    try std.testing.expectEqualStrings("pilots\\Rel_Brdge_Off.fm8", report.film.slice());
    try std.testing.expect(std.mem.startsWith(u8, report.speech.slice(), "rel_lnd_00"));
    try std.testing.expectEqual(.land, mission.slot(player).current().?.order);
    var windows: Windows = .{};
    const ctx: Context = .{ .sound = sound, .windows = &windows, .all = mission.objects, .frame_start = 0 };
    radio.stepReports(ctx, 100 + report_delay);
    try std.testing.expectEqual(0, radio.count);
    radio.stepReports(ctx, 101 + report_delay);
    try std.testing.expectEqual(null, radio.reports[0]);
    try std.testing.expectEqual(1, radio.count);
    try std.testing.expectEqual(reliant_bridge, radio.queue[radio.read].object);
    try std.testing.expectEqual(bridge_name, radio.queue[radio.read].name.?);

    // Not cleared, it refuses; and with the reports all taken, nothing answers and nothing lands.
    radio.reset(sound);
    mission.slot(player).object.order_count = 0;
    variables.landing_cleared = 0;
    permissionToLand(world, 1000);
    try std.testing.expect(std.mem.startsWith(u8, radio.reports[0].?.speech.slice(), "rel_lnd_den_0"));
    try std.testing.expectEqual(0, mission.slot(player).object.order_count);
    variables.landing_cleared = 1;
    for (&radio.reports) |*held| held.* = radio.reports[0];
    permissionToLand(world, 2000);
    try std.testing.expectEqual(0, mission.slot(player).object.order_count);
    try std.testing.expectEqual(null, radio.freeReport());

    // In training, the flight instructor answers.
    radio.reset(sound);
    mission.objects.mission_number = create.training_missions[0];
    mission.player.female = true;
    permissionToLand(world, 3000);
    try std.testing.expect(radio.speaking(sound));
    try std.testing.expectEqual(instructor, radio.reports[0].?.object);
    try std.testing.expectEqualStrings("pilots\\VirtFlt_Ins.fm8", radio.reports[0].?.film.slice());
    try std.testing.expectEqualStrings(instructor_line, radio.reports[0].?.speech.slice());
}

test permissionToLand {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var variables: @import("../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 1000 });
    const slot = mission.slot(player);

    // Not yet cleared, the ship lands on nothing, and the key goes unheard for a while.
    mission.player.carrier = reliant;
    permissionToLand(world, 100);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(100 + permission_every, mission.player.permission_heard_from);
    // Cleared, it is heard again only once the while is up, and the ship lands on its carrier.
    variables.landing_cleared = 1;
    permissionToLand(world, 100 + permission_every - 1);
    try std.testing.expectEqual(0, slot.object.order_count);
    permissionToLand(world, 100 + permission_every);
    try std.testing.expectEqual(.land, slot.current().?.order);
    try std.testing.expectEqual(reliant, slot.current().?.target.slotIn(mission.objects).?);

    // A ship that launched from no carrier lands on nothing.
    slot.object.order_count = 0;
    mission.player.carrier = null;
    permissionToLand(world, 10000);
    try std.testing.expectEqual(0, slot.object.order_count);
}

/// What the tests of the radio's users share.
pub const testing = struct {
    /// The radio's archives, in a directory of their own: a line of silence under each name of
    /// `lines` in `speech.hog`, as the game's archive holds them, without extensions, and `films`
    /// in `pilots.hog`.
    pub const Archives = struct {
        tmp: std.testing.TmpDir,

        pub fn init(archives: *Archives, gpa: Allocator, io: Io, lines: []const []const u8, films: []const hudmovie.testing.Film) !void {
            archives.tmp = std.testing.tmpDir(.{});
            errdefer archives.tmp.cleanup();
            const silence = try cbox.testFile(gpa, 4410, 200);
            defer gpa.free(silence);
            const members = try gpa.alloc(hog.Member, lines.len);
            defer gpa.free(members);
            for (members, lines) |*member, name| member.* = .{ .name = name, .data = silence };
            try hog.testing.write(gpa, io, archives.tmp.dir, "speech.hog", members);
            try hudmovie.testing.write(gpa, io, archives.tmp.dir, "pilots.hog", films);
        }

        /// The radio on them (`Radio.openAt`).
        pub fn radio(archives: *const Archives, gpa: Allocator, io: Io) Radio {
            return .openAt(gpa, io, archives.tmp.dir, "speech.hog", "pilots.hog");
        }

        pub fn deinit(archives: *Archives) void {
            archives.tmp.cleanup();
        }
    };

    /// A world heard through a radio, in mission 1: the player's ship, a fighter of the player's
    /// wing flown by Bandit, and an enemy fighter whose pilot speaks in the Russian voice.
    pub const Heard = struct {
        archives: Archives,
        mission: gameobj.testing.Mission,
        speaker: hog_snd.testing.Speaker,
        radio: Radio,
        variables: vm.Variables,
        wingman: u16,
        enemy: u16,

        /// Bandit, the pilot of the wingman and of the enemy, whose voice is the Russian one.
        pub const bandit = 0;

        pub fn init(heard: *Heard) !void {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            // A line of Moose's, and the pilot's own asking the wingmen.
            try heard.archives.init(gpa, io, &.{ "PLCK_001", "MPHUD_001", "MPHUD_002", "MPHUD_003" }, &.{.{ .name = "static.fm8", .frames = 1, .colour = 0x80 }});
            errdefer heard.archives.deinit();
            const mission = &heard.mission;
            try mission.init(gpa);
            errdefer mission.deinit();
            mission.objects.mission_number = 1;
            mission.tables.combat[@intFromEnum(gameobj.Type.predator)].class = .fighter;
            _ = try mission.add(.predator, @splat(0));
            heard.wingman = try mission.add(.predator, .{ 0, 0, 1000 });
            heard.enemy = try mission.add(.predator, .{ 0, 0, 2000 });
            for ([_]u16{ heard.wingman, heard.enemy }) |ship| mission.slot(ship).object.pilot = bandit;
            mission.slot(heard.wingman).object.wing = .player;
            mission.slot(heard.enemy).object.side = .hostile;
            try heard.speaker.init(2, null);
            heard.radio = heard.archives.radio(gpa, io);
            heard.variables = .{};
        }

        /// `init`, with the player's ship first in the player's wing and the wingman second, and
        /// the player's ship targeting the enemy under its controls.
        pub fn initWing(heard: *Heard) !gameobj.World {
            try heard.init();
            errdefer heard.deinit();
            const all = heard.mission.objects;
            all.wing[0] = 0;
            all.wing[1] = heard.wingman;
            all.slots[heard.enemy].object.flags.targetable = true;
            _ = try aigeneric.pushShip(heard.mission.orders(), 0, .player_control, heard.enemy, null);
            return heard.world();
        }

        pub fn deinit(heard: *Heard) void {
            heard.radio.deinit(&heard.speaker.sound);
            heard.speaker.sound.shutdown();
            heard.mission.deinit();
            heard.archives.deinit();
        }

        pub fn world(heard: *Heard) gameobj.World {
            var seen = heard.mission.world();
            seen.radio = &heard.radio;
            seen.hearing = heard.speaker.hearing(&heard.mission.clock);
            seen.variables = &heard.variables;
            return seen;
        }

        /// The line `back` places behind the next to be said.
        pub fn queued(heard: *const Heard, back: usize) *const Queued {
            return &heard.radio.queue[(heard.radio.read + back) % queue_size];
        }

        /// Whether the line `back` places behind the next is `speaker`'s, and one of `lines`, as it
        /// starts: the suffix a ship's pilot's voice ends.
        pub fn expectLine(heard: *const Heard, back: usize, speaker: i32, lines: []const []const u8) !void {
            const line = heard.queued(back);
            try std.testing.expectEqual(speaker, line.object);
            const speech = line.speech.slice();
            for (lines) |suffix| {
                if (std.mem.endsWith(u8, speech, suffix)) return;
            }
            std.debug.print("{s} is none of the lines\n", .{speech});
            return error.TestUnexpectedResult;
        }
    };
};

test shipLine {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ship = try mission.add(.predator, @splat(0));
    const object = &mission.slot(ship).object;
    var buffer: [ship_line_size]u8 = undefined;

    // A friendly ship's pilot speaks in its voice for the friendly side: Bandit's, and Moose none.
    object.pilot = 0;
    try std.testing.expectEqualStrings("banres_001.ut", shipLine(&buffer, mission.objects, ship, "res_001.ut").?);
    object.pilot = tigers_moose;
    try std.testing.expectEqual(null, shipLine(&buffer, mission.objects, ship, "res_001.ut"));
    // A hostile ship's pilot speaks in the Russian voice, but a pilot the game gives none.
    object.side = .hostile;
    object.pilot = 0;
    try std.testing.expectEqualStrings("rustnt_001.ut", shipLine(&buffer, mission.objects, ship, "tnt_001.ut").?);
    object.pilot = 21;
    try std.testing.expectEqual(pilots.Voice.prefix(@enumFromInt(4)), null);
    try std.testing.expectEqual(null, shipLine(&buffer, mission.objects, ship, "tnt_001.ut"));
    // Any other side's has no line, nor a pilot past the table.
    object.side = .neutral;
    object.pilot = 0;
    try std.testing.expectEqual(null, shipLine(&buffer, mission.objects, ship, "tnt_001.ut"));
    object.side = .friendly;
    object.pilot = pilots.faces.len;
    try std.testing.expectEqual(null, shipLine(&buffer, mission.objects, ship, "tnt_001.ut"));
}

test "the missile warning and the landing reminder" {
    var heard: testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    const world = heard.world();
    const clock = &heard.mission.clock;
    const radio = &heard.radio;
    const moose_line = pilot_base + volunteers_moose;

    // A missile homing on the player's ship has Moose warn the pilot, at most once a while, and
    // never once the pilot has ejected.
    const player = heard.mission.slot(0);
    player.object.missile_homing = 1;
    clock.frame_start = 10;
    remarksFrame(world);
    try std.testing.expectEqual(1, radio.count);
    try heard.expectLine(0, moose_line, &missile_warnings);
    try std.testing.expectEqual(10 + missile_expiry, heard.queued(0).expiry.?);
    radio.reset(&heard.speaker.sound);
    clock.frame_start = 10 + missile_wait;
    remarksFrame(world);
    try std.testing.expectEqual(0, radio.count);
    clock.frame_start += 1;
    player.object.flags.ejected = true;
    remarksFrame(world);
    try std.testing.expectEqual(0, radio.count);
    player.object.missile_homing = 0;

    // Once the ship is cleared to land, Moose reminds the pilot to ask, a while on and a while
    // after; unless the script has the remarks unsaid.
    heard.variables.landing_cleared = 1;
    clock.frame_start = 100;
    remarksFrame(world);
    try std.testing.expect(heard.mission.player.remarks.landing_reminded);
    try std.testing.expectEqual(0, radio.count);
    clock.frame_start = 100 + landing_wait + 1;
    remarksFrame(world);
    try std.testing.expectEqual(1, radio.count);
    try heard.expectLine(0, moose_line, &landing_reminders);
    heard.mission.player.remarks.generic_comms_disabled = true;
    clock.frame_start += landing_wait + 1;
    remarksFrame(world);
    try std.testing.expectEqual(1, radio.count);
    try std.testing.expectEqual(clock.frame_start + landing_wait, heard.mission.player.remarks.landing_next);
    // Cleared no more, the reminder is over.
    heard.variables.landing_cleared = 0;
    remarksFrame(world);
    try std.testing.expect(!heard.mission.player.remarks.landing_reminded);

    // In training, the flight instructor reminds the pilot once, whatever the script has unsaid.
    radio.reset(&heard.speaker.sound);
    heard.mission.objects.mission_number = create.training_missions[0];
    heard.variables.landing_cleared = 1;
    remarksFrame(world);
    try std.testing.expectEqual(1, radio.count);
    try std.testing.expectEqual(instructor, heard.queued(0).object);
    try std.testing.expectEqualStrings(training_landing_reminder, heard.queued(0).speech.slice());
    clock.frame_start += 2 * landing_wait;
    remarksFrame(world);
    try std.testing.expectEqual(1, radio.count);
}

test "the jump reminder calls the pilot to jump, then jumps" {
    const gpa = std.testing.allocator;
    var heard: testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    var fixture: vm.machine.testing.Fixture = undefined;
    try fixture.init(gpa, &.{}, .{});
    defer fixture.deinit();
    var queue: events.Events = .init(gpa, &fixture.machine);
    defer queue.deinit();
    var world = heard.world();
    world.events = &queue;
    world.variables = &fixture.machine.variables;
    const clock = &heard.mission.clock;
    const radio = &heard.radio;
    const moose_line = pilot_base + volunteers_moose;
    const remarks = &heard.mission.player.remarks;

    // A jump ready, Moose says so, and calls the pilot to jump four times, a while apart.
    fixture.machine.variables.ready.jump = .newly;
    remarksFrame(world);
    try heard.expectLine(0, moose_line, &jump_lines);
    for (jump_call_lines, 0..) |lines, call| {
        radio.reset(&heard.speaker.sound);
        clock.game_ticks = @intCast(jump_wait * (call + 1) - 1);
        remarksFrame(world);
        try std.testing.expectEqual(0, radio.count);
        clock.game_ticks += 1;
        remarksFrame(world);
        try heard.expectLine(0, moose_line, &lines);
    }
    // A moment after the last, the player's ship jumps, which ends the reminder.
    clock.game_ticks += jump_last_wait - 1;
    remarksFrame(world);
    try std.testing.expectEqual(.newly, fixture.machine.variables.ready.jump);
    clock.game_ticks += 1;
    remarksFrame(world);
    try std.testing.expectEqual(.no, fixture.machine.variables.ready.jump);
    try std.testing.expect(!remarks.jump_reminded);

    // A warp's words are a warp's; and in training, the flight instructor's, and no call follows.
    radio.reset(&heard.speaker.sound);
    fixture.machine.variables.ready.warp = .newly;
    remarksFrame(world);
    try heard.expectLine(0, moose_line, &warp_lines);
    radio.reset(&heard.speaker.sound);
    remarks.jump_reminded = false;
    heard.mission.objects.mission_number = create.training_missions[0];
    remarksFrame(world);
    try std.testing.expectEqualStrings(training_jump_line, heard.queued(0).speech.slice());
    clock.game_ticks += 10 * jump_wait;
    remarksFrame(world);
    try std.testing.expectEqual(1, radio.count);
}

test "a kill, a loss, an ejection, a taunt and a launch have their words" {
    var heard: testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    const world = heard.world();
    const clock = &heard.mission.clock;
    const radio = &heard.radio;
    const sound = &heard.speaker.sound;
    const moose_line = pilot_base + volunteers_moose;
    const remarks = &heard.mission.player.remarks;
    const enemy = heard.enemy;
    const wingman = heard.wingman;

    // A fighter's kill: its pilot's last words, in its voice, and Moose's; then none for a while.
    clock.game_ticks = 1000;
    killRemark(world, enemy);
    try std.testing.expectEqual(2, radio.count);
    try heard.expectLine(0, enemy, &last_words);
    try std.testing.expect(std.mem.startsWith(u8, heard.queued(0).speech.slice(), "rusdth_00"));
    try std.testing.expectEqual(hudmovie.Flags.once, heard.queued(0).flags);
    try heard.expectLine(1, moose_line, &fighter_kill_lines);
    radio.reset(sound);
    clock.game_ticks += kill_wait;
    killRemark(world, enemy);
    try std.testing.expectEqual(0, radio.count);
    // A torpedo's has Moose's words alone; a pilot's pod has Moose's at any time.
    heard.mission.tables.combat[@intFromEnum(gameobj.Type.predator)].class = .torpedo;
    clock.game_ticks += 1;
    killRemark(world, enemy);
    try heard.expectLine(0, moose_line, &torpedo_kill_lines);
    radio.reset(sound);
    heard.mission.slot(enemy).object.flags.ejected = true;
    killRemark(world, enemy);
    try heard.expectLine(0, moose_line, &pod_kill_lines);
    heard.mission.slot(enemy).object.flags.ejected = false;

    // A wingman lost: its pilot's last words, and Moose's.
    radio.reset(sound);
    shipLost(world, wingman);
    try std.testing.expectEqualStrings("bandth_001.ut", heard.queued(0).speech.slice());
    try heard.expectLine(1, moose_line, &lost_lines);

    // A wingman's pilot ejecting says so, and a while later the wingman in the wing's last place
    // says the rescue's words; there being none, nothing is said.
    radio.reset(sound);
    clock.frame_start = 100;
    wingmanEjected(world, wingman);
    try std.testing.expectEqualStrings("banejt_001.ut", heard.queued(0).speech.slice());
    radio.reset(sound);
    clock.frame_start = 100 + rescue_wait;
    remarksFrame(world);
    try std.testing.expectEqual(wingman, remarks.ejected.?);
    heard.mission.objects.wing[rescuer_place] = wingman;
    clock.frame_start += 1;
    remarksFrame(world);
    try std.testing.expectEqual(null, remarks.ejected);
    try heard.expectLine(0, pilot_base + testing.Heard.bandit, &rescue_lines);
    try std.testing.expect(std.mem.startsWith(u8, heard.queued(0).speech.slice(), "banres_00"));
    radio.reset(sound);
    wingmanEjected(world, wingman);
    heard.mission.objects.wing[rescuer_place] = null;
    radio.reset(sound);
    clock.frame_start += rescue_wait + 1;
    remarksFrame(world);
    try std.testing.expectEqual(null, remarks.ejected);
    try std.testing.expectEqual(0, radio.count);

    // An enemy's hit taunts the pilot, at most once a while, and never once the script has the
    // taunts unsaid.
    enemyTaunt(world, enemy);
    try heard.expectLine(0, enemy, &taunts);
    try std.testing.expect(std.mem.startsWith(u8, heard.queued(0).speech.slice(), "rustnt_0"));
    radio.reset(sound);
    clock.frame_start += taunt_wait;
    enemyTaunt(world, enemy);
    try std.testing.expectEqual(0, radio.count);
    remarks.taunts_disabled = true;
    clock.frame_start += 1;
    enemyTaunt(world, enemy);
    try std.testing.expectEqual(0, radio.count);
    try std.testing.expectEqual(clock.frame_start + taunt_wait, remarks.taunt_next);

    // A launch from the Reliant has its bridge officer's words; from anything else, none.
    const reliant = try heard.mission.add(.reliant, .{ 0, 0, 5000 });
    launchLine(world, reliant);
    try heard.expectLine(0, reliant_bridge, &reliant_launch_lines);
    radio.reset(sound);
    launchLine(world, enemy);
    try std.testing.expectEqual(0, radio.count);

    // The script's switch leaves them all unsaid.
    remarks.generic_comms_disabled = true;
    launchLine(world, reliant);
    shipLost(world, wingman);
    wingmanEjected(world, wingman);
    clock.game_ticks += kill_wait + 1;
    killRemark(world, enemy);
    try std.testing.expectEqual(0, radio.count);
}
