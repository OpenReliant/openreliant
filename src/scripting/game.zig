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
const luau = @import("luau.zig");
const State = luau.State;
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
const events = @import("events.zig");
const interfaces = @import("interfaces.zig");

/// Limits for game scripts: 100 milliseconds per call, since they run as the game plays, and
/// 64 MiB per mod.
pub const limits: runtime.Limits = .{ .time = .fromMilliseconds(100), .memory = 64 << 20 };

/// A script that runs.
pub const Running = struct {
    context: *Context,
    /// Its file's name, as its mod has it.
    name: []const u8,
    offered: runtime.Offered,
    /// Whether it's a mission's, which stops as its mission ends.
    mission: bool = false,
    /// Whether it has stopped, and waits for the calls walking its list to finish (`Game.sweep`).
    stopped: bool = false,
};

/// The scripts that run in one place: the game's, or one object's.
const List = std.ArrayList(Running);

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
    /// The global and mission scripts that run, in the order they started.
    running: List = .empty,
    /// The object scripts that run on each object, by slot, in the order they started.
    on_objects: [gameobj.max_objects]List = @splat(.empty),
    /// The mods opened for the mission's scripts, which close as it ends.
    mission_mods: std.ArrayList(*Context) = .empty,
    events: events.Events,
    interfaces: interfaces.Interfaces,
    /// The mission that runs, if any.
    mission: ?MissionHeld = null,
    /// How many calls walk the lists of scripts that run, whose stopped scripts wait for them.
    walking: u32 = 0,
    /// Whether a script stopped while calls walked the lists.
    stopped: bool = false,

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
    pub fn start(gpa: Allocator, io: Io, opened: []const Mod, held: *records.Records, version: []const u8, all: *create.Objects) Allocator.Error!?*Game {
        const any = for (opened) |*mod| {
            var listed = globalScripts(mod);
            if (listed.next() != null) break true;
            var keys = mod.manifest.keys(script.missions_section);
            if (keys.next() != null) break true;
            if (attachesScripts(mod)) break true;
        } else false;
        if (!any) return null;

        const game = try gpa.create(Game);
        const scripts = Runtime.create(gpa, io, opened, .{ .side = .game, .limits = limits, .seed = load.seed, .version = version }) catch |err| {
            gpa.destroy(game);
            return err;
        };
        game.* = .{
            .gpa = gpa,
            .runtime = scripts,
            .hooks = undefined,
            .scripts = .{ .context = game, .vtable = &vtable },
            .objects = all,
            .events = .{ .gpa = gpa, .runtime = scripts },
            .interfaces = .{ .gpa = gpa, .runtime = scripts },
        };
        game.hooks = .init(gpa, scripts, &game.scripts);
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
        game.interfaces.push(state);
        scripts.setPackage(.interfaces);
        scripts.objects = all;
        scripts.game = game;
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
            while (listed.next()) |name| try game.startScript(&game.running, context, name, false, null);
        }
        return game;
    }

    /// Stops the game's scripts, as the game ends.
    pub fn stop(game: *Game) void {
        game.objects.scripts = null;
        game.stopObjectScripts();
        game.stopMissionScripts();
        for (game.running.items) |*running| running.offered.release(game.runtime);
        game.running.deinit(game.gpa);
        for (&game.on_objects) |*list| list.deinit(game.gpa);
        game.mission_mods.deinit(game.gpa);
        game.events.deinit();
        game.interfaces.deinit();
        game.hooks.deinit();
        game.runtime.destroy();
        game.gpa.destroy(game);
    }

    /// The game whose scripts make `call`. Raises an error where no game runs.
    pub fn of(call: Call, comptime label: []const u8) *Game {
        return call.runtime().game orelse call.raise("{s} can only be used while a game runs", .{label});
    }

    /// Runs the script `name` of the mod opened as `context`, keeps what it offers in `list`, and
    /// calls its `on_init` with `init`, then, for an object script, its `on_added`. A script that
    /// fails is logged and left out. `init` goes with the script.
    fn startScript(game: *Game, list: *List, context: *Context, name: []const u8, mission: bool, init: ?data.Data) Allocator.Error!void {
        defer if (init) |given| game.runtime.release(given.ref);
        const mod = context.modOf();
        const returned = game.runtime.run(context, name) orelse return;
        defer game.runtime.release(returned);
        var offered = context.offerOf(name, returned) orelse return;
        list.append(game.gpa, .{ .context = context, .name = name, .offered = offered, .mission = mission }) catch |err| {
            offered.release(game.runtime);
            return err;
        };
        const at = list.items.len - 1;
        inline for (comptime std.enums.values(script.Handler)) |handler| {
            if (comptime script.Handler.Arguments(handler) == null) {
                if (offered.handlers.get(handler) != null) log.warn("{s}: {s}: this version of OpenReliant doesn't call {t} yet", .{ mod.name, name, handler });
            }
        }
        if (offered.handlers.get(.on_object_added) != null) game.hooks.want(.object_added);
        log.info("{s}: started {s}", .{ mod.name, name });
        if (offered.interface) |interface| {
            if (try game.interfaces.offer(context, interface.name, interface.table)) |base| {
                game.callOne(list, at, .on_interface_override, .{ .base = .{ .ref = base } });
            }
        }
        game.callOne(list, at, .on_init, .{ .data = init });
        if (context.family == .object) game.callOne(list, at, .on_added, .{});
    }

    /// Calls the engine handler `handler` of the script at `at` in `list` with `arguments`.
    fn callOne(game: *Game, list: *List, at: usize, comptime handler: script.Handler, arguments: script.Handler.Arguments(handler).?) void {
        var made: Made = .{};
        defer made.release(game.runtime);
        const passed = made.pass(game.runtime, arguments) orelse return;
        game.walking += 1;
        defer game.leave();
        game.callPassed(list, at, handler, passed);
    }

    /// Calls `handler` of each running script of `list` with `arguments`, in order. Scripts that
    /// start meanwhile are called too.
    fn callEach(game: *Game, list: *List, comptime handler: script.Handler, arguments: script.Handler.Arguments(handler).?) void {
        if (list.items.len == 0) return;
        var made: Made = .{};
        defer made.release(game.runtime);
        const passed = made.pass(game.runtime, arguments) orelse return;
        game.walking += 1;
        defer game.leave();
        var at: usize = 0;
        while (at < list.items.len) : (at += 1) game.callPassed(list, at, handler, passed);
    }

    /// `callEach`, for the game's scripts and then each object's.
    fn callAll(game: *Game, comptime handler: script.Handler, arguments: script.Handler.Arguments(handler).?) void {
        game.walking += 1;
        defer game.leave();
        game.callEach(&game.running, handler, arguments);
        for (&game.on_objects) |*list| game.callEach(list, handler, arguments);
    }

    fn callPassed(game: *Game, list: *List, at: usize, comptime handler: script.Handler, passed: anytype) void {
        const running = &list.items[at];
        if (running.stopped) return;
        const function = running.offered.handlers.get(handler) orelse return;
        if (game.runtime.call(running.context, function, passed) != .failed) return;
        // The call may have added scripts to the list, which moves it.
        const failed = &list.items[at];
        log.warn("{s}: {s}: {t} failed, and isn't called again", .{ failed.context.modOf().name, failed.name, handler });
        game.runtime.release(function);
        failed.offered.handlers.set(handler, null);
    }

    fn leave(game: *Game) void {
        game.walking -= 1;
        if (game.walking == 0 and game.stopped) game.sweep();
    }

    /// Stops the script at `at` in `list`: lets go of what it offered, and closes its mod's context
    /// once none of its scripts there runs. It leaves the list once no call walks it (`sweep`).
    fn stopScript(game: *Game, list: *List, at: usize) void {
        const running = &list.items[at];
        if (running.stopped) return;
        running.stopped = true;
        running.offered.release(game.runtime);
        const context = running.context;
        const shared = for (list.items) |*other| {
            if (!other.stopped and other.context == context) break true;
        } else false;
        if (!shared) game.closeContext(context);
        game.stopped = true;
        if (game.walking == 0) game.sweep();
    }

    /// Closes a mod opened for scripts that have all stopped: their hooks and interfaces go.
    fn closeContext(game: *Game, context: *Context) void {
        game.hooks.removeContext(context);
        game.interfaces.removeContext(context);
        game.runtime.close(context);
    }

    /// Takes the stopped scripts out of their lists.
    fn sweep(game: *Game) void {
        sweepList(&game.running);
        for (&game.on_objects) |*list| sweepList(list);
        game.stopped = false;
    }

    fn sweepList(list: *List) void {
        var kept: usize = 0;
        for (list.items) |running| {
            if (running.stopped) continue;
            list.items[kept] = running;
            kept += 1;
        }
        list.shrinkRetainingCapacity(kept);
    }

    /// Stops the scripts of the mission, and closes the mods opened for them.
    fn stopMissionScripts(game: *Game) void {
        game.walking += 1;
        defer game.leave();
        for (game.running.items, 0..) |running, at| {
            if (running.mission) game.stopScript(&game.running, at);
        }
        for (game.mission_mods.items) |context| {
            if (!context.closed) game.closeContext(context);
        }
        game.mission_mods.clearRetainingCapacity();
    }

    /// Stops every object's scripts, as a mission ends.
    fn stopObjectScripts(game: *Game) void {
        for (0..game.on_objects.len) |index| game.stopObject(@intCast(index));
    }

    /// Stops the scripts of the object in slot `index`.
    fn stopObject(game: *Game, index: u16) void {
        game.walking += 1;
        defer game.leave();
        const list = &game.on_objects[index];
        for (0..list.items.len) |at| game.stopScript(list, at);
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
                    game.startScript(&game.on_objects[index], opened, name, false, null) catch |err| {
                        log.warn("{s}: {s} can't start on object {d}: {s}", .{ mod.name, name, index, @errorName(err) });
                    };
                }
            }
        }
    }

    /// Calls the `on_removed` of the scripts of the object in slot `index`, and stops them, as it
    /// leaves the mission.
    fn objectRemoved(game: *Game, index: u16) void {
        game.callEach(&game.on_objects[index], .on_removed, .{});
        game.stopObject(index);
    }

    /// Delivers the events sent since the last update (`events.zig`).
    fn deliver(game: *Game) void {
        var pending = game.events.take();
        defer pending.deinit(game.gpa);
        game.walking += 1;
        defer game.leave();
        for (pending.items) |*sent| {
            defer game.runtime.release(sent.data.ref);
            const list = switch (sent.to) {
                .global => &game.running,
                .object => |handle| if (handle.valid(game.objects)) &game.on_objects[handle.slot] else continue,
            };
            game.deliverTo(list, sent);
        }
    }

    /// Calls the handlers of `list` for the event `sent`, newest mod first, and within a mod in the
    /// order its scripts started.
    fn deliverTo(game: *Game, list: *List, sent: *const events.Pending) void {
        const name = sent.name.slice();
        var mod = game.runtime.mods.len;
        while (mod > 0) {
            mod -= 1;
            var at: usize = 0;
            while (at < list.items.len) : (at += 1) {
                const running = &list.items[at];
                if (running.stopped or running.context.mod != mod) continue;
                const table = running.offered.event_handlers orelse continue;
                const called = game.runtime.callIn(running.context, table, name, .{sent.data.ref}) orelse continue;
                switch (called) {
                    .returned_false => return,
                    .failed => log.warn("{s}: {s}: the handler of the event {s} failed", .{ list.items[at].context.modOf().name, list.items[at].name, name }),
                    .returned, .returned_nil => {},
                }
            }
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
    };

    fn hookCall(context: *anyopaque, hook_call: *engine_hooks.Call) void {
        const game = ofScripts(context);
        switch (hook_call.hook) {
            .object_added => {
                const index = objectOf(hook_call);
                game.objectAdded(index);
                game.callEach(&game.running, .on_object_added, .{ .object = .of(index) });
            },
            .object_removed => {
                const index = objectOf(hook_call);
                game.callEach(&game.running, .on_object_removed, .{ .object = .of(index) });
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

    fn startMissionScripts(game: *Game, mod: u16, listed: *script.List) Allocator.Error!void {
        try game.mission_mods.ensureUnusedCapacity(game.gpa, 1);
        const context = try game.runtime.open(mod, .global, null);
        game.mission_mods.appendAssumeCapacity(context);
        while (listed.next()) |name| try game.startScript(&game.running, context, name, true, null);
    }

    fn started(context: *anyopaque, mission: engine_hooks.Mission) void {
        const game = ofScripts(context);
        game.callEach(&game.running, .on_mission_start, .{ .mission = mission });
        game.hooks.tell(.mission_started, mission);
    }

    fn ended(context: *anyopaque, outcome: engine_hooks.Outcome) void {
        const game = ofScripts(context);
        game.callEach(&game.running, .on_mission_end, .{ .outcome = outcome });
        game.hooks.tell(.mission_ended, outcome);
        game.stopObjectScripts();
        game.stopMissionScripts();
        game.runtime.orders = null;
        game.mission = null;
    }

    fn update(context: *anyopaque, seconds: f32) void {
        const game = ofScripts(context);
        game.deliver();
        game.callAll(.on_update, .{ .seconds = seconds });
    }

    fn step(context: *anyopaque) void {
        ofScripts(context).callAll(.on_step, .{});
    }
};

/// The values made to pass an engine handler its arguments, let go once it has been called.
const Made = struct {
    refs: [max_made]luau.Ref = undefined,
    len: usize = 0,

    /// The most arguments a handler takes that are made rather than pushed as they are.
    const max_made = 4;

    fn release(made: *Made, scripts: *Runtime) void {
        for (made.refs[0..made.len]) |ref| scripts.release(ref);
    }

    /// The arguments `Runtime.call` takes for `arguments`: numbers as they are, and a reference to
    /// each value made for the others. Null if one can't be made.
    fn pass(made: *Made, scripts: *Runtime, arguments: anytype) ?Passed(@TypeOf(arguments)) {
        const Arguments = @TypeOf(arguments);
        var passed: Passed(Arguments) = undefined;
        inline for (@typeInfo(Arguments).@"struct".fields, 0..) |field, at| {
            const value = @field(arguments, field.name);
            passed[at] = switch (field.type) {
                f32 => value,
                ?data.Data => if (value) |given| given.ref else null,
                values.Table => value.ref,
                else => ref: {
                    const ref = scripts.make(Push(field.type).push, .{value}) orelse return null;
                    made.refs[made.len] = ref;
                    made.len += 1;
                    break :ref ref;
                },
            };
        }
        return passed;
    }

    /// The tuple `pass` gives for a handler's `Arguments`.
    fn Passed(comptime Arguments: type) type {
        const fields = @typeInfo(Arguments).@"struct".fields;
        var types: [fields.len]type = undefined;
        for (&types, fields) |*passed, field| passed.* = switch (field.type) {
            f32 => f32,
            ?data.Data => ?luau.Ref,
            else => luau.Ref,
        };
        return @Tuple(&types);
    }

    /// What pushes a value of `T` (`Runtime.make`).
    fn Push(comptime T: type) type {
        return struct {
            fn push(state: *State, value: T) void {
                values.push(state, T, value);
            }
        };
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
    const list = &game.on_objects[index];
    for (list.items) |running| {
        if (running.stopped or running.context.mod != call.context.mod) continue;
        if (std.ascii.eqlIgnoreCase(running.name, file)) {
            drop(scripts, payload);
            return false;
        }
    }
    const context = for (list.items) |running| {
        if (!running.stopped and running.context.mod == call.context.mod) break running.context;
    } else scripts.open(call.context.mod, .object, .of(game.objects, index)) catch {
        drop(scripts, payload);
        call.raise("add_script: out of memory", .{});
    };
    const before = list.items.len;
    game.startScript(list, context, file, false, payload) catch call.raise("add_script: out of memory", .{});
    return list.items.len > before;
}

/// `object:remove_script(name)`.
pub fn removeScript(call: Call, object: Object, name: []const u8) bool {
    const game = Game.of(call, "remove_script");
    if (call.context.family != .global) call.raise("remove_script: only global scripts can remove scripts", .{});
    const list = &game.on_objects[object.slot()];
    for (list.items, 0..) |running, at| {
        if (running.stopped or running.context.mod != call.context.mod) continue;
        if (!sameScript(running.name, name)) continue;
        game.stopScript(list, at);
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
    game.events.send(call, .{ .object = .of(game.objects, object.slot()) }, name, payload);
}

/// `core.send_global_event(name, data)`.
pub fn sendGlobalEvent(call: Call, name: []const u8, payload: data.Data) void {
    const game = call.runtime().game orelse {
        call.runtime().release(payload.ref);
        call.raise("send_global_event: events can only be sent while a game runs", .{});
    };
    game.events.send(call, .global, name, payload);
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
        fixture.game = (try Game.start(gpa, io, fixture.mods.list, &fixture.held, "0.7.0", fixture.mission.objects)).?;
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
    try std.testing.expectEqual(2, fixture.game.on_objects[sabre].items.len);
    try std.testing.expectEqual(1, all.slots[sabre].object.yaw_input);
    try std.testing.expectEqual(1.5, fixture.scaled(sabre, 3));
    try std.testing.expectEqual(1.5, fixture.scaled(sabre, 3));
    // The first Sabre's hits aren't halved, and don't count for the other.
    try std.testing.expectEqual(3, fixture.scaled(fixture.sabre, 3));
    fixture.game.scripts.update(0.1);
    try std.testing.expectEqual(0.25, all.slots[sabre].object.throttle);
    // As it leaves, its scripts stop with it.
    all.resetSlot(sabre, &fixture.mission.random);
    try std.testing.expectEqual(0, fixture.game.on_objects[sabre].items.len);
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
    try std.testing.expectEqual(1, fixture.game.on_objects[fixture.sabre].items.len);
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
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "wingmen", &.{
        .{ "mod.ini", @embedFile("wingmen/mod.ini") },
        .{ "wingman.luau", @embedFile("wingmen/wingman.luau") },
        .{ "wingmen.luau", @embedFile("wingmen/wingmen.luau") },
    } }});
    defer fixture.deinit();
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
