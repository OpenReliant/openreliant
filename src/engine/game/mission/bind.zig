//! A mission file read and bound for play, as a mission's start has `mission_bind_sections`
//! (`0x00451D90`) do it: the file read from the game's `missions` folder or from `resource.hog`
//! (`read`), each of its sections bound (`Mission.bind`), and the tables the rest of the mission
//! reads made from them. [`docs/engine/missions.md`](../../../../docs/engine/missions.md)
//! describes it. Its records are found as the script names them, by where they lie in the image
//! (`Mission.shipIndex` and the rest), and the image is read where the script points
//! (`Mission.byte` and the rest). **Unverified:** these functions lie between `loadout.cpp`'s code
//! and `Executor.cpp`'s; by what they do they are the mission's.
//!
//! Elsewhere: the script's clock and start (`vm.Machine.start`), the watches of the proximity
//! conditions (`0x0045AE10`), which the mission's events make as it starts
//! (`events.Events.watch`), and the wings (`mission_wings_build`, `mission.buildWings`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const dte = @import("../../../formats/dte.zig");
const files = @import("../../files.zig");
const vm = @import("../../vm.zig");
const bigfile = @import("../bigfile.zig");

const log = std.log.scoped(.mission);

/// How much of a loose mission file the game reads: its buffer's size (`0x00451DA0`).
pub const loose_limit = 0xFA000;

/// Where a mission's file came from.
pub const Source = enum { mod, loose, archive };

/// What a read past the mission image gives, where the game would read past its buffer.
pub const ReadError = error{OutsideImage};

pub const File = struct {
    /// The file's bytes as the mission binds them, made in the allocator `read` is given.
    image: []u8,
    source: Source,
};

/// `mission_file_read` (`0x0045A300`): the mission file `path`, a path of the game's under its
/// directory `dir`. The loose file comes first, where there is one (`file_exists`,
/// `0x004AD6E0`), found whatever the case of its names, as Windows finds it, and read as it is,
/// no further than `loose_limit`; then the member of `resources` it names (`hog_load`),
/// expanded where RefPack packed it. Null where there is neither, on which the archive's reader
/// reports the member missing and the mission's start stops the game: "The mission number is
/// invalid". OpenReliant leaves saying so to the caller.
///
/// **Improvement:** a mod's file of the mission's name comes first
/// (`bigfile.Mods.readInPlaceOf`), before even the loose file, which the installation itself holds
/// missions 18 and 25 as, so that a mod replaces any mission.
pub fn read(io: Io, gpa: Allocator, dir: Io.Dir, resources: *const bigfile.Hog, path: []const u8) !?File {
    if (try resources.mods.readInPlaceOf(gpa, path)) |bytes| return .{ .image = bytes, .source = .mod };
    if (try files.readFile(io, gpa, dir, path, .limited(files.max_file_size))) |bytes| {
        if (bytes.len <= loose_limit) return .{ .image = bytes, .source = .loose };
        // The game reads no more than its buffer holds, and binds what it read.
        log.warn("{s} is {d} bytes: the game reads the first {d}", .{ path, bytes.len, loose_limit });
        defer gpa.free(bytes);
        return .{ .image = try gpa.dupe(u8, bytes[0..loose_limit]), .source = .loose };
    }
    if (!resources.has(path)) return null;
    return .{ .image = try resources.readFile(gpa, path), .source = .archive };
}

