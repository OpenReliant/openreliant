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
//! - A campaign flies a lost mission again, and keeps the mission the player reached in the mod's
//!   global storage, in the section `campaigns` (`progress_section`), under the mode's own name.
//!   GAME MODES carries on from there; after the last mission it starts from the first again.
//! - A mission is a standard `.DTE` file, the game's or a mod's, by its number: the mode adds
//!   nothing to the mission format.
//!
//! **Improvement:** the original has no game modes but its campaign, INSTANT ACTION and
//! multiplayer, and its campaign is its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const gameobj = openreliant.engine.game.gameobj;
const Ending = openreliant.engine.game.main.Ending;
const Rating = openreliant.engine.vm.Variables.Outcome;
const screen = openreliant.engine.game.interface.game_modes;
const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const runtime_module = @import("runtime.zig");
const Storage = @import("storage.zig").Storage;

const log = std.log.scoped(.scripts);

/// How a mode flies its missions.
pub const Kind = screen.Mode.Kind;

/// The section of a mod's global storage that keeps how far each of its campaigns has come: the
/// place of the mission to fly next, from 0, under the mode's own name. A script can set it, to
/// start a campaign over for example.
pub const progress_section = "campaigns";

/// The most missions a mode flies.
pub const max_missions = 64;

/// A mode, as a script registers it.
pub const Definition = struct {
    pub const script_name = "GameMode";

    /// Its name, which the mod's name qualifies.
    name: []const u8,
    /// What the game modes screen calls it, and what it says of it.
    label: []const u8,
    description: []const u8 = "",
    /// The missions it flies, in turn, by their numbers: `mission<number>.dte`.
    missions: values.List(u16, max_missions),
    /// The ship the player flies them in, or the ship each mission gives.
    ship: ?gameobj.Type = null,
    /// Whether it starts again from its first mission after its last, until the player leaves a
    /// mission; otherwise it comes back to the main menu.
    loop: bool = false,
    /// Whether it is a campaign: a lost mission is flown again, and GAME MODES carries on from the
    /// mission the player reached.
    campaign: bool = false,
    /// The name of the mod's registered screen (`ui.register_screen`) that the front end shows
    /// before each of its missions, which flies it with `ui.launch_mission`.
    briefing: ?[]const u8 = null,

    fn kind(definition: Definition) Kind {
        if (definition.campaign) return .campaign;
        return if (definition.loop) .loop else .once;
    }
};

