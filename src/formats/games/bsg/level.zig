//! Battlestar Galactica's objects' definitions (`levels/<model>.lvl`), in the text format of
//! `text.zig`: a `level` block of attributes, each a name, `const` or `amend`, a type and its
//! values, such as `attribute({Gun1}, const, vector,-163,-107.000008,116.999992,0)`. A ship's give
//! its flight model, its weapons, where its guns, engines and hardpoints are, and more
//! ([Battlestar Galactica](../../../../docs/games/battlestar-galactica.md#object-definitions)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const model = @import("model.zig");
const text = @import("text.zig");

pub const Type = enum { number, string, vector };

pub const Attribute = struct {
    name: []const u8,
    /// `const` or `amend`. **Unknown:** what `amend` changes.
    mode: []const u8,
    type: Type,
    values: []const []const u8,

    /// Its number, or null for another type.
    pub fn number(attribute: Attribute) ?f32 {
        if (attribute.type != .number or attribute.values.len < 1) return null;
        return std.fmt.parseFloat(f32, attribute.values[0]) catch null;
    }

    /// Its first three numbers, or null for another type. A vector has three, or four with a fourth
    /// of 0.
    pub fn vector(attribute: Attribute) ?[3]f32 {
        if (attribute.type != .vector or attribute.values.len < 3) return null;
        var values: [3]f32 = undefined;
        for (&values, attribute.values[0..3]) |*value, written| value.* = std.fmt.parseFloat(f32, written) catch return null;
        return values;
    }

    /// Its string, or null for another type.
    pub fn string(attribute: Attribute) ?[]const u8 {
        return if (attribute.type == .string and attribute.values.len > 0) attribute.values[0] else null;
    }
};

/// What a hardpoint is for, by its `_type` attribute.
pub const HardpointKind = enum {
    /// A missile of the ship's secondary weapon.
    secondary,
    /// A missile of its other secondary weapon.
    subsecondary,
    turret,
    player_turret,
    launch_tube,
    /// A model mounted on the object, such as a launch tube's door.
    subobject,
    leech_point,
    leech_beam,

    /// The kind of the `_type` attribute's string, such as `LAUNCHTUBE`, or null for another.
    pub fn of(name: []const u8) ?HardpointKind {
        inline for (comptime std.enums.values(HardpointKind)) |kind| {
            if (matches(@tagName(kind), name)) return kind;
        }
        return null;
    }

    /// Whether `tag`, its underscores left out, is `name` in capitals.
    fn matches(comptime tag: []const u8, name: []const u8) bool {
        var at: usize = 0;
        for (tag) |byte| {
            if (byte == '_') continue;
            if (at >= name.len or std.ascii.toUpper(byte) != name[at]) return false;
            at += 1;
        }
        return at == name.len;
    }
};

/// A hardpoint: the attributes whose names start with the same prefix, one of them `<prefix>_type`.
pub const Hardpoint = struct {
    /// The prefix, such as `Secondary00` or `Instancelaunchtube_main01`.
    prefix: []const u8,
    /// Its `_type` attribute's string, such as `SECONDARY`.
    type: []const u8,
    kind: ?HardpointKind,
    /// Its `_ID`.
    id: ?[]const u8,
    /// The model mounted on it (`_object`), such as `ltgaga01`, or null for none.
    object: ?[]const u8,
    /// Its place and turn on the object, from `_xform0` to `_xform3`, the last where it stands.
    matrix: model.Matrix,
    /// Every attribute of the hardpoint.
    attributes: []const Attribute,
};

/// What a point of the object is, by its attribute's name.
pub const PointKind = enum {
    /// `Gun<n>`: a gun's muzzle.
    gun,
    /// `Jet<n>`: an engine's glow, as large as `Jet<n>Size`.
    jet,
    /// `VapourTrail<n>`: where a vapour trail streams from.
    vapour_trail,
    /// `CockpitOffset`: where the pilot's eye is.
    cockpit,

    /// The attribute's name without its number.
    fn prefix(kind: PointKind) []const u8 {
        return switch (kind) {
            .gun => "Gun",
            .jet => "Jet",
            .vapour_trail => "VapourTrail",
            .cockpit => "CockpitOffset",
        };
    }
};

