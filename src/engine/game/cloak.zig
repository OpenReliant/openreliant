//! `C:\lancer\game\cloak.cpp`: the cloak, which hides a ship behind a shimmer as it fades its
//! hull; and the countermeasures, the decoys a ship drops to draw away the missiles homing on it.
//! **Unverified:** that the countermeasures are this file's. Their code lies after `cbox.cpp`'s and
//! before `cloak.cpp`'s asserting code, and their model's name, `ships\decoy.shp`, lies just
//! before `cloak.cpp`'s path among the strings. **Unverified:** likewise that `object_uncloak`
//! (`0x00463780`) to `cloak_node_cloaks` (`0x00463C30`), after the asserting code, and
//! `cloak_node_reveal` (`0x004629D0`), before it, are this file's.
//! [`missiles.md`](../../../docs/engine/missiles.md#countermeasures) describes them, and
//! [`cloak.md`](../../../docs/engine/cloak.md) the cloak.
//!
//! Not ported: in a network game, the host's choice of the missile a countermeasure draws away
//! ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../surrender/math.zig");
const Vector = math.Vector;
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const events = @import("mission/events.zig");
const explode = @import("explode.zig");
const gameobj = @import("gameobj.zig");
const hud = @import("hud.zig");
const missiles = @import("missiles.zig");
const objects = @import("objects.zig");
const particles = @import("particles.zig");
const table = @import("table.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const aigeneric = @import("aigeneric.zig");
const create = @import("create.zig");
const ease = @import("../genilib/interf/ease.zig");
const Random = @import("../random.zig").Random;
const sound3d = @import("sound3d.zig");
const srofiles = @import("srofiles.zig");

// --- The cloak --------------------------------------------------------------------------------

/// How long a cloak takes to come on, or to go, in ticks (`0xFA` in `cloak_frame` and
/// `cloak_wobble`).
pub const change_ticks = 250;

/// An object's cloak (`GameObject.cloak`, the 0x2C bytes `object_cloak` allocates), from the
/// moment it starts to come on until it has gone.
pub const Cloak = struct {
    /// Whether it is going (`+0x00`), and whether it is still coming on or going, which holds off
    /// a change of mind (`+0x01`).
    going: bool = false,
    changing: bool = true,
    /// How strong its shimmer is (`+0x04`), and how solid its hull (`+0x08`).
    shimmer: f32 = 0,
    hull: f32 = 1,
    /// When it began to come on (`+0x0C`), when it began to go (`+0x10`), and when a hit last
    /// showed the hull through it (`+0x14`).
    came_at: i32,
    going_at: i32 = 0,
    struck_at: i32 = 0,
    /// The tick of its last frame (`frame`). Each frame, the shimmer turns and what hits showed
    /// fades by the ticks since. The game keeps the ticks its shimmer and its hull were drawn at
    /// instead, in the frame before and in this one (`+0x1C` to `+0x28`).
    stepped_at: i32 = 0,

    /// When it started its change, coming on or going.
    fn changedAt(cloak: Cloak) i32 {
        return if (cloak.going) cloak.going_at else cloak.came_at;
    }

    /// The ticks since it started its change, at tick `now`, counted as the game counts them, so
    /// that a change from the future reads as long done.
    fn since(cloak: Cloak, now: i32) u32 {
        return @bitCast(now -% cloak.changedAt());
    }
};

/// Whether the object in `slot` can cloak: its model's header says so (`shp.Header.Flags.cloak`).
pub fn canCloak(slot: *const create.Slot) bool {
    return if (slot.model) |*model| model.source.header.flags.cloak else false;
}

/// `object_set_cloak` (`0x00463560`): the object in slot `index`, where it can cloak, cloaked or
/// not as `on` says, where it isn't already (`toggle`); for the player's ship the display's cloak
/// with it. The ships launching from it follow it.
pub fn set(world: gameobj.World, index: u16, on: bool) void {
    const all = world.objects;
    const slot = &all.slots[index];
    if (!canCloak(slot)) return;
    if (slot.object.flags.cloaked == on) return;
    toggle(world, index);
    if (index == all.player) if (world.display) |display| {
        display.devices.getPtr(.cloak).setting = if (on) .on else .off;
    };
    for (0..all.count) |at| {
        const other: u16 = @intCast(at);
        const entry = all.slots[other].current() orelse continue;
        if (entry.order == .launch and entry.target.slot() == index) set(world, other, on);
    }
}

/// `object_toggle_cloak` (`0x00463600`): the object in slot `index`, where it can cloak and its
/// cloak isn't still changing, uncloaks where it is cloaked, and cloaks where it isn't.
pub fn toggle(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    if (!canCloak(slot)) return;
    if (slot.cloak) |cloak| if (cloak.changing) return;
    if (slot.object.flags.cloaked) uncloak(world, index) else cloakOn(world, index);
}

/// `object_cloak` (`0x00463640`): the object in slot `index` cloaks, its Cloaked event posted
/// first (`events.cloaked`). Its cloak starts to come on: each part that cloaks is drawn
/// see-through (`seeThrough`) and shimmers (`shimmerOn`); and it sounds `CLOAK01`, on the player's
/// voices for the player's ship.
fn cloakOn(world: gameobj.World, index: u16) void {
    events.cloaked(world, index, true);
    const all = world.objects;
    const slot = &all.slots[index];
    slot.object.flags.cloaked = true;
    slot.cloak = .{ .came_at = world.clock.frame_start };
    const model = if (slot.model) |*live| live else return;
    seeThrough(model, slot.object.type.base() == .kafelnikof);
    shimmerOn(model, world.random);
    sound3d.playIn(world, null, null, index, .cloak01, 1, sound3d.fxClass(all, index));
}

/// `object_uncloak` (`0x00463780`): the cloak of the object in slot `index`, where it has one,
/// starts to go, its Decloaked event posted first (`events.cloaked`), and it sounds `CLOAK01` as it
/// does coming on.
pub fn uncloak(world: gameobj.World, index: u16) void {
    const slot = &world.objects.slots[index];
    const cloak = if (slot.cloak) |*kept| kept else return;
    events.cloaked(world, index, false);
    cloak.going = true;
    cloak.changing = true;
    cloak.going_at = world.clock.frame_start;
    sound3d.playIn(world, null, null, index, .cloak01, 1, sound3d.fxClass(world.objects, index));
}

/// `cloak_drop` (`0x00463420`): the object in `slot` has no cloak from now on, if it had one,
/// whatever its parts were showing, their callbacks let go (`cloak_node_free`, `0x00463470`),
/// which OpenReliant's parts have none of. An explosion's blast drops it so.
pub fn drop(slot: *create.Slot) void {
    slot.object.flags.cloaked = false;
    slot.cloak = null;
}

/// `cloak_frame` (`0x00463810`), for an object with a cloak, at tick `now`. Coming on, over
/// `change_ticks`, its shimmer strengthens and its hull fades. Once it has come on, each part's
/// hull is clear and its shimmer full, and what hits showed fades and the shimmer turns by
/// `change_ticks` once. Going, the other way; once it has gone, each part's hull is its own again
/// (`restore`) and the cloak is dropped. Then the shimmers turn and what hits showed of a clear
/// hull fades, by the ticks since its last frame (`step`).
///
/// The game runs it in `mission_frame`'s pass that draws the objects, and turns the shimmers and
/// fades the hulls as it draws each part (`Drawing`), for the ticks since that object was last
/// drawn. OpenReliant runs all of it once a game tick, in the objects' pass (`main.objectsPass`),
/// so that the cloak plays the same however often the screen is drawn, and the game doesn't
/// depend on what is drawn.
pub fn frame(slot: *create.Slot, now: i32) void {
    const cloak = if (slot.cloak) |*kept| kept else return;
    const ticks = now - cloak.stepped_at;
    cloak.stepped_at = now;
    const since = cloak.since(now);
    if (since < change_ticks) {
        const done = @as(f32, @floatFromInt(since)) / change_ticks;
        cloak.shimmer = if (cloak.going) 1 - done else done;
        cloak.hull = 1 - cloak.shimmer;
        cloak.changing = true;
    } else if (cloak.going) {
        if (slot.model) |*model| restore(model);
        return drop(slot);
    } else {
        if (cloak.changing) if (slot.model) |*model| eachCloaking(model, {}, struct {
            fn visit(_: void, part: *objects.Model.Part, effect: *PartCloak) void {
                effect.fade(change_ticks);
                part.object.colour[3] = 0;
                if (effect.shimmer_made) effect.swirl(change_ticks, 1);
            }
        }.visit);
        cloak.changing = false;
        cloak.shimmer = 1;
        cloak.hull = 0;
    }
    if (slot.model) |*model| step(model, cloak.*, ticks, slot.object.type.base() == .kafelnikof);
}

/// The work the game does as it draws each part of `model` that has a shimmer
/// (`cloak_shimmer_callback`, `cloak_hull_callback`), for `ticks`: the shimmer turns, unless the
/// cloak's shimmer is nothing or the object is the Kafelnikof (`PartCloak.swirl`), and while the
/// hull is clear, what hits showed of a part that cloaks fades (`PartCloak.fade`).
fn step(model: *objects.Model, cloak: Cloak, ticks: i32, kafelnikof: bool) void {
    const Step = struct { cloak: Cloak, ticks: i32, kafelnikof: bool };
    eachCloaking(model, Step{ .cloak = cloak, .ticks = ticks, .kafelnikof = kafelnikof }, struct {
        fn visit(stepping: Step, _: *objects.Model.Part, effect: *PartCloak) void {
            if (!effect.shimmer_made) return;
            if (stepping.cloak.shimmer != 0 and !stepping.kafelnikof) effect.swirl(stepping.ticks, stepping.cloak.shimmer);
            if (effect.cloaks and stepping.cloak.hull == 0) effect.fade(stepping.ticks);
        }
    }.visit);
}

/// How far a cloaked ship's frame shears as its cloak changes, at most, about each pair of its
/// axes (`0x004DC450`), and how fast each shear swings, with its start, as shares of a half turn
/// over the change (`0x004DC72C`; `0x004DC7BC`, `0x004DC7B8`; `0x004DC7B4`, `0x004DC470`).
const shear_most: f32 = 0.15;
const shear_rates = [3]f32{ 20, 26, 14 };
const shear_starts = [3]f32{ 0, 2.8, 0.9 };

/// `cloak_wobble` (`0x004639B0`), in `mission_frame`'s pass before the camera's frame, for the
/// object in `slot`, where it is cloaked and not the Kafelnikof, at tick `now`: while its cloak
/// changes, its frame, as drawn, shears a little and back, three ways at their own rates, swelling
/// and dying away over the change.
pub fn wobble(slot: *create.Slot, now: i32) void {
    if (slot.object.type.base() == .kafelnikof) return;
    const cloak = slot.cloak orelse return;
    const since = cloak.since(now);
    if (since > change_ticks) return;
    const done = @as(f32, @floatFromInt(since)) / change_ticks;
    const swell = @sin(done * std.math.pi);
    var shears: [3]f32 = undefined;
    for (&shears, shear_rates, shear_starts) |*shear, rate, start| shear.* = @sin(done * rate + start) * swell * shear_most;
    // Of Y by X, of X by Y and of X by Z, in turn (`mat3_shear_x`, `0x004C24F0`; `mat3_shear_y`,
    // `0x004C2550`; `mat3_shear_z`, `0x004C25B0`).
    var turn = slot.drawn.orientation;
    turn = math.product(turn, .{ 1, 0, 0, shears[0], 1, 0, 0, 0, 1 });
    turn = math.product(turn, .{ 1, shears[1], 0, 0, 1, 0, 0, 0, 1 });
    turn = math.product(turn, .{ 1, 0, shears[2], 0, 1, 0, 0, 0, 1 });
    slot.drawn.orientation = turn;
    if (slot.model) |*model| model.place(slot.drawn.position, slot.drawn.orientation);
}

/// How far round the point struck a hit shows a cloaked hull, and how sharply its showing falls
/// off with distance, by the object's radius (`0x004DC79C`, `0x004DC770`).
const struck_reach: f32 = 1.123;
const struck_falloff: f32 = 0.45;

/// `cloak_reveal` (`0x00463AF0`): a hit at `at` on the object in slot `index`, where it is
/// cloaked, shows its hull round the point (`cloak_node_reveal`, `0x004629D0`): each vertex of a
/// part that cloaks within `struck_reach` of the object's radius is the more solid the nearer it
/// stands, up to whole. The Kafelnikof's parts go by their own smallest extent, not the radius. A
/// shot spent on the shields shows it, and one on a component, the Nova Cannon's beam, and a
/// shield's flare.
///
/// **Fix:** the game shows the hit on the vertices of the level each part was drawn at last, in
/// one set of colours that all its levels share, so what a hit showed moves to other vertices
/// when the level changes. OpenReliant keeps a set for each level and shows the hit on every level
/// (`PartCloak.show`), so it stays where it struck whichever level is drawn, and the game doesn't
/// depend on which level was drawn.
pub fn reveal(world: gameobj.World, index: u16, at: Vector) void {
    const slot = &world.objects.slots[index];
    const cloak = if (slot.cloak) |*kept| kept else return;
    cloak.struck_at = world.clock.frame_start;
    const model = if (slot.model) |*live| live else return;
    const struck: Struck = .{ .at = at, .radius = slot.object.radius, .kafelnikof = slot.object.type.base() == .kafelnikof };
    eachCloaking(model, struck, struct {
        fn visit(hit: Struck, part: *objects.Model.Part, effect: *PartCloak) void {
            if (effect.cloaks) effect.show(hit, part.object.levels, part.object.place());
        }
    }.visit);
}

/// A hit that shows a cloaked hull (`reveal`): where it struck, the object's radius, and whether
/// the object is the Kafelnikof.
const Struck = struct {
    at: Vector,
    radius: f32,
    kafelnikof: bool,

    /// The size a level showing `mesh` goes by: the object's radius, or on the Kafelnikof the
    /// mesh's smallest extent.
    fn size(struck: Struck, mesh: *const srapiext.Mesh) f32 {
        if (!struck.kafelnikof) return struck.radius;
        const extent = mesh.bounds[1] - mesh.bounds[0];
        return @min(@min(extent[0], extent[1]), extent[2]);
    }
};

/// The Kafelnikof's parts that cloak, where every other object cloaks whole
/// (`kafelnikof_cloaking_parts`, `0x004E1998`).
const kafelnikof_cloaks = [_][]const u8{ "Kaf bot vent", "Kaf comms twr", "Kaf ext vent", "Kaf frnt vent", "Kaf land plat", "Kaf shield gen", "Kaf top vent" };

/// Whether the part named `name` cloaks, on the Kafelnikof or another (`cloak_node_cloaks`,
/// `0x00463C30`).
fn cloaks(kafelnikof: bool, name: []const u8) bool {
    if (!kafelnikof) return true;
    for (kafelnikof_cloaks) |listed| if (std.mem.eql(u8, name, listed)) return true;
    return false;
}

/// `cloak_node_see_through` (`0x00462B80`): each part of `model`, and of the models it carries,
/// that cloaks is drawn see-through, its own colours clear.
fn seeThrough(model: *objects.Model, kafelnikof: bool) void {
    eachCloaking(model, kafelnikof, struct {
        fn visit(on_kafelnikof: bool, part: *objects.Model.Part, effect: *PartCloak) void {
            effect.cloaks = cloaks(on_kafelnikof, effect.name);
            if (!effect.cloaks) return;
            part.object.levels = effect.see_through;
            effect.clearHull();
        }
    }.visit);
}

/// `cloak_node_shimmer` (`0x00462EB0`): each part of `model`, and of the models it carries, that
/// cloaks has its shimmer, clear, its texture laid on anew at random.
fn shimmerOn(model: *objects.Model, random: *Random) void {
    eachCloaking(model, random, struct {
        fn visit(drawn_from: *Random, _: *objects.Model.Part, effect: *PartCloak) void {
            if (!effect.cloaks) return;
            effect.shimmer_made = true;
            effect.shimmer.colour[3] = 0;
            for (effect.shimmer_uv[0..effect.shimmer_levels[0].mesh.positions.len]) |*uv| {
                const u = drawn_from.fraction();
                uv.* = .{ u, drawn_from.fraction() };
            }
        }
    }.visit);
}

/// `cloak_node_restore` (`0x00462D30`): each part of `model`, and of the models it carries, that
/// cloaks has its own levels back, solid and its own colours clear.
fn restore(model: *objects.Model) void {
    eachCloaking(model, {}, struct {
        fn visit(_: void, part: *objects.Model.Part, effect: *PartCloak) void {
            if (!effect.cloaks) return;
            part.object.colour[3] = 1;
            part.object.levels = effect.own;
            effect.clearHull();
        }
    }.visit);
}

/// OpenReliant's: each part that cloaks of `model`, which is not drawn, as the ship the camera sits
/// in is not, as solid as its cloak's hull `hull`, which the part's shadow goes by (`srshadow`), as
/// a drawn one's does (`Drawing.hull`).
pub fn shadeUnseen(model: *objects.Model, hull: f32) void {
    eachCloaking(model, hull, struct {
        fn visit(solid: f32, part: *objects.Model.Part, effect: *PartCloak) void {
            if (effect.cloaks) part.object.colour[3] = solid;
        }
    }.visit);
}

/// Runs `visit` on each part of `model`, and of the models it carries however deep, that has the
/// cloak's meshes, with them.
fn eachCloaking(model: *objects.Model, context: anytype, comptime visit: fn (@TypeOf(context), *objects.Model.Part, *PartCloak) void) void {
    for (model.parts) |*part| {
        if (part.cloak) |*effect| visit(context, part, effect);
    }
    var each = model.carried();
    while (each.next()) |mount| eachCloaking(&mount.model, context, visit);
}

/// A part of a model that can cloak, as its cloak draws it (`srofiles.Cloaking`): its name, which
/// says whether it cloaks on the Kafelnikof; its own levels and those seen through; its hull's own
/// colours, which it is drawn see-through by; and its shimmer (`node + 0x0C`), with its own colours
/// and texture coordinates.
pub const PartCloak = struct {
    name: []const u8,
    own: []const srapiext.Level,
    see_through: []const srapiext.Level,
    /// The hull's own colours, a set for each of its levels with a colour a vertex
    /// (`srapiext.MeshObject.baked_levels`). The game keeps one set for all its levels (`reveal`).
    hull_colours: [][][4]f32,
    shimmer_levels: []const srapiext.Level,
    shimmer: srapiext.MeshObject,
    shimmer_colours: [][4]f32,
    shimmer_uv: [][2]f32,
    /// Whether it cloaks with its object, and whether it has had its shimmer made, which it keeps.
    cloaks: bool = false,
    shimmer_made: bool = false,

    /// The part's meshes for the cloak, `name` the part's, `own` its levels and `radius` its
    /// farthest reach.
    pub fn create(gpa: Allocator, cloaking: srofiles.Cloaking, name: []const u8, own: []const srapiext.Level, radius: f32) Allocator.Error!PartCloak {
        var vertices: usize = 0;
        for (own) |level| vertices = @max(vertices, level.mesh.positions.len);
        const hull_colours = try gpa.alloc([][4]f32, own.len);
        var made: usize = 0;
        errdefer {
            for (hull_colours[0..made]) |colours| gpa.free(colours);
            gpa.free(hull_colours);
        }
        for (hull_colours, own) |*colours, level| {
            colours.* = try gpa.alloc([4]f32, level.mesh.positions.len);
            @memset(colours.*, @splat(0));
            made += 1;
        }
        const shimmer_colours = try gpa.alloc([4]f32, vertices);
        errdefer gpa.free(shimmer_colours);
        @memset(shimmer_colours, @splat(0));
        const shimmer_uv = try gpa.alloc([2]f32, vertices);
        @memset(shimmer_uv, @splat(0));
        return .{
            .name = name,
            .own = own,
            .see_through = cloaking.see_through_levels,
            .hull_colours = hull_colours,
            .shimmer_levels = cloaking.shimmer_levels,
            .shimmer = .{
                .flags = .{ .baked_object = true, .own_first = true },
                .position = @splat(0),
                .radius = radius,
                .levels = cloaking.shimmer_levels,
                .baked = shimmer_colours,
                .own_uv = .{ shimmer_uv, null },
            },
            .shimmer_colours = shimmer_colours,
            .shimmer_uv = shimmer_uv,
        };
    }

    /// OpenReliant's: points the cloak of a part, copied with the part (`objects.Model.copy`), at
    /// copies of its colours and texture coordinates made in `arena`, and the part's `object` at
    /// the hull's.
    pub fn copyOwn(effect: *PartCloak, arena: Allocator, object: *srapiext.MeshObject) Allocator.Error!void {
        const hull = try arena.alloc([][4]f32, effect.hull_colours.len);
        for (hull, effect.hull_colours) |*colours, from| colours.* = try arena.dupe([4]f32, from);
        effect.hull_colours = hull;
        effect.shimmer_colours = try arena.dupe([4]f32, effect.shimmer_colours);
        effect.shimmer_uv = try arena.dupe([2]f32, effect.shimmer_uv);
        effect.shimmer.baked = effect.shimmer_colours;
        effect.shimmer.own_uv[0] = effect.shimmer_uv;
        object.baked_levels = effect.hull_colours;
    }

    pub fn deinit(effect: PartCloak, gpa: Allocator) void {
        for (effect.hull_colours) |colours| gpa.free(colours);
        gpa.free(effect.hull_colours);
        gpa.free(effect.shimmer_colours);
        gpa.free(effect.shimmer_uv);
    }

    /// The hull's own colours cleared, on every level.
    fn clearHull(effect: *PartCloak) void {
        for (effect.hull_colours) |colours| @memset(colours, @splat(0));
    }

    /// `cloak_hull_fade` (`0x004632F0`) for one part while its hull is clear, `ticks` since it was
    /// drawn: what hits have shown of it fades by `struck_fade` a tick. With the hull not clear the
    /// game sets its alpha instead, which `Drawing.hull` does. The game fades the vertices of the
    /// level drawn; OpenReliant fades every level's (`reveal`).
    fn fade(effect: *PartCloak, ticks: i32) void {
        const faded = @as(f32, @floatFromInt(ticks)) * struck_fade;
        for (effect.hull_colours) |colours| for (colours) |*colour| {
            if (!(colour[3] > 0)) continue;
            colour[3] = @max(colour[3] + faded, 0);
        };
    }

    /// `cloak_node_reveal` for one part that cloaks, drawn with `levels` and placed at `placed`: on
    /// each level, each vertex within `struck_reach` times the level's size (`Struck.size`) of the
    /// hit gets more solid the nearer it is, up to whole.
    fn show(effect: *PartCloak, struck: Struck, levels: []const srapiext.Level, placed: math.Place) void {
        for (levels, effect.hull_colours[0..@min(levels.len, effect.hull_colours.len)]) |level, colours| {
            const mesh = level.mesh;
            const size = struck.size(mesh);
            const reach = size * struck_reach;
            for (mesh.positions, colours[0..mesh.positions.len]) |position, *colour| {
                const distance = math.distance(struck.at, placed.point(position));
                if (distance > reach) continue;
                colour[3] = @min(colour[3] + @min((reach - distance) / (size * struck_falloff), 1), 1);
            }
        }
    }

    /// `cloak_shimmer_swirl` (`0x00463050`) for one part, `ticks` since its shimmer last turned, at
    /// `strength`: its texture coordinates turn about the texture's corner, the faster the nearer
    /// they lie, and it takes `shimmerColour`. The game turns those of the level drawn; OpenReliant
    /// turns all that `shimmerOn` laid on, the finest level's, since each turns on its own.
    fn swirl(effect: *PartCloak, ticks: i32, strength: f32) void {
        effect.shimmer.flags.lit = false;
        const turned = @as(f32, @floatFromInt(ticks)) * swirl_rate;
        const colour = shimmerColour(strength);
        const vertices = effect.shimmer_levels[0].mesh.positions.len;
        for (effect.shimmer_uv[0..vertices], effect.shimmer_colours[0..vertices]) |*uv, *shade| {
            const u, const v = uv.*;
            const angle = turned / (u * u + v * v);
            const s = @sin(angle);
            const c = @cos(angle);
            uv.* = .{ c * u - s * v, s * u + c * v };
            shade[0..3].* = colour;
        }
    }
};

/// How fast what a hit showed of a clear hull fades, a tick (`0x004DC7A8`), and how fast the
/// shimmer's texture coordinates turn, a tick, a unit from the texture's corner (`0x004DC7A0`).
const struck_fade: f32 = -0.01;
const swirl_rate: f32 = 0.008;

/// The shimmer's colours: black, to `shimmer_bright` as it strengthens to `shimmer_turn`, then to
/// `shimmer_full` (`cloak_colour_at`, `0x004631E0`), in 256ths.
const shimmer_bright = [3]f32{ 185.0 / 256.0, 203.0 / 256.0, 82.0 / 256.0 };
const shimmer_full = [3]f32{ 0, 0, 80.0 / 256.0 };
const shimmer_turn: f32 = 0.3;

/// The shimmer's colour at `strength`, easing in and out from each colour to the next
/// (`cloak_colour_at`, `0x004631E0`, by `ease.cosine`).
///
/// **Improvement:** the game reads it from a table of 1024 (`cloak_colour`, `0x004632B0`, from
/// `cloak_colours`, `0x0054142C`, which `cloak_init`, `0x00463500`, fills), a step at a time; the
/// port works it out.
pub fn shimmerColour(strength: f32) [3]f32 {
    var colour: [3]f32 = undefined;
    for (&colour, shimmer_bright, shimmer_full) |*channel, bright, full| {
        channel.* = if (strength < shimmer_turn)
            ease.cosine(0, bright, strength / shimmer_turn)
        else
            ease.cosine(bright, full, (strength - shimmer_turn) / (1 - shimmer_turn));
    }
    return colour;
}

/// What a cloaked object's part draws, as `node_draw` does with flag `0x80`: its shimmer, where it
/// has one, placed where the part stands (`cloak_shimmer_callback`, `0x00463B20`), unless the
/// cloak's shimmer is nothing or the object is the Kafelnikof; and its hull, see-through
/// (`cloak_hull_callback`, `0x00463B90`), which the original leaves out on its software renderer.
/// While the game is paused, both are drawn as they stand. The cloak's frame turns the shimmer and
/// fades the hull (`frame`).
pub const Drawing = struct {
    cloak: *const Cloak,
    kafelnikof: bool,

    /// The shimmer to add for `part`, drawn in `view`, or null.
    pub fn shimmer(drawing: Drawing, part: *objects.Model.Part, view: *const objects.View) ?*srapiext.MeshObject {
        const effect = if (part.cloak) |*kept| kept else return null;
        if (!effect.shimmer_made) return null;
        effect.shimmer.position = part.object.position;
        effect.shimmer.orientation = part.object.orientation;
        if (!view.paused and (drawing.cloak.shimmer == 0 or drawing.kafelnikof)) return null;
        return &effect.shimmer;
    }

    /// The hull of `part`, drawn in `view`: a part that cloaks is as solid as the cloak's hull while
    /// the hull isn't clear. A part with no shimmer is drawn as it would be uncloaked.
    pub fn hull(drawing: Drawing, part: *objects.Model.Part, view: *const objects.View) void {
        const effect = if (part.cloak) |*kept| kept else return;
        if (!effect.shimmer_made or !effect.cloaks or view.paused) return;
        if (drawing.cloak.hull != 0) part.object.colour[3] = drawing.cloak.hull;
    }
};

/// A mission holding one object, the player's ship, whose model of one part can cloak.
const TestStage = struct {
    mission: gameobj.testing.Mission,
    model: create.testing.Model,
    image: @import("../surrender/surrenderlib/srtexture.zig").Image,
    index: u16,

    pub fn init(stage: *TestStage, gpa: Allocator) !void {
        try stage.mission.init(gpa);
        errdefer stage.mission.deinit();
        try stage.model.init(gpa);
        errdefer stage.model.deinit(gpa);
        stage.image = .{ .levels = &.{} };
        try stage.model.withCloak(gpa, &stage.image);
        const mission = &stage.mission;
        stage.index = try mission.addWith(stage.model.types(), .of(.predator), @splat(0));
    }

    pub fn deinit(stage: *TestStage, gpa: Allocator) void {
        stage.mission.deinit();
        stage.model.deinit(gpa);
    }

    pub fn slot(stage: *TestStage) *create.Slot {
        return stage.mission.slot(stage.index);
    }

    pub fn part(stage: *TestStage) *objects.Model.Part {
        return &stage.slot().model.?.parts[0];
    }
};

test set {
    const gpa = std.testing.allocator;
    var stage: TestStage = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const slot = stage.slot();
    const part = stage.part();
    const effect = &part.cloak.?;
    const world = stage.mission.world();
    stage.mission.clock.frame_start = 100;

    // It cloaks from now: its part drawn see-through, and shimmering.
    set(world, stage.index, true);
    try std.testing.expect(slot.object.flags.cloaked);
    try std.testing.expectEqual(100, slot.cloak.?.came_at);
    try std.testing.expectEqual(effect.see_through.ptr, part.object.levels.ptr);
    try std.testing.expect(effect.cloaks and effect.shimmer_made);
    // A change of mind waits for the change to end.
    set(world, stage.index, false);
    try std.testing.expect(!slot.cloak.?.going);
    // Halfway, the shimmer is half as strong as it comes, and the hull half as solid.
    frame(slot, 100 + change_ticks / 2);
    try std.testing.expectApproxEqAbs(0.5, slot.cloak.?.shimmer, 1e-6);
    try std.testing.expectApproxEqAbs(0.5, slot.cloak.?.hull, 1e-6);
    try std.testing.expect(slot.cloak.?.changing);
    // Once it has come on, the hull is clear and the shimmer whole.
    frame(slot, 100 + change_ticks);
    try std.testing.expect(!slot.cloak.?.changing);
    try std.testing.expectEqual(1, slot.cloak.?.shimmer);
    try std.testing.expectEqual(0, part.object.colour[3]);

    // Uncloaking, it goes from now, the other way.
    stage.mission.clock.frame_start = 400;
    toggle(world, stage.index);
    try std.testing.expect(slot.cloak.?.going);
    frame(slot, 400 + change_ticks / 5);
    try std.testing.expectApproxEqAbs(0.8, slot.cloak.?.shimmer, 1e-6);
    // Once it has gone, the part has its own levels back, solid, and the object no cloak.
    frame(slot, 400 + change_ticks);
    try std.testing.expectEqual(null, slot.cloak);
    try std.testing.expect(!slot.object.flags.cloaked);
    try std.testing.expectEqual(effect.own.ptr, part.object.levels.ptr);
    try std.testing.expectEqual(1, part.object.colour[3]);

    // A model that can't cloak doesn't.
    stage.model.source.header.flags.cloak = false;
    set(world, stage.index, true);
    try std.testing.expect(!slot.object.flags.cloaked);
}

test wobble {
    const gpa = std.testing.allocator;
    var stage: TestStage = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const slot = stage.slot();
    set(stage.mission.world(), stage.index, true);

    // As the cloak changes, the frame shears, and the model is placed so.
    slot.drawn = .{ .position = @splat(0), .orientation = math.identity };
    wobble(slot, change_ticks / 3);
    try std.testing.expect(!std.meta.eql(math.identity, slot.drawn.orientation));
    try std.testing.expectEqual(slot.drawn.orientation, slot.model.?.orientation);
    // Neither as it starts, nor once it has come on.
    slot.drawn.orientation = math.identity;
    wobble(slot, 0);
    try std.testing.expectEqual(math.identity, slot.drawn.orientation);
    wobble(slot, change_ticks + 1);
    try std.testing.expectEqual(math.identity, slot.drawn.orientation);
    // The Kafelnikof never wobbles.
    slot.object.type = .of(.kafelnikof);
    wobble(slot, change_ticks / 3);
    try std.testing.expectEqual(math.identity, slot.drawn.orientation);
}

test reveal {
    const gpa = std.testing.allocator;
    var stage: TestStage = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const slot = stage.slot();
    const colours = stage.part().cloak.?.hull_colours[0];
    set(stage.mission.world(), stage.index, true);
    slot.object.radius = 100;

    // A hit on an edge shows the corner in reach, the more the nearer, and not those out of it.
    const world = stage.mission.world();
    stage.mission.clock.frame_start = 500;
    reveal(world, stage.index, .{ -100, -20, 0 });
    try std.testing.expectEqual(500, slot.cloak.?.struck_at);
    const near = (100 * struck_reach - 80) / (100 * struck_falloff);
    try std.testing.expectApproxEqAbs(near, colours[0][3], 1e-5);
    try std.testing.expectEqual(0, colours[3][3]);
    // Another on the corner shows it whole, and no more.
    reveal(world, stage.index, .{ -100, -100, 0 });
    try std.testing.expectEqual(1, colours[0][3]);
    try std.testing.expectEqual(0, colours[1][3]);
}

test "frame turns the shimmer and fades the hull for the ticks since the last" {
    const gpa = std.testing.allocator;
    var stage: TestStage = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const slot = stage.slot();
    const effect = &stage.part().cloak.?;
    stage.mission.clock.frame_start = 0;
    set(stage.mission.world(), stage.index, true);
    frame(slot, 0);
    // Come on, the shimmer at its full colour, unlit.
    frame(slot, change_ticks);
    try std.testing.expect(!effect.shimmer.flags.lit);
    try std.testing.expectApproxEqAbs(shimmer_full[2], effect.shimmer_colours[0][2], 1e-6);
    // The hull clear, what a hit showed fades a tick at a time since the last frame, and the
    // shimmer turns as far.
    effect.hull_colours[0][0][3] = 1;
    effect.shimmer_uv[0] = .{ 1, 0 };
    frame(slot, change_ticks + 50);
    try std.testing.expectApproxEqAbs(0.5, effect.hull_colours[0][0][3], 1e-6);
    try std.testing.expectApproxEqAbs(@cos(50 * swirl_rate), effect.shimmer_uv[0][0], 1e-6);
    // The Kafelnikof's shimmer doesn't turn.
    slot.object.type = .of(.kafelnikof);
    frame(slot, change_ticks + 100);
    try std.testing.expectApproxEqAbs(@cos(50 * swirl_rate), effect.shimmer_uv[0][0], 1e-6);
    try std.testing.expectEqual(0, effect.hull_colours[0][0][3]);
}

test Drawing {
    const gpa = std.testing.allocator;
    var stage: TestStage = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const slot = stage.slot();
    const part = stage.part();
    set(stage.mission.world(), stage.index, true);
    frame(slot, change_ticks / 2);
    part.object.position = .{ 1, 2, 3 };
    var drawing: Drawing = .{ .cloak = &slot.cloak.?, .kafelnikof = false };
    var view: objects.View = .{};

    // Halfway on: the shimmer where the part stands, and the hull half solid.
    const shimmer = drawing.shimmer(part, &view) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(part.object.position, shimmer.position);
    drawing.hull(part, &view);
    try std.testing.expectApproxEqAbs(0.5, part.object.colour[3], 1e-6);
    // The Kafelnikof shows no shimmer, but while the game is paused it is drawn as it stands.
    drawing.kafelnikof = true;
    try std.testing.expectEqual(null, drawing.shimmer(part, &view));
    view.paused = true;
    try std.testing.expect(drawing.shimmer(part, &view) != null);
}

test "PartCloak.show" {
    const gpa = std.testing.allocator;
    const srmesh = @import("../surrender/surrenderlib/srmesh.zig");
    var image: @import("../surrender/surrenderlib/srtexture.zig").Image = .{ .levels = &.{} };
    var fine = try srmesh.testing.square(gpa);
    defer fine.deinit(gpa);
    var coarse = try srmesh.testing.square(gpa);
    defer coarse.deinit(gpa);
    // The coarser level lists the square's corners the other way round.
    std.mem.reverse(Vector, coarse.positions);
    const levels = [_]srapiext.Level{ .{ .mesh = &fine, .until = 1000 }, .{ .mesh = &coarse, .until = 2000 } };
    const cloaking = try srofiles.Cloaking.build(gpa, &levels, &image);
    defer cloaking.deinit(gpa);
    const effect = try PartCloak.create(gpa, cloaking, "part", &levels, 100);
    defer effect.deinit(gpa);
    var shown = effect;
    // A hit on a corner shows it on each level, wherever that level lists it.
    shown.show(.{ .at = fine.positions[0], .radius = 100, .kafelnikof = false }, &levels, .{});
    try std.testing.expectEqual(1, shown.hull_colours[0][0][3]);
    try std.testing.expectEqual(0, shown.hull_colours[0][3][3]);
    try std.testing.expectEqual(0, shown.hull_colours[1][0][3]);
    try std.testing.expectEqual(1, shown.hull_colours[1][3][3]);
}

test shimmerColour {
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, shimmerColour(0));
    for (shimmerColour(shimmer_turn), shimmer_bright) |channel, bright| try std.testing.expectApproxEqAbs(bright, channel, 1e-6);
    for (shimmerColour(1), shimmer_full) |channel, full| try std.testing.expectApproxEqAbs(full, channel, 1e-6);
    // Halfway to bright, it is halfway there.
    try std.testing.expectApproxEqAbs(shimmer_bright[0] / 2, shimmerColour(shimmer_turn / 2)[0], 1e-6);
}

