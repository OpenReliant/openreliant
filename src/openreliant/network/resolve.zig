//! Resolve a player's direct server address away from the front-end thread.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const web = @import("openreliant").engine.web;

const Job = @This();
name: [net.HostName.max_len]u8 = undefined,
len: usize,
port: u16,

pub fn parse(text: []const u8, default_port: u16) !Job {
    const parts = std.mem.cut(u8, text, ":");
    const host = if (parts) |value| value[0] else text;
    const port = if (parts) |value| std.fmt.parseInt(u16, value[1], 10) catch return error.InvalidAddress else default_port;
    if (port == 0) return error.InvalidAddress;
    _ = net.HostName.init(host) catch return error.InvalidAddress;
    var job: Job = .{ .len = host.len, .port = port };
    @memcpy(job.name[0..host.len], host);
    return job;
}

pub fn run(job: *Job, io: Io, _: *web.Progress) !net.IpAddress {
    var entries: [32]net.HostName.LookupResult = undefined;
    var queue: Io.Queue(net.HostName.LookupResult) = .init(&entries);
    const host = try net.HostName.init(job.name[0..job.len]);
    var lookup = io.async(net.HostName.lookup, .{ host, io, &queue, .{ .port = job.port } });
    defer lookup.cancel(io) catch {};
    var ipv6: ?net.IpAddress = null;
    while (queue.getOne(io)) |entry| switch (entry) {
        .address => |address| switch (address) {
            .ip4 => return address,
            .ip6 => if (ipv6 == null) {
                ipv6 = address;
            },
        },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {
            try lookup.await(io);
            return ipv6 orelse error.UnknownHostName;
        },
    }
}

test "direct host names accept an optional port" {
    const named = try parse("eu.openreliant.space", 27020);
    try std.testing.expectEqualStrings("eu.openreliant.space", named.name[0..named.len]);
    try std.testing.expectEqual(27020, named.port);
    try std.testing.expectEqual(27024, (try parse("eu.openreliant.space:27024", 27020)).port);
    try std.testing.expectError(error.InvalidAddress, parse("eu.openreliant.space:0", 27020));
    try std.testing.expectError(error.InvalidAddress, parse("eu.openreliant.space:bad", 27020));
    try std.testing.expectError(error.InvalidAddress, parse("not/a/host", 27020));
}
