//! Mission source identity and references (#608). Symbol tables work with the existing format
//! records without copying their fields or keeping a separate list of record kinds.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Whether `id` matches the source grammar `[A-Za-z_][A-Za-z0-9_-]*`.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or !(std.ascii.isAlphabetic(id[0]) or id[0] == '_')) return false;
    for (id[1..]) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '-')) return false;
    }
    return true;
}

/// A source reference to a collection of `Record`. Different record types have different
/// reference types. The caller selects the table, including the script bank where applicable.
pub fn Reference(comptime Record: type) type {
    return struct {
        pub const RecordType = Record;
        id: []const u8,
    };
}

/// One source collection. Its record type defines its reference type; its order defines indices.
/// Build one table per collection or script bank. Binary limits belong to the lowering code,
/// not this table: an index here is a `usize`, never a truncated binary field.
pub fn Symbols(comptime Record: type) type {
    return struct {
        const Self = @This();
        pub const Ref = Reference(Record);
        pub const Entry = struct {
            id: []const u8,
            record: Record,
        };
        pub const InitError = Allocator.Error || error{ InvalidId, DuplicateId };
        pub const ResolveError = error{ InvalidId, MissingId };

        entries: []const Entry,
        indices: std.StringHashMapUnmanaged(usize) = .empty,

        /// Borrows immutable entries and ID bytes until `deinit`. Rebuild the table after changing
        /// IDs or collection order. Display names and original object IDs are never inspected.
        pub fn init(gpa: Allocator, entries: []const Entry) InitError!Self {
            var table: Self = .{ .entries = entries };
            errdefer table.deinit(gpa);
            for (entries, 0..) |entry, index| {
                if (!validId(entry.id)) return error.InvalidId;
                const slot = try table.indices.getOrPut(gpa, entry.id);
                if (slot.found_existing) return error.DuplicateId;
                slot.value_ptr.* = index;
            }
            return table;
        }

        pub fn deinit(table: *Self, gpa: Allocator) void {
            table.indices.deinit(gpa);
            table.* = undefined;
        }

        /// Resolves only in this collection. An invalid reference is distinguished from a valid
        /// ID that is absent, so a source reader can report the appropriate diagnostic.
        pub fn indexOf(table: Self, reference: Ref) ResolveError!usize {
            if (!validId(reference.id)) return error.InvalidId;
            return table.indices.get(reference.id) orelse error.MissingId;
        }

        pub fn resolve(table: Self, reference: Ref) ResolveError!*const Record {
            return &table.entries[try table.indexOf(reference)].record;
        }
    };
}

test validId {
    for ([_][]const u8{ "player", "_start", "Alpha_2-escort" }) |id| try std.testing.expect(validId(id));
    for ([_][]const u8{ "", "2player", "-player", "A B", "A.B", "A\x00B", "é" }) |id| try std.testing.expect(!validId(id));
    // Check every byte at both positions, including non-ASCII bytes and control characters.
    for (0..256) |value| {
        const char: u8 = @intCast(value);
        const letter = (char >= 'A' and char <= 'Z') or (char >= 'a' and char <= 'z');
        const digit = char >= '0' and char <= '9';
        try std.testing.expectEqual(letter or char == '_', validId(&.{char}));
        try std.testing.expectEqual(letter or digit or char == '_' or char == '-', validId(&.{ 'a', char }));
    }
}

