//! OpenReliant's: the records mods add, each family numbered after the game's records: ship types
//! ([#333](https://github.com/OpenReliant/openreliant/issues/333)), gun types, missile types and
//! pilots ([#640](https://github.com/OpenReliant/openreliant/issues/640)), and game variables
//! ([#1322](https://github.com/OpenReliant/openreliant/issues/1322)).
//!
//! A mod lists what it adds in its manifest, a section for each family, and describes each in a
//! section of its own, with one of the game's records as its base:
//!
//! ```ini
//! [Guns]
//! banana=20
//!
//! [Gun banana]
//! Base=pulse_cannon
//! Name=Banana Gun
//! ```
//!
//! - Each gets the next free number of its family as OpenReliant starts, mod by mod in load order,
//!   so the numbers depend on which mods are on. Scripts name each by its qualified name, such as
//!   `bananas:banana`, never by its number.
//! - Each acts as its base wherever the code singles one out (`gameobj.Type.base`,
//!   `guns.GunType.base`, `missiles.Type.base`), and starts with its base's records. A game
//!   variable has no base.
//! - The number after its name in the list is the number the mod's own files use for it: its
//!   missions for ship types, the carriers ships launch from, pilots and game variables, its
//!   models' muzzles for guns and their hardpoints for missiles. As OpenReliant loads one of the
//!   mod's files, it changes that number to the one the record got (`remapMission`,
//!   `remapModel`), so the files stay in the game's formats.
//! - A mod can list a record that a mod it requires adds, by its qualified name, with the number
//!   its own files use for it, so that its files can use that record too (`Family.Reference`):
//!
//! ```ini
//! [Mod]
//! Requires=realistic-planets
//!
//! [ShipTypes]
//! realistic-planets:mars=300
//! ```
//!
//! The lists are fixed once OpenReliant has started (`read`), and read from anywhere.
//!
//! **Improvement:** the original's records are its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const dte = @import("../../formats/dte.zig");
const shp = @import("../../formats/shp.zig");
const stats = @import("../../formats/stats.zig");
const wave = @import("../../formats/wave.zig");
const files = @import("../files.zig");
const gameobj = @import("gameobj.zig");
const guns_module = @import("guns.zig");
const missiles_module = @import("missiles.zig");
const pilots_module = @import("pilots.zig");
const loadout = @import("../interface/loadout/tables.zig");
const mods_module = @import("bigfile/mods.zig");
const vm = @import("../vm.zig");
const gameflow = @import("gameflow.zig");
const Mod = mods_module.Mod;

const log = std.log.scoped(.mods);

/// What a family of records is, whose base is one of the game's `Base`, and which has an `Extra`
/// each besides: what the log calls one, its manifest's sections, and its numbers.
pub fn Spec(comptime Base: type, comptime Extra: type) type {
    return struct {
        /// What the log calls one, such as `ship type`.
        noun: []const u8,
        /// The manifest's section that lists a mod's records, and the prefix of the section that
        /// describes each one.
        list_section: []const u8,
        item_section: []const u8,
        /// Its first number, the one after the game's last, and the number past its last.
        first: u32,
        end: u32,
        /// The least number the mod's own files can give one, where that is below `first`.
        own_first: ?u32 = null,
        /// How the manifest names the game's records that the family's records take as their base;
        /// null for a family whose records have no base, such as the game variables, which take
        /// `template`.
        bases: ?Bases(Base) = null,
        /// What the mod's own files that use the number after a record's name are, for the log.
        numbered_in: []const u8,
        /// The game's record one without a `Base` starts from, where the family takes one without:
        /// one the game singles out nowhere. Null where every record needs a `Base`.
        template: ?Base = null,
        /// Reads what a record has besides its base and its name from its section, or null where
        /// the section gets it wrong, which it logs.
        readExtra: ?fn (Context, []const u8, Base) Allocator.Error!?Extra = null,
    };
}

/// How a family's manifest names the game's records that its records take as their base
/// (`Spec.bases`).
pub fn Bases(comptime Base: type) type {
    return struct {
        /// The game's record that the manifest's text names.
        of: fn ([]const u8) ?Base,
        /// The number of one of the game's records.
        number: fn (Base) u32,
    };
}

/// What a family's `Spec.readExtra` reads with: the arena, the mod and its manifest, and the
/// record's own name, for the log.
pub const Context = struct {
    arena: Allocator,
    mod: Mod,
    own: []const u8,

    /// Logs that the record gets `problem` wrong.
    pub fn warn(context: Context, comptime noun: []const u8, comptime problem: []const u8, args: anytype) void {
        log.warn("{s}: {s}: the " ++ noun ++ " '{s}' " ++ problem, .{ context.mod.name, mods_module.manifest_name, context.own } ++ args);
    }
};

