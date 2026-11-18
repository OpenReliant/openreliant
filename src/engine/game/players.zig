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
    };
};

/// A participant's simulation state, kept by `create.Objects` beside the simulated ships.
/// A managed participant keeps their membership across a ship replacement. Each new ship
/// starts with fresh input and weapons. The local path keeps its existing control persistence.
pub const State = struct {
    membership: Membership = .local_rules,
    controls: flight.State = .{},
    weapons: Weapons = .{},
    /// Validated input from the bound participant. Held input lasts across game frames and steps.
    command: ?Command = null,

    /// What SHIELD BALANCING has shifted beyond the fore and aft shields' full charge
    /// (`shield_reserve_fore`, `0x0051CF78`, and `shield_reserve_aft`, `0x0051CF34`).
    shield_reserves: gameobj.ShieldReserves = .{},

    /// Drops all state tied to the old ship while keeping the participant's admission.
    pub fn unbindShip(state: *State) void {
        if (state.membership != .joined) return;
        state.membership.joined.ship = null;
        state.command = null;
        state.controls = .{};
        state.weapons = .{};
        state.shield_reserves = .{};
    }

    pub fn resetMission(state: *State) void {
        if (state.membership == .joined) return state.unbindShip();
        state.shield_reserves = .{};
        state.command = null;
        state.weapons.lock.reset();
    }
};

/// A flight command and one-time requests, with retained identities for selected targets.
/// Transport sequencing and buffering belong to [#954](https://github.com/OpenReliant/openreliant/issues/954);
/// this record is simulation input.
pub const Command = struct {
    flight: flight.Command = .{},
    match_speed: bool = false,
    weapons: WeaponCommand = .{},
    target: union(enum) { keep, clear, aim: aigeneric.Aim } = .keep,

    pub fn consumePresses(command: *Command) void {
        command.flight.consumePresses();
        command.match_speed = false;
        command.target = .keep;
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

test {
    std.testing.refAllDecls(@This());
}
