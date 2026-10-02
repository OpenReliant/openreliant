//! `C:\lancer\surrender\surrenderlib\srImage.cpp`: the images the textures are made of, which
//! OpenReliant keeps as `srtexture.Image`. `image_shrink` (`0x004C95F0`) makes one smaller by whole
//! ratios across and down, as the driver fits a texture to the device (`srtexture.fit`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const srtexture = @import("srtexture.zig");
const Image = srtexture.Image;
const Level = srtexture.Level;

/// `image_shrink` (`0x004C95F0`): makes `image` `ratio` times smaller horizontally and vertically,
/// each ratio 1 or more, as `srtexture.fit` gives them.
///
/// An image with mipmap levels, shrunk by the same ratio both ways, drops a level for each halving
/// of the ratio, keeping at least one (`0x004C9614` on); for the game's textures, whose sides are
/// powers of two, the first level kept is the one that matches the ratio. Otherwise its finest
/// level becomes the average of each block of `ratio` pixels, ignoring a partial block at the right
/// or bottom edge and rounding each channel's average down (`0x004C96B0` on), and an image that had
/// levels has them regenerated (`image_build_mipmaps`).
///
/// **Improvement:** the regenerated levels are made the same way as a mod picture's mipmaps
/// (`srtexture.mipmaps`), averaging in linear light.
pub fn shrink(gpa: Allocator, image: *Image, ratio: [2]u32) Allocator.Error!void {
    const levels = image.levels;
    if (levels.len > 1 and ratio[0] == ratio[1]) {
        var halvings: usize = 0;
        var left = ratio[0];
        while (left > 1) : (left /= 2) halvings += 1;
        const dropped = @min(halvings, levels.len - 1);
        if (dropped == 0) return;
        const kept = try gpa.dupe(Level, levels[dropped..]);
        for (levels[0..dropped]) |level| gpa.free(level.rgba);
        gpa.free(levels);
        image.levels = kept;
        return;
    }
    const finest = levels[0];
    const width = finest.width / ratio[0];
    const height = finest.height / ratio[1];
    const rgba = try blockMeans(gpa, finest, .{ width, height }, ratio);
    // The levels made again take the pixels, and let them go where they fail.
    const made: []const Level = if (levels.len > 1)
        try srtexture.mipmaps(gpa, .{ .width = width, .height = height, .rgba = rgba }, .colour, srtexture.max_side)
    else single: {
        errdefer gpa.free(rgba);
        break :single try gpa.dupe(Level, &.{.{ .width = width, .height = height, .rgba = rgba }});
    };
    for (levels) |level| gpa.free(level.rgba);
    gpa.free(levels);
    image.levels = made;
}

/// `level`'s pixels as `size` pixels, each the mean of the block of `ratio` it covers, each channel
/// rounded down.
fn blockMeans(gpa: Allocator, level: Level, size: [2]u32, ratio: [2]u32) Allocator.Error![]u8 {
    const rgba = try gpa.alloc(u8, @as(usize, size[0]) * size[1] * 4);
    const block = ratio[0] * ratio[1];
    for (0..size[1]) |y| for (0..size[0]) |x| {
        var sums: [4]u32 = @splat(0);
        for (0..ratio[1]) |dy| for (0..ratio[0]) |dx| {
            const from = ((y * ratio[1] + dy) * level.width + x * ratio[0] + dx) * 4;
            for (&sums, level.rgba[from..][0..4]) |*sum, channel| sum.* += channel;
        };
        for (rgba[(y * size[0] + x) * 4 ..][0..4], sums) |*out, sum| out.* = @intCast(sum / block);
    };
    return rgba;
}

/// An image of `levels` levels, the finest `width` by `height`, each pixel's red its place along
/// the row, for the tests.
fn testImage(gpa: Allocator, width: u32, height: u32, levels: usize) Allocator.Error!Image {
    const made = try gpa.alloc(Level, levels);
    var count: usize = 0;
    errdefer {
        for (made[0..count]) |level| gpa.free(level.rgba);
        gpa.free(made);
    }
    var across = width;
    var down = height;
    for (made) |*level| {
        const rgba = try gpa.alloc(u8, @as(usize, across) * down * 4);
        for (0..@as(usize, across) * down) |at| rgba[at * 4 ..][0..4].* = .{ @intCast(at % across), 0, 0, 255 };
        level.* = .{ .width = across, .height = down, .rgba = rgba };
        count += 1;
        across = @max(across / 2, 1);
        down = @max(down / 2, 1);
    }
    return .{ .levels = made };
}

test shrink {
    const gpa = std.testing.allocator;
    // Halved both ways, an image with levels gives its finest up.
    var square = try testImage(gpa, 8, 8, 4);
    defer square.deinit(gpa);
    try shrink(gpa, &square, .{ 2, 2 });
    try std.testing.expectEqual(3, square.levels.len);
    try std.testing.expectEqual(4, square.width());
    // Halved across alone, its finest level is averaged in pairs, and its levels made again.
    var wide = try testImage(gpa, 8, 4, 4);
    defer wide.deinit(gpa);
    try shrink(gpa, &wide, .{ 2, 1 });
    try std.testing.expectEqual([2]u32{ 4, 4 }, [2]u32{ wide.width(), wide.height() });
    try std.testing.expectEqual(3, wide.levels.len);
    // The first pixel the mean of reds 0 and 1, rounded down; the second of 2 and 3.
    try std.testing.expectEqual(0, wide.levels[0].rgba[0]);
    try std.testing.expectEqual(2, wide.levels[0].rgba[4]);
    // A single level stays one, and a part block at the edge is left out.
    var single = try testImage(gpa, 5, 2, 1);
    defer single.deinit(gpa);
    try shrink(gpa, &single, .{ 2, 2 });
    try std.testing.expectEqual(1, single.levels.len);
    try std.testing.expectEqual([2]u32{ 2, 1 }, [2]u32{ single.width(), single.height() });
}
