//! Load scripts ([#498](https://github.com/OpenReliant/openreliant/issues/498)) run once at
//! startup, before the main menu, and change the records the game reads (`records.Records`). Mods
//! run in load order, and each mod's scripts in the order its manifest lists them under `Load`.
//! After all of them, each script's `on_records_loaded` handler runs, in the same order. If a
//! script or handler fails, the error is logged and its changes are undone. If no mod has a load
//! script, no Luau state is created.
//!
//! A game mode's records script (`game_modes.Mode.records`) is a load script too, which runs on its
//! own before each of the mode's missions (`runOne`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.scripts);

const openreliant = @import("openreliant");
const mods = openreliant.engine.game.bigfile.mods;
const Mod = mods.Mod;
const luau = @import("luau.zig");
const script = @import("script.zig");
const runtime = @import("runtime.zig");
const records = @import("records.zig");
const packages = @import("packages.zig");

/// Limits for load scripts: 1 second per call and 64 MiB per mod. Changing records needs far less,
/// so only a broken script hits them.
pub const limits: runtime.Limits = .{ .time = .fromSeconds(1), .memory = 64 << 20 };

/// The seed for `math.random` in load scripts. It's fixed so that the records come out the same on
/// every machine.
pub const seed = 0x4F70_656E_5265_6C69;

/// Runs the load scripts of `opened` on `held`. `version` is OpenReliant's version, which scripts
/// can read.
pub fn run(gpa: Allocator, io: Io, opened: []const Mod, held: *records.Records, version: []const u8, shared: runtime.Shared) Allocator.Error!void {
    return runWithin(gpa, io, opened, held, version, limits, shared);
}

fn runWithin(gpa: Allocator, io: Io, opened: []const Mod, held: *records.Records, version: []const u8, within: runtime.Limits, shared: runtime.Shared) Allocator.Error!void {
    for (opened) |*mod| tellUnknown(mod);
    const any = for (opened) |*mod| {
        var listed = loadScripts(mod);
        if (listed.next() != null) break true;
    } else false;
    if (!any) return;

    const scripts = try start(gpa, io, opened, held, version, within, shared);
    defer scripts.destroy();

    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(gpa);
    for (opened, 0..) |*mod, at| {
        var listed = loadScripts(mod);
        if (listed.next() == null) continue;
        listed = loadScripts(mod);
        const context = try scripts.open(@intCast(at), .load, null);
        while (listed.next()) |name| {
            const offered = try runScript(gpa, scripts, context, name, held) orelse continue;
            if (offered.handlers.get(.on_records_loaded)) |handler| try pending.append(gpa, .{ .context = context, .handler = handler });
        }
    }
    for (pending.items) |entry| {
        const saved = try held.snapshot(gpa);
        defer saved.deinit(gpa);
        if (scripts.call(entry.context, entry.handler, .{}) == .failed) saved.restore(held);
    }
}

/// Runs one load script, `name` of the mod at `mod` in `opened`, on `held`, as a game mode's
/// records script runs before each of its missions (`game_modes.Mode.records`). Its
/// `on_records_loaded` handler doesn't run: that is for the load scripts as OpenReliant starts. If
/// it fails, the error is logged and its changes are undone.
pub fn runOne(gpa: Allocator, io: Io, opened: []const Mod, mod: u16, name: []const u8, held: *records.Records, version: []const u8, shared: runtime.Shared) Allocator.Error!void {
    const scripts = try start(gpa, io, opened, held, version, limits, shared);
    defer scripts.destroy();
    const context = try scripts.open(mod, .load, null);
    _ = try runScript(gpa, scripts, context, name, held);
}

/// A Luau state for load scripts, which can change `held`.
fn start(gpa: Allocator, io: Io, opened: []const Mod, held: *records.Records, version: []const u8, within: runtime.Limits, shared: runtime.Shared) Allocator.Error!*runtime.Runtime {
    const scripts = try runtime.Runtime.create(gpa, io, opened, .{ .side = .game, .limits = within, .seed = seed, .version = version, .shared = shared });
    records.register(scripts.state);
    records.push(scripts.state, held, true);
    scripts.setPackage(.records);
    packages.push(scripts);
    return scripts;
}

