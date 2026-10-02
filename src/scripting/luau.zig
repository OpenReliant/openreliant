//! A Zig wrapper around the parts of Luau's C API (`luau.h`) that the scripting uses: the state and
//! its stack, tables, userdata, protected calls, the compiler, the sandbox, and the callbacks used
//! for the limits.
//!
//! Luau is built so that errors use `longjmp` (`deps/luau`). A function that raises an error, such
//! as `State.raise` or one of Luau's argument checks, never returns, and Zig `defer`s in the frames
//! it skips don't run. So a C function called from Luau must free what it allocated before calling
//! anything that can raise an error.

const std = @import("std");
const c = @import("luau");

/// A Luau state or thread (`lua_State`).
pub const State = opaque {
    fn raw(state: *State) *c.lua_State {
        return @ptrCast(state);
    }

    fn of(raw_state: ?*c.lua_State) *State {
        return @ptrCast(raw_state.?);
    }

    /// Creates a state that allocates through `allocate`, which gets `context`. Returns null if
    /// that fails.
    pub fn create(allocate: Allocate, context: ?*anyopaque) ?*State {
        return @ptrCast(c.lua_newstate(allocate, context) orelse return null);
    }

    pub fn close(state: *State) void {
        c.lua_close(state.raw());
    }

    /// Opens Luau's standard libraries.
    pub fn openLibraries(state: *State) void {
        c.luaL_openlibs(state.raw());
    }

    /// Makes the globals and the standard libraries read-only (`luaL_sandbox`).
    pub fn sandbox(state: *State) void {
        c.luaL_sandbox(state.raw());
    }

    /// Creates a thread that shares the state's globals, and pushes it.
    pub fn newThread(state: *State) *State {
        return of(c.lua_newthread(state.raw()));
    }

    /// Creates a thread with its own global table, which falls back to the sandboxed globals
    /// (`luaL_sandboxthread`), and pushes it.
    pub fn newSandboxedThread(state: *State) *State {
        const thread = of(c.lua_newthread(state.raw()));
        c.luaL_sandboxthread(thread.raw());
        return thread;
    }

    /// The pointer stored with the thread (`lua_getthreaddata`).
    pub fn threadData(state: *State, comptime T: type) ?*T {
        return @ptrCast(@alignCast(c.lua_getthreaddata(state.raw())));
    }

    pub fn setThreadData(state: *State, data: ?*anyopaque) void {
        c.lua_setthreaddata(state.raw(), data);
    }

    fn callbacks(state: *State) *c.lua_Callbacks {
        return c.lua_callbacks(state.raw());
    }

    /// The pointer stored with the state's callbacks (`lua_Callbacks.userdata`).
    pub fn callbackData(state: *State, comptime T: type) ?*T {
        return @ptrCast(@alignCast(state.callbacks().userdata));
    }

    pub fn setCallbackData(state: *State, data: ?*anyopaque) void {
        state.callbacks().userdata = data;
    }

    /// Sets the interrupt callback, which Luau calls at safe points while a script runs.
    /// `collecting` is true when the call comes from the garbage collector, where raising an error
    /// isn't allowed.
    pub fn setInterrupt(state: *State, comptime run: fn (*State, collecting: bool) void) void {
        state.callbacks().interrupt = &struct {
            fn call(raw_state: ?*c.lua_State, gc: c_int) callconv(.c) void {
                run(of(raw_state), gc >= 0);
            }
        }.call;
    }

    /// Makes new threads, such as coroutines, inherit their parent's thread data.
    pub fn inheritThreadData(state: *State) void {
        state.callbacks().userthread = &struct {
            fn call(parent: ?*c.lua_State, thread: ?*c.lua_State) callconv(.c) void {
                const from = parent orelse return;
                c.lua_setthreaddata(thread, c.lua_getthreaddata(from));
            }
        }.call;
    }

    /// Sets the memory category that the thread's allocations are counted in (`lua_setmemcat`).
    pub fn setMemoryCategory(state: *State, category: u8) void {
        c.lua_setmemcat(state.raw(), category);
    }

    /// Runs a full garbage collection.
    pub fn collectGarbage(state: *State) void {
        _ = c.lua_gc(state.raw(), c.LUA_GCCOLLECT, 0);
    }

    /// The number of bytes allocated in `category`.
    pub fn totalBytes(state: *State, category: u8) usize {
        return c.lua_totalbytes(state.raw(), category);
    }

    // --- Stack ----------------------------------------------------------------------------------

    pub fn top(state: *State) i32 {
        return c.lua_gettop(state.raw());
    }

    pub fn setTop(state: *State, index: i32) void {
        c.lua_settop(state.raw(), index);
    }

    pub fn pop(state: *State, count: i32) void {
        c.lua_settop(state.raw(), -count - 1);
    }

    /// Converts a relative stack index into an absolute one, which stays valid as values are
    /// pushed.
    pub fn absolute(state: *State, index: i32) i32 {
        return c.lua_absindex(state.raw(), index);
    }

    /// Moves the top value to `index`, shifting the values above it up.
    pub fn insert(state: *State, index: i32) void {
        c.lua_insert(state.raw(), index);
    }

    pub fn pushCopy(state: *State, index: i32) void {
        c.lua_pushvalue(state.raw(), index);
    }

    /// Moves `count` values from the top of `from`'s stack to `to`'s.
    pub fn move(from: *State, to: *State, count: i32) void {
        c.lua_xmove(from.raw(), to.raw(), count);
    }

    pub fn typeOf(state: *State, index: i32) Type {
        return @enumFromInt(c.lua_type(state.raw(), index));
    }

    /// The type name Luau uses in its messages, such as "string".
    pub fn typeName(state: *State, index: i32) [:0]const u8 {
        return std.mem.span(c.luaL_typename(state.raw(), index));
    }

    // --- Values ---------------------------------------------------------------------------------

    pub fn pushNil(state: *State) void {
        c.lua_pushnil(state.raw());
    }

    pub fn pushBoolean(state: *State, value: bool) void {
        c.lua_pushboolean(state.raw(), @intFromBool(value));
    }

    pub fn pushNumber(state: *State, value: f64) void {
        c.lua_pushnumber(state.raw(), value);
    }

    pub fn pushString(state: *State, value: []const u8) void {
        c.lua_pushlstring(state.raw(), value.ptr, value.len);
    }

    pub fn pushLightUserdata(state: *State, value: *anyopaque) void {
        c.lua_pushlightuserdatatagged(state.raw(), value, 0);
    }

    /// Pushes a C function, with `name` shown in tracebacks.
    pub fn pushFunction(state: *State, function: Function, name: [:0]const u8) void {
        c.lua_pushcclosurek(state.raw(), function, name, 0, null);
    }

    pub fn toBoolean(state: *State, index: i32) bool {
        return c.lua_toboolean(state.raw(), index) != 0;
    }

    /// The number at `index`, or null if the value isn't a number.
    pub fn toNumber(state: *State, index: i32) ?f64 {
        if (state.typeOf(index) != .number) return null;
        return c.lua_tonumberx(state.raw(), index, null);
    }

    /// The string at `index`, or null if the value isn't a string. Numbers aren't converted.
    pub fn toString(state: *State, index: i32) ?[]const u8 {
        if (state.typeOf(index) != .string) return null;
        var len: usize = undefined;
        const ptr = c.lua_tolstring(state.raw(), index, &len) orelse return null;
        return ptr[0..len];
    }

    /// The light userdata at `index`, or null if the value isn't light userdata.
    pub fn toLightUserdata(state: *State, comptime T: type, index: i32) ?*T {
        return @ptrCast(@alignCast(c.lua_tolightuserdata(state.raw(), index) orelse return null));
    }

    /// Pops `count` values and pushes them concatenated, like `..`.
    pub fn concat(state: *State, count: i32) void {
        c.lua_concat(state.raw(), count);
    }

    /// Pushes the value at `index` converted to a string, like `tostring`, and returns it.
    pub fn toDisplay(state: *State, index: i32) []const u8 {
        var len: usize = undefined;
        const ptr = c.luaL_tolstring(state.raw(), index, &len);
        return ptr[0..len];
    }

    // --- Tables ---------------------------------------------------------------------------------

    /// Pushes a new table with space preallocated for `array` elements and `fields` fields.
    pub fn newTable(state: *State, array: u16, fields: u16) void {
        c.lua_createtable(state.raw(), array, fields);
    }

    /// Pushes `table[key]` for the table at `index`, ignoring metamethods.
    pub fn rawGetField(state: *State, index: i32, key: [:0]const u8) Type {
        return @enumFromInt(c.lua_rawgetfield(state.raw(), index, key));
    }

    /// Pops a value and sets `table[key]` to it for the table at `index`, ignoring metamethods.
    pub fn rawSetField(state: *State, index: i32, key: [:0]const u8) void {
        c.lua_rawsetfield(state.raw(), index, key);
    }

    /// Pops a key and pushes the next key and value of the table at `index` (`lua_next`). Returns
    /// false after the last one.
    pub fn next(state: *State, index: i32) bool {
        return c.lua_next(state.raw(), index) != 0;
    }

    pub fn setReadonly(state: *State, index: i32, readonly: bool) void {
        c.lua_setreadonly(state.raw(), index, @intFromBool(readonly));
    }

    /// Pops a value and sets the global `name` to it.
    pub fn setGlobal(state: *State, name: [:0]const u8) void {
        c.lua_setfield(state.raw(), c.LUA_GLOBALSINDEX, name);
    }

    /// Pushes the global `name`.
    pub fn getGlobal(state: *State, name: [:0]const u8) Type {
        return @enumFromInt(c.lua_getfield(state.raw(), c.LUA_GLOBALSINDEX, name));
    }

    // --- Userdata -------------------------------------------------------------------------------

    /// Pushes new userdata holding a `T`, with the metatable registered for `tag`
    /// (`setUserdataMetatable`). The `T` is uninitialized.
    pub fn newUserdata(state: *State, comptime T: type, tag: Tag) *T {
        const raw_data = c.lua_newuserdatataggedwithmetatable(state.raw(), @sizeOf(T), tag);
        return @ptrCast(@alignCast(raw_data));
    }

    /// The `T` in the userdata at `index`, or null if the value isn't userdata with `tag`.
    pub fn toUserdata(state: *State, comptime T: type, index: i32, tag: Tag) ?*T {
        return @ptrCast(@alignCast(c.lua_touserdatatagged(state.raw(), index, tag) orelse return null));
    }

    /// Pops a table and registers it as the metatable for userdata with `tag`.
    pub fn setUserdataMetatable(state: *State, tag: Tag) void {
        c.lua_setuserdatametatable(state.raw(), tag);
    }

    // --- References -----------------------------------------------------------------------------

    /// Creates a reference to the value at `index`, which keeps it from being collected until
    /// `unref`.
    pub fn ref(state: *State, index: i32) Ref {
        return @enumFromInt(c.lua_ref(state.raw(), index));
    }

    pub fn unref(state: *State, reference: Ref) void {
        _ = c.lua_unref(state.raw(), @intFromEnum(reference));
    }

    /// Pushes the referenced value.
    pub fn pushRef(state: *State, reference: Ref) Type {
        return @enumFromInt(c.lua_rawgeti(state.raw(), c.LUA_REGISTRYINDEX, @intFromEnum(reference)));
    }

    // --- Calls ----------------------------------------------------------------------------------

    /// Calls the function below the `arguments` on the stack in protected mode. On success it
    /// leaves `results` results; on failure it leaves the error message with a traceback.
    pub fn protectedCall(state: *State, arguments: i32, results: i32) Status {
        const base = state.top() - arguments;
        state.pushFunction(traceback, "traceback");
        state.insert(base);
        const status: Status = @enumFromInt(c.lua_pcall(state.raw(), arguments, results, base));
        c.lua_remove(state.raw(), base);
        return status;
    }

    /// Error handler for `protectedCall`: adds a traceback to the message.
    fn traceback(raw_state: ?*c.lua_State) callconv(.c) c_int {
        const L = raw_state.?;
        const message = c.lua_tolstring(L, 1, null);
        c.luaL_traceback(L, L, message, 1);
        return 1;
    }

    /// Like `protectedCall`, but leaves the error as it was raised, without a traceback.
    pub fn protectedCallBare(state: *State, arguments: i32, results: i32) Status {
        return @enumFromInt(c.lua_pcall(state.raw(), arguments, results, 0));
    }

    /// Calls the C function `function` in protected mode with `context` as its argument
    /// (`lua_cpcall`). Its results are discarded.
    pub fn protectedCallC(state: *State, function: Function, context: ?*anyopaque) Status {
        return @enumFromInt(c.lua_cpcall(state.raw(), function, context));
    }

    /// Raises an error with a formatted message, prefixed with the script's file and line. Never
    /// returns. Messages longer than `max_message` are cut off.
    pub fn raise(state: *State, comptime format: []const u8, arguments: anytype) noreturn {
        var buffer: [max_message]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, format, arguments) catch buffer[0..];
        c.luaL_where(state.raw(), 1);
        state.pushString(message);
        c.lua_concat(state.raw(), 2);
        c.lua_error(state.raw());
    }

    /// Raises the value on top of the stack as an error. Never returns.
    pub fn raiseTop(state: *State) noreturn {
        c.lua_error(state.raw());
    }

    // --- Loading --------------------------------------------------------------------------------

    /// Loads compiled `bytecode` as a function named `chunk` and pushes it. If loading fails,
    /// pushes the error message instead. The function uses the thread's globals. Loading can raise
    /// an out-of-memory error, so call it in protected mode (`protectedCallC`).
    pub fn load(state: *State, chunk: [:0]const u8, bytecode: []const u8) Status {
        return if (c.luau_load(state.raw(), chunk, bytecode.ptr, bytecode.len, 0) == 0) .ok else .syntax_error;
    }
};

