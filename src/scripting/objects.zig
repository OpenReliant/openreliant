//! Objects as scripts see them ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! handles. A handle holds an object's slot, and how often the slot had had its object replaced
//! when the handle was made (`create.Objects.reuses`). It's valid until its object is removed, or
//! its mission ends: the game reuses its slots, so an old handle never points at whatever took the
//! slot. Reading a field of a handle that isn't valid raises an error; `object:is_valid()` says
//! whether it is.
//!
//! There's one handle for each object while scripts hold it, so handles compare equal for the same
//! object, and work as table keys. Every script can read its fields (`fields`); global scripts can
//! change the fields that have a setter on any object, and an object's own scripts on their object
//! (`mayChange`). Its methods are `methods`.

const std = @import("std");

const openreliant = @import("openreliant");
const pilots = openreliant.engine.game.pilots;
const engine = openreliant.engine;
const gameobj = engine.game.gameobj;
const create = engine.game.create;
const motion = engine.game.motion;
const orders = engine.game.ai.orders;
const Object = engine.hooks.Object;
const luau = @import("luau.zig");
const State = luau.State;
const runtime_module = @import("runtime.zig");
const Runtime = runtime_module.Runtime;
const Context = runtime_module.Context;
const values = @import("values.zig");
const api = @import("api.zig");
const Call = api.Call;
const data = @import("data.zig");
const game = @import("game.zig");
const world = @import("world.zig");
const hooks = @import("hooks.zig");
const util = @import("util.zig");
const math = engine.surrender.math;
const main = engine.game.main;
const Target = engine.hooks.Target;

const Vector = @Vector(3, f32);

/// An object as scripts hold it.
pub const Handle = struct {
    slot: u16,
    /// The slot's count of reuses when the handle was made.
    count: u32,

    pub const tag = @backingInt(runtime_module.Tag.object);

    /// Whether its object is still the one in its slot.
    pub fn valid(handle: Handle, all: *const create.Objects) bool {
        return handle.slot < all.reuses.len and all.reuses[handle.slot] == handle.count;
    }

    /// The handle of the object in slot `index` of `all` now.
    pub fn of(all: *const create.Objects, index: u16) Handle {
        return .{ .slot = index, .count = all.reuses[index] };
    }
};

/// Several objects, which scripts get as a table of handles, in order (`values.push`).
pub const List = values.List(Object, gameobj.max_objects);

