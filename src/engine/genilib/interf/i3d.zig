//! GenILib's 3D interface (`interf.cpp`, `0x00426A30` on), which the loadout builds its hologram
//! of: objects the pointer presses and hovers, found by their projected triangles (`I3DOBJECT`);
//! animations of an object's place, angles and scale from one key to the next, each eased
//! (`I3DANIM`, `I3DFRAME`, `I3DKEYINFO`); and the interface that steps the animations each frame,
//! follows the pointer with its cursor and puts its objects in the scene (`IINTERFACE`), with a
//! stack of what to do as an animation ends (`IFUNCSTACK`).
//!
//! **Unverified:** the files of the cursor (`cursor_create`, `0x00424460`, and
//! `cursor_mesh_build`, `0x004244E0`), which lie before the file's known code, and of the tree's
//! scaling (`node_tree_scale`, `0x00428320`), which lies after it. They are the interface's own,
//! so OpenReliant keeps them with it.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const srapi = @import("../../surrender/surrenderlib/srapi.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");
const srcore = @import("../../surrender/surrenderlib/srcore.zig");
const srmesh = @import("../../surrender/surrenderlib/srmesh.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const objects = @import("../../game/objects.zig");
const xtrabits = @import("../../game/xtrabits.zig");
const ease = @import("ease.zig");
const Vector = math.Vector;

/// A rectangle of the screen, in pixels (`FRECT`, `0x10` bytes): top, left, bottom and right.
pub const Rect = struct {
    top: f32,
    left: f32,
    bottom: f32,
    right: f32,

    /// `frect_holds` (`0x00426DD0`): whether `at` lies within it, its edges included.
    pub fn holds(rect: Rect, at: [2]i32) bool {
        const x: f32 = @floatFromInt(at[0]);
        const y: f32 = @floatFromInt(at[1]);
        return rect.left <= x and x <= rect.right and rect.top <= y and y <= rect.bottom;
    }

    /// Takes in `point`, or starts at it where `first`.
    fn grow(rect: *Rect, point: [2]f32, first: bool) void {
        if (first) {
            rect.* = .{ .top = point[1], .left = point[0], .bottom = point[1], .right = point[0] };
            return;
        }
        rect.left = @min(rect.left, point[0]);
        rect.right = @max(rect.right, point[0]);
        rect.top = @min(rect.top, point[1]);
        rect.bottom = @max(rect.bottom, point[1]);
    }
};

/// Where the pointer is as an object's callback is made: the button, 1 for the left, the only one
/// the interface hands on; the pointer's place on the screen; and the object's place in the
/// interface's list (`iinterface_object_index`).
pub const Press = struct {
    button: i32 = 1,
    at: [2]i32,
    index: i32,
};

/// A callback of an object's, made with the interface's context.
pub const ObjectCallback = *const fn (context: *anyopaque, object: *Object, press: Press) void;

/// A callback of an animation's, made with the interface's context.
pub const AnimCallback = *const fn (context: *anyopaque, anim: *Anim) void;

/// What an object stands for in the scene: a scene object of its own, or a game object's tree of
/// parts (`I3DOBJECT + 0x3C`), which the animations move by its root.
pub const Target = union(enum) {
    none,
    mesh: *srapiext.MeshObject,
    tree: *objects.Model,
};

/// An object of the interface (`I3DOBJECT`, `0x48` bytes).
pub const Object = struct {
    /// Its scene object's name, or its tree's first part's, taken as it is added
    /// (`iinterface_add_object`); the loadout finds its placements by it.
    name: []const u8 = "",
    /// Its place on the screen, which the hit test tries first: made for a tree
    /// (`i3dobject_rect_update`), none otherwise (`+0x08`).
    rect: ?Rect = null,
    /// What the left button's press and release call (`+0x10`, `+0x14`), and the pointer's coming
    /// onto it and leaving it (`+0x20`, `+0x24`).
    press: ?ObjectCallback = null,
    release: ?ObjectCallback = null,
    enter: ?ObjectCallback = null,
    leave: ?ObjectCallback = null,
    /// Its creator's (`+0x28`).
    user: usize = 0,
    /// Whether the pointer finds it (`+0x2C`).
    clickable: bool,
    /// What the loadout writes under it while the pointer is on it (`+0x30`, 30 bytes); none.
    tooltip: ?[]const u8 = null,
    /// Its creator's kind for it (`+0x38`).
    kind: u32,
    target: Target = .none,
    /// Put in the scene (`+0x40`).
    shown: bool = true,
    /// On the overlay's layer rather than the world's (`+0x41`).
    overlay: bool = false,

    /// `i3dobject_create` (`0x00426A30`): an object of `kind`, `clickable` or not, with a copy of
    /// `tooltip` where it has one, standing for nothing yet.
    pub fn create(kind: u32, tooltip: ?[]const u8, clickable: bool) Object {
        var object: Object = .{ .kind = kind, .clickable = clickable };
        object.setTooltip(tooltip);
        return object;
    }

    /// A copy of `text` made its tooltip, as far as it keeps one (`tooltip_size`), or none; as its
    /// creation takes one, and as the loadout gives each of its buttons its label (`0x00443EC6`
    /// on).
    pub fn setTooltip(object: *Object, text: ?[]const u8) void {
        object.tooltip = if (text) |words| words[0..@min(words.len, tooltip_size - 1)] else null;
    }

    /// The most bytes of a tooltip an object keeps, its terminator's among them (`0x00426A93`).
    pub const tooltip_size = 30;

    /// Puts it in the scene: a scene object on the world's layer, or the overlay's where it asks,
    /// and a tree's parts as `tree_to_scene` puts them (`iinterface_scene`'s, and
    /// `iinterface_add_object`'s).
    pub fn addToScene(object: *Object, gpa: Allocator, scene: *srcore.Scene, tree_to_scene: TreeToScene) Allocator.Error!void {
        switch (object.target) {
            .none => {},
            .mesh => |mesh| try xtrabits.sceneAdd(gpa, scene, .{ .mesh = mesh }, if (object.overlay) .overlay else .world),
            .tree => |tree| try tree_to_scene(gpa, scene, tree),
        }
    }

    /// `i3dobject_hit` (`0x00426E20`): whether the pointer at `at` lies on the object as the
    /// camera of `context` sees it: within its rectangle, where it has one, then on a triangle of
    /// its projected mesh, or of any of its tree's parts (`i3dobject_hit_tree`, `0x00426B30`). Each
    /// polygon the pipeline shows is taken as a fan from its first corner (`point_in_triangle`).
    pub fn hit(object: *Object, arena: Allocator, context: *const srapi.Context, at: [2]i32) Allocator.Error!bool {
        if (object.rect) |rect| if (!rect.holds(at)) return false;
        switch (object.target) {
            .none => return false,
            .mesh => |mesh| return meshHit(arena, context, mesh, at),
            .tree => |tree| {
                for (tree.parts) |*part| {
                    if (part.hidden) continue;
                    if (try meshHit(arena, context, &part.object, at)) return true;
                }
                return false;
            },
        }
    }

    /// Where its scene object, or its tree's root, stands, which a key made of it starts from
    /// (`i3dframe_key`); the origin for an object that stands for nothing.
    pub fn position(object: Object) Vector {
        return switch (object.target) {
            .none => @splat(0),
            .mesh => |mesh| mesh.position,
            .tree => |tree| tree.position,
        };
    }

    /// Which way its scene object, or its tree's root, is turned.
    pub fn orientation(object: Object) math.Matrix {
        return switch (object.target) {
            .none => math.identity,
            .mesh => |mesh| mesh.orientation,
            .tree => |tree| tree.orientation,
        };
    }

    /// Its scene object, or its tree's root, moved to `position`, as a frame's step moves it.
    pub fn setPosition(object: *Object, at: Vector) void {
        switch (object.target) {
            .none => {},
            .mesh => |mesh| mesh.position = at,
            .tree => |tree| tree.position = at,
        }
    }

    /// Its scene object, or its tree's root, turned to `orientation`.
    pub fn setOrientation(object: *Object, turned: math.Matrix) void {
        switch (object.target) {
            .none => {},
            .mesh => |mesh| mesh.orientation = turned,
            .tree => |tree| tree.orientation = turned,
        }
    }

    /// `i3dobject_rect_update` (`0x004271C0`): for a tree, its rectangle made again round every
    /// corner of its parts' polygons the pipeline shows (`i3dobject_rect_grow`, `0x00427200`); none
    /// where none shows.
    pub fn updateRect(object: *Object, arena: Allocator, context: *const srapi.Context) Allocator.Error!void {
        const tree = switch (object.target) {
            .tree => |tree| tree,
            else => return,
        };
        var rect: Rect = undefined;
        var first = true;
        for (tree.parts) |*part| {
            if (part.hidden) continue;
            const drawn = try project(arena, context, &part.object) orelse continue;
            for (drawn.visible) |visible| {
                const polygon = drawn.mesh.polygons[visible.polygon];
                for (drawn.mesh.indices[polygon.first..][0..polygon.count]) |vertex| {
                    const screen = drawn.screen[vertex];
                    rect.grow(.{ screen.x, screen.y }, first);
                    first = false;
                }
            }
        }
        object.rect = if (first) null else rect;
    }
};

/// What puts a tree's parts in the scene, which the interface's creator gives it
/// (`node_tree_to_scene`, which places each part's frame as it goes).
pub const TreeToScene = *const fn (gpa: Allocator, scene: *srcore.Scene, tree: *objects.Model) Allocator.Error!void;

/// The scene emptied but for its lights, as `iinterface_scene` and the loadout empty it before they
/// put their objects in.
pub fn clearScene(scene: *srcore.Scene) void {
    for (&scene.layers.values) |*list| list.clearRetainingCapacity();
    scene.casters.clearRetainingCapacity();
    scene.portals.clearRetainingCapacity();
}

/// The pipeline's view of `mesh` from the camera of `context`, as the interface projects an object
/// to find it (`SR_object_rotate`, `object_level_select`, `mesh_cull`, `mesh_list_marked`,
/// `mesh_project`); null where it is out of sight.
fn project(arena: Allocator, context: *const srapi.Context, mesh: *srapiext.MeshObject) Allocator.Error!?srmesh.Drawn {
    var budget: srmesh.Budget = .{ .limit = std.math.maxInt(usize) };
    return srmesh.pipe(arena, context, mesh, &.{}, &budget);
}

/// Whether the pointer at `at` lies on a triangle of `mesh`'s projected polygons.
fn meshHit(arena: Allocator, context: *const srapi.Context, mesh: *srapiext.MeshObject, at: [2]i32) Allocator.Error!bool {
    const drawn = try project(arena, context, mesh) orelse return false;
    for (drawn.visible) |visible| {
        const polygon = drawn.mesh.polygons[visible.polygon];
        const corners = drawn.mesh.indices[polygon.first..][0..polygon.count];
        if (corners.len < 3) continue;
        const first = screenOf(drawn, corners[0]);
        for (2..corners.len) |i| {
            if (pointInTriangle(at, first, screenOf(drawn, corners[i - 1]), screenOf(drawn, corners[i]))) return true;
        }
    }
    return false;
}

fn screenOf(drawn: srmesh.Drawn, vertex: u16) [2]f32 {
    const screen = drawn.screen[vertex];
    return .{ screen.x, screen.y };
}

/// `point_in_triangle` (`0x00427080`): whether `at` lies within the triangle `a`, `b`, `c` on the
/// screen, its edges included: its place by the triangle's two edges from `a` is worked out, each
/// share from 0 to 1 and their sum no more than 1. A triangle of an area under `least_area` holds
/// nothing.
pub fn pointInTriangle(at: [2]i32, a: [2]f32, b: [2]f32, c: [2]f32) bool {
    const x = @as(f32, @floatFromInt(at[0])) - a[0];
    const y = @as(f32, @floatFromInt(at[1])) - a[1];
    const across = b - @as(@Vector(2, f32), a);
    const down = c - @as(@Vector(2, f32), a);
    const area = down[1] * across[0] - down[0] * across[1];
    if (@abs(area) < least_area) return false;
    const reciprocal = 1 / area;
    const s = (across[0] * y - across[1] * x) * reciprocal;
    const t = (down[1] * x - down[0] * y) * reciprocal;
    if (s < 0 or s > 1 or t < 0 or t > 1) return false;
    const sum = t + s;
    return sum >= 0 and sum <= 1;
}

/// The least a triangle's doubled area is for `pointInTriangle` to find anything in it
/// (`0x004DC688`).
const least_area: f32 = 1e-4;

/// A key an animation moves an object to (`I3DKEYINFO`, `0x2C` bytes): its place, its angles and
/// its scale.
///
/// Not ported: the key's vertices and colours (`+0x18` to `+0x24`), which no animation of the
/// loadout's moves.
pub const Key = struct {
    position: Vector = @splat(0),
    angles: Vector = @splat(0),
    scale: f32 = 1,

    /// `i3dframe_key` (`0x004275D0`): a key where `object` stands, turned by `angles`, at `scale`,
    /// which a builder makes each frame's key of before it moves it elsewhere.
    pub fn at(object: *const Object, angles: Vector, scale: f32) Key {
        return .{ .position = object.position(), .angles = angles, .scale = scale };
    }
};

/// An ease a frame moves a property of its object by, from its key to the next frame's.
pub const Ease = enum {
    linear,
    cosine,
    in,
    out,
    rise_fall,

    /// The ease's value `at` of the way from `from` to `to`, going `direction`: the rise and fall
    /// falls first going back (`ease_rise_fall`'s first argument).
    fn value(which: Ease, direction: Direction, from: f32, to: f32, at: f32) f32 {
        return switch (which) {
            .linear => ease.linear(from, to, at),
            .cosine => ease.cosine(from, to, at),
            .in => ease.in(from, to, at),
            .out => ease.out(from, to, at),
            .rise_fall => ease.riseFall(switch (direction) {
                .forward => .rising,
                .back => .falling,
            }, from, to, at),
        };
    }
};

/// A step of an animation, from its key to the next frame's (`I3DFRAME`, `0x34` bytes).
pub const Frame = struct {
    /// The clock's milliseconds the step began at (`+0x08`), and how long it takes (`+0x0C`).
    start: u32 = 0,
    duration: u32,
    /// The eases the object's place, angles and scale move by; none leaves the property as it is
    /// (`+0x18`, `+0x1C`, `+0x20`).
    position: ?Ease = null,
    angles: ?Ease = null,
    scale: ?Ease = null,
    key: Key,
    /// The scale a tree was last given, which the next step scales it on from (`+0x30`).
    last_scale: f32 = 1,
};

/// Whether an animation plays once, again and again, or there and back again (`I3DANIM + 0x3C`).
pub const Mode = enum(u32) { once = 0, again = 1, there_and_back = 2, _ };

/// Which way an animation plays (`I3DANIM + 0x40`): from its first key to its last, or back.
pub const Direction = enum(u32) { forward = 0, back = 1 };

/// An animation of an object (`I3DANIM`, `0x5C` bytes), from its first frame's key to its last.
pub const Anim = struct {
    /// What it is called (`+0x00`, up to 32 bytes): the loadout's names, such as `Spin Disc`.
    name: []const u8,
    object: *Object,
    frames: []Frame,
    /// The frame playing (`+0x54`); none before the animation starts.
    current: ?usize = null,
    /// Stopped (`+0x24`): set as it is made, reset or ended.
    stopped: bool = true,
    /// Set as it is reset, and cleared by its first step (`+0x44`).
    fresh: bool = false,
    mode: Mode = .once,
    direction: Direction = .forward,
    /// What each step calls (`+0x28`); what the first frame calls once it has come `share` of the
    /// way (`+0x2C`, `+0x38`), and whether it has (`+0x30`); and what its end calls (`+0x34`).
    on_step: ?AnimCallback = null,
    on_share: ?AnimCallback = null,
    share: f32 = 1,
    shared: bool = false,
    on_end: ?AnimCallback = null,
    /// Its creator's (`+0x48`).
    user: usize = 0,

    /// `i3danim_create` (`0x00427A40`): an animation called `name` of `object` over `frames`,
    /// reset to play forward.
    pub fn create(name: []const u8, object: *Object, frames: []Frame, user: usize) Anim {
        var anim: Anim = .{ .name = name, .object = object, .frames = frames, .user = user };
        anim.reset(.forward);
        return anim;
    }

    /// `i3danim_reset` (`0x00427AC0`): stopped, with no frame playing and its share not yet
    /// reached, to play `direction` next; each frame's last scale that of the key it starts from
    /// going that way.
    pub fn reset(anim: *Anim, direction: Direction) void {
        anim.direction = direction;
        anim.stopped = true;
        anim.current = null;
        anim.shared = false;
        anim.fresh = true;
        for (anim.frames, 0..) |*frame, i| switch (direction) {
            .forward => frame.last_scale = frame.key.scale,
            .back => if (i + 1 < anim.frames.len) {
                frame.last_scale = anim.frames[i + 1].key.scale;
            },
        };
    }

    /// `i3danim_start` (`0x00427B60`): playing, from its first frame going forward and from the
    /// frame before its last going back, where no frame is playing yet, the frame's start at
    /// `now`.
    pub fn start(anim: *Anim, now: u32) void {
        anim.stopped = false;
        if (anim.current == null) anim.current = switch (anim.direction) {
            .forward => 0,
            .back => anim.frames.len - 2,
        };
        anim.frames[anim.current.?].start = now;
    }

    /// `i3danim_stop` (`0x00427BB0`).
    pub fn stop(anim: *Anim) void {
        anim.stopped = true;
    }

    /// Whether it plays.
    pub fn playing(anim: Anim) bool {
        return !anim.stopped;
    }

    /// `i3danim_step` (`0x00427B10`): the frame playing stepped to `now`, and the next started
    /// where it ends into one.
    fn step(anim: *Anim, context: *anyopaque, now: u32) void {
        const current = anim.current orelse return;
        if (anim.stepFrame(context, current, now)) |next| {
            anim.current = next;
            anim.start(now);
        }
    }

    /// `i3dframe_step` (`0x004276A0`): frame `index` moved to `now`, while the animation plays:
    /// each property with an ease eased `at` of the way from the key it starts from to the other,
    /// `at` the time since the frame began over its length, held from 0 to 1; the angles made into
    /// the object's orientation (`mat3_from_angles`); the scale made the scene object's, or for a
    /// tree the ratio of the new to the last it was given (`node_tree_scale`). Then the step's
    /// callback, the share's once the first frame of a two-frame animation reaches it, and at the
    /// frame's end, the frame to go on to, if any (`frameEnd`).
    fn stepFrame(anim: *Anim, context: *anyopaque, index: usize, now: u32) ?usize {
        if (anim.stopped) return null;
        anim.fresh = false;
        const frame = &anim.frames[index];
        const elapsed: f32 = @floatFromInt(now -% frame.start);
        const at = std.math.clamp(elapsed / @as(f32, @floatFromInt(frame.duration)), 0, 1);
        const next = &anim.frames[index + 1];
        const from, const to = switch (anim.direction) {
            .forward => .{ frame.key, next.key },
            .back => .{ next.key, frame.key },
        };
        const object = anim.object;
        if (frame.position) |which| {
            var position: Vector = undefined;
            inline for (0..3) |axis| position[axis] = which.value(anim.direction, from.position[axis], to.position[axis], at);
            object.setPosition(position);
        }
        if (frame.angles) |which| {
            var angles: Vector = undefined;
            inline for (0..3) |axis| angles[axis] = which.value(anim.direction, from.angles[axis], to.angles[axis], at);
            object.setOrientation(math.fromAngles(angles[0], angles[1], angles[2]));
        }
        if (frame.scale) |which| {
            const scale = which.value(anim.direction, from.scale, to.scale, at);
            switch (object.target) {
                .none => {},
                .mesh => |mesh| mesh.scale = scale,
                .tree => |tree| {
                    const current = &anim.frames[anim.current.?];
                    scaleTree(tree, scale / current.last_scale);
                    current.last_scale = scale;
                },
            }
        }
        if (anim.on_step) |callback| callback(context, anim);
        if (index + 2 == anim.frames.len and !anim.shared and anim.share <= at) {
            if (anim.on_share) |callback| {
                anim.shared = true;
                callback(context, anim);
            }
        }
        if (at == 1) return anim.frameEnd(context, index, now);
        return null;
    }

    /// `i3dframe_end` (`0x004279B0`): the animation stopped at the end of frame `index`, and the
    /// frame to go on to going its way, where there is one. At its last: played again, from its
    /// start, where it plays again and again, with no end called; turned round where it plays
    /// there and back, and started again unless it has come back; then the first frame made the
    /// one playing, and its end called.
    fn frameEnd(anim: *Anim, context: *anyopaque, index: usize, now: u32) ?usize {
        anim.stop();
        switch (anim.direction) {
            .forward => if (index + 2 < anim.frames.len) return index + 1,
            .back => if (index > 0) return index - 1,
        }
        switch (anim.mode) {
            .again => {
                anim.reset(anim.direction);
                anim.start(now);
                return null;
            },
            .there_and_back => {
                anim.direction = switch (anim.direction) {
                    .forward => .back,
                    .back => .forward,
                };
                anim.start(now);
            },
            else => {},
        }
        anim.current = 0;
        if (anim.on_end) |callback| callback(context, anim);
        return null;
    }
};

/// `node_tree_scale` (`0x00428320`): each part of `tree` scaled by `factor`, and its place from
/// what it hangs from with it (`node_scale`, `0x00428390`), so that the whole grows or shrinks
/// about the root. What its parts carry are nodes of the tree too, such as the missiles the
/// loadout hangs on a ship: each is scaled with its place on its part, the centre of mass it
/// stands on among it.
pub fn scaleTree(tree: *objects.Model, factor: f32) void {
    for (tree.parts) |*part| {
        part.object.scale *= factor;
        part.origin *= @splat(factor);
    }
    var each = tree.carried();
    while (each.next()) |mount| {
        mount.origin *= @splat(factor);
        mount.model.centre *= @splat(factor);
        scaleTree(&mount.model, factor);
    }
}

/// What the loadout's interface draws with and hands its callbacks.
pub const Interface = struct {
    gpa: Allocator,
    /// What every callback is handed: the interface's creator.
    context: *anyopaque,
    objects: std.ArrayList(*Object) = .empty,
    anims: std.ArrayList(*Anim) = .empty,
    /// The 3D cursor, a small spinning pointer before the camera where the pointer is (`+0x18`).
    cursor: ?*srapiext.MeshObject = null,
    /// The pointer's place on the screen (`+0x1C`, `+0x20`), from the middle of the front end's
    /// screen.
    pointer: [2]i32 = .{ 320, 240 },
    /// What to do as the animations end (`+0x24`).
    stack: std.ArrayList(Deferred) = .empty,
    /// The last frame's pointer and buttons (`+0x3C` on), cleared as the interface is made.
    last: Mouse = .{ .at = .{ 0, 0 } },
    /// Set while the loadout's animations play: the pointer is left alone (`+0x50`).
    busy: bool = false,
    /// The object the pointer is on, and the one its left button went down on (`+0x54`, `+0x58`).
    hovered: ?*Object = null,
    pressed: ?*Object = null,

    /// The pointer's place and its buttons, as the interface reads them each frame.
    pub const Mouse = struct {
        at: [2]i32 = .{ 320, 240 },
        left: bool = false,
        right: bool = false,
    };

    /// Something the interface is to do once an animation ends (`IFUNCSTACK`, `0x0C` bytes): a
    /// function and what it is handed.
    pub const Deferred = struct {
        function: *const fn (context: *anyopaque, argument: usize) void,
        argument: usize,
    };

    /// `iinterface_create` (`0x00427BD0`): an interface with nothing in it, its pointer in the
    /// middle of the screen.
    pub fn create(gpa: Allocator, context: *anyopaque) Interface {
        return .{ .gpa = gpa, .context = context };
    }

    pub fn deinit(interface: *Interface) void {
        interface.objects.deinit(interface.gpa);
        interface.anims.deinit(interface.gpa);
        interface.stack.deinit(interface.gpa);
    }

    /// `iinterface_add_object` (`0x00427C70`): `object` at the end of the list, named after its
    /// scene object, or its tree's first part (`name`).
    pub fn addObject(interface: *Interface, object: *Object, name: []const u8) Allocator.Error!void {
        object.name = name;
        try interface.objects.append(interface.gpa, object);
    }

    /// `iinterface_remove_object` (`0x00427D90`): `object` out of the list, and no longer the one
    /// hovered or pressed.
    pub fn removeObject(interface: *Interface, object: *Object) void {
        if (std.mem.indexOfScalar(*Object, interface.objects.items, object)) |at| _ = interface.objects.orderedRemove(at);
        if (interface.hovered == object) interface.hovered = null;
        if (interface.pressed == object) interface.pressed = null;
    }

    /// `iinterface_object_index` (`0x00427E50`): `object`'s place in the list, -1 where it is not
    /// in it.
    pub fn indexOf(interface: Interface, object: *Object) i32 {
        const at = std.mem.indexOfScalar(*Object, interface.objects.items, object) orelse return -1;
        return @intCast(at);
    }

    /// `iinterface_add_anim` (`0x00427DE0`): `anim` at the end of the list.
    pub fn addAnim(interface: *Interface, anim: *Anim) Allocator.Error!void {
        try interface.anims.append(interface.gpa, anim);
    }

    /// `iinterface_remove_anim` (`0x00427E10`).
    pub fn removeAnim(interface: *Interface, anim: *Anim) void {
        if (std.mem.indexOfScalar(*Anim, interface.anims.items, anim)) |at| _ = interface.anims.orderedRemove(at);
    }

    /// `iinterface_frame` (`0x00427C40`): every animation stepped to `now`
    /// (`iinterface_step_anims`, `0x00427E70`), then, unless the interface is busy, the pointer
    /// followed (`follow`).
    pub fn frame(interface: *Interface, arena: Allocator, context: *const srapi.Context, now: u32, mouse: Mouse) Allocator.Error!void {
        // A callback may add animations as the list is stepped: those it adds are stepped too.
        // It may also take its own animation out, as the loadout's Attach Missile does as it ends:
        // the game takes each animation's next before it steps it, so the one after it is stepped
        // all the same.
        var i: usize = 0;
        while (i < interface.anims.items.len) {
            const anim = interface.anims.items[i];
            anim.step(interface.context, now);
            if (i < interface.anims.items.len and interface.anims.items[i] == anim) i += 1;
        }
        if (!interface.busy) try interface.follow(arena, context, now, mouse);
    }

    /// `iinterface_pointer` (`0x00427EA0`): the pointer at `mouse`'s place, kept on the screen; the
    /// left button's press called on the first clickable object under it (`Object.hit`), which
    /// becomes the pressed one, and its release on the pressed one; and, where the pointer has
    /// moved with neither button down, the object under it made the hovered one, calling its
    /// `enter` where nothing was hovered, and the one left behind's `leave`. The cursor then stands
    /// `cursor_distance` before the camera at the pointer's place, turned with the camera, and
    /// spins about its Y axis once every `cursor_turn` milliseconds.
    fn follow(interface: *Interface, arena: Allocator, context: *const srapi.Context, now: u32, mouse: Mouse) Allocator.Error!void {
        const screen = context.projection.screen;
        interface.pointer = .{
            std.math.clamp(mouse.at[0], 0, @as(i32, @intCast(screen[0])) - 1),
            std.math.clamp(mouse.at[1], 0, @as(i32, @intCast(screen[1])) - 1),
        };
        const at = interface.pointer;
        const pressing = mouse.left and !interface.last.left;
        const releasing = !mouse.left and interface.last.left;
        const moved = at[0] != interface.last.at[0] or at[1] != interface.last.at[1];

        if (releasing) if (interface.pressed) |pressed| if (pressed.release) |release| {
            release(interface.context, pressed, .{ .at = at, .index = interface.indexOf(pressed) });
        };
        const hovered = interface.hovered;
        var tooltip_hover = false;
        var under: ?*Object = null;
        for (interface.objects.items, 0..) |object, index| {
            if (!object.clickable or !try object.hit(arena, context, at)) continue;
            under = object;
            const press: Press = .{ .at = at, .index = @intCast(index) };
            if (pressing) if (object.press) |callback| {
                interface.pressed = object;
                callback(interface.context, object, press);
            };
            if (moved and !mouse.left and !mouse.right) {
                if (interface.hovered == null and object.enter != null) {
                    interface.hovered = object;
                    object.enter.?(interface.context, object, press);
                } else if (object.tooltip != null) {
                    tooltip_hover = true;
                    interface.hovered = object;
                }
            }
            break;
        } else interface.pressed = null;
        if (hovered) |left| if (under != left and interface.indexOf(left) != -1) {
            if (left.leave) |callback| callback(interface.context, left, .{ .at = at, .index = interface.indexOf(left) });
            if (!tooltip_hover) interface.hovered = null;
        };
        if (interface.cursor) |cursor| interface.placeCursor(cursor, context, now);
        interface.last = .{ .at = at, .left = mouse.left, .right = mouse.right };
    }

    /// The cursor where the pointer is (`0x004280BA` to `0x0042816F`).
    fn placeCursor(interface: Interface, cursor: *srapiext.MeshObject, context: *const srapi.Context, now: u32) void {
        const projection = context.projection;
        const camera = context.camera;
        cursor.scale = cursor_scale;
        var place: Vector = .{
            (@as(f32, @floatFromInt(interface.pointer[0])) - projection.centre[0]) / projection.scale[0] * cursor_distance,
            (@as(f32, @floatFromInt(interface.pointer[1])) - projection.centre[1]) / projection.scale[1] * cursor_distance,
            cursor_distance,
        };
        // Turned with the camera about its place (`object_face_camera`, `0x00428250`).
        place = camera.point(place);
        cursor.position = place;
        var angles = math.angles(camera.orientation);
        angles[1] += @as(f32, @floatFromInt(now % cursor_turn)) * (2 * std.math.pi / @as(f32, @floatFromInt(cursor_turn)));
        cursor.orientation = math.fromAngles(angles[0], angles[1], angles[2]);
    }

    /// `iinterface_scene` (`0x004281E0`): the scene emptied but for its lights (`clearScene`), then
    /// each object shown, or with `clickable` each clickable one too, put in it
    /// (`Object.addToScene`).
    pub fn scene(interface: *Interface, gpa: Allocator, scene_: *srcore.Scene, clickable: bool, tree_to_scene: TreeToScene) Allocator.Error!void {
        clearScene(scene_);
        for (interface.objects.items) |object| {
            if (object.shown or (clickable and object.clickable)) try object.addToScene(gpa, scene_, tree_to_scene);
        }
    }

    /// `ifuncstack_push` (`0x00428290`): `function` to be called with `argument` once an
    /// animation ends, before anything pushed earlier.
    pub fn push(interface: *Interface, function: *const fn (context: *anyopaque, argument: usize) void, argument: usize) Allocator.Error!void {
        try interface.stack.append(interface.gpa, .{ .function = function, .argument = argument });
    }

    /// `ifuncstack_run` (`0x004282E0`): the last pushed called and taken off the stack, if any.
    pub fn runDeferred(interface: *Interface) void {
        const top = interface.stack.pop() orelse return;
        top.function(interface.context, top.argument);
    }
};

/// How far before the camera the cursor stands (`0x004DC4E0`), its scale (`0x00427F63`), and the
/// milliseconds it takes to spin round once (`0x004DC698`).
const cursor_distance: f32 = 1.5;
const cursor_scale: f32 = 0.045;
const cursor_turn: u32 = 1200;

/// `cursor_mesh_build` (`0x004244E0`): the 3D cursor's mesh, a small pointer with its tip at the
/// origin: a diamond of four vertices from 1.6 to 2.4 down Y about the middle, 0.2 in front of and
/// behind which two more stand, the ten triangles running from the tip and round the two, its
/// texture coordinates all nought. Its faces' planes, its vertex normals and its bounds are worked
/// out; its one surface is left for the caller.
pub fn cursorMesh(gpa: Allocator) Allocator.Error!srapiext.Mesh {
    var mesh: srapiext.Mesh = try .create(gpa, .{ .polygons = 10, .vertices = 7, .indices = 30 });
    errdefer mesh.deinit(gpa);
    mesh.positions[0..7].* = .{
        .{ 0, 0, 0 },      .{ 0.6, 1.6, 0 },  .{ 0.3, 2.4, 0 }, .{ -0.3, 2.4, 0 },
        .{ -0.6, 1.6, 0 }, .{ 0, 1.2, -0.2 }, .{ 0, 1.2, 0.2 },
    };
    mesh.numberPolygons(3);
    mesh.indices[0..30].* = .{ 1, 0, 5, 2, 1, 5, 3, 2, 5, 4, 3, 5, 4, 5, 0, 0, 6, 4, 6, 3, 4, 6, 2, 3, 6, 1, 2, 6, 0, 1 };
    _ = try mesh.addCoordinates(gpa);
    srapi.calcPolyNormals(&mesh);
    srapi.calcVertexNormals(&mesh);
    srapi.findBoundingBox(&mesh);
    return mesh;
}

/// The 3D cursor, which the interface keeps before the camera at the pointer's place
/// (`Interface.cursor`), and the object of the interface that stands for it.
pub const Cursor = struct {
    mesh: srapiext.Mesh,
    levels: [1]srapiext.Level,
    scene_object: srapiext.MeshObject,
    object: Object,

    /// `cursor_create` (`0x00424460`): the cursor's mesh textured with `image`, lit and opaque, its
    /// scene object lit, 20 behind the camera's plane and 3 times its size until the pointer first
    /// places it; made the interface's cursor, and its object, which the pointer does not find,
    /// added to `interface` on the overlay's layer. The cursor must not move once made.
    pub fn create(cursor: *Cursor, gpa: Allocator, interface: *Interface, image: ?*srtexture.Image) Allocator.Error!void {
        cursor.mesh = try cursorMesh(gpa);
        errdefer cursor.mesh.deinit(gpa);
        cursor.mesh.surfaces[0] = .{
            .polygons = @intCast(cursor.mesh.polygons.len),
            .material = .onePass(.{ .coordinates = .mesh, .lit = true, .blend = .off }),
            .textures = .{ .of(image), .none },
        };
        cursor.levels = .{.{ .mesh = &cursor.mesh, .until = std.math.inf(f32) }};
        cursor.scene_object = .{
            .flags = .{ .lit = true },
            .position = .{ 0, 0, created_depth },
            .scale = created_scale,
            .radius = cursor.mesh.radius,
            .levels = &cursor.levels,
        };
        cursor.object = .create(0, null, false);
        cursor.object.target = .{ .mesh = &cursor.scene_object };
        cursor.object.overlay = true;
        interface.cursor = &cursor.scene_object;
        try interface.addObject(&cursor.object, cursor_name);
    }

    pub fn deinit(cursor: *Cursor, gpa: Allocator) void {
        cursor.mesh.deinit(gpa);
    }

    /// Its scene object's name (`0x004E490C`).
    const cursor_name = "Cursor Mesh";
    /// Where it stands along Z, and its scale, as it is made (`0x00424498`, `0x0042449F`).
    const created_depth: f32 = -20;
    const created_scale: f32 = 3;
};

test Rect {
    const rect: Rect = .{ .top = 10, .left = 20, .bottom = 30, .right = 40 };
    try std.testing.expect(rect.holds(.{ 20, 10 }));
    try std.testing.expect(rect.holds(.{ 40, 30 }));
    try std.testing.expect(!rect.holds(.{ 19, 20 }));
    try std.testing.expect(!rect.holds(.{ 30, 31 }));
}

test pointInTriangle {
    const a: [2]f32 = .{ 0, 0 };
    const b: [2]f32 = .{ 10, 0 };
    const c: [2]f32 = .{ 0, 10 };
    try std.testing.expect(pointInTriangle(.{ 2, 2 }, a, b, c));
    try std.testing.expect(pointInTriangle(.{ 0, 0 }, a, b, c));
    try std.testing.expect(pointInTriangle(.{ 5, 5 }, a, b, c));
    try std.testing.expect(!pointInTriangle(.{ 6, 5 }, a, b, c));
    try std.testing.expect(!pointInTriangle(.{ -1, 2 }, a, b, c));
    // Either way round.
    try std.testing.expect(pointInTriangle(.{ 2, 2 }, a, c, b));
    // A triangle with no area holds nothing.
    try std.testing.expect(!pointInTriangle(.{ 0, 0 }, a, a, b));
}

/// What the tests' callbacks count.
const Counts = struct {
    press: u32 = 0,
    release: u32 = 0,
    enter: u32 = 0,
    leave: u32 = 0,
    share: u32 = 0,
    end: u32 = 0,

    fn of(context: *anyopaque) *Counts {
        return @ptrCast(@alignCast(context));
    }
    fn pressed(context: *anyopaque, _: *Object, _: Press) void {
        of(context).press += 1;
    }
    fn released(context: *anyopaque, _: *Object, _: Press) void {
        of(context).release += 1;
    }
    fn entered(context: *anyopaque, _: *Object, _: Press) void {
        of(context).enter += 1;
    }
    fn left(context: *anyopaque, _: *Object, _: Press) void {
        of(context).leave += 1;
    }
    fn shared(context: *anyopaque, _: *Anim) void {
        of(context).share += 1;
    }
    fn ended(context: *anyopaque, _: *Anim) void {
        of(context).end += 1;
    }
};

test Anim {
    var counts: Counts = .{};
    var mesh_object: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} };
    var object: Object = .create(0, null, false);
    object.target = .{ .mesh = &mesh_object };
    var frames = [_]Frame{
        .{ .duration = 1000, .position = .linear, .scale = .linear, .key = .{ .position = .{ 0, 0, 0 }, .scale = 1 } },
        .{ .duration = 1000, .key = .{ .position = .{ 10, 0, 0 }, .scale = 3 } },
    };
    var anim: Anim = .create("Test", &object, &frames, 0);
    anim.on_share = Counts.shared;
    anim.share = 0.5;
    anim.on_end = Counts.ended;
    try std.testing.expect(!anim.playing());

    // Forward: half way at 500 ms, when the share is reached; at the end, stopped.
    anim.start(0);
    anim.step(&counts, 500);
    try std.testing.expectEqual(5, mesh_object.position[0]);
    try std.testing.expectEqual(2, mesh_object.scale);
    try std.testing.expectEqual(1, counts.share);
    anim.step(&counts, 1000);
    try std.testing.expectEqual(10, mesh_object.position[0]);
    try std.testing.expect(!anim.playing());
    try std.testing.expectEqual(1, counts.end);
    // Stopped, a step moves nothing.
    mesh_object.position[0] = 7;
    anim.step(&counts, 1500);
    try std.testing.expectEqual(7, mesh_object.position[0]);

    // Back, from the last key to the first.
    anim.reset(.back);
    anim.start(2000);
    anim.step(&counts, 2250);
    try std.testing.expectEqual(7.5, mesh_object.position[0]);
    anim.step(&counts, 3000);
    try std.testing.expectEqual(0, mesh_object.position[0]);
    try std.testing.expectEqual(2, counts.end);

    // Again and again: at its end it starts over, with no end called.
    anim.mode = .again;
    anim.reset(.forward);
    anim.start(4000);
    anim.step(&counts, 5000);
    try std.testing.expect(anim.playing());
    try std.testing.expectEqual(2, counts.end);
    anim.step(&counts, 5500);
    try std.testing.expectEqual(5, mesh_object.position[0]);
}

