//! OpenReliant's outline fonts: TrueType and OpenType fonts drawn at the window's resolution
//! instead of the bitmap fonts they replace (`hud.Opened.outline`).
//!
//! The text keeps the bitmap font's layout: each character's width and the line height come from
//! the bitmap font, so every screen lays out its text like the original, whatever the outline font.
//! On that layout, each character is drawn from the outline font at the size that makes its
//! capitals as tall as the bitmap font's, on the bitmap font's baseline, and centred on the inked
//! part of the bitmap glyph. Newtown's strokes are made as heavy as the bitmap font's (`Fit`). A
//! character the outline font has no glyph for keeps the bitmap glyph. Each size of a font is
//! rendered into one texture (`Atlas`), with its pixels aligned to the window's, so the text is as
//! sharp as the window's resolution allows.
//!
//! A font in a mod with the same name as a bitmap font replaces it: `optfnt.ttf` or `optfnt.otf`
//! for `interface\optfnt.fnt` (`fnt.outlineName`). Otherwise Newtown, which is built into
//! OpenReliant (`deps/newtown`), replaces the original Handel Gothic fonts: the menu, ITAC, flight
//! display and loadout tooltip fonts (`handel_gothic`).
//!
//! **Improvement:** the original draws its text with bitmap fonts made for a 640x480 screen, which
//! OpenReliant scales up to the window. `--bitmap-fonts` and `--original` draw them that way.

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
/// built into OpenReliant (`deps/newtown/README.md`).
pub const newtown = @embedFile("Newtown.ttf");

/// The game's Handel Gothic fonts, which Newtown replaces unless a mod has a font for them: the
/// menu and ITAC fonts, drawn in one colour, and the flight display and loadout tooltip fonts,
/// drawn through palettes.
pub const handel_gothic = [_][]const u8{
    hud.large_menu_font,
    hud.small_menu_font,
    itac.large_font_name,
    itac.small_font_name,
    hud.Resources.font_name,
    loadout.title_font_name,
};

/// Whether Newtown replaces the game's font `name` (`handel_gothic`), ignoring folders and case, as
/// the archives look up names.
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

/// Renders an outline font's glyphs into pixels: FreeType, in the platform layer
/// (`platform/fonts.zig`).
pub const Rasterizer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Opens the font file `bytes`, which must outlive the face; null if it can't read the
        /// font.
        open: *const fn (*anyopaque, []const u8) ?Face,
        close: *const fn (*anyopaque, Face) void,
        /// How far above the baseline the outline of `character` reaches, in ems; null if the face
        /// has no glyph for it.
        top: *const fn (*anyopaque, Face, u21) ?f32,
        /// Renders `character` at `em` pixels per em, with its strokes made wider by the second
        /// `f32`, in ems (narrower if negative), keeping its left edge and baseline. The coverage
        /// is allocated with the allocator. Null if the face has no glyph for it.
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

/// A rendered glyph: its coverage, row by row, from 0 for none to 255 for full, `width` by `height`
/// pixels, with its top `top` pixels above the baseline.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    top: i32,
    coverage: []u8,

    pub fn deinit(bitmap: Bitmap, gpa: Allocator) void {
        gpa.free(bitmap.coverage);
    }

    /// The coverage of the pixel at `column` and `row`, counting from 1, so that column and row 0,
    /// and anything past the glyph's size, are the clear pixels around it.
    fn coverAt(bitmap: Bitmap, column: usize, row: usize) f32 {
        if (column == 0 or row == 0 or column > bitmap.width or row > bitmap.height) return 0;
        return outline_cover[bitmap.coverage[(row - 1) * bitmap.width + column - 1]];
    }
};

/// The number of character codes whose glyphs are kept, matching the widths `hud.Opened` caches
/// (`font_open`).
const codes = hud.cached_codes;

/// The capitals used to fit an outline font's size, taking the first that both fonts have: letters
/// that sit on the baseline and have a flat top at the capital height.
const references = "HIEFLT";

/// The largest size an outline font is drawn at, in pixels per em, a limit for windows many times
/// the size of the original screens.
const largest_em = 512;

