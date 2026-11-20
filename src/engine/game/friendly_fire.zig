//! Moose warns pilots who hit friendly ships (`0x00474B20` to `0x004751A5`). If a pilot destroys
//! a friend, the Friendly Fire order (117) sends their ship back to its carrier. **Unknown:** the
//! original source file. The code follows the motion routines, between `explode.cpp` and
//! `gameflow.cpp`. See `docs/engine/orders.md`.
//!
//! In co-op the host owns recall decisions and addresses radio lines to the affected pilots.

const std = @import("std");
const assert = std.debug.assert;

const math = @import("../surrender/math.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const ailand = @import("ailand.zig");
const create = @import("create.zig");
const players = @import("players.zig");
const collision = @import("collision.zig");
const gameobj = @import("gameobj.zig");
const input = @import("../input.zig");
const radio = @import("radio.zig");

/// The damage and cooldown for a pilot's warnings. `friendly_fire_reset` (`0x00474B20`) clears
/// them at mission start.
pub const Warnings = struct {
    /// The player's damage to friends since the last warning (`friendly_fire_damage`,
    /// `0x00562CEC`).
    damage: f32 = 0,
    /// The original caps its warning count at `held_count` (`friendly_fire_count`, `0x00562CF0`).
    count: u8 = 0,
    /// The game's tick up to which no warning comes (`friendly_fire_quiet_until`, `0x00562CE8`).
    quiet_until: u32 = 0,
};

/// The damage past which Moose warns the player (`0x004DC5EC`), and how long after a warning the
/// next may come, in the game's ticks (`0x00474CED`).
const warn_over: f32 = 800;
const warn_every: u32 = 3000;

/// The count of warnings the game holds at (`0x00474CD1`): it takes a second back to the first, so
/// the lines for a second warning (`ff_005` to `ff_008`, `0x00500830`) and a third (`ff_009` to
/// `ff_012`, `0x00500840`) are never said, and the warnings never stop, as they would after the
/// third.
const held_count = 1;

/// Moose's first warnings (`0x00500820`).
const warnings = [_][]const u8{ "ff_001.ut", "ff_002.ut", "ff_003.ut", "ff_004.ut" };

/// Friendly-fire rules apply to shots, Screamers and collisions with friendly objects
/// (`0x00463F6D`). The component damage path already excludes collisions.
fn friendlyHit(world: gameobj.World, index: u16, kind: collision.Kind) bool {
    if (world.objects.slots[index].object.side != .friendly) return false;
    return switch (kind) {
        .bullet, .screamer, .collision => true,
        else => false,
    };
}

/// `friendly_fire_warning` (`0x00474C80`) adds scaled damage to the pilot's total. Moose queues
/// a line and clears the total when the damage and cooldown both pass their limits. The original
/// skips warnings in arena missions at `0x00474C87`.
pub fn warn(world: gameobj.World, index: u16, attacker: gameobj.DamageSource, kind: collision.Kind, damage: f32) void {
    if (!friendlyHit(world, index, kind)) return;
    const all = world.objects;
    const audience = shooter(world, attacker) orelse return;
    const kept = &all.player_states[attacker.object.slot].friendly_fire;
    kept.damage += damage;
    if (kept.damage <= warn_over or kept.quiet_until >= world.clock.game_ticks) return;
    kept.count = @min(kept.count + 1, held_count);
    kept.quiet_until = world.clock.game_ticks +% warn_every;
    kept.damage = 0;
    radio.mooseSaysOneOfTo(world, audience, &warnings);
}

fn shooter(world: gameobj.World, source: gameobj.DamageSource) ?collision.HitFeedback.Audience {
    const all = world.objects;
    return switch (world.damage_rules) {
        .campaign => if (source.resolve(all) == all.player) .local else null,
        .cooperative => .{ .participant = all.playerBindingFor(source.object, source.participant_generation) orelse return null },
        .arena => null,
    };
}

/// `cmd_FriendlyFire` (0x00459F30) has no target and calls `player_friend_destroyed(0)`.
/// The original mission command recalls the local pilot on each machine running the script.
/// The host applies that command once to the bound co-op pilots.
pub fn scriptRecall(world: gameobj.World) void {
    const all = world.objects;
    switch (world.damage_rules) {
        .campaign => all.slots[all.player].object.sent_home = .friend_destroyed,
        .cooperative => markCrew(world, .friend_destroyed),
        .arena => {},
    }
}

/// `player_friend_destroyed` (0x00474E00). Armour damage checks the object's protection;
/// component damage also checks that the part whose armour ran out was the hull (0x00464951).
pub fn destroyed(world: gameobj.World, index: u16, source: gameobj.DamageSource, kind: collision.Kind, hull: bool) void {
    if (!friendlyHit(world, index, kind)) return;
    const all = world.objects;
    const object = &all.slots[index].object;
    const player_only = object.invulnerable == .player_can_hit;
    if (object.flags.ejected and kind == .collision and !player_only) return;
    const audience = shooter(world, source) orelse return;
    switch (audience) {
        .local => all.slots[all.player].object.sent_home = .friend_destroyed,
        .participant => |binding| {
            const state = &all.player_states[binding.participant.slot];
            if (state.membership.joined.ending != .playing) return;
            if (hull and player_only) {
                state.recall = .told;
                markCrew(world, .crew_abort);
            } else if (state.recall == .none) state.recall = .friend_destroyed;
        },
    }
}

/// The original message 0x49 leaves an existing mark intact (0x004B9389).
fn markCrew(world: gameobj.World, mark: gameobj.SentHome) void {
    const all = world.objects;
    for (all.player_states[0..all.playerSlotCount()], 0..) |*state, i| {
        if (all.playerBinding(@intCast(i)) == null) continue;
        if (state.recall == .none and state.membership.joined.ending == .playing) state.recall = mark;
    }
}

/// `friendly_fire_send_home` (0x00474B40) runs after orders. The campaign runs the
/// pilot's return. The original starts Friendly Fire on the recalled pilot's machine
/// and gives Jump Out to remote copies. The shared host runs the recalled pilot's
/// original timers for each affected ship.
pub fn sendHome(ctx: aigeneric.Context) void {
    const world = ctx.world;
    const all = world.objects;
    switch (world.damage_rules) {
        .campaign => {
            const slot = &all.slots[all.player];
            const object = &slot.object;
            if (object.flags.outOfAction() or object.sent_home == .none or world.player.ending != .playing) return;
            const current = slot.current() orelse return;
            if (aigeneric.prioritised(all, current.order)) return;
            world.player.ending = endingFor(object.sent_home);
            _ = aigeneric.give(ctx, all.player, .friendly_fire, current.target.asShip(all));
            object.flags.sent_off = true;
        },
        .cooperative => {
            for (all.player_states[0..all.playerSlotCount()], 0..) |*state, i| {
                if (state.recall == .none) continue;
                const binding = all.playerBinding(@intCast(i)) orelse continue;
                sendParticipantHome(ctx, binding, state.recall);
            }
        },
        .arena => {},
    }
}

/// Finish a co-op recall after the last active pilot leaves and the shared jumps finish.
pub fn recallComplete(all: *const create.Objects) bool {
    var recalled = false;
    for (all.player_states[0..all.playerSlotCount()], 0..) |state, i| {
        if (state.membership != .joined) continue;
        if (state.membership.joined.ending == .ejecting) return false;
        recalled = recalled or state.membership.joined.ending.sentHome();
        if (all.playerBinding(@intCast(i)) == null) continue;
        const slot = &all.slots[i];
        if (!slot.object.flags.outOfAction() or slot.running(.friendly_fire) != null or slot.running(.jump_out) != null) return false;
        if (slot.running(.land) != null and !state.landed) return false;
    }
    return recalled;
}

fn endingFor(mark: gameobj.SentHome) @import("main.zig").Ending {
    return if (mark == .crew_abort) ._unknown_7 else .friendly_fire;
}

fn sendParticipantHome(ctx: aigeneric.Context, binding: players.ControlRef, mark: gameobj.SentHome) void {
    const world = ctx.world;
    const all = world.objects;
    const index = binding.participant.slot;
    const slot = &all.slots[index];
    if (slot.object.flags.outOfAction()) return;
    if (slot.current()) |order| if (aigeneric.prioritised(all, order.order)) return;
    const target: aigeneric.Target = if (slot.current()) |order| order.target.asShip(all) else .none;
    if (!aigeneric.give(ctx, index, .friendly_fire, target)) return;
    // An order hook can change the ship before the push returns.
    if (!std.meta.eql(all.playerBinding(index), @as(?players.ControlRef, binding))) return;
    const state = &all.player_states[index];
    state.recall = .none;
    state.membership.joined.ending = endingFor(mark);
    slot.object.sent_home = mark;
    slot.object.flags.sent_off = true;
}

/// What Friendly Fire keeps in the object's order state.
pub const State = extern struct {
    stage: Stage,
    /// The frame's start at which the stage ends.
    until: i32,
    _unknown_08: [aigeneric.state_size - 0x08]u8,

    comptime {
        assert(@offsetOf(State, "until") == 0x4);
        assert(@sizeOf(State) == aigeneric.state_size);
    }
};

/// Friendly Fire's stages.
pub const Stage = enum(i32) {
    /// The player flies on as Moose speaks.
    speaking = 0,
    /// The ship is steered toward its carrier, the player's controls holding a share.
    steering = 1,
    /// The ship lands.
    landing = 2,
    _,
};

/// How long the player flies on, and how long the ship is steered toward its carrier, in ticks
/// (`0x00474E79`, `0x0047518A`).
const speaking_ticks = 300;
const steering_ticks = 700;

/// Moose's words as the player is sent home (`0x00500850`); and the carrier's abort (`0x00500990`),
/// said by pilot 27 for the Reliant (`0x00474F08`) and 28 for any other (`0x00474F15`).
const home_lines = [_][]const u8{ "ff_013.ut", "ff_014.ut", "ff_015.ut", "ff_016.ut", "ff_017.ut", "ff_018.ut", "ff_019.ut", "ff_020.ut", "ff_021.ut", "ff_022.ut", "ff_023.ut" };
const abort_line = "abrt_001.ut";
const reliant_aborts: u16 = 0x1B;
const other_aborts: u16 = 0x1C;

/// `order_friendly_fire_init` (`0x00474E60`): the player flies on for `speaking_ticks` as Moose
/// says it is to go home; a ship marked by a multiplayer game hears its carrier abort the mission
/// instead.
///
/// **Fix:** the game reads the carrier's type through a null pointer where the player launched
/// from no carrier; OpenReliant has the other carriers' pilot say it.
pub fn init(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const slot = &world.objects.slots[index];
    slot.state.friendly_fire.stage = .speaking;
    slot.state.friendly_fire.until = ctx.world.clock.frame_start + speaking_ticks;
    if (world.damage_rules == .cooperative) {
        const pilot = world.objects.playerBinding(index) orelse return;
        recallLine(world, .{ .participant = pilot }, slot.object.sent_home, world.objects.player_states[index].carrier);
    } else recallLine(world, .local, slot.object.sent_home, world.player.carrier);
}

fn recallLine(world: gameobj.World, audience: collision.HitFeedback.Audience, mark: gameobj.SentHome, carrier: ?gameobj.ObjectRef) void {
    switch (mark) {
        .told, .crew_abort => {
            const index = if (carrier) |ship| ship.resolve(world.objects) else null;
            const reliant = if (index) |i| world.objects.slots[i].object.type.base() == .reliant else false;
            radio.pilotSaysTo(world, audience, if (reliant) reliant_aborts else other_aborts, .talking, abort_line, .queued, .looping, radio.no_expiry);
        },
        else => radio.mooseSaysOneOfTo(world, audience, &home_lines),
    }
}

/// How the steering toward the carrier mixes with the player's controls (`0x004DC484`,
/// `0x004DC4C0`): the player's throttle and turns at `players_share`, the AI's turns at the rest.
const players_share: f32 = 0.7;
const steering_share: f32 = 0.3;

/// How far from its carrier the ship jumps out rather than flying there (`0x004DC4F8`).
const jump_beyond: f32 = 1_000_000;

fn returnCarrier(world: gameobj.World, index: u16) ?u16 {
    if (world.damage_rules != .cooperative) return ailand.landingCarrier(world);
    const all = world.objects;
    const carrier = (all.player_states[index].carrier orelse return null).resolve(all) orelse return null;
    return switch (all.slots[carrier].landing orelse return null) {
        .reliant, .yamato => carrier,
        else => null,
    };
}

/// `order_friendly_fire` (`0x00474F20`): while Moose speaks, the player flies on
/// (`input.playerControlOrder`); then for `steering_ticks` the ship is steered toward the carrier
/// the player launched from (`ai.steer`), the player's controls keeping `players_share` of the
/// throttle and the turns; then the order ends, and the ship lands on the carrier, jumping out
/// first where it is farther than `jump_beyond`, out of the action. The game also clears the
/// carrier's stand-in flag.
///
/// **Fix:** the game reads the carrier through a null pointer where the player launched from
/// none; OpenReliant lets the ship fly on as the player has it, and then ends the order. It does
/// the same where the player's carrier offers no landing (`ailand.landingCarrier`), which only a
/// mod or a mission's script makes so.
pub fn update(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.friendly_fire;
    const now = ctx.world.clock.frame_start;
    switch (state.stage) {
        .speaking => {
            if (state.until >= now) return input.playerControlOrder(ctx, index);
            state.stage = .steering;
            state.until = now + steering_ticks;
        },
        .steering => {
            if (state.until < now) {
                state.stage = .landing;
                return;
            }
            input.playerControlOrder(ctx, index);
            const carrier = returnCarrier(world, index) orelse return;
            steerHome(world, index, all.slots[carrier].object.nextPosition());
        },
        .landing => {
            const carrier = returnCarrier(world, index);
            if (world.damage_rules == .cooperative) {
                // 0x00474F20 distinguishes a carrier recall from ordinary friendly fire.
                // Other pilots see the departure (0x00474BFE); only this pilot sees the landing.
                const membership = &all.player_states[index].membership;
                if (membership.* == .joined)
                    membership.joined.ending_scene = recallScene(all, slot, carrier);
                slot.object.flags.sent_off = false;
                aigeneric.end(ctx, index);
                _ = aigeneric.giveShip(ctx, index, .jump_out, index, null);
                slot.object.flags.sent_off = true;
                return;
            }
            slot.object.flags.sent_off = false;
            aigeneric.end(ctx, index);
            const landed_on = carrier orelse return;
            const home = &all.slots[landed_on].object;
            home.flags.stand_in = false;
            _ = aigeneric.giveShip(ctx, index, .land, landed_on, null);
            const from = slot.object.nextPosition();
            if (math.distance(home.nextPosition(), from) > jump_beyond) {
                _ = aigeneric.giveShip(ctx, index, .jump_out, index, null);
            }
            slot.object.flags.sent_off = true;
        },
        _ => {},
    }
}

fn recallScene(all: *const create.Objects, slot: *const create.Slot, carrier: ?u16) @import("players.zig").EndingScene {
    switch (slot.object.sent_home) {
        .told, .crew_abort => {},
        else => return .jump_out,
    }
    const home = &all.slots[carrier orelse return .jump_out];
    const jumps = math.distance(home.object.nextPosition(), slot.object.nextPosition()) > jump_beyond;
    return switch (home.landing orelse return .jump_out) {
        .yamato => if (jumps) .jump_to_yamato else .yamato_landing,
        .reliant => if (jumps) .jump_to_reliant else .reliant_landing,
        else => .jump_out,
    };
}

/// The ship in slot `index` steered toward `home`, the player's controls, just read, keeping
/// `players_share` of the throttle and the turns.
fn steerHome(world: gameobj.World, index: u16, home: math.Vector) void {
    const object = &world.objects.slots[index].object;
    const throttle = object.throttle;
    const roll = object.roll_input;
    const pitch = object.pitch_input;
    const yaw = object.yaw_input;
    _ = ai.steer(world, index, home, ai.full_limit, ai.no_ease, .{});
    // The game zeroes the throttle before it mixes, so the AI's share of it is nothing.
    object.throttle = throttle * players_share;
    object.roll_input = mix(object.roll_input, roll);
    object.pitch_input = mix(object.pitch_input, pitch);
    object.yaw_input = mix(object.yaw_input, yaw);
}

/// A turn `steered` toward the carrier, mixed with the player's `own`.
fn mix(steered: f32, own: f32) f32 {
    return steered * steering_share + own * players_share;
}

test warn {
    var heard: radio.testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    const world = heard.world();
    const all = world.objects;
    const pilot: gameobj.DamageSource = .of(all, all.player);
    const enemy: gameobj.DamageSource = .of(all, heard.enemy);
    const kept = &all.player_states[all.player].friendly_fire;
    const clock = &heard.mission.clock;
    clock.game_ticks = 100;

    // The player's shots on a friend mount up; past `warn_over`, Moose warns the player.
    warn(world, heard.wingman, pilot, .bullet, 500);
    try std.testing.expectEqual(0, heard.radio.count);
    warn(world, heard.wingman, pilot, .bullet, 500);
    try heard.expectLine(0, radio.pilot_base + 4, &warnings);
    try std.testing.expectEqual(0, kept.damage);
    try std.testing.expectEqual(100 + warn_every, kept.quiet_until);
    // Within the quiet, the damage mounts unsaid; after it, the count holds at one.
    heard.radio.reset(&heard.speaker.asked);
    warn(world, heard.wingman, pilot, .screamer, 900);
    try std.testing.expectEqual(0, heard.radio.count);
    clock.game_ticks = 101 + warn_every;
    warn(world, heard.wingman, pilot, .collision, 1);
    try std.testing.expectEqual(1, heard.radio.count);
    try std.testing.expectEqual(held_count, kept.count);
    // Hits on enemies, missile hits and another ship's hits do not count.
    heard.radio.reset(&heard.speaker.asked);
    clock.game_ticks += 2 * warn_every;
    warn(world, heard.enemy, pilot, .bullet, 1000);
    warn(world, heard.wingman, pilot, .missile, 1000);
    warn(world, heard.wingman, enemy, .bullet, 1000);
    try std.testing.expectEqual(0, kept.damage);
    try std.testing.expectEqual(0, heard.radio.count);
}

test "hosted friendly-fire warnings track each shooter across damage paths" {
    const objects = @import("objects.zig");
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.data[0].part.flags.component = true;
    model.data[0].part.component_armor = 100;
    var heard: radio.testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    const mission = &heard.mission;
    var host = mission.world();
    host.damage_rules = .cooperative;
    const all = host.objects;
    const first = all.player;
    const second = heard.wingman;
    all.players = 2;
    const first_pilot = all.joinParticipant(first).?;
    const second_pilot = all.joinParticipant(second).?;
    const first_binding = all.bindParticipant(first_pilot, .of(all, first)).?;
    const second_binding = all.bindParticipant(second_pilot, .of(all, second)).?;
    const first_state = &all.player_states[first].friendly_fire;
    const second_state = &all.player_states[second].friendly_fire;

    const Notice = collision.HitFeedback.Addressed;
    const Recorder = struct {
        notice: ?Notice = null,

        fn enqueue(context: *anyopaque, notice: Notice) void {
            if (notice.effect != .radio_line) return;
            const recorder: *@This() = @ptrCast(@alignCast(context));
            recorder.notice = notice;
        }
    };
    var recorder: Recorder = .{};
    host.hit_feedback = .{ .context = &recorder, .enqueue = Recorder.enqueue };
    const friend = try mission.addWith(model.types(), .of(.kamov), .{ 0, 0, 3000 });
    const target = mission.slot(friend);
    target.object.side = .friendly;
    target.object.shields = .all(5000);
    target.object.armor = .all(5000);
    const part: objects.PartRef = .{ .model = &target.model.?, .index = 0 };
    const clock = &mission.clock;
    clock.game_ticks = 100;
    clock.frame_start = 150;
    const old_shot: gameobj.DamageSource = .of(all, second);
    const random_before = mission.random.fingerprint();

    collision.damage(host, friend, .fore, 600, 1, first, .bullet);
    collision.damageFrom(host, friend, .fore, 450, 1, old_shot, .bullet);
    collision.armorDamageFrom(host, friend, .fore, 350, old_shot, .collision);
    try std.testing.expectEqual(warn_over, second_state.damage);
    try std.testing.expect(recorder.notice == null);
    collision.componentDamageFrom(host, friend, part, 1, old_shot, .screamer);
    const second_warning = recorder.notice.?;
    try std.testing.expectEqual(second_binding, second_warning.recipient);
    try std.testing.expectEqual(clock.frame_start, second_warning.tick);
    try std.testing.expectEqual(0, second_state.damage);
    try std.testing.expectEqual(600, first_state.damage);

    recorder.notice = null;
    clock.game_ticks = second_state.quiet_until;
    collision.damageFrom(host, friend, .fore, 850, 1, old_shot, .bullet);
    try std.testing.expectEqual(850, second_state.damage);
    try std.testing.expect(recorder.notice == null);
    collision.armorDamage(host, friend, .fore, 201, first, .collision);
    const first_warning = recorder.notice.?;
    try std.testing.expectEqual(first_binding, first_warning.recipient);
    try std.testing.expectEqual(random_before, mission.random.fingerprint());

    const client = heard.world();
    try std.testing.expect(!second_warning.present(client));
    all.player = second;
    radio.mooseSays(client, "plck_001.ut", .queued, radio.no_expiry);
    try std.testing.expect(second_warning.present(client));
    try std.testing.expectEqual(2, heard.radio.count);
    try heard.expectLine(1, radio.pilot_base + 4, &warnings);
    try std.testing.expectEqual(null, heard.queued(1).expiry);

    try std.testing.expect(create.Objects.leaveParticipant(host, second_pilot));
    const rejoined = all.joinParticipant(second).?;
    _ = all.bindParticipant(rejoined, second_binding.ship).?;
    recorder.notice = null;
    clock.game_ticks += 1;
    collision.damageFrom(host, friend, .fore, 900, 1, old_shot, .bullet);
    try std.testing.expect(!second_warning.present(client));
    try std.testing.expectEqual(0, second_state.damage);
    try std.testing.expect(recorder.notice == null);

    host.damage_rules = .{ .arena = null };
    collision.damage(host, friend, .fore, 900, 1, second, .bullet);
    try std.testing.expectEqual(0, second_state.damage);
    try std.testing.expect(recorder.notice == null);
}

test mix {
    try std.testing.expectApproxEqAbs(steering_share + players_share * -0.5, mix(1, -0.5), 1e-6);
    try std.testing.expectApproxEqAbs(players_share, mix(0, 1), 1e-6);
}

test "a collision with a friendly pod recalls the pilot only when the pod takes player hits alone" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    _ = try mission.add(.of(.predator), @splat(0));
    const friend = try mission.add(.of(.predator), .{ 0, 0, 1000 });
    const by: gameobj.DamageSource = .of(world.objects, 0);
    mission.slot(friend).object.flags.ejected = true;
    destroyed(world, friend, by, .collision, true);
    try std.testing.expectEqual(.none, mission.slot(0).object.sent_home);
    mission.slot(friend).object.invulnerable = .player_can_hit;
    destroyed(world, friend, by, .collision, true);
    try std.testing.expectEqual(.friend_destroyed, mission.slot(0).object.sent_home);
}

