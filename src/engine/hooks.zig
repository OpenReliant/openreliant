//! What mods' scripts can hook ([#498](https://github.com/OpenReliant/openreliant/issues/498)): the
//! original game's functions, under the names `ghidra/names/LANCER.EXE.tsv` gives them,
//! OpenReliant's own functions, the events of the missions, and the engine's own events. The engine
//! declares the hooks here and calls them where they happen. The scripting module runs the handlers
//! that mods add (`src/scripting`), through `Scripts`.
//!
//! A hookable function starts with one line, which only checks a flag while no script hooks it:
//!
//! ```zig
//! if (hooks.enter(.object_damage, damage, .{ world, index, struck, value, factor, attacker, kind })) |done| return done;
//! ```
//!
//! What a hook's handlers see in `e` is its `Fields`. A function's fields are its parameters after
//! the first (the world, the context the orders run in, or the mission's script), in order. A field whose name starts
//! with `_` passes its parameter through without scripts seeing it. The names of the hooks and of
//! their fields are part of the scripting API: they stay the same when OpenReliant's code changes,
//! and the definitions file the scripting module generates from them pins them.
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../formats/dte.zig");
const vm = @import("vm.zig");
const ai = @import("game/ai.zig");
const aigeneric = @import("game/aigeneric.zig");
const collision = @import("game/collision.zig");
const create = @import("game/create.zig");
const executor = @import("game/executor.zig");
const gameobj = @import("game/gameobj.zig");
const guns = @import("game/guns.zig");
const main = @import("game/main.zig");
const objects = @import("game/objects.zig");
const gameflow = @import("game/gameflow.zig");
const radio = @import("game/radio.zig");
const restart = @import("game/interface/restart.zig");
const movie = @import("game/xtrabits/movie.zig");
const orders = ai.orders;
const routines = ai.routines;

/// An object, by its slot, as a hook passes it. Scripts see it as an object handle.
pub const Object = enum(u16) {
    _,

    pub fn of(index: u16) Object {
        return @fromBackingInt(index);
    }

    pub fn slot(object: Object) u16 {
        return @backingInt(object);
    }
};

/// A missile in flight, by its record in `missiles.Missiles`, as a hook passes it. Scripts see it as
/// a missile handle.
pub const Missile = enum(u8) {
    _,

    pub fn of(index: u8) Missile {
        return @fromBackingInt(index);
    }

    pub fn record(missile: Missile) u8 {
        return @backingInt(missile);
    }
};

/// A turret: one of an object's guns that turns to aim, spins its barrels or launches missiles, by
/// the object and the gun's place among its guns (`create.Slot.guns`). Scripts see it as a turret
/// handle.
pub const Turret = struct {
    object: Object,
    gun: u16,
};

/// What an order or a missile is aimed at, as a hook passes it: a ship of the mission, whole or one
/// of its components, one of the mission's flight groups or squads, by its index, or nothing.
/// Scripts see it as a table, each field nil where it doesn't apply; a handler that sets more than
/// one aims at the first of `object`, `flight_group` and `squad`.
pub const Target = struct {
    /// The ship aimed at.
    object: ?Object = null,
    /// The ship's component aimed at; nil for the whole ship.
    component: ?u16 = null,
    flight_group: ?u16 = null,
    squad: ?u16 = null,
    /// The target as the game holds it, which `aimed` gives back while the fields still say the
    /// same, so that a kind the scripts can't name goes through unchanged.
    _held: aigeneric.Target = .none,

    pub fn of(held: aigeneric.Target) Target {
        var target: Target = .{ ._held = held };
        const index = std.math.cast(u16, held.index) orelse return target;
        switch (held.kind) {
            .ship => {
                target.object = .of(index);
                target.component = held.part();
            },
            .flight_group => target.flight_group = index,
            .squad => target.squad = index,
            _ => {},
        }
        return target;
    }

    /// The target as the game holds it.
    pub fn aimed(target: Target) aigeneric.Target {
        const unchanged = of(target._held);
        if (std.meta.eql(unchanged, target)) return target._held;
        if (target.object) |object| return .at(object.slot(), target.component);
        if (target.flight_group) |index| return .group(.flight_group, index);
        if (target.squad) |index| return .group(.squad, index);
        return .none;
    }
};

/// What a hook is on.
pub const On = enum {
    /// A function of the original game, which handlers can change, wrap or replace.
    function,
    /// A function of OpenReliant's own: a step that the original takes inside a larger function.
    /// Handlers change it as they change the game's functions.
    engine_function,
    /// An event of the mission, one its triggers can wait for (`dte.Condition`).
    mission_event,
    /// An event of the engine.
    engine_event,

    /// Whether handlers can change its fields and its result, and run it (`e:original()`), as they
    /// can a function's.
    pub fn isFunction(on: On) bool {
        return switch (on) {
            .function, .engine_function => true,
            .mission_event, .engine_event => false,
        };
    }
};

/// A hook, as the engine declares it.
pub const Declaration = struct {
    /// What it's on, which the list it's declared in gives (`declaration`).
    on: On = .function,
    /// The function's address in the original, for a hook on one of the original's functions.
    address: ?u32 = null,
    /// What its handlers see in `e`.
    Fields: type,
    /// What the function returns, which handlers see as `e.result`; `void` for none, and for an
    /// event.
    Result: type = void,
    /// The field that holds the object it concerns, which handlers' filters test; null for none.
    subject: ?[]const u8 = "object",
    /// What it is, in a sentence or two, for the reference.
    about: []const u8,
};

