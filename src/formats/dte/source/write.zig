//! A mission as Luau source text, as `sltool dte decompile` writes it
//! ([Mission source](../../../../docs/formats/mission-source.md)): its records as declarations, in
//! the order of their tables, then its triggers and its parts with their code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const dte = @import("../../dte.zig");
const decompile = @import("../decompile.zig");
const bind = @import("../../../engine/game/mission/bind.zig");
const conditions = @import("../../../engine/vm/conditions.zig");
const names = @import("names.zig");
const script = @import("script.zig");
const vocabulary = @import("vocabulary.zig");
const Word = names.Word;
const indexed = script.indexed;

pub const Error = Writer.Error || Allocator.Error || dte.Error || decompile.Error;

/// Writes `mission` as source, allocating with `arena`.
pub fn write(writer: *Writer, arena: Allocator, mission: dte.Mission) Error!void {
    var source: Source = try .init(arena, mission);
    try source.write(writer);
}

/// The longest line a declaration's fields keep to before they go on lines of their own.
const line_length = 100;

const Source = struct {
    arena: Allocator,
    mission: dte.Mission,
    ships: []align(1) const dte.Ship,
    flight_groups: []align(1) const dte.FlightGroup,
    squads: []align(1) const dte.Squad,
    formations: []align(1) const dte.Formation,
    points: []align(1) const dte.FormationPoint,
    curves: []align(1) const dte.Curve,
    globals: []align(1) const dte.Global,
    parts: []align(1) const dte.Part,
    triggers: []align(1) const dte.Trigger,
    /// The object each trigger belongs to, by its object ID, where an object's slice holds it.
    owners: []const ?u16,
    routines: []const dte.Routine,
    record_names: script.Names,
    formation_names: []const []const u8,
    /// Each formation's points, by their indices (`dte.Mission.pointsOf`).
    formation_points: []const []const u16,
    /// The names of each condition's event values, by condition.
    events: [conditions.table.len][]const []const u8,
    /// The name of each block that more than one trigger runs, by the block's place in the script.
    handlers: std.AutoArrayHashMapUnmanaged(usize, []const u8) = .empty,
    namer: names.Namer,

    fn init(arena: Allocator, mission: dte.Mission) Error!Source {
        var source: Source = .{
            .arena = arena,
            .mission = mission,
            .ships = try mission.ships(),
            .flight_groups = try mission.flightGroups(),
            .squads = try mission.squads(),
            .formations = try mission.formations(),
            .points = try mission.formationPoints(),
            .curves = try mission.curves(),
            .globals = try mission.globals(),
            .parts = try mission.parts(),
            .triggers = try mission.triggers(),
            .owners = try mission.triggerObjects(arena),
            .routines = try mission.routines(arena),
            .record_names = .{},
            .formation_names = &.{},
            .formation_points = &.{},
            .events = undefined,
            .namer = .init(arena),
        };
        // The script names events' values after their labels, which no record may take.
        for (&source.events, conditions.table) |*event, condition| {
            event.* = try script.eventNames(arena, condition.values);
            for (event.*) |value| try source.namer.reserve(value);
        }
        source.record_names = .{
            .ships = try source.nameAll(dte.Ship, source.ships, .ship),
            .flight_groups = try source.nameAll(dte.FlightGroup, source.flight_groups, .flight_group),
            .squads = try source.nameAll(dte.Squad, source.squads, .squad),
            .curves = try source.nameCurves(),
            .globals = try source.nameAll(dte.Global, source.globals, .global),
            .parts = try source.nameAll(dte.Part, source.parts, .part),
            .objects = try source.objectNames(),
        };
        source.formation_names = try source.nameAll(dte.Formation, source.formations, .formation);
        const points = try arena.alloc([]const u16, source.formations.len);
        for (points, 0..) |*list, index| list.* = try mission.pointsOf(arena, index);
        source.formation_points = points;
        try source.nameHandlers();
        return source;
    }

    /// Names each of `records`, declared with `constructor`, after its display name.
    fn nameAll(source: *Source, comptime Record: type, records: []align(1) const Record, constructor: Word) Allocator.Error![]const []const u8 {
        const list = try source.arena.alloc([]const u8, records.len);
        for (list, records, 0..) |*item, record, index| item.* = try source.namer.name(source.mission.name(record.name), @tagName(constructor), index);
        return list;
    }

    /// Names the curves, which have no display names, by their index.
    fn nameCurves(source: *Source) Allocator.Error![]const []const u8 {
        const list = try source.arena.alloc([]const u8, source.curves.len);
        for (list, 0..) |*item, index| item.* = try source.namer.name("", @tagName(Word.curve), index);
        return list;
    }

    /// The name of each object's record, by its object ID: the ship's, the flight group's or the
    /// squad's the game takes it for (`mission.bind.resolveObjects`).
    fn objectNames(source: *Source) Error![]const ?[]const u8 {
        const records = try bind.resolveObjects(source.arena, source.mission);
        const list = try source.arena.alloc(?[]const u8, records.len);
        for (list, records) |*name, record| name.* = if (record) |found| switch (found) {
            .ship => |index| source.record_names.ships[index],
            .flight_group => |index| source.record_names.flight_groups[index],
            .squad => |index| source.record_names.squads[index],
        } else null;
        return list;
    }

    /// Names each block more than one trigger runs, after its first trigger's subject and
    /// condition.
    fn nameHandlers(source: *Source) Error!void {
        var counts: std.AutoArrayHashMapUnmanaged(usize, usize) = .empty;
        for (source.triggers) |trigger| {
            const start = trigger.block() orelse continue;
            if (source.routineAt(start) == null) continue;
            const slot = try counts.getOrPut(source.arena, start);
            slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
        }
        for (source.triggers, source.owners, 0..) |trigger, owner, index| {
            const start = trigger.block() orelse continue;
            if ((counts.get(start) orelse 0) < 2 or source.handlers.contains(start)) continue;
            const subject = if (owner) |object| source.record_names.objects[object] orelse "" else "";
            const condition = vocabulary.name(.condition, @backingInt(trigger.condition)) orelse "";
            const display = try std.fmt.allocPrint(source.arena, "{s} {s}", .{ subject, condition });
            try source.handlers.put(source.arena, start, try source.namer.name(display, @tagName(Word.handler), index));
        }
    }

    /// The block a trigger runs that starts at `start` in the script, where one does.
    fn routineAt(source: Source, start: usize) ?dte.Routine {
        for (source.routines) |routine| {
            if (routine.start == start and routine.owner == .triggers) return routine;
        }
        return null;
    }

    fn write(source: *Source, w: *Writer) Error!void {
        if (source.mission.openReliantName()) |name| {
            try w.print("{t}({{ name = ", .{Word.mission});
            try script.writeString(w, name);
            try w.writeAll(" })\n");
        }
        try source.writeGlobals(w);
        try source.writeFlightGroups(w);
        try source.writeShips(w);
        try source.writeSquads(w);
        try source.writeFormations(w);
        try source.writeCurves(w);
        try source.writeHandlers(w);
        try source.writeTriggers(w);
        try source.writeParts(w);
    }

    /// A blank line and `title` as a comment, where `count` records follow.
    fn heading(w: *Writer, title: []const u8, count: usize) Writer.Error!void {
        if (count > 0) try w.print("\n-- {s}\n\n", .{title});
    }

    /// `name = constructor("display"`, the start of a declaration, and the characters it takes.
    fn open(source: *Source, w: *Writer, name: []const u8, constructor: Word, display: u16) Writer.Error!usize {
        var line: Writer.Allocating = .init(source.arena);
        try line.writer.print("{s} = {t}(", .{ name, constructor });
        try script.writeString(&line.writer, source.mission.name(display));
        try w.writeAll(line.written());
        return line.written().len;
    }

    /// `name = constructor("display", { fields })`, or without fields where it has none.
    fn declare(source: *Source, w: *Writer, name: []const u8, constructor: Word, display: u16, fields: *const Fields) Error!void {
        const column = try source.open(w, name, constructor, display);
        if (fields.list.items.len > 0) {
            try w.writeAll(", ");
            try fields.write(w, column + ", ".len, ")".len);
        }
        try w.writeAll(")\n");
    }

    fn writeGlobals(source: *Source, w: *Writer) Error!void {
        try heading(w, "Globals", source.globals.len);
        for (source.globals, source.record_names.globals) |global, name| {
            _ = try source.open(w, name, .global, global.name);
            try w.print(", {d})\n", .{global.value});
        }
    }

    fn writeFlightGroups(source: *Source, w: *Writer) Error!void {
        try heading(w, "Flight groups", source.flight_groups.len);
        for (source.flight_groups, source.record_names.flight_groups) |group, name| {
            var fields: Fields = .init(source.arena);
            if (group.wing != .none) {
                if (std.enums.tagName(dte.FlightGroup.Wing, group.wing)) |wing| {
                    try fields.add("wing", "\"{s}\"", .{wing});
                } else {
                    try fields.add("wing", "{d}", .{@backingInt(group.wing)});
                }
            }
            if (group.formation.index != dte.Reference.unset) try fields.add("formation", "{f}", .{indexed(source.formation_names, group.formation.index, .formation_index)});
            try source.declare(w, name, .flight_group, group.name, &fields);
        }
    }

    fn writeShips(source: *Source, w: *Writer) Error!void {
        try heading(w, "Ships", source.ships.len);
        for (source.ships, source.record_names.ships) |ship, name| {
            var fields: Fields = .init(source.arena);
            const constructor: Word = switch (ship.kind) {
                dte.Ship.nav_point_kind => .nav_point,
                dte.Ship.waypoint_kind => .waypoint,
                dte.Ship.point_kind => .point,
                dte.Ship.curve_point_kind => .curve_point,
                else => constructor: {
                    try fields.add("type", "{f}", .{named(.ship_type, ship.kind)});
                    break :constructor .ship;
                },
            };
            if (ship.flightGroup()) |group| try fields.add("group", "{f}", .{indexed(source.record_names.flight_groups, group, .flight_group_index)});
            if (ship.pilotRecord()) |pilot| try fields.add("pilot", "{f}", .{named(.pilot, pilot)});
            if (!std.mem.allEqual(f32, &ship.position, 0)) try fields.add("position", "{f}", .{vector(ship.position)});
            if (ship.yaw != 0) try fields.add("yaw", "{d}", .{ship.yaw});
            if (ship.pitch != 0) try fields.add("pitch", "{d}", .{ship.pitch});
            if (ship.roll != 0) try fields.add("roll", "{d}", .{ship.roll});
            if (ship.launchGate()) |gate| try fields.add("launch", "{{ from = {f}, gate = {d} }}", .{ named(.ship_type, ship.launch_from), gate });
            if (ship.formationPoint()) |point| try fields.add("formation_point", "{s}", .{try source.pointName(point)});
            if (ship.tier != dte.Ship.campaign_tier) try fields.add("tier", "{d}", .{ship.tier});
            if (ship.markedCurve()) |curve| try fields.add("marker", "{{ curve = {f}, at = {f} }}", .{ indexed(source.record_names.curves, curve, .curve_index), number(ship.marker_at) });
            try source.declare(w, name, constructor, ship.name, &fields);
        }
    }

    fn writeSquads(source: *Source, w: *Writer) Error!void {
        try heading(w, "Squads", source.squads.len);
        for (source.squads, source.record_names.squads, 0..) |squad, name, index| {
            var members: std.ArrayList([]const u8) = .empty;
            for (try source.mission.membersOf(index)) |member| {
                const object = source.record_names.object(member.object_id);
                try members.append(source.arena, if (member.part()) |component|
                    try std.fmt.allocPrint(source.arena, "{t}({f}, {d})", .{ Word.component, object, component })
                else
                    try std.fmt.allocPrint(source.arena, "{f}", .{object}));
            }
            try writeList(w, members.items, try source.open(w, name, .squad, squad.name));
        }
    }

    fn writeFormations(source: *Source, w: *Writer) Error!void {
        try heading(w, "Formations", source.formations.len);
        for (source.formations, source.formation_names, source.formation_points) |formation, name, list| {
            var points: std.ArrayList([]const u8) = .empty;
            for (list) |point| try points.append(source.arena, try std.fmt.allocPrint(source.arena, "{f}", .{vector(source.points[point].offset)}));
            try writeList(w, points.items, try source.open(w, name, .formation, formation.name));
        }
    }

    fn writeCurves(source: *Source, w: *Writer) Error!void {
        try heading(w, "Curves", source.curves.len);
        for (source.curves, source.record_names.curves) |curve, name| {
            const ships = source.record_names.ships;
            var fields: Fields = .init(source.arena);
            if (curve.startShip()) |ship| try fields.add("start", "{f}", .{indexed(ships, ship, .ship_index)});
            if (curve.endShip()) |ship| try fields.add("finish", "{f}", .{indexed(ships, ship, .ship_index)});
            try fields.add("from", "{f}", .{vector(curve.from)});
            try fields.add("to", "{f}", .{vector(curve.to)});
            if (curve.leaving_handle.index != dte.Reference.unset) try fields.add("leaving_handle", "{f}", .{indexed(ships, curve.leaving_handle.index, .ship_index)});
            if (curve.arriving_handle.index != dte.Reference.unset) try fields.add("arriving_handle", "{f}", .{indexed(ships, curve.arriving_handle.index, .ship_index)});
            try fields.add("leaving", "{f}", .{vector(curve.leaving)});
            try fields.add("arriving", "{f}", .{vector(curve.arriving)});
            try w.print("{s} = {t}(", .{ name, Word.curve });
            try fields.write(w, name.len + " = curve(".len, ")".len);
            try w.writeAll(")\n");
        }
    }

    fn writeHandlers(source: *Source, w: *Writer) Error!void {
        try heading(w, "Code more than one trigger runs", source.handlers.count());
        for (source.handlers.keys(), source.handlers.values()) |start, name| {
            const routine = source.routineAt(start).?;
            const condition = source.triggers[routine.owner.triggers[0]].condition;
            try w.print("{s} = {t}(", .{ name, Word.handler });
            try source.function(w, routine, .{ .event = source.eventsOf(condition) }, 0);
            try w.writeAll(")\n");
        }
    }

    fn eventsOf(source: Source, condition: dte.Condition) []const []const u8 {
        const index = @backingInt(condition);
        return if (index < source.events.len) source.events[index] else &.{};
    }

    fn writeTriggers(source: *Source, w: *Writer) Error!void {
        try heading(w, "Triggers", source.triggers.len);
        for (source.triggers, source.owners) |trigger, owner| {
            const subject: script.Indexed = if (owner) |object| source.record_names.object(object) else .{ .name = "nil" };
            const head = try std.fmt.allocPrint(source.arena, "{t}({f}, {f}", .{ Word.on, subject, named(.condition, @backingInt(trigger.condition)) });
            var fields: Fields = .init(source.arena);
            switch (trigger.repeat) {
                .once => {},
                .always => try fields.add("repeats", "\"always\"", .{}),
                .counted => if (trigger.repeat_counter == trigger.repeat_count)
                    try fields.add("repeats", "{{ counted = {d} }}", .{trigger.repeat_count})
                else
                    try fields.add("repeats", "{{ counted = {d}, left = {d} }}", .{ trigger.repeat_count, trigger.repeat_counter }),
                _ => try fields.add("repeats", "{d}", .{@backingInt(trigger.repeat)}),
            }
            if (trigger.component()) |component| try fields.add("component", "{d}", .{component});
            if (trigger.deferred != 0) try fields.add("deferred", "true", .{});
            try source.filters(&fields, trigger);
            const code = source.triggerCode(trigger, owner);
            const event = source.eventsOf(trigger.condition);
            try w.writeAll(head);
            if (fields.list.items.len > 0) {
                // What follows the fields on their line: the code's first line, or the bracket.
                const after = switch (code) {
                    .none => ")".len,
                    .handler => |name| ", ".len + name.len + ")".len,
                    .function => ", function()".len + parametersLength(event),
                };
                try w.writeAll(", ");
                try fields.write(w, head.len + ", ".len, after);
            }
            switch (code) {
                .none => {},
                .handler => |name| try w.print(", {s}", .{name}),
                .function => |routine| {
                    // A function that doesn't fit after the subject and the condition starts a line
                    // of its own.
                    const own_line = fields.list.items.len == 0 and head.len + ", function()".len + parametersLength(event) > line_length;
                    try w.writeAll(if (own_line) ",\n    " else ", ");
                    try source.function(w, routine, .{ .event = event }, @intFromBool(own_line));
                },
            }
            try w.writeAll(")\n");
        }
    }

    /// The code a trigger runs: the block it shares with other triggers, by its handler's name,
    /// or its own, where it can fire and has one.
    const Code = union(enum) {
        none,
        handler: []const u8,
        function: dte.Routine,
    };

    fn triggerCode(source: *Source, trigger: dte.Trigger, owner: ?u16) Code {
        const start = trigger.block() orelse return .none;
        if (source.handlers.get(start)) |handler| return .{ .handler = handler };
        if (owner == null) return .none;
        return .{ .function = source.routineAt(start) orelse return .none };
    }

    /// The characters a function's parameters `names` take, with the commas between them.
    fn parametersLength(parameter_names: []const []const u8) usize {
        var length: usize = 0;
        for (parameter_names, 0..) |name, index| length += name.len + @as(usize, if (index > 0) ", ".len else 0);
        return length;
    }

    /// The values a trigger's event must have, by their names, for the values its condition
    /// checks.
    fn filters(source: *Source, fields: *Fields, trigger: dte.Trigger) Error!void {
        const condition = trigger.condition.descriptor() orelse return;
        const event = source.eventsOf(trigger.condition);
        for (condition.values, event, 0..) |value, name, slot| {
            if (!value.checked or slot >= trigger.operands.len) continue;
            switch (dte.Operand.read(trigger.operands[slot], value.kinds)) {
                .unset => {},
                .number => |known| try fields.add(name, "{d}", .{known}),
                .any_ship => try fields.add(name, "{t}", .{Word.any_ship}),
                .ship => |index| try fields.add(name, "{f}", .{indexed(source.record_names.ships, index, .ship_index)}),
                .flight_group => |index| try fields.add(name, "{f}", .{indexed(source.record_names.flight_groups, index, .flight_group_index)}),
                .squad => |index| try fields.add(name, "{f}", .{indexed(source.record_names.squads, index, .squad_index)}),
                .other => |known| try fields.add(name, "{d}", .{known}),
            }
        }
    }

    fn writeParts(source: *Source, w: *Writer) Error!void {
        try heading(w, "Parts", source.parts.len);
        for (source.parts, source.record_names.parts, 0..) |part, name, index| {
            _ = try source.open(w, name, .part, part.name);
            const routine = for (source.routines) |routine| {
                if (routine.owner == .part and routine.owner.part == index) break routine;
            } else null;
            if (routine) |found| {
                try w.writeAll(", ");
                try source.function(w, found, .{ .arguments = part.arguments }, 0);
            } else if (part.flags.start) {
                try w.writeAll(", nil");
            }
            if (part.flags.start) try w.writeAll(", { start = true }");
            try w.writeAll(")\n");
        }
    }

    /// What a function's parameters are: the values of a trigger's event, or a part's arguments.
    const Parameters = union(enum) {
        event: []const []const u8,
        arguments: u8,
    };

    /// A function of `routine`'s statements, with `parameters`, whose `end` is indented `depth`
    /// levels.
    fn function(source: *Source, w: *Writer, routine: dte.Routine, parameters: Parameters, depth: usize) Error!void {
        try w.writeAll("function(");
        switch (parameters) {
            .event => |event| for (event, 0..) |name, index| try w.print("{s}{s}", .{ if (index > 0) ", " else "", name }),
            .arguments => |count| try script.writeParameters(w, count),
        }
        try w.writeAll(")\n");
        const body = try decompile.routine(source.arena, source.mission, routine);
        const event = switch (parameters) {
            .event => |names_of_values| names_of_values,
            .arguments => &.{},
        };
        try script.write(w, body, &source.record_names, .{ .event = event }, depth + 1);
        try w.splatByteAll(' ', 4 * depth);
        try w.writeAll("end");
    }

    /// Point `point` of `formation_points` as its formation's name indexed by its place among the
    /// formation's points, from 1, or by its index where it is none of its formation's.
    fn pointName(source: Source, point: u16) Allocator.Error![]const u8 {
        if (point < source.points.len) {
            const formation = source.points[point].formation;
            if (formation < source.formations.len) {
                if (std.mem.findScalar(u16, source.formation_points[formation], point)) |place| {
                    return std.fmt.allocPrint(source.arena, "{s}[{d}]", .{ source.formation_names[formation], place + 1 });
                }
            }
        }
        return std.fmt.allocPrint(source.arena, "{t}({d})", .{ Word.formation_point_index, point });
    }
};

