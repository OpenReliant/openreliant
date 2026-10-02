//! The mission script VM's run-time structures. **Unknown:** its source file; the interpreter's
//! code lies between `mission.cpp`'s and `attach.cpp`'s. [`vm/opcodes.zig`](vm/opcodes.zig) and
//! [`vm/conditions.zig`](vm/conditions.zig) transcribe its opcode and condition tables.
//!
//! A thread runs one block with a stack of its own. While it runs, the interpreter (`vm_run`,
//! `0x0045C980`) keeps its stack pointer and block end in globals (`vm_stack_top`, `0x00537570`;
//! `vm_block_end`, `0x005373F0`) and hands every opcode handler the addresses of the thread's
//! instruction pointer and frame pointer.

const std = @import("std");
const assert = std.debug.assert;

const dte = @import("../formats/dte.zig");
const layout = @import("../formats/layout.zig");
const commands = @import("game/executor/commands.zig");
const engine = @import("../engine.zig");
const hud = @import("game/hud.zig");
const Code = engine.Code;
const Pointer = engine.Pointer;

pub const opcodes = @import("vm/opcodes.zig");
pub const conditions = @import("vm/conditions.zig");
pub const machine = @import("vm/machine.zig");
pub const triggers = @import("vm/triggers.zig");
pub const Machine = machine.Machine;
pub const Implementation = machine.Implementation;
pub const GameImplementation = machine.GameImplementation;
pub const run_on = machine.run_on;
pub const yield = machine.yield;

/// An opcode handler, called through `vm_dispatch_table`. `ip` points at the thread's instruction
/// pointer, already past the opcode, and `frame` at its frame pointer. `previous` is what the last
/// handler returned. A handler returns it to carry on, or zero to end the loop.
pub const Handler = Code("uint __fastcall (byte **ip, uint **frame, uint previous)");

/// A command's implementation, which `command` calls through the catalogue. `args` points at its
/// first argument on the stack. The result is stored in `Thread.result`, and a zero result also
/// ends the handler loop.
pub const Command = Code("uint __fastcall (byte **ip, uint *args)");

/// What a command hands `for_each_ship` to run for each ship its first argument names: the ship,
/// and the command's remaining arguments.
pub const ShipCommand = Code("uint __fastcall (MissionShip *ship, uint *args)");

/// Threads the pool at `vm_threads` holds. `vm_thread_start` (`0x0045B8D0`) starts none while 31
/// are running.
pub const max_threads = 32;

/// Timers the table at `vm_timers` (`0x004F6344`) holds.
pub const max_timers = 16;

/// The values an event carries at most, which a thread's locals and each event an object keeps
/// have room for.
pub const max_event_values = 5;

/// A script thread.
pub const Thread = extern struct {
    /// Stack pointer, saved while the thread is suspended.
    stack_top: Pointer(u32),
    /// End of the running block, where its constants start. Saved like `stack_top`.
    block_end: Pointer(u8),
    /// The running part's first argument: `push_argument n` reads `frame[n]`.
    frame: Pointer(u32),
    /// Value of `vm_clock` to resume at, or zero when not waiting.
    wake_time: u32,
    /// Next instruction to run. Null for a free slot.
    ip: Pointer(u8),
    /// Block end at which the script debugger's step-over stops.
    step_block_end: Pointer(u8),
    /// The values of the event that started the thread, which `push_local` reads.
    locals: [max_event_values]u32,
    stack: [32]u32,
    /// **Unknown.** `unknown_ac_start` when the thread starts.
    _unknown_ac: u8,
    /// Parts called and not yet returned from. A `return` at depth zero ends the thread.
    call_depth: u8,
    /// Set by `InterruptTriggerCode`: the thread waits for its trigger to fire again, which clears
    /// it, and the pass over the threads (`vm_threads_run`) leaves it alone until then.
    interrupted: bool,
    /// The low byte of the index of the trigger that started the thread, or `no_trigger` for none.
    trigger: u8,
    /// The last command's result, or the value the last part returned: what `push_result` reads.
    result: u32,
    /// **Unknown.** Zero when the thread starts.
    _unknown_b4: u32,

    /// The `trigger` of a thread no trigger started (`part_run`, `0x0045BAB5`).
    pub const no_trigger: u8 = 0xFF;

    /// The `_unknown_ac` of a thread as it starts (`vm_thread_start`, `0x0045B92F`).
    pub const unknown_ac_start: u8 = 0xFF;

    comptime {
        assert(@offsetOf(Thread, "wake_time") == 0x0C);
        assert(@offsetOf(Thread, "ip") == 0x10);
        assert(@offsetOf(Thread, "locals") == 0x18);
        assert(@offsetOf(Thread, "stack") == 0x2C);
        assert(@offsetOf(Thread, "call_depth") == 0xAD);
        assert(@offsetOf(Thread, "result") == 0xB0);
        assert(@sizeOf(Thread) == 0xB8);
    }
};

