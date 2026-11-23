# Fan translations

A fan translation changes the game's text and nothing else. The text is in two Windows modules
that hold only strings: `LANGUAGE.DLL`, the game's, and `ITACLANG.DLL`, the ITAC's. A translation
is those two modules made again in another language. `openreliant install --translation` writes
them over the ones in an install ([`install.zig`](../../src/openreliant/install.zig), `translate`).

OpenReliant knows two ([Supported editions](../guide/editions.md#fan-translations)):

| Translation | Comes as | `LANGUAGE.DLL` | `ITACLANG.DLL` | Code page |
|---|---|---|---|---|
| Spanish, by Clan DLAN | The two modules | 118,855 bytes | 441,856 bytes | 1252 |
| Slovak | A patcher, 495,444 bytes | 110,663 bytes | 577,594 bytes | 1250 |

## The code page

The game reads its strings with `LoadStringA`, which writes them in the system's code page. The
modules hold them as UTF-16, so OpenReliant picks the page from the letters they use
(`language.Page.of`): Cyrillic letters give 1251, a Latin letter that page 1250 has and 1252
lacks gives 1250, and anything else 1252. In the Slovak translation those letters are `č`, `ľ`,
`ĺ`, `ň`, `ŕ` and `Ť`.

The game's bitmap fonts have only page 1252's letters, and neither translation changes them. With
outline fonts the letters come from the built-in fonts ([Fonts](fnt.md#outline-fonts)). The
bitmap fonts draw a byte as the letter page 1252 has there, as the original does: `è` for `č`.

## The Slovak patcher

The Slovak translation is a Windows program, `StarLancer_SK.exe`, that patches an installed
English game. OpenReliant reads it as data ([`formats/patcher.zig`](../../src/formats/patcher.zig))
and never runs it. The addresses below are in that program.

**Unverified:** the product that made it. Its block numbers match those of Clickteam's installers.

### Blocks

After the program's last section comes a run of blocks. Each starts with this header:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | The block's number, `0x1234` to `0x1242`, or `0x7F7F` |
| `0x02` | 2 | 1 if its data is packed, 0 if not |
| `0x04` | 4 | How many bytes of data follow |

A packed block's data starts with its unpacked size, 4 bytes, and the rest is
[packed](#packing). OpenReliant reads two blocks:

- `0x1242` lists the files the patcher writes (`0x00407196`).
- `0x7F7F` holds the files' data and ends the blocks. Its data is 4 bytes of length, then that
  many bytes, to the end of the program.

### Files

The files block is a count, 4 bytes, then a record for each file:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | The record's size |
| `0x04` | 4 | Flags. **Unknown.** |
| `0x08` | 2 | The kind: `0x22` for a whole file, `0x21` for a patch |
| `0x0A` | 4 | A checksum. **Unknown:** how it is worked out. |
| `0x0E` | 4 | The file's size once written |
| `0x12` | 12 | **Unknown.** |
| `0x1E` | 24 | Three times, 8 bytes each |
| `0x36` | | The file's name, ending in a zero byte |

The record ends with 16 bytes:

| Offset from the end | Size | Field |
|---|---|---|
| `-0x10` | 4 | A checksum. **Unknown.** |
| `-0x0C` | 4 | For a patch, the size of the file it changes |
| `-0x08` | 4 | Where the file's data starts in the data block |
| `-0x04` | 4 | How many bytes it takes there |

A whole file's data is the file, [packed](#packing). A patch changes the file of its own name.
The patcher also carries that file whole, under its name with `.eng` added, which is the name it
keeps the replaced file under. OpenReliant makes a patched file from that copy
(`Patcher.write`), so the result doesn't depend on the install: any release gets the same two
modules.

### Patches

A patch's data is two pieces (`0x0040564B`): the commands, then the bytes they add. Each piece
starts with a byte of flags:

| Bit | Meaning |
|---|---|
| 0 | The piece is packed, and its packed size follows its size |
| 1 | Its size is 4 bytes, not 2 |
| 2 | Its packed size is 4 bytes, not 2 |

The commands build the new file from start to end (`0x004049D8`). The first byte of a command
says what it does:

| First byte | Adds | Copies |
|---|---|---|
| Top bit set, bits 5 and 6 clear | Its low 5 bits + 1 bytes | Nothing |
| Top bit set, bits 5 and 6 not clear | As many bytes as bits 5 and 6 say | Its low 5 bits + 2 bytes |
| 0 | Nothing | The next 2 bytes, little-endian, + `0x81` bytes |
| Any other | Nothing | The byte + 1 bytes |

Added bytes come from the second piece, in order. A copy takes bytes from the file being changed.
Its place follows the command, as a signed number counted from where the last copy ended, in one
of three forms:

| First byte | Form |
|---|---|
| Top two bits `10` | 6 bits, in this byte |
| Top bit `0` | 15 bits, in this byte and the next, then `0x20` further from zero |
| Top two bits `11` | 22 bits, in this byte and the next two, then `0x4020` further from zero. The value `0x100000` means the number follows as 4 bytes, big-endian |

### Packing

The patcher packs with deflate, changed in three ways (`0x004032C3`):

- A block starts with 3 bits for its kind, then the bit that marks the last block. The kinds are
  deflate's with 4 added: 5 for the fixed codes, 6 for codes of the block's own, 7 for stored
  bytes.
- The lengths of the code-length code come in the order 18, 17, 16, then 0 to 15.
- A stored block starts at the next whole byte with its length, 2 bytes, without the length's
  complement.
