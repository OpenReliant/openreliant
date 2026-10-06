//! The radio's speech codec, which decodes the speech files (`.ut`, in `msspeech.hog`): a coder of
//! frames of 432 samples at 22,050 Hz, each of four subframes of 108, from twelve reflection
//! coefficients, a pitch predictor and a pulse excitation.
//! [docs/formats/speech.md](../../../docs/formats/speech.md) describes the stream.
//!
//! **Unverified:** no string places its code (`0x004A7290` to `0x004A8101`), which lies between
//! `timer.cpp`'s and `winmain.cpp`'s. OpenReliant calls it `voice.cpp`, which sorts between the
//! two. `cbox.zig` plays what it decodes.

const std = @import("std");
const assert = std.debug.assert;

pub const tables = @import("voice/tables.zig");

/// The samples of a frame, and of each of its four subframes.
pub const frame_samples = 432;
pub const subframe_samples = 108;

/// How many reflection coefficients a frame gives, and how many samples its synthesis filter
/// works in at a time: the first three blocks with the coefficients a quarter, a half and three
/// quarters of the way to the frame's, the rest with the frame's own (`0x004A75F5`).
pub const order = 12;
pub const block = 12;

/// How many samples of past excitation the pitch predictor keeps.
pub const history_samples = 324;

/// The first subframe's start in the history less the pitch predictor's shortest lag: it reaches
/// back `subframe_samples` and the lag it reads (`0x004A7456`).
pub const pitch_reach = history_samples - subframe_samples;

/// How the frame's coefficients step toward the ones it reads: a quarter of the way in each of
/// the first four blocks (`0x004DC3D4`).
pub const coefficient_step: f32 = 0.25;

/// The first four coefficients take any of `tables.levels`; the other eight the 32 from this one
/// on (`0x00509124`).
pub const narrow_levels = 16;

/// The gains of a stream: the first, the header's four bits plus one times `gain_step`, and each
/// after it the one before times a ratio, `ratio_base` plus the header's six bits times
/// `ratio_step` (`0x004DC45C`, `0x004DCA24`, `0x004DC418`).
pub const gain_step: f32 = 8;
pub const ratio_base: f32 = 1.04;
pub const ratio_step: f32 = 0.001;

/// What a subframe's four bits of pitch gain are worth each (`0x004DCA28`).
pub const pitch_step: f32 = 1.0 / 15.0;

/// The weights of the filter that fills in every other sample of an excitation read at a step of
/// two, for the samples one, three and five away (`0x004DCA2C`, `0x004DCA30`, `0x004DCA34`); and
/// the gain the excitation then takes (`0x004DC808`).
const fill_weights = [3]f32{ 0.5973859429359436, -0.1145915612578392, 0.018032679334282875 };
pub const filled_gain: f32 = 0.5;

/// The pulses the plain code gives, for its two-bit codes `01` and `11` (`0x004A77FF`).
pub const plain_pulse: f32 = 2;

/// The length an escape of the pulse code starts at, one more for each leading 1 bit
/// (`0x004A7760`); and the least run of zeros its run codes give, and the bits they add
/// (`0x004A7709`).
pub const escape_base = 7;
pub const run_base = 7;
pub const run_bits = 6;

/// A frame's samples, or the state of a stream as the game lays it out after its bit reader
/// (`+0x0C` on): whether the subframes read their pulses at a step of two, how many levels of the
/// first coefficient the pulses take the variable code for, the gains, the reflection
/// coefficients, the synthesis filter's memory, and the history: the past excitation, then the
/// frame's samples.
pub const State = extern struct {
    stepped: u32,
    coded_levels: u32,
    gains: [64]f32,
    reflection: [order]f32,
    memory: [order]f32,
    history: [history_samples + frame_samples]f32,

    comptime {
        // As the game's, from the stream's start.
        assert(@offsetOf(State, "gains") + 0x0C == 0x14);
        assert(@offsetOf(State, "reflection") + 0x0C == 0x114);
        assert(@offsetOf(State, "memory") + 0x0C == 0x144);
        assert(@offsetOf(State, "history") + 0x0C == 0x174);
    }

    /// The frame's samples, once `Decoder.frame` has decoded it.
    pub fn samples(state: *const State) *const [frame_samples]f32 {
        return state.history[history_samples..];
    }

    /// The sample `index` places from the history's start, which may lie before it: a pitch lag
    /// past `pitch_reach` reads the gains, the coefficients and the filter's memory as samples,
    /// as the game's decoder does.
    fn pitchSource(state: *const State, index: i32) f32 {
        const flat: [*]const f32 = @ptrCast(&state.gains);
        const from_gains = @offsetOf(State, "history") - @offsetOf(State, "gains");
        return flat[@intCast(@as(i32, from_gains / @sizeOf(f32)) + index)];
    }
};