/// Runs the load script `name` in `context`, and returns what it offers; null where it fails,
/// after its changes to `held` are undone.
fn runScript(gpa: Allocator, scripts: *runtime.Runtime, context: *runtime.Context, name: []const u8, held: *records.Records) Allocator.Error!?runtime.Offered {
    const saved = try held.snapshot(gpa);
    defer saved.deinit(gpa);
    const returned = scripts.run(context, name) orelse {
        saved.restore(held);
        return null;
    };
    defer scripts.release(returned);
    const offered = context.offerOf(name, returned) orelse {
        saved.restore(held);
        return null;
    };
    log.info("{s}: ran {s}", .{ context.modOf().name, name });
    return offered;
}

/// An `on_records_loaded` handler, which runs after all load scripts.
const Pending = struct {
    context: *runtime.Context,
    handler: luau.Ref,
};

/// The load scripts listed in `mod`'s manifest, in order.
fn loadScripts(mod: *const Mod) script.List {
    return .of(mod.manifest.value(script.section, script.Kind.load.key()) orelse "");
}

/// Logs the unknown keys in `mod`'s `[Scripts]`.
fn tellUnknown(mod: *const Mod) void {
    var keys = mod.manifest.keys(script.section);
    while (keys.next()) |key| {
        if (script.Attachment.parse(key, mod.name) == null) log.warn("{s}: unknown script kind '{s}' in [{s}]", .{ mod.name, key, script.section });
    }
}

pub const testing = struct {
    /// Creates a game folder in `dir` with the mods `made`, each a folder of files.
    pub fn makeMods(io: Io, dir: Io.Dir, made: []const struct { []const u8, []const struct { []const u8, []const u8 } }) !void {
        for (made) |mod| {
            for (mod[1]) |file| {
                var path_buffer: [128]u8 = undefined;
                const folder = try std.mem.print(&path_buffer, "mods/{s}", .{mod[0]});
                try dir.createDirPath(io, folder);
                var file_buffer: [128]u8 = undefined;
                const path = try std.mem.print(&file_buffer, "mods/{s}/{s}", .{ mod[0], file[0] });
                try dir.writeFile(io, .{ .sub_path = path, .data = file[1] });
            }
        }
    }

    /// Records with three guns, the first being the Laser Cannon, and one string.
    pub fn records3(arena: Allocator) !records.Records {
        var guns: [3]openreliant.stats.Gun = @splat(std.mem.zeroes(openreliant.stats.Gun));
        for (&guns, 0..) |*gun, at| gun.range = @floatFromInt(at + 1);
        return .init(arena, .{ .ships = &.{}, .ship_types = &.{}, .guns = &guns, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{"Laser Cannon"}, .itac_text = &.{} });
    }
};

test "load scripts run in load order, and their handlers run after all of them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.makeMods(io, tmp.dir, &.{
        .{
            "a",
            &.{
                .{ "mod.ini", "[Scripts]\nLoad=first.luau\n" },
                .{
                    "first.luau",
                    \\local records = require("openreliant.records")
                    \\records.guns.laser_cannon.range = 5
                    \\return { engine_handlers = { on_records_loaded = function()
                    \\    records.guns[1].speed = records.guns[1].range
                    \\end } }
                },
            },
        },
        .{
            "b",
            &.{
                .{ "mod.ini", "[Scripts]\nLoad = second.luau, Third.LUAU\n" },
                .{
                    "second.luau",
                    \\local records = require("openreliant.records")
                    \\records.guns[1].range *= 2
                    \\records.guns[1].shot_energy = require("util").value
                    \\assert(require("Util") == require("util.luau"))
                },
                .{ "util.luau", "return { value = 3 }" },
                .{
                    "Third.LUAU",
                    \\local core = require("openreliant.core")
                    \\require("openreliant.records").text[1] = "Version " .. core.version
                },
            },
        },
    });
    var mods_held: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods_held.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try testing.records3(arena.allocator());
    try run(gpa, io, mods_held.list, &held, "0.7.0", .{});

    // The first mod sets the range to 5, the second doubles it, and the handler runs after both.
    try std.testing.expectEqual(10, held.guns[0].range);
    try std.testing.expectEqual(10, held.guns[0].speed);
    try std.testing.expectEqual(3, held.guns[0].shot_energy);
    try std.testing.expectEqualStrings("Version 0.7.0", held.text[0]);
}

