//! `C:\lancer\game\mission.cpp`'s handlers of the editor link (docs/engine/editor-link.md): what
//! the game does with each tag the editor sends (`received`), and what it tells the editor
//! (`Sent`), for the mission a `Session` works on. The link itself, its transport and its framing,
//! is the engine's (`engine.link`), and the script VM's stops and steps are the VM's (`vm.editor`).
//! Another game on the engine brings a table of its own tags.
//!
//! **Unverified:** the dispatch (`editor_link_read`, `0x00457730`) and the check
//! (`editor_link_check`, `0x00457670`) lie between `videoreports.cpp`'s known code and
//! `Executor.cpp`'s, in a file whose name the executable doesn't give. They go with the handlers
//! they call.

const std = @import("std");
const Io = std.Io;

const dte = @import("../../../formats/dte.zig");
const hooks = @import("../../hooks.zig");
const gameobj = @import("../gameobj.zig");
const link = @import("../../link.zig");
const Random = @import("../../random.zig").Random;
const vm = @import("../../vm.zig");
const mission = @import("../mission.zig");
const Order = @import("../ai/orders.zig").Order;
const ticks_per_second = @import("../main.zig").ticks_per_second;
const winmain = @import("../winmain.zig");

const log = std.log.scoped(.editor);

/// StarLancer, as the link names it to an editor.
pub const game: link.Game = .{ .name = "StarLancer", .vm = "starlancer" };

/// The tags the game sends the editor, each with a 4-byte payload.
pub const Sent = enum(u16) {
    /// A thread stopped: the offset in the script of the byte it stopped before (`vm_run`,
    /// `0x0045CA8F`).
    stopped = 0x1A,
    /// Whether the thread pool's first thread has finished (`vm_first_finished`), at each fifth
    /// second of the script's clock while nothing holds the script (`editor_link_check`,
    /// `0x00457720`).
    first_finished = 0x1B,
};

/// What the game does with a tag from the editor.
pub const Action = union(enum) {
    /// `editor_table_copy` (`0x0045A770`): the payload copied over a section of the mission
    /// (`copy`).
    copy: dte.Section,
    /// `editor_run_control` (`0x0045A900`): the editor's pause, its releases and steps, and a part
    /// run at once (`RunControl`).
    run_control,
    /// Kept where nothing reads it, which OpenReliant passes over: the ship the editor picks
    /// (`editor_picked_ship`, `0x0052A1D8`), and 32 bytes (`editor_unused`, `0x005270E4`).
    unread,
    /// Nothing.
    nothing,
    /// Not ported yet: the editor's live changes to the mission and its ships
    /// ([#1057](https://github.com/OpenReliant/openreliant/issues/1057)).
    not_ported,
};

/// A tag the editor sends.
pub const Received = struct {
    name: []const u8,
    /// Where `editor_link_read`'s jump table sends the tag (`0x004579BC`).
    case: u32,
    action: Action,
};

/// The tags the editor sends, by their value (`editor_link_read`, `0x00457730`).
pub const received = [_]Received{
    .{ .name = "ships_place", .case = 0x0045777D, .action = .not_ported },
    .{ .name = "ship_move", .case = 0x0045778F, .action = .not_ported },
    .{ .name = "table_counts", .case = 0x004577A2, .action = .not_ported },
    .{ .name = "script", .case = 0x004577B5, .action = .not_ported },
    .{ .name = "parts", .case = 0x004577D3, .action = .not_ported },
    .{ .name = "triggers", .case = 0x004577F2, .action = .not_ported },
    .{ .name = "ships", .case = 0x00457810, .action = .not_ported },
    .{ .name = "flight_groups", .case = 0x0045782E, .action = .not_ported },
    .{ .name = "objects", .case = 0x0045784D, .action = .not_ported },
    .{ .name = "script_flags", .case = 0x0045786B, .action = .{ .copy = .script_flags } },
    .{ .name = "squads", .case = 0x00457888, .action = .not_ported },
    .{ .name = "squad_members", .case = 0x004578A6, .action = .not_ported },
    .{ .name = "formations", .case = 0x004578C4, .action = .not_ported },
    .{ .name = "formation_points", .case = 0x004578E3, .action = .not_ported },
    .{ .name = "curves", .case = 0x00457901, .action = .not_ported },
    .{ .name = "bind_tables", .case = 0x0045791C, .action = .not_ported },
    .{ .name = "timer_parts", .case = 0x00457923, .action = .not_ported },
    .{ .name = "ship_remove", .case = 0x0045792E, .action = .not_ported },
    .{ .name = "ship_remake", .case = 0x00457939, .action = .not_ported },
    .{ .name = "nothing", .case = 0x00457995, .action = .nothing },
    .{ .name = "view_ship", .case = 0x00457944, .action = .not_ported },
    .{ .name = "run_control", .case = 0x0045794F, .action = .run_control },
    .{ .name = "pick_ship", .case = 0x0045795A, .action = .unread },
    .{ .name = "unused", .case = 0x00457975, .action = .unread },
};

