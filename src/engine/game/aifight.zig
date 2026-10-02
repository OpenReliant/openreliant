//! `C:\lancer\game\aifight.cpp`: the Fight order, which runs one combat maneuver after another
//! against its target, aiming and firing as it goes. [`aidefend.zig`](aidefend.zig) runs the
//! maneuvers.
//!
//! **Unverified:** that the Fight order's routines outside this file's known code are the file's:
//! `fight_fire` (`0x004096B0`) to `fight_choose_maneuver` (`0x0040A3A0`), which lie between
//! `aidock.cpp`'s known code and this file's, and `order_fight` (`0x0040A5E0`), which lies just
//! after it.

const std = @import("std");
const assert = std.debug.assert;

const Vec3 = @import("../../formats/shp.zig").Vec3;
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aidefend = @import("aidefend.zig");
const Mirror = aidefend.Mirror;
const maneuvers = aidefend.maneuvers;
const Maneuver = maneuvers.Maneuver;
const Bearing = maneuvers.Bearing;
const aigeneric = @import("aigeneric.zig");
const cloak = @import("cloak.zig");
const Order = @import("ai/orders.zig").Order;
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const guns = @import("guns.zig");
const missiles = @import("missiles.zig");
const pilots = @import("pilots.zig");
const xtrabits = @import("xtrabits.zig");

/// What the Fight order keeps in its `order_state` (`ai_local` in the developers' asserts).
pub const FightState = extern struct {
    /// Where it aims its guns, moved each update by `aim_velocity`.
    aim: Vec3,
    /// A quarter of the target's velocity when last aimed, per tick.
    aim_velocity: Vec3,
    /// The tick at which the maneuver ends and Fight chooses another.
    maneuver_end: i32,
    /// The tick at which it aims again.
    next_aim: i32,
    /// The tick from which its missile has locked on, which the missiles' code keeps.
    locked_at: i32,
    /// The tick from which `cloak` cloaks the ship.
    cloak_at: i32,
    /// The maneuver running.
    maneuver: Maneuver,
    /// Whether the aim leads the target, as `ai.leadAim` found it could.
    led: bool,
    /// The script line running (`AIFight_line`): `before_first` until the first starts.
    line: u8,
    /// Set while the line's instruction waits.
    waiting: bool,
    /// **Unknown.** In a multiplayer game, set once the choice of maneuver is sent.
    _unknown_2d: u8,
    /// Whether `Cloak` asked for the cloak.
    cloak: bool,
    /// Whether a missile is ready to fire.
    missile_ready: bool,
    /// Which inputs the maneuver mirrors this time.
    mirror: Mirror,
    _unknown_31: [3]u8,
    /// The tick at which the running instruction's time is up.
    timer: i32,
    _unknown_38: u32,
    /// Whether `SetAfterburner` lit the afterburner, which the maneuver keeps burning.
    afterburner: bool,
    _unknown_3d: [3]u8,
    /// The point the ship flies to.
    point: Vec3,
    /// Set once the point is nearly dead ahead: the ship then pitches at its full rate, weaving,
    /// until the point is some 45 degrees off its nose.
    weaving: bool,
    _unknown_4d: u8,
    /// The ship `RunToShip` flies to.
    ship: u16,
    _unknown_50: [0x40]u8,

    /// `line` before a maneuver's first line starts, which the first step onward wraps to 0.
    pub const before_first = 0xFF;

    comptime {
        assert(@offsetOf(FightState, "maneuver_end") == 0x18);
        assert(@offsetOf(FightState, "maneuver") == 0x28);
        assert(@offsetOf(FightState, "line") == 0x2B);
        assert(@offsetOf(FightState, "missile_ready") == 0x2F);
        assert(@offsetOf(FightState, "timer") == 0x34);
        assert(@offsetOf(FightState, "afterburner") == 0x3C);
        assert(@offsetOf(FightState, "point") == 0x40);
        assert(@offsetOf(FightState, "ship") == 0x4E);
        assert(@sizeOf(FightState) == 0x90);
    }
};

/// What the Fight order keeps in its entry's `data`: the maneuver to start next.
pub const FightData = extern struct {
    /// Its length in ticks, or -1 while it is still to be drawn from the maneuver's range.
    ticks: i16,
    /// The ship to run to, for `run_to_ship`.
    ship: u16,
    /// The maneuver's number (`next`), or `none` while none is chosen, as `fight_choose_maneuver`
    /// leaves it as it starts to choose.
    maneuver: u8,
    /// Set when a new maneuver has been chosen and has yet to start.
    fresh: bool,
    _unknown_06: [10]u8,

    /// `maneuver` while none is chosen.
    pub const none: u8 = 0xFF;

    /// The maneuver chosen to start next, where one is.
    pub fn next(data: FightData) ?Maneuver {
        return if (data.maneuver == none) null else @enumFromInt(data.maneuver);
    }

    /// Chooses `maneuver` to start next, by its number's low byte, which is all the game keeps.
    pub fn setNext(data: *FightData, maneuver: Maneuver) void {
        data.maneuver = @truncate(@intFromEnum(maneuver));
    }

    comptime {
        assert(@offsetOf(FightData, "ship") == 0x2);
        assert(@offsetOf(FightData, "maneuver") == 0x4);
        assert(@offsetOf(FightData, "fresh") == 0x5);
        assert(@sizeOf(FightData) == 16);
    }
};

test FightData {
    var data = std.mem.zeroes(FightData);
    data.maneuver = FightData.none;
    try std.testing.expectEqual(null, data.next());
    data.setNext(.run_to_ship);
    try std.testing.expectEqual(Maneuver.run_to_ship, data.next());
    try std.testing.expectEqual(9, data.maneuver);
}

