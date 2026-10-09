# The ITAC

The ITAC (`itac`, `0x0043EFC0`, `C:\lancer\game\itac.cpp`) is the terminal that Use ITAC opens in
the Reliant's rooms and the Yamato's ([The Reliant's rooms](rooms.md)), and which `WinMain` opens
after each mission of the campaign for its debriefing. It runs in a loop of its own on a screen 640
by 480. Nine buttons along its foot open its sections, each with a movie in, a movie out and a
picture of its own that its text is written on; the last button closes it. Its strings are
`ITACLANG.DLL`'s, read as it opens (`itac_language_init`, `0x00440770`).

## In OpenReliant

[`game/itac.zig`](../../src/engine/game/itac.zig) runs the ITAC. Its sections are DEBRIEFINGS
([`game/itac/debriefing.zig`](../../src/engine/game/itac/debriefing.zig)), NEWS REPORTS
([`game/itac/news_reports.zig`](../../src/engine/game/itac/news_reports.zig)), VIDEO REPORTS
([`game/videoreports.zig`](../../src/engine/game/videoreports.zig)), the fighters, capital ships,
squadrons and personnel of either side
([`game/itac/fighters.zig`](../../src/engine/game/itac/fighters.zig),
[`game/itac/ships.zig`](../../src/engine/game/itac/ships.zig),
[`game/itac/squadrons.zig`](../../src/engine/game/itac/squadrons.zig),
[`game/itac/personnel.zig`](../../src/engine/game/itac/personnel.zig)) and the KILLBOARD
([`game/itac/killboard.zig`](../../src/engine/game/itac/killboard.zig)), and
[`game/itac/tooltips.zig`](../../src/engine/game/itac/tooltips.zig) holds the buttons' tooltips. The
lit shapes, the debriefings' texts, the news items, the video reports, the fighters, capital ships,
squadrons and personnel, and the KILLBOARD's pilots are in
[`game/itac/tables.zig`](../../src/engine/game/itac/tables.zig), which `make itac-tables` derives
from the executable. The driver runs the loop
(`Driver.itac` in [`openreliant/rooms.zig`](../../src/openreliant/rooms.zig)), from the rooms and
after each mission of the campaign.

OpenReliant ports the whole ITAC: its loop, with its movies, its sections' pictures and titles, the
fades of their text, the panes their text wipes in by, the lit shapes, the pointer, the sounds and
the buttons' tooltips, and every section.

**Fixes:**

- A section's title and text fade a step each frame of its movie in and out, over which the fade is
  meant to run: sixteen frames in, five out. The game steps them each frame it draws, so that they
  run faster the faster the machine, and a movie skipped leaves the text as dim as the fade had
  reached. OpenReliant ends it at full.
- After a mission, the game opens DEBRIEFINGS after its movie in, so that the figures fading in over
  the movie are those of whichever debriefing was chosen last. OpenReliant opens it before, as the
  rooms open NEWS REPORTS.
- As another entry of a section's list is chosen, the game holds the screen still for half a second,
  drawing nothing (`itac_pause`, `0x00440170`). OpenReliant shows it at once.
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
- The capital ships' second text arrow stands at (349, 204), overlapping the first, which wins where
  they overlap. So the right 10 pixels of the second arrow light up but don't scroll the text.
  OpenReliant moves it to (359, 204), where it covers the arrow that lights up.
- The squadrons draw the picture of the record at the chosen squadron's place in the whole table,
  so that past a squadron the Alliance's list leaves out, each shows the picture of one before it.
  OpenReliant draws the chosen squadron's.
- A portrait past shape 41, which `persons.spr` doesn't hold, takes its palette's block from the
  bits of the fade. OpenReliant draws it with the last palette's.
- The KILLBOARD adds up the kills of a twentieth record past its nineteen pilots, which runs into
  the loadout's colours for its panels' text (`loadout_text_remap`, `0x004EA308`), and never lets
  go of the portraits it reads each time it opens. OpenReliant adds up the nineteen's, and lets go
  of the portraits as the board is left.
- The game adds ten tooltips for the nine buttons, the tenth read from the bytes after their table.
  Its rectangle lies far off the screen, so it never shows; OpenReliant adds the nine.

**Improvements:**

- The times of the sounds now and then, and which plays, and the KILLBOARD's kills are drawn from
  `std.Random`, where the game uses `rand`. The kills still come from the campaign's seed, so that
  a campaign shows the same board each time.
- Its text, in `itacbig.fnt` and `itacsml.fnt`, is drawn with outline fonts at the window's
  resolution: Newtown, or a font from a mod ([Outline fonts](../formats/fnt.md#outline-fonts)).

## Opening and closing

| | Use ITAC in the rooms | After a mission (`WinMain`, `0x004AA696`) |
|---|---|---|
| Opening | Sound 4 of `itacsnd.fat`, then, by the mission's carrier ([The carrier](rooms.md#the-carrier)), the pilot's eye read on the Reliant, `itac_eye_recog.bik` from the disc, or `inter\itac\itac open.bik` on the Yamato | None |
| First section | NEWS REPORTS | DEBRIEFINGS, with REPLAY MISSION for the latest |
| After | The rooms, from where the ITAC leaves the pilot | The rooms for the next mission, or with REPLAY MISSION the mission again |

In both, sound 3 plays at `0x50` as the screen comes on, `inter\itac\itacinit.bik`, which leaves the
picture `itactrans_00014`. Then its hum, sound 0, plays over and over at `0x40`, and now and then
sound 2 or 7 at `0x50`: the first between 500 and 700 game ticks later, each other between 500
and 1300 after the last (`0x0043F654`).

Escape, or the last button's movie in, closes it (`0x0043FA70`, `0x0043FADB`): the hum fades, sound
6 plays at full volume, `inter\itac\itaclose.bik` plays on the Yamato, and the screen holds until
the sound has faded out. Every sound then ends. Escape leaves the section shown without its handler
for leaving it.

## The screen

Each section writes its text on its picture, `inter\itac\itactrans_NNNNN.tga`, into panes that
wipe in from the left, 14 pixels a tick of the ITAC's timer, 30 ticks a second (`itac_timer`,
`0x0043FC60`; `itac_panes_draw`, `0x0043FF50`). The panes show only while no fade runs. The title
stands at (167, 22) in `itacbig.fnt`, in (236, 105, 77); the rest is in `itacsml.fnt`.

The ITAC draws its shapes straight into the frame, over the picture behind it: the device locks the
frame after the picture and runs the ITAC's render hook (`srd3d.dll`, `0x10003410`). So their pixels
of index 0 show in the palette's colour 0, black in every set the ITAC draws, rather than letting the
picture show through.

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

**Improvement:** a game mode with `debriefing` opens the ITAC after each mission that goes on to the next, as the StarLancer trial does ([Game modes](../guide/scripting.md#game-modes)). Only DEBRIEFINGS and EXIT open (`Itac.sections`), and the other buttons do nothing. The debriefings come from the mode's own record of its missions, kept apart from the campaign's, in the text of the mode's records (`records.itac_text`). REPLAY MISSION flies the mission again from its briefing.

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
  "(more)" marks a body that runs past its box. **Improvement:** OpenReliant takes the paragraphs,
  the medal, the ribbon and the fighters from the mission's settings, which mods can change
  ([Each mission of the campaign](../guide/scripting.md#each-mission-of-the-campaign)).
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

**Improvement:** OpenReliant takes the items from the missions' settings, which mods can change
([Each mission of the campaign](../guide/scripting.md#each-mission-of-the-campaign)). A mission's
items are listed from the rooms before it on, so the original's item after mission 0 belongs to
mission 1, and so on. The list holds up to 255 items, where the game's
holds its table's 24; past that, the oldest make room.

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

**Improvement:** OpenReliant takes the reports from the missions' settings, which mods can change
([Each mission of the campaign](../guide/scripting.md#each-mission-of-the-campaign)). A mission's
reports are listed from the rooms before it on, so the original's report after mission 7 belongs to
mission 8, and so on. A report names the carrier whose disc holds its
movie. The list holds up to 255 reports, where the game's holds its table's 6.

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

## The sides

The fighters, the capital ships, the squadrons and the personnel show either side's, the Alliance's
as each opens. Two buttons at the top right choose the side, the Alliance's at x 551 and the
Coalition's at x 478, each section's own (`0x004E5460` and the others). A press on the other side's
plays sound 8 at `0x50`, lists the side's from its first, and builds the section again. The side's
emblem, shape 25 or 24 of `itacgfx.spr` with block 23's palette, stands over its button, fading with
the section, and the title names the side.

## The fighters

ALLIANCE FIGHTERS and COALITION FIGHTERS list every fighter of the side, twelve and nine: the
loadout's own records (`loadout_alliance_ships`, `0x004E5470`; `loadout_coalition_ships`,
`0x004E57A0`). As the section opens, `loadout_ship_bars_init` works out each one's bars from the
ships' stats, as the loadout does ([The loadout](loadout.md)).

- The name, in capitals, in (58, 209, 255).
- The picture of `inter\itac\fighters.spr` at (91, 65), fading with the section, with the palette of
  the last block of the file's before its shape: 0, 5, 10, 15, 17, 22 or 27.
- The figures, labels in (255, 189, 130) and values right-aligned in (255, 146, 58), 15 apart:
  Type; Clearance, on the Alliance's side only; and the bars, from 3 to 10, of Speed Rating,
  Acceleration, Agility Rating, Shield Strength, Shield Recharge and Armor.
- The armament: Afterburner Fuel in seconds, Armament with a gun a row, a count before each that
  has one, Crew, and the special abilities in a paragraph below.
- The list of the names, the chosen in (58, 209, 255). A press on one chooses it.

| What | Where |
|---|---|
| Name | (32, 80), 113 by 13 |
| Figures | (33, 252), 200 by 138, values right-aligned at x 232 |
| Armament | (253, 252), 207 by 138, values right-aligned at x 452 |
| List | (474, 146), 146 by 218, the names from x 484, 126 wide |

## The capital ships

ALLIANCE SHIPS and COALITION SHIPS list every capital ship of the side (`0x004E42C0`, 21 records,
then 27).

- The name, in capitals, in (58, 209, 255), then Commissioned, Type, Displacement, Propulsion,
  Spacecraft, Armament and Crew, 15 apart.
- The picture of `inter\itac\capships.spr` at (57, 234), fading with the section, with the palette of
  the last block of the file's before its shape: every third block, from 0 to 54, is a palette.
- PROFILE, over the description, which its arrows scroll. The Reliant's and the Yamato's continue in
  a second string each (`0x004241F8`). "(more)" marks a description that runs past its box.
- The list of the names, down to the foot of its pane, with arrows on either side that step it on,
  no further than to leave 13 showing, and back. A press on a name chooses it.

| What | Where |
|---|---|
| Name and figures | (33, 80), 200 by 138, values right-aligned at x 232 |
| PROFILE | (255, 81), 215 by 24 |
| Description | (255, 103), 207 by 88, scrolled in a box 94 high from y 88; arrows at (332, 204) and (359, 204), 27 by 27 |
| "(more)" | Right edge at (462, 187) |
| List | (474, 140), 146 by 220, the names from x 484, 126 wide; arrows at (514, 367) and (541, 367), 27 by 27 |

## The squadrons

ALLIANCE SQUADRONS and COALITION SQUADRONS (`0x004EBD10`, 19 records; `0x004EBF28`, 8). The
Alliance's list follows the campaign: the 45th Volunteers show before mission 13 and the 45th Flying
Tigers from it, and the 51st Volunteers up to mission 9 (`0x00450440`). **Improvement:** OpenReliant
follows the mission's rules, the 45th's name as the radio's films and the KILLBOARD have it, after
mission 13, which gives the same in every mission the original campaign reaches
([Rules by mission number](missions.md#rules-by-mission-number)).

- The name, in capitals, in (58, 209, 255), then Class, Leader, Base and Nation, 28 apart.
- The picture of `inter\itac\squads.spr` at (80, 263), with the palette its record names, fading
  with the section.
- PROFILE, over the history, which its arrows scroll. After mission 6, the 705 Cobras' tells of the
  inquiry into their colonel (`0x00450235`, [Rules by mission number](missions.md#rules-by-mission-number)). "(more)" marks a history that runs past its box.
- The list of the names, down to the foot of its pane; the Alliance's has arrows that step it on,
  no further than to leave 13 showing, and back. A press on a name chooses it.

| What | Where |
|---|---|
| Name and figures | (32, 79), 185 by 140, values right-aligned at x 209 |
| PROFILE | (235, 80), 229 by 15 |
| History | (235, 101), 229 by 103; arrows at (325, 215) and (352, 215), 27 by 27 |
| "(more)" | Right edge at (464, 203) |
| List | (472, 136), 147 by 223, the names from x 482, 126 wide; arrows at (515, 367) and (542, 367), 27 by 27 |

## The personnel

ALLIANCE PERSONNEL and COALITION PERSONNEL (`0x004EB430`, 30 records, then 6).

- The name, in capitals, in (58, 209, 255), then Age and Nationality, and Ship and Callsign where
  the person has them, 26 apart.
- The portrait of `inter\itac\persons.spr` at (296, 76), with the palette of the last block of the
  file's before its shape: 0, 9, 18, 24, 33 or 35.
- PROFILE, over Military History, Training and Background, each heading on a line of its own above
  its text, which the arrows scroll. "(more)" marks a profile that runs past its box.
- The list of the names, down to the foot of its pane; the Alliance's has arrows as the squadrons'
  do. Only choosing the side brings it back to its top.

| What | Where |
|---|---|
| Name and figures | (34, 77), 225 by 144, values right-aligned at x 258 |
| PROFILE | (35, 244), 405 by 22 |
| Profile | (35, 266), 405 by 60; arrows at (44, 342) and (71, 342), 27 by 27 |
| "(more)" | Right edge at (440, 323) |
| List | (474, 138), 146 by 218, the names from x 484, 126 wide; arrows at (514, 367) and (541, 367), 27 by 27 |

## KILLBOARD

The pilots of the Reliant's squadrons (`0x004E9A08`, 19 records) and the player, best first, five
at a time from the first shown; the arrows at (293, 377) and (319, 377), 26 by 26, step the board
on and back. It opens with sound 5 and wipes in at (30, 72), 593 by 295.

- Each pilot starts with their kills, and each mission flown before the one the campaign has come
  to adds a draw round their mean, more or less half their spread (`killboard_kills`,
  `0x00441460`), from the campaign's seed (`killboard_seed`, `0x00562F10`). Missions 12, 13, 17 and
  22, which the campaign doesn't fly, add none, and Klaus Steiner adds none from mission 19 to 23.
  **Improvement:** OpenReliant passes over whichever missions the campaign's order doesn't have, so
  missions a mod puts back add their kills ([The campaign's
  missions](../guide/scripting.md#the-campaigns-missions)). Not yet in the records: the pilots, and
  the missions they join, leave and sit out ([#1008](https://github.com/OpenReliant/openreliant/issues/1008)).
- The board follows the campaign: John McGann and Brad Callan leave it after mission 5, Zoran
  Grandoni after 12, Angelo Fuser and Joe Dabo after 21, Manzo Takamatsu after 22 and Matt Moreno
  after 25, and Linc Stevenson joins it at mission 6 (`0x00441320`).
- Each row has the place in `itacbig.fnt` at (50, 109) down, the portrait of `inter\itac\kills.spr`
  at (72, 97), the name and the squadron at x 135, the ship at x 288, and the kills at x 441, each
  row 55 below the last. PILOTS, SHIP and TOTAL KILLS head the columns in (58, 209, 255).
- The player's row has their call sign over their squadron, the 45th Volunteers, which flies as the
  45th Flying Tigers from mission 14, as the 45th's pilots do, and their portrait by whether the
  pilot is female. The 45th's portraits take block 0's palette, the others' block 6's.

## Tooltips

As the pointer rests on a button, its tooltip shows under it: View Debriefings to Exit ITAC, strings
`0x712` on (`itac_tooltips_add`, `0x00440EB0`). It shows after 100 game ticks, or at once where a
tooltip showed in the last 30, 38 below the pointer, or 19 above it where that would put it below y 450.
Until then it follows the pointer (`tooltips_update`, `0x00440C40`). It is written in `newfont.fnt`
in a black box edged in grey, palette entries 0 and 100 of `itacgfx.spr`'s block 29, kept 6 clear of
the screen's right edge (`tooltip_draw`, `0x00440D80`). The tooltips show while no fade runs.

The multiplayer front end's screens show the same tooltips, with the game's strings rather than the
ITAC's (`tooltips_init`, `0x00440B30`, with 1): the connection, the sessions and a session's
loadout ([Front end](front-end.md)). They come with those screens, which OpenReliant doesn't have yet
([#813](https://github.com/OpenReliant/openreliant/issues/813),
[#404](https://github.com/OpenReliant/openreliant/issues/404)).
