//! Game modes and campaigns from mods ([#560](https://github.com/OpenReliant/openreliant/issues/560),
//! [#442](https://github.com/OpenReliant/openreliant/issues/442)): `core.register_game_mode`,
//! `core.game_mode` and `core.game_mode_mission`.
//!
//! - A load or menu script registers a mode as OpenReliant starts: a label and a description for
//!   the game modes screen (`interface.game_modes`), the missions it flies in turn, the ship the
//!   player flies them in, how it flies them (`Kind`), and the mod's screen that briefs the player
//!   before each mission. Both kinds of script run before the front end shows anything, so the
//!   modes are fixed for the whole run; the driver closes the registry once they have started
//!   (`Registry.close`).
//! - The driver flies a mode's missions as the main menu flies INSTANT ACTION's, and says which mode
//!   runs (`Registry.running`) and which mission it is at (`Registry.at`). Every script reads them
//!   (`core.game_mode`), so that a mod's rules, its global scripts' hooks and its player scripts'
//!   displays, apply while its mode runs alone.
//! - A campaign shows the restart screen after a mission is lost or left, as the trial does, to
//!   fly it again or go back to the main menu (`Next`). It keeps the mission the player reached in
//!   the mod's global storage, in the section `campaigns` (`progress_section`), under the mode's
//!   own name. GAME MODES carries on from there; after the last mission it starts from the first
//!   again.
//! - A mission is a standard `.DTE` file, the game's or a mod's, by its number: the mode adds
//!   nothing to the mission format. A mode can fly a mod's mission as one of the game's numbers,
//!   for what the game does by a mission's number
//!   ([#818](https://github.com/OpenReliant/openreliant/issues/818)), and name its objectives,
//!   which the game's table names only for its own missions
//!   ([#817](https://github.com/OpenReliant/openreliant/issues/817)).
//! - A mode can name a records script of its mod, which changes the records for its missions alone
//!   ([#816](https://github.com/OpenReliant/openreliant/issues/816)). It runs as a load script
//!   before each of them, and the records go back to what they were as the mission ends
//!   (`ModeRecords`), so that the game's campaign never sees the changes.
//!
//! **Improvement:** the original has no game modes but its campaign, INSTANT ACTION and
//! multiplayer, and its campaign is its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const gameobj = openreliant.engine.game.gameobj;
const pilots = openreliant.engine.game.pilots;
const rooms = openreliant.engine.game.interface.rooms;
const hud = openreliant.engine.game.hud;
const mods = openreliant.engine.game.bigfile.mods;
const Mod = mods.Mod;
const Ending = openreliant.engine.game.main.Ending;
const Rating = openreliant.engine.vm.Variables.Outcome;
const screen = openreliant.engine.game.interface.game_modes;
const loadout_tables = openreliant.engine.interface.loadout.tables;
const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const runtime_module = @import("runtime.zig");
const Storage = @import("storage.zig").Storage;
const records = @import("records.zig");
const load = @import("load.zig");
const script = @import("script.zig");

const log = std.log.scoped(.scripts);

/// How a mode flies its missions.
pub const Kind = screen.Mode.Kind;

/// The section of a mod's global storage that keeps how far each of its campaigns has come: the
/// place of the mission to fly next, from 0, under the mode's own name. A script can set it, to
/// start a campaign over for example.
pub const progress_section = "campaigns";

/// The most missions a mode flies.
pub const max_missions = 64;

/// The most ships a mode's loadout offers: as many as its arc has places.
pub const max_loadout_ships = loadout_tables.arc_slot_count;

/// A mission of a mode, as a script gives it: its number, or a table with more.
pub const MissionGiven = union(enum) {
    number: u16,
    table: MissionTable,
};

