//! `openreliant debug`: a small debugger of mission scripts on the editor link
//! (docs/engine/editor-link.md, docs/guide/debugging.md). It connects to a game started with
//! `--editor-link`, stops the mission's script at breakpoints, steps it, and shows where it stopped
//! and what it holds. It reads StarLancer's script dialect. A full mission editor and debugger are
//! a project of their own; this one shows what the link does.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const platform = @import("platform");
const engine = openreliant.engine;
const dte = openreliant.dte;
const link = engine.link;
const editor = engine.game.mission.editor;
const help = @import("help.zig");
pub const script = @import("debug/script.zig");

const Breakpoint = script.Breakpoint;
const Script = script.Script;

pub const usage = std.fmt.comptimePrint(
    \\usage: openreliant debug [--port <port>]
    \\  --port <port>  the port the game listens at; {d} by default, as --editor-link-port sets it
    \\  -h, --help     show this page
    \\
    \\Debugs the script of the mission a game started with --editor-link plays: stops it at
    \\breakpoints, steps through its statements, and shows where it stopped and what it holds. It
    \\waits for the game, and for it again once it goes. Type help for the commands.
    \\
, .{platform.link.default_port});

/// The commands, as `help` lists them.
const commands_help =
    \\  parts [<text>]       list the mission's parts, or those whose names hold <text>
    \\  list [<part>]        show a part's instructions, its statements numbered; without a part,
    \\                       the routine the script stopped in
    \\  break <part>[:<n>]   stop before statement <n> of a part, its first by default; the part by
    \\                       its number, or by its name or a piece of it
    \\  break @<offset>      stop before the byte at <offset> in the script
    \\  breaks               list the breakpoints
    \\  delete [<n>]         remove breakpoint <n>, or all of them
    \\  continue, c          let the script run on to the next breakpoint
    \\  step, s              run to the next statement
    \\  next, n              run to the next statement, past the parts it calls
    \\  pause, resume        pause the mission, or let it go on
    \\  run <part>           run a part at once, on a new thread
    \\  where                show where the script stopped
    \\  state                show the script's clock, threads and globals, and the game's
    \\                       variables that aren't 0
    \\  quit, q              quit, letting the script go
    \\
;

const prompt_text = "(debug) ";

/// How long the debugger waits before it tries to connect again.
const retry_ms = 100;

/// Runs `openreliant debug` with the given arguments. Returns the exit code.
pub fn main(io: Io, gpa: Allocator, args: []const [:0]const u8) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .initStreaming(.stdout(), io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    if (help.asked(args)) {
        try out.writeAll(usage);
        return 0;
    }
    const port = portOf(args) orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    var debugger: Debugger = .{ .io = io, .gpa = gpa, .out = out, .port = port };
    defer debugger.deinit();
    debugger.say("Waiting for a game at 127.0.0.1:{d}. Type help for the commands.\n", .{port});
    try debugger.listener.concurrent(io, Debugger.listen, .{&debugger});
    defer debugger.stop();
    var in_buffer: [1024]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &in_buffer);
    while (true) {
        debugger.prompt();
        const line = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = stdin.interface.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            error.ReadFailed => break,
        } orelse break;
        if (!debugger.run(line)) break;
    }
    return 0;
}

/// The port `--port` gives, or the default; null for an argument it doesn't take.
fn portOf(args: []const [:0]const u8) ?u16 {
    var port: u16 = platform.link.default_port;
    var at: usize = 0;
    while (at < args.len) : (at += 1) {
        if (!std.mem.eql(u8, args[at], "--port") or at + 1 == args.len) return null;
        at += 1;
        port = std.fmt.parseInt(u16, args[at], 10) catch return null;
    }
    return port;
}

/// The commands, as they're typed: `c`, `s`, `n` and `q` are short for `continue`, `step`, `next`
/// and `quit`.
const Command = enum { help, parts, list, @"break", breaks, delete, @"continue", c, step, s, next, n, pause, @"resume", run, where, state, quit, q };

