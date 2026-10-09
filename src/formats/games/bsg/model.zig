//! Battlestar Galactica's models (`models/<model>/<model>.mdl`): the parts of a model, as Maya
//! exported them, in the text format of `text.zig`. Each part is a `model` block inside the
//! model's own, and names its parent, its place in its parent's frame, the point it turns about,
//! and the mesh it draws (`mesh.zig`). Most parts' names hold their level of detail, `c1` to `c5`,
//! 1 the finest, such as `c1_viper2` or `sh_bs_basestar01_c4_basestar_top`; the pieces a ship
//! breaks into, such as `xd_debris01`, have none.

const std = @import("std");
const Allocator = std.mem.Allocator;

const text = @import("text.zig");

/// A 4 by 4 matrix, row by row, as Direct3D keeps one: a point is a row multiplied by it, and the
/// last row is where the frame's origin stands.
pub const Matrix = [16]f32;

pub const identity: Matrix = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

/// The coarsest level of detail.
pub const coarsest_level = 5;

pub const Part = struct {
    name: []const u8,
    /// The name of the part it hangs from, or null for none.
    parent: ?[]const u8,
    /// Its place and turn in its parent's frame.
    matrix: Matrix,
    /// The point it turns about, in its own frame.
    pivot: ?[3]f32,
    /// Its mesh as the model names it, such as `SHV2VI00c1_viper2Shape.msh`, or empty for none.
    mesh: []const u8,

    /// Its level of detail, from 1 to `coarsest_level`, by the first part of its name between
    /// underscores that is `c` and the level; null for a name without one.
    pub fn level(part: Part) ?u8 {
        var words = std.mem.splitScalar(u8, part.name, '_');
        while (words.next()) |word| {
            if (word.len != 2 or word[0] != 'c') continue;
            const digit = std.fmt.charToDigit(word[1], 10) catch continue;
            if (digit >= 1 and digit <= coarsest_level) return digit;
        }
        return null;
    }

    /// The archive's name of its mesh in the folder of `model`: the mesh's name in lowercase, with
    /// `.bmsh` for `.msh`, such as `models/shv2vi00/shv2vi00c1_viper2shape.bmsh`.
    pub fn meshPath(part: Part, arena: Allocator, model: []const u8) Allocator.Error![]const u8 {
        const stem = if (std.mem.endsWith(u8, part.mesh, source_extension)) part.mesh[0 .. part.mesh.len - source_extension.len] else part.mesh;
        const path = try std.fmt.allocPrint(arena, "models/{s}/{s}.bmsh", .{ model, stem });
        return std.ascii.lowerString(path, path);
    }
};

/// The extension of a mesh as a model names it.
const source_extension = ".msh";

pub const Model = struct {
    parts: []const Part,
    /// The Maya scene the model was exported from, such as
    /// `Z:/BattleStar/SHIPS/sh_v2_viper01/models/sh_v2_viper01.mb`, or null where it isn't named.
    scene: ?[]const u8,

    pub fn parse(arena: Allocator, bytes: []const u8) (text.Error || error{NotAModel})!Model {
        const top = try text.parse(arena, bytes);
        if (!std.mem.eql(u8, top.name, "model")) return error.NotAModel;
        const parts = try arena.alloc(Part, top.blocks.len);
        for (parts, top.blocks) |*part, block| {
            if (!std.mem.eql(u8, block.name, "model")) return error.NotAModel;
            const parent = if (block.statement("parent")) |line| line.arg(0) orelse "" else "";
            part.* = .{
                .name = (block.statement("name") orelse return error.NotAModel).arg(0) orelse return error.NotAModel,
                .parent = if (parent.len > 0) parent else null,
                .matrix = if (block.statement("matrix")) |line| line.numbers(16, 0) orelse return error.NotAModel else identity,
                .pivot = if (block.statement("pivot")) |line| line.numbers(3, 0) orelse return error.NotAModel else null,
                .mesh = if (block.statement("meshname")) |line| line.arg(0) orelse "" else "",
            };
        }
        return .{ .parts = parts, .scene = scene(top) };
    }

    /// The parts at level `wanted`, or at the level nearest it that has any, finer first, and the
    /// parts without a level.
    pub fn partsAt(model: Model, arena: Allocator, wanted: u8) Allocator.Error![]const Part {
        var best: ?u8 = null;
        for (model.parts) |part| {
            const at = part.level() orelse continue;
            if (best == null or distance(at, wanted) < distance(best.?, wanted) or
                (distance(at, wanted) == distance(best.?, wanted) and at < best.?)) best = at;
        }
        const chosen = best orelse return model.parts;
        var kept: std.ArrayList(Part) = .empty;
        for (model.parts) |part| {
            const at = part.level() orelse chosen;
            if (at == chosen) try kept.append(arena, part);
        }
        return kept.items;
    }
};

fn distance(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// The Maya scene that `top`'s first comment names.
fn scene(top: text.Block) ?[]const u8 {
    const prefix = "Maya scene ";
    for (top.comments) |line| {
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    }
    return null;
}

test Model {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\model
        \\{
        \\// Maya scene Z:/BattleStar/SHIPS/sh_cb_turret/models/turret.mb
        \\    model
        \\    {
        \\        name({c1_pivot})
        \\        parent({})
        \\        matrix(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1)
        \\        meshname({SHCBCB10c1_pivotShape.msh})
        \\    }
        \\    model
        \\    {
        \\        name({c1_barrels})
        \\        parent({c1_pivot})
        \\        matrix(1,0,0,0,0,1,0,0,0,0,1,0,0,23.319533,145.704759,1)
        \\        pivot(0,0,10,1)
        \\        meshname({SHCBCB10c1_barrelsShape.msh})
        \\    }
        \\    model
        \\    {
        \\        name({c3_pivot})
        \\        parent({})
        \\        meshname({SHCBCB10c3_pivotShape.msh})
        \\    }
        \\}
        \\
    ;
    const model: Model = try .parse(arena, source);
    try std.testing.expectEqualStrings("Z:/BattleStar/SHIPS/sh_cb_turret/models/turret.mb", model.scene.?);
    try std.testing.expectEqual(3, model.parts.len);
    const barrels = model.parts[1];
    try std.testing.expectEqualStrings("c1_pivot", barrels.parent.?);
    try std.testing.expectEqual(145.704759, barrels.matrix[14]);
    try std.testing.expectEqual([3]f32{ 0, 0, 10 }, barrels.pivot.?);
    try std.testing.expectEqual(null, model.parts[0].parent);
    try std.testing.expectEqualStrings("models/shcbcb10/shcbcb10c1_barrelsshape.bmsh", try barrels.meshPath(arena, "shcbcb10"));
    try std.testing.expectEqual(identity, model.parts[2].matrix);

    try std.testing.expectEqual(4, (Part{ .name = "sh_bs_basestar01_c4_basestar_top", .parent = null, .matrix = identity, .pivot = null, .mesh = "" }).level());
    try std.testing.expectEqual(null, (Part{ .name = "xd_debris01", .parent = null, .matrix = identity, .pivot = null, .mesh = "" }).level());
    try std.testing.expectEqual(null, (Part{ .name = "c9_extra", .parent = null, .matrix = identity, .pivot = null, .mesh = "" }).level());

    // The finest level has two parts; level 2 has none, so level 1's are the nearest.
    try std.testing.expectEqual(2, (try model.partsAt(arena, 1)).len);
    try std.testing.expectEqual(2, (try model.partsAt(arena, 2)).len);
    try std.testing.expectEqualStrings("c3_pivot", (try model.partsAt(arena, 4))[0].name);
}