/// The stream's bits, least significant first, a byte at a time, which the game keeps before its
/// state: where the next byte is, the bits held and how many (`+0x00` to `+0x08`).
pub const Bits = struct {
    data: []const u8,
    next: usize = 1,
    held: u32,
    count: u5 = 8,

    pub fn init(data: []const u8) Bits {
        return .{ .data = data, .held = if (data.len > 0) data[0] else 0 };
    }

    /// `0x004A7360`: the next `n` bits, eight at most, and the stream past them.
    pub fn read(bits: *Bits, n: u4) u32 {
        const value = bits.held & mask(n);
        bits.skip(n);
        return value;
    }

    /// `0x004A7850`: the stream past its next `n` bits, eight at most. Down to fewer than eight
    /// held, it takes the next byte.
    ///
    /// **Fix:** past the stream's end the game reads whatever follows it; OpenReliant reads zeros.
    pub fn skip(bits: *Bits, n: u4) void {
        assert(n <= 8);
        bits.held >>= n;
        bits.count -= n;
        if (bits.count >= 8) return;
        const byte: u32 = if (bits.next < bits.data.len) bits.data[bits.next] else 0;
        bits.held |= byte << bits.count;
        bits.next += 1;
        bits.count += 8;
    }

    /// The next eight bits, not yet read.
    fn peek(bits: Bits) u8 {
        return @truncate(bits.held);
    }

    /// The masks the game reads its bits by (`0x005090C0`).
    fn mask(n: u4) u32 {
        return (@as(u32, 1) << n) - 1;
    }
};

/// A stream being decoded: its bits and its state.
pub const Decoder = struct {
    bits: Bits,
    state: State,

    /// `0x004A7290`: the stream's header, from its first byte. One bit says whether the subframes
    /// read their pulses at a step of two; four the levels of the first coefficient below which
    /// they take the variable code, 32 less them; four the first gain; and six the ratio of the
    /// others. The coefficients, the filter's memory and the past excitation start at nothing.
    pub fn init(data: []const u8) Decoder {
        var decoder: Decoder = .{ .bits = .init(data), .state = undefined };
        const bits = &decoder.bits;
        const state = &decoder.state;
        state.stepped = bits.read(1);
        state.coded_levels = 32 - bits.read(4);
        state.gains[0] = @as(f32, @floatFromInt(bits.read(4) + 1)) * gain_step;
        const ratio = @as(f32, @floatFromInt(bits.read(6))) * ratio_step + ratio_base;
        for (state.gains[1..], state.gains[0 .. state.gains.len - 1]) |*gain, before| gain.* = ratio * before;
        state.reflection = @splat(0);
        state.memory = @splat(0);
        @memset(state.history[0..history_samples], 0);
        return decoder;
    }

    /// `0x004A73B0`: the next frame, into the history after the past excitation
    /// (`State.samples`).
    ///
    /// Twelve coefficient levels come first, six bits each for the first four and five for the
    /// rest; the first's level, below `coded_levels`, says the frame's pulses take the variable
    /// code. Each subframe then reads a lag, eight bits, reaching back from its start
    /// `subframe_samples` further than the lag; a pitch gain, four bits; a gain from the header's,
    /// six bits; and its pulses (`pulses`). Read at a step of two, one bit says which samples they
    /// fall on, and another whether the others are nothing or filled in between them (`fill`),
    /// the gain then halved. The subframe's excitation is the pulses times the gain and the
    /// history the lag reaches times the pitch gain.
    ///
    /// The last `history_samples` of the frame's excitation are kept for the next, and the frame
    /// is filtered into speech (`synthesize`), its coefficients stepping to the new levels over its
    /// first four blocks.
    pub fn frame(decoder: *Decoder) void {
        const bits = &decoder.bits;
        const state = &decoder.state;
        var steps: [order]f32 = undefined;
        const first = bits.read(6);
        const coded = first < state.coded_levels;
        steps[0] = (tables.levels[first] - state.reflection[0]) * coefficient_step;
        for (steps[1..4], state.reflection[1..4]) |*step, level| step.* = (tables.levels[bits.read(6)] - level) * coefficient_step;
        for (steps[4..], state.reflection[4..]) |*step, level| step.* = (tables.levels[narrow_levels + bits.read(5)] - level) * coefficient_step;

        var start: i32 = pitch_reach;
        var out: usize = history_samples;
        while (out < state.history.len) : ({
            start += subframe_samples;
            out += subframe_samples;
        }) {
            const source = start - @as(i32, @intCast(bits.read(8)));
            const pitch = @as(f32, @floatFromInt(bits.read(4))) * pitch_step;
            var gain = state.gains[bits.read(6)];
            // The subframe's pulses, with room for the fill's reach on either side.
            var pulses_around: [fill_reach + subframe_samples + fill_reach]f32 = undefined;
            const excitation = pulses_around[fill_reach..][0..subframe_samples];
            if (state.stepped == 0) {
                readPulses(bits, coded, excitation, 1);
            } else {
                const offset = bits.read(1);
                const alone = bits.read(1);
                readPulses(bits, coded, excitation[offset..], 2);
                var other: usize = 1 - offset;
                if (alone != 0) {
                    while (other < subframe_samples) : (other += 2) excitation[other] = 0;
                } else {
                    @memset(pulses_around[0..fill_reach], 0);
                    @memset(pulses_around[fill_reach + subframe_samples ..], 0);
                    fill(pulses_around[fill_reach + other - fill_reach ..]);
                    gain *= filled_gain;
                }
            }
            for (state.history[out..][0..subframe_samples], excitation, 0..) |*sample, pulse, i| {
                sample.* = gain * pulse + pitch * state.pitchSource(source + @as(i32, @intCast(i)));
            }
        }
        finish(state, steps);
    }
};

