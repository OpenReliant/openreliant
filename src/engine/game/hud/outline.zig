//! OpenReliant's outline fonts: TrueType and OpenType fonts drawn at the window's resolution in
//! place of the bitmap fonts they stand in for (`hud.Opened.outline`).
//!
//! The bitmap font stays the layout: each code's width and the line's height are its own, so that
//! every screen lays its text out as the game does, whatever the outline font. Over that layout,
//! each character is drawn from the outline font at as many pixels to the em as stand its capitals
//! as tall as the bitmap's, on the bitmap's baseline, and centred across where the bitmap's glyph
//! has its ink, Newtown's strokes made as heavy as the bitmap's (`Fit`). A code the outline font
//! has no glyph for keeps the bitmap's. Each size a
//! font is drawn at is rasterized into one picture (`Atlas`), each of whose pixels lands on one of
//! the window's, so that the text is as sharp as the window is fine.
//!
//! A mod's font named for a bitmap font stands in for it, `optfnt.ttf` or `optfnt.otf` for
//! `interface\optfnt.fnt` (`fnt.outlineName`). Without one, Newtown, which OpenReliant carries
//! (`deps/newtown`), stands in for the game's own Handel Gothic fonts: the menus', the ITAC's, the
//! display's and the loadout's tooltip's (`handel_gothic`).
//!
//! **Improvement:** the original draws its text in its bitmap fonts, made for a screen 640 by 480,
//! which OpenReliant magnifies to the window. `--bitmap-fonts` and `--original` draw them so.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fnt = @import("../../../formats/fnt.zig");
const srtexture = @import("../../surrender/surrenderlib/srtexture.zig");
const bigfile = @import("../bigfile.zig");
const hud = @import("../hud.zig");
const itac = @import("../itac.zig");
const language = @import("../language.zig");
const loadout = @import("../../interface/loadout/loadout.zig");

const log = std.log.scoped(.fonts);

/// Newtown Regular, by Roger White, from Roger's Fonts, in the public domain: the outline font
/// OpenReliant carries (`deps/newtown/README.md`).
pub const newtown = @embedFile("Newtown.ttf");

/// The game's fonts Newtown stands in for where no mod's font does, its Handel Gothic fonts: the
/// menus' and the ITAC's, drawn in one colour, and the display's own and the loadout's tooltip's,
/// drawn through palettes.
pub const handel_gothic = [_][]const u8{
    hud.large_menu_font,
    hud.small_menu_font,
    itac.large_font_name,
    itac.small_font_name,
    hud.Resources.font_name,
    loadout.title_font_name,
};

/// Whether Newtown stands in for the game's font `name` (`handel_gothic`), its folders and its case
/// aside, as the archives look a name up.
pub fn standsIn(name: []const u8) bool {
    const base = std.fs.path.basenameWindows(name);
    for (handel_gothic) |font| {
        if (std.ascii.eqlIgnoreCase(base, std.fs.path.basenameWindows(font))) return true;
    }
    return false;
}

pub const Error = Allocator.Error || error{Rasterizing};

/// A font a `Rasterizer` has opened.
pub const Face = *anyopaque;

/// What turns an outline font's glyphs into pixels: FreeType, in the platform
/// (`platform/fonts.zig`).
pub const Rasterizer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The face of the font file `bytes`, which outlive it; null where they hold no font it
        /// reads.
        open: *const fn (*anyopaque, []const u8) ?Face,
        close: *const fn (*anyopaque, Face) void,
        /// How far above the baseline the outline of `character` reaches, in ems; null where the
        /// face has no glyph for it.
        top: *const fn (*anyopaque, Face, u21) ?f32,
        /// `character` drawn at `em` pixels to the em, its strokes made the second `f32` of an em
        /// wider, or narrower below 0, its left and its baseline kept, its coverage made in the
        /// allocator; null where the face has no glyph for it.
        draw: *const fn (*anyopaque, Face, u21, f32, f32, Allocator) Error!?Bitmap,
    };

    pub fn open(rasterizer: Rasterizer, bytes: []const u8) ?Face {
        return rasterizer.vtable.open(rasterizer.context, bytes);
    }
    pub fn close(rasterizer: Rasterizer, face: Face) void {
        rasterizer.vtable.close(rasterizer.context, face);
    }
    pub fn top(rasterizer: Rasterizer, face: Face, character: u21) ?f32 {
        return rasterizer.vtable.top(rasterizer.context, face, character);
    }
    pub fn draw(rasterizer: Rasterizer, face: Face, character: u21, em: f32, weight: f32, gpa: Allocator) Error!?Bitmap {
        return rasterizer.vtable.draw(rasterizer.context, face, character, em, weight, gpa);
    }
};

/// A glyph drawn: its coverage row by row, from 0 for none to 255 for full, `width` by `height`,
/// its top `top` pixels above the baseline.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    top: i32,
    coverage: []u8,

    pub fn deinit(bitmap: Bitmap, gpa: Allocator) void {
        gpa.free(bitmap.coverage);
    }

    /// How much of the pixel `column` across and `row` down it covers, counting from a line of
    /// clear pixels before its first, which reaches the clear pixels round it too.
    fn coverAt(bitmap: Bitmap, column: usize, row: usize) f32 {
        if (column == 0 or row == 0 or column > bitmap.width or row > bitmap.height) return 0;
        return outline_cover[bitmap.coverage[(row - 1) * bitmap.width + column - 1]];
    }
};

