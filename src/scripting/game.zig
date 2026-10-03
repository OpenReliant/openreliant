//! The game side of mods' scripts ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! the scripts that decide what happens in the game, while a game runs. A game runs from the moment
//! the front end starts a campaign, loads a saved game or flies a mission on its own (or
//! `--mission` starts one), until the front end's main menu comes back, or OpenReliant quits.
//!
//! - A mod's `Global` scripts start as the game starts, in load order, and each mod's in the order
//!   its manifest lists them. They run for the whole game.
//! - Its `[Missions]` scripts start as their mission begins, before the mission's ships are made,
//!   and stop once it ends; each attempt at a mission starts them afresh. A key of `[Missions]` is
//!   a mission's file name, such as `mission40.dte`, in any case.
//! - Its object scripts start on each object of a class (`Fighter=`) or a type
//!   (`Type.predator=`) as the object is added to the mission, and on one object when a global
//!   script adds them (`object:add_script`). They stop as their object leaves the mission, or as
//!   the mission ends. Each object a mod's scripts run on has the mod opened for it on its own, so
//!   its scripts have their own globals.
//! - The engine calls the scripts' handlers in the order the scripts started: the global and
//!   mission scripts', then each object's, by slot. Events sent between scripts wait for the next
//!   update (`events.zig`).
//! - `math.random` starts again at each mission's start, from the game's random numbers, so it
//!   gives the same numbers on every machine for the same game.
//!
//! An engine handler that raises an error is logged and isn't called again. If no mod has global,
//! mission or object scripts, no Luau state is created.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.scripts);

const openreliant = @import("openreliant");
const mods = openreliant.engine.game.bigfile.mods;
const Mod = mods.Mod;
const create = openreliant.engine.game.create;
const gameobj = openreliant.engine.game.gameobj;
const aigeneric = openreliant.engine.game.aigeneric;
const winmain = openreliant.engine.game.winmain;
const engine_hooks = openreliant.engine.hooks;
const Object = engine_hooks.Object;
const script = @import("script.zig");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const Context = runtime.Context;
const records = @import("records.zig");
const packages = @import("packages.zig");
const hooks = @import("hooks.zig");
const objects = @import("objects.zig");
const values = @import("values.zig");
const load = @import("load.zig");
const data = @import("data.zig");
const api = @import("api.zig");
const Call = api.Call;
const running = @import("running.zig");
const interfaces = @import("interfaces.zig");
const world = @import("world.zig");

/// Limits for game scripts: 100 milliseconds per call, since they run as the game plays, and
/// 64 MiB per mod.
pub const limits: runtime.Limits = .{ .time = .fromMilliseconds(100), .memory = 64 << 20 };

