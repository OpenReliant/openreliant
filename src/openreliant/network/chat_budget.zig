//! Fixed-size token buckets for chat fan-out. The session bucket also covers reconnects.
const std = @import("std");
const Budget = @This();

const Limit = struct { burst: i64, refill_us: i64 };
pub const pilot: Limit = .{ .burst = 2, .refill_us = 2 * std.time.us_per_s };
pub const session: Limit = .{ .burst = 4, .refill_us = 750 * std.time.us_per_ms };

// Each line costs one refill interval. A full bucket starts with room for a short burst.
ready_at: ?i64 = null,

pub fn take(budget: *Budget, now: i64, limit: Limit) bool {
    const next = @max(now, budget.ready_at orelse now) + limit.refill_us;
    if (next - now > limit.burst * limit.refill_us) return false;
    budget.ready_at = next;
    return true;
}

test "spam does not delay a refill and a fresh pilot does not reset the session budget" {
    var peer: Budget = .{};
    var host: Budget = .{};
    for (0..session.burst) |_| try std.testing.expect(host.take(0, session));
    try std.testing.expect(peer.take(0, pilot));
    try std.testing.expect(!host.take(0, session));
    try std.testing.expect(peer.take(0, pilot));
    try std.testing.expect(!peer.take(pilot.refill_us - 1, pilot));
    try std.testing.expect(host.take(session.refill_us, session));
    try std.testing.expect(peer.take(pilot.refill_us, pilot));
}
