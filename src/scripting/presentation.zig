//! The presentation side of mods' scripts ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! player and menu scripts, which decide what the player sees, hears and does, in a Luau state of
//! their own.
//!
//! - A mod's `Menu` scripts start as OpenReliant starts, and run until it quits, in the menus and
//!   over the missions.
//! - Its `Player` scripts start as a game starts, and stop as it ends, as the global scripts do.
//! - Both get `on_frame` each frame drawn, even while the game is paused; `on_key_press` and
//!   `on_key_release` as keys go down and up; `on_action` as the controls bound to an action are
//!   used in flight; and `on_viewport_resized` as the window changes size.
//! - They draw over the flight display and the menus (`drawing.zig`), and change the game only by
//!   sending events to the global scripts (`core.send_global_event`), whose data is copied into the
//!   game's state, as it would be sent to another machine.
//!
//! If no mod has player or menu scripts, no Luau state is created.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const mods = engine.game.bigfile.mods;
const Mod = mods.Mod;
const create = engine.game.create;
const hud = engine.game.hud;
const camera = engine.game.camera;
const hog_snd = engine.game.hog_snd;
const input = engine.input;
const mod_options = engine.game.interface.mod_options;
const postprocessing = @import("postprocessing.zig");
const controls = engine.input.controls;
const device = engine.surrender.srd3d.device;
const engine_hooks = engine.hooks;
const script = @import("script.zig");
const runtime = @import("runtime.zig");
const Runtime = runtime.Runtime;
const records = @import("records.zig");
const packages = @import("packages.zig");
const objects = @import("objects.zig");
const interfaces = @import("interfaces.zig");
const running = @import("running.zig");
const drawing = @import("drawing.zig");
const data = @import("data.zig");
const api = @import("api.zig");
const Call = api.Call;
const load = @import("load.zig");
const game_module = @import("game.zig");

/// Limits for player and menu scripts: 100 milliseconds per call, and 64 MiB per mod, as for the
/// game's.
pub const limits: runtime.Limits = .{ .time = .fromMilliseconds(100), .memory = 64 << 20 };

/// The scripts of each kind that runs on the presentation side.
const Place = enum { menu, player };

/// The kinds of keys a keyboard reports, by scan code (`input.Key`).
const key_codes = std.math.maxInt(@typeInfo(input.Key).@"enum".tag_type) + 1;

/// What the driver tells the scripts of a frame.
pub const Host = struct {
    /// The seconds of real time since the last frame.
    seconds: f32,
    /// The keyboard, the joystick and the bindings.
    devices: *input.Devices,
    /// The window's size in pixels.
    window: [2]u32,
    /// What each layer is drawn on this frame; null for one that isn't shown.
    views: std.EnumArray(drawing.Which, ?drawing.View) = .initFill(null),
    /// The camera, while a mission is shown.
    camera: ?Camera = null,
    /// The sound, where any is heard.
    sound: ?*hog_snd.Sound = null,
    /// Whether the player is flying, which is when the controls' actions mean anything.
    flying: bool = false,

    pub const Camera = struct {
        camera: *camera.Camera,
        /// The time the camera's views switch by (`main.Clock.viewTime`).
        now: u32,
        /// The player's ship, which a view follows unless a script names another object.
        player: u16,
    };
};

