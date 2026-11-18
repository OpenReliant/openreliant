//! OpenReliant's simulation-owned state for each player. The original keeps flight controls and
//! shield balancing in local globals. **Improvement:** the host owns these for each participant,
//! independently of local devices and presentation.
//! Flight controls and selected targets belong to each participant. Mission state and participant
//! lifecycle follow separately ([#1367](https://github.com/OpenReliant/openreliant/issues/1367)).

const std = @import("std");
const gameobj = @import("gameobj.zig");
const flight = @import("../input/flight.zig");
const aigeneric = @import("aigeneric.zig");
const missile_display = @import("hud/missile_display.zig");
const lock = @import("main/lock.zig");
const ship_devices = @import("ship_devices.zig");
const friendly_fire = @import("friendly_fire.zig");

/// Identifies one admission to the session. The host keeps this independently of the ship.
pub const ParticipantRef = struct {
    slot: u16,
    generation: u64,
};

/// Identifies the participant and the ship a command was sampled for.
pub const ControlRef = struct {
    participant: ParticipantRef,
    ship: gameobj.ObjectRef,
};

pub const Membership = union(enum) {
    local_rules,
    vacant,
    joined: Joined,

    pub const Joined = struct {
        generation: u64,
        ship: ?gameobj.ObjectRef = null,
        kills: Kills = .{},
    };
};

/// The pilot's skull count and their kills in the current mission.
pub const Kills = struct {
    count: i32 = 0,
    mission: u16 = 0,

    /// `kills_add` (0x004B14F0) adds the award to the total. A mission that counts
    /// kills records one destruction regardless of the size of the award.
    pub fn add(kills: *Kills, count: i32, counts_mission: bool) void {
        kills.count += count;
        if (counts_mission) kills.mission +|= 1;
    }
};

/// A participant's simulation state, kept by `create.Objects` beside the simulated ships.
/// A managed participant keeps their membership across a ship replacement. Each new ship
/// starts with fresh input and weapons. The local path keeps its existing control persistence.
pub const State = struct {
    membership: Membership = .local_rules,
    controls: flight.State = .{},
    weapons: Weapons = .{},
    charges: ship_devices.Charges = ship_devices.full,
    /// Validated input from the bound participant. Held input lasts across game frames and steps.
    command: ?Command = null,

    /// What SHIELD BALANCING has shifted beyond the fore and aft shields' full charge
    /// (`shield_reserve_fore`, `0x0051CF78`, and `shield_reserve_aft`, `0x0051CF34`).
    shield_reserves: gameobj.ShieldReserves = .{},
    /// Tick of the last armour warning (`0x00588334`). The standalone campaign keeps it across
    /// missions. A newly bound ship starts with a fresh cooldown.
    armor_warned_at: i32 = 0,
    /// Tick of the last sound on this pilot's hull (`0x00593794`). It resets with the armour
    /// warning cooldown when a hosted ship is replaced.
    hull_heard_at: i32 = 0,
    /// The frame tick past which an enemy may taunt this pilot again (`0x005297EC`).
    taunt_next: i32 = 0,
    /// The frame tick past which this pilot can receive another missile warning (`0x005297E4`).
    missile_warning_next: i32 = 0,
    /// The game tick past which this pilot can receive another kill remark (`0x00529CB8`).
    kill_remark_next: u32 = 0,
    friendly_fire: friendly_fire.Warnings = .{},

    /// Drops all state tied to the old ship while keeping the participant's admission.
    pub fn unbindShip(state: *State) void {
        if (state.membership != .joined) return;
        state.membership.joined.ship = null;
        state.command = null;
        state.controls = .{};
        state.weapons = .{};
        state.charges = ship_devices.full;
        state.shield_reserves = .{};
        state.armor_warned_at = 0;
        state.hull_heard_at = 0;
        state.taunt_next = 0;
        state.missile_warning_next = 0;
        state.kill_remark_next = 0;
        state.friendly_fire = .{};
    }

    pub fn resetMission(state: *State) void {
        if (state.membership == .joined) {
            state.membership.joined.kills.mission = 0;
            return state.unbindShip();
        }
        state.shield_reserves = .{};
        state.command = null;
        state.weapons.lock.reset();
        state.charges = ship_devices.full;
        state.taunt_next = 0;
        state.missile_warning_next = 0;
        state.kill_remark_next = 0;
        state.friendly_fire = .{};
    }
};

/// A flight command and one-time requests, with retained identities for selected targets.
/// Transport sequencing and buffering belong to [#954](https://github.com/OpenReliant/openreliant/issues/954);
/// this record is simulation input.
pub const Command = struct {
    flight: flight.Command = .{},
    match_speed: bool = false,
    weapons: WeaponCommand = .{},
    devices: ship_devices.Requests = .empty,
    target: union(enum) { keep, clear, aim: aigeneric.Aim } = .keep,

    pub fn consumePresses(command: *Command) void {
        command.flight.consumePresses();
        command.match_speed = false;
        command.target = .keep;
        command.devices = .empty;
        command.weapons = .{ .fire_guns = command.weapons.fire_guns };
    }
};

/// Weapon input addresses the participant that owns the command. The host picks the rack and
/// checks the target, lock and ammunition.
pub const WeaponCommand = struct {
    fire_guns: bool = false,
    launch_missile: bool = false,
    rotate_missiles: ?missile_display.Turn = null,
    countermeasures: bool = false,
};

pub const Weapons = struct {
    ring: missile_display.Ring = .{},
    lock: lock.Lock = .{},
};

test "a kill award counts one destruction in a mission that records kills" {
    var kills: Kills = .{};
    kills.add(2, true);
    kills.add(3, false);
    try std.testing.expectEqual(Kills{ .count = 5, .mission = 1 }, kills);
}

test {
    std.testing.refAllDecls(@This());
}
