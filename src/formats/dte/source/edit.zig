//! The edits an editor makes to mission source
//! ([Editors](../../../../docs/formats/mission-source.md#editors)): setting an argument of a
//! declaration, setting, adding or removing a field of its table, and adding a declaration. Each
//! edit replaces one span of the source, so the rest of the text keeps its comments and layout.
//! Values are written the way the decompiler writes them (`write.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const script = @import("script.zig");
const syntax = @import("syntax.zig");
const write = @import("write.zig");
const Index = syntax.Index;
const Position = syntax.Position;

/// Text that replaces the source from `start` up to `end`. An edit that only inserts text has the
/// same `start` and `end`.
pub const Edit = struct {
    start: Position,
    end: Position,
    text: []const u8,
};

/// A value an edit writes.
pub const Value = union(enum) {
    number: f32,
    vector: [3]f32,
    /// A string.
    text: []const u8,
    /// A name, such as a declared record's, written as it is.
    name: []const u8,
    boolean: bool,
    /// A table, on one line.
    table: []const Item,
    /// Source written as it is, such as `sabres[2]`.
    source: []const u8,

    /// An item of a table: `key = value`, or just a value if it has no key.
    pub const Item = struct {
        key: ?[]const u8 = null,
        value: Value,

        pub fn format(item: Item, w: *Writer) Writer.Error!void {
            if (item.key) |key| try w.print("{s} = ", .{key});
            try w.print("{f}", .{item.value});
        }
    };

    pub fn format(value: Value, w: *Writer) Writer.Error!void {
        switch (value) {
            .number => |number| try w.print("{f}", .{write.number(number)}),
            .vector => |vector| try w.print("{f}", .{write.vector(vector)}),
            .text => |text| try script.writeString(w, text),
            .name, .source => |text| try w.writeAll(text),
            .boolean => |boolean| try w.writeAll(if (boolean) "true" else "false"),
            .table => |items| {
                if (items.len == 0) return w.writeAll("{}");
                try w.writeAll("{ ");
                for (items, 0..) |item, index| try w.print("{s}{f}", .{ if (index > 0) ", " else "", item });
                try w.writeAll(" }");
            },
        }
    }
};

