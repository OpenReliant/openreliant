//! OpenReliant's: the records mods add, each family numbered after the game's own: ship types
//! ([#333](https://github.com/OpenReliant/openreliant/issues/333)), gun types, missile types and
//! pilots ([#640](https://github.com/OpenReliant/openreliant/issues/640)).
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
//!   `guns.GunType.base`, `missiles.Type.base`), and starts with its base's records.
//! - The number after its name in the list is the number the mod's own files use for it: its
//!   missions for ship types and pilots, its models' muzzles for guns and their hardpoints for
//!   missiles. As OpenReliant loads one of the mod's files, it changes that number to the one the
//!   record got (`remapMission`, `remapModel`), so the files stay in the game's formats.
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
const profile = @import("../profile.zig");
const gameobj = @import("gameobj.zig");
const guns_module = @import("guns.zig");
const missiles_module = @import("missiles.zig");
const pilots_module = @import("pilots.zig");
const mods_module = @import("bigfile/mods.zig");
const Mod = mods_module.Mod;

const log = std.log.scoped(.mods);

/// What a family of records is, whose base is one of the game's `Base`, and which has an `Extra`
/// each besides: what the log calls one, its manifest's sections, and its numbers.
pub fn Spec(comptime Base: type, comptime Extra: type) type {
    return struct {
        /// What the log calls one, such as `ship type`.
        noun: []const u8,
        /// The manifest's section that lists a mod's records, and the prefix of each one's own
        /// section.
        list_section: []const u8,
        item_section: []const u8,
        /// Its first number, the one after the game's last, and the number past its last.
        first: u32,
        end: u32,
        /// The game's record the manifest's text names, and the number of each.
        baseOf: fn ([]const u8) ?Base,
        baseNumber: fn (Base) u32,
        /// What the mod's own files that use the number after a record's name are, for the log.
        numbered_in: []const u8,
        /// Reads what a record has besides its base and its name from its section, or null where
        /// the section gets it wrong, which it logs.
        readExtra: ?fn (Context, []const u8, Base) Allocator.Error!?Extra = null,
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
            /// Its qualified name: the name of the mod's folder or archive, and its own.
            name: []const u8,
            /// The name of the mod it comes from (`Mod.name`).
            mod: []const u8,
            /// The game's record it acts as, and starts from.
            base: Base,
            /// What the game calls it, else what it calls its base; and once the strings are read,
            /// the language string that holds it (`addNames`).
            label: ?[]const u8 = null,
            label_string: ?u16 = null,
            /// The number the mod's own files use for it, if they do.
            own_number: ?u32 = null,
            extra: Extra = if (Extra == void) {} else undefined,

            /// Its name without the mod's.
            pub fn own(added: Added) []const u8 {
                return added.name[added.mod.len + 1 ..];
            }
        };

        /// The records the mods add, in the order of their numbers; empty until `install`.
        var registered: []Added = &.{};

        /// Makes `list` the records the mods add, as OpenReliant starts. The list must outlive
        /// every use.
        pub fn install(list: []Added) void {
            assert(list.len <= capacity);
            registered = list;
        }

        /// Lets go of the records, as a test ends.
        pub fn reset() void {
            registered = &.{};
        }

        pub fn all() []Added {
            return registered;
        }

        /// The record a mod adds of the number `number`, if there is one.
        pub fn get(number: u32) ?*const Added {
            if (number < first or number - first >= registered.len) return null;
            return &registered[number - first];
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

        /// The number of the record the mod called `mod` gives the number `number` in its files.
        pub fn remapped(mod: []const u8, number: u32) ?u32 {
            for (registered, first..) |each, assigned| {
                if (each.own_number == number and std.mem.eql(u8, each.mod, mod)) return @intCast(assigned);
            }
            return null;
        }

        /// The number of what `text` names, for a record of the mod called `mod`: one of the
        /// game's by its name or number (`Spec.baseOf`), one the mods add by its qualified name,
        /// or one `mod` adds by its own name.
        pub fn named(text: []const u8, mod: []const u8) ?u32 {
            if (spec.baseOf(text)) |base| return spec.baseNumber(base);
            if (find(text)) |number| return number;
            var buffer: [256]u8 = undefined;
            const qualified = std.fmt.bufPrint(&buffer, "{s}:{s}", .{ mod, text }) catch return null;
            return find(qualified);
        }

        /// The records each mod in `mods` adds, as its manifest lists them, in load order. A
        /// record the manifest gets wrong is left out, which the log says, and so are those past
        /// `capacity`.
        pub fn read(arena: Allocator, mods: []const Mod) Allocator.Error![]Added {
            var list: std.ArrayList(Added) = .empty;
            for (mods) |mod| {
                var listed = mod.manifest.keys(spec.list_section);
                while (listed.next()) |own| {
                    if (list.items.len == capacity) {
                        log.warn("{s}: {s}: more than {d} of the mods' {s}s, so the rest are left out", .{ mod.name, mods_module.manifest_name, capacity, spec.noun });
                        return list.items;
                    }
                    const made = try parse(.{ .arena = arena, .mod = mod, .own = own }, list.items) orelse continue;
                    try list.append(arena, made);
                }
            }
            return list.items;
        }

        /// The record `context.own` of `context.mod`, as its manifest describes it, or null where it
        /// gets it wrong, which the log says. `earlier` holds the records read before it.
        fn parse(context: Context, earlier: []const Added) Allocator.Error!?Added {
            const manifest = context.mod.manifest;
            const own = context.own;
            if (own.len == 0 or std.mem.indexOfAny(u8, own, ": ") != null) {
                context.warn(spec.noun, "needs a name without spaces or colons", .{});
                return null;
            }
            const name = try std.fmt.allocPrint(context.arena, "{s}:{s}", .{ context.mod.name, own });
            for (earlier) |each| if (std.ascii.eqlIgnoreCase(each.name, name)) {
                context.warn(spec.noun, "is listed twice", .{});
                return null;
            };
            const section = try std.fmt.allocPrint(context.arena, "{s}{s}", .{ spec.item_section, own });
            const base_text = manifest.value(section, "Base") orelse {
                context.warn(spec.noun, "needs a Base in [{s}]", .{section});
                return null;
            };
            const base = spec.baseOf(base_text) orelse {
                context.warn(spec.noun, "has the base '{s}', which isn't one of the game's", .{base_text});
                return null;
            };
            var made: Added = .{
                .name = name,
                .mod = context.mod.name,
                .base = base,
                .label = if (manifest.value(section, "Name")) |text| try context.arena.dupe(u8, text) else null,
            };
            if (spec.readExtra) |readExtra| made.extra = try readExtra(context, section, base) orelse return null;
            const number_text = std.mem.trim(u8, manifest.value(spec.list_section, own) orelse "", " \t");
            if (number_text.len > 0) {
                const number = std.fmt.parseInt(u32, number_text, 0) catch 0;
                if (number < first or number >= end) {
                    context.warn(spec.noun, "gives " ++ spec.numbered_in ++ " the number {s}, which isn't from {d} to {d}", .{ number_text, first, end - 1 });
                    return null;
                }
                for (earlier) |each| if (std.mem.eql(u8, each.mod, context.mod.name) and each.own_number == number) {
                    context.warn(spec.noun, "gives " ++ spec.numbered_in ++ " the same number as '{s}'", .{each.own()});
                    return null;
                };
                made.own_number = number;
            }
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
            for (made[own_count..], registered) |*record, each| record.* = made[spec.baseNumber(each.base) - numbered_from];
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
        if (@intFromEnum(each) >= 0 and @intFromEnum(each) < below and std.ascii.eqlIgnoreCase(trimmed, @tagName(each))) return each;
    }
    return null;
}

/// What a ship type has besides: its model and the schematic the display shows of it, else its
/// base's; and the gun every muzzle of its model fires and the missile every hardpoint holds, else
/// those its model names.
pub const ShipExtra = struct {
    model: []const u8,
    schematic: ?[]const u8 = null,
    gun: ?guns_module.GunType = null,
    missile: ?missiles_module.Type = null,
};

fn readShip(context: Context, section: []const u8, _: gameobj.GameType) Allocator.Error!?ShipExtra {
    const manifest = context.mod.manifest;
    const model = manifest.value(section, "Model") orelse {
        context.warn("ship type", "needs a Model in [{s}]", .{section});
        return null;
    };
    var made: ShipExtra = .{ .model = try context.arena.dupe(u8, model) };
    if (manifest.value(section, "Schematic")) |text| made.schematic = try context.arena.dupe(u8, text);
    if (manifest.value(section, "Guns")) |text| {
        const number = guns.named(text, context.mod.name) orelse {
            context.warn("ship type", "fires the gun '{s}', which isn't one of the game's or the mods'", .{text});
            return null;
        };
        made.gun = @enumFromInt(number);
    }
    if (manifest.value(section, "Missiles")) |text| {
        const number = missiles.named(text, context.mod.name) orelse {
            context.warn("ship type", "carries the missile '{s}', which isn't one of the game's or the mods'", .{text});
            return null;
        };
        made.missile = @enumFromInt(number);
    }
    return made;
}

/// What a missile type has besides: the model it flies as, else its base's.
pub const MissileExtra = struct {
    model: ?[]const u8 = null,
};

fn readMissile(context: Context, section: []const u8, _: missiles_module.GameMissile) Allocator.Error!?MissileExtra {
    const model = context.mod.manifest.value(section, "Model") orelse return .{};
    return .{ .model = try context.arena.dupe(u8, model) };
}

/// The ship types mods add, from 256 to the markers (`GameType.sun_marker`).
pub const ships = Family(gameobj.GameType, ShipExtra, .{
    .noun = "ship type",
    .list_section = "ShipTypes",
    .item_section = "ShipType ",
    .first = 0x100,
    .end = @intFromEnum(gameobj.GameType.sun_marker),
    .baseOf = struct {
        fn of(text: []const u8) ?gameobj.GameType {
            return gameNamed(gameobj.GameType, text, 0x100);
        }
    }.of,
    .baseNumber = struct {
        fn number(base: gameobj.GameType) u32 {
            return @intFromEnum(base);
        }
    }.number,
    .numbered_in = "its missions",
    .readExtra = readShip,
});

/// The gun types mods add, after the game's 15, up to the most a muzzle's byte holds.
pub const guns = Family(guns_module.GameGun, void, .{
    .noun = "gun",
    .list_section = "Guns",
    .item_section = "Gun ",
    .first = guns_module.max_types,
    .end = std.math.maxInt(u8) + 1,
    .baseOf = struct {
        fn of(text: []const u8) ?guns_module.GameGun {
            const trimmed = std.mem.trim(u8, text, " \t");
            if (std.fmt.parseInt(u32, trimmed, 0)) |number| {
                if (number == 0 or number >= guns_module.max_types) return null;
                return @enumFromInt(number - 1);
            } else |_| {}
            return gameNamed(guns_module.GameGun, trimmed, guns_module.max_types);
        }
    }.of,
    .baseNumber = struct {
        fn number(base: guns_module.GameGun) u32 {
            return base.number();
        }
    }.number,
    .numbered_in = "its models' muzzles",
});

/// The missile types mods add, after the game's 11.
pub const missiles = Family(missiles_module.GameMissile, MissileExtra, .{
    .noun = "missile",
    .list_section = "Missiles",
    .item_section = "Missile ",
    .first = missiles_module.type_count,
    .end = std.math.maxInt(u8) + 1,
    .baseOf = struct {
        fn of(text: []const u8) ?missiles_module.GameMissile {
            const base = gameNamed(missiles_module.GameMissile, text, missiles_module.type_count) orelse return null;
            return if (base == .none) null else base;
        }
    }.of,
    .baseNumber = struct {
        fn number(base: missiles_module.GameMissile) u32 {
            return @intCast(@intFromEnum(base));
        }
    }.number,
    .numbered_in = "its models' hardpoints",
    .readExtra = readMissile,
});

/// What a pilot has besides: its face, its base's, under its own name where it has one
/// (`addNames`).
pub const PilotExtra = struct {
    face: pilots_module.Face,
};

fn readPilot(_: Context, _: []const u8, base: u8) Allocator.Error!?PilotExtra {
    return .{ .face = pilots_module.faces[base] };
}

/// The pilots mods add, after the game's 194, up to the one a mission's ship record keeps for
/// none (`dte.Ship.no_pilot`).
pub const pilots = Family(u8, PilotExtra, .{
    .noun = "pilot",
    .list_section = "Pilots",
    .item_section = "Pilot ",
    .first = pilots_module.Table.count,
    .end = dte.Ship.no_pilot,
    .baseOf = struct {
        fn of(text: []const u8) ?u8 {
            const number = std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t"), 0) catch return null;
            return if (number < pilots_module.Table.count) number else null;
        }
    }.of,
    .baseNumber = struct {
        fn number(base: u8) u32 {
            return base;
        }
    }.number,
    .numbered_in = "its missions",
    .readExtra = readPilot,
});

/// Reads what each mod in `mods` adds, family by family, in load order, as OpenReliant starts:
/// the guns, missiles and pilots before the ship types, which can name them.
pub fn read(arena: Allocator, mods: []const Mod) Allocator.Error!void {
    guns.install(try guns.read(arena, mods));
    missiles.install(try missiles.read(arena, mods));
    pilots.install(try pilots.read(arena, mods));
    ships.install(try ships.read(arena, mods));
}

/// Lets go of every family, as a test ends.
pub fn reset() void {
    ships.reset();
    guns.reset();
    missiles.reset();
    pilots.reset();
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
    return made.items;
}

/// Changes the numbers the mod called `mod` gives the ship types and pilots it adds in a mission's
/// ship records, in the mission's `image`, to the numbers they got. A mission that can't be read is
/// left as it is, to fail as it loads.
pub fn remapMission(image: []u8, mod: []const u8) void {
    const mission = dte.Mission.parse(image) catch return;
    const records = mission.ships() catch return;
    if (records.len == 0) return;
    const start = @intFromPtr(records.ptr) - @intFromPtr(image.ptr);
    for (records, 0..) |record, at| {
        const place = start + at * @sizeOf(dte.Ship);
        if (ships.remapped(mod, record.kind)) |number| {
            std.mem.writeInt(u16, image[place + @offsetOf(dte.Ship, "kind") ..][0..2], @intCast(number), .little);
        }
        if (pilots.remapped(mod, record.pilot)) |number| image[place + @offsetOf(dte.Ship, "pilot")] = @intCast(number);
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
        \\[Missiles]
        \\banana=30
        \\[Missile banana]
        \\Base=raptor
        \\Model=banana.shp
        \\[Pilots]
        \\trooper=200
        \\[Pilot trooper]
        \\Base=0
        \\[ShipTypes]
        \\teapot=300
        \\kettle=
        \\bad name=
        \\nobase=
        \\[ShipType teapot]
        \\Base=predator
        \\Model=teapot.shp
        \\Name=Teapot
        \\Guns=banana
        \\Missiles=bananas:banana
        \\[ShipType kettle]
        \\base=0x0B
        \\model=kettle.shp
        \\Guns=nova_cannon
        \\[ShipType nobase]
        \\Model=x.shp
    ;
    const mod: Mod = .{ .name = "bananas", .source = undefined, .manifest = .{ .text = manifest } };
    try read(arena.allocator(), &.{mod});
    defer reset();

    try std.testing.expectEqual(1, guns.all().len);
    try std.testing.expectEqualStrings("bananas:banana", guns.all()[0].name);
    try std.testing.expectEqual(guns_module.GameGun.pulse_cannon, guns.all()[0].base);
    try std.testing.expectEqual(20, guns.all()[0].own_number.?);
    try std.testing.expectEqual(guns.first, guns.find("bananas:banana").?);
    try std.testing.expectEqualStrings("banana.shp", missiles.all()[0].extra.model.?);
    try std.testing.expectEqual(0, pilots.all()[0].base);

    const list = ships.all();
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqualStrings("bananas:teapot", list[0].name);
    try std.testing.expectEqualStrings("teapot", list[0].own());
    try std.testing.expectEqual(gameobj.GameType.predator, list[0].base);
    try std.testing.expectEqualStrings("Teapot", list[0].label.?);
    try std.testing.expectEqual(300, list[0].own_number.?);
    try std.testing.expectEqual(guns.first, list[0].extra.gun.?.number());
    try std.testing.expectEqual(missiles.first, list[0].extra.missile.?.index().?);
    try std.testing.expectEqual(gameobj.GameType.phoenix, list[1].base);
    try std.testing.expectEqual(guns_module.GunType.of(.nova_cannon), list[1].extra.gun.?);
    try std.testing.expectEqual(null, list[1].own_number);
    try std.testing.expectEqual(ships.first + 1, ships.find("BANANAS:kettle").?);
    try std.testing.expectEqualStrings("bananas:teapot", ships.get(ships.first).?.name);
    try std.testing.expectEqual(null, ships.get(ships.first + 2));
    try std.testing.expectEqual(null, ships.get(0x0B));
    try std.testing.expectEqual(ships.first + 2, ships.count());
}

test "Family.records" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list = [_]guns.Added{.{ .name = "a:b", .mod = "a", .base = .pulse_cannon }};
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

test addNames {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list = [_]ships.Added{
        .{ .name = "a:b", .mod = "a", .base = .phoenix, .label = "Bee", .extra = .{ .model = "b.shp" } },
        .{ .name = "a:c", .mod = "a", .base = .phoenix, .extra = .{ .model = "c.shp" } },
    };
    ships.install(&list);
    var gun_list = [_]guns.Added{.{ .name = "a:g", .mod = "a", .base = .pulse_cannon, .label = "Gee" }};
    guns.install(&gun_list);
    defer reset();
    const text = try addNames(arena.allocator(), &.{ "one", "two" });
    try std.testing.expectEqual(4, text.len);
    try std.testing.expectEqual(3, list[0].label_string.?);
    try std.testing.expectEqualStrings("Bee", text[list[0].label_string.? - 1]);
    try std.testing.expectEqual(null, list[1].label_string);
    try std.testing.expectEqualStrings("Gee", text[gun_list[0].label_string.? - 1]);
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
    // A mission of mod `a` naming its types 300 and 301, its pilot 200, and one of the game's.
    var records = [_]dte.Ship{
        dte.testing.ship(0, dte.Ship.no_flight_group, 300),
        dte.testing.ship(1, dte.Ship.no_flight_group, @intFromEnum(gameobj.GameType.phoenix)),
        dte.testing.ship(2, dte.Ship.no_flight_group, 301),
        dte.testing.ship(3, dte.Ship.no_flight_group, 302),
    };
    records[0].pilot = 200;
    records[1].pilot = 12;
    var sections: dte.write.Sections = @splat(.{});
    dte.write.set(&sections, .ships, records.len, std.mem.sliceAsBytes(&records));
    const image = try dte.write.write(gpa, &sections, .{});
    defer gpa.free(image);
    remapMission(image, "a");
    const remapped_ships = try (try dte.Mission.parse(image)).ships();
    try std.testing.expectEqual(ships.first, remapped_ships[0].kind);
    try std.testing.expectEqual(pilots.first, remapped_ships[0].pilot);
    try std.testing.expectEqual(@intFromEnum(gameobj.GameType.phoenix), remapped_ships[1].kind);
    try std.testing.expectEqual(12, remapped_ships[1].pilot);
    try std.testing.expectEqual(ships.first + 2, remapped_ships[2].kind);
    try std.testing.expectEqual(302, remapped_ships[3].kind);
    // The other mod's type of the same number is its own.
    try std.testing.expectEqual(ships.first + 1, ships.remapped("z", 300).?);
    try std.testing.expectEqual(null, ships.remapped("q", 300));
}

test remapModel {
    var gun_list = [_]guns.Added{.{ .name = "a:g", .mod = "a", .base = .pulse_cannon, .own_number = 20 }};
    guns.install(&gun_list);
    var missile_list = [_]missiles.Added{.{ .name = "a:m", .mod = "a", .base = .raptor, .own_number = 30 }};
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