/// The debugger: the game's connection, which a task of its own hears (`listen`), and the mission,
/// the breakpoints and the stop, which the commands and the game's messages work on.
const Debugger = struct {
    io: Io,
    gpa: Allocator,
    out: *Io.Writer,
    port: u16,
    /// Guards what follows and the output, which the listener and the commands share.
    mutex: Io.Mutex = .init,
    /// Set as the debugger quits, which ends the listener.
    stopping: bool = false,
    /// The game's connection; null while none is.
    stream: ?Io.net.Stream = null,
    /// Whether the prompt waits on its line, which an event first ends.
    prompted: bool = false,
    /// Whether an event ended the prompt's line, so that the prompt comes again after it.
    reprompt: bool = false,
    /// The mission playing, by its number; null between missions.
    mission: ?u16 = null,
    /// The mission's script, once the game has sent its file.
    script: ?Script = null,
    /// The breakpoints, whose parts' texts the debugger owns.
    breakpoints: std.ArrayList(Breakpoint) = .empty,
    /// Where the script stopped, while the game holds it.
    stopped: ?u32 = null,
    listener: Io.Group = .init,

    fn deinit(debugger: *Debugger) void {
        for (debugger.breakpoints.items) |breakpoint| debugger.freeBreakpoint(breakpoint);
        debugger.breakpoints.deinit(debugger.gpa);
        debugger.forgetMission();
    }

    /// Ends the listener: the game's connection shut down ends its read, and its next attempt to
    /// connect finds the debugger stopping.
    fn stop(debugger: *Debugger) void {
        debugger.mutex.lockUncancelable(debugger.io);
        debugger.stopping = true;
        if (debugger.stream) |stream| stream.shutdown(debugger.io, .both) catch {};
        debugger.mutex.unlock(debugger.io);
        debugger.listener.await(debugger.io) catch {};
    }

    /// Writes to the output, with the lock held. Where the prompt waits on its line, the text
    /// starts a line of its own, and the prompt comes again after it (`afterEvent`).
    fn say(debugger: *Debugger, comptime format: []const u8, arguments: anytype) void {
        if (debugger.prompted) {
            debugger.out.writeByte('\n') catch {};
            debugger.prompted = false;
            debugger.reprompt = true;
        }
        debugger.out.print(format, arguments) catch {};
    }

    /// Shows the prompt, which then waits on its line.
    fn prompt(debugger: *Debugger) void {
        debugger.mutex.lockUncancelable(debugger.io);
        defer debugger.mutex.unlock(debugger.io);
        debugger.out.writeAll(prompt_text) catch {};
        debugger.out.flush() catch {};
        debugger.prompted = true;
    }

    /// Runs the command `line`; false to quit.
    fn run(debugger: *Debugger, line: []const u8) bool {
        debugger.mutex.lockUncancelable(debugger.io);
        defer debugger.mutex.unlock(debugger.io);
        defer debugger.out.flush() catch {};
        debugger.prompted = false;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const verb = words.next() orelse return true;
        const rest = std.mem.trim(u8, words.rest(), " \t\r");
        const command = std.meta.stringToEnum(Command, verb) orelse {
            debugger.say("There's no command {s}: type help for the commands.\n", .{verb});
            return true;
        };
        switch (command) {
            .help => debugger.say("{s}", .{commands_help}),
            .parts => debugger.listParts(rest),
            .list => debugger.listRoutine(rest),
            .@"break" => debugger.addBreakpoint(rest),
            .breaks => debugger.listBreakpoints(),
            .delete => debugger.deleteBreakpoints(rest),
            .@"continue", .c => debugger.release(.run_on),
            .step, .s => debugger.release(.step_into),
            .next, .n => debugger.release(.step_over),
            .pause => debugger.control(.pause, 1),
            .@"resume" => debugger.control(.pause, 0),
            .run => debugger.runPart(rest),
            .where => if (debugger.stopped) |offset| debugger.sayStop(offset) else debugger.say("The script isn't stopped.\n", .{}),
            .state => if (debugger.playing()) {
                _ = debugger.send(@backingInt(link.Own.get_state), "");
            },
            .quit, .q => return false,
        }
        return true;
    }

    /// The listener: connects to the game, hears it until it goes, and connects again, until the
    /// debugger stops.
    fn listen(debugger: *Debugger) Io.Cancelable!void {
        const io = debugger.io;
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(debugger.port) };
        while (!debugger.isStopping()) {
            const stream = address.connect(io, .{ .mode = .stream }) catch {
                try io.sleep(.fromMilliseconds(retry_ms), .awake);
                continue;
            };
            if (!debugger.attach(stream)) return stream.close(io);
            debugger.hear(stream);
            debugger.detach(stream);
        }
    }

    fn isStopping(debugger: *Debugger) bool {
        debugger.mutex.lockUncancelable(debugger.io);
        defer debugger.mutex.unlock(debugger.io);
        return debugger.stopping;
    }

    /// Takes `stream` as the game's connection; false as the debugger stops.
    fn attach(debugger: *Debugger, stream: Io.net.Stream) bool {
        debugger.mutex.lockUncancelable(debugger.io);
        defer debugger.mutex.unlock(debugger.io);
        if (debugger.stopping) return false;
        debugger.stream = stream;
        return true;
    }

    /// Lets the game's connection go, and closes it.
    fn detach(debugger: *Debugger, stream: Io.net.Stream) void {
        debugger.mutex.lockUncancelable(debugger.io);
        debugger.stream = null;
        debugger.forgetMission();
        if (!debugger.stopping) debugger.event("The game went. Waiting for it again.\n", .{});
        debugger.mutex.unlock(debugger.io);
        stream.close(debugger.io);
    }

    /// Hears the game's messages until it goes.
    fn hear(debugger: *Debugger, stream: Io.net.Stream) void {
        var buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(debugger.io, &buffer);
        while (true) {
            const message = link.readMessage(&reader.interface, debugger.gpa) catch return;
            defer debugger.gpa.free(message.payload);
            debugger.mutex.lockUncancelable(debugger.io);
            defer debugger.mutex.unlock(debugger.io);
            debugger.handle(message);
            debugger.afterEvent();
        }
    }

    /// Says an event that didn't come from a command.
    fn event(debugger: *Debugger, comptime format: []const u8, arguments: anytype) void {
        debugger.say(format, arguments);
        debugger.afterEvent();
    }

    /// Brings the prompt back where an event ended its line.
    fn afterEvent(debugger: *Debugger) void {
        if (debugger.reprompt) {
            debugger.out.writeAll(prompt_text) catch {};
            debugger.prompted = true;
            debugger.reprompt = false;
        }
        debugger.out.flush() catch {};
    }

    /// Acts on a message from the game, with the lock held.
    fn handle(debugger: *Debugger, message: link.Message) void {
        if (link.Own.of(message.tag)) |own| return switch (own) {
            .hello => debugger.hello(message.payload),
            .mission_started => debugger.missionStarted(message.payload),
            .mission_file => debugger.missionFile(message.payload),
            .mission_ended => {
                if (debugger.mission) |number| debugger.say("Mission {d} ended.\n", .{number});
                debugger.forgetMission();
            },
            .state => debugger.sayState(message.payload),
            else => {},
        };
        if (message.tag == @backingInt(editor.Sent.stopped) and message.payload.len >= @sizeOf(u32)) {
            const offset = std.mem.readInt(u32, message.payload[0..4], .little);
            debugger.stopped = offset;
            debugger.sayStop(offset);
        }
    }

    fn hello(debugger: *Debugger, payload: []const u8) void {
        debugger.say("Connected to {s}, OpenReliant {s}.\n", .{ link.field(payload, "game") orelse "a game", link.field(payload, "openreliant") orelse "?" });
        const vm = link.field(payload, "vm") orelse "";
        if (!std.mem.eql(u8, vm, editor.game.vm)) {
            debugger.say("Its scripts are in the {s} dialect, and this debugger reads only {s}: breakpoints by offset still work.\n", .{ vm, editor.game.vm });
        }
    }

    fn missionStarted(debugger: *Debugger, payload: []const u8) void {
        debugger.forgetMission();
        const number = std.fmt.parseInt(u16, link.field(payload, "number") orelse "", 10) catch 0;
        debugger.mission = number;
        debugger.say("Mission {d} starts ({s}).\n", .{ number, link.field(payload, "file") orelse "?" });
    }

    /// The mission's file: its script read, and the breakpoints' flags sent.
    fn missionFile(debugger: *Debugger, file: []const u8) void {
        if (debugger.script) |*old| old.deinit();
        debugger.script = null;
        var made = Script.init(debugger.gpa, file) catch |err| return debugger.say("The mission's file can't be read: {s}\n", .{@errorName(err)});
        var placed: usize = 0;
        for (debugger.breakpoints.items) |breakpoint| {
            if (made.place(breakpoint)) |_| placed += 1 else |_| {}
        }
        debugger.script = made;
        debugger.sendFlags();
        if (debugger.breakpoints.items.len != 0) debugger.say("{d} of {d} breakpoints are in its script.\n", .{ placed, debugger.breakpoints.items.len });
    }

    fn forgetMission(debugger: *Debugger) void {
        if (debugger.script) |*old| old.deinit();
        debugger.script = null;
        debugger.mission = null;
        debugger.stopped = null;
    }

    /// Whether a mission plays, which it says where none does.
    fn playing(debugger: *Debugger) bool {
        if (debugger.stream == null) {
            debugger.say("No game is connected.\n", .{});
            return false;
        }
        if (debugger.mission == null) {
            debugger.say("No mission is playing.\n", .{});
            return false;
        }
        return true;
    }

    /// The mission's script, which it says where the game hasn't sent it.
    fn scriptOrSay(debugger: *Debugger) ?*Script {
        if (debugger.script) |*found| return found;
        debugger.say("No mission's script is here yet: one comes as a mission starts.\n", .{});
        return null;
    }

    /// Sends a message to the game; false where none is connected or the connection fails.
    fn send(debugger: *Debugger, tag: u16, payload: []const u8) bool {
        const stream = debugger.stream orelse return false;
        var buffer: [256]u8 = undefined;
        var writer = stream.writer(debugger.io, &buffer);
        link.writeMessage(&writer.interface, tag, payload) catch return false;
        writer.interface.flush() catch return false;
        return true;
    }

    /// Sends run control (tag `0x15`) where a mission plays.
    fn control(debugger: *Debugger, command: editor.RunControl.Command, argument: u32) void {
        if (!debugger.playing()) return;
        const payload: editor.RunControl = .{ .command = command, .argument = argument };
        _ = debugger.send(editor.tagNamed("run_control"), std.mem.asBytes(&payload));
    }

    /// Releases the script, which no longer stands where it stopped.
    fn release(debugger: *Debugger, command: editor.RunControl.Command) void {
        debugger.control(command, 0);
        debugger.stopped = null;
    }

    fn runPart(debugger: *Debugger, text: []const u8) void {
        const found = debugger.scriptOrSay() orelse return;
        const part = found.findPart(text) catch |err| return debugger.sayUnplaced(err, text);
        debugger.control(.run_part, @intCast(part));
    }

    /// Sends the breakpoints' flags for the mission's script, where the game has sent it.
    fn sendFlags(debugger: *Debugger) void {
        const found = if (debugger.script) |*have| have else return;
        const flags = found.flags(debugger.gpa, debugger.breakpoints.items) catch return debugger.say("The debugger has no memory left for the flags.\n", .{});
        defer debugger.gpa.free(flags);
        _ = debugger.send(editor.tagNamed("script_flags"), flags);
    }

    fn addBreakpoint(debugger: *Debugger, text: []const u8) void {
        const parsed = Breakpoint.parse(text) orelse return debugger.say("Give break a part, a part and a statement as <part>:<n>, or @<offset>.\n", .{});
        const owned: Breakpoint = switch (parsed) {
            .offset => parsed,
            .statement => |at| .{ .statement = .{
                .part = debugger.gpa.dupe(u8, at.part) catch return debugger.say("The debugger has no memory left for the breakpoint.\n", .{}),
                .statement = at.statement,
            } },
        };
        debugger.breakpoints.append(debugger.gpa, owned) catch {
            debugger.freeBreakpoint(owned);
            return debugger.say("The debugger has no memory left for the breakpoint.\n", .{});
        };
        debugger.say("Breakpoint {d}, {f}", .{ debugger.breakpoints.items.len, owned });
        debugger.sayPlace(owned);
        debugger.sendFlags();
    }

    fn freeBreakpoint(debugger: *Debugger, breakpoint: Breakpoint) void {
        switch (breakpoint) {
            .statement => |at| debugger.gpa.free(at.part),
            .offset => {},
        }
    }

    fn listBreakpoints(debugger: *Debugger) void {
        if (debugger.breakpoints.items.len == 0) return debugger.say("There are no breakpoints.\n", .{});
        for (debugger.breakpoints.items, 1..) |breakpoint, number| {
            debugger.say("{d:>3}  {f}", .{ number, breakpoint });
            debugger.sayPlace(breakpoint);
        }
    }

    fn deleteBreakpoints(debugger: *Debugger, text: []const u8) void {
        if (text.len == 0) {
            for (debugger.breakpoints.items) |breakpoint| debugger.freeBreakpoint(breakpoint);
            debugger.breakpoints.clearRetainingCapacity();
            debugger.say("The breakpoints are gone.\n", .{});
        } else {
            const number = std.fmt.parseInt(usize, text, 10) catch 0;
            if (number == 0 or number > debugger.breakpoints.items.len) return debugger.say("There's no breakpoint {s}.\n", .{text});
            debugger.freeBreakpoint(debugger.breakpoints.orderedRemove(number - 1));
            debugger.say("Breakpoint {d} is gone.\n", .{number});
        }
        debugger.sendFlags();
    }

    /// Ends the line of a breakpoint with where it stops in the mission's script.
    fn sayPlace(debugger: *Debugger, breakpoint: Breakpoint) void {
        const found = if (debugger.script) |*have| have else return debugger.say(": for the next mission\n", .{});
        const offset = found.place(breakpoint) catch |err| return debugger.say(": not in this mission ({s})\n", .{unplacedText(err)});
        debugger.say(": ", .{});
        debugger.sayLocation(found, offset);
        debugger.say("\n", .{});
    }

    fn sayUnplaced(debugger: *Debugger, err: (script.Unplaced || Allocator.Error), text: []const u8) void {
        debugger.say("{s}: {s}\n", .{ text, unplacedText(err) });
    }

    /// Says where the script stopped: the place, and the instruction there.
    fn sayStop(debugger: *Debugger, offset: u32) void {
        debugger.say("Stopped at ", .{});
        const found = if (debugger.script) |*have| have else return debugger.say("{d}.\n", .{offset});
        debugger.sayLocation(found, offset);
        debugger.say(":\n", .{});
        const instruction = dte.decodeAt(found.code, offset) orelse return debugger.say("  (no instruction there)\n", .{});
        const constants = if (found.routineAt(offset)) |index| found.routines[index].constants(found.code) else &.{};
        debugger.say("  ", .{});
        dte.listing.writeInstruction(debugger.out, found.mission, instruction, constants, .{}) catch {};
        debugger.say("\n", .{});
    }

    /// Says where a thread is, from the offset in the script `text` gives, where it gives one.
    fn sayAt(debugger: *Debugger, text: []const u8) void {
        const offset = std.fmt.parseInt(u32, text, 10) catch return debugger.say("{s}", .{text});
        const found = if (debugger.script) |*have| have else return debugger.say("{d}", .{offset});
        debugger.sayLocation(found, offset);
    }

    /// Says where the byte `offset` bytes into the script lies: its statement and its routine.
    fn sayLocation(debugger: *Debugger, found: *Script, offset: u32) void {
        debugger.say("{d}", .{offset});
        const index = found.routineAt(offset) orelse return debugger.say(", outside the script's routines", .{});
        if (found.statementAt(index, offset) catch null) |number| debugger.say(", statement {d}", .{number});
        debugger.say(" of ", .{});
        debugger.sayRoutine(found, index);
    }

    /// Names routine `index`: a part, or the block of the triggers that run it.
    fn sayRoutine(debugger: *Debugger, found: *Script, index: usize) void {
        switch (found.routines[index].owner) {
            .part => |part| {
                debugger.say("part {d}", .{part});
                const parts = found.mission.parts() catch return;
                const name = found.mission.name(parts[part].name);
                if (name.len != 0) debugger.say(", {s}", .{name});
            },
            .triggers => |triggers| {
                debugger.say("the block of trigger{s}", .{if (triggers.len == 1) "" else "s"});
                for (triggers, 0..) |trigger, at| debugger.say("{s}{d}", .{ if (at == 0) " " else ", ", trigger });
            },
        }
    }

    fn listParts(debugger: *Debugger, filter: []const u8) void {
        const found = debugger.scriptOrSay() orelse return;
        const parts = found.mission.parts() catch return debugger.say("The mission's parts can't be read.\n", .{});
        for (parts, 0..) |part, index| {
            if (part.isEmpty()) continue;
            const name = found.mission.name(part.name);
            if (filter.len != 0 and std.ascii.findIgnoreCase(name, filter) == null) continue;
            debugger.say("{d:>4}  {s}{s}\n", .{ index, name, if (part.flags.start) "  (start)" else "" });
        }
    }

    /// Shows a routine's instructions, each statement numbered at the instruction it ends with:
    /// `>` marks where the script stopped, and `*` each breakpoint.
    fn listRoutine(debugger: *Debugger, text: []const u8) void {
        const found = debugger.scriptOrSay() orelse return;
        const index = if (text.len == 0) stopped: {
            const offset = debugger.stopped orelse return debugger.say("Give list a part, as the script isn't stopped.\n", .{});
            break :stopped found.routineAt(offset) orelse return debugger.say("The script stopped outside its routines.\n", .{});
        } else named: {
            const part = found.findPart(text) catch |err| return debugger.sayUnplaced(err, text);
            break :named found.partRoutine(part) orelse return debugger.say("Part {d} has no block.\n", .{part});
        };
        const no_memory = "The debugger has no memory left for the listing.\n";
        const made = (found.listing(index) catch return debugger.say(no_memory, .{})) orelse
            return debugger.say("The routine's block can't be read.\n", .{});
        const ends = (found.statements(index) catch return debugger.say(no_memory, .{})) orelse &.{};
        const constants = found.routines[index].constants(found.code);
        debugger.sayRoutine(found, index);
        debugger.say("\n", .{});
        var number: usize = 0;
        for (made.instructions) |instruction| {
            const address: u32 = @intCast(instruction.address);
            const stop_mark: u8 = if (debugger.stopped == address) '>' else ' ';
            const break_mark: u8 = if (debugger.breaksAt(found, address)) '*' else ' ';
            if (number < ends.len and ends[number] == address) {
                number += 1;
                debugger.say("{c}{c}{d:>4}", .{ stop_mark, break_mark, number });
            } else debugger.say("{c}{c}    ", .{ stop_mark, break_mark });
            dte.listing.writeInstruction(debugger.out, found.mission, instruction, constants, .{}) catch {};
            debugger.say("\n", .{});
        }
    }

    /// Whether a breakpoint stops before the byte `offset` bytes into the script.
    fn breaksAt(debugger: *Debugger, found: *Script, offset: u32) bool {
        for (debugger.breakpoints.items) |breakpoint| {
            if (found.place(breakpoint)) |place| {
                if (place == offset) return true;
            } else |_| {}
        }
        return false;
    }

    /// Shows the script's state as the game sent it (`link.Own.state`).
    fn sayState(debugger: *Debugger, payload: []const u8) void {
        const hold = link.field(payload, "hold") orelse "none";
        debugger.say("Clock {s} s. The script is {s}", .{ link.field(payload, "clock") orelse "?", if (std.mem.eql(u8, hold, "held")) "held" else "running" });
        const step = link.field(payload, "step") orelse "none";
        if (!std.mem.eql(u8, step, "none")) debugger.say(", stepping ({s})", .{step});
        if (std.mem.eql(u8, link.field(payload, "paused") orelse "0", "1")) debugger.say(", and the mission is paused", .{});
        debugger.say(".\nThreads:\n", .{});
        for (0..engine.vm.max_threads) |thread| {
            var key: [32]u8 = undefined;
            const at = link.field(payload, keyOf(&key, "thread.{d}.at", thread)) orelse continue;
            debugger.say("{d:>4}  at ", .{thread});
            debugger.sayAt(at);
            if (link.field(payload, keyOf(&key, "thread.{d}.wake", thread))) |wake| if (!std.mem.eql(u8, wake, "0")) debugger.say(", waits for second {s}", .{wake});
            if (std.mem.eql(u8, link.field(payload, keyOf(&key, "thread.{d}.interrupted", thread)) orelse "0", "1")) debugger.say(", waits for its trigger", .{});
            debugger.say("\n", .{});
        }
        debugger.say("Globals:\n", .{});
        const found: ?*Script = if (debugger.script) |*have| have else null;
        const globals = if (found) |have| have.mission.globals() catch &.{} else &.{};
        var lines = std.mem.splitScalar(u8, payload, '\n');
        while (lines.next()) |line| {
            const equals = std.mem.findScalar(u8, line, '=') orelse continue;
            const key = line[0..equals];
            const value = line[equals + 1 ..];
            if (std.mem.startsWith(u8, key, "global.")) {
                const index = std.fmt.parseInt(usize, key["global.".len..], 10) catch continue;
                const name = if (found) |have| (if (index < globals.len) have.mission.name(globals[index].name) else "") else "";
                debugger.say("{d:>4}  {s}{s}= ", .{ index, name, if (name.len == 0) "" else " " });
                debugger.sayWord(value);
                debugger.say("\n", .{});
            }
        }
        debugger.say("The game's variables that aren't 0:\n", .{});
        lines.reset();
        while (lines.next()) |line| {
            const equals = std.mem.findScalar(u8, line, '=') orelse continue;
            if (!std.mem.startsWith(u8, line, "variable.") or std.mem.eql(u8, line[equals + 1 ..], "0")) continue;
            debugger.say("  {s} = ", .{line["variable.".len..equals]});
            debugger.sayWord(line[equals + 1 ..]);
            debugger.say("\n", .{});
        }
    }

    /// Says one of the script's words as the state gives it, unsigned, as a signed number: the
    /// scripts count down past 0, as the countdown does.
    fn sayWord(debugger: *Debugger, text: []const u8) void {
        const word = std.fmt.parseInt(u32, text, 10) catch return debugger.say("{s}", .{text});
        debugger.say("{d}", .{@as(i32, @bitCast(word))});
    }
};

