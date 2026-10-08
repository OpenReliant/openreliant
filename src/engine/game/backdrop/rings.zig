//! OpenReliant's: the sun's and the lens flares' round textures drawn again, `scale` times finer,
//! from the rings they are made of (`redraw`), so that they stay round and crisp however large they
//! are drawn. [`backdrop.md`](../../../../docs/engine/backdrop.md#sun-and-lens-flares) describes
//! them.
//!
//! **Improvement:** the game draws them from their small 16-bit textures, which a large display
//! magnifies into stair-stepped edges and banded glows. `--original` keeps them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");

/// How many times finer each way a texture is drawn again.
pub const scale = 8;

/// Whether what isn't round in a texture is kept, as the sun's ragged rim and its rays are, or the
/// texture is drawn round alone.
pub const Detail = enum { round, kept };

/// A colour, red, green, blue and alpha from 0 to 255.
const Colour = @Vector(4, f32);

/// How finely the rings are measured, in bins a texel, how far either way a ring's colour is
/// averaged, in bins, and how finely the middle is searched for.
const bins = 8;
const window = bins / 2;
const search_bins = 4;

/// How far either way the middle is searched for from the texture's centre, in quarters of a texel.
const search_steps = 8;
const search_step: f32 = 0.25;

/// The narrowest run of one colour that is a ring, in bins; the widest blend between two rings that
/// is one edge, and the furthest a smoothed step reaches into a ring, in texels; and the fewest
/// steps of one level the same way in a row that are a gradient's rounding.
const narrowest_ring = bins / 2;
const widest_blend: f32 = 1.5;
const furthest_reach: f32 = 4;
const staircase = 3;

/// How far either way along its ray a texel's detail is averaged, in texels, and the most it may
/// then stray from its ring, in levels of a 16-bit texture, and still be rounding's rather than the
/// art's.
const along = 2;
const rounding: f32 = 0.5;

/// The highest level of a 16-bit texture's red, green and blue; alpha, which it has none of, counts
/// as green.
const levels = Colour{ 31, 63, 31, 63 };

/// Draws `image`'s first level again, `scale` times finer each way, with its levels down to a
/// texel.
///
/// It finds the middle the texture is roundest about, and measures each ring of it: the mean colour
/// of the texels whose centres lie that far out. Where every texel in a ring shares one colour,
/// over half a texel or more, the ring is flat; elsewhere a ring takes the mean of the texels
/// within half a texel of it. Between two flat rings less than `widest_blend` apart lies an edge,
/// placed where the rings keep their light. A run of `staircase` or more edges of one level each
/// the same way is a gradient that 16-bit rounding cut into steps, and each of its edges is
/// smoothed out to the nearer ring's middle, no further than `furthest_reach`; any other edge stays
/// crisp, a texel of the finer texture wide. Elsewhere the rings are drawn as measured. With
/// `detail` kept, what the rings leave out of each texel is added back, smoothly enlarged. The
/// result is dithered to 8 bits.
pub fn redraw(gpa: Allocator, image: *const srtexture.Image, detail: Detail) Allocator.Error!srtexture.Image {
    const source = image.levels[0];
    const middle = try roundest(gpa, source);
    const measured = try Profile.measure(gpa, source, middle);
    defer measured.deinit(gpa);
    const edges = try Edges.find(gpa, measured);
    defer gpa.free(edges);
    const drawn: Drawn = .{ .profile = measured, .edges = edges };

    const residue: ?[]Colour = switch (detail) {
        .round => null,
        .kept => try drawn.residue(gpa, source, middle),
    };
    defer if (residue) |left| gpa.free(left);

    const width = source.width * scale;
    const height = source.height * scale;
    const levels_made = std.math.log2_int(u32, @max(width, height)) + 1;
    var total: usize = 0;
    for (0..levels_made) |level| total += @as(usize, @max(width >> @intCast(level), 1)) * @max(height >> @intCast(level), 1) * 4;
    const rgba = try gpa.alloc(u8, total);
    errdefer gpa.free(rgba);
    const made = try gpa.alloc(srtexture.Level, levels_made);

    const fine: f32 = 1.0 / @as(f32, scale);
    const first = rgba[0 .. width * height * 4];
    for (0..height) |y| {
        for (0..width) |x| {
            const at: [2]f32 = .{ (@as(f32, @floatFromInt(x)) + 0.5) * fine, (@as(f32, @floatFromInt(y)) + 0.5) * fine };
            var colour = drawn.at(math.planeDistance(at, middle), fine);
            if (residue) |left| colour += bicubic(left, source.width, source.height, at[0] - 0.5, at[1] - 0.5);
            const noise: Colour = @splat(dither(x, y));
            const out = std.math.clamp(@floor(colour + noise), @as(Colour, @splat(0)), @as(Colour, @splat(255)));
            inline for (0..4) |k| first[(y * width + x) * 4 + k] = @intFromFloat(out[k]);
        }
    }
    made[0] = .{ .width = width, .height = height, .texels = first };
    var used = first.len;
    for (1..levels_made) |level| {
        const above = made[level - 1];
        const w = @max(above.width / 2, 1);
        const h = @max(above.height / 2, 1);
        const below = rgba[used..][0 .. w * h * 4];
        halve(above, below, w, h);
        made[level] = .{ .width = w, .height = h, .texels = below };
        used += below.len;
    }
    return .{ .levels = made };
}

