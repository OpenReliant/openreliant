//! Missiles in flight as scripts see them ([#587](https://github.com/OpenReliant/openreliant/issues/587)):
//! handles, as objects have (`objects.zig`). A missile isn't an object of the mission's slots but
//! one of the records of `missiles.Missiles`, so its handle holds its record, and how often the
//! record had been reused when the handle was made (`Missiles.reuses`). It's valid until the
//! missile's flight ends, or its mission ends; reading a field of a handle that isn't valid raises
//! an error. There's one handle for each missile while scripts hold it, so handles compare equal
//! for the same missile.
//!
//! Every script can read a missile's fields (`fields`). Global scripts can change those that have a
//! setter and set off any missile, and a missile's own scripts their missile (`mayChange`).
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const gameobj = engine.game.gameobj;
const create = engine.game.create;
const engine_missiles = engine.game.missiles;
const Object = engine.hooks.Object;
const Target = engine.hooks.Target;
const luau = @import("luau.zig");
const State = luau.State;
const runtime_module = @import("runtime.zig");
const Runtime = runtime_module.Runtime;
const Context = runtime_module.Context;
const values = @import("values.zig");
const api = @import("api.zig");
const Call = api.Call;
const util = @import("util.zig");
const handles = @import("objects.zig");

const Vector = @Vector(3, f32);

/// Several missiles, which scripts get as a table of handles, in order (`values.push`).
pub const List = values.List(engine.hooks.Missile, engine_missiles.max_missiles);

/// A missile as scripts hold it.
pub const Handle = struct {
    record: u8,
    /// The record's count of reuses when the handle was made.
    count: u32,

    pub const tag = @backingInt(runtime_module.Tag.missile);

    /// Whether its missile is still the one in its record.
    pub fn valid(handle: Handle, all: *const create.Objects) bool {
        return all.missiles.records[handle.record] != null and all.missiles.reuses[handle.record] == handle.count;
    }

    /// The handle of the missile in record `record` of `all` now.
    pub fn of(all: *const create.Objects, record: u8) Handle {
        return .{ .record = record, .count = all.missiles.reuses[record] };
    }
};

/// The missile in record `record`, which a valid handle holds.
fn missileIn(all: *const create.Objects, record: u8) *const engine_missiles.Missile {
    return &all.missiles.records[record].?;
}

/// What the missile in record `record` flies as, to change it.
fn slotOf(all: *create.Objects, record: u8) *create.Slot {
    return &all.missiles.records[record].?.slot;
}

/// What scripts can read of a missile, by name, and what they can change (`api.Field`). A field's
/// `get` takes the objects and the missile's record; its `set`, the call that sets it as well.
pub const fields = struct {
    pub const @"type" = api.Field(engine_missiles.Type, "Its type, such as `raptor`, or the qualified name of one a mod adds.", struct {
        pub fn get(all: *const create.Objects, record: u8) engine_missiles.Type {
            return missileIn(all, record).type;
        }
    });

    pub const launcher = api.Field(?Object, "The object that launched it, or let it fall; nil once that one has left the mission.", struct {
        pub fn get(all: *const create.Objects, record: u8) ?Object {
            return if (missileIn(all, record).launcherIn(all)) |slot| .of(slot) else null;
        }
    });

    pub const target = api.Field(Target, "What it flies at. Its guidance turns to a new target from the next frame.", struct {
        pub fn get(all: *const create.Objects, record: u8) Target {
            return .of(missileIn(all, record).target);
        }

        pub fn set(_: Call, all: *create.Objects, record: u8, value: Target) void {
            all.missiles.records[record].?.target = value.aimed();
        }
    });

    pub const side = api.Field(gameobj.Side(i32), "The side it's on: its launcher's, as it was launched.", struct {
        pub fn get(all: *const create.Objects, record: u8) gameobj.Side(i32) {
            return missileIn(all, record).slot.object.side;
        }
    });

    pub const position = api.Field(Vector, "Where it is. Setting it moves it there at once.", struct {
        pub fn get(all: *const create.Objects, record: u8) Vector {
            return missileIn(all, record).slot.object.position();
        }

        pub fn set(_: Call, all: *create.Objects, record: u8, value: Vector) void {
            handles.moveTo(slotOf(all, record), value);
        }
    });

    pub const orientation = api.Field(util.Orientation, "Where its axes point: to its right, down and forward, out of its nose (`openreliant.util`). Setting it turns it at once, its axes made unit length and at right angles first, and its guidance turns on from there.", struct {
        pub fn get(all: *const create.Objects, record: u8) util.Orientation {
            return .of(missileIn(all, record).slot.object.root.orientation);
        }

        pub fn set(call: Call, all: *create.Objects, record: u8, value: util.Orientation) void {
            handles.turnTo(call, slotOf(all, record), value);
        }
    });

    pub const velocity = api.Field(Vector, "How far it moves in a simulation step, of which there are 25 a second. Setting it pushes it, and its motor carries on from there.", struct {
        pub fn get(all: *const create.Objects, record: u8) Vector {
            return gameobj.vector(missileIn(all, record).slot.object.velocity);
        }

        pub fn set(_: Call, all: *create.Objects, record: u8, value: Vector) void {
            slotOf(all, record).object.velocity = gameobj.vec3(value);
        }
    });

    pub const speed = api.Field(f32, "How fast it moves: the length of its velocity.", struct {
        pub fn get(all: *const create.Objects, record: u8) f32 {
            const moved = gameobj.vector(missileIn(all, record).slot.object.velocity);
            return @sqrt(@reduce(.Add, moved * moved));
        }
    });
};

