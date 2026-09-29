//! A software device: draws what the driver hands it the way Direct3D 7 rasterizes, into a colour
//! buffer and a depth buffer. OpenReliant's reference: the same frame gives the same image on the
//! GPU device.
//!
//! Pixel centres lie at whole numbers, and a pixel whose centre lies on an edge belongs to the
//! triangle whose top or left edge it is; screen positions are kept in sixteenths of a pixel.
//! Colours and texture coordinates are interpolated in perspective, by the vertices' `rhw`, depth
//! straight across the screen. Textures are sampled bilinearly, wrapping, from the mip level
//! nearest to the texels a pixel spans.

const std = @import("std");
const Allocator = std.mem.Allocator;

const srd3d = @import("srd3d.zig");
const device = @import("device.zig");
const srtexture = @import("../surrenderlib/srtexture.zig");
const Vertex = device.Vertex;

const subpixel = 16;

/// Farthest a screen position is taken to be, in pixels, which keeps the edge sums in range.
const guard_band = 1 << 26;

pub const Software = struct {
    width: u32,
    height: u32,
    /// Red, green and blue, row by row from the top.
    colour: [][3]f32,
    /// Nearer is greater.
    depth: []f32,

    pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Software {
        const count = @as(usize, width) * height;
        const colour = try gpa.alloc([3]f32, count);
        errdefer gpa.free(colour);
        return .{ .width = width, .height = height, .colour = colour, .depth = try gpa.alloc(f32, count) };
    }

    pub fn deinit(software: Software, gpa: Allocator) void {
        gpa.free(software.colour);
        gpa.free(software.depth);
    }

    /// The software device draws the frame itself and adds nothing to it, so what is drawn over
    /// the scene needs no keeping apart.
    fn overlayNothing(_: *anyopaque) void {}

    pub fn interface(software: *Software) device.Device {
        return .{ .ptr = software, .vtable = &vtable };
    }

    const vtable: device.Device.VTable = .{ .begin = begin, .end = end, .draw = draw, .overlay = overlayNothing };

    fn from(ptr: *anyopaque) *Software {
        return @ptrCast(@alignCast(ptr));
    }

    fn begin(ptr: *anyopaque) void {
        const software = from(ptr);
        @memset(software.colour, .{ 0, 0, 0 });
        @memset(software.depth, 0);
    }

    fn end(_: *anyopaque) void {}

    fn draw(ptr: *anyopaque, state: device.State, primitive: device.Primitive, vertices: []const Vertex, indices: ?[]const u16) void {
        const software = from(ptr);
        const count = if (indices) |i| i.len else vertices.len;
        const pick = struct {
            fn vertex(v: []const Vertex, list: ?[]const u16, n: usize) Vertex {
                return v[if (list) |l| l[n] else n];
            }
        };
        switch (primitive) {
            .points => for (0..count) |n| software.point(state, pick.vertex(vertices, indices, n)),
            .lines => {
                var n: usize = 0;
                while (n + 1 < count) : (n += 2) software.line(state, pick.vertex(vertices, indices, n), pick.vertex(vertices, indices, n + 1));
            },
            .triangles => {
                var n: usize = 0;
                while (n + 2 < count) : (n += 3) {
                    software.triangle(state, .{ pick.vertex(vertices, indices, n), pick.vertex(vertices, indices, n + 1), pick.vertex(vertices, indices, n + 2) });
                }
            },
            .strip => for (2..count) |n| {
                software.triangle(state, .{ pick.vertex(vertices, indices, n - 2), pick.vertex(vertices, indices, n - 1), pick.vertex(vertices, indices, n) });
            },
            .fan => for (2..count) |n| {
                software.triangle(state, .{ pick.vertex(vertices, indices, 0), pick.vertex(vertices, indices, n - 1), pick.vertex(vertices, indices, n) });
            },
        }
    }

    /// The frame as 8-bit red, green, blue and alpha, opaque, row by row from the top.
    pub fn rgba(software: Software, gpa: Allocator) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, software.colour.len * 4);
        for (software.colour, 0..) |colour, i| {
            for (colour, 0..) |c, channel| out[i * 4 + channel] = std.math.lossyCast(u8, @round(std.math.clamp(c, 0, 1) * 255));
            out[i * 4 + 3] = 0xFF;
        }
        return out;
    }

    fn at(software: Software, x: usize, y: usize) usize {
        return y * software.width + x;
    }

    /// Writes one pixel's colour and depth, as the states say.
    fn fragment(software: *Software, state: device.State, index: usize, z: f32, colour: [4]f32, texel: ?[4]f32) void {
        if (state.depth.testing and z < software.depth[index]) return;
        software.colour[index] = srd3d.blend(state.blend, srd3d.shade(texel, colour, true), software.colour[index]);
        if (state.depth.writing) software.depth[index] = z;
    }

    fn point(software: *Software, state: device.State, v: Vertex) void {
        const x = @floor(v.x + 0.5);
        const y = @floor(v.y + 0.5);
        if (!(x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(software.width)) and y < @as(f32, @floatFromInt(software.height)))) return;
        const index = software.at(std.math.lossyCast(usize, x), std.math.lossyCast(usize, y));
        const texel: ?[4]f32 = if (state.texture) |t| t.sample(0, v.u, v.v) else null;
        software.fragment(state, index, v.z, device.unpack(v.diffuse), texel);
    }

    fn line(software: *Software, state: device.State, a: Vertex, b: Vertex) void {
        const span = @max(@abs(b.x - a.x), @abs(b.y - a.y));
        if (!(span < guard_band)) return;
        const steps = @max(std.math.lossyCast(usize, @ceil(span)), 1);
        const ca = device.unpack(a.diffuse);
        const cb = device.unpack(b.diffuse);
        for (0..steps + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const x = @floor(a.x + (b.x - a.x) * t + 0.5);
            const y = @floor(a.y + (b.y - a.y) * t + 0.5);
            if (!(x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(software.width)) and y < @as(f32, @floatFromInt(software.height)))) continue;
            // In perspective where the ends carry a depth, else straight across.
            const w = a.rhw + (b.rhw - a.rhw) * t;
            const far = if (w > 0) t * b.rhw / w else t;
            var colour: [4]f32 = undefined;
            for (&colour, ca, cb) |*c, p, q| c.* = p + (q - p) * far;
            const texel: ?[4]f32 = if (state.texture) |tex| tex.sample(0, a.u + (b.u - a.u) * far, a.v + (b.v - a.v) * far) else null;
            software.fragment(state, software.at(std.math.lossyCast(usize, x), std.math.lossyCast(usize, y)), a.z + (b.z - a.z) * t, colour, texel);
        }
    }

    const Screen = struct { x: i64, y: i64 };

    fn fixed(pixels: f32) i64 {
        return std.math.lossyCast(i64, @round(std.math.clamp(pixels, -guard_band, guard_band) * subpixel));
    }

    fn edge(a: Screen, b: Screen, x: i64, y: i64) i64 {
        return (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
    }

    /// Whether a pixel centre exactly on an edge belongs to the triangle: on its top or left edges.
    fn topLeft(a: Screen, b: Screen) bool {
        return b.y < a.y or (b.y == a.y and b.x > a.x);
    }

    fn triangle(software: *Software, state: device.State, corners: [3]Vertex) void {
        var v = corners;
        var s: [3]Screen = undefined;
        for (&s, v) |*p, c| p.* = .{ .x = fixed(c.x), .y = fixed(c.y) };
        var area = edge(s[0], s[1], s[2].x, s[2].y);
        if (area == 0) return;
        // Direct3D culls nothing here: turn the triangle so its inside is positive.
        if (area < 0) {
            std.mem.swap(Screen, &s[1], &s[2]);
            std.mem.swap(Vertex, &v[1], &v[2]);
            area = -area;
        }
        const x_range = pixelRange(@min(s[0].x, s[1].x, s[2].x), @max(s[0].x, s[1].x, s[2].x), software.width) orelse return;
        const y_range = pixelRange(@min(s[0].y, s[1].y, s[2].y), @max(s[0].y, s[1].y, s[2].y), software.height) orelse return;

        const edges = [3][2]usize{ .{ 1, 2 }, .{ 2, 0 }, .{ 0, 1 } };
        const size: f32 = @floatFromInt(area);
        var step: [2][3]f32 = undefined;
        for (edges, 0..) |e, i| {
            step[0][i] = @as(f32, @floatFromInt(s[e[0]].y - s[e[1]].y)) * subpixel / size;
            step[1][i] = @as(f32, @floatFromInt(s[e[1]].x - s[e[0]].x)) * subpixel / size;
        }
        var colours: [3][4]f32 = undefined;
        for (&colours, v) |*c, x| c.* = device.unpack(x.diffuse);

        var py = y_range[0];
        while (py < y_range[1]) : (py += 1) {
            const cy = @as(i64, py) * subpixel;
            var px = x_range[0];
            pixels: while (px < x_range[1]) : (px += 1) {
                const cx = @as(i64, px) * subpixel;
                var weights: [3]f32 = undefined;
                for (edges, &weights) |e, *weight| {
                    const sum = edge(s[e[0]], s[e[1]], cx, cy);
                    if (sum < 0 or (sum == 0 and !topLeft(s[e[0]], s[e[1]]))) continue :pixels;
                    weight.* = @as(f32, @floatFromInt(sum)) / size;
                }
                var z: f32 = 0;
                for (weights, v) |weight, x| z += weight * x.z;
                const index = software.at(px, py);
                if (state.depth.testing and z < software.depth[index]) continue;

                const perspective = perspectiveWeights(weights, v);
                var colour: [4]f32 = @splat(0);
                for (perspective, colours) |weight, c| {
                    for (&colour, c) |*out, x| out.* += weight * x;
                }
                const texel: ?[4]f32 = if (state.texture) |texture| blk: {
                    const uv = coordinates(perspective, v);
                    if (state.filter == .point) break :blk texture.samplePoint(uv[0], uv[1]);
                    const level = mipLevel(texture, uv, .{
                        coordinates(perspectiveWeights(add(weights, step[0]), v), v),
                        coordinates(perspectiveWeights(add(weights, step[1]), v), v),
                    });
                    break :blk texture.sample(level, uv[0], uv[1]);
                } else null;
                software.fragment(state, index, z, colour, texel);
            }
        }
    }
};

