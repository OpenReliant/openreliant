# PlayStation formats

The PlayStation games on the original's engine, such as
[Star Trek: Invasion](../games/star-trek-invasion.md), keep some files in the console's own
formats. The code is in [`src/formats/playstation/`](../../src/formats/playstation), and the discs'
Mode 2 sectors are described in [Disc images](disc-images.md#image-layout).

```bash
sltool tim info <picture.tim>             # a picture's size and depth
sltool tim png <picture.tim> <out.png>    # a picture, as a PNG file
```

## Executables

A disc's `SYSTEM.CNF` names the executable the console starts, in a line such as
`BOOT = cdrom:\SLUS_009.24;1`. The executable, a `PS-X EXE`, is a 2048-byte header, then the
program's text:

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | `PS-X EXE` |
| 16 | 4 | The address the program starts at |
| 20 | 4 | The global pointer at the start |
| 24 | 4 | The address the text loads at |
| 28 | 4 | The text's size |

## TIM pictures

A TIM picture is a header, a colour table for a picture of palette indices, then the picture:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `0x10` |
| 4 | 4 | Flags: the depth in bits 0 to 2, and in bit 3 whether a colour table follows |
| 8 | | The colour table's block, if any, then the picture's block |

The depth is 0 for 4-bit palette indices, the leftmost pixel in the low bits, 1 for 8-bit indices,
2 for 15-bit colours and 3 for 24-bit colours. A block starts with a 12-byte header:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | The block's length, this header included |
| 4 | 2 | x in video memory |
| 6 | 2 | y in video memory |
| 8 | 2 | The width, in 16-bit units of video memory |
| 10 | 2 | The height, in rows |

The colour table holds one palette a row. A colour has 5 bits each of red, green and blue, from the
low bits, and a flag in bit 15 that makes it semi-transparent where the drawing asks for it. The
colour `0x0000` is drawn transparent. `sltool` writes a picture as RGBA, with the first palette, and
`0x0000` transparent.
