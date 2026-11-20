//! Own the transport and route its callbacks to the current host and pilot.
const std = @import("std");
const net = @import("transport.zig");
const wire = @import("wire.zig");
const Arena = @import("arena.zig");
const credential = @import("identity.zig");
const Host = @import("server.zig");
pub const Client = @import("client.zig");

pub const default_port = 27020;
const default_round_ticks = 250;
const max_certificate = 4096;
const max_root_key = 512;
const Role = enum { host, join };
var current: struct { host: ?*Host = null, client: ?*Client = null } = .{};

comptime {
    if (@import("network_options").enabled) @export(&status, .{ .name = "session_status" });
}

fn status(conn: net.Connection, event: net.Status, identity: ?[*:0]const u8) callconv(.c) void {
    const name = if (identity) |value| std.mem.span(value) else null;
    if (current.client) |client| {
        if (client.conn == conn) return client.status(conn, event, name);
    }
    if (current.host) |host| return host.status(conn, event, name);
    if (current.client != null) net.session_close(conn);
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
    game_directory: ?std.Io.Dir = null,
    mode: Arena.Mode = .training,
    mission: ?u16 = null,
    players: u8 = wire.slots,
    ticks: ?u32,
    invite_address: ?std.Io.net.IpAddress = null,
};

fn initTransport(root: ?[]const u8, certificate: ?[]const u8) !void {
    if (!net.session_init(if (root) |r| r.ptr else null, if (root) |r| r.len else 0, if (certificate) |cert| cert.ptr else null, @intCast(if (certificate) |cert| cert.len else 0), wire.capacity))
        return error.InvalidTransportIdentity;
}

fn initAutomatic(server: *const credential.Server, io: std.Io) !void {
    var certificate = try server.hostCertificate(io);
    defer certificate.wipe();
    try initTransport(&credential.openSshKey(server.issuer.public_key), certificate.slice());
}

/// A listener and a local pilot sharing one transport instance. The local pair is created
/// inside the process, so remote admission can never take the host pilot's reservation.
pub const LocalGame = struct {
    gpa: std.mem.Allocator,
    directory: std.Io.Dir,
    server: credential.Server,
    host: Host,

    pub fn start(io: std.Io, gpa: std.mem.Allocator, directory: std.Io.Dir, client: *Client, port: u16, call_sign: wire.CallSign, mission: ?u16) !*LocalGame {
        const game = try gpa.create(LocalGame);
        errdefer gpa.destroy(game);
        game.gpa = gpa;
        game.directory = directory;
        game.server = try .load(io, directory);
        errdefer game.server.wipe();
        try initAutomatic(&game.server, io);
        errdefer net.session_deinit();
        const arena = try Arena.create(gpa, .training, io, directory);
        errdefer arena.destroy();
        game.host = .{
            .io = io,
            .arena = arena,
            .signer = &game.server,
            .lan_only = true,
            .start = .{ .lobby = .{ .mission = mission } },
            .player_limit = if (mission != null) wire.cooperative_slots else wire.slots,
        };

        var address_buffer: [credential.Invite.max_address]u8 = undefined;
        const address = try std.fmt.bufPrintSentinel(&address_buffer, "[::]:{d}", .{port}, 0);
        try game.host.open(address, null);
        errdefer game.host.close();
        var server_end: net.Connection = 0;
        var client_end: net.Connection = 0;
        if (!net.session_local_pair(&server_end, &client_end)) return error.ConnectFailed;
        game.host.takeLocalPilot(server_end, call_sign);
        client.local(io, client_end);
        current = .{ .host = &game.host, .client = client };
        return game;
    }

    pub fn launch(game: *LocalGame) !void {
        if (!game.host.canLaunch()) return;
        const staging = game.host.arena;
        const lobby = game.host.start.lobby;
        if (lobby.mission) |mission| {
            game.host.beginBriefing(mission, game.directory);
            return;
        }
        game.host.arena = try staging.prepareStock(lobby.scenario, game.host.io, game.directory);
        staging.destroy();
        game.host.launch();
    }

    pub fn stop(game: *LocalGame, client: *Client) void {
        current = .{};
        client.close();
        game.host.close();
        net.session_deinit();
        game.host.arena.destroy();
        game.server.wipe();
        game.gpa.destroy(game);
    }
};

pub fn serve(io: std.Io, gpa: std.mem.Allocator, directory: std.Io.Dir, identity: ?Identity, options: HostOptions) !void {
    const limit: u8 = if (options.mission != null) wire.cooperative_slots else wire.slots;
    if (options.players < Host.pilots_to_start or options.players > limit) return error.InvalidPlayerLimit;
    var server: ?credential.Server = null;
    defer if (server) |*automatic| automatic.wipe();
    if (identity) |managed| {
        try managed.load(io, gpa, directory);
    } else {
        server = try .load(io, directory);
        try initAutomatic(&server.?, io);
    }
    defer net.session_deinit();
    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    const game_directory = options.game_directory orelse directory;
    const arena = try Arena.create(gpa, options.mode, io, game_directory);
    host.* = .{
        .io = io,
        .arena = arena,
        .player_limit = options.players,
        .signer = if (server) |*automatic| automatic else null,
        .campaign_start = if (options.mission) |mission| .{ .number = mission, .directory = game_directory } else null,
    };
    defer host.arena.destroy();
    current.host = host;
    defer current.host = null;
    const invite: ?credential.Invite = if (server) |*automatic|
        if (options.invite_address) |address| .{ .address = address, .key = automatic.issuer.public_key } else null
    else
        null;
    try host.run(options.address, options.ticks, invite);
}

fn controls(value: []const u8) !Client.Controls {
    if (std.mem.eql(u8, value, "keyboard")) return .keyboard;
    return .{ .fixed = std.meta.stringToEnum(Client.Steering, value) orelse return error.InvalidSteering };
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
    const steering = if (args.len > 1) try controls(args[1]) else .keyboard;
    const limit = if (args.len > 2) try number(args[2]) else null;
    var client: Client = undefined;
    try connect(&client, io, args[0]);
    defer disconnect(&client);
    try client.drive(io, steering, limit);
}

pub fn connect(client: *Client, io: std.Io, target: []const u8) !void {
    const invite = if (std.mem.startsWith(u8, target, credential.Invite.prefix))
        try credential.Invite.parse(target)
    else
        null;
    const endpoint = if (invite) |value| value.address else try directAddress(target);
    var buffer: [credential.Invite.max_address]u8 = undefined;
    const address = try std.fmt.bufPrintSentinel(&buffer, "{f}", .{endpoint}, 0);
    try initTransport(if (invite) |value| &credential.openSshKey(value.key) else null, null);
    errdefer net.session_deinit();
    client.* = .{ .expected_host = if (invite != null) credential.host_name else null };
    try client.open(io, address);
    current.client = client;
}

pub fn disconnect(client: *Client) void {
    client.close();
    current.client = null;
    net.session_deinit();
}

fn play(io: std.Io, address: [:0]const u8, expected_host: ?[]const u8, steering: Client.Controls, limit: ?u32) !void {
    var client: Client = .{ .expected_host = expected_host };
    current.client = &client;
    defer current.client = null;
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
