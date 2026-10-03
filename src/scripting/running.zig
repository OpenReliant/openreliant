//! What the game's scripts and the presentation's share
//! ([#498](https://github.com/OpenReliant/openreliant/issues/498)): the scripts that run, kept in
//! lists (`Runner`): starting them, calling their engine handlers, delivering their events, and
//! stopping them.
//!
//! A script that stops while engine handlers are being called is only marked, and leaves its list
//! once the calls are done (`Runner.sweep`), so no list changes under a call. As the last of a
//! mod's scripts in one context stops, the context closes, and the hooks and interfaces its scripts
//! added go with it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.scripts);

const luau = @import("luau.zig");
const State = luau.State;
const script = @import("script.zig");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const Context = runtime.Context;
const hooks = @import("hooks.zig");
const values = @import("values.zig");
const data = @import("data.zig");
const events = @import("events.zig");
const interfaces = @import("interfaces.zig");
const async_module = @import("async.zig");
const Name = runtime.Name;

/// A script that runs.
pub const Running = struct {
    context: *Context,
    /// Its file's name, as its mod has it.
    name: []const u8,
    offered: runtime.Offered,
    /// Whether it's a mission's, which stops as its mission ends.
    mission: bool = false,
    /// Whether it has stopped, and waits for the calls walking its list to finish (`Runner.sweep`).
    stopped: bool = false,
};

/// The scripts that run in one place, in the order they started.
pub const List = std.ArrayList(Running);

/// A timer waiting to run the function its mod registered under `name` (`async.zig`).
pub const Timer = struct {
    context: *Context,
    name: Name,
    /// The seconds left until it runs.
    left: f64,
    /// What it passes the function, held in the state; null for nil.
    data: ?luau.Ref,
    /// The round of `Runner.advance` it was started in, which runs only those started before it.
    round: u32 = 0,
};

