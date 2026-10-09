//! The text format of Battlestar Galactica's models (`.mdl`) and objects' definitions (`.lvl`): a
//! tree of blocks, each a name on a line of its own and its contents between braces, each on lines
//! of their own. A block holds statements, a key and its arguments between parentheses, such as
//! `matrix(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1)`, blocks of its own, and comments after `//`. An
//! argument between braces, such as `{c1_viper2}`, is a name or a string.
//!
//! ```text
//! model
//! {
//! // Maya scene Z:/BattleStar/SHIPS/sh_v2_viper01/models/sh_v2_viper01.mb
//!     model
//!     {
//!         name({c1_viper2})
//!         parent({})
//!     }
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Statement = struct {
    key: []const u8,
    /// Its arguments, each without the braces around it.
    args: []const []const u8,

    /// Argument `index` as a number, or null where it is missing or isn't one.
    pub fn number(statement: Statement, index: usize) ?f32 {
        if (index >= statement.args.len) return null;
        return std.fmt.parseFloat(f32, statement.args[index]) catch null;
    }

    /// The arguments from `first` on as `count` numbers, or null where they aren't.
    pub fn numbers(statement: Statement, comptime count: usize, first: usize) ?[count]f32 {
        var values: [count]f32 = undefined;
        for (&values, first..) |*value, at| value.* = statement.number(at) orelse return null;
        return values;
    }

    /// Argument `index`, or null where it is missing.
    pub fn arg(statement: Statement, index: usize) ?[]const u8 {
        return if (index < statement.args.len) statement.args[index] else null;
    }
};

pub const Block = struct {
    name: []const u8,
    /// Its comments, each the text after `//`.
    comments: []const []const u8,
    statements: []const Statement,
    blocks: []const Block,

    /// The first statement with `key`, or null for none.
    pub fn statement(block: Block, key: []const u8) ?Statement {
        for (block.statements) |held| {
            if (std.mem.eql(u8, held.key, key)) return held;
        }
        return null;
    }
};

pub const Error = error{
    /// A line that is none of a block's name, a brace, a statement or a comment, or braces that
    /// don't match.
    NotText,
} || Allocator.Error;

/// The tree of `text`: its one block at the top.
pub fn parse(arena: Allocator, text: []const u8) Error!Block {
    var reading: Reading = .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    const name = reading.nextLine() orelse return error.NotText;
    if (!isName(name)) return error.NotText;
    const top = try reading.block(arena, name);
    if (reading.nextLine() != null) return error.NotText;
    return top;
}

const Reading = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    /// The next line with something on it, trimmed.
    fn nextLine(reading: *Reading) ?[]const u8 {
        while (reading.lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) return trimmed;
        }
        return null;
    }

    /// The block called `name`, from its opening brace to its closing one.
    fn block(reading: *Reading, arena: Allocator, name: []const u8) Error!Block {
        const opening = reading.nextLine() orelse return error.NotText;
        if (!std.mem.eql(u8, opening, "{")) return error.NotText;
        var comments: std.ArrayList([]const u8) = .empty;
        var statements: std.ArrayList(Statement) = .empty;
        var blocks: std.ArrayList(Block) = .empty;
        while (reading.nextLine()) |line| {
            if (std.mem.eql(u8, line, "}")) return .{
                .name = name,
                .comments = comments.items,
                .statements = statements.items,
                .blocks = blocks.items,
            };
            if (std.mem.startsWith(u8, line, comment)) {
                try comments.append(arena, std.mem.trim(u8, line[comment.len..], " "));
            } else if (isName(line)) {
                try blocks.append(arena, try reading.block(arena, line));
            } else {
                try statements.append(arena, try parseStatement(arena, line));
            }
        }
        return error.NotText;
    }
};

const comment = "//";

/// Whether `line` is a block's name: a word of letters, digits and underscores.
fn isName(line: []const u8) bool {
    for (line) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}

/// The statement on `line`: a key, then its arguments between parentheses, separated by commas
/// that aren't between braces.
fn parseStatement(arena: Allocator, line: []const u8) Error!Statement {
    const open = std.mem.findScalar(u8, line, '(') orelse return error.NotText;
    if (line[line.len - 1] != ')' or !isName(line[0..open]) or open == 0) return error.NotText;
    const inside = line[open + 1 .. line.len - 1];
    var args: std.ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (inside, 0..) |byte, at| switch (byte) {
        '{' => depth += 1,
        '}' => depth = std.math.sub(usize, depth, 1) catch return error.NotText,
        ',' => if (depth == 0) {
            try args.append(arena, unbraced(inside[start..at]));
            start = at + 1;
        },
        else => {},
    };
    if (depth != 0) return error.NotText;
    if (inside.len > 0) try args.append(arena, unbraced(inside[start..]));
    return .{ .key = line[0..open], .args = args.items };
}

/// `arg` trimmed, without the braces around it.
fn unbraced(arg: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, arg, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') return trimmed[1 .. trimmed.len - 1];
    return trimmed;
}

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        "model\r\n{\r\n// Maya scene Z:/BattleStar/SHIPS/sh_v2_viper01/models/sh_v2_viper01.mb\r\n" ++
        "\tmodel\r\n\t{\r\n\t\tname({c1_viper2})\r\n\t\tparent({})\r\n" ++
        "\t\tpivot(-0.000002,-4.70512,608.104614,1)\r\n\t}\r\n\r\n" ++
        "\tattribute({FriendOrFoe}, const, string,{FRIEND})\r\n}\r\n";
    const top = try parse(arena, text);
    try std.testing.expectEqualStrings("model", top.name);
    try std.testing.expectEqualStrings("Maya scene Z:/BattleStar/SHIPS/sh_v2_viper01/models/sh_v2_viper01.mb", top.comments[0]);
    const part = top.blocks[0];
    try std.testing.expectEqualStrings("c1_viper2", part.statement("name").?.arg(0).?);
    try std.testing.expectEqualStrings("", part.statement("parent").?.arg(0).?);
    try std.testing.expectEqual([4]f32{ -0.000002, -4.70512, 608.104614, 1 }, part.statement("pivot").?.numbers(4, 0).?);
    const attribute = top.statement("attribute").?;
    try std.testing.expectEqual(4, attribute.args.len);
    try std.testing.expectEqualStrings("FriendOrFoe", attribute.args[0]);
    try std.testing.expectEqualStrings("FRIEND", attribute.args[3]);
    try std.testing.expectEqual(null, attribute.number(1));

    try std.testing.expectError(error.NotText, parse(arena, "model\n{\n"));
    try std.testing.expectError(error.NotText, parse(arena, "model\n{\nname({a)\n}\n"));
}
