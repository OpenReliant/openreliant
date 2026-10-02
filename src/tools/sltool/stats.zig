//! `sltool stats ...`: read the `*STATS.BIN` tables.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const stats = openreliant.stats;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    /// Lists every record with its fields.
    list: struct { path: []const u8 },

    pub const usage =
        \\  stats list <stats.bin>          list a ship, gun, missile or pilot table
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        return switch (verb) {
            inline else => |tag| sltool.positional(Command, tag, operands),
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        switch (command) {
            .list => |operands| {
                const table = stats.Table.fromPath(operands.path) orelse {
                    std.debug.print("{s}: not one of the stats tables\n", .{operands.path});
                    return error.UnknownTable;
                };
                switch (try stats.File.parse(table, try ctx.readInput(operands.path))) {
                    inline else => |rows, tag| try list(ctx, tag, rows),
                }
            },
        }
    }
};

fn list(ctx: Context, comptime table: stats.Table, all: []align(1) const table.Record()) !void {
    const Record = table.Record();
    const load = table.load();
    const loaded = load.reads(all.len);

    try ctx.stdout.print("{s}: {d} records; the engine keeps {d}", .{
        table.fileName(), all.len, load.capacity(),
    });
    if (all.len > load.capacity()) switch (load) {
        .at_most => try ctx.stdout.print(" and reads no further, so records {d} to {d} are ignored", .{
            loaded, all.len - 1,
        }),
        .until_end => try ctx.stdout.writeAll(" but reads to the end of the file, overrunning its table"),
    };
    try ctx.stdout.writeAll("\n\n");

    try ctx.stdout.print("{s:>4}  {s:<24}", .{ "#", "name" });
    inline for (std.meta.fields(Record)) |field| {
        if (comptime isShown(field.name)) try printHeading(ctx, field);
    }
    try ctx.stdout.writeByte('\n');

    for (all, 0..) |record, index| {
        const marker: u8 = if (index < loaded) ' ' else '-';
        try ctx.stdout.print("{d:>3}{c}  {s:<24}", .{ index, marker, stats.nameOf(&record.name) });
        inline for (std.meta.fields(Record)) |field| {
            if (comptime isShown(field.name)) try printValue(ctx, @field(record, field.name));
        }
        try ctx.stdout.writeByte('\n');
    }
    if (loaded < all.len) try ctx.stdout.writeAll("\n- marks a record the engine never loads\n");
}

/// The name has its own column, and what the engine never reads is zero throughout.
fn isShown(comptime name: []const u8) bool {
    return !std.mem.eql(u8, name, "name") and !std.mem.startsWith(u8, name, "_unread");
}

fn printHeading(ctx: Context, comptime field: std.builtin.Type.StructField) !void {
    const label = comptime std.mem.trimStart(u8, field.name, "_");
    switch (@typeInfo(field.type)) {
        .array => |array| inline for (0..array.len) |i| {
            try ctx.stdout.print(" {s:>14}", .{std.fmt.comptimePrint("{s}[{d}]", .{ label, i })});
        },
        // A record of named values, such as the damage to a shield and to a hull: a column each.
        .@"struct" => |info| switch (info.layout) {
            .@"extern" => inline for (info.fields) |inner| {
                try ctx.stdout.print(" {s:>14}", .{label ++ "." ++ inner.name});
            },
            else => try ctx.stdout.print(" {s:>14}", .{label}),
        },
        else => try ctx.stdout.print(" {s:>14}", .{label}),
    }
}

fn printValue(ctx: Context, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .float => try ctx.stdout.print(" {d:>14.3}", .{value}),
        .int => try ctx.stdout.print(" {d:>14}", .{value}),
        .array => for (value) |element| try printValue(ctx, element),
        // A packed value the engine reads only part of: show the part it reads.
        .@"struct" => |info| switch (info.layout) {
            .@"packed" => if (@hasField(T, "low"))
                try printValue(ctx, value.low)
            else
                @compileError("no column format for " ++ @typeName(T)),
            .@"extern" => inline for (info.fields) |inner| try printValue(ctx, @field(value, inner.name)),
            .auto => @compileError("no column format for " ++ @typeName(T)),
        },
        .@"enum" => {
            // Render into a buffer first: `formatTag` does not pad, and the column must.
            var buffer: [16]u8 = undefined;
            var writer: Io.Writer = .fixed(&buffer);
            openreliant.layout.formatTag(T, value, &writer) catch {};
            try ctx.stdout.print(" {s:>14}", .{writer.buffered()});
        },
        else => @compileError("no column format for " ++ @typeName(T)),
    }
}

test Command {
    const parsed = try Command.parse(&.{ "list", "gunstats.bin" });
    try std.testing.expectEqualStrings("gunstats.bin", parsed.list.path);
    try std.testing.expectError(error.Usage, Command.parse(&.{"list"}));
}
