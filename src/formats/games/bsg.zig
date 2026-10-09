//! Battlestar Galactica (2003), an Xbox and PlayStation 2 game by Warthog, who developed
//! StarLancer: its missions, its command catalogue and its comms films. Its discs and executable
//! are the Xbox's (`xbox`).

pub const mission = @import("bsg/mission.zig");
pub const catalogue = @import("bsg/catalogue.zig");
pub const comms = @import("bsg/comms.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
