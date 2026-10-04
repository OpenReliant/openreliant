//! OpenReliant's: the ship types mods add ([#333](https://github.com/OpenReliant/openreliant/issues/333)).
//!
//! A mod lists the types it adds in its manifest, each with one of the game's types as its base:
//!
//! ```ini
//! [ShipTypes]
//! teapot=300
//!
//! [ShipType teapot]
//! Base=predator
//! Model=teapot.shp
//! Name=Teapot
//! ```
//!
//! - Each type gets the next free number from `first` as OpenReliant starts, mod by mod in load
//!   order, so the numbers depend on which mods are on. Scripts name a type by its qualified name,
//!   such as `teapot:teapot`, never by its number.
//! - A type acts as its base wherever the code singles out a type (`gameobj.Type.base`). It starts
//!   with its base's records, figures and flight model, and its own model, schematic and name.
//! - The number after the type's name in `[ShipTypes]` is the number the mod's own missions use for
//!   it, from `first` up. As OpenReliant loads one of the mod's missions, it changes that number in
//!   the mission's ship records to the number the type got (`remapMission`), so the mission files
//!   stay standard. Leave it empty for a type the mod's missions don't use.
//!
//! The list is fixed once OpenReliant has started (`install`), and read from anywhere through
//! `gameobj.Type`.
//!
//! **Improvement:** the original's ship types are its own 256.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const dte = @import("../../formats/dte.zig");
const stats = @import("../../formats/stats.zig");
const gameobj = @import("gameobj.zig");
const GameType = gameobj.GameType;
const mods_module = @import("bigfile/mods.zig");
const Mod = mods_module.Mod;

const log = std.log.scoped(.mods);

/// The first number a type a mod adds can take: the one after the game's last type.
pub const first = 0x100;

/// The number past the last: the game's markers start there (`GameType.sun_marker`).
pub const end = @intFromEnum(GameType.sun_marker);

/// The most types the mods can add.
pub const capacity = end - first;

/// The manifest's section that lists a mod's types, and the prefix of each type's own section.
pub const list_section = "ShipTypes";
pub const type_section = "ShipType ";

/// A type a mod adds.
pub const Added = struct {
    /// Its qualified name: the name of the mod's folder or archive, and the type's own.
    name: []const u8,
    /// The name of the mod it comes from (`Mod.name`).
    mod: []const u8,
    /// The game's type it acts as, and starts its records from.
    base: GameType,
    /// Its model, and the schematic the display shows of it, else its base's.
    model: []const u8,
    schematic: ?[]const u8 = null,
    /// What the game calls it, else what it calls its base; and once the strings are read, the
    /// language string that holds it (`addNames`).
    label: ?[]const u8 = null,
    label_string: ?u16 = null,
    /// The number the mod's own missions use for it, if they do.
    mission_number: ?u16 = null,

    /// Its name without the mod's.
    pub fn own(added: Added) []const u8 {
        return added.name[added.mod.len + 1 ..];
    }
};

/// The types the mods add, in the order of their numbers; empty until `install`.
var registered: []Added = &.{};

/// Makes `list` the types the mods add, as OpenReliant starts. The list must outlive every use.
pub fn install(list: []Added) void {
    assert(list.len <= capacity);
    registered = list;
}

/// The types the mods add.
pub fn all() []const Added {
    return registered;
}

/// The type a mod adds of the number `number`, if there is one.
pub fn get(number: u32) ?*const Added {
    if (number < first or number - first >= registered.len) return null;
    return &registered[number - first];
}

/// The number of the type a mod adds called `name`, by its qualified name.
pub fn find(name: []const u8) ?u32 {
    for (registered, first..) |each, number| {
        if (std.ascii.eqlIgnoreCase(each.name, name)) return @intCast(number);
    }
    return null;
}

/// How many types have records in the ship tables: the game's, then the mods'.
pub fn count() usize {
    return first + registered.len;
}

/// Reads the types each mod in `mods` adds from its manifest, in load order. A type the manifest
/// gets wrong is left out, which the log says, and so are types past `capacity`.
pub fn read(arena: Allocator, mods: []const Mod) Allocator.Error![]Added {
    var list: std.ArrayList(Added) = .empty;
    for (mods) |mod| {
        var listed = mod.manifest.keys(list_section);
        while (listed.next()) |own| {
            if (list.items.len == capacity) {
                log.warn("{s}: {s}: more than {d} ship types, so the rest are left out", .{ mod.name, mods_module.manifest_name, capacity });
                return list.items;
            }
            const type_added = try parse(arena, mod, own, list.items) orelse continue;
            try list.append(arena, type_added);
        }
    }
    return list.items;
}

