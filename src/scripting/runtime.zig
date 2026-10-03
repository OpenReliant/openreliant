//! The Luau state that mod scripts run in
//! ([#498](https://github.com/OpenReliant/openreliant/issues/498)): the sandbox, the time and
//! memory limits, loading each mod's scripts, and `require`.
//!
//! A mod's scripts are compiled once, the first time the mod is opened, and kept as bytecode
//! (`Code`). Each opening of the mod (`Context`), such as the one for each object a mod's object
//! scripts run on, loads its own copy of a script as it requires it, with its own global table. So
//! scripts can't see each other's globals, and an object's scripts can't see another object's.
//! `require` runs a script once for its context and returns its result. It accepts another script
//! from the same mod, by file name with or without the extension and in any case, or an
//! OpenReliant package (`script.Package`). Compile errors are logged when the mod is first opened,
//! and raised again when the script is required.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.scripts);

const openreliant = @import("openreliant");
const mods = openreliant.engine.game.bigfile.mods;
const Mod = mods.Mod;
const Objects = openreliant.engine.game.create.Objects;
const aigeneric = openreliant.engine.game.aigeneric;
const luau = @import("luau.zig");
const State = luau.State;
const script = @import("script.zig");
const values = @import("values.zig");
const objects = @import("objects.zig");
const game_module = @import("game.zig");
const presentation_module = @import("presentation.zig");
const storage_module = @import("storage.zig");
const running_module = @import("running.zig");
const stored = @import("stored.zig");
const bigfile = openreliant.engine.game.bigfile;

/// The userdata tags, one per kind of userdata, each with its own metatable.
pub const Tag = enum(luau.Tag) {
    /// A record, or a struct or array inside one (`records.Values`).
    record_value = 1,
    /// A table of records, such as the ships (`records.Set`).
    record_set = 2,
    /// An object's handle (`objects.Handle`).
    object = 3,
    /// What a hook's handler sees as `e` (`hooks.Event`).
    hook_event = 4,
    /// What `hooks.add` returns (`hooks.Handle`).
    hook_handle = 5,
    /// The package `openreliant.interfaces` (`interfaces.Interfaces`).
    interfaces = 6,
    /// A section of a mod's storage (`storage.zig`).
    section = 7,
};

/// Which part of the game a state runs scripts for.
pub const Side = enum {
    /// Load, global and object scripts, which affect what happens in the game. They have no `os`
    /// library, and `math.random` uses a seeded generator so every machine gets the same numbers.
    game,
    /// Player and menu scripts, which affect what each player sees and hears.
    presentation,
};

/// Resource limits for scripts.
pub const Limits = struct {
    /// How long a single call into a script may run.
    time: Io.Duration,
    /// How much memory one mod's scripts may use.
    memory: usize,
};

pub const Options = struct {
    side: Side,
    limits: Limits,
    /// The seed for `math.random` on the game side.
    seed: u64,
    /// OpenReliant's version, such as `0.7.0` (`core.package.version`).
    version: []const u8,
    shared: Shared = .{},
};

/// What every state shares.
pub const Shared = struct {
    /// The mods' storage (`storage.zig`); null where it isn't kept.
    storage: ?*storage_module.Storage = null,
    /// The game's files, as the game reads them, mods first (`vfs.zig`); null where there are none.
    files: ?bigfile.Hog = null,
};

/// The interrupt callback reads the clock on every this many calls, since reading it on every call
/// would be slow.
const interrupt_stride = 64;

/// Luau supports 256 memory categories: 0 for the engine and one per mod. Mods past the 255th
/// share the last one.
const max_category = 255;

/// The longest module name and chunk name.
const max_module_name = 255;
const max_chunk_name = 255;

/// Marks a module as currently loading in `Context.loaded`, to detect circular requires.
var loading: u8 = 0;