/// The tag of the row of `received` named `name`, for an editor to send.
pub fn tagNamed(comptime name: []const u8) u16 {
    inline for (received, 0..) |row, value| {
        if (comptime std.mem.eql(u8, row.name, name)) return value;
    }
    @compileError("no tag is named " ++ name);
}

/// The payload of tag `0x15` (`editor_run_control`). A shorter payload reads as if zeros followed.
pub const RunControl = extern struct {
    command: Command,
    /// For `pause`, the pause in its low byte: 0 lets the mission go on. For `run_part`, the part's
    /// index.
    argument: u32,

    pub const Command = enum(u32) {
        pause = 0,
        run_on = 1,
        step_into = 2,
        step_over = 3,
        run_part = 4,
        _,

        /// The step the commands 1 to 3 release the script with, the command's own value
        /// (`0x0045A938`); null for the others.
        pub fn step(command: Command) ?vm.editor.Step {
            return switch (command) {
                .run_on => .run_on,
                .step_into => .into,
                .step_over => .over,
                else => null,
            };
        }

        comptime {
            for ([_]Command{ .run_on, .step_into, .step_over }) |command| {
                std.debug.assert(@backingInt(command) == @backingInt(command.step().?));
            }
        }
    };

    comptime {
        std.debug.assert(@offsetOf(RunControl, "argument") == 4);
        std.debug.assert(@sizeOf(RunControl) == 8);
    }
};

/// How often the game tells the editor whether the first thread has finished: at each value of the
/// script's clock that is a multiple of this (`0x004576FD`).
const finished_every = 5;

/// The most events the game keeps between two states while an editor is linked (`Session.events`).
/// Past it, the oldest go first, and the state counts how many (`link.State.events_dropped`).
pub const max_events = 512;