/// A mission of a mode with more than its number.
pub const MissionTable = struct {
    pub const script_name = "GameModeMissionTable";

    /// Its number: the file `mission<number>.dte`.
    number: u16,
    /// The number it flies as, for what the game does by a mission's number, such as the wing
    /// flying the twins of the player's ships from mission 14 on; its own number by default.
    as: ?u16 = null,
    /// The names of its objectives, which its script's `SetObjective` numbers from 0, in place of
    /// the names the game's table has for the number it flies as.
    objectives: ?values.List([]const u8, hud.Objectives.per_mission) = null,
    /// Where the mode briefs its missions in the game's briefing room (`Definition.briefing_room`):
    /// the movie on the room's screen, a Bink file of the game's or a mod's.
    hologram: ?[]const u8 = null,
    /// Enriquez's last word after the loadout in that room, a speech file of the game's or a mod's,
    /// such as `ms_speech\enrbr_tag01.ut`; none leaves her silent.
    last_word: ?[]const u8 = null,
};

/// A mission a mode flies: the number of its file, the number it flies as, the names it gives its
/// objectives, if it gives any (`hud.Objectives.Names`), in the game's code page, and its movie and
/// last word in the game's briefing room.
pub const Entry = struct {
    file: u16,
    number: u16,
    objectives: ?hud.Objectives.Names = null,
    hologram: ?[]const u8 = null,
    last_word: ?[]const u8 = null,
};

/// A mode, as a script registers it.
pub const Definition = struct {
    pub const script_name = "GameMode";

    /// Its name, which the mod's name qualifies.
    name: []const u8,
    /// What the game modes screen calls it, and what it says of it.
    label: []const u8,
    description: []const u8 = "",
    /// The missions it flies, in turn, by their numbers (`mission<number>.dte`), or as tables that
    /// say more of each (`MissionTable`).
    missions: values.List(MissionGiven, max_missions),
    /// The ship the player flies them in, or the ship each mission gives.
    ship: ?gameobj.Type = null,
    /// Whether it starts again from its first mission after its last, until the player leaves a
    /// mission; otherwise it comes back to the main menu.
    loop: bool = false,
    /// Whether it is a campaign: the restart screen follows a mission lost or left, and GAME MODES
    /// carries on from the mission the player reached.
    campaign: bool = false,
    /// The name of the mod's registered screen (`ui.register_screen`) that the front end shows
    /// before each of its missions, which flies it with `ui.launch_mission`.
    briefing: ?[]const u8 = null,
    /// The game's briefing room that briefs each of its missions, after the `briefing` screen
    /// where there is one: the door, Enriquez at the room's screen with the mission's `hologram`,
    /// the loadout on the same ship and her `last_word` (`MissionTable`), as the StarLancer trial
    /// briefs its missions ([#819](https://github.com/OpenReliant/openreliant/issues/819)).
    briefing_room: ?rooms.Carrier = null,
    /// The ships the loadout offers there, in order, in place of those the campaign's tier and the
    /// pilot's rank open. It starts on the first, and then on the ship chosen last.
    loadout_ships: ?values.List(gameobj.Type, max_loadout_ships) = null,
    /// The pilots of the player's wingmen, Alpha 2 to 6, in place of the campaign's wing, which
    /// the missions flown as the campaign's numbers give the wingmen; `none` keeps a place's.
    wing_pilots: ?values.List(pilots.Number, pilots.wingman_places) = null,
    /// Whether the ITAC debriefs each mission that goes on to the next, as the StarLancer trial's
    /// does. It offers only DEBRIEFINGS, which shows the debriefing for the number the mission
    /// flies as and its rating, in the text of the mode's records, with REPLAY MISSION.
    debriefing: bool = false,
    /// The name of the mod's registered screen that the front end shows after its last mission,
    /// which leaves for the main menu with `ui.go_to("main_menu")`.
    ending: ?[]const u8 = null,
    /// The name of the mod's script that changes the records for its missions alone: a load script
    /// that runs before each of them, whose changes go back as the mission ends.
    records: ?[]const u8 = null,

    fn kind(definition: Definition) Kind {
        if (definition.campaign) return .campaign;
        return if (definition.loop) .loop else .once;
    }
};

