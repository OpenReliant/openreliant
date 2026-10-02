//! `C:\lancer\game\ailand.cpp`: Land, order 8, by which the player's ship lands on the carrier it
//! launched from, which ends the mission ([Landing](../../../docs/engine/orders.md#landing)). The
//! player asks for it with PERMISSION TO LAND (`videoreports.permissionToLand`). Its init picks one
//! of two styles by the carrier; each has its own init and update (`land_styles`, `0x004E1FE8`,
//! `0x18` bytes each: init, update, exit, 0, name and 0). OpenReliant has the Reliant's.
//!
//! **Unverified:** that `order_land` and the styles' routines (`0x0040EB40` to `0x0040FC77`) are
//! this file's. They lie after its known code, before `airipper.cpp`'s, and the style table
//! (`land_styles`, `0x004E1FE8`), just before this file's path, ties them to Land.
//!
//! Not ported: the Yamato's style ([#349](https://github.com/vdmkenny/openreliant/issues/349)),
//! whose landing OpenReliant lets go of at once.

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
const input = @import("../input.zig");
const objects = @import("objects.zig");
const reliant_launch = @import("launch/reliant.zig");
const sound3d = @import("sound3d.zig");

/// How a ship lands, by the carrier it lands on (`order_land_init`).
pub const Style = enum(u32) {
    /// On the Yamato, shown in its hangar (`land_yamato_init`, `0x0040EB60`, and
    /// `land_yamato_update`, `0x0040EE80`).
    yamato = 0,
    /// On the Reliant, down into its first launch tube through the tube's upper door
    /// (`reliantInit`, `reliantUpdate`).
    reliant = 1,
    /// OpenReliant's own: the order aims at nothing that can be landed on, and ends.
    none = std.math.maxInt(u32),
    _,

    /// The style of a landing on a ship of type `carrier`, or null for a ship that nothing lands
    /// on.
    pub fn of(carrier: gameobj.Type) ?Style {
        return switch (carrier) {
            .reliant => .reliant,
            .yamato => .yamato,
            else => null,
        };
    }
};

/// How the Reliant's landing brings the ship down.
pub const Touchdown = enum {
    /// **Improvement:** the ship levels out as it approaches (`flaredAim`) and stops dead, so that
    /// it sinks straight down the tube and comes to rest level in it; and once its top is below the
    /// tube's upper door, the door closes over it, sounding (`reliantUpdate`).
    level,
    /// As the game lands it: pitched as it came, coasting as it stops, the door left open.
    original,
};

/// The order's state (`GameObject.order_state`).
pub const State = extern struct {
    style: Style,
    /// The frame's tick the step waits for.
    due: i32,
    _unknown_08: u32,
    step: Step,
    /// The middle of the tube the ship lands in, where the cutaway has moved the carrier
    /// (`cutaway`).
    tube: [3]f32,
    /// OpenReliant's own: whether the tube's upper door has begun to close over the ship
    /// (`Touchdown.level`).
    door_closing: bool,

    comptime {
        assert(@offsetOf(State, "due") == 0x04);
        assert(@offsetOf(State, "step") == 0x0C);
        assert(@offsetOf(State, "tube") == 0x10);
    }
};

/// The Reliant's steps.
pub const Step = enum(u32) {
    /// The player flies on until the landing is due; then the cutaway begins, and the tube's upper
    /// door opens.
    waiting = 0,
    /// The ship flies to `over_tube`, slowing as it nears, and stops within `near`.
    approaching = 1,
    /// Stopped, it waits `settle` ticks.
    settling = 2,
    /// It sinks into the tube, slowing as it goes, and is down within `down_at` of its middle.
    sinking = 3,
    /// Down, it waits `landed_wait` ticks, and the mission is over.
    down = 4,
    _,
};

/// How long the player flies on before the Reliant's landing begins, in ticks (`0x0040F5EA`).
const wait: i32 = 700;

/// Where the cutaway moves the carrier, turned as the world is, far from what the mission holds
/// (`0x0040F600`).
const carrier_away: Vector = .{ 0, -1_000_000, 0 };

