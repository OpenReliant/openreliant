//! The Ulysses' end, in `C:\lancer\game\explode.cpp`. Its components run `componentLost`
//! (`explode_ulysses_component`, `0x0046EA50`) as they are destroyed: the fin is thrown off, and
//! as the top goes the ship's back is thrown off too and the top is cut away over 900 ticks by a
//! split of its own (`Top`), which takes a slot among the capital ships' splits (`split.Splits`).

const std = @import("std");

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const explode = @import("../explode.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const sound3d = @import("../sound3d.zig");
const xtrabits = @import("../xtrabits.zig");
const events = @import("../mission/events.zig");
const split = @import("split.zig");

/// The parts of the Ulysses' model that its end goes by (`0x004F7480`, and `0x00500418` to
/// `0x00500488`).
const top = "Ulysses Top";
const fin = "Ulysses Fin";
const front_wreck = "Uly frnt dest";
const back_wreck = "Uly back dest";
const fin_wreck = "Uly bfin dest";
const middle = "Uly mid sec";
const middle_wreck = "Uly mid sec dest";
const middle_damaged = "Uly mid dest";
const low_generator = "Ulysses Low gen";

/// `explode_ulysses_component` (`0x0046EA50`): the Ulysses in slot `index` has lost `part`, one of
/// its components. The ship is unpowered from then on.
///
/// Where the part is its top, the front's wreck shows, the top starts coming away (`Top.start`),
/// component 0 has its Destroyed, and the ship is lost (`ai.hullLost`). Then, where the part
/// is its top or its fin and the fin is still on, the fin is thrown off (`throwFin`).
pub fn componentLost(ctx: aigeneric.Context, index: u16, part: objects.PartRef) void {
    const world = ctx.world;
    const object = &world.objects.slots[index].object;
    const name = if (part.data()) |data| data.part.name() else "";
    object.flags.unpowered = true;
    const top_lost = std.mem.eql(u8, name, top);
    if (top_lost) {
        if (world.objects.slots[index].model) |*model| model.showNamed(front_wreck);
        Top.start(world, index);
        destroyed(world, index, 0);
        ai.hullLost(ctx, index);
    }
    if (object.ends.fin_lost) return;
    if (!top_lost and !std.mem.eql(u8, name, fin)) return;
    object.ends.fin_lost = true;
    throwFin(world, index, top_lost);
}

/// The fin thrown off: a piece of it (`ulysses_fin`) made where the ship stands, unpowered and
/// exploding, spinning and drifting away; two fireballs at each of the fin's `fireballs` points,
/// the second of them late; the middle's wreck shown where the middle, the low generator and the
/// fin were; the view flashing where the camera is near, and the ship's explosion heard, unless
/// the top went with it; the piece's wreck burning; and component 1's Destroyed.
fn throwFin(world: gameobj.World, index: u16, with_top: bool) void {
    const all = world.objects;
    const slot = &all.slots[index];
    const thrown = split.makePiece(world, index, .of(.ulysses_fin));
    if (thrown) |made| {
        const piece = &all.slots[made].object;
        piece.flags.unpowered = true;
        piece.flags.exploding = true;
        piece.rotation = math.fromAngleVector(fin_tumble);
        piece.velocity = gameobj.vec3(fin_drift);
    }
    if (slot.model) |*model| {
        if (model.partNamed(fin)) |ref| finFireballs(world, ref, slot.object.radius * fin_fireball_share);
        model.showNamed(middle_wreck);
        for ([_][]const u8{ low_generator, fin, middle, middle_damaged }) |name| model.hideNamed(name);
    }
    if (!with_top) {
        split.flashNear(world, index);
        sound3d.playIn(world, null, null, index, .capexp, 1, .player_fx);
    }
    if (thrown) |made| explode.burnPart(world, made, fin_wreck, wreck_burn);
    destroyed(world, index, 1);
}

/// How the thrown fin turns, a step, and drifts, a step, in the world's axes.
const fin_tumble: Vector = .{ 0.002, -0.0002, -0.0001 };
const fin_drift: Vector = .{ 5, 15, -1 };

/// The fin's fireballs are this share of the ship's radius across (`0x004DC4C0`), and the second
/// at each of its points goes off this many ticks late.
const fin_fireball_share: f32 = 0.3;
const fin_fireballs_late = [_]i32{ 60, 90, 120 };

/// How the wrecks of the Ulysses' pieces burn: for 5000 ticks, their rays flickering, with their
/// burn lights and smoke.
const wreck_burn: explode.Burn = .{ .forever = false, .flickers = true, .lights = true };

/// Two lit fireballs `size` across at each of the first of `ref`'s `fireballs` points, the second
/// late by `fin_fireballs_late`.
///
/// **Fix:** the game reads three points whatever the list holds.
fn finFireballs(world: gameobj.World, ref: objects.PartRef, size: f32) void {
    const data = ref.data() orelse return;
    const list = data.pointList(.fireballs) orelse return;
    const place = ref.part().drawn();
    const count = @min(list.points.len, fin_fireballs_late.len);
    for (list.points[0..count], fin_fireballs_late[0..count]) |point, late| {
        const at = place.point(gameobj.vector(point.position));
        explode.fireballAt(world, at, .{ .size = size, .light = true });
        explode.fireballAt(world, at, .{ .size = size, .light = true, .delay = late });
    }
}

/// The Ulysses' component `n` has its Destroyed, where the ship lists one there
/// (`object_component_index`).
fn destroyed(world: gameobj.World, index: u16, n: usize) void {
    const slot = &world.objects.slots[index];
    const part = slot.component(n) orelse return;
    if (slot.componentIndex(part)) |listed| events.destroyed(world, index, listed);
}

/// The Ulysses' top coming away (`ulysses_split_create`, `0x0046BC30`, 0x38 bytes), run once a
/// frame by `ulysses_split_update` (`0x0046EF00`). Two portals stand where the cut has reached
/// along the top's `cut` points: the first cuts the top, keeping what lies ahead of the cut, and
/// the second the front's wreck and the back's, keeping what lies behind it.
pub const Top = struct {
    /// The Ulysses (`+0x00`), and the tick its top began to come away (`+0x04`).
    object: u16,
    started: i32,
    /// Where the ship's root stood then (`+0x10`), which it is held at, shaking.
    at: Vector,
    /// The two portals (`+0x1C`, `+0x20`).
    portals: [2]srapiext.Portal,
    /// The back thrown off (`+0x28`), where it was made.
    other: ?u16 = null,
    /// How many steps the cut has taken along the top's points (`+0x30`).
    step: u16 = 0,
    /// Whether its portals are in the scene this frame.
    cutting: bool = false,

    /// How long it runs, in ticks; how many steps the cut takes a tick (`0x004DC830`); and how
    /// many steps it takes before its portals leave the scene.
    const duration = 900;
    const step_rate: f32 = 0.07444444;
    const cut_steps = 0x42;
    /// A step's fireball's size, its bits, one more on an odd step, how they are thrown, and how
    /// often its explosion is heard.
    const step_fireball: f32 = 3200;
    const step_bits = 5;
    const step_bit: explode.Bit.Throw = .{ .size = 1, .speed = 1, .bodies = 0.1 };
    const sound_every = 15;
    /// How far the ship shakes about where it stood, along each axis (`0x004DC7F0`).
    const shake: f32 = 25;

    /// How the ship turns, a step, and drifts, a step, in the world's axes, as its top comes away
    /// once its fin is gone too.
    const end_tumble: Vector = .{ 4e-05, 0.0013, -0.002 };
    const end_drift: Vector = .{ -2, 3, 20 };

    /// The top of the Ulysses in slot `index` starts coming away: a slot among the splits, its
    /// portals facing back and ahead along the ship as it stands; the back thrown off
    /// (`ulysses_back`) where the ship stands, unpowered and exploding; the top cut by the first
    /// portal, and the front's wreck and the back's by the second.
    fn start(world: gameobj.World, index: u16) void {
        const explosions = world.explosions orelse return;
        const all = world.objects;
        const slot = &all.slots[index];
        const cut = &explosions.splits.add(world, .{ .ulysses = .{
            .object = index,
            .started = world.clock.frame_start,
            .at = gameobj.vector(slot.object.root.position),
            .portals = .{ .{}, .{} },
        } }).ulysses;
        cut.other = split.makePiece(world, index, .of(.ulysses_back));
        if (cut.other) |other| {
            const back = &all.slots[other];
            back.object.flags.unpowered = true;
            back.object.flags.exploding = true;
        }
        if (slot.model) |*model| {
            xtrabits.clipNamed(model, top, &cut.portals[0]);
            xtrabits.clipNamed(model, front_wreck, &cut.portals[1]);
        }
        if (cut.other) |other| if (all.slots[other].model) |*model| xtrabits.clipNamed(model, back_wreck, &cut.portals[1]);
        const ahead = math.forward(slot.object.root.orientation);
        cut.portals[0].normal = -ahead;
        cut.portals[1].normal = ahead;
    }

    /// `ulysses_split_update`, once a frame: whether it is over. Until its time is up, the cut
    /// takes a step whenever the time says it is behind, at most one a frame (`stepOn`); the
    /// portals stand at whichever of the last two points it reached is nearer the stern, and are in
    /// the scene while it is still cutting; and the ship is held where it stood, shaking. Once its
    /// time is up, the halves part (`end`).
    ///
    /// **Fix:** the game reads the top's first list of points whatever it holds, which in the
    /// shipped model is its cut points; OpenReliant reads its cut points wherever they are listed.
    /// At the first step the game reads the point before the first, and at the last one past the
    /// last; OpenReliant reads the first and the last.
    pub fn update(cut: *Top, world: gameobj.World) bool {
        const slot = &world.objects.slots[cut.object];
        const elapsed = world.clock.frame_start - cut.started;
        cut.cutting = false;
        if (elapsed >= duration) {
            if (slot.object.ends.split_ended) return false;
            cut.end(world);
            return true;
        }
        const model = if (slot.model) |*live| live else return false;
        const ref = model.partNamed(top) orelse return false;
        const points = ((ref.data() orelse return false).pointList(.cut) orelse return false).points;
        if (points.len == 0) return false;
        const place = ref.part().drawn();
        if (@as(f32, @floatFromInt(cut.step)) < @as(f32, @floatFromInt(elapsed)) * step_rate) {
            cut.stepOn(world, place.point(gameobj.vector(points[@min(cut.step, points.len - 1)].position)));
        }
        const last = points.len - 1;
        const before = gameobj.vector(points[@min(cut.step -| 1, last)].position);
        const now = gameobj.vector(points[@min(cut.step, last)].position);
        const reached = place.point(if (before[2] <= now[2]) before else now);
        for (&cut.portals) |*portal| portal.position = reached;
        cut.cutting = cut.step < cut_steps;
        split.holdShaking(world, slot, cut.at, shake);
        return false;
    }

    /// A step of the cut, at `at`: a lit fireball; burning bits heading back along the ship; and
    /// on every 15th step an explosion's sound, `explosion01` or `explosion02` at random.
    fn stepOn(cut: *Top, world: gameobj.World, at: Vector) void {
        explode.fireballAt(world, at, .{ .size = step_fireball, .light = true });
        const back = -math.forward(world.objects.slots[cut.object].object.root.orientation);
        for (0..step_bits + cut.step % 2) |_| explode.throwBit(world, at, back, step_bit);
        cut.step += 1;
        if (cut.step % sound_every != 0) return;
        const which: sound3d.sounds.Sound = if (world.random.rand() % 2 == 0) .explosion02 else .explosion01;
        sound3d.playIn(world, at, null, null, which, 1, .explosions);
    }

    /// The halves parting, once (`GameObject.Ends.split_ended`): the portals go and nothing is
    /// cut; the back drifts off as a split's other half does, in the world's axes; the top and the
    /// middle's wreck go; the view flashes where the camera is near, the explosion is heard, and
    /// the ship is recentred on what is left of it; fireballs go off at the top's `fireballs`
    /// points (`split.endFireballs`); where the fin is gone too, the ship turns and drifts away
    /// and the back's wreck burns; and the front's wreck burns.
    ///
    /// The game has code here to throw off a fin that is still on, but its test can never pass,
    /// so the fin stays on.
    fn end(cut: *Top, world: gameobj.World) void {
        const all = world.objects;
        const slot = &all.slots[cut.object];
        const object = &slot.object;
        object.ends.split_ended = true;
        cut.release(world);
        if (cut.other) |other| {
            const back = &all.slots[other].object;
            back.rotation = math.fromAngleVector(split.Split.other_tumble);
            back.velocity = gameobj.vec3(split.Split.other_drift);
        }
        if (slot.model) |*model| {
            model.hideNamed(top);
            model.hideNamed(middle_wreck);
        }
        split.flashNear(world, cut.object);
        explode.sound(world, slot.drawn.position, .explosions);
        gameobj.recentreObject(slot);
        if (slot.model) |*model| if (model.partNamed(top)) |ref| split.endFireballs(world, object, ref);
        if (object.ends.fin_lost) {
            object.flags.unpowered = true;
            object.flags.exploding = true;
            object.rotation = math.fromAngleVector(end_tumble);
            object.velocity = gameobj.vec3(end_drift);
            if (cut.other) |other| explode.burnPart(world, other, back_wreck, wreck_burn);
        }
        explode.burnPart(world, cut.object, front_wreck, wreck_burn);
    }

    /// Lets the portals go, and with them what they cut on the ship and the back
    /// (`split.unclip`).
    pub fn release(cut: *Top, world: gameobj.World) void {
        cut.cutting = false;
        split.unclip(world, cut.object, cut.other);
    }
};

test "the Ulysses throws off its fin, then its top comes away" {
    const create = @import("../create.zig");
    const flash = @import("../main/flash.zig");
    var stage: explode.testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    // Its top, with three points for the cut, and its fin, with two where fireballs go off, beside
    // the wrecks and the middle. The pieces thrown off have the same model.
    var named: objects.testing.NamedParts(6) = undefined;
    named.init(
        .{ top, fin, front_wreck, back_wreck, middle, middle_wreck },
        .{ .cut, .fireballs, .cut, .cut, .cut, .cut },
        .{ &.{ .{ 0, 0, 100 }, .{ 0, 0, -100 }, .{ 0, 0, 0 } }, &.{ .{ 0, 0, 10 }, .{ 0, 0, 20 } }, &.{}, &.{}, &.{}, &.{} },
    );
    const kind: create.Type = .{ .model = &named.parts.source, .loaded = &named.parts.loaded };
    const types = create.testing.oneType(&kind);
    const mission = &stage.mission;
    _ = try mission.add(.of(.kamov), @splat(0));
    const ship = try mission.addWith(types, .of(.ulysses), .{ 0, 0, 5000 });
    var world = stage.world();
    world.spawn = mission.spawn(types);
    var lit: flash.Flash = .{};
    var watching: @import("../camera.zig").Camera = .{};
    watching.place.position = .{ 0, 0, 5000 };
    world.flash = &lit;
    world.camera = &watching;
    const ctx: aigeneric.Context = .of(world);
    const slot = &mission.objects.slots[ship];
    const object = &slot.object;
    const model = &slot.model.?;
    // The model has no meshes to give it a size.
    object.radius = 1000;

    // A part that is neither its top nor its fin only leaves the ship unpowered.
    componentLost(ctx, ship, model.partNamed(middle).?);
    try std.testing.expect(object.flags.unpowered and !object.ends.fin_lost);

    // Its fin goes: a piece of it drifts away, two fireballs go off at each of its points, its
    // middle's wreck shows in place of the fin and the middle, and the view flashes.
    componentLost(ctx, ship, model.partNamed(fin).?);
    try std.testing.expect(object.ends.fin_lost);
    const thrown = &mission.objects.slots[mission.objects.count - 1].object;
    try std.testing.expectEqual(.ulysses_fin, thrown.type.base());
    try std.testing.expect(thrown.flags.unpowered and thrown.flags.exploding);
    try std.testing.expectEqual(gameobj.vec3(fin_drift), thrown.velocity);
    try std.testing.expect(model.partNamed(fin).?.part().hidden and model.partNamed(middle).?.part().hidden);
    try std.testing.expect(!model.partNamed(middle_wreck).?.part().hidden);
    var set_off: usize = 0;
    for (stage.explosions.fireballs) |fireball| set_off += @intFromBool(fireball != null);
    try std.testing.expectEqual(4, set_off);
    try std.testing.expectEqual(flash.flash_ticks, lit.left);

    // Its top goes: the ship is lost, its back is thrown off, and the top starts coming away, cut
    // by the first portal, the front's wreck and the back's by the second.
    componentLost(ctx, ship, model.partNamed(top).?);
    try std.testing.expect(object.flags.exploding and !model.partNamed(front_wreck).?.part().hidden);
    const splits = &stage.explosions.splits;
    try std.testing.expect(splits.splitting(ship));
    const cut = &splits.slots[0].?.ulysses;
    const back = &mission.objects.slots[cut.other.?];
    try std.testing.expectEqual(.ulysses_back, back.object.type.base());
    try std.testing.expect(model.partNamed(top).?.part().object.portal == &cut.portals[0]);
    try std.testing.expect(model.partNamed(front_wreck).?.part().object.portal == &cut.portals[1]);
    try std.testing.expect(back.model.?.partNamed(back_wreck).?.part().object.portal == &cut.portals[1]);
    try std.testing.expect(model.partNamed(fin).?.part().object.portal == null);

    // At first the portals stand at the first point and cut, and the ship shakes where it stood.
    const place = model.partNamed(top).?.part().drawn();
    try std.testing.expect(!cut.update(world));
    try std.testing.expect(cut.cutting);
    try std.testing.expectEqual(place.point(.{ 0, 0, 100 }), cut.portals[0].position);
    try std.testing.expectEqual(@as(Vector, @splat(Top.shake)), @abs(gameobj.vector(object.root.position) - cut.at));
    // A hundred ticks on, the cut takes a step, and the portals stand at the nearer to the stern
    // of the first two points.
    mission.clock.frame_start += 100;
    try std.testing.expect(!cut.update(world));
    try std.testing.expectEqual(1, cut.step);
    try std.testing.expectEqual(place.point(.{ 0, 0, -100 }), cut.portals[1].position);

    // Once its time is up the halves part: nothing is cut, the top goes, the back drifts off, and
    // with its fin gone the ship drifts away too.
    mission.clock.frame_start += Top.duration;
    splits.frame(world);
    try std.testing.expectEqual(null, splits.slots[0]);
    try std.testing.expect(object.ends.split_ended);
    try std.testing.expect(model.partNamed(top).?.part().hidden and model.partNamed(top).?.part().object.portal == null);
    try std.testing.expectEqual(gameobj.vec3(split.Split.other_drift), back.object.velocity);
    try std.testing.expectEqual(gameobj.vec3(Top.end_drift), object.velocity);
}