/// The hooks on the original's functions, under the names `ghidra/names/LANCER.EXE.tsv` gives
/// them. The order table's routines have hooks of their own (`routine_hooks`), which cover what
/// ships do through their orders: launching, landing, docking, jumps, gates and explosions.
pub const functions = struct {
    pub const object_damage: Declaration = .{
        .address = 0x00463EE0,
        .about = "Damage to `object` from `attacker`. Its shield in `quadrant` takes `value` first. What gets through, times `factor`, damages its armour (`object_armor_damage`). `kind` says what dealt the damage.",
        .Fields = struct {
            object: Object,
            quadrant: collision.Quadrant,
            value: f32,
            factor: f32,
            attacker: Object,
            kind: collision.Kind,
        },
    };

    pub const object_armor_damage: Declaration = .{
        .address = 0x004641F0,
        .about = "Damage to the armour of `object` in `quadrant`, once its shield there is down: `value` from `attacker`, of `kind`. Armour below zero destroys the object (`object_destroyed`).",
        .Fields = struct {
            object: Object,
            quadrant: collision.Quadrant,
            value: f32,
            attacker: Object,
            kind: collision.Kind,
        },
    };

    pub const component_damage: Declaration = .{
        .address = 0x004645C0,
        .about = "Damage to one of the components of `object`, such as a capital ship's turret or engine: `value` from `attacker`, of `kind`.",
        .Fields = struct {
            object: Object,
            _part: objects.PartRef,
            value: f32,
            attacker: Object,
            kind: collision.Kind,
        },
    };

    pub const damage_by_difficulty: Declaration = .{
        .address = 0x00463D70,
        .about = "How hard damage of `kind` lands on `object` at the game's difficulty: the result is what `value` becomes.",
        .Fields = struct {
            object: Object,
            kind: collision.Kind,
            value: f32,
        },
        .Result = f32,
    };

    pub const object_destroyed: Declaration = .{
        .address = 0x00401F30,
        .about = "The end of `object`: its pilot ejects, or it explodes. With `may_spin`, it may spin out as it goes; with `no_eject`, the player's pilot doesn't eject.",
        .Fields = struct {
            object: Object,
            may_spin: bool,
            no_eject: bool,
        },
    };

    pub const bullet_fire: Declaration = .{
        .address = 0x0047C5F0,
        .about = "`owner` fires a shot of `gun_type` from one of its guns. `heard` says whether the shot makes a sound.",
        .Fields = struct {
            owner: Object,
            _muzzle: guns.Muzzle,
            gun_type: guns.GunType,
            heard: bool,
        },
        .subject = "owner",
    };

    pub const radio_say: Declaration = .{
        .address = 0x004562D0,
        .about = "The radio says a line: the speech file `speech`, its speaker's face playing the film `film`, as `mode` has it, at once (`now`), queued, or queued unless the radio is busy (`if_idle`). A handler can change the names, to say another line, or stop it, so that nothing is said and what waits for it goes on.",
        .Fields = struct {
            _radio: *radio.Radio,
            speech: radio.LineName,
            film: radio.LineName,
            _line: radio.Line,
            mode: radio.Mode,
        },
        .subject = null,
    };

    pub const missile_launch: Declaration = .{
        .address = 0x00496290,
        .about = "`launcher` launches a missile from one of its racks at `target`.",
        .Fields = struct {
            launcher: Object,
            _rack: usize,
            target: Target,
        },
        .subject = "launcher",
    };

    pub const missile_launch_turret: Declaration = .{
        .address = 0x004967F0,
        .about = "One of the missile turrets of `object` launches a Screamer at `target`.",
        .Fields = struct {
            object: Object,
            _model: *const objects.Model,
            _launcher: usize,
            target: Target,
        },
    };

    pub const order_push: Declaration = .{
        .address = 0x0040CC10,
        .about = "`object` is given `order`, aimed at `target`, on top of its orders. The result says whether it took: `\"taken\"`, `\"refused\"` where the object refuses it, the order it runs doesn't give way or it has too many, or `\"conflict\"` where the order it runs can't give way. A handler that stops the push leaves `\"refused\"`.",
        .Fields = struct {
            object: Object,
            order: orders.Order,
            target: Target,
        },
        .Result = aigeneric.Pushed,
    };

    pub const order_pop: Declaration = .{
        .address = 0x0040CE70,
        .about = "`object` ends the order it runs, which its exit runs for where it has started, and the order below starts again. The result says whether it had one.",
        .Fields = struct {
            object: Object,
        },
        .Result = bool,
    };

    pub const object_orders: Declaration = .{
        .address = 0x0040C5F0,
        .about = "`object` runs its current order, as it does each frame. Each order's routines have hooks of their own, such as `order_fight`.",
        .Fields = struct {
            object: Object,
        },
    };

    pub const vm_command: Declaration = .{
        .address = 0x0045BEA0,
        .about = "The mission's script runs one of its commands, `command`, on `arguments`: as many as the command takes, the first first, and 0 past them. They're the script's own values: numbers, and the places of the mission's ships and texts in its file. To change them, set `e.arguments` to a new list. The result is what the command gives: `\"run_on\"` lets the script's thread go on, `\"wait\"` ends its run until it runs next, and a number is the command's value, which lets it go on too. A handler that stops the command leaves `\"run_on\"`.",
        .Fields = struct {
            _thread: u8,
            command: executor.MissionCommand,
            arguments: executor.Arguments,
        },
        .Result = vm.machine.CommandResult,
        .subject = null,
    };

    pub const restart_screen: Declaration = .{
        .address = 0x0043EB80,
        .about = "The restart screen, after a mission is lost or left. Its result is the player's choice: `replay_from_briefing`, `replay_from_launch` or `main_menu`. A handler that stops it chooses without the screen: `main_menu`, unless it sets `e.result`.",
        .Fields = struct { _shown: restart.Shown },
        .Result = restart.Choice,
        .subject = null,
    };

    pub const order_retaliate: Declaration = .{
        .address = 0x0040C520,
        .about = "`object`, a fighter, turns on whoever last hit it, once it has taken enough damage lately and its order allows it.",
        .Fields = struct {
            object: Object,
        },
    };
};