/// The game side of mods' scripts while a game runs.
pub const Game = struct {
    gpa: Allocator,
    runtime: *Runtime,
    /// The scripts that run, with their events and interfaces.
    runner: running.Runner,
    /// The global and mission scripts that run, then each object's, by slot (`global`,
    /// `onObject`).
    lists: [1 + gameobj.max_objects]running.List = @splat(.empty),
    /// The handlers the scripts add to hooks.
    hooks: hooks.Hooks,
    /// What the engine calls (`create.Objects.scripts`).
    scripts: engine_hooks.Scripts,
    /// The objects of the game, which handles stand for.
    objects: *create.Objects,
    /// The mods opened for the mission's scripts, which close as it ends.
    mission_mods: std.ArrayList(*Context) = .empty,
    /// The mission that runs, if any.
    mission: ?MissionHeld = null,

    /// The mission that runs, kept from its start.
    const MissionHeld = struct {
        number: u16,
        file: [winmain.mission_path_size]u8,
        file_len: u8,

        fn of(mission: engine_hooks.Mission) MissionHeld {
            var held: MissionHeld = .{ .number = mission.number, .file = undefined, .file_len = @intCast(mission.file.len) };
            @memcpy(held.file[0..mission.file.len], mission.file);
            return held;
        }

        pub fn view(held: *const MissionHeld) engine_hooks.Mission {
            return .{ .number = held.number, .file = held.file[0..held.file_len] };
        }
    };

    /// Starts a game's scripts for `all`, the game's objects: the `Global` scripts of `opened`,
    /// which can read `held`, the records. `version` is OpenReliant's version. Returns null if no
    /// mod has global, mission or object scripts.
    /// Where `loading`, the scripts start for a saved game, whose state `snapshot.restore` puts
    /// back, so they don't get `on_init` yet.
    pub fn start(gpa: Allocator, io: Io, opened: []const Mod, held: *records.Records, version: []const u8, all: *create.Objects, shared: runtime.Shared, loading: bool) Allocator.Error!?*Game {
        const any = for (opened) |*mod| {
            var listed = globalScripts(mod);
            if (listed.next() != null) break true;
            var keys = mod.manifest.keys(script.missions_section);
            if (keys.next() != null) break true;
            if (attachesScripts(mod)) break true;
        } else false;
        if (!any) return null;

        const game = try gpa.create(Game);
        const scripts = Runtime.create(gpa, io, opened, .{ .side = .game, .limits = limits, .seed = load.seed, .version = version, .shared = shared }) catch |err| {
            gpa.destroy(game);
            return err;
        };
        game.* = .{
            .gpa = gpa,
            .runtime = scripts,
            .runner = undefined,
            .hooks = undefined,
            .scripts = .{ .context = game, .vtable = &vtable },
            .objects = all,
        };
        game.runner = .init(gpa, scripts, &game.lists);
        game.hooks = .init(gpa, scripts, &game.scripts);
        game.runner.hooks = &game.hooks;
        errdefer game.stop();
        const state = scripts.state;
        records.register(state);
        records.push(state, held, false);
        scripts.setPackage(.records);
        packages.push(scripts);
        hooks.Hooks.register(state);
        game.hooks.push(state);
        scripts.setPackage(.hooks);
        objects.register(scripts);
        interfaces.Interfaces.register(state);
        game.runner.interfaces.push(state);
        scripts.setPackage(.interfaces);
        scripts.objects = all;
        scripts.game = game;
        scripts.runner = &game.runner;
        all.scripts = &game.scripts;
        // An object's scripts stop as it leaves the mission, so the engine tells the scripts of
        // every object that leaves, and of every object added where manifests attach scripts.
        game.hooks.want(.object_removed);
        for (opened) |*mod| if (attachesScripts(mod)) game.hooks.want(.object_added);

        for (opened, 0..) |*mod, at| {
            var listed = globalScripts(mod);
            if (listed.next() == null) continue;
            listed = globalScripts(mod);
            const context = try scripts.open(@intCast(at), .global, null);
            while (listed.next()) |name| _ = try game.startScript(game.global(), context, name, false, null, loading);
        }
        return game;
    }

    /// Stops the game's scripts, as the game ends.
    pub fn stop(game: *Game) void {
        game.runtime.custom_orders.endMission(game.runtime);
        game.objects.scripts = null;
        game.stopMissionScripts();
        game.runner.deinit();
        game.mission_mods.deinit(game.gpa);
        game.hooks.deinit();
        game.runtime.destroy();
        game.gpa.destroy(game);
    }

    /// The game whose scripts make `call`. Raises an error where no game runs.
    pub fn of(call: Call, comptime label: []const u8) *Game {
        return call.runtime().game orelse call.raise("{s} can only be used while a game runs", .{label});
    }

    /// The global and mission scripts that run.
    pub fn global(game: *Game) *running.List {
        return &game.lists[0];
    }

    /// The scripts that run on the object in slot `index`.
    pub fn onObject(game: *Game, index: u16) *running.List {
        return &game.lists[1 + @as(usize, index)];
    }

    /// `Runner.start`, which also has the engine tell the scripts of each object added where the
    /// script handles that.
    fn startScript(game: *Game, list: *running.List, context: *Context, name: []const u8, mission: bool, payload: ?data.Data, loading: bool) Allocator.Error!?usize {
        const at = try game.runner.start(list, context, name, mission, payload, loading) orelse return null;
        if (list.items[at].offered.handlers.get(.on_object_added) != null) game.hooks.want(.object_added);
        return at;
    }

    /// Stops the scripts of the mission, and closes the mods opened for them.
    fn stopMissionScripts(game: *Game) void {
        game.runner.walking += 1;
        defer game.runner.leave();
        const list = game.global();
        for (list.items, 0..) |held, at| {
            if (held.mission) game.runner.stopScript(list, at);
        }
        for (game.mission_mods.items) |context| {
            if (!context.closed) game.runner.closeContext(context);
        }
        game.mission_mods.clearRetainingCapacity();
    }

    /// Stops every object's scripts, as a mission ends.
    fn stopObjectScripts(game: *Game) void {
        for (game.lists[1..]) |*list| game.runner.stopAll(list);
    }

    /// Starts the scripts that mods' manifests attach to the object in slot `index`, as it's added
    /// to the mission.
    fn objectAdded(game: *Game, index: u16) void {
        const slot = &game.objects.slots[index];
        const class = if (slot.combat) |combat| combat.class else null;
        for (game.runtime.mods, 0..) |*mod, at| {
            var keys = mod.manifest.keys(script.section);
            var context: ?*Context = null;
            while (keys.next()) |key| {
                const attachment = script.Attachment.parse(key) orelse continue;
                const matches = switch (attachment) {
                    .kind => |kind| kind.runs() and kind.class() != null and kind.class() == class,
                    .object_type => |object_type| object_type == slot.object.type,
                };
                if (!matches) continue;
                var listed: script.List = .of(mod.manifest.value(script.section, key) orelse "");
                while (listed.next()) |name| {
                    const opened = context orelse game.runtime.open(@intCast(at), .object, .of(game.objects, index)) catch |err| {
                        log.warn("{s}: the scripts of object {d} can't start: {s}", .{ mod.name, index, @errorName(err) });
                        return;
                    };
                    context = opened;
                    _ = game.startScript(game.onObject(index), opened, name, false, null, false) catch |err| {
                        log.warn("{s}: {s} can't start on object {d}: {s}", .{ mod.name, name, index, @errorName(err) });
                    };
                }
            }
        }
    }

    /// Calls the `on_removed` of the scripts of the object in slot `index`, and stops them, as it
    /// leaves the mission.
    fn objectRemoved(game: *Game, index: u16) void {
        game.runner.callEach(game.onObject(index), .on_removed, .{});
        game.runner.stopAll(game.onObject(index));
    }

    /// Delivers the events sent since the last update (`events.zig`).
    fn deliver(game: *Game) void {
        var pending = game.runner.events.take();
        defer pending.deinit(game.gpa);
        for (pending.items) |*sent| {
            defer game.runtime.release(sent.data.ref);
            const list = switch (sent.to) {
                .global => game.global(),
                .object => |handle| if (handle.valid(game.objects)) game.onObject(handle.slot) else continue,
            };
            game.runner.deliverTo(list, sent);
        }
    }

    fn ofScripts(context: *anyopaque) *Game {
        return @ptrCast(@alignCast(context));
    }

    const vtable: engine_hooks.Scripts.VTable = .{
        .call = hookCall,
        .begin = begin,
        .started = started,
        .ended = ended,
        .update = update,
        .step = step,
        .order_info = orderInfo,
        .order_run = orderRun,
    };

    fn orderInfo(context: *anyopaque, order: openreliant.engine.game.ai.orders.Order) ?openreliant.engine.game.ai.orders.Info {
        return ofScripts(context).runtime.custom_orders.info(order);
    }

    fn orderRun(context: *anyopaque, ctx: aigeneric.Context, index: u16, order: openreliant.engine.game.ai.orders.Order, role: openreliant.engine.game.ai.routines.Role) bool {
        const game = ofScripts(context);
        return game.runtime.custom_orders.run(game.runtime, ctx, index, order, role);
    }

    fn hookCall(context: *anyopaque, hook_call: *engine_hooks.Call) void {
        const game = ofScripts(context);
        switch (hook_call.hook) {
            .object_added => {
                const index = objectOf(hook_call);
                game.objectAdded(index);
                game.runner.callEach(game.global(), .on_object_added, .{ .object = .of(index) });
            },
            .object_removed => {
                const index = objectOf(hook_call);
                if (game.runtime.orders) |ctx| aigeneric.forgetCustom(ctx, index);
                game.runner.callEach(game.global(), .on_object_removed, .{ .object = .of(index) });
                game.objectRemoved(index);
            },
            else => {},
        }
        game.hooks.run(hook_call);
    }

    /// The object of an `object_added` or `object_removed` call.
    fn objectOf(hook_call: *engine_hooks.Call) u16 {
        const fields: *const engine_hooks.Fields(.object_added) = @ptrCast(@alignCast(hook_call.fields));
        return fields.object.slot();
    }

    fn begin(context: *anyopaque, orders: aigeneric.Context, mission: engine_hooks.Mission, seed: u64) void {
        const game = ofScripts(context);
        game.stopObjectScripts();
        game.stopMissionScripts();
        game.runtime.reseed(seed);
        game.runtime.orders = orders;
        game.mission = .of(mission);
        for (game.runtime.mods, 0..) |*mod, at| {
            var listed = missionScripts(mod, mission.file) orelse continue;
            game.startMissionScripts(@intCast(at), &listed) catch |err| log.warn("{s}: the scripts of {s} can't start: {s}", .{ mod.name, mission.file, @errorName(err) });
        }
    }

    /// Starts the scripts of a mission that runs already, as the scripts are reloaded partway
    /// through it: the mission's scripts, and the scripts manifests attach to each object in it,
    /// as its start would have them (`begin`), but without `on_mission_start` or
    /// `on_object_added`.
    pub fn resumeMission(game: *Game, orders: aigeneric.Context, mission: engine_hooks.Mission, seed: u64) void {
        begin(game, orders, mission, seed);
        for (0..game.objects.slots.len) |index| {
            if (world.inMission(game.objects, @intCast(index))) game.objectAdded(@intCast(index));
        }
    }

    fn startMissionScripts(game: *Game, mod: u16, listed: *script.List) Allocator.Error!void {
        try game.mission_mods.ensureUnusedCapacity(game.gpa, 1);
        const context = try game.runtime.open(mod, .global, null);
        game.mission_mods.appendAssumeCapacity(context);
        while (listed.next()) |name| _ = try game.startScript(game.global(), context, name, true, null, false);
    }

    fn started(context: *anyopaque, mission: engine_hooks.Mission) void {
        const game = ofScripts(context);
        game.runner.callEach(game.global(), .on_mission_start, .{ .mission = mission });
        game.hooks.tell(.mission_started, mission);
    }

    fn ended(context: *anyopaque, outcome: engine_hooks.Outcome) void {
        const game = ofScripts(context);
        game.runner.callEach(game.global(), .on_mission_end, .{ .outcome = outcome });
        game.hooks.tell(.mission_ended, outcome);
        game.runtime.custom_orders.endMission(game.runtime);
        game.stopObjectScripts();
        game.stopMissionScripts();
        game.runtime.orders = null;
        game.mission = null;
    }

    fn update(context: *anyopaque, seconds: f32) void {
        const game = ofScripts(context);
        game.deliver();
        game.runner.advance(seconds);
        game.runner.callAll(.on_update, .{ .seconds = seconds });
    }

    fn step(context: *anyopaque) void {
        ofScripts(context).runner.callAll(.on_step, .{});
    }
};

