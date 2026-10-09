//! The game's records: the stat tables and the text, available to scripts as
//! `openreliant.records` ([#498](https://github.com/OpenReliant/openreliant/issues/498)). Load
//! scripts can change them before the game reads them; other scripts can only read them.
//!
//! The record tables are `ships`, `guns`, `missiles` and `pilots` from the stat files
//! ([Stat tables](../../docs/formats/stats.md)); `ship_types`, the class and the other words the
//! game's executable holds for each ship type; `faces`, the pilots' faces from the executable;
//! `text` from `language.dll`; and `itac_text` from the ITAC's `itaclang.dll`. Records are indexed
//! by the game's numbers: guns and text from 1, the rest from 0. All but the text can also be
//! looked up by OpenReliant's names, such as `records.guns.laser_cannon` or
//! `records.ships.predator`, and what the mods add by its qualified name, such as
//! `records.ships["teapot:teapot"]`. A record is a proxy (`bind.Binding`)
//! whose fields are named as in the format docs, and a text entry is a string. Records can't be
//! removed, because missions refer to them by number. Adding new ones isn't supported yet
//! ([#333](https://github.com/OpenReliant/openreliant/issues/333),
//! [#640](https://github.com/OpenReliant/openreliant/issues/640)).
//!
//! `campaign` is the campaign's missions in the order it flies them (`game.gameflow.Order`). Scripts
//! get it as a new list of the missions' numbers each time, and load scripts change it by assigning
//! a new list ([#975](https://github.com/OpenReliant/openreliant/issues/975)).
//!
//! `missions` holds the campaign's settings for each of its missions, by its number
//! (`game.gameflow.CampaignMission`), `killboard` the ITAC's KILLBOARD's pilots
//! (`game.itac.killboard.Pilot`), and `maneuvers` the combat maneuvers (`game.aidefend.Compiled`).
//! Each entry is a proxy whose fields load scripts change in place, as they change a record's
//! ([#976](https://github.com/OpenReliant/openreliant/issues/976),
//! [#1008](https://github.com/OpenReliant/openreliant/issues/1008),
//! [#1024](https://github.com/OpenReliant/openreliant/issues/1024)). Load scripts can also add
//! maneuvers.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const stats = openreliant.stats;
const game = openreliant.engine.game;
const language = game.language;
const gameflow = game.gameflow;
const luau = @import("luau.zig");
const State = luau.State;
const bind = @import("bind.zig");
const values = @import("values.zig");
const runtime = @import("runtime.zig");

pub const missions = @import("records/missions.zig");
pub const killboard = @import("records/killboard.zig");
pub const maneuvers = @import("records/maneuvers.zig");

/// The tables whose entries have named fields (`records/table.zig`), each a module that declares
/// `script_name`, `list_name`, `Field`, `TypeOf`, `about`, `each` and `entries_about`.
pub const field_tables = .{ missions, killboard, maneuvers };

/// The proxies for records.
pub const Values = bind.Binding(&.{ stats.Ship, game.create.combat_stats.Static, stats.Gun, stats.Missile, stats.Pilot, game.pilots.FaceRecord }, @backingInt(runtime.Tag.record_value), "record");