/// What `register` works out of a mode's definition: the names of its briefing's and its ending's
/// screens, which the mod's name qualifies, and the file of its records script.
const Names = struct {
    briefing: ?[]const u8 = null,
    ending: ?[]const u8 = null,
    records: ?[]const u8 = null,
};

/// A mode registered.
pub const Mode = struct {
    /// Its qualified name, such as `arena:arena`, and the name of its mod's folder.
    name: []const u8,
    mod: []const u8,
    missions: []const Entry,
    ship: ?gameobj.Type,
    kind: Kind,
    /// The qualified name of its briefing screen, if it has one.
    briefing: ?[]const u8,
    /// The game's briefing room that briefs its missions, if one does, and the ships its loadout
    /// offers, if the mode lists them.
    briefing_room: ?rooms.Carrier = null,
    loadout_ships: ?[]const gameobj.Type = null,
    /// The pilots it seats in the player's wing, from Alpha 2, if it names any.
    wing_pilots: ?[]const pilots.Number = null,
    /// Whether the ITAC debriefs its missions.
    debriefing: bool = false,
    /// The qualified name of its ending screen, if it has one.
    ending: ?[]const u8 = null,
    /// The file of its records script, as its mod has it, if it has one.
    records: ?[]const u8 = null,

    /// Its name without the mod's: what follows the last colon, since the mod's part is its
    /// qualifier (`Mod.qualifier`), which leaves out a packed mod's `.hog`, and its own part has no
    /// colon.
    fn own(mode: Mode) []const u8 {
        const colon = std.mem.findScalarLast(u8, mode.name, ':') orelse return mode.name;
        return mode.name[colon + 1 ..];
    }
};

/// The mission a mode is at, as scripts see it.
pub const ModeMission = struct {
    pub const script_name = "GameModeMission";

    /// The mission's number, its place among the mode's missions from 1, and how many it has.
    number: u16,
    place: u16,
    count: u16,
};

/// What follows a mission of the mode running as it ends (`Registry.goesOn`).
pub const Next = enum {
    /// The briefing of the mission the mode flies next.
    mission,
    /// The restart screen, after a campaign's mission is lost or left from the pause menu, as
    /// the trial shows it: the mission flown again from its briefing or from its launch, or the
    /// main menu.
    restart,
    /// The mode is over after its last mission: its ending, where it has one, then the main menu.
    over,
    /// The player left the mode from the pause menu, for the main menu.
    left,
};

/// Whether a mission that ended as `ending`, rated `rating` by its script, is lost: the player's
/// ship destroyed, the pilot captured or sent home, or the mission a total failure.
fn lost(ending: Ending, rating: Rating) bool {
    return switch (ending) {
        .destroyed, .captured, .friendly_fire, .total_failure => true,
        else => rating == .total_failure,
    };
}