/// A mission bound for play: its image, from which its records are read and into which the engine
/// writes their run-time fields, as the game writes into its buffer, and the tables binding makes.
pub const Mission = struct {
    gpa: Allocator,
    image: []u8,
    file: dte.Mission,
    /// `mission_format_flags` (`0x00525F9A`, `0x00525FA4`, `0x005267C6`, `0x005294E8`): the four
    /// flags of the directory's entries, each set where any section has it. Nothing reads them.
    formats: dte.DirectoryEntry.Formats,
    /// The flight groups' ships, group after group (`flight_group_ships`, `0x004EF2F8`), each by
    /// its index among the mission's ships. A group's `first_ship` and `ship_count` give its run.
    group_ships: []u16,
    /// The waypoints (`waypoints`, `0x00525710`), grouped by flight group, each group's in the
    /// order the mission lists them. A Patrol Route flies a group's from the entry its target
    /// names (`order_patrol_route_init`).
    waypoints: []Waypoint,
    /// The record each entry of the object table stands for (`object_records`, `0x00538C90`),
    /// by object ID; null where none does.
    records: []?Record,
    /// The part tables (`part_table`, `part_table_b`): section 8's parts, whose code is in the
    /// script, and section 17's, whose code is in `script_b`.
    parts: vm.Parts,
    parts_b: vm.Parts,

    pub const Waypoint = struct {
        /// The waypoint's flight group, by its index.
        group: u8,
        /// The waypoint, by its index among the mission's ships.
        ship: u16,
    };

    /// A record of the mission's that an entry of the object table stands for, by its index in
    /// its section.
    pub const Record = union(enum) {
        ship: u16,
        flight_group: u16,
        squad: u16,
    };

    /// Binds `image`, made in `gpa`, which the mission then owns (`mission_bind_sections`): each
    /// section's records, the ships at their spawn places (`resetShips`), and the tables. A
    /// section that runs past the image fails, where the game would read past its buffer.
    pub fn bind(gpa: Allocator, image: []u8) !Mission {
        errdefer gpa.free(image);
        const file: dte.Mission = try .parse(image);
        var mission: Mission = .{
            .gpa = gpa,
            .image = image,
            .file = file,
            .formats = .{},
            .group_ships = &.{},
            .waypoints = &.{},
            .records = &.{},
            .parts = @splat(.{}),
            .parts_b = @splat(.{}),
        };
        for (file.directory) |entry| mission.formats = mission.formats.noting(entry.formats);
        resetShips(try mission.ships());
        // What `mission_bind_tables` (`0x00453050`) makes of the sections once they are bound.
        mission.parts = try partTable(&mission, .parts, .script);
        mission.parts_b = try partTable(&mission, .parts_b, .script_b);
        mission.waypoints = try listWaypoints(gpa, try mission.ships());
        errdefer gpa.free(mission.waypoints);
        mission.group_ships = try listGroupShips(gpa, try mission.flightGroups(), try mission.ships());
        errdefer gpa.free(mission.group_ships);
        mission.records = try resolveObjects(gpa, file);
        return mission;
    }

    pub fn deinit(mission: *Mission) void {
        mission.gpa.free(mission.records);
        mission.gpa.free(mission.group_ships);
        mission.gpa.free(mission.waypoints);
        mission.gpa.free(mission.image);
    }

    /// The mission's ships, as the engine writes them.
    pub fn ships(mission: Mission) dte.Error![]align(1) dte.Ship {
        // The image is the mission's own, and writable.
        return @constCast(try mission.file.ships());
    }

    /// How many ships the mission places (`mission_ships_count`, `0x00529504`): none where the
    /// file's ships cannot be read.
    pub fn shipCount(mission: Mission) usize {
        const all = mission.ships() catch return 0;
        return all.len;
    }

    pub fn flightGroups(mission: Mission) dte.Error![]align(1) dte.FlightGroup {
        return @constCast(try mission.file.flightGroups());
    }

    /// The trigger list, as the engine arms and disarms its triggers.
    pub fn triggers(mission: Mission) dte.Error![]align(1) dte.Trigger {
        return @constCast(try mission.file.triggers());
    }

    /// Where the block `offset` bytes into the code of section `code` lies in the image, as
    /// `mission_fill_part` (`0x00452FD0`) and `trigger_match` (`0x0045CEA0`) take a part's and a
    /// trigger's (`dte.Part.block`, `dte.Trigger.block`): null for none.
    ///
    /// **Fix:** the game takes the code of a section the mission leaves unused from the place
    /// `dte.DirectoryEntry.unused_offset` gives, whatever lies there; OpenReliant gives no block.
    pub fn blockAt(mission: *const Mission, code: dte.Section, offset: ?usize) ?u32 {
        const entry = mission.file.entry(code);
        if (!entry.isUsed()) return null;
        return std.math.cast(u32, entry.offset + (offset orelse return null));
    }

    /// The mission's ship `index`, as the engine writes it: null past the ships, or where the
    /// file's ships cannot be read.
    pub fn ship(mission: Mission, index: usize) ?*align(1) dte.Ship {
        const all = mission.ships() catch return null;
        return if (index < all.len) &all[index] else null;
    }

    /// The mission's flight group `index`: null past the flight groups, or where the file's flight
    /// groups cannot be read.
    pub fn flightGroup(mission: Mission, index: usize) ?*align(1) dte.FlightGroup {
        const all = mission.flightGroups() catch return null;
        return if (index < all.len) &all[index] else null;
    }

    /// The ships of flight group `group`: as many as its count from its first in the list.
    ///
    /// **Fix:** the game reads a group's ships past the list's end where its first ship's place
    /// and its count run past it; OpenReliant stops there.
    pub fn groupShips(mission: Mission, group: dte.FlightGroup) []const u16 {
        const first = @min(group.firstShip() orelse return &.{}, mission.group_ships.len);
        return mission.group_ships[first..][0..@min(group.ship_count, mission.group_ships.len - first)];
    }

    /// The record object `id` of the object table stands for: null past the table, or where no
    /// record stands for it.
    pub fn recordOf(mission: Mission, id: usize) ?Record {
        return if (id < mission.records.len) mission.records[id] else null;
    }

    // --- The records, as the script names them -----------------------------------------------

    /// The place of no record: what a ship of no flight group names (`ship_flight_group`,
    /// `0x00452AB9`), and one of the places the lookups take for none (`ship_index`, `0x004531C0`).
    pub const no_place: u32 = 0;

    /// The place of every bit set, which `push_null` pushes for no object, and which the lookups
    /// take for none (`ship_index`, `0x004531C4`).
    pub const null_place: u32 = 0xFFFF_FFFF;

    /// The record index the lookups give for none (`ship_index`, `0x004531EC`), which they take
    /// for none as a place too (`0x004531C9`).
    pub const no_record: u16 = 0xFFFF;

    /// The place `place` names a record at, as the lookups take it (`ship_index`'s compares,
    /// `0x004531C0` to `0x004531CF`): null for `no_place`, `null_place` and `no_record`.
    pub fn named(place: u32) ?u32 {
        return switch (place) {
            no_place, null_place, no_record => null,
            else => place,
        };
    }

    /// `record_object_id` (`0x00453200`): the object ID of the ship, flight group or squad whose
    /// record lies at `place`, which the record starts with. **Fix:** the game reads it wherever
    /// `place` points; OpenReliant gives none for a place that names none (`named`), and for one
    /// outside the image.
    pub fn objectId(mission: *const Mission, place: u32) ?u16 {
        return mission.halfword(named(place) orelse return null) catch null;
    }

    /// `ship_index` (`0x004531C0`): the index among the mission's ships of the ship at `place`,
    /// the value the script names it by; null for a place that names none (`named`), which the
    /// game gives as `no_record`. Like the game, it takes any other place for a ship's.
    pub fn shipIndex(mission: *const Mission, place: u32) ?u16 {
        return mission.recordIndex(.ships, place);
    }

    /// `flight_group_index` (`0x00452060`): the same for a flight group.
    pub fn flightGroupIndex(mission: *const Mission, place: u32) ?u16 {
        return mission.recordIndex(.flight_groups, place);
    }

    /// `squad_index` (`0x00453070`): the same for a squad.
    pub fn squadIndex(mission: *const Mission, place: u32) ?u16 {
        return mission.recordIndex(.squads, place);
    }

    /// `curve_index` (`0x004524E0`): the same for a curve. **Fix:** the game counts a curve from
    /// any place, those that name none too, which give whatever index their distance from the
    /// curves comes to; OpenReliant gives none for them.
    pub fn curveIndex(mission: *const Mission, place: u32) ?u16 {
        return mission.recordIndex(.curves, place);
    }

    /// The index among section `section`'s records of the record at `place`: how many records
    /// from the section's first it lies, as a halfword; null for a place that names none.
    fn recordIndex(mission: *const Mission, comptime section: dte.Section, place: u32) ?u16 {
        const stride = comptime section.stride().?;
        const at = named(place) orelse return null;
        return @truncate((at -% mission.file.entry(section).offset) / stride);
    }

    /// What `recordKind` tells a place for: a ship's, a flight group's or a squad's, numbered as
    /// the object table's kinds are (`dte.Object.Kind`).
    pub const RecordKind = std.meta.Tag(Record);

    /// `record_kind` (`0x00453590`): whether `place` is a ship's, a flight group's or a squad's,
    /// taking the place just past a section's last record for one of its own, as the game does;
    /// null for anything else, which the game gives as `0xFFFF`.
    pub fn recordKind(mission: *const Mission, place: u32) ?RecordKind {
        inline for (.{ .{ dte.Section.ships, RecordKind.ship }, .{ dte.Section.flight_groups, RecordKind.flight_group }, .{ dte.Section.squads, RecordKind.squad } }) |pair| {
            const entry = mission.file.entry(pair[0]);
            const end = entry.offset +% @as(u32, entry.count) * comptime pair[0].stride().?;
            if (place >= entry.offset and place <= end) return pair[1];
        }
        return null;
    }

    /// Whether `place` lies among the records section `section` holds.
    pub fn holds(mission: *const Mission, comptime section: dte.Section, place: u32) bool {
        const entry = mission.file.entry(section);
        const end = entry.offset +% @as(u32, entry.count) * comptime section.stride().?;
        return entry.count != 0 and place >= entry.offset and place < end;
    }

    /// Where record `index` of section `section` lies, which the game pushes as the record's
    /// address, whether or not the section holds it.
    pub fn recordPlace(mission: *const Mission, comptime section: dte.Section, index: usize) u32 {
        const stride = comptime section.stride().?;
        return @truncate(mission.file.entry(section).offset +% index * stride);
    }

    /// Where global `index`'s value lies.
    pub fn globalPlace(mission: *const Mission, index: u8) u32 {
        return mission.recordPlace(.globals, index) +% @offsetOf(dte.Global, "value");
    }

    /// Where the field `offset` bytes into the record at `place` lies: past the address space, as
    /// for `null_place`, it faults, as the game's read there does.
    pub fn fieldPlace(place: u32, offset: u32) ReadError!u32 {
        return std.math.add(u32, place, offset) catch error.OutsideImage;
    }

    /// `ship_flight_group` (`0x00452AA0`): where the record of the flight group the ship at `place`
    /// names lies, or `no_place` for a ship of no flight group. It reads the ship's flight group
    /// wherever `place` lies, as the game does (`fieldPlace`).
    pub fn shipFlightGroup(mission: *const Mission, place: u32) ReadError!u32 {
        const group = try mission.byte(try fieldPlace(place, @offsetOf(dte.Ship, "flight_group")));
        if (group == dte.Ship.no_flight_group) return no_place;
        return mission.recordPlace(.flight_groups, group);
    }

    // --- The image, as the script reads it ---------------------------------------------------

    /// The records of section `section`, which fault where they run past the image.
    pub fn recordsIn(mission: *const Mission, comptime T: type, section: dte.Section) ReadError![]align(1) const T {
        return mission.file.records(T, section) catch error.OutsideImage;
    }

    /// The `count` bytes of the image at `at`, as the engine writes them.
    pub fn bytes(mission: *const Mission, at: u32, count: u32) ReadError![]u8 {
        const image = mission.image;
        if (at > image.len or count > image.len - at) return error.OutsideImage;
        return image[at..][0..count];
    }

    pub fn byte(mission: *const Mission, at: u32) ReadError!u8 {
        return (try mission.bytes(at, 1))[0];
    }

    /// The halfword at `at`, big-endian, as the script's two-byte operands are.
    pub fn big(mission: *const Mission, at: u32) ReadError!u16 {
        return std.mem.readInt(u16, (try mission.bytes(at, 2))[0..2], .big);
    }

    pub fn halfword(mission: *const Mission, at: u32) ReadError!u16 {
        return std.mem.readInt(u16, (try mission.bytes(at, 2))[0..2], .little);
    }

    pub fn word(mission: *const Mission, at: u32) ReadError!u32 {
        return std.mem.readInt(u32, (try mission.bytes(at, 4))[0..4], .little);
    }

    /// The text a string argument points at in the image (`push_string`), up to its terminating
    /// zero.
    pub fn text(mission: *const Mission, at: u32) ReadError![]const u8 {
        const image = mission.image;
        if (at >= image.len) return error.OutsideImage;
        const rest = image[at..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse return error.OutsideImage];
    }

    /// The members of squad `squad`, reached `depth` squads down a walk, as `squad_walk`
    /// (`0x00401D80`) and a condition's count of a squad's members (`condition_squad_add`,
    /// `0x004533D0`) take them, from the squad's first: none where the mission has no such squad.
    ///
    /// **Fix:** the game walks a squad that holds itself round for ever, reads a member no record
    /// stands for from address zero, and stops with a fatal error at a member of a kind it does not
    /// know ("oh disaster, biblical proportions" in `squad_walk`, "unknown ai group member" in
    /// `condition_squad_add`); OpenReliant gives no members once a walk has gone down more squads
    /// than the mission has, and passes over such a member (`SquadMembers`).
    pub fn squadMembers(mission: *const Mission, squad: u16, depth: usize) SquadMembers {
        const squads = mission.file.squads() catch &.{};
        if (squad >= squads.len or depth > squads.len) return .{ .mission = mission, .squad = squad, .members = &.{} };
        return mission.squadMembersFrom(squad, squads[squad].first_member);
    }

    /// The members of squad `squad` from member `first` of the squads' members on, as
    /// `for_each_ship` (`0x0045D480`) takes them, reading where the squad's members start from the
    /// place the script names it by: none from past the squads' members, or where the file's
    /// members cannot be read.
    pub fn squadMembersFrom(mission: *const Mission, squad: u16, first: usize) SquadMembers {
        const members = mission.file.records(dte.SquadMember, .squad_members) catch &.{};
        return .{ .mission = mission, .squad = squad, .members = members[@min(first, members.len)..] };
    }

    /// A squad's members in turn, from its first while they are its own, each as the record it
    /// names: a ship as the component its membership names, a flight group, or a squad. It passes
    /// over a member no record stands for, and a flight group past the mission's.
    pub const SquadMembers = struct {
        mission: *const Mission,
        squad: u16,
        /// The squads' members from the next one on.
        members: []align(1) const dte.SquadMember,

        pub const Member = union(enum) {
            /// A ship by its index among the mission's ships, and its component, or null for the
            /// whole ship.
            ship: struct { index: u16, component: ?u8 },
            flight_group: dte.FlightGroup,
            /// A squad by its index among the mission's squads.
            squad: u16,
        };

        pub fn next(each: *SquadMembers) ?Member {
            while (each.members.len > 0) {
                const member = each.members[0];
                each.members = each.members[1..];
                if (member.squad != each.squad) {
                    each.members = &.{};
                    return null;
                }
                const record = each.mission.recordOf(member.object_id) orelse continue;
                return switch (record) {
                    .ship => |index| .{ .ship = .{ .index = index, .component = member.part() } },
                    .flight_group => |index| .{ .flight_group = (each.mission.flightGroup(index) orelse continue).* },
                    .squad => |index| .{ .squad = index },
                };
            }
            return null;
        }
    };
};

