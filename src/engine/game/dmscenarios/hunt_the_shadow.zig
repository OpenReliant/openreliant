//! Hunt the Shadow (dm_scenarios record 0x0050C890). The host owns the role and its score.
const std = @import("std");
const cloak = @import("../cloak.zig");
const create = @import("../create.zig");
const deathmatch = @import("../deathmatch.zig");
const gameobj = @import("../gameobj.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const players = @import("../players.zig");

/// The Shadow's killer gets this bonus (0x004B4A75) in addition to the normal frag (0x004085A2).
const bonus_frags = 5;

pub const Round = struct {
    owner: ?players.ParticipantRef = null,

    /// shadow_pilot_destroyed (0x004B4920) gives the role to the first killer, then to each
    /// pilot who kills the Shadow. A crash or other death without a credited killer clears it.
    pub fn destroyed(round: *Round, world: gameobj.World, index: u16) void {
        const all = world.objects;
        const victim = all.playerBinding(index) orelse return;
        const slot = &all.slots[index];
        const killer = if (slot.attackerBinding(all)) |by|
            if (by.participant.slot != index) by.participant else null
        else
            null;
        const former = round.owner orelse {
            if (killer) |pilot| round.assign(world, pilot, null);
            return;
        };
        if (std.meta.eql(former, victim.participant)) {
            if (killer) |pilot| {
                round.assign(world, pilot, former);
            } else {
                round.owner = null;
            }
        } else if (std.meta.eql(round.owner, killer)) {
            // shadow_killed_pilot (0x004B4B30) clears ordinary credit and awards one frag.
            slot.setAttacker(null);
            _ = deathmatch.awardArenaKills(all, former, 1);
            Notice.post(world, .killed, former, victim.participant);
        }
    }

    /// shadow_pilot_left (0x004B49D0) clears the role when its pilot leaves.
    pub fn leave(round: *Round, pilot: players.ParticipantRef) void {
        if (std.meta.eql(round.owner, @as(?players.ParticipantRef, pilot))) round.owner = null;
    }

    /// shadow_assign (0x004B49F0) restores the old Shadow's targeting flag, then cloaks the next
    /// Shadow and clears their shields. Normal destruction still credits the kill.
    fn assign(round: *Round, world: gameobj.World, next: players.ParticipantRef, former: ?players.ParticipantRef) void {
        if (former) |pilot| {
            _ = deathmatch.awardArenaKills(world.objects, next, bonus_frags);
            world.objects.slots[pilot.slot].object.flags.targetable = true;
        }
        round.owner = next;
        cloakShip(world, next.slot);
        Notice.post(world, if (former != null) .transferred else .claimed, next, former);
    }
};

pub fn cloakShip(world: gameobj.World, index: u16) void {
    const all = world.objects;
    const object = &all.slots[index].object;
    object.shields = .all(0);
    object.flags.targetable = false;
    all.player_states[index].shield_reserves = .{};
    cloak.beginPowerUp(world, index);
}

/// The host uses this ship's admission for shield recharge (0x00476FFF) and random pickups
/// (mp_can_take_powerup, 0x004B2DC0).
pub fn isShadow(all: *const create.Objects, index: u16) bool {
    if (all.arena_scenario != .hunt_the_shadow) return false;
    const owner = all.arena_scenario.hunt_the_shadow.shadow.owner orelse return false;
    if (owner.slot != index) return false;
    const pilot = all.playerBinding(index) orelse return false;
    return pilot.participant.generation == owner.generation;
}

pub const Notice = struct {
    kind: Kind,
    pilot: players.ParticipantRef,
    other: ?players.ParticipantRef,
    tick: i32,

    pub const Kind = enum(u8) { claimed, transferred, killed };
    pub const Sink = struct {
        context: *anyopaque,
        send: *const fn (*anyopaque, Notice) void,
    };

    fn post(world: gameobj.World, kind: Kind, pilot: players.ParticipantRef, other: ?players.ParticipantRef) void {
        if (world.shadow_notices) |sink|
            sink.send(sink.context, .{ .kind = kind, .pilot = pilot, .other = other, .tick = world.clock.frame_start });
    }

    pub fn present(notice: Notice, messages: *hud.Messages, strings: language.Language, viewer: players.ParticipantRef, name: []const u8, other: []const u8) void {
        const scorer = std.meta.eql(notice.pilot, viewer);
        switch (notice.kind) {
            .claimed => {},
            .transferred => {
                const bonus = if (scorer) strings.string(0x2F3) orelse "(+5)" else "";
                deathmatch.addMessage(messages, notice.tick, strings.string(0x2E7) orelse "%s killed Shadow %s %s", &.{ name, other, bonus });
            },
            .killed => {
                const bonus = if (scorer) strings.string(0x2F4) orelse "(+1)" else "";
                deathmatch.addMessage(messages, notice.tick, strings.string(0x2E6) orelse "%s the Shadow killed %s %s", &.{ name, other, bonus });
                return;
            },
        }
        announce(messages, strings, notice.tick, name);
    }
};

/// shadow_init (0x004B48C0) announces the role on entry or resync.
pub fn announce(messages: *hud.Messages, strings: language.Language, tick: i32, name: ?[]const u8) void {
    if (name) |pilot| {
        deathmatch.addMessage(messages, tick, strings.string(0x2DD) orelse "%s is the new Shadow", &.{pilot});
    } else {
        messages.add(strings.string(0x2E5) orelse "No-one is the Shadow", tick);
    }
}

/// shadow_draw_hud (0x004B4BE0) places shape 13 at the common arena objective anchor.
pub fn drawBadge(pen: hud.Pen, icons: *hud.Art) hud.Error!void {
    try pen.drawing(.{ .art = icons, .gpa = pen.gpa }).partShape(.shadow_badge_icon, 13, pen.placed(.{ -25, 0 }, 0.5, 0));
}

test "the host assigns, scores and clears the Shadow role by admission" {
    const aiexplode = @import("../aiexplode.zig");
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const falcon = try mission.add(.of(.predator), @splat(0));
    const viper = try mission.add(.of(.predator), .{ 0, 0, 1500 });
    const rook = try mission.add(.of(.predator), .{ 0, 0, -1500 });
    all.players = 3;
    for ([_]u16{ falcon, viper, rook }) |index| {
        const pilot = all.joinParticipant(index).?;
        _ = all.bindParticipant(pilot, .of(all, index)).?;
    }
    all.arena_scenario = .{ .hunt_the_shadow = .{ .powerups = try .start(all) } };
    const round = &all.arena_scenario.hunt_the_shadow.shadow;
    var world = mission.world();
    world.damage_rules = .{ .arena = null };
    const first = all.playerBinding(falcon).?.participant;
    const second = all.playerBinding(viper).?.participant;
    const falcon_shot: gameobj.DamageSource = .of(all, falcon);
    const viper_shot: gameobj.DamageSource = .of(all, viper);
    all.player_states[falcon].shield_reserves.fore = 3;

    mission.slot(viper).setAttacker(falcon_shot);
    round.destroyed(world, viper);
    aiexplode.killCredit(world, viper);
    try std.testing.expectEqual(first, round.owner.?);
    try std.testing.expectEqual(1, all.player_states[falcon].membership.joined.kills.count);
    try std.testing.expect(mission.slot(falcon).object.flags.cloaked);
    try std.testing.expect(!mission.slot(falcon).object.flags.targetable);
    try std.testing.expectEqual(0, mission.slot(falcon).object.shields.fore);
    try std.testing.expectEqual(0, all.player_states[falcon].shield_reserves.fore);

    mission.slot(rook).setAttacker(falcon_shot);
    round.destroyed(world, rook);
    aiexplode.killCredit(world, rook);
    try std.testing.expectEqual(first, round.owner.?);
    try std.testing.expectEqual(2, all.player_states[falcon].membership.joined.kills.count);
    try std.testing.expectEqual(null, mission.slot(rook).attackerBinding(all));

    mission.slot(falcon).setAttacker(viper_shot);
    round.destroyed(world, falcon);
    aiexplode.killCredit(world, falcon);
    try std.testing.expectEqual(second, round.owner.?);
    try std.testing.expectEqual(6, all.player_states[viper].membership.joined.kills.count);
    try std.testing.expect(mission.slot(falcon).object.flags.targetable);

    mission.slot(viper).setAttacker(null);
    round.destroyed(world, viper);
    try std.testing.expectEqual(null, round.owner);
    round.assign(world, second, null);
    try std.testing.expect(create.Objects.leaveParticipant(world, second));
    try std.testing.expectEqual(null, round.owner);
    const replacement = all.joinParticipant(viper).?;
    _ = all.bindParticipant(replacement, .of(all, viper)).?;
    round.assign(world, replacement, null);
    round.leave(second);
    try std.testing.expectEqual(replacement, round.owner.?);
}
