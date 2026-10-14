//! Mission source as Luau's parser reads it
//! ([Mission source](../../../../docs/formats/mission-source.md)): a tree of the statements and
//! expressions in the file, each node with the line and column where it starts and ends. The
//! `source_parser` module fills it with Luau's own parser, which only the tools that read source
//! link. A construct that mission source doesn't use, such as a loop, is an `unsupported` node, so
//! that the compiler can say where it is.

const std = @import("std");

/// A node's index in `Tree.nodes`.
pub const Index = u32;

/// The kinds of node, with the numbers `src/source_parser/luau.h` gives them.
pub const Kind = enum(u8) {
    // Statements.
    /// A list of statements: the file's chunk, a function's body, or a branch of an `if`.
    block = 0,
    @"if" = 1,
    @"return" = 2,
    /// A call made as a statement.
    call_statement = 3,
    local = 4,
    assign = 5,
    /// `target += value`, and the forms of the other operators.
    compound_assign = 6,
    // Expressions.
    nil = 20,
    boolean = 21,
    number = 22,
    string = 23,
    local_name = 24,
    global_name = 25,
    /// `object.name`.
    field = 26,
    /// `object[key]`.
    index = 27,
    call = 28,
    function = 29,
    table = 30,
    /// An item of a table.
    item = 31,
    unary = 32,
    binary = 33,
    /// A name that a local or a parameter declares.
    name = 34,
    /// A construct mission source doesn't use, such as a loop. Its text says what it is.
    unsupported = 40,
};

pub const UnaryOperator = enum(u8) {
    not,
    minus,
    length,

    /// The operator as Luau writes it.
    pub fn symbol(operator: UnaryOperator) []const u8 {
        return switch (operator) {
            .not => "not",
            .minus => "-",
            .length => "#",
        };
    }
};

pub const BinaryOperator = enum(u8) {
    add,
    sub,
    mul,
    div,
    floor_div,
    mod,
    pow,
    concat,
    not_equal,
    equal,
    less,
    less_equal,
    greater,
    greater_equal,
    @"and",
    @"or",

    /// The operator as Luau writes it.
    pub fn symbol(operator: BinaryOperator) []const u8 {
        return switch (operator) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .floor_div => "//",
            .mod => "%",
            .pow => "^",
            .concat => "..",
            .not_equal => "~=",
            .equal => "==",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
            .@"and" => "and",
            .@"or" => "or",
        };
    }
};

/// The forms of a table's item: `value`, `key = value` and `[key] = value`.
pub const ItemKind = enum(u8) { list, record, general };

/// A place in the source, where a node or an error starts or a node ends. Lines and columns count
/// from 0, and columns count bytes, as in Luau.
pub const Position = extern struct {
    line: u32,
    column: u32,

    /// Writes the place counting from 1, as an editor shows it: `12:5`.
    pub fn format(position: Position, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}:{d}", .{ @as(u64, position.line) + 1, @as(u64, position.column) + 1 });
    }
};

/// A node as the bridge writes it (`OrNode`), which `Tree.get` reads.
pub const Node = extern struct {
    kind: Kind,
    /// What the byte holds depends on the kind: the operator of a unary, binary or compound
    /// assignment node, the form of a table's item, a boolean's value, and how many of a local's,
    /// an assignment's or a function's children are its names, its targets or its parameters.
    op: u8,
    at: Position,
    /// Just past the node's last byte.
    end: Position,
    /// The node's children, `count` of them from `first` in `Tree.children`.
    first: u32,
    count: u32,
    /// The node's text, `text_length` bytes from `text_start` in `Tree.text`.
    text_start: u32,
    text_length: u32,
    /// A number's value, and for a name and a local's use, the local's number (`Syntax.Local`).
    number: f64,
};

/// An error Luau's parser found.
pub const Error = struct {
    at: Position,
    message: []const u8,
};

/// A node and its parts, in a form that depends on its kind.
pub const Syntax = union(Kind) {
    block: []const Index,
    @"if": If,
    @"return": []const Index,
    call_statement: Index,
    local: Binding,
    assign: Binding,
    compound_assign: CompoundAssign,
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    local_name: Local,
    global_name: []const u8,
    field: Field,
    index: Indexed,
    call: Call,
    function: Function,
    table: []const Index,
    item: Item,
    unary: Unary,
    binary: Binary,
    name: Local,
    unsupported: []const u8,

    /// A local, by its name and its number: each local the file declares, a parameter or a
    /// `local`, has a number of its own, which tells apart two of the same name where one hides
    /// the other.
    pub const Local = struct {
        name: []const u8,
        number: u32,
    };

    pub const If = struct {
        condition: Index,
        then: Index,
        /// The `else` block, or for an `elseif`, an `if`; null without either.
        @"else": ?Index,
    };

    /// `local names = values`, or `targets = values`.
    pub const Binding = struct {
        targets: []const Index,
        values: []const Index,

        /// The first `count` of `parts` are the targets, and the rest the values.
        fn split(parts: []const Index, count: u8) Binding {
            return .{ .targets = parts[0..count], .values = parts[count..] };
        }
    };

    pub const CompoundAssign = struct {
        operator: BinaryOperator,
        target: Index,
        value: Index,
    };

    pub const Field = struct {
        object: Index,
        name: []const u8,
    };

    pub const Indexed = struct {
        object: Index,
        key: Index,
    };

    pub const Call = struct {
        function: Index,
        arguments: []const Index,
    };

    pub const Function = struct {
        /// The parameters' `name` nodes.
        parameters: []const Index,
        body: Index,
    };

    pub const Item = union(ItemKind) {
        list: Index,
        record: struct { key: []const u8, value: Index },
        general: struct { key: Index, value: Index },
    };

    pub const Unary = struct {
        operator: UnaryOperator,
        operand: Index,
    };

    pub const Binary = struct {
        operator: BinaryOperator,
        left: Index,
        right: Index,
    };
};

