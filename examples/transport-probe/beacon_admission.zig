//! Nonblocking protocol check for a signed Six Beacons connection.
const std = @import("std");
const socket = @import("socket.zig");
const wire = @import("beacon_snapshot.zig");
const version = @import("version").string;

pub const timeout = 3 * std.time.us_per_s;

// This revision belongs to the probe protocol. App releases can share a revision.
pub const protocol_revision: u16 = 2;

pub fn sendVersion(conn: socket.Connection, message: wire.Message, revision: u16, release: []const u8) !void {
    var buffer: [wire.capacity]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try out.writeByte(@backingInt(message));
    try out.writeInt(u16, revision, .little);
    try out.writeAll(release);
    try socket.send(conn, wire.lane, out.buffered());
}

pub const Version = struct {
    revision: u16,
    release: []const u8,

    pub fn read(bytes: []const u8, message: wire.Message) !Version {
        var in = std.Io.Reader.fixed(bytes);
        if (try in.takeEnum(wire.Message, .little) != message) return error.UnexpectedMessage;
        const revision = try in.takeInt(u16, .little);
        const release = in.buffered();
        if (release.len == 0) return error.MissingVersion;
        return .{ .revision = revision, .release = release };
    }
};

pub const Attempt = struct {
    conn: socket.Connection,
    expires: i64,
    start_tick: i32,
    rejected: bool = false,

    pub const Result = enum { pending, compatible, release, silent_timeout };

    /// Reads at most one message. A rejected peer has until the same deadline to read the reply.
    pub fn advance(attempt: *Attempt, current: ?socket.Connection, now: i64) Result {
        if (current != attempt.conn) return .release;
        if (now >= attempt.expires) return if (attempt.rejected) .release else .silent_timeout;
        if (attempt.rejected) return .pending;
        var buffer: [wire.capacity]u8 = undefined;
        const packet = (socket.receive(attempt.conn, &buffer) catch return .release) orelse return .pending;
        if (packet.lane != wire.lane) return .release;
        const request = Version.read(packet.bytes, .join) catch return .release;
        if (request.revision == protocol_revision) return .compatible;
        sendVersion(attempt.conn, .wrong_protocol, protocol_revision, version) catch return .release;
        attempt.rejected = true;
        return .pending;
    }
};
