//! `C:\lancer\surrender\srD3D`: Surrender's Direct3D 7 driver, built as `srd3d.dll`.

const std = @import("std");

pub const device = @import("srd3d/device.zig");
pub const srd3d = @import("srd3d/srd3d.zig");

test {
    std.testing.refAllDecls(@This());
}