/// A ship under the Fight order: what the order's routines and its maneuvers work on.
pub const Fighter = struct {
    ctx: aigeneric.Context,
    index: u16,
    slot: *create.Slot,
    state: *FightState,
    pilot: *const pilots.Pilot,
    /// Its order's target, and the target's slot: the game reads the index as a ship's, whatever
    /// its kind.
    against: ai.ValidTarget,

    /// The ship in slot `index` under the Fight order, against its order's target, which the update
    /// has found it can still aim at (`ai.targetOrPop`).
    pub fn of(ctx: aigeneric.Context, index: u16, against: ai.ValidTarget) Fighter {
        const all = ctx.world.objects;
        const slot = &all.slots[index];
        return .{
            .ctx = ctx,
            .index = index,
            .slot = slot,
            .state = &slot.state.fight,
            .pilot = all.pilots.get(slot.object.pilot),
            .against = against,
        };
    }

    /// The ship in slot `index` under the Fight order, against its order's target read on trust,
    /// as `order_fight_init` reads it, where it names one of the slots
    /// (`aigeneric.Target.slotIn`): the target may be one it can no longer aim at, which the
    /// update then pops.
    pub fn unchecked(ctx: aigeneric.Context, index: u16) ?Fighter {
        const all = ctx.world.objects;
        const read = all.slots[index].orders[0].target;
        const slot = read.slotIn(all) orelse return null;
        return .of(ctx, index, .{ .target = read, .slot = slot });
    }

    pub fn objects(fighter: Fighter) *create.Objects {
        return fighter.ctx.world.objects;
    }

    pub fn now(fighter: Fighter) i32 {
        return fighter.ctx.world.clock.frame_start;
    }

    pub fn ship(fighter: Fighter) *gameobj.GameObject {
        return &fighter.slot.object;
    }

    /// Where the ship will be at the next step, which the fighting goes by.
    pub fn position(fighter: Fighter) Vector {
        return fighter.ship().nextPosition();
    }

    /// Where the ship's nose will point at the next step.
    pub fn heading(fighter: Fighter) Vector {
        return fighter.ship().nextHeading();
    }

    /// The square of how far `object` will be from the ship at the next step.
    pub fn apartSquared(fighter: Fighter, object: *const gameobj.GameObject) f32 {
        return math.lengthSquared(object.nextPosition() - fighter.position());
    }

    pub fn entry(fighter: Fighter) *aigeneric.Entry {
        return &fighter.slot.orders[0];
    }

    pub fn target(fighter: Fighter) aigeneric.Target {
        return fighter.against.target;
    }

    /// The target's slot.
    pub fn enemy(fighter: Fighter) *create.Slot {
        return &fighter.objects().slots[fighter.against.slot];
    }

    pub fn enemyPosition(fighter: Fighter) Vector {
        return fighter.enemy().object.nextPosition();
    }

    /// Where the object at the action sphere's centre will be.
    pub fn sphereCentre(fighter: Fighter) Vector {
        const all = fighter.objects();
        return all.slots[all.action_sphere.centre].object.nextPosition();
    }

    /// The part of the target it aims at (`0x004018F0`).
    pub fn aimed(fighter: Fighter) ai.Aimed {
        return ai.aimedAt(fighter.objects(), fighter.against);
    }

    /// `object_cruise_speed` of the ship; nothing for one with no flight stats.
    pub fn cruise(fighter: Fighter) f32 {
        return ai.slotCruise(fighter.slot, fighter.ctx.world.view) orelse 0;
    }

    /// Steers at `at` the pilot's way, with its limit and its ease.
    pub fn steer(fighter: Fighter, at: Vector, flags: ai.Steering) void {
        _ = ai.steer(fighter.ctx.world, fighter.index, at, fighter.pilot.turn_limit, fighter.pilot.turn_ease, flags);
    }

    /// The ship's own random number from 0 to 1 (`object_random`).
    pub fn random(fighter: Fighter) f32 {
        return xtrabits.objectRandom(fighter.ship());
    }

    /// The ship's own random number from 0 to 32767 (`object_random15`).
    pub fn random15(fighter: Fighter) u15 {
        return xtrabits.objectRandom15(fighter.ship());
    }

    /// A number from `least` up to `most` as the game draws one: `least` plus the ship's random
    /// number modulo the span.
    ///
    /// **Fix:** where the span is nothing the game divides by zero; OpenReliant takes `least`.
    pub fn randomBetween(fighter: Fighter, least: i32, most: i32) i32 {
        const drawn: i32 = fighter.random15();
        const span = most - least;
        return if (span == 0) least else least + @rem(drawn, span);
    }

    /// The tick a wait drawn from `range` ends at: its least plus the ship's random number modulo
    /// its span (`randomBetween`), from now.
    pub fn waitFrom(fighter: Fighter, range: pilots.Pilot.Range) i32 {
        return fighter.randomBetween(range.least, range.most) + fighter.now();
    }

    /// The players' ships still in the action (`GameObject.Flags.outOfAction`).
    pub fn players(fighter: Fighter) Players {
        const all = fighter.objects();
        return .{ .slots = all.slots[0..all.players] };
    }

    /// Whether a player's ship still in the action is within `reach` of the ship.
    pub fn playerWithin(fighter: Fighter, reach: f32) bool {
        var each = fighter.players();
        while (each.next()) |player| {
            if (fighter.apartSquared(player) < reach * reach) return true;
        }
        return false;
    }
};

/// An iterator over the players' ships still in the action (`Fighter.players`).
pub const Players = struct {
    slots: []create.Slot,

    pub fn next(each: *Players) ?*gameobj.GameObject {
        while (each.slots.len > 0) {
            const object = &each.slots[0].object;
            each.slots = each.slots[1..];
            if (!object.flags.outOfAction()) return object;
        }
        return null;
    }
};

/// The order's `init` (`order_fight_init`, `0x0040A4D0`): chooses the first maneuver and draws the
/// wait for the first missile, marks the ship as fighting its target and the target as fought one
/// more time, and forgets what the ship had lately taken.
///
/// **Fix:** the game takes the target's index as a ship's slot whatever it holds, and stops with
/// "pilot not setup for %s" (`0x004E1980`) for a ship with no pilot record, such as a stand-in.
/// OpenReliant leaves a target past the objects for the update to pop, and fights with the pilot
/// its number gives (`pilots.Table.get`).
///
/// Not ported: a multiplayer game's, where the host chooses the maneuvers and the ship starts on
/// 200 ticks of the first ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn init(ctx: aigeneric.Context, index: u16) void {
    const fighter = Fighter.unchecked(ctx, index) orelse return;
    if (fighter.against.slot >= ctx.world.objects.count) return;
    choose(fighter);
    drawMissileWait(fighter);
    const ship = fighter.ship();
    ship.fighting = .of(fighter.against.slot);
    fighter.enemy().object.fought_by += 1;
    ship.recent_damage = 0;
}

