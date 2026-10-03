//! The `openreliant.vfs` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! reading the game's and the mods' files, which scripts can't change (`package`). A file comes as
//! a string of its bytes.
//!
//! Not ported: reading the game's loose files, such as the missions folder's
//! ([#592](https://github.com/OpenReliant/openreliant/issues/592)).

const std = @import("std");

const luau = @import("luau.zig");
const State = luau.State;
const api = @import("api.zig");
const Call = api.Call;

/// What `openreliant.vfs` holds.
pub const package = struct {
    pub const read = api.Native("The file `name` as the game reads it: a mod's, the latest mod's first, or else the game's own, as a string of its bytes. Nil where there's none.", "name: string", "string?", readGame);
    pub const read_mod = api.Native("The calling mod's own file `name`, as a string of its bytes. Nil where it has none.", "name: string", "string?", readMod);
    pub const exists = api.Native("Whether the game has the file `name`, in a mod or of its own.", "name: string", "boolean", fileExists);
};

/// `vfs.read(name)`.
fn readGame(state: *State) i32 {
    const call: Call = .of(state, "vfs.read");
    const name = nameOf(state, "vfs.read");
    const files = call.runtime().options.shared.files orelse return pushNone(state);
    if (!files.has(name)) return pushNone(state);
    const gpa = call.runtime().gpa;
    const bytes = files.readFile(gpa, name) catch |err| state.raise("vfs.read: {s} can't be read: {s}", .{ name, @errorName(err) });
    return pushBytes(state, gpa, bytes);
}

/// `vfs.read_mod(name)`.
fn readMod(state: *State) i32 {
    const call: Call = .of(state, "vfs.read_mod");
    const name = nameOf(state, "vfs.read_mod");
    const gpa = call.runtime().gpa;
    const bytes = call.context.modOf().readFile(gpa, name) catch |err| state.raise("vfs.read_mod: {s} can't be read: {s}", .{ name, @errorName(err) });
    return pushBytes(state, gpa, bytes orelse return pushNone(state));
}

/// `vfs.exists(name)`.
fn fileExists(state: *State) i32 {
    const call: Call = .of(state, "vfs.exists");
    const name = nameOf(state, "vfs.exists");
    const files = call.runtime().options.shared.files;
    state.pushBoolean(if (files) |held| held.has(name) else false);
    return 1;
}

fn nameOf(state: *State, comptime label: []const u8) []const u8 {
    return state.toString(1) orelse state.raise(label ++ ": expected a file's name, got {s}", .{state.typeName(1)});
}

fn pushNone(state: *State) i32 {
    state.pushNil();
    return 1;
}

/// Pushes `bytes` as a string, which the state copies, and lets them go. Luau's errors skip Zig's
/// defers: should the copy run out of memory, the bytes are lost until OpenReliant quits.
fn pushBytes(state: *State, gpa: std.mem.Allocator, bytes: []u8) i32 {
    if (!state.checkStack(1)) {
        gpa.free(bytes);
        state.raise("out of memory", .{});
    }
    state.pushString(bytes);
    gpa.free(bytes);
    return 1;
}
