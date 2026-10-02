//! `C:\lancer\game\aidefend.cpp`: the combat maneuvers, scripts in the developers' own language
//! that the Fight order runs. [`aidefend/maneuvers.zig`](aidefend/maneuvers.zig) holds the
//! maneuvers, their scripts and the handlers of each opcode;
//! [`aidefend/script.zig`](aidefend/script.zig) compiles the scripts as the payload does.

const std = @import("std");
const assert = std.debug.assert;

const shp = @import("../../formats/shp.zig");
const engine = @import("../../engine.zig");
const Pointer = engine.Pointer;
const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const ai = @import("ai.zig");
const aifight = @import("aifight.zig");
const Fighter = aifight.Fighter;
const create = @import("create.zig");
const gameobj = @import("gameobj.zig");
const objects = @import("objects.zig");
const pilots = @import("pilots.zig");

pub const maneuvers = @import("aidefend/maneuvers.zig");
pub const script = @import("aidefend/script.zig");

/// What a compiled instruction does: its first byte.
pub const Opcode = enum(u8) {
    set_yaw = 0,
    set_pitch = 1,
    set_roll = 2,
    set_speed = 3,
    wait = 4,
    goto = 5,
    label = 6,
    set_afterburner = 7,
    runaway = 8,
    attack = 9,
    attack_massive = 10,
    out_of_action_sphere = 11,
    set_mirror = 12,
    @"if" = 13,
    @"else" = 14,
    endif = 15,
    avoid = 16,
    cloak = 17,
    attack_medium_fighter = 18,
    new_attack_run = 19,
    run_to_ship = 20,
    end_script = 21,
};

/// Which of the turning inputs a maneuver may mirror, and which it does once it has chosen.
pub const Mirror = packed struct(u8) {
    yaw: bool = false,
    pitch: bool = false,
    roll: bool = false,
    _unused: u5 = 0,

    pub const all: Mirror = .{ .yaw = true, .pitch = true, .roll = true };

    /// A random choice among the inputs `allowed` may mirror, by the low bits of a ship's random
    /// number.
    pub fn pick(allowed: Mirror, drawn: u15) Mirror {
        return @bitCast(@as(u8, @truncate(drawn)) & @as(u8, @bitCast(allowed)));
    }
};

/// What an `if` asks.
pub const Condition = enum(u8) {
    /// Whether the ship is on course to hit its target.
    going_to_crash = 0,
    _,
};

/// An entry of `maneuvers`.
pub const Maneuver = extern struct {
    /// The inputs the maneuver may mirror: each time it starts, a random choice among them.
    mirror: Mirror,
    _unknown_01: [3]u8,
    script: Pointer(ScriptLine),
    /// The developers' name, such as "loop the loop".
    name: Pointer(u8),
    /// The ticks it runs for, a random number from `min_ticks` to `max_ticks` unless Fight gives
    /// its own.
    min_ticks: u16,
    max_ticks: u16,

    comptime {
        assert(@offsetOf(Maneuver, "script") == 0x4);
        assert(@sizeOf(Maneuver) == 0x10);
    }
};

/// A line of a maneuver's script, which a null `text` ends.
pub const ScriptLine = extern struct {
    text: Pointer(u8),
    /// Its compiled form in `maneuver_code`, which the line gets the first time it runs.
    instruction: Pointer(Instruction),

    comptime {
        assert(@offsetOf(ScriptLine, "instruction") == 0x4);
        assert(@sizeOf(ScriptLine) == 0x8);
    }
};

/// What an opcode's `start` and `run` are: code for the ship in a slot running an instruction.
/// True from `start` makes the instruction wait, calling `run` each update until it returns false;
/// false moves on to the next line at once.
pub const Handler = engine.Code("bool __fastcall (int slot, FightState *state, ManeuverInstruction *instruction)");

/// An entry of `maneuver_handlers`, one for each opcode. Null for none.
pub const Handlers = extern struct {
    start: Pointer(Handler),
    run: Pointer(Handler),

    comptime {
        assert(@offsetOf(Handlers, "run") == 0x4);
        assert(@sizeOf(Handlers) == 0x8);
    }
};

