//! Loudness as ITU-R BS.1770 measures it, in LUFS, which OpenReliant matches one recording to
//! another by: each channel weighted as the ear hears it (K-weighting: a shelf that lifts the
//! highs, and a high-pass under the bass), its power taken over blocks of 400 ms every 100 ms, and
//! the blocks under -70 LUFS left out, then those more than 10 LU under the rest. Not Miles's.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The blocks' length and the step between them, in seconds.
const block_seconds = 0.4;
const step_seconds = 0.1;

/// The gates: the loudness under which a block counts as silence, and how far under the loudness
/// of the blocks left a block is then left out, in LU.
const absolute_gate = -70.0;
const relative_gate = -10.0;

/// The offset that makes a full-scale sine of 997 Hz in one channel read -3.01 LUFS.
const offset = -0.691;

/// The level of a 16-bit sample at full scale.
const full_scale = 32768.0;

/// The analogue filters BS.1770's K-weighting stands for, as libebur128 fits them: a shelf that
/// lifts the frequencies over about 1.5 kHz by 4 dB, as the head does, and a high-pass that leaves
/// out the bass under about 38 Hz. The shelf's band gain is its gain raised to `shelf_band`.
const shelf_frequency: f64 = 1681.974450955533;
const shelf_gain: f64 = 3.999843853973347;
const shelf_q: f64 = 0.7071752369554196;
const shelf_band: f64 = 0.4996667741545416;
const high_pass_frequency: f64 = 38.13547087602444;
const high_pass_q: f64 = 0.5003270373238773;

/// A biquad filter, one of K-weighting's, worked out for the rate it runs at from the analogue
/// filter it stands for.
const Biquad = struct {
    b: [3]f64,
    a: [2]f64,
    z: [2]f64 = .{ 0, 0 },

    fn shelf(rate: f64) Biquad {
        const k = @tan(std.math.pi * shelf_frequency / rate);
        const vh = std.math.pow(f64, 10, shelf_gain / 20);
        const vb = std.math.pow(f64, vh, shelf_band);
        const a0 = 1 + k / shelf_q + k * k;
        return .{
            .b = .{ (vh + vb * k / shelf_q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / shelf_q + k * k) / a0 },
            .a = .{ 2 * (k * k - 1) / a0, (1 - k / shelf_q + k * k) / a0 },
        };
    }

    fn highPass(rate: f64) Biquad {
        const k = @tan(std.math.pi * high_pass_frequency / rate);
        const a0 = 1 + k / high_pass_q + k * k;
        return .{
            .b = .{ 1, -2, 1 },
            .a = .{ 2 * (k * k - 1) / a0, (1 - k / high_pass_q + k * k) / a0 },
        };
    }

    /// The next output for `x`, as a transposed direct form II.
    fn step(filter: *Biquad, x: f64) f64 {
        const y = filter.b[0] * x + filter.z[0];
        filter.z[0] = filter.b[1] * x - filter.a[0] * y + filter.z[1];
        filter.z[1] = filter.b[2] * x - filter.a[1] * y;
        return y;
    }
};

/// The most channels `integrated` weighs.
pub const max_channels = 8;

/// The integrated loudness of `samples`, 16-bit, `channels` to a frame, at `rate` frames a second:
/// each channel counted alike, as BS.1770 counts those ahead. Null for none, or for a recording
/// all silence. One shorter than a block is taken as a single block.
pub fn integrated(gpa: Allocator, samples: []align(1) const i16, channels: usize, rate: u32) Allocator.Error!?f32 {
    if (channels == 0 or channels > max_channels or rate == 0) return null;
    const frames = samples.len / channels;
    if (frames == 0) return null;
    const step: usize = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(rate)) * step_seconds)));

    // The weighted power of each step's frames, summed over the channels.
    const powers = try gpa.alloc(f64, (frames + step - 1) / step);
    defer gpa.free(powers);
    @memset(powers, 0);
    var filters: [max_channels][2]Biquad = undefined;
    for (filters[0..channels]) |*pair| pair.* = .{ .shelf(@floatFromInt(rate)), .highPass(@floatFromInt(rate)) };
    for (0..frames) |frame| {
        for (filters[0..channels], 0..) |*pair, channel| {
            const x = @as(f64, @floatFromInt(samples[frame * channels + channel])) / full_scale;
            const y = pair[1].step(pair[0].step(x));
            powers[frame / step] += y * y;
        }
    }

    // The gates leave out the silent blocks, then the quiet ones.
    const blocks: Blocks = .{ .powers = powers, .frames = frames, .step = step };
    const loud = blocks.meanOver(absolute_gate) orelse return null;
    const kept = blocks.meanOver(@max(absolute_gate, loudnessOf(loud) + relative_gate)) orelse return null;
    return @floatCast(loudnessOf(kept));
}

