//! The script VM's side of the editor link (docs/engine/editor-link.md): what the VM's globals keep
//! for the editor, and how `vm_run` (`0x0045C980`) stops and steps a thread for it. The editor's
//! messages set the hold and the step (`editor_run_control`, `0x0045A900`, ported as the game's
//! handler of tag `0x15`). The VM talks to the editor through `Editor.connection`: it tells the
//! editor where a thread stopped and what the script did, and reads the editor's messages while the
//! script starts. Nothing here belongs to one game: the game's link fills in `Editor.present` and
//! `Editor.connection` from its own connection.

const std = @import("std");

/// `vm_hold` (`0x005373F8`): the editor's hold on the script.
pub const Hold = enum(i8) {
    /// The editor let the script go on: the next instruction run takes it as `none` again, and
    /// acts on the step (`vm_run`, `0x0045C9FF`).
    released = -1,
    none = 0,
    /// Stopped before a flagged byte or at a step's end: the threads, the timers, the watches and
    /// the script's clock wait, and `mission_frame` leaves out its work.
    held = 1,
};

/// `vm_step_mode` (`0x00537582`): what the editor's last release asked for.
pub const Step = enum(i8) {
    none = -1,
    /// Run on past the byte it stopped before, to the next flagged byte.
    run_on = 1,
    /// Stop before the next instruction that starts a statement (`opcodes.Info.starts_statement`).
    into = 2,
    /// Stop before the next statement of the same block, or of the block a return goes back to.
    over = 3,
};

/// OpenReliant's: what the script did, which the editor's timeline shows (`Editor.report`).
pub const Event = union(enum) {
    /// A trigger fired, by its index in the trigger list.
    trigger: u32,
    /// A command of the catalogue ran, by its number.
    command: u8,
};

/// How the VM reaches the editor, through the game's link.
pub const Connection = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Tells the editor that a thread stopped before the byte `offset` bytes into the script,
        /// which the original sends as tag `0x1A`.
        stopped: *const fn (context: *anyopaque, offset: u32) void,
        /// `editor_link_check` (`0x00457670`): acts on the editor's messages waiting. They can
        /// release the script, pause the mission, or let the script go as the editor leaves.
        check: *const fn (context: *anyopaque) void,
        /// Waits `milliseconds` for the editor (`Sleep`).
        sleep: *const fn (context: *anyopaque, milliseconds: u32) void,
        /// The time in milliseconds on a clock that only goes forward, for how long the script's
        /// start has waited for the editor (`Editor.waitForFlags`).
        now: *const fn (context: *anyopaque) u64,
        /// OpenReliant's: tells the editor what the script did (`Editor.report`).
        happened: *const fn (context: *anyopaque, event: Event) void,
    };
};

/// The longest the script's start waits for the editor's flags before it runs the start parts,
/// while an editor is linked (`Editor.waitForFlags`).
pub const flags_wait_ms = 1000;

/// How often the script's start checks the link while it waits for the editor's flags.
pub const flags_check_ms = 1;

/// How long the script's start waits after each start part, and each time round while the editor
/// holds it (`0x0045CCDB`).
pub const part_wait_ms = 1;

