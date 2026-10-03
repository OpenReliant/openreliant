//! `sltool dte ...`: read `.DTE` mission files.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const dte = openreliant.dte;

const sltool = @import("main.zig");
const Context = sltool.Context;
const Library = @import("library.zig").Library;

pub const Command = union(enum) {
    info: struct { mission: []const u8 },
    /// The 27-entry directory.
    sections: struct { mission: []const u8 },
    ships: struct { mission: []const u8 },
    triggers: struct { mission: []const u8 },
    strings: struct { mission: []const u8 },
    /// Lists the script's named routines.
    parts: struct { mission: []const u8 },
    /// Disassembles the script bytecode.
    script: struct { mission: []const u8 },
    /// Writes the mission and its script again, and checks they come back the same.
    check: struct { mission: []const u8 },

    pub const usage =
        \\  dte info <mission>              summarise a mission
        \\  dte sections <mission>          list the 27-section directory
        \\  dte ships <mission>             list the placed ships and nav points
        \\  dte triggers <mission>          list the scripted triggers
        \\  dte strings <mission>           dump the string pool
        \\  dte parts <mission>             list the script's named routines
        \\  dte script <mission>            disassemble the script bytecode
        \\  dte check <mission>             write the mission and its script again, and check that
        \\                                  they come back the same
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        return switch (verb) {
            inline else => |tag| sltool.positional(Command, tag, operands),
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        const path = switch (command) {
            inline else => |operands| operands.mission,
        };
        const image = try ctx.readInput(path);
        const mission: dte.Mission = try .parse(image);
        // Models, for naming components, are looked for beside the mission.
        var library: ?Library = Library.beside(ctx, path) catch null;
        defer if (library) |*found| found.deinit();
        const models: ?*Library = if (library) |*found| found else null;

        switch (command) {
            .info => try info(ctx, mission),
            .sections => try sections(ctx, mission),
            .ships => try ships(ctx, mission),
            .triggers => try triggers(ctx, mission, models),
            .strings => try strings(ctx, mission),
            .parts => try parts(ctx, mission),
            .script => try script(ctx, mission, models),
            .check => try check(ctx, mission),
        }
    }
};

fn info(ctx: Context, mission: dte.Mission) !void {
    const ship_list = try mission.ships();
    var named: usize = 0;
    for (ship_list) |ship| {
        if (mission.name(ship.name).len > 0) named += 1;
    }
    const player: ?[]const u8 = if (try mission.player()) |ship| mission.name(ship.name) else null;

    try ctx.stdout.print(
        \\image:     {Bi:.1}
        \\ships:     {d} ({d} named)
        \\triggers:  {d}
        \\globals:   {d}
        \\strings:   {d} in a {d}-byte pool
        \\script:    {d} bytes
        \\
    , .{
        mission.image.len,
        ship_list.len,
        named,
        (try mission.triggers()).len,
        (try mission.globals()).len,
        mission.entry(.strings).count,
        mission.stringPoolEnd() -| mission.entry(.strings).offset,
        (try mission.script()).len,
    });
    if (player) |name| try ctx.stdout.print("player:    {s}\n", .{name});
}

fn sections(ctx: Context, mission: dte.Mission) !void {
    try ctx.stdout.writeAll("  #  count  flags    offset  section\n");
    for (mission.directory, 0..) |entry, i| {
        const section: dte.Section = @enumFromInt(i);
        if (!entry.isUsed()) {
            try ctx.stdout.print("{d:>3}  {s:>5}  {s:>5}  {s:>8}  ", .{ i, "-", "-", "unused" });
        } else {
            try ctx.stdout.print("{d:>3}  {d:>5}   0x{x:0>2}  {x:0>8}  ", .{
                i, entry.count, entry.formats.byte(), entry.offset,
            });
        }
        try openreliant.layout.formatTag(dte.Section, section, ctx.stdout);
        try ctx.stdout.writeByte('\n');
    }
}

