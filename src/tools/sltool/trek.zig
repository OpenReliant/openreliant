//! `sltool trek ...`: read Star Trek: Invasion's files: the archive on its disc, its `.DSM`
//! missions, which have the original's format, and its `.TRK` models
//! ([#181](https://github.com/OpenReliant/openreliant/issues/181)). `sltool tim` reads its
//! pictures.

const std = @import("std");

const openreliant = @import("openreliant");
const cdimage = openreliant.cdimage;
const iso9660 = openreliant.iso9660;
const dte = openreliant.dte;
const tim = openreliant.playstation.tim;
const trek = openreliant.games.trek;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    ls: struct { image: []const u8 },
    extract: struct { image: []const u8, out_dir: []const u8 },
    sections: struct { mission: []const u8 },
    strings: struct { mission: []const u8 },
    parts: struct { mission: []const u8 },
    script: struct { mission: []const u8 },
    chunks: struct { model: []const u8 },
    textures: struct { model: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  trek ls <image>                 list the files in Star Trek: Invasion's archive on its
        \\                                  disc image
        \\  trek extract <image> <out-dir>  copy every file out of the archive
        \\  trek sections <mission>         list an Invasion mission's sections
        \\  trek strings <mission>          dump an Invasion mission's string pool
        \\  trek parts <mission>            list an Invasion mission's script routines
        \\  trek script <mission>           disassemble an Invasion mission's script
        \\  trek chunks <model>             list an Invasion model's chunks
        \\  trek textures <model> <out-dir>
        \\                                  save an Invasion model's textures as PNG files
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
            .ls => |operands| try readArchive(ctx, operands.image, null),
            .extract => |operands| try readArchive(ctx, operands.image, operands.out_dir),
            .sections => |operands| try sections(ctx, try readMission(ctx, operands.mission)),
            .strings => |operands| try sltool.dte.printPool(ctx, (try readMission(ctx, operands.mission)).strings()),
            .parts => |operands| {
                var directory: [dte.section_count]dte.DirectoryEntry = undefined;
                try sltool.dte.parts(ctx, (try readMission(ctx, operands.mission)).asDte(&directory));
            },
            .script => |operands| {
                var directory: [dte.section_count]dte.DirectoryEntry = undefined;
                try sltool.dte.script(ctx, (try readMission(ctx, operands.mission)).asDte(&directory), null, .numbered);
            },
            .chunks => |operands| try chunks(ctx, try .parse(try ctx.readInput(operands.model))),
            .textures => |operands| try textures(ctx, operands.model, operands.out_dir),
        }
    }
};

/// Lists the archive on the disc image at `image_path`, or copies its files into `out_dir`.
fn readArchive(ctx: Context, image_path: []const u8, out_dir: ?[]const u8) !void {
    const image: cdimage.Image = try .open(ctx.io, .cwd(), image_path);
    defer image.close();
    const volume: iso9660.Volume = try .open(image);
    const archive: trek.res.Archive = try .open(ctx.arena, &volume);
    if (out_dir) |path| try extract(ctx, archive, path) else try list(ctx, archive);
}

fn readMission(ctx: Context, path: []const u8) !trek.dsm.Mission {
    return .parse(try ctx.readInput(path));
}

fn list(ctx: Context, archive: trek.res.Archive) !void {
    try ctx.stdout.writeAll(" slot   sector       bytes  name\n");
    var files: usize = 0;
    for (archive.slots, 0..) |slot, index| {
        const item = try archive.file(index) orelse continue;
        files += 1;
        try ctx.stdout.print("{d:>5}  {d:>7}  {d:>10}  {s}{s}\n", .{
            index,
            slot.sector,
            item.size,
            item.name orelse "-",
            if (item.streamed) "  (streamed)" else "",
        });
    }
    try ctx.stdout.print("{d} files in {d} slots, {d} of them named by the executable\n", .{ files, archive.slots.len, archive.names.len });
}