/// The codes a font's glyphs are kept for, as `hud.Opened` caches their widths (`font_open`).
const codes = hud.cached_codes;

/// The capitals an outline font's size is fitted by, the first of them both fonts have: letters
/// that stand on the baseline and stop flat at the capitals' height.
const references = "HIEFLT";

/// The largest size an outline font is drawn at, in pixels to the em, which a window many times
/// the screens' size stops at.
const largest_em = 512;

/// How an outline font stands over the bitmap font it stands in for, in the bitmap's pixels.
pub const Fit = struct {
    /// The outline's pixels to the em for each of the bitmap's pixels: as many as stand its
    /// capitals, made as heavy as `weight` says, as tall as the bitmap's.
    em: f32,
    /// How far below the top of the line the bitmap's baseline is.
    baseline: f32,
    /// How much wider the outline's strokes are drawn than its own, in ems, narrower below 0: as
    /// much as makes its letters and digits ink as much as the bitmap's (`weighed`), so that the
    /// text is as heavy as the game's.
    weight: f32,
    /// How far right of its glyph's left edge the middle of each code's ink is across, in the
    /// bitmap; null for a code without ink.
    middles: [codes]?f32,

    /// The fit of `face` over `font`, whose bytes cover as `cover` says, by the height of the first
    /// of `references` both have, from the bitmap's ink and the outline's, its strokes as heavy as
    /// `heft` says; null where they have none of them in common.
    pub fn of(rasterizer: Rasterizer, face: Face, font: fnt.Font, cover: *const Cover, heft: Heft, gpa: Allocator) Allocator.Error!?Fit {
        for (references) |letter| {
            const glyph = font.glyph(letter) orelse continue;
            const rows = inkSpan(cover, glyph.pixels, glyph.width, .down) orelse continue;
            const top = rasterizer.top(face, letter) orelse continue;
            if (!(top > 0)) continue;
            const height = rows[1] - rows[0];
            const weight = switch (heft) {
                .own => 0,
                .bitmap => try weighed(rasterizer, face, font, cover, height, top, gpa),
            };
            var fit: Fit = .{ .em = emFor(height, top, weight), .baseline = rows[1], .weight = weight, .middles = @splat(null) };
            for (&fit.middles, 0..) |*middle, code| {
                const shown = font.glyph(code) orelse continue;
                const across = inkSpan(cover, shown.pixels, shown.width, .across) orelse continue;
                middle.* = (across[0] + across[1]) / 2;
            }
            return fit;
        }
        return null;
    }

    /// The size the outline font is drawn at for the bitmap font drawn `scale` times its own: its
    /// pixels to the em in `sixty_fourths`.
    fn size(fit: Fit, scale: f32) u32 {
        return @intFromFloat(std.math.clamp(@round(fit.em * scale * sixty_fourths), 1, largest_em * sixty_fourths));
    }
};

/// The parts of a pixel sizes are given in, as FreeType takes them.
pub const sixty_fourths = 64;

/// The letters and digits, which a font's weight and its ink are taken from.
pub const letters_and_digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// How many times the bitmap font's size an outline font's glyphs are drawn at to be weighed
/// (`weighed`), so that their edges are measured finely.
const weigh_scale = 8;

/// The most an outline font's strokes are made wider or narrower, in ems.
const largest_weight = 0.1;

/// The most times a weight is put right (`weighed`), and how small a change ends it, in ems.
const weigh_steps = 8;
const weigh_settled = 1e-4;

/// The outline's pixels to the em for each of the bitmap's, its strokes `weight` ems wider: as
/// many as stand its capitals, which reach `top` ems up, as tall as the bitmap's `height`. A stroke
/// made wider reaches that much higher.
fn emFor(height: f32, top: f32, weight: f32) f32 {
    return height / (top + weight);
}

/// How much wider the strokes of `face` must be, in ems, for its letters and digits, fitted to
/// capitals `height` of the bitmap's pixels tall that reach `top` ems up, to ink as much as those
/// of `font` do, its bytes covering as `cover` says. A stroke made wider takes in half of what it
/// gains on each side, so the ink they lack over half the length of their edges is how much wider
/// they must be; that is put right again from where it lands, the capitals kept as tall, until it
/// settles. Nothing where they can't be drawn.
fn weighed(rasterizer: Rasterizer, face: Face, font: fnt.Font, cover: *const Cover, height: f32, top: f32, gpa: Allocator) Allocator.Error!f32 {
    var weight: f32 = 0;
    for (0..weigh_steps) |_| {
        const size = emFor(height, top, weight) * weigh_scale;
        const ink = try inkOf(rasterizer, face, font, cover, size, weight, gpa) orelse return 0;
        if (ink.edges == 0) return weight;
        const change = 2 * ink.lacking / ink.edges / size;
        weight = std.math.clamp(weight + change, -largest_weight, largest_weight);
        if (@abs(change) < weigh_settled) break;
    }
    return weight;
}