/// The presentation side of mods' scripts.
pub const Presentation = struct {
    gpa: Allocator,
    runtime: *Runtime,
    runner: running.Runner,
    lists: std.EnumArray(Place, running.List) = .initFill(.empty),
    layers: std.EnumArray(drawing.Which, drawing.Layer) = .initFill(.{}),
    assets: drawing.Assets = .{},
    /// What each layer is drawn on this frame.
    views: std.EnumArray(drawing.Which, ?drawing.View) = .initFill(null),
    /// What the driver told of the last frame, which the packages reach the game through.
    host: ?Host = null,
    /// The game's scripts while a game runs, which the scripts' events go to.
    game: ?*game_module.Game = null,
    /// The keys held, which presses and releases are told against.
    keys: std.StaticBitSet(key_codes) = .initEmpty(),
    /// The actions whose controls were held last frame.
    actions: std.EnumSet(controls.Action) = .initEmpty(),
    /// The window's size last frame.
    window: ?[2]u32 = null,

    /// Starts the `Menu` scripts of `opened`, which can read `held`, the records. `version` is
    /// OpenReliant's version. Returns null if no mod has player or menu scripts.
    pub fn start(gpa: Allocator, io: Io, opened: []const Mod, held: *records.Records, version: []const u8, shared: runtime.Shared) Allocator.Error!?*Presentation {
        const any = for (opened) |*mod| {
            if (hasScripts(mod)) break true;
        } else false;
        if (!any) return null;

        const shown = try gpa.create(Presentation);
        const scripts = Runtime.create(gpa, io, opened, .{ .side = .presentation, .limits = limits, .seed = load.seed, .version = version, .shared = shared }) catch |err| {
            gpa.destroy(shown);
            return err;
        };
        shown.* = .{ .gpa = gpa, .runtime = scripts, .runner = undefined };
        shown.runner = .init(gpa, scripts, &shown.lists.values);
        errdefer shown.stop();
        const state = scripts.state;
        records.register(state);
        records.push(state, held, false);
        scripts.setPackage(.records);
        packages.push(scripts);
        objects.register(scripts);
        interfaces.Interfaces.register(state);
        shown.runner.interfaces.push(state);
        scripts.setPackage(.interfaces);
        scripts.presentation = shown;
        scripts.runner = &shown.runner;
        try shown.startScripts(.menu, false);
        return shown;
    }

    /// Stops the scripts, as OpenReliant quits.
    pub fn stop(shown: *Presentation) void {
        shown.runner.deinit();
        for (&shown.layers.values) |*layer| layer.deinit(shown.gpa);
        shown.assets.deinit(shown.gpa);
        shown.runtime.destroy();
        shown.gpa.destroy(shown);
    }

    /// Reads the folder mods' scripts again, and starts the menu scripts again, with `on_init`, as
    /// the console's `reload` does. The player scripts start again with the game's
    /// (`startGame`).
    pub fn reload(shown: *Presentation) Allocator.Error!void {
        shown.runner.stopAll(shown.lists.getPtr(.menu));
        try shown.runtime.recompileFolders();
        try shown.startScripts(.menu, false);
    }

    /// The presentation side whose script makes `call`. Raises an error from a game script.
    pub fn of(call: Call, comptime label: []const u8) *Presentation {
        return call.runtime().presentation orelse call.raise("{s} can only be used by player and menu scripts", .{label});
    }

    /// What the driver told of the last frame. Raises an error before the first.
    pub fn hostOf(call: Call, comptime label: []const u8) Host {
        return of(call, label).host orelse call.raise("{s} can only be used once frames are drawn", .{label});
    }

    /// Starts the scripts each mod lists for `place`, in load order.
    fn startScripts(shown: *Presentation, comptime place: Place, loading: bool) Allocator.Error!void {
        for (shown.runtime.mods, 0..) |*mod, at| {
            var listed = listedScripts(mod, place);
            if (listed.next() == null) continue;
            listed = listedScripts(mod, place);
            const context = try shown.runtime.open(@intCast(at), familyOf(place), null);
            while (listed.next()) |name| _ = try shown.runner.start(shown.lists.getPtr(place), context, name, false, null, loading);
        }
    }

    /// Starts the `Player` scripts as a game starts, with `game`, the game's scripts if any mod
    /// has some, and `all`, the game's objects; `loading` as `Game.start` has it.
    pub fn startGame(shown: *Presentation, game: ?*game_module.Game, all: *create.Objects, loading: bool) Allocator.Error!void {
        shown.endGame();
        shown.game = game;
        shown.runtime.objects = all;
        try shown.startScripts(.player, loading);
    }

    /// Stops the `Player` scripts as the game ends.
    pub fn endGame(shown: *Presentation) void {
        shown.resetRegisteredCamera();
        shown.runner.stopAll(shown.lists.getPtr(.player));
        shown.game = null;
        shown.runtime.objects = null;
    }

    /// Tells the scripts that `mission` has started.
    pub fn missionStarted(shown: *Presentation, mission: engine_hooks.Mission) void {
        shown.runner.callAll(.on_mission_start, .{ .mission = mission });
    }

    /// Tells the scripts that the mission has ended as `outcome` says.
    pub fn missionEnded(shown: *Presentation, outcome: engine_hooks.Outcome) void {
        shown.resetRegisteredCamera();
        shown.runner.callAll(.on_mission_end, .{ .outcome = outcome });
    }

    /// A mission transition must not keep a camera callback's subject from the previous scene.
    fn resetRegisteredCamera(shown: *Presentation) void {
        shown.runtime.registries.resetCamera(shown.runtime);
    }

    /// Sets what compiles and draws the scripts' post effects, or null for nothing
    /// (`postprocessing.Registry.setHost`). Call it with null before the host is destroyed.
    pub fn setEffectHost(shown: *Presentation, host: ?postprocessing.EffectHost) void {
        shown.runtime.post_effects.setHost(host);
    }

    /// The passes of the post effects the scripts have enabled, in the order they draw.
    pub fn effectPasses(shown: *const Presentation, buffer: *[postprocessing.max_effects]postprocessing.Pass) []const postprocessing.Pass {
        return shown.runtime.post_effects.passes(buffer);
    }

    /// Tells the scripts of the mod `mod` that the player set its option `option` to `value`.
    pub fn settingChanged(shown: *Presentation, mod: []const u8, option: []const u8, value: mod_options.Value) void {
        shown.runner.callMod(mod, .on_setting_changed, .{ .key = option, .value = value });
    }

    /// Tells the scripts that `key` went down or up. A key held down that the window repeats is
    /// told once.
    pub fn key(shown: *Presentation, pressed: input.Key, down: bool) void {
        const code = @intFromEnum(pressed);
        if (shown.keys.isSet(code) == down) return;
        shown.keys.setValue(code, down);
        shown.runtime.registries.input(shown.runtime, pressed, down);
        if (down) {
            shown.runner.callAll(.on_key_press, .{ .key = pressed });
        } else {
            shown.runner.callAll(.on_key_release, .{ .key = pressed });
        }
    }

    /// Runs a frame of the scripts: what they drew last frame goes, the window's new size and the
    /// actions used are told, and `on_frame` runs.
    pub fn frame(shown: *Presentation, host: Host) void {
        shown.host = host;
        shown.views = host.views;
        for (&shown.layers.values) |*layer| layer.clear();
        if (shown.window) |last| {
            if (!std.mem.eql(u32, &last, &host.window)) shown.runner.callAll(.on_viewport_resized, .{ .width = host.window[0], .height = host.window[1] });
        }
        shown.window = host.window;
        var held: std.EnumSet(controls.Action) = .initEmpty();
        if (host.flying) {
            for (std.enums.values(controls.Action)) |action| {
                if (!host.devices.active(action, false)) continue;
                held.insert(action);
                if (!shown.actions.contains(action)) shown.runner.callAll(.on_action, .{ .action = @tagName(action) });
            }
        }
        shown.actions = held;
        const registry = &shown.runtime.input_actions;
        host.devices.mod_actions = registry;
        // Callbacks may register or close contexts; fixed entry slots keep the walk valid.
        const count = registry.count;
        for (0..count) |index| {
            if (registry.pressed(index, host.devices, host.flying)) {
                // A handler can reload registration slots. Keep this event's name stable.
                const name = registry.entries[index].name;
                shown.runner.callAll(.on_action, .{ .action = std.mem.sliceTo(&name, 0) });
            }
        }
        shown.runner.advance(host.seconds);
        shown.runner.callAll(.on_frame, .{ .seconds = host.seconds });
        shown.runtime.registries.frame(shown.runtime, host.seconds);
    }

    /// Draws what the scripts drew on `which` this frame into `into`, where it's shown. `sight`
    /// places what they drew in the world.
    pub fn draw(shown: *const Presentation, which: drawing.Which, into: device.Device, sight: ?hud.Sight) Allocator.Error!void {
        const view = shown.views.get(which) orelse return;
        try shown.layers.getPtrConst(which).draw(into, view, sight);
    }

    /// `core.send_global_event` from a player or menu script: the event goes to the game's
    /// scripts, its data copied into their state. Takes `payload` over.
    pub fn sendToGame(shown: *Presentation, call: Call, name: []const u8, payload: data.Data) void {
        const game = shown.game orelse {
            shown.runtime.release(payload.ref);
            call.raise("send_global_event: events can only be sent while a game runs", .{});
        };
        const copied = data.transfer(call.state, payload.ref, game.runtime);
        shown.runtime.release(payload.ref);
        const ref = copied orelse call.raise("send_global_event: out of memory", .{});
        game.runner.events.send(call, .global, name, .{ .ref = ref });
    }
};