fn extract(ctx: Context, archive: trek.res.Archive, out_path: []const u8) !void {
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);

    var files: usize = 0;
    var streamed: usize = 0;
    var bytes: u64 = 0;
    for (0..archive.slots.len) |index| {
        const item = try archive.file(index) orelse continue;
        const path = try item.path(ctx.arena);
        if (std.Io.Dir.path.dirnamePosix(path)) |folder| try out_dir.createDirPath(io, folder);
        const file = try out_dir.createFile(io, path, .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try archive.copy(item, &writer.interface);
        try writer.interface.flush();
        files += 1;
        if (item.streamed) streamed += 1;
        bytes += item.copiedSize();
    }
    try ctx.stdout.print("extracted {d} files ({Bi:.1}) to {s}\n", .{ files, bytes, out_path });
    if (streamed != 0) try ctx.stdout.print(
        "kept {d} of them, with streamed audio or video, as whole {d}-byte Mode 2 sectors\n",
        .{ streamed, cdimage.mode2_size },
    );
}

fn sections(ctx: Context, mission: trek.dsm.Mission) !void {
    try ctx.stdout.writeAll("  #  count  flags    offset  section\n");
    for (mission.directory, 0..) |entry, index| {
        if (!entry.isUsed()) continue;
        const section: trek.dsm.Section = @fromBackingInt(@intCast(index));
        try ctx.stdout.print("{d:>3}  {d:>5}   0x{x:0>2}  {x:0>8}  {f}", .{ index, entry.count, entry.formats.byte(), entry.offset, section });
        if (section.asDte()) |original| {
            try ctx.stdout.writeAll(", the original's ");
            try openreliant.layout.formatTag(dte.Section, original, ctx.stdout);
        }
        try ctx.stdout.writeByte('\n');
    }
}

fn chunks(ctx: Context, model: trek.trk.Model) !void {
    if (model.number) |number| try ctx.stdout.print("model {d}\n", .{number});
    try ctx.stdout.writeAll("offset  id      bytes\n");
    var all = model.chunks();
    while (try all.next()) |chunk| {
        try ctx.stdout.print("{d:>6}  {s}  {d:>6}", .{ model.offsetOf(chunk), &chunk.id, chunk.body.len });
        if (std.mem.eql(u8, &chunk.id, trek.trk.texture_id)) {
            if (tim.Picture.parse(chunk.body)) |picture| {
                try ctx.stdout.print("  {d}x{d}, {f}", .{ picture.width, picture.height, picture.depth });
            } else |err| try ctx.stdout.print("  {t}", .{err});
        }
        try ctx.stdout.writeByte('\n');
    }
}

/// Saves each of the model's textures as `<model>_<n>.png` in `out_path`, counting from 0.
fn textures(ctx: Context, path: []const u8, out_path: []const u8) !void {
    const model: trek.trk.Model = try .parse(try ctx.readInput(path));
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(ctx.io);
    const stem = std.Io.Dir.path.stem(path);
    var saved: usize = 0;
    var all = model.chunks();
    while (try all.next()) |chunk| {
        if (!std.mem.eql(u8, &chunk.id, trek.trk.texture_id)) continue;
        const picture: tim.Picture = try .parse(chunk.body);
        const name = try ctx.arena.print("{s}_{d}.png", .{ stem, saved });
        try ctx.writePng(out_dir, name, picture.width, picture.height, try picture.rgba(ctx.arena));
        saved += 1;
    }
    try ctx.stdout.print("wrote {d} textures to {s}\n", .{ saved, out_path });
}

test Command {
    try std.testing.expectEqualStrings("disc.bin", (try Command.parse(&.{ "ls", "disc.bin" })).ls.image);
    try std.testing.expectEqualStrings("out", (try Command.parse(&.{ "textures", "E0.TRK", "out" })).textures.out_dir);
    try std.testing.expectEqualStrings("E217.DSM", (try Command.parse(&.{ "script", "E217.DSM" })).script.mission);
    try std.testing.expectError(error.Usage, Command.parse(&.{ "extract", "disc.bin" }));
    try std.testing.expectError(error.Usage, Command.parse(&.{"play"}));
}
