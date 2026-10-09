//! `sltool cd ...`: look inside a game disc image (`.bin` or `.iso`) without mounting it.

const std = @import("std");

const openreliant = @import("openreliant");
const cdimage = openreliant.cdimage;
const iso9660 = openreliant.iso9660;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { image: []const u8 },
    ls: struct { image: []const u8 },
    extract: struct { image: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  cd info <image>                 describe a disc image
        \\  cd ls <image>                   list the files on a disc image
        \\  cd extract <image> <out-dir>    copy every file off a disc image
        \\
    ;

    pub fn parse(args: []const [:0]const u8) error{Usage}!Command {
        const verb, const operands = try sltool.verbOf(Command, args);
        return switch (verb) {
            inline else => |tag| sltool.positional(Command, tag, operands),
        };
    }

    pub fn run(command: Command, ctx: Context) !void {
        const image_path = switch (command) {
            inline else => |operands| operands.image,
        };
        const image: cdimage.Image = try .open(ctx.io, .cwd(), image_path);
        defer image.close();
        const volume: iso9660.Volume = try .open(image);

        switch (command) {
            .info => try info(ctx, &volume),
            .ls => try list(ctx, &volume),
            .extract => |operands| try extract(ctx, &volume, operands.out_dir),
        }
    }
};

fn info(ctx: Context, volume: *const iso9660.Volume) !void {
    const image = volume.image;
    try ctx.stdout.print(
        \\layout:     {t} ({d} byte sectors)
        \\blocks:     {d} ({Bi:.1})
        \\volume:     {s}
        \\namespace:  {t}
        \\
    , .{
        image.layout,                image.layout.sectorSize(),
        image.block_count,           @as(u64, image.block_count) * cdimage.block_size,
        try volume.label(ctx.arena), volume.namespace,
    });
}

fn list(ctx: Context, volume: *const iso9660.Volume) !void {
    var walker = try volume.walk(ctx.arena);
    while (try walker.next()) |item| switch (item.entry.kind) {
        .directory => try ctx.stdout.print("{s:>10}  {f}  {s}/\n", .{ "", item.entry.recorded_at, item.path }),
        .file => try ctx.stdout.print("{d:>10}  {f}  {s}\n", .{ item.entry.extent.len, item.entry.recorded_at, item.path }),
    };
}

fn extract(ctx: Context, volume: *const iso9660.Volume, out_path: []const u8) !void {
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);

    var files: usize = 0;
    var streamed: usize = 0;
    var bytes: u64 = 0;
    var walker = try volume.walk(ctx.arena);
    while (try walker.next()) |item| switch (item.entry.kind) {
        .directory => try out_dir.createDirPath(io, item.path),
        .file => {
            const file = try out_dir.createFile(io, item.path, .{});
            defer file.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var writer = file.writer(io, &buffer);
            const extent = item.entry.extent;
            // ISO 9660 counts a file's length in logical blocks, whatever its sectors hold.
            const sectors = @divCeil(extent.len, cdimage.block_size);
            if (try volume.image.hasForm2(extent.lba, sectors)) {
                try volume.image.streamMode2Sectors(extent.lba, sectors, &writer.interface);
                streamed += 1;
                bytes += @as(u64, sectors) * cdimage.mode2_size;
            } else {
                try volume.image.streamExtent(extent.lba, extent.len, &writer.interface);
                bytes += extent.len;
            }
            try writer.interface.flush();
            files += 1;
        },
    };
    try ctx.stdout.print("extracted {d} files ({Bi:.1}) to {s}\n", .{ files, bytes, out_path });
    if (streamed != 0) try ctx.stdout.print(
        "kept {d} of them, with streamed audio or video, as whole {d}-byte Mode 2 sectors\n",
        .{ streamed, cdimage.mode2_size },
    );
}

test Command {
    try std.testing.expectEqualStrings("disc.bin", (try Command.parse(&.{ "info", "disc.bin" })).info.image);
    try std.testing.expectEqualStrings("disc.bin", (try Command.parse(&.{ "ls", "disc.bin" })).ls.image);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "ls", "disc.bin", "extra" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{"mount"}));
}