/// What scripts can read of an object, by name, and what they can change (`api.Field`). A field's
/// `get` takes the objects and the object's slot; its `set`, the call that sets it as well.
pub const fields = struct {
    pub const slot = api.Field(u16, "The slot it fills in the mission, from 0.", struct {
        pub fn get(_: *const create.Objects, index: u16) u16 {
            return index;
        }
    });

    pub const @"type" = api.Field(gameobj.Type, "Its type, such as `predator`.", struct {
        pub fn get(all: *const create.Objects, index: u16) gameobj.Type {
            return all.slots[index].object.type;
        }
    });

    pub const class = api.Field(?create.ShipCombat.Class, "Its class, such as `fighter`; nil for an object without stats, such as a nav point.", struct {
        pub fn get(all: *const create.Objects, index: u16) ?create.ShipCombat.Class {
            const combat = all.slots[index].combat orelse return null;
            return combat.class;
        }
    });

    pub const pilot = api.Field(pilots.Number, "The pilot flying it, whose record sets how it flies and fights: a pilot of the game's by its number, one a mod adds by its qualified name, or `none`.", struct {
        pub fn get(all: *const create.Objects, index: u16) pilots.Number {
            return .of(all.slots[index].object.pilot);
        }

        pub fn set(_: Call, all: *create.Objects, index: u16, value: pilots.Number) void {
            pilots.setPilot(&all.slots[index].object, if (value == .none) -1 else @backingInt(value));
        }
    });

    pub const side = api.Field(gameobj.Side(i32), "The side it's on. Setting it changes its side, as a mission's SetHostile does.", struct {
        pub fn get(all: *const create.Objects, index: u16) gameobj.Side(i32) {
            return all.slots[index].object.side;
        }

        pub fn set(_: Call, all: *create.Objects, index: u16, value: gameobj.Side(i32)) void {
            all.slots[index].object.side = value;
        }
    });

    pub const position = api.Field(Vector, "Where it is. Setting it moves it there at once, as a mission's SnapToPoint does.", struct {
        pub fn get(all: *const create.Objects, index: u16) Vector {
            return all.slots[index].object.position();
        }

        pub fn set(_: Call, all: *create.Objects, index: u16, value: Vector) void {
            moveTo(&all.slots[index], value);
        }
    });

    pub const orientation = api.Field(util.Orientation, "Where its axes point: to its right, down and forward, out of its nose (`openreliant.util`). Setting it turns it at once, its axes made unit length and at right angles first, the forward one keeping its direction.", struct {
        pub fn get(all: *const create.Objects, index: u16) util.Orientation {
            return .of(all.slots[index].object.root.orientation);
        }

        pub fn set(call: Call, all: *create.Objects, index: u16, value: util.Orientation) void {
            turnTo(call, &all.slots[index], value);
        }
    });

    pub const velocity = api.Field(Vector, "How far it moves in a simulation step, of which there are 25 a second. Setting it pushes it, and its engines carry on from there.", struct {
        pub fn get(all: *const create.Objects, index: u16) Vector {
            return all.slots[index].object.velocity.vector();
        }

        pub fn set(_: Call, all: *create.Objects, index: u16, value: Vector) void {
            const object = &all.slots[index].object;
            object.velocity = .of(value);
            object.speed = math.length(value);
        }
    });

    pub const speed = api.Field(f32, "How fast it moves: the length of its velocity.", struct {
        pub fn get(all: *const create.Objects, index: u16) f32 {
            return all.slots[index].object.speed;
        }
    });

    pub const radius = api.Field(f32, "How far its model reaches from its middle.", struct {
        pub fn get(all: *const create.Objects, index: u16) f32 {
            return all.slots[index].object.radius;
        }
    });

    pub const is_player = api.Field(bool, "Whether it's the player's ship.", struct {
        pub fn get(all: *const create.Objects, index: u16) bool {
            return index == all.player;
        }
    });

    pub const order = api.Field(?@import("orders.zig").Identifier, "The order it's following: one of the game's (`Order`), or a mod's by its qualified name; nil for none.", struct {
        pub fn get(all: *const create.Objects, index: u16) ?@import("orders.zig").Identifier {
            const entry = all.slots[index].current() orelse return null;
            return @import("orders.zig").identifierOf(all, entry.order);
        }
    });

    pub const target = api.Field(?Target, "What the order it's following is aimed at; nil while it follows none.", struct {
        pub fn get(all: *const create.Objects, index: u16) ?Target {
            const entry = all.slots[index].current() orelse return null;
            return .of(entry.target);
        }
    });

    pub const last_attacker = api.Field(?Object, "The object that last hit it; nil for none, or once that one has left the mission.", struct {
        pub fn get(all: *const create.Objects, index: u16) ?Object {
            const attacker = all.slots[index].object.last_attacker.index() orelse return null;
            return world.objectIn(all, attacker);
        }
    });

    pub const throttle = api.Field(f32, "Its throttle: 1 is full, 2 the afterburner's and -1 reverse thrust's. Its order or its pilot usually sets it each frame.", struct {
        pub fn get(all: *const create.Objects, index: u16) f32 {
            return all.slots[index].object.throttle;
        }

        pub fn set(call: Call, all: *create.Objects, index: u16, value: f32) void {
            if (value < motion.reverse_throttle or value > motion.afterburner_throttle) {
                call.raise("throttle: expected a number from {d} to {d}, got {d}", .{ motion.reverse_throttle, motion.afterburner_throttle, value });
            }
            all.slots[index].object.throttle = value;
        }
    });

    pub const roll_input = Input("roll_input", "How hard it rolls, from -1 to 1. Its order or its pilot usually sets it each frame.");
    pub const pitch_input = Input("pitch_input", "How hard it pitches, from -1 to 1. Its order or its pilot usually sets it each frame.");
    pub const yaw_input = Input("yaw_input", "How hard it yaws, from -1 to 1. Its order or its pilot usually sets it each frame.");

    pub const afterburning = api.Field(bool, "Whether its afterburner burns.", struct {
        pub fn get(all: *const create.Objects, index: u16) bool {
            return all.slots[index].object.afterburner;
        }
    });

    pub const afterburner_fuel = api.Field(f32, "The afterburner's fuel left, in seconds of burning. Setting it fills or drains the tank, from 0 up.", struct {
        pub fn get(all: *const create.Objects, index: u16) f32 {
            return @as(f32, @floatFromInt(all.slots[index].object.afterburner_fuel)) / main.ticks_per_second;
        }

        pub fn set(call: Call, all: *create.Objects, index: u16, value: f32) void {
            if (value < 0) call.raise("afterburner_fuel: expected a number from 0 up, got {d}", .{value});
            all.slots[index].object.afterburner_fuel = std.math.lossyCast(i32, value * main.ticks_per_second);
        }
    });

    pub const countermeasures = api.Field(u16, "How many countermeasures it has left.", struct {
        pub fn get(all: *const create.Objects, index: u16) u16 {
            return all.slots[index].object.countermeasures;
        }

        pub fn set(_: Call, all: *create.Objects, index: u16, value: u16) void {
            all.slots[index].object.countermeasures = value;
        }
    });

    pub const shields = api.Field(gameobj.Quadrants, "Its shields in each quadrant. Each can be set from 0 to what a whole ship of its type has; an object without stats has no shields to set.", struct {
        pub fn get(all: *const create.Objects, index: u16) gameobj.Quadrants {
            return all.slots[index].object.shields;
        }

        pub fn set(call: Call, all: *create.Objects, index: u16, value: gameobj.Quadrants) void {
            const slot_held = &all.slots[index];
            const combat = slot_held.combat orelse call.raise("shields: an object without stats has none", .{});
            slot_held.object.shields = quadrantsUpTo(call, value, combat.fullShields() - 1, "shields");
        }
    });

    pub const armor = api.Field(gameobj.Quadrants, "Its armour in each quadrant. Each can be set from 0 to what a whole ship of its type has, and its guns, speed and shields' recharge follow, as damage wears them; an object without stats has no armour to set.", struct {
        pub fn get(all: *const create.Objects, index: u16) gameobj.Quadrants {
            return all.slots[index].object.armor;
        }

        pub fn set(call: Call, all: *create.Objects, index: u16, value: gameobj.Quadrants) void {
            const slot_held = &all.slots[index];
            const combat = slot_held.combat orelse call.raise("armor: an object without stats has none", .{});
            slot_held.object.armor = quadrantsUpTo(call, value, combat.startingArmor(), "armor");
            main.armorConditions(&slot_held.object, combat);
        }
    });

    pub const hull = api.Field(?f32, "The share of its armour it has left, from about 1 as it's made down to 0: its weakest quadrant against a quadrant's full armour. Nil for an object without stats.", struct {
        pub fn get(all: *const create.Objects, index: u16) ?f32 {
            const slot_held = &all.slots[index];
            const combat = slot_held.combat orelse return null;
            return combat.armorShare(slot_held.object.armor);
        }
    });

    pub const invulnerable = api.Field(gameobj.Invulnerability, "What can harm it: anything for `none`, nothing for `full`, only a player's ship for `player_can_hit`, and anything for `eject_before_exploding`, though its pilot ejects first. Setting it is what a mission's SetInvulnerability does.", struct {
        pub fn get(all: *const create.Objects, index: u16) gameobj.Invulnerability {
            return all.slots[index].object.invulnerable;
        }

        pub fn set(_: Call, all: *create.Objects, index: u16, value: gameobj.Invulnerability) void {
            all.slots[index].object.invulnerable = value;
        }
    });

    pub const exploding = ReadFlag("exploding", "Whether it has started to explode. It takes no more orders.");
    pub const ejected = ReadFlag("ejected", "Whether its pilot has ejected. It takes no more orders.");

    pub const cloaked = api.Field(bool, "Whether it's cloaked. Setting it cloaks or uncloaks it, as a mission's Cloak does, where its model can.", struct {
        pub fn get(all: *const create.Objects, index: u16) bool {
            return all.slots[index].object.flags.cloaked;
        }

        pub fn set(call: Call, _: *create.Objects, index: u16, value: bool) void {
            const ctx = call.runtime().orders orelse call.raise("cloaked: ships only cloak while a mission runs", .{});
            engine.game.cloak.set(ctx.world, index, value);
        }
    });

    pub const targetable = api.Field(bool, "Whether ships can target it. Setting it is what a mission's SetTargetable does: a type that can't be targeted stays so.", struct {
        pub fn get(all: *const create.Objects, index: u16) bool {
            return all.slots[index].object.flags.targetable;
        }

        pub fn set(_: Call, all: *create.Objects, index: u16, value: bool) void {
            const slot_held = &all.slots[index];
            engine.game.ai.setTargetable(&slot_held.object, slot_held.combat, value);
        }
    });

    pub const lights = api.Field(bool, "Whether its lights are on. Setting it is what a mission's DisableLights does.", struct {
        pub fn get(all: *const create.Objects, index: u16) bool {
            return !all.slots[index].object.flags.lights_disabled;
        }

        pub fn set(_: Call, all: *create.Objects, index: u16, value: bool) void {
            engine.game.executor.setLights(&all.slots[index], value);
        }
    });

    pub const disabled = Flag("disabled", "Whether it's left out of the mission's work, as a mission's DisableObject leaves it.");
    pub const guns_disabled = Flag("guns_disabled", "Whether its guns don't fire and its turrets rest, as a mission's DisableGuns sets.");
    pub const missiles_disabled = Flag("missiles_disabled", "Whether it can't launch missiles, as a mission's DisableMissiles sets.");
    pub const engines_disabled = Flag("engines_disabled", "Whether its engines are off: its throttle held at 0, and no afterburner or reverse thrust, as a mission's DisableEngines sets.");
    pub const eject_disabled = Flag("eject_disabled", "Whether the player can't eject from it, as a mission's DisableEject sets.");
    pub const do_not_disturb = Flag("do_not_disturb", "Whether it keeps to its orders: it doesn't retaliate, come to another's help, rise to a taunt or take the wingmen's commands, as a mission's DoNotDisturb sets.");
    pub const avoidance_disabled = Flag("no_avoidance", "Whether it no longer keeps clear of other ships, as a mission's SetShipAvoidance sets.");

    /// A flag of the object's, `flag`, which scripts read and set.
    fn Flag(comptime flag: []const u8, comptime about: []const u8) type {
        return api.Field(bool, about, struct {
            pub fn get(all: *const create.Objects, index: u16) bool {
                return @field(all.slots[index].object.flags, flag);
            }

            pub fn set(_: Call, all: *create.Objects, index: u16, value: bool) void {
                @field(all.slots[index].object.flags, flag) = value;
            }
        });
    }

    /// A flag of the object's, `flag`, which scripts only read.
    fn ReadFlag(comptime flag: []const u8, comptime about: []const u8) type {
        return api.Field(bool, about, struct {
            pub fn get(all: *const create.Objects, index: u16) bool {
                return @field(all.slots[index].object.flags, flag);
            }
        });
    }

    /// A steering input, the object's field `name`.
    fn Input(comptime name: []const u8, comptime about: []const u8) type {
        return api.Field(f32, about, struct {
            pub fn get(all: *const create.Objects, index: u16) f32 {
                return @field(all.slots[index].object, name);
            }

            pub fn set(call: Call, all: *create.Objects, index: u16, value: f32) void {
                if (@abs(value) > motion.full_input) call.raise(name ++ ": expected a number from {d} to {d}, got {d}", .{ -motion.full_input, motion.full_input, value });
                @field(all.slots[index].object, name) = value;
            }
        });
    }
};

