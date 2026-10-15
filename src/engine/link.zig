//! OpenReliant's editor link (docs/engine/editor-link.md): the link the original keeps with its own
//! mission editor and script debugger, carried over a transport that works on every system in
//! place of the original's block of shared memory. This module is the part no game owns: how the
//! messages travel, framed on a stream of bytes (`Header`), whether an editor is there, and the
//! records of OpenReliant's own messages (`Hello`, `MissionStarted`, `State`, `ConsoleLine`), which
//! one side writes and the other reads. A game acts on the messages itself (StarLancer's in
//! `game.mission.editor`), and a script VM reports through it where a thread stopped
//! (`vm.editor`).
//!
//! **Improvement:** the original reads the editor's messages only while a mission's script starts
//! (`editor_link_check`, `0x00457670`); OpenReliant reads them every frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const vm_editor = @import("vm/editor.zig");

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

/// The port the game listens at for an editor, on its own address, 127.0.0.1, unless
/// `--editor-link-port` gives another.
pub const default_port = 22539;

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
    /// and the game's variables, the ships' orders, and what the script did since the last state.
    state = 0x106,
    /// From the editor: a line for the game's console, run as if typed into it (`ConsoleLine`).
    console_line = 0x107,
    _,

    /// `tag` as one of OpenReliant's own; null for one of the original's.
    pub fn of(tag: u16) ?Own {
        return if (tag >= @backingInt(Own.hello)) @fromBackingInt(@intCast(tag)) else null;
    }
};

/// The version of the link's own messages, which `Own.hello` gives. Version 2 adds the console
/// line, and the ships' orders and the script's events to the state.
pub const protocol_version = 2;

/// A game on the engine, as the link names it to an editor (`Own.hello`).
pub const Game = struct {
    /// Its name, such as StarLancer.
    name: []const u8,
    /// Its script VM's dialect, which tells a client how to read the mission's scripts.
    vm: []const u8,
};

/// Why a client can't read one of OpenReliant's own messages: a field it needs is missing, or isn't
/// what the field holds. A reader passes over the keys it doesn't know, so that a newer game's
/// messages still read.
pub const ReadError = error{Invalid};

/// `Own.hello`: the link's protocol (`protocol_version`), OpenReliant's version, and the game with
/// its script VM's dialect.
pub const Hello = struct {
    protocol: u32,
    openreliant: []const u8,
    game: Game,

    pub fn write(hello: Hello, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("protocol={d}\nopenreliant={s}\ngame={s}\nvm={s}\n", .{ hello.protocol, hello.openreliant, hello.game.name, hello.game.vm });
    }

    /// The hello in `payload`, whose text it borrows.
    pub fn read(payload: []const u8) ReadError!Hello {
        return .{
            .protocol = try number(u32, payload, "protocol"),
            .openreliant = try text(payload, "openreliant"),
            .game = .{ .name = try text(payload, "game"), .vm = try text(payload, "vm") },
        };
    }
};

/// `Own.mission_started`: the mission's number, and its file's name, such as `mission1.dte`.
pub const MissionStarted = struct {
    number: u16,
    file: []const u8,

    pub fn write(started: MissionStarted, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("number={d}\nfile={s}\n", .{ started.number, started.file });
    }

    /// The start in `payload`, whose text it borrows.
    pub fn read(payload: []const u8) ReadError!MissionStarted {
        return .{ .number = try number(u16, payload, "number"), .file = try text(payload, "file") };
    }
};