/// Mission source as an editor edits it: the text, the tree that Luau's parser reads from it, and
/// where each line starts. Lines and columns count from 0, and columns count bytes, as in Luau.
pub const Source = struct {
    text: []const u8,
    tree: syntax.Tree,
    line_starts: []const usize,

    /// The source of `text`, with `tree` as `source_parser.parse` reads it from `text`.
    pub fn init(arena: Allocator, text: []const u8, tree: syntax.Tree) Allocator.Error!Source {
        var starts: std.ArrayList(usize) = .empty;
        try starts.append(arena, 0);
        for (text, 0..) |byte, index| if (byte == '\n') try starts.append(arena, index + 1);
        return .{ .text = text, .tree = tree, .line_starts = starts.items };
    }

    /// The call that declares `name` (`name = word(...)`), or null if the source doesn't declare
    /// it.
    pub fn declaration(source: Source, name: []const u8) ?Index {
        for (source.statements()) |statement| {
            const call = source.declared(statement) orelse continue;
            if (std.mem.eql(u8, call.name, name)) return call.call;
        }
        return null;
    }

    /// The call of the statement that starts on `line`: a declaration's call, or a call made as a
    /// statement, such as a trigger's `on(...)`.
    pub fn callOn(source: Source, line: u32) ?Index {
        for (source.statements()) |statement| {
            if (source.tree.at(statement).line != line) continue;
            if (source.declared(statement)) |found| return found.call;
            return switch (source.tree.get(statement)) {
                .call_statement => |call| call,
                else => null,
            };
        }
        return null;
    }

    /// The last statement that declares a record with `word` (`name = word(...)`), if there is
    /// one.
    pub fn lastDeclarationOf(source: Source, word: []const u8) ?Index {
        var last: ?Index = null;
        for (source.statements()) |statement| {
            const found = source.declared(statement) orelse continue;
            const called = source.callee(found.call) orelse continue;
            if (std.mem.eql(u8, called, word)) last = statement;
        }
        return last;
    }

    /// The name that `call` calls, such as `ship`, or null if it calls something other than a
    /// name.
    pub fn callee(source: Source, call: Index) ?[]const u8 {
        return switch (source.tree.get(call)) {
            .call => |found| switch (source.tree.get(found.function)) {
                .global_name => |name| name,
                else => null,
            },
            else => null,
        };
    }

    /// The edit that sets argument `index` of `call` to `value`. If the call has exactly `index`
    /// arguments, the value is added after the last one. Null if the call has fewer arguments.
    pub fn setArgument(source: Source, arena: Allocator, call: Index, index: usize, value: Value) Allocator.Error!?Edit {
        const arguments = source.argumentsOf(call) orelse return null;
        if (index < arguments.len) return try source.replace(arena, arguments[index], value);
        if (index == arguments.len) return try source.append(arena, call, try arena.print("{f}", .{value}));
        return null;
    }

    /// The edit that sets `field` to `value` in the table that is argument `index` of `call`. If
    /// the table has the field, its value is replaced. Otherwise the field is added after the last
    /// item: on a new line if the table spans several lines, and on the same line if not. If
    /// argument `index` isn't a table, a table with the field is added before it, such as before
    /// a trigger's function, or after the last argument if the call has exactly `index`
    /// arguments. Null if the call has fewer arguments.
    pub fn setField(source: Source, arena: Allocator, call: Index, index: usize, field: []const u8, value: Value) Allocator.Error!?Edit {
        const arguments = source.argumentsOf(call) orelse return null;
        const item = try arena.print("{s} = {f}", .{ field, value });
        if (index == arguments.len) return try source.append(arena, call, try arena.print("{{ {s} }}", .{item}));
        if (index > arguments.len) return null;
        const table = arguments[index];
        const items = switch (source.tree.get(table)) {
            .table => |items| items,
            else => return try insert(arena, source.tree.at(table), "{{ {s} }}, ", .{item}),
        };
        if (source.itemIndex(items, field)) |found| return try source.replace(arena, source.valueOf(items[found]), value);
        if (items.len == 0) return .{ .start = source.tree.at(table), .end = source.tree.end(table), .text = try arena.print("{{ {s} }}", .{item}) };
        const last = items[items.len - 1];
        const last_end = source.offset(source.tree.end(last));
        if (source.tree.at(last).line > source.tree.at(table).line and source.endsLine(last_end)) {
            // On a new line after the last item, with the same indent, and with a comma after the
            // last item if it has none.
            const line_end = source.lineEnd(last_end);
            const rest = source.text[last_end..line_end];
            const comma = if (std.mem.startsWith(u8, std.mem.trimStart(u8, rest, " \t"), ",")) "" else ",";
            return .{
                .start = source.tree.end(last),
                .end = source.positionOf(line_end),
                .text = try arena.print("{s}{s}\n{s}{s},", .{ comma, rest, source.indentOf(source.tree.at(last).line), item }),
            };
        }
        // On the last item's line: after its comma if it has one, and otherwise after the item.
        const after = source.text[last_end..];
        const spaces = after.len - std.mem.trimStart(u8, after, " \t").len;
        if (last_end + spaces < source.text.len and source.text[last_end + spaces] == ',') {
            return try insert(arena, source.positionOf(last_end + spaces + 1), " {s},", .{item});
        }
        return try insert(arena, source.tree.end(last), ", {s}", .{item});
    }

    /// The edit that removes `field` from the table that is argument `index` of `call`. An item
    /// that is alone on its lines goes with its lines, comment included, and any other item with
    /// the comma between it and its neighbour. Removing the only item leaves `{}`. Null if the
    /// table doesn't have the field.
    pub fn removeField(source: Source, call: Index, index: usize, field: []const u8) ?Edit {
        const arguments = source.argumentsOf(call) orelse return null;
        if (index >= arguments.len) return null;
        const table = arguments[index];
        const items = switch (source.tree.get(table)) {
            .table => |items| items,
            else => return null,
        };
        const place = source.itemIndex(items, field) orelse return null;
        if (items.len == 1) return .{ .start = source.tree.at(table), .end = source.tree.end(table), .text = "{}" };
        const item = items[place];
        if (source.tree.at(item).line > source.tree.at(table).line and source.aloneOnLines(item)) {
            const last_line = source.tree.end(item).line;
            return .{ .start = .{ .line = source.tree.at(item).line, .column = 0 }, .end = source.positionOf(source.lineStart(last_line + 1)), .text = "" };
        }
        if (place + 1 < items.len) return .{ .start = source.tree.at(item), .end = source.tree.at(items[place + 1]), .text = "" };
        return .{ .start = source.tree.end(items[place - 1]), .end = source.tree.end(item), .text = "" };
    }

    /// The edit that adds the declaration `name = word(values)` on a new line after the statement
    /// `after`, or at the end of the text if `after` is null. If the last argument is a table and
    /// the line would be longer than `write.line_length`, each of its items goes on a line of its
    /// own.
    pub fn declare(source: Source, arena: Allocator, after: ?Index, name: []const u8, word: []const u8, values: []const Value) Allocator.Error!Edit {
        var line: Writer.Allocating = .init(arena);
        line.writer.print("{s} = {s}(", .{ name, word }) catch return error.OutOfMemory;
        for (values, 0..) |argument, index| {
            if (index > 0) line.writer.writeAll(", ") catch return error.OutOfMemory;
            const last_table = index + 1 == values.len and argument == .table;
            if (!last_table) {
                line.writer.print("{f}", .{argument}) catch return error.OutOfMemory;
                continue;
            }
            const items = try arena.alloc([]const u8, argument.table.len);
            for (items, argument.table) |*text, item| text.* = try arena.print("{f}", .{item});
            write.writeTable(&line.writer, items, line.written().len, ")".len) catch return error.OutOfMemory;
        }
        line.writer.writeAll(")\n") catch return error.OutOfMemory;
        const at = if (after) |statement| source.lineStart(source.tree.end(statement).line + 1) else source.text.len;
        // At the end of a text whose last line has no line break, the declaration starts one.
        const lead = if (at == source.text.len and at > 0 and source.text[at - 1] != '\n') "\n" else "";
        return insert(arena, source.positionOf(at), "{s}{s}", .{ lead, line.written() });
    }

    /// The text after `edit`, allocated in `arena`.
    pub fn apply(source: Source, arena: Allocator, edit: Edit) Allocator.Error![]u8 {
        const start = source.offset(edit.start);
        const end = source.offset(edit.end);
        return std.mem.concat(arena, u8, &.{ source.text[0..start], edit.text, source.text[end..] });
    }

    fn statements(source: Source) []const Index {
        return switch (source.tree.get(source.tree.root)) {
            .block => |list| list,
            else => &.{},
        };
    }

    /// The name and the call of a declaration, `name = word(...)`.
    fn declared(source: Source, statement: Index) ?struct { name: []const u8, call: Index } {
        const assign = switch (source.tree.get(statement)) {
            .assign => |assign| assign,
            else => return null,
        };
        if (assign.targets.len != 1 or assign.values.len != 1) return null;
        const name = switch (source.tree.get(assign.targets[0])) {
            .global_name => |name| name,
            else => return null,
        };
        if (source.tree.get(assign.values[0]) != .call) return null;
        return .{ .name = name, .call = assign.values[0] };
    }

    fn argumentsOf(source: Source, call: Index) ?[]const Index {
        return switch (source.tree.get(call)) {
            .call => |found| found.arguments,
            else => null,
        };
    }

    /// The index in `items` of the item `field = value`.
    fn itemIndex(source: Source, items: []const Index, field: []const u8) ?usize {
        for (items, 0..) |item, index| switch (source.tree.get(item)) {
            .item => |found| switch (found) {
                .record => |record| if (std.mem.eql(u8, record.key, field)) return index,
                else => {},
            },
            else => {},
        };
        return null;
    }

    fn valueOf(source: Source, item: Index) Index {
        return switch (source.tree.get(item).item) {
            .list => |value| value,
            .record => |record| record.value,
            .general => |general| general.value,
        };
    }

    /// The edit that replaces `node` with `value`.
    fn replace(source: Source, arena: Allocator, node: Index, value: Value) Allocator.Error!Edit {
        return .{ .start = source.tree.at(node), .end = source.tree.end(node), .text = try arena.print("{f}", .{value}) };
    }

    /// The edit that adds `text` as the last argument of `call`.
    fn append(source: Source, arena: Allocator, call: Index, text: []const u8) Allocator.Error!Edit {
        const list = source.argumentsOf(call) orelse unreachable;
        if (list.len > 0) return insert(arena, source.tree.end(list[list.len - 1]), ", {s}", .{text});
        // Before the call's closing bracket.
        const end = source.tree.end(call);
        return insert(arena, .{ .line = end.line, .column = end.column -| 1 }, "{s}", .{text});
    }

    /// Whether `item` is alone on its lines: only spaces before it on its first line, and only a
    /// comma, spaces and a comment after it on its last.
    fn aloneOnLines(source: Source, item: Index) bool {
        const start = source.tree.at(item);
        const before = source.text[source.lineStart(start.line)..source.offset(start)];
        return std.mem.trim(u8, before, " \t").len == 0 and source.endsLine(source.offset(source.tree.end(item)));
    }

    /// Whether only a comma, spaces and a comment follow byte `index` on its line.
    fn endsLine(source: Source, index: usize) bool {
        var rest = std.mem.trim(u8, source.text[index..source.lineEnd(index)], " \t\r");
        if (std.mem.startsWith(u8, rest, ",")) rest = std.mem.trimStart(u8, rest[1..], " \t");
        return rest.len == 0 or std.mem.startsWith(u8, rest, "--");
    }

    /// Where the line of byte `index` ends: at its line break, or at the end of the text.
    fn lineEnd(source: Source, index: usize) usize {
        return std.mem.findScalarPos(u8, source.text, index, '\n') orelse source.text.len;
    }

    /// The spaces and tabs at the start of line `line`.
    fn indentOf(source: Source, line: u32) []const u8 {
        const start = source.lineStart(line);
        var end = start;
        while (end < source.text.len and (source.text[end] == ' ' or source.text[end] == '\t')) end += 1;
        return source.text[start..end];
    }

    /// Where line `line` starts in the text, or the end of the text past the last line.
    fn lineStart(source: Source, line: u32) usize {
        return if (line < source.line_starts.len) source.line_starts[line] else source.text.len;
    }

    fn offset(source: Source, position: Position) usize {
        return @min(source.text.len, source.lineStart(position.line) + position.column);
    }

    /// The line and column of byte `index` of the text.
    fn positionOf(source: Source, index: usize) Position {
        var line: usize = std.sort.upperBound(usize, source.line_starts, index, struct {
            fn order(wanted: usize, start: usize) std.math.Order {
                return std.math.order(wanted, start);
            }
        }.order);
        line -|= 1;
        return .{ .line = @intCast(line), .column = @intCast(index - source.line_starts[line]) };
    }
};

/// The edit that inserts `format` with `args` at `at`.
fn insert(arena: Allocator, at: Position, comptime format: []const u8, args: anytype) Allocator.Error!Edit {
    return .{ .start = at, .end = at, .text = try arena.print(format, args) };
}

test Value {
    var buffer: [128]u8 = undefined;
    var w: Writer = .fixed(&buffer);
    const values = [_]Value{
        .{ .number = 0.5 },
        .{ .vector = .{ -2000, 0, 42000 } },
        .{ .text = "Sabre \"1\"" },
        .{ .name = "alpha" },
        .{ .boolean = false },
        .{ .table = &.{} },
        .{ .table = &.{ .{ .key = "from", .value = .{ .name = "carrier" } }, .{ .value = .{ .number = 2 } } } },
        .{ .source = "sabres[2]" },
    };
    for (values) |value| try w.print("{f}; ", .{value});
    try std.testing.expectEqualStrings("0.5; { -2000, 0, 42000 }; \"Sabre \\\"1\\\"\"; alpha; false; {}; { from = carrier, 2 }; sabres[2]; ", w.buffered());
}