/// Moves the object of `slot` to `position` at once: where it stands now and next, and where it's
/// drawn (`objects.setPosition`).
pub fn moveTo(slot: *create.Slot, position: Vector) void {
    engine.game.objects.setPosition(&slot.object, &slot.drawn, position);
}

/// Turns the object of `slot` to `orientation` at once, its axes made unit length and at right
/// angles first (`math.orthonormalize`). Raises an error for axes that don't make an orientation.
pub fn turnTo(call: Call, slot: *create.Slot, orientation: util.Orientation) void {
    if (!(math.lengthSquared(math.cross(orientation.forward, orientation.right)) > 0)) {
        call.raise("orientation: expected forward and right axes that aren't zero or parallel", .{});
    }
    engine.game.objects.setOrientation(&slot.object, &slot.drawn, math.orthonormalize(orientation.matrix()));
}

/// `value`, a quadrant's figure in each, where each lies from 0 to `most`. Raises an error naming
/// `label` otherwise.
fn quadrantsUpTo(call: Call, value: gameobj.Quadrants, most: f32, comptime label: []const u8) gameobj.Quadrants {
    const top = @max(0, most);
    inline for (@typeInfo(gameobj.Quadrants).@"struct".field_names) |quadrant| {
        const figure = @field(value, quadrant);
        if (figure < 0 or figure > top) call.raise(label ++ ".{s}: expected a number from 0 to {d}, got {d}", .{ quadrant, top, figure });
    }
    return value;
}

