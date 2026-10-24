//! The reference of mission source, `docs/guide/mission-reference.md`: its declarations and their
//! fields, the functions and values of its script, the game's commands and conditions, and the
//! names of the game's values, from the same declarations and tables as its definitions file
//! (`definitions.zig`). `sltool dte reference` writes it, and tests check the copy in
//! `docs/guide`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const dte = @import("../../dte.zig");
const layout = @import("../../layout.zig");
const commands = @import("../../../engine/game/executor/commands.zig");
const conditions = @import("../../../engine/vm/conditions.zig");
const vm = @import("../../../engine/vm.zig");
const language = @import("language.zig");
const names = @import("names.zig");
const script = @import("script.zig");
const vocabulary = @import("vocabulary.zig");

pub const Error = Allocator.Error || Writer.Error;

/// Writes the reference page, with `arena` for the names it makes.
pub fn write(arena: Allocator, w: *Writer) Error!void {
    try w.writeAll(
        \\# Mission source reference
        \\
        \\This page lists everything mission source holds: its declarations and their fields, the
        \\functions and values of its script, the game's commands and conditions, and the names of the
        \\game's values. [Mission source](../formats/mission-source.md) explains the syntax, and editors
        \\complete and describe the same names from [`mission.d.luau`](mission.d.luau).
        \\`sltool dte reference` writes this page from the game's tables.
        \\
        \\## Declarations
        \\
        \\The file's top level holds declarations: `name = constructor(...)` declares a record under
        \\`name`, `on(...)` a trigger, and `mission(...)` gives the mission's own details.
        \\
    );
    try writeWords(w, .declaration);
    try w.writeAll(
        \\
        \\## Tables of fields
        \\
        \\A declaration's fields go in a table, `{ name = value }`. A field whose type ends in `?` can
        \\be left out.
        \\
    );
    for (language.tables) |table| try writeTable(w, table);
    try w.writeAll(
        \\
        \\## The script's functions and values
        \\
        \\The code of parts and triggers uses these besides the commands, its parameters, the file's
        \\names and Luau's operators.
        \\
    );
    try writeWords(w, .script);
    try w.writeAll(
        \\
        \\## References past the records
        \\
        \\A reference to a record that the mission doesn't have, such as a curve's ship in some of the
        \\leftover missions, is written by its index.
        \\
    );
    try writeWords(w, .index);
    try writeTypes(w);
    try w.writeAll(
        \\
        \\## Commands
        \\
        \\The game's commands, from its catalogue. Their names, their parameters' labels and their
        \\descriptions are the developers' own, and the parameters' names are made from the labels. A
        \\command the catalogue doesn't have runs as `command(number, ...)`.
        \\
    );
    for (commands.table, 0..) |command, number| try writeCommand(arena, w, command, number);
    try w.writeAll(
        \\
        \\## Conditions
        \\
        \\What a trigger watches for, by the names mission source gives the conditions of the game's
        \\catalogue; the catalogue's own names are the developers'. A trigger's function gets the values
        \\its condition's events carry as its parameters, named after their labels, and a trigger checks
        \\a value it can check by the field of the same name ([TriggerFields](#triggerfields)).
        \\
    );
    for (conditions.table, 0..) |condition, number| try writeCondition(arena, w, condition, number);
    try writeNames(w);
}

/// Writes the words of `group`, each with its declaration and what it is or does.
fn writeWords(w: *Writer, group: language.Group) Writer.Error!void {
    for (std.enums.values(names.Word)) |word| {
        if (language.groupOf(word) != group) continue;
        try w.print("\n### `{t}`\n\n```luau\n{f}\n```\n\n{s}\n", .{ word, language.Signature{ .word = word }, language.declaration(word).about });
    }
}

/// Writes `table` and its fields.
fn writeTable(w: *Writer, table: language.Table) Writer.Error!void {
    try w.print("\n### {s}\n\n| Field | Type | What it is |\n|---|---|---|\n", .{table.name});
    for (table.fields) |field| try w.print("| `{s}` | `{f}` | {s} |\n", .{ field.name, cell(field.type), field.about });
    if (table.events) try w.print("| A value's name | `{f}` or `{f}` | For each value of the condition's events that a trigger can check, what it must be for the trigger to fire ([Conditions](#conditions)). |\n", .{
        cell(language.checkType(.{ .ship = true })), cell(language.checkType(.{ .number = true })),
    });
}

/// Writes the types the declarations, the functions and the commands take and give, besides the
/// tables and the names of values.
fn writeTypes(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\
        \\## Types
        \\
        \\The types the declarations, the functions and the commands take and give, besides the tables
        \\of fields and the names of values.
        \\
        \\| Type | Is | What it is |
        \\|---|---|---|
        \\
    );
    for (language.types) |declared| {
        try w.print("| `{s}` | ", .{declared.name});
        switch (declared.definition) {
            .own => |body| if (body.len == 0)
                try w.writeAll("A type of its own")
            else
                try w.print("A type of its own, `{f}`", .{cell(body)}),
            .alias => |definition| try w.print("`{f}`", .{cell(definition)}),
        }
        try w.print(" | {s} |\n", .{declared.about});
    }
}

/// Writes `command`, the catalogue's `number`th, with its description and its parameters.
fn writeCommand(arena: Allocator, w: *Writer, command: commands.Command, number: usize) Error!void {
    try w.print("\n### {s}\n\n", .{command.name});
    if (command.description.len > 0) try w.print("{f} ", .{sentence(command.description)});
    try w.print("Command {d} of the catalogue.\n\n", .{number});
    const parameters = try language.parameters(arena, command);
    if (parameters.len == 0) return w.writeAll("Takes nothing.\n");
    try w.writeAll("| Parameter | Type | Label |\n|---|---|---|\n");
    for (parameters) |parameter| {
        try w.print("| `{s}` | `{f}` | {f} |\n", .{ parameter.name, cell(try arena.print("{f}", .{parameter.type})), cell(parameter.label) });
    }
}

/// Writes `condition`, the catalogue's `number`th: what a trigger of it can watch, and the values
/// its events carry.
fn writeCondition(arena: Allocator, w: *Writer, condition: conditions.Condition, number: usize) Error!void {
    const name = vocabulary.name(.condition, @intCast(number)) orelse try arena.print("{d}", .{number});
    try w.print("\n### `{s}`\n\nThe catalogue's `{s}`, condition {d}.", .{ name, condition.name, number });
    var subjects: std.ArrayList([]const u8) = .empty;
    inline for (.{ .{ "ship", "a ship" }, .{ "flight_group", "a flight group" }, .{ "squad", "a squad" } }) |pair| {
        if (@field(condition.subjects, pair[0])) try subjects.append(arena, pair[1]);
    }
    if (subjects.items.len > 0) try w.print(" A trigger of it watches {f}.", .{names.Listed{ .items = subjects.items, .quoted = false, .last = " or " }});
    if (condition.slot != null) try w.writeAll(" An object keeps its last event of it, which `last_event` reads.");
    try w.writeAll("\n\n");
    if (condition.values.len == 0) return w.writeAll("Its events carry no values.\n");
    try w.writeAll("| Parameter | Label | Type | A trigger checks it |\n|---|---|---|---|\n");
    const described: dte.Condition = @fromBackingInt(@intCast(number));
    for (condition.values, try script.eventNames(arena, condition.values), 0..) |value, parameter, slot| {
        const checks = switch (described.keeps(slot)) {
            .nothing => "No",
            .check => "Yes",
            .distance => "No: a trigger sets it, how far it looks, in radii of the ship it watches",
        };
        try w.print("| `{s}` | {f} | `{s}` | {s} |\n", .{ parameter, cell(value.label), language.eventValueType(value.kinds), checks });
    }
}

/// Writes the names of the game's values: those of each kind the game names, the wings and the
/// game's variables.
fn writeNames(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\
        \\## Names of values
        \\
        \\A value the game names is written by its name, in quotes. One without a name, such as a
        \\mod's ship type, is written as a number.
        \\
    );
    inline for (comptime std.enums.values(vocabulary.Kind)) |kind| {
        if (comptime vocabulary.Names(kind)) |Enum| {
            try w.print("\n### {s}\n\n", .{kind.typeName()});
            try writeList(w, @typeInfo(Enum).@"enum".field_names);
            try w.writeAll(", or a number.\n");
        }
    }
    try w.writeAll("\n### Wing\n\n");
    try writeList(w, @typeInfo(dte.FlightGroup.Wing).@"enum".field_names);
    try w.writeAll(", or a number.\n\n### GameVariables\n\nThe game's variables, which `game` holds: ");
    try writeList(w, @typeInfo(vm.GameVariable).@"enum".field_names);
    try w.writeAll(", or a number, as in `game[37]`, for one without a name.\n");
}

