//! The screen's flash, in `C:\lancer\game\main.cpp`: a capital ship coming apart close by lights
//! the whole view white for a moment (`0x00587CC8`), which `mission_frame` draws and counts down
//! (`screen_flash_draw`, `0x00494940`), and shows red while the player's display is shaken by a
//! hit (`hud.Interference`). **Unverified:** `0x00494940` lies after `main.cpp`'s known code,
//! before `matmanager.cpp`'s; by what it does it is this file's.
//!
//! A capital ship's engine exhaust whites the view out by its flash, and keeps the red away while
//! the player's ship stands in it (`environfx.Exhaust`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const Vector = math.Vector;
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const gameobj = @import("../gameobj.zig");
const xtrabits = @import("../xtrabits.zig");

/// How long a flash lasts, in ticks, and how bright it is for each tick left, no more than one
/// (`0x004DC954`): white for its first 17 ticks, then fading out.
pub const flash_ticks = 100;
const per_tick: f32 = 0.012;

/// How near the camera must be for a ship to flash the view as it comes apart, in its radii
/// (`0x004DC56C`).
const near_radii: f32 = 5;

/// How far beyond the near plane the sprite stands, as the mission's start makes it
/// (`0x004DC404`, at `0x00493C97`).
const beyond_near: f32 = 1;

/// The flash: how many ticks it has left (`0x00587CC8`), and the sprite that covers the view
/// (`0x00587CCC`), made as a mission starts (`0x00493CA8`): untextured, coloured by its own colour,
/// and added to what is drawn.
pub const Flash = struct {
    left: i32 = 0,
    sprite: [1]srapiext.Sprite = .{.{}},
    set: srapiext.SpriteSet = .{ .surface = .{ .material = .onePass(.{ .coordinates = .none, .lit = true, .blend = .add }) }, .sprites = &.{} },

    /// Lights the view for `flash_ticks`.
    pub fn start(flash: *Flash) void {
        flash.left = flash_ticks;
    }

    /// `explode_flash_near` (`0x00471D70`): lights the view where the camera, at `camera`, stands
    /// within `near_radii` of `object`.
    pub fn near(flash: *Flash, object: *const gameobj.GameObject, camera: Vector) void {
        if (math.distance(gameobj.vector(object.root.position), camera) < object.radius * near_radii) flash.start();
    }

    /// `screen_flash_draw` (`0x00494940`), once a frame but while paused: while the flash lasts,
    /// the sprite is white, as bright as its ticks left give it, and it counts down the frame's
    /// `ticks`; while `red`, the display's interference in the view ahead, is above zero, the
    /// sprite is red at it instead. Either way the sprite goes into the overlay's layer, just
    /// beyond the near plane of the camera at `camera`, reaching the width and the height of the
    /// view there either side. The caller fades the interference after (`hud.Interference.fade`).
    pub fn draw(flash: *Flash, gpa: Allocator, scene: *srcore.Scene, camera: math.Place, projection: srapi.Projection, ticks: i32, red: f32) Allocator.Error!void {
        const flashing = flash.left > 0;
        if (flashing) {
            const bright = @min(@as(f32, @floatFromInt(flash.left)) * per_tick, 1);
            flash.sprite[0].colour = .{ bright, bright, bright };
            flash.left -= ticks;
        }
        if (red > 0) flash.sprite[0].colour = .{ red, 0, 0 };
        if (!flashing and !(red > 0)) return;
        const distance = projection.near + beyond_near;
        const bounds = projection.bounds;
        flash.sprite[0].half_size = .{ (bounds[2] - bounds[0]) * distance, (bounds[3] - bounds[1]) * distance };
        flash.set.sprites = &flash.sprite;
        flash.set.position = camera.ahead(distance);
        try xtrabits.sceneAdd(gpa, scene, .{ .sprites = &flash.set }, .overlay);
    }
};

test Flash {
    const gpa = std.testing.allocator;
    var flash: Flash = .{};
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    const projection: srapi.Projection = .init(640, 480, .{ 0, 0, 1, 1 }, .{ 1, 1 });

    // Nothing shows until it is lit.
    try flash.draw(gpa, &scene, .{}, projection, 1, 0);
    try std.testing.expectEqual(0, scene.layers.get(.overlay).items.len);

    // A ship coming apart within five of its radii of the camera lights it; further off, not.
    var object = std.mem.zeroes(gameobj.GameObject);
    object.radius = 100;
    object.root.position = .{ .x = 0, .y = 0, .z = 600 };
    flash.near(&object, @splat(0));
    try std.testing.expectEqual(0, flash.left);
    object.root.position.z = 400;
    flash.near(&object, @splat(0));
    try std.testing.expectEqual(flash_ticks, flash.left);

    // White at first, in front of the camera over the whole view, counting down the frame's ticks.
    try flash.draw(gpa, &scene, .{}, projection, 50, 0);
    try std.testing.expectEqual(1, scene.layers.get(.overlay).items.len);
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, flash.sprite[0].colour);
    try std.testing.expect(flash.set.position[2] > projection.near);
    try std.testing.expectEqual(50, flash.left);
    // Then fading.
    try flash.draw(gpa, &scene, .{}, projection, 50, 0);
    try std.testing.expectApproxEqAbs(0.6, flash.sprite[0].colour[0], 1e-5);
    try std.testing.expectEqual(0, flash.left);

    // A hit's interference shows it red at its level, over the white.
    scene.clear();
    try flash.draw(gpa, &scene, .{}, projection, 1, 0.3);
    try std.testing.expectEqual(1, scene.layers.get(.overlay).items.len);
    try std.testing.expectEqual([3]f32{ 0.3, 0, 0 }, flash.sprite[0].colour);
}
