# The Reliant's rooms

The hub a single-player campaign comes back to between missions: the Reliant's rooms, walked through in movies, and the Yamato's after mission 18. The game calls them VR (`VR_movie`). `interface.cpp` holds them: the rooms (`vr_rooms`, `0x00439FB0`) with their drawing (`vr_draw`, `0x0043C1C0`), the news report on the television (`news_report`, `0x0043BA40`), a new pilot's induction (`reliant_induction`, `0x00438D50`), and the in-game options Escape opens over them (`in_game_options`, `0x004394D0`).

## In OpenReliant

[`game/interface/rooms.zig`](../../src/engine/game/interface/rooms.zig) holds the rooms and the news report, and [`rooms/views.zig`](../../src/engine/game/interface/rooms/views.zig) their views, which `tablegen rooms` reads out of the executable (`make room-tables`). [`induction.zig`](../../src/engine/game/interface/induction.zig) holds the induction, [`in_game_options.zig`](../../src/engine/game/interface/in_game_options.zig) the in-game options, [`restart.zig`](../../src/engine/game/interface/restart.zig) the restart screen, [`game/winmain.zig`](../../src/engine/game/winmain.zig) what `WinMain` does as a campaign starts (`CampaignStart`) and after each mission (`afterMission`), and [`game/gameflow.zig`](../../src/engine/game/gameflow.zig) the campaign it carries from one mission to the next. The driver runs each in a loop of its own ([`openreliant/rooms.zig`](../../src/openreliant/rooms.zig)), and plays the movies between them as the game plays them ([Movies](movies.md)).

