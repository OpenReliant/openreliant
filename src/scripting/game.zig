//! Global scripts ([#498](https://github.com/OpenReliant/openreliant/issues/498)): the scripts that
//! decide what happens in the game, while a game runs. A game runs from the moment the front end
//! starts a campaign, loads a saved game or flies a mission on its own (or `--mission` starts one),
//! until the front end's main menu comes back, or OpenReliant quits.
//!
//! - A mod's `Global` scripts start as the game starts, in load order, and each mod's in the order
//!   its manifest lists them. They run for the whole game.
//! - Its `[Missions]` scripts start as their mission begins, before the mission's ships are made,
//!   and stop once it ends; each attempt at a mission starts them afresh. A key of `[Missions]` is
//!   a mission's file name, such as `mission40.dte`, in any case.
//! - The engine calls each script's handlers (`on_init`, `on_update`, `on_step`,
//!   `on_mission_start`, `on_mission_end`, `on_object_added` and `on_object_removed`) in the same
//!   order, and runs the handlers they add to hooks (`hooks.zig`).
//! - `math.random` starts again at each mission's start, from the game's random numbers, so it
//!   gives the same numbers on every machine for the same game.
//!
//! An engine handler that raises an error is logged and isn't called again. If no mod has global or
//! mission scripts, no Luau state is created.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.scripts);

const openreliant = @import("openreliant");
const mods = openreliant.engine.game.bigfile.mods;
const Mod = mods.Mod;
const create = openreliant.engine.game.create;
const engine_hooks = openreliant.engine.hooks;
const luau = @import("luau.zig");
const State = luau.State;
const script = @import("script.zig");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const Context = runtime.Context;
const records = @import("records.zig");
const core = @import("core.zig");
const hooks = @import("hooks.zig");
const objects = @import("objects.zig");
const values = @import("values.zig");
const load = @import("load.zig");

/// Limits for global scripts: 100 milliseconds per call, since they run as the game plays, and
/// 64 MiB per mod.
pub const limits: runtime.Limits = .{ .time = .fromMilliseconds(100), .memory = 64 << 20 };