test "a failed script's changes are undone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.makeMods(io, tmp.dir, &.{
        .{ "broken", &.{
            .{ "mod.ini", "[Scripts]\nLoad=raises.luau, syntax.luau, offers.luau, missing.luau, loops.luau, hungry.luau, last.luau\n" },
            .{ "raises.luau", "require('openreliant.records').guns[1].range = 99\nerror('broken')" },
            .{ "syntax.luau", "local = 1" },
            .{ "offers.luau", "require('openreliant.records').guns[1].range = 98\nreturn { engine_handlers = { on_update = function() end } }" },
            .{ "loops.luau", "require('openreliant.records').guns[1].range = 97\nwhile true do end" },
            .{ "hungry.luau", "local t = {}\nfor i = 1, 1e8 do t[i] = tostring(i) end" },
            .{ "last.luau", "require('openreliant.records').guns[2].range = 42" },
        } },
    });
    var mods_held: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods_held.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try testing.records3(arena.allocator());
    try runWithin(gpa, io, mods_held.list, &held, "0.7.0", .{ .time = .fromMilliseconds(50), .memory = 1 << 20 }, .{});

    // Every script failed, including the one that timed out and the one that ran out of memory, and
    // the last one still ran.
    try std.testing.expectEqual(1, held.guns[0].range);
    try std.testing.expectEqual(42, held.guns[1].range);
}

test "load scripts can only require the packages available to them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.makeMods(io, tmp.dir, &.{
        .{
            "reach",
            &.{
                .{ "mod.ini", "[Scripts]\nLoad=reach.luau\n" },
                .{
                    "reach.luau",
                    \\local function fails(name, message)
                    \\    local ok, err = pcall(require, name)
                    \\    assert(not ok and string.find(err, message, 1, true), err)
                    \\end
                    \\fails("openreliant.shaders", "is not available to load scripts")
                    \\fails("openreliant.hooks", "is not available to load scripts")
                    \\fails("openreliant.world", "is not available to load scripts")
                    \\fails("openreliant.nothing", "unknown package")
                    \\fails("missing", "has no script missing.luau")
                    \\assert(os == nil and math.randomseed == nil)
                    \\local n = math.random(1, 1000)
                    \\assert(n >= 1 and n <= 1000)
                    \\require("openreliant.records").guns[1].range = n
                },
            },
        },
    });
    var mods_held: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods_held.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var first = try testing.records3(arena.allocator());
    try run(gpa, io, mods_held.list, &first, "0.7.0", .{});
    var second = try testing.records3(arena.allocator());
    try run(gpa, io, mods_held.list, &second, "0.7.0", .{});
    // The script ran to the end, and got the same random number both times.
    try std.testing.expect(first.guns[0].range != 1);
    try std.testing.expectEqual(first.guns[0].range, second.guns[0].range);
}

test "no Luau state is created without load scripts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.makeMods(io, tmp.dir, &.{
        .{ "plain", &.{.{ "mod.ini", "[Mod]\nName=Plain\n[Scripts]\nGlobal=later.luau\n" }} },
    });
    var mods_held: mods.Mods = try .open(std.testing.allocator, io, tmp.dir, null);
    defer mods_held.close(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var held = try testing.records3(arena.allocator());
    // Nothing is allocated, so no state was created.
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try run(failing.allocator(), io, mods_held.list, &held, "0.7.0", .{});
}

test "the interceptor example adds a ship type, and its load script changes its record" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const game = openreliant.engine.game;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.makeMods(io, tmp.dir, &.{.{ "interceptor", &.{
        .{ "mod.ini", @embedFile("interceptor/mod.ini") },
        .{ "records.luau", @embedFile("interceptor/records.luau") },
        .{ "menu.luau", @embedFile("interceptor/menu.luau") },
    } }});
    var opened: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try game.additions.read(arena.allocator(), opened.list);
    defer game.additions.reset();
    const added = game.additions.ships.all();
    try std.testing.expectEqual(1, added.len);
    try std.testing.expectEqualStrings("interceptor:interceptor", added[0].name);
    try std.testing.expectEqual(game.gameobj.GameType.predator, added[0].base);
    // Scripts know the type by its qualified name, which stands for its number.
    const interceptor = game.gameobj.Type.fromScriptName("interceptor:interceptor").?;
    try std.testing.expectEqual(game.additions.ships.first, interceptor.number());
    try std.testing.expectEqual(game.gameobj.GameType.predator, interceptor.base());

    var game_ships: [1]openreliant.stats.Ship = .{std.mem.zeroes(openreliant.stats.Ship)};
    game_ships[0].max_speed = 100;
    game_ships[0].shield_power = 10;
    var held: records.Records = try .init(arena.allocator(), .{
        .ships = try game.additions.ships.records(openreliant.stats.Ship, arena.allocator(), &game_ships, 0),
        .ship_types = &.{},
        .guns = &.{},
        .missiles = &.{},
        .pilots = &.{},
        .faces = &.{},
        .text = &.{},
        .itac_text = &.{},
    });
    try run(gpa, io, opened.list, &held, "0.7.0", .{});
    // The Predator stays as it was, and the Interceptor is faster with lighter shields.
    try std.testing.expectEqual(100, held.ships[0].max_speed);
    try std.testing.expectApproxEqAbs(130, held.ships[game.additions.ships.first].max_speed, 1e-3);
    try std.testing.expectApproxEqAbs(6, held.ships[game.additions.ships.first].shield_power, 1e-3);
}