/// How an outline font is placed over the bitmap font it replaces, in the bitmap font's pixels.
pub const Fit = struct {
    /// The outline font's pixels per em for each bitmap pixel: the size that makes its capitals,
    /// with the strokes widened by `weight`, as tall as the bitmap font's.
    em: f32,
    /// The distance from the top of the line down to the bitmap font's baseline.
    baseline: f32,
    /// How much wider the outline font's strokes are drawn than normal, in ems (narrower if
    /// negative): enough to make its letters and digits cover as many pixels as the bitmap font's
    /// (`weighed`), so the text is as heavy as the original.
    weight: f32,
    /// For each character, the horizontal middle of its ink in the bitmap glyph, from the glyph's
    /// left edge; null for a character without ink.
    middles: [codes]?f32,

    /// Fits `face` over `font`, whose bytes cover pixels as `cover` says, by the height of the
    /// first of `references` that both fonts have, measured from the bitmap's ink and the outline,
    /// with strokes as heavy as `heft` says. Null if they have none of those letters in common.
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

    /// The size to draw the outline font at when the bitmap font is drawn at `scale` times its
    /// size: pixels per em, in `sixty_fourths`.
    fn size(fit: Fit, scale: f32) u32 {
        return @intFromFloat(std.math.clamp(@round(fit.em * scale * sixty_fourths), 1, largest_em * sixty_fourths));
    }
};

/// Sizes are given in 64ths of a pixel, as FreeType takes them.
pub const sixty_fourths = 64;

/// The letters and digits used to measure a font's weight and ink.
pub const letters_and_digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// How many times the bitmap font's size the outline font's glyphs are drawn at for weighing
/// (`weighed`), so their edges are measured precisely.
const weigh_scale = 8;

/// The most an outline font's strokes can be made wider or narrower, in ems.
const largest_weight = 0.1;

/// The maximum number of weight adjustments (`weighed`), and the change, in ems, small enough to
/// stop at.
const weigh_steps = 8;
const weigh_settled = 1e-4;

/// The outline font's pixels per em for each bitmap pixel, with its strokes `weight` ems wider: the
/// size that makes its capitals, which reach `top` ems above the baseline, as tall as the bitmap
/// font's `height`. Widening a stroke also makes it that much taller.
fn emFor(height: f32, top: f32, weight: f32) f32 {
    return height / (top + weight);
}

/// How much wider, in ems, the strokes of `face` must be for its letters and digits to cover as
/// many pixels as those of `font`, whose bytes cover pixels as `cover` says. The capitals are
/// fitted to `height` bitmap pixels and reach `top` ems above the baseline. Widening a stroke adds
/// half the change on each side, so the first estimate is the missing ink divided by half the
/// length of the glyphs' edges. The estimate is repeated from the new weight, keeping the capitals
/// the same height, until it settles. Returns 0 if the glyphs can't be drawn.
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

/// How much less ink the letters and digits of `face` have, drawn at `size` pixels per em and
/// `weight` ems heavier, than those of `font` drawn `weigh_scale` times as large, with its bytes
/// covering pixels as `cover` says; and the length of their edges, the sum of how steeply their
/// coverage changes. Null if they can't be drawn.
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
        // Over the glyph and a border of clear pixels, from each pixel to the next one across and
        // down.
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

/// How heavy an outline font's strokes are drawn: at the font's normal weight, for a mod's font,
/// or as heavy as the bitmap font's, for Newtown, which replaces the original fonts.
pub const Heft = enum { own, bitmap };

/// How much of a pixel each byte of a glyph covers, from 0 for none to 1 for full.
pub const Cover = [256]f32;

/// The coverage of each byte in a font drawn as levels of one colour (`hud.Opened.Paint.ramp`),
/// as its glyphs are drawn.
pub const level_cover: Cover = covers: {
    var cover: Cover = undefined;
    for (&cover, 0..) |*share, level| share.* = @as(f32, @floatFromInt(hud.rampLevel(level))) / 255;
    break :covers cover;
};

/// The coverage of each byte in a `Bitmap`.
const outline_cover: Cover = covers: {
    var cover: Cover = undefined;
    for (&cover, 0..) |*share, level| share.* = @as(f32, @floatFromInt(level)) / 255;
    break :covers cover;
};

const Axis = enum { across, down };

