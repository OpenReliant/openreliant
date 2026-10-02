//! The game's records: the stat tables and the text, available to scripts as
//! `openreliant.records` ([#498](https://github.com/OpenReliant/openreliant/issues/498)). Load
//! scripts can change them before the game reads them; other scripts can only read them.
//!
//! The record tables are `ships`, `guns`, `missiles` and `pilots` from the stat files
//! ([Stat tables](../../docs/formats/stats.md)), plus `text` from `language.dll` and `itac_text`
//! from the ITAC's `itaclang.dll`. Records are indexed by the game's numbers: guns and text from 1,
//! the rest from 0. Ships, guns and missiles can also be looked up by OpenReliant's names, such as
//! `records.guns.laser_cannon` or `records.ships.predator`. A record is a proxy (`bind.Binding`)
//! whose fields are named as in the format docs, and a text entry is a string. Records can't be
//! removed, because missions refer to them by number, and adding new ones isn't supported yet
//! ([#560](https://github.com/OpenReliant/openreliant/issues/560)).

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const stats = openreliant.stats;
const game = openreliant.engine.game;
const language = game.language;
const luau = @import("luau.zig");
const State = luau.State;
const bind = @import("bind.zig");
const runtime = @import("runtime.zig");

/// The proxies for records.
pub const Values = bind.Binding(&.{ stats.Ship, stats.Gun, stats.Missile, stats.Pilot }, @intFromEnum(runtime.Tag.record_value), "record");

