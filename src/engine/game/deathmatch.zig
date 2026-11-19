//! Player tallies and multiplayer rules from `C:\lancer\game\deathmatch.cpp`.
//! **Unverified:** `kills_add` lies between the known code from this file and `dmscenarios.cpp`.

const std = @import("std");
const gameobj = @import("gameobj.zig");
const radio = @import("radio.zig");
const Objects = @import("create.zig").Objects;
const players = @import("players.zig");

pub const TeamScore = struct {
    kills: i32 = 0,
    deaths: u32 = 0,
};

/// Only a team game keeps the four sets of totals at 0x005D76FC and 0x005D76DC.
pub const ArenaScores = union(enum) {
    free_for_all,
    teams: std.EnumArray(players.ArenaTeam, TeamScore),

    /// The original calls `mp_reset_team_tallies` (0x004B15E0) when the last pilot leaves a team.
    pub fn clearEmptyTeam(scores: *ArenaScores, all: *const Objects, previous: ?players.ArenaTeam) void {
        const team = previous orelse return;
        if (scores.* != .teams) return;
        for (all.player_states[0..@min(all.players, all.player_states.len)]) |*state| {
            if (state.membership == .joined and state.membership.joined.team == team) return;
        }
        scores.teams.set(team, .{});
    }
};

/// The host starts a fresh arena round with the current admissions and team assignments.
/// `mp_arena_init` (0x004AE860) clears both the player and team scores.
pub fn startRound(all: *Objects, mode: std.meta.Tag(ArenaScores)) void {
    all.arena_scores = switch (mode) {
        .free_for_all => .free_for_all,
        .teams => .{ .teams = .initFill(.{}) },
    };
    for (all.player_states[0..@min(all.players, all.player_states.len)]) |*state| {
        if (state.membership == .joined) {
            state.membership.joined.kills.count = 0;
            state.membership.joined.deaths = 0;
        }
    }
}

/// `explode_ship_init` calls `deaths_add` at 0x00408866 before checking kill credit.
/// **Improvement:** the host counts the death of every bound pilot, whatever killed them.
pub fn recordDeath(all: *Objects, index: u16) void {
    const victim = all.playerBinding(index) orelse return;
    const pilot = &all.player_states[victim.participant.slot].membership.joined;
    pilot.deaths += 1;
    if (all.arena_scores == .teams) {
        if (pilot.team) |team| all.arena_scores.teams.getPtr(team).deaths += 1;
    }
}

/// Credits a destruction that passed the rules for its ship or hull. The original calls
/// `kills_add` (0x004B14F0) before `radio_kill_remark`. **Improvement:** the host awards
/// the kill to the pilot who owned the damage source, independently of the cockpit and radio.
pub fn creditDestruction(world: gameobj.World, index: u16, channels: radio.KillChannels) void {
    const all = world.objects;
    const slot = &all.slots[index];
    switch (world.damage_rules) {
        .campaign => {
            if (slot.attacker(all) != all.player) return;
            world.player.kills.add(1, all.rules().counts_kills);
            radio.killRemark(world, index);
        },
        .cooperative, .arena => {
            const binding = slot.attackerBinding(all) orelse return;
            const pilot = &all.player_states[binding.participant.slot].membership.joined;
            if (world.damage_rules == .arena and all.arena_scores == .teams) {
                const team = pilot.team orelse return;
                if (all.playerBinding(index)) |victim| {
                    const opposing = all.participantTeam(victim.participant) orelse return;
                    if (opposing == team) return;
                }
                all.arena_scores.teams.getPtr(team).kills += 1;
            }
            pilot.kills.add(1, world.damage_rules == .cooperative and all.rules().counts_kills);
            if (world.damage_rules == .cooperative) radio.hostedKillRemark(world, index, binding, channels);
        },
    }
}

