//! Browse independent directory servers without blocking the front end.
const std = @import("std");
const engine = @import("openreliant").engine;
const web = engine.web;
const Connection = engine.game.interface.Connection;
const DirectoryInvite = @import("identity.zig").DirectoryInvite;
const Key = @import("identity.zig").PublicKey;

/// The directory the browser uses unless the player configures another one.
pub const default_origin = "https://directory.openreliant.space";

const Page = struct {
    listings: []const Listing,
    next: ?usize,
};

const Listing = struct {
    key: []const u8,
    session: []const u8,
    address: []const u8,
    advertisement: struct {
        name: []const u8,
        description: []const u8 = "",
        mode: ?struct { id: []const u8, name: []const u8 } = null,
        players: u16,
        capacity: u16,
        protocol: u32,
    },
};
const Identity = struct { key: [32]u8, session: [16]u8 };
const Result = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Connection.Server,

    fn deinit(result: *Result) void {
        result.arena.deinit();
    }
};
const Job = struct {
    origins: []const u8,

    pub fn deinit(job: *Job) void {
        web.allocator.free(job.origins);
    }
    pub fn discard(result: Result) void {
        var owned = result;
        owned.deinit();
    }

    pub fn run(job: *Job, io: std.Io, progress: *web.Progress) !Result {
        var arena = std.heap.ArenaAllocator.init(web.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        var rows: std.ArrayList(Connection.Server) = .empty;
        var identities: std.ArrayList(Identity) = .empty;
        var answered = false;
        var origins = std.mem.splitScalar(u8, job.origins, ',');
        while (origins.next()) |part| {
            const origin = std.mem.trim(u8, part, " \t/");
            if (origin.len == 0) continue;
            var cursor: usize = 0;
            for (0..16) |_| {
                const url = try std.fmt.allocPrint(allocator, "{s}/v1/listings?game=org.openreliant.starlancer&cursor={d}", .{ origin, cursor });
                const response = fetchPage(io, url, progress) catch break;
                defer web.allocator.free(response);
                const next_page = appendPage(allocator, response, &rows, &identities) catch break;
                answered = true;
                const next = next_page orelse break;
                if (next <= cursor) break;
                cursor = next;
            }
        }
        if (!answered) return error.DirectoryUnavailable;
        @import("browser_ping.zig").measure(io, rows.items);
        return .{ .arena = arena, .rows = try rows.toOwnedSlice(allocator) };
    }
};

fn fetchPage(io: std.Io, url: []const u8, progress: *web.Progress) ![]u8 {
    const Event = union(enum) { response: void, deadline: std.Io.Cancelable!void };
    var response: ?[]u8 = null;
    errdefer if (response) |body| web.allocator.free(body);
    {
        var events: [2]Event = undefined;
        var select: std.Io.Select(Event) = .init(io, &events);
        defer select.cancelDiscard();
        try select.concurrent(.response, fetchInto, .{ io, url, progress, &response });
        try select.concurrent(.deadline, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(3), .awake });
        _ = try select.await();
    }
    return response orelse error.DirectoryUnavailable;
}

fn fetchInto(io: std.Io, url: []const u8, progress: *web.Progress, response: *?[]u8) void {
    response.* = web.fetch(io, .{ .url = url, .loopback = .of(url) }, 128 * 1024, progress) catch null;
}

