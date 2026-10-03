//! The `openreliant.hooks` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! the handlers that mods add to the hooks the engine declares (`engine.hooks`), and how they run.
//!
//! - `hooks.add(name, handler, filter)` adds a handler that runs before the hook's function, or
//!   when its event happens. `hooks.after(name, handler, filter)` adds one that runs after the
//!   function, which sees its result in `e.result`. Each returns a handle whose `remove` method
//!   removes the handler.
//! - A handler gets one value, `e`, with the hook's fields. Changing a field of a function's `e`
//!   changes what the function does; an event's fields can only be read.
//! - Handlers run newest mod first (the mod loaded last), and within a mod in the order they were
//!   added. A handler that returns `false` stops the call: the handlers after it don't run, and
//!   neither does the function, if it hasn't run yet, nor the handlers after it.
//! - `e:original()` runs the rest of the call at once: the handlers after this one, then the
//!   function, with the values in `e`. It returns the function's result, and the function doesn't
//!   run again once the handler returns.
//! - A filter limits a handler to the objects it's for: `{ object = handle }`, or a `type`, a
//!   `class` or a `side`, each a name or a list of them, or a function that gets `e` and returns
//!   true for a call it's for. The engine checks all but a function itself, without calling into
//!   Luau.
//! - A handler that raises an error is logged and removed, and the changes it made to `e` are
//!   undone.
//!
//! While hooks run, handlers that are added or removed only take effect once the outermost hook is
//! done, so that a hook's list of handlers doesn't change under it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.scripts);

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const engine_hooks = engine.hooks;
const Hook = engine_hooks.Hook;
const Object = engine_hooks.Object;
const gameobj = engine.game.gameobj;
const create = engine.game.create;
const luau = @import("luau.zig");
const State = luau.State;
const runtime_module = @import("runtime.zig");
const Runtime = runtime_module.Runtime;
const Context = runtime_module.Context;
const objects = @import("objects.zig");
const values = @import("values.zig");