/// Writes the names `tags` give, but placeholders (`layout.isPlaceholder`), each in backticks.
fn writeList(w: *Writer, tags: []const [:0]const u8) Writer.Error!void {
    var first = true;
    for (tags) |tag| {
        if (layout.isPlaceholder(tag)) continue;
        try w.print("{s}`{s}`", .{ if (first) "" else ", ", tag });
        first = false;
    }
}

/// `text` in a table's cell, its `|` escaped.
fn cell(text: []const u8) Cell {
    return .{ .text = text };
}

const Cell = struct {
    text: []const u8,

    pub fn format(shown: Cell, w: *Writer) Writer.Error!void {
        for (shown.text) |char| {
            if (char == '|') try w.writeByte('\\');
            try w.writeByte(char);
        }
    }
};

/// `text` as a sentence: with a full stop after it, unless it ends in one, or in `!` or `?`.
fn sentence(text: []const u8) Sentence {
    return .{ .text = text };
}

const Sentence = struct {
    text: []const u8,

    pub fn format(shown: Sentence, w: *Writer) Writer.Error!void {
        try w.writeAll(shown.text);
        if (std.mem.findScalar(u8, ".!?", shown.text[shown.text.len - 1]) == null) try w.writeByte('.');
    }
};

test "the reference doesn't change unless the game's tables or the source do" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var out: Writer.Allocating = .init(arena_state.allocator());
    try write(arena_state.allocator(), &out.writer);
    if (!std.mem.eql(u8, out.written(), @embedFile("mission-reference.md"))) {
        std.debug.print("the reference of mission source has changed: if that's meant, run `make definitions` to update docs/guide/mission-reference.md\n", .{});
        return error.TestUnexpectedResult;
    }
}

test write {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: Writer.Allocating = .init(arena);
    try write(arena, &out.writer);
    const text = out.written();
    // A command's parameters, as the definitions name and type them, with the developers' labels.
    try std.testing.expect(std.mem.find(u8, text,
        \\| `entity_to_target` | `Entity?` | Entity to target (can be NULL) |
    ) != null);
    // A condition's values, and whether a trigger checks them; a `|` in a type is escaped.
    try std.testing.expect(std.mem.find(u8, text, "| `attacker` | Attacker | `MissionShip` | Yes |\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "| `(Entity \\| number)?` or `number?` |") != null);
}

test sentence {
    var buffer: [32]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    try w.print("{f} {f} {f}", .{ sentence("Dock Ship."), sentence("Fly"), sentence("Plays the movie!") });
    try std.testing.expectEqualStrings("Dock Ship. Fly. Plays the movie!", w.buffered());
}