/// The blocks of a recording: `block_seconds` long each, a step of `step` frames apart, over the
/// power of each step. A recording shorter than a block is one block of what there is.
const Blocks = struct {
    powers: []const f64,
    frames: usize,
    step: usize,

    /// The steps a block spans.
    fn length(blocks: Blocks) usize {
        const steps_per_block: usize = @intFromFloat(block_seconds / step_seconds);
        return @min(steps_per_block, blocks.powers.len);
    }

    /// The mean power of the blocks louder than `gate`, in LUFS; null for none.
    fn meanOver(blocks: Blocks, gate: f64) ?f64 {
        const span = blocks.length();
        var sum: f64 = 0;
        var count: usize = 0;
        for (0..blocks.powers.len - span + 1) |first| {
            const mean = blocks.meanPower(first, span);
            if (loudnessOf(mean) <= gate) continue;
            sum += mean;
            count += 1;
        }
        return if (count == 0) null else sum / @as(f64, @floatFromInt(count));
    }

    /// The mean power of the block starting at step `first`, `span` steps long.
    fn meanPower(blocks: Blocks, first: usize, span: usize) f64 {
        var sum: f64 = 0;
        for (blocks.powers[first..][0..span]) |each| sum += each;
        const start = first * blocks.step;
        const end = @min(blocks.frames, (first + span) * blocks.step);
        return sum / @as(f64, @floatFromInt(end - start));
    }
};

/// The loudness of a mean power, in LUFS.
fn loudnessOf(power: f64) f64 {
    if (power <= 0) return -std.math.inf(f64);
    return offset + 10 * std.math.log10(power);
}

/// A sine of `frequency` Hz at `amplitude` of full scale, `seconds` long at `rate`, in `gpa`.
fn testSine(gpa: Allocator, frequency: f64, amplitude: f64, seconds: f64, rate: u32) ![]i16 {
    const count: usize = @intFromFloat(seconds * @as(f64, @floatFromInt(rate)));
    const samples = try gpa.alloc(i16, count);
    for (samples, 0..) |*sample, n| {
        const t = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(rate));
        sample.* = @intFromFloat(@round(amplitude * 32767 * @sin(2 * std.math.pi * frequency * t)));
    }
    return samples;
}

test integrated {
    const gpa = std.testing.allocator;
    // A full-scale sine of 997 Hz reads -3.01 LUFS, as BS.1770's calibration has it, at the
    // speech's rate as at 48 kHz; one a tenth of that, 20 dB quieter.
    for ([_]u32{ 22050, 48000 }) |rate| {
        const full = try testSine(gpa, 997, 1, 2, rate);
        defer gpa.free(full);
        try std.testing.expectApproxEqAbs(-3.01, (try integrated(gpa, full, 1, rate)).?, 0.05);
        const tenth = try testSine(gpa, 997, 0.1, 2, rate);
        defer gpa.free(tenth);
        try std.testing.expectApproxEqAbs(-23.01, (try integrated(gpa, tenth, 1, rate)).?, 0.05);
    }
    // Silence reads nothing, and more silence around a sound changes nothing: the gates leave it
    // out, though the blocks that straddle the sound's edges count.
    const rate = 22050;
    const quiet = [_]i16{0} ** (rate * 2);
    try std.testing.expectEqual(null, try integrated(gpa, &quiet, 1, rate));
    const sine = try testSine(gpa, 997, 0.5, 1, rate);
    defer gpa.free(sine);
    var readings: [2]f32 = undefined;
    for ([_]usize{ 1, 5 }, &readings) |seconds, *reading| {
        const padded = try gpa.alloc(i16, rate * (2 * seconds + 1));
        defer gpa.free(padded);
        @memset(padded, 0);
        @memcpy(padded[rate * seconds ..][0..sine.len], sine);
        reading.* = (try integrated(gpa, padded, 1, rate)).?;
    }
    try std.testing.expectApproxEqAbs(readings[0], readings[1], 1e-4);
    const alone = (try integrated(gpa, sine, 1, rate)).?;
    // Two channels alike read 3 dB louder than one; a sound shorter than a block reads too.
    const stereo = try gpa.alloc(i16, sine.len * 2);
    defer gpa.free(stereo);
    for (sine, 0..) |value, n| stereo[2 * n ..][0..2].* = .{ value, value };
    try std.testing.expectApproxEqAbs(alone + 3.01, (try integrated(gpa, stereo, 2, rate)).?, 0.05);
    try std.testing.expect(try integrated(gpa, sine[0 .. rate / 10], 1, rate) != null);
}
