//! The names mission source writes the game's values by: StarLancer's tables, named as the
//! scripting API names them ([Mission source](../../../../docs/formats/mission-source.md#records)),
//! so that mission source, mods' scripts and the editor share them. A value without a name, such
//! as a mod's ship type, stays a number. Another game on the engine brings tables of its own
//! ([#1017](https://github.com/OpenReliant/openreliant/issues/1017)).

const std = @import("std");

const dte = @import("../../dte.zig");
const commands = @import("../../../engine/game/executor/commands.zig");
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
};

/// The name of value `number` of `kind`, where the game names it.
pub fn name(kind: Kind, number: u32) ?[]const u8 {
    return switch (kind) {
        .ship_type => std.enums.tagName(gameobj.GameType, @fromBackingInt(number)),
        .pilot => std.enums.tagName(pilots.GamePilot, @fromBackingInt(std.math.cast(u8, number) orelse return null)),
        .order => std.enums.tagName(orders.Order, @fromBackingInt(std.math.cast(i16, number) orelse return null)),
        .condition => std.enums.tagName(dte.Condition, @fromBackingInt(std.math.cast(u8, number) orelse return null)),
        .head => std.enums.tagName(pilots.Head, @fromBackingInt(number)),
        .part => null,
    };
}

/// The name of one of the game's variables (`vm.GameVariable`), where it has one that isn't a
/// placeholder such as `_unknown_6`.
pub fn variable(number: u8) ?[]const u8 {
    const found = std.enums.tagName(vm.GameVariable, @fromBackingInt(number)) orelse return null;
    return if (found[0] == '_') null else found;
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
        refers_to_pilot => .pilot,
        refers_to_head => .head,
        else => null,
    };
}

/// The label of the parameter that takes an order, `SetAI`'s.
const ai_mode = "AI Mode";
/// What `commands.Extra.refers_to` says a named constant is: a pilot, and a head movement.
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

test variable {
    try std.testing.expectEqualStrings("backup_available", variable(vm.Variables.number("backup_available")).?);
    try std.testing.expectEqual(null, variable(vm.Variables.number("_unknown_6")));
}

test of {
    const executor = @import("../../../engine/game/executor.zig");
    const set_ai = commands.find(executor.commandIndex("SetAI")).?;
    try std.testing.expectEqual(.order, of(set_ai.params[1]).?);
    try std.testing.expectEqual(null, of(set_ai.params[2]));
    const timer = commands.find(executor.commandIndex("CreateTimer")).?;
    try std.testing.expectEqual(.part, of(timer.params[1]).?);
}