fn ships(ctx: Context, mission: dte.Mission) !void {
    try ctx.stdout.writeAll("index  object  group  pilot  kind  name                           position                                  yaw  pitch  roll\n");
    for (try mission.ships(), 0..) |ship, i| {
        var group: [4]u8 = undefined;
        var pilot: [4]u8 = undefined;
        try ctx.stdout.print("{d:>5}  {d:>6}  {s:>5}  {s:>5}  {d:>4}  {s:<30} ({d:>12.0}, {d:>12.0}, {d:>12.0})  {d:>4}  {d:>5}  {d:>4}{s}\n", .{
            i,
            ship.object_id,
            if (ship.flightGroup()) |in_group|
                std.fmt.bufPrint(&group, "{d}", .{in_group}) catch "?"
            else
                "-",
            if (ship.pilotRecord()) |flown_by|
                std.fmt.bufPrint(&pilot, "{d}", .{flown_by}) catch "?"
            else
                "-",
            ship.kind,
            mission.name(ship.name),
            ship.position[0],
            ship.position[1],
            ship.position[2],
            ship.yaw,
            ship.pitch,
            ship.roll,
            if (ship.flags.destroyed) "  destroyed" else "",
        });
    }
}

fn triggers(ctx: Context, mission: dte.Mission, models: ?*Library) !void {
    const owners = try mission.triggerObjects(ctx.arena);
    const all_objects = try mission.objects();
    const all_ships = try mission.ships();
    try ctx.stdout.writeAll("index  condition                   component  repeat   start  block  subject\n");
    for (try mission.triggers(), owners, 0..) |trigger, owner, i| {
        // A custom formatter does not pad, so render into a buffer to keep the columns straight.
        var condition: [28]u8 = undefined;
        var repeat: [8]u8 = undefined;
        var qualifier: [4]u8 = undefined;
        var block: [8]u8 = undefined;
        try ctx.stdout.print("{d:>5}  {s:<26}  {s:>9}  {s:<7}  {s:<5}  {s:>5}  ", .{
            i,
            std.fmt.bufPrint(&condition, "{f}", .{trigger.condition}) catch "?",
            if (trigger.component()) |component|
                std.fmt.bufPrint(&qualifier, "{d}", .{component}) catch "?"
            else
                "-",
            std.fmt.bufPrint(&repeat, "{f}", .{trigger.repeat}) catch "?",
            if (trigger.deferred == 0) "now" else "later",
            if (trigger.block()) |at| std.fmt.bufPrint(&block, "{d}", .{at}) catch "?" else "-",
        });
        const id = owner orelse {
            try ctx.stdout.writeAll("none, so it never fires\n");
            continue;
        };
        const kind = if (id < all_objects.len) all_objects[id].kind else @as(dte.Object.Kind, @enumFromInt(0xFF));
        try ctx.stdout.print("{f} {d}", .{ kind, id });
        if (kind == .ship) {
            for (all_ships) |ship| {
                if (ship.object_id == id) {
                    try ctx.stdout.print("  {s}", .{mission.name(ship.name)});
                    if (trigger.component()) |component| {
                        try ctx.stdout.writeAll(", component");
                        try printComponent(ctx, models, ship, component);
                    }
                    break;
                }
            }
        }
        try printOperands(ctx, mission, trigger);
        try ctx.stdout.writeByte('\n');
    }
}

/// The trigger's set operands, labelled with the values of its condition they stand for.
fn printOperands(ctx: Context, mission: dte.Mission, trigger: dte.Trigger) !void {
    const condition = trigger.condition.descriptor() orelse return;
    var first = true;
    for (condition.values, trigger.operands[0..condition.values.len]) |value, raw| {
        const operand: dte.Operand = .read(raw, value.kinds);
        if (operand == .unset) continue;
        try ctx.stdout.print("{s}{s}=", .{ if (first) "  " else ", ", value.label });
        first = false;
        switch (operand) {
            .unset => unreachable,
            .number => |number| try ctx.stdout.print("{d}", .{number}),
            .any_ship => try ctx.stdout.writeAll("any ship"),
            .ship => |index| try printShip(ctx, mission, index),
            .flight_group => |index| try printFlightGroup(ctx, mission, index),
            .squad => |index| try printSquad(ctx, mission, index),
            .other => |bits| try ctx.stdout.print("0x{X:0>8}", .{bits}),
        }
    }
}

/// A referenced ship, by object ID as the subject column shows it.
fn printShip(ctx: Context, mission: dte.Mission, index: u16) !void {
    const all = try mission.ships();
    if (index >= all.len) return ctx.stdout.print("ship #{d}, out of range", .{index});
    const ship = all[index];
    try ctx.stdout.print("ship {d} {s}", .{ ship.object_id, mission.name(ship.name) });
}