/// `, { a, b })` and a new line: a declaration's list and its end, after `column` characters of
/// its line, or with an item to a line where it doesn't fit there. `, {})` for an empty one.
fn writeList(w: *Writer, items: []const []const u8, column: usize) Writer.Error!void {
    try w.writeAll(", ");
    try writeTable(w, items, column + ", ".len, ")".len);
    try w.writeAll(")\n");
}

/// `items` as a table, `{ a, b }`, starting `column` characters into its line, with `after`
/// characters after it on the line: on that line where it fits, or with an item to a line.
fn writeTable(w: *Writer, items: []const []const u8, column: usize, after: usize) Writer.Error!void {
    if (items.len == 0) return w.writeAll("{}");
    var length = column + "{  }".len + after;
    for (items, 0..) |item, index| length += item.len + @as(usize, if (index > 0) ", ".len else 0);
    if (length > line_length) {
        try w.writeAll("{\n");
        for (items) |item| try w.print("    {s},\n", .{item});
        return w.writeAll("}");
    }
    try w.writeAll("{ ");
    for (items, 0..) |item, index| try w.print("{s}{s}", .{ if (index > 0) ", " else "", item });
    try w.writeAll(" }");
}

/// A value the game names, by its name as a string, or its number where it has none.
const Named = struct {
    kind: vocabulary.Kind,
    value: u32,

    pub fn format(named_value: Named, w: *Writer) Writer.Error!void {
        if (vocabulary.name(named_value.kind, named_value.value)) |name| return w.print("\"{s}\"", .{name});
        try w.print("{d}", .{named_value.value});
    }
};

