//! The fixed tables the game keeps its effects in, as OpenReliant holds them. Not from any file of
//! the original: its tables find a slot for a new record in one of two ways, which these share.

const std = @import("std");

/// A table of `capacity` records where each new one takes the slot after the last, round the
/// first so many, in the place of whatever was there: the explosions' bits and pieces, and the
/// sparks.
pub fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        slots: [capacity]?T = @splat(null),
        /// The slot the next record takes.
        next: usize = 0,

        const Self = @This();
        pub const len = capacity;

        /// The slot the next record goes in, round the first `used`, which the caller lets go of
        /// and fills. A `used` of none, or more than there are, is taken as all of them.
        pub fn take(ring: *Self, used: usize) *?T {
            const round = if (used == 0 or used > capacity) capacity else used;
            const at = ring.next % round;
            ring.next = (at + 1) % round;
            return &ring.slots[at];
        }
    };
}

/// The first free slot of `slots`, or null where every one is taken: the fireballs and the
/// shockwaves.
pub fn firstFree(comptime T: type, slots: []?T) ?*?T {
    return &slots[firstFreeIndex(T, slots) orelse return null];
}

/// Where the first free slot of `slots` is, or null where every one is taken: the countermeasures,
/// and `Linked`'s.
pub fn firstFreeIndex(comptime T: type, slots: []const ?T) ?usize {
    for (slots, 0..) |slot, index| if (slot == null) return index;
    return null;
}

/// Where the first slot of `slots` that `free` finds free is, or null where every one is taken: the
/// tables whose records mark their slot taken themselves, with a flag of their own.
pub fn firstFreeBy(comptime T: type, slots: []const T, comptime free: fn (*const T) bool) ?usize {
    for (slots, 0..) |*slot, index| if (free(slot)) return index;
    return null;
}

test firstFreeBy {
    const Record = struct {
        live: bool,
        fn dead(record: *const @This()) bool {
            return !record.live;
        }
    };
    const records = [_]Record{ .{ .live = true }, .{ .live = false }, .{ .live = false } };
    try std.testing.expectEqual(1, firstFreeBy(Record, &records, Record.dead));
    try std.testing.expectEqual(null, firstFreeBy(Record, records[0..1], Record.dead));
}

/// A table of `capacity` records, each new one in the first free slot, whose live records are also
/// linked newest first, through their own `newer` and `older`, in the order the game walks them:
/// the missiles and their trails. A record lets go of what it holds with its `release`.
pub fn Linked(comptime T: type, comptime capacity: usize) type {
    return struct {
        records: [capacity]?T = @splat(null),
        newest: ?Index = null,
        /// How often each slot has had its record removed, so that a handle to a record can tell
        /// whether the slot still holds it, as an object's handle does (`create.Objects.reuses`).
        /// OpenReliant's own: the game keeps no such count.
        reuses: [capacity]u32 = @splat(0),

        const Self = @This();
        pub const Index = std.math.IntFittingRange(0, capacity - 1);

        pub fn get(list: *Self, index: usize) ?*T {
            if (index >= capacity) return null;
            return if (list.records[index]) |*record| record else null;
        }

        pub fn full(list: *const Self) bool {
            return firstFreeIndex(T, &list.records) == null;
        }

        /// Puts `record` in the first free slot, at the head of the list; null where every slot is
        /// taken.
        pub fn add(list: *Self, record: T) ?Index {
            const at: Index = @intCast(firstFreeIndex(T, &list.records) orelse return null);
            list.records[at] = record;
            const added = &list.records[at].?;
            added.older = list.newest;
            added.newer = null;
            if (list.newest) |head| list.records[head].?.newer = at;
            list.newest = at;
            return at;
        }

        /// Takes the record at `index` out of the list, lets go of what it holds, and frees its
        /// slot.
        pub fn remove(list: *Self, gpa: std.mem.Allocator, index: Index) void {
            const record = &list.records[index].?;
            if (record.newer) |newer| list.records[newer].?.older = record.older else list.newest = record.older;
            if (record.older) |older| list.records[older].?.newer = record.newer;
            record.release(gpa);
            list.records[index] = null;
            list.reuses[index] +%= 1;
        }

        /// Every record let go of.
        pub fn reset(list: *Self, gpa: std.mem.Allocator) void {
            for (&list.records, &list.reuses) |*slot, *reused| {
                if (slot.*) |*record| {
                    record.release(gpa);
                    reused.* +%= 1;
                }
                slot.* = null;
            }
            list.newest = null;
        }

        pub fn walk(list: *const Self) Walk {
            return .{ .list = list, .at = list.newest };
        }

        /// Each live record's index, newest first. The walk takes the next before it hands one
        /// out, so a record removed on the way doesn't end the walk.
        pub const Walk = struct {
            list: *const Self,
            at: ?Index,

            pub fn next(w: *Walk) ?Index {
                const index = w.at orelse return null;
                w.at = if (w.list.records[index]) |record| record.older else null;
                return index;
            }
        };
    };
}

test Ring {
    var ring: Ring(u8, 4) = .{};
    // Round the first three, the fourth left alone.
    for (0..4) |n| ring.take(3).* = @intCast(n);
    try std.testing.expectEqual([4]?u8{ 3, 1, 2, null }, ring.slots);
    try std.testing.expectEqual(1, ring.next);
    // Round all of them once more are used.
    _ = ring.take(4);
    try std.testing.expectEqual(2, ring.next);
}

test firstFree {
    var slots: [3]?u8 = .{ 1, null, null };
    try std.testing.expectEqual(&slots[1], firstFree(u8, &slots).?);
    slots = .{ 1, 2, 3 };
    try std.testing.expectEqual(null, firstFree(u8, &slots));
}

test Linked {
    const Record = struct {
        value: u8,
        newer: ?u2 = null,
        older: ?u2 = null,
        fn release(record: *@This(), _: std.mem.Allocator) void {
            record.value = 0;
        }
    };
    var list: Linked(Record, 3) = .{};
    // Each takes the first free slot, the newest walked first.
    for ([_]u8{ 10, 20, 30 }) |value| _ = list.add(.{ .value = value }).?;
    try std.testing.expect(list.full());
    try std.testing.expectEqual(null, list.add(.{ .value = 40 }));
    list.remove(std.testing.allocator, 1);
    try std.testing.expectEqual(1, list.reuses[1]);
    try std.testing.expectEqual(1, list.add(.{ .value = 40 }).?);
    var walk = list.walk();
    var order: [3]u8 = undefined;
    var n: usize = 0;
    while (walk.next()) |index| : (n += 1) order[n] = list.get(index).?.value;
    try std.testing.expectEqualSlices(u8, &.{ 40, 30, 10 }, order[0..n]);
    // A reset counts a reuse of each slot that held a record.
    list.reset(std.testing.allocator);
    try std.testing.expectEqual(null, list.newest);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 1 }, &list.reuses);
}
