//! Simulation state for the devices fitted to each player's ship. The HUD reads the same charges
//! from its drawing snapshot.

const std = @import("std");
const cloak = @import("cloak.zig");
const input = @import("../input.zig");
const gameobj = @import("gameobj.zig");

/// A device a ship may carry that runs off a charge, which its light shows as a bar.
pub const Device = enum {
    ecm,
    cloak,
    spectral_shields,

    pub const Spec = struct {
        /// The charge when full, in ticks, where `hud_init` starts it.
        full: i32,
        /// What it spends of the charge a tick while it is on. It charges at one a tick while off.
        drain: i32,
    };

    /// Twenty seconds of ECM, a hundred of cloak and ten of spectral shields.
    pub fn spec(kind: Device) Spec {
        return switch (kind) {
            .ecm => .{ .full = 2000, .drain = 1 },
            .cloak => .{ .full = 10000, .drain = 1 },
            .spectral_shields => .{ .full = 6000, .drain = 6 },
        };
    }
};

/// Whether the ship carries a device, and whether it is on: `ecm_state` (`0x0057BF4C`),
/// `cloak_state` (`0x00566638`) and `spectral_shields_state` (`0x0057BF20`).
pub const Setting = enum(i32) {
    absent = -1,
    off = 0,
    on = 1,
    _,
};

/// A device's setting and its charge in ticks: `ecm_charge` (`0x005665F8`), `cloak_charge`
/// (`0x0056663C`) and `spectral_shields_charge` (`0x00566620`).
pub const Charge = struct {
    setting: Setting = .off,
    ticks: i32,

    /// Carried, off and full, as `hud_init` leaves each device.
    pub fn full(kind: Device) Charge {
        return .{ .ticks = kind.spec().full };
    }

    /// `hud_draw`'s work on the charge for a frame of `frame_duration`: while the device is off it
    /// charges up to full, and while it is on it drains. Says whether it has just run dry, which
    /// leaves the charge at nothing for the device to be turned off.
    pub fn run(charge: *Charge, kind: Device, frame_duration: i32) bool {
        const at = kind.spec();
        switch (charge.setting) {
            .off => charge.ticks = @min(charge.ticks + frame_duration, at.full),
            .on => {
                charge.ticks -= frame_duration * at.drain;
                if (charge.ticks < 0) {
                    charge.ticks = 0;
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// How much of a full charge is left, from 0 to 1, which the bar shows.
    pub fn share(charge: Charge, kind: Device) f32 {
        return @as(f32, @floatFromInt(charge.ticks)) / @as(f32, @floatFromInt(kind.spec().full));
    }
};

pub const Charges = std.EnumArray(Device, Charge);
pub const Requests = std.EnumSet(Device);
pub const full: Charges = .init(.{
    .ecm = .full(.ecm),
    .cloak = .full(.cloak),
    .spectral_shields = .full(.spectral_shields),
});

/// Fits a fresh ship using its capabilities. ECM is standard on player ships.
pub fn fitted(spectral: bool, can_cloak: bool) Charges {
    var charges = full;
    charges.getPtr(.spectral_shields).setting = if (spectral) .off else .absent;
    charges.getPtr(.cloak).setting = if (can_cloak) .off else .absent;
    return charges;
}

test {
    std.testing.refAllDecls(@This());
}

/// Local input keeps the existing charge rules. The host also checks each submitted activation.
pub const Control = enum { local, host };

/// Requests from a bound pilot. The host checks fitting and remaining charge before activation.
///
/// In an arena the cloak and the spectral shields stay as they are: the original's CLOAK SHIP
/// does nothing in a multiplayer mission (`player_cloak_set`, `0x004153EA`), where the cloak is a
/// power-up's, and its SPECTRAL SHIELDS key is passed over (`0x00414E92`). ECM has no such test.
pub fn toggle(world: gameobj.World, index: u16, kind: Device) void {
    const all = world.objects;
    if (!all.hasBoundPlayerShip(index)) return;
    if (world.damage_rules == .arena and kind != .ecm) return;
    const slot = &all.slots[index];
    const object = &slot.object;
    const charges = &all.player_states[index].charges;
    const charge = charges.get(kind);
    if (charge.setting == .absent) return;
    const on = switch (kind) {
        .ecm => !object.flags.ecm,
        .cloak => !object.flags.cloaked,
        .spectral_shields => !object.flags.spectral_shields,
    };
    if (on and charge.ticks <= 0) return;
    switch (kind) {
        .ecm => input.setEcm(charges, object, on),
        .spectral_shields => input.setSpectralShields(charges, object, on, .{ .all = all, .index = index }),
        .cloak => cloak.set(world, index, on),
    }
    // Player-specific beeps and callouts need addressed presentation events
    // ([#1368](https://github.com/OpenReliant/openreliant/issues/1368)).
}

/// Starts a decloak even if the cloak is still coming on, when its charge runs out or the pilot
/// disconnects. The existing cloak transition finishes the change.
pub fn endCloak(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const active = slot.cloak orelse return;
    if (!active.going) cloak.uncloak(world, index);
}

/// The device timers originally advanced in `hud_draw`. The simulation advances the same
/// timers at that point in the game frame, even without presentation.
pub fn advance(world: gameobj.World, index: u16, elapsed: i32, control: Control) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const charges = &all.player_states[index].charges;
    if (charges.getPtr(.ecm).run(.ecm, elapsed)) input.setEcm(charges, object, false);

    const cloaking = charges.getPtr(.cloak);
    if (control == .host and cloaking.setting != .absent) {
        cloaking.setting = if (slot.cloak) |active| (if (active.going) .off else .on) else .off;
    }
    if (cloaking.run(.cloak, elapsed)) switch (control) {
        .local => cloak.set(world, index, false),
        .host => {
            cloaking.setting = .off;
            endCloak(world, index);
        },
    };

    if (charges.getPtr(.spectral_shields).run(.spectral_shields, elapsed)) input.setSpectralShields(charges, object, false, null);
}
