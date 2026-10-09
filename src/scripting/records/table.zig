//! A table of the records that scripts see as a list of proxies numbered from 1, each with named
//! fields that load scripts change in place: the campaign's missions (`records.missions`) and the
//! KILLBOARD's pilots (`records.killboard`). Assigning a table of fields to an entry changes only the
//! fields the table holds. Entries can't be added or removed.

const std = @import("std");

const openreliant = @import("openreliant");
const language = openreliant.engine.game.language;
const luau = @import("../luau.zig");
const State = luau.State;
const bind = @import("../bind.zig");
const values = @import("../values.zig");
const records = @import("../records.zig");
const Records = records.Records;

/// One entry of a table, as its proxy holds it.
pub const Item = struct {
    records: *Records,
    /// Its index in the table, from 0.
    place: usize,
    writable: bool,

    /// Its number, as scripts index it: from 1.
    pub fn number(item: Item) u16 {
        return @intCast(item.place + 1);
    }
};

/// The proxies of a table that `Spec` describes:
///
/// - `script_name`, the name scripts know an entry by, and `item_noun`, such as "a mission";
/// - `list_name`, the table's name in the package, and `described`, such as "the campaign's
///   missions";
/// - `list_tag` and `item_tag`, the userdata tags of the table and of an entry;
/// - `Field`, the entries' fields;
/// - `count(records)`, how many entries the table has;
/// - `getField(state, item, field)`, which pushes a field's value, and `setField(state, item,
///   field, given)`, which sets it from the value at `given`.
pub fn Table(comptime Spec: type) type {
    return struct {
        /// The userdata for the table.
        const List = struct {
            records: *Records,
            writable: bool,

            fn of(state: *State, at: i32) *const List {
                return state.checkUserdata(List, at, Spec.list_tag, Spec.described);
            }
        };

        fn itemOf(state: *State, at: i32) *const Item {
            return state.checkUserdata(Item, at, Spec.item_tag, Spec.item_noun);
        }

        /// Registers the metatables of the table and of each entry.
        pub fn register(state: *State) void {
            state.registerUserdata(Spec.list_tag, Spec.list_name, &.{
                .{ "__index", luau.wrap(index) },
                .{ "__newindex", luau.wrap(newIndex) },
                .{ "__iter", luau.wrap(iterate) },
                .{ "__len", luau.wrap(length) },
                .{ "__tostring", luau.wrap(describeList) },
            });
            state.registerUserdata(Spec.item_tag, Spec.script_name, &.{
                .{ "__index", luau.wrap(get) },
                .{ "__newindex", luau.wrap(set) },
                .{ "__tostring", luau.wrap(describeItem) },
            });
        }

        /// Pushes the table, which scripts can change only if `writable`. Call `register` first.
        pub fn push(state: *State, held: *Records, writable: bool) void {
            const list = state.newUserdata(List, Spec.list_tag);
            list.* = .{ .records = held, .writable = writable };
        }

        /// The index in `held`'s table of the entry that the key at `key` numbers; null for any
        /// other key.
        fn placeOf(state: *State, held: *const Records, key: i32) ?usize {
            const number = bind.wholeIndex(state.toNumber(key) orelse return null) orelse return null;
            if (number < 1) return null;
            const place = number - 1;
            return if (place < Spec.count(held)) place else null;
        }

        fn pushItem(state: *State, list: *const List, place: usize) void {
            const item = state.newUserdata(Item, Spec.item_tag);
            item.* = .{ .records = list.records, .place = place, .writable = list.writable };
        }

        /// The table's `__index`: the entry of a number, nil for a number it has none for.
        fn index(state: *State) i32 {
            const list = List.of(state, 1);
            const place = placeOf(state, list.records, 2) orelse {
                state.pushNil();
                return 1;
            };
            pushItem(state, list, place);
            return 1;
        }

        /// The table's `__newindex`: `records.<list>[n] = { ... }` changes the fields the table
        /// holds.
        fn newIndex(state: *State) i32 {
            const list = List.of(state, 1);
            if (!list.writable) state.raise("records can only be changed by load scripts", .{});
            const place = placeOf(state, list.records, 2) orelse {
                _ = state.toDisplay(2);
                state.raise("records.{s}[{s}] does not exist: {s} are 1 to {d}", .{ Spec.list_name, state.toString(-1).?, Spec.described, Spec.count(list.records) });
            };
            if (state.typeOf(3) == .nil) state.raise("records.{s}: {s} can't be removed", .{ Spec.list_name, Spec.item_noun });
            if (state.typeOf(3) != .table) state.raise("records.{s}: expected a table of fields, got {s}", .{ Spec.list_name, state.typeName(3) });
            const item: Item = .{ .records = list.records, .place = place, .writable = true };
            state.pushNil();
            while (state.next(3)) {
                const key = (if (state.typeOf(-2) == .string) state.toString(-2) else null) orelse
                    state.raise("records.{s}: a table of fields has names for keys, not {s}", .{ Spec.list_name, state.typeName(-2) });
                Spec.setField(state, item, fieldNamed(state, key), -1);
                state.pop(1);
            }
            return 0;
        }

        /// The table's `__iter`: each entry in turn, as its number and the entry.
        fn iterate(state: *State) i32 {
            state.pushFunction(luau.wrap(step), "next");
            state.pushCopy(1);
            state.pushNil();
            return 3;
        }

        /// The entry after the given number, or nothing after the last.
        fn step(state: *State) i32 {
            const list = List.of(state, 1);
            const place: usize = if (state.typeOf(2) == .nil) 0 else (placeOf(state, list.records, 2) orelse return 0) + 1;
            if (place >= Spec.count(list.records)) return 0;
            state.pushNumber(@floatFromInt(place + 1));
            pushItem(state, list, place);
            return 2;
        }

        /// The table's `__len`: how many entries it has.
        fn length(state: *State) i32 {
            state.pushNumber(@floatFromInt(Spec.count(List.of(state, 1).records)));
            return 1;
        }

        fn describeList(state: *State) i32 {
            _ = List.of(state, 1);
            state.pushString(Spec.list_name);
            return 1;
        }

        fn describeItem(state: *State) i32 {
            _ = itemOf(state, 1);
            state.pushString(Spec.script_name);
            return 1;
        }

        /// The field named `name`; an error for a name an entry doesn't have.
        fn fieldNamed(state: *State, name: []const u8) Spec.Field {
            return std.meta.stringToEnum(Spec.Field, name) orelse
                state.raise("{s} has no field '{s}' ({s})", .{ Spec.script_name, name, field_names });
        }

        /// The fields' names, for error messages.
        const field_names = names: {
            var names: []const u8 = "";
            for (std.enums.values(Spec.Field), 0..) |field, at| names = names ++ (if (at == 0) "" else ", ") ++ @tagName(field);
            break :names names;
        };

        /// An entry's `__index`: the value of a field.
        fn get(state: *State) i32 {
            const item = itemOf(state, 1).*;
            const name = state.toString(2) orelse state.raise("{s}: a field has a name, not {s}", .{ Spec.script_name, state.typeName(2) });
            Spec.getField(state, item, fieldNamed(state, name));
            return 1;
        }

        /// An entry's `__newindex`: changes a field, for load scripts.
        fn set(state: *State) i32 {
            const item = itemOf(state, 1).*;
            if (!item.writable) state.raise("records can only be changed by load scripts", .{});
            const name = state.toString(2) orelse state.raise("{s}: a field has a name, not {s}", .{ Spec.script_name, state.typeName(2) });
            Spec.setField(state, item, fieldNamed(state, name), 3);
            return 0;
        }
    };
}

