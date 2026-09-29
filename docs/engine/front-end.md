# Front end

The screens the game shows outside a mission: the main menu, the pilots, the settings, the briefings and the rest. `interface.cpp` holds them, and GenILib's `interf.cpp` runs them.

**Unverified:** the files of the code between the two files' known code (`0x004282C6` to `0x004296A0`, [Source files](../binary/sources.md)). `interface_run` and the front end's start-up run the screens, so OpenReliant puts them with GenILib's `interf.cpp`; the main menu and its drawing are one of the game's screens rather than what runs them, so they go with `interface.cpp`.

## In OpenReliant

[`genilib/interf.zig`](../../src/engine/genilib/interf.zig) runs the screens (`interface_run`) and opens what they draw with. [`game/interface/`](../../src/engine/game/interface) holds the screens: the front end's screen and pointer in [`canvas.zig`](../../src/engine/game/interface/canvas.zig), the main menu in [`main_menu.zig`](../../src/engine/game/interface/main_menu.zig), the pilot roster in [`pilot_roster.zig`](../../src/engine/game/interface/pilot_roster.zig), and the YES or NO dialog in [`dialog.zig`](../../src/engine/game/interface/dialog.zig). The picture behind the screens is `matmanager.Background` ([`game/matmanager.zig`](../../src/engine/game/matmanager.zig)). The loading screens are in [`game/xtrabits/loading.zig`](../../src/engine/game/xtrabits/loading.zig).

