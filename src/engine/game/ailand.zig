//! `C:\lancer\game\ailand.cpp`: Land, order 8, by which the player's ship lands on its carrier,
//! which ends the mission ([Landing](../../../docs/engine/orders.md#landing)). The player asks for
//! it with PERMISSION TO LAND (`radio.permissionToLand`). Its init picks how the ship lands
//! (`Style`), and each style has its own init and update (`land_styles`, `0x004E1FE8`, `0x18` bytes
//! each: init, update, exit, 0, name and 0): the Reliant's, down into its first launch tube
//! ([`ailand/reliant.zig`](ailand/reliant.zig)), and the Yamato's, down onto a pad of its landing
//! bay ([`ailand/yamato.zig`](ailand/yamato.zig)). OpenReliant adds two, in at the doors of a gate
//! and down to where ships launch from it: into a hangar bay, and into the Badanov's or the
//! Krasny's bay ([`ailand/bay.zig`](ailand/bay.zig)).
//!
//! **Improvement:** the game picks the style by the carrier's type, and lands only on the Reliant
//! and the Yamato. OpenReliant lands on a ship that offers a landing (`create.Slot.landing`). Its
//! type's record says which one (`create.combat_stats.Static.landing`): the Reliant and the Yamato
//! offer theirs, as in the game, and no other type offers one (`Style.of`). Mods and missions'
//! scripts can change it, so that a mission sets its own flow.
//!
//! **Unverified:** that `order_land` and the styles' routines (`0x0040EB40` to `0x0040FC77`) are
//! this file's. They lie after its known code, before `airipper.cpp`'s, and the style table
//! (`land_styles`, `0x004E1FE8`), just before this file's path, ties them to Land.
//!
//! Not ported: in a multiplayer game, the end of the mission as another player's ship lands on the
//! Yamato ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.orders);

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aigeneric = @import("aigeneric.zig");
const Context = aigeneric.Context;
const camera = @import("camera.zig");
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const launch = @import("launch.zig");
const objects = @import("objects.zig");

pub const bay = @import("ailand/bay.zig");
pub const reliant = @import("ailand/reliant.zig");
pub const yamato = @import("ailand/yamato.zig");

/// How the player's ship lands on a carrier: the landing a ship offers (`create.Slot.landing`),
/// and the one a landing runs (`State.landing`).
pub const Style = enum(u32) {
    /// On the Yamato, down onto a pad of its landing bay (`yamato.init`, `yamato.update`).
    yamato = 0,
    /// On the Reliant, down into its first launch tube through the tube's upper door
    /// (`reliant.init`, `reliant.update`).
    reliant = 1,
    /// **Improvement:** OpenReliant's own, in a hangar bay that ships launch from: in at the doors
    /// of a gate and down to its launch point (`bay.init`, `bay.update`).
    bay = 2,
    /// **Improvement:** OpenReliant's own, in the Badanov's or the Krasny's bay: in at its doors
    /// and down to where a ship waits at the gate to launch, as in a hangar bay
    /// (`launch.badanov.gatePlace`).
    badanov = 3,

    /// The name scripts know these values by.
    pub const script_name = "Landing";

    /// The landing the game offers on a ship of type `ship_type` (`order_land_init`, `0x0040EAC0`):
    /// the Reliant's and the Yamato's. It offers none on any other type, where it stops with
    /// "Cannot land on %s".
    pub fn original(ship_type: gameobj.GameType) ?Style {
        return switch (ship_type) {
            .reliant => .reliant,
            .yamato => .yamato,
            else => null,
        };
    }

    /// The landing a ship of type `ship_type` offers before scripts change it
    /// (`create.typeRecords`). One of the game's types offers the game's (`original`). A type a
    /// mod adds offers the one its section gives (`additions.ShipExtra.landing`). Without one, it
    /// offers its base's where it keeps its base's model (`launch.launchesAsBase`), whose parts
    /// that landing goes by, and none where it has a model of its own.
    pub fn of(ship_type: gameobj.Type) ?Style {
        const added = ship_type.added() orelse return original(ship_type.base());
        if (added.extra.landing) |given| return given.style();
        return if (launch.launchesAsBase(ship_type)) original(added.base) else null;
    }
};

