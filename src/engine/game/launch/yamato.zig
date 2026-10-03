//! The Yamato's launch (`launch_yamato_init`, `0x004192C0`, and `launch_yamato_run`,
//! `0x00419840`): a fighter waits in a side bay, then flies out through its doors. The player's
//! launch shows a separate hangar, six steam emitters and three exterior camera views.

const std = @import("std");
const libcmt = @import("../../libcmt.zig");
const math = @import("../../surrender/math.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srmesh = @import("../../surrender/surrenderlib/srmesh.zig");
const shp = @import("../../../formats/shp.zig");
const aigeneric = @import("../aigeneric.zig");
const camera = @import("../camera.zig");
const create = @import("../create.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const particles = @import("../particles.zig");
const sound3d = @import("../sound3d.zig");
const launch = @import("../launch.zig");
const bay_style = @import("bay.zig");

/// The Yamato's steps after the common launch wait and delay.
pub const Step = enum(i32) {
    release = 2,
    open = 3,
    accelerate = 4,
    clear = 5,
    fly = 6,
    end = 7,
    _,

    /// Delay before the next step (`launch_yamato_run`, `0x00419840`).
    fn wait(step: Step) i32 {
        return switch (step) {
            .release => 100,
            .open => 300,
            .accelerate => 50,
            .clear => 150,
            .fly => 300,
            .end, _ => unreachable,
        };
    }

    /// Engine shake for the player's release, door opening and acceleration (`0x00419840`).
    fn shake(step: Step) f32 {
        return switch (step) {
            .release => 0.1,
            .open => 0.2,
            .accelerate => 0.3,
            .clear, .fly, .end, _ => unreachable,
        };
    }
};

/// The bay is child gate + 3; its doors are children gate * 2 + 31 and + 32
/// (`0x00419339`, `0x0041935F`). Gates below 8 face the opposite side (`0x004193A6`).
const first_bay = 3;
const first_door = 31;
const side_split = 8;
/// **Improvement:** an exact quarter turn replaces the original's rounded angle (`0x004193AF`).
const quarter_turn: f32 = std.math.pi / 2.0;
/// Each bay has two doors (`0x0041935F`, `0x0041937D`), and the cutaway uses parts 0 and 1
/// (`0x004198FD`). Its sound plays at the second door (`0x00419954`).
const door_count = 2;
const hangar_first_door = 0;
const hangar_sound_door = 1;
/// The hangar's first three parts exclude every backdrop light but the first ambient
/// (`0x00419670`).
const hangar_light_mask: u32 = 0x3B;
const lit_parts = 3;
/// The throttle at step 4 (`launch_yamato_run`, `0x00419840`).
const out_throttle: f32 = 2;
/// View 15 starts in the last 50 ticks of step 6 (`0x00419884`).
const camera_lead = 50;
/// The unused camera marker stands 1000 outside and above the bay; the software renderer
/// puts it 2000 past the bay's front (`0x004DC44C`, `0x004DC438`).
const marker_margin: f32 = 1000;

/// The steam template made by `launches_init` (`0x00418A70`, `0x0051D108`).
const steam: particles.Template = .{
    .life = 50,
    .life_spread = 10,
    .rate = .through(50, 50, 50),
    .size = .through(20, 70, 100),
    .colour = @splat(.through(1, 0.75, 0)),
};

/// **Improvement:** dimmer additive steam avoids saturated white blobs with bloom. The
/// original uses full white; the softer version preserves size, timing and motion.
pub const Steam = enum { original, soft };
const steam_brightness: f32 = 0.35;
const soft_steam: particles.Template = blk: {
    var template = steam;
    for (&template.colour) |*curve| {
        curve.a *= steam_brightness;
        curve.b *= steam_brightness;
        curve.c *= steam_brightness;
    }
    break :blk template;
};
/// Emitter frames, directions and spread from `launches_init` (`0x00418B61` onward).
const vents = [_]struct { part: usize, position: math.Vector, direction: math.Vector, spread: math.Vector }{
    .{ .part = 2, .position = .{ -779, -600, 40 }, .direction = .{ 1, 0, 0 }, .spread = .{ 0, 0.1, 0.1 } },
    .{ .part = 1, .position = .{ -370, -610, -25 }, .direction = .{ 0.5, 0.5, -1 }, .spread = @splat(0.1) },
    .{ .part = 1, .position = .{ -370, 450, -25 }, .direction = .{ 0.5, -0.5, -1 }, .spread = @splat(0.1) },
    .{ .part = 0, .position = .{ 370, -610, -25 }, .direction = .{ -0.5, 0.5, -1 }, .spread = @splat(0.1) },
    .{ .part = 0, .position = .{ 370, 450, -25 }, .direction = .{ -0.5, -0.5, -1 }, .spread = @splat(0.1) },
    .{ .part = 2, .position = .{ 935, -600, 40 }, .direction = .{ -1, 0, 0 }, .spread = .{ 0, 0.1, 0.1 } },
};
/// Four door vents start together at step 2, between the two independently pulsing hull vents
/// (`launch_yamato_run`, `0x00419840`).
const first_door_vent = 1;
const door_vent_count = 4;
/// Emitter speed and spread (`0x00418B30`, `0x00418B3D`), central burst duration, and the
/// outer vents' duration and pause ranges (`0x00419840`, `0x00419AC9`, `0x00419AE0`).
const steam_speed: f32 = 10;
const steam_speed_range: f32 = 3;
const central_ticks = 200;
const vent_min = 20;
const vent_spread = 80;
const vent_pause = 100;

/// Mission-local replacements for the six emitter pointers at `0x0051D0F0`, their two next
/// burst ticks (`0x0051D0B8`, `0x0051D0BC`), and the Yamato's use of `launch_cutaway`.
pub const Effects = struct {
    emitters: [vents.len]particles.Emitter = makeEmitters(),
    due: [2]i32 = @splat(0),
    cutaway: Cutaway = .none,
};

/// The Yamato's values of `launch_cutaway` (`0x0051D0EC`).
pub const Cutaway = enum(i32) {
    none = -1,
    beside = 0,
    ahead = 1,
    aside = 2,

    /// Selects one of three cutaways using the original's random call (`launch_yamato_run`).
    fn pick(random: *libcmt.Rand) Cutaway {
        const choices = [_]Cutaway{ .beside, .ahead, .aside };
        return choices[random.rand() % choices.len];
    }
};

fn makeEmitters() [vents.len]particles.Emitter {
    var result: [vents.len]particles.Emitter = undefined;
    for (&result, vents) |*emitter, vent| emitter.* = .{
        .born = 0,
        .template = &steam,
        .place = .{ .position = vent.position },
        .direction = vent.direction,
        .spread = vent.spread,
        .speed = steam_speed,
        .speed_range = steam_speed_range,
    };
    return result;
}

/// `launch_yamato_init` (`0x004192C0`): the ship rides the carrier's root, with throttle and
/// steering cleared. It stands at the bay's minimum X for gates below 8, maximum X otherwise,
/// centred on Y and Z, turned a quarter turn about Y before the bay's world orientation.
/// **Fix:** missing bay or door parts are skipped instead of reading past the model's child list.
pub fn init(ctx: aigeneric.Context, index: u16, carrier: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const holder = &all.slots[carrier];
    slot.riding = .{ .object = carrier };
    slot.object.letGo();
    const gate = std.math.cast(usize, slot.orders[0].target.component) orelse return;
    const model = if (holder.model) |*held| held else return;
    const bay = gate + first_bay;
    const bounds = model.levelBounds(bay) orelse return;
    setBay(model, gate, true);
    const frame = model.frameAt(bay, holder.drawn);
    var at = (bounds[0] + bounds[1]) * @as(math.Vector, @splat(0.5));
    at[0] = bounds[@intFromBool(gate >= side_split)][0];
    const turn = math.product(math.rotation(.y, if (gate < side_split) quarter_turn else -quarter_turn), frame.orientation);
    objects.setPlace(&slot.object, &slot.drawn, .{ .position = frame.point(at), .orientation = turn });
    if (index != all.player) return;
    world.player.carrier = carrier;
    showHangar(ctx, frame, bounds);
    if (world.camera) |view| {
        view.cockpit_mode = .cockpit;
        _ = view.setView(.cockpit, index, true, true, world.clock.viewTime());
    }
    world.player.showing = .launch;
}

/// Shows the player's hangar (type `0xD4`) with its front edge aligned to the bay's maximum X
/// and its middle on Y and Z (`0x00419524` to `0x0041982E`). The player still rides the carrier.
fn showHangar(ctx: aigeneric.Context, frame: math.Place, bounds: [2]math.Vector) void {
    const world = ctx.world;
    const all = world.objects;
    const effects = &world.player.yamato_launch;
    effects.* = .{};
    for (&effects.emitters) |*emitter| emitter.template = switch (world.launch_steam) {
        .original => &steam,
        .soft => &soft_steam,
    };
    const hangar = create.make(world, create.cutaway_slot, .yamato_hangar) catch |err| {
        std.log.scoped(.launch).warn("the Yamato's hangar is left out: {s}", .{@errorName(err)});
        return;
    } orelse return;
    const shown = &all.slots[hangar];
    shown.object.flags.no_collisions = true;
    for (&effects.due) |*due| due.* = world.clock.frame_start + @as(i32, world.random.rand() % vent_pause);
    if (shown.model) |*model| for (model.parts[0..@min(lit_parts, model.parts.len)]) |*part| {
        part.object.light_mask = hangar_light_mask;
    };
    var at = (bounds[0] + bounds[1]) * @as(math.Vector, @splat(0.5));
    at[0] = bounds[1][0];
    var front = (gameobj.vector(shown.object.bounds_min) + gameobj.vector(shown.object.bounds_max)) * @as(math.Vector, @splat(0.5));
    front[2] = shown.object.bounds_max.z;
    const turn = all.slots[all.player].object.root.next_orientation;
    objects.setPlace(&shown.object, &shown.drawn, .{ .position = frame.point(at) - math.transform(turn, front), .orientation = turn });
}

/// Shows or hides the bay mesh, and enables or disables portal clipping on its two door meshes
/// (`0x00419345`, `0x00419366`, and step 7 of `launch_yamato_run`).
fn setBay(model: *objects.Model, gate: usize, shown: bool) void {
    const bay = gate + first_bay;
    if (model.rootChild(bay) != null) model.parts[bay].hidden = !shown;
    for (0..door_count) |door| {
        const part = gate * door_count + first_door + door;
        if (model.rootChild(part) != null) model.parts[part].object.flags.portal_clipped = shown;
    }
}

/// Starts both door tracks from time zero, preserving each track's animation mode. The
/// sound's part is explicit because the hangar uses its second door and the carrier its first.
fn playDoors(world: gameobj.World, slot: *create.Slot, first: usize, sound: ?struct { part: usize, kind: sound3d.sounds.Sound }) void {
    const model = if (slot.model) |*held| held else return;
    for (0..door_count) |door| if (model.rootChild(first + door) != null)
        model.playNamed(first + door, bay_style.door_track, 0, null, bay_style.door_speed);
    if (sound) |heard| if (model.rootChild(heard.part)) |part|
        sound3d.playFrom(world, part.drawn(), heard.kind, .not_reserved);
}

/// `launch_yamato_run` (`0x00419840`): releases the ship, opens the cutaway's doors, accelerates
/// through the carrier's doors, removes the cutaway, then restores normal flight. Every step
/// waits strictly past its due tick. The outer steam vents also run while the launch waits.
pub fn run(ctx: aigeneric.Context, index: u16) void {
    const world = ctx.world;
    const all = world.objects;
    const slot = &all.slots[index];
    const state = &slot.state.launch;
    const now = world.clock.frame_start;
    const player = index == all.player;
    const effects = &world.player.yamato_launch;
    if (player and state.step.as(Step) == .fly and effects.cutaway == .beside and state.due - now < camera_lead) {
        if (world.camera) |view| if (view.view != .yamato_beside) switchView(world, .yamato_beside);
    }
    if (state.due < now) switch (state.step.as(Step)) {
        .release => {
            slot.motion = .plain;
            state.attached = false;
            if (player) {
                for (effects.emitters[first_door_vent..][0..door_vent_count]) |*emitter| {
                    emitter.born = now;
                    emitter.life = central_ticks;
                }
                world.shake.* = Step.release.shake();
            }
            advance(state, .release, now);
        },
        .open => {
            if (player) {
                world.player.showing = .launch;
                const hangar = &all.slots[create.cutaway_slot];
                playDoors(world, hangar, hangar_first_door, .{ .part = hangar_sound_door, .kind = .dooropen });
                world.shake.* = Step.open.shake();
                sound3d.playIn(world, null, null, index, sound3d.engineSound(slot.object.type), 0, .player_engines);
            }
            advance(state, .open, now);
        },
        .accelerate => {
            slot.object.throttle = out_throttle;
            if (player) world.shake.* = Step.accelerate.shake();
            if (slot.orders[0].target.slotIn(all)) |carrier| {
                if (std.math.cast(usize, slot.orders[0].target.component)) |gate| {
                    const first = gate * door_count + first_door;
                    playDoors(world, &all.slots[carrier], first, if (player) .{ .part = first, .kind = .doorclos } else null);
                }
            }
            advance(state, .accelerate, now);
        },
        .clear => {
            if (player) {
                if (world.display) |display| display.caption.start(world.clock.game_ticks);
                all.resetSlot(create.cutaway_slot, world.random);
                world.player.showing = .everything;
                setMarker(world, slot);
                effects.cutaway = .pick(world.random);
                switch (effects.cutaway) {
                    .ahead => switchView(world, .yamato_ahead),
                    .aside => switchView(world, .yamato_aside),
                    .beside, .none => {},
                }
            }
            advance(state, .clear, now);
        },
        .fly => advance(state, .fly, now),
        .end => {
            if (slot.orders[0].target.slotIn(all)) |carrier| if (all.slots[carrier].model) |*model| {
                if (std.math.cast(usize, slot.orders[0].target.component)) |gate| setBay(model, gate, false);
            };
            slot.object.letGo();
            if (player) {
                if (world.display) |display| display.caption.stop();
                if (world.camera) |view| {
                    view.cockpit_mode = view.setting.mode();
                    switch (view.view) {
                        .yamato_beside, .yamato_ahead, .yamato_aside => _ = view.setView(.cockpit, index, false, true, world.clock.viewTime()),
                        else => {},
                    }
                }
                world.player.showing = .everything;
            }
            slot.motion = .forward;
            launch.letGo(ctx, index);
            return;
        },
        _ => {},
    };
    if (player and @intFromEnum(state.step) < @intFromEnum(Step.fly)) stream(world);
}

fn advance(state: *launch.State, step: Step, now: i32) void {
    state.advance(@enumFromInt(@intFromEnum(step) + 1), now, step.wait());
}

fn switchView(world: gameobj.World, view: camera.View) void {
    const watching = world.camera orelse return;
    const player = world.objects.player;
    _ = watching.setYamato(view, player, world.clock.viewTime(), .of(&world.objects.slots[player]));
}

/// Places the original's camera marker at the hardware renderer's position. None of the three
/// launch views reads it (`launch_yamato_run`, step 5).
fn setMarker(world: gameobj.World, slot: *create.Slot) void {
    const carrier = slot.orders[0].target.slotIn(world.objects) orelse return;
    const holder = &world.objects.slots[carrier];
    const model = if (holder.model) |*held| held else return;
    const gate = std.math.cast(usize, slot.orders[0].target.component) orelse return;
    const bounds = model.levelBounds(gate + first_bay) orelse return;
    const local: math.Vector = .{
        if (gate < side_split) bounds[1][0] + marker_margin else bounds[0][0] - marker_margin,
        bounds[0][1] - marker_margin,
        bounds[0][2],
    };
    for (&world.objects.slots) |*marker| if (marker.object.type == .marker) {
        objects.setPosition(&marker.object, &marker.drawn, model.frameAt(gate + first_bay, holder.drawn).point(local));
        break;
    };
}

/// A Yamato model with bounds on every part and tracks on both tested bays' doors.
/// Initialize it in place because its levels and tracks point into the fixture.
const TestCarrier = struct {
    mesh: srapiext.Mesh,
    levels: [1]srapiext.Level,
    tracks: [1]shp.Track,
    parts: objects.testing.Parts(49),

    fn init(carrier: *TestCarrier, gpa: std.mem.Allocator) !void {
        carrier.mesh = try srmesh.testing.square(gpa);
        carrier.mesh.bounds = .{ .{ -100, -200, -300 }, .{ 400, 600, 700 } };
        carrier.levels = .{.{ .mesh = &carrier.mesh, .until = std.math.inf(f32) }};
        carrier.tracks = .{.{ .clip = objects.testing.clip(100, .once, bay_style.door_track), .keyframes = &.{}, .events = &.{} }};
        carrier.parts.init();
        for (&carrier.parts.loaded_parts, &carrier.parts.data) |*part, *data| {
            part.levels = &carrier.levels;
            data.tracks = &carrier.tracks;
        }
    }

    fn deinit(carrier: *TestCarrier, gpa: std.mem.Allocator) void {
        carrier.mesh.deinit(gpa);
    }
};

test "the Yamato's bays place fighters on both sides and release them on schedule" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: TestCarrier = undefined;
    try carrier_model.init(gpa);
    defer carrier_model.deinit(gpa);
    _ = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.yamato, .{ 1000, 0, 10000 });
    try carrier_model.parts.fit(gpa, mission.slot(carrier));
    const model = &mission.slot(carrier).model.?;
    const ctx = mission.orders();
    for ([_]u16{ 0, 8 }) |gate| {
        const ship = try mission.add(.sabre, @splat(0));
        const slot = mission.slot(ship);
        slot.object.throttle = 1;
        slot.object.pitch_input = 1;
        _ = try aigeneric.pushShip(ctx, ship, .launch, carrier, gate);
        aigeneric.objectOrders(ctx, ship);
        try std.testing.expectEqual(math.Vector{ if (gate == 0) 900 else 1400, 200, 10200 }, slot.drawn.position);
        try std.testing.expectApproxEqAbs(@as(f32, if (gate == 0) 1 else -1), math.forward(slot.drawn.orientation)[0], 1e-6);
        try std.testing.expectEqual(objects.NodeOf{ .object = carrier }, slot.riding.?);
        try std.testing.expectEqual(0, slot.object.throttle);
        try std.testing.expectEqual(0, slot.object.pitch_input);
        try std.testing.expect(!model.parts[gate + first_bay].hidden);
        try std.testing.expect(model.parts[gate * 2 + first_door].object.flags.portal_clipped);
        launch.start(mission.objects, ship);
        aigeneric.objectOrders(ctx, ship);
        launch.testing.pastDue(&mission, ctx, ship);
        const state = &slot.state.launch;
        try std.testing.expectEqual(Step.open, state.step.as(Step));
        try std.testing.expect(!state.attached);
        try std.testing.expectEqual(.plain, slot.motion.?);
        // Equality does not advance a step.
        mission.clock.frame_start = state.due;
        aigeneric.objectOrders(ctx, ship);
        try std.testing.expectEqual(Step.open, state.step.as(Step));
        launch.testing.pastDue(&mission, ctx, ship);
        launch.testing.pastDue(&mission, ctx, ship);
        try std.testing.expectEqual(out_throttle, slot.object.throttle);
        for (0..door_count) |door| {
            const animation = model.parts[gate * door_count + first_door + door].animation;
            try std.testing.expectEqual(bay_style.door_speed, animation.speed);
            try std.testing.expectEqual(0, animation.time);
            try std.testing.expectEqual(.once, animation.mode);
        }
        while (slot.object.order_count != 0) launch.testing.pastDue(&mission, ctx, ship);
        try std.testing.expect(model.parts[gate + first_bay].hidden);
        try std.testing.expect(!model.parts[gate * 2 + first_door].object.flags.portal_clipped);
        try std.testing.expectEqual(.forward, slot.motion.?);
        try std.testing.expectEqual(0, slot.object.throttle);
        try std.testing.expectEqual(null, slot.object.passes_through[0].index());
        try std.testing.expect(slot.object.flags.targetable);
    }
}

