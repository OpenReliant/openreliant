//! The relay and target selection for Dark Reign (dmscenarios.cpp, 0x004B3AE0).
const std = @import("std");
const ai = @import("../ai.zig");
const orders = @import("../aigeneric.zig");
const create = @import("../create.zig");
const deathmatch = @import("../deathmatch.zig");
const gameobj = @import("../gameobj.zig");
const input = @import("../../input.zig");
const objects = @import("../objects.zig");
const players = @import("../players.zig");
const sound3d = @import("../sound3d.zig");
const math = @import("../../surrender/math.zig");

const target_delay = @import("../dmscenarios.zig").Scenario.dark_reign.record().rules.dark_reign.target_delay; // dark_reign_frame, 0x004B3F57
const return_interval = 50;
const return_margin: f32 = 500;

pub const Round = struct {
    relay: gameobj.ObjectRef,
    tower: gameobj.ObjectRef,
    bounds: deathmatch.Bounds,
    carrier: ?players.ControlRef = null,
    drops: deathmatch.PickupDrop = .{},
    next_return: i32 = 0,
    last_wait: i32 = 0,

    pub fn start(all: *const create.Objects) !Round {
        return .{
            .relay = find(all, .comms_relay) orelse return error.MissingCommsRelay,
            .tower = find(all, .darkreign) orelse return error.MissingDarkReign,
            .bounds = .of(all),
        };
    }

    pub fn find(all: *const create.Objects, kind: gameobj.GameType) ?gameobj.ObjectRef {
        for (all.slots[all.players..all.count], all.players..) |*slot, index| {
            if (slot.object.created and slot.object.type.base() == kind) return .of(all, @intCast(index));
        }
        return null;
    }

    /// The host drops the relay before clearing the ship's binding.
    pub fn drop(round: *Round, all: *create.Objects, index: u16) void {
        const carrier = round.carrier orelse return;
        const binding = all.playerBinding(index) orelse return;
        if (!std.meta.eql(carrier, binding)) return;
        round.carrier = null;
        const relay = round.relay.resolve(all) orelse return;
        round.drops.beside(&all.slots[relay], &all.slots[index].object);
    }

    /// On departure the original re-enables the relay at its last loose position
    /// (0x004B3C40). Destruction instead drops it beside the ship (0x004B3CB0).
    pub fn leave(round: *Round, all: *create.Objects, index: u16) void {
        const carrier = round.carrier orelse return;
        if (carrier.participant.slot != index) return;
        round.carrier = null;
        const relay = round.relay.resolve(all) orelse return;
        all.slots[relay].object.flags.disabled = false;
    }

    pub fn frame(round: *Round, world: gameobj.World) void {
        const all = world.objects;
        const index = round.relay.resolve(all) orelse return;
        if (round.carrier == null) round.collect(world, index);
        const tower = round.tower.resolve(all) orelse return;
        round.target(world, tower);
    }

    fn collect(round: *Round, world: gameobj.World, index: u16) void {
        const all = world.objects;
        const relay = &all.slots[index];
        const now = world.clock.frame_start;
        if (now >= round.next_return) {
            round.next_return = (now - @mod(now, return_interval)) + return_interval;
            if (math.distance(relay.drawn.position, round.bounds.centre) > round.bounds.radius - return_margin) {
                for (all.slots[all.players..all.count]) |*marker| {
                    if (marker.object.type.base() != .beacon_marker) continue;
                    objects.setPlace(&relay.object, &relay.drawn, marker.object.placeAt(.now));
                    sound3d.playIn(world, null, null, index, .dmspawn2, 1, .not_reserved);
                    break;
                }
            }
        }
        if (relay.object.flags.disabled) return;
        for (0..all.playerSlotCount()) |i| {
            const player: u16 = @intCast(i);
            const binding = deathmatch.pickupPilot(world, player) orelse continue;
            const ship = &all.slots[i];
            if (math.distance(ship.drawn.position, relay.drawn.position) >= ship.object.radius + relay.object.radius) continue;
            // The original waits for a second admission before allowing the pickup.
            if (deathmatch.onlyOnePilot(all)) {
                deathmatch.six_beacons.Notice.waiting(world, binding.participant, &round.last_wait);
                return;
            }
            round.carrier = binding;
            relay.object.flags.disabled = true;
            if (ai.controlEntry(all, player)) |entry| {
                if (entry.target.slotIn(all) == index) _ = input.cycleTargetFor(world.display, all, player, .next, .hostile, true);
            }
            sound3d.playIn(world, null, null, player, .dmpickup, 1, sound3d.fxClass(all, player));
            return;
        }
    }

    /// An idle tower picks one admitted opponent uniformly. The carrier and, in team games,
    /// members of the carrier's team are skipped.
    fn target(round: *Round, world: gameobj.World, index: u16) void {
        const all = world.objects;
        const tower = &all.slots[index];
        if (tower.object.gone()) return;
        const ctx: orders.Context = .of(world);
        const carrier = if (round.carrier) |pilot| pilot.participant.slot else null;
        if (tower.current()) |order| switch (order.order) {
            .fire_ion_cannon, .deathmatch_dark_reign_target, .dark_reign_shoot => {
                if (carrier != null and carrier == order.target.slotIn(all)) {
                    orders.end(ctx, index);
                } else return;
            },
            .explode => return,
            else => {},
        };
        const team = if (all.arena_scores == .teams) (if (round.carrier) |pilot| all.participantTeam(pilot.participant) else null) else null;
        if (tower.waiting().len != 0) return;
        var candidates: [deathmatch.spawn.positions]u16 = undefined;
        var count: u15 = 0;
        for (0..@min(all.playerSlotCount(), candidates.len)) |i| {
            const pilot = all.playerBinding(@intCast(i)) orelse continue;
            if (!all.hasBoundPlayerShip(@intCast(i)) or @as(u16, @intCast(i)) == carrier) continue;
            if (team != null and all.participantTeam(pilot.participant) == team) continue;
            candidates[count] = @intCast(i);
            count += 1;
        }
        if (count == 0) return;
        // As in dark_reign_frame, select before the delay. If that pilot takes the relay
        // during the delay, the active order will be cancelled before it can fire.
        const chosen = candidates[world.random.below(count)];
        orders.queue(ctx, index, .{ .order = .dark_reign_shoot, .target = .at(chosen, null), .sequence = 0, .data = .{ .words = @splat(0) } }, target_delay, @truncate(world.random.rand()));
    }
};