/// The modes the mods registered, in the order they were. The strings and the lists live as long
/// as the registry does (`arena`).
pub const Registry = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    /// The mods' storage, which keeps the campaigns' progress; none keeps it nowhere.
    storage: ?*Storage = null,
    modes: std.ArrayList(Mode) = .empty,
    /// The modes as the game modes screen shows them, in the same order.
    shown: std.ArrayList(screen.Mode) = .empty,
    /// Whether registering is over.
    closed: bool = false,
    /// The mode running, by its place, while one does, and the place of the mission it is at.
    running: ?usize = null,
    at: usize = 0,

    pub fn init(gpa: Allocator, storage: ?*Storage) Registry {
        return .{ .gpa = gpa, .arena = .init(gpa), .storage = storage };
    }

    pub fn deinit(registry: *Registry) void {
        registry.modes.deinit(registry.gpa);
        registry.shown.deinit(registry.gpa);
        registry.arena.deinit();
    }

    /// Ends registering, as the scripts that register have started, and reads how far each
    /// campaign has come.
    pub fn close(registry: *Registry) void {
        registry.closed = true;
        for (registry.modes.items, registry.shown.items) |mode, *shown| {
            if (mode.kind == .campaign) shown.reached = registry.kept(mode);
        }
    }

    /// The place of the mode called `name`, if one is.
    pub fn find(registry: *const Registry, name: []const u8) ?usize {
        for (registry.modes.items, 0..) |mode, at| if (std.mem.eql(u8, mode.name, name)) return at;
        return null;
    }

    /// Keeps a copy of `given`, which has been checked, as the mode `name` of the mod in the folder
    /// `folder`, called `mod` on the screen, with the screens and the records script `names` gives.
    fn adopt(registry: *Registry, folder: []const u8, mod: []const u8, name: []const u8, names: Names, given: Definition) (Allocator.Error || error{BadName})!void {
        const memory = registry.arena.allocator();
        try registry.modes.ensureUnusedCapacity(registry.gpa, 1);
        try registry.shown.ensureUnusedCapacity(registry.gpa, 1);
        registry.modes.appendAssumeCapacity(.{
            .name = try memory.dupe(u8, name),
            .mod = try memory.dupe(u8, folder),
            .missions = try entries(memory, given.missions.slice()),
            .ship = given.ship,
            .kind = given.kind(),
            .briefing = if (names.briefing) |screen_name| try memory.dupe(u8, screen_name) else null,
            .briefing_room = given.briefing_room,
            .loadout_ships = if (given.loadout_ships) |listed| try memory.dupe(gameobj.Type, listed.slice()) else null,
            .wing_pilots = if (given.wing_pilots) |listed| try memory.dupe(pilots.Number, listed.slice()) else null,
            .debriefing = given.debriefing,
            .ending = if (names.ending) |screen_name| try memory.dupe(u8, screen_name) else null,
            .records = if (names.records) |file| try memory.dupe(u8, file) else null,
        });
        registry.shown.appendAssumeCapacity(.{
            .label = try memory.dupe(u8, given.label),
            .description = try memory.dupe(u8, given.description),
            .mod = try memory.dupe(u8, mod),
            .missions = given.missions.len,
            .kind = given.kind(),
        });
    }

    /// The mode running, if one does.
    pub fn current(registry: *const Registry) ?Mode {
        return registry.modes.items[registry.running orelse return null];
    }

    /// Starts the mode at `place`: a campaign at the mission the player reached, any other at its
    /// first.
    pub fn start(registry: *Registry, place: usize) void {
        registry.running = place;
        const mode = registry.modes.items[place];
        registry.at = if (mode.kind == .campaign) registry.kept(mode) else 0;
    }

    /// The mission the mode running is at.
    pub fn mission(registry: *const Registry) ?*const Entry {
        return &(registry.current() orelse return null).missions[registry.at];
    }

    /// Moves the mode running on as its mission ends as `ending`, rated `rating`, and tells what
    /// follows. A campaign stays at a mission that is lost or left, for the restart screen, and
    /// starts from its first mission again after its last. A loop starts again after its last.
    /// Any other mode ends after its last, or when the player leaves a mission.
    pub fn goesOn(registry: *Registry, ending: Ending, rating: Rating) Next {
        const mode = registry.current() orelse return .over;
        if (mode.kind == .campaign and (ending == .left or lost(ending, rating))) return .restart;
        if (ending == .left) return .left;
        registry.at += 1;
        const over = registry.at == mode.missions.len;
        if (over) registry.at = 0;
        if (mode.kind == .campaign) registry.keep(mode, registry.at);
        if (over and mode.kind != .loop) return .over;
        return .mission;
    }

    /// Takes the mode running back to its mission at `place`, which `goesOn` has moved on from, as
    /// the ITAC's REPLAY MISSION flies it again.
    pub fn replay(registry: *Registry, place: usize) void {
        const mode = registry.current() orelse return;
        registry.at = place;
        if (mode.kind == .campaign) registry.keep(mode, place);
    }

    /// The place of the mission the campaign `mode` carries on from, as its mod's storage keeps it.
    fn kept(registry: *const Registry, mode: Mode) usize {
        const storage = registry.storage orelse return 0;
        const value = storage.read(mode.mod, progress_section, .global, mode.own()) orelse return 0;
        const place = switch (value) {
            .number => |number| number,
            else => return 0,
        };
        if (!(place >= 0 and place < @as(f64, @floatFromInt(mode.missions.len)))) return 0;
        return @intFromFloat(place);
    }

    /// Keeps `place` as the mission the campaign `mode` carries on from.
    fn keep(registry: *Registry, mode: Mode, place: usize) void {
        registry.shown.items[registry.running.?].reached = place;
        const storage = registry.storage orelse return;
        storage.put(mode.mod, progress_section, .global, mode.own(), .{ .number = @floatFromInt(place) }) catch
            log.warn("{s}: no memory to keep the campaign's progress", .{mode.name});
    }
};

