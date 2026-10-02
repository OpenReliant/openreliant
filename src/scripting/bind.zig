//! Exposes Zig values to scripts by reflecting over their declarations at compile time
//! ([#498](https://github.com/OpenReliant/openreliant/issues/498)).
//!
//! Numbers become Luau numbers, enums their tag names, and byte arrays strings. Structs and other
//! arrays become proxies: userdata that read and write the value in place. Struct fields use their
//! Zig names, except fields starting with an underscore, which are hidden because they hold unknown
//! or unused data. Array elements are indexed from 1. Writes are type-checked, and unknown field
//! names are errors, so that typos are reported.

const std = @import("std");
const luau = @import("luau.zig");
const State = luau.State;

/// Proxies for the types in `roots` and every struct and array inside them. The proxies use the
/// userdata tag `tag`, and Luau's `typeof` returns `name` for them.
pub fn Binding(comptime roots: []const type, comptime tag: luau.Tag, comptime name: [:0]const u8) type {
    return struct {
        /// Every type a proxy can stand for: the roots first, then the structs and arrays inside
        /// them.
        pub const kinds: []const type = gather(roots);

        /// One tag per entry of `kinds`, so that switching on a proxy's kind covers them all.
        const Kind = kind: {
            const Int = std.math.IntFittingRange(0, kinds.len - 1);
            var names: [kinds.len][]const u8 = undefined;
            for (&names, 0..) |*kind_name, at| kind_name.* = std.fmt.comptimePrint("{d}", .{at});
            break :kind @Enum(Int, .exhaustive, &names, &std.simd.iota(Int, kinds.len));
        };

        const Proxy = struct {
            address: *anyopaque,
            kind: Kind,
            writable: bool,

            fn of(state: *State, at: i32) *const Proxy {
                return state.toUserdata(Proxy, at, tag) orelse state.raise("expected a {s}", .{name});
            }
        };

        /// Registers the proxies' metatable.
        pub fn register(state: *State) void {
            state.newTable(0, 8);
            inline for (.{
                .{ "__index", luau.wrap(index) },
                .{ "__newindex", luau.wrap(newIndex) },
                .{ "__iter", luau.wrap(iterate) },
                .{ "__len", luau.wrap(length) },
                .{ "__eq", luau.wrap(equal) },
                .{ "__tostring", luau.wrap(describe) },
            }) |entry| {
                state.pushFunction(entry[1], entry[0]);
                state.rawSetField(-2, entry[0]);
            }
            state.pushString(name);
            state.rawSetField(-2, "__type");
            state.setReadonly(-1, true);
            state.setUserdataMetatable(tag);
        }

        /// Pushes a proxy for `value`. Scripts can change it only if `writable`.
        pub fn push(state: *State, comptime T: type, value: *T, writable: bool) void {
            const proxy = state.newUserdata(Proxy, tag);
            proxy.* = .{ .address = value, .kind = kindOf(T), .writable = writable };
        }

        /// Sets the fields of `value` from the table at `table`, checking each one as a single
        /// write would. Keys in `skipped` are ignored.
        pub fn assign(state: *State, comptime T: type, value: *T, table: i32, comptime skipped: []const []const u8) void {
            assignTable(state, T, value, state.absolute(table), skipped);
        }

        /// The value behind the proxy at `at`, or null if it isn't a proxy for a `T`.
        pub fn pointer(state: *State, comptime T: type, at: i32) ?*T {
            const proxy = state.toUserdata(Proxy, at, tag) orelse return null;
            if (proxy.kind != kindOf(T)) return null;
            return @ptrCast(@alignCast(proxy.address));
        }

        fn kindOf(comptime T: type) Kind {
            inline for (kinds, 0..) |kind, at| {
                if (kind == T) return @enumFromInt(at);
            }
            @compileError(@typeName(T) ++ " is not one of the binding's types");
        }

        /// `__index`: reads a field or an element.
        fn index(state: *State) i32 {
            const proxy = Proxy.of(state, 1);
            switch (proxy.kind) {
                inline else => |kind| {
                    const T = kinds[@intFromEnum(kind)];
                    pushKey(state, T, @ptrCast(@alignCast(proxy.address)), proxy.writable, 2);
                },
            }
            return 1;
        }

        /// `__newindex`: writes a field or an element.
        fn newIndex(state: *State) i32 {
            const proxy = Proxy.of(state, 1);
            if (!proxy.writable) state.raise("this {s} is read-only", .{name});
            switch (proxy.kind) {
                inline else => |kind| {
                    const T = kinds[@intFromEnum(kind)];
                    setKey(state, T, @ptrCast(@alignCast(proxy.address)), 2, 3);
                },
            }
            return 0;
        }

        /// `__iter`: iterates over the fields or elements in order.
        fn iterate(state: *State) i32 {
            state.pushFunction(luau.wrap(step), "next");
            state.pushCopy(1);
            state.pushNil();
            return 3;
        }

        /// Returns the key after the given one and its value, or nothing after the last.
        fn step(state: *State) i32 {
            const proxy = Proxy.of(state, 1);
            switch (proxy.kind) {
                inline else => |kind| {
                    const T = kinds[@intFromEnum(kind)];
                    return pushNext(state, T, @ptrCast(@alignCast(proxy.address)), proxy.writable);
                },
            }
        }

        /// `__len`: the number of elements of an array, or of fields of a struct.
        fn length(state: *State) i32 {
            const proxy = Proxy.of(state, 1);
            switch (proxy.kind) {
                inline else => |kind| {
                    const T = kinds[@intFromEnum(kind)];
                    const len = switch (@typeInfo(T)) {
                        .array => |array| array.len,
                        else => comptime fieldsOf(T).len,
                    };
                    state.pushNumber(@floatFromInt(len));
                },
            }
            return 1;
        }

        /// `__eq`: two proxies are equal if they point at the same value.
        fn equal(state: *State) i32 {
            const a = Proxy.of(state, 1);
            const b = Proxy.of(state, 2);
            state.pushBoolean(a.address == b.address and a.kind == b.kind);
            return 1;
        }

        /// `__tostring`: the value's type name.
        fn describe(state: *State) i32 {
            const proxy = Proxy.of(state, 1);
            switch (proxy.kind) {
                inline else => |kind| state.pushString(comptime noun(kinds[@intFromEnum(kind)])),
            }
            return 1;
        }

        fn pushKey(state: *State, comptime T: type, value: *T, writable: bool, key: i32) void {
            switch (@typeInfo(T)) {
                .@"struct" => {
                    const field_name = state.toString(key) orelse state.raise("{s}: expected a field name, got {s}", .{ comptime noun(T), state.typeName(key) });
                    inline for (comptime fieldsOf(T)) |field| {
                        if (std.mem.eql(u8, field_name, field.name)) return pushField(state, T, value, field, writable);
                    }
                    state.raise("{s} has no field '{s}'", .{ comptime noun(T), field_name });
                },
                .array => |array| {
                    const place = element(state, array.len, key);
                    pushValue(state, array.child, &value[place], writable);
                },
                else => comptime unreachable,
            }
        }

        fn setKey(state: *State, comptime T: type, value: *T, key: i32, given: i32) void {
            switch (@typeInfo(T)) {
                .@"struct" => {
                    const field_name = state.toString(key) orelse state.raise("{s}: expected a field name, got {s}", .{ comptime noun(T), state.typeName(key) });
                    inline for (comptime fieldsOf(T)) |field| {
                        if (std.mem.eql(u8, field_name, field.name)) return setField(state, T, value, field, given);
                    }
                    state.raise("{s} has no field '{s}'", .{ comptime noun(T), field_name });
                },
                .array => |array| {
                    const place = element(state, array.len, key);
                    setValue(state, array.child, &value[place], given, comptime noun(T));
                },
                else => comptime unreachable,
            }
        }

        fn pushNext(state: *State, comptime T: type, value: *T, writable: bool) i32 {
            switch (@typeInfo(T)) {
                .@"struct" => {
                    const fields = comptime fieldsOf(T);
                    // The field after the given one, or the first if none is given.
                    var after: usize = 0;
                    if (state.toString(2)) |previous| {
                        after = fields.len;
                        inline for (fields, 0..) |field, at| {
                            if (std.mem.eql(u8, previous, field.name)) after = at + 1;
                        }
                    }
                    inline for (fields, 0..) |field, at| {
                        if (after == at) {
                            state.pushString(field.name);
                            pushField(state, T, value, field, writable);
                            return 2;
                        }
                    }
                    return 0;
                },
                .array => |array| {
                    // The element after the given index, or the first if none is given.
                    const previous: usize = if (state.typeOf(2) == .nil) 0 else wholeIndex(state.toNumber(2) orelse return 0) orelse return 0;
                    if (previous >= array.len) return 0;
                    state.pushNumber(@floatFromInt(previous + 1));
                    pushValue(state, array.child, &value[previous], writable);
                    return 2;
                },
                else => comptime unreachable,
            }
        }

        /// Pushes `value`: a proxy for a struct or an array, the value itself otherwise.
        fn pushValue(state: *State, comptime T: type, value: *T, writable: bool) void {
            if (comptime isAggregate(T)) return push(state, T, value, writable);
            pushScalar(state, T, value.*);
        }

        /// Pushes a struct field. Scalar fields are read by value, because fields of packed
        /// structs can't be pointed at.
        fn pushField(state: *State, comptime T: type, value: *T, comptime field: std.builtin.Type.StructField, writable: bool) void {
            if (comptime isAggregate(field.type)) return push(state, field.type, &@field(value.*, field.name), writable);
            pushScalar(state, field.type, @field(value.*, field.name));
        }

        /// Sets a struct field from the value at `given`.
        fn setField(state: *State, comptime T: type, value: *T, comptime field: std.builtin.Type.StructField, given: i32) void {
            const label = comptime noun(T) ++ "." ++ field.name;
            if (comptime isAggregate(field.type)) return setValue(state, field.type, &@field(value.*, field.name), given, label);
            @field(value.*, field.name) = scalarOf(state, field.type, given, label);
        }

        /// Sets `value` from the value at `given`: from a table of fields for a struct or an array,
        /// or a checked scalar otherwise. `label` names the value in error messages.
        fn setValue(state: *State, comptime T: type, value: *T, given: i32, comptime label: []const u8) void {
            if (comptime isAggregate(T)) {
                if (state.typeOf(given) != .table) state.raise("{s}: expected a table, got {s}", .{ label, state.typeName(given) });
                return assignTable(state, T, value, state.absolute(given), &.{});
            }
            value.* = scalarOf(state, T, given, label);
        }

        fn assignTable(state: *State, comptime T: type, value: *T, table: i32, comptime skipped: []const []const u8) void {
            state.pushNil();
            while (state.next(table)) {
                defer state.pop(1);
                if (state.toString(-2)) |key| {
                    if (comptime skipped.len > 0) if (isSkipped(key, skipped)) continue;
                }
                setKey(state, T, value, -2, -1);
            }
        }

        fn isSkipped(key: []const u8, comptime skipped: []const []const u8) bool {
            inline for (skipped) |skip| {
                if (std.mem.eql(u8, key, skip)) return true;
            }
            return false;
        }
    };
}