/// Editable copies of the game's tables.
pub const Records = struct {
    ships: []stats.Ship,
    /// Each ship type's words that the game keeps in its executable rather than `shipstats.bin`:
    /// its class, its side, the string that names it, whether it can be targeted and which form of
    /// the target display shows it (`ship_combat_stats`).
    ship_types: []game.create.combat_stats.Static,
    guns: []stats.Gun,
    missiles: []stats.Missile,
    pilots: []stats.Pilot,
    /// The pilots' faces, which the game keeps in its executable (`pilot_faces`).
    faces: []game.pilots.FaceRecord,
    /// The strings of `language.dll` in the game's code page. Index 0 holds string id 1.
    text: [][]const u8,
    /// The strings of the ITAC's `itaclang.dll`, stored the same way.
    itac_text: [][]const u8,
    /// The campaign's missions in the order it flies them, which the game takes once the load
    /// scripts have run (`game.gameflow.install`).
    campaign: game.gameflow.Order,
    /// What the campaign makes of each of its missions, by its number from 1, which the game reads
    /// from as it goes, once the load scripts have run (`gameflow.installMissions`). Their names are
    /// in `arena`.
    missions: []gameflow.CampaignMission,
    /// The KILLBOARD's pilots, which the game takes once the load scripts have run
    /// (`itac.killboard.install`). Their text is in `arena`.
    killboard: []game.itac.killboard.Pilot,
    /// The combat maneuvers, which the game takes with the stats (`aidefend.install`). Load scripts
    /// can add to them. Their names and their scripts, as text and compiled, are in `arena`.
    maneuvers: []game.aidefend.Compiled,
    /// Where text from scripts is allocated. It must live as long as the game's original strings.
    arena: Allocator,

    /// The tables as read from the game's files.
    pub const Tables = struct {
        ships: []align(1) const stats.Ship,
        ship_types: []const game.create.combat_stats.Static,
        guns: []align(1) const stats.Gun,
        missiles: []align(1) const stats.Missile,
        pilots: []align(1) const stats.Pilot,
        faces: []const game.pilots.FaceRecord,
        text: []const []const u8,
        itac_text: []const []const u8,
        campaign: game.gameflow.Order = .original,
        missions: []const gameflow.CampaignMission = &gameflow.CampaignMission.original,
        killboard: []const game.itac.killboard.Pilot = &game.itac.killboard.Pilot.original,
        maneuvers: []const game.aidefend.Compiled = &game.aidefend.Compiled.original,
    };

    /// Copies `tables` into `arena`.
    pub fn init(arena: Allocator, tables: Tables) Allocator.Error!Records {
        return .{
            .ships = try copy(arena, stats.Ship, tables.ships),
            .ship_types = try arena.dupe(game.create.combat_stats.Static, tables.ship_types),
            .guns = try copy(arena, stats.Gun, tables.guns),
            .missiles = try copy(arena, stats.Missile, tables.missiles),
            .pilots = try copy(arena, stats.Pilot, tables.pilots),
            .faces = try arena.dupe(game.pilots.FaceRecord, tables.faces),
            .text = try arena.dupe([]const u8, tables.text),
            .itac_text = try arena.dupe([]const u8, tables.itac_text),
            .campaign = tables.campaign,
            .missions = try arena.dupe(gameflow.CampaignMission, tables.missions),
            .killboard = try arena.dupe(game.itac.killboard.Pilot, tables.killboard),
            .maneuvers = try arena.dupe(game.aidefend.Compiled, tables.maneuvers),
            .arena = arena,
        };
    }

    fn copy(arena: Allocator, comptime T: type, records: []align(1) const T) Allocator.Error![]T {
        const copied = try arena.alloc(T, records.len);
        @memcpy(std.mem.sliceAsBytes(copied), std.mem.sliceAsBytes(records));
        return copied;
    }

    /// One of the text tables, in the form the game reads strings.
    pub fn language(records: Records, comptime set: Set) game.language.Language {
        comptime std.debug.assert(set.isText());
        return .{ .strings = @field(records, @tagName(set)) };
    }

    /// The number of records in `set` that scripts can access: as many as the game reads from the
    /// file, and for the ships, then those of the types mods add (`additions.ships`).
    pub fn count(records: Records, comptime set: Set) usize {
        const held = @field(records, @tagName(set)).len;
        const table = (comptime set.table()) orelse return held;
        const added = if (comptime set.Added()) |Family| Family.all().len else 0;
        return @min(held, table.load().capacity() + added);
    }

    /// Saves a copy of all tables, which `Snapshot.restore` puts back if a script fails.
    pub fn snapshot(records: Records, gpa: Allocator) Allocator.Error!Snapshot {
        var saved: Snapshot = undefined;
        saved.campaign = records.campaign;
        saved.missions = try gpa.dupe(gameflow.CampaignMission, records.missions);
        errdefer gpa.free(saved.missions);
        saved.killboard = try gpa.dupe(game.itac.killboard.Pilot, records.killboard);
        errdefer gpa.free(saved.killboard);
        saved.maneuvers = try gpa.dupe(game.aidefend.Compiled, records.maneuvers);
        errdefer gpa.free(saved.maneuvers);
        saved.maneuvers_held = records.maneuvers;
        inline for (comptime std.enums.values(Set), 0..) |set, made| {
            errdefer inline for (comptime std.enums.values(Set)[0..made]) |done| gpa.free(@field(saved, @tagName(done)));
            @field(saved, @tagName(set)) = try gpa.dupe(set.Element(), @field(records, @tagName(set)));
        }
        return saved;
    }

    pub const Snapshot = struct {
        ships: []stats.Ship,
        ship_types: []game.create.combat_stats.Static,
        guns: []stats.Gun,
        missiles: []stats.Missile,
        pilots: []stats.Pilot,
        faces: []game.pilots.FaceRecord,
        text: [][]const u8,
        itac_text: [][]const u8,
        campaign: game.gameflow.Order,
        missions: []gameflow.CampaignMission,
        killboard: []game.itac.killboard.Pilot,
        maneuvers: []game.aidefend.Compiled,
        /// The maneuvers' table itself, which adding a maneuver replaces with a longer one, maybe
        /// in an arena that's freed after the script runs (`game_modes.ModeRecords`).
        maneuvers_held: []game.aidefend.Compiled,

        pub fn restore(saved: Snapshot, records: *Records) void {
            inline for (comptime std.enums.values(Set)) |set| @memcpy(@field(records, @tagName(set)), @field(saved, @tagName(set)));
            records.campaign = saved.campaign;
            @memcpy(records.missions, saved.missions);
            @memcpy(records.killboard, saved.killboard);
            records.maneuvers = saved.maneuvers_held;
            @memcpy(records.maneuvers, saved.maneuvers);
        }

        pub fn deinit(saved: Snapshot, gpa: Allocator) void {
            inline for (comptime std.enums.values(Set)) |set| gpa.free(@field(saved, @tagName(set)));
            gpa.free(saved.missions);
            gpa.free(saved.killboard);
            gpa.free(saved.maneuvers);
        }
    };
};