/// Frees what `redraw` made, and hands its texture back to the device.
pub fn free(gpa: Allocator, image: srtexture.Image) void {
    if (image.texture) |texture| texture.release();
    var total: usize = 0;
    for (image.levels) |level| total += level.texels.len;
    gpa.free(image.levels[0].texels.ptr[0..total]);
    gpa.free(image.levels);
}

/// The middle a texture is roundest about: of the points a quarter of a texel apart within
/// `search_steps` of its centre, the one about which its texels stray least from their ring's mean.
fn roundest(gpa: Allocator, level: srtexture.Level) Allocator.Error![2]f32 {
    const reach = @as(usize, @intFromFloat(std.math.hypot(@as(f32, @floatFromInt(level.width)), @as(f32, @floatFromInt(level.height))) * search_bins)) + 3;
    const sums = try gpa.alloc(@Vector(3, f64), reach);
    defer gpa.free(sums);
    const squares = try gpa.alloc(f64, reach);
    defer gpa.free(squares);
    const counts = try gpa.alloc(u32, reach);
    defer gpa.free(counts);
    const centre: [2]f32 = .{ @as(f32, @floatFromInt(level.width)) / 2, @as(f32, @floatFromInt(level.height)) / 2 };
    var best = centre;
    var least = std.math.inf(f64);
    var i: i32 = -search_steps;
    while (i <= search_steps) : (i += 1) {
        var j: i32 = -search_steps;
        while (j <= search_steps) : (j += 1) {
            const at: [2]f32 = .{ centre[0] + @as(f32, @floatFromInt(i)) * search_step, centre[1] + @as(f32, @floatFromInt(j)) * search_step };
            @memset(sums, @splat(0));
            @memset(squares, 0);
            @memset(counts, 0);
            for (0..level.height) |y| {
                for (0..level.width) |x| {
                    const bin: usize = @intFromFloat(math.planeDistance(texelCentre(x, y), at) * search_bins);
                    const four = texel(level, x, y);
                    const colour: @Vector(3, f64) = .{ four[0], four[1], four[2] };
                    sums[bin] += colour;
                    squares[bin] += @reduce(.Add, colour * colour);
                    counts[bin] += 1;
                }
            }
            var stray: f64 = 0;
            for (sums, squares, counts) |sum, square, count| {
                if (count > 0) stray += square - @reduce(.Add, sum * sum) / @as(f64, @floatFromInt(count));
            }
            if (stray < least) {
                least = stray;
                best = at;
            }
        }
    }
    return best;
}