/// OpenReliant's own functions: steps that the original takes inside a larger function, which
/// OpenReliant makes functions of so that scripts can hook them. Those that choose a movie take the
/// one the game plays, which a handler can change to the name of another Bink file, the game's or a
/// mod's, or to nil for none. A handler that stops the call plays none.
pub const engine_functions = struct {
    pub const mission_lost: Declaration = .{
        .about = "A mission is lost or left, and `movie` plays before the restart screen. In the game's campaign, it is the pilot's funeral where `ending` is `destroyed`, the pilot in the enemy's hands where it is `captured`, the pilot's execution where it is `friendly_fire`, and none where the player left the mission. A game mode's mission plays none. `rating` is how the mission's script rated it, and `mission` is its number.",
        .Fields = struct {
            ending: main.Ending,
            rating: vm.Variables.Outcome,
            mission: u16,
            movie: ?movie.Name,
        },
        .Result = ?movie.Name,
        .subject = null,
    };

    pub const career_over: Declaration = .{
        .about = "The pilot's career in the game's campaign ends after mission `mission`, and `movie` plays before the main menu: the pilot's transfer where `ending` is `rescued`, after too many pickups, and for a total failure (`ending` `total_failure`) the transfer or, after missions 25 and 27 without the Yamato, the shuttle at Fort Bear. `rating` is how the mission's script rated it.",
        .Fields = struct {
            ending: main.Ending,
            rating: vm.Variables.Outcome,
            mission: u16,
            movie: ?movie.Name,
        },
        .Result = ?movie.Name,
        .subject = null,
    };

    pub const medal_ceremony: Declaration = .{
        .about = "Mission `mission` of the game's campaign awards the pilot `medal`, and `movie`, the medal's ceremony, plays.",
        .Fields = struct {
            medal: gameflow.Medal,
            mission: u16,
            movie: ?movie.Name,
        },
        .Result = ?movie.Name,
        .subject = null,
    };
};

/// What a hook on one of the order table's routines sees.
pub const RoutineFields = struct {
    /// The object that runs the order.
    object: Object,
    /// The order's record, which picks the routine.
    _info: orders.Info,
};

/// A routine of the order table that can be hooked.
pub const Routine = struct {
    name: []const u8,
    address: u32,
    role: routines.Role,
    /// The first order that uses it.
    order: orders.Order,
};

/// The routines `ghidra/names/LANCER.EXE.tsv` names itself, whose hooks take those names: the
/// player's controls, which its assertion names, and the first step that three orders share.
const hand_named_routines = [_]struct { address: u32, name: []const u8 }{
    .{ .address = 0x00413410, .name = "player_controls" },
    .{ .address = 0x0040B1C0, .name = "order_first_step_init" },
};

/// The order table's routines that can be hooked: each one OpenReliant names (`routines.named`), or
/// the names table names itself (`hand_named_routines`), under that name.
pub const routine_hooks: []const Routine = list: {
    @setEvalBranchQuota(orders.table.len * orders.table.len * 400);
    var list: []const Routine = &.{};
    for (routines.named) |named| {
        const name = for (hand_named_routines) |hand| {
            if (hand.address == named.address) break hand.name;
        } else named.name;
        list = list ++ .{Routine{ .name = name, .address = named.address, .role = named.role, .order = named.order }};
    }
    for (hand_named_routines) |hand| {
        if (routines.find(hand.address) != null) continue;
        const first: Routine = found: for (orders.table) |entry| {
            for (std.enums.values(routines.Role)) |role| {
                if (routines.address(entry, role) == hand.address) break :found .{ .name = hand.name, .address = hand.address, .role = role, .order = entry.order };
            }
        } else @compileError("no order uses the routine " ++ hand.name);
        list = list ++ .{first};
    }
    break :list list;
};

/// What a routine's hook is, for the reference: its role, and the orders that use it.
fn routineAbout(comptime routine: Routine) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var text: []const u8 = "The " ++ @tagName(routine.role) ++ " of order";
        var count = 0;
        for (orders.table) |entry| {
            if (routines.address(entry, routine.role) != routine.address) continue;
            const named = if (entry.name.len > 0) ", " ++ entry.name else "";
            text = text ++ (if (count == 0) " " else ", and of order ") ++ std.fmt.comptimePrint("{d}", .{@backingInt(entry.order)}) ++ named;
            count += 1;
        }
        return text ++ ", which `object` runs.";
    }
}