/// The record tables.
pub const Set = enum {
    ships,
    ship_types,
    guns,
    missiles,
    pilots,
    faces,
    text,
    itac_text,

    /// The type of the table's records.
    pub fn Element(comptime set: Set) type {
        return @typeInfo(@FieldType(Records, @tagName(set))).pointer.child;
    }

    /// The number of the first record. Guns start at 1, as muzzles number them, and text at 1, as
    /// string ids do. The rest start at 0.
    pub fn first(set: Set) u32 {
        return switch (set) {
            .guns, .text, .itac_text => 1,
            .ships, .ship_types, .missiles, .pilots, .faces => 0,
        };
    }

    /// The stat file the table comes from, if any.
    pub fn table(set: Set) ?stats.Table {
        return switch (set) {
            .ships => .ships,
            .guns => .guns,
            .missiles => .missiles,
            .pilots => .pilots,
            .ship_types, .faces, .text, .itac_text => null,
        };
    }

    /// The family of records the mods add to the table (`game.additions`), if they add any.
    fn Added(comptime set: Set) ?type {
        return switch (set) {
            .ships, .ship_types => game.additions.ships,
            .guns => game.additions.guns,
            .missiles => game.additions.missiles,
            .pilots, .faces => game.additions.pilots,
            .text, .itac_text => null,
        };
    }

    fn isText(set: Set) bool {
        return switch (set) {
            .text, .itac_text => true,
            .ships, .ship_types, .guns, .missiles, .pilots, .faces => false,
        };
    }

    /// OpenReliant's names for records in the table, with their numbers.
    fn names(comptime set: Set) []const Named {
        comptime {
            @setEvalBranchQuota(20_000);
            var named: []const Named = &.{};
            switch (set) {
                .ships, .ship_types => for (std.enums.values(game.gameobj.GameType)) |ship| {
                    const number = @backingInt(ship);
                    if (number < stats.Table.ships.load().capacity()) named = named ++ .{Named{ .name = @tagName(ship), .number = number }};
                },
                .guns => for (std.enums.values(game.guns.GameGun)) |gun| {
                    named = named ++ .{Named{ .name = @tagName(gun), .number = gun.number() }};
                },
                .missiles => for (std.enums.values(game.missiles.GameMissile)) |missile| {
                    if (missile != .none) named = named ++ .{Named{ .name = @tagName(missile), .number = @intCast(@backingInt(missile)) }};
                },
                .pilots, .faces => for (std.enums.values(game.pilots.GamePilot)) |pilot| {
                    named = named ++ .{Named{ .name = @tagName(pilot), .number = @backingInt(pilot) }};
                },
                .text, .itac_text => {},
            }
            return named;
        }
    }

    const Named = struct { name: []const u8, number: u32 };
};