test shadeUnseen {
    const gpa = std.testing.allocator;
    var stage: TestStage = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const part = stage.part();
    set(stage.mission.world(), stage.index, true);
    // Its hull casts a shadow as solid as it stands, the part seen through.
    try std.testing.expect(part.object.alpha_shadow);
    shadeUnseen(&stage.slot().model.?, 0.75);
    try std.testing.expectEqual(0.75, part.object.colour[3]);
}

test "PartCloak.swirl" {
    const gpa = std.testing.allocator;
    var stage: TestStage = undefined;
    try stage.init(gpa);
    defer stage.deinit(gpa);
    const effect = &stage.part().cloak.?;
    // A coordinate a unit from the corner turns by `swirl_rate` a tick, and one twice as far a
    // quarter of that.
    effect.shimmer_uv[0] = .{ 1, 0 };
    effect.shimmer_uv[1] = .{ 0, 2 };
    effect.swirl(100, 1);
    const turned = 100 * swirl_rate;
    try std.testing.expectApproxEqAbs(@cos(turned), effect.shimmer_uv[0][0], 1e-6);
    try std.testing.expectApproxEqAbs(@sin(turned), effect.shimmer_uv[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(-2 * @sin(turned / 4), effect.shimmer_uv[1][0], 1e-6);
    try std.testing.expectApproxEqAbs(2 * @cos(turned / 4), effect.shimmer_uv[1][1], 1e-6);
}

// --- The countermeasures ---------------------------------------------------------------------

/// How many countermeasures fly at once (`countermeasures`, `0x00540610`).
pub const max_countermeasures = 100;

/// A countermeasure dropped (`0x24` bytes of `countermeasures`).
pub const Countermeasure = struct {
    /// When it ends (`+0x04`), and the ship that dropped it (`+0x08`).
    until: i32,
    owner: u16,
    /// How far it drifts a tick (`+0x0C`).
    velocity: Vector,
    /// Its model where it stands (`+0x18`), turning as it drifts.
    model: objects.Model,
    /// Its smoke, from its nose and its tail (`+0x1C`, `+0x20`).
    streams: [2]particles.Emitter,

    pub fn place(countermeasure: *const Countermeasure) math.Place {
        return .{ .position = countermeasure.model.position, .orientation = countermeasure.model.orientation };
    }
};

/// The decoys' smoke (`decoy_particles`, `0x00541424`): a puff a tick at half the chance, from 50
/// to 100 across, dark grey fading to nothing, for a second or a tenth more.
pub const smoke: particles.Template = .{
    .life = 100,
    .life_spread = 10,
    .rate = .through(50, 50, 50),
    .size = .through(50, 75, 100),
    .colour = @splat(.through(0.25, 0.15, 0)),
};

/// How long a countermeasure lasts (`object_spend_countermeasure`, `0x004625E2`); how fast it drops
/// away along its dropper's Y axis and back, a tick (`0x004DC56C`), beside a quarter of its
/// dropper's velocity (`0x0046267F`); how far it turns about its Y axis a tick (`decoys_update`,
/// `0x0046290C`); and its end's fireball, from the sheet: how far across and for how long
/// (`countermeasure_end`, `0x0046249B` and `0x00462499`).
const life = 1000;
const drop_away: f32 = 5;
const carried: f32 = 0.25;
const spin: f32 = 0.01;
const end_size: f32 = 200;
const end_life = 50;

/// A countermeasure's smoke: how fast it leaves, a tick (`0x0046275B`), and up to how much faster
/// (`0x00462726`), and how far it strays across either way (`0x00462743`); each stream lasts as
/// long as the countermeasure.
const smoke_speed: f32 = 5;
const smoke_speed_range: f32 = 1;
const smoke_spread: Vector = .{ 0.25, 0.25, 0 };

/// What the chance a countermeasure draws a missile away is out of (`0x00462895`).
const percent = 100;

/// How much more likely a countermeasure is to draw a missile away from a player's ship, and from
/// an AI whose pilot holds its countermeasures for 50 ticks at least (level 2 of `tier_c`), in
/// percent.
const player_bonus = 30;
const sharp_pilot_bonus = 50;
const sharp_pilot_least = 50;

/// The countermeasures in flight, and their model.
pub const Countermeasures = struct {
    gpa: Allocator,
    records: [max_countermeasures]?Countermeasure = @splat(null),
    /// `decoy_model` (`0x00541420`): `ships\decoy.shp`, where the game has it.
    model: ?objects.Mounts.Mounted,

    /// `decoys_init` (`0x00462390`), as a mission runs: none flying, and the model loaded.
    pub fn init(gpa: Allocator, mounts: ?objects.Mounts) Countermeasures {
        const loader = mounts orelse return .{ .gpa = gpa, .model = null };
        return .{ .gpa = gpa, .model = loader.load(loader.context, model_file) };
    }

    const model_file = "decoy.shp";

    /// `decoys_free` (`0x004624F0`) and the start of a mission: every countermeasure let go.
    pub fn reset(countermeasures: *Countermeasures) void {
        for (&countermeasures.records) |*record| {
            if (record.*) |*countermeasure| countermeasure.model.deinit(countermeasures.gpa);
            record.* = null;
        }
    }

    pub fn get(countermeasures: *Countermeasures, index: u8) ?*Countermeasure {
        return if (countermeasures.records[index]) |*countermeasure| countermeasure else null;
    }

    /// `object_spend_countermeasure` (`0x00462550`): the ship at `slot` drops a countermeasure,
    /// where it has one left, the player's with the display's beep; with none, the player's
    /// display refuses. It stands at the ship's tail where the step is taking it, turned as it
    /// will be, and drifts at a quarter of its velocity, dropping away 5 along its Y axis and 5
    /// back, trailing smoke from its nose and its tail, for 1000 ticks. Then each missile homing on
    /// the ship with no decoy, in the order of their records, rolls to be drawn away: its type's
    /// decoy chance, 30 more against a player's ship and 50 more against a sharp pilot's, in
    /// percent. The first drawn away takes it, and the rest keep homing: a countermeasure draws
    /// away one missile at most. With every countermeasure flying, or where memory runs out for
    /// its model, the ship's is spent for nothing.
    pub fn spend(countermeasures: *Countermeasures, world: gameobj.World, slot: u16) void {
        const all = world.objects;
        const ship = &all.slots[slot];
        const object = &ship.object;
        const player = slot == all.player;
        if (object.countermeasures < 1) {
            if (player) hud.beep(world, .refused);
            return;
        }
        object.countermeasures -= 1;
        if (player) hud.beep(world, .done);
        const at: u8 = @intCast(table.firstFreeIndex(Countermeasure, &countermeasures.records) orelse return);
        const mounted = countermeasures.model orelse return;

        var model: objects.Model = objects.Model.create(countermeasures.gpa, mounted.model, mounted.loaded, .{}) catch return;
        gameobj.linkParts(&model, mounted.model);
        const tail = object.placeAt(.next);
        const orientation = tail.orientation;
        model.place(tail.point(.{ 0, 0, object.bounds_min.z }), orientation);
        const velocity = object.velocity.vector() * @as(Vector, @splat(carried)) + (math.yAxis(orientation) - math.forward(orientation)) * @as(Vector, @splat(drop_away));
        const bounds = if (model.parts.len > 0 and model.parts[0].object.levels.len > 0) model.parts[0].object.levels[0].mesh.bounds else [2]Vector{ @splat(0), @splat(0) };
        countermeasures.records[at] = .{
            .until = world.clock.frame_start + life,
            .owner = slot,
            .velocity = velocity,
            .model = model,
            .streams = .{ stream(world, .{ 0, 0, bounds[1][2] }, .{ 0, 0, 1 }), stream(world, .{ 0, 0, bounds[0][2] }, .{ 0, 0, -1 }) },
        };

        for (&all.missiles.records) |*record| {
            const missile = &(record.* orelse continue);
            if (missile.decoy != null or missile.target.slot() != slot) continue;
            var chance = missile.stats(&all.missile_stats).decoy_chance;
            if (slot < all.players) {
                chance += player_bonus;
            } else if (all.pilots.get(object.pilot).timings.countermeasures.least == sharp_pilot_least) {
                chance += sharp_pilot_bonus;
            }
            if (@mod(@as(i32, world.random.rand()), percent) < chance) {
                missile.decoy = at;
                break;
            }
        }
    }

    /// `decoys_update` (`0x00462900`), once a frame after the explosions: each countermeasure past
    /// its time ends; the rest turn about their Y axis, drift on by their velocity times the
    /// frame's ticks, and trail their smoke.
    ///
    /// **Quirk:** a countermeasure turns by one tick more than the frame's.
    pub fn frame(countermeasures: *Countermeasures, world: gameobj.World) void {
        const turn = math.fromAngles(0, spin * @as(f32, @floatFromInt(world.clock.frame_duration + 1)), 0);
        for (&countermeasures.records, 0..) |*record, index| {
            const countermeasure = &(record.* orelse continue);
            if (countermeasure.until < world.clock.frame_start) {
                countermeasures.end(world, @intCast(index));
                continue;
            }
            const drifted = countermeasure.model.position + countermeasure.velocity * @as(Vector, @splat(@floatFromInt(world.clock.frame_duration)));
            countermeasure.model.place(drifted, math.product(countermeasure.model.orientation, turn));
            const pool = world.particles orelse continue;
            const sending = world.sending() orelse continue;
            for (&countermeasure.streams) |*emitter| _ = pool.stream(emitter, countermeasure.place(), sending);
        }
    }

    /// `countermeasure_end` (`0x00462460`): every missile it drew away turns back to its target,
    /// and it ends in a fireball, 200 across over half a second, drifting as it did.
    pub fn end(countermeasures: *Countermeasures, world: gameobj.World, at: u8) void {
        const countermeasure = countermeasures.get(at) orelse return;
        for (&world.objects.missiles.records) |*record| {
            const missile = &(record.* orelse continue);
            if (missile.decoy == at) missile.decoy = null;
        }
        explode.fireballAt(world, countermeasure.model.position, .{ .kind = .sheet, .size = end_size, .life = end_life, .velocity = countermeasure.velocity });
        countermeasure.model.deinit(countermeasures.gpa);
        countermeasures.records[at] = null;
    }

    /// OpenReliant's: the countermeasures as a drawn frame copies them (`main.Drawn.Effects`), each
    /// one's model copied into `arena` (`objects.Model.copy`), which drawing writes into as it
    /// draws it (`draw`).
    pub fn copy(countermeasures: *const Countermeasures, arena: Allocator) Allocator.Error!Countermeasures {
        var copied = countermeasures.*;
        for (&copied.records) |*record| if (record.*) |*countermeasure| {
            // Made apart first, since the copy reads the model it replaces.
            const model = try countermeasure.model.copy(arena);
            countermeasure.model = model;
        };
        return copied;
    }

    /// Adds each countermeasure's model to the world's layer. `countermeasures` is a drawn frame's
    /// copy (`copy`), whose models drawing writes into as it draws them, so that it writes nothing
    /// into the game's countermeasures.
    pub fn draw(countermeasures: *Countermeasures, gpa: Allocator, scene: *srcore.Scene, view: objects.View) Allocator.Error!void {
        for (&countermeasures.records) |*record| {
            const countermeasure = &(record.* orelse continue);
            try countermeasure.model.draw(gpa, scene, .world, view);
        }
    }
};

/// A countermeasure's stream of smoke, at `at` in its frame, leaving along `direction`.
fn stream(world: gameobj.World, at: Vector, direction: Vector) particles.Emitter {
    return .{
        .life = life,
        .born = world.clock.frame_start,
        .place = .{ .position = at },
        .direction = direction,
        .spread = smoke_spread,
        .speed = smoke_speed,
        .speed_range = smoke_speed_range,
        .template = &smoke,
    };
}

pub const testing = struct {
    pub const Cloaked = TestStage;

    /// Countermeasures of the fixture's own model, in an armed mission.
    const Stage = struct {
        armed: missiles.testing.Armed,
        dropped: Countermeasures,

        fn init(stage: *Stage) !void {
            try stage.armed.init(std.testing.allocator);
            stage.dropped = .init(std.testing.allocator, stage.armed.model.type.effects.mounts);
        }

        fn deinit(stage: *Stage) void {
            stage.dropped.reset();
            stage.armed.deinit();
        }

        fn world(stage: *Stage) gameobj.World {
            var reached = stage.armed.mission.world();
            reached.countermeasures = &stage.dropped;
            return reached;
        }
    };
};

test "Countermeasures.spend" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const all = stage.armed.mission.objects;
    const player = try stage.armed.add(.friendly, @splat(0));
    const enemy = try stage.armed.add(.hostile, .{ 0, 0, 20000 });
    all.slots[player].object.velocity = .{ .x = 0, .y = 0, .z = 40 };
    // Two Raptors at the player, sure to be drawn away.
    all.missile_stats.stats[1].decoy_chance = 100;
    const at_player: aigeneric.Target = .at(player, null);
    missiles.launch(world, enemy, 0, at_player);
    missiles.launch(world, enemy, 0, at_player);

    // One drops behind the ship, drifting at a quarter of its speed, down and back, and draws one
    // missile away, the first in its records.
    const before = all.slots[player].object.countermeasures;
    stage.dropped.spend(world, player);
    try std.testing.expectEqual(before - 1, all.slots[player].object.countermeasures);
    const countermeasure = stage.dropped.get(0).?;
    try std.testing.expectEqual(math.Vector{ 0, drop_away, 10 - drop_away }, countermeasure.velocity);
    try std.testing.expectEqual(1000, countermeasure.until);
    try std.testing.expectEqual(0, stage.armed.missile(0).decoy);
    try std.testing.expectEqual(null, stage.armed.missile(1).decoy);

    // With none left, nothing is dropped.
    all.slots[player].object.countermeasures = 0;
    stage.dropped.spend(world, player);
    try std.testing.expectEqual(null, stage.dropped.get(1));
}

test "Countermeasures.frame" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const all = stage.armed.mission.objects;
    const clock = &stage.armed.mission.clock;
    const player = try stage.armed.add(.friendly, @splat(0));
    const enemy = try stage.armed.add(.hostile, .{ 0, 0, 20000 });
    all.missile_stats.stats[1].decoy_chance = 100;
    missiles.launch(world, enemy, 0, .at(player, null));
    stage.dropped.spend(world, player);

    // It drifts by its velocity a tick, turning about its Y axis.
    clock.frame_duration = 2;
    const from = stage.dropped.get(0).?.model.position;
    stage.dropped.frame(world);
    const dropped = stage.dropped.get(0).?;
    try std.testing.expectEqual(from + dropped.velocity * @as(math.Vector, @splat(2)), dropped.model.position);
    // Past its time it ends, and the missile it drew away turns back to its target.
    clock.frame_start = 1001;
    stage.dropped.frame(world);
    try std.testing.expectEqual(null, stage.dropped.get(0));
    try std.testing.expectEqual(null, stage.armed.missile(0).decoy);
}

