//! `C:\lancer\game\xtrabits.cpp`: odds and ends of the game's frame. `scene_add` (`0x004ADB30`)
//! puts an object in the scene for the frame, `object_random15` (`0x004ADCE0`) draws an object's
//! own random numbers, `0x004AAFC0` clips a line to a pane, and `node_clip_named` (`0x004ADEA0`)
//! and `node_tree_clip` (`0x004ADEE0`) have a portal cut a part or all of an object's parts
//! (`clipNamed`, `clipTree`). **Unverified:** that the third and the last two are this file's:
//! the third lies between the message pump and the first code the file's assertions place, the
//! last two after the last code they place.
//!
//! `renderer_start` (`0x004ACBE0`) caps the textures' sides by the texture detail
//! (`TextureDetail`).
//!
//! The loading screens the game shows as it starts and before each attempt at a mission are in
//! [`xtrabits/loading.zig`](xtrabits/loading.zig), the movies it plays in a loop of their own in
//! [`xtrabits/movie.zig`](xtrabits/movie.zig), what it plays as the pilot comes back from a
//! mission in [`xtrabits/landing.zig`](xtrabits/landing.zig), and the screenshots its keys save in
//! [`xtrabits/screenshot.zig`](xtrabits/screenshot.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;

const layout = @import("../../formats/layout.zig");
const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srstars = @import("../surrender/surrenderlib/srstars.zig");
const Random = @import("../random.zig").Random;
const gameobj = @import("gameobj.zig");
const GameObject = gameobj.GameObject;
const create = @import("create.zig");
const objects = @import("objects.zig");

/// The texture detail setting (`Tdetail`, `texture_detail`, `0x00595D7C`), which `renderer_start`
/// uses to limit a texture's longest side (`0x004ACF9F`), lowering the device's own limit if it's
/// larger: 128 at 0, 256 at 1 and 2048 at 2, and the device's limit for any other value. The
/// original video screen switches between 0 and 1, which it calls LOW and HIGH.
///
/// **Improvement:** HIGH, 2, sets no limit, where the original limits textures to 2048, which none
/// of the original textures reach, so a mod's picture keeps its full size. The settings screen
/// calls 1 MEDIUM.
pub const TextureDetail = enum(u32) {
    low = 0,
    medium = 1,
    high = 2,
    _,

    /// The longest side a texture keeps, null for any.
    pub fn largest(detail: TextureDetail) ?u32 {
        return switch (detail) {
            .low => low_side,
            .medium => medium_side,
            .high, _ => null,
        };
    }

    const low_side = 128;
    const medium_side = 256;

    pub fn format(detail: TextureDetail, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return layout.formatTagAs(TextureDetail, detail, "texture detail", writer);
    }
};

pub const ending = @import("xtrabits/ending.zig");
pub const landing = @import("xtrabits/landing.zig");
pub const loading = @import("xtrabits/loading.zig");
pub const movie = @import("xtrabits/movie.zig");
pub const screenshot = @import("xtrabits/screenshot.zig");

/// A scene object of any kind `scene_add` takes.
pub const Object = union(enum) {
    mesh: *srapiext.MeshObject,
    light: *const srlight.Light,
    sprites: *srapiext.SpriteSet,
    stars: *srstars.Field,
    portal: *srapiext.Portal,
};

/// Puts `object` in the scene for the frame (`scene_add`): at the head of `layer`'s list, or of the
/// lights' for a light and the portals' for a portal, whatever the layer. A hidden object is left
/// out, as is a mesh object whose level has no polygons. `mission_frame` empties the lists each
/// frame.
pub fn sceneAdd(gpa: Allocator, scene: *srcore.Scene, object: Object, layer: srcore.Layer) Allocator.Error!void {
    const list = scene.layers.getPtr(layer);
    switch (object) {
        .mesh => |mesh| {
            if (mesh.flags.hidden) return;
            if (mesh.levels.len == 0 or mesh.levels[mesh.level].mesh.polygons.len == 0) return;
            try list.append(gpa, .{ .mesh = mesh });
        },
        .light => |light| try scene.lights.append(gpa, light.*),
        .sprites => |sprites| if (!sprites.flags.hidden) try list.append(gpa, .{ .sprites = sprites }),
        .stars => |field| if (!field.flags.hidden) try list.append(gpa, .{ .stars = field }),
        .portal => |portal| try scene.portals.append(gpa, portal),
    }
}