/// The family of the scripts of `place`.
fn familyOf(place: Place) script.Family {
    return switch (place) {
        .menu => .menu,
        .player => .player,
    };
}

/// Whether `mod` lists player or menu scripts.
fn hasScripts(mod: *const Mod) bool {
    for (std.enums.values(Place)) |place| {
        var listed = listedScripts(mod, place);
        if (listed.next() != null) return true;
    }
    return false;
}

/// The scripts `mod` lists for `place`, in order.
fn listedScripts(mod: *const Mod, place: Place) script.List {
    const kind: script.Kind = switch (place) {
        .menu => .menu,
        .player => .player,
    };
    return .of(mod.manifest.value(script.section, kind.key()) orelse "");
}

/// Player and menu scripts from the mods `made`, each a folder of files, and the game's scripts
/// over a mission that holds the player's Predator.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    mods: mods.Mods,
    arena: std.heap.ArenaAllocator,
    held: records.Records,
    mission: engine.game.gameobj.testing.Mission,
    shown: *Presentation,
    devices: input.Devices = .{},
    font: hud.Opened,

    fn init(fixture: *Fixture, made: []const struct { []const u8, []const struct { []const u8, []const u8 } }) !void {
        return fixture.initShared(made, .{});
    }

    /// `init`, with what the mods share; where it has a registry of options, the load scripts run
    /// first, to declare the pages the others read.
    fn initShared(fixture: *Fixture, made: []const struct { []const u8, []const struct { []const u8, []const u8 } }, shared: runtime.Shared) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        fixture.* = .{ .tmp = std.testing.tmpDir(.{ .iterate = true }), .mods = undefined, .arena = .init(gpa), .held = undefined, .mission = undefined, .shown = undefined, .font = .open(try openreliant.fnt.Font.parse(comptime openreliant.fnt.testing.font(false)), null) };
        errdefer fixture.tmp.cleanup();
        errdefer fixture.arena.deinit();
        try load.testing.makeMods(io, fixture.tmp.dir, made);
        fixture.mods = try .open(gpa, io, fixture.tmp.dir, null);
        errdefer fixture.mods.close(gpa);
        fixture.held = try load.testing.records3(fixture.arena.allocator());
        try fixture.mission.init(gpa);
        errdefer fixture.mission.deinit();
        _ = try fixture.mission.add(.predator, @splat(0));
        if (shared.settings != null) try load.run(gpa, io, fixture.mods.list, &fixture.held, "0.7.0", shared);
        fixture.shown = (try Presentation.start(gpa, io, fixture.mods.list, &fixture.held, "0.7.0", shared)).?;
    }

    fn deinit(fixture: *Fixture) void {
        fixture.shown.stop();
        fixture.mission.deinit();
        fixture.arena.deinit();
        fixture.mods.close(std.testing.allocator);
        fixture.tmp.cleanup();
    }

    /// A frame of `seconds`, in a window of `window`, with the menus shown.
    fn frame(fixture: *Fixture, seconds: f32, window: [2]u32) void {
        var host: Host = .{ .seconds = seconds, .devices = &fixture.devices, .window = window };
        host.views.set(.ui, .{ .font = &fixture.font, .gpa = std.testing.allocator, .screen = window, .scale = 2 });
        fixture.shown.frame(host);
    }
};

test "menu actions dispatch qualified press edges in flight and close on reload" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nMenu=a.luau\n" },
            .{
                "a.luau",
                \\local input = require("openreliant.input")
                \\local action = input.register_action("pulse", {label = "Pulse", key = "f12", modifier = "shift"})
                \\local count = 0
                \\assert(action == "a:pulse")
                \\assert(not pcall(function() input.register_action("pulse", {label = "Duplicate"}) end))
                \\return {engine_handlers = {on_action = function(name)
                \\    if name == action then
                \\        count += 1; assert(count == 1 and input.action_down(action))
                \\    end
                \\end, on_frame = function()
                \\    require("openreliant.ui").text(vector.zero, tostring(count))
                \\end}}
            },
        },
    }});
    defer fixture.deinit();
    const index = fixture.shown.runtime.input_actions.find("a:pulse").?;
    var host: Host = .{ .seconds = 0.04, .devices = &fixture.devices, .window = .{ 640, 480 }, .flying = true };
    fixture.shown.frame(host);
    fixture.devices.keyboard.down[@intFromEnum(input.Key.f12)] = true;
    fixture.devices.keyboard.down[input.scan.left_shift] = true;
    fixture.shown.frame(host);
    try std.testing.expect(fixture.shown.runtime.input_actions.entries[index].held);
    try std.testing.expectEqualStrings("1", fixture.shown.layers.get(.ui).text.items);
    fixture.shown.frame(host);
    host.flying = false;
    fixture.shown.frame(host);
    try std.testing.expect(!fixture.shown.runtime.input_actions.entries[index].held);
    try fixture.shown.reload();
    host.flying = true;
    fixture.shown.frame(host);
    try std.testing.expect(!fixture.shown.runtime.input_actions.entries[index].ready);
}

