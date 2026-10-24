//! Window 7 of the display, the power distribution (`hud_window_draw`'s case for it, at
//! `0x00488491`): the power ball, and the shields', guns' and engines' shares of the power as
//! percentages and bars. `hud_init` (`0x00483150`) works out the tables the ball is drawn from.
//!
//! The ball is a sphere textured with `powerball.tga` and lit from the front and above. The
//! texture scrolls with the power setting, so the ball looks as if it turns toward wherever the
//! power is. The game writes it into the display a pixel at a time; OpenReliant writes the same
//! pixels into an image each frame and draws that.
//!
//! **Improvement:** a mod's picture can be a whole multiple of the original's size
//! (`matmanager.Sizes.multiples`), and the ball is drawn with as many pixels for each of the
//! original's, as sharp as its picture.

const std = @import("std");
const Allocator = std.mem.Allocator;

const math = @import("../../surrender/math.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const tga = @import("../../../formats/tga.zig");
const Random = @import("../../random.zig").Random;
const input_power = @import("../../input/power.zig");
const gameobj = @import("../gameobj.zig");
const hud = @import("../hud.zig");

/// The texture `hud_init` reads for the ball.
pub const picture_name = "powerball.tga";

/// The ball's size: 62 pixels across and down, holding a circle of radius 31.
pub const size = 62;
const radius = size / 2;

/// The texture's size: `powerball.tga` is 256 by 256.
const texture_size = 256;

/// Levels of light, and colours for each: a colour is picked by the texture's level at a pixel
/// and the light there.
const lights = 64;
const levels = 32;

/// How far the display's shake can move a row of the ball to the right: `hit_shake` is at most 2
/// by the time the display is drawn, which gives 20 pixels.
const most_jitter = 20;

/// The width of the image the ball is drawn into, with room for the shake.
pub const image_width = size + most_jitter;

/// The share of the image's width that the ball fills, the rest being room for the shake.
pub const ball_across: f32 = @as(f32, size) / image_width;

/// A step across the ball, from one pixel to the next: its radius is 1 in the tables' sums
/// (`0x004DC8D4`).
const step: f32 = 1.0 / @as(f32, radius);

/// The sphere `fillSphere` maps the texture onto: its radius squared (`0x004DC480`), and the texels
/// from the texture's middle to a half turn round it, across and down (`0x004DC8C8`, and negated
/// for down at `0x004DC8CC`).
const sphere_squared: f32 = 2;
const half_turn_texels: f32 = 138;

/// What `hud_init` takes off each point of the sphere's offset into the texture, a number in its
/// code: in 16 bits, the same as adding `0x8080`, the texture's middle, row 128 and column 128
/// (`textureMiddle`).
const middle_offset = 0x7F80;

/// The offset of the middle of a texture `side` texels across and down: its middle row, then its
/// middle column.
fn textureMiddle(side: u32) u32 {
    return side / 2 * side + side / 2;
}

/// How `fillShade` lights the ball: each pixel stands for the point `shade_shift` further along
/// either axis on a sphere of radius 1 (`0x004DC4C0`), so that the brightest spot is up and to the
/// left of the middle; the light stands `light_distance` in front (a number in `hud_init`'s code);
/// and a point facing it straight on gets `shade_scale` (`0x004DC554`).
const shade_shift: f32 = 0.3;
const light_distance: f32 = 8;
const shade_scale: f32 = 64;

/// How `fillColours` colours the ball: a level of light is its share of the brightest,
/// `light_share` (`0x004DC8C4`), squared, plus `least_brightness` (`0x004DC3D4`); what that comes
/// to past 1 adds a white highlight of `highlight_level` times it to every channel
/// (`0x004DC6CC`). The texture's level makes the red and the green, `orange` times it
/// (`0x004DC8C0`, `0x004DC8BC`).
const light_share: f32 = 1.0 / @as(f32, lights - 1);
const least_brightness: f32 = 0.25;
const highlight_level: f32 = 255;
const orange = [2]f32{ 184, 67 };

comptime {
    // The tables' fractions are the game's own constants, worked out from the ball's sizes.
    std.debug.assert(step == 1.0 / 31.0);
    std.debug.assert(light_share == 1.0 / 63.0);
    // Wrapped round the texture as 16 bits wrap, taking `middle_offset` off adds the middle.
    std.debug.assert(@mod(-middle_offset, texture_size * texture_size) == textureMiddle(texture_size));
    std.debug.assert(stepAt(1) == step);
}

/// The tables the ball is drawn from, and the image OpenReliant draws it into. The game's are
/// `size` pixels across and down, and its texture `texture_size`; a mod's picture can make them
/// `multiple` times as large.
pub const Ball = struct {
    /// How many of the ball's pixels stand for each of the original's, across and down: its
    /// picture's size over `texture_size`, 1 for the game's own.
    multiple: u32,
    /// `powerball.tga`'s levels, a byte a pixel, top row first (`0x00569984`). The image is grey,
    /// and `hud_init` keeps the top 5 bits of each pixel's first channel.
    texture: []u8,
    /// Where each pixel of the ball shows the texture: a sphere mapped onto it, an offset into
    /// the texture that wraps round its end, as the game's 16 bits wrap round its 256 by 256
    /// texels (`0x00579E2C`).
    sphere: []u32,
    /// How brightly each pixel is lit, 0 to 63 (`0x00567F90`).
    shade: []u8,
    /// The colours: for each level of light, one for each of the texture's levels (`0x00566F90`,
    /// in the display's 16-bit format, and `0x00568E94` for the 8-bit one).
    colours: [lights][levels][3]u8,
    /// The ball, drawn afresh each frame, and the image the display draws it with.
    pixels: []u8,
    level: [1]srtexture.Level,
    image: srtexture.Image,

    /// What `hud_init` works out from `powerball.tga`, `picture`, at as many times the original's
    /// size as the picture is (`multiple`).
    pub fn create(gpa: Allocator, picture: tga.Image) Allocator.Error!*Ball {
        const multiple: u32 = @max(1, picture.width / texture_size);
        const ball = try gpa.create(Ball);
        errdefer gpa.destroy(ball);
        const side = texture_size * @as(usize, multiple);
        const ball_side = size * @as(usize, multiple);
        const texture = try gpa.alloc(u8, side * side);
        errdefer gpa.free(texture);
        const sphere = try gpa.alloc(u32, ball_side * ball_side);
        errdefer gpa.free(sphere);
        const shade = try gpa.alloc(u8, ball_side * ball_side);
        errdefer gpa.free(shade);
        const pixels = try gpa.alloc(u8, image_width * multiple * ball_side * 4);
        ball.* = .{ .multiple = multiple, .texture = texture, .sphere = sphere, .shade = shade, .colours = undefined, .pixels = pixels, .level = undefined, .image = undefined };
        fillTexture(ball.texture, side, picture);
        fillSphere(ball.sphere, multiple);
        fillShade(ball.shade, multiple);
        fillColours(&ball.colours, leftOver());
        @memset(ball.pixels, 0);
        ball.level = .{.{ .width = image_width * multiple, .height = size * multiple, .texels = ball.pixels }};
        ball.image = .{ .levels = &ball.level };
        return ball;
    }

    /// Frees the ball, once its image has handed its texture back to the device.
    pub fn destroy(ball: *Ball, gpa: Allocator) void {
        ball.image.releaseTexture();
        for ([_][]u8{ ball.texture, ball.shade, ball.pixels }) |table| gpa.free(table);
        gpa.free(ball.sphere);
        gpa.destroy(ball);
    }

    /// The ball for the power setting `setting`, as window 7 writes it into the display: each row
    /// of the circle, the texture scrolled by half the setting, lit by `shade` and coloured by
    /// `colours`. While `hit_shake` is above zero, each row moves right by a random share of
    /// `10 * hit_shake` pixels, a number of `random` a row, as the game does in 16-bit colour.
    /// At a larger `multiple`, the scroll and the shake are as many times larger, and each shake
    /// moves the rows that stand for one of the original's.
    pub fn render(ball: *Ball, setting: [2]f32, hit_shake: f32, random: ?*Random) void {
        @memset(ball.pixels, 0);
        const multiple: i32 = @intCast(ball.multiple);
        const scale: f32 = @floatFromInt(ball.multiple);
        const side = texture_size * @as(i64, multiple);
        const ball_radius = radius * multiple;
        const ball_side = size * multiple;
        const width = image_width * multiple;
        const scroll = std.math.lossyCast(i32, setting[0] * 0.5 * scale) - std.math.lossyCast(i32, setting[1] * -0.5 * scale) * side;
        var jitter: i32 = 0;
        var row: i32 = -ball_radius;
        while (row < ball_radius) : (row += 1) {
            const span = std.math.lossyCast(i32, @sqrt(@as(f32, @floatFromInt(ball_radius * ball_radius - row * row))) + 0.5);
            if (@mod(row + ball_radius, multiple) == 0) jitter = @min(hud.rowShift(hit_shake, random), most_jitter) * multiple;
            const first: usize = @intCast((row + ball_radius) * ball_side + ball_radius - span);
            const into: usize = @intCast((row + ball_radius) * width + ball_radius - span + jitter);
            for (0..@intCast(2 * span)) |across| {
                const at = first + across;
                const texel = ball.texture[@intCast(std.math.clamp(@as(i64, ball.sphere[at]) + scroll, 0, side * side - 1))];
                const colour = ball.colours[ball.shade[at]][texel];
                const pixel = ball.pixels[(into + across) * 4 ..][0..4];
                pixel.* = .{ colour[0], colour[1], colour[2], 255 };
            }
        }
        ball.image.changed = true;
    }
};

/// `hud_channel` (`0x00482DE0`): a colour channel, cut down to a whole number and kept within 0
/// and 255.
fn channel(x: f32) u8 {
    return @intCast(std.math.clamp(std.math.lossyCast(i32, x), 0, 255));
}

/// The texture, `side` texels across and down, from `picture`; a texel past the picture's edges is
/// black.
fn fillTexture(texture: []u8, side: usize, picture: tga.Image) void {
    for (0..side) |y| {
        for (0..side) |x| {
            const grey = if (x < picture.width and y < picture.height) picture.pixel(x, y)[0] else 0;
            texture[y * side + x] = grey >> 3;
        }
    }
}

/// Each pixel of the ball as a point on a sphere of radius √2 seen from the front, and where it
/// falls on the texture: `half_turn_texels` to the half turn from its middle, `x` to the right and
/// `y` down. A pixel outside the circle is pulled in toward it. At a larger `multiple`, the ball
/// and the texture both are as many times larger.
fn fillSphere(sphere: []u32, multiple: u32) void {
    const ball_side = size * multiple;
    const side: i64 = texture_size * multiple;
    const ball_step = stepAt(multiple);
    const half_turn = half_turn_texels * @as(f32, @floatFromInt(multiple));
    for (0..ball_side) |row| {
        const y = centred(row, multiple) * ball_step;
        const y_squared = y * y;
        for (0..ball_side) |column| {
            const x = centred(column, multiple) * ball_step;
            const at = inside(x, y, x * x + y_squared);
            const z = @sqrt(sphere_squared - at.squared);
            const across: f32 = std.math.asin(at.x / z);
            const down = std.math.lossyCast(i32, std.math.asin(at.y / z) * (1.0 / std.math.pi) * -half_turn);
            const offset = std.math.lossyCast(i32, across * (1.0 / std.math.pi) * half_turn) - down * side + textureMiddle(@intCast(side));
            sphere[row * ball_side + column] = @intCast(@mod(offset, side * side));
        }
    }
}

/// How much light each pixel of the ball gets, from 0 to 63: the point it stands for
/// (`shadePoint`) gets `shade_scale` times the cosine of the angle between the sphere's surface
/// there and a light `light_distance` in front.
fn fillShade(shade: []u8, multiple: u32) void {
    const light: math.Vector = .{ 0, 0, light_distance };
    const ball_side = size * multiple;
    for (0..ball_side) |row| {
        for (0..ball_side) |column| {
            const at = shadePoint(row, column, multiple);
            const point: math.Vector = .{ at.x, at.y, @sqrt(1 - at.squared) };
            const towards = light - point;
            const lit = math.dot(towards, point) * shade_scale / math.length(towards);
            shade[row * ball_side + column] = @intCast(std.math.clamp(std.math.lossyCast(i32, lit), 0, lights - 1));
        }
    }
}

/// The point the pixel at `row` and `column` stands for, `(x + shade_shift, y + shade_shift)` on a
/// sphere of radius 1, so that the brightest spot is up and to the left of the middle.
fn shadePoint(row: usize, column: usize, multiple: u32) Inside {
    const ball_step = stepAt(multiple);
    const y = centred(row, multiple) * ball_step + shade_shift;
    const x = centred(column, multiple) * ball_step + shade_shift;
    return inside(x, y, x * x + y * y);
}

/// What `hud_init` has left in the highlight's place from working out the shade, which the colours
/// start from (`fillColours`): the `x` of the last pixel's point at the original's size.
fn leftOver() f32 {
    return shadePoint(size - 1, size - 1, 1).x;
}

/// The colours: orange shades of the texture's level, brighter with the light, and past three
/// quarters of it a white highlight added to every channel. Below that, the game adds what is left
/// in the highlight's place from working the shade out, `left_over`, which is well under 1 and
/// only moves where the channels round to.
fn fillColours(colours: *[lights][levels][3]u8, left_over: f32) void {
    var highlight = left_over;
    for (colours, 0..) |*light, row| {
        const t = @as(f32, @floatFromInt(row)) * light_share;
        for (light, 0..) |*colour, level| {
            var brightness = t * t + least_brightness;
            if (brightness > 1) {
                highlight = (brightness - 1) * highlight_level;
                brightness = 1;
            }
            const value = @as(f32, @floatFromInt(level)) * step * brightness;
            colour.* = .{ channel(value * orange[0] + highlight), channel(value * orange[1] + highlight), channel(highlight) };
        }
    }
}

/// A row or column of the ball, from its middle, for a ball `multiple` times the original's size.
fn centred(index: usize, multiple: u32) f32 {
    return @floatFromInt(@as(i64, @intCast(index)) - radius * @as(i64, multiple));
}

/// A step across a ball `multiple` times the original's size: `step` for the original's.
fn stepAt(multiple: u32) f32 {
    return 1.0 / @as(f32, @floatFromInt(radius * multiple));
}

const Inside = struct { x: f32, y: f32, squared: f32 };

/// A point of the ball's square outside its circle, divided by its distance squared, and taken as
/// lying on it; one inside, as it stands.
fn inside(x: f32, y: f32, squared: f32) Inside {
    if (squared > 1) return .{ .x = x / squared, .y = y / squared, .squared = 1 };
    return .{ .x = x, .y = y, .squared = squared };
}

/// What window 7 needs to draw what it shows.
pub const Shown = struct {
    ball: *Ball,
    /// The player's ship, whose power setting the window shows.
    object: *const gameobj.GameObject,
    /// The camera's shake, which shakes the ball too.
    hit_shake: f32,
    random: ?*Random,
};

/// The window's title, POWER (`0xA7`), and where it stands from the window's place.
const title = 0xA7;
const title_at = [2]i32{ 2, -77 };

/// The shares as whole percentages, which `hud_window_draw` rounds from each share times
/// `percent` (`0x004DC440`) as `sr_round` does and then, where they come to 101, takes one from the
/// first that is 34.
pub fn percentages(setting: [2]f32) std.EnumArray(input_power.System, i32) {
    const shares = input_power.shares(setting);
    var found: std.EnumArray(input_power.System, i32) = undefined;
    for (std.enums.values(input_power.System)) |system| {
        found.set(system, math.round(shares.get(system) * percent));
    }
    if (found.get(.shields) + found.get(.guns) + found.get(.engines) == 101) {
        for (std.enums.values(input_power.System)) |system| {
            if (found.get(system) != 34) continue;
            found.set(system, 33);
            break;
        }
    }
    return found;
}

/// A bar of the window: the shape that stands for its empty bar, the shape drawn over it for the
/// share, and the pane that cuts the share down to size (`0x00566658`, `0x00566654` and
/// `0x00566650`), as the pane's edges stand for a share, from the window's place.
const Bar = struct {
    empty: u16,
    full: u16,
    at: [2]i32,
    /// The pane's left, top, right and bottom edges, inclusive, for a share.
    pane: *const fn (share: f32) [4]i32,
};

/// What a share of the power is multiplied by for its percentage.
const percent: f32 = 100;

/// The bars' lengths in the display's own pixels: the shields' across the top (`0x004DC908`), the
/// guns' and the engines' down the sides (`0x004DC90C`).
const across_length: f32 = 54;
const down_length: f32 = 48;

const bars = std.EnumArray(input_power.System, Bar).init(.{
    // Across the top, emptying from the left.
    .shields = .{ .empty = 0x83, .full = 0x80, .at = .{ 41, -32 }, .pane = struct {
        fn pane(share: f32) [4]i32 {
            return .{ 40 + math.round(across_length - share * across_length), -33, 94, -17 };
        }
    }.pane },
    // Up the left side, filling from the foot.
    .guns = .{ .empty = 0x84, .full = 0x81, .at = .{ 34, -13 }, .pane = struct {
        fn pane(share: f32) [4]i32 {
            return .{ 33, -14 + math.round(down_length - share * down_length), 64, 34 };
        }
    }.pane },
    // Down the right side, filling from the top.
    .engines = .{ .empty = 0x85, .full = 0x82, .at = .{ 70, -13 }, .pane = struct {
        fn pane(share: f32) [4]i32 {
            return .{ 69, -14, 100, -14 + math.round(share * down_length) };
        }
    }.pane },
});

/// Where each share's percentage stands from the window's place.
const figures = std.EnumArray(input_power.System, [2]i32).init(.{
    .shields = .{ 86, -43 },
    .guns = .{ 18, 30 },
    .engines = .{ 86, 30 },
});

/// The shapes the window draws last, and where from its place: the frames round the figures.
const labels = [_]struct { shape: u16, at: [2]i32 }{
    .{ .shape = 0xBE, .at = .{ 53, -67 } },
    .{ .shape = 0xBD, .at = .{ 103, 1 } },
    .{ .shape = 0xC1, .at = .{ 2, 4 } },
};

/// Where the ball's image stands from the window's place: the circle's middle is at 68 across and
/// 1 up.
const ball_at: [2]i32 = .{ 68 - radius, -1 - radius };

/// Draws what window 7 shows, in the order `hud_window_draw` draws it: the title, the ball, the
/// percentages, then each bar and the shapes round them.
pub fn draw(shown: Shown, canvas: hud.windows.Canvas) hud.windows.Canvas.Error!void {
    try canvas.string(.power_title, title, title_at, .left);

    const setting = input_power.point(shown.object);
    shown.ball.render(setting, shown.hit_shake, shown.random);
    canvas.image(.power_ball, &shown.ball.image, .{ image_width, size }, ball_at, null);

    const found = percentages(setting);
    for (std.enums.values(input_power.System)) |system| {
        try canvas.print(.power_figures, "{d}%", .{found.get(system)}, figures.get(system), .left);
    }

    const shares = input_power.shares(setting);
    for ([_]input_power.System{ .guns, .engines, .shields }) |system| {
        const bar = bars.get(system);
        try canvas.shape(bar.empty, bar.at);
        try canvas.shapeIn(bar.full, bar.at, bar.pane(shares.get(system)));
    }
    for (labels) |label| try canvas.shape(label.shape, label.at);
}

/// What the tests here and in the scripts' make the ball from.
pub const testing = struct {
    /// A picture of `powerball.tga`'s size: a grey gradient across, so that where the ball samples
    /// it shows. Its pixels are in `gpa`.
    pub fn picture(gpa: Allocator) !tga.Image {
        const rgb = try gpa.alloc(u8, texture_size * texture_size * 3);
        for (0..texture_size * texture_size) |at| {
            const grey: u8 = @intCast(at % texture_size);
            @memset(rgb[at * 3 ..][0..3], grey);
        }
        return .{ .width = texture_size, .height = texture_size, .rgb = rgb };
    }
};

test Ball {
    const gpa = std.testing.allocator;
    const picture = try testing.picture(gpa);
    defer gpa.free(picture.rgb);
    const ball = try Ball.create(gpa, picture);
    defer ball.destroy(gpa);

    // The middle of the ball shows the middle of the texture; the texture keeps 5 bits a level.
    try std.testing.expectEqual(0x8080, ball.sphere[radius * size + radius]);
    try std.testing.expectEqual(128 >> 3, ball.texture[0x8080]);
    // The light is brightest above and to the left of the middle, and none reaches the far edge.
    try std.testing.expect(ball.shade[20 * size + 20] > ball.shade[40 * size + 40]);
    try std.testing.expectEqual(lights - 1, std.mem.max(u8, ball.shade));
    // Dark and unlit is black; the brightest light adds a white highlight.
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, ball.colours[0][0]);
    try std.testing.expect(ball.colours[lights - 1][0][2] > 0);
    try std.testing.expectEqual(0, ball.colours[10][levels - 1][2]);

    // Drawn, the ball is a circle, clear outside it.
    ball.render(.{ 1, 1 }, 0, null);
    try std.testing.expect(ball.image.changed);
    const middle = (radius * image_width + radius) * 4;
    try std.testing.expectEqual(255, ball.pixels[middle + 3]);
    try std.testing.expectEqual(0, ball.pixels[3]);
    // The texture scrolls with the setting: across it, the ball's middle shows another level.
    const before = ball.pixels[middle..][0..3].*;
    ball.render(.{ -60, 1 }, 0, null);
    try std.testing.expect(!std.mem.eql(u8, &before, ball.pixels[middle..][0..3]));
}

