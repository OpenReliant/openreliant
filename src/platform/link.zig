//! The editor link's transport (`engine.link.Transport`, docs/engine/editor-link.md): a TCP
//! connection on the machine's own address, 127.0.0.1, in place of the original's block of named
//! shared memory. It takes one editor at a time, and another that connects waits until the first
//! goes. A task of its own accepts the editor and reads what it sends, which the game takes once a
//! frame. The game writes to the editor itself.
//!
//! The task stops without being cancelled, which doesn't wake an `accept` on every system: the
//! server shuts the editor's connection down to end its read, and connects to its own port to wake
//! its `accept`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const link = @import("openreliant").engine.link;

const log = std.log.scoped(.link);

/// The port an editor connects to, unless the options give another.
pub const default_port = 22539;

/// The most bytes the transport keeps for the game to take. Past it, the editor has sent more than
/// a few of the longest messages the link takes while the game took none, and the transport drops
/// the connection.
const most_waiting = 4 * (link.header_size + link.max_payload);

/// How many bytes a read takes at most.
const read_size = 16 * 1024;

/// How many bytes of the game's a write gathers before they go out.
const write_size = 256;

/// How long the task waits before it accepts again, after an accept failed.
const retry_ms = 1000;

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    listener: Io.net.Server,
    /// Guards what follows, which the task and the game share.
    mutex: Io.Mutex = .init,
    /// The editor's connection; null while none is.
    stream: ?Io.net.Stream = null,
    /// The connection's number, which changes with each; null while none is.
    session: ?u32 = null,
    sessions: u32 = 0,
    /// The bytes the editor sent that the game hasn't taken.
    received: std.ArrayList(u8) = .empty,
    /// Set as the server stops, which ends the task.
    stopping: bool = false,
    /// Held while the game writes to the connection, which the task waits for before it closes it.
    writing: Io.Mutex = .init,
    task: Io.Group = .init,

    /// Listens on 127.0.0.1 at `port`, and starts the task that accepts the editor. The server
    /// mustn't move once started.
    pub fn start(server: *Server, gpa: Allocator, io: Io, port: u16) !void {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        server.* = .{ .gpa = gpa, .io = io, .listener = try address.listen(io, .{ .reuse_address = true }) };
        errdefer server.listener.deinit(io);
        try server.task.concurrent(io, serve, .{server});
    }

    /// Stops the task, and closes the connection and the port.
    pub fn stop(server: *Server) void {
        const io = server.io;
        server.mutex.lockUncancelable(io);
        server.stopping = true;
        if (server.stream) |stream| shutDown(io, stream);
        server.mutex.unlock(io);
        // The task may wait for an editor to connect: a connection of its own wakes it.
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(server.listeningPort()) };
        if (address.connect(io, .{ .mode = .stream })) |waking| waking.close(io) else |_| {}
        server.task.await(io) catch {};
        server.listener.deinit(io);
        server.received.deinit(server.gpa);
    }

    /// The port it listens at, which the system picks where `start` was given 0.
    pub fn listeningPort(server: *const Server) u16 {
        return server.listener.socket.address.getPort();
    }

    pub fn transport(server: *Server) link.Transport {
        return .{ .context = server, .vtable = &.{ .session = currentSession, .read = read, .write = write, .drop = drop } };
    }

    /// The task: accepts an editor, reads what it sends until it goes, and accepts the next, until
    /// the server stops.
    fn serve(server: *Server) Io.Cancelable!void {
        const io = server.io;
        while (true) {
            const stream = server.listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    if (server.stopped()) return;
                    log.warn("the editor link can't take a connection: {s}", .{@errorName(err)});
                    try io.sleep(.fromMilliseconds(retry_ms), .awake);
                    continue;
                },
            };
            const session = server.open(stream) orelse {
                stream.close(io);
                return;
            };
            try server.receive(stream, session);
        }
    }

    fn stopped(server: *Server) bool {
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        return server.stopping;
    }

    /// Takes `stream` as the editor's connection, and gives its number; null as the server stops.
    fn open(server: *Server, stream: Io.net.Stream) ?u32 {
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        if (server.stopping) return null;
        server.stream = stream;
        server.sessions +%= 1;
        server.session = server.sessions;
        server.received.clearRetainingCapacity();
        log.info("an editor connected", .{});
        return server.sessions;
    }

    /// Reads what the editor sends on `stream`, connection `session`, until it goes, then closes
    /// the connection.
    fn receive(server: *Server, stream: Io.net.Stream, session: u32) Io.Cancelable!void {
        defer server.close(stream, session);
        var buffer: [read_size]u8 = undefined;
        var reader = stream.reader(server.io, &buffer);
        while (true) {
            const bytes = reader.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => {
                    if (reader.err) |failed| if (failed == error.Canceled) return error.Canceled;
                    return;
                },
            };
            if (!server.keep(session, bytes)) return;
            reader.interface.toss(bytes.len);
        }
    }

    /// Keeps `bytes` of connection `session` for the game; false where the connection has gone,
    /// or the game has left too many.
    fn keep(server: *Server, session: u32, bytes: []const u8) bool {
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        if (server.session != session) return false;
        if (server.received.items.len + bytes.len > most_waiting) {
            log.warn("the editor sent more than the game takes, so the link drops the connection", .{});
            return false;
        }
        server.received.appendSlice(server.gpa, bytes) catch {
            log.warn("the editor link has no memory left for the editor's messages, so it drops the connection", .{});
            return false;
        };
        return true;
    }

    /// Closes `stream`, connection `session`, once the game has finished writing to it.
    fn close(server: *Server, stream: Io.net.Stream, session: u32) void {
        const io = server.io;
        server.writing.lockUncancelable(io);
        defer server.writing.unlock(io);
        server.mutex.lockUncancelable(io);
        server.stream = null;
        if (server.session == session) {
            server.session = null;
            server.received.clearRetainingCapacity();
        }
        server.mutex.unlock(io);
        stream.close(io);
        log.info("the editor went", .{});
    }

    fn currentSession(context: *anyopaque) ?u32 {
        const server: *Server = @ptrCast(@alignCast(context));
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        return server.session;
    }

    fn read(context: *anyopaque, session: u32, into: []u8) usize {
        const server: *Server = @ptrCast(@alignCast(context));
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        if (server.session != session) return 0;
        const count = @min(into.len, server.received.items.len);
        @memcpy(into[0..count], server.received.items[0..count]);
        server.received.replaceRangeAssumeCapacity(0, count, &.{});
        return count;
    }

    fn write(context: *anyopaque, session: u32, bytes: []const u8) void {
        const server: *Server = @ptrCast(@alignCast(context));
        const io = server.io;
        server.writing.lockUncancelable(io);
        defer server.writing.unlock(io);
        server.mutex.lockUncancelable(io);
        const current = if (server.session == session) server.stream else null;
        server.mutex.unlock(io);
        const stream = current orelse return;
        var buffer: [write_size]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(bytes) catch return shutDown(io, stream);
        writer.interface.flush() catch return shutDown(io, stream);
    }

    fn drop(context: *anyopaque, session: u32) void {
        const server: *Server = @ptrCast(@alignCast(context));
        const io = server.io;
        server.mutex.lockUncancelable(io);
        defer server.mutex.unlock(io);
        if (server.session != session) return;
        server.session = null;
        server.received.clearRetainingCapacity();
        if (server.stream) |stream| shutDown(io, stream);
    }

    /// Shuts a connection down that failed, that the game drops or that the server stops with: the
    /// task's read then ends, and it closes the connection.
    fn shutDown(io: Io, stream: Io.net.Stream) void {
        stream.shutdown(io, .both) catch {};
    }
};