/// A family of records mods add, as `spec` describes it.
pub fn Family(comptime Base_: type, comptime Extra: type, comptime spec: Spec(Base_, Extra)) type {
    return struct {
        pub const first = spec.first;
        pub const end = spec.end;
        /// The most the mods can add.
        pub const capacity = end - first;
        pub const Base = Base_;

        /// A record a mod adds.
        pub const Added = struct {
            /// Its qualified name: the mod's (`Mod.qualifier`), a colon, and its own.
            name: []const u8,
            /// The name of the mod it comes from (`Mod.name`).
            mod: []const u8,
            /// The game's record it acts as, and starts from: the one its `Base` names, else the
            /// family's `Spec.template`.
            base: Base,
            /// Whether its manifest names a base. Without one, it takes only the template's
            /// records, and none of what the game gives the template in particular.
            based: bool = true,
            /// What the game calls it, else what it calls its base; and once the strings are read,
            /// the language string that holds it (`addNames`).
            label: ?[]const u8 = null,
            label_string: ?u16 = null,
            /// The number the mod's own files use for it, if they do.
            own_number: ?u32 = null,
            /// What its kind has besides, which every record must give (`{}` for a gun), so that
            /// none is left undefined.
            extra: Extra,

            /// Its name without the mod's, which can't hold a colon (`parse`).
            pub fn own(added: Added) []const u8 {
                return added.name[std.mem.findScalarLast(u8, added.name, ':').? + 1 ..];
            }
        };

        /// Another mod's record that a mod lists by its qualified name, from a mod it requires, so
        /// that its own files can use the record by the number it gives it.
        pub const Reference = struct {
            /// The record's qualified name.
            name: []const u8,
            /// The name of the mod that lists it (`Mod.name`), and the number that mod's files use.
            mod: []const u8,
            own_number: u32,
            /// The record's number.
            number: u32,
        };

        /// What the mods' manifests list: the records the mods add, in the order of their numbers,
        /// and the records of other mods they name.
        pub const Listed = struct {
            added: []Added,
            references: []Reference,
        };

        /// The records the mods add, in the order of their numbers; empty until `install`.
        var registered: []Added = &.{};
        /// The other mods' records the mods name; empty until `installReferences`.
        var referenced: []const Reference = &.{};

        /// Makes `list` the records the mods add, as OpenReliant starts. The list must outlive
        /// every use.
        pub fn install(list: []Added) void {
            assert(list.len <= capacity);
            registered = list;
        }

        /// Makes `list` the other mods' records that the mods name, as OpenReliant starts. The list
        /// must outlive every use.
        pub fn installReferences(list: []const Reference) void {
            referenced = list;
        }

        /// Lets go of the records, as a test ends.
        pub fn reset() void {
            registered = &.{};
            referenced = &.{};
        }

        pub fn all() []Added {
            return registered;
        }

        /// The record a mod adds of the number `number`, if there is one.
        pub fn get(number: u32) ?*const Added {
            return &registered[place(number) orelse return null];
        }

        /// Where the record a mod adds of the number `number` stands among the mods' records, and
        /// in any list kept beside them; null for a number no mod's record has.
        pub fn place(number: u32) ?usize {
            if (number < first or number - first >= registered.len) return null;
            return number - first;
        }

        /// The number of the record a mod adds called `name`, by its qualified name.
        pub fn find(name: []const u8) ?u32 {
            for (registered, first..) |each, number| {
                if (std.ascii.eqlIgnoreCase(each.name, name)) return @intCast(number);
            }
            return null;
        }

        /// How many numbers of the family have records: the game's, then the mods'.
        pub fn count() usize {
            return first + registered.len;
        }

        /// The number of the record the mod called `mod` gives the number `number` in its files:
        /// one it adds, or one of a mod it requires that it names.
        pub fn remapped(mod: []const u8, number: u32) ?u32 {
            for (registered, first..) |each, assigned| {
                if (each.own_number == number and std.mem.eql(u8, each.mod, mod)) return @intCast(assigned);
            }
            for (referenced) |each| {
                if (each.own_number == number and std.mem.eql(u8, each.mod, mod)) return each.number;
            }
            return null;
        }

        /// Whether the mod called `mod` gives any record of the family a number in its files
        /// (`remapped`).
        pub fn numbered(mod: []const u8) bool {
            for (registered) |each| if (each.own_number != null and std.mem.eql(u8, each.mod, mod)) return true;
            for (referenced) |each| if (std.mem.eql(u8, each.mod, mod)) return true;
            return false;
        }

        /// The number of what `text` names, for a record of the mod whose qualified names start
        /// with `mod` (`Mod.qualifier`): one of the game's by its name or number
        /// (`Spec.bases`), one the mods add by its qualified name, or one `mod` adds by its own
        /// name.
        pub fn named(text: []const u8, mod: []const u8) ?u32 {
            if (spec.bases) |bases| if (bases.of(text)) |base| return bases.number(base);
            if (find(text)) |number| return number;
            var buffer: [256]u8 = undefined;
            const qualified = std.mem.print(&buffer, "{s}:{s}", .{ mod, text }) catch return null;
            return find(qualified);
        }

        /// The records each mod in `mods` adds, and the records of the mods it requires that it
        /// names, as its manifest lists them, in load order. A record the manifest gets wrong is
        /// left out, which the log says, and so are those past `capacity`.
        pub fn read(arena: Allocator, mods: []const Mod) Allocator.Error!Listed {
            var list: std.ArrayList(Added) = .empty;
            var references: std.ArrayList(Reference) = .empty;
            var full = false;
            for (mods) |mod| {
                var listed = mod.manifest.keys(spec.list_section);
                while (listed.next()) |own| {
                    const context: Context = .{ .arena = arena, .mod = mod, .own = own };
                    if (std.mem.findScalar(u8, own, ':') != null) {
                        const reference = refer(context, list.items, references.items) orelse continue;
                        try references.append(arena, reference);
                        continue;
                    }
                    if (full) continue;
                    if (list.items.len == capacity) {
                        log.warn("{s}: {s}: more than {d} of the mods' {s}s, so the rest are left out", .{ mod.name, mods_module.manifest_name, capacity, spec.noun });
                        full = true;
                        continue;
                    }
                    const made = try parse(context, list.items, references.items) orelse continue;
                    try list.append(arena, made);
                }
            }
            return .{ .added = list.items, .references = references.items };
        }

        /// The name of what the mod called `mod` already gives the number `number` in its files,
        /// of `added` and `references`, if anything.
        fn holder(mod: []const u8, number: u32, added: []const Added, references: []const Reference) ?[]const u8 {
            for (added) |each| if (std.mem.eql(u8, each.mod, mod) and each.own_number == number) return each.own();
            for (references) |each| if (std.mem.eql(u8, each.mod, mod) and each.own_number == number) return each.name;
            return null;
        }

        /// The number `text` that the list section gives `context.own` for the mod's files, or null
        /// where it isn't one of the family's, or the mod already gives it to something else in
        /// `added` or `references`, which the log says.
        fn ownNumber(context: Context, text: []const u8, added: []const Added, references: []const Reference) ?u32 {
            const number = std.fmt.parseInt(u32, text, 0) catch 0;
            const least = spec.own_first orelse first;
            if (number < least or number >= end) {
                context.warn(spec.noun, "gives " ++ spec.numbered_in ++ " the number {s}, which isn't from {d} to {d}", .{ text, least, end - 1 });
                return null;
            }
            if (holder(context.mod.name, number, added, references)) |name| {
                context.warn(spec.noun, "gives " ++ spec.numbered_in ++ " the same number as '{s}'", .{name});
                return null;
            }
            return number;
        }

        /// The record of another mod that `context.own` names by its qualified name, for the
        /// number the list section gives it, or null where the mod doesn't require that mod, that
        /// mod doesn't add it, or the number isn't one it can give, which the log says. `added`
        /// holds the records read before, which hold every record of the mods it requires, as
        /// those load before it, and `references` the records of other mods named before.
        fn refer(context: Context, added: []const Added, references: []const Reference) ?Reference {
            const own = context.own;
            const colon = std.mem.findScalarLast(u8, own, ':').?;
            const owner = own[0..colon];
            var needed = context.mod.requirements();
            const required = while (needed.next()) |name| {
                if (std.ascii.eqlIgnoreCase(name, owner)) break true;
            } else false;
            if (!required) {
                context.warn(spec.noun, "is another mod's, and Requires doesn't list '{s}'", .{owner});
                return null;
            }
            const number = for (added, first..) |each, at| {
                if (std.ascii.eqlIgnoreCase(each.name, own)) break at;
            } else {
                context.warn(spec.noun, "isn't one that '{s}' adds", .{owner});
                return null;
            };
            const number_text = std.mem.trim(u8, context.mod.manifest.value(spec.list_section, own) orelse "", " \t");
            if (number_text.len == 0) {
                context.warn(spec.noun, "needs the number " ++ spec.numbered_in ++ " use for it", .{});
                return null;
            }
            const own_number = ownNumber(context, number_text, added, references) orelse return null;
            return .{ .name = added[number - first].name, .mod = context.mod.name, .own_number = own_number, .number = @intCast(number) };
        }

        /// The record `context.own` of `context.mod`, as its manifest describes it, or null
        /// where it gets it wrong, which the log says. `earlier` holds the records read before
        /// it, and `references` the records of other mods named before it.
        fn parse(context: Context, earlier: []const Added, references: []const Reference) Allocator.Error!?Added {
            const manifest = context.mod.manifest;
            const own = context.own;
            if (own.len == 0 or std.mem.findAny(u8, own, ": ") != null) {
                context.warn(spec.noun, "needs a name without spaces or colons", .{});
                return null;
            }
            const name = try context.arena.print("{s}:{s}", .{ context.mod.qualifier(), own });
            for (earlier) |each| if (std.ascii.eqlIgnoreCase(each.name, name)) {
                context.warn(spec.noun, "is listed twice", .{});
                return null;
            };
            const section = try context.arena.print("{s}{s}", .{ spec.item_section, own });
            const base_text = if (spec.bases == null) null else manifest.value(section, "Base");
            const base = if (base_text) |text| spec.bases.?.of(text) orelse {
                context.warn(spec.noun, "has the base '{s}', which isn't one of the game's", .{text});
                return null;
            } else spec.template orelse {
                context.warn(spec.noun, "needs a Base in [{s}]", .{section});
                return null;
            };
            const extra: Extra = if (spec.readExtra) |readExtra| try readExtra(context, section, base) orelse return null else {};
            var made: Added = .{
                .name = name,
                .mod = context.mod.name,
                .base = base,
                .based = base_text != null,
                .label = if (manifest.value(section, "Name")) |text| try context.arena.dupe(u8, text) else null,
                .extra = extra,
            };
            const number_text = std.mem.trim(u8, manifest.value(spec.list_section, own) orelse "", " \t");
            if (number_text.len > 0) made.own_number = ownNumber(context, number_text, earlier, references) orelse return null;
            return made;
        }

        /// The game's records `game`, the first of which has the number `numbered_from`, followed
        /// by a copy of its base's for each record the mods add: filled out with zeros up to
        /// `first` where the game has fewer, so that each record's place is its number less
        /// `numbered_from`.
        pub fn records(comptime Record: type, arena: Allocator, game: []align(1) const Record, comptime numbered_from: u32) Allocator.Error![]Record {
            const own_count = first - numbered_from;
            const made = try arena.alloc(Record, own_count + registered.len);
            const kept = @min(game.len, own_count);
            for (made[0..kept], game[0..kept]) |*record, from| record.* = from;
            @memset(made[kept..own_count], std.mem.zeroes(Record));
            for (made[own_count..], registered) |*record, each| record.* = made[spec.bases.?.number(each.base) - numbered_from];
            return made;
        }
    };
}

