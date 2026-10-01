//! sRGB's transfer function (IEC 61966-2-1), between a colour's encoded values and its light from 0
//! to 1, as the shaders' `colour.glsl` has it, for what the CPU works out in linear light: the
//! colours of the lights the GPU device takes, and the mipmaps of a mod's pictures
//! (`srtexture.mipmaps`).

const std = @import("std");

/// Below this encoded value the curve is a straight line of this slope.
const knee = 0.04045;
const slope = 12.92;
/// Past the knee, the value is offset and raised to the exponent.
const offset = 0.055;
const exponent = 2.4;

/// The light of the encoded value `value`.
pub fn decoded(value: f32) f32 {
    return @floatCast(decode(value));
}

fn decode(value: f64) f64 {
    return if (value <= knee) value / slope else std.math.pow(f64, (value + offset) / (1 + offset), exponent);
}

/// The light of the 8-bit level `of`.
pub fn light(of: u8) f32 {
    return lights[of];
}

/// The 8-bit level nearest the light `of`, in encoded value, held to the levels.
pub fn level(of: f32) u8 {
    var low: usize = 0;
    var high: usize = bounds.len;
    while (low < high) {
        const middle = (low + high) / 2;
        if (of < bounds[middle]) high = middle else low = middle + 1;
    }
    return @intCast(low);
}

/// The light of each level, worked out exactly once.
const lights: [256]f32 = table: {
    @setEvalBranchQuota(100_000);
    var out: [256]f32 = undefined;
    for (&out, 0..) |*each, at| each.* = @floatCast(decode(@as(f64, @floatFromInt(at)) / 255));
    break :table out;
};

/// The light halfway, in encoded value, between each level and the next: where the nearest level
/// changes.
const bounds: [255]f32 = table: {
    @setEvalBranchQuota(100_000);
    var out: [255]f32 = undefined;
    for (&out, 0..) |*bound, at| bound.* = @floatCast(decode((@as(f64, @floatFromInt(at)) + 0.5) / 255));
    break :table out;
};

test decoded {
    try std.testing.expectEqual(0, decoded(0));
    try std.testing.expectApproxEqAbs(1, decoded(1), 1e-6);
    // Half the encoding is a fifth of the light.
    try std.testing.expectApproxEqAbs(0.214, decoded(0.5), 1e-3);
    // The dark end is a straight line.
    try std.testing.expectApproxEqAbs(0.02 / 12.92, decoded(0.02), 1e-7);
}

test level {
    for (0..256) |at| {
        const each: u8 = @intCast(at);
        try std.testing.expectEqual(each, level(light(each)));
    }
    try std.testing.expectEqual(188, level(0.5));
    try std.testing.expectEqual(0, level(-1));
    try std.testing.expectEqual(255, level(2));
}
