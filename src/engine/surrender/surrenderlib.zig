//! `C:\lancer\surrender\surrenderlib`: the Surrender library, a module for each file this project
//! describes.

const std = @import("std");

pub const srapi = @import("surrenderlib/srapi.zig");
pub const srapiext = @import("surrenderlib/srapiext.zig");
pub const srbmo = @import("surrenderlib/srbmo.zig");
pub const srclip = @import("surrenderlib/srclip.zig");
pub const srcore = @import("surrenderlib/srcore.zig");
pub const srimage = @import("surrenderlib/srimage.zig");
pub const srlight = @import("surrenderlib/srlight.zig");
pub const srmesh = @import("surrenderlib/srmesh.zig");
pub const srshadow = @import("surrenderlib/srshadow.zig");
pub const srstars = @import("surrenderlib/srstars.zig");
pub const srtexture = @import("surrenderlib/srtexture.zig");

test {
    std.testing.refAllDecls(@This());
}
