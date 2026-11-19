//! Transport checks that run without opening a socket.
test {
    _ = @import("incoming_connections.zig");
    _ = @import("beacon_snapshot.zig");
    _ = @import("beacon_arena.zig");
}