/// The editor link as the game works it for a mission: from its script's start (`begin`) to its end
/// (`end`), the editor's messages are acted on. In between, the original's wait for the next
/// mission, and OpenReliant's own are taken as they come (`poll`).
pub const Session = struct {
    link: *link.Link,
    /// What the script's start waits with (`vm.editor.Editor.sleep`).
    io: Io,
    /// The mission the editor works on; null between missions.
    loaded: ?*mission.Loaded = null,
    /// The mission's number and file, which an editor hears of (`link.Own.mission_started`).
    number: u16 = 0,
    file_buffer: [winmain.mission_path_size]u8 = undefined,
    file_length: usize = 0,
    /// The script's clock as the game last told the editor whether the first thread had finished;
    /// null for not yet in this mission.
    finished_told: ?u32 = null,
    /// The tags not ported yet that the editor has sent, each logged the first time.
    logged: std.bit_set.Static(received.len) = .empty,
    /// What the script did since the editor last asked for the state, which the state gives
    /// (`link.State.events`), and how many were left out past `max_events`.
    events: std.ArrayList(link.State.ScriptEvent) = .empty,
    events_dropped: u32 = 0,
    /// The lines for the game's console that the editor sent, in the link's allocator, which the
    /// game runs after each poll and then lets go of (`clearConsoleLines`).
    console_lines: std.ArrayList([]u8) = .empty,

    pub fn init(on: *link.Link, io: Io) Session {
        return .{ .link = on, .io = io };
    }

    pub fn deinit(session: *Session) void {
        session.events.deinit(session.link.gpa);
        session.clearConsoleLines();
        session.console_lines.deinit(session.link.gpa);
    }

    /// Lets go of the console lines the editor sent, once the game has run them.
    pub fn clearConsoleLines(session: *Session) void {
        for (session.console_lines.items) |line| session.link.gpa.free(line);
        session.console_lines.clearRetainingCapacity();
    }

    /// As the script of `loaded`, `started`, is about to start: the editor works on it from now on,
    /// and hears of it. An editor that has just connected is taken first, so that it hears of the
    /// mission before the script's start reads its messages.
    pub fn begin(session: *Session, loaded: *mission.Loaded, started: hooks.Mission) void {
        if (session.loaded == null) session.poll();
        session.loaded = loaded;
        loaded.session = session;
        session.number = started.number;
        session.file_length = @min(started.file.len, session.file_buffer.len);
        @memcpy(session.file_buffer[0..session.file_length], started.file[0..session.file_length]);
        session.finished_told = null;
        session.events.clearRetainingCapacity();
        session.events_dropped = 0;
        loaded.script.editor.present = session.link.present();
        loaded.script.editor.connection = .{ .context = session, .vtable = &.{ .stopped = stopped, .check = check, .sleep = sleep, .now = now, .happened = happened } };
        session.tellMission();
    }

    /// As the mission ends, before it goes: the editor hears of it, and its messages wait for the
    /// next.
    pub fn end(session: *Session) void {
        const loaded = session.loaded orelse return;
        loaded.session = null;
        loaded.script.editor.connection = null;
        session.loaded = null;
        session.link.send(@backingInt(link.Own.mission_ended), "");
    }

    /// Once a frame, and wherever the script's start checks the link (`editor_link_check`): an
    /// editor connecting or going, then its messages. While no mission plays, the original's
    /// messages wait for the next one, and so do the messages after them; a console line is taken
    /// at once. Then, at each fifth second of the script's clock while nothing holds the script,
    /// the editor hears whether the first thread has finished.
    ///
    /// **Improvement:** the original reads the editor's messages only while a mission's script
    /// starts, and so tells it of the first thread only then; OpenReliant does both every frame,
    /// once for each value of the clock.
    pub fn poll(session: *Session) void {
        while (session.link.next(if (session.loaded == null) .own else .all)) |event| switch (event) {
            .connected => if (session.loaded) |loaded| {
                loaded.script.editor.present = true;
                session.tellMission();
            },
            .disconnected => if (session.loaded) |loaded| loaded.script.editor.letGo(),
            .message => |message| if (session.loaded) |loaded| session.receive(loaded, message) else session.between(message),
        };
        session.tellFinished();
    }

    /// Acts on a message from the editor, by its tag (`editor_link_read`).
    ///
    /// **Improvement:** the original stops the game on a tag past `0x17` (`fatal_error`);
    /// OpenReliant logs it and passes over it.
    fn receive(session: *Session, loaded: *mission.Loaded, message: link.Message) void {
        if (link.Own.of(message.tag)) |own| return session.answer(loaded, own, message.payload);
        if (message.tag >= received.len) {
            log.warn("the editor sent tag 0x{X}, which the game doesn't know, so it passes over it", .{message.tag});
            return;
        }
        switch (received[message.tag].action) {
            .copy => |section| {
                copy(&loaded.bound, section, message.payload);
                if (section == .script_flags) loaded.script.editor.flagged = true;
            },
            .run_control => runControl(loaded, message.payload),
            .unread, .nothing => {},
            .not_ported => if (!session.logged.isSet(message.tag)) {
                session.logged.set(message.tag);
                log.info("the editor's tag 0x{X:0>2} ({s}) isn't ported yet, so the game passes over it (#1057)", .{ message.tag, received[message.tag].name });
            },
        }
    }

    /// Acts on one of OpenReliant's own messages, `payload` its payload: the mission's file or the
    /// script's state for the editor, or a line for the game's console.
    fn answer(session: *Session, loaded: *mission.Loaded, request: link.Own, payload: []const u8) void {
        switch (request) {
            .get_mission => session.link.send(@backingInt(link.Own.mission_file), loaded.bound.image),
            .get_state => session.tellState(loaded),
            .console_line => session.keepConsoleLine(payload),
            else => log.warn("the editor sent tag 0x{X}, which only the game sends, so it passes over it", .{@backingInt(request)}),
        }
    }

    /// Acts on one of OpenReliant's own messages while no mission plays: a console line is kept for
    /// the game to run, and a request for the mission's file or the script's state is passed over.
    fn between(session: *Session, message: link.Message) void {
        switch (link.Own.of(message.tag) orelse return) {
            .console_line => session.keepConsoleLine(message.payload),
            else => log.debug("the editor sent tag 0x{X} with no mission playing, so the game passes over it", .{message.tag}),
        }
    }

    /// Keeps the console line in `payload` for the game to run (`console_lines`).
    fn keepConsoleLine(session: *Session, payload: []const u8) void {
        const console = link.ConsoleLine.read(payload) catch {
            log.warn("the editor sent a console line without its line, so the game passes over it", .{});
            return;
        };
        const gpa = session.link.gpa;
        const kept = gpa.dupe(u8, console.line) catch return;
        session.console_lines.append(gpa, kept) catch gpa.free(kept);
    }

    /// Tells the editor the script's state (`stateOf`), with what the script did since it last
    /// asked, which the game then forgets.
    fn tellState(session: *Session, loaded: *mission.Loaded) void {
        var arena: std.heap.ArenaAllocator = .init(session.link.gpa);
        defer arena.deinit();
        var state = stateOf(arena.allocator(), loaded) catch {
            log.warn("the link has no memory left for the script's state", .{});
            return;
        };
        state.events = session.events.items;
        state.events_dropped = session.events_dropped;
        session.link.sendRecord(.state, state);
        session.events.clearRetainingCapacity();
        session.events_dropped = 0;
    }

    /// Tells the editor of the mission playing, as it starts or as an editor connects, and sends
    /// it the mission's file. The editor answers with the script's flags, which the script's start
    /// waits for.
    fn tellMission(session: *Session) void {
        const loaded = session.loaded orelse return;
        const started: link.MissionStarted = .{ .number = session.number, .file = session.file_buffer[0..session.file_length] };
        session.link.sendRecord(.mission_started, started);
        session.link.send(@backingInt(link.Own.mission_file), loaded.bound.image);
    }

    /// Tells the editor whether the first thread has finished (`editor_link_check`, `0x004576F6`).
    fn tellFinished(session: *Session) void {
        const loaded = session.loaded orelse return;
        const script = &loaded.script;
        if (!script.editor.present or script.editor.hold != .none) return;
        if (script.clock % finished_every != 0 or session.finished_told == script.clock) return;
        session.finished_told = script.clock;
        session.sendWord(.first_finished, @intFromBool(script.first_finished));
    }

    fn sendWord(session: *Session, tag: Sent, value: u32) void {
        var payload: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(u32, &payload, value, .little);
        session.link.send(@backingInt(tag), &payload);
    }

    fn stopped(context: *anyopaque, offset: u32) void {
        const session: *Session = @ptrCast(@alignCast(context));
        session.sendWord(.stopped, offset);
    }

    fn check(context: *anyopaque) void {
        const session: *Session = @ptrCast(@alignCast(context));
        session.poll();
    }

    fn sleep(context: *anyopaque, milliseconds: u32) void {
        const session: *Session = @ptrCast(@alignCast(context));
        session.io.sleep(.fromMilliseconds(milliseconds), .awake) catch {};
    }

    fn now(context: *anyopaque) u64 {
        const session: *Session = @ptrCast(@alignCast(context));
        return @intCast(@max(0, Io.Clock.awake.now(session.io).toMilliseconds()));
    }

    /// Keeps what the script did for the editor's next state, with when it happened on the
    /// script's clock: the game's ticks since the clock started, less the ticks the editor held the
    /// script (`mission.Loaded.tickClock`).
    fn happened(context: *anyopaque, event: vm.editor.Event) void {
        const session: *Session = @ptrCast(@alignCast(context));
        const loaded = session.loaded orelse return;
        const ticks = if (loaded.script.game) |playing| playing.world.clock.game_ticks else loaded.clock_at;
        const milliseconds = @as(u64, ticks -% loaded.clock_from) * std.time.ms_per_s / ticks_per_second;
        const time = std.math.cast(u32, milliseconds) orelse std.math.maxInt(u32);
        if (session.events.items.len == max_events) {
            _ = session.events.orderedRemove(0);
            session.events_dropped +|= 1;
        }
        session.events.append(session.link.gpa, switch (event) {
            .trigger => |index| .{ .kind = .trigger, .index = index, .time = time },
            .command => |number| .{ .kind = .command, .index = number, .time = time },
        }) catch {
            session.events_dropped +|= 1;
        };
    }
};

