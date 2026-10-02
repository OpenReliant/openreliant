//! `C:\lancer\game\xtrabits.cpp`: odds and ends of the game's frame. `scene_add` (`0x004ADB30`)
//! puts an object in the scene for the frame, `object_random15` (`0x004ADCE0`) draws an object's
//! own random numbers, `0x004AAFC0` clips a line to a pane, and `node_tree_clip` (`0x004ADEE0`)
//! has a portal cut an object's parts (`clipTree`). **Unverified:** that the third and the last
//! are this file's: the third lies between the message pump and the first code the file's
//! assertions place, the last after the last code they place.
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

const srapiext = @import("../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../surrender/surrenderlib/srcore.zig");
const srlight = @import("../surrender/surrenderlib/srlight.zig");
const srstars = @import("../surrender/surrenderlib/srstars.zig");
const libcmt = @import("../libcmt.zig");
const GameObject = @import("gameobj.zig").GameObject;
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
        return switch (detail) {
            _ => writer.print("texture detail {d}", .{@intFromEnum(detail)}),
            inline else => |named| writer.writeAll(@tagName(named)),
        };
    }
};

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

/// Clips part `index` of `model` and every part of each model it carries, however deep, by
/// `portal`, or, where null, by none, the flag left as it was (`node_tree_clip`, `0x004ADEE0`;
/// `node_tree_unclip`, `0x004ADF40`).
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

/// `object_random15` (`0x004ADCE0`): the object's own random number from 0 to 32767, which steps
/// its seed (`GameObject.random_seed`) as the C runtime's `rand` steps its own. **Unverified:** it
/// lies after this file's known code, before `deathmatch.cpp`'s.
pub fn objectRandom15(object: *GameObject) u15 {
    var random: libcmt.Rand = .{ .seed = object.random_seed };
    defer object.random_seed = random.seed;
    return random.rand();
}

/// `object_random` (`0x004ADD10`): the object's own random number from 0 to 1, which is
/// `objectRandom15` times the reciprocal of the runtime's largest (`0x004DC710`), as
/// `Rand.fraction` takes it. **Unverified:** it lies after this file's known code, before
/// `deathmatch.cpp`'s.
pub fn objectRandom(object: *GameObject) f32 {
    var random: libcmt.Rand = .{ .seed = object.random_seed };
    defer object.random_seed = random.seed;
    return random.fraction();
}

/// `ship_type_first_levels` (`0x004AE190`): a ship type's model, loaded where none of its objects
/// has yet, one more object of it counted, and its first part's levels of detail. Null where the
/// game has no model for it. **Unverified:** it lies after this file's known code.
pub fn firstLevels(all: *create.Objects, types: create.Types, ship_type: u8) ?[]const srapiext.Level {
    const loaded = all.useType(types, ship_type) orelse return null;
    const parts = loaded.loaded.parts;
    return if (parts.len > 0) parts[0].levels else null;
}

test firstLevels {
    var random: libcmt.Rand = .{};
    const all = try create.Objects.create(std.testing.allocator, &random);
    defer all.destroy();

    // A type without a model has no levels, but is counted as used all the same.
    try std.testing.expectEqual(null, firstLevels(all, create.testing.no_models, 0x4E));
    try std.testing.expectEqual(1, all.types[0x4E].objects);

    // One with a model gives its first part's.
    var model: create.testing.Model = undefined;
    try model.init(std.testing.allocator);
    defer model.deinit(std.testing.allocator);
    const levels = firstLevels(all, model.types(), 0x4F).?;
    try std.testing.expectEqual(&model.mesh, levels[0].mesh);
    try std.testing.expectEqual(1, all.types[0x4F].objects);
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
    try std.testing.expectEqual(1 *% 214013 +% 2531011, object.random_seed);
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

test TextureDetail {
    try std.testing.expectEqual(128, TextureDetail.low.largest().?);
    try std.testing.expectEqual(256, TextureDetail.medium.largest().?);
    try std.testing.expectEqual(null, TextureDetail.high.largest());
    try std.testing.expectEqual(null, @as(TextureDetail, @enumFromInt(7)).largest());
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("medium", try std.fmt.bufPrint(&buffer, "{f}", .{TextureDetail.medium}));
    try std.testing.expectEqualStrings("texture detail 7", try std.fmt.bufPrint(&buffer, "{f}", .{@as(TextureDetail, @enumFromInt(7))}));
}

test {
    _ = landing;
    _ = loading;
    _ = movie;
    _ = screenshot;
}