test "registered views, displays and screens execute and close with their contexts" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nPlayer=player.luau\nMenu=menu.luau\n" },
            .{
                "player.luau",
                \\local camera = require("openreliant.camera")
                \\local hud = require("openreliant.hud")
                \\local util = require("openreliant.util")
                \\local view = camera.register_view("follow", {letterbox = true, frame = function(ship, seconds)
                \\    return {position = ship.position + vector.create(0, -50, -100), orientation = util.from_angles(vector.zero)}
                \\end})
                \\hud.register_display("status", {frame = function() hud.text(vector.zero, "registered display") end})
                \\return {engine_handlers = {on_frame = function()
                \\    assert(camera.set_view(view))
                \\    assert(camera.view == view)
                \\end}}
            },
            .{
                "menu.luau",
                \\local ui = require("openreliant.ui")
                \\local screen = ui.register_screen("panel", {frame = function() ui.text(vector.zero, "registered screen") end,
                \\    key = function(key, down) if key == "escape" and down then assert(ui.show_screen(nil)) end end})
                \\assert(ui.show_screen(screen))
            },
        },
    }});
    defer fixture.deinit();
    try fixture.shown.startGame(null, fixture.mission.objects, false);
    var view: engine.game.camera.Camera = .{};
    var host: Host = .{ .seconds = 0.04, .devices = &fixture.devices, .window = .{ 640, 480 }, .camera = .{ .camera = &view, .now = 1, .player = 0 } };
    const layer: drawing.View = .{ .font = &fixture.font, .gpa = gpa, .screen = .{ 640, 480 }, .scale = 1 };
    host.views.set(.hud, layer);
    host.views.set(.ui, layer);
    fixture.shown.frame(host);
    try std.testing.expectEqualStrings("registered display", fixture.shown.layers.get(.hud).text.items);
    try std.testing.expectEqualStrings("registered screen", fixture.shown.layers.get(.ui).text.items);
    try engine.surrender.math.testing.expectVector(.{ 0, -50, -100 }, view.place.position);
    try std.testing.expectEqual(engine.game.camera.letterbox, view.bars);
    fixture.shown.key(.escape, true);
    try std.testing.expectEqual(null, fixture.shown.runtime.registries.selected_screen);
    fixture.shown.endGame();
    try std.testing.expectEqual(engine.game.camera.View.cockpit, view.view);
    try std.testing.expectEqual(null, fixture.shown.runtime.registries.find(.display, "a:status"));
    try fixture.shown.reload();
    try std.testing.expect(fixture.shown.runtime.registries.find(.screen, "a:panel") != null);
}

test "camera locks take precedence and failed registry callbacks fall back safely" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nPlayer=player.luau\nMenu=menu.luau\n" },
            .{ "menu.luau", "local ui = require('openreliant.ui'); ui.register_screen('bad', {frame = function() ui.text(vector.zero, 'partial'); error('broken screen') end})" },
            .{
                "player.luau",
                \\local camera = require("openreliant.camera")
                \\local view = camera.register_view("bad", {frame = function() return {position = vector.zero} end})
                \\return {engine_handlers = {on_frame = function() camera.set_view(view) end}}
            },
        },
    }});
    defer fixture.deinit();
    try fixture.shown.startGame(null, fixture.mission.objects, false);
    var view: engine.game.camera.Camera = .{ .locked = true, .view = .director };
    var host: Host = .{ .seconds = 0.04, .devices = &fixture.devices, .window = .{ 640, 480 }, .camera = .{ .camera = &view, .now = 1, .player = 0 } };
    fixture.shown.frame(host);
    try std.testing.expectEqual(engine.game.camera.View.director, view.view);
    view.locked = false;
    fixture.shown.frame(host);
    try std.testing.expectEqual(engine.game.camera.View.cockpit, view.view);
    try std.testing.expectEqual(null, fixture.shown.runtime.registries.find(.camera, "a:bad"));
    host.views.set(.ui, .{ .font = &fixture.font, .gpa = std.testing.allocator, .screen = .{ 640, 480 }, .scale = 1 });
    fixture.shown.runtime.registries.selected_screen = fixture.shown.runtime.registries.find(.screen, "a:bad");
    fixture.shown.frame(host);
    try std.testing.expectEqual(null, fixture.shown.runtime.registries.selected_screen);
    try std.testing.expectEqual(0, fixture.shown.layers.get(.ui).commands.items.len);
}

test "camera callbacks that select an original view do not apply their returned pose" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nPlayer=a.luau\n" },
            .{
                "a.luau",
                \\local camera = require("openreliant.camera")
                \\local util = require("openreliant.util")
                \\local name = camera.register_view("switch", {frame = function()
                \\    assert(camera.set_view("external"))
                \\    return {position = vector.create(999, 999, 999), orientation = util.from_angles(vector.zero)}
                \\end})
                \\return {engine_handlers = {on_frame = function() camera.set_view(name) end}}
            },
        },
    }});
    defer fixture.deinit();
    try fixture.shown.startGame(null, fixture.mission.objects, false);
    var view: engine.game.camera.Camera = .{};
    fixture.shown.frame(.{ .seconds = 0.04, .devices = &fixture.devices, .window = .{ 640, 480 }, .camera = .{ .camera = &view, .now = 1, .player = 0 } });
    try std.testing.expectEqual(engine.game.camera.View.external, view.view);
    try engine.surrender.math.testing.expectVector(@splat(0), view.place.position);
    try std.testing.expectEqual(null, fixture.shown.runtime.registries.selected_camera);
}

test "presentation names isolate mods and failed loads remove only new registrations" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{
        .{ "a", &.{
            .{ "mod.ini", "[Scripts]\nMenu=good.luau,bad.luau\n" },
            .{ "good.luau", "local ui = require('openreliant.ui'); assert(ui.register_screen('panel', {frame = function() end}) == 'a:panel'); assert(not pcall(ui.register_screen, 'panel', {frame = function() end}))" },
            .{ "bad.luau", "require('openreliant.ui').register_screen('discard', {frame = function() end}); error('bad load')" },
        } },
        .{ "b", &.{ .{ "mod.ini", "[Scripts]\nMenu=b.luau\n" }, .{ "b.luau", "assert(require('openreliant.ui').register_screen('panel', {frame = function() end}) == 'b:panel')" } } },
    });
    defer fixture.deinit();
    try std.testing.expect(fixture.shown.runtime.registries.find(.screen, "a:panel") != null);
    try std.testing.expect(fixture.shown.runtime.registries.find(.screen, "b:panel") != null);
    try std.testing.expectEqual(null, fixture.shown.runtime.registries.find(.screen, "a:discard"));
}