/// The `Global` scripts `mod` lists, in order.
fn globalScripts(mod: *const Mod) script.List {
    return .of(mod.manifest.value(script.section, script.Kind.global.key()) orelse "");
}

/// Whether `mod`'s manifest attaches scripts to objects by their class or type.
fn attachesScripts(mod: *const Mod) bool {
    var keys = mod.manifest.keys(script.section);
    while (keys.next()) |key| {
        const attachment = script.Attachment.parse(key) orelse continue;
        switch (attachment) {
            .kind => |kind| if (kind.runs() and kind.family() == .object) return true,
            .object_type => return true,
        }
    }
    return false;
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

/// `object:add_script(name, data)`.
pub fn addScript(call: Call, object: Object, name: []const u8, payload: ?data.Data) bool {
    // Luau's errors skip Zig's defers, so the payload is let go by hand before each.
    const drop = struct {
        fn drop(scripts: *Runtime, given: ?data.Data) void {
            if (given) |held| scripts.release(held.ref);
        }
    }.drop;
    const scripts = call.runtime();
    if (call.context.family != .global) {
        drop(scripts, payload);
        call.raise("add_script: only global scripts can add scripts", .{});
    }
    const game = scripts.game orelse {
        drop(scripts, payload);
        call.raise("add_script can only be used while a game runs", .{});
    };
    const mod = call.context.modOf();
    const file = scriptNamed(mod, name) orelse {
        drop(scripts, payload);
        call.raise("add_script: mod {s} has no script {s}", .{ mod.name, name });
    };
    const index = object.slot();
    const list = game.onObject(index);
    for (list.items) |held| {
        if (held.stopped or held.context.mod != call.context.mod) continue;
        if (std.ascii.eqlIgnoreCase(held.name, file)) {
            drop(scripts, payload);
            return false;
        }
    }
    const context = for (list.items) |held| {
        if (!held.stopped and held.context.mod == call.context.mod) break held.context;
    } else scripts.open(call.context.mod, .object, .of(game.objects, index)) catch {
        drop(scripts, payload);
        call.raise("add_script: out of memory", .{});
    };
    const started = game.startScript(list, context, file, false, payload, false) catch call.raise("add_script: out of memory", .{});
    return started != null;
}

/// `object:remove_script(name)`.
pub fn removeScript(call: Call, object: Object, name: []const u8) bool {
    const game = Game.of(call, "remove_script");
    if (call.context.family != .global) call.raise("remove_script: only global scripts can remove scripts", .{});
    const list = game.onObject(object.slot());
    for (list.items, 0..) |held, at| {
        if (held.stopped or held.context.mod != call.context.mod) continue;
        if (!sameScript(held.name, name)) continue;
        game.runner.stopScript(list, at);
        return true;
    }
    return false;
}

/// `object:send_event(name, data)`.
pub fn sendEvent(call: Call, object: Object, name: []const u8, payload: data.Data) void {
    const game = call.runtime().game orelse {
        call.runtime().release(payload.ref);
        call.raise("send_event: events can only be sent while a game runs", .{});
    };
    game.runner.events.send(call, .{ .object = .of(game.objects, object.slot()) }, name, payload);
}

/// `core.send_global_event(name, data)`.
pub fn sendGlobalEvent(call: Call, name: []const u8, payload: data.Data) void {
    if (call.runtime().presentation) |shown| return shown.sendToGame(call, name, payload);
    const game = call.runtime().game orelse {
        call.runtime().release(payload.ref);
        call.raise("send_global_event: events can only be sent while a game runs", .{});
    };
    game.runner.events.send(call, .global, name, payload);
}

/// The file name of `mod`'s script `name`, given with or without its extension and in any case, as
/// the mod has it.
fn scriptNamed(mod: *const Mod, name: []const u8) ?[]const u8 {
    var names = mod.scripts();
    while (names.next()) |file| {
        if (sameScript(file, name)) return file;
    }
    return null;
}

/// Whether the script file `file` is the one `name` names, with or without its extension and in
/// any case (`require`).
fn sameScript(file: []const u8, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(file, name)) return true;
    const stem = file[0 .. file.len - std.fs.path.extension(file).len];
    return std.ascii.eqlIgnoreCase(stem, name);
}