/// The userdata for a record table.
const SetProxy = struct {
    records: *Records,
    set: Set,
    writable: bool,

    const tag = @backingInt(runtime.Tag.record_set);

    fn of(state: *State, at: i32) *const SetProxy {
        return state.checkUserdata(SetProxy, at, tag, "a record table");
    }
};

/// Registers the metatables for records and record tables.
pub fn register(state: *State) void {
    Values.register(state);
    state.registerUserdata(SetProxy.tag, "records", &.{
        .{ "__index", luau.wrap(index) },
        .{ "__newindex", luau.wrap(newIndex) },
        .{ "__iter", luau.wrap(iterate) },
        .{ "__len", luau.wrap(length) },
        .{ "__tostring", luau.wrap(describe) },
    });
    inline for (field_tables) |Table| Table.register(state);
}

/// Pushes the `openreliant.records` package: a read-only table holding the record tables, the
/// campaign's missions (`campaign`), the settings of each (`missions`), the KILLBOARD's pilots
/// (`killboard`) and the combat maneuvers (`maneuvers`), which scripts can change only if
/// `writable`. Call `register` first.
pub fn push(state: *State, records: *Records, writable: bool) void {
    state.newTable(0, std.enums.values(Set).len + field_tables.len);
    inline for (comptime std.enums.values(Set)) |set| {
        const proxy = state.newUserdata(SetProxy, SetProxy.tag);
        proxy.* = .{ .records = records, .set = set, .writable = writable };
        state.rawSetField(-2, @tagName(set));
    }
    inline for (field_tables) |Table| {
        Table.push(state, records, writable);
        state.rawSetField(-2, Table.list_name);
    }
    // `campaign` isn't held in the table, so that reading it gives a new list each time, and Luau
    // calls `__newindex` to assign it, read-only as the table is.
    state.newTable(0, 3);
    state.pushClosure(luau.wrap(getCampaign), "__index", records);
    state.rawSetField(-2, "__index");
    state.pushClosure(if (writable) luau.wrap(setCampaign) else luau.wrap(refuseChange), "__newindex", records);
    state.rawSetField(-2, "__newindex");
    state.lockMetatable();
    state.setReadonly(-1, true);
    state.setMetatable(-2);
    state.setReadonly(-1, true);
}

/// The campaign's missions as scripts get and give them: a list of their numbers.
const CampaignList = values.List(u16, game.gameflow.last_mission);

/// The name scripts give the campaign's missions in the package.
const campaign_name = "campaign";

fn isCampaign(state: *State, key: i32) bool {
    return state.typeOf(key) == .string and std.mem.eql(u8, state.toString(key).?, campaign_name);
}

/// The package's `__index`: `campaign` is a new list of the campaign's missions, in order, which a
/// script can change and then assign. Any other name the package doesn't hold is nil.
fn getCampaign(state: *State) i32 {
    if (!isCampaign(state, 2)) {
        state.pushNil();
        return 1;
    }
    const records = state.upvalue(Records);
    var list: CampaignList = .{};
    for (records.campaign.missions()) |mission| list.append(mission);
    values.push(state, CampaignList, list);
    return 1;
}

/// The package's `__newindex` for load scripts: `records.campaign = list` makes the list the
/// campaign's missions, in order (`game.gameflow.Order.of`).
fn setCampaign(state: *State) i32 {
    if (!isCampaign(state, 2)) return refuseChange(state);
    const records = state.upvalue(Records);
    const list = values.read(state, CampaignList, 3, "records.campaign");
    records.campaign = game.gameflow.Order.of(list.slice()) catch |err| state.raise("records.campaign: {s}", .{switch (err) {
        error.Empty => "the campaign needs at least one mission",
        error.OutOfRange => std.fmt.comptimePrint("a mission's number must be from {d} to {d}", .{ game.gameflow.first_mission, game.gameflow.last_mission }),
        error.NotRising => "the missions' numbers must rise, each listed once",
    }});
    return 0;
}