/// The Reliant's launch tube the ship lands down, its first (`0x0040F600`), halfway between whose
/// doors' middles it lands (`launch.reliant.tubeMiddle`); and that tube's upper door, a part of the
/// Reliant's root's child list (`launch.reliant.Door`), which opens as the landing begins.
const first_tube = 0;
const upper_door = reliant_launch.Door.upper.part(first_tube);

/// Where the cutaway sets the ship, in the carrier's frame from the tube's middle: ahead of it and
/// above it; and where the ship flies to, over the tube, where it first looks (`0x0040F600`).
const start_offset: Vector = .{ 0, -5000, 20000 };
const over_tube: Vector = .{ 0, -3000, 0 };

/// The upper door's track (`0x004E2050`), and how fast it plays to open the door (`0x0040FA55`).
/// It plays back to close the door as fast as the launch's tube doors open
/// (`launch.reliant.door_speed`), OpenReliant's choice (`Touchdown.level`).
const door_track = "opendoor2";
const door_speed: f32 = 1.23;

/// The throttle the ship approaches with for each unit it has to go, and the most it takes
/// (`0x004DC4B0`, `0x004DC408`); and how near it stops (`0x004DC468`).
const approach_throttle: f32 = 0.0001;
const approach_most: f32 = 0.5;
const near: f32 = 200;

/// How long the ship waits over the tube before it sinks, in ticks (`0x0040FB59`).
const settle: i32 = 50;

/// The throttle the ship sinks with for each unit it has to go (`0x004DC538`), and how far over the
/// tube's middle it is down, along the carrier's Y axis, which points below it (`0x004DC534`).
const sink_throttle: f32 = 1.0 / 15000.0;
const down_at: f32 = -100;

/// How long the mission goes on once the ship is down, in ticks (`0x0040FC4A`).
const landed_wait: i32 = 270;

/// `order_land_init` (`0x0040EAC0`): the style, by the type of the carrier the order aims at, and
/// the style's init.
///
/// **Fix:** the game stops with "Cannot land on %s" for a ship that nothing lands on; OpenReliant
/// logs it, and the update lets the order go.
pub fn init(ctx: Context, index: u16) void {
    const all = ctx.world.objects;
    const state = &all.slots[index].state.land;
    const carrier = all.slots[index].orders[0].target.slotIn(all);
    const carrier_type = if (carrier) |at| all.slots[at].object.type else null;
    state.style = if (carrier_type) |of| Style.of(of) orelse .none else .none;
    switch (state.style) {
        .reliant => reliantInit(ctx, index),
        .none => log.warn("object {d} cannot land on what its order aims at", .{index}),
        .yamato, _ => {},
    }
}

/// `order_land` (`0x0040EB40`): the style's update. A landing OpenReliant has no style for ends at
/// once.
pub fn update(ctx: Context, index: u16) void {
    const slot = &ctx.world.objects.slots[index];
    switch (slot.state.land.style) {
        .reliant => reliantUpdate(ctx, index),
        .yamato => {
            log.warn("object {d} does not land: the Yamato's landing is not ported", .{index});
            aigeneric.end(ctx, index);
        },
        .none, _ => aigeneric.end(ctx, index),
    }
}

/// `land_reliant_init` (`0x0040F5C0`): the first step, due `wait` ticks on, or at once where the
/// player's ship is being sent home for its friendly fire.
fn reliantInit(ctx: Context, index: u16) void {
    const state = &ctx.world.objects.slots[index].state.land;
    state.step = .waiting;
    state.due = ctx.world.clock.frame_start + if (ctx.world.player.ending.sentHome()) 0 else wait;
}

