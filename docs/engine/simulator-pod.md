# The simulator pod

The simulator pod (`simulator_pod`, `0x0044F3D0`) is the screen Enter Simulator Pod opens in the
Reliant's rooms and the Yamato's ([The Reliant's rooms](rooms.md)). It runs in a loop of its own on
a screen 640 by 480, over a picture of the pod, and flies the simulator's missions itself: three
training missions and Instant Action. Its code lies within `C:\lancer\interface\loadout\loadout.cpp`.

## In OpenReliant

[`interface/loadout/simulator_pod.zig`](../../src/engine/interface/loadout/simulator_pod.zig) holds
the pod. The driver runs its loop (`Driver.simulate` in
[`openreliant/rooms.zig`](../../src/openreliant/rooms.zig)), keeps the rooms and the pod open while
one of its missions is flown, and goes back into the pod as the mission ends
(`Driver.backFromSimulator`).

**Fix:** RESTART in the pause menu starts the pod's mission again, as it does Instant Action's from
the main menu. The game flies the pod's mission once, and comes back to the pod however the mission
ends, RESTART among them.

## The screens

As it opens, the pod reads `inter\simpod\simgfx.spr`, the shapes that light its choices, and the
ITAC's large font, `inter\itac\itacbig.fnt`, which its title is written in. On the Yamato, for a
mission after 18, it first plays `inter\simpod\hud_controls_up_.bik` over the screen. Its two
screens (`simulator_pod_screen`, `0x00524FDC`) each have a picture behind them, the first and the
last frame of `inter\simpod\training.bik`, and a title at (42, 85), from its left:

| Screen | Title | Picture |
|---|---|---|
| 0 | FLIGHT SIMULATOR (`0x3C6`), in `0xC18415` | `inter\simpod\training_00000.tga` |
| 1 | Training Missions (`0x101`), in `0x00E200` | `inter\simpod\training_00035.tga` |

Each screen's choices are a table at `0x004EBB38` (`simulator_pod_items`), 0x58 bytes a screen: the
count, the rectangles, the lit shapes, the screens each leads to and the strings that name them.
Only the first screen reads the screens they lead to; the code takes the rest by each choice's
place.

| Screen | Choice | Rectangle | Lit shape | Leads to |
|---|---|---|---|---|
| 0 | Training Missions (`0x101`) | 111 by 111 from (265, 164) | 4 | Screen 1, through `inter\simpod\training.bik` |
| 0 | Instant Action (`0x102`) | 111 by 111 from (265, 328) | 5 | Mission 29 |
| 0 | Leave Simulator (`0x104`) | 80 by 80 from (546, 18) | 7 | Out of the pod |
| 1 | Mission 1 - Instrument Training (`0x106`) | 111 by 111 from (100, 164) | 2 | Mission 31 |
| 1 | Mission 2 - Flight Training (`0x105`) | 111 by 111 from (265, 164) | 1 | Mission 30 |
| 1 | Mission 3 - Weapons Training (`0x107`) | 111 by 111 from (265, 328) | 3 | Mission 32 |
| 1 | Leave Simulator (`0x104`) | 80 by 80 from (546, 18) | 6 | Out of the pod |
| 1 | Instant Action (`0x102`) | 80 by 80 from (546, 114) | 8 | Mission 29 |

The pointer finds a choice inside its rectangle, the edges left out. Its drawing
(`simulator_pod_draw`, `0x0044F840`) lights the choice under the pointer, its shape drawn a pixel in
from the rectangle's corner with the palette of `simgfx.spr`, and writes its name centred at
(320, 440), in white, in the front end's large font; then the title, and the pointer: the front
end's, shape `pointer_clock / 4 + 1` of `interface\frontend.spr`, whose ticks run on by the game's
each pass and back to 0 at 64 (`pointer_clock`, `0x0051D7C8`).

Escape leaves the pod. The left button takes the choice under the pointer for as long as it is
down (`itac_left_down`, `0x00520138`). Every choice but Leave Simulator plays sound 12 of the rooms'
`wlksmp.fat` at full volume, and a mission plays it twice.

## The missions

The pod flies a mission itself (`0x0044F622` on), in the simulator: the training missions in its
training (`simulator_mode` 1, which the loading screen calls Calibrating Simulator), and Instant
Action in its own (`simulator_mode` 2 and `simulator` set), as the main menu's INSTANT ACTION flies
it ([Front end](front-end.md)). It clears the attempt's variables (`mission_reset_variables`),
loads (`mission_load`), puts the player in a Grendel, ship type 2 of `player_loadouts`, and runs the
mission from `.\missions\%s.dte`, where the name is `mission31`, `mission30`, `mission32` or
`mission29`. Then it puts back the pilot's kills (`skull_count`) and `mission_number` as they were.

No hangar movie, landing, debriefing or medal comes with the mission, and the campaign's records
keep nothing of it; the game's variables, which are the campaign's, keep what the mission left in
them. The pause menu stands in for the debriefing, as for Instant Action's ([Pause
menu](pause-menu.md)): LEAVE MISSION goes back to the pod.

Back in the pod, a training mission leaves the training missions' screen up, and Instant Action
brings back FLIGHT SIMULATOR and its picture. As the pod closes, every voice ends, the rooms' hum
among them, and on the Yamato `inter\simpod\hud_controls_down.bik` plays over the screen; the rooms
go on with step `0xB` of `wlksmp.fat` ([The Reliant's rooms](rooms.md#the-loop)).