/// The texture's rings: the mean colour of the texels whose centres fall in each bin, over `window`
/// bins either way where they are not all one colour, and the one colour they share where they do.
const Profile = struct {
    means: []Colour,
    shared: []?[4]u8,

    fn measure(gpa: Allocator, level: srtexture.Level, middle: [2]f32) Allocator.Error!Profile {
        const count = @as(usize, @intFromFloat(std.math.hypot(@as(f32, @floatFromInt(level.width)), @as(f32, @floatFromInt(level.height))) / 2 * bins)) + 2;
        const sums = try gpa.alloc(Colour, count);
        defer gpa.free(sums);
        const means = try gpa.alloc(Colour, count);
        errdefer gpa.free(means);
        const shared = try gpa.alloc(?[4]u8, count);
        errdefer gpa.free(shared);
        const counts = try gpa.alloc(u32, count);
        defer gpa.free(counts);
        const mixed = try gpa.alloc(bool, count);
        defer gpa.free(mixed);
        @memset(sums, @splat(0));
        @memset(shared, null);
        @memset(counts, 0);
        @memset(mixed, false);
        for (0..level.height) |y| {
            for (0..level.width) |x| {
                const bin: usize = @intFromFloat(math.planeDistance(texelCentre(x, y), middle) * bins);
                if (bin >= count) continue;
                const bytes = level.texels[(y * level.width + x) * 4 ..][0..4].*;
                sums[bin] += texel(level, x, y);
                counts[bin] += 1;
                if (shared[bin]) |colour| {
                    if (!std.mem.eql(u8, &colour, &bytes)) mixed[bin] = true;
                } else shared[bin] = bytes;
            }
        }
        for (shared, mixed) |*colour, mix| {
            if (mix) colour.* = null;
        }
        // Each bin's mean: its own texels' where they share a colour, and over the window about it
        // where they don't; where no texel's centre falls in the window, the nearest bin's where
        // one does.
        var measured: ?usize = null;
        for (0..count) |bin| {
            const reach: usize = if (shared[bin] == null) window else 0;
            var sum: Colour = @splat(0);
            var n: u32 = 0;
            for (bin -| reach..@min(bin + reach + 1, count)) |near| {
                sum += sums[near];
                n += counts[near];
            }
            if (n == 0) {
                if (measured) |before| means[bin] = means[before];
                continue;
            }
            means[bin] = sum / @as(Colour, @splat(@floatFromInt(n)));
            if (measured == null) {
                for (0..bin) |gap| means[gap] = means[bin];
            }
            measured = bin;
        }
        // A bin no texel's centre falls in shares a colour only with neighbours that share the same
        // one.
        var last: ?usize = null;
        for (0..count) |bin| {
            if (counts[bin] == 0) continue;
            const before = last orelse bin;
            for (before..bin) |gap| {
                if (counts[gap] == 0) shared[gap] = if (sameColour(shared[before], shared[bin])) shared[bin] else null;
            }
            if (last == null) @memset(shared[0..bin], shared[bin]);
            last = bin;
        }
        if (last) |end| @memset(shared[end + 1 ..], shared[end]);
        return .{ .means = means, .shared = shared };
    }

    fn sameColour(a: ?[4]u8, b: ?[4]u8) bool {
        const first = a orelse return false;
        const second = b orelse return false;
        return std.mem.eql(u8, &first, &second);
    }

    fn deinit(profile: Profile, gpa: Allocator) void {
        gpa.free(profile.means);
        gpa.free(profile.shared);
    }

    /// The measured colour `r` out, between the bins.
    fn at(profile: Profile, r: f32) Colour {
        const x = r * bins - 0.5;
        if (x <= 0) return profile.means[0];
        const i: usize = @intFromFloat(x);
        if (i + 1 >= profile.means.len) return profile.means[profile.means.len - 1];
        const t: Colour = @splat(x - @as(f32, @floatFromInt(i)));
        return profile.means[i] + (profile.means[i + 1] - profile.means[i]) * t;
    }
};

/// A flat ring: its first and last bins, and its colour.
const Ring = struct {
    first: usize,
    last: usize,
    colour: Colour,

    /// Its middle, in texels, but no further than `furthest_reach` from `edge`.
    fn middle(ring: Ring, edge: f32) f32 {
        const half = @as(f32, @floatFromInt(ring.first + ring.last + 1)) / 2 / bins;
        return std.math.clamp(half, edge - furthest_reach, edge + furthest_reach);
    }
};

/// An edge between two flat rings, from `from` to `to`: `inside` becomes `outside` at `at`, over
/// `width` or crisply for none.
const Edge = struct {
    from: f32,
    to: f32,
    at: f32,
    width: f32,
    inside: Colour,
    outside: Colour,
};