/// `land_reliant_update` (`0x0040F940`): a step of the Reliant's landing (`Step`).
///
/// While the landing is not yet due, the player's ship flies by the player's controls
/// (`input.playerControlOrder`). Then the cutaway begins (`cutaway`): the mission's scene becomes
/// the landing's, every object but the ship and the carrier is disabled and the two others
/// enabled, and the ship flies by its nose (`motion.Motion.plain`), passing through everything.
/// The carrier's first tube's upper door opens, sounding where it is (`playDoor`).
///
/// The ship steers at `over_tube`, its throttle `approach_throttle` for each unit it has to go, at
/// most `approach_most`, and stops within `near` of it, its turns nothing. It waits `settle` ticks,
/// then sinks along its own Y axis (`motion.Motion.downward`), its throttle `sink_throttle` for
/// each unit it stands from the tube's middle. Once it is less than `down_at` over it, it stops,
/// sounding its landing, and `landed_wait` ticks later the mission is over (`vm.Variables`).
fn reliantUpdate(ctx: Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const object = &slot.object;
    const state = &slot.state.land;
    const carrier = slot.orders[0].target.slotIn(all) orelse return;
    const now = ctx.world.clock.frame_start;
    switch (state.step) {
        .waiting => {
            if (now < state.due and index == all.player) return input.playerControlOrder(ctx, index);
            cutaway(ctx, index, carrier);
            world.player.showing = .landing;
            for (all.slots[0..all.count], 0..) |*each, at| each.object.flags.disabled = at != index and at != carrier;
            state.step = .approaching;
            slot.motion = .plain;
            object.flags.no_collisions = true;
            playDoor(world, &all.slots[carrier], .dooropen, 0, door_speed);
        },
        .approaching => {
            const frame = tubeFrame(state, &all.slots[carrier]);
            const point = switch (world.touchdown) {
                .level => flaredAim(frame, object),
                .original => frame.point(over_tube),
            };
            _ = ai.steer(world, index, point, ai.full_limit, ai.no_ease, .{});
            const distance = math.distance(point, object.nextPosition());
            object.throttle = @min(distance * approach_throttle, approach_most);
            if (distance >= near) return;
            object.letGo();
            if (world.touchdown == .level) ai.stop(object);
            state.step = .settling;
            state.due = now + settle;
        },
        .settling => {
            if (state.due >= now) return;
            state.step = .sinking;
            slot.motion = .downward;
        },
        .sinking => {
            const reliant = &all.slots[carrier];
            const frame = tubeFrame(state, reliant);
            const off = frame.inverse(object.nextPosition());
            object.throttle = math.length(off) * sink_throttle;
            // **Improvement:** the tube's upper door closes over the ship: its opening played back
            // from where it stands, as fast as the launch's tube doors open, with the game's sound
            // of a door closing (`0x36`, `doorclos`), as the opening had the sound of one opening
            // (`Touchdown.level`).
            if (world.touchdown == .level and !state.door_closing and belowDoor(reliant, frame, off[1] + object.bounds_min.y)) {
                state.door_closing = true;
                playDoor(world, reliant, .doorclos, objects.Model.keep_time, -reliant_launch.door_speed);
            }
            if (off[1] <= down_at) return;
            object.letGo();
            sound3d.playIn(world, null, null, index, .shipland, 1, .not_reserved);
            state.step = .down;
            state.due = now + landed_wait;
        },
        .down => {
            if (state.due >= now) return;
            if (world.variables) |variables| variables.mission_over = 1;
        },
        _ => {},
    }
}

/// `land_reliant_cutaway` (`0x0040F600`): the cutaway of the Reliant's landing. One of its two
/// views, picked at random, watches the ship, locked. The carrier moves to `carrier_away`, turned
/// as the world is, and the middle of its first launch tube is worked out there: halfway between
/// the middles of the tube's doors, each the middle of the bounds of the level its part drew last
/// (`launch.reliant.tubeMiddle`). The ship stands at `start_offset` from it in the carrier's frame,
/// looking at `over_tube`, stopped, its power shared evenly. The carrier's orders are all popped,
/// and it stops.
fn cutaway(ctx: Context, index: u16, carrier: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.land;
    if (world.camera) |view| {
        const pick: camera.View = if (world.random.rand() % 2 == 0) .landing_aside else .landing_tube;
        _ = view.setView(pick, index, true, true, ctx.world.clock.viewTime());
    }
    const reliant = &all.slots[carrier];
    objects.setPlace(&reliant.object, &reliant.drawn, .{ .position = carrier_away, .orientation = math.identity });
    if (reliant_launch.tubeMiddle(reliant, first_tube, 0)) |tube| state.tube = tube;
    const frame = tubeFrame(state, reliant);
    const object = &slot.object;
    objects.setPosition(object, &slot.drawn, frame.point(start_offset));
    const look = frame.point(over_tube);
    objects.setOrientation(object, &slot.drawn, math.lookAt(look - object.nextPosition()));
    ai.stop(object);
    object.gun_factor = 1;
    object.speed_factor = 1;
    object.shield_factor = 1;
    aigeneric.popAll(ctx, carrier);
    ai.stop(&reliant.object);
}