/// The longest error message `State.raise` produces.
pub const max_message = 512;

/// Compiles Luau source code to bytecode, which must be freed with `Bytecode.free`. Returns null if
/// out of memory. If the source has errors, the bytecode encodes the error, which `State.load`
/// reports.
pub fn compile(source: []const u8) ?Bytecode {
    var options = std.mem.zeroes(c.lua_CompileOptions);
    options.optimizationLevel = optimization_level;
    options.debugLevel = debug_level;
    var len: usize = undefined;
    const ptr = c.luau_compile(source.ptr, source.len, &options, &len) orelse return null;
    return .{ .bytes = ptr[0..len] };
}

/// Bytecode allocated by the compiler with C's allocator.
pub const Bytecode = struct {
    bytes: []const u8,

    pub fn free(bytecode: Bytecode) void {
        std.c.free(@constCast(bytecode.bytes.ptr));
    }
};

/// Luau's baseline optimization, which keeps tracebacks complete.
const optimization_level = 1;

/// Keep line numbers and function names for errors and tracebacks.
const debug_level = 1;

/// A C function that Luau can call.
pub const Function = *const fn (?*c.lua_State) callconv(.c) c_int;

/// Wraps a Zig function as a C function for Luau. `run` returns the number of results it pushed.
pub fn wrap(comptime run: fn (*State) i32) Function {
    return &struct {
        fn call(raw_state: ?*c.lua_State) callconv(.c) c_int {
            return run(State.of(raw_state));
        }
    }.call;
}

