# `.HOG` archives

The game's assets live in `.HOG` files, which use Electronic Arts' **`BIGF`** container. A 16-byte
header is followed by a directory, then the members packed back to back with no padding and no
alignment.

Every integer in the container is **big-endian**.

```bash
sltool hog info <archive>              # size, member count, how much is compressed
sltool hog ls <archive>                # offset, stored size, real size, name
sltool hog extract <archive> <dir>     # decompressing by default; --raw to keep members as stored
sltool hog pack <dir> <archive>        # pack a folder's files; --store: compress only what must be;
                                       # --checksum: write <archive>.sha256 beside it
make assets                            # extract resource.hog and pilots.hog into game/assets
```

## Header

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `BIGF` |
| 4 | 4 | Total archive size, which equals the file's own size in every shipped archive |
| 8 | 4 | Entry count |
| 12 | 4 | Offset where the directory ends and the first member begins |

## Directory

Entries follow the header at offset 16, packed with no alignment:

| Size | Field |
|---|---|
| 4 | Member offset from the start of the file |
| 4 | Member size as stored, which is the compressed size for a compressed member |
| n+1 | Name, NUL-terminated |

Entries are variable-length, so the directory can only be read by walking it; there is no index.

Names form a flat namespace with no directories and no path separators, and are not normalised:

- **Case is inconsistent.** `interpal.TGA` and `interpal.tga` are different members of
  `resource.hog`.
- **Names may contain spaces**, for example `Boridin gun dest.SHP`.
- **Names are not unique.** Some names in `resource.hog` appear twice, and the two members are
  usually different sizes, so they are different assets rather than redundant copies. `sltool hog extract` gives the later member a `~2` suffix before
  its extension so nothing is lost, including where two names differ only by case and would
  collide on a case-insensitive filesystem.

### Trailing filler

Two of the five shipped archives, `msspeech.hog` and `pilots.hog`, count one more entry in their
header than their directory holds.

The extra record is `0xCD` filler, the pattern MSVC writes over uninitialized memory, and it sits
past the end of the real directory. The members themselves are unaffected: in every archive they
form one contiguous run from the header's data offset to the last byte of the file, with no gaps. A reader should validate each entry and stop at the first one that is not a plausible
record, rather than trusting the count.

## The shipped archives

| Archive | Compressed | Contents |
|---|---|---|
| `resource.hog` | Almost every member | Models, sprites, images, missions, stat tables, sound banks, fonts |
| `pilots.hog` | No | `.fm8` face films ([face films](fm8.md)) |
| `msspeech.hog` | No | Speech, one member per line, no extensions ([speech files](speech.md)) |
| `CD1.HOG` | A few sprites | Bink video, briefings (`.box`), the debriefings' MP3 lines, sprites, sound banks |
| `CD2.HOG` | No | Bink video, briefings (`.box`), the debriefings' MP3 lines, sprites, sound banks |

The game opens the discs' archives one at a time, as it needs them (`cd_hog_open`,
[Movies](../engine/movies.md#the-discs-archives)), and Bink reads a movie from one as it is
stored (`hog_locate`).

OpenReliant's mods, which are archives in this format or folders of files, replace the files with
the same names in any of these archives and among the game's loose files
([Modding](../guide/modding.md)).

`resource.hog`'s members by extension: `.shp` models, `.spr` sprites, `.tga` images, `.dte`
missions, `.fat` [sound banks](fat.md), `.fnt` [fonts](fnt.md), `.ccb` colour tables, and five `.bin` files:
the four stat tables and a `profile.bin`, which the game never reads ([The pilot's profile](profile.md)).

## Reading a file

`hog_read_file` (`0x004C7F60`) reads a member by a name the game's code gives, such as
`ms_speech\ms1_ban_001.ut`:

1. It copies the name and cuts it at its first dot when `ut` follows, with case: `x.ut.wav` becomes
   `x`, while `name.UT` and `a.b.ut` stay whole.
2. It keeps what follows the last backslash, looking from the second character on. Only `\`
   separates folders here.
3. It finds that member in any case (`hog_seek`, `0x004C8370`).
4. It expands the member only when it starts `10 FB` (`hog_unpack`, `0x004C8480`), and returns any
   other member as it is stored, whatever its second byte.
5. A missing member stops the game with `HOG_bigread2: error loading %s.`

`hog_read_file_as_named` (`0x004C8110`) skips the `ut` cut, and `hog_file_size` (`0x004C81F0`)
takes the name whole.

**Fix:** the game copies the name into a 128-byte buffer without a limit, so a longer name
overruns its stack. OpenReliant cuts it to 128 bytes
([`bigfile.memberName`](../../src/engine/game/bigfile.zig)). Where a radio line is missing,
OpenReliant warns and leaves the line out instead of stopping.

OpenReliant opens an archive whose name differs in case, as Windows does (`hog_open`, `0x004C7E20`,
`bigfile.openArchive`).

## Writing an archive

`hog.build` lays an archive out as the shipped ones are: the header, a record and a name for each
member in the order given, then the members back to back from the header's data offset to the end
of the file, with no trailing filler. A name is one or more bytes of printable ASCII, as the
directory's reader takes it (`hog.validName`). Names are not made unique.

`sltool hog pack` makes an archive of every file of a folder, each a member of its own name, in
name order. It stores each member as `hog.packMember` finds best:

- A RefPack stream ([compressing](refpack.md#compressing)) where one is smaller and the game can
  expand it in place, and otherwise, or with `--store`, the file as it is, which the game reads
  verbatim.
- A file that begins `10 FB`, whatever the packing: the game takes it for a stream. It goes in as
  it is only where it is one that expands to its declared size in place
  (`refpack.loadsInPlace`), as `sltool hog extract --raw` gives a packed member. A stream over the
  bound, from another tool say, would overwrite the heap as the game loads it, so what it expands
  to is packed in its place. A file that is no such stream but only begins as one is compressed,
  having no form the game reads as it is. Where no stream of it loads, the pack fails.
- Movies (`.bik`) and face films (`.fm8`) as they are, whatever they begin with: the game reads
  both where they lie. Bink opens a movie in the archive once `hog_locate` (`0x004C83F0`) has found
  it, and `hudmovie_play` (`0x0048D120`) finds a film with `hog_seek` (`0x004C8370`) and reads it
  from the archive's file where the seek leaves it. Neither goes through `hog_read_file`, the one
  path that expands a packed member.

The `~N` suffix `extract` gives a repeated name stays in the member's name.

With `--checksum`, `pack` also writes a checksum file next to the archive, named after the archive
plus `.sha256`, in the format `sha256sum` uses. OpenReliant checks a mod's archive against it when
it loads the mod ([Modding](../guide/modding.md#checksums)).

## RefPack compression

Compressed members begin with `10 FB` and are decompressed transparently by `sltool hog extract`.
The codec is EA's **RefPack**, also called QFS, and named FB10 after those two bytes. See
[`refpack.md`](refpack.md).

Compression is per member, not per archive, and is a property of the archive rather than of the
file type: the same extensions appear compressed in `resource.hog` and uncompressed on the discs.
