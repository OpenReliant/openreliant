//! Run a direct-IP host or terminal client before the game starts the display.
const std = @import("std");
const net = @import("transport.zig");
const wire = @import("wire.zig");
const Arena = @import("arena.zig");
const credential = @import("identity.zig");
const Host = @import("server.zig");
const Client = @import("client.zig");

pub const default_port = 27020;
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
        if (certificate.len == 0) return error.InvalidTransportIdentity;
        try initTransport(root, certificate);
    }
};

pub const HostOptions = struct {
    address: [:0]const u8,
    mode: Arena.Mode = .training,
    players: u8 = wire.slots,
    ticks: ?u32,
    invite_address: ?std.Io.net.IpAddress = null,
};

fn initTransport(root: ?[]const u8, certificate: ?[]const u8) !void {
    if (!net.session_init(if (root) |r| r.ptr else null, if (root) |r| r.len else 0, if (certificate) |cert| cert.ptr else null, @intCast(if (certificate) |cert| cert.len else 0), wire.capacity))
        return error.InvalidTransportIdentity;
}

pub fn serve(io: std.Io, gpa: std.mem.Allocator, directory: std.Io.Dir, identity: ?Identity, options: HostOptions) !void {
    var server: ?credential.Server = null;
    defer if (server) |*automatic| automatic.wipe();
    if (identity) |managed| {
        try managed.load(io, gpa, directory);
    } else {
        server = try .load(io, directory);
        const automatic = &server.?;
        var certificate = try automatic.hostCertificate(io);
        defer certificate.wipe();
        try initTransport(&credential.openSshKey(automatic.issuer.public_key), certificate.slice());
    }
    defer net.session_deinit();
    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    host.* = .{
        .io = io,
        .arena = undefined,
        .player_limit = options.players,
        .signer = if (server) |*automatic| automatic else null,
    };
    try host.arena.init(gpa, options.mode);
    defer host.arena.deinit();
    current = .{ .host = host };
    defer current = null;
    const invite: ?credential.Invite = if (server) |*automatic|
        if (options.invite_address) |address| .{ .address = address, .key = automatic.issuer.public_key } else null
    else
        null;
    try host.run(options.address, options.ticks, invite);
}

fn controls(value: []const u8) !Client.Controls {
    if (std.mem.eql(u8, value, "keyboard")) return .keyboard;
    return .{ .fixed = std.meta.stringToEnum(wire.Steering, value) orelse return error.InvalidSteering };
}

fn directAddress(text: []const u8) !std.Io.net.IpAddress {
    const IpAddress = std.Io.net.IpAddress;
    // An IPv6 address with an explicit port must be in brackets.
    const address = IpAddress.parse(text, default_port) catch literal: {
        var address = try IpAddress.parseLiteral(text);
        if (std.mem.endsWith(u8, text, "]")) address.setPort(default_port);
        break :literal address;
    };
    if (address.getPort() == 0 or !credential.Invite.hasAddress(address)) return error.InvalidAddress;
    return address;
}

fn join(io: std.Io, args: []const [:0]const u8) !void {
    const invite = if (std.mem.startsWith(u8, args[0], credential.Invite.prefix))
        try credential.Invite.parse(args[0])
    else
        null;
    const endpoint = if (invite) |value| value.address else try directAddress(args[0]);
    var buffer: [credential.Invite.max_address]u8 = undefined;
    const address = try std.fmt.bufPrintSentinel(&buffer, "{f}", .{endpoint}, 0);
    const steering = if (args.len > 1) try controls(args[1]) else .keyboard;
    const limit = if (args.len > 2) try number(args[2]) else null;
    try initTransport(if (invite) |value| &credential.openSshKey(value.key) else null, null);
    defer net.session_deinit();
    try play(io, address, if (invite != null) credential.host_name else null, steering, limit);
}

fn play(io: std.Io, address: [:0]const u8, expected_host: ?[]const u8, steering: Client.Controls, limit: ?u32) !void {
    var client: Client = .{ .expected_host = expected_host };
    current = .{ .client = &client };
    defer current = null;
    try client.run(io, address, steering, limit);
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0) return error.InvalidSessionArguments;
    const role = std.meta.stringToEnum(Role, args[0]) orelse return error.InvalidSessionRole;
    if (role == .join and args.len >= 2 and args.len <= 4) {
        try join(io, args[1..]);
        return 0;
    }
    const min_args: usize = if (role == .host) 4 else 6;
    if (args.len < min_args or args.len > min_args + 1) return error.InvalidSessionArguments;
    const limit = if (args.len > min_args) try number(args[min_args]) else null;
    const identity: Identity = .{ .root_path = args[2], .certificate_path = args[3] };

    switch (role) {
        .host => try serve(io, gpa, .cwd(), identity, .{ .address = args[1], .ticks = limit orelse default_round_ticks }),
        .join => {
            try identity.load(io, gpa, .cwd());
            defer net.session_deinit();
            try play(io, args[1], args[4], try controls(args[5]), limit);
        },
    }
    return 0;
}

test "direct addresses accept an optional port" {
    for ([_][]const u8{ "127.0.0.1", "::1", "[::1]" }) |text|
        try std.testing.expectEqual(default_port, (try directAddress(text)).getPort());
    for ([_][]const u8{ "127.0.0.1:27200", "[::1]:27200" }) |text|
        try std.testing.expectEqual(27200, (try directAddress(text)).getPort());
    try std.testing.expectError(error.InvalidAddress, directAddress("127.0.0.1:0"));
}

test {
    std.testing.refAllDecls(wire);
}