/// The game side of mods' scripts while a game runs.
pub const Game = struct {
    gpa: Allocator,
    runtime: *Runtime,
    /// The handlers the scripts add to hooks.
    hooks: hooks.Hooks,
    /// What the engine calls (`create.Objects.scripts`).
    scripts: engine_hooks.Scripts,
    /// The objects of the game, which handles stand for.
    objects: *create.Objects,
    /// The scripts running, in the order their handlers run.
    running: std.ArrayList(Running) = .empty,
    /// The mods opened for the mission's scripts, which close as it ends.
    mission_mods: std.ArrayList(*Context) = .empty,

    /// Starts a game's scripts for `all`, the game's objects: the `Global` scripts of `opened`,
    /// which can read `held`, the records. `version` is OpenReliant's version. Returns null if no
    /// mod has global or mission scripts.
    pub fn start(gpa: Allocator, io: Io, opened: []const Mod, held: *records.Records, version: []const u8, all: *create.Objects) Allocator.Error!?*Game {
        const any = for (opened) |*mod| {
            var listed = globalScripts(mod);
            if (listed.next() != null) break true;
            var keys = mod.manifest.keys(script.missions_section);
            if (keys.next() != null) break true;
        } else false;
        if (!any) return null;

        const game = try gpa.create(Game);
        const scripts = Runtime.create(gpa, io, opened, .{ .side = .game, .limits = limits, .seed = load.seed }) catch |err| {
            gpa.destroy(game);
            return err;
        };
        game.* = .{ .gpa = gpa, .runtime = scripts, .hooks = undefined, .scripts = .{ .context = game, .vtable = &vtable }, .objects = all };
        game.hooks = .init(gpa, scripts, &game.scripts);
        errdefer game.stop();
        const state = scripts.state;
        records.register(state);
        records.push(state, held, false);
        scripts.setPackage(.records);
        core.push(state, version);
        scripts.setPackage(.core);
        hooks.Hooks.register(state);
        game.hooks.push(state);
        scripts.setPackage(.hooks);
        objects.register(scripts);
        scripts.objects = all;
        all.scripts = &game.scripts;

        for (opened, 0..) |*mod, at| {
            var listed = globalScripts(mod);
            if (listed.next() == null) continue;
            listed = globalScripts(mod);
            const context = try scripts.open(@intCast(at), .global);
            while (listed.next()) |name| try game.startScript(context, name, false);
        }
        return game;
    }

    /// Stops the game's scripts, as the game ends.
    pub fn stop(game: *Game) void {
        game.objects.scripts = null;
        game.stopMissionScripts();
        for (game.running.items) |*running| game.releaseHandlers(running);
        game.running.deinit(game.gpa);
        game.mission_mods.deinit(game.gpa);
        game.hooks.deinit();
        game.runtime.destroy();
        game.gpa.destroy(game);
    }

    /// Runs the script `name` of the mod opened as `context`, keeps its engine handlers, and calls
    /// its `on_init`. A script that fails is logged and left out.
    fn startScript(game: *Game, context: *Context, name: []const u8, mission: bool) Allocator.Error!void {
        const mod = context.modOf();
        const returned = game.runtime.run(context, name) orelse return;
        defer game.runtime.release(returned);
        const handlers = context.handlersOf(name, returned) orelse return;
        try game.running.append(game.gpa, .{ .context = context, .name = name, .handlers = handlers, .mission = mission });
        for (later_handlers) |handler| {
            if (handlers.get(handler) != null) log.warn("{s}: {s}: this version of OpenReliant doesn't call {t} yet", .{ mod.name, name, handler });
        }
        if (handlers.get(.on_object_added) != null) game.hooks.want(.object_added);
        if (handlers.get(.on_object_removed) != null) game.hooks.want(.object_removed);
        log.info("{s}: started {s}", .{ mod.name, name });
        game.callEach(.on_init, .{}, game.running.items.len - 1);
    }

    /// The engine handlers a global script may give that this version doesn't call yet.
    const later_handlers = [_]script.Handler{ .on_save, .on_load, .on_interface_override };

    /// Calls the engine handler `handler` of each running script, from the one at `first` on, with
    /// `arguments` (`Runtime.call`).
    fn callEach(game: *Game, comptime handler: script.Handler, arguments: anytype, first: usize) void {
        var at = first;
        while (at < game.running.items.len) : (at += 1) {
            const running = &game.running.items[at];
            const function = running.handlers.get(handler) orelse continue;
            if (game.runtime.call(running.context, function, arguments) != .failed) continue;
            log.warn("{s}: {s}: {t} failed, and isn't called again", .{ running.context.modOf().name, running.name, handler });
            game.runtime.release(function);
            running.handlers.set(handler, null);
        }
    }

    /// Calls `handler` of each running script with a read-only table of `value`'s fields.
    fn callEachWithTable(game: *Game, comptime handler: script.Handler, comptime T: type, value: T) void {
        const table = game.runtime.make(tableOf(T), .{value}) orelse return;
        defer game.runtime.release(table);
        game.callEach(handler, .{table}, 0);
    }

    fn releaseHandlers(game: *Game, running: *Running) void {
        for (std.enums.values(script.Handler)) |handler| {
            if (running.handlers.get(handler)) |function| game.runtime.release(function);
        }
    }

    /// Stops the scripts of the mission, and closes the mods opened for them.
    fn stopMissionScripts(game: *Game) void {
        var kept: usize = 0;
        for (game.running.items) |*running| {
            if (running.mission) {
                game.releaseHandlers(running);
                continue;
            }
            game.running.items[kept] = running.*;
            kept += 1;
        }
        game.running.shrinkRetainingCapacity(kept);
        for (game.mission_mods.items) |context| {
            game.hooks.removeContext(context);
            game.runtime.close(context);
        }
        game.mission_mods.clearRetainingCapacity();
    }

    fn of(context: *anyopaque) *Game {
        return @ptrCast(@alignCast(context));
    }

    const vtable: engine_hooks.Scripts.VTable = .{
        .call = call,
        .begin = begin,
        .started = started,
        .ended = ended,
        .update = update,
        .step = step,
    };

    fn call(context: *anyopaque, hook_call: *engine_hooks.Call) void {
        const game = of(context);
        switch (hook_call.hook) {
            .object_added => game.objectHandlers(.on_object_added, hook_call),
            .object_removed => game.objectHandlers(.on_object_removed, hook_call),
            else => {},
        }
        game.hooks.run(hook_call);
    }

    /// Calls `handler`, `on_object_added` or `on_object_removed`, of each running script with the
    /// object's handle.
    fn objectHandlers(game: *Game, comptime handler: script.Handler, hook_call: *engine_hooks.Call) void {
        const fields: *const engine_hooks.Fields(.object_added) = @ptrCast(@alignCast(hook_call.fields));
        const handle = game.runtime.make(objects.push, .{fields.object.slot()}) orelse return;
        defer game.runtime.release(handle);
        game.callEach(handler, .{handle}, 0);
    }

    fn begin(context: *anyopaque, mission: engine_hooks.Mission, seed: u64) void {
        const game = of(context);
        game.stopMissionScripts();
        game.runtime.reseed(seed);
        for (game.runtime.mods, 0..) |*mod, at| {
            var listed = missionScripts(mod, mission.file) orelse continue;
            game.startMissionScripts(@intCast(at), &listed) catch |err| log.warn("{s}: the scripts of {s} can't start: {s}", .{ mod.name, mission.file, @errorName(err) });
        }
    }

    fn startMissionScripts(game: *Game, mod: u16, listed: *script.List) Allocator.Error!void {
        try game.mission_mods.ensureUnusedCapacity(game.gpa, 1);
        const context = try game.runtime.open(mod, .global);
        game.mission_mods.appendAssumeCapacity(context);
        while (listed.next()) |name| try game.startScript(context, name, true);
    }

    fn started(context: *anyopaque, mission: engine_hooks.Mission) void {
        const game = of(context);
        game.callEachWithTable(.on_mission_start, engine_hooks.Mission, mission);
        game.hooks.tell(.mission_started, mission);
    }

    fn ended(context: *anyopaque, outcome: engine_hooks.Outcome) void {
        const game = of(context);
        game.callEachWithTable(.on_mission_end, engine_hooks.Outcome, outcome);
        game.hooks.tell(.mission_ended, outcome);
        game.stopMissionScripts();
    }

    fn update(context: *anyopaque, seconds: f32) void {
        of(context).callEach(.on_update, .{seconds}, 0);
    }

    fn step(context: *anyopaque) void {
        of(context).callEach(.on_step, .{}, 0);
    }
};