/// The order's state (`GameObject.order_state`).
pub const State = extern struct {
    /// The landing it runs, by its style's number (`landing`), or `no_landing` where the order
    /// aims at nothing that offers one.
    style: u32,
    /// The frame's tick the step waits for; in the Yamato's landing, from the cutaway on, the tick
    /// the view from its bay begins to slide along it (`camera.View.landing_bay`).
    due: i32,
    /// The Yamato's: the frame's tick the steps on its pad wait for.
    pad_due: i32,
    step: Step,
    /// The Reliant's: the middle of the tube the ship lands in, where the cutaway has moved the
    /// carrier (`reliant.cutaway`).
    tube: [3]f32,
    /// OpenReliant's own: whether the Reliant's upper door has begun to close over the ship
    /// (`reliant.Touchdown.level`).
    door_closing: bool,
    /// OpenReliant's own: where the ship stands on the Yamato's pad, in the pad's frame, which
    /// each frame's pass places it at (`yamato.hold`). The game hangs the ship's frame from the
    /// pad's.
    on_pad: [3]f32,
    pad_orientation: math.Matrix,
    /// OpenReliant's own, a bay's: where the ship comes to rest at the gate it lands at and how
    /// it is turned there, where the cutaway has moved the carrier (`bay.cutaway`), and the mouth
    /// of the bay, where the way out from there leaves the carrier's bounds (`bay.mouth`).
    gate_place: [3]f32,
    gate_orientation: math.Matrix,
    mouth: [3]f32,

    /// What `style` holds where the order aims at nothing that offers a landing, which the update
    /// lets go: OpenReliant's own.
    pub const no_landing = std.math.maxInt(u32);

    /// The landing it runs; null where the order aims at nothing that offers one.
    pub fn landing(state: *const State) ?Style {
        return std.enums.fromInt(Style, state.style);
    }

    /// Sets the landing it runs, or none.
    pub fn setLanding(state: *State, style: ?Style) void {
        state.style = if (style) |runs| @backingInt(runs) else no_landing;
    }

    comptime {
        assert(@offsetOf(State, "due") == 0x04);
        assert(@offsetOf(State, "pad_due") == 0x08);
        assert(@offsetOf(State, "step") == 0x0C);
        assert(@offsetOf(State, "tube") == 0x10);
        assert(@sizeOf(State) <= @sizeOf(aigeneric.State));
    }
};

/// The step a landing is at (`State.step`), as each style numbers its own (`reliant.Step`,
/// `yamato.Step`, `bay.Step`).
pub const Step = enum(u32) {
    _,

    /// The step as the style's own steps, `Styled`, number it.
    pub fn as(step: Step, comptime Styled: type) Styled {
        comptime assert(@typeInfo(Styled).@"enum".tag_type == u32);
        return @fromBackingInt(@backingInt(step));
    }

    /// A style's own step as a landing's.
    pub fn of(own: anytype) Step {
        comptime assert(@typeInfo(@TypeOf(own)).@"enum".tag_type == u32);
        return @fromBackingInt(@backingInt(own));
    }

    /// Whether the landing is at its style's step `other` or past it, by their numbers as the game
    /// compares them.
    pub fn reached(step: Step, other: anytype) bool {
        return @backingInt(step) >= @backingInt(of(other));
    }
};

/// How long the player flies on before the landing begins, in ticks: the Reliant's
/// (`0x0040F5EA`) and the Yamato's (`0x0040EB7A`).
pub const wait: i32 = 700;

/// Where the cutaway moves the carrier, or the Yamato's landing bay, turned as the world is, far
/// from what the mission holds (`0x0040F600`, `0x0040EBE4`).
pub const carrier_away: Vector = .{ 0, -1_000_000, 0 };

/// The throttle the ship approaches with for each unit it has to go, in the Reliant's and the
/// Yamato's landings, and the most the Reliant's takes (`0x004DC4B0`, `0x004DC408`); and how near
/// it stops (`0x004DC468`). A landing in a bay goes by them too.
pub const approach_throttle: f32 = 0.0001;
pub const approach_most: f32 = 0.5;
pub const near: f32 = 200;