/// A name of the game's records, by the tags of `Named`: a tag of it whose number is below
/// `below`, or a number below `below`.
fn gameNamed(comptime Named: type, text: []const u8, comptime below: comptime_int) ?Named {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (std.fmt.parseInt(u32, trimmed, 0)) |number| {
        if (number >= below) return null;
        return std.enums.fromInt(Named, number);
    } else |_| {}
    inline for (comptime std.enums.values(Named)) |each| {
        if (@backingInt(each) >= 0 and @backingInt(each) < below and std.ascii.eqlIgnoreCase(trimmed, @tagName(each))) return each;
    }
    return null;
}

/// What a ship type has besides its base and its name. Where the manifest leaves one out, the
/// ship type takes its base's:
/// - its model, and the schematic the display shows of it;
/// - the model the loadout's guns view shows (`loadout.tables.modRecord`), or its own model
///   without a base;
/// - the gun every muzzle of its model fires and the missile every hardpoint holds, or those its
///   model names;
/// - when the player flies it: its cockpit's model, the pictures for its wire frame on the gunnery
///   display and its icon in the wing's window, by the name their files start with
///   (`hud.Art.Pictures`), and its engine's sound, a WAV file's bytes.
pub const ShipExtra = struct {
    model: []const u8,
    schematic: ?[]const u8 = null,
    guns_model: ?[]const u8 = null,
    gun: ?guns_module.GunType = null,
    missile: ?missiles_module.Type = null,
    cockpit: ?[]const u8 = null,
    wire_frame: ?[]const u8 = null,
    wing_icon: ?[]const u8 = null,
    engine_sound: ?[]const u8 = null,
    /// The campaign tier from which the loadout screen offers it; without one, 0, the start of the
    /// campaign (`loadout.tables.offers`).
    tier: ?u2 = null,
    /// Whether it carries blind fire and spectral shields when the player flies it
    /// (`main.playerShip`). Without the keys, it carries what its base carries, or neither
    /// without a base.
    blind_fire: ?bool = null,
    spectral_shields: ?bool = null,
    /// What the loadout's panel shows for it (`loadout.tables.Ship`). Without the keys, the panel
    /// shows its base's, or `default_class`, `default_access` and `default_crew` without a base.
    class: ?loadout.Class = null,
    access: ?loadout.Access = null,
    crew: ?u8 = null,

    /// What the loadout's panel shows for a ship type without a base, unless its manifest says.
    pub const default_class: loadout.Class = .light;
    pub const default_access: loadout.Access = .bronze;
    pub const default_crew: u8 = 1;
};

fn readShip(context: Context, section: []const u8, base: gameobj.GameType) Allocator.Error!?ShipExtra {
    const manifest = context.mod.manifest;
    const model = manifest.value(section, "Model") orelse {
        context.warn("ship type", "needs a Model in [{s}]", .{section});
        return null;
    };
    var made: ShipExtra = .{ .model = try fileName(context, model) };
    if (manifest.value(section, "Cockpit")) |text| made.cockpit = try fileName(context, text);
    if (manifest.value(section, "WireFrame")) |text| made.wire_frame = try context.arena.dupe(u8, files.stem(text));
    if (manifest.value(section, "WingIcon")) |text| made.wing_icon = try context.arena.dupe(u8, files.stem(text));
    if (manifest.value(section, "EngineSound")) |name| made.engine_sound = try readSound(context, "ship type", name) orelse return null;
    if (manifest.value(section, "Tier")) |text| made.tier = readNumber(u2, context, "ship type", "Tier", text) orelse return null;
    if (manifest.value(section, "BlindFire")) |text| made.blind_fire = readSwitch(context, "ship type", "BlindFire", text) orelse return null;
    if (manifest.value(section, "SpectralShields")) |text| made.spectral_shields = readSwitch(context, "ship type", "SpectralShields", text) orelse return null;
    if (manifest.value(section, "Class")) |text| made.class = readNamed(loadout.Class, context, "Class", text) orelse return null;
    if (manifest.value(section, "Access")) |text| made.access = readNamed(loadout.Access, context, "Access", text) orelse return null;
    if (manifest.value(section, "Crew")) |text| made.crew = readNumber(u8, context, "ship type", "Crew", text) orelse return null;
    if (manifest.value(section, "Schematic")) |text| made.schematic = try fileName(context, text);
    if (manifest.value(section, "GunsModel")) |text| made.guns_model = try fileName(context, text);
    if (manifest.value(section, "Guns")) |text| {
        const number = guns.named(text, context.mod.qualifier()) orelse {
            context.warn("ship type", "fires the gun '{s}', which isn't one of the game's or the mods'", .{text});
            return null;
        };
        made.gun = @fromBackingInt(@intCast(number));
    }
    if (manifest.value(section, "Missiles")) |text| {
        const number = missiles.named(text, context.mod.qualifier()) orelse {
            context.warn("ship type", "carries the missile '{s}', which isn't one of the game's or the mods'", .{text});
            return null;
        };
        made.missile = @fromBackingInt(@intCast(number));
    }
    // A type based on a ship the player can't fly is flown only with a cockpit of its own
    // (`main.playerShip`), so without one, what it gives for the player's ship goes unused.
    if (made.cockpit == null and !base.playerFlies()) {
        for ([_][]const u8{ "WireFrame", "WingIcon", "BlindFire", "SpectralShields" }) |key| {
            if (manifest.value(section, key) != null) context.warn("ship type", "gives {s}, which a ship the player can't fly uses only with a Cockpit", .{key});
        }
    }
    return made;
}

/// What a missile type has besides: the model it flies as, and for a missile whose base hangs in a
/// pod, the pod's model; each else its base's. And for the loadout screen: the campaign tier from
/// which it offers it, else its base's, and what its panel says of it, under its own name where it
/// has one (`addNames`), else what it says of its base.
pub const MissileExtra = struct {
    model: ?[]const u8 = null,
    pod: ?[]const u8 = null,
    tier: ?u2 = null,
    description: ?[]const u8 = null,
    description_string: ?u16 = null,
};

fn readMissile(context: Context, section: []const u8, _: missiles_module.GameMissile) Allocator.Error!?MissileExtra {
    const manifest = context.mod.manifest;
    var made: MissileExtra = .{};
    if (manifest.value(section, "Model")) |model| made.model = try fileName(context, model);
    if (manifest.value(section, "Pod")) |pod| made.pod = try fileName(context, pod);
    if (manifest.value(section, "Description")) |text| made.description = try context.arena.dupe(u8, text);
    if (manifest.value(section, "Tier")) |text| made.tier = readNumber(u2, context, "missile", "Tier", text) orelse return null;
    return made;
}

/// The file `text` names, by its own name: a mod's files sit directly in it, so a folder in front
/// of the name, with either separator, is passed over, the same way on every system. Pictures and
/// films go by their names' start instead (`files.stem`).
fn fileName(context: Context, text: []const u8) Allocator.Error![]const u8 {
    return context.arena.dupe(u8, files.leaf(text));
}