pub const Runtime = struct {
    gpa: Allocator,
    io: Io,
    state: *State,
    options: Options,
    /// The mods, in load order.
    mods: []const Mod,
    /// The value `require` returns for each package, if set (`setPackage`).
    packages: std.EnumArray(script.Package, ?luau.Ref) = .initFill(null),
    /// The opened mods (`open`).
    contexts: std.ArrayList(*Context) = .empty,
    /// Each mod's scripts compiled, by the mod's index in `mods`, once it has been opened.
    code: std.AutoHashMapUnmanaged(u16, Code) = .empty,
    random: std.Random.DefaultPrng,
    /// The call in progress, if any (`begin`).
    running: ?Running = null,
    /// Interrupt calls since the clock was last read.
    interrupts: u32 = 0,
    /// The objects that handles stand for, while a game runs (`objects.zig`).
    objects: ?*Objects = null,
    /// The game the scripts run in, while one runs, for the game side.
    game: ?*game_module.Game = null,
    /// The presentation side, for its own state.
    presentation: ?*presentation_module.Presentation = null,
    /// What orders run against, while a mission runs.
    orders: ?aigeneric.Context = null,
    /// The scripts that run in the state, with their events, interfaces and timers.
    runner: ?*running_module.Runner = null,
    /// The handles made, by slot (`objects.zig`).
    handles: ?luau.Ref = null,

    const Running = struct {
        /// The memory category of the running mod.
        category: u8,
        started: Io.Clock.Timestamp,
    };

    /// Creates a sandboxed state with Luau's standard libraries and OpenReliant's `require` and
    /// `print`.
    pub fn create(gpa: Allocator, io: Io, opened: []const Mod, options: Options) Allocator.Error!*Runtime {
        const runtime = try gpa.create(Runtime);
        errdefer gpa.destroy(runtime);
        runtime.* = .{ .gpa = gpa, .io = io, .state = undefined, .options = options, .mods = opened, .random = .init(options.seed) };
        runtime.state = State.create(allocate, runtime) orelse return error.OutOfMemory;
        const state = runtime.state;
        state.setCallbackData(runtime);
        state.setInterrupt(interrupt);
        state.inheritThreadData();
        state.openLibraries();
        state.pushFunction(luau.wrap(require), "require");
        state.setGlobal("require");
        state.pushFunction(luau.wrap(print), "print");
        state.setGlobal("print");
        storage_module.Storage.register(state);
        if (options.side == .game) {
            state.pushNil();
            state.setGlobal("os");
            _ = state.getGlobal("math");
            state.pushFunction(luau.wrap(random), "random");
            state.rawSetField(-2, "random");
            state.pushNil();
            state.rawSetField(-2, "randomseed");
            state.pop(1);
        }
        state.sandbox();
        return runtime;
    }

    pub fn destroy(runtime: *Runtime) void {
        runtime.state.close();
        for (runtime.contexts.items) |context| runtime.gpa.destroy(context);
        runtime.contexts.deinit(runtime.gpa);
        var code = runtime.code.valueIterator();
        while (code.next()) |held| held.deinit(runtime.gpa);
        runtime.code.deinit(runtime.gpa);
        runtime.gpa.destroy(runtime);
    }

    /// Releases a reference so its value can be collected.
    pub fn release(runtime: *Runtime, kept: luau.Ref) void {
        runtime.state.unref(kept);
    }

    /// Pops a value and makes it what `require` returns for `package`.
    pub fn setPackage(runtime: *Runtime, package: script.Package) void {
        runtime.packages.set(package, runtime.state.ref(-1));
        runtime.state.pop(1);
    }

    /// Opens a mod for scripts of `family`, so that they can be required. `mod` is the mod's index
    /// in `mods`. An object script's context names its object (`object`). The mod's scripts are
    /// compiled the first time it's opened (`compiled`).
    pub fn open(runtime: *Runtime, mod: u16, family: script.Family, object: ?objects.Handle) Allocator.Error!*Context {
        _ = try runtime.compiled(mod);
        const state = runtime.state;
        const context = try runtime.gpa.create(Context);
        errdefer runtime.gpa.destroy(context);
        try runtime.contexts.ensureUnusedCapacity(runtime.gpa, 1);
        if (!state.checkStack(context_stack)) return error.OutOfMemory;
        const thread = state.newThread();
        context.* = .{ .runtime = runtime, .mod = mod, .family = family, .object = object, .thread = thread, .thread_ref = state.ref(-1) };
        state.pop(1);
        thread.setThreadData(context);
        thread.setMemoryCategory(context.category());
        state.newTable(0, 0);
        context.loaded = state.ref(-1);
        state.pop(1);
        runtime.contexts.appendAssumeCapacity(context);
        return context;
    }

    /// The scripts of mod `mod` compiled, compiling them the first time. A script that doesn't
    /// compile is logged, and kept, so that requiring it raises its error.
    fn compiled(runtime: *Runtime, mod: u16) Allocator.Error!*const Code {
        const entry = try runtime.code.getOrPut(runtime.gpa, mod);
        if (entry.found_existing) return entry.value_ptr;
        entry.value_ptr.* = runtime.compile(mod) catch |err| {
            runtime.code.removeByPtr(entry.key_ptr);
            return err;
        };
        return entry.value_ptr;
    }

    /// Reads and compiles the scripts of the folder mods compiled so far again, as they're
    /// reloaded: the scripts that start from then on, and the modules `require` runs, take the
    /// new code. A mod's archive doesn't change while OpenReliant runs.
    pub fn recompileFolders(runtime: *Runtime) Allocator.Error!void {
        var entries = runtime.code.iterator();
        while (entries.next()) |entry| {
            if (runtime.mods[entry.key_ptr.*].source != .folder) continue;
            const code = try runtime.compile(entry.key_ptr.*);
            entry.value_ptr.deinit(runtime.gpa);
            entry.value_ptr.* = code;
        }
    }

    /// Reads and compiles the scripts of `mod`.
    fn compile(runtime: *Runtime, mod: u16) Allocator.Error!Code {
        var code: Code = .{};
        errdefer code.deinit(runtime.gpa);
        const opened = &runtime.mods[mod];
        var names = opened.scripts();
        while (names.next()) |name| {
            var module_buffer: [max_module_name:0]u8 = undefined;
            const module = moduleName(&module_buffer, name) orelse {
                log.warn("{s}: skipping {s}: the name is too long", .{ opened.name, name });
                continue;
            };
            const source = opened.readFile(runtime.gpa, name) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => {
                    log.warn("{s}: skipping {s}: {s}", .{ opened.name, name, @errorName(err) });
                    continue;
                },
            } orelse continue;
            defer runtime.gpa.free(source);
            const bytecode = luau.compile(source) orelse return error.OutOfMemory;
            errdefer bytecode.free();
            var chunk_buffer: [max_chunk_name:0]u8 = undefined;
            const chunk = std.fmt.bufPrintZ(&chunk_buffer, "={s}/{s}", .{ opened.name, name }) catch "=script";
            try code.add(runtime.gpa, module, chunk, bytecode);
            runtime.check(chunk, bytecode.bytes);
        }
        return code;
    }

    /// Loads `bytecode` once to log its compile error, if it has one.
    fn check(runtime: *Runtime, chunk: [:0]const u8, bytecode: []const u8) void {
        const state = runtime.state;
        var request: LoadRequest = .{ .chunk = chunk, .bytecode = bytecode };
        if (state.protectedCallC(luau.wrap(checkChunk), &request) != .ok) {
            log.warn("{s}: out of memory checking the script", .{chunk[1..]});
            state.pop(1);
        }
    }

    /// Closes a mod opened for scripts that stop before the others, such as a mission's: its
    /// scripts can be collected, and it can't be called again. The context itself stays until the
    /// runtime is destroyed, since coroutines its scripts made may still point to it.
    pub fn close(runtime: *Runtime, context: *Context) void {
        if (context.closed) return;
        context.closed = true;
        const state = runtime.state;
        state.unref(context.loaded);
        state.unref(context.thread_ref);
        if (context.callbacks) |callbacks| state.unref(callbacks);
        context.callbacks = null;
        if (context.console) |console| state.unref(console);
        context.console = null;
    }

    /// Makes a value in protected mode, with `build` and its `arguments` pushing it, and returns a
    /// reference to it, or null if memory runs out. The value is the engine's, so it counts
    /// against no mod's memory.
    pub fn make(runtime: *Runtime, comptime build: anytype, arguments: anytype) ?luau.Ref {
        const Request = struct {
            arguments: @TypeOf(arguments),
            made: ?luau.Ref = null,

            fn run(state: *State) i32 {
                const request = state.toLightUserdata(@This(), 1).?;
                @call(.auto, build, .{state} ++ request.arguments);
                request.made = state.ref(-1);
                state.pop(1);
                return 0;
            }
        };
        var request: Request = .{ .arguments = arguments };
        const outer = runtime.running;
        runtime.running = null;
        defer runtime.running = outer;
        if (runtime.state.protectedCallC(luau.wrap(Request.run), &request) != .ok) {
            runtime.state.pop(1);
            return null;
        }
        return request.made;
    }

    /// Starts `math.random` on the game side again from `seed`.
    pub fn reseed(runtime: *Runtime, seed: u64) void {
        runtime.random = .init(seed);
    }

    /// Runs the script `name` like `require` does, and returns a reference to its result. Returns
    /// null if the script fails; the error is logged.
    pub fn run(runtime: *Runtime, context: *Context, name: []const u8) ?luau.Ref {
        const thread = context.thread;
        _ = thread.getGlobal("require");
        thread.pushString(name);
        const outer = runtime.begin(context);
        const status = thread.protectedCall(1, 1);
        runtime.end(outer);
        if (status != .ok) {
            runtime.recover(context, thread);
            return null;
        }
        defer thread.pop(1);
        return thread.ref(-1);
    }

    /// Calls the referenced function as the context's mod, with `arguments`: each a reference, a
    /// number or a boolean, none of which takes memory to push (`make` makes the rest). Returns
    /// what the function returned, or `failed` if it raised an error, which is logged.
    pub fn call(runtime: *Runtime, context: *Context, function: luau.Ref, arguments: anytype) Called {
        if (context.closed) return .failed;
        const thread = context.thread;
        if (!thread.checkStack(arguments.len + 2)) return .failed;
        _ = thread.pushRef(function);
        return runtime.callPushed(context, arguments);
    }

    /// Calls the referenced function with no arguments as the context's mod, and returns a copy of
    /// what it returned as plain data (`stored.capture`), made in `gpa`: nil for nothing, and null
    /// where it failed or returned what isn't plain data, which is logged.
    pub fn callKeeping(runtime: *Runtime, context: *Context, function: luau.Ref, gpa: Allocator) ?stored.Value {
        if (context.closed) return null;
        const thread = context.thread;
        if (!thread.checkStack(2)) return null;
        _ = thread.pushRef(function);
        const outer = runtime.begin(context);
        const status = thread.protectedCall(0, 1);
        runtime.end(outer);
        if (status != .ok) {
            runtime.recover(context, thread);
            return null;
        }
        const returned = thread.ref(-1);
        thread.pop(1);
        defer runtime.release(returned);
        return runtime.keep(context, returned, gpa, "on_save");
    }

    /// A copy of the referenced value as plain data (`stored.capture`), made in `gpa`; null where
    /// it isn't plain data, which is logged as the context's error, naming `label`.
    pub fn keep(runtime: *Runtime, context: *Context, value: luau.Ref, gpa: Allocator, label: []const u8) ?stored.Value {
        const thread = context.thread;
        if (!thread.checkStack(2)) return null;
        var request: KeepRequest = .{ .value = value, .gpa = gpa, .label = label };
        if (thread.protectedCallC(luau.wrap(keepValue), &request) != .ok) {
            runtime.recover(context, thread);
            return null;
        }
        return request.kept;
    }

    /// Runs `source`, a line of Luau typed into the console, as the context's mod: as an expression,
    /// whose values are written to `w` separated by tabs, or else as statements. Its global
    /// variables are kept for the next line, apart from the scripts' (`Context.console`). Returns
    /// false where it doesn't compile or fails, which is logged as the scripts' errors are.
    pub fn evaluate(runtime: *Runtime, context: *Context, source: []const u8, w: *Io.Writer) Allocator.Error!bool {
        if (context.closed) return false;
        const expression = try std.mem.concat(runtime.gpa, u8, &.{ "return ", source });
        defer runtime.gpa.free(expression);
        const as_expression = luau.compile(expression) orelse return error.OutOfMemory;
        defer as_expression.free();
        const as_statements = luau.compile(source) orelse return error.OutOfMemory;
        defer as_statements.free();

        const thread = context.thread;
        if (!thread.checkStack(console_stack)) return error.OutOfMemory;
        var request: EvaluateRequest = .{ .context = context, .tried = .{ as_expression.bytes, as_statements.bytes } };
        if (thread.protectedCallC(luau.wrap(loadConsoleLine), &request) != .ok) {
            runtime.recover(context, thread);
            return false;
        }
        const base = thread.top();
        defer thread.setTop(base);
        _ = thread.pushRef(request.function.?);
        runtime.release(request.function.?);
        const outer = runtime.begin(context);
        defer runtime.end(outer);
        if (thread.protectedCall(0, luau.all_results) != .ok) {
            runtime.recover(context, thread);
            return false;
        }
        // Each value is written as `tostring` gives it, called in protected mode, since a
        // metatable's `__tostring` can fail.
        const results = thread.top();
        var at = base + 1;
        while (at <= results) : (at += 1) {
            if (!thread.checkStack(console_stack)) return error.OutOfMemory;
            if (at > base + 1) w.writeByte('\t') catch {};
            _ = thread.getGlobal("tostring");
            thread.pushCopy(at);
            if (thread.protectedCall(1, 1) != .ok) {
                runtime.recover(context, thread);
                return false;
            }
            w.writeAll(thread.toString(-1) orelse "") catch {};
            thread.pop(1);
        }
        return true;
    }

    /// `call`, for the function at `key` of the referenced table, such as an event's handler.
    /// Returns null if the table has no function there.
    pub fn callIn(runtime: *Runtime, context: *Context, table: luau.Ref, key: [:0]const u8, arguments: anytype) ?Called {
        if (context.closed) return .failed;
        const thread = context.thread;
        if (!thread.checkStack(arguments.len + 3)) return .failed;
        _ = thread.pushRef(table);
        const found = thread.rawGetField(-1, key);
        thread.remove(-2);
        if (found != .function) {
            thread.pop(1);
            return null;
        }
        return runtime.callPushed(context, arguments);
    }

    /// Calls the function on top of the context's thread with `arguments` (`call`).
    fn callPushed(runtime: *Runtime, context: *Context, arguments: anytype) Called {
        const thread = context.thread;
        inline for (arguments) |argument| pushArgument(thread, argument);
        const outer = runtime.begin(context);
        const status = thread.protectedCall(arguments.len, 1);
        runtime.end(outer);
        if (status != .ok) {
            runtime.recover(context, thread);
            return .failed;
        }
        defer thread.pop(1);
        return switch (thread.typeOf(-1)) {
            .nil => .returned_nil,
            .boolean => if (thread.toBoolean(-1)) .returned else .returned_false,
            else => .returned,
        };
    }

    /// After a failed call: logs the error, and runs a full garbage collection so that a script
    /// that hit the memory limit doesn't leave its garbage for the mod's next script.
    fn recover(runtime: *Runtime, context: *const Context, thread: *State) void {
        context.report(thread);
        runtime.state.collectGarbage();
    }

    /// Starts a call into a mod's scripts: its allocations count against the mod's memory, and the
    /// time limit starts. Returns the call it interrupts, if any, which `end` resumes: a hook's
    /// handler can run the game's function, whose own hooks call other handlers.
    fn begin(runtime: *Runtime, context: *const Context) ?Running {
        const outer = runtime.running;
        runtime.running = .{ .category = context.category(), .started = .now(runtime.io, .awake) };
        runtime.interrupts = 0;
        return outer;
    }

    fn end(runtime: *Runtime, outer: ?Running) void {
        runtime.running = outer;
    }

    /// Luau's allocator, using C's allocator. Refuses allocations that would take the running mod
    /// over its memory limit (`Limits.memory`).
    fn allocate(data: ?*anyopaque, ptr: ?*anyopaque, old: usize, new: usize) callconv(.c) ?*anyopaque {
        const runtime: *Runtime = @ptrCast(@alignCast(data.?));
        if (new == 0) {
            std.c.free(ptr);
            return null;
        }
        const held = if (ptr == null) 0 else old;
        if (runtime.running) |running| if (new > held) {
            if (runtime.state.totalBytes(running.category) + (new - held) > runtime.options.limits.memory) return null;
        };
        return std.c.realloc(ptr, new);
    }

    /// Stops a call that runs over its time limit (`Limits.time`).
    fn interrupt(state: *State, collecting: bool) void {
        if (collecting) return;
        const runtime = state.callbackData(Runtime).?;
        const running = runtime.running orelse return;
        runtime.interrupts +%= 1;
        if (runtime.interrupts % interrupt_stride != 0) return;
        if (running.started.untilNow(runtime.io).raw.nanoseconds < runtime.options.limits.time.nanoseconds) return;
        state.raise("script timed out after {f}", .{runtime.options.limits.time});
    }
};

