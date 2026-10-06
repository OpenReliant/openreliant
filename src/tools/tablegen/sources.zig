//! Maps the payload's code to the source files it was compiled from.
//!
//! A source file that uses the assertion macro holds its own path as a string, and each function
//! that asserts refers to it. The linker lays out each object file's code in one run, and its data
//! in another, both in the same order: so the path strings put the files in order and place the
//! functions that name them. Other strings extend that. The compiler merges identical literals into
//! the data of the first file, in link order, to use one, so a literal bounds from below the file of
//! every function that uses it, and gives the file of a function that is its only user. A function
//! between two functions of one file is that file's. Strings placed that way place further ones
//! lying between two of one file, until nothing changes.
//!
//! What no string places lies between its neighbours: the end of one file, the start of the next,
//! or a file between them whose path the binary does not hold.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");

const image = @import("image.zig");
const testing = @import("testing.zig");
const x86 = @import("x86.zig");

/// A function of the listing: its entry, the end of its last instruction, and the addresses its
/// operands name.
pub const Function = struct {
    address: u32,
    end: u32,
    references: []const u32,
};

/// A source file: the path its data holds, where, and the code known to be its own.
pub const File = struct {
    path: []const u8,
    path_string: u32,
    code: ?Range,
};

pub const Range = struct {
    start: u32,
    end: u32,
};

pub const Error = error{ NoPaths, BadListing };

/// Reads the functions of an `ExportProgram.java` disassembly listing, in address order.
pub fn functions(arena: std.mem.Allocator, listing: []const u8) (Error || std.mem.Allocator.Error)![]const Function {
    var all: std.ArrayList(Function) = .empty;
    var references: std.ArrayList(u32) = .empty;
    var current: ?Function = null;

    var lines: x86.Lines = .init(listing);
    while (lines.next() catch return error.BadListing) |line| switch (line) {
        .banner => |banner| {
            if (current) |*function| try finish(arena, &all, function, &references);
            current = .{ .address = banner.address, .end = banner.address, .references = &.{} };
        },
        .instruction => |encoded| {
            const function = &(current orelse continue);
            function.end = @max(function.end, encoded.address + @as(u32, @intCast(encoded.bytes.len / 2)));
            // Every number the operands spell, whatever it is: only those that are strings matter.
            const operands = encoded.text;
            var i: usize = 0;
            while (std.mem.findPos(u8, operands, i, "0x")) |start| {
                var end = start + 2;
                while (end < operands.len and std.ascii.isHex(operands[end])) end += 1;
                if (std.fmt.parseInt(u32, operands[start + 2 .. end], 16)) |value| {
                    try references.append(arena, value);
                } else |_| {}
                i = end;
            }
        },
        .other => {},
    };
    if (current) |*function| try finish(arena, &all, function, &references);
    std.mem.sort(Function, all.items, {}, struct {
        fn lessThan(_: void, a: Function, b: Function) bool {
            return a.address < b.address;
        }
    }.lessThan);
    return all.toOwnedSlice(arena);
}

fn finish(arena: std.mem.Allocator, all: *std.ArrayList(Function), function: *Function, references: *std.ArrayList(u32)) !void {
    std.mem.sort(u32, references.items, {}, std.sort.asc(u32));
    const unique = dedupe(references.items);
    function.references = try arena.dupe(u32, unique);
    references.clearRetainingCapacity();
    try all.append(arena, function.*);
}

fn dedupe(sorted: []u32) []u32 {
    if (sorted.len == 0) return sorted;
    var n: usize = 1;
    for (sorted[1..]) |value| {
        if (value != sorted[n - 1]) {
            sorted[n] = value;
            n += 1;
        }
    }
    return sorted[0..n];
}

/// The addresses of the strings in `ExportProgram.java`'s `strings.tsv`, sorted.
pub fn stringAddresses(arena: std.mem.Allocator, tsv: []const u8) std.mem.Allocator.Error![]const u32 {
    var addresses: std.ArrayList(u32) = .empty;
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
        const address = std.fmt.parseInt(u32, line[0..tab], 16) catch continue;
        try addresses.append(arena, address);
    }
    std.mem.sort(u32, addresses.items, {}, std.sort.asc(u32));
    return dedupe(addresses.items);
}