/// The pixels whose centres, at whole numbers, can lie between `low` and `high`, in sixteenths of a
/// pixel, cut to `size`; null when none can.
fn pixelRange(low: i64, high: i64, size: u32) ?[2]u32 {
    const first = std.math.lossyCast(u32, @divFloor(low + subpixel - 1, subpixel));
    const last = std.math.lossyCast(u32, @min(@divFloor(high, subpixel) + 1, size));
    if (first >= last) return null;
    return .{ first, last };
}

fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

/// Screen weights made into weights for what varies in perspective; straight across where the
/// corners carry no depth.
fn perspectiveWeights(weights: [3]f32, v: [3]Vertex) [3]f32 {
    var w: f32 = 0;
    for (weights, v) |weight, x| w += weight * x.rhw;
    if (!(w != 0)) return weights;
    var out: [3]f32 = undefined;
    for (&out, weights, v) |*o, weight, x| o.* = weight * x.rhw / w;
    return out;
}

fn coordinates(weights: [3]f32, v: [3]Vertex) [2]f32 {
    var uv: [2]f32 = @splat(0);
    for (weights, v) |weight, x| {
        uv[0] += weight * x.u;
        uv[1] += weight * x.v;
    }
    return uv;
}

/// The mip level the device samples: the nearest to the texels a pixel spans, from the texture
/// coordinates at the pixel and one pixel across and down.
fn mipLevel(texture: *const srtexture.Image, uv: [2]f32, neighbours: [2][2]f32) usize {
    const width: f32 = @floatFromInt(texture.width());
    const height: f32 = @floatFromInt(texture.height());
    var widest: f32 = 0;
    for (neighbours) |n| {
        const du = (n[0] - uv[0]) * width;
        const dv = (n[1] - uv[1]) * height;
        widest = @max(widest, du * du + dv * dv);
    }
    const lod = 0.5 * std.math.log2(widest);
    if (!(lod > 0.5)) return 0;
    return @min(std.math.lossyCast(usize, @floor(lod + 0.5)), texture.levels.len - 1);
}

