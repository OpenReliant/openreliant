//! The script VM at run time: the VM's globals, its threads, the interpreter, the clock and the
//! timers, `for_each_ship`, and the commands that live beside them (the timers', `Wait`,
//! `InterruptTriggerCode`, `KillAllScriptExecutionExecptMe`, `OpenInstrument` and
//! `CloseInstrument`). [docs/engine/script-vm.md](../../../docs/engine/script-vm.md) describes the
//! VM.
//!
//! Where the game holds an address on a thread's stack, OpenReliant holds where the place lies in
//! the mission image, which holds the script, its strings and every record a script names: a
//! ship's, a flight group's, a global's. The instruction pointer and a block's end are such places
//! too, and a thread's frame is its place on the thread's own stack. The bound mission finds a
//! record by its place and reads the image (`bind.Mission.shipIndex`, `bind.Mission.byte` and the
//! rest). Where the game would fault, or read past a table, OpenReliant ends the thread and logs
//! why.
//!
//! Not ported: the script debugger that `vm_run` serves
//! ([#539](https://github.com/OpenReliant/openreliant/issues/539)).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.vm);

const dte = @import("../../formats/dte.zig");
const libcmt = @import("../libcmt.zig");
const math = @import("../surrender/math.zig");
const vm = @import("../vm.zig");
const executor = @import("../game/executor.zig");
const mission = @import("../game/mission.zig");
const bind = mission.bind;
const aigeneric = @import("../game/aigeneric.zig");
const create = @import("../game/create.zig");
const gameobj = @import("../game/gameobj.zig");
const hud = @import("../game/hud.zig");

/// The value `push_null` pushes: no object (`0x0045C4B5`), which the mission's lookups take for
/// none (`bind.Mission.named`).
pub const none: u32 = bind.Mission.null_place;

/// A command as OpenReliant runs it. Its result is stored in the thread's result, and a zero result
/// ends the thread's run, which a waiting command gives: most give `run_on` or `yield`.
pub const Implementation = *const fn (call: Call) u32;

/// The work of a command that does nothing outside a game and always lets its thread run on
/// (`run_on`): the command's call, and the game.
pub const GameImplementation = *const fn (call: Call, game: aigeneric.Context) void;

/// The result of a command that lets its thread run on, as the game's commands end (`MOV EAX,0x1`,
/// such as `0x00458119` in `cmd_WaitForSpeech`).
pub const run_on: u32 = 1;

/// The result of a command that ends its thread's run until the thread runs next, as a command
/// that waits ends (`XOR EAX,EAX`, such as `0x00458115` in `cmd_WaitForSpeech`).
pub const yield: u32 = 0;

/// The size of the `command` instruction: its opcode and its operand, the command's number.
pub const command_size: u32 = size: {
    const info = dte.Opcode.command.info() orelse @compileError("the VM has no command opcode");
    break :size 1 + info.operands;
};

comptime {
    // The game's commands that wait step back over themselves by 2 (`againItself`).
    assert(command_size == 2);
}

/// What a command runs with.
pub const Call = struct {
    machine: *Machine,
    /// The thread that runs it, by its place in the pool (`vm_thread`, `0x00537578`).
    thread: u8,
    /// Its arguments on the thread's stack, the first first.
    args: []u32,

    /// Has the thread run the command again when it runs next, and yields, as a command that waits
    /// does: its instruction pointer goes back `back` bytes, to the command itself, or to the
    /// pushes of its arguments before it too, which then push them afresh (`*ip -= back`).
    pub fn again(call: Call, back: u32) u32 {
        const thread = &call.machine.threads[call.thread];
        if (thread.ip) |at| thread.ip = at -% back;
        return yield;
    }

    /// `again`, back over the command instruction alone (`command_size`), as `WaitForSpeech`,
    /// `WaitForMovie` and `WaitForDirectorCam` run again (`ADD EAX,-0x2` at `0x00458110`,
    /// `0x0045818B` and `0x00459C9C`).
    pub fn againItself(call: Call) u32 {
        return call.again(command_size);
    }
};

/// What ends a thread where the game faults or reads past a table.
pub const Fault = error{
    /// An instruction, a constant or a record past the mission image.
    OutsideImage,
    /// An opcode the VM has no handler for.
    UnknownOpcode,
    StackOverflow,
    StackUnderflow,
    /// A number past what it indexes: a part, a local, a command, an event's value.
    OutOfRange,
    /// `push_argument` or `select_argument` in a block started with no arguments.
    NoFrame,
    /// A store with no `select_` before it.
    NoStore,
    /// An integer division by zero.
    DivisionByZero,
    /// Squads that hold one another round in a circle.
    SquadCycle,
};

/// A thread as OpenReliant runs it: the game's record, with the places the game keeps in it as
/// pointers kept beside it.
pub const Running = struct {
    /// The game's record: its wake time, locals, stack, call depth, trigger and result. Its
    /// pointers stay null.
    record: vm.Thread = std.mem.zeroes(vm.Thread),
    /// Where its next instruction lies in the mission image; null for a free slot (`Thread.ip`).
    ip: ?u32 = null,
    /// Where the running block ends, and its constants start (`Thread.block_end`).
    block_end: u32 = 0,
    /// Where the running part's first argument lies on the stack; null for a block started with
    /// none (`Thread.frame`).
    frame: ?u8 = null,
    /// The first free place of its stack (`Thread.stack_top`).
    top: u8 = 0,
    /// The index of the trigger that started it in the trigger list, whole, where one did; the
    /// record keeps its low byte (`Thread.trigger`).
    trigger: ?usize = null,

    /// Whether its slot is free (`ip`).
    pub fn isFree(thread: *const Running) bool {
        return thread.ip == null;
    }

    fn push(thread: *Running, value: u32) Fault!void {
        if (thread.top >= thread.record.stack.len) return error.StackOverflow;
        thread.record.stack[thread.top] = value;
        thread.top += 1;
    }

    /// The value `back` places below the top of the stack: 1 for the top.
    fn below(thread: *Running, back: u8) Fault!*u32 {
        if (thread.top < back) return error.StackUnderflow;
        return &thread.record.stack[thread.top - back];
    }

    fn drop(thread: *Running, count: u8) Fault!void {
        if (thread.top < count) return error.StackUnderflow;
        thread.top -= count;
    }

    fn pop(thread: *Running) Fault!u32 {
        const value = (try thread.below(1)).*;
        thread.top -= 1;
        return value;
    }

    /// The two values on top of the stack, `a` below `b`, which a binary opcode takes, and leaves
    /// its result in `a`'s place.
    fn pair(thread: *Running) Fault!struct { a: *u32, b: u32 } {
        const b = (try thread.below(1)).*;
        const a = try thread.below(2);
        thread.top -= 1;
        return .{ .a = a, .b = b };
    }
};

/// A walk of a pool as the game walks its threads and its timers (`vm_threads_run`,
/// `vm_run_timers`, `cmd_DestroyTimer`, `trigger_thread_running`): each entry that is not free
/// (`isFree`) in turn, until as many have been given as were in use as the walk began (`count`).
/// An entry is looked at as the walk reaches it, so one that comes into use in a later slot before
/// then is given too, and the count the walk began with holds whatever its work does to the pool's.
pub fn Live(comptime T: type, comptime isFree: fn (*const T) bool) type {
    return struct {
        /// The pool itself.
        entries: []T,
        /// How many more entries in use the walk gives.
        left: usize,
        /// The next entry to look at.
        at: usize = 0,

        const Walk = @This();

        pub fn init(entries: []T, count: usize) Walk {
            return .{ .entries = entries, .left = count };
        }

        /// The next entry in use, and its index in the pool.
        pub fn next(walk: *Walk) ?struct { *T, usize } {
            while (walk.left != 0 and walk.at < walk.entries.len) {
                const index = walk.at;
                walk.at += 1;
                const entry = &walk.entries[index];
                if (isFree(entry)) continue;
                walk.left -= 1;
                return .{ entry, index };
            }
            return null;
        }
    };
}

/// What the last `select_` opcode chose for `assign` and the compound stores (`vm_store_target`,
/// `0x00537408`).
pub const Store = union(enum) {
    none,
    /// A dword of the mission image: a global's value.
    image: u32,
    /// A place on a thread's stack: an argument's.
    stack: struct { thread: u8, place: u8 },
    /// One of the game's variables.
    variable: u8,
};

/// The components `push_component` named for the values it pushed since the last command
/// (`vm_component_tag_list`, `0x00537420`), each by the place of its value on the running thread's
/// stack.
pub const Tags = struct {
    tags: [vm.ComponentTag.max]Tag = undefined,
    count: u8 = 0,

    pub const Tag = struct { place: u8, component: u8 };

    /// `vm_tag_component` (`0x0045D8B0`). **Fix:** the game writes a ninth past its list.
    fn add(tags: *Tags, component: u8, place: u8) void {
        if (tags.count == tags.tags.len) return;
        tags.tags[tags.count] = .{ .place = place, .component = component };
        tags.count += 1;
    }

    /// `vm_tags_clear` (`0x0045D890`), after every command.
    fn clear(tags: *Tags) void {
        tags.count = 0;
    }

    /// `vm_tag_pop` (`0x0045D8E0`): the last tag taken off the list.
    fn pop(tags: *Tags) void {
        if (tags.count > 0) tags.count -= 1;
    }
};

/// A free timer, as `mission_script_start` fills the table: every byte `0xFF`.
const free_timer = std.mem.bytesToValue(vm.Timer, &([_]u8{0xFF} ** @sizeOf(vm.Timer)));

comptime {
    assert(free_timer.isFree());
}

/// What `_unknown_00537401` is set to as the script starts and before every command
/// (`0x0045CC38`, `0x0045BEDF`).
const unknown_00537401_reset: u8 = 0xFF;

/// The value `push_percent` scales by (`0x004DC730`), a hundredth as a float rounds it.
const percent: f32 = 0.01;

/// The records of the second command catalogue that `command_b` reads (`command_catalogue_b`,
/// `0x004F3AD0`): its one command, Test_AI_Function, which has no implementation, and the empty
/// record that ends the catalogue. The catalogue counts no commands (`catalogue_count`), but
/// `command_b` reads a record by its number whatever the count: past these two, the game's strings.
const catalogue_b = [_]struct { name: []const u8, arguments: u8 }{
    .{ .name = "Test_AI_Function", .arguments = 2 },
    .{ .name = "", .arguments = 0 },
};

/// What `command_b` gives: the game calls a stub in place of the command's implementation, which
/// returns 1 (`0x0045D800`).
const stub_result = run_on;