test "the strafe-run example combines registries and built-in interfaces" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "strafe-run", &.{
        .{ "mod.ini", @embedFile("strafe-run/mod.ini") },
        .{ "order.luau", @embedFile("strafe-run/order.luau") },
        .{ "actions.luau", @embedFile("strafe-run/actions.luau") },
        .{ "display.luau", @embedFile("strafe-run/display.luau") },
    } }});
    defer fixture.deinit();
    const sabre = try fixture.mission.add(.sabre, .{ 0, 0, 1000 });
    const scripts = (try game_module.Game.start(std.testing.allocator, std.testing.io, fixture.mods.list, &fixture.held, "0.7.0", fixture.mission.objects, .{}, false)).?;
    defer scripts.stop();
    try fixture.shown.startGame(scripts, fixture.mission.objects, false);
    defer fixture.shown.endGame();
    scripts.scripts.begin(fixture.mission.orders(), .{ .number = 0, .file = "mission0.dte" }, 1);
    var view: engine.game.camera.Camera = .{};
    var host: Host = .{ .seconds = 0.04, .devices = &fixture.devices, .window = .{ 640, 480 }, .flying = true, .camera = .{ .camera = &view, .now = 1, .player = 0 } };
    const layer: drawing.View = .{ .font = &fixture.font, .gpa = std.testing.allocator, .screen = .{ 640, 480 }, .scale = 1 };
    host.views.set(.hud, layer);
    host.views.set(.ui, layer);
    fixture.shown.frame(host);
    try std.testing.expectEqualStrings("Shift F12: strafe run", fixture.shown.layers.get(.hud).text.items);
    fixture.devices.keyboard.down[input.scan.left_shift] = true;
    fixture.devices.keyboard.down[@intFromEnum(input.Key.f12)] = true;
    fixture.shown.frame(host);
    scripts.scripts.update(0.04);
    try std.testing.expectEqual(scripts.runtime.custom_orders.find("strafe-run:strafe_run").?, fixture.mission.slot(sabre).current().?.order);
    engine.game.aigeneric.objectOrders(fixture.mission.orders(), sabre);
    try std.testing.expectEqual(0.25, fixture.mission.slot(sabre).object.yaw_input);
    fixture.devices.keyboard.down[@intFromEnum(input.Key.f10)] = true;
    fixture.shown.frame(host);
    try std.testing.expectEqualStrings("strafe-run:chase", fixture.shown.runtime.registries.cameraName(view.view).?);
    try engine.surrender.math.testing.expectVector(.{ 0, -200, -1000 }, view.place.position);
    fixture.devices.keyboard.down[@intFromEnum(input.Key.f9)] = true;
    fixture.shown.frame(host);
    try std.testing.expect(fixture.shown.runtime.registries.selected_screen != null);
    try std.testing.expect(fixture.shown.layers.get(.ui).commands.items.len == 3);
}

test "the example action sends a game event that starts its custom order" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "custom-order", &.{
        .{ "mod.ini", @embedFile("custom-order/mod.ini") },
        .{ "pulse.luau", @embedFile("custom-order/pulse.luau") },
        .{ "action.luau", @embedFile("custom-order/action.luau") },
    } }});
    defer fixture.deinit();
    const sabre = try fixture.mission.add(.sabre, .{ 0, 0, 1000 });
    const game_scripts = (try game_module.Game.start(std.testing.allocator, std.testing.io, fixture.mods.list, &fixture.held, "0.7.0", fixture.mission.objects, .{}, false)).?;
    defer game_scripts.stop();
    try fixture.shown.startGame(game_scripts, fixture.mission.objects, false);
    defer fixture.shown.endGame();
    game_scripts.scripts.begin(fixture.mission.orders(), .{ .number = 0, .file = "mission0.dte" }, 1);
    var host: Host = .{ .seconds = 0.04, .devices = &fixture.devices, .window = .{ 640, 480 }, .flying = true };
    fixture.shown.frame(host);
    fixture.devices.keyboard.down[@intFromEnum(input.Key.f12)] = true;
    fixture.devices.keyboard.down[input.scan.left_shift] = true;
    fixture.shown.frame(host);
    game_scripts.scripts.update(0.04);
    const pulse = game_scripts.runtime.custom_orders.find("custom-order:pulse").?;
    try std.testing.expectEqual(pulse, fixture.mission.slot(sabre).current().?.order);
    engine.game.aigeneric.objectOrders(fixture.mission.orders(), sabre);
    try std.testing.expectEqual(0.25, fixture.mission.slot(sabre).object.throttle);
    host.flying = false;
    fixture.shown.frame(host);
}

test "menu scripts draw over the menus, and hear keys and the window" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nMenu=menu.luau\n" },
            .{
                "menu.luau",
                \\local ui = require("openreliant.ui")
                \\local presses = 0
                \\local resized = nil
                \\return { engine_handlers = {
                \\    on_key_press = function(key) if key == "escape" then presses += 1 end end,
                \\    on_viewport_resized = function(width, height) resized = width end,
                \\    on_frame = function(seconds)
                \\        assert(ui.width == (resized or 800))
                \\        -- Code 1 is two pixels wide and tall, drawn at twice the game's size.
                \\        local size = ui.measure("\1\1", 2)
                \\        assert(size.width == 16 and size.height == 8)
                \\        ui.text(vector.create(10, 20, 0), "pressed " .. presses, { colour = vector.create(1, 0, 0), align = "centre" })
                \\        ui.rectangle(vector.create(0, 0, 0), vector.create(5, 5, 0), { alpha = 0.5 })
                \\        if resized then ui.line(vector.create(0, 0, 0), vector.create(resized, 0, 0)) end
                \\        assert(not pcall(ui.text, vector.create(0, 0, 0), "x", { colur = 1 }))
                \\    end,
                \\} }
            },
        },
    }});
    defer fixture.deinit();
    const shown = fixture.shown;
    fixture.frame(0.016, .{ 800, 600 });
    try std.testing.expectEqual(2, shown.layers.get(.ui).commands.items.len);
    // A key held down that the window repeats is told once.
    shown.key(.escape, true);
    shown.key(.escape, true);
    shown.key(.escape, false);
    fixture.frame(0.016, .{ 800, 600 });
    const layer = shown.layers.getPtr(.ui);
    try std.testing.expectEqualStrings("pressed 1", layer.text.items);
    try std.testing.expectEqual(hud.Align.centre, layer.commands.items[0].text.alignment);
    // A new size is told before the frame, which draws a line across the new width.
    fixture.frame(0.016, .{ 1024, 768 });
    try std.testing.expectEqual(3, layer.commands.items.len);
    try std.testing.expectEqual(1024, layer.commands.items[2].line.to.screen[0]);
}

