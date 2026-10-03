//! The names tables kept by hand in `ghidra/names`, which `ghidra/scripts/Annotate.java` applies
//! after the rows `names` writes, so that a hand row overrides a generated one. Their rows are
//! checked here, so that a malformed row fails the tests instead of a Ghidra run, so that GitHub
//! can show each table as one, and so that no address is named twice among the hand tables or
//! among the generated rows.

const std = @import("std");
const Io = std.Io;

const names = @import("names.zig");

/// A table of rows, under the name its rows are reported by.
pub const Table = struct {
    name: []const u8,
    text: []const u8,
};

/// The tables, under their names in `ghidra/names`, as `build.zig` embeds them.
pub const hand = [_]Table{
    .{ .name = "LANCER.EXE.runtime.tsv", .text = @embedFile("LANCER.EXE.runtime.tsv") },
    .{ .name = "LANCER.EXE.tsv", .text = @embedFile("LANCER.EXE.tsv") },
    .{ .name = "srd3d.dll.tsv", .text = @embedFile("srd3d.dll.tsv") },
};

pub const Kind = enum { function, data };

/// A row: address, kind, name, then a type and a comment, either of which may be empty.
pub const Row = struct {
    address: u32,
    kind: Kind,
    name: []const u8,
    type: []const u8,
    comment: []const u8,
};

pub const Error = error{ Malformed, BadAddress, BadKind, BadName, BadCharacter };

/// The first line of each hand table, which GitHub shows as the table's header.
pub const header = "address\tkind\tname\ttype\tcomment";

/// A line's row, or null for the header, a comment or a blank line.
pub fn parseLine(line: []const u8) Error!?Row {
    if (line.len == 0 or line[0] == '#' or std.mem.eql(u8, line, header)) return null;
    // The project writes no en or em dashes, in these tables either.
    if (std.mem.indexOf(u8, line, "\u{2013}") != null or std.mem.indexOf(u8, line, "\u{2014}") != null)
        return error.BadCharacter;

    var fields: [5][]const u8 = @splat("");
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |field| : (count += 1) {
        if (count == fields.len) return error.Malformed;
        fields[count] = field;
    }
    if (count < 3) return error.Malformed;

    const address = fields[0];
    if (address.len != 8) return error.BadAddress;
    for (address) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return error.BadAddress,
    };
    const name = fields[2];
    if (name.len == 0) return error.BadName;
    for (name) |c| if (c <= ' ' or c == 0x7F) return error.BadName;

    return .{
        .address = std.fmt.parseInt(u32, address, 16) catch return error.BadAddress,
        .kind = std.meta.stringToEnum(Kind, fields[1]) orelse return error.BadKind,
        .name = name,
        .type = fields[3],
        .comment = fields[4],
    };
}

/// A row of a hand table. GitHub shows a file as a table only if every row has the same columns,
/// so each has all five, with empty fields where there is no type or comment, and no double quote,
/// which GitHub reads as quoting.
pub fn handRow(line: []const u8) Error!Row {
    if (std.mem.count(u8, line, "\t") != 4) return error.Malformed;
    if (std.mem.indexOfScalar(u8, line, '"') != null) return error.BadCharacter;
    return try parseLine(line) orelse error.Malformed;
}

test handRow {
    const row = try handRow("00515240\tdata\t__iob\t\t");
    try std.testing.expectEqualStrings("__iob", row.name);
    try std.testing.expectError(error.Malformed, handRow("00515240\tdata\t__iob"));
    try std.testing.expectError(error.Malformed, handRow(""));
    try std.testing.expectError(error.Malformed, handRow("# Script VM\t\t\t\t"));
    try std.testing.expectError(error.Malformed, handRow(header));
    try std.testing.expectError(error.BadCharacter, handRow("00515240\tdata\t__iob\t\tthe \"iob\""));
}