const Edges = struct {
    /// The edges between the profile's flat rings (`redraw`).
    fn find(gpa: Allocator, profile: Profile) Allocator.Error![]Edge {
        var rings: std.ArrayList(Ring) = .empty;
        defer rings.deinit(gpa);
        var bin: usize = 0;
        while (bin < profile.shared.len) {
            const colour = profile.shared[bin] orelse {
                bin += 1;
                continue;
            };
            var end = bin + 1;
            while (end < profile.shared.len and Profile.sameColour(profile.shared[end], colour)) end += 1;
            if (end - bin >= narrowest_ring) try rings.append(gpa, .{
                .first = bin,
                .last = end - 1,
                .colour = .{ @floatFromInt(colour[0]), @floatFromInt(colour[1]), @floatFromInt(colour[2]), @floatFromInt(colour[3]) },
            });
            bin = end;
        }
        if (rings.items.len < 2) return gpa.alloc(Edge, 0);

        // Which edges are a gradient's rounding: runs of `staircase` or more steps of one level,
        // near and the same way.
        const pairs = rings.items.len - 1;
        const stepped = try gpa.alloc(bool, pairs);
        defer gpa.free(stepped);
        @memset(stepped, false);
        var start: usize = 0;
        while (start < pairs) {
            var end = start;
            while (end < pairs and oneLevel(rings.items, end) and way(rings.items, end) == way(rings.items, start)) end += 1;
            if (end - start >= staircase) @memset(stepped[start..end], true);
            start = @max(end, start + 1);
        }

        var edges: std.ArrayList(Edge) = .empty;
        errdefer edges.deinit(gpa);
        for (0..pairs) |n| {
            const inside = rings.items[n];
            const outside = rings.items[n + 1];
            const gap_from = @as(f32, @floatFromInt(inside.last + 1)) / bins;
            const gap_to = @as(f32, @floatFromInt(outside.first)) / bins;
            if (gap_to - gap_from > widest_blend) continue;
            const from = @round(inside.middle(gap_from) * bins) / bins;
            const to = @round(outside.middle(gap_to) * bins) / bins;
            const at = keepingLight(profile, inside.colour, outside.colour, from, to);
            try edges.append(gpa, .{
                .from = from,
                .to = to,
                .at = at,
                .width = if (stepped[n]) 2 * @min(at - from, to - at) else 0,
                .inside = inside.colour,
                .outside = outside.colour,
            });
        }
        return edges.toOwnedSlice(gpa);
    }

    /// Whether rings `n` and `n + 1` lie near and differ by no more than a level in each channel.
    fn oneLevel(rings: []const Ring, n: usize) bool {
        const gap = @as(f32, @floatFromInt(rings[n + 1].first - rings[n].last - 1)) / bins;
        if (gap > widest_blend) return false;
        const apart = @abs(@round(rings[n].colour / @as(Colour, @splat(255)) * levels) - @round(rings[n + 1].colour / @as(Colour, @splat(255)) * levels));
        return @reduce(.And, apart <= @as(Colour, @splat(1)));
    }

    /// Whether ring `n + 1` is brighter than ring `n`, darker, or neither.
    fn way(rings: []const Ring, n: usize) i2 {
        const inside = rings[n].colour[0] + rings[n].colour[1] + rings[n].colour[2];
        const outside = rings[n + 1].colour[0] + rings[n + 1].colour[1] + rings[n + 1].colour[2];
        return @as(i2, @intFromBool(outside > inside)) - @intFromBool(outside < inside);
    }

    /// Where between `from` and `to` a step from `inside` to `outside` keeps the light the profile
    /// measures there, weighted by how far out it lies, in the channel that changes most.
    fn keepingLight(profile: Profile, inside: Colour, outside: Colour, from: f32, to: f32) f32 {
        const change: [4]f32 = @abs(outside - inside);
        const in: [4]f32 = inside;
        const out: [4]f32 = outside;
        var k: usize = 0;
        for (1..3) |channel| {
            if (change[channel] > change[k]) k = channel;
        }
        if (change[k] == 0) return (from + to) / 2;
        var light: f32 = 0;
        const first: usize = @intFromFloat(@round(from * bins));
        const last: usize = @intFromFloat(@round(to * bins));
        for (first..last) |bin| {
            const r = (@as(f32, @floatFromInt(bin)) + 0.5) / bins;
            const mean: [4]f32 = profile.means[bin];
            light += mean[k] * r / bins;
        }
        // inside * (at² - from²) / 2 + outside * (to² - at²) / 2 = light
        const square = (2 * light - out[k] * to * to + in[k] * from * from) / (in[k] - out[k]);
        return @sqrt(std.math.clamp(square, from * from, to * to));
    }
};

