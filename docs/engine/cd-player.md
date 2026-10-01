# The CD player

The CD player (`cd_player`, `0x00437FC0`) is the screen Use CD player opens in the Reliant's rooms
and the Yamato's ([The Reliant's rooms](rooms.md)). It runs in a loop of its own on a screen 640 by
480, over a picture of the player, and plays the game's music from a list of twelve pieces, each
carrier its own. Its code lies within `C:\lancer\game\interface.cpp`.

## In OpenReliant

[`game/interface/cd_player.zig`](../../src/engine/game/interface/cd_player.zig) holds the CD
player, and the driver runs its loop (`Driver.listen` in
[`openreliant/rooms.zig`](../../src/openreliant/rooms.zig)).

**Fixes:**

- Every piece comes from the list shown. The game takes the Yamato's list for PLAY SELECTED TRACK
  alone, and the Reliant's for the rows, the next and the previous track and the piece that follows
  one's end, so that on the Yamato these play the Reliant's piece in the row.
- The CD player's volume is the level its music plays at, which the music volume and the master
  volume scale as they scale any music ([Sound](sound.md#music)). The game plays each piece at the
  full level and sets the stream to the CD player's volume itself, past the two volumes, so that at
  the music volume's default a press of either button makes the music louder.

**Improvement:** RANDOM TRACK MODE draws the next piece from `std.Random`, among the eleven others.
The game draws `rand() % 12` up to 20 times for one other than the piece that ended, and plays that
piece again where none is.

## The screen

As it opens, the CD player shows its picture behind the screen, `interface\rel_bunk2cd.tga` on the
Reliant, up to mission 18, and `interface\brd2cd.tga` on the Yamato, after it, and reads
`cdplay.spr`, its shapes, and the ITAC's large font, `inter\itac\itacbig.fnt`. Nothing is chosen,
nothing is paused and the modes are off, whatever music plays already. Its drawing
(`cd_player_draw`, `0x00438890`) draws, in order:

1. The button under the pointer, lit, but for REPEAT TRACK MODE and RANDOM TRACK MODE, which are
   lit while they are on.
2. The title, CD PLAYER (`0x3B4`), at (117, 129) from its left, in the ITAC's large font, in
   `0x0079FE`.
3. The list, a row every 16 from 171 down: its number, `%02d` from 01, at 117, and the piece's name
   at 137, in the front end's small font, in `0x0079FE`, and the piece chosen in white.
4. The name of the button under the pointer, centred at (320, 440), in white, in the front end's
   large font.
5. The pointer, shape 12 of `cdplay.spr`, in the palette of the set's block 11. The buttons are
   drawn in block 0's.

The pointer finds a button inside its rectangle, the edges left out (`interface_hit`):

| Button | Rectangle | Lit shape | A press |
|---|---|---|---|
| PLAY SELECTED TRACK (`0x2F6`) | 50 by 43 from (564, 124) | 3 at (571, 134) | Plays the piece chosen |
| PAUSE THE CURRENT TRACK (`0x2F7`) | 56 by 27 from (562, 170) | 4 at (571, 174) | Pauses the music, or lets it go on |
| STOP THE CURRENT TRACK (`0x2F8`) | 55 by 26 from (562, 199) | 5 at (571, 204) | Closes the music, and leaves nothing chosen |
| PLAY THE NEXT TRACK (`0x2F9`) | 55 by 27 from (562, 227) | 6 at (571, 231) | Plays the next piece, the first where none is chosen |
| PLAY THE PREVIOUS TRACK (`0x2FA`) | 56 by 27 from (562, 256) | 7 at (571, 259) | Plays the previous piece |
| REPEAT TRACK MODE (`0x2FB`) | 55 by 26 from (562, 285) | 8 at (571, 288) | Turns repeating on or off, and random play off |
| RANDOM TRACK MODE (`0x2FC`) | 56 by 26 from (562, 314) | 9 at (571, 316) | Turns random play on or off, and repeating off |
| LEAVE CD PLAYER (`0x2FD`) | 54 by 38 from (562, 343) | 10 at (571, 354) | Closes the player on the next pass |
| CD VOLUME UP (`0x2FE`) | 56 by 22 from (21, 341) | 1 at (29, 345) | Turns the volume up |
| CD VOLUME DOWN (`0x2FF`) | 56 by 22 from (21, 363) | 2 at (29, 368) | Turns the volume down |

After the buttons come the list's rows, 400 by 14 from (117, 176), each 16 below the last.

## The lists

Each piece plays from `music\` and the name of its file, with `.wav`:

| Row | The Reliant's | Its file | The Yamato's | Its file |
|---|---|---|---|---|
| 01 | Spirit of War (`0x319`) | `new_mission01` | Final Word (`0x531`) | `New_Sim01` |
| 02 | Freedom (`0x31A`) | `new_mission02` | By the Sword (`0x532`) | `New_Sim02` |
| 03 | Warrior's Dance (`0x31B`) | `new_mission03` | Race to die (`0x533`) | `New_Sim04` |
| 04 | Hell's Mouth (`0x31C`) | `new_mission04` | Hollow Vein (`0x534`) | `New_Sim05` |
| 05 | The Calling (`0x31D`) | `new_mission05` | Seven Sins (`0x535`) | `New_Sim07` |
| 06 | Black Sun (`0x31E`) | `new_mission06` | Shadow Walk (`0x536`) | `New_Sim08` |
| 07 | Indian Dawn (`0x31F`) | `new_mission10` | Running with Wolves (`0x537`) | `New_Sim10` |
| 08 | Deliverance (`0x320`) | `New_Searching Mission 01` | Fluid (`0x538`) | `new_launch` |
| 09 | Silent Scream (`0x321`) | `New_Searching Mission 03` | Devil's Prayer (`0x539`) | `New_Takeoff - Music` |
| 10 | PathFinder (`0x322`) | `New_Searching Mission 05` | The Reckoning (`0x53A`) | `new_victory` |
| 11 | Night behind Day (`0x323`) | `New_Searching Mission 06` | Dark Skies (`0x53B`) | `new_defeat` |
| 12 | The Catalyst (`0x324`) | `New_Searching Mission 10` | The Rise (`0x53C`) | `new_mission01` |

## Playing

A press of the left button over a button or a row plays sound 8 of the rooms' `wlksmp.fat` at full
volume, and does what it does on the pass the button goes down (`0x0051DB40`). A row chooses its
piece (`0x0051D9D0`), and the piece chosen plays as its row is clicked again. A piece plays at once
(`music_play`), over and over in REPEAT TRACK MODE and else once, and closes the music playing.

PLAY SELECTED TRACK and a row clicked again start the player playing (`0x0051D7AC`), and STOP THE
CURRENT TRACK stops it. While it plays, with REPEAT TRACK MODE off and the music not paused, a
piece's end is followed by the list's next piece, or in RANDOM TRACK MODE by another at random
(`0x00438735` on); the list's last piece is its end. The next and the previous track play without
starting the player, and take the pause off, as PLAY SELECTED TRACK does; a row clicked again leaves
it.

The volume (`0x004E5B88`), from 0 to 127, is full as the game starts and lasts while it runs. Its
buttons turn it a step each pass the left button is held over them.

Escape closes the player. The music plays on in the rooms, as any music plays, without the rooms'
reverb ([Sound](../port/sound.md#openal-soft)), until the briefing, the news report, the ITAC or the
simulator pod fades it out ([The loop](rooms.md#the-loop)).