/// A game mode's own records (`Mode.records`): before each of the mode's missions, its records
/// script changes the records the game reads, and as the mission ends they go back to what they
/// were. The driver loads the game's tables from the records again after each.
pub const ModeRecords = struct {
    gpa: Allocator,
    io: std.Io,
    opened: []const Mod,
    held: *records.Records,
    version: []const u8,
    shared: runtime_module.Shared,
    /// The records as they were, while a mission of the mode runs with its own.
    saved: ?records.Records.Snapshot = null,
    /// The text the script gives, which lives until the records go back.
    text: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, io: std.Io, opened: []const Mod, held: *records.Records, version: []const u8, shared: runtime_module.Shared) ModeRecords {
        return .{ .gpa = gpa, .io = io, .opened = opened, .held = held, .version = version, .shared = shared, .text = .init(gpa) };
    }

    pub fn deinit(mode_records: *ModeRecords) void {
        _ = mode_records.restore();
        mode_records.text.deinit();
    }

    /// Before a mission of `mode`: the records as they were, then changed by its records script,
    /// where it has one. Whether the records may have changed, so that the game's tables are
    /// loaded from them again.
    pub fn apply(mode_records: *ModeRecords, mode: Mode) Allocator.Error!bool {
        const restored = mode_records.restore();
        const name = mode.records orelse return restored;
        const mod = for (mode_records.opened, 0..) |candidate, at| {
            if (std.mem.eql(u8, candidate.name, mode.mod)) break at;
        } else return restored;
        mode_records.saved = try mode_records.held.snapshot(mode_records.gpa);
        const kept = mode_records.held.arena;
        mode_records.held.arena = mode_records.text.allocator();
        defer mode_records.held.arena = kept;
        try load.runOne(mode_records.gpa, mode_records.io, mode_records.opened, @intCast(mod), name, mode_records.held, mode_records.version, mode_records.shared);
        return true;
    }

    /// As the mission ends: the records as they were before the mode's script changed them, and
    /// its text let go of. Whether they changed back.
    pub fn restore(mode_records: *ModeRecords) bool {
        const saved = mode_records.saved orelse return false;
        saved.restore(mode_records.held);
        saved.deinit(mode_records.gpa);
        mode_records.saved = null;
        _ = mode_records.text.reset(.retain_capacity);
        return true;
    }
};

