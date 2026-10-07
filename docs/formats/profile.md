# The pilot's profile

`profile.bin` in the game's folder holds the pilot's profile: the 0xD0 bytes the game keeps at
`profile` (`0x00562CF8`), written as they lie in memory, little-endian (`profile_save`,
`0x004753F0`). Its fields are those at the start of a saved game's `MISS` record, without the
multiplayer deaths ([Saved games](save.md)).

| Offset | Size | Holds |
|---|---|---|
| `0x00` | 4 | The mission the campaign had moved on to when a mission's end last copied the campaign in (`mission_number`); 0 in a new profile |
| `0x04` | 32 | The pilot's call sign, up to its terminator |
| `0x24` | 4 | The pilot's rank, 0 to 8 (`pilot_rank`) |
| `0x28` | 4 | The campaign's tier (`campaign_tier`) |
| `0x2C` | 4 | The pilot's kills over the campaign (`skull_count`) |
| `0x30` | 6 × 4 | The pilot's medals, 1 where awarded (`pilot_medals`) |
| `0x48` | 6 × 4 | The pilot's ribbons, 1 where awarded (`pilot_ribbons`) |
| `0x60` | 28 × 2 | Each mission's rating, by its number less one, -1 for none (`mission_ratings`) |
| `0x98` | 28 × 2 | The pilot's kills in each mission, by its number, missions 0 to 27 (`mission_kills`) |

`resource.hog` holds a `profile.bin` too, which the game never reads: it opens the one in its
folder ([Hog archives](hog.md)).

## When the game reads and writes it

- `campaign_new` reads it (`profile_load`, `0x00475390`) as the game starts, as the main menu
  opens and as START GAME begins a campaign, and the pilot takes its call sign. Where the game's
  folder has none, it makes a new one named PLAYER (string `0xBF`), with no mission rated and the
  rest 0, and writes it; the call sign then stays as it was.
- The game copies the call sign into the profile and writes it as the pilot roster's call sign
  changes, as the Reliant's rooms open, and last in each mission's start.
- Each mission's end that moves the campaign on to the next mission copies the campaign into the
  profile after the autosave, and writes it (`mission_end_record`, `0x00475C2D`). The last
  mission, which leads to the story's end, leaves it as it was.
- Before a campaign mission of a network game, `WinMain` reads it and puts the pilot's rank, tier,
  kills, medals, ribbons, ratings and each mission's kills back into the campaign
  (`0x004A99CC`). The multiplayer screens write it with the call sign too.

## In OpenReliant

[`game/gameflow.zig`](../../src/engine/game/gameflow.zig) holds the profile (`Profile`), and reads
and writes the file whatever the case of its name (`ProfileFile`). The pilot roster, the rooms,
each mission's start and each mission's end write it as the game does.

- **Improvement:** OpenReliant writes the file only where the profile has changed since it was last
  read or written. The game writes it again in each pass of the pilot roster while the pointer's
  button is held anywhere off the call sign.
- **Fix:** the call sign the profile gives ends with its 32 bytes, where the game copies the name
  up to its terminator wherever that lies.

Not ported: a network game's campaign mission, which reads the profile back
([#804](https://github.com/OpenReliant/openreliant/issues/804)).
