//! The player and menu scripts' frames in each of `openreliant`'s loops: the main loop, the rooms'
//! (`rooms.zig`) and the movies' (`movies.zig`).
//! Each loop hands the scripts the keys its window reads, runs their frame before it draws, with
//! what each of their layers is drawn on, and draws their user interface layer last.
//!
//! **Improvement:** the original has no scripting apart from its mission scripts.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const scripting = @import("scripting");
const engine = openreliant.engine;
const game = engine.game;
const hud = game.hud;
const device = engine.surrender.srd3d.device;
const ScriptConsole = @import("console.zig").Driver;

pub const ScriptFrames = struct {
    gpa: Allocator,
    presentation: *scripting.Presentation,
    devices: *engine.input.Devices,
    sound: *game.hog_snd.Sound,
    /// What draws the outline fonts, where OpenReliant has one.
    rasterizer: ?hud.outline.Rasterizer,
    /// The fonts scripts can name besides their layer's own.
    fonts: std.EnumArray(scripting.drawing.Font, ?*hud.Opened) = .initFill(null),
    /// When the last frame ran, which the next one's seconds count from.
    presented_at: u64 = 0,
    /// The scripting console, while the scripts don't hear the keys; null without it.
    console: ?*const ScriptConsole = null,

    /// What a frame tells the scripts, in a window `window` pixels in size, with `flying` saying
    /// whether the player is flying: the seconds since the last frame, the devices and the sound.
    /// No layer is shown until `show` shows it.
    pub fn host(frames: *ScriptFrames, window: [2]u32, flying: bool) scripting.presentation.Host {
        const now = platform.window.nanoseconds();
        defer frames.presented_at = now;
        return .{
            .seconds = @as(f32, @floatFromInt(now -| frames.presented_at)) / std.time.ns_per_s,
            .devices = frames.devices,
            .window = window,
            .sound = frames.sound,
            .flying = flying,
        };
    }

    /// Shows the layer `which` of `told`, written with `font` at `scale` of the window's pixels to
    /// the game's, its shapes from `art`, with the fonts scripts can name.
    pub fn show(frames: *const ScriptFrames, told: *scripting.presentation.Host, which: scripting.drawing.Which, font: *hud.Opened, scale: f32, art: ?*hud.Art) void {
        var view: scripting.drawing.View = .{ .font = font, .gpa = frames.gpa, .screen = told.window, .scale = scale, .art = art, .rasterizer = frames.rasterizer };
        for (std.enums.values(scripting.drawing.Font)) |named| {
            if (named != .default) view.fonts.set(named, frames.fonts.get(named));
        }
        told.views.set(which, view);
    }

    /// A frame of a screen with a loop of its own, such as a room or a movie, in a window `window`
    /// pixels in size: the scripts draw on the user interface layer, in the menus' small font, at
    /// the front end's scale. Without that font, the scripts don't run.
    pub fn screenFrame(frames: *ScriptFrames, window: [2]u32) void {
        const font = frames.fonts.get(.menu_small) orelse return;
        var shown = frames.host(window, false);
        frames.show(&shown, .ui, font, game.interface.canvas.scaleFor(window), null);
        frames.presentation.frame(shown);
    }

    /// The scripts hear a key `scan` go down or up, except a key pressed while the console is up,
    /// or the key that brings it up.
    pub fn key(frames: *ScriptFrames, scan: engine.input.Key, down: bool) void {
        if (down and frames.withholds(scan)) return;
        frames.presentation.key(scan, down);
    }

    /// Whether the console keeps a press of `scan` from the scripts.
    fn withholds(frames: *const ScriptFrames, scan: engine.input.Key) bool {
        const console = frames.console orelse return false;
        return console.isUp() or scan == scripting.console.key;
    }

    /// Draws what the scripts drew on the user interface layer into `into`, last over the screen.
    pub fn drawUi(frames: *const ScriptFrames, into: device.Device) Allocator.Error!void {
        try frames.presentation.draw(.ui, into, null);
    }
};

test ScriptFrames {
    var devices: engine.input.Devices = .{};
    var small: hud.Opened = undefined;
    var large: hud.Opened = undefined;
    var frames: ScriptFrames = .{ .gpa = std.testing.allocator, .presentation = undefined, .devices = &devices, .sound = undefined, .rasterizer = null };
    frames.fonts.set(.menu_small, &small);
    frames.fonts.set(.menu_large, &large);
    // A frame counts its seconds from the last, and shows no layer until one is shown.
    const before = platform.window.nanoseconds();
    var told = frames.host(.{ 640, 480 }, true);
    try std.testing.expect(told.seconds >= @as(f32, @floatFromInt(before)) / std.time.ns_per_s);
    try std.testing.expect(frames.presented_at >= before);
    try std.testing.expect(told.flying);
    try std.testing.expectEqual(null, told.views.get(.ui));
    // A layer shown writes in its own font, and can name the others.
    frames.show(&told, .ui, &small, 2, null);
    const view = told.views.get(.ui).?;
    try std.testing.expectEqual(&small, view.fontOf(.default).?);
    try std.testing.expectEqual(&large, view.fontOf(.menu_large).?);
    try std.testing.expectEqual(null, view.fontOf(.hud));
    try std.testing.expectEqual([2]u32{ 640, 480 }, view.screen);
}

test "ScriptFrames.key" {
    var console: ScriptConsole = .{ .console = .{ .gpa = std.testing.allocator, .mods = &.{} } };
    var frames: ScriptFrames = .{ .gpa = std.testing.allocator, .presentation = undefined, .devices = undefined, .sound = undefined, .rasterizer = null, .console = &console };
    // While the console is down, only the key that brings it up is kept from the scripts.
    try std.testing.expect(frames.withholds(scripting.console.key));
    try std.testing.expect(!frames.withholds(.a));
    // While it's up, they hear no key pressed.
    console.console.open = true;
    try std.testing.expect(frames.withholds(.a));
    // Without the console, they hear every key.
    frames.console = null;
    try std.testing.expect(!frames.withholds(scripting.console.key));
}