/// Luau's allocator callback (`lua_Alloc`): resizes `ptr` from `old` to `new` bytes, frees it when
/// `new` is 0, and allocates when `ptr` is null.
pub const Allocate = *const fn (context: ?*anyopaque, ptr: ?*anyopaque, old: usize, new: usize) callconv(.c) ?*anyopaque;

/// The type of a Luau value (`lua_type`).
pub const Type = enum(c_int) {
    none = c.LUA_TNONE,
    nil = c.LUA_TNIL,
    boolean = c.LUA_TBOOLEAN,
    light_userdata = c.LUA_TLIGHTUSERDATA,
    number = c.LUA_TNUMBER,
    integer = c.LUA_TINTEGER,
    vector = c.LUA_TVECTOR,
    string = c.LUA_TSTRING,
    table = c.LUA_TTABLE,
    function = c.LUA_TFUNCTION,
    userdata = c.LUA_TUSERDATA,
    thread = c.LUA_TTHREAD,
    buffer = c.LUA_TBUFFER,
    class = c.LUA_TCLASS,
    _,
};

/// The result of a call or a load.
pub const Status = enum(c_int) {
    ok = c.LUA_OK,
    yield = c.LUA_YIELD,
    runtime_error = c.LUA_ERRRUN,
    syntax_error = c.LUA_ERRSYNTAX,
    memory_error = c.LUA_ERRMEM,
    handler_error = c.LUA_ERRERR,
    @"break" = c.LUA_BREAK,
    _,
};

