# The radio

`C:\lancer\game\videoreports.cpp` (**Unverified:** the file, placed by the link order) queues the
lines the pilots say and plays them with their faces in the display's window 0, whose films
`C:\lancer\game\hudmovie.cpp` plays ([face films](../formats/fm8.md)). OpenReliant ports both
([`game/videoreports.zig`](../../src/engine/game/videoreports.zig),
[`game/hudmovie.zig`](../../src/engine/game/hudmovie.zig)), and the window's drawing
([`game/hud/radio.zig`](../../src/engine/game/hud/radio.zig)).

## Lines

`radio_say` (`0x004562D0`) takes a film, a speech file ([Speech files](../formats/speech.md)), a
mode, the string that names the speaker, the film's flags, whose line it is (`comms_object`,
`0x0057BDF4`: a ship's slot, a pilot of the pilots' table from `0xFFFF` on, or -1 for nobody) and
how long it keeps, outside a multiplayer mission:

- Mode 0, at once: window 0 opens held unless it is open, with its full time and without the
  display's sound, from however far it had closed; the line playing stops; the window keeps the
  speaker's name (`radio_name`, `0x0057BC4C`), whose the line is and their side (`radio_side`,
  `0x0056993C`: the ship's, the pilot's face's, or friendly for nobody); the speech is read from
  `msspeech.hog` (`radio_speech`, `0x005883CC`) and the film plays (`hudmovie_play`).
- Mode 1, queued. Mode 2, queued unless a line plays or waits (`radio_busy`, `0x004561A0`).

The queue holds five lines (`radio_queue`, `0x005295A0`, `0x74` bytes each: the film's flags, the
speaker's name, the film's path in 50 bytes, the speech file's name in 52, whose it is, and the
tick it expires at, or -1), counted at `0x00529594`, written at `0x00529870` and read at
`0x00529CBE`. `radio_frame` (`0x00456510`), each frame after the controls, while lines wait, window
0 is shut or closing and no speech plays, takes the next and says it unless its time has passed:
the window opens held and names the speaker, and, unless the line is nobody's, the speech is read
and the film plays. A line that is nobody's leaves the window open with nothing in it, which then
closes. The game also leaves out a line of object `0x3E9`, which no slot reaches. A sixth line
queued is dropped.