/// The ink the letters and digits of `face`, drawn at `size` pixels to the em and `weight` ems
/// heavier, lack beside those of `font` drawn `weigh_scale` times as large, its bytes covering as
/// `cover` says, and the length of their edges, the sum of how steeply their coverage changes;
/// null where they can't be drawn.
fn inkOf(rasterizer: Rasterizer, face: Face, font: fnt.Font, cover: *const Cover, size: f32, weight: f32, gpa: Allocator) Allocator.Error!?struct { lacking: f32, edges: f32 } {
    var wanted: f32 = 0;
    var inked: f32 = 0;
    var edges: f32 = 0;
    for (letters_and_digits) |letter| {
        const glyph = font.glyph(letter) orelse continue;
        const drawn = rasterizer.draw(face, letter, size, weight, gpa) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.Rasterizing => return null,
        } orelse continue;
        defer drawn.deinit(gpa);
        for (glyph.pixels) |byte| wanted += cover[byte];
        // Over the glyph and a line of clear pixels round it, from each pixel to the next across
        // and down.
        for (0..drawn.height + 1) |row| for (0..drawn.width + 1) |column| {
            const here = drawn.coverAt(column, row);
            const across = drawn.coverAt(column + 1, row) - here;
            const down = drawn.coverAt(column, row + 1) - here;
            inked += here;
            edges += @sqrt(across * across + down * down);
        };
    }
    return .{ .lacking = wanted * weigh_scale * weigh_scale - inked, .edges = edges };
}

/// How heavy an outline font's strokes are drawn: as it draws them itself, as a mod's font is, or
/// as heavy as the bitmap font's, as Newtown is, which stands in for the game's own.
pub const Heft = enum { own, bitmap };

/// How much of a pixel each byte of a glyph covers, from 0 for none to 1 for full.
pub const Cover = [256]f32;

/// How a font drawn as levels of one colour covers (`hud.Opened.Paint.ramp`), as its glyphs are
/// drawn.
pub const level_cover: Cover = covers: {
    var cover: Cover = undefined;
    for (&cover, 0..) |*share, level| share.* = @as(f32, @floatFromInt(hud.rampLevel(level))) / 255;
    break :covers cover;
};

/// How a `Bitmap`'s coverage covers.
const outline_cover: Cover = covers: {
    var cover: Cover = undefined;
    for (&cover, 0..) |*share, level| share.* = @as(f32, @floatFromInt(level)) / 255;
    break :covers cover;
};

const Axis = enum { across, down };

/// Where the ink of `pixels`, `width` to a row, starts and ends `axis`, bytes covering as `cover`
/// says: from the first line of pixels with ink, as far into it as its fullest pixel falls short
/// of full, to the last, as far into it as its fullest pixel reaches; null where there is none. An
/// edge drawn half over a line of pixels so lies half way into it.
fn inkSpan(cover: *const Cover, pixels: []const u8, width: usize, axis: Axis) ?[2]f32 {
    if (width == 0) return null;
    const height = pixels.len / width;
    const lines, const along = switch (axis) {
        .across => .{ width, height },
        .down => .{ height, width },
    };
    var found: ?[2]f32 = null;
    for (0..lines) |line| {
        var fullest: f32 = 0;
        for (0..along) |at| {
            const index = switch (axis) {
                .across => at * width + line,
                .down => line * width + at,
            };
            fullest = @max(fullest, cover[pixels[index]]);
        }
        if (fullest == 0) continue;
        const start: f32 = @floatFromInt(line);
        // Worked out before `found` is written, which its own result would otherwise alias.
        const first = if (found) |was| was[0] else start + 1 - fullest;
        found = .{ first, start + fullest };
    }
    return found;
}

/// How a code is drawn from an outline font.
pub const Shown = union(enum) {
    /// Nothing: its glyph has no ink.
    blank,
    /// The bitmap's glyph: the outline font has none for it.
    bitmap,
    /// The part `u`, `v` of the atlas's picture `image` over the rectangle `edges` of the screen.
    quad: struct { image: *srtexture.Image, edges: hud.Clip, u: [2]f32, v: [2]f32 },
};

/// The clear pixels kept round each glyph of an atlas, so that none is drawn with a neighbour's
/// edge.
const gap = 1;

/// The narrowest an atlas is.
const least_width = 64;

/// An outline font's glyphs drawn at one size, packed into one picture, white and as opaque as
/// each pixel is covered, which the colour the text is drawn in tints.
pub const Atlas = struct {
    /// Pixels to the em, in 64ths (`Fit.size`).
    size: u32,
    image: srtexture.Image,
    /// The picture's pixels, which the image keeps, for the glyphs of another size to be drawn
    /// into.
    pixels: []u8,
    glyphs: [codes]Glyph,
    /// When it was last drawn from, in its outline's draws, so that the least lately drawn gives
    /// way.
    drawn: u64 = 0,

    pub const Glyph = union(enum) {
        /// The bitmap's glyph has no ink, or the outline's is empty: nothing is drawn.
        blank,
        /// The outline font has no glyph for it: the bitmap's is drawn.
        bitmap,
        placed: Placed,
    };

    /// Where a glyph's picture lies in the atlas and how large it is, how far above the baseline
    /// its top stands, and how far right of its left edge the middle of its ink is.
    pub const Placed = struct { at: [2]u32, width: u32, height: u32, top: i32, middle: f32 };

    fn deinit(atlas: *Atlas, gpa: Allocator) void {
        atlas.image.deinit(gpa);
    }
};

/// How many sizes of its glyphs an outline font keeps at once, more than a frame draws it at: the
/// front end draws its small font at the size of its screens and at the display's, for the version
/// (`hud.drawVersion`).
const kept_sizes = 4;

