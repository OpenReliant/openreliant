//! The Luau state that mod scripts run in
//! ([#498](https://github.com/OpenReliant/openreliant/issues/498)): the sandbox, the time and
//! memory limits, loading each mod's scripts, and `require`.
//!
//! When a mod is opened, each of its scripts is compiled and loaded with its own global table, so
//! scripts can't see each other's globals. `require` runs a script once and returns its result. It
//! accepts another script from the same mod, by file name with or without the extension and in any
//! case, or an OpenReliant package (`script.Package`). Compile errors are logged when the mod is
//! opened, and raised again when the script is required.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.scripts);

const openreliant = @import("openreliant");
const mods = openreliant.engine.game.bigfile.mods;
const Mod = mods.Mod;
const luau = @import("luau.zig");
const State = luau.State;
const script = @import("script.zig");

/// The userdata tags, one per kind of userdata, each with its own metatable.
pub const Tag = enum(luau.Tag) {
    /// A record, or a struct or array inside one (`records.Values`).
    record_value = 1,
    /// A table of records, such as the ships (`records.Set`).
    record_set = 2,
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
    random: std.Random.DefaultPrng,
    /// The call in progress, if any (`begin`).
    running: ?Running = null,
    /// Interrupt calls since the clock was last read.
    interrupts: u32 = 0,

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

    /// Opens a mod for scripts of `family`: compiles and loads all its scripts so that they can be
    /// required. `mod` is the mod's index in `mods`.
    pub fn open(runtime: *Runtime, mod: u16, family: script.Family) Allocator.Error!*Context {
        const state = runtime.state;
        const context = try runtime.gpa.create(Context);
        errdefer runtime.gpa.destroy(context);
        try runtime.contexts.ensureUnusedCapacity(runtime.gpa, 1);
        const thread = state.newThread();
        context.* = .{ .runtime = runtime, .mod = mod, .family = family, .thread = thread, .thread_ref = state.ref(-1) };
        state.pop(1);
        thread.setThreadData(context);
        thread.setMemoryCategory(context.category());
        state.newTable(0, 0);
        context.chunks = state.ref(-1);
        state.newTable(0, 0);
        context.loaded = state.ref(-1);
        state.pop(2);
        runtime.contexts.appendAssumeCapacity(context);
        try runtime.loadChunks(context);
        return context;
    }

    /// Compiles and loads each of the mod's scripts into `Context.chunks`.
    fn loadChunks(runtime: *Runtime, context: *Context) Allocator.Error!void {
        const mod = context.modOf();
        var names = mod.scripts();
        while (names.next()) |name| {
            var module_buffer: [max_module_name:0]u8 = undefined;
            const module = moduleName(&module_buffer, name) orelse {
                log.warn("{s}: skipping {s}: the name is too long", .{ mod.name, name });
                continue;
            };
            const source = mod.readFile(runtime.gpa, name) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => {
                    log.warn("{s}: skipping {s}: {s}", .{ mod.name, name, @errorName(err) });
                    continue;
                },
            } orelse continue;
            defer runtime.gpa.free(source);
            const bytecode = luau.compile(source) orelse return error.OutOfMemory;
            defer bytecode.free();
            var chunk_buffer: [max_chunk_name:0]u8 = undefined;
            var request: LoadRequest = .{
                .context = context,
                .module = module,
                .chunk = std.fmt.bufPrintZ(&chunk_buffer, "={s}/{s}", .{ mod.name, name }) catch "=script",
                .bytecode = bytecode.bytes,
            };
            runtime.begin(context);
            const status = context.thread.protectedCallC(luau.wrap(loadChunk), &request);
            runtime.end();
            if (status != .ok) log.warn("{s}: {s} could not be loaded: {t}", .{ mod.name, name, status });
        }
    }

    /// Runs the script `name` like `require` does, and returns a reference to its result. Returns
    /// null if the script fails; the error is logged.
    pub fn run(runtime: *Runtime, context: *Context, name: []const u8) ?luau.Ref {
        const thread = context.thread;
        _ = thread.getGlobal("require");
        thread.pushString(name);
        runtime.begin(context);
        const status = thread.protectedCall(1, 1);
        runtime.end();
        if (status != .ok) {
            runtime.recover(context, thread);
            return null;
        }
        defer thread.pop(1);
        return thread.ref(-1);
    }

    /// Calls the referenced function as the context's mod. Returns false if it fails; the error is
    /// logged.
    pub fn call(runtime: *Runtime, context: *Context, function: luau.Ref) bool {
        const thread = context.thread;
        _ = thread.pushRef(function);
        runtime.begin(context);
        const status = thread.protectedCall(0, 0);
        runtime.end();
        if (status != .ok) {
            runtime.recover(context, thread);
            return false;
        }
        return true;
    }

    /// After a failed call: logs the error, and runs a full garbage collection so that a script
    /// that hit the memory limit doesn't leave its garbage for the mod's next script.
    fn recover(runtime: *Runtime, context: *const Context, thread: *State) void {
        context.report(thread);
        runtime.state.collectGarbage();
    }

    /// Starts a call into a mod's scripts: its allocations count against the mod's memory, and the
    /// time limit starts.
    fn begin(runtime: *Runtime, context: *const Context) void {
        runtime.running = .{ .category = context.category(), .started = .now(runtime.io, .awake) };
        runtime.interrupts = 0;
    }

    fn end(runtime: *Runtime) void {
        runtime.running = null;
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

/// The engine handlers a script returned, as references.
pub const Handlers = std.EnumArray(script.Handler, ?luau.Ref);

/// What's wrong with the table a script returned.
const Failure = union(enum) {
    returns: []const u8,
    key: []const u8,
    offer: []const u8,
    handlers: []const u8,
    handler: []const u8,
    function: []const u8,
};

/// A mod opened for one script family (`Runtime.open`).
pub const Context = struct {
    runtime: *Runtime,
    /// The mod's index in `Runtime.mods`.
    mod: u16,
    family: script.Family,
    /// The thread the mod's calls run on. Its allocations count against the mod.
    thread: *State,
    thread_ref: luau.Ref,
    /// The mod's scripts by module name: the loaded function, or the error if it didn't load.
    chunks: luau.Ref = undefined,
    /// The modules `require` has run, with their results.
    loaded: luau.Ref = undefined,

    pub fn modOf(context: *const Context) *const Mod {
        return &context.runtime.mods[context.mod];
    }

    /// The mod's memory category.
    fn category(context: *const Context) u8 {
        return @intCast(@min(@as(usize, context.mod) + 1, max_category));
    }

    /// Checks the table a script returned, and returns references to its engine handlers. Returns
    /// null if the table has something a script of this family may not return; the problem is
    /// logged.
    pub fn handlersOf(context: *Context, name: []const u8, returned: luau.Ref) ?Handlers {
        const state = context.thread;
        const mod = context.modOf();
        var handlers: Handlers = .initFill(null);
        const base = state.top();
        defer state.setTop(base);
        const failure: Failure = check: {
            switch (state.pushRef(returned)) {
                .nil => return handlers,
                .table => {},
                // What `require` returns for a script that returns nothing.
                .boolean => if (state.toBoolean(-1)) return handlers else break :check .{ .returns = state.typeName(-1) },
                else => break :check .{ .returns = state.typeName(-1) },
            }
            state.pushNil();
            while (state.next(base + 1)) {
                const key = state.toString(-2) orelse break :check .{ .key = state.typeName(-2) };
                const offer = std.meta.stringToEnum(script.Offer, key) orelse break :check .{ .offer = key };
                if (!offer.offeredBy(context.family)) break :check .{ .offer = key };
                if (offer == .engine_handlers) {
                    if (state.typeOf(-1) != .table) break :check .{ .handlers = state.typeName(-1) };
                    const table = state.top();
                    state.pushNil();
                    while (state.next(table)) {
                        const handler_name = state.toString(-2) orelse break :check .{ .key = state.typeName(-2) };
                        const handler = std.meta.stringToEnum(script.Handler, handler_name) orelse break :check .{ .handler = handler_name };
                        if (!handler.givenBy(context.family)) break :check .{ .handler = handler_name };
                        if (state.typeOf(-1) != .function) break :check .{ .function = handler_name };
                        handlers.set(handler, state.ref(-1));
                        state.pop(1);
                    }
                }
                state.pop(1);
            }
            return handlers;
        };
        for (std.enums.values(script.Handler)) |handler| if (handlers.get(handler)) |kept| state.unref(kept);
        switch (failure) {
            .returns => |type_name| log.warn("{s}: {s} must return a table or nothing, not a {s}", .{ mod.name, name, type_name }),
            .key => |type_name| log.warn("{s}: {s} returned a table with a {s} key; keys must be names", .{ mod.name, name, type_name }),
            .offer => |offer| log.warn("{s}: {s} returned '{s}', which {t} scripts can't use", .{ mod.name, name, offer, context.family }),
            .handlers => |type_name| log.warn("{s}: {s}: engine_handlers must be a table, not a {s}", .{ mod.name, name, type_name }),
            .handler => |handler| log.warn("{s}: {s}: {t} scripts can't use the engine handler '{s}'", .{ mod.name, name, context.family, handler }),
            .function => |handler| log.warn("{s}: {s}: the engine handler {s} must be a function", .{ mod.name, name, handler }),
        }
        return null;
    }

    /// Logs the error on top of `thread` with the mod's name, and pops it.
    fn report(context: *const Context, thread: *State) void {
        log.warn("{s}: {s}", .{ context.modOf().name, thread.toString(-1) orelse "an error that isn't a string" });
        thread.pop(1);
    }
};

/// The arguments for `loadChunk`.
const LoadRequest = struct {
    context: *Context,
    module: [:0]const u8,
    chunk: [:0]const u8,
    bytecode: []const u8,
};

/// Loads a script's bytecode with its own globals and stores the function, or the error message if
/// it fails, in the mod's chunks. Runs in protected mode (`Runtime.loadChunks`).
fn loadChunk(state: *State) i32 {
    const request = state.toLightUserdata(LoadRequest, 1).?;
    const own = state.newSandboxedThread();
    const status = own.load(request.chunk, request.bytecode);
    own.move(state, 1);
    if (status != .ok) log.warn("{s}", .{state.toString(-1) orelse "a script that doesn't compile"});
    _ = state.pushRef(request.context.chunks);
    state.pushCopy(-2);
    state.rawSetField(-2, request.module);
    return 0;
}

/// `require(name)`: runs a script from the same mod once and returns its result, or returns an
/// OpenReliant package.
fn require(state: *State) i32 {
    const context = state.threadData(Context) orelse state.raise("require can only be used by mod scripts", .{});
    const name = state.toString(1) orelse state.raise("require: expected a string, got {s}", .{state.typeName(1)});
    if (script.Package.parse(name)) |package| {
        if (!package.reachableFrom(context.family)) state.raise("{s} is not available to {t} scripts", .{ name, context.family });
        if (!package.ready()) state.raise("{s} is not available in this version of OpenReliant", .{name});
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
    _ = state.pushRef(context.chunks);
    switch (state.rawGetField(-1, module)) {
        .function => {},
        .string => state.raiseTop(),
        else => state.raise("mod {s} has no script {s}{s}", .{ context.modOf().name, module, mods.script_extension }),
    }
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
