//! The wingmen's commands (`0x00454B80` to `0x00455720`): ATTACK MY TARGET, BACK OFF and HELP ME,
//! which the player gives by their keys (`input.frameKeys`) or the radio's menu (`give`).
//! **Unverified:** the code lies among the radio's, as PERMISSION TO LAND's does.
//!
//! The radio's menu (`videoreports.menu`) names the wingman, or the whole wing.
//!
//! Not ported: the command sent to another player of a multiplayer game (`0x004BA040`,
//! `0x004BA080`, `0x004BA0C0`) ([#55](https://github.com/vdmkenny/openreliant/issues/55)).

const std = @import("std");

const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const math = @import("../../surrender/math.zig");
const mission = @import("../mission.zig");
const pilots = @import("../pilots.zig");
const videoreports = @import("../videoreports.zig");

/// A command to the wingmen.
pub const Command = enum {
    /// `0x00454C20`: fight the player's target.
    attack_my_target,
    /// `0x00454FA0`: stop fighting the player's target, and leave it be a while.
    back_off,
    /// `0x00455330`: fight the ships fighting the player.
    help_me,

    /// The pilot's own line asking it (`0x004F0E68`, `0x004F0E74`, `0x004F0E80`).
    fn request(command: Command) []const u8 {
        return switch (command) {
            .attack_my_target => "hud_001.ut",
            .back_off => "hud_002.ut",
            .help_me => "hud_003.ut",
        };
    }
};

/// A wingman's replies to a command: as it cannot now, and as it does it.
const Replies = struct {
    busy: []const []const u8,
    done: []const []const u8,
};

/// The ends of the wingmen's replies, the pilot's voice before them (`videoreports.shipLine`), by
/// the command, from the set of replies most pilots have and from the fuller one
/// (`pilots.Face.full_replies`): ATTACK MY TARGET's (`0x004EF3A0`, `0x004EF3B0`; `0x004EF370`,
/// `0x004EF380`), BACK OFF's (`0x004EF434`, `0x004EF444`; `0x004EF3CC`, `0x004EF3E4`) and HELP
/// ME's (`0x004EF4CC`, `0x004EF4DC`; `0x004EF464`, `0x004EF47C`).
const replies = struct {
    const numbered = videoreports.numbered;
    const most = std.EnumArray(Command, Replies).init(.{
        .attack_my_target = .{ .busy = &numbered("_amt_", 1, 4), .done = &numbered("_amt_", 5, 8) },
        .back_off = .{ .busy = &numbered("_bkoff_", 1, 4), .done = &numbered("_bkoff_", 5, 9) },
        .help_me = .{ .busy = &numbered("_hlpme_", 1, 4), .done = &numbered("_hlpme_", 5, 8) },
    });
    const full = std.EnumArray(Command, Replies).init(.{
        .attack_my_target = .{ .busy = &numbered("_amt_", 5, 8), .done = &numbered("_amt_", 9, 13) },
        .back_off = .{ .busy = &numbered("_bkoff_", 1, 6), .done = &numbered("_bkoff_", 7, 15) },
        .help_me = .{ .busy = &numbered("_hlpme_", 1, 6), .done = &numbered("_hlpme_", 7, 14) },
    });
};

/// Who a command goes to (`0x00529596`): a wingman the game picks, or the wingman in a slot, as the
/// radio's menu names one.
pub const Addressee = union(enum) {
    picked,
    wingman: u16,
};

/// How a wingman stands to a command.
const Standing = enum {
    /// It takes it.
    free,
    /// It cannot now: it is not to be disturbed (`gameobj.GameObject.Flags.do_not_disturb`), or,
    /// for a command but BACK OFF, its current order has a priority (`ai.Record.priority`).
    busy,
    /// It has it in hand already.
    done,
};

/// What a command is about: the player's target, or HELP ME's attackers.
const Aim = struct {
    target: aigeneric.Target = .none,
    attackers: []const u16 = &.{},
};

/// How long a wingman that backs off leaves the player's target be, in the game's ticks
/// (`0x00455191`).
const back_off_ticks = 3000;

/// The most attackers HELP ME finds, one for each object.
const most_attackers = gameobj.max_objects;