/// What `call_part` pushes above a part's arguments, and `return` pops. The thread's frame pointer
/// then points at the first argument, `4 * arguments + 16` bytes below the stack pointer.
pub const CallRecord = extern struct {
    argument_count: u32,
    return_ip: Pointer(u8),
    caller_frame: Pointer(u32),
    caller_block_end: Pointer(u8),

    comptime {
        assert(@sizeOf(CallRecord) == 0x10);
    }
};

/// An entry of the command catalogue, or of a mission's part table: what `command` and
/// `call_part` call. The catalogue fills every field; a part's entry has only its block and its
/// argument count.
pub const Function = extern struct {
    entry: Entry,
    /// Arguments taken from the stack. The engine reads a byte of the catalogue's dword.
    argument_count: u8,
    _unknown_05: [3]u8,
    name: Pointer(u8),
    params: [max_params]Param,
    description: Pointer(u8),
    /// **Unknown.**
    flag: u32,

    pub const max_params = 8;

    pub const Entry = extern union {
        implementation: Pointer(Command),
        /// The part's block: its length halfword, then its code.
        block: Pointer(u16),
    };

    pub const Param = extern struct {
        kinds: commands.Kinds,
        /// **Unknown.**
        extra: u32,
        label: Pointer(u8),
    };

    comptime {
        assert(@offsetOf(Function, "name") == 0x08);
        assert(@offsetOf(Function, "params") == 0x0C);
        assert(@offsetOf(Function, "description") == 0x6C);
        assert(@sizeOf(Function) == 0x74);
    }
};

/// A timer that `CreateTimer` set.
pub const Timer = extern struct {
    /// The part to start, or `free_part` for a free entry.
    part: i32,
    /// Countdown to reload after each firing.
    period: u16,
    /// Firings left. Zero for no limit; `DestroyTimer` runs after the last.
    remaining: u16,
    /// Clock ticks to the next firing.
    countdown: u16,
    /// The ID the script gave it, which `DestroyTimer` takes.
    id: u16,
    /// `vm_clock` when it last counted down, so that it counts once per tick.
    last_tick: u32,

    /// The `part` of a free entry (`vm_run_timers`, `0x0045D162`).
    pub const free_part: i32 = -1;

    pub fn isFree(timer: *const Timer) bool {
        return timer.part == free_part;
    }

    /// Frees the entry, as `DestroyTimer` does.
    pub fn free(timer: *Timer) void {
        timer.part = free_part;
    }

    comptime {
        assert(@sizeOf(Timer) == 0x10);
    }
};

/// An entry of a part table (`part_table`, `part_table_b`) as OpenReliant keeps it: the part's
/// block, by where it lies in the mission image, and its argument count. `mission_fill_part`
/// (`0x00452FD0`) fills the game's `Function` with the same two.
pub const Part = struct {
    /// Where the block's length halfword lies in the mission image; null for a part with no block.
    block: ?u32 = null,
    argument_count: u8 = 0,
};

/// Entries each part table has room for (`mission_alloc_part_tables`, `0x0045CB40`).
pub const part_table_size = 256;

/// A part table: the mission's parts, then entries of no block. **Fix:** the game leaves the
/// entries past the mission's parts as `malloc` gave them, and a call to one runs whatever they
/// hold.
pub const Parts = [part_table_size]Part;

