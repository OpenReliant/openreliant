//! Objects as scripts see them ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! handles. A handle holds an object's slot, and how often the slot had had its object replaced
//! when the handle was made (`create.Objects.reuses`). It's valid until its object is removed, or
//! its mission ends: the game reuses its slots, so an old handle never points at whatever took the
//! slot. Reading a field of a handle that isn't valid raises an error; `object:is_valid()` says
//! whether it is.
//!
//! There's one handle for each object while scripts hold it, so handles compare equal for the same
//! object, and work as table keys. Their fields can only be read in this version (`fields`).

const std = @import("std");

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const gameobj = engine.game.gameobj;
const create = engine.game.create;
const orders = engine.game.ai.orders;
const luau = @import("luau.zig");
const State = luau.State;
const runtime_module = @import("runtime.zig");
const Runtime = runtime_module.Runtime;
const values = @import("values.zig");

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
};

/// What scripts can read of an object, by name. Each is a field of its handle: its type, what it
/// is, and how it's read.
pub const fields = struct {
    pub const slot = Field(u16, "The slot it fills in the mission, from 0.", struct {
        fn get(_: *const create.Objects, index: u16) u16 {
            return index;
        }
    }.get);

    pub const @"type" = Field(gameobj.Type, "Its type, such as `predator`.", struct {
        fn get(all: *const create.Objects, index: u16) gameobj.Type {
            return all.slots[index].object.type;
        }
    }.get);

    pub const class = Field(?create.ShipCombat.Class, "Its class, such as `fighter`; nil for an object without stats, such as a nav point.", struct {
        fn get(all: *const create.Objects, index: u16) ?create.ShipCombat.Class {
            const combat = all.slots[index].combat orelse return null;
            return combat.class;
        }
    }.get);

    pub const side = Field(gameobj.Side(i32), "The side it's on.", struct {
        fn get(all: *const create.Objects, index: u16) gameobj.Side(i32) {
            return all.slots[index].object.side;
        }
    }.get);

    pub const position = Field(@Vector(3, f32), "Where it is.", struct {
        fn get(all: *const create.Objects, index: u16) @Vector(3, f32) {
            return gameobj.vector(all.slots[index].object.root.position);
        }
    }.get);

    pub const velocity = Field(@Vector(3, f32), "How far it moves in a simulation step, of which there are 25 a second.", struct {
        fn get(all: *const create.Objects, index: u16) @Vector(3, f32) {
            return gameobj.vector(all.slots[index].object.velocity);
        }
    }.get);

    pub const is_player = Field(bool, "Whether it's the player's ship.", struct {
        fn get(all: *const create.Objects, index: u16) bool {
            return index == all.player;
        }
    }.get);

    pub const order = Field(?orders.Order, "The order it's following, such as `fight`; nil for none.", struct {
        fn get(all: *const create.Objects, index: u16) ?orders.Order {
            const entry = all.slots[index].current() orelse return null;
            return entry.order;
        }
    }.get);
};

/// A field of a handle: of type `T`, described by `about`, and read by `read`.
fn Field(comptime T: type, comptime about: []const u8, comptime getter: fn (*const create.Objects, u16) T) type {
    return struct {
        pub const Type = T;
        pub const description = about;
        pub const get = getter;
    };
}

/// The methods of a handle.
pub const methods = struct {
    pub const is_valid = "Whether the object is still in the mission. A handle stops being valid once its object is removed or its mission ends.";
};

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
    if (std.mem.eql(u8, key, "is_valid")) {
        state.pushFunction(luau.wrap(isValid), "is_valid");
        return 1;
    }
    const all = objectsOf(state);
    if (!handle.valid(all)) state.raise("object {d} is no longer in the mission", .{handle.slot});
    inline for (comptime std.meta.declarations(fields)) |decl| {
        const field = @field(fields, decl.name);
        if (std.mem.eql(u8, key, decl.name)) {
            values.push(state, field.Type, field.get(all, handle.slot));
            return 1;
        }
    }
    state.raise("an object has no field '{s}'", .{key});
}

/// `object:is_valid()`.
fn isValid(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag) orelse state.raise("is_valid: expected an object, got {s}", .{state.typeName(1)});
    const runtime = state.callbackData(Runtime).?;
    state.pushBoolean(if (runtime.objects) |all| handle.valid(all) else false);
    return 1;
}

fn setField(state: *State) i32 {
    state.raise("an object's fields can only be read in this version of OpenReliant", .{});
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

    const scripts = try Runtime.create(gpa, std.testing.io, &.{}, .{ .side = .game, .limits = .{ .time = .fromSeconds(1), .memory = 1 << 20 }, .seed = 1 });
    defer scripts.destroy();
    register(scripts);
    scripts.objects = mission.objects;
    const state = scripts.state;
    const thread = state.newSandboxedThread();
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
    try bind.testing.expectSourceError(thread, "local x = sabre.speed", "no field 'speed'");

    // Once its slot is reset, the handle is no longer valid.
    mission.objects.resetSlot(sabre, &mission.random);
    try bind.testing.runSource(thread, "assert(not sabre:is_valid() and tostring(sabre) == 'object 1 (gone)')");
    try bind.testing.expectSourceError(thread, "local x = sabre.type", "no longer in the mission");
}
