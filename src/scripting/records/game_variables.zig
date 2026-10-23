//! The game's variables as scripts see them in `openreliant.records.game_variables`
//! ([#1322](https://github.com/OpenReliant/openreliant/issues/1322)): one for each number a mission's
//! script names, from 0, each a proxy for its `gameflow.VariableRecord`, whose fields load scripts
//! change in place, as they do a record's. Scripts also find a variable by its name: the game's,
//! such as `krasnaya_alive`, or the qualified name of one a mod adds. The campaign goes by them:
//! the value a new campaign gives each variable, the value each attempt at a mission starts it at,
//! and whether a saved game keeps it.

const std = @import("std");

const openreliant = @import("openreliant");
const gameflow = openreliant.engine.game.gameflow;
const vm = openreliant.engine.vm;
const luau = @import("../luau.zig");
const State = luau.State;
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const Records = records.Records;
const table = @import("table.zig");

/// The name scripts know a game variable's record by.
pub const script_name = "GameVariableRecord";

/// How the reference and the definitions introduce the variables.
pub const each = "Each of the game's variables";
pub const entries_about = "What the campaign does with each of the game's variables, by its number from 0 or by its name. Load scripts change their fields.";

/// What the proxies need of the variables (`table.Table`).
pub const list_name = "game_variables";
pub const described = "the game's variables";
pub const item_noun = "a game variable";
pub const list_tag = @backingInt(runtime.Tag.game_variables);
pub const item_tag = @backingInt(runtime.Tag.game_variable);
/// The number of the first variable, as the scripts number them.
pub const first = 0;

/// How many variables the records hold: one for each number.
pub fn count(held: *const Records) usize {
    return held.game_variables.len;
}

/// The variable a script names `text`: one of the game's by its name, or one a mod adds by its
/// qualified name, or by its own name in that mod's scripts.
pub fn placeNamed(state: *State, _: *const Records, text: []const u8) ?usize {
    return @backingInt(values.lookUp(state, vm.Variable, text) orelse return null);
}

/// The proxies of the variables (`table.Table`).
const proxies = table.Table(@This());
pub const register = proxies.register;
pub const push = proxies.push;

/// A variable's fields, as scripts name them: its name, then those of `gameflow.VariableRecord`.
pub const Field = enum { name, start, attempt, saved };

comptime {
    for (@typeInfo(gameflow.VariableRecord).@"struct".field_names, 1..) |name, at| {
        std.debug.assert(std.mem.eql(u8, name, @tagName(@as(Field, @fromBackingInt(at)))));
    }
}

/// The type of `field`'s value as scripts read it, which the definitions and the reference show.
pub fn TypeOf(comptime field: Field) type {
    return switch (field) {
        .name => ?[]const u8,
        else => @FieldType(gameflow.VariableRecord, @tagName(field)),
    };
}

/// What the reference says of `field`.
pub fn about(field: Field) []const u8 {
    return switch (field) {
        .name => "Its name: the game's, such as `krasnaya_alive`, or the qualified name of one a mod adds; nil for a number without one. It can't be changed.",
        .start => "The value a new campaign gives it; nil leaves it as it was. The game's own clear the first 32 variables and set the campaign's flags, such as `ghost_alive`, to 1.",
        .attempt => "The value each attempt at a mission starts it at; nil where the campaign keeps it from one mission to the next, as it keeps the campaign's flags.",
        .saved => "Whether a saved game keeps it.",
    };
}

/// Pushes the value of `field` of the variable `item`.
pub fn getField(state: *State, item: table.Item, field: Field) void {
    switch (field) {
        .name => values.push(state, ?[]const u8, @as(vm.Variable, @fromBackingInt(@intCast(item.place))).scriptName()),
        inline else => |name| values.push(state, TypeOf(name), @field(item.records.game_variables[item.place], @tagName(name))),
    }
}

/// Sets `field` of the variable `item` from the value at `given`.
pub fn setField(state: *State, item: table.Item, field: Field, given: i32) void {
    switch (field) {
        .name => state.raise(script_name ++ ".name: a variable's name comes from the game or its mod's manifest, and can't be changed", .{}),
        inline else => |name| {
            const label = script_name ++ "." ++ @tagName(name);
            @field(item.records.game_variables[item.place], @tagName(name)) = values.read(state, TypeOf(name), given, label);
        },
    }
}

test "the game's variables" {
    const bind = @import("../bind.zig");
    const additions = openreliant.engine.game.additions;
    var added = [_]additions.variables.Added{.{ .name = "a:beaten", .mod = "a", .base = {}, .based = false, .extra = .{ .start = 4, .saved = true } }};
    additions.variables.install(&added);
    defer additions.variables.reset();
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
        \\local variables = records.game_variables
        \\assert(#variables == 256 and tostring(variables[0]) == "GameVariableRecord")
        \\-- The original's: a flag of the campaign, a variable of each attempt, and one past them.
        \\local krasnaya = variables.krasnaya_alive
        \\assert(krasnaya.name == "krasnaya_alive" and krasnaya.start == 1 and krasnaya.attempt == nil and krasnaya.saved)
        \\assert(variables[28].name == "objectives_met" and variables[28].attempt == 0 and not variables[28].saved)
        \\assert(variables.countdown.start == nil and variables[40].name == nil and variables.nothing == nil)
        \\-- A mod's, by its qualified name or its number.
        \\assert(variables["a:beaten"].start == 4 and variables[64].name == "a:beaten")
        \\-- A replacement campaign starts without the Krasnaya, and starts the countdown each attempt.
        \\krasnaya.start = 0
        \\variables.countdown = { attempt = 60, saved = true }
    );
    const krasnaya_alive = @backingInt(vm.GameVariable.krasnaya_alive);
    try std.testing.expectEqual(0, held.game_variables[krasnaya_alive].start.?);
    try std.testing.expectEqual(gameflow.VariableRecord{ .attempt = 60, .saved = true }, held.game_variables[@backingInt(vm.GameVariable.countdown)]);
    try bind.testing.expectSourceError(thread, "records.game_variables[0].name = 'ready'", "can't be changed");
    try bind.testing.expectSourceError(thread, "records.game_variables[256] = {}", "records.game_variables[256] does not exist: the game's variables are 0 to 255");
    try bind.testing.expectSourceError(thread, "records.game_variables.ghost_alive.attempt = 'never'", "GameVariableRecord.attempt");
}