/// An outline font standing in for one bitmap font, and its glyphs at the sizes lately drawn.
pub const Outline = struct {
    /// What its atlases are made in, whoever draws from it: kept for the run by `Outlines`, it
    /// outlives what any one screen draws with.
    gpa: Allocator,
    rasterizer: Rasterizer,
    face: Face,
    /// The mod's font file `face` reads, which it keeps; none for Newtown, which is built in, and
    /// whose face `Outlines` keeps.
    file: ?[]u8,
    fit: Fit,
    atlases: [kept_sizes]?Atlas = @splat(null),
    /// The pictures of atlases that grew out of them, which the device may still be sending up with
    /// the frame drawn from them, kept until the end.
    retired: std.ArrayList(srtexture.Image) = .empty,
    /// Its draws counted, which tell which atlas was drawn from least lately.
    draws: u64 = 0,
    /// Set once its glyphs can't be drawn, which leaves the bitmap's.
    failed: bool = false,

    pub fn deinit(outline: *Outline) void {
        const gpa = outline.gpa;
        for (&outline.atlases) |*held| if (held.*) |*atlas| atlas.deinit(gpa);
        for (outline.retired.items) |image| image.deinit(gpa);
        outline.retired.deinit(gpa);
        if (outline.file) |file| {
            outline.rasterizer.close(outline.face);
            gpa.free(file);
        }
    }

    /// Its glyphs for the bitmap font drawn `scale` times its size, drawn the first time they are
    /// asked for at that size, in place of those drawn least lately where it keeps as many sizes as
    /// it can; null once they can't be drawn, which the log says.
    pub fn at(outline: *Outline, scale: f32) Allocator.Error!?Sized {
        if (outline.failed) return null;
        outline.draws += 1;
        const size = outline.fit.size(scale);
        for (&outline.atlases) |*held| if (held.*) |*atlas| if (atlas.size == size) {
            atlas.drawn = outline.draws;
            return .{ .outline = outline, .atlas = atlas };
        };
        // An empty place, else the atlas drawn from least lately.
        var chosen = &outline.atlases[0];
        for (&outline.atlases) |*held| {
            const atlas = if (held.*) |*atlas| atlas else {
                chosen = held;
                break;
            };
            if (atlas.drawn < chosen.*.?.drawn) chosen = held;
        }
        render(outline, chosen, outline.gpa, size) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.Rasterizing => {
                log.warn("an outline font's glyphs can't be drawn: the bitmap font's are", .{});
                outline.failed = true;
                return null;
            },
        };
        const atlas = &chosen.*.?;
        atlas.drawn = outline.draws;
        return .{ .outline = outline, .atlas = atlas };
    }
};

/// An outline font's glyphs at the size a line is drawn at.
pub const Sized = struct {
    outline: *const Outline,
    atlas: *Atlas,

    /// How code `code` is drawn, its glyph's place on the line starting `left` across and the
    /// line's top `top` down, the bitmap font drawn `scale` times its size: its ink centred across
    /// where the bitmap's is, on the bitmap's baseline, each of its picture's pixels on one of the
    /// window's.
    pub fn shown(sized: Sized, code: u8, left: f32, top: f32, scale: f32) Shown {
        const atlas = sized.atlas;
        const fit = &sized.outline.fit;
        const glyph = switch (atlas.glyphs[code]) {
            .blank => return .blank,
            .bitmap => return .bitmap,
            .placed => |placed| placed,
        };
        const middle = fit.middles[code] orelse return .blank;
        const x = @round(left + middle * scale - glyph.middle);
        const y = @round(top + fit.baseline * scale) - @as(f32, @floatFromInt(glyph.top));
        const width: f32 = @floatFromInt(glyph.width);
        const height: f32 = @floatFromInt(glyph.height);
        const across: f32 = @floatFromInt(atlas.image.width());
        const down: f32 = @floatFromInt(atlas.image.height());
        const from: [2]f32 = .{ @floatFromInt(glyph.at[0]), @floatFromInt(glyph.at[1]) };
        // Direct3D 7's pixels have their centres on whole coordinates, so the rectangle starts half
        // a pixel before its first pixel's centre.
        return .{ .quad = .{
            .image = &atlas.image,
            .edges = .{ .left = x - 0.5, .top = y - 0.5, .right = x + width - 0.5, .bottom = y + height - 0.5 },
            .u = .{ from[0] / across, (from[0] + width) / across },
            .v = .{ from[1] / down, (from[1] + height) / down },
        } };
    }
};

