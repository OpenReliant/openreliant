//! Configuration and startup for the packaged headless host.
const std = @import("std");
const Profile = @import("openreliant").engine.profile.Profile;
const Arena = @import("arena.zig");
const Host = @import("server.zig");
const session = @import("session.zig");
const Invite = @import("identity.zig").Invite;
const wire = @import("wire.zig");
const LaunchWait = @import("launch_wait.zig");
const ArenaOptions = @import("openreliant").engine.game.deathmatch.Options;
const Advertiser = @import("advertise.zig");
const Difficulty = @import("openreliant").engine.game.collision.Difficulty;

const default_config = "server.ini";
const max_config_size = 16 * 1024;

const Config = struct {
    bind: std.Io.net.IpAddress,
    invite_address: ?std.Io.net.IpAddress,
    mode: Arena.Mode,
    mission: ?u16,
    game_directory: []const u8,
    players: u8,
    launch_wait: LaunchWait,
    metrics: ?std.Io.net.IpAddress,
    ticks: ?u32,
    teams: bool,
    arena_options: ArenaOptions,
    repeat_rounds: bool,
    difficulty: Difficulty,
    identity: ?session.Identity,
    advertise: ?Advertiser.Config,
    /// The name in LAN lists, or null to stay out of them.
    lan_name: ?[]const u8,
    check_updates: bool,

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
        const minimum = if (profile.value("Server", "MinPlayers")) |value|
            std.fmt.parseInt(u8, value, 10) catch return error.InvalidMinimumPlayers
        else if (mission != null) players else Host.pilots_to_start;
        if (minimum < Host.pilots_to_start or minimum > players) return error.InvalidMinimumPlayers;
        const start_delay: u32 = if (profile.value("Server", "StartDelaySeconds")) |value|
            std.fmt.parseInt(u32, value, 10) catch return error.InvalidStartDelay
        else if (mode.scenario() != null) 30 else 0;
        const metrics = if (profile.value("Metrics", "Port")) |value| address: {
            const metrics_port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidMetricsPort;
            if (metrics_port == 0 or metrics_port == port) return error.InvalidMetricsPort;
            const host = profile.value("Metrics", "BindAddress") orelse "127.0.0.1";
            break :address std.Io.net.IpAddress.parse(host, metrics_port) catch return error.InvalidMetricsBindAddress;
        } else null;
        const round_seconds = profile.value("Server", "RoundSeconds");
        const ticks = if (profile.value("Server", "RoundTicks")) |limit| raw: {
            if (round_seconds != null) return error.ConflictingRoundLimits;
            break :raw std.fmt.parseInt(u32, limit, 10) catch return error.InvalidRoundTicks;
        } else if (round_seconds) |limit| seconds: {
            const seconds = std.fmt.parseInt(u32, limit, 10) catch return error.InvalidRoundSeconds;
            if (seconds == 0) return error.InvalidRoundSeconds;
            break :seconds std.math.cast(u32, @as(u64, seconds) * std.time.us_per_s / wire.step_us) orelse return error.InvalidRoundSeconds;
        } else null;
        if (ticks == 0) return error.InvalidRoundTicks;
        const teams = try optionalSwitch(profile, "Teams", false);
        const repeat_rounds = try optionalSwitch(profile, "RepeatRounds", mode.scenario() != null);
        const arena_options: ArenaOptions = if (mode.scenario() != null) .{
            .ai_turrets = try optionalSwitch(profile, "AiTurrets", false),
            .target_players = try optionalSwitch(profile, "TargetPlayers", true),
        } else .{};
        if (teams and (mode.scenario() == null or mode.scenario().?.record().teams == .none)) return error.InvalidTeamArena;
        if (repeat_rounds and mode.scenario() == null) return error.InvalidRepeatRounds;
        // A co-op campaign's difficulty: easy, as the original flies every network campaign,
        // unless the server sets another.
        const difficulty: Difficulty = if (profile.value("Server", "Difficulty")) |value|
            std.meta.stringToEnum(Difficulty, value) orelse return error.InvalidDifficulty
        else
            .easy;
        const root = profile.value("Identity", "RootPublicKey");
        const certificate = profile.value("Identity", "Certificate");
        const managed: ?session.Identity = if (root == null and certificate == null) null else identity: {
            const root_path = root orelse return error.MissingRootPublicKey;
            const certificate_path = certificate orelse return error.MissingCertificate;
            if (root_path.len == 0) return error.MissingRootPublicKey;
            if (certificate_path.len == 0) return error.MissingCertificate;
            break :identity .{ .root_path = root_path, .certificate_path = certificate_path };
        };
        const name = profile.value("Server", "Name") orelse "OpenReliant server";
        const rendezvous = try optionalSwitch(profile, "Rendezvous", false);
        const unlisted = try optionalSwitch(profile, "Unlisted", false);
        // A server out of the list has only its rendezvous invite to be found by.
        if (unlisted and !rendezvous) return error.UnlistedNeedsRendezvous;
        if (rendezvous and profile.value("Server", "DirectoryServers") == null) return error.RendezvousNeedsDirectory;
        return .{
            .bind = bind,
            .invite_address = if (Invite.hasAddress(advertised)) advertised else null,
            .mode = mode,
            .mission = mission,
            .game_directory = profile.value("Server", "GameDirectory") orelse ".",
            .players = players,
            .launch_wait = .{ .minimum = minimum, .delay_us = @as(i64, start_delay) * std.time.us_per_s },
            .metrics = metrics,
            .ticks = ticks,
            .teams = teams,
            .arena_options = arena_options,
            .repeat_rounds = repeat_rounds,
            .difficulty = difficulty,
            .identity = managed,
            .advertise = if (profile.value("Server", "DirectoryServers")) |origins| .{
                .origins = origins,
                .name = name,
                .description = profile.value("Server", "Description") orelse "",
                .address = profile.value("Server", "PublicAddress"),
                .port = port,
                .rendezvous = rendezvous,
                .unlisted = unlisted,
            } else null,
            .lan_name = if (try optionalSwitch(profile, "LanDiscovery", true)) name else null,
            .check_updates = try optionalSwitch(profile, "CheckUpdates", true),
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
        .launch_wait = config.launch_wait,
        .metrics = config.metrics,
        .ticks = config.ticks,
        .teams = config.teams,
        .arena_options = config.arena_options,
        .repeat_rounds = config.repeat_rounds,
        .difficulty = config.difficulty,
        .invite_address = config.invite_address,
        .advertise = config.advertise,
        .lan_name = config.lan_name,
        .check_updates = config.check_updates,
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

test "a server takes rendezvous through a directory, listed or not" {
    const plain = try Config.parse(.{ .text = "[Server]\nDirectoryServers=https://directory.example" });
    try std.testing.expect(!plain.advertise.?.rendezvous and !plain.advertise.?.unlisted);
    const reached = try Config.parse(.{ .text = "[Server]\nDirectoryServers=https://directory.example\nRendezvous=1" });
    try std.testing.expect(reached.advertise.?.rendezvous and !reached.advertise.?.unlisted);
    const private = try Config.parse(.{ .text = "[Server]\nDirectoryServers=https://directory.example\nRendezvous=1\nUnlisted=1" });
    try std.testing.expect(private.advertise.?.rendezvous and private.advertise.?.unlisted);
    // A server out of the list has only its rendezvous invite to be found by.
    try std.testing.expectError(error.UnlistedNeedsRendezvous, Config.parse(.{ .text = "[Server]\nDirectoryServers=https://directory.example\nUnlisted=1" }));
    try std.testing.expectError(error.RendezvousNeedsDirectory, Config.parse(.{ .text = "[Server]\nRendezvous=1" }));
}

test "dedicated activation and metrics have independent settings" {
    const defaults = try Config.parse(.empty);
    try std.testing.expect(defaults.check_updates);
    try std.testing.expectEqualStrings("OpenReliant server", defaults.lan_name.?);
    try std.testing.expectEqualStrings("Friday", (try Config.parse(.{ .text = "[Server]\nName=Friday" })).lan_name.?);
    try std.testing.expectEqual(null, (try Config.parse(.{ .text = "[Server]\nLanDiscovery=0" })).lan_name);
    try std.testing.expect(!(try Config.parse(.{ .text = "[Server]\nCheckUpdates=0" })).check_updates);
    try std.testing.expectEqual(2, defaults.launch_wait.minimum);
    try std.testing.expectEqual(30 * std.time.us_per_s, defaults.launch_wait.delay_us);
    try std.testing.expect(defaults.repeat_rounds);
    try std.testing.expectEqual(null, defaults.metrics);

    const server = try Config.parse(.{ .text =
        \\[Server]
        \\Players=8
        \\MinPlayers=4
        \\StartDelaySeconds=12
        \\RoundSeconds=60
        \\[Metrics]
        \\Port=9100
    });
    try std.testing.expectEqual(4, server.launch_wait.minimum);
    try std.testing.expectEqual(12 * std.time.us_per_s, server.launch_wait.delay_us);
    try std.testing.expectEqual(60 * std.time.us_per_s / wire.step_us, server.ticks.?);
    try std.testing.expect(server.metrics.?.eql(&try std.Io.net.IpAddress.parseLiteral("127.0.0.1:9100")));
    try std.testing.expectError(error.InvalidMinimumPlayers, Config.parse(.{ .text = "[Server]\nPlayers=4\nMinPlayers=5" }));
    try std.testing.expectError(error.InvalidMetricsPort, Config.parse(.{ .text = "[Metrics]\nPort=27020" }));
    try std.testing.expectError(error.ConflictingRoundLimits, Config.parse(.{ .text = "[Server]\nRoundTicks=10\nRoundSeconds=1" }));
    const coop = try Config.parse(.{ .text = "[Server]\nMission=1\nPlayers=4" });
    try std.testing.expectEqual(4, coop.launch_wait.minimum);
    try std.testing.expectEqual(0, coop.launch_wait.delay_us);
    try std.testing.expect(!coop.repeat_rounds);
    // Co-op is easy, as in the original, unless the server sets its difficulty.
    try std.testing.expectEqual(.easy, coop.difficulty);
    try std.testing.expectEqual(.hard, (try Config.parse(.{ .text = "[Server]\nMission=1\nDifficulty=hard" })).difficulty);
    try std.testing.expectError(error.InvalidDifficulty, Config.parse(.{ .text = "[Server]\nMission=1\nDifficulty=brutal" }));
}