/// The key `format` makes with `number`, written in `buffer`; empty where it doesn't fit.
fn keyOf(buffer: []u8, comptime format: []const u8, number: usize) []const u8 {
    return std.fmt.bufPrint(buffer, format, .{number}) catch "";
}

fn unplacedText(err: (script.Unplaced || Allocator.Error)) []const u8 {
    return switch (err) {
        error.NoSuchPart => "no part has that number or name",
        error.SeveralParts => "more than one part's name holds that, so give its number",
        error.NoSuchStatement => "the part has no such statement",
        error.OutsideScript => "the offset is past the script",
        error.OutOfMemory => "no memory left",
    };
}

test portOf {
    try std.testing.expectEqual(platform.link.default_port, portOf(&.{}).?);
    try std.testing.expectEqual(4000, portOf(&.{ "--port", "4000" }).?);
    try std.testing.expectEqual(null, portOf(&.{"--port"}));
    try std.testing.expectEqual(null, portOf(&.{ "--port", "x" }));
    try std.testing.expectEqual(null, portOf(&.{"--other"}));
}

test "the debugger's commands and the game's messages" {
    const gpa = std.testing.allocator;
    const machine = engine.vm.machine.testing;
    const code = try machine.twoStatements(gpa);
    defer gpa.free(code);
    const image = try machine.Fixture.image(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0 } });
    defer gpa.free(image);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var debugger: Debugger = .{ .io = std.testing.io, .gpa = gpa, .out = &out.writer, .port = 0 };
    defer debugger.deinit();

    // With no mission, a breakpoint waits for one, and run control says why it can't.
    try std.testing.expect(debugger.run("break 0:2"));
    try std.testing.expect(debugger.run("continue"));
    try std.testing.expect(std.mem.find(u8, out.written(), "Breakpoint 1, 0:2: for the next mission") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "No game is connected.") != null);

    // The game's messages: a mission starts, its file comes, and the script stops at the
    // breakpoint, the part's second statement.
    debugger.handle(.{ .tag = @backingInt(link.Own.mission_started), .payload = "number=4\nfile=mission4.dte\n" });
    debugger.handle(.{ .tag = @backingInt(link.Own.mission_file), .payload = image });
    const found = if (debugger.script) |*have| have else return error.TestExpectedScript;
    const second = try found.place(.{ .statement = .{ .part = "0", .statement = 2 } });
    var stop: [4]u8 = undefined;
    std.mem.writeInt(u32, &stop, second, .little);
    debugger.handle(.{ .tag = @backingInt(editor.Sent.stopped), .payload = &stop });
    try std.testing.expect(std.mem.find(u8, out.written(), "Mission 4 starts (mission4.dte).") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "1 of 1 breakpoints are in its script.") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "statement 2 of part 0:\n") != null);

    // The listing marks the stop and the breakpoint, and the parts list the start part.
    out.clearRetainingCapacity();
    try std.testing.expect(debugger.run("list"));
    try std.testing.expect(std.mem.find(u8, out.written(), ">*   2") != null);
    try std.testing.expect(debugger.run("parts"));
    try std.testing.expect(std.mem.find(u8, out.written(), "(start)") != null);

    // The state names the thread's place, the globals and the variables that aren't 0.
    out.clearRetainingCapacity();
    var state: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&state, "clock=3\nhold=held\nstep=into\npaused=0\nthread.0.at={d}\nthread.0.wake=0\nglobal.1=7\nvariable.mission_over=0\nvariable.backup_available=1\n", .{second});
    debugger.handle(.{ .tag = @backingInt(link.Own.state), .payload = text });
    try std.testing.expect(std.mem.find(u8, out.written(), "Clock 3 s. The script is held, stepping (into).") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "   0  at ") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "   1  = 7") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "backup_available = 1") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "mission_over") == null);

    // Deleting the breakpoint, and the mission's end.
    try std.testing.expect(debugger.run("delete 1"));
    try std.testing.expectEqual(0, debugger.breakpoints.items.len);
    debugger.handle(.{ .tag = @backingInt(link.Own.mission_ended), .payload = "" });
    try std.testing.expectEqual(null, debugger.script);
    try std.testing.expect(!debugger.run("quit"));
}
