//! `openreliant --mission <number> --twin`: the twin check. Beside the mission, a second copy of it
//! runs with nothing drawn or heard: a world with every optional part left out but the mission's
//! records and what it makes ships from, its own objects, player, clock and random numbers, started
//! the same way from the same seed. After each pass of the main loop the twin runs the ticks the
//! game ran, and the two are compared field by field (`engine.compare`). At the first difference
//! it writes the tick and the fields that differ, and the run ends. So it finds what of the game
//! still depends on what the player sees and hears
//! ([#947](https://github.com/OpenReliant/openreliant/issues/947)).
//!
//! It compares the random numbers, the clocks, the player, the objects with their models' parts,
//! and the mission's script. Mods' scripts would run on the game's side alone, so the twin needs a
//! game without them (`--no-mods`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const engine = openreliant.engine;
const game = engine.game;
const Differences = engine.compare.Differences;

/// The fields left out, each named by its type and its own name: what only the presentation sets,
/// and only the presentation reads.
const presentation_fields = [_][]const u8{
    // The 3D sound an object plays, which the sound hands out (`sound3d`).
    "GameObject.sound_voice",
    // Whether an object is drawn, which the camera clears or sets for the player's ship as the view
    // goes into its cockpit or out (`main.viewFrame`); only drawing and the sound read it.
    "GameObject.Flags.hidden",
    // The world a record keeps to act on, the mission's script's among them, which points at each
    // side's own parts.
    ".world",
};

/// The most differences written out; the rest are counted.
const shown_most = 40;