/// The rings as drawn: their edges, and the measured profile elsewhere.
const Drawn = struct {
    profile: Profile,
    edges: []const Edge,

    /// The colour `r` out, for a texel `texel` wide.
    fn at(drawn: Drawn, r: f32, texel_width: f32) Colour {
        for (drawn.edges) |edge| {
            if (r < edge.from or r >= edge.to) continue;
            const t = std.math.clamp((r - edge.at) / @max(edge.width, texel_width) + 0.5, 0, 1);
            return math.lerp(edge.inside, edge.outside, t);
        }
        return drawn.profile.at(r);
    }

    /// What the rings leave out of each texel of `level`, whose middle is `middle`, where it runs
    /// out from the middle as the rays do: each texel's share averaged along its line from the
    /// middle, `along` either way, and kept in each channel where it is more than `rounding` levels
    /// of a 16-bit texture. What strays less, or not along a ray, is the texture's rounding.
    fn residue(drawn: Drawn, gpa: Allocator, level: srtexture.Level, middle: [2]f32) Allocator.Error![]Colour {
        const off = try gpa.alloc(Colour, level.width * level.height);
        defer gpa.free(off);
        for (0..level.height) |y| {
            for (0..level.width) |x| off[y * level.width + x] = texel(level, x, y) - drawn.at(math.planeDistance(texelCentre(x, y), middle), 1);
        }
        const left = try gpa.alloc(Colour, level.width * level.height);
        const least = @as(Colour, @splat(255 * rounding)) / levels;
        for (0..level.height) |y| {
            for (0..level.width) |x| {
                const centre = texelCentre(x, y);
                const r = math.planeDistance(centre, middle);
                const way: [2]f32 = if (r > 0) .{ (centre[0] - middle[0]) / r, (centre[1] - middle[1]) / r } else .{ 0, 0 };
                var sum: Colour = @splat(0);
                for (0..2 * along + 1) |step| {
                    const t = @as(f32, @floatFromInt(step)) - along;
                    sum += bilinear(off, level.width, level.height, centre[0] + way[0] * t - 0.5, centre[1] + way[1] * t - 0.5);
                }
                const mean = sum / @as(Colour, @splat(2 * along + 1));
                left[y * level.width + x] = @select(f32, @abs(mean) > least, mean, @as(Colour, @splat(0)));
            }
        }
        return left;
    }
};

fn texel(level: srtexture.Level, x: usize, y: usize) Colour {
    const bytes = level.texels[(y * level.width + x) * 4 ..][0..4];
    return .{ @floatFromInt(bytes[0]), @floatFromInt(bytes[1]), @floatFromInt(bytes[2]), @floatFromInt(bytes[3]) };
}

fn texelCentre(x: usize, y: usize) [2]f32 {
    return .{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
}

/// `values`, `width` by `height`, at `x`, `y` in texels from the first texel's centre, by a
/// Catmull-Rom spline each way, the edges held.
fn bicubic(values: []const Colour, width: u32, height: u32, x: f32, y: f32) Colour {
    const ix: i64 = @intFromFloat(@floor(x));
    const iy: i64 = @intFromFloat(@floor(y));
    const tx = x - @floor(x);
    const ty = y - @floor(y);
    var rows: [4]Colour = undefined;
    for (&rows, 0..) |*row, dy| {
        const yy: usize = @intCast(std.math.clamp(iy + @as(i64, @intCast(dy)) - 1, 0, height - 1));
        var column: [4]Colour = undefined;
        for (&column, 0..) |*c, dx| {
            const xx: usize = @intCast(std.math.clamp(ix + @as(i64, @intCast(dx)) - 1, 0, width - 1));
            c.* = values[yy * width + xx];
        }
        row.* = catmullRom(column, tx);
    }
    return catmullRom(rows, ty);
}

/// `values`, `width` by `height`, at `x`, `y` in texels from the first texel's centre, between the
/// four texels about it, the edges held.
fn bilinear(values: []const Colour, width: u32, height: u32, x: f32, y: f32) Colour {
    const fx = std.math.clamp(x, 0, @as(f32, @floatFromInt(width - 1)));
    const fy = std.math.clamp(y, 0, @as(f32, @floatFromInt(height - 1)));
    const x0: usize = @intFromFloat(fx);
    const y0: usize = @intFromFloat(fy);
    const x1 = @min(x0 + 1, width - 1);
    const y1 = @min(y0 + 1, height - 1);
    const tx = fx - @as(f32, @floatFromInt(x0));
    const ty = fy - @as(f32, @floatFromInt(y0));
    const top = math.lerp(values[y0 * width + x0], values[y0 * width + x1], tx);
    const bottom = math.lerp(values[y1 * width + x0], values[y1 * width + x1], tx);
    return math.lerp(top, bottom, ty);
}

fn catmullRom(p: [4]Colour, t: f32) Colour {
    const s: Colour = @splat(t);
    const half: Colour = @splat(0.5);
    const two: Colour = @splat(2);
    const three: Colour = @splat(3);
    const four: Colour = @splat(4);
    const five: Colour = @splat(5);
    return p[1] + half * s * (p[2] - p[0] + s * (two * p[0] - five * p[1] + four * p[2] - p[3] + s * (three * (p[1] - p[2]) + p[3] - p[0])));
}

/// A texel's dither, from 0 to 1: interleaved gradient noise, which spreads a gradient's rounding
/// evenly without a pattern the eye picks out.
fn dither(x: usize, y: usize) f32 {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const inner = 0.06711056 * fx + 0.00583715 * fy;
    const outer = 52.9829189 * (inner - @floor(inner));
    return outer - @floor(outer);
}

/// `above` halved each way into `below`, `width` by `height`, each texel the mean of the four it
/// covers.
fn halve(above: srtexture.Level, below: []u8, width: u32, height: u32) void {
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..4) |k| {
                var sum: u32 = 0;
                for (0..2) |dy| {
                    for (0..2) |dx| {
                        const sx = @min(x * 2 + dx, above.width - 1);
                        const sy = @min(y * 2 + dy, above.height - 1);
                        sum += above.texels[(sy * above.width + sx) * 4 + k];
                    }
                }
                below[(y * width + x) * 4 + k] = @intCast((sum + 2) / 4);
            }
        }
    }
}

