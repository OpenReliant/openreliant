//! Whether two missions are the same mission
//! ([The round trip](../../../docs/formats/mission-source.md#the-round-trip)): what the game reads of
//! them is equal. Records are compared field by field, their names as text, an object by the record
//! the game takes it for, a formation's point by its place among the formation's, and the code of
//! parts and triggers as statements. The string pool's layout, the objects' numbers, the sections'
//! layout and the bytes the game doesn't read may differ.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dte = @import("../dte.zig");
const decompile = @import("decompile.zig");
const statements = @import("statements.zig");
const bind = @import("../../engine/game/mission/bind.zig");

pub const Error = dte.Error || decompile.Error;

/// The first way `b` differs from `a`, as a message, or null where they are the same mission.
pub fn difference(arena: Allocator, a: dte.Mission, b: dte.Mission) Error!?[]const u8 {
    var comparison: Comparison = .{
        .arena = arena,
        .a = try .init(arena, a),
        .b = try .init(arena, b),
    };
    return comparison.run();
}

/// A mission and what comparing it needs worked out once.
const Side = struct {
    mission: dte.Mission,
    /// The record each object stands for, by its object ID.
    objects: []const ?bind.Mission.Record,
    /// The object whose slice holds each trigger, where one does.
    owners: []const ?u16,
    /// Each formation's points, by their indices, as the game finds them.
    points: []const []const u16,

    fn init(arena: Allocator, mission: dte.Mission) Error!Side {
        const points = try arena.alloc([]const u16, (try mission.formations()).len);
        for (points, 0..) |*list, index| list.* = try mission.pointsOf(arena, index);
        return .{
            .mission = mission,
            .objects = try bind.resolveObjects(arena, mission),
            .owners = try mission.triggerObjects(arena),
            .points = points,
        };
    }

    /// What object `id` stands for: its record, or the ID itself where it stands for none.
    fn object(side: Side, id: u32) Object {
        if (id < side.objects.len) if (side.objects[id]) |record| return .{ .record = record };
        return .{ .id = id };
    }

    /// What formation point `point` is: its place among its formation's points, or the index
    /// itself where it is none of its formation's.
    fn point(side: Side, index: u16) Point {
        const all = side.mission.formationPoints() catch &.{};
        if (index < all.len and all[index].formation < side.points.len) {
            const formation = all[index].formation;
            if (std.mem.findScalar(u16, side.points[formation], index)) |place| return .{ .place = .{ formation, place } };
        }
        return .{ .index = index };
    }

    /// The statements of the block `start` bytes into the script.
    fn code(side: Side, arena: Allocator, start: usize) Error![]const statements.Statement {
        return decompile.block(arena, try side.mission.script(), start);
    }
};

const Object = union(enum) {
    record: bind.Mission.Record,
    id: u32,
};

const Point = union(enum) {
    place: struct { u16, usize },
    index: u16,
};