/// A script that runs.
const Running = struct {
    context: *Context,
    /// Its file's name, as its manifest lists it.
    name: []const u8,
    handlers: runtime.Handlers,
    /// Whether it's a mission's, which stops as its mission ends.
    mission: bool,
};

/// The `Global` scripts `mod` lists, in order.
fn globalScripts(mod: *const Mod) script.List {
    return .of(mod.manifest.value(script.section, script.Kind.global.key()) orelse "");
}

/// The scripts `mod` lists under `[Missions]` for the mission file `file`, if any.
fn missionScripts(mod: *const Mod, file: []const u8) ?script.List {
    var keys = mod.manifest.keys(script.missions_section);
    while (keys.next()) |key| {
        if (!std.ascii.eqlIgnoreCase(key, file)) continue;
        return .of(mod.manifest.value(script.missions_section, key) orelse "");
    }
    return null;
}

/// What pushes a read-only table of a `T`'s fields (`Runtime.make`).
fn tableOf(comptime T: type) fn (*State, T) void {
    return struct {
        fn push(state: *State, value: T) void {
            values.pushTable(state, T, value);
        }
    }.push;
}

/// A game with the mods `made`, each a folder of files, over a mission that holds the player's
/// Predator and a Sabre.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    mods: mods.Mods,
    arena: std.heap.ArenaAllocator,
    held: records.Records,
    mission: openreliant.engine.game.gameobj.testing.Mission,
    game: *Game,
    sabre: u16,

    const collision = openreliant.engine.game.collision;

    fn init(fixture: *Fixture, made: []const struct { []const u8, []const struct { []const u8, []const u8 } }) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        fixture.tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer fixture.tmp.cleanup();
        try load.testing.makeMods(io, fixture.tmp.dir, made);
        fixture.mods = try .open(gpa, io, fixture.tmp.dir, null);
        errdefer fixture.mods.close(gpa);
        fixture.arena = .init(gpa);
        errdefer fixture.arena.deinit();
        fixture.held = try load.testing.records3(fixture.arena.allocator());
        try fixture.mission.init(gpa);
        errdefer fixture.mission.deinit();
        _ = try fixture.mission.add(.predator, @splat(0));
        fixture.sabre = try fixture.mission.add(.sabre, .{ 0, 0, 1000 });
        fixture.game = (try Game.start(gpa, io, fixture.mods.list, &fixture.held, "0.7.0", fixture.mission.objects)).?;
    }

    fn deinit(fixture: *Fixture) void {
        fixture.game.stop();
        fixture.mission.deinit();
        fixture.arena.deinit();
        fixture.mods.close(std.testing.allocator);
        fixture.tmp.cleanup();
    }

    /// What the game's difficulty makes of `value`, dealt to the object in slot `index` by a
    /// missile, through the hooks.
    fn scaled(fixture: *Fixture, index: u16, value: f32) f32 {
        return collision.byDifficulty(fixture.mission.world(), index, .missile, value);
    }
};