/// The frame the landing goes by: the middle of the tube the cutaway worked out (`State.tube`),
/// turned as `carrier` will be next.
fn tubeFrame(state: *const State, carrier: *const create.Slot) math.Place {
    return .{ .position = state.tube, .orientation = carrier.object.root.next_orientation };
}

/// **Improvement:** the point the ship steers at as it approaches, in the tube's frame `frame`
/// (`tubeFrame`), so that it levels out as it comes rather than pitching as it arrives
/// (`Touchdown.level`). It stands over the tube's middle, at first at the game's height,
/// `over_tube`; as the ship nears, eased in and out over the way the cutaway set it to come, it
/// rises to the ship's own height, which it takes once the ship is over the tube.
fn flaredAim(frame: math.Place, object: *const gameobj.GameObject) Vector {
    const off = frame.inverse(object.nextPosition());
    const across = @sqrt(off[0] * off[0] + off[2] * off[2]);
    const share = std.math.clamp(1 - across / start_offset[2], 0, 1);
    const eased = share * share * (3 - 2 * share);
    return frame.point(.{ 0, math.lerp(over_tube[1], off[1], eased), 0 });
}

/// Whether a ship whose top stands `top` along the Y axis of the tube's frame `frame` (`tubeFrame`)
/// is below the underside of the tube's upper door, as the level the door drew last bounds it.
/// False where the Reliant's model lacks the door.
fn belowDoor(reliant: *const create.Slot, frame: math.Place, top: f32) bool {
    const model = if (reliant.model) |*held| held else return false;
    const bounds = model.levelBounds(upper_door) orelse return false;
    const middle = model.boundsMiddle(upper_door) orelse return false;
    const underside = model.frameAt(upper_door, reliant.drawn).point(.{ middle[0], bounds[1][1], middle[2] });
    return top > frame.inverse(underside)[1];
}

/// Plays the upper door's track (`door_track`) from `from` at `speed`, sounding `which` where the
/// door stands, facing as it does; nothing where the Reliant's model lacks the door.
fn playDoor(world: gameobj.World, reliant: *create.Slot, which: sound3d.sounds.Sound, from: f32, speed: f32) void {
    const model = if (reliant.model) |*held| held else return;
    if (model.rootChild(upper_door) == null) return;
    sound3d.playFrom(world, model.frameAt(upper_door, reliant.drawn), which, .guaranteed);
    model.playNamed(upper_door, door_track, from, null, speed);
}

/// What the landing's views stand by where the object in slot `index` is landing
/// (`camera.View.landing_tube`, `landing_aside`): the middle of the tube its state keeps, and how
/// its carrier is turned as it is drawn.
pub fn seen(all: *const create.Objects, index: u16) ?camera.Landing {
    if (index >= all.slots.len) return null;
    const slot = &all.slots[index];
    const entry = slot.running(.land) orelse return null;
    const carrier = entry.target.slotIn(all) orelse return null;
    return .{ .tube = slot.state.land.tube, .carrier = all.slots[carrier].drawn.orientation };
}

test Style {
    try std.testing.expectEqual(Style.reliant, Style.of(.reliant).?);
    try std.testing.expectEqual(Style.yamato, Style.of(.yamato).?);
    try std.testing.expectEqual(null, Style.of(.predator));
}

