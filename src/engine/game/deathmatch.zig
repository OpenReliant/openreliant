//! Player tallies and multiplayer rules from `C:\lancer\game\deathmatch.cpp`.
//! **Unverified:** `kills_add` lies between the known code from this file and `dmscenarios.cpp`.

const std = @import("std");
const gameobj = @import("gameobj.zig");
const radio = @import("radio.zig");
const Objects = @import("create.zig").Objects;
const players = @import("players.zig");

pub const pickup_rings = @import("deathmatch/pickup_rings.zig");
pub const powerups = @import("deathmatch/powerups.zig");
pub const respawn = @import("deathmatch/respawn.zig");
pub const Wreck = @import("deathmatch/wreck.zig");
pub const spawn = @import("deathmatch/spawn.zig");
pub const dark_reign = @import("dmscenarios/dark_reign.zig");
pub const six_beacons = @import("dmscenarios/six_beacons.zig");
pub const tag_bomb = @import("dmscenarios/tag_bomb.zig");
const math = @import("../surrender/math.zig");

/// `cmd_ResetToSpawnPositions` (`0x004591B0`) selects the rules for this map once and
/// rebuilds the admitted pilots' ships. An empty lobby leaves the spawn markers ready for joins.
pub fn resetToSpawnPositions(world: gameobj.World) !void {
    if (world.damage_rules != .arena) return;
    const all = world.objects;
    const scenarios = @import("dmscenarios.zig");
    if (!scenarios.isScenario(all.mission_number)) return;
    // The original leaves scenery guns off unless the host enables AI turrets.
    for (all.slots[@min(all.players, all.count)..all.count]) |*slot| slot.object.flags.guns_disabled = true;
    if (all.arena_scenario == .deathmatch) {
        if (all.mission_number == scenarios.Scenario.nuclear_threat.mission())
            try six_beacons.Round.start(world, .free_for_all);
        if (all.mission_number == scenarios.Scenario.asteroid_field.mission())
            all.arena_scenario = .{ .asteroid_field = try powerups.Round.start(all) };
        if (all.mission_number == scenarios.Scenario.dark_reign.mission()) {
            const round = try dark_reign.Round.start(all);
            all.arena_scenario = .{ .dark_reign = .{ .relay = round, .powerups = try powerups.Round.start(all) } };
        }
        if (all.mission_number == scenarios.Scenario.tag_bomb.mission())
            all.arena_scenario = .{ .tag_bomb = .{ .powerups = try powerups.Round.start(all) } };
        all.arena_boundary = .{ .bounds = switch (all.arena_scenario) {
            .six_beacons => |*round| round.bounds,
            else => .of(all),
        } };
    }
    for (0..all.players) |at| {
        const index: u16 = @intCast(at);
        const pilot = all.playerBinding(index) orelse continue;
        try spawn.reset(world, pilot.participant, all.slots[index].object.type, null);
    }
}

/// The first arena_frame (0x004AEB50) fits a sphere around the arena scenery and spawn markers.
pub const Bounds = struct {
    centre: math.Vector,
    radius: f32,

    pub fn of(all: *const Objects) Bounds {
        const scenery = all.slots[@min(all.players, all.count)..all.count];
        var low: math.Vector = @splat(std.math.inf(f32));
        var high = -low;
        for (scenery) |*slot| {
            if (!slot.object.created or !includes(slot.object.type.base())) continue;
            const extent: math.Vector = @splat(slot.object.radius);
            low = @min(low, slot.object.position() - extent);
            high = @max(high, slot.object.position() + extent);
        }
        if (low[0] > high[0]) return .{ .centre = @splat(0), .radius = 0 };
        const centre = (low + high) * @as(math.Vector, @splat(0.5));
        var radius: f32 = 0;
        for (scenery) |*slot| {
            if (slot.object.created and includes(slot.object.type.base())) radius = @max(radius, math.distance(centre, slot.object.position()) + slot.object.radius);
        }
        return .{ .centre = centre, .radius = radius };
    }

    fn includes(kind: gameobj.GameType) bool {
        const Type = gameobj.GameType;
        const id = kind.number();
        if (id <= Type.phoenix.number() or id >= Type.marker.number()) return false;
        return switch (id) {
            Type.proximity_mine.number(),
            Type.dm_beacon.number(),
            Type.neptune_hi.number()...Type.earth.number(),
            Type.neptune_lo.number()...Type.venus_lo.number(),
            => false,
            else => true,
        };
    }
};

pub const Boundary = @import("deathmatch/boundary.zig");