/// The game's variables a script reads and writes by number (`push_array`, `select_array`): the
/// block of 64 dwords from `jump_ready` (`0x0052A3F0`) up to the next global (`0x0052A4F0`), of
/// which the engine and the shipped missions use the first 38. Some belong to an attempt at a
/// mission, which `gameflow.resetVariables` clears before each; the rest belong to the campaign,
/// which a new one sets (`gameflow.newCampaign`) and the pilot's saved game keeps. **Unknown:**
/// what most of the campaign's stand for: flags a new campaign sets, which the scripts clear as
/// the story's characters die and the flow between missions reads
/// ([#381](https://github.com/vdmkenny/openreliant/issues/381)).
pub const Variables = extern struct {
    /// `jump_ready` and `warp_ready` (0 and 1): whether the mission has a jump or a warp ready for
    /// JUMP DRIVE, which the display's prompt reads (`hud.Readiness`).
    ready: hud.Readiness = .{},
    _unknown_2: u32 = 0,
    /// `backup_available` (3): whether the carrier sends backup when the pilot asks for it. The
    /// radio's REQUEST BACKUP (`0x004558D0`) raises the mission's PlayerWantsBackup event for the
    /// first request while it is set, and the carrier refuses otherwise. The scripts set it as
    /// backup can come and clear it as it can no longer (`videoreports.requestBackup`).
    backup_available: u32 = 0,
    /// `player_missiles_left` (4): the missile display's counts together.
    player_missiles_left: u32 = 0,
    _unknown_5: [4]u32 = @splat(0),
    /// `mission_over` (9): set once the camera has watched the mission's end long enough, or once
    /// the player's ship has landed.
    mission_over: u32 = 0,
    /// `landing_cleared` (10): whether PERMISSION TO LAND is granted, and the player's ship lands
    /// (`videoreports.permissionToLand`). Mission 1's script sets it as the Reliant jumps in.
    landing_cleared: u32 = 0,
    _unknown_11: [3]u32 = @splat(0),
    /// `mission_success` (14): how the script rates the mission.
    mission_success: Outcome = .failure,
    /// `script_players` (15): how many players fly the mission, which the game gives the script as
    /// the mission starts (`script_set_players`, `0x004124D0`): 1 outside a multiplayer game. The
    /// scripts test it for the enemies a multiplayer game adds, and for which of a part's endings
    /// runs: mission 1's ambush ends only for the count it was flown with.
    players: u32 = 0,
    _unknown_16: [11]u32 = @splat(0),
    /// `last_success` (27): how the script rated the last mission the pilot came through, which the
    /// mission's end keeps unless the rating is a total failure (`mission_end_record`,
    /// `0x00475AC2`). Mission 25's second part weighs its own rating by it. Mission 1's script
    /// clears it as the mission starts, and a few others set it; the mission's end then writes
    /// over both.
    last_success: Outcome = .failure,
    /// `objectives_met` (28): set by the script once the mission's objectives are met, as mission
    /// 1's is once the ambushers are destroyed. The debriefing of a mission the ejected pilot was
    /// picked up in tells the pilot the mission was a success by it, and a failure without it
    /// (`0x00424ECE`, `0x0042545B`). **Not ported:** the debriefing
    /// ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
    objectives_met: u32 = 0,
    _unknown_29: u32 = 0,
    /// `ghost_alive` (30): whether Ghost, the ace mission 1 puts up against the player, lives: 1 in
    /// a new campaign. Mission 1's script clears it as Ghost dies, and mission 4's has Petrov say
    /// a line by it. The engine only keeps it with the pilot's game.
    ghost_alive: u32 = 0,
    _unknown_31: [2]u32 = @splat(0),
    /// `countdown` (33): seconds left, which mission 29's script sets and the display shows as a
    /// clock in minutes and seconds (`hud.clockTime`). The game takes one off at every 100th tick
    /// of the mission (`gameobj.gameTick`).
    countdown: i32 = 0,
    _unknown_34: u32 = 0,
    _unknown_35: [2]u32 = @splat(0),
    /// `ion_cannons_hold_lock` (37): while it is set, the Dark Reign's ion cannon keeps its target
    /// (`aiioncan.cpp`, order 110): it loses it neither as the target flies into its cone or out of
    /// the angle it fires in, nor, in a multiplayer game, after a long search (`0x0040D40F`,
    /// `0x0040D7D9`). **Not ported:** the order
    /// ([#30](https://github.com/vdmkenny/openreliant/issues/30)).
    ion_cannons_hold_lock: u32 = 0,
    /// The rest of the block, which neither the engine nor the shipped missions use.
    spare: [26]u32 = @splat(0),
    /// Room for every number past the block that a byte names. In the game these are the globals
    /// after the block, which no shipped mission touches.
    beyond: [count - block_size]u32 = @splat(0),

    /// How many variables the block holds, up to the next global.
    pub const block_size = 64;

    /// How many variables the script can number: every number a byte names.
    pub const count = std.math.maxInt(u8) + 1;

    /// Variable `index`, as the script numbers them.
    pub fn slot(variables: *Variables, index: u8) *u32 {
        return &@as(*[count]u32, @ptrCast(variables))[index];
    }

    /// The number the scripts give the variable `name`.
    pub fn number(comptime name: []const u8) u8 {
        return @offsetOf(Variables, name) / @sizeOf(u32);
    }

    /// How the script rates the mission, as the game's debug line names each rating: the carrier's
    /// clearance to land picks its line by it, and a rating past the named ones is "incorrectly
    /// defined".
    pub const Outcome = enum(i32) {
        /// "Total Failure (kick out)".
        total_failure = -1,
        failure = 0,
        partial_failure = 1,
        partial_success = 2,
        success = 3,
        /// "Success + Bonus".
        success_bonus = 4,
        _,

        pub fn format(outcome: Outcome, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return layout.formatTag(Outcome, outcome, writer);
        }
    };

    comptime {
        const at = struct {
            fn at(name: []const u8, address: u32) void {
                assert(@offsetOf(Variables, name) == address - 0x0052A3F0);
            }
        }.at;
        at("backup_available", 0x0052A3FC);
        at("player_missiles_left", 0x0052A400);
        at("mission_over", 0x0052A414);
        at("landing_cleared", 0x0052A418);
        at("mission_success", 0x0052A428);
        at("players", 0x0052A42C);
        at("last_success", 0x0052A45C);
        at("objectives_met", 0x0052A460);
        at("ghost_alive", 0x0052A468);
        at("countdown", 0x0052A474);
        at("ion_cannons_hold_lock", 0x0052A484);
        at("spare", 0x0052A488);
        at("beyond", 0x0052A4F0);
        assert(@offsetOf(Variables, "beyond") == block_size * @sizeOf(u32));
        assert(@sizeOf(Variables) == count * @sizeOf(u32));
    }
};