/// The missions `given`, as a mode keeps them in `memory`: each name of their objectives in the
/// game's code page (`language.encode`). Errors where a name isn't valid UTF-8 or is too long.
fn entries(memory: Allocator, given: []const MissionGiven) (Allocator.Error || error{BadName})![]const Entry {
    const kept = try memory.alloc(Entry, given.len);
    for (kept, given) |*entry, mission| entry.* = switch (mission) {
        .number => |number| .{ .file = number, .number = number },
        .table => |table| .{
            .file = table.number,
            .number = table.as orelse table.number,
            .objectives = if (table.objectives) |names| try records.missions.objectiveNames(memory, names.slice()) else null,
            .hologram = if (table.hologram) |name| try memory.dupe(u8, name) else null,
            .last_word = if (table.last_word) |name| try memory.dupe(u8, name) else null,
        },
    };
    return kept;
}

/// What `openreliant.core` holds of game modes.
pub const functions = struct {
    pub const register_game_mode = api.Function("Registers a game mode, which the main menu's GAME MODES lists. The mod's name qualifies its `name`, and the screen shows its `label` and `description`. `missions` lists the missions it flies in turn: each is the number of a standard `.DTE` file of the game's or a mod's, or a table that also gives the number the mission flies as, the names of its objectives, and its `hologram` and `last_word` in the briefing room. `ship` is the ship the player flies them in; without it, each mission gives the ship. With `loop`, the mode starts again after its last mission. A `campaign` shows the restart screen after a mission is lost or left, and carries on from the mission the player reached. `briefing` names the mod's registered screen that the front end shows before each mission. `briefing_room`, `reliant` or `yamato`, then briefs each mission in that game's briefing room, with the loadout. `loadout_ships` lists the ships that loadout offers, in order, starting on the first. `wing_pilots` lists the pilots of the player's wingmen, Alpha 2 to 6, in place of the campaign's wing, which the missions flown as the campaign's numbers give the wingmen: each a pilot of the game's by its number, or one a mod adds by its qualified name, and `none` keeps a place's pilot. With `debriefing`, the ITAC debriefs each mission that goes on to the next. `ending` names the mod's registered screen that the front end shows after the last mission. `records` names the mod's script that changes the records for the mode's missions alone: it runs as a load script before each of them, and its changes go back as the mission ends. Only load and menu scripts can use it, as OpenReliant starts. Returns the mode's qualified name.", &.{"definition"}, register);
    pub const game_mode = api.Field(?[]const u8, "The qualified name of the game mode that runs, such as `arena:arena`; nil in the game's campaign, INSTANT ACTION and anywhere else.", struct {
        pub fn get(call: Call) ?[]const u8 {
            const registry = call.runtime().options.shared.modes orelse return null;
            return (registry.current() orelse return null).name;
        }
    });
    pub const game_mode_mission = api.Field(?ModeMission, "The mission the game mode that runs is at: the one flown, or between missions the one flown next. nil where no game mode runs.", struct {
        pub fn get(call: Call) ?ModeMission {
            const registry = call.runtime().options.shared.modes orelse return null;
            const mode = registry.current() orelse return null;
            return .{ .number = mode.missions[registry.at].file, .place = @intCast(registry.at + 1), .count = @intCast(mode.missions.len) };
        }
    });
};

