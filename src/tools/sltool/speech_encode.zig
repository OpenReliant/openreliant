//! Writes speech files (`.ut`, [docs/formats/speech.md](../../../docs/formats/speech.md)) from
//! samples, for mods that give the radio lines of their own. The game's decoder
//! (`engine/game/voice.zig`) sets the format; this is the other way.
//!
//! It takes the settings every shipped file has (`Settings`), and codes each frame by analysis by
//! synthesis against the decoder's own filter: the twelve reflection coefficients from the frame
//! (Levinson-Durbin) at their nearest levels; then, subframe by subframe, the pitch lag and gain
//! whose prediction filters nearest to the speech, and the pulses, their gain, and where the
//! stepped mode puts them, nearest to what is left. The frame then ends as the decoder ends it
//! (`voice.finish`), so the encoder's state is the decoder's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const openreliant = @import("openreliant");
const voice = openreliant.engine.game.voice;
const cbox = openreliant.engine.game.cbox;
const tables = voice.tables;

/// The header's settings, as every shipped file has them: pulses at a step of two, the variable
/// code below the first coefficient's level 24, a first gain of 64 and a ratio of 1.068.
pub const Settings = struct {
    stepped: bool = true,
    /// 32 less the levels that take the variable code.
    plain_from: u4 = 8,
    first_gain: u4 = 7,
    ratio: u6 = 28,
};

const samples_per_frame = voice.frame_samples;
const subframe = voice.subframe_samples;

/// The longest lag a subframe's pitch predictor reads: the lag is eight bits, and the encoder keeps
/// to lags that reach into the past excitation (`voice.State.history`).
const max_lag = 255;

/// The largest pulse the encoder writes in the variable code, a long escape.
const max_pulse = 40;

/// A file of `samples`, 16-bit mono at 22,050 Hz, scrambled and ready to write. The caller owns
/// the bytes.
pub fn encode(gpa: Allocator, samples: []const i16, settings: Settings) Allocator.Error![]u8 {
    var bits: BitWriter = .{};
    defer bits.bytes.deinit(gpa);
    try bits.put(gpa, @intFromBool(settings.stepped), 1);
    try bits.put(gpa, settings.plain_from, 4);
    try bits.put(gpa, settings.first_gain, 4);
    try bits.put(gpa, settings.ratio, 6);
    var header_bytes: [2]u8 = undefined;
    @memcpy(&header_bytes, bits.bytes.items[0..2]);
    var state = voice.Decoder.init(&header_bytes).state;

    var frame: [samples_per_frame]f32 = undefined;
    var at: usize = 0;
    while (at < samples.len) : (at += samples_per_frame) {
        for (&frame, 0..) |*value, i| value.* = if (at + i < samples.len) @floatFromInt(samples[at + i]) else 0;
        try encodeFrame(gpa, &bits, &state, &frame);
    }

    var stream = bits.bytes.items;
    var length: u32 = @intCast(@sizeOf(cbox.Header) - 4 + stream.len);
    // A file whose length begins `CB` or `man` the game takes as unscrambled already
    // (`cbox.unscramble`): a byte more of nothing at the stream's end moves it.
    if (marked(length)) {
        try bits.bytes.append(gpa, 0);
        stream = bits.bytes.items;
        length += 1;
    }
    const header: cbox.Header = .{ .length = length, .magic = cbox.Header.line_magic.*, .size = @intCast(samples.len * 2) };
    const file = try gpa.alloc(u8, @sizeOf(cbox.Header) + stream.len);
    @memcpy(file[0..@sizeOf(cbox.Header)], std.mem.asBytes(&header));
    @memcpy(file[@sizeOf(cbox.Header)..], stream);
    cbox.unscramble(file);
    return file;
}

/// Whether a file of `length` begins as one the game takes for unscrambled.
fn marked(length: u32) bool {
    const bytes = std.mem.toBytes(length);
    return std.mem.startsWith(u8, &bytes, "CB") or std.mem.startsWith(u8, &bytes, "man");
}

/// The stream's bits, least significant first, as `voice.Bits` reads them.
const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    at: usize = 0,

    fn put(writer: *BitWriter, gpa: Allocator, value: u32, n: u6) Allocator.Error!void {
        for (0..n) |i| {
            if (writer.at % 8 == 0) try writer.bytes.append(gpa, 0);
            if ((value >> @intCast(i)) & 1 == 1) writer.bytes.items[writer.at / 8] |= @as(u8, 1) << @intCast(writer.at % 8);
            writer.at += 1;
        }
    }
};