fn named(kind: vocabulary.Kind, value: u32) Named {
    return .{ .kind = kind, .value = value };
}

/// A number as Luau writes it: the shortest that reads back as the same `f32`, with an exponent
/// from `exponent_from` on, and `0/0`, `1/0` and `-1/0` for those Luau has no literal for.
const Number = struct {
    value: f32,

    /// The smallest number written with an exponent, 2^53. From there on a double holds only some
    /// whole numbers, and Luau warns about one written in digits that it can't hold exactly.
    const exponent_from: f32 = 1 << (std.math.floatMantissaBits(f64) + 1);

    pub fn format(shown: Number, w: *Writer) Writer.Error!void {
        if (std.math.isNan(shown.value)) return w.writeAll("0/0");
        if (std.math.isInf(shown.value)) return w.writeAll(if (shown.value > 0) "1/0" else "-1/0");
        if (@abs(shown.value) >= exponent_from) return w.print("{e}", .{shown.value});
        try w.print("{d}", .{shown.value});
    }
};

fn number(value: f32) Number {
    return .{ .value = value };
}

/// A place as `{ x, y, z }`.
const Vector = struct {
    value: [3]f32,

    pub fn format(shown: Vector, w: *Writer) Writer.Error!void {
        try w.print("{{ {f}, {f}, {f} }}", .{ number(shown.value[0]), number(shown.value[1]), number(shown.value[2]) });
    }
};

