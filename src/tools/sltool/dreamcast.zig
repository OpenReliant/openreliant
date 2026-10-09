//! `sltool dreamcast ...`: read the Dreamcast version's files that the PC version doesn't have:
//! its text tables and its texture cache. `sltool cd` reads its `.cdi` disc images, and the other
//! commands read its archives, missions, models, stat tables, face films and speech as the PC's.

const std = @import("std");

const openreliant = @import("openreliant");
const dreamcast = openreliant.dreamcast;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    text: struct { table: []const u8 },
    textures: struct { cache: []const u8 },
    extract: struct { cache: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  dreamcast text <table>          list the strings of a Dreamcast text table, GTEXT.DAT
        \\                                  or ITEXT.DAT
        \\  dreamcast textures <cache>      list the textures in DREAMCACHEHW.DAT
        \\  dreamcast extract <cache> <out-dir>
        \\                                  save every texture in DREAMCACHEHW.DAT as a PNG file
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
            .text => |operands| try text(ctx, try .parse(try ctx.readInput(operands.table))),
            .textures => |operands| try textures(ctx, try .parse(try ctx.readInput(operands.cache))),
            .extract => |operands| try extract(ctx, try .parse(try ctx.readInput(operands.cache)), operands.out_dir),
        }
    }
};

fn text(ctx: Context, table: dreamcast.text.Table) !void {
    for (0..table.offsets.len) |number| {
        try ctx.stdout.print("{d:>5}  {s}\n", .{ number, table.string(number) orelse "" });
    }
}

fn textures(ctx: Context, cache: dreamcast.textures.Cache) !void {
    try ctx.stdout.writeAll("   #  name                              size  kind\n");
    for (cache.entries, 0..) |*entry, index| {
        try ctx.stdout.print("{d:>4}  {s:<32}  {d:>4}  {f}\n", .{ index, entry.name(), entry.width, entry.kind });
    }
}

/// Saves each texture's largest level as `<name>.png` in `out_path`.
fn extract(ctx: Context, cache: dreamcast.textures.Cache, out_path: []const u8) !void {
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(ctx.io);
    // A few names repeat, for separate copies of a texture.
    var names: sltool.UniqueNames = .{};
    var saved: usize = 0;
    for (cache.entries) |*entry| {
        const texture = cache.texture(entry) catch |err| {
            try ctx.stdout.print("skipping {s}: {t}\n", .{ entry.name(), err });
            continue;
        };
        const pixels = try texture.rgba(ctx.arena);
        defer ctx.arena.free(pixels);
        const name = try names.of(ctx.arena, try ctx.arena.print("{s}.png", .{entry.name()}));
        try ctx.writePng(out_dir, name, entry.width, entry.width, pixels);
        saved += 1;
    }
    try ctx.stdout.print("wrote {f} to {s}\n", .{ sltool.count(saved, "texture"), out_path });
    try names.report(ctx, "texture");
}

test Command {
    try std.testing.expectEqualStrings("GTEXT.DAT", (try Command.parse(&.{ "text", "GTEXT.DAT" })).text.table);
    try std.testing.expectEqualStrings("out", (try Command.parse(&.{ "extract", "DREAMCACHEHW.DAT", "out" })).extract.out_dir);
    try std.testing.expectError(error.Usage, Command.parse(&.{"textures"}));
}