/// A referenced flight group, by object ID as the subject column shows it.
fn printFlightGroup(ctx: Context, mission: dte.Mission, index: u16) !void {
    const all = try mission.flightGroups();
    if (index >= all.len) return ctx.stdout.print("flight group #{d}, out of range", .{index});
    try ctx.stdout.print("flight_group {d}", .{all[index].object_id});
}

/// A referenced squad, by object ID as the subject column shows it.
fn printSquad(ctx: Context, mission: dte.Mission, index: u16) !void {
    const all = try mission.squads();
    if (index >= all.len) return ctx.stdout.print("squad #{d}, out of range", .{index});
    try ctx.stdout.print("squad {d}", .{all[index].object_id});
}

/// Decodes the first block of the script section.
///
/// Blocks are entered by address, so only the one at the start of the section can be found without
/// the part table; the rest are reached by `call_part`.
fn parts(ctx: Context, mission: dte.Mission) !void {
    const code = try mission.script();
    const list = try mission.parts();
    try ctx.stdout.print("{d} parts over {d} bytes of script\n\n", .{ list.len, code.len });
    try ctx.stdout.writeAll("  #  offset  bytes  args  block  name\n");

    var decoded: usize = 0;
    var filled: usize = 0;
    for (list, 0..) |part, index| {
        try ctx.stdout.print("{d:>3}  ", .{index});
        if (part.isEmpty()) {
            try ctx.stdout.print("{s:>6}  {s:>5}  {s:>4}  {s:>5}  ", .{ "-", "-", "-", "-" });
        } else {
            filled += 1;
            const listing = try dte.disassemble(ctx.arena, code, part.start());
            const block: usize = if (dte.BlockReader.at(code, part.start())) |r| r.declared else 0;
            if (listing) |found| {
                if (!found.incomplete and found.unreached == 0) decoded += 1;
            }
            try ctx.stdout.print("{d:>6}  {d:>5}  {d:>4}  {d:>5}  ", .{
                part.start(), part.size(), part.arguments, block,
            });
        }
        try ctx.stdout.print("{s}{s}\n", .{ mission.name(part.name), if (part.flags.start) "  (runs at start)" else "" });
    }
    try ctx.stdout.print("\n{d} of {d} entry blocks decode cleanly\n", .{ decoded, filled });
}

fn script(ctx: Context, mission: dte.Mission, models: ?*Library) !void {
    const code = try mission.script();
    const all_parts = try mission.parts();
    const list = try mission.routines(ctx.arena);
    try ctx.stdout.print("{d} bytes of script in {d} routines\n", .{ code.len, list.len });

    for (list) |routine| {
        try ctx.stdout.print("\n{d} to {d}: ", .{ routine.start, routine.start + routine.extent });
        switch (routine.owner) {
            .part => |index| {
                try ctx.stdout.print("part {d}", .{index});
                const name = mission.name(all_parts[index].name);
                if (name.len != 0) try ctx.stdout.print(", {s}", .{name});
            },
            .triggers => |indices| {
                try ctx.stdout.writeAll(if (indices.len == 1) "trigger" else "triggers");
                for (indices, 0..) |index, i| {
                    try ctx.stdout.print("{s}{d}", .{ if (i == 0) " " else ", ", index });
                }
            },
        }
        try ctx.stdout.writeByte('\n');

        const constants = routine.constants(code);
        const listing = try dte.disassemble(ctx.arena, code, routine.start) orelse {
            try ctx.stdout.writeAll("  no block here\n");
            continue;
        };
        try printListing(ctx, mission, models, listing, constants);
        if (constants.len != 0) {
            try ctx.stdout.writeAll("  constants:");
            for (constants) |value| try ctx.stdout.print(" {d}", .{value});
            try ctx.stdout.writeByte('\n');
        }
    }
}