/// Whether `text` is the absolute path of a C or C++ source file, as `__FILE__` spells one.
pub fn isSourcePath(text: []const u8) bool {
    if (text.len < 4 or !std.ascii.isAlphabetic(text[0]) or text[1] != ':' or text[2] != '\\') return false;
    return std.ascii.endsWithIgnoreCase(text, ".cpp") or std.ascii.endsWithIgnoreCase(text, ".c");
}

/// A position among the files: file `k` is `2k + 1`, and `2k` is between file `k - 1` and file `k`.
const Position = u16;

const Anchor = struct { address: u32, position: Position };

/// A function of the listing, by index, that uses the string at `string`.
const Use = struct { string: u32, function: u32 };

/// Walks uses sorted by string, the users of one string at a time.
const Runs = struct {
    rest: []const Use,

    fn next(runs: *Runs) ?[]const Use {
        if (runs.rest.len == 0) return null;
        const string = runs.rest[0].string;
        var end: usize = 1;
        while (end < runs.rest.len and runs.rest[end].string == string) end += 1;
        defer runs.rest = runs.rest[end..];
        return runs.rest[0..end];
    }
};

/// The one function that uses a string, where the string is its alone: no other function uses
/// it, no word of the data points at it, and it is not a path.
fn privateUser(users: []const Use, pointed: []const u32, paths: []const Anchor) ?u32 {
    const string = users[0].string;
    if (users.len != 1 or contains(pointed, string) or positionOf(paths, string) != null) return null;
    return users[0].function;
}