/// A compiled instruction: byte records packed one after another, as long as their opcode needs.
pub const Instruction = extern union {
    opcode: Opcode,
    /// `set_yaw`, `set_pitch`, `set_roll`, `set_speed`: a value picked from a range.
    range: Range,
    /// `wait`, `runaway`, `attack`, `out_of_action_sphere`, `avoid`, `attack_medium_fighter`,
    /// `attack_massive`, `run_to_ship`, `end_script`: a number of ticks picked from a range, which
    /// the last three leave unset.
    ticks: Ticks,
    /// `set_afterburner`, `cloak`, `new_attack_run`.
    flag: Flag,
    /// `goto`, and `else`, which jumps to its `endif`.
    jump: Jump,
    /// `if`.
    branch: Branch,

    pub const Range = extern struct {
        opcode: Opcode,
        _pad: [3]u8,
        min: f32 align(1),
        max: f32 align(1),
    };

    pub const Ticks = extern struct {
        opcode: Opcode,
        _pad: u8,
        min: u16 align(1),
        max: u16 align(1),
    };

    pub const Flag = extern struct {
        opcode: Opcode,
        on: bool,
    };

    pub const Jump = extern struct {
        opcode: Opcode,
        /// The line to go on after: a `goto`'s label, an `else`'s `endif`.
        line: u8,
    };

    pub const Branch = extern struct {
        opcode: Opcode,
        condition: Condition,
        /// The line to go on after when the condition fails: the `if`'s `else` or `endif`.
        otherwise: u8,
    };

    comptime {
        assert(@alignOf(Instruction) == 1);
        assert(@offsetOf(Range, "min") == 4);
        assert(@offsetOf(Range, "max") == 8);
        assert(@sizeOf(Range) == 12);
        assert(@offsetOf(Ticks, "min") == 2);
        assert(@offsetOf(Ticks, "max") == 4);
        assert(@sizeOf(Ticks) == 6);
        assert(@offsetOf(Flag, "on") == 1);
        assert(@sizeOf(Flag) == 2);
        assert(@offsetOf(Jump, "line") == 1);
        assert(@sizeOf(Jump) == 2);
        assert(@offsetOf(Branch, "condition") == 1);
        assert(@offsetOf(Branch, "otherwise") == 2);
        assert(@sizeOf(Branch) == 3);
    }
};

/// The most lines a maneuver starts in one update.
///
/// **Fix:** a script loop with no command that waits would hang the game; OpenReliant starts at
/// most this many lines in one update. None of the game's scripts has one.
const most_lines = 256;

/// `maneuver_run` (`0x004069B0`): runs the Fight order's maneuver for an update. While no line
/// waits it starts the next, each command running at once until one waits; then it runs the
/// waiting one.
///
/// **Fix:** a script that runs off its end stops the game with a syntax error; OpenReliant ends the
/// maneuver there, so Fight chooses another.
///
/// **Fix:** a maneuver number past the table runs nothing, where the game reads past it.
pub fn run(fighter: Fighter) void {
    const number = @intFromEnum(fighter.state.maneuver);
    if (number < maneuvers.compiled.len) runScript(fighter, maneuvers.compiled[number]);
}

fn runScript(fighter: Fighter, program: []const script.Instruction) void {
    const state = fighter.state;
    if (state.afterburner) fighter.ship().afterburner = true;
    var started: usize = 0;
    while (!state.waiting) : (started += 1) {
        if (started == most_lines) return;
        state.line +%= 1;
        if (state.line >= program.len) return endManeuver(fighter);
        state.waiting = start(fighter, program[state.line]);
    }
    state.waiting = update(fighter, program[state.line]);
}

/// The start of an instruction (`maneuver_handlers`' first routines): true for one that waits.
/// Each arm ports the routine the table gives its opcode as it starts (`maneuvers.handlers`, named
/// `maneuver_<opcode>_start`), the timers of those that wait by `maneuver_start_timer`
/// (`startTimer`) and the jumps of `Goto` and `Else` by `maneuver_jump` (`0x00405B70`).
fn start(fighter: Fighter, instruction: script.Instruction) bool {
    const state = fighter.state;
    switch (instruction) {
        .set_yaw => |range| setInput(fighter, .yaw, range),
        .set_pitch => |range| setInput(fighter, .pitch, range),
        .set_roll => |range| setInput(fighter, .roll, range),
        .set_speed => |range| fighter.ship().throttle = math.lerp(range.min, range.max, fighter.random()),
        .wait, .attack, .avoid, .attack_medium_fighter => |ticks| {
            startTimer(fighter, ticks);
            return true;
        },
        .attack_massive => {
            // Its line holds no ticks; the game's compiler leaves the bytes zeroed.
            startTimer(fighter, .{ .min = 0, .max = 0 });
            return true;
        },
        .goto, .@"else" => |line| state.line = line,
        .label, .endif => {},
        .set_afterburner => |on| state.afterburner = on and fighter.pilot.turn_limit == afterburner_limit and fighter.playerWithin(afterburner_reach),
        .runaway => |ticks| {
            startTimer(fighter, ticks);
            const own = fighter.position();
            flyTo(fighter, own + math.normalize(own - fighter.enemyPosition()) * @as(Vector, @splat(runaway_reach)));
            return true;
        },
        .out_of_action_sphere => |ticks| {
            startTimer(fighter, ticks);
            flyTo(fighter, fighter.sphereCentre());
            return true;
        },
        .set_mirror => state.mirror = Mirror.all.pick(fighter.random15()),
        .@"if" => |branch| if (!(branch.condition == .going_to_crash and goingToCrash(fighter))) {
            state.line = branch.otherwise;
        },
        .cloak => |on| {
            state.cloak = on;
            state.cloak_at = fighter.now() + cloak_delay;
        },
        .new_attack_run => |clear| {
            startAttackRun(fighter);
            if (clear) fighter.ship().fighting = .none;
            return true;
        },
        .run_to_ship => {
            flyTo(fighter, friend(fighter).nextPosition());
            return true;
        },
        .end_script => return true,
    }
    return false;
}