fn register(call: Call, given: Definition) []const u8 {
    switch (call.context.family) {
        .load, .menu => {},
        .global, .object, .player => call.raise("{t} scripts can't register a game mode; load and menu scripts can", .{call.context.family}),
    }
    const registry = call.runtime().options.shared.modes orelse call.raise("game modes aren't kept here", .{});
    if (registry.closed) call.raise("a game mode can only be registered as OpenReliant starts", .{});
    var buffer: [runtime_module.max_name]u8 = undefined;
    const name = call.qualified(given.name, &buffer);
    if (registry.find(name) != null) call.raise("the game mode '{s}' is registered already", .{name});
    if (registry.modes.items.len == screen.capacity) call.raise("at most {d} game modes can be registered", .{screen.capacity});
    if (given.label.len == 0) call.raise("a game mode needs a label", .{});
    if (given.missions.len == 0) call.raise("a game mode needs missions", .{});
    if (given.loop and given.campaign) call.raise("a campaign can't loop", .{});
    if (given.loadout_ships) |listed| if (listed.len == 0) call.raise("loadout_ships needs a ship", .{});
    var briefing_buffer: [runtime_module.max_name]u8 = undefined;
    var ending_buffer: [runtime_module.max_name]u8 = undefined;
    const mod = call.context.modOf();
    const names: Names = .{
        .briefing = if (given.briefing) |screen_name| call.qualified(screen_name, &briefing_buffer) else null,
        .ending = if (given.ending) |screen_name| call.qualified(screen_name, &ending_buffer) else null,
        .records = if (given.records) |file| script.find(mod, file) orelse call.raise("mod {s} has no script {s}", .{ mod.name, file }) else null,
    };
    registry.adopt(mod.name, mod.about(.name) orelse mod.name, name, names, given) catch |err| switch (err) {
        error.OutOfMemory => call.raise("out of memory", .{}),
        error.BadName => call.raise(records.missions.bad_objective_name, .{}),
    };
    return registry.modes.items[registry.modes.items.len - 1].name;
}

test Registry {
    const gpa = std.testing.allocator;
    var storage: Storage = .{ .gpa = gpa };
    defer storage.deinit();
    var registry: Registry = .init(gpa, &storage);
    defer registry.deinit();
    var missions: values.List(MissionGiven, max_missions) = .{};
    for ([_]u16{ 40, 41, 42 }) |number| missions.append(.{ .number = number });
    try registry.adopt("a", "A", "a:once", .{}, .{ .name = "once", .label = "ONCE", .missions = missions });
    try registry.adopt("a", "A", "a:loop", .{}, .{ .name = "loop", .label = "LOOP", .missions = missions, .loop = true });
    try registry.adopt("a", "A", "a:tour", .{ .briefing = "a:brief" }, .{ .name = "tour", .label = "TOUR", .missions = missions, .campaign = true, .briefing = "brief" });
    try std.testing.expectEqual(2, registry.find("a:tour").?);
    try std.testing.expectEqualStrings("a:brief", registry.modes.items[2].briefing.?);
    // The first mode flies its missions once, the player leaving one ends it.
    registry.start(0);
    try std.testing.expectEqual(40, registry.mission().?.file);
    try std.testing.expectEqual(.mission, registry.goesOn(.playing, .success));
    try std.testing.expectEqual(41, registry.mission().?.file);
    try std.testing.expectEqual(.mission, registry.goesOn(.destroyed, .failure));
    try std.testing.expectEqual(42, registry.mission().?.file);
    try std.testing.expectEqual(.over, registry.goesOn(.playing, .success));
    registry.start(0);
    try std.testing.expectEqual(.left, registry.goesOn(.left, .success));
    // The second starts again after its last.
    registry.start(1);
    registry.at = 2;
    try std.testing.expectEqual(.mission, registry.goesOn(.playing, .success));
    try std.testing.expectEqual(40, registry.mission().?.file);
    // The campaign stays at a mission lost or left, keeps the mission reached, and carries on from
    // it.
    registry.close();
    registry.start(2);
    try std.testing.expectEqual(.restart, registry.goesOn(.destroyed, .success));
    try std.testing.expectEqual(.restart, registry.goesOn(.playing, .total_failure));
    try std.testing.expectEqual(.restart, registry.goesOn(.left, .success));
    try std.testing.expectEqual(40, registry.mission().?.file);
    try std.testing.expectEqual(.mission, registry.goesOn(.playing, .success));
    try std.testing.expectEqual(1, storage.read("a", progress_section, .global, "tour").?.number);
    // REPLAY MISSION takes it back to the mission flown.
    registry.replay(0);
    try std.testing.expectEqual(40, registry.mission().?.file);
    try std.testing.expectEqual(0, storage.read("a", progress_section, .global, "tour").?.number);
    try std.testing.expectEqual(.mission, registry.goesOn(.playing, .success));
    try std.testing.expectEqual(1, registry.shown.items[2].reached);
    registry.running = null;
    registry.start(2);
    try std.testing.expectEqual(41, registry.mission().?.file);
    // After its last mission it is over, and starts from its first again.
    try std.testing.expectEqual(.mission, registry.goesOn(.rescued, .success));
    try std.testing.expectEqual(.over, registry.goesOn(.playing, .success));
    try std.testing.expectEqual(0, registry.shown.items[2].reached);
    // A place out of range in the storage starts it from its first mission.
    try storage.put("a", progress_section, .global, "tour", .{ .number = 7 });
    registry.start(2);
    try std.testing.expectEqual(40, registry.mission().?.file);
    // A packed mod's campaign keeps its progress under the mode's own name too, though the mod's
    // name, `b.hog`, is longer than its qualifier.
    try registry.adopt("b.hog", "B", "b:ace", .{}, .{ .name = "ace", .label = "ACE", .missions = missions, .campaign = true });
    registry.start(3);
    try std.testing.expectEqual(.mission, registry.goesOn(.playing, .success));
    try std.testing.expectEqual(1, storage.read("b.hog", progress_section, .global, "ace").?.number);
}

