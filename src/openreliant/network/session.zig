//! The direct-IP training session, available before the game starts the display.
const std = @import("std");
const net = @import("transport.zig");
const wire = @import("wire.zig");
const Host = @import("server.zig");
const Client = @import("client.zig");

const usage =
    \\usage: openreliant session host <ip:port> <certificate> [round-ticks]
    \\       openreliant session join <ip:port> <certificate> <host-identity> <keyboard|left|straight|right> [views-before-leaving]
    \\
;
const default_round_ticks = 250;
const max_certificate = 4096;
const Role = enum { host, join };
var current: ?union(enum) { host: *Host, client: *Client } = null;

export fn session_status(conn: net.Connection, event: net.Status, identity: ?[*:0]const u8) void {
    const name = if (identity) |value| std.mem.span(value) else null;
    switch (current orelse return) {
        .host => |host| host.status(conn, event, name),
        .client => |client| client.status(conn, event, name),
    }
}

fn number(value: []const u8) !u32 {
    const parsed = try std.fmt.parseInt(u32, value, 10);
    return if (parsed != 0) parsed else error.InvalidCount;
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    const role = std.meta.stringToEnum(Role, args[0]) orelse return error.InvalidSessionRole;
    const min_args: usize = if (role == .host) 3 else 5;
    if (args.len < min_args or args.len > min_args + 1) return error.InvalidSessionArguments;
    const limit = if (args.len > min_args) try number(args[min_args]) else null;
    const address = args[1];
    {
        const cert = try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(max_certificate));
        defer {
            std.crypto.secureZero(u8, cert);
            gpa.free(cert);
        }
        if (!net.session_init(cert.ptr, @intCast(cert.len), wire.capacity)) return error.InvalidTransportCertificate;
    }
    defer net.session_deinit();

    switch (role) {
        .host => {
            const host = try gpa.create(Host);
            defer gpa.destroy(host);
            host.* = .{ .io = io, .arena = undefined };
            try host.arena.init(gpa);
            defer host.arena.deinit();
            current = .{ .host = host };
            defer current = null;
            try host.run(address, limit orelse default_round_ticks);
        },
        .join => {
            const controls: Client.Controls = if (std.mem.eql(u8, args[4], "keyboard"))
                .keyboard
            else
                .{ .fixed = std.meta.stringToEnum(wire.Steering, args[4]) orelse return error.InvalidSteering };
            var client: Client = .{ .expected_host = args[3] };
            current = .{ .client = &client };
            defer current = null;
            try client.run(io, address, controls, limit);
        },
    }
    return 0;
}

test {
    std.testing.refAllDecls(wire);
}