/// `text` as a switch of a record of `noun`: `yes`, `true`, `on` or `1`, or `no`, `false`, `off`
/// or `0`, in any case; null where it is none of them, which the log says.
fn readSwitch(context: Context, comptime noun: []const u8, comptime key: []const u8, text: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, text, " \t");
    for ([_][]const u8{ "yes", "true", "on", "1" }) |word| if (std.ascii.eqlIgnoreCase(trimmed, word)) return true;
    for ([_][]const u8{ "no", "false", "off", "0" }) |word| if (std.ascii.eqlIgnoreCase(trimmed, word)) return false;
    context.warn(noun, "gives " ++ key ++ " the value '{s}', which isn't yes or no", .{text});
    return null;
}

/// `text` as a value of `Named`, by its name in any case or by its number (`gameNamed`); null
/// where it is neither, which the log says with the names it takes.
fn readNamed(comptime Named: type, context: Context, comptime key: []const u8, text: []const u8) ?Named {
    const end = std.math.maxInt(@typeInfo(Named).@"enum".tag_type) + 1;
    if (gameNamed(Named, text, end)) |named| return named;
    const names = comptime names: {
        var list: []const u8 = "";
        for (@typeInfo(Named).@"enum".field_names, 0..) |name, at| list = list ++ (if (at == 0) "" else ", ") ++ name;
        break :names list;
    };
    context.warn("ship type", "gives " ++ key ++ " the value '{s}', which isn't one of " ++ names, .{text});
    return null;
}

/// `text` as the whole number of `T` that a record of `noun` gives its `key`, such as a campaign
/// tier, a `u2`; null where it isn't one, which the log says with the numbers `T` holds.
fn readNumber(comptime T: type, context: Context, comptime noun: []const u8, comptime key: []const u8, text: []const u8) ?T {
    return std.fmt.parseInt(T, std.mem.trim(u8, text, " \t"), 0) catch {
        context.warn(noun, "gives " ++ key ++ " the value '{s}', which isn't a whole number from {d} to {d}", .{ text, std.math.minInt(T), std.math.maxInt(T) });
        return null;
    };
}

/// The ship types mods add, from 256 to the markers (`GameType.sun_marker`).
pub const ships = Family(gameobj.GameType, ShipExtra, .{
    .noun = "ship type",
    .list_section = "ShipTypes",
    .item_section = "ShipType ",
    .first = 0x100,
    .end = @backingInt(gameobj.GameType.sun_marker),
    .bases = .{
        .of = struct {
            fn of(text: []const u8) ?gameobj.GameType {
                return gameNamed(gameobj.GameType, text, 0x100);
            }
        }.of,
        .number = struct {
            fn number(base: gameobj.GameType) u32 {
                return @backingInt(base);
            }
        }.number,
    },
    .numbered_in = "its missions",
    // A fighter the game singles out nowhere.
    .template = .predator,
    .readExtra = readShip,
});

/// What a gun type has besides, each else its base's: the picture its shots are drawn with, by its
/// texture's name, as one flare `shot_size` across either way of its middle; the sound a shot
/// makes, a WAV file's bytes; and the picture its muzzle flash is drawn with, by its texture's
/// name, `flash_size` long, else as long as its base's
/// ([#675](https://github.com/OpenReliant/openreliant/issues/675)).
pub const GunExtra = struct {
    shot: ?[]const u8 = null,
    shot_size: f32 = default_shot_size,
    sound: ?[]const u8 = null,
    flash: ?[]const u8 = null,
    flash_size: ?f32 = null,

    /// How far a shot's picture reaches either way of its middle, without `ShotSize`: the Pulse
    /// Cannon's flare's.
    pub const default_shot_size: f32 = 60;
};

fn readGun(context: Context, section: []const u8, _: guns_module.GameGun) Allocator.Error!?GunExtra {
    const manifest = context.mod.manifest;
    var made: GunExtra = .{};
    // A picture is found by its texture's name, as the mods' pictures are (`srtexture.Files`).
    if (manifest.value(section, "Shot")) |name| made.shot = try context.arena.dupe(u8, files.stem(name));
    if (manifest.value(section, "ShotSize")) |text| made.shot_size = readSize(context, "shot", text) orelse return null;
    if (manifest.value(section, "Flash")) |name| made.flash = try context.arena.dupe(u8, files.stem(name));
    if (manifest.value(section, "FlashSize")) |text| made.flash_size = readSize(context, "flash", text) orelse return null;
    if (manifest.value(section, "Sound")) |name| made.sound = try readSound(context, "gun", name) orelse return null;
    return made;
}

/// The size `text` gives a gun's `what`, a number above zero; null where it isn't one, which the
/// log says.
fn readSize(context: Context, comptime what: []const u8, text: []const u8) ?f32 {
    const size = std.fmt.parseFloat(f32, std.mem.trim(u8, text, " \t")) catch 0;
    if (size > 0) return size;
    context.warn("gun", "gives the " ++ what ++ " size '{s}', which isn't a size", .{text});
    return null;
}

/// The bytes of the WAV file `name` in the mod, found by its own name (`fileName`), for a record of
/// `noun`; null where the mod doesn't have it or it isn't a WAV file the sound plays, which the log
/// says.
fn readSound(context: Context, comptime noun: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    const bytes = context.mod.readFile(context.arena, files.leaf(name)) catch |err| switch (err) {
        error.OutOfMemory => |oom| return oom,
        else => null,
    } orelse {
        context.warn(noun, "sounds as {s}, which the mod doesn't have", .{name});
        return null;
    };
    _ = wave.Wave.parse(bytes) catch {
        context.warn(noun, "sounds as {s}, which isn't a WAV file of PCM or IMA ADPCM", .{name});
        return null;
    };
    return bytes;
}

/// The gun types mods add, after the game's 15, up to the most a muzzle's byte holds.
pub const guns = Family(guns_module.GameGun, GunExtra, .{
    .noun = "gun",
    .list_section = "Guns",
    .item_section = "Gun ",
    .first = guns_module.max_types,
    .end = std.math.maxInt(u8) + 1,
    .bases = .{
        .of = struct {
            fn of(text: []const u8) ?guns_module.GameGun {
                const trimmed = std.mem.trim(u8, text, " \t");
                if (std.fmt.parseInt(u32, trimmed, 0)) |number| {
                    if (number == 0 or number >= guns_module.max_types) return null;
                    return @fromBackingInt(@intCast(number - 1));
                } else |_| {}
                return gameNamed(guns_module.GameGun, trimmed, guns_module.max_types);
            }
        }.of,
        .number = struct {
            fn number(base: guns_module.GameGun) u32 {
                return base.number();
            }
        }.number,
    },
    .readExtra = readGun,
    .numbered_in = "its models' muzzles",
});

/// The missile types mods add, after the game's 11.
pub const missiles = Family(missiles_module.GameMissile, MissileExtra, .{
    .noun = "missile",
    .list_section = "Missiles",
    .item_section = "Missile ",
    .first = missiles_module.type_count,
    .end = std.math.maxInt(u8) + 1,
    .bases = .{
        .of = struct {
            fn of(text: []const u8) ?missiles_module.GameMissile {
                const base = gameNamed(missiles_module.GameMissile, text, missiles_module.type_count) orelse return null;
                return if (base == .none) null else base;
            }
        }.of,
        .number = struct {
            fn number(base: missiles_module.GameMissile) u32 {
                return @intCast(@backingInt(base));
            }
        }.number,
    },
    .numbered_in = "its models' hardpoints",
    .readExtra = readMissile,
});

/// What a pilot has besides: its face, its base's, under its own name where it has one
/// (`addNames`).
pub const PilotExtra = struct {
    face: pilots_module.Face,
};

