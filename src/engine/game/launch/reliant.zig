//! The Reliant's launches (`launch_reliant_init`, `0x0041AE20`, and `launch_reliant_run`,
//! `0x0041B240`): a ship drops out of the Reliant through one of its six tubes, each shut by a
//! door above and one below. The player's ship is shown lowered within the Reliant's hangar
//! (`reliant_hang.shp`), a cutaway made in the cutaway slot and laid over the tube, and one of
//! three cutaway views (`Cutaway`) watches it go.

const std = @import("std");
const log = std.log.scoped(.launch);

const libcmt = @import("../../libcmt.zig");
const math = @import("../../surrender/math.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const aigeneric = @import("../aigeneric.zig");
const camera = @import("../camera.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const hog_snd = @import("../hog_snd.zig");
const objects = @import("../objects.zig");
const sound3d = @import("../sound3d.zig");
const launch = @import("../launch.zig");

/// A launch's steps from the Reliant, each named for what it does as it runs, once the wait the
/// step before set has passed (`launch.State.due`).
pub const Step = enum(i32) {
    /// The ship's engine starts, for the player's with a shake, the cutaway is picked, and the
    /// tube's upper door shows.
    start = 2,
    /// The hangar's retainer lowers the player's ship.
    lower = 3,
    /// The retainer lets go, and the ship no longer rides its node.
    release = 4,
    /// The tube's lower door opens, and the hangar's.
    open = 5,
    /// The ship drops out, the mission's date typed out on the player's screen.
    drop = 6,
    /// Clear of the bay, the cutaway ends.
    clear = 7,
    /// It drops on.
    fall = 8,
    /// It steadies, flying ahead again.
    level = 9,
    /// The launch ends.
    end = 10,
    _,

    /// The step after it.
    fn next(step: Step) Step {
        return @enumFromInt(@intFromEnum(step) + 1);
    }
};

/// How long each step waits for the next, in ticks (`launch_reliant_run`, `0x0041B287`,
/// `0x0041B382`, `0x0041B3D9`, `0x0041B4AB`, `0x0041B503`, `0x0041B55E`, `0x0041B575`, and
/// `0x0041B5BE` for a ship not the player's; the player's ends at once).
fn wait(step: Step) i32 {
    return switch (step) {
        .start => 100,
        .lower => 250,
        .release => 50,
        .open => 150,
        .drop => 50,
        .clear => 150,
        .fall => 300,
        .level => 200,
        .end, _ => 0,
    };
}

/// Which of the three cutaways the player's launch shows (`launch_cutaway`, `0x0051D0EC`),
/// picked at random as it starts: none from the mission's load (`launches_init`, `0x00418A70`).
pub const Cutaway = enum(i32) {
    none = -1,
    /// From within the bay, from the start (`camera.View.launch_bay`).
    bay = 1,
    /// From below, once the ship is clear (`camera.View.launch_below`).
    below = 2,
    /// From aside, from the door's opening, the hangar gone (`camera.View.launch_aside`).
    aside = 3,
    _,

    /// How many cutaways `pick` picks among (`0x0041B2CB`).
    const cutaways = 3;

    /// One of the three, picked from the runtime's numbers as the player's launch starts
    /// (`0x0041B2C5` to `0x0041B2D6`): the remainder of `random`'s next over `cutaways`, counted
    /// from the first, the bay's.
    pub fn pick(random: *libcmt.Rand) Cutaway {
        return @enumFromInt(@as(i32, random.rand() % cutaways) + @intFromEnum(Cutaway.bay));
    }
};

/// The shake the player's ship's engine starts with (`hit_shake`, `0x0041B2A4`).
const start_shake: f32 = 0.1;

/// How far on from a tube's lower door its upper door is in the Reliant's root's child list
/// (`0x0041AEBF`, `0x0041B30A`).
pub const door_step = 6;

/// The doors of a tube, each a part of the Reliant's root's child list: the lower door is part
/// `gate`, the upper `door_step` on.
pub const Door = enum {
    lower,
    upper,

    /// Its part in the Reliant's root's child list for tube `gate`.
    pub fn part(door: Door, gate: usize) usize {
        return gate + @as(usize, @intFromEnum(door)) * door_step;
    }
};

/// How far across a tube's middle lies from its doors', in their frames: to the right for a gate
/// of even number, to the left for an odd (`0x004DC5A8`).
const tube_offset: f32 = 400;

/// The hangar's parts that its dim light alone reaches: its hull and its two doors, the first
/// three of its root's child list (`0x0041B10C`).
const lit_parts = 3;

/// The light mask the hangar's hull and doors take (`0x0041B10C`): every light of the backdrop's
/// but its first ambient (`backdrop.Lights`, `0x04`) is kept out, so that only their baked
/// colours, the ambient's glimmer and the lights that reach every object light them.
const hangar_light_mask: u32 = 0x3B;

/// The hangar's parts the launch plays tracks on: its lower door (`0x0041B449`), which opens as
/// the tube's does, and its retainer (`0x0041B354`), which lowers the ship.
const hangar_door = 2;
const hangar_retainer = 3;

/// **Improvement:** how much farther the hangar's two beacons reach, whose own reach falls short of
/// the ship on the retainer by about a quarter; the share of their flash the red walls throw back
/// on the ship and its cockpit, which the beacons light on the nose, out of the cutaways' sight;
/// and the light bit that share goes by, which every part of the hangar keeps out, one no light of
/// the game's has (`objects.HangarBeacons`).
const beacon_reach: f32 = 2;
const beacon_bounce: f32 = 0.1;
const bounce_mask: u32 = 0x40;

/// The hangar's launch points: the first for a gate of odd number, the second, turned half a turn
/// with the hangar, for an even (`0x0041B15E`, `0x0041B174`).
const hangar_points = [2]i16{ 0, 1 };

/// The tracks the launch plays (`node_play_named`): the doors' opening (`0x004E1728`), and the
/// retainer's lowering (`0x004E1690`).
const open_track = "opendoor";
const deploy_track = "deploy";

/// How fast the launch plays its tracks: the tube's lower door's opening (`0x0041B3E7`), the
/// hangar's door's (`0x0041B42E`), the upper door's closing back (`0x0041B2FB`), and the
/// retainer's lowering, played back to raise it (`0x0041B339`, `0x0041B3A1`).
pub const door_speed: f32 = 2;
const hangar_door_speed: f32 = 4;
const upper_door_speed: f32 = -1;
const retainer_speed: f32 = 2;

/// The standard samples the player hears (`bank_stdsmp`): the retainer's clamps as it lowers the
/// ship (`0x0041B362`), and the doors as they open (`0x0041B457`), as loud as they go
/// (`0x0041B36D`, `0x0041B462`).
const lowered_sample = 6;
const opened_sample = 5;
const sample_volume = 127;

/// `launch_reliant_init` (`0x0041AE20`): readies the ship in slot `index` to launch from the
/// Reliant in slot `carrier`, through the gate its order's target names by its component. It
/// rides the Reliant's root, its steering and its throttle nothing, and stands in its tube
/// (`tube`), turned as the Reliant turns next. The player's ship's launch shows the hangar
/// (`showHangar`), in which it rides the retainer; the Reliant becomes the ship the player launched
/// from (`input.Player.carrier`), which the cutaway leaves out, and the camera takes view 0 in the
/// cockpit mode, locked.
///
/// **Fix:** the game reads through a tube door the Reliant's model lacks; OpenReliant leaves the
/// ship where it stands.
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    slot.riding = .{ .object = carrier };
    const object = &slot.object;
    object.letGo();
    const gate = slot.orders[0].target.component;
    const reliant = &all.slots[carrier];
    const in_tube = tube(reliant, gate) orelse {
        log.warn("the Reliant in slot {d} has no tube {d}", .{ carrier, gate });
        return;
    };
    const turn = reliant.object.root.next_orientation;
    objects.setPlace(object, &slot.drawn, .{ .position = in_tube, .orientation = turn });
    if (index != all.player) return;
    world.player.carrier = carrier;
    showHangar(ctx, index, gate, in_tube, turn);
    if (world.camera) |view| {
        view.cockpit_mode = .cockpit;
        _ = view.setView(.cockpit, all.player, true, true, ctx.world.clock.viewTime());
    }
    world.player.showing = .launch;
}

/// Where a ship launching through `gate` stands in `reliant`: in the middle of the gate's tube
/// (`tubeMiddle`), `tube_offset` across. Null where the gate is none, or the Reliant's model lacks
/// either door, or its part has no level.
fn tube(reliant: *const create.Slot, gate: i16) ?math.Vector {
    const number = std.math.cast(usize, gate) orelse return null;
    const across: f32 = if (evenGate(gate)) tube_offset else -tube_offset;
    return tubeMiddle(reliant, number, across);
}

/// Whether `gate` is of even number: its tube's middle lies to the right (`0x0041AF2D`), the
/// hangar turns half a turn with it (`0x0041B0FC`), and the bay's view stands on the ship's left
/// (`camera.Camera.setLaunch`).
fn evenGate(gate: i16) bool {
    return @mod(gate, 2) == 0;
}

/// The middle of tube `gate`, as `reliant` is drawn: halfway between the middles of the bounds of
/// the levels its two doors (`Door`) drew last, each `across` to the side in its door's frame, as
/// the launch (`launch_reliant_init`) and the landing (`land_reliant_cutaway`) work it out. Null
/// where the model lacks either door, or its part has no level.
pub fn tubeMiddle(reliant: *const create.Slot, gate: usize, across: f32) ?math.Vector {
    const model = if (reliant.model) |*held| held else return null;
    var sum: math.Vector = @splat(0);
    for (std.enums.values(Door)) |door| {
        const part = door.part(gate);
        var middle = model.boundsMiddle(part) orelse return null;
        middle[0] += across;
        sum += model.frameAt(part, reliant.drawn).point(middle);
    }
    return sum * @as(math.Vector, @splat(0.5));
}

/// The hangar the player's ship launches in, as `init` shows it: made in the cutaway slot, passing
/// through everything, its hull and doors lit by its dim light alone (`hangar_light_mask`), and
/// laid over the tube so that the ship stands `in_tube` at one of its launch points
/// (`hangar_points`): the ship is placed at the point with the hangar at the origin, turned as the
/// Reliant is, or half a turn more for a gate of even number (`launch.attach`), the hangar moves by
/// the way from there to the tube, and the ship is placed at the point again, riding the retainer.
///
/// **Improvement:** with `objects.HangarBeacons.to_the_ship`, the beacons reach `beacon_reach`
/// times as far and throw `beacon_bounce` of their flash back on the ship and its cockpit.
fn showHangar(ctx: aigeneric.Context, index: u16, gate: i16, in_tube: math.Vector, turn: math.Matrix) void {
    const world = ctx.world;
    const all = world.objects;
    const hangar = create.make(world, create.cutaway_slot, .reliant_hangar) catch |err| {
        log.warn("the Reliant's hangar is left out: {s}", .{@errorName(err)});
        return;
    } orelse return;
    const shown = &all.slots[hangar];
    shown.object.flags.no_collisions = true;
    if (shown.model) |*model| {
        for (model.parts[0..@min(lit_parts, model.parts.len)]) |*part| part.object.light_mask = hangar_light_mask;
        if (world.hangar_beacons == .to_the_ship) {
            model.reachFarther(beacon_reach);
            model.bounceLights(beacon_bounce, bounce_mask);
        }
    }
    const even = evenGate(gate);
    const point = hangar_points[@intFromBool(even)];
    objects.setPlace(&shown.object, &shown.drawn, .{ .position = @splat(0), .orientation = if (even) math.turned(turn, .y, std.math.pi) else turn });
    launch.attach(all, index, hangar, point);
    const shift = in_tube - all.slots[index].object.nextPosition();
    objects.setPosition(&shown.object, &shown.drawn, shift);
    launch.attach(all, index, hangar, point);
}

/// `launch_reliant_run` (`0x0041B240`): the launch of the ship in slot `index` from the Reliant, a
/// step (`Step`) each time the wait the last set has passed:
///
/// 1. `start`: for the player's ship, the engine starts sounding with a shake, one of the three
///    cutaways is picked from the runtime's numbers (`Cutaway.pick`), the bay's view taking the
///    camera at once, and the tube's upper door shows, playing its opening backwards.
/// 2. `lower`: the hangar's retainer lowers the player's ship, its clamps heard.
/// 3. `release`: the retainer rises again, and the ship rides its node no more.
/// 4. `open`: the tube's lower door opens. For the player's ship the cutaway shows, the hangar's
///    door opens too, heard, and with the aside cutaway the camera takes that view as the hangar
///    goes.
/// 5. `drop`: the ship drops (`motion.Motion.downward`), at full throttle; on the player's screen
///    the mission's date is typed out (`hud.Caption`). **Improvement:** the hangar's walls throw
///    the beacons' flash on it no more (`objects.Model.endBounce`).
/// 6. `clear`: out of the bay's view, the player's cutaway ends, and with the cutaway from below
///    the camera takes that view.
/// 7. `fall`, 8. `level`: after a while the ship flies ahead again, steering nothing and at no
///    throttle.
/// 9. `end`: for the player's ship, the date goes, the camera leaves the cutaway for view 0 in the
///    cockpit mode the options' setting picks, and the hangar goes; the ship passes through the
///    Reliant no more, and the launch ends (`launch.letGo`).
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.launch;
    const now = ctx.world.clock.frame_start;
    if (state.due >= now) return;
    const player = index == all.player;
    switch (state.step.as(Step)) {
        .start => {
            moveOn(state, .start, now);
            if (!player) return;
            world.shake.* = start_shake;
            sound3d.playIn(world, null, null, index, sound3d.engineSound(slot.object.type), 0, .player_engines);
            world.player.cutaway = .pick(world.random);
            if (world.player.cutaway == .bay) switchView(ctx, .launch_bay, index);
            if (tubeDoor(all, slot, .upper)) |door| {
                door.model.playNamed(door.part, open_track, 0, .swing, upper_door_speed);
                door.model.parts[door.part].hidden = false;
            }
        },
        .lower => {
            if (player) {
                playOnHangar(all, hangar_retainer, deploy_track, 0, retainer_speed);
                playSample(world, lowered_sample);
            }
            moveOn(state, .lower, now);
        },
        .release => {
            if (player) playOnHangar(all, hangar_retainer, deploy_track, objects.Model.keep_time, -retainer_speed);
            state.attached = false;
            moveOn(state, .release, now);
        },
        .open => {
            if (tubeDoor(all, slot, .lower)) |door| door.model.playNamed(door.part, open_track, 0, null, door_speed);
            if (player) {
                world.player.showing = .launch;
                playOnHangar(all, hangar_door, open_track, 0, hangar_door_speed);
                playSample(world, opened_sample);
                if (world.player.cutaway == .aside) {
                    switchView(ctx, .launch_aside, all.player);
                    all.resetSlot(create.cutaway_slot, world.random);
                    world.player.showing = .everything;
                }
            }
            moveOn(state, .open, now);
        },
        .drop => {
            if (player) if (world.display) |display| display.caption.start(ctx.world.clock.game_ticks);
            // The ship leaves the hangar, whose walls throw the beacons' flash on it no more.
            if (player) if (hangarModel(all)) |model| model.endBounce();
            slot.motion = .downward;
            slot.object.throttle = 1;
            moveOn(state, .drop, now);
        },
        .clear => {
            const in_bay = if (world.camera) |view| view.view == .launch_bay else false;
            if (player and !in_bay) {
                world.player.showing = .everything;
                all.resetSlot(create.cutaway_slot, world.random);
                if (world.player.cutaway == .below) switchView(ctx, .launch_below, index);
            }
            moveOn(state, .clear, now);
        },
        .fall => moveOn(state, .fall, now),
        .level => {
            slot.motion = .forward;
            slot.object.letGo();
            // The player's launch ends at the next update.
            if (player) state.step = .of(Step.end) else moveOn(state, .level, now);
        },
        .end => {
            if (player) {
                if (world.display) |display| display.caption.stop();
                if (world.camera) |view| {
                    view.cockpit_mode = view.setting.mode();
                    switch (view.view) {
                        .launch_bay, .launch_below, .launch_aside => _ = view.setView(.cockpit, index, false, true, ctx.world.clock.viewTime()),
                        else => {},
                    }
                }
                all.resetSlot(create.cutaway_slot, world.random);
                world.player.showing = .everything;
            }
            launch.letGo(ctx, index);
        },
        _ => {},
    }
}

