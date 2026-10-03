//! The routines of the order table (`orders.zig`) and their names. OpenReliant names a routine
//! `order_` followed by its order's name, with `_init` or `_exit` added for those roles. The Ghidra
//! names (`ghidragen`) and the scripts' hooks (`engine.hooks`) both use these names.
//!
//! A routine shared by orders with different names, or used in different roles, gets no name here;
//! `ghidra/names/LANCER.EXE.tsv` names it by hand.

const std = @import("std");

const orders = @import("orders.zig");

/// A routine's role in its order.
pub const Role = enum {
    /// Runs before the order's first update.
    init,
    /// Runs each time the object runs the order.
    update,
    /// Runs when the order ends after it has started.
    exit,

    /// What the role adds to the routine's name.
    pub fn suffix(role: Role) []const u8 {
        return switch (role) {
            .init => "_init",
            .update => "",
            .exit => "_exit",
        };
    }
};

/// The address of `entry`'s routine for `role`, if it has one.
pub fn address(entry: orders.Info, role: Role) ?u32 {
    return switch (role) {
        inline else => |known| @field(entry, @tagName(known)),
    };
}

/// Whether `entry` names its routine for `role`: it is the first order to use the routine, and
/// every order that uses it has the same name and uses it in the same role.
pub fn names(entry: orders.Info, role: Role) bool {
    const own = address(entry, role) orelse return false;
    if (std.enums.tagName(orders.Order, entry.order) == null) return false;
    for (orders.table) |other| {
        for (std.enums.values(Role)) |other_role| {
            if (address(other, other_role) != own) continue;
            if (other_role != role or !std.mem.eql(u8, other.name, entry.name)) return false;
            if (@intFromEnum(other.order) < @intFromEnum(entry.order)) return false;
        }
    }
    return true;
}

/// The name of `entry`'s routine for `role`, such as `order_run_away` or `order_fly_init`, where
/// `entry` names it (`names`).
pub fn name(comptime entry: orders.Info, comptime role: Role) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(orders.table.len * orders.table.len * 40);
        if (!names(entry, role)) return null;
        return "order_" ++ @tagName(entry.order) ++ role.suffix();
    }
}

/// A named routine.
pub const Named = struct {
    name: []const u8,
    address: u32,
    role: Role,
    /// The first order that uses it, which names it.
    order: orders.Order,
};

/// Every routine with a name, in the order of the table and then of the roles.
pub const named: []const Named = list: {
    @setEvalBranchQuota(orders.table.len * orders.table.len * 200);
    var found: []const Named = &.{};
    for (orders.table) |entry| {
        for (std.enums.values(Role)) |role| {
            const routine = name(entry, role) orelse continue;
            found = found ++ .{Named{ .name = routine, .address = address(entry, role).?, .role = role, .order = entry.order }};
        }
    }
    break :list found;
};

/// The named routine at `routine`, the address of a routine in the order table, if it has a name.
pub fn find(routine: u32) ?Named {
    for (named) |each| {
        if (each.address == routine) return each;
    }
    return null;
}

test names {
    const fly_aimlessly = orders.info(.fly_aimlessly).?;
    try std.testing.expectEqualStrings("order_fly_aimlessly_init", comptime name(orders.info(.fly_aimlessly).?, .init).?);
    try std.testing.expect(names(fly_aimlessly, .update));
    // Orders 19 and 40 are both Jump In and share their routines, which take the first's name.
    try std.testing.expectEqualStrings("order_jump_in", comptime name(orders.info(.jump_in).?, .update).?);
    try std.testing.expect(!names(orders.info(.jump_in_40).?, .update));
    try std.testing.expectEqualStrings("order_jump_in", find(address(orders.info(.jump_in_40).?, .update).?).?.name);
    // The empty routine that orders of different names share gets no order's name.
    try std.testing.expectEqual(null, find(0x004983A0));
    try std.testing.expect(!names(orders.info(.do_nothing).?, .init));
}

test named {
    // Each name is given once.
    for (named, 0..) |each, at| {
        for (named[at + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, each.name, other.name));
    }
}
