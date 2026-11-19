//! Host-wide limits for connections accepted by the private transport probe.
const std = @import("std");
const Incoming = @This();

// Room for the three playing pilots and one connection negotiating admission.
const capacity = 4;
const HandshakeBudget = @import("handshake_budget");

connections: [capacity]?u32 = @splat(null),
budget: HandshakeBudget = .{},

pub fn contains(incoming: *const Incoming, conn: u32) bool {
    return std.mem.findScalar(?u32, &incoming.connections, conn) != null;
}

/// ICE signalling and the connecting callback can report the same handle.
pub fn reserve(incoming: *Incoming, conn: u32, now_us: i64) bool {
    if (incoming.contains(conn)) return true;
    const slot = std.mem.findScalar(?u32, &incoming.connections, null) orelse return false;
    if (!incoming.budget.take(now_us)) return false;
    incoming.connections[slot] = conn;
    return true;
}

pub fn release(incoming: *Incoming, conn: u32) void {
    const slot = std.mem.findScalar(?u32, &incoming.connections, conn) orelse return;
    incoming.connections[slot] = null;
}

test "pending and playing connections share capacity until their own handle closes" {
    var incoming: Incoming = .{};
    for (1..capacity + 1) |conn| try std.testing.expect(incoming.reserve(@intCast(conn), 0));
    const next = capacity + 1;
    const later = 2 * std.time.us_per_s;
    try std.testing.expect(!incoming.reserve(next, later));
    try std.testing.expect(incoming.reserve(2, later));
    incoming.release(next);
    try std.testing.expect(!incoming.reserve(next, later));
    incoming.release(2);
    try std.testing.expect(incoming.reserve(next, later));
    incoming.release(2);
    try std.testing.expect(incoming.contains(next));
    for (1..capacity + 1) |conn| try std.testing.expectEqual(conn != 2, incoming.contains(@intCast(conn)));
}

test "closing a connection frees capacity without refunding a handshake start" {
    var incoming: Incoming = .{};
    for (0..capacity) |_| {
        try std.testing.expect(incoming.reserve(1, 0));
        try std.testing.expect(incoming.reserve(1, 0));
        incoming.release(1);
    }
    try std.testing.expect(!incoming.reserve(2, std.time.us_per_s - 1));
    try std.testing.expect(incoming.reserve(2, std.time.us_per_s));
}
