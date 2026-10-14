//! The rooms' views as scripts see them in `openreliant.records.room_views`
//! ([#1169](https://github.com/OpenReliant/openreliant/issues/1169)): the Reliant's and the
//! Yamato's, numbered 1 to 125 in the order they are stored in the executable
//! (`interface.rooms.views`). Each is a proxy for its `interface.rooms.View`. Load scripts change
//! its fields in place, as with a record, so a mod can change what the rooms play and where they
//! lead.

const std = @import("std");

const openreliant = @import("openreliant");
const game = openreliant.engine.game;
const language = game.language;
const rooms = game.interface.rooms;
const canvas = game.interface.canvas;
const movie = game.xtrabits.movie;
const luau = @import("../luau.zig");
const State = luau.State;
const values = @import("../values.zig");
const runtime = @import("../runtime.zig");
const records = @import("../records.zig");
const Records = records.Records;
const table = @import("table.zig");

/// The name scripts know a view by.
pub const script_name = "RoomView";

/// How the reference and the definitions introduce the views.
pub const each = "Each of the rooms' views";
pub const entries_about = "The rooms' views, the Reliant's and the Yamato's, numbered 1 to 125 in the order they are stored in the executable. Load scripts can change their fields.";

/// What the proxies need of the views (`table.Table`).
pub const list_name = "room_views";
pub const described = "the rooms' views";
pub const item_noun = "a view";
pub const list_tag = @backingInt(runtime.Tag.room_views);
pub const item_tag = @backingInt(runtime.Tag.room_view);

/// How many views the records hold: as many as the executable has.
pub fn count(held: *const Records) usize {
    return held.room_views.len;
}

/// The proxies of the views (`table.Table`).
const proxies = table.Table(@This());
pub const register = proxies.register;
pub const push = proxies.push;

/// A view's fields, as scripts name them: all fields of `interface.rooms.View` except its address.
pub const Field = enum { movie, loop, label, exits, action, hotspot, sound };

comptime {
    // Scripts see every field of a view except its address, under the same name.
    for (@typeInfo(rooms.View).@"struct".field_names) |name| {
        if (!std.mem.eql(u8, name, "address") and !@hasField(Field, name)) @compileError("records.room_views doesn't show a view's " ++ name);
    }
    for (std.enums.values(Field)) |field| {
        if (!@hasField(rooms.View, @tagName(field))) @compileError("rooms.View has no field " ++ @tagName(field));
    }
}

/// A view's exits as scripts read them: the numbers of the views they lead to.
const Exits = values.List(u32, rooms.View.max_exits);

/// The type of `field`'s value as scripts read it, which the definitions and the reference show.
pub fn TypeOf(comptime field: Field) type {
    return switch (field) {
        .exits => Exits,
        else => table.ScriptType(@FieldType(rooms.View, @tagName(field)), 0),
    };
}

/// What the reference says of `field`.
pub fn about(field: Field) []const u8 {
    return switch (field) {
        .movie => std.fmt.comptimePrint("The movie that plays on the way into the view: a Bink file from the disc's archive or from a mod, such as `rel_l2cd.bik`, at most {d} characters; nil for none.", .{movie.max_name}),
        .loop => "The movie that loops while the player is in the view, given like `movie`; nil for none, which leaves the last frame of the way in on the screen.",
        .label => "The text that names the way into the view. It shows at the bottom of the screen while the pointer is over the view's hotspot.",
        .exits => std.fmt.comptimePrint("The numbers of the views this view leads to, at most {d}.", .{rooms.View.max_exits}),
        .action => "What happens once the player is in the view, such as `cd_player`, which opens the CD player.",
        .hotspot => "The area of the game's 640 by 480 screen where the pointer selects the way into this view, in each view that has it as an exit.",
        .sound => "The number of the sound from the rooms' `vrsnd.fat` that plays on the way into the view; nil for none.",
    };
}

/// The view `item`.
fn viewOf(item: table.Item) *rooms.View {
    return &item.records.room_views[item.place];
}

/// Pushes the value of `field` of the view `item`.
pub fn getField(state: *State, item: table.Item, field: Field) void {
    const view = viewOf(item);
    switch (field) {
        .movie => values.push(state, ?[]const u8, view.movie),
        .loop => values.push(state, ?[]const u8, view.loop),
        // The labels are in the game's text, while `table.pushValue` reads the ITAC's.
        .label => table.pushWords(state, item.records, view.label, .text),
        .exits => {
            var exits: Exits = .{};
            for (view.exits) |exit| exits.append(@as(u32, exit) + 1);
            values.push(state, Exits, exits);
        },
        .action => values.push(state, rooms.Action, view.action),
        .hotspot => values.push(state, canvas.Rect, view.hotspot),
        .sound => values.push(state, ?u8, view.sound),
    }
}

