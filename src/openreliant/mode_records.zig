//! The records as the game's tables hold them (`loadTables`), and a game mode's own records, which
//! its missions alone see (`ModeTables`,
//! [#816](https://github.com/OpenReliant/openreliant/issues/816)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const scripting = @import("scripting");
const game = openreliant.engine.game;

/// Loads the game's tables from `records`: the ships' stats as `stats_load_ships` reads them, the
/// guns', the missiles' and the pilots', and the pilots' faces. The text needs no loading, since
/// the game reads it from the records.
pub fn loadTables(tables: *game.create.Stats, objects: *game.create.Objects, records: *const scripting.Records) void {
    tables.load(records.ships);
    objects.gun_stats.load(records.guns);
    objects.missile_stats.load(records.missiles);
    objects.pilots.load(records.pilots);
    objects.faces.load(records.faces);
}

/// A game mode's own records (`scripting.game_modes.ModeRecords`), and the game's tables, loaded
/// again from the records as the mode's changes come and go.
pub const ModeTables = struct {
    own: *scripting.game_modes.ModeRecords,
    tables: *game.create.Stats,
    objects: *game.create.Objects,

    /// Before a mission of `mode`: its records, and the tables loaded from them.
    pub fn apply(mode_tables: ModeTables, mode: scripting.game_modes.Mode) Allocator.Error!void {
        if (try mode_tables.own.apply(mode)) mode_tables.load();
    }

    /// As the mission ends: the records as they were, and the tables loaded from them again.
    pub fn restore(mode_tables: ModeTables) void {
        if (mode_tables.own.restore()) mode_tables.load();
    }

    fn load(mode_tables: ModeTables) void {
        loadTables(mode_tables.tables, mode_tables.objects, mode_tables.own.held);
    }
};

test ModeTables {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try scripting.load.testing.makeMods(io, tmp.dir, &.{.{ "p", &.{
        .{ "mod.ini", "[Mod]\nName=P\n" },
        .{ "own.luau", "require('openreliant.records').ships[0].max_speed = 300" },
    } }});
    var opened: game.bigfile.mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ships: [1]openreliant.stats.Ship = .{std.mem.zeroes(openreliant.stats.Ship)};
    ships[0].max_speed = 10;
    ships[0].pitch_rate = 1;
    var records: scripting.Records = try .init(arena.allocator(), .{ .ships = &ships, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    const tables = try gpa.create(game.create.Stats);
    defer gpa.destroy(tables);
    tables.* = .initial;
    var random: openreliant.engine.random.Random = .{};
    const objects = try game.create.Objects.create(gpa, &random);
    defer objects.destroy();
    loadTables(tables, objects, &records);
    try std.testing.expectEqual(10, tables.flight[0].max_speed);

    // The mode's mission flies with its own records, and the next with the game's again.
    var own: scripting.game_modes.ModeRecords = .init(gpa, io, opened.list, &records, "0.7.0", .{});
    defer own.deinit();
    const mode_tables: ModeTables = .{ .own = &own, .tables = tables, .objects = objects };
    try mode_tables.apply(.{ .name = "p:own", .mod = "p", .missions = &.{.{ .file = 91, .number = 91 }}, .ship = null, .kind = .once, .briefing = null, .records = "own.luau" });
    try std.testing.expectEqual(300, tables.flight[0].max_speed);
    mode_tables.restore();
    try std.testing.expectEqual(10, tables.flight[0].max_speed);
}
