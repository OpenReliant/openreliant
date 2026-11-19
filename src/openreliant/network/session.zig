//! Run a direct-IP host or terminal client before the game starts the display.
const std = @import("std");
const net = @import("transport.zig");
const wire = @import("wire.zig");
const Arena = @import("arena.zig");
const Host = @import("server.zig");
const Client = @import("client.zig");

const default_round_ticks = 250;
const max_certificate = 4096;
const max_root_key = 512;
const Role = enum { host, join };
var current: ?union(enum) { host: *Host, client: *Client } = null;

comptime {
    if (@import("network_options").enabled) @export(&status, .{ .name = "session_status" });
}

fn status(conn: net.Connection, event: net.Status, identity: ?[*:0]const u8) callconv(.c) void {
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

pub const Identity = struct {
    root_path: []const u8,
    certificate_path: []const u8,

    fn load(identity: Identity, io: std.Io, gpa: std.mem.Allocator, directory: std.Io.Dir) !void {
        const root = try directory.readFileAlloc(io, identity.root_path, gpa, .limited(max_root_key));
        defer gpa.free(root);
        const certificate = try directory.readFileAlloc(io, identity.certificate_path, gpa, .limited(max_certificate));
        defer {
            std.crypto.secureZero(u8, certificate);
            gpa.free(certificate);
        }
        if (!net.session_init(root.ptr, root.len, certificate.ptr, @intCast(certificate.len), wire.capacity))
            return error.InvalidTransportIdentity;
    }
};

pub const HostOptions = struct {
    address: [:0]const u8,
    mode: Arena.Mode = .training,
    players: u8 = wire.slots,
    ticks: ?u32,
};

pub fn serve(io: std.Io, gpa: std.mem.Allocator, directory: std.Io.Dir, identity: Identity, options: HostOptions) !void {
    try identity.load(io, gpa, directory);
    defer net.session_deinit();
    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    host.* = .{ .io = io, .arena = undefined, .player_limit = options.players };
    try host.arena.init(gpa, options.mode);
    defer host.arena.deinit();
    current = .{ .host = host };
    defer current = null;
    try host.run(options.address, options.ticks);
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
    const identity: Identity = .{ .root_path = args[2], .certificate_path = args[3] };

    switch (role) {
        .host => try serve(io, gpa, .cwd(), identity, .{ .address = args[1], .ticks = limit orelse default_round_ticks }),
        .join => {
            try identity.load(io, gpa, .cwd());
            defer net.session_deinit();
            var client: Client = .{ .expected_host = args[4] };
            current = .{ .client = &client };
            defer current = null;
            try client.run(io, args[1], controls, limit);
        },
    }
    return 0;
}

test {
    std.testing.refAllDecls(wire);
}