/// `Own.state`: the script's state as the game holds it. Its values are the script's words,
/// unsigned.
pub const State = struct {
    /// The script's clock, in seconds.
    clock: u32,
    /// The editor's hold on the script, its step and its pause of the mission.
    hold: vm_editor.Hold,
    step: vm_editor.Step,
    paused: bool,
    /// Whether the thread pool's first thread has finished: the start parts are done.
    first_finished: bool,
    /// The threads running, in the order of their slots.
    threads: []const Thread,
    /// Each of the mission's globals, by its index.
    globals: []const u32,
    /// The game's variables: each named one, and each other one that isn't 0, by its number.
    variables: []const Variable,
    /// Each of the mission's ships in play, by its index: its order and its target.
    ships: []const Ship = &.{},
    /// What the script did since the last state, in order: the triggers fired and the commands
    /// run.
    events: []const ScriptEvent = &.{},
    /// How many events were left out, past the most the game keeps between two states.
    events_dropped: u32 = 0,

    pub const Thread = struct {
        slot: u32,
        /// Where it is in the script, as an offset; null outside it.
        at: ?u32,
        /// Its call depth.
        depth: u32,
        /// The clock value it waits for; 0 for none.
        wake: u32,
        /// Whether it waits for its trigger.
        interrupted: bool,
        /// The trigger that started it, where one did.
        trigger: ?u32,
    };

    pub const Variable = struct {
        /// The game's name for it, such as `mission_over`, or its number where it has none.
        name: []const u8,
        value: u32,
    };

    pub const Ship = struct {
        /// Its index in the mission's ships, which is also its object's slot.
        index: u16,
        /// Its current order, by its name, or its number where it has none; `none` for no order.
        order: []const u8,
        /// The slot of the ship its order aims at, where it aims at one: a ship's index for one of
        /// the mission's ships.
        target: ?u16,
    };

    pub const ScriptEvent = struct {
        kind: Kind,
        /// The trigger's index in the trigger list, or the command's number in the catalogue.
        index: u32,
        /// When it happened on the script's clock, in milliseconds.
        time: u32,

        pub const Kind = enum { trigger, command };
    };

    /// Writes the state, a `key=value` line for each field: `clock`, `hold`, `step`, `paused` and
    /// `first_finished`; for each thread, by its slot, `thread.N.at` (`none` outside the script),
    /// `thread.N.depth`, `thread.N.wake`, `thread.N.interrupted`, and `thread.N.trigger` where a
    /// trigger started it; `global.N` for each global; `variable.NAME` for each variable; for each
    /// ship in play, by its index, `ship.N.order`, and `ship.N.target` where its order has one;
    /// for each event, from 0, `event.N.kind`, `event.N.index` and `event.N.time`; and
    /// `events_dropped` where some were left out.
    pub fn write(state: State, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("clock={d}\nhold={t}\nstep={t}\npaused={d}\nfirst_finished={d}\n", .{
            state.clock, state.hold, state.step, @intFromBool(state.paused), @intFromBool(state.first_finished),
        });
        for (state.threads) |thread| {
            if (thread.at) |at| try writer.print("thread.{d}.at={d}\n", .{ thread.slot, at }) else try writer.print("thread.{d}.at=none\n", .{thread.slot});
            try writer.print("thread.{d}.depth={d}\nthread.{d}.wake={d}\nthread.{d}.interrupted={d}\n", .{
                thread.slot, thread.depth, thread.slot, thread.wake, thread.slot, @intFromBool(thread.interrupted),
            });
            if (thread.trigger) |trigger| try writer.print("thread.{d}.trigger={d}\n", .{ thread.slot, trigger });
        }
        for (state.globals, 0..) |value, index| try writer.print("global.{d}={d}\n", .{ index, value });
        for (state.variables) |each| try writer.print("variable.{s}={d}\n", .{ each.name, each.value });
        for (state.ships) |ship| {
            try writer.print("ship.{d}.order={s}\n", .{ ship.index, ship.order });
            if (ship.target) |target| try writer.print("ship.{d}.target={d}\n", .{ ship.index, target });
        }
        for (state.events, 0..) |event, index| try writer.print("event.{d}.kind={t}\nevent.{d}.index={d}\nevent.{d}.time={d}\n", .{
            index, event.kind, index, event.index, index, event.time,
        });
        if (state.events_dropped > 0) try writer.print("events_dropped={d}\n", .{state.events_dropped});
    }

    /// The fields of the state that hold one value each.
    const Scalar = enum { clock, hold, step, paused, first_finished, events_dropped };

    /// The fields of a thread, of a ship and of an event.
    const ThreadField = enum { at, depth, wake, interrupted, trigger };
    const ShipField = enum { order, target };
    const EventField = enum { kind, index, time };

    /// An event as its lines are read: its kind is null until a line gives it.
    const ReadEvent = struct { kind: ?ScriptEvent.Kind = null, index: u32 = 0, time: u32 = 0 };

    /// The state in `payload`, its lists made in `arena`, its names borrowed from `payload`. A
    /// global's index fits the 16 bits a mission's directory counts its globals in, and a ship's the
    /// 16 bits of an object's slot. The events are numbered from 0 with none missing, and each has
    /// its kind.
    pub fn read(arena: Allocator, payload: []const u8) (Allocator.Error || ReadError)!State {
        var clock: ?u32 = null;
        var hold: ?vm_editor.Hold = null;
        var step: ?vm_editor.Step = null;
        var paused: ?bool = null;
        var first_finished: ?bool = null;
        var threads: std.ArrayList(Thread) = .empty;
        var globals: std.ArrayList(u32) = .empty;
        var variables: std.ArrayList(Variable) = .empty;
        var ships: std.ArrayList(Ship) = .empty;
        var events: std.ArrayList(ReadEvent) = .empty;
        var events_dropped: u32 = 0;
        var fields: Fields = .of(payload);
        while (fields.next()) |found| {
            const key = found.key;
            const value = found.value;
            if (std.meta.stringToEnum(Scalar, key)) |scalar| switch (scalar) {
                .clock => clock = try parse(u32, value),
                .hold => hold = try named(vm_editor.Hold, value),
                .step => step = try named(vm_editor.Step, value),
                .paused => paused = try flag(value),
                .first_finished => first_finished = try flag(value),
                .events_dropped => events_dropped = try parse(u32, value),
            } else if (std.mem.cutPrefix(u8, key, "thread.")) |rest| {
                const slot_text, const name = std.mem.cutScalar(u8, rest, '.') orelse return error.Invalid;
                const thread = try sortedIn(Thread, "slot", arena, &threads, .{ .slot = try parse(u32, slot_text), .at = null, .depth = 0, .wake = 0, .interrupted = false, .trigger = null });
                if (std.meta.stringToEnum(ThreadField, name)) |thread_field| switch (thread_field) {
                    .at => thread.at = if (std.mem.eql(u8, value, "none")) null else try parse(u32, value),
                    .depth => thread.depth = try parse(u32, value),
                    .wake => thread.wake = try parse(u32, value),
                    .interrupted => thread.interrupted = try flag(value),
                    .trigger => thread.trigger = try parse(u32, value),
                };
            } else if (std.mem.cutPrefix(u8, key, "global.")) |index_text| {
                const index: usize = try parse(u16, index_text);
                if (index >= globals.items.len) try globals.appendNTimes(arena, 0, index + 1 - globals.items.len);
                globals.items[index] = try parse(u32, value);
            } else if (std.mem.cutPrefix(u8, key, "variable.")) |name| {
                try variables.append(arena, .{ .name = name, .value = try parse(u32, value) });
            } else if (std.mem.cutPrefix(u8, key, "ship.")) |rest| {
                const index_text, const name = std.mem.cutScalar(u8, rest, '.') orelse return error.Invalid;
                const ship = try sortedIn(Ship, "index", arena, &ships, .{ .index = try parse(u16, index_text), .order = "none", .target = null });
                if (std.meta.stringToEnum(ShipField, name)) |ship_field| switch (ship_field) {
                    .order => ship.order = value,
                    .target => ship.target = try parse(u16, value),
                };
            } else if (std.mem.cutPrefix(u8, key, "event.")) |rest| {
                const index_text, const name = std.mem.cutScalar(u8, rest, '.') orelse return error.Invalid;
                const index: usize = try parse(u32, index_text);
                if (index > events.items.len) return error.Invalid;
                if (index == events.items.len) try events.append(arena, .{});
                const event = &events.items[index];
                if (std.meta.stringToEnum(EventField, name)) |event_field| switch (event_field) {
                    .kind => event.kind = try named(ScriptEvent.Kind, value),
                    .index => event.index = try parse(u32, value),
                    .time => event.time = try parse(u32, value),
                };
            }
        }
        const read_events = try arena.alloc(ScriptEvent, events.items.len);
        for (read_events, events.items) |*event, found| event.* = .{ .kind = found.kind orelse return error.Invalid, .index = found.index, .time = found.time };
        return .{
            .clock = clock orelse return error.Invalid,
            .hold = hold orelse return error.Invalid,
            .step = step orelse return error.Invalid,
            .paused = paused orelse return error.Invalid,
            .first_finished = first_finished orelse return error.Invalid,
            .threads = threads.items,
            .globals = globals.items,
            .variables = variables.items,
            .ships = ships.items,
            .events = read_events,
            .events_dropped = events_dropped,
        };
    }

    /// The record in `list` whose `key` is `made`'s, where it has one, and otherwise `made`, added
    /// in the order of the records' `key`.
    fn sortedIn(comptime T: type, comptime key: []const u8, arena: Allocator, list: *std.ArrayList(T), made: T) Allocator.Error!*T {
        const wanted = @field(made, key);
        for (list.items) |*item| if (@field(item, key) == wanted) return item;
        var place: usize = list.items.len;
        while (place > 0 and @field(list.items[place - 1], key) > wanted) place -= 1;
        try list.insert(arena, place, made);
        return &list.items[place];
    }

    /// The variable named `name`, where the state has it.
    pub fn variable(state: State, name: []const u8) ?u32 {
        for (state.variables) |each| if (std.mem.eql(u8, each.name, name)) return each.value;
        return null;
    }
};