pub const Point = struct {
    /// Its attribute, such as `Gun1`.
    name: []const u8,
    kind: PointKind,
    position: [3]f32,
    /// A jet's size, or null.
    size: ?f32,
};

pub const Level = struct {
    /// The object's name, such as `SHV2VI00`.
    name: []const u8,
    attributes: []const Attribute,

    pub fn parse(arena: Allocator, bytes: []const u8) (text.Error || error{NotALevel})!Level {
        const top = try text.parse(arena, bytes);
        if (!std.mem.eql(u8, top.name, "level")) return error.NotALevel;
        var attributes: std.ArrayList(Attribute) = .empty;
        for (top.statements) |statement| {
            if (!std.mem.eql(u8, statement.key, "attribute")) continue;
            if (statement.args.len < 3) return error.NotALevel;
            try attributes.append(arena, .{
                .name = statement.args[0],
                .mode = statement.args[1],
                .type = std.meta.stringToEnum(Type, statement.args[2]) orelse return error.NotALevel,
                .values = statement.args[3..],
            });
        }
        const name = if (top.statement("name")) |line| line.arg(0) orelse "" else "";
        return .{ .name = name, .attributes = attributes.items };
    }

    /// The attribute called `name`, or null for none.
    pub fn find(level: Level, name: []const u8) ?Attribute {
        for (level.attributes) |attribute| {
            if (std.mem.eql(u8, attribute.name, name)) return attribute;
        }
        return null;
    }

    /// The object's hardpoints, in the order of their `_type` attributes.
    pub fn hardpoints(level: Level, arena: Allocator) Allocator.Error![]const Hardpoint {
        const type_suffix = "_type";
        var found: std.ArrayList(Hardpoint) = .empty;
        for (level.attributes) |typed| {
            if (!std.mem.endsWith(u8, typed.name, type_suffix)) continue;
            const kind_name = typed.string() orelse continue;
            const prefix = typed.name[0 .. typed.name.len - type_suffix.len];
            var attributes: std.ArrayList(Attribute) = .empty;
            var matrix = model.identity;
            for (level.attributes) |attribute| {
                const field = fieldOf(attribute.name, prefix) orelse continue;
                try attributes.append(arena, attribute);
                if (rowOf(field)) |row| {
                    const values = attribute.vector() orelse continue;
                    @memcpy(matrix[row * 4 ..][0..3], &values);
                }
            }
            try found.append(arena, .{
                .prefix = prefix,
                .type = kind_name,
                .kind = .of(kind_name),
                .id = if (level.find(try fieldName(arena, prefix, "ID"))) |id| id.string() else null,
                .object = if (level.find(try fieldName(arena, prefix, "object"))) |object| object.string() else null,
                .matrix = matrix,
                .attributes = attributes.items,
            });
        }
        return found.items;
    }

    /// The object's guns, jets, vapour trails and cockpit, in the attributes' order.
    pub fn points(level: Level, arena: Allocator) Allocator.Error![]const Point {
        var found: std.ArrayList(Point) = .empty;
        for (level.attributes) |attribute| {
            const position = attribute.vector() orelse continue;
            const kind = for (std.enums.values(PointKind)) |candidate| {
                if (isPoint(attribute.name, candidate)) break candidate;
            } else continue;
            const size = if (kind == .jet) if (level.find(try std.fmt.allocPrint(arena, "{s}Size", .{attribute.name}))) |sized| sized.number() else null else null;
            try found.append(arena, .{ .name = attribute.name, .kind = kind, .position = position, .size = size });
        }
        return found.items;
    }
};

/// The field of `name` after `prefix` and an underscore, or null where `name` isn't one of the
/// prefix's.
fn fieldOf(name: []const u8, prefix: []const u8) ?[]const u8 {
    if (name.len <= prefix.len + 1 or !std.mem.startsWith(u8, name, prefix) or name[prefix.len] != '_') return null;
    return name[prefix.len + 1 ..];
}

