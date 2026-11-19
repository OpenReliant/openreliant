//! The Tag Bomb scenario from dmscenarios.cpp (0x004B4340).
//! **Improvement:** The host runs the fuse and resolves gun tags for every pilot.
const std = @import("std");
const ai = @import("../ai.zig");
const deathmatch = @import("../deathmatch.zig");
const gameobj = @import("../gameobj.zig");
const hud = @import("../hud.zig");
const language = @import("../language.zig");
const players = @import("../players.zig");

pub const fuse = 4500;
const detonation_frags = 3;

pub const Notice = struct {
    kind: Kind,
    pilot: players.ParticipantRef,
    other: players.ParticipantRef,
    tick: i32,
    awarded: bool = false,

    pub const Kind = enum(u8) { passed, detonated };
    pub const Sink = struct {
        context: *anyopaque,
        send: *const fn (*anyopaque, Notice) void,
    };

    fn post(world: gameobj.World, notice: Notice) void {
        if (world.tag_bomb_notices) |sink| sink.send(sink.context, notice);
    }

    pub fn present(notice: Notice, messages: *hud.Messages, strings: language.Language, viewer: players.ParticipantRef, name: []const u8, other_name: []const u8) void {
        switch (notice.kind) {
            .passed => deathmatch.addMessage(messages, notice.tick, strings.string(0x305) orelse "%s passed the bomb to %s", &.{ name, other_name }),
            .detonated => {
                const suffix = if (notice.awarded and std.meta.eql(notice.pilot, viewer))
                    strings.string(0x5B8) orelse "(+3)"
                else
                    "";
                deathmatch.addMessage(messages, notice.tick, strings.string(0x2E1) orelse "%s laughs as %s explodes %s", &.{ name, other_name, suffix });
            },
        }
    }
};

pub const Hud = struct {
    carrier: ?players.ParticipantRef = null,
    remaining: u16 = 0,

    pub fn active(view: Hud, pilot: players.ParticipantRef) bool {
        return std.meta.eql(view.carrier, @as(?players.ParticipantRef, pilot));
    }

    /// tag_bomb_draw_hud (0x004B46B0) puts the original badge and rounded timer at the shared
    /// arena objective anchor. The original adds one even on an exact second.
    pub fn drawLocal(view: Hud, pen: hud.Pen, icons: ?*hud.Art) hud.Error!void {
        const anchor = pen.placed(.{ -25, 0 }, 0.5, 0);
        if (icons) |art| try pen.drawing(.{ .art = art, .gpa = pen.gpa }).shape(0x0A, anchor);
        var buffer: [language.max_length + 5]u8 = undefined;
        const units = pen.strings.string(0x2D5) orelse "secs";
        const text = std.fmt.bufPrint(&buffer, "{d} {s}", .{ view.remaining / 100 + 1, units }) catch return;
        _ = try pen.partText(.tag_bomb_countdown, pen.moved(anchor, .{ 21, 40 }), text, .centre);
    }
};

const Pilot = struct {
    // The pilot's original countdown pauses while another ship carries the bomb.
    remaining: u16 = fuse,
    pending: ?struct { tagger: ?players.ParticipantRef } = null,
};

