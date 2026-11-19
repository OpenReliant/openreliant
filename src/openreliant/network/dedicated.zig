//! Configuration and startup for the packaged headless host.
const std = @import("std");
const Profile = @import("openreliant").engine.profile.Profile;
const Arena = @import("arena.zig");
const Host = @import("server.zig");
const session = @import("session.zig");
const Invite = @import("identity.zig").Invite;
const wire = @import("wire.zig");

const default_config = "server.ini";
const max_config_size = 16 * 1024;

const Config = struct {
    bind: std.Io.net.IpAddress,
    invite_address: ?std.Io.net.IpAddress,
    mode: Arena.Mode,
    players: u8,
    ticks: ?u32,
    identity: ?session.Identity,

    fn parse(profile: Profile) !Config {
        const port = if (profile.value("Server", "Port")) |value|
            std.fmt.parseInt(u16, value, 10) catch return error.InvalidPort
        else
            session.default_port;
        if (port == 0) return error.InvalidPort;
        const address = profile.value("Server", "BindAddress") orelse "127.0.0.1";
        const bind = std.Io.net.IpAddress.parse(address, port) catch return error.InvalidBindAddress;
        const advertised = if (profile.value("Server", "InviteAddress")) |value|
            std.Io.net.IpAddress.parse(value, port) catch return error.InvalidInviteAddress
        else
            bind;
        const mode = if (profile.value("Server", "Arena")) |value|
            std.meta.stringToEnum(Arena.Mode, value) orelse return error.InvalidArena
        else
            .@"six-beacons";
        const players = if (profile.value("Server", "Players")) |value|
            std.fmt.parseInt(u8, value, 10) catch return error.InvalidPlayerLimit
        else
            wire.slots;
        if (players < Host.pilots_to_start or players > wire.slots) return error.InvalidPlayerLimit;
        const ticks = if (profile.value("Server", "RoundTicks")) |limit|
            std.fmt.parseInt(u32, limit, 10) catch return error.InvalidRoundTicks
        else
            null;
        if (ticks == 0) return error.InvalidRoundTicks;
        const root = profile.value("Identity", "RootPublicKey");
        const certificate = profile.value("Identity", "Certificate");
        const managed: ?session.Identity = if (root == null and certificate == null) null else identity: {
            const root_path = root orelse return error.MissingRootPublicKey;
            const certificate_path = certificate orelse return error.MissingCertificate;
            if (root_path.len == 0) return error.MissingRootPublicKey;
            if (certificate_path.len == 0) return error.MissingCertificate;
            break :identity .{ .root_path = root_path, .certificate_path = certificate_path };
        };
        return .{
            .bind = bind,
            .invite_address = if (Invite.hasAddress(advertised)) advertised else null,
            .mode = mode,
            .players = players,
            .ticks = ticks,
            .identity = managed,
        };
    }
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len > 1) return error.InvalidServerArguments;
    const path = if (args.len == 0) default_config else args[0];
    const folder = std.fs.path.dirname(path) orelse ".";
    var directory = try std.Io.Dir.cwd().openDir(io, folder, .{});
    defer directory.close(io);
    const text = try directory.readFileAlloc(io, std.fs.path.basename(path), gpa, .limited(max_config_size));
    defer gpa.free(text);
    const config = try Config.parse(.{ .text = text });
    var buffer: [128]u8 = undefined;
    const address = try std.fmt.bufPrintSentinel(&buffer, "{f}", .{config.bind}, 0);
    try session.serve(io, gpa, directory, config.identity, .{
        .address = address,
        .mode = config.mode,
        .players = config.players,
        .ticks = config.ticks,
        .invite_address = config.invite_address,
    });
}

test "headless settings share the game's INI syntax" {
    const config = try Config.parse(.{ .text =
        \\[server]
        \\bindaddress=::1
        \\port=27200
        \\players=2
        \\roundticks=175
        \\[identity]
        \\RootPublicKey="certs/session root.pub"
        \\Certificate=certs/host.cert
    });
    try std.testing.expectEqual(27200, config.bind.getPort());
    try std.testing.expectEqual(Arena.Mode.@"six-beacons", config.mode);
    try std.testing.expectEqual(2, config.players);
    try std.testing.expectEqual(175, config.ticks.?);
    try std.testing.expectEqualStrings("certs/session root.pub", config.identity.?.root_path);
    try std.testing.expectError(error.InvalidPlayerLimit, Config.parse(.{ .text = "[Server]\nPlayers=4" }));
    try std.testing.expect((try Config.parse(.empty)).identity == null);
    try std.testing.expectError(error.MissingRootPublicKey, Config.parse(.{ .text = "[Identity]\nCertificate=host.cert" }));
    try std.testing.expect((try Config.parse(.{ .text = "[server]\nBindAddress=0.0.0.0" })).invite_address == null);
    const advertised = try Config.parse(.{ .text = "[server]\nBindAddress=0.0.0.0\nInviteAddress=192.0.2.1" });
    try std.testing.expect(advertised.invite_address.?.eql(&try std.Io.net.IpAddress.parseLiteral("192.0.2.1:27020")));
}