/// What the VM keeps for the editor link.
pub const Editor = struct {
    /// Whether an editor is linked (`editor_absent`, `0x004F634C`, inverted). With none, `vm_run`
    /// neither stops at the flagged bytes nor steps.
    present: bool = false,
    hold: Hold = .none,
    step: Step = .none,
    /// `vm_step_returned` (`0x00537414`): set as a part returns to its caller (`vm_return`), which
    /// ends a step over at the next statement.
    step_returned: bool = false,
    /// `editor_paused` (`0x00537581`): the editor's pause of the mission. `mission_frame` leaves
    /// out its work, and the timer runs none of its routines.
    paused: bool = false,
    /// OpenReliant's: whether the editor has sent the script's flags since the script started,
    /// which the start waits for (`waitForFlags`). A game's link sets it as it copies them.
    flagged: bool = false,
    /// The game's link to the editor; null for none.
    connection: ?Connection = null,

    /// Whether the script is held, which the threads, the timers, the watches and the clock wait
    /// for (`vm_hold` above 0).
    pub fn holds(editor: Editor) bool {
        return editor.hold == .held;
    }

    /// Whether `mission_frame` leaves out its work (`0x0049288E`): while the editor pauses the
    /// mission, or holds the script with the editor there.
    pub fn leavesFrame(editor: Editor) bool {
        return editor.paused or (editor.holds() and editor.present);
    }

    /// `mission_script_start`'s part (`0x0045CC22`, `0x0045CC7B`, `0x0045CC81`): the mission's
    /// pause lifted, and the hold and the step cleared, with the editor's flags still to come.
    /// Whether the editor is there, and the connection, are the link's, and stay.
    pub fn reset(editor: *Editor) void {
        editor.paused = false;
        editor.hold = .none;
        editor.step = .none;
        editor.flagged = false;
    }

    /// `editor_run_control` (`0x0045A900`) for its commands 1 to 3: the script released, to go on
    /// as `step` has it. A run on releases it only where the editor holds or has released it.
    pub fn release(editor: *Editor, step: Step) void {
        if (step == .run_on and editor.hold == .none) return;
        editor.hold = .released;
        editor.step = step;
    }

    /// Holds the script before `offset` and tells the editor (`vm_run`, `0x0045CA88`).
    pub fn stop(editor: *Editor, offset: u32) void {
        editor.hold = .held;
        if (editor.connection) |connection| connection.vtable.stopped(connection.context, offset);
    }

    /// OpenReliant's: tells the editor what the script did, while one is there.
    pub fn report(editor: *Editor, event: Event) void {
        if (!editor.present) return;
        if (editor.connection) |connection| connection.vtable.happened(connection.context, event);
    }

    /// Acts on the editor's messages waiting (`editor_link_check`).
    pub fn check(editor: *Editor) void {
        if (editor.connection) |connection| connection.vtable.check(connection.context);
    }

    /// Waits `milliseconds` for the editor, while one is there.
    ///
    /// **Improvement:** the original waits whether an editor is there or not.
    pub fn sleep(editor: *Editor, milliseconds: u32) void {
        if (!editor.present) return;
        if (editor.connection) |connection| connection.vtable.sleep(connection.context, milliseconds);
    }

    /// The script's start before the start parts run (`mission_script_start`, `0x0045CC95`): the
    /// editor's messages are read, and while an editor is there and hasn't sent the script's flags,
    /// read again every `flags_check_ms`, for `flags_wait_ms` at most, so that a breakpoint in a
    /// start part stops it.
    ///
    /// **Improvement:** the original reads the messages, waits a fifth of a second whether an
    /// editor is there or not (`0x0045CCA0`), and reads them again, and the breakpoints of a
    /// slower editor miss the start parts.
    pub fn waitForFlags(editor: *Editor) void {
        editor.check();
        const connection = editor.connection orelse return;
        const started = connection.vtable.now(connection.context);
        while (editor.present and !editor.flagged and connection.vtable.now(connection.context) -% started < flags_wait_ms) {
            editor.sleep(flags_check_ms);
            editor.check();
        }
    }

    /// OpenReliant's: as the editor goes, the script is let go, with no step.
    ///
    /// **Improvement:** the original keeps a script the editor held as it was, so the mission's
    /// script waits for good once the editor is gone.
    pub fn letGo(editor: *Editor) void {
        editor.present = false;
        editor.paused = false;
        editor.hold = .none;
        editor.step = .none;
    }
};