/// What `sceneAddCopy` puts in the scene: a mesh object, one with a mesh of its own, or a set of
/// sprites, as a frame draws it.
pub const Copied = union(enum) {
    mesh: srapiext.MeshObject,
    own_mesh: OwnMesh,
    sprites: srapiext.SpriteSet,
};

/// A mesh object that draws a mesh of its own at every distance, as one level of detail, the way
/// `mesh_object_create` makes one. The copy gets its own level, made with it.
pub const OwnMesh = struct {
    object: srapiext.MeshObject,
    mesh: *const srapiext.Mesh,
};

/// Puts a copy of `copied` in the scene for the frame (`sceneAdd`). The copy is made in `arena`,
/// which lasts until the frame is drawn, so neither drawing nor the pipeline, as it picks a mesh
/// object's level, writes into the original. The effects draw with it: each copy stands where the
/// frame draws it, and the effect's own record is left as it is.
pub fn sceneAddCopy(gpa: Allocator, arena: Allocator, scene: *srcore.Scene, copied: Copied, layer: srcore.Layer) Allocator.Error!void {
    switch (copied) {
        .mesh => |mesh| {
            const copy = try arena.create(srapiext.MeshObject);
            copy.* = mesh;
            try sceneAdd(gpa, scene, .{ .mesh = copy }, layer);
        },
        .own_mesh => |own| {
            const copy = try arena.create(struct { object: srapiext.MeshObject, level: [1]srapiext.Level });
            copy.level = .{.{ .mesh = own.mesh, .until = std.math.inf(f32) }};
            copy.object = own.object;
            copy.object.levels = &copy.level;
            try sceneAdd(gpa, scene, .{ .mesh = &copy.object }, layer);
        },
        .sprites => |set| {
            const copy = try arena.create(srapiext.SpriteSet);
            copy.* = set;
            try sceneAdd(gpa, scene, .{ .sprites = copy }, layer);
        },
    }
}

/// Clips part `index` of `model`, and every part of each model it carries however deep, by
/// `portal`. A null portal clears the portal but leaves the flag as it was (`node_tree_clip`,
/// `0x004ADEE0`; `node_tree_unclip`, `0x004ADF40`).
pub fn clipPart(model: *objects.Model, index: usize, portal: ?*const srapiext.Portal) void {
    const part = &model.parts[index];
    part.object.portal = portal;
    if (portal != null) part.object.flags.portal_clipped = true;
    var each = model.carriedBy(index);
    while (each.next()) |mount| clipTree(&mount.model, portal);
}

/// `clipPart` for every part of `model`, as `node_tree_clip` clips an object from its root.
pub fn clipTree(model: *objects.Model, portal: ?*const srapiext.Portal) void {
    for (0..model.parts.len) |index| clipPart(model, index, portal);
}

/// `node_clip_named` (`0x004ADEA0`): clips the first part of `model` named `name`
/// (`objects.Model.partNamed`) by `portal`. A null portal clears both the portal and the flag. The
/// parts that hang from it and the models it carries are left as they are.
pub fn clipNamed(model: *objects.Model, name: []const u8, portal: ?*const srapiext.Portal) void {
    const ref = model.partNamed(name) orelse return;
    const object = &ref.part().object;
    object.portal = portal;
    object.flags.portal_clipped = portal != null;
}