/// `mission_build_part_tables` (`0x00452F50`)'s filling of one part table from the part
/// descriptors of section `descriptors`, each part's block in section `code` (`mission_fill_part`,
/// `0x00452FD0`, `Mission.blockAt`). **Fix:** the game fills the table from every descriptor, past
/// its 256 entries.
fn partTable(mission: *const Mission, descriptors: dte.Section, code: dte.Section) dte.Error!vm.Parts {
    var table: vm.Parts = @splat(.{});
    const found = try mission.file.records(dte.Part, descriptors);
    const count = @min(found.len, table.len);
    for (table[0..count], found[0..count]) |*entry, part| entry.* = .{
        .block = mission.blockAt(code, part.block()),
        .argument_count = part.arguments,
    };
    return table;
}

/// The top byte of a reference `recordReference` makes (`0x004513D0`).
const reference_high: u8 = 0xFF;

/// `record_reference` (`0x004513A0`): the reference to the record of tag `tag` that is `index`
/// among its section's, or to none (`dte.Reference.unset`), as `for_each_ship_note`
/// (`0x0045D720`) has each ship's object name the first ship of a walk. The game counts the index
/// from the record's address; its top byte is `reference_high`.
pub fn recordReference(tag: dte.Reference.Tag, index: ?u16) dte.Reference {
    return .{ .index = index orelse dte.Reference.unset, .tag = tag, ._unknown_24 = reference_high };
}