test "the bananas example adds a gun, a missile, a pilot and a ship that names them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const game = openreliant.engine.game;
    const stats = openreliant.stats;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.makeMods(io, tmp.dir, &.{.{ "bananas", &.{
        .{ "mod.ini", @embedFile("bananas/mod.ini") },
        .{ "records.luau", @embedFile("bananas/records.luau") },
        .{ "menu.luau", @embedFile("bananas/menu.luau") },
        .{ "troopers.luau", @embedFile("bananas/troopers.luau") },
        .{ "banana_shot.png", @embedFile("bananas/banana_shot.png") },
        .{ "boing.wav", @embedFile("bananas/boing.wav") },
    } }});
    var opened: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try game.additions.read(arena.allocator(), opened.list);
    defer game.additions.reset();
    const boat = game.additions.ships.all()[0];
    try std.testing.expectEqualStrings("bananas:banana_boat", boat.name);
    try std.testing.expectEqualStrings("bananas:banana_gun", boat.extra.gun.?.scriptName().?);
    try std.testing.expectEqualStrings("bananas:banana", boat.extra.missile.?.scriptName().?);
    try std.testing.expectEqual(game.guns.GameGun.pulse_cannon, boat.extra.gun.?.base());
    // The gun's shot is the example's picture, and its sound the example's WAV file.
    const gun = boat.extra.gun.?.added().?.extra;
    try std.testing.expectEqualStrings("banana_shot", gun.shot.?);
    try std.testing.expectEqualSlices(u8, @embedFile("bananas/boing.wav"), gun.sound.?);
    try std.testing.expectEqual(game.missiles.GameMissile.bandit, boat.extra.missile.?.base());
    try std.testing.expectEqual(21, game.additions.pilots.all()[0].base);

    var guns: [15]stats.Gun = @splat(std.mem.zeroes(stats.Gun));
    guns[1].speed = 1000;
    var missiles: [11]stats.Missile = @splat(std.mem.zeroes(stats.Missile));
    missiles[@backingInt(game.missiles.GameMissile.bandit)].lock_time = 300;
    var held: records.Records = try .init(arena.allocator(), .{
        .ships = try game.additions.ships.records(stats.Ship, arena.allocator(), &.{}, 0),
        .ship_types = &.{},
        .guns = try game.additions.guns.records(stats.Gun, arena.allocator(), &guns, 1),
        .missiles = try game.additions.missiles.records(stats.Missile, arena.allocator(), &missiles, 0),
        .pilots = try game.additions.pilots.records(stats.Pilot, arena.allocator(), &.{}, 0),
        .faces = &.{},
        .text = &.{},
        .itac_text = &.{},
    });
    try run(gpa, io, opened.list, &held, "0.7.0", .{});
    // The Banana Gun is a faster Pulse Cannon, the Banana a quicker Bandit, and the Trooper a
    // beginner who fires at anything near the nose.
    try std.testing.expectApproxEqAbs(1500, held.guns[game.additions.guns.first - 1].speed, 1e-3);
    try std.testing.expectEqual(1000, held.guns[1].speed);
    try std.testing.expectEqual(150, held.missiles[game.additions.missiles.first].lock_time);
    const trooper = held.pilots[game.additions.pilots.first];
    try std.testing.expectEqual(stats.Pilot.Tier.level_0, trooper.tier_b);
    try std.testing.expectEqual(stats.Pilot.Skill.low, trooper.skill);
}