/// The package's `__newindex` for the other scripts, and for anything but `campaign`.
fn refuseChange(state: *State) i32 {
    if (isCampaign(state, 2)) state.raise("records can only be changed by load scripts", .{});
    state.raise("attempt to modify a readonly table", .{});
}

/// `__index`: looks up a record by number or name, returning nil if there is none.
fn index(state: *State) i32 {
    const proxy = SetProxy.of(state, 1);
    switch (proxy.set) {
        inline else => |set| {
            const place = placeOf(state, proxy.records.*, set, 2) orelse {
                state.pushNil();
                return 1;
            };
            pushRecord(state, proxy.records, set, place, proxy.writable);
        },
    }
    return 1;
}

/// `__newindex`: replaces a record. For text, the value is a string. For any other record, it is a
/// table of the fields to change; if it has a `template` record, the record is copied from the
/// template first.
fn newIndex(state: *State) i32 {
    const proxy = SetProxy.of(state, 1);
    if (!proxy.writable) state.raise("records can only be changed by load scripts", .{});
    switch (proxy.set) {
        inline else => |set| {
            const place = placeOf(state, proxy.records.*, set, 2) orelse {
                _ = state.toDisplay(2);
                state.raise("{t}[{s}] does not exist (adding records is not supported yet)", .{ set, state.toString(-1).? });
            };
            if (state.typeOf(3) == .nil) state.raise("records can't be removed: missions refer to them by number", .{});
            const records = proxy.records;
            if (comptime set.isText()) {
                @field(records, @tagName(set))[place] = textOf(state, records.arena, 3, "text");
            } else {
                const T = set.Element();
                const record = &@field(records, @tagName(set))[place];
                if (state.typeOf(3) != .table) state.raise("{t}: expected a table of fields, got {s}", .{ set, state.typeName(3) });
                if (state.rawGetField(3, "template") != .nil) {
                    const template = Values.pointer(state, T, -1) orelse state.raise("template must be a record from {t}", .{set});
                    record.* = template.*;
                }
                state.pop(1);
                Values.assign(state, T, record, 3, &.{"template"});
            }
        },
    }
    return 0;
}

/// `__iter`: iterates over the records in order, as number and record.
fn iterate(state: *State) i32 {
    state.pushFunction(luau.wrap(step), "next");
    state.pushCopy(1);
    state.pushNil();
    return 3;
}

/// Returns the record after the given number, or nothing after the last.
fn step(state: *State) i32 {
    const proxy = SetProxy.of(state, 1);
    switch (proxy.set) {
        inline else => |set| {
            const place: usize = if (state.typeOf(2) == .nil) 0 else next: {
                const previous = bind.wholeIndex(state.toNumber(2) orelse return 0) orelse return 0;
                if (previous < set.first()) return 0;
                break :next previous + 1 - set.first();
            };
            if (place >= proxy.records.count(set)) return 0;
            state.pushNumber(@floatFromInt(place + set.first()));
            pushRecord(state, proxy.records, set, place, proxy.writable);
            return 2;
        },
    }
}

/// `__len`: the number of records.
fn length(state: *State) i32 {
    const proxy = SetProxy.of(state, 1);
    switch (proxy.set) {
        inline else => |set| state.pushNumber(@floatFromInt(proxy.records.count(set))),
    }
    return 1;
}

fn describe(state: *State) i32 {
    state.pushString(@tagName(SetProxy.of(state, 1).set));
    return 1;
}

/// The 0-based position of the record the key at `key` refers to, by number or name. Returns null
/// if there is no such record.
fn placeOf(state: *State, records: Records, comptime set: Set, key: i32) ?usize {
    const number: usize = if (state.toNumber(key)) |number|
        bind.wholeIndex(number) orelse return null
    else if (state.toString(key)) |name| named: {
        for (comptime set.names()) |named| {
            if (std.mem.eql(u8, name, named.name)) break :named named.number;
        }
        // What the mods add, by its qualified name.
        const found = if (comptime set.Added()) |Family| Family.find(name) else null;
        if (found) |number| break :named number;
        return null;
    } else return null;
    if (number < set.first()) return null;
    const place = number - set.first();
    return if (place < records.count(set)) place else null;
}