pub const Machine = struct {
    gpa: Allocator,
    /// The mission it runs: its image, which the script reads its records from and writes its
    /// globals into, and the tables binding it made.
    mission: *bind.Mission,
    /// The game's random numbers (`rand`), which `random_branch` draws.
    random: *libcmt.Rand,
    /// `vm_thread_pool` (`0x00537590`).
    threads: [vm.max_threads]Running = @splat(.{}),
    /// `vm_thread_count` (`0x00537415`).
    thread_count: u8 = 0,
    /// `vm_finished` (`0x00537574`): set by a `return` at call depth zero.
    finished: bool = false,
    /// `vm_first_finished` (`0x00537410`): set once the pool's first thread finishes.
    first_finished: bool = false,
    store: Store = .none,
    tags: Tags = .{},
    /// `vm_clock` (`0x00538C9C`): seconds of the mission.
    clock: u32 = 0,
    /// `vm_clock_ticked` (`0x00537580`): set as the clock ticks, until the timers have run for the
    /// tick.
    ticked: bool = false,
    /// `vm_timers_running` (`0x00537400`): whether the timers run, set as the script starts.
    timers_running: bool = true,
    /// `vm_timer_table` (`0x00537470`).
    timers: [vm.max_timers]vm.Timer = @splat(free_timer),
    /// `vm_timer_count` (`0x00537468`).
    timer_count: u16 = 0,
    variables: vm.Variables = .{},
    /// `vm_command_flag` (`0x00537584`): whether `forEachShip` passes over the players' ships in a
    /// flight group, as the running command's flags in section 24 have it
    /// (`dte.CommandFlags.players`, inverted).
    skips_players: bool = false,
    /// `0x00537401`: **Unknown.** Set to `unknown_00537401_reset` as the script starts and before
    /// every command.
    _unknown_00537401: u8 = unknown_00537401_reset,
    /// `event_values` (`0x00538CA0`): the last events of the conditions that keep them, for each
    /// object.
    event_values: []vm.ObjectEvents = &.{},
    /// The commands not ported yet that have run, each logged the first time.
    logged: std.StaticBitSet(executor.commands.table.len) = .initEmpty(),
    /// What the commands act on the game through, which the game's code reaches through its
    /// globals: the world and its clock, as the mission's start and its frame give them. Null where
    /// there is no game, as in a test of the script alone, and the commands that act on it then do
    /// nothing.
    game: ?aigeneric.Context = null,
    /// `for_each_ship_first` (`0x00537418`): the first ship the running `forEachShip` has run its
    /// command for, which each later one's object names (`GameObject._unknown_698`); and
    /// `for_each_ship_count` (`0x00537575`), how many it has.
    walk_first: ?u16 = null,
    walk_count: u8 = 0,
    /// `wait_still_moving` (`0x0052A1E0`): whether the ships `WaitForJumpOrLaunch` walks are still
    /// jumping or launching.
    still_moving: bool = false,
    /// `condition_verdict` (`0x00525F84`): the condition's handlers' verdict on the event being
    /// raised on a flight group or a squad (`vm.triggers.raiseOnGroups`). While it is false, only
    /// the triggers of the repeat mode the condition exempts answer. Each event raised sets it
    /// again, as the script's start does.
    verdict: bool = true,
    /// `vm_last_jump` (`0x005373F4`): the script's clock when JUMP DRIVE last took a jump or a warp
    /// the mission had ready, which `WhenPlayerLastJumped` counts from; `never_jumped` until then.
    last_jumped: u32 = never_jumped,
    /// Whether a trigger's operand that names nothing has been logged.
    named_nothing: bool = false,

    /// `last_jumped` as the script starts (`0x0045CC2E`).
    pub const never_jumped: u32 = 0xFFFF;

    pub fn init(gpa: Allocator, bound: *bind.Mission, random: *libcmt.Rand) Machine {
        return .{ .gpa = gpa, .mission = bound, .random = random };
    }

    pub fn deinit(machine: *Machine) void {
        machine.gpa.free(machine.event_values);
    }

    /// `mission_script_start` (`0x0045CBC0`), as the mission's binding ends: every object's kept
    /// events emptied, the clock, the timers, the threads and the tags reset, the handlers' verdict
    /// and the last jump's time too, and the timers set running. Then each start part runs, every
    /// object's triggers are armed, and each ship's Destroyed flag is cleared and its components
    /// all intact. Where a curve starts at the ship, the first such curve's ships are made
    /// (`0x0045CD71`): the ship it starts at, those its tangents are drawn to, and the ship it ends
    /// at, each where its slot holds no object made yet, which the start part may have left
    /// (`executor.createShip`).
    ///
    /// **Fix:** the game takes the object past its array for a curve that names no ship;
    /// OpenReliant passes over it.
    pub fn start(machine: *Machine) !void {
        const file = machine.mission.file;
        machine.gpa.free(machine.event_values);
        machine.event_values = &.{};
        machine.event_values = try machine.gpa.alloc(vm.ObjectEvents, (try file.objects()).len);
        @memset(machine.event_values, std.mem.zeroes(vm.ObjectEvents));
        machine._unknown_00537401 = unknown_00537401_reset;
        machine.first_finished = false;
        machine.last_jumped = never_jumped;
        machine.verdict = true;
        machine.clock = 0;
        machine.timers = @splat(free_timer);
        machine.resetThreads();
        machine.tags.clear();
        machine.timer_count = 0;
        machine.ticked = false;
        machine.timers_running = true;
        for (try file.parts()) |part| {
            if (part.flags.start and !part.isEmpty()) machine.runPart(part);
        }
        const triggers = try machine.mission.triggers();
        for (try file.objects()) |object| {
            for (vm.triggers.sliceOf(triggers, object).triggers) |*trigger| trigger.armed = 1;
        }
        const curves = try file.curves();
        for (try machine.mission.ships(), 0..) |*ship, index| {
            ship.flags = .{ .destroyed = false, ._unknown = 0 };
            ship.intact_components = dte.Ship.all_intact;
            const game = machine.game orelse continue;
            const curve = curves[executor.curves.starting(curves, @intCast(index)) orelse continue];
            const all = game.world.objects;
            for ([_]dte.Reference{ curve.start, curve.leaving_handle, curve.arriving_handle, curve.end }) |point| {
                if (point.index >= all.slots.len or all.slots[point.index].object.created) continue;
                executor.createShip(game, machine.mission, point.index);
            }
        }
    }

    /// `part_run` (`0x0045BAA0`): runs a part's block at once, on a new thread.
    fn runPart(machine: *Machine, part: dte.Part) void {
        _ = machine.startThread(machine.mission.blockAt(.script, part.block()), null, false, null, null);
    }

    /// `vm_thread_start` (`0x0045B8D0`): starts a thread on `block`, the one at `into` or a free
    /// one, which runs now unless `deferred`, for the trigger `trigger`, by its index in the
    /// trigger list, where one starts it. None starts while 31 run, or on no block.
    /// **Fix:** the game takes a free thread past its pool where none is free.
    pub fn startThread(machine: *Machine, block: ?u32, into: ?u8, deferred: bool, frame: ?u8, trigger: ?usize) ?u8 {
        const at = block orelse return null;
        if (machine.thread_count + 1 >= vm.max_threads) return null;
        const index = into orelse machine.allocThread() orelse return null;
        const length = machine.mission.halfword(at) catch return null;
        const thread = &machine.threads[index];
        thread.ip = at + @sizeOf(u16);
        thread.frame = frame;
        thread.record.wake_time = 0;
        thread.record._unknown_b4 = 0;
        thread.block_end = at + length;
        thread.record.call_depth = 0;
        thread.record.interrupted = false;
        thread.trigger = trigger;
        thread.record.trigger = if (trigger) |started| @truncate(started) else vm.Thread.no_trigger;
        thread.record._unknown_ac = vm.Thread.unknown_ac_start;
        machine.thread_count += 1;
        if (!deferred) machine.runThread(index);
        return index;
    }

    /// `vm_thread_alloc` (`0x0045B960`): the first free thread, its stack emptied.
    pub fn allocThread(machine: *Machine) ?u8 {
        for (&machine.threads, 0..) |*thread, index| {
            if (thread.ip != null) continue;
            thread.top = 0;
            return @intCast(index);
        }
        return null;
    }

    /// The threads running, from the pool's first (`Live`).
    pub fn liveThreads(machine: *Machine) Live(Running, Running.isFree) {
        return .init(&machine.threads, machine.thread_count);
    }

    /// The timers set, from the table's first (`Live`).
    fn liveTimers(machine: *Machine) Live(vm.Timer, vm.Timer.isFree) {
        return .init(&machine.timers, machine.timer_count);
    }

    /// `vm_threads_reset` (`0x0045B990`): frees every thread.
    fn resetThreads(machine: *Machine) void {
        machine.thread_count = 0;
        machine.threads = @splat(.{});
    }

    /// `vm_thread_run` (`0x0045BA30`): runs a thread until it yields or finishes, unless it waits
    /// for a later clock. A finished thread's slot is freed.
    fn runThread(machine: *Machine, index: u8) void {
        const thread = &machine.threads[index];
        if (thread.record.wake_time != 0) {
            if (machine.clock <= thread.record.wake_time) return;
            thread.record.wake_time = 0;
        }
        machine.finished = false;
        if (!machine.run(index)) return;
        thread.ip = null;
        machine.thread_count -= 1;
    }

    /// `vm_threads_run` (`0x0045B9B0`), once a frame (`process_mission`): each thread that was
    /// running as the pass began, and not waiting for its trigger (`InterruptTriggerCode`), runs
    /// on. A thread the pass starts in a later slot runs in it too, while the pass has threads
    /// still to count.
    pub fn runThreads(machine: *Machine) void {
        var threads = machine.liveThreads();
        while (threads.next()) |found| {
            const thread, const index = found;
            if (!thread.record.interrupted) machine.runThread(@intCast(index));
        }
    }

    /// `vm_run_timers` (`0x0045D140`), once the clock has ticked (`process_mission`): each timer
    /// counts down once a clock value, and at zero starts its part on a new thread, then reloads
    /// its countdown, or after its last firing is destroyed.
    pub fn runTimers(machine: *Machine) void {
        var timers = machine.liveTimers();
        while (timers.next()) |found| {
            const timer = found[0];
            if (timer.last_tick == machine.clock) continue;
            timer.countdown -%= 1;
            if (timer.countdown == 0) machine.fire(timer);
        }
    }

    fn fire(machine: *Machine, timer: *vm.Timer) void {
        timer.last_tick = machine.clock;
        const part = machine.partEntry(.a, timer.part);
        if (timer.remaining == 0) {
            timer.countdown = timer.period;
        } else {
            timer.remaining -= 1;
            if (timer.remaining != 0) timer.countdown = timer.period else machine.destroyTimers(timer.id);
        }
        _ = machine.startThread(part.block, null, true, null, null);
    }

    /// A part table's entry `index`: none past the table.
    fn partEntry(machine: *Machine, table: enum { a, b }, index: anytype) vm.Part {
        const parts = switch (table) {
            .a => &machine.mission.parts,
            .b => &machine.mission.parts_b,
        };
        const at = std.math.cast(usize, index) orelse return .{};
        return if (at < parts.len) parts[at] else .{};
    }

    /// `cmd_CreateTimer` (`0x0045D210`, command `0x01`): a timer with an ID, which destroys any
    /// timer with the same, that starts a part every so many seconds, so many times or for ever.
    /// **Fix:** the game takes a timer past its table where none is free.
    pub fn createTimer(call: Call) u32 {
        const machine = call.machine;
        const id: u16 = @truncate(call.args[0]);
        machine.destroyTimers(id);
        const timer = for (&machine.timers) |*timer| {
            if (timer.isFree()) break timer;
        } else return run_on;
        machine.timer_count += 1;
        timer.id = id;
        timer.part = @bitCast(call.args[1]);
        timer.period = @truncate(call.args[2]);
        timer.countdown = timer.period;
        if (timer.period == 1) timer.countdown += 1;
        timer.last_tick = 0;
        timer.remaining = @truncate(call.args[3]);
        return run_on;
    }

    /// `cmd_DestroyTimer` (`0x0045D290`, command `0x02`): destroys every timer with an ID.
    pub fn destroyTimer(call: Call) u32 {
        call.machine.destroyTimers(@truncate(call.args[0]));
        return run_on;
    }

    /// Every timer set with the ID `id` is freed.
    fn destroyTimers(machine: *Machine, id: u16) void {
        var timers = machine.liveTimers();
        while (timers.next()) |found| {
            const timer = found[0];
            if (timer.id != id) continue;
            timer.free();
            machine.timer_count -= 1;
        }
    }

    /// `cmd_Wait` (`0x0045D2E0`, command `0x05`): the thread waits until the clock has passed so
    /// many seconds more.
    pub fn wait(call: Call) u32 {
        const machine = call.machine;
        machine.threads[call.thread].record.wake_time = call.args[0] +% machine.clock;
        return yield;
    }

    /// `cmd_InterruptTriggerCode` (`0x0045D450`, command `0x17`): the thread stops until its
    /// trigger fires again.
    pub fn interruptTriggerCode(call: Call) u32 {
        call.machine.threads[call.thread].record.interrupted = true;
        return yield;
    }

    /// `cmd_KillAllScriptExecutionExecptMe` (`0x0045D990`, command `0x51`): every thread but the
    /// caller's ends.
    pub fn killAllScriptExecutionExceptMe(call: Call) u32 {
        const machine = call.machine;
        for (&machine.threads, 0..) |*thread, index| {
            if (thread.ip == null or index == call.thread) continue;
            thread.ip = null;
            machine.thread_count -= 1;
        }
        return run_on;
    }

    /// The display, and its window a command's argument numbers, in a game with a display and
    /// where the argument numbers one of its windows.
    fn instrument(game: aigeneric.Context, value: u32) ?struct { *hud.State, hud.windows.Window } {
        const display = game.world.display orelse return null;
        const number = std.math.cast(u4, value) orelse return null;
        return .{ display, std.enums.fromInt(hud.windows.Window, number) orelse return null };
    }

    /// `cmd_OpenInstrument` (`0x0045D9D0`, command `0x40`): the display's window the argument
    /// numbers opens (`hud.windows.Windows.open`) and is held open until the script closes it. The
    /// radio's menu, window 11, starts from its top (`videoreports.menu.Menu.start`), and opening
    /// the objectives, window 10, closes the wing status window where it is up. **Unknown:** the
    /// byte after the window's hold (`+0x25`), which the command clears. **Unverified:** it lies
    /// among the interpreter's code, after `cmd_KillAllScriptExecutionExecptMe`, as
    /// `CloseInstrument` does, rather than in the Executor's.
    ///
    /// **Fix:** the game opens a window past its fifteen from past its table; OpenReliant opens
    /// none.
    pub fn openInstrument(call: Call, game: aigeneric.Context) void {
        const display, const window = instrument(game, call.args[0]) orelse return;
        const windows = &display.windows;
        _ = windows.open(window, false);
        windows.status.getPtr(window).held = true;
        if (window == .comms) game.world.player.menu.start(game);
        if (window == .objectives and windows.up(.wing_status)) windows.close(.wing_status);
    }

    /// `cmd_CloseInstrument` (`0x0045DA30`, command `0x41`): the display's window the argument
    /// numbers closes (`hud.windows.Windows.close`), held open no more.
    pub fn closeInstrument(call: Call, game: aigeneric.Context) void {
        const display, const window = instrument(game, call.args[0]) orelse return;
        display.windows.close(window);
        display.windows.status.getPtr(window).held = false;
    }

    /// `vm_argument_component` (`0x0045D950`): the component `push_component` named for the
    /// running command's argument `index`, or null for none.
    pub fn argumentComponent(machine: *const Machine, thread: u8, index: u8) ?u8 {
        const first = machine.threads[thread].top;
        for (machine.tags.tags[0..machine.tags.count]) |tag| {
            if (tag.place -% first == index) return tag.component;
        }
        return null;
    }

    /// `vm_tag_matches` (`0x0045D910`): whether `component` is one that `push_component` named for
    /// the running command's arguments, any of them; or, where it names none of them, the object
    /// itself (`dte.Trigger.whole_object`).
    pub fn tagged(machine: *const Machine, component: u8) bool {
        for (machine.tags.tags[0..machine.tags.count]) |tag| {
            if (tag.component == component) return true;
        }
        return component == dte.Trigger.whole_object;
    }

    /// A command's work for each ship `forEachShip` runs it for: the command's call, with its
    /// arguments after the first, and the ship.
    pub const ShipImplementation = *const fn (call: Call, ship: Ship) void;

    /// A ship `forEachShip` runs a command for: the game, the ship by its index among the mission's
    /// ships, and its object's slot.
    pub const Ship = struct {
        game: aigeneric.Context,
        index: u16,
        slot: *create.Slot,
    };

    /// `for_each_ship` (`0x0045D460`): runs `each` for each ship of the ship, flight group or squad
    /// the command's first argument names, with its arguments after the first. A flight group's
    /// ships run in the mission's order, and a squad's members in theirs, a member that is a flight
    /// group or a squad for each of its ships, one that names a component of a ship with the
    /// component tagged on the first argument (`argumentComponent`). While the command's flag is
    /// set (`skips_players`), the players' ships in a flight group are passed over. Each ship's
    /// object names the first ship the walk ran for (`GameObject._unknown_698`), or none for the
    /// first. Nothing runs without a game.
    pub fn forEachShip(call: Call, each: ShipImplementation) void {
        const machine = call.machine;
        const game = machine.game orelse return;
        if (call.args.len == 0) return;
        machine.walk_first = null;
        machine.walk_count = 0;
        const rest: Call = .{ .machine = machine, .thread = call.thread, .args = call.args[1..] };
        machine.walkEntity(rest, game, call.args[0], each, 0) catch |fault| {
            log.warn("a command's ships are walked no further: {s}", .{@errorName(fault)});
        };
    }

    /// `for_each_ship`'s walk of `entity` (`0x0045D480`), `depth` squads down, in `game`. A squad's
    /// members run from the first its record at `entity` names (`bind.Mission.squadMembersFrom`).
    ///
    /// **Fix:** the game walks a squad that holds itself round for ever, and walks a member of the
    /// object table no record stands for from address zero; OpenReliant stops once the walk has
    /// gone down more squads than the mission has, and passes over the member.
    fn walkEntity(machine: *Machine, call: Call, game: aigeneric.Context, entity: u32, each: ShipImplementation, depth: usize) Fault!void {
        if (entity == bind.Mission.no_place) return;
        if (machine.mission.holds(.ships, entity)) return machine.walkShip(call, game, entity, each);
        if (machine.mission.holds(.flight_groups, entity)) return machine.walkGroup(call, game, try machine.groupAt(entity), each);
        if (!machine.mission.holds(.squads, entity)) return;
        const squads = try machine.mission.recordsIn(dte.Squad, .squads);
        if (depth > squads.len) return error.SquadCycle;
        // The game takes a squad whose first member's low byte is `no_member_low` for one with
        // none.
        const first_member = entity + @offsetOf(dte.Squad, "first_member");
        if (try machine.mission.byte(first_member) == no_member_low) return;
        const own = machine.mission.squadIndex(entity) orelse bind.Mission.no_record;
        const first = try machine.mission.halfword(first_member);
        var members = machine.mission.squadMembersFrom(own, first);
        while (members.next()) |member| switch (member) {
            .ship => |ship| {
                if (ship.component) |component| machine.tags.add(component, machine.threads[call.thread].top);
                try machine.walkShip(call, game, machine.mission.recordPlace(.ships, ship.index), each);
                if (ship.component != null) machine.tags.pop();
            },
            .flight_group => |group| try machine.walkGroup(call, game, group, each),
            .squad => |inner| try machine.walkEntity(call, game, machine.mission.recordPlace(.squads, inner), each, depth + 1),
        };
    }

    /// The low byte of a squad's `first_member` that `for_each_ship` takes for a squad with no
    /// members (`0x0045D594`).
    const no_member_low: u8 = 0xFF;

    /// The flight group at `place`, as far as `for_each_ship` reads it, wherever `place` lies among
    /// the flight groups (`0x0045D4F8`): its count of ships and where the first lies in the list
    /// binding the mission made.
    fn groupAt(machine: *Machine, place: u32) Fault!dte.FlightGroup {
        var group = std.mem.zeroes(dte.FlightGroup);
        group.ship_count = try machine.mission.byte(place + @offsetOf(dte.FlightGroup, "ship_count"));
        group.first_ship = try machine.mission.word(place + @offsetOf(dte.FlightGroup, "first_ship"));
        return group;
    }

    /// Each ship of flight group `group`, as binding the mission listed them
    /// (`bind.Mission.groupShips`), the players' ones passed over while the command's flag says
    /// so (`skips_players`).
    fn walkGroup(machine: *Machine, call: Call, game: aigeneric.Context, group: dte.FlightGroup, each: ShipImplementation) Fault!void {
        const players = game.world.objects.players;
        for (machine.mission.groupShips(group)) |ship| {
            if (machine.skips_players and ship < players) continue;
            try machine.walkShip(call, game, machine.mission.recordPlace(.ships, ship), each);
        }
    }

    /// `for_each_ship_run` (`0x0045D700`), `for_each_ship`'s work for one ship: its object names
    /// the first ship of the walk (`for_each_ship_note`, `0x0045D720`, `bind.recordReference`),
    /// then the command runs for it, where the ship's object is one of the game's
    /// (`mission.shipSlot`).
    fn walkShip(machine: *Machine, call: Call, game: aigeneric.Context, ship: u32, each: ShipImplementation) Fault!void {
        const all = game.world.objects;
        const index = mission.shipSlot(machine.mission, all, ship) orelse return;
        const slot = &all.slots[index];
        slot.object._unknown_698 = bind.recordReference(.ship, machine.walk_first);
        if (machine.walk_first == null) machine.walk_first = index;
        machine.walk_count +%= 1;
        each(call, .{ .game = game, .index = index, .slot = slot });
    }

    /// `vm_run` (`0x0045C980`): runs the thread from its instruction pointer, an opcode at a time,
    /// until a handler returns zero. True once the thread has finished, which a `return` at call
    /// depth zero does.
    fn run(machine: *Machine, index: u8) bool {
        var previous: u32 = 1;
        while (previous != 0) {
            previous = machine.step(index, previous) catch |fault| {
                log.warn("a script thread ends at {d}: {s}", .{ machine.threads[index].ip orelse 0, @errorName(fault) });
                machine.finished = true;
                machine.threads[index].record.call_depth = 0;
                return true;
            };
        }
        if (machine.threads[index].record.call_depth != 0) return false;
        if (machine.finished and index == 0) machine.first_finished = true;
        return machine.finished;
    }

    /// One opcode's handler (`vm_dispatch_table`, `0x004F6350`): what it does, with the handler's
    /// return value, `previous` to carry on or zero to end the run.
    fn step(machine: *Machine, index: u8, previous: u32) Fault!u32 {
        const thread = &machine.threads[index];
        const opcode: dte.Opcode = @enumFromInt(try machine.operand(thread));
        switch (opcode) {
            // The comparisons take the values as unsigned (`CMP`, `SBB`), and the float ones load
            // each as a whole number (`FILD`), exactly, so they compare as the others do.
            .equal => try compare(thread, .eq),
            .not_equal => try compare(thread, .neq),
            .greater, .greater_f => try compare(thread, .gt),
            .greater_equal, .greater_equal_f => try compare(thread, .gte),
            .less, .less_f => try compare(thread, .lt),
            .less_equal, .less_equal_f => try compare(thread, .lte),
            .in_flight_group, .not_in_flight_group => {
                const values = try thread.pair();
                const in = try machine.inFlightGroup(values.a.*, values.b);
                values.a.* = @intFromBool(in == (opcode == .in_flight_group));
            },
            .in_squad, .not_in_squad => {
                const values = try thread.pair();
                const in = try machine.inSquad(values.b, values.a.*, dte.Trigger.whole_object, 0);
                values.a.* = @intFromBool(in == (opcode == .in_squad));
            },
            inline .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .add_assign_f, .sub_assign_f, .mul_assign_f, .div_assign_f => |store| {
                const value = (try thread.below(1)).*;
                const target = try machine.stored();
                target.* = switch (store) {
                    .assign => value,
                    .add_assign => target.* +% value,
                    .sub_assign => target.* -% value,
                    .mul_assign => target.* *% value,
                    .div_assign => try divide(target.*, value),
                    // `FILD` the value, then the operation on the float stored, rounded.
                    .add_assign_f => @bitCast(single(float(target.*) + unsigned(value))),
                    .sub_assign_f => @bitCast(single(float(target.*) - unsigned(value))),
                    .mul_assign_f => @bitCast(single(unsigned(value) * float(target.*))),
                    .div_assign_f => @bitCast(single(float(target.*) / unsigned(value))),
                    else => comptime unreachable,
                };
                try thread.drop(2);
            },
            inline .add, .sub, .mul, .div, .logical_and, .logical_or, .add_f, .sub_f, .mul_f, .div_f => |operation| {
                const values = try thread.pair();
                const a = values.a.*;
                const b = values.b;
                values.a.* = switch (operation) {
                    .add => a +% b,
                    .sub => a -% b,
                    .mul => a *% b,
                    .div => try divide(a, b),
                    .logical_and => @intFromBool(a != 0 and b != 0),
                    .logical_or => @intFromBool(a != 0 or b != 0),
                    // One loaded unsigned (`FILD`), the other taken signed (`FIADD` and the like),
                    // rounded, then truncated (`__ftol`).
                    .add_f => whole(single(unsigned(b) + signed(a))),
                    .sub_f => whole(single(unsigned(a) - signed(b))),
                    .mul_f => whole(single(unsigned(b) * signed(a))),
                    .div_f => whole(single(unsigned(a) / signed(b))),
                    else => comptime unreachable,
                };
            },
            .command => return machine.command(index, try machine.operand(thread)),
            .command_b => return machine.commandB(index, try machine.operand(thread)),
            .call_part => try machine.callPart(index, machine.partEntry(.a, try machine.operand(thread))),
            .call_part_b => try machine.callPart(index, machine.partEntry(.b, try machine.operand(thread))),
            .spawn_part => try machine.spawnPart(index, machine.partEntry(.a, try machine.operand(thread)), true),
            .spawn_part_b => try machine.spawnPart(index, machine.partEntry(.b, try machine.operand(thread)), false),
            .branch_if_zero, .branch_if_zero_alt => {
                const at = thread.ip.?;
                const taken = try thread.pop() == 0;
                thread.ip = if (taken) at +% try machine.mission.big(at) else at + 2;
            },
            .jump => {
                const at = thread.ip.?;
                thread.ip = at +% try machine.mission.big(at);
            },
            .random_branch => try machine.randomBranch(thread),
            .@"return", .return_alt => return machine.returnFromPart(index),
            .push_array => try thread.push(machine.variables.slot(try machine.operand(thread)).*),
            .push_global => try thread.push(try machine.mission.word(machine.mission.globalPlace(try machine.operand(thread)))),
            .push_constant => try thread.push(try machine.constant(thread, try machine.operand(thread))),
            .push_constant_wide => try thread.push(try machine.constant(thread, try machine.operandWide(thread))),
            .push_string, .push_string_alt => {
                const at = thread.ip.?;
                // The length byte counts itself.
                const length = try machine.mission.byte(at);
                try thread.push(at + 1);
                thread.ip = at +% length;
            },
            .push_ship => try thread.push(machine.mission.recordPlace(.ships, try machine.operand(thread))),
            .push_ship_wide => try thread.push(machine.mission.recordPlace(.ships, try machine.operandWide(thread))),
            .push_component, .push_component_alt => {
                try thread.push(machine.mission.recordPlace(.ships, try machine.operand(thread)));
                machine.tags.add(try machine.operand(thread), thread.top - 1);
            },
            .push_flight_group => try thread.push(machine.mission.recordPlace(.flight_groups, try machine.operand(thread))),
            .push_squad => try thread.push(machine.mission.recordPlace(.squads, try machine.operand(thread))),
            .push_curve => try thread.push(machine.mission.recordPlace(.curves, try machine.operand(thread))),
            .push_section_19 => try thread.push(machine.mission.recordPlace(.unused_19, try machine.operand(thread))),
            .push_byte, .push_byte_alt => try thread.push(try machine.operand(thread)),
            .push_percent => {
                const share = try machine.operand(thread);
                // `FIMUL` by the share, then `FMUL` by a hundredth, each rounded.
                const scaled = single(unsigned((try thread.below(1)).*) * @as(f128, @floatFromInt(share)));
                try thread.push(whole(single(@as(f128, scaled) * percent)));
            },
            .push_local => {
                const local = try machine.operand(thread);
                if (local >= thread.record.locals.len) return error.OutOfRange;
                try thread.push(thread.record.locals[local]);
            },
            .push_argument => try thread.push(thread.record.stack[try argument(thread, try machine.operand(thread))]),
            .push_null => try thread.push(none),
            .push_result => try thread.push(thread.record.result),
            .push_event_value => try thread.push(try machine.eventValue(thread)),
            .select_array => {
                const variable = try machine.operand(thread);
                machine.store = .{ .variable = variable };
                try thread.push(machine.variables.slot(variable).*);
            },
            .select_global => {
                const place = machine.mission.globalPlace(try machine.operand(thread));
                machine.store = .{ .image = place };
                try thread.push(try machine.mission.word(place));
            },
            .select_argument => {
                const place = try argument(thread, try machine.operand(thread));
                machine.store = .{ .stack = .{ .thread = index, .place = place } };
                try thread.push(thread.record.stack[place]);
            },
            .nop => {},
            _ => return error.UnknownOpcode,
        }
        return previous;
    }

    /// `vm_command` (`0x0045BEA0`): runs a command of the catalogue on its arguments, the top of
    /// the stack, which it pops. Its result takes the first argument's place, above the stack, and
    /// is the thread's result.
    fn command(machine: *Machine, index: u8, number: u8) Fault!u32 {
        const thread = &machine.threads[index];
        if (number >= executor.commands.table.len) return error.OutOfRange;
        const count: u8 = @intCast(executor.commands.table[number].params.len);
        try thread.drop(count);
        machine._unknown_00537401 = unknown_00537401_reset;
        machine.skips_players = !machine.commandFlags(.command_flags, number).players;
        const call: Call = .{ .machine = machine, .thread = index, .args = thread.record.stack[thread.top..][0..count] };
        const result = if (executor.implementation(number)) |implementation| implementation(call) else machine.unported(number);
        return machine.commandResult(index, result);
    }

    /// `vm_command_b` (`0x0045BF20`): `command` through the second catalogue (`catalogue_b`), with
    /// its flags in section 25. For the command, the game calls a stub that gives 1
    /// (`stub_result`), so it pops its arguments and gives 1.
    fn commandB(machine: *Machine, index: u8, number: u8) Fault!u32 {
        if (number >= catalogue_b.len) return error.OutOfRange;
        try machine.threads[index].drop(catalogue_b[number].arguments);
        machine.skips_players = !machine.commandFlags(.command_flags_b, number).players;
        return machine.commandResult(index, stub_result);
    }

    /// A command's result, which takes the first argument's place, above the stack, and is the
    /// thread's result.
    fn commandResult(machine: *Machine, index: u8, result: u32) Fault!u32 {
        const thread = &machine.threads[index];
        if (thread.top >= thread.record.stack.len) return error.StackOverflow;
        thread.record.stack[thread.top] = result;
        thread.record.result = result;
        machine.tags.clear();
        return result;
    }

    /// A command not ported yet does nothing and gives 1, which lets the thread run on as most
    /// commands do. It is logged the first time it runs.
    fn unported(machine: *Machine, number: u8) u32 {
        if (!machine.logged.isSet(number)) {
            machine.logged.set(number);
            log.info("the script command {s} is not ported yet: it does nothing", .{executor.commands.table[number].name});
        }
        return run_on;
    }

    /// Command `number`'s flags in `section`, 24 for the catalogue and 25 for the second, as
    /// `vm_command` reads them (`0x0045BEDC`): the low byte of the word `number` places past the
    /// section's offset (`dte.CommandFlags.fromLow`), whatever the section's count. A mission that
    /// leaves the section unused, at `dte.DirectoryEntry.unused_offset`, gives whatever lies there:
    /// in the shipped missions that do, the trigger operands of section 1.
    ///
    /// **Fix:** where that lies past the image, as for a section that starts at the file's end, the
    /// game reads past its copy of the file (`mission_file_read` allocates the file's size);
    /// OpenReliant takes none.
    fn commandFlags(machine: *const Machine, section: dte.Section, number: u8) dte.CommandFlags {
        const offset = machine.mission.file.entry(section).offset;
        const at = std.math.add(u32, offset, @as(u32, number) * @sizeOf(u16)) catch return .{};
        return .fromLow(machine.mission.byte(at) catch return .{});
    }

    /// `vm_call_part` (`0x0045BFA0`) and `vm_call_part_b` (`0x0045C110`): above the arguments the
    /// caller pushed, a call record, then the part's block runs, its frame the first argument.
    /// **Fix:** the second table's call goes on to a part with no block, which the game runs from
    /// address zero.
    fn callPart(machine: *Machine, index: u8, entry: vm.Part) Fault!void {
        const block = entry.block orelse return;
        const thread = &machine.threads[index];
        const length = try machine.mission.halfword(block);
        try thread.push(entry.argument_count);
        try thread.push(thread.ip.?);
        try thread.push(if (thread.frame) |frame| frame else none);
        try thread.push(thread.block_end);
        if (thread.top < @as(u16, entry.argument_count) + @sizeOf(vm.CallRecord) / @sizeOf(u32)) return error.StackUnderflow;
        thread.frame = @intCast(thread.top - entry.argument_count - @sizeOf(vm.CallRecord) / @sizeOf(u32));
        thread.ip = block + @sizeOf(u16);
        thread.block_end = block + length;
        thread.record.call_depth +%= 1;
    }

    /// `vm_return` (`0x0045C6E0`): at call depth zero, the thread has finished. Deeper, the part's
    /// value becomes the thread's result, and the call record and the arguments are popped.
    fn returnFromPart(machine: *Machine, index: u8) Fault!u32 {
        const thread = &machine.threads[index];
        machine.finished = thread.record.call_depth == 0;
        if (machine.finished) return 0;
        thread.record.result = try thread.pop();
        thread.block_end = try thread.pop();
        const frame = try thread.pop();
        thread.frame = if (frame == none) null else std.math.cast(u8, frame) orelse return error.OutOfRange;
        thread.ip = try thread.pop();
        // The argument count is read as a halfword.
        const count: u16 = @truncate(try thread.pop());
        if (count > thread.top) return error.StackUnderflow;
        thread.top -= @intCast(count);
        thread.record.call_depth -%= 1;
        return 1;
    }

    /// `vm_spawn_part` (`0x0045C070`) and `vm_spawn_part_b` (`0x0045C1E0`): the part's arguments
    /// move from the stack to a new thread's, which starts on the part's block at the next pass.
    /// The first table's does nothing for a part with no block; the second's pops the arguments
    /// first, then starts nothing.
    fn spawnPart(machine: *Machine, index: u8, entry: vm.Part, checks_block: bool) Fault!void {
        const thread = &machine.threads[index];
        if (checks_block and entry.block == null) return;
        try thread.drop(entry.argument_count);
        const new = machine.allocThread() orelse return;
        const count = entry.argument_count;
        if (count > machine.threads[new].record.stack.len) return error.StackOverflow;
        @memcpy(machine.threads[new].record.stack[0..count], thread.record.stack[thread.top..][0..count]);
        _ = machine.startThread(entry.block, new, true, 0, null);
        machine.threads[new].top = count;
    }

    /// `vm_random_branch` (`0x0045C910`): a roll of the game's `rand`, below `roll_range`, against
    /// each arm's threshold in turn; the first arm it falls below, where it names a target, is
    /// taken, or else the default. The targets count from the opcode. The operands are an arm table
    /// (`dte.ArmIterator`).
    fn randomBranch(machine: *Machine, thread: *Running) Fault!void {
        const Header = dte.ArmIterator.Header;
        const Arm = dte.ArmIterator.Arm;
        const at = thread.ip.?;
        var arms = try machine.mission.byte(at + @offsetOf(Header, "count"));
        const default = at + @offsetOf(Header, "default");
        var arm = at + @sizeOf(Header);
        const roll: u8 = @intCast(@rem(machine.random.rand(), roll_range));
        const target = while (arms != 0) : (arm += @sizeOf(Arm)) {
            arms -= 1;
            if (roll < try machine.mission.byte(arm + @offsetOf(Arm, "threshold"))) {
                const taken = try machine.mission.big(arm + @offsetOf(Arm, "target"));
                break if (taken != no_arm) taken else try machine.mission.big(default);
            }
        } else try machine.mission.big(default);
        thread.ip = at +% target -% 1;
    }

    /// The rolls `random_branch` draws below (`0x0045C922`).
    const roll_range = 100;

    /// The target of an arm that takes the default instead (`0x0045C94A`).
    const no_arm: u16 = 0xFFFF;

    /// Where the store the last `select_` chose lies.
    fn stored(machine: *Machine) Fault!*align(1) u32 {
        return switch (machine.store) {
            .none => error.NoStore,
            .image => |at| @ptrCast((try machine.mission.bytes(at, @sizeOf(u32))).ptr),
            .stack => |slot| &machine.threads[slot.thread].record.stack[slot.place],
            .variable => |variable| machine.variables.slot(variable),
        };
    }

    /// `ship_in_flight_group` (`0x0045CB20`): whether the ship at `ship`, unless it is
    /// `bind.Mission.no_place`, names the flight group at `group` (`bind.Mission.shipFlightGroup`).
    /// It reads the ship's flight group wherever `ship` lies, as the game does; a place past the
    /// address space, such as `none`, ends the thread where the game faults.
    fn inFlightGroup(machine: *Machine, ship: u32, group: u32) Fault!bool {
        if (ship == bind.Mission.no_place) return false;
        return try machine.mission.shipFlightGroup(ship) == group;
    }

    /// `object_in_squad` (`0x00452AC0`): whether the object at `object` is a member of the squad at
    /// `squad`, as the component `tag`, or through a member that is a flight group or a squad. The
    /// members run from the squad's first, read wherever `squad` lies, while they are the squad's
    /// own (`bind.Mission.squadIndex`), and the object is read only once a member is reached
    /// (`0x00452B2A`). A place past the address space, such as `none`, ends the thread where the
    /// game faults.
    ///
    /// **Fix:** the game reads a squad no record stands for from address zero, and a member past
    /// the object table from past it; OpenReliant passes over both.
    pub fn inSquad(machine: *Machine, squad: u32, object: u32, tag: u8, depth: u8) Fault!bool {
        const bound = machine.mission;
        if (depth > (try bound.recordsIn(dte.Squad, .squads)).len) return error.SquadCycle;
        const first = try bound.halfword(try bind.Mission.fieldPlace(squad, @offsetOf(dte.Squad, "first_member")));
        if (first == dte.Squad.no_member) return false;
        const own = bound.squadIndex(squad) orelse bind.Mission.no_record;
        const members = try bound.recordsIn(dte.SquadMember, .squad_members);
        const objects = try bound.recordsIn(dte.Object, .objects);
        for (members[@min(first, members.len)..]) |member| {
            if (member.squad != own) break;
            if (try bound.halfword(object) == member.object_id and member.component == tag) return true;
            if (bound.recordOf(member.object_id)) |record| switch (record) {
                .ship => {},
                .flight_group => |at| if (try machine.inFlightGroup(object, bound.recordPlace(.flight_groups, at))) return true,
                .squad => |at| if (try machine.inSquad(bound.recordPlace(.squads, at), object, tag, depth + 1)) return true,
            } else if (member.object_id < objects.len and objects[member.object_id].kind == .flight_group) {
                // A flight group the object table names with no record is a null group, which a
                // ship of no group is in.
                if (try machine.inFlightGroup(object, bind.Mission.no_place)) return true;
            }
        }
        return false;
    }

    /// `vm_push_event_value` (`0x0045C5E0`): a value of the last event of a condition an object
    /// keeps (`event_values`).
    fn eventValue(machine: *Machine, thread: *Running) Fault!u32 {
        const condition = try machine.operand(thread);
        const value = try machine.operand(thread);
        const object = try machine.operand(thread);
        const slot = (vm.conditions.find(condition) orelse return error.OutOfRange).slot orelse return error.OutOfRange;
        if (object >= machine.event_values.len) return error.OutOfRange;
        const kept = machine.event_values[object].flat();
        const at = @as(usize, slot) * vm.max_event_values + value;
        return if (at < kept.len) kept[at] else error.OutOfRange;
    }

    /// Constant `index` of the running block, from its end.
    fn constant(machine: *Machine, thread: *Running, index: u16) Fault!u32 {
        return machine.mission.word(thread.block_end +% @as(u32, index) * @sizeOf(u32));
    }

    /// The next byte at the thread's instruction pointer, which it moves past.
    fn operand(machine: *Machine, thread: *Running) Fault!u8 {
        const at = thread.ip.?;
        const value = try machine.mission.byte(at);
        thread.ip = at + 1;
        return value;
    }

    /// The next two bytes, big-endian, as the script's two-byte operands are.
    fn operandWide(machine: *Machine, thread: *Running) Fault!u16 {
        const at = thread.ip.?;
        const value = try machine.mission.big(at);
        thread.ip = at + 2;
        return value;
    }
};