/// What a call returned (`Runtime.call`).
pub const Called = enum {
    /// It raised an error, which is logged.
    failed,
    /// It returned a value other than nil and `false`.
    returned,
    /// It returned nil, or nothing.
    returned_nil,
    /// It returned `false`, which stops a hook's later handlers.
    returned_false,
};

/// Pushes an argument of `Runtime.call`.
fn pushArgument(state: *State, argument: anytype) void {
    const T = @TypeOf(argument);
    switch (@typeInfo(T)) {
        .float, .int, .comptime_float, .comptime_int => state.pushNumber(argument),
        .bool => state.pushBoolean(argument),
        .optional => if (argument) |held| pushArgument(state, held) else state.pushNil(),
        else => if (T == luau.Ref) {
            _ = state.pushRef(argument);
        } else @compileError("make a reference to pass a " ++ @typeName(T)),
    }
}

/// The engine handlers a script returned, as references.
pub const Handlers = std.EnumArray(script.Handler, ?luau.Ref);

/// The longest name of an interface or of an event.
pub const max_name = 64;

/// A name of up to `max_name` bytes, kept in place, with a zero after it for Luau.
pub const Name = struct {
    bytes: [max_name:0]u8 = @splat(0),
    len: u8 = 0,

    /// `text` as a name, or null if it's too long.
    pub fn of(text: []const u8) ?Name {
        if (text.len > max_name) return null;
        var name: Name = .{ .len = @intCast(text.len) };
        @memcpy(name.bytes[0..text.len], text);
        return name;
    }

    pub fn slice(name: *const Name) [:0]const u8 {
        return name.bytes[0..name.len :0];
    }
};

