//! Turrets as scripts see them ([#587](https://github.com/OpenReliant/openreliant/issues/587)):
//! handles, as objects and missiles have (`objects.zig`, `missiles.zig`). A turret is one of an
//! object's guns that turns to aim, spins its barrels or launches missiles (`guns.Turret`), so its
//! handle holds its object's handle and the gun's place among the object's guns. It's valid while
//! its object is in the mission, after the turret is destroyed too (`destroyed`). There's one handle
//! for each turret while scripts hold it, so handles compare equal for the same turret.
//!
//! Every script can read a turret's fields (`fields`). Global scripts can aim any turret, and a
//! turret's own scripts their turret (`mayChange`).
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const gameobj = engine.game.gameobj;
const create = engine.game.create;
const guns = engine.game.guns;
const Object = engine.hooks.Object;
const Target = engine.hooks.Target;
const Turret = engine.hooks.Turret;
const luau = @import("luau.zig");
const State = luau.State;
const runtime_module = @import("runtime.zig");
const Runtime = runtime_module.Runtime;
const Context = runtime_module.Context;
const values = @import("values.zig");
const api = @import("api.zig");
const Call = api.Call;
const handles = @import("objects.zig");

const Vector = @Vector(3, f32);

/// The most turrets an object's list holds (`List`): a handle's gun is a `u16`, and no ship of the
/// game has as many.
const max_listed = 256;

/// Several turrets, which scripts get as a table of handles, in order (`values.push`).
pub const List = values.List(Turret, max_listed);

/// A turret as scripts hold it.
pub const Handle = struct {
    object: handles.Handle,
    gun: u16,

    pub const tag = @backingInt(runtime_module.Tag.turret);

    /// Whether its object is still in the mission, with the turret among its guns.
    pub fn valid(handle: Handle, all: *const create.Objects) bool {
        return handle.object.valid(all) and isTurret(all.slots[handle.object.slot].guns, handle.gun);
    }

    /// The handle of `held` in `all` now.
    pub fn of(all: *const create.Objects, held: Turret) Handle {
        return .{ .object = .of(all, held.object.slot()), .gun = held.gun };
    }

    /// The turret it holds.
    pub fn turret(handle: Handle) Turret {
        return .{ .object = .of(handle.object.slot), .gun = handle.gun };
    }
};

/// Whether gun `gun` of `fitted` is a turret: any but a fixed gun, a destroyed turret included.
pub fn isTurret(fitted: []const guns.Fitted, gun: u16) bool {
    return gun < fitted.len and fitted[gun].turret != .fixed;
}

/// The turrets of the object in slot `index`, in the order of its guns.
pub fn on(all: *const create.Objects, index: u16) List {
    var list: List = .{};
    const fitted = all.slots[index].guns;
    for (0..@min(fitted.len, max_listed)) |gun| {
        if (isTurret(fitted, @intCast(gun))) list.append(.{ .object = .of(index), .gun = @intCast(gun) });
    }
    return list;
}

/// What a turret is (`guns.Turret`).
pub const Kind = enum {
    /// It turns to aim at a target of its own.
    aimed,
    /// Its barrels spin up while its object's trigger is held.
    spinning,
    /// It launches missiles.
    launcher,

    pub const script_name = "TurretKind";
};

/// The gun of `turret`, which a valid handle holds.
fn gunOf(all: *const create.Objects, turret: Turret) *guns.Fitted {
    return &all.slots[turret.object.slot()].guns[turret.gun];
}

