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

OpenReliant draws the interface text with outline fonts at the window's resolution, instead of
scaling up the bitmap fonts ([`hud/outline.zig`](../../src/engine/game/hud/outline.zig)). FreeType
renders the glyphs ([Platform](../port/platform.md#fonts)).

- **Which font.** A TrueType or OpenType font in a mod with the same name as a bitmap font replaces
  it: `optfnt.ttf` or `optfnt.otf` for `interface\optfnt.fnt`, with the TrueType font tried first
  ([Modding](../guide/modding.md#fonts)). Otherwise Newtown, which is built into OpenReliant
  ([`deps/newtown`](../../deps/newtown/README.md)), replaces the original Handel Gothic fonts:
  `optfnt.fnt` and `smlfnt2.fnt`, the large and small menu fonts; `itacbig.fnt` and `itacsml.fnt`,
  the ITAC fonts; `blufont.fnt`, the flight display font; and `ld_handel.fnt`, the loadout tooltip
  font. A `.fnt` file in a mod is drawn from its bitmaps.
- **Palette fonts.** The flight display font and the loadout tooltip font are drawn through a
  palette, with each pixel of a glyph in its own colour. For these fonts, the ink is the brightest
  colour their digits and letters use, and each colour counts as partial coverage by how close it
  is to the ink, since the bitmap's pixels fade towards black where the glyph covers them less.
  Outline glyphs are drawn in the ink colour, and a glyph that uses colours the digits and letters
  don't use, such as a symbol, keeps its bitmap.
- **Weight.** Newtown's strokes are made as heavy as the bitmap font's. OpenReliant makes them
  wider or narrower (FreeType's `FT_Outline_Embolden`) until its digits and letters, drawn at eight
  times the size with capitals of the same height, cover as many pixels as the bitmap font's. The
  first estimate of the change is the missing coverage divided by half the length of the glyphs'
  edges, and OpenReliant repeats the estimate from the result until it settles. A mod's font is
  drawn at its normal weight.
- **Outline.** VFX draws every pixel of a bitmap glyph that has any coverage as fully opaque,
  blending the ink colour with black by how much the glyph covers it, so the original text has a
  dark edge wherever the background is lighter. An outline glyph's pixels are only as opaque as
  they are covered, so OpenReliant gives the text a black outline one bitmap pixel wide instead:
  before it draws a line of text, it draws each glyph eight times in black, offset in the eight
  compass directions.
- **Layout.** The text keeps the bitmap font's layout: each character's width and the line height
  come from the bitmap font, so every screen lays out its text like the original. Each character is
  drawn from the outline font at the size that makes its capitals as tall as the bitmap font's,
  measured on the first of `H`, `I`, `E`, `F`, `L` and `T` that both fonts have. It sits on the
  bitmap font's baseline, the bottom of that letter's ink, and is centred on the inked part of the
  bitmap glyph. Ink is measured to a fraction of a pixel: a pixel half covered at the edge of the
  ink puts the edge halfway into the pixel. A character the outline font has no glyph for keeps the
  bitmap glyph, and a character whose bitmap glyph has no ink draws nothing. Characters are in the
  game's code page, 1252.
- **Pixels.** Each size of a font is rendered once into a texture, in white with each pixel's alpha
  set by its coverage, and the text colour tints it. Each glyph is drawn aligned to the window's
  pixels, so the text is as sharp as the window's resolution allows. FreeType's light hinting fits
  the glyphs' heights to the pixel grid.

**Improvement:** the original draws its text with its bitmap fonts at 640x480. `--bitmap-fonts`,
`--original` and the OUTLINE FONTS setting draw the bitmap fonts instead, scaled up, with opaque
pixels as VFX draws them.

## Prior art

[DMJC's StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp) read the header, the glyph
records and the two drawing modes from `WINVFX8.DLL`. It gives the offset table a fixed 256 entries;
the table's length is the count at `0x04`, which in several fonts exceeds 256. The trailing palette
and the coverage levels are additions.