/// A game with the mods `made`, each a folder of files, over a mission that holds the player's
/// Predator and a Sabre.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    mods: mods.Mods,
    arena: std.heap.ArenaAllocator,
    held: records.Records,
    mission: gameobj.testing.Mission,
    game: *Game,
    sabre: u16,

    const collision = openreliant.engine.game.collision;

    fn init(fixture: *Fixture, made: []const struct { []const u8, []const struct { []const u8, []const u8 } }) !void {
        return fixture.initShared(made, .{});
    }

    /// `init`, with what the mods share; where it has a registry of options, the load scripts run
    /// first, to declare the pages the others read.
    fn initShared(fixture: *Fixture, made: []const struct { []const u8, []const struct { []const u8, []const u8 } }, shared: runtime.Shared) !void {
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
        if (shared.settings != null) try load.run(gpa, io, fixture.mods.list, &fixture.held, "0.7.0", shared);
        fixture.game = (try Game.start(gpa, io, fixture.mods.list, &fixture.held, "0.7.0", fixture.mission.objects, shared, false)).?;
        fixture.sabre = try fixture.mission.add(.sabre, .{ 0, 0, 1000 });
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

    /// Begins mission 5, as the engine does before its ships are made.
    fn begin(fixture: *Fixture) void {
        fixture.game.scripts.begin(fixture.mission.orders(), .{ .number = 5, .file = "mission5.dte" }, 1);
    }
};

