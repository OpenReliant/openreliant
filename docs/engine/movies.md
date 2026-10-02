# Movies

The game plays its movies with RAD's Bink (`BINKW32.DLL`), their sound through Miles
(`BinkSetSoundSystem` with `BinkOpenMiles`). The movies are Bink files ([`.bik`](../formats/bink.md)),
in the game's folder and in the discs' archives.

## Playing a movie

Four functions play a movie in a loop of their own, in `xtrabits.cpp`:

| Function | Plays | From | Over | At |
|---|---|---|---|---|
| `play_bink_movie` (`0x004AB850`) | The intro | The game's folder | A screen cleared to black once | The movie's rate, at full volume (`BinkSetVolume`, `0x8000`) |
| `play_bink_movie_no_clear` (`0x004AB6E0`) | The front end's transitions | The game's folder | What the screen last showed | 15 frames a second (`BinkSetFrameRate(15, 1)` and `BINKFRAMERATE`) |
| `play_bink_movie_resourced` (`0x004ABB80`) | The hangar's, a chapter's zoom, a new pilot's intro | The disc's archive | A screen cleared to black once | The movie's rate, at full volume |
| `play_bink_movie_no_clear_resourced` (`0x004AB9D0`) | A chapter's movie and news, the ways of a new pilot's induction, the way into the briefing room | The disc's archive | What the screen last showed | The movie's rate: it sets 15 frames a second without `BINKFRAMERATE`, which alone has Bink keep to it |

The two that read the disc's archive find the movie in it (`hog_locate`, `0x004C83F0`), by its
whole name whatever its case, and have Bink open it where it lies in the archive's file
(`BINKFILEHANDLE`, `0x800000`).

A pass of the loop (`0x004AB7B2`) runs the message pump, reads the keyboard and moves the pointer.
Escape, the pointer's right button down, the movie's end (`0x005D6C90`) or the game quitting
(`0x005D60BC`) ends it; otherwise, once `BinkWait` says the next frame is due, `bink_frame`
(`0x004AC510`) decodes it (`BinkDoFrame`), copies it into the middle of the screen
(`BinkCopyToBuffer`), and moves on to the next (`BinkNextFrame`), or marks the movie ended at its
last. The message pump pauses the movie while the window is away (`BinkPause`). A movie that cannot
be opened stops the game with a message (`play_bink_movie: error loading %s.`).

The video settings' `Transitions` (`[Device]`, 1 unless set, read at `0x004A9081`; [Video](front-end.md#video)) turns off the
movies over the screen; those on a cleared screen play whatever it says on a hardware renderer
(`sr + 0x1AC`). With it off, a chapter's end plays its zoom alone.