/// The scripts of one side, in their lists, with their events and interfaces.
pub const Runner = struct {
    gpa: Allocator,
    runtime: *Runtime,
    /// Every list of scripts of the side, which a sweep goes through.
    lists: []List,
    events: events.Events,
    interfaces: interfaces.Interfaces,
    /// The hooks the scripts add handlers to; null for the presentation side, which has none yet.
    hooks: ?*hooks.Hooks = null,
    /// The timers waiting, in the order they were started.
    timers: std.ArrayList(Timer) = .empty,
    /// How many times `advance` has run, which tells the timers it runs from those started since.
    round: u32 = 0,
    /// How many calls walk the lists, whose stopped scripts wait for them.
    walking: u32 = 0,
    /// Whether a script stopped while calls walked the lists.
    stopped: bool = false,

    pub fn init(gpa: Allocator, scripts: *Runtime, lists: []List) Runner {
        return .{
            .gpa = gpa,
            .runtime = scripts,
            .lists = lists,
            .events = .{ .gpa = gpa, .runtime = scripts },
            .interfaces = .{ .gpa = gpa, .runtime = scripts },
        };
    }

    /// Stops every script and lets go of the lists.
    pub fn deinit(runner: *Runner) void {
        for (runner.lists) |*list| runner.stopAll(list);
        for (runner.lists) |*list| list.deinit(runner.gpa);
        for (runner.timers.items) |timer| if (timer.data) |ref| runner.runtime.release(ref);
        runner.timers.deinit(runner.gpa);
        runner.events.deinit();
        runner.interfaces.deinit();
    }

    /// Adds `timer`, which then holds its data's reference.
    pub fn addTimer(runner: *Runner, timer: Timer) error{ OutOfMemory, TooMany }!void {
        if (runner.timers.items.len == async_module.max_timers) return error.TooMany;
        var started = timer;
        started.round = runner.round;
        try runner.timers.append(runner.gpa, started);
    }

    /// Moves the timers on by `seconds`, and runs those whose time has come, soonest first, each
    /// once. Timers started meanwhile wait for the next.
    pub fn advance(runner: *Runner, seconds: f64) void {
        for (runner.timers.items) |*timer| timer.left -= seconds;
        // The timers this call's functions start belong to the round after it.
        runner.round +%= 1;
        while (true) {
            var soonest: ?usize = null;
            for (runner.timers.items, 0..) |timer, at| {
                if (timer.round == runner.round or timer.left > 0) continue;
                if (soonest == null or timer.left < runner.timers.items[soonest.?].left) soonest = at;
            }
            const at = soonest orelse return;
            runner.fire(runner.timers.orderedRemove(at));
        }
    }

    /// Runs the function `timer` names, and lets go of its data.
    fn fire(runner: *Runner, timer: Timer) void {
        defer if (timer.data) |ref| runner.runtime.release(ref);
        const context = timer.context;
        if (context.closed) return;
        const name = timer.name.slice();
        const callbacks = context.callbacks orelse return missingCallback(context, name);
        runner.walking += 1;
        defer runner.leave();
        const called = runner.runtime.callIn(context, callbacks, name, .{timer.data}) orelse return missingCallback(context, name);
        if (called == .failed) log.warn("{s}: the timer {s} failed", .{ context.modOf().name, name });
    }

    fn missingCallback(context: *const Context, name: []const u8) void {
        log.warn("{s}: a timer names {s}, which no script registered (async.register_timer)", .{ context.modOf().name, name });
    }

    /// Runs the script `name` of the mod opened as `context`, keeps what it offers in `list`, and
    /// calls its `on_init` with `payload` unless it's `loading`, as a saved game's scripts start
    /// (`snapshot.restore`), then, for an object script, its `on_added`. Returns where it went in
    /// `list`; null for a script that fails, which is logged and left out. `payload` goes with the
    /// script.
    pub fn start(runner: *Runner, list: *List, context: *Context, name: []const u8, mission: bool, payload: ?data.Data, loading: bool) Allocator.Error!?usize {
        defer if (payload) |given| runner.runtime.release(given.ref);
        const mod = context.modOf();
        const returned = runner.runtime.run(context, name) orelse return null;
        defer runner.runtime.release(returned);
        var offered = context.offerOf(name, returned) orelse return null;
        list.append(runner.gpa, .{ .context = context, .name = name, .offered = offered, .mission = mission }) catch |err| {
            offered.release(runner.runtime);
            return err;
        };
        const at = list.items.len - 1;
        inline for (comptime std.enums.values(script.Handler)) |handler| {
            if (comptime script.Handler.Arguments(handler) == null) {
                if (offered.handlers.get(handler) != null) log.warn("{s}: {s}: this version of OpenReliant doesn't call {t} yet", .{ mod.name, name, handler });
            }
        }
        log.info("{s}: started {s}", .{ mod.name, name });
        if (offered.interface) |interface| {
            if (try runner.interfaces.offer(context, interface.name, interface.table)) |base| {
                runner.callOne(list, at, .on_interface_override, .{ .base = .{ .ref = base } });
            }
        }
        if (!loading) runner.callOne(list, at, .on_init, .{ .data = payload });
        if (context.family == .object) runner.callOne(list, at, .on_added, .{});
        return at;
    }

    /// Calls the engine handler `handler` of the script at `at` in `list` with `arguments`.
    pub fn callOne(runner: *Runner, list: *List, at: usize, comptime handler: script.Handler, arguments: script.Handler.Arguments(handler).?) void {
        var made: Made = .{};
        defer made.release(runner.runtime);
        const passed = made.pass(runner.runtime, arguments) orelse return;
        runner.walking += 1;
        defer runner.leave();
        runner.callPassed(list, at, handler, passed);
    }

    /// Calls `handler` of each running script of `list` with `arguments`, in order. Scripts that
    /// start meanwhile are called too.
    pub fn callEach(runner: *Runner, list: *List, comptime handler: script.Handler, arguments: script.Handler.Arguments(handler).?) void {
        if (list.items.len == 0) return;
        var made: Made = .{};
        defer made.release(runner.runtime);
        const passed = made.pass(runner.runtime, arguments) orelse return;
        runner.walking += 1;
        defer runner.leave();
        var at: usize = 0;
        while (at < list.items.len) : (at += 1) runner.callPassed(list, at, handler, passed);
    }

    /// `callEach`, for every list in order.
    pub fn callAll(runner: *Runner, comptime handler: script.Handler, arguments: script.Handler.Arguments(handler).?) void {
        runner.walking += 1;
        defer runner.leave();
        for (runner.lists) |*list| runner.callEach(list, handler, arguments);
    }

    fn callPassed(runner: *Runner, list: *List, at: usize, comptime handler: script.Handler, passed: anytype) void {
        const running = &list.items[at];
        if (running.stopped) return;
        const function = running.offered.handlers.get(handler) orelse return;
        if (runner.runtime.call(running.context, function, passed) != .failed) return;
        // The call may have added scripts to the list, which moves it.
        const failed = &list.items[at];
        log.warn("{s}: {s}: {t} failed, and isn't called again", .{ failed.context.modOf().name, failed.name, handler });
        runner.runtime.release(function);
        failed.offered.handlers.set(handler, null);
    }

    /// Ends a walk of the lists, sweeping them once the last walk is done.
    pub fn leave(runner: *Runner) void {
        runner.walking -= 1;
        if (runner.walking == 0 and runner.stopped) runner.sweep();
    }

    /// Stops the script at `at` in `list`: lets go of what it offered, and closes its mod's context
    /// once none of its scripts there runs. It leaves the list once no call walks it (`sweep`).
    pub fn stopScript(runner: *Runner, list: *List, at: usize) void {
        const running = &list.items[at];
        if (running.stopped) return;
        running.stopped = true;
        running.offered.release(runner.runtime);
        const context = running.context;
        const shared = for (list.items) |*other| {
            if (!other.stopped and other.context == context) break true;
        } else false;
        if (!shared) runner.closeContext(context);
        runner.stopped = true;
        if (runner.walking == 0) runner.sweep();
    }

    /// Stops every script of `list`.
    pub fn stopAll(runner: *Runner, list: *List) void {
        runner.walking += 1;
        defer runner.leave();
        for (0..list.items.len) |at| runner.stopScript(list, at);
    }

    /// Closes a mod opened for scripts that have all stopped: their hooks and interfaces go.
    pub fn closeContext(runner: *Runner, context: *Context) void {
        if (runner.hooks) |held| held.removeContext(context);
        runner.interfaces.removeContext(context);
        var kept: usize = 0;
        for (runner.timers.items) |timer| {
            if (timer.context == context) {
                if (timer.data) |ref| runner.runtime.release(ref);
                continue;
            }
            runner.timers.items[kept] = timer;
            kept += 1;
        }
        runner.timers.shrinkRetainingCapacity(kept);
        runner.runtime.close(context);
    }

    /// Takes the stopped scripts out of their lists.
    fn sweep(runner: *Runner) void {
        for (runner.lists) |*list| {
            var kept: usize = 0;
            for (list.items) |running| {
                if (running.stopped) continue;
                list.items[kept] = running;
                kept += 1;
            }
            list.shrinkRetainingCapacity(kept);
        }
        runner.stopped = false;
    }

    /// Calls the handlers of `list` for the event `sent`, newest mod first, and within a mod in the
    /// order its scripts started.
    pub fn deliverTo(runner: *Runner, list: *List, sent: *const events.Pending) void {
        runner.walking += 1;
        defer runner.leave();
        const name = sent.name.slice();
        var mod = runner.runtime.mods.len;
        while (mod > 0) {
            mod -= 1;
            var at: usize = 0;
            while (at < list.items.len) : (at += 1) {
                const running = &list.items[at];
                if (running.stopped or running.context.mod != mod) continue;
                const table = running.offered.event_handlers orelse continue;
                const called = runner.runtime.callIn(running.context, table, name, .{sent.data.ref}) orelse continue;
                switch (called) {
                    .returned_false => return,
                    .failed => log.warn("{s}: {s}: the handler of the event {s} failed", .{ list.items[at].context.modOf().name, list.items[at].name, name }),
                    .returned, .returned_nil => {},
                }
            }
        }
    }
};

