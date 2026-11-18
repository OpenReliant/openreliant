//! The player's subtarget picked out in red on its target's model (`hud_subtarget`, `0x0048CC30`,
//! and `hud_subtarget_clear`, `0x0048CA80`, from `hud.cpp`).
//!
//! Each part of the subtarget's assembly, the parts of its model that share its component's
//! `link_id`, up to `max_parts`, shows a copy of its levels whose surfaces are drawn in one pass and
//! lit, takes no light from the first six lights (`light_mask`), and has red for its own colour
//! (`red`), so the lighting draws it in red over its texture. The game copies the meshes because
//! every object of a type shares them; OpenReliant copies each level's mesh with its surfaces, the
//! only part it changes, and shares the rest. Putting the parts back lets the copies go, or, while a
//! drawn frame may still show them, keeps them until it is drawn (`Subtarget.hold`).
//!
//! A switch of view picks the parts out as the view becomes 0 and puts them back for any other,
//! as the camera takes it up (`camera.Camera.notice`); `mission_frame` picks them out in view 0 where the target or its component changed
//! (`main.keepPlayerTarget`); a component lost on the target puts them back (`objects.loseComponents`,
//! `node_draw`); and the next mission's start puts them back, before its objects are reset, which
//! the game does as the mission before ends (`mission_run`, at `0x00494260`). `openreliant` puts
//! them back as it quits, before the objects go, so that the copies go too.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ai = @import("../ai.zig");
const aigeneric = @import("../aigeneric.zig");
const create = @import("../create.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const srapiext = @import("../../surrender/surrenderlib/srapiext.zig");

/// The most parts picked out at once: the room the game keeps for them (`0x00569944`,
/// `0x00579E04`).
pub const max_parts = 10;

/// The lights that don't reach a part picked out: the first six (`0x0048CD80`).
pub const light_mask: u32 = 0x3F;

/// A part's own colour while picked out: red, its alpha nothing (`0x0048CE37`).
pub const red: [4]f32 = .{ 1, 0, 0, 0 };

/// The target and the component whose parts are picked out, and what those parts had before.
///
/// **Fix:** the game overwrites one saved scene object (`0x005656C0`) for every part. When
/// restoring part `n`, it reads the colour and light mask from record `n` past that address.
/// The first part gets the last one's values, and later parts read past the saved record. It also
/// restores only three colour channels. OpenReliant saves each part and restores all four channels.
pub const Subtarget = struct {
    /// The object and component picked out (`0x0057999C`, `0x0057999E`). OpenReliant keeps the
    /// object's identity, and uses null where the original keeps -1.
    target: ?struct { object: gameobj.ObjectRef, component: u16 } = null,
    saved: [max_parts]Saved = undefined,
    count: usize = 0,
    /// OpenReliant's: whether a drawn frame's copy of the objects may show the parts' copies
    /// (`main.Drawn`), from when the copy is taken (`hold`) until the frame is drawn (`letGo`).
    /// Meanwhile the copies of the parts put back are kept in `spent` rather than let go.
    held: bool = false,
    spent: std.ArrayList([]srapiext.Level) = .empty,

    /// What a part picked out had: its own levels and the copies it shows in their place, its
    /// light mask and its colour.
    const Saved = struct {
        levels: []const srapiext.Level,
        copies: []srapiext.Level,
        light_mask: u32,
        colour: [4]f32,
    };

    /// Whether the same object and component are already highlighted (`mission_frame`,
    /// `0x00493298`). **Fix:** selecting the same component on a replacement refreshes its parts.
    pub fn shows(subtarget: *const Subtarget, all: *const create.Objects, target: aigeneric.Target) bool {
        const picked = subtarget.target orelse return target.index == aigeneric.Target.none.index and target.isWhole();
        return subtarget.belongsTo(all, target.slot() orelse return false) and target.part() == picked.component;
    }

    /// Whether the highlighted parts still belong to the object in `index`.
    pub fn belongsTo(subtarget: *const Subtarget, all: *const create.Objects, index: u16) bool {
        const picked = subtarget.target orelse return false;
        return picked.object.resolve(all) == index;
    }

    /// `hud_subtarget` (`0x0048CC30`): restores the previous highlight, then highlights the
    /// selected component's parts if the player's target is valid.
    pub fn pick(subtarget: *Subtarget, all: *create.Objects) void {
        subtarget.clear(all);
        const entry = ai.playerControlEntry(all) orelse return;
        if (!ai.targetValid(all, entry.target.resolve(all), .{})) return;
        const component = entry.target.part() orelse return;
        const index = entry.target.slotIn(all) orelse return;
        subtarget.target = .{ .object = .of(all, index), .component = component };
        var walk = Assembly.of(all, index, component) orelse return;
        while (walk.next()) |part| {
            if (subtarget.count == max_parts) return;
            const copies = copyLevels(all.gpa, part.object.levels) catch return;
            subtarget.saved[subtarget.count] = .{
                .levels = part.object.levels,
                .copies = copies,
                .light_mask = part.object.light_mask,
                .colour = part.object.colour,
            };
            subtarget.count += 1;
            part.object.levels = copies;
            part.object.light_mask = light_mask;
            part.object.colour = red;
        }
    }

    /// `hud_subtarget_clear` (`0x0048CA80`): restores the highlighted parts in traversal order
    /// and frees their copied levels.
    ///
    /// **Fix:** the game restores parts through the saved slot even if another object has taken
    /// it. OpenReliant checks the original object's identity first. If it has gone, its parts
    /// have gone too, so only the copied levels need freeing.
    pub fn clear(subtarget: *Subtarget, all: *create.Objects) void {
        const picked = subtarget.target orelse return;
        defer {
            for (subtarget.saved[0..subtarget.count]) |saved| subtarget.spend(all.gpa, saved.copies);
            subtarget.count = 0;
            subtarget.target = null;
        }
        const index = picked.object.resolve(all) orelse return;
        var walk = Assembly.of(all, index, picked.component) orelse return;
        var at: usize = 0;
        while (walk.next()) |part| : (at += 1) {
            if (at == subtarget.count) return;
            const saved = subtarget.saved[at];
            part.object.levels = saved.levels;
            part.object.light_mask = saved.light_mask;
            part.object.colour = saved.colour;
        }
    }

    /// A drawn frame's copy of the objects may show the parts picked out now (`main.Drawn`), so
    /// the copies of the parts put back from now on are kept until the frame is drawn (`letGo`).
    pub fn hold(subtarget: *Subtarget) void {
        subtarget.held = true;
    }

    /// Lets go of the copies of the parts put back since `hold`, once the frame is drawn.
    pub fn letGo(subtarget: *Subtarget, gpa: Allocator) void {
        subtarget.held = false;
        for (subtarget.spent.items) |copies| freeLevels(gpa, copies);
        subtarget.spent.clearAndFree(gpa);
    }

    /// Lets go of `copies`, or keeps them in `spent` while a drawn frame may show them (`held`).
    /// If there is no memory to keep them, they leak rather than being freed while that frame may
    /// still show them.
    fn spend(subtarget: *Subtarget, gpa: Allocator, copies: []srapiext.Level) void {
        if (!subtarget.held) return freeLevels(gpa, copies);
        subtarget.spent.append(gpa, copies) catch {};
    }
};

/// The parts of a component's assembly: those of the model holding its part, as the game walks
/// its holder's children, that share the part's `link_id`, in the model's order. Parts taken out
/// of the model are passed over, as the game finds their nodes gone from the list.
const Assembly = struct {
    model: *objects.Model,
    link: u32,
    at: usize = 0,

    fn of(all: *create.Objects, index: u16, component: u16) ?Assembly {
        const slot = &all.slots[index];
        const part = slot.component(component) orelse return null;
        const model = if (slot.model) |*live| live.holding(part) orelse return null else return null;
        return .{ .model = model, .link = part.link_id };
    }

    fn next(walk: *Assembly) ?*objects.Model.Part {
        while (walk.at < walk.model.parts.len) {
            const part = &walk.model.parts[walk.at];
            walk.at += 1;
            if (!part.removed and part.link_id == walk.link) return part;
        }
        return null;
    }
};

/// Copies of `levels` (`levels_copy`, `0x004C4B70`, and `mesh_copy`, `0x004C4710`), each mesh's
/// surfaces drawn in one pass and lit (`0x0048CD97` on).
fn copyLevels(gpa: Allocator, levels: []const srapiext.Level) Allocator.Error![]srapiext.Level {
    const copies = try gpa.alloc(srapiext.Level, levels.len);
    var made: usize = 0;
    errdefer {
        freeMeshes(gpa, copies[0..made]);
        gpa.free(copies);
    }
    for (levels, copies) |level, *copy| {
        const mesh = try gpa.create(srapiext.Mesh);
        errdefer gpa.destroy(mesh);
        mesh.* = level.mesh.*;
        mesh.surfaces = try gpa.dupe(srapiext.Surface, level.mesh.surfaces);
        for (mesh.surfaces) |*surface| {
            surface.material.two_pass = false;
            surface.material.lit[0] = true;
        }
        copy.* = .{ .mesh = mesh, .until = level.until };
        made += 1;
    }
    return copies;
}

/// Lets the copies `copyLevels` made go, the meshes' surfaces with them.
fn freeLevels(gpa: Allocator, copies: []srapiext.Level) void {
    freeMeshes(gpa, copies);
    gpa.free(copies);
}

fn freeMeshes(gpa: Allocator, copies: []const srapiext.Level) void {
    for (copies) |copy| {
        gpa.free(copy.mesh.surfaces);
        gpa.destroy(copy.mesh);
    }
}

test Subtarget {
    const gpa = std.testing.allocator;
    const srmesh = @import("../../surrender/surrenderlib/srmesh.zig");
    var mission: gameobj.testing.Mission = undefined;
    try mission.init(gpa);
    defer mission.deinit();
    const all = mission.objects;
    const player = try mission.add(.of(.predator), @splat(0));
    try std.testing.expect(try aigeneric.push(mission.orders(), player, .player_control, .none));
    const index = try mission.add(.of(.kamov), .{ 0, 0, 5000 });
    const slot = mission.slot(index);
    slot.object.flags.targetable = true;
    slot.object.flags.components = true;

    // A model of three parts showing a mesh of two passes, unlit: the first two of the assembly
    // its one component, the first, belongs to, the third of another.
    var mesh = try srmesh.testing.square(gpa);
    defer mesh.deinit(gpa);
    mesh.surfaces[0].material.two_pass = true;
    mesh.surfaces[0].material.lit[0] = false;
    var three: objects.testing.Three = undefined;
    three.init(&mesh, &.{});
    var model: objects.Model = try .create(gpa, &three.source, &three.loaded, .{});
    defer model.deinit(gpa);
    const kept = slot.model;
    slot.model = model;
    defer slot.model = kept;
    const live = &slot.model.?;
    for (live.parts, [_]u32{ 1, 1, 2 }) |*part, link| part.link_id = link;
    slot.components[0] = &live.parts[0];
    slot.object.component_count = 1;
    const own = live.parts[0].object.levels;
    const own_mask = live.parts[0].object.light_mask;
    live.parts[0].object.colour = .{ 0.1, 0.2, 0.3, 0.4 };
    ai.playerControlEntry(all).?.target = .at(all, index, 0);

    // Picked out: the assembly's two parts show copies drawn in one lit pass, in red, out of the
    // first six lights' reach; the other part and the shared mesh stay as they were.
    var subtarget: Subtarget = .{};
    subtarget.pick(all);
    try std.testing.expect(subtarget.shows(all, .at(index, 0)));
    for (live.parts[0..2]) |part| {
        try std.testing.expect(part.object.levels.ptr != own.ptr);
        const material = part.object.levels[0].mesh.surfaces[0].material;
        try std.testing.expect(!material.two_pass and material.lit[0]);
        try std.testing.expectEqual(light_mask, part.object.light_mask);
        try std.testing.expectEqual(red, part.object.colour);
    }
    try std.testing.expectEqual(own.ptr, live.parts[2].object.levels.ptr);
    try std.testing.expect(mesh.surfaces[0].material.two_pass);

    // Put back: each part has its own again, and none is picked out.
    subtarget.clear(all);
    try std.testing.expectEqual(null, subtarget.target);
    for (live.parts) |part| {
        try std.testing.expectEqual(own.ptr, part.object.levels.ptr);
        try std.testing.expectEqual(own_mask, part.object.light_mask);
    }
    // Every part its own colour, all four of its values.
    try std.testing.expectEqual([4]f32{ 0.1, 0.2, 0.3, 0.4 }, live.parts[0].object.colour);
    try std.testing.expectEqual(@as([4]f32, @splat(0)), live.parts[1].object.colour);

    // A target that names no component picks nothing out.
    ai.playerControlEntry(all).?.target = .at(all, index, null);
    subtarget.pick(all);
    try std.testing.expectEqual(null, subtarget.target);

    // Where the object has left its slot since, putting back only lets the copies go.
    ai.playerControlEntry(all).?.target = .at(all, index, 0);
    subtarget.pick(all);
    all.reuses[index] +%= 1;
    subtarget.clear(all);
    try std.testing.expect(live.parts[0].object.levels.ptr != own.ptr);
    for (live.parts[0..2]) |*part| part.object.levels = own;

    // The old order no longer selects the object. Select it again for a new highlight.
    subtarget.pick(all);
    try std.testing.expectEqual(null, subtarget.target);
    ai.playerControlEntry(all).?.target = .at(all, index, 0);

    // While a drawn frame may show the copies, those of the parts put back are kept until the
    // frame is drawn.
    subtarget.pick(all);
    subtarget.hold();
    subtarget.clear(all);
    try std.testing.expectEqual(own.ptr, live.parts[0].object.levels.ptr);
    try std.testing.expectEqual(2, subtarget.spent.items.len);
    subtarget.letGo(gpa);
    try std.testing.expectEqual(0, subtarget.spent.items.len);
    try std.testing.expect(!subtarget.held);
}
