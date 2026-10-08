//! Definitions for mod scripts from the full design in
//! [#498](https://github.com/OpenReliant/openreliant/issues/498): the script kinds a manifest's
//! `[Scripts]` section accepts, the engine handlers each kind may use, and the packages each kind
//! may require. They cover the whole design so that scripts written now keep working as later
//! versions add features.

const std = @import("std");

const openreliant = @import("openreliant");
const gameobj = openreliant.engine.game.gameobj;
const additions = openreliant.engine.game.additions;
const create = openreliant.engine.game.create;
const engine_hooks = openreliant.engine.hooks;
const input = openreliant.engine.input;
const mod_options = openreliant.engine.game.interface.mod_options;
const Object = engine_hooks.Object;
const Mod = openreliant.engine.game.bigfile.mods.Mod;
const data = @import("data.zig");
const values = @import("values.zig");

/// The manifest section that lists a mod's scripts by kind.
pub const section = "Scripts";

/// The manifest section that assigns global scripts to mission files. Each runs while its mission
/// runs.
pub const missions_section = "Missions";

/// A key in `[Scripts]`: a script kind (`Kind.key`), or an object type written as `Type.` followed
/// by OpenReliant's name for it (`Type.predator`), its number (`Type.12` or `Type.0x0C`), or a ship
/// type a mod adds by its qualified name (`Type.teapot:teapot`) or, in the mod that adds it, by its
/// own (`Type.teapot`).
pub const Attachment = union(enum) {
    kind: Kind,
    object_type: gameobj.Type,

    /// The prefix of keys that name an object type.
    pub const type_prefix = "Type.";

    /// Parses a key of the manifest of the mod called `mod`, ignoring case. Returns null for an
    /// unknown key. The ship types mods add must be read first (`additions.read`).
    pub fn parse(key: []const u8, mod: []const u8) ?Attachment {
        if (key.len > type_prefix.len and std.ascii.eqlIgnoreCase(key[0..type_prefix.len], type_prefix)) {
            const named = key[type_prefix.len..];
            if (std.fmt.parseInt(u32, named, 0)) |number| return .{ .object_type = @fromBackingInt(number) } else |_| {}
            const number = additions.ships.named(named, mod) orelse return null;
            return .{ .object_type = @fromBackingInt(number) };
        }
        inline for (comptime std.enums.values(Kind)) |kind| {
            if (std.ascii.eqlIgnoreCase(key, kind.key())) return .{ .kind = kind };
        }
        return null;
    }

    /// The script family: scripts attached to an object type are object scripts.
    pub fn family(attachment: Attachment) Family {
        return switch (attachment) {
            .kind => |kind| kind.family(),
            .object_type => .object,
        };
    }
};

/// A kind of script, by what it is attached to.
pub const Kind = enum {
    /// Runs once at startup, before the main menu, and changes the records.
    load,
    /// Runs for the whole game, and in the missions listed under `[Missions]`.
    global,
    /// Attached to the player, for the whole game.
    player,
    /// Runs in the menus, from startup until the game quits.
    menu,
    /// Attached to each object of a class (`create.ShipCombat.Class`).
    fighter,
    capital,
    support,
    other,
    torpedo,
    debris,
    mine,
    planet,
    /// Attached to each missile in flight.
    missile,
    /// Attached to each turret.
    turret,

    /// The kind's key in `[Scripts]`, such as `Load`.
    pub fn key(kind: Kind) []const u8 {
        return switch (kind) {
            inline else => |tag| comptime capitalised(@tagName(tag)),
        };
    }

    pub fn family(kind: Kind) Family {
        return switch (kind) {
            .load => .load,
            .global => .global,
            .player => .player,
            .menu => .menu,
            .fighter, .capital, .support, .other, .torpedo, .debris, .mine, .planet, .missile, .turret => .object,
        };
    }

    /// The object class whose objects scripts of this kind run on, for the kinds named after one.
    pub fn class(kind: Kind) ?create.ShipCombat.Class {
        return switch (kind) {
            inline .fighter, .capital, .support, .other, .torpedo, .debris, .mine, .planet => |tag| @field(create.ShipCombat.Class, @tagName(tag)),
            .load, .global, .player, .menu, .missile, .turret => null,
        };
    }
};

/// Iterates over a comma-separated list of script file names from `[Scripts]`.
pub const List = struct {
    names: std.mem.TokenIterator(u8, .scalar),

    pub fn of(text: []const u8) List {
        return .{ .names = std.mem.tokenizeScalar(u8, text, ',') };
    }

    pub fn next(list: *List) ?[]const u8 {
        while (list.names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len > 0) return name;
        }
        return null;
    }
};