test ModeRecords {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try load.testing.makeMods(io, tmp.dir, &.{.{
        "p",
        &.{
            .{ "mod.ini", "[Mod]\nName=P\n" },
            .{
                "own.luau",
                \\local core = require("openreliant.core")
                \\local records = require("openreliant.records")
                \\records.guns.laser_cannon.range = 7
                \\records.text[1] = "Laser Cannon of " .. core.game_mode .. ", mission " .. core.game_mode_mission.number
            },
            .{ "broken.luau", "require('openreliant.records').guns[1].range = 99\nerror('broken')" },
        },
    }});
    var opened: mods.Mods = try .open(gpa, io, tmp.dir, null);
    defer opened.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var held = try load.testing.records3(arena.allocator());
    var registry: Registry = .init(gpa, null);
    defer registry.deinit();
    var missions: values.List(MissionGiven, max_missions) = .{};
    missions.append(.{ .number = 91 });
    try registry.adopt("p", "P", "p:own", .{ .records = "own.luau" }, .{ .name = "own", .label = "OWN", .missions = missions });
    try registry.adopt("p", "P", "p:broken", .{ .records = "broken.luau" }, .{ .name = "broken", .label = "BROKEN", .missions = missions });
    try registry.adopt("p", "P", "p:plain", .{}, .{ .name = "plain", .label = "PLAIN", .missions = missions });
    var own: ModeRecords = .init(gpa, io, opened.list, &held, "0.7.0", .{ .modes = &registry });
    defer own.deinit();

    // The mode's script changes the records for its mission, and they go back as it ends.
    registry.start(0);
    try std.testing.expect(try own.apply(registry.current().?));
    try std.testing.expectEqual(7, held.guns[0].range);
    try std.testing.expectEqualStrings("Laser Cannon of p:own, mission 91", held.text[0]);
    try std.testing.expect(own.restore());
    try std.testing.expectEqual(1, held.guns[0].range);
    try std.testing.expectEqualStrings("Laser Cannon", held.text[0]);
    try std.testing.expect(!own.restore());
    // A script that fails changes nothing.
    registry.start(1);
    _ = try own.apply(registry.current().?);
    try std.testing.expectEqual(1, held.guns[0].range);
    // A mode without a script flies with the records as they were before the last mode's script
    // changed them.
    registry.start(0);
    _ = try own.apply(registry.current().?);
    registry.start(2);
    try std.testing.expect(try own.apply(registry.current().?));
    try std.testing.expectEqual(1, held.guns[0].range);
    try std.testing.expect(!try own.apply(registry.current().?));
}
