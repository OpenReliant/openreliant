//! The player's hits on friends (`0x00474B20` to `0x004751A5`): Moose's warnings as the damage
//! mounts (`warn`), and the player sent home for destroying a friend (`friendDestroyed`,
//! `sendHome`), by the Friendly Fire order (117, `init`, `update`), which lands the ship on its
//! carrier. **Unknown:** its source file. The code lies after the motion routines', between
//! `explode.cpp`'s and `gameflow.cpp`'s, and no string places it; this module is named for what it
//! does. docs/engine/orders.md describes it.
//!
//! Not ported: a multiplayer game's side of it, in which a player told of an ejected pilot's
//! destruction hears the carrier abort the mission, and the other players' ships jump out
//! ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

const std = @import("std");
const assert = std.debug.assert;

const math = @import("../surrender/math.zig");
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const collision = @import("collision.zig");
const gameobj = @import("gameobj.zig");
const input = @import("../input.zig");
const videoreports = @import("videoreports.zig");

/// What Moose's warnings keep, which `friendly_fire_reset` (`0x00474B20`) clears as `mission_run`
/// starts a mission.
pub const Warnings = struct {
    /// The player's damage to friends since the last warning (`friendly_fire_damage`,
    /// `0x00562CEC`).
    damage: f32 = 0,
    /// The warnings given, which the game holds at `held_count` (`friendly_fire_count`,
    /// `0x00562CF0`).
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

/// Whether a blow of `kind` to the object in slot `index` by `attacker` is the player's on a friend,
/// as `object_damage`, `object_armor_damage` and `component_damage` test it (`0x00463F6D`): a shot,
/// a Screamer or a collision of the player's ship on a friendly object.
fn onFriend(world: gameobj.World, index: u16, attacker: u16, kind: collision.Kind) bool {
    const all = world.objects;
    if (attacker != all.player or all.slots[index].object.side != .friendly) return false;
    return switch (kind) {
        .bullet, .screamer, .collision => true,
        else => false,
    };
}

/// `friendly_fire_warning` (`0x00474C80`), for a blow of `damage`, after the difficulty's scaling,
/// that the damage routines find is the player's on a friend (`onFriend`): the damage mounts, and
/// once past `warn_over` and `warn_every` after the last, Moose warns the player on the radio, and
/// the damage counts from nothing again.
pub fn warn(world: gameobj.World, index: u16, attacker: u16, kind: collision.Kind, damage: f32) void {
    if (!onFriend(world, index, attacker, kind)) return;
    const kept = &world.player.friendly_fire;
    kept.damage += damage;
    if (kept.damage <= warn_over or kept.quiet_until >= world.clock.game_ticks) return;
    kept.count = @min(kept.count + 1, held_count);
    kept.quiet_until = world.clock.game_ticks + warn_every;
    kept.damage = 0;
    videoreports.mooseSaysOneOf(world, &warnings);
}

/// `player_friend_destroyed` (`0x00474E00`), as the player's blow destroys a friend (`onFriend`),
/// where it is not a collision with a pilot's pod, or one of a friend's components by a shot or a
/// Screamer, and as the script's `FriendlyFire` asks: the player's ship is to be sent home
/// (`sendHome`).
pub fn friendDestroyed(world: gameobj.World) void {
    const all = world.objects;
    all.slots[all.player].object.sent_home = .friend_destroyed;
}

/// Whether the object in slot `index`, just destroyed by a blow of `kind` from `attacker`, was the
/// player's friend (`object_armor_damage`, `0x0046446D`): not where the blow was a collision with a
/// pilot's pod that anything could harm.
pub fn destroyedFriend(world: gameobj.World, index: u16, attacker: u16, kind: collision.Kind) bool {
    const object = &world.objects.slots[index].object;
    if (!onFriend(world, index, attacker, kind)) return false;
    return !(object.flags.ejected and kind == .collision and object.invulnerable != .player_can_hit);
}

/// `mission_frame`'s care of a player's ship to be sent home (`0x0049298C`), each frame after the
/// orders, with `friendly_fire_send_home` (`0x00474B40`): where the player's ship is in the action
/// and marked, the mission goes on and the ship's current order has no priority, the mission's
/// ending becomes the friendly fire's, and the ship takes Friendly Fire aimed at its current
/// order's index and component taken as a ship's (`order_push_ship`), out of the action.
pub fn sendHome(ctx: aigeneric.Context) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[all.player];
    const object = &slot.object;
    if (object.flags.outOfAction() or object.sent_home == .none) return;
    if (world.player.ending != .playing) return;
    const current = slot.current() orelse return;
    if (aigeneric.prioritised(all, current.order)) return;
    world.player.ending = if (object.sent_home == ._unknown_3) ._unknown_7 else .friendly_fire;
    _ = aigeneric.give(ctx, all.player, .friendly_fire, current.target.asShip());
    object.flags.sent_off = true;
}