/// The end of `Decoder.frame`, once the frame's excitation is in the history after the past
/// excitation: its last `history_samples` kept for the next frame, and the frame filtered into
/// speech (`synthesize`), its coefficients taking `steps` in each of its first four blocks.
pub fn finish(state: *State, steps: [order]f32) void {
    @memcpy(state.history[0..history_samples], state.history[frame_samples..]);
    for (0..3) |at| {
        for (&state.reflection, steps) |*level, step| level.* += step;
        synthesize(state, at * block, 1);
    }
    for (&state.reflection, steps) |*level, step| level.* += step;
    synthesize(state, 3 * block, frame_samples / block - 3);
}

/// How far the fill reaches either side of a sample it fills in.
pub const fill_reach = 5;

/// `0x004A76A0`: the pulses of a subframe, into `excitation` at a step of `step`.
///
/// Where the frame's first level says so (`coded`), each comes from the variable code, read in
/// two contexts (`tables.symbols`, `tables.records`) by the next eight bits: a symbol from the
/// fifth on is a pulse of its value; the third and fourth a run of `run_base` zeros and more, six
/// bits, cut short at the subframe's end; the first and second an escape, a pulse of
/// `escape_base` and one more for each leading 1 bit, and a sign bit, 1 for a positive pulse.
/// Otherwise each pulse is two bits at most: 0 for none, `01` for `-plain_pulse` and `11` for
/// `plain_pulse`.
fn readPulses(bits: *Bits, coded: bool, excitation: []f32, step: usize) void {
    var at: usize = 0;
    if (!coded) {
        while (at < subframe_samples) : (at += step) {
            switch (bits.held & 3) {
                0, 2 => {
                    excitation[at] = 0;
                    bits.skip(1);
                },
                1 => {
                    excitation[at] = -plain_pulse;
                    bits.skip(2);
                },
                3 => {
                    excitation[at] = plain_pulse;
                    bits.skip(2);
                },
                else => unreachable,
            }
        }
        return;
    }
    var context: u1 = 0;
    while (at < subframe_samples) {
        const symbol = tables.symbols[context][bits.peek()];
        const record = tables.records[symbol];
        context = record.next;
        bits.skip(record.bits);
        switch (symbol) {
            0, 1 => {
                var size: i32 = escape_base;
                if (bits.read(1) == 1) {
                    size += 1;
                    while (bits.read(1) == 1) size += 1;
                }
                excitation[at] = @floatFromInt(if (bits.read(1) == 1) size else -size);
                at += step;
            },
            2, 3 => {
                var run: usize = bits.read(run_bits) + run_base;
                if (run * step + at > subframe_samples) run = (subframe_samples - at) / step;
                for (0..run) |_| {
                    excitation[at] = 0;
                    at += step;
                }
            },
            else => {
                excitation[at] = record.value;
                at += step;
            },
        }
    }
}

