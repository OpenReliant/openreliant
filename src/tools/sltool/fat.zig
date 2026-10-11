//! `sltool fat ...`: read `.fat` sound banks and save their sounds as WAV files. It reads the banks
//! of the format's first version too, which Privateer 2 ships, and saves their sounds as stored.

const std = @import("std");

const openreliant = @import("openreliant");
const fat = openreliant.fat;
const Wave = openreliant.wave.Wave;

const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    ls: struct { bank: []const u8 },
    /// Writes every sound as a WAV file, unchanged, or as stored for a bank of the first version.
    extract: struct { bank: []const u8, out_dir: []const u8 },

    pub const usage =
        \\  fat ls <bank>                   list a sound bank's sounds
        \\  fat extract <bank> <out-dir>    save every sound as a WAV file, or as stored for a
        \\                                  bank of the first version, such as Privateer 2's
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
        const bytes = try ctx.readInput(path);
        const bank = fat.Bank.parse(bytes) catch |err| switch (err) {
            error.NotABank => {
                const first = try fat.v1.Bank.parse(bytes);
                return switch (command) {
                    .ls => lsFirst(ctx, first),
                    .extract => |operands| extractFirst(ctx, first, path, operands.out_dir),
                };
            },
            else => return err,
        };
        switch (command) {
            .ls => try ls(ctx, bank),
            .extract => |operands| try extract(ctx, bank, path, operands.out_dir),
        }
    }
};

fn ls(ctx: Context, bank: fat.Bank) !void {
    try ctx.stdout.print("{f}\n\n", .{sltool.count(bank.entries.len, "sound")});
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

/// The sounds of a bank of the first version, with what its entries give.
fn lsFirst(ctx: Context, bank: fat.v1.Bank) !void {
    try ctx.stdout.print("version {s}, {f}\n\n", .{ fat.v1.magic, sltool.count(bank.entries.len, "sound") });
    try ctx.stdout.writeAll("   #    offset     bytes  priority   decoded  unknown\n");
    for (bank.entries, 0..) |entry, i| {
        try ctx.stdout.print("{d:>4}  {d:>8}  {d:>8}  {d:>8}  {d:>8}  {x}\n", .{ i, entry.offset, bank.sound(i).?.len, entry.priority, entry.decoded.size, &entry.unknown });
    }
}

/// Writes the sounds of a bank of the first version as stored, since their codec is unknown.
fn extractFirst(ctx: Context, bank: fat.v1.Bank, source: []const u8, out_path: []const u8) !void {
    try writeEach(ctx, bank, source, out_path, "raw");
    try ctx.stdout.writeAll("the sounds are as stored: their codec is unknown (docs/games/privateer-2.md)\n");
}

fn extract(ctx: Context, bank: fat.Bank, source: []const u8, out_path: []const u8) !void {
    try writeEach(ctx, bank, source, out_path, "wav");
}

/// Writes each sound of `bank`, of either version, as `<bank>_<n>.<extension>` in `out_path`.
fn writeEach(ctx: Context, bank: anytype, source: []const u8, out_path: []const u8, comptime extension: []const u8) !void {
    const count = bank.entries.len;
    const io = ctx.io;
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);

    const stem = std.Io.Dir.path.stem(std.Io.Dir.path.basename(source));
    for (0..count) |i| {
        const name = try ctx.arena.print("{s}_{d:0>3}." ++ extension, .{ stem, i });
        try out_dir.writeFile(io, .{ .sub_path = name, .data = bank.sound(i).? });
    }
    try ctx.stdout.print("wrote {f} to {s}\n", .{ sltool.count(count, "sound"), out_path });
}

test Command {
    const parsed = try Command.parse(&.{ "extract", "betty.fat", "out" });
    try std.testing.expectEqualStrings("out", parsed.extract.out_dir);
    try std.testing.expectError(error.Usage, Command.parse(&.{"ls"}));
}