/// Maps `code` to the source files whose paths the strings at `strings` hold.
pub fn read(
    arena: std.mem.Allocator,
    reader: image.Reader,
    code: []const Function,
    strings: []const u32,
) (Error || std.mem.Allocator.Error)![]const File {
    // Literals: strings the file holds. A buffer in the zero-filled data can look like an empty one.
    var literal_list: std.ArrayList(u32) = .empty;
    for (strings) |address| {
        const text = reader.string(address) catch continue;
        if (text.len != 0) try literal_list.append(arena, address);
    }
    const literals = literal_list.items;

    // The paths, one file for each, in the order of their first copy in the data.
    var files: std.ArrayList(File) = .empty;
    var paths: std.ArrayList(Anchor) = .empty;
    for (literals) |address| {
        const text = reader.string(address) catch continue;
        if (!isSourcePath(text)) continue;
        const index = for (files.items, 0..) |file, i| {
            if (std.ascii.eqlIgnoreCase(file.path, text)) break i;
        } else blk: {
            try files.append(arena, .{ .path = text, .path_string = address, .code = null });
            break :blk files.items.len - 1;
        };
        try paths.append(arena, .{ .address = address, .position = @intCast(2 * index + 1) });
    }
    if (files.items.len == 0) return error.NoPaths;
    const last: Position = @intCast(2 * files.items.len);

    // Who uses each string: functions, and pointers in the data.
    var uses: std.ArrayList(Use) = .empty;
    for (code, 0..) |function, index| {
        for (function.references) |address| {
            if (contains(literals, address)) try uses.append(arena, .{ .string = address, .function = @intCast(index) });
        }
    }
    std.mem.sort(Use, uses.items, {}, struct {
        fn lessThan(_: void, a: Use, b: Use) bool {
            return a.string < b.string or (a.string == b.string and a.function < b.function);
        }
    }.lessThan);
    const pointed = try pointedTo(arena, reader, literals);

    const lo = try arena.alloc(Position, code.len);
    const hi = try arena.alloc(Position, code.len);
    var known: std.ArrayList(Anchor) = .empty;
    try known.appendSlice(arena, paths.items);
    sortAnchors(known.items);

    while (true) {
        @memset(lo, 0);
        @memset(hi, last);
        var strings_used: Runs = .{ .rest = uses.items };
        while (strings_used.next()) |users| {
            const string = users[0].string;
            if (positionOf(paths.items, string)) |position| {
                for (users) |use| {
                    lo[use.function] = @max(lo[use.function], position);
                    hi[use.function] = @min(hi[use.function], position);
                }
            } else {
                const below, _ = around(known.items, string, last);
                for (users) |use| lo[use.function] = @max(lo[use.function], below);
            }
        }
        var floor: Position = 0;
        for (lo) |*bound| {
            floor = @max(floor, bound.*);
            bound.* = floor;
        }

        // A string's only user is in the file whose data holds it, unless that contradicts the
        // other strings: then it is shared after all, with a user the listing does not show.
        strings_used = .{ .rest = uses.items };
        while (strings_used.next()) |users| {
            const user = privateUser(users, pointed, paths.items) orelse continue;
            _, const above = around(known.items, users[0].string, last);
            if (above >= lo[user]) hi[user] = @min(hi[user], above);
        }
        var ceiling: Position = last;
        var index = hi.len;
        while (index > 0) {
            index -= 1;
            ceiling = @min(ceiling, hi[index]);
            hi[index] = ceiling;
        }

        // The strings of the functions now placed place others in turn.
        var next: std.ArrayList(Anchor) = .empty;
        try next.appendSlice(arena, paths.items);
        strings_used = .{ .rest = uses.items };
        while (strings_used.next()) |users| {
            const user = privateUser(users, pointed, paths.items) orelse continue;
            if (lo[user] == hi[user]) try next.append(arena, .{ .address = users[0].string, .position = lo[user] });
        }
        sortAnchors(next.items);
        keepOrdered(paths.items, &next);
        if (next.items.len == known.items.len) break;
        known = next;
    }

    for (code, lo, hi) |function, low, high| {
        if (low != high or low % 2 == 0) continue;
        const file = &files.items[(low - 1) / 2];
        if (file.code) |*range| {
            range.start = @min(range.start, function.address);
            range.end = @max(range.end, function.end);
        } else {
            file.code = .{ .start = function.address, .end = function.end };
        }
    }
    return files.toOwnedSlice(arena);
}

fn contains(sorted: []const u32, value: u32) bool {
    return std.sort.binarySearch(u32, sorted, value, struct {
        fn order(target: u32, item: u32) std.math.Order {
            return std.math.order(target, item);
        }
    }.order) != null;
}

fn sortAnchors(anchors: []Anchor) void {
    std.mem.sort(Anchor, anchors, {}, struct {
        fn lessThan(_: void, a: Anchor, b: Anchor) bool {
            return a.address < b.address;
        }
    }.lessThan);
}

/// Drops the derived anchors that break the order of the files: the data runs through the files in
/// link order, so positions rise with addresses. Paths are never dropped.
fn keepOrdered(paths: []const Anchor, anchors: *std.ArrayList(Anchor)) void {
    while (true) {
        const items = anchors.items;
        var bad: ?usize = null;
        var highest: Position = 0;
        for (items, 0..) |anchor, i| {
            if (anchor.position < highest) {
                // Blame whichever of the two is not a path; a later pass finds any other.
                bad = if (positionOf(paths, anchor.address) == null) i else for (items[0..i], 0..) |earlier, j| {
                    if (earlier.position > anchor.position and positionOf(paths, earlier.address) == null) break j;
                } else null;
                if (bad != null) break;
            }
            highest = @max(highest, anchor.position);
        }
        _ = anchors.orderedRemove(bad orelse return);
    }
}

fn positionOf(anchors: []const Anchor, address: u32) ?Position {
    for (anchors) |anchor| {
        if (anchor.address == address) return anchor.position;
    }
    return null;
}

