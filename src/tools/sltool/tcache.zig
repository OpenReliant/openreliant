//! `sltool tcache ...`: read the texture caches and save their textures as PNG.

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const png = openreliant.png;
const tcache = openreliant.tcache;
const tga = openreliant.tga;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { cache: []const u8 },
    ls: struct { cache: []const u8 },
    /// Writes the full-size level of each texture, or of the named ones, as RGBA.
    extract: struct {
        cache: []const u8,
        palette: []const u8,
        out_dir: []const u8,
        names: []const [:0]const u8,
    },

    pub const usage =
        \\  tcache info <cache>             summarise a texture cache (tcachehw.dat, tcachesw.dat)
        \\  tcache ls <cache>               list its textures
        \\  tcache extract <cache> <palette.tga> <out-dir> [name...]
        \\                                  save textures as PNG, indices looked up in the palette
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        switch (verb) {
            .extract => return if (operands.len >= 3) .{ .extract = .{
                .cache = operands[0],
                .palette = operands[1],
                .out_dir = operands[2],
                .names = operands[3..],
            } } else error.Usage,
            inline else => |tag| return sltool.positional(Command, tag, operands),
        }
    }

    pub fn run(command: Command, ctx: Context) !void {
        const path = switch (command) {
            inline else => |operands| operands.cache,
        };
        const cache: tcache.Cache = try .parse(ctx.arena, try ctx.readInput(path));

        switch (command) {
            .info => try info(ctx, cache),
            .ls => try list(ctx, cache),
            .extract => |operands| try extract(ctx, cache, operands.palette, operands.out_dir, operands.names),
        }
    }
};

fn info(ctx: Context, cache: tcache.Cache) !void {
    var by_encoding: std.EnumArray(tcache.Encoding, usize) = .initFill(0);
    var mipmapped: usize = 0;
    for (cache.textures) |texture| {
        by_encoding.getPtr(texture.encoding).* += 1;
        if (texture.levels > 1) mipmapped += 1;
    }
    try ctx.stdout.print(
        \\version:        {d}
        \\entries:        {d} of {d}
        \\  loadable:     {d}
        \\  mipmapped:    {d}
        \\pixels end at:  {d}
        \\
    , .{
        cache.header.version,
        cache.entries.len,
        tcache.capacity,
        cache.textures.len,
        mipmapped,
        cache.header.end,
    });
    for (by_encoding.values, 0..) |count, i| {
        const encoding: tcache.Encoding = @fromBackingInt(@intCast(i));
        try ctx.stdout.print("  {s:<14}{d}\n", .{ @tagName(encoding), count });
    }
}

fn list(ctx: Context, cache: tcache.Cache) !void {
    try ctx.stdout.writeAll("index  name                              size      levels  encoding       offset\n");
    for (cache.textures) |texture| {
        const size = try ctx.arena.print("{d}x{d}", .{ texture.width, texture.height });
        try ctx.stdout.print("{d:>5}  {s:<32}  {s:<9}  {d:>5}  {s:<13}  {x:0>8}\n", .{
            texture.entry.image.index,
            texture.name(),
            size,
            texture.levels,
            @tagName(texture.encoding),
            texture.entry.image.source,
        });
    }
}

fn extract(
    ctx: Context,
    cache: tcache.Cache,
    palette_path: []const u8,
    out_path: []const u8,
    names: []const [:0]const u8,
) !void {
    const io = ctx.io;
    const palette = try tga.palette(try ctx.readInput(palette_path));

    var chosen: std.ArrayList(tcache.Texture) = .empty;
    if (names.len == 0) {
        try chosen.appendSlice(ctx.arena, cache.textures);
    } else for (names) |name| {
        const texture = cache.find(name) orelse {
            std.debug.print("no texture named {s}\n", .{name});
            return error.TextureNotFound;
        };
        try chosen.append(ctx.arena, texture);
    }

    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);

    for (chosen.items) |texture| {
        // Every loadable texture has a level 0.
        const level = texture.level(0) orelse continue;
        try savePng(ctx, out_dir, texture.name(), level, &palette);
    }
    try ctx.stdout.print("wrote {d} textures to {s}\n", .{ chosen.items.len, out_path });
}

/// Saves `level`, in `palette`'s colours, as the PNG file `<name>.png` in `dir`.
pub fn savePng(ctx: Context, dir: std.Io.Dir, name: []const u8, level: tcache.Level, palette: *const tga.Palette) !void {
    const pixels = try level.rgba(ctx.arena, palette);
    defer ctx.arena.free(pixels);
    try ctx.writePng(dir, try ctx.arena.print("{s}.png", .{name}), level.width, level.height, pixels);
}

test Command {
    const extract_all = try Command.parse(&.{ "extract", "tcachehw.dat", "palette.tga", "out" });
    try std.testing.expectEqualStrings("palette.tga", extract_all.extract.palette);
    try std.testing.expectEqual(0, extract_all.extract.names.len);
    const extract_some = try Command.parse(&.{ "extract", "tcachehw.dat", "palette3.tga", "out", "gyank_1", "plate-nw" });
    try std.testing.expectEqual(2, extract_some.extract.names.len);
    try std.testing.expectEqualStrings("tcachehw.dat", (try Command.parse(&.{ "ls", "tcachehw.dat" })).ls.cache);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "extract", "tcachehw.dat", "palette.tga" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{ "show", "tcachehw.dat" }));
}

test "extracts a texture" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_bytes = try tcache.testing.build(arena, &.{.{ .name = "Kiev_1", .encoding = .index8, .width = 2, .height = 2 }});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tcachehw.dat", .data = cache_bytes });

    // A colour-mapped TGA with a 256-entry map and no image to speak of.
    var palette_file: [tga.header_size + @sizeOf(tga.Palette) + 1]u8 = @splat(0);
    (try openreliant.layout.viewMut(tga.Header, &palette_file)).* = .{
        .id_length = 0,
        .color_map_type = .present,
        .image_type = .color_mapped,
        .color_map_first = 0,
        .color_map_length = tga.palette_length,
        .color_map_entry_bits = 24,
        .x_origin = 0,
        .y_origin = 0,
        .width = 0,
        .height = 0,
        .pixel_bits = 0,
        .descriptor = @bitCast(@as(u8, 0)),
    };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "palette.tga", .data = &palette_file });

    const base = try arena.print(".zig-cache/tmp/{s}", .{tmp.sub_path});
    var out: Io.Writer.Allocating = .init(arena);
    const ctx: Context = .{ .io = std.testing.io, .arena = arena, .stdout = &out.writer };
    const command: Command = .{ .extract = .{
        .cache = try arena.print("{s}/tcachehw.dat", .{base}),
        .palette = try arena.print("{s}/palette.tga", .{base}),
        .out_dir = try arena.print("{s}/out", .{base}),
        .names = &.{"KIEV_1"},
    } };
    try command.run(ctx);

    const written = try tmp.dir.readFileAlloc(std.testing.io, "out/Kiev_1.png", arena, .limited(1 << 20));
    try std.testing.expectEqualSlices(u8, png.signature, written[0..8]);
}
