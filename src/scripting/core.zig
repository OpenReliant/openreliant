//! The `openreliant.core` package ([#498](https://github.com/OpenReliant/openreliant/issues/498)),
//! available to every script. It only has the OpenReliant version so far; later versions add to it.

const std = @import("std");
const luau = @import("luau.zig");
const State = luau.State;

/// Pushes the package for OpenReliant `version`, such as `0.7.0`.
pub fn push(state: *State, version: []const u8) void {
    state.newTable(0, 1);
    state.pushString(version);
    state.rawSetField(-2, "version");
    state.setReadonly(-1, true);
}

test push {
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    push(state, "0.7.0");
    state.setGlobal("core");
    state.sandbox();
    const thread = state.newSandboxedThread();
    try @import("bind.zig").testing.runSource(thread, "assert(core.version == '0.7.0')");
    try @import("bind.zig").testing.expectSourceError(thread, "core.version = '1'", "readonly");
}