/// `mission_ships_reset` (`0x00452010`): each ship's run-time place and angles set to those it is
/// placed at.
pub fn resetShips(ships: []align(1) dte.Ship) void {
    for (ships) |*ship| {
        ship.runtime_position = ship.position;
        ship.runtime_yaw = ship.yaw;
        ship.runtime_pitch = ship.pitch;
        ship.runtime_roll = ship.roll;
    }
}

/// `mission_list_waypoints` (`0x00452100`): the waypoints in flight groups, a group at a time. It
/// takes the first waypoint not yet listed, then every later one of the same group, marking each
/// listed, until none is left.
fn listWaypoints(gpa: Allocator, ships: []align(1) dte.Ship) Allocator.Error![]Mission.Waypoint {
    for (ships) |*ship| ship.waypoint_listed = 0;
    var listed: std.ArrayList(Mission.Waypoint) = .empty;
    errdefer listed.deinit(gpa);
    while (true) {
        var group: ?u8 = null;
        for (ships, 0..) |*ship, index| {
            if (!ship.isWaypoint() or ship.waypoint_listed != 0) continue;
            const own = ship.flightGroup() orelse continue;
            if (group == null) group = own;
            if (own != group.?) continue;
            ship.waypoint_listed = 1;
            try listed.append(gpa, .{ .group = own, .ship = @intCast(index) });
        }
        if (group == null) break;
    }
    return listed.toOwnedSlice(gpa);
}

