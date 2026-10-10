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
const link = @import("../../link.zig");
const Random = @import("../../random.zig").Random;
const vm = @import("../../vm.zig");
const mission = @import("../mission.zig");
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

/// The editor link as the game works it for a mission: from its script's start (`begin`) to its end
/// (`end`), the editor's messages are acted on, and in between they wait.
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

    pub fn init(on: *link.Link, io: Io) Session {
        return .{ .link = on, .io = io };
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
        loaded.script.editor.present = session.link.present();
        loaded.script.editor.connection = .{ .context = session, .vtable = &.{ .stopped = stopped, .check = check, .sleep = sleep } };
        session.tellMission();
    }

    /// As the mission ends, before it goes: the editor hears of it, and its messages wait for the
    /// next.
    pub fn end(session: *Session) void {
        const loaded = session.loaded orelse return;
        loaded.session = null;
        loaded.script.editor.connection = null;
        session.loaded = null;
        session.link.sendFields(.mission_ended, &.{});
    }

    /// Once a frame, and wherever the script's start checks the link (`editor_link_check`): an
    /// editor connecting or going, then its messages, which wait while no mission plays. Then,
    /// at each fifth second of the script's clock while nothing holds the script, the editor hears
    /// whether the first thread has finished.
    ///
    /// **Improvement:** the original reads the editor's messages only while a mission's script
    /// starts, and so tells it of the first thread only then; OpenReliant does both every frame,
    /// once for each value of the clock.
    pub fn poll(session: *Session) void {
        while (session.link.next(if (session.loaded == null) .connections else .all)) |event| switch (event) {
            .connected => if (session.loaded) |loaded| {
                loaded.script.editor.present = true;
                session.tellMission();
            },
            .disconnected => if (session.loaded) |loaded| loaded.script.editor.letGo(),
            .message => |message| if (session.loaded) |loaded| session.receive(loaded, message),
        };
        session.tellFinished();
    }

    /// Acts on a message from the editor, by its tag (`editor_link_read`).
    ///
    /// **Improvement:** the original stops the game on a tag past `0x17` (`fatal_error`);
    /// OpenReliant logs it and passes over it.
    fn receive(session: *Session, loaded: *mission.Loaded, message: link.Message) void {
        if (link.Own.of(message.tag)) |own| return session.answer(loaded, own);
        if (message.tag >= received.len) {
            log.warn("the editor sent tag 0x{X}, which the game doesn't know, so it passes over it", .{message.tag});
            return;
        }
        switch (received[message.tag].action) {
            .copy => |section| copy(&loaded.bound, section, message.payload),
            .run_control => runControl(loaded, message.payload),
            .unread, .nothing => {},
            .not_ported => if (!session.logged.isSet(message.tag)) {
                session.logged.set(message.tag);
                log.info("the editor's tag 0x{X:0>2} ({s}) isn't ported yet, so the game passes over it (#1057)", .{ message.tag, received[message.tag].name });
            },
        }
    }

    /// Answers one of OpenReliant's own requests: the mission's file, or the script's state.
    fn answer(session: *Session, loaded: *mission.Loaded, request: link.Own) void {
        switch (request) {
            .get_mission => session.link.send(@backingInt(link.Own.mission_file), loaded.bound.image),
            .get_state => session.tellState(loaded),
            else => log.warn("the editor sent tag 0x{X}, which only the game sends, so it passes over it", .{@backingInt(request)}),
        }
    }

    /// Tells the editor the script's state (`writeState`).
    fn tellState(session: *Session, loaded: *mission.Loaded) void {
        var text: std.Io.Writer.Allocating = .init(session.link.gpa);
        defer text.deinit();
        writeState(&text.writer, loaded) catch {
            log.warn("the link has no memory left for the script's state", .{});
            return;
        };
        session.link.send(@backingInt(link.Own.state), text.written());
    }

    /// Tells the editor of the mission playing, as it starts or as an editor connects, and sends
    /// it the mission's file, which it places its breakpoints by before the start parts run.
    fn tellMission(session: *Session) void {
        const loaded = session.loaded orelse return;
        var number: [std.fmt.count("{d}", .{std.math.maxInt(u16)})]u8 = undefined;
        session.link.sendFields(.mission_started, &.{
            .{ .key = "number", .value = number[0..std.fmt.printInt(&number, session.number, 10, .lower, .{})] },
            .{ .key = "file", .value = session.file_buffer[0..session.file_length] },
        });
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
};

