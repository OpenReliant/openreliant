//! Planet Bombard: ten flashes that burst over Titan's surface while environment effect 2 is on,
//! as mission 25 turns it on before its last jump.
//!
//! The game builds the flashes as its renderer starts (`bombard_flashes_create`, `0x0046A500`),
//! each a square over `pbang`. `create_object` gives the last part of each Titan it makes a routine
//! that the part runs as it is drawn (`bombard_hook`, `0x0046A300`), and keeps that Titan's slot
//! (`bombard_planet`, `0x005531A8`). While effect 2 is on, the routine moves the flashes on
//! (`Bombard.frame`): each one waits, bursts at a random spot of one of three regions of Titan, grows
//! and fades over 35 ticks, then waits again. Nothing adds the flashes to the scene, so the game
//! never shows them.
//!
//! **Unverified:** the routines lie between `environfx.cpp`'s known code and `erayfx.cpp`'s, and are
//! kept with the environment's effects, which the routine reads.
//!
//! **Improvement:** OpenReliant draws the flashes as they burst (`Bombard.draw`). `--original`
//! leaves them unseen, as the game does.

const std = @import("std");
const Allocator = std.mem.Allocator;

const loadout = @import("../../interface/loadout/loadout.zig");
const Random = @import("../../random.zig").Random;
const math = @import("../../surrender/math.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const matmanager = @import("../matmanager.zig");
const xtrabits = @import("../xtrabits.zig");

/// The texture the flashes are drawn over (`0x004FFAC8`): one round flash, 32 texels across.
pub const texture_name = "pbang";

/// How many flashes there are (`bombard_flashes`, `0x005524A8`, 0xC bytes each).
pub const flash_count = 10;

/// How large a flash is across as it is built: one in `large_odds` is `large_size`, and the rest
/// from `least_size` to `least_size + size_spread` (`0x0046A5B1`, `0x004DC564`, `0x004DC508`).
const large_odds = 10;
const large_size: f32 = 25000;
const least_size: f32 = 3000;
const size_spread: f32 = 15000;

/// How many ticks a flash shows for (`0x0046A338`), and the most ticks it then waits at random
/// before it bursts again (`0x004DC44C`).
pub const show_ticks = 35;
const most_wait: f32 = 1000;

/// The cells of the picture sheet the flashes were drawn for, each its left, top, right and bottom
/// in pixels on a sheet of 256 by 256 (`bombard_cells`, `0x004FF74C`). They grow from the first to
/// the last. The sheet doesn't ship: `pbang` is one flash, and only the cells' sizes are used.
const cells = [8][4]f32{
    .{ 214, 36, 236, 60 },
    .{ 214, 0, 248, 34 },
    .{ 92, 196, 138, 242 },
    .{ 170, 112, 234, 178 },
    .{ 92, 116, 168, 194 },
    .{ 0, 116, 90, 212 },
    .{ 112, 0, 212, 110 },
    .{ 0, 0, 110, 114 },
};

/// How large a flash is at each cell: the cell's width over the first cell's.
const cell_scales = scales: {
    var all: [cells.len]f32 = undefined;
    for (&all, cells) |*scale, cell| scale.* = (cell[2] - cell[0]) / (cells[0][2] - cells[0][0]);
    break :scales all;
};

/// How many cells a showing flash steps through each tick: 16 over its 35 ticks (`0x004DC814`).
/// Its step picks its cell from `cell_steps`, the cells in turn and then the last
/// (`bombard_cell_steps`, `0x004FF7CC`).
const steps_per_tick: f32 = 16.0 / @as(f32, show_ticks);
const cell_steps = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7 };

/// A showing flash's grey: `early_grey` for the first half of its time, then from `late_grey` down
/// to nothing (`0x0046A433`, `0x004DC4C0`).
const early_grey: f32 = 0.1;
const late_grey: f32 = 0.3;

/// The three regions of Titan a flash bursts in, each the pitch and the yaw a flash is turned by
/// before it strays (`0x0046A71F`), and how far it strays from there about each axis, at random:
/// 0.3 of a half turn (`0x004DC81C`).
const regions = [3][2]f32{ .{ -0.5, 1 }, .{ 0.2, 4 }, .{ 0.4, 7 } };
const stray: f32 = 0.3 * std.math.pi;

/// Whether OpenReliant draws the flashes.
pub const Shown = enum {
    /// **Improvement:** as they burst, over Titan.
    drawn,
    /// Never, as the game builds them and never adds them to the scene.
    original,
};