/// The order's update (`order_fight`, `0x0040A5E0`): pops the order once its target can no longer
/// be fought. Otherwise it chooses the next maneuver once this one's time is up, starts a newly
/// chosen one, aims and fires, calls for help, cloaks or uncloaks as the maneuver asks
/// (`updateCloak`) and runs the maneuver.
///
/// Not ported: a multiplayer game's, where the host chooses the maneuvers
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
pub fn update(ctx: aigeneric.Context, index: u16) void {
    const fighter: Fighter = .of(ctx, index, ai.targetOrPop(ctx, index, .{}) orelse return);
    if (fighter.now() > fighter.state.maneuver_end) choose(fighter);
    const data = &fighter.entry().data.fight;
    if (data.fresh) begin(fighter, data);
    aim(fighter);
    callForHelp(fighter);
    updateCloak(fighter);
    aidefend.run(fighter);
}

/// `fight_update_cloak` (`0x00409EC0`): a ship whose model can cloak cloaks once the maneuver's
/// `Cloak` has asked for the cloak and `cloak_at` has come, and uncloaks while the maneuver asks
/// for none, as a new maneuver does until it asks (`cloak.set`).
fn updateCloak(fighter: Fighter) void {
    if (!cloak.canCloak(fighter.slot)) return;
    if (!fighter.state.cloak) return cloak.set(fighter.ctx.world, fighter.index, false);
    if (fighter.now() >= fighter.state.cloak_at) cloak.set(fighter.ctx.world, fighter.index, true);
}

test updateCloak {
    const gpa = std.testing.allocator;
    var stage: cloak.testing.Cloaked = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const slot = stage.slot();
    // The stage's zeroed order names slot 0.
    const fighter = Fighter.unchecked(stage.mission.orders(), stage.index).?;

    // The maneuver's cloak comes on from `cloak_at`, not before.
    fighter.state.cloak = true;
    fighter.state.cloak_at = 100;
    stage.mission.clock.frame_start = 99;
    updateCloak(fighter);
    try std.testing.expect(!slot.object.flags.cloaked);
    stage.mission.clock.frame_start = 100;
    updateCloak(fighter);
    try std.testing.expect(slot.object.flags.cloaked);
    // A maneuver that asks for none uncloaks the ship, once the cloak has come on.
    cloak.frame(slot, 100 + cloak.change_ticks);
    fighter.state.cloak = false;
    updateCloak(fighter);
    try std.testing.expect(slot.cloak.?.going);
}

/// Starts the maneuver `choose` left in the order's data: the state cleared, its first line still
/// to come, a random choice of the inputs it may mirror, and its time counted from now. With none
/// chosen, the state takes the data's byte as the game copies it, a number no maneuver has, which
/// runs nothing.
fn begin(fighter: Fighter, data: *FightData) void {
    const state = fighter.state;
    state.* = std.mem.zeroes(FightState);
    state.maneuver = data.next() orelse @enumFromInt(FightData.none);
    state.line = FightState.before_first;
    const allowed: Mirror = if (maneuvers.info(state.maneuver)) |info| info.mirror else .{};
    state.mirror = allowed.pick(fighter.random15());
    state.maneuver_end = @as(i32, @as(u16, @bitCast(data.ticks))) + fighter.now();
    state.ship = data.ship;
    data.fresh = false;
}

/// A maneuver `choose` picks, how long for where it says, and the ship it runs to where that is
/// what it does.
const Choice = struct {
    maneuver: Maneuver,
    /// Null to draw it from the maneuver's range.
    ticks: ?i16 = null,
    ship: ?u16 = null,
};

/// Against a target with components, a ship attacks it for this long (`fight_choose_against_
/// massive`, `0x0040A220`); a ship with components attacks as one for this long
/// (`fight_choose_as_massive`, `0x0040A390`); a ship out of the action sphere heads back for this
/// long.
const against_massive: Choice = .{ .maneuver = .attack_massive_object, .ticks = 20000 };
const as_massive: Choice = .{ .maneuver = .attack_medium_fighter, .ticks = 10000 };
const back_to_sphere: Choice = .{ .maneuver = .out_of_action_sphere, .ticks = 500 };

/// `fight_choose_maneuver` (`0x0040A3A0`): the next maneuver, into the order's data for the next
/// update to start. A target with components is attacked as a massive object, and a ship with
/// components attacks as one; between two ships without, a ship strays back to the action sphere
/// where it has left it, and otherwise chooses by where the two are (`byPosition`). Where the
/// choice gives no length, it is drawn from the maneuver's range.
fn choose(fighter: Fighter) void {
    const data = &fighter.entry().data.fight;
    data.fresh = true;
    const choice: Choice = if (fighter.enemy().object.flags.components)
        against_massive
    else if (fighter.ship().flags.components)
        as_massive
    else
        outOfSphere(fighter) orelse byPosition(fighter);
    data.setNext(choice.maneuver);
    if (choice.ship) |friend| data.ship = friend;
    data.ticks = choice.ticks orelse drawn: {
        const info = maneuvers.table[@intFromEnum(choice.maneuver)];
        // The game adds in 16 bits.
        break :drawn @truncate(fighter.randomBetween(info.min_ticks, info.max_ticks));
    };
}

/// How far off a ship outside the action sphere its target must be, inside it, for the ship to
/// fight on out there (`0x004DC4F0`, its square), and how near a player's ship keeps it fighting
/// (`0x004DC4EC`, its square).
const far_enemy: f32 = 200000;
const player_near: f32 = 100000;