/// `mission_list_group_ships` (`0x00452EC0`): each flight group's ships, in the order the mission
/// lists them, and the group's count of them and the first one's place.
fn listGroupShips(gpa: Allocator, groups: []align(1) dte.FlightGroup, ships: []align(1) const dte.Ship) Allocator.Error![]u16 {
    var listed: std.ArrayList(u16) = .empty;
    errdefer listed.deinit(gpa);
    for (groups, 0..) |*group, index| {
        group.ship_count = 0;
        group.first_ship = dte.FlightGroup.no_ship;
        for (ships, 0..) |ship, at| {
            if (ship.flight_group != index) continue;
            if (group.firstShip() == null) group.first_ship = @intCast(listed.items.len);
            try listed.append(gpa, @intCast(at));
            group.ship_count +%= 1;
        }
    }
    return listed.toOwnedSlice(gpa);
}

/// `mission_resolve_objects` (`0x00452DB0`): for each entry of the object table, the record it
/// stands for (`mission_object_record`, `0x00452DF0`): of its kind, the first whose object ID is
/// the entry's.
fn resolveObjects(gpa: Allocator, file: dte.Mission) !([]?Mission.Record) {
    const objects = try file.objects();
    const records = try gpa.alloc(?Mission.Record, objects.len);
    errdefer gpa.free(records);
    for (objects, records, 0..) |object, *record, id| {
        record.* = switch (object.kind) {
            .ship => if (firstWithId(dte.Ship, try file.ships(), id)) |at| .{ .ship = at } else null,
            .flight_group => if (firstWithId(dte.FlightGroup, try file.flightGroups(), id)) |at| .{ .flight_group = at } else null,
            .squad => if (firstWithId(dte.Squad, try file.squads(), id)) |at| .{ .squad = at } else null,
            _ => null,
        };
    }
    return records;
}

/// The index of the first of `records` whose object ID, taken as 16 bits, is `id`.
fn firstWithId(comptime T: type, records: []align(1) const T, id: usize) ?u16 {
    for (records, 0..) |record, at| {
        if (@as(u16, @truncate(record.object_id)) == id) return @intCast(at);
    }
    return null;
}

/// A mission image for the tests, written as the shipped missions are laid out (`dte.write`), each
/// section's entry with the flags `formats`.
pub const testing = struct {
    pub const Sections = struct {
        ships: []const dte.Ship = &.{},
        flight_groups: []const dte.FlightGroup = &.{},
        objects: []const dte.Object = &.{},
        squads: []const dte.Squad = &.{},
        squad_members: []const dte.SquadMember = &.{},
        formats: dte.DirectoryEntry.Formats = .all,
    };

    pub fn image(gpa: Allocator, sections: Sections) dte.write.Error![]u8 {
        var written: dte.write.Sections = @splat(.{});
        inline for (.{
            .{ dte.Section.ships, sections.ships },
            .{ dte.Section.flight_groups, sections.flight_groups },
            .{ dte.Section.objects, sections.objects },
            .{ dte.Section.squads, sections.squads },
            .{ dte.Section.squad_members, sections.squad_members },
        }) |pair| dte.write.set(&written, pair[0], pair[1].len, std.mem.sliceAsBytes(pair[1]));
        return dte.write.write(gpa, &written, .{ .formats = sections.formats });
    }
};