/// The handlers mods have added, by hook.
pub const Hooks = struct {
    gpa: Allocator,
    runtime: *Runtime,
    /// What the engine reaches the scripts through, whose `hooked` follows the handlers here.
    scripts: *engine_hooks.Scripts,
    /// Each hook's handlers, in the order they run.
    handlers: std.EnumArray(Hook, std.ArrayList(Handler)) = .initFill(.empty),
    /// The handlers added while hooks run, which join their lists once the hooks are done.
    added: std.ArrayList(Added) = .empty,
    /// Whether handlers were removed while hooks ran.
    removed: bool = false,
    /// The hooks the game side runs whether or not they have handlers, for engine handlers of its
    /// own (`want`).
    wanted: std.EnumSet(Hook) = .initEmpty(),
    /// The hooks running, each inside the last.
    depth: u32 = 0,
    next_id: u32 = 1,

    pub fn init(gpa: Allocator, runtime: *Runtime, scripts: *engine_hooks.Scripts) Hooks {
        return .{ .gpa = gpa, .runtime = runtime, .scripts = scripts };
    }

    pub fn deinit(hooks: *Hooks) void {
        for (&hooks.handlers.values) |*list| {
            for (list.items) |*handler| handler.release(hooks.runtime);
            list.deinit(hooks.gpa);
        }
        for (hooks.added.items) |*added| added.handler.release(hooks.runtime);
        hooks.added.deinit(hooks.gpa);
        hooks.scripts.hooked = .initEmpty();
    }

    /// Registers the metatables of `e` and of the handles `add` returns.
    pub fn register(state: *State) void {
        state.registerUserdata(Event.tag, "hook", &.{
            .{ "__index", luau.wrap(eventField) },
            .{ "__newindex", luau.wrap(setEventField) },
            .{ "__tostring", luau.wrap(describeEvent) },
        });
        state.registerUserdata(Handle.tag, "hook_handle", &.{
            .{ "__index", luau.wrap(handleField) },
            .{ "__tostring", luau.wrap(describeHandle) },
        });
    }

    /// Pushes the `openreliant.hooks` package.
    pub fn push(hooks: *Hooks, state: *State) void {
        state.newTable(0, 2);
        state.pushClosure(luau.wrap(add), "add", hooks);
        state.rawSetField(-2, "add");
        state.pushClosure(luau.wrap(after), "after", hooks);
        state.rawSetField(-2, "after");
        state.setReadonly(-1, true);
    }

    /// Runs the handlers of `call.hook` (`engine.hooks.Scripts.VTable.call`).
    pub fn run(hooks: *Hooks, call: *engine_hooks.Call) void {
        const access = accesses.getPtrConst(call.hook);
        hooks.depth += 1;
        defer hooks.leave();
        var dispatch: Dispatch = .{ .hooks = hooks, .call = call, .access = access, .list = hooks.handlers.getPtr(call.hook).items };
        defer dispatch.finish();
        dispatch.before();
        if (dispatch.stopped) return;
        if (call.original) |function| if (!dispatch.ran) {
            function(call);
            dispatch.ran = true;
        };
        if (access.on == .function) dispatch.after();
    }

    /// Tells the handlers of `hook`, an event, that it has happened, with `fields`.
    pub fn tell(hooks: *Hooks, comptime hook: Hook, fields: engine_hooks.Fields(hook)) void {
        if (!hooks.scripts.hooked.contains(hook)) return;
        var told = fields;
        var call: engine_hooks.Call = .{ .scripts = hooks.scripts, .hook = hook, .fields = &told, .result = null, .original = null };
        hooks.run(&call);
    }

    /// Removes every handler the mod opened as `context` has added, as its scripts stop.
    pub fn removeContext(hooks: *Hooks, context: *const Context) void {
        for (&hooks.handlers.values) |*list| {
            for (list.items) |*handler| {
                if (handler.context == context) handler.removed = true;
            }
        }
        for (hooks.added.items) |*added| {
            if (added.handler.context == context) added.handler.removed = true;
        }
        hooks.removed = true;
        if (hooks.depth == 0) hooks.settle();
    }

    /// Has the engine run `hook` whatever its handlers.
    pub fn want(hooks: *Hooks, hook: Hook) void {
        hooks.wanted.insert(hook);
        hooks.scripts.hooked.insert(hook);
    }

    fn leave(hooks: *Hooks) void {
        hooks.depth -= 1;
        if (hooks.depth == 0) hooks.settle();
    }

    /// Once no hook runs: lets go of the handlers removed, adds those added meanwhile, and has the
    /// engine check each hook that has handlers.
    fn settle(hooks: *Hooks) void {
        if (!hooks.removed and hooks.added.items.len == 0) return;
        if (hooks.removed) {
            for (&hooks.handlers.values) |*list| {
                var kept: usize = 0;
                for (list.items) |*handler| {
                    if (handler.removed) {
                        handler.release(hooks.runtime);
                        continue;
                    }
                    list.items[kept] = handler.*;
                    kept += 1;
                }
                list.shrinkRetainingCapacity(kept);
            }
            hooks.removed = false;
        }
        for (hooks.added.items) |*added| {
            if (added.handler.removed) {
                added.handler.release(hooks.runtime);
                continue;
            }
            hooks.insert(added.hook, added.handler) catch {
                log.warn("{s}: no memory to add a handler of {t}", .{ added.handler.context.modOf().name, added.hook });
                added.handler.release(hooks.runtime);
            };
        }
        hooks.added.clearRetainingCapacity();
        var lists = hooks.handlers.iterator();
        while (lists.next()) |list| hooks.scripts.hooked.setPresent(list.key, list.value.items.len > 0 or hooks.wanted.contains(list.key));
    }

    /// Puts `handler` in `hook`'s list after the handlers of its own mod and of later ones.
    fn insert(hooks: *Hooks, hook: Hook, handler: Handler) Allocator.Error!void {
        const list = hooks.handlers.getPtr(hook);
        const at = for (list.items, 0..) |other, place| {
            if (other.context.mod < handler.context.mod) break place;
        } else list.items.len;
        try list.insert(hooks.gpa, at, handler);
    }

    /// Adds `handler` to `hook`'s list, or to those waiting while hooks run.
    fn addHandler(hooks: *Hooks, hook: Hook, handler: Handler) Allocator.Error!void {
        if (hooks.depth > 0) return hooks.added.append(hooks.gpa, .{ .hook = hook, .handler = handler });
        try hooks.insert(hook, handler);
        hooks.scripts.hooked.insert(hook);
    }

    /// Marks the handler `id` of `hook` removed. Returns false if it isn't there, as once removed.
    fn removeHandler(hooks: *Hooks, hook: Hook, id: u32) bool {
        const found = for (hooks.handlers.getPtr(hook).items) |*handler| {
            if (handler.id == id and !handler.removed) break handler;
        } else for (hooks.added.items) |*added| {
            if (added.handler.id == id and !added.handler.removed) break &added.handler;
        } else return false;
        found.removed = true;
        hooks.removed = true;
        if (hooks.depth == 0) hooks.settle();
        return true;
    }
};