/// The script's state for `link.Own.state` (`link.State`), its lists made in `arena`. A thread
/// whose instruction is outside the script has no place in it. The game's variables come by their
/// names, and the ones without a name by their numbers, where they aren't 0. The ships are the
/// mission's ships in play, made and not destroyed, each with its current order, and the ship
/// that order aims at where it aims at one.
fn stateOf(arena: std.mem.Allocator, loaded: *mission.Loaded) std.mem.Allocator.Error!link.State {
    const script = &loaded.script;
    const code = loaded.bound.file.entry(.script);
    var threads: std.ArrayList(link.State.Thread) = .empty;
    var live = script.liveThreads();
    while (live.next()) |found| {
        const thread, const index = found;
        const ip = thread.ip orelse continue;
        const at = ip -% code.offset;
        try threads.append(arena, .{
            .slot = @intCast(index),
            .at = if (at < @as(u32, code.count) * @sizeOf(u16)) at else null,
            .depth = thread.record.call_depth,
            .wake = thread.record.wake_time,
            .interrupted = thread.record.interrupted,
            .trigger = if (thread.trigger) |trigger| @intCast(trigger) else null,
        });
    }
    const file_globals = loaded.bound.file.globals() catch &.{};
    const globals = try arena.alloc(u32, file_globals.len);
    for (globals, file_globals) |*value, global| value.* = global.value;
    var variables: std.ArrayList(link.State.Variable) = .empty;
    for (0..vm.Variables.count) |number| {
        const value = script.variables.slot(@intCast(number)).*;
        if (std.enums.tagName(vm.GameVariable, @fromBackingInt(@intCast(number)))) |name| {
            try variables.append(arena, .{ .name = name, .value = value });
        } else if (value != 0) try variables.append(arena, .{ .name = try arena.print("{d}", .{number}), .value = value });
    }
    var ships: std.ArrayList(link.State.Ship) = .empty;
    if (script.game) |playing| {
        const records = loaded.bound.ships() catch &.{};
        const slots = &playing.world.objects.slots;
        const count = @min(records.len, slots.len);
        for (records[0..count], slots[0..count], 0..) |record, *slot, index| {
            if (!slot.object.created or record.flags.destroyed) continue;
            const entry = slot.current();
            try ships.append(arena, .{
                .index = @intCast(index),
                .order = if (entry) |current| try orderName(arena, current.order) else "none",
                .target = if (entry) |current| current.target.ship() else null,
            });
        }
    }
    return .{
        .clock = script.clock,
        .hold = script.editor.hold,
        .step = script.editor.step,
        .paused = script.editor.paused,
        .first_finished = script.first_finished,
        .threads = threads.items,
        .globals = globals,
        .variables = variables.items,
        .ships = ships.items,
    };
}

