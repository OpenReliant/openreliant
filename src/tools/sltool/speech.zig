//! `sltool speech ...`: decode the radio's speech files, `.ut`, of the game's own codec
//! ([`engine/game/voice.zig`](../../engine/game/voice.zig)), to WAV, the samples as the game
//! makes them; or encode a WAV file to one (`speech_encode.zig`).

const std = @import("std");
const Io = std.Io;

const openreliant = @import("openreliant");
const cbox = openreliant.engine.game.cbox;
const hog = openreliant.hog;
const wave = openreliant.wave;

const encoder = @import("speech_encode.zig");
const sltool = @import("main.zig");
const Context = sltool.Context;

pub const Command = union(enum) {
    decode: struct { file: []const u8, out: []const u8 },
    /// Decodes every member that is a speech file.
    extract: struct { archive: []const u8, out_dir: []const u8 },
    /// Encodes a WAV file to a speech file.
    encode: struct { wav: []const u8, out: []const u8 },

    pub const usage =
        \\  speech decode <file> <out.wav>  decode a speech file to a WAV file
        \\  speech extract <archive> <out-dir>
        \\                                  decode every line of a speech archive to WAV files
        \\  speech encode <in.wav> <out.ut>  encode a WAV file to a speech file, mixed to mono
        \\                                  at 22,050 Hz
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
            .decode => |operands| try decode(ctx, operands.file, operands.out),
            .extract => |operands| try extract(ctx, operands.archive, operands.out_dir),
            .encode => |operands| try encode(ctx, operands.wav, operands.out),
        }
    }
};

fn decode(ctx: Context, path: []const u8, out: []const u8) !void {
    const bytes = try ctx.readInput(path);
    const speech = cbox.Speech.parse(bytes) orelse return error.NotASpeechFile;
    const samples = try cbox.decode(ctx.arena, speech, .cut);
    const file = try wave.pcm16(ctx.arena, cbox.rate, 1, samples);
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = out, .data = file });
    try ctx.stdout.print("wrote {d} samples, {d:.2} s, to {s}\n", .{ samples.len, @as(f64, @floatFromInt(samples.len)) / cbox.rate, out });
}

/// Writes `out`, a speech file of the WAV file at `path`: its channels mixed to one and taken to
/// the speech's rate (`resampled`).
fn encode(ctx: Context, path: []const u8, out: []const u8) !void {
    const bytes = try ctx.readInput(path);
    const sound = try wave.Wave.parse(bytes);
    var reader: wave.Decoder = try .init(sound);
    const mixed = try ctx.arena.alloc(f32, reader.frames);
    for (mixed) |*value| {
        const frame = reader.next().?;
        value.* = if (sound.channels == 2) (@as(f32, @floatFromInt(frame[0])) + @as(f32, @floatFromInt(frame[1]))) / 2 else @floatFromInt(frame[0]);
    }
    const samples = try resampled(ctx.arena, mixed, sound.rate, cbox.rate);
    const file = try encoder.encode(ctx.arena, samples, .{});
    try Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = out, .data = file });
    try ctx.stdout.print("wrote {d} samples, {d:.2} s, to {s}, {d} bytes\n", .{ samples.len, @as(f64, @floatFromInt(samples.len)) / cbox.rate, out, file.len });
}

/// `samples` at `from` samples a second taken to `to`, each new sample between the two old ones
/// around it; going down, each first the mean of the old ones it covers.
fn resampled(gpa: std.mem.Allocator, samples: []const f32, from: u32, to: u32) ![]i16 {
    const ratio = @as(f64, @floatFromInt(from)) / @as(f64, @floatFromInt(to));
    const count: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(samples.len)) / ratio));
    const out = try gpa.alloc(i16, count);
    const span: usize = @max(1, @as(usize, @intFromFloat(@floor(ratio))));
    for (out, 0..) |*value, i| {
        const at = @as(f64, @floatFromInt(i)) * ratio;
        const index: usize = @intFromFloat(@floor(at));
        var sum: f64 = 0;
        for (0..span) |k| {
            const here = samples[@min(index + k, samples.len - 1)];
            const next = samples[@min(index + k + 1, samples.len - 1)];
            const share = at - @floor(at);
            sum += here + (next - here) * share;
        }
        value.* = @intFromFloat(std.math.clamp(@round(sum / @as(f64, @floatFromInt(span))), -32768, 32767));
    }
    return out;
}

test resampled {
    const gpa = std.testing.allocator;
    // At the same rate, the samples as they are; at twice the rate, half as many, averaged.
    const same = try resampled(gpa, &.{ 1, 2, 3, 4 }, 22050, 22050);
    defer gpa.free(same);
    try std.testing.expectEqualSlices(i16, &.{ 1, 2, 3, 4 }, same);
    const halved = try resampled(gpa, &.{ 0, 2, 4, 6 }, 44100, 22050);
    defer gpa.free(halved);
    try std.testing.expectEqualSlices(i16, &.{ 1, 5 }, halved);
}

fn extract(ctx: Context, path: []const u8, out_path: []const u8) !void {
    const io = ctx.io;
    var archive = try hog.Archive.open(ctx.arena, io, .cwd(), path);
    defer archive.close(ctx.arena);
    var out_dir = try ctx.outputDir(out_path);
    defer out_dir.close(io);
    // Each line's bytes, samples and file live only as long as it takes to write it.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var written: usize = 0;
    var skipped: usize = 0;
    for (archive.entries) |entry| {
        _ = scratch.reset(.retain_capacity);
        const gpa = scratch.allocator();
        const contents = try archive.read(gpa, entry);
        const speech = cbox.Speech.parse(contents.bytes) orelse {
            skipped += 1;
            continue;
        };
        const samples = try cbox.decode(gpa, speech, .cut);
        const file = try wave.pcm16(gpa, cbox.rate, 1, samples);
        const name = try gpa.print("{s}.wav", .{entry.name});
        try out_dir.writeFile(io, .{ .sub_path = name, .data = file });
        written += 1;
    }
    try ctx.stdout.print("wrote {f} to {s}", .{ sltool.count(written, "line"), out_path });
    if (skipped > 0) try ctx.stdout.print(", skipped {f} that aren't speech files", .{sltool.count(skipped, "member")});
    try ctx.stdout.writeByte('\n');
}

test Command {
    const parsed = try Command.parse(&.{ "decode", "ms1_ban_001", "out.wav" });
    try std.testing.expectEqualStrings("out.wav", parsed.decode.out);
    try std.testing.expectEqualStrings("lines", (try Command.parse(&.{ "extract", "msspeech.hog", "lines" })).extract.out_dir);
    try std.testing.expectError(error.Usage, Command.parse(&.{"decode"}));
    try std.testing.expectEqualStrings("line.ut", (try Command.parse(&.{ "encode", "line.wav", "line.ut" })).encode.out);
}
