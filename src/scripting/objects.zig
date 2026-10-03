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

/// An object as scripts hold it.
pub const Handle = struct {
    slot: u16,
    /// The slot's count of reuses when the handle was made.
    count: u32,

    pub const tag = @intFromEnum(runtime_module.Tag.object);

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
pub const List = struct {
    slots: [gameobj.max_objects]u16 = undefined,
    len: usize = 0,

    pub fn append(list: *List, index: u16) void {
        list.slots[list.len] = index;
        list.len += 1;
    }
};

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

    pub const side = api.Field(gameobj.Side(i32), "The side it's on.", struct {
        pub fn get(all: *const create.Objects, index: u16) gameobj.Side(i32) {
            return all.slots[index].object.side;
        }
    });

    pub const position = api.Field(@Vector(3, f32), "Where it is.", struct {
        pub fn get(all: *const create.Objects, index: u16) @Vector(3, f32) {
            return gameobj.vector(all.slots[index].object.root.position);
        }
    });

    pub const velocity = api.Field(@Vector(3, f32), "How far it moves in a simulation step, of which there are 25 a second.", struct {
        pub fn get(all: *const create.Objects, index: u16) @Vector(3, f32) {
            return gameobj.vector(all.slots[index].object.velocity);
        }
    });

    pub const speed = api.Field(f32, "How fast it moves: the length of its velocity.", struct {
        pub fn get(all: *const create.Objects, index: u16) f32 {
            return all.slots[index].object.speed;
        }
    });

    pub const is_player = api.Field(bool, "Whether it's the player's ship.", struct {
        pub fn get(all: *const create.Objects, index: u16) bool {
            return index == all.player;
        }
    });

    pub const order = api.Field(?orders.Order, "The order it's following, such as `fight`; nil for none.", struct {
        pub fn get(all: *const create.Objects, index: u16) ?orders.Order {
            const entry = all.slots[index].current() orelse return null;
            return entry.order;
        }
    });

    pub const last_attacker = api.Field(?Object, "The object that last hit it; nil for none, or once that one has left the mission.", struct {
        pub fn get(all: *const create.Objects, index: u16) ?Object {
            const attacker = all.slots[index].object.last_attacker.index() orelse return null;
            if (attacker >= all.slots.len or !world.inMission(all, attacker)) return null;
            return .of(attacker);
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

    pub const shields = api.Field(gameobj.Quadrants, "Its shields in each quadrant.", struct {
        pub fn get(all: *const create.Objects, index: u16) gameobj.Quadrants {
            return all.slots[index].object.shields;
        }
    });

    pub const armor = api.Field(gameobj.Quadrants, "Its armour in each quadrant.", struct {
        pub fn get(all: *const create.Objects, index: u16) gameobj.Quadrants {
            return all.slots[index].object.armor;
        }
    });

    pub const hull = api.Field(?f32, "The share of its armour it has left, from about 1 as it's made down to 0: its weakest quadrant against a quadrant's full armour. Nil for an object without stats.", struct {
        pub fn get(all: *const create.Objects, index: u16) ?f32 {
            const slot_held = &all.slots[index];
            const combat = slot_held.combat orelse return null;
            return combat.armorShare(slot_held.object.armor);
        }
    });

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

/// The methods of a handle (`api.Function`), each taking the handle first, as `self`.
pub const methods = struct {
    pub const is_valid = api.Function("Whether the object is still in the mission. A handle stops being valid once its object is removed or its mission ends.", &.{"self"}, isValid);
    pub const give_order = api.Function("Gives it `order`, aimed at `target` or at nothing, as a mission's SetAI does: the order goes on top of its orders if the one it follows gives way. Returns whether it took. Global scripts can give any object orders, and an object's scripts their own object.", &.{ "self", "order", "target" }, giveOrder);
    pub const send_event = api.Function("Sends the event `name` to the object's scripts, with `data`, which must be plain data. It arrives at the next update.", &.{ "self", "name", "data" }, game.sendEvent);
    pub const add_script = api.Function("Starts the script `name` of the calling mod on the object, as an object script, and passes `data` to its `on_init`. Returns whether it started. Only global scripts can add scripts.", &.{ "self", "name", "data" }, game.addScript);
    pub const hook = api.Native("`hooks.add`, for the calls that concern this object only: a handler for the hook `name`, with an optional `filter`. Returns the handler's handle. Global scripts can hook any object, and an object's scripts their own.", "name: string, handler: (e: any) -> boolean?, filter: (Filter | (e: any) -> boolean)?", "HookHandle", hooks.hookObject);
    pub const remove_script = api.Function("Stops the script `name` of the calling mod on the object. Returns whether it ran there. Only global scripts can remove scripts.", &.{ "self", "name" }, game.removeScript);
};

/// `object:is_valid()`.
fn isValid(call: Call, handle: Handle) bool {
    const all = call.runtime().objects orelse return false;
    return handle.valid(all);
}

/// `object:give_order(order, target)`.
fn giveOrder(call: Call, object: Object, given: orders.Order, target: ?Object) bool {
    const index = object.slot();
    if (!mayChange(call.context, index)) call.raise("give_order: {t} scripts can't give this object orders", .{call.context.family});
    const ctx = call.runtime().orders orelse call.raise("give_order: orders can only be given while a mission runs", .{});
    const aim: engine.game.aigeneric.Target = if (target) |aimed| .at(aimed.slot(), null) else .none;
    return engine.game.aigeneric.give(ctx, index, given, aim);
}

/// Whether the script of `context` may change the object in slot `index`: a global script may
/// change any object, and an object's script only its own.
pub fn mayChange(context: *const Context, index: u16) bool {
    return switch (context.family) {
        .global => true,
        .object => if (context.object) |own| own.slot == index else false,
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
            std.fmt.bufPrint(&buffer, "object {d} ({s})", .{ handle.slot, type_name })
        else
            std.fmt.bufPrint(&buffer, "object {d} (type {d})", .{ handle.slot, @intFromEnum(object_type) });
    } else std.fmt.bufPrint(&buffer, "object {d} (gone)", .{handle.slot});
    state.pushString(text catch "object");
    return 1;
}

test "handles name objects until they are removed" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    _ = try mission.add(.predator, .{ 0, 0, 0 });
    const sabre = try mission.add(.sabre, .{ 0, 100, 0 });

    const scripts = try Runtime.create(gpa, std.testing.io, &.{}, .{ .side = .game, .limits = .{ .time = .fromSeconds(1), .memory = 1 << 20 }, .seed = 1, .version = "0.7.0" });
    defer scripts.destroy();
    register(scripts);
    scripts.objects = mission.objects;
    const state = scripts.state;
    const thread = state.newSandboxedThread();
    // The thread runs as an object script of the Sabre's, which can change the Sabre only.
    var context: Context = .{ .runtime = scripts, .mod = 0, .family = .object, .object = .of(mission.objects, sabre), .thread = thread, .thread_ref = undefined };
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

    // Once its slot is reset, the handle is no longer valid.
    mission.objects.resetSlot(sabre, &mission.random);
    try bind.testing.runSource(thread, "assert(not sabre:is_valid() and tostring(sabre) == 'object 1 (gone)')");
    try bind.testing.expectSourceError(thread, "local x = sabre.type", "no longer in the mission");
}