/// `fight_choose_out_of_sphere` (`0x0040A230`): back to the action sphere, for a ship fighting
/// anything but a player's that has left the sphere. It fights on where its target is far off but
/// inside the sphere, and where a player's ship is near.
fn outOfSphere(fighter: Fighter) ?Choice {
    const all = fighter.objects();
    if (fighter.target().index < all.players) return null;
    const centre = fighter.sphereCentre();
    const reach = all.action_sphere.radius * all.action_sphere.radius;
    if (math.lengthSquared(fighter.position() - centre) < reach) return null;
    const enemy = fighter.enemyPosition();
    if (math.lengthSquared(fighter.position() - enemy) > far_enemy * far_enemy and math.lengthSquared(enemy - centre) < reach) return null;
    if (fighter.playerWithin(player_near)) return null;
    return back_to_sphere;
}

/// The least share of its top speed a target is taken to fly at (`0x004DC3D4`).
const least_pace: f32 = 0.25;

/// How far off a target a pilot pursues it, by skill, before the target's pace scales it
/// (`pursue_distances`, `0x004E193C`).
///
/// **Fix:** the table holds three, and the game indexes it with the skill as a signed word
/// (`0x0040A0D0`), reading whatever lies past it or before it. For 3 to 8 that is a string's
/// bytes, so large that the ship never pursues. For others, such as 9, 16, 20 to 24 and 26 to 28,
/// and every skill from -1 to -24, it is a number so small, or 0, that the ship always pursues.
/// OpenReliant never pursues by distance for a skill outside the table.
fn pursuit(skill: pilots.Pilot.Skill) f32 {
    return switch (skill) {
        .low => 300000,
        .medium => 200000,
        .high => 100000,
        .other => std.math.inf(f32),
    };
}

/// The cosines at which a direction is ahead of a nose, and behind it: the target from the ship's
/// (`0x004DC408`, `0x004DC41C`) and the ship from the target's (`0x004DC4E8`).
const ahead_cosine: f32 = 0.5;
const behind_cosine: f32 = -0.5;
const seen_behind_cosine: f32 = -0.1;

/// How close the ships are when the ship runs for it (`0x004DC43C`), and when
/// `AttackMediumFighter` flies straight on (`aidefend`).
pub const close_quarters: f32 = 10000;

/// One in this many times a ship with its target behind looks for a friendly ship to run to
/// (`0x0040A1A7`).
const run_odds = 10;

/// `fight_choose_by_position` (`0x0040A000`), between two ships without components: pursuit of a
/// target far off for the pilot's skill; then, with the target behind, one time in `run_odds` a
/// run to a friendly capital ship where there is one; running away at close quarters; and
/// otherwise a random pick among `maneuvers.choices` by where each ship is from the other's nose.
///
/// The game also walks the player's weapons here while the player's guns are damaged, to no
/// effect.
fn byPosition(fighter: Fighter) Choice {
    const enemy = fighter.enemy();
    const toward = fighter.enemyPosition() - fighter.position();
    const apart = math.length(toward);
    const top = if (enemy.flight) |flight| flight.max_speed else 0;
    const pace = @max(enemy.object.speed / top, least_pace);
    if (apart > pace * pursuit(fighter.pilot.skill())) return .{ .maneuver = .attack_pursue };
    const where = bearing(math.cosineOff(toward, fighter.heading()), behind_cosine);
    const seen = bearing(-math.cosineOff(toward, enemy.object.nextHeading()), seen_behind_cosine);
    if (where == .behind and fighter.random15() % run_odds == 0) {
        if (shipToRunTo(fighter)) |friend| return .{ .maneuver = .run_to_ship, .ship = friend };
    }
    if (apart < close_quarters) return .{ .maneuver = .defend_runaway };
    const list = maneuvers.choices[@intFromEnum(where)][@intFromEnum(seen)];
    return .{ .maneuver = list[@as(usize, fighter.random15()) % list.len] };
}

comptime {
    for (maneuvers.choices) |row| for (row) |list| assert(list.len > 0);
}

/// Where a direction is from a nose, by the cosine of the angle between them.
fn bearing(cosine: f32, behind: f32) Bearing {
    if (cosine > ahead_cosine) return .ahead;
    return if (cosine <= behind) .behind else .abeam;
}

/// How far the nearest-ship searches start, a square further than anything is from anything
/// (`0x00409DCA`, `0x00409F19`).
const farthest: f32 = 9e10;

/// The nearest of the ships a search is offered, as the game's searches keep it: from `farthest`,
/// each nearer one in turn.
const Nearest = struct {
    index: ?u16 = null,
    apart: f32 = farthest,

    fn offer(nearest: *Nearest, index: usize, apart: f32) void {
        if (apart < nearest.apart) nearest.take(index, apart);
    }

    fn take(nearest: *Nearest, index: usize, apart: f32) void {
        nearest.* = .{ .index = @intCast(index), .apart = apart };
    }
};

/// How near the edge of a friendly capital ship counts as having run to it already
/// (`0x004DC494`).
const run_to_berth: f32 = 50000;

/// `fight_find_ship_to_run_to` (`0x00409F00`): the nearest capital or support ship with
/// components on the ship's side, to run to. None where the ship is already near one.
fn shipToRunTo(fighter: Fighter) ?u16 {
    const all = fighter.objects();
    var nearest: Nearest = .{};
    for (all.slots[0..all.count], 0..) |*slot, index| {
        if (slot.object.flags.outOfSearch() or !slot.object.flags.components) continue;
        if (slot.object.side != fighter.ship().side) continue;
        const combat = slot.combat orelse continue;
        if (combat.class != .capital and combat.class != .support) continue;
        const apart = fighter.apartSquared(&slot.object);
        const berth = slot.object.radius + run_to_berth;
        if (apart < berth * berth) return null;
        nearest.offer(index, apart);
    }
    return nearest.index;
}

/// The share of the target's velocity the aim drifts by (`fight_aim`, `0x00409C6D`).
const aim_drift: f32 = 0.25;