/// A comparison of the two values on top, which the result replaces.
fn compare(thread: *Running, how: std.math.CompareOperator) Fault!void {
    const values = try thread.pair();
    values.a.* = @intFromBool(std.math.compare(values.a.*, how, values.b));
}

/// An unsigned division (`DIV`). **Fix:** a division by zero, which faults the game, ends the
/// thread.
fn divide(a: u32, b: u32) Fault!u32 {
    if (b == 0) return error.DivisionByZero;
    return a / b;
}

/// Where argument `index` of the thread's frame lies on its stack.
fn argument(thread: *const Running, index: u8) Fault!u8 {
    const frame = thread.frame orelse return error.NoFrame;
    const at = @as(usize, frame) + index;
    if (at >= thread.record.stack.len) return error.OutOfRange;
    return @intCast(at);
}

/// A value as the FPU loads it with `FILD`: exact.
fn unsigned(value: u32) f128 {
    return @floatFromInt(value);
}

/// A value as `FIADD` and the like take it: a signed whole number.
fn signed(value: u32) f128 {
    return @floatFromInt(@as(i32, @bitCast(value)));
}

/// A stored float, as `FADD float ptr` and the like take it.
fn float(value: u32) f128 {
    return @as(f32, @bitCast(value));
}

/// A result as the FPU rounds it while Direct3D runs, its precision set to single: the exact value
/// rounded once.
fn single(exact: f128) f32 {
    return @floatCast(exact);
}