/// What a script offers in the table it returns (`Context.offerOf`), as references.
pub const Offered = struct {
    handlers: Handlers = .initFill(null),
    /// A copy of its `event_handlers`: functions by event name.
    event_handlers: ?luau.Ref = null,
    /// Its `interface`, and the `interface_name` it goes by.
    interface: ?Interface = null,

    pub const Interface = struct {
        name: Name,
        table: luau.Ref,
    };

    /// Lets go of what it holds.
    pub fn release(offered: *Offered, runtime: *Runtime) void {
        for (std.enums.values(script.Handler)) |handler| {
            if (offered.handlers.get(handler)) |function| runtime.release(function);
        }
        if (offered.event_handlers) |table| runtime.release(table);
        if (offered.interface) |interface| runtime.release(interface.table);
        offered.* = .{};
    }
};

/// What's wrong with the table a script returned.
const Failure = union(enum) {
    returns: []const u8,
    key: []const u8,
    offer: []const u8,
    table: struct { offer: script.Offer, type_name: []const u8 },
    handler: []const u8,
    function: []const u8,
    event: []const u8,
    interface_name: []const u8,
    half_interface,
};

/// A mod opened for one script family (`Runtime.open`), or for its scripts on one object.
pub const Context = struct {
    runtime: *Runtime,
    /// The mod's index in `Runtime.mods`.
    mod: u16,
    family: script.Family,
    /// The object an object script's context runs on; null for the other families.
    object: ?objects.Handle = null,
    /// The thread the mod's calls run on. Its allocations count against the mod.
    thread: *State,
    thread_ref: luau.Ref,
    /// The modules `require` has run, with their results.
    loaded: luau.Ref = undefined,
    /// The functions its scripts registered for timers, by name (`async.zig`); null until the
    /// first.
    callbacks: ?luau.Ref = null,
    /// The thread whose globals keep the variables of the Luau typed into the console in this
    /// context (`Runtime.evaluate`); null until the first line.
    console: ?luau.Ref = null,
    /// Whether it has been closed (`Runtime.close`).
    closed: bool = false,

    pub fn modOf(context: *const Context) *const Mod {
        return &context.runtime.mods[context.mod];
    }

    /// The mod's memory category.
    fn category(context: *const Context) u8 {
        return @intCast(@min(@as(usize, context.mod) + 1, max_category));
    }

    /// Checks the table a script returned, and returns references to what it offers. Returns null
    /// if the table has something a script of this family may not return, or out of memory; the
    /// problem is logged.
    pub fn offerOf(context: *Context, name: []const u8, returned: luau.Ref) ?Offered {
        const state = context.thread;
        const mod = context.modOf();
        var offered: Offered = .{};
        const base = state.top();
        defer state.setTop(base);
        if (!state.checkStack(offer_stack)) {
            log.warn("{s}: {s}: out of memory", .{ mod.name, name });
            return null;
        }
        var interface_name: ?Name = null;
        const failure: Failure = check: {
            switch (state.pushRef(returned)) {
                .nil => return offered,
                .table => {},
                // What `require` returns for a script that returns nothing.
                .boolean => if (state.toBoolean(-1)) return offered else break :check .{ .returns = state.typeName(-1) },
                else => break :check .{ .returns = state.typeName(-1) },
            }
            state.pushNil();
            while (state.next(base + 1)) {
                const key = state.toString(-2) orelse break :check .{ .key = state.typeName(-2) };
                const offer = std.meta.stringToEnum(script.Offer, key) orelse break :check .{ .offer = key };
                if (!offer.offeredBy(context.family)) break :check .{ .offer = key };
                switch (offer) {
                    .engine_handlers => {
                        if (state.typeOf(-1) != .table) break :check .{ .table = .{ .offer = offer, .type_name = state.typeName(-1) } };
                        const table = state.top();
                        state.pushNil();
                        while (state.next(table)) {
                            const handler_name = state.toString(-2) orelse break :check .{ .key = state.typeName(-2) };
                            const handler = std.meta.stringToEnum(script.Handler, handler_name) orelse break :check .{ .handler = handler_name };
                            if (!handler.givenBy(context.family)) break :check .{ .handler = handler_name };
                            if (state.typeOf(-1) != .function) break :check .{ .function = handler_name };
                            offered.handlers.set(handler, state.ref(-1));
                            state.pop(1);
                        }
                    },
                    .event_handlers => {
                        if (state.typeOf(-1) != .table) break :check .{ .table = .{ .offer = offer, .type_name = state.typeName(-1) } };
                        const table = state.top();
                        state.newTable(0, 0);
                        const copied = state.top();
                        state.pushNil();
                        while (state.next(table)) {
                            const event = state.toString(-2) orelse break :check .{ .key = state.typeName(-2) };
                            if (event.len > max_name) break :check .{ .event = event };
                            if (state.typeOf(-1) != .function) break :check .{ .event = event };
                            state.pushCopy(-2);
                            state.pushCopy(-2);
                            state.rawSet(copied);
                            state.pop(1);
                        }
                        offered.event_handlers = state.ref(copied);
                        state.pop(1);
                    },
                    .interface_name => {
                        const text = state.toString(-1) orelse break :check .{ .interface_name = state.typeName(-1) };
                        interface_name = Name.of(text) orelse break :check .{ .interface_name = text };
                    },
                    .interface => {
                        if (state.typeOf(-1) != .table) break :check .{ .table = .{ .offer = offer, .type_name = state.typeName(-1) } };
                        offered.interface = .{ .name = .{}, .table = state.ref(-1) };
                    },
                }
                state.pop(1);
            }
            if ((interface_name == null) != (offered.interface == null)) break :check .half_interface;
            if (offered.interface) |*interface| interface.name = interface_name.?;
            return offered;
        };
        offered.release(context.runtime);
        switch (failure) {
            .returns => |type_name| log.warn("{s}: {s} must return a table or nothing, not a {s}", .{ mod.name, name, type_name }),
            .key => |type_name| log.warn("{s}: {s} returned a table with a {s} key; keys must be names", .{ mod.name, name, type_name }),
            .offer => |offer| log.warn("{s}: {s} returned '{s}', which {t} scripts can't use", .{ mod.name, name, offer, context.family }),
            .table => |wrong| log.warn("{s}: {s}: {t} must be a table, not a {s}", .{ mod.name, name, wrong.offer, wrong.type_name }),
            .handler => |handler| log.warn("{s}: {s}: {t} scripts can't use the engine handler '{s}'", .{ mod.name, name, context.family, handler }),
            .function => |handler| log.warn("{s}: {s}: the engine handler {s} must be a function", .{ mod.name, name, handler }),
            .event => |event| log.warn("{s}: {s}: the event handler '{s}' must be a function, with a name of at most {d} bytes", .{ mod.name, name, event, max_name }),
            .interface_name => |text| log.warn("{s}: {s}: interface_name must be a name of at most {d} bytes, not {s}", .{ mod.name, name, max_name, text }),
            .half_interface => log.warn("{s}: {s}: an interface needs both interface_name and interface", .{ mod.name, name }),
        }
        return null;
    }

    /// Logs the error on top of `thread` with the mod's name, and pops it.
    fn report(context: *const Context, thread: *State) void {
        log.warn("{s}: {s}", .{ context.modOf().name, thread.toString(-1) orelse "an error that isn't a string" });
        thread.pop(1);
    }
};