/// `fight_aim` (`0x00409BE0`): every `aim_interval` ticks the pilot aims afresh, ahead of the
/// target where it can lead it (`ai.leadAim`) and otherwise at it, and reckons the aim's drift as a
/// quarter of the target's velocity, turned on by half as many of the target's turns. Between times
/// the aim drifts on. Then it fires.
fn aim(fighter: Fighter) void {
    const state = fighter.state;
    const enemy = &fighter.enemy().object;
    if (state.next_aim < fighter.now()) {
        state.next_aim = @as(i32, fighter.pilot.aim_interval) + fighter.now();
        if (ai.leadAim(fighter.objects(), fighter.index, fighter.against, 1)) |led| {
            state.aim = gameobj.vec3(led);
            state.led = true;
        } else {
            state.led = false;
            state.aim = if (fighter.target().part() == null) enemy.root.next_position else gameobj.vec3(fighter.aimed().position);
        }
        var drift = gameobj.vector(enemy.velocity) * @as(Vector, @splat(aim_drift));
        var turns = @divTrunc(fighter.pilot.aim_interval, 2);
        while (turns > 0) : (turns -= 1) drift = math.transform(enemy.rotation, drift);
        state.aim_velocity = gameobj.vec3(drift);
    }
    const step: f32 = @floatFromInt(fighter.ctx.world.clock.frame_duration);
    state.aim = gameobj.vec3(gameobj.vector(state.aim) + gameobj.vector(state.aim_velocity) * @as(Vector, @splat(step)));
    fire(fighter);
}

/// The share of a laser cannon's range within which a pilot fires (`0x004DC3D4`).
const fire_range: f32 = 0.25;

/// A friendly ship holds its fire while a player's ship is ahead of it, from nothing up to
/// `in_line_reach` along its nose, within `in_line_spread` of that distance, the player's radius
/// and `in_line_margin` of the line (`0x004DC3D0`, `0x004DC494`, `0x004DC4E4`, `0x004DC4A8`).
const in_line_reach: f32 = 50000;
const in_line_spread: f32 = 0.1;
const in_line_margin: f32 = 500;

/// `fight_fire` (`0x004096B0`): once `pause` has passed since the pilot last looked, it fires for
/// `burst` ticks where the aim point is within `fire_spread` of the target's radius of the line
/// along its nose and the part it aims at is within `fire_range` of a laser cannon's range; a
/// friendly ship holds its fire while a player's ship is in the way. A cloaked ship doesn't fire.
/// Then it times its missiles and countermeasures.
///
/// A cloaked target is fired at only where it stands further off than both radii and
/// `close_quarters` (`cloak_target_far`, `0x00463BD0`); otherwise the ship skips its missiles and
/// countermeasures too. The order doesn't keep a cloaked target (`ai.target_barred`), so that
/// doesn't come up here.
fn fire(fighter: Fighter) void {
    const ship = fighter.ship();
    if (ship.flags.cloaked) return;
    const all = fighter.objects();
    const timings = fighter.pilot.timings;
    const aimed = fighter.aimed();
    const radius = if (fighter.target().part() == null) fighter.enemy().object.radius else aimed.radius;
    if (fighter.now() > ship.fire_at) {
        const laser = guns.GunType.laser_cannon.stats(&all.gun_stats);
        const range = @as(f32, @floatFromInt(laser.lifetime)) * laser.speed * fire_range;
        if (ai.alongNose(fighter.slot.drawn, gameobj.vector(fighter.state.aim), radius * fighter.pilot.fire_spread) and
            math.distance(fighter.position(), aimed.position) < range and
            !(ship.side == .friendly and playerInLine(fighter)))
        {
            guns.fire(ship, fighter.slot.trigger(fighter.now()), timings.burst);
        }
        ship.fire_at = @as(i32, timings.pause) + fighter.now();
    }
    aimMissile(fighter);
    if (!fighter.state.missile_ready) drawMissileWait(fighter);
    counterMissiles(fighter);
}

/// The odds of launching a missile ready each time the wait for it comes round (`0x004DC3F8`).
const launch_odds: f32 = 0.2;

/// `fight_fire`'s missiles: of the first rack with missiles left but for Jack Hammers, which the
/// ship keeps for order 3, a lock builds while the target's node lies within the type's lock range
/// and 0.7 of the ship's nose, and is ready once the type's lock time has passed. Ready, each time
/// the wait comes round the ship launches one time in five, and either way draws its wait again
/// and locks again from the start.
///
/// Not ported: a multiplayer game's client, which leaves the launch to the host
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn aimMissile(fighter: Fighter) void {
    const ship = fighter.ship();
    const all = fighter.objects();
    const state = fighter.state;
    state.missile_ready = false;
    const now = fighter.now();
    for (ship.fittedRacks(), 0..) |rack, at| {
        if (rack.count <= 0 or rack.type == .jack_hammer) continue;
        const stats = all.missile_stats.of(rack.type) orelse break;
        if (!missiles.inLockReach(stats, fighter.aimed().position - fighter.position(), fighter.heading())) state.locked_at = stats.lock_time + now;
        if (state.locked_at < now) state.missile_ready = true;
        if (state.missile_ready and ship.missile_at < now) {
            if (fighter.ctx.world.random.fraction() < launch_odds) missiles.launch(fighter.ctx.world, fighter.index, at, fighter.target());
            drawMissileWait(fighter);
            state.locked_at = stats.lock_time + now;
            state.missile_ready = false;
        }
        break;
    }
}

/// `fight_fire`'s countermeasures: with no missile homing on the ship, the wait for the next is
/// held at the pilot's least; with one, once the wait has passed, the ship draws it again and
/// drops a countermeasure.
///
/// Not ported: a multiplayer game's client, which leaves the countermeasure to the host
/// ([#55](https://github.com/vdmkenny/openreliant/issues/55)).
fn counterMissiles(fighter: Fighter) void {
    const ship = fighter.ship();
    const range = fighter.pilot.timings.countermeasures;
    if (ship.missile_homing == 0) {
        ship.countermeasure_at = @as(i32, range.least) + fighter.now();
        return;
    }
    if (ship.countermeasure_at >= fighter.now()) return;
    ship.countermeasure_at = fighter.waitFrom(range);
    if (fighter.ctx.world.countermeasures) |dropped| dropped.spend(fighter.ctx.world, fighter.index);
}