/// A handler a mod added.
const Handler = struct {
    id: u32,
    /// The mod that added it, which it runs as.
    context: *Context,
    function: luau.Ref,
    when: When,
    filter: Filter,
    removed: bool = false,

    fn release(handler: *Handler, runtime: *Runtime) void {
        runtime.release(handler.function);
        if (handler.filter.function) |function| runtime.release(function);
    }
};

const Added = struct { hook: Hook, handler: Handler };

/// When a handler runs.
const When = enum {
    /// Before the function, or as the event happens (`hooks.add`).
    before,
    /// After the function (`hooks.after`).
    after,
};

/// The objects a handler is for. Each test that's set must hold.
const Filter = struct {
    object: ?objects.Handle = null,
    types: Few(gameobj.Type, max_types) = .{},
    classes: Few(create.ShipCombat.Class, max_classes) = .{},
    sides: Few(gameobj.Side(i32), max_sides) = .{},
    /// A function that gets `e`, and returns true for a call the handler is for.
    function: ?luau.Ref = null,

    /// The most types, classes and sides a filter lists.
    const max_types = 64;
    const max_classes = 16;
    const max_sides = 8;

    /// Whether it tests the object a hook concerns.
    fn testsObject(filter: *const Filter) bool {
        return filter.object != null or filter.types.len > 0 or filter.classes.len > 0 or filter.sides.len > 0;
    }

    /// Whether the object in slot `index` of `all` passes its tests.
    fn passes(filter: *const Filter, all: *const create.Objects, index: u16) bool {
        if (filter.object) |handle| if (handle.slot != index or !handle.valid(all)) return false;
        const slot = &all.slots[index];
        if (filter.types.len > 0 and !filter.types.has(slot.object.type)) return false;
        if (filter.classes.len > 0) {
            const combat = slot.combat orelse return false;
            if (!filter.classes.has(combat.class)) return false;
        }
        if (filter.sides.len > 0 and !filter.sides.has(slot.object.side)) return false;
        return true;
    }
};

/// Up to `capacity` values of `T`, kept in place.
fn Few(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        len: usize = 0,

        fn has(few: *const @This(), value: T) bool {
            return std.mem.indexOfScalar(T, few.items[0..few.len], value) != null;
        }
    };
}