test Interface {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var counts: Counts = .{};
    var interface: Interface = .create(gpa, &counts);
    defer interface.deinit();

    // A square 4 across, 10 ahead of the camera, in the middle of the screen.
    const loadout = @import("../../interface/loadout/loadout.zig");
    var mesh = try loadout.squareMesh(gpa, true, 4, 4);
    defer mesh.deinit(gpa);
    mesh.surfaces[0] = .{ .polygons = @intCast(mesh.polygons.len), .material = .onePass(.{ .coordinates = .mesh, .lit = false, .blend = .off }) };
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var mesh_object: srapiext.MeshObject = .{ .flags = .{}, .position = .{ 0, 0, 10 }, .radius = 3, .levels = &levels };
    var object: Object = .create(0, "Square", true);
    object.target = .{ .mesh = &mesh_object };
    object.press = Counts.pressed;
    object.release = Counts.released;
    object.enter = Counts.entered;
    object.leave = Counts.left;
    try interface.addObject(&object, "Square");
    try std.testing.expectEqual(0, interface.indexOf(&object));

    // Near as the loadout's, which sets the near plane to 1.
    var context: srapi.Context = .{ .projection = .init(640, 480, srapi.full_screen, .{ 0.6, 0.8 }) };
    context.projection.near = 1;
    // The pointer comes onto it: it is hovered.
    try interface.frame(arena, &context, 0, .{ .at = .{ 320, 240 } });
    try std.testing.expectEqual(1, counts.enter);
    try std.testing.expectEqual(&object, interface.hovered.?);
    // The left button goes down on it and comes up.
    try interface.frame(arena, &context, 10, .{ .at = .{ 320, 240 }, .left = true });
    try std.testing.expectEqual(1, counts.press);
    try std.testing.expectEqual(&object, interface.pressed.?);
    try interface.frame(arena, &context, 20, .{ .at = .{ 320, 240 } });
    try std.testing.expectEqual(1, counts.release);
    // Off it, it is left, and nothing is pressed.
    try interface.frame(arena, &context, 30, .{ .at = .{ 10, 10 } });
    try std.testing.expectEqual(1, counts.leave);
    try std.testing.expectEqual(null, interface.hovered);
    try std.testing.expectEqual(null, interface.pressed);
    // Busy, the pointer is left alone.
    interface.busy = true;
    try interface.frame(arena, &context, 40, .{ .at = .{ 320, 240 }, .left = true });
    try std.testing.expectEqual(1, counts.press);
}