test Variables {
    var variables: Variables = .{};
    variables.slot(0).* = 1;
    variables.slot(3).* = 1;
    variables.slot(9).* = 1;
    variables.slot(10).* = 1;
    variables.slot(14).* = 3;
    variables.slot(15).* = 2;
    variables.slot(27).* = 4;
    variables.slot(28).* = 1;
    variables.slot(30).* = 1;
    variables.slot(33).* = 110;
    variables.slot(37).* = 1;
    variables.slot(255).* = 7;
    try std.testing.expectEqual(.newly, variables.ready.jump);
    try std.testing.expectEqual(1, variables.backup_available);
    try std.testing.expectEqual(1, variables.mission_over);
    try std.testing.expectEqual(1, variables.landing_cleared);
    try std.testing.expectEqual(.success, variables.mission_success);
    try std.testing.expectEqual(2, variables.players);
    try std.testing.expectEqual(.success_bonus, variables.last_success);
    try std.testing.expectEqual(1, variables.objectives_met);
    try std.testing.expectEqual(1, variables.ghost_alive);
    try std.testing.expectEqual(110, variables.countdown);
    try std.testing.expectEqual(1, variables.ion_cannons_hold_lock);
    try std.testing.expectEqual(7, variables.beyond[191]);
    try std.testing.expectEqual(10, Variables.number("landing_cleared"));
    try std.testing.expectEqual(30, Variables.number("ghost_alive"));
}

