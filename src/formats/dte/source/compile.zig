//! Mission source compiled into a standard mission file, as `sltool dte build` does it
//! ([Mission source](../../../../docs/formats/mission-source.md)). The declarations become the
//! records, each kind in the order of its declarations, and the code of the parts and triggers
//! becomes the script (`compile/code.zig`). What the source leaves out takes what most shipped
//! records hold (`dte.Ship.blank` and the others), and the compiler numbers the objects itself
//! (`Compiler.numberObjects`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const dte = @import("../../dte.zig");
const assemble = @import("../assemble.zig");
const statements = @import("../statements.zig");
const bind = @import("../../../engine/game/mission/bind.zig");
const commands = @import("../../../engine/game/executor/commands.zig");
const executor = @import("../../../engine/game/executor.zig");
const conditions = @import("../../../engine/vm/conditions.zig");
const names = @import("names.zig");
const script = @import("script.zig");
const syntax = @import("syntax.zig");
const vocabulary = @import("vocabulary.zig");
const Word = names.Word;
const Index = syntax.Index;

/// The code of parts and triggers, read into statements.
pub const code = @import("compile/code.zig");

/// Why a file doesn't compile, and where.
pub const Failure = struct {
    at: syntax.Position,
    message: []const u8,

    /// Writes the failure as `line:column: message`.
    pub fn format(failure: Failure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{f}: {s}", .{ failure.at, failure.message });
    }
};

pub const Error = Allocator.Error || error{
    /// The source has an error, which the failure describes.
    Invalid,
};

/// Compiles `tree` into a mission file, allocated with `arena`. Where the source has an error, the
/// parser's or the compiler's, `failure` says what and where, and the error is `Invalid`.
pub fn compile(arena: Allocator, tree: syntax.Tree, failure: *Failure) Error![]u8 {
    if (tree.errors.len > 0) {
        failure.* = .{ .at = tree.errors[0].at, .message = tree.errors[0].message };
        return error.Invalid;
    }
    var compiler: Compiler = .{ .arena = arena, .tree = tree, .failure = failure };
    try compiler.declare();
    return compiler.build();
}

/// The kinds of record a name can declare.
pub const Kind = enum {
    global,
    flight_group,
    ship,
    squad,
    formation,
    curve,
    part,
    handler,

    /// What a record of the kind is called in a message.
    pub fn noun(kind: Kind) []const u8 {
        return switch (kind) {
            .flight_group => "flight group",
            else => @tagName(kind),
        };
    }

    /// The form that names a record of the kind by its index, such as `ship_index(59031)`, where
    /// it has one.
    fn indexForm(kind: Kind) ?Word {
        return switch (kind) {
            inline else => |tag| if (@hasField(Word, @tagName(tag) ++ "_index")) @field(Word, @tagName(tag) ++ "_index") else null,
        };
    }
};

/// What a name declares: a record of a kind, by its index among the records of its kind, and the
/// call that declares it.
pub const Declared = struct {
    kind: Kind,
    index: u32,
    call: Index,
};

/// The fields each constructor takes.
const ship_fields = [_][]const u8{ "type", "group", "pilot", "position", "yaw", "pitch", "roll", "launch", "formation_point", "tier" };
/// A marker's: a ship's but `type`, and a point's `marker` too.
const marker_fields = ship_fields[1..].*;
const point_fields = marker_fields ++ [_][]const u8{"marker"};
const curve_fields = [_][]const u8{ "start", "finish", "from", "to", "leaving_handle", "arriving_handle", "leaving", "arriving" };