test "Mission.bind" {
    const gpa = std.testing.allocator;
    const waypoint = dte.Ship.waypoint_kind;
    var placed = dte.testing.ship(0, 0, 43);
    placed.position = .{ 100, 200, 300 };
    placed.yaw = 90;
    placed.pitch = 10;
    placed.roll = -1;
    const image = try testing.image(gpa, .{
        .ships = &.{
            placed,
            dte.testing.ship(1, 1, waypoint),
            dte.testing.ship(2, 2, waypoint),
            dte.testing.ship(3, 1, waypoint),
            dte.testing.ship(4, 0, 43),
            dte.testing.ship(5, dte.Ship.no_flight_group, waypoint),
        },
        .flight_groups = &.{ dte.testing.flightGroup(6, .none), dte.testing.flightGroup(7, .none), dte.testing.flightGroup(8, .none) },
        .objects = &(.{dte.testing.object(.ship, 0, 0)} ** 6 ++ .{
            dte.testing.object(.flight_group, 0, 0),
            dte.testing.object(.flight_group, 0, 0),
            dte.testing.object(.squad, 0, 0),
            dte.testing.object(@enumFromInt(7), 0, 0),
        }),
        .formats = .{ .first = true, .second = true, .third = true },
    });
    var mission: Mission = try .bind(gpa, image);
    defer mission.deinit();

    try std.testing.expectEqual(dte.DirectoryEntry.Formats{ .first = true, .second = true, .third = true }, mission.formats);
    // Each ship stands where it is placed.
    const ships = try mission.ships();
    try std.testing.expectEqual([3]f32{ 100, 200, 300 }, ships[0].runtime_position);
    try std.testing.expectEqual(90, ships[0].runtime_yaw);
    try std.testing.expectEqual(10, ships[0].runtime_pitch);
    try std.testing.expectEqual(-1, ships[0].runtime_roll);

    // The waypoints a group at a time, each group's in order; one in no group is left out.
    try std.testing.expectEqualSlices(Mission.Waypoint, &.{ .{ .group = 1, .ship = 1 }, .{ .group = 1, .ship = 3 }, .{ .group = 2, .ship = 2 } }, mission.waypoints);
    try std.testing.expectEqual(0, ships[5].waypoint_listed);

    // Each group's ships, and their place in the list.
    const groups = try mission.flightGroups();
    try std.testing.expectEqualSlices(u16, &.{ 0, 4 }, mission.groupShips(groups[0]));
    try std.testing.expectEqualSlices(u16, &.{ 1, 3 }, mission.groupShips(groups[1]));
    try std.testing.expectEqual(2, groups[1].first_ship);

    // Each object's record: its ship or group; none for a squad the mission lacks, or an unknown
    // kind.
    try std.testing.expectEqual(Mission.Record{ .ship = 3 }, mission.records[3].?);
    try std.testing.expectEqual(Mission.Record{ .flight_group = 1 }, mission.records[7].?);
    try std.testing.expectEqual(null, mission.records[8]);
    try std.testing.expectEqual(null, mission.records[9]);
    try std.testing.expectEqual(Mission.Record{ .flight_group = 1 }, mission.recordOf(7).?);
    try std.testing.expectEqual(null, mission.recordOf(8));
    try std.testing.expectEqual(null, mission.recordOf(10));

    // A ship or a flight group by its index, the engine's to write; none past the last.
    try std.testing.expectEqual(4, mission.ship(4).?.object_id);
    mission.ship(4).?.runtime_yaw = 45;
    try std.testing.expectEqual(45, ships[4].runtime_yaw);
    try std.testing.expectEqual(null, mission.ship(6));
    try std.testing.expectEqual(7, mission.flightGroup(1).?.object_id);
    try std.testing.expectEqual(null, mission.flightGroup(3));
}