/// The weights of the synthesis filter for each sample of a frame: the coefficients stepping a
/// quarter of the way to the frame's in each of its first three blocks, then the frame's own
/// (`voice.finish`).
const Schedule = struct {
    weights: [4][voice.order]f32,

    fn of(reflection: [voice.order]f32, steps: [voice.order]f32) Schedule {
        var schedule: Schedule = undefined;
        var levels = reflection;
        for (&schedule.weights) |*weights| {
            for (&levels, steps) |*level, step| level.* += step;
            weights.* = voice.coefficients(levels);
        }
        return schedule;
    }

    /// The weights sample `index` of the frame is filtered with.
    fn at(schedule: *const Schedule, index: usize) *const [voice.order]f32 {
        return &schedule.weights[@min(index / voice.block, 3)];
    }

    /// Filters `excitation`, the subframe from sample `start` of the frame, into `out`, from the
    /// filter's memory `memory`, which it leaves as the last outputs.
    fn filter(schedule: *const Schedule, start: usize, excitation: []const f32, memory: *[voice.order]f32, out: []f32) void {
        for (excitation, out, 0..) |value, *sample, i| {
            var sum = value;
            for (schedule.at(start + i), memory) |weight, before| sum += weight * before;
            std.mem.copyBackwards(f32, memory[1..], memory[0 .. voice.order - 1]);
            memory[0] = sum;
            sample.* = sum;
        }
    }

    /// What filters to `wanted` from no memory: `wanted` through the inverse filter.
    fn inverse(schedule: *const Schedule, start: usize, wanted: []const f32, out: []f32) void {
        for (out, 0..) |*value, i| {
            var sum = wanted[i];
            for (schedule.at(start + i), 0..) |weight, k| {
                if (i > k) sum -= weight * wanted[i - 1 - k];
            }
            value.* = sum;
        }
    }
};

/// The reflection coefficients of `frame`, as the decoder takes them (`voice.coefficients`), from
/// its autocorrelation under a Hamming window (Levinson-Durbin).
pub fn reflectionOf(frame: *const [samples_per_frame]f32) [voice.order]f32 {
    var windowed: [samples_per_frame]f32 = undefined;
    for (frame, &windowed, 0..) |value, *out, i| {
        const phase = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, samples_per_frame - 1);
        out.* = value * (0.54 - 0.46 * @cos(phase));
    }
    var r: [voice.order + 1]f64 = undefined;
    for (&r, 0..) |*sum, lag| {
        sum.* = 0;
        for (windowed[lag..], windowed[0 .. samples_per_frame - lag]) |a, b| sum.* += @as(f64, a) * b;
    }
    // A little white noise keeps a silent or pure frame's filter stable.
    r[0] = r[0] * 1.0001 + 1e-3;
    var predictor: [voice.order]f64 = @splat(0);
    var reflection: [voice.order]f32 = @splat(0);
    var err = r[0];
    for (0..voice.order) |m| {
        var acc = r[m + 1];
        for (0..m) |j| acc -= predictor[j] * r[m - j];
        const k = std.math.clamp(acc / err, -0.999, 0.999);
        var next = predictor;
        next[m] = k;
        for (0..m) |j| next[j] = predictor[j] - k * predictor[m - 1 - j];
        predictor = next;
        err *= 1 - k * k;
        // The decoder's coefficients turn the other way: its first weight is the first one's
        // negative.
        reflection[m] = @floatCast(-k);
    }
    return reflection;
}

/// The level nearest `value` among `tables.levels[from..from + count]`, counted from `from`.
fn nearestLevel(value: f32, from: usize, count: usize) u32 {
    var best: usize = 0;
    for (tables.levels[from..][0..count], 0..) |level, i| {
        if (@abs(level - value) < @abs(tables.levels[from + best] - value)) best = i;
    }
    return @intCast(best);
}