/// A file of source, parsed.
pub const Tree = struct {
    nodes: []const Node,
    children: []const Index,
    text: []const u8,
    errors: []const Error,
    /// The file's chunk, a block.
    root: Index,

    /// The node at `index`, with its parts.
    pub fn get(tree: Tree, index: Index) Syntax {
        const node = tree.nodes[index];
        const parts = tree.childrenOf(index);
        const text = tree.textOf(index);
        return switch (node.kind) {
            .block => .{ .block = parts },
            .@"if" => .{ .@"if" = .{ .condition = parts[0], .then = parts[1], .@"else" = if (parts.len > 2) parts[2] else null } },
            .@"return" => .{ .@"return" = parts },
            .call_statement => .{ .call_statement = parts[0] },
            .local => .{ .local = .split(parts, node.op) },
            .assign => .{ .assign = .split(parts, node.op) },
            .compound_assign => .{ .compound_assign = .{ .operator = @fromBackingInt(node.op), .target = parts[0], .value = parts[1] } },
            .nil => .nil,
            .boolean => .{ .boolean = node.op != 0 },
            .number => .{ .number = node.number },
            .string => .{ .string = text },
            .local_name => .{ .local_name = .{ .name = text, .number = @intFromFloat(node.number) } },
            .global_name => .{ .global_name = text },
            .field => .{ .field = .{ .object = parts[0], .name = text } },
            .index => .{ .index = .{ .object = parts[0], .key = parts[1] } },
            .call => .{ .call = .{ .function = parts[0], .arguments = parts[1..] } },
            .function => .{ .function = .{ .parameters = parts[0..node.op], .body = parts[node.op] } },
            .table => .{ .table = parts },
            .item => .{
                .item = switch (@as(ItemKind, @fromBackingInt(node.op))) {
                    .list => .{ .list = parts[0] },
                    // Luau gives a record's key as a string.
                    .record => .{ .record = .{ .key = tree.textOf(parts[0]), .value = parts[1] } },
                    .general => .{ .general = .{ .key = parts[0], .value = parts[1] } },
                },
            },
            .unary => .{ .unary = .{ .operator = @fromBackingInt(node.op), .operand = parts[0] } },
            .binary => .{ .binary = .{ .operator = @fromBackingInt(node.op), .left = parts[0], .right = parts[1] } },
            .name => .{ .name = .{ .name = text, .number = @intFromFloat(node.number) } },
            .unsupported => .{ .unsupported = text },
        };
    }

    /// Where node `index` starts.
    pub fn at(tree: Tree, index: Index) Position {
        return tree.nodes[index].at;
    }

    /// Where node `index` ends, just past its last byte. A table's item ends with its value.
    pub fn end(tree: Tree, index: Index) Position {
        return tree.nodes[index].end;
    }

    fn childrenOf(tree: Tree, index: Index) []const Index {
        const node = tree.nodes[index];
        return tree.children[node.first..][0..node.count];
    }

    fn textOf(tree: Tree, index: Index) []const u8 {
        const node = tree.nodes[index];
        return tree.text[node.text_start..][0..node.text_length];
    }

    /// Writes node `index` and the nodes under it as S-expressions, for tests and debugging:
    /// `(call (global_name "on") (string "shot_at"))`.
    pub fn dump(tree: Tree, index: Index, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("({t}", .{tree.nodes[index].kind});
        switch (tree.get(index)) {
            .boolean => |value| try writer.print(" {}", .{value}),
            .number => |value| try writer.print(" {d}", .{value}),
            .string, .global_name, .unsupported => |text| try writer.print(" \"{f}\"", .{std.zig.fmtString(text)}),
            .local_name, .name => |local| try writer.print(" \"{f}\"", .{std.zig.fmtString(local.name)}),
            .field => |field| try writer.print(" \"{f}\"", .{std.zig.fmtString(field.name)}),
            .compound_assign => |assign| try writer.print(" {t}", .{assign.operator}),
            .unary => |unary| try writer.print(" {t}", .{unary.operator}),
            .binary => |binary| try writer.print(" {t}", .{binary.operator}),
            .item => |item| try writer.print(" {t}", .{item}),
            else => {},
        }
        for (tree.childrenOf(index)) |child| {
            try writer.writeByte(' ');
            try tree.dump(child, writer);
        }
        try writer.writeByte(')');
    }
};