/// Moves on from step `from` to the next, which runs once `from`'s wait has passed from `now`.
fn moveOn(state: *launch.State, from: Step, now: i32) void {
    state.advance(.of(from.next()), now, wait(from));
}

/// The door `door` of the tube the ship in `slot` launches through, its order's gate, in its
/// carrier's model, where there is one.
fn tubeDoor(all: *create.Objects, slot: *const create.Slot, door: Door) ?struct { model: *objects.Model, part: usize } {
    const target = slot.orders[0].target;
    const carrier = target.slotIn(all) orelse return null;
    const model = if (all.slots[carrier].model) |*held| held else return null;
    const part = door.part(target.part() orelse return null);
    if (part >= model.parts.len) return null;
    return .{ .model = model, .part = part };
}

/// The hangar's model, where the hangar stands in the cutaway slot.
fn hangarModel(all: *create.Objects) ?*objects.Model {
    const hangar = &all.slots[create.cutaway_slot];
    if (hangar.object.type != .reliant_hangar) return null;
    return if (hangar.model) |*held| held else null;
}

/// Plays `track` on the hangar's part `part` from `time` at `speed`, where the hangar stands in
/// the cutaway slot.
fn playOnHangar(all: *create.Objects, part: usize, track: []const u8, time: f32, speed: f32) void {
    const model = hangarModel(all) orelse return;
    if (part < model.parts.len) model.playNamed(part, track, time, null, speed);
}