/// `0x004A7890`: fills in every other sample of an excitation read at a step of two, from the
/// first of `samples` that is to be filled, which starts `fill_reach` samples before it: each is
/// the samples one, three and five away on either side, weighted by `fill_weights`.
pub fn fill(samples: []f32) void {
    var at: usize = fill_reach;
    while (at < fill_reach + subframe_samples) : (at += 2) {
        samples[at] = (samples[at - 5] + samples[at + 5]) * fill_weights[2] +
            (samples[at - 3] + samples[at + 3]) * fill_weights[1] +
            (samples[at - 1] + samples[at + 1]) * fill_weights[0];
    }
}

/// `0x004A78D0`: filters `blocks` blocks of the frame's samples from sample `start` into speech,
/// each the sample plus the filter's twelve coefficients (`coefficients`) times the twelve
/// samples before it.
///
/// **Improvement:** the sums go in order, where the game's unrolled filter adds its twelve terms in
/// an order of its own; the two round differently in the last bit.
fn synthesize(state: *State, start: usize, blocks: usize) void {
    const weights = coefficients(state.reflection);
    for (state.history[history_samples + start ..][0 .. blocks * block]) |*sample| {
        var sum = sample.*;
        for (weights, state.memory) |weight, before| sum += weight * before;
        std.mem.copyBackwards(f32, state.memory[1..], state.memory[0 .. order - 1]);
        state.memory[0] = sum;
        sample.* = sum;
    }
}

/// `0x004A8050`: the synthesis filter's coefficients from the reflection coefficients `k`: the
/// lattice's response to an impulse, its state starting at the first eleven of `k`, each output
/// less the coefficients so far times the outputs before it.
pub fn coefficients(k: [order]f32) [order]f32 {
    // The lattice's state, the sample before it first.
    var lattice: [order]f32 = undefined;
    lattice[0] = 1;
    @memcpy(lattice[1..], k[0 .. order - 1]);
    var response: [order]f32 = undefined;
    var weights: [order]f32 = undefined;
    for (0..order) |n| {
        var sum = -(lattice[order - 1] * k[order - 1]);
        var m: usize = order - 1;
        while (m > 0) {
            m -= 1;
            sum -= k[m] * lattice[m];
            lattice[m + 1] = sum * k[m] + lattice[m];
        }
        lattice[0] = sum;
        response[n] = sum;
        for (0..n) |i| sum -= response[n - 1 - i] * weights[i];
        weights[n] = sum;
    }
    return weights;
}

test Bits {
    // Least significant first, refilling a byte at a time.
    var bits: Bits = .init(&.{ 0b1011_0101, 0b0000_1111 });
    try std.testing.expectEqual(0b101, bits.read(3));
    try std.testing.expectEqual(0b10110, bits.read(5));
    try std.testing.expectEqual(0b1111, bits.read(4));
    // Past the end, zeros.
    try std.testing.expectEqual(0, bits.read(8));
}

test "Decoder.init" {
    // Stepped, 32 - 2 coded levels, a first gain of (3 + 1) * 8 and a ratio of 1.04 + 10 / 1000.
    var bytes: [4]u8 = @splat(0);
    var at: u5 = 0;
    for ([_][2]u32{ .{ 1, 1 }, .{ 2, 4 }, .{ 3, 4 }, .{ 10, 6 } }) |field| {
        const value, const width = field;
        var i: u5 = 0;
        while (i < width) : (i += 1) {
            if ((value >> i) & 1 == 1) bytes[at / 8] |= @as(u8, 1) << @intCast(at % 8);
            at += 1;
        }
    }
    const decoder: Decoder = .init(&bytes);
    try std.testing.expectEqual(1, decoder.state.stepped);
    try std.testing.expectEqual(30, decoder.state.coded_levels);
    try std.testing.expectEqual(32, decoder.state.gains[0]);
    try std.testing.expectApproxEqAbs(32 * 1.05, decoder.state.gains[1], 1e-4);
    try std.testing.expectEqual(0, decoder.state.history[0]);
}