/// An order's name as the state gives it (`link.State.Ship.order`), or its number where it has
/// none.
fn orderName(arena: std.mem.Allocator, order: Order) std.mem.Allocator.Error![]const u8 {
    return std.enums.tagName(Order, order) orelse arena.print("{d}", .{@backingInt(order)});
}

/// `editor_table_copy` (`0x0045A770`): `payload` copied over a section of the mission, as many
/// bytes as the section's records take (`tableSize`).
///
/// **Fix:** the game copies that many bytes whatever the payload's size, and past the section's
/// reservation where the size runs past it. OpenReliant copies no more than the payload, and no
/// further than the next section's start (`dte.Mission.room`).
fn copy(bound: *mission.Mission, section: dte.Section, payload: []const u8) void {
    const length = @min(payload.len, tableSize(bound.file, section), bound.file.room(section));
    if (length == 0) return;
    const at = bound.file.entry(section).offset;
    @memcpy(bound.image[at..][0..length], payload[0..length]);
}

/// How many bytes a section's records take as `editor_link_read` copies them: the section's count
/// times its record's size, but the script's flags' own size (`dte.Mission.scriptFlagsSize`).
fn tableSize(file: dte.Mission, section: dte.Section) u32 {
    if (section == .script_flags) return file.scriptFlagsSize();
    return @as(u32, file.entry(section).count) * (section.stride() orelse 0);
}

/// `editor_run_control` (`0x0045A900`), by the payload's command: the editor's pause of the
/// mission, the script released with a step, or a part run at once by its index (`part_run`).
///
/// **Fix:** the game runs a part past the parts' table, reading past it; OpenReliant logs it and
/// runs none.
fn runControl(loaded: *mission.Loaded, payload: []const u8) void {
    var bytes: [@sizeOf(RunControl)]u8 = @splat(0);
    const length = @min(payload.len, bytes.len);
    @memcpy(bytes[0..length], payload[0..length]);
    const control = std.mem.bytesToValue(RunControl, &bytes);
    const editor = &loaded.script.editor;
    if (control.command.step()) |step| return editor.release(step);
    switch (control.command) {
        .pause => editor.paused = @as(u8, @truncate(control.argument)) != 0,
        .run_part => {
            const parts = loaded.bound.file.parts() catch &.{};
            if (control.argument >= parts.len) {
                log.warn("the editor ran part {d}, past the mission's {d}, so nothing runs", .{ control.argument, parts.len });
                return;
            }
            loaded.script.runPart(parts[control.argument]);
        },
        else => {},
    }
}

comptime {
    // A row for each case of `editor_link_cases`, the tags 0x00 to 0x17.
    std.debug.assert(received.len == 0x18);
    std.debug.assert(tagNamed("script_flags") == 0x09 and tagNamed("run_control") == 0x15);
}