/// Where the ink of `pixels`, `width` pixels per row, starts and ends along `axis`, with the bytes
/// covering pixels as `cover` says. The start is in the first line of pixels with ink, offset into
/// it by how far its fullest pixel is from full, and the end is in the last line, offset by how
/// full its fullest pixel is; null if there's no ink. So an edge that half covers a line of pixels
/// lies halfway into it.
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
        // Computed before `found` is written, since the result would otherwise alias it.
        const first = if (found) |was| was[0] else start + 1 - fullest;
        found = .{ first, start + fullest };
    }
    return found;
}

/// How a character is drawn from an outline font.
pub const Shown = union(enum) {
    /// Nothing: its glyph has no ink.
    blank,
    /// The bitmap glyph, since the outline font has none for it.
    bitmap,
    /// The area `u`, `v` of the atlas texture `image`, drawn over the screen rectangle `edges`.
    quad: struct { image: *srtexture.Image, edges: hud.Clip, u: [2]f32, v: [2]f32 },
};

/// The clear pixels kept around each glyph in an atlas, so no glyph is drawn with part of its
/// neighbour.
const gap = 1;

/// The minimum width of an atlas.
const least_width = 64;

/// An outline font's glyphs rendered at one size and packed into one texture, white, with each
/// pixel's alpha set by its coverage. The text colour tints it.
pub const Atlas = struct {
    /// Pixels per em, in 64ths (`Fit.size`).
    size: u32,
    image: srtexture.Image,
    /// The texture's pixels, which the image keeps, so the glyphs of another size can be drawn
    /// into them.
    pixels: []u8,
    glyphs: [codes]Glyph,
    /// When it was last used, counted in its outline's draws, so the least recently used atlas is
    /// replaced first.
    drawn: u64 = 0,

    pub const Glyph = union(enum) {
        /// The bitmap glyph has no ink, or the outline glyph is empty: nothing is drawn.
        blank,
        /// The outline font has no glyph for it: the bitmap glyph is drawn.
        bitmap,
        placed: Placed,
    };

    /// Where a glyph is in the atlas and its size, how far its top is above the baseline, and the
    /// horizontal middle of its ink, from its left edge.
    pub const Placed = struct { at: [2]u32, width: u32, height: u32, top: i32, middle: f32 };

    fn deinit(atlas: *Atlas, gpa: Allocator) void {
        atlas.image.deinit(gpa);
    }
};

/// How many sizes of its glyphs an outline font keeps at once, more than a frame uses: the front
/// end draws its small font at the size of its screens, and at the flight display's size for the
/// version (`hud.drawVersion`).
const kept_sizes = 4;