/// Plays standard sample `index` in the middle, once, where the world is heard. **Improvement:** it
/// rings in the hangar, as the sounds of the scene do (`hog_snd.Sound.inScene`).
fn playSample(world: gameobj.World, index: usize) void {
    const hearing = world.hearing orelse return;
    const bank = hearing.sound.stdsmp orelse return;
    _ = hearing.sound.playInScene(bank, index, sample_volume, hog_snd.once, hog_snd.centre, hog_snd.own_pitch);
}

/// Switches the camera to one of the launch's views, `view`, of the object in slot `object`
/// (`camera.Camera.setLaunch`): the bay's beside the object on the side of its order's gate.
fn switchView(ctx: aigeneric.Context, view: camera.View, object: u16) void {
    const watching = ctx.world.camera orelse return;
    const all = ctx.world.objects;
    const seen = &all.slots[object];
    const gate = seen.orders[0].target.component;
    _ = watching.setLaunch(view, object, ctx.world.clock.viewTime(), .of(seen), .of(&all.slots[all.player]), evenGate(gate));
}

/// Fixtures for the tests here and in the landing's (`ailand`).
pub const testing = struct {
    /// A Reliant's model: its twelve tube doors, the lower door of gate `g` 1000 along X for each
    /// gate and the upper 500 above it, each part's level the square test mesh, whose middle is its
    /// origin. Set it up where it stays, as its records point into it.
    pub const Reliant = struct {
        mesh: srapiext.Mesh,
        levels: [1]srapiext.Level,
        parts: objects.testing.Parts(2 * door_step),

        pub fn init(reliant: *Reliant, gpa: std.mem.Allocator) !void {
            reliant.mesh = try @import("../../surrender/surrenderlib/srmesh.zig").testing.square(gpa);
            reliant.levels = .{.{ .mesh = &reliant.mesh, .until = std.math.inf(f32) }};
            reliant.parts.init();
            for (&reliant.parts.data, &reliant.parts.loaded_parts, 0..) |*part, *loaded, n| {
                const gate: f32 = @floatFromInt(n % door_step);
                part.part.position = .{ .x = 1000 * gate, .y = if (n < door_step) 0 else -500, .z = 0 };
                loaded.levels = &reliant.levels;
            }
        }

        pub fn deinit(reliant: *Reliant, gpa: std.mem.Allocator) void {
            reliant.mesh.deinit(gpa);
        }

        /// Gives the Reliant in `slot` the model.
        pub fn fit(reliant: *const Reliant, gpa: std.mem.Allocator, slot: *create.Slot) std.mem.Allocator.Error!void {
            return reliant.parts.fit(gpa, slot);
        }
    };
};