/// The methods of a handle (`api.Function`), each taking the handle first, as `self`.
pub const methods = struct {
    pub const is_valid = api.Function("Whether the missile is still in flight. A handle stops being valid once its flight ends or its mission ends.", &.{"self"}, isValid);
    pub const detonate = api.Function("Ends its flight now, as it ends when its time runs out: it blows up where it is, with a shockwave for a Havoc or an Imp. Global scripts can set off any missile, and a missile's own scripts their missile.", &.{"self"}, setOff);
};

/// `missile:is_valid()`.
fn isValid(call: Call, handle: Handle) bool {
    const all = call.runtime().objects orelse return false;
    return handle.valid(all);
}

/// `missile:detonate()`.
fn setOff(call: Call, missile: engine.hooks.Missile) void {
    if (!mayChange(call.context, missile.record())) call.raise("{t} scripts can't set this missile off", .{call.context.family});
    const ctx = call.runtime().orders orelse call.raise("missiles only fly while a mission runs", .{});
    engine_missiles.end(ctx.world, missile.record());
}

/// Whether the script of `context` may change the missile in record `record`: a global script may
/// change any missile, and a missile's script only its own.
pub fn mayChange(context: *const Context, record: u8) bool {
    return switch (context.family) {
        .global => true,
        .object => if (context.runs_on) |own| switch (own) {
            .missile => |handle| handle.record == record,
            .object, .turret => false,
        } else false,
        .load, .player, .menu => false,
    };
}

/// Registers the handles' metatable, and makes the table that keeps one handle for each missile.
pub fn register(runtime: *Runtime) void {
    const state = runtime.state;
    state.registerUserdata(Handle.tag, "missile", &.{
        .{ "__index", luau.wrap(getField) },
        .{ "__newindex", luau.wrap(setField) },
        .{ "__tostring", luau.wrap(describe) },
    });

    // The handles, by record, which the table lets go once nothing else holds them.
    state.newTable(0, 0);
    state.newTable(0, 1);
    state.pushString("v");
    state.rawSetField(-2, "__mode");
    state.setMetatable(-2);
    runtime.missile_handles = state.ref(-1);
    state.pop(1);
}

/// Pushes the handle of the missile in record `record`, or nil where no game runs.
pub fn push(state: *State, record: u8) void {
    const runtime = state.callbackData(Runtime).?;
    const all = runtime.objects orelse return state.pushNil();
    const count = all.missiles.reuses[record];
    _ = state.pushRef(runtime.missile_handles.?);
    const table = state.top();
    const key: i32 = @as(i32, record) + 1;
    if (state.rawGetIndex(table, key) == .userdata) {
        if (state.toUserdata(Handle, -1, Handle.tag).?.count == count) return state.remove(table);
    }
    state.pop(1);
    state.newUserdata(Handle, Handle.tag).* = .{ .record = record, .count = count };
    state.pushCopy(-1);
    state.rawSetIndex(table, key);
    state.remove(table);
}

/// The record of the missile whose handle is at `given`. Raises an error if it isn't a valid
/// handle; `label` names the value in the message.
pub fn read(state: *State, given: i32, comptime label: []const u8) u8 {
    const handle = state.toUserdata(Handle, given, Handle.tag) orelse state.raise("{s}: expected a missile, got {s}", .{ label, state.typeName(given) });
    if (!handle.valid(objectsOf(state))) state.raise("{s}: the missile's flight has ended", .{label});
    return handle.record;
}

fn objectsOf(state: *State) *const create.Objects {
    return state.callbackData(Runtime).?.objects orelse state.raise("missiles only exist while a game runs", .{});
}

/// `__index`: reads a field, or finds a method.
fn getField(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const key = state.toString(2) orelse state.raise("missile: expected a field name, got {s}", .{state.typeName(2)});
    inline for (comptime api.declared(methods, .function)) |name| {
        if (std.mem.eql(u8, key, name)) {
            state.pushFunction(luau.wrap(@field(methods, name).wrapped("missile:" ++ name)), name ++ "");
            return 1;
        }
    }
    const all = objectsOf(state);
    if (!handle.valid(all)) state.raise("missile {d}'s flight has ended", .{handle.record});
    inline for (comptime api.declared(fields, .field)) |name| {
        if (std.mem.eql(u8, key, name)) {
            const field = @field(fields, name);
            values.push(state, field.Type, field.get(all, handle.record));
            return 1;
        }
    }
    state.raise("a missile has no field '{s}'", .{key});
}