test "Mission.squadMembers" {
    const gpa = std.testing.allocator;
    const member = dte.testing.squadMember;
    const object = dte.testing.object;
    const whole = dte.Trigger.whole_object;
    // Squad 0 holds ship 0's component 2, the flight group, an object no record stands for, ship 1
    // whole and squad 1, which holds ship 0 whole. Squad 2 holds itself.
    const image = try testing.image(gpa, .{
        .ships = &.{ dte.testing.ship(0, 0, 43), dte.testing.ship(1, dte.Ship.no_flight_group, 43) },
        .flight_groups = &.{dte.testing.flightGroup(2, .none)},
        .objects = &.{ object(.ship, 0, 0), object(.ship, 0, 0), object(.flight_group, 0, 0), object(.squad, 0, 0), object(.squad, 0, 0), object(.squad, 0, 0), object(.squad, 0, 0) },
        .squads = &.{ dte.testing.squad(3, 0), dte.testing.squad(4, 5), dte.testing.squad(6, 6) },
        .squad_members = &.{ member(0, 0, 2), member(2, 0, whole), member(5, 0, whole), member(1, 0, whole), member(4, 0, whole), member(0, 1, whole), member(6, 2, whole) },
    });
    var mission: Mission = try .bind(gpa, image);
    defer mission.deinit();

    const Member = Mission.SquadMembers.Member;
    var members = mission.squadMembers(0, 0);
    try std.testing.expectEqual(Member{ .ship = .{ .index = 0, .component = 2 } }, members.next().?);
    const group = members.next().?.flight_group;
    try std.testing.expectEqual(2, group.object_id);
    try std.testing.expectEqualSlices(u16, &.{0}, mission.groupShips(group));
    try std.testing.expectEqual(Member{ .ship = .{ .index = 1, .component = null } }, members.next().?);
    try std.testing.expectEqual(Member{ .squad = 1 }, members.next().?);
    // The next member is another squad's, which ends the walk.
    try std.testing.expectEqual(null, members.next());
    try std.testing.expectEqual(null, members.next());
    var inner = mission.squadMembers(1, 1);
    try std.testing.expectEqual(Member{ .ship = .{ .index = 0, .component = null } }, inner.next().?);
    try std.testing.expectEqual(null, inner.next());
    // A squad the mission lacks has no members.
    var missing = mission.squadMembers(3, 0);
    try std.testing.expectEqual(null, missing.next());
    // A squad that holds itself gives itself while the walk is no more squads down than the
    // mission has, and nothing after, so a walk down it ends.
    var depth: usize = 0;
    while (true) : (depth += 1) {
        var cycle = mission.squadMembers(2, depth);
        const found = cycle.next() orelse break;
        try std.testing.expectEqual(Member{ .squad = 2 }, found);
    }
    try std.testing.expectEqual(4, depth);
    // From a member of the squad's on, and from past the members, none.
    var from = mission.squadMembersFrom(0, 3);
    try std.testing.expectEqual(Member{ .ship = .{ .index = 1, .component = null } }, from.next().?);
    try std.testing.expectEqual(Member{ .squad = 1 }, from.next().?);
    try std.testing.expectEqual(null, from.next());
    var past = mission.squadMembersFrom(0, 7);
    try std.testing.expectEqual(null, past.next());
}

test "the records, as the script names them" {
    const gpa = std.testing.allocator;
    var ships = dte.testing.ships(2, 43);
    ships[1].flight_group = 1;
    const groups = [_]dte.FlightGroup{ dte.testing.flightGroup(2, .none), dte.testing.flightGroup(3, .none) };
    const squads = [_]dte.Squad{dte.testing.squad(4, 0)};
    const curves = [_]dte.Curve{dte.testing.curve(0, 1, @splat(0), @splat(0))};
    const globals = [_]dte.Global{.{ .name = 0, ._unknown_02 = 0, .value = 7, ._unknown_08 = 0 }};
    var sections: dte.write.Sections = @splat(.{});
    dte.write.set(&sections, .ships, ships.len, std.mem.sliceAsBytes(&ships));
    dte.write.set(&sections, .flight_groups, groups.len, std.mem.sliceAsBytes(&groups));
    dte.write.set(&sections, .squads, squads.len, std.mem.sliceAsBytes(&squads));
    dte.write.set(&sections, .curves, curves.len, std.mem.sliceAsBytes(&curves));
    dte.write.set(&sections, .globals, globals.len, std.mem.sliceAsBytes(&globals));
    dte.write.set(&sections, .strings, 3, "Hi\x00");
    var mission: Mission = try .bind(gpa, try dte.write.write(gpa, &sections, .{}));
    defer mission.deinit();

    // A place names nothing where it is zero, every bit set or `no_record`.
    for ([_]u32{ Mission.no_place, Mission.null_place, Mission.no_record }) |nothing| {
        try std.testing.expectEqual(null, Mission.named(nothing));
        try std.testing.expectEqual(null, mission.objectId(nothing));
        try std.testing.expectEqual(null, mission.shipIndex(nothing));
        try std.testing.expectEqual(null, mission.curveIndex(nothing));
    }
    const ship = mission.recordPlace(.ships, 1);
    try std.testing.expectEqual(ship, Mission.named(ship).?);
    try std.testing.expectEqual(mission.file.entry(.ships).offset + @sizeOf(dte.Ship), ship);

    // Each record by its place: its index, and the object ID it starts with.
    try std.testing.expectEqual(1, mission.shipIndex(ship));
    try std.testing.expectEqual(1, mission.flightGroupIndex(mission.recordPlace(.flight_groups, 1)));
    try std.testing.expectEqual(0, mission.squadIndex(mission.recordPlace(.squads, 0)));
    try std.testing.expectEqual(0, mission.curveIndex(mission.recordPlace(.curves, 0)));
    try std.testing.expectEqual(3, mission.objectId(mission.recordPlace(.flight_groups, 1)));
    try std.testing.expectEqual(null, mission.objectId(@intCast(mission.image.len)));

    // Its kind, the place just past a section's last record one of its own, and none further.
    const past = mission.recordPlace(.ships, ships.len);
    try std.testing.expectEqual(.ship, mission.recordKind(ship).?);
    try std.testing.expectEqual(.ship, mission.recordKind(past).?);
    try std.testing.expectEqual(null, mission.recordKind(mission.recordPlace(.ships, ships.len + 1)));
    try std.testing.expectEqual(.flight_group, mission.recordKind(mission.recordPlace(.flight_groups, 0)).?);
    try std.testing.expectEqual(.squad, mission.recordKind(mission.recordPlace(.squads, 0)).?);
    try std.testing.expect(mission.holds(.ships, ship) and !mission.holds(.ships, past));

    // A ship's flight group, none for a ship of none; a ship at `null_place` faults.
    try std.testing.expectEqual(mission.recordPlace(.flight_groups, 1), try mission.shipFlightGroup(ship));
    try std.testing.expectEqual(Mission.no_place, try mission.shipFlightGroup(mission.recordPlace(.ships, 0)));
    try std.testing.expectError(error.OutsideImage, mission.shipFlightGroup(Mission.null_place));

    // A global's value, the text a place points at, and nothing past the image.
    try std.testing.expectEqual(7, try mission.word(mission.globalPlace(0)));
    try std.testing.expectEqualStrings("Hi", try mission.text(mission.file.entry(.strings).offset));
    try std.testing.expectError(error.OutsideImage, mission.halfword(@intCast(mission.image.len - 1)));
    try std.testing.expectError(error.OutsideImage, mission.text(@intCast(mission.image.len)));

    // A block of the script, none for none.
    try std.testing.expectEqual(mission.file.entry(.script).offset + 4, mission.blockAt(.script, 4).?);
    try std.testing.expectEqual(null, mission.blockAt(.script, null));
}