/// The methods of a handle (`api.Function`), each taking the handle first, as `self`.
pub const methods = struct {
    pub const is_valid = api.Function("Whether the object is still in the mission. A handle stops being valid once its object is removed or its mission ends.", &.{"self"}, isValid);
    pub const give_order = api.Function("Gives it `order`, aimed at `target` or at nothing, as a mission's SetAI does: the order goes on top of its orders if the one it follows gives way. `component` aims it at one part of `target` instead of the whole ship, as a mission's orders can: for Launch, the carrier's launch gate, counting from 0; for Dock, the port. Returns whether it took. Global scripts can give any object orders, and an object's scripts their own object.", &.{ "self", "order", "target", "component" }, giveOrder);
    pub const start_launch = api.Function("Starts its Launch, as a mission's StartLaunch does: the first Launch among its orders goes after the short random wait the game gives each ship. Returns whether it had a Launch to start. Global scripts can start any object's launch, and an object's scripts their own.", &.{"self"}, startLaunch);
    pub const send_event = api.Function("Sends the event `name` to the object's scripts, with `data`, which must be plain data. It arrives at the next update.", &.{ "self", "name", "data" }, game.sendEvent);
    pub const add_script = api.Function("Starts the script `name` of the calling mod on the object, as an object script, and passes `data` to its `on_init`. Returns whether it started. Only global scripts can add scripts.", &.{ "self", "name", "data" }, game.addScript);
    pub const hook = api.Native("`hooks.add`, for the calls that concern this object only: a handler for the hook `name`, with an optional `filter`. Returns the handler's handle. Global scripts can hook any object, and an object's scripts their own.", "name: string, handler: (e: any) -> boolean?, filter: (Filter | (e: any) -> boolean)?", "HookHandle", hooks.hookObject);
    pub const set_surface = api.Function("Draws the object with the surface function `name`, the calling mod's by its own name or any mod's by the qualified one, reading `parameters`; nil draws it with its textures' functions again. Returns false if no function of that name is registered. Only player scripts can set it.", &.{ "self", "name", "parameters" }, @import("shaders.zig").setSurface);
    pub const turrets = api.Function("Its turrets: its guns that turn to aim, spin their barrels or launch missiles, destroyed ones included, in the order of its guns.", &.{"self"}, turretsOn);
    pub const remove_script = api.Function("Stops the script `name` of the calling mod on the object. Returns whether it ran there. Only global scripts can remove scripts.", &.{ "self", "name" }, game.removeScript);
};