fn appendPage(allocator: std.mem.Allocator, response: []const u8, rows: *std.ArrayList(Connection.Server), identities: *std.ArrayList(Identity)) !?usize {
    var temporary = std.heap.ArenaAllocator.init(web.allocator);
    defer temporary.deinit();
    const page = try std.json.parseFromSliceLeaky(Page, temporary.allocator(), response, .{ .ignore_unknown_fields = true });
    for (page.listings) |entry| {
        if (rows.items.len >= 256) break;
        if (entry.advertisement.name.len == 0 or entry.advertisement.name.len > 96 or
            entry.advertisement.description.len > 512 or entry.advertisement.capacity == 0 or
            entry.advertisement.players > entry.advertisement.capacity or entry.advertisement.protocol == 0) continue;
        if (entry.advertisement.mode) |mode| if (mode.name.len > 96) continue;
        var id: Identity = undefined;
        if (entry.key.len != 64 or entry.session.len != 32) continue;
        _ = std.fmt.hexToBytes(&id.key, entry.key) catch continue;
        _ = std.fmt.hexToBytes(&id.session, entry.session) catch continue;
        var duplicate = false;
        for (identities.items) |previous| if (std.mem.eql(u8, &previous.key, &id.key) and std.mem.eql(u8, &previous.session, &id.session)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        const address = std.Io.net.IpAddress.parseLiteral(entry.address) catch continue;
        if (address.getPort() == 0 or !@import("identity.zig").Invite.hasAddress(address)) continue;
        const key = Key.fromBytes(id.key) catch continue;
        const target = try std.fmt.allocPrint(allocator, "{f}", .{DirectoryInvite{ .invite = .{ .address = address, .key = key }, .session = id.session }});
        try rows.append(allocator, .{
            .name = try allocator.dupe(u8, entry.advertisement.name),
            .description = try allocator.dupe(u8, entry.advertisement.description),
            .mode = try allocator.dupe(u8, if (entry.advertisement.mode) |mode| mode.name else ""),
            .players = entry.advertisement.players,
            .capacity = entry.advertisement.capacity,
            .protocol = entry.advertisement.protocol,
            .target = target,
        });
        try identities.append(allocator, id);
    }
    return page.next;
}

test "listings from two directories share one key and session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var rows: std.ArrayList(Connection.Server) = .empty;
    var identities: std.ArrayList(Identity) = .empty;
    const page =
        \\{"listings":[{"key":"a2f337e19ba160c0708622f9cc6f64476ebd3a28d0b698f54778e85fd1991fe3","session":"16098744024934c8f343e2d6c9689d10","address":"8.8.8.8:27020","advertisement":{"name":"Example","players":2,"capacity":8,"protocol":29}}],"next":null}
    ;
    try std.testing.expectEqual(null, try appendPage(allocator, page, &rows, &identities));
    _ = try appendPage(allocator, page, &rows, &identities);
    try std.testing.expectEqual(1, rows.items.len);
    try std.testing.expectEqual(29, rows.items[0].protocol.?);
    const invite = try DirectoryInvite.parse(rows.items[0].target);
    try std.testing.expectEqualStrings("a2f337e19ba160c0708622f9cc6f64476ebd3a28d0b698f54778e85fd1991fe3", &std.fmt.bytesToHex(invite.invite.key.toBytes(), .lower));
}

const Directory = @This();
download: web.Download(Job) = .{},
result: ?Result = null,

pub fn refresh(directory: *Directory, origins: []const u8) void {
    if (directory.download.busy()) return;
    const copy = web.allocator.dupe(u8, origins) catch return;
    directory.download.start(.{ .origins = copy }, .{ .whole = .fromSeconds(15) }) catch |err| std.log.warn("could not browse directories: {t}", .{err});
}

pub fn poll(directory: *Directory, screen: *Connection) void {
    const answer = directory.download.take() orelse return;
    const found = answer catch |err| {
        std.log.warn("could not browse directories: {t}", .{err});
        screen.message = .{ .english = "Could not reach the directory" };
        return;
    };
    // Keep the selected session when a refresh changes the order or player counts.
    const selected = if (screen.source == .internet and directory.result != null and screen.selected < directory.result.?.rows.len)
        directory.result.?.rows[screen.selected].target
    else
        null;
    var match: ?usize = null;
    if (selected) |target| for (found.rows, 0..) |row, index| {
        if (std.mem.eql(u8, target, row.target)) {
            match = index;
            break;
        }
    };
    if (directory.result) |*previous| previous.deinit();
    directory.result = found;
    screen.listings.set(.internet, directory.result.?.rows);
    if (screen.source == .internet) {
        screen.selected = match orelse 0;
        if (match == null) screen.first = 0;
    }
    screen.message = .{};
}

pub fn close(directory: *Directory) void {
    directory.download.abandon();
    if (directory.result) |*result| result.deinit();
}