test "custom orders use qualified names, lifecycle callbacks and the engine stack" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" },
                .{
                    "a.luau",
                    \\local orders = require("openreliant.orders")
                    \\local world = require("openreliant.world")
                    \\local started, updated, exited = 0, 0, 0
                    \\local own
                    \\own = orders.register("hold", {
                    \\    priority = 2, flags = {avoidance = true},
                    \\    init = function(ship, target) started += 1; assert(target == world.objects()[1]) end,
                    \\    update = function(ship, target, seconds)
                    \\        updated += 1; ship.throttle = 0.25
                    \\        assert(ship.order == "a:hold" and orders.stack(ship)[1].order == own)
                    \\        return updated < 2
                    \\    end,
                    \\    exit = function(ship) exited += 1; ship.throttle = 0.5 end,
                    \\})
                    \\assert(own == "a:hold")
                    \\assert(not pcall(function() orders.register("hold", {update = function() end}) end))
                    \\return { engine_handlers = {on_mission_start = function()
                    \\    local ships = world.objects(); local ship = ships[2]
                    \\    assert(orders.info(own).priority == 2 and orders.info(own).flags.avoidance)
                    \\    assert(orders.info("b:hold") ~= nil)
                    \\    assert(not ships[1]:give_order(own))
                    \\    assert(ship:give_order("do_nothing") and ship:give_order(own, ships[1]))
                    \\end, on_update = function()
                    \\    assert(started == 1 and updated == 2 and exited == 1)
                    \\end} }
                },
            },
        },
        .{ "b", &.{ .{ "mod.ini", "[Scripts]\nGlobal=b.luau\n" }, .{ "b.luau", "assert(require('openreliant.orders').register('hold', {update = function() end}) == 'b:hold')" } } },
    });
    defer fixture.deinit();
    fixture.begin();
    fixture.game.scripts.started(.{ .number = 5, .file = "mission5.dte" });
    const ctx = fixture.mission.orders();
    aigeneric.objectOrders(ctx, fixture.sabre);
    try std.testing.expectEqual(0.25, fixture.mission.slot(fixture.sabre).object.throttle);
    try std.testing.expectError(error.OrderConflict, aigeneric.push(ctx, fixture.sabre, .fly_aimlessly, .none));
    aigeneric.objectOrders(ctx, fixture.sabre);
    try std.testing.expectEqual(0.5, fixture.mission.slot(fixture.sabre).object.throttle);
    try std.testing.expect(fixture.game.runtime.custom_orders.entries.items[1].enabled);
    try std.testing.expectEqual(.do_nothing, fixture.mission.slot(fixture.sabre).current().?.order);
    fixture.game.scripts.update(0.04);
    try std.testing.expect(fixture.game.runtime.custom_orders.entries.items[0].enabled);
}

test "custom order failures disable callbacks and context closure removes stacked orders" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" },
            .{
                "a.luau",
                \\local orders = require("openreliant.orders")
                \\local world = require("openreliant.world")
                \\orders.register("broken", {update = function(ship) ship:give_order("do_nothing") end})
                \\orders.register("hold", {priority = 3, update = function() end, exit = function(ship) ship.throttle = 0.75 end})
                \\return {engine_handlers = {on_mission_start = function()
                \\    local ship = world.objects()[2]
                \\    assert(ship:give_order("do_nothing") and ship:give_order("a:broken"))
                \\end}}
            },
        },
    }});
    defer fixture.deinit();
    fixture.begin();
    fixture.game.scripts.started(.{ .number = 5, .file = "mission5.dte" });
    const ctx = fixture.mission.orders();
    aigeneric.objectOrders(ctx, fixture.sabre);
    try std.testing.expect(!fixture.game.runtime.custom_orders.entries.items[0].enabled);
    try std.testing.expectEqual(.do_nothing, fixture.mission.slot(fixture.sabre).current().?.order);
    const hold = fixture.game.runtime.custom_orders.find("a:hold").?;
    try std.testing.expect(aigeneric.give(ctx, fixture.sabre, hold, .none));
    aigeneric.objectOrders(ctx, fixture.sabre);
    fixture.game.runtime.close(fixture.game.runtime.custom_orders.entries.items[1].context);
    try std.testing.expectEqual(0.75, fixture.mission.slot(fixture.sabre).object.throttle);
    try std.testing.expectEqual(.do_nothing, fixture.mission.slot(fixture.sabre).current().?.order);
    try std.testing.expectEqual(null, fixture.game.runtime.custom_orders.find("a:hold"));
}