/// The values made to pass an engine handler its arguments, let go once it has been called.
const Made = struct {
    refs: [max_made]luau.Ref = undefined,
    len: usize = 0,

    /// The most arguments a handler takes that are made rather than pushed as they are.
    const max_made = 4;

    fn release(made: *Made, scripts: *Runtime) void {
        for (made.refs[0..made.len]) |ref| scripts.release(ref);
    }

    /// The arguments `Runtime.call` takes for `arguments`: numbers as they are, and a reference to
    /// each value made for the others. Null if one can't be made.
    fn pass(made: *Made, scripts: *Runtime, arguments: anytype) ?Passed(@TypeOf(arguments)) {
        const Arguments = @TypeOf(arguments);
        var passed: Passed(Arguments) = undefined;
        inline for (@typeInfo(Arguments).@"struct".fields, 0..) |field, at| {
            const value = @field(arguments, field.name);
            passed[at] = switch (comptime passing(field.type)) {
                .number => value,
                .optional_data => if (value) |given| given.ref else null,
                .table => value.ref,
                .made => ref: {
                    const ref = scripts.make(Push(field.type).push, .{value}) orelse return null;
                    made.refs[made.len] = ref;
                    made.len += 1;
                    break :ref ref;
                },
            };
        }
        return passed;
    }

    /// How an argument of `T` is passed.
    const Passing = enum { number, optional_data, table, made };

    fn passing(comptime T: type) Passing {
        if (T == ?data.Data) return .optional_data;
        if (T == values.Table) return .table;
        return switch (@typeInfo(T)) {
            .float, .int => .number,
            else => .made,
        };
    }

    /// The tuple `pass` gives for a handler's `Arguments`.
    fn Passed(comptime Arguments: type) type {
        const fields = @typeInfo(Arguments).@"struct".fields;
        var types: [fields.len]type = undefined;
        for (&types, fields) |*passed, field| passed.* = switch (passing(field.type)) {
            .number => field.type,
            .optional_data => ?luau.Ref,
            .table, .made => luau.Ref,
        };
        return @Tuple(&types);
    }

    /// What pushes a value of `T` (`Runtime.make`).
    fn Push(comptime T: type) type {
        return struct {
            fn push(state: *State, value: T) void {
                values.push(state, T, value);
            }
        };
    }
};
