//! Star Trek: Invasion (Activision, 2000), a PlayStation game by Warthog, who developed the
//! original: its archive, its missions and its models. Its pictures are the PlayStation's TIM
//! pictures (`playstation.tim`).

pub const res = @import("trek/res.zig");
pub const dsm = @import("trek/dsm.zig");
pub const trk = @import("trek/trk.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
