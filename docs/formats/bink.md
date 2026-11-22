# `.bik` movies

The game's movies are Bink video, revision 1, by RAD Game Tools, which it plays through
`BINKW32.DLL` ([Movies](../engine/movies.md)). A movie is a header, its audio tracks, an index of
its frames, and the frames. [`formats/bink.zig`](../../src/formats/bink.zig) reads the container;
FFmpeg's decoders decode the video and the audio ([Platform](../port/platform.md#movies)).

The intro's movies lie in the game's folder, the front end's transitions in its `interface`
folder, and the rest in the disc archives `CD1.HOG` and `CD2.HOG`. Every one is revision `f`, `g`
or `i`, at 15 frames a second but for four stills at 1: 640 by 480 for the screens and their
transitions, 640 by 360 for the 16:9 cinematics, and about 352 by 305 for the briefings. The sound
is 22,050 Hz, mono or stereo, or 44,100 Hz stereo, and many have none.

## Header

| Offset | Size | Field |
|---|---|---|
| `0x00` | 3 | `BIK` |
| `0x03` | 1 | The revision: `b` to `i` |
| `0x04` | 4 | The file's size, less these 8 bytes |
| `0x08` | 4 | Frames |
| `0x0C` | 4 | The size of the largest frame |
| `0x10` | 4 | **Unknown.** |
| `0x14` | 4 | Width |
| `0x18` | 4 | Height |
| `0x1C` | 4 | Frames a second, times the next field |
| `0x20` | 4 | The divisor of the frame rate |
| `0x24` | 4 | The video's flags: `0x00020000` grey, `0x00100000` with an alpha plane, and in its top four bits how the player enlarges the pictures ([Scaling](#scaling)) |
| `0x28` | 4 | Audio tracks |

Then, for each audio track, a `u32` that nothing reads (the most samples a packet decodes to);
then, for each, its rate (`u16`) and its flags (`u16`: `0x1000` coded by the discrete cosine
transform rather than the real Fourier transform, `0x2000` stereo, `0x4000` 16-bit samples); then,
for each, its id (`u32`).

## Frames

The index follows, a `u32` for each frame: its offset from the start of the file, with bit 0 set
for a key frame, so frames start at even offsets. A frame runs to the next one's offset, the last
to the file's end.

A frame holds, for each audio track, a `u32` size and a packet of that many bytes, then its video
to the frame's end. An audio packet starts with the size its samples decode to, in bytes (`u32`);
one of fewer than 4 bytes holds nothing. The first frame carries more of the sound than its share,
so that the sound plays ahead of the pictures.

## Scaling

The top four bits of the video's flags say how Bink's player shows a movie coded at half its
width, its height or both (`bink.VideoFlags.Scaling`):

| Value | The movie is shown |
|---|---|
| 0 | As it is coded |
| 1 | Twice as high, each line doubled |
| 2 | Twice as high, every other line black |
| 3 | Twice as wide |
| 4 | Twice as wide and as high, each pixel doubled |
| 5 | Twice as wide and as high, every other line black |

The game's own movies have 0. The [Russian release](russian-release.md#the-movies)'s were coded
again at half size: 320x240 for 640x480 and 320x180 for 640x360 with 4, and 320x360 for 640x360
with 3. OpenReliant draws a movie at the size its flags give (`bink.Header.shownSize`), scaled
as it scales every movie, and draws every line.
