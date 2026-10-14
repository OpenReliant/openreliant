# Example mods

These mods are examples for mod makers. Each one shows how a part of modding works
([Modding](../../docs/guide/modding.md), [Scripting](../../docs/guide/scripting.md)), with comments
in its files. They are not supported mods: they aren't balanced or tested for play, and they can change
or go away in any release. Copy one as a starting point for your own mod.

| Mod | What it shows |
|---|---|
| [`arena`](arena) | A game mode with its own rules and HUD, which skips the simulator's radio talk (`radio_say`) |
| [`audio`](audio) | Playing the mod's own sounds in 2D and 3D, showing which piece of music is playing, and fading the music out (`openreliant.audio`) |
| [`balance`](balance) | Changing the game's records from a load script |
| [`bananas`](bananas) | A new gun with its own shot picture, sound and muzzle flash, a missile with a model built from OBJ, a pilot with a voice, a ship that carries them, and a pilot set by a script |
| [`campaign`](campaign) | A campaign with a briefing screen and a movie |
| [`cd-player-pages`](cd-player-pages) | Two pages for the CD player in the rooms, the Reliant's list and the Yamato's, turned with the front end's arrows |
| [`cel-shading`](cel-shading) | A lighting function and a surface function (`openreliant.shaders`) |
| [`crt`](crt) | A post effect (`openreliant.postprocessing`) |
| [`custom-order`](custom-order) | Registering an AI order |
| [`drawing-assets`](drawing-assets) | Drawing a mod's pictures, the game's shapes and fonts |
| [`hud-layout`](hud-layout) | A HUD display that stands in for the game's radar, moves and scales other instruments, and reads what they show |
| [`dvd`](dvd) | A menu script that draws over the menus |
| [`interceptor`](interceptor) | A new ship type, based on the Predator, flown in a game mode |
| [`main-menu`](main-menu) | A main menu of the mod's own in place of the game's |
| [`music`](music) | A piece of music in place of the main menu's, which loops back where the game's does, and a track of the CD player that plays it |
| [`rules`](rules) | Hooks on the game's functions |
| [`strafe-run`](strafe-run) | A custom order with a HUD display, a chase camera and rebindable actions |
| [`tally`](tally) | Storage kept with each saved game and across every game |
| [`teapot`](teapot) | A ship type with a model of its own, built from OBJ (`sltool shp from-obj`), and its own cockpit, display pictures and engine sound, offered on the loadout screen |
| [`trent`](trent) | Face films that replace a pilot's by name, built with `sltool fm8 encode`, and the pilot renamed in the game's text from a load script |
| [`wingmen`](wingmen) | Object scripts, events, interfaces and a mod's options page |

To try one, copy its folder into the `mods` folder of your game directory
([Modding](../../docs/guide/modding.md)). Each example's name on the mods screen starts with
`Example:`.

[What mods can do](../../docs/guide/what-mods-can-do.md) lists every modding feature with the example
that shows it.