/// What a flash bursts on: Titan's root as it is drawn, and the radius of its first part, at which
/// the flashes stand.
pub const Planet = struct {
    root: math.Place,
    radius: f32,
};

/// A flash: its square, `Boom_Mesh`, coloured by a grey of its own and added; whether it shows;
/// and the tick it started showing at, or the tick it bursts again after while it waits.
pub const Flash = struct {
    mesh: srapiext.Mesh,
    level: [1]srapiext.Level,
    object: srapiext.MeshObject,
    /// Its grey for each corner (`bombard_flash_shade`, `0x0046A4B0`).
    colours: [4][4]f32,
    showing: bool = false,
    time: i32,
    /// Where it stands in Titan's root frame as it bursts: turned out to Titan's surface.
    local: math.Place = .{},

    /// `bombard_flash_shade` (`0x0046A4B0`): every corner `grey`, solid.
    fn shade(flash: *Flash, grey: f32) void {
        flash.colours = @splat(.{ grey, grey, grey, 1 });
    }

    /// `bombard_flash_start` (`0x0046A700`): bursts on `planet` at frame `now`. It picks one of the
    /// three regions, turns by the region's pitch and yaw, strays from there by a random share of
    /// `stray` about each axis in turn (`math.fromAngles`), and stands at `planet`'s radius along its
    /// own forward axis, facing out.
    ///
    /// **Fix:** the game keeps the tick the flash was due at, so one due long before, as every
    /// flash is when a mission turns the effect on, shows for a single frame at its largest with a
    /// grey below nothing. OpenReliant starts such a flash at `now`.
    fn start(flash: *Flash, planet: Planet, random: *Random, now: i32) void {
        flash.showing = true;
        if (now - flash.time >= show_ticks) flash.time = now;
        const region = regions[random.below(regions.len)];
        const pitch = random.fraction() * stray + region[0];
        const yaw = random.fraction() * stray + region[1];
        const roll = random.fraction() * stray;
        const turn = math.fromAngles(pitch, yaw, roll);
        flash.local = .{ .orientation = turn, .position = math.transform(turn, .{ 0, 0, planet.radius }) };
    }
};

/// The size a flash showing for `ticks` is drawn at, as a share of its size as built: each cell's
/// in turn, then the last's.
///
/// **Fix:** the game keeps each cell's width and height over the first cell's in pairs
/// (`0x0054F0C8`), but reads them one float at a time by cell, so that a flash takes the widths and
/// the heights of the first four cells in turn: 1, 1, 1.55, 1.42, 2.09, 1.92, 2.91, and then 2.75.
/// OpenReliant takes each cell's width, so that the flash grows through all eight, from 1 to 5.
pub fn scaleAt(ticks: i32) f32 {
    const step = math.round(@as(f32, @floatFromInt(ticks)) * steps_per_tick);
    return cell_scales[cell_steps[@intCast(std.math.clamp(step, 0, cell_steps.len - 1))]];
}

/// The grey of a flash showing for `ticks`.
pub fn greyAt(ticks: i32) f32 {
    const share = @as(f32, @floatFromInt(ticks)) / show_ticks;
    if (share < 0.5) return early_grey;
    return (1 - (share - 0.5) * 2) * late_grey;
}

