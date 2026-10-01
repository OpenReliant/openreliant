# MP3 files

The crew in the rooms speak their lines from MP3 files on the discs' archives, `%s.mp3` of the
names the crew's tables give, such as `rm06p.mp3` on the Reliant's disc and `ym19p.mp3` on the
Yamato's ([The crew](../engine/rooms.md#the-crew)). The game hands a file to Miles whole, named
`.mp3` (`AIL_set_named_sample_file`), and Miles's MP3 decoder, `MP3DEC.ASI`, plays it. Every MP3
file the discs hold is MPEG-2 audio, Layer III, at 22,050 Hz in joint stereo, 64 kilobits a second.

## In OpenReliant

[`formats/mp3.zig`](../../src/formats/mp3.zig) reads a file's frames, and FFmpeg's MP3 decoder
decodes each ([Platform](../port/platform.md#movies)) into the WAVE file a voice plays.

## Frames

A file is a run of frames. It may start with an ID3v2 tag, whose header of ten bytes holds `ID3`, a
version of two bytes, a byte of flags, and the length of the tag past the header in four bytes of
seven bits each, the highest first; a footer of ten bytes ends the tag where bit 4 of the flags is
set. It may end with an ID3v1 tag, `TAG` and 125 bytes more. Neither tag holds audio.

A frame starts with a header of four bytes, read as a big-endian word:

| Bits | Field |
|---|---|
| 31 to 21 | All set: the frame's sync |
| 20 to 19 | The version: `11` MPEG-1, `10` MPEG-2, `00` MPEG-2.5, `01` none |
| 18 to 17 | The layer: `01` Layer III |
| 16 | Clear where a checksum of two bytes follows the header |
| 15 to 12 | The bit rate's index |
| 11 to 10 | The sample rate's index |
| 9 | The padding: a byte more in the frame |
| 7 to 6 | The channel mode: `11` one channel, else two |

The bit rates in kilobits a second, by their index from 1 to 14, are 32, 40, 48, 56, 64, 80, 96,
112, 128, 160, 192, 224, 256 and 320 for MPEG-1, and 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112,
128, 144 and 160 for the others; index 0 is a free rate and 15 none. The sample rates by their index
from 0 to 2 are 44,100, 48,000 and 32,000 Hz for MPEG-1, half those for MPEG-2, and a quarter for
MPEG-2.5.

A Layer III frame holds 1,152 samples a channel in MPEG-1, and 576 in the others. Its length in
bytes, header and all, is 144 times the bit rate over the sample rate for MPEG-1, and 72 times for
the others, plus the padding's byte, rounded down: 208 bytes, or 209, for the crew's lines.
OpenReliant passes over bytes that start no frame of Layer III with a set bit rate, as a decoder
finds its way back to the frames.