/// A reference created by `State.ref`.
pub const Ref = enum(c_int) {
    _,
};

/// A userdata tag, which selects the userdata's metatable. Luau allows tags below
/// `c.LUA_UTAG_LIMIT`.
pub const Tag = std.math.IntFittingRange(0, c.LUA_UTAG_LIMIT - 1);

test "a script runs, and errors report the line" {
    const state = State.create(testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    state.sandbox();
    const thread = state.newSandboxedThread();

    const good = compile("local x = 40 + 2; return x").?;
    defer good.free();
    try std.testing.expectEqual(Status.ok, thread.load("=good", good.bytes));
    try std.testing.expectEqual(Status.ok, thread.protectedCall(0, 1));
    try std.testing.expectEqual(42, thread.toNumber(-1).?);
    thread.pop(1);

    const bad = compile("local t = nil\nreturn t.field").?;
    defer bad.free();
    try std.testing.expectEqual(Status.ok, thread.load("=bad", bad.bytes));
    try std.testing.expectEqual(Status.runtime_error, thread.protectedCall(0, 1));
    const message = thread.toString(-1).?;
    try std.testing.expect(std.mem.startsWith(u8, message, "bad:2: attempt to index nil"));
}

test "a syntax error is reported when loading" {
    const state = State.create(testing.allocate, null).?;
    defer state.close();
    const broken = compile("local = 1").?;
    defer broken.free();
    try std.testing.expectEqual(Status.syntax_error, state.load("=broken", broken.bytes));
    try std.testing.expect(std.mem.startsWith(u8, state.toString(-1).?, "broken:1:"));
}

test "the sandbox makes the standard libraries read-only" {
    const state = State.create(testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    state.sandbox();
    const thread = state.newSandboxedThread();
    const changing = compile("math.pi = 3").?;
    defer changing.free();
    try std.testing.expectEqual(Status.ok, thread.load("=changing", changing.bytes));
    try std.testing.expectEqual(Status.runtime_error, thread.protectedCall(0, 0));
    try std.testing.expect(std.mem.indexOf(u8, thread.toString(-1).?, "readonly") != null);
}

pub const testing = struct {
    /// An allocator for states in tests, using C's allocator.
    pub fn allocate(_: ?*anyopaque, ptr: ?*anyopaque, _: usize, new: usize) callconv(.c) ?*anyopaque {
        if (new == 0) {
            std.c.free(ptr);
            return null;
        }
        return std.c.realloc(ptr, new);
    }
};
