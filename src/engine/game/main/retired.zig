//! OpenReliant's: what the game lets go of while a drawn frame may still read it, held until the
//! next drawn frame begins. A drawn frame's copies share with the game what the game doesn't change
//! once it has made it, such as the radio film's bytes (`main.Drawn`). With the game frames running
//! beside drawing, the game could let such memory go while a frame still reads it, so it hands it
//! here instead (`Retired.free`, `Retired.destroy`, `Retired.drop`), and the main thread lets go of
//! it as the next drawn frame begins, once the frame before is done (`Retired.release`). Where
//! nothing draws, it goes at once.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Retired = struct {
    /// What its list of held memory is made in.
    gpa: Allocator,
    held: std.ArrayList(Held) = .empty,

    /// Memory held, and what lets it go.
    const Held = union(enum) {
        memory: struct { bytes: []u8, alignment: Alignment, gpa: Allocator },
        record: struct { record: *anyopaque, destroy: *const fn (*anyopaque, Allocator) void, gpa: Allocator },
    };

    pub fn deinit(retired: *Retired) void {
        retired.release();
        retired.held.deinit(retired.gpa);
    }

    /// Lets go of everything held, as a drawn frame begins: the frame before, the last that could
    /// read it, is done.
    pub fn release(retired: *Retired) void {
        for (retired.held.items) |held| switch (held) {
            .memory => |memory| memory.gpa.rawFree(memory.bytes, memory.alignment, @returnAddress()),
            .record => |record| record.destroy(record.record, record.gpa),
        };
        retired.held.clearRetainingCapacity();
    }

    /// Lets go of `memory`, a slice made in `gpa`, once no drawn frame can read it: as the next
    /// drawn frame begins, or at once where nothing draws (`retired` is null) or the list can't
    /// grow to hold it.
    pub fn free(retired: ?*Retired, gpa: Allocator, memory: anytype) void {
        const info = @typeInfo(@TypeOf(memory)).pointer;
        const bytes: []u8 = @ptrCast(@constCast(memory));
        if (bytes.len == 0) return;
        const kept = retired orelse return gpa.free(memory);
        const alignment: Alignment = .fromByteUnits(info.attrs.@"align" orelse @alignOf(info.child));
        kept.held.append(kept.gpa, .{ .memory = .{ .bytes = bytes, .alignment = alignment, .gpa = gpa } }) catch gpa.free(memory);
    }

    /// Lets go of `record` with its own `destroy`, which frees it from `gpa`, once no drawn frame
    /// can read it, as `free` does.
    pub fn destroy(retired: ?*Retired, gpa: Allocator, record: anytype) void {
        const T = @typeInfo(@TypeOf(record)).pointer.child;
        const kept = retired orelse return record.destroy(gpa);
        const letGo = struct {
            fn letGo(held: *anyopaque, allocator: Allocator) void {
                const typed: *T = @ptrCast(@alignCast(held));
                typed.destroy(allocator);
            }
        }.letGo;
        kept.held.append(kept.gpa, .{ .record = .{ .record = record, .destroy = letGo, .gpa = gpa } }) catch record.destroy(gpa);
    }

    /// Lets go of what `value` holds with its own `deinit`, which frees it from `gpa`, once no
    /// drawn frame can read it, as `free` does. Until then the value waits in a box of its own,
    /// made in `gpa`.
    pub fn drop(retired: ?*Retired, gpa: Allocator, value: anytype) void {
        const Box = struct {
            value: @TypeOf(value),

            fn destroy(box: *@This(), allocator: Allocator) void {
                box.value.deinit(allocator);
                allocator.destroy(box);
            }
        };
        const kept = retired orelse return dropAtOnce(gpa, value);
        const box = gpa.create(Box) catch return dropAtOnce(gpa, value);
        box.* = .{ .value = value };
        destroy(kept, gpa, box);
    }

    fn dropAtOnce(gpa: Allocator, value: anytype) void {
        var held = value;
        held.deinit(gpa);
    }
};

test Retired {
    const gpa = std.testing.allocator;
    var retired: Retired = .{ .gpa = gpa };
    defer retired.deinit();
    const Record = struct {
        value: u32,

        fn destroy(record: *@This(), allocator: Allocator) void {
            allocator.destroy(record);
        }
    };
    const Value = struct {
        mesh: []u32,

        fn deinit(value: *@This(), allocator: Allocator) void {
            allocator.free(value.mesh);
        }
    };

    // What the game lets go of stays as it was until the next drawn frame begins, then goes.
    const film = try gpa.dupe(u16, &.{ 1, 2, 3 });
    Retired.free(&retired, gpa, film);
    const record = try gpa.create(Record);
    record.value = 7;
    Retired.destroy(&retired, gpa, record);
    const mesh = try gpa.dupe(u32, &.{ 4, 5 });
    Retired.drop(&retired, gpa, Value{ .mesh = mesh });
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, film);
    try std.testing.expectEqual(7, record.value);
    try std.testing.expectEqualSlices(u32, &.{ 4, 5 }, mesh);
    retired.release();
    try std.testing.expectEqual(0, retired.held.items.len);

    // Where nothing draws, it goes at once.
    Retired.free(null, gpa, try gpa.dupe(u8, "film"));
    Retired.destroy(null, gpa, try gpa.create(Record));
    Retired.drop(null, gpa, Value{ .mesh = try gpa.dupe(u32, &.{6}) });
}