test "Interface.frame after an animation takes itself out" {
    const Removing = struct {
        interface: Interface,
        ends: u32 = 0,

        fn ended(context: *anyopaque, anim: *Anim) void {
            const removing: *@This() = @ptrCast(@alignCast(context));
            removing.ends += 1;
            removing.interface.removeAnim(anim);
        }
    };
    var removing: Removing = .{ .interface = undefined };
    removing.interface = .create(std.testing.allocator, &removing);
    defer removing.interface.deinit();
    var mesh_object: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &.{} };
    var object: Object = .create(0, null, false);
    object.target = .{ .mesh = &mesh_object };
    var frames: [2][2]Frame = @splat(.{
        .{ .duration = 100, .position = .linear, .key = .{} },
        .{ .duration = 0, .key = .{ .position = .{ 1, 0, 0 } } },
    });
    var anims: [2]Anim = undefined;
    for (&anims, &frames) |*anim, *pair| {
        anim.* = .create("Test", &object, pair, 0);
        anim.on_end = Removing.ended;
        try removing.interface.addAnim(anim);
        anim.start(0);
    }
    // The first ends and goes: the second, after it, ends in the same frame.
    removing.interface.busy = true;
    try removing.interface.frame(std.testing.allocator, undefined, 100, .{});
    try std.testing.expectEqual(2, removing.ends);
    try std.testing.expectEqual(0, removing.interface.anims.items.len);
}