test coefficients {
    // Without reflection, no filter.
    try std.testing.expectEqual(@as([order]f32, @splat(0)), coefficients(@splat(0)));
    // A first coefficient alone is the filter's first weight, turned.
    var k: [order]f32 = @splat(0);
    k[0] = 0.5;
    const weights = coefficients(k);
    try std.testing.expectApproxEqAbs(-0.5, weights[0], 1e-6);
    for (weights[1..]) |weight| try std.testing.expectApproxEqAbs(0, weight, 1e-6);
}

test fill {
    // A pulse two samples apart from the filled one weighs in by the nearest weight.
    var samples: [fill_reach + subframe_samples + fill_reach]f32 = @splat(0);
    samples[fill_reach - 1] = 1;
    fill(&samples);
    try std.testing.expectEqual(fill_weights[0], samples[fill_reach]);
    try std.testing.expectEqual(fill_weights[1], samples[fill_reach + 2]);
    try std.testing.expectEqual(fill_weights[2], samples[fill_reach + 4]);
    try std.testing.expectEqual(0, samples[fill_reach + 6]);
}

/// Bits appended least significant first, as the stream holds them, for the tests.
const BitWriter = struct {
    bytes: [64]u8 = @splat(0),
    at: usize = 0,

    fn put(writer: *BitWriter, value: u32, n: u5) void {
        for (0..n) |i| {
            if ((value >> @intCast(i)) & 1 == 1) writer.bytes[writer.at / 8] |= @as(u8, 1) << @intCast(writer.at % 8);
            writer.at += 1;
        }
    }

    /// The code of `symbol` in `context`, as the tables give it: the low bits of any eight that
    /// begin with it.
    fn code(writer: *BitWriter, context: u1, symbol: u8) void {
        for (tables.symbols[context], 0..) |found, byte| {
            if (found != symbol) continue;
            writer.put(@intCast(byte), tables.records[symbol].bits);
            return;
        }
        unreachable;
    }
};

test readPulses {
    // The plain code: each 0 bit nothing, 01 a negative pulse and 11 a positive one, read at a
    // step of two; the rest of the bits zero, so nothing.
    var bits: Bits = .init(&.{ 0b0011_0100, 0 });
    var excitation: [subframe_samples]f32 = @splat(9);
    readPulses(&bits, false, &excitation, 2);
    try std.testing.expectEqual(0, excitation[0]);
    try std.testing.expectEqual(0, excitation[2]);
    try std.testing.expectEqual(-plain_pulse, excitation[4]);
    try std.testing.expectEqual(plain_pulse, excitation[6]);
    try std.testing.expectEqual(9, excitation[1]);

    // The variable code: a pulse of 1, one of -2 that switches the context, a run of 8 zeros, an
    // escape of 7 + 2 with its sign, and a pulse of 3.
    var writer: BitWriter = .{};
    writer.code(0, 6);
    writer.code(0, 9);
    try std.testing.expectEqual(1, tables.records[9].next);
    writer.code(1, 3);
    writer.put(1, run_bits);
    writer.code(0, 0);
    writer.put(0b011, 3);
    writer.put(1, 1);
    writer.code(1, 16);
    bits = .init(&writer.bytes);
    excitation = @splat(9);
    readPulses(&bits, true, &excitation, 1);
    try std.testing.expectEqual(1, excitation[0]);
    try std.testing.expectEqual(-2, excitation[1]);
    for (excitation[2..10]) |zero| try std.testing.expectEqual(0, zero);
    try std.testing.expectEqual(9, excitation[10]);
    try std.testing.expectEqual(3, excitation[11]);
    // Two runs of 70 zeros: the second is cut short at the subframe's end.
    writer = .{};
    writer.code(0, 2);
    writer.put(63, run_bits);
    writer.code(0, 2);
    writer.put(63, run_bits);
    bits = .init(&writer.bytes);
    excitation = @splat(9);
    readPulses(&bits, true, &excitation, 1);
    for (excitation) |zero| try std.testing.expectEqual(0, zero);
}