/// A texture for the tests, `size` texels square, each texel coloured by `colour` for its centre's
/// distance from the middle and its place.
const Synthetic = struct {
    rgba: []u8,
    level: [1]srtexture.Level,

    fn init(gpa: Allocator, size: u32, colour: *const fn (r: f32, x: usize, y: usize) [4]u8) Allocator.Error!Synthetic {
        const rgba = try gpa.alloc(u8, size * size * 4);
        const middle: [2]f32 = @splat(@as(f32, @floatFromInt(size)) / 2);
        for (0..size) |y| {
            for (0..size) |x| rgba[(y * size + x) * 4 ..][0..4].* = colour(math.planeDistance(texelCentre(x, y), middle), x, y);
        }
        return .{ .rgba = rgba, .level = .{.{ .width = size, .height = size, .texels = rgba }} };
    }

    fn deinit(synthetic: Synthetic, gpa: Allocator) void {
        gpa.free(synthetic.rgba);
    }

    fn image(synthetic: *Synthetic) srtexture.Image {
        return .{ .levels = &synthetic.level };
    }
};

/// A 5-bit level as a 16-bit texture's texels expand it to 8 bits.
fn fiveBit(level: u8) u8 {
    return level << 3 | level >> 2;
}

fn redAt(level: srtexture.Level, x: usize, y: usize) u8 {
    return level.texels[(y * level.width + x) * 4];
}

test redraw {
    const gpa = std.testing.allocator;
    // A white disc, then a dim teal band, on black: flat rings, as the flares are made of.
    const bands = struct {
        fn colour(r: f32, _: usize, _: usize) [4]u8 {
            if (r < 6) return .{ 255, 255, 255, 255 };
            if (r < 10) return .{ 16, 80, 72, 255 };
            return .{ 0, 0, 0, 255 };
        }
    };
    var source: Synthetic = try .init(gpa, 32, bands.colour);
    defer source.deinit(gpa);
    const drawn = try redraw(gpa, &source.image(), .round);
    defer free(gpa, drawn);

    // Eight times finer, with every level down to a texel.
    try std.testing.expectEqual(9, drawn.levels.len);
    try std.testing.expectEqual(256, drawn.levels[0].width);
    for (drawn.levels[1..], drawn.levels[0 .. drawn.levels.len - 1]) |below, above| {
        try std.testing.expectEqual(above.width / 2, below.width);
    }
    try std.testing.expectEqual(1, drawn.levels[8].height);

    // Each band keeps its colour, and each edge stays a fine texel or two wide.
    const fine = drawn.levels[0];
    const row = fine.height / 2;
    try std.testing.expectEqual(255, redAt(fine, fine.width / 2, row));
    try std.testing.expect(@abs(@as(i32, redAt(fine, fine.width / 2 + 8 * scale, row)) - 16) <= 1);
    try std.testing.expectEqual(0, redAt(fine, fine.width - 1, row));
    var blended: usize = 0;
    for (fine.width / 2..fine.width) |x| {
        const red = redAt(fine, x, row);
        blended += @intFromBool(red > 17 and red < 254);
    }
    try std.testing.expect(blended <= 2);

    // Its light is the texture's.
    var before: f64 = 0;
    var after: f64 = 0;
    for (0..source.level[0].texels.len / 4) |i| before += @floatFromInt(source.level[0].texels[i * 4]);
    for (0..fine.texels.len / 4) |i| after += @floatFromInt(fine.texels[i * 4]);
    try std.testing.expectApproxEqRel(before, after / (scale * scale), 0.01);
}

