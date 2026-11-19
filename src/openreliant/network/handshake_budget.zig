//! A rolling host-wide limit on new connection handshakes.
const std = @import("std");
const Budget = @This();

pub const Limit = enum(usize) {
    standard = 4,
    automatic_identity = 8,
};

limit: Limit = .standard,
starts: [@backingInt(Limit.automatic_identity)]?i64 = @splat(null),
oldest: usize = 0,

pub fn take(budget: *Budget, now_us: i64) bool {
    if (budget.starts[budget.oldest]) |started| {
        if (now_us -| started < std.time.us_per_s) return false;
    }
    budget.starts[budget.oldest] = now_us;
    budget.oldest = (budget.oldest + 1) % @backingInt(budget.limit);
    return true;
}

test "handshake starts expire individually" {
    for (std.enums.values(Limit)) |limit| {
        var budget: Budget = .{ .limit = limit };
        const starts_per_second = @backingInt(limit);
        const spacing: i64 = @intCast(std.time.us_per_s / starts_per_second);
        for (0..starts_per_second) |i| try std.testing.expect(budget.take(@as(i64, @intCast(i)) * spacing));
        try std.testing.expect(!budget.take(std.time.us_per_s - 1));
        try std.testing.expect(budget.take(std.time.us_per_s));
        try std.testing.expect(!budget.take(std.time.us_per_s + spacing - 1));
        try std.testing.expect(budget.take(std.time.us_per_s + spacing));
    }
}