OpenReliant opens in the front end unless `--mission` names a mission. The pilot roster's START GAME leads into the Reliant's rooms ([The Reliant's rooms](rooms.md)). A mission the front end or the rooms start flies at once, after the music's fade and the hangar's movie but for INSTANT ACTION's, and when it ends, OpenReliant plays the landing or a chapter's end ([Movies](movies.md#around-a-mission)) and goes back to the main menu; LEAVE MISSION goes back without them.

Ported so far: the screen loop, the main menu, QUIT's dialog, INSTANT ACTION, the pilot roster with SET GAME DIFFICULTY, the Reliant's rooms with a new pilot's induction, the news report and the in-game options, the briefing ([Briefing](briefing.md)), the loading screens, the intro and the transitions between the screens ported, and the movies around a mission ([Movies](movies.md)). Not yet:

- The other screens ([#43](https://github.com/vdmkenny/openreliant/issues/43) maps them). The loadout is ported but for its missile page and its internal guns view ([Loadout](loadout.md)). MULTI PLAYER ([#404](https://github.com/vdmkenny/openreliant/issues/404)) and GAME OPTIONS ([#400](https://github.com/vdmkenny/openreliant/issues/400)) stay on the main menu, and LOAD GAME ([#75](https://github.com/vdmkenny/openreliant/issues/75)) on the pilot roster.
- The debriefing after a mission, the ITAC's ([#419](https://github.com/vdmkenny/openreliant/issues/419)), which the campaign's way on opens ([#74](https://github.com/vdmkenny/openreliant/issues/74)).
- The movies between the screens not yet ported, which come with their screens ([Movies](movies.md)).

**Fix:** a screen takes no press until the button held as it was entered comes up. The movie between two screens gives the press that chose the second time to end; where the transitions are off, the game lets it go on to what lies under the pointer on the new screen.

**Improvements**, each marked so in the code:

- The game switches the display to 640 by 480 for the front end. OpenReliant keeps the window as it is, and draws the front end as large as fits in it, centred, so that it keeps its shape.
- The pointer is where the system's is over the window, rather than DirectInput's movements added up.
- OpenReliant's version is written, dimmed, in the window's bottom right corner, as the pause menu writes it ([Pause menu](pause-menu.md)): on the front end's screens, the loading screens and the in-game options over the Reliant's rooms ([The Reliant's rooms](rooms.md)), though not in the rooms themselves.

## The screens

`interface_run` (`0x004289D0`) runs the screen whose number `interface_screen` (`0x0051DAC4`) holds, each until it returns nonzero. A screen that leads to another sets the number and returns 0. Between screens the render hook (`sr + 0x88`) is `0x0043E730`.

| Screen | Function | Issue |
|---|---|---|
| 0, the main menu | `main_menu` (`0x00428B60`) | [#396](https://github.com/vdmkenny/openreliant/issues/396) |
| 1, GAME OPTIONS; 3, audio; 15, video; 16, controls | `0x0042A620`, `0x0042DAB0`, `0x0042E9B0`, `0x0042B690` | [#400](https://github.com/vdmkenny/openreliant/issues/400) |
| 7, the briefing ([Briefing](briefing.md)) | `interface_briefing` (`0x00437010`) | |
| 8, the landing movie: a second's wait, then `play_landing_movie` ([Movies](movies.md#the-landing)), and 3 | `landing_movie_screen` (`0x0043CA30`) | |
| 10 and 11, the multiplayer sessions | `0x0043CA50`, with `0x0051D54C` set or clear | [#404](https://github.com/vdmkenny/openreliant/issues/404) |
| 12, the pilot roster | `0x00430490` | [#397](https://github.com/vdmkenny/openreliant/issues/397) |
| 13, the saved games | `0x00431730` | [#75](https://github.com/vdmkenny/openreliant/issues/75) |
| 14, the multiplayer connection | `0x00432FC0` | [#404](https://github.com/vdmkenny/openreliant/issues/404) |
| 17 and 18, a session's loadout | `0x0044B950`, with `0x0051D54C` set or clear | [#404](https://github.com/vdmkenny/openreliant/issues/404) |

Any other number returns 3. **Unknown:** what selects screen 8: `WinMain` plays the landing itself. What `interface_run` returns tells WinMain what to do:

| Returned | Meaning |
|---|---|
| 1 | The single-player campaign: the Reliant's rooms before the mission ([The Reliant's rooms](rooms.md)), or, where `skip_briefing` is set, the mission without its briefing |
| 2 | Fly the mission |
| 3 | Quit |
| 4, 5 | Set the display up again, then the front end again |

## Start-up

`interface_init` (`0x004288E0`) reads `bank_stdsmp` from `stdsmp.fat`, and opens three fonts: `handel.fnt` (`interface_font_handel`), `interface\optfnt.fnt` (`interface_font_large`) and `interface\smlfnt2.fnt` (`interface_font_small`). It makes `interface_text_remap` (`0x00520284`), 0xFF for level 0 and each level 1 to 15 itself.

## Text

The front end writes with `hud_text` and `hud_text_wrapped` through `interface_text_remap`, ramped by `interface_palette_ramp` (`0x004287C0`), the front end's copy of `hud_palette_ramp` ([Pause menu](pause-menu.md)): entries 1 to 15 of VFX's global palette, a ramp of a `0xRRGGBB` colour at `palette_ramp_brightness`. Level 16, which a few glyphs of the fonts use in their first column, reads past the table into the low byte of `dialog_button` (`0x00520294`): -1, clear, while no dialog's button is under the pointer, and otherwise palette entry 0 or 1. **Fix:** OpenReliant leaves it clear.

**Improvement:** with the crisp filter, the default, the menus' text is drawn from its glyphs' coverage at the window's size: each of a glyph's pixels a square of its own coverage, eased into the next over a pixel of the frame, so that the letters keep the fonts' own shapes and greys, crisp, at any size, where a glyph magnified as it stands comes out soft ([Renderer](../port/renderer.md)). `--original` draws them as they stand, bilinearly.

| Colour | Where |
|---|---|
| `0x40BCFF` | The main menu's labels, the pilot roster's, and the dialogs |
| `0xFDB951` | A panel's labels under the pointer |
| `0xFFFFFF` | On the pilot roster, the call sign while it is typed, the list's call signs, and a button's label under the pointer; in the in-game options, a button's label under the pointer |
| `0xFF0000` | The developers' text |

## The pointer

`interface_pointer_update` (`0x004360D0`), once a pass of a screen's loop:

- DirectInput's movement moves `interface_pointer_x` and `interface_pointer_y` (`0x00520274`, `0x00520270`), which stay on the screen.
- `interface_pointer_ticks` (`0x0051DABC`) runs on by the ticks since the last call, back to 0 once it reaches 64. The pointer is shape 1 + ticks / 4 of the screen's set: 16 shapes, 4 ticks each.
- `interface_pointer_down` (`0x0051DA0C`) is whether the left button is down; `0x0051D9D4` whether the right is.

A screen chooses what lies under the pointer while the left button is down, rather than as it goes down. `interface_hit` (`0x0043EB30`) finds the first of a list of rectangles, each four shorts (corner and size), that holds the pointer, the edges left out.

## The main menu

`main_menu` (`0x00428B60`) shows `interface\sl_splash2.tga` behind itself (`background_set`) and reads `interface\frontend.spr` (`interface_shapes`, `0x0051D60C`, which holds the shown screen's shapes), which it frees as it leaves. It starts the pointer at (320, 200), `music\New_Pensive.wav` at 127 where no music is playing, and a new campaign (`campaign_new`). OpenReliant, which has no campaign yet, starts every mission from a new campaign's variables ([Script VM](script-vm.md)).

Its items are `main_menu_hotspots` (`0x004E5B90`), six shorts each: the corner and size where the pointer finds the item, what choosing it returns, and the shape a panel shows lit. The buttons' shape, 24, goes unused: the drawing lights them with shape `0x1C`.

| Item | Corner | Size | Returns | Shape | Leads to |
|---|---|---|---|---|---|
| SINGLE PLAYER | (27, 123) | 184 by 290 | 0 | 18 | Screen 12 |
| MULTI PLAYER | (203, 125) | 184 by 290 | 0 | 19 | Screen 14 |
| GAME OPTIONS | (421, 165) | 184 by 290 | 0 | 20 | Screen 1 |
| QUIT | (332, 441) | 20 by 15 | 3 | 24 | Its dialog |
| INSTANT ACTION | (300, 441) | 20 by 15 | 0 | 24 | Mission 29 |

Each pass of its loop:

1. Escape asks whether to quit.
2. The next letter of POTATO typed with Control moves the developers' code on; the last sets `developer_mode` (`0x005D5641`) until the game quits. With it set, the developers' keys follow.
3. The pointer, and the item under it (`main_menu_item`, `0x0051D544`). With the left button down over an item, the click plays, sound 11 of `bank_stdsmp` at 127, panned to the middle. QUIT asks whether to quit, and the others lead where the table says, SINGLE PLAYER, MULTI PLAYER and GAME OPTIONS after a transition movie (`0x004AB6E0`).

`interface_confirm` asks whether to quit, with Do you really want to Quit? (string `0x374`). YES returns 3.

INSTANT ACTION (`0x0042905B` to `0x004290E4`) flies mission 29 in ship type 2 in the simulator:
`simulator` (`0x0057E044`) set, and the game's mode (`simulator_mode`, `0x00524FE4`) 2, which the
loading screen names "Preparing for Instant Action", as it names mode 1, the Reliant's simulator's
training, "Calibrating Simulator". The music fades, the loadout's ship is type 2, and the mission
starts again for as long as the pause menu's RESTART asks (`mission_restart`); then `mission_number`
and the pilot's kills go back to what they were, and the main menu comes back.

In the simulator the wingmen's keys go unheard ([Controls](controls.md)), the display's clock
counts the script's `countdown` down ([Display](hud.md#the-radar)), the player's ship is armed by
loadout tier 0 where the script replenishes it (`ReplenishWeapons`), and the wing takes no pilots
from the roster.

OpenReliant flies mission 29 so, RESTART starting it again as for any mission, and comes back to
the main menu as it ends.

### The developers' keys

With `developer_mode` set:

- A number key types a digit of `mission_number`: after one digit it adds a second, after two it starts again.
- Enter with Shift flies the mission without its briefing, in ship type 0, as Shift with F1 does (`skip_briefing`).
- Enter with Control leads to the mission's briefing from the loadout on (`briefing_from_loadout`, [Briefing](briefing.md)), in ship type 0 and the campaign's tier 0, and from there back to the main menu.
- Shift with F1 to F10, F11 or F12 flies it without its briefing, in ship type 0 to 11.

### Drawing

`main_menu_draw` (`0x004291C0`), the render hook:

1. The panels' labels, two lines each, centred, in `interface_font_large`: SINGLE PLAYER at (116, 340) and (116, 356), MULTI PLAYER at (320, 340) and (320, 356), GAME OPTIONS at (524, 340) and (524, 356).
2. In `interface_font_small`: QUIT to the right of (360, 439), INSTANT ACTION to the left of (296, 439).
3. Shape `0x1B` at (332, 441) and at (300, 441), the two buttons.
4. The item under the pointer: a panel's lit shape at its corner, with its labels again in gold, or shape `0x1C` in the button's place.
5. The dialogs (`interface_confirm_draw`, `interface_message_draw`).
6. The pointer.
7. With `developer_mode` set, `M` and `mission_number` at (5, 5) in red, in `font_01.fnt`.

The shapes take the palette of their block's set: the pointer's the first, the lit panels' block `0x11`, the buttons' block `0x16`.

## The dialogs

`interface_confirm` (`0x0042AA80`) reads `quit.spr` (`dialog_shapes`) and asks a question, a string or `dialog_text` for -1, until Escape, which answers NO, or a click on YES or NO (`dialog_buttons`, `0x004E5CB8`: (286, 269) and (326, 269), 25 by 16), answered once the button comes up. It returns true for YES. While it is up (`dialog_open`), the screen's render hook draws it (`interface_confirm_draw`, `0x0042AB60`):

1. The box, shape 6 at (114, 177).
2. The buttons, shape 3, the one under the pointer shape 4.
3. The question, centred on (320, 208) in lines at most 400 wide, 14 apart, at most 10: a string in `interface_font_large`, `dialog_text` in `interface_font_small`.
4. YES to the left of (282, 263), NO to the right of (354, 263), in `interface_font_large`.

`interface_message_draw` (`0x0042ADE0`) draws the front end's other dialog, a message with OK, while `0x0051D7D8` is set.

`interface_box` (`0x00435C60`) frames a box on the screen: its top and left edges in `0x00A7FF`, its right and bottom in `0x005785`, each a pixel short of the corner the other starts from, and a second frame a pixel inside in `0x0086CD`.

## The pilot roster

`pilot_roster` (`0x00430490`), screen 12, which SINGLE PLAYER leads to, shows `interface\main2sin.tga` behind itself and reads `interface\frntend2.spr` (`interface_shapes`), which it frees as it leaves. Its render hook is `pilot_roster_draw` (`0x00430C60`). As it starts, the pilot is a man (`pilot_female`, `0x00562F16`), the call sign is typed afresh (`0x0052019C`) with the characters typed so far let go (`typed_keys_clear`, `0x004AADA0`), its cursor shows (`0x0052016C`), and the list of call signs is closed (`0x005202B8`). While the roster is up (`0x005D6088`), the window's procedure refuses the characters a file's name can't hold, `\/:*?<>|"` (`0x0050954C`), since the call sign names the pilot's saved games.

Its items, in the order `interface_hit` tries them:

| Item | Corner | Size | Does |
|---|---|---|---|
| The man | (62, 145) | 111 by 228 | The pilot a man |
| The woman | (239, 151) | 102 by 275 | The pilot a woman |
| LOAD GAME | (397, 295) | 133 by 20 | Screen 13, the saved games, after a transition movie |
| START GAME | (397, 249) | 145 by 20 | SET GAME DIFFICULTY |
| MAIN MENU | (292, 441) | 25 by 16 | Screen 0, after a transition movie |
| The call sign | (397, 177) | 138 by 45 | The call sign typed afresh, with the characters typed so far let go |
| QUIT | (324, 441) | 60 by 16 | QUIT's dialog, whose YES quits the game (`0x004AAA30`) |
| The list's arrow | (543, 200) | 27 by 15 | Opens or closes the list, once for each press |

Each pass of its loop:

1. Escape leads to the main menu, as MAIN MENU does.
2. The cursor turns on or off once 25 ticks have passed since it last did (`0x00520164`).
3. Enter, or the keypad's Enter, ends the typing. So does the left button down anywhere but on the call sign. The pilot's profile takes the call sign as the pilot's name (`0x00562CFC`) and is written (`profile_save`), and `callsign_add` puts the call sign in the list.
4. While the list is open, its ten rows stand down from (400, 223), each 136 by 20 and 25 below the last, and cover START GAME and LOAD GAME. With the left button down over a row, its call sign becomes the pilot's and the profile's name, the profile is written, the list closes, and the loop waits for the button to come up.
5. With the left button down over an item, what the table says.

`pilot_roster_draw` types the call sign (`call_sign`, `0x00562DCC`, 32 bytes), one character each frame while it is typed (`text_entry_step`, `0x004812F0`): a backspace takes the last character off, and any other goes on where the call sign stays narrower than 125 pixels in `interface_font_small`.

### The call signs

`callsign_list` (`0x005D5E8C`) holds the call signs of the last ten pilots, 50 bytes each, which `starlancer.ini` keeps as `name00` to `name09` under `[CallsignList]`. Every place is a row of the list, an empty one too (`callsign_count`, `0x00595D98`). As the game starts, `WinMain` reads them (`callsigns_load`, `0x004AAE00`), the first PLAYER (string `0xBF`) where the file has none, and writes them straight back (`callsigns_save`, `0x004AAEE0`, which then reads them again).

`callsign_add` (`0x00430B80`) leaves a call sign the list holds as it is. Another goes in the first empty place, or, once the list is full, in the last, the rest moved up a place and the first let go; then the list is saved.

### SET GAME DIFFICULTY

START GAME puts up `difficulty_dialog` (`0x00430300`) over the roster (`0x0051D534`) and sets the difficulty (`0x00562F14`) to medium. Its two arrows, at (253, 222) and (270, 222), each 16 by 26, step the difficulty down and up, going round; START at (276, 269) and BACK at (338, 269), each 25 by 16, close it. A press acts once, until the button comes up. Escape and BACK go back to the roster, the difficulty as the arrows left it. START ends the roster: it frees the shapes, starts a new campaign (`campaign_new`), resets the campaign's wingmen's pilots (`0x0049CD20`), and returns 1.

### Drawing

`pilot_roster_draw`, the render hook:

1. The pilot chosen, lit: shape 19 at (34, 114) for the man, shape 20 at (200, 114) for the woman.
2. In blue, in `interface_font_large`: SELECT PILOT (string `0xB7`) centred on (217, 105), CALL SIGN (Alpha 2) (`0xB8`) from (396, 168), START GAME (`0xB9`) from (433, 247) and LOAD GAME (`0xBA`) from (433, 298); in `interface_font_small`, MAIN MENU (`0xBB`) to the left of (288, 440) and QUIT (`0xBC`) from (353, 440).
3. The call sign's frame, `interface_box` at (398, 192), 140 by 28, and the call sign from (402, 197) in `interface_font_small`, white while it is typed and blue once it isn't. While it is typed and its cursor shows, `_` follows it in blue, at 200 down.
4. The list's arrow, shape 24 at (543, 200), or shape 25 under the pointer; the large buttons, shape 22 at (398, 249) and (398, 300), and the small ones, shape 26 at (292, 441) and (324, 441).
5. The button under the pointer lit, shape 23 or 27, with its label again in white.
6. The list, where it is open: each row framed by `interface_box` at (398, 221 + 25 × row), 140 by 24, wiped black from (400, 223 + 25 × row) to (536, 243 + 25 × row), and its call sign from (404, 225 + 25 × row) in white, in `interface_font_small`.
7. SET GAME DIFFICULTY, where it is up: its box, shape 34 at (114, 177); the arrows, shape 30 at (253, 222), with the one under the pointer lit, shape 31 there or shape 32 at (270, 222); the buttons, shape 26 at (276, 269) and (338, 269), shape 27 under the pointer. Then in blue, in `interface_font_large`: SET GAME DIFFICULTY (`0x2A6`) centred on (320, 185), EASY, MEDIUM or HARD (`0x2A7`, `0x11C`, `0x2A8`) from (289, 222), BACK (`0xF7`) from (370, 264), and START (`0x14A`) to the left of (268, 264).
8. QUIT's dialog, where it is up, and the pointer.

### What the missions take

The pilot's sex and the difficulty are what the missions take from the roster: the radio says the pilot's own lines in a woman's voice for a woman ([Radio](radio.md)), and the difficulty scales damage ([Destruction](objects.md#destruction)). Both start at 0 as the game starts: a man, and easy until SET GAME DIFFICULTY sets it, so INSTANT ACTION, chosen first, is flown on easy. The call sign names the pilot's profile and saved games.

OpenReliant keeps what the roster sets in `Interface.pilot`, which flies every mission the front end starts. `--difficulty` sets the difficulty the game starts with. As the game starts, `campaign_new` reads the pilot's profile, `profile.bin` (the 0xD0 bytes at `0x00562CF8`), whose name becomes the call sign (`profile_load`, `0x00475390`); where the game's folder has none, it makes one under the name PLAYER and leaves the call sign empty.

Not ported:

- Writing the pilot's profile, as the roster changes the call sign, as a campaign starts without one, and as each mission starts ([#74](https://github.com/vdmkenny/openreliant/issues/74), [#301](https://github.com/vdmkenny/openreliant/issues/301)). OpenReliant reads the call sign from the profile the game's folder has.
- The saved games LOAD GAME leads to ([#75](https://github.com/vdmkenny/openreliant/issues/75)), and the transition movies ([#401](https://github.com/vdmkenny/openreliant/issues/401)).

**Fixes:**

- The game copies a call sign into the list, the profile's name or the call sign whatever its length; OpenReliant keeps what fits.
- The call sign's typing goes on adding characters while the call sign stays narrow enough, whatever room its buffer has, which a call sign of narrow characters overruns; OpenReliant stops at the buffer's end.

## Backgrounds

`background_set` (`0x00494B50`) shows a picture behind the frames, loading it with `background_load` (`0x00494A70`) unless `background_name` (`0x00588744`) is it already, case aside. `background_load` reads the TGA and hands it to the device (`sr + 0x50`), or runs `background_hook` (`0x00588740`) in its place where one is set.

The loading screens show one too ([The loading screens](#the-loading-screens)).

## The loading screens

The game shows a loading screen as its renderer starts and before each attempt at a mission: a
picture over the whole screen, and a line of its strings centred across it, the line's top 40
pixels above the screen's foot (`loading_line_draw`, `0x004AB2B0`). The line is in
`interface\optfnt.fnt`, drawn through the last of `text_ramps` (`0x005955A0`), which maps the
font's levels onto the greys at the top of the renderer's palette, up to white.

- As the renderer starts, `renderer_load` (`0x004AB4B0`) shows `interface\splash.tga` alone, then
  with LOADING (string `0x32A`) before each part of the game it loads after the ships' stats: the
  particles, the backdrop and the nebula, the attachments' models, the engine glows, the guns, the
  missiles, the shields, the ejection, the AI and the pilots' stats (`loading_step`,
  `0x004AB470`), running the message pump each time.
- Before each attempt at a mission, `mission_load` (`0x004AD0A0`) shows `interface\sl_splash.tga`,
  `sl_splash800.tga` or `sl_splash1024.tga`, one picture at three sizes, by the screen's width,
  alone (`loading_screen`, `0x004AB3F0`). Once it has set the renderer, the textures and the
  display up again, it adds a line by the simulator's mode (`simulator_mode`): PREPARING FOR
  LAUNCH (string `0xE2`) for none, Calibrating Simulator (`0x14B`) for the Reliant's simulator's
  training, and Preparing for Instant Action (`0x289`) for any other. In a network session each
  player's name follows down the left, 18 pixels apart, with READY beside it once the player is
  ready (`loading_players_draw`, `0x004AB300`).

OpenReliant shows both as it draws the front end: laid out as the game lays them out on a screen
640 by 480, as large as fits in the window. It shows the start-up's LOADING before each of a few
parts it loads. It sets the renderer and the textures up once, as it starts, so the mission's two
frames follow each other at once. Meanwhile the system's events wait for the loop.

Not ported: the players' names in a network session
([#404](https://github.com/vdmkenny/openreliant/issues/404)).

**Improvements:**

- Before a mission OpenReliant shows the largest picture, `sl_splash1024.tga`, whatever the
  window's width. `--original` picks it by the width, as the game does.
- OpenReliant's version is written in the window's corner, as on the front end's screens.
