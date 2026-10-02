//! Scripting for mods ([#498](https://github.com/OpenReliant/openreliant/issues/498)): Luau scripts
//! that a mod lists in its manifest. This version runs load scripts, which change the game's
//! records at startup ([#555](https://github.com/OpenReliant/openreliant/issues/555)). The
//! [modding guide](../docs/guide/modding.md#scripts) explains how to write them, and
//! [docs/port/scripting.md](../docs/port/scripting.md) how they run.
//!
//! This module is linked into the game only, not into the library the tools share, because Luau is
//! a C++ library (`deps/luau`).
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");

pub const luau = @import("scripting/luau.zig");
pub const bind = @import("scripting/bind.zig");
pub const script = @import("scripting/script.zig");
pub const runtime = @import("scripting/runtime.zig");
pub const records = @import("scripting/records.zig");
pub const core = @import("scripting/core.zig");
pub const load = @import("scripting/load.zig");

pub const Records = records.Records;

test {
    std.testing.refAllDecls(@This());
}