fn printListing(
    ctx: Context,
    mission: dte.Mission,
    models: ?*Library,
    listing: dte.Disassembly,
    constants: []align(1) const u32,
) !void {
    var previous: ?usize = null;
    for (listing.instructions) |instruction| {
        // A hole means the bytes between two reached instructions are not reached themselves.
        if (previous) |end| {
            if (instruction.address > end) {
                try ctx.stdout.print("  {d:>6}  ... {d} bytes not reached\n", .{ end, instruction.address - end });
            }
        }
        previous = instruction.address + instruction.size();

        // Long inline runs are shown as their text, so only the head needs a hex column.
        var bytes: [11]u8 = undefined;
        var at: usize = 0;
        at += (std.fmt.bufPrint(bytes[at..], "{x:0>2}", .{@intFromEnum(instruction.opcode)}) catch break).len;
        for (instruction.operands) |b| {
            at += (std.fmt.bufPrint(bytes[at..], " {x:0>2}", .{b}) catch break).len;
        }
        try ctx.stdout.print("  {d:>6}  {s:<11} ", .{ instruction.address, bytes[0..@min(at, bytes.len)] });
        try openreliant.layout.formatTag(dte.Opcode, instruction.opcode, ctx.stdout);

        switch (instruction.flow) {
            .call => try printIndex(ctx, mission, models, instruction),
            .next => switch (instruction.opcode) {
                .push_constant => {
                    const index = instruction.operands[0];
                    if (index < constants.len) {
                        try ctx.stdout.print("   = {d}", .{constants[index]});
                    } else {
                        try ctx.stdout.writeAll("   (past the constants)");
                    }
                },
                .command => if (openreliant.engine.game.executor.commands.find(instruction.operands[0])) |command| {
                    try ctx.stdout.print("   {s}", .{command.name});
                },
                else => try printIndex(ctx, mission, models, instruction),
            },
            .branch => |branch| try ctx.stdout.print("   -> {d}{s}", .{
                branch.target, if (branch.conditional) " if zero" else "",
            }),
            .inline_data => |data| try printInline(ctx, data),
            .random => |arms| {
                var iterator = arms;
                var separator: []const u8 = "   -> ";
                while (iterator.next()) |target| {
                    try ctx.stdout.print("{s}{d}", .{ separator, target });
                    separator = " | ";
                }
            },
            .@"return" => {},
        }
        try ctx.stdout.writeByte('\n');
    }
    if (listing.incomplete) try ctx.stdout.writeAll("  a reached byte is not an opcode\n");
}

/// Shows the operand of an instruction that takes an index, and the name of what it indexes where
/// the mission holds one.
fn printIndex(ctx: Context, mission: dte.Mission, models: ?*Library, instruction: dte.Instruction) !void {
    switch (instruction.opcode) {
        .push_component, .push_component_alt => if (instruction.operands.len == 2) {
            const index = instruction.operands[0];
            const all = try mission.ships();
            if (index >= all.len) return ctx.stdout.print("   {d}, component {d}", .{ index, instruction.operands[1] });
            try ctx.stdout.print("   {d}  {s}, component {d}", .{ index, mission.name(all[index].name), instruction.operands[1] });
            return printComponent(ctx, models, all[index], instruction.operands[1]);
        },
        else => {},
    }
    if (instruction.operands.len != 1) return;
    const index = instruction.operands[0];
    try ctx.stdout.print("   {d}", .{index});
    const name: []const u8 = switch (instruction.opcode) {
        .call_part, .spawn_part => blk: {
            const all = mission.parts() catch break :blk "";
            break :blk if (index < all.len) mission.name(all[index].name) else "";
        },
        .push_ship => blk: {
            const all = mission.ships() catch break :blk "";
            break :blk if (index < all.len) mission.name(all[index].name) else "";
        },
        .push_global, .select_global => blk: {
            const all = mission.globals() catch break :blk "";
            break :blk if (index < all.len) mission.name(all[index].name) else "";
        },
        else => "",
    };
    if (name.len != 0) try ctx.stdout.print("  {s}", .{name});
}

/// Names component `index` of a ship: the part it is in the model of the ship's type, found beside
/// the mission. Nothing when the model cannot be found.
fn printComponent(ctx: Context, models: ?*Library, ship: dte.Ship, index: u8) !void {
    const library = models orelse return;
    const ship_type = openreliant.engine.game.create.models.shipType(ship.kind) orelse return;
    const model = ship_type.model orelse return;
    const list = try library.components(model) orelse return;
    if (index >= list.len) {
        return ctx.stdout.print(" out of range: {s} lists {d}", .{ model, list.len });
    }
    const component = list[index];
    try ctx.stdout.print(" \"{s}\"", .{std.mem.trimEnd(u8, component.part.name(), " ")});
    if (component.depth != 0) try ctx.stdout.print(" on {s}", .{component.model});
}

/// Renders an inline run as text when it is one, and as hex otherwise.
fn printInline(ctx: Context, data: []const u8) !void {
    const text = std.mem.sliceTo(data, 0);
    const printable = text.len + 1 == data.len and
        text.len != 0 and
        for (text) |c| {
            if (!std.ascii.isPrint(c)) break false;
        } else true;

    if (printable) {
        try ctx.stdout.print("   \"{s}\"", .{text});
        return;
    }
    try ctx.stdout.writeAll("  ");
    for (data) |b| try ctx.stdout.print(" {x:0>2}", .{b});
}

