//! The script VM's side of the editor link (docs/engine/editor-link.md): what the VM's globals keep
//! for the editor, and how `vm_run` (`0x0045C980`) stops and steps a thread for it. The editor's
//! messages set the hold and the step (`editor_run_control`, `0x0045A900`, ported as the game's
//! handler of tag `0x15`), and the VM reaches the editor through `Editor.connection`, which tells
//! it where a thread stopped and reads its messages while the script starts. None of it is a
//! game's: a game's link fills `Editor.present` and `Editor.connection` from its own connection.

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
    };
};

/// How long the script's start waits for the editor's messages before it runs the start parts
/// (`mission_script_start`, `0x0045CCA0`).
pub const start_wait_ms = 200;

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
    /// pause lifted, and the hold and the step cleared. Whether the editor is there, and the
    /// connection, are the link's, and stay.
    pub fn reset(editor: *Editor) void {
        editor.paused = false;
        editor.hold = .none;
        editor.step = .none;
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

    /// Acts on the editor's messages waiting (`editor_link_check`).
    pub fn check(editor: *Editor) void {
        if (editor.connection) |connection| connection.vtable.check(connection.context);
    }

    /// Waits `milliseconds` for the editor, while one is there.
    ///
    /// **Improvement:** the original waits whether an editor is there or not, a fifth of a second
    /// as each mission's script starts.
    pub fn sleep(editor: *Editor, milliseconds: u32) void {
        if (!editor.present) return;
        if (editor.connection) |connection| connection.vtable.sleep(connection.context, milliseconds);
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
    /// An editor in memory, for the tests: the offsets it heard of the stops, and the releases it
    /// gives as the script's start checks its messages.
    pub const Listener = struct {
        offsets: [8]u32 = undefined,
        count: usize = 0,
        /// The steps the editor releases the script with, one for each check, in order.
        releases: []const Step = &.{},
        checks: usize = 0,
        slept: u32 = 0,
        /// The editor that `check` releases.
        editor: ?*Editor = null,

        pub fn connection(listener: *Listener) Connection {
            return .{ .context = listener, .vtable = &.{ .stopped = stopped, .check = check, .sleep = sleep } };
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
            const editor = listener.editor orelse return;
            if (!editor.holds() or listener.checks >= listener.releases.len) return;
            editor.release(listener.releases[listener.checks]);
            listener.checks += 1;
        }

        fn sleep(context: *anyopaque, milliseconds: u32) void {
            const listener: *Listener = @ptrCast(@alignCast(context));
            listener.slept += milliseconds;
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
    editor.present = false;
    try std.testing.expect(!editor.leavesFrame());
    // With no editor there, nothing waits for one.
    editor.sleep(5);
    try std.testing.expectEqual(5, listener.slept);
    editor.paused = true;
    try std.testing.expect(editor.leavesFrame());
    editor.reset();
    try std.testing.expect(!editor.leavesFrame() and editor.step == .none);
}