/// Each update of an instruction that waits (`maneuver_handlers`' second routines): true while it
/// still waits. Each arm ports the routine the table gives its opcode while it waits
/// (`maneuvers.handlers`, named `maneuver_<opcode>_run`).
fn update(fighter: Fighter, instruction: script.Instruction) bool {
    return switch (instruction) {
        .wait => fighter.now() < fighter.state.timer,
        .runaway, .out_of_action_sphere => flyOn(fighter),
        .attack => attack(fighter),
        .attack_massive => attackMassive(fighter),
        .avoid => avoid(fighter),
        .attack_medium_fighter => attackMediumFighter(fighter),
        .new_attack_run => |far| attackRun(fighter, far),
        .run_to_ship => runToShip(fighter),
        .end_script => {
            endManeuver(fighter);
            return true;
        },
        .set_yaw, .set_pitch, .set_roll, .set_speed, .goto, .label, .set_afterburner, .set_mirror, .@"if", .@"else", .endif, .cloak => false,
    };
}

/// `maneuver_start_timer` (`0x00405B20`): the instruction's time is up a random share of its range
/// after its least.
fn startTimer(fighter: Fighter, ticks: script.Ticks) void {
    const spread: f32 = @floatFromInt(@as(i32, ticks.max) - ticks.min);
    fighter.state.timer = @as(i32, ticks.min) + fighter.now() + math.round(fighter.random() * spread);
}

/// `maneuver_end_script_run` (`0x004069A0`): ends the maneuver, its end the tick before, so Fight
/// chooses another.
fn endManeuver(fighter: Fighter) void {
    fighter.state.maneuver_end = fighter.now() - 1;
}

fn timeUp(fighter: Fighter) bool {
    return fighter.state.timer < fighter.now();
}

/// A turning input a script sets.
const Axis = enum {
    yaw,
    pitch,
    roll,

    /// The object's input for the axis (`yaw_input` and so on).
    fn input(axis: Axis, object: *gameobj.GameObject) *f32 {
        return switch (axis) {
            inline else => |named| &@field(object, @tagName(named) ++ "_input"),
        };
    }

    /// Whether the maneuver mirrors the axis.
    fn mirrored(axis: Axis, mirror: Mirror) bool {
        return switch (axis) {
            inline else => |named| @field(mirror, @tagName(named)),
        };
    }
};

/// `maneuver_set_yaw_start` (`0x00405960`), `maneuver_set_pitch_start` (`0x004059E0`) and
/// `maneuver_set_roll_start` (`0x00405A60`): the input a random share of the range, times the
/// pilot's turn limit, the other way about where the maneuver mirrors it.
///
/// The share is taken as `lerp` (`0x004C1050`) takes it, which the game writes out here and in
/// `maneuver_set_speed_start` (`0x00405AE0`): the range's span times the share, plus its least.
fn setInput(fighter: Fighter, axis: Axis, range: script.Range) void {
    const value = math.lerp(range.min, range.max, fighter.random()) * fighter.pilot.turn_limit;
    axis.input(fighter.ship()).* = if (axis.mirrored(fighter.state.mirror)) -value else value;
}

/// The point the ship flies to, straight at it again (`maneuver_stop_weaving`, `0x00405C50`).
fn flyTo(fighter: Fighter, point: Vector) void {
    fighter.state.point = gameobj.vec3(point);
    fighter.state.weaving = false;
}

/// `maneuver_fly_to_point` (`0x00405E60`): steers at the point until the time is up.
fn flyOn(fighter: Fighter) bool {
    if (timeUp(fighter)) return false;
    steerToPoint(fighter);
    return true;
}

/// `maneuver_steer_to_point` (`0x00405C60`): at full throttle at the point, and once it is within
/// `weave_start` of the nose, pitching at the pilot's full rate until it is past `weave_end`, so
/// the ship weaves. With anything on its avoidance lists, it steers at the point with neither the
/// pilot's limit nor its throttle, avoiding (`ai.steer`).
fn steerToPoint(fighter: Fighter) void {
    const state = fighter.state;
    const ship = fighter.ship();
    const point = gameobj.vector(state.point);
    if (ship.avoid_ahead.count >= 1 or ship.avoid_near.count != 0) {
        _ = ai.steer(fighter.ctx.world, fighter.index, point, ai.full_limit, ai.no_ease, .clear);
        return;
    }
    const off = math.cosineOff(point - fighter.position(), fighter.heading());
    ship.throttle = ai.full_throttle;
    if (state.weaving) {
        if (off < weave_end) state.weaving = false;
        ship.holdTurns();
        ship.pitch_input = fighter.pilot.turn_limit;
        return;
    }
    _ = ai.steer(fighter.ctx.world, fighter.index, point, fighter.pilot.turn_limit, ai.no_ease, .{ .avoid_near = true, .avoid_ahead = true, .pitch_up = true });
    if (off > weave_start) state.weaving = true;
}