test "one-shot custom orders skip init and exit and mission end removes custom stacks" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" },
            .{
                "a.luau",
                \\local orders = require("openreliant.orders")
                \\local world = require("openreliant.world")
                \\orders.register("hold", {update = function() end, exit = function(ship) ship.throttle = 0.75 end})
                \\orders.register("once", {flags = {one_shot = true, players = true},
                \\    init = function() error("must not init") end,
                \\    update = function(ship) ship.throttle = 0.5 end,
                \\    exit = function() error("must not exit") end})
                \\return {engine_handlers = {on_mission_start = function()
                \\    local ship = world.objects()[2]
                \\    assert(ship:give_order("do_nothing") and ship:give_order("a:hold") and ship:give_order("a:once"))
                \\end}}
            },
        },
    }});
    defer fixture.deinit();
    fixture.begin();
    fixture.game.scripts.started(.{ .number = 5, .file = "mission5.dte" });
    aigeneric.objectOrders(fixture.mission.orders(), fixture.sabre);
    const hold = fixture.game.runtime.custom_orders.find("a:hold").?;
    try std.testing.expectEqual(hold, fixture.mission.slot(fixture.sabre).current().?.order);
    try std.testing.expectEqual(0.5, fixture.mission.slot(fixture.sabre).object.throttle);
    fixture.game.scripts.ended(.{ .ending = .playing, .rating = .success });
    try std.testing.expectEqual(0.75, fixture.mission.slot(fixture.sabre).object.throttle);
    try std.testing.expectEqual(.do_nothing, fixture.mission.slot(fixture.sabre).current().?.order);
    // Global registrations remain available in the next mission, with the same qualified names.
    try std.testing.expectEqual(hold, fixture.game.runtime.custom_orders.find("a:hold").?);
}

test "mission order registrations close and register again without stale numeric IDs" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "a", &.{
        .{ "mod.ini", "[Missions]\nmission5.dte=a.luau\n" },
        .{ "a.luau", "require('openreliant.orders').register('hold', {update = function() end})" },
    } }});
    defer fixture.deinit();
    fixture.begin();
    const old = fixture.game.runtime.custom_orders.find("a:hold").?;
    try std.testing.expect(aigeneric.give(fixture.mission.orders(), fixture.sabre, old, .none));
    aigeneric.objectOrders(fixture.mission.orders(), fixture.sabre);
    // Starting the context again models the shutdown/restart path used on reload.
    fixture.begin();
    const new = fixture.game.runtime.custom_orders.find("a:hold").?;
    try std.testing.expect(old != new);
    try std.testing.expectEqual(0, fixture.mission.slot(fixture.sabre).object.order_count);
    try std.testing.expect(aigeneric.give(fixture.mission.orders(), fixture.sabre, new, .none));
}

test "the custom order example runs and completes its throttle pulse" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "custom-order", &.{
        .{ "mod.ini", @embedFile("custom-order/mod.ini") },
        .{ "pulse.luau", @embedFile("custom-order/pulse.luau") },
    } }});
    defer fixture.deinit();
    fixture.begin();
    fixture.game.scripts.started(.{ .number = 5, .file = "mission5.dte" });
    const pulse = fixture.game.runtime.custom_orders.find("custom-order:pulse").?;
    try std.testing.expectEqual(pulse, fixture.mission.slot(fixture.sabre).current().?.order);
    fixture.mission.clock.frame_duration = 100;
    aigeneric.objectOrders(fixture.mission.orders(), fixture.sabre);
    try std.testing.expectEqual(0.25, fixture.mission.slot(fixture.sabre).object.throttle);
    aigeneric.objectOrders(fixture.mission.orders(), fixture.sabre);
    try std.testing.expectEqual(0, fixture.mission.slot(fixture.sabre).object.order_count);
    try std.testing.expectEqual(0, fixture.mission.slot(fixture.sabre).object.throttle);
}

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

test "mods can intercept warp orders and receive filtered Undocked events" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nGlobal=a.luau\n" },
            .{
                "a.luau",
                \\local hooks = require("openreliant.hooks")
                \\local seen = false
                \\hooks.add("undocked", function(e)
                \\    assert(e.object.type == "sabre")
                \\    seen = true
                \\end, { type = "sabre" })
                \\hooks.add("order_warp_out", function(e)
                \\    assert(seen)
                \\    e.object.throttle = 0.75
                \\    return false
                \\end, { type = "sabre" })
            },
        },
    }});
    defer fixture.deinit();
    const game = openreliant.engine.game;
    const ctx = fixture.mission.orders();
    try std.testing.expect(try game.aigeneric.pushShip(ctx, fixture.sabre, .warp_out, 0, null));
    openreliant.engine.hooks.tell(fixture.mission.world(), .undocked, .{ .object = .of(0) });
    openreliant.engine.hooks.tell(fixture.mission.world(), .undocked, .{ .object = .of(fixture.sabre) });
    game.aigeneric.objectOrders(ctx, fixture.sabre);
    try std.testing.expectEqual(0.75, fixture.mission.slot(fixture.sabre).object.throttle);
    try std.testing.expectEqual(0, fixture.mission.slot(fixture.sabre).state.warp.step);
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
    // An event's fields can't be changed, so its handler fails. The engine still tells the scripts
    // of objects that leave, whose own scripts stop with them.
    const hooked = &fixture.game.scripts.hooked;
    fixture.mission.objects.resetSlot(fixture.sabre, &fixture.mission.random);
    try std.testing.expect(fixture.game.hooks.handlers.get(.object_removed).items.len == 0);
    try std.testing.expect(hooked.contains(.object_removed));
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
    fixture.begin();
    scripts.started(mission);
    try std.testing.expectEqual(11, fixture.scaled(fixture.sabre, 2));
    scripts.update(0.5);
    try std.testing.expectEqual(12, fixture.scaled(fixture.sabre, 2));
    // As the mission ends, its script stops.
    scripts.ended(.{ .ending = .destroyed, .rating = .failure });
    try std.testing.expectEqual(200, fixture.scaled(fixture.sabre, 2));
}

