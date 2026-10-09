//! The Xbox's own formats, which the Xbox games on StarLancer's engine use: the discs' filesystem,
//! the executables and the order of a texture's texels.

pub const xdvdfs = @import("xbox/xdvdfs.zig");
pub const xbe = @import("xbox/xbe.zig");
pub const swizzle = @import("xbox/swizzle.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
