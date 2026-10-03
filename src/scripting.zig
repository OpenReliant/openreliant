//! Scripting for mods ([#498](https://github.com/OpenReliant/openreliant/issues/498)): Luau scripts
//! that a mod lists in its manifest. This version runs load scripts, which change the game's
//! records at startup ([#555](https://github.com/OpenReliant/openreliant/issues/555)), and global
//! scripts, which run as the game plays and hook its functions and events
//! ([#556](https://github.com/OpenReliant/openreliant/issues/556)). The
//! [scripting guide](../docs/guide/scripting.md) explains how to write them, and
//! [docs/port/scripting.md](../docs/port/scripting.md) how they run.
//!
//! This module is linked into the game only, not into the library the tools share, because Luau is
//! a C++ library (`deps/luau`).
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");

pub const luau = @import("scripting/luau.zig");
pub const values = @import("scripting/values.zig");
pub const bind = @import("scripting/bind.zig");
pub const script = @import("scripting/script.zig");
pub const runtime = @import("scripting/runtime.zig");
pub const records = @import("scripting/records.zig");
pub const core = @import("scripting/core.zig");
pub const objects = @import("scripting/objects.zig");
pub const hooks = @import("scripting/hooks.zig");
pub const load = @import("scripting/load.zig");
pub const game = @import("scripting/game.zig");
pub const reference = @import("scripting/reference.zig");

pub const Records = records.Records;
pub const Game = game.Game;

test {
    std.testing.refAllDecls(@This());
}