test "a larger picture draws a larger ball" {
    const gpa = std.testing.allocator;
    const picture = try testing.picture(gpa);
    defer gpa.free(picture.rgb);
    const ball = try Ball.create(gpa, picture);
    defer ball.destroy(gpa);
    // The same gradient, twice as large.
    const rgb = try gpa.alloc(u8, 4 * texture_size * texture_size * 3);
    defer gpa.free(rgb);
    for (0..4 * texture_size * texture_size) |at| @memset(rgb[at * 3 ..][0..3], @intCast(at % (2 * texture_size) / 2));
    const large = try Ball.create(gpa, .{ .width = 2 * texture_size, .height = 2 * texture_size, .rgb = rgb });
    defer large.destroy(gpa);
    try std.testing.expectEqual(2, large.multiple);
    try std.testing.expectEqual(2 * image_width, large.image.width());
    try std.testing.expectEqual(2 * size, large.image.height());

    // Its middle shows the texture's middle, and every other pixel stands for one of the
    // original's, lit and coloured alike.
    const large_side = 2 * size;
    try std.testing.expectEqual(textureMiddle(2 * texture_size), large.sphere[size * large_side + size]);
    try std.testing.expectEqual(ball.colours, large.colours);
    for (0..size) |row| for (0..size) |column| {
        try std.testing.expectEqual(ball.shade[row * size + column], large.shade[2 * row * large_side + 2 * column]);
    };
    // Drawn, the middle of each shows the same level.
    ball.render(.{ 1, 1 }, 0, null);
    large.render(.{ 1, 1 }, 0, null);
    const middle_pixel = (radius * image_width + radius) * 4;
    const large_middle = (size * 2 * image_width + size) * 4;
    try std.testing.expectEqualSlices(u8, ball.pixels[middle_pixel..][0..4], large.pixels[large_middle..][0..4]);

    // The shake moves the two rows that stand for one of the original's alike, twice as far.
    var random: Random = .{};
    large.render(.{ 1, 1 }, 2, &random);
    var moved = false;
    for (0..size) |pair| {
        var shifts: [2]?usize = @splat(null);
        for (&shifts, 0..) |*shift, half| {
            const row = 2 * pair + half;
            const start = for (0..2 * image_width) |x| {
                if (large.pixels[(row * 2 * image_width + x) * 4 + 3] != 0) break x;
            } else continue;
            const from_middle: i32 = @as(i32, @intCast(row)) - size;
            const span = std.math.lossyCast(i32, @sqrt(@as(f32, @floatFromInt(size * size - from_middle * from_middle))) + 0.5);
            shift.* = start - @as(usize, @intCast(size - span));
        }
        // The top row is a single point, with no pixels.
        const first = shifts[0] orelse continue;
        try std.testing.expectEqual(first, shifts[1].?);
        try std.testing.expect(first % 2 == 0);
        if (first > 0) moved = true;
    }
    try std.testing.expect(moved);
}

