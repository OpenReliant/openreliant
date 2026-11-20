//! Configuration and startup for the packaged headless host.
const std = @import("std");
const Profile = @import("openreliant").engine.profile.Profile;
const Arena = @import("arena.zig");
const Host = @import("server.zig");
const session = @import("session.zig");
const Invite = @import("identity.zig").Invite;
const wire = @import("wire.zig");
const ArenaOptions = @import("openreliant").engine.game.deathmatch.Options;

const default_config = "server.ini";
const max_config_size = 16 * 1024;

const Config = struct {
    bind: std.Io.net.IpAddress,
    invite_address: ?std.Io.net.IpAddress,
    mode: Arena.Mode,
    mission: ?u16,
    game_directory: []const u8,
    players: u8,
    ticks: ?u32,
    teams: bool,
    arena_options: ArenaOptions,
    repeat_rounds: bool,
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
        const arena = profile.value("Server", "Arena");
        const mission = if (profile.value("Server", "Mission")) |value| selected: {
            if (arena != null) return error.InvalidMission;
            const number = std.fmt.parseInt(u16, value, 10) catch return error.InvalidMission;
            if (!wire.campaignNumber(number)) return error.InvalidMission;
            break :selected number;
        } else null;
        const mode: Arena.Mode = if (mission != null) .training else if (arena) |value|
            std.meta.stringToEnum(Arena.Mode, value) orelse return error.InvalidArena
        else
            .@"nuclear-threat";
        const crew_limit: u8 = if (mission != null) wire.cooperative_slots else wire.slots;
        const players = if (profile.value("Server", "Players")) |value|
            std.fmt.parseInt(u8, value, 10) catch return error.InvalidPlayerLimit
        else if (mission != null) Host.pilots_to_start else crew_limit;
        if (players < Host.pilots_to_start or players > crew_limit) return error.InvalidPlayerLimit;
        const ticks = if (profile.value("Server", "RoundTicks")) |limit|
            std.fmt.parseInt(u32, limit, 10) catch return error.InvalidRoundTicks
        else
            null;
        if (ticks == 0) return error.InvalidRoundTicks;
        const teams = try optionalSwitch(profile, "Teams", false);
        const repeat_rounds = try optionalSwitch(profile, "RepeatRounds", false);
        const arena_options: ArenaOptions = if (mode.scenario() != null) .{
            .ai_turrets = try optionalSwitch(profile, "AiTurrets", false),
            .target_players = try optionalSwitch(profile, "TargetPlayers", true),
        } else .{};
        if (teams and (mode.scenario() == null or mode.scenario().?.record().teams == .none)) return error.InvalidTeamArena;
        if (repeat_rounds and (mode.scenario() == null or ticks == null)) return error.InvalidRepeatRounds;
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
            .mission = mission,
            .game_directory = profile.value("Server", "GameDirectory") orelse ".",
            .players = players,
            .ticks = ticks,
            .teams = teams,
            .arena_options = arena_options,
            .repeat_rounds = repeat_rounds,
            .identity = managed,
        };
    }
};

fn optionalSwitch(profile: Profile, key: []const u8, default: bool) !bool {
    const value = profile.value("Server", key) orelse return default;
    return switch (std.fmt.parseInt(u1, value, 10) catch return error.InvalidServerSwitch) {
        0 => false,
        1 => true,
    };
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len > 1) return error.InvalidServerArguments;
    const path = if (args.len == 0) default_config else args[0];
    const folder = std.fs.path.dirname(path) orelse ".";
    var directory = try std.Io.Dir.cwd().openDir(io, folder, .{});
    defer directory.close(io);
    const text = try directory.readFileAlloc(io, std.fs.path.basename(path), gpa, .limited(max_config_size));
    defer gpa.free(text);
    const config = try Config.parse(.{ .text = text });
    var game_directory = if (config.mission != null or config.mode.scenario() != null) try directory.openDir(io, config.game_directory, .{}) else null;
    defer if (game_directory) |*opened| opened.close(io);
    var buffer: [128]u8 = undefined;
    const address = try std.fmt.bufPrintSentinel(&buffer, "{f}", .{config.bind}, 0);
    try session.serve(io, gpa, directory, config.identity, .{
        .address = address,
        .mode = config.mode,
        .mission = config.mission,
        .game_directory = game_directory,
        .players = config.players,
        .ticks = config.ticks,
        .teams = config.teams,
        .arena_options = config.arena_options,
        .repeat_rounds = config.repeat_rounds,
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
    try std.testing.expectEqual(Arena.Mode.@"nuclear-threat", config.mode);
    try std.testing.expectEqual(.asteroid_field, (try Config.parse(.{ .text = "[Server]\nArena=asteroid-field" })).mode.scenario());
    try std.testing.expectEqual(ArenaOptions{}, config.arena_options);
    const options = try Config.parse(.{ .text = "[server]\naiturrets=1\ntargetplayers=0" });
    try std.testing.expect(options.arena_options.ai_turrets);
    try std.testing.expect(!options.arena_options.target_players);
    try std.testing.expectError(error.InvalidServerSwitch, Config.parse(.{ .text = "[Server]\nTargetPlayers=2" }));
    try std.testing.expectEqual(ArenaOptions{}, (try Config.parse(.{ .text = "[Server]\nMission=1\nAiTurrets=1\nTargetPlayers=0" })).arena_options);
    try std.testing.expectEqual(2, config.players);
    try std.testing.expectEqual(175, config.ticks.?);
    try std.testing.expectEqualStrings("certs/session root.pub", config.identity.?.root_path);
    try std.testing.expectEqual(8, (try Config.parse(.empty)).players);
    try std.testing.expectError(error.InvalidPlayerLimit, Config.parse(.{ .text = "[Server]\nPlayers=9" }));
    try std.testing.expectEqual(2, (try Config.parse(.{ .text = "[Server]\nMission=1" })).players);
    try std.testing.expectEqual(4, (try Config.parse(.{ .text = "[Server]\nMission=1\nPlayers=4" })).players);
    try std.testing.expectError(error.InvalidPlayerLimit, Config.parse(.{ .text = "[Server]\nMission=1\nPlayers=5" }));
    try std.testing.expect((try Config.parse(.empty)).identity == null);
    try std.testing.expectError(error.MissingRootPublicKey, Config.parse(.{ .text = "[Identity]\nCertificate=host.cert" }));
    try std.testing.expect((try Config.parse(.{ .text = "[server]\nBindAddress=0.0.0.0" })).invite_address == null);
    const advertised = try Config.parse(.{ .text = "[server]\nBindAddress=0.0.0.0\nInviteAddress=192.0.2.1" });
    try std.testing.expect(advertised.invite_address.?.eql(&try std.Io.net.IpAddress.parseLiteral("192.0.2.1:27020")));
}
