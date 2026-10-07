//! What `openreliant` draws with, and the frames it draws outside the game's loop: the loading
//! screens' and the movies'.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const srapi = engine.surrender.surrenderlib.srapi;
const srcore = engine.surrender.surrenderlib.srcore;
const srd3d = engine.surrender.srd3d;
const screenshot = engine.game.xtrabits.screenshot;

const log = std.log.scoped(.screenshot);

/// Frames drawn outside the game's loop, as the loading screens' and the movies' are: an overlay
/// drawn over an empty scene and put on the window at once.
pub const Presenter = struct {
    window: *platform.window.Window,
    /// The GPU the driver draws with.
    gpu: *platform.gpu.Gpu,
    driver: *srd3d.srd3d.Driver,
    context: *srapi.Context,
    /// The scene, empty, and what a frame is drawn in.
    scene: srcore.Scene = .{},
    frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

    pub fn close(presenter: *Presenter, gpa: Allocator) void {
        presenter.scene.deinit(gpa);
        presenter.frame_arena.deinit();
    }

    /// The size the frames are drawn at, as the GPU's settings have it, of the window's size at
    /// the display's own density.
    pub fn size(presenter: *const Presenter) [2]u32 {
        return presenter.gpu.frameSize();
    }

    /// Draws a frame of `overlay` alone and puts it on the window.
    pub fn present(presenter: *Presenter, overlay: srcore.Overlay) !void {
        return presenter.presentScene(presenter.context, &presenter.scene, overlay);
    }

    /// Draws a frame of `scene`, as the camera and the projection of `context` have it and over
    /// its background, with `overlay` over it, and puts it on the window.
    pub fn presentScene(presenter: *Presenter, context: *srapi.Context, scene: *srcore.Scene, overlay: srcore.Overlay) !void {
        _ = presenter.frame_arena.reset(.retain_capacity);
        try srcore.render(presenter.frame_arena.allocator(), context, scene, presenter.driver.interface(), overlay);
    }

    /// The last frame drawn: what a screenshot saves, as the game grabs the screen (`sr + 0x7C`).
    /// The caller owns the pixels.
    pub fn capture(presenter: *Presenter, gpa: Allocator) !screenshot.Picture {
        const frame = try presenter.gpu.capture(gpa);
        return .{ .rgba = frame.rgba, .size = frame.size };
    }

    /// Saves the last frame drawn as the next of `screenshots` (`screenshot_save`), which says
    /// where once it is written. A failure is logged, and the game goes on.
    pub fn saveScreenshot(presenter: *Presenter, gpa: Allocator, screenshots: *screenshot.Screenshots) void {
        const picture = presenter.capture(gpa) catch |err| return log.err("the screen can't be read: {s}", .{@errorName(err)});
        screenshots.save(gpa, picture) catch |err| log.err("the screenshot can't be saved: {s}", .{@errorName(err)});
    }
};

/// What an overlay's drawing fails with: running out of memory alone. A shape the file does not
/// hold draws nothing, as it does in the game.
pub fn drawn(result: anytype) Allocator.Error!void {
    result catch |err| switch (err) {
        error.OutOfMemory => |out| return out,
        else => {},
    };
}
