//! What player scripts read of the flight display's instruments (`openreliant.hud`): which of the
//! game's instruments the mods' displays stand in for, where each instrument draws, and what the
//! game's instruments show, so that a display can stand in for one, and how a display's `layout`
//! moves and scales them ([#793](https://github.com/OpenReliant/openreliant/issues/793)).
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const hud = engine.game.hud;
const gun_types = engine.game.guns;
const missile_display = hud.missile_display;
const create = engine.game.create;
const Target = engine.hooks.Target;
const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const presentation = @import("presentation.zig");

/// A list of the game's instruments, which holds them all.
pub const Instruments = values.List(hud.Instrument, std.enums.values(hud.Instrument).len);

/// Where a display puts one of the game's instruments (`register_display`'s `layout`).
pub const Layout = struct {
    pub const script_name = "HudLayout";
    /// The most times its own size an instrument can be drawn.
    pub const max_scale = 8;

    /// How far it moves, in the game's pixels, which grow with the window as the display's own do.
    offset: ?@Vector(3, f32) = null,
    /// How many times its own size it's drawn, growing from where it stands on the screen.
    scale: ?f32 = null,

    /// The placement it gives the instrument; null for a scale out of bounds.
    pub fn placement(layout: Layout) ?hud.Placement {
        const scale = layout.scale orelse 1;
        if (!(scale > 0 and scale <= max_scale)) return null;
        const offset: @Vector(3, f32) = layout.offset orelse @splat(0);
        return .{ .offset = .{ offset[0], offset[1] }, .scale = scale };
    }
};

/// The player's guns as the gunnery window and the targeting cluster show them.
pub const Guns = struct {
    pub const script_name = "HudGuns";

    /// The group of guns chosen, counting from 0, which GUNNERY WINDOW moves on.
    group: u8,
    /// How many groups the ship has.
    groups: u8,
    /// Whether every group fires, which FULL GUNS turns on.
    all: bool,
    /// Whether SYNCHRONISE GUNS is on.
    synchronised: bool,
    /// The type of the chosen group's first gun, nil for none.
    gun: ?gun_types.GunType,
    /// The guns' charge, and the most they hold.
    charge: f32,
    full_charge: f32,
};

/// A missile type on the missile window's ring, and how many are left.
pub const RingMissile = struct {
    pub const script_name = "HudMissile";

    type: engine.game.missiles.Type,
    left: i16,
};

/// The player's missiles as the missile window shows them.
pub const Missiles = struct {
    pub const script_name = "HudMissiles";

    /// The armed missile, nil while the ring is empty.
    armed: ?engine.game.missiles.Type,
    /// How many of the armed missile are left.
    left: i16,
    /// Each missile type on the ring, in its order, the armed one among them.
    ring: values.List(RingMissile, missile_display.max_entries),
};

/// The radar's range.
pub const Radar = struct {
    pub const script_name = "HudRadar";

    /// The range, 0 the closest, which RADAR RANGES moves on.
    range: u8,
    /// How far the radar reaches at that range.
    reach: f32,
    /// Whether its rings are still moving to that range's.
    zooming: bool,
};

/// The flight display's state, and the player's ship, while a mission is shown; null otherwise.
fn flightOf(call: Call, comptime label: []const u8) ?struct { presentation.Host.Flight, *const create.Slot } {
    const host = presentation.Presentation.of(call, label).host orelse return null;
    const flight = host.flight orelse return null;
    const all = call.runtime().objects orelse return null;
    return .{ flight, &all.slots[all.player] };
}

pub const replaced = api.Field(Instruments, "The game's instruments the mods' displays stand in for this frame, which aren't drawn (`register_display`).", struct {
    pub fn get(call: Call) Instruments {
        var list: Instruments = .{};
        const placements = presentation.Presentation.of(call, "replaced").instrumentPlacements();
        for (std.enums.values(hud.Instrument)) |instrument| {
            if (placements.get(instrument).hidden) list.append(instrument);
        }
        return list;
    }
});