pub const Bombard = struct {
    flashes: [flash_count]Flash,
    /// The frame the flashes last moved on at (`bombard_flashes_framed_at`, `0x00552520`), which
    /// nothing reads.
    framed_at: i32 = 0,
    shown: Shown,

    /// `bombard_flashes_create` (`0x0046A500`), at frame `now`: the ten flashes, each one sized as
    /// `random` draws it, a square that faces along Z over `pbang` (`loadout.addedSquare`), lit and
    /// added, and an object coloured by its own corners, never culled and always drawn. Each waits
    /// from `now`.
    ///
    /// The game first gives each square the texture coordinates of the sheet's first cell, but
    /// every frame a flash shows sets them to the whole of `pbang` again (`0x0046A3B7`), as
    /// OpenReliant's have them from the start.
    pub fn create(gpa: Allocator, textures: *srtexture.Table, shown: Shown, random: *Random, now: i32) (Allocator.Error || matmanager.Error)!*Bombard {
        const image = try matmanager.textureRequire(textures, texture_name);
        const bombard = try gpa.create(Bombard);
        errdefer gpa.destroy(bombard);
        bombard.* = .{ .flashes = undefined, .shown = shown };
        var made: usize = 0;
        errdefer for (bombard.flashes[0..made]) |*flash| flash.mesh.deinit(gpa);
        for (&bombard.flashes) |*flash| {
            const size = if (random.oneIn(large_odds)) large_size else random.fraction() * size_spread + least_size;
            flash.* = .{ .mesh = try loadout.addedSquare(gpa, size, size, true, image), .level = undefined, .object = undefined, .colours = undefined, .time = now };
            made += 1;
            flash.level = .{.{ .mesh = &flash.mesh, .until = std.math.inf(f32) }};
            flash.shade(0);
            flash.object = .{
                .flags = .{ .not_culled = true, .always_drawn = true, .unbounded = true, .owns_mesh = true, .baked_object = true },
                .position = @splat(0),
                .radius = flash.mesh.radius,
                .levels = &flash.level,
                .baked = &flash.colours,
            };
        }
        return bombard;
    }

    /// Sets every flash waiting from tick 0 again, black, as each mission starts.
    ///
    /// **Fix:** the game sets the flashes waiting only as its renderer starts, though each mission
    /// counts its ticks from 0 again, so that after a mission with the effect on, a flash can wait
    /// for the tick it was due at there, minutes into the next mission. OpenReliant sets them
    /// waiting again as each mission starts (`environfx.Environment.resetEffects`).
    pub fn reset(bombard: *Bombard) void {
        for (&bombard.flashes) |*flash| {
            flash.showing = false;
            flash.time = 0;
            flash.shade(0);
        }
    }

    /// `bombard_flashes_free` (`0x0046A6D0`): lets the flashes go.
    pub fn destroy(bombard: *Bombard, gpa: Allocator) void {
        for (&bombard.flashes) |*flash| flash.mesh.deinit(gpa);
        gpa.destroy(bombard);
    }

    /// `bombard_flashes_frame` (`0x0046A312`), at frame `now`, the flashes standing on `planet`.
    /// Each flash that has shown for `show_ticks` waits again, until a random tick up to `most_wait`
    /// on, and keeps its grey this frame. Otherwise one that waits past its tick bursts
    /// (`Flash.start`). One that shows takes the size and the grey of the ticks it has shown for
    /// (`scaleAt`, `greyAt`), and one that waits is black.
    pub fn frame(bombard: *Bombard, planet: Planet, random: *Random, now: i32) void {
        for (&bombard.flashes) |*flash| {
            if (flash.showing and now - flash.time >= show_ticks) {
                flash.showing = false;
                flash.time = math.round(random.fraction() * most_wait + @as(f32, @floatFromInt(now)));
                continue;
            }
            if (!flash.showing and now > flash.time) flash.start(planet, random, now);
            if (!flash.showing) {
                flash.shade(0);
                continue;
            }
            const ticks = now - flash.time;
            flash.object.scale = scaleAt(ticks);
            flash.shade(greyAt(ticks));
        }
        bombard.framed_at = now;
    }

    /// Adds each flash that shows, standing where it burst on `planet`, to the world's layer, unless
    /// they aren't shown.
    pub fn draw(bombard: *Bombard, gpa: Allocator, scene: *srcore.Scene, planet: Planet) Allocator.Error!void {
        if (bombard.shown == .original) return;
        for (&bombard.flashes) |*flash| {
            if (!flash.showing) continue;
            const place = flash.local.within(planet.root);
            flash.object.position = place.position;
            flash.object.orientation = place.orientation;
            try xtrabits.sceneAdd(gpa, scene, .{ .mesh = &flash.object }, .world);
        }
    }
};

test scaleAt {
    // From the first cell's size, through each cell's in turn, every two ticks or so, to the last
    // cell's, five times the first's, which it keeps.
    try std.testing.expectEqual(1, scaleAt(0));
    try std.testing.expectApproxEqAbs(34.0 / 22.0, scaleAt(2), 1e-6);
    try std.testing.expectApproxEqAbs(46.0 / 22.0, scaleAt(4), 1e-6);
    try std.testing.expectApproxEqAbs(100.0 / 22.0, scaleAt(13), 1e-6);
    try std.testing.expectEqual(5, scaleAt(15));
    try std.testing.expectEqual(5, scaleAt(show_ticks - 1));
    for (1..show_ticks) |ticks| try std.testing.expect(scaleAt(@intCast(ticks)) >= scaleAt(@intCast(ticks - 1)));
}