The pilots' table (`pilot_faces`, `0x005048D8`, 24 bytes each) holds a face for each of the 194
pilots of `pilot_stats`, which `object_set_pilot` points an object at as its pilot record: the
string that names the pilot, a halfword (**Unknown:** `0x53` in every record), the side, the voice
the pilot speaks in flying a hostile ship ([Remarks](#remarks)), and a film for each of four head
movements: talking, laughing, the 45th's own pilot (the same film for every pilot), and dying. `radio_say_pilot`
(`0x00456250`) says a line for a pilot of the table, as `0xFFFF` and its number; `radio_say_ship`
(`0x004561C0`) for a ship, with its pilot's face, unless the ship is a stand-in, exploding, or
without a pilot record. Each names the film `pilots\<film>.fm8` for the head movement the line
asks for. OpenReliant generates the table from the payload (`make face-tables`). **Fix:** for a
head past the four or a pilot past the table, which the game reads beside them, OpenReliant plays
the dead channel's film, with no name.

`radio_reset` (`0x004560F0`), as `hud_init` readies a mission, empties the queue and names nobody;
it also clears the remarks' state and the script's switches over them. **Fix:** the game leaves a
film playing into the next mission, whose first line then starts before its window has opened;
OpenReliant stops it.

## The window

`hudmovie_play` (`0x0048D120`) plays a film and decides when the line starts. With a film playing
already, the line starts at once unless the flags say not (bit 3). Otherwise the line waits for the
window (`hudmovie_waiting`, `0x0057C298`): `hud_draw` counts the frame's ticks
(`hudmovie_waited`, `0x0057C3AC`) and starts the line once they pass 91, 92 ticks after it was said,
as the window has been open for a third of a second. The film's timer holds it at its first frame
meanwhile. Its flags:

| Bit | Meaning |
| --- | --- |
| 0 | the film loops |
| 1 | the film holds for the line: at its end, while the line goes on, the dead channel's film (`pilots\static.fm8`) loops in its place, and once it is over the window closes and the film stops |
| 2 | the film is drawn in its own palette, as every film the game plays is. **Unknown:** the palette the window would draw one without it in (`0x0057BF5C`) |
| 3 | the film starts no line: the dead channel's |

The script's `CommsFromShip` and `CommsFromPilot`, and the radio's own reports, play with 5, the
film looping while the line plays; the `Once` forms with 6, once and then the dead channel's film;
the dead channel's film plays with 13 (`0xD`).

`hud_window_draw`'s case for window 0 (`0x00488035`), from the window's place `(x, y)`:

- In the view ahead while the window closes, the last of its shapes, the emblem.
- A film that has stopped closes the window (and clears `0x00569974`, which nothing reads).
- Once the line has started, a line that is over closes the window and stops the film. While it
  plays, in the view ahead, the speaker's name at `(x + 1, y + 2)` and the film at
  `(x + 13, y + 19)`, each row moved right by a random share of `10 * hit_shake` pixels, drawn
  every pixel, the see-through colour among them.
- While the line waits, in the view ahead, shape `0x131` and on for a friendly speaker, `0x148` and
  on for any other, a shape each 4 ticks of the wait: 23 of them, noise that settles on the emblem
  of the speaker's side.

The window closes with the display's sound. `hud_comms_marker` and the radar mark the ship whose
line it is while the window is open or opening ([The target](hud.md#the-target),
[The radar](hud.md#the-radar)).

**Fix:** the game stops with a fatal error where `pilots.hog` lacks a film, as it does six the
pilots' faces name (`BLKACE`, `C_Scientist` and its death, `Saladin_Cap_D`, `Varygag_Capt` and its
death); OpenReliant plays the dead channel's film in its place. Where `pilots.hog` itself cannot be
opened, which is fatal too, OpenReliant says the lines without the window's films.

## The script's commands

- `PlaySpeech` (`0x06`) plays a speech file at once, without the window or a film, ending the line
  playing; the game reads it into a buffer of its own (`0x005883D0`), which leaves a line waiting
  for the window its own.
- `WaitForSpeech` (`0x07`) waits while a line plays; `WaitForMovie` (`0x09`) while a film plays
  (`hudmovie_playing`, `0x0057C3A8`). The missions wait for the film before each line they say.
- `PlayCommsMovie` (`0x08`) plays the film `pilots\<film>` with a speech file, at once, looping,
  under the string its third argument numbers, the line nobody's. It also sets `0x005373EA`, which
  nothing reads.

The game sets the volumes again as a line first plays in a mission (`0x005297E8`), alike either
way.

## Reports

A report waits its time before it goes to the queue (`0x00529D48`, five of them, `0x7C` bytes
each):

| Offset | Field |
|---|---|
| `+0x00` | In use |
| `+0x04` | Whose it is, as a line's |
| `+0x08` | **Unknown.** Whom it concerns: PERMISSION TO LAND and the wingmen's replies put the player's ship there, and nothing reads it |
| `+0x0C` | **Unknown.** Its kind: only kind 1 is said |
| `+0x10` | The string that names a pilot of the pilots' table who says it; a ship's report is named by its pilot's face |
| `+0x14` | The game tick past which it is said |
| `+0x18` | The film's path, 50 bytes |
| `+0x4A` | The speech file's name, 50 bytes |

`0x004560D0` finds the first free one, or -1, which stops whatever would queue one. `0x00456050`,
each frame after `radio_frame`, lets each whose tick has passed go, and queues it (`radio_say`,
mode 1, flags 5, no expiry) where it is of kind 1 and neither nobody's, object `0x3E9`'s, nor an
exploding ship's; a ship's is named by its pilot's record, a pilot's by the report. `radio_reset`
empties them.

`0x004566C0` plays the pilot's own line at once through the speech sample, without the window,
ending the line playing, unless the mission is a multiplayer one: `0x004536D0` names it `mp` and the
line for a male pilot, `fp` for a female one (`0x00562F16`, which the [pilot roster](front-end.md#the-pilot-roster) sets).

PERMISSION TO LAND ([Landing](orders.md#landing)) has the pilot ask, `hud_012`, and queues the
answer 300 ticks on:

- In a training mission, the flight instructor's, pilot `0x52` named by string `0x100`:
  `pilots\VirtFlt_Ins.fm8` and `trnglnd_001.ut`.
- In any other, the bridge's: pilot `0x54` named by string `0x44` where the carrier is a Yamato,
  pilot `0x3C` otherwise. `0x00453620` makes its line, `yam` and the Yamato's bridge officer's film
  `pilots\Yam_Brdge_Off.fm8` where the carrier is a Yamato or explodes, `rel` and
  `pilots\Rel_Brdge_Off.fm8` otherwise, ending in a suffix `0x00453A50` picks at random by `rand`:
  clearing the ship, from `_lnd_001` to `_lnd_009` for a mission the script rates a success or
  better (`mission_success`), from `_lnd_010` to `_lnd_016` for a partial failure or success, and
  from `_lnd_017` to `_lnd_024` for any other; refusing it, from `_lnd_den_01` to `_lnd_den_04`.
  It also writes "DEBUG: Mission is flagged as a" and the rating's name into a line nothing shows.

## The wingmen's commands

ATTACK MY TARGET (`0x00454C20`), BACK OFF (`0x00454FA0`) and HELP ME (`0x00455330`) go to the
wingman `0x00529596` names: -1, as the keys give them ([Controls](controls.md)), for one the game
picks; a slot, as the radio's menu names one; or -2 and -3, which send the command to another
player of a multiplayer game. The pilot asks first, `hud_001`, `hud_002` and `hud_003`.

ATTACK MY TARGET and BACK OFF are about the player's target (`player_control_entry`), and do
nothing without one. HELP ME is about its attackers: the hostile ships that can be aimed at whose
current order is Fight aimed at the player's ship, or with none, the player's target where it is a
hostile ship that can be aimed at; without either it does nothing.

How a wingman stands to a command:

| Command | Busy | Done already | Free |
|---|---|---|---|
| ATTACK MY TARGET (`0x00454B80`) | not to be disturbed, or its current order has a priority | its current order aimed at the player's target | otherwise |
| BACK OFF (`0x00454F40`) | not to be disturbed | its current order not Fight aimed at the player's target, or none | its current order Fight aimed at the player's target |
| HELP ME (`0x00455280`) | not to be disturbed, or its current order has a priority | its current order Fight aimed at an attacker | otherwise |

The game picks from the ships of the player's wing but the player, not exploding and free: for
BACK OFF one at random (`rand` over their number); for the others one the likelier the farther it
is from the player's ship, a `rand` over 32767 times the sum of their distances falling among the
running sums. A wingman free, or the one picked, takes the command: it fights the player's target
(Fight, order 105); it pops its current order and leaves the player's target be for 3000 game
ticks, which Find New Target then passes over (`+0x6AC`, `+0x6B0`); or it fights one of the
attackers at random. Before it, the game draws a number it does nothing with for a pilot whose
third value (`pilot_stats`, `+0x20`) is 0, 1 or 2. A wingman named that is busy only answers so;
one that has it in hand only answers, BACK OFF's leaving the target be all the same.

The answer is a report, from the wingman to the player, 300 ticks on, its line in the pilot's voice
(`ship_line`) and the film of its face talking. Bandit, Diceman, Viper, Enriquez and Hawkeye have a
fuller set of replies (`0x004539A0`, by the table at `0x004539D0`):

| Command | Busy | Done | Busy, fuller set | Done, fuller set |
|---|---|---|---|---|
| ATTACK MY TARGET | `_amt_001` to `_amt_004` | `_amt_005` to `_amt_008` | `_amt_005` to `_amt_008` | `_amt_009` to `_amt_013` |
| BACK OFF | `_bkoff_001` to `_bkoff_004` | `_bkoff_005` to `_bkoff_009` | `_bkoff_001` to `_bkoff_006` | `_bkoff_007` to `_bkoff_015` |
| HELP ME | `_hlpme_001` to `_hlpme_004` | `_hlpme_005` to `_hlpme_008` | `_hlpme_001` to `_hlpme_006` | `_hlpme_007` to `_hlpme_014` |

**Fix:** the game copies the reply of a pilot with no voice from nowhere, and stops; OpenReliant
leaves it out.

Not ported: a multiplayer game's commands ([#55](https://github.com/vdmkenny/openreliant/issues/55)).

## The menu

The display's window 11, which COMMS WINDOW opens held ([Controls](controls.md)), and the script's
`OpenInstrument` too, shows the radio's menu (`comms_menu_run`, `0x00455D40`): a page of numbered
items. Opening the window starts the menu at its top page and runs it at once; while the window is
open, `hud_target_keys` runs it each frame before its own keys. A run makes the page's items, ten
at most (`0x00529540`, `0x00529CBC` of them), or does what the page is for and closes the window,
held no more, still showing the page before. A page left with no items goes back to the top, which
a page of none makes at once. Then the number keys choose an item, 1 the first and 0 the tenth,
each press once (`key_pressed`), with the display's sound 0: the item's page comes next, about whom
the item names (`wingman_addressed`, `0x00529596`). While the window is open, the keys 1 to 8 do
nothing else. Each page also names a title (`0x00529FB4`), which nothing draws.

| Page | Its items, or what it does |
|---|---|
| -1, COMMS (`0x00453B90`) | Target, to page 0 about the player's target, where it is a hostile ship that can be aimed at, and a fighter, a capital ship or one between by its type's class; Alpha Wing, to page 1, where a ship of the player's wing but the player's is not exploding; Base, to page 2, but in the maps of the multiplayer game's scenarios (`0x004B2D30`: missions 81 to 85 and 87) |
| 0 and 4, a ship (`0x00454370`) | Nothing for a ship exploding. For a hostile ship, the five taunts, pages 6 to 10. For a ship of the player's wing, the three commands, pages 11 to 13, where the player's target is a hostile ship that can be aimed at, and What's your status?, page 14; then, for it and any other friend, Come on... get your act together and Nice work. I owe you one, pages 15 and 16. No item leads to page 4 |
| 1, Alpha Pilots (`0x00453C80`) | Each ship of the player's wing but the player's, not exploding, by its pilot's name and the call sign of its place in the wing, Alpha 1 to Alpha 5 and Alpha Leader (`0x004EF7DC`), to page 0; then, for more than one, Alpha Wing, to page 5 for a wingman the game picks |
| 2, Base (`0x00453D50`) | Permission to land, page 18, and Request backup, page 19 |
| 3, Open channels (`0x00453DA0`) | Open all channels and Close all channels, pages 20 and 21. No item leads to page 3 |
| 5, Alpha Wing (`0x00454570`) | The three commands, pages 11 to 13 |
| 6 to 10 | A taunt (`0x00454870`) |
| 11 to 13 | The command ([The wingmen's commands](#the-wingmens-commands)) |
| 14 | What's your status? (`0x00455720`) |
| 15 and 16 | Come on... get your act together (`0x00455B00`), and Nice work. I owe you one (`0x00455C20`) |
| 17 | Nothing. No item leads to it |
| 18 | PERMISSION TO LAND ([Reports](#reports)) |
| 19 | REQUEST BACKUP (`0x004558D0`) |
| 20 and 21 | Kills credited and remarked on, and no longer (`kill_credit_on`, `0x00529C6C`, which a mission's start sets) |
| 22 to 28 | A multiplayer game's: the other players, messages and the commands to them, and another player's request |

`0x00453A70` draws the menu from 2, 2 of the window's place in the view ahead: COMMS in the
display's font, then from 24 below each item, 12 below the one before, in `newfont.fnt`: its
number and a full stop, and 13 across what it says.

A taunt: the pilot says `hud_007` to `hud_011`. Unless the ship is not to be disturbed, is not a
fighter by its type's class, or its current order has a priority or aims at the player's ship
already, it turns on the player's ship (Fight) and answers 300 ticks on, in its pilot's voice,
`_res_001` to `_res_024`. Six aces answer in lines of their own, by the pilot's number: Black Sun
(10, `hs_res_001` to `hs_res_007`), Ivan Petrov (15, `ip_res_001` to `ip_res_014`), Nicolai Petrov
(16, `np_res_001` to `np_res_010`), Colonel McGann (50, `cm_res_001` to `cm_res_010`), the
Saracens' leader (131, `al_res_001` to `al_res_011`) and the Golden Warriors' (133, `rd_res_001` to
`rd_res_006`). Before it turns, the game draws a number it does nothing with for a pilot whose
third value is 0 or 1.

What's your status?: the pilot says `hud_004`, and a wingman whose pilot has a face and a second
value (`pilot_stats`, `+0x1E`) above 0 answers 250 ticks on, by how whole its armour is: its four
quadrants together over six times its type's armour class, the fraction dropped, less 1, held from
0 to 2.

| Armour | Answer | Fuller set |
|---|---|---|
| 0 | `_status_001` to `_status_004` | `_status_001` to `_status_007` |
| 1 | `_status_005` to `_status_008` | `_status_008` to `_status_015` |
| 2 | `_status_009` to `_status_011` | `_status_019` to `_status_024` |

The scolding and the praise: the pilot says `hud_005` or `hud_006`, and the ship answers 300 ticks
on, `_cmon_001` to `_cmon_004` or, in the fuller set, to `_cmon_012`; `_iou_001` to `_iou_004` or,
in the fuller set, to `_iou_008`.

REQUEST BACKUP: the pilot says `hud_013`. Where the script has set `backup_available` (variable 3,
[The game's variables](script-vm.md#the-games-variables)) and the request has not brought backup
yet this mission (`0x00529CB0`, which a mission's start clears), the player's ship has its
PlayerWantsBackup, on which the script sends the backup, and the bridge of the carrier the ship
launched from answers 300 ticks on that it comes, `_reqbk_001` to `_reqbk_007`; otherwise it
refuses, `_reqbk_008` to `_reqbk_014`. The officer and the lines are PERMISSION TO LAND's.

**Fix:** where the top page itself has no items, the game makes it again and again, and hangs;
OpenReliant leaves the menu empty. The game reads the name of a wingman with no pilot through a null
pointer; OpenReliant names it by its call sign alone. It reads the armour class of a ship with no
type's stats through a null pointer for What's your status?, and the carrier for REQUEST BACKUP
where the ship launched from none; OpenReliant makes no report.

Not ported: a multiplayer game's pages and the chat line they type in (`0x00529FB8`)
([#55](https://github.com/vdmkenny/openreliant/issues/55)).

## Remarks

The game has the pilots speak by themselves on the radio. Moose makes the squadron's remarks: pilot
2 of the pilots' table, the 45th Tigers' Moose, after mission 13, and pilot 4, the 45th Volunteers',
through it. `0x00453A50` picks a line of a table at random by `rand`. Unless it says otherwise
below, each is said talking, the film looping (flags 5), queued (mode 1) and kept for good; mode 2
queues it only while the radio is free.

A ship's pilot speaks in its voice. `ship_line` (`0x00453710`) names the line into `0x00529CC0`:
for a friendly ship, the pilot's number up to `0xB9` indexes a byte table (`0x004538E0`) whose
cases start the line with one of 22 voices, `ban`, `dic`, `fre`, `vip`, `enq`, `sil`, `tak`, `jor`,
`vix`, `cut`, `cla`, `ski`, `jui`, `fac`, `haw`, `arr`, `ner`, `rhi`, `sta`, `fla`, `wor` and
`ego`, or with none; for a hostile ship, the face's halfword at `+0x06` does, 5 `rus`, 6 `chn` and
7 `arb`, any other none. Every pilot of the table is `rus` but a few, of 4 or 0. A pilot with no
voice has no line, which `radio_say` then leaves out. **Fix:** for a ship of any other side the
game leaves the name as it was, the line it made last; OpenReliant has no line.

`DisableGenericComms` leaves the remarks unsaid (`0x00529538`), but for the reminders to jump, the
flight instructor's reminder to land and the ejection's words, and `DisableTaunts` the taunts
(`0x00529CB4`) ([Script VM](script-vm.md)).

`radio_remarks_frame` (`0x00456B90`), each frame after the reports, runs four:

- `radio_landing_reminder` (`0x00456710`): unless the player's ship is landing, while the script's
  `landing_cleared` is set and the mission goes on, the reminder runs (`0x00529878`); otherwise it
  is over. As it begins, in a training mission, the flight instructor, pilot `0x52`, says
  `trnprm_001` once. In any other, 4500 ticks of `frame_start` on and every 4500 after
  (`0x00529D40`), Moose says one of `moolnd_001` to `moolnd_003`.
- `radio_jump_reminder` (`0x00456860`): while the mission has a jump or a warp ready (`jump_ready`,
  `warp_ready`) and goes on, the reminder runs (`0x00529874`). As it begins, the flight instructor
  says `trnjmp_001` in training; Moose otherwise says one of `jmp_001` to `jmp_004` for a jump, or
  of `wrp_001` to `wrp_004` for a warp alone. Outside training Moose then calls the pilot to jump
  every 2000 game ticks (`0x00529D44`), four times (`0x00529598`), from `moo_w1001` to `moo_w1004`
  the first time to `moo_w4001` to `moo_w4004` the fourth; 300 ticks after the fourth, the player's
  ship jumps (`player_jump`).
- `radio_missile_warning` (`0x00456A80`): while a missile homes on the player's ship and the ship is
  neither exploding, ejected nor sent off, at most once in 1000 ticks of `frame_start`
  (`0x005297E4`), Moose says one of `plck_001` to `plck_008`, mode 2, kept 500 ticks.
- `radio_rescue` (`0x00456B10`): 1000 ticks of `frame_start` after a wingman's pilot ejects
  (`0x00529880`), unless the pilot's pod is exploding, the pilot of the ship in the last place of
  the player's wing (`0x00515D92`) says `res_001` to `res_003` in its voice, mode 2. **Fix:** the
  game reads before its objects where the wing has no ship there; OpenReliant says nothing.

The others answer what happens:

| Remark | When | Words |
|---|---|---|
| `radio_kill_remark` (`0x00456BB0`) | The player's kill is credited (`explode_kill_credit`, and a hull lost from a Kurgan, an Antanov or a Gurevich) | A pilot's pod: Moose, `enmejt_001` to `enmejt_003`, mode 2. Anything else, at most once in 600 game ticks (`0x00529CB8`), then only while the radio is free: a fighter's pilot says `dth_001` to `dth_006` in its voice, dying, once (flags 6), kept 200 ticks, and Moose `plyrkl_001` to `plyrkl_009`, kept 500; a torpedo has Moose say `trpkl_001` to `trpkl_006`, mode 2, kept 500 |
| `radio_ship_lost` (`0x00456CF0`) | A ship of the player's wing is lost, but the player's, while the radio is free | Its pilot, `dth_001` in its voice, dying, once, mode 2; then Moose, `npcdth_001` to `npcdth_004` |
| `radio_wingman_ejected` (`0x00456D80`) | The pilot of a ship of the player's wing ejects, but the player's (`order_eject_init`) | The pilot, `ejt_001` in its voice, mode 2; the rescue waits its time |
| `radio_enemy_taunt` (`0x00456DD0`) | A ship's shot or missile, damage of kind 0, 1 or 5, strikes the player's ship (`object_damage`, `object_armor_damage`) | A hostile ship not listing components, at most once in 2000 ticks of `frame_start` (`taunt_next`, `0x005297EC`): `tnt_001` to `tnt_013` in its voice, mode 2, unless the taunts are unsaid |
| `radio_launch_line` (`0x00456E50`) | The player's launch goes (`order_launch`) | The flight instructor in training, `trnlch_001`; otherwise the Reliant's bridge officer, pilot `0x3C`, `relbdg_001` to `relbdg_006`, or the Yamato's, `0x54`, `yambdg_001` to `yambdg_005`, mode 2; from anything else none |

`explode_kill_credit` clears the ship's exploding flag while it runs, so that the dying pilot may
speak (`radio_say_ship` passes over an exploding ship), and puts back the flags it found.

The ejection has Moose's words too ([The ejection](ejection.md)): `ejt_001` to `ejt_008` calling
the pilot to eject, `ejt_015` or `ejt_016` as the pilot calls from the pod, and `nanpkup`,
`antpkup` or `ejtkll` on the pilot's fate, each queued.

The game's mode `0x00524FE4` 1 counts as training for the reminders and the launch's words. Not
ported: that mode.

## Speech

A line plays through the speech sample ([Sound](sound.md#speech)), its peaks rounded off and in
the cockpit's cabin unless `--original`.
