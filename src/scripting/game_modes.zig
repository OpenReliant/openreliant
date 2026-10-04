//! Game modes from mods ([#560](https://github.com/OpenReliant/openreliant/issues/560)):
//! `core.register_game_mode` and `core.game_mode`.
//!
//! - A load or menu script registers a mode as OpenReliant starts: a label and a description for
//!   the game modes screen (`interface.game_modes`), the missions it flies in turn, the ship the
//!   player flies them in, and whether it starts again after the last. Both run before the front
//!   end shows anything, so the modes are fixed for the whole run; the driver closes the registry
//!   once they have started (`Registry.close`).
//! - The driver flies a mode's missions as the main menu flies INSTANT ACTION's, and says which mode
//!   runs (`Registry.running`). Every script reads it (`core.game_mode`), so that a mod's rules,
//!   its global scripts' hooks and its player scripts' displays, apply while its mode runs alone.
//! - A mission is a standard `.DTE` file, the game's or a mod's, by its number: the mode adds
//!   nothing to the mission format.
//!
//! **Improvement:** the original has no game modes but its campaign, INSTANT ACTION and
//! multiplayer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const gameobj = openreliant.engine.game.gameobj;
const screen = openreliant.engine.game.interface.game_modes;
const api = @import("api.zig");
const Call = api.Call;
const values = @import("values.zig");
const runtime_module = @import("runtime.zig");

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
};

/// A mode registered.
pub const Mode = struct {
    /// Its qualified name, such as `arena:arena`.
    name: []const u8,
    missions: []const u16,
    ship: ?gameobj.Type,
    loop: bool,
};

/// The modes the mods registered, in the order they were. The strings and the lists live as long
/// as the registry does (`arena`).
pub const Registry = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    modes: std.ArrayList(Mode) = .empty,
    /// The modes as the game modes screen shows them, in the same order.
    shown: std.ArrayList(screen.Mode) = .empty,
    /// Whether registering is over.
    closed: bool = false,
    /// The mode running, by its place, while one does.
    running: ?usize = null,

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(registry: *Registry) void {
        registry.modes.deinit(registry.gpa);
        registry.shown.deinit(registry.gpa);
        registry.arena.deinit();
    }

    /// Ends registering, as the scripts that register have started.
    pub fn close(registry: *Registry) void {
        registry.closed = true;
    }

    /// The place of the mode called `name`, if one is.
    pub fn find(registry: *const Registry, name: []const u8) ?usize {
        for (registry.modes.items, 0..) |mode, at| if (std.mem.eql(u8, mode.name, name)) return at;
        return null;
    }

    /// Keeps a copy of `given`, which has been checked, as the mode `name` of the mod called `mod`
    /// on the screen.
    fn adopt(registry: *Registry, mod: []const u8, name: []const u8, given: Definition) Allocator.Error!void {
        const memory = registry.arena.allocator();
        try registry.modes.ensureUnusedCapacity(registry.gpa, 1);
        try registry.shown.ensureUnusedCapacity(registry.gpa, 1);
        registry.modes.appendAssumeCapacity(.{
            .name = try memory.dupe(u8, name),
            .missions = try memory.dupe(u16, given.missions.slice()),
            .ship = given.ship,
            .loop = given.loop,
        });
        registry.shown.appendAssumeCapacity(.{
            .label = try memory.dupe(u8, given.label),
            .description = try memory.dupe(u8, given.description),
            .mod = try memory.dupe(u8, mod),
            .missions = given.missions.len,
            .loop = given.loop,
        });
    }

    /// The mode running, if one does.
    pub fn current(registry: *const Registry) ?Mode {
        return registry.modes.items[registry.running orelse return null];
    }
};

/// What `openreliant.core` holds of game modes.
pub const functions = struct {
    pub const register_game_mode = api.Function("Registers a game mode, which the main menu's GAME MODES lists: a `name`, which the mod's name qualifies; a `label` and a `description` for the screen; the `missions` it flies in turn, by their numbers, each a standard `.DTE` file of the game's or a mod's; the `ship` the player flies them in, or the ship each mission gives; and whether it starts again after its last mission (`loop`). Only load and menu scripts can use it, as OpenReliant starts. Returns the mode's qualified name.", &.{"definition"}, register);
    pub const game_mode = api.Field(?[]const u8, "The qualified name of the game mode that runs, such as `arena:arena`; nil in the campaign, INSTANT ACTION and anywhere else.", struct {
        pub fn get(call: Call) ?[]const u8 {
            const registry = call.runtime().options.shared.modes orelse return null;
            return (registry.current() orelse return null).name;
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
    const mod = call.context.modOf();
    registry.adopt(mod.about(.name) orelse mod.name, name, given) catch call.raise("core: out of memory", .{});
    return registry.modes.items[registry.modes.items.len - 1].name;
}
