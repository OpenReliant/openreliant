# `.SPR` sprites

The game's 2D imagery, drawn by WinVFX: the sprite sets in `resource.hog`.

These are the interface, not the world: the HUD, menus, cursors, briefing and loadout screens, the
news reader, kill tallies, and a per-ship schematic. They are **not** model textures, which is
covered under [What sprites are not](#what-sprites-are-not).

```bash
sltool spr info <sprite>                # what the set contains
sltool spr ls <sprite>                  # every block, with kind and size
sltool spr extract <sprite> <out-dir>   # every shape as an indexed PNG, as a mod names it
make sprites                            # every shape into game/sprites
```

## Layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `1.40`, stored as four raw bytes rather than a number |
| 4 | 4 | Block count |
| 8 | 8 x count | Directory: a `u32` offset and a `u32` that is **zero in every entry of every file** |

Entries are in ascending offset order, so a block runs from its own offset to the next one, or to
the end of the file.

## Blocks

Nothing records what a block is, and three kinds occur. They have to be told apart by structure:

| Kind | Recognised by |
|---|---|
| Shape | Parses as a shape header whose rows fit inside the block |
| Palette | 768 bytes whose every byte is a 6-bit level, so never above `0x3F` |
| Remap table | 256 bytes, the remainder |
| Placeholder | Neither, and carries no rows |

Size alone will not separate them: some shipped shapes are exactly 768 or 256 bytes long. The
palette test is what resolves it, since every such shape contains `0xFF`.

The placeholders hold bounds near `maxInt(i32)` and no pixel data. They occur in `LAUNCH.SPR`,
`ifhard.spr` and `ifsoft.spr`.

A remap table maps each palette index to another. The HUD sets open with a run of them, the first
being the identity, `00 01 02 ... FF`.

### Shape

| Offset | Type | Field |
|---|---|---|
| `0x00` | u16 x2 | What `VFX_shape_bounds` returns: a height in the low half and a width in the high. For the pause menu's shapes, `y2 + 1` and `x2 + 1`; constant across a file in the ship schematics |
| `0x04` | u16 x2 | What `VFX_shape_origin` returns, down in the low half and across in the high, which the pause menu adds to where it draws a shape: (1, 1) for each of its shapes |
| `0x08` | i32 x4 | `x1`, `y1`, `x2`, `y2`, inclusive |
| `0x18` | | The rows |

Bounds are signed and can be negative, which is how a sprite is centred on its anchor rather than
its corner. Width is `x2 - x1 + 1`.

### Rows

One run-length encoded row per scanline, top to bottom. Each opcode starts with a control byte
whose low bit picks the kind and whose upper seven bits are a count:

| Control byte | Meaning |
|---|---|
| `0x00` | End of row. The rest of the row stays transparent. |
| Even, count > 0 | Repeat the next byte `count` times |
| Odd, count > 0 | Copy the next `count` bytes |
| `0x01` | Skip the next byte's worth of pixels, leaving them transparent |

Pixels are palette indices and **index 0 is transparent**.

## Palettes

A palette is 256 RGB triples at 6 bits per channel, the VGA convention. Expanding to 8 bits by
repeating the top bits into the bottom keeps full scale full: `(v << 2) | (v >> 4)`.

A file may carry several, and a shape uses the nearest one at or before it, so a set can hold
groups that each have their own. `CAPSHIPS.SPR` is a run of such groups, each a palette and two
ships, so a pair of ships shares a national colour scheme.

**Most sets carry no palette at all**, including every ship schematic. Those shapes are drawn with
whatever palette the game has loaded, and `sltool spr extract` falls back to greyscale for them.

**Unknown:** which palette that is. It is not the first 768 bytes of `palette.ccb`: those are 6-bit
values, but they colour the schematics as noise while leaving the silhouettes clean.

## What sprites are not

None of the textures the `.SHP` models name is a sprite set:

- **No model texture name matches any `.spr`**, under any prefix.
- Most sets are named `<ship>SCEM.SPR`: small, one per ship, the schematic shown in the interface.
- The rest are named for their screens: `BRIEF`, `FRONTEND`, `HUDHARD`, `LOADOUT`, `CURSORS`,
  `NEWSREP`, `KILLS`, `LAUNCH`, `CAPSHIPS`.

The models' textures are in the [texture caches](tcache.md).

## Prior art

The RLE encoding and the shape header were decoded by
[DMJC's StarLanceDecomp](https://github.com/DMJC/StarLanceDecomp) from
`VFX_shape_blit_unclipped` in `WINVFX8.DLL`, which also identified the palette blocks and the
nearest-preceding-palette rule. Everything above was re-derived against the 269 shipped files; the
remap tables, the placeholders, the palette content test that separates blocks whose sizes collide,
and the texture findings are additions.
