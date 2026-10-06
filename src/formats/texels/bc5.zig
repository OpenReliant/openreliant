//! BC5 blocks made from a normal map's 16-bit samples
//! ([#688](https://github.com/OpenReliant/openreliant/issues/688)): its x in red and its y in
//! green, each a BC4 block of two 8-bit endpoints and a 3-bit index for each of the 16 pixels.
//!
//! A GPU decodes the six values between the endpoints at better than 8 bits, so a block of shallow
//! normals, whose endpoints lie a level or two apart, holds steps finer than an 8-bit picture can.
//! The encoder that takes 8-bit pictures (`texture_compressor.zig`) loses them before it starts;
//! this one picks each block's endpoints and indices from the 16-bit samples themselves.

const std = @import("std");
const texels = @import("../texels.zig");

/// The bytes of a BC4 block: two endpoints, then 16 indices of 3 bits.
const bc4_bytes = 8;

/// The pixels of a block.
const pixels = texels.block_side * texels.block_side;

/// The highest level of an 8-bit endpoint.
const top = std.math.maxInt(u8);

/// The steps from the first endpoint to the second, the six values between them included, where
/// the first is the higher.
const steps = 7;

/// How far the encoder moves each endpoint from the block's own extremes, either way, as it looks
/// for the pair that fits the block best.
const reach = 1;

/// Encodes the rows of blocks `first` to `first + count` of the 16-bit RGBA level `rgba16`
/// (`texels.Format.rgba16`), `width` by `height` pixels, into `out`, which holds the whole level in
/// BC5. Pixels past the level's edge repeat its last row and column.
pub fn encodeRows(rgba16: []const u8, width: u32, height: u32, first: u32, count: u32, out: []u8) void {
    const across = texels.blocks(width);
    for (first..first + count) |row| for (0..across) |column| {
        var x: [pixels]f32 = undefined;
        var y: [pixels]f32 = undefined;
        for (0..texels.block_side) |down| for (0..texels.block_side) |side| {
            const pixel_x = @min(column * texels.block_side + side, width - 1);
            const pixel_y = @min(row * texels.block_side + down, height - 1);
            const at = (pixel_y * width + pixel_x) * 4 * @sizeOf(u16);
            x[down * texels.block_side + side] = texels.unit(u16, std.mem.readInt(u16, rgba16[at..][0..2], .native));
            y[down * texels.block_side + side] = texels.unit(u16, std.mem.readInt(u16, rgba16[at + 2 ..][0..2], .native));
        };
        const block = out[(row * across + column) * 2 * bc4_bytes ..][0 .. 2 * bc4_bytes];
        block[0..bc4_bytes].* = bc4(x);
        block[bc4_bytes..].* = bc4(y);
    };
}

/// The BC4 block that fits `values`, each from 0 to 1, best: of the endpoints near their extremes,
/// the pair whose eight values leave the least squared error.
fn bc4(values: [pixels]f32) [bc4_bytes]u8 {
    const lowest = std.mem.min(f32, &values);
    const highest = std.mem.max(f32, &values);
    const low: i32 = @intFromFloat(@round(lowest * top));
    const high: i32 = @intFromFloat(@round(highest * top));
    var best: [bc4_bytes]u8 = undefined;
    var least = std.math.inf(f32);
    var from = high - reach;
    while (from <= high + reach) : (from += 1) {
        var to = low - reach;
        while (to <= low + reach) : (to += 1) {
            // The first endpoint above the second picks the block's eight evenly spaced values.
            if (from > top or to < 0 or from <= to) continue;
            const made = fit(values, @intCast(from), @intCast(to));
            if (made.error_sum < least) {
                least = made.error_sum;
                best = made.block;
            }
        }
    }
    // Endpoints reach past the block's extremes, so a block of one value has a pair too.
    std.debug.assert(least != std.math.inf(f32));
    return best;
}

