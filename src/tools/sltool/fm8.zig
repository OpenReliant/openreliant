//! `sltool fm8 ...`: read the pilots' face films (`.fm8`,
//! [`engine/game/talkie.zig`](../../engine/game/talkie.zig)) and save their frames as PNG files,
//! or make a film from PNG files (`fm8_encode.zig`).

const std = @import("std");

const openreliant = @import("openreliant");
const png = openreliant.png;
const talkie = openreliant.engine.game.talkie;

const encoder = @import("fm8_encode.zig");
const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    info: struct { film: []const u8 },
    /// Writes every frame as an indexed PNG file over the film's palette.
    extract: struct { film: []const u8, out_dir: []const u8 },
    /// Writes a film of the PNG files in a folder, in their names' order.
    encode: struct { frames_dir: []const u8, film: []const u8 },

    pub const usage =
        \\  fm8 info <film>                 a face film's frames and chunks
        \\  fm8 extract <film> <out-dir>    save every frame as a PNG file
        \\  fm8 encode <frames-dir> <film>  make a film of a folder's PNG files, in name order,
        \\                                  each 120 by 100 for a face
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
            .info => |operands| try info(ctx, try ctx.readInput(operands.film)),
            .extract => |operands| try extract(ctx, try ctx.readInput(operands.film), operands.film, operands.out_dir),
            .encode => |operands| try encode(ctx, operands.frames_dir, operands.film),
        }
    }
};

fn info(ctx: Context, bytes: []u8) !void {
    var film: talkie.Film = .init(ctx.arena);
    defer film.deinit();
    var chunks: talkie.Chunks = .{ .bytes = bytes };
    var frames: usize = 0;
    var keys: usize = 0;
    var bad: usize = 0;
    try ctx.stdout.writeAll("   #  chunk  bytes\n");
    var index: usize = 0;
    while (chunks.next()) |chunk| : (index += 1) {
        try ctx.stdout.print("{d:>4}  {s:<5}  {d:>5}\n", .{ index, chunk.bytes[0..4], chunk.bytes.len });
        const decoded = film.decode(chunk) catch {
            bad += 1;
            continue;
        };
        if (decoded) frames += 1;
        if (chunk.id == .key) keys += 1;
    }
    try ctx.stdout.print("\n{d} frames of {d} x {d}, {d} of them key frames, {d:.2} s at {d} a second", .{ frames, film.width, film.height, keys, @as(f64, @floatFromInt(frames)) / talkie.frames_per_second, talkie.frames_per_second });
    if (film.transparent) |index_seen| try ctx.stdout.print(", see-through entry {d}", .{index_seen});
    if (bad > 0) try ctx.stdout.print(", {d} chunks not decoded", .{bad});
    try ctx.stdout.writeByte('\n');
}

/// Writes `film_path`, a film of the PNG files in `frames_path`, in the order of their names.
fn encode(ctx: Context, frames_path: []const u8, film_path: []const u8) !void {
    const io = ctx.io;
    var dir = try std.Io.Dir.cwd().openDir(io, frames_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var walk = dir.iterate();
    while (try walk.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".png")) continue;
        try names.append(ctx.arena, try ctx.arena.dupe(u8, entry.name));
    }
    if (names.items.len == 0) {
        try ctx.stdout.print("{s} has no PNG files\n", .{frames_path});
        return error.NoFrames;
    }
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    const frames = try ctx.arena.alloc([]const u8, names.items.len);
    var size: ?[2]u32 = null;
    for (names.items, frames) |name, *frame| {
        const bytes = try dir.readFileAlloc(io, name, ctx.arena, .limited(64 * 1024 * 1024));
        const picture = try png.read(ctx.arena, bytes);
        const own: [2]u32 = .{ picture.width, picture.height };
        if (size) |first| if (!std.mem.eql(u32, &first, &own)) {
            try ctx.stdout.print("{s} is {d} by {d}, where the first frame is {d} by {d}\n", .{ name, own[0], own[1], first[0], first[1] });
            return error.BadFrames;
        };
        size = own;
        frame.* = picture.rgba;
    }
    const width = std.math.cast(u16, size.?[0]) orelse return error.BadFrames;
    const height = std.math.cast(u16, size.?[1]) orelse return error.BadFrames;
    const film = encoder.encode(ctx.arena, width, height, frames) catch |err| {
        if (err == error.BadFrames) try ctx.stdout.print("the frames are {d} by {d}, which isn't a whole number of 4 by 4 blocks\n", .{ width, height });
        return err;
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = film_path, .data = film });
    try ctx.stdout.print("wrote {d} frames of {d} by {d} to {s}, {d} bytes\n", .{ frames.len, width, height, film_path, film.len });
}

fn extract(ctx: Context, bytes: []u8, source: []const u8, out_path: []const u8) !void {
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);
    const stem = std.fs.path.stem(std.fs.path.basename(source));
    var film: talkie.Film = .init(ctx.arena);
    defer film.deinit();
    var chunks: talkie.Chunks = .{ .bytes = bytes };
    var written: usize = 0;
    while (chunks.next()) |chunk| {
        const decoded = film.decode(chunk) catch |err| {
            try ctx.stdout.print("chunk {d} of {s} is not decoded: {s}\n", .{ written, source, @errorName(err) });
            continue;
        };
        if (!decoded) continue;
        const name = try std.fmt.allocPrint(ctx.arena, "{s}_{d:0>3}.png", .{ stem, written });
        defer ctx.arena.free(name);
        const file = try out_dir.createFile(io, name, .{});
        defer file.close(io);
        var buffer: [32 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try png.writeIndexed(ctx.arena, &writer.interface, .{
            .width = @intCast(film.width),
            .height = @intCast(film.height),
            .palette = &film.palette,
            .transparent = film.transparent,
        }, film.frame());
        try writer.interface.flush();
        written += 1;
    }
    try ctx.stdout.print("wrote {d} frames to {s}\n", .{ written, out_path });
}

test Command {
    const parsed = try Command.parse(&.{ "extract", "45Tigers_Plt.fm8", "frames" });
    try std.testing.expectEqualStrings("frames", parsed.extract.out_dir);
    try std.testing.expectEqualStrings("a.fm8", (try Command.parse(&.{ "info", "a.fm8" })).info.film);
    try std.testing.expectError(error.Usage, Command.parse(&.{"info"}));
    const encoding = try Command.parse(&.{ "encode", "frames", "face.fm8" });
    try std.testing.expectEqualStrings("frames", encoding.encode.frames_dir);
    try std.testing.expectEqualStrings("face.fm8", encoding.encode.film);
}

test {
    _ = encoder;
}
