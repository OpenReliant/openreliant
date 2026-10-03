# Saved games

A saved game is an IFF file in the `saves` folder of the game's folder,
`saves\<call sign>GAME<slot>.IFF`: the call sign as the pilot typed it, then the slot in two
digits at least (`0x004E86E4`). `game_save` (`0x00475650`) writes it and `game_load`
(`0x00475430`) reads it; the saved games screen lists and chooses them
([Front end](../engine/front-end.md#the-saved-games)).

```bash
sltool save info <file.IFF>   # everything a saved game holds, field by field
sltool save ls <folder>       # the saved games in a folder: each one's name, mission and pilot
```

| Slot | Saved game |
|---|---|
| 0 | The autosave, which each mission's end writes as the campaign moves on (`mission_end_record`, `0x00475C28`) |
| 1 to 99 | The player's, which the saved games screen saves |
| 100 | The restart point, named `restart`, which `WinMain` writes as each attempt at a mission begins (`restart_save`, `0x00475D20`) and reads back for a replay (`restart_load`, `0x00475D30`) |

## In OpenReliant

[`game/gameflow/save.zig`](../../src/engine/game/gameflow/save.zig) writes and reads the files
(`save.write`, `save.read`), takes the records from the campaign as OpenReliant holds it and puts
them back (`save.Game`), and finds the files in the game's folder whatever the case of their names
(`save.Folder`), as the game's reader upper-cases every name it opens. The IFF reader is
[`game/iff.zig`](../../src/engine/game/iff.zig). OpenReliant writes the game's layout byte for
byte and reads what the game writes: a save of the original comes back out the same through
OpenReliant's campaign, but for the bytes the game leaves as its buffers held them, such as those
after the call sign's terminator, which OpenReliant writes as zeros.

- **Improvement:** OpenReliant keeps the restart point in memory, where the game writes it as slot
  100 and reads it back; and it makes the `saves` folder where the game's folder lacks it, which the
  game leaves to its installer, failing to save without it.
- **Fixes:** each record takes no more of its chunk than it holds, where the game reads each chunk
  by the length the file gives, so that a longer one runs on into what follows the record in
  memory. A rank, a tier, a ship or a missile past those the game has is taken as the nearest it
  has, or none. A file with no `SAVE` form loads nothing. A call sign with a character a file's name
  can't hold saves nothing, where the game would take a separator in it for a folder's. The game
  checks the disk by writing `0x1400` bytes to `saves\test.bin` before each save, then writes the
  save without checking it; OpenReliant checks the save's own write.
- **Improvement:** the mods' scripts keep their state with each saved game, in a file of the same
  name with the extension `.scripts` beside it (`save.companionName`), so that the saved game stays
  as the game writes it. The saves folder tells the driver as a game is saved, loaded or removed
  (`save.Extra`), and the driver writes, reads or removes that file
  ([Scripting](../port/scripting.md#saved-games)).
- The wing's pilots and the pool of their replacements live beside the campaign, as the game's
  globals do (`pilots.Wingmen`, [Objects](../engine/objects.md#the-wings-pilots)). A load puts
  back the wing and the pool's first record; the rest of the pool stays as the session left it.

## Layout

The file is one IFF form of type `SAVE`: `FORM`, the form's length big-endian, `SAVE`, then the
chunks. Each chunk is its id, its length big-endian, and that many bytes, which lie as the game
holds them in memory, little-endian, followed by a zero byte where the length is odd, which the
length leaves out and the form's counts. The form's length is the file's less 8, which `game_save`
writes as a zero first and sets once the chunks are written (`0x004758E4`).

`game_save` writes `NAME`, then the five records of its table (`save_chunks`, `0x00500A20`: an id,
an address and a size a record):

| Chunk | Size | Holds | In memory |
|---|---|---|---|
| `NAME` | The name's length and its terminator | The name the saved games list shows | |
| `MISS` | `0x17C` | The campaign as it stands | `0x00562DC8` |
| `VERS` | 4 | 1 (`save_version`), which nothing checks | `0x00562F44` |
| `VARS` | `0x78` | The game's variables the campaign keeps | `0x00562F78` |
| `PILO` | 4 | The first of the pool of pilots that replace the wingmen who die | `0x005047D0` |
| `ALPH` | `0xC` | The pilots of the player's wing | `0x0058A958` |

Every chunk but `NAME` has an even length, so a save whose name has `L` characters is
`580 + ((L + 2) & ~1)` bytes long.

`game_load` looks for each record's chunk from the form's first chunk, so that the chunks may come
in any order, the first of an id counts, and chunks it doesn't know, forms within the form too, are
passed over. A chunk the file lacks leaves its record as it was. It never reads `NAME`, which only
the saved games screen reads.

### MISS

The `0x17C` bytes from `mission_number` (`0x00562DC8`) to `save_version`:

| Offset | Size | Field |
|---|---|---|
| `0x000` | 4 | The mission the campaign is at, the next to fly (`mission_number`) |
| `0x004` | 32 | The pilot's call sign, up to its terminator (`call_sign`) |
| `0x024` | 4 | The pilot's rank, 0 to 8 (`pilot_rank`) |
| `0x028` | 4 | The campaign's tier, 0 to 3 (`campaign_tier`) |
| `0x02C` | 4 | The pilot's kills over the campaign (`skull_count`) |
| `0x030` | 4 | The local player's deaths in a multiplayer mission, 0 in single player (`mp_deaths`) |
| `0x034` | 24 | Medals 1 to 6, a word each, 1 where awarded (`pilot_medals`) |
| `0x04C` | 24 | Ribbons 1 to 6, a word each, 1 where awarded (`pilot_ribbons`); the game awards ribbons 1 to 5 |
| `0x064` | 56 | Each mission's rating, a halfword each by its number less one, -1 for none (`mission_ratings`) |
| `0x09C` | 56 | The pilot's kills in each mission, a halfword each by its number, missions 0 to 27 (`mission_kills`) |
| `0x0D4` | 56 | The campaign's pickups where a nanny ship picked the pilot up in each mission, by its number less one (`mission_pickups`) |
| `0x10C` | 2 | The times a nanny ship has picked the pilot up (`pickups`) |
| `0x10E` | 56 | The rank each mission's end promoted the pilot to, by its number less one, 0 for none (`mission_promotions`) |
| `0x146` | 2 | Unused |
| `0x148` | 4 | The seed of the ITAC's KILLBOARD (`killboard_seed`) |
| `0x14C` | 2 | The game's difficulty: 0 easy, 1 medium, 2 hard |
| `0x14E` | 2 | Whether the pilot is female (`pilot_female`) |
| `0x150` | 2 | The loadout's saved ship (`campaign_saved_ship`) |
| `0x152` | 40 | The loadout's saved racks, a missile each or -1 for none (`campaign_saved_racks`) |
| `0x17A` | 2 | Unused |

### VARS

Thirty words (`saved_variables`): the game's variables 16 to 21, 5, 22, 23, 6 to 8, 11 to 13, 24 to
27, 29 to 32, 34 and 36 in that order, which `game_save` copies in before it writes the chunk
(`0x004757A0`), then five words nothing writes, always 0. `game_load` clears variables 0 to 31,
then puts those back (`0x004754DA` on); variables 33, 35 and from 37 on keep what they held
([Script VM](../engine/script-vm.md)).

### PILO and ALPH

The pool of pilots that replace the wingmen who die (`pilot_pool`, `0x005047D0`) is 65 records of 4
bytes: a pilot, by the pilot stats' number (a halfword), a status (0 dead, 1 in the wing, 2 free)
and a byte nothing uses. `PILO` keeps the first record alone, as the game sends it alone to the
other players too (`0x004BA338`). **Unverified:** that the whole pool was meant, `0x104` bytes.

`ALPH` is the pilots of the player's wing, Alpha 1 to 6 (`alpha_pilots`, a halfword each): -1 for
the player, then the five wingmen's. A new campaign's are -1, `0x55`, `0x6C`, `0x56`, `0xAC` and 7
(`campaign_pilots_reset`, `0x0049CD20`).

## The autosave

As a mission's end moves the campaign on (`mission_end_record`), after the record, the medal's
ceremony and `update_pilots` (`0x0049CD70`), the game saves itself as slot 0, outside a network
session. Its name is the game's string `AUTOSAVE: Mission ` (`0x18A`) and the number the player sees
for the mission it has moved on to (`mission_display_numbers`, `0x004E5C78`), which counts the
campaign's missions in the order they are flown, so that mission 14 is `AUTOSAVE: Mission 12`. A
mission the pilot does not come through, mission 25's first part, and the last mission make none.

## The restart point

`WinMain` saves the game as slot 100 before each attempt at a mission of the campaign
(`0x004AA3FC`), and as a campaign starts or is loaded. The restart screen's REPLAY MISSION FROM
BRIEFING and FROM LAUNCH, the ITAC's REPLAY MISSION and the pause menu's RESTART each load it
(`restart_load`), which keeps the loadout's ship and racks as they stand
(`restart_choice_keep`, `0x00475D70`; `restart_choice_put_back`, `0x00475DA0`): a replay starts
from the game as the attempt began, the variables as a load leaves them, in the ship chosen last.
