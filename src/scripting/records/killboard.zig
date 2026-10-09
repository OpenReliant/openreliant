//! The ITAC's KILLBOARD as scripts see it in `openreliant.records.killboard`
//! ([#1008](https://github.com/OpenReliant/openreliant/issues/1008)): its pilots, numbered from 1,
//! each a proxy for its `itac.killboard.Pilot` whose fields load scripts change in place, as they do
//! a record's. A mod that restores or moves missions keeps the board in step with its campaign, and
//! a campaign of its own gives the board's places pilots of its own.

const std = @import("std");

const openreliant = @import("openreliant");
const game = openreliant.engine.game;
const killboard = game.itac.killboard;
const luau = @import("../luau.zig");
const State = luau.State;
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const Records = records.Records;
const table = @import("table.zig");

/// The name scripts know a pilot of the board by.
pub const script_name = "KillboardPilot";

/// How the reference and the definitions introduce the pilots.
pub const each = "Each of the KILLBOARD's pilots";
pub const entries_about = "The KILLBOARD's pilots, numbered from 1. Load scripts change their fields.";

/// What the proxies need of the board's pilots (`table.Table`).
pub const list_name = "killboard";
pub const described = "the KILLBOARD's pilots";
pub const item_noun = "a pilot";
pub const list_tag = @backingInt(runtime.Tag.killboard);
pub const item_tag = @backingInt(runtime.Tag.killboard_pilot);

/// How many pilots the records hold.
pub fn count(held: *const Records) usize {
    return held.killboard.len;
}

/// The proxies of the board's pilots (`table.Table`).
const proxies = table.Table(@This());
pub const register = proxies.register;
pub const push = proxies.push;

/// The most missions a script gives a pilot to sit out.
const most_missions = 32;

/// A pilot's fields, as scripts name them: those of `itac.killboard.Pilot`.
pub const Field = std.meta.FieldEnum(killboard.Pilot);

/// The type of `field`'s value as scripts read it, which the definitions and the reference show.
pub fn TypeOf(comptime field: Field) type {
    return table.ScriptType(@FieldType(killboard.Pilot, @tagName(field)), most_missions);
}

/// What the reference says of `field`.
pub fn about(field: Field) []const u8 {
    return switch (field) {
        .name => "The pilot's name.",
        .squadron => "The line below the name: the pilot's squadron, in brackets.",
        .ship => "The pilot's ship; nil leaves the column empty.",
        .kills => "The kills the pilot starts a campaign with.",
        .mean => "The kills each mission adds on average.",
        .spread => "How far a mission's kills can stray from the mean: half the spread each way.",
        .portrait => "The shape of the pilot's portrait in `inter\\itac\\kills.spr`.",
        .in_45th => "Whether the pilot flies in the 45th: the portrait takes the 45th's palette, and the squadron shows as the 45th Flying Tigers in the missions whose `flying_tigers` rule is on.",
        .joins_at => "The first mission the pilot is on the board in, as Linc Stevenson joins at mission 6; nil for every mission.",
        .leaves_after => "The last mission the pilot is on the board in, as John McGann leaves after mission 5; nil for every mission.",
        .sits_out => "The missions in which the pilot adds no kills, as Klaus Steiner sits out missions 19 to 23.",
    };
}

/// The pilot `item`.
fn pilotOf(item: table.Item) *killboard.Pilot {
    return &item.records.killboard[item.place];
}

/// Pushes the value of `field` of the pilot `item`.
pub fn getField(state: *State, item: table.Item, field: Field) void {
    switch (field) {
        inline else => |name| {
            const Kept = @FieldType(killboard.Pilot, @tagName(name));
            table.pushValue(state, item.records, Kept, @field(pilotOf(item), @tagName(name)));
        },
    }
}

/// Sets `field` of the pilot `item` from the value at `given`.
pub fn setField(state: *State, item: table.Item, field: Field, given: i32) void {
    switch (field) {
        inline else => |name| {
            const label = script_name ++ "." ++ @tagName(name);
            const Kept = @FieldType(killboard.Pilot, @tagName(name));
            const read = values.read(state, TypeOf(name), given, label);
            @field(pilotOf(item), @tagName(name)) = table.kept(Kept, state, item.records, read, label);
        },
    }
}

/// Records for the tests: the original board, and the ITAC's text with the names the tests read.
fn testRecords(arena: std.mem.Allocator) !Records {
    var held: Records = try .init(arena, .{ .ships = &.{}, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    held.itac_text = try arena.alloc([]const u8, 1800);
    @memset(held.itac_text, "");
    held.itac_text[0x518 - 1] = "John McGann";
    return held;
}

test "the KILLBOARD's pilots" {
    const bind = @import("../bind.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var held = try testRecords(arena.allocator());
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    records.register(state);
    records.push(state, &held, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\local board = records.killboard
        \\assert(#board == 19 and tostring(board[1]) == "KillboardPilot")
        \\-- The original's pilots.
        \\local mcgann
        \\for _, pilot in board do
        \\    if pilot.name == "John McGann" then mcgann = pilot end
        \\end
        \\assert(mcgann.leaves_after == 5 and mcgann.joins_at == nil and #mcgann.sits_out == 0)
        \\-- A restoration keeps him on the board, and a pilot of its own sits out two missions.
        \\mcgann.leaves_after = nil
        \\board[19] = { name = "Trent Ramsey", squadron = "(45th Volunteers)", in_45th = true, sits_out = { 12, 13 } }
        \\-- A table leaves out a field set to nil, so that takes an assignment of its own.
        \\board[19].ship = nil
        \\assert(board[19].name == "Trent Ramsey" and board[19].ship == nil)
    );
    try std.testing.expectEqualStrings("Trent Ramsey", held.killboard[18].name.text);
    try std.testing.expectEqualSlices(u16, &.{ 12, 13 }, held.killboard[18].sits_out);
    try std.testing.expect(held.killboard[18].in_45th);
    try bind.testing.expectSourceError(thread, "records.killboard[20] = {}", "records.killboard[20] does not exist: the KILLBOARD's pilots are 1 to 19");
    try bind.testing.expectSourceError(thread, "records.killboard[1].kills = 'many'", "KillboardPilot.kills");
    try bind.testing.expectSourceError(thread, "records.killboard[1].rank = 3", "KillboardPilot has no field 'rank'");
}