/// Rules selected by the host after loading an arena. Ordinary deathmatch has no objectives.
pub const Scenario = union(enum) {
    deathmatch,
    asteroid_field: powerups.Round,
    six_beacons: six_beacons.Round,
    dark_reign: struct { relay: dark_reign.Round, powerups: powerups.Round },
    tag_bomb: struct { bomb: tag_bomb.Round = .{}, powerups: powerups.Round },

    pub fn powerUps(scenario: *Scenario) ?*powerups.Round {
        return switch (scenario.*) {
            .asteroid_field => |*round| round,
            .dark_reign => |*round| &round.powerups,
            .tag_bomb => |*round| &round.powerups,
            else => null,
        };
    }

    pub fn frame(scenario: *Scenario, world: gameobj.World) void {
        if (scenario.powerUps()) |round| round.frame(world);
        switch (scenario.*) {
            .deathmatch, .asteroid_field => {},
            .dark_reign => |*round| round.relay.frame(world),
            .six_beacons => |*round| round.frame(world),
            .tag_bomb => |*round| round.bomb.frame(world),
        }
    }

    pub fn releaseShip(scenario: *Scenario, all: *Objects, index: u16) void {
        if (scenario.powerUps()) |round| round.release(all, index);
        switch (scenario.*) {
            .deathmatch, .asteroid_field, .tag_bomb => {},
            .dark_reign => |*round| round.relay.drop(all, index),
            .six_beacons => |*round| round.drop(all, index),
        }
    }

    pub fn departShip(scenario: *Scenario, all: *Objects, pilot: players.ParticipantRef) void {
        switch (scenario.*) {
            .dark_reign => |*round| round.relay.leave(all, pilot.slot),
            .tag_bomb => |*round| round.bomb.leave(pilot),
            else => return scenario.releaseShip(all, pilot.slot),
        }
        if (scenario.powerUps()) |round| round.release(all, pilot.slot);
    }
};