/// `__ftol`'s whole number of a result.
fn whole(value: f32) u32 {
    return @bitCast(math.ftol(value));
}

/// Fixtures for the tests: a machine on a mission written with `dte.write` from assembled
/// routines.
pub const testing = struct {
    const write = dte.write;
    pub const Routine = dte.assemble.Routine;

    /// Ends a start part as the tests' scripts end it, its result 1 returned, and gives its bytes
    /// (`Routine.finish`), which the caller frees.
    pub fn finishPart(routine: *Routine) ![]u8 {
        try finishPartOps(routine);
        return routine.finish();
    }

    /// Assembles a routine with `build`, which the caller frees.
    pub fn assemble(gpa: Allocator, comptime build: fn (routine: *Routine) anyerror!void) ![]u8 {
        var routine: Routine = .init(gpa);
        defer routine.deinit();
        try build(&routine);
        return routine.finish();
    }

    /// A block that adds one to global `global`, which the caller frees.
    pub fn counting(gpa: Allocator, comptime global: u8) ![]u8 {
        return assemble(gpa, struct {
            fn build(r: *Routine) !void {
                try r.op(.select_global, &.{global});
                try r.op(.push_byte, &.{1});
                try r.op(.add_assign, &.{});
                try finishPartOps(r);
            }
        }.build);
    }

    /// The end of a start part as the tests' scripts end it: its result 1 returned.
    fn finishPartOps(routine: *Routine) !void {
        try routine.op(.push_byte, &.{1});
        try routine.op(.@"return", &.{});
    }

    /// A part: its routine's bytes, as `Routine.finish` gives them, and its arguments.
    pub const Part = struct { code: []const u8, arguments: u8 = 0, start: bool = false };

    /// Records for a script to name.
    pub const Records = struct {
        globals: []const u32 = &.{},
        ships: []const dte.Ship = &.{},
        flight_groups: []const dte.FlightGroup = &.{},
        objects: []const dte.Object = &.{},
        squads: []const dte.Squad = &.{},
        squad_members: []const dte.SquadMember = &.{},
        /// Each trigger's block is a part's, as `link` names it (`Fixture.link`).
        triggers: []const dte.Trigger = &.{},
        curves: []const dte.Curve = &.{},
        /// Section 24, a word for each command (`dte.CommandFlags`); none where it is empty, as
        /// the words past the section lie in the file's zeros.
        command_flags: []const dte.CommandFlags = &.{},
    };

    pub const Fixture = struct {
        mission: bind.Mission,
        random: libcmt.Rand = .{},
        machine: Machine,

        /// A mission whose script holds `parts` one after another, each a part of its own, with
        /// `records`, and a machine on it.
        pub fn init(fixture: *Fixture, gpa: Allocator, parts: []const Part, records: Records) !void {
            var script: std.ArrayList(u8) = .empty;
            defer script.deinit(gpa);
            var descriptors: std.ArrayList(dte.Part) = .empty;
            defer descriptors.deinit(gpa);
            for (parts) |part| {
                var descriptor = std.mem.zeroes(dte.Part);
                descriptor.offset = @intCast(script.items.len / @sizeOf(u16));
                descriptor.length = @intCast(part.code.len / @sizeOf(u16));
                descriptor.arguments = part.arguments;
                descriptor.flags.start = part.start;
                try descriptors.append(gpa, descriptor);
                try script.appendSlice(gpa, part.code);
            }
            const globals = try gpa.alloc(dte.Global, records.globals.len);
            defer gpa.free(globals);
            for (globals, records.globals) |*record, value| record.* = .{ .name = 0, ._unknown_02 = 0, .value = value, ._unknown_08 = 0 };
            var sections: write.Sections = @splat(.{});
            const section = write.set;
            section(&sections, .script, script.items.len / @sizeOf(u16), script.items);
            section(&sections, .parts, descriptors.items.len, std.mem.sliceAsBytes(descriptors.items));
            section(&sections, .globals, globals.len, std.mem.sliceAsBytes(globals));
            section(&sections, .ships, records.ships.len, std.mem.sliceAsBytes(records.ships));
            section(&sections, .flight_groups, records.flight_groups.len, std.mem.sliceAsBytes(records.flight_groups));
            section(&sections, .objects, records.objects.len, std.mem.sliceAsBytes(records.objects));
            section(&sections, .squads, records.squads.len, std.mem.sliceAsBytes(records.squads));
            section(&sections, .squad_members, records.squad_members.len, std.mem.sliceAsBytes(records.squad_members));
            section(&sections, .triggers, records.triggers.len, std.mem.sliceAsBytes(records.triggers));
            section(&sections, .curves, records.curves.len, std.mem.sliceAsBytes(records.curves));
            section(&sections, .command_flags, records.command_flags.len, std.mem.sliceAsBytes(records.command_flags));
            const image = try write.write(gpa, &sections, .{});
            fixture.mission = try .bind(gpa, image);
            fixture.random = .{};
            fixture.machine = .init(gpa, &fixture.mission, &fixture.random);
        }

        pub fn deinit(fixture: *Fixture) void {
            fixture.machine.deinit();
            fixture.mission.deinit();
        }

        /// The `link` of a trigger whose block is that of part `index` of `parts`: where the part's
        /// block lies in the script, in halfwords.
        pub fn link(parts: []const Part, index: usize) u16 {
            var at: usize = 0;
            for (parts[0..index]) |part| at += part.code.len;
            return @intCast(at / @sizeOf(u16));
        }

        /// Global `index`'s value.
        pub fn global(fixture: *Fixture, index: u8) u32 {
            return fixture.mission.word(fixture.mission.globalPlace(index)) catch unreachable;
        }

        /// A second of the mission, as the game's frame goes through it: the clock ticks, the timers
        /// run for the tick, and the threads run on.
        pub fn second(fixture: *Fixture) void {
            executor.clockTick(&fixture.machine);
            fixture.machine.runThreads();
            if (fixture.machine.ticked and fixture.machine.timers_running) {
                fixture.machine.runTimers();
                fixture.machine.ticked = false;
            }
        }
    };

    /// A game on a mission: the mission's script on a machine (`Fixture`), and a world of objects
    /// whose orders read its records, the mission bound as the game binds it (`main.startMission`).
    /// It stays where `init` fills it in, as the world points into it.
    pub const Game = struct {
        fixture: Fixture,
        /// The objects, the stats they are made from, and what the world points at.
        mission: gameobj.testing.Mission,

        /// The mission of `parts` and `records` (`Fixture.init`), and the objects.
        pub fn init(game: *Game, gpa: Allocator, parts: []const Part, records: Records) !void {
            try game.fixture.init(gpa, parts, records);
            errdefer game.fixture.deinit();
            try game.mission.init(gpa);
        }

        pub fn deinit(game: *Game) void {
            game.mission.deinit();
            game.fixture.deinit();
        }

        /// The world, the mission bound.
        pub fn world(game: *Game) gameobj.World {
            var seen = game.mission.world();
            seen.mission = &game.fixture.mission;
            return seen;
        }

        /// What the objects' orders run against: the world and its clock.
        pub fn orders(game: *Game) aigeneric.Context {
            return .of(game.world());
        }

        /// `orders`, the world making its ships from the test stats with no models
        /// (`gameobj.World.spawn`), as the commands that create a mission's ships need.
        pub fn spawning(game: *Game) aigeneric.Context {
            var on = game.orders();
            on.world.spawn = game.mission.spawn(create.testing.no_models);
            return on;
        }

        /// Starts the script, its commands acting on `on` (`Machine.game`).
        pub fn start(game: *Game, on: aigeneric.Context) !void {
            game.fixture.machine.game = on;
            try game.fixture.machine.start();
        }
    };
};