/// `maneuver_attack_run` (`0x00405E80`): until the time is up, steers at the aim point at full
/// throttle. Close in, it matches the aim point's speed along its nose instead, and with the
/// target behind where the ship will be in `lookahead` updates, a pilot of the highest skill lights
/// the afterburner. The throttle stays at `least_throttle` or more.
fn attack(fighter: Fighter) bool {
    if (timeUp(fighter)) return false;
    const ship = fighter.ship();
    const apart = math.distance(fighter.position(), fighter.enemyPosition());
    fighter.steer(gameobj.vector(fighter.state.aim), .clear);
    const ahead = fighter.position() + gameobj.vector(ship.velocity) * @as(Vector, @splat(lookahead));
    const nose = math.forward(ship.root.orientation);
    if (math.dot(nose, fighter.enemyPosition() - ahead) >= 0) {
        ship.throttle = if (apart >= fighter.enemy().object.radius + ship.radius + close_in)
            ai.full_throttle
        else
            math.dot(nose, gameobj.vector(fighter.state.aim_velocity)) / fighter.cruise();
    } else if (fighter.pilot.skill() == .high) {
        ship.afterburner = true;
    } else {
        ship.throttle = ai.full_throttle;
    }
    ship.throttle = @max(ship.throttle, least_throttle);
    return true;
}

/// Whether the ship is within `reach_steps` of its cruise speed, both sizes aside, of the part of
/// the target it aims at.
fn closeToPart(fighter: Fighter) bool {
    const aimed = fighter.aimed();
    const reach = fighter.cruise() * reach_steps + fighter.ship().radius + aimed.radius;
    return math.lengthSquared(fighter.position() - aimed.position) < reach * reach;
}

/// `maneuver_attack_massive_run` (`0x00406030`): at full throttle at the aim point until it is
/// close to the part it aims at.
fn attackMassive(fighter: Fighter) bool {
    if (closeToPart(fighter)) return false;
    fighter.ship().throttle = ai.full_throttle;
    fighter.steer(gameobj.vector(fighter.state.aim), .clear);
    return true;
}

/// `maneuver_avoid_run` (`0x004062D0`): until the time is up, with the target ahead it pitches hard
/// away from it at half throttle; with it behind, it flies straight on at full throttle.
fn avoid(fighter: Fighter) bool {
    if (timeUp(fighter)) return false;
    const ship = fighter.ship();
    const local = ship.placeAt(.next).inverse(fighter.enemyPosition());
    ship.holdTurns();
    if (local[2] < 0) {
        ship.throttle = ai.full_throttle;
        return true;
    }
    ship.pitch_input = if (local[1] >= 0) 1 else -1;
    ship.throttle = half_throttle;
    return true;
}

/// `maneuver_attack_medium_fighter_run` (`0x00406400`): until the time is up, at full throttle
/// toward where the target will be, leading it by its velocity less a tenth of the ship's over the
/// time the ship takes to get there. At close quarters with the target off its nose by more than
/// `medium_cone`, straight on instead.
fn attackMediumFighter(fighter: Fighter) bool {
    if (timeUp(fighter)) return false;
    const ship = fighter.ship();
    ship.throttle = ai.full_throttle;
    const toward = fighter.enemyPosition() - fighter.position();
    const apart = math.length(toward);
    const direction = if (apart < aifight.close_quarters and math.dot(fighter.heading(), toward) < apart * medium_cone)
        fighter.heading()
    else lead: {
        const closing = gameobj.vector(fighter.enemy().object.velocity) - gameobj.vector(ship.velocity) * @as(Vector, @splat(own_share));
        break :lead math.normalize(closing * @as(Vector, @splat(apart / fighter.cruise())) + toward);
    };
    fighter.steer(fighter.position() + direction * @as(Vector, @splat(medium_reach)), .{ .avoid_near = true });
    return true;
}

/// `maneuver_new_attack_run_start` (`0x004065D0`): the way out, in the target's frame. For a
/// component of the target that its model gives a firing arc, the way out the arc names
/// (`shp.FiringArc.way_out`); for any other aim, the way out from the part of the target it aims
/// at that is clear of the target's hull (`ai.escapeDirection`).
fn startAttackRun(fighter: Fighter) void {
    const enemy = fighter.enemy();
    if (arcWayOut(enemy, fighter.target().part())) |way| {
        fighter.state.point = way;
        return;
    }
    const out = ai.escapeDirection(enemy, fighter.aimed().position);
    fighter.state.point = gameobj.vec3(math.transformTransposed(enemy.object.root.next_orientation, out));
}