test "Countermeasures.draw" {
    const gpa = std.testing.allocator;
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const player = try stage.armed.add(.friendly, @splat(0));
    stage.dropped.spend(stage.world(), player);
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Each is drawn from the drawn frame's copy of its model, so none of its own parts goes into
    // the scene.
    var copied = try stage.dropped.copy(arena.allocator());
    try copied.draw(gpa, &scene, .{});
    const drawn = scene.layers.get(.world).items;
    try std.testing.expect(drawn.len > 0);
    for (drawn) |item| for (stage.dropped.get(0).?.model.parts) |*part| {
        try std.testing.expect(item.mesh != &part.object);
    };
    // The copy stays where it was while the game's drifts on.
    const at = copied.get(0).?.model.position;
    stage.dropped.get(0).?.model.position += .{ 1, 0, 0 };
    try std.testing.expectEqual(at, copied.get(0).?.model.position);
}

test "a missile drawn away catches its countermeasure" {
    var stage: testing.Stage = undefined;
    try stage.init();
    defer stage.deinit();
    const world = stage.world();
    const all = stage.armed.mission.objects;
    const clock = &stage.armed.mission.clock;
    const player = try stage.armed.add(.friendly, @splat(0));
    const enemy = try stage.armed.add(.hostile, .{ 0, 0, 20000 });
    all.missile_stats.stats[1].decoy_chance = 100;
    missiles.launch(world, enemy, 0, .at(player, null));
    stage.dropped.spend(world, player);
    // Past its launch, it homes on the countermeasure and ends with it within 1000.
    const missile = stage.armed.missile(0);
    missile.slot.drawn.position = stage.dropped.get(0).?.model.position + math.Vector{ 0, 0, 500 };
    clock.frame_start = 50;
    missiles.frame(world, 0);
    try std.testing.expectEqual(null, stage.dropped.get(0));
    try std.testing.expectEqual(0, stage.armed.live());
}
