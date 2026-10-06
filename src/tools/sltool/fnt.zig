//! `sltool fnt ...`: read `.fnt` fonts and render them as glyph atlases.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const fnt = openreliant.fnt;
const png = openreliant.png;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { font: []const u8 },
    /// Writes every glyph into one PNG, sixteen character codes to a row.
    render: struct { font: []const u8, out: []const u8 },

    pub const usage =
        \\  fnt info <font>                 summarise a .fnt font and its glyph widths
        \\  fnt render <font> <out.png>     draw every glyph into an atlas, sixteen codes to a row
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
            inline else => |operands| operands.font,
        };
        const font: fnt.Font = try .parse(try ctx.readInput(path));
        switch (command) {
            .info => try info(ctx, font),
            .render => |operands| try render(ctx, font, operands.out),
        }
    }
};

/// Codes to a row of the atlas and of the width listing.
const columns = 16;

/// The character codes a byte can hold, which the listing and the atlas stop at.
const codes = std.math.maxInt(u8) + 1;

fn info(ctx: Context, font: fnt.Font) !void {
    var glyphs: usize = 0;
    for (0..font.offsets.len) |code| {
        if (font.glyph(code) != null) glyphs += 1;
    }
    try ctx.stdout.print("version {s}, {d} codes of which {d} have a glyph, {d} rows tall, {s}\n\n", .{
        std.mem.sliceTo(&font.header.version, 0),
        font.offsets.len,
        glyphs,
        font.height(),
        if (font.palette != null) "with a trailing palette" else "no palette",
    });

    try ctx.stdout.writeAll("widths, by character code:\n");
    const shown = @min(font.offsets.len, codes);
    var row: usize = 0;
    while (row < shown) : (row += columns) {
        try ctx.stdout.print("  {x:0>2}:", .{row});
        for (row..@min(row + columns, shown)) |code| {
            if (font.glyph(code)) |glyph| {
                try ctx.stdout.print(" {d:>2}", .{glyph.width});
            } else {
                try ctx.stdout.writeAll("  -");
            }
        }
        try ctx.stdout.writeByte('\n');
    }
}

fn render(ctx: Context, font: fnt.Font, out_path: []const u8) !void {
    const shown = @min(font.offsets.len, codes);
    var widest: u32 = 1;
    for (0..shown) |code| {
        if (font.glyph(code)) |glyph| widest = @max(widest, glyph.width);
    }
    // One pixel of gap around each cell keeps neighbouring glyphs apart.
    const cell_width = widest + 1;
    const cell_height = font.height() + 1;
    const rows = @divCeil(shown, columns);
    const width = columns * cell_width + 1;
    const height: u32 = @intCast(rows * cell_height + 1);

    const pixels = try ctx.arena.alloc(u8, @as(usize, width) * height);
    @memset(pixels, 0);
    for (0..shown) |code| {
        const glyph = font.glyph(code) orelse continue;
        const left = 1 + (code % columns) * cell_width;
        const top = 1 + (code / columns) * cell_height;
        for (0..glyph.height) |y| {
            const source = glyph.pixels[y * glyph.width ..][0..glyph.width];
            @memcpy(pixels[(top + y) * width + left ..][0..glyph.width], source);
        }
    }

    // Coverage as grey. A trailing palette is not used: the text's colour comes from the remap
    // table the caller draws with, and some fonts' palettes are not a coverage ramp at all.
    const palette = png.greys(fnt.full_coverage);

    const file = try Io.Dir.cwd().createFile(ctx.io, out_path, .{});
    defer file.close(ctx.io);
    var buffer: [32 * 1024]u8 = undefined;
    var writer = file.writer(ctx.io, &buffer);
    try png.writeIndexed(ctx.arena, &writer.interface, .{
        .width = width,
        .height = height,
        .palette = &palette,
        .transparent = 0,
    }, pixels);
    try writer.interface.flush();
    try ctx.stdout.print("wrote a {d}x{d} atlas to {s}\n", .{ width, height, out_path });
}

test Command {
    const parsed = try Command.parse(&.{ "render", "handel.fnt", "handel.png" });
    try std.testing.expectEqualStrings("handel.png", parsed.render.out);
    try std.testing.expectError(error.Usage, Command.parse(&.{"info"}));
}