/// Draws the glyphs `outline`'s fit has ink for at `size` into the atlas in `slot`, which it holds:
/// into its picture where they fit, which then goes up to the GPU again, else into a new one.
///
/// The device keeps a texture for the rest of the run, so an atlas's picture is made with both its
/// sides powers of two, which the glyphs of a size near its own fit in again as the window changes
/// size, and only a size too large for it takes a new one. The atlas given way to was drawn from
/// least lately, in an earlier frame while a frame draws no more sizes than are kept.
fn render(outline: *Outline, slot: *?Atlas, gpa: Allocator, size: u32) Error!void {
    const rasterizer = outline.rasterizer;
    const face = outline.face;
    const fit = &outline.fit;
    const em = @as(f32, @floatFromInt(size)) / sixty_fourths;
    var drawn: [codes]?Bitmap = @splat(null);
    defer for (drawn) |held| if (held) |bitmap| bitmap.deinit(gpa);
    var glyphs: [codes]Atlas.Glyph = @splat(.blank);
    var area: usize = 0;
    var widest: u32 = 0;
    for (fit.middles, &drawn, &glyphs, 0..) |middle, *bitmap, *glyph, code| {
        if (middle == null) continue;
        const made = try rasterizer.draw(face, language.toUnicode(@intCast(code)), em, fit.weight, gpa) orelse {
            glyph.* = .bitmap;
            continue;
        };
        if (made.width == 0 or made.height == 0) {
            made.deinit(gpa);
            continue;
        }
        bitmap.* = made;
        area += @as(usize, made.width + gap) * (made.height + gap);
        widest = @max(widest, made.width);
    }

    var places: [codes][2]u32 = undefined;
    const kept: ?*Atlas = if (slot.*) |*atlas| atlas else null;
    const width: u32, const height: u32 = size: {
        if (kept) |atlas| {
            const across = atlas.image.width();
            if (widest + 2 * gap <= across and pack(&drawn, across, &places) <= atlas.image.height()) {
                break :size .{ across, atlas.image.height() };
            }
        }
        const square: u32 = @intCast(std.math.sqrt(area));
        const across = std.math.ceilPowerOfTwoAssert(u32, @max(least_width, widest + 2 * gap, square));
        break :size .{ across, std.math.ceilPowerOfTwoAssert(u32, pack(&drawn, across, &places)) };
    };

    const same = if (kept) |atlas| atlas.image.width() == width and atlas.image.height() == height else false;
    const pixels = if (same) kept.?.pixels else try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer if (!same) gpa.free(pixels);
    for (0..@as(usize, width) * height) |pixel| pixels[pixel * 4 ..][0..4].* = .{ 0xFF, 0xFF, 0xFF, 0 };
    for (drawn, places, &glyphs) |held, place, *glyph| {
        const bitmap = held orelse continue;
        for (0..bitmap.height) |row| {
            const into = (@as(usize, place[1]) + row) * width + place[0];
            for (bitmap.coverage[row * bitmap.width ..][0..bitmap.width], 0..) |level, column| pixels[(into + column) * 4 + 3] = level;
        }
        const ink = inkSpan(&outline_cover, bitmap.coverage, bitmap.width, .across) orelse [2]f32{ 0, @floatFromInt(bitmap.width) };
        glyph.* = .{ .placed = .{ .at = place, .width = bitmap.width, .height = bitmap.height, .top = bitmap.top, .middle = (ink[0] + ink[1]) / 2 } };
    }

    if (same) {
        const atlas = kept.?;
        atlas.image.changed = true;
        atlas.size = size;
        atlas.glyphs = glyphs;
        return;
    }
    if (kept != null) try outline.retired.ensureUnusedCapacity(gpa, 1);
    const image: srtexture.Image = try .single(gpa, width, height, pixels);
    if (kept) |atlas| outline.retired.appendAssumeCapacity(atlas.image);
    slot.* = .{ .size = size, .image = image, .pixels = pixels, .glyphs = glyphs };
}

/// Lays the glyphs out in rows left to right across `width`, `gap` apart and from the edges, each
/// row as tall as its tallest: where each lies, into `places`, and how tall the rows come to.
fn pack(drawn: *const [codes]?Bitmap, width: u32, places: *[codes][2]u32) u32 {
    var x: u32 = gap;
    var y: u32 = gap;
    var row: u32 = 0;
    for (drawn, places) |held, *place| {
        const bitmap = held orelse continue;
        if (x + bitmap.width + gap > width) {
            y += row + gap;
            x = gap;
            row = 0;
        }
        place.* = .{ x, y };
        x += bitmap.width + gap;
        row = @max(row, bitmap.height);
    }
    return y + row + gap;
}

