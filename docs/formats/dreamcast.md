# The Dreamcast version

StarLancer was released for the Dreamcast too, running on Windows CE. Most of its files are in
the PC's formats, so the PC's `sltool` commands read them. Its text and its texture cache have
formats of their own, which `sltool dreamcast` reads. This page describes the disc as a DiscJuggler
image, the usual way a burned Dreamcast disc is kept. The code is in
[`src/formats/dreamcast/`](../../src/formats/dreamcast).

```bash
sltool cd extract <starlancer.cdi> <dir>            # the disc's files
sltool dreamcast text <GTEXT.DAT>                   # the game's text; ITEXT.DAT for the ITAC's
sltool dreamcast textures <DREAMCACHEHW.DAT>        # the texture cache's textures
sltool dreamcast extract <DREAMCACHEHW.DAT> <dir>   # each texture as a PNG file
```

## The disc

The image has an audio track in the first session, and the data track in the second: Mode 2,
with 2336-byte sectors, starting at disc address 11702 ([Disc images](disc-images.md#discjuggler-images)).
Its ISO 9660 volume is called `ECH-SL`.

| Files | Contents | Read with |
|---|---|---|
| `GAME.EXE` | The game: a Windows CE program for the Dreamcast's SH-4. | |
| `0WINCEOS.BIN` | **Unverified:** the Windows CE system, as its name says. | |
| `RESOURCE.HOG`, `PILOTS.HOG`, `MSSPEECH.HOG` | The archives, in the PC's format ([`.HOG`](hog.md)): missions, models, pictures, face films and speech, each in the PC's format too. | `sltool hog`, `dte`, `shp`, `fm8`, `speech` |
| `SHIPSTATS.BIN`, `GUNSTATS.BIN`, `MISSILESTATS.BIN`, `PILOTSTATS.BIN` | The stat tables, in the PC's format ([Stat tables](stats.md)). | `sltool stats` |
| `GTEXT.DAT`, `ITEXT.DAT` | The text ([Text](#text)). | `sltool dreamcast text` |
| `DREAMCACHEHW.DAT` | The texture cache ([Textures](#textures)). | `sltool dreamcast textures`, `extract` |
| `*.SFD` | The movies, as Sofdec films: an MPEG program stream. | |
| `*.TNF` | **Unknown:** fonts, by their names, 1026 bytes each ([#1022](https://github.com/OpenReliant/openreliant/issues/1022)). | |
| `WARNING_ENG.DA` | **Unknown:** it holds an ISO 9660 volume descriptor 32 KiB in ([#1022](https://github.com/OpenReliant/openreliant/issues/1022)). | |

## Text

`GTEXT.DAT` holds the game's text, such as the ships' names, and `ITEXT.DAT` the ITAC's, such as
the debriefings and news. The PC version keeps them in the string tables of `LANGUAGE.DLL` and
`ITACLANG.DLL`.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | **Unknown:** 6551 in both tables |
| 4 | | The offset of each string in the file, 4 bytes each, up to the first string |
| | | The strings, each ending in a zero byte |

**Unverified:** how the strings' numbers relate to the PC's string IDs
([#1022](https://github.com/OpenReliant/openreliant/issues/1022)).

## Textures

`DREAMCACHEHW.DAT` is the PC's texture cache ([Texture caches](tcache.md)) made for the
Dreamcast's PowerVR. It has the PC's header, version 102 with the entries in use and the end of the
pixels, and room for 1000 entries. Its entries are 92 bytes, and its textures follow the
directory, each starting on a 32-byte boundary.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 32 | The name, ending in a zero byte |
| `0x20` | 4 | The entry's own index |
| `0x24` | 2 | The kind (below) |
| `0x26` | 2 | **Unknown:** with mipmaps, the levels of the full chain or one fewer; 1 without |
| `0x28` | 2 | The width |
| `0x2A` | 2 | The height, the same as the width in every entry |
| `0x2C` | 32 | Red, green, blue and alpha, each a mask (4 bytes), a shift (2 bytes) and the bits of 8 it lacks (2 bytes), as the PC's channels are |
| `0x4C` | 4 | **Unknown:** zero in every entry but the last |
| `0x50` | 4 | Where the texture is in the file |
| `0x54` | 8 | Zero |

The kind's bits:

| Bit | Meaning |
|---|---|
| 0 | The texture has mipmaps |
| 1 | The texture is compressed with vector quantization (VQ) |
| 3 | RGB 565 texels |
| 4 | ARGB 4444 texels |
| 5 | ARGB 1555 texels |

A plain texture holds its 16-bit texels row by row. A VQ texture holds a codebook of 256 entries,
2048 bytes, each a 2 by 2 block of texels, then one byte for each block of the picture: the
codebook entry it takes. The blocks are in the PowerVR's twiddled order, the bits of the block's
row and column interleaved with the row's in the even bits, and an entry's texels run down the
left column, then the right.

A texture with mipmaps holds the full chain of levels down to 1 by 1, smallest first, so its
largest level comes last. A plain texture's chain starts with 6 bytes of padding before the 1 by 1
texel, and a VQ texture's with one byte for the 1 by 1 level. `sltool dreamcast extract` writes
each texture's largest level. **Unverified:** whether the game twiddles a plain texture's levels as
it loads them, since the PowerVR draws mipmapped textures twiddled.
