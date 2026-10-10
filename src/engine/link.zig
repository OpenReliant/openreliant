//! OpenReliant's editor link (docs/engine/editor-link.md): the link the original keeps with Digital
//! Anvil's mission editor and script debugger, carried over a transport that works on every system
//! in place of the original's block of shared memory. This module is the part no game owns: how the
//! messages travel, framed on a stream of bytes (`Header`), and whether an editor is there. A game
//! acts on the messages itself (StarLancer's in `game.mission.editor`), and a script VM reports
//! through it where a thread stopped (`vm.editor`).
//!
//! **Improvement:** the original reads the editor's messages only while a mission's script starts
//! (`editor_link_check`, `0x00457670`); OpenReliant reads them every frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const log = std.log.scoped(.link);

/// A message: its tag, and its payload.
pub const Message = struct {
    tag: u16,
    payload: []const u8,
};

/// How a message is framed on the stream, little-endian: its tag, a halfword that is always 0, and
/// its payload's size, then the payload. The original's entries keep the tag, a halfword for the
/// size and the payload's offset in the block (`editor_link_post`, `0x00457A80`). Its table copies
/// take their sizes from the mission's own counts, so a payload can run past what a halfword
/// counts, and the stream counts it in a word.
pub const Header = extern struct {
    tag: u16,
    reserved: u16 = 0,
    size: u32,

    comptime {
        assert(@offsetOf(Header, "reserved") == 2);
        assert(@offsetOf(Header, "size") == 4);
        assert(@sizeOf(Header) == header_size);
    }
};

pub const header_size = 8;

/// The longest payload taken: the whole of the original's block (`editor_link_create`,
/// `0x00457B90`), which no message of the original fills. A longer one drops the connection.
pub const max_payload = 0xD4A08;

/// The tags OpenReliant adds to the original's, past them, which the original stops the game on.
/// Each payload is text, a `key=value` line for each field, so any client reads it; only
/// `mission_file`'s is the file's bytes.
///
/// **Improvement:** the original's editor knew the mission from its own copy of it, and its
/// debugger only heard where the script stopped.
pub const Own = enum(u16) {
    /// As an editor connects: the link's protocol (`protocol_version`), OpenReliant's version, the
    /// game and its script VM's dialect (`Game`).
    hello = 0x100,
    /// A mission's script starts: its number and its file.
    mission_started = 0x101,
    /// The mission ends.
    mission_ended = 0x102,
    /// From the editor: asks for the mission's file, which the game answers with `mission_file`.
    get_mission = 0x103,
    /// The mission's file as the game runs it, with the script's globals as they stand.
    mission_file = 0x104,
    /// From the editor: asks for the script's state, which the game answers with `state`.
    get_state = 0x105,
    /// The script's state: its clock, the editor's hold, step and pause, the threads, the globals
    /// and the game's variables.
    state = 0x106,
    _,

    /// `tag` as one of OpenReliant's own; null for one of the original's.
    pub fn of(tag: u16) ?Own {
        return if (tag >= @backingInt(Own.hello)) @fromBackingInt(@intCast(tag)) else null;
    }
};

/// The version of the link's own messages, which `Own.hello` gives.
pub const protocol_version = 1;

/// A game on the engine, as the link names it to an editor (`Own.hello`).
pub const Game = struct {
    /// Its name, such as StarLancer.
    name: []const u8,
    /// Its script VM's dialect, which tells a client how to read the mission's scripts.
    vm: []const u8,
};

/// What the link reads from and writes to: a connection to at most one editor at a time.
pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The connection an editor is on, a number that changes with each connection, or null
        /// while none is.
        session: *const fn (context: *anyopaque) ?u32,
        /// Moves up to `into.len` of the bytes connection `session` sent into `into`, and gives
        /// how many: none once the connection has gone.
        read: *const fn (context: *anyopaque, session: u32, into: []u8) usize,
        /// Sends `bytes` on connection `session`, in order; nothing once it has gone.
        write: *const fn (context: *anyopaque, session: u32, bytes: []const u8) void,
        /// Drops connection `session`, as one that sent what isn't a message.
        drop: *const fn (context: *anyopaque, session: u32) void,
    };
};

/// What `Link.next` found since the last call.
pub const Event = union(enum) {
    /// An editor connected, which the link has greeted (`Own.hello`).
    connected,
    /// The editor went.
    disconnected,
    /// A message, whose payload stays until the next call.
    message: Message,
};

