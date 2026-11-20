//! The dedicated host waits for enough pilots, then gives new arrivals time to join.
const std = @import("std");
const LaunchWait = @This();

pub const minimum_players = 2;

minimum: u8 = minimum_players,
delay_us: i64 = 0,
deadline: ?i64 = null,

pub fn reset(wait: *LaunchWait) void {
    wait.deadline = null;
}

pub fn ready(wait: *LaunchWait, players: usize, now: i64) bool {
    if (players < wait.minimum) {
        wait.reset();
        return false;
    }
    const deadline = wait.deadline orelse now +| wait.delay_us;
    wait.deadline = deadline;
    return now >= deadline;
}

test "a new admission restarts the wait even if the room is full" {
    var wait: LaunchWait = .{ .minimum = 2, .delay_us = 30 };
    try std.testing.expect(!wait.ready(1, 0));
    try std.testing.expect(!wait.ready(2, 10));
    try std.testing.expect(!wait.ready(2, 35));
    wait.reset();
    try std.testing.expect(!wait.ready(3, 36));
    try std.testing.expect(!wait.ready(3, 65));
    try std.testing.expect(wait.ready(3, 66));
    try std.testing.expect(!wait.ready(1, 67));
    try std.testing.expect(!wait.ready(2, 81));
    try std.testing.expect(wait.ready(2, 111));
}
