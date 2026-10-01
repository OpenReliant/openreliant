# Texture caches

`tcachehw.dat` and `tcachesw.dat`, installed beside the game, hold every texture the models and
effects use, converted and mipmapped ahead of time. The game reads textures from nothing else. The
software renderer uses `tcachesw.dat`; the hardware renderers use `tcachehw.dat`.

```bash
sltool tcache info <cache>                                # entries, formats
sltool tcache ls <cache>                                  # every texture: size, levels, format
sltool tcache extract <cache> <palette.tga> <out-dir> [name...]
make textures                                             # tcachehw.dat into game/textures
```

## Layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Version: `102` |
| 4 | 4 | Entries in use |
| 8 | 4 | End of the pixels |
| 12 | 1000 x 240 | Directory: the entries in use, then zeros |
| 240012 | | Pixels |

All fields are little-endian. [`src/formats/tcache.zig`](../../src/formats/tcache.zig) defines the
structures.

## Entry

The engine reads the whole directory into memory, `texture_cache` (`0x005E83E0`). From `0x48` on an
entry is the image as the engine holds it (`TextureImage`); `texture_find` returns a pointer to that
part.

| Off | Type | Field |
|---|---|---|
| `0x00` | format | Format of the stored pixels |
| `0x40` | u32 | Width of the stored pixels |
| `0x44` | u32 | Height of the stored pixels |
| `0x48` | char[32] | Name, NUL-terminated, with no directory or extension |
| `0x68` | u32 | The entry's own index |
| `0x6C` | u32 | Users. Run-time state |
| `0x70` | u32 | Flags (below) |
| `0x74` | u32 | Mipmap levels |
| `0x78` | u32 | Width |
| `0x7C` | u32 | Height |
| `0x80` | format | Pixel format |
| `0xC0` | u32 | Address of the pixels. Run-time state |
| `0xDC` | f32 | `200.0` in every entry. **Unknown** |
| `0xE0` | u32 | File offset of the pixels |
| `0xE4` | f32 | Brightness: added to every channel on upload, as a fraction of full scale |
| `0xE8` | f32 | Contrast: every channel is scaled by `1 + contrast` on upload |
| `0xEC` | u32 | The driver's record of the uploaded texture. Run-time state |

The other bytes are zero. Before reading an entry's pixels, the loader copies `0x00` to `0x47` over
`0x78` to `0xBF`, since the upload may convert or resize the image in memory. In the shipped caches
the two copies agree.

Flags:

| Bit | Meaning |
|---|---|
| `0x01` | Set on index-and-alpha entries, and only those |
| `0x02` | Mipmapped |
| `0x04` | Set on 8-bit index entries, and only those |
| `0x08` | Transient: made at run time and kept in memory, never written to the file. `texture_find` does not return it while nothing uses it |
| `0x10` | Makes `image_convert` take another path (`0x004C8850`). **Unknown** |

### Pixel format

| Off | Field |
|---|---|
| `0x00` | Bytes per pixel: 1, 2 or 4 |
| `0x04` | Palette index |
| `0x10` | Red |
| `0x1C` | Green |
| `0x28` | Blue |
| `0x34` | Alpha |

Each component is three u32s: mask, shift and loss. Its 8-bit value is
`((pixel & mask) >> shift) << loss`; an absent component has mask 0 and loss 8. `pixel_format_set`
(`0x004C3430`) derives shift and loss from the mask. The engine's conversion, `image_convert`
(`0x004C8600`), leaves the low `loss` bits zero; `sltool` scales to full range.

The shipped caches use three formats:

| Format | Bytes | Pixel |
|---|---|---|
| 8-bit index | 1 | A palette index |
| Index and alpha | 2 | A palette index in the low byte, alpha in the high byte |
| RGB565 | 2 | Red in bits 11 to 15, green 5 to 10, blue 0 to 4 |

A format without alpha is opaque.

### Pixels

An entry's pixels are its mipmap levels in order, the full-size image first, each row by row from
the top. Each level halves the last, rounding down. A mipmapped entry has levels down to a smaller
side of 2, so 8 for 256x256; an entry without the flag has one, whatever `0x74` holds. The size is
the pixel count of all levels (`image_pixel_count`, `0x004C85B0`) times the bytes per pixel.

The entries' pixels are contiguous, in directory order, and end at the header's end offset.

## Palettes

Palette indices look up the palette loaded at the time: the colour map of a TGA in `resource.hog`,
256 entries stored blue, green, red (`SR_TGA_get_palette`, `0x004CA9B0`).

| Where | Palette | Colour cube |
|---|---|---|
| Software renderer | `softpal.tga` | `softpal.ccb` |
| Hardware renderers | `palette.tga` | `palette.ccb` |
| Loadout screen | `palette3.tga` | `palette3.ccb` |

`renderer_start` (`0x004ACBE0`) loads the renderer's pair and `loadout_load` the loadout screen's.
The loadout screen's textures are indexed into `palette3.tga` and identical in both caches: the
fighters' `g`- and `r`-prefixed textures, `gmissiles`, `rmissiles`, `plate-nw`, `plate-ne`,
`plate-sw`, `plate-se`, `hologlow` and `hpoints`. The rest are indexed into their renderer's palette.

A colour cube (`.ccb`, `SR_CCB_load`) holds, in order:

| Offset | Size | Field |
|---|---|---|
| `0x000` | 256 x 3 | The palette, in 6-bit levels |
| `0x300` | 256 x 12 | The palette again, as floats: level / 64 |
| `0xF00` | 4 | **Unknown** |
| `0xF04` | 7 x 4 | Bits of red, green and blue (6 each), their maxima (63 each), the table's size (`0x40000`) |
| `0xF20` | `0x40000` | A palette index for each colour, by the top 6 bits of red, green and blue, red outermost |

`image_convert` quantizes to an index format through the table.

## Loading

`renderer_start` opens the cache with `texture_cache_open` (`0x004C9A40`). A missing file, or one of
another version, is replaced by an empty cache, and every texture lookup then fails.

A model's materials are looked up by `texture_require` (`0x00494A30`), with the prefix
[`.SHP`](shp.md#material-tag-0x06) describes. `texture_find` (`0x004C9E20`) compares the name's file
name, what follows its last `\`, `/` or `:`, with each entry's in directory order, ignoring case. On
first use it reads the pixels and uploads them. A miss stops the game: `Could not find image %s`.

The upload (`texture_upload`, `0x004C9C90`) fits the image to the device. `Tdetail` in the `Device`
section of the settings, 0, 1 or 2 (default 1), caps texture sides at 128, 256 or 2048; a larger
image is shrunk by the integer ratio. Brightness and contrast apply when either is non-zero. The
image is then converted to the device's format.

The shipped game adds nothing to the file. The loadout screen draws its panels into transient
32-bit textures, `fpanels`, `bpanels`, `finfo` and `binfo`, kept in memory.

OpenReliant looks for a mod's picture of the texture's name, `<name>.png`, before the cache, and
makes its mipmaps as it reads it ([Modding](../guide/modding.md#textures)).

## Contents

The two caches hold the same names in the same order. Besides the palette, a few images differ:
`matflarea1` to `matflareb7` are 256x256 in `tcachesw.dat` and 32x32 in `tcachehw.dat`, and
`ddwarp128` and `ddlaserr` hold different pictures.

Many of the second textures that parts flagged `0x80` bind, `l` and the material name, are 2x2
placeholders.

A few models in `resource.hog` name textures neither cache holds, among them `Dockcube.SHP`, the
`Cargo` models and the `p`-prefixed planets.
