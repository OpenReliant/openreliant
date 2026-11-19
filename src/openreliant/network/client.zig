//! The direct-IP pilot used by the connection screen and the headless client.
const std = @import("std");
const Io = std.Io;
const flight = @import("openreliant").engine.input.flight;
const Presses = @import("flight_input.zig").Presses;
const wire = @import("wire.zig");
const net = @import("transport.zig");
const Client = @This();

pub const Controls = union(enum) { keyboard, fixed: Steering };

/// Repeatable controls for the terminal client and loopback workloads.
pub const Steering = enum(i8) {
    left = -1,
    straight = 0,
    right = 1,

    fn command(steering: Steering) flight.Command {
        const axis = @as(f32, @floatFromInt(@backingInt(steering))) * 0.1;
        return .{ .steering = .{ .axes = .{ axis, 0, 0 } }, .throttle = .{ .axis = 1 } };
    }
};

const timeout = 10 * std.time.us_per_s;
const poll_ms = 4;

expected_host: ?[]const u8,
conn: net.Connection = 0,
state: enum { connecting, connected, unverified, closed, lost } = .connecting,

deadline: i64 = 0,
sent_join: bool = false,
joined: ?wire.Admission = null,
call_sign: ?wire.CallSign = null,
fighter: wire.Fighter = .predator,
latest: ?wire.Snapshot = null,
roster: wire.Roster = .{},
sequence: u32 = 0,
next_input: i64 = 0,
leaving: bool = false,
flight_command: flight.Command = .{},
fire_primary: bool = false,
weapons: ?wire.ordnance.Order = null,
sent_aim: ?wire.ordnance.Aim = null,
projectiles: [wire.ordnance.Page.pages]?wire.ordnance.Page = @splat(null),
presses: Presses = .{},

pub fn status(client: *Client, conn: net.Connection, event: net.Status, name: ?[]const u8) void {
    if (conn != client.conn) {
        net.session_close(conn);
        return;
    }
    const accepted = switch (event) {
        .authenticated => if (client.expected_host) |expected|
            name != null and std.mem.eql(u8, name.?, expected)
        else
            true,
        .unverified => client.expected_host == null,
        .incoming, .closed, .lost => false,
    };
    if (accepted) {
        client.state = .connected;
    } else {
        net.session_close(conn);
        client.state = switch (event) {
            .closed => .closed,
            .lost => .lost,
            else => .unverified,
        };
    }
}

pub fn open(client: *Client, io: Io, address: [:0]const u8) !void {
    client.conn = net.session_open(address, false);
    if (client.conn == 0) return error.ConnectFailed;
    client.deadline = Io.Clock.awake.now(io).toMicroseconds() + timeout;
}

pub fn local(client: *Client, io: Io, client_end: net.Connection) void {
    client.* = .{
        .expected_host = null,
        .conn = client_end,
        .state = .connected,
        .deadline = Io.Clock.awake.now(io).toMicroseconds() + timeout,
    };
}

pub fn close(client: *Client) void {
    if (client.conn != 0 and (client.state == .connecting or client.state == .connected)) net.session_close(client.conn);
    client.conn = 0;
}

pub fn leave(client: *Client, io: Io) !void {
    if (client.leaving) return;
    try net.send(client.conn, .leave);
    client.deadline = Io.Clock.awake.now(io).toMicroseconds() + timeout;
    client.leaving = true;
}

pub const Event = union(enum) {
    idle,
    admitted,
    lobby: wire.Scenario,
    beacon_notice: wire.BeaconNotice,
    combat: wire.Combat,
    projectiles,
    snapshot,
    finished,
    closed,
};

pub fn setFlight(client: *Client, command: flight.Command) void {
    client.flight_command = command;
    client.presses.take(&client.flight_command);
}

pub fn setWeapons(client: *Client, order: wire.ordnance.Order) void {
    if (client.weapons) |*pending| pending.merge(order) else client.weapons = order;
}

pub fn selectShip(client: *Client, ship: wire.Fighter) !void {
    if (client.latest != null or client.fighter == ship) return;
    if (client.sent_join) try net.send(client.conn, .{ .pick_ship = ship });
    client.fighter = ship;
}