/// The outline fonts that stand in for the bitmap fonts, each made as its bitmap font first opens
/// and kept for the run, so that their glyphs are drawn once for every screen that writes in them.
pub const Outlines = struct {
    gpa: Allocator,
    /// What draws their glyphs; none leaves every font its bitmap (`--bitmap-fonts`).
    rasterizer: ?Rasterizer,
    /// The mods, whose fonts stand in for the game's.
    mods: *const bigfile.Mods,
    /// Newtown's face, opened as the first font it stands in for opens.
    built_in: ?Face = null,
    fonts: std.ArrayList(Font) = .empty,

    /// A bitmap font opened, by its name as the archives look it up, and the outline that stands in
    /// for it; none where it keeps its bitmap.
    const Font = struct { name: []u8, outline: ?*Outline };

    pub fn init(gpa: Allocator, rasterizer: ?Rasterizer, mods: *const bigfile.Mods) Outlines {
        return .{ .gpa = gpa, .rasterizer = rasterizer, .mods = mods };
    }

    pub fn deinit(outlines: *Outlines) void {
        const gpa = outlines.gpa;
        for (outlines.fonts.items) |font| {
            if (font.outline) |outline| {
                outline.deinit();
                gpa.destroy(outline);
            }
            gpa.free(font.name);
        }
        outlines.fonts.deinit(gpa);
        if (outlines.built_in) |face| outlines.rasterizer.?.close(face);
        outlines.* = undefined;
    }

    /// The outline that stands in for the bitmap font `name`, read as `font`, whose bytes cover as
    /// `cover` says: a mod's font of its name, else Newtown where it is one of the game's own
    /// Handel Gothic fonts; null where it keeps its bitmap. The log says which stands in.
    pub fn of(outlines: *Outlines, name: []const u8, font: fnt.Font, cover: *const Cover) Allocator.Error!?*Outline {
        var buffer: [bigfile.member_name_room]u8 = undefined;
        const member = bigfile.memberName(&buffer, name);
        for (outlines.fonts.items) |known| {
            if (std.ascii.eqlIgnoreCase(known.name, member)) return known.outline;
        }
        const gpa = outlines.gpa;
        try outlines.fonts.ensureUnusedCapacity(gpa, 1);
        const kept_name = try gpa.dupe(u8, member);
        errdefer gpa.free(kept_name);
        const outline = try outlines.make(member, font, cover);
        outlines.fonts.appendAssumeCapacity(.{ .name = kept_name, .outline = outline });
        return outline;
    }

    /// The outline that stands in for the bitmap font `member`, read as `font`, whose bytes cover
    /// as `cover` says: a mod's font of its name, the first of `fnt.outline_extensions` that reads,
    /// else Newtown where it stands in for the game's own font; null where none does.
    fn make(outlines: *Outlines, member: []const u8, font: fnt.Font, cover: *const Cover) Allocator.Error!?*Outline {
        const rasterizer = outlines.rasterizer orelse return null;
        const gpa = outlines.gpa;
        for (fnt.outline_extensions) |extension| {
            var buffer: [bigfile.member_name_room]u8 = undefined;
            const name = fnt.outlineName(&buffer, member, extension) catch continue;
            const file = outlines.mods.readFile(gpa, name) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => {
                    log.warn("{s} is left out: {s}", .{ name, @errorName(err) });
                    continue;
                },
            } orelse continue;
            const face = rasterizer.open(file) orelse {
                log.warn("{s} is left out: it can't be read as a font", .{name});
                gpa.free(file);
                continue;
            };
            const made = outlines.fitted(rasterizer, face, file, font, cover, .own, name) catch |err| {
                rasterizer.close(face);
                gpa.free(file);
                return err;
            };
            if (made) |outline| {
                log.info("{s} is drawn in {s}", .{ member, name });
                return outline;
            }
            rasterizer.close(face);
            gpa.free(file);
        }
        // The game's own font, which Newtown stands in for.
        if (outlines.mods.has(member) or !standsIn(member)) return null;
        const face = outlines.built_in orelse rasterizer.open(newtown) orelse {
            log.warn("Newtown is left out: it can't be read as a font", .{});
            return null;
        };
        outlines.built_in = face;
        const outline = try outlines.fitted(rasterizer, face, null, font, cover, .bitmap, "Newtown") orelse return null;
        log.info("{s} is drawn in Newtown, its strokes {d:.3} of an em {s}", .{ member, @abs(outline.fit.weight), if (outline.fit.weight < 0) "narrower" else "wider" });
        return outline;
    }

    /// The outline of `face`, which reads `file`, over the bitmap font `font`; null where they
    /// share none of the capitals it is fitted by, which the log says.
    fn fitted(outlines: *Outlines, rasterizer: Rasterizer, face: Face, file: ?[]u8, font: fnt.Font, cover: *const Cover, heft: Heft, name: []const u8) Allocator.Error!?*Outline {
        const fit = try Fit.of(rasterizer, face, font, cover, heft, outlines.gpa) orelse {
            log.warn("{s} is left out: it and the bitmap font share none of the capitals {s}", .{ name, references });
            return null;
        };
        const outline = try outlines.gpa.create(Outline);
        outline.* = .{ .gpa = outlines.gpa, .rasterizer = rasterizer, .face = face, .file = file, .fit = fit };
        return outline;
    }
};

pub const testing = struct {
    /// A rasterizer for the tests, which draws boxes: it opens any file but one that starts `not`,
    /// the face being the file's first byte, and has a glyph for every character below `0x80` but
    /// `#`, a box `wide` of an em wide and as tall as `capitals` of an em, fully covered, on the
    /// baseline: by default as long across as `font`'s glyphs are for their height, so that it
    /// weighs the same.
    pub const Boxes = struct {
        /// The faces open.
        open_faces: usize = 0,
        wide: f32 = 0.6,

        pub const capitals = 0.75;

        pub fn rasterizer(boxes: *Boxes) Rasterizer {
            return .{ .context = boxes, .vtable = &.{ .open = open, .close = close, .top = top, .draw = draw } };
        }

        fn of(context: *anyopaque) *Boxes {
            return @ptrCast(@alignCast(context));
        }

        fn open(context: *anyopaque, bytes: []const u8) ?Face {
            if (bytes.len == 0 or std.mem.startsWith(u8, bytes, "not")) return null;
            of(context).open_faces += 1;
            return @ptrCast(@constCast(bytes.ptr));
        }

        fn close(context: *anyopaque, _: Face) void {
            of(context).open_faces -= 1;
        }

        fn has(character: u21) bool {
            return character < 0x80 and character != '#';
        }

        fn top(_: *anyopaque, _: Face, character: u21) ?f32 {
            return if (has(character)) capitals else null;
        }

        fn draw(context: *anyopaque, _: Face, character: u21, em: f32, weight: f32, gpa: Allocator) Error!?Bitmap {
            if (!has(character)) return null;
            // Made heavier, a box grows to the right and up, as FreeType's glyphs do.
            const width: u32 = @intFromFloat(@max(0, @round(em * of(context).wide + weight * em)));
            const height: u32 = @intFromFloat(@max(0, @round(em * capitals + weight * em)));
            const coverage = try gpa.alloc(u8, @as(usize, width) * height);
            @memset(coverage, 0xFF);
            return .{ .width = width, .height = height, .top = @intCast(height), .coverage = coverage };
        }
    };

    /// A bitmap font eight rows tall for the tests, its codes below `0x80`: `A`, `H` and `#` each a
    /// box six pixels wide, inked from column 1 to 4 and from row 2 to 6, and the space six pixels
    /// of nothing.
    pub const font = fontInked(.{ 15, 15, 15 }, null);

    /// `font`, its boxes `#`, `A` and `H` inked with the bytes `inks`, and `palette` after them
    /// where there is one.
    pub fn fontInked(comptime inks: [3]u8, comptime palette: ?[fnt.palette_size]u8) []const u8 {
        const height = 8;
        const width = 6;
        const blank = std.mem.toBytes(@as(u32, width)) ++ @as([width * height]u8, @splat(0));
        var glyphs: []const u8 = &.{};
        for (inks) |ink| {
            var box: [width * height]u8 = @splat(0);
            for (2..7) |row| @memset(box[row * width + 1 ..][0..4], ink);
            glyphs = glyphs ++ std.mem.toBytes(@as(u32, width)) ++ box;
        }
        const count = 0x80;
        const first = fnt.header_size + count * 4;
        var table: [count]u32 = @splat(0);
        table[' '] = first;
        for ("#AH", 0..) |code, at| table[code] = first + blank.len + at * (4 + width * height);
        const header: fnt.Header = .{ .version = "2.\x00\x00".*, .count = count, .height = height, ._unknown_0c = 0 };
        const bytes = std.mem.toBytes(header) ++ std.mem.sliceAsBytes(&table) ++ blank ++ glyphs;
        return if (palette) |colours| bytes ++ colours else bytes;
    }
};