/// An outline font that replaces one bitmap font, and its glyphs at the most recently used sizes.
pub const Outline = struct {
    /// The allocator for its atlases, whoever draws with it: `Outlines` keeps the outline for the
    /// whole run, so it outlives any one screen's allocator.
    gpa: Allocator,
    rasterizer: Rasterizer,
    face: Face,
    /// The mod's font file that `face` reads, which the outline keeps; null for Newtown, which is
    /// built in, and whose face `Outlines` keeps.
    file: ?[]u8,
    fit: Fit,
    atlases: [kept_sizes]?Atlas = @splat(null),
    /// The textures of atlases that outgrew them, kept until the end because the device may still
    /// be uploading them with the frame that used them.
    retired: std.ArrayList(srtexture.Image) = .empty,
    /// A count of its draws, used to find the least recently used atlas.
    draws: u64 = 0,
    /// Set once its glyphs can't be drawn, so the bitmap glyphs are used.
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

    /// Its glyphs for the bitmap font drawn at `scale` times its size. They are rendered the first
    /// time that size is used, replacing the least recently used size if all `kept_sizes` are in
    /// use. Null once they can't be drawn, which the log says.
    pub fn at(outline: *Outline, scale: f32) Allocator.Error!?Sized {
        if (outline.failed) return null;
        outline.draws += 1;
        const size = outline.fit.size(scale);
        for (&outline.atlases) |*held| if (held.*) |*atlas| if (atlas.size == size) {
            atlas.drawn = outline.draws;
            return .{ .outline = outline, .atlas = atlas };
        };
        // An empty slot, or else the least recently used atlas.
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
                log.warn("can't draw an outline font's glyphs; using the bitmap font", .{});
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

    /// How character `code` is drawn when its place on the line starts at `left`, the line's top is
    /// at `top`, and the bitmap font is drawn at `scale` times its size: with its ink centred on
    /// the bitmap glyph's ink, on the bitmap font's baseline, and its pixels aligned to the
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

/// Renders the glyphs that have ink in `outline`'s fit, at `size`, into the atlas in `slot`: into
/// its existing texture if they fit, which is then uploaded to the GPU again, or else into a new
/// one.
///
/// The device keeps a texture for the rest of the run, so an atlas texture has power-of-two sides,
/// which glyphs of a similar size fit into again when the window changes size; only a size too
/// large for it needs a new texture. The atlas being replaced is the least recently used one, from
/// an earlier frame, as long as a frame uses no more sizes than are kept.
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

/// Lays out the glyphs in rows, left to right across `width`, with `gap` pixels between them and
/// around the edges, each row as tall as its tallest glyph. Writes each glyph's position into
/// `places`, and returns the total height.
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

/// The outline fonts that replace the bitmap fonts. Each is made when its bitmap font is first
/// opened and kept for the whole run, so its glyphs are rendered once for every screen that uses
/// it.
pub const Outlines = struct {
    gpa: Allocator,
    /// What renders their glyphs; null keeps the bitmap glyphs for every font (`--bitmap-fonts`).
    rasterizer: ?Rasterizer,
    /// The mods, whose fonts replace the game's fonts.
    mods: *const bigfile.Mods,
    /// Newtown's face, opened when the first font it replaces is opened.
    built_in: ?Face = null,
    fonts: std.ArrayList(Font) = .empty,

    /// A bitmap font that has been opened, by the name the archives look it up by, and the outline
    /// font that replaces it; null if it keeps its bitmap glyphs.
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

    /// The outline font that replaces the bitmap font `name`, parsed as `font`, whose bytes cover
    /// pixels as `cover` says: a mod's font with its name, or else Newtown if it's one of the
    /// original Handel Gothic fonts. Null if it keeps its bitmap glyphs. The log says which font is
    /// used.
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

    /// Makes the outline font that replaces the bitmap font `member`, parsed as `font`, whose bytes
    /// cover pixels as `cover` says: a mod's font with its name, the first of
    /// `fnt.outline_extensions` that can be read, or else Newtown if it replaces that font. Null if
    /// neither does.
    fn make(outlines: *Outlines, member: []const u8, font: fnt.Font, cover: *const Cover) Allocator.Error!?*Outline {
        const rasterizer = outlines.rasterizer orelse return null;
        const gpa = outlines.gpa;
        for (fnt.outline_extensions) |extension| {
            var buffer: [bigfile.member_name_room]u8 = undefined;
            const name = fnt.outlineName(&buffer, member, extension) catch continue;
            const file = outlines.mods.readFile(gpa, name) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => {
                    log.warn("can't read {s}: {s}", .{ name, @errorName(err) });
                    continue;
                },
            } orelse continue;
            const face = rasterizer.open(file) orelse {
                log.warn("skipping {s}: it can't be read as a font", .{name});
                gpa.free(file);
                continue;
            };
            const made = outlines.fitted(rasterizer, face, file, font, cover, .own, name) catch |err| {
                rasterizer.close(face);
                gpa.free(file);
                return err;
            };
            if (made) |outline| {
                log.info("{s} uses {s}", .{ member, name });
                return outline;
            }
            rasterizer.close(face);
            gpa.free(file);
        }
        // One of the original fonts, which Newtown replaces.
        if (outlines.mods.has(member) or !standsIn(member)) return null;
        const face = outlines.built_in orelse rasterizer.open(newtown) orelse {
            log.warn("can't use Newtown: it can't be read as a font", .{});
            return null;
        };
        outlines.built_in = face;
        const outline = try outlines.fitted(rasterizer, face, null, font, cover, .bitmap, "Newtown") orelse return null;
        log.info("{s} uses Newtown, with strokes {d:.3} em {s}", .{ member, @abs(outline.fit.weight), if (outline.fit.weight < 0) "narrower" else "wider" });
        return outline;
    }

    /// Makes the outline font for `face`, which reads `file`, over the bitmap font `font`. Null,
    /// with a message in the log, if they have none of the capitals used for fitting in common.
    fn fitted(outlines: *Outlines, rasterizer: Rasterizer, face: Face, file: ?[]u8, font: fnt.Font, cover: *const Cover, heft: Heft, name: []const u8) Allocator.Error!?*Outline {
        const fit = try Fit.of(rasterizer, face, font, cover, heft, outlines.gpa) orelse {
            log.warn("skipping {s}: it has none of the capitals {s} in common with the bitmap font", .{ name, references });
            return null;
        };
        const outline = try outlines.gpa.create(Outline);
        outline.* = .{ .gpa = outlines.gpa, .rasterizer = rasterizer, .face = face, .file = file, .fit = fit };
        return outline;
    }
};

pub const testing = struct {
    /// A rasterizer for the tests that draws boxes. It opens any file except one starting with
    /// `not`, using the file's first byte as the face, and has a glyph for every character below
    /// `0x80` except `#`: a fully covered box `wide` ems wide and `capitals` ems tall, on the
    /// baseline. By default the boxes have the same proportions as `font`'s glyphs, so they weigh
    /// the same.
    pub const Boxes = struct {
        /// The number of open faces.
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
            // A heavier box grows to the right and up, as FreeType's glyphs do.
            const width: u32 = @intFromFloat(@max(0, @round(em * of(context).wide + weight * em)));
            const height: u32 = @intFromFloat(@max(0, @round(em * capitals + weight * em)));
            const coverage = try gpa.alloc(u8, @as(usize, width) * height);
            @memset(coverage, 0xFF);
            return .{ .width = width, .height = height, .top = @intCast(height), .coverage = coverage };
        }
    };

    /// A bitmap font eight rows tall for the tests, with codes below `0x80`: `A`, `H` and `#` are
    /// each six pixels wide, with ink from column 1 to 4 and from row 2 to 6, and the space is six
    /// blank pixels.
    pub const font = fontInked(.{ 15, 15, 15 }, null);

    /// `font`, with the boxes `#`, `A` and `H` inked with the bytes `inks`, followed by `palette`
    /// if there is one.
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
    // Ink from the middle of row 1, which is half covered, to the end of row 3, in columns 1 and 2.
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
    // A bitmap font's levels: 15 is full, and anything above it is clear.
    try std.testing.expectEqual([2]f32{ 0, 1 }, inkSpan(&level_cover, &.{ 15, 16 }, 2, .across).?);
}