/// The way out the firing arc of component `component` of the ship in `slot` names, where its
/// type's model gives the component one; the arcs follow the object's components, the model's own
/// first. Null for the whole ship.
fn arcWayOut(slot: *const create.Slot, component: ?u16) ?shp.Vec3 {
    const index = component orelse return null;
    const arcs = (slot.type orelse return null).model.firing_arcs;
    return if (index < arcs.len) arcs[index].way_out else null;
}

/// `maneuver_new_attack_run_run` (`0x00406680`): flies to a point out from the part it aims at,
/// along the way out as the part turns (`ai.Aimed.orientation`), `run_out` away, or twice the
/// target's radius for a larger one where `far`. It flies at full throttle on the afterburner
/// while that way lies along its course, at half throttle while it lies against it. Within
/// `run_done` of the point, the run is over and the ship is fighting the target again.
fn attackRun(fighter: Fighter, far: bool) bool {
    const ship = fighter.ship();
    const enemy = &fighter.enemy().object;
    const aimed = fighter.aimed();
    const out = math.transform(aimed.orientation, gameobj.vector(fighter.state.point));
    if (math.dot(out, gameobj.vector(ship.velocity)) >= 0) {
        ship.throttle = ai.full_throttle;
        ship.afterburner = true;
    } else {
        ship.throttle = half_throttle;
    }
    const reach = if (far and enemy.radius > run_out) enemy.radius * 2 else run_out;
    const staging = out * @as(Vector, @splat(reach)) + aimed.position;
    if (math.lengthSquared(staging - fighter.position()) < run_done * run_done) {
        // The game takes the target's index as a ship's slot, whatever its kind, as Fight's `init`
        // does.
        ship.fighting = .from(fighter.target().slot());
        return false;
    }
    fighter.steer(staging, .clear);
    return true;
}

/// `maneuver_run_to_ship_run` (`0x00406840`): flies to the friendly ship, its point following it.
/// By a ship with components it is done within `run_to_reach` of the ship's edge; by one without,
/// it matches the ship's speed along its own nose and closes by the distance past `run_to_reach`.
fn runToShip(fighter: Fighter) bool {
    const to = friend(fighter);
    fighter.state.point = to.root.next_position;
    steerToPoint(fighter);
    const apart = math.distance(to.nextPosition(), fighter.position());
    if (to.flags.components) return apart >= to.radius + run_to_reach;
    const ship = fighter.ship();
    const pace = math.dot(fighter.heading(), gameobj.vector(to.velocity)) / fighter.cruise();
    ship.throttle = @max(pace + (apart - run_to_reach) * run_to_closing, least_throttle);
    return true;
}

/// The friendly ship `RunToShip` flies to.
fn friend(fighter: Fighter) *gameobj.GameObject {
    return &fighter.objects().slots[fighter.state.ship].object;
}

/// `If Goingtocrash` (`maneuver_if_start`, `0x00406170`): against a target without components, on
/// course to hit it within `crash_steps` with the berth the pilot's skill gives (`crashBerth`,
/// `ai.collisionCourse`); against one with components, close to the part it aims at.
fn goingToCrash(fighter: Fighter) bool {
    if (fighter.enemy().object.flags.components) return closeToPart(fighter);
    const berth = crashBerth(fighter.pilot.skill()) orelse return false;
    return ai.collisionCourse(fighter.ctx.world, fighter.index, fighter.against.slot, crash_steps, berth);
}

/// The berth `If Goingtocrash` keeps from a target by the pilot's skill, which `maneuver_if_start`
/// holds in its code; none for a pilot of any other skill, which never crashes.
fn crashBerth(skill: pilots.Pilot.Skill) ?f32 {
    return switch (skill) {
        .low => 5000,
        .medium => 3500,
        .high => 2000,
        .other => null,
    };
}

