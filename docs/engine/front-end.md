# Front end

The screens the game shows outside a mission: the main menu, the pilots, the settings, the briefings and the rest. `interface.cpp` holds them, and GenILib's `interf.cpp` runs them.

**Unverified:** the files of the code between the two files' known code (`0x004282C6` to `0x004296A0`, [Source files](../binary/sources.md)). `interface_run` and the front end's start-up run the screens, so OpenReliant puts them with GenILib's `interf.cpp`; the main menu and its drawing are one of the game's screens rather than what runs them, so they go with `interface.cpp`.

## In OpenReliant

[`genilib/interf.zig`](../../src/engine/genilib/interf.zig) runs the screens (`interface_run`) and opens what they draw with. [`game/interface/`](../../src/engine/game/interface) holds the screens: the front end's screen and pointer in [`canvas.zig`](../../src/engine/game/interface/canvas.zig), the main menu in [`main_menu.zig`](../../src/engine/game/interface/main_menu.zig), GAME OPTIONS in [`game_options.zig`](../../src/engine/game/interface/game_options.zig), the settings screen in [`settings.zig`](../../src/engine/game/interface/settings.zig), the pilot roster in [`pilot_roster.zig`](../../src/engine/game/interface/pilot_roster.zig), the saved games in [`saved_games.zig`](../../src/engine/game/interface/saved_games.zig), and the YES or NO dialog and the box saying a save failed in [`dialog.zig`](../../src/engine/game/interface/dialog.zig). The picture behind the screens is `matmanager.Background` ([`game/matmanager.zig`](../../src/engine/game/matmanager.zig)). The loading screens are in [`game/xtrabits/loading.zig`](../../src/engine/game/xtrabits/loading.zig).