/// Converts the key at `key`, a 1-based array index, into a 0-based one for an array of `len`.
fn element(state: *State, len: usize, key: i32) usize {
    const number = state.toNumber(key) orelse state.raise("expected an array index, got {s}", .{state.typeName(key)});
    const place = wholeIndex(number) orelse 0;
    if (place < 1 or place > len) state.raise("index {d} is out of range 1 to {d}", .{ number, len });
    return place - 1;
}

/// `number` as an index, or null if it isn't a whole number from 0 up.
pub fn wholeIndex(number: f64) ?usize {
    if (number != @floor(number) or number < 0 or number > max_index) return null;
    return @intFromFloat(number);
}

/// The largest index a script can give.
const max_index: f64 = std.math.maxInt(u32);

fn pushScalar(state: *State, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .float => state.pushNumber(value),
        .int => state.pushNumber(@floatFromInt(value)),
        .bool => state.pushBoolean(value),
        .@"enum" => if (std.enums.tagName(T, value)) |tag_name|
            state.pushString(tag_name)
        else
            state.pushNumber(@floatFromInt(@intFromEnum(value))),
        .array => state.pushString(std.mem.sliceTo(&value, 0)),
        else => @compileError("scripts can't read a " ++ @typeName(T)),
    }
}

/// Reads the value at `given` as a `T`, raising an error if it doesn't fit. `label` names the
/// value in error messages.
fn scalarOf(state: *State, comptime T: type, given: i32, comptime label: []const u8) T {
    switch (@typeInfo(T)) {
        .float => {
            const number = state.toNumber(given) orelse wrongType(state, label, "a number", given);
            const narrowed = std.math.lossyCast(T, number);
            if (!std.math.isFinite(narrowed)) state.raise("{s}: expected a finite number, got {d}", .{ label, number });
            return narrowed;
        },
        .int => {
            const number = state.toNumber(given) orelse wrongType(state, label, "a number", given);
            if (number != @floor(number) or number < std.math.minInt(T) or number > std.math.maxInt(T)) {
                state.raise("{s}: expected a whole number from {d} to {d}, got {d}", .{ label, std.math.minInt(T), std.math.maxInt(T), number });
            }
            return @intFromFloat(number);
        },
        .bool => {
            if (state.typeOf(given) != .boolean) wrongType(state, label, "a boolean", given);
            return state.toBoolean(given);
        },
        .@"enum" => |info| {
            if (state.toString(given)) |tag_name| {
                return std.meta.stringToEnum(T, tag_name) orelse state.raise("{s}: expected {s}, got '{s}'", .{ label, comptime choices(T), tag_name });
            }
            const number = state.toNumber(given) orelse wrongType(state, label, comptime choices(T), given);
            if (number == @floor(number) and number >= std.math.minInt(info.tag_type) and number <= std.math.maxInt(info.tag_type)) {
                const raw: info.tag_type = @intFromFloat(number);
                if (!info.is_exhaustive) return @enumFromInt(raw);
                inline for (comptime std.enums.values(T)) |named| {
                    if (@intFromEnum(named) == raw) return named;
                }
            }
            state.raise("{s}: expected {s}, got {d}", .{ label, comptime choices(T), number });
        },
        .array => |array| {
            const text = state.toString(given) orelse wrongType(state, label, "a string", given);
            if (text.len >= array.len) state.raise("{s}: expected at most {d} bytes, got {d}", .{ label, array.len - 1, text.len });
            var bytes: T = @splat(0);
            @memcpy(bytes[0..text.len], text);
            return bytes;
        },
        else => @compileError("scripts can't write a " ++ @typeName(T)),
    }
}

