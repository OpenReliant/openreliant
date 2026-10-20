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

/// The flash: how many ticks it has left (`0x00587CC8`). The game lights it and counts it down,
/// and drawing only reads it (`draw`).
pub const Flash = struct {
    left: i32 = 0,

    /// Lights the view for `flash_ticks`.
    pub fn start(flash: *Flash) void {
        flash.left = flash_ticks;
    }

    /// `explode_flash_near` (`0x00471D70`): lights the view where the camera, at `camera`, stands
    /// within `near_radii` of `object`.
    pub fn near(flash: *Flash, object: *const gameobj.GameObject, camera: Vector) void {
        if (math.distance(object.position(), camera) < object.radius * near_radii) flash.start();
    }

    /// `screen_flash_draw`'s countdown (`0x00494940`): while the flash lasts, it counts down the
    /// frame's `ticks`. The game counts it down right after it draws it, in each frame that isn't
    /// paused. OpenReliant counts it down at the start of the next game frame
    /// (`main.missionFrame`), so the flash drawn after a game frame is the one the game draws in
    /// it.
    pub fn countDown(flash: *Flash, ticks: i32) void {
        if (flash.left > 0) flash.left -= ticks;
    }

    /// How bright it shows: `per_tick` for each tick left, no more than one.
    fn brightness(flash: Flash) f32 {
        return @min(@as(f32, @floatFromInt(flash.left)) * per_tick, 1);
    }

    /// The rest of `screen_flash_draw`: while the flash lasts, the sprite is white, as bright as
    /// its ticks left make it. While `red`, the display's interference in the view ahead, is
    /// above zero, the sprite is red at that level instead. Either way the sprite goes into the
    /// overlay's layer, just beyond the near plane of the camera at `camera`, and reaches the width
    /// and the height of the view there on either side. It is drawn from a copy of `cover` made in
    /// `arena`, which lasts until the frame is drawn (`xtrabits.sceneAddCopy`). The caller fades
    /// the interference afterwards (`hud.Interference.Shown.fade`).
    pub fn draw(flash: *const Flash, gpa: Allocator, arena: Allocator, scene: *srcore.Scene, camera: math.Place, projection: srapi.Projection, red: f32) Allocator.Error!void {
        const colour: [3]f32 = if (red > 0) .{ red, 0, 0 } else if (flash.left > 0) @splat(flash.brightness()) else return;
        const distance = projection.near + beyond_near;
        const bounds = projection.bounds;
        const sprite: srapiext.Sprite = .{
            .colour = colour,
            .half_size = .{ (bounds[2] - bounds[0]) * distance, (bounds[3] - bounds[1]) * distance },
        };
        var set = cover;
        set.sprites = try arena.dupe(srapiext.Sprite, &.{sprite});
        set.position = camera.ahead(distance);
        try xtrabits.sceneAddCopy(gpa, arena, scene, .{ .sprites = set }, .overlay);
    }
};

/// The set with the sprite that covers the view (`0x00587CCC`), as the mission's start makes it
/// (`0x00493CA8`): untextured, coloured by its sprite's colour, and added to what is drawn.
const cover: srapiext.SpriteSet = .{
    .surface = .{ .material = .onePass(.{ .coordinates = .none, .lit = true, .blend = .add }) },
    .sprites = &.{},
};

test Flash {
    const gpa = std.testing.allocator;
    var flash: Flash = .{};
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const projection: srapi.Projection = .init(640, 480, .{ 0, 0, 1, 1 }, .{ 1, 1 });
    const drawn = scene.layers.getPtr(.overlay);

    // Nothing shows until it is lit.
    try flash.draw(gpa, arena, &scene, .{}, projection, 0);
    try std.testing.expectEqual(0, drawn.items.len);

    // A ship coming apart within five of its radii of the camera lights it; further off, not.
    var object = std.mem.zeroes(gameobj.GameObject);
    object.radius = 100;
    object.root.position = .{ .x = 0, .y = 0, .z = 600 };
    flash.near(&object, @splat(0));
    try std.testing.expectEqual(0, flash.left);
    object.root.position.z = 400;
    flash.near(&object, @splat(0));
    try std.testing.expectEqual(flash_ticks, flash.left);

    // White at first, in front of the camera over the whole view.
    try flash.draw(gpa, arena, &scene, .{}, projection, 0);
    try std.testing.expectEqual(1, drawn.items.len);
    const white = drawn.items[0].sprites;
    try std.testing.expectEqual([3]f32{ 1, 1, 1 }, white.sprites[0].colour);
    try std.testing.expect(white.position[2] > projection.near);
    // Then it fades as the game counts down the frames' ticks.
    flash.countDown(50);
    try std.testing.expectEqual(50, flash.left);
    scene.clear();
    try flash.draw(gpa, arena, &scene, .{}, projection, 0);
    try std.testing.expectApproxEqAbs(0.6, drawn.items[0].sprites.sprites[0].colour[0], 1e-5);
    // Once its ticks are gone, it counts down no further and shows no more.
    flash.countDown(50);
    flash.countDown(50);
    try std.testing.expectEqual(0, flash.left);
    scene.clear();
    try flash.draw(gpa, arena, &scene, .{}, projection, 0);
    try std.testing.expectEqual(0, drawn.items.len);

    // A hit's interference shows it red at its level, over the white. Drawing leaves the ticks
    // left as they are.
    flash.start();
    try flash.draw(gpa, arena, &scene, .{}, projection, 0.3);
    try std.testing.expectEqual(1, drawn.items.len);
    try std.testing.expectEqual([3]f32{ 0.3, 0, 0 }, drawn.items[0].sprites.sprites[0].colour);
    try std.testing.expectEqual(flash_ticks, flash.left);
}