test Fit {
    const gpa = std.testing.allocator;
    var boxes: testing.Boxes = .{};
    const rasterizer = boxes.rasterizer();
    const font: fnt.Font = try .parse(testing.font);
    // The H's ink is five rows tall and the outline's capitals are three quarters of an em, so an
    // em is six and two thirds bitmap pixels, on the bitmap's baseline, below row 6.
    const fit = (try Fit.of(rasterizer, rasterizer.open("face").?, font, &level_cover, .bitmap, gpa)).?;
    try std.testing.expectApproxEqAbs(5.0 / 0.75, fit.em, 1e-5);
    // Its boxes have as much ink as the bitmap's, so their weight isn't changed.
    try std.testing.expectApproxEqAbs(0, fit.weight, 1e-3);
    try std.testing.expectEqual(7, fit.baseline);
    try std.testing.expectEqual(3, fit.middles['H'].?);
    try std.testing.expectEqual(null, fit.middles[' ']);
    try std.testing.expectEqual(null, fit.middles['B']);
    // At three times the size, an em is twenty pixels, in 64ths.
    try std.testing.expectEqual(20 * sixty_fourths, fit.size(3));
    // A font with none of the capitals used for fitting has no fit.
    try std.testing.expectEqual(null, try Fit.of(rasterizer, rasterizer.open("face").?, try .parse(comptime fnt.testing.font(false)), &level_cover, .bitmap, gpa));
}