test standsIn {
    try std.testing.expect(standsIn("interface\\optfnt.fnt"));
    try std.testing.expect(standsIn("SMLFNT2.FNT"));
    try std.testing.expect(standsIn("inter\\itac\\itacbig.fnt"));
    try std.testing.expect(standsIn("blufont.fnt"));
    try std.testing.expect(!standsIn("font_01.fnt"));
}

test inkSpan {
    // Ink from the middle of row 1, half covered, to the end of row 3, its columns 1 and 2.
    const pixels = [_]u8{
        0, 0,    0,    0,
        0, 0x80, 0x80, 0,
        0, 0xFF, 0xFF, 0,
        0, 0xFF, 0xFF, 0,
    };
    const down = inkSpan(&outline_cover, &pixels, 4, .down).?;
    try std.testing.expectApproxEqAbs(1.498, down[0], 1e-3);
    try std.testing.expectEqual(4, down[1]);
    try std.testing.expectEqual([2]f32{ 1, 3 }, inkSpan(&outline_cover, &pixels, 4, .across).?);
    try std.testing.expectEqual(null, inkSpan(&outline_cover, &@as([4]u8, @splat(0)), 2, .down));
    // A bitmap font's levels: 15 full, and past it clear.
    try std.testing.expectEqual([2]f32{ 0, 1 }, inkSpan(&level_cover, &.{ 15, 16 }, 2, .across).?);
}

test Fit {
    const gpa = std.testing.allocator;
    var boxes: testing.Boxes = .{};
    const rasterizer = boxes.rasterizer();
    const font: fnt.Font = try .parse(testing.font);
    // The H's ink stands five rows tall and the outline's capitals three quarters of an em: an em
    // of six and two thirds of the bitmap's pixels, on the bitmap's baseline, under row 6.
    const fit = (try Fit.of(rasterizer, rasterizer.open("face").?, font, &level_cover, .bitmap, gpa)).?;
    try std.testing.expectApproxEqAbs(5.0 / 0.75, fit.em, 1e-5);
    // Its boxes ink as much as the bitmap's: they are drawn as heavy as they are.
    try std.testing.expectApproxEqAbs(0, fit.weight, 1e-3);
    try std.testing.expectEqual(7, fit.baseline);
    try std.testing.expectEqual(3, fit.middles['H'].?);
    try std.testing.expectEqual(null, fit.middles[' ']);
    try std.testing.expectEqual(null, fit.middles['B']);
    // Three times the size, an em of twenty pixels, in 64ths.
    try std.testing.expectEqual(20 * sixty_fourths, fit.size(3));
    // A font without any of the capitals it is fitted by has no fit.
    try std.testing.expectEqual(null, try Fit.of(rasterizer, rasterizer.open("face").?, try .parse(comptime fnt.testing.font(false)), &level_cover, .bitmap, gpa));
}

test weighed {
    const gpa = std.testing.allocator;
    // Boxes a hundredth of an em wider for their height than the bitmap's ink, which covers four
    // by five of its pixels: drawn lighter, at eight times the size they ink as much as it does,
    // their capitals as tall.
    var boxes: testing.Boxes = .{ .wide = 0.61 };
    const rasterizer = boxes.rasterizer();
    const face = rasterizer.open("face").?;
    const fit = (try Fit.of(rasterizer, face, try .parse(testing.font), &level_cover, .bitmap, gpa)).?;
    try std.testing.expect(fit.weight < 0);
    const drawn = (try rasterizer.draw(face, 'H', fit.em * weigh_scale, fit.weight, gpa)).?;
    defer drawn.deinit(gpa);
    try std.testing.expectEqual(4 * 5 * weigh_scale * weigh_scale, drawn.width * drawn.height);
    try std.testing.expectEqual(5 * weigh_scale, drawn.height);
}