test "the arithmetic, the compares and the stores" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // Global 0 = 12, global 1 = 10 - 3.
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{12});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.op(.push_byte, &.{10});
            try r.op(.push_byte, &.{3});
            try r.op(.sub, &.{});
            try r.op(.assign, &.{});
            // Global 2 = none > 1, which holds, the values being unsigned.
            try r.op(.select_global, &.{2});
            try r.op(.push_null, &.{});
            try r.op(.push_byte, &.{1});
            try r.op(.greater, &.{});
            try r.op(.assign, &.{});
            // Global 3 += 6 * 7, a wide constant among them; variable 9 = 1.
            try r.op(.select_global, &.{3});
            try r.pushConstant(6);
            try r.pushConstant(7);
            try r.op(.mul, &.{});
            try r.op(.add_assign, &.{});
            try r.op(.select_array, &.{9});
            try r.op(.push_byte, &.{1});
            try r.op(.assign, &.{});
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0, 0, 100 } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(12, fixture.global(0));
    try std.testing.expectEqual(7, fixture.global(1));
    try std.testing.expectEqual(1, fixture.global(2));
    try std.testing.expectEqual(142, fixture.global(3));
    try std.testing.expectEqual(1, fixture.machine.variables.mission_over);
    // The start part's thread has finished.
    try std.testing.expectEqual(0, fixture.machine.thread_count);
    try std.testing.expect(fixture.machine.first_finished);
}