/// OpenReliant's: the portals a drawn frame cuts its copy of the objects with (`main.Drawn`), one
/// for each portal of the game's that a split or a gate keeps. The owner places each where the
/// game's stands. Each keeps from one drawn frame to the next the plane the pipeline last gave it
/// in the camera's frame (`srapiext.Portal.transform`), as the game's own portal keeps it: one
/// left out of the scene cuts by the plane it last had there, and a new one by none. So neither
/// drawing nor the pipeline writes into the game's portals.
pub const Portals = struct {
    held: [capacity]?Held = @splat(null),

    /// Room for the portals of every split and gate there can be (`main.Drawn`).
    pub const capacity = 64;

    const Held = struct {
        /// The game's portal, and the tick its owner made it at, which tells it from a later one
        /// in its place.
        game: *const srapiext.Portal,
        made: i32,
        portal: srapiext.Portal = .{},
        /// Whether its owner stood it this drawn frame.
        stood: bool = true,
    };

    /// Before the owners stand theirs (`stand`): none stood yet.
    pub fn begin(portals: *Portals) void {
        for (&portals.held) |*slot| if (slot.*) |*held| {
            held.stood = false;
        };
    }

    /// Drawing's portal for `game`, which its owner made at tick `made`: the one it had for it the
    /// frame before, with the plane it last had in the camera's frame, or a new one with none. The
    /// owner places it. Null where all are taken.
    pub fn stand(portals: *Portals, game: *const srapiext.Portal, made: i32) ?*srapiext.Portal {
        var free: ?*?Held = null;
        for (&portals.held) |*slot| {
            const held = &(slot.* orelse {
                if (free == null) free = slot;
                continue;
            });
            if (held.game != game) continue;
            if (held.made != made) held.* = .{ .game = game, .made = made };
            held.stood = true;
            return &held.portal;
        }
        const slot = free orelse return null;
        slot.* = .{ .game = game, .made = made };
        return &slot.*.?.portal;
    }

    /// After the owners stood theirs: the ones no owner stood go.
    pub fn end(portals: *Portals) void {
        for (&portals.held) |*slot| if (slot.*) |held| {
            if (!held.stood) slot.* = null;
        };
    }

    /// Drawing's portal for `game`, where its owner stood one.
    pub fn of(portals: *Portals, game: *const srapiext.Portal) ?*srapiext.Portal {
        for (&portals.held) |*slot| {
            const held = &(slot.* orelse continue);
            if (held.game == game) return &held.portal;
        }
        return null;
    }

    /// Points each part of `model`, and of the models it carries however deep, that one of the
    /// game's portals cuts at drawing's portal for it.
    pub fn cut(portals: *Portals, model: *objects.Model) void {
        for (model.parts) |*part| {
            const game = part.object.portal orelse continue;
            if (portals.of(game)) |mine| part.object.portal = mine;
        }
        var each = model.carried();
        while (each.next()) |mount| portals.cut(&mount.model);
    }
};

test sceneAdd {
    const gpa = std.testing.allocator;
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);

    const levels = [_]srapiext.Level{.{ .mesh = &@import("srofiles.zig").empty, .until = std.math.inf(f32) }};
    var nothing: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = &levels };
    try sceneAdd(gpa, &scene, .{ .mesh = &nothing }, .world);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);

    var sprites: srapiext.SpriteSet = .{ .sprites = &.{} };
    try sceneAdd(gpa, &scene, .{ .sprites = &sprites }, .overlay);
    sprites.flags.hidden = true;
    try sceneAdd(gpa, &scene, .{ .sprites = &sprites }, .overlay);
    try std.testing.expectEqual(1, scene.layers.get(.overlay).items.len);

    // A light goes to the lights' list, whatever the layer.
    const light: srlight.Light = .{ .mask = 1, .intensity = 1, .colour = .{ 1, 1, 1 }, .kind = .ambient };
    try sceneAdd(gpa, &scene, .{ .light = &light }, .background);
    try std.testing.expectEqual(1, scene.lights.items.len);
    try std.testing.expectEqual(0, scene.layers.get(.background).items.len);

    // A portal likewise goes to the portals' list.
    var portal: srapiext.Portal = .{};
    try sceneAdd(gpa, &scene, .{ .portal = &portal }, .world);
    try std.testing.expectEqual(1, scene.portals.items.len);
    try std.testing.expectEqual(0, scene.layers.get(.world).items.len);
}

