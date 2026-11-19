//! Game data for a stock arena. Both host entry points use the same mission loader and models.
const std = @import("std");
const openreliant = @import("openreliant");
const engine = openreliant.engine;
const game = engine.game;
const Scenario = game.dmscenarios.Scenario;
const textures = engine.surrender.surrenderlib.srtexture;
const stats = openreliant.stats;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Files = struct {
    io: Io,
    directory: Io.Dir,
    archive: *const game.bigfile.Hog,

    /// Bind and run the mission's start part. On a viewer this only constructs the scenery.
    /// The host supplies the arena damage rules, participant bindings and simulation clock.
    pub fn load(files: Files, gpa: Allocator, scenario: Scenario, world: game.gameobj.World) !*game.mission.Loaded {
        const number = scenario.mission();
        var path_buffer: [game.winmain.mission_path_size]u8 = undefined;
        const path = game.winmain.missionPath(&path_buffer, number, false, true);
        const mission = (try game.mission.bind.read(files.io, gpa, files.directory, files.archive, path)) orelse return error.MissingArenaMission;
        const loaded = try game.mission.Loaded.create(gpa, mission.image, world.random);
        errdefer loaded.destroy();
        const all = world.objects;
        all.mission_number = number;
        all.players = game.deathmatch.spawn.positions;
        all.count = @intCast(@min(loaded.bound.shipCount(), all.slots.len));
        if (all.count < all.players) return error.MissingArenaPlayerSlots;
        loaded.script.variables = game.gameflow.restartPoint();
        loaded.script.variables.players = all.players;
        const orders: game.aigeneric.Context = .of(withMission(world, loaded));
        try loaded.start(orders);
        // The script creates eight placeholder ships. OpenReliant only puts ships in the round
        // for admitted pilots and the viewer receives those ships from the host.
        for (0..all.players) |slot| game.create.resetSlot(orders, @intCast(slot));
        return loaded;
    }
};

pub fn withMission(original: game.gameobj.World, loaded: *game.mission.Loaded) game.gameobj.World {
    var world = original;
    world.mission = &loaded.bound;
    world.events = &loaded.events;
    world.variables = &loaded.script.variables;
    return world;
}

/// The stock host loads the same flight tables and models with CPU resources. It has no window,
/// graphics device or sound device. The player host uses this path too.
pub const Assets = struct {
    heap: std.heap.ArenaAllocator,
    files: Files,
    archive: game.bigfile.Hog,
    images: textures.Table,
    library: game.create.library.TypeCache,

    pub fn open(gpa: Allocator, io: Io, directory: Io.Dir, tables: *game.create.Stats, all: *game.create.Objects) !*Assets {
        const assets = try gpa.create(Assets);
        errdefer gpa.destroy(assets);
        assets.heap = .init(gpa);
        errdefer assets.heap.deinit();
        const memory = assets.heap.allocator();
        assets.archive = try .open(memory, io, directory, game.bigfile.resource_name);
        errdefer assets.archive.close(memory);
        assets.files = .{ .io = io, .directory = directory, .archive = &assets.archive };
        const cache = try openreliant.tcache.Cache.parse(memory, try read(memory, io, directory, openreliant.tcache.hardware_name));
        const palette = try openreliant.tga.palette(try assets.archive.readFile(memory, "palette.tga"));
        assets.images = .init(gpa, cache, palette);
        errdefer assets.images.deinit();
        assets.library = .{ .gpa = gpa, .resources = &assets.archive, .textures = &assets.images, .looks = .{}, .global_palette = null };
        tables.* = .initial;
        tables.load(try records(memory, io, directory, .ships));
        all.gun_stats.load(try records(memory, io, directory, .guns));
        all.missile_stats.load(try records(memory, io, directory, .missiles));
        all.pilots.load(try records(memory, io, directory, .pilots));
        // Cache the supported fighters before the listener opens, so admission does not block
        // an active match on the first use of a model.
        const types = assets.library.types();
        for (std.enums.values(game.dmscenarios.Fighter)) |ship| _ = types.load(types.context, @intCast(ship.kind().number()));
        return assets;
    }

    pub fn close(assets: *Assets, gpa: Allocator) void {
        assets.library.deinit();
        assets.images.deinit();
        assets.archive.close(assets.heap.allocator());
        assets.heap.deinit();
        gpa.destroy(assets);
    }
};

fn read(gpa: Allocator, io: Io, directory: Io.Dir, name: []const u8) ![]u8 {
    return try engine.files.readFile(io, gpa, directory, name, .limited(engine.files.max_file_size)) orelse error.FileNotFound;
}

fn records(gpa: Allocator, io: Io, directory: Io.Dir, comptime table: stats.Table) ![]align(1) const stats.Table.Record(table) {
    const file = try stats.File.parse(table, try read(gpa, io, directory, table.fileName()));
    return @field(file, @tagName(table));
}
