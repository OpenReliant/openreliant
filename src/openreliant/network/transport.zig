//! Private transport calls. The connection callback runs on the polling thread.
const wire = @import("wire.zig");

pub const Connection = u32;
pub const Status = enum(c_int) { incoming, authenticated, closed, unverified, lost, dropped };
pub extern fn session_init(root: ?[*]const u8, root_size: usize, certificate: ?[*]const u8, size: c_int, max_message: c_int) bool;
pub extern fn session_set_certificate(certificate: [*]const u8, size: c_int) bool;
pub extern fn session_deinit() void;
pub extern fn session_open(address: [*:0]const u8, host: bool) u32;
pub extern fn session_local_pair(server: *Connection, client: *Connection) bool;
pub extern fn session_peer_ip(conn: Connection, address: *[16]u8) bool;
pub extern fn session_ping_ms(conn: Connection) c_int;
pub extern fn session_listen_close(listener: u32) void;
pub extern fn session_accept(conn: Connection) bool;
pub extern fn session_close(conn: Connection) void;
pub extern fn session_drop(conn: Connection) void;
pub extern fn session_poll() void;
pub extern fn session_key() u8;
extern fn session_send(conn: Connection, bytes: [*]const u8, size: c_int, reliable: bool) bool;
extern fn session_receive(conn: Connection, bytes: [*]u8, size: c_int) c_int;

/// Game message payloads queued to and delivered by the transport.
pub const Traffic = struct {
    sent: Counts = .{},
    received: Counts = .{},

    pub const Counts = struct {
        messages: u64 = 0,
        bytes: u64 = 0,

        fn add(counts: *Counts, bytes: usize) void {
            counts.messages += 1;
            counts.bytes += bytes;
        }
    };
};

pub const Channel = struct {
    traffic: ?*Traffic = null,

    pub fn send(channel: Channel, conn: Connection, message: wire.Message) !void {
        var buf: [wire.capacity]u8 = undefined;
        const bytes = try message.encode(&buf);
        const reliable = switch (message) {
            .input, .view, .combat, .projectiles, .scene_page, .pilot_page, .own_flight => false,
            else => true,
        };
        try channel.sendBytes(conn, bytes, reliable);
    }

    pub fn sendBytes(channel: Channel, conn: Connection, bytes: []const u8, reliable: bool) error{SendFailed}!void {
        if (!session_send(conn, bytes.ptr, @intCast(bytes.len), reliable)) return error.SendFailed;
        if (channel.traffic) |traffic| traffic.sent.add(bytes.len);
    }

    pub fn receive(channel: Channel, conn: Connection, buf: *[wire.capacity]u8) !?wire.Message {
        const n = session_receive(conn, buf, buf.len);
        if (n < 0) return error.ReceiveFailed;
        if (n == 0) return null;
        const bytes = buf[0..@intCast(n)];
        if (channel.traffic) |traffic| traffic.received.add(bytes.len);
        return try wire.Message.decode(bytes);
    }
};

pub fn send(conn: Connection, message: wire.Message) !void {
    try (Channel{}).send(conn, message);
}

pub fn receive(conn: Connection, buf: *[wire.capacity]u8) !?wire.Message {
    return (Channel{}).receive(conn, buf);
}
