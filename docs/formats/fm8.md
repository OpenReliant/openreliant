# Face films

The pilots' faces, which the radio's window plays as a pilot speaks ([Radio](../engine/radio.md)):
`.fm8` files in `pilots.hog` ([`.HOG`](hog.md)), one for each pilot and head movement, such as
`45Tigers_Plt.fm8`, `45Tigers_Plt_L.fm8` and `45Tigers_Plt_D.fm8`, and `static.fm8` for a dead
channel. [`engine/game/talkie.zig`](../../src/engine/game/talkie.zig) decodes them. Battlestar
Galactica's comms films use the same chunks, without the scrambling
([Battlestar Galactica](../games/battlestar-galactica.md#comms-films)).

```bash
sltool fm8 info <film>                # its frames and chunks
sltool fm8 extract <film> <out-dir>   # every frame as an indexed PNG file
sltool fm8 encode <frames-dir> <film> # a film of a folder's PNG files, in name order
```

`sltool fm8 encode` ([`fm8_encode.zig`](../../src/tools/sltool/fm8_encode.zig)) writes one key
frame, then a delta frame for each frame after it: each block moved from the frame before where an
equal block lies within 8 pixels, else drawn in four colours where it has no more, else given whole.
It takes only exact matches, so a film of the game's comes back frame for frame, a little larger
than the game's tool made it.

## Chunks

A film is chunks back to back, each 8 bytes of header and its data:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `fYEK`, a key frame; `fLED`, a delta frame; `fDNE`, the end |
| 4 | 4 | The chunk's size, header included |

Each chunk past its header is XORed with the key `A3 27 B7 DD`, repeating from the header's end,
up to 8 bytes before the chunk's end; the last 8 bytes are plain in every shipped film. The game
unscrambles a chunk as it reads it (`talkie_unscramble`, `0x004A6E30`), one chunk a tick of a
timer at 15 a second (`hudmovie_init`, `0x0048D030`), and the end chunk, of its header alone,
ends the film (`talkie_read_chunk`, `0x004A6D80`).

## Key frames

A key frame (`talkie_key`, `0x004A6980`) holds a whole frame and the palette:

| Offset | Size | Field |
|---|---|---|
| 8 | 2 | The frame's height |
| 10 | 2 | Its width |
| 12 | 2 | How many palette entries follow, 256 |
| 14 | 2 | The first entry they fill, 0 |
| 16 | 4 | **Unknown:** zero in every shipped film |
| 20 | 256 x 3 | The palette, red, green and blue a byte each, at `first * 3` |
| 20 + `entries` x 3 | | The pixels, a byte each as an entry of the palette, row by row, compressed with [RefPack](refpack.md) |

The frames are 120 by 100, made of blocks of 4 by 4 pixels. OpenReliant plays films of any size
in whole blocks, and the radio's window draws each at 120 by 100
([Faces](../guide/modding.md#faces)). The game looks through the entries for
the colour it draws see-through, red 255, green 0 and blue 216, or red 254, green 0 and blue 215
or 216, and converts the entries for the display's colour depth.

Ten films come from earlier versions of the tool that made them: `51stWL_Plt`, `51stWL_Plt_d`,
`BuccnrsWL_Plt`, `CougerWL_Plt`, `CougerWL_Plt_d`, `StingerWL_Plt_D`, `StingerWL_Plt_L`,
`STINGWL`, `Victorious_Brdge_Off_D` and `test`. Their key frames hold the width before the height
and the first entry before the entries, and their delta frames their counts in other orders
(below). No pilot record names them, and the game's decoder, reading them in its own order, would
draw their pixels from the palette. Nine are faces the released films lack, the wing leaders of the
51st, the Buccaneers, the Cougars and the Stingers and the Victorious's bridge officer's death;
`test` holds `BUCC`'s frames again. OpenReliant reads them by their layout: a key frame whose
entries are fewer than its first entry has the earlier order, and a delta frame the first order
whose counts lay out a chunk of its size.

## Delta frames

A delta frame (`talkie_delta`, `0x004A66F0`) makes the next frame from the one before, block by
block:

| Offset | Size | Field |
|---|---|---|
| 8 | 2 | The bits each entry of the map takes |
| 10 | 2 | How many blocks are given whole |
| 12 | 2 | How many motion vectors there are |
| 14 | 2 | How many blocks are drawn in four colours |
| 16 | 4 | **Unknown:** zero in every shipped film |

The earlier tools wrote the counts in other orders, the whole blocks' always second: the vectors,
the whole blocks, the patterns, the bits (eight of the ten films above); or the patterns, the
whole blocks, the bits, the vectors (`BuccnrsWL_Plt` and `test`).

The rest of a delta frame:

| Offset | Size | Field |
|---|---|---|
| 20 | | The vectors: two 10-bit numbers each, least significant bit first, the top bit the sign, packed on to whole words (`talkie_unpack_vectors`, `0x004A6520`) |
| | 16 each | The blocks given whole, their pixels row by row |
| | 8 each | The patterns: four palette entries, then a word of two bits a pixel, the highest bits the first pixel's (`talkie_patterns`, `0x004A6590`) |
| | | The map: an entry for each block, row by row, of the bits above, packed on to whole words (`blocks_unpack_map`, `0x004BE937`) |

An entry below the count of vectors moves a block from the frame before: the vector's first
number is added to a table of the rows' starts at the second, `second * width + first`, and the
block is copied from that far away from its own place. Any other entry, less the count of
vectors, picks a block given, the whole ones first and then the patterns (`blocks_assemble`,
`0x004BE884`). The two frames swap before each delta.

## Playing

`hudmovie_play` (`0x0048D120`) opens a film from `pilots.hog` by what follows the first backslash of
its path (`0x0048D2CA`), and decodes its first chunk. **Fix:** the game doesn't check that the path
has a backslash, and crashes where it has none; OpenReliant takes the whole path. Six films of the
45th change with the squadron's name (its pilot and Moose, talking, laughing and dying, from tables
at `0x005026AC` and `0x00502754`): through mission 13 the 45th Tigers' play as the 45th Volunteers',
and from mission 14 the reverse, the names compared without regard to case. In OpenReliant, the
mission's rules decide ([Rules by mission number](../engine/missions.md#rules-by-mission-number)). A timer 15 times a
second, which stands still while the game is paused, decodes the next chunk and copies the frame
into the window's image (`hudmovie_image`, `0x0057C3BC`), and at the end chunk loops the film or
holds it for the line as its flags say ([The radio](../engine/radio.md#the-window)). OpenReliant
reads the film whole as it starts and unscrambles its chunks once
([`hudmovie.zig`](../../src/engine/game/hudmovie.zig)).

The window draws every pixel of the frame, the see-through colour among them, at the display's
scale both ways, so a film keeps its shape at any window's size.