test "a player who destroys a friend is sent home, and lands" {
    var heard: radio.testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    const world = heard.world();
    const all = heard.mission.objects;
    const ctx: aigeneric.Context = .of(world);
    const player = &all.slots[0];
    const reliant = try heard.mission.add(.of(.reliant), .{ 0, 0, 5000 });
    heard.mission.player.carrier = .of(heard.mission.objects, reliant);
    _ = try aigeneric.pushShip(ctx, 0, .player_control, heard.enemy, null);

    // Unmarked, the ship flies on.
    sendHome(ctx);
    try std.testing.expectEqual(.playing, heard.mission.player.ending);
    // Marked, the mission ends with the friendly fire, and the ship takes Friendly Fire.
    scriptRecall(world);
    sendHome(ctx);
    try std.testing.expectEqual(.friendly_fire, heard.mission.player.ending);
    try std.testing.expectEqual(.friendly_fire, player.current().?.order);
    try std.testing.expect(player.object.flags.sent_off);

    // As it starts, Moose says so, and the player flies on a while.
    heard.mission.clock.frame_start = 1000;
    init(ctx, 0);
    try heard.expectLine(0, radio.pilot_base + 4, &home_lines);
    try std.testing.expectEqual(1000 + speaking_ticks, player.state.friendly_fire.until);
    heard.mission.clock.frame_start += speaking_ticks + 1;
    update(ctx, 0);
    try std.testing.expectEqual(.steering, player.state.friendly_fire.stage);
    // Steered toward the carrier, the player's throttle held to its share.
    player.object.throttle = ai.full_throttle;
    update(ctx, 0);
    try std.testing.expectApproxEqAbs(players_share, player.object.throttle, 1e-6);
    heard.mission.clock.frame_start += steering_ticks + 1;
    update(ctx, 0);
    try std.testing.expectEqual(.landing, player.state.friendly_fire.stage);
    // Then it lands on the carrier, near enough not to jump.
    update(ctx, 0);
    try std.testing.expectEqual(.land, player.current().?.order);
    try std.testing.expectEqual(reliant, player.current().?.target.slotIn(all).?);
    try std.testing.expect(player.object.flags.sent_off);
}