test greyAt {
    // A tenth for the first half of its time, then from 0.3 down to nothing.
    try std.testing.expectEqual(early_grey, greyAt(0));
    try std.testing.expectEqual(early_grey, greyAt(17));
    try std.testing.expectApproxEqAbs(late_grey * (1 - 1.0 / 35.0), greyAt(18), 1e-6);
    try std.testing.expectApproxEqAbs(late_grey / 35.0 * 2, greyAt(34), 1e-6);
}

test Bombard {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, &.{texture_name});
    defer textures.deinit(gpa);
    var random: Random = .{};
    const bombard = try Bombard.create(gpa, &textures.table, .drawn, &random, 100);
    defer bombard.destroy(gpa);
    // Ten squares, one in ten 25000 across, the rest 3000 to 18000, black and waiting from tick 100.
    for (bombard.flashes) |flash| {
        const across = flash.mesh.bounds[1][0] - flash.mesh.bounds[0][0];
        try std.testing.expect(across == large_size or (across >= least_size and across <= least_size + size_spread));
        try std.testing.expect(!flash.showing and flash.time == 100);
        try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, flash.colours[0]);
    }

    // On a Titan of radius 1000 standing at (5000, 0, 0), every flash bursts at the next frame,
    // standing on its surface, facing out.
    const planet: Planet = .{ .root = .{ .position = .{ 5000, 0, 0 } }, .radius = 1000 };
    bombard.frame(planet, &random, 101);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try bombard.draw(gpa, &scene, planet);
    try std.testing.expectEqual(flash_count, scene.layers.get(.world).items.len);
    for (bombard.flashes) |flash| {
        try std.testing.expect(flash.showing);
        try std.testing.expectApproxEqAbs(1000, math.length(flash.object.position - planet.root.position), 1e-2);
        const out = math.normalize(flash.object.position - planet.root.position);
        try std.testing.expectApproxEqAbs(1, math.dot(math.forward(flash.object.orientation), out), 1e-5);
        try std.testing.expectEqual(1, flash.object.scale);
        try std.testing.expectEqual(early_grey, flash.colours[3][0]);
    }

    // Its ticks count from the tick it was due at. Twenty in, it is larger and brighter; at its
    // 35th it waits again, up to 1000 ticks, keeping its grey for the frame; then it is black, and
    // not drawn.
    bombard.frame(planet, &random, 100 + 20);
    try std.testing.expectEqual(scaleAt(20), bombard.flashes[0].object.scale);
    try std.testing.expectEqual(greyAt(20), bombard.flashes[0].colours[0][1]);
    bombard.frame(planet, &random, 100 + show_ticks);
    const waiting = bombard.flashes[0];
    try std.testing.expect(!waiting.showing and waiting.time >= 100 + show_ticks and waiting.time <= 100 + show_ticks + most_wait);
    try std.testing.expectEqual(greyAt(20), waiting.colours[0][0]);
    bombard.frame(planet, &random, 100 + show_ticks);
    try std.testing.expectEqual(0, bombard.flashes[0].colours[0][0]);
    scene.clear();
    try bombard.draw(gpa, &scene, planet);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    try std.testing.expectEqual(100 + show_ticks, bombard.framed_at);
}

test "a flash long overdue shows its whole time" {
    const gpa = std.testing.allocator;
    const textures = try srtexture.testing.Textures.init(gpa, &.{texture_name});
    defer textures.deinit(gpa);
    var random: Random = .{};
    const bombard = try Bombard.create(gpa, &textures.table, .original, &random, 0);
    defer bombard.destroy(gpa);
    // Due at tick 0 and first moved on at tick 5000, as when a mission turns the effect on: it
    // starts at 5000, at its first size and grey.
    const planet: Planet = .{ .root = .{}, .radius = 1000 };
    bombard.frame(planet, &random, 5000);
    try std.testing.expectEqual(5000, bombard.flashes[0].time);
    try std.testing.expectEqual(1, bombard.flashes[0].object.scale);
    try std.testing.expectEqual(early_grey, bombard.flashes[0].colours[0][0]);
    // As the game draws them, never.
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    try bombard.draw(gpa, &scene, planet);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
    // A mission's start sets them waiting from tick 0 again.
    bombard.reset();
    for (bombard.flashes) |flash| try std.testing.expect(!flash.showing and flash.time == 0 and flash.colours[0][0] == 0);
}
