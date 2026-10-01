//! The outline fonts' glyphs, drawn by FreeType (`deps/freetype`) for the engine's rasterizer
//! (`hud.outline.Rasterizer`). A face opens from its font file in memory, and its glyphs are drawn
//! anti-aliased, with FreeType's light hinting: their heights fitted to the pixels, which keeps
//! their level strokes, their feet and the capitals' tops sharp, and their widths and their places
//! across as the outlines have them.
//!
//! FreeType is used from the thread the game runs on alone.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("ft");
const openreliant = @import("openreliant");
const outline = openreliant.engine.game.hud.outline;

const log = std.log.scoped(.fonts);

/// How each glyph is loaded: drawn as it loads, with light hinting.
const load_flags: c.FT_Int32 = c.FT_LOAD_RENDER | @as(c.FT_Int32, c.FT_RENDER_MODE_LIGHT & 15) << 16;

/// FreeType's library, which every face it opens needs while it is open.
pub const FreeType = struct {
    library: c.FT_Library,

    pub fn init() error{FreeType}!FreeType {
        var library: c.FT_Library = null;
        const failed = c.FT_Init_FreeType(&library);
        if (failed != 0) {
            log.warn("FreeType doesn't start: error {d}", .{failed});
            return error.FreeType;
        }
        return .{ .library = library };
    }

    pub fn deinit(free_type: *FreeType) void {
        _ = c.FT_Done_FreeType(free_type.library);
    }

    pub fn rasterizer(free_type: *FreeType) outline.Rasterizer {
        return .{ .context = free_type, .vtable = &.{
            .open = open,
            .close = close,
            .top = top,
            .draw = draw,
        } };
    }
};

fn of(context: *anyopaque) *FreeType {
    return @ptrCast(@alignCast(context));
}

fn faceOf(face: outline.Face) c.FT_Face {
    return @ptrCast(@alignCast(face));
}

/// The first face of the font file `bytes`; null where FreeType can't read it, or it is no
/// outline font, which the log says.
fn open(context: *anyopaque, bytes: []const u8) ?outline.Face {
    const size = std.math.cast(c.FT_Long, bytes.len) orelse return null;
    var face: c.FT_Face = null;
    const failed = c.FT_New_Memory_Face(of(context).library, bytes.ptr, size, 0, &face);
    if (failed != 0) {
        log.warn("FreeType can't read a font: error {d}", .{failed});
        return null;
    }
    if (face.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0) {
        log.warn("a font holds no outlines, only bitmaps", .{});
        _ = c.FT_Done_Face(face);
        return null;
    }
    return face;
}

fn close(_: *anyopaque, face: outline.Face) void {
    _ = c.FT_Done_Face(faceOf(face));
}

/// How far above the baseline `character`'s outline reaches, in ems, from its unscaled metrics.
fn top(_: *anyopaque, face: outline.Face, character: u21) ?f32 {
    const shown = faceOf(face);
    const index = c.FT_Get_Char_Index(shown, character);
    if (index == 0 or shown.*.units_per_EM == 0) return null;
    if (c.FT_Load_Glyph(shown, index, c.FT_LOAD_NO_SCALE) != 0) return null;
    const bearing: f32 = @floatFromInt(shown.*.glyph.*.metrics.horiBearingY);
    return bearing / @as(f32, @floatFromInt(shown.*.units_per_EM));
}

/// `character` drawn at `em` pixels to the em, as 256 levels of coverage; null where the face has
/// no glyph for it, or one FreeType can't draw so.
fn draw(_: *anyopaque, face: outline.Face, character: u21, em: f32, gpa: Allocator) outline.Error!?outline.Bitmap {
    const shown = faceOf(face);
    const index = c.FT_Get_Char_Index(shown, character);
    if (index == 0) return null;
    // A size in 64ths of a point at 72 points to the inch: in 64ths of a pixel.
    const size = std.math.lossyCast(c.FT_F26Dot6, @round(em * 64));
    if (c.FT_Set_Char_Size(shown, 0, size, 72, 72) != 0) return error.Rasterizing;
    if (c.FT_Load_Glyph(shown, index, load_flags) != 0) return null;
    const glyph = shown.*.glyph;
    const bitmap = glyph.*.bitmap;
    if (bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY or bitmap.pitch < 0) return null;
    const width: u32 = bitmap.width;
    const height: u32 = bitmap.rows;
    const coverage = try gpa.alloc(u8, @as(usize, width) * height);
    const pitch: usize = @intCast(bitmap.pitch);
    for (0..height) |row| @memcpy(coverage[row * width ..][0..width], bitmap.buffer[row * pitch ..][0..width]);
    return .{ .width = width, .height = height, .top = glyph.*.bitmap_top, .coverage = coverage };
}

test FreeType {
    const gpa = std.testing.allocator;
    var free_type: FreeType = try .init();
    defer free_type.deinit();
    const rasterizer = free_type.rasterizer();
    // Newtown's capitals stand some seven tenths of an em tall.
    const face = rasterizer.open(outline.newtown).?;
    defer rasterizer.close(face);
    const capitals = rasterizer.top(face, 'H').?;
    try std.testing.expect(capitals > 0.6 and capitals < 0.8);
    // An H drawn at 100 pixels to the em stands on the baseline, as tall as its outline.
    const h = (try rasterizer.draw(face, 'H', 100, gpa)).?;
    defer h.deinit(gpa);
    try std.testing.expectApproxEqAbs(capitals * 100, @as(f32, @floatFromInt(h.top)), 1);
    try std.testing.expectEqual(h.top, @as(i32, @intCast(h.height)));
    try std.testing.expect(std.mem.max(u8, h.coverage) == 0xFF);
    // A character it has no glyph for, and a file that holds no font.
    try std.testing.expectEqual(null, try rasterizer.draw(face, 0x4E2D, 100, gpa));
    try std.testing.expectEqual(null, rasterizer.top(face, 0x4E2D));
    try std.testing.expectEqual(null, rasterizer.open("not a font"));
}
