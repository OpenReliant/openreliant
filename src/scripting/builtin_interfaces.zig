//! Built-in interface groups (#558), assembled from existing API declarations. They contain no
//! engine logic and remain the base beneath ordinary mod interface overrides.
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

const HookFunctions = struct {
    pub const add_hook = api.Native("Adds a handler through the existing hooks package.", "name: string, handler: (e: any) -> boolean?, filter: any?", "HookHandle", forward("add"));
    pub const after_hook = api.Native("Adds an after handler through the existing hooks package.", "name: string, handler: (e: any) -> boolean?, filter: any?", "HookHandle", forward("after"));
};

fn forward(comptime name: [:0]const u8) fn (*@import("luau.zig").State) i32 {
    return struct {
        fn run(state: *@import("luau.zig").State) i32 {
            const call = api.Call.of(state, "interface hook");
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
    Weapons,
    Carriers,
    Camera,
    Controls,
    HUD,
    Audio,
    Missions,
    Campaign,
    FrontEnd,

    pub fn namespace(comptime group: Group) type {
        return switch (group) {
            .Flight => struct {
                pub const to_world = util.package.to_world;
                pub const to_local = util.package.to_local;
                pub const look_at = util.package.look_at;
                pub const angle_off = util.package.angle_off;
                pub const turn = util.package.turn;
            },
            .AI => struct {
                pub const register = orders.package.register;
                pub const info = orders.package.info;
                pub const stack = orders.package.stack;
                pub const cancel = orders.package.cancel;
                pub const clear = orders.package.clear;
                pub const give_order = objects.methods.give_order;
            },
            .Combat, .Weapons => HookFunctions,
            .Carriers => struct {
                pub const give_order = objects.methods.give_order;
                pub const add_hook = HookFunctions.add_hook;
                pub const after_hook = HookFunctions.after_hook;
            },
            .Camera => camera.package,
            .Controls => input.package,
            .HUD => drawing.Package(.hud),
            .Audio => audio.package,
            .Missions => world.package,
            .Campaign => struct {
                pub const mission = world.package.mission;
                pub const send_global_event = core.package.send_global_event;
            },
            .FrontEnd => drawing.Package(.ui),
        };
    }

    pub fn reachable(group: Group, family: script.Family) bool {
        return switch (group) {
            .Flight => true,
            .AI, .Combat, .Weapons, .Carriers => family == .global or family == .object,
            .Camera, .HUD => family == .player,
            .Controls, .Audio, .FrontEnd => family == .player or family == .menu,
            .Missions, .Campaign => family == .global,
        };
    }
};

pub fn push(state: *@import("luau.zig").State, comptime group: Group) void {
    // Field getters use the existing package machinery; their original Call checks still apply.
    api.pushPackage(state, switch (group) {
        .Flight => .util,
        .AI, .Carriers => .orders,
        .Combat, .Weapons => .hooks,
        .Camera => .camera,
        .Controls => .input,
        .HUD => .hud,
        .Audio => .audio,
        .Missions, .Campaign => .world,
        .FrontEnd => .ui,
    }, group.namespace());
}
