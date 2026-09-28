//! `C:\lancer\GenILib`: the interface library the front end's screens run in.

const std = @import("std");

pub const interf = @import("genilib/interf.zig");

test {
    std.testing.refAllDecls(@This());
}
