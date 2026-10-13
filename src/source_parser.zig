//! Reads mission source with Luau's own parser
//! ([Mission source](../docs/formats/mission-source.md)): `source_parser/luau.cpp` parses the
//! text and writes the syntax tree into flat arrays, and `parse` copies them into the library's
//! tree (`dte.source.syntax`). It is a module of its own because it links Luau's parser, which the
//! library the tools share doesn't.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const syntax = @import("openreliant").dte.source.syntax;
const luau = @import("luau_syntax");

/// Parses `text` as Luau, into a tree in `arena` with the errors Luau's parser found.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!syntax.Tree {
    const parsed: ?*luau.OrTree = luau.openreliant_parse_luau(text.ptr, text.len);
    const tree = parsed orelse return error.OutOfMemory;
    defer luau.openreliant_luau_tree_free(tree);
    const nodes: [*]const syntax.Node = @ptrCast(tree.nodes);
    const own_text = try arena.dupe(u8, tree.text[0..tree.text_length]);
    const errors = try arena.alloc(syntax.Error, tree.error_count);
    for (errors, tree.errors[0..tree.error_count]) |*made, found| made.* = .{
        .at = .{ .line = found.line, .column = found.column },
        .message = own_text[found.message_start..][0..found.message_length],
    };
    return .{
        .nodes = try arena.dupe(syntax.Node, nodes[0..tree.node_count]),
        .children = try arena.dupe(syntax.Index, tree.children[0..tree.child_count]),
        .text = own_text,
        .errors = errors,
        .root = tree.root,
    };
}

// The bridge's nodes have the library's layout, and the header gives every kind of node, operator
// and form of a table's item the library's number.
comptime {
    assert(@sizeOf(syntax.Node) == @sizeOf(luau.OrNode));
    for ([_][]const u8{ "kind", "op", "first", "count", "text_start", "text_length", "number" }) |field| {
        assert(@offsetOf(syntax.Node, field) == @offsetOf(luau.OrNode, field));
    }
    assert(@offsetOf(syntax.Node, "at") + @offsetOf(syntax.Position, "line") == @offsetOf(luau.OrNode, "line"));
    assert(@offsetOf(syntax.Node, "at") + @offsetOf(syntax.Position, "column") == @offsetOf(luau.OrNode, "column"));
    sameNumbers(syntax.Kind, "OR_", &.{ "OR_UNARY_", "OR_BINARY_", "OR_ITEM_" });
    sameNumbers(syntax.UnaryOperator, "OR_UNARY_", &.{});
    sameNumbers(syntax.BinaryOperator, "OR_BINARY_", &.{});
    sameNumbers(syntax.ItemKind, "OR_ITEM_", &.{});
}

/// Checks that each of the header's constants whose name starts with `prefix`, and with none of
/// `others`, is a tag of `Enum` in capitals with the same number, and that every tag has one.
fn sameNumbers(comptime Enum: type, comptime prefix: []const u8, comptime others: []const []const u8) void {
    @setEvalBranchQuota(100_000);
    var count = 0;
    for (std.meta.declarations(luau)) |name| {
        if (!std.mem.startsWith(u8, name, prefix) or startsWithAny(name, others)) continue;
        var lower: [name.len - prefix.len]u8 = undefined;
        _ = std.ascii.lowerString(&lower, name[prefix.len..]);
        const tag = std.meta.stringToEnum(Enum, &lower) orelse @compileError(name ++ " has no tag in " ++ @typeName(Enum));
        if (@backingInt(tag) != @field(luau, name)) @compileError(name ++ " has another number than " ++ @typeName(Enum));
        count += 1;
    }
    if (count != std.enums.values(Enum).len) @compileError("luau.h lacks tags of " ++ @typeName(Enum));
}

fn startsWithAny(name: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
    return false;
}