/// The mission's events, under the names of their conditions (`dte.Condition`). Each comes for the
/// mission's ships, those its file lists, as the game posts it for their triggers, whether or not a
/// trigger waits for it.
pub const mission_events = struct {
    pub const shot_at: Declaration = .{
        .about = "`attacker` hits `object`: its component number `component`, or the object as a whole when `component` is nil.",
        .Fields = struct { object: Object, attacker: Object, component: ?u8 },
    };

    pub const destroyed: Declaration = .{
        .about = "`object` is destroyed, or its component number `component`. `attacker` is what last hit it. Each ship is destroyed once, though its components can be destroyed before it.",
        .Fields = struct { object: Object, component: ?u8, attacker: ?Object },
    };

    pub const launched: Declaration = .{
        .about = "`object` has launched from its carrier.",
        .Fields = struct { object: Object },
    };

    pub const ship_reached: Declaration = .{
        .about = "`reached_by` has reached the mission's ship `ship`, a point on a curve it follows or the curve's end.",
        .Fields = struct { ship: u16, reached_by: Object },
        .subject = "reached_by",
    };

    pub const camera_reached: Declaration = .{
        .about = "The director's camera has reached the mission's ship `ship`, a point on its curve or the curve's end.",
        .Fields = struct { ship: u16 },
        .subject = null,
    };

    pub const proximity_close: Declaration = .{
        .about = "`other` stands close to `object`, within 20 times its radius: `distance` times it. The game looks once a second, and only while one of `object`'s triggers waits for it.",
        .Fields = struct { object: Object, other: Object, distance: f32 },
    };

    pub const proximity_general: Declaration = .{
        .about = "`other` stands within the distance that one of `object`'s triggers names, counted in `object`'s radius: `distance` times it. The game looks once a second, and only while such a trigger waits for it.",
        .Fields = struct { object: Object, other: Object, distance: f32 },
    };

    pub const object_scooped: Declaration = .{
        .about = "`object` has taken `scooped` aboard with its tractor beam.",
        .Fields = struct { object: Object, scooped: Object },
    };

    pub const player_ready_to_jump: Declaration = .{
        .about = "JUMP DRIVE took the jump the mission had ready for `object`, the player's ship.",
        .Fields = struct { object: Object },
    };

    pub const jumped_in: Declaration = .{
        .about = "`object` has jumped in.",
        .Fields = struct { object: Object },
    };

    pub const fixed_gate_jumped_in: Declaration = .{
        .about = "`object` has come in through the fixed gate `gate`.",
        .Fields = struct { object: Object, gate: Object },
    };

    pub const player_ready_to_warp: Declaration = .{
        .about = "JUMP DRIVE took the warp the mission had ready for `object`, the player's ship.",
        .Fields = struct { object: Object },
    };

    pub const player_wants_backup: Declaration = .{
        .about = "REQUEST BACKUP brought the mission's backup for `object`, the player's ship.",
        .Fields = struct { object: Object },
    };

    pub const ripper_grabbed_object: Declaration = .{
        .about = "`object`, a Ripper, has `grabbed` aboard.",
        .Fields = struct { object: Object, grabbed: Object },
    };

    pub const ripper_dropped_object: Declaration = .{
        .about = "`object`, a Ripper, has let go of `dropped`, or fitted it to a ship.",
        .Fields = struct { object: Object, dropped: Object },
    };

    pub const cloaked: Declaration = .{
        .about = "`object` cloaks.",
        .Fields = struct { object: Object },
    };

    pub const decloaked: Declaration = .{
        .about = "`object` uncloaks.",
        .Fields = struct { object: Object },
    };

    pub const undocked: Declaration = .{
        .about = "`object` has retrieved its limpet pod and left the docking port.",
        .Fields = struct { object: Object },
    };

    pub const docked: Declaration = .{
        .about = "`object` has docked.",
        .Fields = struct { object: Object },
    };

    pub const explosion_ship: Declaration = .{
        .about = "The explosion that `object` set off is over.",
        .Fields = struct { object: Object },
    };

    pub const jumped_through_hoop: Declaration = .{
        .about = "`flown_by` has flown through `object`, a training hoop, from behind it.",
        .Fields = struct { object: Object, flown_by: Object },
    };
};

