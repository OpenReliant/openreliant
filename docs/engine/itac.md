# The ITAC

The ITAC (`itac`, `0x0043EFC0`, `C:\lancer\game\itac.cpp`) is the terminal that Use ITAC opens in
the Reliant's rooms and the Yamato's ([The Reliant's rooms](rooms.md)), and which `WinMain` opens
after each mission of the campaign for its debriefing. It runs in a loop of its own on a screen 640
by 480. Nine buttons along its foot open its sections, each with a movie in, a movie out and a
picture of its own that its text is written on; the last button closes it. Its strings are
`ITACLANG.DLL`'s, read as it opens (`itac_language_init`, `0x00440770`).

## In OpenReliant

[`game/itac.zig`](../../src/engine/game/itac.zig) runs the ITAC, and
[`game/itac/debriefing.zig`](../../src/engine/game/itac/debriefing.zig) is DEBRIEFINGS. The lit
shapes and the debriefings' texts are in [`game/itac/tables.zig`](../../src/engine/game/itac/tables.zig),
which `make itac-tables` derives from the executable. The driver runs the loop
(`Driver.itac` in [`openreliant/rooms.zig`](../../src/openreliant/rooms.zig)), from the rooms and
after each mission of the campaign.

Ported so far: the ITAC's loop, with its movies, its sections' pictures and titles, the fades of
their text, the panes their text wipes in by, the lit shapes, the pointer and the sounds; and
DEBRIEFINGS with REPLAY MISSION. Not yet: the other sections, which show their pictures with nothing
written on them: NEWS REPORTS ([#461](https://github.com/vdmkenny/openreliant/issues/461)), VIDEO
REPORTS ([#462](https://github.com/vdmkenny/openreliant/issues/462)), the fighters
([#463](https://github.com/vdmkenny/openreliant/issues/463)), the capital ships
([#464](https://github.com/vdmkenny/openreliant/issues/464)), the squadrons
([#465](https://github.com/vdmkenny/openreliant/issues/465)) and the personnel
([#466](https://github.com/vdmkenny/openreliant/issues/466)) of either side, and the KILLBOARD
([#467](https://github.com/vdmkenny/openreliant/issues/467)); and the buttons' tooltips
([#468](https://github.com/vdmkenny/openreliant/issues/468)).

**Fixes:**

- A section's title and text fade a step each frame of its movie in and out, over which the fade is
  meant to run: sixteen frames in, five out. The game steps them each frame it draws, so that they
  run faster the faster the machine, and a movie skipped leaves the text as dim as the fade had
  reached. OpenReliant ends it at full.
- After a mission, the game opens DEBRIEFINGS after its movie in, so that the figures fading in over
  the movie are those of whichever debriefing was chosen last. OpenReliant opens it before, as the
  rooms open NEWS REPORTS.
- As another debriefing is chosen, the game holds the screen still for half a second, drawing
  nothing (`itac_pause`, `0x00440170`). OpenReliant shows it at once.

**Improvements:**

- The times of the sounds now and then, and which plays, are drawn from `std.Random`, where the
  game uses `rand`.
- Its text, in `itacbig.fnt` and `itacsml.fnt`, is drawn from outline fonts at the window's
  resolution, Newtown or a mod's ([Outline fonts](../formats/fnt.md#outline-fonts)).

## Opening and closing

| | Use ITAC in the rooms | After a mission (`WinMain`, `0x004AA696`) |
|---|---|---|
| Opening | Sound 4 of `itacsnd.fat`, then the pilot's eye read, `itac_eye_recog.bik` from the disc, up to mission 18, or `inter\itac\itac open.bik` after it | None |
| First section | NEWS REPORTS | DEBRIEFINGS, with REPLAY MISSION for the latest |
| After | The rooms, from where the ITAC leaves the pilot | The rooms for the next mission, or with REPLAY MISSION the mission again |

In both, sound 3 plays at `0x50` as the screen comes on, `inter\itac\itacinit.bik`, which leaves the
picture `itactrans_00014`. Then its hum, sound 0, plays over and over at `0x40`, and now and then
sound 2 or 7 at `0x50`: the first between 500 and 700 game ticks later, each other between 500
and 1300 after the last (`0x0043F654`).

Escape, or the last button's movie in, closes it (`0x0043FA70`, `0x0043FADB`): the hum fades, sound
6 plays at full volume, `inter\itac\itaclose.bik` plays after mission 18, and the screen holds until
the sound has faded out. Every sound then ends. Escape leaves the section shown without its handler
for leaving it.

## The screen

Each section writes its text on its picture, `inter\itac\itactrans_NNNNN.tga`, into panes that
wipe in from the left, 14 pixels a tick of the ITAC's timer, 30 ticks a second (`itac_timer`,
`0x0043FC60`; `itac_panes_draw`, `0x0043FF50`). The panes show only while no fade runs. The title
stands at (167, 22) in `itacbig.fnt`, in (236, 105, 77); the rest is in `itacsml.fnt`.

`itacgfx.spr` holds the pointer, shapes 2 to 22, one for every 4 game ticks with block 1's palette,
and the shapes the ITAC lights where the pointer is over them, with block 30's palette
(`itac_lit_draw`, `0x00440F90`): the buttons, and each section's arrows.

## The sections

| Button | Section | Movies | Picture |
|---|---|---|---|
| 1 | DEBRIEFINGS | `itacdeb.bik`, `itacdebf.bik` | `itactrans_00030` |
| 2 | NEWS REPORTS | `itacnew.bik`, `itacnewf.bik` | `itactrans_00051` |
| 3 | VIDEO REPORTS | `itacmov.bik`, `itacmovf.bik` | `itactrans_00072` |
| 4 | ALLIANCE or COALITION FIGHTERS | `itacss.bik`, `itacssf.bik` | `itactrans_00093` |
| 5 | ALLIANCE or COALITION SHIPS | `itaccs.bik`, `itaccsf.bik` | `itactrans_00114` |
| 6 | ALLIANCE or COALITION SQUADRONS | `itacsq.bik`, `itacsqf.bik` | `itactrans_00135` |
| 7 | ALLIANCE or COALITION PERSONNEL | `itacpil.bik`, `itacpilf.bik` | `itactrans_00156` |
| 8 | KILLBOARD | `itackil.bik`, `itackilf.bik` | `itactrans_00177` |
| 9 | Closes the ITAC | `itacexit.bik` | |

The buttons are 58 by 51 at y 422 (`itac_buttons`, `0x004E9340`). The movies are in `inter\itac\` in
the game's folder, played at 15 frames a second over the screen in the ITAC's own loop
(`itac_movie_play`, `0x00440010`), which only Escape ends; the pictures are in `resource.hog`.

A press on another section's button plays sound 1 (`0x0043F6DE`). The shown section's movie out
plays, its title and text fading out over it, and its handler for leaving it runs. The new
section's handler for opening it runs, and its movie in plays with its title and text fading in, the
pointer hidden. Then its picture shows and its panes wipe in. Each section has five handlers
(`itac_section_handlers`, `0x004E9288`): opened, left, loaded, each frame and drawn.

## DEBRIEFINGS

Enriquez's debriefing of each mission the pilot has flown, as text alone (`debrief_text_draw`,
`0x00424CF0`). The list at the right names the missions flown, "Mission" and each one's place in
the campaign's order counted from 1 (`campaign_missions`, `0x004E4954`), so that its Mission 12 is
mission 14. As it opens, the latest is chosen.

- The header, in (58, 209, 255): FROM SQUADRON LEADER MARIA ENRIQUEZ, TO the pilot's call sign.
- The body, in (255, 146, 58), which the arrows below it scroll: the paragraphs the mission's rating
  calls for (`debrief_texts`, `0x004E4A68`, a table for each rating and a row for each mission),
  then a paragraph on each of the medal, where the mission was rated a success with its bonus, the
  promotion, the ribbon and the fighters it brought. Where a nanny ship picked the pilot up in the
  mission, whether the objectives were met and the pickup's paragraph stand in their place.
  "(more)" marks a body that runs past its box.
- Mission Kills, the mission's, and Overall Kills, the campaign's; Rank and Level, the game's
  strings; their values fade with the section.
- REPLAY MISSION, after a mission, for the latest debriefing: the campaign as the mission began, as
  `restart_load` loads it, and its briefing again (`0x004AA2E0` on).

| What | Where |
|---|---|
| Header | (30, 82), 399 by 34 |
| Body | (30, 117), 400 by 194; arrows at (219, 321) and (246, 321), 27 by 27 |
| "(more)" | Right edge at (430, 308) |
| List | (473, 104), 144 by 259; arrows at (515, 368) and (542, 368), 27 by 27 |
| Figures | Labels at x 36, values right-aligned at x 214, y 346, 362, 378 and 394 |
| REPLAY MISSION | Button at (433, 368), 33 by 25; its label right-aligned at (425, 370) |

What it shows of each mission is the pilot's record of it, which `mission_end_record` keeps
(`gameflow.MissionRecord`): its rating, the kills made in it, one a ship (`kills_add`), the
campaign's pickups where a nanny ship picked the pilot up in it, and the rank the pilot was promoted
to at its end.