/// A pilot's face, its base's but for the films and the voice its section gives: `Talking`,
/// `Laughing` and `Dying` name the films its face plays (`pilots\<film>.fm8`, which a mod gives as
/// `<film>.fm8`), and `Voice` the start of its lines' names.
fn readPilot(context: Context, section: []const u8, base: u8) Allocator.Error!?PilotExtra {
    const manifest = context.mod.manifest;
    var face = pilots_module.faces[base];
    const film_keys = [_]struct { []const u8, pilots_module.Head }{ .{ "Talking", .talking }, .{ "Laughing", .laughing }, .{ "Dying", .dying } };
    for (film_keys) |entry| {
        const key, const head = entry;
        const film = manifest.value(section, key) orelse continue;
        face.films[@backingInt(head)] = try context.arena.dupe(u8, files.stem(film));
    }
    if (manifest.value(section, "Voice")) |voice| face.own_voice = try context.arena.dupe(u8, std.mem.trim(u8, voice, " \t"));
    return .{ .face = face };
}

/// The pilots mods add, after the game's 194, up to the one a mission's ship record keeps for
/// none (`dte.Ship.no_pilot`).
pub const pilots = Family(u8, PilotExtra, .{
    .noun = "pilot",
    .list_section = "Pilots",
    .item_section = "Pilot ",
    .first = pilots_module.Table.count,
    .end = dte.Ship.no_pilot,
    .bases = .{
        .of = struct {
            fn of(text: []const u8) ?u8 {
                const number = std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t"), 0) catch return null;
                return if (number < pilots_module.Table.count) number else null;
            }
        }.of,
        .number = struct {
            fn number(base: u8) u32 {
                return base;
            }
        }.number,
    },
    .numbered_in = "its missions",
    .readExtra = readPilot,
});

/// A game variable's record (`gameflow.VariableRecord`) from its section: `Start`, the value a new
/// campaign gives it, 0 without it; `Attempt`, the value each attempt at a mission starts it at,
/// none without it, so that the campaign keeps it from one mission to the next; and `Saved`,
/// whether a saved game keeps it, yes without it.
fn readVariable(context: Context, section: []const u8, _: void) Allocator.Error!?gameflow.VariableRecord {
    const manifest = context.mod.manifest;
    var made: gameflow.VariableRecord = .{ .start = 0, .saved = true };
    if (manifest.value(section, "Start")) |text| made.start = readNumber(i32, context, "game variable", "Start", text) orelse return null;
    if (manifest.value(section, "Attempt")) |text| made.attempt = readNumber(i32, context, "game variable", "Attempt", text) orelse return null;
    if (manifest.value(section, "Saved")) |text| made.saved = readSwitch(context, "game variable", "Saved", text) orelse return null;
    return made;
}

/// The game variables mods add, past the original's block of 64 up to the last number a script's
/// byte names (`vm.Variables`). A mod's missions can also number them from the block's spare
/// variables on, which neither the engine nor the shipped missions use, so that the missions run in
/// the original too.
pub const variables = Family(void, gameflow.VariableRecord, .{
    .noun = "game variable",
    .list_section = "GameVariables",
    .item_section = "GameVariable ",
    .first = vm.Variables.block_size,
    .end = vm.Variables.count,
    .own_first = vm.Variables.number("spare"),
    .numbered_in = "its missions",
    .template = {},
    .readExtra = readVariable,
});

/// Reads what each mod in `mods` adds, and the records of other mods it names, family by family,
/// in load order, as OpenReliant starts: the guns, missiles and pilots before the ship types, which
/// can name them, then the game variables.
pub fn read(arena: Allocator, mods: []const Mod) Allocator.Error!void {
    inline for (.{ guns, missiles, pilots, ships, variables }) |family| {
        const listed = try family.read(arena, mods);
        family.install(listed.added);
        family.installReferences(listed.references);
    }
}

/// Lets go of every family, as a test ends.
pub fn reset() void {
    ships.reset();
    guns.reset();
    missiles.reset();
    pilots.reset();
    variables.reset();
}

/// The game's strings `text`, then the name of each record the mods add that has one, which each
/// keeps (`label_string`). A string's id is its place from 1; past the ids a word holds, a record
/// keeps its base's name.
pub fn addNames(arena: Allocator, text: []const []const u8) Allocator.Error![]const []const u8 {
    var made: std.ArrayList([]const u8) = .empty;
    try made.appendSlice(arena, text);
    inline for (.{ ships, guns, missiles, pilots }) |family| {
        for (family.all()) |*each| {
            const label = each.label orelse continue;
            try made.append(arena, label);
            each.label_string = std.math.cast(u16, made.items.len);
        }
    }
    for (pilots.all()) |*each| if (each.label_string) |name| {
        each.extra.face.name = name;
    };
    for (missiles.all()) |*each| if (each.extra.description) |description| {
        try made.append(arena, description);
        each.extra.description_string = std.math.cast(u16, made.items.len);
    };
    return made.items;
}

/// Replaces the numbers that the mod called `mod` gives the records it adds, or names, in the
/// mission `image`, with the numbers they got: in its ship records, each ship's type, the type of
/// the carrier it launches from, and its pilot; in its script, the game variables
/// (`remapVariables`). A mission that can't be read is left as it is, to fail as it loads.
pub fn remapMission(gpa: Allocator, image: []u8, mod: []const u8) Allocator.Error!void {
    const mission = dte.Mission.parse(image) catch return;
    remapShips(image, mission, mod);
    try remapVariables(gpa, image, mission, mod);
}

/// Replaces the numbers that the mod called `mod` gives the ship types and pilots it adds, or
/// names, in the ship records of the mission `image`.
fn remapShips(image: []u8, mission: dte.Mission, mod: []const u8) void {
    const records = mission.ships() catch return;
    const start = (mission.span(.ships) catch return orelse return).offset;
    for (records, 0..) |record, at| {
        const place = start + at * @sizeOf(dte.Ship);
        if (ships.remapped(mod, record.kind)) |number| {
            std.mem.writeInt(u16, image[place + @offsetOf(dte.Ship, "kind") ..][0..2], @intCast(number), .little);
        }
        // The launch looks for the first ship of this type, so a mod's carrier type needs the
        // same number here as in the carrier's own record.
        if (ships.remapped(mod, record.launch_from)) |number| {
            std.mem.writeInt(u16, image[place + @offsetOf(dte.Ship, "launch_from") ..][0..2], @intCast(number), .little);
        }
        if (pilots.remapped(mod, record.pilot)) |number| image[place + @offsetOf(dte.Ship, "pilot")] = @intCast(number);
    }
}

/// Replaces the numbers that the mod called `mod` gives the game variables it adds, or names, in
/// the script of the mission `image`, with the numbers they got: the operand of each `push_array`
/// and `select_array` that its parts and its triggers' blocks reach.
fn remapVariables(gpa: Allocator, image: []u8, mission: dte.Mission, mod: []const u8) Allocator.Error!void {
    if (!variables.numbered(mod)) return;
    const script = mission.script() catch return;
    const offset = (mission.span(.script) catch return orelse return).offset;
    const routines = mission.routines(gpa) catch |err| switch (err) {
        error.OutOfMemory => |oom| return oom,
        else => return,
    };
    defer gpa.free(routines);
    // A block more than one routine runs is read once, so its variables change once.
    var blocks: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, script.len);
    defer blocks.deinit(gpa);
    for (routines) |routine| {
        if (routine.start >= script.len or blocks.isSet(routine.start)) continue;
        blocks.set(routine.start);
        const listing = try dte.disassemble(gpa, script, routine.start) orelse continue;
        defer gpa.free(listing.instructions);
        for (listing.instructions) |instruction| switch (instruction.opcode) {
            .push_array, .select_array => if (variables.remapped(mod, instruction.operands[0])) |number| {
                image[offset + instruction.address + 1] = @intCast(number);
            },
            else => {},
        };
    }
}

