//! Plain data, which scripts pass to each other in events
//! ([#498](https://github.com/OpenReliant/openreliant/issues/498)): `nil`, booleans, numbers,
//! strings, vectors, object handles, and tables of these. A value passed on is copied as it's
//! passed, so the sender can't change it afterwards, and a table that holds anything else, or
//! itself, is an error. Keeping to plain data means events can later be saved, and sent to other
//! machines in a multiplayer game.

const luau = @import("luau.zig");
const State = luau.State;
const objects = @import("objects.zig");
const Runtime = @import("runtime.zig").Runtime;

/// Plain data a script passed on: a copy, held by a reference that its holder lets go
/// (`Runtime.release`).
pub const Data = struct {
    ref: luau.Ref,
};

/// How deep tables may hold tables. A table that holds itself goes past it.
pub const max_depth = 32;

/// How much stack copying one level takes: the copy, a key and a value, and their copies.
const level_stack = 5;

/// Pushes a copy of the plain data at `given`. Raises an error naming `label` for anything that
/// isn't plain data.
pub fn copy(state: *State, given: i32, comptime label: []const u8) void {
    copyAt(state, state.absolute(given), label, 0);
}

/// Copies the plain data `ref` holds in `from`'s state into `to`'s, as an event from a player
/// script goes to the game's scripts, and returns a reference to the copy there; null if memory
/// runs out. The data was checked as it was copied the first time (`copy`).
pub fn transfer(from: *State, ref: luau.Ref, to: *Runtime) ?luau.Ref {
    const base = from.top();
    defer from.setTop(base);
    if (!from.checkStack(1)) return null;
    _ = from.pushRef(ref);
    return to.make(copyAcross, .{ from, from.top() });
}

fn copyAcross(state: *State, from: *State, at: i32) void {
    copyFrom(state, from, at, 0);
}

/// Pushes on `to` a copy of the plain data at `at` in `from`.
fn copyFrom(to: *State, from: *State, at: i32, depth: u32) void {
    if (!to.checkStack(level_stack) or !from.checkStack(level_stack)) to.raise("out of memory", .{});
    switch (from.typeOf(at)) {
        .boolean => to.pushBoolean(from.toBoolean(at)),
        .number => to.pushNumber(from.toNumber(at).?),
        .string => to.pushString(from.toString(at).?),
        .vector => to.pushVector(from.toVector(at).?),
        .userdata => objects.pushHandle(to, from.toUserdata(objects.Handle, at, objects.Handle.tag).?.*),
        .table => {
            if (depth == max_depth) to.raise("tables nest more than {d} deep", .{max_depth});
            to.newTable(0, 0);
            const made = to.top();
            from.pushNil();
            while (from.next(at)) {
                const value = from.top();
                copyFrom(to, from, value - 1, depth + 1);
                copyFrom(to, from, value, depth + 1);
                to.rawSet(made);
                from.pop(1);
            }
        },
        // Nothing else passes `copy`.
        else => to.pushNil(),
    }
}

fn copyAt(state: *State, at: i32, comptime label: []const u8, depth: u32) void {
    if (!state.checkStack(level_stack)) state.raise("{s}: out of memory", .{label});
    switch (state.typeOf(at)) {
        // These can't change, so the value itself serves.
        .nil, .none, .boolean, .number, .string, .vector => state.pushCopy(at),
        .userdata => {
            if (state.toUserdata(objects.Handle, at, objects.Handle.tag) == null) state.raise("{s}: only plain data can be passed on, not {s}", .{ label, state.typeName(at) });
            state.pushCopy(at);
        },
        .table => {
            if (depth == max_depth) state.raise("{s}: tables nest more than {d} deep, or a table holds itself", .{ label, max_depth });
            state.newTable(0, 0);
            const made = state.top();
            state.pushNil();
            while (state.next(at)) {
                const value = state.top();
                copyAt(state, value - 1, label, depth + 1);
                copyAt(state, value, label, depth + 1);
                state.rawSet(made);
                state.pop(1);
            }
        },
        else => state.raise("{s}: only plain data can be passed on, not {s}", .{ label, state.typeName(at) }),
    }
}

test copy {
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    state.pushFunction(luau.wrap(struct {
        fn run(called: *State) i32 {
            copy(called, 1, "data");
            return 1;
        }
    }.run), "copy");
    state.setGlobal("copy");
    state.sandbox();
    const thread = state.newSandboxedThread();
    const bind = @import("bind.zig");
    try bind.testing.runSource(thread,
        \\local sent = { name = "wing", count = 3, at = vector.create(1, 2, 3), list = { true, "a" } }
        \\local got = copy(sent)
        \\assert(got ~= sent and got.list ~= sent.list)
        \\assert(got.name == "wing" and got.count == 3 and got.at == vector.create(1, 2, 3))
        \\assert(got.list[1] == true and got.list[2] == "a")
        \\sent.count = 4
        \\assert(got.count == 3)
        \\assert(copy(5) == 5 and copy(nil) == nil)
    );
    try bind.testing.expectSourceError(thread, "copy({ f = print })", "only plain data");
    try bind.testing.expectSourceError(thread, "local t = {}; t.t = t; copy(t)", "holds itself");
}