/// Advance the connection without waiting for a packet or a simulation tick.
pub fn poll(client: *Client, io: Io) !Event {
    net.session_poll();
    if (client.state == .unverified) return error.UnverifiedServer;
    if (client.state == .closed) return if (client.leaving) .closed else error.Disconnected;
    if (client.state == .lost) return if (client.leaving) .closed else error.TransportLost;
    const now = Io.Clock.awake.now(io).toMicroseconds();
    // The first pilot may wait as long as needed for a second to join.
    if ((client.joined == null or client.latest != null or client.leaving) and now >= client.deadline) return error.SessionTimedOut;
    if (client.state == .connected and !client.sent_join) {
        try net.send(client.conn, .{ .join = .local });
        try net.send(client.conn, .{ .pick_ship = client.fighter });
        client.sent_join = true;
    }
    if (client.joined != null and !client.leaving and now >= client.next_input) {
        try net.send(client.conn, .{ .input = .{
            .sequence = client.sequence,
            .command = client.flight_command,
            .fire_for = if (client.fire_primary and client.latest != null) client.latest.?.ships[client.joined.?.slot].?.reuse else null,
        } });
        if (client.presses.any()) {
            try net.send(client.conn, .{ .flight_press = client.presses });
            client.presses = .{};
        }
        if (client.weapons) |*pending| {
            if (pending.presses.any() or !std.meta.eql(client.sent_aim, @as(?wire.ordnance.Aim, pending.aim))) {
                try net.send(client.conn, .{ .weapon_order = pending.* });
                client.sent_aim = pending.aim;
                pending.presses = .{};
            }
        }
        client.sequence +%= 1;
        client.next_input = now + wire.step_us;
    }
    var buffer: [wire.capacity]u8 = undefined;
    const message = try net.receive(client.conn, &buffer) orelse return .idle;
    switch (message) {
        .joined => |admission| {
            if (!client.sent_join or client.joined != null) return error.UnexpectedAdmission;
            client.joined = admission;
            if (client.call_sign) |name| try net.send(client.conn, .{ .call_sign = name });
            client.deadline = now + timeout;
            return .admitted;
        },
        .wrong_protocol => |required| {
            std.debug.print("server requires multiplayer protocol {d} (OpenReliant {s})\n", .{ required.protocol, required.release });
            return error.IncompatibleProtocol;
        },
        .roster => |roster| {
            const admission = client.joined orelse return error.UnexpectedMessage;
            if (client.leaving) return .idle;
            if (roster.pilots[admission.slot] == null or roster.pilots[admission.slot].?.generation != admission.generation)
                return error.UnexpectedMessage;
            client.roster = roster;
            if (client.latest == null) if (roster.lobby) |scenario| return .{ .lobby = scenario };
            return .idle;
        },
        .beacon_notice => |notice| return if (client.joined != null and !client.leaving) .{ .beacon_notice = notice } else error.UnexpectedMessage,
        .combat => |effects| return if (client.latest != null and !client.leaving) .{ .combat = effects } else .idle,
        .projectiles => |page| {
            const view = client.latest orelse return .idle;
            if (client.leaving or view.scenario == null or page.tick > view.tick +| wire.ordnance.Page.max_age) return .idle;
            const entry = &client.projectiles[page.index()];
            if (entry.* == null or page.tick > entry.*.?.tick) entry.* = page;
            return .projectiles;
        },
        .view, .finished => |view| {
            const admission = client.joined orelse {
                // Unreliable flight updates can arrive before the reliable admission.
                return if (message == .view) .idle else error.UnexpectedMessage;
            };
            if (client.leaving or view.tick <= if (client.latest) |last| last.tick else @as(u32, 0)) return .idle;
            const ship = view.ships[admission.slot] orelse return error.MissingShip;
            if (ship.generation != admission.generation) return error.WrongShip;
            if (client.latest) |last| if (last.scenario != view.scenario) return error.UnexpectedMessage;
            client.latest = view;
            client.deadline = now + timeout;
            if (message == .finished) {
                try net.send(client.conn, .{ .received_final = view.tick });
                client.leaving = true;
                return .finished;
            }
            return .snapshot;
        },
        else => return error.UnexpectedMessage,
    }
}

pub fn run(client: *Client, io: Io, address: [:0]const u8, controls: Controls, leave_after: ?u32) !void {
    try client.open(io, address);
    defer client.close();
    try client.drive(io, controls, leave_after);
}

pub fn drive(client: *Client, io: Io, controls: Controls, leave_after: ?u32) !void {
    var steering: Steering = switch (controls) {
        .keyboard => .straight,
        .fixed => |value| value,
    };
    if (controls == .keyboard) std.debug.print("A steers left, S flies straight, D steers right, and Q leaves. Press Enter to send a key.\n", .{});
    var views: u32 = 0;
    var objectives: wire.Objectives = .none;
    while (true) {
        if (controls == .keyboard and client.joined != null and !client.leaving) switch (net.session_key()) {
            'a', 'A' => steering = .left,
            's', 'S' => steering = .straight,
            'd', 'D' => steering = .right,
            'q', 'Q' => try client.leave(io),
            else => {},
        };
        client.setFlight(steering.command());
        const event = try client.poll(io);
        switch (event) {
            .idle, .lobby, .combat, .projectiles => {},
            .beacon_notice => |notice| std.debug.print("notice {s} {d}\n", .{ @tagName(notice.event.kind), notice.event.pilot.slot }),
            .closed => return,
            .admitted => {
                const admission = client.joined.?;
                std.debug.print("admitted {d} {d}\n", .{ admission.slot, admission.generation });
            },
            .snapshot, .finished => {
                const view = client.latest.?;
                views += 1;
                std.debug.print("view {d}", .{view.tick});
                for (view.ships) |entry| {
                    if (entry) |seen| {
                        std.debug.print(" {d} {d:.3} {d:.3}", .{ seen.generation, seen.position[0], seen.position[2] });
                    } else std.debug.print(" 0 0 0", .{});
                }
                std.debug.print("\n", .{});
                if (!std.meta.eql(objectives, view.objectives)) {
                    objectives = view.objectives;
                    showObjectives(view);
                }
                if (event == .finished) {
                    std.debug.print("finished {d}\n", .{view.tick});
                } else if (leave_after == views) try client.leave(io);
            },
        }
        try io.sleep(.fromMilliseconds(poll_ms), .awake);
    }
}

fn showObjectives(view: wire.Snapshot) void {
    if (view.objectives != .six_beacons) return;
    for (view.objectives.six_beacons, 0..) |beacon, index| switch (beacon) {
        .carried => |slot| std.debug.print("beacon {d} {d} carried {d} {d}\n", .{ view.tick, index, slot, view.ships[slot].?.generation }),
        .loose => |p| std.debug.print("beacon {d} {d} loose {d:.3} {d:.3} {d:.3}\n", .{ view.tick, index, p[0], p[1], p[2] }),
    };
}