/// `SetAfterburner(on)` lights the afterburner only for a pilot whose turn limit is this
/// (`0x004DC480`), and only with a player's ship within `afterburner_reach` (`0x004DC47C`, its
/// square). No pilot preset's limit is above 1, so as the game ships it never lights.
const afterburner_limit: f32 = 2;
const afterburner_reach: f32 = 50000;
/// How far away `Runaway` flies, and how long after `Cloak` it cloaks (`maneuver_runaway_start`,
/// `0x00405E23`; `maneuver_cloak_start`, `0x004063EF`).
const runaway_reach: f32 = 1000000;
const cloak_delay = 500;
/// The cosines of the angles off the nose at which a ship flying to a point starts weaving
/// (`0x004DC470`) and steers at the point again (`0x004DC484`).
const weave_start: f32 = 0.9;
const weave_end: f32 = 0.7;
/// The throttle `Avoid` pitches away at, and `NewAttackRun` flies at with the way out against its
/// course (`maneuver_avoid_run`, `0x004063C1`; `maneuver_new_attack_run_run`, `0x00406702`).
const half_throttle: f32 = 0.5;
/// `Attack`'s look ahead, in updates of the ship's velocity (`maneuver_attack_run`,
/// `0x00405EFD`); how close in, both sizes aside, it matches the aim point's speed
/// (`0x004DC488`); and the least throttle it or `RunToShip` holds (`0x004DC408`).
const lookahead: f32 = 20;
const close_in: f32 = 12000;
const least_throttle: f32 = 0.5;
/// How many updates of cruise speed count as close to a part (`0x004DC48C`).
const reach_steps: f32 = 50;
/// `AttackMediumFighter`: the cosine of the cone off the nose the target must be within at close
/// quarters (`aifight.close_quarters`, `0x004DC414`), and the share of the ship's own velocity the
/// lead takes off and how far out it steers at (`maneuver_attack_medium_fighter_run`:
/// `0x00406518`, which pushes the share as -0.1, and `0x004064CF` and `0x00406576`).
const medium_cone: f32 = 0.95;
const own_share: f32 = 0.1;
const medium_reach: f32 = 20000;
/// `NewAttackRun`: how far out it stages (`0x004DC494`), and how close to that point it is done
/// (`0x004DC490`, its square).
const run_out: f32 = 50000;
const run_done: f32 = 2000;
/// `RunToShip`: how close to the ship's edge it is done (`0x004DC46C`), and how much throttle each
/// unit past that adds (`0x004DC498`).
const run_to_reach: f32 = 5000;
const run_to_closing: f32 = 0.0002;
/// `If Goingtocrash`: how many updates ahead a crash is looked for (`maneuver_if_start`,
/// `0x00406256`).
const crash_steps: f32 = 100;

test {
    std.testing.refAllDecls(@This());
}

test Mirror {
    try std.testing.expectEqual(Mirror{ .yaw = true, .roll = true }, Mirror.all.pick(0b101));
    // Only what the maneuver allows is mirrored, whatever the number.
    try std.testing.expectEqual(Mirror{ .pitch = true }, (Mirror{ .pitch = true }).pick(0x7FFF));
    try std.testing.expectEqual(Mirror{}, Mirror.all.pick(0b1000));
}

test run {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const state = fighter.state;
    const ship = fighter.ship();
    state.maneuver = .loop_the_loop;
    state.line = aifight.FightState.before_first;
    state.mirror = .{ .pitch = true };

    // Every line up to the first that waits runs at once: the loop's pitch, mirrored, at the
    // pilot's limit, and half throttle. Then it waits on its Wait, the eighth line.
    run(fighter);
    try std.testing.expectEqual(-fighter.pilot.turn_limit, ship.pitch_input);
    try std.testing.expectEqual(0, ship.yaw_input);
    try std.testing.expectEqual(0.5, ship.throttle);
    try std.testing.expect(state.cloak);
    try std.testing.expect(state.waiting);
    try std.testing.expectEqual(7, state.line);
    try std.testing.expectEqual(1000, state.timer);

    // Once the time is up it stops waiting; the next update goes round the loop to the Wait again.
    mission.clock.frame_start = state.timer;
    run(fighter);
    try std.testing.expect(!state.waiting);
    run(fighter);
    try std.testing.expect(state.waiting);
    try std.testing.expectEqual(7, state.line);
    try std.testing.expectEqual(2000, state.timer);
}

test "a script that ends or never waits" {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const state = fighter.state;
    mission.clock.frame_start = 100;

    // Running off the end of a script ends the maneuver.
    state.line = aifight.FightState.before_first;
    runScript(fighter, &comptime script.compile(&.{"SetSpeed(1)"}));
    try std.testing.expectEqual(1, fighter.ship().throttle);
    try std.testing.expectEqual(99, state.maneuver_end);

    // A loop with nothing in it that waits is given up on rather than run for ever.
    state.line = aifight.FightState.before_first;
    runScript(fighter, &comptime script.compile(&.{ "loop:", "Goto loop" }));
    try std.testing.expect(!state.waiting);
}

test steerToPoint {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const state = fighter.state;
    const ship = fighter.ship();

    // A point dead ahead: full throttle, and it starts weaving.
    flyTo(fighter, .{ 0, 0, 200000 });
    steerToPoint(fighter);
    try std.testing.expectEqual(1, ship.throttle);
    try std.testing.expect(state.weaving);
    // Weaving, it pitches at the pilot's full rate and nothing else.
    steerToPoint(fighter);
    try std.testing.expectEqual(fighter.pilot.turn_limit, ship.pitch_input);
    try std.testing.expectEqual(0, ship.yaw_input);
    // With the point well off its nose, it stops weaving.
    state.point = .{ .x = 100000, .y = 0, .z = 50000 };
    steerToPoint(fighter);
    try std.testing.expect(!state.weaving);
}

