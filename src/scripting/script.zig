//! Definitions for mod scripts from the full design in
//! [#498](https://github.com/OpenReliant/openreliant/issues/498): the script kinds a manifest's
//! `[Scripts]` section accepts, the engine handlers each kind may use, and the packages each kind
//! may require. They cover the whole design so that scripts written now keep working as later
//! versions add features. `Kind.runs` and `Package.ready` say what this version supports.

const std = @import("std");

const openreliant = @import("openreliant");
const gameobj = openreliant.engine.game.gameobj;
const create = openreliant.engine.game.create;

/// The manifest section that lists a mod's scripts by kind.
pub const section = "Scripts";

/// The manifest section that assigns global scripts to mission files. Each runs while its mission
/// runs.
pub const missions_section = "Missions";

/// A key in `[Scripts]`: a script kind (`Kind.key`), or an object type written as `Type.` followed
/// by OpenReliant's name for it (`Type.predator`) or its number (`Type.12` or `Type.0x0C`).
pub const Attachment = union(enum) {
    kind: Kind,
    object_type: gameobj.Type,

    /// The prefix of keys that name an object type.
    pub const type_prefix = "Type.";

    /// Parses a key, ignoring case. Returns null for an unknown key.
    pub fn parse(key: []const u8) ?Attachment {
        if (key.len > type_prefix.len and std.ascii.eqlIgnoreCase(key[0..type_prefix.len], type_prefix)) {
            const named = key[type_prefix.len..];
            if (std.fmt.parseInt(u32, named, 0)) |number| return .{ .object_type = @enumFromInt(number) } else |_| {}
            inline for (comptime std.enums.values(gameobj.Type)) |object_type| {
                if (std.ascii.eqlIgnoreCase(named, @tagName(object_type))) return .{ .object_type = object_type };
            }
            return null;
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

    /// Whether this version runs scripts of this kind.
    pub fn runs(kind: Kind) bool {
        return switch (kind.family()) {
            .load, .global => true,
            .object, .player, .menu => false,
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
    on_viewport_resized,
    on_interface_override,

    /// Whether a script of `family` may use this handler.
    pub fn givenBy(handler: Handler, family: Family) bool {
        return switch (handler) {
            .on_init, .on_save, .on_load => family != .load,
            .on_records_loaded => family == .load,
            .on_update, .on_step => family == .global or family == .object,
            .on_frame, .on_key_press, .on_key_release, .on_action, .on_console_command, .on_viewport_resized => family == .player or family == .menu,
            .on_mission_start, .on_mission_end => family == .global or family == .player or family == .menu,
            .on_object_added, .on_object_removed => family == .global,
            .on_added, .on_removed => family == .object,
            .on_interface_override => family != .load,
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
            .core, .records, .storage, .interfaces, .util, .vfs => true,
            .hooks, .async => family != .load,
            .world => family == .global,
            .self => family == .object,
            .nearby => family == .object or family == .player,
            .orders => family == .global or family == .object,
            .hud, .camera, .postprocessing, .debug => family == .player,
            .ui, .input, .audio => family == .player or family == .menu,
            .shaders => family == .load or family == .player,
        };
    }

    /// Whether this version implements this package.
    pub fn ready(package: Package) bool {
        return switch (package) {
            .core, .records, .hooks => true,
            else => false,
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
    try std.testing.expectEqual(Attachment{ .kind = .load }, Attachment.parse("Load").?);
    try std.testing.expectEqual(Attachment{ .kind = .fighter }, Attachment.parse("FIGHTER").?);
    try std.testing.expectEqual(Attachment{ .object_type = .predator }, Attachment.parse("Type.predator").?);
    try std.testing.expectEqual(Attachment{ .object_type = .reliant }, Attachment.parse("type.0x0C").?);
    try std.testing.expectEqual(Attachment{ .object_type = @enumFromInt(200) }, Attachment.parse("Type.200").?);
    try std.testing.expectEqual(null, Attachment.parse("Loads"));
    try std.testing.expectEqual(null, Attachment.parse("predator"));
    try std.testing.expectEqual(null, Attachment.parse("Type.nothing"));
    try std.testing.expectEqual(Family.object, Attachment.parse("Missile").?.family());
    try std.testing.expectEqual(Family.object, Attachment.parse("Type.reliant").?.family());
}

test Kind {
    try std.testing.expectEqualStrings("Load", Kind.load.key());
    try std.testing.expectEqualStrings("Postprocessing", comptime capitalised("postprocessing"));
    try std.testing.expect(Kind.load.runs());
    try std.testing.expect(Kind.global.runs());
    try std.testing.expect(!Kind.player.runs());
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
    try std.testing.expect(Package.records.ready());
    try std.testing.expect(Package.hooks.ready());
    try std.testing.expect(!Package.world.ready());
}

test Offer {
    try std.testing.expect(Offer.engine_handlers.offeredBy(.load));
    try std.testing.expect(!Offer.interface.offeredBy(.load));
    try std.testing.expect(Offer.interface.offeredBy(.global));
}