test sceneAddCopy {
    const gpa = std.testing.allocator;
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const mesh = try @import("../surrender/surrenderlib/srmesh.zig").testing.square(gpa);
    defer mesh.deinit(gpa);

    // The scene holds a copy, so changing the original afterwards leaves the copy as it was.
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var object: srapiext.MeshObject = .{ .flags = .{}, .position = .{ 1, 2, 3 }, .radius = 100, .levels = &levels };
    try sceneAddCopy(gpa, arena.allocator(), &scene, .{ .mesh = object }, .world);
    object.position = @splat(0);
    try std.testing.expectEqual(@Vector(3, f32){ 1, 2, 3 }, scene.layers.get(.world).items[0].mesh.position);

    // A set of sprites likewise, and a hidden one is left out, as `sceneAdd` leaves it out.
    var set: srapiext.SpriteSet = .{ .sprites = &.{} };
    try sceneAddCopy(gpa, arena.allocator(), &scene, .{ .sprites = set }, .overlay);
    set.flags.hidden = true;
    try std.testing.expect(!scene.layers.get(.overlay).items[0].sprites.flags.hidden);
    try sceneAddCopy(gpa, arena.allocator(), &scene, .{ .sprites = set }, .overlay);
    try std.testing.expectEqual(1, scene.layers.get(.overlay).items.len);

    // An object with a mesh of its own draws it at every distance, through a level made with the
    // copy.
    const own: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 100, .levels = &.{} };
    try sceneAddCopy(gpa, arena.allocator(), &scene, .{ .own_mesh = .{ .object = own, .mesh = &mesh } }, .background);
    const drawn = scene.layers.get(.background).items[0].mesh;
    try std.testing.expectEqual(1, drawn.levels.len);
    try std.testing.expectEqual(&mesh, drawn.levels[0].mesh);
    try std.testing.expectEqual(std.math.inf(f32), drawn.levels[0].until);
}

test Portals {
    const gpa = std.testing.allocator;
    var portals: Portals = .{};
    const game: [2]srapiext.Portal = .{ .{}, .{} };

    // A new portal has no plane in the camera's frame yet, and keeps the one it is given from one
    // frame to the next.
    portals.begin();
    const first = portals.stand(&game[0], 10).?;
    try std.testing.expectEqual(srapiext.Portal.View{}, first.view);
    first.view.point = .{ 1, 2, 3 };
    portals.end();
    portals.begin();
    try std.testing.expectEqual(first, portals.stand(&game[0], 10).?);
    try std.testing.expectEqual(srapiext.Portal.View{ .point = .{ 1, 2, 3 } }, first.view);
    // One its owner made later in the same place starts again.
    try std.testing.expectEqual(srapiext.Portal.View{}, portals.stand(&game[0], 20).?.view);
    portals.end();

    // The parts a game's portal cuts are pointed at drawing's for it; the rest are left alone.
    var named: objects.testing.NamedParts(2) = undefined;
    named.init(.{ "Hull", "Top" }, .{ .cut, .cut }, .{ &.{}, &.{} });
    var model = try named.parts.create(gpa);
    defer model.deinit(gpa);
    clipNamed(&model, "Top", &game[0]);
    clipNamed(&model, "Hull", &game[1]);
    portals.begin();
    const mine = portals.stand(&game[0], 20).?;
    portals.end();
    portals.cut(&model);
    try std.testing.expect(model.parts[1].object.portal == mine);
    try std.testing.expect(model.parts[0].object.portal == &game[1]);

    // Once its owner stands it no more, it goes.
    portals.begin();
    portals.end();
    try std.testing.expectEqual(null, portals.of(&game[0]));
}

/// What `object_random15` (`0x004ADCE0`) multiplies an object's seed by, the same step as the C
/// runtime's `rand` (`0x004CF555`).
const seed_multiplier: u32 = 214013;

/// What `object_random15` (`0x004ADCE0`) then adds to the seed, as `rand` (`0x004CF555`) does.
const seed_increment: u32 = 2531011;