/// `object:is_valid()`.
fn isValid(call: Call, handle: Handle) bool {
    const all = call.runtime().objects orelse return false;
    return handle.valid(all);
}

/// `object:turrets()`.
fn turretsOn(call: Call, object: Object) @import("turrets.zig").List {
    const all = call.runtime().objects orelse call.raise("turrets: objects only exist while a game runs", .{});
    return @import("turrets.zig").on(all, object.slot());
}

/// `object:give_order(order, target, component)`.
fn giveOrder(call: Call, object: Object, identifier: @import("orders.zig").Identifier, target: ?Object, component: ?u8) bool {
    const ctx = ordersOf(call, object, "give_order");
    const given = @import("orders.zig").resolve(call, identifier);
    const aim: engine.game.aigeneric.Target = if (target) |aimed| .at(aimed.slot(), if (component) |part| part else null) else aim: {
        if (component != null) call.raise("give_order: a component needs a target", .{});
        break :aim .none;
    };
    return engine.game.aigeneric.give(ctx, object.slot(), given, aim);
}

/// `object:start_launch()`: `launch.start` (`launch_start`, `0x00418DB0`), as a mission's
/// StartLaunch runs it for each of its ships.
fn startLaunch(call: Call, object: Object) bool {
    const all = ordersOf(call, object, "start_launch").world.objects;
    const had = all.slots[object.slot()].firstOrder(.launch) != null;
    engine.game.launch.start(all, object.slot());
    return had;
}