/// What Friendly Fire keeps in the object's order state.
pub const State = extern struct {
    stage: Stage,
    /// The frame's start at which the stage ends.
    until: i32,
    _unknown_08: [0x90 - 0x08]u8,

    comptime {
        assert(@offsetOf(State, "until") == 0x4);
        assert(@sizeOf(State) == 0x90);
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
    switch (slot.object.sent_home) {
        .told, ._unknown_3 => {
            const reliant = if (world.player.carrier) |carrier| world.objects.slots[carrier].object.type == .reliant else false;
            const pilot = if (reliant) reliant_aborts else other_aborts;
            videoreports.pilotSays(world, pilot, .talking, abort_line, .queued, .looping, videoreports.no_expiry);
        },
        else => videoreports.mooseSaysOneOf(world, &home_lines),
    }
}

/// How the steering toward the carrier mixes with the player's controls (`0x004DC484`,
/// `0x004DC4C0`): the player's throttle and turns at `players_share`, the AI's turns at the rest.
const players_share: f32 = 0.7;
const steering_share: f32 = 0.3;

/// How far from its carrier the ship jumps out rather than flying there (`0x004DC4F8`).
const jump_beyond: f32 = 1_000_000;

/// `order_friendly_fire` (`0x00474F20`): while Moose speaks, the player flies on
/// (`input.playerControlOrder`); then for `steering_ticks` the ship is steered toward the carrier
/// the player launched from (`ai.steer`), the player's controls keeping `players_share` of the
/// throttle and the turns; then the order ends, and the ship lands on the carrier, jumping out
/// first where it is farther than `jump_beyond`, out of the action. The game also clears the
/// carrier's stand-in flag.
///
/// **Fix:** the game reads the carrier through a null pointer where the player launched from
/// none; OpenReliant lets the ship fly on as the player has it, and then ends the order.
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
            const carrier = world.player.carrier orelse return;
            steerHome(world, index, all.slots[carrier].object.nextPosition());
        },
        .landing => {
            slot.object.flags.sent_off = false;
            aigeneric.end(ctx, index);
            const carrier = world.player.carrier orelse return;
            const home = &all.slots[carrier].object;
            home.flags.stand_in = false;
            _ = aigeneric.giveShip(ctx, index, .land, carrier, null);
            const from = slot.object.nextPosition();
            if (math.distance(home.nextPosition(), from) > jump_beyond) {
                _ = aigeneric.giveShip(ctx, index, .jump_out, index, null);
            }
            slot.object.flags.sent_off = true;
        },
        _ => {},
    }
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
    var heard: videoreports.testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    const world = heard.world();
    const kept = &heard.mission.player.friendly_fire;
    heard.mission.clock.game_ticks = 100;

    // The player's shots on a friend mount up; past `warn_over`, Moose warns the player.
    warn(world, heard.wingman, 0, .bullet, 500);
    try std.testing.expectEqual(0, heard.radio.count);
    warn(world, heard.wingman, 0, .bullet, 500);
    try heard.expectLine(0, videoreports.pilot_base + 4, &warnings);
    try std.testing.expectEqual(0, kept.damage);
    try std.testing.expectEqual(100 + warn_every, kept.quiet_until);
    // Within the quiet, the damage mounts unsaid; after it, the count holds at one.
    heard.radio.reset(&heard.speaker.sound);
    warn(world, heard.wingman, 0, .screamer, 900);
    try std.testing.expectEqual(0, heard.radio.count);
    heard.mission.clock.game_ticks = 101 + warn_every;
    warn(world, heard.wingman, 0, .collision, 1);
    try std.testing.expectEqual(1, heard.radio.count);
    try std.testing.expectEqual(held_count, kept.count);
    // Nor an enemy's, a missile's, nor another's blow counts.
    heard.radio.reset(&heard.speaker.sound);
    heard.mission.clock.game_ticks += 2 * warn_every;
    warn(world, heard.enemy, 0, .bullet, 1000);
    warn(world, heard.wingman, 0, .missile, 1000);
    warn(world, heard.wingman, heard.enemy, .bullet, 1000);
    try std.testing.expectEqual(0, kept.damage);
    try std.testing.expectEqual(0, heard.radio.count);
}

test mix {
    try std.testing.expectApproxEqAbs(steering_share + players_share * -0.5, mix(1, -0.5), 1e-6);
    try std.testing.expectApproxEqAbs(players_share, mix(0, 1), 1e-6);
}

test destroyedFriend {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    _ = try mission.add(.predator, @splat(0));
    const friend = try mission.add(.predator, .{ 0, 0, 1000 });
    try std.testing.expect(destroyedFriend(world, friend, 0, .bullet));
    // A collision with a pilot's pod that anything could harm is no friend destroyed; with one only
    // a player could, it is.
    mission.slot(friend).object.flags.ejected = true;
    try std.testing.expect(!destroyedFriend(world, friend, 0, .collision));
    mission.slot(friend).object.invulnerable = .player_can_hit;
    try std.testing.expect(destroyedFriend(world, friend, 0, .collision));
    mission.slot(friend).object.side = .hostile;
    try std.testing.expect(!destroyedFriend(world, friend, 0, .bullet));
}

test "a player who destroys a friend is sent home, and lands" {
    var heard: videoreports.testing.Heard = undefined;
    try heard.init();
    defer heard.deinit();
    const world = heard.world();
    const all = heard.mission.objects;
    const ctx: aigeneric.Context = .of(world);
    const player = &all.slots[0];
    const reliant = try heard.mission.add(.reliant, .{ 0, 0, 5000 });
    heard.mission.player.carrier = reliant;
    _ = try aigeneric.pushShip(ctx, 0, .player_control, heard.enemy, null);

    // Unmarked, the ship flies on.
    sendHome(ctx);
    try std.testing.expectEqual(.playing, heard.mission.player.ending);
    // Marked, the mission ends with the friendly fire, and the ship takes Friendly Fire.
    friendDestroyed(world);
    sendHome(ctx);
    try std.testing.expectEqual(.friendly_fire, heard.mission.player.ending);
    try std.testing.expectEqual(.friendly_fire, player.current().?.order);
    try std.testing.expect(player.object.flags.sent_off);

    // As it starts, Moose says so, and the player flies on a while.
    heard.mission.clock.frame_start = 1000;
    init(ctx, 0);
    try heard.expectLine(0, videoreports.pilot_base + 4, &home_lines);
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