test avoid {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const ship = fighter.ship();
    fighter.state.timer = 10;

    // The player is behind the Sabre, which faces away from it: it flies straight on.
    try std.testing.expect(avoid(fighter));
    try std.testing.expectEqual(ai.full_throttle, ship.throttle);
    try std.testing.expectEqual(0, ship.pitch_input);
    // Turned about to face the player, it pitches hard away at half throttle.
    ship.root.next_orientation = math.rotation(.y, std.math.pi);
    try std.testing.expect(avoid(fighter));
    try std.testing.expectEqual(half_throttle, ship.throttle);
    try std.testing.expectEqual(1, ship.pitch_input);
    // Its time up, it is done.
    mission.clock.frame_start = 11;
    try std.testing.expect(!avoid(fighter));
}

test attack {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const ship = fighter.ship();
    fighter.state.timer = 10;

    // Turned about to face the player, far off: full throttle at the aim point.
    objects.setOrientation(ship, &fighter.slot.drawn, math.rotation(.y, std.math.pi));
    try std.testing.expect(attack(fighter));
    try std.testing.expectEqual(ai.full_throttle, ship.throttle);
    // Close in, it matches the aim point's speed along its nose, here none, and holds the least
    // throttle.
    objects.setPosition(ship, &fighter.slot.drawn, .{ 0, 0, 5000 });
    try std.testing.expect(attack(fighter));
    try std.testing.expectEqual(least_throttle, ship.throttle);
    // Its time up, it is done.
    mission.clock.frame_start = 11;
    try std.testing.expect(!attack(fighter));
}

test attackMassive {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);

    // Far from the part it aims at, it closes at full throttle; within fifty updates of its cruise
    // speed of it, it is done.
    try std.testing.expect(attackMassive(fighter));
    try std.testing.expectEqual(ai.full_throttle, fighter.ship().throttle);
    objects.setPosition(fighter.ship(), &fighter.slot.drawn, .{ 0, 0, 10000 });
    try std.testing.expect(!attackMassive(fighter));
}

test attackMediumFighter {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 5000);
    const ship = fighter.ship();
    fighter.state.timer = 10;

    // At close quarters, with the player off its nose, it flies straight on at full throttle.
    try std.testing.expect(attackMediumFighter(fighter));
    try std.testing.expectEqual(ai.full_throttle, ship.throttle);
    try std.testing.expectEqual(0, ship.yaw_input);
    // Farther off, it turns to lead the player, behind it.
    objects.setPosition(ship, &fighter.slot.drawn, .{ 0, 0, 50000 });
    try std.testing.expect(attackMediumFighter(fighter));
    try std.testing.expect(ship.yaw_input != 0);
    // Its time up, it is done.
    mission.clock.frame_start = 11;
    try std.testing.expect(!attackMediumFighter(fighter));
}

test attackRun {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 5000);
    const ship = fighter.ship();
    // The way out is along the player's nose, the player standing at the origin facing along Z.
    fighter.state.point = .{ .x = 0, .y = 0, .z = 1 };

    // Still, it burns at full throttle for the point `run_out` out along it.
    try std.testing.expect(attackRun(fighter, false));
    try std.testing.expectEqual(ai.full_throttle, ship.throttle);
    try std.testing.expect(ship.afterburner);
    // Flying against the way out, at half throttle.
    ship.velocity = .{ .x = 0, .y = 0, .z = -10 };
    ship.afterburner = false;
    try std.testing.expect(attackRun(fighter, false));
    try std.testing.expectEqual(half_throttle, ship.throttle);
    try std.testing.expect(!ship.afterburner);
    // At the point the run is over, and the ship fights the player again.
    objects.setPosition(ship, &fighter.slot.drawn, .{ 0, 0, run_out });
    try std.testing.expect(!attackRun(fighter, false));
    try std.testing.expectEqual(0, ship.fighting.index());
}

test runToShip {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 5000);
    const ship = fighter.ship();
    const other = try mission.add(.sabre, .{ 0, 0, 25000 });
    const to = mission.slot(other);
    fighter.state.ship = other;

    // Far from a ship without components, it closes by how far it is past `run_to_reach`, the
    // ship standing still.
    try std.testing.expect(runToShip(fighter));
    try std.testing.expectApproxEqAbs((20000 - run_to_reach) * run_to_closing, ship.throttle, 1e-5);
    // Near it, at the least throttle.
    objects.setPosition(&to.object, &to.drawn, .{ 0, 0, 6000 });
    try std.testing.expect(runToShip(fighter));
    try std.testing.expectEqual(least_throttle, ship.throttle);
    // By a ship with components, it is done within `run_to_reach` of its edge.
    to.object.flags.components = true;
    try std.testing.expect(!runToShip(fighter));
}

