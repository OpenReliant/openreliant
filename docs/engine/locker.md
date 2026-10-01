# The locker

The locker (`medal_display`, `0x004362F0`, `MedalDisplay` by its assertions) is the screen Open
Locker opens in the Reliant's rooms and the Yamato's ([The Reliant's rooms](rooms.md)). It runs in a
loop of its own over the lid's movie: the lid goes up, and the pilot's medals and ribbons come into
view with it. Its code lies within `C:\lancer\game\interface.cpp`.

## In OpenReliant

[`game/interface/locker.zig`](../../src/engine/game/interface/locker.zig) holds the locker, and
[`locker/tables.zig`](../../src/engine/game/interface/locker/tables.zig) the tables of where it
shows each award and how, which `tablegen locker` reads out of the executable
(`make locker-tables`). The driver runs its loop (`Driver.openLocker` in
[`openreliant/rooms.zig`](../../src/openreliant/rooms.zig)). The medals and ribbons are the
campaign's ([Saved games](../formats/save.md)).

**Fixes:**

- The lid's movies are each the locker's own. The game opens three of the four into another
  movie's handle (`bink_movie`, `0x005D6C40`) and goes on drawing and timing its own (`vr_movie`,
  `0x0051D7E8`), which then holds a movie already closed: the Reliant's lid going down, and the
  Yamato's going up and down.
- Past the end of its table, for a lid's movie longer than the game's, an award keeps the table's
  last shape. The game reads on past the table.

Its timer, 15 times a second (`0x00437DE0`), is left out: nothing it counts shows.

## The lid

On the Yamato the locker first plays `lockzomi.bik` over the screen, from the disc's archive. Then
the lid goes up: its movie plays from the disc's archive at 15 frames a second, with sound 5 of the
rooms' `wlksmp.fat`.

| Carrier | Up | Down |
|---|---|---|
| The Reliant, up to mission 18 | `rel_locklup.bik` | `rel_lockldo.bik` |
| The Yamato, after it | `locklidup.bik` | `lokliddo.bik` |

Once the lid is up, either button sends it down; so does Escape, at any time. The lid goes down in
its own movie, with sound 4, and the locker closes as it ends, or at once on Escape. The rooms then
go on with step 6 ([The loop](rooms.md#the-loop)); on the Yamato the view they go on in comes in
through `lockzomo.bik`. While the lid is up, 0 saves a screenshot ([Screenshots](screenshots.md)).

## The awards

As the lid goes up, the locker reads a set of shapes from the disc's archive for each medal and each
ribbon the pilot has, `%d` its number: on the Reliant `rmedal%d.spr` and `rbar%d.spr`, and on the
Yamato `medal%d.spr` and `bar%d.spr`. Each set is drawn in its own block 0's palette.

Its drawing (`medal_display_draw`, `0x00436B20`) shows each award at a place of its own, as the
shape its table gives for the lid's frame, none for 0. The frame (`0x005201AC`) steps with each frame
of the lid's movie but its last: up from -1 as the lid goes up, and down from 21 on the Reliant, 14
on the Yamato, as far as 0, as it goes down. The tables (`0x004E77C0` to `0x004E7B4C`) hold a row
for each of the six medals and the six ribbons on each carrier: 64 frames for the Reliant's medals,
23 for its ribbons, and 16 for the Yamato's.

With the lid up, the drawing writes the name of the award under the pointer, where the pilot has it,
and else Close Locker (`0xD5`), centred at (320, 440), in white, in the front end's large font. Then
it draws the pointer, the front end's. The pointer finds an award inside its rectangle, the edges
left out (`interface_hit`):

| Award | String | The Reliant's | The Yamato's |
|---|---|---|---|
| Medal 1, The Silver Cluster | `0x56A` | 79 by 43 from (226, 111) | 68 by 60 from (206, 154) |
| Medal 2, The Black Eagle | `0x56B` | 86 by 52 from (303, 132) | 72 by 62 from (291, 157) |
| Medal 3, The Medal of Valor | `0x56C` | 96 by 68 from (399, 152) | 80 by 68 from (384, 164) |
| Medal 4, The Legion of Service | `0x570` | | 74 by 67 from (172, 223) |
| Medal 5, The Navy Cross | `0x571` | | 82 by 84 from (263, 229) |
| Medal 6, The Alliance Medal of Honor | `0x572` | | 90 by 97 from (366, 239) |
| Ribbon 1, The Alliance Defense Mobilization Medal | `0x56D` | 46 by 29 from (116, 214) | 29 by 24 from (145, 299) |
| Ribbon 2, The Long Range Forces Commendation Medal | `0x56E` | 49 by 31 from (161, 232) | 40 by 23 from (190, 308) |
| Ribbon 3, The Special Operations Service Medal | `0x56F` | 50 by 35 from (213, 252) | 44 by 26 from (239, 317) |
| Ribbon 4, The Joint Services Commendation Medal | `0x573` | | 42 by 26 from (290, 326) |
| Ribbon 5, The Battle of Titan Campaign Medal | `0x574` | | 49 by 28 from (345, 336) |

The missions that award each medal and ribbon are in [After a mission](rooms.md#after-a-mission).
