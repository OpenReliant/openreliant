//! A headless direct-IP client. It sends controls and reports the host's positions.
const std = @import("std");
const Io = std.Io;
const wire = @import("wire.zig");
const net = @import("transport.zig");
const Client = @This();

pub const Controls = union(enum) { keyboard, fixed: wire.Steering };

const timeout = 10 * std.time.us_per_s;
const poll_ms = 4;
const input_interval_us = 40 * std.time.us_per_ms;

expected_host: []const u8,
conn: net.Connection = 0,
state: enum { connecting, authenticated, closed } = .connecting,

pub fn status(client: *Client, conn: net.Connection, event: net.Status, name: ?[]const u8) void {
    if (conn != client.conn or (event == .authenticated and (name == null or !std.mem.eql(u8, name.?, client.expected_host)))) {
        net.session_close(conn);
        if (conn == client.conn) client.state = .closed;
        return;
    }
    switch (event) {
        .incoming => net.session_close(conn),
        .authenticated => client.state = .authenticated,
        .closed => {
            net.session_close(conn);
            client.state = .closed;
        },
    }
}

pub fn run(client: *Client, io: Io, address: [:0]const u8, controls: Controls, leave_after: ?u32) !void {
    const conn = net.session_open(address, false);
    if (conn == 0) return error.ConnectFailed;
    client.conn = conn;
    defer if (client.state != .closed) net.session_close(conn);

    var deadline = Io.Clock.awake.now(io).toMicroseconds() + timeout;
    var steering: wire.Steering = switch (controls) {
        .keyboard => .straight,
        .fixed => |value| value,
    };
    if (controls == .keyboard) std.debug.print("A steers left, S flies straight, D steers right, and Q leaves. Press Enter to send a key.\n", .{});
    var sent_join = false;
    var joined: ?wire.Admission = null;
    var last_tick: u32 = 0;
    var views: u32 = 0;
    var sequence: u32 = 0;
    var next_input: i64 = 0;
    var leaving = false;
    var buffer: [wire.capacity]u8 = undefined;

    while (true) {
        net.session_poll();
        if (client.state == .closed) {
            if (leaving) return;
            return error.Disconnected;
        }
        const now = Io.Clock.awake.now(io).toMicroseconds();
        if (now >= deadline) return error.SessionTimedOut;
        if (client.state == .authenticated and !sent_join) {
            try net.send(conn, .{ .join = .local });
            sent_join = true;
        }
        if (joined != null and !leaving and now >= next_input) {
            if (controls == .keyboard) switch (net.session_key()) {
                'a', 'A' => steering = .left,
                's', 'S' => steering = .straight,
                'd', 'D' => steering = .right,
                'q', 'Q' => {
                    leaving = true;
                },
                else => {},
            };
            if (leaving) {
                try net.send(conn, .leave);
            } else {
                try net.send(conn, .{ .input = .{ .sequence = sequence, .steering = steering } });
                sequence +%= 1;
                next_input = now + input_interval_us;
            }
        }
        if (try net.receive(conn, &buffer)) |message| switch (message) {
            .joined => |admission| {
                if (!sent_join or joined != null) return error.UnexpectedAdmission;
                joined = admission;
                deadline = now + timeout;
                std.debug.print("admitted {d} {d}\n", .{ admission.slot, admission.generation });
            },
            .wrong_protocol => |required| {
                std.debug.print("server requires multiplayer protocol {d} (OpenReliant {s})\n", .{ required.protocol, required.release });
                return error.IncompatibleProtocol;
            },
            .view, .finished => |view| {
                if (joined) |admission| {
                    if (view.tick > last_tick and !leaving) {
                        const ship = view.ships[admission.slot] orelse return error.MissingShip;
                        if (ship.generation != admission.generation) return error.WrongShip;
                        deadline = now + timeout;
                        last_tick = view.tick;
                        views += 1;
                        std.debug.print("view {d}", .{view.tick});
                        for (view.ships) |entry| {
                            if (entry) |seen| {
                                std.debug.print(" {d} {d:.3} {d:.3}", .{ seen.generation, seen.position[0], seen.position[2] });
                            } else std.debug.print(" 0 0 0", .{});
                        }
                        std.debug.print("\n", .{});
                        if (message == .finished) {
                            try net.send(conn, .{ .received_final = view.tick });
                            leaving = true;
                            std.debug.print("finished {d}\n", .{view.tick});
                        } else if (leave_after == views) {
                            try net.send(conn, .leave);
                            leaving = true;
                        }
                    }
                }
            },
            else => return error.UnexpectedMessage,
        };
        try io.sleep(.fromMilliseconds(poll_ms), .awake);
    }
}