test scaleTree {
    const shown: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 0, .levels = &.{} };
    var missile_parts = [_]objects.Model.Part{.{ .hidden = false, .parent = null, .origin = .{ 0, 1, 0 }, .object = shown }};
    var hung = [_]?objects.Model.Mount{ .{
        .part = 0,
        .attachment = 0,
        .origin = .{ 2, 0, 0 },
        .orientation = math.identity,
        .model = .{ .parts = &missile_parts, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{}, .centre = .{ 0, 0, 1 } },
    }, null };
    var parts = [_]objects.Model.Part{.{ .hidden = false, .parent = null, .origin = .{ 4, 0, 0 }, .object = shown }};
    var ship: objects.Model = .{ .parts = &parts, .order = &.{}, .lights = &.{}, .glows = &.{}, .mounts = &.{}, .hung = &hung };
    scaleTree(&ship, 0.5);
    try std.testing.expectEqual(0.5, parts[0].object.scale);
    try std.testing.expectEqual(Vector{ 2, 0, 0 }, parts[0].origin);
    // A missile hung on the part scales with it, its place and its centre too.
    const mount = hung[0].?;
    try std.testing.expectEqual(Vector{ 1, 0, 0 }, mount.origin);
    try std.testing.expectEqual(Vector{ 0, 0, 0.5 }, mount.model.centre);
    try std.testing.expectEqual(0.5, missile_parts[0].object.scale);
    try std.testing.expectEqual(Vector{ 0, 0.5, 0 }, missile_parts[0].origin);
}