/// The positions of the nearest known strings below and above `address`, or its own position.
fn around(sorted: []const Anchor, address: u32, last: Position) struct { Position, Position } {
    var below: Position = 0;
    for (sorted) |anchor| {
        if (anchor.address == address) return .{ anchor.position, anchor.position };
        if (anchor.address > address) return .{ below, anchor.position };
        below = anchor.position;
    }
    return .{ below, last };
}

/// The strings that some word of the data points at: those are used by a table, not only by code.
fn pointedTo(arena: std.mem.Allocator, reader: image.Reader, strings: []const u32) std.mem.Allocator.Error![]const u32 {
    var pointed: std.ArrayList(u32) = .empty;
    for (reader.image.sections) |*section| {
        if (section.characteristics.execute) continue;
        const start = section.raw_offset;
        const end = @min(@as(usize, start) + section.raw_size, reader.bytes.len);
        if (start >= end) continue;
        const data = reader.bytes[start..end];
        for (std.mem.bytesAsSlice(u32, data[0 .. data.len - data.len % @sizeOf(u32)])) |value| {
            if (contains(strings, value)) try pointed.append(arena, value);
        }
    }
    std.mem.sort(u32, pointed.items, {}, std.sort.asc(u32));
    return dedupe(pointed.items);
}

/// Writes the source files as Zig.
pub fn emit(w: *Io.Writer, first_function: u32, files: []const File) Io.Writer.Error!void {
    try w.writeAll(
        \\//! The payload's source files, in the order the linker laid them out, and the code each is known
        \\//! to hold. `docs/binary/sources.md` describes how they are found.
        \\//!
        \\//! Generated by `src/tools/tablegen` from the payload executable and its Ghidra export. Do not edit
        \\//! by hand; run `make source-map`.
        \\
        \\const std = @import("std");
        \\
        \\pub const Range = struct {
        \\    start: u32,
        \\    /// The end of the last instruction.
        \\    end: u32,
        \\};
        \\
        \\pub const File = struct {
        \\    /// The path the file's assertions name, as the binary spells it.
        \\    path: []const u8,
        \\    /// Where the file's data holds that path.
        \\    path_string: u32,
        \\    /// From the first function known to be the file's to the end of the last; null when no
        \\    /// function is.
        \\    code: ?Range,
        \\};
        \\
        \\
    );
    try w.print(
        \\/// The payload's first function, where its code starts.
        \\pub const first_function: u32 = 0x{X:0>8};
        \\
        \\/// Every file whose path the binary holds, in link order.
        \\pub const files = [_]File{{
        \\
    , .{first_function});
    for (files) |file| {
        try w.print("    .{{ .path = \"{f}\", .path_string = 0x{X:0>8}, .code = ", .{ std.zig.fmtString(file.path), file.path_string });
        if (file.code) |range| {
            try w.print(".{{ .start = 0x{X:0>8}, .end = 0x{X:0>8} }} }},\n", .{ range.start, range.end });
        } else {
            try w.writeAll("null },\n");
        }
    }
    try w.writeAll(
        \\};
        \\
        \\comptime {
        \\    @setEvalBranchQuota(10_000);
        \\    var data: u32 = 0;
        \\    var code: u32 = 0;
        \\    for (files) |file| {
        \\        if (file.path_string <= data) @compileError("files out of link order: " ++ file.path);
        \\        data = file.path_string;
        \\        if (file.code) |range| {
        \\            if (range.start < code or range.end <= range.start) @compileError("code out of order: " ++ file.path);
        \\            code = range.end;
        \\        }
        \\    }
        \\}
        \\
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
        \\
    );
}

test functions {
    const listing =
        \\; ==== FUN_00401010 @ 00401010 ====
        \\00401010  68c8055000               PUSH 0x5005c8
        \\00401015  c3                       RET
        \\
        \\; ==== FUN_00401000 @ 00401000 ====
        \\00401000  a100055000               MOV EAX,[0x00500500]
        \\00401005  e806000000               CALL 0x00401010
        \\0040100a  c3                       RET
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try functions(arena.allocator(), listing);
    try std.testing.expectEqual(2, parsed.len);
    try std.testing.expectEqual(0x401000, parsed[0].address);
    try std.testing.expectEqual(0x40100B, parsed[0].end);
    try std.testing.expectEqualSlices(u32, &.{ 0x401010, 0x500500 }, parsed[0].references);
    try std.testing.expectEqualSlices(u32, &.{0x5005C8}, parsed[1].references);
}

test isSourcePath {
    try std.testing.expect(isSourcePath("C:\\lancer\\game\\Ai.cpp"));
    try std.testing.expect(isSourcePath("C:\\lancer\\game\\hog_SND.CPP"));
    try std.testing.expect(!isSourcePath("interface\\frontend.spr"));
    try std.testing.expect(!isSourcePath("C:\\lancer\\game\\objects.h"));
}

test read {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var data: [0x200]u8 = @splat(0);
    const region: testing.Region = .{ .va = 0x500000, .bytes = &data };
    region.putString(0x500000, "C:\\src\\a.cpp");
    region.putString(0x500010, "early");
    region.putString(0x500020, "shared");
    region.putString(0x500080, "C:\\src\\a.cpp");
    region.putString(0x500090, "gamma");
    region.putString(0x5000A0, "beta");
    region.putString(0x500100, "C:\\src\\b.cpp");
    const reader = try testing.reader(std.testing.allocator, &.{region});
    defer testing.freeReader(std.testing.allocator, reader);

    const listing =
        \\; ==== a1 @ 00401000 ====
        \\00401000  68000050 PUSH 0x500000
        \\00401004  68200050 PUSH 0x500020
        \\00401008  68a00050 PUSH 0x5000a0
        \\; ==== a2 @ 00401010 ====
        \\00401010  68900050 PUSH 0x500090
        \\; ==== gap @ 00401020 ====
        \\00401020  c3 RET
        \\; ==== b1 @ 00401030 ====
        \\00401030  68000150 PUSH 0x500100
        \\00401034  68200050 PUSH 0x500020
        \\; ==== late @ 00401040 ====
        \\00401040  68100050 PUSH 0x500010
        \\
    ;
    const strings = [_]u32{ 0x500000, 0x500010, 0x500020, 0x500080, 0x500090, 0x5000A0, 0x500100 };
    const files = try read(arena, reader, try functions(arena, listing), &strings);

    try std.testing.expectEqual(2, files.len);
    try std.testing.expectEqualStrings("C:\\src\\a.cpp", files[0].path);
    try std.testing.expectEqual(0x500000, files[0].path_string);
    // a2's string lies between a.cpp's second path and a string of a1's, which places it once a1 is
    // placed. The gap between the files stays unplaced.
    try std.testing.expectEqual(Range{ .start = 0x401000, .end = 0x401014 }, files[0].code.?);
    // late's only string lies between a.cpp's two paths, but late follows b.cpp's code: the string
    // has another user the listing does not show, and late stays unplaced.
    try std.testing.expectEqual(Range{ .start = 0x401030, .end = 0x401038 }, files[1].code.?);
}

test emit {
    var buffer: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try emit(&w, 0x401000, &.{
        .{ .path = "C:\\lancer\\game\\Ai.cpp", .path_string = 0x4E0C50, .code = .{ .start = 0x401F30, .end = 0x40266D } },
        .{ .path = "C:\\lancer\\game\\videoreports.cpp", .path_string = 0x4EE7B8, .code = null },
    });
    const source = w.buffered();
    try testing.expectZig(source);
    try std.testing.expect(std.mem.find(u8, source, "pub const first_function: u32 = 0x00401000;") != null);
    try std.testing.expect(std.mem.find(u8, source, ".{ .path = \"C:\\\\lancer\\\\game\\\\Ai.cpp\", .path_string = 0x004E0C50, .code = .{ .start = 0x00401F30, .end = 0x0040266D } },") != null);
    try std.testing.expect(std.mem.find(u8, source, "videoreports.cpp\", .path_string = 0x004EE7B8, .code = null },") != null);
}