fn encodeFrame(gpa: Allocator, bits: *BitWriter, state: *voice.State, frame: *const [samples_per_frame]f32) Allocator.Error!void {
    // The coefficients, and the steps the decoder takes to them.
    const wanted = reflectionOf(frame);
    var codes: [voice.order]u32 = undefined;
    var levels: [voice.order]f32 = undefined;
    for (&codes, &levels, wanted, 0..) |*code, *level, value, i| {
        const from: usize = if (i < 4) 0 else voice.narrow_levels;
        const count: usize = if (i < 4) tables.levels.len else 32;
        code.* = nearestLevel(value, from, count);
        level.* = tables.levels[from + code.*];
    }
    for (codes, 0..) |code, i| try bits.put(gpa, code, if (i < 4) 6 else 5);
    const coded = codes[0] < state.coded_levels;
    var steps: [voice.order]f32 = undefined;
    for (&steps, levels, state.reflection) |*step, level, before| step.* = (level - before) * voice.coefficient_step;
    const schedule: Schedule = .of(state.reflection, steps);

    var memory = state.memory;
    for (0..4) |s| {
        const start = s * subframe;
        const out = voice.history_samples + start;
        const source_start = voice.pitch_reach + start;
        // What the filter gives of the frame's memory alone, and what is left to make.
        var zero_input: [subframe]f32 = undefined;
        var held = memory;
        schedule.filter(start, &@as([subframe]f32, @splat(0)), &held, &zero_input);
        var target: [subframe]f32 = undefined;
        for (&target, frame[start..][0..subframe], zero_input) |*t, wanted_sample, zi| t.* = wanted_sample - zi;

        // The pitch: each lag's prediction filtered from no memory, at its best gain.
        var best = Pitch{};
        var lag: usize = 0;
        while (lag <= @min(max_lag, source_start)) : (lag += 1) {
            var predicted: [subframe]f32 = undefined;
            for (&predicted, 0..) |*value, i| value.* = state.history[source_start - lag + i];
            var filtered: [subframe]f32 = undefined;
            var none: [voice.order]f32 = @splat(0);
            schedule.filter(start, &predicted, &none, &filtered);
            const pitch = Pitch.fit(lag, &target, &filtered);
            if (pitch.saving > best.saving) best = pitch;
        }
        const pitch_gain = @as(f32, @floatFromInt(best.gain)) * voice.pitch_step;
        var prediction: [subframe]f32 = undefined;
        for (&prediction, 0..) |*value, i| value.* = pitch_gain * state.history[source_start - best.lag + i];
        var predicted_out: [subframe]f32 = undefined;
        var none: [voice.order]f32 = @splat(0);
        schedule.filter(start, &prediction, &none, &predicted_out);
        var left: [subframe]f32 = undefined;
        for (&left, target, predicted_out) |*l, t, p| l.* = t - p;

        // The pulses: what is left through the inverse filter, coded at each gain and placing,
        // the one that filters nearest kept.
        var residual: [subframe]f32 = undefined;
        schedule.inverse(start, &left, &residual);
        const pulses = choosePulses(state, &schedule, start, coded, &left, &residual);

        try bits.put(gpa, @intCast(best.lag), 8);
        try bits.put(gpa, best.gain, 4);
        try bits.put(gpa, pulses.gain, 6);
        if (state.stepped != 0) {
            try bits.put(gpa, pulses.offset, 1);
            try bits.put(gpa, @intFromBool(pulses.alone), 1);
        }
        var buffer: [subframe]i32 = undefined;
        try writePulses(gpa, bits, coded, pulses.values(state.stepped != 0, &buffer));

        // The excitation as the decoder makes it, kept for the next subframes' pitch, and the
        // filter's memory stepped on through it.
        for (state.history[out..][0..subframe], pulses.excitation, prediction) |*sample, pulse, p| sample.* = pulse + p;
        var through: [subframe]f32 = undefined;
        schedule.filter(start, state.history[out..][0..subframe], &memory, &through);
    }
    voice.finish(state, steps);
}

/// A subframe's pitch: its lag, its gain in fifteenths, and how much nearer it brings the target.
const Pitch = struct {
    lag: usize = 0,
    gain: u4 = 0,
    saving: f32 = 0,

    fn fit(lag: usize, target: *const [subframe]f32, filtered: *const [subframe]f32) Pitch {
        var cross: f32 = 0;
        var energy: f32 = 0;
        for (target, filtered) |t, f| {
            cross += t * f;
            energy += f * f;
        }
        if (energy <= 0 or cross <= 0) return .{ .lag = lag };
        const gain: u4 = @intFromFloat(std.math.clamp(@round(cross / energy / voice.pitch_step), 0, 15));
        const g = @as(f32, @floatFromInt(gain)) * voice.pitch_step;
        return .{ .lag = lag, .gain = gain, .saving = 2 * g * cross - g * g * energy };
    }
};

/// A subframe's pulses: the gain's number, which samples they fall on and whether the others are
/// nothing, each pulse's value, and the excitation they make.
const Pulses = struct {
    gain: u6 = 0,
    offset: u1 = 0,
    alone: bool = true,
    pulses: [subframe]i32 = @splat(0),
    excitation: [subframe]f32 = @splat(0),
    err: f32 = std.math.inf(f32),

    /// The values the stream holds, in `buffer`: every one, or at a step of two from `offset`.
    fn values(pulses: *const Pulses, stepped: bool, buffer: *[subframe]i32) []const i32 {
        if (!stepped) return &pulses.pulses;
        var count: usize = 0;
        var at: usize = pulses.offset;
        while (at < subframe) : (at += 2) {
            buffer[count] = pulses.pulses[at];
            count += 1;
        }
        return buffer[0..count];
    }
};