test "the player's ship lands on the Reliant, and the mission is over" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var variables: @import("../vm.zig").Variables = .{};
    var world = mission.world();
    world.variables = &variables;
    const ctx: Context = .of(world);
    const player = try mission.add(.predator, .{ 100, 0, 0 });
    const reliant = try mission.add(.reliant, .{ 0, 0, 50000 });
    const other = try mission.add(.predator, .{ 5, 5, 5 });
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
    const slot = mission.slot(player);
    const state = &slot.state.land;

    // The Reliant's style, due `wait` ticks on, until which the player flies on.
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Style.reliant, state.style);
    try std.testing.expectEqual(Step.waiting, state.step);
    try std.testing.expectEqual(1000 + wait, state.due);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.waiting, state.step);

    // Then the cutaway: the Reliant stopped far away, the ship ahead of its tube and above it,
    // flying by its nose and passing through everything, and every other object disabled.
    mission.clock.frame_start = 1000 + wait;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.approaching, state.step);
    try std.testing.expectEqual(@import("main.zig").Showing.landing, mission.player.showing);
    try std.testing.expect(mission.slot(other).object.flags.disabled);
    try std.testing.expect(!mission.slot(reliant).object.flags.disabled and !slot.object.flags.disabled);
    try std.testing.expectEqual(carrier_away, mission.slot(reliant).object.nextPosition());
    try std.testing.expectEqual(0, mission.slot(reliant).object.order_count);
    const tube: Vector = state.tube;
    try std.testing.expectEqual(tube + start_offset, slot.object.nextPosition());
    try std.testing.expectEqual(@import("motion.zig").Motion.plain, slot.motion.?);
    try std.testing.expect(slot.object.flags.no_collisions);

    // Far from the point over the tube, it approaches at its most; within `near`, it stops.
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(approach_most, slot.object.throttle);
    objects.setPosition(&slot.object, &slot.drawn, tube + over_tube + Vector{ 0, 0, 150 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.settling, state.step);
    try std.testing.expectEqual(0, slot.object.throttle);

    // It waits `settle` ticks, and sinks along its Y axis, slowing as it nears the tube's middle.
    mission.ordersAfter(ctx, player, settle);
    try std.testing.expectEqual(Step.settling, state.step);
    mission.ordersAfter(ctx, player, 1);
    try std.testing.expectEqual(Step.sinking, state.step);
    try std.testing.expectEqual(@import("motion.zig").Motion.downward, slot.motion.?);
    objects.setPosition(&slot.object, &slot.drawn, tube + Vector{ 0, -1500, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectApproxEqAbs(1500 * sink_throttle, slot.object.throttle, 1e-6);
    objects.setPosition(&slot.object, &slot.drawn, tube + Vector{ 0, -50, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.down, state.step);
    try std.testing.expectEqual(0, slot.object.throttle);

    // `landed_wait` ticks after it is down, the mission is over.
    mission.ordersAfter(ctx, player, landed_wait);
    try std.testing.expectEqual(0, variables.mission_over);
    mission.ordersAfter(ctx, player, 1);
    try std.testing.expectEqual(1, variables.mission_over);
}

test flaredAim {
    var object = std.mem.zeroes(gameobj.GameObject);
    const frame: math.Place = .{ .position = .{ 0, 0, 1000 } };
    const tube = frame.position;
    // Where the cutaway sets the ship, the game's point over the tube.
    object.root.next_position = gameobj.vec3(tube + start_offset);
    try std.testing.expectEqual(tube + over_tube, flaredAim(frame, &object));
    // Half way there, the point has risen half way to the ship's height.
    object.root.next_position = gameobj.vec3(tube + Vector{ 0, -4000, start_offset[2] / 2 });
    try std.testing.expectApproxEqAbs(-3500, flaredAim(frame, &object)[1], 1e-2);
    // Over the tube's middle, at the ship's own height, so that it flies level.
    object.root.next_position = gameobj.vec3(tube + Vector{ 0, -3800, 0 });
    try std.testing.expectApproxEqAbs(-3800, flaredAim(frame, &object)[1], 1e-2);
}

test "the ship lands in the Reliant's first tube, and its upper door closes over it" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var reliant_model: reliant_launch.testing.Reliant = undefined;
    try reliant_model.init(gpa);
    defer reliant_model.deinit(gpa);
    var world = mission.world();
    world.touchdown = .level;
    const ctx: Context = .of(world);
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 50000 });
    try reliant_model.fit(gpa, mission.slot(reliant));
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
    const slot = mission.slot(player);
    const state = &slot.state.land;
    aigeneric.objectOrders(ctx, player);
    mission.clock.frame_start = wait + 1;
    aigeneric.objectOrders(ctx, player);

    // The cutaway works out the tube's middle where it has moved the carrier, turned as the world
    // is: halfway between the lower door, part 0, and the upper door, part 6, 500 above it.
    const tube: Vector = state.tube;
    try std.testing.expectEqual(carrier_away + Vector{ 0, -250, 0 }, tube);
    try std.testing.expectEqual(tube + start_offset, slot.object.nextPosition());

    // Sinking, the door stays open while the ship's top is above the door's underside, 150 over
    // the tube's middle; once its top is below it, the door closes over it, and stays closing.
    state.step = .sinking;
    slot.object.bounds_min.y = -20;
    objects.setPosition(&slot.object, &slot.drawn, tube + Vector{ 0, -1500, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expect(!state.door_closing);
    objects.setPosition(&slot.object, &slot.drawn, tube + Vector{ 0, -120, 0 });
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(Step.sinking, state.step);
    try std.testing.expect(state.door_closing);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expect(state.door_closing);
}

test "a ship sent home for its friendly fire lands at once" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 50000 });
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
    mission.player.ending = .friendly_fire;
    mission.clock.frame_start = 1000;
    aigeneric.objectOrders(ctx, player);
    const state = &mission.slot(player).state.land;
    try std.testing.expectEqual(1000, state.due);
    try std.testing.expectEqual(Step.approaching, state.step);
}