/// Changes the numbers the mod called `mod` gives the guns and missiles it adds in a model of its
/// own, `parts`: its muzzles' guns, and its hardpoints' missiles for every loadout tier.
pub fn remapModel(parts: []const shp.PartData, mod: []const u8) void {
    for (parts) |part| for (part.attachments) |*attachment| switch (attachment.kind) {
        .gun_muzzle => if (guns.remapped(mod, attachment.gun_type)) |number| {
            attachment.gun_type = number;
        },
        .missile => {
            if (missiles.remapped(mod, attachment.id)) |number| attachment.id = number;
            for (&attachment.later_tiers) |*word| {
                const low: u16 = @truncate(word.*);
                if (missiles.remapped(mod, low)) |number| word.* = (word.* & 0xFFFF_0000) | number;
            }
        },
        else => {},
    };
}

test "a family reads what each mod lists" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const manifest =
        \\[Guns]
        \\banana=20
        \\[Gun banana]
        \\Base=pulse_cannon
        \\Name=Banana Gun
        \\Shot=art\peel_shot.png
        \\Flash=fx/peel_flash.png
        \\[Missiles]
        \\banana=30
        \\late=
        \\[Missile banana]
        \\Base=raptor
        \\Model=banana.shp
        \\Pod=bunch.shp
        \\Description=Yellow.
        \\Tier= 2
        \\[Missile late]
        \\Base=raptor
        \\Tier=4
        \\[Pilots]
        \\trooper=200
        \\[Pilot trooper]
        \\Base=0
        \\Talking=pilots\trooper.fm8
        \\Dying=trooper_d
        \\Voice=trp
        \\[ShipTypes]
        \\teapot=300
        \\kettle=
        \\bad name=
        \\nobase=
        \\wrong=
        \\[ShipType teapot]
        \\Base=predator
        \\Model=teapot.shp
        \\WireFrame=art\teapotwire.png
        \\WingIcon=art/teapoticon
        \\Name=Teapot
        \\Guns=banana
        \\Missiles=bananas:banana
        \\[ShipType kettle]
        \\base=0x0B
        \\model=kettle.shp
        \\Guns=nova_cannon
        \\[ShipType nobase]
        \\Model=x.shp
        \\GunsModel=x_gun.shp
        \\BlindFire=Yes
        \\SpectralShields=off
        \\Class=Light_Medium
        \\Access=gold
        \\Crew=2
        \\[ShipType wrong]
        \\Base=predator
        \\Model=y.shp
        \\Class=enormous
    ;
    // An archive's qualified names leave out `.hog`.
    const mod: Mod = .{ .name = "bananas.HOG", .source = undefined, .manifest = .{ .text = manifest } };
    try read(arena.allocator(), &.{mod});
    defer reset();

    try std.testing.expectEqual(1, guns.all().len);
    try std.testing.expectEqualStrings("bananas:banana", guns.all()[0].name);
    try std.testing.expectEqual(guns_module.GameGun.pulse_cannon, guns.all()[0].base);
    try std.testing.expectEqual(20, guns.all()[0].own_number.?);
    try std.testing.expectEqual(guns.first, guns.find("bananas:banana").?);
    // A picture or a film is named by its file's name, whatever folder the manifest gives it in.
    try std.testing.expectEqualStrings("peel_shot", guns.all()[0].extra.shot.?);
    try std.testing.expectEqualStrings("peel_flash", guns.all()[0].extra.flash.?);
    try std.testing.expectEqualStrings("banana.shp", missiles.all()[0].extra.model.?);
    try std.testing.expectEqualStrings("bunch.shp", missiles.all()[0].extra.pod.?);
    try std.testing.expectEqualStrings("Yellow.", missiles.all()[0].extra.description.?);
    try std.testing.expectEqual(2, missiles.all()[0].extra.tier.?);
    // A tier past the campaign's last is left out, with the missile.
    try std.testing.expectEqual(1, missiles.all().len);
    try std.testing.expectEqual(0, pilots.all()[0].base);
    // Its own films and voice, and its base's films for the rest.
    const face = pilots.all()[0].extra.face;
    try std.testing.expectEqualStrings("trooper", face.film(.talking).?);
    try std.testing.expectEqualStrings("trooper_d", face.film(.dying).?);
    try std.testing.expectEqualStrings(pilots_module.faces[0].film(.laughing).?, face.film(.laughing).?);
    try std.testing.expectEqualStrings("trp", face.own_voice.?);

    // A ship type with a class that isn't one is left out.
    const list = ships.all();
    try std.testing.expectEqual(3, list.len);
    try std.testing.expectEqualStrings("bananas:teapot", list[0].name);
    try std.testing.expectEqualStrings("teapot", list[0].own());
    try std.testing.expectEqual(gameobj.GameType.predator, list[0].base);
    try std.testing.expectEqualStrings("Teapot", list[0].label.?);
    try std.testing.expectEqualStrings("teapotwire", list[0].extra.wire_frame.?);
    try std.testing.expectEqualStrings("teapoticon", list[0].extra.wing_icon.?);
    try std.testing.expectEqual(300, list[0].own_number.?);
    try std.testing.expectEqual(guns.first, list[0].extra.gun.?.number());
    try std.testing.expectEqual(missiles.first, list[0].extra.missile.?.index().?);
    try std.testing.expectEqual(gameobj.GameType.phoenix, list[1].base);
    try std.testing.expectEqual(guns_module.GunType.of(.nova_cannon), list[1].extra.gun.?);
    try std.testing.expectEqual(null, list[1].own_number);
    try std.testing.expectEqual(ships.first + 1, ships.find("BANANAS:kettle").?);
    try std.testing.expectEqualStrings("bananas:teapot", ships.get(ships.first).?.name);
    try std.testing.expect(list[0].based);
    // Without a base, the template, and the devices and figures it gives.
    try std.testing.expectEqual(gameobj.GameType.predator, list[2].base);
    try std.testing.expect(!list[2].based);
    try std.testing.expect(list[2].extra.blind_fire.?);
    try std.testing.expect(!list[2].extra.spectral_shields.?);
    try std.testing.expectEqual(loadout.Class.light_medium, list[2].extra.class.?);
    try std.testing.expectEqual(loadout.Access.gold, list[2].extra.access.?);
    try std.testing.expectEqual(2, list[2].extra.crew.?);
    try std.testing.expectEqualStrings("x_gun.shp", list[2].extra.guns_model.?);
    try std.testing.expectEqual(null, list[0].extra.class);
    try std.testing.expectEqual(null, ships.get(ships.first + 3));
    try std.testing.expectEqual(null, ships.get(0x0B));
    try std.testing.expectEqual(ships.first + 3, ships.count());
}

test "a type based on a ship the player can't fly, with and without a cockpit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mod: Mod = .{ .name = "red", .source = undefined, .manifest = .{ .text =
        \\[ShipTypes]
        \\red_basilisk=300
        \\grey_basilisk=301
        \\[ShipType red_basilisk]
        \\Base=basilisk
        \\Model=Rus_basalisk.SHP
        \\Cockpit=kamg_frm.shp
        \\WireFrame=redwire
        \\[ShipType grey_basilisk]
        \\Base=basilisk
        \\Model=Rus_basalisk.SHP
        \\WireFrame=greywire
        \\BlindFire=yes
    } };
    try read(arena.allocator(), &.{mod});
    defer reset();
    // Both are read. The second, without a cockpit, leaves its wire frame and blind fire unused,
    // which the log says.
    const list = ships.all();
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqualStrings("kamg_frm.shp", list[0].extra.cockpit.?);
    try std.testing.expectEqual(null, list[1].extra.cockpit);
    try std.testing.expectEqualStrings("greywire", list[1].extra.wire_frame.?);
}

