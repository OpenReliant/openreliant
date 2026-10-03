//! Scripting for mods ([#498](https://github.com/OpenReliant/openreliant/issues/498)): Luau scripts
//! that a mod lists in its manifest. This version runs load scripts, which change the game's
//! records at startup ([#555](https://github.com/OpenReliant/openreliant/issues/555)), global
//! scripts, which run as the game plays and hook its functions and events
//! ([#556](https://github.com/OpenReliant/openreliant/issues/556)), and object scripts, which run
//! on the objects of a mission, with events and interfaces between scripts, and player and menu
//! scripts, which draw over the display and the menus, with a console for modders
//! ([#557](https://github.com/OpenReliant/openreliant/issues/557)). The
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
pub const running = @import("scripting/running.zig");
pub const api = @import("scripting/api.zig");
pub const data = @import("scripting/data.zig");
pub const stored = @import("scripting/stored.zig");
pub const snapshot = @import("scripting/snapshot.zig");
pub const vfs = @import("scripting/vfs.zig");
pub const util = @import("scripting/util.zig");
pub const orders = @import("scripting/orders.zig");
pub const async = @import("scripting/async.zig");
pub const storage = @import("scripting/storage.zig");
pub const settings = @import("scripting/settings.zig");
pub const events = @import("scripting/events.zig");
pub const interfaces = @import("scripting/interfaces.zig");
pub const world = @import("scripting/world.zig");
pub const nearby = @import("scripting/nearby.zig");
pub const packages = @import("scripting/packages.zig");
pub const drawing = @import("scripting/drawing.zig");
pub const presentation = @import("scripting/presentation.zig");
pub const input = @import("scripting/input.zig");
pub const camera = @import("scripting/camera.zig");
pub const audio = @import("scripting/audio.zig");
pub const load = @import("scripting/load.zig");
pub const game = @import("scripting/game.zig");
pub const reference = @import("scripting/reference.zig");
pub const console = @import("scripting/console.zig");

pub const Records = records.Records;
pub const Game = game.Game;
pub const Presentation = presentation.Presentation;

test {
    std.testing.refAllDecls(@This());
}