test "Wait holds a thread until the clock has passed its seconds" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{2});
            try r.command("Wait");
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{1});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(1, fixture.machine.thread_count);
    // At 1 and at 2 it waits; past 2 it runs on.
    fixture.second();
    fixture.second();
    try std.testing.expectEqual(0, fixture.global(0));
    fixture.second();
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "a call passes its arguments and returns its value" {
    const gpa = std.testing.allocator;
    const caller = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{4});
            try r.op(.push_byte, &.{5});
            try r.op(.call_part, &.{1});
            try r.op(.select_global, &.{0});
            try r.op(.push_result, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(caller);
    const called = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_argument, &.{0});
            try r.op(.push_argument, &.{1});
            try r.op(.add, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(called);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = caller, .start = true }, .{ .code = called, .arguments = 2 } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(9, fixture.global(0));
    // The return took the record and the arguments off the stack.
    try std.testing.expectEqual(0, fixture.machine.threads[0].top);
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "a spawned part takes its arguments to a thread of its own" {
    const gpa = std.testing.allocator;
    const spawner = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{3});
            try r.op(.spawn_part, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(spawner);
    const spawned = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.op(.push_argument, &.{0});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(spawned);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = spawner, .start = true }, .{ .code = spawned, .arguments = 1 } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    // The spawned thread waits for the pass.
    try std.testing.expectEqual(1, fixture.machine.thread_count);
    try std.testing.expectEqual(0, fixture.global(0));
    fixture.machine.runThreads();
    try std.testing.expectEqual(3, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "a timer starts its part every so many seconds, so many times" {
    const gpa = std.testing.allocator;
    const setter = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // CreateTimer(ID 1, part 1, every 2 seconds, twice).
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{2});
            try r.op(.push_byte, &.{2});
            try r.command("CreateTimer");
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(setter);
    const counter = try testing.counting(gpa, 0);
    defer gpa.free(counter);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = setter, .start = true }, .{ .code = counter } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(1, fixture.machine.timer_count);
    var counts: [6]u32 = undefined;
    for (&counts) |*count| {
        fixture.second();
        // The part the timer started runs at the next pass.
        fixture.machine.runThreads();
        count.* = fixture.global(0);
    }
    try std.testing.expectEqual([6]u32{ 0, 1, 1, 2, 2, 2 }, counts);
    try std.testing.expectEqual(0, fixture.machine.timer_count);
}

