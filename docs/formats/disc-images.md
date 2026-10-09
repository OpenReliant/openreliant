# Disc images and the disc filesystem

The game ships on two CDs. This project reads disc images directly: `sltool cd` parses the sector
framing and the ISO 9660 filesystem itself, so extraction needs no mounting, no conversion to
`.iso`, and no third-party tool.

## Image layout

Redump-style images store **complete 2352-byte sectors** (`MODE1/2352` in the accompanying cue
sheet), not the 2048-byte user data that an `.iso` holds. A Mode 1 sector is:

| Offset | Size | Field |
|---|---|---|
| 0 | 12 | Sync pattern: `00 FF FF FF FF FF FF FF FF FF FF 00` |
| 12 | 3 | Address, as minutes / seconds / frames in BCD |
| 15 | 1 | Mode |
| 16 | 2048 | User data: one logical block |
| 2064 | 288 | EDC and ECC |

Addresses count 75 frames to the second and start after a two-second pregap, so logical block 0 is
at `00:02:00` and the ISO 9660 primary volume descriptor, at block 16, is at `00:02:16`.

`sltool` detects the layout from the first twelve bytes: an image that starts with the sync pattern
is raw, anything else is treated as 2048-byte logical blocks. EDC and ECC are not checked.

PlayStation discs use Mode 2 sectors (`MODE2/2352`). After the header comes a 4-byte subheader,
stored twice, whose submode byte says which form the sector has:

| Offset | Size | Field |
|---|---|---|
| 0 | 16 | Sync pattern, address and mode, as in Mode 1 |
| 16 | 8 | Subheader, stored twice |
| 24 | 2048 | Form 1: one logical block, then 280 bytes of EDC and ECC |
| 24 | 2324 | Form 2: streamed audio or video, then 4 bytes of EDC |

Bit 5 of the submode marks Form 2. A Form 2 sector carries no logical block, so reading one as a
block fails, and so does a Mode 0 sector. `sltool cd extract` copies a file that holds any Form 2
sector as whole Mode 2 sectors: the 2336 bytes after each sector's header, which PlayStation tools
read. [Star Trek: Invasion](../games/star-trek-invasion.md#the-disc)'s disc holds such a file.

## Filesystem

Both discs carry a plain ISO 9660 filesystem with no Joliet supplementary descriptor, so all names
are 8.3 and upper case, with the `;1` version suffix that `sltool` strips. `sltool` reads Joliet
names where a disc has them.

| Disc | Label | Blocks | Size |
|---|---|---|---|
| 1 | `SL_CD1` | 331,659 | 648 MiB |
| 2 | `SL_CD2` | 279,922 | 547 MiB |

### Disc 1

| Path | Size | Contents |
|---|---|---|
| `LANCER.CAB` | 226,746,308 | Installer cabinet: the game as installed. |
| `GAME/CD1.HOG` | 406,051,549 | Asset archive. |
| `GAME/CAB/LANCER.EXE` | 249,119 | SafeDisc loader. |
| `GAME/CAB/LANCER.ICD` | 1,151,021 | The game, encrypted. |
| `GAME/CAB/LANGUAGE.DLL`, `ITACLANG.DLL` | | Language resources. |
| `SETUP.EXE`, `SETUPENU.DLL`, `SETUPAPI.DLL` | | Installer. |
| `DPLAYERX.DLL`, `CLCD16.DLL`, `CLCD32.DLL`, `CLOKSPL.EXE`, `DRVMGT.DLL`, `SECDRV.SYS` | | SafeDisc support files. |
| `DIRECTX/`, `GOODIES/` | | DirectX 7 redistributable, MSN Gaming Zone client, diagnostics. |

### Disc 2

| Path | Size | Contents |
|---|---|---|
| `GAME/CD2.HOG` | 535,385,670 | Asset archive: later missions and video. |
| `DOCS/MAUNAL.PDF`, `DOCS/QRC.PDF` | | Manual and reference card. The manual's filename is misspelled on the disc. |
| `GOODIES/` | | Acrobat Reader, MSN Gaming Zone client. |

`GAME/CD1.BIN` and `GAME/CD2.BIN` are zero-length disc-identification markers.

## Using it

```bash
sltool cd info <image>            # layout, block count, volume label
sltool cd ls <image>              # every file, with size and timestamp
sltool cd extract <image> <dir>   # copy everything off
```

`sltool cd` also reads Xbox discs, as `extract-xiso` writes their images
([Xbox formats](xbox.md#discs)).

`make game` runs the extraction for both discs, then installs `game/install/` from them with
`openreliant install`, which unpacks disc 1's `LANCER.CAB`, an LZX-compressed Microsoft cabinet, and
copies both discs' archives ([Platform](../port/platform.md#installing-the-games-files)).