pub const Link = struct {
    gpa: Allocator,
    transport: Transport,
    /// The game, and OpenReliant's version, which the hello gives.
    game: Game,
    version: []const u8,
    /// The bytes received and not yet taken as messages.
    received: std.ArrayList(u8) = .empty,
    /// The bytes at the start of `received` that the last message given out took.
    taken: usize = 0,
    /// The connection the bytes came from; null while none is.
    session: ?u32 = null,

    /// How many bytes a read takes at most.
    const read_size = 64 * 1024;

    pub fn init(gpa: Allocator, transport: Transport, game: Game, version: []const u8) Link {
        return .{ .gpa = gpa, .transport = transport, .game = game, .version = version };
    }

    pub fn deinit(link: *Link) void {
        link.received.deinit(link.gpa);
    }

    /// Whether an editor is there: for as long as it stays connected.
    ///
    /// The original counts the checks in a row that find no message, and takes the editor as gone
    /// on the 513th (`editor_link_check`, `0x004576BB`): its block can't tell it the editor went. A
    /// connection can.
    pub fn present(link: *const Link) bool {
        return link.session != null;
    }

    /// What the caller takes from `next`.
    pub const Taking = enum {
        /// Connections and messages.
        all,
        /// Only an editor connecting or going: the messages wait for a later call.
        connections,
    };

    /// What happened since the last call: an editor connecting or going, or a message. The caller
    /// takes events until none is left, each frame; a message's payload lasts until the next call.
    /// As an editor connects, the link greets it (`Own.hello`).
    pub fn next(link: *Link, taking: Taking) ?Event {
        link.dropTaken();
        const now = link.transport.vtable.session(link.transport.context);
        if (now != link.session) {
            link.received.clearRetainingCapacity();
            // A new connection where another was ends that one first.
            if (link.session != null) {
                link.session = null;
                return .disconnected;
            }
            link.session = now;
            link.hello();
            return .connected;
        }
        const session = link.session orelse return null;
        if (taking == .connections) return null;
        link.receive(session) catch {
            link.dropConnection("the link has no memory left for the editor's messages", .{});
            return null;
        };
        if (link.received.items.len < header_size) return null;
        const header = std.mem.bytesToValue(Header, link.received.items[0..header_size]);
        if (header.size > max_payload) {
            link.dropConnection("the editor sent a message of {d} bytes, past the {d} the link takes", .{ header.size, max_payload });
            return null;
        }
        if (link.received.items.len - header_size < header.size) return null;
        link.taken = header_size + header.size;
        return .{ .message = .{ .tag = header.tag, .payload = link.received.items[header_size..link.taken] } };
    }

    /// Drops the editor's connection, and says why.
    fn dropConnection(link: *Link, comptime why: []const u8, arguments: anytype) void {
        log.warn(why ++ ", so it drops the connection", arguments);
        if (link.session) |session| link.transport.vtable.drop(link.transport.context, session);
        link.received.clearRetainingCapacity();
    }

    /// Greets an editor that connected (`Own.hello`).
    fn hello(link: *Link) void {
        link.sendFields(.hello, &.{
            .{ .key = "protocol", .value = std.fmt.comptimePrint("{d}", .{protocol_version}) },
            .{ .key = "openreliant", .value = link.version },
            .{ .key = "game", .value = link.game.name },
            .{ .key = "vm", .value = link.game.vm },
        });
    }

    /// Sends a message to the editor connected; nothing where none is.
    pub fn send(link: *Link, tag: u16, payload: []const u8) void {
        const session = link.session orelse return;
        const header: Header = .{ .tag = tag, .size = @intCast(payload.len) };
        link.transport.vtable.write(link.transport.context, session, std.mem.asBytes(&header));
        if (payload.len > 0) link.transport.vtable.write(link.transport.context, session, payload);
    }

    /// Sends one of OpenReliant's own messages, `fields` as its `key=value` lines.
    pub fn sendFields(link: *Link, tag: Own, fields: []const Field) void {
        var buffer: [fields_size]u8 = undefined;
        var text: std.Io.Writer = .fixed(&buffer);
        for (fields) |line| text.print("{s}={s}\n", .{ line.key, line.value }) catch {
            log.warn("the link's message {d} is too long for its buffer, so it's cut short", .{@backingInt(tag)});
            break;
        };
        link.send(@backingInt(tag), text.buffered());
    }

    /// A field of one of OpenReliant's own messages.
    pub const Field = struct { key: []const u8, value: []const u8 };

    /// The most text one of OpenReliant's own messages takes.
    const fields_size = 1024;

    fn dropTaken(link: *Link) void {
        link.received.replaceRangeAssumeCapacity(0, link.taken, &.{});
        link.taken = 0;
    }

    /// Takes the bytes waiting into `received`.
    fn receive(link: *Link, session: u32) Allocator.Error!void {
        while (true) {
            try link.received.ensureUnusedCapacity(link.gpa, read_size);
            const room = link.received.unusedCapacitySlice();
            const count = link.transport.vtable.read(link.transport.context, session, room[0..read_size]);
            if (count == 0) return;
            link.received.items.len += count;
        }
    }
};