/// `object_random15` (`0x004ADCE0`): the object's own random number from 0 to 32767, bits 16 to
/// 30 of its seed (`GameObject.random_seed`) after one step. **Unverified:** it lies after this
/// file's known code, before `deathmatch.cpp`'s.
pub fn objectRandom15(object: *GameObject) u15 {
    var seed: std.Random.lcg.Wrapping(u32) = .init(object.random_seed, seed_multiplier, seed_increment);
    object.random_seed = seed.next();
    return @truncate(object.random_seed >> 16);
}

/// `object_random` (`0x004ADD10`): the object's own random number from 0 to 1, which is
/// `objectRandom15` times the reciprocal of the largest it gives (`0x004DC710`, `Random.share`).
/// **Unverified:** it lies after this file's known code, before `deathmatch.cpp`'s.
pub fn objectRandom(object: *GameObject) f32 {
    return Random.share(objectRandom15(object));
}

/// `ship_type_first_levels` (`0x004AE190`): a ship type's model, loaded where it isn't yet, kept
/// loaded, and its first part's levels of detail. Null where the game has no model for it.
/// **Unverified:** it lies after this file's known code.
///
/// **Improvement:** the game keeps the type loaded by counting one more object of it
/// (`create.Objects.useType`). Only drawing code calls it, so OpenReliant marks the type in `kept`
/// instead, which a mission's start keeps loaded (`library.TypeCache.sweep`), and the objects'
/// counts stay the game's own.
pub fn firstLevels(types: create.Types, kept: *create.TypeSet, ship_type: gameobj.Type) ?[]const srapiext.Level {
    kept.set(ship_type.number());
    const loaded = types.load(types.context, @intCast(ship_type.number())) orelse return null;
    const parts = loaded.loaded.parts;
    return if (parts.len > 0) parts[0].levels else null;
}

test firstLevels {
    var kept: create.TypeSet = .empty;

    // A type without a model has no levels, but is kept all the same.
    try std.testing.expectEqual(null, firstLevels(create.testing.no_models, &kept, .of(.debris)));
    try std.testing.expect(kept.isSet(gameobj.GameType.debris.number()));

    // One with a model gives its first part's.
    var model: create.testing.Model = undefined;
    try model.init(std.testing.allocator);
    defer model.deinit(std.testing.allocator);
    const levels = firstLevels(model.types(), &kept, .of(.debris_1)).?;
    try std.testing.expectEqual(&model.mesh, levels[0].mesh);
    try std.testing.expect(kept.isSet(gameobj.GameType.debris_1.number()));
}

test objectRandom {
    var object = std.mem.zeroes(GameObject);
    object.random_seed = 1;
    try std.testing.expectApproxEqAbs(41.0 / 32767.0, objectRandom(&object), 1e-9);
    // Every number it gives lies between 0 and 1.
    for (0..100) |_| {
        const number = objectRandom(&object);
        try std.testing.expect(number >= 0 and number <= 1);
    }
}

test objectRandom15 {
    // From the seed the runtime starts on, the runtime's first number, and the seed stepped on.
    var object = std.mem.zeroes(GameObject);
    object.random_seed = 1;
    try std.testing.expectEqual(41, objectRandom15(&object));
    try std.testing.expectEqual(1 *% seed_multiplier +% seed_increment, object.random_seed);
}

/// Which edges of a pane a point lies beyond, as `0x004AAFC0` codes them.
const Outcode = packed struct(u4) {
    below: bool = false,
    above: bool = false,
    right: bool = false,
    left: bool = false,

    fn of(point: [2]i32, last: [2]i32) Outcode {
        return .{ .below = point[1] > last[1], .above = point[1] < 0, .right = point[0] > last[0], .left = point[0] < 0 };
    }

    fn outside(code: Outcode) bool {
        return @as(u4, @bitCast(code)) != 0;
    }

    /// Whether both points lie beyond one edge, which leaves the whole line beyond it.
    fn shared(a: Outcode, b: Outcode) bool {
        return @as(u4, @bitCast(a)) & @as(u4, @bitCast(b)) != 0;
    }
};