pub const Round = struct {
    carrier: ?players.ParticipantRef = null,
    tagger: ?players.ParticipantRef = null,
    pilots: [deathmatch.spawn.positions]Pilot = @splat(.{}),
    detonating: bool = false,

    pub fn hudView(round: *const Round) Hud {
        const carrier = round.carrier orelse return .{};
        return .{ .carrier = carrier, .remaining = round.pilots[carrier.slot].remaining };
    }

    /// tag_bomb_pilot_destroyed (0x004B4460) arms the first downed pilot on respawn.
    /// A carrier who dies before detonation keeps the same timer through respawn.
    pub fn destroyed(round: *Round, world: gameobj.World, index: u16) void {
        const all = world.objects;
        const pilot = all.playerBinding(index) orelse return;
        if (index >= round.pilots.len) return;
        if (round.carrier == null) {
            const attacker = all.slots[index].attackerBinding(all);
            round.pilots[index] = .{ .pending = .{ .tagger = if (attacker) |by| by.participant else null } };
        } else if (round.detonating and round.hudView().active(pilot.participant)) {
            round.clear();
            round.pilots[index].remaining = fuse;
        }
    }

    /// tag_bomb_pilot_respawned (0x004B4510) hands over the bomb at the end of the spawn effect.
    pub fn respawned(round: *Round, world: gameobj.World, index: u16) void {
        const pilot = world.objects.playerBinding(index) orelse return;
        if (index >= round.pilots.len) return;
        const pending = round.pilots[index].pending orelse return;
        round.pilots[index].pending = null;
        round.assign(world, pilot.participant, pending.tagger);
    }

    /// tag_bomb_pilot_left (0x004B44D0) clears ownership if the carrier leaves.
    pub fn leave(round: *Round, pilot: players.ParticipantRef) void {
        if (round.hudView().active(pilot)) round.clear();
        if (pilot.slot < round.pilots.len) round.pilots[pilot.slot] = .{};
    }

    fn clear(round: *Round) void {
        round.carrier = null;
        round.tagger = null;
        round.detonating = false;
    }

    /// tag_bomb_bullet_hit (0x004B44F0) runs for a primary gun impact, including shields.
    /// The host checks the projectile's ship and admission before it can pass the bomb.
    pub fn bulletHit(world: gameobj.World, target: u16, source: gameobj.DamageSource) void {
        const all = world.objects;
        if (world.damage_rules != .arena or all.arena_scenario != .tag_bomb) return;
        const round = &all.arena_scenario.tag_bomb.bomb;
        if (round.detonating or target >= round.pilots.len) return;
        const owner = all.playerBindingFor(source.object, source.participant_generation) orelse return;
        if (!round.hudView().active(owner.participant) or owner.participant.slot == target) return;
        const hit = all.playerBinding(target) orelse return;
        round.assign(world, hit.participant, owner.participant);
    }

    /// tag_bomb_set_carrier (0x004B4810) changes the carrier without resetting their timer.
    fn assign(round: *Round, world: gameobj.World, pilot: players.ParticipantRef, by: ?players.ParticipantRef) void {
        round.tagger = by orelse round.carrier;
        round.carrier = pilot;
        round.detonating = false;
        if (by) |tagger| Notice.post(world, .{
            .kind = .passed,
            .pilot = tagger,
            .other = pilot,
            .tick = world.clock.frame_start,
        });
    }

    /// tag_bomb_frame (0x004B4550) counts down only for a flying carrier.
    pub fn frame(round: *Round, world: gameobj.World) void {
        const carrier = round.carrier orelse return;
        const all = world.objects;
        const index = carrier.slot;
        if (round.detonating or all.joinedParticipant(carrier) == null or !all.hasBoundPlayerShip(index)) return;
        if (all.slots[index].running(.deathmatch_respawn_effect) != null or all.slots[index].running(.explode) != null) return;
        const remaining = &round.pilots[index].remaining;
        remaining.* = @intCast(@as(u32, remaining.*) -| world.clock.frameTicks());
        if (remaining.* == 0) round.detonate(world, carrier);
    }

    /// tag_bomb_detonate (0x004B45D0) destroys the carrier and credits the last tagger three
    /// frags (0x004B468D). The installed help string says two, but the executable awards three.
    fn detonate(round: *Round, world: gameobj.World, victim: players.ParticipantRef) void {
        const all = world.objects;
        round.detonating = true;
        ai.objectDestroyed(.of(world), victim.slot, false, true);
        const tagger = round.tagger orelse return;
        // The original writes -2 so the ship explosion cannot award a second frag.
        all.slots[victim.slot].setAttacker(null);
        Notice.post(world, .{
            .kind = .detonated,
            .pilot = tagger,
            .other = victim,
            .tick = world.clock.frame_start,
            .awarded = deathmatch.awardArenaKills(all, tagger, detonation_frags),
        });
    }
};

test "Tag Bomb arms on first respawn and each pilot resumes their own fuse" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const first = try mission.add(.of(.predator), .{ 0, 0, 0 });
    const second = try mission.add(.of(.predator), .{ 0, 0, 1500 });
    all.players = 2;
    const a = all.joinParticipant(first).?;
    _ = all.bindParticipant(a, .of(all, first)).?;
    const b = all.joinParticipant(second).?;
    _ = all.bindParticipant(b, .of(all, second)).?;
    all.arena_scenario = .{ .tag_bomb = .{ .powerups = try .start(all) } };
    const round = &all.arena_scenario.tag_bomb.bomb;
    var world = mission.world();
    world.damage_rules = .{ .arena = null };
    const shot_a: gameobj.DamageSource = .of(all, first);
    const shot_b: gameobj.DamageSource = .of(all, second);

    mission.slot(second).setAttacker(shot_a);
    round.destroyed(world, second);
    try std.testing.expectEqual(null, round.carrier);
    round.respawned(world, second);
    try std.testing.expect(round.hudView().active(b));
    try std.testing.expectEqual(a, round.tagger.?);
    mission.clock.frame_duration = 12;
    round.frame(world);
    try std.testing.expectEqual(fuse - 12, round.hudView().remaining);

    Round.bulletHit(world, first, shot_b);
    try std.testing.expect(round.hudView().active(a));
    try std.testing.expectEqual(fuse, round.hudView().remaining);
    round.frame(world);
    Round.bulletHit(world, second, shot_a);
    try std.testing.expect(round.hudView().active(b));
    try std.testing.expectEqual(fuse - 12, round.hudView().remaining);

    round.destroyed(world, second);
    try std.testing.expect(round.hudView().active(b));
    try std.testing.expectEqual(fuse - 12, round.hudView().remaining);
    const ctx: @import("../aigeneric.zig").Context = .of(world);
    try std.testing.expect(try @import("../aigeneric.zig").push(ctx, second, .deathmatch_respawn_effect, .none));
    round.frame(world);
    try std.testing.expectEqual(fuse - 12, round.hudView().remaining);
    try std.testing.expect(@import("../aigeneric.zig").pop(ctx, second));

    try std.testing.expect(@import("../create.zig").Objects.leaveParticipant(world, a));
    const replacement = all.joinParticipant(first).?;
    _ = all.bindParticipant(replacement, .of(all, first)).?;
    round.pilots[second].remaining = 4;
    round.frame(world);
    try std.testing.expect(mission.slot(second).running(.explode) != null);
    try std.testing.expectEqual(0, all.player_states[first].membership.joined.kills.count);
    try std.testing.expectEqual(null, mission.slot(second).attacker(all));
    round.destroyed(world, second);
    try std.testing.expectEqual(fuse, round.pilots[second].remaining);
    try std.testing.expectEqual(null, round.carrier);
}