test "scripts reloaded partway through a mission start on its objects, without its start" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nFighter=wing.luau\n[Missions]\nMISSION5.dte=mission.luau\n" },
                .{
                    "wing.luau",
                    \\local self = require("openreliant.self")
                    \\self:hook("damage_by_difficulty", function(e) e.value *= 0.5 end)
                },
                .{
                    "mission.luau",
                    \\local factor = 3
                    \\require("openreliant.hooks").add("damage_by_difficulty", function(e) e.value *= factor end)
                    \\return { engine_handlers = { on_mission_start = function() factor = 100 end } }
                },
            },
        },
    });
    defer fixture.deinit();
    // The Sabre is in the mission already: its script starts on it, and the mission's script
    // starts without hearing the mission start.
    fixture.game.resumeMission(fixture.mission.orders(), .{ .number = 5, .file = "mission5.dte" }, 1);
    try std.testing.expectEqual(1, fixture.game.onObject(fixture.sabre).items.len);
    try std.testing.expectEqual(3, fixture.scaled(fixture.sabre, 2));
}

test "object scripts run on the objects their manifest names, each with its own globals" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nFighter=wing.luau\nType.sabre=sabre.luau\n" },
                .{
                    "wing.luau",
                    \\local self = require("openreliant.self")
                    \\count = 0
                    \\local hooks = require("openreliant.hooks")
                    \\-- Each fighter's own hits land at half strength, counted by its own global.
                    \\self:hook("damage_by_difficulty", function(e) count += 1; e.value *= 0.5 end)
                    \\return { engine_handlers = {
                    \\    on_update = function() if count == 2 then self.throttle = 0.25 end end,
                    \\    on_removed = function() print("removed", self.slot) end,
                    \\} }
                },
                .{
                    "sabre.luau",
                    \\local self = require("openreliant.self")
                    \\return { engine_handlers = { on_added = function() self.yaw_input = 1 end } }
                },
            },
        },
    });
    defer fixture.deinit();
    fixture.begin();
    // The Sabre made before the mission began has no scripts; one made now has both.
    const sabre = try fixture.mission.add(.sabre, .{ 0, 0, 2000 });
    const all = fixture.mission.objects;
    try std.testing.expectEqual(2, fixture.game.onObject(sabre).items.len);
    try std.testing.expectEqual(1, all.slots[sabre].object.yaw_input);
    try std.testing.expectEqual(1.5, fixture.scaled(sabre, 3));
    try std.testing.expectEqual(1.5, fixture.scaled(sabre, 3));
    // The first Sabre's hits aren't halved, and don't count for the other.
    try std.testing.expectEqual(3, fixture.scaled(fixture.sabre, 3));
    fixture.game.scripts.update(0.1);
    try std.testing.expectEqual(0.25, all.slots[sabre].object.throttle);
    // As it leaves, its scripts stop with it.
    all.resetSlot(sabre, &fixture.mission.random);
    try std.testing.expectEqual(0, fixture.game.onObject(sabre).items.len);
}

test "global scripts add scripts to objects, send them events, and share interfaces" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nGlobal=game.luau\n" },
                .{
                    "game.luau",
                    \\local world = require("openreliant.world")
                    \\local heard = {}
                    \\return {
                    \\    interface_name = "Wing",
                    \\    interface = { heard = function() return heard end },
                    \\    engine_handlers = {
                    \\        on_mission_start = function()
                    \\            for _, object in world.objects() do
                    \\                if object.type == "sabre" then
                    \\                    assert(object:add_script("escort", { leader = world.player }))
                    \\                    assert(not object:add_script("ESCORT.luau"))
                    \\                    object:send_event("Hello", { from = "game" })
                    \\                end
                    \\            end
                    \\        end,
                    \\    },
                    \\    event_handlers = {
                    \\        Reported = function(data) table.insert(heard, data.leader) end,
                    \\    },
                    \\}
                },
                .{
                    "escort.luau",
                    \\local core = require("openreliant.core")
                    \\local leader
                    \\return {
                    \\    engine_handlers = { on_init = function(data) leader = data.leader end },
                    \\    event_handlers = {
                    \\        Hello = function(data)
                    \\            assert(data.from == "game")
                    \\            core.send_global_event("Reported", { leader = leader })
                    \\        end,
                    \\    },
                    \\}
                },
            },
        },
        .{
            "b",
            &.{
                .{ "mod.ini", "[Scripts]\nGlobal=check.luau\n" },
                .{
                    "check.luau",
                    \\local world = require("openreliant.world")
                    \\local I = require("openreliant.interfaces")
                    \\local base
                    \\return {
                    \\    -- Mod b's Wing takes the place of mod a's, and calls through to it.
                    \\    interface_name = "Wing",
                    \\    interface = { heard = function() return base.heard() end, newer = true },
                    \\    engine_handlers = {
                    \\        on_interface_override = function(earlier) base = earlier end,
                    \\        on_update = function()
                    \\            local heard = I.Wing.heard()
                    \\            if I.Wing.newer and #heard == 1 and heard[1] == world.player then
                    \\                world.player.yaw_input = -1
                    \\            end
                    \\        end,
                    \\    },
                    \\}
                },
            },
        },
    });
    defer fixture.deinit();
    fixture.begin();
    const scripts = &fixture.game.scripts;
    scripts.started(.{ .number = 5, .file = "mission5.dte" });
    try std.testing.expectEqual(1, fixture.game.onObject(fixture.sabre).items.len);
    const player = &fixture.mission.objects.slots[0].object;
    // The first update delivers the greeting before the scripts' on_update, and the second the
    // report it sends back, which mod b then finds through the interface.
    scripts.update(0.1);
    try std.testing.expectEqual(0, player.yaw_input);
    scripts.update(0.1);
    try std.testing.expectEqual(-1, player.yaw_input);
}

