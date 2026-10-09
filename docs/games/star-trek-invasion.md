# Star Trek: Invasion

Star Trek: Invasion (Activision, 2000) is a PlayStation game by Warthog, who developed StarLancer.
Its missions have StarLancer's `.DTE` format and script bytecode, while its archive and models are
its own and its pictures are the PlayStation's. `sltool trek` reads its files. OpenReliant doesn't
play them: [#181](https://github.com/OpenReliant/openreliant/issues/181) compares the two games,
which shows what a shared engine would have to keep apart.

```bash
sltool trek ls <image>                    # the archive's files, with their names
sltool trek extract <image> <dir>         # copy them out
sltool trek sections <mission.dsm>        # a mission's directory
sltool trek strings <mission.dsm>         # its string pool
sltool trek parts <mission.dsm>           # its script's named routines
sltool trek script <mission.dsm>          # its script, disassembled
sltool trek chunks <model.trk>            # a model's chunks
sltool trek textures <model.trk> <dir>    # its textures, as PNG files
sltool tim png <picture.tim> <out.png>    # a picture, as a PNG file
```

The code is in [`src/formats/games/trek/`](../../src/formats/games/trek), and the PlayStation's
own formats are in [`src/formats/playstation/`](../../src/formats/playstation).

## The disc

The North American disc, `SLUS-00924`, is one Mode 2 data track. Its ISO 9660 volume holds four
files:

| Path | Contents |
|---|---|
| `SYSTEM.CNF` | The console's boot file, which names the executable: `BOOT = cdrom:\SLUS_009.24;1`. |
| `SLUS_009.24` | The executable ([PlayStation formats](../formats/playstation.md#executables)). |
| `STARTREK.RES` | The archive: every other file of the game. |
| `CDPAD.PAD` | **Unverified:** padding, as its name says. |

The archive holds Form 2 sectors, which `sltool cd extract` copies as whole Mode 2 sectors
([Disc images](../formats/disc-images.md#image-layout)).

## The archive

`STARTREK.RES` starts with an index of 8-byte slots:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | The sector the file starts at, from the start of the archive |
| 4 | 4 | The file's size in bytes |

A slot of size 0 is empty. The first slot's file starts right after the index, so its sector is
the index's length in sectors: three sectors, 768 slots, on the North American disc.

The archive doesn't name its files. The executable has a table of pointers to their names, in slot
order, such as `TRK\KJ_FA.TRK` or `\FRONTEND.OVL` for a file at the top. `sltool` finds the table as
the longest run of pointers in the text to names of files.

Most files are logical blocks. The films and the music also hold Form 2 sectors of streamed
audio, and their sizes count whole Mode 2 sectors of 2336 bytes rather than logical blocks.
`sltool trek extract` writes them as whole Mode 2 sectors, which PlayStation tools read.

| Extension | Contents |
|---|---|
| `.TRK` | Models ([Models](#models)). |
| `.DSM` | Missions ([Missions](#missions)). |
| `.TIM` | Pictures ([TIM pictures](../formats/playstation.md#tim-pictures)). |
| `.TGA` | Pictures, as uncompressed true-colour TGA files. |
| `.STR` | Films, streamed. |
| `.XAR` | Music, streamed as XA audio. |
| `.MMF` | Streamed files that start `FMMW`. **Unknown:** what they hold. |
| `.OVL` | `FRONTEND.OVL` and `GAME.OVL`. **Unverified:** code overlays. |
| `.BUL`, `.TEX`, `.SGD`, `.SMP`, `.XAD`, `.TOP`, `.BOT`, `.INF`, `.CNF` | **Unknown.** |

## Missions

A `.DSM` mission has StarLancer's layout ([`.DTE` missions](../formats/dte.md#directory)): a
directory of sections, then the sections. The directory has 128 entries of StarLancer's form, which
fill the first 1024 bytes, and the sections come in another order. Every mission uses
entries 0 to 22 and leaves the rest unused.

| Section | Stride | Contents | StarLancer's section |
|---|---|---|---|
| 0 | 4 | **Unknown.** | |
| 1 | 1 | The string pool. | `strings` (0) |
| 2 | 36 | **Unknown.** | |
| 3 | `0x44` | The ships. A ship names its model by a string offset at `+0`, such as `VALKA` for the model `TRK\VALKA.TRK`, and its name by one at `+4`. It places the model with whole numbers rather than floats. | `ships` (3), laid out otherwise |
| 4 | `0x14` | The flight groups. | `flight_groups` (4) |
| 5 | `0x0C` | **Unverified:** the globals. Each starts with a name's string offset and holds a value, as StarLancer's do. | |
| 6 | `0x30` | The triggers. | `triggers` (5) |
| 7 | 2 | The script, counted in halfwords. | `script` (6) |
| 8 | 8 | The objects. | `objects` (7) |
| 9 | `0x1C` | The parts. | `parts` (8) |
| 10 | `0x0C` | **Unknown.** | |
| 11, 15 | `0x44` | Records in the shape of StarLancer's curves, with whole numbers in place of floats. **Unknown:** what each section's records are for. | |
| 12 | `0x1C` | **Unverified:** a second part table, as StarLancer's `parts_b`. | |
| 13 | 2 | **Unverified:** a second script, as StarLancer's `script_b`. | |
| 14 | 52 | **Unknown.** | |
| 16, 17 | `0x0C` | **Unknown.** | |
| 19 | `0x10` | **Unknown.** | |

`sltool trek` reads the sections that hold StarLancer's records with StarLancer's mission reader,
which it points at them.

The script has StarLancer's bytecode ([Script VM](../engine/script-vm.md)): every instruction the
routines reach is one of StarLancer's. The parts' names show the same mission editor, such as
`StartUp` or `CamValkyrie1Stuff`, and the string pool holds names such as `Curve1_Join1_Point2`.
The Executor's commands differ. Commands `0x01` to `0x03` are StarLancer's `CreateTimer`,
`DestroyTimer` and `CreateFlightGroup`, and the scripts call commands up to `0x80`. `sltool trek
script` shows the commands by number. **Unknown:** what Invasion's other commands do.

## Models

A `.TRK` model is a header, then chunks, each a four-letter id, a length and that many bytes, as in
RIFF. Every chunk's length is a multiple of four. The last chunk is `FINI`, and the archive pads the
file after it.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `TREK` |
| 4 | 4 | The length of the file up to the end of `FINI` |
| 8 | 4 | The model's number, different in each model; absent in `WARP.TRK` |

| Chunk | Contents |
|---|---|
| `MODL` | A mesh. **Unknown:** its layout. |
| `ENGI` | **Unknown.** |
| `LODC` | **Unknown.** It holds a date as text, such as `9th February 2000, 15.30`. |
| `COLL` | **Unknown.** |
| `TEXS` | **Unknown.** It starts with the number of textures. |
| `TIMS` | A texture, as a TIM picture ([TIM pictures](../formats/playstation.md#tim-pictures)). |

**Unverified:** how the game tells a model without a number. `sltool` reads four capital letters
after the length as the first chunk's id.