test "scripts draw cached mod pictures, game shapes and measured custom fonts" {
    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nMenu=a.luau\n" },
            .{ "font.ttf", "face" },
            .{ "bad.ttf", "not a font" },
            .{ "bad.png", "not a PNG" },
            .{
                "a.luau",
                \\local ui = require("openreliant.ui")
                \\return {engine_handlers = {on_frame = function()
                \\    local style = {font = "font.ttf", base_font = "menu_large", scale = 2}
                \\    local size = ui.measure("AH", style)
                \\    assert(size.width == 24 and size.height == 16)
                \\    ui.text(vector.create(1, 2, 0), "AH", style)
                \\    ui.text(vector.zero, "AH", {font = "menu_large"})
                \\    ui.picture(vector.create(10, 20, 0), "icon.png", vector.create(12, 8, 0), {alpha = 0.5})
                \\    ui.shape(vector.create(30, 40, 0), 1, {scale = 2})
                \\    assert(not pcall(ui.picture, vector.zero, "bad.png"))
                \\    assert(not pcall(ui.text, vector.zero, "AH", {font = "bad.ttf"}))
                \\    assert(not pcall(ui.picture, vector.zero, "../icon.png"))
                \\end}}
            },
        },
    }});
    defer fixture.deinit();
    var png: std.Io.Writer.Allocating = .init(gpa);
    defer png.deinit();
    try openreliant.png.writeRgba(gpa, &png.writer, 1, 1, &.{ 255, 0, 0, 255 });
    const mod = fixture.mods.list[0];
    try mod.source.folder.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = png.written() });
    // Folder lookup is inventoried at open, so reopen after adding the synthetic picture.
    fixture.shown.stop();
    fixture.mods.close(gpa);
    fixture.mods = try .open(gpa, std.testing.io, fixture.tmp.dir, null);
    fixture.shown = (try Presentation.start(gpa, std.testing.io, fixture.mods.list, &fixture.held, "0.7.0", .{})).?;
    var boxes: hud.outline.testing.Boxes = .{};
    defer std.debug.assert(boxes.open_faces == 0);
    // Close cached faces before checking the rasterizer's lifetime.
    defer fixture.shown.assets.deinit(gpa);
    var font: hud.Opened = .ramp(try openreliant.fnt.Font.parse(hud.outline.testing.font));
    defer font.deinit(gpa);
    const sprite_bytes = try openreliant.spr.testing.paletteAndShape(gpa);
    defer gpa.free(sprite_bytes);
    var art = try hud.Art.init(gpa, try openreliant.spr.Sprite.parse(sprite_bytes), null, null);
    defer art.deinit(gpa);
    var view: drawing.View = .{ .font = &fixture.font, .gpa = gpa, .screen = .{ 640, 480 }, .scale = 1, .art = &art, .rasterizer = boxes.rasterizer() };
    view.fonts.set(.menu_large, &font);
    var host: Host = .{ .seconds = 0.04, .devices = &fixture.devices, .window = .{ 640, 480 } };
    host.views.set(.ui, view);
    fixture.shown.frame(host);
    try std.testing.expectEqual(4, fixture.shown.layers.get(.ui).commands.items.len);
    try std.testing.expectEqual(1, fixture.shown.assets.pictures.items.len);
    try std.testing.expectEqual(1, fixture.shown.assets.fonts.items.len);
    var recorder: device.testing.Recorder = .{ .gpa = gpa };
    defer recorder.deinit();
    try fixture.shown.draw(.ui, recorder.interface(), null);
    try std.testing.expect(recorder.draws.items.len > 2);
    fixture.shown.frame(host);
    try std.testing.expectEqual(1, fixture.shown.assets.pictures.items.len);
    try fixture.shown.reload();
    fixture.shown.frame(host);
    try std.testing.expectEqual(2, fixture.shown.assets.pictures.items.len);
    try std.testing.expectEqual(2, fixture.shown.assets.fonts.items.len);
}

test "the drawing assets example handles absent optional files" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "drawing-assets", &.{
        .{ "mod.ini", @embedFile("drawing-assets/mod.ini") },
        .{ "drawing.luau", @embedFile("drawing-assets/drawing.luau") },
    } }});
    defer fixture.deinit();
    var view: drawing.View = .{ .font = &fixture.font, .gpa = std.testing.allocator, .screen = .{ 640, 480 }, .scale = 1 };
    view.fonts.set(.menu_large, &fixture.font);
    var host: Host = .{ .seconds = 0.04, .devices = &fixture.devices, .window = .{ 640, 480 } };
    host.views.set(.ui, view);
    fixture.shown.frame(host);
    try std.testing.expectEqualStrings("Drawing assets", fixture.shown.layers.get(.ui).text.items);
    try std.testing.expectEqual(1, fixture.shown.layers.get(.ui).commands.items.len);
}

test "menu scripts reload from their files, and start again" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "a", &.{
        .{ "mod.ini", "[Scripts]\nMenu=menu.luau\n" },
        .{ "menu.luau", "local frames = 0\nreturn { engine_handlers = { on_frame = function() frames += 1; require('openreliant.ui').text(vector.zero, 'old ' .. frames) end } }" },
    } }});
    defer fixture.deinit();
    const layer = fixture.shown.layers.getPtr(.ui);
    fixture.frame(0.016, .{ 800, 600 });
    fixture.frame(0.016, .{ 800, 600 });
    try std.testing.expectEqualStrings("old 2", layer.text.items);
    // The file saved again, the menu script starts again with the new code.
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mods/a/menu.luau", .data = "local frames = 0\nreturn { engine_handlers = { on_frame = function() frames += 1; require('openreliant.ui').text(vector.zero, 'new ' .. frames) end } }" });
    try fixture.shown.reload();
    fixture.frame(0.016, .{ 800, 600 });
    try std.testing.expectEqualStrings("new 1", layer.text.items);
}

