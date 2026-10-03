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
        shown.runtime.destroy();
        shown.gpa.destroy(shown);
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
        shown.runner.callAll(.on_mission_end, .{ .outcome = outcome });
    }

    /// Tells the scripts that `key` went down or up. A key held down that the window repeats is
    /// told once.
    pub fn key(shown: *Presentation, pressed: input.Key, down: bool) void {
        const code = @intFromEnum(pressed);
        if (shown.keys.isSet(code) == down) return;
        shown.keys.setValue(code, down);
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
                if (!shown.actions.contains(action)) shown.runner.callAll(.on_action, .{ .action = action });
            }
        }
        shown.actions = held;
        shown.runner.advance(host.seconds);
        shown.runner.callAll(.on_frame, .{ .seconds = host.seconds });
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
        fixture.shown = (try Presentation.start(gpa, io, fixture.mods.list, &fixture.held, "0.7.0", .{})).?;
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
    var fixture: Fixture = undefined;
    try fixture.init(&.{.{ "wingmen", &.{
        .{ "mod.ini", @embedFile("wingmen/mod.ini") },
        .{ "wingman.luau", @embedFile("wingmen/wingman.luau") },
        .{ "wingmen.luau", @embedFile("wingmen/wingmen.luau") },
        .{ "status.luau", @embedFile("wingmen/status.luau") },
    } }});
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const game = (try game_module.Game.start(gpa, std.testing.io, fixture.mods.list, &fixture.held, "0.7.0", fixture.mission.objects, .{}, false)).?;
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
    // With the wingman out of the fight, F11 calls it back to the formation at the game's next
    // update.
    const slot = &fixture.mission.objects.slots[wingman];
    slot.object.armor = .all(1);
    slot.object.last_attacker = .of(0);
    game.scripts.update(0.1);
    try std.testing.expectEqual(.run_away, slot.current().?.order);
    game.scripts.update(0.1);
    fixture.shown.key(.f11, true);
    fixture.shown.frame(host);
    game.scripts.update(0.1);
    game.scripts.update(0.1);
    try std.testing.expectEqual(.formation, slot.current().?.order);
}