test goingToCrash {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 5000);
    const ship = fighter.ship();

    // Facing away from the player, it is on course to hit nothing; turned about and flying at the
    // player, it is, within its pilot's berth.
    try std.testing.expect(!goingToCrash(fighter));
    objects.setOrientation(ship, &fighter.slot.drawn, math.rotation(.y, std.math.pi));
    ship.velocity = .{ .x = 0, .y = 0, .z = -50 };
    try std.testing.expect(goingToCrash(fighter));
    // Against a target with components, it is once close to the part it aims at, whatever its
    // course.
    objects.setOrientation(ship, &fighter.slot.drawn, math.identity);
    ship.velocity = .zero;
    fighter.enemy().object.flags.components = true;
    try std.testing.expect(goingToCrash(fighter));
    // A pilot of a skill the game has no berth for never crashes.
    try std.testing.expectEqual(null, crashBerth(.other));
    try std.testing.expectEqual(2000, crashBerth(.high));
}

test arcWayOut {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    var hull: create.testing.Model = undefined;
    try hull.init(gpa);
    defer hull.deinit(gpa);
    var arcs = [_]shp.FiringArc{std.mem.zeroes(shp.FiringArc)};
    arcs[0].way_out = .{ .x = 0, .y = -1, .z = 0 };
    hull.source.firing_arcs = &arcs;
    const index = try mission.addWith(hull.types(), .reaper, @splat(0));
    const slot = mission.slot(index);

    // A component the model gives an arc pulls out the way the arc names; the whole ship, or a
    // component past the arcs, has none.
    try std.testing.expectEqual(arcs[0].way_out, arcWayOut(slot, 0).?);
    try std.testing.expectEqual(null, arcWayOut(slot, null));
    try std.testing.expectEqual(null, arcWayOut(slot, 1));
}

test start {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    const state = fighter.state;
    const ship = fighter.ship();

    // Not on course to hit the player, the If goes on after its Endif, and the Wait there waits.
    state.line = aifight.FightState.before_first;
    runScript(fighter, &comptime script.compile(&.{ "If Goingtocrash", "Avoid(300)", "Endif", "Wait(10)" }));
    try std.testing.expect(state.waiting);
    try std.testing.expectEqual(3, state.line);

    // Runaway flies straight for the point `runaway_reach` out, away from the player, weaving no
    // more.
    state.weaving = true;
    try std.testing.expect(start(fighter, .{ .runaway = .{ .min = 10, .max = 10 } }));
    try std.testing.expect(!state.weaving);
    try std.testing.expectEqual(gameobj.vec3(.{ 0, 0, 50000 + runaway_reach }), state.point);
    try std.testing.expectEqual(10, state.timer);

    // NewAttackRun, told to, has the ship fight nothing until the run is over; otherwise it keeps
    // its target.
    ship.fighting = .of(0);
    try std.testing.expect(start(fighter, .{ .new_attack_run = false }));
    try std.testing.expectEqual(gameobj.Slot.of(0), ship.fighting);
    try std.testing.expect(start(fighter, .{ .new_attack_run = true }));
    try std.testing.expectEqual(gameobj.Slot.none, ship.fighting);
}

test startAttackRun {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const fighter = try aifight.testing.fighter(&mission, 50000);
    var hull: create.testing.Model = undefined;
    try hull.init(gpa);
    defer hull.deinit(gpa);
    hull.withHull();
    var arcs = [_]shp.FiringArc{std.mem.zeroes(shp.FiringArc)};
    arcs[0].way_out = .{ .x = 0, .y = -1, .z = 0 };
    hull.source.firing_arcs = &arcs;
    // The target is turned a quarter about Y, the box of its hull 5000 behind it.
    hull.nodes[0].centre = .{ .x = 0, .y = 0, .z = -5000 };
    const target = try mission.addWith(hull.types(), .reaper, .{ 0, 0, 100000 });
    const slot = mission.slot(target);
    objects.setOrientation(&slot.object, &slot.drawn, math.rotation(.y, std.math.pi / 2.0));
    slot.model.?.place(slot.drawn.position, slot.drawn.orientation);

    // At a component its model gives a firing arc, the way out the arc names.
    fighter.slot.orders[0].target = .at(target, 0);
    startAttackRun(aifight.Fighter.unchecked(fighter.ctx, fighter.index).?);
    try std.testing.expectEqual(arcs[0].way_out, fighter.state.point);
    // At the whole ship, the way clear of its hull, in its own frame: ahead, away from the box
    // behind it, however it is turned.
    fighter.slot.orders[0].target = .at(target, null);
    startAttackRun(aifight.Fighter.unchecked(fighter.ctx, fighter.index).?);
    try std.testing.expectApproxEqAbs(0, fighter.state.point.x, 1e-5);
    try std.testing.expectApproxEqAbs(0, fighter.state.point.y, 1e-5);
    try std.testing.expectApproxEqAbs(1, fighter.state.point.z, 1e-5);
}