/// One run of a hook's handlers.
const Dispatch = struct {
    hooks: *Hooks,
    call: *engine_hooks.Call,
    access: *const Access,
    list: []Handler,
    /// The next handler `before` looks at.
    next: usize = 0,
    /// Whether a handler has stopped the call.
    stopped: bool = false,
    /// Whether the function has run.
    ran: bool = false,
    /// Whether the handlers run before the function, or after it.
    stage: When = .before,
    /// `e`, made for the first handler that runs, and the reference that keeps it.
    event: ?*Event = null,
    event_ref: luau.Ref = undefined,

    /// Runs the handlers that run before the function, from the next, until one stops the call.
    fn before(dispatch: *Dispatch) void {
        while (dispatch.next < dispatch.list.len and !dispatch.stopped) {
            const handler = &dispatch.list[dispatch.next];
            dispatch.next += 1;
            if (handler.removed or handler.when != .before or !dispatch.wants(handler)) continue;
            const saved = dispatch.save();
            const ran = dispatch.ran;
            switch (dispatch.callHandler(handler)) {
                // Its changes are undone, unless the function ran with them.
                .failed => if (dispatch.ran == ran) dispatch.restore(saved),
                .returned_false => dispatch.stopped = true,
                .returned, .returned_nil => {},
            }
        }
    }

    /// Runs the handlers that run after the function, until one returns false.
    fn after(dispatch: *Dispatch) void {
        dispatch.stage = .after;
        for (dispatch.list) |*handler| {
            if (handler.removed or handler.when != .after or !dispatch.wants(handler)) continue;
            const saved = dispatch.save();
            switch (dispatch.callHandler(handler)) {
                .failed => dispatch.restore(saved),
                .returned_false => return,
                .returned, .returned_nil => {},
            }
        }
    }

    /// Whether `handler` is for this call: its filter's tests, then its function.
    fn wants(dispatch: *Dispatch, handler: *Handler) bool {
        const filter = &handler.filter;
        if (filter.testsObject()) {
            const subject = dispatch.access.subject orelse return false;
            const index = subject(dispatch.call.fields) orelse return false;
            const all = dispatch.hooks.runtime.objects orelse return false;
            if (!filter.passes(all, index)) return false;
        }
        const function = filter.function orelse return true;
        const event = dispatch.eventRef() orelse return false;
        return switch (dispatch.hooks.runtime.call(handler.context, function, .{event})) {
            .returned => true,
            .returned_nil, .returned_false => false,
            .failed => failed: {
                dispatch.drop(handler);
                break :failed false;
            },
        };
    }

    /// Calls `handler`, removing it if it fails. Where there's no memory for `e`, the handler is
    /// passed over as though it had failed, but kept.
    fn callHandler(dispatch: *Dispatch, handler: *Handler) runtime_module.Called {
        const event = dispatch.eventRef() orelse return .failed;
        const called = dispatch.hooks.runtime.call(handler.context, handler.function, .{event});
        if (called == .failed) dispatch.drop(handler);
        return called;
    }

    /// Removes a handler that failed.
    fn drop(dispatch: *Dispatch, handler: *Handler) void {
        log.warn("{s}: a handler of {s} failed, and is removed", .{ handler.context.modOf().name, dispatch.access.name });
        handler.removed = true;
        dispatch.hooks.removed = true;
    }

    /// The reference to `e`, made the first time; null where there's no memory for it.
    fn eventRef(dispatch: *Dispatch) ?luau.Ref {
        if (dispatch.event == null) dispatch.event_ref = dispatch.hooks.runtime.make(Event.make, .{dispatch}) orelse {
            // An `e` made without its reference is left to be collected, and never used.
            dispatch.event = null;
            return null;
        };
        return dispatch.event_ref;
    }

    /// Once the hook has run: `e` can't be used any more.
    fn finish(dispatch: *Dispatch) void {
        const event = dispatch.event orelse return;
        event.dispatch = null;
        dispatch.hooks.runtime.release(dispatch.event_ref);
    }

    const Saved = struct {
        fields: [max_fields_size]u8,
        result: [max_result_size]u8,
    };

    /// The fields and the result as they are, which `restore` puts back.
    fn save(dispatch: *const Dispatch) Saved {
        var saved: Saved = undefined;
        const access = dispatch.access;
        @memcpy(saved.fields[0..access.size], fieldBytes(dispatch.call, access));
        if (dispatch.call.result) |result| @memcpy(saved.result[0..access.result_size], @as([*]const u8, @ptrCast(result))[0..access.result_size]);
        return saved;
    }

    fn restore(dispatch: *const Dispatch, saved: Saved) void {
        const access = dispatch.access;
        @memcpy(fieldBytes(dispatch.call, access), saved.fields[0..access.size]);
        if (dispatch.call.result) |result| @memcpy(@as([*]u8, @ptrCast(result))[0..access.result_size], saved.result[0..access.result_size]);
    }

    fn fieldBytes(call: *const engine_hooks.Call, access: *const Access) []u8 {
        return @as([*]u8, @ptrCast(call.fields))[0..access.size];
    }
};