/// How much stack running a line of the console takes, beyond its results.
const console_stack = 4;

/// The name a line of the console's tracebacks give it.
const console_chunk = "=console";

/// The arguments of `loadConsoleLine`.
const EvaluateRequest = struct {
    context: *Context,
    /// The line compiled as an expression, then as statements.
    tried: [2][]const u8,
    function: ?luau.Ref = null,
};

/// Loads a line of the console as a function of the console's thread in its context, which it
/// makes the first time, the first of `tried` that loads. Raises the error of the last where none
/// does. Runs in protected mode (`Runtime.evaluate`).
fn loadConsoleLine(state: *State) i32 {
    const request = state.toLightUserdata(EvaluateRequest, 1).?;
    const context = request.context;
    if (context.console == null) {
        _ = state.newSandboxedThread();
        context.console = state.ref(-1);
        state.pop(1);
    }
    _ = state.pushRef(context.console.?);
    const console = state.toThread(-1).?;
    for (request.tried, 0..) |bytecode, at| {
        if (console.load(console_chunk, bytecode) == .ok) break;
        if (at + 1 == request.tried.len) {
            console.move(state, 1);
            state.raiseTop();
        }
        console.pop(1);
    }
    console.move(state, 1);
    request.function = state.ref(-1);
    return 0;
}

