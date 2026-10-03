//! Plain data kept outside Luau ([#498](https://github.com/OpenReliant/openreliant/issues/498)):
//! what scripts save with a game (`on_save`), their timers' data, and their storage sections. A
//! `Value` is plain data (`data.zig`) as a tree of Zig values, which either Luau state can read
//! back, and which is written to files in a binary form of its own (`encode`, `decode`).
//!
//! The form, little-endian: each value starts with its kind (`Kind`), a byte. A number is an `f64`,
//! a string its length as a `u32` and its bytes, a vector three `f32`s, a handle the object's slot
//! as a `u16` and its count of reuses as a `u32`, and a table its count of pairs as a `u32`, then
//! each pair's key and value. A handle is kept as it was, and comes back as a handle that isn't
//! valid, since saved games are made between missions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const luau = @import("luau.zig");
const State = luau.State;
const objects = @import("objects.zig");
const data = @import("data.zig");

/// The kinds of plain data, as the binary form starts each value.
pub const Kind = enum(u8) {
    nil = 0,
    false = 1,
    true = 2,
    number = 3,
    string = 4,
    vector = 5,
    handle = 6,
    table = 7,
    _,
};

/// Plain data, owned by the allocator that made it (`deinit`).
pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    vector: @Vector(3, f32),
    handle: objects.Handle,
    table: []const Pair,

    pub const Pair = struct { key: Value, value: Value };

    pub fn deinit(value: Value, gpa: Allocator) void {
        switch (value) {
            .string => |bytes| gpa.free(bytes),
            .table => |pairs| {
                for (pairs) |pair| {
                    pair.key.deinit(gpa);
                    pair.value.deinit(gpa);
                }
                gpa.free(pairs);
            },
            .nil, .boolean, .number, .vector, .handle => {},
        }
    }

    /// The value of the table's pair whose key is the string `key`; null for none, or where it
    /// isn't a table.
    pub fn field(value: Value, key: []const u8) ?Value {
        const pairs = switch (value) {
            .table => |pairs| pairs,
            else => return null,
        };
        for (pairs) |pair| switch (pair.key) {
            .string => |name| if (std.mem.eql(u8, name, key)) return pair.value,
            else => {},
        };
        return null;
    }
};

/// How deep a table may hold tables, as for events (`data.max_depth`).
const max_depth = data.max_depth;

/// How much stack copying one level takes.
const level_stack = 5;

/// The plain data at `at` of `state`, copied into `gpa`. Raises an error naming `label` for
/// anything that isn't plain data, or where memory runs out.
pub fn capture(state: *State, gpa: Allocator, at: i32, label: []const u8) Value {
    const index = state.absolute(at);
    // Everything is checked before anything is copied: Luau's errors skip Zig's defers, so the
    // copy itself only fails with a Zig error, which lets go of what it made.
    check(state, index, label, 0);
    return copy(state, gpa, index, 0) catch state.raise("{s}: out of memory", .{label});
}

/// Raises an error naming `label` where the value at `at` isn't plain data.
fn check(state: *State, at: i32, label: []const u8, depth: u32) void {
    if (!state.checkStack(level_stack)) state.raise("{s}: out of memory", .{label});
    switch (state.typeOf(at)) {
        .nil, .none, .boolean, .number, .vector, .string => {},
        .userdata => if (state.toUserdata(objects.Handle, at, objects.Handle.tag) == null)
            state.raise("{s}: only plain data can be kept, not {s}", .{ label, state.typeName(at) }),
        .table => {
            if (depth == max_depth) state.raise("{s}: tables nest more than {d} deep, or a table holds itself", .{ label, max_depth });
            state.pushNil();
            while (state.next(at)) {
                const top = state.top();
                check(state, top - 1, label, depth + 1);
                check(state, top, label, depth + 1);
                state.pop(1);
            }
        },
        else => state.raise("{s}: only plain data can be kept, not {s}", .{ label, state.typeName(at) }),
    }
}