/// Checks that `text` parses without an error into the statements `expected`, one per line as
/// `syntax.Tree.dump` writes them.
fn expectTree(text: []const u8, expected: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try parse(arena, text);
    for (tree.errors) |found| std.debug.print("{f}: {s}\n", .{ found.at, found.message });
    try std.testing.expectEqual(0, tree.errors.len);
    var out: std.Io.Writer.Allocating = .init(arena);
    for (tree.get(tree.root).block, 0..) |statement, index| {
        if (index > 0) try out.writer.writeByte('\n');
        try tree.dump(statement, &out.writer);
    }
    try std.testing.expectEqualStrings(expected, out.written());
}

test "records" {
    try expectTree(
        \\-- A comment, which leaves nothing.
        \\reliant_group = flight_group("(FG)Reliant", { wing = "player" })
        \\
        \\position = { -11608147, (-0.5), 1.5e6 }
        \\point = sabres[2]
    ,
        \\(assign (global_name "reliant_group") (call (global_name "flight_group") (string "(FG)Reliant") (table (item record (string "wing") (string "player")))))
        \\(assign (global_name "position") (table (item list (unary minus (number 11608147))) (item list (unary minus (number 0.5))) (item list (number 1500000))))
        \\(assign (global_name "point") (index (global_name "sabres") (number 2)))
    );
}

test "triggers and parts" {
    try expectTree(
        \\on(convoy, "shot_at", { attacker = any_ship }, function(attacker: Ship, hull_damage) end)
        \\go_home = part("(F)GO HOME", function(arg0) return 1 end, { start = true })
    ,
        \\(call_statement (call (global_name "on") (global_name "convoy") (string "shot_at") (table (item record (string "attacker") (global_name "any_ship"))) (function (name "attacker") (name "hull_damage") (block))))
        \\(assign (global_name "go_home") (call (global_name "part") (string "(F)GO HOME") (function (name "arg0") (block (return (number 1)))) (table (item record (string "start") (boolean true)))))
    );
}

test "the script" {
    try expectTree(
        \\if hits >= 50 then hits += 1 elseif lost then go_home() else end
        \\local roll: number = random()
        \\SetAI(attacker, "find_new_target", 1, nil)
        \\spawn(go_home, roll)
        \\over = game.mission_over == 0 and result() ~= game[37] or not done
        \\return 1
    ,
        \\(if (binary greater_equal (global_name "hits") (number 50)) (block (compound_assign add (global_name "hits") (number 1))) (if (global_name "lost") (block (call_statement (call (global_name "go_home")))) (block)))
        \\(local (name "roll") (call (global_name "random")))
        \\(call_statement (call (global_name "SetAI") (global_name "attacker") (string "find_new_target") (number 1) (nil)))
        \\(call_statement (call (global_name "spawn") (global_name "go_home") (local_name "roll")))
        \\(assign (global_name "over") (binary or (binary and (binary equal (field "mission_over" (global_name "game")) (number 0)) (binary not_equal (call (global_name "result")) (index (global_name "game") (number 37)))) (unary not (global_name "done"))))
        \\(return (number 1))
    );
}

test "constructs mission source doesn't use" {
    try expectTree(
        \\while true do end
        \\function f() end
        \\ship:fire()
        \\x = function(...) end
        \\y = `{x} hits`
        \\z = if x then 1 else 2
        \\plain = `plain`
    ,
        \\(unsupported "a loop")
        \\(unsupported "a function declared by name")
        \\(call_statement (unsupported "a method call"))
        \\(assign (global_name "x") (unsupported "a function that takes `...`"))
        \\(assign (global_name "y") (unsupported "a string with values put into it"))
        \\(assign (global_name "z") (unsupported "an if expression"))
        \\(assign (global_name "plain") (string "plain"))
    );
}

test "errors and their places" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try parse(arena,
        \\x = ship("Player",
        \\y = 2
    );
    try std.testing.expect(tree.errors.len > 0);
    try std.testing.expectEqual(syntax.Position{ .line = 1, .column = 2 }, tree.errors[0].at);
    try std.testing.expect(tree.errors[0].message.len > 0);
    // Nothing at all is an empty chunk.
    const empty = try parse(arena, "");
    try std.testing.expectEqual(0, empty.errors.len);
    try std.testing.expectEqual(0, empty.get(empty.root).block.len);
}