/// pickup_drop (0x004B26B0) cycles through the six world axes (0x0050C4AC).
pub const PickupDrop = struct {
    next: usize = 0,

    const directions = [_]math.Vector{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

    pub fn beside(drop: *PickupDrop, item: *@import("create.zig").Slot, ship: *const gameobj.GameObject) void {
        const offset = directions[drop.next] * @as(math.Vector, @splat(0.8 * ship.radius));
        drop.next = (drop.next + 1) % directions.len;
        @import("objects.zig").setPosition(&item.object, &item.drawn, ship.position() + offset);
        item.object.flags.disabled = false;
        item.object.flags.targetable = true;
    }
};

/// pickup_frame (0x004B24A0) skips pilots who are dying, spawning or waiting to collect again.
pub fn pickupPilot(world: gameobj.World, index: u16) ?players.ControlRef {
    const all = world.objects;
    const binding = all.playerBinding(index) orelse return null;
    const ship = &all.slots[index];
    if (!all.hasBoundPlayerShip(index) or ship.running(.explode) != null or ship.running(.deathmatch_respawn_effect) != null) return null;
    if (world.clock.frame_start < all.player_states[index].membership.joined.pickups_after) return null;
    return binding;
}

pub fn onlyOnePilot(all: *const Objects) bool {
    var joined: usize = 0;
    for (all.player_states[0..all.playerSlotCount()]) |*state| {
        if (state.membership == .joined) joined += 1;
        if (joined >= 2) return false;
    }
    return true;
}

pub const TeamScore = struct {
    kills: i32 = 0,
    deaths: u32 = 0,
};

/// The host's object side is shared. Use admissions and arena teams for a missile's allies.
pub fn missileAlly(all: *Objects, launcher: gameobj.DamageSource, pilot: players.ControlRef) bool {
    const owner = all.playerBindingFor(launcher.object, launcher.participant_generation) orelse return false;
    if (owner.participant.slot == pilot.participant.slot) return true;
    if (all.arena_scores != .teams) return false;
    const team = all.participantTeam(owner.participant) orelse return false;
    return all.participantTeam(pilot.participant) == team;
}

/// Only a team game keeps the four sets of totals at 0x005D76FC and 0x005D76DC.
pub const ArenaScores = union(enum) {
    free_for_all,
    teams: std.EnumArray(players.ArenaTeam, TeamScore),

    /// The original calls `mp_reset_team_tallies` (0x004B15E0) when the last pilot leaves a team.
    pub fn clearEmptyTeam(scores: *ArenaScores, all: *const Objects, previous: ?players.ArenaTeam) void {
        const team = previous orelse return;
        if (scores.* != .teams) return;
        for (all.player_states[0..all.playerSlotCount()]) |*state| {
            if (state.membership == .joined and state.membership.joined.team == team) return;
        }
        scores.teams.set(team, .{});
    }
};

/// The host starts a fresh arena round with the current admissions and team assignments.
/// `mp_arena_init` (0x004AE860) clears both the player and team scores.
pub fn startRound(all: *Objects, mode: std.meta.Tag(ArenaScores)) void {
    all.arena_scenario = .deathmatch;
    all.arena_boundary = null;
    all.arena_scores = switch (mode) {
        .free_for_all => .free_for_all,
        .teams => .{ .teams = .initFill(.{}) },
    };
    for (all.player_states[0..all.playerSlotCount()]) |*state| {
        if (state.membership == .joined) {
            state.membership.joined.kills.count = 0;
            state.membership.joined.deaths = 0;
            state.membership.joined.pickups_after = 0;
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
        .cooperative => {
            const binding = slot.attackerBinding(all) orelse return;
            all.player_states[binding.participant.slot].membership.joined.kills.add(1, all.rules().counts_kills);
            radio.hostedKillRemark(world, index, binding, channels);
        },
        .arena => {
            const binding = slot.attackerBinding(all) orelse return;
            if (all.arena_scores == .teams) {
                if (all.playerBinding(index)) |victim| {
                    const opposing = all.participantTeam(victim.participant) orelse return;
                    if (opposing == all.participantTeam(binding.participant)) return;
                }
            }
            _ = awardArenaKills(all, binding.participant, 1);
        },
    }
}

/// Adds frags to the same admission even if its fighter has since respawned.
pub fn awardArenaKills(all: *Objects, recipient: players.ParticipantRef, count: i32) bool {
    const state = all.joinedParticipant(recipient) orelse return false;
    const pilot = &state.membership.joined;
    if (all.arena_scores == .teams) {
        const team = pilot.team orelse return false;
        all.arena_scores.teams.getPtr(team).kills += count;
    }
    pilot.kills.add(count, false);
    return true;
}

/// An arena-wide HUD message from the host. The session resolves names by admission.
pub const UberKill = struct {
    owner: players.ParticipantRef,
    victim: players.ParticipantRef,
    awarded: bool,
    tick: i32,

    const message_id = 0x301; // uber_explode_update, 0x00473340
    const award_suffix_id = 0x2F4; // 0x00473309

    pub const Sink = struct {
        context: *anyopaque,
        send: *const fn (*anyopaque, UberKill) void,
    };

    /// Formats the installed language's kill line (0x301). Only the scorer sees the
    /// award suffix (0x2F4). The HUD keeps as much of the message as fits on one line.
    pub fn present(notice: UberKill, messages: *@import("hud.zig").Messages, strings: @import("language.zig").Language, viewer: players.ParticipantRef, owner_name: []const u8, victim_name: []const u8) void {
        const format = strings.string(message_id) orelse return;
        const scored = notice.awarded and std.meta.eql(notice.owner, viewer);
        const suffix = if (scored) strings.string(award_suffix_id) orelse "" else "";
        addMessage(messages, notice.tick, format, &.{ owner_name, victim_name, suffix });
    }
};

/// Fills the original HUD string's %s fields and clips the result to one message line.
pub fn addMessage(messages: anytype, tick: i32, format: []const u8, values: []const []const u8) void {
    var buffer: [@import("hud.zig").Messages.line_size]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buffer);
    var parts = std.mem.splitSequence(u8, format, "%s");
    line.writeAll(parts.first()) catch {};
    for (values) |value| {
        const after = parts.next() orelse break;
        line.writeAll(value) catch break;
        line.writeAll(after) catch break;
    }
    messages.add(line.buffered(), tick);
}

/// `uber_explode_update` clears the previous attacker, awards the blast owner a kill
/// without testing team allegiance (0x00473372), then posts the HUD message (0x0047337E).
pub fn uberKill(world: gameobj.World, source: gameobj.DamageSource, victim: players.ParticipantRef) void {
    const all = world.objects;
    const slot = &all.slots[victim.slot];
    slot.setAttacker(null);
    slot.object.last_attacker = .uber_blast;
    const generation = source.participant_generation orelse return;
    const binding = all.playerBindingFor(source.object, generation);
    const awarded = if (binding) |owner| awardArenaKills(all, owner.participant, 1) else false;
    if (world.uber_kills) |sink| sink.send(sink.context, .{
        .owner = .{ .slot = source.object.slot, .generation = generation },
        .victim = victim,
        .awarded = awarded,
        .tick = world.clock.frame_start,
    });
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

test "the Uber announcement uses the viewer's language and only the scorer sees the award" {
    var text: [UberKill.message_id][]const u8 = @splat("");
    text[UberKill.message_id - 1] = "%s / %s %s";
    text[UberKill.award_suffix_id - 1] = "+1";
    const strings: @import("language.zig").Language = .{ .strings = &text };
    var messages: @import("hud.zig").Messages = .{};
    const notice: UberKill = .{
        .owner = .{ .slot = 0, .generation = 1 },
        .victim = .{ .slot = 1, .generation = 2 },
        .awarded = true,
        .tick = 100,
    };
    notice.present(&messages, strings, notice.owner, "Alpha", "%s");
    notice.present(&messages, strings, notice.victim, "Alpha", "%s");
    try std.testing.expectEqualStrings("Alpha / %s +1", messages.line(0));
    try std.testing.expectEqualStrings("Alpha / %s ", messages.line(1));
}

test {
    std.testing.refAllDecls(@This());
}