/// One condition of the catalogue at `condition_descriptors` (`0x004F6698`).
pub const ConditionDescriptor = extern struct {
    /// The developers' `TT_*` name, without the prefix.
    name: Pointer(u8),
    /// **Unknown.** Zero, except `0x400` for the internal `ExplosionShip`.
    _unknown_04: u16,
    /// The kinds of object whose triggers can have this condition.
    subjects: dte.Object.KindSet,
    /// The values an event of this condition carries, in order, up to an entry with a null label.
    /// Null for none.
    values: Pointer(EventValue),
    /// Index into `ObjectEvents` under which the matcher keeps each object's last event, for
    /// `push_event_value`. `none` for none.
    slot: u8,
    /// Triggers with this repeat mode fire even when `verdict` vetoes the event; `none` for none.
    veto_exempt: dte.Trigger.Repeat,
    _unknown_0e: u16,
    /// Called before an event on a flight group or squad is counted.
    begin: Pointer(anyopaque),
    /// Called once for each member of the flight group.
    add_member: Pointer(anyopaque),
    /// Returns whether the event goes ahead: the value of `condition_verdict`.
    verdict: Pointer(anyopaque),

    /// What `slot` and `veto_exempt` hold for none.
    pub const none: u8 = 0xFF;

    comptime {
        assert(@offsetOf(ConditionDescriptor, "subjects") == 0x06);
        assert(@offsetOf(ConditionDescriptor, "slot") == 0x0C);
        assert(@offsetOf(ConditionDescriptor, "begin") == 0x10);
        assert(@sizeOf(ConditionDescriptor) == 0x1C);
    }
};

/// One value an event carries: an entry of a condition's `values` list.
pub const EventValue = extern struct {
    label: Pointer(u8),
    kinds: commands.Kinds,
    /// **Unknown.** `0xFF`, or `0x09` for the weapon of `ShotAt`.
    _unknown_08: u8,
    /// Whether a trigger's operand for this value is checked against the event's.
    checked: bool,
    _unknown_0a: u16,

    comptime {
        assert(@sizeOf(EventValue) == 0x0C);
    }
};

/// The component `push_component` named for a value it pushed. The list at `vm_component_tags`
/// (`0x004F6340`) holds one per such value since the last command, up to a terminating slot of -1.
pub const ComponentTag = extern struct {
    /// The stack slot the value is in.
    slot: Pointer(u32),
    component: u8,
    _unknown_05: [3]u8,

    /// Tags the list holds, not counting the terminator.
    pub const max = 8;

    comptime {
        assert(@sizeOf(ComponentTag) == 8);
    }
};

/// An event waiting in the queue at `event_queue` (`0x0052ABD8`) for `events_flush`
/// (`0x0045B840`), which raises it on the ship and, for `groups`, on its flight group and the
/// squads that hold it.
pub const QueuedEvent = extern struct {
    groups: bool,
    _unknown_01: [3]u8,
    ship: Pointer(dte.Ship),
    condition: dte.Condition,
    value_count: u8,
    _unknown_0a: u16,
    /// Room for `max_values`; an event carries at most `max_event_values`.
    values: [max_values]u32,
    /// The component of the ship the event concerns, or `dte.Trigger.whole_object`.
    qualifier: u8,
    _unknown_2d: [3]u8,

    /// The values a waiting event has room for.
    pub const max_values = 8;

    comptime {
        assert(max_values >= max_event_values);
        assert(@offsetOf(QueuedEvent, "ship") == 0x04);
        assert(@offsetOf(QueuedEvent, "values") == 0x0C);
        assert(@offsetOf(QueuedEvent, "qualifier") == 0x2C);
        assert(@sizeOf(QueuedEvent) == 0x30);
    }
};

/// The last events of the conditions that have a `slot`, kept for each object at `event_values`
/// (`0x00538CA0`).
pub const ObjectEvents = extern struct {
    shot_at: [max_event_values]u32,
    destroyed: [max_event_values]u32,

    /// The kept events' values one after another, slot after slot, as `push_event_value` numbers
    /// them.
    pub fn flat(events: *ObjectEvents) *[slots * max_event_values]u32 {
        return @ptrCast(events);
    }

    /// The events kept, one for each `ConditionDescriptor.slot`.
    pub const slots = 2;

    comptime {
        assert(@sizeOf(ObjectEvents) == 0x28);
        assert(@sizeOf(ObjectEvents) == slots * max_event_values * @sizeOf(u32));
        // Every condition that keeps its events keeps them in one of the slots.
        for (conditions.table) |condition| {
            if (condition.slot) |slot| assert(slot < slots);
        }
    }
};

test ObjectEvents {
    var events = std.mem.zeroes(ObjectEvents);
    events.flat()[ObjectEvents.slots * max_event_values - 1] = 9;
    events.flat()[max_event_values] = 7;
    try std.testing.expectEqual(7, events.destroyed[0]);
    try std.testing.expectEqual(9, events.destroyed[max_event_values - 1]);
    try std.testing.expectEqual([_]u32{0} ** max_event_values, events.shot_at);
}

test {
    std.testing.refAllDecls(@This());
}