/// The script's state as `link.Own.state` gives it, a `key=value` line each: its clock (`clock`),
/// the editor's hold, step and pause (`hold`, `step`, `paused`), and whether the pool's first
/// thread has finished (`first_finished`); for each thread running, by its slot, where it is in the
/// script (`thread.N.at`, none outside it), its call depth, the clock value it waits for, 0 for
/// none, whether it waits for its trigger, and the trigger that started it, if one did; each
/// global's value (`global.N`); and the game's variables (`variable.NAME`), by their names, and
/// the unnamed ones by their numbers where they aren't 0. Values are the script's words, unsigned.
fn writeState(writer: *std.Io.Writer, loaded: *mission.Loaded) std.Io.Writer.Error!void {
    const script = &loaded.script;
    const editor = script.editor;
    try writer.print("clock={d}\nhold={t}\nstep={t}\npaused={d}\nfirst_finished={d}\n", .{
        script.clock,
        editor.hold,
        editor.step,
        @intFromBool(editor.paused),
        @intFromBool(script.first_finished),
    });
    const code = loaded.bound.file.entry(.script);
    var threads = script.liveThreads();
    while (threads.next()) |found| {
        const thread, const index = found;
        const ip = thread.ip orelse continue;
        const at = ip -% code.offset;
        if (at < @as(u32, code.count) * @sizeOf(u16)) {
            try writer.print("thread.{d}.at={d}\n", .{ index, at });
        } else try writer.print("thread.{d}.at=none\n", .{index});
        try writer.print("thread.{d}.depth={d}\nthread.{d}.wake={d}\nthread.{d}.interrupted={d}\n", .{
            index, thread.record.call_depth, index, thread.record.wake_time, index, @intFromBool(thread.record.interrupted),
        });
        if (thread.trigger) |trigger| try writer.print("thread.{d}.trigger={d}\n", .{ index, trigger });
    }
    for (loaded.bound.file.globals() catch &.{}, 0..) |global, index| {
        try writer.print("global.{d}={d}\n", .{ index, global.value });
    }
    for (0..vm.Variables.count) |number| {
        const value = script.variables.slot(@intCast(number)).*;
        if (std.enums.tagName(vm.GameVariable, @fromBackingInt(@intCast(number)))) |name| {
            try writer.print("variable.{s}={d}\n", .{ name, value });
        } else if (value != 0) try writer.print("variable.{d}={d}\n", .{ number, value });
    }
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
        t.pipe = .{ .gpa = gpa };
        t.link = .init(gpa, t.pipe.transport(), game, "1.2.3");
        t.session = .init(&t.link, std.testing.io);
        t.random = .{};
        const code = try machine_testing.twoStatements(gpa);
        defer gpa.free(code);
        const flags: [32]u8 = @splat(0);
        const image = try machine_testing.Fixture.image(gpa, &.{.{ .code = code }}, .{ .globals = &.{ 0, 0 }, .script_flags = &flags });
        t.loaded = try mission.Loaded.create(gpa, image, &t.random);
    }

    fn deinit(t: *Test) void {
        t.loaded.destroy();
        t.link.deinit();
        t.pipe.deinit();
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
    try std.testing.expectEqualStrings("7", link.field(started.payload, "number").?);
    try std.testing.expectEqualStrings("mission7.dte", link.field(started.payload, "file").?);
    try t.expectFile();
    try std.testing.expectEqual(0, try t.word(.first_finished));

    // It flags the part's first instruction, and the part stops before it.
    var flags: [32]u8 = @splat(0);
    flags[Test.first] = 1;
    try t.pipe.sendToGame(0x09, &flags);
    t.session.poll();
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
    try std.testing.expectEqualStrings("held", link.field(state.payload, "hold").?);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("{d}", .{Test.first}), link.field(state.payload, "thread.0.at").?);
    try std.testing.expectEqualStrings("0", link.field(state.payload, "thread.0.depth").?);
    try std.testing.expectEqualStrings("0", link.field(state.payload, "global.1").?);
    try std.testing.expectEqualStrings("1", link.field(state.payload, "variable.mission_over").?);
    try std.testing.expectEqual(null, link.field(state.payload, "variable.200"));

    // A tag only the game sends is passed over.
    try t.pipe.sendToGame(@backingInt(link.Own.state), "");
    t.session.poll();
    try std.testing.expectEqual(null, t.pipe.takeFromGame(&text));
}
