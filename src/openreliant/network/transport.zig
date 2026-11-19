//! Private transport calls. The connection callback runs on the polling thread.
const wire = @import("wire.zig");

pub const Connection = u32;
pub const Status = enum(c_int) { incoming, authenticated, closed, unverified, lost };
pub extern fn session_init(root: ?[*]const u8, root_size: usize, certificate: ?[*]const u8, size: c_int, max_message: c_int) bool;
pub extern fn session_set_certificate(certificate: [*]const u8, size: c_int) bool;
pub extern fn session_deinit() void;
pub extern fn session_open(address: [*:0]const u8, host: bool) u32;
pub extern fn session_local_pair(server: *Connection, client: *Connection) bool;
pub extern fn session_peer_ip(conn: Connection, address: *[16]u8) bool;
pub extern fn session_listen_close(listener: u32) void;
pub extern fn session_accept(conn: Connection) bool;
pub extern fn session_close(conn: Connection) void;
pub extern fn session_poll() void;
pub extern fn session_key() u8;
extern fn session_send(conn: Connection, bytes: [*]const u8, size: c_int, reliable: bool) bool;
extern fn session_receive(conn: Connection, bytes: [*]u8, size: c_int) c_int;

pub fn send(conn: Connection, message: wire.Message) !void {
    var buf: [wire.capacity]u8 = undefined;
    const bytes = try message.encode(&buf);
    const reliable = switch (message) {
        .input, .view => false,
        else => true,
    };
    try sendBytes(conn, bytes, reliable);
}

pub fn sendBytes(conn: Connection, bytes: []const u8, reliable: bool) error{SendFailed}!void {
    if (!session_send(conn, bytes.ptr, @intCast(bytes.len), reliable)) return error.SendFailed;
}

pub fn receive(conn: Connection, buf: *[wire.capacity]u8) !?wire.Message {
    const n = session_receive(conn, buf, buf.len);
    if (n < 0) return error.ReceiveFailed;
    if (n == 0) return null;
    return try wire.Message.decode(buf[0..@intCast(n)]);
}