/// The file name of `mod`'s script `name`, given with or without its extension and in any case, as
/// the mod has it; null where the mod has no such script.
pub fn find(mod: *const Mod, name: []const u8) ?[]const u8 {
    var names = mod.scripts();
    while (names.next()) |file| {
        if (isNamed(file, name)) return file;
    }
    return null;
}

/// Whether the script file `file` is the one `name` names, with or without its extension and in
/// any case (`require`).
pub fn isNamed(file: []const u8, name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(file, name)) return true;
    const stem = file[0 .. file.len - std.Io.Dir.path.extension(file).len];
    return std.ascii.eqlIgnoreCase(stem, name);
}

test isNamed {
    try std.testing.expect(isNamed("Records.LUAU", "records.luau"));
    try std.testing.expect(isNamed("records.luau", "Records"));
    try std.testing.expect(!isNamed("records.luau", "record"));
}

/// Script families, which decide what a script may do.
pub const Family = enum {
    /// Changes the records at startup.
    load,
    /// Controls what happens in a mission.
    global,
    /// Controls its own object.
    object,
    /// Controls what the player sees, hears and does.
    player,
    /// Controls the menus.
    menu,
};

/// The keys of the table a script returns.
pub const Offer = enum {
    engine_handlers,
    event_handlers,
    interface_name,
    interface,

    /// Whether a script of `family` may return this key. Load scripts may only return engine
    /// handlers.
    pub fn offeredBy(offer: Offer, family: Family) bool {
        return offer == .engine_handlers or family != .load;
    }
};

/// The engine handlers, which the engine calls as the game runs.
pub const Handler = enum {
    on_init,
    on_save,
    on_load,
    on_records_loaded,
    on_update,
    on_step,
    on_frame,
    on_mission_start,
    on_mission_end,
    on_object_added,
    on_object_removed,
    on_added,
    on_removed,
    on_key_press,
    on_key_release,
    on_action,
    on_console_command,
    on_window_resized,
    on_interface_override,
    on_option_changed,

    /// Whether a script of `family` may use this handler.
    pub fn givenBy(handler: Handler, family: Family) bool {
        return switch (handler) {
            .on_init, .on_interface_override => family != .load,
            // What lasts a whole game is kept: object scripts end with their mission, and menu
            // scripts run across games.
            .on_save, .on_load => family == .global or family == .player,
            .on_records_loaded => family == .load,
            .on_update, .on_step => family == .global or family == .object,
            .on_frame, .on_key_press, .on_key_release, .on_action, .on_console_command, .on_window_resized => family == .player or family == .menu,
            .on_mission_start, .on_mission_end => family == .global or family == .player or family == .menu,
            .on_object_added, .on_object_removed => family == .global,
            .on_added, .on_removed => family == .object,
            // The options are set in the front end, where the menu scripts run.
            .on_option_changed => family == .menu,
        };
    }

    /// When the engine calls it, for the reference.
    pub fn about(handler: Handler) []const u8 {
        return switch (handler) {
            .on_init => "When the script starts, with the data `add_script` gave it, or nil.",
            .on_save => "When the game is saved, between missions, and as each mission of the campaign starts, for its restart point: what it returns, which must be plain data, is kept with it. Mission scripts aren't kept.",
            .on_load => "In place of `on_init`, when a saved game is loaded or the game goes back to the restart point, with what the script's `on_save` returned then, or nil. A script that didn't run then, such as one of a mod added since, gets `on_init` instead.",
            .on_records_loaded => "After every mod's load scripts have run.",
            .on_update => "Each frame in which game time passes, after the ships' orders, with the seconds it covers.",
            .on_step => "Each simulation step, 25 a second, after everything has moved.",
            .on_frame => "Each frame drawn, even while the game is paused, with the seconds of real time since the last.",
            .on_mission_start => "When a mission has started and its first ships are there.",
            .on_mission_end => "When the mission ends, for whatever reason.",
            .on_object_added => "When an object is added to the mission.",
            .on_object_removed => "When an object leaves the mission, such as once it has blown up.",
            .on_added => "When the script's object is in the mission: as it's added, or at once if the script starts later.",
            .on_removed => "When the script's object leaves the mission.",
            .on_key_press => "When a key is pressed. A key held down is told once.",
            .on_key_release => "When a key is released.",
            .on_action => "When the player uses the controls bound to an action, in flight.",
            .on_console_command => "When a line typed in the console isn't one of its commands, with the line.",
            .on_window_resized => "When the window changes size, with its new size in pixels.",
            .on_interface_override => "When the script's interface takes the place of one an earlier script offered under the same name, with that one.",
            .on_option_changed => "When the player sets one of the mod's options on the mods screen, with its key and the new value. Options are set in the front end, so scripts that run in a game read them with `options.get` as they start.",
        };
    }

    /// What the engine passes it, as fields named after its parameters.
    pub fn Arguments(comptime handler: Handler) type {
        return switch (handler) {
            .on_init => struct { data: ?data.Data },
            .on_save => struct {},
            .on_load => struct { saved: ?data.Data },
            .on_records_loaded, .on_step, .on_added, .on_removed => struct {},
            .on_update => struct { seconds: f32 },
            .on_mission_start => struct { mission: engine_hooks.Mission },
            .on_mission_end => struct { outcome: engine_hooks.Outcome },
            .on_object_added, .on_object_removed => struct { object: Object },
            .on_interface_override => struct { base: values.Table },
            .on_frame => struct { seconds: f32 },
            .on_key_press, .on_key_release => struct { key: input.Key },
            .on_action => struct { action: []const u8 },
            .on_window_resized => struct { width: u32, height: u32 },
            .on_console_command => struct { text: []const u8 },
            .on_option_changed => struct { key: []const u8, value: mod_options.Value },
        };
    }

    /// What the engine takes from what it returns: what `on_save` returns is kept. Void for the
    /// handlers whose result is ignored.
    pub fn Result(comptime handler: Handler) type {
        return switch (handler) {
            .on_save => ?data.Data,
            .on_init, .on_load, .on_records_loaded, .on_update, .on_step, .on_frame, .on_mission_start, .on_mission_end, .on_object_added, .on_object_removed, .on_added, .on_removed, .on_key_press, .on_key_release, .on_action, .on_console_command, .on_window_resized, .on_interface_override, .on_option_changed => void,
        };
    }
};