test Tree {
    // `x += -2` and `on("a", { b = true })`, built by hand as the bridge writes them.
    const nodes = [_]Node{
        .{ .kind = .global_name, .op = 0, .at = .{ .line = 0, .column = 0 }, .end = .{ .line = 0, .column = 1 }, .first = 0, .count = 0, .text_start = 0, .text_length = 1, .number = 0 },
        .{ .kind = .number, .op = 0, .at = .{ .line = 0, .column = 6 }, .end = .{ .line = 0, .column = 7 }, .first = 0, .count = 0, .text_start = 1, .text_length = 0, .number = 2 },
        .{ .kind = .unary, .op = @backingInt(UnaryOperator.minus), .at = .{ .line = 0, .column = 5 }, .end = .{ .line = 0, .column = 7 }, .first = 0, .count = 1, .text_start = 1, .text_length = 0, .number = 0 },
        .{ .kind = .compound_assign, .op = @backingInt(BinaryOperator.add), .at = .{ .line = 0, .column = 0 }, .end = .{ .line = 0, .column = 7 }, .first = 1, .count = 2, .text_start = 1, .text_length = 0, .number = 0 },
        .{ .kind = .global_name, .op = 0, .at = .{ .line = 1, .column = 0 }, .end = .{ .line = 1, .column = 2 }, .first = 3, .count = 0, .text_start = 1, .text_length = 2, .number = 0 },
        .{ .kind = .string, .op = 0, .at = .{ .line = 1, .column = 3 }, .end = .{ .line = 1, .column = 6 }, .first = 3, .count = 0, .text_start = 3, .text_length = 1, .number = 0 },
        .{ .kind = .string, .op = 0, .at = .{ .line = 1, .column = 10 }, .end = .{ .line = 1, .column = 11 }, .first = 3, .count = 0, .text_start = 4, .text_length = 1, .number = 0 },
        .{ .kind = .boolean, .op = 1, .at = .{ .line = 1, .column = 14 }, .end = .{ .line = 1, .column = 18 }, .first = 3, .count = 0, .text_start = 5, .text_length = 0, .number = 0 },
        .{ .kind = .item, .op = @backingInt(ItemKind.record), .at = .{ .line = 1, .column = 10 }, .end = .{ .line = 1, .column = 18 }, .first = 3, .count = 2, .text_start = 5, .text_length = 0, .number = 0 },
        .{ .kind = .table, .op = 0, .at = .{ .line = 1, .column = 8 }, .end = .{ .line = 1, .column = 20 }, .first = 5, .count = 1, .text_start = 5, .text_length = 0, .number = 0 },
        .{ .kind = .call, .op = 0, .at = .{ .line = 1, .column = 0 }, .end = .{ .line = 1, .column = 21 }, .first = 6, .count = 3, .text_start = 5, .text_length = 0, .number = 0 },
        .{ .kind = .call_statement, .op = 0, .at = .{ .line = 1, .column = 0 }, .end = .{ .line = 1, .column = 21 }, .first = 9, .count = 1, .text_start = 5, .text_length = 0, .number = 0 },
        .{ .kind = .block, .op = 0, .at = .{ .line = 0, .column = 0 }, .end = .{ .line = 1, .column = 21 }, .first = 10, .count = 2, .text_start = 5, .text_length = 0, .number = 0 },
    };
    const children = [_]Index{ 1, 0, 2, 6, 7, 8, 4, 5, 9, 10, 3, 11 };
    const tree: Tree = .{ .nodes = &nodes, .children = &children, .text = "xonab", .errors = &.{}, .root = 12 };

    const assign = tree.get(3).compound_assign;
    try std.testing.expectEqual(.add, assign.operator);
    try std.testing.expectEqualStrings("x", tree.get(assign.target).global_name);
    try std.testing.expectEqual(.minus, tree.get(assign.value).unary.operator);
    const item = tree.get(8).item.record;
    try std.testing.expectEqualStrings("b", item.key);
    try std.testing.expect(tree.get(item.value).boolean);
    // An item starts at its key, and ends with its value.
    try std.testing.expectEqual(Position{ .line = 1, .column = 10 }, tree.at(8));
    try std.testing.expectEqual(Position{ .line = 1, .column = 18 }, tree.end(8));

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try tree.dump(tree.root, &out.writer);
    try std.testing.expectEqualStrings(
        \\(block (compound_assign add (global_name "x") (unary minus (number 2))) (call_statement (call (global_name "on") (string "a") (table (item record (string "b") (boolean true))))))
    , out.written());
}

test Position {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12:5", try std.mem.print(&buffer, "{f}", .{Position{ .line = 11, .column = 4 }}));
}
