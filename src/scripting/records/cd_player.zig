//! The CD player's tracks as scripts see them in `openreliant.records.cd_player`
//! ([#1167](https://github.com/OpenReliant/openreliant/issues/1167)): the Reliant's twelve, Spirit of
//! War to The Catalyst, numbered 1 to 12, then the Yamato's, Final Word to The Rise, numbered 13 to
//! 24. Each is a proxy for its `interface.cd_player.Track`, whose fields load scripts change in
//! place, as they do a record's, so that a mod's music can have a row of the player.

const std = @import("std");

const openreliant = @import("openreliant");
const game = openreliant.engine.game;
const cd_player = game.interface.cd_player;
const Carrier = game.interface.rooms.Carrier;
const luau = @import("../luau.zig");
const State = luau.State;
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const Records = records.Records;
const table = @import("table.zig");

/// The name scripts know a track by.
pub const script_name = "CdPlayerTrack";

/// How the reference and the definitions introduce the tracks.
pub const each = "Each of the CD player's tracks";
pub const entries_about = "The CD player's tracks: the Reliant's, 1 to 12, then the Yamato's, 13 to 24. Load scripts change their fields.";

/// What the proxies need of the tracks (`table.Table`).
pub const list_name = "cd_player";
pub const described = "the CD player's tracks";
pub const item_noun = "a track";
pub const list_tag = @backingInt(runtime.Tag.cd_player);
pub const item_tag = @backingInt(runtime.Tag.cd_player_track);

/// How many tracks the records hold: each carrier's list, the Reliant's first.
pub fn count(held: *const Records) usize {
    _ = held;
    return std.enums.values(Carrier).len * cd_player.track_count;
}

/// The proxies of the tracks (`table.Table`).
const proxies = table.Table(@This());
pub const register = proxies.register;
pub const push = proxies.push;

/// A track's fields, as scripts name them: those of `interface.cd_player.Track`.
pub const Field = std.meta.FieldEnum(cd_player.Track);

/// The type of `field`'s value as scripts read it, which the definitions and the reference show.
pub fn TypeOf(comptime field: Field) type {
    return table.ScriptType(@FieldType(cd_player.Track, @tagName(field)), 0);
}

/// What the reference says of `field`.
pub fn about(field: Field) []const u8 {
    return switch (field) {
        .piece => "The music the track plays: the name of its file in the `music` folder, without the `.wav`, such as `New_Mission01`. A mod's own piece plays as the game's do.",
        .name => "The track's name in the list.",
    };
}

/// The track `item`: the Reliant's list, then the Yamato's.
fn trackOf(item: table.Item) *cd_player.Track {
    const carrier = std.enums.values(Carrier)[item.place / cd_player.track_count];
    return &item.records.cd_player.getPtr(carrier)[item.place % cd_player.track_count];
}

/// Pushes the value of `field` of the track `item`.
pub fn getField(state: *State, item: table.Item, field: Field) void {
    const track = trackOf(item);
    switch (field) {
        .piece => values.push(state, []const u8, track.piece),
        // The names are the game's text, not the ITAC's, which `table.pushValue` reads.
        .name => records.pushText(state, track.name.in(item.records.language(.text))),
    }
}

/// Sets `field` of the track `item` from the value at `given`.
pub fn setField(state: *State, item: table.Item, field: Field, given: i32) void {
    switch (field) {
        inline else => |name| {
            const label = script_name ++ "." ++ @tagName(name);
            const Kept = @FieldType(cd_player.Track, @tagName(name));
            const read = values.read(state, TypeOf(name), given, label);
            if (name == .piece and read.len > cd_player.longest_piece) state.raise(label ++ ": expected at most {d} characters, got {d}", .{ cd_player.longest_piece, read.len });
            @field(trackOf(item), @tagName(name)) = table.kept(Kept, state, item.records, read, label);
        },
    }
}

test "the CD player's tracks" {
    const bind = @import("../bind.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var held: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    held.text = try arena.allocator().alloc([]const u8, 0x600);
    @memset(held.text, "");
    held.text[0x319 - 1] = "Spirit of War";
    held.text[0x53C - 1] = "The Rise";
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    records.register(state);
    records.push(state, &held, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\local tracks = records.cd_player
        \\assert(#tracks == 24 and tostring(tracks[1]) == "CdPlayerTrack")
        \\-- The original's lists: The Rise, the Yamato's last, plays Spirit of War's piece.
        \\assert(tracks[1].name == "Spirit of War" and tracks[1].piece == "new_mission01")
        \\assert(tracks[24].name == "The Rise" and tracks[24].piece == "new_mission01")
        \\-- A mod puts its own piece there, with a name of its own.
        \\tracks[24] = { piece = "New_Pensive", name = "OpenReliant Theme" }
        \\assert(tracks[24].piece == "New_Pensive" and tracks[24].name == "OpenReliant Theme")
    );
    const rise = held.cd_player.get(.yamato)[11];
    try std.testing.expectEqualStrings("New_Pensive", rise.piece);
    try std.testing.expectEqualStrings("OpenReliant Theme", rise.name.text);
    try std.testing.expectEqualStrings("new_mission01", held.cd_player.get(.reliant)[0].piece);
    try bind.testing.expectSourceError(thread, "records.cd_player[25] = {}", "records.cd_player[25] does not exist: the CD player's tracks are 1 to 24");
    try bind.testing.expectSourceError(thread, "records.cd_player[1].piece = 3", "CdPlayerTrack.piece");
    try bind.testing.expectSourceError(thread, "records.cd_player[1].piece = string.rep('x', 251)", "CdPlayerTrack.piece: expected at most 250 characters, got 251");
    try bind.testing.expectSourceError(thread, "records.cd_player[1].length = 3", "CdPlayerTrack has no field 'length'");
}
