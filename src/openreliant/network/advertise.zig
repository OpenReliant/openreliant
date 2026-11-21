//! Publish a host's signed directory lease on a background worker.
const std = @import("std");
const engine = @import("openreliant").engine;
const web = engine.web;
const identity = @import("identity.zig");
const wire = @import("wire.zig");
const version = @import("version");
const Host = @import("server.zig");
const KeyPair = std.crypto.sign.Ed25519.KeyPair;
const Publisher = @This();

const Snapshot = struct {
    players: usize,
    capacity: u8,
    scenario: ?wire.Scenario,
    accepting: bool,

    fn of(host: *const Host) Snapshot {
        const players = host.playingCount();
        return .{
            .players = players,
            .capacity = host.player_limit,
            .scenario = if (host.start == .lobby) host.start.lobby.scenario else host.arena.mode.scenario(),
            .accepting = host.final_tick == null and players < host.player_limit,
        };
    }
};

pub const Config = struct {
    origins: []const u8,
    name: []const u8,
    description: []const u8,
    address: ?[]const u8,
    port: u16,
};

const Job = struct {
    arena: std.heap.ArenaAllocator,
    origins: []const u8,
    body: []const u8,
    key: KeyPair,
    session: [16]u8,

    pub fn deinit(job: *Job) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&job.key));
        job.arena.deinit();
    }

    pub fn run(job: *Job, io: std.Io, _: *web.Progress) !void {
        var origins = std.mem.splitScalar(u8, job.origins, ',');
        while (origins.next()) |part| {
            const origin = std.mem.trim(u8, part, " \t/");
            if (origin.len == 0) continue;
            job.registerWithDeadline(io, origin) catch |err| std.log.warn("directory {s}: {t}", .{ origin, err });
        }
    }

    fn registerWithDeadline(job: *Job, io: std.Io, origin: []const u8) !void {
        const Event = union(enum) { result: anyerror!void, deadline: std.Io.Cancelable!void };
        var events: [2]Event = undefined;
        var select: std.Io.Select(Event) = .init(io, &events);
        defer select.cancelDiscard();
        try select.concurrent(.result, register, .{ job, io, origin });
        try select.concurrent(.deadline, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(3), .awake });
        return switch (try select.await()) {
            .result => |result| result,
            .deadline => error.Timeout,
        };
    }

    fn register(job: *Job, io: std.Io, origin: []const u8) !void {
        const allocator = job.arena.allocator();
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();
        const key = std.fmt.bytesToHex(job.key.public_key.toBytes(), .lower);
        const session = std.fmt.bytesToHex(job.session, .lower);
        const challenge_body = try std.json.Stringify.valueAlloc(allocator, .{ .key = key, .session = session, .operation = "register" }, .{});
        const challenge_url = try std.fmt.allocPrint(allocator, "{s}/v1/challenge", .{origin});
        var response_buffer: [4096]u8 = undefined;
        var response: std.Io.Writer = .fixed(&response_buffer);
        const first = try post(&client, challenge_url, challenge_body, &.{}, &response);
        if (first != .ok) return error.ChallengeRefused;
        const parsed = try std.json.parseFromSliceLeaky(struct { challenge: []const u8 }, allocator, response.buffered(), .{ .ignore_unknown_fields = true });
        if (parsed.challenge.len != 64) return error.InvalidChallenge;
        const message = try std.fmt.allocPrint(allocator, "OpenReliant Directory v1\nregister\n{s}\n{s}\n{s}", .{ parsed.challenge, session, job.body });
        const signature = std.fmt.bytesToHex((try job.key.sign(message, null)).toBytes(), .lower);
        const headers = [_]std.http.Header{
            .{ .name = "X-Directory-Key", .value = &key },
            .{ .name = "X-Directory-Session", .value = &session },
            .{ .name = "X-Directory-Challenge", .value = parsed.challenge },
            .{ .name = "X-Directory-Signature", .value = &signature },
        };
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/register", .{origin});
        response = .fixed(&response_buffer);
        if (try post(&client, url, job.body, &headers, &response) != .ok) return error.AdvertisementRefused;
    }
};

