//! The `openreliant.async` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! timers (`package`). A script registers a function under a name (`async.register_timer`), and a
//! timer names the function it runs (`async.after`), so that a timer can be kept with a saved game
//! and run after it's loaded, once the script has registered its functions again.
//!
//! A timer counts the seconds its side sees pass: game time for global and object scripts, which
//! stops while the game is paused and between missions (`on_update`), and real time for player and
//! menu scripts (`on_frame`). The timers of an object's scripts go with the object.

const luau = @import("luau.zig");
const State = luau.State;
const runtime_module = @import("runtime.zig");
const Name = runtime_module.Name;
const api = @import("api.zig");
const Call = api.Call;
const data = @import("data.zig");

/// The most timers a side keeps waiting.
pub const max_timers = 4096;

/// What `openreliant.async` holds.
pub const package = struct {
    pub const register_timer = api.Native("Registers `handler` under `name` for the script's mod, for timers to run. Register it as the script runs, so that a timer kept with a saved game finds it again after the game is loaded.", "name: string, handler: (data: any) -> ()", api.nothing, registerTimer);
    pub const after = api.Function("Runs the function registered under `name` once `seconds` have passed, with `data`, which must be plain data: seconds of game time for global and object scripts, and of real time for player and menu scripts.", &.{ "seconds", "name", "data" }, startTimer);
};

/// `async.register_timer(name, handler)`.
fn registerTimer(state: *State) i32 {
    const call: Call = .of(state, "async.register_timer");
    const name = state.toString(1) orelse state.raise("async.register_timer: expected a name, got {s}", .{state.typeName(1)});
    const key = Name.of(name) orelse state.raise("async.register_timer: a name has at most {d} bytes", .{runtime_module.max_name});
    if (state.typeOf(2) != .function) state.raise("async.register_timer: expected a function, got {s}", .{state.typeName(2)});
    const context = call.context;
    if (context.callbacks == null) {
        state.newTable(0, 0);
        context.callbacks = state.ref(-1);
        state.pop(1);
    }
    _ = state.pushRef(context.callbacks.?);
    state.pushCopy(2);
    state.rawSetField(-2, key.slice());
    state.pop(1);
    return 0;
}

/// `async.after(seconds, name, data)`.
fn startTimer(call: Call, seconds: f32, name: []const u8, payload: ?data.Data) void {
    const scripts = call.runtime();
    const runner = scripts.runner orelse {
        if (payload) |given| scripts.release(given.ref);
        call.raise("async.after: timers only run while scripts do", .{});
    };
    const held = Name.of(name) orelse {
        if (payload) |given| scripts.release(given.ref);
        call.raise("async.after: a name has at most {d} bytes", .{runtime_module.max_name});
    };
    runner.addTimer(.{ .context = call.context, .name = held, .left = @max(seconds, 0), .data = if (payload) |given| given.ref else null }) catch {
        if (payload) |given| scripts.release(given.ref);
        call.raise("async.after: at most {d} timers can wait", .{max_timers});
    };
}