/// `command`, given to the wingman `to` names. The pilot asks on the radio
/// (`videoreports.playerSays`). ATTACK MY TARGET and BACK OFF are about the player's target
/// (`ai.playerControlEntry`), which they need; HELP ME about its attackers (`attackers`), which it
/// needs too. A wingman free to (`standing`), which the game picks where none is named
/// (`pick`), takes it: it fights the player's target; it stops (`aigeneric.pop`) and leaves the
/// player's target be for `back_off_ticks` (`gameobj.GameObject.set_aside`); or it fights one of
/// the attackers at random. It says so `videoreports.report_delay` ticks later
/// (`videoreports.reportShip`). A wingman named that cannot now says so; one that has it in hand
/// already says it does it, a wingman told to back off leaving the target be all the same.
pub fn give(world: gameobj.World, command: Command, to: Addressee) void {
    videoreports.playerSays(world, command.request());
    const all = world.objects;
    var found: [most_attackers]u16 = undefined;
    const aim: Aim = switch (command) {
        .attack_my_target, .back_off => .{ .target = (ai.playerControlEntry(all) orelse return).target },
        .help_me => .{ .attackers = attackers(all, &found) orelse return },
    };
    const wingman = switch (to) {
        .picked => pick(world, command, aim) orelse return,
        .wingman => |slot| switch (standing(all, command, slot, aim)) {
            .free => slot,
            .busy => return answer(world, slot, command, .busy),
            .done => {
                if (command == .back_off) setAside(world, slot);
                return answer(world, slot, command, .done);
            },
        },
    };
    drawForNothing(world, wingman);
    const ctx: aigeneric.Context = .of(world);
    switch (command) {
        .attack_my_target => _ = aigeneric.give(ctx, wingman, .fight, aim.target),
        .back_off => {
            _ = aigeneric.pop(ctx, wingman);
            setAside(world, wingman);
        },
        .help_me => {
            const attacker = aim.attackers[world.random.rand() % aim.attackers.len];
            _ = aigeneric.giveShip(ctx, wingman, .fight, attacker, null);
        },
    }
    answer(world, wingman, command, .done);
}

/// The wingman in slot `wingman` leaves the player's current target be for `back_off_ticks`.
fn setAside(world: gameobj.World, wingman: u16) void {
    const all = world.objects;
    const current = all.slots[all.player].current() orelse return;
    const object = &all.slots[wingman].object;
    object.set_aside = .from(std.math.cast(u16, current.target.index));
    object.set_aside_until = world.clock.game_ticks + back_off_ticks;
}

/// The wingman in slot `wingman`'s reply to `command`, as it cannot now or as it does it
/// (`fullReplies` picks the set).
fn answer(world: gameobj.World, wingman: u16, command: Command, reply: Standing) void {
    const said = (if (fullReplies(world.objects, wingman)) replies.full else replies.most).get(command);
    videoreports.reportShip(world, wingman, if (reply == .busy) said.busy else said.done);
}

/// `pilot_full_replies` (`0x004539A0`): whether the pilot of the ship in slot `index` answers from
/// the fuller set of replies (`pilots.Face.full_replies`); a pilot past the table does not.
pub fn fullReplies(all: *const create.Objects, index: u16) bool {
    const face = pilots.faceOf(all.slots[index].object.pilot) orelse return false;
    return face.full_replies;
}

/// What the game does before a wingman takes a command: for a pilot whose third value
/// (`pilots.Pilot.values`, `+0x20`) is 0, 1 or 2, it draws a number it does nothing with.
/// **Unknown:** what the value is.
fn drawForNothing(world: gameobj.World, wingman: u16) void {
    const all = world.objects;
    if (all.pilots.get(all.slots[wingman].object.pilot).values[2] <= 2) _ = world.random.rand();
}

/// The wingman the game picks for `command`, from the player's wing but the player, not exploding
/// and free to take it: for BACK OFF one at random; for the others one the likelier the farther it
/// is from the player's ship. Null for none.
fn pick(world: gameobj.World, command: Command, aim: Aim) ?u16 {
    const all = world.objects;
    var found: [mission.wing_size]u16 = undefined;
    var count: usize = 0;
    for (all.wing) |listed| {
        const slot = listed orelse continue;
        if (slot == all.player or all.slots[slot].object.flags.exploding) continue;
        if (standing(all, command, slot, aim) != .free) continue;
        found[count] = slot;
        count += 1;
    }
    const free = found[0..count];
    if (free.len == 0) return null;
    if (command == .back_off) return free[world.random.rand() % free.len];
    const player = all.slots[all.player].object.nextPosition();
    var reach: [mission.wing_size]f32 = undefined;
    var total: f32 = 0;
    for (free, reach[0..free.len]) |slot, *upto| {
        total += math.distance(all.slots[slot].object.nextPosition(), player);
        upto.* = total;
    }
    const fall = world.random.fraction() * total;
    for (free[0 .. free.len - 1], reach[0 .. free.len - 1]) |slot, upto| {
        if (upto > fall) return slot;
    }
    return free[free.len - 1];
}

