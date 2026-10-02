# RefPack compression

Most members of `resource.hog` are compressed with **RefPack**, Electronic Arts' LZ77 variant, also
called QFS and named FB10 after the two bytes its header starts with.

A stream is a sequence of commands. Each copies a short run of literal bytes straight from the
input, then usually repeats a run of bytes that already appeared in the output. Four command
encodings cover progressively longer matches and distances, and a fifth ends the stream.

## Header

| Size | Field |
|---|---|
| 1 | Flags |
| 1 | `0xFB` |
| 3 or 4 | Compressed size, only when the flags say so |
| 3 or 4 | Decompressed size |

Sizes are big-endian. The flag bits that matter:

| Bit | Meaning |
|---|---|
| `0x01` | A compressed size precedes the decompressed size |
| `0x80` | Sizes are 4 bytes rather than 3 |

Every stream in this game uses `10 FB`: neither bit set, so the header is five bytes and carries
only the decompressed size. It is also the one form the game expands: `hog_read_file`
(`0x004C7F60`) reads a member's first two bytes big-endian and compares them with `0x10FB`, and
takes any other member as it is stored. `refpack.gameExpands` makes the same test. The longest
header, with both bits set, is ten bytes.

## Commands

The first byte selects the encoding. In the table, *literals* is how many bytes are copied from the
input before the match, *length* is how many bytes the match repeats, and *distance* is how far
back in the output it starts.

| First byte | Bytes | Literals | Length | Distance |
|---|---|---|---|---|
| `0x00`-`0x7F` | 2 | `b0 & 3` | `((b0 >> 2) & 7) + 3` | `((b0 & 0x60) << 3) + b1 + 1` |
| `0x80`-`0xBF` | 3 | `(b1 >> 6) & 3` | `(b0 & 0x3F) + 4` | `((b1 & 0x3F) << 8) + b2 + 1` |
| `0xC0`-`0xDF` | 4 | `b0 & 3` | `((b0 & 0x0C) << 6) + b3 + 5` | `((b0 & 0x10) << 12) + (b1 << 8) + b2 + 1` |
| `0xE0`-`0xFB` | 1 | `((b0 & 0x1F) << 2) + 4` | none | none |
| `0xFC`-`0xFF` | 1 | `b0 & 3` | none | none, and the stream ends |

So the reachable ranges are matches of 3 to 10 within 1 KiB, 4 to 67 within 16 KiB, and 5 to 1028
within 128 KiB; literal runs are 4 to 112 bytes and always a multiple of four, except for the up to
three literals a short match or the final command can carry.

A match may overlap the bytes it is producing. A distance of one with a length of five repeats the
previous byte five times, so the copy has to proceed one byte at a time rather than as a block
move.

## Decompressing

```bash
sltool hog extract <archive> <dir>     # decompresses members as it extracts
```

The decompressor is `src/formats/refpack.zig`. It validates as it goes: a command that runs past
the end of the input, a match reaching before the start of the output, or a total that disagrees
with the header's decompressed size are all rejected rather than producing truncated output.

Every compressed member of `resource.hog` decompresses to exactly the size its header declares.

## Compressing

`refpack.compressAlloc` writes a stream of the one form the game expands: `10 FB`, a 3-byte size,
the commands, and a terminator with nothing after it. It is a lazy parse over hash chains, not EA's
compressor, so its streams differ from the shipped ones while expanding to the same bytes. Each
match takes the smallest form that holds it, as every match in the shipped streams does. Matches
reach back at most 131071 bytes, the furthest the shipped streams go, though the long form's field
holds one more.

Literals are written as runs of 4 to 112 bytes, and the last 0 to 3 before a match ride in its
command, or in the terminator at the end. A payload of 16777216 bytes or more has no stream: the
game reads only 3-byte sizes.

The encoder keeps `inPlaceExcess` as it writes, from what each command stands for, rather than
reading its stream back. `refpack.Compressor` compresses one payload after another with the same
match finder, as the `.HOG` writer does for an archive's members; `compressAlloc` is one for a
single payload.

### What the game's expansion demands

`hog_unpack` (`0x004C8480`) allocates the expanded size plus `0x2800` bytes, reads the stream to the
end of that block, and calls `refpack_expand` (`0x004CC350`) to expand it from the start of the same
block. The expansion checks nothing, so a stream loads only where the output never overtakes the
input still to read. At the start of the stream, and after each command, the input still to read
less the output still to write is at most `0x2800`: `refpack.inPlaceExcess` is the largest of those
values. Two shapes break it. A stream longer than its data by more than `0x2800` puts the read
before the block. Or a run of matches puts the output far ahead, and literals then take the input
past it, after which the expansion reads its own output as commands and overwrites the heap.

The literals of a payload that does not compress take 1 byte in 112 for their control bytes, so
`compressAlloc` fails with `error.NotInPlace` for one of 1146212 bytes or more, and for a
compressible one with a tail of that size. Every shipped stream keeps within the bound, the
tightest, `smp3d.fat`, at 486.

Where there is no stream, or none that loads, the member is stored as it is, which the game reads
verbatim. A payload that itself begins `10 FB` cannot be stored so: the game would take it for a
stream. `refpack.loadsInPlace` tells whether a stream expands to its declared size within the
bound, which the `.HOG` writer checks before it keeps a member that begins `10 FB`
([writing an archive](hog.md#writing-an-archive)).

The flags byte of a stream must be exactly `0x10`. `hog_read_file` expands a member only when it
begins `10 FB`, and `refpack_expand` takes bit 0 as the compressed size's presence, which would
make it read that size as the expanded one, and has no path for bit 7 (4-byte sizes), which is why
a member holds at most 16777215 bytes.

The bound, its two shapes and the shipped streams' values are from a comment on
[#113](https://github.com/OpenReliant/openreliant/issues/113) by the
[Starlancer-OSS](https://github.com/LordBlacksun/Starlancer-OSS) project (its documentation is
licensed CC BY 4.0), which ran `refpack_expand` on generated streams under emulation: 1146211 bytes
of literals load and 1146212 do not, and neither does 2000000 zero bytes followed by a tail of
literals that takes the input 2 bytes past the slack. **Unverified:** here, where OpenReliant cannot
run `refpack_expand`; the tests check `inPlaceExcess` against the same figures.