/// What orders run against, where the calling script may change `object`'s orders
/// (`mayChange`). Raises an error naming `label` otherwise.
pub fn ordersOf(call: Call, object: Object, comptime label: []const u8) engine.game.aigeneric.Context {
    if (call.runtime().custom_orders.running) call.raise("order callbacks cannot change order stacks; return false to finish", .{});
    if (!mayChange(call.context, object.slot())) call.raise(label ++ ": {t} scripts can't change this object's orders", .{call.context.family});
    return call.runtime().orders orelse call.raise(label ++ ": orders can only change while a mission runs", .{});
}

/// Whether the script of `context` may change the object in slot `index`: a global script may
/// change any object, and an object's script only its own.
pub fn mayChange(context: *const Context, index: u16) bool {
    return switch (context.family) {
        .global => true,
        .object => if (context.runs_on) |own| switch (own) {
            .object => |handle| handle.slot == index,
            .missile, .turret => false,
        } else false,
        .load, .player, .menu => false,
    };
}

/// Registers the handles' metatable, and makes the table that keeps one handle for each object.
pub fn register(runtime: *Runtime) void {
    const state = runtime.state;
    state.registerUserdata(Handle.tag, "object", &.{
        .{ "__index", luau.wrap(getField) },
        .{ "__newindex", luau.wrap(setField) },
        .{ "__tostring", luau.wrap(describe) },
    });

    // The handles, by slot, which the table lets go once nothing else holds them.
    state.newTable(0, 0);
    state.newTable(0, 1);
    state.pushString("v");
    state.rawSetField(-2, "__mode");
    state.setMetatable(-2);
    runtime.handles = state.ref(-1);
    state.pop(1);
}

/// Pushes the handle of the object in slot `index`, or nil where no game runs.
pub fn push(state: *State, index: u16) void {
    const runtime = state.callbackData(Runtime).?;
    const all = runtime.objects orelse return state.pushNil();
    const count = all.reuses[index];
    _ = state.pushRef(runtime.handles.?);
    const table = state.top();
    const key: i32 = @as(i32, index) + 1;
    if (state.rawGetIndex(table, key) == .userdata) {
        if (state.toUserdata(Handle, -1, Handle.tag).?.count == count) return state.remove(table);
    }
    state.pop(1);
    const handle = state.newUserdata(Handle, Handle.tag);
    handle.* = .{ .slot = index, .count = count };
    state.pushCopy(-1);
    state.rawSetIndex(table, key);
    state.remove(table);
}

/// Pushes a handle of its own to the player's ship, outside the handles kept by slot, so that
/// `follow` can point it at the player's ship of each mission.
pub fn pushFollowing(state: *State, all: *const create.Objects) void {
    state.newUserdata(Handle, Handle.tag).* = .of(all, all.player);
}

/// Points the handle at `index` at the player's ship in `all` now.
pub fn follow(state: *State, index: i32, all: *const create.Objects) void {
    const handle = state.toUserdata(Handle, index, Handle.tag) orelse return;
    handle.* = .of(all, all.player);
}

/// Pushes `handle`, as another state's script held it: the object's own handle while it's in the
/// mission, or else a handle that isn't valid.
pub fn pushHandle(state: *State, handle: Handle) void {
    const runtime = state.callbackData(Runtime).?;
    if (runtime.objects) |all| if (handle.valid(all)) return push(state, handle.slot);
    state.newUserdata(Handle, Handle.tag).* = handle;
}