/// `__newindex`: changes a field that has a setter, where the script may change the missile
/// (`mayChange`).
fn setField(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const key = state.toString(2) orelse state.raise("missile: expected a field name, got {s}", .{state.typeName(2)});
    var call: Call = .of(state, "missile");
    const all = call.runtime().objects orelse state.raise("missiles only exist while a game runs", .{});
    if (!handle.valid(all)) state.raise("missile {d}'s flight has ended", .{handle.record});
    inline for (comptime api.declared(fields, .field)) |name| {
        const field = @field(fields, name);
        if (std.mem.eql(u8, key, name)) {
            call.label = "missile." ++ name;
            if (!field.writable) state.raise("a missile's {s} can only be read", .{name});
            if (!mayChange(call.context, handle.record)) state.raise("{t} scripts can't change this missile's {s}", .{ call.context.family, name });
            field.set(call, all, handle.record, values.read(state, field.Type, 3, name));
            return 0;
        }
    }
    state.raise("a missile has no field '{s}'", .{key});
}

/// `__tostring`: `missile 12`, with the missile's type while it flies.
fn describe(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const runtime = state.callbackData(Runtime).?;
    var buffer: [64]u8 = undefined;
    const valid = if (runtime.objects) |all| handle.valid(all) else false;
    const text = if (valid)
        std.mem.print(&buffer, "missile {d} ({f})", .{ handle.record, missileIn(runtime.objects.?, handle.record).type })
    else
        std.mem.print(&buffer, "missile {d} (gone)", .{handle.record});
    state.pushString(text catch "missile");
    return 1;
}

test "handles name missiles until their flight ends" {
    const gpa = std.testing.allocator;
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const launcher = try mission.add(.of(.predator), .{ 0, 0, 0 });
    const all = mission.objects;
    var slot: create.Slot = .{ .object = std.mem.zeroes(gameobj.GameObject) };
    slot.object.root.position = gameobj.vec3(.{ 0, 0, 500 });
    slot.object.velocity = gameobj.vec3(.{ 0, 3, 4 });
    const record = all.missiles.add(.{ .slot = slot, .launcher = launcher, .launcher_reuses = all.reuses[launcher], .type = .of(.raptor), .target = .at(launcher, null) }).?;

    const scripts = try Runtime.create(gpa, std.testing.io, &.{}, .{ .side = .game, .limits = .{ .time = .fromSeconds(1), .memory = 1 << 20 }, .seed = 1, .version = "0.7.0" });
    defer scripts.destroy();
    @import("objects.zig").register(scripts);
    register(scripts);
    scripts.objects = all;
    const state = scripts.state;
    const thread = state.newSandboxedThread();
    // The thread runs as another missile's script, which can't set this one off.
    var context: Context = .{ .runtime = scripts, .mod = 0, .family = .object, .runs_on = .{ .missile = .{ .record = record +% 1, .count = 0 } }, .thread = thread, .thread_ref = undefined };
    thread.setThreadData(&context);
    push(thread, record);
    thread.setGlobal("raptor");
    push(thread, record);
    thread.setGlobal("again");

    const bind = @import("bind.zig");
    try bind.testing.runSource(thread,
        \\assert(raptor == again and raptor:is_valid())
        \\assert(raptor.type == "raptor" and raptor.launcher.slot == 0 and raptor.target.object == raptor.launcher)
        \\assert(raptor.position == vector.create(0, 0, 500) and raptor.speed == 5)
        \\assert(typeof(raptor) == "missile" and tostring(raptor) == "missile 0 (raptor)")
    );
    try bind.testing.expectSourceError(thread, "raptor.speed = 1", "can only be read");
    try bind.testing.expectSourceError(thread, "local x = raptor.fuel", "no field 'fuel'");
    try bind.testing.expectSourceError(thread, "raptor:detonate()", "missile:detonate: object scripts can't set this missile off");
    try bind.testing.expectSourceError(thread, "raptor.target = {}", "can't change this missile's target");
    // Its own scripts retarget, move and push it.
    context.runs_on = .{ .missile = .of(all, record) };
    try bind.testing.runSource(thread,
        \\local missile = raptor
        \\missile.target = {}
        \\missile.position = vector.create(1, 2, 3)
        \\missile.velocity = vector.create(0, 0, 9)
        \\assert(missile.position == vector.create(1, 2, 3) and missile.speed == 9)
    );
    try std.testing.expectEqual(engine.game.aigeneric.Target.none, all.missiles.records[record].?.target);

    // Once its launcher leaves, the missile has none; once its record is freed, the handle is no
    // longer valid.
    create.resetSlot(mission.orders(), launcher);
    try bind.testing.runSource(thread, "assert(raptor.launcher == nil)");
    all.missiles.remove(gpa, record);
    try bind.testing.runSource(thread, "assert(not raptor:is_valid() and tostring(raptor) == 'missile 0 (gone)')");
    try bind.testing.expectSourceError(thread, "local x = raptor.type", "flight has ended");
}