test "a player sent home to a carrier that offers no landing flies on" {
    var heard: radio.testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    const world = heard.world();
    const all = heard.mission.objects;
    const ctx: aigeneric.Context = .of(world);
    const player = &all.slots[0];
    heard.mission.player.carrier = .of(heard.mission.objects, try heard.mission.add(.of(.victorious), .{ 0, 0, 5000 }));
    _ = try aigeneric.pushShip(ctx, 0, .player_control, heard.enemy, null);
    scriptRecall(world);
    sendHome(ctx);
    heard.mission.clock.frame_start = 1000;
    init(ctx, 0);
    // Past Moose's words and the steering, the order ends, and the player flies on as before.
    heard.mission.clock.frame_start += speaking_ticks + 1;
    update(ctx, 0);
    heard.mission.clock.frame_start += steering_ticks + 1;
    update(ctx, 0);
    update(ctx, 0);
    try std.testing.expectEqual(.player_control, player.current().?.order);
    try std.testing.expect(!player.object.flags.sent_off);
}

test "co-op recall, crew abort and mission-script recall follow the pilots across cockpit changes" {
    const main = @import("main.zig");
    const Notice = collision.HitFeedback.Addressed;
    const Recorder = struct {
        lines: [2]Notice = undefined,
        count: usize = 0,

        fn enqueue(context: *anyopaque, notice: Notice) void {
            if (notice.effect != .radio_line) return;
            const recorder: *@This() = @ptrCast(@alignCast(context));
            recorder.lines[recorder.count] = notice;
            recorder.count += 1;
        }
    };
    const Case = enum { ordinary, crew_abort, scripted };
    for (std.enums.values(Case)) |case| {
        for ([_]u16{ 0, 1 }) |viewer| {
            var heard: radio.testing.Heard = undefined;
            try heard.init();
            defer heard.deinit();
            const mission = &heard.mission;
            var world = mission.world();
            world.damage_rules = .cooperative;
            const all = world.objects;
            all.players = 2;
            all.player = viewer;
            var recorder: Recorder = .{};
            world.hit_feedback = .{ .context = &recorder, .enqueue = Recorder.enqueue };
            const ctx: aigeneric.Context = .of(world);
            for (0..2) |i| {
                const index: u16 = @intCast(i);
                const ref = all.joinParticipant(index).?;
                _ = all.bindParticipant(ref, .of(all, index)).?;
                _ = try aigeneric.push(ctx, index, .multiplayer_control, .none);
            }
            const reliant = try mission.add(.of(.reliant), @splat(0));
            mission.slot(reliant).landing = .reliant;
            const home: math.Vector = .{ 0, 0, if (viewer == 0) 40_000 else 2_000_000 };
            const yamato = try mission.add(.of(.yamato), home);
            mission.slot(yamato).landing = .yamato;
            all.player_states[0].carrier = .of(all, yamato);
            all.player_states[1].carrier = .of(all, reliant);
            const target = mission.slot(heard.enemy);
            target.object.side = .friendly;
            target.object.armor = .all(1);
            switch (case) {
                .scripted => scriptRecall(world),
                .ordinary, .crew_abort => {
                    if (case == .crew_abort) {
                        target.object.invulnerable = .player_can_hit;
                        target.object.flags.ejected = true;
                    }
                    collision.armorDamage(world, heard.enemy, .fore, 50, 1, .bullet);
                },
            }
            sendHome(ctx);
            sendHome(ctx);
            for (0..2) |i| {
                if (all.slots[i].running(.friendly_fire) != null) aigeneric.objectOrders(ctx, @intCast(i));
            }
            try std.testing.expectEqual(.playing, world.player.ending);
            try std.testing.expectEqual(.friendly_fire, all.player_states[1].membership.joined.ending);
            try std.testing.expectEqual(if (case == .ordinary) @as(usize, 1) else 2, recorder.count);
            try std.testing.expectEqual(switch (case) {
                .ordinary => main.Ending.playing,
                .crew_abort => main.Ending._unknown_7,
                .scripted => main.Ending.friendly_fire,
            }, all.player_states[0].membership.joined.ending);
            for (recorder.lines[0..recorder.count], 0..) |line, i| {
                const index: u16 = if (case == .ordinary) 1 else @intCast(i);
                try std.testing.expectEqual(all.playerBinding(index).?, line.recipient);
                try std.testing.expect(all.slots[index].running(.friendly_fire) != null);
                try std.testing.expect(all.slots[index].object.flags.sent_off);
                const client = heard.world();
                all.player = index;
                try std.testing.expect(line.present(client));
                if (case == .crew_abort) {
                    const pilot: i32 = if (index == 1) reliant_aborts else other_aborts;
                    try heard.expectLine(i, radio.pilot_base + pilot, &.{abort_line});
                } else try heard.expectLine(i, radio.pilot_base + 4, &home_lines);
            }

            all.player = viewer;
            try std.testing.expect(!main.missionOver(world));
            for (0..300) |_| {
                mission.clock.frame_duration = 10;
                mission.clock.frame_start += 10;
                for (0..2) |i| if (all.slots[i].running(.friendly_fire) != null or all.slots[i].running(.jump_out) != null) {
                    aigeneric.objectOrders(ctx, @intCast(i));
                };
                if (all.slots[1].object.flags.disabled and
                    (case == .ordinary or all.slots[0].object.flags.disabled)) break;
            }
            try std.testing.expect(all.slots[1].object.flags.disabled);
            try std.testing.expectEqual(case != .ordinary, all.slots[0].object.flags.disabled);
            try std.testing.expectEqual(case != .ordinary, main.missionOver(world));
            const EndingScene = @import("players.zig").EndingScene;
            const lead_scene: EndingScene = switch (case) {
                .ordinary => .none,
                .scripted => .jump_out,
                .crew_abort => if (viewer == 0) .yamato_landing else .jump_to_yamato,
            };
            try std.testing.expectEqual(lead_scene, all.player_states[0].membership.joined.ending_scene);
            try std.testing.expectEqual(if (case == .crew_abort) EndingScene.reliant_landing else .jump_out, all.player_states[1].membership.joined.ending_scene);
            try std.testing.expectEqual(home, all.slots[yamato].object.nextPosition());
            try std.testing.expectEqual(@as(math.Vector, @splat(0)), all.slots[reliant].object.nextPosition());
            if (case != .ordinary) {
                try std.testing.expectEqual(.friendly_fire, world.player.ending);
                try std.testing.expectEqual(all.player_states[viewer].membership.joined.ending, main.displayedEnding(all, world.player));
            }
            all.reset(&mission.random);
            try std.testing.expectEqual(.playing, all.player_states[1].membership.joined.ending);
            try std.testing.expect(!main.missionOver(world));
        }
    }
}