const testing = struct {
    fn vertex(x: f32, y: f32, colour: u32) Vertex {
        return .{ .x = x, .y = y, .z = 0.5, .rhw = 1, .diffuse = colour };
    }

    const flat: device.State = .{ .texture = null, .depth = .{ .testing = false, .writing = false }, .blend = srd3d.factors(.add) };

    fn expectColour(expected: [3]f32, actual: [3]f32) !void {
        for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-5);
    }
};

test "triangles sharing an edge cover each pixel once" {
    const gpa = std.testing.allocator;
    var software: Software = try .init(gpa, 8, 8);
    defer software.deinit(gpa);
    const target = software.interface();
    target.begin();
    // A quad over pixels 2 to 5, centres at whole numbers, added at half brightness in two
    // triangles.
    const grey = 0x00808080;
    const quad = [4]Vertex{
        testing.vertex(1.5, 1.5, grey), testing.vertex(5.5, 1.5, grey),
        testing.vertex(5.5, 5.5, grey), testing.vertex(1.5, 5.5, grey),
    };
    target.draw(testing.flat, .fan, &quad, null);
    const half = 128.0 / 255.0;
    for (0..8) |y| {
        for (0..8) |x| {
            const inside = x >= 2 and x <= 5 and y >= 2 and y <= 5;
            try testing.expectColour(if (inside) .{ half, half, half } else .{ 0, 0, 0 }, software.colour[software.at(x, y)]);
        }
    }
}