/// Runs the launch of the ship in slot `index` on to its step `step` with `ctx`, moving the clock
/// past each wait, and returns the frame's tick it came to it at.
fn runTo(mission: *gameobj.testing.Mission, ctx: aigeneric.Context, index: u16, step: Step) i32 {
    const state = &mission.slot(index).state.launch;
    while (state.step.as(Step) != step) launch.testing.pastDue(mission, ctx, index);
    return mission.clock.frame_start;
}

/// Runs the launch of the ship in slot `index` with `ctx` until it ends, moving the clock past each
/// wait.
fn runOut(mission: *gameobj.testing.Mission, ctx: aigeneric.Context, index: u16) void {
    while (mission.slot(index).object.order_count > 0) launch.testing.pastDue(mission, ctx, index);
}

test "a ship drops out of the Reliant's tube, step by step" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var reliant_model: testing.Reliant = undefined;
    try reliant_model.init(gpa);
    defer reliant_model.deinit(gpa);
    _ = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 10000 });
    try reliant_model.fit(gpa, mission.slot(reliant));
    const ship = try mission.add(.sabre, @splat(0));
    const slot = mission.slot(ship);
    slot.object.throttle = 1;
    const ctx = mission.orders();

    // Through gate 2 it stands between the gate's doors, 400 across to the right, turned as the
    // Reliant, riding its root, its throttle nothing.
    _ = try aigeneric.pushShip(ctx, ship, .launch, reliant, 2);
    aigeneric.objectOrders(ctx, ship);
    try std.testing.expectEqual(math.Vector{ 2400, -250, 10000 }, slot.drawn.position);
    try std.testing.expectEqual(objects.NodeOf{ .object = reliant }, slot.riding.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    // Through gate 3, 400 to the left.
    try std.testing.expectEqual(math.Vector{ 2600, -250, 10000 }, tube(mission.slot(reliant), 3).?);

    // Started, it waits a moment, then each step waits for the last.
    launch.start(mission.objects, ship);
    aigeneric.objectOrders(ctx, ship);
    const state = &slot.state.launch;
    var at = runTo(&mission, ctx, ship, .lower);
    try std.testing.expectEqual(at + wait(.start), state.due);
    at = runTo(&mission, ctx, ship, .open);
    try std.testing.expect(!state.attached);
    at = runTo(&mission, ctx, ship, .clear);
    // It drops at full throttle.
    try std.testing.expectEqual(.downward, slot.motion.?);
    try std.testing.expectEqual(1, slot.object.throttle);
    at = runTo(&mission, ctx, ship, .end);
    // Then it flies ahead again, steering nothing, at no throttle.
    try std.testing.expectEqual(.forward, slot.motion.?);
    try std.testing.expectEqual(0, slot.object.throttle);
    try std.testing.expectEqual(at + wait(.level), state.due);
    // At last its launch ends: it passes through the Reliant no more and can be targeted.
    launch.testing.pastDue(&mission, ctx, ship);
    try std.testing.expectEqual(0, slot.object.order_count);
    try std.testing.expectEqual(null, slot.object.passes_through[0].index());
}