/// The type `own` of `mod`, as its manifest describes it, or null where it gets it wrong, which the
/// log says. `earlier` holds the types read before it.
fn parse(arena: Allocator, mod: Mod, own: []const u8, earlier: []const Added) Allocator.Error!?Added {
    const manifest = mod.manifest;
    const where = mods_module.manifest_name;
    if (own.len == 0 or std.mem.indexOfAny(u8, own, ": ") != null) {
        log.warn("{s}: {s}: the ship type '{s}' needs a name without spaces or colons", .{ mod.name, where, own });
        return null;
    }
    const name = try std.fmt.allocPrint(arena, "{s}:{s}", .{ mod.name, own });
    for (earlier) |each| if (std.ascii.eqlIgnoreCase(each.name, name)) {
        log.warn("{s}: {s}: the ship type '{s}' is listed twice", .{ mod.name, where, own });
        return null;
    };
    const section = try std.fmt.allocPrint(arena, "{s}{s}", .{ type_section, own });
    const base_text = manifest.value(section, "Base") orelse {
        log.warn("{s}: {s}: the ship type '{s}' needs a Base in [{s}]", .{ mod.name, where, own, section });
        return null;
    };
    const base = baseOf(base_text) orelse {
        log.warn("{s}: {s}: the ship type '{s}' has the base '{s}', which isn't one of the game's types", .{ mod.name, where, own, base_text });
        return null;
    };
    const model = manifest.value(section, "Model") orelse {
        log.warn("{s}: {s}: the ship type '{s}' needs a Model in [{s}]", .{ mod.name, where, own, section });
        return null;
    };
    var made: Added = .{
        .name = name,
        .mod = mod.name,
        .base = base,
        .model = try arena.dupe(u8, model),
        .schematic = if (manifest.value(section, "Schematic")) |text| try arena.dupe(u8, text) else null,
        .label = if (manifest.value(section, "Name")) |text| try arena.dupe(u8, text) else null,
    };
    const number_text = std.mem.trim(u8, manifest.value(list_section, own) orelse "", " \t");
    if (number_text.len > 0) {
        const number = std.fmt.parseInt(u16, number_text, 0) catch 0;
        if (number < first or number >= end) {
            log.warn("{s}: {s}: the ship type '{s}' gives its missions the number {s}, which isn't from {d} to {d}", .{ mod.name, where, own, number_text, first, end - 1 });
            return null;
        }
        for (earlier) |each| if (std.mem.eql(u8, each.mod, mod.name) and each.mission_number == number) {
            log.warn("{s}: {s}: the ship types '{s}' and '{s}' give their missions the same number", .{ mod.name, where, each.own(), own });
            return null;
        };
        made.mission_number = number;
    }
    return made;
}

/// The game's type `text` names: by its name, such as `predator`, or by its number below `first`.
fn baseOf(text: []const u8) ?GameType {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (std.fmt.parseInt(u16, trimmed, 0)) |number| {
        return if (number < first) @enumFromInt(number) else null;
    } else |_| {}
    inline for (comptime std.enums.values(GameType)) |named| {
        if (@intFromEnum(named) < first and std.ascii.eqlIgnoreCase(trimmed, @tagName(named))) return named;
    }
    return null;
}

/// The ship records of the game's `ships` for every type, the game's and the mods': the game's,
/// filled out to `first` with zeros where the file has fewer, then a copy of its base's for each
/// type the mods add.
pub fn ships(arena: Allocator, game_ships: []align(1) const stats.Ship) Allocator.Error![]stats.Ship {
    const made = try arena.alloc(stats.Ship, count());
    const own = @min(game_ships.len, first);
    for (made[0..own], game_ships[0..own]) |*record, ship| record.* = ship;
    @memset(made[own..first], std.mem.zeroes(stats.Ship));
    for (made[first..], registered) |*record, each| record.* = made[@intFromEnum(each.base)];
    return made;
}

/// The game's strings `text`, then the name of each type the mods add that has one, whose string
/// each type keeps (`Added.label_string`). A string's id is its place from 1.
pub fn addNames(arena: Allocator, text: []const []const u8) Allocator.Error![]const []const u8 {
    var made: std.ArrayList([]const u8) = .empty;
    try made.appendSlice(arena, text);
    for (registered) |*each| {
        const label = each.label orelse continue;
        try made.append(arena, label);
        each.label_string = std.math.cast(u16, made.items.len) orelse {
            each.label_string = null;
            continue;
        };
    }
    return made.items;
}

/// Changes the numbers the mod called `mod` gives its types in a mission's ship records, in the
/// mission's `image`, to the numbers the types got. A mission that can't be read is left as it is,
/// to fail as it loads.
pub fn remapMission(image: []u8, mod: []const u8) void {
    const mission = dte.Mission.parse(image) catch return;
    const records = mission.ships() catch return;
    if (records.len == 0) return;
    const start = @intFromPtr(records.ptr) - @intFromPtr(image.ptr);
    for (records, 0..) |record, at| {
        const number = remapped(mod, record.kind) orelse continue;
        const kind_at = start + at * @sizeOf(dte.Ship) + @offsetOf(dte.Ship, "kind");
        std.mem.writeInt(u16, image[kind_at..][0..2], number, .little);
    }
}

