//! Battlestar Galactica (2003), an Xbox and PlayStation 2 game by Warthog, who developed
//! StarLancer: its missions, its command catalogue, its comms films, its archives and the models,
//! textures and objects' definitions they hold. Its discs and executable are the Xbox's (`xbox`).

pub const mission = @import("bsg/mission.zig");
pub const catalogue = @import("bsg/catalogue.zig");
pub const comms = @import("bsg/comms.zig");
pub const wart = @import("bsg/wart.zig");
pub const resource = @import("bsg/resource.zig");
pub const texture = @import("bsg/texture.zig");
pub const mesh = @import("bsg/mesh.zig");
pub const text = @import("bsg/text.zig");
pub const model = @import("bsg/model.zig");
pub const level = @import("bsg/level.zig");
pub const to_gltf = @import("bsg/to_gltf.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