test "a co-op pilot keeps kills across ships and starts each mission with a fresh mission tally" {
    const gameflow = @import("gameflow.zig");
    const create = @import("create.zig");
    const hud = @import("hud.zig");
    const explode = @import("explode.zig");
    const aiexplode = @import("aiexplode.zig");
    const Kills = @import("players.zig").Kills;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var host = mission.world();
    host.damage_rules = .cooperative;
    const all = host.objects;
    _ = try mission.add(.of(.predator), @splat(0));
    const shooter = try mission.add(.of(.predator), @splat(0));
    const target = try mission.add(.of(.kurgan), @splat(0));
    all.players = 2;
    const pilot = all.joinParticipant(shooter).?;
    const bound = all.bindParticipant(pilot, .of(all, shooter)).?;
    const kills = &all.player_states[shooter].membership.joined.kills;
    const shot: gameobj.DamageSource = .of(all, shooter);
    mission.slot(target).setAttacker(shot);
    host.player.remarks.kill_credit = false;
    explode.loseHull(.of(host), target);
    try std.testing.expectEqual(Kills{ .count = 1, .mission = 1 }, kills.*);
    try std.testing.expectEqual(0, hud.Readout.skull.value(all, host.player));
    all.player = shooter;
    try std.testing.expectEqual(1, hud.Readout.skull.value(all, host.player));

    // The host reads the installed mission record even for a stock campaign number.
    var custom = gameflow.CampaignMission.original[0];
    custom.rules.counts_kills = false;
    gameflow.installMissions(&.{custom});
    defer gameflow.installMissions(&gameflow.CampaignMission.original);
    all.mission_number = 1;
    const enemy = try mission.add(.of(.sabre), @splat(0));
    mission.slot(enemy).object.side = .hostile;
    mission.slot(enemy).setAttacker(shot);
    aiexplode.killCredit(host, enemy);
    try std.testing.expectEqual(Kills{ .count = 2, .mission = 1 }, kills.*);
    try std.testing.expectEqual(Kills{}, host.player.kills);

    create.resetSlot(.of(host), shooter);
    _ = try create.createObject(all, &mission.tables, create.testing.no_models, shooter, .of(.predator), 0, @splat(0), &mission.random);
    const replacement = all.bindParticipant(pilot, .of(all, shooter)).?;
    try std.testing.expect(!std.meta.eql(bound.ship, replacement.ship));
    aiexplode.killCredit(host, enemy);
    try std.testing.expectEqual(Kills{ .count = 2, .mission = 1 }, kills.*);
    all.reset(&mission.random);
    try std.testing.expectEqual(Kills{ .count = 2 }, kills.*);
    try std.testing.expect(create.Objects.leaveParticipant(host, pilot));
    try std.testing.expectEqual(0, hud.Readout.skull.value(all, host.player));
    _ = all.joinParticipant(shooter).?;
    try std.testing.expectEqual(Kills{}, all.player_states[shooter].membership.joined.kills);
}

test "campaign kill credit follows the attacker and the channel rule for each destruction path" {
    const aiexplode = @import("aiexplode.zig");
    const explode = @import("explode.zig");
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    const player = try mission.add(.of(.predator), @splat(0));
    const enemy = try mission.add(.of(.sabre), @splat(0));
    const slot = mission.slot(enemy);
    slot.object.side = .hostile;
    slot.setAttacker(.of(world.objects, enemy));
    aiexplode.killCredit(world, enemy);
    slot.setAttacker(.of(world.objects, player));
    world.player.remarks.kill_credit = false;
    aiexplode.killCredit(world, enemy);
    try std.testing.expectEqual(0, world.player.kills.count);
    const hull = try mission.add(.of(.antanov), @splat(0));
    mission.slot(hull).setAttacker(.of(world.objects, player));
    explode.loseHull(.of(world), hull);
    try std.testing.expectEqual(1, world.player.kills.mission);
    world.objects.mission_number = 28;
    world.player.remarks.kill_credit = true;
    aiexplode.killCredit(world, enemy);
    try std.testing.expectEqual(2, world.player.kills.count);
    try std.testing.expectEqual(1, world.player.kills.mission);
}

test "an eligible arena kill belongs to its pilot and never counts toward a campaign mission" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var host = mission.world();
    host.damage_rules = .{ .arena = null };
    const all = host.objects;
    _ = try mission.add(.of(.predator), @splat(0));
    const shooter = try mission.add(.of(.predator), @splat(0));
    const target = try mission.add(.of(.sabre), @splat(0));
    all.players = 2;
    const pilot = all.joinParticipant(shooter).?;
    _ = all.bindParticipant(pilot, .of(all, shooter)).?;
    try std.testing.expect(all.setParticipantTeam(pilot, .fourth));
    startRound(all, .teams);
    mission.slot(target).object.side = .hostile;
    mission.slot(target).setAttacker(.of(all, shooter));
    host.player.remarks.kill_credit = false;
    @import("aiexplode.zig").killCredit(host, target);
    const Kills = @import("players.zig").Kills;
    try std.testing.expectEqual(Kills{ .count = 1 }, all.player_states[shooter].membership.joined.kills);
    try std.testing.expectEqual(TeamScore{ .kills = 1 }, all.arena_scores.teams.get(.fourth));
    mission.slot(target).object.side = .friendly;
    @import("aiexplode.zig").killCredit(host, target);
    try std.testing.expectEqual(TeamScore{ .kills = 1 }, all.arena_scores.teams.get(.fourth));
    try std.testing.expectEqual(Kills{}, host.player.kills);
}