/// The arguments of `keepValue`.
const KeepRequest = struct {
    value: luau.Ref,
    gpa: Allocator,
    label: []const u8,
    kept: ?stored.Value = null,
};

/// Copies a value as plain data. Runs in protected mode (`Runtime.keep`).
fn keepValue(state: *State) i32 {
    const request = state.toLightUserdata(KeepRequest, 1).?;
    _ = state.pushRef(request.value);
    request.kept = stored.capture(state, request.gpa, -1, request.label);
    return 0;
}

/// How much stack opening a context takes.
const context_stack = 2;

/// How much stack checking a returned table takes (`Context.offerOf`): the table, a key and a
/// value, a nested table's key and value, and a copy's table, key and value.
const offer_stack = 10;

/// A mod's scripts, compiled (`Runtime.compiled`).
const Code = struct {
    /// Each script's bytecode, by module name (`moduleName`).
    modules: std.StringArrayHashMapUnmanaged(Module) = .empty,

    const Module = struct {
        /// The name tracebacks give it, `=` and its mod's name and file's name.
        chunk: [:0]const u8,
        bytecode: luau.Bytecode,
    };

    fn add(code: *Code, gpa: Allocator, module: []const u8, chunk: [:0]const u8, bytecode: luau.Bytecode) Allocator.Error!void {
        try code.modules.ensureUnusedCapacity(gpa, 1);
        const key = try gpa.dupe(u8, module);
        errdefer gpa.free(key);
        const name = try gpa.dupeZ(u8, chunk);
        code.modules.putAssumeCapacity(key, .{ .chunk = name, .bytecode = bytecode });
    }

    fn deinit(code: *Code, gpa: Allocator) void {
        var entries = code.modules.iterator();
        while (entries.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.chunk);
            entry.value_ptr.bytecode.free();
        }
        code.modules.deinit(gpa);
    }
};

