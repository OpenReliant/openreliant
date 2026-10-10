//! The mods' global and player scripts as `openreliant` runs them while a game runs, which the
//! main loop and the rooms' loops share.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const scripting = @import("scripting");
const version = @import("version");
const engine = openreliant.engine;
const game = engine.game;
const save = game.gameflow.save;

/// The mods' global and player scripts, which run while a game runs (`scripting.Game`,
/// `scripting.Presentation.startGame`), and their state, which is kept with each saved game and
/// with the restart point (`scripting.snapshot`).
pub const GameScripts = struct {
    gpa: Allocator,
    io: Io,
    mods: []const game.bigfile.mods.Mod,
    records: *scripting.Records,
    objects: *game.create.Objects,
    /// The player and menu scripts, if any mod has some.
    presentation: ?*scripting.Presentation,
    /// The mods' storage and the game's files, which every script reaches.
    shared: scripting.runtime.Shared,
    running: ?*scripting.Game = null,
    /// Whether a game runs: from `start` to `stop`.
    started: bool = false,
    /// The scripts' state kept with the game just loaded, which they start from (`loaded`).
    saved: ?[]u8 = null,
    /// The scripts' state as the last flight of the campaign began, which goes back with the
    /// game's restart point (`Saving.restartPoint`).
    restart_point: ?[]u8 = null,

    pub fn deinit(scripts: *GameScripts) void {
        scripts.stop();
        if (scripts.saved) |bytes| scripts.gpa.free(bytes);
        if (scripts.restart_point) |bytes| scripts.gpa.free(bytes);
    }

    /// Starts them as a game starts, after any of the game before: from the state kept with the
    /// game just loaded, if there is one.
    pub fn start(scripts: *GameScripts) Allocator.Error!void {
        const saved = scripts.saved;
        scripts.saved = null;
        defer if (saved) |bytes| scripts.gpa.free(bytes);
        try scripts.startFrom(saved);
    }

    /// Starts them, from the state `kept` if there is one, and otherwise with the storage's game
    /// sections empty, as a new game starts.
    fn startFrom(scripts: *GameScripts, kept: ?[]const u8) Allocator.Error!void {
        scripts.stop();
        if (scripts.shared.storage) |storage| storage.clearGame();
        const loading = kept != null;
        scripts.running = try scripting.Game.start(scripts.gpa, scripts.io, scripts.mods, scripts.records, version.string, scripts.objects, scripts.shared, loading);
        scripts.started = true;
        if (scripts.presentation) |shown| try shown.startGame(scripts.running, scripts.objects, loading);
        if (kept) |bytes| try scripting.snapshot.restore(scripts.gpa, bytes, scripts.running, scripts.presentation, scripts.shared.storage);
    }

    /// Stops them as the game ends, if they run.
    pub fn stop(scripts: *GameScripts) void {
        if (scripts.presentation) |shown| shown.endGame();
        if (scripts.running) |running| running.stop();
        scripts.running = null;
        scripts.started = false;
    }

    /// Reads the folder mods' scripts again and starts the scripts again from where they were, as
    /// the console asks: the game's and the player scripts from their state as a save would keep
    /// it, partway through `mission` where one runs, and the menu scripts afresh.
    pub fn reload(scripts: *GameScripts, mission: ?Resume) Allocator.Error!void {
        std.log.scoped(.scripts).info("reloading the scripts", .{});
        const kept = if (scripts.started) try scripting.snapshot.take(scripts.gpa, scripts.running, scripts.presentation, scripts.shared.storage) else null;
        defer if (kept) |bytes| scripts.gpa.free(bytes);
        if (scripts.presentation) |shown| try shown.reload();
        if (!scripts.started) return;
        try scripts.startFrom(kept);
        const going = mission orelse return;
        if (scripts.running) |running| running.resumeMission(going.orders, going.mission, going.seed);
    }

    /// The scripts a line typed in the console reaches.
    pub fn reachable(scripts: *const GameScripts) scripting.console.Scripts {
        return .{ .game = scripts.running, .presentation = scripts.presentation };
    }

    /// A mission that runs, as the scripts start again partway through it.
    pub const Resume = struct {
        orders: game.aigeneric.Context,
        mission: engine.hooks.Mission,
        seed: u64,
    };

    /// Keeps their state as the campaign's restart point is taken.
    pub fn keepRestartPoint(scripts: *GameScripts) Allocator.Error!void {
        if (scripts.restart_point) |bytes| scripts.gpa.free(bytes);
        scripts.restart_point = null;
        if (!scripts.started) return;
        scripts.restart_point = try scripting.snapshot.take(scripts.gpa, scripts.running, scripts.presentation, scripts.shared.storage);
    }

    /// Starts them again from their state at the restart point, as the game goes back to it.
    pub fn backToRestartPoint(scripts: *GameScripts) Allocator.Error!void {
        if (scripts.restart_point) |point| try scripts.startFrom(point);
    }

    /// What the saved games' folder tells them as a game is saved, loaded and removed.
    pub fn extra(scripts: *GameScripts) save.Extra {
        return .{ .context = scripts, .vtable = &.{ .storing = storing, .stored = stored, .loaded = loaded, .removed = removed } };
    }

    /// Whether there are scripts whose state a saved game keeps.
    fn any(scripts: *const GameScripts) bool {
        return scripts.running != null or scripts.presentation != null;
    }

    /// As a game is saved, its scripts' state is written beside it, before the save itself. A
    /// state that can't be written fails the save, which would otherwise go with the slot's older
    /// state. With no scripts, there's nothing to keep.
    fn storing(context: *anyopaque, folder: save.Folder, call_sign: []const u8, slot: u8) save.Folder.StoreError!void {
        const scripts: *GameScripts = @ptrCast(@alignCast(context));
        if (!scripts.any()) return;
        const bytes = try scripting.snapshot.take(scripts.gpa, scripts.running, scripts.presentation, scripts.shared.storage);
        defer scripts.gpa.free(bytes);
        try folder.putCompanion(call_sign, slot, scripting.snapshot.extension, bytes);
    }

    /// Once a game without scripts is saved, the state an earlier save left in the slot goes.
    fn stored(context: *anyopaque, folder: save.Folder, call_sign: []const u8, slot: u8) void {
        const scripts: *GameScripts = @ptrCast(@alignCast(context));
        if (!scripts.any()) folder.removeCompanion(call_sign, slot, scripting.snapshot.extension);
    }

    /// As a game is loaded, its scripts' state is read, and they start from it: at once where a
    /// game runs, as in the Reliant's rooms, and as the game starts from the front end
    /// otherwise. A game saved without it starts them as a new game does.
    fn loaded(context: *anyopaque, folder: save.Folder, call_sign: []const u8, slot: u8) void {
        const scripts: *GameScripts = @ptrCast(@alignCast(context));
        if (scripts.saved) |bytes| scripts.gpa.free(bytes);
        scripts.saved = folder.companion(scripts.gpa, call_sign, slot, scripting.snapshot.extension, scripting.snapshot.max_size);
        if (scripts.started) scripts.start() catch |err|
            std.log.warn("the scripts can't start for the game loaded: {s}", .{@errorName(err)});
    }

    fn removed(_: *anyopaque, folder: save.Folder, call_sign: []const u8, slot: u8) void {
        folder.removeCompanion(call_sign, slot, scripting.snapshot.extension);
    }
};