/// The BC4 block of endpoints `from` above `to`, each of `values` given the index of the nearest
/// of its eight values, and the block's squared error.
fn fit(values: [pixels]f32, from: u8, to: u8) struct { block: [bc4_bytes]u8, error_sum: f32 } {
    const start = @as(f32, @floatFromInt(from)) / top;
    const end = @as(f32, @floatFromInt(to)) / top;
    var indices: u48 = 0;
    var error_sum: f32 = 0;
    for (values, 0..) |value, at| {
        // The step from `from` toward `to`, 0 to `steps`, of the nearest value.
        const step: u3 = @intFromFloat(@round(std.math.clamp((start - value) / (start - end), 0, 1) * steps));
        const decoded = start + (end - start) * @as(f32, @floatFromInt(step)) / steps;
        error_sum += (value - decoded) * (value - decoded);
        // BC4 numbers the endpoints 0 and 1, and the six values between them 2 to 7.
        const index: u48 = switch (step) {
            0 => 0,
            steps => 1,
            else => @as(u48, step) + 1,
        };
        indices |= index << @intCast(at * @bitSizeOf(u3));
    }
    var block: [bc4_bytes]u8 = undefined;
    block[0] = from;
    block[1] = to;
    std.mem.writeInt(u48, block[2..bc4_bytes], indices, .little);
    return .{ .block = block, .error_sum = error_sum };
}

/// The value index `index` of the BC4 block `block` stands for, from 0 to 1, as a GPU decodes it.
fn decode(block: [bc4_bytes]u8, index: u3) f32 {
    const from: f32 = @floatFromInt(block[0]);
    const to: f32 = @floatFromInt(block[1]);
    std.debug.assert(block[0] > block[1]);
    const value = switch (index) {
        0 => from,
        1 => to,
        else => (from * @as(f32, @floatFromInt(steps + 1 - @as(u4, index))) + to * @as(f32, @floatFromInt(index - 1))) / steps,
    };
    return value / top;
}

test bc4 {
    // A gentle ramp across a level and a half of 8 bits: the block keeps steps between the levels.
    var values: [pixels]f32 = undefined;
    for (&values, 0..) |*value, at| value.* = (128 + @as(f32, @floatFromInt(at)) * 0.1) / 255;
    const block = bc4(values);
    var worst: f32 = 0;
    for (values, 0..) |value, at| {
        const index: u3 = @truncate(std.mem.readInt(u48, block[2..8], .little) >> @intCast(at * 3));
        worst = @max(worst, @abs(decode(block, index) - value));
    }
    // Finer than the half level an 8-bit picture rounds to.
    try std.testing.expect(worst < 0.25 / 255.0);
    // A block of one value decodes to it.
    const flat = bc4(@splat(0.5));
    const index: u3 = @truncate(std.mem.readInt(u48, flat[2..8], .little));
    try std.testing.expectApproxEqAbs(0.5, decode(flat, index), 0.5 / 255.0);
}

test encodeRows {
    // A 5 by 2 level takes 2 by 1 blocks; its x and y land in each block's two halves.
    var rgba16: [5 * 2 * 4 * 2]u8 = undefined;
    for (0..5 * 2) |at| {
        std.mem.writeInt(u16, rgba16[at * 8 ..][0..2], 0xFFFF, .native);
        std.mem.writeInt(u16, rgba16[at * 8 + 2 ..][0..2], 0, .native);
        std.mem.writeInt(u32, rgba16[at * 8 + 4 ..][0..4], 0, .native);
    }
    var out: [2 * 16]u8 = undefined;
    encodeRows(&rgba16, 5, 2, 0, 1, &out);
    for (0..2) |block| {
        try std.testing.expectApproxEqAbs(1, decode(out[block * 16 ..][0..8].*, @truncate(std.mem.readInt(u48, out[block * 16 + 2 ..][0..6], .little))), 1.0 / 255.0);
        try std.testing.expectApproxEqAbs(0, decode(out[block * 16 + 8 ..][0..8].*, @truncate(std.mem.readInt(u48, out[block * 16 + 10 ..][0..6], .little))), 1.0 / 255.0);
    }
}
