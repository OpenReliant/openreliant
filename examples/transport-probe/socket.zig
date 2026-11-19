//! Private packet interface shared by the transport workloads.
pub const Connection = u32;
pub const Packet = struct { bytes: []const u8, lane: u16 };

pub extern fn probe_open(address: [*:0]const u8, host: bool, max_message_size: c_int) bool;
extern fn probe_send(conn: Connection, lane: u16, data: [*]const u8, size: c_int) bool;
extern fn probe_receive(conn: Connection, data: [*]u8, capacity: c_int, lane: *u16) c_int;
pub extern fn probe_close(conn: Connection) bool;
pub extern fn probe_now() i64;
pub extern fn probe_poll() bool;
pub extern fn probe_delivered(conn: Connection) bool;

pub fn send(conn: Connection, lane: u16, bytes: []const u8) !void {
    if (!probe_send(conn, lane, bytes.ptr, @intCast(bytes.len))) return error.SendFailed;
}

pub fn receive(conn: Connection, buffer: []u8) !?Packet {
    var lane: u16 = undefined;
    const count = probe_receive(conn, buffer.ptr, @intCast(buffer.len), &lane);
    if (count < 0) return error.ReceiveFailed;
    if (count == 0) return null;
    return .{ .bytes = buffer[0..@intCast(count)], .lane = lane };
}
