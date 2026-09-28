# Front end

The screens the game shows outside a mission: the main menu, the pilots, the settings, the briefings and the rest. `interface.cpp` holds them, and GenILib's `interf.cpp` runs them.

**Unverified:** the files of the code between the two files' known code (`0x004282C6` to `0x004296A0`, [Source files](../binary/sources.md)). `interface_run` and the front end's start-up run the screens, so OpenReliant puts them with GenILib's `interf.cpp`; the main menu and its drawing are one of the game's screens rather than what runs them, so they go with `interface.cpp`.

## In OpenReliant

[`genilib/interf.zig`](../../src/engine/genilib/interf.zig) runs the screens (`interface_run`) and opens what they draw with. [`game/interface/`](../../src/engine/game/interface) holds the screens: the front end's screen and pointer in [`canvas.zig`](../../src/engine/game/interface/canvas.zig), the main menu in [`main_menu.zig`](../../src/engine/game/interface/main_menu.zig), and the YES or NO dialog in [`dialog.zig`](../../src/engine/game/interface/dialog.zig). The picture behind the screens is `matmanager.Background` ([`game/matmanager.zig`](../../src/engine/game/matmanager.zig)).

OpenReliant opens in the front end unless `--mission` names a mission. A mission the front end starts flies at once, and when it ends, or LEAVE MISSION leaves it, OpenReliant goes back to the main menu.

Ported so far: the screen loop, the main menu, and QUIT's dialog. Not yet:

- The other screens ([#43](https://github.com/vdmkenny/openreliant/issues/43) maps them). Until the pilot roster ([#397](https://github.com/vdmkenny/openreliant/issues/397)), the Reliant's rooms ([#398](https://github.com/vdmkenny/openreliant/issues/398)) and the briefing ([#73](https://github.com/vdmkenny/openreliant/issues/73)) are ported, SINGLE PLAYER starts the campaign's first mission. MULTI PLAYER ([#404](https://github.com/vdmkenny/openreliant/issues/404)) and GAME OPTIONS ([#400](https://github.com/vdmkenny/openreliant/issues/400)) stay on the main menu.
- INSTANT ACTION ([#399](https://github.com/vdmkenny/openreliant/issues/399)), which does nothing yet.
- The debriefing, which a mission's end goes to ([#73](https://github.com/vdmkenny/openreliant/issues/73)).
- The intro and the movies between screens ([#401](https://github.com/vdmkenny/openreliant/issues/401)).

**Improvements**, each marked so in the code:

- The game switches the display to 640 by 480 for the front end. OpenReliant keeps the window as it is, and draws the front end as large as fits in it, centred, so that it keeps its shape.
- The pointer is where the system's is over the window, rather than DirectInput's movements added up.

## The screens

`interface_run` (`0x004289D0`) runs the screen whose number `interface_screen` (`0x0051DAC4`) holds, each until it returns nonzero. A screen that leads to another sets the number and returns 0. Between screens the render hook (`sr + 0x88`) is `0x0043E730`.

| Screen | Function | Issue |
|---|---|---|
| 0, the main menu | `main_menu` (`0x00428B60`) | [#396](https://github.com/vdmkenny/openreliant/issues/396) |
| 1, GAME OPTIONS; 3, audio; 15, video; 16, controls | `0x0042A620`, `0x0042DAB0`, `0x0042E9B0`, `0x0042B690` | [#400](https://github.com/vdmkenny/openreliant/issues/400) |
| 7, the briefing and the debriefing | `0x00437010` | [#73](https://github.com/vdmkenny/openreliant/issues/73) |
| 8, the landing movie | `0x0043CA30` | [#403](https://github.com/vdmkenny/openreliant/issues/403) |
| 10 and 11, the multiplayer sessions | `0x0043CA50`, with `0x0051D54C` set or clear | [#404](https://github.com/vdmkenny/openreliant/issues/404) |
| 12, the pilot roster | `0x00430490` | [#397](https://github.com/vdmkenny/openreliant/issues/397) |
| 13, the saved games | `0x00431730` | [#75](https://github.com/vdmkenny/openreliant/issues/75) |
| 14, the multiplayer connection | `0x00432FC0` | [#404](https://github.com/vdmkenny/openreliant/issues/404) |
| 17 and 18, a session's loadout | `0x0044B950`, with `0x0051D54C` set or clear | [#404](https://github.com/vdmkenny/openreliant/issues/404) |

Any other number returns 3. What `interface_run` returns tells WinMain what to do:

| Returned | Meaning |
|---|---|
| 1 | Fly the mission without its briefing |
| 2 | Fly the mission |
| 3 | Quit |
| 4, 5 | Set the display up again, then the front end again |

## Start-up

`interface_init` (`0x004288E0`) reads `bank_stdsmp` from `stdsmp.fat`, and opens three fonts: `handel.fnt` (`interface_font_handel`), `interface\optfnt.fnt` (`interface_font_large`) and `interface\smlfnt2.fnt` (`interface_font_small`). It makes `interface_text_remap` (`0x00520284`), 0xFF for level 0 and each level 1 to 15 itself.

## Text

The front end writes with `hud_text` and `hud_text_wrapped` through `interface_text_remap`, ramped by `interface_palette_ramp` (`0x004287C0`), the front end's copy of `hud_palette_ramp` ([Pause menu](pause-menu.md)): entries 1 to 15 of VFX's global palette, a ramp of a `0xRRGGBB` colour at `palette_ramp_brightness`.

| Colour | Where |
|---|---|
| `0x40BCFF` | The main menu's labels, and the dialogs |
| `0xFDB951` | A panel's labels under the pointer |
| `0xFF0000` | The developers' text |

## The pointer

`interface_pointer_update` (`0x004360D0`), once a pass of a screen's loop:

- DirectInput's movement moves `interface_pointer_x` and `interface_pointer_y` (`0x00520274`, `0x00520270`), which stay on the screen.
- `interface_pointer_ticks` (`0x0051DABC`) runs on by the ticks since the last call, back to 0 once it reaches 64. The pointer is shape 1 + ticks / 4 of the screen's set: 16 shapes, 4 ticks each.
- `interface_pointer_down` (`0x0051DA0C`) is whether the left button is down; `0x0051D9D4` whether the right is.

A screen chooses what lies under the pointer while the left button is down, rather than as it goes down. `interface_hit` (`0x0043EB30`) finds the first of a list of rectangles, each four shorts (corner and size), that holds the pointer, the edges left out.

## The main menu

`main_menu` (`0x00428B60`) shows `interface\sl_splash2.tga` behind itself (`background_set`) and reads `interface\frontend.spr` (`main_menu_shapes`), which it frees as it leaves. It starts the pointer at (320, 200), `music\New_Pensive.wav` at 127 where no music is playing, and a new campaign (`campaign_new`). OpenReliant, which has no campaign yet, starts every mission from a new campaign's variables ([Script VM](script-vm.md)).

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

INSTANT ACTION flies mission 29 in ship type 2, with `simulator` (`0x0057E044`) set, again and again until the player leaves it, then comes back to the main menu.

### The developers' keys

With `developer_mode` set:

- A number key types a digit of `mission_number`: after one digit it adds a second, after two it starts again.
- Enter with Shift or Control flies the mission from its briefing, in ship type 0.
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

## Backgrounds

`background_set` (`0x00494B50`) shows a picture behind the frames, loading it with `background_load` (`0x00494A70`) unless `background_name` (`0x00588744`) is it already, case aside. `background_load` reads the TGA and hands it to the device (`sr + 0x50`), or runs `background_hook` (`0x00588740`) in its place where one is set.

`loading_screen` (`0x004AB3F0`) writes LOADING over `interface\sl_splash.tga`, `sl_splash800.tga` or `sl_splash1024.tga`, by the screen's width, as a mission loads ([#402](https://github.com/vdmkenny/openreliant/issues/402)).