test "the host scores an exploding arena pilot once, independently of who earns a kill" {
    const cases = [_]struct {
        mode: std.meta.Tag(ArenaScores) = .teams,
        attacker_team: ?players.ArenaTeam = .first,
        victim_team: ?players.ArenaTeam = .second,
        source: enum { pilot, departed, none } = .pilot,
        kills: i32,
    }{
        .{ .mode = .free_for_all, .victim_team = .first, .kills = 1 },
        .{ .kills = 1 },
        .{ .victim_team = .first, .kills = 0 },
        .{ .victim_team = null, .kills = 0 },
        .{ .attacker_team = null, .kills = 0 },
        .{ .source = .departed, .kills = 0 },
        .{ .source = .none, .kills = 0 },
    };
    for (cases) |case| {
        var mission: gameobj.testing.Mission = undefined;
        try mission.init(std.testing.allocator);
        defer mission.deinit();
        var ctx = mission.orders();
        ctx.world.damage_rules = .{ .arena = null };
        ctx.world.player.remarks.kill_credit = false;
        const all = ctx.world.objects;
        all.players = 2;
        const shooter = try mission.add(.of(.predator), @splat(0));
        const victim = try mission.add(.of(.predator), .{ 0, 0, 1000 });
        const pilot = all.joinParticipant(shooter).?;
        const target = all.joinParticipant(victim).?;
        _ = all.bindParticipant(pilot, .of(all, shooter)).?;
        _ = all.bindParticipant(target, .of(all, victim)).?;
        try std.testing.expect(all.setParticipantTeam(pilot, case.attacker_team));
        try std.testing.expect(all.setParticipantTeam(target, case.victim_team));
        startRound(all, case.mode);

        if (case.source != .none) mission.slot(victim).setAttacker(.of(all, shooter));
        if (case.source == .departed) {
            try std.testing.expect(Objects.leaveParticipant(ctx.world, pilot));
            const newcomer = all.joinParticipant(shooter).?;
            _ = all.bindParticipant(newcomer, .of(all, shooter)).?;
            try std.testing.expect(all.setParticipantTeam(newcomer, case.attacker_team));
        }
        @import("ai.zig").objectDestroyed(ctx, victim, true, true);
        for (0..2) |_| @import("aigeneric.zig").objectOrders(ctx, victim);
        const killer = &all.player_states[shooter].membership.joined;
        const lost = &all.player_states[victim].membership.joined;
        try std.testing.expectEqual(case.kills, killer.kills.count);
        try std.testing.expectEqual(0, killer.deaths);
        try std.testing.expectEqual(1, lost.deaths);
        if (all.arena_scores == .teams) {
            for (std.enums.values(players.ArenaTeam)) |team| {
                try std.testing.expectEqual(TeamScore{
                    .kills = if (case.attacker_team == team) case.kills else 0,
                    .deaths = @intFromBool(case.victim_team == team),
                }, all.arena_scores.teams.get(team));
            }
        }
        startRound(all, .teams);
        try std.testing.expectEqual(0, killer.kills.count);
        try std.testing.expectEqual(0, lost.deaths);
        try std.testing.expectEqual(case.victim_team, lost.team);
        try std.testing.expectEqual(TeamScore{}, all.arena_scores.teams.get(.first));
        try std.testing.expectEqual(TeamScore{}, all.arena_scores.teams.get(.second));
    }
}

test "team totals stay with the team until its last pilot leaves" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    all.players = 2;
    const first = all.joinParticipant(0).?;
    const second = all.joinParticipant(1).?;
    startRound(all, .teams);
    try std.testing.expect(all.setParticipantTeam(first, .first));
    try std.testing.expect(all.setParticipantTeam(second, .first));
    const score: TeamScore = .{ .kills = 4, .deaths = 3 };
    all.arena_scores.teams.set(.first, score);
    try std.testing.expect(all.setParticipantTeam(first, .second));
    try std.testing.expectEqual(score, all.arena_scores.teams.get(.first));
    try std.testing.expectEqual(TeamScore{}, all.arena_scores.teams.get(.second));
    try std.testing.expect(Objects.leaveParticipant(mission.world(), second));
    try std.testing.expectEqual(TeamScore{}, all.arena_scores.teams.get(.first));
}