/// The number of the type the mod called `mod` gives the number `number` in its missions.
fn remapped(mod: []const u8, number: u16) ?u16 {
    for (registered, first..) |each, assigned| {
        if (each.mission_number == number and std.mem.eql(u8, each.mod, mod)) return @intCast(assigned);
    }
    return null;
}

pub const testing = struct {
    /// Installs `list` for a test, until `reset`.
    pub fn use(list: []Added) void {
        install(list);
    }

    pub fn reset() void {
        registered = &.{};
    }
};

test read {
    const arena_state = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(arena_state);
    defer arena.deinit();
    const manifest =
        \\[ShipTypes]
        \\teapot=300
        \\kettle=
        \\bad name=
        \\nobase=
        \\[ShipType teapot]
        \\Base=predator
        \\Model=teapot.shp
        \\Name=Teapot
        \\[ShipType kettle]
        \\base=0x0B
        \\model=kettle.shp
        \\[ShipType nobase]
        \\Model=x.shp
    ;
    const mod: Mod = .{ .name = "pots", .source = undefined, .manifest = .{ .text = manifest } };
    const list = try read(arena.allocator(), &.{mod});
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqualStrings("pots:teapot", list[0].name);
    try std.testing.expectEqualStrings("teapot", list[0].own());
    try std.testing.expectEqual(GameType.predator, list[0].base);
    try std.testing.expectEqualStrings("Teapot", list[0].label.?);
    try std.testing.expectEqual(300, list[0].mission_number.?);
    try std.testing.expectEqual(GameType.phoenix, list[1].base);
    try std.testing.expectEqual(null, list[1].mission_number);

    testing.use(list);
    defer testing.reset();
    try std.testing.expectEqual(first + 1, find("POTS:kettle").?);
    try std.testing.expectEqualStrings("pots:teapot", get(first).?.name);
    try std.testing.expectEqual(null, get(first + 2));
    try std.testing.expectEqual(null, get(0x0B));
    try std.testing.expectEqual(first + 2, count());
}

test ships {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list = [_]Added{.{ .name = "a:b", .mod = "a", .base = .phoenix, .model = "b.shp" }};
    testing.use(&list);
    defer testing.reset();
    var game: [12]stats.Ship = @splat(std.mem.zeroes(stats.Ship));
    game[@intFromEnum(GameType.phoenix)].max_speed = 300;
    const made = try ships(arena.allocator(), &game);
    try std.testing.expectEqual(first + 1, made.len);
    try std.testing.expectEqual(300, made[first].max_speed);
    try std.testing.expectEqual(0, made[first - 1].max_speed);
}

test addNames {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list = [_]Added{
        .{ .name = "a:b", .mod = "a", .base = .phoenix, .model = "b.shp", .label = "Bee" },
        .{ .name = "a:c", .mod = "a", .base = .phoenix, .model = "c.shp" },
    };
    testing.use(&list);
    defer testing.reset();
    const text = try addNames(arena.allocator(), &.{ "one", "two" });
    try std.testing.expectEqual(3, text.len);
    try std.testing.expectEqual(3, list[0].label_string.?);
    try std.testing.expectEqualStrings("Bee", text[list[0].label_string.? - 1]);
    try std.testing.expectEqual(null, list[1].label_string);
}

test remapMission {
    const gpa = std.testing.allocator;
    var list = [_]Added{
        .{ .name = "a:b", .mod = "a", .base = .phoenix, .model = "b.shp", .mission_number = 300 },
        .{ .name = "z:b", .mod = "z", .base = .phoenix, .model = "b.shp", .mission_number = 300 },
        .{ .name = "a:c", .mod = "a", .base = .phoenix, .model = "c.shp", .mission_number = 301 },
    };
    testing.use(&list);
    defer testing.reset();
    // A mission of mod `a` naming its types 300 and 301, and one of the game's.
    const records = [_]dte.Ship{
        dte.testing.ship(0, dte.Ship.no_flight_group, 300),
        dte.testing.ship(1, dte.Ship.no_flight_group, @intFromEnum(GameType.phoenix)),
        dte.testing.ship(2, dte.Ship.no_flight_group, 301),
        dte.testing.ship(3, dte.Ship.no_flight_group, 302),
    };
    var sections: dte.write.Sections = @splat(.{});
    dte.write.set(&sections, .ships, records.len, std.mem.sliceAsBytes(&records));
    const image = try dte.write.write(gpa, &sections, .{});
    defer gpa.free(image);
    remapMission(image, "a");
    const remapped_ships = try (try dte.Mission.parse(image)).ships();
    try std.testing.expectEqual(first, remapped_ships[0].kind);
    try std.testing.expectEqual(@intFromEnum(GameType.phoenix), remapped_ships[1].kind);
    try std.testing.expectEqual(first + 2, remapped_ships[2].kind);
    try std.testing.expectEqual(302, remapped_ships[3].kind);
    // The other mod's type of the same number is its own.
    try std.testing.expectEqual(first + 1, remapped("z", 300).?);
    try std.testing.expectEqual(null, remapped("q", 300));
}
