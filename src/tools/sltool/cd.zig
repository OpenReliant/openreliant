//! `sltool cd ...`: look inside a game disc image (`.bin` or `.iso`) without mounting it: an ISO
//! 9660 disc, or an Xbox disc as `extract-xiso` writes it.

const std = @import("std");

const openreliant = @import("openreliant");
const cdimage = openreliant.cdimage;
const iso9660 = openreliant.iso9660;
const xdvdfs = openreliant.xbox.xdvdfs;

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
        switch (try Volume.open(image)) {
            inline else => |volume| switch (command) {
                .info => try info(ctx, &volume),
                .ls => try list(ctx, &volume),
                .extract => |operands| try extract(ctx, &volume, operands.out_dir),
            },
        }
    }
};

/// The filesystem on a disc.
const Volume = union(enum) {
    iso9660: iso9660.Volume,
    xdvdfs: xdvdfs.Volume,

    /// An Xbox disc's volume where the image holds one, or else an ISO 9660 one.
    fn open(image: cdimage.Image) !Volume {
        if (xdvdfs.Volume.open(image)) |volume| {
            return .{ .xdvdfs = volume };
        } else |err| switch (err) {
            error.NotXdvdfs => return .{ .iso9660 = try .open(image) },
            else => |e| return e,
        }
    }
};

/// Describes the image and `volume`, an `iso9660.Volume` or an `xdvdfs.Volume`.
fn info(ctx: Context, volume: anytype) !void {
    const image = volume.image;
    try ctx.stdout.print(
        \\layout:     {t} ({d} byte sectors)
        \\blocks:     {d} ({Bi:.1})
        \\
    , .{
        image.layout,      image.layout.sectorSize(),
        image.block_count, @as(u64, image.block_count) * cdimage.block_size,
    });
    switch (@TypeOf(volume.*)) {
        iso9660.Volume => try ctx.stdout.print("volume:     {s}\nnamespace:  {t}\n", .{ try volume.label(ctx.arena), volume.namespace }),
        xdvdfs.Volume => try ctx.stdout.writeAll("filesystem: Xbox (XDVDFS)\n"),
        else => comptime unreachable,
    }
}

/// Lists every file and folder of `volume`, with the time it was recorded where the filesystem
/// keeps one.
fn list(ctx: Context, volume: anytype) !void {
    var walker = try volume.walk(ctx.arena);
    while (try walker.next()) |item| {
        switch (item.entry.kind) {
            .directory => try ctx.stdout.print("{s:>10}  ", .{""}),
            .file => try ctx.stdout.print("{d:>10}  ", .{item.entry.extent.len}),
        }
        if (@hasField(@TypeOf(item.entry), "recorded_at")) try ctx.stdout.print("{f}  ", .{item.entry.recorded_at});
        try ctx.stdout.print("{s}{s}\n", .{ item.path, if (item.entry.kind == .directory) "/" else "" });
    }
}

fn extract(ctx: Context, volume: anytype, out_path: []const u8) !void {
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
            // The filesystem counts a file's length in logical blocks, whatever its sectors hold.
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