test Server {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var server: Server = undefined;
    try server.start(gpa, io, 0);
    defer server.stop();
    const transport = server.transport();
    try std.testing.expectEqual(null, transport.vtable.session(transport.context));

    // An editor connects and sends a message, which the game takes.
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(server.listeningPort()) };
    const editor = try address.connect(io, .{ .mode = .stream });
    defer editor.close(io);
    const session = try waitFor(io, transport, struct {
        fn connected(t: link.Transport) ?u32 {
            return t.vtable.session(t.context);
        }
    }.connected);
    var write_buffer: [16]u8 = undefined;
    var editor_writer = editor.writer(io, &write_buffer);
    try editor_writer.interface.writeAll("hello");
    try editor_writer.interface.flush();
    var taken: [16]u8 = undefined;
    var count: usize = 0;
    for (0..waits) |_| {
        count += transport.vtable.read(transport.context, session, taken[count..]);
        if (count == 5) break;
        try io.sleep(.fromMilliseconds(wait_ms), .awake);
    }
    try std.testing.expectEqualStrings("hello", taken[0..count]);

    // What the game writes reaches the editor.
    transport.vtable.write(transport.context, session, "back");
    var reply: [4]u8 = undefined;
    var read_buffer: [16]u8 = undefined;
    var editor_reader = editor.reader(io, &read_buffer);
    try editor_reader.interface.readSliceAll(&reply);
    try std.testing.expectEqualStrings("back", &reply);

    // Dropped, the connection goes, and its bytes with it.
    transport.vtable.drop(transport.context, session);
    try std.testing.expectEqual(null, transport.vtable.session(transport.context));
    try std.testing.expectEqual(0, transport.vtable.read(transport.context, session, &taken));
}

/// How many times, and how long apart, the test looks for what the task does.
const waits = 200;
const wait_ms = 10;

/// What `found` gives once it gives anything, looking `waits` times.
fn waitFor(io: Io, transport: link.Transport, found: fn (link.Transport) ?u32) !u32 {
    for (0..waits) |_| {
        if (found(transport)) |value| return value;
        try io.sleep(.fromMilliseconds(wait_ms), .awake);
    }
    return error.Timeout;
}
