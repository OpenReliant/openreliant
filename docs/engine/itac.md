# The ITAC

The ITAC (`itac`, `0x0043EFC0`, `C:\lancer\game\itac.cpp`) is the terminal that Use ITAC opens in
the Reliant's rooms and the Yamato's ([The Reliant's rooms](rooms.md)), and which `WinMain` opens
after each mission of the campaign for its debriefing. It runs in a loop of its own on a screen 640
by 480. Nine buttons along its foot open its sections, each with a movie in, a movie out and a
picture of its own that its text is written on; the last button closes it. Its strings are
`ITACLANG.DLL`'s, read as it opens (`itac_language_init`, `0x00440770`).

## In OpenReliant

[`game/itac.zig`](../../src/engine/game/itac.zig) runs the ITAC,
[`game/itac/debriefing.zig`](../../src/engine/game/itac/debriefing.zig) is DEBRIEFINGS,
[`game/itac/news_reports.zig`](../../src/engine/game/itac/news_reports.zig) is NEWS REPORTS, and
[`game/videoreports/section.zig`](../../src/engine/game/videoreports/section.zig) is VIDEO REPORTS.
The lit shapes, the debriefings' texts, the news items and the video reports are in
[`game/itac/tables.zig`](../../src/engine/game/itac/tables.zig), which `make itac-tables` derives
from the executable. The driver runs the loop
(`Driver.itac` in [`openreliant/rooms.zig`](../../src/openreliant/rooms.zig)), from the rooms and
after each mission of the campaign.

Ported so far: the ITAC's loop, with its movies, its sections' pictures and titles, the fades of
their text, the panes their text wipes in by, the lit shapes, the pointer and the sounds;
DEBRIEFINGS with REPLAY MISSION; NEWS REPORTS; and VIDEO REPORTS. Not yet: the other sections, which
show their pictures with nothing written on them: the fighters
([#463](https://github.com/OpenReliant/openreliant/issues/463)), the capital ships
([#464](https://github.com/OpenReliant/openreliant/issues/464)), the squadrons
([#465](https://github.com/OpenReliant/openreliant/issues/465)) and the personnel
([#466](https://github.com/OpenReliant/openreliant/issues/466)) of either side, and the KILLBOARD
([#467](https://github.com/OpenReliant/openreliant/issues/467)); and the buttons' tooltips
([#468](https://github.com/OpenReliant/openreliant/issues/468)).

**Fixes:**

- A section's title and text fade a step each frame of its movie in and out, over which the fade is
  meant to run: sixteen frames in, five out. The game steps them each frame it draws, so that they
  run faster the faster the machine, and a movie skipped leaves the text as dim as the fade had
  reached. OpenReliant ends it at full.
- After a mission, the game opens DEBRIEFINGS after its movie in, so that the figures fading in over
  the movie are those of whichever debriefing was chosen last. OpenReliant opens it before, as the
  rooms open NEWS REPORTS.
- As another debriefing, news item or video report is chosen, the game holds the screen still for
  half a second, drawing nothing (`itac_pause`, `0x00440170`). OpenReliant shows it at once.
- With no news item listed, NEWS REPORTS draws the picture of the record before its table's first,
  and with no report listed, VIDEO REPORTS crashes, though the campaign always lists one;
  OpenReliant shows none. NEWS REPORTS and VIDEO REPORTS copy a title into a room of 60 and 500
  bytes whatever its length; OpenReliant keeps what fits.
- Where VIDEO REPORTS' list shows every report, its arrow steps the list's first on to -1, after
  which the list lights the report after the chosen one, and a press on a report chooses the one
  before it. OpenReliant keeps the first at 0 or more.
- VIDEO REPORTS draws a still, 116 by 90, into a buffer a column wider and a row taller that it never
  clears, so that the film strip's frames show what the memory held down their right edge and
  along their foot. OpenReliant shows black there.

**Improvements:**

- The times of the sounds now and then, and which plays, are drawn from `std.Random`, where the
  game uses `rand`.
- Its text, in `itacbig.fnt` and `itacsml.fnt`, is drawn with outline fonts at the window's
  resolution: Newtown, or a font from a mod ([Outline fonts](../formats/fnt.md#outline-fonts)).

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
(`itac_section_handlers`, `0x004E9288`): opened, left, loaded, each frame and drawn. Once the ITAC
has closed, it runs each section's handler for leaving it (`0x0043FA4B`).

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

## NEWS REPORTS

The news of the war, an item after each mission the campaign has come through (`news_items`,
`0x004EB0E8`, 24 records): the items whose missions come before the one the campaign has come to,
so that the first shows before mission 1 (`news_list_build`, `0x0044E490`). Each has a title, up to
five paragraphs and a picture of `inter\itac\newsrep.spr`, which the section reads as it opens and
lets go of as it is left (`news_enter`, `0x0044DD90`; `news_leave`, `0x0044DE50`). As it opens,
the latest is chosen, and the list steps on so that it shows at the foot.

- The title, in capitals, in (58, 209, 255).
- The body, in (255, 146, 58), which the arrows below it scroll: the paragraphs, a blank line between
  each two. "(more)" marks a body that runs past its box.
- The picture, the item's shape, at (302, 100), fading with the section. Its palette is that of
  block 0 for the first eleven items of the list, block 13 to the twentieth, and block 26 past it.
- The list of the titles, at most twelve from the first shown, a blank line between each two, the
  chosen in (58, 209, 255). A press on one chooses it, and its title and body wipe in again; the
  arrows step the list on and back.

| What | Where |
|---|---|
| Title | (34, 77), 255 by 20, the title at (36, 79) |
| Body | (34, 101), 258 by 210; arrows at (45, 327) and (70, 327), 25 by 25 |
| "(more)" | Right edge at (292, 306) |
| Picture | (302, 100) |
| List | (470, 101), 150 by 256, the titles from x 480, 134 wide; arrows at (515, 368) and (540, 368), 25 by 25 |

## VIDEO REPORTS

`C:\lancer\game\videoreports.cpp` holds VIDEO REPORTS, the war's video reports
(`video_reports_items`, `0x004EE5B0`, 6 records). It lists those whose missions come before the one
the campaign has come to (`video_reports_enter`, `0x00450540`), so that the first shows before
mission 1. Each has a title, two paragraphs, a still of `inter\itac\vidrep.spr`, which the section
reads as it opens and lets go of as it is left (`video_reports_leave`, `0x00450600`), and a movie in
a disc's archive. As it opens, the first is chosen.

| Report | Listed after mission | Movie | Disc |
|---|---|---|---|
| 1 | 0 | `new_intro.bik` | 2 |
| 2 | 7 | `new_chapter1.bik` | 2 |
| 3 | 13 | `new_chapter2.bik` | 2 |
| 4 | 18 | `foster.bik` | 2 |
| 5 | 19 | `new_chapter3.bik` | 1 |
| 6 | 21 | `new_chapter4.bik` | 1 |

- The title, in capitals, in (58, 209, 255).
- The body, in (255, 146, 58), which the arrows below it scroll: the two paragraphs, a blank line
  between them. "(more)" marks a body that runs past its box.
- The film strip (`video_reports_draw`, `0x00450760`): shape 0x23 of the stills, and the report's
  still three times down it, like frames of a film: its foot, all of it and its head. Both fade
  with the section and use block 26's palette.
- The list of the titles, at most eleven from the first shown, a blank line between each two, the
  chosen in (58, 209, 255). A press on one chooses it, and its title and body wipe in again; the
  arrows step the list on and back.
- The play button. A press holds the screen until the left button is up (`video_reports_play`,
  `0x00450CC0`). After the frame, the ITAC ends every sound, opens the archive of the report's disc
  and plays its movie on a screen cleared to black (`play_bink_movie_resourced`). Then its hum
  plays again, and the sounds now and then start over as when it came on (`0x0043F883` on).

A report holds the part of the campaign it comes from, 1 for the Reliant's and 2 for the Yamato's,
and its movie lies on the disc of that carrier's rooms: the second for the Reliant, the first for
the Yamato. As the ITAC closes, it opens the archive of the carrier's disc again (`0x0043FC31`),
which a report may have changed.

| What | Where |
|---|---|
| Title | (34, 77), 258 by 20, the title at (36, 79) |
| Body | (34, 101), 258 by 165, scrolled in a box 156 high from y 103; arrows at (135, 277) and (160, 277), 25 by 25 |
| "(more)" | Right edge at (292, 264) |
| Film strip | Frame at (297, 97); the still's buffer, 116 by 91: its rows 64 to 89 at (317, 96), all of it at (317, 130), and its rows 0 to 25 at (317, 228) |
| Play button | (360, 277), 40 by 40 |
| List | (470, 104), 150 by 246, the titles from (480, 105), 134 wide; arrows at (514, 368) and (541, 368), 27 by 27 |
