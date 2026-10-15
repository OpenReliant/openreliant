//! OpenReliant's: compares two copies of a record field by field, for the twin check
//! (`openreliant --twin`), and names each field that differs by its path, such as
//! `slots[14].object.root.next_position.x`.
//!
//! Numbers, booleans and enums are compared by value, floats by their bits, packed structs field by
//! field, optionals and tagged unions by what they hold, and untagged unions by their bytes.
//! Pointers and slices are left out: what they point at is compared where the caller names it.

const std = @import("std");

/// The differences between two copies, written to `writer` as they are found, `most` of them; the
/// rest are counted.
pub const Differences = struct {
    writer: *std.Io.Writer,
    most: usize = 10,
    found: usize = 0,
    /// The fields left out, each named by the end of its type's name and its own, such as
    /// `GameObject.sound_voice`.
    skip: []const []const u8 = &.{},
    /// Where the comparison stands, which the caller can lengthen for the copies it walks itself.
    path: Path = .{},

    pub const Segment = Path.Segment;

    /// Compares `a` and `b`, two pointers to copies of the same type, under the name `name`.
    pub fn compare(diffs: *Differences, name: []const u8, a: anytype, b: @TypeOf(a)) void {
        diffs.path.push(.{ .field = name });
        defer diffs.path.pop();
        diffs.walk(a, b);
    }

    fn skips(diffs: *const Differences, qualified: []const u8) bool {
        for (diffs.skip) |left_out| if (std.mem.endsWith(u8, qualified, left_out)) return true;
        return false;
    }

    /// Compares `a` and `b`, two pointers to copies of the same type, where the path stands.
    pub fn walk(diffs: *Differences, a: anytype, b: @TypeOf(a)) void {
        const T = @typeInfo(@TypeOf(a)).pointer.child;
        switch (@typeInfo(T)) {
            .bool, .int, .@"enum" => if (a.* != b.*) diffs.differ(a.*, b.*),
            .float => |float| {
                const Bits = @Int(.unsigned, float.bits);
                if (@as(Bits, @bitCast(a.*)) != @as(Bits, @bitCast(b.*))) diffs.differ(a.*, b.*);
            },
            .vector => |vector| {
                if (comptime !leaf(vector.child)) return;
                const x: [vector.len]vector.child = a.*;
                const y: [vector.len]vector.child = b.*;
                diffs.walk(&x, &y);
            },
            .array => |array| {
                if (comptime skipped(array.child)) return;
                for (a, b, 0..) |*x, *y, index| {
                    diffs.path.push(.{ .index = index });
                    defer diffs.path.pop();
                    diffs.walk(x, y);
                }
            },
            .@"struct" => |info| inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (comptime skipped(Field) or attrs.@"comptime") continue;
                if (!diffs.skips(@typeName(T) ++ "." ++ name)) {
                    diffs.path.push(.{ .field = name });
                    defer diffs.path.pop();
                    if (info.layout == .@"packed") {
                        // A packed struct's fields have no address of their own.
                        const x = @field(a.*, name);
                        const y = @field(b.*, name);
                        diffs.walk(&x, &y);
                    } else diffs.walk(&@field(a.*, name), &@field(b.*, name));
                }
            },
            .optional => |optional| {
                if (comptime skipped(optional.child)) return;
                if (a.* == null or b.* == null) {
                    if ((a.* == null) != (b.* == null)) diffs.differ(Presence.of(a.* != null), Presence.of(b.* != null));
                    return;
                }
                diffs.walk(&a.*.?, &b.*.?);
            },
            .@"union" => |info| if (info.tag_type) |Tag| {
                const tag_a: Tag = a.*;
                const tag_b: Tag = b.*;
                if (tag_a != tag_b) return diffs.differ(tag_a, tag_b);
                switch (a.*) {
                    inline else => |*x, tag| {
                        diffs.path.push(.{ .field = @tagName(tag) });
                        defer diffs.path.pop();
                        diffs.walk(x, &@field(b.*, @tagName(tag)));
                    },
                }
            } else if (!std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b))) diffs.differ(Presence.bytes, Presence.bytes),
            else => {},
        }
    }

    /// Writes the path of a field that differs, with its two values, while fewer than `most` have
    /// been written.
    fn differ(diffs: *Differences, x: anytype, y: @TypeOf(x)) void {
        diffs.found += 1;
        if (diffs.found > diffs.most) return;
        diffs.writer.print("  {f}: {any} against {any}\n", .{ diffs.path, x, y }) catch {};
    }
};