/// `Own.console_line`: a line for the game's console, run as if typed into it: one of the console's
/// commands, such as `reload`, or Luau in the context the console is in. A line break ends it.
pub const ConsoleLine = struct {
    line: []const u8,

    pub fn write(console: ConsoleLine, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const first, _ = std.mem.cutScalar(u8, console.line, '\n') orelse .{ console.line, "" };
        try writer.print("line={s}\n", .{first});
    }

    /// The line in `payload`, whose text it borrows.
    pub fn read(payload: []const u8) ReadError!ConsoleLine {
        return .{ .line = try text(payload, "line") };
    }
};

/// The `key=value` lines of one of OpenReliant's own messages, in order, passing over a line
/// without `=`.
const Fields = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    const Field = struct { key: []const u8, value: []const u8 };

    fn of(payload: []const u8) Fields {
        return .{ .lines = std.mem.splitScalar(u8, payload, '\n') };
    }

    fn next(fields: *Fields) ?Field {
        while (fields.lines.next()) |line| {
            const key, const value = std.mem.cutScalar(u8, line, '=') orelse continue;
            return .{ .key = key, .value = value };
        }
        return null;
    }
};

/// The text of field `key` of one of OpenReliant's own messages, null where it has none.
fn field(payload: []const u8, key: []const u8) ?[]const u8 {
    var fields: Fields = .of(payload);
    while (fields.next()) |found| if (std.mem.eql(u8, found.key, key)) return found.value;
    return null;
}

