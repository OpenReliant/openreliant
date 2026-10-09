//! The combat maneuvers as scripts see them in `openreliant.records.maneuvers`
//! ([#1024](https://github.com/OpenReliant/openreliant/issues/1024)): proxies for the maneuvers the
//! Fight order flies (`aidefend.Compiled`), numbered as the game numbers them, from 0. Load
//! scripts change their fields, and add maneuvers after the original's, which a handler of the
//! `fight_choose_maneuver` hook can then choose. A script is compiled as it's set.

const std = @import("std");

const openreliant = @import("openreliant");
const aidefend = openreliant.engine.game.aidefend;
const luau = @import("../luau.zig");
const State = luau.State;
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const Records = records.Records;
const table = @import("table.zig");

/// The name scripts know a maneuver by.
pub const script_name = "CombatManeuver";

/// How the reference and the definitions introduce the maneuvers.
pub const each = "Each of the combat maneuvers";
pub const entries_about = "The combat maneuvers the Fight order flies, numbered from 0 as the game numbers them. Load scripts change their fields and add new ones after the last.";

/// What the proxies need of the maneuvers (`table.Table`).
pub const list_name = "maneuvers";
pub const described = "the combat maneuvers";
pub const item_noun = "a maneuver";
pub const list_tag = @backingInt(runtime.Tag.maneuvers);
pub const item_tag = @backingInt(runtime.Tag.maneuver);
pub const first = 0;
pub const most = aidefend.most_maneuvers;

/// How many maneuvers the records hold.
pub fn count(held: *const Records) usize {
    return held.maneuvers.len;
}

/// Adds a maneuver after the last, named after its number, with an empty script.
pub fn append(state: *State, held: *Records) void {
    const out_of_memory = "records." ++ list_name ++ ": out of memory";
    const grown = held.arena.alloc(aidefend.Compiled, held.maneuvers.len + 1) catch state.raise(out_of_memory, .{});
    @memcpy(grown[0..held.maneuvers.len], held.maneuvers);
    const name = std.fmt.allocPrint(held.arena, "maneuver {d}", .{held.maneuvers.len}) catch state.raise(out_of_memory, .{});
    grown[held.maneuvers.len] = .{ .definition = .{ .name = name } };
    held.maneuvers = grown;
}

/// The proxies of the maneuvers (`table.Table`).
const proxies = table.Table(@This());
pub const register = proxies.register;
pub const push = proxies.push;

/// A maneuver's fields, as scripts name them: those of `aidefend.Definition`.
pub const Field = std.meta.FieldEnum(aidefend.Definition);

/// The type of `field`'s value as scripts read it, which the definitions and the reference show.
pub fn TypeOf(comptime field: Field) type {
    return table.ScriptType(@FieldType(aidefend.Definition, @tagName(field)), aidefend.most_script_lines);
}

/// What the reference says of `field`.
pub fn about(field: Field) []const u8 {
    return switch (field) {
        .name => "Its name, such as \"loop the loop\".",
        .mirror => "The inputs it may mirror: each time it starts, a random choice among them.",
        .min_ticks => "The fewest ticks it runs, unless the Fight order gives a length of its own.",
        .max_ticks => "The most ticks it runs: Fight draws its length from `min_ticks` up to this.",
        .script => "Its script: a command of the maneuvers' language on each line. Setting it compiles it, and a line that doesn't compile is an error.",
    };
}

/// The maneuver `item`.
fn maneuverOf(item: table.Item) *aidefend.Compiled {
    return &item.records.maneuvers[item.place];
}

/// Pushes the value of `field` of the maneuver `item`.
pub fn getField(state: *State, item: table.Item, field: Field) void {
    switch (field) {
        inline else => |name| {
            const Kept = @FieldType(aidefend.Definition, @tagName(name));
            table.pushValue(state, item.records, Kept, @field(maneuverOf(item).definition, @tagName(name)));
        },
    }
}

/// Sets `field` of the maneuver `item` from the value at `given`. A script is compiled as it's set,
/// and refused, with the line, if a line doesn't compile.
pub fn setField(state: *State, item: table.Item, field: Field, given: i32) void {
    const maneuver = maneuverOf(item);
    switch (field) {
        inline else => |name| {
            const label = script_name ++ "." ++ @tagName(name);
            const Kept = @FieldType(aidefend.Definition, @tagName(name));
            const read = values.read(state, TypeOf(name), given, label);
            const kept = table.kept(Kept, state, item.records, read, label);
            if (name == .script) maneuver.program = compile(state, item.records, kept, label);
            @field(maneuver.definition, @tagName(name)) = kept;
        },
    }
}

/// `lines` compiled into the records' arena. Raises an error naming the first line that doesn't
/// compile.
fn compile(state: *State, held: *Records, lines: []const []const u8, comptime label: []const u8) []const aidefend.script.Instruction {
    const program = held.arena.alloc(aidefend.script.Instruction, lines.len) catch state.raise(label ++ ": out of memory", .{});
    const failure = aidefend.script.compileInto(lines, program) orelse return program;
    state.raise(label ++ ": line {d}, \"{s}\", doesn't compile: {s}", .{ failure.line + 1, lines[failure.line], aidefend.script.describe(failure.err) });
}

test "the combat maneuvers" {
    const bind = @import("../bind.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // The original's maneuvers, and no other records.
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
        \\local all = records.maneuvers
        \\assert(#all == 10 and tostring(all[0]) == "CombatManeuver")
        \\assert(all[8].name == "loop the loop" and all[0].mirror.yaw and all[9].script[2] == "RunToShip()")
        \\-- A shorter loop the loop, and a maneuver of a mod's own after the original's.
        \\all[8].max_ticks = 2000
        \\all[#all] = { name = "barrel roll", mirror = { roll = true }, min_ticks = 1500, max_ticks = 3000,
        \\    script = { "Cloak(off)", "SetSpeed(1)", "SetPitch(0.2)", "loop:", "SetRoll(1)", "Wait(500)", "Goto loop" } }
        \\assert(#all == 11 and all[10].name == "barrel roll")
        \\for number, maneuver in all do
        \\    assert(number < 11 and maneuver.min_ticks <= maneuver.max_ticks)
        \\end
    );
    try std.testing.expectEqual(2000, held.maneuvers[8].definition.max_ticks);
    const added = held.maneuvers[10];
    try std.testing.expectEqualStrings("barrel roll", added.definition.name);
    try std.testing.expect(added.definition.mirror.roll);
    // Its script is compiled: the jump goes back to the label, the fourth line.
    try std.testing.expectEqual(7, added.program.len);
    try std.testing.expectEqual(aidefend.script.Instruction{ .goto = 3 }, added.program[6]);
    try bind.testing.expectSourceError(thread, "records.maneuvers[0].script = { 'Jink(2000, 4000)' }", "CombatManeuver.script: line 1, \"Jink(2000, 4000)\", doesn't compile: the language has no such command");
    try bind.testing.expectSourceError(thread, "records.maneuvers[20] = {}", "records.maneuvers[20] does not exist: the combat maneuvers are 0 to 10; assign to records.maneuvers[11] to add one, up to 255 in all");
    try bind.testing.expectSourceError(thread, "records.maneuvers[0].speed = 3", "CombatManeuver has no field 'speed'");
    try bind.testing.expectSourceError(thread, "records.maneuvers[0].script = table.create(256, \"Wait(1)\")", "CombatManeuver.script: at most 255 values");
}