/// `e`, as a handler sees it: the run of the hook it belongs to, until the hook is done.
const Event = struct {
    dispatch: ?*Dispatch,

    const tag = @intFromEnum(runtime_module.Tag.hook_event);

    /// Pushes a new `e` for `dispatch` (`Runtime.make`).
    fn make(state: *State, dispatch: *Dispatch) void {
        const event = state.newUserdata(Event, tag);
        event.* = .{ .dispatch = dispatch };
        dispatch.event = event;
    }

    fn of(state: *State, at: i32) *Dispatch {
        const event = state.toUserdata(Event, at, tag) orelse state.raise("expected a hook's e, got {s}", .{state.typeName(at)});
        return event.dispatch orelse state.raise("e can only be used while its handler runs", .{});
    }
};

/// `e`'s `__index`: a field, `result`, or the method `original`.
fn eventField(state: *State) i32 {
    const dispatch = Event.of(state, 1);
    const key = state.toString(2) orelse state.raise("e: expected a field name, got {s}", .{state.typeName(2)});
    const access = dispatch.access;
    if (access.on == .function and std.mem.eql(u8, key, "original")) {
        state.pushFunction(luau.wrap(original), "original");
        return 1;
    }
    if (!access.push(state, dispatch.call, key)) state.raise("{s} has no field '{s}'", .{ access.name, key });
    return 1;
}

/// `e`'s `__newindex`: changes a field of a function's `e`, or its result.
fn setEventField(state: *State) i32 {
    const dispatch = Event.of(state, 1);
    const key = state.toString(2) orelse state.raise("e: expected a field name, got {s}", .{state.typeName(2)});
    const access = dispatch.access;
    const set = access.set orelse state.raise("{s} is an event, whose fields can't be changed", .{access.name});
    if (!set(state, dispatch.call, key, 3)) state.raise("{s} has no field '{s}'", .{ access.name, key });
    return 0;
}

fn describeEvent(state: *State) i32 {
    const event = state.toUserdata(Event, 1, Event.tag).?;
    const dispatch = event.dispatch orelse {
        state.pushString("e (done)");
        return 1;
    };
    var buffer: [80]u8 = undefined;
    state.pushString(std.fmt.bufPrint(&buffer, "e of {s}", .{dispatch.access.name}) catch "e");
    return 1;
}

/// `e:original()`: runs the rest of the call, the handlers after this one and then the function,
/// and returns the function's result.
fn original(state: *State) i32 {
    const dispatch = Event.of(state, 1);
    const run = dispatch.call.original orelse state.raise("{s} is an event, which has no original", .{dispatch.access.name});
    if (dispatch.ran or dispatch.stage == .after) state.raise("{s} has already run", .{dispatch.access.name});
    dispatch.before();
    if (dispatch.stopped) {
        state.pushNil();
        return 1;
    }
    run(dispatch.call);
    dispatch.ran = true;
    if (!dispatch.access.push(state, dispatch.call, "result")) state.pushNil();
    return 1;
}

/// What `hooks.add` returns.
const Handle = struct {
    hooks: *Hooks,
    hook: Hook,
    id: u32,

    const tag = @intFromEnum(runtime_module.Tag.hook_handle);
};

fn handleField(state: *State) i32 {
    const key = state.toString(2) orelse state.raise("expected a method name, got {s}", .{state.typeName(2)});
    if (!std.mem.eql(u8, key, "remove")) state.raise("a hook's handle has no field '{s}'", .{key});
    state.pushFunction(luau.wrap(removeHandle), "remove");
    return 1;
}

/// `handle:remove()`: removes the handler. Returns whether it was there.
fn removeHandle(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag) orelse state.raise("remove: expected a hook's handle, got {s}", .{state.typeName(1)});
    state.pushBoolean(handle.hooks.removeHandler(handle.hook, handle.id));
    return 1;
}