test "a mod's files name the records of the mods it requires" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const planets: Mod = .{ .name = "realistic-planets.hog", .source = undefined, .manifest = .{ .text =
        \\[ShipTypes]
        \\mars=
        \\phobos=
        \\deimos=
        \\[ShipType mars]
        \\Base=venus_hi
        \\Model=mars.shp
        \\[ShipType phobos]
        \\Base=venus_hi
        \\Model=phobos.shp
        \\[ShipType deimos]
        \\Base=venus_hi
        \\Model=deimos.shp
        \\[Pilots]
        \\ace=
        \\[Pilot ace]
        \\Base=3
    } };
    const tour: Mod = .{ .name = "tour", .source = undefined, .manifest = .{ .text =
        \\[Mod]
        \\Requires=Realistic-Planets
        \\[ShipTypes]
        \\realistic-planets:mars=300
        \\Realistic-Planets:Phobos=0x130
        \\realistic-planets:moon=301
        \\elsewhere:thing=302
        \\realistic-planets:deimos=
        \\own=300
        \\later=303
        \\[ShipType own]
        \\Base=predator
        \\Model=own.shp
        \\[ShipType later]
        \\Base=predator
        \\Model=later.shp
        \\[Pilots]
        \\realistic-planets:ace=200
    } };
    try read(arena.allocator(), &.{ planets, tour });
    defer reset();

    // The types a mod names are the ones their mod adds, whatever the case of their names.
    try std.testing.expectEqual(ships.first, ships.remapped("tour", 300).?);
    try std.testing.expectEqual(ships.first + 1, ships.remapped("tour", 0x130).?);
    try std.testing.expectEqual(pilots.first, pilots.remapped("tour", 200).?);
    // A record its mod doesn't add, a mod it doesn't require, and a record without a number are left
    // out.
    try std.testing.expectEqual(null, ships.remapped("tour", 301));
    try std.testing.expectEqual(null, ships.remapped("tour", 302));
    try std.testing.expectEqual(2, ships.referenced.len);
    // Its own type can't take a number it gives the other mod's, and its others keep theirs.
    try std.testing.expectEqual(4, ships.all().len);
    try std.testing.expectEqualStrings("tour:later", ships.all()[3].name);
    try std.testing.expectEqual(ships.first + 3, ships.remapped("tour", 303).?);
    // The mod that adds the type gives it no number of its own.
    try std.testing.expectEqual(null, ships.remapped("realistic-planets.hog", 300));
}

test "Family.records" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list = [_]guns.Added{.{ .name = "a:b", .mod = "a", .base = .pulse_cannon, .extra = .{} }};
    guns.install(&list);
    defer guns.reset();
    var game: [3]stats.Gun = @splat(std.mem.zeroes(stats.Gun));
    game[1].range = 2000;
    // The guns' records start from gun 1, so the Pulse Cannon, gun 2, is the second.
    const made = try guns.records(stats.Gun, arena.allocator(), &game, 1);
    try std.testing.expectEqual(guns.first, made.len);
    try std.testing.expectEqual(2000, made[guns.first - 1].range);
    try std.testing.expectEqual(0, made[guns.first - 2].range);
}

test "a gun's shot, sound and flash, and a ship type's cockpit, pictures and sound" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "mods/bananas");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/bananas/mod.ini", .data =
        \\[Guns]
        \\peel=
        \\quiet=
        \\noisy=
        \\flat=
        \\[Gun peel]
        \\Base=pulse_cannon
        \\Shot=peel_shot.png
        \\ShotSize=25
        \\Sound=sounds/peel.wav
        \\Flash=peel_flash.png
        \\FlashSize=30
        \\[Gun quiet]
        \\Base=laser_cannon
        \\[Gun noisy]
        \\Base=laser_cannon
        \\Sound=noise.wav
        \\[Gun flat]
        \\Base=laser_cannon
        \\FlashSize=0
        \\[ShipTypes]
        \\peeler=
        \\[ShipType peeler]
        \\Base=predator
        \\Model=peeler.shp
        \\Cockpit=ships\peeler_frm.shp
        \\WireFrame=peelwire.png
        \\WingIcon=peelicon
        \\EngineSound=sounds\peel.wav
    });
    const peel_sound = comptime wave.testing.pcm("\x00\x00");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/bananas/peel.wav", .data = peel_sound });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/bananas/noise.wav", .data = "not a sound" });
    var mods: mods_module.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try read(arena.allocator(), mods.list);
    defer reset();
    // A gun with a sound that isn't one, or a flash size that isn't one, is left out; the others
    // keep what they give.
    try std.testing.expectEqual(2, guns.all().len);
    const peel = guns.all()[0].extra;
    try std.testing.expectEqualStrings("peel_shot", peel.shot.?);
    try std.testing.expectEqual(25, peel.shot_size);
    try std.testing.expectEqualSlices(u8, peel_sound, peel.sound.?);
    try std.testing.expectEqualStrings("peel_flash", peel.flash.?);
    try std.testing.expectEqual(30, peel.flash_size.?);
    const quiet = guns.all()[1].extra;
    try std.testing.expectEqual(null, quiet.shot);
    try std.testing.expectEqual(null, quiet.flash);
    try std.testing.expectEqual(null, quiet.flash_size);
    try std.testing.expectEqual(GunExtra.default_shot_size, quiet.shot_size);
    try std.testing.expectEqual(null, quiet.sound);
    // A ship type's cockpit, its pictures by their names' start, and its engine's sound. A folder in
    // front of a file's name is passed over, with either separator.
    const peeler = ships.all()[0].extra;
    try std.testing.expectEqualStrings("peeler_frm.shp", peeler.cockpit.?);
    try std.testing.expectEqualStrings("peelwire", peeler.wire_frame.?);
    try std.testing.expectEqualStrings("peelicon", peeler.wing_icon.?);
    try std.testing.expectEqualSlices(u8, peel_sound, peeler.engine_sound.?);
}

test addNames {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list = [_]ships.Added{
        .{ .name = "a:b", .mod = "a", .base = .phoenix, .label = "Bee", .extra = .{ .model = "b.shp" } },
        .{ .name = "a:c", .mod = "a", .base = .phoenix, .extra = .{ .model = "c.shp" } },
    };
    ships.install(&list);
    var gun_list = [_]guns.Added{.{ .name = "a:g", .mod = "a", .base = .pulse_cannon, .label = "Gee", .extra = .{} }};
    guns.install(&gun_list);
    var missile_list = [_]missiles.Added{.{ .name = "a:m", .mod = "a", .base = .raptor, .extra = .{ .description = "Yellow." } }};
    missiles.install(&missile_list);
    defer reset();
    const text = try addNames(arena.allocator(), &.{ "one", "two" });
    try std.testing.expectEqual(5, text.len);
    try std.testing.expectEqual(3, list[0].label_string.?);
    try std.testing.expectEqualStrings("Bee", text[list[0].label_string.? - 1]);
    try std.testing.expectEqual(null, list[1].label_string);
    try std.testing.expectEqualStrings("Gee", text[gun_list[0].label_string.? - 1]);
    // A missile's description comes after the names.
    try std.testing.expectEqualStrings("Yellow.", text[missile_list[0].extra.description_string.? - 1]);
}

