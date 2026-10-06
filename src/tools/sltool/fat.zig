//! `sltool fat ...`: read `.fat` sound banks and save their sounds as WAV files.

const std = @import("std");

const openreliant = @import("openreliant");
const fat = openreliant.fat;
const Wave = openreliant.wave.Wave;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    ls: struct { bank: []const u8 },
    /// Writes every sound as a WAV file, unchanged.
    extract: struct { bank: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  fat ls <bank>                   list a sound bank's sounds
        \\  fat extract <bank> <out-dir>    save every sound as a WAV file
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
            inline else => |operands| operands.bank,
        };
        const bank: fat.Bank = try .parse(try ctx.readInput(path));
        switch (command) {
            .ls => try ls(ctx, bank),
            .extract => |operands| try extract(ctx, bank, path, operands.out_dir),
        }
    }
};

fn ls(ctx: Context, bank: fat.Bank) !void {
    try ctx.stdout.print("{d} sounds\n\n", .{bank.entries.len});
    try ctx.stdout.writeAll("   #    offset     bytes  priority  format      ch   rate  seconds\n");
    for (bank.entries, 0..) |entry, i| {
        try ctx.stdout.print("{d:>4}  {d:>8}  {d:>8}  {d:>8}  ", .{ i, entry.offset, entry.size, entry.priority });
        const wave = Wave.parse(bank.sound(i).?) catch {
            try ctx.stdout.writeAll("not a WAVE file\n");
            continue;
        };
        // A custom formatter does not pad, so render into a buffer to keep the columns straight.
        var format: [16]u8 = undefined;
        try ctx.stdout.print("{s:<10}  {d:>2}  {d:>5}", .{
            std.mem.print(&format, "{f}", .{wave.format}) catch "?",
            wave.channels,
            wave.rate,
        });
        if (wave.seconds()) |length| try ctx.stdout.print("  {d:>7.2}", .{length});
        try ctx.stdout.writeByte('\n');
    }
}

fn extract(ctx: Context, bank: fat.Bank, source: []const u8, out_path: []const u8) !void {
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);

    const stem = std.Io.Dir.path.stem(std.Io.Dir.path.basename(source));
    for (0..bank.entries.len) |i| {
        const name = try ctx.arena.print("{s}_{d:0>3}.wav", .{ stem, i });
        try out_dir.writeFile(io, .{ .sub_path = name, .data = bank.sound(i).? });
    }
    try ctx.stdout.print("wrote {d} sounds to {s}\n", .{ bank.entries.len, out_path });
}

test Command {
    const parsed = try Command.parse(&.{ "extract", "betty.fat", "out" });
    try std.testing.expectEqualStrings("out", parsed.extract.out_dir);
    try std.testing.expectError(error.Usage, Command.parse(&.{"ls"}));
}