/// The text of field `key`, which a message must have.
fn text(payload: []const u8, key: []const u8) ReadError![]const u8 {
    return field(payload, key) orelse error.Invalid;
}

/// The number in field `key`, which a message must have.
fn number(comptime T: type, payload: []const u8, key: []const u8) ReadError!T {
    return parse(T, try text(payload, key));
}

fn parse(comptime T: type, value: []const u8) ReadError!T {
    return std.fmt.parseInt(T, value, 10) catch error.Invalid;
}

/// A field that holds the name of one of `Enum`'s values.
fn named(comptime Enum: type, value: []const u8) ReadError!Enum {
    return std.meta.stringToEnum(Enum, value) orelse error.Invalid;
}

/// A field that is 1 or 0.
fn flag(value: []const u8) ReadError!bool {
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "0")) return false;
    return error.Invalid;
}

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
    const read_size = std.fmt.parseIntSizeSuffix("64KiB", 10) catch unreachable;

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
        /// Connections, and OpenReliant's own messages while one is next: the first of the
        /// original's waits for a later call, and the messages after it with it.
        own,
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
        if (taking == .own and Own.of(header.tag) == null) return null;
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
        const greeting: Hello = .{ .protocol = protocol_version, .openreliant = link.version, .game = link.game };
        link.sendRecord(.hello, greeting);
    }

    /// Sends a message to the editor connected; nothing where none is.
    pub fn send(link: *Link, tag: u16, payload: []const u8) void {
        const session = link.session orelse return;
        const header: Header = .{ .tag = tag, .size = @intCast(payload.len) };
        link.transport.vtable.write(link.transport.context, session, std.mem.asBytes(&header));
        if (payload.len > 0) link.transport.vtable.write(link.transport.context, session, payload);
    }

    /// Sends one of OpenReliant's own messages, `record` written as its `key=value` lines
    /// (`Hello`, `MissionStarted`, `State`, `ConsoleLine`); nothing where no editor is connected.
    pub fn sendRecord(link: *Link, tag: Own, record: anytype) void {
        if (link.session == null) return;
        var payload: std.Io.Writer.Allocating = .init(link.gpa);
        defer payload.deinit();
        record.write(&payload.writer) catch {
            log.warn("the link has no memory left for its message 0x{X}", .{@backingInt(tag)});
            return;
        };
        link.send(@backingInt(tag), payload.written());
    }

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
    try std.testing.expectEqual(protocol_version, try parse(u32, field(hello.payload, "protocol").?));
    try std.testing.expectEqualStrings("1.2.3", field(hello.payload, "openreliant").?);
    try std.testing.expectEqualStrings("Example", field(hello.payload, "game").?);
    try std.testing.expectEqualStrings("example", field(hello.payload, "vm").?);
    try std.testing.expectEqual(null, field(hello.payload, "mission"));
}