/// Whether a player's ship still in the action is in the way of the ship's guns.
fn playerInLine(fighter: Fighter) bool {
    const nose = fighter.heading();
    var each = fighter.players();
    while (each.next()) |player| {
        const toward = player.nextPosition() - fighter.position();
        const along = math.dot(nose, toward);
        if (!(along >= 0 and along <= in_line_reach)) continue;
        const off = math.distance(toward, nose * @as(Vector, @splat(along)));
        if (off < along * in_line_spread + player.radius + in_line_margin) return true;
    }
    return false;
}

/// Draws the wait for the ship's next missile from the pilot's range (`missile_at`).
fn drawMissileWait(fighter: Fighter) void {
    fighter.ship().missile_at = fighter.waitFrom(fighter.pilot.timings.missiles);
}

/// The share of its armour class times six a ship must lately have taken from the player to call
/// for help (`0x004DC3F8`), and the share an armour quadrant must be below (`0x004DC408`).
const help_damage: f32 = 0.2;
const help_armor: f32 = 0.5;

/// `fight_call_for_help` (`0x00409D10`): a ship fighting the player that the player has lately hurt
/// badly, with an armour quadrant below half, forgets the damage and sends its nearest wingman
/// (`wingman`) at the player too.
fn callForHelp(fighter: Fighter) void {
    const all = fighter.objects();
    const ship = fighter.ship();
    if (fighter.target().index != all.player) return;
    const combat = fighter.slot.combat orelse return;
    const worth = combat.fullArmor();
    if (ship.recent_damage < worth * help_damage) return;
    if (ship.last_attacker.index() != all.player) return;
    for (ship.armor.values()) |armor| {
        if (armor < worth * help_armor) break;
    } else return;
    ship.recent_damage = 0;
    const helper = wingman(fighter) orelse return;
    _ = aigeneric.giveShip(fighter.ctx, helper, .fight, all.player, null);
}

/// The wingman `callForHelp` calls: the nearest fighter on the ship's side, not the ship itself nor
/// one told not to be disturbed, that is fighting or milling. The first milling one found takes
/// over from any fighting one found before it, however near; from there the nearest wins.
fn wingman(fighter: Fighter) ?u16 {
    const all = fighter.objects();
    var nearest: Nearest = .{};
    var milling = false;
    for (all.slots[0..all.count], 0..) |*slot, index| {
        if (index == fighter.index) continue;
        if (slot.object.flags.outOfSearch() or slot.object.flags.do_not_disturb) continue;
        if (slot.object.side != fighter.ship().side) continue;
        const combat = slot.combat orelse continue;
        if (combat.class != .fighter) continue;
        const order = (slot.current() orelse continue).order;
        if (order != .fight and order != .mill) continue;
        const apart = fighter.apartSquared(&slot.object);
        if (order == .mill and !milling) {
            milling = true;
            nearest.take(index, apart);
        } else nearest.offer(index, apart);
    }
    return nearest.index;
}

test {
    std.testing.refAllDecls(@This());
}

/// Fixtures for the tests here and in `aidefend.zig`.
pub const testing = struct {
    /// The player's Predator, and a Sabre `apart` ahead of it, facing away, under a Fight order
    /// against it that has yet to start.
    pub fn fighter(mission: *gameobj.testing.Mission, apart: f32) !Fighter {
        const ctx = mission.orders();
        const player = try mission.add(.predator, @splat(0));
        const index = try mission.add(.sabre, .{ 0, 0, apart });
        try std.testing.expect(try aigeneric.pushShip(ctx, index, .fight, player, null));
        return Fighter.unchecked(ctx, index) orelse error.NoTarget;
    }
};

/// `testing.fighter`, with the order started.
fn testFight(mission: *gameobj.testing.Mission, apart: f32) !Fighter {
    const fighter = try testing.fighter(mission, apart);
    aigeneric.objectOrders(fighter.ctx, fighter.index);
    return fighter;
}

test init {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 300000);
    const all = mission.objects;

    // The ship fights the player, who is fought once, and the wait for the first missile is drawn
    // from the pilot's range.
    try std.testing.expectEqual(0, fighter.ship().fighting.index());
    try std.testing.expectEqual(1, all.slots[0].object.fought_by);
    const wait = fighter.pilot.timings.missiles;
    try std.testing.expect(fighter.ship().missile_at >= wait.least and fighter.ship().missile_at < wait.most);
    // The player is at rest, so taken at a quarter of its top speed, and far off for a pilot of
    // middling skill: the Sabre pursues it for a length drawn from the maneuver's range.
    try std.testing.expectEqual(Maneuver.attack_pursue, fighter.state.maneuver);
    try std.testing.expect(!fighter.entry().data.fight.fresh);
    const info = maneuvers.table[@intFromEnum(Maneuver.attack_pursue)];
    try std.testing.expect(fighter.state.maneuver_end >= info.min_ticks and fighter.state.maneuver_end < info.max_ticks);
}

test choose {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 300000);
    const data = &fighter.entry().data.fight;

    // Close in, with the player behind it and no friendly capital ship to run to, it runs.
    fighter.ship().root.next_position = .{ .x = 0, .y = 0, .z = 5000 };
    choose(fighter);
    try std.testing.expect(data.fresh);
    try std.testing.expectEqual(Maneuver.defend_runaway, data.next());
    // A target with components is attacked as a massive object, for its fixed time.
    fighter.enemy().object.flags.components = true;
    choose(fighter);
    try std.testing.expectEqual(Maneuver.attack_massive_object, data.next());
    try std.testing.expectEqual(against_massive.ticks.?, data.ticks);

    // The next update starts it.
    fighter.state.maneuver_end = -1;
    mission.clock.frame_start = 5;
    update(fighter.ctx, fighter.index);
    try std.testing.expectEqual(Maneuver.attack_massive_object, fighter.state.maneuver);
    try std.testing.expectEqual(20005, fighter.state.maneuver_end);
}