/// The engine's events.
pub const engine_events = struct {
    pub const mission_started: Declaration = .{
        .about = "A mission has started: number `number`, from the file `file`. Its first ships are there.",
        .Fields = Mission,
        .subject = null,
    };

    pub const mission_ended: Declaration = .{
        .about = "The mission ends: `ending` says how it ended for the player, and `rating` how its script rated it.",
        .Fields = Outcome,
        .subject = null,
    };

    pub const object_added: Declaration = .{
        .about = "`object` has been added to the mission.",
        .Fields = struct { object: Object },
    };

    pub const object_removed: Declaration = .{
        .about = "`object` is leaving the mission: it has blown up, or its slot is being reset. Its handle stops being valid after this.",
        .Fields = struct { object: Object },
    };

    pub const missile_added: Declaration = .{
        .about = "`missile` has been launched by `launcher`, or let fall from it. Its target is set.",
        .Fields = struct { missile: Missile, launcher: ?Object },
        .subject = "launcher",
    };

    pub const missile_removed: Declaration = .{
        .about = "The flight of `missile`, launched by `launcher`, ends: it has struck something or run out of time, and blows up. Its handle stops being valid after this. `launcher` is nil once it has left the mission.",
        .Fields = struct { missile: Missile, launcher: ?Object },
        .subject = "launcher",
    };

    pub const order_started: Declaration = .{
        .about = "`object` has started `order`, which has come to the top of its orders. One-shot orders, which run once and end straight away, don't start.",
        .Fields = struct { object: Object, order: orders.Order },
    };

    pub const order_ended: Declaration = .{
        .about = "`object` has ended `order`, which it had started, as the order was popped or replaced.",
        .Fields = struct { object: Object, order: orders.Order },
    };

    pub const trigger_fired: Declaration = .{
        .about = "The mission's trigger number `trigger` has fired on an event of `condition`. It's one of `object`'s triggers, or a flight group's or a squad's when `object` is nil.",
        .Fields = struct { trigger: usize, condition: dte.Condition, object: ?Object },
    };
};

/// Every hook: the functions', the order table's routines', OpenReliant's functions', the mission's
/// events and the engine's.
pub const Hook = hook: {
    var names: []const []const u8 = &.{};
    for (std.meta.declarations(functions)) |decl_name| names = names ++ .{decl_name};
    for (routine_hooks) |routine| names = names ++ .{routine.name};
    for (std.meta.declarations(engine_functions)) |decl_name| names = names ++ .{decl_name};
    for (std.meta.declarations(mission_events)) |decl_name| names = names ++ .{decl_name};
    for (std.meta.declarations(engine_events)) |decl_name| names = names ++ .{decl_name};
    const Int = std.math.IntFittingRange(0, names.len - 1);
    break :hook @Enum(Int, .exhaustive, names, &std.simd.iota(Int, names.len));
};

/// The declaration of `hook`, with what it's on.
pub fn declaration(comptime hook: Hook) Declaration {
    comptime {
        const name = @tagName(hook);
        var declared: Declaration = if (@hasDecl(functions, name))
            @field(functions, name)
        else if (@hasDecl(engine_functions, name))
            @field(engine_functions, name)
        else if (@hasDecl(mission_events, name))
            @field(mission_events, name)
        else if (@hasDecl(engine_events, name))
            @field(engine_events, name)
        else
            routineDeclaration(routineNamed(name).?);
        declared.on = if (@hasDecl(mission_events, name))
            .mission_event
        else if (@hasDecl(engine_events, name))
            .engine_event
        else if (@hasDecl(engine_functions, name))
            .engine_function
        else
            .function;
        return declared;
    }
}

/// The declaration of the hook on `routine`.
fn routineDeclaration(comptime routine: Routine) Declaration {
    return .{ .address = routine.address, .Fields = RoutineFields, .about = routineAbout(routine) };
}

/// What a handler of `hook` sees in `e`.
pub fn Fields(comptime hook: Hook) type {
    return declaration(hook).Fields;
}

/// What `hook`'s function returns.
pub fn Result(comptime hook: Hook) type {
    return declaration(hook).Result;
}

fn routineNamed(comptime name: []const u8) ?Routine {
    for (routine_hooks) |routine| {
        if (std.mem.eql(u8, routine.name, name)) return routine;
    }
    return null;
}

/// A mission, as the scripts hear of it.
pub const Mission = struct {
    /// Its number: 25 for both of mission 25's parts, and 0 for OpenReliant's sandbox.
    number: u16,
    /// Its file's name, such as `mission40.dte`, or `mission251.dte` for mission 25's second part,
    /// which `[Missions]` in a mod's manifest matches.
    file: []const u8,
};

/// How a mission ended, as the scripts hear of it.
pub const Outcome = struct {
    /// How it ended for the player: `playing` where the player's ship wasn't lost or left when it
    /// ended.
    ending: main.Ending,
    /// How the mission's script rated it (`vm.Variables.mission_success`).
    rating: vm.Variables.Outcome,
};

