//! Built-in interface groups (#558), assembled from existing API declarations. They contain no
//! engine logic and remain the base beneath ordinary mod interface overrides.

const std = @import("std");

const api = @import("api.zig");
const script = @import("script.zig");
const util = @import("util.zig");
const objects = @import("objects.zig");
const orders = @import("orders.zig");
const camera = @import("camera.zig");
const input = @import("input.zig");
const drawing = @import("drawing.zig");
const audio = @import("audio.zig");
const world = @import("world.zig");
const core = @import("core.zig");
const hooks = @import("hooks.zig");

const HookFunctions = struct {
    pub const add_hook = api.NativeTyped("`hooks.add`: adds a handler to the hook `name`.", hooks.add_type, forward("add"));
    pub const after_hook = api.NativeTyped("`hooks.after`: adds a handler that runs after the function `name`.", hooks.after_type, forward("after"));
};

fn forward(comptime name: [:0]const u8) fn (api.Call) i32 {
    return struct {
        fn run(call: api.Call) i32 {
            const state = call.state;
            if (call.context.family != .global and call.context.family != .object) call.raise("hook interfaces require game scripts", .{});
            const count = state.top();
            const package = call.runtime().packages.get(.hooks) orelse call.raise("hooks are unavailable in this context", .{});
            _ = state.pushRef(package);
            _ = state.rawGetField(-1, name);
            state.remove(-2);
            state.insert(1);
            if (state.protectedCall(count, 1) != .ok) state.raiseTop();
            return 1;
        }
    }.run;
}

pub const Group = enum {
    Flight,
    AI,
    Combat,
    Carriers,
    Camera,
    Controls,
    HUD,
    Audio,
    Missions,
    Campaign,
    FrontEnd,

    /// What a group offers: its functions and fields, the package whose fields it reads, and the
    /// families of scripts that may reach it.
    const Offer = struct {
        namespace: type,
        package: script.Package,
        families: []const script.Family,
    };

    const every_family = std.enums.values(script.Family);
    const game_scripts: []const script.Family = &.{ .global, .object };
    const player_scripts: []const script.Family = &.{.player};
    const presenting_scripts: []const script.Family = &.{ .player, .menu };
    const global_scripts: []const script.Family = &.{.global};

    fn offer(comptime group: Group) Offer {
        return switch (group) {
            .Flight => .{ .package = .util, .families = every_family, .namespace = struct {
                pub const to_world = util.package.to_world;
                pub const to_local = util.package.to_local;
                pub const look_at = util.package.look_at;
                pub const angle_off = util.package.angle_off;
                pub const turn = util.package.turn;
            } },
            .AI => .{ .package = .orders, .families = game_scripts, .namespace = struct {
                pub const register = orders.package.register;
                pub const info = orders.package.info;
                pub const stack = orders.package.stack;
                pub const cancel = orders.package.cancel;
                pub const clear = orders.package.clear;
                pub const give_order = objects.methods.give_order;
            } },
            .Combat => .{ .package = .hooks, .families = game_scripts, .namespace = HookFunctions },
            .Carriers => .{ .package = .orders, .families = game_scripts, .namespace = struct {
                pub const give_order = objects.methods.give_order;
                pub const start_launch = objects.methods.start_launch;
                pub const add_hook = HookFunctions.add_hook;
                pub const after_hook = HookFunctions.after_hook;
            } },
            .Camera => .{ .package = .camera, .families = player_scripts, .namespace = camera.package },
            .Controls => .{ .package = .input, .families = presenting_scripts, .namespace = input.package },
            .HUD => .{ .package = .hud, .families = player_scripts, .namespace = drawing.Package(.hud) },
            .Audio => .{ .package = .audio, .families = presenting_scripts, .namespace = audio.package },
            .Missions => .{ .package = .world, .families = global_scripts, .namespace = world.package },
            .Campaign => .{ .package = .world, .families = global_scripts, .namespace = struct {
                pub const mission = world.package.mission;
                pub const send_global_event = core.package.send_global_event;
            } },
            .FrontEnd => .{ .package = .ui, .families = presenting_scripts, .namespace = drawing.Package(.ui) },
        };
    }

    pub fn namespace(comptime group: Group) type {
        return group.offer().namespace;
    }

    /// Whether a script of `family` may reach the group.
    pub fn reachable(comptime group: Group, family: script.Family) bool {
        return std.mem.findScalar(script.Family, comptime group.offer().families, family) != null;
    }
};

pub fn push(state: *@import("luau.zig").State, comptime group: Group) void {
    // Field getters use the existing package machinery; their original Call checks still apply.
    api.pushPackage(state, comptime group.offer().package, group.namespace(), "I." ++ @tagName(group));
}
