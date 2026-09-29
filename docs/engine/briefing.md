# The briefing

The front end's screen 7 (`interface_briefing`, `0x00437010`, named after its asserts' `InterfaceBriefing`), which the Reliant's rooms run as the player goes through the briefing room's door: the door, with AWAITING CLEARANCE, as the briefing loads; the way into the briefing room; Enriquez at the room's screen, which plays the mission's movie; after the loadout, his last word; then the mission. `interface.cpp` holds it, with the door's drawing (`briefing_door_draw`, `0x00437D30`) and the briefing's (`briefing_draw`, `0x0043E730`). After the campaign's last mission, `WinMain` runs it for the campaign's end ([The campaign's end](#the-campaigns-end)).

**Unverified:** the file of the briefing's drawing, which lies after `interface.cpp`'s known code and before `itac.cpp`'s ([Source files](../binary/sources.md)). It draws the briefing alone, so OpenReliant puts it with the briefing.

## In OpenReliant

[`game/interface/briefing.zig`](../../src/engine/game/interface/briefing.zig) holds the briefing. The driver runs it in a loop of its own once the rooms have ended ([`openreliant/rooms.zig`](../../src/openreliant/rooms.zig)), plays the movies of its way in as the game plays them ([Movies](movies.md)), and draws the loadout's hologram while it runs ([Loadout](loadout.md)). Once it ends, the mission flies in the ship the loadout chose, after the hangar's movie ([The Reliant's rooms](rooms.md)).

Not ported:

- The in-game options' LOAD over the loadout, which leaves the briefing for the rooms' first view ([#75](https://github.com/vdmkenny/openreliant/issues/75)); and the loadout's internal guns view ([Loadout](loadout.md#not-ported-yet)).
- The way to the campaign's end after mission 28 ([#74](https://github.com/vdmkenny/openreliant/issues/74)). The briefing's part in it is ported.

**Fixes:**

- Past the table of the missions' movies, the game reads what lies beside it on the stack for the movie's name. OpenReliant plays none there, and the briefing ends at once.
- The pointer's right button ends a stage only once it has come up since the stage began. The game ends one while the button is down, so that the press that skipped the way in, still held, ends the briefing at once, and the last word after it.

**Improvements:**

- The briefing's sounds, the wait's, the door, the room's chatter, the mission's movie and Enriquez's words, ring subtly in a small room of the ship, as the rooms' do ([Sound](../port/sound.md#openal-soft)); the game plays them dry. `--no-reverb` and `--original` leave the room out.
- Enriquez's last word is brought down to the loudness of the mission's movie he has just narrated, as ITU-R BS.1770 measures both, where the game plays it as recorded: the recordings of his last words are mastered louder than the movies', in every shipped mission, which makes them jump out. `--original` plays them as recorded.

## The briefing room

The Reliant's briefing room serves up to mission 18, and the Yamato's after it:

| | Reliant | Yamato |
|---|---|---|
| The door | `inter\rbriefdor.tga` | `inter\briefdoor.tga` |
| The way in | `rel_c2bre.bik` | `amonoff_.bik`, then `briefing room 350.bik` |
| The door's sound | A quarter tone up | At its own pitch |
| The sprite sets | `rbrief.spr`, then `rbrief2.spr` | `brief.spr`, then `brief2.spr` |
| Enriquez | At (469, 116) | At (1, 122) |
| The movie on the room's screen | At (97, 29) | At (200, 42) |
| The frame round the screen | Shape `0xB6` at (89, 17) | Shape `0xA8` at (190, 28) |

The sprite sets are `resource.hog`'s: the room, shape 0, 640 by 480; the palette, block 1, which the briefing makes VFX's global palette (`palette_to_vfx`), so that every shape is drawn with it; and Enriquez's frames from shape 2. The briefing's set ends with the frame round the room's screen, and the last word's has none.

## The stages

1. **The door.** The picture behind the frames is the door (`0x0043EAF0` adds `.tga`, `background_set`), and the drawing writes AWAITING CLEARANCE, strings `0x292` and `0x293` written `%s %s`, centred at (320, 440) in white in the large font (`briefing_door_draw`). One frame shows, then the briefing loads: the sound of `waitloop.fat`, from `resource.hog`, plays at 110, once; the loadout loads (`loadout_load`, `0x00441AA0`), but for mission 29; the briefing's sprite set is read; the speech stops, the music starts fading out by 15 and the voices pause (`sound_pause_all`); `vrsfx.fat` is read from the disc's archive open, and the archive of the carrier's disc opens (`cd_hog_open`).
2. **The way in.** `vrsfx.fat`'s first sound, a sliding door, and its third, the room's chatter, play at full volume, once, and the way in's movies play over the screen (`play_bink_movie_no_clear_resourced`). On the Yamato, a movie of the screen by the door going dark comes first, before the sounds. The bank's second sound, another door, is never played.
3. **The briefing** (`briefing_state` 1, `0x00520280`). Every voice fades out by 4 (`sound_fade_all`), Enriquez starts his animation, and the room's screen plays the mission's movie, from the disc's archive at its own rate and full volume (`BinkSetVolume`). A pass of its loop (`0x004374F0` on) reads the keyboard and the pointer: O saves a screenshot ([Screenshots](screenshots.md)), then Escape, the pointer's right button, or the movie's end ends it. Every voice then ends, and the sprite set and the banks are let go.
4. **The loadout** ([Loadout](loadout.md)). Every voice ends, and the sprite set, `vrsfx.fat` and the room's window are let go; then, but for mission 29, the movie into the loadout's hologram plays from the disc's archive, `rel_br2holo.bik` on the Reliant and `br2hol.bik` on the Yamato (`0x00437711`), the loadout's render hook takes the briefing's (`0x0044B200`), and the loadout enters (`loadout_enter`, `0x00442720`). A pass of its loop (`0x00437784` on) reads the keyboard and the pointer: Escape opens the in-game options, and otherwise a frame of the loadout (`loadout_frame`, `0x004433C0`) runs and is drawn, until it ends; O saves a screenshot. The loadout then leaves (`loadout_leave`, `0x00442CC0`), the near plane goes back to 100, and the movie back to the room plays, `rel_holo2br.bik` or `hol2br.bik` (`0x00437B57`).
5. **The last word** (`briefing_state` 2). The last word's sprite set, and Enriquez's animation from its first frame. His line, `ms_speech\enrbr_tag%02d.ut` for the mission's number, from `speech_hog`, is said once as the animation reaches frame 17, at full volume (`speech_play`). Escape, the right button, or the animation's frame 60 ends it, and the line with it (`speech_stop_all`).

`interface_briefing` then returns -1, with `briefing_outcome` (`0x0051D4B4`) clear, and the rooms end for the mission to be flown ([The Reliant's rooms](rooms.md#a-campaigns-start)).

The in-game options over the loadout (`in_game_options`, `0x004394D0`, [The Reliant's rooms](rooms.md#the-in-game-options)) open with the scene let go of but for its lights, the loadout's speech paused in mission 1, and every sound ended (`0x004377A4` to `0x00437846`). BACK or Escape goes back to the loadout, its speech resumed and its page built again (`loadout_resume`, `0x00443760`), without its hum. MAIN MENU leaves the loadout, sets `briefing_outcome` to 2 and ends the briefing for the main menu; LOAD, where it loaded a saved game, sets it to 1, which takes the rooms back to their first view.

The developers' Enter with Control in the main menu sets `briefing_from_loadout` (`0x0051DB48`) and leads to the briefing, which then leaves the way in and the briefing out, from the loadout on. After it, `WinMain` starts the front end again at its main menu ([Front end](front-end.md#the-developers-keys)).

## The drawing

`briefing_draw` is the front end's render hook, which `interface_run` sets before each screen. While `briefing_state` is 1 or 2 it draws:

1. The room, and Enriquez's frame over it: shape 2, and the segment's first shape past it, and the frame's number.
2. His next frame, once the timer's count (`game_ticks`) passes `briefing_next_frame` (`0x0051D4D8`): 6 ticks from the stage's start, then the count and 6.666 more (`0x004DC6D4`), truncated, so that each frame shows for 7 ticks at least.
3. In the briefing, the mission's movie's frame due, copied onto the room's screen, and the frame round the screen over it. At the movie's last frame, `briefing_movie_playing` (`0x0052027C`) clears.

In the briefing, Enriquez's animation goes round twelve segments, each from frame 0 to its last, then the next's from its first shape:

| Segment | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Reliant, first shape past 2 (`0x004E5C40`) | 0 | 99 | 0 | 0 | 0 | 0 | 137 | 0 | 0 | 61 | 0 | 0 |
| Reliant, last frame (`0x004E5C58`) | 60 | 37 | 60 | 60 | 60 | 60 | 42 | 60 | 60 | 37 | 60 | 60 |
| Yamato, first shape past 2 (`0x004E5C10`) | 0 | 85 | 0 | 0 | 0 | 0 | 123 | 0 | 0 | 47 | 0 | 0 |
| Yamato, last frame (`0x004E5C28`) | 46 | 37 | 46 | 46 | 46 | 46 | 42 | 46 | 46 | 37 | 46 | 46 |

In the last word, the animation runs up to frame 60 and stops there.

## The missions' movies

The room's screen plays `%s.bik` of a table the briefing builds on its stack, indexed by the mission's number: `new_m01` to `new_m28`, missions 12, 13, 17 and 22, which the campaign has none of, taking mission 1's. They lie on the disc of the mission's carrier: missions up to 18 on the second, the rest on the first.

## The campaign's end

As mission 28 is won, the campaign moves on to mission 29, and `WinMain` runs the briefing itself for it (`0x004AA027`, `0x004AA6F2`), before the story's end (`ending_movies_play`; [#416](https://github.com/vdmkenny/openreliant/issues/416)). Mission 29's briefing loads no loadout. In place of the movie, Enriquez speaks `enddebriefing.ut`, from `speech_hog`, over the Yamato's briefing room, until Escape, the right button or the end of his speech, and no loadout or last word follows.