/// `0x004AAFC0`: clips the line from `from` to `to` to a pane at the screen's corner whose last
/// pixel is `last`, as the display's pane is, cutting an end outside back to the edge it crosses
/// by whole-number sums, then keeps both ends on the screen. Returns whether any of the line is
/// on the pane; a line wholly off it is left as it was.
pub fn clipLine(last: [2]i32, from: *[2]i32, to: *[2]i32) bool {
    var codes: [2]Outcode = .{ .of(from.*, last), .of(to.*, last) };
    while (codes[0].outside() or codes[1].outside()) {
        if (codes[0].shared(codes[1])) return false;
        const end = if (codes[0].outside()) from else to;
        const out = if (codes[0].outside()) codes[0] else codes[1];
        const a = from.*;
        const b = to.*;
        var cut: [2]i32 = undefined;
        if (out.below or out.above) {
            cut[1] = if (out.below) last[1] else 0;
            cut[0] = @divTrunc((cut[1] - a[1]) * (b[0] - a[0]), b[1] - a[1]) + a[0];
        } else {
            cut[0] = if (out.right) last[0] else 0;
            cut[1] = @divTrunc((cut[0] - a[0]) * (b[1] - a[1]), b[0] - a[0]) + a[1];
        }
        end.* = cut;
        codes = .{ .of(from.*, last), .of(to.*, last) };
    }
    for ([2]*[2]i32{ from, to }) |point| {
        for (point, last) |*c, most| c.* = std.math.clamp(c.*, 0, most);
    }
    return true;
}

test clipLine {
    const last: [2]i32 = .{ 639, 479 };
    // A line from the middle out past the right edge stops on it, at the height it crosses at.
    var from: [2]i32 = .{ 320, 240 };
    var to: [2]i32 = .{ 959, 240 };
    try std.testing.expect(clipLine(last, &from, &to));
    try std.testing.expectEqual([2]i32{ 639, 240 }, to);
    try std.testing.expectEqual([2]i32{ 320, 240 }, from);
    // Out past a corner, it stops on the edge it crosses first.
    to = .{ 1000, 1000 };
    try std.testing.expect(clipLine(last, &from, &to));
    try std.testing.expectEqual(479, to[1]);
    try std.testing.expectEqual(@divTrunc((479 - 240) * (1000 - 320), 1000 - 240) + 320, to[0]);
    // A line wholly beyond one edge is left as it was.
    from = .{ -10, 5 };
    to = .{ -20, 50 };
    try std.testing.expect(!clipLine(last, &from, &to));
    try std.testing.expectEqual([2]i32{ -20, 50 }, to);
}

test clipNamed {
    const gpa = std.testing.allocator;
    var named: objects.testing.NamedParts(2) = undefined;
    named.init(.{ "Hull", "Top" }, .{ .cut, .cut }, .{ &.{}, &.{} });
    var model = try named.parts.create(gpa);
    defer model.deinit(gpa);
    const portal: srapiext.Portal = .{};
    // The part of the name is clipped by the portal, and the other is left alone.
    clipNamed(&model, "Top", &portal);
    try std.testing.expect(model.parts[1].object.portal == &portal and model.parts[1].object.flags.portal_clipped);
    try std.testing.expect(model.parts[0].object.portal == null and !model.parts[0].object.flags.portal_clipped);
    // None clears its portal and its flag; a name no part has changes nothing.
    clipNamed(&model, "Top", null);
    try std.testing.expect(model.parts[1].object.portal == null and !model.parts[1].object.flags.portal_clipped);
    clipNamed(&model, "Fin", &portal);
    try std.testing.expect(model.parts[0].object.portal == null and model.parts[1].object.portal == null);
}

test TextureDetail {
    try std.testing.expectEqual(128, TextureDetail.low.largest().?);
    try std.testing.expectEqual(256, TextureDetail.medium.largest().?);
    try std.testing.expectEqual(null, TextureDetail.high.largest());
    try std.testing.expectEqual(null, @as(TextureDetail, @fromBackingInt(7)).largest());
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("medium", try std.mem.print(&buffer, "{f}", .{TextureDetail.medium}));
    try std.testing.expectEqualStrings("texture detail 7", try std.mem.print(&buffer, "{f}", .{@as(TextureDetail, @fromBackingInt(7))}));
}

test {
    std.testing.refAllDecls(@This());
}