/// The type scripts read and give for a value the records keep as `T`: text as strings, and a list
/// as a `values.List` of at most `most` values.
pub fn ScriptType(comptime T: type, comptime most: usize) type {
    return switch (T) {
        language.Words => []const u8,
        ?language.Words => ?[]const u8,
        else => switch (@typeInfo(T)) {
            .pointer => |pointer| if (pointer.child == u8) T else values.List(ScriptType(pointer.child, most), most),
            else => T,
        },
    };
}

/// Converts `given`, a value a script gave as `ScriptType(T, ...)`, into the `T` the records keep:
/// text in the game's code page, and strings and lists copied into the records' arena. Raises an
/// error naming `label` if it can't.
pub fn kept(comptime T: type, state: *State, held: *Records, given: anytype, comptime label: []const u8) T {
    return switch (T) {
        language.Words => .{ .text = records.encoded(state, held.arena, given, label) },
        ?language.Words => if (given) |text| .{ .text = records.encoded(state, held.arena, text, label) } else null,
        []const u8 => held.arena.dupe(u8, given) catch state.raise(label ++ ": out of memory", .{}),
        ?[]const u8 => if (given) |text| kept([]const u8, state, held, text, label) else null,
        else => switch (@typeInfo(T)) {
            .pointer => |pointer| list: {
                const items = held.arena.alloc(pointer.child, given.len) catch state.raise(label ++ ": out of memory", .{});
                for (items, given.slice()) |*item, one| item.* = kept(pointer.child, state, held, one, label);
                break :list items;
            },
            else => given,
        },
    };
}

/// The items a script gave, `given`, as the records keep them: report parts, news items and the
/// like, of type `Kept`, whose fields have the same names as the script's (`kept`).
pub fn keptItems(comptime Kept: type, state: *State, held: *Records, given: anytype, comptime label: []const u8) []const Kept {
    const items = held.arena.alloc(Kept, given.len) catch state.raise(label ++ ": out of memory", .{});
    const info = @typeInfo(Kept).@"struct";
    for (items, given) |*item, read| {
        inline for (info.field_names, info.field_types) |name, Type| @field(item, name) = kept(Type, state, held, @field(read, name), label);
    }
    return items;
}

/// Pushes `value`, which the records keep as a `T`, as scripts read it: text as UTF-8 strings, with
/// a string number read from the ITAC's text, and a slice as a list.
pub fn pushValue(state: *State, held: *const Records, comptime T: type, value: T) void {
    switch (T) {
        language.Words => records.pushText(state, value.in(held.language(.itac_text))),
        ?language.Words => if (value) |words| pushValue(state, held, language.Words, words) else state.pushNil(),
        []const u8, ?[]const u8 => values.push(state, T, value),
        else => switch (@typeInfo(T)) {
            .pointer => |pointer| {
                state.newTable(@intCast(value.len), 0);
                for (value, 1..) |item, at| {
                    pushValue(state, held, pointer.child, item);
                    state.rawSetIndex(-2, @intCast(at));
                }
            },
            .@"struct" => |info| {
                state.newTable(0, info.field_names.len);
                inline for (info.field_names, info.field_types) |name, Type| {
                    pushValue(state, held, Type, @field(value, name));
                    state.rawSetField(-2, name);
                }
            },
            else => values.push(state, T, value),
        },
    }
}

/// Pushes `items`, such as a mission's news items, as a list of tables with the same fields.
pub fn pushItems(state: *State, held: *const Records, items: anytype) void {
    pushValue(state, held, @TypeOf(items), items);
}