fn wrongType(state: *State, comptime label: []const u8, comptime expected: []const u8, given: i32) noreturn {
    state.raise("{s}: expected {s}, got {s}", .{ label, expected, state.typeName(given) });
}

/// The values an enum field accepts, for error messages: its tag names, and any number if the enum
/// is open.
fn choices(comptime T: type) []const u8 {
    comptime {
        var text: []const u8 = "";
        const values = std.enums.values(T);
        for (values, 0..) |value, at| {
            const separator = if (at == 0) "" else if (at == values.len - 1 and @typeInfo(T).@"enum".is_exhaustive) " or " else ", ";
            text = text ++ separator ++ "'" ++ @tagName(value) ++ "'";
        }
        return if (@typeInfo(T).@"enum".is_exhaustive) text else text ++ " or a number";
    }
}

/// The fields of `T` that scripts see: all except those starting with an underscore.
pub fn fieldsOf(comptime T: type) []const std.builtin.Type.StructField {
    comptime {
        var fields: []const std.builtin.Type.StructField = &.{};
        for (@typeInfo(T).@"struct".fields) |field| {
            if (field.name[0] != '_') fields = fields ++ .{field};
        }
        return fields;
    }
}

/// Whether scripts see `T` through a proxy: structs, and arrays of anything but bytes, which are
/// strings.
fn isAggregate(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .array => |array| array.child != u8,
        else => false,
    };
}