test "the records of OpenReliant's own messages read back as written" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var payload: std.Io.Writer.Allocating = .init(arena);

    const hello: Hello = .{ .protocol = protocol_version, .openreliant = "1.2.3", .game = example };
    try hello.write(&payload.writer);
    const hello_read: Hello = try .read(payload.written());
    try std.testing.expectEqual(protocol_version, hello_read.protocol);
    try std.testing.expectEqualStrings("1.2.3", hello_read.openreliant);
    try std.testing.expectEqualStrings("Example", hello_read.game.name);
    try std.testing.expectEqualStrings("example", hello_read.game.vm);

    payload.clearRetainingCapacity();
    const started: MissionStarted = .{ .number = 90, .file = "mission90.dte" };
    try started.write(&payload.writer);
    const started_read: MissionStarted = try .read(payload.written());
    try std.testing.expectEqual(90, started_read.number);
    try std.testing.expectEqualStrings("mission90.dte", started_read.file);

    payload.clearRetainingCapacity();
    const state: State = .{
        .clock = 41,
        .hold = .held,
        .step = .over,
        .paused = false,
        .first_finished = true,
        .threads = &.{
            .{ .slot = 0, .at = 10, .depth = 1, .wake = 0, .interrupted = false, .trigger = 0 },
            .{ .slot = 3, .at = null, .depth = 0, .wake = 45, .interrupted = true, .trigger = null },
        },
        .globals = &.{ 7, 0xFFFFFFFF },
        .variables = &.{ .{ .name = "mission_over", .value = 1 }, .{ .name = "200", .value = 5 } },
    };
    try state.write(&payload.writer);
    const state_read: State = try .read(arena, payload.written());
    try std.testing.expectEqual(41, state_read.clock);
    try std.testing.expectEqual(vm_editor.Hold.held, state_read.hold);
    try std.testing.expectEqual(vm_editor.Step.over, state_read.step);
    try std.testing.expect(!state_read.paused and state_read.first_finished);
    try std.testing.expectEqual(2, state_read.threads.len);
    try std.testing.expectEqual(state.threads[0], state_read.threads[0]);
    try std.testing.expectEqual(state.threads[1], state_read.threads[1]);
    try std.testing.expectEqualSlices(u32, state.globals, state_read.globals);
    try std.testing.expectEqual(1, state_read.variable("mission_over").?);
    try std.testing.expectEqual(5, state_read.variable("200").?);
    try std.testing.expectEqual(null, state_read.variable("mission_success"));
    try std.testing.expectEqual(0, state_read.ships.len);
    try std.testing.expectEqual(0, state_read.events.len);

    // The ships' orders, and what the script did since the last state.
    payload.clearRetainingCapacity();
    var busy = state;
    busy.ships = &.{
        .{ .index = 2, .order = "fight", .target = 0 },
        .{ .index = 0, .order = "player_control", .target = null },
    };
    busy.events = &.{
        .{ .kind = .trigger, .index = 1, .time = 41_800 },
        .{ .kind = .command, .index = 11, .time = 41_800 },
    };
    busy.events_dropped = 3;
    try busy.write(&payload.writer);
    const busy_read: State = try .read(arena, payload.written());
    try std.testing.expectEqual(2, busy_read.ships.len);
    // In the order of their indices.
    try std.testing.expectEqual(0, busy_read.ships[0].index);
    try std.testing.expectEqualStrings("player_control", busy_read.ships[0].order);
    try std.testing.expectEqual(null, busy_read.ships[0].target);
    try std.testing.expectEqualStrings("fight", busy_read.ships[1].order);
    try std.testing.expectEqual(0, busy_read.ships[1].target.?);
    try std.testing.expectEqualSlices(State.ScriptEvent, busy.events, busy_read.events);
    try std.testing.expectEqual(3, busy_read.events_dropped);

    payload.clearRetainingCapacity();
    const line: ConsoleLine = .{ .line = "x = 6 * 7\nprint(x)" };
    try line.write(&payload.writer);
    // A line break ends the line, and an `=` in it stays.
    try std.testing.expectEqualStrings("x = 6 * 7", (try ConsoleLine.read(payload.written())).line);

    // A key it doesn't know is passed over.
    const newer: State = try .read(arena, "clock=1\nhold=none\nstep=none\npaused=0\nfirst_finished=0\nweather=fine\nthread.2.colour=red\n");
    try std.testing.expectEqual(1, newer.threads.len);
    try std.testing.expectEqual(null, newer.threads[0].at);

    // A field missing, or not what it holds, makes the message unreadable, as does a global past
    // the 16 bits a mission counts them in.
    try std.testing.expectError(error.Invalid, Hello.read("protocol=1\ngame=Example\n"));
    try std.testing.expectError(error.Invalid, MissionStarted.read("number=ninety\nfile=x.dte\n"));
    try std.testing.expectError(error.Invalid, State.read(arena, "clock=1\nhold=gripped\nstep=none\npaused=0\nfirst_finished=0\n"));
    try std.testing.expectError(error.Invalid, State.read(arena, "clock=1\nhold=none\nstep=none\npaused=0\n"));
    try std.testing.expectError(error.Invalid, State.read(arena, "clock=1\nhold=none\nstep=none\npaused=0\nfirst_finished=0\nglobal.70000=1\n"));
    const last: State = try .read(arena, "clock=1\nhold=none\nstep=none\npaused=0\nfirst_finished=0\nglobal.65535=3\n");
    try std.testing.expectEqual(65536, last.globals.len);
    try std.testing.expectEqual(3, last.globals[65535]);
    // The events come numbered from 0, each with its kind.
    const start = "clock=1\nhold=none\nstep=none\npaused=0\nfirst_finished=0\n";
    try std.testing.expectError(error.Invalid, State.read(arena, start ++ "event.1.kind=trigger\n"));
    try std.testing.expectError(error.Invalid, State.read(arena, start ++ "event.0.index=4\n"));
    try std.testing.expectError(error.Invalid, State.read(arena, start ++ "event.0.kind=parade\n"));
    try std.testing.expectError(error.Invalid, State.read(arena, start ++ "ship.70000.order=fight\n"));
    try std.testing.expectError(error.Invalid, ConsoleLine.read("text=reload\n"));
}

test "taking OpenReliant's own messages leaves the original's waiting" {
    const gpa = std.testing.allocator;
    var pipe: testing.Pipe = .{ .gpa = gpa };
    defer pipe.deinit();
    var link: Link = .init(gpa, pipe.transport(), example, "1.2.3");
    defer link.deinit();
    pipe.connect();
    _ = link.next(.all);
    try pipe.sendToGame(@backingInt(Own.console_line), "line=reload\n");
    try pipe.sendToGame(0x15, &.{ 0, 0, 0, 0, 1, 0, 0, 0 });
    try pipe.sendToGame(@backingInt(Own.console_line), "line=help\n");
    try std.testing.expectEqual(Own.console_line, Own.of(link.next(.own).?.message.tag).?);
    // The original's tag waits, and the console line after it with it.
    try std.testing.expectEqual(null, link.next(.own));
    try std.testing.expectEqual(null, link.next(.own));
    try std.testing.expectEqual(0x15, link.next(.all).?.message.tag);
    try std.testing.expectEqual(Own.console_line, Own.of(link.next(.own).?.message.tag).?);
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