test "a target that can't be fought ends the order" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 300000);
    fighter.enemy().object.flags.exploding = true;
    update(fighter.ctx, fighter.index);
    try std.testing.expectEqual(0, fighter.ship().order_count);
}

test bearing {
    try std.testing.expectEqual(Bearing.ahead, bearing(0.6, behind_cosine));
    try std.testing.expectEqual(Bearing.abeam, bearing(0.5, behind_cosine));
    try std.testing.expectEqual(Bearing.behind, bearing(-0.5, behind_cosine));
    try std.testing.expectEqual(Bearing.abeam, bearing(-0.2, behind_cosine));
    try std.testing.expectEqual(Bearing.behind, bearing(-0.2, seen_behind_cosine));
}

test "Fighter.randomBetween" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 300000);
    for (0..20) |_| {
        const drawn = fighter.randomBetween(10, 20);
        try std.testing.expect(drawn >= 10 and drawn < 20);
    }
    // No span, where the game would divide by zero.
    try std.testing.expectEqual(7, fighter.randomBetween(7, 7));
    // A wait drawn from a range ends that far from now.
    mission.clock.frame_start = 1000;
    for (0..20) |_| {
        const ends = fighter.waitFrom(.{ .least = 10, .most = 20 });
        try std.testing.expect(ends >= 1010 and ends < 1020);
    }
}

test pursuit {
    try std.testing.expectEqual(300000, pursuit(.low));
    try std.testing.expectEqual(200000, pursuit(.medium));
    try std.testing.expectEqual(100000, pursuit(.high));
    // Outside the table, never by distance.
    try std.testing.expectEqual(std.math.inf(f32), pursuit(.other));
}

test outOfSphere {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const all = mission.objects;
    const started = try testFight(&mission, 300000);
    const player = &all.slots[0].object;
    // The Sabre fights a ship near it, far out of a small sphere around the player.
    const other = try mission.add(.sabre, .{ 0, 0, 310000 });
    started.entry().target = .at(other, null);
    const fighter = Fighter.unchecked(started.ctx, started.index).?;
    all.action_sphere = .{ .centre = 0, .radius = 1000 };

    // With no player's ship near it, it heads back to the sphere.
    try std.testing.expectEqual(back_to_sphere, outOfSphere(fighter).?);
    // It fights on where its target is far off but inside the sphere.
    all.slots[other].object.root.next_position = .{ .x = 0, .y = 0, .z = 500 };
    try std.testing.expectEqual(null, outOfSphere(fighter));
    // And where a player's ship is near, its target outside the sphere.
    all.slots[other].object.root.next_position = .{ .x = 0, .y = 0, .z = 310000 };
    player.root.next_position = .{ .x = 0, .y = 0, .z = 250000 };
    try std.testing.expectEqual(null, outOfSphere(fighter));
    // A ship fighting a player's ship fights on wherever it is.
    player.root.next_position = .{ .x = 0, .y = 0, .z = 0 };
    started.entry().target = .at(0, null);
    try std.testing.expectEqual(null, outOfSphere(Fighter.unchecked(started.ctx, started.index).?));
}

test shipToRunTo {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 20000);
    mission.tables.combat[@intFromEnum(gameobj.Type.mammoth)].class = .capital;
    const mammoth = try mission.add(.mammoth, .{ 0, 0, 200000 });
    const friend = &mission.slot(mammoth).object;
    friend.side = fighter.ship().side;
    friend.radius = 1000;

    // A capital ship on its side without components is passed over.
    friend.flags.components = false;
    try std.testing.expectEqual(null, shipToRunTo(fighter));
    // With them, the ship runs to it.
    friend.flags.components = true;
    try std.testing.expectEqual(mammoth, shipToRunTo(fighter).?);
    // On another side, it doesn't.
    friend.side = if (fighter.ship().side == .friendly) .hostile else .friendly;
    try std.testing.expectEqual(null, shipToRunTo(fighter));
    // Within its radius and `run_to_berth` of it, the ship has run to it already.
    friend.side = fighter.ship().side;
    friend.root.next_position = .{ .x = 0, .y = 0, .z = 20000 + run_to_berth };
    try std.testing.expectEqual(null, shipToRunTo(fighter));
}

test aim {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 20000);
    const state = fighter.state;
    const enemy = &fighter.enemy().object;
    enemy.velocity = .{ .x = 0, .y = 0, .z = 8 };
    enemy.rotation = math.identity;
    mission.clock.frame_start = 100;
    mission.clock.frame_duration = 4;

    // Due, the pilot aims afresh, and again `aim_interval` ticks on; the aim drifts by a quarter
    // of the target's velocity, turned as the target turns.
    state.next_aim = 99;
    aim(fighter);
    try std.testing.expectEqual(@as(i32, fighter.pilot.aim_interval) + 100, state.next_aim);
    try std.testing.expectEqual(Vec3{ .x = 0, .y = 0, .z = 2 }, state.aim_velocity);
    // Between times the aim drifts on, by its velocity for each tick of the frame.
    state.aim = .{ .x = 10, .y = 20, .z = 30 };
    state.aim_velocity = .{ .x = 1, .y = 2, .z = 3 };
    aim(fighter);
    try std.testing.expectEqual(Vec3{ .x = 14, .y = 28, .z = 42 }, state.aim);
    try std.testing.expectEqual(@as(i32, fighter.pilot.aim_interval) + 100, state.next_aim);
}