fn post(client: *std.http.Client, url: []const u8, payload: []const u8, headers: []const std.http.Header, response: *std.Io.Writer) !std.http.Status {
    const uri = try web.secured(try std.Uri.parse(url), .of(url));
    const result = try client.fetch(.{ .location = .{ .uri = uri }, .method = .POST, .payload = payload, .redirect_behavior = .unhandled, .extra_headers = headers, .response_writer = response });
    return result.status;
}

config: Config,
key: KeyPair,
session: [16]u8,
download: web.Download(Job) = .{},
next: i64 = 0,
revision: u64 = 0,
last: ?Snapshot = null,
next_change: i64 = 0,

pub fn init(io: std.Io, config: Config, server: *const identity.Server) !Publisher {
    var session: [16]u8 = undefined;
    try io.randomSecure(&session);
    return .{ .config = config, .key = server.issuer, .session = session };
}

pub fn tick(publisher: *Publisher, host: *const Host, now: i64) void {
    if (publisher.download.take()) |answer| answer catch |err| std.log.warn("directory advertisement failed: {t}", .{err});
    if (publisher.download.busy()) return;
    const current = Snapshot.of(host);
    if (!due(publisher.last, current, now, publisher.next, publisher.next_change)) return;
    publisher.next = now + 30 * std.time.us_per_s;
    publisher.next_change = now + std.time.us_per_s;
    publisher.send(current) catch |err| {
        std.log.warn("could not start directory advertisement: {t}", .{err});
        return;
    };
    publisher.last = current;
}

fn due(previous: ?Snapshot, current: Snapshot, now: i64, next: i64, next_change: i64) bool {
    const changed = if (previous) |last| !std.meta.eql(last, current) else true;
    return now >= next or (changed and now >= next_change);
}

test "player changes publish promptly without allowing rapid churn" {
    const empty: Snapshot = .{ .players = 0, .capacity = 8, .scenario = .tag_bomb, .accepting = true };
    var joined = empty;
    joined.players = 1;
    try std.testing.expect(due(null, empty, 0, 0, 0));
    try std.testing.expect(!due(empty, joined, 500_000, 30_000_000, 1_000_000));
    try std.testing.expect(due(empty, joined, 1_000_000, 30_000_000, 1_000_000));
    try std.testing.expect(due(joined, empty, 2_000_000, 31_000_000, 2_000_000));
    try std.testing.expect(!due(empty, empty, 29_000_000, 30_000_000, 1_000_000));
    try std.testing.expect(due(empty, empty, 30_000_000, 30_000_000, 1_000_000));
}

fn send(publisher: *Publisher, snapshot: Snapshot) !void {
    var arena = std.heap.ArenaAllocator.init(web.allocator);
    var owned = true;
    errdefer if (owned) arena.deinit();
    const allocator = arena.allocator();
    const origins = try allocator.dupe(u8, publisher.config.origins);
    publisher.revision += 1;
    const mode = if (snapshot.scenario) |chosen| mode: {
        const id = try allocator.dupe(u8, @tagName(chosen));
        for (id) |*character| if (character.* == '_') {
            character.* = '-';
        };
        break :mode .{ .id = id, .name = chosen.record().name };
    } else null;
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .game = .{ .id = "org.openreliant.starlancer", .name = "StarLancer" },
        .revision = publisher.revision,
        .name = publisher.config.name,
        .description = publisher.config.description,
        .hosting = "dedicated",
        .mode = mode,
        .players = snapshot.players,
        .capacity = snapshot.capacity,
        .accepting = snapshot.accepting,
        .protocol = wire.revision,
        .release = version.string,
        .port = publisher.config.port,
        .address = publisher.config.address,
    }, .{});
    owned = false;
    try publisher.download.start(.{ .arena = arena, .origins = origins, .body = body, .key = publisher.key, .session = publisher.session }, .{ .whole = .fromSeconds(15) });
}

pub fn close(publisher: *Publisher) void {
    publisher.download.abandon();
    std.crypto.secureZero(u8, std.mem.asBytes(&publisher.key));
}
