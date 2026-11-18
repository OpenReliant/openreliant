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

/// A participant's simulation state, kept by `create.Objects` beside the simulated ships.
/// This belongs to the player's slot, so replacing its physical ship leaves it intact.
/// A mission reset clears reserves and pending commands, preserving the control globals.
/// It contains no device, camera or display state.
pub const State = struct {
    controls: flight.State = .{},
    weapons: Weapons = .{},
    /// Commands supplied at the simulation boundary. Null uses local devices for the displayed
    /// player and leaves remote players alone. A held command survives frames and physical steps.
    command: ?Command = null,

    /// What SHIELD BALANCING has shifted beyond the fore and aft shields' full charge
    /// (`shield_reserve_fore`, `0x0051CF78`, and `shield_reserve_aft`, `0x0051CF34`).
    shield_reserves: gameobj.ShieldReserves = .{},

    /// Installs a command from the host's input source, after resolving device bindings.
    pub fn submit(state: *State, command: Command) bool {
        if (!command.flight.valid()) return false;
        state.command = command;
        return true;
    }

    pub fn resetMission(state: *State) void {
        state.shield_reserves = .{};
        state.command = null;
        state.weapons.lock.reset();
        state.weapons.ship = null;
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
    /// The ship whose loadout supplied this selection.
    ship: ?gameobj.ObjectRef = null,
    ring: missile_display.Ring = .{},
    lock: lock.Lock = .{},
};

test {
    std.testing.refAllDecls(@This());
}