test "Cutaway.pick" {
    var random: libcmt.Rand = .{};
    for (0..30) |_| switch (Cutaway.pick(&random)) {
        .bay, .below, .aside => {},
        .none, _ => return error.TestUnexpectedResult,
    };
}

test Door {
    // Tube 2's doors: its lower door part 2, its upper part 8.
    try std.testing.expectEqual(2, Door.lower.part(2));
    try std.testing.expectEqual(2 + door_step, Door.upper.part(2));
}

test tubeMiddle {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var reliant_model: testing.Reliant = undefined;
    try reliant_model.init(gpa);
    defer reliant_model.deinit(gpa);
    const slot = mission.slot(try mission.add(.reliant, .{ 0, 0, 10000 }));
    try reliant_model.fit(gpa, slot);
    // Halfway between gate 2's lower door, 2000 along X, and its upper door 500 above it, as the
    // Reliant stands, nothing across.
    try std.testing.expectEqual(math.Vector{ 2000, -250, 10000 }, tubeMiddle(slot, 2, 0).?);
    // The first tube, the one the landing goes down.
    try std.testing.expectEqual(math.Vector{ 0, -250, 10000 }, tubeMiddle(slot, 0, 0).?);
    // A tube whose upper door the model lacks has none.
    try std.testing.expectEqual(null, tubeMiddle(slot, door_step, 0));
}