/// The mods' scripts, as the game calls them: the scripting module's game side, which
/// `create.Objects.scripts` holds while a game runs.
pub const Scripts = struct {
    /// The hooks that have handlers, which the hooked functions and events check first.
    hooked: std.EnumSet(Hook) = .empty,
    /// The hook whose function runs next without its handlers, as they run it (`Call.original`).
    passing: ?Hook = null,
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Runs the handlers of `call.hook`.
        call: *const fn (context: *anyopaque, call: *Call) void,
        /// A mission begins, before its objects are made: its own scripts start, and the scripts'
        /// random numbers start again from `seed`. Its orders run against `ctx` until it ends.
        begin: *const fn (context: *anyopaque, ctx: aigeneric.Context, mission: Mission, seed: u64) void,
        /// The mission has started (`on_mission_start`, `mission_started`).
        started: *const fn (context: *anyopaque, mission: Mission) void,
        /// The mission ends (`on_mission_end`, `mission_ended`), and its own scripts stop.
        ended: *const fn (context: *anyopaque, outcome: Outcome) void,
        /// A frame of the mission in which `seconds` of game time pass (`on_update`).
        update: *const fn (context: *anyopaque, seconds: f32) void,
        /// A simulation step (`on_step`).
        step: *const fn (context: *anyopaque) void,
        /// Metadata and callbacks for orders registered by mods, absent without a registry.
        order_info: ?*const fn (context: *anyopaque, order: orders.Order) ?orders.Info = null,
        order_run: ?*const fn (context: *anyopaque, ctx: aigeneric.Context, index: u16, order: orders.Order, role: routines.Role) bool = null,
    };

    pub fn begin(scripts: *Scripts, ctx: aigeneric.Context, mission: Mission, seed: u64) void {
        scripts.vtable.begin(scripts.context, ctx, mission, seed);
    }

    pub fn started(scripts: *Scripts, mission: Mission) void {
        scripts.vtable.started(scripts.context, mission);
    }

    pub fn ended(scripts: *Scripts, outcome: Outcome) void {
        scripts.vtable.ended(scripts.context, outcome);
    }

    pub fn update(scripts: *Scripts, seconds: f32) void {
        scripts.vtable.update(scripts.context, seconds);
    }

    pub fn step(scripts: *Scripts) void {
        scripts.vtable.step(scripts.context);
    }
};

/// A call of a hook, as its handlers run.
pub const Call = struct {
    scripts: *Scripts,
    hook: Hook,
    /// Its fields, a `Fields(hook)`, which a function's handlers may change.
    fields: *anyopaque,
    /// Its function's result, a `Result(hook)`; null for an event, or a function with none.
    result: ?*anyopaque,
    /// Runs the function with the fields as they are, and keeps its result; null for an event.
    original: ?*const fn (call: *Call) void,
};

/// What a hookable function's first line asks: null where the function goes on as it is, as it
/// does while no script hooks it. Otherwise the handlers have run, the function with them or not,
/// and this is its result. `arguments` are the function's own.
pub inline fn enter(comptime hook: Hook, comptime function: anytype, arguments: std.meta.ArgsTuple(@TypeOf(function))) ?Result(hook) {
    comptime checkFunction(hook, @TypeOf(function));
    const scripts = scriptsOf(arguments[0]) orelse return null;
    if (!scripts.hooked.contains(hook)) return null;
    if (passes(scripts, hook)) return null;
    return run(scripts, hook, Fields(hook), function, arguments);
}

/// `enter`, for `function`, which runs the order table's routine of `role` for the order `info`,
/// the current order of the object in slot `index`: where the routine has a hook
/// (`routineHook`).
pub inline fn enterRoutine(comptime role: routines.Role, comptime function: anytype, ctx: aigeneric.Context, index: u16, info: orders.Info) ?void {
    const scripts = ctx.world.objects.scripts orelse return null;
    const hook = routineHook(info.order, role) orelse return null;
    if (!scripts.hooked.contains(hook)) return null;
    if (passes(scripts, hook)) return null;
    return run(scripts, hook, RoutineFields, function, .{ ctx, index, info });
}

/// Tells the handlers of `hook`, an event, that it has happened, with `fields`. `source` reaches
/// the scripts: the world, the context the orders run in, or the objects.
pub fn tell(source: anytype, comptime hook: Hook, fields: Fields(hook)) void {
    comptime assert(!declaration(hook).on.isFunction());
    const scripts = scriptsOf(source) orelse return;
    if (!scripts.hooked.contains(hook)) return;
    var told = fields;
    var call: Call = .{ .scripts = scripts, .hook = hook, .fields = &told, .result = null, .original = null };
    scripts.vtable.call(scripts.context, &call);
}

/// Whether `hook`'s handlers have it run past them, which leaves its function to run as it is.
fn passes(scripts: *Scripts, hook: Hook) bool {
    if (scripts.passing != hook) return false;
    scripts.passing = null;
    return true;
}

/// Runs the handlers of `hook`, whose fields are `F`, for a call of `function` with `arguments`.
fn run(scripts: *Scripts, hook: Hook, comptime F: type, comptime function: anytype, arguments: std.meta.ArgsTuple(@TypeOf(function))) Return(function) {
    const R = Return(function);
    const Arguments = @TypeOf(arguments);
    const Pending = struct {
        call: Call,
        arguments: Arguments,
        fields: F,
        result: R,

        fn original(call: *Call) void {
            const pending: *@This() = @alignCast(@fieldParentPtr("call", call));
            var given = pending.arguments;
            inline for (@typeInfo(F).@"struct".field_names, 1..) |name, at| {
                given[at] = parameterOf(@TypeOf(given[at]), @field(pending.fields, name));
            }
            call.scripts.passing = call.hook;
            defer call.scripts.passing = null;
            pending.result = @call(.auto, function, given);
        }
    };
    var pending: Pending = .{
        .call = undefined,
        .arguments = arguments,
        .fields = fieldsOf(F, arguments),
        .result = stopped(R),
    };
    pending.call = .{
        .scripts = scripts,
        .hook = hook,
        .fields = &pending.fields,
        .result = if (R == void) null else &pending.result,
        .original = Pending.original,
    };
    scripts.vtable.call(scripts.context, &pending.call);
    return pending.result;
}

