//! OpenReliant's simulation-owned state for each player. The original uses local globals for
//! shield balancing; the host keeps a separate reserve for each participant instead.
//! **Improvement:** shield state belongs to the simulation, independently of local input.
//! Controls and targets still belong to the local input state
//! ([#1366](https://github.com/OpenReliant/openreliant/issues/1366)). Mission state and participant
//! lifecycle follow separately ([#1367](https://github.com/OpenReliant/openreliant/issues/1367)).

const std = @import("std");
const gameobj = @import("gameobj.zig");

/// A participant's simulation state, kept by `create.Objects` beside the simulated ships.
/// This belongs to the player's slot, so replacing its physical ship leaves it intact.
/// A mission reset clears it. It contains no device, camera or display state.
pub const State = struct {
    /// What SHIELD BALANCING has shifted beyond the fore and aft shields' full charge
    /// (`shield_reserve_fore`, `0x0051CF78`, and `shield_reserve_aft`, `0x0051CF34`).
    shield_reserves: gameobj.ShieldReserves = .{},
};

test {
    std.testing.refAllDecls(@This());
}