/// The value at `at`, which `check` has passed, copied into `gpa`.
fn copy(state: *State, gpa: Allocator, at: i32, depth: u32) Allocator.Error!Value {
    return switch (state.typeOf(at)) {
        .boolean => .{ .boolean = state.toBoolean(at) },
        .number => .{ .number = state.toNumber(at).? },
        .vector => .{ .vector = state.toVector(at).? },
        .string => .{ .string = try gpa.dupe(u8, state.toString(at).?) },
        .userdata => .{ .handle = state.toUserdata(objects.Handle, at, objects.Handle.tag).?.* },
        .table => table: {
            var pairs: std.ArrayList(Value.Pair) = .empty;
            errdefer {
                for (pairs.items) |pair| {
                    pair.key.deinit(gpa);
                    pair.value.deinit(gpa);
                }
                pairs.deinit(gpa);
            }
            const base = state.top();
            errdefer state.setTop(base);
            state.pushNil();
            while (state.next(at)) {
                const top = state.top();
                const key = try copy(state, gpa, top - 1, depth + 1);
                errdefer key.deinit(gpa);
                const value = try copy(state, gpa, top, depth + 1);
                errdefer value.deinit(gpa);
                try pairs.append(gpa, .{ .key = key, .value = value });
                state.pop(1);
            }
            break :table .{ .table = try pairs.toOwnedSlice(gpa) };
        },
        else => .nil,
    };
}

/// Pushes `value` on `state`, as tables of its own.
pub fn push(state: *State, value: Value) void {
    if (!state.checkStack(level_stack)) state.raise("out of memory", .{});
    switch (value) {
        .nil => state.pushNil(),
        .boolean => |held| state.pushBoolean(held),
        .number => |number| state.pushNumber(number),
        .string => |bytes| state.pushString(bytes),
        .vector => |vector| state.pushVector(vector),
        .handle => |handle| objects.pushHandle(state, handle),
        .table => |pairs| {
            state.newTable(0, @intCast(@min(pairs.len, std.math.maxInt(u16))));
            const made = state.top();
            for (pairs) |pair| {
                if (pair.key == .nil) continue;
                push(state, pair.key);
                push(state, pair.value);
                state.rawSet(made);
            }
        },
    }
}

/// Writes `value` in the binary form.
pub fn encode(w: *Io.Writer, value: Value) Io.Writer.Error!void {
    switch (value) {
        .nil => try w.writeByte(@intFromEnum(Kind.nil)),
        .boolean => |held| try w.writeByte(@intFromEnum(if (held) Kind.true else Kind.false)),
        .number => |number| {
            try w.writeByte(@intFromEnum(Kind.number));
            try w.writeInt(u64, @bitCast(number), .little);
        },
        .string => |bytes| {
            try w.writeByte(@intFromEnum(Kind.string));
            try w.writeInt(u32, @intCast(bytes.len), .little);
            try w.writeAll(bytes);
        },
        .vector => |vector| {
            try w.writeByte(@intFromEnum(Kind.vector));
            const axes: [3]f32 = vector;
            for (axes) |axis| try w.writeInt(u32, @bitCast(axis), .little);
        },
        .handle => |handle| {
            try w.writeByte(@intFromEnum(Kind.handle));
            try w.writeInt(u16, handle.slot, .little);
            try w.writeInt(u32, handle.count, .little);
        },
        .table => |pairs| {
            try w.writeByte(@intFromEnum(Kind.table));
            try w.writeInt(u32, @intCast(pairs.len), .little);
            for (pairs) |pair| {
                try encode(w, pair.key);
                try encode(w, pair.value);
            }
        },
    }
}

pub const DecodeError = error{ Damaged, OutOfMemory };

/// Reads a value in the binary form from `r`, made in `gpa`.
pub fn decode(r: *Io.Reader, gpa: Allocator) DecodeError!Value {
    return decodeAt(r, gpa, 0);
}

