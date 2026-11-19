//! The direct-IP training session, available before the game starts the display.
const std = @import("std");
const net = @import("transport.zig");
const wire = @import("wire.zig");
const Host = @import("server.zig");
const Client = @import("client.zig");

const default_round_ticks = 250;
const max_certificate = 4096;
const max_root_key = 512;
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
    if (args.len == 0) return error.InvalidSessionArguments;
    const role = std.meta.stringToEnum(Role, args[0]) orelse return error.InvalidSessionRole;
    const min_args: usize = if (role == .host) 4 else 6;
    if (args.len < min_args or args.len > min_args + 1) return error.InvalidSessionArguments;
    const limit = if (args.len > min_args) try number(args[min_args]) else null;
    const controls: Client.Controls = if (role == .host or std.mem.eql(u8, args[5], "keyboard"))
        .keyboard
    else
        .{ .fixed = std.meta.stringToEnum(wire.Steering, args[5]) orelse return error.InvalidSteering };
    const address = args[1];
    {
        const root = try std.Io.Dir.cwd().readFileAlloc(io, args[2], gpa, .limited(max_root_key));
        defer gpa.free(root);
        const cert = try std.Io.Dir.cwd().readFileAlloc(io, args[3], gpa, .limited(max_certificate));
        defer {
            std.crypto.secureZero(u8, cert);
            gpa.free(cert);
        }
        if (!net.session_init(root.ptr, root.len, cert.ptr, @intCast(cert.len), wire.capacity)) return error.InvalidTransportIdentity;
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
            var client: Client = .{ .expected_host = args[4] };
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
