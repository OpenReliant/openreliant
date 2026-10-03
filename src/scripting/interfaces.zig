//! Interfaces ([#498](https://github.com/OpenReliant/openreliant/issues/498)): what a script
//! offers other scripts. A script that returns `interface_name` and `interface` offers the table
//! `interface` under that name, and scripts reach it through `openreliant.interfaces`, as
//! `I.<name>`. Global scripts see the interfaces of the global scripts, an object's scripts those
//! of the scripts on the same object, and player and menu scripts each other's.
//!
//! A later script that offers an interface of the same name, in a later mod or later in the same
//! mod, overrides the earlier one: scripts see the latest. The later script's
//! `on_interface_override` gets the earlier interface, so it can call through to it. When a script
//! stops, its interfaces go, and the one it overrode comes back.

const std = @import("std");
const Allocator = std.mem.Allocator;

const luau = @import("luau.zig");
const State = luau.State;
const runtime_module = @import("runtime.zig");
const Runtime = runtime_module.Runtime;
const Context = runtime_module.Context;
const Name = runtime_module.Name;
const objects = @import("objects.zig");
const api = @import("api.zig");
const Call = api.Call;
const builtin = @import("builtin_interfaces.zig");

/// Which scripts see an interface.
pub const Scope = union(enum) {
    /// The global and mission scripts, or on the presentation side the player and menu scripts.
    global,
    /// The scripts on one object.
    object: objects.Handle,

    /// The scope of the scripts of `context`.
    pub fn of(context: *const Context) ?Scope {
        return switch (context.family) {
            .global, .player, .menu => .global,
            .object => .{ .object = context.object.? },
            .load => null,
        };
    }

    fn eql(scope: Scope, other: Scope) bool {
        return switch (scope) {
            .global => other == .global,
            .object => |handle| switch (other) {
                .global => false,
                .object => |other_handle| handle.slot == other_handle.slot and handle.count == other_handle.count,
            },
        };
    }
};

/// An interface a script offers.
const Entry = struct {
    scope: Scope,
    name: Name,
    table: luau.Ref,
    /// The script's mod, as opened for it.
    context: *const Context,
};

/// The interfaces offered, oldest first.
pub const Interfaces = struct {
    gpa: Allocator,
    runtime: *Runtime,
    offered: std.ArrayList(Entry) = .empty,
    builtins: std.EnumArray(builtin.Group, ?luau.Ref) = .initFill(null),

    pub const tag = @intFromEnum(runtime_module.Tag.interfaces);

    pub fn deinit(interfaces: *Interfaces) void {
        for (interfaces.builtins.values) |ref| if (ref) |held| interfaces.runtime.release(held);
        interfaces.offered.deinit(interfaces.gpa);
    }

    /// Adds `table` under `name`, offered by a script of `context`, which keeps the reference.
    /// Returns the interface it overrides, if any.
    pub fn offer(interfaces: *Interfaces, context: *const Context, name: Name, table: luau.Ref) Allocator.Error!?luau.Ref {
        const scope = Scope.of(context).?;
        const base = if (interfaces.find(scope, name.slice())) |entry| entry.table else interfaces.builtinBase(context.family, name.slice());
        try interfaces.offered.append(interfaces.gpa, .{ .scope = scope, .name = name, .table = table, .context = context });
        return base;
    }

    fn builtinBase(interfaces: *Interfaces, family: @import("script.zig").Family, name: []const u8) ?luau.Ref {
        inline for (std.meta.fields(builtin.Group)) |group| {
            const kind: builtin.Group = @enumFromInt(group.value);
            if (std.mem.eql(u8, name, group.name) and kind.reachable(family)) {
                if (interfaces.builtins.get(kind)) |ref| return ref;
                const ref = interfaces.runtime.make(builtin.push, .{kind}) orelse return null;
                interfaces.builtins.set(kind, ref);
                return ref;
            }
        }
        return null;
    }

    /// Takes away the interfaces the scripts of `context` offered, as they stop. The references
    /// stay with the scripts' own records (`runtime.Offered`).
    pub fn removeContext(interfaces: *Interfaces, context: *const Context) void {
        var kept: usize = 0;
        for (interfaces.offered.items) |entry| {
            if (entry.context == context) continue;
            interfaces.offered.items[kept] = entry;
            kept += 1;
        }
        interfaces.offered.shrinkRetainingCapacity(kept);
    }

    /// The latest interface named `name` that scripts of `scope` see.
    fn find(interfaces: *const Interfaces, scope: Scope, name: []const u8) ?*const Entry {
        var at = interfaces.offered.items.len;
        while (at > 0) {
            at -= 1;
            const entry = &interfaces.offered.items[at];
            if (entry.scope.eql(scope) and std.mem.eql(u8, entry.name.slice(), name)) return entry;
        }
        return null;
    }

    /// Registers the metatable of `I`, the package `openreliant.interfaces`.
    pub fn register(state: *State) void {
        state.registerUserdata(tag, "interfaces", &.{
            .{ "__index", luau.wrap(get) },
            .{ "__newindex", luau.wrap(set) },
        });
    }

    /// Pushes the package `openreliant.interfaces`, which reads the interfaces of whichever script
    /// looks them up.
    pub fn push(interfaces: *Interfaces, state: *State) void {
        const held = state.newUserdata(*Interfaces, tag);
        held.* = interfaces;
    }

    /// `__index`: the latest interface of the name the caller's scripts see, or nil.
    fn get(state: *State) i32 {
        const interfaces = state.toUserdata(*Interfaces, 1, tag).?.*;
        const name = state.toString(2) orelse state.raise("interfaces: expected a name, got {s}", .{state.typeName(2)});
        const call: Call = .of(state, "interfaces");
        const scope = Scope.of(call.context) orelse state.raise("{t} scripts have no interfaces yet", .{call.context.family});
        const entry = interfaces.find(scope, name) orelse {
            if (interfaces.builtinBase(call.context.family, name)) |ref| {
                _ = state.pushRef(ref);
                return 1;
            }
            state.pushNil();
            return 1;
        };
        _ = state.pushRef(entry.table);
        return 1;
    }

    fn set(state: *State) i32 {
        state.raise("interfaces are offered by returning interface_name and interface, not set", .{});
    }
};