const Comparison = struct {
    arena: Allocator,
    a: Side,
    b: Side,

    fn say(c: *Comparison, comptime message: []const u8, args: anytype) Error!?[]const u8 {
        return try c.arena.print(message, args);
    }

    /// Objects compared by the records they stand for, for `statements.same`.
    fn objects(c: *const Comparison) Objects {
        return .{ .a = &c.a, .b = &c.b };
    }

    const Objects = struct {
        a: *const Side,
        b: *const Side,

        pub fn same(sides: Objects, x: u8, y: u8) bool {
            return std.meta.eql(sides.a.object(x), sides.b.object(y));
        }
    };

    fn sameName(c: *Comparison, a: u16, b: u16) bool {
        return std.mem.eql(u8, c.a.mission.name(a), c.b.mission.name(b));
    }

    fn run(c: *Comparison) Error!?[]const u8 {
        const a = c.a.mission;
        const b = c.b.mission;
        if (!sameText(a.openReliantName(), b.openReliantName())) return c.say("the mission's name differs", .{});
        inline for (.{
            .{ "global", dte.Mission.globals, Comparison.global },
            .{ "flight group", dte.Mission.flightGroups, Comparison.flightGroup },
            .{ "ship", dte.Mission.ships, Comparison.ship },
            .{ "squad", dte.Mission.squads, Comparison.squad },
            .{ "formation", dte.Mission.formations, Comparison.formation },
            .{ "curve", dte.Mission.curves, Comparison.curve },
            .{ "part", dte.Mission.parts, Comparison.part },
            .{ "trigger", dte.Mission.triggers, Comparison.trigger },
        }) |kind| {
            const left = try kind[1](a);
            const right = try kind[1](b);
            if (left.len != right.len) return c.say("one mission has {d} " ++ kind[0] ++ "s, and the other {d}", .{ left.len, right.len });
            for (left, right, 0..) |x, y, index| {
                if (try kind[2](c, x, y, index)) |field| return c.say(kind[0] ++ " {d} differs in its {s}", .{ index, field });
            }
        }
        if ((try a.records(dte.Part, .parts_b)).len != (try b.records(dte.Part, .parts_b)).len) return c.say("the second script's parts differ", .{});
        return null;
    }

    fn global(c: *Comparison, x: dte.Global, y: dte.Global, _: usize) Error!?[]const u8 {
        if (!c.sameName(x.name, y.name)) return "name";
        if (x.value != y.value) return "value";
        return null;
    }

    fn flightGroup(c: *Comparison, x: dte.FlightGroup, y: dte.FlightGroup, _: usize) Error!?[]const u8 {
        if (!c.sameName(x.name, y.name)) return "name";
        if (x.wing != y.wing) return "wing";
        if (x.formation.index != y.formation.index) return "formation";
        return null;
    }

    fn ship(c: *Comparison, x: dte.Ship, y: dte.Ship, _: usize) Error!?[]const u8 {
        if (!c.sameName(x.name, y.name)) return "name";
        if (x.kind != y.kind) return "type";
        if (x.flight_group != y.flight_group) return "flight group";
        if (x.pilot != y.pilot) return "pilot";
        if (!sameFloats(x.position, y.position)) return "position";
        if (x.yaw != y.yaw or x.pitch != y.pitch or x.roll != y.roll) return "angles";
        if (x.launch_gate != y.launch_gate or (x.launchGate() != null and x.launch_from != y.launch_from)) return "launch";
        if ((x.formationPoint() == null) != (y.formationPoint() == null)) return "formation point";
        if (x.formationPoint()) |point| if (!std.meta.eql(c.a.point(point), c.b.point(y.formation_point))) return "formation point";
        if (x.tier != y.tier) return "tier";
        if (x.kind == dte.Ship.point_kind) {
            if (!std.meta.eql(x.markedCurve(), y.markedCurve())) return "marked curve";
            if (x.markedCurve() != null and !sameFloat(x.marker_at, y.marker_at)) return "place on its curve";
        }
        return null;
    }

    fn squad(c: *Comparison, x: dte.Squad, y: dte.Squad, index: usize) Error!?[]const u8 {
        if (!c.sameName(x.name, y.name)) return "name";
        const left = try c.a.mission.membersOf(index);
        const right = try c.b.mission.membersOf(index);
        if (left.len != right.len) return "members";
        for (left, right) |p, q| {
            if (p.component != q.component or !std.meta.eql(c.a.object(p.object_id), c.b.object(q.object_id))) return "members";
        }
        return null;
    }

    fn formation(c: *Comparison, x: dte.Formation, y: dte.Formation, index: usize) Error!?[]const u8 {
        if (!c.sameName(x.name, y.name)) return "name";
        const left = c.a.points[index];
        const right = c.b.points[index];
        if (left.len != right.len) return "points";
        const left_all = try c.a.mission.formationPoints();
        const right_all = try c.b.mission.formationPoints();
        for (left, right) |p, q| if (!sameFloats(left_all[p].offset, right_all[q].offset)) return "points";
        return null;
    }

    fn curve(_: *Comparison, x: dte.Curve, y: dte.Curve, _: usize) Error!?[]const u8 {
        if (x.start.index != y.start.index or x.end.index != y.end.index) return "ships";
        if (x.leaving_handle.index != y.leaving_handle.index or x.arriving_handle.index != y.arriving_handle.index) return "handles";
        if (!sameFloats(x.from, y.from) or !sameFloats(x.to, y.to)) return "ends";
        if (!sameFloats(x.leaving, y.leaving) or !sameFloats(x.arriving, y.arriving)) return "tangents";
        return null;
    }

    fn part(c: *Comparison, x: dte.Part, y: dte.Part, _: usize) Error!?[]const u8 {
        if (!c.sameName(x.name, y.name)) return "name";
        if (x.flags.start != y.flags.start) return "start";
        if (x.isEmpty() != y.isEmpty()) return "code";
        if (x.isEmpty()) return null;
        if (x.arguments != y.arguments) return "arguments";
        if (!statements.same(try c.a.code(c.arena, x.start()), try c.b.code(c.arena, y.start()), c.objects())) return "code";
        return null;
    }

    fn trigger(c: *Comparison, x: dte.Trigger, y: dte.Trigger, index: usize) Error!?[]const u8 {
        if (x.condition != y.condition) return "condition";
        if (x.repeat != y.repeat) return "repeats";
        if (x.repeat == .counted and (x.repeat_count != y.repeat_count or x.repeat_counter != y.repeat_counter)) return "repeats";
        if (x.qualifier != y.qualifier) return "component";
        if ((x.deferred != 0) != (y.deferred != 0)) return "deferred";
        if (x.condition.descriptor()) |condition| {
            for (condition.values, 0..) |value, slot| {
                const what: []const u8 = switch (x.condition.keeps(slot)) {
                    .nothing => continue,
                    .check => "values it checks",
                    .distance => "distance",
                };
                if (slot >= x.operands.len) continue;
                if (!std.meta.eql(dte.Operand.read(x.operands[slot], value.kinds), dte.Operand.read(y.operands[slot], value.kinds))) return what;
            }
        }
        const left_owner = c.a.owners[index];
        const right_owner = c.b.owners[index];
        if ((left_owner == null) != (right_owner == null)) return "subject";
        // A trigger no object holds never fires, so what it would run doesn't count.
        const owner = left_owner orelse return null;
        if (!std.meta.eql(c.a.object(owner), c.b.object(right_owner.?))) return "subject";
        if ((x.block() == null) != (y.block() == null)) return "code";
        const start = x.block() orelse return null;
        if (!statements.same(try c.a.code(c.arena, start), try c.b.code(c.arena, y.block().?), c.objects())) return "code";
        return null;
    }
};