test "player scripts run with the game, and send it events" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "a",
        &.{
            .{ "mod.ini", "[Scripts]\nGlobal=game.luau\nPlayer=player.luau\nMenu=menu.luau\n" },
            .{
                "game.luau",
                \\return { event_handlers = {
                \\    Throttle = function(data) data.ship.throttle = data.to end,
                \\} }
            },
            .{
                "player.luau",
                \\local core = require("openreliant.core")
                \\local nearby = require("openreliant.nearby")
                \\local sent = false
                \\return {
                \\    interface_name = "Pilot",
                \\    interface = { sent = function() return sent end },
                \\    engine_handlers = { on_frame = function()
                \\        if sent then return end
                \\        -- Its own object is the player's ship.
                \\        assert(require("openreliant.self").is_player)
                \\        -- A player script can't change the game itself, only send it events.
                \\        assert(not pcall(require, "openreliant.world"))
                \\        local ships = nearby.objects(1000)
                \\        assert(#ships == 1 and ships[1].type == "sabre")
                \\        assert(not pcall(function() ships[1].throttle = 0.5 end))
                \\        core.send_global_event("Throttle", { ship = ships[1], to = 0.5 })
                \\        sent = true
                \\    end },
                \\}
            },
            .{
                "menu.luau",
                \\local I = require("openreliant.interfaces")
                \\local ui = require("openreliant.ui")
                \\return { engine_handlers = { on_frame = function()
                \\    if I.Pilot and I.Pilot.sent() then ui.text(vector.create(0, 0, 0), "seen") end
                \\end } }
            },
        },
    }});
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const game = (try game_module.Game.start(gpa, std.testing.io, fixture.mods.list, &fixture.held, "0.7.0", fixture.mission.objects, .{}, false)).?;
    defer game.stop();
    const sabre = try fixture.mission.add(.sabre, .{ 0, 0, 500 });
    try std.testing.expectEqual(1, fixture.shown.lists.get(.menu).items.len);
    try fixture.shown.startGame(game, fixture.mission.objects, false);
    try std.testing.expectEqual(1, fixture.shown.lists.get(.player).items.len);
    // The player script's event reaches the global script at the game's next update, the Sabre's
    // handle with it.
    fixture.frame(0.016, .{ 800, 600 });
    game.scripts.update(0.1);
    try std.testing.expectEqual(0.5, fixture.mission.objects.slots[sabre].object.throttle);
    // The menu script sees the player script's interface.
    fixture.frame(0.016, .{ 800, 600 });
    try std.testing.expectEqualStrings("seen", fixture.shown.layers.get(.ui).text.items);
    // As the game ends, the player script stops, and so does its interface.
    fixture.shown.endGame();
    try std.testing.expectEqual(0, fixture.shown.lists.get(.player).items.len);
    fixture.frame(0.016, .{ 800, 600 });
    try std.testing.expectEqual(0, fixture.shown.layers.get(.ui).commands.items.len);
}

test "the bouncing DVD logo example drifts, bounces and changes colour" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "dvd", &.{
        .{ "mod.ini", @embedFile("dvd/mod.ini") },
        .{ "dvd.luau", @embedFile("dvd/dvd.luau") },
    } }});
    defer fixture.deinit();
    const layer = fixture.shown.layers.getPtr(.ui);
    fixture.frame(0.016, .{ 640, 480 });
    try std.testing.expectEqual(2, layer.commands.items.len);
    const first = layer.commands.items[0].text;
    // It drifts down and to the right, and after long enough it has bounced and changed colour.
    fixture.frame(0.5, .{ 640, 480 });
    const moved = layer.commands.items[0].text;
    try std.testing.expect(moved.at.screen[0] > first.at.screen[0] and moved.at.screen[1] > first.at.screen[1]);
    try std.testing.expectEqualDeep(first.colour, moved.colour);
    fixture.frame(3, .{ 640, 480 });
    const bounced = layer.commands.items[0].text;
    try std.testing.expect(!std.meta.eql(first.colour, bounced.colour));
    // While the menus aren't shown, it draws nothing.
    fixture.shown.frame(.{ .seconds = 0.016, .devices = &fixture.devices, .window = .{ 640, 480 } });
    try std.testing.expectEqual(0, layer.commands.items.len);
}

test "the wingmen example's panel lists the wingmen nearby, and calls them back" {
    const storage_module = @import("storage.zig");
    const settings_module = @import("settings.zig");
    const gpa = std.testing.allocator;
    var storage: storage_module.Storage = .{ .gpa = gpa };
    defer storage.deinit();
    var pages: settings_module.Registry = .init(gpa, &storage);
    defer pages.deinit();
    const shared: runtime.Shared = .{ .storage = &storage, .settings = &pages };
    var fixture: Fixture = undefined;
    try fixture.initShared(&.{.{ "wingmen", &.{
        .{ "mod.ini", @embedFile("wingmen/mod.ini") },
        .{ "options.luau", @embedFile("wingmen/options.luau") },
        .{ "wingman.luau", @embedFile("wingmen/wingman.luau") },
        .{ "wingmen.luau", @embedFile("wingmen/wingmen.luau") },
        .{ "status.luau", @embedFile("wingmen/status.luau") },
    } }}, shared);
    defer fixture.deinit();
    const game = (try game_module.Game.start(gpa, std.testing.io, fixture.mods.list, &fixture.held, "0.7.0", fixture.mission.objects, shared, false)).?;
    defer game.stop();
    game.scripts.begin(fixture.mission.orders(), .{ .number = 5, .file = "mission5.dte" }, 1);
    const wingman = try fixture.mission.add(.wolverine, .{ 0, 0, -1000 });
    fixture.mission.objects.slots[wingman].object.side = .friendly;
    try fixture.shown.startGame(game, fixture.mission.objects, false);
    // Over the flight display, the panel's title and the wingman's line.
    var host: Host = .{ .seconds = 0.016, .devices = &fixture.devices, .window = .{ 1024, 768 }, .flying = true };
    host.views.set(.hud, .{ .font = &fixture.font, .gpa = gpa, .screen = .{ 1024, 768 }, .scale = 1 });
    fixture.shown.frame(host);
    const layer = fixture.shown.layers.getPtr(.hud);
    try std.testing.expectEqual(2, layer.commands.items.len);
    try std.testing.expect(std.mem.endsWith(u8, layer.text.items, "1  97%"));
    // F9 hides it.
    fixture.shown.key(.f9, true);
    fixture.shown.frame(host);
    try std.testing.expectEqual(0, layer.commands.items.len);
    // With the wingman out of the fight, Shift+F9 calls it back to the formation at the game's
    // next update.
    const slot = &fixture.mission.objects.slots[wingman];
    slot.object.armor = .all(1);
    slot.object.last_attacker = .of(0);
    game.scripts.update(0.1);
    try std.testing.expectEqual(.run_away, slot.current().?.order);
    game.scripts.update(0.1);
    fixture.shown.key(.f9, false);
    fixture.devices.keyboard.down[@intFromEnum(input.Key.left_shift)] = true;
    fixture.shown.key(.f9, true);
    fixture.shown.frame(host);
    game.scripts.update(0.1);
    game.scripts.update(0.1);
    try std.testing.expectEqual(.formation, slot.current().?.order);
}