/// Sets `field` of the view `item` from the value at `given`.
pub fn setField(state: *State, item: table.Item, field: Field, given: i32) void {
    const view = viewOf(item);
    switch (field) {
        inline .movie, .loop => |name| {
            const label = script_name ++ "." ++ @tagName(name);
            const read = values.read(state, ?[]const u8, given, label);
            if (read) |file| if (file.len > movie.max_name) state.raise(label ++ ": expected at most {d} characters, got {d}", .{ movie.max_name, file.len });
            @field(view, @tagName(name)) = table.kept(?[]const u8, state, item.records, read, label);
        },
        .label => {
            const label = script_name ++ ".label";
            view.label = table.kept(language.Words, state, item.records, values.read(state, []const u8, given, label), label);
        },
        .exits => {
            const label = script_name ++ ".exits";
            const read = values.read(state, Exits, given, label);
            const total = count(item.records);
            const exits = item.records.arena.alloc(u8, read.len) catch state.raise(label ++ ": out of memory", .{});
            for (exits, read.slice()) |*exit, number| {
                if (number < 1 or number > total) state.raise(label ++ ": no view {d}: the views are 1 to {d}", .{ number, total });
                exit.* = @intCast(number - 1);
            }
            view.exits = exits;
        },
        .action => view.action = values.read(state, rooms.Action, given, script_name ++ ".action"),
        .hotspot => view.hotspot = values.read(state, canvas.Rect, given, script_name ++ ".hotspot"),
        .sound => view.sound = values.read(state, ?u8, given, script_name ++ ".sound"),
    }
}

test "the rooms' views" {
    const bind = @import("../bind.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var held: Records = try .init(arena.allocator(), .{ .ships = &.{}, .ship_types = &.{}, .guns = &.{}, .missiles = &.{}, .pilots = &.{}, .faces = &.{}, .text = &.{}, .itac_text = &.{} });
    held.text = try arena.allocator().alloc([]const u8, 0x600);
    @memset(held.text, "");
    held.text[0xDB - 1] = "Walk to Bunk";
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    records.register(state);
    records.push(state, &held, true);
    state.setGlobal("records");
    state.sandbox();
    const thread = state.newSandboxedThread();

    try bind.testing.runSource(thread,
        \\local views = records.room_views
        \\assert(#views == 125 and tostring(views[1]) == "RoomView")
        \\-- The Reliant's rooms start by the ladder to the bunk, with exits to views 3, 4 and 2.
        \\local start = views[1]
        \\assert(start.movie == "rel_ladd_bunk.bik" and start.loop == "rel_doorloop.bik")
        \\assert(start.label == "Walk to Bunk" and start.action == "none" and start.sound == nil)
        \\assert(#start.exits == 3 and start.exits[1] == 3 and start.exits[3] == 2)
        \\assert(views[2].action == "briefing" and views[2].hotspot.width == 296)
        \\-- A mod renames the way into the briefing room, and sends its door to the bunk's view.
        \\views[2].label = "Report for Duty"
        \\views[2].exits = { 1 }
        \\views[2].loop = nil
        \\assert(views[2].label == "Report for Duty" and views[2].exits[1] == 1 and views[2].loop == nil)
    );
    const door = held.room_views[1];
    try std.testing.expectEqualStrings("Report for Duty", door.label.text);
    try std.testing.expectEqualSlices(u8, &.{0}, door.exits);
    try std.testing.expectEqual(null, door.loop);
    try bind.testing.expectSourceError(thread, "records.room_views[126] = {}", "records.room_views[126] does not exist: the rooms' views are 1 to 125");
    try bind.testing.expectSourceError(thread, "records.room_views[1].exits = { 126 }", "RoomView.exits: no view 126: the views are 1 to 125");
    try bind.testing.expectSourceError(thread, "records.room_views[1].exits = { 1, 2, 3, 4, 5 }", "RoomView.exits");
    try bind.testing.expectSourceError(thread, "records.room_views[1].movie = string.rep('x', 65)", "RoomView.movie: expected at most 64 characters, got 65");
}