/// The slot of the object whose handle is at `given`. Raises an error if it isn't a valid handle;
/// `label` names the value in the message.
pub fn read(state: *State, given: i32, comptime label: []const u8) u16 {
    const handle = state.toUserdata(Handle, given, Handle.tag) orelse state.raise("{s}: expected an object, got {s}", .{ label, state.typeName(given) });
    const all = objectsOf(state);
    if (!handle.valid(all)) state.raise("{s}: the object is no longer in the mission", .{label});
    return handle.slot;
}

fn objectsOf(state: *State) *const create.Objects {
    return state.callbackData(Runtime).?.objects orelse state.raise("objects only exist while a game runs", .{});
}

/// `__index`: reads a field, or finds a method.
fn getField(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const key = state.toString(2) orelse state.raise("object: expected a field name, got {s}", .{state.typeName(2)});
    inline for (comptime api.declared(methods, .function)) |name| {
        if (std.mem.eql(u8, key, name)) {
            state.pushFunction(luau.wrap(@field(methods, name).wrapped), name ++ "");
            return 1;
        }
    }
    const all = objectsOf(state);
    if (!handle.valid(all)) state.raise("object {d} is no longer in the mission", .{handle.slot});
    inline for (comptime api.declared(fields, .field)) |name| {
        const field = @field(fields, name);
        if (std.mem.eql(u8, key, name)) {
            values.push(state, field.Type, field.get(all, handle.slot));
            return 1;
        }
    }
    state.raise("an object has no field '{s}'", .{key});
}

/// `__newindex`: changes a field that has a setter, where the script may change the object
/// (`mayChange`).
fn setField(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const key = state.toString(2) orelse state.raise("object: expected a field name, got {s}", .{state.typeName(2)});
    const call: Call = .of(state, key);
    const all = call.runtime().objects orelse state.raise("objects only exist while a game runs", .{});
    if (!handle.valid(all)) state.raise("object {d} is no longer in the mission", .{handle.slot});
    inline for (comptime api.declared(fields, .field)) |name| {
        const field = @field(fields, name);
        if (std.mem.eql(u8, key, name)) {
            if (!field.writable) state.raise("an object's {s} can only be read", .{name});
            if (!mayChange(call.context, handle.slot)) state.raise("{t} scripts can't change this object's {s}", .{ call.context.family, name });
            field.set(call, all, handle.slot, values.read(state, field.Type, 3, name));
            return 0;
        }
    }
    state.raise("an object has no field '{s}'", .{key});
}

/// `__tostring`: `object 12`, with the object's type while it's valid.
fn describe(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const runtime = state.callbackData(Runtime).?;
    var buffer: [64]u8 = undefined;
    const valid = if (runtime.objects) |all| handle.valid(all) else false;
    const text = if (valid) text: {
        const object_type = runtime.objects.?.slots[handle.slot].object.type;
        break :text if (values.name(gameobj.Type, object_type)) |type_name|
            std.mem.print(&buffer, "object {d} ({s})", .{ handle.slot, type_name })
        else
            std.mem.print(&buffer, "object {d} (type {d})", .{ handle.slot, @backingInt(object_type) });
    } else std.mem.print(&buffer, "object {d} (gone)", .{handle.slot});
    state.pushString(text catch "object");
    return 1;
}

