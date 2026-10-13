//! The names mission source writes the game's values by: StarLancer's tables, named as the
//! scripting API names them ([Mission source](../../../../docs/formats/mission-source.md#records)),
//! so that mission source, mods' scripts and the editor share them. A value without a name, such
//! as a mod's ship type, stays a number. Another game on the engine brings tables of its own
//! ([#1017](https://github.com/OpenReliant/openreliant/issues/1017)).

const std = @import("std");

const dte = @import("../../dte.zig");
const commands = @import("../../../engine/game/executor/commands.zig");
const environfx = @import("../../../engine/game/environfx.zig");
const gameobj = @import("../../../engine/game/gameobj.zig");
const orders = @import("../../../engine/game/ai/orders.zig");
const pilots = @import("../../../engine/game/pilots.zig");
const vm = @import("../../../engine/vm.zig");

/// A kind of value the game names.
pub const Kind = enum {
    ship_type,
    pilot,
    order,
    condition,
    /// How a pilot's face moves as it says a line (`pilots.Head`).
    head,
    /// A part, which mission source names by the part's own name.
    part,
    /// An effect of a mission's space, which `SetEnvironmentFX` turns on and off
    /// (`environfx.Effect`).
    environment_effect,

    /// What a value of the kind is called in a message.
    pub fn noun(kind: Kind) []const u8 {
        return switch (kind) {
            .ship_type => "ship type",
            .head => "head movement",
            .environment_effect => "environment effect",
            else => @tagName(kind),
        };
    }

    /// Whether mods add values of the kind under names of their own, which scripts write as text,
    /// as they do ship types and pilots. A mission writes those values as numbers, but the type in
    /// the definitions takes text too, as the scripting API's type of the same name does, so that
    /// both definitions files can be loaded together.
    pub fn hasModNames(kind: Kind) bool {
        return switch (kind) {
            .ship_type, .pilot => true,
            else => false,
        };
    }

    /// The name of the type of the kind's values in the definitions of mission source
    /// (`definitions.zig`), the scripting API's name where it has the type too.
    pub fn typeName(kind: Kind) []const u8 {
        return switch (kind) {
            .ship_type => "ShipType",
            .pilot => "PilotNumber",
            .order => "Order",
            .condition => "Condition",
            .head => "HeadMovement",
            .environment_effect => "EnvironmentEffect",
            .part => "Part",
        };
    }
};

/// The game's table of the values of `kind`, an enum of their names; none for a part, which the
/// source names by the part's own name.
pub fn Names(comptime kind: Kind) ?type {
    return switch (kind) {
        .ship_type => gameobj.GameType,
        .pilot => pilots.GamePilot,
        .order => orders.Order,
        .condition => dte.Condition,
        .head => pilots.Head,
        .environment_effect => environfx.Effect,
        .part => null,
    };
}

/// Whether `tag` is a placeholder for a value not understood yet, such as `_unused_2`. Mission
/// source writes such a value as a number, never by the placeholder's name.
pub fn isPlaceholder(tag: []const u8) bool {
    return tag.len > 0 and tag[0] == '_';
}

/// The name of value `number` of `kind`, where the game names it.
pub fn name(kind: Kind, number: u32) ?[]const u8 {
    return switch (kind) {
        inline else => |known| if (comptime Names(known)) |Enum| {
            const Backing = @typeInfo(Enum).@"enum".tag_type;
            const found = std.enums.tagName(Enum, @fromBackingInt(std.math.cast(Backing, number) orelse return null)) orelse return null;
            return if (isPlaceholder(found)) null else found;
        } else null,
    };
}

/// The value of `kind` that the game names `text`, the inverse of `name`.
pub fn value(kind: Kind, text: []const u8) ?u32 {
    if (isPlaceholder(text)) return null;
    return switch (kind) {
        inline else => |known| if (comptime Names(known)) |Enum| {
            return std.math.cast(u32, @backingInt(std.meta.stringToEnum(Enum, text) orelse return null));
        } else null,
    };
}

/// The name of one of the game's variables (`vm.GameVariable`), where it has one that isn't a
/// placeholder (`isPlaceholder`).
pub fn variable(number: u8) ?[]const u8 {
    const found = std.enums.tagName(vm.GameVariable, @fromBackingInt(number)) orelse return null;
    return if (isPlaceholder(found)) null else found;
}