pub const Twin = struct {
    gpa: Allocator,
    objects: *game.create.Objects,
    types: game.create.library.TypeCache,
    player: engine.input.Player = .{},
    clock: game.main.Clock = .{},
    random: engine.random.Random = .{},
    shake: f32 = 0,
    devices: engine.input.Devices = .{},
    cockpit: game.main.cockpit.Cockpit,
    display: game.hud.State = .{},
    world: game.gameobj.World,
    loaded: ?*game.mission.Loaded = null,
    /// The game's mission, which the twin follows until it ends or starts again.
    following: ?*const game.mission.Loaded = null,
    /// The ticks compared alike so far, and whether the check found a difference.
    ticks: i32 = 0,
    failed: bool = false,

    /// A twin of the game's world `world`, before its mission starts, with the records the driver
    /// loaded into the game's objects and the types the game's cache `types` loads.
    pub fn create(gpa: Allocator, world: game.gameobj.World, types: *const game.create.library.TypeCache) !*Twin {
        const full = world.objects;
        if (full.scripts != null) {
            std.log.err("twin: the twin runs the mission without mods' scripts, so it needs a game without them; add --no-mods", .{});
            return error.TwinCheckFailed;
        }
        const twin = try gpa.create(Twin);
        errdefer gpa.destroy(twin);
        twin.* = .{
            .gpa = gpa,
            .objects = undefined,
            .types = types.emptyCopy(),
            .cockpit = .init(gpa),
            .world = undefined,
        };
        twin.objects = try .create(gpa, &twin.random);
        // A mission's start resets the objects before it seeds the random numbers, so the twin
        // starts from the game's numbers as they stand.
        twin.random = world.random.*;
        // What the driver loads into the objects before a mission (`mode_records.loadTables`), and
        // what the front end chose for it.
        const objects = twin.objects;
        objects.gun_stats = full.gun_stats;
        objects.missile_stats = full.missile_stats;
        objects.pilots = full.pilots;
        objects.faces = full.faces;
        objects.wingmen = full.wingmen;
        objects.simulator = full.simulator;
        objects.campaign_tier = full.campaign_tier;
        objects.players = full.players;
        objects.loadout_ships = full.loadout_ships;
        objects.loadout_racks = full.loadout_racks;
        objects.bullets.looks = full.bullets.looks;
        objects.bullets.shot_lights = full.bullets.shot_lights;
        twin.world = bare(world);
        twin.world.objects = objects;
        twin.world.player = &twin.player;
        twin.world.clock = &twin.clock;
        twin.world.random = &twin.random;
        twin.world.shake = &twin.shake;
        if (world.spawn) |spawn| twin.world.spawn = .{ .tables = spawn.tables, .types = twin.types.types() };
        return twin;
    }

    pub fn destroy(twin: *Twin) void {
        if (twin.following != null and !twin.failed) std.log.info("twin: the twins were alike for {d} ticks", .{twin.ticks});
        if (twin.loaded) |loaded| loaded.destroy();
        twin.objects.destroy();
        twin.cockpit.deinit();
        twin.types.deinit();
        twin.gpa.destroy(twin);
    }

    /// The world `world` with every optional part left out, but the mission's records and what it
    /// makes ships from.
    fn bare(world: game.gameobj.World) game.gameobj.World {
        var left = world;
        inline for (@typeInfo(game.gameobj.World).@"struct".field_names, @typeInfo(game.gameobj.World).@"struct".field_types) |name, Field| {
            const kept = comptime for ([_][]const u8{ "spawn", "mission", "events", "variables" }) |game_part| {
                if (std.mem.eql(u8, name, game_part)) break true;
            } else false;
            if (@typeInfo(Field) == .optional and !kept) @field(left, name) = null;
        }
        return left;
    }

    /// Starts the twin's mission as the game's started, by `start` with the twin's own parts in
    /// place of the game's, from the mission file `image`, made in the twin's allocator, as mission
    /// `number`; then takes the game's clock as it stands, and follows the game's mission
    /// `following`.
    pub fn start(twin: *Twin, game_start: game.main.Start, image: []u8, number: u16, clock: *const game.main.Clock, following: *const game.mission.Loaded) !void {
        var start_with = game_start;
        start_with.orders = .{ .world = twin.world, .devices = &twin.devices };
        start_with.clock = &twin.clock;
        start_with.types = &twin.types;
        start_with.cockpit = &twin.cockpit;
        start_with.display = &twin.display;
        start_with.profile = null;
        start_with.editor = null;
        const loaded = try game.main.startMission(twin.gpa, start_with, image, number);
        twin.loaded = loaded;
        twin.world.mission = &loaded.bound;
        twin.world.events = &loaded.events;
        twin.world.variables = &loaded.script.variables;
        twin.clock = clock.*;
        twin.following = following;
    }

    /// The game's side of a pass, as it stands once the frame is drawn.
    pub const Game = struct {
        world: game.gameobj.World,
        clock: *const game.main.Clock,
        loaded: ?*const game.mission.Loaded,
        riders: game.objects.Riders,
    };

    /// After a pass of the main loop: the twin runs the ticks the game ran, and the two are
    /// compared. At the first difference it writes them out and fails. Once the game's mission
    /// ends or starts again, the twin stops, and says how long the two stayed alike.
    pub fn pass(twin: *Twin, full: Game) error{TwinCheckFailed}!void {
        const following = twin.following orelse return;
        if (full.loaded != following) {
            std.log.info("twin: the mission ended after {d} ticks, with the twins alike throughout", .{twin.ticks});
            twin.following = null;
            return;
        }
        // The timer's ticks the game had, and its pause.
        twin.clock.timer_ticks = full.clock.timer_ticks;
        twin.clock.game_ticks = full.clock.game_ticks;
        twin.clock.play = full.clock.play;
        twin.clock.paused = full.clock.paused;
        _ = game.main.gameFrames(&twin.clock, &twin.devices, twin.world, full.riders, twin.loaded);

        var report: std.Io.Writer.Allocating = .init(twin.gpa);
        defer report.deinit();
        var diffs: Differences = .{ .writer = &report.writer, .most = shown_most, .skip = &presentation_fields };
        twin.compare(&diffs, full);
        if (diffs.found == 0) {
            twin.ticks = full.clock.mission_ticks;
            return;
        }
        std.log.err("twin: mission {d} differs at tick {d}, in {d} fields:\n{s}{s}", .{
            full.world.objects.mission_number,
            full.clock.mission_ticks,
            diffs.found,
            report.written(),
            if (diffs.found > diffs.most) "  ...\n" else "",
        });
        twin.failed = true;
        return error.TwinCheckFailed;
    }

    fn compare(twin: *Twin, diffs: *Differences, full: Game) void {
        diffs.compare("random", full.world.random, &twin.random);
        const clocks = .{ "mission_ticks", "frame_start", "frame_duration", "simulation_counter", "simulation_turn", "paused_ticks" };
        inline for (clocks) |name| diffs.compare("clock." ++ name, &@field(full.clock.*, name), &@field(twin.clock, name));
        diffs.compare("player", full.world.player, &twin.player);
        diffs.compare("objects", full.world.objects, twin.objects);
        // The models' parts, which the objects hold apart.
        for (&full.world.objects.slots, &twin.objects.slots, 0..) |*a, *b, index| {
            const model_a = if (a.model) |*model| model else continue;
            const model_b = if (b.model) |*model| model else continue;
            if (model_a.parts.len != model_b.parts.len) continue;
            for (model_a.parts, model_b.parts, 0..) |*x, *y, part| {
                const path: []const Differences.Segment = &.{ .{ .field = "objects" }, .{ .field = "slots" }, .{ .index = index }, .{ .field = "model" }, .{ .field = "parts" }, .{ .index = part } };
                for (path) |segment| diffs.path.push(segment);
                defer for (path) |_| diffs.path.pop();
                diffs.walk(x, y);
            }
        }
        if (full.loaded) |loaded| if (twin.loaded) |mine| diffs.compare("mission", loaded, mine);
    }
};

test "Twin.bare" {
    var mission: game.gameobj.testing.Mission = undefined;
    try mission.init(std.testing.allocator);
    defer mission.deinit();
    var flash: game.main.flash.Flash = .{};
    var world = mission.world();
    world.flash = &flash;
    world.spawn = mission.spawn(game.create.testing.no_models);
    world.difficulty = .hard;
    const left = Twin.bare(world);
    // What is drawn or heard is left out; what the game makes ships from, and its settings, stay.
    try std.testing.expectEqual(null, left.flash);
    try std.testing.expect(left.spawn != null);
    try std.testing.expectEqual(.hard, left.difficulty);
    try std.testing.expectEqual(world.objects, left.objects);
}