/// Pushes a record: a proxy for a stat record, or a UTF-8 string for text.
fn pushRecord(state: *State, records: *Records, comptime set: Set, place: usize, writable: bool) void {
    const held = @field(records, @tagName(set));
    if (comptime set.isText()) return pushText(state, held[place]);
    Values.push(state, set.Element(), &held[place], writable);
}

/// Pushes a string from the game's code page, converted to UTF-8.
pub fn pushText(state: *State, text: []const u8) void {
    var buffer: [language.max_length * language.max_utf8_bytes]u8 = undefined;
    state.pushString(language.decode(&buffer, text[0..@min(text.len, language.max_length)]));
}

/// Converts the UTF-8 string at `given` to the game's code page and copies it into `arena`.
/// Characters the code page doesn't have become `?` (`language.encode`). Raises an error that names
/// `label` if the value isn't a valid UTF-8 string or is longer than the game allows
/// (`language.max_length`).
pub fn textOf(state: *State, arena: Allocator, given: i32, comptime label: []const u8) []const u8 {
    const text = state.toString(given) orelse state.raise(label ++ ": expected a string, got {s}", .{state.typeName(given)});
    return encoded(state, arena, text, label);
}

/// Converts `text`, a UTF-8 string a script gave, as `textOf` does.
pub fn encoded(state: *State, arena: Allocator, text: []const u8, comptime label: []const u8) []const u8 {
    const characters = std.unicode.utf8CountCodepoints(text) catch state.raise(label ++ ": the string is not valid UTF-8", .{});
    if (characters > language.max_length) state.raise(label ++ ": expected at most {d} characters, got {d}", .{ language.max_length, characters });
    var buffer: [language.max_length]u8 = undefined;
    return arena.dupe(u8, language.encode(&buffer, text)) catch state.raise(label ++ ": out of memory", .{});
}

test {
    std.testing.refAllDecls(@This());
}

test "records can be read and changed by number and by name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var guns: [2]stats.Gun = @splat(std.mem.zeroes(stats.Gun));
    guns[0].range = 1000;
    guns[1].range = 2000;
    var records: Records = try .init(arena.allocator(), .{
        .ships = &.{},
        .ship_types = &.{},
        .guns = &guns,
        .missiles = &.{},
        .pilots = &.{},
        .faces = &.{},
        .text = &.{ "Laser Cannon", "Caf\xe9" },
        .itac_text = &.{},
    });

    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    register(state);
    push(state, &records, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();
    luau.testing.exposeMetatables(thread);

    try bind.testing.runSource(thread,
        \\local guns = records.guns
        \\assert(#guns == 2 and guns[1].range == 1000 and guns.laser_cannon == guns[1] and guns.pulse_cannon.range == 2000)
        \\assert(guns[0] == nil and guns[3] == nil and guns.nothing == nil)
        \\guns.laser_cannon.damage.hull = 30
        \\guns[2] = { template = guns[1], speed = 5 }
        \\local count = 0
        \\for number, gun in guns do count += number end
        \\assert(count == 3)
        \\assert(records.text[1] == "Laser Cannon" and records.text[2] == "Café")
        \\records.text[1] = "Ion Repeater €"
        \\local step = rawgetmetatable(guns).__iter(guns)
        \\assert(step(guns, -1) == nil and step(guns, 0.5) == nil and step(guns, 1e30) == nil)
    );
    try std.testing.expectEqual(30, records.guns[0].damage.hull);
    try std.testing.expectEqual(1000, records.guns[1].range);
    try std.testing.expectEqual(5, records.guns[1].speed);
    try std.testing.expectEqualStrings("Ion Repeater \x80", records.text[0]);

    try bind.testing.expectSourceError(thread, "records.guns[3] = {}", "guns[3] does not exist (adding records is not supported yet)");
    try bind.testing.expectSourceError(thread, "records.guns[1] = nil", "records can't be removed");
    try bind.testing.expectSourceError(thread, "records.guns[1] = 5", "guns: expected a table of fields, got number");
    try bind.testing.expectSourceError(thread, "records.guns[1] = { template = records.text }", "template must be a record from guns");
    try bind.testing.expectSourceError(thread, "records.text[1] = 'x' .. string.rep('y', 998)", "text: expected at most 998 characters, got 999");
    try bind.testing.expectSourceError(thread, "records.ships = nil", "readonly");
}

test "ship records by the game's names and by the qualified names of the types mods add" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ships = game.additions.ships;
    var list = [_]ships.Added{.{ .name = "pots:teapot", .mod = "pots", .base = .phoenix, .extra = .{ .model = "teapot.shp" } }};
    ships.install(&list);
    defer ships.reset();
    var game_ships: [12]stats.Ship = @splat(std.mem.zeroes(stats.Ship));
    game_ships[@backingInt(game.gameobj.GameType.phoenix)].max_speed = 300;
    var records: Records = try .init(arena.allocator(), .{
        .ships = try ships.records(stats.Ship, arena.allocator(), &game_ships, 0),
        .ship_types = &.{},
        .guns = &.{},
        .missiles = &.{},
        .pilots = &.{},
        .faces = &.{},
        .text = &.{},
        .itac_text = &.{},
    });

    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    register(state);
    push(state, &records, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\local ships = records.ships
        \\assert(ships.phoenix.max_speed == 300 and ships.phoenix == ships[11])
        \\local teapot = ships["pots:teapot"]
        \\assert(teapot == ships[256] and teapot.max_speed == 300)
        \\teapot.max_speed = 150
        \\assert(ships.phoenix.max_speed == 300 and ships["nobody:teapot"] == nil)
    );
    try std.testing.expectEqual(150, records.ships[ships.first].max_speed);
}