test "a pending co-op recall and old damage cannot follow a new admission on the same ship" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var world = mission.world();
    world.damage_rules = .cooperative;
    const ctx: aigeneric.Context = .of(world);
    const all = world.objects;
    const pilot = try mission.add(.of(.predator), @splat(0));
    const friend = try mission.add(.of(.predator), @splat(0));
    const ref = all.joinParticipant(pilot).?;
    const binding = all.bindParticipant(ref, .of(all, pilot)).?;
    const old: gameobj.DamageSource = .of(all, pilot);
    _ = try aigeneric.push(ctx, pilot, .jump_in, .none);
    destroyed(world, friend, old, .bullet, true);
    sendHome(ctx);
    const state = &all.player_states[pilot];
    try std.testing.expectEqual(.friend_destroyed, state.recall);
    try std.testing.expectEqual(.playing, state.membership.joined.ending);
    try std.testing.expect(create.Objects.leaveParticipant(world, ref));
    const next = all.joinParticipant(pilot).?;
    _ = all.bindParticipant(next, binding.ship).?;
    mission.slot(friend).object.invulnerable = .player_can_hit;
    destroyed(world, friend, old, .bullet, true);
    try std.testing.expectEqual(.none, state.recall);
    world.damage_rules = .{ .arena = null };
    destroyed(world, friend, .of(all, pilot), .bullet, true);
    scriptRecall(world);
    sendHome(ctx);
    try std.testing.expectEqual(.none, state.recall);
    try std.testing.expectEqual(.none, mission.slot(pilot).object.sent_home);
}