test cursorMesh {
    const gpa = std.testing.allocator;
    var mesh = try cursorMesh(gpa);
    defer mesh.deinit(gpa);
    try std.testing.expectEqual(10, mesh.polygons.len);
    // Its tip at the origin, the last triangle closing the fan round the vertex behind.
    try std.testing.expectEqual(Vector{ 0, 0, 0 }, mesh.positions[0]);
    try std.testing.expectEqual(27, mesh.polygons[9].first);
    try std.testing.expectEqualSlices(u16, &.{ 6, 0, 1 }, mesh.indices[27..30]);
}

test Cursor {
    const gpa = std.testing.allocator;
    var counts: Counts = .{};
    var interface: Interface = .create(gpa, &counts);
    defer interface.deinit();
    var cursor: Cursor = undefined;
    try cursor.create(gpa, &interface, null);
    defer cursor.deinit(gpa);
    // The interface's cursor, and an object of it on the overlay that the pointer does not find.
    try std.testing.expectEqual(&cursor.scene_object, interface.cursor.?);
    try std.testing.expectEqual(0, interface.indexOf(&cursor.object));
    try std.testing.expect(cursor.object.overlay and !cursor.object.clickable);
    // The pointer puts it before the camera, at its own scale.
    var context: srapi.Context = .{ .projection = .init(640, 480, srapi.full_screen, .{ 0.6, 0.8 }) };
    context.projection.near = 1;
    try interface.frame(std.testing.allocator, &context, 0, .{ .at = .{ 320, 240 } });
    try std.testing.expectEqual(cursor_scale, cursor.scene_object.scale);
    try std.testing.expectApproxEqAbs(cursor_distance, cursor.scene_object.position[2], 1e-6);
}

