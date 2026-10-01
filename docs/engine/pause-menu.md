# Pause menu

While a mission is paused, the game draws a configuration menu in place of the head-up display. The menu has a main screen and screens for audio, video and control settings; multiplayer has its own screen. The mouse drives the menu, and Escape backs out of it.

**Unverified:** the source file's name. The menu's code (`0x0048D820` to `0x004906F0`) and its data lie between `hudmovie.cpp`'s and `language.cpp`'s in link order ([Source files](../binary/sources.md)), and no assertion names the file. OpenReliant calls it `hudoptions.cpp`: it sorts between those two, and the menu draws through the display's pane in `hud_draw`'s place. `game_pause` and `mission_paused_frame` lie between `language.cpp` and `main.cpp`'s first placed function, and `paused` among `main.cpp`'s variables, so they are taken to be `main.cpp`'s.

## In OpenReliant

[`game/hudoptions.zig`](../../src/engine/game/hudoptions.zig) holds the menu and its screens, with the items, their drawing and the buttons the screens share in [`hudoptions/menu.zig`](../../src/engine/game/hudoptions/menu.zig) and the main screen in [`hudoptions/screens.zig`](../../src/engine/game/hudoptions/screens.zig); `game_pause` is in [`game/main.zig`](../../src/engine/game/main.zig). Ported so far: pausing and resuming, the paused frame's outcomes, the menu's items and pointer, and the main screen. The audio, the video and the controls screens, the last of which F1 opens too, are OpenReliant's settings screen ([The settings screen](front-end.md#the-settings-screen)). Not yet: the multiplayer screen ([#211](https://github.com/vdmkenny/openreliant/issues/211)). RESTART starts the mission again, mission 25 from its first part ([After a mission](rooms.md#after-a-mission)). LEAVE MISSION turns to the restart screen in the campaign ([After a mission](rooms.md#after-a-mission)), goes back to the main menu from INSTANT ACTION and to the simulator pod from its missions ([The simulator pod](simulator-pod.md)), and quits where `--mission` named the mission.

**Improvements**, each marked so in the code:

- The menu is drawn `hud.scaleFor` times larger, as the display is, so it keeps its proportions on a larger screen.
- The audio, the video and the controls screens are the front end's, the settings screen, over the mission darkened, with CONTINUE in MAIN MENU's place ([The settings screen](front-end.md#the-settings-screen)).
- The pointer is where the system's is over the window, rather than DirectInput's motion added up.
- Losing the window's focus with a mission loaded pauses into the menu in single player too.
- OpenReliant's version is written, dimmed, in the bottom right corner, as on the front end's menus ([Front end](front-end.md)).
- The text is drawn from outline fonts at the window's resolution, as the front end's is ([Front end](front-end.md#text)).
- A mission `--mission` names ends in the menu, which stands in for the debriefing, and `--no-pause-menu` flies it again at once. Its LEAVE MISSION quits.

**Fixes** of the game's bugs, each marked so in the code:

- Coverage level 16 of the fonts, which a few glyphs use in their first column, is left clear, as the front end draws it, where the game reads past its remap table into a volume's byte.

W and H below are the screen's size in pixels (`sr + 0x1666`, `sr + 0x166A`). The layout is in pixels about fractions of the screen, and does not scale.

## Pausing

| What | Where | Pauses with |
|---|---|---|
| Escape, in any frame of the mission | `mission_frame` (`0x004924B0`), `key_pressed(DIK_ESCAPE, 0, once)`, before the frame's work, which it then leaves out | `game_pause(true, false)`, `pause_reason` 0, `pause_player` the player |
| F1, the `key_config` action (73, string `0x55B` HELP), in single player | `mission_frame` | `game_pause(true, false)`, then `pause_screen` 2: the controls screen directly |
| A player's lag past 150, in multiplayer | `mission_frame` | `game_pause(true, false)`, `pause_reason` 1 |
| Another player's pause, network packet `0x27` | `0x004B6F80` | `game_pause(true or false, true)`, copying the reason and the player |
| The session lost, `mission_ending` 9 (packet `0x4C`) | | `game_pause(true, true)` |
| The window going inactive, in a multiplayer session with a mission loaded (`mission_loaded`, `0x00588734`) | `message_pump` (`0x004AAB20`) | `game_pause(true, false)`; active again, the mission stays in the menu |

No key pauses without the menu: the Pause key has no check, and P is POWERBALL WINDOW.
`hud_target_keys` (`0x0048B6B0`) also sets `paused` for an in-mission video (flag `0x00566630`),
without the menu. In single player the window going inactive pauses only the sound (see
[Sound](sound.md)); `paused` stays clear.

`game_pause` (`0x00491E20`, `bool pause, bool quiet`) does, pausing, if the game isn't paused yet:

1. `sr + 0x78`, empties the typed-character queue (`typed_keys_clear`, `0x004AADA0`), sets `paused`,
   and empties the chat line (`chat_input`, `0x00529C70`).
2. Holds the frame timing (`frame_timing_hold(1)`, `0x0049CFD0`).
3. Stops the Miles sample at `0x00563F18` if speech channel 0 is busy, and pauses the 3D voices and
   the voices. **Unverified:** that the sample is the speech's.
4. Puts `pause_menu_draw` in the overlay slot `sr + 0x88` and opens the menu (`pause_menu_open`).
5. In a multiplayer session (`net_session`, `0x005DC1E8`), unless `quiet`, sends the pause
   (`net_send_pause(1)`, `0x004BAAE0`: packet `0x27` with the flag and `pause_reason`).
6. Sets `paused_clock` (`0x00587CC0`).

It always sets `pause_view_setting` (`0x00582E88`) to `cockpit_mode_setting`, and `0x005DD524` to
50. **Unknown:** what reads `0x005DD524`.

Resuming, if paused: restores the window if it is suspended (`0x005DDD28`; **Unverified:**
`WM_SYSCOMMAND` `SC_RESTORE` through two imports), calls `sr + 0x78`, clears bit 0 of
`radar_backing + 0x14`, clears `paused`, resumes the sample, the frame timing, the 3D voices and the
voices, sends the resume where it sent the pause, puts `hud_draw` back, closes the menu
(`pause_menu_close`), and switches to view 0 (`camera_set_view(0, player, 0, 1)`) if
`cockpit_mode_setting` changed while paused. It always sets `0x005DD524` to 10. The music is never
paused.

## The paused frame

`mission_run` (`0x00494040`) runs `mission_paused_frame` (`0x00491FC0`) for each frame while paused,
in place of `mission_frame`:

1. `music_update`, so the music goes on.
2. The network, in multiplayer.
3. `frame_duration` from its own clock, against `paused_clock`. **Unverified:** the clock, an import
   read shifted right by 2.
4. `read_keyboard`, which lets go of the keys that are up, the sound's updates
   (`sound_buffers_play` of `stdsmp`, `sound_3d_update`), `read_joystick`, and the menu's mouse
   (`menu_mouse_update`). It hides the radar's backing (bit 0 of `radar_backing + 0x14`).
5. `sr_render`: the scene as it stood, and the overlay. If the brightness (`sr + 0x15FA`) changed,
   `sr + 0x54`.
6. What `pause_screen` has become:

| `pause_screen` | Outcome |
|---|---|
| 5 | Restart: resumes, sets `mission_restart` (`0x005D60B9`), and returns 1. `WinMain` ends the mission and starts it again |
| 6 | Continue: resumes, returns 0 |
| 7 | Leave: resumes, clears `mission_restart`, sets `mission_ending` 4, stops the 8 speech channels (`0x004620D0`), returns 1. `WinMain` skips the debriefing and `mission_end_record` for ending 4 |

## Screens

`pause_menu_draw` (`0x004906F0`) is the overlay. Like `hud_draw`, it points the VFX window at
`sr + 0x15FE` and calls `sr + 0x80` when `sr + 0x1AC` is 1; on the hardware renderers it loads
palette block `0x77` of `hud_shapes` at brightness 1. Then:

1. If `pause_screen` (`0x0057DAA4`) differs from `pause_screen_entered` (`0x0057DABC`), the new
   screen's enter routine, and `pause_screen_entered` takes it.
2. The screen's frame routine.
3. If the screen changed during the frame, the old one's leave routine. That includes a change to
   5, 6 or 7, so a sub-screen's settings are saved when the game resumes from it.
4. Palette block `0x77` again, which undoes the text's colour ramp, and the cursor.

| Screen | What | Enter | Frame | Leave |
|---|---|---|---|---|
| 0 | Four QUIT buttons; nothing selects it | | `pause_screen_quit` `0x0048DF20` | |
| 1 | Main, single player | | `pause_screen_main` `0x0048E8D0` | |
| 2 | Controls | `pause_controls_enter` `0x0048F620` | `pause_screen_controls` `0x0048FEF0` | `pause_controls_exit` `0x004905C0` |
| 3 | Audio | `pause_audio_enter` `0x0048EC20` | `pause_screen_audio` `0x0048EC70` | `sound_settings_save` `0x0048F160` |
| 4 | Video | `pause_video_enter` `0x0048F230` | `pause_screen_video` `0x0048F260` | `video_settings_save` `0x0048F5A0` |
| 8 | Debug listing; nothing reaches it | | `pause_screen_debug` `0x0048E140` | |
| 9 | Multiplayer | `pause_multiplayer_enter` `0x0048E440` | `pause_screen_multiplayer` `0x0048E510` | `pause_multiplayer_exit` `0x0048E500` |

`pause_menu_open` (`0x00490600`) starts on screen 9 in a multiplayer session, else 1.

### Main (1)

Title `0x108` SELECT AN OPTION. Three icons, each centred on its anchor with its label in the large
font, centred, 65 pixels below:

| Icon | Shape, lit | Anchor | Goes to |
|---|---|---|---|
| AUDIO (`0x109`) | `0x180`, `0x183` (a speaker) | 0.25 W, 0.5 H | 3 |
| CONTROL DEVICES (`0x10A`) | `0x17F`, `0x182` (a joystick) | 0.5 W, 0.5 H | 2 |
| VIDEO (`0x10B`) | `0x181`, `0x184` (a monitor) | 0.75 W, 0.5 H | 4 |

Buttons (see [Buttons](#buttons)): LEAVE MISSION (`0x32B`, 7) where the others have OK, RESTART
(`0x181`, 5), CONTINUE (`0x180`, 6). Escape: 6.

### Audio (3)

OpenReliant shows its settings screen in this one's place ([The settings screen](front-end.md#the-settings-screen)). The game's:

Entering keeps the four volumes for CANCEL CHANGES (`audio_saved_speech`, `_effects`, `_music`,
`_master`) and ends any drag. Title `0x2ED` SOUND CONFIGURATION; the items are the table at
`0x00502940` (13 items).

Four sliders, from the top, each at 0.5 H plus an offset:

| Slider | String | Offset |
|---|---|---|
| Speech | `0x576` SPEECH VOLUME | -90 |
| Sound effects | `0x2EE` SOUND EFFECTS VOLUME | -30 |
| Music | `0x2EF` MUSIC VOLUME | +30 |
| Master | `0x577` MASTER VOLUME | +90 |

The track is shape `0x187` (189 by 13), placed `0x12` at (0.5 W + 16, 0.5 H + offset); its label is
right-aligned at (-32, -6). The knob is shape `0x188` (18 by 31), centred, at an x offset of
round(v / 127 × 171 + 24) for volume v.

- Clicking a knob starts its drag. While a button is held, v = round((cursor x - round(0.5 W) - 24)
  / 171 × 127), clamped to 0-127, and `sound_volumes_apply`. Clicks count only while no drag is on;
  the check leaves out the master volume's, which a press always finds clear anyway.
- With no button down, a drag ends. An effects drag that was on in the last frame plays sound 14
  of `stdsmp` once, at the volume the pointer's place works out to, unclamped, pan 64
  (`drag_effects_last`), so a click too short to drag plays nothing.
- A drag goes on at the start of the frame, before the items are drawn; a knob clicked is dragged
  from the next frame.
- RESET DEFAULTS: speech 127, effects 80, music 80, master 127. CANCEL CHANGES: the kept volumes.
- OK: 1. Escape: 1, before the clicks, which a leaving click overrides. Leaving saves the
  `[Sound]` section (`sound_settings_save`): `Fxvolume`, `Musicvolume`, `Speechvolume`,
  `Mastervolume`.

### Video (4)

OpenReliant shows its settings screen in this one's place ([The settings screen](front-end.md#the-settings-screen)). The game's:

Entering keeps `cockpit_mode_setting` and the brightness (`sr + 0x15FA`) for CANCEL CHANGES. Title
`0x10D` GRAPHICS CONFIGURATION; the items are the table at `0x00502BB0` (11 items).

- BRIGHTNESS (`0x113`), a slider at -30 like the audio's, shown only while bit 0 of `sr + 0x38` is
  set. The knob's x offset is round((b - 0.5) × 114 + 24); a drag sets b = (x - round(0.5 W) - 24) /
  171 × 1.5 + 0.5, clamped to 0.5-2.0. It shares the effects' drag flag.
- DEFAULT VIEW (`0x28A`): the arrow box, shape `0x178`, placed `0x13` at (0.5 W - 16, 0.5 H + 30),
  its label right-aligned at (-41, -6). Its halves are hover-only items: `0x179` at x offset -33
  goes back, `0x17A` at -16 forward, through the settings 0, 1 and 2, setting `cockpit_mode` 1, 2
  and 0 to match: forward past 2 to 0, back before 0 to 2, and a setting out of range by one. The
  value is drawn left-aligned at (0.5 W + 16, 0.5 H + 24): COCKPIT VIEW (`0x28B`), CHASE VIEW
  (`0x28C`) or NO COCKPIT VIEW (`0x57F`).
- RESET DEFAULTS: brightness 1, `sr + 0x54`, and both `cockpit_mode_setting` and `cockpit_mode` 0
  (from `0x004E5C08`). Mode 0 is no cockpit where setting 0 is the cockpit.
- CANCEL CHANGES: the kept values. OK: 1. Escape: 1.
- Leaving writes `[Device] gamma`, the brightness in hundredths, and `[Device] View`
  (`video_settings_save`).

### Controls (2)

OpenReliant shows its settings screen in this one's place ([The settings screen](front-end.md#the-settings-screen)). The game's:

Entering makes three panes: the actions' (W/2 - 274 to W/2 + 46), the bindings' (W/2 + 82 to
W/2 + 275), each from y = 0.2 H + 32 down in whole 15-pixel rows above H - 152, and the dialog's.
It reloads the bindings (`key_config_defaults`, `0x0042CAA0`, from `default.txt`, then
`load_key_config`), numbers `controls_list`, and keeps the settings and all 74 bindings for CANCEL
CHANGES. Title `0x17A` CONTROL CONFIGURATION; the items are the table at `0x00502E20` (15 items).

- PRIMARY CONTROLLER (`0x234`): radio buttons JOYSTICK (`0x235`) and KEYBOARD ONLY (`0x237`) at
  0.5 W - 276. MOUSE (`0x236`) is in the strings but unused.
- Check boxes at 0.5 W + 276, shapes `0x185` off and `0x186` on: FORCE FEEDBACK (`0x17D`), INVERT
  PITCH (`0x17E`), HAT ENABLE (`0x17F`), JOYSTICK ROLL (`0x233`). An item is dimmed while it can't
  be used: JOYSTICK without a joystick, FORCE FEEDBACK without one that has it or outside joystick
  mode, HAT and ROLL outside joystick mode.
- The list: `controls_list` (`0x004E75E8`), 80 rows, -1 a red double divider and otherwise actions
  0 to 72 (`key_config` isn't listed, so F1 can't be rebound here). Rows are 15 pixels, in the small
  font at x 8 in each pane. A row shows the action's name (the string id at `ControlBinding + 0x2C`)
  and its binding: SHIFT + K, CONTROL + K or K, with AND JOY n for a button. Alt is never shown. An
  empty binding shows ! NOT ASSIGNED ! (`0x5B1`) in yellow.
- The scroll widget `0x17B` at (0.5 W + 63, 0.2 H + 36), with hover-only halves `0x17C` up and
  `0x17D` down. Holding one scrolls by `frame_duration` a frame; the list then settles on whole
  rows.
- Clicking a row keeps its binding, clears it and waits for a key: each of the 89 keys of
  `key_names` (`0x004E5CD0`, a DirectInput code and a name in 0x24 bytes) with no modifier, Shift
  or Ctrl, then the joystick's buttons.
- A key or button another action holds (`control_binding_find`, `0x0042C5F0`) opens a dialog
  (`pause_controls_conflict`, `0x0048FD60`): "KEY" / This Key is already assigned to (`0x5AF`) /
  the action / Redefine Anyway? (`0x5B0`), built with `"%s"\n%s %s\n%s`, `"%s + %s"` for a
  modifier and `"%s %d"` with JOY for a button. YES (`0x28F`) takes it from the other action; NO
  (`0x290`) keeps waiting. Its buttons are the table at `0x00502DC0`.
- RESET DEFAULTS: `key_config_defaults` and `save_key_config` (`0x0042C630`). CANCEL CHANGES:
  everything kept. OK: 1. Escape: 1.
- Leaving destroys the panes and saves the bindings (`save_key_config`) to `starlancer.ini`.

`pause_controls_draw` (`0x0048F860`) draws the screen and returns the item under the cursor, 100
plus the action for a list row, or -1. **Not traced line by line:** how the wait reads the keys.

### Multiplayer (9)

Entering clears the scoreboard's rows and lag flags, sets no player to drop, and makes the dialog's
pane; leaving destroys it. Title `0xA9` PAUSED.

- LEAVE MISSION at (+16, -32), 7; CONTINUE at (-16, -32), 6. Escape: 6.
- The deathmatch scores (`0x004AF650`), with a drop button (shape `0x176`) at (0.5 W + 282, the
  row's y + 7) beside each player whose lag has passed 100 since the screen opened. Clicking one
  sets `drop_player_slot`, which `mission_paused_frame` drops. **Unverified:** the drop, through
  `0x004BB950`, `0x004B99B0` and `0x004B6890`.
- The message log and the chat line, with a `_` caret.
- At (0.5 W, 0.2 H + 32) in the large font, `%s: %s` with the pausing player's name and Player has
  paused the game (`0x53E`), or Game paused due to bad connection. (`0x55A`).
- With `mission_ending` 9, the session-lost dialog instead (`pause_session_lost`, `0x0048E370`):
  Your session has been terminated due to a bad connection (`0x5F1`) and OK (`0x316`), which leaves
  (7) as the button is released.

### Unreachable screens (0 and 8)

Nothing sets `pause_screen` to 0. Its four QUIT buttons (`0xBC`) at (0.5 W - 100, 0.3 H + 0, 40, 80
and 120) go to 1, 6, 5 and 7. Screen 8 would be item 6 of a six-item menu or item 2 of a two-item
one; it lists the ships, their sync states and the mission's globals in the display's font and
appends them to `c:\mission.txt` each frame.

## Menu items

`menu_draw` (`0x0048DB00`, `int count` in ECX, `shapes` in EDX, then `items`, `title` and `mouse`
on the stack) draws a screen's title and items and returns the item under the cursor, or -1. The
screens act on it when `menu_mouse_pressed` is set; dialogs on `menu_mouse_released`.

An item, 0x30 bytes:

| Offset | Field |
|---|---|
| `+0x00` | Placement: the low nibble across (1 centred, 2 the left edge at the anchor, 3 the right edge), the high nibble down (1 centred, 2 the top, 3 the bottom); 0 either way as 2 |
| `+0x04`, `+0x08` | The anchor as fractions of W and H (float) |
| `+0x0C`, `+0x10` | Offsets from the anchor in pixels |
| `+0x14` | Shape, or 0 |
| `+0x18` | Shape under the cursor, or 0 |
| `+0x1C`, `+0x20` | The text's offsets from the anchor |
| `+0x24` | Font, an index into `menu_fonts`: 0 `hud_font`, 1 the small font, 2 the large; -1 for none |
| `+0x28` | String id, or -1 |
| `+0x2C` | Bits 0-2 the text's alignment (0 left, 1 centred, 2 right); bit 3 dimmed |

The title: `hud_text(hud_pane, round(0.5 W), round(0.2 H) - 32, large font, title, centred)` in the
orange ramp at brightness 1, over a rule from (round(0.1 W), round(0.2 H)) to (round(0.9 W),
round(0.2 H)), pure red (`hud_colour(255, 0, 0)` with bit 31, which `winvfx16` takes as a direct
16-bit pixel).

The shapes, item by item:

1. Palette block `0x77` at brightness 1, or 0.5 for a dimmed item.
2. The shape's width and height (`VFX_shape_bounds`, the header's first word, halves) and origin
   (`VFX_shape_origin`, the header's second; (1, 1) for every menu shape).
3. x = round(W × across) + origin x + offset x, y = round(H × down) + offset y + origin y, then
   placed by the placement nibbles.
4. With `mouse` set and the cursor within [x, x + w) by [y, y + h), the item is the one under the
   cursor; with a shape for that, it is also the highlighted item, drawn with that shape.
5. `VFX_shape_draw(hud_pane, shapes, shape, x, y)`.

The text, item by item, at (round(W × across) + offset x + text x, round(H × down) + offset y +
text y), leaving out the shape's placement and origin: `palette_ramp_brightness` (`0x005202F0`) 0.5
or 1, `hud_palette_ramp` white `0xFFFFFF` for the highlighted item and orange `0xFE851A` for the
rest, then `hud_text` through `menu_text_remap` with the item's alignment. The ramp sets VFX's
palette entries 1 to 15 to the colour times i / 15 times the brightness; on an 8-bit pane it writes
6-6-6 cube indices into the remap table instead.

### Buttons

Shape `0x176`, `0x177` under the cursor (25 by 16), text in the small font, anchored at (0.5 W, H):

| Button | String | Offset | Text |
|---|---|---|---|
| OK | `0x316` | (+16, -32) | Left, (+25, -5) |
| RESTART | `0x181` | (-16, -32) | Right, (-25, -5) |
| CONTINUE | `0x180` | (-16, -52) | Right, (-25, -5) |
| RESET DEFAULTS | `0x183` | (+16, -52) | Left, (+25, -5) |
| CANCEL CHANGES | `0x5A9` | (+16, -74) on audio and video, (-16, -74) on controls | Left; right on controls |

On screens 1 and 9 the button in OK's place is LEAVE MISSION (`0x32B`).

### Dialogs

`menu_dialog_pane` (`0x0057DA74`) spans W/2 ± 240 by H/2 ± 60. A dialog wipes it
(`VFX_pane_wipe(pane, 0)`), frames it (`menu_box_draw`, `0x0048D820`: the outer top and left edges
red 205, the outer right and bottom 102.5, a rectangle one pixel in at 164, all direct colours) and
writes its text (`hud_text_wrapped`, `0x00480FD0`) at the pane's middle across and y 0x14, in the
small font, colour `0x40BCFF`, centred, 400 wide, lines 14 pixels apart, at most 10 lines. A line
breaks at a line feed, then a space, then a hyphen, and else mid-word with a hyphen added.

## Strings

All from `LANGUAGE.DLL`, `language_string(id)` being the resource id:

| Ids | Text |
|---|---|
| `0x108`, `0x109`, `0x10A`, `0x10B` | SELECT AN OPTION, AUDIO, CONTROL DEVICES, VIDEO |
| `0x180`, `0x181`, `0x32B` | CONTINUE, RESTART, LEAVE MISSION |
| `0x316`, `0x183`, `0x5A9` | OK, RESET DEFAULTS, CANCEL CHANGES |
| `0x2ED`, `0x2EE`, `0x2EF`, `0x576`, `0x577` | SOUND CONFIGURATION, SOUND EFFECTS VOLUME, MUSIC VOLUME, SPEECH VOLUME, MASTER VOLUME |
| `0x10D`, `0x113`, `0x28A`, `0x28B`, `0x28C`, `0x57F` | GRAPHICS CONFIGURATION, BRIGHTNESS, DEFAULT VIEW, COCKPIT VIEW, CHASE VIEW, NO COCKPIT VIEW |
| `0x17A`, `0x234`, `0x235`, `0x236`, `0x237` | CONTROL CONFIGURATION, PRIMARY CONTROLLER, JOYSTICK, MOUSE, KEYBOARD ONLY |
| `0x17D`, `0x17E`, `0x17F`, `0x233` | FORCE FEEDBACK, INVERT PITCH, HAT ENABLE, JOYSTICK ROLL |
| `0x311`, `0x312`, `0x17C`, `0xB5`, `0x32C`, `0x545` | SHIFT, CONTROL, CONTROL, a space, JOY, AND (with spaces) |
| `0x5AF`, `0x5B0`, `0x5B1`, `0x28F`, `0x290` | This Key is already assigned to, Redefine Anyway?, ! NOT ASSIGNED !, YES, NO |
| `0xA9`, `0x53E`, `0x55A`, `0x5F1`, `0xBC` | PAUSED, Player has paused the game, Game paused due to bad connection., Your session has been terminated due to a bad connection, QUIT |

The actions' names are their string ids at `ControlBinding + 0x2C` (`0x330` COCKPIT CAMERA, for
one). The key names are those the keyboard's layout gives the keys, which `WinMain` and the
loaders copy into `key_names` and `ControlBinding + 0x2E` ([Key names](controls.md#key-names)).
`ControlBinding`: `+0x04` name (40 bytes), `+0x2C` string id (i16), `+0x2E` key name (30 bytes),
`+0x4C` button.

## Fonts, shapes and the cursor

`pause_menu_open` reads two fonts from `resource.hog` and opens them: `interface\optfnt.fnt`, the
large font (`menu_font_large`, titles and icon labels), and `interface\smlfnt2.fnt`, the small one
(`menu_font_small`, buttons, lists and dialogs). `menu_fonts` (`0x0057DA64`) is `hud_font`, the
small and the large. Both fonts use coverage levels 0 to 16. It also fills `menu_text_remap`
(`0x0057DAD8`) with `0xFF` and then 1 to 15, sets `pause_screen_entered` to -1 and the ramp's
brightness to 1, and ends the missile lock tone (`missile_lock_tone`, `0x00566644`, `stdsmp` sound
0x15). `pause_menu_close` (`0x004906D0`) frees both fonts (`font_close`, `0x00480DF0`).

The shapes are in `hud_shapes` (`HUDHARD.SPR`):

| Shape | What |
|---|---|
| `0x176`, `0x177` | Button, lit |
| `0x178` | Arrow box; `0x179` and `0x17A` its left and right halves |
| `0x17B` | Up and down widget; `0x17C` and `0x17D` its halves |
| `0x17E` | Cursor |
| `0x17F`-`0x184` | Joystick, speaker and monitor icons (120 by 100), then each lit |
| `0x185`, `0x186` | Check box, off and on |
| `0x187` | Slider track |
| `0x188` | Slider knob |

The drawing is VFX's, on `hud_pane`: `VFX_shape_draw`, `VFX_shape_bounds`, `VFX_shape_origin`,
`VFX_line_draw`, `VFX_pane_construct`, `VFX_pane_destroy` and `VFX_pane_wipe`, with `hud_text`,
`hud_text_wrapped`, `hud_palette_ramp`, `hud_colour` and `hud_place`.

The mouse (`menu_mouse_update`, `0x0048D9F0`): DirectInput's relative motion moves `menu_cursor_x`
and `menu_cursor_y` (`0x00502780`, `0x00502784`), which start at (320, 240), are kept between
pauses, and stay on the screen. After a move the system cursor is put back at the window's corner
plus (320, 200) (**Unverified:** through three imports, taken to be `GetWindowRect` and
`SetCursorPos`). Either button sets `menu_mouse_down`; its going down sets `menu_mouse_pressed`, and
its coming up `menu_mouse_released`, each for that frame. The cursor is drawn last, shape `0x17E` at
the point; its pixels start at (+2, +2), so the arrow's tip is at the point. The keyboard and the
joystick are read only for a binding; no key moves between items.

## Quirks

- Video RESET DEFAULTS sets `cockpit_mode` 0, no cockpit, with setting 0, the cockpit.
- Escape while a binding waits for a key leaves that action unbound, and leaving the screen saves
  it so. **Unverified:** inferred from the order of the code.
- Coverage level 16 reads `menu_text_remap[16]`, the low byte of `audio_saved_effects`
  (`0x0057DAE8`). Few pixels of the two fonts use that level.
- The audio screen's click guard leaves out the master knob's drag flag; every drag flag is clear
  on a press anyway.
- The effects test sound's volume isn't clamped.