pub const testing = struct {
    /// An editor in memory, for the tests: the offsets it heard of the stops, and the flags and
    /// the releases it gives as the script's start checks its messages.
    pub const Listener = struct {
        offsets: [8]u32 = undefined,
        count: usize = 0,
        /// The steps the editor releases the script with, one for each check that finds the script
        /// held, in order.
        releases: []const Step = &.{},
        /// How many releases it gave.
        released: usize = 0,
        /// The check that brings the editor's flags, counting from 0; null for none.
        flags_at: ?usize = 0,
        /// How many times its messages were checked.
        checked: usize = 0,
        /// How long it waited, in milliseconds, which is its clock.
        slept: u32 = 0,
        /// The editor that `check` flags and releases.
        editor: ?*Editor = null,
        /// What it heard the script do, in order.
        events: [8]Event = undefined,
        event_count: usize = 0,

        pub fn connection(listener: *Listener) Connection {
            return .{ .context = listener, .vtable = &.{ .stopped = stopped, .check = check, .sleep = sleep, .now = now, .happened = happened } };
        }

        /// What it heard the script do.
        pub fn heard(listener: *const Listener) []const Event {
            return listener.events[0..listener.event_count];
        }

        pub fn last(listener: Listener) u32 {
            return listener.offsets[listener.count - 1];
        }

        fn stopped(context: *anyopaque, offset: u32) void {
            const listener: *Listener = @ptrCast(@alignCast(context));
            listener.offsets[listener.count] = offset;
            listener.count += 1;
        }

        fn check(context: *anyopaque) void {
            const listener: *Listener = @ptrCast(@alignCast(context));
            defer listener.checked += 1;
            const editor = listener.editor orelse return;
            if (listener.flags_at == listener.checked) editor.flagged = true;
            if (!editor.holds() or listener.released >= listener.releases.len) return;
            editor.release(listener.releases[listener.released]);
            listener.released += 1;
        }

        fn sleep(context: *anyopaque, milliseconds: u32) void {
            const listener: *Listener = @ptrCast(@alignCast(context));
            listener.slept += milliseconds;
        }

        fn now(context: *anyopaque) u64 {
            const listener: *Listener = @ptrCast(@alignCast(context));
            return listener.slept;
        }

        fn happened(context: *anyopaque, event: Event) void {
            const listener: *Listener = @ptrCast(@alignCast(context));
            if (listener.event_count == listener.events.len) return;
            listener.events[listener.event_count] = event;
            listener.event_count += 1;
        }
    };
};

test Editor {
    var listener: testing.Listener = .{};
    var editor: Editor = .{ .present = true, .connection = listener.connection() };
    try std.testing.expect(!editor.leavesFrame());
    // A run on with nothing held does nothing; a step does.
    editor.release(.run_on);
    try std.testing.expectEqual(Hold.none, editor.hold);
    editor.release(.into);
    try std.testing.expectEqual(Hold.released, editor.hold);
    try std.testing.expectEqual(Step.into, editor.step);
    // A stop holds the script, tells the editor, and leaves out the frame's work while the editor
    // is there.
    editor.stop(10);
    try std.testing.expectEqual(10, listener.last());
    try std.testing.expect(editor.holds() and editor.leavesFrame());
    editor.sleep(5);
    try std.testing.expectEqual(5, listener.slept);
    // The editor hears what the script does while it's there.
    editor.report(.{ .trigger = 2 });
    try std.testing.expectEqualSlices(Event, &.{.{ .trigger = 2 }}, listener.heard());
    editor.present = false;
    editor.report(.{ .command = 11 });
    try std.testing.expectEqual(1, listener.heard().len);
    try std.testing.expect(!editor.leavesFrame());
    // With no editor there, nothing waits for one.
    editor.sleep(5);
    try std.testing.expectEqual(5, listener.slept);
    editor.paused = true;
    try std.testing.expect(editor.leavesFrame());
    editor.reset();
    try std.testing.expect(!editor.leavesFrame() and editor.step == .none);
}

test "the script's start waits for the editor's flags" {
    const Case = struct {
        present: bool,
        flags_at: ?usize,
        slept: u32,
    };
    for ([_]Case{
        // Flags waiting at the first check need no wait, and those at the third take two.
        .{ .present = true, .flags_at = 0, .slept = 0 },
        .{ .present = true, .flags_at = 2, .slept = 2 * flags_check_ms },
        // An editor that sends none holds the start up for the longest wait.
        .{ .present = true, .flags_at = null, .slept = flags_wait_ms },
        // With no editor, the start doesn't wait.
        .{ .present = false, .flags_at = null, .slept = 0 },
    }) |case| {
        var listener: testing.Listener = .{ .flags_at = case.flags_at };
        var editor: Editor = .{ .present = case.present, .connection = listener.connection() };
        listener.editor = &editor;
        editor.waitForFlags();
        try std.testing.expectEqual(case.slept, listener.slept);
        try std.testing.expectEqual(case.flags_at != null, editor.flagged);
    }
    // Each start waits for flags of its own.
    var editor: Editor = .{ .flagged = true };
    editor.reset();
    try std.testing.expect(!editor.flagged);
}
