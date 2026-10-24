# Matroska and WebM files

Matroska is a container for video, audio and subtitles in many codecs. WebM is Matroska that holds
only VP8, VP9 or AV1 video and Vorbis or Opus audio. The original reads no Matroska files.
OpenReliant reads them from mods, in place of a Bink movie ([Movies](../guide/modding.md#movies)),
and plays VP9 video with Opus or Vorbis sound. A WebM file usually has the extension `.webm`, and
any other Matroska file `.mkv`.

## Elements

A file is a tree of EBML elements (RFC 8794). Each element is an ID, the size of its data, and the
data, which holds a value or more elements. The ID and the size are numbers of variable length:
the zero bits at the start of the first byte, plus one, give the number's length in bytes, and the
set bit after them marks where the length ends. An ID keeps that bit as part of its value, as the
specifications write the IDs, and has at most 4 bytes. A size drops it, and has at most 8 bytes; a
size whose value has every bit set is unknown, as a file written as a stream leaves its segment's
and its clusters' sizes. Integers are big-endian, in up to 8 bytes, floats are 4 or 8 bytes,
big-endian, and strings may end in zero bytes.

A file is an EBML header, `1A45DFA3`, whose `DocType` (`4282`) is `matroska` or `webm`, then a
segment, `18538067`, which holds the rest (RFC 9559):

| Element | ID | Holds |
|---|---|---|
| `Info` | `1549A966` | Its `TimestampScale` (`2AD7B1`): how many nanoseconds a tick of the timestamps lasts, 1,000,000 unless given |
| `Tracks` | `1654AE6B` | A `TrackEntry` (`AE`) for each track |
| `Cluster` | `1F43B675` | Its `Timestamp` (`E7`), in ticks, then its blocks |

A segment can also hold an index of where its elements are (`SeekHead`), cues for seeking
(`Cues`), chapters, tags and attachments.

A track entry holds:

| Element | ID | Holds |
|---|---|---|
| `TrackNumber` | `D7` | The number its blocks give |
| `TrackType` | `83` | 1 for video, 2 for audio |
| `FlagEnabled` | `B9` | 0 for a track that is off, 1 unless given |
| `CodecID` | `86` | `V_VP9`, `A_OPUS` or `A_VORBIS`, say |
| `CodecPrivate` | `63A2` | The codec's headers, where it has any |
| `ContentEncodings` | `6D80` | How the track's data is compressed or encrypted, where it is |
| `Video` | `E0` | A video track's `PixelWidth` (`B0`) and `PixelHeight` (`BA`) |
| `Audio` | `E1` | An audio track's `SamplingFrequency` (`B5`, a float, 8000 unless given) and `Channels` (`9F`, 1 unless given) |

## Blocks

A cluster holds the tracks' frames in blocks: each in a `SimpleBlock` (`A3`), or in a `Block`
(`A1`) inside a `BlockGroup` (`A0`). A block starts with a header:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 to 8 | The track's number, as a size |
| then | 2 | The time, in ticks after the cluster's timestamp, signed |
| then | 1 | Flags: `0x80` a key frame (in a simple block), `0x08` a frame not shown, `0x06` the lacing, `0x01` a frame that may be dropped |

The frame follows. A block in a group leaves the key frame flag clear: it is a key frame unless the
group also holds a `ReferenceBlock` (`FB`), which names a frame it depends on.

Lacing puts several frames in one block, as audio packets often are. The first byte after the
header is the number of frames less one, then come the frames' sizes, all but the last's, which is
what remains:

- **Xiph lacing** (`0x02`): each size as bytes added up, where a byte of 255 carries on into the
  next byte and any other ends the size.
- **EBML lacing** (`0x06`): the first size as a size number, then each next size as a signed
  number of variable length, the difference from the size before. A signed number is the value of
  a size less half its range, `2^(7n-1) - 1` for a number of `n` bytes.
- **Fixed-size lacing** (`0x04`): no sizes, as the frames all have the same size.

## Codecs

- **VP9** (`V_VP9`): each block holds a frame, or a superframe: several frames, one shown and the
  others only decoded, with an index of their sizes at its end. A frame's first byte holds the
  frame's marker, `10` in its two top bits, then the profile's low bit and its high bit. Profile 0
  is 8 bits with the colour at half size across and down (4:2:0). A key frame gives its colour
  space, such as BT.601 or BT.709, or leaves it unknown, and says whether its range is limited or
  full.
- **Opus** (`A_OPUS`): `CodecPrivate` is the identification header, `OpusHead`, as in an Ogg
  stream ([Ogg files](ogg.md#streams)).
- **Vorbis** (`A_VORBIS`): `CodecPrivate` is the three headers laced together in Xiph lacing, as
  the decoder takes them.

## In OpenReliant

[`formats/matroska.zig`](../../src/formats/matroska.zig) reads the EBML header, then the segment's
information and tracks, and the blocks of every cluster that belong to the first video track and
the first audio track that are on. It keeps each video frame with its time and whether it is a key
frame, and each audio packet, and skips the other elements. A cluster whose size is unknown ends
where one of the segment's own elements begins, such as the next cluster or the cues. It refuses a
file that isn't Matroska or WebM, one without video, one whose first video frame isn't a key frame,
and one whose tracks are compressed or encrypted.

`engine/bink.zig` plays the movie in a Bink movie's place
([Movies](../engine/movies.md#in-openreliant)). It takes only VP9 of profile 0, which it checks
from the first frame. FFmpeg's VP9 decoder decodes the frames, and its Opus or Vorbis decoder the
sound, all of it as the movie opens ([Platform](../port/platform.md#movies)). The colours are
turned into RGB by BT.709 where the frames say BT.709, or SMPTE 240M, which is close to it, and by
BT.601 otherwise, in the range they say.
