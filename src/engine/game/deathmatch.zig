//! Player tallies and multiplayer rules from `C:\lancer\game\deathmatch.cpp`.
//! **Unverified:** `kills_add` lies between the known code from this file and `dmscenarios.cpp`.

const std = @import("std");
const gameobj = @import("gameobj.zig");
const radio = @import("radio.zig");

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
            const kills = &all.player_states[binding.participant.slot].membership.joined.kills;
            kills.add(1, world.damage_rules == .cooperative and all.rules().counts_kills);
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
    mission.slot(target).object.side = .hostile;
    mission.slot(target).setAttacker(.of(all, shooter));
    host.player.remarks.kill_credit = false;
    @import("aiexplode.zig").killCredit(host, target);
    const Kills = @import("players.zig").Kills;
    try std.testing.expectEqual(Kills{ .count = 1 }, all.player_states[shooter].membership.joined.kills);
    try std.testing.expectEqual(Kills{}, host.player.kills);
}
