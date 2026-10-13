//! OpenReliant's icon ([`assets/icon`](../../assets/icon)), which the window shows where the
//! system takes a window's icon from the window: on macOS, where it is also the application's in
//! the Dock, and on Linux (`platform.window.Window.setIcon`). On Windows, the executables carry it
//! (`src/tools/build_resources.zig`).

const std = @import("std");

const openreliant = @import("openreliant");

/// The icon as PNG files, at the size for a display at 100% and at the size for one at 200%.
pub const pngs = [_][]const u8{ @embedFile("openreliant-256.png"), @embedFile("openreliant-512.png") };

test pngs {
    for (pngs, [_]u32{ 256, 512 }) |file, side| {
        try std.testing.expectEqual([2]u32{ side, side }, try openreliant.png.size(file));
    }
}