/// Every struct and array reachable from `roots` through visible fields, the roots first.
fn gather(comptime roots: []const type) []const type {
    comptime {
        var found: []const type = &.{};
        for (roots) |root| found = add(found, root);
        return found;
    }
}

fn add(comptime found: []const type, comptime T: type) []const type {
    comptime {
        if (!isAggregate(T)) return found;
        for (found) |known| {
            if (known == T) return found;
        }
        var more: []const type = found ++ &[_]type{T};
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                for (fieldsOf(T)) |field| {
                    if (info.layout == .@"packed" and isAggregate(field.type)) @compileError("fields of packed structs can't be proxies");
                    more = add(more, field.type);
                }
            },
            .array => |array| more = add(more, array.child),
            else => {},
        }
        return more;
    }
}

/// `T`'s name in messages: the last part of its Zig name, or its element type's plus "s" for an
/// array.
fn noun(comptime T: type) []const u8 {
    comptime {
        return switch (@typeInfo(T)) {
            .array => |array| noun(array.child) ++ "s",
            else => {
                const full = @typeName(T);
                return if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| full[dot + 1 ..] else full;
            },
        };
    }
}

test noun {
    const Sample = struct { x: f32 };
    try std.testing.expectEqualStrings("Sample", comptime noun(Sample));
    try std.testing.expectEqualStrings("Samples", comptime noun([2]Sample));
}