test "the campaign's missions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var records: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    register(state);
    push(state, &records, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\-- A local, as scripts hold the package: Luau keeps what it reads through a global.
        \\local records = records
        \\local campaign = records.campaign
        \\assert(#campaign == 24 and campaign[12] == 14 and table.find(campaign, 12) == nil)
        \\-- Each read gives a new list, and changing it changes nothing until it's assigned.
        \\table.insert(campaign, 12)
        \\assert(#records.campaign == 24)
        \\for _, mission in { 13, 17, 22 } do
        \\    table.insert(campaign, mission)
        \\end
        \\table.sort(campaign)
        \\records.campaign = campaign
        \\assert(#records.campaign == 28 and records.campaign[12] == 12)
        \\assert(records.nothing == nil)
    );
    try std.testing.expectEqual(28, records.campaign.missions().len);
    try std.testing.expectEqual(13, records.campaign.next(12));

    try bind.testing.expectSourceError(thread, "records.campaign = {}", "records.campaign: the campaign needs at least one mission");
    try bind.testing.expectSourceError(thread, "records.campaign = { 1, 29 }", "records.campaign: a mission's number must be from 1 to 28");
    try bind.testing.expectSourceError(thread, "records.campaign = { 2, 1 }", "records.campaign: the missions' numbers must rise, each listed once");
    try bind.testing.expectSourceError(thread, "records.campaign = 5", "records.campaign");
    try bind.testing.expectSourceError(thread, "records.anything = 1", "readonly");
    // A list that fails leaves the campaign as it was.
    try std.testing.expectEqual(28, records.campaign.missions().len);
}

test "read-only records" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var guns: [1]stats.Gun = @splat(std.mem.zeroes(stats.Gun));
    var records: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &.{}, .guns = &guns, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{"x"}, .itac_text = &.{} });
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    register(state);
    push(state, &records, false);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();
    try bind.testing.runSource(thread, "assert(records.guns[1].range == 0 and records.text[1] == 'x' and #records.campaign == 24)");
    try bind.testing.expectSourceError(thread, "records.guns[1].range = 1", "this record is read-only");
    try bind.testing.expectSourceError(thread, "records.text[1] = 'y'", "records can only be changed by load scripts");
    try bind.testing.expectSourceError(thread, "records.campaign = { 1 }", "records can only be changed by load scripts");
}

