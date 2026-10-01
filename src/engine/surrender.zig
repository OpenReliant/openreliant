//! `C:\lancer\surrender`: the Surrender renderer. The library is linked into the payload; each
//! driver is a DLL of its own.

const std = @import("std");

pub const colour = @import("surrender/colour.zig");
pub const math = @import("surrender/math.zig");
pub const srd3d = @import("surrender/srd3d.zig");
pub const surrenderlib = @import("surrender/surrenderlib.zig");

test {
    std.testing.refAllDecls(@This());
}