test "source IDs resolve format records independently of display names and binary IDs" {
    const dte = @import("../dte.zig");
    const Ships = Symbols(dte.Ship);
    const Groups = Symbols(dte.FlightGroup);
    const gpa = std.testing.allocator;
    const entries = [_]Ships.Entry{
        .{ .id = "player", .record = dte.testing.ship(42, 0, 0) },
        .{ .id = "escort", .record = dte.testing.ship(7, 0, 60000) },
    };
    var ships = try Ships.init(gpa, &entries);
    defer ships.deinit(gpa);
    const group_entries = [_]Groups.Entry{.{ .id = "player", .record = dte.testing.flightGroup(91, .player) }};
    var groups = try Groups.init(gpa, &group_entries);
    defer groups.deinit(gpa);

    // Both ships have the same name offset. The same source ID can exist in another collection.
    try std.testing.expectEqual(entries[0].record.name, entries[1].record.name);
    try std.testing.expectEqual(42, (try ships.resolve(.{ .id = "player" })).object_id);
    try std.testing.expectEqual(91, (try groups.resolve(.{ .id = "player" })).object_id);
    // Mod content need not have a named base-game type. Identity keeps its numeric type intact.
    try std.testing.expectEqual(60000, (try ships.resolve(.{ .id = "escort" })).kind);
    try std.testing.expect(Ships.Ref != Groups.Ref);
    try std.testing.expectError(error.MissingId, groups.indexOf(.{ .id = "escort" }));

    // Reordering and renaming display names changes neither identity nor the original object ID.
    var reordered = [_]Ships.Entry{ entries[1], entries[0] };
    reordered[1].record.name = 123;
    var rebuilt = try Ships.init(gpa, &reordered);
    defer rebuilt.deinit(gpa);
    try std.testing.expectEqual(0, try ships.indexOf(.{ .id = "player" }));
    try std.testing.expectEqual(1, try rebuilt.indexOf(.{ .id = "player" }));
    try std.testing.expectEqual(42, (try rebuilt.resolve(.{ .id = "player" })).object_id);
    try std.testing.expectEqual(123, (try rebuilt.resolve(.{ .id = "player" })).name);
}

test "symbol errors and allocation failures release the index" {
    const Table = Symbols(u32);
    const gpa = std.testing.allocator;
    const entries = [_]Table.Entry{ .{ .id = "one", .record = 1 }, .{ .id = "two", .record = 2 } };
    var table = try Table.init(gpa, &entries);
    defer table.deinit(gpa);
    try std.testing.expectError(error.InvalidId, table.indexOf(.{ .id = "bad.id" }));
    try std.testing.expectError(error.MissingId, table.resolve(.{ .id = "absent" }));
    const duplicate = [_]Table.Entry{ entries[0], entries[0] };
    try std.testing.expectError(error.DuplicateId, Table.init(gpa, &duplicate));
    const invalid = [_]Table.Entry{ entries[0], .{ .id = "bad.id", .record = 0 } };
    try std.testing.expectError(error.InvalidId, Table.init(gpa, &invalid));
    // Grow through several map allocations so failures also exercise cleanup of an existing map.
    var many: [300]Table.Entry = undefined;
    var ids: [many.len][16]u8 = undefined;
    for (&many, &ids, 0..) |*entry, *id, index| entry.* = .{
        .id = try std.fmt.bufPrint(id, "record_{d}", .{index}),
        .record = @intCast(index),
    };
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: Allocator, records: []const Table.Entry) !void {
            var made = try Table.init(allocator, records);
            defer made.deinit(allocator);
            try std.testing.expectEqual(299, try made.indexOf(.{ .id = "record_299" }));
            try std.testing.expectError(error.MissingId, made.indexOf(.{ .id = "Record_299" }));
        }
    }.run, .{&many});
    var empty = try Table.init(gpa, &.{});
    defer empty.deinit(gpa);
    try std.testing.expectError(error.MissingId, empty.indexOf(.{ .id = "one" }));
}

test "new record types and independent script banks use the same symbol table" {
    const ExtendedRecord = struct { payload: u64 };
    const Table = Symbols(ExtendedRecord);
    const gpa = std.testing.allocator;
    const first = [_]Table.Entry{.{ .id = "start", .record = .{ .payload = 11 } }};
    const second = [_]Table.Entry{.{ .id = "start", .record = .{ .payload = 22 } }};
    var bank_a = try Table.init(gpa, &first);
    defer bank_a.deinit(gpa);
    var bank_b = try Table.init(gpa, &second);
    defer bank_b.deinit(gpa);
    try std.testing.expectEqual(11, (try bank_a.resolve(.{ .id = "start" })).payload);
    try std.testing.expectEqual(22, (try bank_b.resolve(.{ .id = "start" })).payload);
}
