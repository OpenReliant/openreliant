//! OpenReliant's: the game frames on a thread of their own, at the game's own pace beside the main
//! thread, which draws (`GameThread.run`). The two share the game's records, so each holds the lock
//! while it uses them: the game thread as it runs the ticks due, and the main thread for each pass
//! until it draws (`GameThread.hold`), which reads only the drawn frame's copies (`main.Drawn`).
//! Where the main thread runs the game frames itself, in step with the drawn frames, as for a
//! screenshot, the game thread waits (`GameThread.free`).
//!
//! **Improvement:** the game runs its ticks as each frame begins, all those due since the frame
//! before. Here they run when they are due, while the frame is drawn, each with the controls and
//! what drawing handed over as the last frame began, which can be a drawn frame older. What a tick
//! does with them is the same.

const std = @import("std");
const Io = std.Io;

const input = @import("../../input.zig");
const gameobj = @import("../gameobj.zig");
const objects = @import("../objects.zig");
const main = @import("../main.zig");
const Loaded = @import("../mission.zig").Loaded;

pub const GameThread = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    /// The platform's clock in nanoseconds, which the game's ticks are counted on, and the length
    /// of a tick in nanoseconds (`main.Clock.advanceToFine`).
    now: *const fn () u64,
    tick: u64,
    /// What the game frames run with (`main.gameFrames`), which the main thread changes only while
    /// it holds the lock.
    clock: *main.Clock,
    devices: *input.Devices,
    reading: *input.Reading,
    world: *const gameobj.World,
    riders: objects.Riders,
    loaded: *const ?*Loaded,
    /// Whether the game frames run here, at their own pace. Otherwise the main thread runs them in
    /// step with the drawn frames, and the game thread waits. The main thread sets it each pass,
    /// while it holds the game (`hold`).
    free: bool = false,
    /// What the game frames did here since the main thread last took it up (`takeDone`).
    done: Done = .{},
    /// Set as the run ends (`stop`).
    stopping: bool = false,

    /// What the game frames did on the game thread.
    pub const Done = struct {
        /// Whether any ran, whose presses then count as taken on the main thread too.
        ran: bool = false,
        /// Whether the mission ended, which holds them until the main thread has taken it up.
        over: bool = false,
    };

    /// Holds the game's records for a pass of the main thread, until `unlock`. Afterwards the game
    /// frames run on only if the pass lets them again (`free`), so a pass that ends early, such as
    /// when a mission ends, leaves them waiting.
    pub fn hold(thread: *GameThread) void {
        thread.lock();
        thread.free = false;
    }

    pub fn unlock(thread: *GameThread) void {
        thread.mutex.unlock(thread.io);
    }

    fn lock(thread: *GameThread) void {
        thread.mutex.lockUncancelable(thread.io);
    }

    /// The game thread, until `stop`: each pass, with the lock held, the game frames of the ticks
    /// due (`pass`), then it sleeps until the next tick is due.
    pub fn run(thread: *GameThread) void {
        while (true) {
            thread.lock();
            if (thread.stopping) return thread.unlock();
            const next = thread.pass();
            thread.unlock();
            thread.io.sleep(.fromNanoseconds(next -| thread.now()), .awake) catch return;
        }
    }

    /// While the game frames run here and the mission plays on: the clock to the platform's time,
    /// then a game frame for each tick that brings (`main.gameFrames`). Returns the platform's time
    /// the next tick is due at.
    fn pass(thread: *GameThread) u64 {
        const now = thread.now();
        const next = (now / thread.tick + 1) * thread.tick;
        if (!thread.free or thread.done.over) return next;
        thread.clock.advanceToFine(now, thread.tick);
        const from = thread.clock.frame_start;
        const ended = main.gameFrames(thread.clock, thread.devices, thread.reading, thread.world.*, thread.riders, thread.loaded.*);
        if (thread.clock.frame_start != from) thread.done.ran = true;
        if (ended == .over) thread.done.over = true;
        return next;
    }

    /// What the game frames did here since the main thread last took it up, which it takes up
    /// while it holds the game.
    pub fn takeDone(thread: *GameThread) Done {
        defer thread.done = .{};
        return thread.done;
    }

    /// Ends the game thread, `running` (`run`), once its pass is done.
    pub fn stop(thread: *GameThread, running: *Io.Future(void)) void {
        thread.lock();
        thread.stopping = true;
        thread.unlock();
        running.await(thread.io);
    }
};

test GameThread {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var missions: [2]gameobj.testing.Mission = undefined;
    for (&missions) |*mission| {
        try mission.init(gpa);
        for (0..2) |_| _ = try mission.add(.of(.predator), @splat(0));
        try std.testing.expect(try @import("../aigeneric.zig").push(mission.orders(), 1, .slow_rotate, .none));
    }
    defer for (&missions) |*mission| mission.deinit();
    var devices: [2]input.Devices = .{ .{}, .{} };
    var reading: input.Reading = .{};
    const loaded: ?*Loaded = null;
    const Fake = struct {
        var time: u64 = 0;
        fn now() u64 {
            return time;
        }
    };
    const worlds = [2]gameobj.World{ missions[0].world(), missions[1].world() };
    var thread: GameThread = .{
        .io = io,
        .now = Fake.now,
        .tick = 10,
        .clock = &missions[0].clock,
        .devices = &devices[0],
        .reading = &reading,
        .world = &worlds[0],
        .riders = .together,
        .loaded = &loaded,
    };

    // While the main thread runs the game frames, the game thread's passes run none.
    Fake.time = 100;
    try std.testing.expectEqual(110, thread.pass());
    try std.testing.expectEqual(0, missions[0].clock.mission_ticks);
    try std.testing.expectEqual(GameThread.Done{}, thread.takeDone());

    // Running here, each pass runs the ticks the platform's time brings, as the main thread runs
    // them in step with the drawn frames, and the mission plays the same way.
    thread.free = true;
    for (0..40) |step| {
        Fake.time = 100 + 10 * (step + 1);
        _ = thread.pass();
        missions[1].clock.advanceToFine(Fake.time, 10);
        try std.testing.expectEqual(.played, main.gameFrames(&missions[1].clock, &devices[1], &reading, worlds[1], .together, null));
    }
    try std.testing.expectEqual(GameThread.Done{ .ran = true }, thread.takeDone());
    try std.testing.expectEqual(missions[1].clock.mission_ticks, missions[0].clock.mission_ticks);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&missions[1].slot(1).object), std.mem.asBytes(&missions[0].slot(1).object));

    // Held by the main thread, the passes run none until it lets them again.
    thread.hold();
    thread.unlock();
    const ran_to = missions[0].clock.mission_ticks;
    Fake.time += 100;
    _ = thread.pass();
    try std.testing.expectEqual(ran_to, missions[0].clock.mission_ticks);
    try std.testing.expectEqual(GameThread.Done{}, thread.takeDone());

    // Stopped, the thread ends at its next pass.
    var running = try io.concurrent(GameThread.run, .{&thread});
    thread.stop(&running);
}