test fire {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    const fighter = try testFight(&mission, 20000);
    const ship = fighter.ship();
    const timings = fighter.pilot.timings;
    // The Sabre faces the player, its aim on it, with a Laser Cannon fitted whose range reaches it.
    const turned = math.rotation(.y, std.math.pi);
    fighter.slot.drawn.orientation = turned;
    ship.root.next_orientation = turned;
    fighter.state.aim = .{ .x = 0, .y = 0, .z = 0 };
    all.slots[0].object.radius = 100;
    const laser = &all.gun_stats.types[guns.GunType.laser_cannon.number()];
    laser.lifetime = 100;
    laser.speed = 1000;
    try guns.testing.fitTo(fighter.slot, gpa, &.{guns.testing.barrel(.laser_cannon)});
    ship.gun_mode.all = true;
    const gun = &fighter.slot.guns[0];
    mission.clock.frame_start = 100;

    // A hostile ship fires for the pilot's burst once its pause has passed, and looks again a
    // pause on.
    ship.side = .hostile;
    ship.fire_at = 99;
    fire(fighter);
    try std.testing.expectEqual(@as(i32, timings.burst) + 100, gun.firing_until);
    try std.testing.expectEqual(@as(i32, timings.pause) + 100, ship.fire_at);
    // Until then it doesn't look.
    gun.firing_until = 0;
    fire(fighter);
    try std.testing.expectEqual(0, gun.firing_until);
    // A friendly ship holds its fire with the player in the way, and looks again a pause on.
    ship.side = .friendly;
    ship.fire_at = 99;
    fire(fighter);
    try std.testing.expectEqual(0, gun.firing_until);
    try std.testing.expectEqual(@as(i32, timings.pause) + 100, ship.fire_at);
}

test counterMissiles {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 20000);
    const ship = fighter.ship();
    const range = fighter.pilot.timings.countermeasures;
    const least: i32 = range.least;
    const most: i32 = range.most;
    mission.clock.frame_start = 100;

    // With no missile homing on the ship, the wait for the next is held at the pilot's least.
    ship.missile_homing = 0;
    counterMissiles(fighter);
    try std.testing.expectEqual(least + 100, ship.countermeasure_at);
    // With one, the ship waits that out, then draws the wait again from the pilot's range.
    ship.missile_homing = 1;
    mission.clock.frame_start = least + 100;
    counterMissiles(fighter);
    try std.testing.expectEqual(least + 100, ship.countermeasure_at);
    mission.clock.frame_start += 1;
    counterMissiles(fighter);
    const now = mission.clock.frame_start;
    try std.testing.expect(ship.countermeasure_at >= least + now and ship.countermeasure_at < most + now);
}

test playerInLine {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 20000);
    const player = &fighter.objects().slots[0].object;

    // The Sabre faces away from the player, so the player is not in its way.
    try std.testing.expect(!playerInLine(fighter));
    // Ahead of it along its nose, it is.
    player.root.next_position = .{ .x = 0, .y = 0, .z = 40000 };
    try std.testing.expect(playerInLine(fighter));
    // Well off the line, or past the reach, it isn't.
    player.root.next_position = .{ .x = 10000, .y = 0, .z = 40000 };
    try std.testing.expect(!playerInLine(fighter));
    player.root.next_position = .{ .x = 0, .y = 0, .z = 80000 };
    try std.testing.expect(!playerInLine(fighter));
}

test callForHelp {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const ctx = mission.orders();
    const fighter = try testFight(&mission, 20000);
    const far = try mission.add(.sabre, .{ 0, 0, 90000 });
    const near = try mission.add(.sabre, .{ 0, 0, 30000 });
    const milling = try mission.add(.sabre, .{ 0, 0, 120000 });
    const none: aigeneric.Target = .none;
    try std.testing.expect(try aigeneric.push(ctx, far, .mill, none));
    try std.testing.expect(try aigeneric.push(ctx, near, .fly, none));
    try std.testing.expect(try aigeneric.push(ctx, milling, .mill, none));

    // Not hurt enough: nobody is called.
    const ship = fighter.ship();
    ship.last_attacker = .of(0);
    callForHelp(fighter);
    try std.testing.expectEqual(Order.fly, mission.objects.slots[near].orders[0].order);

    // Hurt badly by the player, with a quadrant of armour below half: the first milling Sabre is
    // called, being nearer than the other milling one, and the flying one isn't.
    ship.recent_damage = 100;
    ship.armor.aft = 1;
    callForHelp(fighter);
    try std.testing.expectEqual(0, ship.recent_damage);
    try std.testing.expectEqual(Order.fight, mission.objects.slots[far].orders[0].order);
    try std.testing.expectEqual(Order.mill, mission.objects.slots[milling].orders[0].order);
}

test "a Sabre fights the player" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var devices: @import("../input.zig").Devices = .{};
    const fighter = try testFight(&mission, 100000);
    const state = fighter.state;

    // A minute of frames: the Sabre closes on the player and goes from one maneuver to another.
    var nearest = std.math.inf(f32);
    var changes: usize = 0;
    var last = state.maneuver;
    for (0..1500) |_| {
        mission.clock.advanceTimer(4);
        _ = mission.clock.runTicks(&devices, mission.world());
        mission.clock.frameBegin();
        _ = @import("main.zig").missionFrame(fighter.ctx, .{}, null);
        nearest = @min(nearest, math.length(fighter.position()));
        if (state.maneuver != last) changes += 1;
        last = state.maneuver;
    }
    try std.testing.expectEqual(1, fighter.ship().order_count);
    try std.testing.expect(nearest < 20000);
    try std.testing.expect(changes > 1);
}

test aimMissile {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try testFight(&mission, 20000);
    const ship = fighter.ship();
    ship.rack_count = 2;
    ship.racks[0] = .{ .type = .jack_hammer, .count = 1 };
    ship.racks[1] = .{ .type = .raptor, .count = 3 };
    ship.root.next_orientation = math.rotation(.y, std.math.pi);
    mission.clock.frame_start = 10;

    // The Raptors lock on, the Jack Hammer passed over: a fresh order counts its lock from tick 0,
    // so it is ready as soon as the target is in reach.
    aimMissile(fighter);
    try std.testing.expect(fighter.state.missile_ready);
    // Facing away, the lock starts again, ready once the Raptor's lock time has passed.
    ship.root.next_orientation = math.identity;
    aimMissile(fighter);
    try std.testing.expect(!fighter.state.missile_ready);
    try std.testing.expectEqual(10 + mission.objects.missile_stats.of(.raptor).?.lock_time, fighter.state.locked_at);
}