pub const bounds = api.Function("Where the game's instrument `instrument` last drew, in the window's pixels, as the mods' displays place it, and even while one stands in for it; nil before it first draws, or outside a mission.", &.{"instrument"}, struct {
    fn get(call: Call, instrument: hud.Instrument) ?hud.Clip {
        const flight, _ = flightOf(call, "bounds") orelse return null;
        return flight.hud.bounds.get(instrument);
    }
}.get);

pub const instruments_shown = api.Field(bool, "Whether the game's instruments show this frame: during a mission, in the view ahead from the cockpit.", struct {
    pub fn get(call: Call) bool {
        const host = presentation.Presentation.of(call, "instruments_shown").host orelse return false;
        const held = host.camera orelse return false;
        return hud.instrumented(held.camera.view);
    }
});

pub const guns = api.Field(?Guns, "The player's guns as the gunnery window and the targeting cluster show them; nil outside a mission.", struct {
    pub fn get(call: Call) ?Guns {
        _, const slot = flightOf(call, "guns") orelse return null;
        const combat = slot.combat orelse return null;
        const mode = slot.object.gun_mode;
        return .{
            .group = mode.group,
            .groups = std.math.lossyCast(u8, combat.gun_groups),
            .all = mode.all,
            .synchronised = mode.synchronised,
            .gun = slot.groupLead(mode.group),
            .charge = slot.object.gun_charge,
            .full_charge = combat.gun_energy,
        };
    }
});

pub const missiles = api.Field(?Missiles, "The player's missiles as the missile window shows them; nil outside a mission.", struct {
    pub fn get(call: Call) ?Missiles {
        const flight, _ = flightOf(call, "missiles") orelse return null;
        const ring = &flight.hud.missiles;
        var shown: Missiles = .{ .armed = null, .left = 0, .ring = .{} };
        for (ring.entries) |entry| {
            const left = entry.left() orelse continue;
            shown.ring.append(.{ .type = entry.type, .left = left });
        }
        if (ring.entries[ring.armed].left()) |left| {
            shown.armed = ring.entries[ring.armed].type;
            shown.left = left;
        }
        return shown;
    }
});

pub const target = api.Field(?Target, "The target the display shows, with its subtarget as `component`; nil for none, or outside a mission.", struct {
    pub fn get(call: Call) ?Target {
        const flight, _ = flightOf(call, "target") orelse return null;
        const shown = flight.hud.target orelse return null;
        return .of(shown.target);
    }
});

pub const radar = api.Field(?Radar, "The radar's range; nil outside a mission.", struct {
    pub fn get(call: Call) ?Radar {
        const flight, _ = flightOf(call, "radar") orelse return null;
        const state = flight.hud;
        return .{ .range = state.radar_range, .reach = hud.Radar.ranges[state.radar_range].reach, .zooming = state.radar_zoom != null };
    }
});

pub const kills = api.Field(?i32, "The kills the skull readout shows; nil outside a mission.", struct {
    pub fn get(call: Call) ?i32 {
        const flight, _ = flightOf(call, "kills") orelse return null;
        return flight.player.kills.count;
    }
});

pub const open_windows = api.Field(Instruments, "The game's windows that are open, opening or closing; none outside a mission.", struct {
    pub fn get(call: Call) Instruments {
        var list: Instruments = .{};
        const flight, _ = flightOf(call, "open_windows") orelse return list;
        for (std.enums.values(hud.windows.Window)) |window| {
            const instrument = hud.Instrument.ofWindow(window) orelse continue;
            if (flight.hud.windows.status.get(window).phase == .shut) continue;
            // Window 14 shows the radio's menu too, which is listed once.
            if (std.mem.findScalar(hud.Instrument, list.slice(), instrument) == null) list.append(instrument);
        }
        return list;
    }
});