test Outline {
    const gpa = std.testing.allocator;
    var boxes: testing.Boxes = .{};
    const rasterizer = boxes.rasterizer();
    const font: fnt.Font = try .parse(testing.font);
    var outline: Outline = .{ .gpa = gpa, .rasterizer = rasterizer, .face = rasterizer.open("face").?, .file = null, .fit = (try Fit.of(rasterizer, rasterizer.open("face").?, font, &level_cover, .bitmap, gpa)).? };
    defer outline.deinit();

    // At three times the size, the outline's glyphs are boxes twelve pixels wide and fifteen tall,
    // A's and H's, in a picture 64 by 32.
    const sized = (try outline.at(3)).?;
    const atlas = sized.atlas;
    try std.testing.expectEqual([2]u32{ 64, 32 }, [2]u32{ atlas.image.width(), atlas.image.height() });
    try std.testing.expectEqual(Atlas.Placed{ .at = .{ 14, 1 }, .width = 12, .height = 15, .top = 15, .middle = 6 }, atlas.glyphs['H'].placed);
    try std.testing.expectEqual(0xFF, atlas.pixels[((1 + 7) * 64 + 14 + 4) * 4 + 3]);
    try std.testing.expectEqual(0, atlas.pixels[((1 + 7) * 64 + 13) * 4 + 3]);
    // H, its place starting 30 across on a line whose top is 100 down: its ink centred on the
    // bitmap's, 9 into its place, and standing on the baseline, 21 down, each of its pixels on one
    // of the window's.
    const h = sized.shown('H', 30, 100, 3).quad;
    try std.testing.expectEqual(&atlas.image, h.image);
    try std.testing.expectEqual(hud.Clip{ .left = 32.5, .top = 105.5, .right = 44.5, .bottom = 120.5 }, h.edges);
    try std.testing.expectEqual([2]f32{ 14.0 / 64.0, 26.0 / 64.0 }, h.u);
    try std.testing.expectEqual([2]f32{ 1.0 / 32.0, 16.0 / 32.0 }, h.v);
    // The space has no ink, the outline font no `#`, and the font no B.
    try std.testing.expectEqual(.blank, sized.shown(' ', 0, 0, 3));
    try std.testing.expectEqual(.bitmap, sized.shown('#', 0, 0, 3));
    try std.testing.expectEqual(.blank, sized.shown('B', 0, 0, 3));

    // The same size draws from the same atlas, and others each from one of their own.
    try std.testing.expectEqual(atlas, (try outline.at(3)).?.atlas);
    for ([_]f32{ 3.1, 3.2, 3.3 }) |scale| try std.testing.expect((try outline.at(scale)).?.atlas != atlas);
    // A fifth size takes the place of the atlas drawn from least lately, in its picture where it
    // fits, which goes up to the GPU again.
    const pixels = atlas.pixels.ptr;
    try std.testing.expectEqual(atlas, (try outline.at(3.4)).?.atlas);
    try std.testing.expectEqual(pixels, atlas.pixels.ptr);
    try std.testing.expect(atlas.image.changed);
    try std.testing.expectEqual(0, outline.retired.items.len);
    // One too large for it takes a new picture, the old one kept for the frame that drew from it.
    const large = (try outline.at(20)).?.atlas;
    try std.testing.expect(large.image.width() > 64);
    try std.testing.expectEqual(1, outline.retired.items.len);
}

test Outlines {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A mod with an outline font for `optfnt.fnt`, a bitmap font of its own for `smlfnt2.fnt`, and
    // an outline font for `itacbig.fnt` that doesn't read.
    try tmp.dir.createDirPath(io, "mods/a");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/optfnt.ttf", .data = "a's font" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/smlfnt2.fnt", .data = "a's bitmap font" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/itacbig.otf", .data = "not a font" });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir);
    defer mods.close(gpa);
    var boxes: testing.Boxes = .{};
    const font: fnt.Font = try .parse(testing.font);
    {
        var outlines: Outlines = .init(gpa, boxes.rasterizer(), &mods);
        defer outlines.deinit();
        // The mod's font stands in for `optfnt.fnt`, once for every time it opens.
        const optfnt = (try outlines.of(hud.large_menu_font, font, &level_cover)).?;
        try std.testing.expectEqualStrings("a's font", optfnt.file.?);
        // A mod's font is drawn as heavy as it is.
        try std.testing.expectEqual(0, optfnt.fit.weight);
        try std.testing.expectEqual(optfnt, (try outlines.of("OPTFNT.FNT", font, &level_cover)).?);
        // The mod's own bitmap font keeps its bitmap; Newtown stands in for the game's ITAC font,
        // the mod's that doesn't read left out, and for the display's, from the face it opened
        // once; and nothing for a font that isn't Handel Gothic.
        try std.testing.expectEqual(null, try outlines.of(hud.small_menu_font, font, &level_cover));
        const itacbig = (try outlines.of("inter\\itac\\itacbig.fnt", font, &level_cover)).?;
        try std.testing.expectEqual(null, itacbig.file);
        try std.testing.expectEqual(@as(Face, @ptrCast(@constCast(newtown.ptr))), itacbig.face);
        const blufont = (try outlines.of(hud.Resources.font_name, font, &level_cover)).?;
        try std.testing.expectEqual(itacbig.face, blufont.face);
        try std.testing.expectEqual(null, try outlines.of("font_01.fnt", font, &level_cover));
        try std.testing.expectEqual(2, boxes.open_faces);
    }
    try std.testing.expectEqual(0, boxes.open_faces);
    // Without a rasterizer, every font keeps its bitmap.
    var bitmaps: Outlines = .init(gpa, null, &mods);
    defer bitmaps.deinit();
    try std.testing.expectEqual(null, try bitmaps.of(hud.large_menu_font, font, &level_cover));
}