test "menu scripts are told of their own mod's options" {
    var fixture: Fixture = undefined;
    const handler =
        \\local ui = require("openreliant.ui")
        \\local heard = "nothing"
        \\return { engine_handlers = {
        \\    on_setting_changed = function(key, value) heard = key .. "=" .. tostring(value) end,
        \\    on_frame = function() ui.text(vector.create(0, 0, 0), heard) end,
        \\} }
    ;
    try fixture.init(&.{
        .{ "a", &.{ .{ "mod.ini", "[Scripts]\nMenu=menu.luau\n" }, .{ "menu.luau", handler } } },
        .{ "b", &.{ .{ "mod.ini", "[Scripts]\nMenu=menu.luau\n" }, .{ "menu.luau", handler } } },
    });
    defer fixture.deinit();
    fixture.shown.settingChanged("b", "flee", .{ .number = 0.35 });
    fixture.shown.settingChanged("b", "show", .{ .boolean = false });
    fixture.frame(0.016, .{ 800, 600 });
    // Mod a heard nothing, and mod b the last of its changes.
    try std.testing.expectEqualStrings("nothingshow=false", fixture.shown.layers.getPtr(.ui).text.items);
}

test "player scripts register post effects, which draw in order and end with their scripts" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{
        "retro",
        &.{
            .{ "mod.ini", "[Scripts]\nPlayer=effects.luau, failing.luau\n" },
            .{ "a.frag", "void main() {}" },
            .{ "broken.frag", "broken" },
            .{
                "effects.luau",
                \\local post = require("openreliant.postprocessing")
                \\assert(post.register({ name = "late", shader = "a.frag", stage = "after_hud" }) == "retro:late")
                \\post.register({ name = "second", shader = "a.frag", order = 5, parameters = { 1, 2 } })
                \\post.register({ name = "first", shader = "a.frag", order = -1 })
                \\post.register({ name = "off", shader = "a.frag", enabled = false })
                \\local ok, message = pcall(post.register, { name = "late", shader = "a.frag" })
                \\assert(not ok and string.find(message, "registered already", 1, true), message)
                \\ok, message = pcall(post.register, { name = "bad", shader = "broken.frag" })
                \\assert(not ok and string.find(message, "broken.frag:2", 1, true), message)
                \\ok, message = pcall(post.register, { name = "gone", shader = "missing.frag" })
                \\assert(not ok and string.find(message, "no file missing.frag", 1, true), message)
                \\ok, message = pcall(post.register, { name = "no good", shader = "a.frag" })
                \\assert(not ok and string.find(message, "identifier", 1, true), message)
                \\assert(post.set_parameters("retro:first", { 0.5 }) and post.set_enabled("off", true))
                \\assert(not post.set_enabled("nothing", true))
            },
            .{
                "failing.luau",
                \\require("openreliant.postprocessing").register({ name = "rolled_back", shader = "a.frag" })
                \\error("this script fails to load")
            },
        },
    }});
    defer fixture.deinit();
    var host: postprocessing.testing.Host = .{};
    defer host.deinit();
    fixture.shown.setEffectHost(host.effectHost());
    try fixture.shown.startGame(null, fixture.mission.objects, false);
    // The failing script's effect was taken back as it failed to load.
    try std.testing.expectEqual(5, host.added);
    try std.testing.expectEqualSlices(u32, &.{4}, host.removed.items);
    // Before the display by order (first, then off, which was turned on, then second), then after
    // it.
    var buffer: [postprocessing.max_effects]postprocessing.Pass = undefined;
    const passes = fixture.shown.effectPasses(&buffer);
    try std.testing.expectEqual(4, passes.len);
    const expected = [_]struct { u32, postprocessing.Stage }{ .{ 2, .before_hud }, .{ 3, .before_hud }, .{ 1, .before_hud }, .{ 0, .after_hud } };
    for (expected, passes) |want, pass| {
        try std.testing.expectEqual(want[0], pass.effect);
        try std.testing.expectEqual(want[1], pass.stage);
    }
    try std.testing.expectEqual([4]f32{ 0.5, 0, 0, 0 }, passes[0].parameters);
    try std.testing.expectEqual([4]f32{ 1, 2, 0, 0 }, passes[2].parameters);
    // The game's end stops the player scripts, and their effects go.
    fixture.shown.endGame();
    try std.testing.expectEqual(0, fixture.shown.effectPasses(&buffer).len);
    try std.testing.expectEqual(5, host.removed.items.len);
}

test "without a host, as with the software device, effects register and draw nothing" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "retro", &.{
        .{ "mod.ini", "[Scripts]\nPlayer=effects.luau\n" },
        .{ "a.frag", "void main() {}" },
        .{ "effects.luau", "assert(require('openreliant.postprocessing').register({ name = 'crt', shader = 'a.frag' }) == 'retro:crt')" },
    } }});
    defer fixture.deinit();
    try fixture.shown.startGame(null, fixture.mission.objects, false);
    var buffer: [postprocessing.max_effects]postprocessing.Pass = undefined;
    try std.testing.expectEqual(0, fixture.shown.effectPasses(&buffer).len);
}

test "the CRT example registers its effect, and Shift F8 and Shift F7 change it" {
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "crt", &.{
        .{ "mod.ini", @embedFile("crt/mod.ini") },
        .{ "crt.luau", @embedFile("crt/crt.luau") },
        .{ "crt.frag", @embedFile("crt/crt.frag") },
    } }});
    defer fixture.deinit();
    var host: postprocessing.testing.Host = .{};
    defer host.deinit();
    fixture.shown.setEffectHost(host.effectHost());
    try fixture.shown.startGame(null, fixture.mission.objects, false);
    fixture.frame(0.016, .{ 800, 600 });
    var buffer: [postprocessing.max_effects]postprocessing.Pass = undefined;
    var passes = fixture.shown.effectPasses(&buffer);
    try std.testing.expectEqual(1, passes.len);
    try std.testing.expectEqual(.after_hud, passes[0].stage);
    try std.testing.expectEqual(0.3, passes[0].parameters[0]);
    // Shift F7 steps the scanlines on; Shift F8 turns the effect off.
    fixture.devices.keyboard.down[@intFromEnum(input.Key.left_shift)] = true;
    fixture.shown.key(.f7, true);
    passes = fixture.shown.effectPasses(&buffer);
    try std.testing.expectEqual(0.5, passes[0].parameters[0]);
    fixture.shown.key(.f8, true);
    try std.testing.expectEqual(0, fixture.shown.effectPasses(&buffer).len);
}
