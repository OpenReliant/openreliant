# Xbox formats

The Xbox games on StarLancer's engine, such as
[Battlestar Galactica](../games/battlestar-galactica.md), come on discs with the Xbox's own
filesystem and executable. The code is in [`src/formats/xbox/`](../../src/formats/xbox).

```bash
sltool cd ls <image>              # every file
sltool cd extract <image> <dir>   # copy everything off
```

## Discs

An Xbox disc holds an XDVDFS volume of 2048-byte sectors. An image that `extract-xiso` writes holds
the volume alone, which `sltool cd` reads. **Not supported:** a whole disc's image, which holds
more than the game's volume ([#1019](https://github.com/OpenReliant/openreliant/issues/1019)).
The volume descriptor is at the volume's sector 32:

| Offset | Size | Field |
|---|---|---|
| 0 | 20 | `MICROSOFT*XBOX*MEDIA` |
| 20 | 4 | The root directory's first sector |
| 24 | 4 | The root directory's size in bytes |

A directory is a binary tree of entries sorted by name, each 4-byte aligned, and an empty one holds
one entry of `0xFF` filler:

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | The left subtree's offset in the directory, in 4-byte units; 0 or `0xFFFF` for none |
| 2 | 2 | The right subtree's offset, likewise |
| 4 | 4 | The first sector of the file or directory |
| 8 | 4 | Its size in bytes |
| 12 | 1 | Attributes: `0x10` for a directory |
| 13 | 1 | The name's length |
| 14 | | The name |

## Executables

An Xbox executable, `default.xbe`, starts with a header that places its sections in memory:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `XBEH` |
| `0x104` | 4 | The base address: the header loads there |
| `0x11C` | 4 | The count of sections |
| `0x120` | 4 | The address of the section headers |

The header's addresses are in memory, from the base address. A section header is `0x38` bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Flags |
| 4 | 4 | The section's address in memory |
| 8 | 4 | Its size in memory |
| 12 | 4 | Its offset in the file |
| 16 | 4 | Its size in the file |
| 20 | 4 | The address of its name |