/// Writes a message to `writer`, framed (`Header`): how an editor sends to the game.
pub fn writeMessage(writer: *std.Io.Writer, tag: u16, payload: []const u8) std.Io.Writer.Error!void {
    const header: Header = .{ .tag = tag, .size = @intCast(payload.len) };
    try writer.writeAll(std.mem.asBytes(&header));
    try writer.writeAll(payload);
}

/// Reads the next message from `reader`, its payload made in `gpa`, which the caller frees: how an
/// editor hears the game.
pub fn readMessage(reader: *std.Io.Reader, gpa: Allocator) std.Io.Reader.ReadAllocError!Message {
    var header: Header = undefined;
    try reader.readSliceAll(std.mem.asBytes(&header));
    return .{ .tag = header.tag, .payload = try reader.readAllocAll(gpa, header.size) };
}

/// The text field `key` of one of OpenReliant's own messages, null where it has none.
pub fn field(payload: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line| {
        const equals = std.mem.findScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..equals], key)) return line[equals + 1 ..];
    }
    return null;
}

pub const testing = struct {
    /// A transport in memory: what an editor sends waits in `to_game`, and what the game sends goes
    /// into `to_editor`.
    pub const Pipe = struct {
        gpa: Allocator,
        connection: ?u32 = null,
        to_game: std.ArrayList(u8) = .empty,
        to_editor: std.ArrayList(u8) = .empty,
        dropped: bool = false,

        pub fn deinit(pipe: *Pipe) void {
            pipe.to_game.deinit(pipe.gpa);
            pipe.to_editor.deinit(pipe.gpa);
        }

        pub fn transport(pipe: *Pipe) Transport {
            return .{ .context = pipe, .vtable = &.{ .session = session, .read = read, .write = write, .drop = drop } };
        }

        /// An editor connects.
        pub fn connect(pipe: *Pipe) void {
            pipe.connection = (pipe.connection orelse 0) + 1;
            pipe.dropped = false;
        }

        /// The editor sends a message.
        pub fn sendToGame(pipe: *Pipe, tag: u16, payload: []const u8) Allocator.Error!void {
            const header: Header = .{ .tag = tag, .size = @intCast(payload.len) };
            try pipe.to_game.appendSlice(pipe.gpa, std.mem.asBytes(&header));
            try pipe.to_game.appendSlice(pipe.gpa, payload);
        }

        /// The next message the game sent, taken off what it sent; null for none.
        pub fn takeFromGame(pipe: *Pipe, payload: []u8) ?Message {
            if (pipe.to_editor.items.len < header_size) return null;
            const header = std.mem.bytesToValue(Header, pipe.to_editor.items[0..header_size]);
            const length = header_size + header.size;
            @memcpy(payload[0..header.size], pipe.to_editor.items[header_size..length]);
            pipe.to_editor.replaceRangeAssumeCapacity(0, length, &.{});
            return .{ .tag = header.tag, .payload = payload[0..header.size] };
        }

        fn session(context: *anyopaque) ?u32 {
            const pipe: *Pipe = @ptrCast(@alignCast(context));
            return if (pipe.dropped) null else pipe.connection;
        }

        fn read(context: *anyopaque, connection: u32, into: []u8) usize {
            const pipe: *Pipe = @ptrCast(@alignCast(context));
            if (session(context) != connection) return 0;
            const count = @min(into.len, pipe.to_game.items.len);
            @memcpy(into[0..count], pipe.to_game.items[0..count]);
            pipe.to_game.replaceRangeAssumeCapacity(0, count, &.{});
            return count;
        }

        fn write(context: *anyopaque, connection: u32, bytes: []const u8) void {
            const pipe: *Pipe = @ptrCast(@alignCast(context));
            if (session(context) != connection) return;
            pipe.to_editor.appendSlice(pipe.gpa, bytes) catch {};
        }

        fn drop(context: *anyopaque, connection: u32) void {
            const pipe: *Pipe = @ptrCast(@alignCast(context));
            if (session(context) != connection) return;
            pipe.dropped = true;
            pipe.to_game.clearRetainingCapacity();
        }
    };
};