test "handles name objects until they are removed" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    _ = try mission.add(.of(.predator), .{ 0, 0, 0 });
    const sabre = try mission.add(.of(.sabre), .{ 0, 100, 0 });

    const scripts = try Runtime.create(gpa, std.testing.io, &.{}, .{ .side = .game, .limits = .{ .time = .fromSeconds(1), .memory = 1 << 20 }, .seed = 1, .version = "0.7.0" });
    defer scripts.destroy();
    register(scripts);
    scripts.objects = mission.objects;
    const state = scripts.state;
    const thread = state.newSandboxedThread();
    // The thread runs as an object script of the Sabre's, which can change the Sabre only.
    var context: Context = .{ .runtime = scripts, .mod = 0, .family = .object, .runs_on = .{ .object = .of(mission.objects, sabre) }, .thread = thread, .thread_ref = undefined };
    thread.setThreadData(&context);
    push(thread, sabre);
    thread.setGlobal("sabre");
    push(thread, 0);
    thread.setGlobal("player");
    push(thread, sabre);
    thread.setGlobal("again");

    const bind = @import("bind.zig");
    try bind.testing.runSource(thread,
        \\assert(sabre == again and sabre ~= player)
        \\assert(sabre.type == "sabre" and sabre.slot == 1 and not sabre.is_player and player.is_player)
        \\assert(sabre.position == vector.create(0, 100, 0) and sabre:is_valid())
        \\assert(typeof(sabre) == "object" and tostring(sabre) == "object 1 (sabre)")
        \\local seen = { [sabre] = true }
        \\assert(seen[again])
    );
    try bind.testing.expectSourceError(thread, "sabre.type = 'predator'", "can only be read");
    try bind.testing.expectSourceError(thread, "local x = sabre.top_speed", "no field 'top_speed'");
    try bind.testing.runSource(thread, "sabre.throttle = 0.5; sabre.yaw_input = -1");
    try std.testing.expectEqual(0.5, mission.objects.slots[sabre].object.throttle);
    try std.testing.expectEqual(-1, mission.objects.slots[sabre].object.yaw_input);
    try bind.testing.expectSourceError(thread, "sabre.throttle = 3", "from -1 to 2");
    try bind.testing.expectSourceError(thread, "player.throttle = 1", "can't change this object's throttle");

    // Its place, side, flags and supplies change as a mission's commands change them. The handle is
    // read through a local, as scripts hold theirs: Luau resolves a global's fields once, as the
    // chunk loads.
    try bind.testing.runSource(thread,
        \\local ship = sabre
        \\ship.position = vector.create(10, 20, 30)
        \\assert(ship.position == vector.create(10, 20, 30))
        \\ship.velocity = vector.create(0, 3, 4)
        \\assert(ship.speed == 5)
        \\ship.side = "hostile"
        \\ship.guns_disabled = true
        \\ship.lights = false
        \\ship.invulnerable = "full"
        \\ship.afterburner_fuel = 2.5
        \\ship.countermeasures = 3
        \\assert(ship.side == "hostile" and ship.guns_disabled and not ship.lights and ship.invulnerable == "full")
        \\assert(ship.afterburner_fuel == 2.5 and ship.countermeasures == 3 and not ship.exploding)
        \\local turned = ship.orientation
        \\ship.orientation = { right = turned.forward, down = turned.down, forward = -turned.right * 2 }
        \\assert(vector.magnitude(ship.orientation.forward + turned.right) < 1e-5)
    );
    const changed = &mission.objects.slots[sabre];
    try std.testing.expectEqual(gameobj.Side(i32).hostile, changed.object.side);
    try std.testing.expect(changed.object.flags.guns_disabled and changed.object.flags.lights_disabled);
    try std.testing.expectEqual(250, changed.object.afterburner_fuel);
    try std.testing.expectEqual([3]f32{ 10, 20, 30 }, changed.drawn.position);
    // Shields and armour go from 0 to what a whole ship has.
    const combat = changed.combat.?;
    try bind.testing.runSource(thread, "sabre.shields = { left = 0, right = 1, fore = 2, aft = 3 }");
    try std.testing.expectEqual(gameobj.Quadrants{ .left = 0, .right = 1, .fore = 2, .aft = 3 }, changed.object.shields);
    try bind.testing.expectSourceError(thread, "sabre.shields = { left = -1, right = 0, fore = 0, aft = 0 }", "shields.left: expected a number from 0");
    var whole: [96]u8 = undefined;
    try bind.testing.expectSourceError(thread, try std.fmt.bufPrint(&whole, "sabre.armor = {{ left = {d}, right = 0, fore = 0, aft = 0 }}", .{combat.startingArmor() + 1}), "armor.left: expected a number from 0");
    try bind.testing.expectSourceError(thread, "sabre.orientation = { right = vector.zero, down = vector.zero, forward = vector.zero }", "aren't zero or parallel");

    // Once its slot is reset, the handle is no longer valid.
    create.resetSlot(mission.orders(), sabre);
    try bind.testing.runSource(thread, "assert(not sabre:is_valid() and tostring(sabre) == 'object 1 (gone)')");
    try bind.testing.expectSourceError(thread, "local x = sabre.type", "no longer in the mission");
}