/// How long the mission goes on once the ship is down, in ticks (`0x0040FC4A`).
pub const landed_wait: i32 = 270;

/// `order_land_init` (`0x0040EAC0`): the landing that the ship the order aims at offers
/// (`create.Slot.landing`), and its style's init.
///
/// **Fix:** the game stops with "Cannot land on %s" for a ship it has no landing for; OpenReliant
/// logs it, and the update lets the order go.
pub fn init(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const state = &all.slots[index].state.land;
    const carrier = all.slots[index].orders[0].target.slotIn(all);
    const offered = if (carrier) |at| all.slots[at].landing else null;
    state.setLanding(offered);
    const style = offered orelse {
        log.warn("object {d} cannot land on what its order aims at", .{index});
        return;
    };
    switch (style) {
        .reliant => reliant.init(ctx, index),
        .yamato => yamato.init(ctx, index),
        .bay, .badanov => bay.init(ctx, index),
    }
}

/// `order_land` (`0x0040EB40`): the style's update. A landing on what offers none ends at once.
pub fn update(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    const style = slot.state.land.landing() orelse return aigeneric.end(ctx, index);
    switch (style) {
        .reliant => reliant.update(ctx, index),
        .yamato => yamato.update(ctx, index),
        .bay, .badanov => bay.update(ctx, index),
    }
}

/// The start of a landing's cutaway: one of `views`, picked at random, watches the ship in slot
/// `index`, locked (`camera.switchView`).
pub fn watch(world: gameobj.World, index: u16, views: [2]camera.View) void {
    const pick = if (world.random.oneIn(2)) views[0] else views[1];
    _ = camera.switchView(world, pick, index, true, true);
}

/// Moves the object in `slot`, the carrier or the Yamato's landing bay, to `carrier_away`, turned
/// as the world is, as a landing's cutaway does.
pub fn moveAway(slot: *create.Slot) void {
    objects.setPlace(&slot.object, &slot.drawn, .{ .position = carrier_away });
}

/// Stops the ship in `object` and shares its power evenly, as a landing's cutaway does.
pub fn stopShip(object: *gameobj.GameObject) void {
    ai.stop(object);
    object.gun_factor = 1;
    object.speed_factor = 1;
    object.shield_factor = 1;
}

/// Pops all the orders of the carrier in slot `carrier` and stops it, as the Reliant's and a bay's
/// cutaways do.
pub fn stopCarrier(ctx: Context, carrier: u16) void {
    aigeneric.popAll(ctx, carrier);
    ai.stop(&ctx.world.objects.slots[carrier].object);
}

/// Makes the mission's scene the landing's, as the Reliant's and a bay's landings begin: every
/// object but the ship in slot `index` and the carrier in slot `carrier` is disabled, and those two
/// are enabled.
pub fn showLanding(world: gameobj.World, index: u16, carrier: u16) void {
    world.player.showing = .landing;
    const all = world.objects;
    for (all.slots[0..all.count], 0..) |*each, at| each.object.flags.disabled = at != index and at != carrier;
}

/// Ends the mission (`vm.Variables.mission_over`) once the frame's tick is past `due`, as each
/// landing's last step does.
pub fn endAfter(world: gameobj.World, due: i32) void {
    if (world.clock.frame_start <= due) return;
    if (world.variables) |variables| variables.mission_over = 1;
}

/// The ship the player's ship can land on: the player's carrier (`gameobj.Player.carrier`), where
/// it offers a landing (`create.Slot.landing`); null where it offers none, or there is no
/// carrier. PERMISSION TO LAND (`radio.permissionToLand`) and the friendly fire's sending home
/// (`friendly_fire.update`) land the ship on it.
pub fn landingCarrier(world: gameobj.World) ?u16 {
    const carrier = world.player.carrier orelse return null;
    return if (world.objects.slots[carrier].landing != null) carrier else null;
}