pub const Compiler = struct {
    arena: Allocator,
    tree: syntax.Tree,
    failure: *Failure,
    /// What each name of the file declares.
    names: std.StringHashMapUnmanaged(Declared) = .empty,
    /// The calls that declare each kind's records, in order.
    declarations: std.EnumArray(Kind, std.ArrayList(Index)) = .initFill(.empty),
    /// The calls of `on`, in order.
    triggers: std.ArrayList(Index) = .empty,
    /// The call of `mission`, where the file has one.
    mission: ?Index = null,
    /// The object table's length: the records', or more where `object_index` names an object past
    /// them.
    object_count: u32 = 0,
    /// The object ID of each ship, flight group and squad, by its index (`numberObjects`).
    object_ids: std.EnumArray(ObjectKind, []u32) = .initFill(&.{}),

    /// The kinds of record the object table numbers.
    const ObjectKind = enum { ship, flight_group, squad };

    /// Records why the compilation fails, at `node`, and gives `Invalid`.
    pub fn fail(c: *Compiler, node: Index, comptime message: []const u8, args: anytype) Error {
        const text = std.fmt.allocPrint(c.arena, message, args) catch return error.OutOfMemory;
        c.failure.* = .{ .at = c.tree.at(node), .message = text };
        return error.Invalid;
    }

    /// The word of the source's own that `node` calls, such as `ship` in `ship(...)`.
    pub fn wordOf(c: *Compiler, node: Index) ?Word {
        const call = switch (c.tree.get(node)) {
            .call => |call| call,
            else => return null,
        };
        return switch (c.tree.get(call.function)) {
            .global_name => |name| std.meta.stringToEnum(Word, name),
            else => null,
        };
    }

    /// What `name`, at `node`, declares.
    pub fn lookup(c: *Compiler, node: Index, name: []const u8) Error!Declared {
        return c.names.get(name) orelse c.fail(node, "`{s}` is not declared", .{name});
    }

    fn count(c: *Compiler, kind: Kind) u32 {
        return @intCast(c.declarations.get(kind).items.len);
    }

    /// The arguments of the call `node`, from `least` to `most` of them, as `usage` says.
    fn arguments(c: *Compiler, node: Index, least: usize, most: usize, comptime usage: []const u8) Error![]const Index {
        const list = c.tree.get(node).call.arguments;
        if (list.len < least or list.len > most) return c.fail(node, usage, .{});
        return list;
    }

    // The declarations.

    fn declare(c: *Compiler) Error!void {
        const usage = "the top level holds declarations, `on(...)` and `mission(...)`";
        for (c.tree.get(c.tree.root).block) |line| switch (c.tree.get(line)) {
            .assign => |binding| try c.declaration(line, binding),
            .call_statement => |call| {
                const called = c.wordOf(call) orelse return c.fail(line, usage, .{});
                switch (called) {
                    .on => try c.triggers.append(c.arena, call),
                    .mission => {
                        if (c.mission != null) return c.fail(line, "the mission's details are given twice", .{});
                        c.mission = call;
                    },
                    else => return c.fail(line, usage, .{}),
                }
            },
            .unsupported => |what| return c.fail(line, "{s}, which mission source doesn't use", .{what}),
            else => return c.fail(line, usage, .{}),
        };
        try c.numberObjects();
    }

    /// Numbers the objects: first those that `last_event` names, in the order the source names
    /// them, since the script names those by a byte, then the rest, the ships, the flight groups
    /// and the squads, each in order.
    fn numberObjects(c: *Compiler) Error!void {
        const unnumbered = std.math.maxInt(u32);
        for (std.enums.values(ObjectKind)) |kind| {
            const ids = try c.arena.alloc(u32, c.count(kindOf(kind)));
            @memset(ids, unnumbered);
            c.object_ids.set(kind, ids);
        }
        var next: u32 = 0;
        for (0..c.tree.nodes.len) |index| {
            const node: Index = @intCast(index);
            if (c.wordOf(node) != .last_event) continue;
            const given = c.tree.get(node).call.arguments;
            if (given.len == 0 or c.tree.get(given[0]) != .global_name) continue;
            const declared = c.names.get(c.tree.get(given[0]).global_name) orelse continue;
            const kind = objectKind(declared.kind) orelse continue;
            const id = &c.object_ids.get(kind)[declared.index];
            if (id.* != unnumbered) continue;
            id.* = next;
            next += 1;
        }
        for (std.enums.values(ObjectKind)) |kind| {
            for (c.object_ids.get(kind)) |*id| if (id.* == unnumbered) {
                id.* = next;
                next += 1;
            };
        }
        c.object_count = next;
    }

    fn kindOf(kind: ObjectKind) Kind {
        return switch (kind) {
            inline else => |tag| @field(Kind, @tagName(tag)),
        };
    }

    fn objectKind(kind: Kind) ?ObjectKind {
        return std.meta.stringToEnum(ObjectKind, @tagName(kind));
    }

    /// `name = constructor(...)`: the record a name declares.
    fn declaration(c: *Compiler, line: Index, binding: syntax.Syntax.Binding) Error!void {
        if (binding.targets.len != 1 or binding.values.len != 1) return c.fail(line, "a declaration names one record: `name = ship(...)`", .{});
        const target = binding.targets[0];
        const name = switch (c.tree.get(target)) {
            .global_name => |name| name,
            else => return c.fail(target, "a record is declared under a name: `name = ship(...)`", .{}),
        };
        const value = binding.values[0];
        const kind: Kind = switch (c.wordOf(value) orelse return c.fail(value, "`{s}` is declared by a constructor, such as `ship(...)`", .{name})) {
            .global => .global,
            .flight_group => .flight_group,
            .ship, .nav_point, .waypoint, .point, .curve_point => .ship,
            .squad => .squad,
            .formation => .formation,
            .curve => .curve,
            .part => .part,
            .handler => .handler,
            else => |other| return c.fail(value, "`{t}(...)` declares no record", .{other}),
        };
        if (names.isReserved(name) or executor.commandNamed(name) != null) return c.fail(target, "`{s}` is a name mission source keeps for itself", .{name});
        const records = c.declarations.getPtr(kind);
        const slot = try c.names.getOrPut(c.arena, name);
        if (slot.found_existing) return c.fail(target, "`{s}` is declared already, at {f}", .{ name, c.tree.at(slot.value_ptr.call) });
        slot.value_ptr.* = .{ .kind = kind, .index = @intCast(records.items.len), .call = value };
        try records.append(c.arena, value);
    }

    // The values the declarations give.

    fn string(c: *Compiler, node: Index) Error![]const u8 {
        return switch (c.tree.get(node)) {
            .string => |text| text,
            else => c.fail(node, "text in quotes goes here", .{}),
        };
    }

    fn boolean(c: *Compiler, node: Index) Error!bool {
        return switch (c.tree.get(node)) {
            .boolean => |value| value,
            else => c.fail(node, "`true` or `false` goes here", .{}),
        };
    }

    /// The number `node` writes: a number, one negated, or a quotient such as `1/0`, as the
    /// source writes those Luau has no literal for.
    fn number(c: *Compiler, node: Index) Error!f64 {
        switch (c.tree.get(node)) {
            .number => |value| return value,
            .unary => |unary| if (unary.operator == .minus) return -(try c.number(unary.operand)),
            .binary => |pair| if (pair.operator == .div) return try c.number(pair.left) / try c.number(pair.right),
            else => {},
        }
        return c.fail(node, "a number goes here", .{});
    }

    /// The whole number `node` writes, which `T` holds.
    pub fn whole(c: *Compiler, comptime T: type, node: Index) Error!T {
        const value = try c.number(node);
        if (@trunc(value) != value or value < std.math.minInt(T) or value > std.math.maxInt(T)) {
            return c.fail(node, "a whole number from {d} to {d} goes here", .{ std.math.minInt(T), std.math.maxInt(T) });
        }
        return @intFromFloat(value);
    }

    /// A whole number of 32 bits, as the script and the records keep one: from -2147483648, kept
    /// as the bits it is written in, to 4294967295.
    pub fn word(c: *Compiler, node: Index) Error!u32 {
        const value = try c.number(node);
        if (@trunc(value) != value or value < std.math.minInt(i32) or value > std.math.maxInt(u32)) {
            return c.fail(node, "a whole number from {d} to {d} goes here", .{ std.math.minInt(i32), std.math.maxInt(u32) });
        }
        return if (value < 0) @bitCast(@as(i32, @intFromFloat(value))) else @intFromFloat(value);
    }

    fn float(c: *Compiler, node: Index) Error!f32 {
        const value = try c.number(node);
        if (std.math.isFinite(value) and @abs(value) > std.math.floatMax(f32)) return c.fail(node, "this number is too large for 32 bits", .{});
        return @floatCast(value);
    }

    /// `value`, the number of the `what`, as `T`, where `T` holds it.
    pub fn narrow(c: *Compiler, comptime T: type, node: Index, value: u32, what: []const u8) Error!T {
        return std.math.cast(T, value) orelse c.fail(node, "{s} {d} doesn't fit here, which holds up to {d}", .{ what, value, std.math.maxInt(T) });
    }

    /// The items of the list `node`: `{ a, b, c }`.
    fn listOf(c: *Compiler, node: Index) Error![]const Index {
        const items = switch (c.tree.get(node)) {
            .table => |items| items,
            else => return c.fail(node, "a list goes here: `{{ a, b }}`", .{}),
        };
        const values = try c.arena.alloc(Index, items.len);
        for (values, items) |*value, item| value.* = switch (c.tree.get(item).item) {
            .list => |found| found,
            else => return c.fail(item, "a list holds values alone, without names", .{}),
        };
        return values;
    }

    /// A place, `{ x, y, z }`.
    fn vector(c: *Compiler, node: Index) Error![3]f32 {
        const items = try c.listOf(node);
        if (items.len != 3) return c.fail(node, "a place is three numbers: `{{ x, y, z }}`", .{});
        var place: [3]f32 = undefined;
        for (&place, items) |*axis, item| axis.* = try c.float(item);
        return place;
    }

    /// The fields of the table `node`, `{ name = value }`, each one of `allowed`.
    fn fields(c: *Compiler, node: Index, allowed: []const []const u8) Error!Fields {
        const items = switch (c.tree.get(node)) {
            .table => |items| items,
            else => return c.fail(node, "the fields go in a table: `{{ name = value }}`", .{}),
        };
        const keys = try c.arena.alloc([]const u8, items.len);
        const values = try c.arena.alloc(Index, items.len);
        for (items, keys, values, 0..) |item, *key, *value, place| {
            const record = switch (c.tree.get(item).item) {
                .record => |record| record,
                else => return c.fail(item, "a field is written `name = value`", .{}),
            };
            if (!contains(allowed, record.key)) return c.fail(item, "`{s}` isn't a field here, which takes {f}", .{ record.key, Listed{ .names = allowed } });
            if (contains(keys[0..place], record.key)) return c.fail(item, "`{s}` is given twice", .{record.key});
            key.* = record.key;
            value.* = record.value;
        }
        return .{ .keys = keys, .values = values };
    }

    /// The index of the record of `kind` that `node` names: by its name, or by its index form for
    /// one past the mission's records, such as `ship_index(59031)` (`Kind.indexForm`).
    pub fn reference(c: *Compiler, node: Index, kind: Kind) Error!u32 {
        switch (c.tree.get(node)) {
            .global_name => |name| {
                const declared = try c.lookup(node, name);
                if (declared.kind != kind) return c.fail(node, "`{s}` is a {s}, not a {s}", .{ name, declared.kind.noun(), kind.noun() });
                return declared.index;
            },
            .call => |call| if (c.wordOf(node)) |form| if (form == kind.indexForm()) {
                if (call.arguments.len != 1) return c.fail(node, "`{t}(...)` takes the record's index", .{form});
                return c.whole(u32, call.arguments[0]);
            },
            else => {},
        }
        return c.fail(node, "a {s} goes here", .{kind.noun()});
    }

    /// `reference` as `T`, where `T` holds the index.
    pub fn referenceAs(c: *Compiler, comptime T: type, node: Index, kind: Kind) Error!T {
        return c.narrow(T, node, try c.reference(node, kind), kind.noun());
    }

    /// The value of `kind` that `node` gives: by the name the game gives it, in quotes, or by its
    /// number, for one the game doesn't name, such as a mod's.
    pub fn named(c: *Compiler, node: Index, kind: vocabulary.Kind) Error!u32 {
        return switch (c.tree.get(node)) {
            .string => |text| vocabulary.value(kind, text) orelse c.fail(node, "the game has no {s} named \"{s}\"", .{ kind.noun(), text }),
            else => c.word(node),
        };
    }

    /// The object ID of the ship, flight group or squad `node` names (`numberObjects`), or of the
    /// object `object_index(N)` gives.
    pub fn objectOf(c: *Compiler, node: Index) Error!u32 {
        if (c.wordOf(node) == .object_index) {
            const call = c.tree.get(node).call;
            if (call.arguments.len != 1) return c.fail(node, "`object_index(...)` takes the object's ID", .{});
            const id = try c.whole(u16, call.arguments[0]);
            c.object_count = @max(c.object_count, @as(u32, id) + 1);
            return id;
        }
        const name = switch (c.tree.get(node)) {
            .global_name => |name| name,
            else => return c.fail(node, "a ship, a flight group or a squad goes here", .{}),
        };
        const declared = try c.lookup(node, name);
        const kind = objectKind(declared.kind) orelse return c.fail(node, "`{s}` is a {s}, not a ship, a flight group or a squad", .{ name, declared.kind.noun() });
        return c.object_ids.get(kind)[declared.index];
    }

    // The records.

    fn build(c: *Compiler) Error![]u8 {
        var pool: Pool = .{};
        const globals = try c.buildGlobals(&pool);
        const formations = try c.buildFormations(&pool);
        const curves = try c.buildCurves();
        const groups = try c.buildFlightGroups(&pool);
        const ships = try c.buildShips(&pool, formations);
        // Each group's count of ships and the first one's place, as binding the mission works them
        // out.
        _ = try bind.listGroupShips(c.arena, groups, ships);
        const squads = try c.buildSquads(&pool);
        const parts = try c.buildParts(&pool);
        const triggers = try c.buildTriggers();
        const code_bytes = try c.buildScript(parts, triggers);
        // After the code, whose `object_index` can name objects past the records.
        const objects = try c.buildObjects(ships, try c.slices(triggers));

        var sections: dte.write.Sections = @splat(.{});
        try c.section(&sections, .strings, pool.strings.bytes.items.len, pool.strings.bytes.items, "bytes of names");
        try c.section(&sections, .globals, globals.len, std.mem.sliceAsBytes(globals), "globals");
        try c.section(&sections, .ships, ships.len, std.mem.sliceAsBytes(ships), "ships");
        try c.section(&sections, .flight_groups, groups.len, std.mem.sliceAsBytes(groups), "flight groups");
        try c.section(&sections, .triggers, triggers.records.len, std.mem.sliceAsBytes(triggers.records), "triggers");
        try c.section(&sections, .script, code_bytes.len / 2, code_bytes, "halfwords of script");
        try c.section(&sections, .objects, objects.len, std.mem.sliceAsBytes(objects), "objects");
        try c.section(&sections, .parts, parts.records.len, std.mem.sliceAsBytes(parts.records), "parts");
        const flags = try c.arena.alloc(u8, code_bytes.len);
        @memset(flags, 0);
        try c.section(&sections, .script_flags, flags.len, flags, "script flags");
        try c.section(&sections, .squads, squads.records.len, std.mem.sliceAsBytes(squads.records), "squads");
        try c.section(&sections, .squad_members, squads.members.len, std.mem.sliceAsBytes(squads.members), "squad members");
        try c.section(&sections, .formations, formations.records.len, std.mem.sliceAsBytes(formations.records), "formations");
        try c.section(&sections, .formation_points, formations.points.len, std.mem.sliceAsBytes(formations.points), "formation points");
        try c.section(&sections, .curves, curves.len, std.mem.sliceAsBytes(curves), "curves");
        const command_flags = &dte.write.template.command_flags;
        try c.section(&sections, .command_flags, command_flags.len, std.mem.sliceAsBytes(command_flags), "commands");
        return dte.write.write(c.arena, &sections, .{ .name = try c.missionName() }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NameTooLong => c.fail(c.mission.?, "the mission's name is longer than its section counts", .{}),
            // Each section's size is checked as it is set.
            error.SectionTooLarge => unreachable,
        };
    }

    /// Puts `bytes`, `amount` of what `noun` names, in section `which`, where the mission file has
    /// room for them.
    fn section(c: *Compiler, sections: *dte.write.Sections, which: dte.Section, amount: usize, bytes: []const u8, comptime noun: []const u8) Error!void {
        const room = dte.write.template.room(@backingInt(which));
        if (bytes.len > room or amount > std.math.maxInt(u16)) {
            return c.fail(c.tree.root, "a mission file has room for {d} " ++ noun ++ ", and this one has {d}", .{ room / (which.stride() orelse 1), amount });
        }
        dte.write.set(sections, which, amount, bytes);
    }

    fn missionName(c: *Compiler) Error!?[]const u8 {
        const call = c.mission orelse return null;
        const given = try c.fields((try c.arguments(call, 1, 1, "`mission(...)` takes a table: `{{ name = \"Patrol\" }}`"))[0], &.{"name"});
        return if (given.get("name")) |node| try c.string(node) else null;
    }

    fn buildGlobals(c: *Compiler, pool: *Pool) Error![]dte.Global {
        const calls = c.declarations.get(.global).items;
        const records = try c.arena.alloc(dte.Global, calls.len);
        for (records, calls) |*record, call| {
            const given = try c.arguments(call, 2, 2, "a global takes its display name and the value it starts with");
            record.* = .blank;
            record.name = try pool.add(c, given[0]);
            record.value = try c.word(given[1]);
        }
        return records;
    }

    const Formations = struct {
        records: []dte.Formation,
        points: []dte.FormationPoint,

        /// How many points formation `index` has.
        fn pointCount(formations: Formations, index: usize) usize {
            const end = if (index + 1 < formations.records.len) formations.records[index + 1].first_point else formations.points.len;
            return end - formations.records[index].first_point;
        }
    };

    fn buildFormations(c: *Compiler, pool: *Pool) Error!Formations {
        const calls = c.declarations.get(.formation).items;
        const records = try c.arena.alloc(dte.Formation, calls.len);
        var points: std.ArrayList(dte.FormationPoint) = .empty;
        for (records, calls, 0..) |*record, call, index| {
            const given = try c.arguments(call, 2, 2, "a formation takes its display name and its points: `{{ {{ x, y, z }} }}`");
            record.* = .blank;
            record.name = try pool.add(c, given[0]);
            record.first_point = try c.narrow(u16, call, @intCast(points.items.len), "formation point");
            for (try c.listOf(given[1])) |item| {
                var point: dte.FormationPoint = .blank;
                point.formation = try c.narrow(u16, call, @intCast(index), "formation");
                point.offset = try c.vector(item);
                try points.append(c.arena, point);
            }
        }
        return .{ .records = records, .points = points.items };
    }

    fn buildCurves(c: *Compiler) Error![]dte.Curve {
        const calls = c.declarations.get(.curve).items;
        const records = try c.arena.alloc(dte.Curve, calls.len);
        for (records, calls) |*record, call| {
            const given = try c.fields((try c.arguments(call, 1, 1, "a curve takes a table of its fields"))[0], &curve_fields);
            record.* = .blank;
            inline for (.{ .{ "start", "start" }, .{ "finish", "end" }, .{ "leaving_handle", "leaving_handle" }, .{ "arriving_handle", "arriving_handle" } }) |pair| {
                if (given.get(pair[0])) |node| @field(record, pair[1]) = .of(.ship, try c.referenceAs(u16, node, .ship));
            }
            inline for (.{ "from", "to", "leaving", "arriving" }) |name| {
                if (given.get(name)) |node| @field(record, name) = try c.vector(node);
            }
        }
        return records;
    }

    fn buildFlightGroups(c: *Compiler, pool: *Pool) Error![]dte.FlightGroup {
        const calls = c.declarations.get(.flight_group).items;
        const records = try c.arena.alloc(dte.FlightGroup, calls.len);
        for (records, calls, 0..) |*record, call, index| {
            const given = try c.arguments(call, 1, 2, "a flight group takes its display name and a table of its fields");
            record.* = .blank;
            record.object_id = try c.narrow(u16, call, c.object_ids.get(.flight_group)[index], "object");
            record.name = try pool.add(c, given[0]);
            const details: Fields = if (given.len > 1) try c.fields(given[1], &.{ "wing", "formation" }) else .{};
            if (details.get("wing")) |node| record.wing = switch (c.tree.get(node)) {
                .string => |text| std.meta.stringToEnum(dte.FlightGroup.Wing, text) orelse return c.fail(node, "a wing is \"player\", \"second\", \"third\" or \"none\"", .{}),
                else => @fromBackingInt(try c.whole(u8, node)),
            };
            if (details.get("formation")) |node| record.formation = .of(.formation, try c.referenceAs(u16, node, .formation));
        }
        return records;
    }

    fn buildShips(c: *Compiler, pool: *Pool, formations: Formations) Error![]dte.Ship {
        const calls = c.declarations.get(.ship).items;
        const records = try c.arena.alloc(dte.Ship, calls.len);
        for (records, calls, 0..) |*record, call, index| {
            const constructor = c.wordOf(call).?;
            const given = try c.arguments(call, 1, 2, "a ship or a marker takes its display name and a table of its fields");
            record.* = .blank;
            record.object_id = c.object_ids.get(.ship)[index];
            record.name = try pool.add(c, given[0]);
            const allowed: []const []const u8 = switch (constructor) {
                .ship => &ship_fields,
                .point => &point_fields,
                else => &marker_fields,
            };
            const details: Fields = if (given.len > 1) try c.fields(given[1], allowed) else .{};
            record.kind = switch (constructor) {
                .nav_point => dte.Ship.nav_point_kind,
                .waypoint => dte.Ship.waypoint_kind,
                .point => dte.Ship.point_kind,
                .curve_point => dte.Ship.curve_point_kind,
                else => kind: {
                    const node = details.get("type") orelse return c.fail(call, "a ship needs its `type`", .{});
                    break :kind try c.narrow(u16, node, try c.named(node, .ship_type), "ship type");
                },
            };
            if (details.get("group")) |node| {
                const group = try c.reference(node, .flight_group);
                if (group >= dte.Ship.no_flight_group) return c.fail(node, "a ship's flight group is one of the first {d}", .{dte.Ship.no_flight_group});
                record.flight_group = @intCast(group);
            }
            if (details.get("pilot")) |node| {
                const pilot = try c.named(node, .pilot);
                if (pilot >= dte.Ship.no_pilot) return c.fail(node, "a pilot is one of the first {d} records of pilotstats.bin", .{dte.Ship.no_pilot});
                record.pilot = @intCast(pilot);
            }
            if (details.get("position")) |node| {
                record.position = try c.vector(node);
                record.runtime_position = record.position;
            }
            inline for (.{ .{ "yaw", "runtime_yaw" }, .{ "pitch", "runtime_pitch" }, .{ "roll", "runtime_roll" } }) |pair| {
                if (details.get(pair[0])) |node| {
                    @field(record, pair[0]) = try c.whole(i16, node);
                    @field(record, pair[1]) = @field(record, pair[0]);
                }
            }
            if (details.get("launch")) |node| {
                const launch = try c.fields(node, &.{ "from", "gate" });
                const from = launch.get("from") orelse return c.fail(node, "a launch gives the type of ship it is `from`", .{});
                const gate = launch.get("gate") orelse return c.fail(node, "a launch gives the `gate` the ship launches through", .{});
                record.launch_from = try c.narrow(u16, from, try c.named(from, .ship_type), "ship type");
                record.launch_gate = try c.whole(u8, gate);
                if (record.launch_gate == dte.Ship.no_launch) return c.fail(gate, "a gate is from 0 to {d}", .{dte.Ship.no_launch - 1});
            }
            if (details.get("formation_point")) |node| {
                record.formation_point = try c.formationPoint(node, formations);
                record.formation_point_tag = .formation_point;
            }
            if (details.get("tier")) |node| record.tier = try c.whole(u8, node);
            if (details.get("marker")) |node| {
                const marker = try c.fields(node, &.{ "curve", "at" });
                const curve = marker.get("curve") orelse return c.fail(node, "a marker gives the `curve` it marks a place on", .{});
                record.marker_curve = try c.referenceAs(i16, curve, .curve);
                if (marker.get("at")) |at| record.marker_at = try c.float(at);
            }
        }
        return records;
    }

    /// A ship's place in a formation: `sabres[2]`, the formation's second point, or
    /// `formation_point_index(N)`.
    fn formationPoint(c: *Compiler, node: Index, formations: Formations) Error!u16 {
        switch (c.tree.get(node)) {
            .index => |indexed| {
                const formation = try c.reference(indexed.object, .formation);
                if (formation >= formations.records.len) return c.fail(node, "the points of a formation past the mission's aren't known", .{});
                const place = try c.whole(u32, indexed.key);
                const points = formations.pointCount(formation);
                if (place == 0 or place > points) return c.fail(indexed.key, "the formation has {d} points, numbered from 1", .{points});
                return try c.narrow(u16, node, formations.records[formation].first_point + place - 1, "formation point");
            },
            .call => |call| if (c.wordOf(node) == .formation_point_index) {
                if (call.arguments.len != 1) return c.fail(node, "`formation_point_index(...)` takes the point's index", .{});
                const point = try c.whole(u16, call.arguments[0]);
                if (point == dte.Ship.no_formation_point) return c.fail(node, "a formation point's index is from 0 to {d}", .{dte.Ship.no_formation_point - 1});
                return point;
            },
            else => {},
        }
        return c.fail(node, "a formation's point goes here, such as `sabres[2]`", .{});
    }

    const Squads = struct {
        records: []dte.Squad,
        members: []dte.SquadMember,
    };

    fn buildSquads(c: *Compiler, pool: *Pool) Error!Squads {
        const calls = c.declarations.get(.squad).items;
        const records = try c.arena.alloc(dte.Squad, calls.len);
        var members: std.ArrayList(dte.SquadMember) = .empty;
        for (records, calls, 0..) |*record, call, index| {
            const given = try c.arguments(call, 2, 2, "a squad takes its display name and its members: `{{ a, b }}`");
            record.* = .blank;
            record.object_id = try c.narrow(u16, call, c.object_ids.get(.squad)[index], "object");
            record.name = try pool.add(c, given[0]);
            const items = try c.listOf(given[1]);
            if (items.len > 0) {
                record.first_member = try c.narrow(u16, call, @intCast(members.items.len), "squad member");
                record.first_member_tag = .squad_member;
            }
            for (items) |item| {
                var member: dte.SquadMember = .blank;
                member.squad = @intCast(index);
                var object = item;
                if (c.wordOf(item) == .component) {
                    const parts = c.tree.get(item).call.arguments;
                    if (parts.len != 2) return c.fail(item, "`component(...)` takes the object and the component's index", .{});
                    object = parts[0];
                    member.component = try c.whole(u8, parts[1]);
                    if (member.component == dte.Trigger.whole_object) return c.fail(parts[1], "a component's index is from 0 to {d}", .{dte.Trigger.whole_object - 1});
                }
                member.object_id = try c.narrow(u16, item, try c.objectOf(object), "object");
                try members.append(c.arena, member);
            }
        }
        return .{ .records = records, .members = members.items };
    }

    const Parts = struct {
        records: []dte.Part,
        /// Each part's function, where it has one.
        functions: []?Index,
    };

    fn buildParts(c: *Compiler, pool: *Pool) Error!Parts {
        const calls = c.declarations.get(.part).items;
        const records = try c.arena.alloc(dte.Part, calls.len);
        const functions = try c.arena.alloc(?Index, calls.len);
        for (records, functions, calls) |*record, *function, call| {
            const given = try c.arguments(call, 1, 3, "a part takes its display name, its code and a table of its fields");
            record.* = .blank;
            record.name = try pool.add(c, given[0]);
            function.* = null;
            if (given.len > 1) switch (c.tree.get(given[1])) {
                .function => |found| {
                    function.* = given[1];
                    record.arguments = @intCast(found.parameters.len);
                },
                .nil => {},
                else => return c.fail(given[1], "a part's code is a function, or `nil` for none", .{}),
            };
            if (given.len > 2) {
                const details = try c.fields(given[2], &.{"start"});
                if (details.get("start")) |node| record.flags.start = try c.boolean(node);
            }
        }
        return .{ .records = records, .functions = functions };
    }

    const Triggers = struct {
        records: []dte.Trigger,
        /// The object ID of each trigger's subject, where it has one.
        subjects: []?u32,
        /// The function each trigger runs, its own or a handler's, where it runs one.
        functions: []?Index,
    };

    fn buildTriggers(c: *Compiler) Error!Triggers {
        const calls = c.triggers.items;
        const built: Triggers = .{
            .records = try c.arena.alloc(dte.Trigger, calls.len),
            .subjects = try c.arena.alloc(?u32, calls.len),
            .functions = try c.arena.alloc(?Index, calls.len),
        };
        for (built.records, built.subjects, built.functions, calls) |*record, *subject, *function, call| {
            const given = try c.arguments(call, 2, 4, "`on(...)` takes the subject, the condition, a table of its fields and its code");
            record.* = .blank;
            subject.* = if (c.tree.get(given[0]) == .nil) null else try c.objectOf(given[0]);
            record.condition = @fromBackingInt(try c.narrow(u8, given[1], try c.named(given[1], .condition), "condition"));
            var rest = given[2..];
            if (rest.len > 0 and c.tree.get(rest[0]) == .table) {
                try c.triggerFields(record, rest[0]);
                rest = rest[1..];
            }
            function.* = null;
            if (rest.len > 1) return c.fail(rest[1], "a trigger runs one function", .{});
            if (rest.len == 1) function.* = switch (c.tree.get(rest[0])) {
                .function => rest[0],
                .global_name => |name| handler: {
                    const declared = try c.lookup(rest[0], name);
                    if (declared.kind != .handler) return c.fail(rest[0], "`{s}` is a {s}, not a handler", .{ name, declared.kind.noun() });
                    const handler = (try c.arguments(declared.call, 1, 1, "a handler takes its function"))[0];
                    if (c.tree.get(handler) != .function) return c.fail(handler, "a handler's code is a function", .{});
                    break :handler handler;
                },
                .nil => null,
                else => return c.fail(rest[0], "a trigger's code is a function or a handler", .{}),
            };
        }
        return built;
    }

    /// A trigger's fields: how it repeats, the component it watches, whether its thread waits for
    /// the scheduler, and what the values its condition checks must be.
    fn triggerFields(c: *Compiler, record: *dte.Trigger, node: Index) Error!void {
        const values = if (record.condition.descriptor()) |condition| condition.values else &.{};
        const event = try script.eventNames(c.arena, values);
        const allowed = try std.mem.concat(c.arena, []const u8, &.{ &.{ "repeats", "component", "deferred" }, event });
        const details = try c.fields(node, allowed);
        if (details.get("repeats")) |repeats| switch (c.tree.get(repeats)) {
            .string => |text| record.repeat = if (std.mem.eql(u8, text, "once")) .once else if (std.mem.eql(u8, text, "always")) .always else {
                return c.fail(repeats, "a trigger repeats \"once\", \"always\", or `{{ counted = 3 }}`", .{});
            },
            .table => {
                const counted = try c.fields(repeats, &.{ "counted", "left" });
                record.repeat = .counted;
                record.repeat_count = try c.whole(u8, counted.get("counted") orelse return c.fail(repeats, "a counted trigger gives how many times it fires: `{{ counted = 3 }}`", .{}));
                record.repeat_counter = if (counted.get("left")) |left| try c.whole(u8, left) else record.repeat_count;
            },
            else => record.repeat = @fromBackingInt(try c.whole(u8, repeats)),
        };
        if (details.get("component")) |component| {
            record.qualifier = try c.whole(u8, component);
            if (record.qualifier == dte.Trigger.whole_object) return c.fail(component, "a component's index is from 0 to {d}", .{dte.Trigger.whole_object - 1});
        }
        if (details.get("deferred")) |deferred| record.deferred = @intFromBool(try c.boolean(deferred));
        for (event, 0..) |name, slot| {
            const filter = details.get(name) orelse continue;
            if (!values[slot].checked or slot >= record.operands.len) return c.fail(filter, "the event's `{s}` isn't checked, so it takes no value here", .{name});
            record.operands[slot] = dte.Operand.write(try c.operand(filter, values[slot].kinds));
        }
    }

    /// What a value of an event must be, for a trigger to fire: a number, a ship, a flight group
    /// or a squad, `any_ship`, or the operand's bits as a number.
    fn operand(c: *Compiler, node: Index, kinds: commands.Kinds) Error!dte.Operand {
        if (kinds.number) return c.checked(node, .{ .number = try c.word(node) }, kinds);
        const usage = "a ship, a flight group, a squad or `any_ship` goes here";
        const kind: Kind = switch (c.tree.get(node)) {
            .global_name => |name| kind: {
                if (std.mem.eql(u8, name, @tagName(Word.any_ship))) return c.checked(node, .any_ship, kinds);
                break :kind (try c.lookup(node, name)).kind;
            },
            .call => switch (c.wordOf(node) orelse return c.fail(node, usage, .{})) {
                .ship_index => .ship,
                .flight_group_index => .flight_group,
                .squad_index => .squad,
                else => return c.fail(node, usage, .{}),
            },
            // The operand's bits, where the matcher can't read it as a record.
            else => return c.checked(node, .{ .other = try c.word(node) }, kinds),
        };
        return c.checked(node, switch (kind) {
            .ship => .{ .ship = try c.referenceAs(u16, node, .ship) },
            .flight_group => .{ .flight_group = try c.referenceAs(u16, node, .flight_group) },
            .squad => .{ .squad = try c.referenceAs(u16, node, .squad) },
            else => return c.fail(node, usage, .{}),
        }, kinds);
    }

    /// `found`, where it reads back as itself: a value written otherwise can't be.
    fn checked(c: *Compiler, node: Index, found: dte.Operand, kinds: commands.Kinds) Error!dte.Operand {
        if (!std.meta.eql(dte.Operand.read(dte.Operand.write(found), kinds), found)) return c.fail(node, "this value reads back as another, or as none", .{});
        return found;
    }

    /// Each object's slice of the trigger list: its triggers, which follow one another.
    fn slices(c: *Compiler, triggers: Triggers) Error![]?Slice {
        const found = try c.arena.alloc(?Slice, c.object_count);
        @memset(found, null);
        for (triggers.subjects, c.triggers.items, 0..) |subject, call, index| {
            const object = subject orelse continue;
            const slot = &found[object];
            if (slot.*) |*slice| {
                if (@as(usize, slice.first) + slice.count != index) return c.fail(call, "an object's triggers follow one another", .{});
                if (slice.count == std.math.maxInt(u8)) return c.fail(call, "an object has {d} triggers at most", .{std.math.maxInt(u8)});
                slice.count += 1;
            } else {
                slot.* = .{ .first = try c.narrow(u16, call, @intCast(index), "trigger"), .count = 1 };
            }
        }
        return found;
    }

    const Slice = struct { first: u16, count: u8 };

    /// The script: the blocks the triggers run, in the order the triggers first run them, then the
    /// parts' in order. Sets where each trigger's and each part's code starts.
    fn buildScript(c: *Compiler, parts: Parts, triggers: Triggers) Error![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        // The blocks the triggers run, by their functions, with the trigger whose condition gives
        // the event's values: the first that can fire, as `statements.Context.of` takes it.
        var blocks: std.AutoArrayHashMapUnmanaged(Index, usize) = .empty;
        for (triggers.functions, 0..) |function, index| {
            const node = function orelse continue;
            const slot = try blocks.getOrPut(c.arena, node);
            if (!slot.found_existing or (triggers.subjects[slot.value_ptr.*] == null and triggers.subjects[index] != null)) slot.value_ptr.* = index;
        }
        const starts = try c.arena.alloc(u16, blocks.count());
        for (blocks.keys(), blocks.values(), starts) |node, first, *start| {
            const condition = triggers.records[first].condition.descriptor();
            const context: statements.Context = .{ .event = if (condition) |found| found.values else &.{} };
            start.* = try c.routine(&bytes, node, .event, context);
        }
        for (triggers.records, triggers.functions) |*record, function| {
            if (function) |node| record.link = starts[blocks.getIndex(node).?];
        }
        for (parts.records, parts.functions) |*record, function| {
            const node = function orelse continue;
            record.offset = try c.routine(&bytes, node, .arguments, .{});
            record.length = @intCast(bytes.items.len / 2 - record.offset);
        }
        return bytes.items;
    }

    /// Writes the routine of the function `node` after `bytes`, and gives where it starts, in
    /// halfwords.
    fn routine(c: *Compiler, bytes: *std.ArrayList(u8), node: Index, parameters: code.Parameters, context: statements.Context) Error!u16 {
        const body = try code.function(c, node, parameters);
        const made = statements.bytes(c.arena, body, context) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.BranchTooFar => c.fail(node, "an `if` or a random choice here holds more code than a branch reaches", .{}),
            error.InlineTooLong => c.fail(node, "a text here is longer than {d} bytes", .{assemble.Routine.longest_text}),
            error.TooManyConstants => c.fail(node, "this code pushes more numbers than a routine holds", .{}),
            error.BlockTooLong => c.fail(node, "this code is longer than a routine holds", .{}),
            error.WrongOperands => c.fail(node, "a random choice here has more than {d} arms", .{std.math.maxInt(u8)}),
            error.BackwardBranch, error.UnplacedLabel => unreachable,
        };
        const start = bytes.items.len / 2;
        if (start + made.len / 2 >= dte.Part.no_block) return c.fail(node, "the script is longer than a mission's {d} halfwords", .{dte.Part.no_block - 1});
        try bytes.appendSlice(c.arena, made);
        return @intCast(start);
    }

    /// The object table: each ship's, flight group's and squad's entry, by its object ID, with its
    /// slice of the triggers, and an entry of no record for each that `object_index` names past
    /// them. Ship 0's entry and the curve points' are marked as the original's tools mark them.
    fn buildObjects(c: *Compiler, ships: []const dte.Ship, triggers: []const ?Slice) Error![]dte.Object {
        const objects = try c.arena.alloc(dte.Object, c.object_count);
        for (objects, triggers) |*object, slice| object.* = .{
            .kind = .ship,
            .count = if (slice) |found| found.count else 0,
            .first = if (slice) |found| found.first else dte.Object.no_triggers,
            .tool_flags = .{},
        };
        inline for (comptime std.enums.values(ObjectKind)) |kind| {
            for (c.object_ids.get(kind)) |id| objects[id].kind = @field(dte.Object.Kind, @tagName(kind));
        }
        for (ships, 0..) |ship, index| {
            const flags = &objects[ship.object_id].tool_flags;
            flags.player = index == 0;
            flags.curve_point = ship.kind == dte.Ship.curve_point_kind;
        }
        return objects;
    }
};

/// A table's fields, by their names.
const Fields = struct {
    keys: []const []const u8 = &.{},
    values: []const Index = &.{},

    fn get(given: Fields, key: []const u8) ?Index {
        for (given.keys, given.values) |name, value| if (std.mem.eql(u8, name, key)) return value;
        return null;
    }
};

/// Names as a message lists them: `a`, `b` and `c`.
const Listed = struct {
    names: []const []const u8,

    pub fn format(listed: Listed, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (listed.names, 0..) |name, index| {
            const separator = if (index == 0) "" else if (index + 1 == listed.names.len) " and " else ", ";
            try writer.print("{s}`{s}`", .{ separator, name });
        }
    }
};

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

/// The string pool (`dte.write.Strings`), which the source's display names go in.
const Pool = struct {
    strings: dte.write.Strings = .{},

    fn add(pool: *Pool, c: *Compiler, node: Index) Error!u16 {
        return pool.strings.add(c.arena, try c.string(node)) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.HoldsNul => c.fail(node, "a name can't hold a NUL", .{}),
            error.Full => c.fail(node, "the names fill the string pool, which counts {d} bytes", .{std.math.maxInt(u16)}),
        };
    }
};
