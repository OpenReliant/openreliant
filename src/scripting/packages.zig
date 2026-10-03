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

/// The namespace that declares `package`; null for a package made otherwise, or not made yet.
pub fn namespace(comptime package: script.Package) ?type {
    return switch (package) {
        .core => core.package,
        .world => world.package,
        .nearby => nearby.package,
        .records, .hooks, .self, .interfaces, .orders, .hud, .ui, .input, .camera, .audio, .postprocessing, .shaders, .storage, .async, .util, .vfs, .debug => null,
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