/// Editable copies of the game's tables.
pub const Records = struct {
    ships: []stats.Ship,
    guns: []stats.Gun,
    missiles: []stats.Missile,
    pilots: []stats.Pilot,
    /// The strings of `language.dll` in the game's code page. Index 0 holds string id 1.
    text: [][]const u8,
    /// The strings of the ITAC's `itaclang.dll`, stored the same way.
    itac_text: [][]const u8,
    /// Where text from scripts is allocated. It must live as long as the game's original strings.
    arena: Allocator,

    /// The tables as read from the game's files.
    pub const Tables = struct {
        ships: []align(1) const stats.Ship,
        guns: []align(1) const stats.Gun,
        missiles: []align(1) const stats.Missile,
        pilots: []align(1) const stats.Pilot,
        text: []const []const u8,
        itac_text: []const []const u8,
    };

    /// Copies `tables` into `arena`.
    pub fn init(arena: Allocator, tables: Tables) Allocator.Error!Records {
        return .{
            .ships = try copy(arena, stats.Ship, tables.ships),
            .guns = try copy(arena, stats.Gun, tables.guns),
            .missiles = try copy(arena, stats.Missile, tables.missiles),
            .pilots = try copy(arena, stats.Pilot, tables.pilots),
            .text = try arena.dupe([]const u8, tables.text),
            .itac_text = try arena.dupe([]const u8, tables.itac_text),
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
    /// file.
    pub fn count(records: Records, comptime set: Set) usize {
        const held = @field(records, @tagName(set)).len;
        return if (comptime set.table()) |table| @min(held, table.load().capacity()) else held;
    }

    /// Saves a copy of all tables, which `Snapshot.restore` puts back if a script fails.
    pub fn snapshot(records: Records, gpa: Allocator) Allocator.Error!Snapshot {
        var saved: Snapshot = undefined;
        inline for (comptime std.enums.values(Set), 0..) |set, made| {
            errdefer inline for (comptime std.enums.values(Set)[0..made]) |done| gpa.free(@field(saved, @tagName(done)));
            @field(saved, @tagName(set)) = try gpa.dupe(set.Element(), @field(records, @tagName(set)));
        }
        return saved;
    }

    pub const Snapshot = struct {
        ships: []stats.Ship,
        guns: []stats.Gun,
        missiles: []stats.Missile,
        pilots: []stats.Pilot,
        text: [][]const u8,
        itac_text: [][]const u8,

        pub fn restore(saved: Snapshot, records: *Records) void {
            inline for (comptime std.enums.values(Set)) |set| @memcpy(@field(records, @tagName(set)), @field(saved, @tagName(set)));
        }

        pub fn deinit(saved: Snapshot, gpa: Allocator) void {
            inline for (comptime std.enums.values(Set)) |set| gpa.free(@field(saved, @tagName(set)));
        }
    };
};

/// The record tables.
pub const Set = enum {
    ships,
    guns,
    missiles,
    pilots,
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
            .ships, .missiles, .pilots => 0,
        };
    }

    /// The stat file the table comes from, if any.
    pub fn table(set: Set) ?stats.Table {
        return switch (set) {
            .ships => .ships,
            .guns => .guns,
            .missiles => .missiles,
            .pilots => .pilots,
            .text, .itac_text => null,
        };
    }

    fn isText(set: Set) bool {
        return set.table() == null;
    }

    /// OpenReliant's names for records in the table, with their numbers.
    fn names(comptime set: Set) []const Named {
        comptime {
            var named: []const Named = &.{};
            switch (set) {
                .ships => for (std.enums.values(game.gameobj.Type)) |ship| {
                    const number = @intFromEnum(ship);
                    if (number < stats.Table.ships.load().capacity()) named = named ++ .{Named{ .name = @tagName(ship), .number = number }};
                },
                .guns => for (std.enums.values(game.guns.GunType)) |gun| {
                    named = named ++ .{Named{ .name = @tagName(gun), .number = gun.number() }};
                },
                .missiles => for (std.enums.values(game.missiles.Type)) |missile| {
                    if (missile.index()) |number| named = named ++ .{Named{ .name = @tagName(missile), .number = number }};
                },
                .pilots, .text, .itac_text => {},
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

    const tag = @intFromEnum(runtime.Tag.record_set);

    fn of(state: *State, at: i32) *const SetProxy {
        return state.toUserdata(SetProxy, at, tag) orelse state.raise("expected a record table", .{});
    }
};

/// Registers the metatables for records and record tables.
pub fn register(state: *State) void {
    Values.register(state);
    state.newTable(0, 8);
    inline for (.{
        .{ "__index", luau.wrap(index) },
        .{ "__newindex", luau.wrap(newIndex) },
        .{ "__iter", luau.wrap(iterate) },
        .{ "__len", luau.wrap(length) },
        .{ "__tostring", luau.wrap(describe) },
    }) |entry| {
        state.pushFunction(entry[1], entry[0]);
        state.rawSetField(-2, entry[0]);
    }
    state.pushString("records");
    state.rawSetField(-2, "__type");
    state.setReadonly(-1, true);
    state.setUserdataMetatable(SetProxy.tag);
}

/// Pushes the `openreliant.records` package: a read-only table holding the record tables, which
/// scripts can change only if `writable`. Call `register` first.
pub fn push(state: *State, records: *Records, writable: bool) void {
    state.newTable(0, std.enums.values(Set).len);
    inline for (comptime std.enums.values(Set)) |set| {
        const proxy = state.newUserdata(SetProxy, SetProxy.tag);
        proxy.* = .{ .records = records, .set = set, .writable = writable };
        state.rawSetField(-2, @tagName(set));
    }
    state.setReadonly(-1, true);
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

/// `__newindex`: replaces a record. For a stat record, the value is a table of the fields to
/// change; if it has a `template` record, the record is copied from the template first. For text,
/// the value is a string.
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
                @field(records, @tagName(set))[place] = textOf(state, records.arena, 3);
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
        inline for (comptime set.names()) |named| {
            if (std.mem.eql(u8, name, named.name)) break :named named.number;
        }
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
fn pushText(state: *State, text: []const u8) void {
    var buffer: [language.max_length * max_utf8_bytes]u8 = undefined;
    var len: usize = 0;
    for (text[0..@min(text.len, language.max_length)]) |byte| {
        len += std.unicode.utf8Encode(language.toUnicode(byte), buffer[len..]) catch encoded: {
            buffer[len] = '?';
            break :encoded 1;
        };
    }
    state.pushString(buffer[0..len]);
}

/// The most bytes a character from the game's code page needs in UTF-8.
const max_utf8_bytes = 3;

/// Converts the UTF-8 string at `given` to the game's code page and copies it into `arena`.
/// Characters the code page doesn't have become `?` (`language.encode`). Raises an error if the
/// value isn't a valid UTF-8 string or is longer than the game allows (`language.max_length`).
fn textOf(state: *State, arena: Allocator, given: i32) []const u8 {
    const text = state.toString(given) orelse state.raise("text: expected a string, got {s}", .{state.typeName(given)});
    const characters = std.unicode.utf8CountCodepoints(text) catch state.raise("text: the string is not valid UTF-8", .{});
    if (characters > language.max_length) state.raise("text: expected at most {d} characters, got {d}", .{ language.max_length, characters });
    var buffer: [language.max_length]u8 = undefined;
    return arena.dupe(u8, language.encode(&buffer, text)) catch state.raise("text: out of memory", .{});
}

test "records can be read and changed by number and by name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var guns: [2]stats.Gun = @splat(std.mem.zeroes(stats.Gun));
    guns[0].range = 1000;
    guns[1].range = 2000;
    var records: Records = try .init(arena.allocator(), .{
        .ships = &.{},
        .guns = &guns,
        .missiles = &.{},
        .pilots = &.{},
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
        \\local step = getmetatable(guns).__iter(guns)
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

test "read-only records" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var guns: [1]stats.Gun = @splat(std.mem.zeroes(stats.Gun));
    var records: Records = try .init(arena.allocator(), .{ .ships = &.{}, .guns = &guns, .missiles = &.{}, .pilots = &.{}, .text = &.{"x"}, .itac_text = &.{} });
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    register(state);
    push(state, &records, false);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();
    try bind.testing.runSource(thread, "assert(records.guns[1].range == 0 and records.text[1] == 'x')");
    try bind.testing.expectSourceError(thread, "records.guns[1].range = 1", "this record is read-only");
    try bind.testing.expectSourceError(thread, "records.text[1] = 'y'", "records can only be changed by load scripts");
}

test "Records.snapshot" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var guns: [1]stats.Gun = @splat(std.mem.zeroes(stats.Gun));
    var records: Records = try .init(arena.allocator(), .{ .ships = &.{}, .guns = &guns, .missiles = &.{}, .pilots = &.{}, .text = &.{"x"}, .itac_text = &.{} });
    const saved = try records.snapshot(std.testing.allocator);
    defer saved.deinit(std.testing.allocator);
    records.guns[0].range = 5;
    records.text[0] = "y";
    saved.restore(&records);
    try std.testing.expectEqual(0, records.guns[0].range);
    try std.testing.expectEqualStrings("x", records.text[0]);
}

test "the field names scripts see don't change" {
    // Scripts use these names. Renaming a field in the formats breaks mods.
    const expected = .{
        .{ stats.Ship, "name,max_speed,inertia,yaw_rate,yaw_inertia,pitch_rate,pitch_inertia,roll_rate,roll_inertia,shield_power,armor_class,afterburner_fuel,shield_recharge,gun_energy,gun_recharge,rounds" },
        .{ stats.Gun, "name,range,speed,damage,fire_rate,shot_energy" },
        .{ stats.Damage, "shield,hull" },
        .{ stats.Missile, "name,speed,turn_rate,flight_time,damage,lock_time,decoy_chance,lock_range,component_damage" },
        .{ stats.Pilot, "name,tier_a,tier_b,tier_c,skill" },
    };
    inline for (expected) |pinned| {
        comptime var names: []const u8 = "";
        inline for (comptime bind.fieldsOf(pinned[0]), 0..) |field, at| names = names ++ (if (at == 0) "" else ",") ++ field.name;
        try std.testing.expectEqualStrings(pinned[1], names);
    }
    try std.testing.expectEqual(1, Set.guns.first());
    try std.testing.expectEqual(0, Set.ships.first());
}