fn describeHandle(state: *State) i32 {
    const handle = state.toUserdata(Handle, 1, Handle.tag).?;
    var buffer: [80]u8 = undefined;
    state.pushString(std.fmt.bufPrint(&buffer, "handler of {t}", .{handle.hook}) catch "handler");
    return 1;
}

/// `hooks.add(name, handler, filter)`.
fn add(state: *State) i32 {
    return addAs(state, .before);
}

/// `hooks.after(name, handler, filter)`.
fn after(state: *State) i32 {
    return addAs(state, .after);
}

fn addAs(state: *State, comptime when: When) i32 {
    const hooks = state.upvalue(Hooks);
    const verb = switch (when) {
        .before => "hooks.add",
        .after => "hooks.after",
    };
    const context = state.threadData(Context) orelse state.raise("{s} can only be used by mod scripts", .{verb});
    const name = state.toString(1) orelse state.raise("{s}: expected a hook's name, got {s}", .{ verb, state.typeName(1) });
    const hook = std.meta.stringToEnum(Hook, name) orelse state.raise("{s}: there's no hook named '{s}' ('openreliant hooks' lists them)", .{ verb, name });
    const access = accesses.getPtrConst(hook);
    if (when == .after and access.on != .function) state.raise("hooks.after: {s} is an event; hooks.add adds its handlers", .{name});
    if (state.typeOf(2) != .function) state.raise("{s}: expected a function for the handler, got {s}", .{ verb, state.typeName(2) });
    var filter = readFilter(state, verb, access, 3);

    // Nothing can raise an error from here until the references are let go.
    filter.function = if (state.typeOf(3) == .function) state.ref(3) else null;
    const handler: Handler = .{ .id = hooks.next_id, .context = context, .function = state.ref(2), .when = when, .filter = filter };
    hooks.addHandler(hook, handler) catch {
        var dropped = handler;
        dropped.release(hooks.runtime);
        state.raise("{s}: out of memory", .{verb});
    };
    hooks.next_id +%= 1;
    const handle = state.newUserdata(Handle, Handle.tag);
    handle.* = .{ .hooks = hooks, .hook = hook, .id = handler.id };
    return 1;
}

/// The filter at `at`: nil, a function, or a table of tests. Raises an error for anything else.
fn readFilter(state: *State, comptime verb: []const u8, access: *const Access, at: i32) Filter {
    var filter: Filter = .{};
    switch (state.typeOf(at)) {
        .nil, .none, .function => return filter,
        .table => {},
        else => state.raise("{s}: expected a table or a function for the filter, got {s}", .{ verb, state.typeName(at) }),
    }
    if (access.subject == null) state.raise("{s}: {s} concerns no object to filter by", .{ verb, access.name });
    state.pushNil();
    while (state.next(at)) {
        const key = state.toString(-2) orelse state.raise("{s}: a filter's keys are names, not {s}", .{ verb, state.typeName(-2) });
        const test_name = std.meta.stringToEnum(Test, key) orelse state.raise("{s}: a filter has no test '{s}': it takes object, type, class and side", .{ verb, key });
        switch (test_name) {
            .object => filter.object = (state.toUserdata(objects.Handle, -1, objects.Handle.tag) orelse
                state.raise("{s}: a filter's object must be an object, not {s}", .{ verb, state.typeName(-1) })).*,
            .type => readList(state, verb, gameobj.Type, &filter.types),
            .class => readList(state, verb, create.ShipCombat.Class, &filter.classes),
            .side => readList(state, verb, gameobj.Side(i32), &filter.sides),
        }
        state.pop(1);
    }
    return filter;
}

/// The tests a filter's table can hold.
const Test = enum { object, type, class, side };

/// Reads the value on top, a name or a list of them, into `few`.
fn readList(state: *State, comptime verb: []const u8, comptime T: type, few: anytype) void {
    const label = verb ++ ": filter";
    if (state.typeOf(-1) != .table) return addTo(state, T, few, values.read(state, T, -1, label));
    const list = state.top();
    state.pushNil();
    while (state.next(list)) {
        addTo(state, T, few, values.read(state, T, -1, label));
        state.pop(1);
    }
}