/// What an optional or an untagged union is shown as where it differs.
const Presence = enum {
    none,
    some,
    bytes,

    fn of(set: bool) Presence {
        return if (set) .some else .none;
    }
};

/// Whether a value of type `T` is compared as it is, a number, a boolean or an enum.
fn leaf(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        else => false,
    };
}

/// Whether a field of type `T` is left out: a pointer or a slice, or what holds nothing to
/// compare.
fn skipped(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .@"fn", .@"opaque", .type, .void, .null, .undefined, .noreturn, .comptime_int, .comptime_float, .enum_literal, .error_set, .error_union, .frame, .@"anyframe" => true,
        .optional => |optional| skipped(optional.child),
        else => false,
    };
}

/// Where a field stands within the copies compared, such as `slots[14].object.flags.hidden`.
pub const Path = struct {
    segments: [max_depth]Segment = undefined,
    depth: usize = 0,

    /// The deepest path written out in full; deeper segments are walked but left out of it.
    const max_depth = 24;

    pub const Segment = union(enum) {
        field: []const u8,
        index: usize,
    };

    pub fn push(path: *Path, segment: Segment) void {
        if (path.depth < max_depth) path.segments[path.depth] = segment;
        path.depth += 1;
    }

    pub fn pop(path: *Path) void {
        path.depth -= 1;
    }

    pub fn format(path: Path, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (path.segments[0..@min(path.depth, max_depth)], 0..) |segment, at| switch (segment) {
            .field => |name| try writer.print("{s}{s}", .{ if (at > 0) "." else "", name }),
            .index => |index| try writer.print("[{d}]", .{index}),
        };
    }
};

test Differences {
    const Flags = packed struct(u8) { a: bool = false, b: bool = false, _rest: u6 = 0 };
    const Kind = enum(u8) { ship, gun, _ };
    const Inner = struct { speed: f32 = 0, flags: Flags = .{}, at: @Vector(3, f32) = @splat(0) };
    const Record = struct {
        count: u16 = 0,
        kind: Kind = .ship,
        inner: [2]Inner = @splat(.{}),
        target: ?u16 = null,
        order: union(enum) { idle, fly: struct { speed: f32 } } = .idle,
        owner: ?*u8 = null,
        name: []const u8 = "",
    };
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var diffs: Differences = .{ .writer = &writer };

    // Copies alike, pointers and slices aside, have no differences.
    var byte: u8 = 0;
    const a: Record = .{ .owner = &byte, .name = "a" };
    var b: Record = .{ .name = "b" };
    diffs.compare("record", &a, &b);
    try std.testing.expectEqual(0, diffs.found);

    // Each field that differs is named by its path, with both values.
    b.count = 3;
    b.inner[1].flags.b = true;
    b.inner[0].at[2] = 1.5;
    b.target = 7;
    b.order = .{ .fly = .{ .speed = 2 } };
    diffs.compare("record", &a, &b);
    try std.testing.expectEqual(5, diffs.found);
    try std.testing.expectEqualStrings(
        \\  record.count: 0 against 3
        \\  record.inner[0].at[2]: 0 against 1.5
        \\  record.inner[1].flags.b: false against true
        \\  record.target: .none against .some
        \\  record.order: .idle against .fly
        \\
    , writer.buffered());

    // A field named in `skip` by its type and its name is left out.
    writer = .fixed(&buffer);
    diffs = .{ .writer = &writer, .skip = &.{ "Record.count", "Inner.flags" } };
    diffs.compare("record", &a, &b);
    try std.testing.expectEqual(3, diffs.found);

    // Past `most`, the differences are counted, not written; a float's sign counts.
    writer = .fixed(&buffer);
    diffs = .{ .writer = &writer, .most = 1 };
    var c = a;
    c.inner[0].speed = -0.0;
    c.kind = @fromBackingInt(9);
    diffs.compare("record", &a, &c);
    try std.testing.expectEqual(2, diffs.found);
    try std.testing.expectEqualStrings("  record.kind: .ship against @fromBackingInt(9)\n", writer.buffered());
}