test "the game variables a mod adds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const campaign: Mod = .{ .name = "campaign", .source = undefined, .manifest = .{ .text =
        \\[GameVariables]
        \\pirates_beaten=40
        \\alarm=0x50
        \\script_only=
        \\bad_start=42
        \\taken=17
        \\[GameVariable pirates_beaten]
        \\Start=1
        \\Base=krasnaya_alive
        \\[GameVariable alarm]
        \\Attempt=-1
        \\Saved=no
        \\[GameVariable bad_start]
        \\Start=lots
    } };
    const sequel: Mod = .{ .name = "sequel", .source = undefined, .manifest = .{ .text =
        \\[Mod]
        \\Requires=campaign
        \\[GameVariables]
        \\campaign:pirates_beaten=40
        \\own=41
    } };
    try read(arena.allocator(), &.{ campaign, sequel });
    defer reset();
    // The ones with a start that isn't a number, or a number the game's own variables use, are left
    // out. The rest are numbered past the original's block, in load order.
    const all = variables.all();
    try std.testing.expectEqual(4, all.len);
    try std.testing.expectEqualStrings("campaign:pirates_beaten", all[0].name);
    try std.testing.expectEqual(gameflow.VariableRecord{ .start = 1, .saved = true }, all[0].extra);
    try std.testing.expect(!all[0].based);
    try std.testing.expectEqual(gameflow.VariableRecord{ .start = 0, .attempt = -1, .saved = false }, all[1].extra);
    try std.testing.expectEqual(null, all[2].own_number);
    try std.testing.expectEqualStrings("sequel:own", all[3].name);
    try std.testing.expectEqual(vm.Variables.block_size, variables.find("campaign:pirates_beaten").?);
    // Each mod's missions number them their own way, the sequel's also the variable it requires.
    try std.testing.expectEqual(variables.first, variables.remapped("campaign", 40).?);
    try std.testing.expectEqual(variables.first + 1, variables.remapped("campaign", 0x50).?);
    try std.testing.expectEqual(variables.first, variables.remapped("sequel", 40).?);
    try std.testing.expectEqual(variables.first + 3, variables.remapped("sequel", 41).?);
    try std.testing.expectEqual(null, variables.remapped("campaign", 41));
    try std.testing.expect(variables.numbered("sequel") and !variables.numbered("other"));
}

test "remapMission changes a mod's game variables in its script" {
    const gpa = std.testing.allocator;
    var list = [_]variables.Added{
        .{ .name = "a:x", .mod = "a", .base = {}, .based = false, .own_number = 40, .extra = .{} },
        .{ .name = "z:x", .mod = "z", .base = {}, .based = false, .own_number = 40, .extra = .{} },
    };
    variables.install(&list);
    defer reset();
    // Mod `a`'s mission reads and sets its variable 40, and reads the spare variable 41, which it
    // doesn't list, and the game's `krasnaya_alive`.
    const krasnaya_alive = vm.Variables.number("krasnaya_alive");
    var routine: dte.assemble.Routine = .init(gpa);
    defer routine.deinit();
    try routine.op(.push_array, &.{40});
    try routine.op(.select_array, &.{40});
    try routine.op(.push_array, &.{41});
    try routine.op(.push_array, &.{krasnaya_alive});
    try routine.op(.@"return", &.{});
    const code = try routine.finish();
    defer gpa.free(code);
    var part = std.mem.zeroes(dte.Part);
    part.flags.start = true;
    part.length = @intCast(code.len / @sizeOf(u16));
    var sections: dte.write.Sections = @splat(.{});
    dte.write.set(&sections, .script, code.len / @sizeOf(u16), code);
    dte.write.set(&sections, .parts, 1, std.mem.asBytes(&part));
    const image = try dte.write.write(gpa, &sections, .{});
    defer gpa.free(image);
    try remapMission(gpa, image, "a");
    const listing = (try dte.disassemble(gpa, try (try dte.Mission.parse(image)).script(), 0)).?;
    defer gpa.free(listing.instructions);
    var operands: [4]u8 = undefined;
    for (listing.instructions[0..operands.len], &operands) |instruction, *operand| operand.* = instruction.operands[0];
    try std.testing.expectEqualSlices(u8, &.{ variables.first, variables.first, 41, krasnaya_alive }, &operands);
}

test remapMission {
    const gpa = std.testing.allocator;
    var list = [_]ships.Added{
        .{ .name = "a:b", .mod = "a", .base = .phoenix, .own_number = 300, .extra = .{ .model = "b.shp" } },
        .{ .name = "z:b", .mod = "z", .base = .phoenix, .own_number = 300, .extra = .{ .model = "b.shp" } },
        .{ .name = "a:c", .mod = "a", .base = .phoenix, .own_number = 301, .extra = .{ .model = "c.shp" } },
    };
    ships.install(&list);
    var pilot_list = [_]pilots.Added{.{ .name = "a:p", .mod = "a", .base = 0, .own_number = 200, .extra = .{ .face = pilots_module.faces[0] } }};
    pilots.install(&pilot_list);
    defer reset();
    // A mission of mod `a` naming its types 300 and 301, its pilot 200, and one of the game's. The
    // game's ship launches from the mod's type 300, and the ship of type 301 from the game's
    // Reliant.
    var records = [_]dte.Ship{
        dte.testing.ship(0, dte.Ship.no_flight_group, 300),
        dte.testing.ship(1, dte.Ship.no_flight_group, @backingInt(gameobj.GameType.phoenix)),
        dte.testing.ship(2, dte.Ship.no_flight_group, 301),
        dte.testing.ship(3, dte.Ship.no_flight_group, 302),
    };
    records[0].pilot = 200;
    records[0].launch_from = dte.Ship.no_launch_from;
    records[1].pilot = 12;
    records[1].launch_from = 300;
    records[1].launch_gate = 0;
    records[2].launch_from = @backingInt(gameobj.GameType.reliant);
    records[2].launch_gate = 1;
    var sections: dte.write.Sections = @splat(.{});
    dte.write.set(&sections, .ships, records.len, std.mem.sliceAsBytes(&records));
    const image = try dte.write.write(gpa, &sections, .{});
    defer gpa.free(image);
    try remapMission(gpa, image, "a");
    const remapped_ships = try (try dte.Mission.parse(image)).ships();
    try std.testing.expectEqual(ships.first, remapped_ships[0].kind);
    try std.testing.expectEqual(pilots.first, remapped_ships[0].pilot);
    try std.testing.expectEqual(dte.Ship.no_launch_from, remapped_ships[0].launch_from);
    try std.testing.expectEqual(@backingInt(gameobj.GameType.phoenix), remapped_ships[1].kind);
    try std.testing.expectEqual(12, remapped_ships[1].pilot);
    try std.testing.expectEqual(ships.first, remapped_ships[1].launch_from);
    try std.testing.expectEqual(ships.first + 2, remapped_ships[2].kind);
    try std.testing.expectEqual(@backingInt(gameobj.GameType.reliant), remapped_ships[2].launch_from);
    try std.testing.expectEqual(302, remapped_ships[3].kind);
    // The other mod's type of the same number is its own.
    try std.testing.expectEqual(ships.first + 1, ships.remapped("z", 300).?);
    try std.testing.expectEqual(null, ships.remapped("q", 300));
}

test remapModel {
    var gun_list = [_]guns.Added{.{ .name = "a:g", .mod = "a", .base = .pulse_cannon, .own_number = 20, .extra = .{} }};
    guns.install(&gun_list);
    var missile_list = [_]missiles.Added{.{ .name = "a:m", .mod = "a", .base = .raptor, .own_number = 30, .extra = .{} }};
    missiles.install(&missile_list);
    defer reset();
    var attachments = [_]shp.Attachment{ std.mem.zeroes(shp.Attachment), std.mem.zeroes(shp.Attachment), std.mem.zeroes(shp.Attachment) };
    attachments[0].kind = .gun_muzzle;
    attachments[0].gun_type = 20;
    attachments[1].kind = .missile;
    attachments[1].id = 30;
    attachments[1].later_tiers = .{ 1, 30, 0x0001_001E, 2 };
    attachments[2].kind = .gun_muzzle;
    attachments[2].gun_type = 3;
    // Only the parts' attachments are read.
    var parts: [1]shp.PartData = undefined;
    parts[0].attachments = &attachments;
    remapModel(&parts, "a");
    try std.testing.expectEqual(guns.first, attachments[0].gun_type);
    try std.testing.expectEqual(missiles.first, attachments[1].id);
    try std.testing.expectEqual([4]u32{ 1, missiles.first, 0x0001_0000 | missiles.first, 2 }, attachments[1].later_tiers);
    try std.testing.expectEqual(3, attachments[2].gun_type);
    // Another mod's model keeps its numbers.
    attachments[2].gun_type = 20;
    remapModel(&parts, "b");
    try std.testing.expectEqual(20, attachments[2].gun_type);
}