test "the shake moves the ball's rows to the right" {
    const gpa = std.testing.allocator;
    const picture = try testing.picture(gpa);
    defer gpa.free(picture.rgb);
    const ball = try Ball.create(gpa, picture);
    defer ball.destroy(gpa);
    var random: Random = .{};
    ball.render(.{ 1, 1 }, 2, &random);
    // Some row starts right of where it would stand still, and none reaches past the image.
    var moved = false;
    for (0..size) |row| {
        const at = row * image_width * 4;
        const start = for (0..image_width) |x| {
            if (ball.pixels[at + x * 4 + 3] != 0) break x;
        } else continue;
        const centre: i32 = @intCast(row);
        const span = std.math.lossyCast(i32, @sqrt(@as(f32, @floatFromInt(radius * radius - (centre - radius) * (centre - radius)))) + 0.5);
        if (start > @as(usize, @intCast(radius - span))) moved = true;
    }
    try std.testing.expect(moved);
}

test percentages {
    // EQUALIZE POWER's point rounds to 34, 34 and 33, and the first 34 gives one back.
    const found = percentages(input_power.presets.get(.equal));
    try std.testing.expectEqual(33, found.get(.shields));
    try std.testing.expectEqual(34, found.get(.guns));
    try std.testing.expectEqual(33, found.get(.engines));
    // Nearly all of it to the engines.
    const engines = percentages(input_power.presets.get(.engines));
    try std.testing.expect(engines.get(.engines) > 90);
}

test "the bars' panes cut them to their shares" {
    // The guns' bar shows all of its 48 rows at a whole share and one at none.
    try std.testing.expectEqual(-14, bars.get(.guns).pane(1)[1]);
    try std.testing.expectEqual(34, bars.get(.guns).pane(0)[1]);
    // The engines' bar shows a row for each forty-eighth.
    try std.testing.expectEqual(-14 + 24, bars.get(.engines).pane(0.5)[3]);
    // The shields' bar empties from the left.
    try std.testing.expectEqual(40 + 54, bars.get(.shields).pane(0)[0]);
}