/// What the tests share: a mission whose one part sets two globals, a statement each
/// (`vm.machine.testing.twoStatements`), with the flags section the editor fills, and an editor on
/// a pipe.
const Test = struct {
    pipe: link.testing.Pipe,
    link: link.Link,
    session: Session,
    random: Random = .{},
    loaded: *mission.Loaded,

    const machine_testing = vm.machine.testing;
    /// The part's first instruction, and its first store, past a select and a push.
    const first = machine_testing.first_instruction;
    const store = first + machine_testing.instructionSize(.select_global) + machine_testing.instructionSize(.push_byte);

    fn init(t: *Test, gpa: std.mem.Allocator) !void {
        return t.initWith(gpa, &.{});
    }

    /// The test's mission with the ships `ships`.
    fn initWith(t: *Test, gpa: std.mem.Allocator, ships: []const dte.Ship) !void {
        t.pipe = .{ .gpa = gpa };
        t.link = .init(gpa, t.pipe.transport(), game, "1.2.3");
        t.session = .init(&t.link, std.testing.io);
        t.random = .{};
        const code = try machine_testing.twoStatements(gpa);
        defer gpa.free(code);
        const flags: [32]u8 = @splat(0);
        const image = try machine_testing.Fixture.image(gpa, &.{.{ .code = code }}, .{ .globals = &.{ 0, 0 }, .script_flags = &flags, .ships = ships });
        t.loaded = try mission.Loaded.create(gpa, image, &t.random);
    }

    fn deinit(t: *Test) void {
        t.loaded.destroy();
        t.session.deinit();
        t.link.deinit();
        t.pipe.deinit();
    }

    /// The mission starts with an editor linked, which takes what the game tells it as it does.
    fn start(t: *Test) !void {
        t.session.begin(t.loaded, .{ .number = 1, .file = "mission1.dte" });
        t.pipe.connect();
        t.session.poll();
        var buffer: [128]u8 = undefined;
        _ = try t.heard(&buffer);
        _ = try t.heard(&buffer);
        try t.expectFile();
        _ = try t.word(.first_finished);
    }

    /// The state the editor asks for, read in `arena`.
    fn state(t: *Test, arena: std.mem.Allocator) !link.State {
        try t.pipe.sendToGame(@backingInt(link.Own.get_state), "");
        t.session.poll();
        const text = try arena.alloc(u8, 64 * 1024);
        const sent = t.pipe.takeFromGame(text) orelse return error.TestExpectedMessage;
        try std.testing.expectEqual(@backingInt(link.Own.state), sent.tag);
        return .read(arena, sent.payload);
    }

    /// The editor's next message from the game, which must have sent one.
    fn heard(t: *Test, buffer: []u8) !link.Message {
        return t.pipe.takeFromGame(buffer) orelse error.TestExpectedMessage;
    }

    /// Takes the game's next message, which must be the mission's file, whole.
    fn expectFile(t: *Test) !void {
        const gpa = std.testing.allocator;
        const file = try gpa.alloc(u8, t.loaded.bound.image.len);
        defer gpa.free(file);
        const sent = t.pipe.takeFromGame(file) orelse return error.TestExpectedMessage;
        try std.testing.expectEqual(@backingInt(link.Own.mission_file), sent.tag);
        try std.testing.expectEqualSlices(u8, t.loaded.bound.image, sent.payload);
    }

    /// The word of the game's next message, which must have tag `tag`.
    fn word(t: *Test, tag: Sent) !u32 {
        var buffer: [16]u8 = undefined;
        const message = try t.heard(&buffer);
        try std.testing.expectEqual(@backingInt(tag), message.tag);
        return std.mem.readInt(u32, message.payload[0..4], .little);
    }

    /// The editor sends tag `0x15` with `command` and `argument`, and the game reads it.
    fn control(t: *Test, command: RunControl.Command, argument: u32) !void {
        try t.pipe.sendToGame(0x15, std.mem.asBytes(&RunControl{ .command = command, .argument = argument }));
        t.session.poll();
    }
};

test Session {
    const gpa = std.testing.allocator;
    var t: Test = undefined;
    try t.init(gpa);
    defer t.deinit();
    t.session.begin(t.loaded, .{ .number = 7, .file = "mission7.dte" });
    try std.testing.expect(!t.loaded.script.editor.present);

    // An editor connects: it hears of the game, of the mission, and that the first thread hasn't
    // finished, as the script's clock stands at 0.
    t.pipe.connect();
    t.session.poll();
    try std.testing.expect(t.loaded.script.editor.present);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqual(@backingInt(link.Own.hello), (try t.heard(&buffer)).tag);
    const started = try t.heard(&buffer);
    try std.testing.expectEqual(@backingInt(link.Own.mission_started), started.tag);
    const started_read: link.MissionStarted = try .read(started.payload);
    try std.testing.expectEqual(7, started_read.number);
    try std.testing.expectEqualStrings("mission7.dte", started_read.file);
    try t.expectFile();
    try std.testing.expectEqual(0, try t.word(.first_finished));

    // It flags the part's first instruction, which the script's start waits for, and the part
    // stops before it.
    var flags: [32]u8 = @splat(0);
    flags[Test.first] = 1;
    try t.pipe.sendToGame(0x09, &flags);
    try std.testing.expect(!t.loaded.script.editor.flagged);
    t.session.poll();
    try std.testing.expect(t.loaded.script.editor.flagged);
    const part = (try t.loaded.bound.file.parts())[0];
    t.loaded.script.runPart(part);
    try std.testing.expectEqual(Test.first, try t.word(.stopped));
    try std.testing.expect(t.loaded.script.editor.holds());

    // A step goes on to the store, and stops before it.
    try t.control(.step_into, 0);
    t.loaded.script.runThreads();
    try std.testing.expectEqual(Test.store, try t.word(.stopped));

    // The editor pauses the mission, and runs a part past the mission's, which runs nothing.
    try t.control(.pause, 1);
    try std.testing.expect(t.loaded.script.editor.leavesFrame());
    try t.control(.run_part, 9);
    try std.testing.expectEqual(1, t.loaded.script.thread_count);
    // A tag past the original's is passed over.
    try t.pipe.sendToGame(0x30, "");
    t.session.poll();

    // As the editor goes, the script is let go.
    t.pipe.dropped = true;
    t.session.poll();
    try std.testing.expect(!t.loaded.script.editor.present and !t.loaded.script.editor.leavesFrame());
    try std.testing.expectEqual(vm.editor.Hold.none, t.loaded.script.editor.hold);
}