/// The packages a script can require as `openreliant.<name>`.
pub const Package = enum {
    core,
    records,
    hooks,
    world,
    self,
    nearby,
    orders,
    hud,
    ui,
    input,
    camera,
    audio,
    postprocessing,
    shaders,
    storage,
    async,
    interfaces,
    util,
    vfs,
    options,
    debug,

    /// The prefix of package names.
    pub const prefix = "openreliant.";

    /// Parses a package name such as `openreliant.records`. Returns null for an unknown name.
    pub fn parse(name: []const u8) ?Package {
        const rest = std.mem.cutPrefix(u8, name, prefix) orelse return null;
        return std.meta.stringToEnum(Package, rest);
    }

    /// Whether a script of `family` may require this package.
    pub fn reachableFrom(package: Package, family: Family) bool {
        return switch (package) {
            .core, .records, .storage, .util, .vfs, .options => true,
            .async, .interfaces => family != .load,
            // The hooks there are so far are all the game's.
            .hooks => family == .global or family == .object,
            .world => family == .global,
            .self => family == .object or family == .player,
            .nearby => family == .object or family == .player,
            .orders => family == .global or family == .object,
            .hud, .camera, .postprocessing, .shaders, .debug => family == .player,
            .ui, .input, .audio => family == .player or family == .menu,
        };
    }

    /// What it gives, for the reference.
    pub fn about(package: Package) []const u8 {
        return switch (package) {
            .core => "OpenReliant's version, events for the global scripts, and game modes.",
            .records => "The game's records: ships, guns, missiles, pilots, the pilots' faces, the text of the game and the ITAC, and the campaign's missions in the order it flies them (`campaign`). Only load scripts can change them.",
            .hooks => "Handlers on the game's functions and events.",
            .world => "The mission's objects, the player's ship and the mission itself.",
            .self => "The script's own object, as a handle: an object script's object, a missile script's missile, or the player's ship for a player script, nil between games.",
            .nearby => "The objects around the script's own object or missile.",
            .orders => "What the order table says of each order, the orders each object has, and ending them. An object's give_order gives orders.",
            .hud => "Drawing over the flight display, while it's shown: text, lines and rectangles, in the window's pixels.",
            .ui => "Drawing over the menus, the front end's screens and the pause menu, while they're shown: text, lines and rectangles, in the window's pixels.",
            .input => "Whether keys are held, and the controls bound to actions.",
            .camera => "The camera's view: which it is, switching it, and registering views of the mod's own.",
            .audio => "Interface sounds, music and Betty's lines.",
            .postprocessing => "Post effects: GLSL fragment shaders from the mod, drawn over the whole frame, before the flight display or after it.",
            .shaders => "Surface and lighting functions: GLSL functions from the mod that change how surfaces are lit.",
            .storage => "Sections of plain data for each mod: kept with the saved game, or in the game folder across every game.",
            .async => "Timers, kept with the saved game: game time for global and object scripts, real time for player and menu scripts.",
            .interfaces => "The interfaces other scripts offer, as `I.<name>`: those of the global scripts to global scripts, those of an object's scripts to the object's other scripts, and those of player and menu scripts to each other. Nil for one nobody offers.",
            .util => "Orientations, turning points between the world and an object's own frame, and angles. Luau's vector library has the rest of the vector maths.",
            .vfs => "Reading the game's and the mods' files.",
            .options => "The options a mod offers the player on the mods screen: declaring the page, and reading the values.",
            .debug => "Lines and text placed in the world, drawn over the flight display where the camera sees them, for debugging.",
        };
    }
};