/// What scripts can read of a turret, by name, and what they can change (`api.Field`). A field's
/// `get` takes the objects and the turret; its `set`, the call that sets it as well.
pub const fields = struct {
    pub const object = api.Field(Object, "The object it's on.", struct {
        pub fn get(_: *const create.Objects, turret: Turret) Object {
            return turret.object;
        }
    });

    pub const kind = api.Field(?Kind, "What it is: `aimed`, which turns to aim at a target of its own; `spinning`, a gun whose barrels spin up while its object's trigger is held; or `launcher`, which launches missiles. Nil once it's destroyed.", struct {
        pub fn get(all: *const create.Objects, turret: Turret) ?Kind {
            return switch (gunOf(all, turret).turret) {
                .aimed => .aimed,
                .spin => .spinning,
                .missile => .launcher,
                .fixed, .gone => null,
            };
        }
    });

    pub const destroyed = api.Field(bool, "Whether it was destroyed with its base. It turns and fires no more.", struct {
        pub fn get(all: *const create.Objects, turret: Turret) bool {
            return gunOf(all, turret).turret == .gone;
        }
    });

    pub const gun_type = api.Field(?guns.GunType, "The type of the shots it fires; nil for a missile turret, or once it's destroyed.", struct {
        pub fn get(all: *const create.Objects, turret: Turret) ?guns.GunType {
            const barrel = gunOf(all, turret).barrel() orelse return null;
            return barrel.type;
        }
    });

    pub const position = api.Field(?Vector, "Where its base is; nil once it's destroyed.", struct {
        pub fn get(all: *const create.Objects, turret: Turret) ?Vector {
            const base = gunOf(all, turret).turret.base() orelse return null;
            return base.part().drawn().position;
        }
    });

    pub const target = api.Field(?Target, "What it aims at: an aimed turret's and a missile turret's own target; nil for a spinning gun, which fires where its object points, or once it's destroyed. Setting it aims the turret, which turns to it, and nil leaves it to look for one.", struct {
        pub fn get(all: *const create.Objects, turret: Turret) ?Target {
            return switch (gunOf(all, turret).turret) {
                .aimed => |aimed| .of(aimed.target),
                .missile => |launcher| .of(launcher.target),
                .spin, .fixed, .gone => null,
            };
        }

        pub fn set(call: Call, all: *create.Objects, turret: Turret, value: ?Target) void {
            const aimed_at: engine.game.aigeneric.Target = if (value) |given| given.aimed() else .none;
            switch (gunOf(all, turret).turret) {
                .aimed => |*aimed| aimed.target = aimed_at,
                .missile => |*launcher| launcher.target = aimed_at,
                .spin, .fixed, .gone => call.raise("only an aimed turret or a missile turret has a target", .{}),
            }
        }
    });
};

/// The methods of a handle (`api.Function`), each taking the handle first, as `self`.
pub const methods = struct {
    pub const is_valid = api.Function("Whether its object is still in the mission. A handle stops being valid once its object is removed or its mission ends.", &.{"self"}, isValid);
};

/// `turret:is_valid()`.
fn isValid(call: Call, handle: Handle) bool {
    const all = call.runtime().objects orelse return false;
    return handle.valid(all);
}

/// Whether the script of `context` may change `turret`: a global script may change any turret, and
/// a turret's script only its own.
pub fn mayChange(context: *const Context, turret: Turret) bool {
    return switch (context.family) {
        .global => true,
        .object => if (context.runs_on) |own| switch (own) {
            .turret => |handle| handle.object.slot == turret.object.slot() and handle.gun == turret.gun,
            .object, .missile => false,
        } else false,
        .load, .player, .menu => false,
    };
}

/// Registers the handles' metatable, and makes the table that keeps one handle for each turret.
pub fn register(runtime: *Runtime) void {
    const state = runtime.state;
    state.registerUserdata(Handle.tag, "turret", &.{
        .{ "__index", luau.wrap(getField) },
        .{ "__newindex", luau.wrap(setField) },
        .{ "__tostring", luau.wrap(describe) },
    });

    // The handles, by object and gun, which the table lets go once nothing else holds them.
    state.newTable(0, 0);
    state.newTable(0, 1);
    state.pushString("v");
    state.rawSetField(-2, "__mode");
    state.setMetatable(-2);
    runtime.turret_handles = state.ref(-1);
    state.pop(1);
}