/// A mode registered.
pub const Mode = struct {
    /// Its qualified name, such as `arena:arena`, and the name of its mod's folder.
    name: []const u8,
    mod: []const u8,
    missions: []const u16,
    ship: ?gameobj.Type,
    kind: Kind,
    /// The qualified name of its briefing screen, if it has one.
    briefing: ?[]const u8,

    /// Its name without the mod's.
    fn own(mode: Mode) []const u8 {
        return mode.name[mode.mod.len + 1 ..];
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
    /// `folder`, called `mod` on the screen, briefed by the screen called `briefing`.
    fn adopt(registry: *Registry, folder: []const u8, mod: []const u8, name: []const u8, briefing: ?[]const u8, given: Definition) Allocator.Error!void {
        const memory = registry.arena.allocator();
        try registry.modes.ensureUnusedCapacity(registry.gpa, 1);
        try registry.shown.ensureUnusedCapacity(registry.gpa, 1);
        registry.modes.appendAssumeCapacity(.{
            .name = try memory.dupe(u8, name),
            .mod = try memory.dupe(u8, folder),
            .missions = try memory.dupe(u16, given.missions.slice()),
            .ship = given.ship,
            .kind = given.kind(),
            .briefing = if (briefing) |screen_name| try memory.dupe(u8, screen_name) else null,
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

    /// The number of the mission the mode running is at.
    pub fn mission(registry: *const Registry) ?u16 {
        return (registry.current() orelse return null).missions[registry.at];
    }

    /// Moves the mode running on as its mission ends as `ending`, rated `rating`: to the number of
    /// the mission it flies next, or null where it is over. Leaving a mission ends it. A campaign
    /// flies a lost mission again, and starts from its first mission again after its last; a loop
    /// starts again after its last; any other mode ends after it.
    pub fn goesOn(registry: *Registry, ending: Ending, rating: Rating) ?u16 {
        const mode = registry.current() orelse return null;
        if (ending == .left) return null;
        if (mode.kind == .campaign and lost(ending, rating)) return registry.mission();
        registry.at += 1;
        const over = registry.at == mode.missions.len;
        if (over) registry.at = 0;
        if (mode.kind == .campaign) registry.keep(mode, registry.at);
        if (over and mode.kind != .loop) return null;
        return registry.mission();
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

/// What `openreliant.core` holds of game modes.
pub const functions = struct {
    pub const register_game_mode = api.Function("Registers a game mode, which the main menu's GAME MODES lists: a `name`, which the mod's name qualifies; a `label` and a `description` for the screen; the `missions` it flies in turn, by their numbers, each a standard `.DTE` file of the game's or a mod's; the `ship` the player flies them in, or the ship each mission gives; whether it starts again after its last mission (`loop`), or is a `campaign`, which flies a lost mission again and carries on from the mission the player reached; and the `briefing`, the name of the mod's registered screen that the front end shows before each mission. Only load and menu scripts can use it, as OpenReliant starts. Returns the mode's qualified name.", &.{"definition"}, register);
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
            return .{ .number = mode.missions[registry.at], .place = @intCast(registry.at + 1), .count = @intCast(mode.missions.len) };
        }
    });
};

fn register(call: Call, given: Definition) []const u8 {
    switch (call.context.family) {
        .load, .menu => {},
        .global, .object, .player => call.raise("core: {t} scripts can't register a game mode; load and menu scripts can", .{call.context.family}),
    }
    const registry = call.runtime().options.shared.modes orelse call.raise("core: game modes aren't kept here", .{});
    if (registry.closed) call.raise("core: a game mode can only be registered as OpenReliant starts", .{});
    var buffer: [runtime_module.max_name]u8 = undefined;
    const name = call.qualified("core", given.name, &buffer);
    if (registry.find(name) != null) call.raise("core: the game mode '{s}' is registered already", .{name});
    if (registry.modes.items.len == screen.capacity) call.raise("core: at most {d} game modes can be registered", .{screen.capacity});
    if (given.label.len == 0) call.raise("core: a game mode needs a label", .{});
    if (given.missions.len == 0) call.raise("core: a game mode needs missions", .{});
    if (given.loop and given.campaign) call.raise("core: a campaign can't loop", .{});
    var briefing_buffer: [runtime_module.max_name]u8 = undefined;
    const briefing = if (given.briefing) |screen_name| call.qualified("core", screen_name, &briefing_buffer) else null;
    const mod = call.context.modOf();
    registry.adopt(mod.name, mod.about(.name) orelse mod.name, name, briefing, given) catch call.raise("core: out of memory", .{});
    return registry.modes.items[registry.modes.items.len - 1].name;
}

test Registry {
    const gpa = std.testing.allocator;
    var storage: Storage = .{ .gpa = gpa };
    defer storage.deinit();
    var registry: Registry = .init(gpa, &storage);
    defer registry.deinit();
    var missions: values.List(u16, max_missions) = .{};
    for ([_]u16{ 40, 41, 42 }) |number| missions.append(number);
    try registry.adopt("a", "A", "a:once", null, .{ .name = "once", .label = "ONCE", .missions = missions });
    try registry.adopt("a", "A", "a:loop", null, .{ .name = "loop", .label = "LOOP", .missions = missions, .loop = true });
    try registry.adopt("a", "A", "a:tour", "a:brief", .{ .name = "tour", .label = "TOUR", .missions = missions, .campaign = true, .briefing = "brief" });
    try std.testing.expectEqual(2, registry.find("a:tour").?);
    try std.testing.expectEqualStrings("a:brief", registry.modes.items[2].briefing.?);
    // The first mode flies its missions once, the player leaving one ends it.
    registry.start(0);
    try std.testing.expectEqual(40, registry.mission().?);
    try std.testing.expectEqual(41, registry.goesOn(.playing, .success).?);
    try std.testing.expectEqual(42, registry.goesOn(.destroyed, .failure).?);
    try std.testing.expectEqual(null, registry.goesOn(.playing, .success));
    registry.start(0);
    try std.testing.expectEqual(null, registry.goesOn(.left, .success));
    // The second starts again after its last.
    registry.start(1);
    registry.at = 2;
    try std.testing.expectEqual(40, registry.goesOn(.playing, .success).?);
    // The campaign flies a lost mission again, keeps the mission reached, and carries on from it.
    registry.close();
    registry.start(2);
    try std.testing.expectEqual(40, registry.goesOn(.destroyed, .success).?);
    try std.testing.expectEqual(40, registry.goesOn(.playing, .total_failure).?);
    try std.testing.expectEqual(41, registry.goesOn(.playing, .success).?);
    try std.testing.expectEqual(1, storage.read("a", progress_section, .global, "tour").?.number);
    try std.testing.expectEqual(1, registry.shown.items[2].reached);
    registry.running = null;
    registry.start(2);
    try std.testing.expectEqual(41, registry.mission().?);
    // After its last mission it is over, and starts from its first again.
    try std.testing.expectEqual(42, registry.goesOn(.rescued, .success).?);
    try std.testing.expectEqual(null, registry.goesOn(.playing, .success));
    try std.testing.expectEqual(0, registry.shown.items[2].reached);
    // A place out of range in the storage starts it from its first mission.
    try storage.put("a", progress_section, .global, "tour", .{ .number = 7 });
    registry.start(2);
    try std.testing.expectEqual(40, registry.mission().?);
}