/// The arguments for `checkChunk`.
const LoadRequest = struct {
    chunk: [:0]const u8,
    bytecode: []const u8,
};

/// Loads a script's bytecode and logs its error if it doesn't load. Runs in protected mode
/// (`Runtime.check`).
fn checkChunk(state: *State) i32 {
    const request = state.toLightUserdata(LoadRequest, 1).?;
    if (state.load(request.chunk, request.bytecode) != .ok) log.warn("{s}", .{state.toString(-1) orelse "a script that doesn't compile"});
    return 0;
}

/// `require(name)`: runs a script from the same mod once and returns its result, or returns an
/// OpenReliant package.
fn require(state: *State) i32 {
    const context = state.threadData(Context) orelse state.raise("require can only be used by mod scripts", .{});
    if (context.closed) state.raise("require: this script has stopped", .{});
    const name = state.toString(1) orelse state.raise("require: expected a string, got {s}", .{state.typeName(1)});
    if (script.Package.parse(name)) |package| {
        if (!package.reachableFrom(context.family)) state.raise("{s} is not available to {t} scripts", .{ name, context.family });
        if (!package.ready()) state.raise("{s} is not available in this version of OpenReliant", .{name});
        // The script's own object, or the player's ship.
        if (package == .self) {
            if (context.object) |own| {
                objects.push(state, own.slot);
            } else if (context.runtime.objects) |all| {
                objects.push(state, all.player);
            } else state.pushNil();
            return 1;
        }
        const kept = context.runtime.packages.get(package) orelse state.raise("{s} is not available here", .{name});
        _ = state.pushRef(kept);
        return 1;
    }
    if (std.mem.startsWith(u8, name, script.Package.prefix)) state.raise("unknown package {s}", .{name});
    var module_buffer: [max_module_name:0]u8 = undefined;
    const module = moduleName(&module_buffer, name) orelse state.raise("require: the name {s} is too long", .{name});

    _ = state.pushRef(context.loaded);
    const loaded = state.top();
    switch (state.rawGetField(loaded, module)) {
        .nil => state.pop(1),
        .light_userdata => if (state.toLightUserdata(u8, -1) == &loading) state.raise("circular require of {s}", .{module}) else return 1,
        else => return 1,
    }
    const code = context.runtime.code.getPtr(context.mod).?;
    const found = code.modules.get(module) orelse state.raise("mod {s} has no script {s}{s}", .{ context.modOf().name, module, mods.script_extension });
    // Each context loads its own copy, with its own globals.
    const own = state.newSandboxedThread();
    _ = own.load(found.chunk, found.bytecode.bytes);
    own.move(state, 1);
    state.remove(-2);
    if (state.typeOf(-1) != .function) state.raiseTop();
    state.pushLightUserdata(&loading);
    state.rawSetField(loaded, module);
    if (state.protectedCallBare(0, 1) != .ok) {
        state.pushNil();
        state.rawSetField(loaded, module);
        state.raiseTop();
    }
    if (state.typeOf(-1) == .nil) {
        state.pop(1);
        state.pushBoolean(true);
    }
    state.pushCopy(-1);
    state.rawSetField(loaded, module);
    return 1;
}