fn vector(value: [3]f32) Vector {
    return .{ .value = value };
}

/// A declaration's fields, which go on its line where they fit, and on lines of their own where
/// they don't.
const Fields = struct {
    arena: Allocator,
    /// Each field as it is written: `name = value`.
    list: std.ArrayList([]const u8) = .empty,

    fn init(arena: Allocator) Fields {
        return .{ .arena = arena };
    }

    fn add(fields: *Fields, key: []const u8, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try fields.list.append(fields.arena, try std.fmt.allocPrint(fields.arena, "{s} = " ++ format, .{key} ++ args));
    }

    /// Writes the fields as a table (`writeTable`).
    fn write(fields: Fields, w: *Writer, column: usize, after: usize) Writer.Error!void {
        try writeTable(w, fields.list.items, column, after);
    }
};

test Number {
    var buffer: [32]u8 = undefined;
    for ([_]struct { f32, []const u8 }{
        .{ 300.5, "300.5" },
        .{ -11608147, "-11608147" },
        // From 2^53 on, with an exponent, which Luau reads without a warning.
        .{ -1.701416e38, "-1.701416e38" },
        .{ std.math.nan(f32), "0/0" },
        .{ -std.math.inf(f32), "-1/0" },
    }) |case| {
        var w: Writer = .fixed(&buffer);
        try w.print("{f}", .{number(case[0])});
        try std.testing.expectEqualStrings(case[1], w.buffered());
    }
}

