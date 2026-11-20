//! Optional Prometheus endpoint for dedicated hosts. HTTP runs outside the game loop.
const std = @import("std");
const Io = std.Io;
const Arena = @import("arena.zig");
const Traffic = @import("transport.zig").Traffic;
const Exporter = @This();
const log = std.log.scoped(.network_metrics);

pub const Join = enum { admitted, rejected, timed_out, abandoned };
pub const Departure = enum { normal, rejected, timed_out, dropped, retired };

pub const Stats = struct {
    players: usize = 0,
    capacity: u8,
    joins: std.EnumArray(Join, u64) = .initFill(0),
    departures: std.EnumArray(Departure, u64) = .initFill(0),
    rounds: std.EnumArray(Arena.Mode, Rounds) = .initFill(.{}),
    cooperative: Rounds = .{},
    ticks: u64 = 0,
    step_us: u64 = 0,
    traffic: Traffic = .{},

    pub const Rounds = struct { started: u64 = 0, completed: u64 = 0 };

    fn write(stats: *const Stats, out: *Io.Writer) Io.Writer.Error!void {
        try out.writeAll(
            "# TYPE openreliant_players gauge\n" ++
                "# TYPE openreliant_player_capacity gauge\n" ++
                "# TYPE openreliant_joins_total counter\n" ++
                "# TYPE openreliant_departures_total counter\n" ++
                "# TYPE openreliant_rounds_started_total counter\n" ++
                "# TYPE openreliant_rounds_completed_total counter\n" ++
                "# TYPE openreliant_simulation_tick_duration_seconds summary\n" ++
                "# TYPE openreliant_game_messages_total counter\n" ++
                "# TYPE openreliant_game_bytes_total counter\n",
        );
        try out.print("openreliant_players {d}\nopenreliant_player_capacity {d}\n", .{ stats.players, stats.capacity });
        for (std.enums.values(Join)) |outcome| {
            try out.print("openreliant_joins_total{{outcome=\"{t}\"}} {d}\n", .{ outcome, stats.joins.get(outcome) });
        }
        for (std.enums.values(Departure)) |outcome| {
            try out.print("openreliant_departures_total{{outcome=\"{t}\"}} {d}\n", .{ outcome, stats.departures.get(outcome) });
        }
        for (std.enums.values(Arena.Mode)) |mode| try writeRounds(out, @tagName(mode), stats.rounds.get(mode));
        try writeRounds(out, "cooperative", stats.cooperative);
        try out.print(
            "openreliant_simulation_tick_duration_seconds_count {d}\n" ++
                "openreliant_simulation_tick_duration_seconds_sum {d}.{d:0>6}\n",
            .{ stats.ticks, stats.step_us / std.time.us_per_s, stats.step_us % std.time.us_per_s },
        );
        try writeTraffic(out, "received", stats.traffic.received);
        try writeTraffic(out, "sent", stats.traffic.sent);
    }

    fn writeRounds(out: *Io.Writer, label: []const u8, rounds: Rounds) Io.Writer.Error!void {
        try out.print(
            "openreliant_rounds_started_total{{mode=\"{s}\"}} {d}\n" ++
                "openreliant_rounds_completed_total{{mode=\"{s}\"}} {d}\n",
            .{ label, rounds.started, label, rounds.completed },
        );
    }

    fn writeTraffic(out: *Io.Writer, direction: []const u8, counts: Traffic.Counts) Io.Writer.Error!void {
        try out.print(
            "openreliant_game_messages_total{{direction=\"{s}\"}} {d}\n" ++
                "openreliant_game_bytes_total{{direction=\"{s}\"}} {d}\n",
            .{ direction, counts.messages, direction, counts.bytes },
        );
    }
};

io: Io,
listener: Io.net.Server,
task: Io.Group = .init,
mutex: Io.Mutex = .init,
/// Only the game thread writes this. The HTTP task reads the published copy.
stats: Stats,
latest: Stats,

pub fn open(exporter: *Exporter, io: Io, address: Io.net.IpAddress, capacity: u8) !void {
    const stats: Stats = .{ .capacity = capacity };
    exporter.* = .{
        .io = io,
        .listener = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 4 }),
        .stats = stats,
        .latest = stats,
    };
    errdefer exporter.listener.deinit(io);
    try exporter.task.concurrent(io, serve, .{exporter});
    log.info("metrics listening at {f}", .{exporter.listener.socket.address});
}

pub fn close(exporter: *Exporter) void {
    exporter.task.cancel(exporter.io);
    exporter.listener.deinit(exporter.io);
}

pub fn publish(exporter: *Exporter, players: usize) void {
    exporter.stats.players = players;
    exporter.mutex.lockUncancelable(exporter.io);
    defer exporter.mutex.unlock(exporter.io);
    exporter.latest = exporter.stats;
}

fn copyStats(exporter: *Exporter) Io.Cancelable!Stats {
    try exporter.mutex.lock(exporter.io);
    defer exporter.mutex.unlock(exporter.io);
    return exporter.latest;
}

fn serve(exporter: *Exporter) Io.Cancelable!void {
    const io = exporter.io;
    while (true) {
        const stream = exporter.listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConnectionAborted => continue,
            else => {
                log.warn("could not accept a metrics connection: {t}", .{err});
                try io.sleep(.fromSeconds(1), .awake);
                continue;
            },
        };
        defer stream.close(io);
        // One request at a time, with a deadline for both reading and writing.
        const Event = union(enum) { response: void, timeout: Io.Cancelable!void };
        var buffer: [2]Event = undefined;
        var select: Io.Select(Event) = .init(io, &buffer);
        defer select.cancelDiscard();
        select.concurrent(.response, respond, .{ exporter, stream }) catch {
            try io.sleep(.fromMilliseconds(100), .awake);
            continue;
        };
        select.concurrent(.timeout, Io.sleep, .{ io, .fromSeconds(2), .awake }) catch {
            try io.sleep(.fromMilliseconds(100), .awake);
            continue;
        };
        _ = try select.await();
    }
}

fn respond(exporter: *Exporter, stream: Io.net.Stream) void {
    var input: [4096]u8 = undefined;
    var output: [1024]u8 = undefined;
    var reader = stream.reader(exporter.io, &input);
    var writer = stream.writer(exporter.io, &output);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;
    if (request.head.method != .GET and request.head.method != .HEAD) {
        request.respond("", .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = &.{.{ .name = "allow", .value = "GET, HEAD" }} }) catch {};
        return;
    }
    if (!std.mem.eql(u8, request.head.target, "/metrics")) {
        request.respond("", .{ .status = .not_found, .keep_alive = false }) catch {};
        return;
    }
    const stats = exporter.copyStats() catch return;
    var payload: [8192]u8 = undefined;
    var data: Io.Writer = .fixed(&payload);
    stats.write(&data) catch return;
    request.respond(data.buffered(), .{
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" }},
    }) catch {};
}