The pilot roster's START GAME leads into the rooms, through the induction for mission 1. The briefing room's door leads to the briefing ([Briefing](briefing.md)), and then to the mission, after the hangar's movie; the in-game options' MAIN MENU leads back to the main menu, and QUIT quits. After the mission the campaign goes on through the rooms to the next briefing, or through the restart screen to the same mission ([After a mission](#after-a-mission)). While the window is away, the rooms' loops pause the music and the voices, as the message pump does; the game's pump also waits for the window to come back, where the rooms go on.

Not ported:

- The crew the player passes on the way to the briefing room's door, a sprite over the movie and a line of speech ([#418](https://github.com/vdmkenny/openreliant/issues/418)).
- The screens of the simulator pod ([#420](https://github.com/vdmkenny/openreliant/issues/420)), the locker ([#421](https://github.com/vdmkenny/openreliant/issues/421)) and the CD player ([#422](https://github.com/vdmkenny/openreliant/issues/422)). The rooms go on as though each had closed at once, turned away from it. Use ITAC opens the ITAC ([The ITAC](itac.md)).
- The in-game options' SAVE and LOAD ([#75](https://github.com/vdmkenny/openreliant/issues/75)), and AUDIO, CONTROL DEVICES and VIDEO ([#400](https://github.com/vdmkenny/openreliant/issues/400)), which stay on the menu.
- The pilot's profile, which the rooms write with the call sign as they open (`profile_save`), and the game and the profile a mission's end saves, with the pilot's records ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
- The story's end after the last mission ([#416](https://github.com/vdmkenny/openreliant/issues/416)): OpenReliant goes back to the main menu.

**Fixes:**

- The fish's food falls by the ticks since it last moved; the game moves it on by the ticks between the pass's start and the drawing, so that it hardly falls on a fast machine ([The fish tank](#the-fish-tank)).
- A mission outside the table of news reports has none; the game reads what lies either side of the table for its name.
- The pointer's right button ends the induction only once it has come up since the place showed. The game ends it while the button is down, so that the press that skipped the way to a place, still held, ends the induction there at once ([The induction](#the-induction)).
- After the pilot's execution in mission 25's second part, REPLAY MISSION FROM BRIEFING replays the first part's briefing. The game flies the second part again at once, and leaves the replay asked for, so that the next mission's briefing follows it without the rooms, from the game's variables as the second part began ([The restart screen](#the-restart-screen)).

**Improvements**, each marked so in the code:

- The rooms' pointer, and the in-game options', is where the system's is over the window, as the front end's is ([Front end](front-end.md#the-pointer)). The game adds up DirectInput's movements.
- OpenReliant's version is written in the window's corner of the in-game options, as on the front end's screens. The rooms, the news report and the induction don't show it.
- The in-game options' ABOUT STARLANCER is ABOUT OPENRELIANT ([The in-game options](#the-in-game-options)).
- The loudest peaks of Enriquez's scenes are rounded off, as the radio's lines' are ([Radio](radio.md)). `--original` cuts them flat.
- The rooms' sounds, the hum, the steps and the doors, ring subtly in a small room of the ship, and Enriquez's scenes on the television and the monitors as the radio's voices do, in the cockpit's cabin, as over a speaker ([Sound](../port/sound.md#openal-soft)); the game plays them dry. `--no-reverb` and `--original` leave the rooms out.

## A campaign's start

As START GAME starts a campaign (`interface_run` returns 1), `WinMain` (`0x004AA1BA` on) starts the music fading out by 15 (`music_fade_out`) and opens the archive of the disc that holds the rooms: the second up to mission 18, the first after it (`cd_hog_open`). Before mission 1 it plays the new pilot's intro, `new_intro.bik`, from the disc on a cleared screen (`play_bink_movie_resourced`), then the induction ([The induction](#the-induction)), then from where the induction ended to the simulator pod:

| Ended at | Movies | View |
|---|---|---|
| The television, first or last | `rel_l2t.bik`, `rel_t2itac.bik` | The pod, from the ITAC (`0x00506CB0`) |
| The locker | `rel_lock2c.bik`, `rel_t2itac.bik` | The pod, from the ITAC |
| The simulator pod | `rel_pod2itac.bik` | The pod, from the ITAC |
| The CD player | | The pod, from the CD player (`0x00506BF0`) |
| The ITAC | | The pod, from the ITAC |

The movies play over the screen (`play_bink_movie_no_clear_resourced`). Any other mission's rooms start at the carrier's first view. Through the briefing room's door, `vr_rooms` lets its movie, sounds and pictures go and runs the briefing, the front end's screen 7 (`interface_run`; [Briefing](briefing.md)), and returns 1 for `WinMain` to fly the mission; where the briefing ends otherwise (`0x0051D4B4`), the rooms go on, or return 0 for the main menu, as the in-game options' MAIN MENU has them do.

## After a mission

As a mission of the campaign ends (`0x004AA4B2` on), `WinMain` plays the landing or a chapter's end where the pilot came back ([Movies](movies.md#around-a-mission)), then goes on by how the mission ended (`winmain.afterMission`):

| Ending | What follows |
|---|---|
| The player's ship destroyed, or the ejected pilot killed | The funeral, then the restart screen |
| The ejected pilot captured | The pilot in the enemy's hands, then the restart screen |
| LEAVE MISSION | The restart screen |
| Sent home for destroying a friend | The pilot's execution, then the restart screen |
| Picked up by a nanny ship, the third time in the campaign (`pickup_count`, `0x00475A60`) | The pilot's transfer, then the main menu |
| Mission 25's first part, unless the script rated it a total failure | Its second part, after the hangar's movie |
| Any other | The mission's end recorded (`mission_end_record`) |

The record (`mission_end_record`, `0x00475A90`) keeps the script's rating as the last (`last_success`), promotes the pilot by the kills, keeps them for the next mission's start, raises the campaign's tier after missions 11, 19 and 21, and moves the campaign on to the next mission: 11 and 12 to 14, 16 to 18, 21 to 23, and the others to the next number, the campaign having no missions 12, 13, 17 and 22. A mission that awards a medal plays its ceremony for a success with its bonus, unless a nanny ship picked the pilot up ([Movies](movies.md#how-a-mission-ended)). The debriefing follows in the ITAC (`itac`, `0x0043EFC0`, [The ITAC](itac.md)), whose REPLAY MISSION flies the mission again from its briefing; otherwise the rooms open where the ITAC leaves the pilot (`0x00506C80`, and the Yamato's `0x0050AEC8`), and the briefing room leads to the next mission. After mission 28, the last, the story ends (`ending_movies_play`, `0x004AC620`) and the campaign goes back to mission 1 and the main menu. A script that rates the mission a total failure ends the pilot's career instead: the transfer, or the shuttle, then the main menu.

The game's variables go on from each mission to the next as its script left them. `WinMain` saves the game as each attempt begins (`restart_save`, `0x00475D20`), and a replay loads it again (`restart_load`, `0x00475D30`), so that a replay starts from the variables the mission began with ([Script VM](script-vm.md)).

### The restart screen

`restart_screen` (`0x0043EB80`), in `interface\restart.spr`, offers three choices, each a button 30 by 21 with its label beside it in orange (`0xFE851A`), in the small font:

| Choice | Button | Label | What follows |
|---|---|---|---|
| REPLAY MISSION FROM BRIEFING (`0x32D`) | (162, 371) | (199, 374) | The game as the mission began, and its briefing, the front end's screen 7 (`0x004AA2E0` on) |
| REPLAY MISSION FROM LAUNCH (`0x32E`) | (162, 398) | (199, 402) | The game as the mission began, and the mission again at once, without the hangar's movie (`0x004AA3D9`) |
| MAIN MENU (`0x32F`) | (162, 425) | (199, 428) | The main menu |

Its drawing (`restart_screen_draw`, `0x0043ED90`) takes the palette of shape 17 at the screen's brightness, clears the screen, and draws shape 18 at (1, 1), shape 19 over the button under the pointer at (164, 373), (164, 400) or (164, 427), the labels, and the pointer. The screen fades in from dark by a thirtieth of full each game tick (`palette_ramp_brightness`, `0x004DC64C`). A press on a button chooses at once, and Escape chooses MAIN MENU; the pointer is put away and the screen fades out, the button chosen still lit, ending as it is dark or as Escape is pressed again.

Mission 25's second part replays as its first part, but after the pilot's execution, which leaves REPLAY MISSION FROM LAUNCH the second (`0x004AA750`). The pause menu's RESTART, too, starts mission 25 again from its first part (`0x004AA47A`).

## The views

Each place the player stands in is a view, `0x30` bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 8 | The hotspot that leads to it from each view it is an exit of: corner and size, as `interface_hit` tests them, the edges left out |
| `0x08` | 4 | The movie on the way into it, from the disc's archive, or 0 |
| `0x0C` | 4 | The movie it loops once there, or 0: without one, the way in's last frame stays |
| `0x10` | 2 | The string that names the way into it, which shows as the pointer rests on its hotspot |
| `0x12` | 2 | How many exits it has |
| `0x14` | 16 | The views it leads to, four at most |
| `0x24` | 4 | **Unknown** |
| `0x28` | 2 | Its action, once the player is in it |
| `0x2A` | 2 | The sound of `vrsnd.fat` its way in plays, or -1 for none |
| `0x2C` | 4 | **Unknown** |

The Reliant's views lie from `0x00506AD0` and the Yamato's from `0x0050A958`, 125 in all, reached from the views the code enters the rooms by: each carrier's first, and those the places leave the player in. The views of the locker and the simulator's hotspots count exits they don't have, null pointers the game never follows.

| Action | Meaning |
|---|---|
| 0 | None: the view loops, and its hotspots lead on |
| 1 | Enter Briefing Room: the rooms end for the briefing |
| 2 | Use ITAC (`itac`, `0x0043EFC0`) |
| 3 | Walk to Fish Tank ([The fish tank](#the-fish-tank)) |
| 4 | **Unknown:** two animations of a sprite set over the movie. No view has it |
| 5 | Enter Simulator Pod (`simulator_pod`, `0x0044F3D0`) |
| 6 | Open Locker (`medal_display`, `0x004362F0`) |
| 7 | Watch ACN News ([The news report](#the-news-report)) |
| 8 | **Unknown:** no view has it; the pointer lights over it |
| 9 | Use CD player (`cd_player`, `0x00437FC0`) |

## The loop

As `vr_rooms` starts, it reads the ship's sounds, `vrsnd.fat`, and the player's, `wlksmp.fat`, from the disc, and plays the ship's hum over and over, sound 4 on the Reliant and 5 on the Yamato, at `0x50`. It reads the pointer's shapes, `interface\vrgfx.spr`, sets the pointer at (320, 200), opens the first view's way in and shows its first frame, and starts a timer at 15 Hz (`vr_timer`, `0x00437DD0`). Each pass of its loop (`0x0043A2C1`):

1. Escape opens the in-game options ([The in-game options](#the-in-game-options)). BACK goes on; a saved game loaded starts the rooms again from the carrier's first view; MAIN MENU ends them.
2. Once the way in has ended (`0x00520298`), the view's action: the briefing, with the music fading out by 15 and every voice ended; a place's screen runs, and the rooms go on from the view it leaves the player in. A view without one settles (`0x0043AF4C`): its loop opens, or the fish tank's first movie, and its hotspots come alive (`0x0051D9E4`: 1 settled, 2 on the way in).
3. In the fish tank's view, the food ([The fish tank](#the-fish-tank)).
4. The pointer moves, within 4 of the screen's left, 65 short of its right and 41 short of its foot. While the view is settled, the exit whose hotspot holds it is the one under it (`0x00520184`).
5. A press of the left or right button, or Space, over an exit takes it; the right button elsewhere skips the way in. A button held from a skip is not taken again until it comes up.
6. On each tick of the timer, the pointer's animation steps on.

Taking an exit (`0x0043B40C`) plays its view's sound at full volume, unless the right button took it without the left and the transitions off (`Transitions`, [Movies](movies.md#playing-a-movie)). The view's way in opens; one without a way in has its action at once. The right button, or the left with the transitions off, skips the way in (`0x0043B7D6`): into a view with a loop, or an action, the view is arrived in at once; for any but the CD player, the pointer shows the skip's shape for a frame, then the way in's last frame shows (`BinkGoto`), and the drawing after it arrives in the view.

As the player goes into a place, the view's movie closes (`0x0043A48C`):

| Place | Before | After, and the view it leaves the player in |
|---|---|---|
| The news report | Every voice ends; the music fades out by 15; step 2 of `wlksmp.fat` | The hum again; step 3 |
| The ITAC | The music fades out by 15 | The hum again |
| The simulator pod | The music fades out by 15; step 9 | Step `0xB` |
| The locker | Step 7 | Step 6 |
| The CD player | | Its way in's first frame shown at once |

Each place leaves the player in a view of its own on each carrier, turned away from it, with that view's way in next.

## The pointer

The pointer's shapes are those of `interface\vrgfx.spr`, each drawn as the set's next: an arrow to the left at 0, the pointer at 11, an arrow to the right at 21, and those between them. Left of 40 it turns into the left arrow, and from 541 on into the right; on each tick of the timer it turns two shapes toward the one its place calls for (`0x0051D618`, `0x0051D7E4`), and its animation steps through 9 frames (`0x00520244`).

`vr_draw` draws it only while the view is settled, but for the skip's shape, 50, 22 to the pointer's right, the frame the skip shows it. Over the way into a view with an action, the pointer straight, it lights, shapes 23 on by its animation's frame; the arrows turn over the exits at the edges, shapes 32 on to the left and 41 on to the right. The label of the exit under it shows centred on (320, 440) in `interface\optfnt.fnt`, in white.

## The fish tank

Walk to Fish Tank's view has no loop: it plays its movies one after another, `move_a_.bik`, `move_d_.bik` and the rest of the fourteen at `0x004E8138`, then from the first again. While no food falls, the pointer on the food, (67, 131), 68 by 120, shows Press for Fish Food (string `0xE1`), and the left button drops it (`0x0043B1E5`). The food falls for 498 ticks (`0x0051D600`): `fish.spr` from the disc, the shape three on from the ticks it has fallen at (250, 125), and the tank's front, shape 2, at (23, 110) over it (`0x0043C73C`).

**Fix:** the game moves the food on by the ticks from the pass's start to the drawing, just after the pass takes them up (`frame_duration`), so that it falls only as the drawing takes time. OpenReliant moves it on by the ticks since it last moved.

## The news report

`news_report` (`0x0043BA40`) plays the next mission's report, Enriquez's scene from the disc spoken over the television's movie, `rel_tv_in_loop.bik` on the Reliant, `b_tv_news_.bik` on the Yamato. The scenes are `.box` speech files ([Speech files](../formats/speech.md)), by the mission's number from 1: `0005a`, `0015`, `0025` and on by ten to `0275`. Mission 1's is in three parts: `0005a`, then `0005b` over `tv_cald.bik`, then `0005c` over the television again.

The report runs a loop of its own inside the rooms, which draws with the rooms' drawing (`0x0051D454`): the television's movie loops, the pointer shows where it is over the whole screen, and the label reads Click to Leave News Report (`0x299`). Escape, or either button down, ends it, as does the end of its speech, the next part following where mission 1 has one. The speech plays once at full volume (`speech_play`, `0x00461D80`, `speech_start` on the first free stream).

**Fix:** the game takes the scene's name from the table on its stack by the mission's number, and outside missions 1 to 28 reads what lies either side of it. OpenReliant has no report there, and the rooms go on.

## The drawing

`vr_draw` (`0x0043C1C0`), the rooms' render hook:

1. The movie's next frame, once due, copied to the screen. At its last: on the way in, the view is arrived in; settled, the loop goes back to its second frame, its first frame's pictures put back first (`0x0051D9D8`), or the fish tank's next movie opens; otherwise the last frame stays.
2. The crew, where one shows ([#418](https://github.com/vdmkenny/openreliant/issues/418)).
3. The label: the news report's, the exit's under the pointer, or the food's.
4. The fish's food, while it falls.
5. The pointer.

## The induction

`reliant_induction` (`0x00438D50`) shows a new pilot round the Reliant before mission 1's rooms. It plays the way from the bunk to the television, `rel_ladd_bunk.bik`, `rel_t2l.bik` and `rel_c_tv.bik`, over the screen, then at each place a movie over and over as Enriquez speaks his scene, from the disc, once, at full volume:

| Place | Movie | Scene | The way on |
|---|---|---|---|
| The television | `rel_tv_enriq.bik` | `enr_intro.box` | `rel_tv_c.bik`, `rel_c2lock.bik` |
| The locker | `single_rel_c2lock.bik` | `enr_locker.box` | `rel_lock2c.bik`, `rel_t2itac.bik`, `rel_itac2pod.bik` |
| The simulator pod | `rel_podmon_loop.bik` | `enr_simpod.box` | `rel_pod2cd.bik` |
| The CD player | `rel_cdloop.bik` | `enr_cd.box` | `rel_cd2pod.bik`, `rel_pod2itac.bik` |
| The ITAC | `rel_itacloop.bik` | `enr_itac.box` | `rel_itac2t.bik`, `rel_t2l.bik`, `rel_c_tv.bik` |
| The television | `rel_tv_enriq.bik` | `enr_outro.box` | `rel_tv_c.bik` |

As a scene ends, or on Space, the way on plays over the screen, and the next place follows; after the last, the induction is over. Escape, or the pointer's right button, ends it where it is. It returns the count of ways it took, which `WinMain` goes on from ([A campaign's start](#a-campaigns-start)). Its drawing (`induction_draw`, `0x00439330`) shows the movie alone, going back to its second frame at its last.

## The in-game options

Escape opens them over the rooms (`in_game_options`, `0x004394D0`): `interface\ingameop.tga` behind, the shapes of `interface\frntend7.spr`, and the front end's pointer. Its items, in the order `interface_hit` tries them:

| Item | Corner | Size | Does |
|---|---|---|---|
| SAVE | (140, 121) | 131 by 112 | `interface\igofade.bik`, then the saved games to save to (screen 13) |
| LOAD | (338, 121) | 130 by 109 | Outside a network session, as SAVE, to load from; a game loaded opens its disc and starts the rooms again |
| AUDIO | (65, 276) | 130 by 109 | `igofade.bik`, then the audio screen (`0x0042DAB0`) |
| CONTROL DEVICES | (250, 272) | 130 by 111 | `igofade.bik` over `interface\igofade.tga`, then the controls screen (`0x0042B690`) |
| VIDEO | (436, 272) | 131 by 110 | `igofade.bik`, then the video screen (`0x0042E9B0`) |
| BACK | (199, 422) | 120 by 15 | The rooms again |
| MAIN MENU | (199, 443) | 120 by 15 | `interface\igo2mm.bik`, then the main menu |
| QUIT | (329, 443) | 100 by 15 | QUIT's dialog ([Front end](front-end.md#the-dialogs)), whose YES quits the game |
| ABOUT STARLANCER | (329, 422) | 100 by 15 | The about box |

As in the front end's screens, an item acts while the left button is down over it. Escape goes back to the rooms. Going back, the menu waits for the button to come up.

Its drawing (`in_game_options_draw`, `0x004398B0`), the render hook:

1. The buttons, shape `0x1C` at (299, 422), (299, 443), (329, 422) and (329, 443), and their labels in blue in `interface_font_small`: BACK (string `0xF7`) to the left of (292, 423), MAIN MENU (`0xBB`) to the left of (292, 444), ABOUT STARLANCER (`0x10C`) from (357, 423) and QUIT (`0xBC`) from (357, 444).
2. The item under the pointer lit: a panel's shape, `0x12` to `0x16`, at (107, 115), (308, 114), (35, 250), (230, 255) and (406, 252); a button's label again in white, and shape `0x1D` on its button.
3. The panels' labels in blue in `interface_font_large`, centred: SAVE (`0x3B5`) on (208, 233), LOAD (`0x149`) on (408, 233), AUDIO (`0x109`) on (130, 385), CONTROL DEVICES (`0x10A`) on (322, 385) and VIDEO (`0x10B`) on (506, 385).
4. The about box, where it is up, then QUIT's dialog, then the pointer.

ABOUT STARLANCER (`about_box`, `0x0042A520`) reads `interface\frntend2.spr` (`0x0051D540`) and shows its box (`0x0051DB4C`) until Escape, or a click on OK, (316, 334), 25 by 16, once the button comes up: the box, shape `0x23` at (114, 177); OK, shape `0x1A` at (316, 334), `0x1B` under the pointer; in blue, the title, ABOUT STARLANCER, centred on (320, 180), `PID - ` and the product ID the installer kept in the registry centred on (320, 194), both in `interface_font_small`, the notice (string `0x315`) centred on (320, 208) in lines at most 400 wide, 14 apart, at most 10, and OK (`0x316`) to the left of (308, 329) in `interface_font_large`.

**Improvement:** OpenReliant's item and box are ABOUT OPENRELIANT. The box's middle is filled black, where the game leaves it clear over the menu, and in the product ID's place a few words on OpenReliant, its version, its copyright and its license, the Mozilla Public License 2.0, stand above the game's notice. Where the lines would reach OK's label 14 apart, they draw closer.