/// The attribute name of `prefix`'s field `name`.
fn fieldName(arena: Allocator, prefix: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}_{s}", .{ prefix, name });
}

/// The matrix row a hardpoint's field gives, `xform0` to `xform3`, or null for another field.
fn rowOf(name: []const u8) ?usize {
    const rows = [_][]const u8{ "xform0", "xform1", "xform2", "xform3" };
    for (rows, 0..) |row, at| {
        if (std.mem.eql(u8, name, row)) return at;
    }
    return null;
}

/// Whether the attribute `name` is a point of `kind`: its prefix, then a number where the kind
/// takes one.
fn isPoint(name: []const u8, kind: PointKind) bool {
    const prefix = kind.prefix();
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    if (kind == .cockpit) return rest.len == 0;
    if (rest.len == 0) return false;
    for (rest) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

test Level {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source =
        \\level
        \\{
        \\    name({SHV2VI00})
        \\    acount(12)
        \\    attribute({MaxSpeed}, const, number,300)
        \\    attribute({PrimaryWeaponType}, const, string,{COL_LASERMK2})
        \\    attribute({CockpitOffset}, const, vector,0,80,35,0)
        \\    attribute({Jet1}, const, vector,-152.050842,17.620859,-582.764648,0)
        \\    attribute({Jet1Size}, const, number,60.000004)
        \\    attribute({Gun1}, const, vector,224.517853,-149.116013,-95.767746,0)
        \\    attribute({Secondary00_type}, const, string,{SECONDARY})
        \\    attribute({Secondary00_ID}, const, string,{Secondary00})
        \\    attribute({Secondary00_xform0}, const, vector,1,0,0,0)
        \\    attribute({Secondary00_xform3}, const, vector,77.891663,-134.826523,-218.445786,0)
        \\    attribute({Instancelaunchtube_main01_type}, const, string,{SUBOBJECT})
        \\    attribute({Instancelaunchtube_main01_object}, const, string,{ltgaga01})
        \\}
        \\
    ;
    const level: Level = try .parse(arena, source);
    try std.testing.expectEqualStrings("SHV2VI00", level.name);
    try std.testing.expectEqual(300, level.find("MaxSpeed").?.number().?);
    try std.testing.expectEqualStrings("COL_LASERMK2", level.find("PrimaryWeaponType").?.string().?);

    const hardpoints = try level.hardpoints(arena);
    try std.testing.expectEqual(2, hardpoints.len);
    const missile = hardpoints[0];
    try std.testing.expectEqual(.secondary, missile.kind.?);
    try std.testing.expectEqualStrings("Secondary00", missile.id.?);
    try std.testing.expectEqual(77.891663, missile.matrix[12]);
    try std.testing.expectEqual(1, missile.matrix[15]);
    try std.testing.expectEqual(4, missile.attributes.len);
    try std.testing.expectEqual(.subobject, hardpoints[1].kind.?);
    try std.testing.expectEqualStrings("ltgaga01", hardpoints[1].object.?);

    const points = try level.points(arena);
    try std.testing.expectEqual(3, points.len);
    try std.testing.expectEqual(.cockpit, points[0].kind);
    try std.testing.expectEqual(.jet, points[1].kind);
    try std.testing.expectEqual(60.000004, points[1].size.?);
    try std.testing.expectEqual(.gun, points[2].kind);
}

test HardpointKind {
    try std.testing.expectEqual(.launch_tube, HardpointKind.of("LAUNCHTUBE").?);
    try std.testing.expectEqual(.player_turret, HardpointKind.of("PLAYERTURRET").?);
    try std.testing.expectEqual(.secondary, HardpointKind.of("SECONDARY").?);
    try std.testing.expectEqual(null, HardpointKind.of("SECONDARYX"));
    try std.testing.expectEqual(null, HardpointKind.of("FUELPOD"));
}