test "object scripts read the world around them, and give their object orders" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nGlobal=game.luau\nFighter=wing.luau\n" },
                .{
                    "game.luau",
                    \\local world = require("openreliant.world")
                    \\return { engine_handlers = { on_mission_start = function()
                    \\    assert(world.mission.number == 5 and world.mission.file == "mission5.dte")
                    \\    assert(world.player.is_player and #world.objects() == 4)
                    \\end } }
                },
                .{
                    "wing.luau",
                    \\local self = require("openreliant.self")
                    \\local nearby = require("openreliant.nearby")
                    \\return { engine_handlers = { on_update = function()
                    \\    if self.is_player or self.order == "run_away" then return end
                    \\    local around = nearby.objects(1500)
                    \\    if #around == 0 then return end
                    \\    -- Without itself; the other Sabres are out of reach.
                    \\    assert(#around == 1 and around[1].is_player)
                    \\    assert(not pcall(function() around[1].throttle = 1 end))
                    \\    assert(self:give_order("run_away", around[1]))
                    \\end } }
                },
            },
        },
    });
    defer fixture.deinit();
    fixture.begin();
    const sabre = try fixture.mission.add(.sabre, .{ 0, 0, -1000 });
    _ = try fixture.mission.add(.sabre, .{ 0, 0, 50000 });
    fixture.game.scripts.started(.{ .number = 5, .file = "mission5.dte" });
    fixture.game.scripts.update(0.1);
    try std.testing.expectEqual(openreliant.engine.game.ai.orders.Order.run_away, fixture.mission.objects.slots[sabre].current().?.order);
}

test "the wingmen example: a badly damaged wingman runs from its attacker, and rejoins later" {
    const storage_module = @import("storage.zig");
    const settings = @import("settings.zig");
    const mod_options = openreliant.engine.game.interface.mod_options;
    var storage: storage_module.Storage = .{ .gpa = std.testing.allocator };
    defer storage.deinit();
    var pages: settings.Registry = .init(std.testing.allocator, &storage);
    defer pages.deinit();
    var fixture: Fixture = undefined;
    try fixture.initShared(&.{.{ "wingmen", &.{
        .{ "mod.ini", @embedFile("wingmen/mod.ini") },
        .{ "options.luau", @embedFile("wingmen/options.luau") },
        .{ "wingman.luau", @embedFile("wingmen/wingman.luau") },
        .{ "wingmen.luau", @embedFile("wingmen/wingmen.luau") },
        .{ "status.luau", @embedFile("wingmen/status.luau") },
    } }}, .{ .storage = &storage, .settings = &pages });
    defer fixture.deinit();
    // Its options are the defaults until the player sets them.
    try std.testing.expectEqual(3, pages.page("wingmen").?.options.len);
    try std.testing.expectEqual(mod_options.Value{ .number = 0.3 }, pages.value("wingmen", "pull_out_below").?);
    fixture.begin();
    const wingman = try fixture.mission.add(.wolverine, .{ 0, 0, -1000 });
    const scripts = &fixture.game.scripts;
    scripts.started(.{ .number = 5, .file = "mission5.dte" });
    const slot = &fixture.mission.objects.slots[wingman];
    slot.object.side = .friendly;
    // Untouched, it stays in the fight.
    scripts.update(0.1);
    try std.testing.expect(slot.current() == null or slot.current().?.order != .run_away);
    // With its armour nearly gone, it runs from the Sabre that hit it.
    slot.object.armor = .all(1);
    slot.object.last_attacker = .of(fixture.sabre);
    scripts.update(0.1);
    try std.testing.expectEqual(.run_away, slot.current().?.order);
    try std.testing.expectEqual(fixture.sabre, @as(u16, @intCast(slot.current().?.target.index)));
    // Its report reaches the global script at the next update, and 20 seconds on it rejoins the
    // player's formation.
    scripts.update(0.1);
    scripts.update(20);
    try std.testing.expectEqual(.formation, slot.current().?.order);
    try std.testing.expectEqual(0, slot.current().?.target.index);
}
