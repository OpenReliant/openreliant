//! The PlayStation's own formats, which the PlayStation games on StarLancer's engine use: the
//! executable that a disc starts, and TIM pictures. The discs' Mode 2 sectors are in `cdimage.zig`.

pub const exe = @import("playstation/exe.zig");
pub const tim = @import("playstation/tim.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
