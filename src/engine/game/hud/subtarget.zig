//! The player's subtarget picked out in red on its target's model (`hud_subtarget`, `0x0048CC30`,
//! and `hud_subtarget_clear`, `0x0048CA80`, from `hud.cpp`).
//!
//! Each part of the subtarget's assembly, the parts of its model that share its component's
//! `link_id`, up to `max_parts`, shows a copy of its levels whose surfaces are drawn in one pass and
//! lit, takes no light from the first six lights (`light_mask`), and has red for its own colour
//! (`red`), so the lighting draws it in red over its texture. The game copies the meshes because
//! every object of a type shares them; OpenReliant copies each level's mesh with its surfaces, the
//! only part it changes, and shares the rest. Putting the parts back lets the copies go.
//!
//! `camera.Camera.setView` picks the parts out as the view becomes 0 and puts them back for any
//! other; `mission_frame` picks them out in view 0 where the target or its component changed
//! (`main.keepPlayerTarget`); a component lost on the target puts them back (`objects.loseComponents`,
//! `node_draw`); and the next mission's start puts them back, before its objects are reset, which
//! the game does as the mission before ends (`mission_run`, at `0x00494260`).

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
/// **Fix:** the game saves each part's scene object to one place (`0x005656C0`), each over the
/// last, but puts back the colour and light mask of the part `n` it walks from `n` records past it,
/// so the first part gets the last one's and the others what lies beyond; and it puts back only
/// three of the colour's four values. OpenReliant keeps each part's own and puts all of it back.
pub const Subtarget = struct {
    /// `0x0057999C` and `0x0057999E`: the object and the component picked out; -1 for none.
    object: i16 = -1,
    component: i16 = -1,
    /// The object's slot's reuse count as its parts were picked out (`create.Objects.reuses`).
    reuse: u32 = 0,
    saved: [max_parts]Saved = undefined,
    count: usize = 0,

    /// What a part picked out had: its own levels and the copies it shows in their place, its
    /// light mask and its colour.
    const Saved = struct {
        levels: []const srapiext.Level,
        copies: []srapiext.Level,
        light_mask: u32,
        colour: [4]f32,
    };

    /// Whether it shows `target`'s parts: the same object and component (`mission_frame`,
    /// `0x00493298`).
    pub fn shows(subtarget: *const Subtarget, target: aigeneric.Target) bool {
        return target.index == subtarget.object and target.component == subtarget.component;
    }

    /// `hud_subtarget` (`0x0048CC30`): puts back what is picked out, then, where the player's
    /// target is valid and names a component, picks out its parts.
    pub fn pick(subtarget: *Subtarget, all: *create.Objects) void {
        subtarget.clear(all);
        const entry = ai.playerControlEntry(all) orelse return;
        if (!ai.targetValid(all, entry.target, .{})) return;
        const component = entry.target.part() orelse return;
        const index = entry.target.slot() orelse return;
        subtarget.object = entry.target.index;
        subtarget.component = entry.target.component;
        subtarget.reuse = all.reuses[index];
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

    /// `hud_subtarget_clear` (`0x0048CA80`): puts back the parts picked out, in the order it walks
    /// them, and lets their copies go.
    ///
    /// **Fix:** the game walks the slot whatever object now holds it. Where the object has gone
    /// from its slot since, OpenReliant only lets the copies go, the parts having gone with it.
    pub fn clear(subtarget: *Subtarget, all: *create.Objects) void {
        if (subtarget.object < 0) return;
        defer {
            for (subtarget.saved[0..subtarget.count]) |saved| freeLevels(all.gpa, saved.copies);
            subtarget.count = 0;
            subtarget.object = -1;
        }
        const index: u16 = @intCast(subtarget.object);
        if (all.reuses[index] != subtarget.reuse) return;
        var walk = Assembly.of(all, index, @intCast(subtarget.component)) orelse return;
        var at: usize = 0;
        while (walk.next()) |part| : (at += 1) {
            if (at == subtarget.count) return;
            const saved = subtarget.saved[at];
            part.object.levels = saved.levels;
            part.object.light_mask = saved.light_mask;
            part.object.colour = saved.colour;
        }
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
    ai.playerControlEntry(all).?.target = .at(index, 0);

    // Picked out: the assembly's two parts show copies drawn in one lit pass, in red, out of the
    // first six lights' reach; the other part and the shared mesh stay as they were.
    var subtarget: Subtarget = .{};
    subtarget.pick(all);
    try std.testing.expect(subtarget.shows(.at(index, 0)));
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
    try std.testing.expectEqual(-1, subtarget.object);
    for (live.parts) |part| {
        try std.testing.expectEqual(own.ptr, part.object.levels.ptr);
        try std.testing.expectEqual(own_mask, part.object.light_mask);
    }
    // Every part its own colour, all four of its values.
    try std.testing.expectEqual([4]f32{ 0.1, 0.2, 0.3, 0.4 }, live.parts[0].object.colour);
    try std.testing.expectEqual(@as([4]f32, @splat(0)), live.parts[1].object.colour);

    // A target that names no component picks nothing out.
    ai.playerControlEntry(all).?.target = .at(index, null);
    subtarget.pick(all);
    try std.testing.expectEqual(-1, subtarget.object);

    // Where the object has left its slot since, putting back only lets the copies go.
    ai.playerControlEntry(all).?.target = .at(index, 0);
    subtarget.pick(all);
    all.reuses[index] +%= 1;
    subtarget.clear(all);
    try std.testing.expect(live.parts[0].object.levels.ptr != own.ptr);
    for (live.parts[0..2]) |*part| part.object.levels = own;
}