/// What the landing's views stand by where the object in slot `index` is landing, by its style:
/// on the Reliant, the tube its state keeps (`reliant.seen`); on the Yamato, its landing bay
/// (`yamato.seen`); in a bay, the place it lands at and the bay's mouth (`bay.seen`).
pub fn seen(all: *const create.Objects, index: u16) ?camera.Landing {
    if (index >= all.slots.len) return null;
    const slot = &all.slots[index];
    const entry = slot.running(.land) orelse return null;
    const state = &slot.state.land;
    return switch (state.landing() orelse return null) {
        .reliant => reliant.seen(all, entry.target, state),
        .yamato => yamato.seen(all, state),
        .bay, .badanov => bay.seen(state),
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "Step.reached" {
    const settling: Step = .of(yamato.Step.settling);
    try std.testing.expect(settling.reached(yamato.Step.settling));
    try std.testing.expect(settling.reached(yamato.Step.waiting));
    try std.testing.expect(!Step.of(yamato.Step.waiting).reached(yamato.Step.settling));
}

test Style {
    // The game lands on the Reliant and the Yamato alone.
    try std.testing.expectEqual(Style.reliant, Style.original(.reliant).?);
    try std.testing.expectEqual(Style.yamato, Style.original(.yamato).?);
    for ([_]gameobj.GameType{ .victorious, .badanov, .krasny, .predator }) |other| {
        try std.testing.expectEqual(null, Style.original(other));
        try std.testing.expectEqual(null, Style.of(.of(other)));
    }
    try std.testing.expectEqual(Style.reliant, Style.of(.of(.reliant)).?);
}

test State {
    var state = std.mem.zeroes(State);
    state.setLanding(.badanov);
    try std.testing.expectEqual(Style.badanov, state.landing().?);
    state.setLanding(null);
    try std.testing.expectEqual(State.no_landing, state.style);
    try std.testing.expectEqual(null, state.landing());
    // A number of no style, as what another order left in the state, is none.
    state.style = 7;
    try std.testing.expectEqual(null, state.landing());
}

test "a landing on a ship that offers none, or a ship's but the player's on the Yamato, is let go" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    _ = try mission.add(.of(.predator), @splat(0));
    const ship = try mission.add(.of(.predator), @splat(0));
    try std.testing.expect(try aigeneric.push(ctx, ship, .fly_aimlessly, .none));
    // The Yamato lands the player's ship alone, and the Badanov and the Victorious offer no landing
    // unless a mod or a script gives them one. A Predator given a bay's landing has no launch point
    // to land at, and one given the Reliant's has no launch tube.
    const carriers = [_]struct { gameobj.Type, ?Style }{
        .{ .of(.yamato), null },
        .{ .of(.badanov), null },
        .{ .of(.victorious), null },
        .{ .of(.predator), .bay },
        .{ .of(.predator), .reliant },
    };
    for (carriers) |carrier_of| {
        const carrier = try mission.add(carrier_of[0], .{ 0, 0, 1000 });
        if (carrier_of[1]) |given| mission.slot(carrier).landing = given;
        try std.testing.expect(try aigeneric.pushShip(ctx, ship, .land, carrier, null));
        aigeneric.objectOrders(ctx, ship);
        try std.testing.expectEqual(.fly_aimlessly, mission.slot(ship).current().?.order);
    }
}

test endAfter {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var variables: @import("../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    mission.clock.frame_start = 1000;
    endAfter(world, 1000);
    try std.testing.expectEqual(0, variables.mission_over);
    mission.clock.frame_start = 1001;
    endAfter(world, 1000);
    try std.testing.expectEqual(1, variables.mission_over);
}

test landingCarrier {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    _ = try mission.add(.of(.predator), @splat(0));
    const reliant_carrier = try mission.add(.of(.reliant), .{ 0, 0, 1000 });
    const victorious = try mission.add(.of(.victorious), .{ 0, 0, 2000 });
    const world = mission.world();
    try std.testing.expectEqual(null, landingCarrier(world));
    mission.player.carrier = reliant_carrier;
    try std.testing.expectEqual(reliant_carrier, landingCarrier(world).?);
    // The Victorious offers no landing until a script gives it one.
    mission.player.carrier = victorious;
    try std.testing.expectEqual(null, landingCarrier(world));
    mission.slot(victorious).landing = .bay;
    try std.testing.expectEqual(victorious, landingCarrier(world).?);
}
