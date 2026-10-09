//! The Dreamcast version of StarLancer: the formats it has where the PC version has others. Its
//! archives, missions, models, stat tables, face films and speech are the PC's, and the
//! DiscJuggler `.cdi` images its discs are often kept in are read by `cdimage`.

pub const pvr = @import("dreamcast/pvr.zig");
pub const textures = @import("dreamcast/textures.zig");
pub const text = @import("dreamcast/text.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