test "Mission.blockAt" {
    const gpa = std.testing.allocator;
    // The mission leaves its script unused: no part, nor trigger, runs a block of it.
    const image = try testing.image(gpa, .{});
    const directory = std.mem.bytesAsSlice(dte.DirectoryEntry, image[0 .. dte.section_count * @sizeOf(dte.DirectoryEntry)]);
    directory[@intFromEnum(dte.Section.script)].offset = dte.DirectoryEntry.unused_offset;
    var mission: Mission = try .bind(gpa, image);
    defer mission.deinit();
    try std.testing.expect(!mission.file.entry(.script).isUsed());
    try std.testing.expectEqual(null, mission.blockAt(.script, 0));
}

test recordReference {
    try std.testing.expectEqual(@as(u32, 0xFF00_0003), @as(u32, @bitCast(recordReference(.ship, 3))));
    try std.testing.expectEqual(@as(u32, 0xFF01_FFFF), @as(u32, @bitCast(recordReference(.flight_group, null))));
}

test read {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try bigfile.testing.write(gpa, io, tmp.dir, bigfile.resource_name, &.{
        .{ .name = "mission1.dte", .data = "archive one" },
        .{ .name = "mission2.dte", .data = "archive two" },
    });
    var resources: bigfile.Hog = try .open(gpa, io, tmp.dir, bigfile.resource_name);
    defer resources.close(gpa);
    try tmp.dir.createDirPath(io, "Missions");
    try tmp.dir.writeFile(io, .{ .sub_path = "Missions/MISSION1.DTE", .data = "loose one" });

    // A loose file stands in for the archive's, whatever its case.
    const one = (try read(io, gpa, tmp.dir, &resources, ".\\missions\\mission1.dte")).?;
    defer gpa.free(one.image);
    try std.testing.expectEqualStrings("loose one", one.image);
    try std.testing.expectEqual(.loose, one.source);
    const two = (try read(io, gpa, tmp.dir, &resources, ".\\missions\\mission2.dte")).?;
    defer gpa.free(two.image);
    try std.testing.expectEqualStrings("archive two", two.image);
    try std.testing.expectEqual(.archive, two.source);
    // A mission in neither is none.
    try std.testing.expectEqual(null, try read(io, gpa, tmp.dir, &resources, ".\\missions\\mission3.dte"));

    // A mod's comes before the loose file, and adds a mission the game lacks.
    try tmp.dir.createDirPath(io, "mods/missions");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/missions/Mission1.dte", .data = "mod one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/missions/mission3.dte", .data = "mod three" });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir);
    defer mods.close(gpa);
    resources.mods = &mods;
    for ([_][]const u8{ "mod one", "archive two", "mod three" }, [_]Source{ .mod, .archive, .mod }, 1..) |image, source, number| {
        var buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, ".\\missions\\mission{d}.dte", .{number});
        const file = (try read(io, gpa, tmp.dir, &resources, path)).?;
        defer gpa.free(file.image);
        try std.testing.expectEqualStrings(image, file.image);
        try std.testing.expectEqual(source, file.source);
    }
}