test "a command not ported yet does nothing and lets the thread run on" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_ship, &.{0});
            try r.op(.push_byte, &.{2});
            try r.command("PrintShipName");
            try r.op(.select_global, &.{0});
            try r.op(.push_result, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "command_b pops its arguments and gives 1" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // Test_AI_Function's two arguments, and none for the record that ends the catalogue.
            try r.op(.push_byte, &.{7});
            try r.op(.push_byte, &.{8});
            try r.op(.command_b, &.{0});
            try r.op(.select_global, &.{0});
            try r.op(.push_result, &.{});
            try r.op(.assign, &.{});
            try r.op(.command_b, &.{1});
            try r.op(.select_global, &.{1});
            try r.op(.push_result, &.{});
            try r.op(.add_assign, &.{});
            // Past the catalogue, the thread ends.
            try r.op(.command_b, &.{2});
            try r.op(.select_global, &.{1});
            try r.op(.push_byte, &.{5});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0 } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(1, fixture.global(0));
    try std.testing.expectEqual(1, fixture.global(1));
    try std.testing.expectEqual(0, fixture.machine.threads[0].top);
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "InterruptTriggerCode holds a thread until its trigger fires again" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.command("InterruptTriggerCode");
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{1});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    fixture.machine.runThreads();
    try std.testing.expectEqual(0, fixture.global(0));
    try std.testing.expectEqual(1, fixture.machine.thread_count);
    // As its trigger fires again.
    fixture.machine.threads[0].record.interrupted = false;
    fixture.machine.runThreads();
    try std.testing.expectEqual(1, fixture.global(0));
}

test "KillAllScriptExecutionExecptMe ends every other thread" {
    const gpa = std.testing.allocator;
    const killer = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.spawn_part, &.{1});
            try r.op(.spawn_part, &.{1});
            try r.command("KillAllScriptExecutionExecptMe");
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(killer);
    const idle = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(idle);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = killer, .start = true }, .{ .code = idle } }, .{});
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "OpenInstrument holds a window of the display open until CloseInstrument" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // The objectives open, which closes the wing status window; a window past the fifteen
            // opens nothing.
            try r.op(.push_byte, &.{@intFromEnum(hud.windows.Window.objectives)});
            try r.command("OpenInstrument");
            try r.op(.push_byte, &.{16});
            try r.command("OpenInstrument");
            // A second on, the objectives close.
            try r.op(.push_byte, &.{1});
            try r.command("Wait");
            try r.op(.push_byte, &.{@intFromEnum(hud.windows.Window.objectives)});
            try r.command("CloseInstrument");
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var game: testing.Game = undefined;
    try game.init(gpa, &.{.{ .code = code, .start = true }}, .{});
    defer game.deinit();
    var display: hud.State = .{};
    _ = display.windows.open(.wing_status, false);
    var on = game.orders();
    on.world.display = &display;
    try game.start(on);

    const windows = &display.windows;
    try std.testing.expect(windows.up(.objectives) and windows.status.get(.objectives).held);
    try std.testing.expect(!windows.up(.wing_status));
    for (0..2) |_| game.fixture.second();
    try std.testing.expect(!windows.up(.objectives) and !windows.status.get(.objectives).held);
    try std.testing.expect(game.fixture.machine.finished);
}

test "random_branch takes the first arm its roll falls below" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            const low = try r.label();
            const high = try r.label();
            const other = try r.label();
            const done = try r.label();
            try r.randomBranch(other, &.{ .{ .target = low, .threshold = 50, .extra = 0 }, .{ .target = high, .threshold = 100, .extra = 0 } });
            r.place(low);
            try r.op(.push_byte, &.{1});
            try r.branch(.jump, done);
            r.place(high);
            try r.op(.push_byte, &.{2});
            try r.branch(.jump, done);
            r.place(other);
            try r.op(.push_byte, &.{3});
            r.place(done);
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{0});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{0});
            try r.op(.add_assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    var expected: libcmt.Rand = .{};
    const roll = @rem(expected.rand(), Machine.roll_range);
    try fixture.machine.start();
    // The roll picked an arm, whose value lies under the stores.
    try std.testing.expectEqual(@as(u32, if (roll < 50) 1 else 2), fixture.machine.threads[0].record.stack[0]);
}

test "push_string pushes where its text lies" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.pushString("hello");
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(fixture.mission.image[fixture.global(0)..], 0));
}

test "the float opcodes round as the FPU does at single precision" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // 2^24 + 1 comes back 2^24.
            try r.op(.select_global, &.{0});
            try r.pushConstant(16777217);
            try r.op(.push_byte, &.{0});
            try r.op(.add_f, &.{});
            try r.op(.assign, &.{});
            // Half of 200: 200 * 50 times a hundredth rounds to 100, where truncating the exact
            // product would give 99.
            try r.op(.select_global, &.{1});
            try r.op(.push_byte, &.{200});
            try r.op(.push_percent, &.{50});
            try r.op(.assign, &.{});
            try r.op(.push_byte, &.{0});
            // A float global, 1.5, plus 2.
            try r.op(.select_global, &.{2});
            try r.op(.push_byte, &.{2});
            try r.op(.add_assign_f, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0, @bitCast(@as(f32, 1.5)) } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(16777216, fixture.global(0));
    try std.testing.expectEqual(100, fixture.global(1));
    try std.testing.expectEqual(@as(f32, 3.5), @as(f32, @bitCast(fixture.global(2))));
}

test "a fault ends the thread" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{0});
            try r.op(.div, &.{});
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{1});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(0, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "in_flight_group and in_squad" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // Ship 0 is in flight group 0, ship 1 is not.
            try r.op(.select_global, &.{0});
            try r.op(.push_ship, &.{0});
            try r.op(.push_flight_group, &.{0});
            try r.op(.in_flight_group, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.op(.push_ship, &.{1});
            try r.op(.push_flight_group, &.{0});
            try r.op(.not_in_flight_group, &.{});
            try r.op(.assign, &.{});
            // Squad 0 holds ship 1 itself, and ship 0 through its flight group.
            try r.op(.select_global, &.{2});
            try r.op(.push_ship, &.{1});
            try r.op(.push_squad, &.{0});
            try r.op(.in_squad, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{3});
            try r.op(.push_ship, &.{0});
            try r.op(.push_squad, &.{0});
            try r.op(.in_squad, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    const records = dte.testing;
    var ships = records.ships(2, 0);
    ships[0].flight_group = 0;
    const whole_ship = dte.Trigger.whole_object;
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{ 0, 0, 0, 0 },
        .ships = &ships,
        .flight_groups = &.{records.flightGroup(2, .player)},
        .objects = &.{ records.object(.ship, 0, 0), records.object(.ship, 0, 0), records.object(.flight_group, 0, 0), records.object(.squad, 0, 0) },
        .squads = &.{records.squad(3, 0)},
        .squad_members = &.{ records.squadMember(1, 0, whole_ship), records.squadMember(2, 0, whole_ship) },
    });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual([4]u32{ 1, 1, 1, 1 }, [4]u32{ fixture.global(0), fixture.global(1), fixture.global(2), fixture.global(3) });
}

test "the branches and the logic" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            const skip = try r.label();
            const never = try r.label();
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{5});
            try r.op(.assign, &.{});
            // Zero branches.
            try r.op(.push_byte, &.{0});
            try r.branch(.branch_if_zero, skip);
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{9});
            try r.op(.assign, &.{});
            r.place(skip);
            // One runs on.
            try r.op(.push_byte, &.{1});
            try r.branch(.branch_if_zero_alt, never);
            try r.op(.select_global, &.{1});
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{0});
            try r.op(.logical_or, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{2});
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{0});
            try r.op(.logical_and, &.{});
            try r.op(.assign, &.{});
            r.place(never);
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0, 7 } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual([3]u32{ 5, 1, 0 }, [3]u32{ fixture.global(0), fixture.global(1), fixture.global(2) });
}

