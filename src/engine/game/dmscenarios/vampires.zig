//! Vampires, the stock scenario at 0x0050C8D0. The host owns infection and its score.
const std = @import("std");
const create = @import("../create.zig");
const deathmatch = @import("../deathmatch.zig");
const gameobj = @import("../gameobj.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const players = @import("../players.zig");

/// The last human to die earns five frags (0x004B5173).
const last_human_bonus = @import("../dmscenarios.zig").Scenario.vampires.record().rules.vampires.last_human_bonus;

/// A snapshot's current vampire slots (vampires_write_state, 0x004B4D40).
pub const Roles = std.StaticBitSet(deathmatch.spawn.positions);

pub const Round = struct {
    /// Keep the role through respawns, and clear it when that admission leaves.
    infected: [deathmatch.spawn.positions]?u64 = @splat(null),

    const Population = struct {
        players: usize = 0,
        vampires: Roles = .empty,
    };

    fn has(round: *const Round, pilot: players.ParticipantRef) bool {
        return pilot.slot < round.infected.len and round.infected[pilot.slot] == pilot.generation;
    }

    fn population(round: *const Round, all: *const create.Objects) Population {
        var active: Population = .{};
        const count = @min(all.playerSlotCount(), round.infected.len);
        for (all.player_states[0..count], round.infected[0..count], 0..) |*state, generation, index| {
            if (state.membership != .joined) continue;
            active.players += 1;
            if (generation == state.membership.joined.generation) active.vampires.set(index);
        }
        return active;
    }

    pub fn roles(round: *const Round, all: *const create.Objects) Roles {
        return round.population(all).vampires;
    }

    /// vampires_pilot_destroyed (0x004B4DC0) infects the first pilot to die, then any human a
    /// vampire kills. The first death can have no killer. A lone pilot cannot start the round.
    pub fn destroyed(round: *Round, world: gameobj.World, index: u16) void {
        const all = world.objects;
        const victim = all.playerBinding(index) orelse return;
        if (index >= round.infected.len or round.has(victim.participant)) return;
        const active = round.population(all);
        if (active.players < 2) return;
        if (active.vampires.count() != 0) {
            const killer = all.slots[index].attackerBinding(all) orelse return;
            if (!round.has(killer.participant)) return;
        }
        round.infect(world, victim.participant, active.vampires.count() + 1 == active.players);
    }

    /// vampires_set_role (0x004B5090) announces infection. Once everyone is infected, it pays
    /// the last human and clears just the roles. Ships, scores and the match clock carry on.
    fn infect(round: *Round, world: gameobj.World, pilot: players.ParticipantRef, last_human: bool) void {
        round.infected[pilot.slot] = pilot.generation;
        if (last_human) {
            _ = deathmatch.awardArenaKills(world.objects, pilot, last_human_bonus);
            round.* = .{};
            Notice.post(world, .{ .last_human = pilot });
        } else {
            Notice.post(world, .{ .infected = pilot });
        }
    }

    /// vampires_pilot_left (0x004B4E40) counts the roster before removing the departing pilot.
    /// With exactly one human on that roster, any departure clears the round and uses the
    /// original departure message. Otherwise, only the departing vampire's role is cleared.
    pub fn leave(round: *Round, world: gameobj.World, pilot: players.ParticipantRef) void {
        const active = round.population(world.objects);
        if (active.vampires.count() + 1 == active.players) {
            round.* = .{};
            Notice.post(world, .round_left);
        } else if (round.has(pilot)) {
            round.infected[pilot.slot] = null;
            if (active.vampires.count() == 1) Notice.post(world, .none_left);
        }
    }
};

/// The random pickup gate (mp_can_take_powerup, 0x004B2DC0) refuses vampires.
pub fn isVampire(all: *const create.Objects, index: u16) bool {
    if (all.arena_scenario != .vampires) return false;
    const pilot = all.playerBinding(index) orelse return false;
    return all.arena_scenario.vampires.infection.has(pilot.participant);
}

pub const Notice = struct {
    tick: i32,
    change: Change,

    pub const Change = union(enum(u8)) {
        infected: players.ParticipantRef,
        last_human: players.ParticipantRef,
        round_left,
        none_left,

        pub fn pilot(change: Change) ?players.ParticipantRef {
            return switch (change) {
                .infected, .last_human => |who| who,
                .round_left, .none_left => null,
            };
        }
    };

    pub const Sink = struct {
        context: *anyopaque,
        send: *const fn (*anyopaque, Notice) void,
    };

    fn post(world: gameobj.World, change: Change) void {
        if (world.vampires_notices) |sink| sink.send(sink.context, .{ .tick = world.clock.frame_start, .change = change });
    }

    pub fn present(notice: Notice, messages: *hud.Messages, strings: language.Language, viewer: players.ParticipantRef, name: []const u8) void {
        const tick = notice.tick;
        if (notice.change.pilot() != null)
            deathmatch.addMessage(messages, tick, strings.stringOr(0x2EA, "%s becomes a vampire!"), &.{name});
        switch (notice.change) {
            .infected => {},
            .last_human => |who| {
                const suffix = if (std.meta.eql(viewer, who)) strings.stringOr(0x2F3, "(+5)") else "";
                deathmatch.addMessage(messages, tick, strings.stringOr(0x2EC, "%s was the last human left %s"), &.{ name, suffix });
                announceEmpty(messages, strings, tick);
            },
            .round_left => {
                messages.add(strings.stringOr(0x5BA, "The last Vampire has left"), tick);
                announceEmpty(messages, strings, tick);
            },
            .none_left => announceEmpty(messages, strings, tick),
        }
    }
};

/// vampires_init (0x004B4CF0) posts this when the starting or resynced roster is all human.
pub fn announceEmpty(messages: *hud.Messages, strings: language.Language, tick: i32) void {
    messages.add(strings.stringOr(0x2E9, "There are no vampires"), tick);
}

/// vampires_draw_hud (0x004B4EC0) uses shape 0x0E at the common arena objective anchor.
pub fn drawBadge(pen: hud.Pen, icons: *hud.Art) hud.Error!void {
    try pen.drawing(.{ .art = icons, .gpa = pen.gpa }).partShape(.vampire_badge_icon, 0x0E, pen.placed(.{ -25, 0 }, 0.5, 0));
}

/// vampires_draw_target_badge (0x004B5060) applies the usual bracket offset to shape 0x12.
pub const target_badge_shape = 0x12;

test "the first casualty and vampire kills infect, and the last human alone earns five frags" {
    const aiexplode = @import("../aiexplode.zig");
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const falcon = try mission.add(.of(.predator), @splat(0));
    const viper = try mission.add(.of(.predator), .{ 0, 0, 1500 });
    const rook = try mission.add(.of(.predator), .{ 0, 0, -1500 });
    all.players = 3;
    all.arena_scenario = .{ .vampires = .{ .powerups = try .start(all) } };
    const round = &all.arena_scenario.vampires.infection;
    var world = mission.world();
    world.damage_rules = .{ .arena = null };
    const first = all.joinParticipant(falcon).?;
    _ = all.bindParticipant(first, .of(all, falcon)).?;
    round.destroyed(world, falcon);
    try std.testing.expectEqual(0, round.roles(all).count());
    for ([_]u16{ viper, rook }) |slot| {
        const pilot = all.joinParticipant(slot).?;
        _ = all.bindParticipant(pilot, .of(all, slot)).?;
    }

    round.destroyed(world, viper);
    try std.testing.expectEqual(1, round.roles(all).count());
    try std.testing.expect(isVampire(all, viper));
    mission.slot(rook).setAttacker(.of(all, falcon));
    round.destroyed(world, rook);
    try std.testing.expect(!isVampire(all, rook));
    mission.slot(rook).setAttacker(.of(all, viper));
    round.destroyed(world, rook);
    aiexplode.killCredit(world, rook);
    try std.testing.expectEqual(2, round.roles(all).count());
    try std.testing.expect(isVampire(all, rook));
    mission.slot(viper).setAttacker(.of(all, falcon));
    round.destroyed(world, viper);
    try std.testing.expect(isVampire(all, viper));

    mission.slot(falcon).setAttacker(.of(all, rook));
    round.destroyed(world, falcon);
    aiexplode.killCredit(world, falcon);
    try std.testing.expectEqual(0, round.roles(all).count());
    try std.testing.expectEqual(5, all.player_states[falcon].membership.joined.kills.count);
    try std.testing.expectEqual(1, all.player_states[rook].membership.joined.kills.count);
    try std.testing.expectEqual(1, all.player_states[viper].membership.joined.kills.count);
}

test "departures use the original roster count and a recycled slot joins as human" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    for (0..3) |pilot| {
        _ = try mission.add(.of(.predator), .{ 0, 0, @as(f32, @floatFromInt(pilot)) * 1500 });
    }
    all.players = 3;
    for (0..all.players) |at| {
        const index: u16 = @intCast(at);
        const pilot = all.joinParticipant(index).?;
        _ = all.bindParticipant(pilot, .of(all, index)).?;
    }
    all.arena_scenario = .{ .vampires = .{ .powerups = try .start(all) } };
    const round = &all.arena_scenario.vampires.infection;
    var world = mission.world();
    world.damage_rules = .{ .arena = null };
    const departing = all.playerBinding(0).?.participant;
    round.destroyed(world, 0);
    try std.testing.expect(create.Objects.leaveParticipant(world, departing));
    try std.testing.expectEqual(0, round.roles(all).count());

    const replacement = all.joinParticipant(0).?;
    _ = all.bindParticipant(replacement, .of(all, 0)).?;
    try std.testing.expect(!isVampire(all, 0));
    round.destroyed(world, 1);
    mission.slot(2).setAttacker(.of(all, 1));
    round.destroyed(world, 2);
    try std.testing.expectEqual(2, round.roles(all).count());
    // The last human leaving clears both vampires without awarding a bonus.
    try std.testing.expect(create.Objects.leaveParticipant(world, replacement));
    try std.testing.expectEqual(0, round.roles(all).count());
    try std.testing.expectEqual(0, all.player_states[1].membership.joined.kills.count);
}