/// The pulses nearest to make `left` (`residual` through the inverse filter), at each of the 64
/// gains, and in the stepped mode each placing, as the decoder builds them.
fn choosePulses(state: *const voice.State, schedule: *const Schedule, start: usize, coded: bool, left: *const [subframe]f32, residual: *const [subframe]f32) Pulses {
    var best: Pulses = .{};
    const stepped = state.stepped != 0;
    for (0..64) |gain_index| {
        for (0..@as(usize, if (stepped) 2 else 1)) |offset| {
            for ([_]bool{ true, false }) |alone| {
                if (!stepped and !alone) continue;
                var gain = state.gains[gain_index];
                if (stepped and !alone) gain *= voice.filled_gain;
                var candidate: Pulses = .{ .gain = @intCast(gain_index), .offset = @intCast(offset), .alone = alone };
                var around: [voice.fill_reach + subframe + voice.fill_reach]f32 = @splat(0);
                const excitation = around[voice.fill_reach..][0..subframe];
                var at: usize = if (stepped) offset else 0;
                while (at < subframe) : (at += if (stepped) 2 else 1) {
                    const value = quantizePulse(residual[at] / gain, coded);
                    candidate.pulses[at] = value;
                    excitation[at] = @floatFromInt(value);
                }
                if (stepped and !alone) voice.fill(around[voice.fill_reach + (1 - offset) - voice.fill_reach ..]);
                for (&candidate.excitation, excitation) |*e, pulse| e.* = gain * pulse;
                var filtered: [subframe]f32 = undefined;
                var none: [voice.order]f32 = @splat(0);
                schedule.filter(start, &candidate.excitation, &none, &filtered);
                var err: f32 = 0;
                for (left, filtered) |l, f| err += (l - f) * (l - f);
                candidate.err = err;
                if (err < best.err) best = candidate;
            }
        }
    }
    return best;
}

/// The pulse the stream can hold nearest `ratio`: -2, 0 or 2 in the plain code, any whole number
/// to `max_pulse` either way in the variable code.
fn quantizePulse(ratio: f32, coded: bool) i32 {
    if (!coded) {
        if (ratio > 1) return 2;
        if (ratio < -1) return -2;
        return 0;
    }
    return @intFromFloat(std.math.clamp(@round(ratio), -max_pulse, max_pulse));
}

/// The code of each symbol in each context: the low bits of any byte the context reads it by.
const symbol_codes = blk: {
    @setEvalBranchQuota(10000);
    var codes: [2][tables.records.len]?u8 = @splat(@splat(null));
    for (0..2) |context| {
        for (tables.symbols[context], 0..) |symbol, byte| {
            if (codes[context][symbol] == null) codes[context][symbol] = byte;
        }
    }
    break :blk codes;
};

/// Writes `pulses`: in the plain code each two bits at most, in the variable code by symbols in
/// their contexts, zeros in runs where seven or more follow, and pulses past six as escapes.
fn writePulses(gpa: Allocator, bits: *BitWriter, coded: bool, pulses: []const i32) Allocator.Error!void {
    if (!coded) {
        for (pulses) |pulse| switch (pulse) {
            0 => try bits.put(gpa, 0, 1),
            -2 => try bits.put(gpa, 1, 2),
            else => try bits.put(gpa, 3, 2),
        };
        return;
    }
    var context: u1 = 0;
    var at: usize = 0;
    while (at < pulses.len) {
        const pulse = pulses[at];
        if (pulse == 0) {
            var zeros: usize = 0;
            while (at + zeros < pulses.len and pulses[at + zeros] == 0) zeros += 1;
            if (zeros >= voice.run_base) {
                const run = @min(zeros, voice.run_base + (1 << voice.run_bits) - 1);
                context = try putSymbol(gpa, bits, context, &.{ 2, 3 });
                try bits.put(gpa, @intCast(run - voice.run_base), voice.run_bits);
                at += run;
                continue;
            }
            context = try putSymbol(gpa, bits, context, &.{4});
            at += 1;
            continue;
        }
        const size: u32 = @abs(pulse);
        if (size < voice.escape_base) {
            var choices: [2]u8 = undefined;
            var count: usize = 0;
            for (tables.records, 0..) |record, symbol| {
                if (symbol >= 5 and record.value == @as(f32, @floatFromInt(pulse))) {
                    choices[count] = @intCast(symbol);
                    count += 1;
                }
            }
            context = try putSymbol(gpa, bits, context, choices[0..count]);
        } else {
            context = try putSymbol(gpa, bits, context, &.{ 0, 1 });
            // Seven is a 0 bit; each more a 1 bit, then a 0 to end them.
            if (size == voice.escape_base) {
                try bits.put(gpa, 0, 1);
            } else {
                for (0..size - voice.escape_base) |_| try bits.put(gpa, 1, 1);
                try bits.put(gpa, 0, 1);
            }
            try bits.put(gpa, @intFromBool(pulse > 0), 1);
        }
        at += 1;
    }
}