/// How the wingman in slot `index` stands to `command` about `aim`: `0x00454B80` for ATTACK MY
/// TARGET, done where its current order aims at the player's target; `0x00454F40` for BACK OFF,
/// free where its current order is Fight aimed at it, and done otherwise; `0x00455280` for HELP
/// ME, done where its current order is Fight aimed at an attacker.
fn standing(all: *const create.Objects, command: Command, index: u16, aim: Aim) Standing {
    const slot = &all.slots[index];
    if (slot.object.flags.do_not_disturb) return .busy;
    const current = slot.current() orelse return if (command == .back_off) .done else .free;
    const target = current.target;
    return switch (command) {
        .attack_my_target => if (aigeneric.prioritised(current.order)) .busy else if (target.index == aim.target.index and target.component == aim.target.component) .done else .free,
        .back_off => if (target.index == aim.target.index and current.order == .fight) .free else .done,
        .help_me => if (aigeneric.prioritised(current.order)) .busy else if (current.order == .fight and std.mem.indexOfScalar(u16, aim.attackers, @bitCast(target.index)) != null) .done else .free,
    };
}

/// The player's target where it is a hostile ship that can be aimed at (`ai.targetValid`), as the
/// wingmen's keys need one (`frame_controls`, `0x0041457D`) and HELP ME takes one; or null.
pub fn hostileTarget(all: *create.Objects) ?u16 {
    const entry = ai.playerControlEntry(all) orelse return null;
    if (!ai.targetValid(all, entry.target, .{})) return null;
    const target = entry.target.slotIn(all) orelse return null;
    return if (all.slots[target].object.side == .hostile) target else null;
}

/// HELP ME's attackers, into `out`: each hostile ship that can be aimed at whose current order is
/// Fight aimed at the player's ship; with none, the player's hostile target (`hostileTarget`); or
/// null for neither.
fn attackers(all: *create.Objects, out: *[most_attackers]u16) ?[]const u16 {
    var count: usize = 0;
    for (all.slots[0..all.count], 0..) |*slot, index| {
        const current = slot.current() orelse continue;
        if (current.order != .fight or current.target.index != all.player) continue;
        const whole: aigeneric.Target = .at(@intCast(index), null);
        if (!ai.targetValid(all, whole, .{}) or slot.object.side != .hostile) continue;
        out[count] = @intCast(index);
        count += 1;
    }
    if (count > 0) return out[0..count];
    out[0] = hostileTarget(all) orelse return null;
    return out[0..1];
}

/// Whether the report waiting first is the wingman's, one of `lines` in Bandit's voice.
fn expectReply(heard: *const videoreports.testing.Heard, lines: []const []const u8) !void {
    const report = heard.radio.reports[0] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, heard.wingman), report.object);
    try std.testing.expectEqual(heard.mission.clock.game_ticks + videoreports.report_delay, report.due);
    const speech = report.speech.slice();
    try std.testing.expect(std.mem.startsWith(u8, speech, "ban_"));
    for (lines) |suffix| {
        if (std.mem.endsWith(u8, speech, suffix)) return;
    }
    return error.TestUnexpectedResult;
}

test hostileTarget {
    var heard: videoreports.testing.Heard = undefined;
    _ = try heard.initWing();
    defer heard.deinit();
    const all = heard.mission.objects;
    try std.testing.expectEqual(heard.enemy, hostileTarget(all).?);
    // A friend, or a target that cannot be aimed at, is none.
    all.slots[heard.enemy].object.side = .friendly;
    try std.testing.expectEqual(null, hostileTarget(all));
    all.slots[heard.enemy].object.side = .hostile;
    all.slots[heard.enemy].object.flags.cloaked = true;
    try std.testing.expectEqual(null, hostileTarget(all));
}