fn sameText(a: ?[]const u8, b: ?[]const u8) bool {
    const left = a orelse return b == null;
    return std.mem.eql(u8, left, b orelse return false);
}

fn sameFloat(a: f32, b: f32) bool {
    return a == b and std.math.signbit(a) == std.math.signbit(b) or std.math.isNan(a) and std.math.isNan(b);
}

fn sameFloats(a: [3]f32, b: [3]f32) bool {
    for (a, b) |x, y| if (!sameFloat(x, y)) return false;
    return true;
}

test difference {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var destroyed: dte.Trigger = .blank;
    destroyed.condition = .destroyed;
    const first = try testMission(arena, .{ .ship = 0, .group = 1 }, 90, destroyed);
    // The same records, with their objects numbered the other way round, are the same mission.
    try std.testing.expectEqual(null, try difference(arena, first, try testMission(arena, .{ .ship = 1, .group = 0 }, 90, destroyed)));
    // A ship turned another way is not.
    const turned = try testMission(arena, .{ .ship = 0, .group = 1 }, 45, destroyed);
    try std.testing.expectEqualStrings("ship 0 differs in its angles", (try difference(arena, first, turned)).?);
    // Nor is a Proximity trigger that looks another distance, which the matcher doesn't check.
    var near: dte.Trigger = .blank;
    near.condition = .proximity_general;
    near.operands[dte.Trigger.proximity_distance] = 3;
    var far = near;
    far.operands[dte.Trigger.proximity_distance] = 5;
    const looking = try testMission(arena, .{ .ship = 0, .group = 1 }, 90, near);
    try std.testing.expectEqualStrings("trigger 0 differs in its distance", (try difference(arena, looking, try testMission(arena, .{ .ship = 0, .group = 1 }, 90, far))).?);
}

/// A mission of a ship and its flight group, with `trigger` on the group. The ship and the group
/// take the object IDs `ids` gives, and the ship is turned `yaw` degrees.
fn testMission(arena: Allocator, ids: struct { ship: u16, group: u16 }, yaw: i16, trigger: dte.Trigger) !dte.Mission {
    const gameobj = @import("../../engine/game/gameobj.zig");
    var ship = dte.testing.ship(ids.ship, 0, @intCast(@backingInt(gameobj.GameType.grendel)));
    ship.yaw = yaw;
    var group = dte.testing.flightGroup(ids.group, .player);
    group.name = "Player\x00".len;
    var objects: [2]dte.Object = undefined;
    objects[ids.ship] = dte.testing.object(.ship, dte.Object.no_triggers, 0);
    objects[ids.group] = dte.testing.object(.flight_group, 0, 1);
    const pool = "Player\x00(FG)Alpha\x00";
    var sections: dte.write.Sections = @splat(.{});
    dte.write.set(&sections, .strings, pool.len, pool);
    dte.write.set(&sections, .ships, 1, std.mem.asBytes(&ship));
    dte.write.set(&sections, .flight_groups, 1, std.mem.asBytes(&group));
    dte.write.set(&sections, .triggers, 1, std.mem.asBytes(&trigger));
    dte.write.set(&sections, .objects, objects.len, std.mem.sliceAsBytes(&objects));
    return .parse(try dte.write.write(arena, &sections, .{}));
}
