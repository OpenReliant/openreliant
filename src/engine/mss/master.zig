//! The master bus: what the whole mix passes through on its way to the device. **Improvement:** the
//! game's mix is only clipped at full scale; OpenReliant evens it out with a gentle compressor,
//! then holds its peaks under the ceiling with a limiter that looks a few milliseconds ahead, so
//! that a dozen guns firing close by stay clean. `--original` leaves it out.

const std = @import("std");

/// The most channels and the longest look-ahead it keeps room for.
pub const max_channels = 8;
const max_lookahead = 512;

pub const Settings = struct {
    /// Where compression starts, in dBFS, and how much a level over it is reduced: 2 means half.
    threshold: f32 = -18,
    ratio: f32 = 2,
    /// The width of the soft knee around the threshold, in dB.
    knee: f32 = 6,
    attack: f32 = 0.010,
    release: f32 = 0.200,
    /// Added back after compression, in dB.
    makeup: f32 = 2,
    /// The limiter's ceiling in dBFS, how far ahead it looks, and how fast it lets go, in seconds.
    ceiling: f32 = -0.3,
    lookahead: f32 = 0.003,
    limiter_release: f32 = 0.080,

    /// The compressor taken out and the limiter kept: compression of 1 to 1, nothing made up.
    pub fn withoutCompressor(settings: Settings) Settings {
        var limited = settings;
        limited.ratio = 1;
        limited.makeup = 0;
        return limited;
    }

    /// Whether it compresses, as against holding the peaks alone.
    pub fn compresses(settings: Settings) bool {
        return settings.ratio > 1;
    }
};

pub const Master = struct {
    channels: usize,
    settings: Settings,
    attack: f32,
    release: f32,
    limiter_attack: f32,
    limiter_release: f32,
    makeup: f32,
    ceiling: f32,
    /// The compressor's level detector and gain.
    level: f32 = 0,
    gain: f32 = 1,
    /// The limiter: the frames it holds back, the gain each needs, and the gain it is at.
    lookahead: usize,
    delay: [max_lookahead * max_channels]f32 = @splat(0),
    needed: [max_lookahead]f32 = @splat(1),
    at: usize = 0,
    limiter_gain: f32 = 1,

    pub fn init(rate: u32, channels: usize, settings: Settings) Master {
        const frames_per_second: f32 = @floatFromInt(rate);
        const lookahead = std.math.clamp(@as(usize, @intFromFloat(settings.lookahead * frames_per_second)), 1, max_lookahead);
        return .{
            .channels = std.math.clamp(channels, 1, max_channels),
            .settings = settings,
            .attack = coefficient(settings.attack, frames_per_second),
            .release = coefficient(settings.release, frames_per_second),
            // The limiter comes down over a third of its look-ahead, so it is down before the peak.
            .limiter_attack = coefficient(settings.lookahead / 3, frames_per_second),
            .limiter_release = coefficient(settings.limiter_release, frames_per_second),
            .makeup = decibels(settings.makeup),
            .ceiling = decibels(settings.ceiling),
            .lookahead = lookahead,
        };
    }

    /// Passes `samples`, frames of `channels` interleaved, through the bus in place.
    pub fn process(master: *Master, samples: []f32) void {
        const channels = master.channels;
        var frame: usize = 0;
        while (frame + channels <= samples.len) : (frame += channels) {
            const in = samples[frame..][0..channels];
            var peak: f32 = 0;
            for (in) |sample| peak = @max(peak, @abs(sample));

            // The compressor, on the frame's peak across the channels.
            const toward = if (peak > master.level) master.attack else master.release;
            master.level += (peak - master.level) * toward;
            master.gain = master.reduction(master.level) * master.makeup;
            for (in) |*sample| sample.* *= master.gain;

            // The limiter: the frame goes into the delay, and the one leaving it takes the lowest
            // gain any frame still in the delay needs.
            const need = if (peak * master.gain > master.ceiling) master.ceiling / (peak * master.gain) else 1;
            var lowest = need;
            for (master.needed[0..master.lookahead]) |gain| lowest = @min(lowest, gain);
            const slot = master.at;
            const held = master.delay[slot * channels ..][0..channels];
            var out: [max_channels]f32 = undefined;
            @memcpy(out[0..channels], held);
            @memcpy(held, in);
            master.needed[slot] = need;
            master.at = (slot + 1) % master.lookahead;
            const coef = if (lowest < master.limiter_gain) master.limiter_attack else master.limiter_release;
            master.limiter_gain += (lowest - master.limiter_gain) * coef;
            for (in, out[0..channels]) |*sample, delayed| {
                sample.* = std.math.clamp(delayed * master.limiter_gain, -master.ceiling, master.ceiling);
            }
        }
    }

    /// The compressor's gain for a level: none below the knee, the ratio's above it, and a smooth
    /// bend between.
    fn reduction(master: *const Master, level: f32) f32 {
        if (level <= 0) return 1;
        const s = master.settings;
        const over = 20 * std.math.log10(level) - s.threshold;
        const slope = 1 - 1 / s.ratio;
        const cut = if (over <= -s.knee / 2)
            0
        else if (over >= s.knee / 2)
            slope * over
        else
            slope * (over + s.knee / 2) * (over + s.knee / 2) / (2 * s.knee);
        return decibels(-cut);
    }
};

fn coefficient(seconds: f32, rate: f32) f32 {
    return 1 - @exp(-1 / @max(seconds * rate, 1));
}

fn decibels(db: f32) f32 {
    return std.math.pow(f32, 10, db / 20);
}

test Master {
    // A quiet tone, well under the threshold, comes out delayed and raised by the make-up alone.
    var master: Master = .init(48000, 2, .{});
    var quiet: [2 * 4800]f32 = undefined;
    for (0..4800) |i| {
        const value = 0.01 * @sin(@as(f32, @floatFromInt(i)) * 0.05);
        quiet[2 * i] = value;
        quiet[2 * i + 1] = value;
    }
    const input = quiet;
    master.process(&quiet);
    const late = 4000;
    const delayed = input[2 * (late - master.lookahead)];
    try std.testing.expectApproxEqAbs(delayed * decibels(2), quiet[2 * late], 1e-4);

    // A loud one is brought down, and a sudden peak past full scale never gets through.
    var loud: [2 * 4800]f32 = undefined;
    for (0..4800) |i| {
        const value: f32 = if (i == 3000) 3 else 0.9 * @sin(@as(f32, @floatFromInt(i)) * 0.05);
        loud[2 * i] = value;
        loud[2 * i + 1] = value;
    }
    master = .init(48000, 2, .{});
    master.process(&loud);
    var highest: f32 = 0;
    for (loud) |sample| highest = @max(highest, @abs(sample));
    try std.testing.expect(highest <= decibels(-0.3) + 1e-6);
    try std.testing.expect(master.gain < 1);
}
