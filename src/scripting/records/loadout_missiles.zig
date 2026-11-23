//! The missiles the loadout offers, as scripts see them in `openreliant.records.loadout_missiles`
//! ([#1555](https://github.com/OpenReliant/openreliant/issues/1555)): the game's ten, from the
//! Screamer, numbered 0, to the fuel pod, numbered 9, in the loadout's order
//! (`interface.loadout.tables.Missile`). Scripts can also look one up by its name, such as
//! `jack_hammer`. Each entry has a `limit`: how many of that missile a ship can carry. Load scripts
//! can change it, and the loadout uses the limits once they have run (`tables.installLimits`). A
//! mod's missile uses its base's limit.

const std = @import("std");

const openreliant = @import("openreliant");
const tables = openreliant.engine.interface.loadout.tables;
const luau = @import("../luau.zig");
const State = luau.State;
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const Records = records.Records;
const table = @import("table.zig");

/// The name scripts know a loadout missile by.
pub const script_name = "LoadoutMissile";

/// How the reference and the definitions introduce the missiles.
pub const each = "Each of the missiles the loadout offers";
pub const entries_about = "The game's missiles in the loadout, by their number from 0 or by their name, such as `jack_hammer`. Load scripts change their fields.";

/// What the proxies need of the missiles (`table.Table`).
pub const list_name = "loadout_missiles";
pub const described = "the loadout's missiles";
pub const item_noun = "a loadout missile";
pub const list_tag = @backingInt(runtime.Tag.loadout_missiles);
pub const item_tag = @backingInt(runtime.Tag.loadout_missile);
/// The number of the first missile: the Screamer's.
pub const first = 0;

/// How many missiles the records hold: the game's ten.
pub fn count(held: *const Records) usize {
    return held.loadout_missiles.len;
}

/// The missile a script names `text`, such as `jack_hammer`.
pub fn placeNamed(_: *State, _: *const Records, text: []const u8) ?usize {
    const missile = std.meta.stringToEnum(tables.Missile, text) orelse return null;
    return @backingInt(missile);
}

/// The proxies of the missiles (`table.Table`).
const proxies = table.Table(@This());
pub const register = proxies.register;
pub const push = proxies.push;

/// A missile's fields, as scripts name them.
pub const Field = enum { name, limit };

/// The type of `field`'s value as scripts read it, which the definitions and the reference show.
pub fn TypeOf(comptime field: Field) type {
    return switch (field) {
        .name => []const u8,
        .limit => u16,
    };
}

/// What the reference says of `field`.
pub fn about(field: Field) []const u8 {
    return switch (field) {
        .name => "Its name, such as `jack_hammer`. It can't be changed.",
        .limit => "How many of it a ship can carry. The game allows 3 Jack Hammers and 999 of each other missile. A mod's missile uses the limit of the missile it's based on.",
    };
}

/// Pushes the value of `field` of the missile `item`.
pub fn getField(state: *State, item: table.Item, field: Field) void {
    switch (field) {
        .name => values.push(state, []const u8, @tagName(@as(tables.Missile, @fromBackingInt(@intCast(item.place))))),
        .limit => values.push(state, u16, item.records.loadout_missiles[item.place]),
    }
}

/// Sets `field` of the missile `item` from the value at `given`.
pub fn setField(state: *State, item: table.Item, field: Field, given: i32) void {
    switch (field) {
        .name => state.raise(script_name ++ ".name: a missile's name comes from the game, and can't be changed", .{}),
        .limit => item.records.loadout_missiles[item.place] = values.read(state, u16, given, script_name ++ ".limit"),
    }
}

test "the loadout's missiles" {
    const bind = @import("../bind.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var held: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    records.register(state);
    records.push(state, &held, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\local missiles = records.loadout_missiles
        \\assert(#missiles == 10 and tostring(missiles[0]) == "LoadoutMissile")
        \\assert(missiles[0].name == "screamer" and missiles[9].name == "fuel_pod")
        \\assert(missiles.jack_hammer.limit == 3 and missiles.havoc.limit == 999 and missiles.nothing == nil)
        \\missiles.jack_hammer.limit = 999
        \\missiles.havoc = { limit = 4 }
    );
    try std.testing.expectEqual(999, held.loadout_missiles[@backingInt(tables.Missile.jack_hammer)]);
    try std.testing.expectEqual(4, held.loadout_missiles[@backingInt(tables.Missile.havoc)]);
    try bind.testing.expectSourceError(thread, "records.loadout_missiles.screamer.name = 'x'", "can't be changed");
    try bind.testing.expectSourceError(thread, "records.loadout_missiles[10] = {}", "records.loadout_missiles[10] does not exist: the loadout's missiles are 0 to 9");
    try bind.testing.expectSourceError(thread, "records.loadout_missiles.jack_hammer.limit = -1", "LoadoutMissile.limit");
}