test "ATTACK MY TARGET" {
    var heard: videoreports.testing.Heard = undefined;
    const world = try heard.initWing();
    defer heard.deinit();
    const all = heard.mission.objects;
    const wingman = &all.slots[heard.wingman];

    // The wingman the game picks fights the player's target, and says so from its fuller set.
    give(world, .attack_my_target, .picked);
    try std.testing.expectEqual(.fight, wingman.current().?.order);
    try std.testing.expectEqual(heard.enemy, wingman.current().?.target.slotIn(all).?);
    try expectReply(&heard, replies.full.get(.attack_my_target).done);
    // Named again, it fights it already, and only says so.
    heard.radio.reset(&heard.speaker.sound);
    const orders = wingman.object.order_count;
    give(world, .attack_my_target, .{ .wingman = heard.wingman });
    try std.testing.expectEqual(orders, wingman.object.order_count);
    try expectReply(&heard, replies.full.get(.attack_my_target).done);
    // Not to be disturbed, it says it cannot; and the game picks none that are.
    heard.radio.reset(&heard.speaker.sound);
    wingman.object.flags.do_not_disturb = true;
    give(world, .attack_my_target, .{ .wingman = heard.wingman });
    try expectReply(&heard, replies.full.get(.attack_my_target).busy);
    heard.radio.reset(&heard.speaker.sound);
    give(world, .attack_my_target, .picked);
    try std.testing.expectEqual(null, heard.radio.reports[0]);
}

test "BACK OFF" {
    var heard: videoreports.testing.Heard = undefined;
    const world = try heard.initWing();
    defer heard.deinit();
    const all = heard.mission.objects;
    const wingman = &all.slots[heard.wingman];
    heard.mission.clock.game_ticks = 100;

    // A wingman fighting the player's target stops, leaves it be a while, and says so.
    _ = try aigeneric.pushShip(heard.mission.orders(), heard.wingman, .fight, heard.enemy, null);
    give(world, .back_off, .picked);
    try std.testing.expectEqual(0, wingman.object.order_count);
    try std.testing.expectEqual(heard.enemy, wingman.object.set_aside.index().?);
    try std.testing.expectEqual(100 + back_off_ticks, wingman.object.set_aside_until);
    try expectReply(&heard, replies.full.get(.back_off).done);
    // With none fighting it, the game picks nobody; one named leaves it be all the same.
    heard.radio.reset(&heard.speaker.sound);
    wingman.object.set_aside = .none;
    give(world, .back_off, .picked);
    try std.testing.expectEqual(null, heard.radio.reports[0]);
    give(world, .back_off, .{ .wingman = heard.wingman });
    try std.testing.expectEqual(heard.enemy, wingman.object.set_aside.index().?);
    try expectReply(&heard, replies.full.get(.back_off).done);
}

test "HELP ME" {
    var heard: videoreports.testing.Heard = undefined;
    const world = try heard.initWing();
    defer heard.deinit();
    const all = heard.mission.objects;
    const wingman = &all.slots[heard.wingman];

    // An enemy fighting the player's ship draws the wingman the game picks.
    const attacker = try heard.mission.add(.predator, .{ 0, 0, 3000 });
    all.slots[attacker].object.side = .hostile;
    all.slots[attacker].object.flags.targetable = true;
    _ = try aigeneric.pushShip(heard.mission.orders(), attacker, .fight, 0, null);
    give(world, .help_me, .picked);
    try std.testing.expectEqual(.fight, wingman.current().?.order);
    try std.testing.expectEqual(attacker, wingman.current().?.target.slotIn(all).?);
    try expectReply(&heard, replies.full.get(.help_me).done);
    // With no attacker, the player's hostile target is one; with neither, nothing is done.
    heard.radio.reset(&heard.speaker.sound);
    _ = aigeneric.pop(heard.mission.orders(), attacker);
    _ = aigeneric.pop(heard.mission.orders(), heard.wingman);
    give(world, .help_me, .picked);
    try std.testing.expectEqual(heard.enemy, wingman.current().?.target.slotIn(all).?);
    heard.radio.reset(&heard.speaker.sound);
    _ = aigeneric.pop(heard.mission.orders(), heard.wingman);
    all.slots[heard.enemy].object.side = .friendly;
    give(world, .help_me, .picked);
    try std.testing.expectEqual(0, wingman.object.order_count);
    try std.testing.expectEqual(null, heard.radio.reports[0]);
}

test replies {
    try std.testing.expectEqualStrings("_amt_009.ut", replies.full.get(.attack_my_target).done[0]);
    try std.testing.expectEqualStrings("_bkoff_015.ut", replies.full.get(.back_off).done[8]);
    try std.testing.expectEqual(4, replies.most.get(.help_me).busy.len);
}