fn decodeAt(r: *Io.Reader, gpa: Allocator, depth: u32) DecodeError!Value {
    const kind: Kind = @enumFromInt(r.takeByte() catch return error.Damaged);
    return switch (kind) {
        .nil => .nil,
        .false => .{ .boolean = false },
        .true => .{ .boolean = true },
        .number => .{ .number = @bitCast(r.takeInt(u64, .little) catch return error.Damaged) },
        .string => .{ .string = string: {
            const len = r.takeInt(u32, .little) catch return error.Damaged;
            const bytes = r.take(len) catch return error.Damaged;
            break :string try gpa.dupe(u8, bytes);
        } },
        .vector => vector: {
            var axes: [3]f32 = undefined;
            for (&axes) |*axis| axis.* = @bitCast(r.takeInt(u32, .little) catch return error.Damaged);
            break :vector .{ .vector = axes };
        },
        .handle => .{ .handle = .{
            .slot = r.takeInt(u16, .little) catch return error.Damaged,
            .count = r.takeInt(u32, .little) catch return error.Damaged,
        } },
        .table => table: {
            if (depth == max_depth) return error.Damaged;
            const count = r.takeInt(u32, .little) catch return error.Damaged;
            var pairs: std.ArrayList(Value.Pair) = .empty;
            errdefer {
                for (pairs.items) |pair| {
                    pair.key.deinit(gpa);
                    pair.value.deinit(gpa);
                }
                pairs.deinit(gpa);
            }
            for (0..count) |_| {
                const key = try decodeAt(r, gpa, depth + 1);
                errdefer key.deinit(gpa);
                const value = try decodeAt(r, gpa, depth + 1);
                errdefer value.deinit(gpa);
                try pairs.append(gpa, .{ .key = key, .value = value });
            }
            break :table .{ .table = try pairs.toOwnedSlice(gpa) };
        },
        _ => error.Damaged,
    };
}

test "plain data goes to a file and back" {
    const gpa = std.testing.allocator;
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    state.sandbox();
    const thread = state.newSandboxedThread();
    const bind = @import("bind.zig");
    try bind.testing.runSource(thread,
        \\kept = { name = "wing", count = 3, at = vector.create(1, 2, 3), list = { true, false, "a" } }
    );
    _ = thread.getGlobal("kept");
    const value = capture(thread, gpa, -1, "kept");
    defer value.deinit(gpa);
    thread.pop(1);
    try std.testing.expectEqual(3, value.field("count").?.number);

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try encode(&buffer.writer, value);
    var reader: std.Io.Reader = .fixed(buffer.written());
    const back = try decode(&reader, gpa);
    defer back.deinit(gpa);
    push(thread, back);
    thread.setGlobal("back");
    try bind.testing.runSource(thread,
        \\assert(back ~= kept and back.name == "wing" and back.count == 3)
        \\assert(back.at == vector.create(1, 2, 3) and back.list[1] == true and back.list[2] == false and back.list[3] == "a")
    );
    // A damaged form is an error, not a crash.
    var cut: std.Io.Reader = .fixed(buffer.written()[0 .. buffer.written().len - 2]);
    try std.testing.expectError(error.Damaged, decode(&cut, gpa));
    var unknown: std.Io.Reader = .fixed(&.{0xEE});
    try std.testing.expectError(error.Damaged, decode(&unknown, gpa));
}

test "capture refuses what isn't plain data, and lets go of what it copied" {
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    state.pushFunction(luau.wrap(struct {
        fn run(called: *State) i32 {
            const value = capture(called, std.testing.allocator, 1, "kept");
            value.deinit(std.testing.allocator);
            return 0;
        }
    }.run), "keep");
    state.setGlobal("keep");
    state.sandbox();
    const thread = state.newSandboxedThread();
    const bind = @import("bind.zig");
    try bind.testing.runSource(thread, "keep({ a = 'x', b = { 1, 2 } })");
    try bind.testing.expectSourceError(thread, "keep({ a = 'x', b = { 1, print } })", "only plain data");
    try bind.testing.expectSourceError(thread, "local t = {}; t.t = t; keep(t)", "holds itself");
}