/// A game for the tests.
const example: Game = .{ .name = "Example", .vm = "example" };

test Link {
    const gpa = std.testing.allocator;
    var pipe: testing.Pipe = .{ .gpa = gpa };
    defer pipe.deinit();
    var link: Link = .init(gpa, pipe.transport(), example, "1.2.3");
    defer link.deinit();
    // Nobody there: nothing happens, and nothing is sent.
    try std.testing.expectEqual(null, link.next(.all));
    link.send(0x1A, "abcd");
    try std.testing.expectEqual(0, pipe.to_editor.items.len);

    // An editor connects, the link greets it, and its messages come whole, even split across
    // reads.
    pipe.connect();
    try std.testing.expectEqual(Event.connected, link.next(.all).?);
    try std.testing.expect(link.present());
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqual(@backingInt(Own.hello), pipe.takeFromGame(&buffer).?.tag);
    try pipe.sendToGame(0x15, &.{ 1, 0, 0, 0 });
    try pipe.sendToGame(0x13, "");
    const half = pipe.to_game.items.len - header_size + 2;
    const tail = try gpa.dupe(u8, pipe.to_game.items[half..]);
    defer gpa.free(tail);
    pipe.to_game.shrinkRetainingCapacity(half);
    // Taking only the connections leaves the messages waiting.
    try std.testing.expectEqual(null, link.next(.connections));
    const first = link.next(.all).?.message;
    try std.testing.expectEqual(0x15, first.tag);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, first.payload);
    try std.testing.expectEqual(null, link.next(.all));
    try pipe.to_game.appendSlice(gpa, tail);
    try std.testing.expectEqual(0x13, link.next(.all).?.message.tag);
    try std.testing.expectEqual(null, link.next(.all));

    // What the game sends reaches the editor framed.
    link.send(0x1A, &.{ 7, 0, 0, 0 });
    const sent = pipe.takeFromGame(&buffer).?;
    try std.testing.expectEqual(0x1A, sent.tag);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 0, 0 }, sent.payload);

    // A message longer than the link takes drops the connection.
    const header: Header = .{ .tag = 3, .size = max_payload + 1 };
    try pipe.to_game.appendSlice(gpa, std.mem.asBytes(&header));
    try std.testing.expectEqual(null, link.next(.all));
    try std.testing.expect(pipe.dropped);
    try std.testing.expectEqual(Event.disconnected, link.next(.all).?);
    try std.testing.expect(!link.present());

    // A new connection where one was ends that one first.
    pipe.connect();
    try std.testing.expectEqual(Event.connected, link.next(.all).?);
    pipe.connect();
    try std.testing.expectEqual(Event.disconnected, link.next(.all).?);
    try std.testing.expectEqual(Event.connected, link.next(.all).?);
}

test "OpenReliant's own messages are key=value lines" {
    const gpa = std.testing.allocator;
    var pipe: testing.Pipe = .{ .gpa = gpa };
    defer pipe.deinit();
    var link: Link = .init(gpa, pipe.transport(), example, "1.2.3");
    defer link.deinit();
    pipe.connect();
    _ = link.next(.all);
    var buffer: [128]u8 = undefined;
    const hello = pipe.takeFromGame(&buffer).?;
    try std.testing.expectEqual(@backingInt(Own.hello), hello.tag);
    try std.testing.expectEqualStrings("1", field(hello.payload, "protocol").?);
    try std.testing.expectEqualStrings("1.2.3", field(hello.payload, "openreliant").?);
    try std.testing.expectEqualStrings("Example", field(hello.payload, "game").?);
    try std.testing.expectEqualStrings("example", field(hello.payload, "vm").?);
    try std.testing.expectEqual(null, field(hello.payload, "mission"));
}

test "an editor writes and reads messages framed" {
    const gpa = std.testing.allocator;
    var bytes: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try writeMessage(&writer, 0x15, &.{ 2, 0, 0, 0 });
    try writeMessage(&writer, @backingInt(Own.get_state), "");
    var reader: std.Io.Reader = .fixed(writer.buffered());
    const first = try readMessage(&reader, gpa);
    defer gpa.free(first.payload);
    try std.testing.expectEqual(0x15, first.tag);
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, first.payload);
    const second = try readMessage(&reader, gpa);
    defer gpa.free(second.payload);
    try std.testing.expectEqual(Own.get_state, Own.of(second.tag).?);
    try std.testing.expectError(error.EndOfStream, readMessage(&reader, gpa));
}