/// Pushes the handle of `turret`, or nil where no game runs.
pub fn push(state: *State, turret: Turret) void {
    const runtime = state.callbackData(Runtime).?;
    const all = runtime.objects orelse return state.pushNil();
    const made: Handle = .of(all, turret);
    _ = state.pushRef(runtime.turret_handles.?);
    const table = state.top();
    const key: i32 = @as(i32, turret.object.slot()) * (std.math.maxInt(u16) + 1) + turret.gun + 1;
    if (state.rawGetIndex(table, key) == .userdata) {
        if (std.meta.eql(state.toUserdata(Handle, -1, Handle.tag).?.*, made)) return state.remove(table);
    }
    state.pop(1);
    state.newUserdata(Handle, Handle.tag).* = made;
    state.pushCopy(-1);
    state.rawSetIndex(table, key);
    state.remove(table);
}

/// The turret whose handle is at `given`. Raises an error if it isn't a valid handle; `label` names
/// the value in the message.
pub fn read(state: *State, given: i32, comptime label: []const u8) Turret {
    const handle = state.toUserdata(Handle, given, Handle.tag) orelse state.raise("{s}: expected a turret, got {s}", .{ label, state.typeName(given) });
    if (!handle.valid(objectsOf(state))) state.raise("{s}: the turret's object is no longer in the mission", .{label});
    return handle.turret();
}

fn objectsOf(state: *State) *const create.Objects {
    return state.callbackData(Runtime).?.objects orelse state.raise("turrets only exist while a game runs", .{});
}

/// `__index`: reads a field, or finds a method.
fn getField(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const key = state.toString(2) orelse state.raise("turret: expected a field name, got {s}", .{state.typeName(2)});
    inline for (comptime api.declared(methods, .function)) |name| {
        if (std.mem.eql(u8, key, name)) {
            state.pushFunction(luau.wrap(@field(methods, name).wrapped("turret:" ++ name)), name ++ "");
            return 1;
        }
    }
    const all = objectsOf(state);
    if (!handle.valid(all)) state.raise("turret {d} of object {d} is no longer in the mission", .{ handle.gun, handle.object.slot });
    inline for (comptime api.declared(fields, .field)) |name| {
        if (std.mem.eql(u8, key, name)) {
            const field = @field(fields, name);
            values.push(state, field.Type, field.get(all, handle.turret()));
            return 1;
        }
    }
    state.raise("a turret has no field '{s}'", .{key});
}

/// `__newindex`: changes a field that has a setter, where the script may change the turret
/// (`mayChange`).
fn setField(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const key = state.toString(2) orelse state.raise("turret: expected a field name, got {s}", .{state.typeName(2)});
    var call: Call = .of(state, "turret");
    const all = call.runtime().objects orelse state.raise("turrets only exist while a game runs", .{});
    if (!handle.valid(all)) state.raise("turret {d} of object {d} is no longer in the mission", .{ handle.gun, handle.object.slot });
    inline for (comptime api.declared(fields, .field)) |name| {
        const field = @field(fields, name);
        if (std.mem.eql(u8, key, name)) {
            call.label = "turret." ++ name;
            if (!field.writable) state.raise("a turret's {s} can only be read", .{name});
            if (!mayChange(call.context, handle.turret())) state.raise("{t} scripts can't change this turret's {s}", .{ call.context.family, name });
            field.set(call, all, handle.turret(), values.read(state, field.Type, 3, name));
            return 0;
        }
    }
    state.raise("a turret has no field '{s}'", .{key});
}

/// `__tostring`: `turret 3 of object 12`, with what it is while its object is in the mission.
fn describe(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    const runtime = state.callbackData(Runtime).?;
    var buffer: [64]u8 = undefined;
    const valid = if (runtime.objects) |all| handle.valid(all) else false;
    const text = if (valid) text: {
        const kind = fields.kind.get(runtime.objects.?, handle.turret());
        break :text std.mem.print(&buffer, "turret {d} of object {d} ({s})", .{ handle.gun, handle.object.slot, if (kind) |known| @tagName(known) else "destroyed" });
    } else std.mem.print(&buffer, "turret {d} of object {d} (gone)", .{ handle.gun, handle.object.slot });
    state.pushString(text catch "turret");
    return 1;
}
