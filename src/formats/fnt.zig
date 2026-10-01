//! `.fnt` fonts: WinVFX bitmap fonts.
//!
//! A font is a header, a table with one offset per character code, and one glyph per code: a width
//! and a raw `width x height` block of pixels, row by row. WinVFX reads the height at `+0x08`
//! (`VFX_font_height`), a glyph's width through the table (`VFX_character_width`), and draws its
//! pixels either as they are or through a remap table the caller supplies (`VFX_character_draw`).
//! Pixels are coverage levels, `0` for none up to `16` for full, so a remap table is what colours
//! the text.

const std = @import("std");
const assert = std.debug.assert;

const layout = @import("layout.zig");
const spr = @import("spr.zig");

pub const extension = ".fnt";

pub const header_size = 0x10;

/// OpenReliant's: the extensions of the outline fonts that stand in for a font, TrueType's and
/// OpenType's, in the order they are looked for (`outlineName`).
pub const outline_extensions = [_][]const u8{ ".ttf", ".otf" };

/// The name of the outline font that stands in for the font `name`, with `outline_extension`: the
/// font's name without its folder or extension, and `outline_extension`.
pub fn outlineName(buffer: []u8, name: []const u8, outline_extension: []const u8) error{NoSpaceLeft}![]u8 {
    const stem = std.fs.path.stem(std.fs.path.basenameWindows(name));
    return std.fmt.bufPrint(buffer, "{s}{s}", .{ stem, outline_extension });
}

test outlineName {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("optfnt.ttf", try outlineName(&buffer, "interface\\optfnt.fnt", ".ttf"));
    try std.testing.expectEqualStrings("BLUFONT.otf", try outlineName(&buffer, "BLUFONT.FNT", ".otf"));
    try std.testing.expectError(error.NoSpaceLeft, outlineName(buffer[0..4], "optfnt.fnt", ".ttf"));
}

/// Bytes of the palette some fonts carry after their last glyph: 256 RGB triples of 6-bit levels,
/// as a sprite set's.
pub const palette_size = spr.palette_size;

/// Coverage of a fully inked pixel.
pub const full_coverage = 16;

/// The engine caches widths for character codes below this, so higher glyphs are never drawn
/// (`font_open`, `0x00480D70`).
pub const engine_limit = 0xFF;

pub const Error = error{ NotAFont, Truncated, BadGlyph };

pub const Header = extern struct {
    /// `2.` or `1.`, as raw bytes.
    version: [4]u8,
    /// Entries in the offset table.
    count: u32,
    /// Rows in every glyph.
    height: u32,
    /// **Unknown.** Nothing in WinVFX or the payload reads it.
    _unknown_0c: u32,

    comptime {
        assert(@sizeOf(Header) == header_size);
    }
};

pub const Glyph = struct {
    width: u32,
    height: u32,
    /// `width * height` coverage levels, row by row.
    pixels: []const u8,
};

pub const Font = struct {
    bytes: []const u8,
    header: *align(1) const Header,
    /// Offsets from the start of the file, one per character code; `0` for no glyph.
    offsets: []align(1) const u32,
    /// The trailing palette, when the file has one: a glyph's bytes are indices into it. The
    /// shipped fonts run from those using its first seventeen entries as levels of coverage to
    /// those reaching past two hundred for glyphs of their own colours.
    palette: ?*const [palette_size]u8,

    pub fn parse(bytes: []const u8) Error!Font {
        const header = try layout.view(Header, bytes);
        const version = header.version;
        if (!std.ascii.isDigit(version[0]) or version[1] != '.' or version[2] != 0 or version[3] != 0) {
            return error.NotAFont;
        }

        const offsets = try layout.array(u32, bytes[header_size..], header.count);

        // Every glyph must fit, and the last one's end tells whether a palette follows.
        var end = header_size + offsets.len * @sizeOf(u32);
        for (offsets) |offset| {
            if (offset == 0) continue;
            if (offset > bytes.len) return error.BadGlyph;
            const width = (layout.view(u32, bytes[offset..]) catch return error.BadGlyph).*;
            const glyph_end = @as(usize, offset) + @sizeOf(u32) + @as(usize, width) * header.height;
            if (glyph_end > bytes.len) return error.BadGlyph;
            end = @max(end, glyph_end);
        }
        const palette: ?*const [palette_size]u8 = if (bytes.len - end == palette_size)
            bytes[end..][0..palette_size]
        else
            null;

        return .{ .bytes = bytes, .header = header, .offsets = offsets, .palette = palette };
    }

    pub fn height(font: Font) u32 {
        return font.header.height;
    }

    /// The glyph for character code `code`, or null when the font has none.
    pub fn glyph(font: Font, code: usize) ?Glyph {
        if (code >= font.offsets.len) return null;
        const offset = font.offsets[code];
        if (offset == 0) return null;
        const width = (layout.view(u32, font.bytes[offset..]) catch return null).*;
        return .{
            .width = width,
            .height = font.header.height,
            .pixels = font.bytes[offset + @sizeOf(u32) ..][0 .. @as(usize, width) * font.header.height],
        };
    }
};

pub const testing = struct {
    /// A font of two codes: 0 has no glyph, 1 is two pixels wide and two tall, with a palette
    /// after it or without.
    pub const font = testFont;
};

fn testFont(comptime with_palette: bool) []const u8 {
    // Two codes: 0 has no glyph, 1 is two pixels wide and two tall.
    const table: [2]u32 = .{ 0, header_size + 2 * @sizeOf(u32) };
    const glyph = std.mem.toBytes(@as(u32, 2)) ++ [_]u8{ 0, 16, 8, 0 };
    const header: Header = .{ .version = "2.\x00\x00".*, .count = table.len, .height = 2, ._unknown_0c = 0 };
    const palette: [palette_size]u8 = @splat(0x3F);
    return std.mem.toBytes(header) ++ std.mem.sliceAsBytes(&table) ++ glyph ++ (if (with_palette) palette else [0]u8{});
}

test Font {
    const font = try Font.parse(comptime testFont(false));
    try std.testing.expectEqual(@as(u32, 2), font.height());
    try std.testing.expectEqual(@as(?Glyph, null), font.glyph(0));
    const one = font.glyph(1).?;
    try std.testing.expectEqual(@as(u32, 2), one.width);
    try std.testing.expectEqualSlices(u8, &.{ 0, 16, 8, 0 }, one.pixels);
    try std.testing.expectEqual(@as(?Glyph, null), font.glyph(2));
    try std.testing.expect(font.palette == null);

    const coloured = try Font.parse(comptime testFont(true));
    try std.testing.expect(coloured.palette != null);

    try std.testing.expectError(error.NotAFont, Font.parse("1.40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"));
}