test "the player's launch shows the hangar and the cutaways, and ends in view 0" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var reliant_model: testing.Reliant = undefined;
    try reliant_model.init(gpa);
    defer reliant_model.deinit(gpa);
    const player = try mission.add(.predator, @splat(0));
    const reliant = try mission.add(.reliant, .{ 0, 0, 10000 });
    try reliant_model.fit(gpa, mission.slot(reliant));
    var view: camera.Camera = .{ .setting = .chase };
    var display: @import("../hud.zig").State = .{};
    var ctx = mission.orders();
    ctx.world.camera = &view;
    ctx.world.display = &display;
    ctx.world.spawn = mission.spawn(create.testing.no_models);

    // The hangar stands in the cutaway slot, the Reliant is the ship the player launched from and
    // the cutaway leaves it out, and the camera is held in the cockpit.
    _ = try aigeneric.pushShip(ctx, player, .launch, reliant, 0);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(.reliant_hangar, mission.objects.slots[create.cutaway_slot].object.type);
    try std.testing.expect(mission.objects.slots[create.cutaway_slot].object.flags.no_collisions);
    try std.testing.expectEqual(reliant, mission.player.carrier.?);
    try std.testing.expectEqual(.launch, mission.player.showing);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expectEqual(.cockpit, view.cockpit_mode);
    try std.testing.expect(view.locked);
    // The gate stays the order's own once the hangar is laid over the tube.
    try std.testing.expectEqual(0, mission.slot(player).orders[0].target.component);

    launch.start(mission.objects, player);
    aigeneric.objectOrders(ctx, player);
    _ = runTo(&mission, ctx, player, .lower);
    // The engine starts with a shake, and a cutaway is picked: the bay's takes the camera at once.
    try std.testing.expectEqual(start_shake, mission.shake);
    try std.testing.expect(mission.player.cutaway != .none);
    if (mission.player.cutaway == .bay) try std.testing.expectEqual(camera.View.launch_bay, view.view);
    _ = runTo(&mission, ctx, player, .clear);
    // As the ship drops, the date is typed out.
    try std.testing.expect(display.caption.on);
    runOut(&mission, ctx, player);
    // At the end the date goes, the hangar goes, everything shows, and the camera is free in view 0
    // in the mode the setting picks.
    try std.testing.expect(!display.caption.on);
    try std.testing.expectEqual(.stand_in, mission.objects.slots[create.cutaway_slot].object.type);
    try std.testing.expectEqual(.everything, mission.player.showing);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expectEqual(.chase, view.cockpit_mode);
    try std.testing.expect(!view.locked);
}