/// The number of the game's variable named `text`, the inverse of `variable`.
pub fn variableNumber(text: []const u8) ?u8 {
    if (isPlaceholder(text)) return null;
    return @backingInt(std.meta.stringToEnum(vm.GameVariable, text) orelse return null);
}

/// The kind of value a command's parameter takes, where it takes a named one: a part, a condition,
/// or a named constant the parameter says what of (`commands.Extra.refers_to`), and the order
/// `SetAI` takes.
pub fn of(param: commands.Param) ?Kind {
    if (param.kinds.part) return .part;
    if (param.kinds.condition) return .condition;
    if (!param.kinds.constant) return null;
    if (std.mem.eql(u8, param.label, ai_mode)) return .order;
    return switch (param.extra.refers_to) {
        refers_to_environment_effect => .environment_effect,
        refers_to_pilot => .pilot,
        refers_to_head => .head,
        else => null,
    };
}

/// The label of the parameter that takes an order, `SetAI`'s.
const ai_mode = "AI Mode";
/// What `commands.Extra.refers_to` says a named constant is: an environment effect, a pilot, and a
/// head movement.
const refers_to_environment_effect = 1;
const refers_to_pilot = 3;
const refers_to_head = 4;

test name {
    try std.testing.expectEqualStrings("grendel", name(.ship_type, @backingInt(gameobj.GameType.grendel)).?);
    try std.testing.expectEqualStrings("find_new_target", name(.order, @intCast(@backingInt(orders.Order.find_new_target))).?);
    try std.testing.expectEqualStrings("shot_at", name(.condition, @backingInt(dte.Condition.shot_at)).?);
    try std.testing.expectEqualStrings("laughing", name(.head, @backingInt(pilots.Head.laughing)).?);
    // A value the game doesn't name, such as a mod's ship type, has none.
    try std.testing.expectEqual(null, name(.ship_type, 100_000));
    try std.testing.expectEqual(null, name(.order, 70_000));
}

test value {
    // Each name reads back as the value it names.
    for ([_]struct { Kind, u32 }{
        .{ .ship_type, @backingInt(gameobj.GameType.grendel) },
        .{ .order, @intCast(@backingInt(orders.Order.find_new_target)) },
        .{ .condition, @backingInt(dte.Condition.shot_at) },
        .{ .head, @backingInt(pilots.Head.laughing) },
        .{ .pilot, @backingInt(pilots.GamePilot.bandit_tigers_leader) },
        .{ .environment_effect, @backingInt(environfx.Effect.ice_field) },
    }) |pair| try std.testing.expectEqual(pair[1], value(pair[0], name(pair[0], pair[1]).?).?);
    try std.testing.expectEqual(null, value(.ship_type, "rubber_duck"));
    try std.testing.expectEqual(null, value(.part, "start"));
}

test isPlaceholder {
    try std.testing.expect(isPlaceholder("_unused_2"));
    try std.testing.expect(!isPlaceholder("grendel"));
    try std.testing.expect(!isPlaceholder(""));
}

test variable {
    try std.testing.expectEqualStrings("backup_available", variable(vm.Variables.number("backup_available")).?);
    try std.testing.expectEqual(null, variable(vm.Variables.number("_unused_2")));
}

test variableNumber {
    try std.testing.expectEqual(vm.Variables.number("backup_available"), variableNumber("backup_available").?);
    // A placeholder's number is written as one, never by its name.
    try std.testing.expectEqual(null, variableNumber("_unused_2"));
    try std.testing.expectEqual(null, variableNumber("no_such_variable"));
}

test of {
    const executor = @import("../../../engine/game/executor.zig");
    const set_ai = commands.find(executor.commandIndex("SetAI")).?;
    try std.testing.expectEqual(.order, of(set_ai.params[1]).?);
    try std.testing.expectEqual(null, of(set_ai.params[2]));
    const timer = commands.find(executor.commandIndex("CreateTimer")).?;
    try std.testing.expectEqual(.part, of(timer.params[1]).?);
    const effect = commands.find(executor.commandIndex("SetEnvironmentFX")).?;
    try std.testing.expectEqual(.environment_effect, of(effect.params[0]).?);
}
