//! The platform OpenReliant runs on, in place of Win32 and DirectX: SDL3. Nothing here is the
//! game's; the game's code in `openreliant` reaches the platform only through what this exposes.

const std = @import("std");

pub const audio = @import("platform/audio.zig");
pub const fonts = @import("platform/fonts.zig");
pub const gpu = @import("platform/gpu.zig");
pub const joystick = @import("platform/joystick.zig");
pub const keyboard = @import("platform/keyboard.zig");
pub const video = @import("platform/video.zig");
pub const window = @import("platform/window.zig");

test {
    std.testing.refAllDecls(@This());
}