test "the editor's messages wait for a mission" {
    const gpa = std.testing.allocator;
    var t: Test = undefined;
    try t.init(gpa);
    defer t.deinit();
    t.pipe.connect();
    t.session.poll();
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqual(@backingInt(link.Own.hello), (try t.heard(&buffer)).tag);
    try std.testing.expectEqual(null, t.pipe.takeFromGame(&buffer));

    // The pause the editor sends with no mission playing waits for the next.
    try t.control(.pause, 1);
    try std.testing.expect(!t.loaded.script.editor.paused);
    t.session.begin(t.loaded, .{ .number = 1, .file = "mission1.dte" });
    try std.testing.expectEqual(@backingInt(link.Own.mission_started), (try t.heard(&buffer)).tag);
    try t.expectFile();
    t.session.poll();
    try std.testing.expect(t.loaded.script.editor.paused);

    // The mission's end is heard of, and the next messages wait again.
    t.session.end();
    _ = try t.word(.first_finished);
    try std.testing.expectEqual(@backingInt(link.Own.mission_ended), (try t.heard(&buffer)).tag);
    try std.testing.expectEqual(null, t.loaded.session);
}

test "the game tells the editor of the first thread once a fifth second, while nothing holds the script" {
    const gpa = std.testing.allocator;
    var t: Test = undefined;
    try t.init(gpa);
    defer t.deinit();
    t.session.begin(t.loaded, .{ .number = 1, .file = "mission1.dte" });
    t.pipe.connect();
    t.session.poll();
    var buffer: [128]u8 = undefined;
    _ = try t.heard(&buffer);
    _ = try t.heard(&buffer);
    try t.expectFile();
    _ = try t.word(.first_finished);
    const script = &t.loaded.script;
    for ([_]struct { clock: u32, told: bool }{
        .{ .clock = 0, .told = false },
        .{ .clock = 3, .told = false },
        .{ .clock = 5, .told = true },
        .{ .clock = 5, .told = false },
    }) |second| {
        script.clock = second.clock;
        t.session.poll();
        try std.testing.expectEqual(second.told, t.pipe.takeFromGame(&buffer) != null);
    }
    script.first_finished = true;
    script.clock = 10;
    script.editor.hold = .held;
    t.session.poll();
    try std.testing.expectEqual(null, t.pipe.takeFromGame(&buffer));
    script.editor.hold = .none;
    t.session.poll();
    try std.testing.expectEqual(1, try t.word(.first_finished));
}

test copy {
    const gpa = std.testing.allocator;
    var t: Test = undefined;
    try t.init(gpa);
    defer t.deinit();
    const bound = &t.loaded.bound;
    const at = bound.file.entry(.script_flags).offset;
    // The flags take the script's bytes, rounded up to 4, and the copy stops there.
    const size = tableSize(bound.file, .script_flags);
    try std.testing.expectEqual(std.mem.alignForward(u32, @as(u32, bound.file.entry(.script).count) * 2, 4), size);
    const room = bound.file.room(.script_flags);
    const after = bound.image[at + size];
    var payload: [64]u8 = @splat(0xAA);
    copy(bound, .script_flags, &payload);
    for (bound.image[at..][0..@min(size, room)]) |byte| try std.testing.expectEqual(0xAA, byte);
    if (room > size) try std.testing.expectEqual(after, bound.image[at + size]);
    // A short payload copies only itself.
    copy(bound, .script_flags, &.{ 1, 2 });
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 0xAA }, bound.image[at..][0..3]);
}

test "the editor asks for the mission's file and the script's state" {
    const gpa = std.testing.allocator;
    var t: Test = undefined;
    try t.init(gpa);
    defer t.deinit();
    t.session.begin(t.loaded, .{ .number = 1, .file = "mission1.dte" });
    t.pipe.connect();
    t.session.poll();
    var buffer: [128]u8 = undefined;
    _ = try t.heard(&buffer);
    _ = try t.heard(&buffer);
    try t.expectFile();
    _ = try t.word(.first_finished);

    // Asked again, the mission's file comes back whole.
    try t.pipe.sendToGame(@backingInt(link.Own.get_mission), "");
    t.session.poll();
    try t.expectFile();

    // The state gives the hold, the thread held and where, the globals and the variables.
    var flags: [32]u8 = @splat(0);
    flags[Test.first] = 1;
    try t.pipe.sendToGame(0x09, &flags);
    t.session.poll();
    t.loaded.script.runPart((try t.loaded.bound.file.parts())[0]);
    _ = try t.word(.stopped);
    t.loaded.script.variables.mission_over = 1;
    try t.pipe.sendToGame(@backingInt(link.Own.get_state), "");
    t.session.poll();
    var text: [4096]u8 = undefined;
    const state = t.pipe.takeFromGame(&text) orelse return error.TestExpectedMessage;
    try std.testing.expectEqual(@backingInt(link.Own.state), state.tag);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const state_read: link.State = try .read(arena.allocator(), state.payload);
    try std.testing.expectEqual(vm.editor.Hold.held, state_read.hold);
    try std.testing.expectEqual(Test.first, state_read.threads[0].at.?);
    try std.testing.expectEqual(0, state_read.threads[0].depth);
    try std.testing.expectEqual(0, state_read.globals[1]);
    try std.testing.expectEqual(1, state_read.variable("mission_over").?);
    try std.testing.expectEqual(null, state_read.variable("200"));

    // A tag only the game sends is passed over.
    try t.pipe.sendToGame(@backingInt(link.Own.state), "");
    t.session.poll();
    try std.testing.expectEqual(null, t.pipe.takeFromGame(&text));
}