/// The result a function of result type `R` leaves where a handler stops it: `R.stopped` where the
/// type declares one, and zero otherwise.
fn stopped(comptime R: type) R {
    switch (@typeInfo(R)) {
        .void => return {},
        .@"struct", .@"enum", .@"union" => if (@hasDecl(R, "stopped")) return R.stopped,
        else => {},
    }
    return std.mem.zeroes(R);
}

fn Return(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

/// The fields `F` of a call with `arguments`: each parameter after the first, in order.
fn fieldsOf(comptime F: type, arguments: anytype) F {
    var fields: F = undefined;
    const info = @typeInfo(F).@"struct";
    inline for (info.field_names, info.field_types, 1..) |name, Field, at| {
        @field(fields, name) = fieldOf(Field, arguments[at]);
    }
    return fields;
}

/// A parameter as a field of type `T`: a slot as an `Object`, and an order's target as a `Target`.
fn fieldOf(comptime T: type, parameter: anytype) T {
    return switch (T) {
        Object => .of(parameter),
        ?Object => if (parameter) |slot| .of(slot) else null,
        Target => .of(parameter),
        else => parameter,
    };
}

/// A field as a parameter of type `T`: an `Object` as its slot, and a `Target` as the game holds
/// one.
fn parameterOf(comptime T: type, field: anytype) T {
    return switch (@TypeOf(field)) {
        Object => field.slot(),
        ?Object => if (field) |object| object.slot() else null,
        Target => field.aimed(),
        else => field,
    };
}

/// The type of the parameter a field of type `Field` stands for: a slot for an `Object`, and the
/// game's target for a `Target`.
fn ParameterType(comptime Field: type) type {
    return switch (Field) {
        Object => u16,
        ?Object => ?u16,
        Target => aigeneric.Target,
        else => Field,
    };
}

/// Fails the build where `hook`'s fields don't follow `Function`'s parameters after the first, or
/// its result isn't the function's.
fn checkFunction(comptime hook: Hook, comptime Function: type) void {
    const info = @typeInfo(Function).@"fn";
    const fields = @typeInfo(Fields(hook)).@"struct";
    const name = @tagName(hook);
    if (!declaration(hook).on.isFunction()) @compileError(name ++ " is an event, which `tell` tells");
    if (info.param_types.len != fields.field_names.len + 1) @compileError("the fields of " ++ name ++ " don't follow its function's parameters");
    for (fields.field_names, fields.field_types, info.param_types[1..]) |field_name, Field, Param| {
        if (Param.? != ParameterType(Field)) @compileError("the field " ++ field_name ++ " of " ++ name ++ " doesn't follow its parameter");
    }
    if (info.return_type.? != Result(hook)) @compileError("the result of " ++ name ++ " isn't its function's");
}

/// The scripts `source` reaches: the world's, the orders' context's, or the objects'.
fn scriptsOf(source: anytype) ?*Scripts {
    return switch (@TypeOf(source)) {
        gameobj.World => source.objects.scripts,
        aigeneric.Context => source.world.objects.scripts,
        radio.Context => source.all.scripts,
        *create.Objects => source.scripts,
        *vm.Machine => if (source.game) |ctx| ctx.world.objects.scripts else null,
        else => @compileError("no scripts in a " ++ @typeName(@TypeOf(source))),
    };
}

/// The hook on the routine of `role` that `order` runs, where it has one: each order that uses a
/// routine reaches its hook.
pub fn routineHook(order: orders.Order, role: routines.Role) ?Hook {
    const number = std.math.cast(usize, @backingInt(order)) orelse return null;
    if (number >= routine_table.len) return null;
    return routine_table[number].get(role);
}

/// The hooks on the routines, by order number and role.
const routine_table = table: {
    @setEvalBranchQuota(orders.table.len * routine_hooks.len * 40);
    var last: usize = 0;
    for (orders.table) |entry| last = @max(last, orderNumber(entry.order));
    var table: [last + 1]std.EnumArray(routines.Role, ?Hook) = @splat(.initFill(null));
    for (orders.table) |entry| {
        for (std.enums.values(routines.Role)) |role| {
            const routine = routines.address(entry, role) orelse continue;
            for (routine_hooks) |each| {
                if (each.address == routine) table[orderNumber(entry.order)].set(role, @field(Hook, each.name));
            }
        }
    }
    break :table table;
};

/// The number of an order the table holds, which is never below 0.
fn orderNumber(order: orders.Order) usize {
    return @intCast(@backingInt(order));
}

comptime {
    @setEvalBranchQuota(100_000);
    for (std.enums.values(Hook)) |hook| {
        const declared = declaration(hook);
        const name = @tagName(hook);
        // A hook on one of the original's functions names its function. One on OpenReliant's own
        // functions or on an event doesn't.
        if ((declared.on == .function) != (declared.address != null)) @compileError(name ++ " is declared wrong");
        // Each mission event is one of the mission's conditions.
        if (declared.on == .mission_event and !@hasField(dte.Condition, name)) @compileError(name ++ " is not a condition");
        // A filter's subject is an object.
        if (declared.subject) |subject| {
            const Subject = @FieldType(declared.Fields, subject);
            if (Subject != Object and Subject != ?Object) @compileError("the subject of " ++ name ++ " isn't an object");
        }
        if (!declared.on.isFunction() and declared.Result != void) @compileError("the event " ++ name ++ " has a result");
    }
}

test Target {
    // A ship's component, a flight group and nothing, as scripts see them.
    const part: Target = .of(.at(5, 2));
    try std.testing.expectEqual(5, part.object.?.slot());
    try std.testing.expectEqual(2, part.component.?);
    try std.testing.expectEqual(3, Target.of(.group(.flight_group, 3)).flight_group.?);
    const none: Target = .of(.none);
    try std.testing.expect(none.object == null and none.flight_group == null and none.squad == null);
    // Unchanged, each goes back as it was, a kind the scripts can't name too.
    const odd: aigeneric.Target = .{ .kind = @fromBackingInt(7), .index = 4, .component = -1 };
    for ([_]aigeneric.Target{ .at(5, 2), .group(.squad, 1), .none, odd }) |held| {
        try std.testing.expectEqual(held, Target.of(held).aimed());
    }
    // Changed, the first of the object, the flight group and the squad set is aimed at.
    try std.testing.expectEqual(aigeneric.Target.at(9, null), (Target{ .object = .of(9), .squad = 1 }).aimed());
    try std.testing.expectEqual(aigeneric.Target.group(.squad, 1), (Target{ .squad = 1 }).aimed());
    try std.testing.expectEqual(aigeneric.Target.none, (Target{ ._held = .at(5, 2) }).aimed());
}

test routineHook {
    try std.testing.expectEqual(Hook.order_run_away, routineHook(.run_away, .update).?);
    try std.testing.expectEqual(Hook.order_fly_init, routineHook(.fly, .init).?);
    // Both Jump In orders reach the first's routine.
    try std.testing.expectEqual(Hook.order_jump_in, routineHook(.jump_in_40, .update).?);
    // The names table names two routines itself.
    try std.testing.expectEqual(Hook.player_controls, routineHook(.player_control, .update).?);
    try std.testing.expectEqual(Hook.order_first_step_init, routineHook(.make_capship_list_left, .init).?);
    // The empty routine has no hook, nor does an order without the routine.
    try std.testing.expectEqual(null, routineHook(.random_spin_slow, .update));
    try std.testing.expectEqual(null, routineHook(.run_away, .exit));
    try std.testing.expectEqual(null, routineHook(@fromBackingInt(-1), .update));
}

test declaration {
    try std.testing.expectEqual(0x00463EE0, declaration(.object_damage).address.?);
    try std.testing.expectEqual(f32, Result(.damage_by_difficulty));
    try std.testing.expectEqual(RoutineFields, Fields(.order_fight));
    try std.testing.expectEqualStrings("The update of order 19, Jump In, and of order 40, Jump In, which `object` runs.", comptime declaration(.order_jump_in).about);
    try std.testing.expectEqual(On.engine_event, declaration(.mission_started).on);
    try std.testing.expectEqual(On.engine_function, declaration(.mission_lost).on);
    try std.testing.expectEqual(null, declaration(.mission_lost).address);
    try std.testing.expectEqual(null, declaration(.camera_reached).subject);
}

/// A stand-in for the scripting module's game side, which records the calls it gets and runs the
/// function as a handler would.
const Recorder = struct {
    scripts: Scripts,
    calls: usize = 0,
    /// What the handlers do: change the first float field to this, then run the function or not.
    value: f32 = 0,
    runs: bool = true,

    const vtable: Scripts.VTable = .{
        .call = call,
        .begin = undefined,
        .started = undefined,
        .ended = undefined,
        .update = undefined,
        .step = undefined,
    };

    fn call(context: *anyopaque, c: *Call) void {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        recorder.calls += 1;
        switch (c.hook) {
            .damage_by_difficulty => {
                const fields: *Fields(.damage_by_difficulty) = @ptrCast(@alignCast(c.fields));
                fields.value = recorder.value;
                if (recorder.runs) c.original.?(c);
            },
            else => if (c.original) |original| original(c),
        }
    }
};

test enter {
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    const world = mission.world();
    _ = try mission.add(.of(.predator), @splat(0));
    const ship = try mission.add(.of(.sabre), @splat(0));
    var recorder: Recorder = .{ .scripts = .{ .context = undefined, .vtable = &Recorder.vtable } };
    recorder.scripts.context = &recorder;

    // Without scripts, or with nothing hooked, the function runs as it is.
    try std.testing.expectEqual(10, collision.byDifficulty(world, ship, .missile, 10));
    mission.objects.scripts = &recorder.scripts;
    try std.testing.expectEqual(10, collision.byDifficulty(world, ship, .missile, 10));
    try std.testing.expectEqual(0, recorder.calls);

    // Hooked, the handlers change what it gets, and run it.
    recorder.scripts.hooked.insert(.damage_by_difficulty);
    recorder.value = 30;
    try std.testing.expectEqual(30, collision.byDifficulty(world, ship, .missile, 10));
    try std.testing.expectEqual(1, recorder.calls);
    try std.testing.expectEqual(null, recorder.scripts.passing);

    // Where the handlers don't run it, it returns what they leave as its result: nothing here.
    recorder.runs = false;
    try std.testing.expectEqual(0, collision.byDifficulty(world, ship, .missile, 10));
}