test "the float opcodes take one value unsigned and the other signed" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // 5 less -3 is 8; 3 times -2 is -6; 7 over 2 is 3 once truncated; over zero, 0.
            try r.op(.select_global, &.{0});
            try r.op(.push_byte, &.{5});
            try r.pushConstant(@bitCast(@as(i32, -3)));
            try r.op(.sub_f, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.pushConstant(@bitCast(@as(i32, -2)));
            try r.op(.push_byte, &.{3});
            try r.op(.mul_f, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{2});
            try r.op(.push_byte, &.{7});
            try r.op(.push_byte, &.{2});
            try r.op(.div_f, &.{});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{3});
            try r.op(.push_byte, &.{7});
            try r.op(.push_byte, &.{0});
            try r.op(.div_f, &.{});
            try r.op(.assign, &.{});
            // A float global, 6: less 2, times 3, over 4.
            try r.op(.select_global, &.{4});
            try r.op(.push_byte, &.{2});
            try r.op(.sub_assign_f, &.{});
            try r.op(.push_byte, &.{0});
            try r.op(.select_global, &.{4});
            try r.op(.push_byte, &.{3});
            try r.op(.mul_assign_f, &.{});
            try r.op(.push_byte, &.{0});
            try r.op(.select_global, &.{4});
            try r.op(.push_byte, &.{4});
            try r.op(.div_assign_f, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{ 0, 0, 0, 1, @bitCast(@as(f32, 6)) } });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(8, fixture.global(0));
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -6))), fixture.global(1));
    try std.testing.expectEqual(3, fixture.global(2));
    try std.testing.expectEqual(0, fixture.global(3));
    try std.testing.expectEqual(@as(f32, 3), @as(f32, @bitCast(fixture.global(4))));
}

test "a part stores into its argument" {
    const gpa = std.testing.allocator;
    const caller = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{1});
            try r.op(.call_part, &.{1});
            try r.op(.select_global, &.{0});
            try r.op(.push_result, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(caller);
    const called = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_argument, &.{0});
            try r.op(.push_byte, &.{7});
            try r.op(.assign, &.{});
            try r.op(.push_argument, &.{0});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(called);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = caller, .start = true }, .{ .code = called, .arguments = 1 } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(7, fixture.global(0));
}

test "push_local and push_event_value read what the event brought" {
    const gpa = std.testing.allocator;
    const kept = comptime for (vm.conditions.table, 0..) |condition, index| {
        if (condition.slot == 1) break index;
    } else unreachable;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.op(.push_local, &.{2});
            try r.op(.assign, &.{});
            try r.op(.select_global, &.{1});
            try r.op(.push_event_value, &.{ kept, 1, 0 });
            try r.op(.assign, &.{});
            try r.op(.push_byte, &.{1});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{.{ .code = code }}, .{ .globals = &.{ 0, 0 }, .objects = &.{dte.testing.object(.ship, 0, 0)} });
    defer fixture.deinit();
    try fixture.machine.start();
    fixture.machine.event_values[0].destroyed[1] = 42;
    const thread = fixture.machine.startThread(fixture.mission.parts[0].block, null, true, null, 3).?;
    fixture.machine.threads[thread].record.locals[2] = 17;
    fixture.machine.runThreads();
    try std.testing.expectEqual(17, fixture.global(0));
    try std.testing.expectEqual(42, fixture.global(1));
}

test "argumentComponent finds a command's argument's component" {
    var machine: Machine = .{ .gpa = std.testing.allocator, .mission = undefined, .random = undefined };
    // The command's arguments start at place 2; push_component tagged the second.
    machine.threads[0].top = 2;
    machine.tags.add(5, 3);
    try std.testing.expectEqual(5, machine.argumentComponent(0, 1));
    try std.testing.expectEqual(null, machine.argumentComponent(0, 0));
    machine.tags.clear();
    try std.testing.expectEqual(null, machine.argumentComponent(0, 1));
}

test "Tags.add keeps the first eight of more" {
    var tags: Tags = .{};
    for (0..vm.ComponentTag.max + 1) |n| tags.add(@intCast(n), @intCast(n));
    try std.testing.expectEqual(vm.ComponentTag.max, tags.count);
    try std.testing.expectEqual(vm.ComponentTag.max - 1, tags.tags[vm.ComponentTag.max - 1].component);
}

test "DestroyTimer destroys the timer before it fires" {
    const gpa = std.testing.allocator;
    const setter = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // CreateTimer(ID 1, part 1, every second, for ever), then DestroyTimer(1).
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{1});
            try r.op(.push_byte, &.{0});
            try r.command("CreateTimer");
            try r.op(.push_byte, &.{1});
            try r.command("DestroyTimer");
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(setter);
    const counter = try testing.counting(gpa, 0);
    defer gpa.free(counter);
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = setter, .start = true }, .{ .code = counter } }, .{ .globals = &.{0} });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(0, fixture.machine.timer_count);
    for (0..4) |_| {
        fixture.second();
        fixture.machine.runThreads();
    }
    try std.testing.expectEqual(0, fixture.global(0));
    try std.testing.expect(fixture.machine.timers[0].isFree());
}

test "in_squad ends the thread on a squad that holds itself" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.op(.push_ship, &.{0});
            try r.op(.push_squad, &.{0});
            try r.op(.in_squad, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    const records = dte.testing;
    var fixture: testing.Fixture = undefined;
    // Squad 0, object 1, is its own only member.
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{7},
        .ships = &records.ships(1, 0),
        .objects = &.{ records.object(.ship, 0, 0), records.object(.squad, 0, 0) },
        .squads = &.{records.squad(1, 0)},
        .squad_members = &.{records.squadMember(1, 0, dte.Trigger.whole_object)},
    });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual(7, fixture.global(0));
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "in_squad takes the members of the squad the place names as squad_index counts it" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            // Zero names no squad, which `squad_index` gives as `no_record`.
            try r.op(.select_global, &.{0});
            try r.op(.push_ship, &.{0});
            try r.op(.push_byte, &.{0});
            try r.op(.in_squad, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    const records = dte.testing;
    var fixture: testing.Fixture = undefined;
    // The only member, ship 0, is of the squad `no_record` numbers.
    try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{
        .globals = &.{0},
        .ships = &records.ships(1, 0),
        .objects = &.{records.object(.ship, 0, 0)},
        .squad_members = &.{records.squadMember(0, bind.Mission.no_record, dte.Trigger.whole_object)},
    });
    defer fixture.deinit();
    // The squad's first member, read where zero places it, in the directory, is the first.
    try std.testing.expectEqual(0, try fixture.mission.halfword(@offsetOf(dte.Squad, "first_member")));
    try fixture.machine.start();
    try std.testing.expectEqual(1, fixture.global(0));
}

test "in_flight_group and in_squad end the thread where the game faults on none" {
    const gpa = std.testing.allocator;
    const not_in_group = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{0});
            try r.op(.push_null, &.{});
            try r.op(.push_flight_group, &.{0});
            try r.op(.not_in_flight_group, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(not_in_group);
    const not_in_squad = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{1});
            try r.op(.push_ship, &.{0});
            try r.op(.push_null, &.{});
            try r.op(.not_in_squad, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(not_in_squad);
    // A squad whose first member lies past the members gives false without reading the object.
    const past = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.select_global, &.{2});
            try r.op(.push_null, &.{});
            try r.op(.push_squad, &.{1});
            try r.op(.in_squad, &.{});
            try r.op(.assign, &.{});
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(past);
    const records = dte.testing;
    var ships = records.ships(2, 0);
    ships[0].flight_group = 0;
    var fixture: testing.Fixture = undefined;
    try fixture.init(gpa, &.{ .{ .code = not_in_group, .start = true }, .{ .code = not_in_squad, .start = true }, .{ .code = past, .start = true } }, .{
        .globals = &.{ 0, 0, 7 },
        .ships = &ships,
        .flight_groups = &.{records.flightGroup(2, .player)},
        .objects = &.{ records.object(.ship, 0, 0), records.object(.ship, 0, 0), records.object(.flight_group, 0, 0), records.object(.squad, 0, 0), records.object(.squad, 0, 0) },
        .squads = &.{ records.squad(3, 0), records.squad(4, 1) },
        .squad_members = &.{records.squadMember(0, 0, dte.Trigger.whole_object)},
    });
    defer fixture.deinit();
    try fixture.machine.start();
    try std.testing.expectEqual([3]u32{ 0, 0, 0 }, [3]u32{ fixture.global(0), fixture.global(1), fixture.global(2) });
    try std.testing.expectEqual(0, fixture.machine.thread_count);
}

test "a command's flags are read where its number places them, whatever the section's count" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_byte, &.{9});
            try r.command("DestroyTimer");
            try r.op(.@"return", &.{});
        }
    }.build);
    defer gpa.free(code);
    const entry = @intFromEnum(dte.Section.command_flags) * @sizeOf(dte.DirectoryEntry);
    for ([_]bool{ true, false }) |within| {
        var fixture: testing.Fixture = undefined;
        try fixture.init(gpa, &.{.{ .code = code, .start = true }}, .{ .globals = &.{1} });
        defer fixture.deinit();
        // Section 24 counts no words, and starts at the globals, where `DestroyTimer`'s word is
        // the low half of global 0's value, 1; or at the image's end, past which there is none.
        const image = fixture.mission.image;
        const offset: u32 = if (within) fixture.mission.file.entry(.globals).offset else @intCast(image.len);
        std.mem.writeInt(u16, image[entry..][0..2], 0, .little);
        std.mem.writeInt(u32, image[entry + @offsetOf(dte.DirectoryEntry, "offset") ..][0..4], offset, .little);
        try fixture.machine.start();
        try std.testing.expectEqual(!within, fixture.machine.skips_players);
    }
}

test "a walking command passes over the players' ships unless its flags take them in" {
    const gpa = std.testing.allocator;
    const code = try testing.assemble(gpa, struct {
        fn build(r: *testing.Routine) !void {
            try r.op(.push_flight_group, &.{0});
            try r.op(.push_byte, &.{1});
            try r.command("SetHostile");
            try testing.finishPartOps(r);
        }
    }.build);
    defer gpa.free(code);
    var ships = dte.testing.ships(2, 0);
    for (&ships) |*ship| ship.flight_group = 0;
    var flags: [executor.commands.table.len]dte.CommandFlags = @splat(.{});
    flags[executor.commandIndex("SetHostile")].players = true;
    for ([_][]const dte.CommandFlags{ &.{}, &flags }) |command_flags| {
        var game: testing.Game = undefined;
        try game.init(gpa, &.{.{ .code = code, .start = true }}, .{
            .ships = &ships,
            .flight_groups = &.{dte.testing.flightGroup(2, .player)},
            .command_flags = command_flags,
        });
        defer game.deinit();
        try game.start(game.orders());
        const all = game.mission.objects;
        try std.testing.expectEqual(1, all.players);
        const players = command_flags.len != 0;
        try std.testing.expectEqual(@as(gameobj.Side(i32), if (players) .hostile else .friendly), all.slots[0].object.side);
        try std.testing.expectEqual(.hostile, all.slots[1].object.side);
    }
}