/// `name` with its first letter capitalized, as manifest keys are written.
fn capitalised(comptime name: []const u8) []const u8 {
    return .{std.ascii.toUpper(name[0])} ++ name[1..];
}

comptime {
    // Every object class has a script kind with the same name.
    for (std.enums.values(create.ShipCombat.Class)) |class| {
        if (!@hasField(Kind, @tagName(class))) @compileError("no kind of script for the class " ++ @tagName(class));
    }
}

test "Attachment.parse" {
    try std.testing.expectEqual(Attachment{ .kind = .load }, Attachment.parse("Load", "a").?);
    try std.testing.expectEqual(Attachment{ .kind = .fighter }, Attachment.parse("FIGHTER", "a").?);
    try std.testing.expectEqual(Attachment{ .object_type = .of(.predator) }, Attachment.parse("Type.predator", "a").?);
    try std.testing.expectEqual(Attachment{ .object_type = .of(.reliant) }, Attachment.parse("type.0x0C", "a").?);
    try std.testing.expectEqual(Attachment{ .object_type = @fromBackingInt(200) }, Attachment.parse("Type.200", "a").?);
    try std.testing.expectEqual(null, Attachment.parse("Loads", "a"));
    try std.testing.expectEqual(null, Attachment.parse("predator", "a"));
    // A ship type a mod adds, by its qualified name, or in its own mod by its own.
    var ships = [_]additions.ships.Added{.{ .name = "pot:teapot", .mod = "pot", .base = .predator, .extra = .{ .model = "teapot.shp" } }};
    additions.ships.install(&ships);
    defer additions.ships.reset();
    const teapot: Attachment = .{ .object_type = @fromBackingInt(additions.ships.first) };
    try std.testing.expectEqual(teapot, Attachment.parse("Type.pot:teapot", "a").?);
    try std.testing.expectEqual(teapot, Attachment.parse("Type.Teapot", "pot").?);
    try std.testing.expectEqual(null, Attachment.parse("Type.teapot", "a"));
    try std.testing.expectEqual(null, Attachment.parse("Type.nothing", "a"));
    try std.testing.expectEqual(Family.object, Attachment.parse("Missile", "a").?.family());
    try std.testing.expectEqual(Family.object, Attachment.parse("Type.reliant", "a").?.family());
}

test Kind {
    try std.testing.expectEqualStrings("Load", Kind.load.key());
    try std.testing.expectEqualStrings("Postprocessing", comptime capitalised("postprocessing"));
    try std.testing.expectEqual(create.ShipCombat.Class.mine, Kind.mine.class().?);
    try std.testing.expectEqual(null, Kind.missile.class());
}

test List {
    var list: List = .of(" a.luau, b.luau ,, c.luau ");
    for ([_][]const u8{ "a.luau", "b.luau", "c.luau" }) |name| try std.testing.expectEqualStrings(name, list.next().?);
    try std.testing.expectEqual(null, list.next());
}

test Handler {
    try std.testing.expect(Handler.on_records_loaded.givenBy(.load));
    try std.testing.expect(!Handler.on_update.givenBy(.load));
    try std.testing.expect(Handler.on_update.givenBy(.object));
    try std.testing.expect(!Handler.on_frame.givenBy(.global));
}

test Package {
    try std.testing.expectEqual(Package.records, Package.parse("openreliant.records").?);
    try std.testing.expectEqual(Package.async, Package.parse("openreliant.async").?);
    try std.testing.expectEqual(null, Package.parse("openreliant.nothing"));
    try std.testing.expectEqual(null, Package.parse("records"));
    try std.testing.expect(Package.records.reachableFrom(.load));
    try std.testing.expect(!Package.world.reachableFrom(.load));
}

test Offer {
    try std.testing.expect(Offer.engine_handlers.offeredBy(.load));
    try std.testing.expect(!Offer.interface.offeredBy(.load));
    try std.testing.expect(Offer.interface.offeredBy(.global));
}