fn addTo(state: *State, comptime T: type, few: anytype, value: T) void {
    if (few.len == few.items.len) state.raise("a filter lists at most {d} of each", .{few.items.len});
    few.items[few.len] = value;
    few.len += 1;
}

/// How the handlers of a hook reach its fields, whatever the hook.
const Access = struct {
    name: []const u8,
    on: engine_hooks.On,
    /// The slot of the object the call concerns, which filters test; null for a hook that concerns
    /// none.
    subject: ?*const fn (fields: *const anyopaque) ?u16,
    /// Pushes the field `key`, or `result`; false if there's none.
    push: *const fn (state: *State, call: *const engine_hooks.Call, key: []const u8) bool,
    /// Sets the field `key`, or `result`, to the value at `given`; false if there's none. Null for
    /// an event, whose fields can't be changed.
    set: ?*const fn (state: *State, call: *engine_hooks.Call, key: []const u8, given: i32) bool,
    /// The size of the fields, and of the result.
    size: usize,
    result_size: usize,
};

/// Each hook's `Access`.
const accesses: std.EnumArray(Hook, Access) = table: {
    @setEvalBranchQuota(std.enums.values(Hook).len * 2000);
    var table: std.EnumArray(Hook, Access) = .initUndefined();
    for (std.enums.values(Hook)) |hook| table.set(hook, accessOf(hook));
    break :table table;
};

/// The largest fields and result of any hook, which `Dispatch.save` keeps a copy of.
const max_fields_size = size: {
    var most: usize = 0;
    for (std.enums.values(Hook)) |hook| most = @max(most, @sizeOf(engine_hooks.Fields(hook)));
    break :size most;
};
const max_result_size = size: {
    var most: usize = 0;
    for (std.enums.values(Hook)) |hook| most = @max(most, @sizeOf(engine_hooks.Result(hook)));
    break :size most;
};

fn accessOf(comptime hook: Hook) Access {
    const declared = engine_hooks.declaration(hook);
    const F = declared.Fields;
    const R = declared.Result;
    const name = @tagName(hook);
    const Functions = struct {
        fn subject(fields: *const anyopaque) ?u16 {
            const held = @field(@as(*const F, @ptrCast(@alignCast(fields))).*, declared.subject.?);
            return switch (@TypeOf(held)) {
                Object => held.slot(),
                ?Object => if (held) |object| object.slot() else null,
                else => comptime unreachable,
            };
        }

        fn push(state: *State, call: *const engine_hooks.Call, key: []const u8) bool {
            const fields: *const F = @ptrCast(@alignCast(call.fields));
            inline for (comptime values.shownFields(F)) |field| {
                if (std.mem.eql(u8, key, field.name)) {
                    values.push(state, field.type, @field(fields.*, field.name));
                    return true;
                }
            }
            if (R != void and std.mem.eql(u8, key, "result")) {
                values.push(state, R, @as(*const R, @ptrCast(@alignCast(call.result.?))).*);
                return true;
            }
            return false;
        }

        fn set(state: *State, call: *engine_hooks.Call, key: []const u8, given: i32) bool {
            const fields: *F = @ptrCast(@alignCast(call.fields));
            inline for (comptime values.shownFields(F)) |field| {
                if (std.mem.eql(u8, key, field.name)) {
                    @field(fields.*, field.name) = values.read(state, field.type, given, name ++ "." ++ field.name);
                    return true;
                }
            }
            if (R != void and std.mem.eql(u8, key, "result")) {
                @as(*R, @ptrCast(@alignCast(call.result.?))).* = values.read(state, R, given, name ++ ".result");
                return true;
            }
            return false;
        }
    };
    return .{
        .name = name,
        .on = declared.on,
        .subject = if (declared.subject != null) Functions.subject else null,
        .push = Functions.push,
        .set = if (declared.on == .function) Functions.set else null,
        .size = @sizeOf(F),
        .result_size = @sizeOf(R),
    };
}