// The symbols `writePulses` asks for: a run of zeros, a zero, an escape, and each pulse from -6 to
// 6. Both contexts have a code for one of each, so `putSymbol` always finds one.
comptime {
    for (0..2) |context| {
        for ([_][]const u8{ &.{ 2, 3 }, &.{4}, &.{ 0, 1 } }) |choices| {
            var found = false;
            for (choices) |symbol| found = found or symbol_codes[context][symbol] != null;
            if (!found) @compileError("a context of the pulse code lacks a symbol the encoder writes");
        }
        for (1..voice.escape_base) |size| for ([_]f32{ -1, 1 }) |sign| {
            var found = false;
            for (tables.records, 0..) |record, symbol| {
                if (symbol >= 5 and record.value == sign * @as(f32, @floatFromInt(size)) and symbol_codes[context][symbol] != null) found = true;
            }
            if (!found) @compileError("a context of the pulse code lacks a pulse the encoder writes");
        };
    }
}

/// Writes the first of `choices` that `context` has a code for, and returns the context after it.
fn putSymbol(gpa: Allocator, bits: *BitWriter, context: u1, choices: []const u8) Allocator.Error!u1 {
    for (choices) |symbol| {
        const code = symbol_codes[context][symbol] orelse continue;
        const record = tables.records[symbol];
        try bits.put(gpa, code, record.bits);
        return record.next;
    }
    unreachable;
}

/// The signal-to-noise ratio in decibels of `decoded` against `original`.
fn snr(original: []const i16, decoded: []const i16) f64 {
    var signal: f64 = 0;
    var noise: f64 = 0;
    for (original, decoded) |o, d| {
        signal += @as(f64, @floatFromInt(o)) * @as(f64, @floatFromInt(o));
        const diff = @as(f64, @floatFromInt(o)) - @as(f64, @floatFromInt(d));
        noise += diff * diff;
    }
    return 10 * std.math.log10(signal / @max(noise, 1));
}

test reflectionOf {
    // The decoder's filter from the coefficients predicts as the frame's own predictor does: for
    // a decaying sine, the filter's first weight is near twice the cosine of its frequency.
    var frame: [samples_per_frame]f32 = undefined;
    for (&frame, 0..) |*value, i| {
        const t: f32 = @floatFromInt(i);
        value.* = 3000 * @sin(0.2 * t) + 200 * @sin(1.3 * t);
    }
    const weights = voice.coefficients(reflectionOf(&frame));
    try std.testing.expect(weights[0] > 1.0);
}

test "a line encoded plays back near what went in" {
    const gpa = std.testing.allocator;
    // Half a second of a voiced sound: a pulse train at 120 Hz through two resonances.
    var samples: [11025]i16 = undefined;
    var y1: f32 = 0;
    var y2: f32 = 0;
    var z1: f32 = 0;
    var z2: f32 = 0;
    for (&samples, 0..) |*sample, i| {
        const pulse: f32 = if (i % 184 == 0) 4000 else 0;
        const y = pulse + 1.8 * y1 - 0.9 * y2;
        y2 = y1;
        y1 = y;
        const z = y * 0.2 + 1.2 * z1 - 0.8 * z2;
        z2 = z1;
        z1 = z;
        sample.* = @intFromFloat(std.math.clamp(z, -30000, 30000));
    }
    const file = try encode(gpa, &samples, .{});
    defer gpa.free(file);
    const copy = try gpa.dupe(u8, file);
    defer gpa.free(copy);
    const speech = cbox.Speech.parse(copy).?;
    try std.testing.expectEqual(samples.len, speech.samples());
    const decoded = try cbox.decode(gpa, speech, .cut);
    defer gpa.free(decoded);
    try std.testing.expect(snr(&samples, decoded) > 6);
}

test marked {
    try std.testing.expect(marked(std.mem.readInt(u32, "CBxx", .little)));
    try std.testing.expect(!marked(1234));
}