test "depth: the nearer opaque triangle stays in front" {
    const gpa = std.testing.allocator;
    var software: Software = try .init(gpa, 8, 8);
    defer software.deinit(gpa);
    const target = software.interface();
    target.begin();
    const opaque_state: device.State = .{ .texture = null, .depth = .{ .testing = true, .writing = true }, .blend = null };
    var near = [3]Vertex{ testing.vertex(-1, -1, 0xFFFF0000), testing.vertex(9, -1, 0xFFFF0000), testing.vertex(-1, 9, 0xFFFF0000) };
    for (&near) |*v| v.z = 0.8;
    var far = [3]Vertex{ testing.vertex(-1, -1, 0xFF0000FF), testing.vertex(9, -1, 0xFF0000FF), testing.vertex(-1, 9, 0xFF0000FF) };
    for (&far) |*v| v.z = 0.2;
    target.draw(opaque_state, .triangles, &near, null);
    target.draw(opaque_state, .triangles, &far, null);
    try testing.expectColour(.{ 1, 0, 0 }, software.colour[software.at(1, 1)]);
    try std.testing.expectApproxEqAbs(0.8, software.depth[software.at(1, 1)], 1e-6);
}

test "points and lines" {
    const gpa = std.testing.allocator;
    var software: Software = try .init(gpa, 8, 8);
    defer software.deinit(gpa);
    const target = software.interface();
    target.begin();
    // A point lands in the pixel whose centre is nearest.
    target.draw(testing.flat, .points, &.{testing.vertex(2.4, 3.6, 0x00FFFFFF)}, null);
    try testing.expectColour(.{ 1, 1, 1 }, software.colour[software.at(2, 4)]);
    // A line along a row, fading from full to nothing.
    target.draw(testing.flat, .lines, &.{ testing.vertex(0, 7, 0x00FF0000), testing.vertex(7, 7, 0x00000000) }, null);
    try testing.expectColour(.{ 1, 0, 0 }, software.colour[software.at(0, 7)]);
    try testing.expectColour(.{ 0, 0, 0 }, software.colour[software.at(7, 7)]);
}

test mipLevel {
    const rgba = [_]u8{0} ** (16 * 16 * 4);
    const levels = [_]srtexture.Level{
        .{ .width = 16, .height = 16, .rgba = &rgba },
        .{ .width = 8, .height = 8, .rgba = &rgba },
        .{ .width = 4, .height = 4, .rgba = &rgba },
    };
    const texture: srtexture.Image = .{ .levels = &levels };
    try std.testing.expectEqual(0, mipLevel(&texture, .{ 0, 0 }, .{ .{ 1.0 / 16.0, 0 }, .{ 0, 1.0 / 16.0 } }));
    try std.testing.expectEqual(1, mipLevel(&texture, .{ 0, 0 }, .{ .{ 2.0 / 16.0, 0 }, .{ 0, 1.0 / 16.0 } }));
    try std.testing.expectEqual(2, mipLevel(&texture, .{ 0, 0 }, .{ .{ 1, 0 }, .{ 0, 0 } }));
}