OpenReliant opens in the front end unless `--mission` names a mission. The pilot roster's START GAME, or a game its LOAD GAME loads, leads into the Reliant's rooms ([The Reliant's rooms](rooms.md)). A mission the front end or the rooms start flies at once, after the music's fade and the hangar's movie but for INSTANT ACTION's. As a mission of the campaign ends, OpenReliant plays the landing or a chapter's end ([Movies](movies.md#around-a-mission)), and the campaign goes on to the next mission's briefing, or turns to the restart screen ([After a mission](rooms.md#after-a-mission)). INSTANT ACTION's goes back to the main menu.

Ported so far: the screen loop, the main menu, QUIT's dialog, INSTANT ACTION, GAME OPTIONS ([GAME OPTIONS](#game-options)), the audio, the controls and the video, on OpenReliant's settings screen ([The settings screen](#the-settings-screen)), the pilot roster with SET GAME DIFFICULTY, the saved games ([The saved games](#the-saved-games)), the Reliant's rooms with a new pilot's induction, the news report and the in-game options, the briefing ([Briefing](briefing.md)), the loading screens, the intro and the transitions between the screens ported, the movies around a mission ([Movies](movies.md)), and the restart screen. Not yet:

- The other screens ([#43](https://github.com/vdmkenny/openreliant/issues/43) maps them). The loadout is ported ([Loadout](loadout.md)). MULTI PLAYER stays on the main menu ([#404](https://github.com/vdmkenny/openreliant/issues/404)).
- The movies between the screens not yet ported, which come with their screens ([Movies](movies.md)).

**Fix:** a screen takes no press until the button held as it was entered comes up. The movie between two screens gives the press that chose the second time to end; where the transitions are off, the game lets it go on to what lies under the pointer on the new screen.

**Improvements**, each marked so in the code:

- The game switches the display to 640 by 480 for the front end. OpenReliant keeps the window as it is, and draws the front end as large as fits in it, centred, so that it keeps its shape.
- The picture behind a screen is drawn as high as the screen, keeping its proportions, and centred across it, where the device stretches it over the screen: the game's own, which are 4:3, cover it alike, and a mod's wider picture reaches past its sides to fill a wider window ([Modding](../guide/modding.md#pictures)).
- The pointer is where the system's is over the window, rather than DirectInput's movements added up.
- The mouse's wheel scrolls the lists, the saved games' and the controls', three rows a notch, as the system scrolls text by default; the game reads no wheel.
- OpenReliant's version is written, dimmed, in the window's bottom right corner, as the pause menu writes it ([Pause menu](pause-menu.md)): on the front end's screens, the loading screens and the in-game options over the Reliant's rooms ([The Reliant's rooms](rooms.md)), though not in the rooms themselves.

## The screens

`interface_run` (`0x004289D0`) runs the screen whose number `interface_screen` (`0x0051DAC4`) holds, each until it returns nonzero. A screen that leads to another sets the number and returns 0. Between screens the render hook (`sr + 0x88`) is `0x0043E730`.

| Screen | Function | Issue |
|---|---|---|
| 0, the main menu | `main_menu` (`0x00428B60`) | [#396](https://github.com/vdmkenny/openreliant/issues/396) |
| 1, GAME OPTIONS ([GAME OPTIONS](#game-options)) | `game_options` (`0x0042A620`) | |
| 3, the audio ([Audio](#audio)) | `audio_screen` (`0x0042DAB0`) | |
| 15, the video ([Video](#video)) | `video_screen` (`0x0042E9B0`) | |
| 16, the controls ([Controls](#controls)) | `controls_screen` (`0x0042B690`) | |
| 7, the briefing ([Briefing](briefing.md)) | `interface_briefing` (`0x00437010`) | |
| 8, the landing movie: a second's wait, then `play_landing_movie` ([Movies](movies.md#the-landing)), and 3 | `landing_movie_screen` (`0x0043CA30`) | |
| 10 and 11, the multiplayer sessions | `0x0043CA50`, with `0x0051D54C` set or clear | [#404](https://github.com/vdmkenny/openreliant/issues/404) |
| 12, the pilot roster | `0x00430490` | [#397](https://github.com/vdmkenny/openreliant/issues/397) |
| 13, the saved games ([The saved games](#the-saved-games)) | `saved_games` (`0x00431730`) | |
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
| `0xFFFFFF` | On the pilot roster, the call sign while it is typed, the list's call signs, and a button's label under the pointer; in the in-game options and on the controls screen, a button's label under the pointer; on the controls screen, the row waiting for a key |
| `0xFFFF00` | On the controls screen, ! NOT ASSIGNED ! |
| `0xFF0000` | The developers' text |

## The pointer

`interface_pointer_update` (`0x004360D0`), once a pass of a screen's loop:

- DirectInput's movement moves `interface_pointer_x` and `interface_pointer_y` (`0x00520274`, `0x00520270`), which stay on the screen.
- `interface_pointer_ticks` (`0x0051DABC`) runs on by the ticks since the last call, back to 0 once it reaches 64. The pointer is shape 1 + ticks / 4 of the screen's set: 16 shapes, 4 ticks each.
- `interface_pointer_down` (`0x0051DA0C`) is whether the left button is down; `0x0051D9D4` whether the right is.

A screen chooses what lies under the pointer while the left button is down, rather than as it goes down. `interface_hit` (`0x0043EB30`) finds the first of a list of rectangles, each four shorts (corner and size), that holds the pointer, the edges left out.

## The main menu

`main_menu` (`0x00428B60`) shows `interface\sl_splash2.tga` behind itself (`background_set`) and reads `interface\frontend.spr` (`interface_shapes`, `0x0051D60C`, which holds the shown screen's shapes), which it frees as it leaves. Each screen sets its background and shapes up so before its loop draws its first frame, after the transition movie that led to it; OpenReliant enters a screen before it draws it (`Interface.enterShown`). It starts the pointer at (320, 200), `music\New_Pensive.wav` at 127 where no music is playing, and a new campaign (`campaign_new`). OpenReliant flies each mission of a campaign from the variables the campaign's last mission left, and a mission outside a campaign from a new campaign's ([Script VM](script-vm.md)).

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

## GAME OPTIONS

`game_options` (`0x0042A620`), screen 1, which the main menu's GAME OPTIONS opens after `interface\main2opt.bik`, shows `interface\main2opt.tga` behind itself, and reads `interface\frntend4.spr`. Its items, in the order `interface_hit` tries them:

| Item | Corner | Size | Does |
|---|---|---|---|
| AUDIO | (30, 165) | 152 by 127 | `interface\optfade.bik` over `interface\optfade.tga`, then the audio (screen 3, [Audio](#audio)) |
| CONTROL DEVICES | (219, 165) | 152 by 127 | The same, then the controls (screen 16, [Controls](#controls)) |
| VIDEO | (408, 165) | 152 by 127 | The same, then the video (screen 15, [Video](#video)) |
| MAIN MENU | (292, 441) | 25 by 16 | `interface\opt2main.bik`, then the main menu |
| QUIT | (324, 441) | 25 by 16 | QUIT's dialog ([The dialogs](#the-dialogs)), whose YES quits the game |
| ABOUT STARLANCER | (292, 421) | 25 by 16 | The about box ([The in-game options](rooms.md#the-in-game-options)) |

An item acts while the left button is down over it. Escape leads to the main menu, as MAIN MENU does.

Its drawing (`game_options_draw`, `0x0042AFB0`), the render hook:

1. The buttons, shape `0x1B` at (292, 421), (292, 441) and (324, 441).
2. The item under the pointer (`roster_item`, `0x00520130`): an icon's lit shape, `0x13` at (35, 155), `0x14` at (202, 160) or `0x15` at (392, 161), or shape `0x1C` on a button. Its label is written white, then in blue again with the others, so it stays blue.
3. In blue, SELECT AN OPTION (`0x108`) centred on (320, 95), and the icons' labels, AUDIO (`0x109`), CONTROL DEVICES (`0x10A`) and VIDEO (`0x10B`), centred on (133, 319), (320, 319) and (511, 319), in `interface_font_large`; ABOUT STARLANCER (`0x10C`) to the left of (288, 420), MAIN MENU (`0xBB`) to the left of (288, 440) and QUIT (`0xBC`) from (353, 440), in `interface_font_small`.
4. The about box, where it is up, the dialogs, then the pointer.

**Improvement:** ABOUT STARLANCER is ABOUT OPENRELIANT, as in the in-game options.

## The settings screen

OpenReliant shows one settings screen where the game has a screen for each setting's kind: GAME OPTIONS' and the in-game options' AUDIO, CONTROL DEVICES and VIDEO (screens 3, 16 and 15), and the pause menu's audio, controls and video ([Pause menu](pause-menu.md#screens)). It is laid out on the front end's screen as the game's are, with their buttons and their shapes: `interface\frntend5.spr`, the audio and video screens' set, which holds the controls screen's widgets too, its buttons in a smoother palette than screen 16's own. A tab for each kind stands in place of their titles, with GRAPHICS for OpenReliant's own options, in `interface_font_large`: AUDIO (`0x109`) centred on (80, 95), CONTROL DEVICES (`0x10A`) on (245, 95), VIDEO (`0x10B`) on (410, 95) and GRAPHICS on (555, 95), the shown tab's white, the one under the pointer gold, the others blue. A click on a label shows its tab; leaving the controls ends a row's wait. Each menu's AUDIO, CONTROL DEVICES and VIDEO open the screen on that tab, as F1 does in flight on the controls.

| Opened from | Movie in | Behind | OK, Escape | MAIN MENU |
|---|---|---|---|---|
| GAME OPTIONS | `interface\optfade.bik` | `interface\optfade.tga` | `interface\optfade2.bik`, then GAME OPTIONS | `interface\opfad2mm.bik`, then the main menu |
| The in-game options | `interface\igofade.bik` | `interface\igoptfad.tga` for the audio and the video, `interface\igofade.tga` for the controls | `interface\igofade2.bik`, then the in-game options | `interface\igof2mm.bik`, then the main menu |
| The pause menu, and F1 | | The mission, darkened | The pause menu's main screen | CONTINUE (`0x180`) in its place, the mission again |

The buttons are shape `0x28`, `0x29` under the pointer, with their labels in `interface_font_small`, blue, white under the pointer: OK (`0x316`) at (299, 422), to the left of (292, 421); MAIN MENU (`0xBB`) at (299, 443), to the left of (292, 442); RESET DEFAULTS (`0x183`) at (329, 422), from (357, 421); CANCEL CHANGES (`0x5A9`) at (329, 443), from (357, 442). The pointer finds OK and MAIN MENU 120 by 15 from x 199, and the other two 100 by 15 from x 329, each at its shape's height. RESET DEFAULTS and CANCEL CHANGES act on the tab shown; leaving writes every tab's settings. A click acts once, until the button comes up, but for the list's arrows and the audio's knobs.

**Improvement:** the screen is OpenReliant's own design, built from the game's screens: one screen with tabs, the same from the front end, the Reliant's rooms and the pause menu, where the game has a screen for each kind, and the pause menu has screens of its own.


### Audio

The audio is `audio_screen` (`0x0042DAB0`), screen 3, which draws with `audio_screen_draw` (`0x0042E2E0`). Opening, it keeps the four volumes for CANCEL CHANGES, and the 3D provider (`sound_3d_provider`, `0x005D5630`).

| What | Where | Drawn |
|---|---|---|
| Labels | SPEECH VOLUME (`0x576`), SOUND EFFECTS VOLUME (`0x2EE`), MUSIC VOLUME (`0x2EF`) and MASTER VOLUME (`0x577`) to the left of x 295, at y 131, 191, 251 and 311 | Small, blue |
| The sliders' tracks | Shape `0x2D`, 9 by 9, every 45 from x 313 to 538, at y 136, 196, 256 and 316 | |
| The knobs | Shape `0x2C`, 15 by 27, at y 126, 186, 246 and 306, from x 313 at a volume of 0 to 488 at 127 (`audio_knobs`, `0x004E76D0`, where the pointer finds them) | |
| 3D SOUND (`0x2F0`) | To the left of (291, 371); the arrows, shapes `0x13` and `0x14`, at (300, 369) and (322, 369), each found 19 by 26, `0x15` and `0x16` under the pointer; the choice from (346, 371) | Small, blue |

A knob held follows the pointer, 4 pixels to its left, from x 313 to 488, while the button is down over it, and its volume is its place over its travel, 0 to 127; the music's and the master volume change as it moves (`AIL_set_stream_volume`). Letting go of the sound effects' knob plays `stdsmp.fat`'s sound 14 at its volume, in the middle. The game's 3D SOUND steps back and on through its 3D providers (`sound_3d_reopen`, `0x0042E2B0`): NONE (`0x1B3`, Miles's own), Aureal A3D Interactive (TM) (`0x2F2`), Creative Labs EAX (TM) (`0x2F1`) and Software 3D Audio - RSX (`0x416`), passing over any that won't open, and keeps the one chosen as `[Sound] 3DProvider`. RESET TO DEFAULT (`0x112`) sets the volumes to their defaults, the speech and the master volume at 127 and the effects and the music at 80, and the provider to NONE, and writes them at once; CANCEL CHANGES puts back what the screen opened with. Leaving writes the volumes to `[Sound]`.

**Improvements:**

- Every volume changes as its knob moves, where the game changes the effects' and the speech's as the screen is left.
- The volume is the knob's place over its travel exactly, where the game multiplies by its rounded reciprocal (`0x004DC6A4`).
- 3D SOUND chooses how OpenAL Soft renders the 3D sounds ([Sound in OpenReliant](../port/sound.md#openal-soft)): AUTOMATIC, by the output, HEADPHONES, with HRTF, or SPEAKERS, where the game's chooses one of Miles's providers, which OpenReliant has none of. REVERB and COMPRESSOR, OpenReliant's own words, turn the reverbs and the master bus's compressor on and off, from the box at (45, 349) and (45, 373). They change the sound at once, and are written to `[OpenReliant]` ([Configuration](../guide/configuration.md)). With the software Miles of `--original`, 3D SOUND and REVERB, OpenAL Soft's, are dimmed.
- RESET DEFAULTS and CANCEL CHANGES set OpenReliant's options too.

### Controls

The controls are `controls_screen` (`0x0042B690`), screen 16, which draws with `controls_screen_draw` (`0x0042CD30`). Opening, it reads the bindings again from `starlancer.ini` (`key_config_defaults`, `load_key_config`; [Controls](controls.md#bindings)), keeps the settings and the 74 bindings for CANCEL CHANGES, and shows the list from its top.

| What | Where | Drawn |
|---|---|---|
| The panes | (45, 136), 324 by 184; (401, 136), 195 by 184 | `interface_box` |
| Heads | FUNCTION (`0x17B`) from (50, 117), CONTROL (`0x17C`) from (405, 117) | `interface_font_large`, blue |
| The list's rows, twelve | 15 apart from y 139: the action's name, its string at `ControlBinding + 0x2C`, from x 50; its binding from x 406. The pointer finds a row 550 by 10 from x 50 | Small, blue, the row waiting white; ! NOT ASSIGNED ! (`0x5B1`) in yellow for an action bound to nothing, but the one waiting |
| A divider | Two lines, 6 and 7 below where a row's text starts, from x 45 to 367 and from 401 to 594 | Blue |
| The arrows | (374, 136) and (374, 156); the pointer finds each 28 by 16 from x 370 | Shapes `0x1E` and `0x1F`, `0x20` and `0x21` under the pointer with its button up |
| PRIMARY CONTROLLER (`0x234`) | From (45, 327) | Small, blue |
| JOYSTICK (`0x235`), MOUSE (`0x236`), KEYBOARD ONLY (`0x237`) | Boxes at (45, 349), (45, 373) and (45, 397), labels from x 67 | Shape `0x1A`, the tick `0x1B` three pixels in for the controller steering; JOYSTICK dimmed without a joystick |
| FORCE FEEDBACK (`0x17D`), INVERT PITCH (`0x17E`), HAT ENABLE (`0x17F`), JOYSTICK ROLL (`0x233`) | Boxes at (349, 325), (349, 349), (349, 373) and (349, 397), labels from x 367; the pointer finds a box 16 by 16 from x 345 | Shape `0x1A`, ticked with `0x1B` where it can be changed and is on |

A binding is written SHIFT + K (`0x311`), CONTROL + K (`0x312`) or K, then AND (`0x545`) JOY n (`0x32C`) for a joystick button, numbered from 0 as the file numbers it. Alt is never written. What can't be used is dimmed to half: FORCE FEEDBACK but from a joystick that has it, steering, and HAT ENABLE and JOYSTICK ROLL but while the joystick steers. INVERT PITCH is ticked while pitch is as the stick has it, `JoystickInvert` 1.

- A check box, or a controller, changes where it can be used, and its `KeyConfig` entry is written at once (`0x0042BBB4` to `0x0042BF8C`). JOYSTICK ROLL is `TwistEnable`.
- An arrow scrolls the list a row, and again each 5 ticks while it is held (`0x0042BD09`).
- A click on an action's row clears its binding, and the row waits: each pass, the first of the 89 keys of `key_names` pressed alone, with Shift or with Ctrl is taken, then the lowest joystick button down, which holds the screen until it comes up. Taking one doesn't end the wait: a row takes a key and a button, and a later key replaces the first. A key or a button another action holds asks first (`control_binding_find`, `0x0042C5F0`), with `"K"`, `"SHIFT + K"`, `"CONTROL + K"` or `"JOY n"`, then This Key is already assigned to (`0x5AF`) and the action, then Redefine Anyway? (`0x5B0`), a line each: YES takes it from that action, NO puts the waiting row's binding back, the row waiting on. Escape, Shift, Ctrl and Alt on their own, the lock keys, Pause and Print Screen are not among the keys, so none of them can be bound.
- A click on another action's row, or on nothing, ends the wait, the old binding back where the row took nothing. A click on a divider puts the old binding back so, but leaves the row waiting; a click on a check box, a controller, a button or an arrow leaves it waiting as it is.
- Escape asks Would you like to save your changes before leaving this screen? (`0x5AB`) where a binding has changed; NO reads the settings and the bindings again from the file. Escape, OK and MAIN MENU then write the bindings (`save_key_config`, `0x0042C630`).
- RESET DEFAULTS sets the defaults (`key_config_defaults`) and writes them at once; CANCEL CHANGES puts back what the screen opened with.

**Fixes:**

- The game leaves out of the search for a key's holder the action at the key's place in `key_names` (`0x0042C119`), where it means the waiting row's, so that pressing again the key a row has just taken asks whether to take it from the row itself, and YES leaves the row without it. OpenReliant leaves out the waiting row's action.
- A key taken without the question counts as a change, which Escape asks about, as a button and a key taken from another action do; the game asks only after those.
- Leaving the screen, by Escape, OK or MAIN MENU, while a row waits having taken nothing puts its binding back; the game writes the action unbound.

**Improvements:**

- PRIMARY CONTROLLER offers MOUSE, `Controller` 2, which steers by the mouse ([Controls](controls.md#steering)). The game has its case (`0x0042BF15`) and its string, but neither a place nor a label, so only the file sets it.
- JOYSTICK is followed by the joystick's name, in capitals, cut short where it would reach the check boxes.
- A row waiting with nothing taken shows PRESS (`0x5AE`, the string the game's training prompts write), where the game leaves it blank.
- Escape while a row waits only ends the wait, as a click on nothing does; the game leaves the screen.
- Up and Down scroll the list as its arrows do while no row waits, and the mouse's wheel scrolls it; the game scrolls it by its arrows alone.

Not ported: the defaults the game reads from `DEFAULT.TXT`, which RESET DEFAULTS sets ([#488](https://github.com/vdmkenny/openreliant/issues/488)); OpenReliant's are the executable's. The keys' names as the keyboard's layout gives them, which the game shows ([#489](https://github.com/vdmkenny/openreliant/issues/489)); OpenReliant shows the executable's.

### Video

The video is `video_screen` (`0x0042E9B0`), screen 15, which draws with `video_screen_draw` (`0x0042F440`). Opening, it keeps what CANCEL CHANGES puts back: the display's mode, the device, the details, the light maps, the view and the transitions (`0x0042EA41` on), and the brightness. Its eight rows stand 37 apart from y 129, each label to the left of x 280 and its value from x 352, in `interface_font_small`, blue. OpenReliant keeps the game's RESOLUTION, DEFAULT VIEW, BRIGHTNESS and VR TRANSITIONS in their rows, and puts its own in the rows of those it leaves out:

| Row | The game's | OpenReliant's |
|---|---|---|
| 129 | RESOLUTION (`0x10E`): the device's display modes, written `%dx%d` (`0x004E8638`) | RESOLUTION: the size the frames are drawn at |
| 166 | 3D RENDER MODE (`0x10F`): the 3D device, by its name | FULL SCREEN |
| 203 | TEXTURE DETAIL (`0x110`): LOW (`0x11D`) or HIGH (`0x11B`) | VSYNC |
| 240 | GRAPHIC DETAIL (`0x111`): LOW, MEDIUM (`0x11C`) or HIGH | FRAME RATE LIMIT |
| 277 | DEFAULT VIEW (`0x28A`): COCKPIT VIEW (`0x28B`), CHASE VIEW (`0x28C`) or NO COCKPIT VIEW (`0x57F`) | The same |
| 314 | BRIGHTNESS (`0x113`), where the device has a gamma ramp | The same |
| 351 | LIGHT MAPS (`0x114`) | ANTI-ALIASING |
| 388 | VR TRANSITIONS (`0x2D4`) | The same |

A row with choices has the arrows' box, shape `0x2E`, a pixel above it at x 301; the pointer finds its halves 12 by 23 from x 301 and 318 (`video_items`, `0x004E76F0`), lit under the pointer with `0x2F` and `0x30`. A row that is on or off has a box, shape `0x1A`, two pixels below it at x 311, ticked with `0x1B`. The brightness's knob, shape `0x2C`, slides from x 347 at 0.5 to 522 at 2 (`video_brightness_knob`, `0x004E7778`), over its track, shape `0x2D`, every 45 from x 347 until 572, 10 below the knob's top. The buttons are the controls screen's.

- An arrow steps its row's choice back or on, round from the last to the first. A view the game doesn't know steps on to the first, and back by one.
- DEFAULT VIEW and VR TRANSITIONS take effect at once, and are written to `[Device] View` and `Transitions` at once (`0x0042EE3F`, `0x0042EFC9` on).
- The knob held follows the pointer, 4 pixels to its left, and the brightness, 0.5 and its place over its travel times 1.5, sets the display's gamma ramp at once (`sr + 0x54`): `srd3d.dll`'s `set_gamma` (`0x10005270`) sets each of the ramp's 256 levels to its share of the way up, at its power 1 over the brightness, the same for red, green and blue. The device has a gamma ramp, which sets bit 0 of `sr + 0x38`, where its primary surface takes one (`DDCAPS2_PRIMARYGAMMA`, `0x10005204`); without one, the brightness is hidden.
- Leaving by Escape, OK or MAIN MENU writes the brightness to `[Device] gamma`, in hundredths (`0x0042F2B3`, `0x0042F0AF`), and starts the renderer again where the mode, the device, the details or the light maps changed.
- RESET TO DEFAULT (`0x112`) sets the defaults at `0x004E5BF4`: the first mode of the second device, the details LOW, the light maps off, the view from the cockpit and the transitions on, and the brightness's knob in the middle of its track.
- DEFAULT VIEW sets the camera's cockpit mode too, as the pause menu's video screen does ([Pause menu](pause-menu.md#video-4)).

OpenReliant's rows change at once, as the driver applies them, and are written to `[OpenReliant]` ([Configuration](../guide/configuration.md#openreliants-settings)): RESOLUTION steps through NATIVE, the window's own size, and 75, 50 and 25 percent of it, each as tall as the front end's 480 rows or more; FULL SCREEN fills the display, as Alt and Enter do; VSYNC waits for the display; FRAME RATE LIMIT steps through DISPLAY, the display's rate where vsync is off, 30, 60, 120, 144 and 240 frames a second, and NONE; ANTI-ALIASING steps through OFF and 2, 4 and 8 samples a pixel, as many as the GPU offers.

**Fixes:**

- RESET DEFAULTS and CANCEL CHANGES set the view and the transitions, and write them. The game shows them set, but takes RESET DEFAULTS' view only where OK or MAIN MENU start the renderer again, its transitions never, and writes neither; and CANCEL CHANGES leaves the game, and the file, with the view and the transitions chosen since.
- RESET DEFAULTS sets the brightness 1. The game puts the knob in the middle of its track, which is 1.25, beside setting the file's value to 100.

**Improvements:**

- RESOLUTION chooses the size the frames are drawn at, which the window shows scaled, where the game's chooses the display's mode. FULL SCREEN, VSYNC, FRAME RATE LIMIT and ANTI-ALIASING are OpenReliant's own.
- The brightness is the knob's place over its travel exactly, where the game multiplies by a rounded reciprocal (`0x004DC6A4`).
- The settings change at once, where the game starts its renderer again to change the mode.

Not ported: 3D RENDER MODE, which OpenReliant has no Direct3D devices for; and TEXTURE DETAIL, GRAPHIC DETAIL and LIGHT MAPS, at whose highest OpenReliant draws ([#493](https://github.com/vdmkenny/openreliant/issues/493)).

### Graphics

The graphics are OpenReliant's own options ([Configuration](../guide/configuration.md#openreliants-settings)), a row each, laid out as the video's rows are, 26 apart from y 129 to 389: PER-PIXEL LIGHTING, LINEAR LIGHT, MATERIALS, SHADOWS (OFF, LOW or HIGH), COCKPIT SHADOWS, SHOT LIGHTS (EVERY SHOT or LATEST TWO), BLOOM, DITHER, TEXTURE FILTER (ORIGINAL, TRILINEAR or CRISP), COLOR DEPTH (32-BIT or 16-BIT) and SMOOTH MOTION. An arrow steps its row's choice round, and a check box turns its option on or off; each change is written to `[OpenReliant]` at once. The picture changes at once, but for LINEAR LIGHT and COLOR DEPTH, which change the GPU's formats and take effect at the next start: once either differs from what the game runs with, its row says CHANGES APPLY AFTER RESTART, in gold, from x 420. RESET DEFAULTS sets OpenReliant's defaults, every improvement on, and CANCEL CHANGES puts back what the tab opened with.

**Improvement:** the tab is OpenReliant's own, with its own words; the game has none of these options.

## The dialogs

`interface_confirm` (`0x0042AA80`) reads `quit.spr` (`dialog_shapes`) and asks a question, a string or `dialog_text` for -1, until Escape, which answers NO, or a click on YES or NO (`dialog_buttons`, `0x004E5CB8`: (286, 269) and (326, 269), 25 by 16), answered once the button comes up. It returns true for YES. While it is up (`dialog_open`), the screen's render hook draws it (`interface_confirm_draw`, `0x0042AB60`):

1. The box, shape 6 at (114, 177).
2. The buttons, shape 3, the one under the pointer shape 4.
3. The question, centred on (320, 208) in lines at most 400 wide, 14 apart, at most 10: a string in `interface_font_large`, `dialog_text` in `interface_font_small`.
4. YES to the left of (282, 263), NO to the right of (354, 263), in `interface_font_large`.

`interface_message_draw` (`0x0042ADE0`) draws the front end's other dialog, a message with OK, while `0x0051D7D8` is set.

`interface_box` (`0x00435C60`) frames a box on the screen: its top and left edges in `0x00A7FF`, its right and bottom in `0x005785`, each a pixel short of the corner the other starts from, and a second frame a pixel inside in `0x0086CD`.

## The pilot roster

`pilot_roster` (`0x00430490`), screen 12, which SINGLE PLAYER leads to, shows `interface\main2sin.tga` behind itself and reads `interface\frntend2.spr` (`interface_shapes`), which it frees as it leaves. Its render hook is `pilot_roster_draw` (`0x00430C60`). As it starts, the pilot is male (`pilot_female`, `0x00562F16`), the call sign is typed afresh (`0x0052019C`) with the characters typed so far let go (`typed_keys_clear`, `0x004AADA0`), its cursor shows (`0x0052016C`), and the list of call signs is closed (`0x005202B8`). While the roster is up (`0x005D6088`), the window's procedure refuses the characters a file's name can't hold, `\/:*?<>|"` (`0x0050954C`), since the call sign names the pilot's saved games.

Its items, in the order `interface_hit` tries them:

| Item | Corner | Size | Does |
|---|---|---|---|
| The male pilot | (62, 145) | 111 by 228 | The pilot male |
| The female pilot | (239, 151) | 102 by 275 | The pilot female |
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

1. The pilot chosen, lit: shape 19 at (34, 114) for the male pilot, shape 20 at (200, 114) for the female.
2. In blue, in `interface_font_large`: SELECT PILOT (string `0xB7`) centred on (217, 105), CALL SIGN (Alpha 2) (`0xB8`) from (396, 168), START GAME (`0xB9`) from (433, 247) and LOAD GAME (`0xBA`) from (433, 298); in `interface_font_small`, MAIN MENU (`0xBB`) to the left of (288, 440) and QUIT (`0xBC`) from (353, 440).
3. The call sign's frame, `interface_box` at (398, 192), 140 by 28, and the call sign from (402, 197) in `interface_font_small`, white while it is typed and blue once it isn't. While it is typed and its cursor shows, `_` follows it in blue, at 200 down.
4. The list's arrow, shape 24 at (543, 200), or shape 25 under the pointer; the large buttons, shape 22 at (398, 249) and (398, 300), and the small ones, shape 26 at (292, 441) and (324, 441).
5. The button under the pointer lit, shape 23 or 27, with its label again in white.
6. The list, where it is open: each row framed by `interface_box` at (398, 221 + 25 × row), 140 by 24, wiped black from (400, 223 + 25 × row) to (536, 243 + 25 × row), and its call sign from (404, 225 + 25 × row) in white, in `interface_font_small`.
7. SET GAME DIFFICULTY, where it is up: its box, shape 34 at (114, 177); the arrows, shape 30 at (253, 222), with the one under the pointer lit, shape 31 there or shape 32 at (270, 222); the buttons, shape 26 at (276, 269) and (338, 269), shape 27 under the pointer. Then in blue, in `interface_font_large`: SET GAME DIFFICULTY (`0x2A6`) centred on (320, 185), EASY, MEDIUM or HARD (`0x2A7`, `0x11C`, `0x2A8`) from (289, 222), BACK (`0xF7`) from (370, 264), and START (`0x14A`) to the left of (268, 264).
8. QUIT's dialog, where it is up, and the pointer.

### What the missions take

The pilot's sex and the difficulty are what the missions take from the roster: the radio says the pilot's own lines in the female voice for a female pilot ([Radio](radio.md)), and the difficulty scales damage ([Destruction](objects.md#destruction)). Both start at 0 as the game starts: male, and easy until SET GAME DIFFICULTY sets it, so INSTANT ACTION, chosen first, is flown on easy. The call sign names the pilot's profile and saved games.

OpenReliant keeps what the roster sets in `Interface.pilot`, which flies every mission the front end starts. `--difficulty` sets the difficulty the game starts with. As the game starts, `campaign_new` reads the pilot's profile, `profile.bin` (the 0xD0 bytes at `0x00562CF8`), whose name becomes the call sign (`profile_load`, `0x00475390`); where the game's folder has none, it makes one under the name PLAYER and leaves the call sign empty.

Not ported:

- Writing the pilot's profile, as the roster changes the call sign, as a campaign starts without one, and as each mission starts ([#74](https://github.com/vdmkenny/openreliant/issues/74), [#301](https://github.com/vdmkenny/openreliant/issues/301)). OpenReliant reads the call sign from the profile the game's folder has.

**Fixes:**

- The game copies a call sign into the list, the profile's name or the call sign whatever its length; OpenReliant keeps what fits.
- The call sign's typing goes on adding characters while the call sign stays narrow enough, whatever room its buffer has, which a call sign of narrow characters overruns; OpenReliant stops at the buffer's end.

## The saved games

`saved_games` (`0x00431730`), screen 13, lists the pilot's saved games, to load one or to save the game as one ([Saved games](../formats/save.md)); `saved_games_saving` (`0x0051D5F4`) picks which. The pilot roster's LOAD GAME opens it to load, after `interface\sinfade.bik`, over `interface\sinfade.tga`; the in-game options' SAVE and LOAD open it over the Reliant's rooms and the briefing's loadout, after `interface\igofade.bik`, over `interface\igoptfad.tga` ([The in-game options](rooms.md#the-in-game-options)). It reads `interface\frntend2.spr` and draws with `saved_games_draw` (`0x00432480`). As it starts, loading, the autosave is selected where there is one; the typed name is empty, and the saves are found (`saved_games_scan`, `0x004315C0`): the call sign's, from slot 0 on, up to the first file missing, so that without the autosave nothing is listed.

| What | Where | Drawn |
|---|---|---|
| Title | Centred on (320, 86) | LOAD GAME FOR (`0x55F`) or SAVE GAME FOR (`0x560`), then the call sign in capitals, large, blue |
| The list's frame, the details' frame | (45, 126), 530 by 175; (45, 321), 550 by 38 | `interface_box` |
| Heads | y 107 | GAMES (`0xE3`) from x 45, PILOT (`0xE4`) centred on 320, MISSION (`0xE5`) to the left of 575, small, blue |
| Rows, ten at most | 17 apart from (49, 126), each 400 by 17 | The save's name from x 49, its pilot centred on 320, the mission's number as the player sees it to the left of 570; blue, the selected row white over a bar of pure blue from x 49 to 572, y 2 to 19 below the row's |
| Details | GAME INFORMATION (`0xE6`) at (49, 302); `Callsign:` at (49, 322), `Rank:` at (49, 339), `Level:` at (290, 322), `Time:` at (290, 339) | The selected save's pilot at (113, 322), rank at (113, 339) and level at (350, 322), from its `MISS`; the date its file was written at (350, 339), as `%02d:%02d` then two spaces and `ddd',' MMM dd yyyy` |
| Arrows | (579, 250) and (579, 268), each 26 by 16 | Shape 28, lit 29 up or 25 down under the pointer |
| Buttons | BACK (292, 421), LOAD GAME or NEW SAVE GAME (324, 421), MAIN MENU (292, 441), QUIT (324, 441), each 25 by 16 | Shape 26, lit 27 under the pointer, the label small, blue, white under the pointer |
| The name, saving | Its frame (45, 380), 358 by 20; the name at (49, 378), large, white, with `_` after it; OK at (562, 384), 32 by 20 | Shape 22, lit 23; SAVE GAME (`0x54D`) to the left of (562, 384) |

Each pass, Escape leaves, and Down and Up scroll the list a row while held, where it holds more than ten. A press acts on the pass it is first seen, but for the arrows', which scroll a row each pass it is held. Rows never light under the pointer; a click on a row selects it, and a second click on the row selected loads it, or, saving, starts typing its name. Saving, the autosave can't be selected. LOAD GAME loads the row selected, and waits for the button to come up. The name typed takes 18 characters at most, and its cursor turns every 25 ticks; Enter, or a click on OK, saves the game under it in the slot selected. NEW SAVE GAME, once a visit, saves the game in the slot after the last found, named Empty Save Game (`0x179`), selects it with the game's rank and level, loads it back, and starts typing its name from Empty Save Game; leaving without saving removes it. A save that fails puts up a box saying so (`save_error_dialog`, `0x0042A870`), which OK closes. There is no DELETE, and no question before a save goes over another.

| Way out | Movie | Then |
|---|---|---|
| BACK, Escape | Loading: `interface\sinfade2.bik` to the roster, `igofade2.bik` to the in-game options. Saving: `igofade2.bik` to the in-game options | Back where it was opened from |
| MAIN MENU | Loading: `interface\sifad2mm.bik` from the roster, `igof2mm.bik` from the in-game options | The main menu |
| QUIT | | Do you really want to Quit?; YES quits |
| A game loaded | | From the roster, `WinMain` takes it as START GAME's, into the rooms before its mission (`0x004AA1AB` on); from the in-game options, the rooms start again from the first view of its mission's carrier |
| The game saved | | Back to the rooms |

**Fixes:**

- Where NEW SAVE GAME fails, leaving removes nothing; the game removes whatever file its buffer names. With every slot taken, NEW SAVE GAME does nothing, where the game saves over the restart point's file.
- A name taken from a save is kept to the typed name's room, and a listed name to the list's, where the game copies either whatever its length. A rank or a level past the game's names is taken as the highest.
- A file with no `SAVE` form is listed with no name, pilot or mission, where the game shows what its buffers held.

**Improvement:** the day's and the month's names in the date are English, where the game takes the system's language's.

Not ported: what the multiplayer games do with the saved games: the co-op host's load, the multiplayer debriefing's save, and a load sent to the other players ([#475](https://github.com/vdmkenny/openreliant/issues/475)).

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
