//! The records as the game's tables hold them (`loadTables`), and what a game mode keeps of its own
//! for its missions alone (`ModeState`): its records
//! ([#816](https://github.com/OpenReliant/openreliant/issues/816)) and its wingmen.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const scripting = @import("scripting");
const game = openreliant.engine.game;

/// Loads the game's tables from `records`: the ships' stats as `stats_load_ships` reads them, the
/// ship types' words from the executable, the guns', the missiles' and the pilots' stats, and the
/// pilots' faces; and installs the combat maneuvers. The text needs no loading, since the game
/// reads it from the records.
pub fn loadTables(tables: *game.create.Stats, objects: *game.create.Objects, records: *const scripting.Records) void {
    tables.load(records.ships);
    tables.loadTypes(records.ship_types);
    objects.gun_stats.load(records.guns);
    objects.missile_stats.load(records.missiles);
    objects.pilots.load(records.pilots);
    objects.faces.load(records.faces);
    game.aidefend.install(records.maneuvers);
}

/// What a game mode keeps of its own while its missions run, in place of the campaign's: its
/// records (`scripting.game_modes.ModeRecords`), with the game's tables loaded again from the
/// records as the mode's changes come and go, and its wingmen (`game.pilots.Wingmen`), which
/// start anew as each mode starts. So the campaign's wing never sees the mode's losses.
///
/// **Improvement:** the original has no game modes.
pub const ModeState = struct {
    own: *scripting.game_modes.ModeRecords,
    tables: *game.create.Stats,
    objects: *game.create.Objects,
    /// The mode's wingmen while the campaign's are in the objects, and the campaign's while the
    /// mode's are (`wingmen_in`).
    aside: game.pilots.Wingmen = .{},
    wingmen_in: bool = false,

    /// As a mode starts: its wingmen anew.
    pub fn begin(state: *ModeState) void {
        state.restore();
        state.aside = .{};
    }

    /// Before a mission of `mode`: its records, the tables loaded from them, and its wingmen.
    pub fn apply(state: *ModeState, mode: scripting.game_modes.Mode) Allocator.Error!void {
        if (try state.own.apply(mode)) state.load();
        if (!state.wingmen_in) state.swapWingmen();
    }

    /// As the mission ends: the records as they were, the tables loaded from them again, and the
    /// campaign's wingmen.
    pub fn restore(state: *ModeState) void {
        if (state.own.restore()) state.load();
        if (state.wingmen_in) state.swapWingmen();
    }

    fn load(state: *ModeState) void {
        loadTables(state.tables, state.objects, state.own.held);
    }

    fn swapWingmen(state: *ModeState) void {
        std.mem.swap(game.pilots.Wingmen, &state.objects.wingmen, &state.aside);
        state.wingmen_in = !state.wingmen_in;
    }
};

test ModeState {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try scripting.load.testing.makeMods(io, tmp.dir, &.{.{
        "p",
        &.{
            .{ "mod.ini", "[Mod]\nName=P\n" },
            .{
                "own.luau",
                \\local records = require("openreliant.records")
                \\records.ships[0].max_speed = 300
                \\records.maneuvers[#records.maneuvers] = { name = "drift", script = { "SetSpeed(0.5)", "Wait(100)" } }
            },
        },
    }});
    var opened: game.bigfile.mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ships: [1]openreliant.stats.Ship = .{std.mem.zeroes(openreliant.stats.Ship)};
    ships[0].max_speed = 10;
    ships[0].pitch_rate = 1;
    var records: scripting.Records = try .init(arena.allocator(), .{ .ships = &ships, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    const tables = try gpa.create(game.create.Stats);
    defer gpa.destroy(tables);
    tables.* = .initial;
    var random: openreliant.engine.random.Random = .{};
    const objects = try game.create.Objects.create(gpa, &random);
    defer objects.destroy();
    defer game.aidefend.installOriginal();
    loadTables(tables, objects, &records);
    try std.testing.expectEqual(10, tables.flight[0].max_speed);

    // The mode's mission flies with its own records, and the next with the game's again.
    var own: scripting.game_modes.ModeRecords = .init(gpa, io, opened.list, &records, "0.7.0", .{});
    defer own.deinit();
    var state: ModeState = .{ .own = &own, .tables = tables, .objects = objects };
    const mode: scripting.game_modes.Mode = .{ .name = "p:own", .mod = "p", .missions = &.{.{ .file = 91, .number = 91 }}, .ship = null, .kind = .once, .briefing = null, .records = "own.luau" };
    try state.apply(mode);
    try std.testing.expectEqual(300, tables.flight[0].max_speed);
    try std.testing.expectEqualStrings("drift", game.aidefend.find(@fromBackingInt(10)).?.definition.name);
    state.restore();
    try std.testing.expectEqual(10, tables.flight[0].max_speed);
    try std.testing.expectEqual(null, game.aidefend.find(@fromBackingInt(10)));

    // The mode's wingmen fly its missions, and the campaign's lose nobody to them.
    objects.wingmen.alpha[1] = 33;
    state.begin();
    try state.apply(mode);
    try std.testing.expectEqual(game.pilots.new_wing, objects.wingmen.alpha);
    objects.wingmen.lose(game.pilots.new_wing[2]);
    state.restore();
    try std.testing.expectEqual(33, objects.wingmen.alpha[1]);
    try std.testing.expectEqual(game.pilots.new_wing[2], objects.wingmen.alpha[2]);
    // The next mission of the mode finds its own losses, and the next mode starts anew.
    try state.apply(mode);
    try std.testing.expectEqual(-1, objects.wingmen.alpha[2]);
    state.begin();
    try std.testing.expectEqual(33, objects.wingmen.alpha[1]);
    try state.apply(mode);
    try std.testing.expectEqual(game.pilots.new_wing, objects.wingmen.alpha);
    state.restore();
}