test "losing a player-only friendly component aborts co-op only for a hull" {
    const objects = @import("objects.zig");
    const gpa = std.testing.allocator;
    var model: create.testing.Model = undefined;
    try model.init(gpa);
    defer model.deinit(gpa);
    model.data[0].part.flags.component = true;
    model.data[0].part.component_armor = 100;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var host = mission.world();
    host.damage_rules = .cooperative;
    const all = host.objects;
    all.players = 2;
    for (0..2) |_| {
        const ship = try mission.add(.of(.predator), @splat(0));
        const pilot = all.joinParticipant(ship).?;
        _ = all.bindParticipant(pilot, .of(all, ship)).?;
    }
    const friend = try mission.addWith(model.types(), .of(.kamov), @splat(0));
    const slot = mission.slot(friend);
    slot.object.side = .friendly;
    slot.object.invulnerable = .player_can_hit;
    const part: objects.PartRef = .{ .model = &slot.model.?, .index = 0 };
    part.part().class = .none;
    collision.componentDamage(host, friend, part, 150, 0, .bullet);
    try std.testing.expectEqual(.friend_destroyed, all.player_states[0].recall);
    try std.testing.expectEqual(.none, all.player_states[1].recall);
    part.part().class = .hull;
    part.part().armor = 100;
    collision.componentDamage(host, friend, part, 150, 1, .screamer);
    try std.testing.expectEqual(.told, all.player_states[1].recall);
    try std.testing.expectEqual(.friend_destroyed, all.player_states[0].recall);
}
