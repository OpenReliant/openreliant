//! The packages that are made from declarations (`api.zig`), and where each is declared. The rest
//! are made by their own modules: the records (`records.zig`), the hooks (`hooks.zig`), the
//! interfaces (`interfaces.zig`), and the script's own object (`self`, `runtime.zig`).

const std = @import("std");

const script = @import("script.zig");
const runtime = @import("runtime.zig");
const api = @import("api.zig");
const core = @import("core.zig");
const world = @import("world.zig");
const nearby = @import("nearby.zig");
const drawing = @import("drawing.zig");
const input = @import("input.zig");
const camera = @import("camera.zig");
const audio = @import("audio.zig");
const storage = @import("storage.zig");
const async_package = @import("async.zig");
const vfs = @import("vfs.zig");
const util = @import("util.zig");
const orders = @import("orders.zig");
const settings = @import("settings.zig");
const postprocessing = @import("postprocessing.zig");
const shaders = @import("shaders.zig");

/// The namespace that declares `package`; null for a package made otherwise, or not made yet.
pub fn namespace(comptime package: script.Package) ?type {
    return switch (package) {
        .core => core.package,
        .world => world.package,
        .nearby => nearby.package,
        .hud => drawing.Package(.hud),
        .ui => drawing.Package(.ui),
        .debug => drawing.debug,
        .input => input.package,
        .camera => camera.package,
        .audio => audio.package,
        .storage => storage.package,
        .async => async_package.package,
        .vfs => vfs.package,
        .util => util.package,
        .orders => orders.package,
        .settings => settings.package,
        .postprocessing => postprocessing.package,
        .shaders => shaders.package,
        .records, .hooks, .self, .interfaces => null,
    };
}

/// Makes each declared package what `require` returns for it in `scripts`.
pub fn push(scripts: *runtime.Runtime) void {
    inline for (comptime std.enums.values(script.Package)) |package| {
        if (comptime namespace(package)) |Namespace| {
            api.pushPackage(scripts.state, package, Namespace);
            scripts.setPackage(package);
        }
    }
}

comptime {
    // A declared package is one this version has.
    for (std.enums.values(script.Package)) |package| {
        if (namespace(package) != null and !package.ready()) @compileError("the package " ++ @tagName(package) ++ " is declared but not ready");
    }
}
