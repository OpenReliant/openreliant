//! `sltool spr ...`: read `.SPR` sprite sets and save their shapes as PNG.

const std = @import("std");

const openreliant = @import("openreliant");
const png = openreliant.png;
const spr = openreliant.spr;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { sprite: []const u8 },
    ls: struct { sprite: []const u8 },
    /// Writes every shape as an indexed PNG.
    extract: struct { sprite: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  spr info <sprite>               summarise a .SPR sprite set
        \\  spr ls <sprite>                 list its blocks: shapes, palettes, remap tables
        \\  spr extract <sprite> <out-dir>  save every shape as an indexed PNG
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
            inline else => |operands| operands.sprite,
        };
        const sprite: spr.Sprite = try .parse(try ctx.readInput(path));

        switch (command) {
            .info => try info(ctx, sprite),
            .ls => try list(ctx, sprite),
            .extract => |operands| try extract(ctx, sprite, path, operands.out_dir),
        }
    }
};

const Counts = struct {
    shapes: usize = 0,
    palettes: usize = 0,
    remaps: usize = 0,
    placeholders: usize = 0,
    pixels: u64 = 0,
};

fn tally(sprite: spr.Sprite) Counts {
    var counts: Counts = .{};
    for (0..sprite.count()) |i| switch (sprite.block(i)) {
        .shape => |shape| {
            counts.shapes += 1;
            counts.pixels += @as(u64, shape.width()) * shape.height();
        },
        .palette => counts.palettes += 1,
        .remap => counts.remaps += 1,
        .placeholder => counts.placeholders += 1,
    };
    return counts;
}

fn info(ctx: Context, sprite: spr.Sprite) !void {
    const counts = tally(sprite);
    try ctx.stdout.print(
        \\blocks:       {d}
        \\  shapes:     {d} ({d} pixels)
        \\  palettes:   {d}
        \\  remaps:     {d}
        \\  placeholder:{d}
        \\
    , .{
        sprite.count(),
        counts.shapes,
        counts.pixels,
        counts.palettes,
        counts.remaps,
        counts.placeholders,
    });
    if (counts.palettes == 0 and counts.shapes > 0) {
        try ctx.stdout.writeAll(
            \\
            \\No palette travels with this set, so its shapes are drawn with whatever palette the
            \\game had loaded. Extracted images fall back to greyscale.
            \\
        );
    }
}

fn list(ctx: Context, sprite: spr.Sprite) !void {
    try ctx.stdout.writeAll("index    offset  kind       detail\n");
    for (0..sprite.count()) |i| {
        const offset = sprite.entries[i].offset;
        switch (sprite.block(i)) {
            .shape => |shape| try ctx.stdout.print(
                "{d:>5}  {x:0>8}  shape      {d}x{d} at ({d},{d})\n",
                .{ i, offset, shape.width(), shape.height(), shape.header.x1, shape.header.y1 },
            ),
            .palette => try ctx.stdout.print("{d:>5}  {x:0>8}  palette    256 colours\n", .{ i, offset }),
            .remap => try ctx.stdout.print("{d:>5}  {x:0>8}  remap      256 entries\n", .{ i, offset }),
            .placeholder => try ctx.stdout.print("{d:>5}  {x:0>8}  placeholder\n", .{ i, offset }),
        }
    }
}

fn extract(ctx: Context, sprite: spr.Sprite, source: []const u8, out_path: []const u8) !void {
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);

    const greyscale = png.greys(std.math.maxInt(u8));

    var written: usize = 0;
    var without_palette: usize = 0;
    for (0..sprite.count()) |i| {
        const shape = switch (sprite.block(i)) {
            .shape => |s| s,
            else => continue,
        };
        const pixels = try shape.decode(ctx.arena);
        defer ctx.arena.free(pixels);

        var palette: png.Palette = undefined;
        if (sprite.paletteFor(i)) |packed_palette| {
            spr.expandPalette(packed_palette, &palette);
        } else {
            palette = greyscale;
            without_palette += 1;
        }

        var named: [std.fs.max_name_bytes]u8 = undefined;
        const name = try spr.pictureName(&named, source, i);

        const file = try out_dir.createFile(io, name, .{});
        defer file.close(io);
        var buffer: [32 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try png.writeIndexed(ctx.arena, &writer.interface, .{
            .width = shape.width(),
            .height = shape.height(),
            .palette = &palette,
            .transparent = 0,
        }, pixels);
        try writer.interface.flush();
        written += 1;
    }

    try ctx.stdout.print("wrote {d} images to {s}\n", .{ written, out_path });
    if (without_palette > 0) {
        try ctx.stdout.print("{d} had no palette in the file and are greyscale\n", .{without_palette});
    }
}

test Command {
    const parsed = try Command.parse(&.{ "extract", "HUD.SPR", "out" });
    try std.testing.expectEqualStrings("HUD.SPR", parsed.extract.sprite);
    try std.testing.expectEqualStrings("out", parsed.extract.out_dir);
    try std.testing.expectEqualStrings("HUD.SPR", (try Command.parse(&.{ "ls", "HUD.SPR" })).ls.sprite);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "extract", "HUD.SPR" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "show", "HUD.SPR" }));
}