test write {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const executor = @import("../../../engine/game/executor.zig");
    const gameobj = @import("../../../engine/game/gameobj.zig");
    const statements = @import("../statements.zig");

    // A ship and a nav point, a flight group, a global, a trigger on the ship and a start part.
    const pool = "Player\x00Nav\x00(FG)Alpha\x00(GV)done\x00(F)start\x00";
    // The records hold none where the shipped ones do: no formation point, and no formation.
    var player = dte.testing.ship(0, 0, @intCast(@backingInt(gameobj.GameType.grendel)));
    player.position = .{ 100, 200, 300 };
    player.yaw = 90;
    player.formation_point = dte.Ship.no_formation_point;
    var nav = dte.testing.ship(1, dte.Ship.no_flight_group, dte.Ship.nav_point_kind);
    nav.name = 7;
    nav.yaw = 45;
    nav.formation_point = dte.Ship.no_formation_point;
    var group = dte.testing.flightGroup(2, .player);
    group.name = 11;
    group.formation = dte.FlightGroup.no_formation;
    var global = std.mem.zeroes(dte.Global);
    global.name = 21;
    var trigger = std.mem.zeroes(dte.Trigger);
    trigger.condition = .destroyed;
    trigger.qualifier = dte.Trigger.whole_object;
    trigger.operands = @splat(std.math.maxInt(u32));
    const block = try statements.bytes(arena, &.{
        .{ .assign = .{ .target = .{ .global = 0 }, .update = .assign, .value = .{ .number = 1 } } },
        .{ .@"return" = .{ .number = 1 } },
    }, .{});
    const routine = try statements.bytes(arena, &.{
        .{ .command = .{ .index = executor.commandIndex("Wait"), .arguments = &.{.{ .number = 3 }} } },
        .{ .@"return" = .{ .number = 1 } },
    }, .{});
    var part = std.mem.zeroes(dte.Part);
    part.name = 30;
    part.offset = @intCast(block.len / 2);
    part.length = @intCast(routine.len / 2);
    part.flags.start = true;
    const code = try std.mem.concat(arena, u8, &.{ block, routine });

    var sections: dte.write.Sections = @splat(.{});
    dte.write.set(&sections, .strings, pool.len, pool);
    dte.write.set(&sections, .ships, 2, std.mem.sliceAsBytes(&[_]dte.Ship{ player, nav }));
    dte.write.set(&sections, .flight_groups, 1, std.mem.asBytes(&group));
    dte.write.set(&sections, .globals, 1, std.mem.asBytes(&global));
    dte.write.set(&sections, .triggers, 1, std.mem.asBytes(&trigger));
    dte.write.set(&sections, .objects, 3, std.mem.sliceAsBytes(&[_]dte.Object{
        dte.testing.object(.ship, 0, 1),
        dte.testing.object(.ship, 0, 0),
        dte.testing.object(.flight_group, 0, 0),
    }));
    dte.write.set(&sections, .parts, 1, std.mem.asBytes(&part));
    dte.write.set(&sections, .script, code.len / 2, code);
    const mission: dte.Mission = try .parse(try dte.write.write(arena, &sections, .{}));

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(&out.writer, arena, mission);
    try std.testing.expectEqualStrings(
        \\
        \\-- Globals
        \\
        \\done = global("(GV)done", 0)
        \\
        \\-- Flight groups
        \\
        \\alpha = flight_group("(FG)Alpha", { wing = "player" })
        \\
        \\-- Ships
        \\
        \\player = ship("Player", { type = "grendel", group = alpha, position = { 100, 200, 300 }, yaw = 90 })
        \\nav = nav_point("Nav", { yaw = 45 })
        \\
        \\-- Triggers
        \\
        \\on(player, "destroyed", function(killer, victim)
        \\    done = 1
        \\    return 1
        \\end)
        \\
        \\-- Parts
        \\
        \\start = part("(F)start", function()
        \\    Wait(3)
        \\    return 1
        \\end, { start = true })
        \\
    , out.written());
}