test "a proxy reads and writes a struct in place" {
    const Damage = extern struct { shield: f32, hull: f32 };
    const Level = enum(u32) { low, high, _ };
    const Gun = extern struct {
        name: [8]u8,
        range: f32,
        damage: Damage,
        level: Level,
        counts: [2]u16,
        _unread: [4]u8,
    };
    const Values = Binding(&.{Gun}, 1, "value");
    // The gun, its damage and its counts. The name is a string.
    try std.testing.expectEqual(3, Values.kinds.len);

    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    Values.register(state);
    state.sandbox();

    var gun: Gun = .{ .name = @splat(0), .range = 1000, .damage = .{ .shield = 2, .hull = 3 }, .level = .low, .counts = .{ 1, 2 }, ._unread = @splat(0) };
    const thread = state.newSandboxedThread();
    Values.push(thread, Gun, &gun, true);
    thread.setGlobal("gun");

    try run(thread,
        \\assert(gun.range == 1000 and gun.damage.hull == 3 and gun.level == "low" and gun.counts[2] == 2)
        \\gun.range = 1500
        \\gun.damage.hull = gun.damage.hull * 2
        \\gun.level = "high"
        \\gun.counts[1] = 7
        \\gun.name = "Ripper"
        \\gun.damage = { shield = 4 }
        \\local seen = {}
        \\for name, value in gun do table.insert(seen, name) end
        \\assert(table.concat(seen, ",") == "name,range,damage,level,counts")
        \\assert(#gun.counts == 2 and gun.damage == gun.damage and typeof(gun) == "value")
    );
    try std.testing.expectEqual(1500, gun.range);
    try std.testing.expectEqual(Damage{ .shield = 4, .hull = 6 }, gun.damage);
    try std.testing.expectEqual(Level.high, gun.level);
    try std.testing.expectEqual(7, gun.counts[0]);
    try std.testing.expectEqualStrings("Ripper", std.mem.sliceTo(&gun.name, 0));

    // Wrong names and values are errors, and change nothing.
    try expectError(thread, "gun.demage = 1", "Gun has no field 'demage'");
    try expectError(thread, "gun.range = 'far'", "Gun.range: expected a number, got string");
    try expectError(thread, "gun.range = 1e300", "Gun.range: expected a finite number");
    try expectError(thread, "gun.counts[1] = 1.5", "u16s: expected a whole number from 0 to 65535, got 1.5");
    try expectError(thread, "gun.counts[3] = 1", "index 3 is out of range 1 to 2");
    try expectError(thread, "gun.level = 'middle'", "Gun.level: expected 'low', 'high' or a number, got 'middle'");
    try expectError(thread, "gun.name = 'A name too long'", "Gun.name: expected at most 7 bytes, got 15");
    try expectError(thread, "local x = gun._unread", "Gun has no field '_unread'");
    try std.testing.expectEqual(1500, gun.range);

    // An open enum accepts numbers without a name.
    try run(thread, "gun.level = 7");
    try std.testing.expectEqual(@as(Level, @enumFromInt(7)), gun.level);

    // The iterator ignores keys it didn't hand out.
    try run(thread, "local iterate = getmetatable(gun.counts).__iter\nlocal step = iterate(gun.counts)\nassert(step(gun.counts, -5) == nil and step(gun.counts, 1e20) == nil)");
}

test "a read-only proxy can't be changed" {
    const Sample = extern struct { x: f32 };
    const Values = Binding(&.{Sample}, 1, "value");
    const state = State.create(luau.testing.allocate, null).?;
    defer state.close();
    state.openLibraries();
    Values.register(state);
    state.sandbox();
    var sample: Sample = .{ .x = 1 };
    const thread = state.newSandboxedThread();
    Values.push(thread, Sample, &sample, false);
    thread.setGlobal("sample");
    try run(thread, "assert(sample.x == 1)");
    try expectError(thread, "sample.x = 2", "this value is read-only");
    try std.testing.expectEqual(1, sample.x);
}

/// Runs `source`, failing the test if it raises an error.
fn run(state: *State, source: []const u8) !void {
    const bytecode = luau.compile(source).?;
    defer bytecode.free();
    try std.testing.expectEqual(luau.Status.ok, state.load("=test", bytecode.bytes));
    const status = state.protectedCall(0, 0);
    if (status != .ok) {
        std.debug.print("{s}\n", .{state.toString(-1).?});
        return error.TestUnexpectedResult;
    }
}

/// Runs `source`, expecting an error whose message contains `message`.
fn expectError(state: *State, source: []const u8, message: []const u8) !void {
    const bytecode = luau.compile(source).?;
    defer bytecode.free();
    try std.testing.expectEqual(luau.Status.ok, state.load("=test", bytecode.bytes));
    try std.testing.expectEqual(luau.Status.runtime_error, state.protectedCall(0, 0));
    const raised = state.toString(-1).?;
    if (std.mem.indexOf(u8, raised, message) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ message, raised });
        return error.TestUnexpectedResult;
    }
    state.pop(1);
}

pub const testing = struct {
    pub const runSource = run;
    pub const expectSourceError = expectError;
};
