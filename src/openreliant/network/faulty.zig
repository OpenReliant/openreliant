//! Clients that misbehave on purpose, for the headless session check: a host has to carry on for
//! its other pilots whatever one connection does (`scripts/check-direct-session.py`,
//! [#1432](https://github.com/OpenReliant/openreliant/issues/1432)).
const std = @import("std");
const Io = std.Io;
const Client = @import("client.zig");
const net = @import("transport.zig");
const wire = @import("wire.zig");

/// How often a misbehaving client looks at its connection.
const poll_interval: Io.Duration = .fromMilliseconds(10);

/// How many views `intrude` flies for before it sends what it may not: two seconds of them.
const views_before_intruding = 50;

/// A connection that never asks to join. It holds a place among the host's waiting connections
/// for `seconds`, then closes, as a client that stalls or leaves during admission does.
pub fn stall(io: Io, address: [:0]const u8, seconds: u32) !void {
    const conn = net.session_open(address, false);
    if (conn == 0) return error.ConnectFailed;
    defer net.session_close(conn);
    const end = Io.Clock.awake.now(io).toMicroseconds() + @as(i64, seconds) * std.time.us_per_s;
    while (Io.Clock.awake.now(io).toMicroseconds() < end) {
        net.session_poll();
        try io.sleep(poll_interval, .awake);
    }
}

/// A pilot who joins and flies, then sends a message only a host may send: the roster. The host
/// removes it for that, and it reports how its session ended.
pub fn intrude(client: *Client, io: Io) !void {
    if (client.call_sign == null) client.call_sign = wire.lobbyName("Intruder");
    var views: u32 = 0;
    while (true) {
        const event = client.poll(io) catch |err| {
            std.debug.print("removed {t} after {d} views\n", .{ err, views });
            return;
        };
        switch (event) {
            .admitted => std.debug.print("admitted {d} {d}\n", .{ client.joined.?.slot, client.joined.?.generation }),
            .snapshot => {
                views += 1;
                if (views == 1) try client.flightReady(io);
                if (views == views_before_intruding) {
                    std.debug.print("intruding\n", .{});
                    try net.send(client.conn, .{ .roster = client.roster });
                }
            },
            .finished, .closed => return error.NotRemoved,
            else => {},
        }
        try io.sleep(poll_interval, .awake);
    }
}