/// `print(...)`: writes the values to the log, separated by tabs and prefixed with the mod's name.
fn print(state: *State) i32 {
    const context = state.threadData(Context) orelse return 0;
    const count = state.top();
    var at: i32 = 1;
    while (at <= count) : (at += 1) {
        if (at > 1) state.pushString("\t");
        _ = state.toDisplay(at);
    }
    if (count == 0) state.pushString("") else state.concat(2 * count - 1);
    log.info("{s}: {s}", .{ context.modOf().name, state.toString(-1).? });
    return 0;
}

/// `math.random` on the game side, using the state's seeded generator. With no arguments it returns
/// a number from 0 to 1, with one argument `m` a whole number from 1 to `m`, and with two arguments
/// a whole number from `m` to `n`.
fn random(state: *State) i32 {
    const context = state.threadData(Context) orelse state.raise("math.random can only be used by mod scripts", .{});
    const numbers = context.runtime.random.random();
    switch (state.top()) {
        0 => state.pushNumber(numbers.float(f64)),
        1 => {
            const last = whole(state, 1);
            if (last < 1) state.raise("math.random: interval is empty", .{});
            state.pushNumber(@floatFromInt(numbers.intRangeAtMost(i64, 1, last)));
        },
        2 => {
            const first = whole(state, 1);
            const last = whole(state, 2);
            if (first > last) state.raise("math.random: interval is empty", .{});
            state.pushNumber(@floatFromInt(numbers.intRangeAtMost(i64, first, last)));
        },
        else => state.raise("math.random: expected at most 2 arguments", .{}),
    }
    return 1;
}

/// The whole number at `index`. Raises an error for anything else.
fn whole(state: *State, index: i32) i64 {
    const number = state.toNumber(index) orelse state.raise("math.random: expected a number, got {s}", .{state.typeName(index)});
    if (number != @floor(number) or @abs(number) > max_whole) state.raise("math.random: expected a whole number, got {d}", .{number});
    return @intFromFloat(number);
}

/// The largest whole number a Luau number can hold exactly.
const max_whole: f64 = 1 << std.math.floatMantissaBits(f64);

/// The module name for a script file: lowercase, without the `.luau` extension. Returns null if it
/// doesn't fit in `buffer`.
fn moduleName(buffer: [:0]u8, name: []const u8) ?[:0]const u8 {
    const extension = std.fs.path.extension(name);
    const stem = if (std.ascii.eqlIgnoreCase(extension, mods.script_extension)) name[0 .. name.len - extension.len] else name;
    if (stem.len > buffer.len) return null;
    const lowered = std.ascii.lowerString(buffer, stem);
    buffer[lowered.len] = 0;
    return buffer[0..lowered.len :0];
}

test moduleName {
    var buffer: [16:0]u8 = undefined;
    try std.testing.expectEqualStrings("balance", moduleName(&buffer, "Balance.LUAU").?);
    try std.testing.expectEqualStrings("util", moduleName(&buffer, "util").?);
    try std.testing.expectEqualStrings("a.lua", moduleName(&buffer, "a.lua").?);
    try std.testing.expectEqual(null, moduleName(&buffer, "a name past sixteen bytes"));
}

test "Runtime.recompileFolders" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const load = @import("load.zig");
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try load.testing.makeMods(io, tmp.dir, &.{.{ "a", &.{ .{ "mod.ini", "" }, .{ "value.luau", "return 1" } } }});
    var opened: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    const scripts = try Runtime.create(gpa, io, opened.list, .{ .side = .game, .limits = .{ .time = .fromSeconds(1), .memory = 1 << 20 }, .seed = 1, .version = "0.7.0" });
    defer scripts.destroy();
    const before = try scripts.open(0, .global, null);
    const first = scripts.run(before, "value").?;
    defer scripts.release(first);
    _ = scripts.state.pushRef(first);
    try std.testing.expectEqual(1, scripts.state.toNumber(-1).?);
    scripts.state.pop(1);
    // The file saved again, the scripts that start from then on take the new code.
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/value.luau", .data = "return 2" });
    try scripts.recompileFolders();
    const after = try scripts.open(0, .global, null);
    const second = scripts.run(after, "value").?;
    defer scripts.release(second);
    _ = scripts.state.pushRef(second);
    try std.testing.expectEqual(2, scripts.state.toNumber(-1).?);
    scripts.state.pop(1);
}