fn strings(ctx: Context, mission: dte.Mission) !void {
    const pool = mission.entry(.strings);
    if (!pool.isUsed()) return;
    const end = mission.stringPoolEnd();

    var offset: usize = pool.offset;
    while (offset < end) {
        const rest = mission.image[offset..end];
        const len = std.mem.indexOfScalar(u8, rest, 0) orelse break;
        if (len > 0) {
            try ctx.stdout.print("{d:>6}  {s}\n", .{ offset - pool.offset, rest[0..len] });
        }
        offset += len + 1;
    }
}

test Command {
    try std.testing.expectEqualStrings("M01.DTE", (try Command.parse(&.{ "script", "M01.DTE" })).script.mission);
    try std.testing.expectEqualStrings("M01.DTE", (try Command.parse(&.{ "triggers", "M01.DTE" })).triggers.mission);
    try std.testing.expectError(error.Usage, Command.parse(&.{"script"}));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "script", "M01.DTE", "extra" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "disassemble", "M01.DTE" }));
}

/// Writes `mission` again and checks what comes back: from its sections' whole rooms, the same
/// bytes, where it is laid out as the template lays it out; from its records alone, the same
/// records; and each routine of its script, assembled again from its disassembly, the same bytes
/// but for the block's padding. Fails where anything differs.
fn check(ctx: Context, mission: dte.Mission) !void {
    const gpa = ctx.arena;
    const out = ctx.stdout;
    if (dte.write.rooms(mission)) |rooms| {
        const bytes = try dte.write.write(gpa, &rooms, .{});
        if (!std.mem.eql(u8, bytes, mission.image)) return fail(out, "written again from its rooms, the file differs");
        try out.writeAll("rooms: the same bytes\n");
    } else {
        try out.writeAll("rooms: laid out otherwise than the template\n");
    }

    const read = try dte.write.records(mission);
    const written = try dte.write.write(gpa, &read, .{});
    if (!dte.write.sameRecords(read, try dte.write.records(try .parse(written)))) return fail(out, "written again from its records, the records differ");
    try out.writeAll("records: the same\n");

    const code = try mission.script();
    var assembled: usize = 0;
    var skipped: usize = 0;
    for (try mission.routines(gpa)) |routine| {
        const disassembly = (try dte.disassemble(gpa, code, routine.start)) orelse continue;
        // Bytes nothing reaches can't be written again from a disassembly.
        if (disassembly.incomplete or disassembly.unreached > 0) {
            skipped += 1;
            continue;
        }
        const original = code[routine.start..][0..routine.extent];
        const again = try reassemble(gpa, disassembly.instructions, routine.constants(code));
        const block = dte.BlockReader.at(original, 0).?;
        const header = dte.BlockReader.header_len;
        const last = disassembly.instructions[disassembly.instructions.len - 1];
        const used = last.address + last.size() - routine.start;
        const same = again.len == original.len and
            std.mem.eql(u8, again[0..used], original[0..used]) and
            std.mem.eql(u8, again[header + block.code.len ..], original[header + block.code.len ..]);
        if (!same) {
            try out.print("routine at {d}: assembled again, it differs\n", .{routine.start});
            return error.Differs;
        }
        assembled += 1;
    }
    try out.print("script: {d} routines assembled again the same, {d} with bytes nothing reaches\n", .{ assembled, skipped });
}

/// A routine assembled again from its disassembly, with its constant table as it was.
fn reassemble(gpa: std.mem.Allocator, instructions: []const dte.Instruction, constants: []align(1) const u32) ![]u8 {
    var routine: dte.assemble.Routine = .init(gpa);
    var at: std.AutoHashMapUnmanaged(usize, dte.assemble.Label) = .empty;
    for (instructions) |instruction| try at.put(gpa, instruction.address, try routine.label());
    for (instructions) |instruction| {
        routine.place(at.get(instruction.address).?);
        try dte.assemble.emit(&routine, instruction, &at);
    }
    for (constants) |constant| try routine.constants.append(gpa, constant);
    return routine.finish();
}

fn fail(out: *Io.Writer, what: []const u8) (Io.Writer.Error || error{Differs}) {
    try out.print("{s}\n", .{what});
    return error.Differs;
}
