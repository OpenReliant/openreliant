//! The Xbox's own formats, which the Xbox games on StarLancer's engine use: the discs' filesystem
//! and the executables.

pub const xdvdfs = @import("xbox/xdvdfs.zig");
pub const xbe = @import("xbox/xbe.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