test "Object.setTooltip" {
    var object: Object = .create(0, "Exit Loadout Computer", true);
    try std.testing.expectEqualStrings("Exit Loadout Computer", object.tooltip.?);
    // What passes its room is cut to it, its terminator's byte left.
    object.setTooltip("A tooltip far longer than the thirty bytes it keeps");
    try std.testing.expectEqual(Object.tooltip_size - 1, object.tooltip.?.len);
    object.setTooltip(null);
    try std.testing.expectEqual(null, object.tooltip);
}

test clearScene {
    const gpa = std.testing.allocator;
    var scene: srcore.Scene = .{};
    defer scene.deinit(gpa);
    var mesh = try cursorMesh(gpa);
    defer mesh.deinit(gpa);
    const levels = [_]srapiext.Level{.{ .mesh = &mesh, .until = std.math.inf(f32) }};
    var scene_object: srapiext.MeshObject = .{ .flags = .{}, .position = @splat(0), .radius = 1, .levels = &levels };
    var object: Object = .create(0, null, false);
    object.target = .{ .mesh = &scene_object };
    object.overlay = true;
    try object.addToScene(gpa, &scene, undefined);
    try std.testing.expectEqual(1, scene.layers.get(.overlay).items.len);
    try scene.lights.append(gpa, .{ .mask = 0, .intensity = 1, .colour = @splat(1), .kind = .ambient });
    // The objects go, the lights stay.
    clearScene(&scene);
    try std.testing.expectEqual(0, scene.layers.get(.overlay).items.len);
    try std.testing.expectEqual(1, scene.lights.items.len);
}