test free {
    const gpa = std.testing.allocator;
    const white = struct {
        fn colour(_: f32, _: usize, _: usize) [4]u8 {
            return @splat(255);
        }
    };
    var source: Synthetic = try .init(gpa, 8, white.colour);
    defer source.deinit(gpa);
    var drawn = try redraw(gpa, &source.image(), .round);
    // A redrawn texture that was drawn hands its texture back as it is freed.
    var device: srtexture.testing.Device = .{};
    device.make(&drawn);
    free(gpa, drawn);
    try std.testing.expectEqual(0, device.held());
}

test "redraw smooths a gradient's rounding" {
    const gpa = std.testing.allocator;
    // Red falling a 5-bit level every two texels out: the stair-steps 16-bit rounding cuts a
    // smooth glow into.
    const stairs = struct {
        fn colour(r: f32, _: usize, _: usize) [4]u8 {
            const level = 31 - @min(@as(u8, @intFromFloat(r / 2)), 31);
            return .{ fiveBit(level), 0, 0, 255 };
        }
    };
    var source: Synthetic = try .init(gpa, 64, stairs.colour);
    defer source.deinit(gpa);
    const drawn = try redraw(gpa, &source.image(), .round);
    defer free(gpa, drawn);

    // Across the steps, no fine texel differs from the next by more than a little, where each step
    // of the texture is eight.
    const fine = drawn.levels[0];
    const row = fine.height / 2;
    for (fine.width / 2 + 4 * scale..fine.width / 2 + 24 * scale) |x| {
        try std.testing.expect(@abs(@as(i32, redAt(fine, x, row)) - redAt(fine, x + 1, row)) <= 3);
    }
}

test "redraw keeps the rays and leaves out the rounding" {
    const gpa = std.testing.allocator;
    // A grey disc whose texels stray a level either way, as rounding leaves them, with a bright ray
    // running out to the right.
    const rayed = struct {
        fn colour(r: f32, x: usize, y: usize) [4]u8 {
            if (r >= 12) return .{ 0, 0, 0, 255 };
            if (y == 16 and x > 18 and x < 28) return .{ 200, 200, 200, 255 };
            const grey: u8 = if ((x + y) % 2 == 0) fiveBit(16) else fiveBit(17);
            return .{ grey, grey, grey, 255 };
        }
    };
    var source: Synthetic = try .init(gpa, 32, rayed.colour);
    defer source.deinit(gpa);
    const kept = try redraw(gpa, &source.image(), .kept);
    defer free(gpa, kept);
    const round = try redraw(gpa, &source.image(), .round);
    defer free(gpa, round);

    // The ray stands out where the detail is kept, and not where the texture is drawn round.
    const middle = 16 * scale;
    const on_ray = .{ middle + 6 * scale, middle + scale / 2 };
    const beside = .{ middle + scale / 2, middle + 6 * scale };
    try std.testing.expect(redAt(kept.levels[0], on_ray[0], on_ray[1]) > redAt(kept.levels[0], beside[0], beside[1]) + 48);
    try std.testing.expect(redAt(round.levels[0], on_ray[0], on_ray[1]) < redAt(round.levels[0], beside[0], beside[1]) + 16);

    // Away from the ray, the rounding is left out: the detail kept adds nothing to the rings.
    for (middle - 6 * scale..middle - 2 * scale) |y| {
        for (middle - 6 * scale..middle - 2 * scale) |x| {
            try std.testing.expect(@abs(@as(i32, redAt(kept.levels[0], x, y)) - redAt(round.levels[0], x, y)) <= 1);
        }
    }
}