test "handlers run newest mod first, in the order each mod added them" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ "a", &.{
            .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" },
            .{ "a.luau", "require('openreliant.hooks').add('damage_by_difficulty', function(e) e.value = e.value * 10 + 1 end)" },
        } },
        .{
            "b",
            &.{
                .{ "mod.ini", "[Scripts]\nGlobal=b.luau\n" },
                .{
                    "b.luau",
                    \\local hooks = require("openreliant.hooks")
                    \\hooks.add("damage_by_difficulty", function(e) e.value = e.value * 10 + 2 end)
                    \\hooks.add("damage_by_difficulty", function(e) e.value = e.value * 10 + 3 end)
                    \\hooks.after("damage_by_difficulty", function(e) e.result += 1000 end, { type = "sabre" })
                    \\-- A hit by the player on a Sabre does nothing.
                    \\hooks.add("object_damage", function(e)
                    \\    if e.attacker.is_player and e.object.type == "sabre" then return false end
                    \\end)
                },
            },
        },
    });
    defer fixture.deinit();
    // Mod b's two, in order, then mod a's; the handler after the function is only for the Sabre.
    try std.testing.expectEqual(1231, fixture.scaled(fixture.sabre, 0));
    // The player's ship takes half at medium difficulty.
    try std.testing.expectEqual(115.5, fixture.scaled(0, 0));

    const shields = &fixture.mission.objects.slots[fixture.sabre].object.shields;
    shields.* = .all(100);
    Fixture.collision.damage(fixture.mission.world(), fixture.sabre, .fore, 50, 1, 0, .bullet);
    try std.testing.expectEqual(100, shields.get(.fore));
}

test "a handler can stop a call, or run the rest of it itself" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" },
                .{
                    "a.luau",
                    \\local hooks = require("openreliant.hooks")
                    \\hooks.add("object_destroyed", function(e) return false end, { class = { "fighter" }, side = "hostile" })
                    \\hooks.add("damage_by_difficulty", function(e)
                    \\    local scaled = e:original()
                    \\    e.result = scaled + 1
                    \\    assert(not pcall(function() e:original() end))
                    \\end)
                    \\hooks.add("damage_by_difficulty", function(e) e.value = 7 end)
                },
            },
        },
    });
    defer fixture.deinit();
    // The second handler runs inside the first's call of the rest, and the function once.
    try std.testing.expectEqual(8, fixture.scaled(fixture.sabre, 3));
    // The Sabre's end is stopped.
    openreliant.engine.game.ai.objectDestroyed(fixture.mission.orders(), fixture.sabre, false, false);
    try std.testing.expectEqual(0, fixture.mission.objects.slots[fixture.sabre].object.order_count);
}

test "a handler that fails is removed, and its changes undone" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" },
                .{
                    "a.luau",
                    \\local hooks = require("openreliant.hooks")
                    \\hooks.add("damage_by_difficulty", function(e) e.value = 100; error("broken") end)
                    \\-- e can't be used once its call is over.
                    \\local kept = nil
                    \\hooks.add("damage_by_difficulty", function(e)
                    \\    if kept then assert(not pcall(function() return kept.value end)) end
                    \\    kept = e
                    \\    e.value += 1
                    \\end)
                    \\hooks.add("object_removed", function(e) e.object = e.object end)
                },
            },
        },
    });
    defer fixture.deinit();
    try std.testing.expectEqual(4, fixture.scaled(fixture.sabre, 3));
    try std.testing.expectEqual(4, fixture.scaled(fixture.sabre, 3));
    // An event's fields can't be changed, so its handler fails, and nothing hooks it any more.
    const hooked = &fixture.game.scripts.hooked;
    try std.testing.expect(hooked.contains(.object_removed));
    fixture.mission.objects.resetSlot(fixture.sabre, &fixture.mission.random);
    try std.testing.expect(!hooked.contains(.object_removed));
}

test "the engine calls the scripts' handlers, and a mission's scripts run with it" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nGlobal=game.luau\n[Missions]\nMISSION5.dte=mission.luau\n" },
                .{
                    "game.luau",
                    \\local factor = 1
                    \\require("openreliant.hooks").add("damage_by_difficulty", function(e) e.value *= factor end)
                    \\return { engine_handlers = {
                    \\    on_mission_start = function(mission) assert(mission.file == "mission5.dte"); factor = mission.number end,
                    \\    on_update = function(seconds) factor += seconds end,
                    \\    on_mission_end = function(outcome) if outcome.ending == "destroyed" then factor = 100 end end,
                    \\} }
                },
                .{ "mission.luau", "require('openreliant.hooks').add('damage_by_difficulty', function(e) e.value += 1 end)" },
            },
        },
    });
    defer fixture.deinit();
    const scripts = &fixture.game.scripts;
    const mission: engine_hooks.Mission = .{ .number = 5, .file = "mission5.dte" };
    scripts.begin(mission, 1);
    scripts.started(mission);
    try std.testing.expectEqual(11, fixture.scaled(fixture.sabre, 2));
    scripts.update(0.5);
    try std.testing.expectEqual(12, fixture.scaled(fixture.sabre, 2));
    // As the mission ends, its script stops.
    scripts.ended(.{ .ending = .destroyed, .rating = .failure });
    try std.testing.expectEqual(200, fixture.scaled(fixture.sabre, 2));
}