test "over the tube, a ship stops dead, or coasts as the game lets it" {
    for ([_]Touchdown{ .level, .original }) |touchdown| {
        var mission: gameobj.testing.Mission = undefined;
        try mission.init(std.testing.allocator);
        defer mission.deinit();
        var world = mission.world();
        world.touchdown = touchdown;
        const ctx: Context = .of(world);
        const player = try mission.add(.predator, @splat(0));
        const reliant = try mission.add(.reliant, .{ 0, 0, 50000 });
        try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
        const slot = mission.slot(player);
        const state = &slot.state.land;
        aigeneric.objectOrders(ctx, player);
        mission.clock.frame_start = wait + 1;
        aigeneric.objectOrders(ctx, player);
        objects.setPosition(&slot.object, &slot.drawn, @as(Vector, state.tube) + over_tube + Vector{ 0, 0, 150 });
        slot.object.velocity = .{ .x = 0, .y = 0, .z = -5 };
        aigeneric.objectOrders(ctx, player);
        try std.testing.expectEqual(Step.settling, state.step);
        try std.testing.expectEqual(@as(f32, if (touchdown == .level) 0 else -5), slot.object.velocity.z);
    }
}

test "a landing on the Yamato, or on what nothing lands on, is let go" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const player = try mission.add(.predator, @splat(0));
    try std.testing.expect(try aigeneric.push(ctx, player, .player_control, .none));
    for ([_]gameobj.Type{ .yamato, .predator }) |carrier_type| {
        const carrier = try mission.add(carrier_type, .{ 0, 0, 1000 });
        try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, carrier, null));
        aigeneric.objectOrders(ctx, player);
        try std.testing.expectEqual(.player_control, mission.slot(player).current().?.order);
    }
}

test seen {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 1000 });
    try std.testing.expectEqual(null, seen(mission.objects, player));
    try std.testing.expect(try aigeneric.pushShip(ctx, player, .land, reliant, null));
    mission.slot(player).state.land.tube = .{ 1, 2, 3 };
    const landing = seen(mission.objects, player).?;
    try std.testing.expectEqual(Vector{ 1, 2, 3 }, landing.tube);
    try std.testing.expectEqual(mission.slot(reliant).drawn.orientation, landing.carrier);
}