test parseLine {
    try std.testing.expectEqual(null, try parseLine(""));
    try std.testing.expectEqual(null, try parseLine("# Script VM"));

    const row = (try parseLine("004d0333\tfunction\t_free\tvoid __cdecl (void *block)\tFrees")).?;
    try std.testing.expectEqual(0x004D0333, row.address);
    try std.testing.expectEqual(Kind.function, row.kind);
    try std.testing.expectEqualStrings("_free", row.name);
    try std.testing.expectEqualStrings("void __cdecl (void *block)", row.type);
    try std.testing.expectEqualStrings("Frees", row.comment);

    const bare = (try parseLine("00515240\tdata\t__iob")).?;
    try std.testing.expectEqual(Kind.data, bare.kind);
    try std.testing.expectEqualStrings("", bare.type);

    try std.testing.expectError(error.Malformed, parseLine("004d0333\tfunction"));
    try std.testing.expectError(error.Malformed, parseLine("004d0333\tfunction\t_free\t\t\t"));
    try std.testing.expectError(error.BadAddress, parseLine("4d0333\tfunction\t_free"));
    try std.testing.expectError(error.BadAddress, parseLine("004D0333\tfunction\t_free"));
    try std.testing.expectError(error.BadKind, parseLine("004d0333\tlabel\t_free"));
    try std.testing.expectError(error.BadName, parseLine("004d0333\tfunction\t"));
    try std.testing.expectError(error.BadName, parseLine("004d0333\tfunction\tfree block"));
    try std.testing.expectError(error.BadCharacter, parseLine("004d0333\tfunction\t_free\t\tFrees \u{2014} or not"));
}

test "the hand tables' rows are well formed" {
    for (hand) |table| {
        if (!std.mem.startsWith(u8, table.text, header ++ "\n")) {
            std.debug.print("{s}: the first line isn't the header\n", .{table.name});
            return error.TestUnexpectedResult;
        }
        const rows = std.mem.trimEnd(u8, table.text[header.len + 1 ..], "\n");
        var lines = std.mem.splitScalar(u8, rows, '\n');
        var number: usize = 2;
        while (lines.next()) |line| : (number += 1) {
            _ = handRow(line) catch |err| {
                std.debug.print("{s}:{d}: {s}\n", .{ table.name, number, @errorName(err) });
                return err;
            };
        }
    }
}

test "no address is named twice by the hand tables or by the generated rows" {
    const gpa = std.testing.allocator;
    var buffer: [256 << 10]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try names.write(&w);
    const generated = [_]Table{.{ .name = "ghidragen names", .text = w.buffered() }};

    for ([_][]const Table{ &generated, &hand }) |tables| {
        var seen: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        defer seen.deinit(gpa);
        for (tables) |table| {
            var lines = std.mem.splitScalar(u8, table.text, '\n');
            while (lines.next()) |line| {
                const row = try parseLine(line) orelse continue;
                const entry = try seen.getOrPut(gpa, row.address);
                if (entry.found_existing) {
                    std.debug.print("{x:0>8} is named in {s} and in {s}\n", .{ row.address, entry.value_ptr.*, table.name });
                    return error.TestUnexpectedResult;
                }
                entry.value_ptr.* = table.name;
            }
        }
    }
}

test "the scripts' hooks on functions take their functions' names" {
    const hooks = @import("openreliant").engine.hooks;
    var buffer: [256 << 10]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try names.write(&w);
    const tables = [_]Table{ hand[1], .{ .name = "ghidragen names", .text = w.buffered() } };
    inline for (comptime std.enums.values(hooks.Hook)) |hook| {
        const declared = comptime hooks.declaration(hook);
        if (declared.address) |address| {
            // The hand table's row for the address, which Ghidra applies last, else the generated
            // one; every hook's function has one.
            const named = for (tables) |table| {
                var lines = std.mem.splitScalar(u8, table.text, '\n');
                const found = while (lines.next()) |line| {
                    const row = try parseLine(line) orelse continue;
                    if (row.address == address) break row.name;
                } else null;
                if (found) |name| break name;
            } else null;
            if (named == null or !std.mem.eql(u8, named.?, @tagName(hook))) {
                std.debug.print("the hook {s} is on {x:0>8}, which the names tables call {s}\n", .{ @tagName(hook), address, named orelse "nothing" });
                return error.TestUnexpectedResult;
            }
        }
    }
}