test "the state gives the ships' orders, and what the script did since the last state" {
    const gpa = std.testing.allocator;
    var world: gameobj.testing.Mission = undefined;
    try world.init(gpa);
    defer world.deinit();
    const player = try world.add(.of(.predator), @splat(0));
    const sabre = try world.add(.of(.sabre), .{ 0, 0, 2000 });
    const wreck = try world.add(.of(.sabre), .{ 0, 0, 4000 });
    // The Sabre fights the player, and the other Sabre is destroyed.
    const fighting = world.slot(sabre);
    fighting.orders[0] = std.mem.zeroes(@TypeOf(fighting.orders[0]));
    fighting.orders[0].order = .fight;
    fighting.orders[0].target = .at(player, null);
    fighting.object.order_count = 1;
    var ships = dte.testing.ships(3, 0);
    ships[wreck].flags.destroyed = true;
    var t: Test = undefined;
    try t.initWith(gpa, &ships);
    defer t.deinit();
    t.loaded.script.game = world.orders();
    try t.start();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The ships in play, the destroyed one left out, and the Sabre's order and target.
    t.loaded.clock_from = 1000;
    world.clock.game_ticks = 1000 + 4180;
    t.loaded.script.editor.report(.{ .trigger = 1 });
    t.loaded.script.editor.report(.{ .command = 11 });
    const busy = try t.state(arena);
    try std.testing.expectEqual(2, busy.ships.len);
    try std.testing.expectEqual(player, busy.ships[0].index);
    try std.testing.expectEqual(sabre, busy.ships[1].index);
    try std.testing.expectEqualStrings("fight", busy.ships[1].order);
    try std.testing.expectEqual(player, busy.ships[1].target.?);
    // The events, each when it happened on the script's clock, in milliseconds.
    try std.testing.expectEqualSlices(link.State.ScriptEvent, &.{
        .{ .kind = .trigger, .index = 1, .time = 41_800 },
        .{ .kind = .command, .index = 11, .time = 41_800 },
    }, busy.events);

    // The next state gives only what happened since.
    try std.testing.expectEqual(0, (try t.state(arena)).events.len);

    // Past the most the game keeps, the oldest go first, counted.
    for (0..max_events + 2) |number| t.loaded.script.editor.report(.{ .command = @intCast(number % 100) });
    const crowded = try t.state(arena);
    try std.testing.expectEqual(max_events, crowded.events.len);
    try std.testing.expectEqual(2, crowded.events[0].index);
    try std.testing.expectEqual(2, crowded.events_dropped);
}

test "the editor's console lines are taken with or without a mission" {
    const gpa = std.testing.allocator;
    var t: Test = undefined;
    try t.init(gpa);
    defer t.deinit();
    t.pipe.connect();
    t.session.poll();
    var buffer: [128]u8 = undefined;
    _ = try t.heard(&buffer);

    // With no mission playing, a console line is taken at once, and a request for the state is
    // passed over.
    try t.pipe.sendToGame(@backingInt(link.Own.console_line), "line=help\n");
    try t.pipe.sendToGame(@backingInt(link.Own.get_state), "");
    t.session.poll();
    try std.testing.expectEqual(1, t.session.console_lines.items.len);
    try std.testing.expectEqualStrings("help", t.session.console_lines.items[0]);
    try std.testing.expectEqual(null, t.pipe.takeFromGame(&buffer));
    t.session.clearConsoleLines();

    // Behind one of the original's messages, it waits with it for the mission.
    try t.control(.pause, 1);
    try t.pipe.sendToGame(@backingInt(link.Own.console_line), "line=reload\n");
    t.session.poll();
    try std.testing.expectEqual(0, t.session.console_lines.items.len);
    t.session.begin(t.loaded, .{ .number = 1, .file = "mission1.dte" });
    t.session.poll();
    try std.testing.expect(t.loaded.script.editor.paused);
    try std.testing.expectEqualStrings("reload", t.session.console_lines.items[0]);
}