test "the ship types' words the executable holds" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var records: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &game.create.combat_stats.ship_types, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    register(state);
    push(state, &records, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\local shuttle = records.ship_types.yakob_shuttle
        \\assert(shuttle.class == "support" and shuttle.side == "hostile" and tostring(shuttle) == "ShipTypeRecord")
        \\assert(records.ship_types[0].class == "fighter")
        \\shuttle.class = "fighter"
    );
    try std.testing.expectEqual(.fighter, records.ship_types[@backingInt(game.gameobj.GameType.yakob_shuttle)].class);
    try bind.testing.expectSourceError(thread, "records.ship_types.yakob_shuttle.class = 'gunboat'", "class");
}

test "the pilots' faces" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const faces = [_]game.pilots.FaceRecord{ .of(&game.pilots.faces[0]), .of(&game.pilots.faces[4]) };
    var records: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &faces, .text = &.{}, .itac_text = &.{} });
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    register(state);
    push(state, &records, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\local moose = records.faces[1]
        \\assert(#records.faces == 2 and records.faces[0].talking == "45TigersWL_Bandit")
        \\assert(moose.name == 131 and moose.dying == "45Volntrs_Moose_d" and tostring(moose) == "Face")
        \\records.faces[1] = { template = records.faces[0], talking = "Ronin_Plt" }
        \\moose.dying = "Ronin_Plt_D"
    );
    try std.testing.expectEqual(33, records.faces[1].name);
    try std.testing.expectEqualStrings("Ronin_Plt", std.mem.sliceTo(&records.faces[1].talking, 0));
    try std.testing.expectEqualStrings("45TigersWL_Bandit_L", std.mem.sliceTo(&records.faces[1].laughing, 0));
    try std.testing.expectEqualStrings("Ronin_Plt_D", std.mem.sliceTo(&records.faces[1].dying, 0));
    try bind.testing.expectSourceError(thread, "records.faces[1].talking = string.rep('x', 117)", "Face.talking: expected at most 116 bytes, got 117");
    try bind.testing.expectSourceError(thread, "records.faces[1] = { template = records.text }", "template must be a record from faces");
}

test "Records.snapshot" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var guns: [1]stats.Gun = @splat(std.mem.zeroes(stats.Gun));
    var records: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &.{}, .guns = &guns, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{"x"}, .itac_text = &.{} });
    const saved = try records.snapshot(std.testing.allocator);
    defer saved.deinit(std.testing.allocator);
    records.guns[0].range = 5;
    records.text[0] = "y";
    records.campaign = try .of(&.{1});
    records.missions[11].carrier = .yamato;
    saved.restore(&records);
    try std.testing.expectEqual(0, records.guns[0].range);
    try std.testing.expectEqualStrings("x", records.text[0]);
    try std.testing.expectEqual(game.gameflow.Order.original, records.campaign);
    try std.testing.expectEqual(.reliant, records.missions[11].carrier);
}

test "the field names scripts see don't change" {
    // Scripts use these names. Renaming a field in the formats breaks mods.
    const expected = .{
        .{ stats.Ship, "name,max_speed,inertia,yaw_rate,yaw_inertia,pitch_rate,pitch_inertia,roll_rate,roll_inertia,shield_power,armor_class,afterburner_fuel,shield_recharge,gun_energy,gun_recharge,rounds" },
        .{ stats.Gun, "name,range,speed,damage,fire_rate,shot_energy" },
        .{ stats.Damage, "shield,hull" },
        .{ stats.Missile, "name,speed,turn_rate,flight_time,damage,lock_time,decoy_chance,lock_range,component_damage" },
        .{ stats.Pilot, "name,tier_a,tier_b,tier_c,skill" },
        .{ game.pilots.FaceRecord, "name,talking,laughing,squadron,dying" },
        .{ game.create.combat_stats.Static, "targetable,name,class,side,display" },
    };
    inline for (expected) |pinned| {
        comptime var names: []const u8 = "";
        inline for (comptime values.shownFields(pinned[0]), 0..) |field, at| names = names ++ (if (at == 0) "" else ",") ++ field.name;
        try std.testing.expectEqualStrings(pinned[1], names);
    }
    try std.testing.expectEqual(1, Set.guns.first());
    try std.testing.expectEqual(0, Set.ships.first());
}