test weighed {
    const gpa = std.testing.allocator;
    // Boxes a hundredth of an em wider than the bitmap's ink, which covers four by five pixels, are
    // drawn lighter: at eight times the size, they cover as many pixels, with capitals of the same
    // height.
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

    // At three times the size, the outline's glyphs for A and H are boxes twelve pixels wide and
    // fifteen tall, in a 64x32 texture.
    const sized = (try outline.at(3)).?;
    const atlas = sized.atlas;
    try std.testing.expectEqual([2]u32{ 64, 32 }, [2]u32{ atlas.image.width(), atlas.image.height() });
    try std.testing.expectEqual(Atlas.Placed{ .at = .{ 14, 1 }, .width = 12, .height = 15, .top = 15, .middle = 6 }, atlas.glyphs['H'].placed);
    try std.testing.expectEqual(0xFF, atlas.pixels[((1 + 7) * 64 + 14 + 4) * 4 + 3]);
    try std.testing.expectEqual(0, atlas.pixels[((1 + 7) * 64 + 13) * 4 + 3]);
    // H, at 30 across on a line whose top is at 100: its ink is centred on the bitmap's, 9 pixels
    // into its place, on the baseline 21 pixels down, with its pixels aligned to the window's.
    const h = sized.shown('H', 30, 100, 3).quad;
    try std.testing.expectEqual(&atlas.image, h.image);
    try std.testing.expectEqual(hud.Clip{ .left = 32.5, .top = 105.5, .right = 44.5, .bottom = 120.5 }, h.edges);
    try std.testing.expectEqual([2]f32{ 14.0 / 64.0, 26.0 / 64.0 }, h.u);
    try std.testing.expectEqual([2]f32{ 1.0 / 32.0, 16.0 / 32.0 }, h.v);
    // The space has no ink, the outline font has no `#`, and the bitmap font has no B.
    try std.testing.expectEqual(.blank, sized.shown(' ', 0, 0, 3));
    try std.testing.expectEqual(.bitmap, sized.shown('#', 0, 0, 3));
    try std.testing.expectEqual(.blank, sized.shown('B', 0, 0, 3));

    // The same size uses the same atlas, and each other size gets its own.
    try std.testing.expectEqual(atlas, (try outline.at(3)).?.atlas);
    for ([_]f32{ 3.1, 3.2, 3.3 }) |scale| try std.testing.expect((try outline.at(scale)).?.atlas != atlas);
    // A fifth size replaces the least recently used atlas, reusing its texture since it fits, and
    // the texture is uploaded to the GPU again.
    const pixels = atlas.pixels.ptr;
    try std.testing.expectEqual(atlas, (try outline.at(3.4)).?.atlas);
    try std.testing.expectEqual(pixels, atlas.pixels.ptr);
    try std.testing.expect(atlas.image.changed);
    try std.testing.expectEqual(0, outline.retired.items.len);
    // A size too large for it gets a new texture, and the old one is kept for the frame that used
    // it.
    const large = (try outline.at(20)).?.atlas;
    try std.testing.expect(large.image.width() > 64);
    try std.testing.expectEqual(1, outline.retired.items.len);
}

test Outlines {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A mod with an outline font for `optfnt.fnt`, a bitmap font that replaces `smlfnt2.fnt`, and
    // an outline font for `itacbig.fnt` that can't be read.
    try tmp.dir.createDirPath(io, "mods/a");
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/optfnt.ttf", .data = "a's font" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/smlfnt2.fnt", .data = "a's bitmap font" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mods/a/itacbig.otf", .data = "not a font" });
    var mods: bigfile.Mods = try .open(gpa, io, tmp.dir, null);
    defer mods.close(gpa);
    var boxes: testing.Boxes = .{};
    const font: fnt.Font = try .parse(testing.font);
    {
        var outlines: Outlines = .init(gpa, boxes.rasterizer(), &mods);
        defer outlines.deinit();
        // The mod's font replaces `optfnt.fnt`, and the same outline is used every time it opens.
        const optfnt = (try outlines.of(hud.large_menu_font, font, &level_cover)).?;
        try std.testing.expectEqualStrings("a's font", optfnt.file.?);
        // A mod's font is drawn at its normal weight.
        try std.testing.expectEqual(0, optfnt.fit.weight);
        try std.testing.expectEqual(optfnt, (try outlines.of("OPTFNT.FNT", font, &level_cover)).?);
        // The mod's bitmap font keeps its bitmap glyphs. Newtown replaces the ITAC font, since the
        // mod's font for it can't be read, and the flight display font, using the face it opened
        // once. A font that isn't Handel Gothic isn't replaced.
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
    // Without a rasterizer, every font keeps its bitmap glyphs.
    var bitmaps: Outlines = .init(gpa, null, &mods);
    defer bitmaps.deinit();
    try std.testing.expectEqual(null, try bitmaps.of(hud.large_menu_font, font, &level_cover));
}
