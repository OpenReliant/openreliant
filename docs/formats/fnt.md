# `.fnt` fonts

The interface's text is drawn with WinVFX bitmap fonts, loaded from `resource.hog`.

```bash
sltool fnt info <font>                # header, and the width of every character
sltool fnt render <font> <out.png>    # every glyph in one atlas, sixteen codes to a row
make fonts                            # every font into game/fonts
```

## Layout

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Version, `2.` or `1.` followed by two NULs |
| `0x04` | 4 | Entries in the offset table |
| `0x08` | 4 | Height: rows in every glyph |
| `0x0C` | 4 | **Unknown.** Nothing in WinVFX or the payload reads it |
| `0x10` | 4 x entries | Offset of each character's glyph from the start of the file; 0 for none |

The table is indexed by character code. A glyph is a `u32` width, then `width x height` bytes of
pixels, row by row. Glyphs follow the table in code order, and a glyph of width 0 is four bytes.

Some fonts end with 768 more bytes: 256 RGB triples of 6-bit levels. In some it is a grey ramp, in
others unrelated colours. **Unknown:** what reads it; neither WinVFX nor the payload's font setup
does.

## Pixels

A pixel is a coverage level, `0` for none up to `16` for fully inked, so glyphs are anti-aliased.
WinVFX's `VFX_character_draw` either writes the levels as they are or looks each up in a remap
table the caller supplies, with `0xFF` meaning transparent; the remap table is what gives text its
colour. `sltool fnt render` shows the levels as grey, with 0 transparent.

## Characters

Codes 0 to 31 are empty. Codes 32 to 127 are ASCII, and in the larger fonts 128 to 255 hold
accented letters and symbols. Some tables run past 255, but those entries are empty, and the
payload's font setup, `font_open` (`0x00480D70`), caches the width of codes below 255 only.

## Outline fonts

OpenReliant draws the interface's text from outline fonts at the window's resolution, in place of
the bitmap fonts' glyphs magnified ([`hud/outline.zig`](../../src/engine/game/hud/outline.zig)).
FreeType draws the glyphs ([Platform](../port/platform.md#fonts)).

- **Which font.** A mod's TrueType or OpenType font named for the font stands in for it:
  `optfnt.ttf` or `optfnt.otf` for `interface\optfnt.fnt`, the TrueType one first
  ([Modding](../guide/modding.md#fonts)). Without one, Newtown, which OpenReliant carries
  ([`deps/newtown`](../../deps/newtown/README.md)), stands in for the game's own Handel Gothic
  fonts: `optfnt.fnt` and `smlfnt2.fnt`, the menus' large and small fonts; `itacbig.fnt` and
  `itacsml.fnt`, the ITAC's; `blufont.fnt`, the flight display's; and `ld_handel.fnt`, the
  loadout's tooltip's. A mod's own `.fnt` keeps its glyphs.
- **Through a palette.** The display's and the loadout's tooltip's fonts are drawn through a
  palette, each pixel of a glyph in its own colour. Such a font is fitted by how far each colour
  comes towards its ink, the brightest colour its digits and letters are drawn in, as a pixel of
  the bitmap fades towards black where its glyph covers it less; its outline glyphs are drawn in
  that ink, and a glyph drawn in any colour its digits and letters aren't keeps its bitmap.
- **The weight.** Newtown's strokes are drawn as heavy as the bitmap font's: made wider or
  narrower (FreeType's `FT_Outline_Embolden`) until its digits and letters, drawn eight times as
  large, ink as much as the bitmap's do, the capitals kept as tall. Its ink lacking over half the
  length of its glyphs' edges gives how much wider the strokes must be, and the weight is put right
  again from where it lands until it settles. A mod's font is drawn as heavy as it is.
- **The edge.** VFX writes a bitmap glyph's pixels opaque to its faintest, each in the ink as far
  as the glyph covers it and black for the rest, so that the game's text stands on a dark edge
  wherever what lies under it is lighter. An outline glyph is as clear as it is faint, so the
  text stands on a black edge one bitmap pixel wide: each glyph drawn eight times round it in
  black, the eight of the compass, before the line's glyphs.
- **The layout.** The bitmap font stays the layout: each character's width and the line's height
  are its own, so that every screen lays its text out as the original does. Each character is drawn
  from the outline font at the size that stands its capitals as tall as the bitmap's, by the first
  of `H`, `I`, `E`, `F`, `L` and `T` both fonts have; on the bitmap's baseline, the foot of that
  letter's ink; and centred across where the bitmap's glyph has its ink. An edge of ink half over a
  pixel counts as half way into it. A character the outline font has no glyph for keeps the
  bitmap's, and a code whose bitmap glyph has no ink draws nothing. The codes are the game's code
  page, 1252.
- **The pixels.** Each size a font is drawn at is drawn once into one picture, white and as opaque
  as each pixel is covered, which the text's colour tints, and each glyph is drawn with its pixels
  on the window's, so that the text is as sharp as the window is fine. FreeType's light hinting fits
  the glyphs' heights to the pixels.

**Improvement:** the original draws its text in its bitmap fonts at 640 by 480. `--bitmap-fonts`,
`--original` and the settings screen's OUTLINE FONTS draw the bitmap fonts, magnified, their
pixels opaque as VFX writes them.

## Prior art

[DMJC's StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp) read the header, the glyph
records and the two drawing modes from `WINVFX8.DLL`. It gives the offset table a fixed 256 entries;
the table's length is the count at `0x04`, which in several fonts exceeds 256. The trailing palette
and the coverage levels are additions.