The Reliant's rooms, the news report and a new pilot's induction play their movies in loops of
their own, from the disc's archive at 15 frames a second whatever the settings, each frame copied
to the screen as it is due ([The Reliant's rooms](rooms.md)). The briefing plays the mission's
movie on the briefing room's screen so, at the movie's rate and full volume ([Briefing](briefing.md)).

## The discs' archives

`cd_hog_open` (`0x0042FE00`) opens a disc's archive, `cd1.hog` or `cd2.hog`, in place of the one
open (`cd_hog`, `0x005202D4`): from the disc in the drive (`cd_in_drive`, `0x004AC6C0`), asking for
the other disc where the drive holds the wrong one, or, in a full install, from the installation's
folder, where both lie ([Platform](../port/platform.md#installing-the-games-files)). Where the archive
cannot be opened, the game stops with `Can't open HOG resource file %s`.

Disc 2 holds the Reliant's movies and chapters 1 and 2 with their news; disc 1 the Yamato's,
chapters 3 to 5 and the story's end. Both hold the Yamato's hangar and landing, the zooms and the
news' transition.

## Around a mission

`WinMain` plays the hangar's movie before each mission it flies, and `play_landing_movie` after it.
The main menu's INSTANT ACTION flies its mission itself, without either, and neither plays where a
lobby launched the game (`lobby_launch`, `0x00595C64`).

### The hangar

After the briefing, `WinMain` starts the music fading out by 15 (`music_fade_out`), stops the
voices (`sound_pause_all`), and waits a second, in which the timer fades the music out (`0x004AA3B2`
on). **Unverified:** that the call it waits with is `Sleep`: the executable's protection hides its
imports. Then, before the mission's loading, `hangar_movie_play` (`0x004ABD40`) opens the
mission's disc, the second up to mission 18 and the first after it, and plays the next of three
movies of the pilots readying (`play_bink_movie_resourced`): the Reliant's, `r_h_ta.bik` to
`r_h_tc.bik`, or past mission 18 the Yamato's, `y_h_ta.bik` to `y_h_tc.bik`. It steps the count on
before each (`0x005D6C8C`), which `WinMain` sets to the first as it opens the front end
(`0x004A9587`), so the second plays first.

### The landing

`WinMain` plays `play_landing_movie` (`0x004ABDE0`) as a mission ends, but not where the player's
ship was destroyed or the ejected pilot killed or captured, nor where the mission was left from
the pause menu (`mission_ending` 1, 3 and 4), nor after mission 25's first part, which leads into
its second.

It plays nothing after mission 25's second part or mission 27 where the game's variable 36 is
clear, nor where the player's ship was sent home (`mission_ending` 6 and 7). A mission that ends a
chapter of the story ends in the chapter's end, unless the script rated it a total failure
(`mission_success` -1); any other mission ends in the landing.

The landing (`0x004AC195` on) plays its movie from the disc's archive at 15 frames a second
(`BinkOpen` with `BINKFILEHANDLE` and `BINKFRAMERATE`, `0x801000`) at full volume, on a screen
cleared to black; then, unless Escape ended it, the thread's movie, a file of the game's folder
read whole (`hog_file_read`) and opened in memory (`BINKFROMMEMORY`, `0x4000000`), at its own rate.
Neither movie has sound: the land bank's first sound, from `resource.hog`, plays over both at
127, once, from the middle (`sound_play`), and stops as they end (`sound_pause_all`). Escape ends
each movie; the pointer's right button does not, as the loop moves no pointer.

The movies and the bank follow the carrier and the mission's rating (`0x004ABDEC` on):

| | The Reliant, up to mission 17 | The Yamato, from mission 18 |
|---|---|---|
| Landing | `r_h_land.bik` | `yamland_generic.bik` |
| Total failure, failure | `rthread_d.bik`, `rlande.fat` | `thread04.bik`, `ylande.fat` |
| Partial failure | `rthread_d.bik`, `rlandd.fat` | `thread04.bik`, `ylandd.fat` |
| Partial success | `rthread_c.bik`, `rlandc.fat` | `thread03.bik`, `ylandc.fat` |
| Success | `rthread_b.bik`, `rlandb.fat` | `thread02.bik`, `ylandb.fat` |
| Success with its bonus | `rthread_a.bik`, `rlanda.fat` | `thread01.bik`, `ylanda.fat` |

Mission 7 always ends on the Yamato, and mission 8 where the game's variable 32 is clear, each
with a failure's thread and bank whatever the rating.

### A chapter's end

The chapters' table (`chapter_of_mission`, `0x00509C00`, a byte for each of missions 1 to 32) names
the chapter a mission ends: missions 7, 11, 19, 21 and 25 end chapters 1 to 5. A chapter's end
(`0x004ABFEE` on) opens the chapter's disc, the second before mission 18 and the first from it on,
and plays:

1. The zoom, `thread_zoom.bik` before mission 18 and `rthread_zoom.bik` from it on
   (`play_bink_movie_resourced`).
2. The chapter's movie, `new_chapter1.bik` to `new_chapter5.bik` (`chapter_movies`, `0x00509BE8`),
   with the news' loop, the first sound of `newsloop.fat`, playing over and over at 80 from here to
   the last report (`play_bink_movie_no_clear_resourced` from here on).
3. The news reports the game's variables call for, each after the news' transition, `acntran.bik`.

| After mission | Report | Plays where |
|---|---|---|
| 7 | `new_chapter1_thread1.bik` | Variable 18 is other than 1 |
| 11 | `new_chapter2_thread1.bik` | Variable 29 is other than 1 |
| 11 | `new_chapter2_thread2.bik` | Variable 17 is other than 1 |
| 11 | `new_chapter2_thread3.bik` | Variable 6 is other than 1; it then sets variable 34 |

All but variable 34 are the campaign's flags, which a new campaign sets to 1 and a mission's
script may clear; each attempt at a mission clears 34. What each stands for is not known
([#381](https://github.com/OpenReliant/openreliant/issues/381)). The function has reports for mission
16 too, `new_chapter3_thread1.bik`, `new_chapter3_thread2.bik` and `new_chapter2_thread3.bik`,
which are never reached, as mission 16 ends no chapter.

### How a mission ended

After the landing, or where there is none, `WinMain` plays how a mission of the campaign ended
from the archive of the disc open, the mission's carrier's, on a cleared screen
(`play_bink_movie_resourced`), then turns to the restart screen or the main menu
([After a mission](rooms.md#after-a-mission)). The Reliant's movies play up to mission 18 and the
Yamato's after it:

| Ending | Up to mission 18 | After mission 18 | Then |
|---|---|---|---|
| The player's ship destroyed, or the ejected pilot killed: the funeral | `new_funeral.bik` | `new_funeral2.bik` | The restart screen |
| The ejected pilot captured: the pilot in the enemy's hands | `int.bik` | `int.bik` | The restart screen |
| Sent home for destroying a friend: the pilot's execution | `new_rel_exec.bik` | `new_y_exec.bik` | The restart screen |
| Picked up by a nanny ship the third time: the pilot's transfer | `new_reliant_transfer.bik` | `new_a y trans.bik` | The main menu |
| A total failure: the pilot's transfer | `new_reliant_transfer.bik` where the game's variable 32 is set, else `new_a y trans.bik` | `new_a y trans.bik` | The main menu |

After missions 25 and 27, where variable 36 is clear, a total failure plays the shuttle at Fort
Bear, `fortbearshuttle_.bik`, in the transfer's place (`0x004AA5E0`). Each movie lies on its
carrier's disc, and `int.bik` and `new_a y trans.bik` on both.

A mission that awards a medal (`medal_of_mission`, `0x005009BB`) plays its ceremony from the disc
as the mission's end is recorded, where the script rated it a success with its bonus and no nanny
ship picked the pilot up (`mission_end_record`, `0x00475B57` on), before the ITAC:

| After mission | Medal | Ceremony |
|---|---|---|
| 6 | 1 | `new_silver.bik` |
| 11 | 2 | `new_black eagle.bik` |
| 16 | 3 | `new_valour.bik` |
| 21 | 4 | `new_legion.bik` |
| 23 | 5 | `new_navy_cross.bik` |
| 27 | 6 | `new_medal_of_honour.bik` |

## The movies played

- As the renderer first starts, before its loading screens, `renderer_load` plays the intro:
  `new_nms.bik`, `new_dalogo_fs_uncmpr.bik` and `warty_.bik`, from the game's folder.
- As `WinMain` opens the front end, `0x004AB6A0` plays `splash to mm.bik`, the splash turning into
  the main menu.
- The front end's screens play their transitions from its `interface` folder as they lead from
  one to another: SINGLE PLAYER `main2sin.bik`, MULTI PLAYER `main2mul.bik` and GAME OPTIONS
  `main2opt.bik` from the main menu; the pilot roster's MAIN MENU and Escape `sin2main.bik`, and
  LOAD GAME `sinfade.bik`.
- As START GAME starts a campaign, `WinMain` plays a new pilot's intro, `new_intro.bik`, before
  mission 1's induction, and the ways from where the induction ended; the in-game options' MAIN
  MENU plays `interface\igo2mm.bik` before the main menu ([The Reliant's rooms](rooms.md)).
- Around each mission `WinMain` flies, the hangar's movie, the landing or a chapter's end, and how
  the mission ended or a medal's ceremony ([Around a mission](#around-a-mission)).
- The ITAC plays its own in its loop, its sections' movies in and out, and on the Reliant the pilot's
  eye read ([The ITAC](itac.md)).

## In OpenReliant

[`engine/bink.zig`](../../src/engine/bink.zig) stands in for Bink, each function for the call it
names; [`engine/bink/picture.zig`](../../src/engine/bink/picture.zig) turns a decoded picture into
colours, by BT.601 in its limited range. It reads the container itself and hands the packets to a
`Codec`: FFmpeg's decoders, in the platform ([Platform](../port/platform.md#movies)). It decodes a
movie's sound whole as the movie opens and plays it as a Miles stream, where Bink fills a Miles
sample as it plays; the sound starts with the first frame, and OpenAL Soft resamples it as it
resamples every sound ([Sound](../port/sound.md#openal-soft)).

[`game/xtrabits/movie.zig`](../../src/engine/game/xtrabits/movie.zig) holds the game's players, one
`Kind` each and one for the landing's loop, `bink_frame`, and the hangar's movies;
[`game/xtrabits/landing.zig`](../../src/engine/game/xtrabits/landing.zig) decides what
`play_landing_movie` plays. [`game/interface/disc.zig`](../../src/engine/game/interface/disc.zig)
opens the discs' archives as a full install does, from the game's folder, where `openreliant
install` copies both. The driver runs the loops ([`openreliant/movies.zig`](../../src/openreliant/movies.zig)),
each frame drawn over an empty scene and put on the window, the window's messages read as the
message pump reads them.

The intro, the splash's movie and the transitions of the screens ported play as the game plays
them; a mission `--mission` names, or a screenshot, starts without the intro. A mission the front
end starts, all but INSTANT ACTION's, fades the music out over a second and plays the hangar's
movie before its loading screen, and as it ends the landing or a chapter's end, and how it ended
or a medal's ceremony; LEAVE MISSION leaves it without the landing. A movie that is missing, or
that cannot be decoded, is left out, and the game goes on, as it does without a disc's archive or
a bank.

**Fixes:**

- For a rating past the named ones, the game takes whatever its stack holds for the thread's movie
  and the bank. OpenReliant lands without them.
- Past the chapters' table, the game reads a mission's chapter from what follows the table.
  OpenReliant ends no chapter there.
- The pointer's right button ends a movie only once it has come up since the movie began. The game
  ends one while the button is down, so that the press that skipped what came before, still held,
  ends it at once.

**Improvements**, each left out under `--original`:

- The steps at the edges of the 8 by 8 blocks Bink codes a picture in are smoothed where they are
  small (up to 12 levels) and the levels either side are even (within 3): the blocks that show in
  a dark or flat area once a movie is drawn large, as in the front end's transitions. Where three
  levels either side are even, the step is spread over the four nearest it, as H.264's strong
  filter spreads one; otherwise the two at the edge are brought nearer. Steps past that are edges
  in the picture, and stay.
- Each pixel's colour is blended from the four nearest samples of the half-size colour planes,
  three quarters of the nearer and a quarter of the farther each way, where Bink gives a 2 by 2
  block of pixels one colour, which shows as steps along a coloured edge.
- A movie is drawn as large as fits in the window, as the front end is, keeping its shape, so that
  a 16:9 movie fills a wide window. `--original` draws it at its size in the middle of the front
  end's screen, as the game draws it on a screen 640 by 480.
- On the GPU, a movie is magnified with FSR 1's edge-adaptive upscale (EASU, from AMD's FidelityFX
  Super Resolution 1.0), which keeps its edges sharp without steps
  ([Renderer](../port/renderer.md#improvements)).

Not ported: the other movies, each with what plays it: the story's end
([#416](https://github.com/OpenReliant/openreliant/issues/416)), those of the rooms' places
([#419](https://github.com/OpenReliant/openreliant/issues/419) to
[#422](https://github.com/OpenReliant/openreliant/issues/422)), and the transitions of the screens not
yet ported, the in-game options' `igofade.bik` among them
([#43](https://github.com/OpenReliant/openreliant/issues/43)).
