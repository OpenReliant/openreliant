//! The command line's help pages, put together and wrapped at compile time: paragraphs, and tables
//! of what is typed beside what it does. `-h` or `--help` asks for one.

const std = @import("std");

/// The columns a page fits in, and where a table's descriptions start.
pub const width = 80;
pub const column = 28;

/// A table's row: what is typed, and what it does.
pub const Row = struct {
    typed: []const u8,
    text: []const u8,
};

/// `text` wrapped to `width`, as a paragraph indented by `indent`.
pub fn paragraph(comptime text: []const u8, comptime indent: usize) []const u8 {
    return wrap(text, indent, 0);
}

/// Whether `args` ask for help, with `-h` or `--help`.
pub fn asked(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    }
    return false;
}

/// `rows` as a table, each row's text wrapped in its own column, starting on a line of its own
/// where what is typed runs into it.
pub fn table(comptime rows: []const Row) []const u8 {
    comptime var out: []const u8 = "";
    inline for (rows) |row| {
        const lead = "  " ++ row.typed;
        out = out ++ if (lead.len + 2 <= column)
            lead ++ wrap(row.text, column, lead.len)
        else
            lead ++ "\n" ++ wrap(row.text, column, 0);
    }
    return out;
}

/// `text` wrapped to `width` with every line after the first indented by `indent`, the first
/// starting after `start` columns already written; each line ends in a newline.
fn wrap(comptime text: []const u8, comptime indent: usize, comptime start: usize) []const u8 {
    @setEvalBranchQuota(100_000);
    comptime var out: []const u8 = "";
    comptime var at = start;
    comptime var words = std.mem.tokenizeScalar(u8, text, ' ');
    comptime var first = true;
    inline while (comptime words.next()) |word| {
        if (!first and at + 1 + word.len > width) {
            out = out ++ "\n";
            at = 0;
            first = true;
        }
        if (first) {
            out = out ++ @as([indent -| at]u8, @splat(' '));
            at = @max(at, indent);
        } else {
            out = out ++ " ";
            at += 1;
        }
        out = out ++ word;
        at += word.len;
        first = false;
    }
    return out ++ "\n";
}

test paragraph {
    const words: []const u8 = @ptrCast(&@as([20][5]u8, @splat("word ".*)));
    const wrapped = comptime paragraph(words, 0);
    var lines = std.mem.splitScalar(u8, wrapped, '\n');
    try std.testing.expectEqual(79, lines.next().?.len);
    try std.testing.expectEqual(19, lines.next().?.len);
}

test asked {
    try std.testing.expect(asked(&.{ "out", "--help" }));
    try std.testing.expect(asked(&.{"-h"}));
    try std.testing.expect(!asked(&.{ "--from", "disc.bin", "out" }));
}

test table {
    const page = comptime table(&.{
        .{ .typed = "--short", .text = "does a thing" },
        .{ .typed = "--rather-long-option <with|a|value>", .text = "does another" },
        .{ .typed = "--wraps", .text = "a description long enough that it has to go on to a second line, which starts under the first" },
    });
    try std.testing.expectEqualStrings(
        \\  --short                   does a thing
        \\  --rather-long-option <with|a|value>
        \\                            does another
        \\  --wraps                   a description long enough that it has to go on to a
        \\                            second line, which starts under the first
        \\
    , page);
}