test "the carrier is immune to targeting, drops the relay on death and leaves it in place on departure" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const first = try mission.add(.of(.predator), .{ 1000, 0, 0 });
    const second = try mission.add(.of(.predator), .{ 40000, 0, 0 });
    const teammate = try mission.add(.of(.predator), .{ 20000, 0, 0 });
    all.players = 3;
    all.arena_scores = .{ .teams = .initFill(.{}) };
    const relay = try mission.add(.of(.comms_relay), mission.slot(first).drawn.position);
    const tower = try mission.add(.of(.darkreign), .{ 80000, 0, 0 });
    mission.slot(relay).object.radius = 40;
    mission.slot(first).object.radius = 10;
    var round = try Round.start(all);
    const owner = all.joinParticipant(first).?;
    _ = all.bindParticipant(owner, .of(all, first)).?;
    _ = all.setParticipantTeam(owner, .first);
    var world = mission.world();
    world.damage_rules = .{ .arena = null };
    round.collect(world, relay);
    try std.testing.expectEqual(null, round.carrier);

    const target = all.joinParticipant(second).?;
    _ = all.bindParticipant(target, .of(all, second)).?;
    _ = all.setParticipantTeam(target, .second);
    const allied = all.joinParticipant(teammate).?;
    _ = all.bindParticipant(allied, .of(all, teammate)).?;
    _ = all.setParticipantTeam(allied, .first);
    round.frame(world);
    try std.testing.expectEqual(owner, round.carrier.?.participant);
    try std.testing.expect(mission.slot(relay).object.flags.disabled);
    const order = mission.slot(tower).waiting()[0];
    try std.testing.expectEqual(second, order.entry.target.resolve(all).slotIn(all));
    try std.testing.expectEqual(target_delay, order.due);

    objects.setPosition(&mission.slot(first).object, &mission.slot(first).drawn, .{ 8000, 0, 0 });
    round.drop(all, first);
    try std.testing.expectEqual(null, round.carrier);
    try std.testing.expectEqual(@as(math.Vector, .{ 8008, 0, 0 }), mission.slot(relay).object.position());
    try std.testing.expect(!mission.slot(relay).object.flags.disabled);

    round.collect(world, relay);
    try std.testing.expectEqual(owner, round.carrier.?.participant);
    objects.setPosition(&mission.slot(first).object, &mission.slot(first).drawn, .{ 9000, 0, 0 });
    round.leave(all, first);
    try std.testing.expectEqual(null, round.carrier);
    try std.testing.expectEqual(@as(math.Vector, .{ 8008, 0, 0 }), mission.slot(relay).object.position());
    try std.testing.expect(!mission.slot(relay).object.flags.disabled);
}