test "the player's Yamato launch opens the hangar, starts steam and restores the cockpit" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var carrier_model: TestCarrier = undefined;
    try carrier_model.init(gpa);
    defer carrier_model.deinit(gpa);
    const player = try mission.add(.predator, @splat(0));
    const carrier = try mission.add(.yamato, .{ 1000, 0, 10000 });
    try carrier_model.parts.fit(gpa, mission.slot(carrier));
    var view: camera.Camera = .{ .setting = .chase };
    var display: @import("../hud.zig").State = .{};
    var ctx = mission.orders();
    ctx.world.camera = &view;
    ctx.world.display = &display;
    ctx.world.spawn = mission.spawn(create.testing.no_models);
    _ = try aigeneric.pushShip(ctx, player, .launch, carrier, 0);
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(carrier, mission.player.carrier.?);
    try std.testing.expectEqual(.yamato_hangar, mission.slot(create.cutaway_slot).object.type);
    try std.testing.expectEqual(.launch, mission.player.showing);
    try std.testing.expect(view.locked);
    launch.start(mission.objects, player);
    aigeneric.objectOrders(ctx, player);
    launch.testing.pastDue(&mission, ctx, player);
    for (mission.player.yamato_launch.emitters[1..5]) |emitter| {
        try std.testing.expectEqual(central_ticks, emitter.life);
        try std.testing.expectEqual(mission.clock.frame_start, emitter.born);
    }
    try std.testing.expectEqual(Step.release.shake(), mission.shake);
    launch.testing.pastDue(&mission, ctx, player);
    try std.testing.expectEqual(Step.open.shake(), mission.shake);
    launch.testing.pastDue(&mission, ctx, player);
    try std.testing.expectEqual(Step.accelerate.shake(), mission.shake);
    launch.testing.pastDue(&mission, ctx, player);
    try std.testing.expect(display.caption.on);
    try std.testing.expectEqual(.everything, mission.player.showing);
    try std.testing.expectEqual(.stand_in, mission.slot(create.cutaway_slot).object.type);
    // Force the delayed beside cutaway, which starts only in step 6's last 50 ticks.
    mission.player.yamato_launch.cutaway = .beside;
    _ = view.setView(.cockpit, player, true, true, 0);
    const state = &mission.slot(player).state.launch;
    mission.clock.frame_start = state.due - camera_lead;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    mission.clock.frame_start += 1;
    aigeneric.objectOrders(ctx, player);
    try std.testing.expectEqual(camera.View.yamato_beside, view.view);
    while (mission.slot(player).object.order_count != 0) launch.testing.pastDue(&mission, ctx, player);
    try std.testing.expect(!display.caption.on);
    try std.testing.expectEqual(camera.View.cockpit, view.view);
    try std.testing.expectEqual(.chase, view.cockpit_mode);
    try std.testing.expect(!view.locked);
}

/// Streams all six vents in array order. Outer bursts last 20 to 99 ticks, with 20 to 119 ticks
/// between bursts, using the same C runtime random calls as the original (`0x00419A98`).
fn stream(world: gameobj.World) void {
    const effects = &world.player.yamato_launch;
    const now = world.clock.frame_start;
    const hangar = &world.objects.slots[create.cutaway_slot];
    const model = if (hangar.model) |*held| held else return;
    for (&effects.emitters, vents, 0..) |*emitter, vent, n| {
        if (n == 0 or n == vents.len - 1) {
            const side: usize = @intFromBool(n != 0);
            if (effects.due[side] < now) {
                emitter.born = now;
                emitter.life = @as(i32, world.random.rand() % vent_spread) + vent_min;
                effects.due[side] = now + emitter.life + vent_min + @as(i32, world.random.rand() % vent_pause);
            }
        }
        if (model.rootChild(vent.part) != null) _ = explode.streamWithin(world, emitter, model.frameAt(vent.part, hangar.drawn));
    }
}
